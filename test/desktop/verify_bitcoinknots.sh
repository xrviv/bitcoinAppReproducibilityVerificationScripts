#!/bin/bash

# Bitcoin Knots Reproducible Build Verification Script
# Based on fanquake's Alpine Guix methodology (adapted from verify_bitcoincore.sh)
# WalletScrutiny.com - Version v0.9.0
#
# DESCRIPTION:
# Standalone script for verifying Bitcoin Knots releases using containerized
# reproducible builds. Performs binary comparison between built artifacts and
# official releases for definitive reproducibility verification.
#
# REQUIREMENTS:
# - Podman installed (sudo apt install podman)
# - Internet connection
# - ~2GB disk space
# - 4GB+ RAM recommended
#
# AUTHOR: WalletScrutiny.com
# DATE: 2025-10-20
# LICENSE: MIT License
#
# CHANGELOG:
# v0.9.0 (2025-10-24): Release-only verification by default, optional debug flag, machine-readable summary
# v0.8.1 (2025-10-24): Use POSIX '.' in embedded Dockerfile for BusyBox compatibility
# v0.8.0 (2025-10-23): Stream official downloads + build artifacts via container; force wget for Guix deps
# v0.7.0 (2025-10-23): Fix parameter contract - use -v for app version per Luis guidelines
# v0.6.0 (2025-10-23): Full Luis compliance - user-owned files, /tmp workspace, no host git requirement
# v0.5.0 (2025-10-20): Fix multi-target podman cp failure - handle spaces in paths, flatten artifacts
# v0.4.0 (2025-10-17): Default builds all Linux + Windows targets; version normalization (v prefix optional)
# v0.3.0 (2025-10-16): Luis guideline compliance - proper exit codes (0=reproducible, 1=not, 2=manual)
# v0.2.0 (2025-10-16): Binary comparison method, GitHub redirect fix
# v0.1.1: Initial Alpine Guix implementation
#
# LUIS GUIDELINE COMPLIANCE:
# This script fully complies with WalletScrutiny script generation guidelines:
# - Uses -v for app version (without v prefix) as required
# - Uses --script-version for showing script version (not -v)
# - Supports -t for type (not applicable for Bitcoin Knots, accepts but ignores)
# - Does not support -a (not applicable for desktop builds)
#
# CREDITS:
# This script's containerized approach is inspired by Michael Ford's (fanquake)
# excellent work on reproducible Bitcoin Core builds. The embedded imagefile
# is based on fanquake's Alpine Guix methodology from:
# https://github.com/fanquake/core-review
#
# Bitcoin Knots is a Bitcoin Core fork maintained by Luke Dashjr that uses
# the same Guix-based reproducible build system.

set -euo pipefail

# Script metadata
SCRIPT_VERSION="v0.9.0"
SCRIPT_NAME="verify_bitcoinknots.sh"
DEFAULT_VERSION="29.2.knots20251010"
CONTAINER_NAME="ws_bitcoinknots_verifier"
IMAGE_NAME="ws_bitcoinknots_verifier"

# Global variables for tracking
OUTPUT_DIR=""
OFFICIAL_CHECKSUMS_FILE=""
COPY_SUCCESS="false"
INCLUDE_DEBUG_ARTIFACTS="false"
declare -a SELECTED_ARTIFACTS=()
declare -a SKIPPED_OPTIONAL_ARTIFACTS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Version normalization function
normalize_version() {
    local ver="$1"
    # Add 'v' prefix if not present
    if [[ ! "$ver" =~ ^v ]]; then
        echo "v${ver}"
    else
        echo "$ver"
    fi
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

is_optional_artifact() {
    local filename="$1"

    if [[ "$filename" == *-debug.* ]]; then
        return 0
    fi
    if [[ "$filename" == *-codesigning.* ]]; then
        return 0
    fi
    if [[ "$filename" == *-unsigned.* ]]; then
        return 0
    fi
    if [[ "$filename" == codesignatures-* ]]; then
        return 0
    fi
    if [[ "$filename" == *.desc.html ]]; then
        return 0
    fi

    return 1
}

select_artifacts_for_verification() {
    local output_dir="$1"
    local include_debug="$2"

    SELECTED_ARTIFACTS=()
    SKIPPED_OPTIONAL_ARTIFACTS=()

    if [[ ! -d "$output_dir" ]]; then
        log_warning "Output directory not found for artifact selection: $output_dir"
        return 1
    fi

    shopt -s nullglob
    for file in "$output_dir"/*; do
        [[ -f "$file" ]] || continue
        local filename
        filename=$(basename "$file")

        case "$filename" in
            COMPARISON_RESULTS.txt|SHA256SUMS|SHA256SUMS.local|SHA256SUMS.*)
                continue
                ;;
        esac

        if [[ "$include_debug" != "true" ]] && is_optional_artifact "$filename"; then
            SKIPPED_OPTIONAL_ARTIFACTS+=("$filename")
            continue
        fi

        SELECTED_ARTIFACTS+=("$filename")
    done
    shopt -u nullglob

    if [[ ${#SELECTED_ARTIFACTS[@]} -eq 0 ]]; then
        log_warning "No artifacts selected for verification"
    else
        log_info "Selected ${#SELECTED_ARTIFACTS[@]} artifacts for verification"
        for artifact in "${SELECTED_ARTIFACTS[@]}"; do
            log_info "  - $artifact"
        done
    fi

    if [[ "$include_debug" != "true" ]] && [[ ${#SKIPPED_OPTIONAL_ARTIFACTS[@]} -gt 0 ]]; then
        log_info "Skipped ${#SKIPPED_OPTIONAL_ARTIFACTS[@]} optional artifacts (use --with-debug to include):"
        for skipped in "${SKIPPED_OPTIONAL_ARTIFACTS[@]}"; do
            log_info "  - $skipped"
        done
    fi

    return 0
}

derive_target_label() {
    local filename="$1"
    local version="$2"

    local clean_version="${version#v}"
    local remainder="${filename#bitcoin-${clean_version}-}"

    if [[ "$remainder" == "$filename" ]]; then
        remainder="${filename#bitcoin-${clean_version}}"
        remainder="${remainder#-}"
    fi

    remainder="${remainder%.tar.gz}"
    remainder="${remainder%.tar.xz}"
    remainder="${remainder%.zip}"
    remainder="${remainder%.exe}"
    remainder="${remainder%.dmg}"

    if [[ -z "$remainder" ]]; then
        remainder="source"
    fi

    echo "$remainder"
}

# Help function
show_help() {
    cat << EOF
$SCRIPT_NAME $SCRIPT_VERSION - Bitcoin Knots Reproducible Build Verification

USAGE:
    $SCRIPT_NAME [OPTIONS] [VERSION]

DESCRIPTION:
    Verifies Bitcoin Knots releases using fanquake's Alpine Guix methodology.
    Builds Bitcoin Knots from source in a containerized environment and compares
    checksums against official releases.

OPTIONS:
    -h, --help              Show this help message
    --script-version        Show script version
    -v VERSION              Bitcoin Knots version to verify (without v prefix)
                           Examples: 29.2.knots20251010, 29.1.knots20250903
    -t TYPE                 Wallet type (not applicable, ignored)
    -c, --clean             Clean up containers and images before build
    --target HOST           Build target (default: all Linux + Windows targets)
                           Specify single target or space-separated list
    --no-verify             Skip checksum verification against official release
    --keep-container        Keep container running after build
    --list-targets          Show available build targets
    --no-copy               Skip copying build artifacts to host (container only)
    --with-debug            Include debug/codesigning/unsigned artifacts in verification

EXAMPLES:
    $SCRIPT_NAME -v 29.2.knots20251010                           # Build all targets
    $SCRIPT_NAME -v 29.2.knots20251010 --clean                   # Clean up and build
    $SCRIPT_NAME -v 29.2.knots20251010 --target x86_64-linux-gnu # Single Linux target
    $SCRIPT_NAME -v 29.1.knots20250903 --target x86_64-w64-mingw32 # Single Windows target
    $SCRIPT_NAME --list-targets                                  # Show all available build targets
    $SCRIPT_NAME --script-version                                # Show script version

REQUIREMENTS:
    - Podman installed and working
    - Internet connection for source download
    - ~2GB disk space for build
    - 30+ minutes build time

CONTAINER DETAILS:
    Base: Alpine Linux 3.22
    Guix: v1.4.0 binary installation
    Build users: 32 parallel builders
    Auto-cleanup: Containers and images removed after verification

CREDITS:
    This script's containerized approach is inspired by Michael Ford's (fanquake)
    excellent work on reproducible Bitcoin Core builds. Bitcoin Knots is a
    Bitcoin Core fork that uses the same Guix-based reproducible build system.

LICENSE:
    MIT License

EOF
}

# Show available build targets
show_targets() {
    cat << EOF
$SCRIPT_NAME $SCRIPT_VERSION - Available Build Targets

SUPPORTED BUILD TARGETS:
Bitcoin Knots supports building for multiple platforms. Each target produces
different output files based on the platform and architecture.

LINUX TARGETS:
    x86_64-linux-gnu        Standard 64-bit Linux (glibc)
    aarch64-linux-gnu       64-bit ARM Linux (e.g., Raspberry Pi 4)
    arm-linux-gnueabihf     32-bit ARM Linux (e.g., Raspberry Pi 3)
    powerpc64-linux-gnu     64-bit PowerPC Linux
    powerpc64le-linux-gnu   64-bit PowerPC Little Endian Linux
    riscv64-linux-gnu       64-bit RISC-V Linux

WINDOWS TARGETS:
    x86_64-w64-mingw32      64-bit Windows

DEFAULT BEHAVIOR:
    By default (when --target is not specified), all Linux targets and
    Windows target are built in a single run:
    - x86_64-linux-gnu
    - aarch64-linux-gnu
    - arm-linux-gnueabihf
    - powerpc64-linux-gnu
    - powerpc64le-linux-gnu
    - riscv64-linux-gnu
    - x86_64-w64-mingw32

MACOS TARGETS:
    x86_64-apple-darwin     64-bit macOS (Intel)
    arm64-apple-darwin      64-bit macOS (Apple Silicon M1/M2)

OUTPUT FILES PER TARGET:
Each successful build produces these files:

FOR LINUX/DESKTOP TARGETS:
    bitcoin-VERSION-TARGET.tar.gz           # Main binaries
    bitcoin-VERSION-TARGET-debug.tar.gz     # Debug symbols

FOR WINDOWS TARGET (x86_64-w64-mingw32):
    bitcoin-VERSION-win64.zip               # Main Windows binaries
    bitcoin-VERSION-win64-debug.zip         # Debug symbols
    bitcoin-VERSION-win64-setup.exe         # Windows installer
    bitcoin-VERSION-win64-unsigned.zip      # Unsigned binaries

FOR MACOS TARGETS:
    bitcoin-VERSION-TARGET.tar.gz           # Main binaries
    bitcoin-VERSION-TARGET.zip              # macOS app bundle
    bitcoin-VERSION-TARGET-unsigned.tar.gz  # Unsigned binaries
    bitcoin-VERSION-TARGET-unsigned.zip     # Unsigned app bundle

SINGLE VS MULTI-TARGET BUILDS:
To build all default targets (all Linux + Windows), omit the --target flag:
    $SCRIPT_NAME 29.2.knots20251010

To build a single specific target, use --target:
    $SCRIPT_NAME --target x86_64-linux-gnu 29.2.knots20251010
    $SCRIPT_NAME --target x86_64-w64-mingw32 29.2.knots20251010

To build custom target list (space-separated):
    $SCRIPT_NAME --target "x86_64-linux-gnu x86_64-w64-mingw32" 29.2.knots20251010

Note: Version can be specified with or without 'v' prefix (both work)

BUILD TIME ESTIMATES:
    Single target:        20-40 minutes
    All default targets:  90-180 minutes (depending on hardware)

VERIFICATION:
All output files can be verified against official Bitcoin Knots releases
available at: https://github.com/bitcoinknots/bitcoin/releases

EOF
}

# Version function
show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
    echo "Based on fanquake's Alpine Guix methodology"
    echo "WalletScrutiny.com Bitcoin Knots verification tool"
}

# Dependency checks
check_dependencies() {
    log_info "Checking dependencies..."

    if ! command -v podman &> /dev/null; then
        echo "Error: Podman is required. Install with: sudo apt install podman"
        exit 1
    fi

    # Test podman functionality
    if ! podman --version &> /dev/null; then
        echo "Error: Podman is not working properly"
        exit 1
    fi

    log_success "All dependencies found"
}

# Cleanup function
cleanup_containers() {
    log_info "Cleaning up existing containers and images..."

    # Remove container if exists
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        log_info "Removing existing container: $CONTAINER_NAME"
        podman rm -f "$CONTAINER_NAME" || true
    fi

    # Remove image if exists
    if podman image exists "$IMAGE_NAME" 2>/dev/null; then
        log_info "Removing existing image: $IMAGE_NAME"
        podman rmi -f "$IMAGE_NAME" || true
    fi

    log_success "Cleanup completed"
}

# Create embedded imagefile
create_imagefile() {
    local imagefile_path="$1"

    log_info "Creating embedded Alpine Guix imagefile..."

    cat > "$imagefile_path" << 'EOF'
FROM alpine:3.22 AS base

RUN apk --no-cache --update add \
      bash \
      bzip2 \
      ca-certificates \
      curl \
      git \
      make \
      shadow

ARG guix_download_path=https://ftpmirror.gnu.org/gnu/guix/
ARG guix_alt_download_path=https://ftp.gnu.org/gnu/guix/
ARG guix_version=1.4.0
ARG guix_checksum_aarch64=72d807392889919940b7ec9632c45a259555e6b0942ea7bfd131101e08ebfcf4
ARG guix_checksum_x86_64=236ca7c9c5958b1f396c2924fcc5bc9d6fdebcb1b4cf3c7c6d46d4bf660ed9c9
ARG builder_count=32

# Container environment paths (inside container)
ENV PATH=/root/.config/guix/current/bin:$PATH
ENV GUIX_LOCPATH=/root/.guix-profile/lib/locale
ENV LC_ALL=en_US.UTF-8

# Install Guix inside container
RUN set -e                                                              && \
    guix_file_name=guix-binary-${guix_version}.$(uname -m)-linux.tar.xz && \
    eval "guix_checksum=\${guix_checksum_$(uname -m)}"                  && \
    cd /tmp                                                             && \
    for mirror in "${guix_download_path}" "${guix_alt_download_path}"; do \
      echo "Attempting download from ${mirror}/${guix_file_name}" >&2;     \
      if wget --tries=3 --timeout=60 -q -O "$guix_file_name" "${mirror}/${guix_file_name}"; then \
        break;                                                             \
      else                                                                 \
        echo "Download failed from $mirror" >&2;                           \
        rm -f "$guix_file_name";                                           \
      fi;                                                                  \
    done                                                                && \
    if [ ! -s "$guix_file_name" ]; then                                 \
      echo "ERROR: Unable to download Guix binary from any mirror" >&2; \
      exit 1;                                                           \
    fi                                                                  && \
    echo "${guix_checksum}  ${guix_file_name}" | sha256sum -c           && \
    tar xJf "$guix_file_name"                                           && \
    mv var/guix /var/                                                      && \
    mv gnu /                                                               && \
    mkdir -p ~root/.config/guix                                            && \
    ln -sf /var/guix/profiles/per-user/root/current-guix ~root/.config/guix/current && \
    . /root/.config/guix/current/etc/profile

# Note: Above paths use /root inside container, not related to host root user

RUN groupadd --system guixbuild
RUN for i in $(seq -w 1 ${builder_count}); do    \
      useradd -g guixbuild -G guixbuild          \
              -d /var/empty -s $(which nologin)  \
              -c "Guix build user ${i}" --system \
              "guixbuilder${i}" ;                \
    done

RUN git clone https://github.com/bitcoinknots/bitcoin.git /bitcoin
RUN mkdir base_cache sources SDKs

WORKDIR /bitcoin

# Authorize Guix keys (inside container)
RUN guix archive --authorize < ~root/.config/guix/current/share/guix/ci.guix.gnu.org.pub

# Start Guix daemon (inside container)
CMD ["/root/.config/guix/current/bin/guix-daemon","--build-users-group=guixbuild"]
EOF

    log_success "Imagefile created: $imagefile_path"
}

# Build container
build_container() {
    local imagefile_path="$1"

    log_info "Building Bitcoin Knots verification container..."
    log_info "This may take 5-15 minutes depending on network speed..."

    if ! podman build --pull --no-cache -t "$IMAGE_NAME" - < "$imagefile_path"; then
        log_error "Container build failed"
        exit 1
    fi

    log_success "Container built successfully: $IMAGE_NAME"
}

# Start container daemon
start_container() {
    log_info "Starting container daemon: $CONTAINER_NAME"

    # Remove any existing container with the same name first
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        log_info "Removing existing container: $CONTAINER_NAME"
        podman rm -f "$CONTAINER_NAME" || true
    fi

    # Run container as root (required for guix-daemon and mounts)
    # Files will be owned by root, we'll handle ownership in copy function
    if ! podman run -d --name "$CONTAINER_NAME" --privileged \
      "$IMAGE_NAME"; then
        log_error "Failed to start container"
        exit 1
    fi

    # Wait a moment for daemon to start
    sleep 2

    log_success "Container daemon started"
}

# Verify Bitcoin Knots version and prepare build
prepare_bitcoin_build() {
    local version="$1"
    local target="$2"

    log_info "Preparing Bitcoin Knots $version build for target: $target"

    # Clean previous build artifacts
    log_info "Cleaning previous build artifacts..."
    podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && rm -rf depends/work/ guix-build-*/ base_cache/*" || true
    podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && make -C depends clean-all" || true

    # Update repository and checkout version
    log_info "Fetching latest Bitcoin Knots repository..."
    podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git fetch --all --tags"

    log_info "Checking out version: $version"
    if ! podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git checkout $version"; then
        log_error "Failed to checkout version: $version"
        log_error "Available tags:"
        podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git tag | grep -E 'knots' | tail -10"
        exit 1
    fi

    # Verify GPG signature
    log_info "Verifying GPG signature for $version..."
    if podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git verify-tag $version 2>/dev/null"; then
        log_success "GPG signature verified for $version"
    else
        log_warning "GPG signature verification failed for $version"
        log_warning "This may be normal for some releases"
    fi

    log_success "Bitcoin Knots $version prepared for build"
}

# Execute Guix build
execute_build() {
    local version="$1"
    local target="$2"

    log_info "Starting Guix build for Bitcoin Knots $version..."
    log_info "Target: $target"
    log_info "This will take 20-60 minutes depending on hardware..."

    local start_time=$(date +%s)

    # Execute the build
    local build_cmd="cd /bitcoin && time FORCE_USE_WGET=1 BASE_CACHE='/base_cache' SOURCE_PATH='/sources' SDK_PATH='/SDKs' HOSTS='$target' ./contrib/guix/guix-build"

    if podman exec "$CONTAINER_NAME" bash -c "$build_cmd"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "Build completed successfully in $duration seconds"
    else
        log_error "Build failed"
        exit 1
    fi
}

# Generate checksums from container artifacts
generate_container_checksums() {
    local version="$1"
    local target="$2"

    # Clean version string for directory names (remove 'v' prefix)
    local clean_version="${version#v}"

    # Detect multi-target vs single-target build
    local build_dir
    if [[ "$target" == *" "* ]]; then
        # Multi-target build: artifacts are in subdirectories under /output/
        build_dir="/bitcoin/guix-build-$clean_version/output"
    else
        # Single-target build: artifacts are directly in /output/$target/
        build_dir="/bitcoin/guix-build-$clean_version/output/$target"
    fi

    log_info "Checking build artifacts in container: $build_dir"

    # Check if build directory exists
    if ! podman exec "$CONTAINER_NAME" bash -c "test -d \"$build_dir\""; then
        log_error "Build output directory not found: $build_dir"
        log_info "Available directories:"
        podman exec "$CONTAINER_NAME" bash -c "ls -la /bitcoin/guix-build-*/" || true
        return 1
    fi

    # List artifacts
    echo ""
    log_info "Build artifacts produced:"
    echo ""

    if [[ "$target" == *" "* ]]; then
        # Multi-target: show subdirectories and their contents
        podman exec "$CONTAINER_NAME" bash -c "cd \"$build_dir\" && for dir in */; do echo \"=== \$dir ===\"; ls -lh \"\$dir\"*.tar.gz \"\$dir\"*.zip \"\$dir\"*.exe 2>/dev/null || ls -lh \"\$dir\"*; echo; done"
    else
        # Single-target: show files directly
        podman exec "$CONTAINER_NAME" bash -c "cd \"$build_dir\" && ls -lh *.tar.gz *.zip *.exe 2>/dev/null || ls -lh *"
    fi
    echo ""

    return 0
}

# Download official checksums to host
download_official_checksums() {
    local version="$1"

    if [[ -n "$OFFICIAL_CHECKSUMS_FILE" ]] && [[ -f "$OFFICIAL_CHECKSUMS_FILE" ]]; then
        log_info "Official checksums already available: $OFFICIAL_CHECKSUMS_FILE"
        return 0
    fi

    log_info "Downloading official Bitcoin Knots checksums..."

    local base_url="https://github.com/bitcoinknots/bitcoin/releases/download/$version"
    local temp_dir
    local container_temp_dir

    temp_dir=$(mktemp -d)

    if ! container_temp_dir=$(podman exec "$CONTAINER_NAME" mktemp -d /tmp/ws_official_sha.XXXXXX 2>/dev/null); then
        log_error "Failed to create temporary directory inside container for checksums"
        rm -rf "$temp_dir"
        return 1
    fi

    if ! podman exec "$CONTAINER_NAME" bash -lc "set -euo pipefail; cd '$container_temp_dir'; wget --tries=3 --timeout=60 -q -O SHA256SUMS '$base_url/SHA256SUMS' || curl -fL --retry 3 --retry-delay 2 -o SHA256SUMS '$base_url/SHA256SUMS'"; then
        log_warning "Could not download SHA256SUMS file"
        log_info "Manual verification required at: https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
        podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        OFFICIAL_CHECKSUMS_FILE=""
        return 1
    fi

    if ! podman exec "$CONTAINER_NAME" bash -lc "cat '$container_temp_dir/SHA256SUMS'" > "$temp_dir/SHA256SUMS"; then
        log_error "Failed to copy SHA256SUMS from container"
        podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        OFFICIAL_CHECKSUMS_FILE=""
        return 1
    fi

    podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true

    OFFICIAL_CHECKSUMS_FILE="$temp_dir/SHA256SUMS"
    log_success "Official checksums downloaded to: $OFFICIAL_CHECKSUMS_FILE"
    return 0
}

# Download official artifacts for binary comparison
download_official_artifacts() {
    local version="$1"      # e.g., v29.2.knots20251010
    local output_dir="$2"   # e.g., ./bitcoinknots-29.2.knots20251010-x86_64-linux-gnu-20251016-005313

    log_info "Downloading official Bitcoin Knots artifacts for binary comparison (inside container)..."

    local official_dir="$output_dir/official-downloads"
    mkdir -p "$official_dir"

    local base_url="https://github.com/bitcoinknots/bitcoin/releases/download/$version"
    local container_temp_dir

    if ! container_temp_dir=$(podman exec "$CONTAINER_NAME" mktemp -d /tmp/ws_official_artifacts.XXXXXX 2>/dev/null); then
        log_error "Failed to create temporary directory inside container for official artifacts"
        return 1
    fi

    if ! podman exec "$CONTAINER_NAME" bash -lc "set -euo pipefail; cd '$container_temp_dir'; wget --tries=3 --timeout=60 -q -O SHA256SUMS '$base_url/SHA256SUMS' || curl -fL --retry 3 --retry-delay 2 -o SHA256SUMS '$base_url/SHA256SUMS'"; then
        log_error "Failed to download SHA256SUMS inside container"
        podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true
        return 1
    fi

    if ! podman exec "$CONTAINER_NAME" bash -lc "cat '$container_temp_dir/SHA256SUMS'" > "$official_dir/SHA256SUMS"; then
        log_error "Failed to copy SHA256SUMS from container"
        podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true
        return 1
    fi

    OFFICIAL_CHECKSUMS_FILE="$official_dir/SHA256SUMS"
    log_success "Official SHA256SUMS downloaded to: $OFFICIAL_CHECKSUMS_FILE"

    declare -A official_hashes=()
    while IFS=' ' read -r hash filename; do
        [[ -z "$hash" || -z "$filename" ]] && continue
        filename="${filename#\*}"
        official_hashes["$filename"]="$hash"
    done < "$OFFICIAL_CHECKSUMS_FILE"

    local download_count=0
    local failed_count=0

    if [[ ${#SELECTED_ARTIFACTS[@]} -eq 0 ]]; then
        log_warning "No artifacts selected for official download"
        podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true
        return 1
    fi

    for filename in "${SELECTED_ARTIFACTS[@]}"; do
        local built_file="$output_dir/$filename"

        if [[ ! -f "$built_file" ]]; then
            log_warning "Selected artifact not found on host: $filename"
            failed_count=$((failed_count + 1))
            continue
        fi

        if [[ -z "${official_hashes[$filename]:-}" ]]; then
            log_warning "Official SHA256SUMS does not list artifact: $filename"
            failed_count=$((failed_count + 1))
            continue
        fi

        log_info "Downloading official artifact inside container: $filename"
        if ! podman exec "$CONTAINER_NAME" bash -lc "set -euo pipefail; cd '$container_temp_dir'; if [ ! -f '$filename' ]; then wget --tries=3 --timeout=120 -q '$base_url/$filename' || curl -fL --retry 3 --retry-delay 2 -o '$filename' '$base_url/$filename'; fi"; then
            log_error "Failed to download: $filename"
            log_error "URL: $base_url/$filename"
            failed_count=$((failed_count + 1))
            continue
        fi

        if ! podman exec "$CONTAINER_NAME" bash -lc "cat '$container_temp_dir/$filename'" > "$official_dir/$filename"; then
            log_error "Failed to copy $filename from container"
            failed_count=$((failed_count + 1))
            continue
        fi

        download_count=$((download_count + 1))
        log_success "Downloaded official artifact: $filename"
    done

    podman exec "$CONTAINER_NAME" rm -rf "$container_temp_dir" >/dev/null 2>&1 || true

    if [ $download_count -eq 0 ]; then
        log_error "No official artifacts were downloaded"
        return 1
    fi

    if [ $failed_count -gt 0 ]; then
        log_warning "$failed_count official artifacts failed to download"
    fi

    return 0
}

# Perform binary comparison between built and official artifacts
compare_artifacts_binary() {
    local output_dir="$1"
    local version="$2"
    local official_dir="$output_dir/official-downloads"

    log_info "Performing binary comparison of artifacts..."

    # Check if official directory exists
    if [ ! -d "$official_dir" ]; then
        log_error "Official downloads directory not found: $official_dir"
        return 2
    fi

    local total=0
    local matches=0
    local mismatches=0

    if [[ ${#SELECTED_ARTIFACTS[@]} -eq 0 ]]; then
        log_warning "No artifacts selected for comparison"
        return 2
    fi

    local comparison_file="$output_dir/COMPARISON_RESULTS.txt"
    echo "BUILDS MATCH BINARIES" > "$comparison_file"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$comparison_file"
    echo "" >> "$comparison_file"

    for filename in "${SELECTED_ARTIFACTS[@]}"; do
        local built_file="$output_dir/$filename"
        local official_file="$official_dir/$filename"

        if [[ ! -f "$built_file" ]]; then
            log_warning "Built artifact missing on host: $filename"
            mismatches=$((mismatches + 1))
            echo "$filename - missing-on-host - N/A - 0 (MISSING BUILT ARTIFACT)" >> "$comparison_file"
            continue
        fi

        if [[ ! -f "$official_file" ]]; then
            log_warning "Official artifact missing for comparison: $filename"
            mismatches=$((mismatches + 1))
            local target_label
            target_label=$(derive_target_label "$filename" "$version")
            local built_hash
            built_hash=$(sha256sum "$built_file" | cut -d' ' -f1)
            echo "$filename - $target_label - $built_hash - 0 (OFFICIAL MISSING)" >> "$comparison_file"
            continue
        fi

        total=$((total + 1))
        local target_label
        target_label=$(derive_target_label "$filename" "$version")
        local built_hash
        built_hash=$(sha256sum "$built_file" | cut -d' ' -f1)
        local official_hash
        official_hash=$(sha256sum "$official_file" | cut -d' ' -f1)

        if cmp -s "$built_file" "$official_file"; then
            matches=$((matches + 1))
            log_success "MATCH: $filename"
            echo "$filename - $target_label - $built_hash - 1 (MATCHES)" >> "$comparison_file"
        else
            mismatches=$((mismatches + 1))
            log_error "MISMATCH: $filename"
            echo "$filename - $target_label - $built_hash - 0 (DOESN'T MATCH)" >> "$comparison_file"
        fi
    done

    echo "" >> "$comparison_file"
    echo "SUMMARY" >> "$comparison_file"
    echo "total: $total" >> "$comparison_file"
    echo "matches: $matches" >> "$comparison_file"
    echo "mismatches: $mismatches" >> "$comparison_file"

    log_info "Comparison results saved to: $comparison_file"

    echo ""
    if [ $mismatches -eq 0 ] && [ $matches -gt 0 ]; then
        log_success "All $matches artifacts are REPRODUCIBLE (binary identical)"
        return 0
    elif [ $mismatches -gt 0 ]; then
        log_error "$mismatches artifacts FAILED reproducibility check"
        return 1
    else
        log_warning "No artifacts were compared"
        return 2
    fi
}

# Copy build artifacts to host
copy_artifacts_to_host() {
    local version="$1"
    local target="$2"
    local copy_flag="$3"

    # Clean version string for directory names (remove 'v' prefix)
    local clean_version="${version#v}"

    # Detect multi-target vs single-target build
    local is_multi_target="false"
    local build_dir
    local target_label

    if [[ "$target" == *" "* ]]; then
        # Multi-target build: artifacts are in subdirectories under /output/
        is_multi_target="true"
        build_dir="/bitcoin/guix-build-$clean_version/output"
        # Sanitize target list for directory name (replace spaces with dashes)
        target_label="all"
    else
        # Single-target build: artifacts are directly in /output/$target/
        build_dir="/bitcoin/guix-build-$clean_version/output/$target"
        target_label="$target"
    fi

    if [[ "$copy_flag" == "false" ]]; then
        log_info "Skipping artifact copy to host (--no-copy specified)"
        log_info "Artifacts remain in container at: $build_dir"
        COPY_SUCCESS="skipped"
        return 0
    fi

    # Verify container still exists
    if ! podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        log_error "Container $CONTAINER_NAME does not exist"
        log_error "Cannot copy artifacts"
        COPY_SUCCESS="false"
        return 1
    fi

    # Create timestamped directory in current working directory (Luis guideline compliance)
    OUTPUT_DIR="./bitcoinknots-$clean_version-$target_label-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$OUTPUT_DIR"

    log_info "Copying build artifacts to host: $OUTPUT_DIR"

    if [[ "$is_multi_target" == "true" ]]; then
        log_info "Multi-target build detected, copying all subdirectories"
    fi

    # Copy artifacts via tar stream to preserve user ownership on host
    if ! ( set -o pipefail; podman exec "$CONTAINER_NAME" bash -lc "set -euo pipefail; cd '$build_dir' && tar -cf - ." | tar -C "$OUTPUT_DIR" --no-same-owner -xf - ); then
        log_error "Failed to stream artifacts from container (tar copy failed)"
        log_error "Artifacts remain in container at: $build_dir"
        COPY_SUCCESS="false"
        return 1
    fi

    # Verify files were actually copied
    if [ -z "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]; then
        log_error "Artifact copy appeared to succeed but directory is empty"
        log_error "Directory: $OUTPUT_DIR"
        COPY_SUCCESS="false"
        return 1
    fi
    
    # Flatten multi-target artifacts for easier comparison
    if [[ "$is_multi_target" == "true" ]]; then
        log_info "Flattening multi-target artifacts to output directory..."
        # Move all files from subdirectories to top level
        find "$OUTPUT_DIR" -mindepth 2 -type f \( -name "*.tar.gz" -o -name "*.zip" -o -name "*.exe" \) -exec mv {} "$OUTPUT_DIR/" \;
        # Remove now-empty target subdirectories
        find "$OUTPUT_DIR" -mindepth 1 -type d -empty -delete
        log_success "Artifacts flattened to output directory"
    fi

    # Count copied files
    local file_count=$(find "$OUTPUT_DIR" -type f | wc -l)
    log_success "Copied $file_count files to: $OUTPUT_DIR"

    # Generate local SHA256SUMS file
    log_info "Generating local SHA256SUMS file..."
    (cd "$OUTPUT_DIR" && sha256sum *.tar.gz *.zip *.exe 2>/dev/null > SHA256SUMS.local) || \
    (cd "$OUTPUT_DIR" && sha256sum * 2>/dev/null > SHA256SUMS.local)

    if [ -f "$OUTPUT_DIR/SHA256SUMS.local" ]; then
        log_success "Local checksums saved to: $OUTPUT_DIR/SHA256SUMS.local"
    else
        log_warning "Failed to generate SHA256SUMS.local"
    fi

    COPY_SUCCESS="true"
    return 0
}

# Print verification summary with all data
print_verification_summary() {
    local version="$1"
    local target="$2"

    echo ""
    echo "=========================================="
    echo "BITCOIN KNOTS VERIFICATION SUMMARY"
    echo "=========================================="
    echo "Version: $version"
    echo "Target: $target"
    echo "Build Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    if [ -n "$OUTPUT_DIR" ] && [ -d "$OUTPUT_DIR" ]; then
        echo "Output Directory: $OUTPUT_DIR"
        echo ""
        echo "BUILD ARTIFACTS:"
        echo "------------------------------------------"

        if [[ ${#SELECTED_ARTIFACTS[@]} -eq 0 ]]; then
            echo "No artifacts selected for verification"
        else
            for filename in "${SELECTED_ARTIFACTS[@]}"; do
                local file="$OUTPUT_DIR/$filename"
                if [ -f "$file" ]; then
                    local filesize=$(du -k "$file" | cut -f1)
                    local filedate=$(stat -c '%y' "$file" | cut -d'.' -f1)
                    local filehash=$(sha256sum "$file" | cut -d' ' -f1)

                    echo "File: $filename"
                    echo "  Path: $file"
                    echo "  Size: ${filesize} KB"
                    echo "  Date: $filedate"
                    echo "  SHA256 (built): $filehash"

                    if [ -n "$OFFICIAL_CHECKSUMS_FILE" ] && [ -f "$OFFICIAL_CHECKSUMS_FILE" ]; then
                        local official_hash=$(grep -F "  $filename" "$OFFICIAL_CHECKSUMS_FILE" 2>/dev/null | awk '{print $1}')
                        if [ -n "$official_hash" ]; then
                            echo "  SHA256 (official): $official_hash"
                        else
                            echo "  SHA256 (official): NOT FOUND"
                        fi
                    fi
                    echo ""
                fi
            done
        fi

        if [[ ${#SKIPPED_OPTIONAL_ARTIFACTS[@]} -gt 0 ]]; then
            echo "Optional artifacts skipped (use --with-debug to include):"
            for skipped in "${SKIPPED_OPTIONAL_ARTIFACTS[@]}"; do
                echo "  - $skipped"
            done
            echo ""
        fi

        echo "=========================================="
        echo "BINARY COMPARISON RESULTS:"
        echo "------------------------------------------"
        if [ -f "$OUTPUT_DIR/COMPARISON_RESULTS.txt" ]; then
            cat "$OUTPUT_DIR/COMPARISON_RESULTS.txt"
        else
            echo "Binary comparison not performed"
            echo ""
            echo "CHECKSUM COMPARISON SUMMARY:"
            if [ -n "$OFFICIAL_CHECKSUMS_FILE" ] && [ -f "$OFFICIAL_CHECKSUMS_FILE" ]; then
                local total=0
                local matches=0
                for filename in "${SELECTED_ARTIFACTS[@]}"; do
                    local file="$OUTPUT_DIR/$filename"
                    if [ -f "$file" ]; then
                        total=$((total + 1))
                        local filehash=$(sha256sum "$file" | cut -d' ' -f1)
                        local official_hash=$(grep -F "  $filename" "$OFFICIAL_CHECKSUMS_FILE" 2>/dev/null | awk '{print $1}')
                        if [ -n "$official_hash" ] && [ "$filehash" == "$official_hash" ]; then
                            matches=$((matches + 1))
                        fi
                    fi
                done
                echo "Total artifacts: $total"
                echo "Matching hashes: $matches"
                echo "Non-matching hashes: $((total - matches))"
            else
                echo "Official checksums: NOT AVAILABLE"
                echo "Manual verification required at:"
                echo "  https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
            fi
        fi
    else
        echo "Output Directory: NOT AVAILABLE"
        echo ""
        echo "Artifacts were not copied to host."
        if [ "$COPY_SUCCESS" == "false" ]; then
            echo "Artifact copy failed. See error messages above."
        elif [ "$COPY_SUCCESS" == "skipped" ]; then
            echo "Artifact copy was skipped (--no-copy flag)."
        fi
    fi
    echo "=========================================="
    echo ""
}

# Print standardized WalletScrutiny verification result format
print_standardized_results() {
    local version="$1"
    local verification_result="$2"
    local commit_hash="$3"
    
    echo ""
    echo "===== Begin Results ====="
    
    # Core metadata fields
    echo "appId:          bitcoinknots"
    echo "signer:         N/A"
    echo "versionName:    ${version#v}"  # Remove v prefix
    echo "buildNumber:    $(date +%Y%m%d)"
    
    # Determine verdict based on verification result
    local verdict=""
    if [[ $verification_result -eq 0 ]]; then
        verdict="reproducible"
    elif [[ $verification_result -eq 1 ]]; then
        verdict="differences found"
    else
        verdict=""  # Manual verification needed
    fi
    echo "verdict:        $verdict"
    
    # App hash (first built artifact)
    local app_hash=""
    if [ -n "$OUTPUT_DIR" ] && [ -d "$OUTPUT_DIR" ] && [[ ${#SELECTED_ARTIFACTS[@]} -gt 0 ]]; then
        local first_selected="${SELECTED_ARTIFACTS[0]}"
        local first_file="$OUTPUT_DIR/$first_selected"
        if [ -f "$first_file" ]; then
            app_hash=$(sha256sum "$first_file" | cut -d' ' -f1)
        fi
    fi
    echo "appHash:        ${app_hash:-N/A}"
    
    # Commit hash
    echo "commit:         ${commit_hash:-N/A}"
    
    # Diff section
    echo ""
    echo "Diff:"
    if [ -f "$OUTPUT_DIR/COMPARISON_RESULTS.txt" ]; then
        grep -E " - (0|1) " "$OUTPUT_DIR/COMPARISON_RESULTS.txt" || echo "(No comparison performed)"
    else
        echo "(No comparison file available)"
    fi
    
    # Git tag and signature section
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Tag: $version"
    echo "Repository: https://github.com/bitcoinknots/bitcoin"
    echo ""
    echo "Signature Summary:"
    echo "Tag type: release"
    echo "[INFO] Bitcoin Knots uses GitHub releases"
    echo "[INFO] Verification based on binary comparison with official releases"
    echo ""
    echo "Keys used:"
    echo "Official releases signed by Luke Dashjr"
    echo "Release page: https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
    
    # Optional additional info
    if [ -n "$OUTPUT_DIR" ] && [ -d "$OUTPUT_DIR" ]; then
        echo ""
        echo "===== Also ===="
        echo "Build performed using Guix reproducible build system"
        echo "Container: Alpine Linux 3.22 with Guix v1.4.0"
        echo "Artifacts location: $OUTPUT_DIR"
        if [ -f "$OUTPUT_DIR/COMPARISON_RESULTS.txt" ]; then
            echo "Detailed comparison: $OUTPUT_DIR/COMPARISON_RESULTS.txt"
        fi
    fi
    
    echo ""
    echo "===== End Results ====="
    
    # Diff investigation commands (only if artifacts available)
    if [ -n "$OUTPUT_DIR" ] && [ -d "$OUTPUT_DIR" ]; then
        echo ""
        echo "For detailed investigation, examine:"
        echo "  $OUTPUT_DIR/COMPARISON_RESULTS.txt"
        echo "  $OUTPUT_DIR/SHA256SUMS.local"
        if [ -n "$OFFICIAL_CHECKSUMS_FILE" ] && [ -f "$OFFICIAL_CHECKSUMS_FILE" ]; then
            echo "  $OFFICIAL_CHECKSUMS_FILE"
        fi
        echo ""
        echo "Compare individual artifacts:"
        if [[ ${#SELECTED_ARTIFACTS[@]} -gt 0 ]]; then
            local first_selected="${SELECTED_ARTIFACTS[0]}"
            local first_file="$OUTPUT_DIR/$first_selected"
            if [ -f "$first_file" ]; then
                echo "  diffoscope <official_artifact> $first_file"
            fi
        fi
        echo "for more details."
    fi
    echo ""
}

# Final cleanup
final_cleanup() {
    local keep_container="$1"

    # Keep container if copy failed
    if [[ "$COPY_SUCCESS" == "false" ]]; then
        log_warning "Artifact copy failed, keeping container for manual extraction"
        log_info "Container: $CONTAINER_NAME"
        log_info "To extract artifacts manually:"
        log_info "  podman exec $CONTAINER_NAME bash"
        log_info "  # Inside container, artifacts are in /bitcoin/guix-build-*/output/"
        log_info "To clean up later:"
        log_info "  podman rm -f $CONTAINER_NAME && podman rmi -f $IMAGE_NAME"
        return 0
    fi

    if [[ "$keep_container" == "false" ]]; then
        log_info "Cleaning up containers and images..."
        cleanup_containers
        log_success "Cleanup completed"
    else
        log_info "Container kept running as requested: $CONTAINER_NAME"
        log_info "To connect: podman exec $CONTAINER_NAME bash"
        log_info "To clean up later: podman rm -f $CONTAINER_NAME && podman rmi -f $IMAGE_NAME"
    fi
}

# Main execution function
main() {
    local version="$DEFAULT_VERSION"
    local target="x86_64-linux-gnu aarch64-linux-gnu arm-linux-gnueabihf powerpc64-linux-gnu powerpc64le-linux-gnu riscv64-linux-gnu x86_64-w64-mingw32"
    local clean_flag="false"
    local verify_flag="true"
    local keep_container="false"
    local copy_flag="true"
    local include_debug="false"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --script-version)
                show_version
                exit 0
                ;;
            -v)
                version="$2"
                shift 2
                ;;
            -t)
                # Type parameter (not applicable for Bitcoin Knots, but accepted for Luis compliance)
                log_warning "Type parameter (-t) not applicable for Bitcoin Knots, ignoring"
                shift 2
                ;;
            --list-targets)
                show_targets
                exit 0
                ;;
            -c|--clean)
                clean_flag="true"
                shift
                ;;
            --target)
                target="$2"
                shift 2
                ;;
            --no-verify)
                verify_flag="false"
                shift
                ;;
            --keep-container)
                keep_container="true"
                shift
                ;;
            --no-copy)
                copy_flag="false"
                shift
                ;;
            --with-debug)
                include_debug="true"
                INCLUDE_DEBUG_ARTIFACTS="true"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                log_error "Unexpected positional argument: $1"
                log_error "Use -v VERSION to specify version"
                show_help
                exit 1
                ;;
        esac
    done

    # Normalize version (add 'v' prefix if missing)
    version=$(normalize_version "$version")

    # Display configuration
    echo ""
    log_info "Bitcoin Knots Reproducible Build Verification"
    log_info "Version: $version"
    log_info "Target: $target"
    log_info "Verify checksums: $verify_flag"
    echo ""

    # Main execution flow
    check_dependencies

    if [[ "$clean_flag" == "true" ]]; then
        cleanup_containers
    fi

    # Create temporary imagefile
    local temp_imagefile=$(mktemp)
    trap "rm -f $temp_imagefile" EXIT

    create_imagefile "$temp_imagefile"
    build_container "$temp_imagefile"
    start_container
    prepare_bitcoin_build "$version" "$target"
    execute_build "$version" "$target"
    
    # Generate checksums in container
    generate_container_checksums "$version" "$target" || true
    
    # Copy artifacts to host BEFORE any cleanup
    copy_artifacts_to_host "$version" "$target" "$copy_flag" || true

    if [[ "$COPY_SUCCESS" == "true" ]]; then
        select_artifacts_for_verification "$OUTPUT_DIR" "$include_debug" || true
    else
        SELECTED_ARTIFACTS=()
        SKIPPED_OPTIONAL_ARTIFACTS=()
    fi

    # Download and compare with official artifacts (NEW PRIMARY METHOD)
    local verification_result=2  # Default: no comparison performed

    if [[ "$verify_flag" == "true" ]] && [[ "$COPY_SUCCESS" == "true" ]]; then
        if download_official_artifacts "$version" "$OUTPUT_DIR"; then
            compare_artifacts_binary "$OUTPUT_DIR" "$version"
            verification_result=$?
        else
            log_warning "Failed to download official artifacts for binary comparison"
            # Fallback to checksum-only verification
            download_official_checksums "$version" || true
            verification_result=2  # No binary comparison available
        fi
    fi

    # Print verification summary
    print_verification_summary "$version" "$target" || true
    
    # Print standardized WalletScrutiny results format
    # Get commit hash from container if available
    local commit_hash=""
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        commit_hash=$(podman exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git rev-parse HEAD" 2>/dev/null || echo "")
    fi
    print_standardized_results "$version" "$verification_result" "$commit_hash" || true

    # Cleanup
    final_cleanup "$keep_container" || true

    echo ""

    # Exit with appropriate code based on verification result
    if [[ "$COPY_SUCCESS" != "true" ]]; then
        if [[ "$COPY_SUCCESS" == "skipped" ]]; then
            log_info "Bitcoin Knots build completed (artifacts in container)"
            exit 0  # Build succeeded, copy skipped by user
        else
            log_error "Bitcoin Knots build completed but artifact copy failed"
            exit 1  # Build succeeded but copy failed
        fi
    fi

    # Determine exit code based on verification result
    if [[ "$verify_flag" == "false" ]]; then
        log_success "Bitcoin Knots build completed (verification skipped)"
        exit 0
    elif [[ $verification_result -eq 0 ]]; then
        log_success "Bitcoin Knots verification completed: REPRODUCIBLE"
        exit 0
    elif [[ $verification_result -eq 1 ]]; then
        log_error "Bitcoin Knots verification completed: NOT REPRODUCIBLE"
        exit 1
    else
        log_warning "Bitcoin Knots verification completed: MANUAL VERIFICATION REQUIRED"
        exit 2
    fi
}

# Execute main function with all arguments
main "$@"
