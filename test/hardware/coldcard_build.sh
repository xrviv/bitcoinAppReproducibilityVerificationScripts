#!/bin/bash
# coldcard_build.sh v3.4.0 - WalletScrutiny verification script for Coldcard Hardware Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: coldcard_build.sh --version VERSION --type MODEL [--binary FIRMWARE_FILE]

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
SCRIPT_VERSION="v3.4.0"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
repo="https://github.com/Coldcard/firmware.git"

# Color constants
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Detect container runtime
if command -v docker &>/dev/null; then
  CONTAINER_CMD="docker"
  echo "Using Docker for containerization"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
  echo "Using Podman for containerization"
else
  echo "Error: Neither docker nor podman found. Please install Docker or Podman."
  exit 1
fi

# Input variables
version=""
model=""
binaryPath=""

usage() {
  echo 'NAME
       coldcard_build.sh - verify Coldcard hardware wallet firmware

SYNOPSIS
       coldcard_build.sh --version VERSION --type MODEL
       coldcard_build.sh --version VERSION --type MODEL --binary FIRMWARE_FILE

DESCRIPTION
       This command verifies firmware builds of Coldcard hardware wallets.
       Signed firmware is expected to differ (only Coinkite holds the signing key).
       Reproducibility is assessed by stripping signatures and comparing the rest.

       --version   Firmware version (e.g., "5.4.4" for Mk4, "1.4.0Q" for Q1)
       --type      Hardware model: mk4 or q1
       --arch      Accepted but ignored (single arch per model)
       --binary    Optional path to official firmware .dfu file (downloaded if not provided)

EXAMPLES
       coldcard_build.sh --version 5.4.4 --type mk4
       coldcard_build.sh --version 1.4.0Q --type q1
       coldcard_build.sh --version 5.4.4 --type mk4 --binary /path/to/firmware.dfu'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2";     shift ;;
    --type)    model="$2";       shift ;;
    --binary)  binaryPath="$2";  shift ;;
    --apk)     binaryPath="$2";  shift ;;  # legacy alias
    --arch)                      shift ;;  # accepted, ignored
    --help)    usage;            exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$version" ]; then
  echo "Error: --version is required"
  echo
  usage
  exit 1
fi

if [ -z "$model" ]; then
  echo "Error: --type is required (mk4 or q1)"
  echo
  usage
  exit 1
fi

if [[ "$model" != "mk4" && "$model" != "q1" ]]; then
  echo "Error: Invalid model '$model'. Must be: mk4 or q1"
  exit 1
fi

# Validate and absolutify binary path if provided
if [ -n "$binaryPath" ]; then
  if [ ! -f "$binaryPath" ]; then
    echo "Error: Binary file not found: $binaryPath"
    exit 1
  fi
  if ! [[ "$binaryPath" =~ ^/.* ]]; then
    binaryPath="$PWD/$binaryPath"
  fi
fi

# Q1 versions carry a Q suffix in the tag; add it if missing
if [[ "$model" == "q1" && ! "$version" =~ Q ]]; then
  version="${version}Q"
fi

# Namespace workDir and image name by version+model to allow parallel runs
# Image names must be lowercase; sanitize version (e.g. 1.4.0Q -> 1.4.0q)
workDir="$(pwd)/coldcard-work-${version}-${model}"
IMAGE_NAME="coldcard-build-$(echo "${version}-${model}" | tr '[:upper:]' '[:lower:]')"

echo
echo "Verifying Coldcard $model firmware version $version"
echo

# ââ Results ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

write_results() {
  local status=$1

  local arch="arm-cortex-m4"
  [[ "$model" == "q1" ]] && arch="arm-cortex-m7"

  # dfu_filename is set during download_official(); fall back gracefully if
  # write_results is called before that point (e.g. early ftbfs in prepare)
  local filename="${dfu_filename:-${version}-${model}-coldcard.dfu}"

  cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  Coldcard ${model} v${version} firmware verification.
  Built using the upstream dockerfile.build inside a containerized environment.
  Comparison method: signatures are masked out of both the official and built binaries
  using hexdump + sed before SHA-256 comparison, mirroring the upstream repro-build.sh
  check-repro step. Only Coinkite holds the signing key so signed binaries will always differ.
  Expected differences (do not affect reproducibility verdict):
  - Official binary is signed by Coinkite; built binary carries a different or absent signature
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

# ââ Prepare âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"

  echo "Cloning Coldcard firmware repository..."
  if ! git clone --quiet "$repo" "$workDir/firmware"; then
    echo -e "${RED}Failed to clone repository${NC}"
    write_results "ftbfs"
    exit 1
  fi

  cd "$workDir/firmware"

  # Tags look like: 2026-03-05T2051-v1.4.0Q  (date prefix + version)
  TAG=$(git tag | grep -E ".*-v${version}$" | sort | tail -1)

  if [ -z "$TAG" ]; then
    echo -e "${RED}Error: Could not find a tag matching version $version${NC}"
    echo "Available tags containing '$version':"
    git tag | grep "$version" | head -10
    write_results "notag"
    exit 1
  fi

  echo "Found tag: $TAG"

  if ! git checkout "$TAG"; then
    echo -e "${RED}Failed to checkout tag $TAG${NC}"
    write_results "ftbfs"
    exit 1
  fi

  commit=$(git rev-parse HEAD)
  echo -e "${GREEN}Repository prepared at commit: $commit${NC}"

  # Coldcard renamed the Mk4 model identifier from "mk4" to "mk" in v5.5.0,
  # and renamed MK4-Makefile to MK-Makefile at the same time.
  # Derive the correct hw_model and mkfile from what actually exists in the repo.
  if [[ "$model" == "mk4" ]]; then
    if [ -f "stm32/MK4-Makefile" ]; then
      mkfile="MK4-Makefile"
      hw_model="mk4"
    else
      mkfile="MK-Makefile"
      hw_model="mk"
    fi
  else
    mkfile="Q1-Makefile"
    hw_model="q1"
  fi

  echo "Using Makefile: $mkfile (hw_model: $hw_model)"

  # Short version for the build system (strip leading v and date prefix)
  short_version=$(echo "$TAG" | grep -oP 'v\K[^-]*$')
  echo "Short version: $short_version"
}

# ââ Download ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

download_official() {
  echo "Locating official firmware..."

  cd "$workDir/firmware/releases"

  # Coldcard's filename convention has changed over time (e.g. mk4 â mk in v5.5.0).
  # Look up the exact filename from signatures.txt using the tag date+version prefix.
  local tag_prefix
  tag_prefix=$(echo "$TAG" | grep -oP '^\d{4}-\d{2}-\d{2}T\d+')
  dfu_filename=$(grep "${tag_prefix}.*-v${short_version}-${hw_model}-coldcard\.dfu" signatures.txt \
    | grep -v "factory" | head -1 | awk '{print $2}')

  if [ -z "$dfu_filename" ]; then
    echo -e "${RED}Error: Could not find firmware filename in signatures.txt for version $short_version${NC}"
    echo "Available entries:"
    grep "$short_version" signatures.txt | head -5
    write_results "ftbfs"
    exit 1
  fi

  echo "Firmware filename: $dfu_filename"

  if [ -n "$binaryPath" ]; then
    echo "Using provided firmware file: $binaryPath"
    cp "$binaryPath" "$dfu_filename"
  else
    local url="https://coldcard.com/downloads/${dfu_filename}"
    echo "Downloading: $url"
    if ! wget -q -O "$dfu_filename" "$url"; then
      echo -e "${RED}Failed to download official firmware${NC}"
      write_results "ftbfs"
      exit 1
    fi
  fi

  officialHashSigned=$(sha256sum "$dfu_filename" | awk '{print $1}')
  echo -e "${GREEN}Official firmware ready: $officialHashSigned${NC}"

  cd "$workDir/firmware"
}

# ââ Build âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

build_firmware() {
  echo "Building Coldcard firmware..."

  cd "$workDir/firmware/stm32"

  echo "Building Docker image ${IMAGE_NAME} from repository dockerfile.build..."
  if ! $CONTAINER_CMD build -t "$IMAGE_NAME" - < dockerfile.build; then
    echo -e "${RED}Docker image build failed!${NC}"
    write_results "ftbfs"
    exit 1
  fi

  cd "$workDir/firmware"

  echo "Running firmware build in container..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume "$(realpath .):/work/src:ro" \
    --volume "$(realpath stm32/built):/work/built:rw" \
    --privileged \
    "$IMAGE_NAME" \
    sh -c "sh src/stm32/repro-build.sh ${short_version} ${hw_model} ${mkfile}"; then
    echo -e "${RED}Firmware build failed!${NC}"
    write_results "ftbfs"
    exit 1
  fi

  echo -e "${GREEN}Firmware built successfully${NC}"
}

# ââ Compare âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

compare_firmware() {
  echo "Comparing firmware binaries..."

  cd "$workDir/firmware"

  # repro-build.sh already runs `make check-repro` inside the container, which
  # uses `signit split` to extract check-fw.bin from the downloaded .dfu and
  # then diffs it against firmware-signed.bin with signatures masked out.
  # We repeat the same masking here to produce comparable hashes for the results.
  local TRIM_SIG="sed -e 's/^00003f[89abcdef]0 .*/(firmware signature here)/'"

  hexdump -C stm32/built/firmware-signed.bin | eval "$TRIM_SIG" > repro-got.txt
  hexdump -C stm32/built/check-fw.bin        | eval "$TRIM_SIG" > repro-want.txt

  officialHashUnsigned=$(sha256sum repro-want.txt | awk '{print $1}')
  builtHashUnsigned=$(sha256sum repro-got.txt     | awk '{print $1}')
  builtHashSigned=$(sha256sum stm32/built/firmware-signed.dfu | awk '{print $1}')

  echo ""
  echo "============================================================"
  echo "VERIFICATION RESULTS:"
  echo "Official (signed):   $officialHashSigned"
  echo "Built (signed):      $builtHashSigned"
  echo "Official (unsigned): $officialHashUnsigned"
  echo "Built (unsigned):    $builtHashUnsigned"
  echo "============================================================"

  if [[ "$builtHashUnsigned" == "$officialHashUnsigned" ]]; then
    verdict="reproducible"
    echo -e "${GREEN}â REPRODUCIBLE: Firmware matches${NC}"
    write_results "reproducible"
    exit_code=0
  else
    verdict="not_reproducible"
    echo -e "${RED}â NOT REPRODUCIBLE: Unsigned firmware differs${NC}"
    write_results "not_reproducible"
    exit_code=1
  fi

  echo ""
  echo "===== Begin Results ====="
  echo "firmware:             Coldcard $model"
  echo "version:              $version"
  echo "type:                 $model"
  echo "verdict:              $verdict"
  echo "officialHashSigned:   $officialHashSigned"
  echo "builtHashSigned:      $builtHashSigned"
  echo "officialHashUnsigned: $officialHashUnsigned"
  echo "builtHashUnsigned:    $builtHashUnsigned"
  echo "repository:           $repo"
  echo "tag:                  $TAG"
  echo "commit:               $commit"
  echo ""
  if [[ "$verdict" == "reproducible" ]]; then
    echo "â The firmware builds reproducibly from source code."
  else
    echo "â The firmware does not build reproducibly."
  fi
  echo "===== End Results ====="
  echo ""
  echo "Verification files:"
  echo "  Official firmware:    $workDir/firmware/releases/$dfu_filename"
  echo "  Built (signed):       $workDir/firmware/stm32/built/firmware-signed.dfu"
  echo "  Built (unsigned hex): $workDir/firmware/repro-got.txt"
  echo "  Official (unsigned hex): $workDir/firmware/repro-want.txt"
  echo ""
  echo "Results file: $RESULTS_FILE"
}

# ââ Cleanup âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

cleanup() {
  echo "Cleaning up container resources..."
  $CONTAINER_CMD rmi "$IMAGE_NAME" -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# ââ Main execution âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ

echo "Starting Coldcard firmware verification..."
echo "This may take 10-20 minutes."
echo

prepare
echo "Environment prepared. Downloading official firmware..."

download_official
echo "Download completed. Building firmware from source..."

build_firmware
echo "Build completed. Comparing firmware..."

compare_firmware
echo "Comparison completed."

cleanup

echo
echo "Coldcard firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit ${exit_code:-1}