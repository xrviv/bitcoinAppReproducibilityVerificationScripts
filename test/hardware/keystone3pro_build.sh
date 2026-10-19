#!/bin/bash
# ==============================================================================
# keystone3pro_build.sh - Keystone 3 Pro Reproducible Build Verification
# ==============================================================================
# Version: v0.1.2
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Date last modified: 2026-07-28
# Project: https://github.com/KeystoneHQ/keystone3-firmware
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided. Review all operations
# before execution.
#
# SCRIPT SUMMARY:
# - Clones the Keystone 3 firmware repository inside a container.
# - Checks out the requested release tag and initializes public submodules.
# - Builds the official upstream Dockerfile from that tag.
# - Checks official firmware availability before spending build time.
# - Builds the requested firmware variant twice, in independent source trees.
# - Requires A/B build determinism before comparing against the official package.
# - Runs firmware-checker (fmc) on the official keystone3.bin payload.
# - Compares build A's mh1903.bin hash against the official extracted payload.

set -eEuo pipefail

SCRIPT_VERSION="v0.1.2"
APP_ID="keystone3.pro"
REPO_URL="https://github.com/KeystoneHQ/keystone3-firmware"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="arm"
TYPE="multi"
BINARY_PATH=""
NO_CACHE=false
WORK_DIR=""
IMAGE_TAG=""
GIT_IMAGE_TAG=""
CONTAINER_CMD=""

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_fail() { echo -e "${RED}[FAIL] $*${NC}" >&2; }

write_results() {
  local verdict="$1"
  local notes="${2:-}"

  notes="${notes//\\/ }"
  notes="${notes//\"/\'}"
  notes="${notes//$'\r'/ }"

  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${verdict}"
    if [[ -n "${notes}" ]]; then
      echo "notes: |"
      printf '%s\n' "${notes}" | sed 's/^/  /'
    fi
  } > "${RESULTS_FILE}"

  echo -e "${GREEN}Results written to: ${RESULTS_FILE}${NC}"
}

handle_err() {
  local rc=$?
  trap - ERR
  log_fail "Unexpected error (exit ${rc})."
  write_results "ftbfs" "Keystone 3 Pro v${VERSION:-unknown} (${TYPE:-unknown}): script failed before a verdict could be computed. Work dir: ${WORK_DIR:-unset}"
  exit "${EXIT_FAIL}"
}
trap handle_err ERR

usage() {
  cat <<USAGE
keystone3pro_build.sh ${SCRIPT_VERSION} - Keystone 3 Pro firmware reproducible build verifier

Usage:
  $0 --version VERSION [--arch arm] [--type multi|btc-only|cypherpunk] [--binary PATH]

Parameters:
  --version VERSION   Firmware version without 'v' prefix, e.g. 2.4.6. Required.
  --arch ARCH         ABS compatibility parameter. Only 'arm' is supported.
  --type TYPE         Firmware type. Accepted:
                      multi|multicoin|web3
                      btc-only|btc_only|btc
                      cypherpunk
  --binary PATH       Optional official keystone3.bin. If omitted, downloads from
                      https://keyst.one/contents/KeystoneFirmwareG3/
  --apk PATH          Android-only parameter; accepted as an alias for --binary.
  --no-cache          Build container images without cache.
  --help              Show this help.

Exit codes: 0 = reproducible, 1 = not reproducible or build failure, 2 = invalid parameters.
USAGE
}

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "${value}" || "${value}" == --* ]]; then
    log_fail "Missing value for ${flag}"
    exit "${EXIT_INVALID}"
  fi
}

detect_container_cmd() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  else
    log_fail "Neither podman nor docker found. Install one container runtime."
    write_results "ftbfs" "No container runtime found. Host requirement is podman or docker."
    exit "${EXIT_FAIL}"
  fi
  log_info "Container engine: ${CONTAINER_CMD}"
}

container_user_args() {
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  if [[ "${CONTAINER_CMD}" == "docker" ]]; then
    printf '%s\n' "--user" "${uid}:${gid}"
  fi
}

container_chown_trap() {
  local path="$1"
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  if [[ "${CONTAINER_CMD}" == "docker" ]]; then
    printf 'chown -R %s:%s %s >/dev/null 2>&1 || true' "${uid}" "${gid}" "${path}"
  else
    printf ':'
  fi
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit "${EXIT_INVALID}"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
      --arch) require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
      --type) require_value "$1" "${2:-}"; TYPE="$2"; shift 2 ;;
      --binary) require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --apk)
        log_warn "--apk is an Android parameter; treating it as --binary."
        require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --no-cache) NO_CACHE=true; shift ;;
      --help|-h) usage; exit "${EXIT_OK}" ;;
      *) log_warn "Ignoring unknown argument: $1"; shift ;;
    esac
  done
}

validate_inputs() {
  if [[ -z "${VERSION}" ]]; then
    log_fail "--version is required."
    exit "${EXIT_INVALID}"
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    log_fail "Invalid --version '${VERSION}'. Expected numeric X.Y.Z, e.g. 2.4.6."
    exit "${EXIT_INVALID}"
  fi

  case "${ARCH}" in
    arm|"") ARCH="arm" ;;
    *) log_fail "Unsupported --arch '${ARCH}'. Keystone 3 Pro firmware supports arch 'arm'."; exit "${EXIT_INVALID}" ;;
  esac

  case "${TYPE,,}" in
    multi|multicoin|web3) TYPE="multi" ;;
    btc|btc-only|btc_only|bitcoin|bitcoin-only|bitcoin_only) TYPE="btc-only" ;;
    cypherpunk) TYPE="cypherpunk" ;;
    *) log_fail "Unsupported --type '${TYPE}'. Use multi, btc-only, or cypherpunk."; exit "${EXIT_INVALID}" ;;
  esac

  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ ! -f "${BINARY_PATH}" ]]; then
      log_fail "--binary file not found: ${BINARY_PATH}"
      exit "${EXIT_INVALID}"
    fi
  fi
}

variant_arg() {
  case "${TYPE}" in
    multi) echo "" ;;
    btc-only) echo "btc_only" ;;
    cypherpunk) echo "cypherpunk" ;;
  esac
}

official_url() {
  case "${TYPE}" in
    multi) echo "https://keyst.one/contents/KeystoneFirmwareG3/v${VERSION}/web3/keystone3.bin" ;;
    btc-only) echo "https://keyst.one/contents/KeystoneFirmwareG3/v${VERSION}/btc_only/keystone3.bin" ;;
    cypherpunk) echo "https://keyst.one/contents/KeystoneFirmwareG3/v${VERSION}/cypherpunk/keystone3.bin" ;;
  esac
}

build_git_helper_image() {
  local dockerfile="${WORK_DIR}/Dockerfile.git-helper"
  cat > "${dockerfile}" <<'DOCKERFILE'
FROM ubuntu:20.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends ca-certificates git openssh-client \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

  local cache_args=()
  if [[ "${NO_CACHE}" == true ]]; then
    cache_args=(--no-cache)
  fi
  "${CONTAINER_CMD}" build "${cache_args[@]}" -t "${GIT_IMAGE_TAG}" -f "${dockerfile}" "${WORK_DIR}"
}

clone_source_tree() {
  local dest_name="$1"
  local user_args=()
  mapfile -t user_args < <(container_user_args)

  "${CONTAINER_CMD}" run --rm \
    "${user_args[@]}" \
    -e HOME=/tmp \
    -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" \
    bash -lc "
      set -euo pipefail
      cd /work
      git clone '${REPO_URL}' '${dest_name}'
      cd '${dest_name}'
      git checkout 'tags/${VERSION}'
      git -c submodule.keystone3-firmware-release.update=none submodule update --init --recursive
    "
}

prepare_sources() {
  local user_args=()
  mapfile -t user_args < <(container_user_args)

  log_info "Preparing two independent source trees inside a container."
  clone_source_tree "source-a"
  clone_source_tree "source-b"
  commit_a="$("${CONTAINER_CMD}" run --rm \
    "${user_args[@]}" \
    -e HOME=/tmp \
    -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" \
    bash -lc "cd /work/source-a && git rev-parse HEAD")"
  commit_b="$("${CONTAINER_CMD}" run --rm \
    "${user_args[@]}" \
    -e HOME=/tmp \
    -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" \
    bash -lc "cd /work/source-b && git rev-parse HEAD")"
  if [[ "${commit_a}" != "${commit_b}" ]]; then
    log_fail "Source clone commits differ: A=${commit_a}, B=${commit_b}"
    write_results "ftbfs" "Source clone commits differ before build."
    exit "${EXIT_FAIL}"
  fi
  log_info "Source commit: ${commit_a}"
}

build_upstream_image() {
  local cache_args=()
  if [[ "${NO_CACHE}" == true ]]; then
    cache_args=(--no-cache)
  fi
  log_info "Building upstream Dockerfile from tag ${VERSION}."
  "${CONTAINER_CMD}" build "${cache_args[@]}" -t "${IMAGE_TAG}" "${WORK_DIR}/source-a"
}

run_firmware_build() {
  local source_dir="$1"
  local label="$2"
  local variant chown_cmd
  variant="$(variant_arg)"
  chown_cmd="$(container_chown_trap /keystone3-firmware)"

  log_info "Running build ${label} (${TYPE})."
  "${CONTAINER_CMD}" run --rm \
    -e BUILD_VARIANT="${variant}" \
    -v "${source_dir}:/keystone3-firmware" \
    "${IMAGE_TAG}" \
    bash -lc "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      cd /keystone3-firmware
      if [ -n \"\${BUILD_VARIANT}\" ]; then
        python3 build.py -e production -t \"\${BUILD_VARIANT}\"
      else
        python3 build.py -e production
      fi
    "

  if [[ ! -f "${source_dir}/build/mh1903.bin" ]]; then
    log_fail "Build ${label} did not produce build/mh1903.bin."
    write_results "ftbfs" "Build ${label} completed without build/mh1903.bin."
    exit "${EXIT_FAIL}"
  fi
}

build_firmware_checker() {
  local chown_cmd
  chown_cmd="$(container_chown_trap /keystone3-firmware)"
  log_info "Building firmware-checker from the checked-out source."
  "${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}/source-a:/keystone3-firmware" \
    "${IMAGE_TAG}" \
    bash -lc "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      cd /keystone3-firmware/tools/code/firmware-checker
      cargo build --release
    "
}

preflight_official_firmware() {
  local url probe status

  if [[ -n "${BINARY_PATH}" ]]; then
    if [[ ! -f "${BINARY_PATH}" ]]; then
      log_fail "Official firmware no longer present at ${BINARY_PATH}."
      write_results "ftbfs" "Official artifact unavailable: the --binary file '${BINARY_PATH}' passed validation at startup but is no longer present. No reproducibility verdict was computed; this is not a hash mismatch."
      exit "${EXIT_FAIL}"
    fi
    log_info "Official firmware supplied locally; skipping availability check."
    return
  fi

  url="$(official_url)"
  log_info "Checking official firmware availability: ${url}"

  probe="$("${CONTAINER_CMD}" run --rm "${IMAGE_TAG}" \
    bash -lc "wget --server-response --spider --user-agent='Mozilla/5.0' --tries=2 --timeout=20 '${url}' 2>&1" || true)"
  status="$(printf '%s\n' "${probe}" | awk '/^[[:space:]]*HTTP\// {code=$2} END {print code}')"

  case "${status}" in
    404|410)
      log_fail "Official firmware is not published for v${VERSION} (${TYPE}) — HTTP ${status}."
      log_fail "URL: ${url}"
      write_results "ftbfs" "Official artifact unavailable: no keystone3.bin is published for v${VERSION} (${TYPE}) at ${url} (HTTP ${status}). No reproducibility verdict was computed; this is NOT a hash mismatch and must not be read as not_reproducible. Keystone releases the multi, btc-only and cypherpunk variants on independent schedules, so this version may exist for a different variant. Check https://keyst.one/firmware for the version currently published per variant, or pass --binary with a locally held official image."
      exit "${EXIT_FAIL}"
      ;;
    2??)
      log_info "Official firmware is available (HTTP ${status})."
      ;;
    "")
      log_warn "Availability preflight inconclusive: no HTTP status returned for ${url}."
      log_warn "Continuing; the official download is attempted after the builds."
      ;;
    *)
      log_warn "Availability preflight inconclusive: HTTP ${status} for ${url}."
      log_warn "Continuing; the official download is attempted after the builds."
      ;;
  esac
}

stage_official_firmware() {
  local chown_cmd url
  chown_cmd="$(container_chown_trap /keystone3-firmware)"

  if [[ -n "${BINARY_PATH}" ]]; then
    log_info "Using provided official firmware: ${BINARY_PATH}"
    cp "${BINARY_PATH}" "${WORK_DIR}/source-a/official-keystone3.bin"
    return
  fi

  url="$(official_url)"
  log_info "Downloading official firmware: ${url}"
  "${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}/source-a:/keystone3-firmware" \
    "${IMAGE_TAG}" \
    bash -lc "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      cd /keystone3-firmware
      wget -O official-keystone3.bin '${url}' --user-agent='Mozilla/5.0' --tries=3 --timeout=30
    "
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

extract_official_payload_hash() {
  local output payload
  output="$("${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}/source-a:/keystone3-firmware" \
    "${IMAGE_TAG}" \
    bash -lc "
      set -euo pipefail
      cd /keystone3-firmware
      ./tools/code/firmware-checker/target/release/fmc --source official-keystone3.bin
    ")"

  payload="$(printf '%s\n' "${output}" | awk '/Firmware checksum sha256:/ {print $4; exit}')"
  if [[ ! "${payload}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log_fail "Could not parse official payload hash from firmware-checker output."
    write_results "ftbfs" "firmware-checker did not return a parseable official payload hash."
    exit "${EXIT_FAIL}"
  fi
  printf '%s\n' "${output}" >&2
  echo "${payload,,}"
}

print_results_block() {
  local verdict="$1"
  local official_hash="$2"
  local build_a_hash="$3"
  local build_b_hash="$4"
  local official_payload_hash="$5"
  local ab_match="$6"
  local official_match="$7"

  echo
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${official_hash}"
  echo "commit:         ${commit_a}"
  echo
  echo "BUILDS MATCH BINARIES"
  echo "build-a-vs-build-b - ${ARCH}-${TYPE} - ${build_a_hash} - ${ab_match}"
  echo "official-payload-vs-build-a - ${ARCH}-${TYPE} - ${official_payload_hash} - ${official_match}"
  echo
  echo "SUMMARY"
  echo "buildAHash:            ${build_a_hash}"
  echo "buildBHash:            ${build_b_hash}"
  echo "officialPackageHash:   ${official_hash}"
  echo "officialPayloadHash:   ${official_payload_hash}"
  echo "officialFile:          keystone3.bin"
  echo "builtFile:             build/mh1903.bin"
  echo "===== End Results ====="
}

main() {
  parse_args "$@"
  validate_inputs
  detect_container_cmd

  WORK_DIR="$(pwd)/keystone3pro-work_${VERSION}_${TYPE}_$$"
  IMAGE_TAG="walletscrutiny-keystone3pro:${VERSION}-${TYPE}-$$"
  GIT_IMAGE_TAG="walletscrutiny-keystone3pro-git:${VERSION}-${TYPE}-$$"
  mkdir -p "${WORK_DIR}"

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
  echo "Verifying Keystone 3 Pro firmware v${VERSION} (${TYPE}, ${ARCH})"
  echo "Work dir: ${WORK_DIR}"
  echo

  build_git_helper_image
  prepare_sources
  build_upstream_image
  preflight_official_firmware
  run_firmware_build "${WORK_DIR}/source-a" "A"
  run_firmware_build "${WORK_DIR}/source-b" "B"

  buildAHash="$(sha256_file "${WORK_DIR}/source-a/build/mh1903.bin")"
  buildBHash="$(sha256_file "${WORK_DIR}/source-b/build/mh1903.bin")"

  if [[ "${buildAHash}" != "${buildBHash}" ]]; then
    echo "A/B DETERMINISM: FAIL build_a_sha256=${buildAHash} build_b_sha256=${buildBHash}"
    print_results_block "not_reproducible" "not_checked" "${buildAHash}" "${buildBHash}" "not_checked" "0 (DOESN'T MATCH)" "0 (NOT CHECKED)"
    write_results "not_reproducible" "A/B determinism failed before official comparison. Build A and build B produced different build/mh1903.bin hashes."
    exit "${EXIT_FAIL}"
  fi

  echo "A/B DETERMINISM: PASS build_a_sha256=${buildAHash} build_b_sha256=${buildBHash}"

  build_firmware_checker
  stage_official_firmware

  officialHash="$(sha256_file "${WORK_DIR}/source-a/official-keystone3.bin")"
  officialPayloadHash="$(extract_official_payload_hash)"

  if [[ "${buildAHash,,}" == "${officialPayloadHash,,}" ]]; then
    finalVerdict="reproducible"
    officialMatch="1 (MATCHES)"
    exitCode="${EXIT_OK}"
  else
    finalVerdict="not_reproducible"
    officialMatch="0 (DOESN'T MATCH)"
    exitCode="${EXIT_FAIL}"
  fi

  print_results_block "${finalVerdict}" "${officialHash}" "${buildAHash}" "${buildBHash}" "${officialPayloadHash}" "1 (MATCHES)" "${officialMatch}"

  if [[ "${finalVerdict}" == "reproducible" ]]; then
    notes="Keystone 3 Pro v${VERSION} (${TYPE}) reproduced. Two independent builds produced the same build/mh1903.bin hash before official comparison. The official keystone3.bin payload extracted with firmware-checker matched build A."
  else
    notes="Keystone 3 Pro v${VERSION} (${TYPE}) did not reproduce. A/B determinism passed, but the official keystone3.bin payload extracted with firmware-checker did not match build A."
  fi
  write_results "${finalVerdict}" "${notes}"
  exit "${exitCode}"
}

main "$@"
