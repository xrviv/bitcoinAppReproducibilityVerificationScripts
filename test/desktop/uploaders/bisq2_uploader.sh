#!/bin/bash
#
# bisq2_uploader.sh - Upload verified Bisq 2 Desktop release artifacts to Blossom
#                     and register each on Nostr (NIP-94 / kind 1063).
#
# Version: v0.1.0
#
# WHAT THIS DOES
#   Mirrors liana_uploader.sh / nunchuk_uploader.sh / sparrow_uploader.sh. For each official
#   Bisq 2 desktop artifact it (1) uploads the file to a Blossom mediaserver and (2) publishes
#   ONE NIP-94 file-metadata event (kind 1063) per artifact, anchoring the file by its SHA256.
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
#   The WHOLE official release file, unmodified (the .deb / .rpm / .exe installer). So the
#   Blossom address EQUALS the SHA256 listed in the release (and shown on the WS page). The
#   installer hash is the *download identity*; reproducibility is proven by bisq2_build.sh,
#   which rebuilds and compares the package. The verdict lives in the web UI.
#
#   Scope: deb, rpm, exe - the artifacts bisq2_build.sh actually verifies. macOS .dmg builds
#   are not reproduced by our pipeline, so they are intentionally NOT uploaded here.
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

SCRIPT_VERSION="v0.2.0"
APP_ID="bisq2"
PLATFORM="desktop"
PAGE_URL="https://walletscrutiny.com/desktop/bisq2/"
RELEASES_REPO="bisq-network/bisq2"
BLOSSOM_SERVER="${WS_BLOSSOM_SERVER:-https://files.nostr.info}"
RELAYS=(wss://relay.nostr.info wss://nostr.mom wss://relay.primal.net wss://relay.damus.io wss://nos.lol)
NAK="${NAK:-nak}"
# Shared WalletScrutiny uploader identity - reused by ALL uploader scripts (sparrow,
# passportprime, liana, nunchuk, bisq2, future ones). Override per-run with WS_UPLOAD_KEYFILE.
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
bisq2_uploader.sh ${SCRIPT_VERSION} - upload + register Bisq 2 Desktop artifacts

Usage:
  $0 --version VERSION [--type LIST] [--publish] [--server URL] [--keyfile PATH]

  --version VERSION   Bisq 2 version WITHOUT the 'v' (e.g. 2.1.11). Required.
                      (The Bisq 2 release tag carries a 'v', e.g. 'v2.1.11'; the asset
                      filenames use the bare version, e.g. 'Bisq-2.1.11.deb'.)
  --type LIST         Comma-separated artifact types, or 'all'. Default: all.
                      Valid: deb, rpm, exe
                      (deb/rpm = x86_64 Linux installers; exe = x86_64 Windows installer)
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
# Bisq 2 release tags carry a 'v' prefix (e.g. v2.1.11) - like Liana, unlike Sparrow/Nunchuk.
DL_BASE="https://github.com/${RELEASES_REPO}/releases/download/v${V}"

# ---- preflight: confirm the release tag exists (one clear error beats N per-asset 404s) ----
if ! curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases/tags/v${V}" >/dev/null 2>&1; then
    warn "No Bisq 2 release found for tag 'v${V}'."
    avail="$(curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=12" 2>/dev/null \
        | grep -oE '"tag_name": *"v[0-9][^"]*"' | sed -E 's/^.*"(v[0-9][^"]*)"$/\1/' | tr '\n' ' ')"
    [[ -n "${avail}" ]] && warn "Recent release tags: ${avail}"
    die "Pass an exact released version WITHOUT the leading 'v' (e.g. --version 2.1.11)."
fi

# ---- artifact catalogue: type -> filename | mime ----
# Asset names use the bare version (e.g. Bisq-2.1.11.deb).
declare -A ART_FILE ART_MIME
ART_FILE[deb]="Bisq-${V}.deb"; ART_MIME[deb]="application/vnd.debian.binary-package"
ART_FILE[rpm]="Bisq-${V}.rpm"; ART_MIME[rpm]="application/x-rpm"
ART_FILE[exe]="Bisq-${V}.exe"; ART_MIME[exe]="application/vnd.microsoft.portable-executable"

# ---- resolve requested types ----
declare -a TYPES=()
if [[ "${TYPES_ARG}" == "all" ]]; then
    TYPES=(deb rpm exe)
else
    IFS=',' read -ra TYPES <<< "${TYPES_ARG}"
fi
for t in "${TYPES[@]}"; do
    [[ -n "${ART_FILE[$t]:-}" ]] || die "unknown --type '${t}' (valid: deb rpm exe)"
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

WORK="$(mktemp -d -t bisq2upload.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log "Bisq 2 ${V} - processing ${#TYPES[@]} artifact(s): ${TYPES[*]}"

# ---- Phase 1: fetch hash manifest to get expected hashes upfront ----
SHA256SUMS_URL="${DL_BASE}/SHA256SUMS"
SHA256SUMS_FILE="${WORK}/SHA256SUMS"
declare -A EXPECTED_HASH
log "Fetching release hash manifest for preflight checks..."
if curl -fsSL -o "${SHA256SUMS_FILE}" "${SHA256SUMS_URL}" 2>/dev/null; then
    for t in "${TYPES[@]}"; do
        fname="${ART_FILE[$t]}"
        h="$(awk -v f="${fname}" '$2==f || $NF==f {print $1; exit}' "${SHA256SUMS_FILE}" | head -1 || true)"
        [[ -n "${h}" ]] && EXPECTED_HASH[$t]="${h}"
    done
    log "Parsed hashes for ${#EXPECTED_HASH[@]} of ${#TYPES[@]} artifact(s) from manifest."
else
    warn "Could not fetch hash manifest — all artifacts will be downloaded."
fi

# ---- Phase 2: Blossom preflight — check which artifacts are already uploaded ----
declare -A BLOSSOM_PRESENT
declare -a NEED_DOWNLOAD=()

echo ""
log "Blossom preflight check (${BLOSSOM_SERVER})..."
for t in "${TYPES[@]}"; do
    if [[ -n "${EXPECTED_HASH[$t]:-}" ]]; then
        h="${EXPECTED_HASH[$t]}"
        if "${NAK}" blossom --server "${BLOSSOM_SERVER}" check "${h}" >/dev/null 2>&1; then
            log "  [${t}] already on Blossom (${h}) — download skipped"
            BLOSSOM_PRESENT[$t]=true
        else
            log "  [${t}] not on Blossom — queued for download"
            BLOSSOM_PRESENT[$t]=false
            NEED_DOWNLOAD+=("${t}")
        fi
    else
        log "  [${t}] no hash in manifest — queued for download"
        BLOSSOM_PRESENT[$t]=false
        NEED_DOWNLOAD+=("${t}")
    fi
done

# ---- Phase 3: Download only artifacts not already on Blossom ----
declare -A ACTUAL_HASH ACTUAL_SIZE
if [[ ${#NEED_DOWNLOAD[@]} -gt 0 ]]; then
    echo ""
    log "Downloading ${#NEED_DOWNLOAD[@]} artifact(s)..."
    for t in "${NEED_DOWNLOAD[@]}"; do
        file="${ART_FILE[$t]}"
        url="${DL_BASE}/${file}"
        out="${WORK}/${file}"
        echo ""
        echo "----- ${t}: ${file} -----"
        if ! curl -f -L --progress-bar -o "${out}" "${url}"; then
            warn "download failed (skipping): ${url}"
            warn "  (this artifact may not exist for ${V}; check the release page)"
            BLOSSOM_PRESENT[$t]=skip
            continue
        fi

        # ---- Phase 4: Redundancy check ----
        got="$(sha256sum "${out}" | cut -d' ' -f1)"
        size="$(stat -c%s "${out}")"
        printf '  sha256=%s  size=%s bytes\n' "${got}" "${size}"
        if [[ -n "${EXPECTED_HASH[$t]:-}" && "${got}" != "${EXPECTED_HASH[$t]}" ]]; then
            die "[${t}] hash mismatch! expected ${EXPECTED_HASH[$t]}, got ${got}"
        fi
        ACTUAL_HASH[$t]="${got}"
        ACTUAL_SIZE[$t]="${size}"
    done
else
    echo ""
    log "All artifacts already on Blossom — no downloads needed."
fi

# ---- Phase 5 & 6: Upload missing + publish kind-1063 for all ----
echo ""
PROCESSED=0
for t in "${TYPES[@]}"; do
    [[ "${BLOSSOM_PRESENT[$t]:-}" == "skip" ]] && continue

    file="${ART_FILE[$t]}"
    mime="${ART_MIME[$t]}"
    url="${DL_BASE}/${file}"

    if [[ "${BLOSSOM_PRESENT[$t]}" == true ]]; then
        hash="${EXPECTED_HASH[$t]}"
        size=""
    else
        hash="${ACTUAL_HASH[$t]:-}"
        size="${ACTUAL_SIZE[$t]:-}"
        [[ -n "${hash}" ]] || { warn "[${t}] no hash available (download failed) — skipping"; continue; }
    fi

    echo "----- ${t}: ${file} -----"
    printf '  sha256=%s\n' "${hash}"

    if [[ "${PUBLISH}" == true ]]; then
        if [[ "${BLOSSOM_PRESENT[$t]}" != true ]]; then
            out="${WORK}/${file}"
            human="$(numfmt --to=iec "${size}" 2>/dev/null || echo "${size}B")"
            echo "  uploading ${file} (${human})..."
            blossom_upload "${out}" "${hash}" || die "blossom upload failed for ${file}"
            log "    uploaded: ${BLOSSOM_SERVER}/${hash}"
        fi
    fi

    blossom_url="${BLOSSOM_SERVER}/${hash}"
    content="Bisq 2 Desktop v${V} (${t}: ${file}) - WalletScrutiny verified artifact.
SHA256 is the official download hash. Reproducibility verdict: ${PAGE_URL}"

    EVENT_TAGS=(
        -t "url=${blossom_url}"
        -t "x=${hash}"
        -t "ox=${hash}"
        -t "m=${mime}"
        -t "i=${APP_ID}"
        -t "version=${V}"
        -t "platform=${PLATFORM}"
        -t "type=${t}"
        -t "client=WalletScrutiny.com"
        -t "r=${PAGE_URL}"
        -t "r=${url}"
    )
    [[ -n "${size}" ]] && EVENT_TAGS+=(-t "size=${size}")

    echo "  --- kind-1063 file-metadata event (preview) ---"
    "${NAK}" event -k 1063 -c "${content}" "${EVENT_TAGS[@]}" --sec "${SEC_HEX}"

    if [[ "${PUBLISH}" == true ]]; then
        log "    broadcasting registration event to ${#RELAYS[@]} relays..."
        "${NAK}" event -k 1063 -c "${content}" "${EVENT_TAGS[@]}" --sec "${SEC_HEX}" "${RELAYS[@]}" >/dev/null
        log "    registered ${file} under ${NPUB}"
    fi
    PROCESSED=$((PROCESSED+1))
    echo ""
done

if [[ "${PROCESSED}" -eq 0 ]]; then
    die "no artifacts processed (all downloads failed - check --version / --type)"
fi
if [[ "${PUBLISH}" == true ]]; then
    log "DONE. ${PROCESSED} artifact(s) processed; uploaded to ${BLOSSOM_SERVER} and registered under ${NPUB}."
    log "Verdict is still to be set in the web UI: ${PAGE_URL}"
else
    echo "DRY RUN - nothing uploaded or broadcast."
    echo "  ${PROCESSED} artifact(s) checked (shown above)."
    echo "  Re-run with --publish to upload to Blossom and broadcast the events."
fi
