#!/bin/bash
# bitbox02_build.sh v3.7.0 - WalletScrutiny verification script for BitBox02
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Date last modified: 2026-06-29 (v3.7.0)
# Usage: bitbox02_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]
#
# Verifies BitBox02 firmware reproducibility: builds from source via the upstream
# Dockerfile at the release tag, then compares the locally-built unsigned firmware
# against the official signed binary with its first 588 bytes (header + signatures) stripped.
# Host requirements: docker or podman only.

set -eE

# ---- Globals ----------------------------------------------------------------
SCRIPT_VERSION="v3.7.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
repo="https://github.com/BitBoxSwiss/bitbox02-firmware"

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

# ---- Results writer (single-line notes, minimal 3-field YAML) ---------------
write_results() {
  local verdict="$1"
  local notes="$2"
  notes="${notes//\\/ }"
  notes="${notes//\"/\'}"
  notes="${notes//$'\n'/ }"
  notes="${notes//$'\r'/ }"
  cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: "${notes}"
EOF
  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

# ---- ERR trap ---------------------------------------------------------------
handle_err() {
  local rc=$?
  echo -e "${RED}Unexpected error (exit ${rc}).${NC}"
  write_results "ftbfs" "BitBox02 v${version:-?} (${firmwareType}): unexpected error (exit ${rc}) during verification."
  exit "$EXIT_FAIL"
}
trap handle_err ERR

# ---- Root check -------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
  echo -e "${RED}Error: do not run this script as root.${NC}"
  exit "$EXIT_FAIL"
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

# ---- Container runtime detection --------------------------------------------
if command -v docker &>/dev/null && docker info &>/dev/null; then
  CONTAINER_CMD="docker"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
  echo -e "${RED}Error: docker is installed but its daemon is not responding, and podman is unavailable.${NC}"
  write_results "ftbfs" "BitBox02: docker daemon not responding and podman unavailable."
  exit "$EXIT_FAIL"
else
  echo -e "${RED}Error: neither docker nor podman found. Install one of them.${NC}"
  write_results "ftbfs" "BitBox02: no container runtime (docker/podman) available on host."
  exit "$EXIT_FAIL"
fi
echo "Container runtime: $CONTAINER_CMD"

# ---- Ownership helpers ------------------------------------------------------
# Docker containers run as real root; chown inside the container correctly sets
# host ownership to HOST_UID:HOST_GID.
#
# Rootless Podman maps container root (UID 0) to the real host user, so files
# created as root are already accessible. However chown to a non-zero UID inside
# a rootless Podman container maps to a subordinate host UID (~subuid range), making
# files inaccessible. Strategy: skip in-container chown for Podman; use
# podman unshare chown on the host side instead.
if [[ "$CONTAINER_CMD" == "docker" ]]; then
  INNER_CHOWN="chown -R ${HOST_UID}:${HOST_GID}"
else
  INNER_CHOWN=":"
fi

repair_ownership() {
  if [[ "$CONTAINER_CMD" == "podman" ]]; then
    # Inside podman unshare, UID 0 maps to the real host user (the rootless namespace
    # puts the caller at UID 0). Using HOST_UID:HOST_GID here would map to the subuid
    # range instead, making files inaccessible.
    podman unshare chown -R 0:0 "$1" 2>/dev/null || true
  fi
}

# ---- Usage ------------------------------------------------------------------
usage() {
  echo 'NAME
       bitbox02_build.sh - verify BitBox02 hardware wallet firmware

SYNOPSIS
       bitbox02_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]

DESCRIPTION
       --version   Firmware version (e.g., "9.25.0"). Required.
       --type      Firmware type: btc|multi (default: btc)
       --binary    Path to official firmware binary. If omitted, downloaded automatically.
       --arch      Accepted for compatibility; ignored (build is always linux/amd64).
       --apk       Accepted for compatibility; ignored (not applicable to firmware).

EXAMPLES
       bitbox02_build.sh --version 9.25.0
       bitbox02_build.sh --version 9.25.0 --type multi
       bitbox02_build.sh --version 9.25.0 --type btc --binary /path/to/firmware.bin'
}

# ---- Argument parsing (unknown args warn and continue; never fatal) ----------
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}";      shift 2 || shift ;;
    --type)    firmwareType="${2:-}"; shift 2 || shift ;;
    --binary)  binaryPath="${2:-}";   shift 2 || shift ;;
    --arch)    ARCH="${2:-}";         shift 2 || shift ;;
    --apk)                            shift 2 || shift ;;
    --help)    usage; exit "$EXIT_OK" ;;
    *)         echo "Warning: unknown argument '$1' (ignored)"; shift ;;
  esac
done

# ---- Validate inputs --------------------------------------------------------
if [[ -z "$version" ]]; then
  echo -e "${RED}Error: --version is required.${NC}"
  usage
  write_results "ftbfs" "BitBox02: --version is required."
  exit "$EXIT_INVALID"
fi

if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*([._-][A-Za-z0-9]+)?$ ]]; then
  echo -e "${RED}Error: --version '${version}' contains unsafe characters.${NC}"
  write_results "ftbfs" "BitBox02: --version '${version}' contains unsafe characters."
  exit "$EXIT_INVALID"
fi

if [[ "$firmwareType" != "btc" && "$firmwareType" != "multi" ]]; then
  echo -e "${RED}Error: --type '${firmwareType}' is invalid. Must be: btc or multi.${NC}"
  write_results "ftbfs" "BitBox02: --type '${firmwareType}' is invalid. Must be: btc or multi."
  exit "$EXIT_INVALID"
fi

if [[ -n "$binaryPath" && ! -f "$binaryPath" ]]; then
  echo -e "${RED}Error: binary file not found: $binaryPath${NC}"
  write_results "ftbfs" "BitBox02: binary file not found: ${binaryPath}."
  exit "$EXIT_INVALID"
fi

if [[ -n "$binaryPath" ]] && ! [[ "$binaryPath" =~ ^/ ]]; then
  binaryPath="$PWD/$binaryPath"
fi

# ---- Type-specific variables ------------------------------------------------
GIT_TAG="firmware/v${version}"
RUN_ID="${version}_${firmwareType}_$$"
workDir="$(pwd)/bitbox02-work_${RUN_ID}"
IMAGE_TAG="bitbox02-firmware_${RUN_ID}"

if [[ "$firmwareType" == "btc" ]]; then
  MAKE_COMMAND="make firmware-btc"
  BUILT_FIRMWARE_PATH="build/bin/firmware-btc.bin"
  SIGNED_FILENAME="firmware-bitbox02-btconly.v${version}.signed.bin"
else
  MAKE_COMMAND="make firmware"
  BUILT_FIRMWARE_PATH="build/bin/firmware.bin"
  SIGNED_FILENAME="firmware-bitbox02-multi.v${version}.signed.bin"
fi

DOWNLOAD_URL="${repo}/releases/download/firmware%2Fv${version}/${SIGNED_FILENAME}"

echo
echo "Verifying BitBox02 firmware v${version} (${firmwareType})"
echo

# ---- Prepare workspace ------------------------------------------------------
echo "Setting up verification environment..."
rm -rf "$workDir"
mkdir -p "$workDir"

# ---- Clone inside container (no host git required) --------------------------
echo "Cloning BitBox02 firmware repository at tag: $GIT_TAG"
MAX_RETRIES=3
retry_count=0
while [[ $retry_count -lt $MAX_RETRIES ]]; do
  if $CONTAINER_CMD run --rm \
    --volume "$workDir:/work" \
    alpine \
    sh -c "
      set -e
      rm -rf /work/src
      apk add --no-cache git >/dev/null 2>&1
      git clone --branch '${GIT_TAG}' --recurse-submodules '${repo}' /work/src
      cd /work/src
      git fetch --tags
      git rev-parse HEAD > /work/commit.txt
      ${INNER_CHOWN} /work
    "; then
    break
  fi
  retry_count=$(( retry_count + 1 ))
  if [[ $retry_count -eq $MAX_RETRIES ]]; then
    echo -e "${RED}Failed to clone repository after $MAX_RETRIES attempts.${NC}"
    write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): failed to clone repository at tag ${GIT_TAG}."
    exit "$EXIT_FAIL"
  fi
  echo "Clone failed, retrying in 5 seconds..."
  sleep 5
done
repair_ownership "$workDir"

commit=$(cat "$workDir/commit.txt")
echo "Commit: $commit"
echo

# ---- Patch Dockerfile inside container (no host sed required) ---------------
# Back up the original so we can restore it after docker build without needing git.
cp "$workDir/src/Dockerfile" "$workDir/Dockerfile.orig"

$CONTAINER_CMD run --rm \
  --volume "$workDir/src:/src" \
  alpine \
  sh -c "
    set -e
    if [ '${GIT_TAG}' = 'firmware/v9.15.0' ]; then
      sed -i 's|cargo install bindgen-cli --version 0.65.1\$|cargo install bindgen-cli --version 0.65.1 --locked|' /src/Dockerfile
    fi
    sed -i 's|go1.19.3.linux-\${TARGETARCH}|go1.19.3.linux-amd64|g' /src/Dockerfile
    ${INNER_CHOWN} /src/Dockerfile
  "
repair_ownership "$workDir/src/Dockerfile"

# ---- Build Docker image -----------------------------------------------------
echo "Building Docker image (this may take 10-20 minutes)..."
if ! $CONTAINER_CMD build \
  --pull \
  --platform linux/amd64 \
  --force-rm \
  --no-cache \
  --tag "$IMAGE_TAG" \
  "$workDir/src"; then
  echo -e "${RED}Docker build failed!${NC}"
  write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): Docker image build failed."
  exit "$EXIT_FAIL"
fi

cp "$workDir/Dockerfile.orig" "$workDir/src/Dockerfile"

# ---- Get official firmware --------------------------------------------------
if [[ -n "$binaryPath" ]]; then
  echo "Using provided binary: $binaryPath"
  cp "$binaryPath" "$workDir/src/$SIGNED_FILENAME"
else
  echo "Downloading official signed firmware..."
  echo "URL: $DOWNLOAD_URL"
  retry_count=0
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    if $CONTAINER_CMD run --rm \
      --volume "$workDir/src:/out" \
      alpine \
      sh -c "
        set -e
        apk add --no-cache wget >/dev/null 2>&1
        wget -O '/out/${SIGNED_FILENAME}' '${DOWNLOAD_URL}'
        ${INNER_CHOWN} '/out/${SIGNED_FILENAME}'
      "; then
      break
    fi
    retry_count=$(( retry_count + 1 ))
    if [[ $retry_count -eq $MAX_RETRIES ]]; then
      echo -e "${RED}Failed to download firmware after $MAX_RETRIES attempts.${NC}"
      $CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true
      write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): failed to download official firmware."
      exit "$EXIT_FAIL"
    fi
    echo "Download failed, retrying in 5 seconds..."
    sleep 5
  done
  repair_ownership "$workDir/src/$SIGNED_FILENAME"
fi

if [[ ! -s "$workDir/src/$SIGNED_FILENAME" ]]; then
  echo -e "${RED}Firmware file missing or empty.${NC}"
  $CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true
  write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): firmware file missing or empty."
  exit "$EXIT_FAIL"
fi

# ---- Build firmware + compare (all inside build container) ------------------
echo "Building firmware ($MAKE_COMMAND) and running comparison..."
if ! $CONTAINER_CMD run --rm \
  --platform linux/amd64 \
  --volume "$workDir/src:/bb02" \
  "$IMAGE_TAG" \
  bash -c "
    set -e
    git config --global --add safe.directory /bb02
    cd /bb02
    ${MAKE_COMMAND}

    SIGNED='/bb02/${SIGNED_FILENAME}'
    BUILT='/bb02/${BUILT_FIRMWARE_PATH}'

    sha256sum \"\$SIGNED\" | awk '{print \$1}' > /bb02/hash_signed.txt
    sha256sum \"\$BUILT\"  | awk '{print \$1}' > /bb02/hash_built.txt

    # Strip first 588 bytes (header + vendor signatures)
    dd if=\"\$SIGNED\" bs=1 skip=588 of=/bb02/p_stripped.bin 2>/dev/null
    sha256sum /bb02/p_stripped.bin | awk '{print \$1}' > /bb02/hash_stripped.txt

    # Device firmware hash: double-sha256 over version (4B at offset 392) + firmware + 0xff padding to 884736B
    dd if=\"\$SIGNED\" bs=1 skip=\$(( 8 + 6 * 64 )) count=4 of=/bb02/p_version.bin 2>/dev/null
    FIRMWARE_BYTES=\$(wc -c < /bb02/p_stripped.bin)
    dd if=/dev/zero bs=1 count=\$(( 884736 - FIRMWARE_BYTES )) 2>/dev/null \
      | tr '\000' '\377' > /bb02/p_padding.bin
    cat /bb02/p_version.bin /bb02/p_stripped.bin /bb02/p_padding.bin \
      | sha256sum | cut -c1-64 | xxd -r -p | sha256sum | cut -c1-64 \
      > /bb02/hash_device.txt

    ${INNER_CHOWN} /bb02
  "; then
  echo -e "${RED}Build or comparison failed!${NC}"
  $CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true
  write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): firmware build or in-container comparison failed."
  exit "$EXIT_FAIL"
fi
repair_ownership "$workDir/src"

echo -e "${GREEN}Firmware build and comparison completed!${NC}"

# ---- Read hash results ------------------------------------------------------
signedHash=$(cat "$workDir/src/hash_signed.txt")
builtHash=$(cat "$workDir/src/hash_built.txt")
downloadStrippedSigHash=$(cat "$workDir/src/hash_stripped.txt")
downloadFirmwareHash=$(cat "$workDir/src/hash_device.txt")

echo ""
echo "============================================================"
echo "VERIFICATION RESULTS:"
echo "Signed download:             $signedHash"
echo "Signed download minus sig:   $downloadStrippedSigHash"
echo "Built binary:                $builtHash"
echo "Firmware hash (on device):   $downloadFirmwareHash"
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

echo ""
echo "===== Begin Results ====="
echo "firmware:     BitBox02"
echo "version:      $version"
echo "type:         $firmwareType"
echo "verdict:      $verdict"
echo "signedHash:   $signedHash"
echo "builtHash:    $builtHash"
echo "unsignedHash: $downloadStrippedSigHash"
echo "deviceHash:   $downloadFirmwareHash"
echo "repository:   $repo"
echo "tag:          $GIT_TAG"
echo "commit:       $commit"
echo "===== End Results ====="

# ---- Write COMPARISON_RESULTS.yaml ------------------------------------------
if [[ "$verdict" == "reproducible" ]]; then
  notes="BitBox02 v${version} (${firmwareType}) reproducible from source at ${GIT_TAG} (commit ${commit}). Comparison: first 588 bytes (header+signatures) stripped from official signed binary before SHA-256 comparison against unsigned build output. Expected difference: official binary has vendor signatures in first 588 bytes; built binary is unsigned."
else
  notes="BitBox02 v${version} (${firmwareType}) not reproducible. Built hash ${builtHash} does not match unsigned official payload hash ${downloadStrippedSigHash} after stripping first 588 bytes (header+signatures) from ${SIGNED_FILENAME}."
fi

write_results "$verdict" "$notes"

# ---- Cleanup ----------------------------------------------------------------
echo "Cleaning up container resources..."
$CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true

echo
echo "BitBox02 firmware verification finished!"
echo "Results: $RESULTS_FILE"

exit "$exit_code"
