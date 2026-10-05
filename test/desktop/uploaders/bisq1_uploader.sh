#!/bin/bash
#
# bisq1_uploader.sh - Upload verified Bisq 1 Desktop release artifacts to Blossom
#                     and register each on Nostr (NIP-94 / kind 1063).
#
# Version: v0.2.2
#
# WHAT THIS DOES
#   Mirrors bisq2_uploader.sh / liana_uploader.sh / nunchuk_uploader.sh. For each official
#   Bisq 1 desktop artifact it (1) uploads the file to a Blossom mediaserver and (2) publishes
#   ONE NIP-94 file-metadata event (kind 1063) per artifact, anchoring the file by its SHA256.
#
#   Per WalletScrutiny's per-artifact verdict model (Leo): each desktop artifact is an
#   independent unit of verification, so this tool emits one event PER artifact (not one
#   bundled event). Run it once per artifact, as each artifact's verification completes.
#
# DUPLICATE DETECTION  (v0.2.0)
#   Before anything else, each artifact's SHA256 is checked against what WalletScrutiny already
#   has on Nostr - both asset-registration events (kind 1063) and verification-result events
#   (kind 30301), which is exactly what walletscrutiny.com/desktop/bisq renders. The hash is
#   stored in the events' 'x' tag, so we query '#x=<hash>' over the WS relays. If ANY event
#   already references that exact hash, the artifact is already anchored and we SKIP it (no
#   re-upload, no duplicate 1063). Use --force to upload anyway. The check runs in dry-run too,
#   so a plain dry run tells you which release artifacts still need uploading.
#
# WHAT THIS DOES NOT DO  (important)
#   It does NOT assign a reproducibility verdict. On WalletScrutiny the verdict is set ONLY
#   in the web UI (the verification results event). This tool merely anchors the official
#   artifacts publicly so a verification can reference them by hash.
#
# WHICH BYTES ARE UPLOADED
#   The WHOLE official release file, unmodified (the .deb / .rpm / .exe installer). So the
#   Blossom address EQUALS the SHA256 listed in the release (and shown on the WS page). The
#   installer hash is the *download identity*; reproducibility is proven by bisq1desktop_build.sh,
#   which rebuilds and compares the package. The verdict lives in the web UI.
#
#   Scope: deb, rpm, exe - the Bisq 1 desktop installers. macOS .dmg builds are not reproduced
#   by our pipeline, so they are intentionally NOT uploaded here.
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
#   Optional: jq (enables the relay side of duplicate detection; without it only the local
#   backup is consulted). grep/sort/wc are used for the dedup tallies.
#
# Organization: WalletScrutiny.com
#

set -euo pipefail

SCRIPT_VERSION="v0.2.2"
APP_ID="bisq"
PLATFORM="desktop"
PAGE_URL="https://walletscrutiny.com/desktop/bisq/"
RELEASES_REPO="bisq-network/bisq"
BLOSSOM_SERVER="${WS_BLOSSOM_SERVER:-https://files.nostr.info}"
RELAYS=(wss://relay.nostr.info wss://nostr.mom wss://relay.primal.net wss://relay.damus.io wss://nos.lol)
# Relays queried for the duplicate-hash check. relay.nostr.info is WalletScrutiny's mainRelayUrl
# and the one that actually indexes the single-letter 'x' tag; the others are queried as a
# best-effort union in case data has propagated. Kinds: 1063 (asset registration) + 30301
# (verification results) - the two kinds that carry the artifact hash in their 'x' tag.
CHECK_RELAYS=(wss://relay.nostr.info wss://relay.nostr.band wss://relay.primal.net wss://relay.damus.io wss://nos.lol wss://nostr.mom)
CHECK_KINDS=(1063 30301)
# Local Nostr backup (./backup/nostr-verification-events in the walletScrutinyCom checkout).
# Consulted as a SECOND source for the duplicate check because relays only retain a recent
# window, while the backup holds historical events the relays may have dropped. Existence-gated.
WS_NOSTR_BACKUP_DIR="${WS_NOSTR_BACKUP_DIR:-$HOME/work/walletScrutinyCom/backup/nostr-verification-events}"
NAK="${NAK:-nak}"
# Shared WalletScrutiny uploader identity - reused by ALL uploader scripts (sparrow,
# passportprime, liana, nunchuk, bisq2, bisq1, future ones). Override per-run with WS_UPLOAD_KEYFILE.
KEYFILE="${WS_UPLOAD_KEYFILE:-$HOME/.config/walletscrutiny/uploader.hexkey}"
# Blossom auth-event validity window (seconds). Must comfortably exceed the time to
# transfer the largest artifact, or the server rejects with "Auth expired" (400).
AUTH_TTL="${WS_BLOSSOM_AUTH_TTL:-1800}"

APP_VERSION=""
TYPES_ARG="all"
PUBLISH=false
FORCE=false

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

# nostr_hash_count HASH
#   Echoes how many DISTINCT pieces of evidence say HASH is already anchored by WalletScrutiny:
#     (a) events on the WS relays whose 'x' tag equals HASH (kinds in CHECK_KINDS), and
#     (b) local-backup event files that contain HASH.
#   Returns 0 only when nothing references the hash. Two safeguards:
#     - Relay results are RE-VERIFIED with jq (some relays ignore tag filters and return noise),
#       so only events that genuinely carry ["x", HASH] are counted.
#     - Relay/network errors are swallowed (counted as 0 found), so a transient relay outage
#       never makes a needed upload look "already present". The backup pass still runs.
#   A one-line breakdown (relays=.. backup=..) is printed to stderr for transparency.
nostr_hash_count() {
    local hash="$1" kflags=() k rc=0 bc=0
    for k in "${CHECK_KINDS[@]}"; do kflags+=(-k "$k"); done

    if command -v jq >/dev/null 2>&1; then
        rc="$(timeout 30 "${NAK}" req "${kflags[@]}" -t x="${hash}" "${CHECK_RELAYS[@]}" 2>/dev/null \
            | jq -rc --arg h "${hash}" 'select(any(.tags[]?; .[0]=="x" and .[1]==$h)) | .id' 2>/dev/null \
            | sort -u | grep -c . || true)"
    else
        warn "jq not found - skipping the relay duplicate check (backup still consulted)."
        rc=0
    fi
    [[ -n "${rc}" ]] || rc=0

    if [[ -d "${WS_NOSTR_BACKUP_DIR}" ]]; then
        bc="$(grep -rl -- "${hash}" "${WS_NOSTR_BACKUP_DIR}" 2>/dev/null | grep -c . || true)"
    fi
    [[ -n "${bc}" ]] || bc=0

    echo "[INFO]     nostr duplicate check: relays=${rc} backup=${bc}" >&2
    echo "$(( rc + bc ))"
}

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
bisq1_uploader.sh ${SCRIPT_VERSION} - upload + register Bisq 1 Desktop artifacts

Usage:
  $0 --version VERSION [--type LIST] [--publish] [--server URL] [--keyfile PATH]

  --version VERSION   Bisq 1 version WITHOUT the 'v' (e.g. 1.10.2). Required.
                      (The Bisq 1 release tag carries a 'v', e.g. 'v1.10.2'; the asset
                      filenames use the 'Bisq-64bit-' prefix, e.g. 'Bisq-64bit-1.10.2.deb'.)
  --type LIST         Comma-separated artifact types, or 'all'. Default: all.
                      Valid: deb, rpm, exe
                      (deb/rpm = x86_64 Linux installers; exe = x86_64 Windows installer)
  --publish           Actually upload to Blossom and broadcast the kind-1063 events.
                      Omit for a dry run (default: shows everything, sends nothing).
  --force             Upload even if the artifact's SHA256 is already anchored on Nostr
                      (skips the duplicate-detection check). Default: skip duplicates.
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
        --force)   FORCE=true; shift ;;
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
# Bisq 1 release tags carry a 'v' prefix (e.g. v1.10.2) - like Bisq 2 and Liana.
DL_BASE="https://github.com/${RELEASES_REPO}/releases/download/v${V}"

# ---- preflight: confirm the release tag exists (one clear error beats N per-asset 404s) ----
if ! curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases/tags/v${V}" >/dev/null 2>&1; then
    warn "No Bisq 1 release found for tag 'v${V}'."
    avail="$(curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=12" 2>/dev/null \
        | grep -oE '"tag_name": *"v[0-9][^"]*"' | sed -E 's/^.*"(v[0-9][^"]*)"$/\1/' | tr '\n' ' ')"
    [[ -n "${avail}" ]] && warn "Recent release tags: ${avail}"
    die "Pass an exact released version WITHOUT the leading 'v' (e.g. --version 1.10.2)."
fi

# ---- artifact catalogue: type -> filename | mime ----
# Bisq 1 asset names use the 'Bisq-64bit-' prefix (e.g. Bisq-64bit-1.10.2.deb).
declare -A ART_FILE ART_MIME
ART_FILE[deb]="Bisq-64bit-${V}.deb"; ART_MIME[deb]="application/vnd.debian.binary-package"
ART_FILE[rpm]="Bisq-64bit-${V}.rpm"; ART_MIME[rpm]="application/x-rpm"
ART_FILE[exe]="Bisq-64bit-${V}.exe"; ART_MIME[exe]="application/vnd.microsoft.portable-executable"

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

WORK="$(mktemp -d -t bisq1upload.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log "Bisq 1 ${V} - processing ${#TYPES[@]} artifact(s): ${TYPES[*]}"

PROCESSED=0
SKIPPED=0
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

    # ---- duplicate detection: is this exact hash already anchored on WS Nostr? ----
    if [[ "${FORCE}" == true ]]; then
        echo "  --force: skipping the Nostr duplicate check"
    else
        echo "  checking WalletScrutiny Nostr for this hash (kinds ${CHECK_KINDS[*]})..."
        already="$(nostr_hash_count "${hash}")"
        if [[ "${already}" -gt 0 ]]; then
            log "    ALREADY ANCHORED: ${already} event(s) on Nostr reference ${hash}"
            log "    skipping ${file} (use --force to upload anyway). See ${PAGE_URL}"
            SKIPPED=$((SKIPPED+1))
            continue
        fi
        echo "    not found on Nostr - this artifact still needs uploading"
    fi

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
    content="Uploaded by Danny's CLI uploader"
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
echo "------------------------------------------------------------"
echo " Summary for Bisq 1 v${V}"
echo "   already anchored on Nostr (skipped): ${SKIPPED}"
echo "   still needing upload (processed):     ${PROCESSED}"
echo "------------------------------------------------------------"
if [[ "${PROCESSED}" -eq 0 && "${SKIPPED}" -eq 0 ]]; then
    die "no artifacts processed (all downloads failed - check --version / --type)"
fi
if [[ "${PROCESSED}" -eq 0 ]]; then
    log "Nothing to do: every requested artifact for v${V} is already anchored on Nostr."
    log "Verdict is set in the web UI: ${PAGE_URL}"
elif [[ "${PUBLISH}" == true ]]; then
    log "DONE. ${PROCESSED} artifact(s) uploaded to ${BLOSSOM_SERVER} and registered under ${NPUB}."
    log "Verdict is still to be set in the web UI: ${PAGE_URL}"
else
    echo "DRY RUN - nothing uploaded or broadcast."
    echo "  ${PROCESSED} artifact(s) downloaded and hashed and NOT yet on Nostr (shown above)."
    echo "  Re-run with --publish to upload to Blossom and broadcast the events."
fi
