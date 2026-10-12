#!/bin/bash
# ==============================================================================
# keystone3pro_build.sh - Keystone 3 Pro Reproducible Build Verification
# ==============================================================================
# Version: v0.2.0
# Organization: WalletScrutiny.com
# Project: https://github.com/KeystoneHQ/keystone3-firmware
# License: MIT
# Last modified by: Bob (WalletScrutiny)
# Last modified on: 2026-10-12
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
#   requested release tag with its public submodules.
# - Builds the upstream Dockerfile from that tag and the firmware variant twice,
#   in independent source trees (A/B determinism gate).
# - Runs upstream's firmware-checker (fmc) on the official keystone3.bin to get
#   the sha256 of its decompressed payload and compares it with build A's
#   build/mh1903.bin. Cross-checks that hash with upstream's pure-Python
#   tools/ota_bin_restore/ota_bin_restore.py when the tag ships it.
# - Hands the workspace back to the caller and removes this run's images.

set -eEuo pipefail

SCRIPT_VERSION="v0.2.0"
APP_ID="keystone3.pro"
REPO_URL="https://github.com/KeystoneHQ/keystone3-firmware"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
SCRIPT_SHA256="N/A"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="arm"
TYPE="multi"
BINARY_PATH=""
NO_CACHE=false
JOBS=""
RUN_ID=""
WORK_DIR=""
IMAGE_TAG=""
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
    write_results "ftbfs" "Keystone 3 Pro v${VERSION:-unknown} (${TYPE:-unknown}): script failed before a verdict could be computed (exit ${rc})."
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
  "${CONTAINER_CMD}" image exists "${GIT_IMAGE_TAG}" 2>/dev/null || return 0
  "${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/w" "${GIT_IMAGE_TAG}" \
    chown -R "${uid}:${gid}" /w >/dev/null 2>&1 \
    || log_warn "Could not restore ownership of ${WORK_DIR}; deleting it may need 'podman unshare rm -rf'."
}

# EXIT trap (success, failure, INT/TERM): stop this run's container, record ftbfs if no
# verdict exists, hand the workspace back, drop this run's images. Never fails.
on_exit() {
  set +e
  trap - ERR
  if [[ -n "${BG_PID}" ]]; then kill "${BG_PID}" >/dev/null 2>&1; fi
  if [[ -n "${CTR_NAME}" && -n "${CONTAINER_CMD}" ]]; then
    "${CONTAINER_CMD}" rm -f "${CTR_NAME}" >/dev/null 2>&1
  fi
  if [[ "${VERDICT_WRITTEN}" != true ]]; then
    write_results "ftbfs" "Keystone 3 Pro v${VERSION:-unknown} (${TYPE:-unknown}): run ended before a verdict was written (interrupted or internal error)."
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
  if [[ -n "${CONTAINER_CMD}" ]]; then
    [[ -n "${IMAGE_TAG}" ]] && "${CONTAINER_CMD}" rmi -f "${IMAGE_TAG}" >/dev/null 2>&1
    [[ -n "${GIT_IMAGE_TAG}" ]] && "${CONTAINER_CMD}" rmi -f "${GIT_IMAGE_TAG}" >/dev/null 2>&1
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
  CTR_NAME="kspro-${RUN_ID}-${label}"
  run_bg "${CONTAINER_CMD}" run --rm --name "${CTR_NAME}" "$@" || rc=$?
  CTR_NAME=""
  return "${rc}"
}

usage() {
  cat <<USAGE
keystone3pro_build.sh ${SCRIPT_VERSION} - Keystone 3 Pro firmware reproducible build verifier

Usage:
  $0 --version VERSION [--arch arm] [--type multi|btc-only|cypherpunk] [--binary PATH]

Parameters:
  --version VERSION   Firmware version without 'v' prefix, e.g. 3.1.2. Required.
  --arch ARCH         ABS compatibility parameter. Only 'arm' is supported.
  --type TYPE         Firmware type. Accepted:
                      multi|multicoin|web3
                      btc-only|btc_only|btc
                      cypherpunk
  --binary PATH       Optional official keystone3.bin (or a directory holding one).
                      If omitted, downloads from
                      https://keyst.one/contents/KeystoneFirmwareG3/
  --apk PATH          Android-only parameter; accepted as an alias for --binary.
  --jobs N            Parallel compile jobs for make and cargo (default: nproc).
  --no-cache          Build container images without cache.
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
  if [[ -z "${VERSION}" ]]; then
    log_fail "--version is required."
    exit "${EXIT_INVALID}"
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    log_fail "Invalid --version '${VERSION}'. Expected numeric X.Y.Z, e.g. 3.1.2."
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
  if [[ -z "${JOBS}" ]]; then
    JOBS="$(nproc 2>/dev/null || echo 4)"
  elif [[ ! "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    log_fail "Invalid --jobs '${JOBS}'. Expected a positive integer."
    exit "${EXIT_INVALID}"
  fi
  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ -d "${BINARY_PATH}" && -f "${BINARY_PATH}/keystone3.bin" ]]; then
      BINARY_PATH="${BINARY_PATH}/keystone3.bin"
    fi
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
  local dir
  case "${TYPE}" in
    multi) dir="web3" ;;
    btc-only) dir="btc_only" ;;
    cypherpunk) dir="cypherpunk" ;;
  esac
  echo "https://keyst.one/contents/KeystoneFirmwareG3/v${VERSION}/${dir}/keystone3.bin"
}

# Per-run workspace under the caller's directory: exclusive create, never reused or deleted.
setup_workdir() {
  local base
  base="$(pwd -P)"
  for _ in 1 2 3; do
    RUN_ID="$(date +%s)-$$"
    WORK_DIR="${base}/keystone3pro_verification_${VERSION}_${TYPE}_${RUN_ID}"
    if mkdir "${WORK_DIR}" 2>/dev/null; then
      trap on_exit EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      IMAGE_TAG="walletscrutiny-keystone3pro:${VERSION}-${TYPE}-${RUN_ID}"
      GIT_IMAGE_TAG="walletscrutiny-keystone3pro-git:${VERSION}-${TYPE}-${RUN_ID}"
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
 && apt-get install -y --no-install-recommends ca-certificates git openssh-client wget \
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
    wget --server-response --spider --user-agent='Mozilla/5.0' --tries=2 --timeout=20 "${url}" 2>&1 || true)"
  status="$(printf '%s\n' "${probe}" | awk '/^[[:space:]]*HTTP\// {code=$2} END {print code}')"
  case "${status}" in
    404|410)
      log_fail "Official firmware is not published for v${VERSION} (${TYPE}): HTTP ${status} for ${url}"
      die_ftbfs "Official artifact unavailable: no keystone3.bin is published for v${VERSION} (${TYPE}) at ${url} (HTTP ${status}). No reproducibility verdict was computed; this is NOT a hash mismatch and must not be read as not_reproducible. Keystone releases the multi, btc-only and cypherpunk variants on independent schedules, so this version may exist for a different variant. Check https://keyst.one/firmware for the version currently published per variant, or pass --binary with a locally held official image."
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
      git checkout 'tags/${VERSION}'
      git -c submodule.keystone3-firmware-release.update=none submodule update --init --recursive
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

build_upstream_image() {
  local cache_args=()
  [[ "${NO_CACHE}" == true ]] && cache_args=(--no-cache)
  log_info "Building upstream Dockerfile from tag ${VERSION} (sha256 $(sha256sum "${WORK_DIR}/source-a/Dockerfile" | cut -c1-64))."
  run_bg "${CONTAINER_CMD}" build "${cache_args[@]}" -t "${IMAGE_TAG}" "${WORK_DIR}/source-a"
}

# build.py calls an unbounded 'make -j'; this shim turns that bare -j into -j<--jobs> and
# passes every other invocation through. Parallelism does not change the produced bytes.
write_make_shim() {
  mkdir -p "${WORK_DIR}/bin"
  cat > "${WORK_DIR}/bin/make" <<'SHIM'
#!/bin/sh
j=""
for a in "$@"; do shift; if [ "$a" = "-j" ]; then j="-j${WS_JOBS:-1}"; else set -- "$@" "$a"; fi; done
exec /usr/bin/make $j "$@"
SHIM
  chmod +x "${WORK_DIR}/bin/make"
}

run_firmware_build() {
  local source_dir="$1"
  local label="$2"
  local variant chown_cmd
  variant="$(variant_arg)"
  chown_cmd="$(container_chown_trap /keystone3-firmware)"
  log_info "Running build ${label} (${TYPE}, ${JOBS} jobs)."
  run_ctr "build-${label}" \
    -e BUILD_VARIANT="${variant}" \
    -e WS_JOBS="${JOBS}" \
    -e CARGO_BUILD_JOBS="${JOBS}" \
    -v "${source_dir}:/keystone3-firmware" \
    -v "${WORK_DIR}/bin:/opt/wsbin:ro" \
    "${IMAGE_TAG}" \
    bash -c "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      export PATH=/opt/wsbin:\${PATH}
      cd /keystone3-firmware
      if [ -n \"\${BUILD_VARIANT}\" ]; then
        python3 build.py -e production -t \"\${BUILD_VARIANT}\"
      else
        python3 build.py -e production
      fi
    "
  if [[ ! -f "${source_dir}/build/mh1903.bin" ]]; then
    die_ftbfs "Build ${label} completed without build/mh1903.bin."
  fi
}

build_firmware_checker() {
  local chown_cmd
  chown_cmd="$(container_chown_trap /keystone3-firmware)"
  log_info "Building upstream firmware-checker (fmc) from the checked-out source."
  run_ctr "fmc-build" \
    -e CARGO_BUILD_JOBS="${JOBS}" \
    -v "${WORK_DIR}/source-a:/keystone3-firmware" \
    "${IMAGE_TAG}" \
    bash -c "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      cd /keystone3-firmware/tools/code/firmware-checker
      cargo build --release
    "
}

stage_official_firmware() {
  local url user_args=()
  mapfile -t user_args < <(container_user_args)
  if [[ -n "${BINARY_PATH}" ]]; then
    log_info "Using provided official firmware: ${BINARY_PATH}"
    cp "${BINARY_PATH}" "${WORK_DIR}/official-keystone3.bin"
    return
  fi
  url="$(official_url)"
  log_info "Downloading official firmware: ${url}"
  run_ctr "download" \
    "${user_args[@]}" \
    -v "${WORK_DIR}:/work" \
    "${GIT_IMAGE_TAG}" \
    wget -O /work/official-keystone3.bin --user-agent='Mozilla/5.0' --tries=3 --timeout=30 "${url}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

# fmc decompresses the OTA payload and hashes it up to the firmware end marker.
extract_official_payload_hash() {
  local output payload
  output="$("${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}/source-a:/keystone3-firmware" \
    -v "${WORK_DIR}/official-keystone3.bin:/official-keystone3.bin:ro" \
    "${IMAGE_TAG}" \
    /keystone3-firmware/tools/code/firmware-checker/target/release/fmc --source /official-keystone3.bin)"
  printf '%s\n' "${output}" >&2
  payload="$(printf '%s\n' "${output}" | awk '/Firmware checksum sha256:/ {print $4; exit}')"
  if [[ ! "${payload}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    die_ftbfs "firmware-checker did not return a parseable official payload hash."
  fi
  echo "${payload,,}"
}

# Informational cross-check with upstream's stdlib-only OTA restore tool (3.1.x+): it
# verifies the OTA header hashes while decompressing, then this hashes the restored image
# up to the 4 KiB sector holding the 'mh1903append' end marker, as the device does.
cross_check_payload() {
  local tool="${WORK_DIR}/source-a/tools/ota_bin_restore/ota_bin_restore.py"
  if [[ ! -f "${tool}" ]]; then
    log_info "Tag ${VERSION} has no tools/ota_bin_restore; cross-check skipped."
    return 0
  fi
  "${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}:/work" \
    "${IMAGE_TAG}" \
    bash -c '
      set -e
      cd /work
      python3 source-a/tools/ota_bin_restore/ota_bin_restore.py official-keystone3.bin official-restored.bin
      python3 - <<PY
import hashlib
d = open("official-restored.bin", "rb").read()
end = -1
for i in range(0, len(d), 4096):
    if d[i:i+12] == b"mh1903append": end = i + 4096; break
boot = any(d[i:i+16] == b"mh1903bootupdate" for i in range(0, len(d), 4096))
print("restoredImageSha256:   %s (%d bytes, OTA header hashes verified)" % (hashlib.sha256(d).hexdigest(), len(d)))
if end < 0:
    print("restoredPayloadSha256: end marker not found")
else:
    print("restoredPayloadSha256: %s (%d bytes up to the mh1903append sector)" % (hashlib.sha256(d[:end]).hexdigest(), end))
print("bootloaderBlock:       %s" % ("present (signed boot image appended by the vendor, not in the repository)" if boot else "absent"))
PY
    ' || log_warn "ota_bin_restore cross-check failed; fmc result stands on its own."
}

print_results_block() {
  local verdict="$1" official_hash="$2" build_a_hash="$3" build_b_hash="$4"
  local official_payload_hash="$5" ab_match="$6" official_match="$7"
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
  echo "official-payload-vs-build-a - ${ARCH}-${TYPE} - ${official_payload_hash} - ${official_match}"
  echo
  echo "SUMMARY"
  echo "buildAHash:            ${build_a_hash}"
  echo "buildBHash:            ${build_b_hash}"
  echo "officialPackageHash:   ${official_hash}"
  echo "officialPayloadHash:   ${official_payload_hash}"
  echo "officialFile:          keystone3.bin"
  echo "builtFile:             build/mh1903.bin"
  echo
  echo "Hash legend: appHash/officialPackageHash is the official keystone3.bin exactly as"
  echo "downloaded (publish this one). officialPayloadHash is the decompressed firmware"
  echo "inside it as computed by upstream's firmware-checker; it equals the checksum the"
  echo "device displays and is what build/mh1903.bin must match. Never publish it as appHash."
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
  echo "Verifying Keystone 3 Pro firmware v${VERSION} (${TYPE}, ${ARCH})"
  echo

  build_git_helper_image
  preflight_official_firmware
  prepare_sources
  build_upstream_image
  write_make_shim
  run_firmware_build "${WORK_DIR}/source-a" "A"
  run_firmware_build "${WORK_DIR}/source-b" "B"

  local buildAHash buildBHash officialHash officialPayloadHash finalVerdict officialMatch exitCode notes
  buildAHash="$(sha256_file "${WORK_DIR}/source-a/build/mh1903.bin")"
  buildBHash="$(sha256_file "${WORK_DIR}/source-b/build/mh1903.bin")"

  if [[ "${buildAHash}" != "${buildBHash}" ]]; then
    echo "A/B DETERMINISM: FAIL build_a_sha256=${buildAHash} build_b_sha256=${buildBHash}"
    print_results_block "not_reproducible" "not_checked" "${buildAHash}" "${buildBHash}" "not_checked" "0 (DOESN'T MATCH)" "0 (NOT CHECKED)"
    write_results "not_reproducible" "Keystone 3 Pro v${VERSION} (${TYPE}): A/B determinism failed before official comparison. Build A and build B produced different build/mh1903.bin hashes. Compare source-a/build and source-b/build in the workspace."
    exit "${EXIT_FAIL}"
  fi
  echo "A/B DETERMINISM: PASS build_a_sha256=${buildAHash} build_b_sha256=${buildBHash}"

  build_firmware_checker
  stage_official_firmware
  officialHash="$(sha256_file "${WORK_DIR}/official-keystone3.bin")"
  officialPayloadHash="$(extract_official_payload_hash)"

  if [[ "${buildAHash,,}" == "${officialPayloadHash,,}" ]]; then
    finalVerdict="reproducible"; officialMatch="1 (MATCHES)"; exitCode="${EXIT_OK}"
  else
    finalVerdict="not_reproducible"; officialMatch="0 (DOESN'T MATCH)"; exitCode="${EXIT_FAIL}"
  fi

  print_results_block "${finalVerdict}" "${officialHash}" "${buildAHash}" "${buildBHash}" "${officialPayloadHash}" "1 (MATCHES)" "${officialMatch}"
  echo
  echo "CROSS-CHECK (upstream tools/ota_bin_restore, informational)"
  cross_check_payload

  if [[ "${finalVerdict}" == "reproducible" ]]; then
    notes="Keystone 3 Pro v${VERSION} (${TYPE}) reproduced. Two independent builds of the upstream Dockerfile produced the same build/mh1903.bin hash, and the official keystone3.bin payload decompressed with upstream's firmware-checker matched it. The official package itself differs from the payload by design: QuickLZ compression, an OTA header carrying the vendor signature, and a signed bootloader block that is not in the repository."
  else
    notes="Keystone 3 Pro v${VERSION} (${TYPE}) did not reproduce. A/B determinism passed, but the official keystone3.bin payload decompressed with upstream's firmware-checker did not match build A's build/mh1903.bin. Compare source-a/build/mh1903.bin with official-restored.bin in the workspace."
  fi
  write_results "${finalVerdict}" "${notes}"
  exit "${exitCode}"
}

main "$@"
