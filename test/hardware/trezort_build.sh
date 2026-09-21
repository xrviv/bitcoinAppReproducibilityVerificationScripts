#!/bin/bash
# ==============================================================================
# trezort_build.sh - Trezor Model T (T2T1) Firmware Reproducible Build Verification
# ==============================================================================
# Version:           v0.1.1
# Organization:      WalletScrutiny.com
# Last modified by:  dannybuntu
# Last modified on:  2026-09-21
# Project:           https://github.com/trezor/trezor-firmware
# Usage:             trezort_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]
# ==============================================================================
# LICENSE: MIT License
#
# Changelog is kept outside this file (WalletScrutiny script notes, hardware/trezorT).
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script runs containerized builds and binary comparisons - review all operations before
# execution. It never connects to, flashes or otherwise touches a hardware device.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Clones trezor-firmware and checks out tag core/vVERSION
# - Downloads the official signed firmware from data.trezor.io (or uses --binary)
# - Builds the firmware with Trezor's own build-docker.sh (--targets firmware, one edition)
# - Zeroes the official file's 65-byte firmware-header signature at offset 4608 + 959 = 5567
#   (Model T vendor header is 4608 bytes; docs/common/reproducible-build.md), refusing to
#   guess if the TRZV / 4608-byte / TRZF header shape does not match
# - Compares SHA-256 of the zeroed official file and the unsigned local build
# - Prints labelled hashes (appHash = official as downloaded) and writes COMPARISON_RESULTS.yaml
# ==============================================================================

set -eE

# ---- Globals (RESULTS_FILE captured before any cd) --------------------------
SCRIPT_VERSION="v0.1.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
repo="https://github.com/trezor/trezor-firmware.git"
firmwareType="standard"
version=""
BINARY_PATH=""
ARCH=""

MODEL="T2T1"
MODEL_LC="t2t1"
PRODUCT="Trezor Model T"
EXPECTED_VH_LEN=4608   # Model T vendor header size (upstream reproducible-build.md)
SIG_INNER=959          # signature offset inside the 1024-byte firmware header (0x3bf)

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

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
  write_results "ftbfs" "${PRODUCT} v${version:-?} (${firmwareType}): unexpected error (exit ${rc}) during verification."
  exit "$EXIT_FAIL"
}
trap handle_err ERR

# ---- Ownership normalization (WS non-root-ownership rule) --------------------
# build-docker.sh runs its build as root inside the container and only chowns /build back
# at the very end of a successful build. If the build fails part-way, root-owned files can
# be left under the bind-mounted build/ directory, which the (non-root) caller could never
# delete. On exit, if anything under the work dir is not owned by the caller, chown it back
# from inside the already-present build image. Best effort: never changes the exit code.
normalize_ownership() {
  [[ -n "${workDir:-}" && -d "$workDir" ]] || return 0
  [[ -n "$(find "$workDir" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]] || return 0
  if [[ "${CONTAINER_CMD:-}" == "docker" && -n "${CONTAINER_NAME:-}" ]] \
     && docker image inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "Restoring ownership of files left by the build container..."
    docker run --rm -v "$workDir:/w" --entrypoint chown "$CONTAINER_NAME" \
      -R "$(id -u):$(id -g)" /w &>/dev/null || true
  fi
  if [[ -n "$(find "$workDir" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
    echo -e "${YELLOW}[WARN] Some files under $workDir are not owned by $(id -un).${NC}"
  fi
}
trap normalize_ownership EXIT

# Refuse to run as root (WS rule: runs as a normal user, never with elevated privileges).
# Never write the privilege-escalation command's name as a word anywhere in this file: the
# build server refuses any script whose text contains it (scriptContainsSudo in
# external/build_server/utils.mjs).
if [[ "$(id -u)" -eq 0 ]]; then
  echo -e "${RED}Error: do not run this script as root.${NC}"
  exit "$EXIT_FAIL"
fi

usage() {
  echo 'NAME
       trezort_build.sh - verify Trezor Model T (T2T1) hardware wallet firmware

SYNOPSIS
       trezort_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]

DESCRIPTION
       --version   Firmware version to verify, e.g. "2.12.5" (required)
       --type      Firmware type. Accepted: standard|universal|multi  or
                   bitcoin-only|btc-only|btconly  (default: standard)
       --binary    Path to official firmware .bin (optional; downloaded if omitted)
       --arch      Accepted for ABS compatibility; unused for single-arch firmware

EXAMPLES
       trezort_build.sh --version 2.12.5 --type btc-only
       trezort_build.sh --version 2.12.5 --type universal'
}

# ---- Disclaimer -------------------------------------------------------------
echo -e "${YELLOW}"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Running this script will execute Docker containers,"
echo "download source code, and perform deterministic builds that may consume"
echo "significant system resources (CPU, memory, disk space)."
echo "Use at your own risk and ensure you understand what the script does before"
echo "execution."
echo "=============================================================================="
echo -e "${NC}"
sleep 2
echo

# ---- Self-identification (first action after the disclaimer, before any ----
# container-runtime detection or network/build work; joins app version -> script bytes)
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
echo "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "         sha256: ${SCRIPT_SHA256}"
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
  write_results "ftbfs" "${PRODUCT}: docker daemon not responding and podman unavailable."
  exit "$EXIT_FAIL"
else
  echo -e "${RED}Error: neither docker nor podman found. Install one of them.${NC}"
  write_results "ftbfs" "${PRODUCT}: no container runtime (docker/podman) available on host."
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
  echo -e "${RED}Error: invalid --version '$version' (expected numeric like 2.12.5)${NC}"
  exit "$EXIT_INVALID"
fi
# Upstream tags/downloads are 3-part. Accept X.Y.Z as-is; accept the 4-part Trezor metadata
# form X.Y.Z.0 and trim the trailing .0. Reject any other shape, so a non-zero 4th component
# is NOT silently built/compared as X.Y.Z while the report claims the 4-part version.
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

# ---- Make --binary absolute; accept a file or a directory of files ----------
# The build server passes a directory when an asset has several files; pick the one
# matching this --type (…-bitcoinonly.bin for bitcoin-only, the plain .bin otherwise).
if [[ -n "$BINARY_PATH" ]]; then
  [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
  if [[ -d "$BINARY_PATH" ]]; then
    binDir="$BINARY_PATH"
    if [[ "$firmwareType" == "bitcoin-only" ]]; then
      BINARY_PATH=$(find "$binDir" -maxdepth 1 -type f -name "trezor-${MODEL_LC}-*-bitcoinonly.bin" | sort | head -n1)
    else
      BINARY_PATH=$(find "$binDir" -maxdepth 1 -type f -name "trezor-${MODEL_LC}-*.bin" ! -name "*-bitcoinonly.bin" | sort | head -n1)
    fi
    if [[ -z "$BINARY_PATH" ]]; then
      echo -e "${RED}Error: no trezor-${MODEL_LC}-*.bin matching --type ${firmwareType} in directory: $binDir${NC}"
      exit "$EXIT_INVALID"
    fi
    echo "Selected from --binary directory: $BINARY_PATH"
  fi
  if [[ ! -f "$BINARY_PATH" ]]; then
    echo -e "${RED}Error: --binary file not found: $BINARY_PATH${NC}"
    exit "$EXIT_INVALID"
  fi
fi

# ---- Host tools ------------------------------------------------------------------
# Trezor's own build-docker.sh needs a host git checkout and host wget/sha256sum (it
# fetches and checks the Alpine tarball itself), so these are required on the host in
# addition to docker/podman. Fail early and clearly instead of part-way through.
missingTools=()
for tool in git wget sha256sum od dd awk; do
  command -v "$tool" &>/dev/null || missingTools+=("$tool")
done
if [[ ${#missingTools[@]} -gt 0 ]]; then
  echo -e "${RED}Error: missing host tools: ${missingTools[*]}${NC}"
  write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}): missing host tools: ${missingTools[*]}."
  exit "$EXIT_FAIL"
fi

# Work dir: version + type + PID so parallel/repeat runs never share a directory.
workDir="$(pwd)/trezor-t-work_${version}_${firmwareType}_$$"

echo
echo "Verifying ${PRODUCT} (${MODEL}) firmware v$version ($firmwareType)"
echo

prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"

  echo "Cloning Trezor firmware repository..."
  if ! git clone "$repo" trezor-firmware; then
    echo -e "${RED}Failed to clone repository${NC}"
    write_results "ftbfs" "${PRODUCT} v${version}: failed to clone ${repo}."
    exit "$EXIT_FAIL"
  fi

  cd trezor-firmware
  echo "Checking out core/v${normalizedVersion}..."
  if ! git checkout "core/v${normalizedVersion}"; then
    echo -e "${RED}Failed to checkout core/v${normalizedVersion}${NC}"
    write_results "ftbfs" "${PRODUCT} v${version}: git tag core/v${normalizedVersion} not found."
    exit "$EXIT_FAIL"
  fi
  commit=$(git rev-parse "HEAD")
  tagType=$(git cat-file -t "core/v${normalizedVersion}" 2>/dev/null || echo "unknown")
  case "$tagType" in
    tag)    tagType="annotated" ;;
    commit) tagType="lightweight" ;;
  esac
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
      url="https://data.trezor.io/firmware/${MODEL_LC}/trezor-${MODEL_LC}-${normalizedVersion}-bitcoinonly.bin"
    else
      url="https://data.trezor.io/firmware/${MODEL_LC}/trezor-${MODEL_LC}-${normalizedVersion}.bin"
    fi
    if ! wget -q -O official.bin "$url"; then
      echo -e "${RED}Failed to download official firmware: $url${NC}"
      write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}): failed to download official firmware from ${url}."
      exit "$EXIT_FAIL"
    fi
  fi

  officialHash=$(sha256sum official.bin | awk '{print $1}')
  echo -e "${GREEN}Official firmware hash: $officialHash${NC}"
}

build_firmware() {
  cd "$workDir/trezor-firmware"

  # Note: builds the default board pinned in this tag's model.toml (default_board = "hw"
  # as of core/v2.12.5); no HW_REVISION override is passed, matching upstream's own
  # default production build.

  # Model- and type-scoped image/container name. build-docker.sh derives its snapshot
  # container name from CONTAINER_NAME + tag; a model-less name would collide with a
  # Safe 5 or Safe 7 run of the same version and edition on the same host.
  if [[ "$firmwareType" == "bitcoin-only" ]]; then
    export CONTAINER_NAME="trezor-firmware-env-${MODEL_LC}-bitcoinonly-${normalizedVersion}.nix"
    skipFlag="--skip-normal"
    builtFirmware="build/core-${MODEL}-bitcoinonly/firmware/firmware.bin"
    echo "Building bitcoin-only firmware for $MODEL..."
  else
    export CONTAINER_NAME="trezor-firmware-env-${MODEL_LC}-standard-${normalizedVersion}.nix"
    skipFlag="--skip-bitcoinonly"
    builtFirmware="build/core-${MODEL}/firmware/firmware.bin"
    echo "Building standard firmware for $MODEL..."
  fi

  # Only the firmware target, as upstream CI does (.github/workflows/common.yml:
  # --targets 'firmware'). The default list (boardloader bootloader secmon firmware)
  # would also build a secmon, which T2T1 does not have (no `secmon` key in its
  # model.toml), and images this script does not compare.
  # build-docker.sh bind-mounts build/core-T2T1{,-bitcoinonly} without creating them;
  # Docker creates bind sources implicitly, rootless podman refuses, so create them first.
  mkdir -p "build/core-${MODEL}" "build/core-${MODEL}-bitcoinonly"
  if ! ./build-docker.sh --models "$MODEL" --targets firmware "$skipFlag" "core/v${normalizedVersion}"; then
    echo -e "${RED}Build failed!${NC}"
    write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}): build-docker.sh build failed."
    exit "$EXIT_FAIL"
  fi

  if [[ ! -f "$builtFirmware" ]]; then
    echo -e "${RED}Built firmware not found: $builtFirmware${NC}"
    write_results "ftbfs" "${PRODUCT} v${version}: build completed but firmware not found at ${builtFirmware}."
    exit "$EXIT_FAIL"
  fi
  echo -e "${GREEN}Firmware built successfully${NC}"

  # Fingerprint Trezor's tooling printed for this build (build/<commit>.fingerprints).
  local fpKey fpFile
  if [[ "$firmwareType" == "bitcoin-only" ]]; then fpKey="${MODEL_LC}_btconly"; else fpKey="${MODEL_LC}_universal"; fi
  fpFile="build/${commit}.fingerprints"
  builtFingerprint=$(grep -m1 "^${fpKey}:" "$fpFile" 2>/dev/null | cut -d: -f2- | tr -d ' ' || true)
  [[ -n "$builtFingerprint" ]] || builtFingerprint="N/A"
}

compare_firmware() {
  cd "$workDir"
  builtHash=$(sha256sum "trezor-firmware/$builtFirmware" | awk '{print $1}')

  # Fail closed on header shape: the official image must start with vendor-header magic
  # "TRZV" (0x54525a56), declare a 4608-byte vendor header (bytes 4-7, uint32 LE), and
  # have the firmware-header magic "TRZF" (0x54525a46) right after it. The 65-byte
  # signature (sigmask 1B + signature 64B) sits 959 bytes into that firmware header ->
  # offset 4608 + 959 = 5567. Refuse to guess if the header does not match, rather than
  # zero the wrong bytes and report a false verdict.
  local magicHex fwMagicHex
  magicHex=$(head -c4 official.bin 2>/dev/null | od -An -tx1 | tr -d ' \n')
  vhLen=$(od -An -tu4 -j4 -N4 official.bin 2>/dev/null | tr -d '[:space:]')
  fwMagicHex=""
  if [[ "$vhLen" =~ ^[0-9]+$ ]]; then
    fwMagicHex=$(od -An -tx1 -j"$vhLen" -N4 official.bin 2>/dev/null | tr -d ' \n')
  fi
  if [[ "$magicHex" != "54525a56" || "$vhLen" != "$EXPECTED_VH_LEN" || "$fwMagicHex" != "54525a46" ]]; then
    echo -e "${RED}Unexpected firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}).${NC}"
    write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}): unexpected firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}); expected TRZV / ${EXPECTED_VH_LEN}B / TRZF for ${MODEL} - refusing to guess signature offset."
    exit "$EXIT_FAIL"
  fi
  seekSize=$(( vhLen + SIG_INNER ))   # 4608 + 959 = 5567

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
echo "Starting ${PRODUCT} verification..."
echo "This may take 15-30 minutes."
echo

prepare
download_official
build_firmware
compare_firmware

print_hash_legend() {
  echo
  echo "----- What these hashes mean -----"
  echo "appHash       SHA-256 of the official firmware exactly as downloaded from"
  echo "              data.trezor.io (signed). THIS is the official hash to publish."
  echo "zeroedHash    The official firmware with its 65-byte firmware-header signature"
  echo "              (offset ${seekSize}) set to zero. Published nowhere, shown by no device;"
  echo "              it exists only to be compared with the unsigned local build."
  echo "builtHash     SHA-256 of the firmware this script built from core/v${normalizedVersion}."
  echo "fingerprint   Trezor's firmware fingerprint of this build (header with signatures"
  echo "              cleared). This is the value a Trezor shows on screen during a"
  echo "              firmware update, and should equal the fingerprint Trezor lists for"
  echo "              this version in data.trezor.io/firmware/${MODEL_LC}/releases.json."
  echo
  echo "MATCH means builtHash == zeroedHash. It does NOT verify Trezor's signature."
  echo "Do not publish zeroedHash or builtHash as the official hash."
  echo "----------------------------------"
}

if [[ "$verdict" == "reproducible" ]]; then matchFlag="1 (MATCHES)"; else matchFlag="0 (DOESN'T MATCH)"; fi
if [[ "$firmwareType" == "bitcoin-only" ]]; then
  officialName="trezor-${MODEL_LC}-${normalizedVersion}-bitcoinonly.bin"
else
  officialName="trezor-${MODEL_LC}-${normalizedVersion}.bin"
fi

print_hash_legend
echo
echo "===== Begin Results ====="
echo "appId:          trezorT"
echo "firmware:       ${PRODUCT}"
echo "model:          ${MODEL}"
echo "version:        $version"
echo "type:           $firmwareType"
echo "verdict:        $verdict"
echo "appHash:        $officialHash"
echo "                  official firmware as downloaded (signed) - publish this"
echo "zeroedHash:     $officialZeroedHash"
echo "                  official firmware with signature zeroed at offset ${seekSize}"
echo "builtHash:      $builtHash"
echo "                  built from source - must equal zeroedHash"
echo "fingerprint:    $builtFingerprint"
echo "                  Trezor firmware fingerprint of the build (shown on device)"
echo "commit:         $commit"
echo "scriptVersion:  $SCRIPT_VERSION"
echo "scriptHash:     $SCRIPT_SHA256"
echo
echo "Diff:"
echo "BUILDS MATCH BINARIES"
echo "${officialName} - ${MODEL}-${firmwareType} - ${builtHash} - ${matchFlag}"
echo "(compared after zeroing the 65-byte signature at offset ${seekSize}; no other bytes excluded)"
echo
echo "Revision, tag (and its signature):"
echo "Tag type: ${tagType} (core/v${normalizedVersion} -> ${commit})"
echo "[INFO] Tag signature not verified by this script."
echo "===== End Results ====="
echo

if [[ "$verdict" == "reproducible" ]]; then
  write_results "reproducible" "${PRODUCT} v${version} (${firmwareType}) reproducible from source via build-docker.sh at core/v${normalizedVersion} (commit ${commit}); official firmware-header signature (offset ${seekSize}, 65B) zeroed before SHA-256 comparison."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_OK"
else
  write_results "not_reproducible" "${PRODUCT} v${version} (${firmwareType}) not reproducible: built ${builtHash} != zeroed official ${officialZeroedHash} (signature zeroed at offset ${seekSize}, 65B)."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_FAIL"
fi
