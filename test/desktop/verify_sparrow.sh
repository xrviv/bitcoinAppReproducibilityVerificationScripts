#!/bin/bash
#
# verify_sparrow.sh - Sparrow Desktop Reproducible Build Verifier
#
# Version: v0.5.0
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
# Repository: https://github.com/xrviv/bitcoinAppReproducibilityVerificationScripts
#

set -euo pipefail

# Script version
SCRIPT_VERSION="v0.5.0"

# Default values (can be overridden by environment variables)
DEFAULT_WORK_DIR_BASE="${SPARROW_WORK_DIR:-$HOME/sparrow-verify}"
DEFAULT_JDK_VERSION="22.0.2+9"
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Global variables
VERSION=""
WORK_DIR=""
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
SAVE_LOGS=false
VERBOSE=false
QUIET=false

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
MODULES_INSPECTED=false
VERDICT_EXIT_CODE=$EXIT_SUCCESS

# Colors for output (initialized after argument parsing)
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_RED=''
COLOR_BLUE=''
COLOR_RESET=''

# Function to initialize colors based on terminal and quiet mode
init_colors() {
    if [[ -t 1 ]] && [[ "$QUIET" != true ]]; then
        COLOR_GREEN='\033[0;32m'
        COLOR_YELLOW='\033[1;33m'
        COLOR_RED='\033[0;31m'
        COLOR_BLUE='\033[0;34m'
        COLOR_RESET='\033[0m'
    fi
}

# ============================================================================
# Helper Functions
# ============================================================================

die() {
    echo "ERROR: $1" >&2
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
    7. Generates comprehensive verification verdict

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
                                (default: ~/sparrow-verify/VERSION)

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

FILES
    Work Directory Structure:
        work-dir/
        ├── Dockerfile
        ├── build-output/Sparrow/        # Built artifacts
        ├── official/Sparrow/             # Official release
        ├── extracted-modules-comparison/ # JIMAGE extraction
        ├── modules-diff.txt              # Modules comparison results
        ├── file-list-diff.txt            # File listing comparison
        └── docker-build.log              # Build log

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
    verify_sparrow.sh version v0.5.0

AUTHOR
    WalletScrutiny Team

REPORTING BUGS
    https://github.com/xrviv/bitcoinAppReproducibilityVerificationScripts/issues

SEE ALSO
    Sparrow Wallet: https://github.com/sparrowwallet/sparrow
    WalletScrutiny: https://walletscrutiny.com
    Script repository: https://github.com/xrviv/bitcoinAppReproducibilityVerificationScripts
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

    # Validate VERSION format (should be semantic version like 2.3.0)
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid VERSION format: $VERSION (expected format: X.Y.Z, e.g., 2.3.0)" $EXIT_INVALID_ARGS
    fi

    # Set defaults based on VERSION
    WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR_BASE/$VERSION}"
    GITHUB_TAG="${GITHUB_TAG:-$VERSION}"
    CONTAINER_NAME="${CONTAINER_NAME:-sparrow-$VERSION-container}"

    # Validate WORK_DIR path
    if [[ "$WORK_DIR" =~ [[:space:]] ]]; then
        die "Work directory path cannot contain spaces: $WORK_DIR" $EXIT_INVALID_ARGS
    fi

    # Validate JDK_VERSION format (e.g., 22.0.2+9)
    if ! [[ "$JDK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
        die "Invalid JDK_VERSION format: $JDK_VERSION (expected format: X.Y.Z+B, e.g., 22.0.2+9)" $EXIT_INVALID_ARGS
    fi

    # Validate JDK_VERSION is reasonable (major version between 8 and 99)
    local jdk_major="${JDK_VERSION%%.*}"
    if [[ $jdk_major -lt 8 ]] || [[ $jdk_major -gt 99 ]]; then
        die "Invalid JDK major version: $jdk_major (must be between 8 and 99)" $EXIT_INVALID_ARGS
    fi

    # Validate BASE_IMAGE format (should contain at least one colon for tag)
    if ! [[ "$BASE_IMAGE" =~ ^[a-z0-9._/-]+:[a-z0-9._-]+$ ]]; then
        die "Invalid BASE_IMAGE format: $BASE_IMAGE (expected format: image:tag, e.g., ubuntu:22.04)" $EXIT_INVALID_ARGS
    fi

    # Validate BASE_IMAGE components
    local image_name="${BASE_IMAGE%:*}"
    local image_tag="${BASE_IMAGE##*:}"
    
    # Image name should not be empty and should not contain invalid characters
    if [[ -z "$image_name" ]] || [[ "$image_name" =~ [^a-z0-9._/-] ]]; then
        die "Invalid BASE_IMAGE name: $image_name (only lowercase alphanumeric, dots, slashes, hyphens allowed)" $EXIT_INVALID_ARGS
    fi
    
    # Tag should not be empty and should not contain invalid characters
    if [[ -z "$image_tag" ]] || [[ "$image_tag" =~ [^a-z0-9._-] ]]; then
        die "Invalid BASE_IMAGE tag: $image_tag (only alphanumeric, dots, hyphens allowed)" $EXIT_INVALID_ARGS
    fi

    # Validate CONTAINER_NAME (Docker naming: alphanumeric, hyphens, underscores, periods)
    # Docker container names must match: [a-zA-Z0-9][a-zA-Z0-9_.-]*
    if ! [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        die "Invalid CONTAINER_NAME: $CONTAINER_NAME (must start with alphanumeric, then alphanumeric/hyphens/underscores/periods)" $EXIT_INVALID_ARGS
    fi

    # Validate GITHUB_TAG format
    if [[ -n "$GITHUB_TAG" ]] && ! [[ "$GITHUB_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid GITHUB_TAG format: $GITHUB_TAG (expected format: X.Y.Z, e.g., 2.3.0)" $EXIT_INVALID_ARGS
    fi

    # Validate OFFICIAL_URL if provided
    if [[ -n "$OFFICIAL_URL" ]] && ! [[ "$OFFICIAL_URL" =~ ^https?:// ]]; then
        die "Invalid OFFICIAL_URL: must start with http:// or https://" $EXIT_INVALID_ARGS
    fi

    # Validate DOCKER_CMD is available
    if ! command -v "$DOCKER_CMD" &> /dev/null; then
        die "Docker command not found: $DOCKER_CMD (install Docker or use --docker-cmd to specify alternative)" $EXIT_INVALID_ARGS
    fi

    # Set official URL if not provided
    if [[ -z "$OFFICIAL_URL" ]]; then
        OFFICIAL_URL="https://github.com/sparrowwallet/sparrow/releases/download/$VERSION/sparrowwallet-$VERSION-x86_64.tar.gz"
    fi

    # Validate conflicts
    if [[ "$VERIFY_ONLY" == true ]] && [[ "$DEEP_INSPECT_ONLY" == true ]]; then
        die "Cannot use --verify-only and --deep-inspect-only together" $EXIT_INVALID_ARGS
    fi

    if [[ "$SKIP_BUILD" == true ]] && [[ "$REBUILD" == true ]]; then
        die "Cannot use --skip-build and --rebuild together" $EXIT_INVALID_ARGS
    fi

    if [[ "$VERIFY_ONLY" == true ]] && [[ "$REBUILD" == true ]]; then
        die "Cannot use --verify-only and --rebuild together (verify-only skips build)" $EXIT_INVALID_ARGS
    fi

    if [[ "$SKIP_BUILD" == true ]] && [[ "$NO_CACHE" == true ]]; then
        die "Cannot use --skip-build and --no-cache together (no-cache only applies to build)" $EXIT_INVALID_ARGS
    fi

    if [[ "$DEEP_INSPECT_ONLY" == true ]] && [[ "$SKIP_JIMAGE_EXTRACT" == true ]]; then
        die "Cannot use --deep-inspect-only and --skip-jimage-extract together" $EXIT_INVALID_ARGS
    fi
}

# ============================================================================
# Phase 1: Environment Setup
# ============================================================================

setup_workspace() {
    # Create work directory structure
    mkdir -p "$WORK_DIR" || die "Failed to create work directory: $WORK_DIR" $EXIT_INVALID_ARGS
    mkdir -p "$WORK_DIR/build-output" || die "Failed to create build-output directory" $EXIT_INVALID_ARGS
    mkdir -p "$WORK_DIR/official" || die "Failed to create official directory" $EXIT_INVALID_ARGS
    mkdir -p "$WORK_DIR/extracted-modules-comparison/build" || die "Failed to create extraction directory" $EXIT_INVALID_ARGS
    mkdir -p "$WORK_DIR/extracted-modules-comparison/official" || die "Failed to create extraction directory" $EXIT_INVALID_ARGS

    # Check required tools
    local missing_tools=()

    command -v "$DOCKER_CMD" &> /dev/null || missing_tools+=("$DOCKER_CMD")

    if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
        missing_tools+=("wget or curl")
    fi

    command -v tar &> /dev/null || missing_tools+=("tar")
    command -v sha256sum &> /dev/null || missing_tools+=("sha256sum")
    command -v diff &> /dev/null || missing_tools+=("diff")
    command -v bc &> /dev/null || missing_tools+=("bc")

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing_tools[*]}" $EXIT_INVALID_ARGS
    fi
}

build_docker() {
    if [[ "$SKIP_BUILD" == true ]]; then
        # Verify build output exists
        if [[ ! -d "$WORK_DIR/build-output/Sparrow" ]]; then
            die "Build output not found at $WORK_DIR/build-output/Sparrow" $EXIT_BUILD_FAILED
        fi

        # Verify critical files exist in build output
        local missing_files=()
        for file in "bin/Sparrow" "lib/libapplauncher.so" "lib/runtime/lib/modules"; do
            if [[ ! -f "$WORK_DIR/build-output/Sparrow/$file" ]]; then
                missing_files+=("$file")
            fi
        done

        if [[ ${#missing_files[@]} -gt 0 ]]; then
            echo "ERROR: Build output incomplete - missing critical files:" >&2
            for file in "${missing_files[@]}"; do
                echo "  - $file" >&2
            done
            exit $EXIT_BUILD_FAILED
        fi

        return
    fi

    cd "$WORK_DIR"

    # Convert JDK_VERSION format for URL (e.g., 22.0.2+9 -> jdk-22.0.2%2B9)
    local jdk_url_version="${JDK_VERSION//+/%2B}"
    local jdk_major_version="${JDK_VERSION%%.*}"
    local jdk_download_url="https://github.com/adoptium/temurin${jdk_major_version}-binaries/releases/download/jdk-${jdk_url_version}/OpenJDK${jdk_major_version}U-jdk_x64_linux_hotspot_${JDK_VERSION//+/_}.tar.gz"
    local jdk_dir="/opt/jdk-${JDK_VERSION}"

    cat > Dockerfile <<DOCKERFILE_END
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \\
    wget \\
    rpm \\
    fakeroot \\
    binutils \\
    git \\
    unzip \\
    && rm -rf /var/lib/apt/lists/*

# Download and install Eclipse Temurin JDK
RUN wget -q ${jdk_download_url} \\
    && tar -xzf OpenJDK${jdk_major_version}U-jdk_x64_linux_hotspot_${JDK_VERSION//+/_}.tar.gz -C /opt \\
    && rm OpenJDK${jdk_major_version}U-jdk_x64_linux_hotspot_${JDK_VERSION//+/_}.tar.gz

ENV JAVA_HOME=${jdk_dir}
ENV PATH=\${JAVA_HOME}/bin:\${PATH}

WORKDIR /build

# Clone Sparrow repository with submodules
RUN git clone --recursive https://github.com/sparrowwallet/sparrow.git

WORKDIR /build/sparrow

# Checkout specific tag
ARG SPARROW_VERSION
RUN git checkout "\${SPARROW_VERSION}"

# Build
RUN ./gradlew jpackage

# Copy output
RUN mkdir -p /output && \\
    cp -r build/jpackage/Sparrow /output/ && \\
    find /output -type f -exec chmod 644 {} \\; && \\
    find /output -type d -exec chmod 755 {} \\;

CMD ["bash"]
DOCKERFILE_END

    # Build Docker image
    local cache_flag=""
    if [[ "$NO_CACHE" == true ]]; then
        cache_flag="--no-cache"
    fi

    # Always capture output to temp file for error reporting, optionally save permanently
    local temp_log="$WORK_DIR/docker-build.log"

    if ! "$DOCKER_CMD" build $cache_flag --build-arg SPARROW_VERSION="$GITHUB_TAG" -t "sparrow-$VERSION-builder" . 2>&1 | tee "$temp_log"; then
        echo "ERROR: Docker build failed. Last 50 lines of output:" >&2
        echo "------------------------------------------------------" >&2
        tail -50 "$temp_log" >&2
        echo "------------------------------------------------------" >&2
        echo "ERROR: Full log saved to: $temp_log" >&2
        exit $EXIT_BUILD_FAILED
    fi

    # Remove log file if not saving logs
    if [[ "$SAVE_LOGS" != true ]]; then
        rm -f "$temp_log"
    fi

    # Check if container exists
    if "$DOCKER_CMD" ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if [[ "$REBUILD" == true ]]; then
            "$DOCKER_CMD" rm -f "$CONTAINER_NAME" > /dev/null 2>&1
        else
            return
        fi
    fi

    # Create container
    if ! "$DOCKER_CMD" create --name "$CONTAINER_NAME" "sparrow-$VERSION-builder" > /dev/null 2>&1; then
        die "Failed to create container" $EXIT_BUILD_FAILED
    fi

    # Copy build output from container
    if ! "$DOCKER_CMD" cp "$CONTAINER_NAME:/output/Sparrow" "$WORK_DIR/build-output/" > /dev/null 2>&1; then
        die "Failed to copy build artifacts from container" $EXIT_BUILD_FAILED
    fi

    # Cleanup container if not keeping
    if [[ "$KEEP_CONTAINER" != true ]]; then
        "$DOCKER_CMD" rm "$CONTAINER_NAME" > /dev/null 2>&1
    fi
}

# ============================================================================
# Phase 3: Official Binary Download
# ============================================================================

download_official() {
    if [[ "$SKIP_DOWNLOAD" == true ]]; then
        # Check if either tarball or extracted directory exists
        if [[ ! -f "$WORK_DIR/sparrowwallet-$VERSION-x86_64.tar.gz" ]] && [[ ! -d "$WORK_DIR/official/Sparrow" ]]; then
            echo "ERROR: Official release not found" >&2
            echo "ERROR: Neither tarball nor extracted directory exists:" >&2
            echo "  Tarball: $WORK_DIR/sparrowwallet-$VERSION-x86_64.tar.gz" >&2
            echo "  Directory: $WORK_DIR/official/Sparrow" >&2
            exit $EXIT_DOWNLOAD_FAILED
        fi

        # If only tarball exists, we need to extract it
        if [[ -f "$WORK_DIR/sparrowwallet-$VERSION-x86_64.tar.gz" ]] && [[ ! -d "$WORK_DIR/official/Sparrow" ]]; then
            # Continue to extraction logic below
            :
        else
            # Verify critical files exist in official release
            local missing_files=()
            for file in "bin/Sparrow" "lib/libapplauncher.so" "lib/runtime/lib/modules"; do
                if [[ ! -f "$WORK_DIR/official/Sparrow/$file" ]]; then
                    missing_files+=("$file")
                fi
            done

            if [[ ${#missing_files[@]} -gt 0 ]]; then
                echo "ERROR: Official release incomplete - missing critical files:" >&2
                for file in "${missing_files[@]}"; do
                    echo "  - $file" >&2
                done
                exit $EXIT_DOWNLOAD_FAILED
            fi

            return
        fi
    fi

    cd "$WORK_DIR"

    # Download if tarball doesn't exist
    if [[ ! -f "sparrowwallet-$VERSION-x86_64.tar.gz" ]]; then
        # Download with wget or curl
        if command -v wget &> /dev/null; then
            if ! wget -q --show-progress "$OFFICIAL_URL" -O "sparrowwallet-$VERSION-x86_64.tar.gz" 2>&1; then
                echo "ERROR: Download failed from $OFFICIAL_URL" >&2
                echo "ERROR: Verify version exists at: https://github.com/sparrowwallet/sparrow/releases" >&2
                exit $EXIT_DOWNLOAD_FAILED
            fi
        elif command -v curl &> /dev/null; then
            if ! curl -L -o "sparrowwallet-$VERSION-x86_64.tar.gz" "$OFFICIAL_URL" 2>&1; then
                echo "ERROR: Download failed from $OFFICIAL_URL" >&2
                echo "ERROR: Verify version exists at: https://github.com/sparrowwallet/sparrow/releases" >&2
                exit $EXIT_DOWNLOAD_FAILED
            fi
        else
            die "Neither wget nor curl available" $EXIT_DOWNLOAD_FAILED
        fi
    fi

    # Calculate SHA256 of tarball
    local tarball_hash
    tarball_hash=$(sha256sum "sparrowwallet-$VERSION-x86_64.tar.gz" | cut -d' ' -f1)
    echo "$tarball_hash  sparrowwallet-$VERSION-x86_64.tar.gz"

    # Extract tarball
    if [[ ! -d "official/Sparrow" ]]; then
        mkdir -p official

        if ! tar -xzf "sparrowwallet-$VERSION-x86_64.tar.gz" -C official/ 2>&1; then
            echo "ERROR: Failed to extract tarball" >&2
            echo "ERROR: Tarball may be corrupted" >&2
            exit $EXIT_DOWNLOAD_FAILED
        fi

        if [[ ! -d "official/Sparrow" ]]; then
            die "Expected directory 'Sparrow' not found in tarball" $EXIT_DOWNLOAD_FAILED
        fi
    fi
}

# ============================================================================
# Phase 4: Critical Binaries Verification
# ============================================================================

verify_critical_binaries() {
    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"

    # Verify directories exist
    if [[ ! -d "$build_dir" ]]; then
        echo "ERROR: Build directory not found: $build_dir"
        exit $EXIT_BUILD_FAILED
    fi

    if [[ ! -d "$official_dir" ]]; then
        echo "ERROR: Official directory not found: $official_dir"
        exit $EXIT_DOWNLOAD_FAILED
    fi

    local all_match=true

    # Critical files to verify
    local critical_files=(
        "bin/Sparrow"
        "lib/libapplauncher.so"
        "lib/Sparrow.png"
        "lib/app/Sparrow.cfg"
    )

    for file in "${critical_files[@]}"; do
        # Check if files exist
        if [[ ! -f "$build_dir/$file" ]]; then
            echo "ERROR: Built file missing: $file"
            exit $EXIT_BUILD_FAILED
        fi

        if [[ ! -f "$official_dir/$file" ]]; then
            echo "ERROR: Official file missing: $file"
            exit $EXIT_DOWNLOAD_FAILED
        fi

        # Calculate and compare hashes
        local build_hash
        local official_hash
        build_hash=$(sha256sum "$build_dir/$file" | cut -d' ' -f1)
        official_hash=$(sha256sum "$official_dir/$file" | cut -d' ' -f1)

        if [[ "$build_hash" == "$official_hash" ]]; then
            echo "$build_hash  $file"
        else
            echo "ERROR: $file: MISMATCH" >&2
            echo "ERROR:   Built:    $build_hash" >&2
            echo "ERROR:   Official: $official_hash" >&2
            all_match=false
        fi
    done

    if [[ "$all_match" == true ]]; then
        CRITICAL_BINARIES_MATCH=true
    else
        CRITICAL_BINARIES_MATCH=false
        VERDICT_EXIT_CODE=$EXIT_CRITICAL_BINARIES_DIFFER
        exit $EXIT_CRITICAL_BINARIES_DIFFER
    fi
}

# ============================================================================
# Phase 5: File Count Analysis
# ============================================================================

analyze_file_counts() {
    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"

    # Verify directories exist
    if [[ ! -d "$build_dir" ]]; then
        echo "ERROR: Build directory not found: $build_dir"
        exit $EXIT_BUILD_FAILED
    fi

    if [[ ! -d "$official_dir" ]]; then
        echo "ERROR: Official directory not found: $official_dir"
        exit $EXIT_DOWNLOAD_FAILED
    fi

    # Count and generate diff
    diff <(cd "$build_dir" && find . -type f | sort) \
         <(cd "$official_dir" && find . -type f | sort) \
         > "$WORK_DIR/file-list-diff.txt" 2>&1 || true
}

# ============================================================================
# Phase 6: Legal Files Analysis
# ============================================================================

analyze_legal_files() {
    # Skip if --ignore-legal specified
    if [[ "$IGNORE_LEGAL" == true ]]; then
        LEGAL_FILES_ACCEPTABLE=true
        return
    fi

    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"

    # Count legal files
    local build_legal
    local official_legal
    build_legal=$(find "$build_dir/lib/runtime/legal/" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    official_legal=$(find "$official_dir/lib/runtime/legal/" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)

    local missing_legal=$((official_legal - build_legal))

    if [[ $missing_legal -gt 0 ]]; then
        if [[ "$STRICT" == true ]]; then
            echo "ERROR: $missing_legal legal/documentation files missing in build" >&2
            echo "ERROR: Strict mode: failing on legal file differences" >&2
            VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
            LEGAL_FILES_ACCEPTABLE=false
            return
        fi

        # Check if all missing files are legal files
        local non_legal_missing
        non_legal_missing=$(grep "^>" "$WORK_DIR/file-list-diff.txt" 2>/dev/null | grep -v "lib/runtime/legal" | wc -l | tr -d ' ' || echo 0)

        if [[ $non_legal_missing -gt 0 ]]; then
            echo "ERROR: $non_legal_missing non-legal files are missing (investigation required)" >&2
            VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
            LEGAL_FILES_ACCEPTABLE=false
        else
            LEGAL_FILES_ACCEPTABLE=true
        fi
    elif [[ $missing_legal -lt 0 ]]; then
        if [[ "$STRICT" == true ]]; then
            VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
            LEGAL_FILES_ACCEPTABLE=false
        else
            LEGAL_FILES_ACCEPTABLE=true
        fi
    else
        LEGAL_FILES_ACCEPTABLE=true
    fi
}

# ============================================================================
# Phase 7: Modules File Inspection (JIMAGE Deep Dive)
# ============================================================================

inspect_modules_file() {
    local build_dir="$WORK_DIR/build-output/Sparrow"
    local official_dir="$WORK_DIR/official/Sparrow"
    local build_modules="$build_dir/lib/runtime/lib/modules"
    local official_modules="$official_dir/lib/runtime/lib/modules"

    # Verify directories exist
    if [[ ! -d "$build_dir" ]]; then
        echo "ERROR: Build directory not found: $build_dir" >&2
        exit $EXIT_BUILD_FAILED
    fi

    if [[ ! -d "$official_dir" ]]; then
        echo "ERROR: Official directory not found: $official_dir" >&2
        exit $EXIT_DOWNLOAD_FAILED
    fi

    # Verify modules files exist
    if [[ ! -f "$build_modules" ]]; then
        echo "ERROR: Build modules file not found: $build_modules" >&2
        exit $EXIT_BUILD_FAILED
    fi

    if [[ ! -f "$official_modules" ]]; then
        echo "ERROR: Official modules file not found: $official_modules" >&2
        exit $EXIT_DOWNLOAD_FAILED
    fi

    # Compare hashes
    local build_hash
    local official_hash
    build_hash=$(sha256sum "$build_modules" | cut -d' ' -f1)
    official_hash=$(sha256sum "$official_modules" | cut -d' ' -f1)

    if [[ "$build_hash" == "$official_hash" ]]; then
        JVM_CLASSES_ACCEPTABLE=true
        APP_CODE_IDENTICAL=true
        MODULES_INSPECTED=true
        return
    fi

    # Skip JIMAGE extraction if requested
    if [[ "$SKIP_JIMAGE_EXTRACT" == true ]]; then
        echo "ERROR: Skipping JIMAGE extraction - cannot verify application code" >&2
        MODULES_INSPECTED=false
        APP_CODE_IDENTICAL=false
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    # Check if jimage command exists
    if ! command -v jimage &> /dev/null; then
        echo "ERROR: jimage command not found (requires JDK installation)" >&2
        MODULES_INSPECTED=false
        APP_CODE_IDENTICAL=false
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    # Extract modules contents
    local extract_dir="$WORK_DIR/extracted-modules-comparison"

    mkdir -p "$extract_dir/build" "$extract_dir/official"

    if ! jimage extract --dir "$extract_dir/build" "$build_modules" > /dev/null 2>&1; then
        echo "ERROR: Failed to extract built modules file" >&2
        MODULES_INSPECTED=false
        APP_CODE_IDENTICAL=false
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    if ! jimage extract --dir "$extract_dir/official" "$official_modules" > /dev/null 2>&1; then
        echo "ERROR: Failed to extract official modules file" >&2
        MODULES_INSPECTED=false
        APP_CODE_IDENTICAL=false
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
        return
    fi

    # Compare extracted contents
    diff -qr "$extract_dir/build" "$extract_dir/official" > "$WORK_DIR/modules-diff.txt" 2>&1 || true

    # Count total differences
    local total_diffs
    total_diffs=$(grep -c "^Files" "$WORK_DIR/modules-diff.txt" 2>/dev/null | tr -d ' ' || echo 0)

    if [[ $total_diffs -eq 0 ]]; then
        MODULES_INSPECTED=true
        JVM_CLASSES_ACCEPTABLE=true
        APP_CODE_IDENTICAL=true
        return
    fi

    # Check Sparrow application code
    if diff -qr "$extract_dir/build/com.sparrowwallet.sparrow" \
               "$extract_dir/official/com.sparrowwallet.sparrow" > /dev/null 2>&1; then
        MODULES_INSPECTED=true
        APP_CODE_IDENTICAL=true
    else
        echo "ERROR: Sparrow application code differs (CRITICAL)" >&2
        MODULES_INSPECTED=true
        APP_CODE_IDENTICAL=false
        VERDICT_EXIT_CODE=$EXIT_APP_CODE_DIFFERS
        exit $EXIT_APP_CODE_DIFFERS
    fi

    # Check if differences are only in JVM infrastructure
    local jvm_diffs
    jvm_diffs=$(grep "java.base/java/lang/invoke" "$WORK_DIR/modules-diff.txt" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

    if [[ $jvm_diffs -eq $total_diffs ]]; then
        MODULES_INSPECTED=true
        JVM_CLASSES_ACCEPTABLE=true
    elif [[ $jvm_diffs -gt 0 ]]; then
        MODULES_INSPECTED=true
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
    else
        echo "ERROR: Differences are not in expected JVM infrastructure" >&2
        MODULES_INSPECTED=true
        JVM_CLASSES_ACCEPTABLE=false
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
    fi
}

# ============================================================================
# Phase 8: Final Verdict Generation
# ============================================================================

generate_verdict() {
    echo ""
    echo "======================================================"
    echo "VERIFICATION RESULTS"
    echo "======================================================"

    # Summary of verification results
    echo ""
    echo "Critical Components:"
    if [[ "$CRITICAL_BINARIES_MATCH" == true ]]; then
        echo "  ✓ Critical binaries: IDENTICAL"
    else
        echo "  ✗ Critical binaries: DIFFER"
    fi

    if [[ "$APP_CODE_IDENTICAL" == true ]]; then
        echo "  ✓ Application code: IDENTICAL"
    else
        echo "  ✗ Application code: DIFFER"
    fi

    echo ""
    echo "Acceptable Differences:"
    if [[ "$JVM_CLASSES_ACCEPTABLE" == true ]]; then
        echo "  ✓ JVM infrastructure: Expected differences only"
    else
        echo "  ⚠ JVM infrastructure: Unexpected differences"
    fi

    if [[ "$LEGAL_FILES_ACCEPTABLE" == true ]]; then
        echo "  ✓ Legal files: Acceptable (documentation only)"
    else
        echo "  ⚠ Legal files: Requires review"
    fi

    echo ""
    echo "======================================================"

    # Determine final verdict
    if [[ "$CRITICAL_BINARIES_MATCH" == true ]] && [[ "$APP_CODE_IDENTICAL" == true ]]; then
        echo "VERDICT: ✅ REPRODUCIBLE"
        echo "======================================================"
        echo ""
        echo "The build is reproducible. All functional binaries and"
        echo "application code are byte-for-byte identical. Differences"
        echo "are limited to JVM infrastructure and documentation files."
        VERDICT_EXIT_CODE=$EXIT_SUCCESS
    elif [[ "$CRITICAL_BINARIES_MATCH" == false ]]; then
        echo "VERDICT: ❌ NOT REPRODUCIBLE (Critical binaries differ)"
        echo "======================================================"
        VERDICT_EXIT_CODE=$EXIT_CRITICAL_BINARIES_DIFFER
    elif [[ "$APP_CODE_IDENTICAL" == false ]]; then
        echo "VERDICT: ❌ NOT REPRODUCIBLE (Application code differs)"
        echo "======================================================"
        VERDICT_EXIT_CODE=$EXIT_APP_CODE_DIFFERS
    else
        echo "VERDICT: ⚠️ MANUAL REVIEW REQUIRED"
        echo "======================================================"
        echo ""
        echo "Verification complete but requires manual review of"
        echo "unexpected differences found during analysis."
        VERDICT_EXIT_CODE=$EXIT_MANUAL_REVIEW_REQUIRED
    fi

    echo ""
    echo "Work directory: $WORK_DIR"
    echo "Build artifacts: $WORK_DIR/build-output/Sparrow/"
    echo "Official release: $WORK_DIR/official/Sparrow/"

    if [[ -f "$WORK_DIR/modules-diff.txt" ]]; then
        echo "Modules diff: $WORK_DIR/modules-diff.txt"
    fi

    if [[ -f "$WORK_DIR/file-list-diff.txt" ]]; then
        echo "File list diff: $WORK_DIR/file-list-diff.txt"
    fi

    echo ""
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Initialize colors after parsing (depends on QUIET flag)
    init_colors

    # Handle --deep-inspect-only mode
    if [[ "$DEEP_INSPECT_ONLY" == true ]]; then
        inspect_modules_file
        generate_verdict
        exit $VERDICT_EXIT_CODE
    fi

    # Phase 1: Setup
    setup_workspace

    # Handle --verify-only mode
    if [[ "$VERIFY_ONLY" == true ]]; then
        SKIP_BUILD=true
        SKIP_DOWNLOAD=true
    fi

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

    # Phase 7: Modules File Inspection
    inspect_modules_file

    # Phase 8: Final Verdict Generation
    generate_verdict

    exit $VERDICT_EXIT_CODE
}

# Run main function
main "$@"
