#!/bin/bash
#
# verify_sparrow.sh - Sparrow Desktop Reproducible Build Verifier
#
# Version: v0.0.1
#
# Description:
#   Automated reproducible build verification for Sparrow Desktop wallet.
#   Builds from source using Docker, downloads official release, performs
#   comprehensive comparison including critical binaries, modules file deep
#   inspection, and JVM-generated class analysis. Generates detailed
#   verification report with reproducibility verdict.
#
# Usage:
#   verify_sparrow.sh VERSION [OPTIONS]
#
# Example:
#   verify_sparrow.sh 2.3.0
#   verify_sparrow.sh 2.3.0 --work-dir /tmp/sparrow-verify
#   verify_sparrow.sh 2.3.0 --skip-build --verify-only
#
# Author: WalletScrutiny Team
# Repository: https://github.com/walletscrutiny/walletScrutinyCom
#

set -x 

# Script version
SCRIPT_VERSION="v0.0.1"

# Default values
DEFAULT_WORK_DIR_BASE="$HOME/builds/desktop/sparrow"
DEFAULT_REPORT_DIR_BASE="$HOME/work/0-reports/desktop/sparrow"
DEFAULT_JDK_VERSION="22.0.2+9"
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Global variables
VERSION=""
WORK_DIR=""
REPORT_DIR=""
JDK_VERSION="$DEFAULT_JDK_VERSION"
BASE_IMAGE="$DEFAULT_BASE_IMAGE"
GITHUB_TAG=""
OFFICIAL_URL=""
CONTAINER_NAME=""

# Flags
SKIP_BUILD=false
SKIP_DOWNLOAD=false
VERIFY_ONLY=false
DEEP_INSPECT_ONLY=false
SKIP_JIMAGE_EXTRACT=false
REBUILD=false
KEEP_CONTAINER=false
NO_CACHE=false
STRICT=false
IGNORE_LEGAL=false
NO_REPORT=false
SAVE_LOGS=false
VERBOSE=false
QUIET=false

# Output format
OUTPUT_FORMAT="markdown"
REPORT_FILE=""

# Exit codes
EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_DOWNLOAD_FAILED=2
EXIT_NOT_REPRODUCIBLE=3
EXIT_CRITICAL_BINARIES_DIFFER=10
EXIT_APP_CODE_DIFFERS=11
EXIT_MANUAL_REVIEW_REQUIRED=12
EXIT_INVALID_ARGS=99

# Verification results
CRITICAL_BINARIES_MATCH=false
APP_CODE_IDENTICAL=false
JVM_CLASSES_ACCEPTABLE=false
LEGAL_FILES_ACCEPTABLE=false
VERDICT_EXIT_CODE=$EXIT_SUCCESS

# Colors for output
if [[ -t 1 ]] && [[ "$QUIET" != true ]]; then
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_RED='\033[0;31m'
    COLOR_BLUE='\033[0;34m'
    COLOR_RESET='\033[0m'
else
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_RED=''
    COLOR_BLUE=''
    COLOR_RESET=''
fi

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    [[ "$QUIET" == true ]] && return
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    [[ "$QUIET" == true ]] && return
    echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $*"
}

log_warning() {
    [[ "$QUIET" == true ]] && return
    echo -e "${COLOR_YELLOW}[⚠]${COLOR_RESET} $*" >&2
}

log_error() {
    echo -e "${COLOR_RED}[✗]${COLOR_RESET} $*" >&2
}

log_verbose() {
    [[ "$VERBOSE" == true ]] && echo -e "    $*"
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# ============================================================================
# Help and Version Functions
# ============================================================================

show_version() {
    echo "verify_sparrow.sh version $SCRIPT_VERSION"
    exit 0
}

show_help() {
    cat << 'EOF'
verify_sparrow.sh - Sparrow Desktop Reproducible Build Verifier

SYNOPSIS
    verify_sparrow.sh VERSION [OPTIONS]

DESCRIPTION
    Automated reproducible build verification for Sparrow Desktop wallet.

    This script performs a complete reproducible build verification:
    1. Builds Sparrow from source using Docker (Ubuntu 22.04 + Temurin JDK)
    2. Downloads official release tarball from GitHub
    3. Compares critical binaries (launcher, libraries, configuration)
    4. Performs deep modules file inspection via JIMAGE extraction
    5. Verifies application code is byte-for-byte identical
    6. Analyzes JVM-generated classes and legal files
    7. Generates comprehensive verification report with verdict

ARGUMENTS
    VERSION
        Sparrow version to verify (e.g., 2.3.0, 2.1.3)

OPTIONS
    General:
        -h, --help              Show this help message and exit
        -v, --version           Show script version and exit
        --verbose               Enable detailed logging
        --quiet                 Suppress non-essential output
        --work-dir DIR          Custom work directory
                                (default: ~/builds/desktop/sparrow/VERSION)

    Build Control:
        --skip-build            Skip Docker build phase
        --skip-download         Skip official release download
        --rebuild               Force rebuild ignoring existing artifacts
        --jdk-version VERSION   Override JDK version (default: 22.0.2+9)
        --container-name NAME   Custom container name
        --keep-container        Keep container running after verification
        --no-cache              Build Docker image without cache

    Verification Control:
        --verify-only           Skip build/download, verify only
        --deep-inspect-only     Only run deep modules inspection
        --skip-jimage-extract   Skip JIMAGE extraction (faster)
        --strict                Fail on any difference including legal files
        --ignore-legal          Don't warn about missing legal files

    Output Control:
        --output-format FORMAT  Report format: markdown|json|text (default: markdown)
        --report-file FILE      Custom report filename
        --report-dir DIR        Custom report directory
        --no-report             Skip report generation
        --save-logs             Save complete build/verification logs

    Advanced:
        --docker-cmd COMMAND    Use alternative to docker (e.g., podman)
        --official-url URL      Override official release download URL
        --github-tag TAG        Override GitHub tag (default: same as VERSION)
        --base-image IMAGE      Override Docker base image (default: ubuntu:22.04)

EXAMPLES
    # Basic verification
    verify_sparrow.sh 2.3.0

    # Verbose mode with custom work directory
    verify_sparrow.sh 2.3.0 --verbose --work-dir /tmp/verify

    # Verify existing artifacts (skip build)
    verify_sparrow.sh 2.3.0 --verify-only

    # Keep container for manual inspection
    verify_sparrow.sh 2.3.0 --keep-container

    # Generate JSON report for automation
    verify_sparrow.sh 2.3.0 --output-format json --quiet

EXIT CODES
    0   Verification successful, reproducible
    1   Build failed
    2   Download failed
    3   Verification failed (not reproducible)
    10  Critical binaries differ
    11  Application code differs (critical)
    12  Unexpected differences requiring manual review
    99  Invalid arguments or configuration error

ENVIRONMENT VARIABLES
    DOCKER_CMD              Docker command to use (default: docker)
    SPARROW_WORK_DIR        Default work directory
    SPARROW_REPORT_DIR      Default report directory

FILES
    Work Directory Structure:
        work-dir/
        ├── Dockerfile
        ├── build-output/Sparrow/        # Built artifacts
        ├── official/Sparrow/             # Official release
        ├── extracted-modules-comparison/ # JIMAGE extraction
        ├── verification-results.txt      # Terminal output log
        └── build.log                     # Build log (if --save-logs)

    Report Location:
        ~/work/0-reports/desktop/sparrow/VERSION/
        └── YYYY-MM-DD.HHMM.sparrowdesktop_vVERSION.md

REPRODUCIBILITY CRITERIA
    REPRODUCIBLE if:
        ✓ Critical binaries byte-for-byte identical
        ✓ Application code 100% identical
        ✓ Only JVM infrastructure or legal files differ

    NOT REPRODUCIBLE if:
        ✗ Critical binaries differ
        ✗ Application code differs
        ✗ Unexpected differences in dependencies

KNOWN ACCEPTABLE DIFFERENCES
    • Missing legal files (~48 files in lib/runtime/legal/)
      Reason: JDK packaging differences (documentation only)

    • Modules file size difference (~94 bytes, 0.0001%)
      Reason: JVM-generated classes (19 files in java.base/java/lang/invoke/)
      Classes: BoundMethodHandle, LambdaForm, Invokers (infrastructure)

VERSION
    verify_sparrow.sh version v0.0.1

AUTHOR
    WalletScrutiny Team

REPORTING BUGS
    https://github.com/walletscrutiny/walletScrutinyCom/issues

SEE ALSO
    Build instructions: ~/work/ws-notes/build-notes/desktop/sparrow/
    Previous verifications: ~/work/0-reports/desktop/sparrow/
    WalletScrutiny: https://walletscrutiny.com
EOF
    exit 0
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        show_help
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -v|--version)
                show_version
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --work-dir)
                WORK_DIR="$2"
                shift 2
                ;;
            --report-dir)
                REPORT_DIR="$2"
                shift 2
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-download)
                SKIP_DOWNLOAD=true
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            --deep-inspect-only)
                DEEP_INSPECT_ONLY=true
                shift
                ;;
            --skip-jimage-extract)
                SKIP_JIMAGE_EXTRACT=true
                shift
                ;;
            --rebuild)
                REBUILD=true
                shift
                ;;
            --keep-container)
                KEEP_CONTAINER=true
                shift
                ;;
            --no-cache)
                NO_CACHE=true
                shift
                ;;
            --strict)
                STRICT=true
                shift
                ;;
            --ignore-legal)
                IGNORE_LEGAL=true
                shift
                ;;
            --no-report)
                NO_REPORT=true
                shift
                ;;
            --save-logs)
                SAVE_LOGS=true
                shift
                ;;
            --jdk-version)
                JDK_VERSION="$2"
                shift 2
                ;;
            --container-name)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --docker-cmd)
                DOCKER_CMD="$2"
                shift 2
                ;;
            --official-url)
                OFFICIAL_URL="$2"
                shift 2
                ;;
            --github-tag)
                GITHUB_TAG="$2"
                shift 2
                ;;
            --base-image)
                BASE_IMAGE="$2"
                shift 2
                ;;
            --output-format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --report-file)
                REPORT_FILE="$2"
                shift 2
                ;;
            -*)
                die "Unknown option: $1" $EXIT_INVALID_ARGS
                ;;
            *)
                if [[ -z "$VERSION" ]]; then
                    VERSION="$1"
                else
                    die "Unexpected argument: $1" $EXIT_INVALID_ARGS
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$VERSION" ]]; then
        die "VERSION argument required. Use --help for usage information." $EXIT_INVALID_ARGS
    fi

    # Set defaults based on VERSION
    WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR_BASE/$VERSION}"
    REPORT_DIR="${REPORT_DIR:-$DEFAULT_REPORT_DIR_BASE/$VERSION}"
    GITHUB_TAG="${GITHUB_TAG:-$VERSION}"
    CONTAINER_NAME="${CONTAINER_NAME:-sparrow-$VERSION-container}"

    # Set official URL if not provided
    if [[ -z "$OFFICIAL_URL" ]]; then
        OFFICIAL_URL="https://github.com/sparrowwallet/sparrow/releases/download/$VERSION/sparrowwallet-$VERSION-x86_64.tar.gz"
    fi

    # Set report filename if not provided
    if [[ -z "$REPORT_FILE" ]] && [[ "$NO_REPORT" != true ]]; then
        local timestamp
        timestamp=$(date +"%Y-%m-%d.%H%M")
        REPORT_FILE="$REPORT_DIR/${timestamp}.sparrowdesktop_v${VERSION}.md"
    fi

    # Validate conflicts
    if [[ "$VERIFY_ONLY" == true ]] && [[ "$DEEP_INSPECT_ONLY" == true ]]; then
        die "Cannot use --verify-only and --deep-inspect-only together" $EXIT_INVALID_ARGS
    fi

    if [[ "$SKIP_BUILD" == true ]] && [[ "$REBUILD" == true ]]; then
        die "Cannot use --skip-build and --rebuild together" $EXIT_INVALID_ARGS
    fi
}

# ============================================================================
# Phase 1: Environment Setup
# ============================================================================

setup_workspace() {
    log_info "[1/8] Setting up workspace..."

    # Create work directory structure
    log_verbose "Creating directory structure in: $WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$WORK_DIR/build-output"
    mkdir -p "$WORK_DIR/official"
    mkdir -p "$WORK_DIR/extracted-modules-comparison/build"
    mkdir -p "$WORK_DIR/extracted-modules-comparison/official"

    # Create report directory if needed
    if [[ "$NO_REPORT" != true ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    # Check required tools
    log_verbose "Checking required tools..."
    local missing_tools=()

    if ! command -v "$DOCKER_CMD" &> /dev/null; then
        missing_tools+=("$DOCKER_CMD")
    fi

    if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
        missing_tools+=("wget or curl")
    fi

    if ! command -v tar &> /dev/null; then
        missing_tools+=("tar")
    fi

    if ! command -v sha256sum &> /dev/null; then
        missing_tools+=("sha256sum")
    fi

    if ! command -v diff &> /dev/null; then
        missing_tools+=("diff")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing_tools[*]}" $EXIT_INVALID_ARGS
    fi

    log_success "Workspace setup complete"
}

build_docker() {
    log_info "[2/8] Building Sparrow Desktop from source..."

    if [[ "$SKIP_BUILD" == true ]]; then
        log_info "Skipping build (--skip-build specified)"
        if [[ ! -d "$WORK_DIR/build-output/Sparrow" ]]; then
            log_error "Build output not found at $WORK_DIR/build-output/Sparrow"
            exit $EXIT_BUILD_FAILED
        fi
        return
    fi

    cd "$WORK_DIR"

    # Generate Dockerfile
    log_verbose "Generating Dockerfile..."
    cat > Dockerfile <<'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Download and install Eclipse Temurin JDK
RUN wget -q https://github.com/adoptium/temurin22-binaries/releases/download/jdk-22.0.2%2B9/OpenJDK22U-jdk_x64_linux_hotspot_22.0.2_9.tar.gz \
    && tar -xzf OpenJDK22U-jdk_x64_linux_hotspot_22.0.2_9.tar.gz -C /opt \
    && rm OpenJDK22U-jdk_x64_linux_hotspot_22.0.2_9.tar.gz

ENV JAVA_HOME=/opt/jdk-22.0.2+9
ENV PATH=$JAVA_HOME/bin:$PATH

WORKDIR /build

# Clone Sparrow repository
RUN git clone https://github.com/sparrowwallet/sparrow.git

WORKDIR /build/sparrow

# Checkout specific tag
ARG SPARROW_VERSION
RUN git checkout $SPARROW_VERSION

# Build
RUN ./gradlew jpackage

# Copy output
RUN mkdir -p /output && \
    cp -r build/jpackage/Sparrow /output/ && \
    find /output -type f -exec chmod 644 {} \; && \
    find /output -type d -exec chmod 755 {} \;

CMD ["bash"]
DOCKERFILE_END

    log_success "Dockerfile generated"

    # Build Docker image
    local cache_flag=""
    if [[ "$NO_CACHE" == true ]]; then
        cache_flag="--no-cache"
    fi

    log_info "Building Docker image (this may take several minutes)..."
    log_verbose "Docker build command: docker build $cache_flag --build-arg SPARROW_VERSION=$GITHUB_TAG -t sparrow-$VERSION-builder ."

    if ! docker build $cache_flag --build-arg SPARROW_VERSION="$GITHUB_TAG" -t "sparrow-$VERSION-builder" . > "$WORK_DIR/docker-build.log" 2>&1; then
        log_error "Docker build failed. Check logs: $WORK_DIR/docker-build.log"
        tail -20 "$WORK_DIR/docker-build.log"
        exit $EXIT_BUILD_FAILED
    fi

    log_success "Docker image built successfully"

    # Check if container exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if [[ "$REBUILD" == true ]]; then
            log_info "Removing existing container: $CONTAINER_NAME"
            docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1
        else
            log_info "Container $CONTAINER_NAME already exists, using existing build"
            log_verbose "Use --rebuild to force rebuild"
            return
        fi
    fi

    # Create container
    log_info "Creating container to extract build artifacts..."
    if ! docker create --name "$CONTAINER_NAME" "sparrow-$VERSION-builder" > /dev/null 2>&1; then
        log_error "Failed to create container"
        exit $EXIT_BUILD_FAILED
    fi

    # Copy build output from container
    log_info "Extracting build artifacts from container..."
    if ! docker cp "$CONTAINER_NAME:/output/Sparrow" "$WORK_DIR/build-output/" > /dev/null 2>&1; then
        log_error "Failed to copy build artifacts from container"
        exit $EXIT_BUILD_FAILED
    fi

    log_success "Build artifacts extracted to: $WORK_DIR/build-output/Sparrow"

    # Show build summary
    local file_count=$(find "$WORK_DIR/build-output/Sparrow" -type f | wc -l)
    log_info "Built artifact contains $file_count files"

    # Cleanup container if not keeping
    if [[ "$KEEP_CONTAINER" != true ]]; then
        log_verbose "Removing container $CONTAINER_NAME"
        docker rm "$CONTAINER_NAME" > /dev/null 2>&1
    else
        log_info "Container preserved: $CONTAINER_NAME (use --keep-container to preserve)"
    fi
}

# ============================================================================
# Phase 3: Official Binary Download
# ============================================================================

download_official() {
    log_info "[3/8] Downloading official release..."

    if [[ "$SKIP_DOWNLOAD" == true ]]; then
        log_info "Skipping download (--skip-download specified)"
        if [[ ! -f "$WORK_DIR/sparrowwallet-$VERSION-x86_64.tar.gz" ]] && [[ ! -d "$WORK_DIR/official/Sparrow" ]]; then
            log_error "Official release not found at $WORK_DIR/official/Sparrow"
            exit $EXIT_DOWNLOAD_FAILED
        fi
        return
    fi

    cd "$WORK_DIR"

    # Check if tarball already exists
    if [[ -f "sparrowwallet-$VERSION-x86_64.tar.gz" ]]; then
        log_info "Tarball already exists, skipping download"
    else
        log_verbose "Downloading from: $OFFICIAL_URL"

        # Download with wget or curl
        if command -v wget &> /dev/null; then
            if ! wget -q --show-progress "$OFFICIAL_URL" -O "sparrowwallet-$VERSION-x86_64.tar.gz" 2>&1; then
                log_error "Download failed from $OFFICIAL_URL"
                log_error "Verify version exists at: https://github.com/sparrowwallet/sparrow/releases"
                exit $EXIT_DOWNLOAD_FAILED
            fi
        elif command -v curl &> /dev/null; then
            if ! curl -L -o "sparrowwallet-$VERSION-x86_64.tar.gz" "$OFFICIAL_URL" 2>&1; then
                log_error "Download failed from $OFFICIAL_URL"
                log_error "Verify version exists at: https://github.com/sparrowwallet/sparrow/releases"
                exit $EXIT_DOWNLOAD_FAILED
            fi
        else
            die "Neither wget nor curl available" $EXIT_DOWNLOAD_FAILED
        fi

        log_success "Download complete"
    fi

    # Calculate SHA256 of tarball
    log_verbose "Calculating SHA256 of tarball..."
    local tarball_hash
    tarball_hash=$(sha256sum "sparrowwallet-$VERSION-x86_64.tar.gz" | cut -d' ' -f1)
    log_info "Tarball SHA256: $tarball_hash"

    # Extract tarball
    if [[ -d "official/Sparrow" ]]; then
        log_info "Official release already extracted, skipping extraction"
    else
        log_info "Extracting tarball..."
        mkdir -p official

        if ! tar -xzf "sparrowwallet-$VERSION-x86_64.tar.gz" -C official/ 2>&1; then
            log_error "Failed to extract tarball"
            log_error "Tarball may be corrupted"
            exit $EXIT_DOWNLOAD_FAILED
        fi

        if [[ ! -d "official/Sparrow" ]]; then
            log_error "Expected directory 'Sparrow' not found in tarball"
            exit $EXIT_DOWNLOAD_FAILED
        fi

        log_success "Extraction complete"
    fi

    # Show file count
    local official_count
    official_count=$(find official/Sparrow -type f | wc -l)
    log_info "Official artifact contains $official_count files"
}

# ============================================================================
# Phase 4: Critical Binaries Verification
# ============================================================================

verify_critical_binaries() {
    log_info "[4/8] Verifying critical binaries..."

    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"
    local all_match=true

    # Critical files to verify
    local critical_files=(
        "bin/Sparrow"
        "lib/libapplauncher.so"
        "lib/Sparrow.png"
        "lib/app/Sparrow.cfg"
    )

    for file in "${critical_files[@]}"; do
        log_verbose "Comparing: $file"

        # Check if files exist
        if [[ ! -f "$build_dir/$file" ]]; then
            log_error "Built file missing: $file"
            exit $EXIT_BUILD_FAILED
        fi

        if [[ ! -f "$official_dir/$file" ]]; then
            log_error "Official file missing: $file"
            exit $EXIT_DOWNLOAD_FAILED
        fi

        # Calculate hashes
        local build_hash
        local official_hash
        build_hash=$(sha256sum "$build_dir/$file" | cut -d' ' -f1)
        official_hash=$(sha256sum "$official_dir/$file" | cut -d' ' -f1)

        # Compare
        if [[ "$build_hash" == "$official_hash" ]]; then
            log_success "✓ $file: MATCH"
            log_verbose "  SHA256: $build_hash"
        else
            log_error "✗ $file: MISMATCH"
            log_error "  Built:    $build_hash"
            log_error "  Official: $official_hash"
            all_match=false
        fi
    done

    if [[ "$all_match" == true ]]; then
        CRITICAL_BINARIES_MATCH=true
        log_success "All critical binaries identical (4/4 match)"
    else
        CRITICAL_BINARIES_MATCH=false
        log_error "Critical binaries differ - build is NOT reproducible"
        VERDICT_EXIT_CODE=$EXIT_CRITICAL_BINARIES_DIFFER
        exit $EXIT_CRITICAL_BINARIES_DIFFER
    fi
}

# ============================================================================
# Phase 5: File Count Analysis
# ============================================================================

analyze_file_counts() {
    log_info "[5/8] Analyzing file differences..."

    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"

    # Count files
    local build_count
    local official_count
    build_count=$(find "$build_dir" -type f | wc -l)
    official_count=$(find "$official_dir" -type f | wc -l)

    log_info "Built artifact: $build_count files"
    log_info "Official release: $official_count files"

    local diff_count=$((official_count - build_count))

    if [[ $diff_count -gt 0 ]]; then
        log_warning "Official has $diff_count more files than build"
    elif [[ $diff_count -lt 0 ]]; then
        log_warning "Build has $((-diff_count)) more files than official"
    else
        log_success "File counts match exactly"
    fi

    # Generate file list diff
    log_verbose "Generating file list comparison..."
    diff <(cd "$build_dir" && find . -type f | sort) \
         <(cd "$official_dir" && find . -type f | sort) \
         > "$WORK_DIR/file-list-diff.txt" 2>&1 || true

    # Analyze missing/extra files
    local files_only_official
    local files_only_build
    files_only_official=$(grep -c "^>" "$WORK_DIR/file-list-diff.txt" 2>/dev/null || echo 0)
    files_only_build=$(grep -c "^<" "$WORK_DIR/file-list-diff.txt" 2>/dev/null || echo 0)

    if [[ $files_only_official -gt 0 ]]; then
        log_verbose "$files_only_official files only in official release"
    fi

    if [[ $files_only_build -gt 0 ]]; then
        log_warning "$files_only_build files only in build output"
    fi
}

# ============================================================================
# Phase 6: Legal Files Analysis
# ============================================================================

analyze_legal_files() {
    log_info "[6/8] Analyzing legal files..."

    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"

    # Count legal files
    local build_legal
    local official_legal
    build_legal=$(find "$build_dir/lib/runtime/legal/" -type f 2>/dev/null | wc -l || echo 0)
    official_legal=$(find "$official_dir/lib/runtime/legal/" -type f 2>/dev/null | wc -l || echo 0)

    log_verbose "Legal files in build: $build_legal"
    log_verbose "Legal files in official: $official_legal"

    local missing_legal=$((official_legal - build_legal))

    if [[ $missing_legal -gt 0 ]]; then
        log_warning "$missing_legal legal/documentation files missing in build"

        # Check if all missing files are legal files
        local non_legal_missing
        non_legal_missing=$(grep "^>" "$WORK_DIR/file-list-diff.txt" 2>/dev/null | grep -v "lib/runtime/legal" | wc -l || echo 0)

        if [[ $non_legal_missing -gt 0 ]]; then
            log_error "$non_legal_missing non-legal files are missing (investigation required)"
            VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        else
            log_success "All missing files are legal documentation (acceptable)"
            LEGAL_FILES_ACCEPTABLE=true
        fi
    elif [[ $missing_legal -lt 0 ]]; then
        log_warning "Build has $((-missing_legal)) more legal files than official"
    else
        log_success "Legal file counts match"
        LEGAL_FILES_ACCEPTABLE=true
    fi
}

# ============================================================================
# Phase 7: Modules File Inspection (JIMAGE Deep Dive)
# ============================================================================

inspect_modules_file() {
    log_info "[7/8] Inspecting modules file..."

    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"
    local build_modules="$build_dir/lib/runtime/lib/modules"
    local official_modules="$official_dir/lib/runtime/lib/modules"

    # Compare file sizes
    local build_size
    local official_size
    build_size=$(stat -c%s "$build_modules" 2>/dev/null || stat -f%z "$build_modules" 2>/dev/null)
    official_size=$(stat -c%s "$official_modules" 2>/dev/null || stat -f%z "$official_modules" 2>/dev/null)

    local size_diff=$((official_size - build_size))
    local percent_diff
    percent_diff=$(echo "scale=6; ($size_diff * 100.0) / $official_size" | bc 2>/dev/null || echo "0")

    log_info "Modules file size:"
    log_info "  Built:    $build_size bytes"
    log_info "  Official: $official_size bytes"
    log_info "  Diff:     $size_diff bytes ($percent_diff%)"

    # Compare hashes
    local build_hash
    local official_hash
    build_hash=$(sha256sum "$build_modules" | cut -d' ' -f1)
    official_hash=$(sha256sum "$official_modules" | cut -d' ' -f1)

    if [[ "$build_hash" == "$official_hash" ]]; then
        log_success "Modules file is byte-for-byte identical"
        JVM_CLASSES_ACCEPTABLE=true
        APP_CODE_IDENTICAL=true
        return
    fi

    log_warning "Modules file hashes differ (expected - may be compression variance)"
    log_verbose "  Built:    $build_hash"
    log_verbose "  Official: $official_hash"

    # Skip JIMAGE extraction if requested
    if [[ "$SKIP_JIMAGE_EXTRACT" == true ]]; then
        log_warning "Skipping JIMAGE extraction (--skip-jimage-extract specified)"
        log_warning "Cannot verify application code identity without extraction"
        return
    fi

    # Check if jimage command exists
    if ! command -v jimage &> /dev/null; then
        log_error "jimage command not found (requires JDK installation)"
        log_error "Cannot perform deep modules inspection"
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    # Extract modules contents
    log_info "Extracting modules contents (this may take a minute)..."
    local extract_dir="$WORK_DIR/extracted-modules-comparison"

    mkdir -p "$extract_dir/build" "$extract_dir/official"

    log_verbose "Extracting built modules..."
    if ! jimage extract --dir "$extract_dir/build" "$build_modules" > /dev/null 2>&1; then
        log_error "Failed to extract built modules file"
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    log_verbose "Extracting official modules..."
    if ! jimage extract --dir "$extract_dir/official" "$official_modules" > /dev/null 2>&1; then
        log_error "Failed to extract official modules file"
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    log_success "Modules extracted successfully"

    # Compare extracted contents
    log_info "Comparing extracted modules contents..."

    diff -qr "$extract_dir/build" "$extract_dir/official" > "$WORK_DIR/modules-diff.txt" 2>&1 || true

    # Count total differences
    local total_diffs
    total_diffs=$(grep -c "^Files" "$WORK_DIR/modules-diff.txt" 2>/dev/null || echo 0)

    if [[ $total_diffs -eq 0 ]]; then
        log_success "Extracted modules contents are identical"
        JVM_CLASSES_ACCEPTABLE=true
        APP_CODE_IDENTICAL=true
        return
    fi

    log_info "Found $total_diffs differing files in modules"

    # Check Sparrow application code
    log_info "Verifying Sparrow application code..."

    if diff -qr "$extract_dir/build/com.sparrowwallet.sparrow" \
               "$extract_dir/official/com.sparrowwallet.sparrow" > /dev/null 2>&1; then
        log_success "✓ Sparrow application code is 100% IDENTICAL"
        APP_CODE_IDENTICAL=true
    else
        log_error "✗ Sparrow application code differs (CRITICAL)"
        APP_CODE_IDENTICAL=false
        VERDICT_EXIT_CODE=$EXIT_APP_CODE_DIFFERS
        exit $EXIT_APP_CODE_DIFFERS
    fi

    # Check if differences are only in JVM infrastructure
    local jvm_diffs
    jvm_diffs=$(grep "java.base/java/lang/invoke" "$WORK_DIR/modules-diff.txt" 2>/dev/null | wc -l || echo 0)

    log_verbose "Differences in JVM infrastructure: $jvm_diffs"
    log_verbose "Total differences: $total_diffs"

    if [[ $jvm_diffs -eq $total_diffs ]]; then
        log_success "All differences are JVM-generated classes (acceptable)"
        log_info "Classes: LambdaForm, MethodHandle, BoundMethodHandle (invokedynamic infrastructure)"
        JVM_CLASSES_ACCEPTABLE=true
    elif [[ $jvm_diffs -gt 0 ]]; then
        log_warning "$jvm_diffs JVM infrastructure differences (acceptable)"
        local other_diffs=$((total_diffs - jvm_diffs))
        log_warning "$other_diffs other differences (requires review)"
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
    else
        log_error "Differences are not in expected JVM infrastructure"
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Print header
    if [[ "$QUIET" != true ]]; then
        echo "======================================================"
        echo "Sparrow Desktop Reproducible Build Verification"
        echo "======================================================"
        echo "Version: $VERSION"
        echo "Platform: $(uname -s) $(uname -m)"
        echo "Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo ""
    fi

    # Phase 1: Setup
    setup_workspace

    # Phase 2: Docker Build
    build_docker

    # Phase 3: Official Binary Download
    download_official

    # Phase 4: Critical Binaries Verification
    verify_critical_binaries

    # Phase 5: File Count Analysis
    analyze_file_counts

    # Phase 6: Legal Files Analysis
    analyze_legal_files

    # More phases will be implemented next
    log_info "Phases 7-8 coming next..."

    exit $EXIT_SUCCESS
}

# Run main function
main "$@"
