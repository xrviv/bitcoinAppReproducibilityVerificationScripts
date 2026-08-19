#!/bin/bash
#
# nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verifier
#
# Version: v0.1.9
#
# Description:
#   Reproducible build verification for Nunchuk Desktop (Linux x86_64 AppImage).
#   Builds the app from source inside an inline Docker/Podman container matching
#   the upstream reproducible_linux.yml execution model, then compares the built
#   AppImage against the official release at the extracted-squashfs level.
#
#   Upstream embeds three OAuth values at compile time, and its workflow does not publish the
#   Actions artifact as the GitHub release asset. Both are reported as context when
#   substantive extracted-content differences are found.
#
#   Whole-AppImage hashes always differ: appimagetool embeds wall-clock time in the squashfs
#   superblock and upstream sets no SOURCE_DATE_EPOCH. Comparison is therefore done by
#   extracting both AppImages with unsquashfs and running diff -r on the trees.
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
#   --binary FILE        Path to official AppImage or ZIP (skips download)
#   --arch ARCH          Architecture (only x86_64-linux-gnu supported; default)
#   --type TYPE          Build type (only appimage supported; default)
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
# Changelog: ~/work/ws-notes/script-notes/desktop/nunchuk/changelog.md
#

set -euo pipefail

SCRIPT_VERSION="v0.1.9"
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
WORK_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
MISSING_OAUTH_INPUTS=""

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
    local name
    local -a missing=()

    for name in OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET OAUTH_REDIRECT_URI; do
        [[ -n "${!name:-}" ]] || missing+=("$name")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        MISSING_OAUTH_INPUTS="$(IFS=,; echo "${missing[*]}")"
        log_warn "Missing compile-time OAuth inputs: ${MISSING_OAUTH_INPUTS}"
        log_warn "The build will continue; any differences require triage and the missing inputs limit root-cause attribution."
    else
        log_info "All upstream compile-time OAuth inputs are present in the environment."
    fi

    log_warn "Upstream does not establish that the published release asset came from reproducible_linux.yml."
}

comparison_context_note() {
    local note="The published release asset is not proven to come from the recreated reproducible_linux.yml pipeline."
    if [[ -n "$MISSING_OAUTH_INPUTS" ]]; then
        note+=" Missing compile-time inputs: ${MISSING_OAUTH_INPUTS}."
    fi
    printf '%s' "$note"
}

# Validate that a SquashFS superblock exists at the given byte offset.
#   0 = valid, 1 = not valid, 2 = cannot validate (no host unsquashfs)
validate_squashfs_offset() {
    local appimage="$1" off="$2"
    command -v unsquashfs >/dev/null 2>&1 || return 2
    unsquashfs -s -o "$off" "$appimage" >/dev/null 2>&1 && return 0
    return 1
}

# Determine the byte offset of the SquashFS payload inside a type-2 AppImage.
# A type-2 AppImage is an ELF runtime with the SquashFS filesystem APPENDED at an
# offset, so unsquashfs must be told that offset with -o. Three tiers (per code review):
#   Tier 1: ask the AppImage runtime (`--appimage-offset`) — no FUSE needed, but it
#           must execute the runtime, which can fail on noexec/perm/arch/container.
#   Tier 2: parse the ELF header — squashfs starts right after the section-header
#           table (offset = e_shoff + e_shentsize * e_shnum). FUSE-free, deterministic.
#   Tier 3: scan for the 'hsqs' SquashFS magic — accepted ONLY if positively validated
#           by unsquashfs, since false positives can occur inside the ELF/runtime data.
# Echoes the numeric offset on success; returns non-zero on total failure.
detect_appimage_offset() {
    local appimage="$1"
    local fsize; fsize="$(stat -c%s "$appimage")"
    local off rc

    # Tier 1: runtime --appimage-offset
    if chmod +x "$appimage" 2>/dev/null; then
        off="$("$appimage" --appimage-offset 2>/dev/null | tr -d '[:space:]')"
        if [[ "$off" =~ ^[0-9]+$ ]] && (( off > 0 && off < fsize )); then
            validate_squashfs_offset "$appimage" "$off"; rc=$?
            if [[ "$rc" -ne 1 ]]; then echo "$off"; return 0; fi
        fi
    fi

    # Tier 2: ELF section-header-table end = squashfs start
    off="$(python3 - "$appimage" <<'PY' 2>/dev/null
import sys, struct
d = open(sys.argv[1], 'rb').read(64)
if d[:4] != b'\x7fELF': sys.exit(1)
is64 = d[4] == 2
end = '<' if d[5] == 1 else '>'
if is64:
    e_shoff = struct.unpack(end + 'Q', d[40:48])[0]
    e_shentsize, e_shnum = struct.unpack(end + 'H', d[58:60])[0], struct.unpack(end + 'H', d[60:62])[0]
else:
    e_shoff = struct.unpack(end + 'I', d[32:36])[0]
    e_shentsize, e_shnum = struct.unpack(end + 'H', d[46:48])[0], struct.unpack(end + 'H', d[48:50])[0]
print(e_shoff + e_shentsize * e_shnum)
PY
)"
    if [[ "$off" =~ ^[0-9]+$ ]] && (( off > 0 && off < fsize )); then
        validate_squashfs_offset "$appimage" "$off"; rc=$?
        if [[ "$rc" -ne 1 ]]; then echo "$off"; return 0; fi
    fi

    # Tier 3: scan for 'hsqs' magic; accept only a positively validated candidate
    local cand
    while IFS= read -r cand; do
        [[ "$cand" =~ ^[0-9]+$ ]] || continue
        (( cand < fsize )) || continue
        if validate_squashfs_offset "$appimage" "$cand"; then echo "$cand"; return 0; fi
    done < <(grep -aboe 'hsqs' "$appimage" 2>/dev/null | cut -d: -f1)

    return 1
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
  --binary FILE        Official AppImage or ZIP (skip GitHub download)
  --arch ARCH          x86_64-linux-gnu (default, only supported value)
  --type TYPE          appimage (default, only supported value)

OPTIONAL ENVIRONMENT:
  OAUTH_CLIENT_ID       Upstream compile-time OAuth client ID
  OAUTH_CLIENT_SECRET   Upstream compile-time OAuth client secret
  OAUTH_REDIRECT_URI    Upstream compile-time OAuth redirect URI

EXAMPLES:
  nunchukdesktop_build.sh --version 1.9.50
  nunchukdesktop_build.sh --version 1.9.50 --binary ~/Downloads/nunchuk-linux-v1.9.50.zip

EXIT CODES:
  0  Identical (reproducible at squashfs-contents level)
  1  Differences found or build failed
  2  Invalid parameters

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/diff_squashfs.txt  (full squashfs diff for human review)
  $WORK_DIR/diff_squashfs_brief.txt  (one line per differing entry)
  $WORK_DIR/why_not_reproducible.txt (categorized reason summary when differences exist)
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
    # Obtain the official AppImage: either extract from the provided ZIP/AppImage binary,
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
            local found; found="$(find "${WORK_DIR}/official_zip" -name "*.AppImage" | head -1)"
            if [[ -z "$found" ]]; then
                die_build "No .AppImage found inside provided ZIP: $BINARY_PATH"
            fi
            cp "$found" "$official_appimage"
        elif [[ "$bname" == *.AppImage ]]; then
            cp "$BINARY_PATH" "$official_appimage"
        else
            die_invalid "--binary must be a .zip or .AppImage file, got: $bname"
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
        local found; found="$(find "${WORK_DIR}/official_zip" -name "*.AppImage" | head -1)"
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

run_build() {
    # Prepare Nunchuk's build environment using an inline Dockerfile that mirrors
    # upstream reproducible-builds/Dockerfile.linux, with these deltas:
    #   - Source is git-cloned at the release TAG inside the container (no host build context)
    #   - debug_info is KEPT (content parity); the flaky module download is retried w/ timeout
    #   - The build runs when the container starts, matching reproducible_linux.yml, so
    #     OAuth environment variables reach CMake instead of being lost at image-build time
    # squashfs-tools is also added so the comparison step can run unsquashfs in-container.
    log_info "Writing inline Dockerfile..."

    cat > "${WORK_DIR}/Dockerfile.build" << 'DOCKERFILE_END'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG QT_VERSION=5.15.2
ENV QT_INSTALL_DIR=/opt/Qt
ENV QT5_DIR=$QT_INSTALL_DIR/$QT_VERSION/gcc_64/lib/cmake/Qt5
ENV QT_INSTALLED_PREFIX=$QT_INSTALL_DIR/$QT_VERSION/gcc_64

ARG TAG=0.0.0
RUN echo "Building version $TAG"

RUN apt update && apt install -y \
        cmake g++ make ninja-build \
        libboost-all-dev libzmq3-dev libevent-dev libdb++-dev \
        sqlite3 libsqlite3-dev libsecret-1-dev \
        git dpkg-dev python3-pip wget unzip curl patchelf p7zip-full \
        libgl1-mesa-dev

RUN apt update && apt install -y \
        fuse libfuse2 squashfuse \
        mesa-common-dev libglu1-mesa-dev \
        libpulse-dev libxcb-xinerama0 software-properties-common \
        libnss3-dev libasound2-dev libxrandr-dev libxcomposite-dev \
        libxcursor-dev libxi-dev libxdamage-dev libxtst-dev libxss-dev \
        libx11-xcb-dev libxt-dev libdbus-1-dev libegl1-mesa-dev \
        squashfs-tools

RUN add-apt-repository ppa:ubuntu-toolchain-r/ppa -y && \
    apt update && apt install -y gcc-14 g++-14 && \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 && \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100

ENV CC=gcc-14
ENV CXX=g++-14

# debug_info is KEPT (matches upstream Dockerfile.linux:44). The official AppImage bundles the
# Qt .debug companion files via CQtDeployer; omitting debug_info drops ~10 MB and breaks content
# parity. The debug-symbols download is flaky, so the module install is retried with a longer timeout.
RUN pip3 install --break-system-packages aqtinstall && \
    aqt install-qt linux desktop $QT_VERSION gcc_64 --outputdir "$QT_INSTALL_DIR" && \
    for attempt in 1 2 3 4 5; do \
        aqt install-qt linux desktop $QT_VERSION gcc_64 --outputdir "$QT_INSTALL_DIR" --timeout 120 \
            --modules qtcharts qtdatavis3d qtlottie qtnetworkauth qtpurchasing qtquick3d \
                      qtquicktimeline qtscript qtvirtualkeyboard qtwaylandcompositor \
                      qtwebengine qtwebglplugin debug_info && break; \
        echo "aqt module install attempt $attempt failed"; \
        [ "$attempt" = 5 ] && { echo "all aqt attempts failed"; exit 1; }; \
        sleep 15; \
    done

RUN git clone --depth 1 --branch 0.15.0 https://github.com/frankosterfeld/qtkeychain.git /tmp/qtkeychain && \
    cd /tmp/qtkeychain && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DQt5_DIR=$QT5_DIR && \
    make -j$(nproc) && make install && ldconfig

RUN git clone https://gitlab.matrix.org/matrix-org/olm.git /tmp/olm && \
    cd /tmp/olm && git checkout 3.2.16 && mkdir build && cd build && \
    cmake .. -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && make -j$(nproc) && \
    make install && ldconfig

RUN wget https://github.com/QuasarApp/CQtDeployer/releases/download/v1.6.2365/CQtDeployer_1.6.2365.7cce7f3_Linux_x86_64.deb && \
    dpkg -i CQtDeployer_1.6.2365.7cce7f3_Linux_x86_64.deb

RUN wget https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1g/openssl-1.1.1g.tar.gz && \
    tar xzf openssl-1.1.1g.tar.gz && \
    cd openssl-1.1.1g && ./config --prefix=/opt/openssl-1.1.1g && \
    make -j$(nproc) && make install_dev

ENV OPENSSL_ROOT_DIR=/opt/openssl-1.1.1g

RUN wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage && \
    chmod +x appimagetool-x86_64.AppImage && mv appimagetool-x86_64.AppImage /usr/local/bin/appimagetool

# Clone the exact release tag from GitHub INSIDE the container (no host build context),
# so the script is self-contained and ABS-ready. TAG is the bare version (e.g. 1.9.50).
RUN git clone --depth=1 --shallow-submodules --recurse-submodules --branch "${TAG}" \
        https://github.com/nunchuk-io/nunchuk-desktop.git /project
WORKDIR /project

CMD ["bash", "/project/reproducible-builds/build_linux.sh"]
DOCKERFILE_END

    log_info "Building container image — this takes 20-40 min on first run..."
    local image_name="nunchuk-verifier-${APP_VERSION}-$$"
    local container_name="nunchuk-extract-${APP_VERSION}-$$"

    # TAG selects the source during image creation and is passed again to the runtime package script.
    # Source is cloned from GitHub inside the container, so the build context is WORK_DIR and the
    # script does not depend on a host checkout (ABS-ready).
    if ! "$CONTAINER_CMD" build \
            --build-arg TAG="${APP_VERSION}" \
            -t "$image_name" \
            -f "${WORK_DIR}/Dockerfile.build" \
            "${WORK_DIR}" 2>&1; then
        die_build "Container build failed"
    fi

    log_info "Running upstream build command inside the container..."
    local -a create_args=(create --name "$container_name" --env "TAG=${APP_VERSION}")
    local oauth_name
    for oauth_name in OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET OAUTH_REDIRECT_URI; do
        if [[ -v "$oauth_name" ]]; then
            # Pass only the variable name so its value is not exposed in the process list.
            create_args+=(--env "$oauth_name")
        fi
    done

    if ! "$CONTAINER_CMD" "${create_args[@]}" "$image_name" > /dev/null; then
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Could not create build container"
    fi
    if ! "$CONTAINER_CMD" start --attach "$container_name"; then
        "$CONTAINER_CMD" rm "$container_name" > /dev/null 2>&1 || true
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Containerized upstream build failed"
    fi

    log_info "Extracting built AppImage from container..."
    if ! "$CONTAINER_CMD" cp \
            "${container_name}:/project/nunchuk-linux-v${APP_VERSION}/nunchuk-linux-v${APP_VERSION}.AppImage" \
            "${WORK_DIR}/built.AppImage"; then
        "$CONTAINER_CMD" rm "$container_name" > /dev/null 2>&1 || true
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Could not extract built AppImage from container"
    fi
    "$CONTAINER_CMD" rm "$container_name" > /dev/null
    "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true

    local sz; sz="$(stat -c%s "${WORK_DIR}/built.AppImage")"
    BUILT_APPIMAGE_SHA256="$(sha256_of "${WORK_DIR}/built.AppImage")"
    log_ok "Built AppImage ready: built.AppImage (${sz} bytes)"
    log_ok "  sha256: ${BUILT_APPIMAGE_SHA256}"
}

compare_appimages() {
    # Extract both AppImages with unsquashfs and run diff -r on the directory trees.
    # Whole-AppImage hash comparison is not used: appimagetool embeds a wall-clock timestamp
    # in the squashfs superblock, so hashes always differ even with identical contents.
    log_info "Extracting AppImages with unsquashfs..."
    local official_dir="${WORK_DIR}/official-squashfs"
    local built_dir="${WORK_DIR}/built-squashfs"
    rm -rf "$official_dir" "$built_dir"

    # Each AppImage carries its SquashFS at a byte offset after the ELF runtime, and
    # the official and built images can have DIFFERENT offsets — detect each on the
    # host (works without unsquashfs) so the same values feed both the host and the
    # container extraction paths. A failure here is an extraction-tooling problem,
    # not a build outcome.
    local official_offset built_offset
    official_offset="$(detect_appimage_offset "${WORK_DIR}/official.AppImage")" \
        || die_build "Could not determine SquashFS offset for official AppImage (extraction tooling failure, not a build result)"
    built_offset="$(detect_appimage_offset "${WORK_DIR}/built.AppImage")" \
        || die_build "Could not determine SquashFS offset for built AppImage (extraction tooling failure, not a build result)"
    log_info "SquashFS offsets -- official: ${official_offset}, built: ${built_offset}"

    if command -v unsquashfs >/dev/null 2>&1; then
        # Use host unsquashfs if available -- faster than spinning up a container.
        unsquashfs -o "$official_offset" -d "$official_dir" "${WORK_DIR}/official.AppImage" > /dev/null 2>&1 || \
            die_build "unsquashfs failed on official AppImage at offset ${official_offset} (extraction tooling failure)"
        unsquashfs -o "$built_offset" -d "$built_dir" "${WORK_DIR}/built.AppImage" > /dev/null 2>&1 || \
            die_build "unsquashfs failed on built AppImage at offset ${built_offset} (extraction tooling failure)"
    else
        log_info "Host unsquashfs not found; extracting via container (installs squashfs-tools)..."
        # Mount WORK_DIR into an ubuntu container and run unsquashfs there, using the
        # host-computed offsets (the AppImage cannot self-execute inside the container).
        "$CONTAINER_CMD" run --rm \
            -v "${WORK_DIR}:/work" \
            ubuntu:24.04 \
            bash -c "apt-get update -qq && apt-get install -y -qq squashfs-tools > /dev/null && \
                     unsquashfs -o ${official_offset} -d /work/official-squashfs /work/official.AppImage > /dev/null && \
                     unsquashfs -o ${built_offset}    -d /work/built-squashfs    /work/built.AppImage    > /dev/null" \
            || die_build "Container unsquashfs extraction failed (offsets official=${official_offset} built=${built_offset}; extraction tooling failure)"
    fi

    log_info "Running diff -r on extracted squashfs trees..."
    local diff_file="${WORK_DIR}/diff_squashfs.txt"
    local diff_exit=0
    # diff returns 1 if files differ; 2 on error. Capture exit without triggering set -e.
    diff -r "$official_dir" "$built_dir" > "$diff_file" 2>&1 || diff_exit=$?
    if [[ "$diff_exit" -gt 1 ]]; then
        die_build "diff -r failed with exit code $diff_exit"
    fi

    local total_lines; total_lines="$(wc -l < "$diff_file")"
    log_info "Full diff: $diff_file ($total_lines lines)"

    local official_sz; official_sz="$(stat -c%s "${WORK_DIR}/official.AppImage")"
    local built_sz;    built_sz="$(stat -c%s "${WORK_DIR}/built.AppImage")"
    local size_delta=$(( official_sz - built_sz ))
    local brief_diff_file="${WORK_DIR}/diff_squashfs_brief.txt"
    local reason_file="${WORK_DIR}/why_not_reproducible.txt"
    local brief_exit=0
    diff -rq "$official_dir" "$built_dir" > "$brief_diff_file" 2>&1 || brief_exit=$?
    if [[ "$brief_exit" -gt 1 ]]; then
        die_build "diff -rq failed with exit code $brief_exit"
    fi

    local differing_files official_only built_only path_diffs
    differing_files="$(grep -c '^Files ' "$brief_diff_file" || true)"
    official_only="$(grep -F -c "Only in ${official_dir}" "$brief_diff_file" || true)"
    built_only="$(grep -F -c "Only in ${built_dir}" "$brief_diff_file" || true)"
    # Headline figure = differing PATHS, from `diff -rq`. Through v0.1.8 it was `wc -l` of the full
    # `diff -r`, which also counts CONTENT lines of differing TEXT files: v2.6.5 reported "199 diff
    # lines" for 157 paths, and that inflated figure reached the published notes.
    path_diffs=$(( differing_files + official_only + built_only ))

    local context_note=""
    if [[ "$brief_exit" -eq 1 ]]; then
        context_note="$(comparison_context_note)"
        {
            echo "WHY NOT REPRODUCIBLE"
            echo "Reason: the extracted official and rebuilt AppImages contain substantive differences."
            printf 'Differing paths: %s (differing files: %s; official-only: %s; rebuilt-only: %s)\n' \
                "$path_diffs" "$differing_files" "$official_only" "$built_only"
            echo "AppImage size delta: ${size_delta} bytes"
            echo "Context: $context_note"
            echo ""
            # One complete list rather than per-directory greps: the old `/bin/` and `/lib/`
            # sections silently omitted root-level entries, which is where v2.6.5's AppRun and
            # nunchuk.desktop differences appeared.
            echo "All differing paths:"
            sed "s#${WORK_DIR}/##g" "$brief_diff_file"
        } > "$reason_file"
        log_info "Reason summary: $reason_file"
        echo ""
        echo "======================================================"
        sed -n '1,18p' "$reason_file"
        echo "Full categorized reason: $reason_file"
        echo "======================================================"
        echo ""
    fi


    echo ""
    echo "======================================================"
    echo "SQUASHFS DIFF PREVIEW (first 5 lines; full diff in ${WORK_DIR}/diff_squashfs.txt)"
    echo "======================================================"
    if [[ "$total_lines" -eq 0 ]]; then
        echo "(No differences)"
    else
        head -5 "$diff_file"
        if [[ "$total_lines" -gt 5 ]]; then
            echo "... (${total_lines} lines of full diff output; ${path_diffs} differing paths)"
        fi
    fi
    echo ""
    echo "Official AppImage: $official_sz bytes"
    echo "Built AppImage:    $built_sz bytes"
    echo "Size delta:        $size_delta bytes"
    echo "======================================================"
    echo ""

    if [[ "$total_lines" -eq 0 && "$diff_exit" -eq 0 ]]; then
        log_ok "Squashfs contents IDENTICAL"
        write_yaml "reproducible" \
            "Built from source at tag ${APP_VERSION}. Squashfs-extracted contents are identical."
        return 0
    else
        local context_note
        context_note="$(comparison_context_note)"
        log_warn "Squashfs contents DIFFER (${path_diffs} differing paths; size delta $size_delta bytes)"
        log_warn "$context_note"
        write_yaml "not_reproducible" \
            "Substantive squashfs differences found: ${path_diffs} differing paths (${differing_files} files differ, ${official_only} only in the official artifact, ${built_only} only in the rebuild); AppImage size delta: ${size_delta} bytes. ${context_note}"
        return 1
    fi
}

# Resolve the git commit that tag APP_VERSION points at (dereferences annotated tags).
# Network is already required for the build, so a remote lookup here is acceptable.
# Resolves the tag to a commit AND classifies it, from one `git ls-remote`: an annotated tag answers
# on both peeled (`^{}`) and unpeeled refs, a lightweight tag only once. Sets globals — a command
# substitution would run this in a subshell and lose SIG_TAG_TYPE.
resolve_commit() {
    local out ref n
    out="$(git ls-remote "https://github.com/${GH_REPO}.git" \
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
    echo "  appImageHash     sha256 of the AppImage extracted from that artifact: the payload the"
    echo "                   comparison ran against. DO NOT publish it."
    echo "  builtAppImageHash sha256 of our rebuilt AppImage. For the record only — never expected"
    echo "                   to match: appimagetool embeds wall-clock time in the squashfs"
    echo "                   superblock and upstream sets no SOURCE_DATE_EPOCH."
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
    resolve_commit; commit="$RESOLVED_COMMIT"

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
    echo "builtAppImageHash: ${BUILT_APPIMAGE_SHA256:-N/A}"
    echo "commit:         ${commit}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
    echo ""
    echo "Diff:"
    # Brief (one line per differing file) so the summary stays log-friendly; the full
    # content diff is in diff_squashfs.txt.
    if [[ -s "${WORK_DIR}/diff_squashfs.txt" ]]; then
        # diff returns 1 when files differ (expected for Nunchuk); never let that abort
        # the summary under set -e/pipefail.
        { diff -rq "${WORK_DIR}/official-squashfs" "${WORK_DIR}/built-squashfs" 2>&1 || true; } \
            | sed "s#${WORK_DIR}/##g"
    else
        echo "(no differences)"
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
    compare_appimages || verdict_exit=$?

    emit_verification_summary

    echo ""
    echo "======================================================"
    echo "RESULTS (machine-readable verdict in COMPARISON_RESULTS.yaml)"
    echo "======================================================"
    cat "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    echo ""
    echo "Work directory: ${WORK_DIR}"
    echo "Full squashfs diff: ${WORK_DIR}/diff_squashfs.txt"
    if [[ -f "${WORK_DIR}/why_not_reproducible.txt" ]]; then
        echo "Reason summary: ${WORK_DIR}/why_not_reproducible.txt"
    fi
    echo "Brief squashfs diff: ${WORK_DIR}/diff_squashfs_brief.txt"
    echo "======================================================"
    echo ""

    exit "$verdict_exit"
}

main "$@"
