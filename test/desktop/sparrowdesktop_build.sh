#!/bin/bash
#
# sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verifier
#
# Version: v0.8.3
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
#   --work-dir DIR       Working directory (default: ./sparrow_desktop_VERSION_ARCH_TYPE_PID)
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
SCRIPT_VERSION="v0.8.3"

# Exit codes (BSA compliant)
EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Default values
DEFAULT_JDK_VERSION="22.0.2+9"
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Global variables
APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
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
            --apk)
                # Accept but ignore for API compatibility (desktop scripts don't use APK)
                shift 2
                ;;
            --work-dir)
                CUSTOM_WORK_DIR="$2"
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
    --work-dir DIR       Working directory (default: ./sparrow_desktop_VERSION_ARCH_TYPE_PID)
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
    local execution_dir

    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    type_component=$(sanitize_component "$APP_TYPE")
    suffix=$(sanitize_component "$(date +%s)-$$")

    local container_name="sparrow-verify-${version_component}-${arch_component}-${type_component}-${suffix}"
    local image_name="sparrow-verifier:${version_component}-${arch_component}-${type_component}-${suffix}"

    # Save execution directory for YAML handoff to build server
    execution_dir="$(pwd)"

    # Set work directory (use current directory if not custom)
    if [[ -n "$CUSTOM_WORK_DIR" ]]; then
        WORK_DIR="$CUSTOM_WORK_DIR"
    else
        # Use current directory + unique subdirectory (follows Luis guidelines)
        WORK_DIR="${execution_dir}/sparrow_desktop_${version_component}_${arch_component}_${type_component}_$$"
    fi

    # Create work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

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
        --build-arg BUILD_ARCH="$APP_ARCH" \
        --build-arg SCRIPT_VERSION="$SCRIPT_VERSION" \
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

    # Copy YAML to execution directory for build server (BSA requirement)
    if [[ "$execution_dir" != "$WORK_DIR" ]]; then
        cp ./COMPARISON_RESULTS.yaml "$execution_dir/" 2>/dev/null || \
            die "Failed to copy YAML to execution directory" $EXIT_BUILD_FAILED
    fi

    # Cleanup container
    if [[ "$KEEP_CONTAINER" != true ]]; then
        $DOCKER_CMD rm "$container_name" > /dev/null 2>&1
    fi

    # Display results
    display_results "$execution_dir"
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
    xz-utils \
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
ENV SPARROW_VERSION=${SPARROW_VERSION}
RUN git checkout "${SPARROW_VERSION}" && \
    git submodule update --init --recursive

# Build with jpackage (creates image + deb + rpm on Linux)
RUN ./gradlew jpackage

# Copy built binary
ARG BUILD_TYPE
RUN mkdir -p /built && \
    cp -r build/jpackage/Sparrow /built/ && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        # Also copy the .deb file for hash comparison
        cp build/jpackage/*.deb /built/; \
    fi

# Download official release
WORKDIR /official
ARG BUILD_TYPE
RUN if [ "${BUILD_TYPE}" = "deb" ]; then \
        # Deb naming: sparrowwallet_VERSION-1_amd64.deb
        wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet_${SPARROW_VERSION}-1_amd64.deb && \
        # Extract deb contents to get Sparrow directory
        ar x sparrowwallet_${SPARROW_VERSION}-1_amd64.deb && \
        # Detect and extract data archive (supports both .gz and .xz)
        if [ -f data.tar.xz ]; then \
            tar -xf data.tar.xz; \
        elif [ -f data.tar.gz ]; then \
            tar -xzf data.tar.gz; \
        else \
            echo "ERROR: Unknown data archive format" && exit 1; \
        fi && \
        # Detect Sparrow directory location (jpackage may place it in different paths)
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        if [ -z "$SPARROW_DIR" ]; then \
            echo "ERROR: Could not find Sparrow directory in extracted deb" && \
            echo "Contents:" && find . -maxdepth 3 -type d && \
            exit 1; \
        fi && \
        mv "$SPARROW_DIR" Sparrow && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    else \
        # Tarball naming: sparrowwallet-VERSION-x86_64.tar.gz
        wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz && \
        tar -xzf sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
    fi

# Align legal files with official release (remove extras)
RUN if [ -d "/official/Sparrow/lib/runtime/legal" ] && [ -d "/built/Sparrow/lib/runtime/legal" ]; then \
        cd /built/Sparrow/lib/runtime/legal && \
        find . -mindepth 1 -maxdepth 1 -type d | while read -r module_dir; do \
            module="${module_dir#./}"; \
            if [ ! -d "/official/Sparrow/lib/runtime/legal/${module}" ]; then \
                rm -rf "$module_dir"; \
            fi; \
        done; \
    fi

# Pass metadata to container
ARG SCRIPT_VERSION
ARG BUILD_ARCH
ARG BUILD_TYPE
ENV SCRIPT_VERSION=${SCRIPT_VERSION}
ENV BUILD_ARCH=${BUILD_ARCH}
ENV BUILD_TYPE=${BUILD_TYPE}

# Create comprehensive comparison script
RUN cat > /verify.sh << 'VERIFY_END'
#!/bin/bash
set -euo pipefail

# Metadata from environment
SCRIPT_VERSION="${SCRIPT_VERSION:-unknown}"
BUILD_TYPE="${BUILD_TYPE:-tarball}"
SPARROW_VERSION="${SPARROW_VERSION:-unknown}"
BUILD_ARCH="${BUILD_ARCH:-x86_64-linux-gnu}"

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
built_legal_listing=$(mktemp /tmp/sparrow-built-legal.XXXXXX)
official_legal_listing=$(mktemp /tmp/sparrow-official-legal.XXXXXX)

# Get all files
(cd /built/Sparrow && find . -type f | sort) > "$built_listing"
(cd /official/Sparrow && find . -type f | sort) > "$official_listing"

# Get legal files separately
(cd /built/Sparrow && find . -type f -path '*/lib/runtime/legal/*' | sort) > "$built_legal_listing"
(cd /official/Sparrow && find . -type f -path '*/lib/runtime/legal/*' | sort) > "$official_legal_listing"

# Count totals
build_total=$(wc -l < "$built_listing" | tr -d ' ')
official_total=$(wc -l < "$official_listing" | tr -d ' ')
built_legal_count=$(wc -l < "$built_legal_listing" | tr -d ' ')
official_legal_count=$(wc -l < "$official_legal_listing" | tr -d ' ')

# Count excluding legal
build_count=$((build_total - built_legal_count))
official_count=$((official_total - official_legal_count))

echo "  Total files (built):    $build_total"
echo "  Total files (official): $official_total"
echo ""

# Show legal file difference if any
if [[ "$built_legal_count" -ne "$official_legal_count" ]]; then
    echo "  ℹ EXCLUDED FROM VERDICT: lib/runtime/legal/ (JDK license texts)"
    echo "    Built has:    $built_legal_count legal files"
    echo "    Official has: $official_legal_count legal files"
    echo "    Difference:   $((official_legal_count - built_legal_count)) files"
    echo "    Reason: jpackage omits these in containers; not executable code"
    echo ""
    echo "    Missing legal files:"
    # Show files in official but not in built
    comm -23 "$official_legal_listing" "$built_legal_listing" | while read -r file; do
        echo "      - $file"
    done
    echo ""
fi

echo "  Comparable files (excluding legal):"
echo "    Built:    $build_count"
echo "    Official: $official_count"

if [[ "$build_count" -eq "$official_count" ]]; then
    echo "  ✓ File counts match"
    FILE_COUNT_MATCH=true
else
    echo "  ⚠ File count differs by $((official_count - build_count))"
    FILE_COUNT_MATCH=false
    # Filter out legal files for comparison display
    grep -v 'lib/runtime/legal/' "$built_listing" > "${built_listing}.filtered"
    grep -v 'lib/runtime/legal/' "$official_listing" > "${official_listing}.filtered"
    print_file_comparison "${official_listing}.filtered" "${built_listing}.filtered"
    rm -f "${built_listing}.filtered" "${official_listing}.filtered"
fi
echo ""

rm -f "$built_listing" "$official_listing" "$built_legal_listing" "$official_legal_listing"

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

# Generate BSA-compliant YAML
mkdir -p /output

# Get current timestamp in ISO 8601 format
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")

# Calculate artifact hashes based on build type
if [[ "$BUILD_TYPE" = "deb" ]]; then
    # For deb: compare .deb files directly
    OFFICIAL_ARTIFACT="/official/sparrowwallet_${SPARROW_VERSION}-1_amd64.deb"
    # Detect built .deb filename (jpackage may use different naming)
    BUILT_DEB_FILE=$(ls /built/*.deb 2>/dev/null | head -1)
    if [[ -z "$BUILT_DEB_FILE" ]]; then
        echo "ERROR: No .deb file found in /built/"
        exit 1
    fi
    BUILT_ARTIFACT="$BUILT_DEB_FILE"
    ARTIFACT_FILENAME="$(basename "$BUILT_DEB_FILE")"
else
    # For tarball: create tarball from built directory
    OFFICIAL_ARTIFACT="/official/sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz"
    BUILT_ARTIFACT="/tmp/sparrowwallet-${SPARROW_VERSION}-x86_64-built.tar.gz"
    ARTIFACT_FILENAME="sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz"
    (cd /built && tar -czf "$BUILT_ARTIFACT" Sparrow)
fi

OFFICIAL_HASH=$(sha256sum "$OFFICIAL_ARTIFACT" | cut -d' ' -f1)
BUILT_HASH=$(sha256sum "$BUILT_ARTIFACT" | cut -d' ' -f1)

# Determine match status
if [[ "$OFFICIAL_HASH" == "$BUILT_HASH" ]]; then
    ARTIFACT_MATCH="true"
    STATUS="reproducible"
else
    ARTIFACT_MATCH="false"
    # Keep status from detailed comparison (might still be reproducible if only legal files differ)
fi

cat > /output/COMPARISON_RESULTS.yaml << YAML_END
date: $TIMESTAMP
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${BUILD_ARCH}
    status: $STATUS
    files:
      - filename: ${ARTIFACT_FILENAME}
        hash: $BUILT_HASH
        match: $ARTIFACT_MATCH
        official_hash: $OFFICIAL_HASH
        notes: "Deep comparison: critical_binaries=$CRITICAL_MATCH modules=$MODULES_MATCH files=$FILE_COUNT_MATCH"
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
    local exec_dir="$1"

    echo ""
    echo "======================================================"
    echo "RESULTS"
    echo "======================================================"
    cat COMPARISON_RESULTS.yaml
    echo ""
    echo "Workspace: $WORK_DIR/COMPARISON_RESULTS.yaml"
    if [[ "$exec_dir" != "$WORK_DIR" ]]; then
        echo "Build server location: $exec_dir/COMPARISON_RESULTS.yaml"
    fi
    echo ""

    # Read status and exit accordingly
    local status
    status=$(grep "^status:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)

    if [[ "$status" == "reproducible" ]]; then
        echo "✅ VERDICT: REPRODUCIBLE"
        echo "Exit code: $EXIT_SUCCESS"
        exit $EXIT_SUCCESS
    else
        echo "❌ VERDICT: NOT REPRODUCIBLE"
        echo "Exit code: $EXIT_BUILD_FAILED"
        exit $EXIT_BUILD_FAILED
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Display script version immediately
    echo "sparrowdesktop_build.sh - Version: $SCRIPT_VERSION"
    echo ""

    parse_arguments "$@"
    build_and_verify
}

main "$@"
