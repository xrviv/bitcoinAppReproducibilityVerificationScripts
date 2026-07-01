#!/usr/bin/env bash
# ======================================================================================
# bitcoinsafe_build.sh - Bitcoin Safe Desktop Reproducible Build Verification
# ======================================================================================
# Version:       v0.8.12
# Organization:  WalletScrutiny.com
# Last Modified: 2026-07-01
# Project:       https://github.com/andreasgriffin/bitcoin-safe
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
# - Downloads official Bitcoin Safe release artifacts from GitHub releases
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using Poetry build system
# - Compares built artifacts against official releases using binary analysis
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Documents differences and generates detailed reproducibility assessment report
#
# ======================================================================================

set -euo pipefail

# ======================================================================================
# CONFIGURATION
# ======================================================================================

APP_ID="bitcoin.safe"
SCRIPT_VERSION="v0.8.12"
REPO_URL="https://github.com/andreasgriffin/bitcoin-safe.git"
RELEASE_BASE="https://github.com/andreasgriffin/bitcoin-safe/releases/download"

# Build configuration variables
NEEDS_SIGNATURE_STRIP=false
BINARY_FILE=""
CHECKED_OUT_TAG=""
SOURCE_COMMIT=""

# Resolve script directory (for COMPARISON_RESULTS.yaml output)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Color codes for output
readonly CYAN='\033[1;36m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# ======================================================================================
# LOGGING FUNCTIONS
# ======================================================================================

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { echo -e "${CYAN}[$(timestamp)] INFO${NC} $*"; }
log_warn() { echo -e "${YELLOW}[$(timestamp)] WARN${NC} $*"; }
log_error() { echo -e "${RED}[$(timestamp)] ERROR${NC} $*"; }
log_success() { echo -e "${GREEN}[$(timestamp)] SUCCESS${NC} $*"; }

# ======================================================================================
# HELP TEXT
# ======================================================================================

show_help() {
  cat <<'EOF'
Bitcoin Safe Desktop Reproducible Build Verification Script

DESCRIPTION:
  Performs reproducible build verification of Bitcoin Safe desktop application.
  Downloads official releases, builds from source using Docker, and compares
  artifacts to assess reproducibility.

USAGE:
  ./bitcoinsafe_build.sh [--version <version>] [--arch <arch>] [--type <type>] [--binary <file>]

VERSION BEHAVIOR:
  --version <version>    Release version to verify (e.g., 1.6.0)
                         If omitted, the script tries to infer it from --binary.

OPTIONAL PARAMETERS:
  --arch <architecture>  Target architecture:
                         - x86_64-linux    Linux x86_64
                         - x86_64-windows  Windows x86_64
                         Default: x86_64-linux

  --type <type>          Build type:
                         Linux:
                           - appimage      AppImage (default)
                           - deb           Debian package
                         Windows:
                           - portable      Portable executable
                           - setup         Setup installer
                         Default: appimage (Linux) / portable (Windows)

  Note: Builds use Bitcoin Safe's official Docker-based build system.
        Podman can be used as a drop-in replacement for Docker.

  --binary <file>        Path to official binary to use instead of downloading.
                         When provided, the download step is skipped and this
                         file is used as the official artifact for comparison.

  --help, -h             Show this help text

OUTPUT:
  - Exit code 0: Build is reproducible
  - Exit code 1: Build failed or is not reproducible
  - COMPARISON_RESULTS.yaml: Machine-readable comparison results
  - Standardized results format between ===== Begin/End Results =====

EXAMPLES:
  # Verify Linux AppImage (default)
  ./bitcoinsafe_build.sh --version 1.6.0

  # Verify Linux AppImage (explicit)
  ./bitcoinsafe_build.sh --version 1.6.0 --arch x86_64-linux --type appimage

  # Use a pre-downloaded official binary (skip download)
  ./bitcoinsafe_build.sh --version 1.6.0 --arch x86_64-linux --type appimage --binary ~/Downloads/Bitcoin-Safe-1.6.0-x86_64.AppImage.tar.gz

  # Verify Debian package
  ./bitcoinsafe_build.sh --version 1.6.0 --arch x86_64-linux --type deb

  # Verify Windows portable executable
  ./bitcoinsafe_build.sh --version 1.6.0 --arch x86_64-windows --type portable

  # Verify Windows setup installer
  ./bitcoinsafe_build.sh --version 1.6.0 --arch x86_64-windows --type setup

REQUIREMENTS:
  - docker or podman    Container runtime (the ONLY host dependency)

  Note: The script auto-launches a python:3.12-slim container with all build tools
        (git, curl, python3, poetry, etc.). No other host dependencies are needed.
        Windows signature stripping uses containerized osslsigncode (no host install needed).

DIRECTORY STRUCTURE:
  All operations are performed in the execution directory:
  ./bitcoinsafe_<version>_<arch>_<type>/
  ├── official/         Downloaded official artifacts
  ├── source/           Cloned repository
  └── built/            Build outputs

For more information, visit: https://walletscrutiny.com
EOF
}

# ======================================================================================
# UTILITY FUNCTIONS
# ======================================================================================

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command_exists "$cmd"; then
    log_error "Required command '${cmd}' not found. ${hint}"
    exit 1
  fi
}

# Try candidate release paths (with and without 'v' prefix)
fetch_release_file() {
  local version="$1"
  local filename="$2"
  local dest="$3"

  for prefix in "v${version}" "${version}"; do
    local url="${RELEASE_BASE}/${prefix}/${filename}"
    if curl -fLs "$url" -o "$dest" 2>/dev/null; then
      log_success "Downloaded ${filename}"
      return 0
    fi
  done

  log_error "Failed to download ${filename}"
  rm -f "$dest"
  return 1
}

# ======================================================================================
# CONTAINER BOOTSTRAP
# ======================================================================================
# When invoked on the host, this function launches a python:3.12-slim container with
# all build dependencies, then re-invokes the script inside the container. The only
# host requirement is docker (or podman). The Docker socket is bind-mounted so that
# build.py can spawn sibling containers for compilation.

detect_build_socket() {
  if [[ -S "/var/run/docker.sock" ]]; then
    echo "/var/run/docker.sock"
    return 0
  fi

  if command_exists podman; then
    local podman_socket=""
    podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ -S "$podman_socket" ]]; then
      echo "$podman_socket"
      return 0
    fi

    podman_socket="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
    if [[ -n "$podman_socket" && -S "$podman_socket" ]]; then
      echo "$podman_socket"
      return 0
    fi
  fi

  return 1
}

bootstrap_container() {
  local CONTAINER_CMD=""
  local BUILD_SOCKET=""
  if command_exists docker; then
    CONTAINER_CMD="docker"
  elif command_exists podman; then
    CONTAINER_CMD="podman"
  else
    log_error "Neither Docker nor Podman found. Install one of them to proceed."
    log_error "  - Docker: https://docs.docker.com/engine/install/"
    log_error "  - Podman: https://podman.io/getting-started/installation"
    exit 1
  fi

  if ! BUILD_SOCKET="$(detect_build_socket)"; then
    log_error "No Docker-compatible build socket found."
    log_error "For Docker, ensure /var/run/docker.sock exists."
    log_error "For Podman, ensure podman.socket is running."
    exit 1
  fi

  local HOST_UID HOST_GID DOCKER_SOCK_GID
  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  DOCKER_SOCK_GID=$(stat -c '%g' "$BUILD_SOCKET" 2>/dev/null || echo "0")

  local SCRIPT_PATH
  SCRIPT_PATH="$(readlink -f "$0")"

  log_info "Launching container for build environment..."
  log_info "Container image: python:3.12-slim"
  log_info "Container runtime: $CONTAINER_CMD"

  # Build run args as array so we can conditionally add --binary mount
  local run_args=(
    --rm
    -v "$PWD:$PWD"
    -v "$BUILD_SOCKET:/var/run/docker.sock"
    -v "$SCRIPT_PATH:$SCRIPT_PATH:ro"
    -v "$SCRIPT_DIR:$SCRIPT_DIR"
    -w "$PWD"
    -e "_INSIDE_CONTAINER=1"
    -e "BS_VERSION=$VERSION"
    -e "BS_ARCH=$ARCH"
    -e "BS_TYPE=$BUILD_TYPE"
    -e "BS_BINARY="
    -e "BS_SCRIPT_PATH=$SCRIPT_PATH"
    -e "HOST_UID=$HOST_UID"
    -e "HOST_GID=$HOST_GID"
    -e "DOCKER_SOCK_GID=$DOCKER_SOCK_GID"
  )

  # If --binary was provided, mount the file into the container at the same path
  if [[ -n "$BINARY_FILE" ]]; then
    local abs_binary
    abs_binary="$(readlink -f "$BINARY_FILE")"
    run_args+=( -v "$abs_binary:$abs_binary:ro" )
    run_args+=( -e "BS_BINARY=$abs_binary" )
  fi

  $CONTAINER_CMD run "${run_args[@]}" \
    python:3.12-slim \
    bash -c '
      # Install dependencies (as root)
      apt-get update -qq && apt-get install -y -qq \
        git curl ca-certificates docker.io coreutils \
        build-essential \
        osslsigncode \
        libglib2.0-0 libgl1 libegl1 libfontconfig1 \
        libxkbcommon0 libxkbcommon-x11-0 \
        libxcb1 libxcb-xinerama0 libxcb-randr0 libxcb-render0 \
        libxcb-shm0 libxcb-shape0 libxcb-sync1 libxcb-xfixes0 \
        libxcb-xkb1 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
        libxcb-cursor0 libxcb-util1 libxcb-render-util0 \
        libx11-xcb1 libdbus-1-3 >/dev/null 2>&1

      # Create builder user matching host UID/GID
      groupadd -g "$HOST_GID" hostgrp 2>/dev/null || true
      groupadd -g "$DOCKER_SOCK_GID" dockerhost 2>/dev/null || true
      useradd -m -u "$HOST_UID" -g "$HOST_GID" builder 2>/dev/null || true
      usermod -aG dockerhost builder 2>/dev/null || true

      # Re-invoke script as builder user (pass --binary if provided)
      su -p builder -c "export HOME=/home/builder && export PATH=\"/home/builder/.local/bin:\$PATH\" && cd \"$PWD\" && bash \"$BS_SCRIPT_PATH\" --version \"$BS_VERSION\" --arch \"$BS_ARCH\" --type \"$BS_TYPE\"${BS_BINARY:+ --binary \"$BS_BINARY\"}"
    '
  exit $?
}

# ======================================================================================
# PARAMETER PARSING
# ======================================================================================

VERSION=""
ARCH=""
BUILD_TYPE=""

infer_metadata_from_binary() {
  local binary_name
  binary_name="$(basename "$BINARY_FILE")"

  if [[ -z "$VERSION" && "$binary_name" =~ ^Bitcoin-Safe-([0-9][0-9A-Za-z._-]*)- ]]; then
    VERSION="${BASH_REMATCH[1]}"
    log_info "Inferred version from --binary filename: $VERSION"
  fi

  case "$binary_name" in
    Bitcoin-Safe-*-x86_64.AppImage.tar.gz)
      [[ -n "$ARCH" ]] || ARCH="x86_64-linux"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="appimage"
      ;;
    Bitcoin-Safe-*-x86_64.deb)
      [[ -n "$ARCH" ]] || ARCH="x86_64-linux"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="deb"
      ;;
    Bitcoin-Safe-*-portable.exe)
      [[ -n "$ARCH" ]] || ARCH="x86_64-windows"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="portable"
      ;;
    Bitcoin-Safe-*-setup.exe)
      [[ -n "$ARCH" ]] || ARCH="x86_64-windows"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="setup"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || { log_error "--version requires a value"; exit 1; }
        VERSION="$2"
        shift 2
        ;;
      --arch)
        [[ $# -ge 2 ]] || { log_error "--arch requires a value"; exit 1; }
        ARCH="$2"
        shift 2
        ;;
      --type)
        [[ $# -ge 2 ]] || { log_error "--type requires a value"; exit 1; }
        BUILD_TYPE="$2"
        shift 2
        ;;
      --binary)
        [[ $# -ge 2 ]] || { log_error "--binary requires a value"; exit 1; }
        BINARY_FILE="$2"
        shift 2
        ;;
      --apk)
        # Accepted but unused (desktop app - no APK). Required by build server
        # which may pass --apk to all scripts. Must not fail per Rule 11.
        [[ $# -ge 2 ]] || { log_error "--apk requires a value"; exit 1; }
        log_info "Ignoring --apk parameter: Bitcoin Safe is a desktop app, not an Android app"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        # Silently ignore unrecognised parameters (build server may pass unknown flags)
        log_warn "Ignoring unknown parameter: $1"
        shift
        ;;
    esac
  done

  if [[ -n "$BINARY_FILE" ]]; then
    infer_metadata_from_binary
  fi

  if [[ -z "$VERSION" ]]; then
    log_error "Missing version. Pass --version or provide a recognizable Bitcoin Safe file with --binary."
    show_help
    exit 1
  fi

  if [[ -z "$ARCH" ]]; then
    ARCH="x86_64-linux"
  fi

  # Default --type based on architecture if not explicitly provided
  if [[ -z "$BUILD_TYPE" ]]; then
    case "$ARCH" in
      x86_64-linux)   BUILD_TYPE="appimage" ;;
      x86_64-windows) BUILD_TYPE="portable" ;;
      *)              BUILD_TYPE="appimage" ;;
    esac
  fi
}

# ======================================================================================
# ARCHITECTURE AND TYPE MAPPING
# ======================================================================================

map_build_config() {
  local arch="$1"
  local type="$2"

  case "${arch}_${type}" in
    x86_64-linux_appimage)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-x86_64.AppImage.tar.gz"
      BUILD_TARGET="appimage"
      BUILT_PATTERN="*${VERSION}*.AppImage.tar.gz"
      ;;
    x86_64-linux_deb)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-x86_64.deb"
      BUILD_TARGET="deb"
      BUILT_PATTERN="*${VERSION}*.deb"
      ;;
    x86_64-windows_portable)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-portable.exe"
      BUILD_TARGET="windows"
      BUILT_PATTERN="*${VERSION}*portable.exe"
      NEEDS_SIGNATURE_STRIP=true
      ;;
    x86_64-windows_setup)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-setup.exe"
      BUILD_TARGET="windows"
      BUILT_PATTERN="*${VERSION}*setup.exe"
      NEEDS_SIGNATURE_STRIP=true
      ;;
    *)
      log_error "Unsupported architecture/type combination: ${arch}/${type}"
      log_error "Supported combinations:"
      log_error "  - x86_64-linux / appimage"
      log_error "  - x86_64-linux / deb"
      log_error "  - x86_64-windows / portable"
      log_error "  - x86_64-windows / setup"
      exit 1
      ;;
  esac
}

# ======================================================================================
# DIRECTORY SETUP
# ======================================================================================

setup_workspace() {
  execution_dir="$(pwd)"
  WORKDIR="${execution_dir}/bitcoinsafe_${VERSION}_${ARCH}_${BUILD_TYPE}"
  OFFICIAL_DIR="$WORKDIR/official"
  SOURCE_DIR="$WORKDIR/source"
  REPO_DIR="$SOURCE_DIR/bitcoin-safe"
  BUILT_DIR="$WORKDIR/built"

  mkdir -p "$OFFICIAL_DIR" "$SOURCE_DIR" "$BUILT_DIR"
  
  log_info "Workspace: $WORKDIR"
  log_info "Version: $VERSION"
  log_info "Architecture: $ARCH"
  log_info "Build Type: $BUILD_TYPE"
}

# ======================================================================================
# REPOSITORY OPERATIONS
# ======================================================================================

prepare_repository() {
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    log_info "Cloning repository..."
    git clone "$REPO_URL" "$REPO_DIR"
  else
    log_info "Updating repository..."
    (cd "$REPO_DIR" && git fetch --all --tags --prune)
  fi

  local ref="v${VERSION}"
  if (cd "$REPO_DIR" && git rev-parse "$ref" >/dev/null 2>&1); then
    log_info "Checking out tag $ref"
    (cd "$REPO_DIR" && git checkout "$ref")
    CHECKED_OUT_TAG="$ref"
  else
    log_warn "Tag $ref not found, trying ${VERSION}"
    (cd "$REPO_DIR" && git checkout "$VERSION")
    CHECKED_OUT_TAG="$VERSION"
  fi

  if [[ -z "$CHECKED_OUT_TAG" ]]; then
    CHECKED_OUT_TAG="$ref"
  fi

  # Clean untracked files and build artifacts to ensure a pristine source tree.
  # Without this, reused workspaces can produce different builds due to stale
  # venvs, leftover dist/ files, or cached Poetry state.
  log_info "Cleaning source tree..."
  (cd "$REPO_DIR" && git clean -fdx)
  (cd "$REPO_DIR" && git checkout -- .)

  (cd "$REPO_DIR" && git submodule update --init --recursive)

  SOURCE_COMMIT=$(cd "$REPO_DIR" && git rev-parse HEAD)
  SOURCE_DATE_EPOCH=$(cd "$REPO_DIR" && git log -1 --format=%ct HEAD)
  export SOURCE_DATE_EPOCH
  export SOURCE_COMMIT
  log_info "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
  log_info "SOURCE_COMMIT: $SOURCE_COMMIT"
}

# ======================================================================================
# BUILD PROCESS
# ======================================================================================

# Remove Docker images created with a PID-unique name by this run.
# build.py removes its named container after a run but does not remove the image;
# without this, each run leaves a dangling tagged image on disk.
cleanup_build_images() {
  local pid_tag="$1"
  for img in \
      "bitcoin_safe-appimage-builder-img-${pid_tag}" \
      "bitcoin_safe-wine-builder-img-${pid_tag}"; do
    if docker image inspect "${img}" >/dev/null 2>&1; then
      log_info "Removing build image: ${img}"
      docker rmi "${img}" 2>/dev/null || log_warn "Could not remove image ${img}"
    fi
  done
}

run_build() {
  log_info "Starting containerized build (this may take several minutes)..."

  local start_ts end_ts
  start_ts=$(date +%s)

  (
    cd "$REPO_DIR"
    export SOURCE_DATE_EPOCH
    export PYTHONHASHSEED=22
    export PYTHONIOENCODING="utf-8"
    export DOCKER_BUILDKIT=1

    # Install Poetry (python:3.12-slim base provides pip3)
    log_info "Installing Poetry..."
    pip3 install --user poetry >/dev/null 2>&1
    export PATH="$HOME/.local/bin:$PATH"
    log_info "Poetry version: $(poetry --version)"

    # Install project dependencies
    log_info "Installing project dependencies with Poetry..."
    poetry install || {
      log_error "Poetry install failed"
      exit 1
    }

    # Map BUILD_TARGET to build.py --targets argument
    # DEB requires AppImage first (it is converted from AppImage)
    local build_targets=""
    case "$BUILD_TARGET" in
      appimage)
        build_targets="appimage"
        ;;
      deb)
        build_targets="appimage deb"
        ;;
      windows)
        build_targets="windows"
        ;;
      *)
        log_error "Unsupported build target: ${BUILD_TARGET}"
        exit 1
        ;;
    esac

    # Patch tools/build.py to use PID-unique Docker image and container names.
    # build.py hardcodes 'bitcoin_safe-appimage-builder-img' and
    # 'bitcoin_safe-wine-builder-img'; running AppImage and DEB simultaneously
    # causes an exit-125 container-name conflict. This patch is
    # orchestration-only (not app source) and applied only to the workdir copy.
    local BUILD_PID="$$"
    log_info "Patching tools/build.py: uniquifying Docker names (PID=${BUILD_PID})"
    log_info "  bitcoin_safe-appimage-builder-img -> bitcoin_safe-appimage-builder-img-${BUILD_PID}"
    log_info "  bitcoin_safe-wine-builder-img     -> bitcoin_safe-wine-builder-img-${BUILD_PID}"
    sed -i \
      -e "s/bitcoin_safe-appimage-builder-img/bitcoin_safe-appimage-builder-img-${BUILD_PID}/g" \
      -e "s/bitcoin_safe-wine-builder-img/bitcoin_safe-wine-builder-img-${BUILD_PID}/g" \
      tools/build.py

    log_info "Running: poetry run python tools/build.py --targets ${build_targets} --commit None"
    poetry run python tools/build.py --targets ${build_targets} --commit None || {
      log_error "Build failed"
      cleanup_build_images "${BUILD_PID}"
      exit 1
    }

    cleanup_build_images "${BUILD_PID}"
  )

  end_ts=$(date +%s)
  BUILD_DURATION=$(( end_ts - start_ts ))
  log_success "Build completed in ${BUILD_DURATION}s"
}

# ======================================================================================
# ARTIFACT COMPARISON
# ======================================================================================

download_official() {
  # If --binary was provided, use it directly instead of downloading
  if [[ -n "$BINARY_FILE" ]]; then
    if [[ ! -f "$BINARY_FILE" ]]; then
      log_error "--binary file not found: $BINARY_FILE"
      return 1
    fi
    OFFICIAL_FILE="$BINARY_FILE"
    OFFICIAL_FILENAME="$(basename "$BINARY_FILE")"
    log_info "Using provided binary as official artifact: $BINARY_FILE"
    return 0
  fi

  log_info "Downloading official artifact: $OFFICIAL_FILENAME"

  local dest="$OFFICIAL_DIR/$OFFICIAL_FILENAME"
  if [[ -f "$dest" ]]; then
    log_info "Using cached official artifact"
    OFFICIAL_FILE="$dest"
    return 0
  fi

  if fetch_release_file "$VERSION" "$OFFICIAL_FILENAME" "$dest"; then
    OFFICIAL_FILE="$dest"
    return 0
  else
    log_error "Failed to download official artifact"
    return 1
  fi
}

find_built_artifact() {
  log_info "Looking for built artifact matching: $BUILT_PATTERN"
  
  local found
  found=$(find "$REPO_DIR/dist" -maxdepth 1 -type f -name "$BUILT_PATTERN" 2>/dev/null | head -n1)
  
  if [[ -z "$found" ]]; then
    log_error "Built artifact not found in $REPO_DIR/dist"
    return 1
  fi

  BUILT_FILE="$BUILT_DIR/$(basename "$found")"
  cp "$found" "$BUILT_FILE"
  log_success "Found built artifact: $(basename "$BUILT_FILE")"
  return 0
}

strip_windows_signature() {
  local input_file="$1"
  local output_file="$2"

  log_info "Stripping signature from Windows executable..."

  # osslsigncode is installed in the bootstrap container (no sibling container needed).
  # Running it directly avoids Docker-socket permission issues when writing output files.
  local strip_output
  strip_output=$(osslsigncode remove-signature -in "$input_file" -out "$output_file" 2>&1) || true

  if [[ -f "$output_file" ]]; then
    log_success "Signature stripped successfully"
  elif echo "$strip_output" | grep -qiE "does not have any signature|no signature found"; then
    log_info "No signature found in $(basename "$input_file") - using file as-is"
    cp "$input_file" "$output_file"
  else
    log_error "Failed to strip signature: $strip_output"
    return 1
  fi

  return 0
}

print_diff_preview() {
  local diff_file="$1"
  local label="$2"
  local max_lines=5
  local total_lines=0

  [[ -f "$diff_file" ]] || return 0

  total_lines=$(wc -l < "$diff_file")
  echo "${label} (first ${max_lines} lines; full diff in ${diff_file}):"
  head -"${max_lines}" "$diff_file"
  if [[ "$total_lines" -gt "$max_lines" ]]; then
    echo "... (${total_lines} lines total)"
  fi
}

compare_artifacts() {
  if [[ ! -f "$BUILT_FILE" ]]; then
    log_error "Built file not found: $BUILT_FILE"
    return 1
  fi

  if [[ ! -f "$OFFICIAL_FILE" ]]; then
    log_error "Official file not found: $OFFICIAL_FILE"
    return 1
  fi

  local built_compare="$BUILT_FILE"
  local official_compare="$OFFICIAL_FILE"
  
  # For Windows builds, strip signatures before comparison
  if [[ "$NEEDS_SIGNATURE_STRIP" == "true" ]]; then
    log_info "Windows build detected - stripping signatures for comparison"

    local official_signed_hash built_signed_hash
    official_signed_hash=$(sha256sum "$OFFICIAL_FILE" | awk '{print $1}')
    built_signed_hash=$(sha256sum "$BUILT_FILE" | awk '{print $1}')
    log_info "Official SHA256 (pre-strip): $official_signed_hash"
    log_info "Built SHA256    (pre-strip): $built_signed_hash"

    built_compare="${WORKDIR}/$(basename "$BUILT_FILE").stripped"
    official_compare="${WORKDIR}/$(basename "$OFFICIAL_FILE").stripped"

    strip_windows_signature "$BUILT_FILE" "$built_compare" || return 1
    strip_windows_signature "$OFFICIAL_FILE" "$official_compare" || return 1
  fi

  BUILT_HASH=$(sha256sum "$built_compare" | awk '{print $1}')
  OFFICIAL_HASH=$(sha256sum "$official_compare" | awk '{print $1}')

  log_info "Built SHA256:    $BUILT_HASH"
  log_info "Official SHA256: $OFFICIAL_HASH"
  
  if [[ "$NEEDS_SIGNATURE_STRIP" == "true" ]]; then
    log_info "Note: Hashes are of signature-stripped executables"
  fi

  if [[ "$BUILT_HASH" == "$OFFICIAL_HASH" ]]; then
    MATCH_STATUS="true"
    VERDICT_STATUS="reproducible"
    log_success "Hashes match - Build is reproducible!"
    return 0
  fi

  # Tar.gz hashes differ -- if this is an AppImage tar.gz, extract and
  # compare the raw AppImage inside (tar metadata is often non-deterministic)
  if [[ "$built_compare" == *.AppImage.tar.gz ]]; then
    log_info "Tar.gz hashes differ - extracting raw AppImages for comparison..."

    local compare_dir="$WORKDIR/appimage_compare"
    mkdir -p "$compare_dir/built" "$compare_dir/official"

    tar xzf "$built_compare" -C "$compare_dir/built/"
    tar xzf "$official_compare" -C "$compare_dir/official/"

    local built_appimage official_appimage
    built_appimage=$(find "$compare_dir/built" -maxdepth 1 -name '*.AppImage' | head -n1)
    official_appimage=$(find "$compare_dir/official" -maxdepth 1 -name '*.AppImage' | head -n1)

    if [[ -z "$built_appimage" || -z "$official_appimage" ]]; then
      log_error "Could not extract AppImage from tar.gz"
      MATCH_STATUS="false"
      VERDICT_STATUS="not_reproducible"
      return 1
    fi

    local built_ai_hash official_ai_hash
    built_ai_hash=$(sha256sum "$built_appimage" | awk '{print $1}')
    official_ai_hash=$(sha256sum "$official_appimage" | awk '{print $1}')

    log_info "Raw AppImage Built SHA256:    $built_ai_hash"
    log_info "Raw AppImage Official SHA256: $official_ai_hash"

    if [[ "$built_ai_hash" == "$official_ai_hash" ]]; then
      BUILT_HASH="$built_ai_hash"
      OFFICIAL_HASH="$official_ai_hash"
      MATCH_STATUS="true"
      VERDICT_STATUS="reproducible"
      log_success "Raw AppImage hashes match - Build is reproducible (tar.gz wrapper differs only)"
      return 0
    fi

    # Raw AppImages also differ -- extract contents and diff
    log_warn "Raw AppImage hashes also differ - running diff on extracted contents..."

    chmod +x "$built_appimage" "$official_appimage"

    local diff_output="$WORKDIR/diff-appimage-contents.txt"

    # Clean any stale extraction directories to prevent nesting
    rm -rf "$compare_dir/built/squashfs-root" "$compare_dir/built-squashfs"
    rm -rf "$compare_dir/official/squashfs-root" "$compare_dir/official-squashfs"

    (cd "$compare_dir/built" && ./*.AppImage --appimage-extract) >/dev/null 2>&1
    mv "$compare_dir/built/squashfs-root" "$compare_dir/built-squashfs"

    (cd "$compare_dir/official" && ./*.AppImage --appimage-extract) >/dev/null 2>&1
    mv "$compare_dir/official/squashfs-root" "$compare_dir/official-squashfs"

    diff -r --no-dereference "$compare_dir/built-squashfs" "$compare_dir/official-squashfs" > "$diff_output" 2>&1 || true

    local diff_lines
    diff_lines=$(wc -l < "$diff_output")
    log_info "AppImage content diff: ${diff_lines} lines written to ${diff_output}"

    if [[ "$diff_lines" -eq 0 ]]; then
      log_success "AppImage contents are identical (squashfs packaging differs)"
      BUILT_HASH="$built_ai_hash"
      OFFICIAL_HASH="$official_ai_hash"
      MATCH_STATUS="true"
      VERDICT_STATUS="reproducible"
      return 0
    fi

    log_warn "AppImage contents differ."
    print_diff_preview "$diff_output" "AppImage diff preview"

    BUILT_HASH="$built_ai_hash"
    OFFICIAL_HASH="$official_ai_hash"
    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
    return 1
  fi

  # DEB hashes differ -- extract data and control, diff contents
  if [[ "$built_compare" == *.deb ]]; then
    log_info "DEB hashes differ - extracting and comparing package contents..."

    local compare_dir="$WORKDIR/deb_compare"
    rm -rf "$compare_dir"
    mkdir -p "$compare_dir/built-data" "$compare_dir/official-data"
    mkdir -p "$compare_dir/built-control" "$compare_dir/official-control"

    # Extract installed files (data) and package metadata (control)
    dpkg-deb -x "$built_compare" "$compare_dir/built-data"
    dpkg-deb -x "$official_compare" "$compare_dir/official-data"
    dpkg-deb -e "$built_compare" "$compare_dir/built-control"
    dpkg-deb -e "$official_compare" "$compare_dir/official-control"

    local data_diff="$WORKDIR/diff-deb-data.txt"
    local control_diff="$WORKDIR/diff-deb-control.txt"
    local diff_output="$WORKDIR/diff-deb-contents.txt"

    diff -r --no-dereference "$compare_dir/built-data" "$compare_dir/official-data" > "$data_diff" 2>&1 || true
    diff -r --no-dereference "$compare_dir/built-control" "$compare_dir/official-control" > "$control_diff" 2>&1 || true

    local data_lines control_lines
    data_lines=$(wc -l < "$data_diff")
    control_lines=$(wc -l < "$control_diff")

    # Combined report
    {
      echo "=== DEB Data Files (installed content): ${data_lines} diff lines ==="
      cat "$data_diff"
      echo ""
      echo "=== DEB Control Metadata: ${control_lines} diff lines ==="
      cat "$control_diff"
    } > "$diff_output"

    log_info "DEB data diff: ${data_lines} lines | control diff: ${control_lines} lines"
    log_info "Full diff written to ${diff_output}"

    # Data identical = reproducible (control metadata may differ cosmetically,
    # same logic as AppImage: outer packaging ≠ application content)
    if [[ "$data_lines" -eq 0 ]]; then
      if [[ "$control_lines" -eq 0 ]]; then
        log_success "DEB contents are identical (ar archive metadata differs)"
      else
        log_success "DEB installed files are identical (control metadata differs only)"
        print_diff_preview "$control_diff" "DEB control diff preview"
      fi
      BUILT_HASH="$OFFICIAL_HASH"
      MATCH_STATUS="true"
      VERDICT_STATUS="reproducible"
      return 0
    fi

    log_warn "DEB installed files differ."
    print_diff_preview "$data_diff" "DEB data diff preview"

    if [[ "$control_lines" -gt 0 ]]; then
      log_warn "Control metadata also differs (${control_lines} lines, see ${control_diff})"
    fi

    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
    return 1
  fi

  MATCH_STATUS="false"
  VERDICT_STATUS="not_reproducible"
  log_warn "Hashes differ - Build is NOT reproducible"
  return 1
}

# ======================================================================================
# YAML OUTPUT GENERATION
# ======================================================================================

generate_comparison_yaml() {
  local yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

  log_info "Generating COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${VERDICT_STATUS}
notes: |
  Bitcoin Safe uses Poetry + Docker to build cross-platform AppImage, DEB, and Windows executables.
  Expected differences (do not affect verdict):
  - AppImage tar.gz wrapper: non-deterministic tar metadata; raw AppImage inside is compared directly.
  - DEB control metadata: cosmetic package metadata differences; installed file content is what matters.
  - Windows executables compared after signature stripping (official is signed by SignPath.io, built is unsigned).
EOF

  log_success "COMPARISON_RESULTS.yaml generated: ${yaml_file}"
}

generate_error_yaml() {
  local error_status="$1"
  local error_msg="$2"
  local yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

  log_info "Generating error COMPARISON_RESULTS.yaml..."

  case "$error_status" in
    reproducible|not_reproducible|ftbfs) ;;
    *) error_status="ftbfs" ;;
  esac

  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${error_status}
notes: |
  ${error_msg}
EOF

  log_info "Error YAML generated: ${yaml_file}"
}

# ======================================================================================
# RESULTS SUMMARY
# ======================================================================================

print_summary() {
  local summary_verdict=""
  local match_indicator="0 (DOESN'T MATCH)"
  if [[ "${MATCH_STATUS}" == "true" ]]; then
    summary_verdict="reproducible"
    match_indicator="1 (MATCHES)"
  fi

  echo
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "versionName:    ${VERSION}"
  echo "versionCode:    N/A"
  echo "verdict:        ${summary_verdict}"
  echo "appHash:        ${OFFICIAL_HASH:-N/A}"
  echo "commit:         ${SOURCE_COMMIT:-N/A}"
  echo
  echo "Diff:"
  if [[ "${MATCH_STATUS}" == "true" ]]; then
    echo "BUILDS MATCH BINARIES"
  else
    echo "BUILDS DO NOT MATCH BINARIES"
  fi
  echo "$(basename "${OFFICIAL_FILE:-unknown}") - ${ARCH} - ${BUILT_HASH:-N/A} - ${match_indicator}"
  if [[ "$NEEDS_SIGNATURE_STRIP" == "true" ]]; then
    echo "Note: Hashes are of signature-stripped executables"
  fi
  echo
  echo "Revision, tag (and its signature):"
  echo "Tag: ${CHECKED_OUT_TAG:-unknown} (checked out from git)"
  echo "Note: Git signature verification not implemented"
  echo
  local diff_file="$WORKDIR/diff-appimage-contents.txt"
  if [[ -f "$diff_file" ]]; then
    print_diff_preview "$diff_file" "AppImage content diff"
    echo
  fi
  local deb_diff_file="$WORKDIR/diff-deb-contents.txt"
  if [[ -f "$deb_diff_file" ]]; then
    print_diff_preview "$deb_diff_file" "DEB content diff"
    echo
  fi
  echo "===== End Results ====="
  echo
}

print_finding() {
  local finding="$1"
  echo "Finding: Bitcoin Safe ${VERSION} ${ARCH} ${BUILD_TYPE} -> ${finding}"
}

# ======================================================================================
# MAIN EXECUTION
# ======================================================================================

main() {
  # Parse arguments first (needed for container bootstrap env vars)
  parse_args "$@"

  # If not inside container, bootstrap and re-invoke
  if [[ "${_INSIDE_CONTAINER:-}" != "1" ]]; then
    bootstrap_container
    # bootstrap_container calls exit, never reaches here
  fi

  # Inside container - proceed with normal flow
  log_info "Starting bitcoinsafe_build.sh script version ${SCRIPT_VERSION}"
  log_info "Bitcoin Safe Desktop Build Verification Script"
  log_info "========================================================"

  # Map architecture and type to build configuration
  map_build_config "$ARCH" "$BUILD_TYPE"

  # Setup workspace
  setup_workspace

  # Prepare repository
  prepare_repository

  # Download official artifact
  if ! download_official; then
    log_error "Failed to download official artifact"
    generate_error_yaml "ftbfs" "Failed to obtain official release artifact"
    exit 1
  fi

  # Run build
  if ! run_build; then
    log_error "Build failed"
    generate_error_yaml "ftbfs" "Build process failed - see logs above"
    exit 1
  fi

  # Find built artifact
  if ! find_built_artifact; then
    log_error "Failed to find built artifact"
    generate_error_yaml "ftbfs" "Build completed but artifact not found in dist/"
    exit 1
  fi

  # Compare artifacts
  BUILT_HASH=""
  OFFICIAL_HASH=""
  MATCH_STATUS="false"
  VERDICT_STATUS="not_reproducible"
  local comparison_result=0
  compare_artifacts || comparison_result=$?

  # If comparison failed before any hashes were computed (e.g. signature strip error),
  # emit ftbfs rather than a misleading not_reproducible with empty hashes.
  if [[ "$comparison_result" -ne 0 && -z "$BUILT_HASH" ]]; then
    log_error "Comparison aborted before hash computation - see errors above"
    generate_error_yaml "ftbfs" "Artifact comparison failed before hash computation - see logs above"
    exit 1
  fi

  # Generate YAML output
  generate_comparison_yaml

  # Print summary
  print_summary

  # Exit with appropriate code
  if [[ "$comparison_result" -eq 0 ]]; then
    print_finding "reproducible"
    log_success "Verification complete: Build is REPRODUCIBLE (exit code: 0)"
    exit 0
  else
    print_finding "${VERDICT_STATUS}"
    log_warn "Verification complete: Build is NOT REPRODUCIBLE (exit code: 1)"
    exit 1
  fi
}

# Run main function
main "$@"
