#!/bin/bash
#
# bitcoincore_uploader.sh - Upload official Bitcoin Core release artifacts to Blossom
#                           and register each on Nostr (NIP-94 / kind 1063), so the
#                           WalletScrutiny web UI lists them as "to be verified".
#
# Version: v0.1.0
#
# WHAT THIS DOES
#   Mirrors bitcoinknots_uploader.sh. For each official Bitcoin Core desktop artifact
#   it (1) uploads the file to a Blossom mediaserver and (2) publishes ONE NIP-94
#   file-metadata event (kind 1063) per artifact, anchoring the file by its SHA256.
#   Registering the artifact makes it appear on the WS page ready for verification.
#
# WHAT THIS DOES NOT DO
#   It does NOT assign a reproducibility verdict. That is set exclusively in the
#   WalletScrutiny web UI after a verifier runs bitcoincore_build.sh.
#
# NEW: --check-releases
#   Bitcoin Core is unusual: it actively releases patches for MULTIPLE major versions
#   simultaneously (e.g. v28.4 ships alongside v31.0). This mode scans ALL GitHub
#   releases, checks Blossom presence per artifact, and also queries the Nostr relay
#   for existing kind-30301 verification events. Artifacts missing from Blossom are
#   listed as upload candidates at the end.
#
#   Use 'latest' (default) to check only the highest patch per major.minor branch
#   (e.g. 28.4, 29.3, 30.2, 31.0). Use 'all' to check every published release.
#
# SCOPE (8 artifact types per release)
#   Linux tarballs  : x86_64, aarch64, arm, powerpc64, riscv64
#   Windows (pre-signing): win64-unsigned.zip, win64-setup-unsigned.exe
#   Excluded: macOS, debug bundles (*-debug*), codesigning payloads
#             (*-codesigning*), source tarball (bitcoin-<V>.tar.gz), SHA256SUMS*.
#
# WINDOWS NOTE
#   Core's verifiable Windows files carry the '-unsigned' suffix. These pre-Authenticode
#   artifacts are what we and guix.sigs attest to; the signed release is NOT compared.
#
# IDENTITY
#   Uses the shared WalletScrutiny uploader keypair. Generated on first run and
#   persisted. Override location with WS_UPLOAD_KEYFILE.
#
# SAFETY
#   Dry-run by DEFAULT (downloads + hashes + prints events, uploads NOTHING, broadcasts
#   NOTHING). Add --publish to actually upload to Blossom and broadcast.
#
# Requirements (host): nak, curl, sha256sum, stat, coreutils.
#
# Organization: WalletScrutiny.com
#

set -euo pipefail

SCRIPT_VERSION="v0.1.1"
APP_ID="bitcoincore"
PLATFORM="desktop"
PAGE_URL="https://walletscrutiny.com/desktop/bitcoincore/"
RELEASES_REPO="bitcoin/bitcoin"
BLOSSOM_SERVER="${WS_BLOSSOM_SERVER:-https://files.nostr.info}"
RELAYS=(wss://relay.nostr.info wss://nostr.mom wss://relay.primal.net wss://relay.damus.io wss://nos.lol)
NAK="${NAK:-nak}"
KEYFILE="${WS_UPLOAD_KEYFILE:-$HOME/.config/walletscrutiny/uploader.hexkey}"
AUTH_TTL="${WS_BLOSSOM_AUTH_TTL:-3600}"

APP_VERSION=""
TYPES_ARG="all"
PUBLISH=false
CHECK_RELEASES_SCOPE=""   # empty = upload mode; 'latest' or 'all' = release-check mode

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

# ---- artifact catalogue helpers ----
# Returns the filename for a given artifact key and Core version string.
get_filename() {
    local key="$1" ver="$2"
    case "${key}" in
        x86_64-linux)      echo "bitcoin-${ver}-x86_64-linux-gnu.tar.gz" ;;
        aarch64-linux)     echo "bitcoin-${ver}-aarch64-linux-gnu.tar.gz" ;;
        arm-linux)         echo "bitcoin-${ver}-arm-linux-gnueabihf.tar.gz" ;;
        powerpc64-linux)   echo "bitcoin-${ver}-powerpc64-linux-gnu.tar.gz" ;;
        riscv64-linux)     echo "bitcoin-${ver}-riscv64-linux-gnu.tar.gz" ;;
        win64-zip)         echo "bitcoin-${ver}-win64-unsigned.zip" ;;
        win64-exe)         echo "bitcoin-${ver}-win64-setup-unsigned.exe" ;;
        *) echo ""; return 1 ;;
    esac
}

get_mime() {
    local key="$1"
    case "${key}" in
        *-linux)   echo "application/gzip" ;;
        win64-zip) echo "application/zip" ;;
        win64-exe) echo "application/vnd.microsoft.portable-executable" ;;
        *)         echo "application/octet-stream" ;;
    esac
}

LINUX_KEYS=(x86_64-linux aarch64-linux arm-linux powerpc64-linux riscv64-linux)
WINDOWS_KEYS=(win64-zip win64-exe)
ALL_KEYS=("${LINUX_KEYS[@]}" "${WINDOWS_KEYS[@]}")

# blossom_upload FILE EXPECTED_SHA256
#   Uploads FILE to the Blossom server via a BUD-02 PUT /upload with a kind-24242
#   auth event (expiration = now + AUTH_TTL). Shows a live progress bar.
blossom_upload() {
    local file="$1" want="$2" exp authb64 resp got
    exp=$(( $(date -u +%s) + AUTH_TTL ))
    authb64="$("${NAK}" event -k 24242 -t t=upload -t "x=${want}" -t "expiration=${exp}" \
        -c "Upload $(basename "${file}")" --sec "${SEC_HEX}" | base64 -w0)" || return 1
    resp="$(curl -f -L --progress-bar -T "${file}" \
        -H "Authorization: Nostr ${authb64}" "${BLOSSOM_SERVER}/upload")" || return 1
    got="$(printf '%s' "${resp}" | grep -oE '[0-9a-f]{64}' | head -1 || true)"
    [[ "${got}" == "${want}" ]] || { warn "server returned sha256 '${got}' != '${want}'"; return 2; }
    return 0
}

usage() {
    cat <<EOF
bitcoincore_uploader.sh ${SCRIPT_VERSION} - upload + register Bitcoin Core Desktop artifacts

Usage:
  $0 --version VERSION [--type LIST] [--publish] [--server URL] [--keyfile PATH]
  $0 --check-releases [latest|all] [--server URL]

UPLOAD MODE (requires --version):
  --version VERSION   Core version WITHOUT the leading 'v' (e.g. 31.0 or 28.4). Required.
  --type LIST         Comma-separated artifact keys, a group, or 'all'. Default: all.
                      Groups:  all | linux | windows
                      Keys:    x86_64-linux aarch64-linux arm-linux
                               powerpc64-linux riscv64-linux
                               win64-zip win64-exe
  --publish           Actually upload to Blossom and broadcast kind-1063 events.
                      Omit for a dry run (default: shows everything, sends nothing).
  --server URL        Blossom mediaserver (default: ${BLOSSOM_SERVER}).
  --keyfile PATH      Nostr identity hex-key file (default: ${KEYFILE}).

RELEASE CHECK MODE:
  --check-releases [latest|all]
      Scan all GitHub bitcoin/bitcoin releases. For each version and artifact type:
        ✅ Blossom  — artifact is present on the Blossom server (by SHA256)
        ✅ Nostr    — a kind-30301 verification event exists for this hash
        ❌          — missing; artifact is added to the upload queue printed at the end

      latest  Check only the highest patch per active major branch (v28+, default).
              (e.g. 28.4, 29.3, 30.2, 31.0 — pre-v28 are EOL and skipped)
      all     Check every single published release (can be 30+ versions).

      Core actively maintains multiple major-version branches simultaneously, so older
      releases like 28.4 can appear after newer ones like 31.0.

      Does NOT upload or broadcast anything.

Examples:
  $0 --check-releases                         # scan latest per branch (fast)
  $0 --check-releases all                     # scan every version ever published
  $0 --version 31.0                           # dry run — show 8 artifacts, no upload
  $0 --version 28.4 --type linux --publish    # upload + register all 6 linux tarballs
  $0 --version 31.0 --type win64-zip,win64-exe --publish

This only ANCHORS official artifacts on Blossom. The reproducibility verdict itself is
assigned exclusively in the WalletScrutiny web UI: ${PAGE_URL}
EOF
}

# ---- argument parsing ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ -n "${2:-}" ]] || die "--version needs a value"; APP_VERSION="$2"; shift 2 ;;
        --type)    [[ -n "${2:-}" ]] || die "--type needs a value"; TYPES_ARG="$2"; shift 2 ;;
        --publish) PUBLISH=true; shift ;;
        --server)  [[ -n "${2:-}" ]] || die "--server needs a value"; BLOSSOM_SERVER="$2"; shift 2 ;;
        --keyfile) [[ -n "${2:-}" ]] || die "--keyfile needs a value"; KEYFILE="$2"; shift 2 ;;
        --check-releases)
            shift
            if [[ "${1:-}" == "all" || "${1:-}" == "latest" ]]; then
                CHECK_RELEASES_SCOPE="$1"; shift
            else
                CHECK_RELEASES_SCOPE="latest"
            fi ;;
        -h|--help) usage; exit 0 ;;
        *) warn "ignoring unknown argument: $1"; shift ;;
    esac
done

command -v "${NAK}" >/dev/null 2>&1 || die "nak not found (set NAK=/path/to/nak)"
command -v curl     >/dev/null 2>&1 || die "curl required"

# ===========================================================================
# CHECK RELEASES MODE
# ===========================================================================
if [[ -n "${CHECK_RELEASES_SCOPE}" ]]; then
    [[ "${CHECK_RELEASES_SCOPE}" == "latest" || "${CHECK_RELEASES_SCOPE}" == "all" ]] \
        || die "--check-releases scope must be 'latest' or 'all'"

    log "Fetching release list from github.com/${RELEASES_REPO}..."
    releases_json="$(curl -fsSL \
        "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=100" 2>/dev/null)" \
        || die "Failed to fetch GitHub releases"

    # Extract stable version strings (strip 'v' prefix, exclude RC/beta tags)
    mapfile -t ALL_VERSIONS < <(
        printf '%s' "${releases_json}" \
        | grep -oE '"tag_name": *"v[0-9][0-9]*\.[0-9][^"]*"' \
        | sed -E 's/.*"v([0-9][^"]*)"$/\1/' \
        | grep -Ev 'rc|beta|alpha|test' \
        | sort -V
    )
    [[ ${#ALL_VERSIONS[@]} -gt 0 ]] || die "No stable release tags found in GitHub API response"

    # 'latest' scope: keep only the highest patch per active major branch (v28+).
    # Pre-v28 releases are EOL and use different artifact naming conventions.
    # Branch key: major number for new-style (22, 28, 29…), "0.minor" for old-style (0.10, 0.21…).
    declare -a CHECK_VERSIONS=()
    if [[ "${CHECK_RELEASES_SCOPE}" == "latest" ]]; then
        declare -A BRANCH_BEST
        for v in "${ALL_VERSIONS[@]}"; do
            major="$(printf '%s' "${v}" | cut -d. -f1)"
            # Skip pre-v28 releases — EOL, different artifact naming
            [[ "${major}" -ge 28 ]] 2>/dev/null || continue
            branch="${major}"
            BRANCH_BEST["${branch}"]="${v}"
        done
        mapfile -t CHECK_VERSIONS < <(printf '%s\n' "${BRANCH_BEST[@]}" | sort -V)
    else
        CHECK_VERSIONS=("${ALL_VERSIONS[@]}")
    fi

    log "Scope: ${CHECK_RELEASES_SCOPE} → ${#CHECK_VERSIONS[@]} release(s): ${CHECK_VERSIONS[*]}"

    # Batch-fetch kind-30301 Nostr verification events for bitcoincore (best effort)
    log "Querying Nostr relay for kind-30301 verifications (timeout 20s)..."
    NOSTR_EVENTS="$(timeout 20 "${NAK}" req -k 30301 -t i=bitcoincore --limit 500 \
        wss://relay.nostr.info 2>/dev/null || true)"
    nostr_count="$(printf '%s\n' "${NOSTR_EVENTS}" | grep -c '"kind"' 2>/dev/null || echo 0)"
    log "  ${nostr_count} verification event(s) retrieved."

    declare -a UPLOAD_QUEUE=()
    echo ""
    printf '%-8s  %-22s  %-7s  %-7s  %s\n' "Version" "Artifact" "Blossom" "Nostr" "Hash (first 16 chars)"
    printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for v in "${CHECK_VERSIONS[@]}"; do
        # Binaries are hosted on bitcoincore.org, not as GitHub release assets.
        # GitHub is used only for tags/metadata; the actual files live on the CDN.
        sha_url="https://bitcoincore.org/bin/bitcoin-core-${v}/SHA256SUMS"
        sha_content="$(curl -fsSL "${sha_url}" 2>/dev/null || true)"
        if [[ -z "${sha_content}" ]]; then
            warn "v${v}: SHA256SUMS not available on bitcoincore.org (possibly removed; skipping)"
            continue
        fi

        for k in "${ALL_KEYS[@]}"; do
            fname="$(get_filename "${k}" "${v}")"
            h="$(printf '%s' "${sha_content}" | grep " ${fname}$" | awk '{print $1}' || true)"
            [[ -z "${h}" ]] && continue  # artifact doesn't exist for this version

            # Blossom presence check (HEAD request via hash, no download)
            blossom_ok="❌"
            if "${NAK}" blossom --server "${BLOSSOM_SERVER}" check "${h}" >/dev/null 2>&1; then
                blossom_ok="✅"
            else
                UPLOAD_QUEUE+=("${v}|${k}|${fname}")
            fi

            # Nostr verification check: look for the artifact's SHA256 in any x tag
            nostr_ok="❌"
            if [[ -n "${NOSTR_EVENTS}" ]]; then
                if printf '%s' "${NOSTR_EVENTS}" | grep -q "\"x\",\"${h}\""; then
                    nostr_ok="✅"
                fi
            fi

            printf '%-8s  %-22s  %-7s  %-7s  %.16s…\n' \
                "${v}" "${k}" "${blossom_ok}" "${nostr_ok}" "${h}"
        done
    done

    echo ""
    if [[ ${#UPLOAD_QUEUE[@]} -gt 0 ]]; then
        log "──── Missing from Blossom — upload queue ────"
        for entry in "${UPLOAD_QUEUE[@]}"; do
            ver="${entry%%|*}"; rest="${entry#*|}"; key="${rest%%|*}"; file="${rest##*|}"
            printf '  --version %-8s  --type %-22s  (%s)\n' "${ver}" "${key}" "${file}"
        done
        echo ""
        log "Upload a single artifact: $0 --version <VERSION> --type <KEY> --publish"
        log "Upload all linux for a version: $0 --version <VERSION> --type linux --publish"
    else
        log "All checked artifacts are present on Blossom. ✅"
    fi
    exit 0
fi

# ===========================================================================
# UPLOAD MODE
# ===========================================================================
[[ -n "${APP_VERSION}" ]] || { usage; die "--version is required (or use --check-releases)"; }

V="${APP_VERSION}"
# Bitcoin Core binaries are hosted on bitcoincore.org, not as GitHub release assets.
DL_BASE="https://bitcoincore.org/bin/bitcoin-core-${V}"

# Build the artifact filename+mime maps for this specific version
declare -A ART_FILE ART_MIME
for k in "${ALL_KEYS[@]}"; do
    ART_FILE[$k]="$(get_filename "${k}" "${V}")"
    ART_MIME[$k]="$(get_mime "${k}")"
done

# Preflight: confirm the release tag exists (one clear error beats N per-asset 404s)
if ! curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases/tags/v${V}" >/dev/null 2>&1; then
    warn "No Bitcoin Core release found for tag 'v${V}'."
    avail="$(curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases?per_page=12" 2>/dev/null \
        | grep -oE '"tag_name": *"v[0-9][^"]*"' | sed -E 's/.*"(v[0-9][^"]*)"$/\1/' | tr '\n' ' ')"
    [[ -n "${avail}" ]] && warn "Recent release tags: ${avail}"
    die "Pass an exact released version WITHOUT the leading 'v' (e.g. --version 31.0)."
fi

# Resolve requested keys from --type argument
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
    log "No identity found — generating a fresh Nostr keypair..."
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

WORK="$(mktemp -d -t bitcoincoreupload.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

log "Bitcoin Core v${V} - processing ${#KEYS[@]} artifact(s): ${KEYS[*]}"

# ---- Phase 1: fetch SHA256SUMS for preflight hash checks ----
SHA256SUMS_URL="https://bitcoincore.org/bin/bitcoin-core-${V}/SHA256SUMS"
SHA256SUMS_FILE="${WORK}/SHA256SUMS"
declare -A EXPECTED_HASH
log "Fetching SHA256SUMS..."
if curl -fsSL -o "${SHA256SUMS_FILE}" "${SHA256SUMS_URL}" 2>/dev/null; then
    for k in "${KEYS[@]}"; do
        fname="${ART_FILE[$k]}"
        h="$(grep " ${fname}$" "${SHA256SUMS_FILE}" | awk '{print $1}' || true)"
        [[ -n "${h}" ]] && EXPECTED_HASH[$k]="${h}"
    done
    log "Parsed hashes for ${#EXPECTED_HASH[@]} of ${#KEYS[@]} artifact(s) from SHA256SUMS."
else
    warn "Could not fetch SHA256SUMS — all artifacts will be downloaded and hashed locally."
fi

# ---- Phase 2: Blossom preflight — skip downloads for already-uploaded artifacts ----
declare -A BLOSSOM_PRESENT
declare -a NEED_DOWNLOAD=()

echo ""
log "Blossom preflight check (${BLOSSOM_SERVER})..."
for k in "${KEYS[@]}"; do
    if [[ -n "${EXPECTED_HASH[$k]:-}" ]]; then
        h="${EXPECTED_HASH[$k]}"
        if "${NAK}" blossom --server "${BLOSSOM_SERVER}" check "${h}" >/dev/null 2>&1; then
            log "  [${k}] already on Blossom (${h}) — download skipped"
            BLOSSOM_PRESENT[$k]=true
        else
            log "  [${k}] not on Blossom — queued for download"
            BLOSSOM_PRESENT[$k]=false
            NEED_DOWNLOAD+=("${k}")
        fi
    else
        log "  [${k}] no hash in SHA256SUMS — queued for download"
        BLOSSOM_PRESENT[$k]=false
        NEED_DOWNLOAD+=("${k}")
    fi
done

# ---- Phase 3: Download only artifacts not already on Blossom ----
declare -A ACTUAL_HASH ACTUAL_SIZE
if [[ ${#NEED_DOWNLOAD[@]} -gt 0 ]]; then
    echo ""
    log "Downloading ${#NEED_DOWNLOAD[@]} artifact(s)..."
    for k in "${NEED_DOWNLOAD[@]}"; do
        file="${ART_FILE[$k]}"
        url="${DL_BASE}/${file}"
        out="${WORK}/${file}"
        echo ""
        echo "----- ${k}: ${file} -----"
        if ! curl -f -L --progress-bar -o "${out}" "${url}"; then
            warn "download failed (skipping): ${url}"
            warn "  (artifact may not exist for v${V}; check the release page)"
            BLOSSOM_PRESENT[$k]=skip
            continue
        fi
        got="$(sha256sum "${out}" | cut -d' ' -f1)"
        size="$(stat -c%s "${out}")"
        printf '  sha256=%s  size=%s bytes\n' "${got}" "${size}"
        if [[ -n "${EXPECTED_HASH[$k]:-}" && "${got}" != "${EXPECTED_HASH[$k]}" ]]; then
            die "[${k}] hash mismatch! expected ${EXPECTED_HASH[$k]}, got ${got}"
        fi
        ACTUAL_HASH[$k]="${got}"
        ACTUAL_SIZE[$k]="${size}"
    done
else
    echo ""
    log "All artifacts already on Blossom — no downloads needed."
fi

# ---- Phase 4 & 5: Upload missing artifacts + publish kind-1063 for all ----
echo ""
PROCESSED=0
for k in "${KEYS[@]}"; do
    [[ "${BLOSSOM_PRESENT[$k]:-}" == "skip" ]] && continue

    file="${ART_FILE[$k]}"
    mime="${ART_MIME[$k]}"
    url="${DL_BASE}/${file}"
    out="${WORK}/${file}"

    if [[ "${BLOSSOM_PRESENT[$k]}" == true ]]; then
        hash="${EXPECTED_HASH[$k]}"
        size=""
    else
        hash="${ACTUAL_HASH[$k]:-}"
        size="${ACTUAL_SIZE[$k]:-}"
        [[ -n "${hash}" ]] || { warn "[${k}] no hash available (download failed) — skipping"; continue; }
    fi

    echo "----- ${k}: ${file} -----"
    printf '  sha256=%s\n' "${hash}"

    if [[ "${PUBLISH}" == true ]]; then
        if [[ "${BLOSSOM_PRESENT[$k]}" != true ]]; then
            human="$(numfmt --to=iec "${size}" 2>/dev/null || echo "${size}B")"
            echo "  uploading ${file} (${human})..."
            blossom_upload "${out}" "${hash}" || die "blossom upload failed for ${file}"
            log "    uploaded: ${BLOSSOM_SERVER}/${hash}"
        fi
    fi

    blossom_url="${BLOSSOM_SERVER}/${hash}"
    content="Bitcoin Core Desktop v${V} (${k}: ${file}) - WalletScrutiny registered artifact.
SHA256 is the official download hash. Reproducibility verdict: ${PAGE_URL}"

    EVENT_TAGS=(
        -t "url=${blossom_url}"
        -t "x=${hash}"
        -t "ox=${hash}"
        -t "m=${mime}"
        -t "i=${APP_ID}"
        -t "version=${V}"
        -t "platform=${PLATFORM}"
        -t "type=${k}"
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
    die "no artifacts processed (all downloads failed — check --version / --type)"
fi

if [[ "${PUBLISH}" == true ]]; then
    log "DONE. ${PROCESSED} artifact(s) processed; uploaded to ${BLOSSOM_SERVER} and registered under ${NPUB}."
    log "Verdict is still to be set in the web UI: ${PAGE_URL}"
else
    echo "DRY RUN — nothing uploaded or broadcast."
    echo "  ${PROCESSED} artifact(s) checked (shown above)."
    echo "  Re-run with --publish to upload to Blossom and broadcast the events."
fi
