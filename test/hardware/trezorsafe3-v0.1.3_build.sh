#!/bin/bash
# ==============================================================================
# trezorsafe3_build.sh - Trezor Safe 3 (T2B1 rev.A / T3B1 rev.B) Firmware Reproducible Build Verification
# ==============================================================================
# Version:           v0.1.3
# Organization:      WalletScrutiny.com
# Last modified by:  Claude Code for Danny
# Last modified on:  2026-10-22
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
# - Creates a per-run workspace in the caller's directory (never reused or deleted)
# - Clones trezor-firmware and checks out tag core/vVERSION
# - Downloads the official signed firmware for each selected revision from data.trezor.io
#   (or uses --binary)
# - Prepares Trezor's build environment with build-docker.sh --init-only (downloads only; a
#   failure here writes no verdict), then builds with build-docker.sh --no-init
#   (--targets firmware, one edition, selected models; a failure here is ftbfs)
# - Zeroes each official file's 65-byte firmware-header signature at offset 512 + 959 = 1471
#   (Safe 3 vendor header is 512 bytes; docs/common/reproducible-build.md), refusing to guess
#   if the TRZV / 512-byte / TRZF / hw_model header shape does not match
# - Compares SHA-256 of each zeroed official file with the unsigned local build of the same
#   revision; the verdict is reproducible only if every compared revision matches
# - Bootloader: each firmware embeds a prebuilt, signed bootloader committed to the repository
#   (core/embed/models/<MODEL>/bootloaders/bootloader_<MODEL>.bin). The script reads its version,
#   clones the matching release tag core/bl<VERSION>, builds the bootloader there with that tag's
#   own build-docker.sh (--targets bootloader), then fills in the two fields Trezor's signing
#   adds: the 65-byte signature (0x3BF) is zeroed on both sides, and the code hash at 0x20 in
#   the committed file must equal the model's hash (models.py) of our built code. The revision is
#   reproducible only if both the firmware and its bootloader match (as in the Trezor One script).
# - Prints one results block per revision (appHash = that revision's official file as
#   downloaded) and writes COMPARISON_RESULTS.yaml next to this script
# - Exit codes: 0 reproducible; 1 not reproducible, ftbfs or a failure with no verdict;
#   2 invalid parameters; 130 stopped. A YAML is written only for a real verdict.
# ==============================================================================

set -eE

# ---- Globals (paths captured before any cd) ---------------------------------
SCRIPT_VERSION="v0.1.3"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_SHA256=""
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
CALLER_DIR="$(pwd -P)"
RUN_ID="$(date +%s)-$$"
RESULTS_WRITTEN=0
workDir=""
CONTAINER_CMD=""
CONTAINER_NAME=""
SNAPSHOT_NAME=""
EXTRA_IMAGES=()   # bootloader build images of this run, removed at exit
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
  RESULTS_WRITTEN=1
  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
  # Per-run copy inside this run's workspace. Deliberately NOT named COMPARISON_RESULTS.yaml:
  # ABS searches its build directory recursively for that name.
  if [[ -n "$workDir" && -d "$workDir" ]]; then
    cp -p "$RESULTS_FILE" "$workDir/results_${RUN_ID}.yaml" 2>/dev/null || true
  fi
}

# no_verdict: a failure that says nothing about the source (runtime, host tools, network,
# a missing tag, an official file of the wrong shape). Writes no YAML, so ABS publishes nothing.
no_verdict() {
  echo -e "${RED}Error: $1${NC}"
  echo -e "${RED}No verdict written (this is not a build failure of the source).${NC}"
  exit "$EXIT_FAIL"
}

# Any unguarded command failure is a script/infrastructure problem, never a verdict.
handle_err() {
  local rc=$?
  trap - ERR
  no_verdict "unexpected error (exit ${rc}) during verification"
}
trap handle_err ERR

# ---- Exit cleanup: ownership hand-back, then this run's images --------------
# build-docker.sh runs its build as root inside the container and chowns /build back to the
# directory owner at the end. Under docker a part-way failure can leave root-owned files; under
# rootless podman that chown maps to a subuid. Either way the (non-root) caller could not
# delete them. Hand everything under the workspace back to the caller, then remove the
# per-run environment image and snapshot. Best effort: never changes the exit code.
cleanup() {
  local rc=$?
  if [[ -n "$workDir" && -d "$workDir" ]]; then
    if [[ "$CONTAINER_CMD" == "podman" ]]; then
      podman unshare chown -R 0:0 "$workDir" &>/dev/null || true
    elif [[ "$CONTAINER_CMD" == "docker" && -n "$CONTAINER_NAME" ]] \
         && [[ -n "$(find "$workDir" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]] \
         && docker image inspect "$CONTAINER_NAME" &>/dev/null; then
      echo "Restoring ownership of files left by the build container..."
      docker run --rm -v "$workDir:/w" --entrypoint chown "$CONTAINER_NAME" \
        -R "$(id -u):$(id -g)" /w &>/dev/null || true
    fi
    if [[ -n "$(find "$workDir" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
      echo -e "${YELLOW}[WARN] Some files under $workDir are not owned by $(id -un).${NC}"
    fi
  fi
  if [[ -n "$CONTAINER_CMD" && -n "$CONTAINER_NAME" ]]; then
    "$CONTAINER_CMD" rm -f "$SNAPSHOT_NAME" &>/dev/null || true
    "$CONTAINER_CMD" rmi -f "$SNAPSHOT_NAME" "$CONTAINER_NAME" &>/dev/null || true
  fi
  local img
  for img in "${EXTRA_IMAGES[@]}"; do
    "$CONTAINER_CMD" rm -f "$img" &>/dev/null || true
    "$CONTAINER_CMD" rmi -f "$img" &>/dev/null || true
  done
  [[ "$RESULTS_WRITTEN" == "1" ]] || echo -e "${YELLOW}[WARN] No COMPARISON_RESULTS.yaml written for this run.${NC}"
  echo "Exit code: ${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Refuse to run as root (WS rule: runs as a normal user, never with elevated privileges).
# Never write the privilege-escalation command's name as a word anywhere in this file: the
# build server refuses any script whose text contains it (scriptContainsSudo in
# external/build_server/utils.mjs).
if [[ "$(id -u)" -eq 0 ]]; then
  echo -e "${RED}Error: do not run this script as root.${NC}"
  exit "$EXIT_INVALID"
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

# One run at a time per script directory: every run writes the same COMPARISON_RESULTS.yaml
# next to the script (where ABS reads it), so two parallel runs from one folder would overwrite
# each other's verdict. flock releases on any exit, so a crash never leaves a stale lock. ABS gives
# each job its own directory, so this never triggers there. Refusing writes no verdict.
if command -v flock &>/dev/null; then
  exec 9>"${SCRIPT_DIR}/.comparison_results.lock"
  if ! flock -n 9; then
    echo -e "${RED}Error: another verification is already running from ${SCRIPT_DIR} (it shares COMPARISON_RESULTS.yaml). Run this one after it, or from a copy of the script in another folder.${NC}"
    echo -e "${RED}No verdict written.${NC}"
    exit "$EXIT_FAIL"
  fi
else
  echo -e "${YELLOW}[WARN] flock not found; parallel runs from this folder would share COMPARISON_RESULTS.yaml.${NC}"
fi

# Remove a previous verdict before this invocation can fail, so ABS can never pick up a
# stale COMPARISON_RESULTS.yaml from an earlier run.
rm -f -- "$RESULTS_FILE"

# ---- Container runtime detection (actually wired into build-docker.sh) ------
# build-docker.sh reads $DOCKER (default "docker"); export the detected runtime
# so a podman-only host genuinely uses podman instead of silently failing.
if command -v docker &>/dev/null && docker info &>/dev/null; then
  CONTAINER_CMD="docker"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
  no_verdict "docker is installed but its daemon is not responding, and podman is unavailable"
else
  no_verdict "neither docker nor podman found; install one of them"
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
for tool in git wget sha256sum od dd awk openssl; do
  command -v "$tool" &>/dev/null || missingTools+=("$tool")
done
if [[ ${#missingTools[@]} -gt 0 ]]; then
  no_verdict "missing host tools: ${missingTools[*]}"
fi

# Per-run workspace in the caller's directory: version + type + revision(s) + epoch-PID, created
# with an exclusive mkdir. Never reused, renamed or deleted, so concurrent runs (same or other
# users, e.g. ABS) cannot touch each other's files.
wd="${CALLER_DIR}/trezorSafe3_verification_${version}_${firmwareType}_${revTag}_${RUN_ID}"
if ! mkdir -- "$wd"; then
  echo -e "${RED}Error: work directory already exists or cannot be created: $wd${NC}"
  exit "$EXIT_INVALID"
fi
workDir="$wd"

echo
echo "Verifying ${PRODUCT} firmware v$version ($firmwareType)"
for m in "${MODELS[@]}"; do echo "  revision: ${m} ($(rev_label "$m"))"; done
echo "Work dir: $workDir"
echo

prepare() {
  cd "$workDir"

  echo "Cloning Trezor firmware repository..."
  if ! git clone "$repo" trezor-firmware; then
    no_verdict "failed to clone ${repo}"
  fi

  cd trezor-firmware
  echo "Checking out core/v${normalizedVersion}..."
  if ! git checkout "core/v${normalizedVersion}"; then
    echo -e "${RED}Error: git tag core/v${normalizedVersion} not found (not a released version).${NC}"
    exit "$EXIT_INVALID"
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
        no_verdict "failed to download official firmware: $url"
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

  # Per-run image/container name (revision, edition, version, run id). build-docker.sh names
  # its snapshot image and container CONTAINER_NAME__<tag>, so the run id keeps parallel runs
  # apart and lets cleanup remove exactly this run's images.
  local modelsCsv m buildArgs
  local edition="standard"
  skipFlag="--skip-bitcoinonly"
  if [[ "$firmwareType" == "bitcoin-only" ]]; then edition="bitcoinonly"; skipFlag="--skip-normal"; fi
  export CONTAINER_NAME="trezor-firmware-env-${revTag}-${edition}-${normalizedVersion}-${RUN_ID}.nix"
  local tagRef="core/v${normalizedVersion}"
  SNAPSHOT_NAME="${CONTAINER_NAME}__${tagRef//[^a-zA-Z0-9]/_}"   # same rule as build-docker.sh
  modelsCsv=$(IFS=,; echo "${MODELS[*]}")

  # Only the firmware target, as upstream CI does (.github/workflows/common.yml:
  # --targets 'firmware'). Neither Safe 3 revision has a secmon (no `secmon` key in model.toml).
  # build-docker.sh bind-mounts build/core-<MODEL>{,-bitcoinonly} without creating them;
  # Docker creates bind sources implicitly, rootless podman refuses, so create them first.
  for m in "${MODELS[@]}"; do mkdir -p "build/core-${m}" "build/core-${m}-bitcoinonly"; done
  buildArgs=(--models "$modelsCsv" --targets firmware "$skipFlag")

  # Step 1, environment only (upstream --init-only): Alpine tarball, Nix image, source clone,
  # submodules, uv and cargo dependencies. Downloads only, so a failure is not a verdict.
  echo "Preparing the build environment (downloads only)..."
  if ! ./build-docker.sh "${buildArgs[@]}" --init-only "$tagRef"; then
    no_verdict "build-docker.sh --init-only failed (environment or dependency download)"
  fi

  # Step 2, the build itself (upstream --no-init) in the snapshot from step 1.
  echo "Building ${firmwareType} firmware for ${modelsCsv}..."
  if ! ./build-docker.sh "${buildArgs[@]}" --no-init "$tagRef"; then
    echo -e "${RED}Build failed!${NC}"
    write_results "ftbfs" "${PRODUCT} v${version} (${firmwareType}, ${modelsCsv}): build-docker.sh build failed after the environment and sources were prepared."
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
      no_verdict "unexpected official ${m} firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}, hw_model=${hwModel}); expected TRZV / ${EXPECTED_VH_LEN}B / TRZF / ${m} - refusing to guess the signature offset"
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
      # Full byte diff in the workspace; the results block shows at most 5 lines of it.
      cmp -l "official_${m}.zeroed" "trezor-firmware/build/core-${m}${editionSuffix}/firmware/firmware.bin" \
        > "diff_${m}.txt" 2>&1 || true
    fi
  done
}

# ---- Bootloader -------------------------------------------------------------
# The firmware build does not compile the bootloader: it embeds the committed, signed
# bootloader_<MODEL>.bin. Rebuild that bootloader from its own release tag (core/bl<VERSION>)
# with that tag's build-docker.sh, so the bootloader the firmware installs is checked too.
# Signing adds two things a local build cannot have: the 65-byte signature (sigmask 0x3BF +
# signature 0x3C0) and the code hash at 0x20 (docs/core/misc/boot.md). The signature is zeroed on
# both sides; the committed code hash must equal a hash of OUR built code (T3B1: SHA-256,
# T2B1: BLAKE2s, per upstream models.py), so it is recomputed rather than ignored.
declare -A BL_CODE_HASH_ALG=([T2B1]=blake2s256 [T3B1]=sha256 [T3T1]=sha256)
declare -A BL_VER=() BL_TAG=() BL_COMMIT=() BL_SIGNED_HASH=() BL_BUILT_HASH=() BL_HASHALG=() BL_MATCH=() BL_NOTE=()

check_bootloader() {
  local m="$1" committed="$2" built="$3" size codelen want got alg
  BL_SIGNED_HASH[$m]=$(sha256_of "$committed")
  BL_BUILT_HASH[$m]=$(sha256_of "$built")
  BL_MATCH[$m]=0
  if [[ ! -f "$built" ]]; then BL_NOTE[$m]="no built bootloader"; return 0; fi
  size=$(wc -c < "$committed")
  codelen=$(od -An -tu4 -j12 -N4 "$committed" | tr -d '[:space:]')
  # One code chunk only (header 1 KiB + code <= 127 KiB); otherwise more hash slots are used.
  if [[ "$size" != "$(wc -c < "$built")" || $(( 1024 + codelen )) -ne "$size" || "$codelen" -gt 130048 ]]; then
    BL_NOTE[$m]="size/codelen mismatch (committed ${size} B, codelen ${codelen}, built $(wc -c < "$built") B)"
    return 0
  fi
  cp "$committed" "bl_${m}.committed.cmp"; cp "$built" "bl_${m}.built.cmp"
  for f in "bl_${m}.committed.cmp" "bl_${m}.built.cmp"; do
    dd if=/dev/zero of="$f" bs=1 seek=959 count=65 conv=notrunc 2>/dev/null   # sigmask + signature
    dd if=/dev/zero of="$f" bs=1 seek=32 count=32 conv=notrunc 2>/dev/null    # code hash (checked below)
  done
  if ! cmp -s "bl_${m}.committed.cmp" "bl_${m}.built.cmp"; then
    cmp -l "bl_${m}.committed.cmp" "bl_${m}.built.cmp" > "diff_bootloader_${m}.txt" 2>&1 || true
    BL_NOTE[$m]="$(wc -l < "diff_bootloader_${m}.txt") bytes differ outside the signature and code hash"
    return 0
  fi
  want=$(od -An -tx1 -j32 -N32 "$committed" | tr -d ' \n')
  # Each model's code-hash function, as upstream defines it (python/src/trezorlib/firmware/
  # models.py, *_HASH_PARAMS at core/bl2.1.16): T2B1 BLAKE2s; T3B1 and T3T1 SHA-256.
  alg="${BL_CODE_HASH_ALG[$m]:-}"
  if [[ -z "$alg" ]]; then BL_NOTE[$m]="no known code-hash function for model ${m}"; return 0; fi
  got=$(tail -c +1025 "$built" | openssl dgst "-${alg}" -r | cut -c1-64)
  if [[ "$got" == "$want" ]]; then BL_HASHALG[$m]="$alg"; BL_MATCH[$m]=1; BL_NOTE[$m]="match"; return 0; fi
  BL_NOTE[$m]="code hash at 0x20 (${want}) is not the ${alg} of the built code (${got})"
}

build_bootloaders() {
  cd "$workDir"
  local m committed magic hdr v tag dir cn sn
  local -A cloned=()
  for m in "${MODELS[@]}"; do
    committed="trezor-firmware/core/embed/models/${m}/bootloaders/bootloader_${m}.bin"
    if [[ ! -f "$committed" ]]; then
      BL_MATCH[$m]=0; BL_NOTE[$m]="no committed bootloader_${m}.bin at core/v${normalizedVersion}"; continue
    fi
    magic=$(head -c4 "$committed"); hdr=$(od -An -tu4 -j4 -N4 "$committed" | tr -d '[:space:]')
    v=$(od -An -tu1 -j16 -N3 "$committed" | awk '{print $1"."$2"."$3}')
    if [[ "$magic" != "TRZB" || "$hdr" != "1024" ]]; then
      BL_MATCH[$m]=0; BL_NOTE[$m]="unexpected bootloader header (magic ${magic}, ${hdr} B)"; continue
    fi
    BL_VER[$m]="$v"; tag="core/bl${v}"; BL_TAG[$m]="$tag"
    if ! git -C trezor-firmware rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
      BL_MATCH[$m]=0; BL_NOTE[$m]="no release tag ${tag} for bootloader ${v}"; continue
    fi
    BL_COMMIT[$m]=$(git -C trezor-firmware rev-parse "${tag}^{commit}")
    dir="bl-${v}"
    if [[ -z "${cloned[$v]:-}" ]]; then
      echo "Building bootloader ${v} from ${tag} (${BL_COMMIT[$m]})..."
      git clone -q --depth 1 --branch "$tag" "$repo" "$dir" || no_verdict "failed to clone ${tag}"
      cn="trezor-bl-env-${v//./_}-${RUN_ID}.nix"; sn="${cn}__${tag//[^a-zA-Z0-9]/_}"
      EXTRA_IMAGES+=("$sn" "$cn")
      local blModels; blModels=$(IFS=,; echo "${MODELS[*]}")
      ( cd "$dir" && for x in "${MODELS[@]}"; do mkdir -p "build/core-${x}" "build/core-${x}-bitcoinonly"; done \
        && CONTAINER_NAME="$cn" ./build-docker.sh --models "$blModels" --targets bootloader --skip-bitcoinonly "$tag" ) \
        || no_verdict "bootloader build at ${tag} failed (this tag's build-docker.sh has no download-only step, so network and source failures cannot be told apart; check the log)"
      cloned[$v]=1
    fi
    check_bootloader "$m" "$committed" "${dir}/build/core-${m}/bootloader/bootloader.bin"
    if [[ "${BL_MATCH[$m]}" == "1" ]]; then
      echo -e "${GREEN}Bootloader ${v} (${m}) matches (code hash: ${BL_HASHALG[$m]})${NC}"
    else
      echo -e "${RED}Bootloader ${v} (${m}) does not match: ${BL_NOTE[$m]}${NC}"
    fi
  done
  # A revision is reproducible only if its firmware AND its bootloader match.
  for m in "${MODELS[@]}"; do
    [[ "${BL_MATCH[$m]:-0}" == "1" ]] || verdict="not_reproducible"
  done
}

# ---- Main -------------------------------------------------------------------
echo "Starting ${PRODUCT} verification..."
echo "This may take 45-60 minutes (firmware, then its bootloader)."
echo

prepare
download_official
build_firmware
compare_firmware
build_bootloaders

print_hash_legend() {
  echo
  echo "----- What these hashes mean -----"
  echo "Each revision has its own firmware file and its own results block:"
  echo "T2B1 = Safe 3 rev.A (STM32F427), T3B1 = Safe 3 rev.B (STM32U58x)."
  echo "appHash       SHA-256 of that revision's official firmware exactly as downloaded"
  echo "              from data.trezor.io (signed). THIS is the official hash to publish"
  echo "              for that file."
  echo "zeroedHash    (after End) The official firmware with its 65-byte firmware-header"
  echo "              signature (offset 1471) set to zero. Comparison only; never publish."
  echo "builtHash     (in Diff) SHA-256 of the firmware built from core/v${normalizedVersion}."
  echo "fingerprint   (after End) Trezor's firmware fingerprint of the build (header with"
  echo "              signatures cleared), the value a Trezor shows during a firmware update."
  echo
  echo "MATCH means builtHash == zeroedHash. It does NOT verify Trezor's signature."
  echo "bootloader    (in Diff) SHA-256 of the bootloader built from its core/bl tag, before"
  echo "              signing. The signed committed file's hash is after End; never publish it."
  echo "----------------------------------"
}

# One standard 9-field results block per revision: each revision is a separate official file.
print_results_block() {
  local m="$1" flag blflag n lines=()
  if [[ "${MATCH[$m]}" == "1" ]]; then flag="1 (MATCHES)"; else flag="0 (DOESN'T MATCH)"; fi
  if [[ "${BL_MATCH[$m]:-0}" == "1" ]]; then blflag="1 (MATCHES)"; else blflag="0 (DOESN'T MATCH)"; fi
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${normalizedVersion}"
  echo "apkVersionCode: N/A"
  if [[ "${MATCH[$m]}" == "1" && "${BL_MATCH[$m]:-0}" == "1" ]]; then
    echo "verdict:        reproducible"
  else
    echo "verdict:        not_reproducible"
  fi
  echo "appHash:        ${OFFICIAL_HASH[$m]}"
  echo "commit:         ${commit}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo
  echo "Diff:"
  echo "BUILDS MATCH BINARIES"
  echo "trezor-${m,,}-${normalizedVersion}${editionSuffix}.bin - ${m}-${firmwareType} - ${BUILT_HASH[$m]} - ${flag}"
  echo "bootloader_${m}.bin ${BL_VER[$m]:-?} - ${m} - ${BL_BUILT_HASH[$m]:-N/A} - ${blflag}"
  if [[ -s "$workDir/diff_${m}.txt" ]]; then
    n=$(wc -l < "$workDir/diff_${m}.txt")
    mapfile -t -n 5 lines < "$workDir/diff_${m}.txt"
    echo "First differing bytes (offset zeroed-official built), ${n} lines in total:"
    printf '%s\n' "${lines[@]}"
    echo "Full diff: $workDir/diff_${m}.txt"
  fi
  echo
  echo "Revision, tag (and its signature):"
  echo "Tag type: ${tagType} (core/v${normalizedVersion} -> ${commit})"
  echo "[INFO] Tag signature not verified by this script."
  echo "===== End Results ====="
}

print_hash_legend
for m in "${MODELS[@]}"; do
  echo
  echo "### ${m} ($(rev_label "$m"))"
  print_results_block "$m"
  echo "type:           ${firmwareType}"
  echo "revision:       ${m} ($(rev_label "$m"))"
  echo "zeroedHash:     ${ZEROED_HASH[$m]}  (signature zeroed at offset ${SEEK[$m]}; never publish)"
  echo "fingerprint:    ${FINGERPRINT[$m]}  (Trezor firmware fingerprint of the build)"
  echo "bootloader:     ${BL_VER[$m]:-?} from ${BL_TAG[$m]:-?} (commit ${BL_COMMIT[$m]:-?}): ${BL_NOTE[$m]:-not checked}"
  echo "bootloaderSigned: ${BL_SIGNED_HASH[$m]:-N/A}  (committed signed file; never publish)"
  [[ -n "${BL_HASHALG[$m]:-}" ]] && echo "bootloaderCodeHash: committed 0x20 field = ${BL_HASHALG[$m]} of the built code"
  if [[ -s "$workDir/diff_bootloader_${m}.txt" ]]; then
    echo "bootloaderDiff: $workDir/diff_bootloader_${m}.txt (first lines below)"
    mapfile -t -n 5 bl_lines < "$workDir/diff_bootloader_${m}.txt"; printf '  %s\n' "${bl_lines[@]}"
  fi
done
echo
echo "Bootloader note: this script built the firmware from core/v${normalizedVersion} and the"
echo "bootloader it embeds from that bootloader's own release tag, then filled in the gaps that"
echo "only Trezor's signing can create (signature zeroed; code hash recomputed from our build)."
echo "A reproducible verdict means both the firmware and the bootloader matched."
echo
echo "Overall verdict (all revisions): ${verdict}"
echo

summary=""
for m in "${MODELS[@]}"; do
  if [[ "${MATCH[$m]}" == "1" ]]; then r="firmware match"; else r="firmware built ${BUILT_HASH[$m]} != zeroed ${ZEROED_HASH[$m]}"; fi
  r="${r}, bootloader ${BL_VER[$m]:-?} (${BL_TAG[$m]:-?}): ${BL_NOTE[$m]:-not checked}"
  summary="${summary}${m}: ${r}; "
done

if [[ "$verdict" == "reproducible" ]]; then
  write_results "reproducible" "${PRODUCT} v${version} (${firmwareType}; ${MODELS[*]}) reproducible from the tagged repository via build-docker.sh at core/v${normalizedVersion} (commit ${commit}); ${summary}official firmware-header signature (offset 1471, 65B) zeroed before SHA-256 comparison."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_OK"
else
  write_results "not_reproducible" "${PRODUCT} v${version} (${firmwareType}; ${MODELS[*]}) not reproducible (firmware and bootloader must both match): ${summary}firmware signature zeroed at offset 1471, 65B."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_FAIL"
fi
