#!/bin/bash
# cypherockx1-v4.1.0_build.sh - WalletScrutiny verification script for Cypherock X1 firmware
# Version: v4.1.0
# Organization: WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-28
# Usage: cypherockx1-v4.1.0_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]
# Project: https://github.com/Cypherock/x1_wallet_firmware
#
# TECHNICAL DISCLAIMER: This script is provided for reproducible-build verification only, with no
# warranty of any kind. It runs containers, downloads source code and firmware, and builds firmware.
# Review every operation before running it.
# LEGAL DISCLAIMER: Intended for legitimate verification and research. Users are responsible for
# complying with applicable laws. The authors accept no liability for misuse.
#
# SCRIPT SUMMARY:
# - Gets the official firmware for the requested variant: the GitHub release asset, or --binary.
# - Clones the release tag with submodules inside a pinned git container.
# - Builds inside the builder image that upstream CI names at the tag (v0.0.0 or v1.0.0, each pinned
#   by digest here), with the flags and build directory of that CI
#   (.github/workflows/containerized-build.yml): Main, Release, Device, VENDOR=Cypherock,
#   BTC_ONLY per variant, SIGN_BINARY=OFF, Ninja.
# - Compares SHA-256 of the whole built file with the whole official file (the release .bin is
#   unsigned, so nothing is stripped) and writes COMPARISON_RESULTS.yaml next to this script.
# Host requirements: docker or podman. Nothing is mounted into containers; files are copied out.
# Exit codes: 0 reproducible; 1 not_reproducible or ftbfs (YAML written), or a download/pull failure
# (no YAML); 2 invalid input/environment or an unknown builder image (no YAML).

set -Eeo pipefail

# ---- Globals ------------------------------------------------------------------
SCRIPT_VERSION="v4.1.0"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_SHA256=""
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

APP_ID="cypherockx1"
REPO_URL="https://github.com/Cypherock/x1_wallet_firmware.git"
RELEASE_BASE="https://github.com/Cypherock/x1_wallet_firmware/releases/download"

# Pinned images. The tag is kept for readability; the digest is what gets pulled.
# Builder: the one upstream CI names at the tag (containerized-build.yml). v0.0.0 (Alpine, apk gcc)
# up to v0.6.3331; v1.0.0 (Ubuntu 22.04, Arm GNU 10.3-2021.10, CMake 3.25.3) from v0.6.3332.
# Docker Hub index digests as of 2026-10-28 (both last pushed Feb 2024).
BUILDER_V0="docker.io/cypherock/x1-firmware-builder:v0.0.0@sha256:93ec18baf04065e79d2a138368e761496721e58129cfdfe856aafdb05984ac05"
BUILDER_V1="docker.io/cypherock/x1-firmware-builder:v1.0.0@sha256:572aaa269791fdfe955911b19d1894b2f30251e12f6d73d2d8cfde7004384145"
BUILDER_REF=""
BUILDER_IMAGE=""
GIT_IMAGE="docker.io/alpine/git:v2.54.0@sha256:6f3b5029566da8e90b24945933dcd806be866b64b1e706f51828bf84faccf21b"
CURL_IMAGE="docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
# Upstream CI builds on ubuntu-latest (amd64). Pin it so other hosts do not pick another manifest.
PLATFORM="linux/amd64"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

version=""
firmwareType=""
ARCH=""
binaryPath=""
CONTAINER_CMD=""
workDir=""
SRC_IMAGE=""
BUILD_IMAGE=""
EXTRACT_CTR=""
commit=""
tagType=""
tagSig=""
commitSig=""
ciBuilder=""
buildDirForm=""
BUILD_DIR=""
srcImageMade=0
buildImageMade=0
officialSource=""
officialHash=""
builtHash=""
verdict=""
NOTES=()

log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '%b[WARN] %s%b\n' "$YELLOW" "$*" "$NC"; }
log_error() { printf '%b[ERROR] %s%b\n' "$RED" "$*" "$NC" >&2; }

sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

# ---- Disclaimer -----------------------------------------------------------------
echo -e "${YELLOW}"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Running this script will run Docker or Podman"
echo "containers, download source code and official firmware, and perform builds"
echo "that may consume significant system resources (CPU, memory, disk space)."
echo "It does not connect to, flash or modify any hardware device."
echo "Use at your own risk and ensure you understand what the script does before"
echo "execution."
echo "=============================================================================="
echo -e "${NC}"
sleep 3

# ---- Self-identification (first action; ties this run to the script bytes) ------
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
echo "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "         sha256: ${SCRIPT_SHA256}"
echo

# A YAML from an earlier run must never be read as this run's verdict.
rm -f -- "$RESULTS_FILE"

if [[ "$(id -u)" -eq 0 ]]; then
  log_error "Do not run this script as root. Run it as a normal user with access to docker or podman."
  exit "$EXIT_INVALID"
fi

usage() {
  cat <<'EOF'
NAME
    cypherockx1_build.sh - verify that Cypherock X1 firmware builds reproducibly from source

SYNOPSIS
    cypherockx1_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]

OPTIONS
    --version VERSION  Firmware version without the "v" prefix, e.g. 0.6.3331 (required).
    --type TYPE        Firmware variant (default: multi):
                         multi    Cypherock-Main.bin      aliases: universal, standard, main, multicoin
                         bitcoin  Cypherock-Main-BTC.bin  aliases: btc, btc-only, bitcoin-only, btconly
    --binary PATH      Official firmware file, or a directory containing the file for the chosen
                       variant. Skips the download.
    --arch ARCH        Accepted for build-server compatibility; the firmware has a single target.
    --apk PATH         Accepted and ignored (Android scripts only).
    -h, --help         Show this help.

REQUIREMENTS
    docker or podman, run as a normal user, with network access and disk space for the images.
    podman is used when both work; set WS_CONTAINER_CMD=docker to force docker.
    The firmware build usually takes tens of minutes; the first run also pulls the builder image.

EXAMPLES
    cypherockx1_build.sh --version 0.6.3341
    cypherockx1_build.sh --version 0.6.3341 --type bitcoin
    cypherockx1_build.sh --version 0.6.3341 --type bitcoin --binary ~/Downloads/Cypherock-Main-BTC.bin

OUTPUT
    COMPARISON_RESULTS.yaml next to this script, and a work directory in the current directory
    holding the official and built firmware for inspection.

EXIT CODES
    0 reproducible
    1 not_reproducible or ftbfs (COMPARISON_RESULTS.yaml written), or a download/pull failure (no verdict)
    2 invalid input or environment, or an unknown builder image at the tag (no verdict)
EOF
}

require_value() {
  if [[ -z "${2:-}" || "$2" == --* ]]; then
    log_error "Option $1 needs a value."
    usage
    exit "$EXIT_INVALID"
  fi
}

# ---- Arguments (unknown arguments warn and continue) -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) require_value "$1" "${2:-}"; version="$2"; shift 2 ;;
    --type)    require_value "$1" "${2:-}"; firmwareType="$2"; shift 2 ;;
    --arch)    require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
    --binary)  require_value "$1" "${2:-}"; binaryPath="$2"; shift 2 ;;
    --apk)
      log_warn "--apk is for Android scripts and is ignored here (use --binary)."
      if [[ -n "${2:-}" && "$2" != --* ]]; then shift 2; else shift; fi ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    *)         log_warn "Ignoring unknown argument: $1"; shift ;;
  esac
done

# ---- Validation -------------------------------------------------------------------
if [[ -z "$version" ]]; then
  log_error "--version is required."
  usage
  exit "$EXIT_INVALID"
fi
# Digits and dots only. The version becomes part of directory, image and git tag names, so this
# also blocks path traversal and shell metacharacters.
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
  log_error "Invalid --version '${version}' (expected digits and dots, e.g. 0.6.3331)."
  exit "$EXIT_INVALID"
fi

case "${firmwareType,,}" in
  ""|multi|multicoin|multi-coin|multi_coin|universal|standard|main)
    firmwareType="multi";   COIN_VARIANT="MULTI_COIN"; BTC_ONLY_FLAG="OFF"; ARTIFACT="Cypherock-Main.bin" ;;
  bitcoin|btc|btc-only|btc_only|bitcoin-only|btconly|bitcoinonly)
    firmwareType="bitcoin"; COIN_VARIANT="BTC_ONLY";   BTC_ONLY_FLAG="ON";  ARTIFACT="Cypherock-Main-BTC.bin" ;;
  *)
    log_error "Invalid --type '${firmwareType}' (use multi or bitcoin)."
    exit "$EXIT_INVALID" ;;
esac

if [[ -n "$ARCH" ]]; then
  if [[ ! "$ARCH" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
    log_error "Invalid --arch '${ARCH}'."
    exit "$EXIT_INVALID"
  fi
  log_info "--arch ${ARCH} accepted; the firmware has a single target (ARM Cortex-M)."
fi
archLabel="${ARCH:-arm}"

if [[ -n "$binaryPath" ]]; then
  [[ "$binaryPath" != /* ]] && binaryPath="${PWD}/${binaryPath}"
  if [[ -d "$binaryPath" ]]; then
    if [[ -f "${binaryPath}/${ARTIFACT}" ]]; then
      binaryPath="${binaryPath}/${ARTIFACT}"
    else
      log_error "Directory ${binaryPath} does not contain ${ARTIFACT} (needed for --type ${firmwareType})."
      exit "$EXIT_INVALID"
    fi
  fi
  if [[ ! -f "$binaryPath" ]]; then
    log_error "--binary file not found: ${binaryPath}"
    exit "$EXIT_INVALID"
  fi
  if [[ "$(basename "$binaryPath")" != "$ARTIFACT" ]]; then
    log_warn "--binary file is named $(basename "$binaryPath"); --type ${firmwareType} expects ${ARTIFACT}."
  fi
fi

# ---- Container runtime --------------------------------------------------------------
if [[ -n "${WS_CONTAINER_CMD:-}" ]]; then
  case "$WS_CONTAINER_CMD" in
    docker|podman) CONTAINER_CMD="$WS_CONTAINER_CMD" ;;
    *) log_error "WS_CONTAINER_CMD must be docker or podman."; exit "$EXIT_INVALID" ;;
  esac
  if ! $CONTAINER_CMD info >/dev/null 2>&1; then
    log_error "${CONTAINER_CMD} is not working for this user."
    exit "$EXIT_INVALID"
  fi
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
else
  log_error "Neither podman nor docker is installed and working for this user."
  exit "$EXIT_INVALID"
fi
log_info "Container runtime: ${CONTAINER_CMD}"

# ---- Results file ---------------------------------------------------------------------
# notes lines only ever carry validated values, hex hashes and fixed text.
write_results() {
  local status="$1" line
  shift
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${status}"
    echo "notes: |"
    for line in "$@"; do
      echo "  ${line}"
    done
  } > "$RESULTS_FILE"
  log_info "Results written to: ${RESULTS_FILE}"
}

fail_ftbfs() {
  log_error "$1"
  write_results "ftbfs" "${NOTES[@]}" "Result: ftbfs. $1"
  exit "$EXIT_FAIL"
}

# A failure that says nothing about the source (network, registry): no YAML, so ABS publishes nothing.
fail_no_verdict() {
  log_error "$1"
  log_error "No verdict: this failure is not a build result. Fix the cause and run again."
  trap - ERR
  rm -f -- "$RESULTS_FILE"
  exit "$EXIT_FAIL"
}

# shellcheck disable=SC2329  # invoked through the ERR trap
on_unexpected_error() {
  local rc=$? line="${BASH_LINENO[0]}"
  trap - ERR
  # Build steps run under "if !", so they never reach this trap: anything here is not a build result.
  fail_no_verdict "Unexpected error (exit ${rc}) near line ${line} before a verdict was reached."
}

# Removes only what this run created. Pulled base images are left for reuse.
# shellcheck disable=SC2329  # invoked through the EXIT trap
cleanup() {
  [[ -n "$CONTAINER_CMD" ]] || return 0
  if [[ -n "$EXTRACT_CTR" ]]; then
    $CONTAINER_CMD rm -f "$EXTRACT_CTR" >/dev/null 2>&1 || true
  fi
  if [[ "$buildImageMade" -eq 1 ]]; then
    $CONTAINER_CMD rmi -f "$BUILD_IMAGE" >/dev/null 2>&1 || true
  fi
  if [[ "$srcImageMade" -eq 1 ]]; then
    $CONTAINER_CMD rmi -f "$SRC_IMAGE" >/dev/null 2>&1 || true
  fi
}

hash_in_container() {
  $CONTAINER_CMD run --rm -i --platform "$PLATFORM" --entrypoint sha256sum "$CURL_IMAGE" < "$1" | awk '{print $1}'
}

# ---- Work area (fresh per run; nothing outside it is ever deleted) ----------------------
runId="$(date +%s)-$$"
runTag="${version}-${firmwareType}-${archLabel}-${runId}"
workDir="$(pwd -P)/cypherockx1_verification_${version}_${firmwareType}_${archLabel}_${runId}"
SRC_IMAGE="ws-cypherockx1-src:${runTag}"
BUILD_IMAGE="ws-cypherockx1-build:${runTag}"
officialFile="${workDir}/output/official-${ARTIFACT}"
builtFile="${workDir}/output/built-${ARTIFACT}"

trap cleanup EXIT
trap on_unexpected_error ERR

NOTES=(
  "Cypherock X1 firmware v${version}, ${firmwareType} variant (${ARTIFACT}), git tag v${version}."
  "Comparison: SHA-256 of the whole built file against the whole official file. The release .bin is unsigned, so nothing is stripped."
)

# Exclusive create: an existing directory belongs to another run, so stop without a verdict.
if ! mkdir -- "$workDir"; then
  log_error "Work directory already exists or cannot be created: ${workDir}"
  exit "$EXIT_INVALID"
fi
mkdir -- "${workDir}/output" "${workDir}/ctx-source" "${workDir}/ctx-build"
log_info "Work directory: ${workDir}"

echo
echo "Verifying Cypherock X1 firmware v${version} (${firmwareType}, ${ARTIFACT})"
echo

# ---- Step 1: official firmware ---------------------------------------------------------
# The curl image also hashes both files, so pull it even with --binary.
$CONTAINER_CMD pull --platform "$PLATFORM" "$CURL_IMAGE" >/dev/null \
  || fail_no_verdict "Could not pull ${CURL_IMAGE}."
if [[ -n "$binaryPath" ]]; then
  log_info "Using provided official firmware: ${binaryPath}"
  cp -- "$binaryPath" "$officialFile"
  safeName="$(basename "$binaryPath")"
  officialSource="provided file ${safeName//[^A-Za-z0-9._-]/_} (--binary)"
else
  url="${RELEASE_BASE}/v${version}/${ARTIFACT}"
  log_info "Downloading official firmware: ${url}"
  if ! $CONTAINER_CMD run --rm --platform "$PLATFORM" "$CURL_IMAGE" -fsSL --retry 3 --retry-delay 5 "$url" > "$officialFile"; then
    rm -f -- "$officialFile"
    fail_no_verdict "Official firmware not downloadable from ${url} (no published release asset for this version and variant, or a network error). No build was attempted."
  fi
  officialSource="GitHub release asset ${url}"
fi
[[ -s "$officialFile" ]] || fail_no_verdict "Official firmware file is empty."
NOTES+=("Official firmware: ${officialSource}.")

# ---- Step 2: clone the tag inside a container ------------------------------------------
{
printf 'ARG GIT_IMAGE=%s\n' "$GIT_IMAGE"
cat <<'EOF'
FROM ${GIT_IMAGE}
ARG VERSION_TAG
ARG REPO_URL
RUN set -eu; \
    git clone --branch "$VERSION_TAG" --depth 1 --recurse-submodules "$REPO_URL" /src; \
    mkdir /ws_meta; \
    cd /src; \
    git rev-parse HEAD > /ws_meta/commit; \
    t="$(git cat-file -t "refs/tags/$VERSION_TAG")"; \
    echo "$t" > /ws_meta/tag_type; \
    if [ "$t" != tag ]; then echo n/a; \
    elif git cat-file -p "refs/tags/$VERSION_TAG" | grep -qE 'BEGIN (PGP|SSH) SIGNATURE'; then echo present; \
    else echo absent; fi > /ws_meta/tag_signature; \
    if git cat-file -p HEAD | grep -q '^gpgsig'; then echo present; else echo absent; fi > /ws_meta/commit_signature; \
    { grep -o -m1 'cypherock/x1-firmware-builder:[A-Za-z0-9._-]*' .github/workflows/containerized-build.yml || echo unknown; } > /ws_meta/ci_builder; \
    if grep -qF 'BUILD_DIR="build_${{ inputs.vendor }}_${{ inputs.coin_support_variant }}"' .github/workflows/containerized-build.yml; then echo vendor; \
    elif grep -qF 'BUILD_DIR="build_${{ inputs.coin_support_variant }}"' .github/workflows/containerized-build.yml; then echo variant; \
    else echo unknown; fi > /ws_meta/build_dir_form
EOF
} > "${workDir}/ctx-source/Dockerfile"

$CONTAINER_CMD pull --platform "$PLATFORM" "$GIT_IMAGE" >/dev/null \
  || fail_no_verdict "Could not pull ${GIT_IMAGE}."
log_info "Cloning tag v${version} with submodules (container)..."
srcImageMade=1
if ! $CONTAINER_CMD build --no-cache --platform "$PLATFORM" \
      --build-arg GIT_IMAGE="$GIT_IMAGE" \
      --build-arg VERSION_TAG="v${version}" \
      --build-arg REPO_URL="$REPO_URL" \
      -t "$SRC_IMAGE" -f "${workDir}/ctx-source/Dockerfile" "${workDir}/ctx-source"; then
  fail_no_verdict "Could not clone tag v${version} with submodules from ${REPO_URL} (missing tag or network error)."
fi

# shellcheck disable=SC2016  # the single-quoted command expands inside the container
if ! meta="$($CONTAINER_CMD run --rm --platform "$PLATFORM" --entrypoint sh "$SRC_IMAGE" \
      -c 'cd /ws_meta && for f in *; do printf "%s=%s\n" "$f" "$(cat "$f")"; done')"; then
  fail_no_verdict "Could not read source metadata from the clone image."
fi
while IFS='=' read -r key value; do
  case "$key" in
    commit)           commit="$value" ;;
    tag_type)         tagType="$value" ;;
    tag_signature)    tagSig="$value" ;;
    commit_signature) commitSig="$value" ;;
    ci_builder)       ciBuilder="$value" ;;
    build_dir_form)   buildDirForm="$value" ;;
  esac
done <<< "$meta"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail_no_verdict "Clone did not report a valid commit."
log_info "Source at commit ${commit} (tag v${version})"
NOTES+=("Source commit: ${commit}.")

# Use the builder and build directory upstream CI used for this tag; refuse anything unknown.
case "$ciBuilder" in
  cypherock/x1-firmware-builder:v0.0.0) BUILDER_IMAGE="$BUILDER_V0" ;;
  cypherock/x1-firmware-builder:v1.0.0) BUILDER_IMAGE="$BUILDER_V1" ;;
  *)
    log_error "Upstream CI at v${version} names builder '${ciBuilder}', which this script does not pin. Update the script."
    exit "$EXIT_INVALID" ;;
esac
BUILDER_REF="$ciBuilder"
case "$buildDirForm" in
  vendor)  BUILD_DIR="build_Cypherock_${COIN_VARIANT}" ;;
  variant) BUILD_DIR="build_${COIN_VARIANT}" ;;
  *)
    log_error "Could not read the build directory from upstream CI at v${version}. Update the script."
    exit "$EXIT_INVALID" ;;
esac
log_info "Builder (from upstream CI at the tag): ${BUILDER_IMAGE}; build directory ${BUILD_DIR}"
NOTES+=("Build: upstream CI recipe at the tag (.github/workflows/containerized-build.yml), cmake Main/Release/Device, VENDOR=Cypherock, BTC_ONLY=${BTC_ONLY_FLAG}, SIGN_BINARY=OFF, Ninja, build directory ${BUILD_DIR}, in ${BUILDER_REF} (the builder CI names at this tag) pinned by digest, platform ${PLATFORM}.")
$CONTAINER_CMD pull --platform "$PLATFORM" "$BUILDER_IMAGE" >/dev/null \
  || fail_no_verdict "Could not pull ${BUILDER_IMAGE}."

# ---- Step 3: build the firmware inside the builder image ----------------------------------
{
printf 'ARG SRC_IMAGE=%s\n' "$SRC_IMAGE"
printf 'ARG BUILDER_IMAGE=%s\n' "$BUILDER_IMAGE"
cat <<'EOF'
FROM ${SRC_IMAGE} AS source
FROM ${BUILDER_IMAGE}
ARG BTC_ONLY_FLAG
ARG BUILD_DIR
COPY --from=source /src /firmware
WORKDIR /firmware
RUN set -e; \
    cmake -B "$BUILD_DIR" \
      -DDEV_SWITCH=OFF \
      -DUNIT_TESTS_SWITCH:BOOL=OFF \
      -DBTC_ONLY:BOOL="$BTC_ONLY_FLAG" \
      -DSIGN_BINARY=OFF \
      -DCMAKE_BUILD_TYPE:STRING=Release \
      -DFIRMWARE_TYPE=Main \
      -DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=OFF \
      -DCMAKE_BUILD_PLATFORM:STRING=Device \
      -DVENDOR=Cypherock \
      -G Ninja . ; \
    ninja -C "$BUILD_DIR"; \
    mkdir -p /ws_out; \
    cp "$BUILD_DIR"/Cypherock-*.bin /ws_out/
EOF
} > "${workDir}/ctx-build/Dockerfile"

log_info "Building firmware (${COIN_VARIANT}) in ${BUILDER_REF}..."
buildImageMade=1
if ! $CONTAINER_CMD build --no-cache --platform "$PLATFORM" \
      --build-arg SRC_IMAGE="$SRC_IMAGE" \
      --build-arg BUILDER_IMAGE="$BUILDER_IMAGE" \
      --build-arg BTC_ONLY_FLAG="$BTC_ONLY_FLAG" \
      --build-arg BUILD_DIR="$BUILD_DIR" \
      -t "$BUILD_IMAGE" -f "${workDir}/ctx-build/Dockerfile" "${workDir}/ctx-build"; then
  fail_ftbfs "Firmware build failed (cmake/ninja in ${BUILDER_REF})."
fi

if ! EXTRACT_CTR="$($CONTAINER_CMD create --platform "$PLATFORM" "$BUILD_IMAGE" true)"; then
  EXTRACT_CTR=""
  fail_no_verdict "Could not create a container to extract the built firmware."
fi
if ! $CONTAINER_CMD cp "${EXTRACT_CTR}:/ws_out/${ARTIFACT}" "$builtFile"; then
  fail_ftbfs "Build finished but ${ARTIFACT} was not produced."
fi
[[ -s "$builtFile" ]] || fail_ftbfs "Built ${ARTIFACT} is empty."

# ---- Step 4: compare ----------------------------------------------------------------------
officialHash="$(hash_in_container "$officialFile")"
builtHash="$(hash_in_container "$builtFile")"
[[ "$officialHash" =~ ^[0-9a-f]{64}$ && "$builtHash" =~ ^[0-9a-f]{64}$ ]] \
  || fail_no_verdict "Could not hash the firmware files."
NOTES+=("Official SHA-256: ${officialHash}." "Built SHA-256: ${builtHash}.")

if [[ "$builtHash" == "$officialHash" ]]; then
  verdict="reproducible"
  matchFlag="1 (MATCHES)"
  exitCode="$EXIT_OK"
  echo -e "${GREEN}REPRODUCIBLE: built firmware is identical to the official firmware${NC}"
  write_results "reproducible" "${NOTES[@]}" "Result: identical hashes."
else
  verdict="not_reproducible"
  matchFlag="0 (DOESN'T MATCH)"
  exitCode="$EXIT_FAIL"
  echo -e "${RED}NOT REPRODUCIBLE: built firmware differs from the official firmware${NC}"
  write_results "not_reproducible" "${NOTES[@]}" "Result: hashes differ. The script does not classify the cause; inspect the two files."
fi

case "$tagType" in
  tag)    tagTypeLabel="annotated" ;;
  commit) tagTypeLabel="lightweight" ;;
  *)      tagTypeLabel="unknown" ;;
esac
case "$tagSig" in
  present) tagSigLine="[WARNING] Tag has a signature block; this script does not verify it" ;;
  absent)  tagSigLine="[WARNING] Tag is not signed" ;;
  *)       tagSigLine="[INFO] Tag is lightweight (cannot contain a signature)" ;;
esac
if [[ "$commitSig" == "present" ]]; then
  commitSigLine="[WARNING] Commit has a signature block; this script does not verify it"
else
  commitSigLine="[WARNING] Commit is not signed"
fi

echo
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${verdict}"
echo "appHash:        ${officialHash}"
echo "commit:         ${commit}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo
echo "Diff:"
if [[ "$verdict" == "reproducible" ]]; then
  echo "BUILDS MATCH BINARIES"
else
  echo "BUILDS DO NOT MATCH BINARIES"
fi
echo "${ARTIFACT} - ${archLabel}-${firmwareType} - ${builtHash} - ${matchFlag}"
echo
echo "SUMMARY"
echo "total: 1"
if [[ "$verdict" == "reproducible" ]]; then
  echo "matches: 1"
  echo "mismatches: 0"
else
  echo "matches: 0"
  echo "mismatches: 1"
fi
echo
echo "Revision, tag (and its signature):"
echo "Signature Summary:"
echo "Tag type: ${tagTypeLabel}"
echo "${tagSigLine}"
echo "${commitSigLine}"
echo "===== End Results ====="
echo
echo "Publish appHash: the official ${ARTIFACT} exactly as downloaded or provided (whole file)."
echo "builtHash:      ${builtHash} (our build; must equal appHash)"
echo "type:           ${firmwareType}"
echo "artifact:       ${ARTIFACT}"
echo "tag:            v${version}"
echo "builderImage:   ${BUILDER_IMAGE} (named by upstream CI at the tag)"
echo "buildDir:       ${BUILD_DIR}"
echo "platform:       ${PLATFORM}"
echo "Official source: ${officialSource}"
echo
echo "Run a full comparison:"
echo "cmp -l \"${officialFile}\" \"${builtFile}\" | head"
echo "diffoscope \"${officialFile}\" \"${builtFile}\""
echo "Files are kept in: ${workDir}/output"
echo "Base images kept for reuse: ${BUILDER_IMAGE} ${GIT_IMAGE} ${CURL_IMAGE}"
echo
echo "Cypherock X1 firmware verification finished."

exit "$exitCode"
