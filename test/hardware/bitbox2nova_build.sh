#!/bin/bash
# bitbox2nova_build.sh v2.1.0 - Standardized verification script for BitBox02 Nova Hardware Wallet
# Organization: WalletScrutiny.com
# Follows WalletScrutiny reproducible verification standards
# Usage: bitbox2nova_build.sh --version VERSION [--type TYPE] [--binary FILE]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"
sleep 2
echo

# Global Variables
SCRIPT_VERSION="v2.1.0"
BUILD_TYPE="firmware"
EXEC_DIR="$(pwd)"
RESULTS_FILE="${EXEC_DIR}/COMPARISON_RESULTS.yaml"
EXIT_INVALID=2   # invalid/missing parameters (ABS convention)

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither docker nor podman found. Please install Docker or Podman."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# BitBox02 Nova constants
firmwareType="btc"  # Default to BTC-only (normalized below)
arch=""             # Accepted for ABS compliance; firmware has a single device arch
providedBinary=""   # Optional official artifact supplied via --binary
verdict=""
notes=""
exit_code=1

usage() {
  echo 'NAME
       bitbox2nova_build.sh - verify BitBox02 Nova hardware wallet firmware

SYNOPSIS
       bitbox2nova_build.sh --version VERSION [--type TYPE] [--binary FILE]

DESCRIPTION
       This command verifies firmware builds of BitBox02 Nova hardware wallet.
       Follows the WalletScrutiny standardized verification script format.

       --version   Firmware version (e.g., "9.23.3")
       --type      Firmware edition: btc (a.k.a. btc-only/bitcoin) or multi.
                   Default: btc.
       --arch      Accepted for build-server compatibility. BitBox02 firmware
                   has a single device architecture, so this does not select a
                   variant; it is recorded only.
       --binary    Path to the official signed firmware artifact to compare
                   against. When omitted, the script downloads it from GitHub.

EXAMPLES
       bitbox2nova_build.sh --version 9.23.3
       bitbox2nova_build.sh --version 9.23.3 --type multi
       bitbox2nova_build.sh --version 9.23.3 --binary /path/to/firmware.signed.bin'
}

# Parse arguments
# NOTE: unknown arguments must never be fatal (WS ABS requirement, 2026-03-11).
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) firmwareType="$2"; shift ;;
    --arch) arch="$2"; shift ;;
    --binary|--apk) providedBinary="$2"; shift ;;
    --help) usage; exit 0 ;;
    *) echo -e "${YELLOW}WARN: Ignoring unknown argument: $1${NC}" >&2 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$version" ]; then
  echo "Error: Version is required!"
  echo
  usage
  exit $EXIT_INVALID
fi

# Normalize firmware type. The wallet .md `builds:` types may be expressed as
# btc-only/bitcoin (BTC-only edition) or multi (multi-coin edition). Per the WS
# rule that unknown/extra parameter values must never be fatal, an unrecognized
# value warns and falls back to the btc default instead of exiting.
case "${firmwareType,,}" in
  btc|btc-only|btconly|bitcoin) firmwareType="btc" ;;
  multi|multicoin) firmwareType="multi" ;;
  *)
    echo -e "${YELLOW}WARN: Unrecognized --type '${firmwareType}', defaulting to btc${NC}" >&2
    firmwareType="btc"
    ;;
esac

# Parallel-safety (script_verifications.md rule 7): the build server launches
# arch/type combinations concurrently, so per-combination resource names must be
# unique to avoid clobbering each other's work dir and container image.
workDir="${EXEC_DIR}/bitbox02-nova-work-${firmwareType}"
IMAGE_TAG="bitbox02-nova-firmware-${firmwareType}"

echo
echo "Verifying BitBox02 Nova firmware version $version ($firmwareType)${arch:+, arch=$arch}"
echo

# Return 0 if the given upstream tag exists on the remote.
tag_exists() {
  local t="$1"
  local url="https://github.com/BitBoxSwiss/bitbox02-firmware"
  [[ -n "${GITHUB_TOKEN:-}" ]] && url="https://x-access-token:${GITHUB_TOKEN}@github.com/BitBoxSwiss/bitbox02-firmware"
  git ls-remote --tags "$url" "refs/tags/${t}" 2>/dev/null | grep -q "refs/tags/${t}$"
}

prepare() {
  echo "Setting up verification environment..."

  # Detect system architecture
  ARCH=$(uname -m)
  echo "System Architecture: $ARCH"

  # Per-edition build settings (independent of the upstream tag scheme).
  if [[ "$firmwareType" == "btc" ]]; then
    MAKE_COMMAND="make firmware-btc"
    FIRMWARE_PREFIX="firmware-btc"
    BUILT_FIRMWARE_PATH="build/bin/firmware-btc.bin"
    SIGNED_FILENAME="firmware-bitbox02nova-btconly.v${version}.signed.bin"
    LEGACY_TAG="firmware-btc-only/v${version}"
  else
    MAKE_COMMAND="make firmware"
    FIRMWARE_PREFIX="firmware"
    BUILT_FIRMWARE_PATH="build/bin/firmware.bin"
    SIGNED_FILENAME="firmware-bitbox02nova-multi.v${version}.signed.bin"
    LEGACY_TAG=""
  fi

  # Resolve the upstream tag. Through v9.25.0 the BTC-only edition had its own
  # `firmware-btc-only/vX` tag; from v9.25.1 the repo unified everything under
  # `firmware/vX` (editions differ only by make target, and all signed assets
  # live on the one release). Probe the legacy tag first, then fall back.
  VERSION="firmware/v${version}"
  if [[ -n "$LEGACY_TAG" ]] && tag_exists "$LEGACY_TAG"; then
    VERSION="$LEGACY_TAG"
  fi
  echo "Resolved upstream tag: $VERSION"

  # Release asset path mirrors the resolved tag (slashes URL-encoded).
  RELEASE_TAG_PATH="${VERSION//\//%2F}"
  DOWNLOAD_URL="https://github.com/BitBoxSwiss/bitbox02-firmware/releases/download/${RELEASE_TAG_PATH}/${SIGNED_FILENAME}"

  # cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"

  echo "Using version tag: $VERSION"
  echo "Make command: $MAKE_COMMAND"
  echo "Download URL: $DOWNLOAD_URL"
  echo -e "${GREEN}Environment prepared${NC}"
}

build_firmware() {
  echo "Cloning BitBox02 firmware repository..."

  cd "$workDir"

  # Use the build server's GITHUB_TOKEN when available (rule 8) to avoid
  # unauthenticated rate limits; fall back to anonymous clone otherwise.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CLONE_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/BitBoxSwiss/bitbox02-firmware"
  else
    CLONE_URL="https://github.com/BitBoxSwiss/bitbox02-firmware"
  fi

  MAX_RETRIES=3
  retry_count=0
  while [ $retry_count -lt $MAX_RETRIES ]; do
    if git clone --depth 1 --branch "$VERSION" --recurse-submodules "$CLONE_URL" temp; then
      break
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -eq $MAX_RETRIES ]; then
      echo -e "${RED}Failed to clone repository after $MAX_RETRIES attempts${NC}"
      write_results "ftbfs" "repository clone failed"
      exit 1
    fi
    echo "Clone failed, retrying in 5 seconds..."
    sleep 5
  done

  cd temp

  # Fetch tags
  git fetch --tags

  # Apply version-specific patches if needed
  if [[ "$VERSION" == "firmware-btc-only/v9.15.0" || "$VERSION" == "firmware/v9.15.0" ]]; then
    echo "Applying patch for v9.15.0..."
    sed -i 's/RUN CARGO_HOME=\/opt\/cargo cargo install bindgen-cli --version 0.65.1/RUN CARGO_HOME=\/opt\/cargo cargo install bindgen-cli --version 0.65.1 --locked/' Dockerfile
  fi

  # Check if Nova-specific build targets exist
  echo "Configuring for BitBox02 Nova build..."
  if grep -q "firmware-nova" Makefile 2>/dev/null; then
    if [[ "$firmwareType" == "btc" ]]; then
      MAKE_COMMAND="make firmware-nova-btc"
    else
      MAKE_COMMAND="make firmware-nova"
    fi
    echo "Using Nova-specific make command: $MAKE_COMMAND"
  else
    echo "Using standard firmware build (Nova features included in main build)"
  fi

  # Modify Dockerfile for explicit architecture
  echo "Configuring Dockerfile for architecture: $ARCH"
  case "$ARCH" in
    x86_64)
      sed -i 's|go1.19.3.linux-${TARGETARCH}|go1.19.3.linux-amd64|g' Dockerfile
      ;;
    aarch64|arm64)
      sed -i 's|go1.19.3.linux-${TARGETARCH}|go1.19.3.linux-arm64|g' Dockerfile
      ;;
    *)
      echo -e "${RED}Unsupported architecture: $ARCH${NC}"
      write_results "ftbfs" "unsupported build architecture: $ARCH"
      exit 1
      ;;
  esac

  echo "Building Docker image for BitBox02 Nova firmware..."
  if ! $CONTAINER_CMD build --pull --platform linux/amd64 --force-rm --no-cache -t "$IMAGE_TAG" .; then
    echo -e "${RED}Docker build failed!${NC}"
    write_results "ftbfs" "docker image build failed"
    exit 1
  fi

  # Revert local Dockerfile patch
  git checkout -- Dockerfile

  echo "Running firmware build command: $MAKE_COMMAND"
  if ! $CONTAINER_CMD run -it --rm --volume "$(pwd)":/bb02 "$IMAGE_TAG" bash -c "git config --global --add safe.directory /bb02 && cd /bb02 && $MAKE_COMMAND"; then
    echo -e "${RED}Firmware build failed!${NC}"
    write_results "ftbfs" "firmware build command failed"
    exit 1
  fi

  echo -e "${GREEN}Firmware build completed successfully!${NC}"
}

download_and_compare() {
  cd "$workDir/temp"

  if [[ -n "$providedBinary" ]]; then
    # Use the official artifact supplied via --binary instead of downloading.
    if [[ ! -s "$providedBinary" ]]; then
      echo -e "${RED}Error: --binary file '$providedBinary' is missing or empty${NC}" >&2
      write_results "ftbfs" "provided --binary artifact missing or empty"
      exit 1
    fi
    echo "Using official firmware supplied via --binary: $providedBinary"
    cp "$providedBinary" "$SIGNED_FILENAME"
  else
    echo "Downloading official signed Nova firmware..."
    echo "URL: $DOWNLOAD_URL"

    # Pass the build server's GITHUB_TOKEN (rule 8) when present.
    WGET_AUTH=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      WGET_AUTH=(--header="Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    MAX_RETRIES=3
    retry_count=0
    while [ $retry_count -lt $MAX_RETRIES ]; do
      if wget "${WGET_AUTH[@]}" -O "$SIGNED_FILENAME" "$DOWNLOAD_URL"; then
        break
      fi
      status=$?
      if [[ $status -eq 8 ]]; then
        echo -e "${YELLOW}Warning: Received HTTP 404 from ${DOWNLOAD_URL}${NC}" >&2

        # Try alternative Nova naming patterns
        ALT_SIGNED_FILENAME="firmware-nova-${firmwareType}.v${version}.signed.bin"
        ALT_DOWNLOAD_URL="https://github.com/BitBoxSwiss/bitbox02-firmware/releases/download/${RELEASE_TAG_PATH}/${ALT_SIGNED_FILENAME}"
        echo -e "${YELLOW}Trying alternative URL: ${ALT_DOWNLOAD_URL}${NC}" >&2

        if wget "${WGET_AUTH[@]}" -O "$ALT_SIGNED_FILENAME" "$ALT_DOWNLOAD_URL"; then
          SIGNED_FILENAME="$ALT_SIGNED_FILENAME"
          break
        fi
      fi
      retry_count=$((retry_count + 1))
      if [ $retry_count -eq $MAX_RETRIES ]; then
        echo -e "${RED}Failed to download firmware after $MAX_RETRIES attempts${NC}" >&2
        write_results "ftbfs" "official firmware download failed"
        exit 1
      fi
      echo "Download failed, retrying in 5 seconds..."
      sleep 5
    done
  fi

  if [[ ! -s "$SIGNED_FILENAME" ]]; then
    echo -e "${RED}Error: Official asset '$SIGNED_FILENAME' is missing or empty${NC}" >&2
    write_results "ftbfs" "official firmware artifact missing or empty"
    exit 1
  fi

  echo "Calculating hashes..."

  # Calculate hash of signed download
  signedHash=$(sha256sum "$SIGNED_FILENAME" | awk '{print $1}')
  echo "Hash of signed download: $signedHash"

  # Calculate hash of built binary
  builtHash=$(sha256sum "$BUILT_FIRMWARE_PATH" | awk '{print $1}')
  echo "Hash of built binary: $builtHash"

  # Unpack signed binary (remove signature)
  echo "Unpacking signed binary..."
  head -c 588 "$SIGNED_FILENAME" > p_head.bin
  tail -c +589 "$SIGNED_FILENAME" > p_${FIRMWARE_PREFIX}.bin

  if [[ ! -s "p_${FIRMWARE_PREFIX}.bin" ]]; then
    echo -e "${YELLOW}Warning: Standard signature extraction failed, trying Nova-specific format...${NC}" >&2

    # Try alternative signature format
    head -c 600 "$SIGNED_FILENAME" > p_head_alt.bin
    tail -c +601 "$SIGNED_FILENAME" > p_${FIRMWARE_PREFIX}_alt.bin

    if [[ -s "p_${FIRMWARE_PREFIX}_alt.bin" ]]; then
      mv p_head_alt.bin p_head.bin
      mv p_${FIRMWARE_PREFIX}_alt.bin p_${FIRMWARE_PREFIX}.bin
    else
      echo -e "${RED}Error: Failed to extract unsigned payload from '$SIGNED_FILENAME'${NC}" >&2
      write_results "ftbfs" "failed to extract unsigned payload from official artifact"
      exit 1
    fi
  fi

  downloadStrippedSigHash=$(sha256sum p_${FIRMWARE_PREFIX}.bin | awk '{print $1}')

  # Extract version and calculate device firmware hash
  cat p_head.bin | tail -c +$(( 8 + 6 * 64 + 1 )) | head -c 4 > p_version.bin
  firmwareBytesCount=$(wc -c p_${FIRMWARE_PREFIX}.bin | sed 's/ .*//g')
  maxFirmwareSize=884736
  paddingBytesCount=$(( maxFirmwareSize - firmwareBytesCount ))

  if [ $paddingBytesCount -lt 0 ]; then
    echo -e "${YELLOW}Warning: Firmware size exceeds standard limit, adjusting for Nova...${NC}"
    maxFirmwareSize=$((firmwareBytesCount + 1024))
    paddingBytesCount=1024
  fi

  dd if=/dev/zero ibs=1 count=$paddingBytesCount 2>/dev/null | tr "\000" "\377" > p_padding.bin
  downloadFirmwareHash=$( cat p_version.bin p_${FIRMWARE_PREFIX}.bin p_padding.bin | sha256sum | cut -c1-64 | xxd -r -p | sha256sum | cut -c1-64 )

  echo ""
  echo "============================================================"
  echo "VERIFICATION RESULTS:"
  echo "Signed download:             $signedHash"
  echo "Signed download minus sig:   $downloadStrippedSigHash"
  echo "Built binary:                $builtHash"
  echo "Firmware as shown in device: $downloadFirmwareHash"
  echo "                            (double sha256 over version,"
  echo "                             firmware and padding)"
  echo ""

  # Determine verdict
  if [[ "$downloadStrippedSigHash" == "$builtHash" ]]; then
    verdict="reproducible"
    notes="built firmware matches unsigned content of official artifact"
    echo -e "${GREEN}REPRODUCIBLE: Built firmware matches unsigned content${NC}"
    echo "============================================================"
    exit_code=0
  else
    verdict="not_reproducible"
    notes="built binary hash ${builtHash} != unsigned official hash ${downloadStrippedSigHash}"
    echo -e "${RED}NOT REPRODUCIBLE: Firmware hashes differ${NC}"
    echo "============================================================"
    exit_code=1
  fi

  write_results "$verdict" "$notes"
}

write_results() {
  local status=$1
  local note=$2

  # Minimal YAML output (WS ABS requirement, 2026-03-12):
  # only script_version, verdict, and optional notes.
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${status}"
    if [[ -n "$note" ]]; then
      echo "notes: ${note}"
    fi
  } > "$RESULTS_FILE"

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

result() {
  echo ""
  echo "===== Begin Results ====="
  echo "firmware:       BitBox02 Nova"
  echo "version:        $version"
  echo "type:           $firmwareType"
  echo "verdict:        $verdict"
  echo "signedHash:     ${signedHash:-N/A}"
  echo "builtHash:      ${builtHash:-N/A}"
  echo "unsignedHash:   ${downloadStrippedSigHash:-N/A}"
  echo "deviceHash:     ${downloadFirmwareHash:-N/A}"
  echo "repository:     https://github.com/BitBoxSwiss/bitbox02-firmware"
  echo "tag:            $VERSION"
  echo ""
  if [[ "$verdict" == "reproducible" ]]; then
    echo "The firmware builds reproducibly from source code."
  else
    echo "The firmware does not build reproducibly."
  fi
  echo "===== End Results ====="
  echo ""
  echo "Verification files available at: $workDir/temp"
  echo "  - Built firmware: $BUILT_FIRMWARE_PATH"
  echo "  - Official firmware: $SIGNED_FILENAME"
  echo "Results file: $RESULTS_FILE"
}

cleanup() {
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting BitBox02 Nova firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building firmware..."

build_firmware
echo "Build completed. Downloading and comparing..."

download_and_compare
echo "Comparison completed."

result
echo "Verification completed."

cleanup

echo
echo "BitBox02 Nova firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit $exit_code
