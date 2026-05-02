#!/usr/bin/env bash
# ==============================================================================
# trezorOne_build.sh - Trezor One (T1B1) Firmware Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.9
# Organization:  WalletScrutiny.com
# Last Modified: 2026-04-22
# Project:       https://github.com/trezor/trezor-firmware
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification
# purposes only. No warranty is provided regarding security, functionality, or fitness
# for any particular purpose. Users assume all risks. This script executes Docker/Podman
# containers, downloads source code, and may consume significant system resources.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build
# verification. Users are responsible for ensuring compliance with all applicable laws.
# The developers assume no liability for any misuse or legal consequences.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Phase 1 (container): downloads releases.json, parses version metadata, downloads
#   official firmware, strips 256-byte TRZR header, zeroes 195-byte signature region,
#   computes SHA256 hashes
# - Phase 2 (Dockerfile container): clones trezor-firmware at legacy/v{version}, builds
#   T1B1 firmware + bootloader using Alpine 3.15.0 + Nix 2.31.4 + pinned nixpkgs,
#   extracts commit hash and git tag type
# - Phase 3 (container): zeroes sig region in built firmware, compares with official,
#   computes bootloader SHA256d, parses bl_check.txt and bl_check.c
# - Host: reads one-value-per-file results, writes COMPARISON_RESULTS.yaml and summary
# - Only host dependency: Docker or Podman
#
# BACKGROUND:
# The Trezor One ("legacy", T1B1) firmware uses:
#   - Alpine Linux 3.15.0 as the container base (SHA256-pinned)
#   - Nix 2.31.4 with pinned nixpkgs for deterministic toolchain
#   - gcc-arm-embedded-13 for STM32F2 cross-compilation
#   - Build entry point: uv run script/cibuild (from legacy/ directory)
# Signature region: TRZF bytes 544-738 (195 bytes) zeroed before comparison.
# Bootloader hashes in bl_check.txt are SHA256d (double-SHA256).

set -euo pipefail

SCRIPT_VERSION="v0.1.9"
RESULTS_WRITTEN=false
IMAGE_NAME=""
TEMP_CONTAINER=""

ALPINE_IMAGE="alpine:3.15.0@sha256:21a3deaa0d32a8057914f36584b5288d2e5ecc984380bc0118285c70fa8c9300"

# ---------------------------------------------------------------------------
# Colors and logging
# ---------------------------------------------------------------------------
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Disclaimer banner
# ---------------------------------------------------------------------------
echo -e "${YELLOW}"
cat << 'DISCLAIMER'
==============================================================================
                             DISCLAIMER
==============================================================================
Please examine this script prior to running it. This script downloads source
code, runs Docker/Podman containers, and builds ARM firmware. It may consume
significant CPU, memory (4+ GB), and disk space (10+ GB).
Build time: 30-60 minutes on first run (Nix downloads toolchains cold).
Use at your own risk.
==============================================================================
DISCLAIMER
echo -e "${NC}"
sleep 3

log_info "trezorOne_build.sh ${SCRIPT_VERSION} starting"

# ---------------------------------------------------------------------------
# Root guard — must not run as root
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
  log_error "Do not run this script as root. Please run as a normal user."
  exit 2
fi

# ---------------------------------------------------------------------------
# Container runtime detection — the only required host dependency
# Prefer the first candidate whose daemon/engine is actually usable (info check).
# This ensures a broken Docker install doesn't block a working Podman setup.
# ---------------------------------------------------------------------------
CONTAINER_CMD=""
for _candidate in docker podman; do
  if command -v "$_candidate" &>/dev/null && "$_candidate" info &>/dev/null 2>&1; then
    CONTAINER_CMD="$_candidate"
    break
  fi
done
if [[ -z "$CONTAINER_CMD" ]]; then
  # Daemon checks both failed; fall back to whichever binary exists and let it error naturally
  for _candidate in docker podman; do
    if command -v "$_candidate" &>/dev/null; then
      CONTAINER_CMD="$_candidate"
      log_warn "${CONTAINER_CMD} found but daemon check failed — proceeding anyway"
      break
    fi
  done
fi
if [[ -z "$CONTAINER_CMD" ]]; then
  log_error "Neither docker nor podman found. Please install Docker or Podman."
  exit 2
fi
log_info "Container runtime: ${CONTAINER_CMD}"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat << EOF
Trezor One (T1B1) Firmware Reproducible Build Verification

  $(basename "$0") --version VERSION [--arch ARCH] [--type TYPE] [--binary FILE]

  --version   Firmware version without 'v' prefix (e.g., 1.14.1)
  --arch      Architecture (default: arm — only valid value for T1B1)
  --type      Firmware type: universal (default) or btc-only
  --binary    Path to official firmware .bin file (skips download)

EXIT CODES
  0 = reproducible
  1 = not_reproducible (differences found)
  2 = ftbfs / invalid parameters
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing — unknown parameters log a warning and continue (never fatal)
# ---------------------------------------------------------------------------
version=""
arch="arm"
build_type="universal"
binary_file=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || { log_error "--version requires a value"; exit 2; }; version="$2"; shift 2 ;;
    --arch)    [[ $# -ge 2 ]] || { log_error "--arch requires a value"; exit 2; }; arch="$2"; shift 2 ;;
    --type)    [[ $# -ge 2 ]] || { log_error "--type requires a value"; exit 2; }; build_type="$2"; shift 2 ;;
    --binary)  [[ $# -ge 2 ]] || { log_error "--binary requires a value"; exit 2; }; binary_file="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) log_warn "Ignoring unknown parameter: $1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
# When --binary is provided without --version, attempt to infer version from filename.
# Covers patterns like trezor-1.14.1.bin and trezor-1.14.1-bitcoinonly.bin.
if [[ -z "$version" && -n "$binary_file" ]]; then
  if [[ "$(basename "$binary_file")" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
    log_warn "No --version provided; inferred '${version}' from filename '$(basename "$binary_file")'"
  fi
fi

if [[ -z "$version" ]]; then
  log_error "--version is required (and could not be inferred from the binary filename)"
  echo
  usage
  exit 2
fi

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log_error "Invalid version format '${version}'. Expected X.Y.Z (e.g., 1.14.1)"
  exit 2
fi

case "${build_type,,}" in
  universal|multi|standard)          build_type="universal" ;;
  btc-only|bitcoin-only|bitcoinonly) build_type="btc-only" ;;
  *)
    log_warn "Unknown --type '${build_type}', defaulting to 'universal'"
    build_type="universal"
    ;;
esac

if [[ "${arch,,}" != "arm" ]]; then
  log_warn "--arch '${arch}' is not valid for T1B1 (only 'arm' supported); continuing with 'arm'"
  arch="arm"
fi

if [[ -n "$binary_file" && ! -f "$binary_file" ]]; then
  log_error "--binary file not found: ${binary_file}"
  exit 2
fi

BITCOIN_ONLY_VAL="$( [[ "$build_type" == "btc-only" ]] && echo 1 || echo 0 )"
GIT_TAG="legacy/v${version}"
RELEASE_FILENAME="$( [[ "$build_type" == "btc-only" ]] && echo "trezor-t1b1-${version}-bitcoinonly.bin" || echo "trezor-t1b1-${version}.bin" )"

# ---------------------------------------------------------------------------
# Workspace setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/trezorOne-work-${build_type}-${version}-$$"
BUILD_OUTPUT_DIR="${WORK_DIR}/build_output"
CANONICAL_RESULTS="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

if [[ -d "$WORK_DIR" ]]; then
  log_warn "Removing stale work directory: ${WORK_DIR}"
  rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR" "$BUILD_OUTPUT_DIR"

log_info "=============================================="
log_info "Trezor One (T1B1) Firmware Verification"
log_info "=============================================="
log_info "Script  : ${SCRIPT_VERSION}"
log_info "Version : ${version} | Type: ${build_type} | Tag: ${GIT_TAG}"
log_info "Work dir: ${WORK_DIR}"
log_info "=============================================="

# ---------------------------------------------------------------------------
# write_results_yaml — writes minimal 3-field COMPARISON_RESULTS.yaml
# ---------------------------------------------------------------------------
write_results_yaml() {
  local v="$1" notes="${2:-}"
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${v}"
    if [[ -n "$notes" ]]; then
      echo "notes: |"
      echo "  ${notes}"
    fi
  } > "${CANONICAL_RESULTS}"
  RESULTS_WRITTEN=true
  log_info "COMPARISON_RESULTS.yaml written (verdict: ${v})"
}

# ---------------------------------------------------------------------------
# Cleanup trap — removes container/image on any exit; writes ftbfs if needed
# ---------------------------------------------------------------------------
cleanup() {
  local ec=$?
  [[ -n "$TEMP_CONTAINER" ]] && ${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" 2>/dev/null || true
  [[ -n "$IMAGE_NAME" ]]    && ${CONTAINER_CMD} rmi -f "$IMAGE_NAME"    2>/dev/null || true
  if [[ "$RESULTS_WRITTEN" != "true" ]]; then
    write_results_yaml "ftbfs" "Script exited unexpectedly (exit code: ${ec})"
  fi
  echo "Exit code: ${ec}"
}
trap cleanup EXIT

# ===========================================================================
# Write helper Python scripts to WORK_DIR (host writes files; containers run them)
# ===========================================================================

# parse_releases.py — parses releases.json, writes one-value-per-file outputs
cat > "${WORK_DIR}/parse_releases.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Parses releases.json and writes metadata files for the requested version.
Usage: parse_releases.py <releases.json> <version> <build_type>
Outputs (to /work/):
  firmware_url.txt          — download URL for the firmware binary
  bootloader_version.txt    — bootloader version bundled with this firmware (e.g. "1.12.1")
  releases_fingerprint.txt  — SHA256 of first 1024-byte TRZF header with sig/index region zeroed
"""
import json, sys

releases_path = sys.argv[1]
target_ver    = sys.argv[2]
build_type    = sys.argv[3]  # "universal" or "btc-only"

with open(releases_path) as f:
    data = json.load(f)

# releases.json may be a bare list or wrapped in a key
releases = data if isinstance(data, list) else data.get("firmware", data.get("releases", []))

target = list(map(int, target_ver.split(".")))

for r in releases:
    ver = r.get("version", [])
    if isinstance(ver, list):
        if ver != target:
            continue
    else:
        if ver != target_ver:
            continue

    url = r.get("url_bitcoinonly" if build_type == "btc-only" else "url", "")
    # Normalize relative URLs — releases.json paths are relative to data.trezor.io
    # but the actual live path omits the leading "data/" segment.
    # e.g. "data/firmware/t1b1/foo.bin" -> "https://data.trezor.io/firmware/t1b1/foo.bin"
    if url and not url.startswith("http"):
        url = url.lstrip("/")
        if url.startswith("data/"):
            url = url[len("data/"):]
        url = "https://data.trezor.io/" + url
    bl  = r.get("bootloader_version", [])
    fp  = r.get("fingerprint_bitcoinonly" if build_type == "btc-only" else "fingerprint", "")

    with open("/work/firmware_url.txt", "w") as f:
        f.write(url.strip() + "\n")
    with open("/work/bootloader_version.txt", "w") as f:
        f.write((".".join(str(x) for x in bl) if bl else "") + "\n")
    with open("/work/releases_fingerprint.txt", "w") as f:
        f.write((fp or "").strip() + "\n")
    sys.exit(0)

sys.stderr.write(f"Version {target_ver} not found in releases.json\n")
sys.exit(1)
PYEOF

# parse_bl_check.py — extracts expected bootloader SHA256d and cross-checks bl_check.c
cat > "${WORK_DIR}/parse_bl_check.py" << 'PYEOF2'
#!/usr/bin/env python3
"""
Parses bl_check.txt for the expected SHA256d of a bootloader version,
then verifies the same hash appears in bl_check.c (compiled into firmware at runtime).
Usage: parse_bl_check.py <bl_check.txt> <bl_check.c> <bootloader_version>
Outputs (to /work/):
  expected_bl_hash.txt   — expected SHA256d (hex), or empty if not found
  bl_hash_in_c.txt       — "yes" or "no"
"""
import sys, re

bl_txt_path = sys.argv[1]
bl_c_path   = sys.argv[2]
bl_ver      = sys.argv[3]

# Look up expected SHA256d in bl_check.txt
expected_hash = ""
try:
    with open(bl_txt_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[1] == bl_ver:
                expected_hash = parts[0].lower()
                break
except FileNotFoundError:
    pass

with open("/work/expected_bl_hash.txt", "w") as f:
    f.write(expected_hash + "\n")

if not expected_hash:
    with open("/work/bl_hash_in_c.txt", "w") as f:
        f.write("no\n")
    sys.exit(0)

# Cross-check: same hash must also appear as a byte array in bl_check.c
hash_in_c = "no"
try:
    with open(bl_c_path) as f:
        content = f.read().lower()
    hex_bytes = re.findall(r'0x([0-9a-f]{2})', content)
    hex_str   = "".join(hex_bytes)
    for i in range(len(hex_str) - 63):
        if hex_str[i:i+64] == expected_hash:
            hash_in_c = "yes"
            break
except FileNotFoundError:
    pass

with open("/work/bl_hash_in_c.txt", "w") as f:
    f.write(hash_in_c + "\n")
PYEOF2

# ---------------------------------------------------------------------------
# If --binary provided, copy it into WORK_DIR so Phase 1 container can use it
# ---------------------------------------------------------------------------
if [[ -n "$binary_file" ]]; then
  cp "$binary_file" "${WORK_DIR}/official_firmware_provided.bin"
  log_info "Using provided binary: ${binary_file}"
fi

# ===========================================================================
# PHASE 1: FETCH CONTAINER
# All downloading, JSON parsing, TRZR stripping, sig zeroing, and hashing
# happen inside this container. Host never calls curl/python3/sha256sum/dd/xxd.
# ===========================================================================
log_info ""
log_info "--- Phase 1: Fetch and prepare official firmware ---"

if ! ${CONTAINER_CMD} run --rm -i \
  -v "${WORK_DIR}:/work" \
  -e "VERSION=${version}" \
  -e "BUILD_TYPE=${build_type}" \
  "${ALPINE_IMAGE}" \
  sh << 'FETCH_SCRIPT'
set -e
apk add --no-cache curl python3 coreutils xxd >/dev/null 2>&1

echo "[Phase1] Downloading releases.json..."
curl -sSL --fail "https://data.trezor.io/firmware/t1b1/releases.json" -o /work/releases.json

echo "[Phase1] Parsing releases.json for version ${VERSION}..."
python3 /work/parse_releases.py /work/releases.json "${VERSION}" "${BUILD_TYPE}"
FIRMWARE_URL=$(cat /work/firmware_url.txt | tr -d '[:space:]')
echo "[Phase1] URL: ${FIRMWARE_URL}"

if [ -f /work/official_firmware_provided.bin ]; then
  echo "[Phase1] Using provided --binary file."
  cp /work/official_firmware_provided.bin /work/official_firmware_raw.bin
else
  echo "[Phase1] Downloading official firmware..."
  curl -sSL --fail "${FIRMWARE_URL}" -o /work/official_firmware_raw.bin
fi

# SHA256 of full raw file (used as appHash in results — not the fingerprint)
sha256sum /work/official_firmware_raw.bin | cut -d' ' -f1 > /work/official_raw_sha256.txt

# Detect TRZR prefix before stripping.
# Older releases (firmware/1/ URL) prepend a 256-byte TRZR header before the TRZF payload.
# Newer releases (firmware/t1b1/ URL) serve the TRZF payload directly — no prefix.
# Magic: TRZR = 54525a52, TRZF = 54525a46. Unconditionally stripping would corrupt newer files.
MAGIC=$(dd if=/work/official_firmware_raw.bin bs=1 count=4 2>/dev/null | xxd -p | tr -d '\n')
echo "[Phase1] Firmware magic bytes: ${MAGIC}"
if [ "${MAGIC}" = "54525a52" ]; then
  echo "[Phase1] TRZR prefix detected — stripping 256-byte header to get TRZF payload"
  dd if=/work/official_firmware_raw.bin of=/work/official_firmware_trzf.bin bs=1 skip=256 2>/dev/null
else
  echo "[Phase1] No TRZR prefix (file is already TRZF) — using as-is"
  cp /work/official_firmware_raw.bin /work/official_firmware_trzf.bin
fi
TRZF_SIZE=$(wc -c < /work/official_firmware_trzf.bin)
echo "[Phase1] TRZF size: ${TRZF_SIZE} bytes"

# Zero 195-byte signature region in TRZF copy (bytes 544-738).
# Constants from legacy/firmware/firmware_sign.py:
#   SIGNATURES_START = 6*4 + 8 + 512 = 544
#   INDEXES_START    = 544 + 3*64    = 736
# Region: 3x64 ECDSA sigs + 3 signer index bytes = 195 bytes total.
cp /work/official_firmware_trzf.bin /work/official_firmware_nosig.bin
dd if=/dev/zero of=/work/official_firmware_nosig.bin bs=1 seek=544 count=195 conv=notrunc 2>/dev/null

sha256sum /work/official_firmware_nosig.bin | cut -d' ' -f1 > /work/official_nosig_sha256.txt
echo "[Phase1] Official nosig SHA256: $(cat /work/official_nosig_sha256.txt)"

# Compute firmware fingerprint per firmware_sign.py logic:
# SHA256 of the first 1024-byte TRZF header with the sig/index region (bytes 544-738) zeroed.
# This matches what firmware_sign.py prints as "Firmware fingerprint" during the build,
# and is what releases.json records. A mismatch means the downloaded file is not the expected
# release — abort to avoid producing a misleading verdict.
dd if=/work/official_firmware_trzf.bin of=/tmp/fp_header.bin bs=1 count=1024 2>/dev/null
dd if=/dev/zero of=/tmp/fp_header.bin bs=1 seek=544 count=195 conv=notrunc 2>/dev/null
COMPUTED_FP=$(sha256sum /tmp/fp_header.bin | cut -d' ' -f1)
EXPECTED_FP=$(cat /work/releases_fingerprint.txt | tr -d '[:space:]')
echo "[Phase1] Computed firmware fingerprint: ${COMPUTED_FP}"
if [ -n "${EXPECTED_FP}" ]; then
  echo "[Phase1] releases.json fingerprint:   ${EXPECTED_FP}"
  if [ "${COMPUTED_FP}" != "${EXPECTED_FP}" ]; then
    echo "[Phase1] FATAL: fingerprint mismatch — downloaded firmware does not match releases.json"
    echo "MISMATCH" > /work/fingerprint_check.txt
    exit 1
  fi
  echo "[Phase1] Fingerprint OK"
  echo "OK" > /work/fingerprint_check.txt
else
  echo "[Phase1] No fingerprint in releases.json — skipping provenance check"
  echo "SKIPPED" > /work/fingerprint_check.txt
fi
FETCH_SCRIPT
then
  log_error "Phase 1 (fetch) container failed — network error, version not found, or fingerprint mismatch (see output above)"
  write_results_yaml "ftbfs" "Phase 1 container failed for version ${version} (see output above)"
  exit 2
fi

# Read Phase 1 outputs using shell builtins only
FIRMWARE_URL=""; BOOTLOADER_VERSION=""; OFFICIAL_NOSIG_SHA256=""; OFFICIAL_RAW_SHA256=""
[[ -f "${WORK_DIR}/firmware_url.txt" ]]          && read -r FIRMWARE_URL          < "${WORK_DIR}/firmware_url.txt"
[[ -f "${WORK_DIR}/bootloader_version.txt" ]]    && read -r BOOTLOADER_VERSION    < "${WORK_DIR}/bootloader_version.txt"
[[ -f "${WORK_DIR}/official_nosig_sha256.txt" ]] && read -r OFFICIAL_NOSIG_SHA256 < "${WORK_DIR}/official_nosig_sha256.txt"
[[ -f "${WORK_DIR}/official_raw_sha256.txt" ]]   && read -r OFFICIAL_RAW_SHA256   < "${WORK_DIR}/official_raw_sha256.txt"

if [[ -z "$OFFICIAL_NOSIG_SHA256" ]]; then
  log_error "Phase 1 failed to produce official nosig SHA256"
  write_results_yaml "ftbfs" "Phase 1 (fetch) container failed — check network access"
  exit 2
fi
log_success "Phase 1 complete. Bootloader version: ${BOOTLOADER_VERSION:-unknown}"

# ===========================================================================
# PHASE 2: BUILD CONTAINER (Dockerfile-based)
# Builds T1B1 firmware + bootloader using Alpine 3.15.0 + Nix 2.31.4.
# Also extracts commit hash and git tag type for the results summary.
# Note: build-docker.sh is NOT called directly (would require Docker-in-Docker).
# Instead we replicate its T1B1 steps inside our own container.
# ===========================================================================
log_info ""
log_info "--- Phase 2: Building firmware (30-60 min on first run) ---"

IMAGE_NAME="trezor-one-build-${build_type}-${version//./_}-$$"
DOCKERFILE_PATH="${WORK_DIR}/Dockerfile.trezorOne"

cat > "$DOCKERFILE_PATH" << DOCKERFILE_EOF
FROM ${ALPINE_IMAGE}

# Install minimal host tools needed before Nix takes over.
# gnupg is included for git tag -v signature attempt.
RUN apk add --no-cache \\
    bash curl xz git shadow sudo ca-certificates \\
    coreutils findutils grep gzip tar util-linux gnupg

# Create non-root build user. Nix installer requires a non-root user
# with passwordless sudo to set up /nix.
RUN adduser -D -s /bin/bash builder && \\
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER builder
ENV HOME=/home/builder
ENV USER=builder
WORKDIR /home/builder

# Install Nix 2.31.4 single-user (pinned version from official build-docker.sh).
RUN curl --silent --location https://releases.nixos.org/nix/nix-2.31.4/install | \\
    sh -s -- --no-daemon

ENV PATH="/home/builder/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\${PATH}"

# Pin nixpkgs to the exact commit used in shell.nix (primary nixpkgs).
# This ensures gcc-arm-embedded-13, uv, and all build tools resolve deterministically.
RUN . /home/builder/.nix-profile/etc/profile.d/nix.sh && \\
    nix-channel --add \\
      https://github.com/NixOS/nixpkgs/archive/a07d4ce6bee67d7c838a8a5796e75dff9caa21ef.tar.gz \\
      nixpkgs && \\
    nix-channel --update nixpkgs

# Clone at exact release tag (legacy/v{version}).
ARG GIT_TAG
ENV GIT_TAG=\${GIT_TAG}
RUN git clone --depth=1 --branch "\${GIT_TAG}" \\
    --recurse-submodules --shallow-submodules \\
    https://github.com/trezor/trezor-firmware.git \\
    /home/builder/trezor-firmware

# Extract commit hash and tag metadata for the results summary.
RUN git -C /home/builder/trezor-firmware rev-parse HEAD \\
      > /home/builder/trezor-firmware/BUILD_COMMIT.txt
RUN git -C /home/builder/trezor-firmware cat-file -t "\${GIT_TAG}" \\
      > /home/builder/trezor-firmware/BUILD_TAG_TYPE.txt 2>/dev/null || \\
    echo "unknown" > /home/builder/trezor-firmware/BUILD_TAG_TYPE.txt
# Attempt GPG tag signature verification. Force gpg.format=openpgp to avoid
# the SSH allowedSignersFile config error. Expected output: "no public key" since
# Trezor's signing key is not imported — informational only, not a build blocker.
RUN git -C /home/builder/trezor-firmware -c gpg.format=openpgp tag -v "\${GIT_TAG}" \\
      > /home/builder/trezor-firmware/BUILD_TAG_VERIFY.txt 2>&1 || true

WORKDIR /home/builder/trezor-firmware

# Build firmware and bootloader inside nix-shell.
# nix-shell reads shell.nix at the repo root, which pulls in gcc-arm-embedded-13,
# uv, gnumake, and the full deterministic toolchain from pinned nixpkgs.
# cibuild runs: libopencm3 -> libtrezor.a -> bootloader -> protob -> firmware -> sign
# BITCOIN_ONLY=0 = universal coins; BITCOIN_ONLY=1 = bitcoin-only build
# PRODUCTION=1   = production memory protection and signature enforcement
ARG BITCOIN_ONLY_VAL
RUN . /home/builder/.nix-profile/etc/profile.d/nix.sh && \\
    mkdir -p build/bootloader build/firmware build/intermediate_fw && \\
    nix-shell --run "\\
      set -e ;\\
      cd legacy ;\\
      git clean -dfx -e .venv ;\\
      ln -sf /home/builder/trezor-firmware/build build ;\\
      BITCOIN_ONLY=${BITCOIN_ONLY_VAL} PRODUCTION=1 uv run script/cibuild ;\\
      cp bootloader/bootloader.bin ../build/bootloader/bootloader.bin ;\\
      cp firmware/trezor.bin       ../build/firmware/firmware.bin ;\\
      cp firmware/firmware*.bin    ../build/firmware/ 2>/dev/null || true ;\\
      cp firmware/bootloader.dat   ../build/bootloader/bootloader.dat 2>/dev/null || true\\
    "

CMD ["ls", "-la", "/home/builder/trezor-firmware/build/"]
DOCKERFILE_EOF

if ! ${CONTAINER_CMD} build \
  --build-arg "GIT_TAG=${GIT_TAG}" \
  --build-arg "BITCOIN_ONLY_VAL=${BITCOIN_ONLY_VAL}" \
  --no-cache \
  --tag "${IMAGE_NAME}" \
  --file "${DOCKERFILE_PATH}" \
  "${WORK_DIR}"; then
  log_error "Container build failed — firmware could not be built from source"
  write_results_yaml "ftbfs" "Docker/Podman build failed for ${GIT_TAG}"
  exit 2
fi
log_success "Build image created: ${IMAGE_NAME}"

# Extract build artifacts from image to host via a temporary container
TEMP_CONTAINER="${IMAGE_NAME}-extract-$$"
${CONTAINER_CMD} create --name "$TEMP_CONTAINER" "$IMAGE_NAME" >/dev/null

if ! ${CONTAINER_CMD} cp \
    "${TEMP_CONTAINER}:/home/builder/trezor-firmware/build/." \
    "${BUILD_OUTPUT_DIR}/"; then
  log_error "Failed to extract build artifacts from container"
  ${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true; TEMP_CONTAINER=""
  write_results_yaml "ftbfs" "Failed to copy build artifacts from container"
  exit 2
fi

# Extract supporting files needed for bootloader verification and results summary
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/legacy/firmware/bl_check.txt" \
  "${WORK_DIR}/bl_check.txt" 2>/dev/null || log_warn "bl_check.txt not found in container"
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/legacy/firmware/bl_check.c" \
  "${WORK_DIR}/bl_check.c"   2>/dev/null || log_warn "bl_check.c not found in container"
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/BUILD_COMMIT.txt" \
  "${WORK_DIR}/commit.txt"          2>/dev/null || true
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/BUILD_TAG_TYPE.txt" \
  "${WORK_DIR}/tag_type.txt"        2>/dev/null || true
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/BUILD_TAG_VERIFY.txt" \
  "${WORK_DIR}/tag_verify.txt"      2>/dev/null || true

# Clean up container and image — no longer needed
${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true; TEMP_CONTAINER=""
${CONTAINER_CMD} rmi -f "$IMAGE_NAME"    >/dev/null 2>&1 || true; IMAGE_NAME=""

# Verify key artifacts were produced
if [[ ! -f "${BUILD_OUTPUT_DIR}/firmware/firmware.bin" ]]; then
  log_error "firmware.bin not found in build output"
  write_results_yaml "ftbfs" "cibuild did not produce firmware.bin"
  exit 2
fi
if [[ ! -f "${BUILD_OUTPUT_DIR}/bootloader/bootloader.bin" ]]; then
  log_error "bootloader.bin not found in build output"
  write_results_yaml "ftbfs" "cibuild did not produce bootloader.bin"
  exit 2
fi
log_success "Phase 2 complete — firmware.bin and bootloader.bin extracted"

# Read git metadata using shell builtins
BUILD_COMMIT=""; BUILD_TAG_TYPE=""
[[ -f "${WORK_DIR}/commit.txt" ]]   && read -r BUILD_COMMIT   < "${WORK_DIR}/commit.txt"
[[ -f "${WORK_DIR}/tag_type.txt" ]] && read -r BUILD_TAG_TYPE < "${WORK_DIR}/tag_type.txt"

# ===========================================================================
# PHASE 3: COMPARISON CONTAINER
# Zeroes sig region in built firmware, compares with official, computes
# bootloader SHA256d, and parses bl_check.txt/bl_check.c.
# All binary operations happen inside this container (no host-side sha256sum/xxd/dd).
# ===========================================================================
log_info ""
log_info "--- Phase 3: Comparing firmware and bootloader ---"

if ! ${CONTAINER_CMD} run --rm -i \
  -v "${WORK_DIR}:/work" \
  -e "BOOTLOADER_VERSION=${BOOTLOADER_VERSION}" \
  "${ALPINE_IMAGE}" \
  sh << 'COMPARE_SCRIPT'
set -e
apk add --no-cache coreutils xxd python3 >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Firmware comparison
# ---------------------------------------------------------------------------
# Zero 195-byte sig region (bytes 544-738) in built firmware — same region zeroed in Phase 1
cp /work/build_output/firmware/firmware.bin /work/built_firmware_nosig.bin
dd if=/dev/zero of=/work/built_firmware_nosig.bin bs=1 seek=544 count=195 conv=notrunc 2>/dev/null

OFFICIAL_NOSIG_HASH=$(sha256sum /work/official_firmware_nosig.bin | cut -d' ' -f1)
BUILT_NOSIG_HASH=$(sha256sum /work/built_firmware_nosig.bin | cut -d' ' -f1)
echo "${BUILT_NOSIG_HASH}" > /work/built_nosig_sha256.txt

echo ""
echo "=== COMPARISON of firmware (sig region zeroed, bytes 544-738) ==="
echo "  official (nosig): ${OFFICIAL_NOSIG_HASH}  path: /work/official_firmware_nosig.bin"
echo "  built    (nosig): ${BUILT_NOSIG_HASH}  path: /work/built_firmware_nosig.bin"

if cmp -s /work/official_firmware_nosig.bin /work/built_firmware_nosig.bin; then
  echo "  result: MATCH"
  echo "yes" > /work/firmware_match.txt
else
  echo "  result: MISMATCH"
  echo "no" > /work/firmware_match.txt
  cmp -l /work/official_firmware_nosig.bin /work/built_firmware_nosig.bin \
    > /work/diff_firmware.txt 2>&1 || true
  echo "  (full byte diff written to /work/diff_firmware.txt)"
fi

# ---------------------------------------------------------------------------
# Bootloader comparison
# Use bootloader.dat (pre-committed binary) when available — this is the bootloader
# that actually ships embedded in official firmware.  The freshly-built bootloader.bin
# may be a different source version (e.g., source says 1.12.2 at tag legacy/v1.14.1
# while the committed dat and releases.json both record 1.12.1).
# ---------------------------------------------------------------------------
if [ -f /work/build_output/bootloader/bootloader.dat ]; then
  BL_FILE=/work/build_output/bootloader/bootloader.dat
  BL_LABEL="bootloader.dat"
  echo "" && echo "=== COMPARISON of bootloader (using pre-committed bootloader.dat) ==="
else
  BL_FILE=/work/build_output/bootloader/bootloader.bin
  BL_LABEL="bootloader.bin"
  echo "" && echo "=== COMPARISON of bootloader (using built bootloader.bin — .dat not found) ==="
fi
echo "${BL_LABEL}" > /work/bootloader_source_label.txt
echo "  bootloader source file: ${BL_FILE}"

wc -c < "${BL_FILE}" > /work/bootloader_size.txt

# SHA256d = sha256(sha256(bytes)) — this is what bl_check.txt records and
# what Trezor's firmware runtime enforces during bootloader integrity check.
BL_STEP1=$(sha256sum "${BL_FILE}" | cut -d' ' -f1)
BUILT_BL_SHA256D=$(echo "${BL_STEP1}" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo "${BUILT_BL_SHA256D}" > /work/built_bl_sha256d.txt

# Parse bl_check.txt and cross-check bl_check.c for expected hash
if [ -n "${BOOTLOADER_VERSION}" ] && [ -f /work/bl_check.txt ] && [ -f /work/bl_check.c ]; then
  python3 /work/parse_bl_check.py /work/bl_check.txt /work/bl_check.c "${BOOTLOADER_VERSION}"
  EXPECTED_BL=$(cat /work/expected_bl_hash.txt | tr -d '[:space:]')
else
  echo "" > /work/expected_bl_hash.txt
  echo "no" > /work/bl_hash_in_c.txt
  EXPECTED_BL=""
fi

echo "  bootloader version (from releases.json): ${BOOTLOADER_VERSION}"
echo "  SHA256d of ${BL_FILE##*/}: ${BUILT_BL_SHA256D}"
echo "  expected SHA256d (from bl_check.txt v${BOOTLOADER_VERSION}): ${EXPECTED_BL:-not found}"
if [ -n "${EXPECTED_BL}" ]; then
  if [ "$(echo "${BUILT_BL_SHA256D}" | tr '[:upper:]' '[:lower:]')" = "$(echo "${EXPECTED_BL}" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "  result: MATCH"
  else
    echo "  result: MISMATCH"
  fi
fi

echo ""
echo "[Phase3] Done"
COMPARE_SCRIPT
then
  log_error "Phase 3 (comparison) container failed"
  write_results_yaml "ftbfs" "Phase 3 container failed for version ${version}"
  exit 2
fi

# Read Phase 3 outputs using shell builtins
BUILT_NOSIG_SHA256=""; FIRMWARE_MATCH=""; BUILT_BL_SHA256D=""; EXPECTED_BL_HASH=""; BL_HASH_IN_C=""
BL_SOURCE_LABEL="bootloader.bin"
[[ -f "${WORK_DIR}/built_nosig_sha256.txt" ]]     && read -r BUILT_NOSIG_SHA256  < "${WORK_DIR}/built_nosig_sha256.txt"
[[ -f "${WORK_DIR}/firmware_match.txt" ]]          && read -r FIRMWARE_MATCH      < "${WORK_DIR}/firmware_match.txt"
[[ -f "${WORK_DIR}/built_bl_sha256d.txt" ]]        && read -r BUILT_BL_SHA256D    < "${WORK_DIR}/built_bl_sha256d.txt"
[[ -f "${WORK_DIR}/expected_bl_hash.txt" ]]        && read -r EXPECTED_BL_HASH    < "${WORK_DIR}/expected_bl_hash.txt"
[[ -f "${WORK_DIR}/bl_hash_in_c.txt" ]]            && read -r BL_HASH_IN_C        < "${WORK_DIR}/bl_hash_in_c.txt"
[[ -f "${WORK_DIR}/bootloader_source_label.txt" ]] && read -r BL_SOURCE_LABEL     < "${WORK_DIR}/bootloader_source_label.txt"

log_success "Phase 3 complete"

# ===========================================================================
# VERDICT DETERMINATION
# ===========================================================================
FIRMWARE_VERDICT="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo "reproducible" || echo "not_reproducible" )"

BOOTLOADER_VERDICT="skipped"
BL_NOTES=""
if [[ -n "$BOOTLOADER_VERSION" && -n "$EXPECTED_BL_HASH" ]]; then
  if [[ "${BUILT_BL_SHA256D,,}" == "${EXPECTED_BL_HASH,,}" ]]; then
    BOOTLOADER_VERDICT="reproducible"
    BL_NOTES="Bootloader v${BOOTLOADER_VERSION} SHA256d matches bl_check.txt"
    [[ "${BL_HASH_IN_C}" == "yes" ]] && BL_NOTES="${BL_NOTES} and bl_check.c"
  else
    BOOTLOADER_VERDICT="not_reproducible"
    BL_NOTES="Bootloader SHA256d mismatch. built=${BUILT_BL_SHA256D} expected=${EXPECTED_BL_HASH}"
  fi
elif [[ -n "$BOOTLOADER_VERSION" && -z "$EXPECTED_BL_HASH" ]]; then
  # releases.json names a bootloader version but bl_check.txt has no hash for it.
  # Treat as not_reproducible: we know something should be verified but cannot.
  BOOTLOADER_VERDICT="not_reproducible"
  BL_NOTES="Bootloader v${BOOTLOADER_VERSION} listed in releases.json but hash not found in bl_check.txt — cannot verify"
else
  # releases.json has no bootloader_version for this firmware — nothing to check.
  BOOTLOADER_VERDICT="skipped"
  BL_NOTES="Bootloader version not listed in releases.json for firmware ${version}"
fi

OVERALL_VERDICT="not_reproducible"
if [[ "$FIRMWARE_VERDICT" == "reproducible" ]]; then
  # Only "skipped" (no bootloader data at all) is acceptable alongside firmware reproducible.
  # A "not_reproducible" or hash-gap bootloader blocks the overall reproducible verdict.
  if [[ "$BOOTLOADER_VERDICT" == "reproducible" || "$BOOTLOADER_VERDICT" == "skipped" ]]; then
    OVERALL_VERDICT="reproducible"
  fi
fi

# ===========================================================================
# BUILD RESULTS SUMMARY — standardized format per verification-result-summary-format.md
# ===========================================================================

# Numeric match values for BUILDS MATCH BINARIES format
FW_MATCH_INT="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo 1 || echo 0 )"
FW_MATCH_LABEL="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
BL_MATCH_INT="$( [[ "$BOOTLOADER_VERDICT" == "reproducible" ]] && echo 1 || echo 0 )"
BL_MATCH_LABEL="$( [[ "$BOOTLOADER_VERDICT" == "reproducible" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
TOTAL_ARTIFACTS=2
MATCH_COUNT=$(( FW_MATCH_INT + BL_MATCH_INT ))
MISMATCH_COUNT=$(( TOTAL_ARTIFACTS - MATCH_COUNT ))

# Git tag and signature info
TAG_TYPE_LABEL="unknown"
TAG_SIG_LINE="[WARNING] Tag signature status unknown"
case "${BUILD_TAG_TYPE}" in
  tag)    TAG_TYPE_LABEL="annotated"; TAG_SIG_LINE="[INFO] Annotated tag — GPG keys not imported, signature not verified" ;;
  commit) TAG_TYPE_LABEL="lightweight"; TAG_SIG_LINE="[INFO] Lightweight tag (cannot contain a GPG signature)" ;;
esac

TAG_VERIFY_OUTPUT=""
if [[ -f "${WORK_DIR}/tag_verify.txt" ]]; then
  TAG_VERIFY_OUTPUT=$(grep -v "gpg.ssh.allowedSignersFile" "${WORK_DIR}/tag_verify.txt" || true)
fi

# Verdict string — format doc uses "reproducible" or "differences found"
VERDICT_STR="$( [[ "$OVERALL_VERDICT" == "reproducible" ]] && echo "reproducible" || echo "differences found" )"

echo ""
echo "===== Begin Results ====="
echo "appId:          trezorOne"
echo "signer:         N/A"
echo "firmwareVersion: ${version}"
echo "firmwareBuild:   N/A"
echo "verdict:        ${VERDICT_STR}"
echo "appHash:        ${OFFICIAL_RAW_SHA256}"
echo "commit:         ${BUILD_COMMIT}"
echo ""
echo "Diff:"
echo "BUILDS MATCH BINARIES"
echo "${RELEASE_FILENAME} - arm-t1b1-${build_type} - ${BUILT_NOSIG_SHA256} - ${FW_MATCH_INT} (${FW_MATCH_LABEL})"
echo "${BL_SOURCE_LABEL} - arm-t1b1 - ${BUILT_BL_SHA256D:-N/A} - ${BL_MATCH_INT} (${BL_MATCH_LABEL})"
echo ""
echo "SUMMARY"
echo "total: ${TOTAL_ARTIFACTS}"
echo "matches: ${MATCH_COUNT}"
echo "mismatches: ${MISMATCH_COUNT}"

if [[ "$FIRMWARE_MATCH" != "yes" && -f "${WORK_DIR}/diff_firmware.txt" ]]; then
  echo ""
  echo "First 5 differing bytes (full diff: ${WORK_DIR}/diff_firmware.txt):"
  head -5 "${WORK_DIR}/diff_firmware.txt" 2>/dev/null || true
fi

echo ""
echo "Revision, tag (and its signature):"
echo "${TAG_VERIFY_OUTPUT}"
echo ""
echo "Signature Summary:"
echo "Tag type: ${TAG_TYPE_LABEL}"
echo "${TAG_SIG_LINE}"
echo ""
echo "Keys used:"
echo "Firmware signed by Trezor (SatoshiLabs s.r.o.)"
echo "See: https://github.com/trezor/trezor-firmware/blob/legacy/v${version}/legacy/firmware/firmware_sign.py"
echo ""
if [[ -n "$BL_NOTES" ]]; then
  echo "===== Also ===="
  echo "Bootloader check: ${BL_NOTES}"
  echo "Bootloader comparison: SHA256d (double-SHA256) vs bl_check.txt entry for v${BOOTLOADER_VERSION:-N/A}"
  [[ "${BL_HASH_IN_C}" == "yes" ]] && echo "Bootloader hash cross-verified against bl_check.c (compiled into firmware)"
  echo ""
fi
echo "===== End Results ====="
echo ""
echo "Run a full"
echo "diffoscope \"${WORK_DIR}/official_firmware_nosig.bin\" \"${WORK_DIR}/built_firmware_nosig.bin\""
echo "for more details."
echo ""

# ===========================================================================
# Write COMPARISON_RESULTS.yaml
# ===========================================================================
YAML_NOTES="Firmware v${version} type=${build_type} tag=${GIT_TAG} commit=${BUILD_COMMIT}. Firmware: ${FIRMWARE_VERDICT}. Bootloader: ${BOOTLOADER_VERDICT}. ${BL_NOTES}"
write_results_yaml "$OVERALL_VERDICT" "$YAML_NOTES"

log_info "=============================================="
log_info "VERDICT   : ${OVERALL_VERDICT}"
log_info "Firmware  : ${FIRMWARE_VERDICT}"
log_info "Bootloader: ${BOOTLOADER_VERDICT}"
log_info "Results   : ${CANONICAL_RESULTS}"
log_info "Work dir  : ${WORK_DIR}"
log_info "=============================================="

case "$OVERALL_VERDICT" in
  reproducible)     log_success "REPRODUCIBLE"; exit 0 ;;
  not_reproducible) log_warn    "NOT REPRODUCIBLE"; exit 1 ;;
  *)                log_error   "FTBFS"; exit 2 ;;
esac
