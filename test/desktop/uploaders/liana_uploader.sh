#!/bin/bash
#
# liana_uploader.sh - Upload verified Liana Desktop release artifacts to Blossom
#                     and register each on Nostr (NIP-94 / kind 1063).
#
# Version: v0.1.0
#
# WHAT THIS DOES
#   Mirrors sparrow_uploader.sh / passportprime_upload.sh. For each official Liana desktop
#   artifact it (1) uploads the file to a Blossom mediaserver and (2) publishes ONE NIP-94
#   file-metadata event (kind 1063) per artifact, anchoring the file by its SHA256.
#
#   Per WalletScrutiny's per-artifact verdict model (Leo): each desktop artifact is an
#   independent unit of verification, so this tool emits one event PER artifact (not one
#   bundled event). Run it once per artifact, as each artifact's verification completes.
#
# WHAT THIS DOES NOT DO  (important)
#   It does NOT assign a reproducibility verdict. On WalletScrutiny the verdict is set ONLY
#   in the web UI (the verification results event). This tool merely anchors the official
#   artifacts publicly so a verification can reference them by hash.
#
# WHICH BYTES ARE UPLOADED
#   The WHOLE official release file, unmodified (tar.gz / deb / exe — no detached signature
#   header to strip). So the Blossom address EQUALS the SHA256 published in the Liana
#   `liana-<ver>-shasums.txt` / shown on the WS page. NOTE: for the tarball and deb the outer
#   hash is the *download identity* — reproducibility is proven at the contents level (the
#   liana-build script compares the 3 binaries lianad/liana-cli/liana-gui). The exe is a
#   single file, so its outer hash IS the reproducible unit. The verdict lives in the web UI.
#
# IDENTITY
#   Uses the shared WalletScrutiny uploader keypair (generated fresh on first run, persisted,
#   and printed to the terminal). Override the location with WS_UPLOAD_KEYFILE.
#
# SAFETY
#   Dry-run by DEFAULT (downloads + hashes + prints the events, uploads NOTHING and
#   broadcasts NOTHING). Add --publish to actually upload to Blossom and broadcast.
#
# Requirements (host tools): nak, curl, sha256sum, stat, coreutils.
#
# Organization: WalletScrutiny.com
#

set -euo pipefail

SCRIPT_VERSION="v0.1.1"
APP_ID="liana"
PLATFORM="desktop"
PAGE_URL="https://walletscrutiny.com/desktop/liana/"
RELEASES_REPO="wizardsardine/liana"
BLOSSOM_SERVER="${WS_BLOSSOM_SERVER:-https://files.nostr.info}"
RELAYS=(wss://relay.nostr.info wss://nostr.mom wss://relay.primal.net wss://relay.damus.io wss://nos.lol)
NAK="${NAK:-nak}"
# Shared WalletScrutiny uploader identity - reused by ALL uploader scripts (sparrow,
# passportprime, liana, future ones). Override per-run with WS_UPLOAD_KEYFILE.
KEYFILE="${WS_UPLOAD_KEYFILE:-$HOME/.config/walletscrutiny/uploader.hexkey}"
# Blossom auth-event validity window (seconds). Must comfortably exceed the time to
# transfer the largest artifact, or the server rejects with "Auth expired" (400).
AUTH_TTL="${WS_BLOSSOM_AUTH_TTL:-1800}"

APP_VERSION=""
TYPES_ARG="all"
PUBLISH=false

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

# blossom_upload FILE EXPECTED_SHA256
#   Uploads FILE to the Blossom server via a BUD-02 PUT /upload with a self-built,
#   kind-24242 auth event (expiration = now + AUTH_TTL). Streams the file with curl so the
#   --progress-bar shows a live upload percentage. Verifies the returned sha256.
blossom_upload() {
    local file="$1" want="$2" exp authb64 resp got
    exp=$(( $(date -u +%s) + AUTH_TTL ))
    authb64="$("${NAK}" event -k 24242 -t t=upload -t "x=${want}" -t "expiration=${exp}" \
        -c "Upload $(basename "${file}")" --sec "${SEC_HEX}" | base64 -w0)" || return 1
    # Progress bar goes to stderr (visible); JSON blob descriptor goes to stdout (captured).
    resp="$(curl -f -L --progress-bar -T "${file}" \
        -H "Authorization: Nostr ${authb64}" "${BLOSSOM_SERVER}/upload")" || return 1
    got="$(printf '%s' "${resp}" | grep -oE '[0-9a-f]{64}' | head -1 || true)"
    [[ "${got}" == "${want}" ]] || { warn "server returned sha256 '${got}' != '${want}'"; return 2; }
    return 0
}

usage() {
    cat <<EOF
liana_uploader.sh ${SCRIPT_VERSION} - upload + register Liana Desktop artifacts

Usage:
  $0 --version VERSION [--type LIST] [--publish] [--server URL] [--keyfile PATH]

  --version VERSION   Liana version WITHOUT the 'v' (e.g. 14.0). Required.
                      (The release tag is 'v<VERSION>'; this tool adds the 'v'.)
  --type LIST         Comma-separated artifact types, or 'all'. Default: all.
                      Valid: tarball, deb, exe
                      (tarball/deb = Linux x86_64; exe = Windows noncodesigned)
  --publish           Actually upload to Blossom and broadcast the kind-1063 events.
                      Omit for a dry run (default: shows everything, sends nothing).
  --server URL        Blossom mediaserver (default: ${BLOSSOM_SERVER}).
  --keyfile PATH      Nostr identity hex-key file (default: ${KEYFILE}).
  -h, --help          This help.

Only upload artifacts you have actually verified. The reproducibility verdict itself is
assigned exclusively in the WalletScrutiny web UI.
EOF
}

# ---- args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ -n "${2:-}" ]] || die "--version needs a value"; APP_VERSION="$2"; shift 2 ;;
        --type)    [[ -n "${2:-}" ]] || die "--type needs a value"; TYPES_ARG="$2"; shift 2 ;;
        --publish) PUBLISH=true; shift ;;
        --server)  [[ -n "${2:-}" ]] || die "--server needs a value"; BLOSSOM_SERVER="$2"; shift 2 ;;
        --keyfile) [[ -n "${2:-}" ]] || die "--keyfile needs a value"; KEYFILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "ignoring unknown argument: $1"; shift ;;
    esac
done
[[ -n "${APP_VERSION}" ]] || { usage; die "--version is required"; }
command -v "${NAK}" >/dev/null 2>&1 || die "nak not found (set NAK=/path/to/nak)"
command -v curl >/dev/null 2>&1 || die "curl required"

V="${APP_VERSION}"
# Liana release tags carry a 'v' prefix (e.g. v14.0) — unlike Sparrow.
DL_BASE="https://github.com/${RELEASES_REPO}/releases/download/v${V}"

# ---- preflight: confirm the release tag exists (one clear error beats N per-asset 404s) ----
# Liana versions are MAJOR.MINOR (e.g. 14.0, 13.1) — a bare '14' has no matching tag/assets.
if ! curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases/tags/v${V}" >/dev/null 2>&1; then
    warn "No Liana release found for tag 'v${V}'."
    avail="$(curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=12" 2>/dev/null \
        | grep -oE '"tag_name": *"v[0-9][^"]*"' | sed -E 's/^.*"(v[0-9][^"]*)"$/\1/' | tr '\n' ' ')"
    [[ -n "${avail}" ]] && warn "Available release tags: ${avail}"
    die "Pass an exact released version WITHOUT the leading 'v' (e.g. --version 14.0, not 14)."
fi

# ---- artifact catalogue: type -> filename | mime ----
declare -A ART_FILE ART_MIME
ART_FILE[tarball]="liana-${V}-x86_64-linux-gnu.tar.gz"; ART_MIME[tarball]="application/gzip"
ART_FILE[deb]="liana-${V}-1_amd64.deb";                 ART_MIME[deb]="application/vnd.debian.binary-package"
ART_FILE[exe]="liana-${V}-noncodesigned.exe";           ART_MIME[exe]="application/vnd.microsoft.portable-executable"

# ---- resolve requested types ----
declare -a TYPES=()
if [[ "${TYPES_ARG}" == "all" ]]; then
    TYPES=(tarball deb exe)
else
    IFS=',' read -ra TYPES <<< "${TYPES_ARG}"
fi
for t in "${TYPES[@]}"; do
    [[ -n "${ART_FILE[$t]:-}" ]] || die "unknown --type '${t}' (valid: tarball deb exe)"
done

# ---- identity (fresh on first run, persisted, displayed) ----
FRESH=false
if [[ -f "${KEYFILE}" ]]; then
    SEC_HEX="$(tr -d '[:space:]' < "${KEYFILE}")"
    [[ -n "${SEC_HEX}" ]] || die "keyfile ${KEYFILE} is empty"
else
    log "No identity found - generating a fresh Nostr keypair..."
    SEC_HEX="$("${NAK}" key generate)"
    mkdir -p "$(dirname "${KEYFILE}")"
    ( umask 077; printf '%s\n' "${SEC_HEX}" > "${KEYFILE}" )
    chmod 600 "${KEYFILE}"
    FRESH=true
fi
PUB_HEX="$(printf '%s' "${SEC_HEX}" | "${NAK}" key public)"
NPUB="$("${NAK}" encode npub "${PUB_HEX}")"
NSEC="$("${NAK}" encode nsec "${SEC_HEX}")"

echo "============================================================"
echo " WalletScrutiny uploader identity (Nostr)"
echo "   npub: ${NPUB}"
if [[ "${FRESH}" == true ]]; then
    echo "   nsec: ${NSEC}"
    echo "   >>> SAVE THIS nsec. It was just generated and stored at:"
    echo "       ${KEYFILE}"
    echo "       Anyone with it can publish as this identity."
else
    echo "   (nsec loaded from ${KEYFILE})"
fi
echo "============================================================"

WORK="$(mktemp -d -t lianaupload.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log "Liana ${V} - processing ${#TYPES[@]} artifact(s): ${TYPES[*]}"

PROCESSED=0
for t in "${TYPES[@]}"; do
    file="${ART_FILE[$t]}"
    mime="${ART_MIME[$t]}"
    url="${DL_BASE}/${file}"
    out="${WORK}/${file}"

    echo ""
    echo "----- ${t}: ${file} -----"
    echo "  downloading..."
    if ! curl -f -L --progress-bar -o "${out}" "${url}"; then
        warn "download failed (skipping): ${url}"
        warn "  (this artifact may not exist for ${V}; check the release page)"
        continue
    fi
    hash="$(sha256sum "${out}" | cut -d' ' -f1)"
    size="$(stat -c%s "${out}")"
    printf '  sha256=%s  size=%s bytes\n' "${hash}" "${size}"

    if [[ "${PUBLISH}" == true ]]; then
        if "${NAK}" blossom --server "${BLOSSOM_SERVER}" check "${hash}" >/dev/null 2>&1; then
            log "    already on ${BLOSSOM_SERVER} (${hash}) - skipping upload"
        else
            human="$(numfmt --to=iec "${size}" 2>/dev/null || echo "${size}B")"
            echo "  uploading ${file} (${human})..."
            blossom_upload "${out}" "${hash}" || die "blossom upload failed for ${file}"
            log "    uploaded: ${BLOSSOM_SERVER}/${hash}"
        fi
    fi

    blossom_url="${BLOSSOM_SERVER}/${hash}"
    content="Liana Desktop v${V} (${t}: ${file}) - WalletScrutiny verified artifact.
SHA256 is the official download hash. Reproducibility verdict: ${PAGE_URL}"

    # NIP-94 (kind 1063) file metadata, one event per artifact.
    EVENT_TAGS=(
        -t "url=${blossom_url}"
        -t "x=${hash}"
        -t "ox=${hash}"
        -t "m=${mime}"
        -t "size=${size}"
        -t "i=${APP_ID}"
        -t "version=${V}"
        -t "platform=${PLATFORM}"
        -t "type=${t}"
        -t "client=WalletScrutiny.com"
        -t "r=${PAGE_URL}"
        -t "r=${url}"
    )

    echo "  --- kind-1063 file-metadata event (preview) ---"
    "${NAK}" event -k 1063 -c "${content}" "${EVENT_TAGS[@]}" --sec "${SEC_HEX}"

    if [[ "${PUBLISH}" == true ]]; then
        log "    broadcasting registration event to ${#RELAYS[@]} relays..."
        "${NAK}" event -k 1063 -c "${content}" "${EVENT_TAGS[@]}" --sec "${SEC_HEX}" "${RELAYS[@]}" >/dev/null
        log "    registered ${file} under ${NPUB}"
    fi
    PROCESSED=$((PROCESSED+1))
done

echo ""
if [[ "${PROCESSED}" -eq 0 ]]; then
    die "no artifacts processed (all downloads failed - check --version / --type)"
fi
if [[ "${PUBLISH}" == true ]]; then
    log "DONE. ${PROCESSED} artifact(s) uploaded to ${BLOSSOM_SERVER} and registered under ${NPUB}."
    log "Verdict is still to be set in the web UI: ${PAGE_URL}"
else
    echo "DRY RUN - nothing uploaded or broadcast."
    echo "  ${PROCESSED} artifact(s) downloaded and hashed (shown above)."
    echo "  Re-run with --publish to upload to Blossom and broadcast the events."
fi
