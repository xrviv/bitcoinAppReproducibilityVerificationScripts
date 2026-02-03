#!/usr/bin/env bash
# ======================================================================================
# bitcoinsafedesktop_build.sh - Bitcoin Safe Desktop Reproducible Build Verification
# ======================================================================================
# Version:       v0.6.0
# Organization:  WalletScrutiny.com
# Last Modified: 2026-02-03
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

APP_ID="bitcoinsafe"
SCRIPT_VERSION="v0.6.0"
REPO_URL="https://github.com/andreasgriffin/bitcoin-safe.git"
RELEASE_BASE="https://github.com/andreasgriffin/bitcoin-safe/releases/download"

# Build configuration variables
NEEDS_SIGNATURE_STRIP=false

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
  ./bitcoinsafedesktop_build.sh --version <version> [--arch <arch>] [--type <type>]

REQUIRED PARAMETERS:
  --version <version>    Release version to verify (e.g., 1.6.0)

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

  --help, -h             Show this help text

OUTPUT:
  - Exit code 0: Build is reproducible
  - Exit code 1: Build failed or is not reproducible
  - COMPARISON_RESULTS.yaml: Machine-readable comparison results
  - Standardized results format between ===== Begin/End Results =====

EXAMPLES:
  # Verify Linux AppImage (default)
  ./bitcoinsafedesktop_build.sh --version 1.6.0

  # Verify Linux AppImage (explicit)
  ./bitcoinsafedesktop_build.sh --version 1.6.0 --arch x86_64-linux --type appimage

  # Verify Debian package
  ./bitcoinsafedesktop_build.sh --version 1.6.0 --arch x86_64-linux --type deb

  # Verify Windows portable executable
  ./bitcoinsafedesktop_build.sh --version 1.6.0 --arch x86_64-windows --type portable

  # Verify Windows setup installer
  ./bitcoinsafedesktop_build.sh --version 1.6.0 --arch x86_64-windows --type setup

REQUIREMENTS:
  - docker or podman    Container runtime (build.py runs compilation inside Docker)
  - python3 (3.10+)    Required by Poetry and build.py
  - poetry              Python dependency manager (auto-installed via pip3 if missing)
  - git                 Version control operations
  - curl                Download official releases
  - sha256sum           Hash verification

  Note: Poetry orchestrates the build on the host; actual compilation runs inside Docker.
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
# PARAMETER PARSING
# ======================================================================================

VERSION=""
ARCH="x86_64-linux"
BUILD_TYPE=""

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
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown parameter: $1"
        show_help
        exit 1
        ;;
    esac
  done

  if [[ -z "$VERSION" ]]; then
    log_error "Missing required parameter: --version"
    show_help
    exit 1
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
  else
    log_warn "Tag $ref not found, trying ${VERSION}"
    (cd "$REPO_DIR" && git checkout "$VERSION")
  fi

  (cd "$REPO_DIR" && git submodule update --init --recursive)

  SOURCE_DATE_EPOCH=$(cd "$REPO_DIR" && git log -1 --format=%ct HEAD)
  export SOURCE_DATE_EPOCH
  log_info "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
}

# ======================================================================================
# BUILD PROCESS
# ======================================================================================

run_build() {
  log_info "Starting containerized build (this may take several minutes)..."

  local start_ts end_ts
  start_ts=$(date +%s)

  (
    cd "$REPO_DIR"
    export SOURCE_DATE_EPOCH
    export PYTHONHASHSEED=22
    export PYTHONIOENCODING="utf-8"

    # Container runtime setup
    # build.py calls 'docker' commands internally; if only podman is
    # available, create a temporary wrapper so 'docker' resolves to podman
    if command_exists podman && ! command_exists docker; then
      log_info "Only Podman found - creating temporary docker wrapper"
      local tmpbin
      tmpbin=$(mktemp -d)
      ln -s "$(which podman)" "${tmpbin}/docker"
      export PATH="${tmpbin}:${PATH}"
    elif command_exists docker; then
      export DOCKER_BUILDKIT=1
      log_info "Using Docker for build"
    else
      log_error "Neither Docker nor Podman found. Please install one of them."
      log_error "  - Docker: https://docs.docker.com/engine/install/"
      log_error "  - Podman: https://podman.io/getting-started/installation"
      exit 1
    fi

    # Ensure Poetry is available
    if ! command_exists poetry; then
      log_info "Poetry not found, attempting install..."
      pip3 install --user poetry || {
        log_error "Failed to install Poetry"
        log_error "Install manually: pip3 install poetry"
        exit 1
      }
      export PATH="$HOME/.local/bin:$PATH"
    fi
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

    log_info "Running: poetry run python tools/build.py --targets ${build_targets} --commit None"
    poetry run python tools/build.py --targets ${build_targets} --commit None || {
      log_error "Build failed"
      exit 1
    }
  )

  end_ts=$(date +%s)
  BUILD_DURATION=$(( end_ts - start_ts ))
  log_success "Build completed in ${BUILD_DURATION}s"
}

# ======================================================================================
# ARTIFACT COMPARISON
# ======================================================================================

download_official() {
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

  # Use Docker/Podman to run osslsigncode (avoid host dependency)
  local CONTAINER_CMD=""
  if command_exists podman; then
    CONTAINER_CMD="podman"
  elif command_exists docker; then
    CONTAINER_CMD="docker"
  else
    log_error "Neither Docker nor Podman found"
    return 1
  fi

  local input_basename output_basename
  input_basename=$(basename "$input_file")
  output_basename=$(basename "$output_file")

  # Run osslsigncode in container
  $CONTAINER_CMD run --rm \
    -v "$(dirname "$input_file"):/work" \
    -w /work \
    debian:bookworm \
    bash -c "apt-get update -qq && apt-get install -y -qq osslsigncode >/dev/null 2>&1 && osslsigncode remove-signature -in '${input_basename}' -out '${output_basename}'" \
    || {
    log_error "Failed to strip signature in container"
    return 1
  }

  log_success "Signature stripped successfully"
  return 0
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
    
    built_compare="${BUILT_FILE}.stripped"
    official_compare="${OFFICIAL_FILE}.stripped"
    
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

    # Show first 30 lines of diff for quick triage
    log_warn "First 30 lines of diff:"
    head -30 "$diff_output" | while IFS= read -r line; do
      echo "  $line"
    done

    BUILT_HASH="$built_ai_hash"
    OFFICIAL_HASH="$official_ai_hash"
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
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"

  log_info "Generating COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
date: $(date -u '+%Y-%m-%dT%H:%M:%S%z')
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${ARCH}
    filename: $(basename "${BUILT_FILE}")
    hash: ${BUILT_HASH}
    match: ${MATCH_STATUS}
    status: ${VERDICT_STATUS}
EOF

  log_success "COMPARISON_RESULTS.yaml generated: ${yaml_file}"
}

generate_error_yaml() {
  local error_status="$1"  # ftbfs, nosource, etc.
  local error_msg="$2"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"

  log_info "Generating error COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
date: $(date -u '+%Y-%m-%dT%H:%M:%S%z')
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${ARCH}
    filename: N/A
    hash: N/A
    match: false
    status: ${error_status}
    error: ${error_msg}
EOF

  log_info "Error YAML generated: ${yaml_file}"
}

# ======================================================================================
# RESULTS SUMMARY
# ======================================================================================

print_summary() {
  # Determine verdict based on match status
  local verdict=""
  if [[ "${MATCH_STATUS}" == "true" ]]; then
    verdict="reproducible"
  else
    verdict=""  # Empty for non-reproducible (legacy compatibility)
  fi

  # Determine match indicator for Diff section
  local match_indicator="0 (DOESN'T MATCH)"
  if [[ "${MATCH_STATUS}" == "true" ]]; then
    match_indicator="1 (MATCHES)"
  fi

  echo
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${OFFICIAL_HASH:-N/A}"
  echo "commit:         N/A"
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
  echo "Tag: v${VERSION} (checked out from git)"
  echo "Note: Git signature verification not implemented"
  echo
  local diff_file="$WORKDIR/diff-appimage-contents.txt"
  if [[ -f "$diff_file" ]]; then
    local diff_lines
    diff_lines=$(wc -l < "$diff_file")
    echo "AppImage content diff (${diff_lines} lines):"
    if [[ "$diff_lines" -le 50 ]]; then
      cat "$diff_file"
    else
      head -50 "$diff_file"
      echo "... (${diff_lines} total lines, see ${diff_file})"
    fi
    echo
  fi
  echo "===== End Results ====="
  echo
}

# ======================================================================================
# MAIN EXECUTION
# ======================================================================================

main() {
  log_info "Starting bitcoinsafedesktop_build.sh script version ${SCRIPT_VERSION}"
  log_info "Bitcoin Safe Desktop Build Verification Script"
  log_info "========================================================"

  # Check requirements
  require_command git "Install git to clone the repository"
  require_command curl "Install curl to download official releases"
  require_command sha256sum "Install coreutils for hash verification"
  require_command python3 "Install Python 3.10+ (required by Poetry and build.py)"
  
  if ! command_exists docker && ! command_exists podman; then
    log_error "Neither Docker nor Podman found. Install one of them to proceed."
    exit 1
  fi

  # Parse arguments
  parse_args "$@"

  # Map architecture and type to build configuration
  map_build_config "$ARCH" "$BUILD_TYPE"

  # Setup workspace
  setup_workspace

  # Prepare repository
  prepare_repository

  # Download official artifact
  if ! download_official; then
    log_error "Failed to download official artifact"
    generate_error_yaml "nosource" "Failed to download official release from GitHub"
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
  local comparison_result=0
  compare_artifacts || comparison_result=$?

  # Generate YAML output
  generate_comparison_yaml

  # Print summary
  print_summary

  # Exit with appropriate code
  if [[ "$comparison_result" -eq 0 ]]; then
    log_success "Verification complete: Build is REPRODUCIBLE (exit code: 0)"
    exit 0
  else
    log_warn "Verification complete: Build is NOT REPRODUCIBLE (exit code: 1)"
    exit 1
  fi
}

# Run main function
main "$@"
