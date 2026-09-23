#!/bin/bash
# ==============================================================================
# coldcard_build.sh - Coldcard (Mk4 / Mk5 / Q) Reproducible Build Verifier
# ==============================================================================
# Version: v4.1.4
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-08-06
# Project: https://github.com/Coldcard/firmware
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided. Please examine this
# script yourself before running it.
#
# SCOPE: Coldcard Mk4 / Mk5 (--type mk4) and Q / Q1 (--type q1), standard and
# Edge tracks. Mk2 and Mk3 (--type mk3) are NOT supported: their fix release
# v4.2.0 is published as a binary with source on master but carries no git tag,
# so there is nothing to pin a verification to. See changelog.
#
# SCRIPT SUMMARY:
# - Clones Coldcard/firmware inside a container and resolves the release tag.
# - Builds the toolchain image from the repository's own stm32/dockerfile.build.
# - Downloads the official .dfu from coldcard.com and checks it against the
#   hash Coinkite records in releases/signatures.txt before using it.
# - Rebuilds the firmware inside the container, reproducing the logic of
#   upstream stm32/repro-build.sh instead of invoking that script, so the build
#   this script performs is fixed by this file and cannot drift upstream.
# - Compares the rebuild against the official image using the same signature
#   masking upstream uses in stm32/shared.mk (check-repro).
#
# UPSTREAM SOURCES INLINED (Coldcard/firmware commit
# c849c4e04a978335937a0fd0c96e76f5bd70bbb6, fetched 2026-08-05):
#   stm32/repro-build.sh    -> write_build_script(), lines marked [repro-build]
#   stm32/dockerfile.build  -> build_toolchain_image()
#   stm32/shared.mk:324-346 -> the check-repro comparison, marked [shared.mk]
#   stm32/shared.mk:62-79   -> rng-code-check, re-implemented in build.sh
# When Coldcard changes any of those, this script must be updated deliberately
# and its version incremented. That is the point: the verification must not
# change underneath us between runs.
#
# THE HASHES, AND WHICH ONE IS THE OFFICIAL ONE:
# Only Coinkite holds the firmware signing key, so a local build can never
# produce the signed bytes Coinkite ships. Upstream therefore compares hexdump
# TEXT of both images with the 128-byte signature block masked out. That makes
# several different "hashes of the Coldcard firmware" available, and only one
# of them is publishable:
#   appHash               the .dfu exactly as downloaded from coldcard.com.
#                         THE official download hash. Publish this one.
#   officialFirmwareHash  the firmware section split out of that .dfu, Coinkite
#                         signature still attached. A real binary, but not a
#                         published artifact.
#   builtFirmwareHash     the firmware section this script built. On a
#                         reproducible result, only its signature block differs
#                         from officialFirmwareHash.
#   officialComparisonHash / builtComparisonHash
#                         SHA-256 of hexdump TEXT FILES with the signature
#                         masked. These are not hashes of any binary and must
#                         never be published anywhere. Equality of these two is
#                         what "reproducible" means here.
# ==============================================================================

set -eEuo pipefail

SCRIPT_VERSION="v4.1.4"
APP_ID="coldcard"
REPO_URL="https://github.com/Coldcard/firmware.git"
DOWNLOAD_BASE="https://coldcard.com/downloads"

# Upstream stm32/dockerfile.build pins alpine:3.16.0 but pulls the ARM toolchain
# from the rolling alpine edge/testing repository, so the compiler version is not
# pinned by anything. Reproduced faithfully - changing it would mean verifying a
# build Coinkite does not perform. Recorded as a known hazard in the changelog.
BASE_IMAGE="alpine:3.16.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
MODEL=""
BINARY_PATH=""
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_USER_ARGS=()
TOOLS_IMAGE=""
BUILD_IMAGE=""

TAG=""
COMMIT=""
SHORT_VERSION=""
TAG_PREFIX=""
HW_MODEL=""
MKFILE=""
DFU_FILENAME=""
OFFICIAL_DFU_HASH=""
OFFICIAL_FW_HASH=""
BUILT_FW_HASH=""
OFFICIAL_CMP_HASH=""
BUILT_CMP_HASH=""
BUILT_DFU_HASH=""
DIFF_FILE=""
RNG_SOURCE="unknown"
RNG_UPSTREAM_CHECK="unknown"
RNG_DETAIL=""
FINAL_EXIT_CODE=0

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_fail() { echo -e "${RED}[FAIL] $*${NC}" >&2; }
log_ok()   { echo -e "${GREEN}[ OK ] $*${NC}"; }

# ── Results ───────────────────────────────────────────────────────────────────

write_results() {
  local verdict="$1" notes="${2:-}"
  notes="${notes//\\/ }"; notes="${notes//$'\r'/ }"
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

invalid_input() {
  local message="$1"
  log_fail "${message}"
  write_results "ftbfs" \
    "Coldcard verification could not start because the invocation was invalid: ${message} No firmware was built or compared."
  exit "${EXIT_INVALID}"
}

# Any unexpected failure still leaves a results file behind: a run that dies
# without one is indistinguishable from a crashed runner.
handle_err() {
  local rc=$?
  trap - ERR
  log_fail "Unexpected error (exit ${rc})."
  write_results "ftbfs" \
    "Coldcard ${MODEL:-unknown} v${VERSION:-unknown}: script failed before a verdict could be computed (exit ${rc}). Work dir: ${WORK_DIR:-unset}"
  exit "${EXIT_FAIL}"
}
trap handle_err ERR

cleanup() {
  [[ -z "${CONTAINER_CMD}" ]] && return 0
  # Only images this run created. A blanket `image prune` would delete other
  # verifications' layer caches on a shared build server.
  for img in "${BUILD_IMAGE}" "${TOOLS_IMAGE}"; do
    [[ -n "${img}" ]] && ${CONTAINER_CMD} rmi -f "${img}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# ── Usage / arguments ─────────────────────────────────────────────────────────

usage() {
  cat <<USAGE
coldcard_build.sh ${SCRIPT_VERSION} - Coldcard firmware reproducibility verifier

SYNOPSIS
  coldcard_build.sh --version VERSION --type MODEL [--binary FILE]

DESCRIPTION
  Rebuilds Coldcard firmware from the tagged public source inside a container
  and compares it against the official release, with the Coinkite signature
  block masked out of both (only Coinkite can produce that signature).

  --version   Firmware version without the v prefix. Standard and Edge tracks
              are both accepted: 5.6.0, 6.5.0X, 1.5.0Q, 6.6.0QX.
  --type      mk4 (Mk4/Mk5) or q1 (Q). mk3 is not supported - see SCOPE.
  --arch      Accepted and ignored; one architecture per model.
  --binary    Optional path to the official .dfu. Downloaded if not given.
  --apk       Accepted as an alias for --binary.
  --help      Show this help.

EXAMPLES
  coldcard_build.sh --version 5.6.0 --type mk4
  coldcard_build.sh --version 1.5.0Q --type q1
  coldcard_build.sh --version 6.5.0X --type mk4 --binary ./official.dfu

Exit codes: 0 = reproducible, 1 = not reproducible / ftbfs, 2 = invalid parameters.
USAGE
}

require_value() {
  if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    invalid_input "Missing value for $1."
  fi
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    invalid_input "No arguments were provided."
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
      --type)    require_value "$1" "${2:-}"; MODEL="$2";   shift 2 ;;
      --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --apk)     log_warn "--apk is not applicable to hardware; treating as --binary."
                 require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --arch)    require_value "$1" "${2:-}"
                 log_info "Ignoring --arch '$2' (one architecture per Coldcard model)."; shift 2 ;;
      --help|-h) usage; exit "${EXIT_OK}" ;;
      # Never fatal: the build server may pass parameters this script does not
      # implement, and that must not abort a verification.
      *) log_warn "Unknown argument: $1 (ignored)"; shift ;;
    esac
  done
}

validate_inputs() {
  if [[ -z "${VERSION}" ]]; then
    invalid_input "--version is required."
  fi
  # Constrains what reaches the workdir path (and therefore `rm -rf`) and the
  # tag/filename matching below. Coldcard versions are digits, dots and the
  # Q / X track suffixes only.
  if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*[A-Za-z]*$ ]]; then
    invalid_input "Invalid --version '${VERSION}'. Expected e.g. 5.6.0, 6.5.0X, 1.5.0Q, 6.6.0QX."
  fi

  if [[ -z "${MODEL}" ]]; then
    invalid_input "--type is required (mk4 or q1)."
  fi
  MODEL="${MODEL,,}"
  case "${MODEL}" in
    mk4|mk5|mk) MODEL="mk4" ;;
    q1|q)       MODEL="q1" ;;
    mk2|mk3)
      invalid_input "--type ${MODEL} is not supported. The Mk2/Mk3 fix release v4.2.0 has a published binary and source on master but no git tag in Coldcard/firmware, so there is no revision to verify against." ;;
    *)
      invalid_input "Invalid --type '${MODEL}'. Use mk4 or q1." ;;
  esac

  # Q builds carry a Q in the version; add it only when absent so Edge Q
  # versions (6.6.0QX) pass through untouched.
  if [[ "${MODEL}" == "q1" && "${VERSION}" != *Q* ]]; then
    VERSION="${VERSION}Q"
    log_info "Q model: using version ${VERSION}."
  fi

  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ ! -f "${BINARY_PATH}" ]]; then
      invalid_input "--binary file not found: ${BINARY_PATH}"
    fi
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    log_warn "Running as root. This script needs no privileges; artifacts will be root-owned."
  fi
}

detect_container_cmd() {
  # User mapping keeps build products in the work directory owned by the caller
  # rather than by root.
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    CONTAINER_RUN_USER_ARGS=(--userns=keep-id -e HOME=/tmp)
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    CONTAINER_RUN_USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
  else
    log_fail "Neither podman nor docker found. One of them is the only requirement."
    write_results "ftbfs" "No container runtime available; nothing was built."
    exit "${EXIT_FAIL}"
  fi
  log_info "Container runtime: ${CONTAINER_CMD}"
}

# ── Workspace ─────────────────────────────────────────────────────────────────

setup_workspace() {
  # Namespaced by version+model so parallel arch/type runs never collide.
  WORK_DIR="${PWD}/coldcard-work-${VERSION}-${MODEL}"
  # Image names must be lowercase; versions carry Q/X suffixes.
  local tag_suffix="${VERSION,,}-${MODEL,,}"
  TOOLS_IMAGE="coldcard-tools-${tag_suffix}"
  BUILD_IMAGE="coldcard-build-${tag_suffix}"
  DIFF_FILE="${WORK_DIR}/out/diff_firmware.txt"

  log_info "Work directory: ${WORK_DIR}"
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}/out" "${WORK_DIR}/built"
}

# ── Images ────────────────────────────────────────────────────────────────────

build_tools_image() {
  log_info "Building tools image ${TOOLS_IMAGE} (git + busybox utilities)..."
  # Everything except the container runtime runs inside a container; the host
  # needs no git, wget or coreutils.
  ${CONTAINER_CMD} build -t "${TOOLS_IMAGE}" - <<DOCKERFILE
FROM ${BASE_IMAGE}
RUN apk add --no-cache git openssl ca-certificates
WORKDIR /work
DOCKERFILE
}

build_toolchain_image() {
  # Reproduced from Coldcard/firmware stm32/dockerfile.build (master, fetched
  # 2026-08-05). Kept byte-equivalent in effect, including the unpinned
  # edge/testing toolchain repository, because deviating would mean verifying a
  # build Coinkite does not perform.
  log_info "Building toolchain image ${BUILD_IMAGE} from inlined stm32/dockerfile.build..."
  ${CONTAINER_CMD} build -t "${BUILD_IMAGE}" - <<DOCKERFILE
FROM ${BASE_IMAGE}
WORKDIR /work
RUN apk add --no-cache git python3 py-pip musl-dev make rsync autoconf automake libtool && \
    apk add gcc-arm-none-eabi newlib-arm-none-eabi --update-cache \
        --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing/
RUN ln -s /usr/bin/python3 /usr/bin/python
DOCKERFILE
}

# ── Clone and tag resolution ──────────────────────────────────────────────────

clone_repo() {
  log_info "Cloning ${REPO_URL} inside the container..."
  if ! ${CONTAINER_CMD} run --rm "${CONTAINER_RUN_USER_ARGS[@]}" \
        --volume "${WORK_DIR}:/work:rw" "${TOOLS_IMAGE}" \
        sh -c "git config --global --add safe.directory '*'; \
               git clone --quiet '${REPO_URL}' /work/repo && \
               git -C /work/repo tag > /work/out/tags.txt"; then
    log_fail "Clone failed."
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: could not clone ${REPO_URL}."
    exit "${EXIT_FAIL}"
  fi
}

resolve_tag() {
  # Coldcard tags look like 2026-04-18T1934-v6.5.0X: an ISO-ish date prefix and
  # the version. Matched by exact suffix in bash rather than by regex, so dots
  # in the version cannot match arbitrary characters.
  local line
  TAG=""
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" == *"-v${VERSION}" ]]; then
      # Tags sort chronologically because the date leads; keep the newest.
      [[ "${line}" > "${TAG}" ]] && TAG="${line}"
    fi
  done < "${WORK_DIR}/out/tags.txt"

  if [[ -z "${TAG}" ]]; then
    log_fail "No tag matches version ${VERSION}."
    echo "Tags containing '${VERSION}':"
    grep -F "${VERSION}" "${WORK_DIR}/out/tags.txt" | head -10 || echo "  (none)"
    # `ftbfs`, not a bespoke verdict: script_verifications.md allows exactly
    # reproducible / not_reproducible / ftbfs.
    write_results "ftbfs" \
      "Coldcard ${MODEL} v${VERSION}: no git tag in Coldcard/firmware matches this version, so there is no revision to build. No comparison was performed and this is NOT a hash mismatch. Coinkite occasionally ships a binary without tagging the source (e.g. Mk2/Mk3 v4.2.0)."
    exit "${EXIT_FAIL}"
  fi

  SHORT_VERSION="${TAG##*-v}"
  TAG_PREFIX="${TAG%%-v*}"
  if [[ -z "${SHORT_VERSION}" || -z "${TAG_PREFIX}" || "${TAG_PREFIX}" == "${TAG}" ]]; then
    log_fail "Tag '${TAG}' does not have the expected <date>-v<version> shape."
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: tag '${TAG}' could not be parsed into a date prefix and a version."
    exit "${EXIT_FAIL}"
  fi
  log_ok "Tag: ${TAG} (version ${SHORT_VERSION}, date prefix ${TAG_PREFIX})"
}

checkout_and_probe() {
  log_info "Checking out ${TAG} and probing the build layout..."
  ${CONTAINER_CMD} run --rm "${CONTAINER_RUN_USER_ARGS[@]}" \
    --volume "${WORK_DIR}:/work:rw" "${TOOLS_IMAGE}" \
    sh -c "git config --global --add safe.directory '*'; \
           git -C /work/repo checkout --quiet '${TAG}' && \
           git -C /work/repo rev-parse HEAD > /work/out/commit.txt && \
           ( [ -f /work/repo/stm32/MK4-Makefile ] && echo yes || echo no ) > /work/out/has_mk4_makefile.txt"

  COMMIT="$(<"${WORK_DIR}/out/commit.txt")"
  COMMIT="${COMMIT//[$'\t\r\n ']/}"

  # Coldcard renamed the Mk4 model id mk4 -> mk and MK4-Makefile -> MK-Makefile
  # in v5.5.0. Probe the checked-out tree rather than comparing version numbers,
  # which would be wrong for the Edge track.
  if [[ "${MODEL}" == "mk4" ]]; then
    if [[ "$(<"${WORK_DIR}/out/has_mk4_makefile.txt")" == "yes" ]]; then
      MKFILE="MK4-Makefile"; HW_MODEL="mk4"
    else
      MKFILE="MK-Makefile";  HW_MODEL="mk"
    fi
  else
    MKFILE="Q1-Makefile";    HW_MODEL="q1"
  fi
  log_ok "Commit ${COMMIT}, Makefile ${MKFILE}, hw model ${HW_MODEL}"
}

# ── Official artifact ─────────────────────────────────────────────────────────

resolve_official_filename() {
  # Coldcard's published filename has changed shape over time (mk4 -> mk at
  # v5.5.0) and its date prefix is the build time, not the tag time, so the
  # exact name is taken from releases/signatures.txt rather than assembled from
  # any template. Lines are "<sha256>  <filename>".
  local sig="${WORK_DIR}/repo/releases/signatures.txt"
  if [[ ! -f "${sig}" ]]; then
    log_fail "releases/signatures.txt is absent at ${TAG}."
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: releases/signatures.txt not present at tag ${TAG}; cannot determine the official filename."
    exit "${EXIT_FAIL}"
  fi

  local hash name match_count=0
  DFU_FILENAME=""; OFFICIAL_DFU_HASH=""
  while read -r hash name _rest; do
    [[ -z "${name:-}" ]] && continue
    [[ "${name}" == *factory* ]] && continue
    if [[ "${name}" == *"-v${SHORT_VERSION}-${HW_MODEL}-coldcard.dfu" ]]; then
      ((match_count += 1))
      if (( match_count == 1 )); then
        DFU_FILENAME="${name}"
        OFFICIAL_DFU_HASH="${hash}"
      fi
    fi
  done < "${sig}"

  if [[ -z "${DFU_FILENAME}" ]]; then
    log_fail "No entry in signatures.txt for v${SHORT_VERSION}-${HW_MODEL}."
    echo "Entries mentioning ${SHORT_VERSION}:"
    grep -F "${SHORT_VERSION}" "${sig}" | head -5 || echo "  (none)"
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: releases/signatures.txt at tag ${TAG} lists no ${HW_MODEL} firmware for this version."
    exit "${EXIT_FAIL}"
  fi
  if (( match_count > 1 )); then
    log_fail "More than one official artifact matches v${SHORT_VERSION}-${HW_MODEL}."
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: releases/signatures.txt at tag ${TAG} contains ${match_count} matching firmware entries. The script will not choose one arbitrarily."
    exit "${EXIT_FAIL}"
  fi
  if [[ ! "${DFU_FILENAME}" =~ ^[0-9A-Za-z._-]+$ ]]; then
    log_fail "Official filename contains unexpected characters: ${DFU_FILENAME}"
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: the matching filename in releases/signatures.txt is unsafe or malformed: ${DFU_FILENAME}"
    exit "${EXIT_FAIL}"
  fi
  if [[ ! "${OFFICIAL_DFU_HASH}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log_fail "The signatures.txt field for ${DFU_FILENAME} is not a SHA-256."
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: releases/signatures.txt does not provide a valid 64-character SHA-256 for ${DFU_FILENAME}. No download or comparison was attempted."
    exit "${EXIT_FAIL}"
  fi
  log_ok "Official artifact: ${DFU_FILENAME}"
}

stage_official_artifact() {
  local dest="/work/repo/releases/${DFU_FILENAME}"
  if [[ -n "${BINARY_PATH}" ]]; then
    log_info "Using supplied binary: ${BINARY_PATH}"
    ${CONTAINER_CMD} run --rm "${CONTAINER_RUN_USER_ARGS[@]}" \
      --volume "${WORK_DIR}:/work:rw" \
      --volume "${BINARY_PATH}:/input.dfu:ro" "${TOOLS_IMAGE}" \
      sh -c "cp /input.dfu '${dest}'"
  else
    log_info "Downloading ${DOWNLOAD_BASE}/${DFU_FILENAME}"
    if ! ${CONTAINER_CMD} run --rm "${CONTAINER_RUN_USER_ARGS[@]}" \
          --volume "${WORK_DIR}:/work:rw" "${TOOLS_IMAGE}" \
          sh -c "wget -q -O '${dest}' '${DOWNLOAD_BASE}/${DFU_FILENAME}'"; then
      log_fail "Download failed."
      write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: could not download ${DFU_FILENAME} from ${DOWNLOAD_BASE}. Not a hash mismatch; no comparison was performed. Supply the file with --binary to retry offline."
      exit "${EXIT_FAIL}"
    fi
  fi

  local actual
  ${CONTAINER_CMD} run --rm "${CONTAINER_RUN_USER_ARGS[@]}" \
    --volume "${WORK_DIR}:/work:rw" "${TOOLS_IMAGE}" \
    sh -c "sha256sum '${dest}' | cut -d' ' -f1 > /work/out/official_dfu_hash.txt"
  actual="$(<"${WORK_DIR}/out/official_dfu_hash.txt")"
  actual="${actual//[$'\t\r\n ']/}"

  if [[ "${actual,,}" != "${OFFICIAL_DFU_HASH,,}" ]]; then
    log_fail "Official artifact does not match the hash Coinkite records in signatures.txt."
    echo "  signatures.txt: ${OFFICIAL_DFU_HASH}"
    echo "  actual:         ${actual}"
    write_results "ftbfs" \
      "Coldcard ${MODEL} v${VERSION}: the ${DFU_FILENAME} obtained does not match the SHA-256 recorded for it in releases/signatures.txt at tag ${TAG} (expected ${OFFICIAL_DFU_HASH}, got ${actual}). No build comparison was performed. Investigate before publishing anything."
    exit "${EXIT_FAIL}"
  fi
  log_ok "Official artifact matches signatures.txt: ${actual}"
  OFFICIAL_DFU_HASH="${actual}"
}

# ── Build and compare ─────────────────────────────────────────────────────────

write_build_script() {
  # Reproduction of Coldcard/firmware stm32/repro-build.sh at commit
  # c849c4e04a978335937a0fd0c96e76f5bd70bbb6 plus the check-repro recipe
  # from stm32/shared.mk:324-346 and rng-code-check from stm32/shared.mk:62-79.
  # Upstream is deliberately NOT invoked: a verification whose build steps can
  # change upstream between two runs is not a fixed measurement.
  #
  # Deviations from upstream, all intentional:
  #  - the checkout is pinned with an explicit `git checkout <commit>`; upstream
  #    relies on `git clone` inheriting a detached HEAD, which is implicit.
  #  - `make check-repro` is replaced by the same commands run directly, so the
  #    diff can be captured to a file instead of only reaching the log.
  #  - the exact verified official filename is passed in; upstream selects the
  #    first filename matching a version/model glob.
  #  - the download branch of upstream's script is unreachable here: the
  #    official .dfu is already staged in releases/ by stage_official_artifact,
  #    which also verifies it against signatures.txt (upstream does not).
  cat > "${WORK_DIR}/build.sh" <<'BUILDSCRIPT'
#!/bin/sh
set -ex

VERSION_STRING="$1"
HW_MODEL="$2"
PARENT_MKFILE="$3"
COMMIT="$4"
OFFICIAL_FILENAME="$5"

VENV_PATH="/tmp/ENV"
MAKE="make -f $PARENT_MKFILE"
TARGETS="firmware-signed.bin firmware-signed.dfu production.bin dev.dfu firmware.lss firmware.elf"
BYPRODUCTS="check-fw.bin check-bootrom.bin repro-got.txt repro-want.txt file_time.c"

git config --global --add safe.directory '*'

# [repro-build] /work/src is mounted read-only, so upstream's read-only branch
# is the one that always runs: build from a local clone under /tmp.
mkdir -p /tmp/checkout
cd /tmp/checkout
git clone --quiet /work/src/.git firmware
cd firmware
git checkout --quiet "$COMMIT"
cd external
git submodule update --init
cd ..
mkdir -p releases
rsync --ignore-missing-args -a /work/src/releases/20*.dfu releases/ || true

# [repro-build] signit.py must be on PATH for the comparison step.
cd cli
python -m venv "$VENV_PATH"
. "$VENV_PATH/bin/activate"
python -m pip install -r requirements.txt
python -m pip install --editable .
cd ../stm32

# [repro-build] The build timestamp is taken from the published binary's
# filename, which is what makes the rebuild time-independent.
case "$OFFICIAL_FILENAME" in
    ""|*/*) echo "ERROR: unsafe or empty official filename"; exit 3 ;;
esac
PUBLISHED_BIN="../releases/$OFFICIAL_FILENAME"
if [ ! -f "$PUBLISHED_BIN" ]; then
    echo "ERROR: exact official .dfu missing from releases/ inside container: $OFFICIAL_FILENAME"
    exit 3
fi
PUBLISHED_BIN=$(realpath "$PUBLISHED_BIN")

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    DT=$(basename "$PUBLISHED_BIN" | cut -d "-" -f1,2,3)
    SOURCE_DATE_EPOCH=$(python -c 'import datetime, sys; sys.stdout.write(str(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H%M").timestamp())))' "$DT")
    export SOURCE_DATE_EPOCH
fi

$MAKE setup
$MAKE DEBUG_BUILD=0 all
$MAKE $TARGETS

# ── RNG linkage check ─────────────────────────────────────────────────────────
# Informational; never fails the build and never changes the verdict.
#
# The 2026-07-30 advisory: MICROPY_HW_ENABLE_RNG=0 caused seed generation to
# resolve to MicroPython's Yasmarang software PRNG instead of the STM32
# hardware TRNG, giving ~72 bits of entropy instead of 128, from March 2021.
# Coinkite's fix (commit ca7246370, 2026-07-31) added a link-time assertion,
# `rng-code-check` in stm32/shared.mk, wired into the `all` target. That runs
# automatically above for FIXED firmware and fails the build if violated.
# Re-implemented here so PRE-FIX versions - where the target does not exist -
# get the same assertion and can be labelled too.
#
# The discriminator, straight from that commit:
#   fixed:  micropython's stm32/rng.o defines NO symbols (the PRNG was not
#           compiled in) AND the board's own rng.o defines a global T rng_get.
#   pre-fix: micropython's rng.o carries the Yasmarang symbols, and the board
#           rng.o has no rng_get, because the fix is what added it.
# This proves what the BUILD links. It says nothing about the quality of the
# hardware TRNG itself, and it is not a randomness test.
set +e
RNG_SOURCE=indeterminate
RNG_DETAIL="rng.o objects not found in the build tree"
RNG_UPSTREAM_CHECK=absent
grep -q 'rng-code-check' shared.mk 2>/dev/null && RNG_UPSTREAM_CHECK=present

UPSTREAM_RNG_O=$(find /tmp/checkout/firmware -name rng.o -path '*/build-*' ! -path '*/boards/*' 2>/dev/null | head -1)
BOARD_RNG_O=$(find /tmp/checkout/firmware -name rng.o -path '*/build-*/boards/*' 2>/dev/null | head -1)

if [ -n "$UPSTREAM_RNG_O" ] && [ -n "$BOARD_RNG_O" ]; then
    # nm exit status is checked separately from its output: a failed nm prints
    # nothing, and treating "no symbols" as evidence would silently turn a
    # broken toolchain into a weak-seed accusation.
    UPSTREAM_SYMS=$(arm-none-eabi-nm --defined-only "$UPSTREAM_RNG_O" 2>/dev/null)
    UPSTREAM_NM_RC=$?
    BOARD_SYMS=$(arm-none-eabi-nm --defined-only "$BOARD_RNG_O" 2>/dev/null)
    BOARD_NM_RC=$?

    printf '%s\n' "$UPSTREAM_SYMS" > /work/built/rng_micropython_symbols.txt
    printf '%s\n' "$BOARD_SYMS"    > /work/built/rng_board_symbols.txt

    HAS_RNG_GET=no
    printf '%s\n' "$BOARD_SYMS" | grep -Eq '^[[:xdigit:]]+[[:space:]]+T[[:space:]]+rng_get$' && HAS_RNG_GET=yes
    UPSTREAM_SYM_COUNT=$(printf '%s' "$UPSTREAM_SYMS" | grep -c .)

    # Three outcomes, not two. Only the two clean patterns are claims; anything
    # else - nm failure, or a mixed state matching neither - is indeterminate.
    if [ "$UPSTREAM_NM_RC" -ne 0 ] || [ "$BOARD_NM_RC" -ne 0 ]; then
        RNG_SOURCE=indeterminate
        RNG_DETAIL="arm-none-eabi-nm failed (upstream rc=$UPSTREAM_NM_RC, board rc=$BOARD_NM_RC) - no conclusion drawn"
    elif [ "$UPSTREAM_SYM_COUNT" -eq 0 ] && [ "$HAS_RNG_GET" = yes ]; then
        RNG_SOURCE=hardware-TRNG
        RNG_DETAIL="board rng.o defines global rng_get and micropython rng.o defines no symbols, so MicroPython's Yasmarang fallback is not linked in"
    elif [ "$UPSTREAM_SYM_COUNT" -gt 0 ] && [ "$HAS_RNG_GET" = no ]; then
        RNG_SOURCE=micropython-PRNG
        RNG_DETAIL="micropython rng.o defines $UPSTREAM_SYM_COUNT symbols and board rng.o has no global rng_get - the pre-fix pattern"
    else
        RNG_SOURCE=indeterminate
        RNG_DETAIL="mixed state matching neither pattern - micropython rng.o symbols: $UPSTREAM_SYM_COUNT, board global rng_get: $HAS_RNG_GET"
    fi
fi

{
  echo "RNG_SOURCE=${RNG_SOURCE}"
  echo "RNG_UPSTREAM_CHECK=${RNG_UPSTREAM_CHECK}"
  echo "RNG_DETAIL=${RNG_DETAIL}"
} > /work/built/rng.env
set -e

# [shared.mk:324-346] check-repro, inlined. The published image is signed with
# a key only Coinkite holds, so the 128-byte signature block at 0x3f80 is
# masked out of both sides before comparison.
signit split "$PUBLISHED_BIN" check-fw.bin check-bootrom.bin
signit check check-fw.bin
signit check firmware-signed.bin
hexdump -C firmware-signed.bin | sed -e 's/^00003f[89abcdef]0 .*/(firmware signature here)/' > repro-got.txt
hexdump -C check-fw.bin        | sed -e 's/^00003f[89abcdef]0 .*/(firmware signature here)/' > repro-want.txt

set +e
diff repro-got.txt repro-want.txt > /work/built/diff_firmware.txt
set -e

{
  echo "OFFICIAL_FW_HASH=$(sha256sum check-fw.bin | cut -d' ' -f1)"
  echo "BUILT_FW_HASH=$(sha256sum firmware-signed.bin | cut -d' ' -f1)"
  echo "OFFICIAL_CMP_HASH=$(sha256sum repro-want.txt | cut -d' ' -f1)"
  echo "BUILT_CMP_HASH=$(sha256sum repro-got.txt | cut -d' ' -f1)"
  echo "BUILT_DFU_HASH=$(sha256sum firmware-signed.dfu | cut -d' ' -f1)"
} > /work/built/hashes.env

rsync -a --ignore-missing-args $TARGETS $BYPRODUCTS /work/built/ || true
BUILDSCRIPT
  chmod +x "${WORK_DIR}/build.sh"
}

run_build() {
  log_info "Building firmware (this typically takes 10-20 minutes)..."
  # No --privileged: nothing in the inlined upstream logic needs host
  # privileges, and the build server runs this unattended.
  if ! ${CONTAINER_CMD} run --rm "${CONTAINER_RUN_USER_ARGS[@]}" \
        --volume "${WORK_DIR}/repo:/work/src:ro" \
        --volume "${WORK_DIR}/built:/work/built:rw" \
        --volume "${WORK_DIR}/build.sh:/build.sh:ro" \
        "${BUILD_IMAGE}" \
        sh /build.sh "${SHORT_VERSION}" "${HW_MODEL}" "${MKFILE}" "${COMMIT}" "${DFU_FILENAME}"; then
    log_fail "Firmware build failed."
    write_results "ftbfs" \
      "Coldcard ${MODEL} v${VERSION}: the firmware failed to build from source at tag ${TAG} (commit ${COMMIT}). No comparison was performed; this is NOT a hash mismatch. Build output is in ${WORK_DIR}."
    exit "${EXIT_FAIL}"
  fi
  log_ok "Build completed."
}

load_hashes() {
  local env_file="${WORK_DIR}/built/hashes.env"
  if [[ ! -f "${env_file}" ]]; then
    log_fail "Build produced no hashes.env."
    write_results "ftbfs" "Coldcard ${MODEL} v${VERSION}: the build container exited successfully but produced no hashes; nothing could be compared."
    exit "${EXIT_FAIL}"
  fi
  # shellcheck disable=SC1090
  . "${env_file}"
  DIFF_FILE="${WORK_DIR}/built/diff_firmware.txt"

  # Informational only. Absent rng.env is not an error: it just means the
  # linkage check could not run, and the verdict does not depend on it.
  #
  # PARSED AS TEXT, NEVER SOURCED. RNG_DETAIL is free prose containing spaces
  # and semicolons; `.` would execute it as shell and abort the run with ftbfs
  # before the real verdict was ever written. Only the three known keys are
  # accepted, and only the first `=` splits.
  local rng_file="${WORK_DIR}/built/rng.env" line key value
  RNG_SOURCE="unknown"; RNG_UPSTREAM_CHECK="unknown"; RNG_DETAIL=""
  if [[ -f "${rng_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      key="${line%%=*}"
      value="${line#*=}"
      [[ "${key}" == "${line}" ]] && continue
      case "${key}" in
        RNG_SOURCE)         RNG_SOURCE="${value}" ;;
        RNG_UPSTREAM_CHECK) RNG_UPSTREAM_CHECK="${value}" ;;
        RNG_DETAIL)         RNG_DETAIL="${value}" ;;
        *) ;;
      esac
    done < "${rng_file}"
  else
    log_warn "No rng.env from the build; RNG linkage is unknown for this run."
  fi
}

# ── Output ────────────────────────────────────────────────────────────────────

print_hash_legend() {
  cat <<LEGEND

----- What these hashes mean -----
appHash                 SHA-256 of the .dfu exactly as downloaded from
                        coldcard.com, and the value Coinkite records in
                        releases/signatures.txt. THIS is the official download
                        hash - it is the one to publish.
officialFirmwareHash    The firmware section split out of that .dfu by
                        'signit split', Coinkite's signature still attached.
                        A real binary, but not a published artifact.
builtFirmwareHash       The firmware section this script built. When the result
                        is reproducible, all bytes outside the signature block
                        match officialFirmwareHash. The complete hashes remain
                        unequal because only Coinkite can create its signature.
officialComparisonHash  SHA-256 of a hexdump TEXT FILE of the official firmware
builtComparisonHash     with the 128-byte signature block masked out, and the
                        same for the local build. These are NOT hashes of any
                        binary. Do not publish them anywhere.
builtSignedDfuHash      The .dfu this build produced, carrying a development
                        signing key (pubkey_num 0 rather than Coinkite's 1).
                        Never equal to appHash by design.

rngSource / rngCheck are INFORMATIONAL and never change the verdict.
Coinkite's 2026-07-30 advisory: seed generation resolved to MicroPython's
Yasmarang software PRNG instead of the STM32 hardware TRNG from March 2021,
giving affected seeds ~72 bits of entropy rather than 128. rngSource reports
which RNG this build actually links, using the same link-time symbol assertion
Coinkite added in their fix (rng-code-check, stm32/shared.mk): micropython's
rng.o must define no symbols and the board's rng.o must define a global
rng_get. rngCheck says whether that target exists in this source tree at all -
'absent' means pre-fix source, so only our copy of the check ran.

This proves what the BUILD links, not how good the hardware TRNG is; it is NOT
a randomness test, and a statistical test would not have caught this defect,
because a PRNG is designed to look random. It is the reproducible result that
carries the finding across to Coinkite's shipped binary: identical bytes mean
the firmware they signed is the firmware whose RNG linkage was checked here.

A version can be REPRODUCIBLE and still be affected - 6.5.0X is exactly that.

REPRODUCIBLE means officialComparisonHash == builtComparisonHash: the firmware
Coinkite signed is built by the public source at this tag. 'signit check' reports
signature validity using the public keys bundled in the source; only creating a
Coinkite signature would require their private key.
----------------------------------
LEGEND
}

print_results() {
  local verdict="$1"

  print_hash_legend
  echo
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "script_version: ${SCRIPT_VERSION}"
  echo "apkVersionName: ${VERSION}"
  echo "apkVersionCode: ${SHORT_VERSION}"
  echo "type:           ${MODEL}"
  echo "hwModel:        ${HW_MODEL}"
  echo "signer:         N/A (firmware signed by Coinkite; private signing key not public)"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${OFFICIAL_DFU_HASH}"
  echo "                  hash of the .dfu as downloaded - the publishable value"
  echo "officialFirmwareHash: ${OFFICIAL_FW_HASH:-unavailable}"
  echo "                  official firmware section, Coinkite signature attached"
  echo "builtFirmwareHash:    ${BUILT_FW_HASH:-unavailable}"
  echo "                  our build; on a reproducible result, only the signature differs"
  echo "officialComparisonHash: ${OFFICIAL_CMP_HASH:-unavailable}"
  echo "                  hexdump text, signature masked - never publish"
  echo "builtComparisonHash:   ${BUILT_CMP_HASH:-unavailable}"
  echo "                  hexdump text, signature masked - never publish"
  echo "builtSignedDfuHash:    ${BUILT_DFU_HASH:-unavailable}"
  echo "                  our .dfu, development signing key"
  echo "repository:     ${REPO_URL}"
  echo "tag:            ${TAG}"
  echo "commit:         ${COMMIT}"
  echo "officialFile:   ${DFU_FILENAME}"
  # Informational, never part of the verdict: a version can be perfectly
  # reproducible and still carry the weak-seed defect.
  case "${RNG_SOURCE:-unknown}" in
    hardware-TRNG)
      echo "rngSource:      hardware-TRNG" ;;
    micropython-PRNG)
      echo -e "rngSource:      micropython-PRNG  ${RED}*** WEAK SEED - see advisory 2026-07-30 ***${NC}" ;;
    *)
      echo "rngSource:      ${RNG_SOURCE:-unknown}" ;;
  esac
  echo "                  ${RNG_DETAIL:-no RNG linkage evidence collected}"
  echo "rngCheck:       ${RNG_UPSTREAM_CHECK:-unknown}"
  echo "                  whether upstream's own rng-code-check exists in this source tree"
  echo
  echo "Diff:"
  if [[ -s "${DIFF_FILE}" ]]; then
    local total
    total="$(wc -l < "${DIFF_FILE}")"
    # Max 5 lines in the terminal; the full diff goes to a file so a large
    # mismatch cannot swamp the build server log.
    head -5 "${DIFF_FILE}"
    if (( total > 5 )); then
      echo "... (${total} lines total)"
    fi
    echo "Full diff: ${DIFF_FILE}"
  else
    echo "(none - masked hexdumps are identical)"
  fi
  echo "===== End Results ====="
  echo
  echo "Artifacts:"
  echo "  Official firmware:      ${WORK_DIR}/repo/releases/${DFU_FILENAME}"
  echo "  Built firmware (.dfu):  ${WORK_DIR}/built/firmware-signed.dfu"
  echo "  Built firmware (.bin):  ${WORK_DIR}/built/firmware-signed.bin"
  echo "  Official (masked hex):  ${WORK_DIR}/built/repro-want.txt"
  echo "  Built (masked hex):     ${WORK_DIR}/built/repro-got.txt"
}

compare_and_report() {
  local verdict notes
  if [[ -n "${OFFICIAL_CMP_HASH:-}" && "${OFFICIAL_CMP_HASH}" == "${BUILT_CMP_HASH:-}" ]]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
  fi

  print_results "${verdict}"

  notes="Coldcard ${MODEL} (hw model ${HW_MODEL}) v${VERSION}, tag ${TAG}, commit ${COMMIT}.
Built from Coldcard/firmware with the upstream toolchain image (stm32/dockerfile.build) and the upstream build steps (stm32/repro-build.sh) reproduced inline in this script.
Comparison follows upstream check-repro (stm32/shared.mk): the 128-byte signature block is masked out of a hexdump of both images before comparison.
Official download hash (publish this one): ${OFFICIAL_DFU_HASH}
Expected differences (do not affect the verdict):
- The official .dfu is signed by Coinkite (pubkey_num 1); a local build carries a development key (pubkey_num 0). Signed artifacts can never match, which is why the signature block is masked."

  if [[ "${verdict}" == "reproducible" ]]; then
    log_ok "REPRODUCIBLE - the masked firmware images are identical."
    write_results "reproducible" "${notes}"
    FINAL_EXIT_CODE="${EXIT_OK}"
    return 0
  fi

  log_fail "NOT REPRODUCIBLE - the masked firmware images differ."
  notes="${notes}
Differences were found outside the masked signature block. Full diff: built/diff_firmware.txt in the work directory."
  write_results "not_reproducible" "${notes}"
  FINAL_EXIT_CODE="${EXIT_FAIL}"
  return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  # Remove any prior verdict before this invocation can fail. Every invalid or
  # failed verification path below writes a fresh result.
  rm -f "${RESULTS_FILE}"

  echo -e "${YELLOW}"
  echo "=============================================================================="
  echo "                               DISCLAIMER"
  echo "=============================================================================="
  echo "Please examine this script yourself prior to running it."
  echo "This script is provided as-is without warranty and may contain bugs or"
  echo "security vulnerabilities. Use at your own risk."
  echo "=============================================================================="
  echo -e "${NC}"

  parse_args "$@"
  validate_inputs
  detect_container_cmd

  log_info "Verifying Coldcard ${MODEL} firmware ${VERSION}"
  setup_workspace
  build_tools_image
  clone_repo
  resolve_tag
  checkout_and_probe
  resolve_official_filename
  stage_official_artifact
  build_toolchain_image
  write_build_script
  run_build
  load_hashes

  compare_and_report
}

# main must be invoked as a simple command. Putting it on the left of `||`
# disables errexit and the ERR trap throughout the function. A handled
# not_reproducible result is carried separately in FINAL_EXIT_CODE.
main "$@"
exit "${FINAL_EXIT_CODE}"
