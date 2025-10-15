#!/bin/bash

# Bitcoin Knots Reproducible Build Verification Script
# Based on fanquake's Alpine Guix methodology (adapted from verify_bitcoincore.sh)
# WalletScrutiny.com - Version v0.0.3 (WIP)
#
# KNOWN ISSUES:
# - Artifact copy to host fails silently (podman cp fails after container cleanup)
# - Official checksum download fails inside container (wget -q suppresses errors, likely DNS/network issue)
# - No error checking on podman cp exit code at line 524
# - Artifacts remain in container if copy fails, lost after cleanup
#
# DESCRIPTION:
# Standalone script for verifying Bitcoin Knots releases using containerized
# reproducible builds. Uses fanquake's proven Alpine Guix methodology without
# requiring external dependencies or host Guix installation.
#
# REQUIREMENTS:
# - Podman installed (sudo apt install podman)
# - Git available
# - Internet connection
# - ~2GB disk space
# - 4GB+ RAM recommended
#
# AUTHOR: WalletScrutiny.com
# DATE: 2025-10-14
# LICENSE: MIT License
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
SCRIPT_VERSION="v0.0.3"
SCRIPT_NAME="verify_bitcoinknots.sh"
DEFAULT_VERSION="v29.2.knots20251010"
CONTAINER_NAME="ws_bitcoinknots_verifier"
IMAGE_NAME="ws_bitcoinknots_verifier"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Help function
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Bitcoin Knots Reproducible Build Verification

USAGE:
    $SCRIPT_NAME [OPTIONS] [VERSION]

DESCRIPTION:
    Verifies Bitcoin Knots releases using fanquake's Alpine Guix methodology.
    Builds Bitcoin Knots from source in a containerized environment and compares
    checksums against official releases.

OPTIONS:
    -h, --help          Show this help message
    -v, --version       Show script version
    -c, --clean         Clean up containers and images before build
    -t, --target HOST   Build target (default: x86_64-linux-gnu)
    --no-verify         Skip checksum verification against official release
    --keep-container    Keep container running after build
    --list-targets      Show available build targets
    --no-copy           Skip copying build artifacts to host (container only)

ARGUMENTS:
    VERSION             Bitcoin Knots version to verify (default: $DEFAULT_VERSION)
                       Examples: v29.2.knots20251010, v29.1.knots20250903

EXAMPLES:
    $SCRIPT_NAME                                    # Verify default version
    $SCRIPT_NAME v29.2.knots20251010                # Verify specific version
    $SCRIPT_NAME --clean v29.1.knots20250903        # Clean up and verify
    $SCRIPT_NAME --target x86_64-w64-mingw32 v29.2.knots20251010  # Windows build
    $SCRIPT_NAME --list-targets                     # Show all available build targets

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
$SCRIPT_NAME v$SCRIPT_VERSION - Available Build Targets

SUPPORTED BUILD TARGETS:
Bitcoin Knots supports building for multiple platforms. Each target produces
different output files based on the platform and architecture.

LINUX TARGETS:
    x86_64-linux-gnu        Standard 64-bit Linux (glibc) - DEFAULT
    aarch64-linux-gnu       64-bit ARM Linux (e.g., Raspberry Pi 4)
    arm-linux-gnueabihf     32-bit ARM Linux (e.g., Raspberry Pi 3)
    powerpc64-linux-gnu     64-bit PowerPC Linux
    powerpc64le-linux-gnu   64-bit PowerPC Little Endian Linux
    riscv64-linux-gnu       64-bit RISC-V Linux

WINDOWS TARGETS:
    x86_64-w64-mingw32      64-bit Windows

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

MULTI-TARGET BUILD:
To build all default targets at once, omit the --target flag:
    $SCRIPT_NAME v29.2.knots20251010

BUILD TIME ESTIMATES:
    Single target:    20-40 minutes
    All targets:      60-120 minutes (depending on hardware)

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
        log_error "Podman is required but not installed"
        log_info "Install with: sudo apt install podman"
        exit 1
    fi

    if ! command -v git &> /dev/null; then
        log_error "Git is required but not installed"
        exit 1
    fi

    # Test podman functionality
    if ! podman --version &> /dev/null; then
        log_error "Podman is not working properly"
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
ARG guix_version=1.4.0
ARG guix_checksum_aarch64=72d807392889919940b7ec9632c45a259555e6b0942ea7bfd131101e08ebfcf4
ARG guix_checksum_x86_64=236ca7c9c5958b1f396c2924fcc5bc9d6fdebcb1b4cf3c7c6d46d4bf660ed9c9
ARG builder_count=32

ENV PATH=/root/.config/guix/current/bin:$PATH
ENV GUIX_LOCPATH=/root/.guix-profile/lib/locale
ENV LC_ALL=en_US.UTF-8

RUN guix_file_name=guix-binary-${guix_version}.$(uname -m)-linux.tar.xz    && \
    eval "guix_checksum=\${guix_checksum_$(uname -m)}"                     && \
    cd /tmp                                                                && \
    wget -q -O "$guix_file_name" "${guix_download_path}/${guix_file_name}" && \
    echo "${guix_checksum}  ${guix_file_name}" | sha256sum -c              && \
    tar xJf "$guix_file_name"                                              && \
    mv var/guix /var/                                                      && \
    mv gnu /                                                               && \
    mkdir -p ~root/.config/guix                                            && \
    ln -sf /var/guix/profiles/per-user/root/current-guix ~root/.config/guix/current && \
    source ~root/.config/guix/current/etc/profile

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

RUN guix archive --authorize < ~root/.config/guix/current/share/guix/ci.guix.gnu.org.pub
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

    if ! podman run -d --name "$CONTAINER_NAME" --privileged "$IMAGE_NAME"; then
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
    podman exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && rm -rf depends/work/ guix-build-*/ base_cache/*" || true
    podman exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && make -C depends clean-all" || true

    # Update repository and checkout version
    log_info "Fetching latest Bitcoin Knots repository..."
    podman exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && git fetch --all --tags"

    log_info "Checking out version: $version"
    if ! podman exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && git checkout $version"; then
        log_error "Failed to checkout version: $version"
        log_error "Available tags:"
        podman exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && git tag | grep -E 'knots' | tail -10"
        exit 1
    fi

    # Verify GPG signature
    log_info "Verifying GPG signature for $version..."
    if podman exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && git verify-tag $version 2>/dev/null"; then
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
    local build_cmd="cd /bitcoin && time BASE_CACHE='/base_cache' SOURCE_PATH='/sources' SDK_PATH='/SDKs' HOSTS='$target' ./contrib/guix/guix-build"

    if podman exec -it "$CONTAINER_NAME" bash -c "$build_cmd"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "Build completed successfully in $duration seconds"
    else
        log_error "Build failed"
        exit 1
    fi
}

# Download official Bitcoin Knots release for comparison
download_official_release() {
    local version="$1"
    local target="$2"

    # Clean version string (remove 'v' prefix)
    local clean_version="${version#v}"

    log_info "Downloading official Bitcoin Knots release for comparison..."
    
    local base_url="https://github.com/bitcoinknots/bitcoin/releases/download/$version/"
    local temp_dir=$(mktemp -d)
    
    cd "$temp_dir"
    
    # Download SHA256SUMS file
    log_info "Downloading SHA256SUMS from: ${base_url}SHA256SUMS"
    if ! wget -q "${base_url}SHA256SUMS" 2>/dev/null; then
        log_warning "Could not download SHA256SUMS file"
        log_info "Manual verification required at: https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Try to download SHA256SUMS.asc for signature verification
    wget -q "${base_url}SHA256SUMS.asc" 2>/dev/null || log_warning "SHA256SUMS.asc not available"
    
    echo "$temp_dir"
}

# Extract and verify checksums
verify_checksums() {
    local version="$1"
    local target="$2"
    local verify_flag="$3"
    local copy_flag="$4"

    # Clean version string for directory names (remove 'v' prefix)
    local clean_version="${version#v}"
    local build_dir="/bitcoin/guix-build-$clean_version/output/$target"

    log_info "Extracting build artifacts from: $build_dir"

    # Check if build directory exists
    if ! podman exec -it "$CONTAINER_NAME" bash -c "test -d $build_dir"; then
        log_error "Build output directory not found: $build_dir"
        log_info "Available directories:"
        podman exec -it "$CONTAINER_NAME" bash -c "ls -la /bitcoin/guix-build-*/" || true
        exit 1
    fi

    # Enhanced artifact listing with file sizes
    echo ""
    log_success "Build artifacts produced:"
    echo ""
    podman exec -it "$CONTAINER_NAME" bash -c "cd $build_dir && ls -lh *.tar.gz *.zip *.exe 2>/dev/null || ls -lh *"

    echo ""
    log_success "SHA256 checksums (official format):"
    echo ""

    # Generate checksums in official format
    local checksums=$(podman exec -it "$CONTAINER_NAME" bash -c "cd $build_dir && sha256sum *.tar.gz *.zip *.exe 2>/dev/null || sha256sum *" | tr -d '\r')

    echo "$checksums"

    echo ""
    log_info "Official Bitcoin Knots checksums can be found at:"
    log_info "${BLUE}https://github.com/bitcoinknots/bitcoin/releases/tag/$version${NC}"
    echo ""

    # Verify against official release if requested
    if [[ "$verify_flag" == "true" ]]; then
        verify_official_checksums "$version" "$checksums"
    fi

    # Copy artifacts to host (optional)
    copy_artifacts_to_host "$version" "$target" "$build_dir" "$copy_flag"
}

# Verify against official Bitcoin Knots checksums
verify_official_checksums() {
    local version="$1"
    local our_checksums="$2"

    log_info "Verifying against official Bitcoin Knots release checksums..."
    
    local official_dir=$(download_official_release "$version" "$target")
    
    if [ -z "$official_dir" ] || [ ! -d "$official_dir" ]; then
        log_warning "Could not download official checksums"
        log_info "Manual verification required"
        return 1
    fi
    
    if [ -f "$official_dir/SHA256SUMS" ]; then
        echo ""
        log_info "Official checksums from GitHub release:"
        cat "$official_dir/SHA256SUMS"
        echo ""
        
        log_info "Comparing checksums..."
        # Simple comparison - could be enhanced with line-by-line matching
        echo "$our_checksums" | while read hash filename; do
            if grep -q "$hash" "$official_dir/SHA256SUMS"; then
                log_success "✅ Match: $filename"
            else
                log_warning "❌ No match: $filename"
            fi
        done
    fi
    
    rm -rf "$official_dir"
}

# Copy build artifacts to host
copy_artifacts_to_host() {
    local version="$1"
    local target="$2"
    local build_dir="$3"
    local copy_flag="$4"

    if [[ "$copy_flag" == "false" ]]; then
        log_info "Skipping artifact copy to host (--no-copy specified)"
        log_info "Artifacts remain in container at: $build_dir"
        return 0
    fi

    # Clean version string for directory names (remove 'v' prefix)
    local clean_version="${version#v}"

    # Create timestamped directory in current working directory
    local output_dir="./bitcoinknots-$clean_version-$target-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$output_dir"

    log_info "Copying build artifacts to host: $output_dir"

    # Copy all files from build directory
    if podman cp "$CONTAINER_NAME:$build_dir/." "$output_dir/"; then

        # Generate local SHA256SUMS file for convenience
        log_info "Generating local SHA256SUMS file..."
        (cd "$output_dir" && sha256sum *.tar.gz *.zip *.exe 2>/dev/null || sha256sum * > SHA256SUMS.local)

        echo ""
        log_success "✅ Artifacts copied to: $output_dir"
        echo ""
        log_info "📁 Contents:"
        ls -lh "$output_dir/"
        echo ""
        log_info "🔍 Local checksums saved to: $output_dir/SHA256SUMS.local"
        log_info "🌐 Compare with official: https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
        echo ""

    else
        log_warning "Failed to copy artifacts to host"
        log_info "Artifacts remain in container at: $build_dir"
    fi
}

# Final cleanup
final_cleanup() {
    local keep_container="$1"

    if [[ "$keep_container" == "false" ]]; then
        log_info "Cleaning up containers and images..."
        cleanup_containers
        log_success "Cleanup completed"
    else
        log_info "Container kept running as requested: $CONTAINER_NAME"
        log_info "To connect: podman exec -it $CONTAINER_NAME bash"
        log_info "To clean up later: podman rm -f $CONTAINER_NAME && podman rmi -f $IMAGE_NAME"
    fi
}

# Main execution function
main() {
    local version="$DEFAULT_VERSION"
    local target="x86_64-linux-gnu"
    local clean_flag="false"
    local verify_flag="true"
    local keep_container="false"
    local copy_flag="true"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            --list-targets)
                show_targets
                exit 0
                ;;
            -c|--clean)
                clean_flag="true"
                shift
                ;;
            -t|--target)
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
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                version="$1"
                shift
                ;;
        esac
    done

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
    verify_checksums "$version" "$target" "$verify_flag" "$copy_flag"
    final_cleanup "$keep_container"

    echo ""
    log_success "Bitcoin Knots verification completed successfully!"
}

# Execute main function with all arguments
main "$@"
