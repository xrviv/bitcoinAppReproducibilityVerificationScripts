#!/bin/bash
# trezorsafe7_build.sh v2.2.3 - WalletScrutiny verification script for Trezor Safe 7 (T3W1)
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Date last modified: 2026-06-24
# Usage: trezorsafe7_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]
#
# Verifies Trezor Safe 7 (model T3W1) firmware reproducibility: builds from source via
# Trezor's upstream build-docker.sh at tag core/vVERSION, then compares the locally-built
# unsigned firmware against the official binary with its 65-byte firmware-header signature zeroed.

set -eE

# ---- Globals (RESULTS_FILE captured before any cd) --------------------------
SCRIPT_VERSION="v2.2.3"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
repo="https://github.com/trezor/trezor-firmware.git"
firmwareType="standard"
version=""
BINARY_PATH=""
ARCH=""

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# ---- Results writer (single-line notes; minimal 3-field YAML) ---------------
write_results() {
  local verdict="$1"
  local notes="$2"
  # Neutralize characters that would break a double-quoted single-line YAML scalar.
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

# Catch any unguarded command failure (cp/dd/sha256sum/mkdir/...) and still emit a YAML.
handle_err() {
  local rc=$?
  echo -e "${RED}Unexpected error (exit ${rc}).${NC}"
  write_results "ftbfs" "Trezor Safe 7 v${version:-?} (${firmwareType}): unexpected error (exit ${rc}) during verification."
  exit "$EXIT_FAIL"
}
trap handle_err ERR

# Refuse to run as root (WS rule: runs as a normal user; sudo is not allowed).
if [[ "$(id -u)" -eq 0 ]]; then
  echo -e "${RED}Error: do not run this script as root.${NC}"
  exit "$EXIT_FAIL"
fi

usage() {
  echo 'NAME
       trezorsafe7_build.sh - verify Trezor Safe 7 (T3W1) hardware wallet firmware

SYNOPSIS
       trezorsafe7_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]

DESCRIPTION
       --version   Firmware version to verify, e.g. "2.12.1" (required)
       --type      Firmware type. Accepted: standard|universal|multi  or
                   bitcoin-only|btc-only|btconly  (default: standard)
       --binary    Path to official firmware .bin (optional; downloaded if omitted)
       --arch      Accepted for ABS compatibility; unused for single-arch firmware

EXAMPLES
       trezorsafe7_build.sh --version 2.12.1 --type bitcoin-only
       trezorsafe7_build.sh --version 2.12.1 --type universal'
}

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

# ---- Container runtime detection (actually wired into build-docker.sh) ------
# build-docker.sh reads $DOCKER (default "docker"); export the detected runtime
# so a podman-only host genuinely uses podman instead of silently failing.
if command -v docker &>/dev/null && docker info &>/dev/null; then
  CONTAINER_CMD="docker"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
  echo -e "${RED}Error: docker is installed but its daemon is not responding, and podman is unavailable.${NC}"
  write_results "ftbfs" "Trezor Safe 7: docker daemon not responding and podman unavailable."
  exit "$EXIT_FAIL"
else
  echo -e "${RED}Error: neither docker nor podman found. Install one of them.${NC}"
  write_results "ftbfs" "Trezor Safe 7: no container runtime (docker/podman) available on host."
  exit "$EXIT_FAIL"
fi
export DOCKER="$CONTAINER_CMD"
echo "Container runtime: $CONTAINER_CMD"

# ---- Argument parsing (unknown args warn and continue; never fatal) ---------
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --binary)  BINARY_PATH="${2:-}";  shift 2 || shift ;;
    --version) version="${2:-}";      shift 2 || shift ;;
    --arch)    ARCH="${2:-}";         shift 2 || shift ;;
    --type)    firmwareType="${2:-}"; shift 2 || shift ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    *)         echo -e "${YELLOW}[WARN] Ignoring unknown argument: $1${NC}"; shift ;;
  esac
done

# ---- Validate version (strict: blocks shell metachars and path traversal) ---
if [[ -z "$version" ]]; then
  echo -e "${RED}Error: --version is required${NC}"; echo
  usage
  exit "$EXIT_INVALID"
fi
# Reject anything but digits and dots up front (blocks injection / path traversal).
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo -e "${RED}Error: invalid --version '$version' (expected numeric like 2.12.1)${NC}"
  exit "$EXIT_INVALID"
fi
# Upstream tags/downloads are 3-part. Accept X.Y.Z as-is; accept the 4-part Trezor metadata
# form X.Y.Z.0 and trim the trailing .0. Reject any other shape, so a non-zero 4th component
# (e.g. 2.12.1.7) is NOT silently built/compared as 2.12.1 while the report claims 2.12.1.7.
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  normalizedVersion="$version"
elif [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0$ ]]; then
  normalizedVersion="${BASH_REMATCH[1]}"
else
  echo -e "${RED}Error: unsupported --version '$version' (expected X.Y.Z or X.Y.Z.0)${NC}"
  exit "$EXIT_INVALID"
fi

# ---- Normalize --type (alias ABS keys btc-only/universal to internal names) -
case "${firmwareType,,}" in
  bitcoin-only|bitcoinonly|btc-only|btconly|btc) firmwareType="bitcoin-only" ;;
  standard|universal|multi|normal)               firmwareType="standard" ;;
  *)
    echo -e "${RED}Error: invalid --type '$firmwareType' (use standard|universal or bitcoin-only|btc-only)${NC}"
    exit "$EXIT_INVALID" ;;
esac

# ---- Make --binary absolute and validate it exists --------------------------
if [[ -n "$BINARY_PATH" ]]; then
  [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
  if [[ ! -f "$BINARY_PATH" ]]; then
    echo -e "${RED}Error: --binary file not found: $BINARY_PATH${NC}"
    exit "$EXIT_INVALID"
  fi
fi

# Work dir: version + type + PID so parallel/repeat runs never share a directory.
workDir="$(pwd)/trezor-safe7-work_${version}_${firmwareType}_$$"

echo
echo "Verifying Trezor Safe 7 (T3W1) firmware v$version ($firmwareType)"
echo

prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"

  echo "Cloning Trezor firmware repository..."
  if ! git clone "$repo" trezor-firmware; then
    echo -e "${RED}Failed to clone repository${NC}"
    write_results "ftbfs" "Trezor Safe 7 v${version}: failed to clone ${repo}."
    exit "$EXIT_FAIL"
  fi

  cd trezor-firmware
  echo "Checking out core/v${normalizedVersion}..."
  if ! git checkout "core/v${normalizedVersion}"; then
    echo -e "${RED}Failed to checkout core/v${normalizedVersion}${NC}"
    write_results "ftbfs" "Trezor Safe 7 v${version}: git tag core/v${normalizedVersion} not found."
    exit "$EXIT_FAIL"
  fi
  commit=$(git rev-parse "HEAD")
  echo -e "${GREEN}Repository prepared at commit: $commit${NC}"
}

download_official() {
  cd "$workDir"

  if [[ -n "$BINARY_PATH" ]]; then
    echo "Using provided official binary: $BINARY_PATH"
    cp "$BINARY_PATH" official.bin
  else
    echo "Downloading official firmware..."
    if [[ "$firmwareType" == "bitcoin-only" ]]; then
      url="https://data.trezor.io/firmware/t3w1/trezor-t3w1-${normalizedVersion}-bitcoinonly.bin"
    else
      url="https://data.trezor.io/firmware/t3w1/trezor-t3w1-${normalizedVersion}.bin"
    fi
    if ! wget -q -O official.bin "$url"; then
      echo -e "${RED}Failed to download official firmware: $url${NC}"
      write_results "ftbfs" "Trezor Safe 7 v${version} (${firmwareType}): failed to download official firmware from ${url}."
      exit "$EXIT_FAIL"
    fi
  fi

  officialHash=$(sha256sum official.bin | awk '{print $1}')
  echo -e "${GREEN}Official firmware hash: $officialHash${NC}"
}

build_firmware() {
  cd "$workDir/trezor-firmware"
  buildModel="T3W1"

  # Note: This builds hardware revision C by default (production version).
  # If we ever need to build revision A or B, we would need to pass HW_REVISION.

  # Type-scoped image/container name so ABS's concurrent standard + bitcoin-only
  # runs of the same version don't collide on the upstream version-only name.
  # Use the upstream skip flags so only the requested variant is built.
  if [[ "$firmwareType" == "bitcoin-only" ]]; then
    export CONTAINER_NAME="trezor-firmware-env-bitcoinonly-${normalizedVersion}.nix"
    skipFlag="--skip-normal"
    builtFirmware="build/core-T3W1-bitcoinonly/firmware/firmware.bin"
    echo "Building bitcoin-only firmware for $buildModel..."
  else
    export CONTAINER_NAME="trezor-firmware-env-standard-${normalizedVersion}.nix"
    skipFlag="--skip-bitcoinonly"
    builtFirmware="build/core-T3W1/firmware/firmware.bin"
    echo "Building standard firmware for $buildModel..."
  fi

  if ! ./build-docker.sh --models "$buildModel" "$skipFlag" "core/v${normalizedVersion}"; then
    echo -e "${RED}Build failed!${NC}"
    write_results "ftbfs" "Trezor Safe 7 v${version} (${firmwareType}): build-docker.sh build failed."
    exit "$EXIT_FAIL"
  fi

  if [[ ! -f "$builtFirmware" ]]; then
    echo -e "${RED}Built firmware not found: $builtFirmware${NC}"
    write_results "ftbfs" "Trezor Safe 7 v${version}: build completed but firmware not found at ${builtFirmware}."
    exit "$EXIT_FAIL"
  fi
  echo -e "${GREEN}Firmware built successfully${NC}"
}

compare_firmware() {
  cd "$workDir"
  builtHash=$(sha256sum "trezor-firmware/$builtFirmware" | awk '{print $1}')

  # Fail closed on header shape: the official image must start with vendor-header magic
  # "TRZV" (0x54525a56) and declare a 1024-byte vendor header (bytes 4-7, uint32 LE). The
  # 65-byte signature (sigmask 1B + signature 64B) sits 959 bytes into the firmware header
  # that follows -> offset 1024 + 959 = 1983 (documented for T3W1). Refuse to guess if the
  # header does not match, rather than zero the wrong bytes and report a false verdict.
  SIG_INNER=959
  local magicHex
  magicHex=$(head -c4 official.bin 2>/dev/null | od -An -tx1 | tr -d ' \n')
  vhLen=$(od -An -tu4 -j4 -N4 official.bin 2>/dev/null | tr -d '[:space:]')
  if [[ "$magicHex" != "54525a56" || "$vhLen" != "1024" ]]; then
    echo -e "${RED}Unexpected firmware header (magic=0x${magicHex}, vendor header=${vhLen}B).${NC}"
    write_results "ftbfs" "Trezor Safe 7 v${version} (${firmwareType}): unexpected firmware header (magic=0x${magicHex}, vendor header=${vhLen}B); expected TRZV / 1024B for T3W1 - refusing to guess signature offset."
    exit "$EXIT_FAIL"
  fi
  seekSize=$(( vhLen + SIG_INNER ))   # 1024 + 959 = 1983

  cp official.bin official.zeroed
  dd if=/dev/zero of=official.zeroed bs=1 seek="$seekSize" count=65 conv=notrunc 2>/dev/null
  officialZeroedHash=$(sha256sum official.zeroed | awk '{print $1}')

  echo
  echo "============================================================"
  echo "Vendor header:       ${vhLen} bytes  (signature zeroed at offset ${seekSize}, 65 bytes)"
  echo "Official (signed):   $officialHash"
  echo "Official (zeroed):   $officialZeroedHash"
  echo "Built (unsigned):    $builtHash"
  echo "============================================================"

  if [[ "$builtHash" == "$officialZeroedHash" ]]; then
    echo -e "${GREEN}REPRODUCIBLE: Firmware matches${NC}"
    verdict="reproducible"
  else
    echo -e "${RED}NOT REPRODUCIBLE: Firmware differs${NC}"
    verdict="not_reproducible"
  fi
}

# ---- Main -------------------------------------------------------------------
echo "Starting Trezor Safe 7 verification..."
echo "This may take 15-30 minutes."
echo

prepare
download_official
build_firmware
compare_firmware

echo
echo "===== Results ====="
echo "firmware:       Trezor Safe 7"
echo "model:          T3W1"
echo "version:        $version"
echo "type:           $firmwareType"
echo "verdict:        $verdict"
echo "official hash:  $officialHash"
echo "zeroed hash:    $officialZeroedHash"
echo "built hash:     $builtHash"
echo "commit:         $commit"
echo "==================="

if [[ "$verdict" == "reproducible" ]]; then
  write_results "reproducible" "Trezor Safe 7 v${version} (${firmwareType}) reproducible from source via build-docker.sh at core/v${normalizedVersion} (commit ${commit}); official firmware-header signature (offset ${seekSize}, 65B) zeroed before SHA-256 comparison."
  echo
  echo "Trezor Safe 7 verification finished!"
  exit "$EXIT_OK"
else
  write_results "not_reproducible" "Trezor Safe 7 v${version} (${firmwareType}) not reproducible: built ${builtHash} != zeroed official ${officialZeroedHash} (signature zeroed at offset ${seekSize}, 65B)."
  echo
  echo "Trezor Safe 7 verification finished!"
  exit "$EXIT_FAIL"
fi
