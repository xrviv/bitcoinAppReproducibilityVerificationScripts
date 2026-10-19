#!/usr/bin/env bash
# ==============================================================================
# cakewalletdesktop_build.sh - Cake Wallet Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.5
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-04
# Project:       https://github.com/cake-tech/cake_wallet
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and binary comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Downloads official Cake Wallet Linux artifacts from GitHub releases (inside container)
# - Clones source code repository and checks out the exact release tag (inside container)
# - Performs containerized reproducible build using the official Cake Wallet builder image
#   (ghcr.io/cake-tech/cake_wallet:debian13-flutter3.32.0-ndkr28-go1.24.1-ruststablenightly)
# - Uses prebuilt monero_c, torch_dart, and reown_flutter libraries (matching CI)
# - Generates dummy API secrets (open build — official release uses real API keys)
# - Compares built artifacts against official releases using diff analysis
# - Generates COMPARISON_RESULTS.yaml for build server automation
#
# ⚠️  KNOWN NON-REPRODUCIBILITY: The official release embeds real third-party API keys
#     (EtherScan, Polygon, Moralis, Ankr, etc.) injected via GitHub Actions secrets.
#     Open builds use empty/dummy keys from tool/generate_new_secrets.dart.
#     Expect verdict: not_reproducible due to embedded key material differences.
#
# SUPPORTED CONFIGURATIONS:
#   --arch x86_64-linux-gnu --type tarball    Linux bundle (compared against tar.xz release)
#   --arch x86_64-linux-gnu --type flatpak    Linux Flatpak bundle
#
# NOT SUPPORTED:
#   Windows (.exe) — requires real Windows OS + Inno Setup, not feasible from Linux
#
# ONLY HOST DEPENDENCY: docker or podman
# ==============================================================================

set -euo pipefail

# ---------- Styling ----------
readonly NC="\033[0m"
readonly GREEN="\033[1;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[1;31m"
readonly BLUE="\033[1;34m"
readonly CYAN="\033[1;36m"
SUCCESS_ICON="[OK]"
WARNING_ICON="[WARN]"
ERROR_ICON="[ERROR]"
INFO_ICON="[INFO]"

APP_ID="cakewallet"
APP_NAME="Cake Wallet Desktop"
SCRIPT_VERSION="v0.2.5"
REPO_URL="https://github.com/cake-tech/cake_wallet"
RELEASE_BASE="https://github.com/cake-tech/cake_wallet/releases/download"
# Official Cake Wallet builder image (Debian 13, Flutter 3.32.0, Go 1.24.1, Rust, Flatpak)
DOCKER_IMAGE="ghcr.io/cake-tech/cake_wallet:debian13-flutter3.32.0-ndkr28-go1.24.1-ruststablenightly"

# Resolve script directory: COMPARISON_RESULTS.yaml is written here per ABS spec
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Logging ----------
log_info()    { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn()    { echo -e "${YELLOW}${WARNING_ICON}${NC} $*"; }
log_error()   { echo -e "${RED}${ERROR_ICON}${NC} $*" >&2; }

# ---------- YAML Output Functions ----------
# Defined early so they can be called from any point in the script (including
# error paths during parameter validation and download).

generate_error_yaml() {
  # Writes an error COMPARISON_RESULTS.yaml with the given status and message.
  # Called on download failure (nosource), build failure (ftbfs), or invalid
  # parameter combinations that prevent any comparison from running.
  local error_status="$1"   # nosource, ftbfs, spam, etc.
  local error_msg="$2"
  local yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
  local arch_val="${ARCH:-unknown}"
  local type_val="${BUILD_TYPE:-unknown}"

  cat > "$yaml_file" <<EOF
date: $(date -u '+%Y-%m-%dT%H:%M:%S%z')
script_version: ${SCRIPT_VERSION}
build_type: ${type_val}
results:
  - architecture: ${arch_val}
    status: ${error_status}
    error: "${error_msg}"
    files:
      - filename: N/A
        hash: N/A
        match: false
EOF
  log_info "Error YAML written: ${yaml_file} (status: ${error_status})"
}

generate_comparison_yaml() {
  # Writes the final COMPARISON_RESULTS.yaml after a completed comparison.
  # architecture matches the --arch parameter exactly (ABS requirement).
  local yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
  log_info "Generating COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
date: $(date -u '+%Y-%m-%dT%H:%M:%S%z')
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${ARCH}
    status: ${VERDICT_STATUS}
    files:
      - filename: ${COMPARISON_FILENAME}
        hash: ${BUILT_HASH}
        match: ${MATCH_STATUS}
EOF
  log_success "COMPARISON_RESULTS.yaml: ${yaml_file}"
}

# ---------- Usage ----------
usage() {
  cat <<EOF
${APP_NAME} Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> --arch <arch> --type <type>

Required Parameters:
  --version <version>    Version without v prefix (e.g., 5.9.0)
  --arch    <arch>       Architecture. Supported: x86_64-linux-gnu
  --type    <type>       Build type:
                           tarball   Compare bundle contents against official tar.xz
                           flatpak   Compare Flatpak bundle against official .flatpak

Silently Ignored (build server compatibility):
  --apk     <path>       Not applicable for desktop builds; logged and ignored

Flags:
  --help                 Show this help message

Examples:
  $(basename "$0") --version 5.9.0 --arch x86_64-linux-gnu --type tarball
  $(basename "$0") --version 5.9.0 --arch x86_64-linux-gnu --type flatpak

Requirements:
  - docker or podman (ONLY host dependency)
  - ~20 GB disk space (builder image is large)
  - ~30-60 minutes build time

Output:
  - Exit 0: reproducible
  - Exit 1: not_reproducible or build failure
  - Exit 2: invalid parameters
  - COMPARISON_RESULTS.yaml written to script directory

⚠️  Expected outcome: not_reproducible — official release embeds real API keys
    (EtherScan, Moralis, Ankr, etc.) unavailable in open builds. Diff output
    shows exactly which files contain the differing key material.

Not supported:
  Windows (.exe) — requires real Windows OS + Inno Setup, not feasible from Linux.

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parameter Parsing ----------
VERSION=""
ARCH="x86_64-linux-gnu"
BUILD_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"; shift 2 ;;
    --arch)
      ARCH="$2"; shift 2 ;;
    --type)
      BUILD_TYPE="$2"; shift 2 ;;
    --apk)
      # Accepted silently per ABS requirement; desktop apps do not use --apk
      log_info "--apk ignored: ${APP_NAME} is a desktop app"
      shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      log_error "Unknown parameter: $1"
      usage
      exit 2 ;;
  esac
done

# ---------- Root Check ----------
# The script must run as a normal user. Running as root risks polluting the
# host system and conflicts with container user-mapping expectations.
if [[ "$(id -u)" -eq 0 ]]; then
  log_error "Do not run this script as root. Use a normal user with docker/podman access."
  exit 2
fi

# ---------- Validation (exit 2 for bad parameters) ----------
if [[ -z "$VERSION" ]]; then
  log_error "Missing required parameter: --version"
  usage; exit 2
fi

if [[ -z "$BUILD_TYPE" ]]; then
  log_error "Missing required parameter: --type (tarball or flatpak)"
  usage; exit 2
fi

if [[ "$ARCH" != "x86_64-linux-gnu" ]]; then
  log_error "Unsupported architecture: ${ARCH}"
  log_error "Supported: x86_64-linux-gnu"
  log_error "Note: Windows builds require a Windows host and are not supported here"
  exit 2
fi

if [[ "$BUILD_TYPE" != "tarball" && "$BUILD_TYPE" != "flatpak" ]]; then
  log_error "Unsupported type: ${BUILD_TYPE}"
  log_error "Supported: tarball, flatpak"
  exit 2
fi

# ---------- Container Detection ----------
# Honour CONTAINER_CMD env var override; otherwise prefer docker, then podman.
# Docker and podman are the ONLY host dependencies for this script.
if [[ -n "${CONTAINER_CMD:-}" ]]; then
  container_cmd="$CONTAINER_CMD"
elif command -v docker >/dev/null 2>&1; then
  container_cmd="docker"
elif command -v podman >/dev/null 2>&1; then
  container_cmd="podman"
else
  log_error "Neither docker nor podman found. Install one of them to proceed."
  log_error "  Docker: https://docs.docker.com/engine/install/"
  log_error "  Podman: https://podman.io/getting-started/installation"
  exit 1
fi
log_info "Container runtime: ${container_cmd}"

host_uid=$(id -u)
host_gid=$(id -g)

# ---------- Workspace Setup ----------
# Use $$ (PID) in workspace name for parallel-safety when the build server
# runs multiple arch/type combinations concurrently.
execution_dir="$(pwd)"
WORKDIR="${execution_dir}/cakewallet_${VERSION}_${ARCH}_${BUILD_TYPE}_$$"
OFFICIAL_DIR="${WORKDIR}/official"
SOURCE_DIR="${WORKDIR}/source"

mkdir -p "$OFFICIAL_DIR" "$SOURCE_DIR"

log_info "============================================================"
log_info "${APP_NAME} v${VERSION} Verification"
log_info "============================================================"
log_info "Script version: ${SCRIPT_VERSION}"
log_info "Architecture:   ${ARCH}"
log_info "Build type:     ${BUILD_TYPE}"
log_info "Workspace:      ${WORKDIR}"
log_info ""
log_warn "NOTE: Official release embeds real API keys (EtherScan, Moralis, Ankr, etc.)"
log_warn "      Open build uses dummy secrets. Verdict expected: not_reproducible."
log_info ""

# ---------- Determine Official Release Filename ----------
# Official GitHub release filenames observed for v5.9.0:
#   Cake_Wallet_v5.9.0_Linux.tar.xz    (96.4 MB)
#   Cake_Wallet_v5.9.0_Linux.flatpak   (99.1 MB)
if [[ "$BUILD_TYPE" == "tarball" ]]; then
  OFFICIAL_FILENAME="Cake_Wallet_v${VERSION}_Linux.tar.xz"
elif [[ "$BUILD_TYPE" == "flatpak" ]]; then
  OFFICIAL_FILENAME="Cake_Wallet_v${VERSION}_Linux.flatpak"
fi
OFFICIAL_FILE="${OFFICIAL_DIR}/${OFFICIAL_FILENAME}"

# ---------- Download Official Release ----------
# Use alpine (tiny ~8 MB image) rather than the multi-GB builder image.
# Alpine is almost always cached or pulls in seconds, avoiding a long silent
# hang that would occur when pulling the Cake Wallet builder image here.
log_info "Downloading official release: ${OFFICIAL_FILENAME}"
log_info "(Using alpine container for download — fast, avoids pulling the large builder image)"

download_ok=false
for tag_prefix in "v${VERSION}" "${VERSION}"; do
  url="${RELEASE_BASE}/${tag_prefix}/${OFFICIAL_FILENAME}"
  log_info "Trying: ${url}"
  if ${container_cmd} run --rm \
    -v "${OFFICIAL_DIR}:${OFFICIAL_DIR}" \
    alpine \
    wget "$url" -O "$OFFICIAL_FILE"; then
    log_success "Downloaded ${OFFICIAL_FILENAME}"
    download_ok=true
    break
  fi
done

if [[ "$download_ok" == "false" ]]; then
  log_error "Failed to download official release: ${OFFICIAL_FILENAME}"
  log_error "Check that version v${VERSION} exists at: ${RELEASE_BASE}"
  generate_error_yaml "nosource" "Failed to download official release from GitHub"
  exit 1
fi

# Fix ownership: alpine runs as root; chown file back to the host user
${container_cmd} run --rm \
  -v "${OFFICIAL_DIR}:${OFFICIAL_DIR}" \
  alpine \
  chown -R "${host_uid}:${host_gid}" "${OFFICIAL_DIR}" 2>/dev/null || true

OFFICIAL_HASH=$(sha256sum "$OFFICIAL_FILE" | awk '{print $1}')
log_info "Official SHA256: ${OFFICIAL_HASH}"

# ---------- Write Inner Build Script ----------
# This bash script runs INSIDE the official Cake Wallet Docker builder image.
# Variables that must be evaluated by the outer shell at write-time are
# interpolated directly (SOURCE_DIR, VERSION, BUILD_TYPE, REPO_URL).
# Variables that must be evaluated at run-time inside the container are
# escaped with \${...} or \$(...).
INNER_BUILD_SCRIPT="${WORKDIR}/inner_build.sh"

cat > "$INNER_BUILD_SCRIPT" << INNER_EOF
#!/bin/bash
set -x -e

# Allow git to operate on the mounted host volume path
git config --global --add safe.directory '*'

# Variables injected from outer script at write-time
SOURCE_DIR="${SOURCE_DIR}"
VERSION="${VERSION}"
BUILD_TYPE="${BUILD_TYPE}"
REPO_URL="${REPO_URL}"

mkdir -p "\${SOURCE_DIR}"
cd "\${SOURCE_DIR}"

echo "[INFO] Cloning ${REPO_URL} at tag v\${VERSION}..."
# --branch checks out the tag directly; --depth 1 keeps the clone lean
git clone --branch "v\${VERSION}" --depth 1 "\${REPO_URL}" .
echo "[INFO] Commit: \$(git log -1 --oneline)"

# -----------------------------------------------------------------------
# Step 1: Fetch prebuilt Torch (torch_dart v1.0.17)
# torch_dart is a Flutter plugin providing Monero signing primitives.
# Pre-built to avoid complex native compilation; matches CI workflow.
# -----------------------------------------------------------------------
pushd scripts
  wget https://github.com/MrCyjaneK/torch_dart/releases/download/v1.0.17/torch_dart-v1.0.17.tar.gz -O torch_dart.tar.gz
  mkdir -p torch_dart
  tar -xzf torch_dart.tar.gz -C torch_dart
  rm torch_dart.tar.gz
popd
echo "[INFO] Torch prepared"

# -----------------------------------------------------------------------
# Step 2: Fetch prebuilt Reown (reown_flutter v0.0.4)
# Reown is the WalletConnect v2 Flutter library. Pre-built to avoid Rust
# compilation; matches CI workflow "Fetch prebuilt Reown" step.
# -----------------------------------------------------------------------
pushd scripts
  rm -rf reown_flutter
  wget https://github.com/cake-tech/reown_flutter/releases/download/v0.0.4/reown_flutter-v0.0.4.tar.gz -O reown_flutter.tar.gz
  mkdir -p reown_flutter
  tar -xzf reown_flutter.tar.gz -C reown_flutter
  rm reown_flutter.tar.gz
popd
echo "[INFO] Reown prepared"

# -----------------------------------------------------------------------
# Step 3: Build Zcash library from source
# zcash_lib (commit 647231e) provides shielded transaction support via
# zwallet (Rust). build_zcash.sh clones the repo and compiles the library.
# Matches CI workflow "Build Zcash Lib" step.
# -----------------------------------------------------------------------
pushd scripts/linux
  ./build_zcash.sh
popd
echo "[INFO] Zcash library built"

# -----------------------------------------------------------------------
# Step 4: Build bitbox_flutter from source
# BitBox02 hardware wallet Flutter plugin requiring native compilation.
# Matches CI workflow "Build Bitbox Flutter" step.
# -----------------------------------------------------------------------
pushd scripts
  ./build_bitbox_flutter.sh
popd
echo "[INFO] Bitbox flutter built"

# -----------------------------------------------------------------------
# Step 5: Prepare prebuilt monero_c (v0.18.4.0-RC9 release bundle)
# monero_c is the C library wrapping Monero/Wownero wallet functionality.
# Building from source takes hours; the CI uses prebuilt .so files from
# the tagged release bundle. .xz files are decompressed in place.
# build_monero_all.sh will detect existing .so files and skip compilation.
# -----------------------------------------------------------------------
mkdir -p scripts/monero_c
pushd scripts/monero_c
  wget https://github.com/MrCyjaneK/monero_c/releases/download/v0.18.4.0-RC9/release-bundle.zip
  unzip release-bundle.zip
  rm release-bundle.zip
  unxz -fv release/*/*.xz
popd
echo "[INFO] monero_c prebuilts prepared"

# -----------------------------------------------------------------------
# Step 6: Build mwebd (MWEB daemon, Go)
# mwebd provides MimbleWimble Extension Block support for Litecoin.
# Built from source at the pinned commit extracted from build_mwebd.sh.
# Matches CI workflow "Build mwebd" step.
# -----------------------------------------------------------------------
export MWEBD_HASH=\$(grep 'git reset --hard' scripts/android/build_mwebd.sh | xargs | awk '{ print \$4 }')
echo "[INFO] MWEBD_HASH=\${MWEBD_HASH}"
pushd scripts/android
  ./build_mwebd.sh
popd
echo "[INFO] mwebd built"

# -----------------------------------------------------------------------
# Step 7: Configure app (app_env.sh + app_config.sh)
# app_env.sh exports APP_LINUX_VERSION, APP_LINUX_BUILD_NUMBER, etc.
# app_config.sh runs dart tool/configure.dart with coin feature flags,
# patches pubspec.yaml with the version, and runs flutter pub get.
# Matches CI workflow "Execute Build and Setup Commands" step.
# -----------------------------------------------------------------------
pushd scripts/linux
  source ./app_env.sh cakewallet
  ./app_config.sh
popd
echo "[INFO] App configured"

# -----------------------------------------------------------------------
# Step 8: Install Flutter dependencies
# Resolves pubspec.yaml dependencies set by app_config.sh above.
# Matches CI workflow "Install Flutter dependencies" step.
# -----------------------------------------------------------------------
flutter pub get
echo "[INFO] Flutter dependencies installed"

# -----------------------------------------------------------------------
# Step 9: Generate model code
# model_generator.sh produces Dart serialization boilerplate from
# annotated source files. 'async' flag enables background mode.
# Matches CI workflow "Build generated code" step.
# -----------------------------------------------------------------------
./model_generator.sh async
echo "[INFO] Model code generated"

# -----------------------------------------------------------------------
# Step 10: Generate localization
# Produces lib/generated/ Dart files from ARB translation resources.
# Matches CI workflow "Generate localization" step.
# -----------------------------------------------------------------------
dart run tool/generate_localization.dart
echo "[INFO] Localization generated"

# -----------------------------------------------------------------------
# Step 11: Generate dummy secrets (OPEN BUILD)
# The official CI injects real API keys via GitHub Actions secrets into
# the .secrets.g.dart files (EtherScan, Moralis, Ankr, Polygon, etc.).
# This tool writes empty strings for all keys as a substitute.
# Result: binaries WILL differ from the official release at this step.
# -----------------------------------------------------------------------
dart run tool/generate_new_secrets.dart
echo "[WARN] Dummy secrets generated — binary WILL differ from official release"

# -----------------------------------------------------------------------
# Step 12: Zcash params workaround (empty placeholder files)
# The CI test pipeline touches empty sapling parameter files instead of
# downloading the real ones (~50 MB each). Real params are required for
# shielded Zcash transactions at runtime but not at compile time.
# Matches CI workflow "Workaround zcash" step.
# -----------------------------------------------------------------------
mkdir -p scripts/zcash_lib/assets/
touch scripts/zcash_lib/assets/sapling-spend.params
touch scripts/zcash_lib/assets/sapling-output.params
echo "[INFO] Zcash params workaround applied"

# -----------------------------------------------------------------------
# Step 13: Build Flutter Linux app
# --dart-define=hasDevOptions=true matches the flag used in the CI.
# --release produces the optimized output bundle in:
#   build/linux/x64/release/bundle/
# -----------------------------------------------------------------------
flutter build linux --dart-define=hasDevOptions=true --release
echo "[INFO] Flutter Linux build complete"

# -----------------------------------------------------------------------
# Step 14: Package Flatpak (flatpak type only)
# flatpak-builder uses com.cakewallet.CakeWallet.yml, which has a
# 'type: dir' source pointing to build/linux/x64/release/ — it packages
# the pre-built Flutter bundle into a Flatpak OCI bundle.
# Requires --privileged Docker flag for flatpak-builder filesystem mounts.
# -----------------------------------------------------------------------
if [[ "\${BUILD_TYPE}" == "flatpak" ]]; then
  cp -r build/linux/x64 build/linux/current
  flatpak-builder --force-clean flatpak-build com.cakewallet.CakeWallet.yml
  flatpak build-export export flatpak-build
  flatpak build-bundle export build/linux/x64/cake_wallet.flatpak com.cakewallet.CakeWallet
  echo "[INFO] Flatpak built: build/linux/x64/cake_wallet.flatpak"
fi

echo "[INFO] Inner build complete"
INNER_EOF

chmod +x "$INNER_BUILD_SCRIPT"

# ---------- Run Container Build ----------
log_info "Pulling builder image (skip with CONTAINER_CMD=... if already cached)..."
${container_cmd} pull "$DOCKER_IMAGE" || log_warn "Pull failed — attempting build with cached image"

log_info "Running build inside container..."
log_info "Image: ${DOCKER_IMAGE}"

# --privileged is required by flatpak-builder to mount FUSE filesystems.
# It is harmless for tarball builds and simplifies a single shared run command.
build_ok=true
if ! ${container_cmd} run \
  --privileged \
  --rm \
  -v "${WORKDIR}:${WORKDIR}" \
  -w "${WORKDIR}" \
  "$DOCKER_IMAGE" \
  bash "${INNER_BUILD_SCRIPT}"; then
  build_ok=false
fi

# Fix file ownership: the builder runs as root; chown output back to host user
# so workspace files are accessible/deletable without sudo. Use alpine (tiny)
# rather than the large builder image — no need for the full toolchain here.
${container_cmd} run --rm \
  -v "${WORKDIR}:${WORKDIR}" \
  alpine \
  chown -R "${host_uid}:${host_gid}" "${WORKDIR}" 2>/dev/null || true

if [[ "$build_ok" == "false" ]]; then
  log_error "Container build failed — check output above"
  generate_error_yaml "ftbfs" "Container build failed"
  exit 1
fi

log_success "Container build completed"

# ---------- Locate Built Artifacts ----------
BUNDLE_DIR="${SOURCE_DIR}/build/linux/x64/release/bundle"
BUILT_BINARY="${BUNDLE_DIR}/cake_wallet"

if [[ ! -f "$BUILT_BINARY" ]]; then
  log_error "Built binary not found: ${BUILT_BINARY}"
  generate_error_yaml "ftbfs" "flutter build linux succeeded but cake_wallet binary not found"
  exit 1
fi

BUILT_BINARY_HASH=$(sha256sum "$BUILT_BINARY" | awk '{print $1}')
log_success "Built binary found: ${BUILT_BINARY}"
log_info   "Built binary SHA256: ${BUILT_BINARY_HASH}"

if [[ "$BUILD_TYPE" == "flatpak" ]]; then
  BUILT_FLATPAK="${SOURCE_DIR}/build/linux/x64/cake_wallet.flatpak"
  if [[ ! -f "$BUILT_FLATPAK" ]]; then
    log_error "Built flatpak not found: ${BUILT_FLATPAK}"
    generate_error_yaml "ftbfs" "flatpak build succeeded but cake_wallet.flatpak not found"
    exit 1
  fi
  log_success "Built flatpak found: ${BUILT_FLATPAK}"
fi

# ---------- Comparison Functions ----------

compare_tarball() {
  # Extracts both the official tar.xz and our built bundle, then runs diff -r.
  # The tar.xz outer archive hash is NOT compared — the CI produces a .zip,
  # not a .tar.xz; the release tar.xz is created by a separate pipeline not
  # in the repo. We compare extracted bundle contents file-by-file instead.
  log_info "------------------------------------------------------------"
  log_info "Tarball comparison: extracting and running diff -r"
  log_info "------------------------------------------------------------"

  local official_extracted="${WORKDIR}/official_extracted"
  local built_extracted="${WORKDIR}/built_extracted"
  mkdir -p "$official_extracted" "$built_extracted"

  # Extract official tar.xz
  log_info "Extracting official tar.xz..."
  tar -xJf "$OFFICIAL_FILE" -C "$official_extracted"
  log_success "Official archive extracted to ${official_extracted}"

  # Copy our built bundle for side-by-side comparison
  log_info "Copying built bundle..."
  cp -r "$BUNDLE_DIR" "${built_extracted}/bundle"
  log_success "Built bundle copied to ${built_extracted}/bundle"

  # Locate the cake_wallet binary inside the official extraction.
  # The tar.xz may have a top-level wrapper dir (e.g. bundle/, cake_wallet-5.9.0/)
  # or it may place files directly. Resolve dynamically.
  local official_bundle_root
  official_bundle_root=$(find "$official_extracted" -maxdepth 3 -name "cake_wallet" -type f \
    | head -n1 | xargs -I{} dirname {} 2>/dev/null || true)
  if [[ -z "$official_bundle_root" ]]; then
    log_warn "cake_wallet binary not found inside official tar.xz; diffing entire extraction"
    official_bundle_root="$official_extracted"
  fi
  local built_bundle_root="${built_extracted}/bundle"

  log_info "Official bundle root: ${official_bundle_root}"
  log_info "Built bundle root:    ${built_bundle_root}"

  # Hash the official cake_wallet ELF binary for reporting
  local official_binary="${official_bundle_root}/cake_wallet"
  if [[ -f "$official_binary" ]]; then
    OFFICIAL_HASH_RESULT=$(sha256sum "$official_binary" | awk '{print $1}')
    log_info "Official binary SHA256: ${OFFICIAL_HASH_RESULT}"
  else
    log_warn "cake_wallet binary not found at expected path in official extraction"
    OFFICIAL_HASH_RESULT="NOT_FOUND"
  fi

  # Run diff -r and preserve full output for human analysis
  local diff_file="${WORKDIR}/diff-bundle.txt"
  log_info "Running diff -r (output → ${diff_file})..."
  diff -r --no-dereference "$official_bundle_root" "$built_bundle_root" > "$diff_file" 2>&1 || true

  local diff_lines
  diff_lines=$(wc -l < "$diff_file")
  log_info "diff -r: ${diff_lines} lines"

  if [[ "$diff_lines" -eq 0 ]]; then
    log_success "Bundle contents are IDENTICAL"
    MATCH_STATUS="true"
    VERDICT_STATUS="reproducible"
  else
    log_warn "Bundle contents DIFFER (${diff_lines} lines)"
    local file_summary
    file_summary=$(grep -E "^(diff -r|Only in|Binary files)" "$diff_file" || true)
    local file_count
    file_count=$(echo "$file_summary" | grep -c . 2>/dev/null || echo 0)
    log_warn "Differing files (${file_count} total, first 5 shown):"
    echo "$file_summary" | head -5 | while IFS= read -r line; do echo "  $line"; done
    log_info "Full diff: ${diff_file}"
    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
  fi

  # Use the official release filename and the built binary hash for YAML
  COMPARISON_FILENAME="${OFFICIAL_FILENAME}"
  BUILT_HASH="${BUILT_BINARY_HASH}"
}

compare_flatpak() {
  # Compares the official .flatpak bundle against our built bundle by hash.
  # Flatpak bundles use OSTree content-addressed storage — identical app
  # content produces identical inner objects, but bundle metadata and
  # signing timestamps may cause the outer file to differ.
  # A hash match here means bit-for-bit identical; a mismatch is expected
  # due to embedded API secrets and any metadata differences.
  log_info "------------------------------------------------------------"
  log_info "Flatpak comparison: SHA256 hash"
  log_info "------------------------------------------------------------"

  local built_flatpak_hash
  built_flatpak_hash=$(sha256sum "$BUILT_FLATPAK" | awk '{print $1}')

  log_info "Official flatpak SHA256: ${OFFICIAL_HASH}"
  log_info "Built flatpak SHA256:    ${built_flatpak_hash}"

  BUILT_HASH="$built_flatpak_hash"
  OFFICIAL_HASH_RESULT="$OFFICIAL_HASH"
  COMPARISON_FILENAME="${OFFICIAL_FILENAME}"

  if [[ "$OFFICIAL_HASH" == "$built_flatpak_hash" ]]; then
    log_success "Flatpak hashes MATCH"
    MATCH_STATUS="true"
    VERDICT_STATUS="reproducible"
  else
    log_warn "Flatpak hashes DIFFER (expected due to embedded API secrets)"
    local official_size built_size
    official_size=$(stat -c%s "$OFFICIAL_FILE")
    built_size=$(stat -c%s "$BUILT_FLATPAK")
    log_info "Official size: ${official_size} bytes"
    log_info "Built size:    ${built_size} bytes"
    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
  fi
}

# ---------- Run Comparison ----------
# Initialize globals used by both comparison functions and the YAML generator
MATCH_STATUS="false"
VERDICT_STATUS="not_reproducible"
BUILT_HASH=""
OFFICIAL_HASH_RESULT=""
COMPARISON_FILENAME=""

if [[ "$BUILD_TYPE" == "tarball" ]]; then
  compare_tarball
elif [[ "$BUILD_TYPE" == "flatpak" ]]; then
  compare_flatpak
fi

# ---------- Generate YAML ----------
generate_comparison_yaml

# ---------- Standardized Results Block ----------
# Format required by WalletScrutiny build server and report tooling.
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${VERSION}"
echo "apkVersionCode: N/A"
echo "verdict:        ${VERDICT_STATUS}"
echo "appHash:        ${OFFICIAL_HASH_RESULT:-N/A}"
echo "commit:         N/A"
echo ""
echo "Diff:"
if [[ "$MATCH_STATUS" == "true" ]]; then
  echo "BUILDS MATCH BINARIES"
else
  echo "BUILDS DO NOT MATCH BINARIES"
fi
echo "${COMPARISON_FILENAME} - ${ARCH} - ${BUILT_HASH} - $([ "$MATCH_STATUS" == "true" ] && echo "1 (MATCHES)" || echo "0 (DIFFERS)")"
echo ""
echo "Known cause of differences (if any):"
echo "Official release embeds real API keys (EtherScan, Moralis, Ankr, etc.)"
echo "via GitHub Actions secrets. Open build uses empty dummy keys."
echo ""
if [[ "$BUILD_TYPE" == "tarball" && -f "${WORKDIR}/diff-bundle.txt" && "$MATCH_STATUS" == "false" ]]; then
  local_diff_lines=$(wc -l < "${WORKDIR}/diff-bundle.txt")
  local_file_summary=$(grep -E "^(diff -r|Only in|Binary files)" "${WORKDIR}/diff-bundle.txt" || true)
  local_file_count=$(echo "$local_file_summary" | grep -c . 2>/dev/null || echo 0)
  echo "Differing files (${local_file_count} total, first 5 shown):"
  echo "$local_file_summary" | head -5
  echo "..."
  echo "See full diff: ${WORKDIR}/diff-bundle.txt"
fi
echo ""
echo "Revision, tag (and its signature):"
echo "Tag: v${VERSION} — checked out from git at build time"
echo ""
echo "===== End Results ====="
echo ""

# ---------- Summary ----------
log_info "============================================================"
log_info "Verification Summary"
log_info "============================================================"
log_info "Version:    ${VERSION}"
log_info "Arch:       ${ARCH}"
log_info "Type:       ${BUILD_TYPE}"
log_info "Verdict:    ${VERDICT_STATUS}"
log_info "Workspace:  ${WORKDIR}"
log_info "YAML:       ${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

if [[ "$VERDICT_STATUS" == "reproducible" ]]; then
  log_success "REPRODUCIBLE"
  echo "Exit code: 0"
  exit 0
else
  log_warn "NOT REPRODUCIBLE"
  echo "Exit code: 1"
  exit 1
fi
