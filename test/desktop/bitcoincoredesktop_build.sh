#!/usr/bin/env bash
# ==============================================================================
# bitcoincoredesktop_build.sh - Bitcoin Core Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.3
# Organization:  WalletScrutiny.com
# Last Modified: 2025-12-02
# Project:       https://github.com/bitcoin/bitcoin
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
# - Downloads official Bitcoin Core releases from bitcoincore.org
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using embedded Dockerfile (Alpine Guix)
# - Builds only standard release binaries (no debug/unsigned variants)
# - Compares checksums between official and built binaries
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Documents differences and generates detailed reproducibility assessment
#
# CREDITS:
# This script's containerized approach is inspired by Michael Ford's (fanquake)
# excellent work on reproducible Bitcoin Core builds. The embedded imagefile
# is based on fanquake's Alpine Guix methodology from:
# https://github.com/fanquake/core-review

set -euo pipefail

# Script metadata
SCRIPT_VERSION="v0.3.3"
SCRIPT_NAME="bitcoincoredesktop_build.sh"
APP_NAME="Bitcoin Core"
APP_ID="bitcoincore"
REPO_URL="https://github.com/bitcoin/bitcoin"
DEFAULT_VERSION="29.1"
CONTAINER_NAME=""
IMAGE_NAME=""
VERIFICATION_EXIT_CODE=1

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
log_info() { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn() { echo -e "${YELLOW}${WARNING_ICON}${NC} $*"; }
log_error() { echo -e "${RED}${ERROR_ICON}${NC} $*" >&2; }

# ---------- Helper Functions ----------
# Sanitize string for container/image names
sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input##-}"
    input="${input%%-}"
    if [[ -z "$input" ]]; then
        input="na"
    fi
    echo "$input"
}

set_unique_names() {
    local version_component
    local arch_component
    local type_component
    version_component=$(sanitize_component "$1")
    arch_component=$(sanitize_component "$2")
    type_component=$(sanitize_component "$3")
    local suffix
    suffix=$(sanitize_component "$(date +%s)-$$")

    CONTAINER_NAME="ws-bitcoin-verifier-${version_component}-${arch_component}-${type_component}-${suffix}"
    IMAGE_NAME="ws-bitcoin-image-${version_component}-${arch_component}-${type_component}-${suffix}"
}

# ---------- Usage ----------
usage() {
  cat <<EOF
Bitcoin Core Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> --arch <arch> --type <type>

Required Parameters:
  --version <version>    Bitcoin Core version to verify (e.g., 29.1, 30.0)
  --arch <arch>          Target architecture
                         Supported: x86_64-linux, aarch64-linux, arm-linux,
                                   x86_64-windows, x86_64-macos, arm64-macos
  --type <type>          Build type (tarball for linux/macos, zip for windows)

Optional Parameters:

Flags:
  --help                 Show this help message
  --clean                Clean up containers and images before build
  --keep-container       Keep container running after build
  --list-targets         Show available build targets

Examples:
  $(basename "$0") --version 29.1 --arch x86_64-linux --type tarball
  $(basename "$0") --version 29.1 --arch aarch64-linux --type tarball
  $(basename "$0") --version 30.0 --arch x86_64-windows --type zip
  $(basename "$0") --version 29.1 --arch x86_64-macos --type tarball
  $(basename "$0") --list-targets

Requirements:
  - Docker or Podman installed
  - Internet connection for downloading sources and official releases
  - Approximately 2GB disk space for build
  - 30-60 minutes build time

Output:
  - Exit code 0: Binaries are reproducible
  - Exit code 1: Binaries differ or verification failed
  - COMPARISON_RESULTS.yaml: Machine-readable comparison results
  - Standardized results format between ===== Begin/End Results =====

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# Show available build targets
show_targets() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Available Build Targets

SUPPORTED BUILD TARGETS:
Bitcoin Core supports building for multiple platforms. Each target produces
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
Each build produces ONE standard release binary per architecture:

FOR LINUX/DESKTOP TARGETS:
    bitcoin-VERSION-TARGET.tar.gz           # Main binaries only

FOR WINDOWS TARGET (x86_64-w64-mingw32):
    bitcoin-VERSION-win64.zip               # Main Windows binaries only

FOR MACOS TARGETS:
    bitcoin-VERSION-TARGET.tar.gz           # Main binaries only

NOTE: Debug, unsigned, codesigning, and installer variants are NOT built.
      Only the primary release binary is built and verified.

BUILD TIME ESTIMATES:
    Single target:    20-40 minutes

EXAMPLE OUTPUTS FOR v29.1 (standard releases only):
    bitcoin-29.1-x86_64-linux-gnu.tar.gz           (50.4 MB)
    bitcoin-29.1-aarch64-linux-gnu.tar.gz          (47.9 MB)
    bitcoin-29.1-arm-linux-gnueabihf.tar.gz        (44.5 MB)
    bitcoin-29.1-win64.zip                         (47.8 MB)
    bitcoin-29.1-x86_64-apple-darwin.tar.gz        (39.0 MB)
    bitcoin-29.1-arm64-apple-darwin.tar.gz         (35.7 MB)

VERIFICATION:
All output files can be verified against official Bitcoin Core releases
available at: https://bitcoin.org/bin/bitcoin-core-VERSION/

For latest releases and to check actual binary names:
    https://bitcoincore.org/bin/

EOF
}

# Version function
show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
    echo "Based on fanquake's Alpine Guix methodology"
    echo "WalletScrutiny.com Bitcoin Core verification tool"
}

# ---------- Parameter Parsing ----------
version=""
arch=""
build_type=""
clean_flag="false"
keep_container="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --arch)
      arch="$2"
      shift 2
      ;;
    --type)
      build_type="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    --clean)
      clean_flag="true"
      shift
      ;;
    --keep-container)
      keep_container="true"
      shift
      ;;
    --list-targets)
      show_targets
      exit 0
      ;;
    *)
      log_error "Unknown parameter: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate required parameters
if [[ -z "$version" ]]; then
  log_error "Missing required parameter: --version"
  usage
  exit 1
fi

if [[ -z "$arch" ]]; then
  log_error "Missing required parameter: --arch"
  usage
  exit 1
fi

if [[ -z "$build_type" ]]; then
  log_error "Missing required parameter: --type"
  usage
  exit 1
fi

# Validate build type per arch
case "$arch" in
  x86_64-windows|win64)
    if [[ "$build_type" != "zip" && "$build_type" != "setup" ]]; then
      log_error "Unsupported type for ${arch}: ${build_type}. Use --type zip or --type setup"
      exit 1
    fi
    ;;
  x86_64-linux|x86_64-linux-gnu|aarch64-linux|arm-linux|x86_64-macos|arm64-macos)
    if [[ "$build_type" != "tarball" ]]; then
      log_error "Unsupported type for ${arch}: ${build_type}. Use --type tarball"
      exit 1
    fi
    ;;
  *)
    log_error "Unsupported architecture/type combo: ${arch}/${build_type}"
    exit 1
    ;;
esac

# Add 'v' prefix if not present (Bitcoin Core uses v-prefixed tags)
if [[ ! "$version" =~ ^v ]]; then
  version="v${version}"
fi

# Generate unique container/image names for this invocation
set_unique_names "$version" "$arch" "$build_type"

# Map build server architecture to Guix host triplet
map_arch_to_guix() {
    local bs_arch="$1"
    case "$bs_arch" in
        x86_64-linux)
            echo "x86_64-linux-gnu"
            ;;
        x86_64-linux-gnu)
            echo "x86_64-linux-gnu"
            ;;
        aarch64-linux)
            echo "aarch64-linux-gnu"
            ;;
        arm-linux)
            echo "arm-linux-gnueabihf"
            ;;
        x86_64-windows|win64)
            echo "x86_64-w64-mingw32"
            ;;
        x86_64-macos)
            echo "x86_64-apple-darwin"
            ;;
        arm64-macos)
            echo "arm64-apple-darwin"
            ;;
        *)
            log_error "Unsupported architecture: $bs_arch"
            exit 1
            ;;
    esac
}

# Generate error YAML
generate_error_yaml() {
    local output_file="$1"
    local error_msg="$2"
    local status="${3:-ftbfs}"
    
    cat > "$output_file" << EOF
date: $(date -Iseconds)
script_version: ${SCRIPT_VERSION}
build_type: ${build_type}
results:
  - architecture: ${arch}
    filename: N/A
    hash: N/A
    match: false
    status: ${status}
    error: ${error_msg}
EOF
}

# Generate success YAML
generate_yaml() {
    local output_file="$1"
    local filename="$2"
    local hash="$3"
    local match="$4"
    local status="$5"
    
    cat > "$output_file" << EOF
date: $(date -Iseconds)
script_version: ${SCRIPT_VERSION}
build_type: ${build_type}
results:
  - architecture: ${arch}
    filename: ${filename}
    hash: ${hash}
    match: ${match}
    status: ${status}
EOF
}

# Dependency checks
check_dependencies() {
    log_info "Checking dependencies..."

    # Check for container runtime (Podman first, Docker as fallback)
    if command -v podman >/dev/null 2>&1; then
        container_cmd="podman"
    elif command -v docker >/dev/null 2>&1; then
        container_cmd="docker"
    else
        log_error "Neither podman nor docker found. Please install one of them."
        echo "Exit code: 1"
        exit 1
    fi

    log_info "Using container runtime: ${container_cmd}"

    log_success "All dependencies found"
}

# Cleanup function
cleanup_containers() {
    if [[ -z "${container_cmd:-}" ]]; then
        return
    fi

    log_info "Cleaning up existing containers and images..."

    # Remove container if exists
    if ${container_cmd} container exists "$CONTAINER_NAME" 2>/dev/null; then
        log_info "Removing existing container: $CONTAINER_NAME"
        ${container_cmd} rm -f "$CONTAINER_NAME" || true
    fi

    # Remove image if exists
    if ${container_cmd} image exists "$IMAGE_NAME" 2>/dev/null; then
        log_info "Removing existing image: $IMAGE_NAME"
        ${container_cmd} rmi -f "$IMAGE_NAME" || true
    fi

    log_success "Cleanup completed"
}

# Trap cleanup handler (runs on exit for failure paths)
TRAP_CLEANUP_COMPLETED=false
cleanup_on_exit() {
    local exit_code=$?
    if [[ -n "${temp_imagefile:-}" && -f "${temp_imagefile:-}" ]]; then
        rm -f "$temp_imagefile"
    fi

    if [[ "${TRAP_CLEANUP_COMPLETED:-false}" != "true" && "${keep_container:-false}" != "true" ]]; then
        cleanup_containers
    fi

    return "$exit_code"
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

RUN git clone https://github.com/bitcoin/bitcoin.git /bitcoin
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

    log_info "Building Bitcoin Core verification container..."
    log_info "This may take 5-15 minutes depending on network speed..."

    if ! ${container_cmd} build --pull --no-cache -t "$IMAGE_NAME" - < "$imagefile_path"; then
        log_error "Container build failed"
        generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Container image build failed" "ftbfs"
        exit 1
    fi

    log_success "Container built successfully: $IMAGE_NAME"
}

# Start container daemon
start_container() {
    log_info "Starting container daemon: $CONTAINER_NAME"

    # Remove any existing container with the same name first
    if ${container_cmd} container exists "$CONTAINER_NAME" 2>/dev/null; then
        log_info "Removing existing container: $CONTAINER_NAME"
        ${container_cmd} rm -f "$CONTAINER_NAME" || true
    fi

    if ! ${container_cmd} run -d --name "$CONTAINER_NAME" --privileged "$IMAGE_NAME"; then
        log_error "Failed to start container"
        generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Failed to start container daemon" "ftbfs"
        exit 1
    fi

    # Wait a moment for daemon to start
    sleep 2

    log_success "Container daemon started"
}

# Verify Bitcoin Core version and prepare build
prepare_bitcoin_build() {
    local version="$1"
    local arch="$2"

    log_info "Preparing Bitcoin Core $version build for architecture: $arch"

    # Clean previous build artifacts
    log_info "Cleaning previous build artifacts..."
        ${container_cmd} exec "$CONTAINER_NAME" bash -c "cd /bitcoin && rm -rf depends/work/ guix-build-*/ base_cache/*" || true
        ${container_cmd} exec "$CONTAINER_NAME" bash -c "cd /bitcoin && make -C depends clean-all" || true

    # Update repository and checkout version
    log_info "Fetching latest Bitcoin Core repository..."
        ${container_cmd} exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git fetch --all --tags"

    log_info "Checking out version: $version"
        if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git checkout $version"; then
        log_error "Failed to checkout version: $version"
        log_error "Available tags:"
        ${container_cmd} exec -it "$CONTAINER_NAME" bash -c "cd /bitcoin && git tag | grep -E '^v[0-9]' | tail -10"
        generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Git checkout failed for version $version" "nosource"
        exit 1
    fi

    # Verify GPG signature
    log_info "Verifying GPG signature for $version..."
    if ${container_cmd} exec "$CONTAINER_NAME" bash -c "cd /bitcoin && git verify-tag $version 2>/dev/null"; then
        log_success "GPG signature verified for $version"
    else
        log_warn "GPG signature verification failed for $version"
        log_warn "This may be normal for release candidates"
    fi

    log_success "Bitcoin Core $version prepared for build"
}

# Execute Guix build
execute_build() {
    local version="$1"
    local arch="$2"

    log_info "Starting Guix build for Bitcoin Core $version..."
    log_info "Architecture: $arch"
    log_info "This will take 20-60 minutes depending on hardware..."

    local start_time=$(date +%s)

    # Execute the build (disable debug builds to save time and space)
    local build_cmd="cd /bitcoin && time BASE_CACHE='/base_cache' SOURCE_PATH='/sources' SDK_PATH='/SDKs' HOSTS='$arch' SKIP_DEBUG=1 ./contrib/guix/guix-build"

    if ${container_cmd} exec "$CONTAINER_NAME" bash -c "$build_cmd"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "Build completed successfully in $duration seconds"
    else
        log_error "Build failed"
        generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Guix build process failed" "ftbfs"
        exit 1
    fi
}

# Extract and verify checksums
verify_checksums() {
    local version="$1"
    local arch="$2"

    # Clean version string for directory names (remove 'v' prefix)
    local clean_version="${version#v}"
    local build_dir="/bitcoin/guix-build-$clean_version/output/$arch"

    log_info "Extracting build artifacts from: $build_dir"

    # Check if build directory exists
    if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "test -d $build_dir"; then
        log_error "Build output directory not found: $build_dir"
        log_info "Available directories:"
        ${container_cmd} exec -it "$CONTAINER_NAME" bash -c "ls -la /bitcoin/guix-build-*/" || true
        generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Build output directory not found" "ftbfs"
        echo "Exit code: 1"
        exit 1
    fi

    # Enhanced artifact listing with file sizes
    echo ""
    log_success "Build artifacts produced:"
    echo ""
    ${container_cmd} exec "$CONTAINER_NAME" bash -c "cd $build_dir && ls -lh *.tar.gz *.zip *.exe 2>/dev/null || ls -lh *"

    echo ""
    log_info "Downloading official Bitcoin Core release for comparison..."
    
    # Create directories for comparison (inside container)
    ${container_cmd} exec "$CONTAINER_NAME" bash -c "mkdir -p /official /built"
    
    # Determine artifact name (standard release only)
    local main_artifact="bitcoin-${clean_version}-${arch}.tar.gz"
    
    # Handle Windows naming convention
    if [[ "$arch" == "x86_64-w64-mingw32" ]]; then
        main_artifact="bitcoin-${clean_version}-win64.zip"
    fi
    
    # Download official release inside container
    local official_url="https://bitcoincore.org/bin/bitcoin-core-${clean_version}"
    log_info "Downloading ${main_artifact} inside container..."
    if ${container_cmd} exec "$CONTAINER_NAME" bash -c "curl -fsSL -o /official/${main_artifact} ${official_url}/${main_artifact}"; then
        log_success "Downloaded official release"
    else
        log_warn "Could not download official release - manual verification required"
        log_info "Official checksums: ${official_url}/SHA256SUMS"
    fi
    
    # Copy built artifacts to /built inside container
    log_info "Organizing built artifacts inside container..."
    ${container_cmd} exec "$CONTAINER_NAME" bash -c "cp $build_dir/* /built/"
    
    # Create local directories for extraction
    official_dir="$workspace/official"
    built_dir="$workspace/built"
    mkdir -p "$official_dir" "$built_dir"
    
    # Copy artifacts from container to host for final comparison
    ${container_cmd} cp "$CONTAINER_NAME:/official/." "$official_dir/" 2>/dev/null || true
    ${container_cmd} cp "$CONTAINER_NAME:/built/." "$built_dir/"
    
    # Generate checksums and compare
    echo ""
    log_info "Comparing checksums..."
    
    comparison_file="${execution_dir}/COMPARISON_RESULTS.yaml"
    match_count=0
    diff_count=0
    
    # Compare main artifact if official exists
    if [[ -f "${official_dir}/${main_artifact}" && -f "${built_dir}/${main_artifact}" ]]; then
        built_hash=$(sha256sum "${built_dir}/${main_artifact}" | awk '{print $1}')
        official_hash=$(sha256sum "${official_dir}/${main_artifact}" | awk '{print $1}')
        
        if [[ "$built_hash" == "$official_hash" ]]; then
            generate_yaml "$comparison_file" "$main_artifact" "$built_hash" "true" "reproducible"
            match_count=$((match_count + 1))
            verdict="reproducible"
            log_success "Match: ${main_artifact}"
            log_success "Hash: ${built_hash}"
        else
            generate_yaml "$comparison_file" "$main_artifact" "$built_hash" "false" "not_reproducible"
            diff_count=$((diff_count + 1))
            verdict="not_reproducible"
            log_warn "Difference: ${main_artifact}"
            log_warn "Built:    ${built_hash}"
            log_warn "Official: ${official_hash}"
        fi
    else
        # No official to compare - just report built hash
        if [[ -f "${built_dir}/${main_artifact}" ]]; then
            built_hash=$(sha256sum "${built_dir}/${main_artifact}" | awk '{print $1}')
            generate_error_yaml "$comparison_file" "No official release available for comparison" "nosource"
            diff_count=$((diff_count + 1))
            verdict="not_reproducible"
            log_warn "No official release to compare - manual verification required"
            log_info "Built hash: ${built_hash}"
        else
            generate_error_yaml "$comparison_file" "Built artifact not found" "ftbfs"
            verdict="not_reproducible"
            log_error "Built artifact not found: ${main_artifact}"
        fi
    fi
    
    # ---------- Standardized Output Format ----------
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A"
    echo "apkVersionName: ${clean_version}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${verdict}"
    if [[ -f "${official_dir}/${main_artifact}" ]]; then
        echo "appHash:        $(sha256sum "${official_dir}/${main_artifact}" | awk '{print $1}')"
    else
        echo "appHash:        N/A (no official release)"
    fi
    echo "commit:         ${version}"
    echo ""
    echo "Diff:"
    if [[ "$verdict" == "reproducible" ]]; then
        echo "BUILDS MATCH BINARIES"
    else
        echo "BUILDS DO NOT MATCH BINARIES"
    fi
    
    # Machine-readable format for desktop binaries
    if [[ -f "${built_dir}/${main_artifact}" ]]; then
        local built_hash=$(sha256sum "${built_dir}/${main_artifact}" | awk '{print $1}')
        local match_flag="0"
        local match_text="DOESN'T MATCH"
        if [[ "$verdict" == "reproducible" ]]; then
            match_flag="1"
            match_text="MATCHES"
        fi
        echo "${main_artifact} - ${guix_arch} - ${built_hash} - ${match_flag} (${match_text})"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Git tag: ${version}"
    echo ""
    echo "===== End Results ====="
    echo ""
    
    # ---------- Summary ----------
    log_info "=============================================="
    log_info "Verification Summary"
    log_info "=============================================="
    log_info "Version: ${clean_version}"
    log_info "Architecture: ${arch}"
    log_info "Matches: ${match_count}"
    log_info "Differences: ${diff_count}"
    
    if [[ "$verdict" == "reproducible" ]]; then
        log_success "Verdict: REPRODUCIBLE"
        log_info "Build server output: ${comparison_file}"
        echo "Exit code: 0"
        VERIFICATION_EXIT_CODE=0
    else
        log_warn "Verdict: NOT REPRODUCIBLE"
        log_info "Build server output: ${comparison_file}"
        log_info "Official checksums: https://bitcoincore.org/bin/bitcoin-core-${clean_version}/SHA256SUMS"
        echo "Exit code: 1"
        VERIFICATION_EXIT_CODE=1
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

    TRAP_CLEANUP_COMPLETED=true
}

# ---------- Setup Workspace ----------
execution_dir="$(pwd)"

# Map architecture to Guix format
guix_arch=$(map_arch_to_guix "$arch")

workspace="${execution_dir}/bitcoin_core_${version}_${arch}_$$"
mkdir -p "$workspace"
cd "$workspace"

log_info "=============================================="
log_info "${APP_NAME} ${version} Verification"
log_info "=============================================="
log_info "Script version: ${SCRIPT_VERSION}"
log_info "Build server architecture: ${arch}"
log_info "Guix host triplet: ${guix_arch}"
log_info "Build type: ${build_type}"
log_info "Workspace: ${workspace}"
log_info ""

# Main execution flow
check_dependencies

if [[ "$clean_flag" == "true" ]]; then
    cleanup_containers
fi

# Create temporary imagefile
temp_imagefile=$(mktemp)
trap cleanup_on_exit EXIT

create_imagefile "$temp_imagefile"
build_container "$temp_imagefile"
start_container
prepare_bitcoin_build "$version" "$guix_arch"
execute_build "$version" "$guix_arch"
verify_checksums "$version" "$guix_arch"
final_cleanup "$keep_container"
exit "$VERIFICATION_EXIT_CODE"
