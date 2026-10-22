#!/bin/bash
# trezorsafe7_build.sh - Trezor Safe 7 (T3W1) firmware reproducible build verification
# Version: v2.3.0 · Organization: WalletScrutiny.com · License: MIT
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-22
# Disclaimer: for reproducible-build verification only; no warranty; runs containers and
#   downloads source; you are responsible for lawful use. Read the script before running it.
# Steps: build the firmware from core/v<version> (build-docker.sh) and compare it with the official
#   file, its 65-byte signature field zeroed; rebuild the three signed binaries it embeds (bootloader,
#   secmon, nRF BLE app) from their own release tags and compare outside their signature areas.
# Reproducible only if all four match. Exit 0 reproducible, 1 not/ftbfs/failure, 2 invalid, 130 stop.
# Host needs: docker or podman, git, wget, sha256sum, od, dd, awk, openssl. History: changelog.

set -eE

# ---- Globals (paths captured before any cd) ---------------------------------
SCRIPT_VERSION="v2.3.0"
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
EXTRA_IMAGES=()   # embedded-binary build images of this run, removed at exit
repo="https://github.com/trezor/trezor-firmware.git"
firmwareType="standard"
version=""
BINARY_PATH=""
ARCH=""
REVISION_ARG=""

PRODUCT="Trezor Safe 7"
APP_ID="trezorSafe7"
ALL_MODELS=(T3W1)
EXPECTED_VH_LEN=1024   # Safe 7 vendor header size (confirmed on the 2.13.0 official file)
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
    T3W1) echo "Safe 7" ;;
    *)    echo "unknown model" ;;
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
       trezorsafe7_build.sh - verify Trezor Safe 7 (T3W1) firmware

SYNOPSIS
       trezorsafe7_build.sh --version VERSION [--type TYPE] [--binary PATH]
                            [--arch ARCH]

DESCRIPTION
       The Safe 7 is Trezor model T3W1.

       --version   Firmware version to verify, e.g. "2.12.5" (required)
       --type      Firmware type. Accepted: standard|universal|multi  or
                   bitcoin-only|btc-only|btconly  (default: standard)
       --binary    Official firmware .bin, or a directory holding
                   trezor-t3w1-VERSION[-bitcoinonly].bin. Its model is checked from the
                   firmware header. Optional; downloaded if omitted.
       --arch      Accepted for ABS compatibility; unused

EXAMPLES
       trezorsafe7_build.sh --version 2.13.0 --type btc-only
       trezorsafe7_build.sh --version 2.13.0 --type universal'
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

# ---- --revision (Safe 3 option; the Safe 7 has one model) ------------------
revisionModel=""
[[ -z "$REVISION_ARG" ]] || echo -e "${YELLOW}[WARN] Ignoring --revision '$REVISION_ARG': the Safe 7 has one model (T3W1)${NC}"

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
    if [[ " ${ALL_MODELS[*]} " != *" ${fileModel} "* ]]; then
      echo -e "${RED}Error: --binary is not ${PRODUCT} firmware (hw_model '${fileModel}', expected ${ALL_MODELS[*]})${NC}"
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

# Model tag for resource names.
revTag="${MODELS[0],,}"

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
wd="${CALLER_DIR}/trezorSafe7_verification_${version}_${firmwareType}_${revTag}_${RUN_ID}"
if ! mkdir -- "$wd"; then
  echo -e "${RED}Error: work directory already exists or cannot be created: $wd${NC}"
  exit "$EXIT_INVALID"
fi
workDir="$wd"

echo
echo "Verifying ${PRODUCT} firmware v$version ($firmwareType)"
for m in "${MODELS[@]}"; do echo "  model: ${m} ($(rev_label "$m"))"; done
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
  # (as of core/v2.13.0); no HW_REVISION override is passed, matching
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
  # --targets 'firmware'). The production firmware embeds the committed signed secmon, bootloader and
  # nRF app instead of building them (checked separately below); the default list
  # fails on it since core/v2.12.2 (trezor-firmware#7775).
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

    # Fail closed on header shape: "TRZV" (0x54525a56), a 1024-byte vendor header (bytes 4-7,
    # uint32 LE), "TRZF" (0x54525a46) right after it, and hw_model (firmware header +24)
    # equal to this revision. The 65-byte signature (sigmask 1B + signature 64B) sits 959
    # bytes into the firmware header -> offset 1024 + 959 = 1983.
    read -r magicHex vhLen fwMagicHex hwModel <<< "$(read_header "official_${m}.bin")"
    if [[ "$magicHex" != "54525a56" || "$vhLen" != "$EXPECTED_VH_LEN" || "$fwMagicHex" != "54525a46" || "$hwModel" != "$m" ]]; then
      no_verdict "unexpected official ${m} firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}, hw_model=${hwModel}); expected TRZV / ${EXPECTED_VH_LEN}B / TRZF / ${m} - refusing to guess the signature offset"
    fi
    seekSize=$(( vhLen + SIG_INNER ))   # 1024 + 959 = 1983
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

# ---- Embedded binaries ------------------------------------------------------
# The production firmware does not compile three components; it embeds signed binaries committed to
# the repository. Each is rebuilt from its own release tag with that tag's build-docker.sh and compared
# outside the areas only Trezor's signing can fill:
#   bootloader  bootloaders/bootloader_T3W1.bin  TRZQ header: zero [auth_size, header_size) (PQ/EC
#               signatures, Merkle proof; core/embed/sec/image/inc/sec/boot_header.h). Tag core/bl<version>.
#   secmon      secmon/secmon.bin  TSEC header: zero the 65-byte sigmask + signature at hdrlen-65.
#               Tag: the secmon/* tag on the commit named in "Built from <commit>" (git log of the file).
#   ble         trezor-ble.bin  MCUboot image: zero the two 64-byte signature TLVs (0x00A0, 0x00A1) that
#               nordic/trezor/scripts/insert_signatures.py appends. Tag nordic/trezor-ble/v<version>.
PARTS=(bootloader secmon ble)
declare -A P_FILE=([bootloader]="bootloaders/bootloader_T3W1.bin" [secmon]="secmon/secmon.bin" [ble]="trezor-ble.bin")
declare -A P_VER=() P_TAG=() P_COMMIT=() P_SIGNED=() P_BUILT=() P_MATCH=() P_NOTE=()

u16() { od -An -tu2 -j"$2" -N2 "$1" | tr -d '[:space:]'; }
u32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d '[:space:]'; }
zero() { dd if=/dev/zero of="$1" bs=1 seek="$2" count="$3" conv=notrunc 2>/dev/null; }

# Zero a copy's signature areas in place; prints nothing, returns 1 if the layout is not as expected.
zero_sig_areas() {
  local part="$1" f="$2" size hs as cs hl off magic tot end t l
  size=$(wc -c < "$f")
  case "$part" in
    bootloader)
      [[ "$(head -c4 "$f")" == "TRZQ" ]] || return 1
      hs=$(u32 "$f" 28); as=$(u32 "$f" 32); cs=$(u32 "$f" 36)
      (( hs + cs == size && as < hs )) || return 1
      zero "$f" "$as" $(( hs - as )) ;;
    secmon)
      [[ "$(head -c4 "$f")" == "TSEC" ]] || return 1
      hl=$(u32 "$f" 4); (( hl > 65 && hl < size )) || return 1
      zero "$f" $(( hl - 65 )) 65 ;;
    ble)
      [[ "$(od -An -tx4 -N4 "$f" | tr -d '[:space:]')" == "96f3b83d" ]] || return 1
      off=$(( $(u16 "$f" 8) + $(u32 "$f" 12) ))
      magic=$(u16 "$f" "$off")
      if [[ "$magic" == "26888" ]]; then off=$(( off + $(u16 "$f" $(( off + 2 ))) )); magic=$(u16 "$f" "$off"); fi
      [[ "$magic" == "26887" ]] || return 1   # 0x6907, unprotected TLV area
      tot=$(u16 "$f" $(( off + 2 ))); end=$(( off + tot )); off=$(( off + 4 ))
      local found=0
      while (( off + 4 <= end )); do
        t=$(u16 "$f" "$off"); l=$(u16 "$f" $(( off + 2 )))
        if (( (t == 160 || t == 161) && l == 64 )); then zero "$f" $(( off + 4 )) 64; found=$(( found + 1 )); fi
        off=$(( off + 4 + l ))
      done
      (( found == 2 && end == size )) || return 1 ;;
  esac
}

part_source() {   # sets P_VER and P_TAG for a part from the committed file (or its git history)
  local part="$1" f="$2" sha
  case "$part" in
    bootloader) P_VER[$part]=$(od -An -tu1 -j12 -N3 "$f" | awk '{print $1"."$2"."$3}'); P_TAG[$part]="core/bl${P_VER[$part]}" ;;
    secmon)
      sha=$(git -C trezor-firmware log -1 --format=%B "core/v${normalizedVersion}" -- "core/embed/models/T3W1/${P_FILE[$part]}" \
            | awk '/Built from/{print $3; exit}' | tr -d '.')
      [[ -n "$sha" ]] && P_TAG[$part]=$(git -C trezor-firmware tag --points-at "$sha" 'secmon/*' | head -1)
      P_VER[$part]="${P_TAG[$part]#secmon/v}" ;;
    ble) P_VER[$part]="$(od -An -tu1 -j20 -N2 "$f" | awk '{print $1"."$2}').$(u16 "$f" 22)"; P_TAG[$part]="nordic/trezor-ble/v${P_VER[$part]}" ;;
  esac
}

build_parts() {
  cd "$workDir"
  local part committed dir cn built args
  for part in "${PARTS[@]}"; do
    committed="trezor-firmware/core/embed/models/T3W1/${P_FILE[$part]}"
    P_MATCH[$part]=0
    if [[ ! -f "$committed" ]]; then P_NOTE[$part]="no committed ${P_FILE[$part]} at core/v${normalizedVersion}"; continue; fi
    P_SIGNED[$part]=$(sha256_of "$committed")
    part_source "$part" "$committed"
    if [[ -z "${P_TAG[$part]:-}" ]] || ! git -C trezor-firmware rev-parse -q --verify "refs/tags/${P_TAG[$part]}" >/dev/null; then
      P_NOTE[$part]="no release tag ${P_TAG[$part]:-found} for this ${part}"; continue
    fi
    P_COMMIT[$part]=$(git -C trezor-firmware rev-parse "${P_TAG[$part]}^{commit}")
    echo "Building ${part} ${P_VER[$part]} from ${P_TAG[$part]} (${P_COMMIT[$part]})..."
    dir="src-${part}"; cn="trezor-${part}-env-${RUN_ID}.nix"
    EXTRA_IMAGES+=("${cn}__${P_TAG[$part]//[^a-zA-Z0-9]/_}" "$cn")
    git clone -q --depth 1 --branch "${P_TAG[$part]}" "$repo" "$dir" || no_verdict "failed to clone ${P_TAG[$part]}"
    if [[ "$part" == "ble" ]]; then
      args=(--models T3W1 --skip-normal --skip-bitcoinonly --nrf); built="${dir}/build/nrf/firmware/nrf-firmware.bin"
    else
      args=(--models T3W1 --targets "$part" --skip-bitcoinonly); built="${dir}/build/core-T3W1/${part}/${part}.bin"
    fi
    ( cd "$dir" && mkdir -p build/core-T3W1 build/core-T3W1-bitcoinonly build/nrf \
      && CONTAINER_NAME="$cn" ./build-docker.sh "${args[@]}" "${P_TAG[$part]}" ) \
      || no_verdict "${part} build at ${P_TAG[$part]} failed (that tag's build-docker.sh has no download-only step, so network and source failures cannot be told apart; check the log)"
    P_BUILT[$part]=$(sha256_of "$built")
    if [[ ! -f "$built" ]]; then P_NOTE[$part]="build produced no ${built##*/}"; continue; fi
    cp "$committed" "${part}.committed.cmp"; cp "$built" "${part}.built.cmp"
    if [[ "$(wc -c < "$committed")" != "$(wc -c < "$built")" ]] \
       || ! zero_sig_areas "$part" "${part}.committed.cmp" || ! zero_sig_areas "$part" "${part}.built.cmp"; then
      P_NOTE[$part]="unexpected size or header layout (refusing to guess the signature area)"; continue
    fi
    if cmp -s "${part}.committed.cmp" "${part}.built.cmp"; then
      P_MATCH[$part]=1; P_NOTE[$part]="match outside the signature area"
      echo -e "${GREEN}${part} ${P_VER[$part]} matches${NC}"
    else
      cmp -l "${part}.committed.cmp" "${part}.built.cmp" > "diff_${part}.txt" 2>&1 || true
      P_NOTE[$part]="$(wc -l < "diff_${part}.txt") bytes differ outside the signature area"
      echo -e "${RED}${part} ${P_VER[$part]} does not match: ${P_NOTE[$part]}${NC}"
    fi
  done
  # Reproducible only if the firmware AND every embedded binary match.
  for part in "${PARTS[@]}"; do [[ "${P_MATCH[$part]}" == "1" ]] || verdict="not_reproducible"; done
}

# ---- Main -------------------------------------------------------------------
echo "Starting ${PRODUCT} verification..."
echo "This may take 1.5-2 hours (firmware, then bootloader, secmon and the nRF BLE app)."
echo

prepare
download_official
build_firmware
compare_firmware
build_parts

print_hash_legend() {
  echo
  echo "----- What these hashes mean -----"
  echo "Safe 7 = Trezor model T3W1."
  echo "appHash       SHA-256 of the official firmware exactly as downloaded"
  echo "              from data.trezor.io (signed). THIS is the official hash to publish"
  echo "              for that file."
  echo "zeroedHash    (after End) The official firmware with its 65-byte firmware-header"
  echo "              signature (offset 1983) set to zero. Comparison only; never publish."
  echo "builtHash     (in Diff) SHA-256 of the firmware built from core/v${normalizedVersion}."
  echo "fingerprint   (after End) Trezor's firmware fingerprint of the build (header with"
  echo "              signatures cleared), the value a Trezor shows during a firmware update."
  echo
  echo "MATCH means builtHash == zeroedHash. It does NOT verify Trezor's signature."
  echo "bootloader / secmon / trezor-ble (in Diff) SHA-256 of each embedded binary built from its own"
  echo "              release tag, before signing. Signed committed hashes are after End; never publish."
  echo "----------------------------------"
}

# One standard 9-field results block per revision: each revision is a separate official file.
print_results_block() {
  local m="$1" flag n lines=() part
  if [[ "${MATCH[$m]}" == "1" ]]; then flag="1 (MATCHES)"; else flag="0 (DOESN'T MATCH)"; fi
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${normalizedVersion}"
  echo "apkVersionCode: N/A"
  if [[ "$verdict" == "reproducible" ]]; then
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
  for part in "${PARTS[@]}"; do
    if [[ "${P_MATCH[$part]}" == "1" ]]; then n="1 (MATCHES)"; else n="0 (DOESN'T MATCH)"; fi
    echo "${P_FILE[$part]##*/} ${P_VER[$part]:-?} - ${m} - ${P_BUILT[$part]:-N/A} - ${n}"
  done
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
  for part in "${PARTS[@]}"; do
    echo "${part}: ${P_VER[$part]:-?} from ${P_TAG[$part]:-?} (commit ${P_COMMIT[$part]:-?}): ${P_NOTE[$part]:-not checked}"
    echo "  signed committed ${P_FILE[$part]##*/}: ${P_SIGNED[$part]:-N/A}  (never publish)"
    if [[ -s "$workDir/diff_${part}.txt" ]]; then
      mapfile -t -n 5 bl_lines < "$workDir/diff_${part}.txt"; printf '  %s\n' "${bl_lines[@]}"
      echo "  full diff: $workDir/diff_${part}.txt"
    fi
  done
done
echo
echo "Embedded binaries note: this script built the firmware from core/v${normalizedVersion}, then the"
echo "bootloader, secmon and nRF BLE app it embeds, each from its own release tag, and compared them"
echo "outside the areas only Trezor's signing can fill (signatures and proofs zeroed on both sides)."
echo "A reproducible verdict means the firmware and all three embedded binaries matched."
echo
echo "Overall verdict (all revisions): ${verdict}"
echo

summary=""
for m in "${MODELS[@]}"; do
  if [[ "${MATCH[$m]}" == "1" ]]; then r="firmware match"; else r="firmware built ${BUILT_HASH[$m]} != zeroed ${ZEROED_HASH[$m]}"; fi
  for part in "${PARTS[@]}"; do r="${r}, ${part} ${P_VER[$part]:-?} (${P_TAG[$part]:-?}): ${P_NOTE[$part]:-not checked}"; done
  summary="${summary}${m}: ${r}; "
done

if [[ "$verdict" == "reproducible" ]]; then
  write_results "reproducible" "${PRODUCT} v${version} (${firmwareType}; ${MODELS[*]}) reproducible from the tagged repository via build-docker.sh at core/v${normalizedVersion} (commit ${commit}); ${summary}official firmware-header signature (offset 1983, 65B) zeroed before SHA-256 comparison."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_OK"
else
  write_results "not_reproducible" "${PRODUCT} v${version} (${firmwareType}; ${MODELS[*]}) not reproducible (firmware and all embedded binaries must match): ${summary}firmware signature zeroed at offset 1983, 65B."
  echo
  echo "${PRODUCT} verification finished!"
  exit "$EXIT_FAIL"
fi
