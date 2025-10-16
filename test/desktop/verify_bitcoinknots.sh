#!/bin/bash

# Bitcoin Knots Reproducible Build Verification Script
# Based on fanquake's Alpine Guix methodology (adapted from verify_bitcoincore.sh)
# WalletScrutiny.com - Version v0.3.0
#
# DESCRIPTION:
# Standalone script for verifying Bitcoin Knots releases using containerized
# reproducible builds. Performs binary comparison between built artifacts and
# official releases for definitive reproducibility verification.
#
# REQUIREMENTS:
# - Podman installed (sudo apt install podman)
# - Git available
# - Internet connection
# - ~2GB disk space
# - 4GB+ RAM recommended
#
# AUTHOR: WalletScrutiny.com
# DATE: 2025-10-16
# LICENSE: MIT License
#
# CHANGELOG:
# v0.3.0 (2025-10-16): Luis guideline compliance - proper exit codes (0=reproducible, 1=not, 2=manual)
# v0.2.0 (2025-10-16): Binary comparison method, GitHub redirect fix
# v0.1.1: Initial Alpine Guix implementation
#
# LUIS GUIDELINE COMPLIANCE:
# This script follows WalletScrutiny script generation guidelines with one documented deviation:
# - Uses positional argument for version (not -v flag) because -v is reserved for --version
#   per standard Unix convention. This deviation is permitted per updated guidelines.
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
SCRIPT_VERSION="v0.3.0"
SCRIPT_NAME="verify_bitcoinknots.sh"
DEFAULT_VERSION="v29.2.knots20251010"
CONTAINER_NAME="ws_bitcoinknots_verifier"
IMAGE_NAME="ws_bitcoinknots_verifier"

# Global variables for tracking
OUTPUT_DIR=""
OFFICIAL_CHECKSUMS_FILE=""
COPY_SUCCESS="false"

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
        echo "Error: Podman is required. Install with: sudo apt install podman"
        exit 1
    fi

    if ! command -v git &> /dev/null; then
        echo "Error: Git is required"
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

# Download official Bitcoin Knots release checksums (runs on HOST)
download_official_release() {
    local version="$1"

    log_info "Downloading official Bitcoin Knots checksums..."
    
    local base_url="https://github.com/bitcoinknots/bitcoin/releases/download/$version/"
    local temp_dir=$(mktemp -d)
    
    cd "$temp_dir"
    
    # Try wget first (with redirect support)
    log_info "Attempting download from: ${base_url}SHA256SUMS"
    if wget --max-redirect=5 --timeout=10 --tries=3 -q -O SHA256SUMS "${base_url}SHA256SUMS"; then
        log_success "Downloaded SHA256SUMS via wget"
    elif curl -fsSL --max-redirs 5 --retry 3 --retry-delay 2 -o SHA256SUMS "${base_url}SHA256SUMS"; then
        log_success "Downloaded SHA256SUMS via curl"
    else
        log_warning "Could not download SHA256SUMS file"
        log_info "Manual verification required at: https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Verify file has content
    if [ ! -s "SHA256SUMS" ]; then
        log_error "Downloaded SHA256SUMS file is empty"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Try to download SHA256SUMS.asc for signature verification
    wget --timeout=10 -q "${base_url}SHA256SUMS.asc" 2>/dev/null || \
    curl -fsSL -o SHA256SUMS.asc "${base_url}SHA256SUMS.asc" 2>/dev/null || \
    log_warning "SHA256SUMS.asc not available"
    
    echo "$temp_dir"
}

# Generate checksums from container artifacts
generate_container_checksums() {
    local version="$1"
    local target="$2"

    # Clean version string for directory names (remove 'v' prefix)
    local clean_version="${version#v}"
    local build_dir="/bitcoin/guix-build-$clean_version/output/$target"

    log_info "Checking build artifacts in container: $build_dir"

    # Check if build directory exists
    if ! podman exec -it "$CONTAINER_NAME" bash -c "test -d $build_dir"; then
        log_error "Build output directory not found: $build_dir"
        log_info "Available directories:"
        podman exec -it "$CONTAINER_NAME" bash -c "ls -la /bitcoin/guix-build-*/" || true
        return 1
    fi

    # List artifacts
    echo ""
    log_info "Build artifacts produced:"
    echo ""
    podman exec -it "$CONTAINER_NAME" bash -c "cd $build_dir && ls -lh *.tar.gz *.zip *.exe 2>/dev/null || ls -lh *"
    echo ""

    return 0
}

# Download official checksums to host
download_official_checksums() {
    local version="$1"

    log_info "Downloading official Bitcoin Knots checksums..."

    local official_dir=$(download_official_release "$version")

    if [ -z "$official_dir" ] || [ ! -d "$official_dir" ]; then
        log_warning "Could not download official checksums"
        log_info "Manual verification required at: https://github.com/bitcoinknots/bitcoin/releases/tag/$version"
        OFFICIAL_CHECKSUMS_FILE=""
        return 1
    fi

    if [ -f "$official_dir/SHA256SUMS" ]; then
        OFFICIAL_CHECKSUMS_FILE="$official_dir/SHA256SUMS"
        log_success "Official checksums downloaded to: $OFFICIAL_CHECKSUMS_FILE"
        return 0
    else
        log_error "SHA256SUMS file not found in download directory"
        OFFICIAL_CHECKSUMS_FILE=""
        return 1
    fi
}

# Download official artifacts for binary comparison
download_official_artifacts() {
    local version="$1"      # e.g., v29.2.knots20251010
    local output_dir="$2"   # e.g., ./bitcoinknots-29.2.knots20251010-x86_64-linux-gnu-20251016-005313

    log_info "Downloading official Bitcoin Knots artifacts for binary comparison..."

    # Create subdirectory for official artifacts
    local official_dir="$output_dir/official-downloads"
    mkdir -p "$official_dir"

    # Construct base URL
    local base_url="https://github.com/bitcoinknots/bitcoin/releases/download/$version/"

    local download_count=0
    local failed_count=0

    # Scan output directory for built artifacts (excluding SHA256SUMS files)
    for built_file in "$output_dir"/*.tar.gz "$output_dir"/*.zip "$output_dir"/*.exe; do
        # Check if file exists and is not a glob pattern
        if [ -f "$built_file" ]; then
            local filename=$(basename "$built_file")

            # Skip SHA256SUMS files
            if [[ "$filename" == SHA256SUMS* ]]; then
                continue
            fi

            local official_url="${base_url}${filename}"

            log_info "Downloading official artifact: $filename"

            # Download with redirect support
            if wget --max-redirect=5 --timeout=30 --tries=3 -q -O "$official_dir/$filename" "$official_url"; then
                log_success "Downloaded: $filename"
                download_count=$((download_count + 1))
            elif curl -fsSL --max-redirs 5 --retry 3 --retry-delay 2 -o "$official_dir/$filename" "$official_url"; then
                log_success "Downloaded: $filename"
                download_count=$((download_count + 1))
            else
                log_error "Failed to download: $filename"
                log_error "URL: $official_url"
                failed_count=$((failed_count + 1))
            fi
        fi
    done

    if [ $download_count -eq 0 ]; then
        log_error "No official artifacts were downloaded"
        return 1
    fi

    log_success "Downloaded $download_count official artifacts to: $official_dir"

    if [ $failed_count -gt 0 ]; then
        log_warning "$failed_count artifacts failed to download"
    fi

    return 0
}

# Perform binary comparison between built and official artifacts
compare_artifacts_binary() {
    local output_dir="$1"
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

    # Create comparison results file
    local comparison_file="$output_dir/COMPARISON_RESULTS.txt"
    echo "Bitcoin Knots Binary Comparison Results" > "$comparison_file"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$comparison_file"
    echo "========================================" >> "$comparison_file"
    echo "" >> "$comparison_file"

    for built_file in "$output_dir"/*.tar.gz "$output_dir"/*.zip "$output_dir"/*.exe; do
        if [ -f "$built_file" ]; then
            local filename=$(basename "$built_file")

            # Skip SHA256SUMS files
            if [[ "$filename" == SHA256SUMS* ]]; then
                continue
            fi

            local official_file="$official_dir/$filename"

            if [ ! -f "$official_file" ]; then
                log_warning "Official file not found for comparison: $filename"
                continue
            fi

            total=$((total + 1))

            # Binary comparison using cmp
            if cmp -s "$built_file" "$official_file"; then
                matches=$((matches + 1))
                log_success "✓ MATCH: $filename (binary identical)"
                echo "✓ MATCH: $filename" >> "$comparison_file"
                echo "  Built:    $(sha256sum "$built_file" | cut -d' ' -f1)" >> "$comparison_file"
                echo "  Official: $(sha256sum "$official_file" | cut -d' ' -f1)" >> "$comparison_file"
                echo "" >> "$comparison_file"
            else
                mismatches=$((mismatches + 1))
                log_error "✗ MISMATCH: $filename (binary differs)"
                echo "✗ MISMATCH: $filename" >> "$comparison_file"
                echo "  Built:    $(sha256sum "$built_file" | cut -d' ' -f1)" >> "$comparison_file"
                echo "  Official: $(sha256sum "$official_file" | cut -d' ' -f1)" >> "$comparison_file"

                # Get file sizes (portable stat command)
                local built_size=$(stat -c '%s' "$built_file" 2>/dev/null || stat -f '%z' "$built_file" 2>/dev/null)
                local official_size=$(stat -c '%s' "$official_file" 2>/dev/null || stat -f '%z' "$official_file" 2>/dev/null)
                echo "  Built size:    $built_size bytes" >> "$comparison_file"
                echo "  Official size: $official_size bytes" >> "$comparison_file"
                echo "" >> "$comparison_file"
            fi
        fi
    done

    # Summary
    echo "" >> "$comparison_file"
    echo "========================================" >> "$comparison_file"
    echo "SUMMARY:" >> "$comparison_file"
    echo "  Total artifacts compared: $total" >> "$comparison_file"
    echo "  Matches (binary identical): $matches" >> "$comparison_file"
    echo "  Mismatches (binary differs): $mismatches" >> "$comparison_file"
    echo "========================================" >> "$comparison_file"

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
    local build_dir="/bitcoin/guix-build-$clean_version/output/$target"

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

    # Create timestamped directory in current working directory
    OUTPUT_DIR="./bitcoinknots-$clean_version-$target-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$OUTPUT_DIR"

    log_info "Copying build artifacts to host: $OUTPUT_DIR"

    # Copy all files from build directory
    if ! podman cp "$CONTAINER_NAME:$build_dir/." "$OUTPUT_DIR/" 2>&1; then
        log_error "podman cp command failed (exit code: $?)"
        log_error "Artifacts remain in container at: $build_dir"
        log_info "Use --keep-container flag and extract manually with:"
        log_info "  podman cp $CONTAINER_NAME:$build_dir/. ./output/"
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
        
        # List each file with size, date, and hash
        for file in "$OUTPUT_DIR"/*; do
            if [ -f "$file" ] && [ "$(basename "$file")" != "SHA256SUMS.local" ]; then
                local filename=$(basename "$file")
                local filesize=$(du -k "$file" | cut -f1)
                local filedate=$(stat -c '%y' "$file" | cut -d'.' -f1)
                local filehash=$(sha256sum "$file" | cut -d' ' -f1)
                
                echo "File: $filename"
                echo "  Path: $file"
                echo "  Size: ${filesize} KB"
                echo "  Date: $filedate"
                echo "  SHA256 (built): $filehash"
                
                # Compare with official if available
                if [ -n "$OFFICIAL_CHECKSUMS_FILE" ] && [ -f "$OFFICIAL_CHECKSUMS_FILE" ]; then
                    local official_hash=$(grep "$filename" "$OFFICIAL_CHECKSUMS_FILE" 2>/dev/null | awk '{print $1}')
                    if [ -n "$official_hash" ]; then
                        echo "  SHA256 (official): $official_hash"
                        if [ "$filehash" == "$official_hash" ]; then
                            echo "  Comparison: MATCH"
                        else
                            echo "  Comparison: MISMATCH"
                        fi
                    else
                        echo "  SHA256 (official): NOT FOUND"
                        echo "  Comparison: N/A"
                    fi
                fi
                echo ""
            fi
        done
        
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
                # Count matches
                local total=0
                local matches=0
                for file in "$OUTPUT_DIR"/*; do
                    if [ -f "$file" ] && [ "$(basename "$file")" != "SHA256SUMS.local" ]; then
                        total=$((total + 1))
                        local filename=$(basename "$file")
                        local filehash=$(sha256sum "$file" | cut -d' ' -f1)
                        local official_hash=$(grep "$filename" "$OFFICIAL_CHECKSUMS_FILE" 2>/dev/null | awk '{print $1}')
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

# Final cleanup
final_cleanup() {
    local keep_container="$1"

    # Keep container if copy failed
    if [[ "$COPY_SUCCESS" == "false" ]]; then
        log_warning "Artifact copy failed, keeping container for manual extraction"
        log_info "Container: $CONTAINER_NAME"
        log_info "To extract artifacts manually:"
        log_info "  podman exec -it $CONTAINER_NAME bash"
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
    
    # Generate checksums in container
    generate_container_checksums "$version" "$target" || true
    
    # Copy artifacts to host BEFORE any cleanup
    copy_artifacts_to_host "$version" "$target" "$copy_flag" || true

    # Download and compare with official artifacts (NEW PRIMARY METHOD)
    local verification_result=2  # Default: no comparison performed

    if [[ "$verify_flag" == "true" ]] && [[ "$COPY_SUCCESS" == "true" ]]; then
        if download_official_artifacts "$version" "$OUTPUT_DIR"; then
            compare_artifacts_binary "$OUTPUT_DIR"
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
