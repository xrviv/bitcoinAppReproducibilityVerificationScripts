#!/bin/bash
# BitBox02 Firmware Reproducible Build Helper
# Version 0.3.1
# Author: Daniel Andrei ("xrviv") R. Garcia
# Organization: WalletScrutiny.com
# Last Updated: 2025-10-10
# Automates download, build, and comparison for BitBox02 firmware editions (btc or multi).
# Use at your own risk; hardware flashing and firmware verification can brick devices if misused.
# Provided under the Apache 2.0 license without warranties or implied guarantees of fitness.
# Requirements: bash, git, wget, python3, docker (or docker-compatible runtime), xxd (vim-common), coreutils

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="0.3.1"
SCRIPT_DESCRIPTION="Automates download, container build, and hash comparison for BitBox02 firmware releases."

CYAN='\033[1;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

usage() {
  cat <<USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}
${SCRIPT_DESCRIPTION}

Usage:
  ${SCRIPT_NAME} <firmware_version> [edition]

Arguments:
  firmware_version   Release number without the leading 'v' (example: 9.23.2)
  edition            Firmware edition to verify: 'btc' (default) or 'multi'

Options:
  -h, --help         Display this help message and exit

Examples:
  ${SCRIPT_NAME} 9.23.2
  ${SCRIPT_NAME} 9.23.2 multi

Tips:
  • If you encounter repeated HTTP 404 errors while downloading the release asset,
    double-check the GitHub release page: recent versions renamed assets to
    'firmware-bitbox02-*.signed.bin'.
  • You can download the asset manually and rename it to match the expected
    pattern if GitHub changes naming again.
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
esac

version=${1:-}
edition=${2:-btc} # Default to 'btc' if the second argument is not provided

if [[ -z "$version" ]]; then
  echo -e "${RED}Error:${NC} Missing firmware version."
  usage
  exit 1
fi

if [[ "$edition" != "btc" && "$edition" != "multi" ]]; then
  echo -e "${RED}Error:${NC} Edition must be 'btc' or 'multi'."
  usage
  exit 1
fi

echo -e "${CYAN}Attempting to build BitBox02 firmware version ${version} (${edition} edition)...${NC}"
ARCHIVE=/tmp
WORKSPACE="$HOME/builds/hardware/bitbox2-build"

if [ -d "$WORKSPACE" ]; then
    echo -e "${RED}Error:${NC} Workspace $WORKSPACE already exists. Remove it manually before rerunning." >&2
    exit 1
fi

mkdir -p "$WORKSPACE"
cd "$WORKSPACE" || exit 1

MAX_RETRIES=3
retry_count=0
while [ $retry_count -lt $MAX_RETRIES ]; do
    echo "Attempting to clone repository (attempt $((retry_count + 1))/$MAX_RETRIES)..."
    if git clone --depth 1 https://github.com/BitBoxSwiss/bitbox02-firmware; then
        break
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -eq $MAX_RETRIES ]; then
        echo "Failed to clone repository after $MAX_RETRIES attempts"
        exit 1
    fi
    echo "Clone failed, retrying in 5 seconds..."
    sleep 5
done

cd bitbox02-firmware || exit 1

# Harden upstream build script so the Go toolchain download follows redirects.
python3 - <<'PY'
from pathlib import Path
build_sh = Path("releases/build.sh")
text = build_sh.read_text()
needle_plain = "curl https://dl.google.com/go/go1.19.3.linux-${TARGETARCH}.tar.gz | tar -xz -C /opt/go_dist"
needle_patched = "curl -fsSL https://dl.google.com/go/go1.19.3.linux-${TARGETARCH}.tar.gz | tar -xz -C /opt/go_dist"
if needle_plain in text and needle_patched not in text:
    patch = (
        "cd temp;\n\n"
        "# Ensure Go toolchain download follows redirects so the archive extracts correctly.\n"
        "sed -i 's|curl https://dl.google.com/go/go1.19.3.linux-${TARGETARCH}.tar.gz | tar -xz -C /opt/go_dist|"
        "curl -fsSL https://dl.google.com/go/go1.19.3.linux-${TARGETARCH}.tar.gz | tar -xz -C /opt/go_dist|' Dockerfile\n\n"
    )
    text = text.replace("cd temp;\n\n", patch, 1)
    build_sh.write_text(text)
PY

if [ "$edition" = "multi" ]; then
    EDITION_TAG_URL="firmware"
    EDITION_FILENAME="firmware"
    DOWNLOAD_ASSET_BASENAME="firmware-bitbox02-multi"
    GIT_CHECKOUT_TAG="firmware/v${version}"
    MAKE_COMMAND="make firmware"
else
    EDITION_TAG_URL="firmware-btc-only"
    EDITION_FILENAME="firmware-btc"
    DOWNLOAD_ASSET_BASENAME="firmware-bitbox02-btconly"
    GIT_CHECKOUT_TAG="firmware-btc-only/v${version}"
    MAKE_COMMAND="make firmware-btc"
fi

SIGNED_BINARY_FILENAME="${DOWNLOAD_ASSET_BASENAME}.v${version}.signed.bin"
DOWNLOAD_URL="https://github.com/BitBoxSwiss/bitbox02-firmware/releases/download/${EDITION_TAG_URL}%2Fv${version}/${SIGNED_BINARY_FILENAME}"

MAX_RETRIES=3
retry_count=0
while [ $retry_count -lt $MAX_RETRIES ]; do
    if wget -O "$SIGNED_BINARY_FILENAME" "$DOWNLOAD_URL"; then
        break
    fi
    status=$?
    if [[ $status -eq 8 ]]; then
        echo -e "${YELLOW}Warning:${NC} Received HTTP 404 from ${DOWNLOAD_URL}." >&2
        echo -e "${YELLOW}Tip:${NC} Visit the GitHub release page and confirm the asset name." >&2
        echo -e "${YELLOW}      Expected pattern: ${SIGNED_BINARY_FILENAME}${NC}" >&2
    fi
    retry_count=$((retry_count + 1))
    if [ $retry_count -eq $MAX_RETRIES ]; then
        echo "Failed to download firmware after $MAX_RETRIES attempts" >&2
        echo "You may need to manually download the asset and place it at: $WORKSPACE/bitbox02-firmware/${SIGNED_BINARY_FILENAME}" >&2
        exit 1
    fi
    echo "Download failed, retrying in 5 seconds..."
    sleep 5
done

if [[ ! -s "$SIGNED_BINARY_FILENAME" ]]; then
    echo -e "${RED}Error:${NC} Downloaded asset '$SIGNED_BINARY_FILENAME' is missing or empty." >&2
    echo -e "Verify the release asset name on GitHub and place the file at: $WORKSPACE/bitbox02-firmware/${SIGNED_BINARY_FILENAME}" >&2
    exit 1
fi

cp "$SIGNED_BINARY_FILENAME" "$ARCHIVE/bitbox02-firmware-${DOWNLOAD_ASSET_BASENAME}.v${version}.signed.bin"

signedHash=$(sha256sum "$SIGNED_BINARY_FILENAME")

if [ ! -f "releases/build.sh" ]; then
    echo "Error: build.sh not found. Repository structure may have changed." >&2
    exit 1
fi

./releases/build.sh "${GIT_CHECKOUT_TAG}" "${MAKE_COMMAND}"
builtHash=$(sha256sum "temp/build/bin/${EDITION_FILENAME}.bin")

head -c 588 "$SIGNED_BINARY_FILENAME" > p_head.bin
tail -c +589 "$SIGNED_BINARY_FILENAME" > "p_${EDITION_FILENAME}.bin"

if [[ ! -s "p_${EDITION_FILENAME}.bin" ]]; then
    echo -e "${RED}Error:${NC} Failed to extract unsigned payload from '$SIGNED_BINARY_FILENAME'." >&2
    echo -e "Ensure the firmware asset corresponds to the requested edition ('${edition}') and try again." >&2
    exit 1
fi

downloadStrippedSigHash=$(sha256sum "p_${EDITION_FILENAME}.bin")
cat p_head.bin | tail -c +$(( 8 + 6 * 64 + 1 )) | head -c 4 > p_version.bin
firmwareBytesCount=$(wc -c "p_${EDITION_FILENAME}.bin" | sed 's/ .*//g')
maxFirmwareSize=884736
paddingBytesCount=$(( maxFirmwareSize - firmwareBytesCount ))
dd if=/dev/zero ibs=1 count=$paddingBytesCount 2>/dev/null | tr "\000" "\377" > p_padding.bin
downloadFirmwareHash=$( cat p_version.bin "p_${EDITION_FILENAME}.bin" p_padding.bin | sha256sum | cut -c1-64 | xxd -r -p | sha256sum | cut -c1-64 )

echo "Hashes of"
echo "signed download             $signedHash"
echo "signed download minus sig.  $downloadStrippedSigHash"
echo "built binary                $builtHash"
echo "firmware as shown in device $downloadFirmwareHash"
echo "                           (The latter is a double sha256 over version,"
echo "                            firmware and padding)"
