#!/bin/bash
# bitbox02_build.sh v3.11.0 - WalletScrutiny verification script for BitBox02
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Date last modified: 2026-07-15 (v3.11.0)
# Usage: bitbox02_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]
#
# Verifies BitBox02 firmware reproducibility: builds from source via the upstream
# Dockerfile at the release tag, then compares the locally-built unsigned firmware
# against the official signed binary with its first 588 bytes (header + signatures) stripped.
# Host requirements: docker or podman only.

set -eE

# ---- Globals ----------------------------------------------------------------
SCRIPT_VERSION="v3.11.0"
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
  # Product id per src/bootloader/bootloader_product.h (magic 0x11233b0b).
  EXPECTED_PRODUCT_ID=2
else
  MAKE_COMMAND="make firmware"
  BUILT_FIRMWARE_PATH="build/bin/firmware.bin"
  SIGNED_FILENAME="firmware-bitbox02-multi.v${version}.signed.bin"
  # Product id per src/bootloader/bootloader_product.h (magic 0x653f362b).
  EXPECTED_PRODUCT_ID=1
fi

DOWNLOAD_URL="${repo}/releases/download/firmware%2Fv${version}/${SIGNED_FILENAME}"

echo
echo "Verifying BitBox02 firmware v${version} (${firmwareType})"
echo

# ---- Prepare workspace ------------------------------------------------------
# Three isolated subdirectories keep the cloned repo completely clean:
#   src/      — cloned source (never written to after clone; git must stay clean)
#   official/ — official signed firmware binary (separate from src so git sees nothing)
#   out/      — comparison outputs (hash files, diag, stripped binary)
echo "Setting up verification environment..."
rm -rf "$workDir"
mkdir -p "$workDir/official" "$workDir/out"

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
  cp "$binaryPath" "$workDir/official/$SIGNED_FILENAME"
else
  echo "Downloading official signed firmware..."
  echo "URL: $DOWNLOAD_URL"
  retry_count=0
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    if $CONTAINER_CMD run --rm \
      --volume "$workDir/official:/out" \
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
  repair_ownership "$workDir/official"
fi

if [[ ! -s "$workDir/official/$SIGNED_FILENAME" ]]; then
  echo -e "${RED}Firmware file missing or empty.${NC}"
  $CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true
  write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): firmware file missing or empty."
  exit "$EXIT_FAIL"
fi

# ---- Build firmware + compare (all inside build container) ------------------
# Three volumes keep responsibilities isolated:
#   /bb02     = source repo (read/write for build artifacts, must stay git-clean)
#   /official = official signed binary (read-only input)
#   /out      = all comparison outputs (hash files, diagnostics, stripped binary)
echo "Building firmware ($MAKE_COMMAND) and running comparison..."
if ! $CONTAINER_CMD run --rm \
  --platform linux/amd64 \
  --volume "$workDir/src:/bb02" \
  --volume "$workDir/official:/official" \
  --volume "$workDir/out:/out" \
  "$IMAGE_TAG" \
  bash -c "
    set -eo pipefail
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

    ${MAKE_COMMAND}

    SIGNED='/official/${SIGNED_FILENAME}'
    BUILT='/bb02/${BUILT_FIRMWARE_PATH}'

    sha256sum \"\$SIGNED\" | awk '{print \$1}' > /out/hash_signed.txt
    sha256sum \"\$BUILT\"  | awk '{print \$1}' > /out/hash_built.txt

    # Upstream signed firmware layout (describe_signed_firmware.py):
    #   4 bytes magic + 584 bytes sigdata + unsigned firmware
    # Total header = 588 bytes for both btconly and multi.
    HEADER_BYTES=588
    dd if=\"\$SIGNED\" bs=1 skip=\"\${HEADER_BYTES}\" of=/out/p_stripped.bin 2>/dev/null
    sha256sum /out/p_stripped.bin | awk '{print \$1}' > /out/hash_stripped.txt

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
    # The 4-byte magic identifies the edition; it must match the edition this run targets,
    # otherwise a wrong-edition --binary would be compared against the wrong build.
    #
    # The hash the device shows at boot is bootloader-dependent. Bootloader v1.2.2 (shipped by
    # firmware 9.26.2, the mandatory intermediate upgrade) computes
    # sha256(product_id_le16 + version + padded_firmware) -- see src/bootloader/bootloader.c
    # _firmware_hash()/_maybe_show_hash(). Firmware monotonic version >= 50 implies that
    # bootloader is present, which is why upstream branches on 50.
    # Older bootloaders use the legacy sha256d(version + padded_firmware).
    python3 -c \"
import hashlib, struct, sys
MAGIC_LEN = 4; SIGDATA_LEN = 584; VERSION_OFF = 392; MAX_FIRMWARE_SIZE = 884736
NEW_SIGHASH_VERSION_CUTOFF = 50
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
    sys.exit(1)
product_id, label = EDITIONS[magic]
if product_id != expected_pid:
    print('ABORT: edition mismatch -- binary is ' + label + ' (magic 0x' + magic +
          '), but this run targets product id ' + str(expected_pid), file=sys.stderr)
    sys.exit(1)
version = data[VERSION_OFF:VERSION_OFF + 4]
firmware = data[MAGIC_LEN + SIGDATA_LEN:]
padded = firmware + b'\\xff' * (MAX_FIRMWARE_SIZE - len(firmware))
monotonic = struct.unpack('<I', version)[0]
if monotonic >= NEW_SIGHASH_VERSION_CUTOFF:
    device_hash = hashlib.sha256(struct.pack('<H', product_id) + version + padded).hexdigest()
    scheme = 'sha256(product_id_le16 + version + padded), bootloader >= v1.2.2'
else:
    device_hash = hashlib.sha256(hashlib.sha256(version + padded).digest()).hexdigest()
    scheme = 'legacy sha256d(version + padded)'
open('/out/hash_device.txt', 'w').write(device_hash + '\\n')
open('/out/edition.txt', 'w').write(label + '\\n')
open('/out/monotonic.txt', 'w').write(str(monotonic) + '\\n')
open('/out/device_hash_scheme.txt', 'w').write(scheme + '\\n')
print('edition: ' + label + ' (magic 0x' + magic + ', product id ' + str(product_id) + ')')
print('monotonic version: ' + str(monotonic))
print('device hash scheme: ' + scheme)
\" \"\$SIGNED\" '${EXPECTED_PRODUCT_ID}'

    ${INNER_CHOWN} /out
  "; then
  echo -e "${RED}Build or comparison failed!${NC}"
  $CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true
  write_results "ftbfs" "BitBox02 v${version} (${firmwareType}): firmware build or in-container comparison failed."
  exit "$EXIT_FAIL"
fi
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
echo "edition:      $edition"
echo "monotonic:    $monotonicVersion"
echo "repository:   $repo"
echo "tag:          $GIT_TAG"
echo "commit:       $commit"
echo "===== End Results ====="

# ---- Write COMPARISON_RESULTS.yaml ------------------------------------------
if [[ "$verdict" == "reproducible" ]]; then
  notes="BitBox02 v${version} (${firmwareType}) reproducible from source at ${GIT_TAG} (commit ${commit}). Comparison: first 588 bytes (4 magic + 584 sigdata) stripped from official signed binary; SHA-256 of remainder matches unsigned build output."
else
  notes="BitBox02 v${version} (${firmwareType}) not reproducible. Built hash ${builtHash} does not match unsigned official payload hash ${downloadStrippedSigHash} after stripping 588 bytes (4 magic + 584 sigdata) from ${SIGNED_FILENAME}."
fi

write_results "$verdict" "$notes"

# ---- Cleanup ----------------------------------------------------------------
echo "Cleaning up container resources..."
$CONTAINER_CMD rmi "$IMAGE_TAG" --force 2>/dev/null || true

echo
echo "BitBox02 firmware verification finished!"
echo "Results: $RESULTS_FILE"

exit "$exit_code"
