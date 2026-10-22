#!/usr/bin/env bash
# trezorOne_build.sh - Trezor One (T1B1) firmware reproducible build verification
# Version: v0.1.14 · Organization: WalletScrutiny.com · License: MIT
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-22
# Disclaimer: for reproducible-build verification only; no warranty; runs containers and
#   downloads source; you are responsible for lawful use. Read the script before running it.
# Steps: fetch the official firmware and check its releases.json fingerprint; build it from
#   legacy/v<version> in containers; zero the 195-byte signature region on both and compare;
#   check the bundled bootloader against bl_check.txt/.c and rebuild it from legacy/bl<version>
#   (reproducible only if it matches byte for byte). Only host need: Docker or Podman.
# Exit 0 reproducible, 1 not reproducible/ftbfs/failure, 2 invalid, 130 stopped. History: changelog.

set -euo pipefail

SCRIPT_VERSION="v0.1.14"
APP_ID="trezorOne"
RESULTS_WRITTEN=false
ENV_IMAGE=""
BUILD_IMAGE=""
TEMP_CONTAINER=""
BL_ENV_IMAGE=""
BL_BUILD_IMAGE=""
WORK_DIR=""

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

ALPINE_IMAGE="docker.io/library/alpine:3.15.0@sha256:21a3deaa0d32a8057914f36584b5288d2e5ecc984380bc0118285c70fa8c9300"

# ---- Colors and logging ----
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# emit — prints stdin unchanged (bash builtins only; replaces cat on the host)
emit() { local c=""; IFS= read -r -d '' c || true; printf '%s' "$c"; }

# ---- Paths (bash parameter expansion; no host dirname/basename/readlink) ----
_src="${BASH_SOURCE[0]}"
if [[ "$_src" == */* ]]; then _src_dir="${_src%/*}"; else _src_dir="."; fi
SCRIPT_DIR="$(cd "$_src_dir" && pwd -P)"
SCRIPT_NAME="${_src##*/}"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
CANONICAL_RESULTS="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

# ---- Container runtime: the first whose engine answers 'info' ----
CONTAINER_CMD=""
for _candidate in docker podman; do
  if command -v "$_candidate" &>/dev/null && "$_candidate" info &>/dev/null; then
    CONTAINER_CMD="$_candidate"
    break
  fi
done
if [[ -z "$CONTAINER_CMD" ]]; then
  for _candidate in docker podman; do
    if command -v "$_candidate" &>/dev/null; then
      CONTAINER_CMD="$_candidate"
      break
    fi
  done
fi

# ---- Self-identification first (hashed in a container; N/A on failure) ----
SCRIPT_SHA256="N/A"
if [[ -n "$CONTAINER_CMD" && -f "$SCRIPT_PATH" ]]; then
  _hash_out="$(${CONTAINER_CMD} run --rm -v "${SCRIPT_PATH}:/script.sh:ro" "${ALPINE_IMAGE}" \
    sha256sum /script.sh </dev/null 2>/dev/null || true)"
  _hash="${_hash_out%% *}"
  [[ "$_hash" =~ ^[0-9a-f]{64}$ ]] && SCRIPT_SHA256="$_hash"
fi
log_info "Script: ${SCRIPT_NAME} ${SCRIPT_VERSION} sha256 ${SCRIPT_SHA256}"

# One run per script folder: runs share COMPARISON_RESULTS.yaml (flock optional).
if command -v flock &>/dev/null; then
  exec 9>"${SCRIPT_DIR}/.comparison_results.lock"
  if ! flock -n 9; then
    log_error "Another verification is already running from ${SCRIPT_DIR} (it shares COMPARISON_RESULTS.yaml). Run this one after it, or from a copy of the script in another folder."
    log_error "No verdict written."
    exit "$EXIT_FAIL"
  fi
else
  log_warn "flock not found; parallel runs from this folder would share COMPARISON_RESULTS.yaml."
fi

# Remove a previous verdict before this invocation can fail, so ABS can never
# pick up a stale COMPARISON_RESULTS.yaml from an earlier run.
rm -f -- "$CANONICAL_RESULTS"

# ---- Disclaimer banner ----
echo -e "${YELLOW}"
emit << 'BANNER_EOF'
==============================================================================
                             DISCLAIMER
==============================================================================
Please examine this script prior to running it. This script downloads source
code, runs Docker/Podman containers, and builds ARM firmware. It may consume
significant CPU, memory (4+ GB), and disk space (10+ GB).
Build time: 30-60 minutes on first run (Nix downloads toolchains cold).
Use at your own risk.
==============================================================================
BANNER_EOF
echo -e "${NC}"

# ---- Root guard ----
if (( EUID == 0 )); then
  log_error "Do not run this script as root. Please run as a normal user."
  exit "$EXIT_INVALID"
fi

if [[ -z "$CONTAINER_CMD" ]]; then
  log_error "Neither docker nor podman found. Please install Docker or Podman."
  exit "$EXIT_FAIL"
fi
log_info "Container runtime: ${CONTAINER_CMD}"

# ---- Usage ----
usage() {
  emit << EOF
Trezor One (T1B1) Firmware Reproducible Build Verification

  ${SCRIPT_NAME} --version VERSION [--arch ARCH] [--type TYPE] [--binary FILE]

  --version   Firmware version without 'v' prefix (e.g., 1.14.1)
  --arch      Architecture (default: arm — only valid value for T1B1)
  --type      Firmware type: universal (default) or btc-only
  --binary    Path to official firmware .bin file (skips download)

EXIT CODES
  0   = reproducible
  1   = not_reproducible, ftbfs, or a failure with no verdict
  2   = invalid parameters
  130 = stopped
EOF
}

# ---- Argument parsing (unknown parameters warn, never fatal) ----
version=""
arch="arm"
build_type="universal"
binary_file=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || { log_error "--version requires a value"; exit "$EXIT_INVALID"; }; version="$2"; shift 2 ;;
    --arch)    [[ $# -ge 2 ]] || { log_error "--arch requires a value"; exit "$EXIT_INVALID"; }; arch="$2"; shift 2 ;;
    --type)    [[ $# -ge 2 ]] || { log_error "--type requires a value"; exit "$EXIT_INVALID"; }; build_type="$2"; shift 2 ;;
    --binary)  [[ $# -ge 2 ]] || { log_error "--binary requires a value"; exit "$EXIT_INVALID"; }; binary_file="$2"; shift 2 ;;
    --help|-h) usage; exit "$EXIT_OK" ;;
    *) log_warn "Ignoring unknown parameter: $1"; shift ;;
  esac
done

# ---- Validate inputs (--version may be inferred from the --binary filename) ----
if [[ -z "$version" && -n "$binary_file" ]]; then
  if [[ "${binary_file##*/}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
    log_warn "No --version provided; inferred '${version}' from filename '${binary_file##*/}'"
  fi
fi

if [[ -z "$version" ]]; then
  log_error "--version is required (and could not be inferred from the binary filename)"
  echo
  usage
  exit "$EXIT_INVALID"
fi

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log_error "Invalid version format '${version}'. Expected X.Y.Z (e.g., 1.14.1)"
  exit "$EXIT_INVALID"
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

binary_abs=""
if [[ -n "$binary_file" ]]; then
  if [[ ! -f "$binary_file" ]]; then
    log_error "--binary file not found: ${binary_file}"
    exit "$EXIT_INVALID"
  fi
  if [[ "$binary_file" == /* ]]; then binary_abs="$binary_file"; else binary_abs="${PWD}/${binary_file}"; fi
fi

BITCOIN_ONLY_VAL="$( [[ "$build_type" == "btc-only" ]] && echo 1 || echo 0 )"
GIT_TAG="legacy/v${version}"
RELEASE_FILENAME="$( [[ "$build_type" == "btc-only" ]] && echo "trezor-t1b1-${version}-bitcoinonly.bin" || echo "trezor-t1b1-${version}.bin" )"

# ---- Per-run workspace in the caller's directory ----
printf -v RUN_ID '%(%s)T-%s' -1 "$$"
WORK_DIR_CANDIDATE="$(pwd -P)/trezorOne_verification_${version}_${build_type}_${RUN_ID}"
BUILD_OUTPUT_DIR="${WORK_DIR_CANDIDATE}/build_output"

if ! mkdir -- "$WORK_DIR_CANDIDATE"; then
  log_error "Work directory already exists or cannot be created: ${WORK_DIR_CANDIDATE}"
  exit "$EXIT_INVALID"
fi
WORK_DIR="$WORK_DIR_CANDIDATE"
mkdir -- "$BUILD_OUTPUT_DIR"

# Image names: localhost/ keeps them fully qualified (no short-name lookup);
# the run id keeps cleanup from touching another run's images.
_tag_suffix="${build_type}-${version//./_}-${RUN_ID}"
ENV_IMAGE_NAME="localhost/trezor-one-env-${_tag_suffix}"
BUILD_IMAGE_NAME="localhost/trezor-one-build-${_tag_suffix}"

log_info "=============================================="
log_info "Trezor One (T1B1) Firmware Verification"
log_info "=============================================="
log_info "Script  : ${SCRIPT_VERSION}"
log_info "Version : ${version} | Type: ${build_type} | Tag: ${GIT_TAG}"
log_info "Work dir: ${WORK_DIR}"
log_info "=============================================="

# write_results_yaml: 3-field YAML, written only for a real verdict
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
  # Per-run copy in this run's workspace. Deliberately NOT named COMPARISON_RESULTS.yaml:
  # ABS searches its build directory recursively for that name.
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    printf '%s\n' "$(<"${CANONICAL_RESULTS}")" > "${WORK_DIR}/results_${RUN_ID}.yaml" || true
  fi
  log_info "COMPARISON_RESULTS.yaml written (verdict: ${v})"
}

# no_verdict — failure that says nothing about the source (network, stop,
# provenance): no YAML, so ABS publishes nothing.
no_verdict() {
  log_error "$1"
  log_error "No verdict written (this is not a build failure of the source)."
  exit "$EXIT_FAIL"
}

# hand_back_workspace: return root-written files to the caller (docker chown / podman unshare)
hand_back_workspace() {
  [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]] || return 0
  if [[ "$CONTAINER_CMD" == "podman" ]]; then
    podman unshare chown -R 0:0 "$WORK_DIR" >/dev/null 2>&1 || true
  else
    # GROUPS[0] is the caller's primary gid (bash builtin; no host id command)
    ${CONTAINER_CMD} run --rm -v "${WORK_DIR}:/work" "${ALPINE_IMAGE}" \
      sh -c "chown -R ${EUID}:${GROUPS[0]} /work && chmod -R u+rwX /work" >/dev/null 2>&1 || true
  fi
}

# cleanup: remove this run's container/images, hand back the workspace; never writes a verdict
cleanup() {
  local ec=$?
  [[ -n "$TEMP_CONTAINER" ]] && ${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  [[ -n "$BUILD_IMAGE" ]]    && ${CONTAINER_CMD} rmi -f "$BUILD_IMAGE"   >/dev/null 2>&1 || true
  [[ -n "$ENV_IMAGE" ]]      && ${CONTAINER_CMD} rmi -f "$ENV_IMAGE"     >/dev/null 2>&1 || true
  [[ -n "$BL_BUILD_IMAGE" ]] && ${CONTAINER_CMD} rmi -f "$BL_BUILD_IMAGE" >/dev/null 2>&1 || true
  [[ -n "$BL_ENV_IMAGE" ]]   && ${CONTAINER_CMD} rmi -f "$BL_ENV_IMAGE"   >/dev/null 2>&1 || true
  hand_back_workspace
  if [[ "$RESULTS_WRITTEN" != "true" ]]; then
    log_warn "No COMPARISON_RESULTS.yaml written for this run."
  fi
  echo "Exit code: ${ec}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- Helper Python scripts (written here, run in containers) ----

# parse_releases.py — parses releases.json, writes one-value-per-file outputs
emit > "${WORK_DIR}/parse_releases.py" << 'PYEOF'
#!/usr/bin/env python3
"""Writes firmware_url.txt, bootloader_version.txt, releases_fingerprint.txt to /work/
for <version> <build_type> from releases.json. Exit 3 when the version is not listed."""
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
    # Relative releases.json URLs: drop a leading "data/" and prefix https://data.trezor.io/
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
sys.exit(3)
PYEOF

# parse_bl_check.py — extracts expected bootloader SHA256d and cross-checks bl_check.c
emit > "${WORK_DIR}/parse_bl_check.py" << 'PYEOF2'
#!/usr/bin/env python3
"""Writes expected_bl_hash.txt (SHA256d for <bootloader_version> from bl_check.txt) and
bl_hash_in_c.txt ("yes" if the same hash is compiled into bl_check.c) to /work/."""
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
    # bl_check.c stores the hashes as "\\xNN" string literals (0xNN accepted too).
    hex_bytes = re.findall(r'(?:0x|\\x)([0-9a-f]{2})', content)
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

# ---- PHASE 1: fetch (container). Exit 3 version not listed, 4 download, 5 fingerprint ----
log_info ""
log_info "--- Phase 1: Fetch and prepare official firmware ---"

BINARY_MOUNT=()
if [[ -n "$binary_abs" ]]; then
  BINARY_MOUNT=(-v "${binary_abs}:/input/official.bin:ro")
  log_info "Using provided binary: ${binary_abs}"
fi

phase1_rc=0
${CONTAINER_CMD} run --rm -i \
  -v "${WORK_DIR}:/work" \
  "${BINARY_MOUNT[@]}" \
  -e "VERSION=${version}" \
  -e "BUILD_TYPE=${build_type}" \
  "${ALPINE_IMAGE}" \
  sh << 'FETCH_SCRIPT' || phase1_rc=$?
set -e
apk add --no-cache curl python3 coreutils xxd >/dev/null 2>&1 || exit 4

echo "[Phase1] Downloading releases.json..."
curl -sSL --fail "https://data.trezor.io/firmware/t1b1/releases.json" -o /work/releases.json || exit 4

echo "[Phase1] Parsing releases.json for version ${VERSION}..."
python3 /work/parse_releases.py /work/releases.json "${VERSION}" "${BUILD_TYPE}" || exit $?
FIRMWARE_URL=$(cat /work/firmware_url.txt | tr -d '[:space:]')
echo "[Phase1] URL: ${FIRMWARE_URL}"

if [ -f /input/official.bin ]; then
  echo "[Phase1] Using provided --binary file."
  cp /input/official.bin /work/official_firmware_raw.bin
else
  echo "[Phase1] Downloading official firmware..."
  curl -sSL --fail "${FIRMWARE_URL}" -o /work/official_firmware_raw.bin || exit 4
fi

# SHA256 of full raw file (used as appHash in results — not the fingerprint)
sha256sum /work/official_firmware_raw.bin | cut -d' ' -f1 > /work/official_raw_sha256.txt

# Detect TRZR prefix before stripping.
# Old releases prepend a 256-byte TRZR (54525a52) header; t1b1/ files start with TRZF (54525a46).
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

# Zero the 195-byte signature region 544-738 (firmware_sign.py: 3x64 sigs + 3 index bytes).
cp /work/official_firmware_trzf.bin /work/official_firmware_nosig.bin
dd if=/dev/zero of=/work/official_firmware_nosig.bin bs=1 seek=544 count=195 conv=notrunc 2>/dev/null

sha256sum /work/official_firmware_nosig.bin | cut -d' ' -f1 > /work/official_nosig_sha256.txt
echo "[Phase1] Official nosig SHA256: $(cat /work/official_nosig_sha256.txt)"

# Fingerprint: SHA256 of the 1024-byte header, region zeroed; must equal releases.json.
dd if=/work/official_firmware_trzf.bin of=/tmp/fp_header.bin bs=1 count=1024 2>/dev/null
dd if=/dev/zero of=/tmp/fp_header.bin bs=1 seek=544 count=195 conv=notrunc 2>/dev/null
COMPUTED_FP=$(sha256sum /tmp/fp_header.bin | cut -d' ' -f1)
EXPECTED_FP=$(cat /work/releases_fingerprint.txt | tr -d '[:space:]')
echo "[Phase1] Computed firmware fingerprint: ${COMPUTED_FP}"
if [ -n "${EXPECTED_FP}" ]; then
  echo "[Phase1] releases.json fingerprint:   ${EXPECTED_FP}"
  if [ "${COMPUTED_FP}" != "${EXPECTED_FP}" ]; then
    echo "[Phase1] FATAL: fingerprint mismatch — firmware file does not match releases.json"
    echo "MISMATCH" > /work/fingerprint_check.txt
    exit 5
  fi
  echo "[Phase1] Fingerprint OK"
  echo "OK" > /work/fingerprint_check.txt
else
  echo "[Phase1] No fingerprint in releases.json — skipping provenance check"
  echo "SKIPPED" > /work/fingerprint_check.txt
fi
FETCH_SCRIPT

case "$phase1_rc" in
  0) ;;
  3) log_error "Version ${version} is not listed in Trezor's releases.json"
     exit "$EXIT_INVALID" ;;
  5) no_verdict "Firmware file fails the releases.json fingerprint — not the published release" ;;
  *) no_verdict "Phase 1 (fetch) failed (exit ${phase1_rc}) — network or download problem" ;;
esac

# Read Phase 1 outputs using shell builtins only
BOOTLOADER_VERSION=""; OFFICIAL_NOSIG_SHA256=""; OFFICIAL_RAW_SHA256=""
[[ -f "${WORK_DIR}/bootloader_version.txt" ]]    && read -r BOOTLOADER_VERSION    < "${WORK_DIR}/bootloader_version.txt"
[[ -f "${WORK_DIR}/official_nosig_sha256.txt" ]] && read -r OFFICIAL_NOSIG_SHA256 < "${WORK_DIR}/official_nosig_sha256.txt"
[[ -f "${WORK_DIR}/official_raw_sha256.txt" ]]   && read -r OFFICIAL_RAW_SHA256   < "${WORK_DIR}/official_raw_sha256.txt"

if [[ -z "$OFFICIAL_NOSIG_SHA256" ]]; then
  no_verdict "Phase 1 did not produce the official firmware hash"
fi
log_success "Phase 1 complete. Bootloader version: ${BOOTLOADER_VERSION:-unknown}"

# ---- PHASE 2a: environment image (downloads only; failure = no verdict) ----
log_info ""
log_info "--- Phase 2a: Preparing build environment and source ---"

ENV_DOCKERFILE="${WORK_DIR}/Dockerfile.env"
emit > "$ENV_DOCKERFILE" << DOCKERFILE_EOF
FROM ${ALPINE_IMAGE}

# Minimal host tools needed before Nix takes over.
# gnupg is included for the git tag -v signature attempt.
RUN apk add --no-cache \\
    bash curl xz git shadow ca-certificates \\
    coreutils findutils grep gzip tar util-linux gnupg

# Non-root build user. A single-user Nix install needs no privileges
# when /nix already exists and belongs to that user, so /nix is created here.
RUN adduser -D -s /bin/bash builder && \\
    mkdir -m 0755 /nix && chown builder /nix

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
# Tag signature check (informational; no Trezor key imported).
RUN git -C /home/builder/trezor-firmware -c gpg.format=openpgp tag -v "\${GIT_TAG}" \\
      > /home/builder/trezor-firmware/BUILD_TAG_VERIFY.txt 2>&1 || true
# Which signature the tag and the commit carry (presence only).
RUN t=\$(git -C /home/builder/trezor-firmware cat-file tag "\${GIT_TAG}" 2>/dev/null || true); \\
    case "\$t" in *"BEGIN SSH SIGNATURE"*) echo ssh ;; *"BEGIN PGP SIGNATURE"*) echo pgp ;; *) echo none ;; esac \\
      > /home/builder/trezor-firmware/BUILD_TAG_SIG.txt; \\
    c=\$(git -C /home/builder/trezor-firmware cat-file commit HEAD); \\
    case "\$c" in *"gpgsig"*) echo yes ;; *) echo no ;; esac > /home/builder/trezor-firmware/BUILD_COMMIT_SIG.txt

WORKDIR /home/builder/trezor-firmware

# Prefetch the nix-shell toolchain (shell.nix at the repo root), so the build
# step below fails only on the source, not on a download.
RUN . /home/builder/.nix-profile/etc/profile.d/nix.sh && nix-shell --run true
DOCKERFILE_EOF

if ! ${CONTAINER_CMD} build \
  --build-arg "GIT_TAG=${GIT_TAG}" \
  --no-cache \
  --tag "${ENV_IMAGE_NAME}" \
  --file "${ENV_DOCKERFILE}" \
  "${WORK_DIR}"; then
  no_verdict "Environment image failed (Nix install, nixpkgs, clone of ${GIT_TAG} or toolchain prefetch) — infrastructure, not the source"
fi
ENV_IMAGE="$ENV_IMAGE_NAME"
log_success "Environment image created: ${ENV_IMAGE}"

# ---- PHASE 2b: build image (cibuild; failure = ftbfs) ----
log_info ""
log_info "--- Phase 2b: Building firmware (30-60 min on first run) ---"

BUILD_DOCKERFILE="${WORK_DIR}/Dockerfile.build"
emit > "$BUILD_DOCKERFILE" << DOCKERFILE_EOF
FROM ${ENV_IMAGE}

WORKDIR /home/builder/trezor-firmware

# Build in nix-shell (shell.nix toolchain); BITCOIN_ONLY picks the edition, PRODUCTION=1.
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
  --build-arg "BITCOIN_ONLY_VAL=${BITCOIN_ONLY_VAL}" \
  --no-cache \
  --tag "${BUILD_IMAGE_NAME}" \
  --file "${BUILD_DOCKERFILE}" \
  "${WORK_DIR}"; then
  log_error "Firmware build failed — the source at ${GIT_TAG} did not build"
  write_results_yaml "ftbfs" "Trezor One ${version} (${build_type}): cibuild failed at ${GIT_TAG}; the environment and source download had succeeded"
  exit "$EXIT_FAIL"
fi
BUILD_IMAGE="$BUILD_IMAGE_NAME"
log_success "Build image created: ${BUILD_IMAGE}"

# Extract build artifacts from image to host via a temporary container
TEMP_CONTAINER="trezor-one-extract-${_tag_suffix}"
if ! ${CONTAINER_CMD} create --name "$TEMP_CONTAINER" "$BUILD_IMAGE" >/dev/null; then
  TEMP_CONTAINER=""
  no_verdict "Could not create a container from the build image to extract artifacts"
fi

if ! ${CONTAINER_CMD} cp \
    "${TEMP_CONTAINER}:/home/builder/trezor-firmware/build/." \
    "${BUILD_OUTPUT_DIR}/"; then
  no_verdict "Failed to copy build artifacts from the container"
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
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/BUILD_TAG_SIG.txt" \
  "${WORK_DIR}/tag_sig.txt"         2>/dev/null || true
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/trezor-firmware/BUILD_COMMIT_SIG.txt" \
  "${WORK_DIR}/commit_sig.txt"      2>/dev/null || true

# Clean up container and images — no longer needed
${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true; TEMP_CONTAINER=""
${CONTAINER_CMD} rmi -f "$BUILD_IMAGE"   >/dev/null 2>&1 || true; BUILD_IMAGE=""
${CONTAINER_CMD} rmi -f "$ENV_IMAGE"     >/dev/null 2>&1 || true; ENV_IMAGE=""

# Verify key artifacts were produced (cibuild succeeded but left no output)
if [[ ! -f "${BUILD_OUTPUT_DIR}/firmware/firmware.bin" ]]; then
  log_error "firmware.bin not found in build output"
  write_results_yaml "ftbfs" "Trezor One ${version} (${build_type}): cibuild did not produce firmware.bin"
  exit "$EXIT_FAIL"
fi
if [[ ! -f "${BUILD_OUTPUT_DIR}/bootloader/bootloader.bin" ]]; then
  log_error "bootloader.bin not found in build output"
  write_results_yaml "ftbfs" "Trezor One ${version} (${build_type}): cibuild did not produce bootloader.bin"
  exit "$EXIT_FAIL"
fi
log_success "Phase 2 complete — firmware.bin and bootloader.bin extracted"

# Read git metadata using shell builtins
BUILD_COMMIT=""; BUILD_TAG_TYPE=""
[[ -f "${WORK_DIR}/commit.txt" ]]   && read -r BUILD_COMMIT   < "${WORK_DIR}/commit.txt"
[[ -f "${WORK_DIR}/tag_type.txt" ]] && read -r BUILD_TAG_TYPE < "${WORK_DIR}/tag_type.txt"

# ---- PHASE 4: rebuild the bundled bootloader from its own release tag legacy/bl<version> ----
# Mirrors that tag's ci/Dockerfile (Nix 2.4, root, sandbox off) and the first three cibuild steps
# (libopencm3, libtrezor, bootloader). Env image = downloads (failure: no verdict); build = ftbfs.
BL_TAG=""; BL_REBUILD=""; BL_TAG_COMMIT=""
if [[ -n "$BOOTLOADER_VERSION" ]]; then
  BL_TAG="legacy/bl${BOOTLOADER_VERSION}"
  log_info ""; log_info "--- Phase 4: Rebuilding bootloader ${BOOTLOADER_VERSION} from ${BL_TAG} ---"
  bl_rc=0
  ${CONTAINER_CMD} run --rm "${ALPINE_IMAGE}" sh -c "apk add -q --no-cache git >/dev/null && git ls-remote --exit-code --tags https://github.com/trezor/trezor-firmware.git refs/tags/${BL_TAG}" >/dev/null || bl_rc=$?
  case "$bl_rc" in 0) ;; 2) BL_REBUILD="no-tag" ;; *) no_verdict "Could not look up tag ${BL_TAG} (network)" ;; esac
fi
if [[ -n "$BL_TAG" && -z "$BL_REBUILD" ]]; then
  emit > "${WORK_DIR}/Dockerfile.blenv" << DOCKERFILE_EOF
FROM ${ALPINE_IMAGE}
RUN apk add --no-cache --update openssl bash git python3 && echo hosts: files dns > /etc/nsswitch.conf
RUN wget -q https://releases.nixos.org/nix/nix-2.4/nix-2.4-x86_64-linux.tar.xz && tar xf nix-2.4-x86_64-linux.tar.xz \\
 && addgroup -g 30000 -S nixbld \\
 && for i in \$(seq 1 30); do adduser -S -D -h /var/empty -g "Nix build user \$i" -u \$((30000 + i)) -G nixbld nixbld\$i; done \\
 && mkdir -m 0755 /etc/nix && echo 'sandbox = false' > /etc/nix/nix.conf \\
 && mkdir -m 0755 /nix && USER=root sh nix-2.4-x86_64-linux/install && rm -r /nix-2.4-x86_64-linux*
ENV USER=root PATH=/nix/var/nix/profiles/default/bin:/bin:/sbin:/usr/bin:/usr/sbin \\
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
RUN git clone -q --depth 1 --branch "${BL_TAG}" https://github.com/trezor/trezor-firmware.git /src \\
 && git -C /src submodule update -q --init --recursive && git -C /src rev-parse HEAD > /src/BL_COMMIT.txt
WORKDIR /src/legacy
RUN nix-shell /src/ci/shell.nix --run "poetry install"
DOCKERFILE_EOF
  BL_ENV_IMAGE_NAME="localhost/trezor-one-blenv-${_tag_suffix}"
  if ! ${CONTAINER_CMD} build --no-cache --tag "$BL_ENV_IMAGE_NAME" --file "${WORK_DIR}/Dockerfile.blenv" "${WORK_DIR}"; then
    no_verdict "Bootloader environment image failed (Nix 2.4, clone of ${BL_TAG} or poetry install)"
  fi
  BL_ENV_IMAGE="$BL_ENV_IMAGE_NAME"
  emit > "${WORK_DIR}/Dockerfile.blbuild" << DOCKERFILE_EOF
FROM ${BL_ENV_IMAGE}
ENV BITCOIN_ONLY=0 PRODUCTION=1
RUN nix-shell /src/ci/shell.nix --run "poetry run sh -c 'make -C vendor/libopencm3 lib/stm32/f2 && make && make -C bootloader'"
DOCKERFILE_EOF
  BL_BUILD_IMAGE_NAME="localhost/trezor-one-blbuild-${_tag_suffix}"
  if ! ${CONTAINER_CMD} build --no-cache --tag "$BL_BUILD_IMAGE_NAME" --file "${WORK_DIR}/Dockerfile.blbuild" "${WORK_DIR}"; then
    write_results_yaml "ftbfs" "Trezor One ${version} (${build_type}): firmware built, but bootloader ${BOOTLOADER_VERSION} did not build from ${BL_TAG}"
    exit "$EXIT_FAIL"
  fi
  BL_BUILD_IMAGE="$BL_BUILD_IMAGE_NAME"
  TEMP_CONTAINER="trezor-one-blextract-${_tag_suffix}"
  ${CONTAINER_CMD} create --name "$TEMP_CONTAINER" "$BL_BUILD_IMAGE" true >/dev/null || no_verdict "Could not create the bootloader extract container"
  ${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/src/legacy/bootloader/bootloader.bin" "${BUILD_OUTPUT_DIR}/bootloader_rebuilt.bin" \
    || no_verdict "Could not copy the rebuilt bootloader out of the container"
  ${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/src/BL_COMMIT.txt" "${WORK_DIR}/bl_commit.txt" 2>/dev/null || true
  [[ -f "${WORK_DIR}/bl_commit.txt" ]] && read -r BL_TAG_COMMIT < "${WORK_DIR}/bl_commit.txt"
  ${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true; TEMP_CONTAINER=""
  ${CONTAINER_CMD} rmi -f "$BL_BUILD_IMAGE" "$BL_ENV_IMAGE" >/dev/null 2>&1 || true; BL_BUILD_IMAGE=""; BL_ENV_IMAGE=""
  BL_REBUILD="built"
  log_success "Phase 4 complete — bootloader rebuilt from ${BL_TAG} (${BL_TAG_COMMIT:-commit unknown})"
fi

# ---- PHASE 3: compare (container) ----
log_info ""
log_info "--- Phase 3: Comparing firmware and bootloader ---"

if ! ${CONTAINER_CMD} run --rm -i \
  -v "${WORK_DIR}:/work" \
  -e "BOOTLOADER_VERSION=${BOOTLOADER_VERSION}" \
  "${ALPINE_IMAGE}" \
  sh << 'COMPARE_SCRIPT'
set -e
apk add --no-cache coreutils xxd python3 >/dev/null 2>&1

# ---- Firmware: zero the same 195-byte region in the build ----
cp /work/build_output/firmware/firmware.bin /work/built_firmware_nosig.bin
dd if=/dev/zero of=/work/built_firmware_nosig.bin bs=1 seek=544 count=195 conv=notrunc 2>/dev/null

OFFICIAL_NOSIG_HASH=$(sha256sum /work/official_firmware_nosig.bin | cut -d' ' -f1)
BUILT_NOSIG_HASH=$(sha256sum /work/built_firmware_nosig.bin | cut -d' ' -f1)
echo "${BUILT_NOSIG_HASH}" > /work/built_nosig_sha256.txt

echo ""
echo "=== COMPARISON of firmware (sig region zeroed, bytes 544-738) ==="
echo "  official (nosig): ${OFFICIAL_NOSIG_HASH}"
echo "  built    (nosig): ${BUILT_NOSIG_HASH}"

if cmp -s /work/official_firmware_nosig.bin /work/built_firmware_nosig.bin; then
  echo "  result: MATCH"
  echo "yes" > /work/firmware_match.txt
else
  echo "  result: MISMATCH"
  echo "no" > /work/firmware_match.txt
  cmp -l /work/official_firmware_nosig.bin /work/built_firmware_nosig.bin \
    > /work/diff_firmware.txt 2>&1 || true
  wc -l < /work/diff_firmware.txt > /work/diff_firmware_lines.txt
fi

# ---- Bootloader: the committed bootloader.dat, which the official firmware embeds ----
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

if [ -f /work/build_output/bootloader_rebuilt.bin ]; then
  sha256sum /work/build_output/bootloader_rebuilt.bin | cut -d' ' -f1 > /work/bl_rebuilt_sha256.txt
  sha256sum "${BL_FILE}" | cut -d' ' -f1 > /work/bl_dat_sha256.txt
  if cmp -s "${BL_FILE}" /work/build_output/bootloader_rebuilt.bin; then echo yes; else echo no; fi > /work/bl_rebuilt_match.txt
  cmp -l "${BL_FILE}" /work/build_output/bootloader_rebuilt.bin > /work/diff_bootloader.txt 2>&1 || true
  echo "  rebuilt from its release tag, identical to ${BL_LABEL}: $(cat /work/bl_rebuilt_match.txt)"
fi

echo ""
echo "[Phase3] Done"
COMPARE_SCRIPT
then
  no_verdict "Phase 3 (comparison) container failed"
fi

# Read Phase 3 outputs using shell builtins
BUILT_NOSIG_SHA256=""; FIRMWARE_MATCH=""; BUILT_BL_SHA256D=""; EXPECTED_BL_HASH=""; BL_HASH_IN_C=""
DIFF_LINES="0"; BL_SOURCE_LABEL="bootloader.bin"
[[ -f "${WORK_DIR}/built_nosig_sha256.txt" ]]     && read -r BUILT_NOSIG_SHA256  < "${WORK_DIR}/built_nosig_sha256.txt"
[[ -f "${WORK_DIR}/firmware_match.txt" ]]          && read -r FIRMWARE_MATCH      < "${WORK_DIR}/firmware_match.txt"
[[ -f "${WORK_DIR}/built_bl_sha256d.txt" ]]        && read -r BUILT_BL_SHA256D    < "${WORK_DIR}/built_bl_sha256d.txt"
[[ -f "${WORK_DIR}/expected_bl_hash.txt" ]]        && read -r EXPECTED_BL_HASH    < "${WORK_DIR}/expected_bl_hash.txt"
[[ -f "${WORK_DIR}/bl_hash_in_c.txt" ]]            && read -r BL_HASH_IN_C        < "${WORK_DIR}/bl_hash_in_c.txt"
[[ -f "${WORK_DIR}/bootloader_source_label.txt" ]] && read -r BL_SOURCE_LABEL     < "${WORK_DIR}/bootloader_source_label.txt"
[[ -f "${WORK_DIR}/diff_firmware_lines.txt" ]]     && read -r DIFF_LINES          < "${WORK_DIR}/diff_firmware_lines.txt"
BL_REBUILT_SHA256=""; BL_DAT_SHA256=""; BL_REBUILT_MATCH=""
[[ -f "${WORK_DIR}/bl_rebuilt_sha256.txt" ]] && read -r BL_REBUILT_SHA256 < "${WORK_DIR}/bl_rebuilt_sha256.txt"
[[ -f "${WORK_DIR}/bl_dat_sha256.txt" ]]     && read -r BL_DAT_SHA256     < "${WORK_DIR}/bl_dat_sha256.txt"
[[ -f "${WORK_DIR}/bl_rebuilt_match.txt" ]]  && read -r BL_REBUILT_MATCH  < "${WORK_DIR}/bl_rebuilt_match.txt"

if [[ -z "$FIRMWARE_MATCH" ]]; then
  no_verdict "Phase 3 did not record a firmware comparison result"
fi
log_success "Phase 3 complete"

# ---- Verdict ----
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

# The bundled bootloader must also rebuild from its release tag (Danny, 2026-10-22, as for Safe 3/5).
if [[ "$BOOTLOADER_VERDICT" == "reproducible" ]]; then
  if [[ "$BL_REBUILD" == "no-tag" ]]; then
    BOOTLOADER_VERDICT="not_reproducible"; BL_NOTES="${BL_NOTES}; no release tag ${BL_TAG}, so not rebuilt from source"
  elif [[ "$BL_REBUILT_MATCH" == "yes" ]]; then
    BL_NOTES="${BL_NOTES}; rebuilt from ${BL_TAG}: byte-identical"
  else
    BOOTLOADER_VERDICT="not_reproducible"; BL_NOTES="${BL_NOTES}; rebuilt from ${BL_TAG}: differs (sha256 ${BL_REBUILT_SHA256:-none} vs ${BL_DAT_SHA256:-none})"
  fi
fi

OVERALL_VERDICT="not_reproducible"
if [[ "$FIRMWARE_VERDICT" == "reproducible" ]]; then
  # Only "skipped" (no bootloader data at all) is acceptable alongside firmware reproducible.
  # A "not_reproducible" or hash-gap bootloader blocks the overall reproducible verdict.
  if [[ "$BOOTLOADER_VERDICT" == "reproducible" || "$BOOTLOADER_VERDICT" == "skipped" ]]; then
    OVERALL_VERDICT="reproducible"
  fi
fi

# ---- Results summary ----

# Numeric match values for BUILDS MATCH BINARIES format
FW_MATCH_INT="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo 1 || echo 0 )"
FW_MATCH_LABEL="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
BL_MATCH_INT="$( [[ "$BOOTLOADER_VERDICT" == "reproducible" ]] && echo 1 || echo 0 )"
BL_MATCH_LABEL="$( [[ "$BOOTLOADER_VERDICT" == "reproducible" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
RB_MATCH_INT="$( [[ "$BL_REBUILT_MATCH" == "yes" ]] && echo 1 || echo 0 )"
RB_MATCH_LABEL="$( [[ "$BL_REBUILT_MATCH" == "yes" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
TOTAL_ARTIFACTS=2; [[ -n "$BL_TAG" ]] && TOTAL_ARTIFACTS=3
MATCH_COUNT=$(( FW_MATCH_INT + BL_MATCH_INT ))
(( TOTAL_ARTIFACTS == 3 )) && MATCH_COUNT=$(( MATCH_COUNT + RB_MATCH_INT ))
MISMATCH_COUNT=$(( TOTAL_ARTIFACTS - MATCH_COUNT ))

# Git tag and signature info
TAG_TYPE_LABEL="unknown"; TAG_SIG_KIND="unknown"; COMMIT_SIG="unknown"
[[ -f "${WORK_DIR}/tag_sig.txt" ]]    && read -r TAG_SIG_KIND < "${WORK_DIR}/tag_sig.txt"
[[ -f "${WORK_DIR}/commit_sig.txt" ]] && read -r COMMIT_SIG   < "${WORK_DIR}/commit_sig.txt"
TAG_SIG_LINE="[WARNING] Tag signature status unknown"
case "${BUILD_TAG_TYPE}" in
  tag)
    TAG_TYPE_LABEL="annotated"
    case "$TAG_SIG_KIND" in
      ssh)  TAG_SIG_LINE="[INFO] Tag carries an SSH signature (not verified: no Trezor key pinned)" ;;
      pgp)  TAG_SIG_LINE="[INFO] Tag carries a PGP signature (not verified: no Trezor key pinned)" ;;
      none) TAG_SIG_LINE="[WARNING] Tag is not signed" ;;
    esac ;;
  commit) TAG_TYPE_LABEL="lightweight"; TAG_SIG_LINE="[INFO] Lightweight tag (cannot contain a signature)" ;;
esac
case "$COMMIT_SIG" in
  yes) COMMIT_SIG_LINE="[INFO] Commit carries a signature (not verified)" ;;
  no)  COMMIT_SIG_LINE="[WARNING] Commit is not signed" ;;
  *)   COMMIT_SIG_LINE="[WARNING] Commit signature status unknown" ;;
esac

# Tag verification output without git's SSH-signer config noise (bash loop; no host grep)
TAG_VERIFY_LINES=()
if [[ -f "${WORK_DIR}/tag_verify.txt" ]]; then
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" == *gpg.ssh.allowedSignersFile* ]] && continue
    TAG_VERIFY_LINES+=("$_line")
  done < "${WORK_DIR}/tag_verify.txt"
fi

# First 5 differing bytes for the terminal (bash mapfile; no host head)
DIFF_PREVIEW=()
if [[ "$FIRMWARE_MATCH" != "yes" && -f "${WORK_DIR}/diff_firmware.txt" ]]; then
  mapfile -t -n 5 DIFF_PREVIEW < "${WORK_DIR}/diff_firmware.txt"
fi

echo ""
echo "Hash legend:"
echo "  appHash = SHA-256 of the official firmware file exactly as downloaded. Publish this one."
echo "  officialNosigHash / builtNosigHash (after End) = SHA-256 of the images with the"
echo "  signature region (bytes 544-738) zeroed. Comparison only; never publish."
echo "  builtBootloaderSha256d = double SHA-256 of the bootloader, as bl_check.txt records it."
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${OVERALL_VERDICT}"
echo "appHash:        ${OFFICIAL_RAW_SHA256}"
echo "commit:         ${BUILD_COMMIT}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo ""
echo "Diff:"
echo "BUILDS MATCH BINARIES"
echo "${RELEASE_FILENAME} - arm-t1b1-${build_type} - ${BUILT_NOSIG_SHA256} - ${FW_MATCH_INT} (${FW_MATCH_LABEL})"
echo "${BL_SOURCE_LABEL} - arm-t1b1 - ${BUILT_BL_SHA256D:-N/A} - ${BL_MATCH_INT} (${BL_MATCH_LABEL})"
[[ -n "$BL_TAG" ]] && echo "bootloader.bin (rebuilt from ${BL_TAG}) - arm-t1b1 - ${BL_REBUILT_SHA256:-N/A} - ${RB_MATCH_INT} (${RB_MATCH_LABEL})"
echo ""
echo "SUMMARY"
echo "total: ${TOTAL_ARTIFACTS}"
echo "matches: ${MATCH_COUNT}"
echo "mismatches: ${MISMATCH_COUNT}"
if (( ${#DIFF_PREVIEW[@]} > 0 )); then
  echo ""
  echo "First differing bytes (offset official built), ${DIFF_LINES} lines in total:"
  printf '%s\n' "${DIFF_PREVIEW[@]}"
  echo "Full diff: ${WORK_DIR}/diff_firmware.txt"
fi
echo ""
echo "Revision, tag (and its signature):"
echo "${GIT_TAG} -> ${BUILD_COMMIT}"
if (( ${#TAG_VERIFY_LINES[@]} > 0 )); then printf '%s\n' "${TAG_VERIFY_LINES[@]}"; fi
echo ""
echo "Signature Summary:"
echo "Tag type: ${TAG_TYPE_LABEL}"
echo "${TAG_SIG_LINE}"
echo "${COMMIT_SIG_LINE}"
echo "===== End Results ====="
echo ""
echo "type:                   ${build_type}"
echo "tag:                    ${GIT_TAG}"
echo "officialFile:           ${RELEASE_FILENAME}"
echo "officialNosigHash:      ${OFFICIAL_NOSIG_SHA256}"
echo "builtNosigHash:         ${BUILT_NOSIG_SHA256}"
echo "builtBootloaderSha256d: ${BUILT_BL_SHA256D:-N/A}"
echo "firmwareVerdict:        ${FIRMWARE_VERDICT}"
echo "bootloaderVerdict:      ${BOOTLOADER_VERDICT}"
echo "bootloaderCheck:        ${BL_NOTES}"
echo "                        SHA256d (double-SHA256) vs bl_check.txt entry for v${BOOTLOADER_VERSION:-N/A}"
[[ "${BL_HASH_IN_C}" == "yes" ]] && echo "                        cross-verified against bl_check.c (compiled into firmware)"
[[ -n "$BL_TAG" ]] && echo "bootloaderRebuild:      ${BL_TAG} (commit ${BL_TAG_COMMIT:-unknown}); committed bootloader.dat sha256 ${BL_DAT_SHA256:-N/A}"
echo "signerNote:             firmware signed by Trezor (SatoshiLabs s.r.o.); see"
echo "                        https://github.com/trezor/trezor-firmware/blob/legacy/v${version}/legacy/bootloader/firmware_sign.py"
echo ""
echo "Run a full"
echo "diffoscope \"${WORK_DIR}/official_firmware_nosig.bin\" \"${WORK_DIR}/built_firmware_nosig.bin\""
echo "for more details."
echo ""

# ---- Write COMPARISON_RESULTS.yaml ----
YAML_NOTES="Firmware v${version} type=${build_type} tag=${GIT_TAG} commit=${BUILD_COMMIT}. Firmware: ${FIRMWARE_VERDICT}. Bootloader: ${BOOTLOADER_VERDICT}. ${BL_NOTES}"
write_results_yaml "$OVERALL_VERDICT" "$YAML_NOTES"

log_info "=============================================="
log_info "VERDICT   : ${OVERALL_VERDICT}"
log_info "Firmware  : ${FIRMWARE_VERDICT}"
log_info "Bootloader: ${BOOTLOADER_VERDICT}"
log_info "Results   : ${CANONICAL_RESULTS}"
log_info "Work dir  : ${WORK_DIR}"
log_info "=============================================="

if [[ "$OVERALL_VERDICT" == "reproducible" ]]; then
  log_success "REPRODUCIBLE"
  exit "$EXIT_OK"
fi
log_warn "NOT REPRODUCIBLE"
exit "$EXIT_FAIL"
