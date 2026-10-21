#!/bin/bash
#
# nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verifier
# Version: v0.2.1
# Last modified by: Danny Garcia, Carol (Buzz), Claude Code
# Last modified on: 2026-10-21
# Organization: WalletScrutiny.com
#
# Rebuilds the Linux x86_64 AppImage with upstream's reproducible-builds/ recipe at the release tag
# (2.9.1+) and compares it byte for byte with the released AppImage. Upstream's Dockerfile.linux is
# built unmodified: it pins its own base image (digest), apt snapshot, toolchain and HWI download.
# For 2.6.6 and 2.9.0 (ZIP releases) use v0.1.16.
#
# Usage: nunchukdesktop_build.sh --version VERSION [--binary APPIMAGE] [--arch x86_64-linux-gnu] [--type appimage]
# Host needs only podman, or docker with buildx. wget, gpg, cmp, diff and unsquashfs run in containers.
#

set -euo pipefail

SCRIPT_VERSION="v0.2.1"
APP_ID="nunchuk"
APP_NAME="Nunchuk Desktop"
GH_REPO="nunchuk-io/nunchuk-desktop"
MIN_VERSION="2.9.1"

EXIT_OK=0
EXIT_DIFF=1
EXIT_INVALID=2

APP_VERSION=""
APP_ARCH="x86_64-linux-gnu"
APP_TYPE="appimage"
BINARY_PATH=""
CONTAINER_CMD=""
# Image build command: `podman build` (buildah) or `docker buildx build --load`. Both set TARGETARCH
# from --platform and support ADD --checksum, which upstream's Dockerfile needs; legacy `docker build` does not.
BUILD_CMD=()
# Digest-pinned git image: clones and resolves the tag inside a container.
GIT_IMAGE="${GIT_IMAGE:-docker.io/alpine/git@sha256:6f8eae2205a85c51106a9650e574a37fb1d5e4f645e5f6ea57cb57b9462cd4cf}"
WORK_DIR=""
IMAGE_NAME=""
# --user for tool containers under rootful engines (rootless: container root is the caller).
TOOLS_USER=()
# apt repeats this line millions of times while snapshot.ubuntu.com fails; dropped from the log.
APT_NOISE="Tried to start delayed item"
ADD_CHECKSUM_FALLBACK=false
ADD_REWRITES=""
DIFF_FILE=""
DIFF_COUNT=""
DIFF_PREVIEW=""
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
VERDICT_WRITTEN=false
NO_VERDICT_BY_DESIGN=false

# Pins read from upstream's recipe at the tag; reported, never overridden.
UPSTREAM_DOCKERFILE_SHA256=""
PIN_BASE_IMAGE=""
PIN_UBUNTU_SNAPSHOT=""
PIN_HWI_VERSION=""
PIN_HWI_COMMIT=""
PIN_HWI_SHA256=""
BUNDLED_HWI_SHA256=""

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

# The released AppImage is both the distributed file and the compared payload.
OFFICIAL_ARTIFACT_NAME=""
OFFICIAL_ARTIFACT_SHA256=""
BUILT_ARTIFACT_SHA256=""

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

# Run a tool from the pinned git image (BusyBox wget/cmp/od, GnuPG) against WORK_DIR at /w.
tools_c() {
    local tool="$1"; shift
    "$CONTAINER_CMD" run --rm "${TOOLS_USER[@]}" -e GITHUB_TOKEN -v "${WORK_DIR}:/w" -w /w \
        --entrypoint "$tool" "$GIT_IMAGE" "$@"
}

# --no-autostart: the image has no gpg-agent, and without it --import exits 2 on a fresh homedir.
gpg_c() { tools_c gpg --homedir /w/gnupg --no-autostart "$@"; }

# Download into WORK_DIR. GitHub hosts: token first, then anonymous (an expired ABS token makes
# GitHub answer 404). Any other host never sees the token.
gh_wget() {
    local rel="${1#"${WORK_DIR}"/}" url="$2"
    case "$url" in
        https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*) ;;
        *) GITHUB_TOKEN="" tools_c wget -q -O "$rel" "$url" 2>/dev/null; return ;;
    esac
    # shellcheck disable=SC2016
    tools_c sh -c 'if [ -n "${GITHUB_TOKEN:-}" ]; then
            wget -q --header="Authorization: token ${GITHUB_TOKEN}" -O "$1" "$2" 2>/dev/null && exit 0
            echo "[WARN] Token download failed, retrying anonymously: $2"
        fi
        wget -q -O "$1" "$2" 2>/dev/null' sh "$rel" "$url"
}

sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

comparison_context_note() {
    printf '%s' "Built with upstream reproducible-builds/Dockerfile.linux (sha256 ${UPSTREAM_DOCKERFILE_SHA256}, ${ADD_REWRITES:+ADD->COPY rewrite below, otherwise }unmodified) and build_linux.sh at tag ${APP_VERSION}, commit ${RESOLVED_COMMIT}. Upstream pins: base ${PIN_BASE_IMAGE}, apt snapshot ${PIN_UBUNTU_SNAPSHOT}, prebuilt HWI ${PIN_HWI_VERSION} (source commit ${PIN_HWI_COMMIT}, archive sha256 ${PIN_HWI_SHA256})${BUNDLED_HWI_SHA256:+, bundled hwi sha256 ${BUNDLED_HWI_SHA256}}.${ADD_REWRITES:+ Builder lacks ADD --checksum, so these ADDs became COPY of the same checksum-verified bytes: ${ADD_REWRITES}.}"
}

detect_container_cmd() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        BUILD_CMD=(podman build --format docker)
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        docker buildx version >/dev/null 2>&1 \
            || die_invalid "docker found but buildx is missing; upstream's Dockerfile needs BuildKit (TARGETARCH, ADD --checksum). Install docker-buildx or podman."
        BUILD_CMD=(docker buildx build --load)
    else
        die_invalid "Neither podman nor docker found in PATH. Install one and retry."
    fi
    is_rootless || TOOLS_USER=(--user "$(id -u):$(id -g)")
    log_info "Container runtime: ${CONTAINER_CMD}; image builds with: ${BUILD_CMD[*]}"
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
    # Same tag shape upstream's build_linux.sh accepts.
    if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
        die_invalid "Invalid --version '${APP_VERSION}' (expected e.g. 2.9.1, no v prefix)"
    fi

    # Only x86_64-linux-gnu / appimage is implemented.
    if [[ "$APP_ARCH" != "x86_64-linux-gnu" ]]; then
        die_invalid "Unsupported --arch '${APP_ARCH}'; only x86_64-linux-gnu is implemented"
    fi
    if [[ "$APP_TYPE" != "appimage" ]]; then
        die_invalid "Unsupported --type '${APP_TYPE}'; only appimage is implemented"
    fi

    # 2.9.1 is the first release with a pinned recipe and a bare AppImage asset.
    if [[ "$(printf '%s\n' "$MIN_VERSION" "$APP_VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]]; then
        die_invalid "Version ${APP_VERSION} predates ${MIN_VERSION}; use nunchukdesktop-v0.1.16_build.sh for 2.6.6 and 2.9.0"
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
  --version VERSION    App version without v prefix, 2.9.1 or later (e.g. 2.9.1)

OPTIONAL:
  --binary FILE        Official release AppImage (skip GitHub download)
  --arch ARCH          x86_64-linux-gnu (default, only supported value)
  --type TYPE          appimage (default, only supported value)

OPTIONAL ENVIRONMENT:
  GITHUB_TOKEN          Used for GitHub downloads, to avoid rate limiting
  SNAPSHOT_WAIT_MIN     Minutes to wait for snapshot.ubuntu.com before giving up (default 120)

REQUIREMENTS:
  podman, or docker with buildx; nothing else (tools run in containers).
  Run as a normal user, not root.

EXAMPLES:
  nunchukdesktop_build.sh --version 2.9.1
  nunchukdesktop_build.sh --version 2.9.1 --binary ~/Downloads/nunchuk-linux-v2.9.1-x86_64.AppImage

EXIT CODES:
  0  Identical (rebuilt AppImage byte-for-byte equal to the released AppImage)
  1  Differences found or build failed
  2  Invalid parameters

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/built.AppImage  (the rebuilt artifact)

For 2.6.6 and 2.9.0 (released as ZIPs) use nunchukdesktop-v0.1.16_build.sh.
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
        "$CONTAINER_CMD" rmi "$IMAGE_NAME" "${IMAGE_NAME}-preflight" > /dev/null 2>&1
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
    log_info "Verifying release manifest signature (gpg in a container)..."

    if ! gh_wget "$sums" "$sums_url"; then
        sig_skip "SHA256SUMS not published for ${APP_VERSION}" \
                 "No SHA256SUMS asset was retrievable for ${APP_VERSION}."
        return 0
    fi
    if ! gh_wget "$asc" "${sums_url}.asc"; then
        sig_skip "SHA256SUMS.asc not published for ${APP_VERSION}" \
                 "SHA256SUMS was published but SHA256SUMS.asc was not; the manifest is unsigned as far as this run established."
        check_digest_against_manifest "$sums" "unsigned"
        return 0
    fi

    # Throwaway keyring: a locally trusted key must not silently make this pass.
    local gnupg_home="${WORK_DIR}/gnupg"
    mkdir -p "$gnupg_home"; chmod 700 "$gnupg_home"

    # Plain HTTPS from keyserver.ubuntu.com (no dirmngr; keys.openpgp.org strips user IDs).
    local imported=false fprs=""
    local keyfile="${WORK_DIR}/release-key.asc"
    local src="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${NUNCHUK_RELEASE_KEY_FPR}"
    if tools_c wget -q -T 60 -O release-key.asc "$src" 2>/dev/null \
            && grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$keyfile" 2>/dev/null \
            && gpg_c --batch --quiet --import /w/release-key.asc >/dev/null 2>&1 \
            && fprs="$(gpg_c --batch --with-colons --fingerprint 2>/dev/null)" \
            && grep -q "^fpr:::::::::${NUNCHUK_RELEASE_KEY_FPR}:" <<<"$fprs"; then
        imported=true
        log_ok "Release key ${NUNCHUK_RELEASE_KEY_FPR} imported"
    fi
    if [[ "$imported" != true ]]; then
        sig_skip "Release key ${NUNCHUK_RELEASE_KEY_FPR} could not be retrieved" \
                 "The pinned release key could not be fetched (offline or blocked); signature not verified."
        check_digest_against_manifest "$sums" "unverified"
        return 0
    fi

    # Clearsigned through 2.6.6, detached from 2.9.0: decide by the armor header, not by trying
    # --decrypt first (on a detached .asc it verifies the neighbouring file and still says GOODSIG).
    local gpg_out="" gpg_rc=0 sig_form="detached"
    local verified_manifest="${WORK_DIR}/SHA256SUMS.verified"

    if grep -q "^-----BEGIN PGP SIGNED MESSAGE-----" "$asc"; then
        sig_form="clearsigned"
        gpg_out="$(gpg_c --batch --yes --status-fd 1 --output /w/SHA256SUMS.verified \
                      --decrypt /w/SHA256SUMS.asc 2>/dev/null)" || gpg_rc=$?
    else
        gpg_out="$(gpg_c --batch --status-fd 1 \
                      --verify /w/SHA256SUMS.asc /w/SHA256SUMS 2>/dev/null)" || gpg_rc=$?
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
    elif grep -q "^\[GNUPG:\] ERRSIG " <<<"$gpg_out"; then
        # Signer not in the throwaway keyring: ERRSIG has the key id in field 3, fingerprint last.
        local eline unk
        eline="$(grep -m1 "^\[GNUPG:\] ERRSIG " <<<"$gpg_out")"
        unk="$(awk '{print $NF}' <<<"$eline")"
        [[ "$unk" =~ ^[0-9A-Fa-f]{40}$ ]] || unk="$(awk '{print $3}' <<<"$eline")"
        SIG_MANIFEST_STATUS="[WARNING] SHA256SUMS ${sig_form} signature is from unknown key ${unk}, not the pinned ${NUNCHUK_RELEASE_KEY_FPR}"
        SIG_KEY_USED="Manifest signed with: ${unk} (not in keyring; signature could not be verified)"
        add_sig_warning "The manifest is signed by key ${unk}, which is not the pinned release key and could not be fetched. Treat the key as rotated or the artifact as suspect until upstream publishes the new key."
        log_warn "SHA256SUMS signed by unknown key ${unk}; the pinned key did not sign it"
        check_digest_against_manifest "$sums" "unverified"
    else
        SIG_MANIFEST_STATUS="[WARNING] No valid signature on SHA256SUMS"
        add_sig_warning "gpg reported no valid signature over the release manifest."
        log_warn "No valid signature on SHA256SUMS"
        check_digest_against_manifest "$sums" "unverified"
    fi

    # Any clearsigned run, whoever signed: flag a split between unsigned asset and signed payload.
    if [[ "$sig_form" == "clearsigned" && -s "$verified_manifest" ]] \
            && [[ "$(sha256_of "$sums")" != "$(sha256_of "$verified_manifest")" ]]; then
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

# /project must appear as the caller's UID, as under rootful Docker.
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

# Release and build-output name from 2.9.1: nunchuk-linux-v<V>-x86_64(.AppImage).
artifact_stem() {
    printf 'nunchuk-linux-v%s-x86_64' "$APP_VERSION"
}

prepare_official() {
    # Official AppImage: --binary or GitHub download. appHash = this file, as distributed.
    local official="${WORK_DIR}/official.AppImage"

    if [[ -n "$BINARY_PATH" ]]; then
        OFFICIAL_ARTIFACT_NAME="$(basename "$BINARY_PATH")"
        [[ "$OFFICIAL_ARTIFACT_NAME" == *.AppImage ]] \
            || die_invalid "--binary must be the released .AppImage, got: ${OFFICIAL_ARTIFACT_NAME}"
        log_info "Using provided binary: ${OFFICIAL_ARTIFACT_NAME}"
        cp "$BINARY_PATH" "$official"
    else
        OFFICIAL_ARTIFACT_NAME="$(artifact_stem).AppImage"
        local dl_url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/${OFFICIAL_ARTIFACT_NAME}"
        log_info "Downloading official release: $dl_url"
        if ! gh_wget "$official" "$dl_url"; then
            die_build "Failed to download: $dl_url"
        fi
    fi
    OFFICIAL_ARTIFACT_SHA256="$(sha256_of "$official")"
    log_ok "Official artifact: ${OFFICIAL_ARTIFACT_NAME} ($(stat -c%s "$official") bytes)"
    log_ok "  sha256: ${OFFICIAL_ARTIFACT_SHA256}"
}

# The pins upstream's recipe declares, read for the report (the build uses them as-is).
read_upstream_pins() {
    local rb="$1/reproducible-builds" lock
    PIN_BASE_IMAGE="$(sed -nE 's/^ARG UBUNTU_IMAGE=([^[:space:]]+).*/\1/p' "${rb}/Dockerfile.linux" | head -1)"
    PIN_UBUNTU_SNAPSHOT="$(sed -nE 's/^ARG UBUNTU_SNAPSHOT=([^[:space:]]+).*/\1/p' "${rb}/Dockerfile.linux" | head -1)"
    lock="${rb}/hwi.lock.env"
    if [[ -f "$lock" ]]; then
        PIN_HWI_VERSION="$(sed -nE 's/^HWI_VERSION=([^[:space:]]+).*/\1/p' "$lock" | head -1)"
        PIN_HWI_COMMIT="$(sed -nE 's/^HWI_COMMIT=([0-9a-f]{40}).*/\1/p' "$lock" | head -1)"
        PIN_HWI_SHA256="$(sed -nE 's/^HWI_LINUX_X86_64_SHA256=([0-9a-f]{64}).*/\1/p' "$lock" | head -1)"
    fi
    [[ "$PIN_BASE_IMAGE" == *@sha256:* ]] \
        || log_warn "Upstream base image is not digest-pinned: ${PIN_BASE_IMAGE:-not found}"
    [[ "$PIN_UBUNTU_SNAPSHOT" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] \
        || log_warn "Upstream apt snapshot not found or malformed: ${PIN_UBUNTU_SNAPSHOT:-not found}"
    [[ -n "$PIN_HWI_SHA256" ]] \
        || log_warn "Upstream HWI pin (hwi.lock.env) not found"
    log_info "Upstream pins: base ${PIN_BASE_IMAGE:-?}"
    log_info "               apt snapshot ${PIN_UBUNTU_SNAPSHOT:-?}"
    log_info "               HWI ${PIN_HWI_VERSION:-?} prebuilt, archive sha256 ${PIN_HWI_SHA256:-?} (source commit ${PIN_HWI_COMMIT:-?})"
}

# Probe one Dockerfile on this builder; true if it builds.
probe_builder() {
    local d="${WORK_DIR}/preflight"
    mkdir -p "$d"
    printf '%s\n' "$@" > "${d}/Dockerfile"
    "${BUILD_CMD[@]}" --platform linux/amd64 -t "${IMAGE_NAME}-preflight" "$d" >> "${d}/build.log" 2>&1 || return 1
    "$CONTAINER_CMD" rmi "${IMAGE_NAME}-preflight" > /dev/null 2>&1 || true
}

# Upstream's Dockerfile needs TARGETARCH (fatal without) and ADD --checksum (podman < 5 lacks it:
# then each such ADD becomes a COPY of the same bytes, fetched and checked against that checksum first).
preflight_builder() {
    local sum
    sum="$(sha256_of "${WORK_DIR}/src/README.md")"
    probe_builder "FROM ${GIT_IMAGE}" "ARG TARGETARCH" 'RUN test "$TARGETARCH" = amd64' \
        || die_build "This builder ($("$CONTAINER_CMD" --version)) does not set TARGETARCH, which upstream's Dockerfile needs. Environment problem, not a build result."
    if probe_builder "FROM ${GIT_IMAGE}" \
            "ADD --checksum=sha256:${sum} https://raw.githubusercontent.com/${GH_REPO}/${RESOLVED_COMMIT}/README.md /readme"; then
        log_ok "Builder supports TARGETARCH and ADD --checksum ($("$CONTAINER_CMD" --version))"
    else
        ADD_CHECKSUM_FALLBACK=true
        log_warn "Builder ($("$CONTAINER_CMD" --version)) lacks ADD --checksum: checksum-verified COPY fallback"
    fi
}

# Copy of the Dockerfile with each ADD --checksum=sha256:H URL DEST replaced by COPY of a file we
# fetched and checked against H. ${VAR} in URLs comes from the Dockerfile's own ARG defaults.
rewrite_add_checksum() {
    local df="$1" out="$2" ctx="$3" line block="" h url dest var val rel n=0
    : > "$out"
    mkdir -p "${ctx}/ws-add-checksum"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Only ADD --checksum blocks are joined and rewritten; every other line is copied as is.
        if [[ -z "$block" && ! "$line" =~ ^ADD[[:space:]]+--checksum= ]]; then
            printf '%s\n' "$line" >> "$out"; continue
        fi
        block="${block}${block:+ }${line%\\}"
        [[ "$line" == *\\ ]] && continue
        read -r -a parts <<<"$block"; block=""
        [[ ${#parts[@]} -eq 4 && "${parts[1]}" =~ ^--checksum=sha256:([0-9a-f]{64})$ && "${parts[2]}" == https://* ]] \
            || die_build "Unsupported ADD --checksum form in upstream's Dockerfile: ${parts[*]}"
        h="${BASH_REMATCH[1]}"; url="${parts[2]}"; dest="${parts[3]}"
        while [[ "$url" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
            var="${BASH_REMATCH[1]}"
            val="$(sed -nE "s/^ARG ${var}=([^[:space:]]+).*/\1/p" "$df" | head -1)"
            [[ -n "$val" ]] || die_build "ADD --checksum URL uses \${${var}} with no ARG default"
            url="${url//\$\{${var}\}/${val}}"
        done
        rel="ws-add-checksum/${h}"
        gh_wget "${ctx}/${rel}" "$url" \
            || die_build "Could not fetch ${url} for the ADD --checksum fallback${url/*snapshot.ubuntu.com*/: snapshot.ubuntu.com outage, not a build result; re-run later, do not publish this ftbfs}"
        [[ "$(sha256_of "${ctx}/${rel}")" == "$h" ]] || die_build "Checksum mismatch for ${url} (expected ${h})"
        printf 'COPY %s %s\n' "$rel" "$dest" >> "$out"
        ADD_REWRITES="${ADD_REWRITES}${ADD_REWRITES:+; }${url} (sha256 ${h})"
        n=$((n + 1))
    done < "$df"
    log_ok "ADD --checksum fallback: ${n} line(s) now COPY checksum-verified bytes"
}

# snapshot.ubuntu.com has outages: wait for upstream's pinned snapshot before the long build
# (every 5 min, up to SNAPSHOT_WAIT_MIN minutes, default 120) instead of failing mid-build.
wait_for_snapshot() {
    [[ -n "$PIN_UBUNTU_SNAPSHOT" ]] || return 0
    local url="https://snapshot.ubuntu.com/ubuntu/${PIN_UBUNTU_SNAPSHOT}/dists/noble/Release"
    local limit=$(( ${SNAPSHOT_WAIT_MIN:-120} * 60 )) waited=0
    until tools_c wget -q -T 30 --spider "$url" 2>/dev/null; do
        if [[ "$waited" -ge "$limit" ]]; then
            die_build "snapshot.ubuntu.com did not serve ${PIN_UBUNTU_SNAPSHOT} for ${SNAPSHOT_WAIT_MIN:-120} min. Mirror outage, not a build result: re-run later, do not publish this ftbfs."
        fi
        log_warn "snapshot.ubuntu.com not serving ${PIN_UBUNTU_SNAPSHOT} yet; retry in 5 min (${waited}s of ${limit}s waited)"
        sleep 300; waited=$((waited + 300))
    done
    log_ok "snapshot.ubuntu.com serves ${PIN_UBUNTU_SNAPSHOT}"
}

run_build() {
    # Upstream's README: build Dockerfile.linux from the checkout, run it with the source at /project.
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

    local dockerfile="${src}/reproducible-builds/Dockerfile.linux"
    [[ -f "$dockerfile" ]] || die_build "Upstream reproducible-builds/Dockerfile.linux not found at tag ${APP_VERSION}"
    UPSTREAM_DOCKERFILE_SHA256="$(sha256_of "$dockerfile")"
    log_info "Upstream Dockerfile.linux sha256: ${UPSTREAM_DOCKERFILE_SHA256}"
    read_upstream_pins "$src"

    IMAGE_NAME="nunchuk-verifier-${APP_VERSION}-$(date +%s)-$$"
    preflight_builder
    wait_for_snapshot
    local build_df="$dockerfile"
    if [[ "$ADD_CHECKSUM_FALLBACK" == true ]]; then
        build_df="${WORK_DIR}/Dockerfile.linux.copy-fallback"
        rewrite_add_checksum "$dockerfile" "$build_df" "$src"
    fi
    log_info "Building upstream image -- 20-40 min on first run..."
    local attempt rc n5 image_built=false build_log="${WORK_DIR}/image-build.log"
    for attempt in 1 2 3; do
        # Completed layers are cached, so a retry resumes at the failed step.
        set +e
        "${BUILD_CMD[@]}" --platform linux/amd64 -t "$IMAGE_NAME" -f "$build_df" "$src" 2>&1 \
            | awk -v f="$APT_NOISE" 'index($0, f) {n++; next} {print; fflush()}
                  END {if (n) printf "[filtered %d lines: %s]\n", n, f}' \
            | tee -a "$build_log"
        rc="${PIPESTATUS[0]}"
        set -e
        if [[ "$rc" -eq 0 ]]; then image_built=true; break; fi
        log_warn "Image build attempt ${attempt}/3 failed (snapshot.ubuntu.com and the Qt mirrors fail transiently)"
        [[ "$attempt" -lt 3 ]] && sleep 60
    done
    if [[ "$image_built" != true ]]; then
        # A mirror outage is not a build result: name it so nobody publishes this ftbfs as one.
        n5="$(grep -cE '(^|[[:space:]])5[0-9]{2}[[:space:]]+(Service Unavailable|Bad Gateway|Gateway Time-?out|Internal Server Error)' "$build_log" || true)"
        if [[ "${n5:-0}" -gt 0 ]] && grep -q 'snapshot\.ubuntu\.com' "$build_log"; then
            die_build "Container image build failed after 3 attempts: snapshot.ubuntu.com answered HTTP 5xx (${n5} log lines). Mirror outage, not a build result: re-run later, do not publish this ftbfs."
        fi
        die_build "Container image build failed after 3 attempts"
    fi

    rm -rf "${src}/ws-add-checksum"
    # Ownership set after the image build, which reads the context as the host user.
    log_info "Setting build ownership so /project matches upstream's rootful-Docker semantics..."
    set_build_owner "${WORK_DIR}"

    log_info "Running upstream build_linux.sh inside the container..."
    if ! "$CONTAINER_CMD" run --platform linux/amd64 --rm \
            -e TAG="${APP_VERSION}" -v "${src}:/project" -w /project \
            "$IMAGE_NAME" bash ./reproducible-builds/build_linux.sh; then
        restore_host_owner "${WORK_DIR}"
        die_build "Containerized upstream build failed"
    fi
    restore_host_owner "${WORK_DIR}"
    "$CONTAINER_CMD" rmi "$IMAGE_NAME" > /dev/null 2>&1 || true
    IMAGE_NAME=""

    local out; out="${src}/$(artifact_stem)/$(artifact_stem).AppImage"
    [[ -f "$out" ]] || die_build "Upstream build produced no AppImage at ${out}"
    cp "$out" "${WORK_DIR}/built.AppImage"
    BUNDLED_HWI_SHA256="$(sha256_of "${src}/$(artifact_stem)/Appdir/usr/bin/hwi")"
    [[ "$BUNDLED_HWI_SHA256" == "N/A" ]] && BUNDLED_HWI_SHA256=""

    BUILT_ARTIFACT_SHA256="$(sha256_of "${WORK_DIR}/built.AppImage")"
    log_ok "Built artifact: $(artifact_stem).AppImage ($(stat -c%s "${WORK_DIR}/built.AppImage") bytes)"
    log_ok "  sha256: ${BUILT_ARTIFACT_SHA256}"
}

# Unpack both AppImages (squashfs after the ELF runtime) and diff the trees. Evidence only:
# the verdict stays the byte comparison. squashfs-tools/diffutils come from the image's Alpine repo.
diff_appimages() {
    DIFF_FILE="${WORK_DIR}/diff_full.txt"
    # shellcheck disable=SC2016
    "$CONTAINER_CMD" run --rm -v "${WORK_DIR}:/w" -w /w --entrypoint sh "$GIT_IMAGE" -c 'set -e
        apk add --no-cache -q squashfs-tools diffutils > /dev/null
        for n in official built; do
            f="$n.AppImage"
            o=$(( $(od -An -tu8 -j40 -N8 "$f") + $(od -An -tu2 -j58 -N2 "$f") * $(od -An -tu2 -j60 -N2 "$f") ))
            [ "$(tail -c +$((o + 1)) "$f" | head -c 4)" = hsqs ] || { echo "no squashfs at offset $o in $f" >&2; exit 3; }
            rm -rf "$n-extract"
            unsquashfs -q -n -no-xattrs -o "$o" -d "$n-extract" "$f" > /dev/null
        done
        diff -r --no-dereference official-extract built-extract > diff_full.txt || [ $? -eq 1 ]' \
        || { DIFF_FILE=""; return 1; }
    DIFF_COUNT="$(grep -cE '^(Binary files|Only in|diff |Symbolic links|File )' "$DIFF_FILE" || true)"
    DIFF_PREVIEW="$(head -n 5 "$DIFF_FILE")"
}

compare_artifacts() {
    # Verdict = the whole AppImage byte for byte; nothing else can pass.
    echo ""
    echo "======================================================"
    echo "ARTIFACT COMPARISON (whole AppImage, byte for byte)"
    echo "======================================================"
    echo "Official: ${OFFICIAL_ARTIFACT_NAME}"
    echo "  ${OFFICIAL_ARTIFACT_SHA256}"
    echo "Rebuilt:  $(artifact_stem).AppImage"
    echo "  ${BUILT_ARTIFACT_SHA256}"
    echo "======================================================"
    echo ""

    if [[ "$OFFICIAL_ARTIFACT_SHA256" == "$BUILT_ARTIFACT_SHA256" ]]; then
        log_ok "Distributed artifact is byte-for-byte IDENTICAL"
        write_yaml "reproducible" \
            "Rebuilt AppImage is byte-for-byte identical to the released AppImage (${OFFICIAL_ARTIFACT_SHA256}). $(comparison_context_note)"
        return 0
    fi

    local ndiff files_note="the unpacked trees could not be diffed"
    # Counted inside the container: one line per differing byte is too much to stream out.
    # shellcheck disable=SC2016
    ndiff="$(tools_c sh -c 'cmp -l official.AppImage built.AppImage 2>/dev/null | wc -l' || true)"
    ndiff="${ndiff//[^0-9]/}"
    log_warn "NOT REPRODUCIBLE: official ${OFFICIAL_ARTIFACT_SHA256} vs rebuilt ${BUILT_ARTIFACT_SHA256} (${ndiff} differing bytes over the common length)"
    log_info "Unpacking both AppImages to diff their contents..."
    if diff_appimages; then
        files_note="${DIFF_COUNT} differing entries in the unpacked AppImages (full list: diff_full.txt in the workspace)"
        log_warn "${DIFF_COUNT} differing entries; full diff: ${DIFF_FILE}"
    else
        log_warn "Could not unpack/diff the AppImages; the byte comparison still decides the verdict"
    fi
    write_yaml "not_reproducible" \
        "Rebuilt AppImage differs from the released AppImage: official ${OFFICIAL_ARTIFACT_SHA256}, rebuilt ${BUILT_ARTIFACT_SHA256}, ${ndiff} differing bytes over the common length; ${files_note}. $(comparison_context_note)"
    return 1
}

# Hash legend, printed outside the results block.
print_hash_legend() {
    echo ""
    echo "HASH LEGEND"
    echo "  appHash          sha256 of ${OFFICIAL_ARTIFACT_NAME:-the official artifact} as distributed."
    echo "                   THIS is the hash to publish (sha256sum of the downloaded file)."
    echo "  builtAppHash     sha256 of our rebuilt AppImage; equality with appHash is the verdict."
    echo "  scriptHash       sha256 of this script, identifying the tooling behind these results."
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
    echo "builtAppHash:   ${BUILT_ARTIFACT_SHA256:-N/A}"
    echo "commit:         ${commit}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
    echo ""
    echo "Diff:"
    if [[ "$OFFICIAL_ARTIFACT_SHA256" == "$BUILT_ARTIFACT_SHA256" ]]; then
        echo "(none: rebuilt AppImage is byte-for-byte identical to the released AppImage)"
    else
        echo "Released AppImage: ${OFFICIAL_ARTIFACT_SHA256}"
        echo "Rebuilt  AppImage: ${BUILT_ARTIFACT_SHA256}"
        if [[ -n "$DIFF_FILE" ]]; then
            echo "Differing entries: ${DIFF_COUNT} (first 5 diff lines below)"
            printf '%s\n' "$DIFF_PREVIEW"
            echo "Full diff: ${DIFF_FILE}"
        fi
    fi
    echo ""
    echo "Upstream pins (from the recipe at the tag):"
    echo "Dockerfile.linux: ${UPSTREAM_DOCKERFILE_SHA256:-N/A}"
    [[ -z "$ADD_REWRITES" ]] || echo "ADD->COPY:      ${ADD_REWRITES}"
    echo "base image:     ${PIN_BASE_IMAGE:-N/A}"
    echo "apt snapshot:   ${PIN_UBUNTU_SNAPSHOT:-N/A}"
    echo "HWI:            ${PIN_HWI_VERSION:-N/A} prebuilt, archive sha256 ${PIN_HWI_SHA256:-N/A}, bundled hwi sha256 ${BUNDLED_HWI_SHA256:-N/A}"

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
    [[ "$(id -u)" -ne 0 ]] || die_invalid "Do not run as root: run as a normal user (rootless podman, or docker group)"
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
    echo "Rebuilt artifact: ${WORK_DIR}/built.AppImage"
    echo "======================================================"
    echo ""

    exit "$verdict_exit"
}

main "$@"
