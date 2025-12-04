#!/bin/bash
#
# sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verifier
#
# Version: v0.8.0
#
# Description:
#   Fully containerized reproducible build verification for Sparrow Desktop.
#   All build, download, and comparison logic runs inside Docker container.
#   Host only orchestrates container and reads YAML output.
#
# Usage:
#   sparrowdesktop_build.sh --version VERSION --arch ARCH --type TYPE [OPTIONS]
#
# Required Parameters:
#   --version VERSION    Sparrow version to build (e.g., 2.3.0)
#   --arch ARCH          Target architecture (x86_64-linux-gnu)
#   --type TYPE          Artifact type (tarball|deb)
#
# Optional Parameters:
#   --work-dir DIR       Working directory (default: ~/sparrow-verify/VERSION)
#   --no-cache           Force rebuild without Docker cache
#   --keep-container     Don't remove container after completion
#   --quiet              Suppress non-essential output
#
# Examples:
#   sparrowdesktop_build.sh --version 2.3.0 --arch x86_64-linux-gnu --type tarball
#   sparrowdesktop_build.sh --version 2.3.0 --arch x86_64-linux-gnu --type tarball --no-cache
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#

set -euo pipefail

# Script version
SCRIPT_VERSION="v0.8.0"

# Exit codes (BSA compliant)
EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Default values
DEFAULT_WORK_DIR_BASE="${SPARROW_WORK_DIR:-$HOME/sparrow-verify}"
DEFAULT_JDK_VERSION="22.0.2+9"
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Global variables
APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
JDK_VERSION="$DEFAULT_JDK_VERSION"
BASE_IMAGE="$DEFAULT_BASE_IMAGE"
NO_CACHE=false
KEEP_CONTAINER=false
QUIET=false

# ============================================================================
# Helper Functions
# ============================================================================

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION --arch ARCH --type TYPE [OPTIONS]"
        echo "Run with --help for more information"
        exit $EXIT_INVALID_PARAMS
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                APP_VERSION="$2"
                shift 2
                ;;
            --arch)
                APP_ARCH="$2"
                shift 2
                ;;
            --type)
                APP_TYPE="$2"
                shift 2
                ;;
            --work-dir)
                WORK_DIR="$2"
                shift 2
                ;;
            --no-cache)
                NO_CACHE=true
                shift
                ;;
            --keep-container)
                KEEP_CONTAINER=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --help)
                show_help
                ;;
            *)
                die "Unknown option: $1" $EXIT_INVALID_PARAMS
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$APP_VERSION" ]]; then
        die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    fi
    if [[ -z "$APP_ARCH" ]]; then
        die "Missing required parameter: --arch" $EXIT_INVALID_PARAMS
    fi
    if [[ -z "$APP_TYPE" ]]; then
        die "Missing required parameter: --type" $EXIT_INVALID_PARAMS
    fi

    # Validate type
    if [[ "$APP_TYPE" != "tarball" ]] && [[ "$APP_TYPE" != "deb" ]]; then
        die "Invalid type: $APP_TYPE (must be tarball or deb)" $EXIT_INVALID_PARAMS
    fi

    # Set work directory
    if [[ -z "$WORK_DIR" ]]; then
        WORK_DIR="$DEFAULT_WORK_DIR_BASE/$APP_VERSION"
    fi
}

show_help() {
    cat << 'EOF'
sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verification

USAGE:
    sparrowdesktop_build.sh --version VERSION --arch ARCH --type TYPE [OPTIONS]

REQUIRED PARAMETERS:
    --version VERSION    Sparrow version to build (e.g., 2.3.0)
    --arch ARCH          Target architecture (x86_64-linux-gnu)
    --type TYPE          Artifact type (tarball or deb)

OPTIONAL PARAMETERS:
    --work-dir DIR       Working directory (default: ~/sparrow-verify/VERSION)
    --no-cache           Force rebuild without Docker cache
    --keep-container     Don't remove container after completion
    --quiet              Suppress non-essential output

EXAMPLES:
    sparrowdesktop_build.sh --version 2.3.0 --arch x86_64-linux-gnu --type tarball
    sparrowdesktop_build.sh --version 2.3.0 --arch x86_64-linux-gnu --type tarball --no-cache

EXIT CODES (BSA Compliant):
    0 - Reproducible (success)
    1 - Build failed OR not reproducible
    2 - Invalid parameters

OUTPUT:
    COMPARISON_RESULTS.yaml - Machine-readable verification results

EOF
    exit 0
}

# ============================================================================
# Main Build and Verification
# ============================================================================

build_and_verify() {
    local container_name="sparrow-verify-$APP_VERSION"
    local image_name="sparrow-verifier:$APP_VERSION"

    # Create work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    [[ "$QUIET" != true ]] && echo "sparrowdesktop_build.sh script version: $SCRIPT_VERSION"
    [[ "$QUIET" != true ]] && echo ""
    [[ "$QUIET" != true ]] && echo "======================================================"
    [[ "$QUIET" != true ]] && echo "Sparrow Desktop v$APP_VERSION - Containerized Build"
    [[ "$QUIET" != true ]] && echo "======================================================"
    [[ "$QUIET" != true ]] && echo ""

    # Create Dockerfile with embedded verification script
    create_dockerfile

    # Build Docker image
    [[ "$QUIET" != true ]] && echo "Building and verifying in container..."
    [[ "$QUIET" != true ]] && echo ""

    local cache_flag=""
    [[ "$NO_CACHE" == true ]] && cache_flag="--no-cache"

    if ! $DOCKER_CMD build $cache_flag \
        --build-arg SPARROW_VERSION="$APP_VERSION" \
        --build-arg BUILD_TYPE="$APP_TYPE" \
        -t "$image_name" . 2>&1 | tee build.log; then
        echo ""
        die "Container build failed" $EXIT_BUILD_FAILED
    fi

    # Extract results
    [[ "$QUIET" != true ]] && echo ""
    [[ "$QUIET" != true ]] && echo "Extracting results..."

    $DOCKER_CMD create --name "$container_name" "$image_name" > /dev/null
    $DOCKER_CMD cp "$container_name:/output/COMPARISON_RESULTS.yaml" ./ 2>/dev/null || \
        die "Failed to extract YAML results" $EXIT_BUILD_FAILED

    # Cleanup container
    if [[ "$KEEP_CONTAINER" != true ]]; then
        $DOCKER_CMD rm "$container_name" > /dev/null 2>&1
    fi

    # Display results
    display_results
}

create_dockerfile() {
    cat > Dockerfile << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    git \
    tar \
    rpm \
    fakeroot \
    binutils \
    diffutils \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

# Install JDK
WORKDIR /opt
RUN wget -q https://github.com/adoptium/temurin22-binaries/releases/download/jdk-22.0.2%2B9/OpenJDK22U-jdk_x64_linux_hotspot_22.0.2_9.tar.gz && \
    tar -xzf OpenJDK22U-jdk_x64_linux_hotspot_22.0.2_9.tar.gz && \
    rm OpenJDK22U-jdk_x64_linux_hotspot_22.0.2_9.tar.gz

ENV JAVA_HOME=/opt/jdk-22.0.2+9
ENV PATH=${JAVA_HOME}/bin:${PATH}

# Clone and build Sparrow
WORKDIR /build
RUN git clone --recursive https://github.com/sparrowwallet/sparrow.git

WORKDIR /build/sparrow
ARG SPARROW_VERSION
RUN git checkout "${SPARROW_VERSION}" && \
    git submodule update --init --recursive

ARG BUILD_TYPE
RUN if [ "${BUILD_TYPE}" = "deb" ]; then \
        ./gradlew jpackageDeb; \
    else \
        ./gradlew jpackage; \
    fi

# Copy built binary
RUN mkdir -p /built && \
    cp -r build/jpackage/Sparrow /built/

# Download official release
WORKDIR /official
RUN wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz && \
    tar -xzf sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz

# Create comprehensive comparison script
RUN cat > /verify.sh << 'VERIFY_END'
#!/bin/bash
set -euo pipefail

echo "========================================================"
echo "VERIFICATION PHASE"
echo "========================================================"
echo ""

# Phase 1: Critical Binaries
echo "Phase 1: Critical Binaries Comparison"
echo "------------------------------------------------------"

CRITICAL_MATCH=true
for file in bin/Sparrow lib/libapplauncher.so lib/Sparrow.png lib/app/Sparrow.cfg; do
    built_hash=$(sha256sum /built/Sparrow/$file 2>/dev/null | cut -d' ' -f1)
    official_hash=$(sha256sum /official/Sparrow/$file 2>/dev/null | cut -d' ' -f1)
    
    echo "  $file:"
    echo "    Built:    $built_hash"
    echo "    Official: $official_hash"
    
    if [[ "$built_hash" != "$official_hash" ]]; then
        echo "    Status:   ✗ MISMATCH"
        CRITICAL_MATCH=false
    else
        echo "    Status:   ✓ MATCH"
    fi
    echo ""
done

# Phase 2: Modules File Deep Inspection
echo "Phase 2: Modules File Deep Inspection (jimage)"
echo "------------------------------------------------------"

modules_built_hash=$(sha256sum /built/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)
modules_official_hash=$(sha256sum /official/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)

echo "  lib/runtime/lib/modules:"
echo "    Built:    $modules_built_hash"
echo "    Official: $modules_official_hash"
echo ""

if [[ "$modules_built_hash" == "$modules_official_hash" ]]; then
    echo "  ✓ Modules file: IDENTICAL"
    MODULES_MATCH=true
    MODULES_DIFF_COUNT=0
else
    echo "  ⚠ Modules file hash differs - performing deep inspection..."
    
    # Extract modules
    mkdir -p /extracted/built /extracted/official
    jimage extract --dir /extracted/built /built/Sparrow/lib/runtime/lib/modules > /dev/null 2>&1
    jimage extract --dir /extracted/official /official/Sparrow/lib/runtime/lib/modules > /dev/null 2>&1
    
    # Compare extracted contents
    MODULES_DIFF_COUNT=$(diff -r /extracted/built /extracted/official 2>/dev/null | grep -c "^Files .* differ$" | tr -d ' \n' || echo 0)
    
    if [[ $MODULES_DIFF_COUNT -eq 0 ]]; then
        echo "  ✓ Deep inspection: All classes IDENTICAL"
        echo "  ℹ Hash difference due to compression/ordering only"
        MODULES_MATCH=true
    else
        echo "  ✗ Deep inspection: $MODULES_DIFF_COUNT class files differ"
        echo ""
        echo "  Differing files (first 20):"
        diff -r /extracted/built /extracted/official 2>/dev/null | grep "^Files .* differ$" | head -20 | while read line; do
            file=$(echo "$line" | sed 's/Files \/extracted\/built\//  - /' | sed 's/ and.*//')
            echo "$file"
        done
        MODULES_MATCH=false
    fi
fi
echo ""

# Phase 3: File Count Analysis
echo "Phase 3: File Count Analysis"
echo "------------------------------------------------------"

build_count=$(find /built/Sparrow -type f | wc -l)
official_count=$(find /official/Sparrow -type f | wc -l)

echo "  Built files:    $build_count"
echo "  Official files: $official_count"

if [[ $build_count -eq $official_count ]]; then
    echo "  ✓ File counts match"
    FILE_COUNT_MATCH=true
else
    echo "  ⚠ File count differs by $((official_count - build_count))"
    FILE_COUNT_MATCH=false
fi
echo ""

# Determine final verdict
if [[ "$CRITICAL_MATCH" == "true" ]] && [[ "$MODULES_MATCH" == "true" ]]; then
    STATUS="reproducible"
    VERDICT="✅ REPRODUCIBLE"
else
    STATUS="not_reproducible"
    VERDICT="❌ NOT REPRODUCIBLE"
fi

# Generate YAML
mkdir -p /output
cat > /output/COMPARISON_RESULTS.yaml << YAML_END
status: $STATUS
build_type: tarball
critical_binaries_match: $CRITICAL_MATCH
modules_match: $MODULES_MATCH
modules_diff_count: $MODULES_DIFF_COUNT
file_count_match: $FILE_COUNT_MATCH
built_file_count: $build_count
official_file_count: $official_count
YAML_END

echo "========================================================"
echo "FINAL VERDICT: $VERDICT"
echo "========================================================"
echo ""

VERIFY_END

RUN chmod +x /verify.sh

# Run verification
RUN /verify.sh

CMD ["cat", "/output/COMPARISON_RESULTS.yaml"]
DOCKERFILE_END
}

display_results() {
    echo ""
    echo "======================================================"
    echo "RESULTS"
    echo "======================================================"
    cat COMPARISON_RESULTS.yaml
    echo ""
    echo "Full results: $WORK_DIR/COMPARISON_RESULTS.yaml"
    echo ""

    # Read status and exit accordingly
    local status
    status=$(grep "^status:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)
    
    if [[ "$status" == "reproducible" ]]; then
        echo "✅ VERDICT: REPRODUCIBLE"
        exit $EXIT_SUCCESS
    else
        echo "❌ VERDICT: NOT REPRODUCIBLE"
        exit $EXIT_BUILD_FAILED
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    parse_arguments "$@"
    build_and_verify
}

main "$@"
