#!/bin/bash
#
# nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verifier
# Version: v0.1.14
# Last modified on: 2026-10-09
# Organization: WalletScrutiny.com
#
# Rebuilds the Linux x86_64 AppImage ZIP with upstream's reproducible-builds/ recipe at the release
# tag (2.6.6+) and compares the whole ZIP byte for byte with the official release. The build image
# is pinned to release day: dated ubuntu:noble-* base + Ubuntu/PPA apt snapshot.
#
# Usage: nunchukdesktop_build.sh --version VERSION [--binary ZIP] [--arch x86_64-linux-gnu] [--type appimage]
#

set -euo pipefail

SCRIPT_VERSION="v0.1.14"
APP_ID="nunchuk"
APP_NAME="Nunchuk Desktop"
GH_REPO="nunchuk-io/nunchuk-desktop"

EXIT_OK=0
EXIT_DIFF=1
EXIT_INVALID=2

APP_VERSION=""
APP_ARCH="x86_64-linux-gnu"
APP_TYPE="appimage"
BINARY_PATH=""
CONTAINER_CMD=""
# Digest-pinned git image: clones and resolves the tag inside a container.
GIT_IMAGE="${GIT_IMAGE:-docker.io/alpine/git@sha256:6f8eae2205a85c51106a9650e574a37fb1d5e4f645e5f6ea57cb57b9462cd4cf}"
WORK_DIR=""
IMAGE_NAME=""
HWI_IMAGE=""
HWI_SHA256=""
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
UPSTREAM_DOCKERFILE_SHA256=""
# Release-day pins; empty = derived. Override: UBUNTU_SNAPSHOT=YYYYMMDDTHHMMSSZ, UBUNTU_BASE=<image>.
UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT:-}"
UBUNTU_BASE="${UBUNTU_BASE:-}"
VERDICT_WRITTEN=false
NO_VERDICT_BY_DESIGN=false

# Pinned release-key fingerprint: a good signature from any other key is not a pass.
NUNCHUK_RELEASE_KEY_FPR="8C8ECD3F660CA53CD878792A6E38A462ED2EF525"
SIG_MANIFEST_STATUS="[WARNING] Manifest signature not checked"
SIG_DIGEST_STATUS="[WARNING] Digest not checked against a signed manifest"
SIG_KEY_USED=""
SIG_TAG_TYPE="unknown"
RESOLVED_COMMIT="unknown"
SIG_TAG_STATUS="[WARNING] Tag signature not checked by this script"
SIG_WARNINGS=""
PROVENANCE_FATAL=""

# OFFICIAL_ARTIFACT_* = file as distributed (ZIP); OFFICIAL_APPIMAGE_SHA256 = payload compared.
OFFICIAL_ARTIFACT_NAME=""
OFFICIAL_ARTIFACT_SHA256=""
OFFICIAL_APPIMAGE_SHA256=""
BUILT_ARTIFACT_SHA256=""
BUILT_APPIMAGE_SHA256=""

NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die_invalid() {
    log_error "$1"
    write_yaml "ftbfs" "$1"
    exit "${EXIT_INVALID}"
}

die_build() {
    log_error "$1"
    write_yaml "ftbfs" "$1"
    exit "${EXIT_DIFF}"
}

# Signed manifest disagrees with the downloaded file: emit no verdict, remove any stale YAML.
die_provenance() {
    log_error "PROVENANCE FAILURE: $1"
    log_error "No verdict is emitted: the artifact compared is not the file upstream signed."
    NO_VERDICT_BY_DESIGN=true
    rm -f "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    log_info "COMPARISON_RESULTS.yaml removed; nothing will be published for this run."
    exit "${EXIT_DIFF}"
}

write_yaml() {
    local verdict="$1"
    local notes="${2:-}"
    # Keep the YAML double-quoted scalar valid even if error text contains quotes.
    notes="${notes//\"/\'}"
    local yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "$notes" ]]; then
        printf 'script_version: %s\nverdict: %s\nnotes: "%s"\n' \
            "$SCRIPT_VERSION" "$verdict" "$notes" > "$yaml_file"
    else
        printf 'script_version: %s\nverdict: %s\n' \
            "$SCRIPT_VERSION" "$verdict" > "$yaml_file"
    fi
    VERDICT_WRITTEN=true
    log_info "COMPARISON_RESULTS.yaml written to: $yaml_file"
}

sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

check_build_inputs() {
    log_info "No compile-time secrets required: upstream removed the OAuth defines at 2.6.6."
}

comparison_context_note() {
    printf '%s' "Built with upstream reproducible-builds/Dockerfile.linux and build_linux.sh at tag ${APP_VERSION} (Dockerfile sha256 ${UPSTREAM_DOCKERFILE_SHA256}), base image ${UBUNTU_BASE}, apt pinned to Ubuntu and PPA snapshot ${UBUNTU_SNAPSHOT}.${HWI_SHA256:+ Bundled hwi built from source, sha256 ${HWI_SHA256}.}"
}


detect_container_cmd() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    else
        die_invalid "Neither podman nor docker found in PATH. Install one and retry."
    fi
    log_info "Container runtime: $CONTAINER_CMD"
}

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        die_invalid "Missing value for parameter: $flag"
    fi
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION [--binary FILE] [--arch ARCH] [--type TYPE]"
        echo "Run $0 --help for details"
        exit "${EXIT_INVALID}"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                require_arg "$1" "${2:-}"
                APP_VERSION="$2"; shift 2 ;;
            --binary)
                require_arg "$1" "${2:-}"
                BINARY_PATH="$2"; shift 2 ;;
            --arch)
                require_arg "$1" "${2:-}"
                APP_ARCH="$2"; shift 2 ;;
            --type)
                require_arg "$1" "${2:-}"
                APP_TYPE="$2"; shift 2 ;;
            --apk)
                # Android alias accepted for ABS compatibility; not applicable here
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi
                log_warn "--apk is not applicable for desktop builds (ignored)" ;;
            --help)
                show_help; exit 0 ;;
            *)
                log_warn "Unknown argument: $1 (ignored)"
                shift ;;
        esac
    done

    if [[ -z "$APP_VERSION" ]]; then
        die_invalid "--version is required"
    fi

    # Only x86_64-linux-gnu / appimage is implemented.
    if [[ "$APP_ARCH" != "x86_64-linux-gnu" ]]; then
        die_invalid "Unsupported --arch '${APP_ARCH}'; only x86_64-linux-gnu is implemented"
    fi
    if [[ "$APP_TYPE" != "appimage" ]]; then
        die_invalid "Unsupported --type '${APP_TYPE}'; only appimage is implemented"

    fi

    # 2.6.6 is the first verifiable release (SOURCE_DATE_EPOCH set, OAuth defines removed).
    if [[ "$(printf '%s\n' "2.6.6" "$APP_VERSION" | sort -V | head -1)" != "2.6.6" ]]; then
        die_invalid "Version ${APP_VERSION} predates 2.6.6; this script cannot verify it (see changelog v0.1.10)"
    fi

    if [[ -n "$BINARY_PATH" && ! -f "$BINARY_PATH" ]]; then
        die_invalid "--binary path does not exist: $BINARY_PATH"
    fi
    if [[ -n "$BINARY_PATH" ]]; then
        BINARY_PATH="$(realpath "$BINARY_PATH")"
    fi
}

show_help() {
    cat << 'EOF'
nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verification

USAGE:
  nunchukdesktop_build.sh --version VERSION [OPTIONS]

REQUIRED:
  --version VERSION    App version without v prefix (e.g. 1.9.50)

OPTIONAL:
  --binary FILE        Official release ZIP (skip GitHub download)
  --arch ARCH          x86_64-linux-gnu (default, only supported value)
  --type TYPE          appimage (default, only supported value)

OPTIONAL ENVIRONMENT:
  GITHUB_TOKEN          Used for GitHub downloads and API lookups, to avoid rate limiting
  UBUNTU_SNAPSHOT       apt snapshot ID (YYYYMMDDTHHMMSSZ); default: release ZIP upload time
  UBUNTU_BASE           Base image; default: newest ubuntu:noble-* tag pushed before the snapshot

EXAMPLES:
  nunchukdesktop_build.sh --version 2.6.6
  nunchukdesktop_build.sh --version 2.9.0 --binary ~/Downloads/nunchuk-linux-x86_64-v2.9.0.zip

EXIT CODES:
  0  Identical (rebuilt ZIP byte-for-byte equal to the released ZIP)
  1  Differences found or build failed
  2  Invalid parameters

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/built.zip           (the rebuilt artifact)
EOF
}

# Per-run workspace under the caller's directory: exclusive create, never reused or deleted.
setup_workdir() {
    local suffix="${APP_VERSION}_${APP_ARCH}_${APP_TYPE}"
    suffix="${suffix//[^a-zA-Z0-9._-]/_}"
    local base tries
    base="$(pwd -P)"
    for tries in 1 2 3; do
        WORK_DIR="${base}/nunchuk_verification_${suffix}_$(date +%s)-$$"
        if mkdir "$WORK_DIR" 2>/dev/null; then
            trap reclaim_workspace EXIT
            trap 'exit 130' INT; trap 'exit 143' TERM
            log_info "Work directory: $WORK_DIR"
            return 0
        fi
        sleep 1
    done
    WORK_DIR=""
    die_build "Could not create a per-run workspace under ${base}"
}

# EXIT trap: drop this run's image, hand the workspace back; never fails.
reclaim_workspace() {
    set +e
    # No verdict yet (killed or internal error): record ftbfs, unless withheld on purpose.
    if [[ "$VERDICT_WRITTEN" != true && "$NO_VERDICT_BY_DESIGN" != true ]]; then
        write_yaml "ftbfs" "Run ended before a verdict was written (interrupted or internal error)"
    fi
    if [[ -n "$IMAGE_NAME" ]]; then
        "$CONTAINER_CMD" rmi "$IMAGE_NAME" > /dev/null 2>&1
    fi
    if [[ -n "$HWI_IMAGE" ]]; then
        "$CONTAINER_CMD" rmi "$HWI_IMAGE" > /dev/null 2>&1
    fi
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
    # Only call the container runtime if the build left foreign-owned files behind.
    if [[ -n "$(find "$WORK_DIR" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
        restore_host_owner "$WORK_DIR"
    fi
    chmod -R u+rwX "$WORK_DIR" > /dev/null 2>&1
    if [[ -n "$(find "$WORK_DIR" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
        log_warn "Workspace still has files not owned by uid $(id -u): ${WORK_DIR}"
    fi
    return 0
}

add_sig_warning() {
    SIG_WARNINGS="${SIG_WARNINGS}
- $1"
}

# A provenance check that could not be performed. Never fatal.
sig_skip() {
    SIG_MANIFEST_STATUS="[WARNING] $1"
    add_sig_warning "$2"
    log_warn "$1 (verdict unaffected)"
}

# Verify the SHA256SUMS signature, then cross-check our digest against it (advisory).
verify_official_signature() {
    local sums_url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/SHA256SUMS"
    local sums="${WORK_DIR}/SHA256SUMS"
    local asc="${WORK_DIR}/SHA256SUMS.asc"

    echo ""
    log_info "Verifying release manifest signature..."

    if ! command -v gpg >/dev/null 2>&1; then
        sig_skip "gpg not installed; manifest signature not verified" \
                 "gpg is not installed here, so the manifest signature was not checked."
        return 0
    fi

    local dl=(wget -q ${GITHUB_TOKEN:+--header="Authorization: token ${GITHUB_TOKEN}"})
    if ! "${dl[@]}" -O "$sums" "$sums_url" 2>/dev/null; then
        sig_skip "SHA256SUMS not published for ${APP_VERSION}" \
                 "No SHA256SUMS asset was retrievable for ${APP_VERSION}."
        return 0
    fi
    if ! "${dl[@]}" -O "$asc" "${sums_url}.asc" 2>/dev/null; then
        sig_skip "SHA256SUMS.asc not published for ${APP_VERSION}" \
                 "SHA256SUMS was published but SHA256SUMS.asc was not; the manifest is unsigned as far as this run established."
        check_digest_against_manifest "$sums" "unsigned"
        return 0
    fi

    # Throwaway keyring: a locally trusted key must not silently make this pass.
    local gnupg_home="${WORK_DIR}/gnupg"
    mkdir -p "$gnupg_home"; chmod 700 "$gnupg_home"

    # Plain HTTPS from keyserver.ubuntu.com (no dirmngr; keys.openpgp.org strips user IDs).
    local imported=false
    local keyfile="${WORK_DIR}/release-key.asc"
    local src="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${NUNCHUK_RELEASE_KEY_FPR}"
    if timeout 60 wget -qO "$keyfile" "$src" 2>/dev/null \
            && grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$keyfile" 2>/dev/null \
            && GNUPGHOME="$gnupg_home" gpg --batch --quiet --import "$keyfile" >/dev/null 2>&1 \
            && GNUPGHOME="$gnupg_home" gpg --batch --with-colons --fingerprint 2>/dev/null \
                 | grep -q "^fpr:::::::::${NUNCHUK_RELEASE_KEY_FPR}:"; then
        imported=true
        log_ok "Release key ${NUNCHUK_RELEASE_KEY_FPR} imported"
    fi
    if [[ "$imported" != true ]]; then
        sig_skip "Release key ${NUNCHUK_RELEASE_KEY_FPR} could not be retrieved" \
                 "The pinned release key could not be fetched (offline or blocked); signature not verified."
        check_digest_against_manifest "$sums" "unverified"
        return 0
    fi

    # SHA256SUMS.asc is clearsigned; the detached form is also handled.
    local gpg_out="" gpg_rc=0 sig_form="clearsigned"
    local verified_manifest="${WORK_DIR}/SHA256SUMS.verified"

    gpg_out="$(GNUPGHOME="$gnupg_home" gpg --batch --status-fd 1 --output "$verified_manifest" \
                  --decrypt "$asc" 2>/dev/null)" || gpg_rc=$?
    if ! grep -q "^\[GNUPG:\] \(GOODSIG\|BADSIG\|EXPKEYSIG\|REVKEYSIG\|ERRSIG\) " <<<"$gpg_out"; then
        # Not clearsigned: retry as a detached signature over the separate manifest.
        sig_form="detached"
        gpg_rc=0
        gpg_out="$(GNUPGHOME="$gnupg_home" gpg --batch --status-fd 1 \
                      --verify "$asc" "$sums" 2>/dev/null)" || gpg_rc=$?
        cp "$sums" "$verified_manifest" 2>/dev/null || true
    fi

    # Require VALIDSIG on the pinned key (signing subkey or primary).
    local sig_key="" pri_key="" vline
    vline="$(grep -m1 "^\[GNUPG:\] VALIDSIG " <<<"$gpg_out" || true)"
    if [[ -n "$vline" ]]; then
        sig_key="$(awk '{print $3}' <<<"$vline")"
        pri_key="$(awk '{print $NF}' <<<"$vline")"
    fi

    if [[ $gpg_rc -eq 0 ]] && grep -q "^\[GNUPG:\] GOODSIG " <<<"$gpg_out" \
            && { [[ "$sig_key" == "$NUNCHUK_RELEASE_KEY_FPR" ]] || [[ "$pri_key" == "$NUNCHUK_RELEASE_KEY_FPR" ]]; }; then
        SIG_MANIFEST_STATUS="[OK] Good ${sig_form} signature on SHA256SUMS from pinned key ${NUNCHUK_RELEASE_KEY_FPR}"
        if [[ -n "$sig_key" && "$sig_key" != "$NUNCHUK_RELEASE_KEY_FPR" ]]; then
            SIG_KEY_USED="Manifest signed with: subkey ${sig_key} of pinned primary ${NUNCHUK_RELEASE_KEY_FPR}"
        else
            SIG_KEY_USED="Manifest signed with: ${NUNCHUK_RELEASE_KEY_FPR}"
        fi
        log_ok "Good ${sig_form} signature on SHA256SUMS from the pinned release key"
        check_digest_against_manifest "$verified_manifest" "signed"
    elif grep -q "^\[GNUPG:\] GOODSIG " <<<"$gpg_out"; then
        SIG_MANIFEST_STATUS="[WARNING] SHA256SUMS signed by ${sig_key:-an unexpected key}, not the pinned ${NUNCHUK_RELEASE_KEY_FPR}"
        SIG_KEY_USED="Manifest signed with: ${sig_key:-unknown}"
        add_sig_warning "The manifest is signed by a key other than the pinned fingerprint. Treat the key as rotated or the artifact as suspect until upstream confirms which."
        log_warn "Manifest signed by an unexpected key: ${sig_key:-unknown}"
        check_digest_against_manifest "$verified_manifest" "unverified"
    else
        SIG_MANIFEST_STATUS="[WARNING] No valid signature on SHA256SUMS"
        add_sig_warning "gpg reported no valid signature over the release manifest."
        log_warn "No valid signature on SHA256SUMS"
        check_digest_against_manifest "$sums" "unverified"
    fi

    # Any clearsigned run, whoever signed: flag a split between unsigned asset and signed payload.
    if [[ "$sig_form" == "clearsigned" && -s "$verified_manifest" ]] \
            && ! diff -q "$sums" "$verified_manifest" >/dev/null 2>&1; then
        add_sig_warning "The unsigned SHA256SUMS asset does not match the signed payload in SHA256SUMS.asc; the signed payload was used."
        log_warn "SHA256SUMS differs from the signed payload inside SHA256SUMS.asc"
    fi
}

# Exact filename match in the manifest; sets globals (no subshell).
check_digest_against_manifest() {
    local sums="$1" manifest_state="$2"
    local want="${OFFICIAL_ARTIFACT_SHA256:-}" name="${OFFICIAL_ARTIFACT_NAME:-}"

    if [[ -z "$want" || -z "$name" || ! -r "$sums" ]]; then
        SIG_DIGEST_STATUS="[WARNING] No readable manifest, or no measured digest, to compare"
        return 0
    fi
    local matches count listed
    matches="$(awk -v n="$name" '$2 == n || $2 == "*" n {print $1}' "$sums" 2>/dev/null || true)"
    count="$(printf '%s\n' "$matches" | grep -c . || true)"

    if [[ "${count:-0}" -eq 0 ]]; then
        add_sig_warning "The manifest does not list ${name}; its digest was not cross-checked."
        SIG_DIGEST_STATUS="[WARNING] ${name} is not listed in the manifest"
        [[ "$manifest_state" == "signed" ]] && PROVENANCE_FATAL="the signed manifest does not list ${name}"
        return 0
    fi
    if [[ "${count:-0}" -gt 1 ]]; then
        add_sig_warning "The manifest lists ${name} ${count} times; ambiguous, treat as unverified."
        SIG_DIGEST_STATUS="[WARNING] The manifest lists ${name} more than once"
        [[ "$manifest_state" == "signed" ]] && PROVENANCE_FATAL="the signed manifest lists ${name} ${count} times"
        return 0
    fi
    listed="$(printf '%s\n' "$matches" | head -1)"
    if [[ ! "$listed" =~ ^[0-9a-fA-F]{64}$ ]]; then
        add_sig_warning "The manifest entry for ${name} is not a sha256 digest."
        SIG_DIGEST_STATUS="[WARNING] Malformed manifest entry for ${name}"
        return 0
    fi

    if [[ "${listed,,}" == "${want,,}" ]]; then
        case "$manifest_state" in
            signed)   SIG_DIGEST_STATUS="[OK] Measured digest of ${name} matches the signed manifest" ;;
            unsigned) SIG_DIGEST_STATUS="[INFO] Measured digest of ${name} matches the manifest, but it is unsigned" ;;
            *)        SIG_DIGEST_STATUS="[INFO] Measured digest of ${name} matches the manifest, signature unverified" ;;
        esac
    else
        add_sig_warning "The artifact digest does NOT match the manifest entry for ${name}. Do not publish a verdict from this run."
        SIG_DIGEST_STATUS="[WARNING] Measured digest of ${name} does NOT match the manifest entry"
        [[ "$manifest_state" == "signed" ]] && PROVENANCE_FATAL="measured digest of ${name} does not match the signed manifest"
    fi
}

# Release ZIP name: nunchuk-linux-x86_64-v<V> from 2.9.0 (Qt 6, aarch64 added), nunchuk-linux-v<V> before.
zip_stem() {
    if [[ "$(printf '%s\n' 2.9.0 "$APP_VERSION" | sort -V | head -1)" == "2.9.0" ]]; then
        printf 'nunchuk-linux-x86_64-v%s' "$APP_VERSION"
    else
        printf 'nunchuk-linux-v%s' "$APP_VERSION"
    fi
}

prepare_official() {
    # Official release ZIP: --binary or GitHub download; extract the AppImage.
    local official_appimage="${WORK_DIR}/official.AppImage"

    if [[ -n "$BINARY_PATH" ]]; then
        log_info "Using provided binary: $(basename "$BINARY_PATH")"
        local bname; bname="$(basename "$BINARY_PATH")"
        OFFICIAL_ARTIFACT_NAME="$bname"
        OFFICIAL_ARTIFACT_SHA256="$(sha256_of "$BINARY_PATH")"
        log_ok "Official artifact as provided: ${bname}"
        log_ok "  sha256: ${OFFICIAL_ARTIFACT_SHA256}"
        if [[ "$bname" == *.zip ]]; then
            log_info "Archive contents:"
            unzip -l "$BINARY_PATH" || true
            log_info "Extracting AppImage from provided ZIP..."
            unzip -q "$BINARY_PATH" -d "${WORK_DIR}/official_zip"
            local found; found="$(find "${WORK_DIR}/official_zip" -name "*.AppImage" -print -quit)"
            if [[ -z "$found" ]]; then
                die_build "No .AppImage found inside provided ZIP: $BINARY_PATH"
            fi
            cp "$found" "$official_appimage"
        else
            # Only the released .zip is accepted: the verdict is the whole ZIP.
            die_invalid "--binary must be the released .zip, got: $bname"
        fi
    else
        local zip_name; zip_name="$(zip_stem).zip"
        local dl_url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/${zip_name}"
        local zip_path="${WORK_DIR}/${zip_name}"
        log_info "Downloading official release: $dl_url"
        if ! wget -q ${GITHUB_TOKEN:+--header="Authorization: token ${GITHUB_TOKEN}"} \
                -O "$zip_path" "$dl_url"; then
            die_build "Failed to download: $dl_url"
        fi
        # appHash = the ZIP as downloaded, hashed before unpacking.
        OFFICIAL_ARTIFACT_NAME="$zip_name"
        OFFICIAL_ARTIFACT_SHA256="$(sha256_of "$zip_path")"
        log_ok "Official artifact as downloaded: ${zip_name} ($(stat -c%s "$zip_path") bytes)"
        log_ok "  sha256: ${OFFICIAL_ARTIFACT_SHA256}"
        log_info "Archive contents:"
        unzip -l "$zip_path" || true
        log_info "Extracting AppImage from downloaded ZIP..."
        unzip -q "$zip_path" -d "${WORK_DIR}/official_zip"
        local found; found="$(find "${WORK_DIR}/official_zip" -name "*.AppImage" -print -quit)"
        if [[ -z "$found" ]]; then
            die_build "No .AppImage found inside downloaded ZIP: $zip_path"
        fi
        cp "$found" "$official_appimage"
    fi

    local sz; sz="$(stat -c%s "$official_appimage")"
    OFFICIAL_APPIMAGE_SHA256="$(sha256_of "$official_appimage")"
    log_ok "Official AppImage ready: $(basename "$official_appimage") (${sz} bytes)"
    log_ok "  sha256: ${OFFICIAL_APPIMAGE_SHA256} (payload compared; NOT the publishable hash)"
}

# Run git inside a container against WORK_DIR mounted at /w.
git_c() {
    # safe.directory: the checkout may belong to another uid.
    "$CONTAINER_CMD" run --rm -v "${WORK_DIR}:/w" -w /w "$GIT_IMAGE" \
        -c safe.directory='*' "$@"
}

# True when the engine runs rootless (container UID 0 = caller).
is_rootless() {
    local r=""
    case "$CONTAINER_CMD" in
        *podman) r="$("$CONTAINER_CMD" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" ;;
        *docker) if "$CONTAINER_CMD" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
                 then r="true"; else r="false"; fi ;;
    esac
    [[ "$r" == "true" ]]
}

# /project must appear as the caller's UID, as under rootful Docker; UID 0 changes the output.
set_build_owner() {
    "$CONTAINER_CMD" run --rm -v "${1}:/w" --entrypoint chown "$GIT_IMAGE" \
        -R "$(id -u):$(id -g)" /w > /dev/null 2>&1 \
        || die_build "Could not set build ownership on ${1}; the build would not match upstream's"
}

# Hand the tree back to the caller; never fatal.
restore_host_owner() {
    local uid gid
    uid="$(id -u)"; gid="$(id -g)"
    if is_rootless; then uid=0; gid=0; fi
    "$CONTAINER_CMD" run --rm -v "${1}:/w" --entrypoint chown "$GIT_IMAGE" \
        -R "${uid}:${gid}" /w > /dev/null 2>&1 \
        || log_warn "Could not restore ownership of ${1}; deleting it may need 'podman unshare rm -rf'"
}

# apt snapshot = release ZIP upload time; base = newest noble-* tag pushed before it.
resolve_release_pins() {
    local sde="$1" t
    local gh=(wget -qO- ${GITHUB_TOKEN:+--header="Authorization: token ${GITHUB_TOKEN}"})
    if [[ -z "$UBUNTU_SNAPSHOT" ]]; then
        t="$("${gh[@]}" "https://api.github.com/repos/${GH_REPO}/releases/tags/${APP_VERSION}" 2>/dev/null \
            | grep -oE '"(name|created_at)": *"[^"]*"' \
            | awk -F'"' -v n="$(zip_stem).zip" '$2=="name"{h=($4==n)} $2=="created_at"&&h{print $4; exit}' || true)"
        if [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
            UBUNTU_SNAPSHOT="$(tr -d ':-' <<<"$t")"
            log_info "apt snapshot = release ZIP upload time: ${UBUNTU_SNAPSHOT}"
        else
            UBUNTU_SNAPSHOT="$(date -u -d "@$((sde + 86400))" +%Y%m%dT%H%M%SZ)"
            log_warn "Release upload time not available; apt snapshot = tag commit + 1 day: ${UBUNTU_SNAPSHOT}"
        fi
    fi
    [[ "$UBUNTU_SNAPSHOT" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] \
        || die_invalid "UBUNTU_SNAPSHOT must look like 20260821T123445Z, got: ${UBUNTU_SNAPSHOT}"
    if [[ -z "$UBUNTU_BASE" ]]; then
        local iso="${UBUNTU_SNAPSHOT:0:4}-${UBUNTU_SNAPSHOT:4:2}-${UBUNTU_SNAPSHOT:6:2}T${UBUNTU_SNAPSHOT:9:2}:${UBUNTU_SNAPSHOT:11:2}:${UBUNTU_SNAPSHOT:13:2}Z"
        t="$(wget -qO- "https://hub.docker.com/v2/repositories/library/ubuntu/tags?name=noble-&page_size=100" 2>/dev/null \
            | grep -oE '"(last_updated|name)":"[^"]*"' | paste - - \
            | sed -nE 's/.*"last_updated":"([^"]+)".*"name":"(noble-[0-9]{8}(\.[0-9]+)?)".*/\1 \2/p' \
            | awk -v s="$iso" '$1 <= s' | sort | tail -1 | awk '{print $2}' || true)"
        # No silent fallback to the moving tag: that is the drift this version exists to remove.
        [[ -n "$t" ]] || die_build "Could not pick a dated ubuntu:noble-* base image for ${iso}; set UBUNTU_BASE"
        UBUNTU_BASE="docker.io/library/ubuntu:${t}"
    fi
    log_info "Base image: ${UBUNTU_BASE}"
}

# Upstream Dockerfile + 2 lines: dated FROM, apt snapshot (TLS check off for snapshot hosts; GPG still on).
pin_dockerfile() {
    local src="$1" dst="$2"
    grep -qE '^FROM ubuntu:24\.04[[:space:]]*$' "$src" \
        || die_build "Upstream Dockerfile.linux no longer starts FROM ubuntu:24.04; pinning not applied"
    awk -v base="$UBUNTU_BASE" -v snap="$UBUNTU_SNAPSHOT" '
        /^FROM ubuntu:24\.04[[:space:]]*$/ && !done {
            print "FROM " base
            printf "RUN printf '\''APT::Snapshot \"%s\";\\nAcquire::https::snapshot.ubuntu.com::Verify-Peer \"false\";\\nAcquire::https::snapshot.ppa.launchpadcontent.net::Verify-Peer \"false\";\\n'\'' > /etc/apt/apt.conf.d/50ws-snapshot\n", snap
            done = 1; next
        }
        { print }' "$src" > "$dst"
    log_info "Pinned Dockerfile (upstream + 2 lines): sha256 $(sha256_of "$dst")"
    diff "$src" "$dst" | grep '^[<>]' || true
}

# HWI from source at the fork commit upstream's CI pins (build-linux.yml HWI_TAG/HWI_COMMIT),
# with the fork's contrib/build.Dockerfile + build_bin.sh --without-gui, into hwi-prebuilt/.
build_hwi() {
    local src="$1" wf="${1}/.github/workflows/build-linux.yml" tag commit head
    tag="$(sed -nE 's/^[[:space:]]*HWI_TAG:[[:space:]]*([^[:space:]#]+).*/\1/p' "$wf" | head -1)"
    commit="$(sed -nE 's/^[[:space:]]*HWI_COMMIT:[[:space:]]*([0-9a-f]{40}).*/\1/p' "$wf" | head -1)"
    [[ -n "$tag" && -n "$commit" ]] || die_build "HWI_TAG/HWI_COMMIT not found in upstream build-linux.yml"
    log_info "Building HWI ${tag} (${commit}) from source, as upstream's CI does..."
    rm -rf "${WORK_DIR}/hwi-src"
    git_c clone --depth 1 --branch "$tag" https://github.com/nogibi/HWI.git /w/hwi-src \
        || die_build "Could not clone nogibi/HWI at ${tag}"
    head="$(git_c -C /w/hwi-src rev-parse HEAD | tr -dc '0-9a-f')" || head=""
    [[ "$head" == "$commit" ]] || die_build "HWI checkout ${head} is not the pinned commit ${commit}"
    HWI_IMAGE="nunchuk-hwi-${APP_VERSION}-$(date +%s)-$$"
    "$CONTAINER_CMD" build --platform linux/amd64 -t "$HWI_IMAGE" \
        -f "${WORK_DIR}/hwi-src/contrib/build.Dockerfile" "${WORK_DIR}/hwi-src" \
        || die_build "HWI builder image failed"
    mkdir -p "${src}/hwi-prebuilt"
    "$CONTAINER_CMD" run --platform linux/amd64 --rm \
        -v "${WORK_DIR}/hwi-src:/hwi-src" -v "${src}/hwi-prebuilt:/out" -w /hwi-src "$HWI_IMAGE" \
        bash -c 'set -euo pipefail; bash contrib/build_bin.sh --without-gui
                 b="$(find dist -type f -name hwi -print -quit)"; [[ -n "$b" ]]; install -m 0755 "$b" /out/hwi' \
        || die_build "HWI build failed"
    "$CONTAINER_CMD" rmi "$HWI_IMAGE" > /dev/null 2>&1 || true
    HWI_IMAGE=""
    [[ -x "${src}/hwi-prebuilt/hwi" ]] || die_build "HWI build produced no executable"
    HWI_SHA256="$(sha256_of "${src}/hwi-prebuilt/hwi")"
    log_ok "HWI built: hwi sha256 ${HWI_SHA256}"
}

run_build() {
    # Upstream's Dockerfile.linux + build_linux.sh, source at /project, as its README instructs.
    local src="${WORK_DIR}/src"
    log_info "Cloning ${GH_REPO} at tag ${APP_VERSION} (in a container)..."
    rm -rf "$src"
    if ! git_c clone --depth=1 --shallow-submodules --recurse-submodules \
            --branch "${APP_VERSION}" "https://github.com/${GH_REPO}.git" /w/src; then
        die_build "Could not clone ${GH_REPO} at tag ${APP_VERSION}"
    fi
    # Checkout HEAD must equal the remote tag commit; fails closed.
    resolve_commit
    [[ "$RESOLVED_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
        || die_build "Could not resolve tag ${APP_VERSION} to a commit; refusing to attribute a build to it"
    local head; head="$(git_c -C /w/src rev-parse HEAD | tr -dc '0-9a-f')" || head=""
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die_build "Could not read HEAD from the checkout"
    [[ "$head" == "$RESOLVED_COMMIT" ]] \
        || die_build "Checkout HEAD ${head} does not match tag ${APP_VERSION} commit ${RESOLVED_COMMIT}"
    log_ok "Checkout HEAD matches tag ${APP_VERSION}: ${head}"

    local sde; sde="$(git_c -C /w/src log -1 --format=%ct | tr -dc 0-9)" || sde=""
    [[ -n "$sde" ]] || die_build "Could not read the tag commit time; SOURCE_DATE_EPOCH unset"
    log_info "SOURCE_DATE_EPOCH from tag commit: ${sde} ($(date -u -d "@${sde}" '+%Y-%m-%d %H:%M:%S UTC'))"

    local dockerfile="${src}/reproducible-builds/Dockerfile.linux"
    [[ -f "$dockerfile" ]] || die_build "Upstream reproducible-builds/Dockerfile.linux not found at tag ${APP_VERSION}"
    UPSTREAM_DOCKERFILE_SHA256="$(sha256_of "$dockerfile")"
    log_info "Upstream Dockerfile.linux sha256: ${UPSTREAM_DOCKERFILE_SHA256}"
    resolve_release_pins "$sde"
    # Kept in WORK_DIR, outside the bind-mounted source tree, so the build sees upstream's files only.
    pin_dockerfile "$dockerfile" "${WORK_DIR}/Dockerfile.pinned"
    dockerfile="${WORK_DIR}/Dockerfile.pinned"

    local image_name="nunchuk-verifier-${APP_VERSION}-$(date +%s)-$$"
    IMAGE_NAME="$image_name"
    log_info "Building upstream image -- 20-40 min on first run..."
    local attempt image_built=false
    for attempt in 1 2 3; do
        # x86_64 build args as upstream's README/CI pass them (2.9.0+; unused before).
        if "$CONTAINER_CMD" build --platform linux/amd64 \
                --build-arg APPIMAGE_ARCH=x86_64 --build-arg QT_HOST=linux \
                --build-arg QT_ARCH=linux_gcc_64 --build-arg QT_DIR_NAME=gcc_64 \
                -t "$image_name" -f "$dockerfile" "$src"; then
            image_built=true
            break
        fi
        log_warn "Image build attempt ${attempt}/3 failed (upstream pins no retry on the aqt module download)"
        [[ "$attempt" -lt 3 ]] && sleep 15
    done
    [[ "$image_built" == true ]] || die_build "Container image build failed after 3 attempts"

    # From 2.9.0 the AppImage bundles hwi, which upstream's CI builds first into hwi-prebuilt/.
    if grep -q 'hwi-prebuilt' "${src}/reproducible-builds/package_linux.sh" 2>/dev/null; then
        build_hwi "$src"
    fi

    # Ownership set after the image build, which reads the context as the host user.
    log_info "Setting build ownership so /project matches upstream's rootful-Docker semantics..."
    set_build_owner "${WORK_DIR}"

    log_info "Running upstream build_linux.sh inside the container..."
    if ! "$CONTAINER_CMD" run --platform linux/amd64 --rm \
            -e TAG="${APP_VERSION}" -e ARCH=x86_64 \
            -v "${src}:/project" -w /project \
            "$image_name" bash ./reproducible-builds/build_linux.sh; then
        restore_host_owner "${WORK_DIR}"
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Containerized upstream build failed"
    fi

    restore_host_owner "${WORK_DIR}"
    "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true

    local out_zip; out_zip="${src}/$(zip_stem)/$(zip_stem).zip"
    [[ -f "$out_zip" ]] || die_build "Upstream build produced no ZIP at ${out_zip}"
    cp "$out_zip" "${WORK_DIR}/built.zip"

    BUILT_ARTIFACT_SHA256="$(sha256_of "${WORK_DIR}/built.zip")"
    log_ok "Built artifact: $(zip_stem).zip ($(stat -c%s "${WORK_DIR}/built.zip") bytes)"
    log_ok "  sha256: ${BUILT_ARTIFACT_SHA256}"

    rm -rf "${WORK_DIR}/built_zip"
    unzip -q "${WORK_DIR}/built.zip" -d "${WORK_DIR}/built_zip"
    local found; found="$(find "${WORK_DIR}/built_zip" -name "*.AppImage" -print -quit)"
    [[ -n "$found" ]] || die_build "No .AppImage found inside the rebuilt ZIP"
    cp "$found" "${WORK_DIR}/built.AppImage"

    BUILT_APPIMAGE_SHA256="$(sha256_of "${WORK_DIR}/built.AppImage")"
    log_ok "Built AppImage ready: built.AppImage ($(stat -c%s "${WORK_DIR}/built.AppImage") bytes)"
    log_ok "  sha256: ${BUILT_APPIMAGE_SHA256}"
}

compare_artifacts() {
    # Verdict = the whole ZIP byte for byte; nothing else can pass.
    echo ""
    echo "======================================================"
    echo "ARTIFACT COMPARISON (whole ZIP, byte for byte)"
    echo "======================================================"
    echo "Official: ${OFFICIAL_ARTIFACT_NAME}"
    echo "  ${OFFICIAL_ARTIFACT_SHA256}"
    echo "Rebuilt:  $(zip_stem).zip"
    echo "  ${BUILT_ARTIFACT_SHA256}"
    echo "Official AppImage: ${OFFICIAL_APPIMAGE_SHA256}"
    echo "Rebuilt  AppImage: ${BUILT_APPIMAGE_SHA256}"
    echo "======================================================"
    echo ""

    if [[ "$OFFICIAL_ARTIFACT_SHA256" == "$BUILT_ARTIFACT_SHA256" ]]; then
        log_ok "Distributed artifact is byte-for-byte IDENTICAL"
        write_yaml "reproducible" \
            "Rebuilt ZIP is byte-for-byte identical to the released ZIP (${OFFICIAL_ARTIFACT_SHA256}). $(comparison_context_note)"
        return 0
    fi

    local detail
    if [[ "$OFFICIAL_APPIMAGE_SHA256" == "$BUILT_APPIMAGE_SHA256" ]]; then
        detail="The AppImage members match (${OFFICIAL_APPIMAGE_SHA256}); the archives differ elsewhere."
        log_warn "AppImage members match; the ZIPs differ elsewhere"
    else
        detail="The AppImage members also differ: official ${OFFICIAL_APPIMAGE_SHA256}, rebuilt ${BUILT_APPIMAGE_SHA256}."
        log_warn "AppImage members differ too"
    fi
    log_warn "NOT REPRODUCIBLE: official ${OFFICIAL_ARTIFACT_SHA256} vs rebuilt ${BUILT_ARTIFACT_SHA256}"
    write_yaml "not_reproducible" \
        "Rebuilt ZIP differs from the released ZIP: official ${OFFICIAL_ARTIFACT_SHA256}, rebuilt ${BUILT_ARTIFACT_SHA256}. ${detail} $(comparison_context_note)"
    return 1
}

# Tag commit and type (annotated/lightweight) from one ls-remote; sets globals.
resolve_commit() {
    local out ref n
    out="$(git_c ls-remote "https://github.com/${GH_REPO}.git" \
              "refs/tags/${APP_VERSION}^{}" "refs/tags/${APP_VERSION}" 2>/dev/null || true)"
    n="$(printf '%s\n' "$out" | grep -c . || true)"
    ref="$(printf '%s\n' "$out" | awk 'END{print $1}')"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && RESOLVED_COMMIT="$ref" || RESOLVED_COMMIT="unknown"
    if [[ "${n:-0}" -ge 2 ]]; then SIG_TAG_TYPE="annotated"
    elif [[ "${n:-0}" -eq 1 ]]; then SIG_TAG_TYPE="lightweight"
    else SIG_TAG_TYPE="unknown"; fi
}

# Hash legend, printed outside the results block.
print_hash_legend() {
    echo ""
    echo "HASH LEGEND"
    echo "  appHash          sha256 of ${OFFICIAL_ARTIFACT_NAME:-the official artifact} exactly as"
    echo "                   distributed. THIS is the hash to publish — a user reproduces it with"
    echo "                   sha256sum on the file they downloaded."
    echo "  appImageHash     sha256 of the AppImage member inside that artifact. Reported to"
    echo "                   localize a failure; NOT what the verdict is based on. Do not publish."
    echo "  builtAppHash     sha256 of our rebuilt ZIP. From 2.6.6 upstream sets SOURCE_DATE_EPOCH"
    echo "                   and normalizes the AppDir, so this IS expected to equal appHash; that"
    echo "                   equality is the verdict. (Through 2.6.5 it could never match.)"
    echo "  builtAppImageHash sha256 of the AppImage inside our rebuilt ZIP. Localizes a failure."
    echo "  scriptHash       sha256 of this script, identifying which tooling produced these results."
}

# Results block (verification-result-summary-format.md); verdict also in COMPARISON_RESULTS.yaml.
emit_verification_summary() {
    local summary_verdict commit
    # Same value as the YAML: one of reproducible / not_reproducible / ftbfs, nothing else.
    summary_verdict="$(awk '/^verdict:/{print $2}' "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml" 2>/dev/null)"
    [[ "$RESOLVED_COMMIT" == "unknown" ]] && resolve_commit
    commit="$RESOLVED_COMMIT"

    print_hash_legend

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${summary_verdict}"
    echo "appHash:        ${OFFICIAL_ARTIFACT_SHA256:-N/A}"
    echo "officialFile:   ${OFFICIAL_ARTIFACT_NAME:-N/A}"
    echo "appImageHash:   ${OFFICIAL_APPIMAGE_SHA256:-N/A}"
    echo "builtAppHash:   ${BUILT_ARTIFACT_SHA256:-N/A}"
    echo "builtAppImageHash: ${BUILT_APPIMAGE_SHA256:-N/A}"
    echo "commit:         ${commit}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
    echo ""
    echo "Diff:"
    if [[ "$OFFICIAL_ARTIFACT_SHA256" == "$BUILT_ARTIFACT_SHA256" ]]; then
        echo "(none: rebuilt ZIP is byte-for-byte identical to the released ZIP)"
    else
        echo "Released ZIP: ${OFFICIAL_ARTIFACT_SHA256}"
        echo "Rebuilt  ZIP: ${BUILT_ARTIFACT_SHA256}"
        echo "Released AppImage member: ${OFFICIAL_APPIMAGE_SHA256}"
        echo "Rebuilt  AppImage member: ${BUILT_APPIMAGE_SHA256}"
    fi

    echo ""
    echo "Revision, tag (and its signature):"
    echo "tag:            ${APP_VERSION}"
    echo "commit:         ${commit}"
    echo ""
    echo "Signature Summary:"
    echo "Tag type: ${SIG_TAG_TYPE}"
    echo "${SIG_MANIFEST_STATUS}"
    echo "${SIG_DIGEST_STATUS}"
    echo "${SIG_TAG_STATUS}"
    echo "[WARNING] Commit signature not checked by this script"
    echo ""
    echo "Keys used:"
    if [[ -n "$SIG_KEY_USED" ]]; then
        echo "${SIG_KEY_USED}"
    else
        echo "None established"
    fi
    echo ""
    printf 'Warnings:%s\n' "${SIG_WARNINGS:-}"
    echo ""
    echo "===== End Results ====="
}

main() {
    echo ""
    echo "======================================================"
    echo "${APP_NAME} Reproducible Build Verifier ${SCRIPT_VERSION}"
    echo "======================================================"
    echo ""

    # Self-identify first.
    SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"
    # Never let ABS read a verdict left by an earlier run in this directory.
    rm -f "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

    parse_args "$@"
    detect_container_cmd
    setup_workdir

    log_info "Version: ${APP_VERSION}"
    log_info "Arch:    ${APP_ARCH}"
    log_info "Type:    ${APP_TYPE}"
    [[ -n "$BINARY_PATH" ]] && log_info "Binary:  ${BINARY_PATH}"
    echo ""

    prepare_official
    verify_official_signature
    [[ -n "$PROVENANCE_FATAL" ]] && die_provenance "$PROVENANCE_FATAL"
    check_build_inputs

    local verdict_exit=0
    run_build
    compare_artifacts || verdict_exit=$?

    emit_verification_summary

    echo ""
    echo "======================================================"
    echo "RESULTS (machine-readable verdict in COMPARISON_RESULTS.yaml)"
    echo "======================================================"
    cat "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    echo ""
    echo "Work directory: ${WORK_DIR}"
    echo "Rebuilt artifact: ${WORK_DIR}/built.zip"
    echo "======================================================"
    echo ""

    exit "$verdict_exit"
}

main "$@"
