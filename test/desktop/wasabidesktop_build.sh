#!/usr/bin/env bash
# ==============================================================================
# wasabidesktop_build.sh - Wasabi Wallet Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v1.3.0
# Organization:  WalletScrutiny.com
# Last Modified: 2025-11-26
# Project:       https://github.com/WalletWasabi/WalletWasabi
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
# - Downloads official Wasabi Wallet release binaries from GitHub releases
# - Clones source code repository and checks out the exact release tag
# - Verifies Git tag authenticity (GPG signatures + commit hash logging)
# - Performs containerized reproducible build using embedded Dockerfile
# - Builds using Wasabi's official Contrib/release.sh script inside container
# - Compares built binaries with official releases using SHA256 hash comparison
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Supports multiple architectures: x86_64-linux-gnu, win64, osx64
#
# SECURITY NOTES:
# - All verification happens inside containers (no host dependencies)
# - Wasabi's GPG key is fetched from keyservers and verified by fingerprint
# - Git tag signatures are checked; warnings issued if unsigned
# - Commit hashes logged for manual verification
#
# REQUIREMENTS:
# - Docker or Podman installed (no other dependencies needed)
# - Internet connection for downloading source and binaries

set -euo pipefail

# ---------- Script Metadata ----------
SCRIPT_VERSION="v1.3.0"
APP_NAME="Wasabi Wallet"
APP_ID="wasabi"

# ---------- Styling ----------
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
SUCCESS_ICON="[OK]"
WARNING_ICON="[WARN]"
ERROR_ICON="[ERROR]"
INFO_ICON="[INFO]"

# ---------- Logging Functions ----------
log_info() {
  echo -e "${BLUE}${INFO_ICON}${NC} $*"
}

log_success() {
  echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}${WARNING_ICON}${NC} $*"
}

log_error() {
  echo -e "${RED}${ERROR_ICON}${NC} $*"
}

usage() {
  cat <<EOF
Wasabi Desktop Reproducible Build Verification Script

Usage (Named Parameters - Recommended):
  $(basename "$0") --version <version> [--arch <architecture>] [--type <type>]

Usage (Positional Parameters - Legacy):
  $(basename "$0") <version> [<architecture>]

Parameters:
  --version <version>    Wasabi version to verify (e.g., 2.7.1)
  --arch <architecture>  Architecture to build (default: x86_64-linux-gnu)
                         Supported: x86_64-linux-gnu, win64
  --type <type>          Package type to verify (default: varies by arch)
                         x86_64-linux-gnu: deb (default), tarball, zip
                         win64: zip (default), msi

Flags:
  --help, -h             Show this help message

Examples:
  $(basename "$0") --version 2.7.1
  $(basename "$0") --version 2.7.1 --arch x86_64-linux-gnu --type deb
  $(basename "$0") --version 2.7.1 --arch x86_64-linux-gnu --type tarball
  $(basename "$0") --version 2.7.1 --arch win64 --type msi
  $(basename "$0") 2.7.1

Requirements:
  - Docker or Podman installed
  - Internet connection for downloading sources and official releases
  - ~2GB disk space for build artifacts

Output:
  - Exit code 0: Binaries are reproducible
  - Exit code 1: Binaries differ or verification failed
  - Exit code 2: Invalid parameters
  - COMPARISON_RESULTS.yaml: Machine-readable comparison results
  - Standardized results between ===== Begin/End Results =====

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parse Arguments ----------
VERSION=""
ARCH="x86_64-linux-gnu"  # Default architecture
TYPE=""  # Will be set based on architecture if not specified

# Support both positional and named parameters for backward compatibility
if [[ $# -gt 0 && "$1" != --* ]]; then
  # Old style: positional parameters
  VERSION="$1"
  if [[ $# -gt 1 ]]; then
    ARCH="$2"
  fi
else
  # New style: named parameters
  while [[ $# -gt 0 ]]; do
    case $1 in
      --version)
        VERSION="$2"
        shift 2
        ;;
      --arch)
        ARCH="$2"
        shift 2
        ;;
      --type)
        TYPE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown parameter: $1"
        usage
        exit 2
        ;;
    esac
  done
fi

# ---------- Validate Parameters ----------
if [ -z "$VERSION" ]; then
  log_error "--version parameter is required"
  usage
  exit 1
fi

# Validate version format (semantic versioning with optional 'v' prefix)
if ! [[ "$VERSION" =~ ^[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  log_error "Invalid version format: $VERSION"
  log_error "Expected format: X.Y.Z or vX.Y.Z (e.g., 2.7.0 or v2.7.0)"
  exit 1
fi

# Validate architecture
if [[ "$ARCH" != "x86_64-linux-gnu" && "$ARCH" != "win64" ]]; then
  log_error "Unsupported architecture: $ARCH"
  echo "Supported architectures: x86_64-linux-gnu, win64"
  exit 2
fi

# Set default TYPE based on ARCH if not specified
if [ -z "$TYPE" ]; then
  case "$ARCH" in
    x86_64-linux-gnu)
      TYPE="deb"
      ;;
    win64)
      TYPE="zip"
      ;;
  esac
fi

# Validate TYPE for the given ARCH
case "$ARCH" in
  x86_64-linux-gnu)
    if [[ "$TYPE" != "deb" && "$TYPE" != "tarball" && "$TYPE" != "zip" ]]; then
      log_error "Invalid type '$TYPE' for architecture '$ARCH'"
      echo "Valid types for x86_64-linux-gnu: deb, tarball, zip"
      exit 2
    fi
    ;;
  win64)
    if [[ "$TYPE" != "zip" && "$TYPE" != "msi" ]]; then
      log_error "Invalid type '$TYPE' for architecture '$ARCH'"
      echo "Valid types for win64: zip, msi"
      exit 2
    fi
    ;;
esac

# ---------- Detect Container Runtime ----------
CONTAINER_CMD=""
if command -v podman &> /dev/null; then
  CONTAINER_CMD="podman"
  log_info "Using Podman for containerization"
elif command -v docker &> /dev/null; then
  CONTAINER_CMD="docker"
  log_info "Using Docker for containerization"
else
  log_error "Neither Docker nor Podman found"
  log_error "Please install Docker or Podman to run this script"
  exit 1
fi

# ---------- Version Normalization ----------
GIT_TAG="$VERSION"
if [[ ! $GIT_TAG =~ ^v ]]; then
  GIT_TAG="v$VERSION"
fi
VERSION_NO_V="${VERSION#v}"

log_info "Building $APP_NAME version: $VERSION (tag: $GIT_TAG) for architecture: $ARCH, type: $TYPE"

# ---------- Setup Workspace ----------
ORIG_DIR="$(pwd)"
WORKSPACE="$(pwd)/wasabi_build_${VERSION_NO_V}_${ARCH}_${TYPE}"
log_info "Creating workspace: $WORKSPACE"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# ---------- Determine Build Configuration ----------
# BUILD_TARGET is based on ARCH, EXPECTED_FILE is based on TYPE
case "$ARCH" in
  x86_64-linux-gnu)
    BUILD_TARGET="debian"
    case "$TYPE" in
      deb)
        EXPECTED_FILE="Wasabi-${VERSION_NO_V}.deb"
        ;;
      tarball)
        EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-x64.tar.gz"
        ;;
      zip)
        EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-x64.zip"
        ;;
    esac
    ;;
  win64)
    BUILD_TARGET="wininstaller"
    case "$TYPE" in
      msi)
        EXPECTED_FILE="Wasabi-${VERSION_NO_V}.msi"
        ;;
      zip)
        EXPECTED_FILE="Wasabi-${VERSION_NO_V}-win-x64.zip"
        ;;
    esac
    ;;
esac

DOWNLOAD_URL="https://github.com/WalletWasabi/WalletWasabi/releases/download/$GIT_TAG/$EXPECTED_FILE"

# ---------- Download and Clone Inside Container ----------
log_info "Downloading official release and cloning repository inside container..."

# Use container to download and clone (no host dependencies except container runtime)
if ! $CONTAINER_CMD run --rm \
  -v "$WORKSPACE:/workspace:Z" \
  -w /workspace \
  debian:bookworm-slim \
  bash -c "
    apt-get update -qq && apt-get install -y -qq wget git > /dev/null 2>&1 && \
    wget -q --show-progress '$DOWNLOAD_URL' -O 'official-$EXPECTED_FILE' && \
    git clone --depth=1 --branch='$GIT_TAG' --single-branch \
      https://github.com/WalletWasabi/WalletWasabi walletwasabi
  "; then
  log_error "Failed to download release or clone repository"
  exit 1
fi

log_success "Downloaded official release and cloned repository"

# ---------- Verify Git Tag Authenticity (Inside Container) ----------
log_info "Verifying Git tag authenticity..."

# Wasabi Wallet's GPG key fingerprint (zkSNACKs Ltd.)
# Source: https://github.com/WalletWasabi/WalletWasabi/blob/master/WalletWasabi.Documentation/Guides/HowToVerifySignatures.md
WASABI_GPG_FINGERPRINT="6FB3 872B 5D42 292F 5992  0797 8563 4832 8949 861E"

GPG_VERIFICATION=$($CONTAINER_CMD run --rm \
  -v "$WORKSPACE:/workspace:Z" \
  -w /workspace/walletwasabi \
  debian:bookworm-slim \
  bash -c "
    set -e
    apt-get update -qq && apt-get install -y -qq git gnupg dirmngr > /dev/null 2>&1
    
    # Get commit hash
    COMMIT=\$(git rev-parse HEAD)
    echo \"COMMIT:\$COMMIT\"
    
    # Try to fetch Wasabi's GPG key from keyservers
    echo 'Fetching GPG key...'
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys '$WASABI_GPG_FINGERPRINT' 2>&1 || \
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys '$WASABI_GPG_FINGERPRINT' 2>&1 || \
    echo 'KEY_FETCH_FAILED'
    
    # Verify the key fingerprint matches
    ACTUAL_FP=\$(gpg --fingerprint --with-colons 2>/dev/null | grep '^fpr' | head -1 | cut -d: -f10)
    EXPECTED_FP='${WASABI_GPG_FINGERPRINT// /}'
    if [ \"\$ACTUAL_FP\" = \"\$EXPECTED_FP\" ]; then
      echo 'FINGERPRINT_OK'
    else
      echo 'FINGERPRINT_MISMATCH'
    fi
    
    # Try to verify tag signature
    git tag -v $GIT_TAG 2>&1 || echo 'TAG_VERIFICATION_FAILED'
  ")

# Parse verification results
ACTUAL_COMMIT=$(echo "$GPG_VERIFICATION" | grep "^COMMIT:" | cut -d: -f2)
log_info "Cloned commit hash: $ACTUAL_COMMIT"

if echo "$GPG_VERIFICATION" | grep -q "FINGERPRINT_OK"; then
  log_success "GPG key fingerprint verified"
  
  if echo "$GPG_VERIFICATION" | grep -q "Good signature"; then
    log_success "Git tag has valid GPG signature from zkSNACKs Ltd."
  elif echo "$GPG_VERIFICATION" | grep -q "TAG_VERIFICATION_FAILED"; then
    log_warning "Git tag is not signed or signature verification failed"
    log_warning "Proceeding with commit hash verification only"
  fi
elif echo "$GPG_VERIFICATION" | grep -q "KEY_FETCH_FAILED"; then
  log_warning "Could not fetch Wasabi's GPG key from keyservers"
  log_warning "Proceeding without signature verification"
elif echo "$GPG_VERIFICATION" | grep -q "FINGERPRINT_MISMATCH"; then
  log_error "GPG key fingerprint mismatch! Possible key substitution attack"
  log_error "Expected: $WASABI_GPG_FINGERPRINT"
  exit 1
else
  log_warning "GPG verification inconclusive"
  log_warning "Proceeding with commit hash verification only"
fi

# Provide manual verification instructions
echo ""
log_info "Manual verification steps:"
log_info "  1. Visit: https://github.com/WalletWasabi/WalletWasabi/releases/tag/$GIT_TAG"
log_info "  2. Verify commit hash: $ACTUAL_COMMIT"
log_info "  3. Check release notes and community announcements"
echo ""

# ---------- Generate Embedded Dockerfile ----------
log_info "Generating embedded Dockerfile for reproducible build..."
DOCKERFILE_PATH="$WORKSPACE/Dockerfile"

cat > "$DOCKERFILE_PATH" <<'DOCKERFILE_EOF'
# Wasabi Wallet Reproducible Build Container
# Based on Microsoft's official .NET SDK image (pinned)
FROM mcr.microsoft.com/dotnet/sdk:8.0.404-bookworm-slim

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# Install required dependencies
RUN apt-get update && apt-get install -y \
    git \
    wget \
    zip \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Create build user (non-root)
RUN useradd -m -u 1000 builder
USER builder
WORKDIR /home/builder

# Copy source code
COPY --chown=builder:builder walletwasabi /home/builder/walletwasabi

# Set working directory
WORKDIR /home/builder/walletwasabi

# Build script will be passed as argument
CMD ["/bin/bash"]
DOCKERFILE_EOF

log_success "Dockerfile generated"

# ---------- Build Container Image ----------
IMAGE_NAME="wasabi-build:${VERSION_NO_V}-${ARCH}-${TYPE}"
log_info "Building container image (this may take several minutes)..."

if ! $CONTAINER_CMD build -t "$IMAGE_NAME" -f "$DOCKERFILE_PATH" "$WORKSPACE"; then
  log_error "Container build failed"
  exit 1
fi
log_success "Container image built: $IMAGE_NAME"

# ---------- Run Build Inside Container ----------
log_info "Running reproducible build inside container for target: $BUILD_TARGET..."

# Create output directory
mkdir -p "$WORKSPACE/output"

# Run the build in a named container (no bind mount), then copy out the artifact
CONTAINER_NAME="wasabi-build-run-${VERSION_NO_V}-${ARCH}-${TYPE}-$$"
cleanup_container() {
  $CONTAINER_CMD rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

log_info "Executing build script: ./Contrib/release.sh $BUILD_TARGET"
if ! $CONTAINER_CMD run --name "$CONTAINER_NAME" "$IMAGE_NAME" \
  bash -c "set -euo pipefail && cd /home/builder/walletwasabi && ./Contrib/release.sh $BUILD_TARGET"; then
  log_error "Build failed inside container"
  cleanup_container
  exit 1
fi

log_info "Copying build artifact from container: $EXPECTED_FILE"
if ! $CONTAINER_CMD cp "$CONTAINER_NAME:/home/builder/walletwasabi/packages/$EXPECTED_FILE" "$WORKSPACE/output/$EXPECTED_FILE"; then
  log_error "Failed to copy build artifact from container"
  cleanup_container
  exit 1
fi

log_success "Build completed and artifact copied"
cleanup_container
trap - EXIT

# ---------- Verify Build Output ----------
if [ ! -f "$WORKSPACE/output/$EXPECTED_FILE" ]; then
  log_error "Expected build output not found: $EXPECTED_FILE"
  log_info "Files in output directory:"
  ls -la "$WORKSPACE/output/"
  exit 1
fi

# ---------- Compute Hashes (inside container, no host sha256sum dependency) ----------
log_info "Computing SHA256 hashes..."
BUILT_HASH=$($CONTAINER_CMD run --rm \
  -v "$WORKSPACE:/workspace:Z" \
  -w /workspace \
  debian:bookworm-slim \
  bash -c "sha256sum output/$EXPECTED_FILE | awk '{print \$1}'")

OFFICIAL_HASH=$($CONTAINER_CMD run --rm \
  -v "$WORKSPACE:/workspace:Z" \
  -w /workspace \
  debian:bookworm-slim \
  bash -c "sha256sum official-$EXPECTED_FILE | awk '{print \$1}'")

echo ""
log_info "Built file hash:    $BUILT_HASH"
log_info "Official file hash: $OFFICIAL_HASH"
echo ""

# ---------- Determine Reproducibility ----------
if [ "$BUILT_HASH" == "$OFFICIAL_HASH" ]; then
  MATCH=true
  log_success "REPRODUCIBLE: Hashes match!"
  VERDICT="reproducible"
else
  MATCH=false
  log_error "NOT REPRODUCIBLE: Hashes differ"
  VERDICT="differences found"
fi

# ---------- Generate COMPARISON_RESULTS.yaml ----------
log_info "Generating COMPARISON_RESULTS.yaml..."
cat > "$WORKSPACE/COMPARISON_RESULTS.yaml" <<EOF
date: $(date -u +"%Y-%m-%dT%H:%M:%S%:z")
script_version: $SCRIPT_VERSION
results:
  - architecture: $ARCH
    type: $TYPE
    files:
      - filename: $EXPECTED_FILE
        hash: $BUILT_HASH
        match: $MATCH
EOF

# Copy to original execution directory for build server
if [ "$WORKSPACE" != "$ORIG_DIR" ]; then
  cp "$WORKSPACE/COMPARISON_RESULTS.yaml" "$ORIG_DIR/COMPARISON_RESULTS.yaml"
fi

log_success "COMPARISON_RESULTS.yaml generated"
cat "$WORKSPACE/COMPARISON_RESULTS.yaml"

# ---------- Standardized Result Summary ----------
echo "===== Begin Results ====="
echo "appId:          $APP_ID"
echo "signer:         N/A"
echo "apkVersionName: $VERSION"
echo "apkVersionCode: N/A"
echo "verdict:        $VERDICT"
echo "appHash:        $OFFICIAL_HASH"
echo "commit:         $ACTUAL_COMMIT"
echo ""
echo "Diff:"
if [ "$MATCH" == "true" ]; then
  echo "BUILDS MATCH BINARIES"
  echo "$EXPECTED_FILE - $ARCH - $BUILT_HASH - 1 (MATCHES)"
else
  echo "BUILDS DO NOT MATCH BINARIES"
  echo "$EXPECTED_FILE - $ARCH - $BUILT_HASH - 0 (DOESN'T MATCH)"
fi
echo ""
echo "SUMMARY"
echo "total: 1"
echo "matches: $([ "$MATCH" == "true" ] && echo 1 || echo 0)"
echo "mismatches: $([ "$MATCH" == "true" ] && echo 0 || echo 1)"
echo ""
echo "Revision, tag (and its signature):"
echo "$GPG_VERIFICATION"
echo "===== End Results ====="

# ---------- Summary ----------
echo ""
echo "========================================="
echo "Build Verification Complete"
echo "========================================="
echo "Version:      $VERSION"
echo "Architecture: $ARCH"
echo "Result:       $([ "$MATCH" == "true" ] && echo "reproducible" || echo "not reproducible")"
echo "Workspace:    $WORKSPACE"
echo "Exit code:    $([ "$MATCH" == "true" ] && echo 0 || echo 1)"
echo "========================================="
echo ""

# Exit with appropriate code
if [ "$MATCH" == "true" ]; then
  exit 0
else
  exit 1
fi
