#!/bin/bash
# ==============================================================================
# keepkey_build.sh - KeepKey Firmware Reproducible Build Verification
# ==============================================================================
# Version: v0.1.0
# Organization: WalletScrutiny.com
# Project: https://github.com/keepkey/keepkey-firmware
# License: MIT
# Last modified by: Daniel Garcia (WalletScrutiny)
# Last modified on: 2026-10-19
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided. Review all operations
# before execution.
#
# SCRIPT SUMMARY:
# - Prints its own name, version and sha256, refuses to run as root.
# - Creates a fresh per-run workspace under the caller's directory.
# - Checks that the official firmware exists before spending build time.
# - Clones the firmware repository twice inside a container and checks out the
#   release tag v<version> with all submodules.
# - Pulls the build image pinned by digest in the tag's own
#   scripts/build/docker/device/release.sh and runs the same cmake/make steps,
#   twice, in independent source trees (A/B determinism gate).
# - Compares the payload (everything after the 256-byte KPKY header) of the
#   official firmware.keepkey.bin with build A's, as the release notes define it.
# - Checks that the two headers differ only in the signature fields (signature
#   indexes and the three 64-byte signature slots), and cross-checks the payload
#   hash with the release's HASHES.txt (informational).
# - Hands the workspace back to the caller and removes this run's helper image.

set -eEuo pipefail

SCRIPT_VERSION="v0.1.0"
APP_ID="keepKey"
REPO_URL="https://github.com/keepkey/keepkey-firmware"
RELEASE_URL="https://github.com/keepkey/keepkey-firmware/releases/download"
OFFICIAL_NAME="firmware.keepkey.bin"
HEADER_SIZE=256
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
SCRIPT_SHA256="N/A"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="arm"
TYPE="firmware"
BINARY_PATH=""
NO_CACHE=false
JOBS=""
RUN_ID=""
WORK_DIR=""
BUILD_IMAGE=""
GIT_IMAGE_TAG=""
CONTAINER_CMD=""
CTR_NAME=""
BG_PID=""
VERDICT_WRITTEN=false
commit_a=""

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_fail() { echo -e "${RED}[FAIL] $*${NC}" >&2; }

# 3-field results file next to the script. notes is a literal block scalar.
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
  VERDICT_WRITTEN=true
  echo -e "${GREEN}Results written to: ${RESULTS_FILE}${NC}"
}

die_ftbfs() {
  log_fail "$1"
  write_results "ftbfs" "$1"
  exit "${EXIT_FAIL}"
}

handle_err() {
  local rc=$?
  trap - ERR
  log_fail "Unexpected error (exit ${rc})."
  if [[ "${VERDICT_WRITTEN}" != true ]]; then
    write_results "ftbfs" "KeepKey v${VERSION:-unknown}: script failed before a verdict could be computed (exit ${rc})."
  fi
  exit "${EXIT_FAIL}"
}
trap handle_err ERR

is_rootless() {
  local r=""
  case "${CONTAINER_CMD}" in
    *podman) r="$("${CONTAINER_CMD}" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" ;;
    *docker) if "${CONTAINER_CMD}" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then r="true"; fi ;;
  esac
  [[ "${r}" == "true" ]]
}

# Hand the workspace back to the caller through the container runtime; never fatal.
restore_host_owner() {
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  if is_rootless; then uid=0; gid=0; fi
  "${CONTAINER_CMD}" image exists "${GIT_IMAGE_TAG}" 2>/dev/null \
    || "${CONTAINER_CMD}" image inspect "${GIT_IMAGE_TAG}" >/dev/null 2>&1 || return 0
  "${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/w" "${GIT_IMAGE_TAG}" \
    chown -R "${uid}:${gid}" /w >/dev/null 2>&1 \
    || log_warn "Could not restore ownership of ${WORK_DIR}; deleting it may need 'podman unshare rm -rf'."
}

# EXIT trap (success, failure, INT/TERM): stop this run's container, record ftbfs if no
# verdict exists, hand the workspace back, drop this run's helper image. Never fails.
on_exit() {
  set +e
  trap - ERR
  if [[ -n "${BG_PID}" ]]; then kill "${BG_PID}" >/dev/null 2>&1; fi
  if [[ -n "${CTR_NAME}" && -n "${CONTAINER_CMD}" ]]; then
    "${CONTAINER_CMD}" rm -f "${CTR_NAME}" >/dev/null 2>&1
  fi
  if [[ "${VERDICT_WRITTEN}" != true ]]; then
    write_results "ftbfs" "KeepKey v${VERSION:-unknown}: run ended before a verdict was written (interrupted or internal error)."
  fi
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${CONTAINER_CMD}" ]]; then
    if [[ -n "$(find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
      restore_host_owner
    fi
    chmod -R u+rwX "${WORK_DIR}" >/dev/null 2>&1
    if [[ -n "$(find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
      log_warn "Workspace still has files not owned by uid $(id -u): ${WORK_DIR}"
    fi
  fi
  if [[ -n "${CONTAINER_CMD}" && -n "${GIT_IMAGE_TAG}" ]]; then
    "${CONTAINER_CMD}" rmi -f "${GIT_IMAGE_TAG}" >/dev/null 2>&1
  fi
  return 0
}

# Run a long command as a background job and wait for it, so INT/TERM traps fire at once
# instead of after the child returns (bash defers traps while a foreground child runs).
run_bg() {
  local rc=0
  "$@" </dev/null &
  BG_PID=$!
  wait "${BG_PID}" || rc=$?
  BG_PID=""
  return "${rc}"
}

# Run a container with a per-run name so the EXIT trap can stop it.
run_ctr() {
  local label="$1" rc=0
  shift
  CTR_NAME="keepkey-${RUN_ID}-${label}"
  run_bg "${CONTAINER_CMD}" run --rm --name "${CTR_NAME}" "$@" || rc=$?
  CTR_NAME=""
  return "${rc}"
}

usage() {
  cat <<USAGE
keepkey_build.sh ${SCRIPT_VERSION} - KeepKey firmware reproducible build verifier

Usage:
  $0 --version VERSION [--arch arm] [--type firmware] [--binary PATH]

Parameters:
  --version VERSION   Firmware version without 'v' prefix, e.g. 7.14.2. Required.
  --arch ARCH         ABS compatibility parameter. Only 'arm' is supported.
  --type TYPE         ABS compatibility parameter. Only 'firmware' is supported.
  --binary PATH       Optional official ${OFFICIAL_NAME} (or a directory holding one).
                      If omitted, downloads it from the GitHub release v<version>.
  --apk PATH          Android-only parameter; accepted as an alias for --binary.
  --jobs N            Parallel make jobs. Default: plain 'make', as upstream release.sh.
  --no-cache          Build the helper image without cache.
  --help              Show this help.

Only host requirement: podman or docker. Do not run as root.
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
    die_ftbfs "Neither podman nor docker found. Host requirement is podman or docker."
  fi
  log_info "Container engine: ${CONTAINER_CMD}"
}

container_user_args() {
  if [[ "${CONTAINER_CMD}" == "docker" ]]; then
    printf '%s\n' "--user" "$(id -u):$(id -g)"
  fi
}

# Inside a rootful docker build container: give the tree back to the caller on exit.
container_chown_trap() {
  if [[ "${CONTAINER_CMD}" == "docker" ]]; then
    printf 'chown -R %s:%s %s >/dev/null 2>&1 || true' "$(id -u)" "$(id -g)" "$1"
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
      --jobs) require_value "$1" "${2:-}"; JOBS="$2"; shift 2 ;;
      --no-cache) NO_CACHE=true; shift ;;
      --help|-h) usage; exit "${EXIT_OK}" ;;
      *) log_warn "Ignoring unknown parameter: $1"; shift ;;
    esac
  done
}

validate_inputs() {
  VERSION="${VERSION#v}"
  if [[ -z "${VERSION}" ]]; then
    log_fail "--version is required."
    exit "${EXIT_INVALID}"
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    log_fail "Invalid --version '${VERSION}'. Expected numeric X.Y.Z, e.g. 7.14.2."
    exit "${EXIT_INVALID}"
  fi
  case "${ARCH}" in
    arm|"") ARCH="arm" ;;
    *) log_fail "Unsupported --arch '${ARCH}'. KeepKey firmware supports arch 'arm'."; exit "${EXIT_INVALID}" ;;
  esac
  case "${TYPE,,}" in
    firmware|"") TYPE="firmware" ;;
    *) log_fail "Unsupported --type '${TYPE}'. KeepKey firmware supports type 'firmware'."; exit "${EXIT_INVALID}" ;;
  esac
  if [[ -n "${JOBS}" && ! "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    log_fail "Invalid --jobs '${JOBS}'. Expected a positive integer."
    exit "${EXIT_INVALID}"
  fi
  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ -d "${BINARY_PATH}" && -f "${BINARY_PATH}/${OFFICIAL_NAME}" ]]; then
      BINARY_PATH="${BINARY_PATH}/${OFFICIAL_NAME}"
    fi
    if [[ ! -f "${BINARY_PATH}" ]]; then
      log_fail "--binary file not found: ${BINARY_PATH}"
      exit "${EXIT_INVALID}"
    fi
  fi
}

official_url() {
  echo "${RELEASE_URL}/v${VERSION}/${OFFICIAL_NAME}"
}

# Per-run workspace under the caller's directory: exclusive create, never reused or deleted.
setup_workdir() {
  local base
  base="$(pwd -P)"
  for _ in 1 2 3; do
    RUN_ID="$(date +%s)-$$"
    WORK_DIR="${base}/keepkey_verification_${VERSION}_${TYPE}_${RUN_ID}"
    if mkdir "${WORK_DIR}" 2>/dev/null; then
      trap on_exit EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      GIT_IMAGE_TAG="walletscrutiny-keepkey-git:${VERSION}-${TYPE}-${RUN_ID}"
      log_info "Work dir: ${WORK_DIR}"
      return 0
    fi
    sleep 1
  done
  WORK_DIR=""
  die_ftbfs "Could not create a per-run workspace under ${base}."
}

build_git_helper_image() {
  local dockerfile="${WORK_DIR}/Dockerfile.git-helper"
  cat > "${dockerfile}" <<'DOCKERFILE'
FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends ca-certificates git wget \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  local cache_args=()
  [[ "${NO_CACHE}" == true ]] && cache_args=(--no-cache)
  log_info "Building the git/download helper image."
  run_bg "${CONTAINER_CMD}" build "${cache_args[@]}" -t "${GIT_IMAGE_TAG}" -f "${dockerfile}" "${WORK_DIR}"
}

preflight_official_firmware() {
  local url probe status
  if [[ -n "${BINARY_PATH}" ]]; then
    log_info "Official firmware supplied locally; skipping availability check."
    return
  fi
  url="$(official_url)"
  log_info "Checking official firmware availability: ${url}"
  probe="$("${CONTAINER_CMD}" run --rm "${GIT_IMAGE_TAG}" \
    wget --server-response --spider --tries=2 --timeout=20 "${url}" 2>&1 || true)"
  status="$(printf '%s\n' "${probe}" | awk '/^[[:space:]]*HTTP\// {code=$2} END {print code}')"
  case "${status}" in
    404|410)
      die_ftbfs "Official artifact unavailable: no ${OFFICIAL_NAME} is attached to GitHub release v${VERSION} (HTTP ${status} for ${url}). No reproducibility verdict was computed; this is NOT a hash mismatch. Pass --binary with a locally held official image."
      ;;
    2??) log_info "Official firmware is available (HTTP ${status})." ;;
    *)
      log_warn "Availability preflight inconclusive (HTTP '${status}') for ${url}."
      log_warn "Continuing; the official download is attempted after the builds."
      ;;
  esac
}

clone_source_tree() {
  local dest_name="$1"
  local user_args=()
  mapfile -t user_args < <(container_user_args)
  run_ctr "clone-${dest_name}" \
    "${user_args[@]}" \
    -e HOME=/tmp \
    -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" \
    bash -c "
      set -euo pipefail
      cd /work
      git clone '${REPO_URL}' '${dest_name}'
      cd '${dest_name}'
      git checkout 'tags/v${VERSION}'
      git submodule update --init --recursive
    "
}

prepare_sources() {
  local user_args=() commit_b
  mapfile -t user_args < <(container_user_args)
  log_info "Preparing two independent source trees inside a container."
  clone_source_tree "source-a"
  clone_source_tree "source-b"
  commit_a="$("${CONTAINER_CMD}" run --rm "${user_args[@]}" -e HOME=/tmp -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" git -C /work/source-a rev-parse HEAD)"
  commit_b="$("${CONTAINER_CMD}" run --rm "${user_args[@]}" -e HOME=/tmp -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" git -C /work/source-b rev-parse HEAD)"
  if [[ "${commit_a}" != "${commit_b}" ]]; then
    die_ftbfs "Source clone commits differ before build: A=${commit_a}, B=${commit_b}"
  fi
  log_info "Source commit: ${commit_a}"
}

# The tag's release.sh pins the build image by digest; use exactly that image.
pull_build_image() {
  local release_sh="${WORK_DIR}/source-a/scripts/build/docker/device/release.sh" ref
  [[ -f "${release_sh}" ]] || die_ftbfs "Tag v${VERSION} has no scripts/build/docker/device/release.sh."
  log_info "release.sh sha256: $(sha256sum "${release_sh}" | cut -c1-64)"
  ref="$(sed -n 's/^IMAGETAG=\([^[:space:]]*\).*/\1/p' "${release_sh}" | head -n1)"
  if [[ ! "${ref}" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]]; then
    die_ftbfs "release.sh IMAGETAG '${ref}' is not pinned by digest; refusing to guess the build image."
  fi
  [[ "${ref%%/*}" == *.* ]] || ref="docker.io/${ref}"
  BUILD_IMAGE="${ref}"
  log_info "Build image (pinned by release.sh): ${BUILD_IMAGE}"
  run_bg "${CONTAINER_CMD}" pull "${BUILD_IMAGE}"
}

# Same steps as release.sh, without its nested docker call. The source must be mounted at
# /root/keepkey-firmware and built in /root/build, as upstream does: paths can end up in the binary.
run_firmware_build() {
  local source_dir="$1"
  local label="$2"
  local chown_cmd make_cmd="make"
  chown_cmd="$(container_chown_trap /root/keepkey-firmware)"
  [[ -n "${JOBS}" ]] && make_cmd="make -j${JOBS}"
  log_info "Running build ${label} (${make_cmd})."
  run_ctr "build-${label}" \
    -v "${source_dir}:/root/keepkey-firmware" \
    "${BUILD_IMAGE}" \
    /bin/sh -c "
      set -e
      trap '${chown_cmd}' EXIT
      mkdir /root/build && cd /root/build
      cmake -C /root/keepkey-firmware/cmake/caches/device.cmake /root/keepkey-firmware \
        -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_COLOR_MAKEFILE=ON
      ${make_cmd}
      mkdir -p /root/keepkey-firmware/bin
      cp bin/*.bin /root/keepkey-firmware/bin/
      cp bin/*.elf /root/keepkey-firmware/bin/
    "
  if [[ ! -f "${source_dir}/bin/${OFFICIAL_NAME}" ]]; then
    die_ftbfs "Build ${label} completed without bin/${OFFICIAL_NAME}."
  fi
}

stage_official_files() {
  local user_args=()
  mapfile -t user_args < <(container_user_args)
  if [[ -n "${BINARY_PATH}" ]]; then
    log_info "Using provided official firmware: ${BINARY_PATH}"
    cp "${BINARY_PATH}" "${WORK_DIR}/official-${OFFICIAL_NAME}"
  else
    log_info "Downloading official firmware: $(official_url)"
    run_ctr "download" "${user_args[@]}" -v "${WORK_DIR}:/work" "${GIT_IMAGE_TAG}" \
      wget -q -O "/work/official-${OFFICIAL_NAME}" --tries=3 --timeout=30 "$(official_url)"
  fi
  "${CONTAINER_CMD}" run --rm "${user_args[@]}" -v "${WORK_DIR}:/work" "${GIT_IMAGE_TAG}" \
    wget -q -O /work/official-HASHES.txt --tries=2 --timeout=30 "${RELEASE_URL}/v${VERSION}/HASHES.txt" \
    || { rm -f "${WORK_DIR}/official-HASHES.txt"; log_warn "HASHES.txt not available for v${VERSION}."; }
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

payload_sha256() {
  tail -c +$((HEADER_SIZE + 1)) "$1" | sha256sum | awk '{print $1}'
}

# Byte offsets (0-based) inside the 256-byte KPKY header where the two files differ.
# tools/firmware/header.s: magic 0-3, codelen 4-7, sigindex 8-10, sig_flag 11, meta_flags
# 12-15, reserved 16-63, sig1/sig2/sig3 64-255. Only 8-10 and 64-255 are signature fields.
header_diff_offsets() {
  paste <(od -An -v -tu1 -w1 -N"${HEADER_SIZE}" "$1") <(od -An -v -tu1 -w1 -N"${HEADER_SIZE}" "$2") \
    | awk '$1 != $2 {print NR - 1}'
}

unexpected_header_offsets() {
  awk '!(($1 >= 8 && $1 <= 10) || ($1 >= 64 && $1 <= 255))' | tr '\n' ' ' | sed 's/ $//'
}

print_results_block() {
  local verdict="$1" official_hash="$2" build_a_hash="$3" build_b_hash="$4"
  local official_payload="$5" ab_match="$6" official_match="$7"
  echo
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${official_hash}"
  echo "commit:         ${commit_a:-unknown}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo "===== End Results ====="
  echo
  echo "BUILDS MATCH BINARIES"
  echo "build-a-vs-build-b - ${ARCH}-${TYPE} - ${build_a_hash} - ${ab_match}"
  echo "official-payload-vs-build-a-payload - ${ARCH}-${TYPE} - ${official_payload} - ${official_match}"
}

main() {
  SCRIPT_SHA256="$(sha256sum "${SCRIPT_PATH}" 2>/dev/null | awk '{print $1}')"
  [[ -n "${SCRIPT_SHA256}" ]] || SCRIPT_SHA256="N/A"
  echo "Script:  $(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION}"
  echo "         sha256: ${SCRIPT_SHA256}"
  if [[ "$(id -u)" -eq 0 ]]; then
    log_fail "Refusing to run as root. Run this script as a normal user; podman or docker is the only requirement."
    exit "${EXIT_INVALID}"
  fi
  # Never let ABS read a verdict left by an earlier run in this directory.
  rm -f "${RESULTS_FILE}"

  parse_args "$@"
  validate_inputs
  detect_container_cmd
  setup_workdir

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
  echo "Verifying KeepKey firmware v${VERSION} (${TYPE}, ${ARCH})"
  echo

  build_git_helper_image
  preflight_official_firmware
  prepare_sources
  pull_build_image
  run_firmware_build "${WORK_DIR}/source-a" "A"
  run_firmware_build "${WORK_DIR}/source-b" "B"

  local builtA="${WORK_DIR}/source-a/bin/${OFFICIAL_NAME}" builtB="${WORK_DIR}/source-b/bin/${OFFICIAL_NAME}"
  local official="${WORK_DIR}/official-${OFFICIAL_NAME}"
  local buildAHash buildBHash buildAPayload officialHash officialPayload hashesPayload
  local headerDiffs unexpected finalVerdict officialMatch exitCode notes
  buildAHash="$(sha256_file "${builtA}")"
  buildBHash="$(sha256_file "${builtB}")"

  if [[ "${buildAHash}" != "${buildBHash}" ]]; then
    echo "A/B DETERMINISM: FAIL build_a_sha256=${buildAHash} build_b_sha256=${buildBHash}"
    print_results_block "not_reproducible" "not_checked" "${buildAHash}" "${buildBHash}" "not_checked" "0 (DOESN'T MATCH)" "0 (NOT CHECKED)"
    write_results "not_reproducible" "KeepKey v${VERSION}: A/B determinism failed before official comparison. Build A and build B produced different bin/${OFFICIAL_NAME} hashes."
    exit "${EXIT_FAIL}"
  fi
  echo "A/B DETERMINISM: PASS build_a_sha256=${buildAHash} build_b_sha256=${buildBHash}"

  stage_official_files
  officialHash="$(sha256_file "${official}")"
  officialPayload="$(payload_sha256 "${official}")"
  buildAPayload="$(payload_sha256 "${builtA}")"
  headerDiffs="$(header_diff_offsets "${official}" "${builtA}")"
  unexpected="$(printf '%s\n' "${headerDiffs}" | sed '/^$/d' | unexpected_header_offsets)"
  hashesPayload="not available"
  if [[ -f "${WORK_DIR}/official-HASHES.txt" ]]; then
    hashesPayload="$(awk -F': *' '/payload/ {print $2; exit}' "${WORK_DIR}/official-HASHES.txt" | awk '{print $1}')"
    [[ -n "${hashesPayload}" ]] || hashesPayload="not found in HASHES.txt"
  fi

  if [[ "${buildAPayload}" == "${officialPayload}" && -z "${unexpected}" ]]; then
    finalVerdict="reproducible"; officialMatch="1 (MATCHES)"; exitCode="${EXIT_OK}"
  else
    finalVerdict="not_reproducible"; exitCode="${EXIT_FAIL}"
    if [[ "${buildAPayload}" == "${officialPayload}" ]]; then officialMatch="1 (MATCHES)"; else officialMatch="0 (DOESN'T MATCH)"; fi
  fi

  print_results_block "${finalVerdict}" "${officialHash}" "${buildAHash}" "${buildBHash}" "${officialPayload}" "1 (MATCHES)" "${officialMatch}"
  echo
  echo "SUMMARY"
  echo "buildAHash:            ${buildAHash} (full file, unsigned header)"
  echo "buildBHash:            ${buildBHash} (full file, unsigned header)"
  echo "buildAPayloadHash:     ${buildAPayload}"
  echo "officialPackageHash:   ${officialHash}"
  echo "officialPayloadHash:   ${officialPayload}"
  echo "hashesTxtPayloadHash:  ${hashesPayload} (release HASHES.txt, informational)"
  echo "officialSize:          $(wc -c < "${official}") bytes; builtSize: $(wc -c < "${builtA}") bytes"
  echo "buildImage:            ${BUILD_IMAGE}"
  echo
  echo "HEADER (first ${HEADER_SIZE} bytes, tools/firmware/header.s)"
  echo "differingBytes:        $(printf '%s\n' "${headerDiffs}" | sed '/^$/d' | wc -l)"
  echo "outsideSignatureFields: ${unexpected:-none}"
  echo "official header 0-15:  $(od -An -tx1 -N16 "${official}" | tr -s ' ' | sed 's/^ //')"
  echo "built header 0-15:     $(od -An -tx1 -N16 "${builtA}" | tr -s ' ' | sed 's/^ //')"
  echo
  echo "Hash legend: appHash/officialPackageHash is the official ${OFFICIAL_NAME} exactly as"
  echo "downloaded (publish this one). The payload hashes skip the ${HEADER_SIZE}-byte KPKY header,"
  echo "which carries the vendor signatures; officialPayloadHash is what build A's payload must"
  echo "match. Never publish a payload hash as appHash."
  echo

  if [[ "${finalVerdict}" == "reproducible" ]]; then
    notes="KeepKey v${VERSION} reproduced. Two independent builds with the build image pinned in the tag's release.sh produced the same ${OFFICIAL_NAME}, and its payload after the ${HEADER_SIZE}-byte header matches the official one. The headers differ only in the signature indexes and the three signature slots, which only the vendor's signing keys can produce."
  elif [[ "${buildAPayload}" == "${officialPayload}" ]]; then
    notes="KeepKey v${VERSION} did not reproduce: the payload matches, but the header differs outside the signature fields at byte offsets ${unexpected}."
  else
    notes="KeepKey v${VERSION} did not reproduce. A/B determinism passed, but the payload after the ${HEADER_SIZE}-byte header differs from the official ${OFFICIAL_NAME}. Compare source-a/bin/${OFFICIAL_NAME} with official-${OFFICIAL_NAME} in the workspace."
  fi
  write_results "${finalVerdict}" "${notes}"
  exit "${exitCode}"
}

main "$@"
