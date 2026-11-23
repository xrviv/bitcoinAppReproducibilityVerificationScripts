#!/bin/bash
# bitbox2nova_build.sh v3.7.0 - WalletScrutiny verification script for BitBox02 Nova
# Version: v3.7.0
# Organization: WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-23
# Usage: bitbox2nova_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]
#
# Verifies BitBox02 Nova firmware reproducibility: builds from source via the upstream
# Dockerfile at the release tag, then compares the locally-built unsigned firmware
# against the official signed binary with its first 588 bytes (header + signatures) stripped.
# Host requirements: docker or podman only.
#
# Steps: clone the release tag in a container; build upstream's Dockerfile; download the
# official signed firmware (or use --binary); make the firmware; compare hashes; write
# COMPARISON_RESULTS.yaml only for a real verdict (reproducible, not_reproducible, ftbfs).
#
# DISCLAIMER: examine this script yourself before running it. It is provided as-is,
# without warranty, and may contain bugs or security vulnerabilities. Use at your own risk.

set -eE

# ---- Globals ----------------------------------------------------------------
SCRIPT_VERSION="v3.7.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# readlink -f, not $0: a relative or symlinked invocation would otherwise hash nothing.
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
repo="https://github.com/BitBoxSwiss/bitbox02-firmware"
# Fully qualified: podman refuses short image names without a prompt (ABS compliance B4).
ALPINE_IMAGE="docker.io/library/alpine:latest"
# Lines that mark a network/download failure in docker, apt, git, wget, curl, cargo or go
# output. Checked in the last 40 lines of a failed step: such a failure is no verdict.
NETWORK_ERROR_PATTERN='Temporary failure (in name resolution|resolving)|Could not resolve|Failed to fetch|Connection (timed out|refused|reset)|Network is unreachable|Could not connect|SSL error|TLS handshake|received early EOF|unable to access|curl: \([0-9]+\)|failed to download|error sending request|spurious network error|dial tcp|i/o timeout|unexpected EOF|failed to resolve source metadata|toomanyrequests'

firmwareType="btc"
version=""
binaryPath=""
ARCH=""

HOST_UID=$(id -u)
HOST_GID=$(id -g)

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Per-run resources; empty until created so the EXIT trap knows what exists.
CONTAINER_CMD=""
workDir=""
IMAGE_TAG=""
CTR_NAME=""
CTR_PID=""
VERDICT_WRITTEN=0

log_warn() { echo -e "${YELLOW}Warning: $*${NC}"; }

# ---- Self-identification ----------------------------------------------------
# Never fails the run: a hashing problem is not a build outcome.
sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

# ---- Results writer (single-line notes, minimal 3-field YAML) ---------------
write_results() {
  local verdict="$1"
  local notes="$2"
  notes="${notes//\\/ }"
  notes="${notes//\"/\'}"
  notes="${notes//$'\n'/ }"
  notes="${notes//$'\r'/ }"
  # Written to a temp file and renamed, so a reader never sees a half-written file.
  # Parallel runs from one directory still share this file. No copy goes into the
  # workspace: ABS searches its build dir recursively (ABS compliance B6).
  local tmp="${RESULTS_FILE}.$$"
  cat > "$tmp" << EOY
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: "${notes}"
EOY
  mv -f "$tmp" "$RESULTS_FILE"
  VERDICT_WRITTEN=1
  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

# No verdict: invalid input, missing runtime, network or other infrastructure failure,
# a stop, or an official file that cannot be used. ABS publishes any YAML it finds, so
# none is written; the EXIT trap reports it (ABS compliance B5/B7).
no_verdict() {
  local code="$1"; shift
  echo -e "${RED}Error: $*${NC}"
  exit "$code"
}

# True when the last 40 lines of a step's log show a network/download error.
network_failure_in() {
  sleep 1  # let tee flush the last lines
  [[ -s "$1" ]] && tail -n 40 "$1" | grep -Eqi "$NETWORK_ERROR_PATTERN" || return 1
  echo -e "${RED}Matched network error: $(tail -n 40 "$1" | grep -Eim1 "$NETWORK_ERROR_PATTERN")${NC}"
}

# ---- Ownership helpers ------------------------------------------------------
# Docker containers run as real root; chown inside the container correctly sets
# host ownership to HOST_UID:HOST_GID.
#
# Rootless Podman maps container root (UID 0) to the real host user, so files
# created as root are already accessible. However chown to a non-zero UID inside
# a rootless Podman container maps to a subordinate host UID (~subuid range), making
# files inaccessible. Strategy: skip in-container chown for Podman; use
# podman unshare chown on the host side instead.
INNER_CHOWN=":"

repair_ownership() {
  if [[ "$CONTAINER_CMD" == "podman" ]]; then
    # Inside podman unshare, UID 0 maps to the real host user (the rootless namespace
    # puts the caller at UID 0). Using HOST_UID:HOST_GID here would map to the subuid
    # range instead, making files inaccessible.
    podman unshare chown -R 0:0 "$1" 2>/dev/null || true
  fi
}

# Hands the whole workspace back to the caller; never fails the script.
hand_back_workspace() {
  [[ -n "$workDir" && -d "$workDir" ]] || return 0
  if [[ "$CONTAINER_CMD" == "podman" ]]; then
    podman unshare chown -R 0:0 "$workDir" 2>/dev/null || true
  elif [[ "$CONTAINER_CMD" == "docker" ]]; then
    docker run --rm --volume "$workDir:/w" "$ALPINE_IMAGE" \
      chown -R "${HOST_UID}:${HOST_GID}" /w >/dev/null 2>&1 || true
  fi
  local stray
  stray="$(find "$workDir" ! -uid "$HOST_UID" -print -quit 2>/dev/null || true)"
  if [[ -n "$stray" ]]; then
    log_warn "could not hand back ownership of: $stray"
  else
    echo "Workspace ownership: all files owned by uid ${HOST_UID} ($workDir)"
  fi
}

# ---- EXIT / signal traps ----------------------------------------------------
# Runs on every exit (success, failure, interrupt): stops this run's container,
# removes this run's image, hands the workspace back, and guarantees a verdict.
finish() {
  local rc=$?
  trap - ERR INT TERM
  set +e
  # Kill the container first: its PID 1 (sh) ignores a forwarded SIGTERM.
  if [[ -n "$CONTAINER_CMD" && -n "$CTR_NAME" ]]; then
    $CONTAINER_CMD kill "$CTR_NAME" >/dev/null 2>&1
    $CONTAINER_CMD rm -f "$CTR_NAME" >/dev/null 2>&1
  fi
  if [[ -n "$CTR_PID" ]] && kill -0 "$CTR_PID" 2>/dev/null; then
    kill "$CTR_PID" 2>/dev/null; wait "$CTR_PID" 2>/dev/null
  fi
  if [[ -n "$CONTAINER_CMD" && -n "$IMAGE_TAG" ]]; then
    $CONTAINER_CMD rmi --force "$IMAGE_TAG" >/dev/null 2>&1
  fi
  hand_back_workspace
  if [[ "$VERDICT_WRITTEN" -eq 0 ]]; then
    echo -e "${RED}No verdict: COMPARISON_RESULTS.yaml not written (exit ${rc}).${NC}"
  fi
  case "$rc" in
    0|1|2|130|143) exit "$rc" ;;
    *)             exit "$EXIT_FAIL" ;;
  esac
}
trap finish EXIT
trap 'echo; echo "Interrupted (SIGINT)."; exit 130' INT
trap 'echo; echo "Terminated (SIGTERM)."; exit 143' TERM

# ---- ERR trap ---------------------------------------------------------------
handle_err() {
  local rc=$?
  echo -e "${RED}Unexpected error (exit ${rc}); not a source build result.${NC}"
  exit "$EXIT_FAIL"
}
trap handle_err ERR

# Runs a container in the background and waits for it, so INT/TERM reach the
# traps immediately instead of after the container finishes.
# With CTR_LOG set, output is also appended there so a failure can be classified.
ctr_run() {
  if [[ -n "${CTR_LOG:-}" ]]; then
    $CONTAINER_CMD run --name "$CTR_NAME" "$@" > >(tee -a "$CTR_LOG") 2>&1 &
  else
    $CONTAINER_CMD run --name "$CTR_NAME" "$@" &
  fi
  CTR_PID=$!
  wait "$CTR_PID"
  local rc=$?
  CTR_PID=""
  return "$rc"
}

# ---- Root check -------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
  echo -e "${RED}Error: do not run this script as root.${NC}"
  exit "$EXIT_INVALID"
fi

# ---- Disclaimer -------------------------------------------------------------
echo -e "${YELLOW}"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Use at your own risk."
echo "=============================================================================="
echo -e "${NC}"
sleep 2
echo

# ---- Announce script identity ----------------------------------------------
# Before argument parsing and before any container/network work, so even a run
# that exits early records which script bytes produced it.
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
echo "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "         sha256: ${SCRIPT_SHA256}"
echo

# A stale result from an earlier run must never be mistaken for this run's verdict.
rm -f "$RESULTS_FILE"

# ---- Container runtime detection --------------------------------------------
if command -v docker &>/dev/null && docker info &>/dev/null; then
  CONTAINER_CMD="docker"
  INNER_CHOWN="chown -R ${HOST_UID}:${HOST_GID}"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
  no_verdict "$EXIT_FAIL" "docker is installed but its daemon is not responding, and podman is unavailable."
else
  no_verdict "$EXIT_FAIL" "neither docker nor podman found. Install one of them."
fi
echo "Container runtime: $CONTAINER_CMD"

# ---- Usage ------------------------------------------------------------------
usage() {
  echo 'NAME
       bitbox2nova_build.sh - verify BitBox02 Nova hardware wallet firmware

SYNOPSIS
       bitbox2nova_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]

DESCRIPTION
       --version   Firmware version (e.g., "9.23.3"). Required.
       --type      Firmware type: btc|multi (default: btc)
       --binary    Official firmware file, or a directory containing it. If omitted, downloaded.
       --arch      Accepted for compatibility; ignored (build is always linux/amd64).
       --apk       Accepted for compatibility; ignored (not applicable to firmware).

EXAMPLES
       bitbox2nova_build.sh --version 9.23.3
       bitbox2nova_build.sh --version 9.23.3 --type multi
       bitbox2nova_build.sh --version 9.23.3 --type btc --binary /path/to/firmware.bin'
}

# ---- Argument parsing (unknown args warn and continue; never fatal) ----------
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}";      shift 2 || shift ;;
    --type)    firmwareType="${2:-}"; shift 2 || shift ;;
    --binary)  binaryPath="${2:-}";   shift 2 || shift ;;
    --arch)    ARCH="${2:-}";         shift 2 || shift ;;
    --apk)                            shift 2 || shift ;;
    --help)    usage; trap - EXIT; exit "$EXIT_OK" ;;
    *)         log_warn "Ignoring unknown parameter: $1"; shift ;;
  esac
done
[[ -n "$ARCH" ]] && echo "Arch: ${ARCH} (ignored; firmware is always built for linux/amd64)"

# ---- Validate inputs --------------------------------------------------------
if [[ -z "$version" ]]; then
  usage
  no_verdict "$EXIT_INVALID" "--version is required."
fi

if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*([._-][A-Za-z0-9]+)?$ ]]; then
  no_verdict "$EXIT_INVALID" "--version '${version}' contains unsafe characters."
fi

# bitBox2Nova.md's `types:` key is "btc-only"; ABS passes it verbatim. Unknown
# --type is an error, not a silent default -- a typo on --type multi must not
# silently verify the wrong firmware edition.
case "${firmwareType,,}" in
  btc|btc-only|btconly|bitcoin-only|bitcoinonly|bitcoin) firmwareType="btc" ;;
  multi|multicoin)                                       firmwareType="multi" ;;
  *)
    no_verdict "$EXIT_INVALID" "--type '${firmwareType}' is invalid. Must be: btc or multi."
    ;;
esac

# ---- Type-specific variables ------------------------------------------------
GIT_TAG="firmware/v${version}"

if [[ "$firmwareType" == "btc" ]]; then
  MAKE_COMMAND="make firmware-btc"
  BUILT_FIRMWARE_PATH="build/bin/firmware-btc.bin"
  SIGNED_FILENAME="firmware-bitbox02nova-btconly.v${version}.signed.bin"
  SIGNED_GLOB="firmware-bitbox02nova-btconly.*.signed.bin"
  # Pre-v9.25.1 BTC-only editions used a separate tag; from v9.25.1 unified under firmware/vX.
  LEGACY_TAG="firmware-btc-only/v${version}"
  # Product id per src/bootloader/bootloader_product.h (magic 0x48714774).
  EXPECTED_PRODUCT_ID=4
else
  MAKE_COMMAND="make firmware"
  BUILT_FIRMWARE_PATH="build/bin/firmware.bin"
  SIGNED_FILENAME="firmware-bitbox02nova-multi.v${version}.signed.bin"
  SIGNED_GLOB="firmware-bitbox02nova-multi.*.signed.bin"
  LEGACY_TAG=""
  # Product id per src/bootloader/bootloader_product.h (magic 0x5b648ceb).
  EXPECTED_PRODUCT_ID=3
fi

# --binary may be a directory (ABS passes one for multi-file submissions). Prefer the
# release file name; otherwise take the single file matching this type's builds: pattern.
if [[ -n "$binaryPath" && -d "$binaryPath" ]]; then
  binDir="${binaryPath%/}"
  if [[ -f "$binDir/$SIGNED_FILENAME" ]]; then
    binaryPath="$binDir/$SIGNED_FILENAME"
  else
    shopt -s nullglob
    matches=("$binDir"/$SIGNED_GLOB)
    shopt -u nullglob
    if [[ "${#matches[@]}" -eq 1 ]]; then
      binaryPath="${matches[0]}"
    else
      no_verdict "$EXIT_INVALID" "expected one ${SIGNED_GLOB} in ${binDir}, found ${#matches[@]}."
    fi
  fi
fi
if [[ -n "$binaryPath" && ! -f "$binaryPath" ]]; then
  no_verdict "$EXIT_INVALID" "binary file not found: $binaryPath"
fi
if [[ -n "$binaryPath" ]] && ! [[ "$binaryPath" =~ ^/ ]]; then
  binaryPath="$PWD/$binaryPath"
fi

echo
echo "Verifying BitBox02 Nova firmware v${version} (${firmwareType})"
echo

# ---- Prepare workspace ------------------------------------------------------
# Per-run directory under the caller's physical cwd, created exclusively: an
# existing path may belong to another run or user and is never reused or deleted.
# Subdirectories keep the cloned repo clean:
#   src/      — cloned source (never written to after clone; git must stay clean)
#   official/ — official signed firmware binary
#   out/      — comparison outputs (hash files, diag, stripped binary, byte diff)
echo "Setting up verification environment..."
WORK_BASE="$(pwd -P)"
for _attempt in 1 2 3; do
  RUN_ID="$(date +%s)-$$"
  candidate="${WORK_BASE}/bitbox02nova_verification_${version}_${firmwareType}_${RUN_ID}"
  if mkdir "$candidate" 2>/dev/null; then
    workDir="$candidate"
    break
  fi
  log_warn "workspace ${candidate} already exists; retrying with a new run id"
  sleep 1
done
if [[ -z "$workDir" ]]; then
  no_verdict "$EXIT_FAIL" "could not create a fresh workspace under ${WORK_BASE}."
fi
mkdir "$workDir/official" "$workDir/out"
IMAGE_TAG="bitbox02nova-firmware_${version}_${firmwareType}_${RUN_ID}"
CTR_NAME="bitbox02nova-${firmwareType}-${RUN_ID}"
echo "Workspace: $workDir"

# ---- Clone + tag resolution inside container --------------------------------
# For BTC-only pre-v9.25.1, the upstream used firmware-btc-only/vX; from v9.25.1
# everything unified under firmware/vX. Probe the legacy tag inside Alpine first.
echo "Resolving upstream tag and cloning repository..."
MAX_RETRIES=3
retry_count=0
while [[ $retry_count -lt $MAX_RETRIES ]]; do
  if ctr_run --rm \
    --volume "$workDir:/work" \
    "$ALPINE_IMAGE" \
    sh -c "
      set -e
      trap '${INNER_CHOWN} /work 2>/dev/null || true' EXIT
      rm -rf /work/src
      apk add --no-cache git >/dev/null 2>&1
      RESOLVED_TAG='firmware/v${version}'
      if [ -n '${LEGACY_TAG}' ]; then
        if git ls-remote --tags '${repo}' 'refs/tags/${LEGACY_TAG}' 2>/dev/null \
            | grep -q 'refs/tags/${LEGACY_TAG}\$'; then
          RESOLVED_TAG='${LEGACY_TAG}'
        fi
      fi
      echo \"\$RESOLVED_TAG\" > /work/resolved_tag.txt
      git clone --branch \"\$RESOLVED_TAG\" --recurse-submodules '${repo}' /work/src
      cd /work/src
      git fetch --tags
      git rev-parse HEAD > /work/commit.txt
    "; then
    break
  fi
  retry_count=$(( retry_count + 1 ))
  if [[ $retry_count -eq $MAX_RETRIES ]]; then
    repair_ownership "$workDir"
    no_verdict "$EXIT_FAIL" "failed to clone ${repo} at the release tag after $MAX_RETRIES attempts (network, or tag not found)."
  fi
  echo "Clone failed, retrying in 5 seconds..."
  sleep 5
done
repair_ownership "$workDir"

GIT_TAG=$(cat "$workDir/resolved_tag.txt")
commit=$(cat "$workDir/commit.txt")
echo "Resolved tag: $GIT_TAG"
echo "Commit: $commit"
echo

# ---- Check for Nova-specific make targets (read-only, host grep is fine) ----
if grep -q "firmware-nova" "$workDir/src/Makefile" 2>/dev/null; then
  if [[ "$firmwareType" == "btc" ]]; then
    MAKE_COMMAND="make firmware-nova-btc"
    BUILT_FIRMWARE_PATH="build/bin/firmware-nova-btc.bin"
  else
    MAKE_COMMAND="make firmware-nova"
    BUILT_FIRMWARE_PATH="build/bin/firmware-nova.bin"
  fi
  echo "Nova-specific make targets detected: using $MAKE_COMMAND"
fi

# From v9.28.0 upstream builds with `make firmware EDITION=...` into
# build-bitbox02-cmake-relwithdebinfo/bin/ (releases/README.md, "Releases from
# v9.28.0 onwards"); the firmware-btc target and build/bin/ output are gone. The
# unsigned binary is the same for BitBox02 and Nova (same README), so the default
# PRODUCT=bitbox02 build is the one to compare; the edition check below still
# requires the Nova magic.
IFS=. read -r _maj _min _ <<< "${version%%[-_]*}"
if (( 10#${_maj:-0} > 9 || (10#${_maj:-0} == 9 && 10#${_min:-0} >= 28) )); then
  NEW_BUILD_DIR="build-bitbox02-cmake-relwithdebinfo/bin"
  if [[ "$firmwareType" == "btc" ]]; then
    MAKE_COMMAND="make firmware EDITION=btc-only"
    BUILT_FIRMWARE_PATH="${NEW_BUILD_DIR}/firmware-btc.bin"
  else
    MAKE_COMMAND="make firmware EDITION=multi"
    BUILT_FIRMWARE_PATH="${NEW_BUILD_DIR}/firmware.bin"
  fi
  echo "v9.28.0+ build system: using $MAKE_COMMAND"
fi

# ---- Patch Dockerfile inside container (no host sed required) ---------------
cp "$workDir/src/Dockerfile" "$workDir/Dockerfile.orig"

ctr_run --rm \
  --volume "$workDir/src:/src" \
  "$ALPINE_IMAGE" \
  sh -c "
    set -e
    if [ '${GIT_TAG}' = 'firmware/v9.15.0' ] || [ '${GIT_TAG}' = 'firmware-btc-only/v9.15.0' ]; then
      sed -i 's|cargo install bindgen-cli --version 0.65.1\$|cargo install bindgen-cli --version 0.65.1 --locked|' /src/Dockerfile
    fi
    # Always patch Go to linux-amd64 regardless of host arch -- build is forced linux/amd64.
    sed -i 's|go1.19.3.linux-\${TARGETARCH}|go1.19.3.linux-amd64|g' /src/Dockerfile
    ${INNER_CHOWN} /src/Dockerfile
  "
repair_ownership "$workDir/src/Dockerfile"

# ---- Build Docker image -----------------------------------------------------
# Backgrounded + wait so a signal can cancel the build through the trap.
echo "Building Docker image (this may take 10-20 minutes)..."
IMAGE_LOG="$workDir/out/image-build.log"
$CONTAINER_CMD build \
  --pull \
  --platform linux/amd64 \
  --force-rm \
  --no-cache \
  --tag "$IMAGE_TAG" \
  "$workDir/src" > >(tee -a "$IMAGE_LOG") 2>&1 &
CTR_PID=$!
if ! wait "$CTR_PID"; then
  CTR_PID=""
  echo -e "${RED}Docker build failed!${NC}"
  if network_failure_in "$IMAGE_LOG"; then
    no_verdict "$EXIT_FAIL" "upstream build image failed on a network/download error, not a source build failure."
  fi
  write_results "ftbfs" "BitBox02 Nova v${version} (${firmwareType}): upstream Dockerfile build environment failed to build (no network error found)."
  exit "$EXIT_FAIL"
fi
CTR_PID=""

cp "$workDir/Dockerfile.orig" "$workDir/src/Dockerfile"

# ---- Get official firmware --------------------------------------------------
if [[ -n "$binaryPath" ]]; then
  echo "Using provided binary: $binaryPath"
  cp "$binaryPath" "$workDir/official/$SIGNED_FILENAME"
else
  echo "Downloading official signed firmware..."
  RELEASE_TAG_PATH="${GIT_TAG//\//%2F}"
  DOWNLOAD_URL="${repo}/releases/download/${RELEASE_TAG_PATH}/${SIGNED_FILENAME}"
  echo "URL: $DOWNLOAD_URL"
  retry_count=0
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    if ctr_run --rm \
      --volume "$workDir/official:/out" \
      "$ALPINE_IMAGE" \
      sh -c "
        set -e
        trap '${INNER_CHOWN} /out 2>/dev/null || true' EXIT
        apk add --no-cache wget >/dev/null 2>&1
        wget -O '/out/${SIGNED_FILENAME}' '${DOWNLOAD_URL}'
      "; then
      break
    fi
    retry_count=$(( retry_count + 1 ))
    if [[ $retry_count -eq $MAX_RETRIES ]]; then
      repair_ownership "$workDir/official"
      no_verdict "$EXIT_FAIL" "failed to download the official firmware after $MAX_RETRIES attempts."
    fi
    echo "Download failed, retrying in 5 seconds..."
    sleep 5
  done
  repair_ownership "$workDir/official"
fi

if [[ ! -s "$workDir/official/$SIGNED_FILENAME" ]]; then
  no_verdict "$EXIT_FAIL" "official firmware file missing or empty."
fi

# ---- Build firmware + compare (all inside build container) ------------------
# Three volumes keep responsibilities isolated:
#   /bb02     = source repo (read/write for build artifacts, must stay git-clean)
#   /official = official signed binary (read-only input)
#   /out      = all comparison outputs (hash files, diagnostics, stripped binary)
echo "Building firmware ($MAKE_COMMAND) and running comparison..."
# /out/stage records how far the container got, so a failure is classified correctly:
# none = setup (dirty tree), building = make failed, no-output = make made no firmware,
# compare = hashing/edition check (an edition mismatch also writes /out/edition_mismatch).
BUILD_LOG="$workDir/out/firmware-build.log"
CTR_LOG="$BUILD_LOG"
if ! ctr_run --rm \
  --platform linux/amd64 \
  --volume "$workDir/src:/bb02" \
  --volume "$workDir/official:/official" \
  --volume "$workDir/out:/out" \
  "$IMAGE_TAG" \
  bash -c "
    set -eo pipefail
    # Runs on every exit from this shell, success or failure -- make writes build
    # artifacts into /bb02 (host \$workDir/src) as root, and a failed build (dirty
    # tree, compile error, edition mismatch) must not skip cleanup: that is exactly
    # when leftovers matter, per non-sudo-directories-guideline.md.
    trap '${INNER_CHOWN} /bb02 /out 2>/dev/null || true' EXIT
    git config --global --add safe.directory /bb02
    cd /bb02

    # Abort if the source tree is dirty — BitBox02 embeds git metadata (including
    # 'dirty'/'pre') in the firmware version string, changing the binary output.
    git_status=\$(git status --porcelain)
    if [[ -n \"\$git_status\" ]]; then
      echo 'ABORT: source tree is dirty (git status --porcelain):' >&2
      echo \"\$git_status\" >&2
      exit 1
    fi

    echo building > /out/stage
    ${MAKE_COMMAND}

    SIGNED='/official/${SIGNED_FILENAME}'
    BUILT='/bb02/${BUILT_FIRMWARE_PATH}'
    if [[ ! -s \"\$BUILT\" ]]; then
      echo no-output > /out/stage
      echo \"ABORT: make succeeded but \$BUILT is missing or empty\" >&2
      exit 1
    fi
    echo compare > /out/stage

    sha256sum \"\$SIGNED\" | awk '{print \$1}' > /out/hash_signed.txt
    sha256sum \"\$BUILT\"  | awk '{print \$1}' > /out/hash_built.txt

    # Upstream signed firmware layout (describe_signed_firmware.py):
    #   4 bytes magic + 584 bytes sigdata + unsigned firmware
    # Total header = 588 bytes for both btconly and multi.
    HEADER_BYTES=588
    dd if=\"\$SIGNED\" bs=1 skip=\"\${HEADER_BYTES}\" of=/out/p_stripped.bin 2>/dev/null
    sha256sum /out/p_stripped.bin | awk '{print \$1}' > /out/hash_stripped.txt

    # Full byte-level diff (offset, official octal, built octal) when hashes differ;
    # evidence only, the verdict comes from the hashes above.
    if [[ \"\$(cat /out/hash_stripped.txt)\" != \"\$(cat /out/hash_built.txt)\" ]]; then
      cmp -l /out/p_stripped.bin \"\$BUILT\" > /out/diff_full.txt 2>&1 || true
    fi

    # Diagnostic: log file sizes and parser-derived hash for post-run analysis.
    python3 -c \"
import hashlib, sys, os
MAGIC_LEN = 4; SIGDATA_LEN = 584
data = open(sys.argv[1], 'rb').read()
firmware = data[MAGIC_LEN + SIGDATA_LEN:]
print('diag_signed_size:', len(data))
print('diag_parser_unsigned_size:', len(firmware))
print('diag_parser_unsigned_hash:', hashlib.sha256(firmware).hexdigest())
built_size = os.path.getsize(sys.argv[2])
print('diag_built_size:', built_size)
if len(firmware) != built_size:
    print('WARNING: size mismatch parser_unsigned=' + str(len(firmware)) + ' built=' + str(built_size))
\" \"\$SIGNED\" \"\$BUILT\" > /out/diag.txt 2>&1 || true
    cat /out/diag.txt

    # Edition check + device firmware hash, mirroring upstream releases/describe_signed_firmware.py.
    #
    # The 4-byte magic identifies the edition; it must match the edition this run targets.
    # This matters especially for Nova: at releases where the Nova and BitBox02 payloads are
    # byte-identical, a wrong-edition --binary would otherwise still compare equal and yield a
    # false 'Nova reproducible'.
    #
    # The hash the device shows at boot depends on the monotonic firmware version. Cutoffs mirror
    # upstream releases/describe_signed_firmware.py and releases/README.md at firmware/v9.29.0:
    #   through 50: sha256d(version + padded_firmware)
    #   51 to 56:   sha256(product_id_le16 + version + padded_firmware)
    #   from 57:    sha256(0x01 + product_id_le16 + version + padded_firmware)
    python3 -c \"
import hashlib, struct, sys
MAGIC_LEN = 4; SIGDATA_LEN = 584; VERSION_OFF = 392; MAX_FIRMWARE_SIZE = 884736
NEW_SIGHASH_VERSION_CUTOFF = 51
VERSIONED_SIGHASH_VERSION_CUTOFF = 57
# magic -> (product_id, label); product ids per src/bootloader/bootloader_product.h
EDITIONS = {
    '653f362b': (1, 'BitBox02 Multi'),
    '11233b0b': (2, 'BitBox02 Bitcoin-only'),
    '5b648ceb': (3, 'BitBox02 Nova Multi'),
    '48714774': (4, 'BitBox02 Nova Bitcoin-only'),
}
expected_pid = int(sys.argv[2])
data = open(sys.argv[1], 'rb').read()
magic = data[:MAGIC_LEN].hex()
if magic not in EDITIONS:
    print('ABORT: unrecognized firmware edition magic 0x' + magic, file=sys.stderr)
    open('/out/edition_mismatch', 'w').write(magic + '\\n')
    sys.exit(1)
product_id, label = EDITIONS[magic]
if product_id != expected_pid:
    print('ABORT: edition mismatch -- binary is ' + label + ' (magic 0x' + magic +
          '), but this run targets product id ' + str(expected_pid), file=sys.stderr)
    open('/out/edition_mismatch', 'w').write(magic + '\\n')
    sys.exit(1)
version = data[VERSION_OFF:VERSION_OFF + 4]
firmware = data[MAGIC_LEN + SIGDATA_LEN:]
padded = firmware + b'\\xff' * (MAX_FIRMWARE_SIZE - len(firmware))
monotonic = struct.unpack('<I', version)[0]
if monotonic >= VERSIONED_SIGHASH_VERSION_CUTOFF:
    device_hash = hashlib.sha256(b'\\x01' + struct.pack('<H', product_id) + version + padded).hexdigest()
    scheme = 'sha256(0x01 + product_id_le16 + version + padded), version >= 57'
elif monotonic >= NEW_SIGHASH_VERSION_CUTOFF:
    device_hash = hashlib.sha256(struct.pack('<H', product_id) + version + padded).hexdigest()
    scheme = 'sha256(product_id_le16 + version + padded), version 51-56'
else:
    device_hash = hashlib.sha256(hashlib.sha256(version + padded).digest()).hexdigest()
    scheme = 'legacy sha256d(version + padded), version <= 50'
open('/out/hash_device.txt', 'w').write(device_hash + '\\n')
open('/out/edition.txt', 'w').write(label + '\\n')
open('/out/monotonic.txt', 'w').write(str(monotonic) + '\\n')
open('/out/device_hash_scheme.txt', 'w').write(scheme + '\\n')
print('edition: ' + label + ' (magic 0x' + magic + ', product id ' + str(product_id) + ')')
print('monotonic version: ' + str(monotonic))
print('device hash scheme: ' + scheme)
\" \"\$SIGNED\" '${EXPECTED_PRODUCT_ID}'

  "; then
  # The container's own EXIT trap already ran chown/no-op as appropriate; podman's
  # rootless case still needs the host-side unshare repair, and needs it on this
  # failure path too -- a crashed build is exactly when leftovers matter most.
  CTR_LOG=""
  repair_ownership "$workDir/src"
  repair_ownership "$workDir/out"
  echo -e "${RED}Build or comparison failed!${NC}"
  stage="$(cat "$workDir/out/stage" 2>/dev/null || echo none)"
  case "$stage" in
    building)
      if network_failure_in "$BUILD_LOG"; then
        no_verdict "$EXIT_FAIL" "firmware build stopped on a network/download error, not a source build failure."
      fi
      write_results "ftbfs" "BitBox02 Nova v${version} (${firmwareType}): ${MAKE_COMMAND} failed at ${GIT_TAG}."
      exit "$EXIT_FAIL" ;;
    no-output)
      write_results "ftbfs" "BitBox02 Nova v${version} (${firmwareType}): ${MAKE_COMMAND} produced no ${BUILT_FIRMWARE_PATH}."
      exit "$EXIT_FAIL" ;;
    compare)
      if [[ -e "$workDir/out/edition_mismatch" ]]; then
        no_verdict "$([[ -n "$binaryPath" ]] && echo "$EXIT_INVALID" || echo "$EXIT_FAIL")" \
          "official file is not the ${firmwareType} BitBox02 Nova edition; nothing to compare."
      fi
      no_verdict "$EXIT_FAIL" "hashing or edition check failed after a successful build." ;;
    *)
      no_verdict "$EXIT_FAIL" "build container setup failed before make (for example a dirty source tree)." ;;
  esac
fi
CTR_LOG=""
repair_ownership "$workDir/src"
repair_ownership "$workDir/out"

echo -e "${GREEN}Firmware build and comparison completed!${NC}"

# ---- Read hash results ------------------------------------------------------
signedHash=$(cat "$workDir/out/hash_signed.txt")
builtHash=$(cat "$workDir/out/hash_built.txt")
downloadStrippedSigHash=$(cat "$workDir/out/hash_stripped.txt")
downloadFirmwareHash=$(cat "$workDir/out/hash_device.txt")
edition=$(cat "$workDir/out/edition.txt")
monotonicVersion=$(cat "$workDir/out/monotonic.txt")
deviceHashScheme=$(cat "$workDir/out/device_hash_scheme.txt")

echo ""
echo "============================================================"
echo "VERIFICATION RESULTS:"
echo "Edition:                     $edition"
echo "Monotonic version:           $monotonicVersion"
echo "Signed download:             $signedHash"
echo "Signed download minus sig:   $downloadStrippedSigHash"
echo "Built binary:                $builtHash"
echo "Firmware hash (on device):   $downloadFirmwareHash"
echo "Device hash scheme:          $deviceHashScheme"
echo "============================================================"

if [[ "$downloadStrippedSigHash" == "$builtHash" ]]; then
  verdict="reproducible"
  exit_code="$EXIT_OK"
  echo -e "${GREEN}REPRODUCIBLE: built firmware matches unsigned content${NC}"
else
  verdict="not_reproducible"
  exit_code="$EXIT_FAIL"
  echo -e "${RED}NOT REPRODUCIBLE: firmware hashes differ${NC}"
fi

cat <<LEGEND

----- What these hashes mean -----
appHash       SHA-256 of the signed firmware exactly as downloaded from the GitHub
              release. THIS is the official download hash to publish.
deviceHash    The hash the device shows at boot (bootloader 1.2.2 or later). A user
              comparing the device screen must use this one, not appHash.
unsignedHash  The official file with its first 588 bytes (edition marker and
              signatures) removed. Published nowhere, shown by no device.
builtHash     SHA-256 of the unsigned firmware this script built from source.

MATCH means builtHash == unsignedHash. Do not publish unsignedHash or builtHash
as the official hash.
LEGEND

echo ""
echo "===== Begin Results ====="
echo "firmware:     BitBox02 Nova"
echo "version:      $version"
echo "type:         $firmwareType"
echo "verdict:      $verdict"
echo "appHash:      $signedHash"
echo "builtHash:    $builtHash"
echo "unsignedHash: $downloadStrippedSigHash"
echo "deviceHash:   $downloadFirmwareHash"
echo "edition:      $edition"
echo "monotonic:    $monotonicVersion"
echo "repository:   $repo"
echo "tag:          $GIT_TAG"
echo "commit:       $commit"
echo "scriptVersion: ${SCRIPT_VERSION}"
echo "scriptHash:    ${SCRIPT_SHA256}"
echo "===== End Results ====="

# ---- Diff preview (at most 5 lines; full diff stays in the workspace) -------
if [[ -s "$workDir/out/diff_full.txt" ]]; then
  echo ""
  echo "First differing bytes (offset, official octal, built octal), 5 of $(wc -l < "$workDir/out/diff_full.txt") lines:"
  head -n 5 "$workDir/out/diff_full.txt"
  echo "Full byte diff: $workDir/out/diff_full.txt"
fi

# ---- Write COMPARISON_RESULTS.yaml ------------------------------------------
if [[ "$verdict" == "reproducible" ]]; then
  notes="BitBox02 Nova v${version} (${firmwareType}) reproducible from source at ${GIT_TAG} (commit ${commit}). Comparison: first 588 bytes (4 magic + 584 sigdata) stripped from official signed binary; SHA-256 of remainder matches unsigned build output."
else
  notes="BitBox02 Nova v${version} (${firmwareType}) not reproducible. Built hash ${builtHash} does not match unsigned official payload hash ${downloadStrippedSigHash} after stripping 588 bytes (4 magic + 584 sigdata) from ${SIGNED_FILENAME}."
fi

write_results "$verdict" "$notes"

# Image removal and workspace hand-back happen in the EXIT trap.
echo
echo "BitBox02 Nova firmware verification finished!"
echo "Results: $RESULTS_FILE"

exit "$exit_code"
