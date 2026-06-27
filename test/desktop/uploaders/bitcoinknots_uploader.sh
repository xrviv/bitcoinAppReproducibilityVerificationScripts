#!/bin/bash
#
# bitcoinknots_uploader.sh - Upload official Bitcoin Knots release artifacts to Blossom
#                            and register each on Nostr (NIP-94 / kind 1063), so the
#                            WalletScrutiny web UI lists them as "to be verified".
#
# Version: v0.1.0
#
# WHAT THIS DOES
#   Mirrors liana_uploader.sh / sparrow_uploader.sh. For each official Bitcoin Knots
#   desktop artifact it (1) uploads the file to a Blossom mediaserver and (2) publishes
#   ONE NIP-94 file-metadata event (kind 1063) per artifact, anchoring the file by its
#   SHA256. Registering the artifact makes it show up on the WS page so it can be picked
#   up for reproducibility verification.
#
#   Per WalletScrutiny's per-artifact verdict model (Leo): each desktop artifact is an
#   independent unit of verification, so this tool emits one event PER artifact (not one
#   bundled event). Run it once per artifact (or with --type all) as needed.
#
# WHAT THIS DOES NOT DO  (important)
#   It does NOT assign a reproducibility verdict. On WalletScrutiny the verdict is set ONLY
#   in the web UI (the verification results event). This tool merely anchors the official
#   artifacts publicly so a verification can reference them by hash.
#
# WHICH BYTES ARE UPLOADED
#   The WHOLE official release file, unmodified (the .tar.gz / .zip / .exe exactly as
#   published on GitHub). So the Blossom address EQUALS the SHA256 published in the Knots
#   release `SHA256SUMS`. The outer hash is the download identity; reproducibility itself
#   is proven by bitcoinknotsdesktop_build.sh (Guix) comparing the built artifact bytes.
#
# SCOPE
#   Bitcoin Knots ships many assets per release. This tool intentionally registers ONLY the
#   primary verifiable binary distributables and EXCLUDES:
#     - macOS (*-apple-darwin*)          (out of scope per WS desktop verification)
#     - debug bundles (*-debug*)
#     - codesigning payloads (*-codesigning*, codesignatures-*)
#     - unsigned intermediates (*-unsigned*)
#     - source tarball (bitcoin-<ver>.tar.gz, no arch), *.desc.html, SHA256SUMS*
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

SCRIPT_VERSION="v0.1.0"
APP_ID="bitcoinknots"
PLATFORM="desktop"
PAGE_URL="https://walletscrutiny.com/desktop/bitcoinknots/"
RELEASES_REPO="bitcoinknots/bitcoin"
BLOSSOM_SERVER="${WS_BLOSSOM_SERVER:-https://files.nostr.info}"
RELAYS=(wss://relay.nostr.info wss://nostr.mom wss://relay.primal.net wss://relay.damus.io wss://nos.lol)
NAK="${NAK:-nak}"
# Shared WalletScrutiny uploader identity - reused by ALL uploader scripts (sparrow,
# liana, passportprime, this one). Override per-run with WS_UPLOAD_KEYFILE.
KEYFILE="${WS_UPLOAD_KEYFILE:-$HOME/.config/walletscrutiny/uploader.hexkey}"
# Blossom auth-event validity window (seconds). Must comfortably exceed the time to
# transfer the largest artifact, or the server rejects with "Auth expired" (400).
# Knots tarballs are larger than Liana's, so the default ceiling is higher.
AUTH_TTL="${WS_BLOSSOM_AUTH_TTL:-3600}"

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
bitcoinknots_uploader.sh ${SCRIPT_VERSION} - upload + register Bitcoin Knots Desktop artifacts

Usage:
  $0 --version VERSION [--type LIST] [--publish] [--server URL] [--keyfile PATH]

  --version VERSION   Knots version WITHOUT the 'v' (e.g. 29.3.knots20260507). Required.
                      (The release tag is 'v<VERSION>'; this tool adds the 'v'.)
  --type LIST         Comma-separated artifact keys, or a group, or 'all'. Default: all.
                      Groups:  all | linux | windows
                      Keys:    x86_64-linux aarch64-linux arm-linux powerpc64-linux
                               powerpc64le-linux riscv64-linux win64-zip win64-exe
                      macOS is intentionally NOT offered (out of scope).
  --publish           Actually upload to Blossom and broadcast the kind-1063 events.
                      Omit for a dry run (default: shows everything, sends nothing).
  --server URL        Blossom mediaserver (default: ${BLOSSOM_SERVER}).
  --keyfile PATH      Nostr identity hex-key file (default: ${KEYFILE}).
  -h, --help          This help.

Examples:
  $0 --version 29.3.knots20260507                       # dry run, all 8 artifacts
  $0 --version 29.3.knots20260507 --type linux --publish # register the 6 Linux tarballs
  $0 --version 29.3.knots20260507 --type win64-zip,win64-exe --publish

This only ANCHORS the official artifacts. The reproducibility verdict itself is assigned
exclusively in the WalletScrutiny web UI: ${PAGE_URL}
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
# Knots release tags carry a 'v' prefix (e.g. v29.3.knots20260507).
DL_BASE="https://github.com/${RELEASES_REPO}/releases/download/v${V}"

# ---- preflight: confirm the release tag exists (one clear error beats N per-asset 404s) ----
if ! curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases/tags/v${V}" >/dev/null 2>&1; then
    warn "No Knots release found for tag 'v${V}'."
    avail="$(curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=12" 2>/dev/null \
        | grep -oE '"tag_name": *"v[0-9][^"]*"' | sed -E 's/^.*"(v[0-9][^"]*)"$/\1/' | tr '\n' ' ')"
    [[ -n "${avail}" ]] && warn "Available release tags: ${avail}"
    die "Pass an exact released version WITHOUT the leading 'v' (e.g. --version 29.3.knots20260507)."
fi

# ---- artifact catalogue: key -> filename | mime ----
# NOTE: Windows assets use the '-pgpverifiable' suffix (confirmed present as far back as
# 29.3.knots20260210; no plain win64.zip / win64-setup.exe exists in any known release).
# Downloads that 404 are skipped with a warning for forward-compatibility.
declare -A ART_FILE ART_MIME
ART_FILE[x86_64-linux]="bitcoin-${V}-x86_64-linux-gnu.tar.gz";       ART_MIME[x86_64-linux]="application/gzip"
ART_FILE[aarch64-linux]="bitcoin-${V}-aarch64-linux-gnu.tar.gz";     ART_MIME[aarch64-linux]="application/gzip"
ART_FILE[arm-linux]="bitcoin-${V}-arm-linux-gnueabihf.tar.gz";       ART_MIME[arm-linux]="application/gzip"
ART_FILE[powerpc64-linux]="bitcoin-${V}-powerpc64-linux-gnu.tar.gz"; ART_MIME[powerpc64-linux]="application/gzip"
ART_FILE[powerpc64le-linux]="bitcoin-${V}-powerpc64le-linux-gnu.tar.gz"; ART_MIME[powerpc64le-linux]="application/gzip"
ART_FILE[riscv64-linux]="bitcoin-${V}-riscv64-linux-gnu.tar.gz";     ART_MIME[riscv64-linux]="application/gzip"
ART_FILE[win64-zip]="bitcoin-${V}-win64-pgpverifiable.zip";          ART_MIME[win64-zip]="application/zip"
ART_FILE[win64-exe]="bitcoin-${V}-win64-setup-pgpverifiable.exe";    ART_MIME[win64-exe]="application/vnd.microsoft.portable-executable"

LINUX_KEYS=(x86_64-linux aarch64-linux arm-linux powerpc64-linux powerpc64le-linux riscv64-linux)
WINDOWS_KEYS=(win64-zip win64-exe)
ALL_KEYS=("${LINUX_KEYS[@]}" "${WINDOWS_KEYS[@]}")

# ---- resolve requested keys ----
declare -a KEYS=()
case "${TYPES_ARG}" in
    all)     KEYS=("${ALL_KEYS[@]}") ;;
    linux)   KEYS=("${LINUX_KEYS[@]}") ;;
    windows) KEYS=("${WINDOWS_KEYS[@]}") ;;
    *)       IFS=',' read -ra KEYS <<< "${TYPES_ARG}" ;;
esac
for k in "${KEYS[@]}"; do
    [[ -n "${ART_FILE[$k]:-}" ]] || die "unknown --type '${k}' (valid: ${ALL_KEYS[*]} | all | linux | windows)"
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

WORK="$(mktemp -d -t bitcoinknotsupload.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log "Bitcoin Knots ${V} - processing ${#KEYS[@]} artifact(s): ${KEYS[*]}"

PROCESSED=0
for k in "${KEYS[@]}"; do
    file="${ART_FILE[$k]}"
    mime="${ART_MIME[$k]}"
    url="${DL_BASE}/${file}"
    out="${WORK}/${file}"

    echo ""
    echo "----- ${k}: ${file} -----"
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
    content="Bitcoin Knots Desktop v${V} (${k}: ${file}) - WalletScrutiny registered artifact.
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
        -t "type=${k}"
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
