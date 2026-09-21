#!/bin/bash
# ==============================================================================
# trezorsafe3_build.sh - Trezor Safe 3 (T2B1 rev.A / T3B1 rev.B) Firmware Reproducible Build Verification
# ==============================================================================
# Version:           v0.1.0
# Organization:      WalletScrutiny.com
# Last modified by:  dannybuntu
# Last modified on:  2026-09-21
# Project:           https://github.com/trezor/trezor-firmware
# Usage:             trezorsafe3_build.sh --version VERSION [--type TYPE] [--binary PATH]
#                    [--revision a|b] [--arch ARCH]
# ==============================================================================
# LICENSE: MIT License
#
# Changelog is kept outside this file (WalletScrutiny script notes, hardware/trezorSafe3).
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
# The Trezor Safe 3 ships as two hardware revisions with different main processors, and Trezor
# publishes separate firmware for each: T2B1 (rev.A, STM32F427) and T3B1 (rev.B, STM32U58x).
# - Selects the revision(s): from the official file's own firmware header (hw_model) when
#   --binary is given; otherwise both revisions, or the one named by --revision
# - Clones trezor-firmware and checks out tag core/vVERSION
# - Downloads the official signed firmware for each selected revision from data.trezor.io
#   (or uses --binary)
# - Builds with Trezor's own build-docker.sh (--targets firmware, one edition, selected models)
# - Zeroes each official file's 65-byte firmware-header signature at offset 512 + 959 = 1471
#   (Safe 3 vendor header is 512 bytes; docs/common/reproducible-build.md), refusing to guess
#   if the TRZV / 512-byte / TRZF / hw_model header shape does not match
# - Compares SHA-256 of each zeroed official file with the unsigned local build of the same
#   revision; the verdict is reproducible only if every compared revision matches
# - Prints labelled hashes per revision (appHash = official as downloaded) and writes
#   COMPARISON_RESULTS.yaml
# ==============================================================================

set -eE

# ---- Globals (RESULTS_FILE captured before any cd) --------------------------
SCRIPT_VERSION="v0.1.0"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
repo="https://github.com/trezor/trezor-firmware.git"
firmwareType="standard"
version=""
BINARY_PATH=""
ARCH=""
REVISION_ARG=""

PRODUCT="Trezor Safe 3"
APP_ID="trezorSafe3"
ALL_MODELS=(T2B1 T3B1)
EXPECTED_VH_LEN=512    # Safe 3 vendor header size (upstream reproducible-build.md)
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

rev_label() {
  case "$1" in
    T2B1) echo "rev.A, STM32F427" ;;
    T3B1) echo "rev.B, STM32U58x" ;;
    *)    echo "unknown revision" ;;
  esac
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
       trezorsafe3_build.sh - verify Trezor Safe 3 (T2B1 rev.A / T3B1 rev.B) firmware

SYNOPSIS
       trezorsafe3_build.sh --version VERSION [--type TYPE] [--binary PATH]
                            [--revision a|b] [--arch ARCH]

DESCRIPTION
       The Safe 3 has two hardware revisions with separate firmware files:
       T2B1 = rev.A (STM32F427), T3B1 = rev.B (STM32U58x).

       --version   Firmware version to verify, e.g. "2.12.5" (required)
       --type      Firmware type. Accepted: standard|universal|multi  or
                   bitcoin-only|btc-only|btconly  (default: standard)
       --binary    Official firmware .bin, or a directory holding
                   trezor-t2b1-/trezor-t3b1-VERSION[-bitcoinonly].bin. The revision of a file
                   is read from its firmware header. Optional; downloaded if omitted.
       --revision  a|b (also T2B1|T3B1). Limit to one revision. Default: both
                   revisions when downloading; with --binary, the revision in that file.
       --arch      Accepted for ABS compatibility; unused

EXAMPLES
       trezorsafe3_build.sh --version 2.12.5 --type btc-only
       trezorsafe3_build.sh --version 2.12.5 --type universal --revision b'
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
    --binary)   BINARY_PATH="${2:-}";  shift 2 || shift ;;
    --version)  version="${2:-}";      shift 2 || shift ;;
    --arch)     ARCH="${2:-}";         shift 2 || shift ;;
    --type)     firmwareType="${2:-}"; shift 2 || shift ;;
    --revision) REVISION_ARG="${2:-}"; shift 2 || shift ;;
    -h|--help)  usage; exit "$EXIT_OK" ;;
    *)          echo -e "${YELLOW}[WARN] Ignoring unknown argument: $1${NC}"; shift ;;
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
if [[ "$firmwareType" == "bitcoin-only" ]]; then editionSuffix="-bitcoinonly"; else editionSuffix=""; fi

# ---- Normalize --revision ---------------------------------------------------
revisionModel=""
case "${REVISION_ARG,,}" in
  "")                      revisionModel="" ;;
  a|reva|rev.a|t2b1)       revisionModel="T2B1" ;;
  b|revb|rev.b|t3b1)       revisionModel="T3B1" ;;
  *)
    echo -e "${RED}Error: invalid --revision '$REVISION_ARG' (use a|b or T2B1|T3B1)${NC}"
    exit "$EXIT_INVALID" ;;
esac

# Read a firmware file's header: prints "<magicHex> <vhLen> <fwMagicHex> <hwModel>".
read_header() {
  local f="$1" m vh fm hw
  m=$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  vh=$(od -An -tu4 -j4 -N4 "$f" 2>/dev/null | tr -d '[:space:]')
  fm=""; hw=""
  if [[ "$vh" =~ ^[0-9]+$ ]]; then
    fm=$(od -An -tx1 -j"$vh" -N4 "$f" 2>/dev/null | tr -d ' \n')
    hw=$(dd if="$f" bs=1 skip=$(( vh + 24 )) count=4 2>/dev/null | tr -cd 'A-Z0-9')
  fi
  echo "${m:-none} ${vh:-none} ${fm:-none} ${hw:-none}"
}

# ---- Select revision(s) and official files ----------------------------------
# MODELS: revisions to verify. OFFICIAL_SRC[model]: provided file (empty -> download).
declare -A OFFICIAL_SRC=()
MODELS=()
if [[ -n "$BINARY_PATH" ]]; then
  [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
  if [[ -d "$BINARY_PATH" ]]; then
    # The build server passes a directory when an asset has several files. Take the file for
    # exactly this --version and --type for each candidate revision.
    binDir="${BINARY_PATH%/}"
    if [[ -n "$revisionModel" ]]; then candidates=("$revisionModel"); else candidates=("${ALL_MODELS[@]}"); fi
    for m in "${candidates[@]}"; do
      f="${binDir}/trezor-${m,,}-${normalizedVersion}${editionSuffix}.bin"
      if [[ -f "$f" ]]; then
        MODELS+=("$m"); OFFICIAL_SRC[$m]="$f"
        echo "Selected from --binary directory: $f"
      elif [[ -n "$revisionModel" ]]; then
        echo -e "${RED}Error: ${f##*/} not found in directory: $binDir${NC}"
        exit "$EXIT_INVALID"
      fi
    done
    if [[ ${#MODELS[@]} -eq 0 ]]; then
      echo -e "${RED}Error: no trezor-t2b1/t3b1-${normalizedVersion}${editionSuffix}.bin in directory: $binDir${NC}"
      exit "$EXIT_INVALID"
    fi
  elif [[ -f "$BINARY_PATH" ]]; then
    # The file says which revision it is: hw_model sits 24 bytes into the firmware header.
    read -r _ _ _ fileModel <<< "$(read_header "$BINARY_PATH")"
    if [[ "$fileModel" != "T2B1" && "$fileModel" != "T3B1" ]]; then
      echo -e "${RED}Error: --binary is not Safe 3 firmware (hw_model '${fileModel}', expected T2B1 or T3B1)${NC}"
      exit "$EXIT_INVALID"
    fi
    if [[ -n "$revisionModel" && "$revisionModel" != "$fileModel" ]]; then
      echo -e "${RED}Error: --revision ${revisionModel} but --binary is ${fileModel} firmware${NC}"
      exit "$EXIT_INVALID"
    fi
    MODELS=("$fileModel"); OFFICIAL_SRC[$fileModel]="$BINARY_PATH"
    echo "Revision from --binary firmware header: ${fileModel} ($(rev_label "$fileModel"))"
  else
    echo -e "${RED}Error: --binary file not found: $BINARY_PATH${NC}"
    exit "$EXIT_INVALID"
  fi
else
  if [[ -n "$revisionModel" ]]; then MODELS=("$revisionModel"); else MODELS=("${ALL_MODELS[@]}"); fi
fi

# Revision tag for resource names: t2b1, t3b1, or safe3 when both are built together.
if [[ ${#MODELS[@]} -eq 1 ]]; then revTag="${MODELS[0],,}"; else revTag="safe3"; fi

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

# Work dir: version + type + revision(s) + PID so parallel/repeat runs never share a directory.
workDir="$(pwd)/trezor-safe3-work_${version}_${firmwareType}_${revTag}_$$"

echo
echo "Verifying ${PRODUCT} firmware v$version ($firmwareType)"
for m in "${MODELS[@]}"; do echo "  revision: ${m} ($(rev_label "$m"))"; done
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

declare -A OFFICIAL_HASH=() ZEROED_HASH=() BUILT_HASH=() FINGERPRINT=() SEEK=() MATCH=()

download_official() {
  cd "$workDir"
  local m url
  for m in "${MODELS[@]}"; do
    if [[ -n "${OFFICIAL_SRC[$m]:-}" ]]; then
      echo "Using provided official binary for ${m}: ${OFFICIAL_SRC[$m]}"
      cp "${OFFICIAL_SRC[$m]}" "official_${m}.bin"
    else
      url="https://data.trezor.io/firmware/${m,,}/trezor-${m,,}-${normalizedVersion}${editionSuffix}.bin"
      echo "Downloading official ${m} firmware..."
      if ! wget -q -O "official_${m}.bin" "$url"; then
        echo -e "${RED}Failed to download official firmware: $url${NC}"
        write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}, ${m}): failed to download official firmware from ${url}."
        exit "$EXIT_FAIL"
      fi
    fi
    OFFICIAL_HASH[$m]=$(sha256sum "official_${m}.bin" | awk '{print $1}')
    echo -e "${GREEN}Official ${m} firmware hash: ${OFFICIAL_HASH[$m]}${NC}"
  done
}

build_firmware() {
  cd "$workDir/trezor-firmware"

  # Note: builds each model's default board pinned in this tag's model.toml
  # (T2B1 rev10, T3B1 revB as of core/v2.12.5); no HW_REVISION override is passed, matching
  # upstream's own default production build.

  # Revision-, edition- and version-scoped image/container name. build-docker.sh derives its
  # snapshot container name from CONTAINER_NAME + tag, so a name without the model would
  # collide with another Trezor model's run of the same version and edition.
  local modelsCsv m
  if [[ "$firmwareType" == "bitcoin-only" ]]; then
    export CONTAINER_NAME="trezor-firmware-env-${revTag}-bitcoinonly-${normalizedVersion}.nix"
    skipFlag="--skip-normal"
  else
    export CONTAINER_NAME="trezor-firmware-env-${revTag}-standard-${normalizedVersion}.nix"
    skipFlag="--skip-bitcoinonly"
  fi
  modelsCsv=$(IFS=,; echo "${MODELS[*]}")
  echo "Building ${firmwareType} firmware for ${modelsCsv}..."

  # Only the firmware target, as upstream CI does (.github/workflows/common.yml:
  # --targets 'firmware'). Neither Safe 3 revision has a secmon (no `secmon` key in model.toml).
  # build-docker.sh bind-mounts build/core-<MODEL>{,-bitcoinonly} without creating them;
  # Docker creates bind sources implicitly, rootless podman refuses, so create them first.
  for m in "${MODELS[@]}"; do mkdir -p "build/core-${m}" "build/core-${m}-bitcoinonly"; done
  if ! ./build-docker.sh --models "$modelsCsv" --targets firmware "$skipFlag" "core/v${normalizedVersion}"; then
    echo -e "${RED}Build failed!${NC}"
    write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}, ${modelsCsv}): build-docker.sh build failed."
    exit "$EXIT_FAIL"
  fi

  for m in "${MODELS[@]}"; do
    if [[ ! -f "build/core-${m}${editionSuffix}/firmware/firmware.bin" ]]; then
      echo -e "${RED}Built firmware not found: build/core-${m}${editionSuffix}/firmware/firmware.bin${NC}"
      write_results "ftbfs" "${PRODUCT} v${version} (${m}): build completed but firmware.bin not found."
      exit "$EXIT_FAIL"
    fi
  done
  echo -e "${GREEN}Firmware built successfully${NC}"

  # Fingerprint Trezor's tooling printed for each build (build/<commit>.fingerprints). Match
  # the edition's own artifact header ("# core-<MODEL>[-bitcoinonly]/firmware/...") and take the
  # line right after it, never a label. The value must be 64 hex characters.
  local fpFile="build/${commit}.fingerprints" fpHeader fp
  for m in "${MODELS[@]}"; do
    fpHeader="# core-${m}${editionSuffix}/firmware/"
    fp=$(awk -v h="$fpHeader" 'found { sub(/^[^:]*:/, ""); gsub(/[[:space:]]/, ""); print; exit }
                               index($0, h) == 1 { found = 1 }' "$fpFile" 2>/dev/null || true)
    if [[ ! "$fp" =~ ^[0-9a-f]{64}$ ]]; then
      echo -e "${YELLOW}[WARN] Could not read the ${m} fingerprint from ${fpFile}; reporting N/A.${NC}"
      fp="N/A"
    fi
    FINGERPRINT[$m]="$fp"
  done
}

compare_firmware() {
  cd "$workDir"
  local m magicHex vhLen fwMagicHex hwModel seekSize
  verdict="reproducible"
  for m in "${MODELS[@]}"; do
    BUILT_HASH[$m]=$(sha256sum "trezor-firmware/build/core-${m}${editionSuffix}/firmware/firmware.bin" | awk '{print $1}')

    # Fail closed on header shape: "TRZV" (0x54525a56), a 512-byte vendor header (bytes 4-7,
    # uint32 LE), "TRZF" (0x54525a46) right after it, and hw_model (firmware header +24)
    # equal to this revision. The 65-byte signature (sigmask 1B + signature 64B) sits 959
    # bytes into the firmware header -> offset 512 + 959 = 1471.
    read -r magicHex vhLen fwMagicHex hwModel <<< "$(read_header "official_${m}.bin")"
    if [[ "$magicHex" != "54525a56" || "$vhLen" != "$EXPECTED_VH_LEN" || "$fwMagicHex" != "54525a46" || "$hwModel" != "$m" ]]; then
      echo -e "${RED}Unexpected ${m} firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}, hw_model=${hwModel}).${NC}"
      write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}, ${m}): unexpected firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}, hw_model=${hwModel}); expected TRZV / ${EXPECTED_VH_LEN}B / TRZF / ${m} - refusing to guess signature offset."
      exit "$EXIT_FAIL"
    fi
    seekSize=$(( vhLen + SIG_INNER ))   # 512 + 959 = 1471
    SEEK[$m]="$seekSize"

    cp "official_${m}.bin" "official_${m}.zeroed"
    dd if=/dev/zero of="official_${m}.zeroed" bs=1 seek="$seekSize" count=65 conv=notrunc 2>/dev/null
    ZEROED_HASH[$m]=$(sha256sum "official_${m}.zeroed" | awk '{print $1}')

    echo
    echo "============================================================"
    echo "Revision:            ${m} ($(rev_label "$m"))"
    echo "Vendor header:       ${vhLen} bytes  (signature zeroed at offset ${seekSize}, 65 bytes)"
    echo "Official (signed):   ${OFFICIAL_HASH[$m]}"
    echo "Official (zeroed):   ${ZEROED_HASH[$m]}"
    echo "Built (unsigned):    ${BUILT_HASH[$m]}"
    echo "============================================================"
    if [[ "${BUILT_HASH[$m]}" == "${ZEROED_HASH[$m]}" ]]; then
      echo -e "${GREEN}REPRODUCIBLE: ${m} firmware matches${NC}"
      MATCH[$m]=1
    else
      echo -e "${RED}NOT REPRODUCIBLE: ${m} firmware differs${NC}"
      MATCH[$m]=0
      verdict="not_reproducible"
    fi
  done
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
  echo "Each revision has its own firmware file and its own set of hashes:"
  echo "T2B1 = Safe 3 rev.A (STM32F427), T3B1 = Safe 3 rev.B (STM32U58x)."
  echo "appHash       SHA-256 of that revision's official firmware exactly as downloaded"
  echo "              from data.trezor.io (signed). THIS is the official hash to publish"
  echo "              for that file."
  echo "zeroedHash    The official firmware with its 65-byte firmware-header signature"
  echo "              (offset 1471) set to zero. Published nowhere, shown by no device;"
  echo "              it exists only to be compared with the unsigned local build."
  echo "builtHash     SHA-256 of the firmware this script built from the tagged repository"
  echo "              (core/v${normalizedVersion}) for that revision."
  echo "fingerprint   Trezor's firmware fingerprint of the build (header with signatures"
  echo "              cleared). This is the value a Trezor shows on screen during a"
  echo "              firmware update, and should equal the fingerprint Trezor lists for"
  echo "              this version in data.trezor.io/firmware/<t2b1|t3b1>/releases.json."
  echo
  echo "MATCH means builtHash == zeroedHash. It does NOT verify Trezor's signature."
  echo "Do not publish zeroedHash or builtHash as the official hash."
  echo "----------------------------------"
}

print_hash_legend
echo
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "firmware:       ${PRODUCT}"
echo "version:        $version"
echo "type:           $firmwareType"
echo "revisions:      ${MODELS[*]}"
echo "verdict:        $verdict"
for m in "${MODELS[@]}"; do
  echo "--- ${m} ($(rev_label "$m")) ---"
  echo "appHash_${m}:   ${OFFICIAL_HASH[$m]}"
  echo "                  official ${m} firmware as downloaded (signed) - publish this"
  echo "zeroedHash_${m}: ${ZEROED_HASH[$m]}"
  echo "                  official ${m} firmware with signature zeroed at offset ${SEEK[$m]}"
  echo "builtHash_${m}: ${BUILT_HASH[$m]}"
  echo "                  built from the tagged repository - must equal zeroedHash_${m}"
  echo "fingerprint_${m}: ${FINGERPRINT[$m]}"
  echo "                  Trezor firmware fingerprint of the build (shown on device)"
done
echo "commit:         $commit"
echo "scriptVersion:  $SCRIPT_VERSION"
echo "scriptHash:     $SCRIPT_SHA256"
echo
echo "Diff:"
echo "BUILDS MATCH BINARIES"
for m in "${MODELS[@]}"; do
  if [[ "${MATCH[$m]}" == "1" ]]; then flag="1 (MATCHES)"; else flag="0 (DOESN'T MATCH)"; fi
  echo "trezor-${m,,}-${normalizedVersion}${editionSuffix}.bin - ${m}-${firmwareType} - ${BUILT_HASH[$m]} - ${flag}"
done
echo "(each compared after zeroing its 65-byte signature at offset 1471; no other bytes excluded)"
echo
echo "Revision, tag (and its signature):"
echo "Tag type: ${tagType} (core/v${normalizedVersion} -> ${commit})"
echo "[INFO] Tag signature not verified by this script."
echo "===== End Results ====="
echo

summary=""
for m in "${MODELS[@]}"; do
  if [[ "${MATCH[$m]}" == "1" ]]; then r="match"; else r="built ${BUILT_HASH[$m]} != zeroed ${ZEROED_HASH[$m]}"; fi
  summary="${summary}${m}: ${r}; "
done

if [[ "$verdict" == "reproducible" ]]; then
  write_results "reproducible" "${PRODUCT} v${version} (${firmwareType}; ${MODELS[*]}) reproducible from the tagged repository via build-docker.sh at core/v${normalizedVersion} (commit ${commit}); ${summary}official firmware-header signature (offset 1471, 65B) zeroed before SHA-256 comparison."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_OK"
else
  write_results "not_reproducible" "${PRODUCT} v${version} (${firmwareType}; ${MODELS[*]}) not reproducible: ${summary}signature zeroed at offset 1471, 65B."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_FAIL"
fi
