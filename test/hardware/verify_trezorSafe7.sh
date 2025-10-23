#!/bin/bash
# Trezor Safe 7 (T3W1) Firmware Reproducible Build Verification
# Version: 0.2.0
# Author: Daniel Andrei ("xrviv") R. Garcia
# Organization: WalletScrutiny.com
# Last Updated: 2025-10-22
#
# Automates download, Docker-based build, and comparison for Trezor Safe 7 firmware.
# Use at your own risk; firmware verification can brick devices if misused.
# Provided under the Apache 2.0 license without warranties or implied guarantees of fitness.
#
# Requirements: bash, wget, docker (or podman), sha256sum

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="0.2.0"

# Colors for human-readable output (not used in results section)
CYAN='\033[1;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
  cat <<USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}
Trezor Safe 7 (T3W1) Firmware Reproducible Build Verification

Usage:
  ${SCRIPT_NAME} -v <version> [-t <type>]

Arguments:
  -v <version>       Firmware version without 'v' prefix (e.g., 2.9.3)
  -t <type>          Optional: 'normal' (default) or 'bitcoinonly'

Options:
  -h, --help         Display this help message

Examples:
  ${SCRIPT_NAME} -v 2.9.3
  ${SCRIPT_NAME} -v 2.9.3 -t bitcoinonly

Note:
  - Requires Docker and ~5GB disk space in /tmp
  - Build takes 15-30 minutes depending on system
  - Uses Trezor's official build-docker.sh script
  - Model identifier: T3W1 (includes nRF Bluetooth firmware)
  - Workspace: /tmp/test_trezorSafe7_v<version>

USAGE
}

# Parse arguments
VERSION=""
TYPE="normal"

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    -v)
      VERSION="$2"
      shift 2
      ;;
    -t)
      TYPE="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Error: Unknown option $1${NC}" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo -e "${RED}Error: Missing firmware version${NC}" >&2
  usage
  exit 1
fi

if [[ "$TYPE" != "normal" && "$TYPE" != "bitcoinonly" ]]; then
  echo -e "${RED}Error: Type must be 'normal' or 'bitcoinonly'${NC}" >&2
  exit 1
fi

# Preflight checks
echo -e "${CYAN}=== Preflight Check ===${NC}"
missing_deps=()
for cmd in wget docker sha256sum; do
  if ! command -v "$cmd" &> /dev/null; then
    missing_deps+=("$cmd")
  fi
done

if [[ ${#missing_deps[@]} -gt 0 ]]; then
  echo -e "${RED}Missing dependencies: ${missing_deps[*]}${NC}" >&2
  echo "Install with: sudo apt-get install -y ${missing_deps[*]}" >&2
  exit 1
fi

if ! docker info &> /dev/null; then
  echo -e "${RED}Docker daemon not accessible${NC}" >&2
  echo "Ensure Docker is running and you have permissions" >&2
  exit 1
fi

echo -e "${GREEN}All prerequisites satisfied${NC}"
echo ""

# Setup workspace in /tmp
WORKSPACE="/tmp/test_trezorSafe7_v${VERSION}"
if [ -d "$WORKSPACE" ]; then
  echo -e "${RED}Error: Workspace $WORKSPACE already exists${NC}" >&2
  echo "Remove it manually: rm -rf $WORKSPACE" >&2
  exit 1
fi

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo -e "${CYAN}=== Trezor Safe 7 (T3W1) Firmware Verification ===${NC}"
echo -e "Version: ${VERSION}"
echo -e "Type: ${TYPE}"
echo -e "Workspace: ${WORKSPACE}"
echo ""

# Determine firmware filename and URL
if [[ "$TYPE" == "bitcoinonly" ]]; then
  FIRMWARE_FILE="trezor-t3w1-${VERSION}-bitcoinonly.bin"
  BUILD_VARIANT="bitcoinonly"
  BUILD_SKIP_FLAG="--skip-normal"
else
  FIRMWARE_FILE="trezor-t3w1-${VERSION}.bin"
  BUILD_VARIANT="normal"
  BUILD_SKIP_FLAG="--skip-bitcoinonly"
fi

FIRMWARE_URL="https://raw.githubusercontent.com/trezor/data/master/firmware/t3w1/${FIRMWARE_FILE}"

# Download official firmware
echo -e "${CYAN}Step 1: Downloading official firmware...${NC}"
if ! wget -q --show-progress "${FIRMWARE_URL}"; then
  echo -e "${RED}Error: Failed to download firmware${NC}" >&2
  echo "URL: ${FIRMWARE_URL}" >&2
  exit 1
fi

# Check if we got a Git LFS pointer instead of actual file
if [[ -f "$FIRMWARE_FILE" ]]; then
  FILE_SIZE=$(wc -c < "$FIRMWARE_FILE")
  if [[ $FILE_SIZE -lt 1000 ]] && grep -q "git-lfs.github.com" "$FIRMWARE_FILE"; then
    echo -e "${YELLOW}Detected Git LFS pointer file, extracting actual firmware...${NC}"
    
    # Extract the actual download URL from LFS pointer
    LFS_OID=$(grep "^oid sha256:" "$FIRMWARE_FILE" | cut -d: -f3)
    LFS_SIZE=$(grep "^size " "$FIRMWARE_FILE" | awk '{print $2}')
    
    if [[ -z "$LFS_OID" ]]; then
      echo -e "${RED}Error: Could not parse Git LFS pointer${NC}" >&2
      exit 1
    fi
    
    # Download actual file from GitHub LFS
    LFS_URL="https://media.githubusercontent.com/media/trezor/data/master/firmware/t3w1/${FIRMWARE_FILE}"
    echo "Downloading actual firmware from Git LFS..."
    rm "$FIRMWARE_FILE"
    if ! wget -q --show-progress "${LFS_URL}" -O "${FIRMWARE_FILE}"; then
      echo -e "${RED}Error: Failed to download firmware from Git LFS${NC}" >&2
      exit 1
    fi
    
    # Verify size matches
    ACTUAL_SIZE=$(wc -c < "$FIRMWARE_FILE")
    if [[ "$ACTUAL_SIZE" != "$LFS_SIZE" ]]; then
      echo -e "${RED}Error: Downloaded size ($ACTUAL_SIZE) doesn't match expected ($LFS_SIZE)${NC}" >&2
      exit 1
    fi
  fi
fi

if [[ ! -s "$FIRMWARE_FILE" ]]; then
  echo -e "${RED}Error: Downloaded firmware is empty${NC}" >&2
  exit 1
fi

OFFICIAL_HASH=$(sha256sum "${FIRMWARE_FILE}" | cut -d' ' -f1)
echo -e "${GREEN}Official firmware hash: ${OFFICIAL_HASH}${NC}"
echo ""

# Clone repository using Docker (containerized git)
echo -e "${CYAN}Step 2: Cloning trezor-firmware repository...${NC}"
GIT_TAG="core/v${VERSION}"

# Get current user UID:GID for proper file ownership
USER_ID=$(id -u)
GROUP_ID=$(id -g)

if ! docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -u "${USER_ID}:${GROUP_ID}" \
  alpine/git:latest \
  clone --depth 1 --branch "${GIT_TAG}" https://github.com/trezor/trezor-firmware; then
  echo -e "${RED}Error: Failed to clone repository or tag not found${NC}" >&2
  echo "Tag: ${GIT_TAG}" >&2
  exit 1
fi

cd trezor-firmware

# Get commit hash using containerized git
COMMIT_HASH=$(docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -u "${USER_ID}:${GROUP_ID}" \
  alpine/git:latest \
  rev-parse HEAD)
echo -e "${GREEN}Commit: ${COMMIT_HASH}${NC}"
echo ""

# Build firmware using Docker
echo -e "${CYAN}Step 3: Building firmware (this takes 15-30 minutes)...${NC}"
echo -e "${YELLOW}Building with Docker container...${NC}"

# Run build-docker.sh with T3W1 model and nRF support
if ! ./build-docker.sh --models T3W1 --nrf ${BUILD_SKIP_FLAG} "${GIT_TAG}"; then
  echo -e "${RED}Error: Build failed${NC}" >&2
  echo "Check build logs above for details" >&2
  exit 2
fi

echo ""

# Locate built firmware
echo -e "${CYAN}Step 4: Locating built firmware...${NC}"

# T3W1 uses different build directory structure
if [[ "$TYPE" == "bitcoinonly" ]]; then
  BUILT_FIRMWARE="build/core-T3W1-bitcoinonly/firmware/firmware.bin"
else
  BUILT_FIRMWARE="build/core-T3W1/firmware/firmware.bin"
fi

if [[ ! -f "$BUILT_FIRMWARE" ]]; then
  echo -e "${RED}Error: Built firmware not found at ${BUILT_FIRMWARE}${NC}" >&2
  echo "Checking for firmware files:"
  find build -name "firmware.bin" -o -name "firmware-*.bin" || true
  exit 2
fi

BUILT_HASH=$(sha256sum "$BUILT_FIRMWARE" | cut -d' ' -f1)
echo -e "${GREEN}Built firmware hash: ${BUILT_HASH}${NC}"
echo ""

# Compare firmware binaries using containerized Python analysis
echo -e "${CYAN}Step 5: Extracting and comparing firmware payloads...${NC}"
echo -e "${YELLOW}Using trezorlib to extract code sections (ignoring signatures)...${NC}"

# Create comparison script that runs in container
cat > compare_firmware.py << 'PYEOF'
import sys
import hashlib
from pathlib import Path

try:
    from trezorlib.firmware import parse
except ImportError:
    print("WARNING: trezorlib not available, falling back to binary comparison")
    sys.exit(2)

def extract_payload(firmware_path):
    """Extract code payload from firmware, ignoring signatures and metadata"""
    try:
        with open(firmware_path, 'rb') as f:
            data = f.read()
        
        # Parse firmware structure
        fw = parse(data)
        
        # Extract code section (this is what actually runs on device)
        if hasattr(fw, 'code'):
            return fw.code
        elif hasattr(fw, 'firmware'):
            return fw.firmware.code if hasattr(fw.firmware, 'code') else fw.firmware
        else:
            # Fallback: return everything after header (first 1KB typically)
            return data[1024:]
    except Exception as e:
        print(f"Error parsing {firmware_path}: {e}")
        return None

def main():
    if len(sys.argv) != 3:
        print("Usage: compare_firmware.py <official.bin> <built.bin>")
        sys.exit(1)
    
    official_path = sys.argv[1]
    built_path = sys.argv[2]
    
    print(f"Analyzing official firmware: {official_path}")
    official_payload = extract_payload(official_path)
    
    print(f"Analyzing built firmware: {built_path}")
    built_payload = extract_payload(built_path)
    
    if official_payload is None or built_payload is None:
        print("ERROR: Failed to extract payloads")
        sys.exit(2)
    
    # Calculate hashes
    official_hash = hashlib.sha256(official_payload).hexdigest()
    built_hash = hashlib.sha256(built_payload).hexdigest()
    
    print(f"\nPayload Analysis:")
    print(f"Official payload size: {len(official_payload)} bytes")
    print(f"Built payload size: {len(built_payload)} bytes")
    print(f"Official payload hash: {official_hash}")
    print(f"Built payload hash: {built_hash}")
    
    # Save extracted payloads for manual inspection
    Path('official_payload.bin').write_bytes(official_payload)
    Path('built_payload.bin').write_bytes(built_payload)
    print(f"\nExtracted payloads saved:")
    print(f"  official_payload.bin")
    print(f"  built_payload.bin")
    
    # Compare
    if official_hash == built_hash:
        print("\n✓ PAYLOADS MATCH - Firmware is reproducible!")
        sys.exit(0)
    else:
        print("\n✗ PAYLOADS DIFFER - Firmware is NOT reproducible")
        # Show first difference
        for i, (a, b) in enumerate(zip(official_payload, built_payload)):
            if a != b:
                print(f"First difference at byte {i}: {a:02x} vs {b:02x}")
                break
        sys.exit(1)

if __name__ == '__main__':
    main()
PYEOF

# Run comparison in Docker container with trezorlib
echo "Running containerized payload comparison..."
DIFF_OUTPUT=""
COMPARISON_EXIT=0

# Try to run in container with trezorlib
if docker run --rm \
  -v "$PWD/..:/workspace" \
  -w /workspace/trezor-firmware \
  python:3.11-slim \
  bash -c "pip install -q trezor[hidapi] && python compare_firmware.py ../${FIRMWARE_FILE} ${BUILT_FIRMWARE}"; then
  echo -e "${GREEN}Payload comparison completed successfully${NC}"
  COMPARISON_EXIT=0
else
  COMPARISON_EXIT=$?
  if [[ $COMPARISON_EXIT -eq 2 ]]; then
    echo -e "${YELLOW}trezorlib comparison unavailable, falling back to binary comparison${NC}"
    # Fallback to simple binary comparison
    if cmp -s "../${FIRMWARE_FILE}" "$BUILT_FIRMWARE"; then
      echo -e "${GREEN}Full binaries are identical!${NC}"
      COMPARISON_EXIT=0
    else
      DIFF_OUTPUT="Full binaries differ (may include signature differences)"
      echo -e "${YELLOW}${DIFF_OUTPUT}${NC}"
      OFFICIAL_SIZE=$(wc -c < "../${FIRMWARE_FILE}")
      BUILT_SIZE=$(wc -c < "$BUILT_FIRMWARE")
      echo "Official size: ${OFFICIAL_SIZE} bytes"
      echo "Built size: ${BUILT_SIZE} bytes"
      COMPARISON_EXIT=1
    fi
  else
    DIFF_OUTPUT="Payloads differ"
    echo -e "${RED}${DIFF_OUTPUT}${NC}"
  fi
fi

echo ""

# Determine verdict based on comparison result
if [[ $COMPARISON_EXIT -eq 0 ]]; then
  VERDICT="reproducible"
  EXIT_CODE=0
else
  VERDICT="differences found"
  EXIT_CODE=1
fi

# Get tag signature info using containerized git
TAG_SIG_OUTPUT=$(docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -u "${USER_ID}:${GROUP_ID}" \
  alpine/git:latest \
  verify-tag "${GIT_TAG}" 2>&1 || echo "No signature found")
COMMIT_SIG_OUTPUT=$(docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -u "${USER_ID}:${GROUP_ID}" \
  alpine/git:latest \
  verify-commit HEAD 2>&1 || echo "No signature found")

# Output results in standardized format
echo "===== Begin Results ====="
echo "appId:          trezor-safe7-${BUILD_VARIANT}"
echo "signer:         N/A"
echo "apkVersionName: ${VERSION}"
echo "apkVersionCode: ${VERSION//.}"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${OFFICIAL_HASH}"
echo "commit:         ${COMMIT_HASH}"
echo ""
echo "Diff:"
if [[ -n "$DIFF_OUTPUT" ]]; then
  echo "Binary comparison: ${DIFF_OUTPUT}"
  echo "Official hash: ${OFFICIAL_HASH}"
  echo "Built hash:    ${BUILT_HASH}"
else
  echo "(no differences)"
fi
echo ""
echo "Revision, tag (and its signature):"
echo "${TAG_SIG_OUTPUT}"
echo ""
if echo "${TAG_SIG_OUTPUT}" | grep -q "Good signature"; then
  echo "Signature Summary:"
  echo "Tag type: annotated"
  echo "[OK] Good signature on annotated tag"
else
  echo "Signature Summary:"
  echo "Tag type: annotated"
  echo "[WARNING] No valid signature found on tag"
fi
echo ""
echo "===== End Results ====="
echo ""
echo "Firmware files:"
echo "  Official: ${WORKSPACE}/${FIRMWARE_FILE}"
echo "  Built:    ${WORKSPACE}/trezor-firmware/${BUILT_FIRMWARE}"
echo ""
echo "For detailed analysis:"
echo "  xxd ${WORKSPACE}/${FIRMWARE_FILE} > official.hex"
echo "  xxd ${WORKSPACE}/trezor-firmware/${BUILT_FIRMWARE} > built.hex"
echo "  diff official.hex built.hex"
echo ""

exit $EXIT_CODE
