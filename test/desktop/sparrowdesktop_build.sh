#!/bin/bash
#
# sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verifier
#
# Version: v0.8.1
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
SCRIPT_VERSION="v0.8.1"

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

sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input#-}"
    input="${input%-}"
    if [[ -z "$input" ]]; then
        input="na"
    fi
    echo "$input"
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
    local version_component
    local arch_component
    local type_component
    local suffix
    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    type_component=$(sanitize_component "$APP_TYPE")
    suffix=$(sanitize_component "$(date +%s)-$$")

    local container_name="sparrow-verify-${version_component}-${arch_component}-${type_component}-${suffix}"
    local image_name="sparrow-verifier:${version_component}-${arch_component}-${type_component}-${suffix}"

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

    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
        $DOCKER_CMD rm -f "$container_name" > /dev/null 2>&1
    fi

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

print_file_comparison() {
    local official_list="$1"
    local built_list="$2"
    local diff_count=0

    mapfile -t official_files < "$official_list"
    mapfile -t built_files < "$built_list"

    local i=0
    local j=0
    local official_total=${#official_files[@]}
    local built_total=${#built_files[@]}

    echo ""
    echo "  File comparison (Official >> Built) — differences only"
    printf "    %-55s | %-55s\n" "Official" "Built"
    printf "    %-55s | %-55s\n" "--------" "-----"

    while (( i < official_total || j < built_total )); do
        local official="${official_files[i]-}"
        local built="${built_files[j]-}"
        local left=""
        local right=""

        if [[ -n "${official:-}" && -n "${built:-}" ]]; then
            if [[ "$official" == "$built" ]]; then
                ((++i))
                ((++j))
                continue
            fi

            if [[ "$official" < "$built" ]]; then
                left="$official"
                right="(missing)"
                ((++i))
            else
                left="(missing)"
                right="$built"
                ((++j))
            fi
        elif [[ -n "${official:-}" ]]; then
            left="$official"
            right="(missing)"
            ((++i))
        else
            left="(missing)"
            right="$built"
            ((++j))
        fi

        ((++diff_count))
        printf "    %-55s | %-55s\n" "$left" "$right"
    done

    if (( diff_count == 0 )); then
        echo "    (No file differences detected)"
    fi
}

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
echo ""

modules_built_hash=$(sha256sum /built/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)
modules_official_hash=$(sha256sum /official/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)

echo "  lib/runtime/lib/modules (side-by-side):"
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │ Built:    $modules_built_hash │"
echo "  │ Official: $modules_official_hash │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""

if [[ "$modules_built_hash" == "$modules_official_hash" ]]; then
    echo "  ✓ Modules file: IDENTICAL"
    MODULES_MATCH=true
    MODULES_DIFF_COUNT=0
else
    echo "  ⚠ Modules file hash differs - performing deep inspection..."
    echo ""
    
    # Extract modules
    mkdir -p /extracted/built /extracted/official
    
    echo "  Extracting built modules..."
    if ! jimage extract --dir /extracted/built /built/Sparrow/lib/runtime/lib/modules 2>&1; then
        echo "  ✗ ERROR: Failed to extract built modules"
        MODULES_MATCH=false
        MODULES_DIFF_COUNT=-1
    else
        echo "  ✓ Built modules extracted"
        
        echo "  Extracting official modules..."
        if ! jimage extract --dir /extracted/official /official/Sparrow/lib/runtime/lib/modules 2>&1; then
            echo "  ✗ ERROR: Failed to extract official modules"
            MODULES_MATCH=false
            MODULES_DIFF_COUNT=-1
        else
            echo "  ✓ Official modules extracted"
            echo ""
            
            # Compare extracted contents without killing Docker on the expected diff exit code
            echo "  Comparing extracted class files..."
            diff_output=$(mktemp /tmp/sparrow-modules-diff.XXXXXX)

            if ! diff -r /extracted/built /extracted/official > "$diff_output" 2>&1; then
                diff_exit=$?
                if [[ $diff_exit -gt 1 ]]; then
                    echo "  ✗ ERROR: diff failed during module comparison (exit $diff_exit)"
                    rm -f "$diff_output"
                    MODULES_MATCH=false
                    MODULES_DIFF_COUNT=-1
                    exit 1
                fi
            fi

            MODULES_DIFF_COUNT=$(awk '/^Files .* differ$/ {count++} END {print count+0}' "$diff_output")

            if [[ "$MODULES_DIFF_COUNT" -eq 0 ]]; then
                echo "  ✓ Deep inspection: All classes IDENTICAL"
                echo "  ℹ Hash difference due to compression/ordering only"
                MODULES_MATCH=true
                rm -f "$diff_output"
            else
                echo "  ✗ Deep inspection: $MODULES_DIFF_COUNT class files differ"
                echo ""
                echo "  Differing files (first 20):"
                grep "^Files .* differ$" "$diff_output" | head -20 | while read line; do
                    file=$(echo "$line" | sed 's/Files \/extracted\/built\//  - /' | sed 's/ and.*//')
                    echo "$file"
                done
                MODULES_MATCH=false
                rm -f "$diff_output"
            fi
        fi
    fi
fi
echo ""

# Phase 3: File Count Analysis
echo "Phase 3: File Count Analysis"
echo "------------------------------------------------------"

built_listing=$(mktemp /tmp/sparrow-built-list.XXXXXX)
official_listing=$(mktemp /tmp/sparrow-official-list.XXXXXX)

(cd /built/Sparrow && find . -type f | sort) > "$built_listing"
(cd /official/Sparrow && find . -type f | sort) > "$official_listing"

build_count=$(wc -l < "$built_listing" | tr -d ' ')
official_count=$(wc -l < "$official_listing" | tr -d ' ')

echo "  Built files:    $build_count"
echo "  Official files: $official_count"

if [[ "$build_count" -eq "$official_count" ]]; then
    echo "  ✓ File counts match"
    FILE_COUNT_MATCH=true
else
    echo "  ⚠ File count differs by $((official_count - build_count))"
    FILE_COUNT_MATCH=false
    print_file_comparison "$official_listing" "$built_listing"
fi
echo ""

rm -f "$built_listing" "$official_listing"

# Determine final verdict
if [[ "$CRITICAL_MATCH" == "true" ]] && [[ "$MODULES_MATCH" == "true" ]] && [[ "$FILE_COUNT_MATCH" == "true" ]]; then
    STATUS="reproducible"
    VERDICT="✅ REPRODUCIBLE"
else
    STATUS="not_reproducible"
    VERDICT="❌ NOT REPRODUCIBLE"
    
    # Explain why not reproducible
    if [[ "$CRITICAL_MATCH" != "true" ]]; then
        echo "  Reason: Critical binaries differ"
    fi
    if [[ "$MODULES_MATCH" != "true" ]]; then
        echo "  Reason: Module classes differ"
    fi
    if [[ "$FILE_COUNT_MATCH" != "true" ]]; then
        echo "  Reason: File count mismatch ($build_count built vs $official_count official)"
    fi
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
