#!/bin/bash
#
# nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verifier
#
# Version: v0.1.11
#
# Description:
#   Reproducible build verification for Nunchuk Desktop (Linux x86_64 AppImage).
#   Builds from source using UPSTREAM'S OWN committed recipe -- reproducible-builds/
#   Dockerfile.linux and build_linux.sh at the release tag, source bind-mounted at /project --
#   exactly as reproducible-builds/README.md instructs verifiers, then compares the result
#   against the official release.
#
#   From 2.6.6 the verdict is the WHOLE ZIP, byte for byte. Upstream derives SOURCE_DATE_EPOCH
#   from the tag commit, normalizes every AppDir timestamp and permission, pins the AppImage
#   runtime and appimagetool (1.9.1) by sha256, and zips under TZ=UTC. Through 2.6.5 this was
#   impossible -- appimagetool stamped wall-clock time into the squashfs superblock -- and only
#   extracted contents could be compared. That extracted comparison is GONE: it discards the very
#   packing and runtime bytes a reproducibility claim is about, so it can never produce a pass.
#
#   2.6.6 also deleted the three compile-time OAUTH_* defines (social login moved to the system
#   browser), removing the one input a third-party verifier could not supply.
#
#   OWNERSHIP IS VERDICT-CRITICAL. Upstream's recipe assumes rootful Docker, where a host-owned
#   checkout appears inside the container as the host user's UID. Under rootless Podman it appears
#   as UID 0, and that alone changes the compiled bytes. The checkout is therefore chowned to the
#   caller's UID before the build and handed back afterwards, so the work directory stays
#   removable by an ordinary user. Evidence: changelog v0.1.11.
#
#   The distributed artifact is a ZIP wrapping the AppImage, so two hashes are meaningful.
#   appHash is the artifact EXACTLY AS DOWNLOADED (the ZIP) per
#   verification-result-summary-format.md; the AppImage's own hash is printed alongside it as
#   the payload compared. See the hash legend printed before the results block.
#
#   Provenance is checked in-script: the SHA256SUMS signature is verified against a PINNED
#   release-key fingerprint, and the measured digest cross-checked against that signed
#   manifest. Both are verdict-neutral.
#
# Usage:
#   nunchukdesktop_build.sh --version VERSION [--arch ARCH] [--type TYPE] [--binary FILE]
#
# Required:
#   --version VERSION    App version without v prefix (e.g. 1.9.50)
#
# Optional:
#   --binary FILE        Path to the official release ZIP (skips download)
#   --arch ARCH          Architecture (only x86_64-linux-gnu supported; default)
#   --type TYPE          Build type (only appimage supported; default)
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
# Changelog: ~/work/ws-notes/script-notes/desktop/nunchuk/changelog.md
#

set -euo pipefail

SCRIPT_VERSION="v0.1.11"
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
# Clone runs in this image so podman/docker stays the only host dependency (ABS rule).
# Digest-pinned: this image both creates the checkout and answers ls-remote, so a mutable
# tag could fabricate both. Its entrypoint IS git, so arguments are git subcommands.
GIT_IMAGE="${GIT_IMAGE:-docker.io/alpine/git@sha256:6f8eae2205a85c51106a9650e574a37fb1d5e4f645e5f6ea57cb57b9462cd4cf}"
WORK_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
UPSTREAM_DOCKERFILE_SHA256=""

# Release-manifest signature verification. The fingerprint is PINNED: a good signature from some
# other key is not a pass. Authority for this fingerprint is upstream's own nunchuk-io/docs
# repository, so it establishes continuity of control, not identity — see the report limitation.
NUNCHUK_RELEASE_KEY_FPR="8C8ECD3F660CA53CD878792A6E38A462ED2EF525"
SIG_MANIFEST_STATUS="[WARNING] Manifest signature not checked"
SIG_DIGEST_STATUS="[WARNING] Digest not checked against a signed manifest"
SIG_KEY_USED=""
SIG_TAG_TYPE="unknown"
RESOLVED_COMMIT="unknown"
SIG_TAG_STATUS="[WARNING] Tag signature not checked by this script"
SIG_WARNINGS=""
PROVENANCE_FATAL=""

# Artifact identity. OFFICIAL_ARTIFACT_* describes the file exactly as distributed (the release
# ZIP, or whatever --binary pointed at); OFFICIAL_APPIMAGE_SHA256 is the payload actually compared.
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

# The manifest carries a good signature from the pinned key, and the artifact we downloaded is NOT
# the one it covers. No verdict about that file could be honest, and no allowed verdict means "could
# not validly check" — so emit NO COMPARISON_RESULTS.yaml and REMOVE any stale one. ABS treats a
# missing/verdict-less YAML as publish-nothing (verifications.mjs:873-877) and searches recursively,
# so a leftover from an earlier run would otherwise be published in this run's name.
die_provenance() {
    log_error "PROVENANCE FAILURE: $1"
    log_error "No verdict is emitted: the artifact compared is not the file upstream signed."
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
    log_info "COMPARISON_RESULTS.yaml written to: $yaml_file"
}

sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

check_build_inputs() {
    # 2.6.6 deleted the three compile-time OAUTH_* defines, so there is no longer an input this
    # script cannot supply. Rationale: changelog v0.1.10.
    log_info "No compile-time secrets required: upstream removed the OAuth defines at 2.6.6."
}

comparison_context_note() {
    printf '%s' "Built with upstream reproducible-builds/Dockerfile.linux and build_linux.sh at tag ${APP_VERSION} (Dockerfile sha256 ${UPSTREAM_DOCKERFILE_SHA256})."
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

    # Reject recognized-but-unsupported arch/type so a wrong combo can't masquerade as a
    # Linux AppImage result. Only x86_64-linux-gnu/appimage is implemented (Windows/macOS
    # are separate, not-yet-supported targets).
    if [[ "$APP_ARCH" != "x86_64-linux-gnu" ]]; then
        die_invalid "Unsupported --arch '${APP_ARCH}'; only x86_64-linux-gnu is implemented"
    fi
    if [[ "$APP_TYPE" != "appimage" ]]; then
        die_invalid "Unsupported --type '${APP_TYPE}'; only appimage is implemented"

    fi

    # 2.6.6 is the first release this script can verify: it is where upstream set SOURCE_DATE_EPOCH
    # and deleted the compile-time OAUTH_* defines. Earlier tags need the input handling removed in
    # v0.1.10, so a run against them would apply logic that cannot verify them. Refuse rather than
    # emit a verdict that looks valid. Enforced, not just documented.
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
  GITHUB_TOKEN          Used for the release download only, to avoid rate limiting

EXAMPLES:
  nunchukdesktop_build.sh --version 2.6.6
  nunchukdesktop_build.sh --version 2.6.6 --binary ~/Downloads/nunchuk-linux-v2.6.6.zip

EXIT CODES:
  0  Identical (rebuilt ZIP byte-for-byte equal to the released ZIP)
  1  Differences found or build failed
  2  Invalid parameters

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/built.zip           (the rebuilt artifact)
EOF
}

setup_workdir() {
    # Use a unique work dir per version+arch+type+PID so parallel ABS runs do not collide.
    local suffix="${APP_VERSION}_${APP_ARCH}_${APP_TYPE}_$$"
    suffix="${suffix//[^a-zA-Z0-9._-]/_}"
    WORK_DIR="/tmp/nunchuk_${suffix}"
    mkdir -p "$WORK_DIR"
    log_info "Work directory: $WORK_DIR"
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

# Verify the release manifest signature, then cross-check the measured digest against the manifest
# that signature covers: a good signature alone does not say we compared the signed file. A failure
# here is fatal only when the signature is good AND the file disagrees (see die_provenance);
# everything else is advisory. Rationale: changelog v0.1.8.
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

    # Plain HTTPS, not `gpg --recv-keys`: the latter needs dirmngr, which fails on hosts allowing
    # ordinary HTTPS but not dirmngr's own network path.
    # Not keys.openpgp.org: it serves this key with user IDs stripped; gpg skips such a key.
    local imported=false
    local keyfile="${WORK_DIR}/release-key.asc"
    local src="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${NUNCHUK_RELEASE_KEY_FPR}"
    if timeout 60 wget -qO "$keyfile" "$src" 2>/dev/null \
            && grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$keyfile" 2>/dev/null \
            && GNUPGHOME="$gnupg_home" gpg --batch --quiet --import "$keyfile" >/dev/null 2>&1 \
            && GNUPGHOME="$gnupg_home" gpg --batch --with-colons --fingerprint 2>/dev/null \
                 | grep -q "^fpr:::::::::${NUNCHUK_RELEASE_KEY_FPR}:"; then
        # The fingerprint check confirms the pinned key actually landed: a lookup service returning
        # some other key must not silently become trusted.
        imported=true
        log_ok "Release key ${NUNCHUK_RELEASE_KEY_FPR} imported"
    fi
    if [[ "$imported" != true ]]; then
        sig_skip "Release key ${NUNCHUK_RELEASE_KEY_FPR} could not be retrieved" \
                 "The pinned release key could not be fetched (offline or blocked); signature not verified."
        check_digest_against_manifest "$sums" "unverified"
        return 0
    fi

    # SHA256SUMS.asc is CLEARSIGNED (2.6.4/2.6.5): the digests it covers are INSIDE it; the
    # separate SHA256SUMS is unsigned. Detached form still handled.
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

    # GOODSIG alone accepts any imported key, so require VALIDSIG on the pinned fingerprint.
    # VALIDSIG names the SIGNING key in field 3 and the PRIMARY last; matching only field 3 would
    # falsely reject a legitimate signing subkey. Accept either, report what signed.
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
        # Valid, just not OUR key — the payload it covers is still what to cross-check against.
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

# Cross-check the measured digest against the manifest entry for our filename. $2 carries the
# manifest's standing so the line never reads stronger than its backing, and gates PROVENANCE_FATAL.
# Sets globals — capturing with $() would run add_sig_warning in a subshell and discard warnings.
check_digest_against_manifest() {
    local sums="$1" manifest_state="$2"
    local want="${OFFICIAL_ARTIFACT_SHA256:-}" name="${OFFICIAL_ARTIFACT_NAME:-}"

    if [[ -z "$want" || -z "$name" || ! -r "$sums" ]]; then
        SIG_DIGEST_STATUS="[WARNING] No readable manifest, or no measured digest, to compare"
        return 0
    fi
    # EXACT equality, never a regex: `$2 ~ "^[*]?" name "$"` treated the name as a pattern, so
    # "nunchuk-linux-v2x6y5azip" matched "nunchuk-linux-v2.6.5.zip" and reported [OK]. Collecting
    # ALL entries matters too — taking the first accepted a conflicting duplicate.
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

prepare_official() {
    # Obtain the official release ZIP: the provided --binary, or the GitHub download,
    # or download the release ZIP from GitHub and extract the AppImage from it.
    local official_appimage="${WORK_DIR}/official.AppImage"

    if [[ -n "$BINARY_PATH" ]]; then
        log_info "Using provided binary: $(basename "$BINARY_PATH")"
        local bname; bname="$(basename "$BINARY_PATH")"
        # The provided file IS the distributed artifact, whatever its form.
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
            # The verdict is the whole distributed ZIP. A bare .AppImage is not that artifact, and
            # accepting one would compare an AppImage hash against a ZIP hash. Refuse instead.
            die_invalid "--binary must be the released .zip, got: $bname"
        fi
    else
        local zip_name="nunchuk-linux-v${APP_VERSION}.zip"
        local dl_url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/${zip_name}"
        local zip_path="${WORK_DIR}/${zip_name}"
        log_info "Downloading official release: $dl_url"
        # Download release ZIP; pass GitHub token header if available to avoid rate limiting.
        if ! wget -q ${GITHUB_TOKEN:+--header="Authorization: token ${GITHUB_TOKEN}"} \
                -O "$zip_path" "$dl_url"; then
            die_build "Failed to download: $dl_url"
        fi
        # Hash the distributed artifact as downloaded, BEFORE unpacking it. This is the value a
        # user can reproduce with sha256sum against the release page, and the one to publish.
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
    # safe.directory: the checkout is chowned back to the caller, so a later git container
    # (running as root) sees another uid's repo and refuses without this. Upstream does the same.
    "$CONTAINER_CMD" run --rm -v "${WORK_DIR}:/w" -w /w "$GIT_IMAGE" \
        -c safe.directory='*' "$@"
}

# Give a container-written tree back to the caller. Needed ONLY when the engine runs rootful, where
# container root is real root. Under any rootless engine -- podman or docker -- container root
# already maps to the invoking user, and chowning to a numeric uid there lands on a subuid instead.
# So test how the engine actually runs, never its executable name.
# True when the engine runs rootless, where container UID 0 maps to the invoking user.
is_rootless() {
    local r=""
    case "$CONTAINER_CMD" in
        *podman) r="$("$CONTAINER_CMD" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" ;;
        *docker) if "$CONTAINER_CMD" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
                 then r="true"; else r="false"; fi ;;
    esac
    [[ "$r" == "true" ]]
}

# Make the bind-mounted checkout appear INSIDE the build container as the caller's UID.
#
# This is verdict-critical, not cosmetic. Upstream's README assumes rootful Docker, where a
# host-owned checkout appears in the container as the host user's own UID. Under rootless Podman
# the same checkout appears as UID 0, and that difference CHANGES THE COMPILED BYTES. Measured
# 2026-08-25 with one image, one clone and one command, varying only this: /project as UID 1001
# reproduced the release exactly (57489e88...), /project as UID 0 did not (aa29927c...).
# Rationale and evidence: changelog v0.1.11.
set_build_owner() {
    "$CONTAINER_CMD" run --rm -v "${1}:/w" --entrypoint chown "$GIT_IMAGE" \
        -R "$(id -u):$(id -g)" /w > /dev/null 2>&1 \
        || die_build "Could not set build ownership on ${1}; the build would not match upstream's"
}

# Hand the tree back so an ordinary user can delete it without podman unshare or sudo.
# Under a rootless engine the caller IS container UID 0; under a rootful one the caller keeps its
# own numeric UID. Never fatal: a verdict already reached must not be lost to a cleanup problem.
restore_host_owner() {
    local uid gid
    uid="$(id -u)"; gid="$(id -g)"
    if is_rootless; then uid=0; gid=0; fi
    "$CONTAINER_CMD" run --rm -v "${1}:/w" --entrypoint chown "$GIT_IMAGE" \
        -R "${uid}:${gid}" /w > /dev/null 2>&1 \
        || log_warn "Could not restore ownership of ${1}; deleting it may need 'podman unshare rm -rf'"
}

run_build() {
    # Builds the way reproducible-builds/README.md tells verifiers to: upstream's committed
    # Dockerfile.linux and build_linux.sh, source bind-mounted at /project. Rationale: changelog v0.1.10.
    local src="${WORK_DIR}/src"
    log_info "Cloning ${GH_REPO} at tag ${APP_VERSION} (in a container)..."
    rm -rf "$src"
    if ! git_c clone --depth=1 --shallow-submodules --recurse-submodules \
            --branch "${APP_VERSION}" "https://github.com/${GH_REPO}.git" /w/src; then
        die_build "Could not clone ${GH_REPO} at tag ${APP_VERSION}"
    fi
    # Bind the reported commit to the checkout that will actually be built. resolve_commit() asks
    # the remote; rev-parse asks the tree we cloned. A tag moved mid-run, or a name collision,
    # shows up here instead of silently mislabelling the result.
    # Fails CLOSED. An unavailable tag lookup is not a pass: skipping the comparison there would
    # leave the collision hole open exactly when the independent check is missing, and would still
    # print a tag attribution nothing established.
    resolve_commit
    [[ "$RESOLVED_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
        || die_build "Could not resolve tag ${APP_VERSION} to a commit; refusing to attribute a build to it"
    local head; head="$(git_c -C /w/src rev-parse HEAD | tr -dc '0-9a-f')" || head=""
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die_build "Could not read HEAD from the checkout"
    [[ "$head" == "$RESOLVED_COMMIT" ]] \
        || die_build "Checkout HEAD ${head} does not match tag ${APP_VERSION} commit ${RESOLVED_COMMIT}"
    log_ok "Checkout HEAD matches tag ${APP_VERSION}: ${head}"

    # build_linux.sh derives SOURCE_DATE_EPOCH from `git log -1 --format=%ct`. Report it so the
    # recording shows the value the packaging step normalizes every timestamp to.
    local sde; sde="$(git_c -C /w/src log -1 --format=%ct | tr -dc 0-9)" || sde=""
    [[ -n "$sde" ]] || die_build "Could not read the tag commit time; SOURCE_DATE_EPOCH unset"
    log_info "SOURCE_DATE_EPOCH from tag commit: ${sde} ($(date -u -d "@${sde}" '+%Y-%m-%d %H:%M:%S UTC'))"

    local dockerfile="${src}/reproducible-builds/Dockerfile.linux"
    [[ -f "$dockerfile" ]] || die_build "Upstream reproducible-builds/Dockerfile.linux not found at tag ${APP_VERSION}"
    UPSTREAM_DOCKERFILE_SHA256="$(sha256_of "$dockerfile")"
    log_info "Upstream Dockerfile.linux sha256: ${UPSTREAM_DOCKERFILE_SHA256}"

    local image_name="nunchuk-verifier-${APP_VERSION}-$$"
    log_info "Building upstream image -- 20-40 min on first run..."
    local attempt image_built=false
    for attempt in 1 2 3; do
        if "$CONTAINER_CMD" build --platform linux/amd64 \
                -t "$image_name" -f "$dockerfile" "$src"; then
            image_built=true
            break
        fi
        log_warn "Image build attempt ${attempt}/3 failed (upstream pins no retry on the aqt module download)"
        [[ "$attempt" -lt 3 ]] && sleep 15
    done
    [[ "$image_built" == true ]] || die_build "Container image build failed after 3 attempts"

    # Ownership is set here, after the image build: `$CONTAINER_CMD build` reads the context as
    # the host user, so the tree must still be host-readable up to this point.
    log_info "Setting build ownership so /project matches upstream's rootful-Docker semantics..."
    set_build_owner "${WORK_DIR}"

    log_info "Running upstream build_linux.sh inside the container..."
    if ! "$CONTAINER_CMD" run --platform linux/amd64 --rm \
            -e TAG="${APP_VERSION}" \
            -v "${src}:/project" -w /project \
            "$image_name" bash ./reproducible-builds/build_linux.sh; then
        restore_host_owner "${WORK_DIR}"
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Containerized upstream build failed"
    fi

    restore_host_owner "${WORK_DIR}"
    "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true

    local out_zip="${src}/nunchuk-linux-v${APP_VERSION}/nunchuk-linux-v${APP_VERSION}.zip"
    [[ -f "$out_zip" ]] || die_build "Upstream build produced no ZIP at ${out_zip}"
    cp "$out_zip" "${WORK_DIR}/built.zip"

    # The ZIP is the artifact upstream's README says to diff, so hash it as built.
    BUILT_ARTIFACT_SHA256="$(sha256_of "${WORK_DIR}/built.zip")"
    log_ok "Built artifact: nunchuk-linux-v${APP_VERSION}.zip ($(stat -c%s "${WORK_DIR}/built.zip") bytes)"
    log_ok "  sha256: ${BUILT_ARTIFACT_SHA256}"

    # Also unpack the AppImage: if the ZIPs differ it localizes the difference, and if they
    # match it localizes where the archives diverge.
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
    # The verdict is the whole distributed ZIP, byte for byte -- nothing else can produce a pass.
    # Equal SHA-256 over the complete archive already implies identical member count, names,
    # metadata, compression and bytes, so no extra structural check is needed. The extracted
    # comparison that earlier versions used to reach a pass is gone: it discards exactly the
    # packing and runtime bytes that a reproducibility claim is about.
    echo ""
    echo "======================================================"
    echo "ARTIFACT COMPARISON (whole ZIP, byte for byte)"
    echo "======================================================"
    echo "Official: ${OFFICIAL_ARTIFACT_NAME}"
    echo "  ${OFFICIAL_ARTIFACT_SHA256}"
    echo "Rebuilt:  nunchuk-linux-v${APP_VERSION}.zip"
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

    # State only what was measured. Equal AppImage hashes do NOT prove the rest of the archive
    # matches: each ZIP is only required to contain an AppImage, so members could differ too.
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

# Resolve the git commit that tag APP_VERSION points at (dereferences annotated tags).
# Network is already required for the build, so a remote lookup here is acceptable.
# Resolves the tag to a commit AND classifies it, from one `git ls-remote`: an annotated tag answers
# on both peeled (`^{}`) and unpeeled refs, a lightweight tag only once. Sets globals — a command
# substitution would run this in a subshell and lose SIG_TAG_TYPE.
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

# Plain-language legend for the several meaningful hashes this app produces. Kept OUTSIDE the
# Begin/End Results markers so that block stays a clean key: value list (dannys-amendments.md,
# "Ambiguous Artifact Hashes"; reference implementation blockstreamjade_build.sh v0.2.0).
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

# Standardized WalletScrutiny verification summary (verification-result-summary-format.md).
# Parsed by the legacy test.sh format; the machine verdict still lives in COMPARISON_RESULTS.yaml.
emit_verification_summary() {
    local yaml_verdict summary_verdict commit
    yaml_verdict="$(awk '/^verdict:/{print $2}' "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml" 2>/dev/null)"
    case "$yaml_verdict" in
        reproducible)     summary_verdict="reproducible" ;;
        not_reproducible) summary_verdict="differences found" ;;
        ftbfs)            summary_verdict="" ;;
        *)                summary_verdict="$yaml_verdict" ;;
    esac
    [[ "$RESOLVED_COMMIT" == "unknown" ]] && resolve_commit
    commit="$RESOLVED_COMMIT"

    print_hash_legend

    # appHash is the artifact EXACTLY AS DOWNLOADED (the release ZIP), per
    # verification-result-summary-format.md and test.sh:149. Through v0.1.6 this field wrongly
    # carried the inner AppImage hash — the same defect class as GitLab issue 957.
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

    # Section 4 of verification-result-summary-format.md. The meaningful signature here is over the
    # release manifest, not the AppImage (unsigned), so the manifest line leads.
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

    # Self-identify before doing anything else, so a recording of this run always shows which
    # bytes of tooling produced the result without the operator having to remember to hash it.
    SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"

    parse_args "$@"
    detect_container_cmd
    setup_workdir

    log_info "Version: ${APP_VERSION}"
    log_info "Arch:    ${APP_ARCH}"
    log_info "Type:    ${APP_TYPE}"
    [[ -n "$BINARY_PATH" ]] && log_info "Binary:  ${BINARY_PATH}"
    echo ""

    prepare_official
    # Provenance checks run after the digest is measured and before the build, so a signature
    # problem shows up early in the recording. Neither can change the verdict.
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
