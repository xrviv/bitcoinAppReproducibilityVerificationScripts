#!/bin/bash
#
# sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verifier
#
# Version: v0.15.0
#
# Description:
#   Fully containerized reproducible build verification for Sparrow Desktop.
#   All build, download, and comparison logic runs inside Docker/Podman container.
#   Host only orchestrates container and reads YAML output.
#
# Usage:
#   sparrowdesktop_build.sh --version VERSION --arch ARCH --type TYPE [OPTIONS]
#
# Required Parameters:
#   --version VERSION    Sparrow version to build (e.g., 2.5.1)
#   --arch ARCH          Target architecture (x86_64-linux-gnu)
#   --type TYPE          Artifact type (tarball|deb|rpm)
#
# Optional Parameters:
#   --binary FILE        Use provided official artifact instead of downloading
#   --work-dir DIR       Working directory (default: ./sparrow_desktop_VERSION_ARCH_TYPE_PID)
#   --no-cache           Force rebuild without Docker/Podman cache
#   --keep-container     Don't remove container after completion
#   --quiet              Suppress non-essential output
#
# Examples:
#   sparrowdesktop_build.sh --version 2.5.1 --arch x86_64-linux-gnu --type tarball
#   sparrowdesktop_build.sh --version 2.5.1 --arch x86_64-linux-gnu --type rpm --binary sparrowwallet-2.5.1-1.x86_64.rpm
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#

set -euo pipefail

SCRIPT_VERSION="v0.15.1"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

DEFAULT_JDK_VERSION="25.0.2+10"
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-}"

APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
NO_CACHE=false
KEEP_CONTAINER=false
QUIET=false
BINARY_PATH=""

# ============================================================================
# Helper Functions
# ============================================================================

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

warn() {
    echo "WARN: $1" >&2
}

detect_container_cmd() {
    if [[ -n "$DOCKER_CMD" ]]; then
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        DOCKER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    else
        die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
    fi
}

require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "Missing value for parameter: $flag" $EXIT_INVALID_PARAMS
    fi
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
                require_value "$1" "${2:-}"
                APP_VERSION="$2"
                shift 2
                ;;
            --arch)
                require_value "$1" "${2:-}"
                APP_ARCH="$2"
                shift 2
                ;;
            --type)
                require_value "$1" "${2:-}"
                APP_TYPE="$2"
                shift 2
                ;;
            --binary)
                require_value "$1" "${2:-}"
                BINARY_PATH="$2"
                shift 2
                ;;
            --apk)
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
            --work-dir)
                require_value "$1" "${2:-}"
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
                warn "Ignoring unknown parameter: $1"
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
        esac
    done

    if [[ -z "$APP_VERSION" ]]; then
        die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    fi
    if [[ -z "$APP_ARCH" ]]; then
        die "Missing required parameter: --arch" $EXIT_INVALID_PARAMS
    fi
    if [[ -z "$APP_TYPE" ]]; then
        die "Missing required parameter: --type" $EXIT_INVALID_PARAMS
    fi

    if [[ "$APP_TYPE" != "tarball" ]] && [[ "$APP_TYPE" != "deb" ]] && [[ "$APP_TYPE" != "rpm" ]]; then
        die "Invalid type: $APP_TYPE (must be tarball, deb, or rpm)" $EXIT_INVALID_PARAMS
    fi

    if [[ -n "$BINARY_PATH" && ! -f "$BINARY_PATH" ]]; then
        die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
    fi

    if [[ -n "$BINARY_PATH" ]]; then
        BINARY_PATH=$(realpath "$BINARY_PATH")
        local bname
        bname=$(basename "$BINARY_PATH")
        case "$APP_TYPE" in
            tarball) [[ "$bname" == *.tar.gz ]] || die "--binary '$bname' does not look like a tarball; expected .tar.gz for --type tarball" $EXIT_INVALID_PARAMS ;;
            deb)     [[ "$bname" == *.deb ]]    || die "--binary '$bname' does not look like a deb; expected .deb for --type deb" $EXIT_INVALID_PARAMS ;;
            rpm)     [[ "$bname" == *.rpm ]]    || die "--binary '$bname' does not look like an rpm; expected .rpm for --type rpm" $EXIT_INVALID_PARAMS ;;
        esac
    fi
}

show_help() {
    cat << 'EOF'
sparrowdesktop_build.sh - Sparrow Desktop Reproducible Build Verification

USAGE:
    sparrowdesktop_build.sh --version VERSION --arch ARCH --type TYPE [OPTIONS]

REQUIRED PARAMETERS:
    --version VERSION    Sparrow version to build (e.g., 2.5.1)
    --arch ARCH          Target architecture (x86_64-linux-gnu)
    --type TYPE          Artifact type (tarball, deb, or rpm)

OPTIONAL PARAMETERS:
    --binary FILE        Use provided official artifact instead of downloading
    --work-dir DIR       Working directory (default: ./sparrow_desktop_VERSION_ARCH_TYPE_PID)
    --no-cache           Force rebuild without Docker/Podman cache
    --keep-container     Don't remove container after completion
    --quiet              Suppress non-essential output

EXAMPLES:
    sparrowdesktop_build.sh --version 2.5.1 --arch x86_64-linux-gnu --type tarball
    sparrowdesktop_build.sh --version 2.5.1 --arch x86_64-linux-gnu --type deb --no-cache
    sparrowdesktop_build.sh --version 2.5.1 --arch x86_64-linux-gnu --type rpm --binary sparrowwallet-2.5.1-1.x86_64.rpm

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
    local version_component arch_component type_component suffix execution_dir

    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    type_component=$(sanitize_component "$APP_TYPE")
    suffix=$(sanitize_component "$(date +%s)-$$")

    local container_name="sparrow-verify-${version_component}-${arch_component}-${type_component}-${suffix}"
    local image_name="sparrow-verifier:${version_component}-${arch_component}-${type_component}-${suffix}"

    execution_dir="$(pwd)"

    if [[ -n "$CUSTOM_WORK_DIR" ]]; then
        WORK_DIR="$CUSTOM_WORK_DIR"
    else
        WORK_DIR="${execution_dir}/sparrow_desktop_${version_component}_${arch_component}_${type_component}_$$"
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Prepare official binary in build context.
    # Always create sparrow_official_binary so the Dockerfile COPY always succeeds.
    # If --binary provided, populate it; otherwise leave it empty (wget path runs).
    if [[ -n "$BINARY_PATH" ]]; then
        cp "$BINARY_PATH" "${WORK_DIR}/sparrow_official_binary"
        BINARY_PROVIDED_FLAG="1"
        [[ "$QUIET" != true ]] && echo "Using provided binary: $(basename "$BINARY_PATH")"
    else
        touch "${WORK_DIR}/sparrow_official_binary"
        BINARY_PROVIDED_FLAG="0"
    fi

    [[ "$QUIET" != true ]] && echo "======================================================"
    [[ "$QUIET" != true ]] && echo "Sparrow Desktop v$APP_VERSION - Containerized Build"
    [[ "$QUIET" != true ]] && echo "======================================================"
    [[ "$QUIET" != true ]] && echo ""

    create_verify_script
    create_dockerfile

    [[ "$QUIET" != true ]] && echo "Building and verifying in container..."
    [[ "$QUIET" != true ]] && echo ""

    local cache_flag=""
    [[ "$NO_CACHE" == true ]] && cache_flag="--no-cache"

    if ! $DOCKER_CMD build $cache_flag \
        --build-arg SPARROW_VERSION="$APP_VERSION" \
        --build-arg BUILD_TYPE="$APP_TYPE" \
        --build-arg BUILD_ARCH="$APP_ARCH" \
        --build-arg SCRIPT_VERSION="$SCRIPT_VERSION" \
        --build-arg BINARY_PROVIDED="$BINARY_PROVIDED_FLAG" \
        -t "$image_name" . 2>&1 | tee build.log; then
        echo ""
        die "Container build failed" $EXIT_BUILD_FAILED
    fi

    [[ "$QUIET" != true ]] && echo ""
    [[ "$QUIET" != true ]] && echo "Extracting results..."

    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
        $DOCKER_CMD rm -f "$container_name" > /dev/null 2>&1
    fi

    $DOCKER_CMD create --name "$container_name" "$image_name" > /dev/null
    $DOCKER_CMD cp "$container_name:/output/COMPARISON_RESULTS.yaml" ./ 2>/dev/null || \
        die "Failed to extract YAML results" $EXIT_BUILD_FAILED

    if [[ "$execution_dir" != "$WORK_DIR" ]]; then
        cp ./COMPARISON_RESULTS.yaml "$execution_dir/" 2>/dev/null || \
            die "Failed to copy YAML to execution directory" $EXIT_BUILD_FAILED
    fi

    if [[ "$KEEP_CONTAINER" != true ]]; then
        $DOCKER_CMD rm "$container_name" > /dev/null 2>&1
    fi

    display_results "$execution_dir"
}

create_verify_script() {
    cat > verify.sh << 'VERIFY_END'
#!/bin/bash
set -euo pipefail

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

    local i=0 j=0
    local official_total=${#official_files[@]}
    local built_total=${#built_files[@]}

    echo ""
    echo "  File comparison (Official >> Built) — differences only"
    printf "    %-55s | %-55s\n" "Official" "Built"
    printf "    %-55s | %-55s\n" "--------" "-----"

    while (( i < official_total || j < built_total )); do
        local official="${official_files[i]-}"
        local built="${built_files[j]-}"
        local left="" right=""

        if [[ -n "${official:-}" && -n "${built:-}" ]]; then
            if [[ "$official" == "$built" ]]; then
                ((++i)); ((++j)); continue
            fi
            if [[ "$official" < "$built" ]]; then
                left="$official"; right="(missing)"; ((++i))
            else
                left="(missing)"; right="$built"; ((++j))
            fi
        elif [[ -n "${official:-}" ]]; then
            left="$official"; right="(missing)"; ((++i))
        else
            left="(missing)"; right="$built"; ((++j))
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
            echo "  Comparing extracted class files..."
            diff_output=$(mktemp /tmp/sparrow-modules-diff.XXXXXX)

            diff_exit=0
            diff -r /extracted/built /extracted/official > "$diff_output" 2>&1 || diff_exit=$?

            if [[ $diff_exit -gt 1 ]]; then
                echo "  ✗ ERROR: diff failed (exit $diff_exit)"
                rm -f "$diff_output"
                MODULES_MATCH=false
                MODULES_DIFF_COUNT=-1
                exit 1
            fi

            MODULES_DIFF_COUNT=$(awk '/^Files .* differ$/ || /^Only in / {count++} END {print count+0}' "$diff_output")

            if [[ "$MODULES_DIFF_COUNT" -eq 0 ]]; then
                echo "  ✓ Deep inspection: All classes IDENTICAL"
                echo "  ℹ Hash difference due to compression/ordering only"
                MODULES_MATCH=true
                rm -f "$diff_output"
            else
                echo "  ✗ Deep inspection: $MODULES_DIFF_COUNT class differences"
                echo ""
                echo "  Differing files (first 20):"
                grep -E '^Files .* differ$|^Only in ' "$diff_output" | head -20 | while read -r line; do
                    f=$(echo "$line" | sed 's/Files \/extracted\/built\//  - /' | sed 's/ and.*//' | sed 's/^Only in /  + Only in /')
                    echo "$f"
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

(cd /built/Sparrow && find . \( -type f -o -type l \) | sort) > "$built_listing"
(cd /official/Sparrow && find . \( -type f -o -type l \) | sort) > "$official_listing"
(cd /built/Sparrow && find . \( -type f -o -type l \) -path '*/lib/runtime/legal/*' | sort) > "$built_legal_listing"
(cd /official/Sparrow && find . \( -type f -o -type l \) -path '*/lib/runtime/legal/*' | sort) > "$official_legal_listing"

build_total=$(wc -l < "$built_listing" | tr -d ' ')
official_total=$(wc -l < "$official_listing" | tr -d ' ')
built_legal_count=$(wc -l < "$built_legal_listing" | tr -d ' ')
official_legal_count=$(wc -l < "$official_legal_listing" | tr -d ' ')

build_count=$((build_total - built_legal_count))
official_count=$((official_total - official_legal_count))

echo "  Total files (built):    $build_total"
echo "  Total files (official): $official_total"
echo ""

if [[ "$built_legal_count" -ne "$official_legal_count" ]]; then
    echo "  ℹ EXCLUDED FROM VERDICT: lib/runtime/legal/ (JDK license texts)"
    echo "    Built has:    $built_legal_count legal files"
    echo "    Official has: $official_legal_count legal files"
    echo "    Difference:   $((official_legal_count - built_legal_count)) files"
    echo "    Reason: jpackage omits these in containers; not executable code"
    echo ""
    echo "    Missing legal files:"
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
    grep -v 'lib/runtime/legal/' "$built_listing" > "${built_listing}.filtered"
    grep -v 'lib/runtime/legal/' "$official_listing" > "${official_listing}.filtered"
    print_file_comparison "${official_listing}.filtered" "${built_listing}.filtered"
    rm -f "${built_listing}.filtered" "${official_listing}.filtered"
fi
echo ""

rm -f "$built_listing" "$official_listing" "$built_legal_listing" "$official_legal_listing"

# Phase 4: File-by-file hash verification
echo "Phase 4: File-by-file Verification"
echo "------------------------------------------------------"

full_listing=$(mktemp /tmp/sparrow-full-list.XXXXXX)
(cd /official/Sparrow && find . \( -type f -o -type l \) -print) | sort > "$full_listing"
total_files=$(wc -l < "$full_listing" | tr -d ' ')

file_index=0
match_files=0
diff_files=0

while IFS= read -r rel_path; do
    file_index=$((file_index + 1))
    official_file="/official/Sparrow/${rel_path#./}"
    built_file="/built/Sparrow/${rel_path#./}"

    built_hash="(missing)"
    official_hash="(missing)"
    status_label="(missing)"

    if [[ -f "$built_file" ]]; then
        built_hash=$(sha256sum "$built_file" | cut -d' ' -f1)
    fi
    if [[ -f "$official_file" ]]; then
        official_hash=$(sha256sum "$official_file" | cut -d' ' -f1)
    fi

    if [[ -f "$built_file" && -f "$official_file" ]]; then
        if [[ "$built_hash" == "$official_hash" ]]; then
            status_label="✓ MATCH"
            match_files=$((match_files + 1))
        else
            status_label="⚠ DIFFER"
            diff_files=$((diff_files + 1))
        fi
    else
        status_label="⚠ MISSING"
        diff_files=$((diff_files + 1))
    fi

    printf "  %3d/%-3d: %s\n" "$file_index" "$total_files" "${rel_path#./}"
    echo "          Built:    $built_hash"
    echo "          Official: $official_hash"
    echo "          Status:   $status_label"
    echo ""
done < "$full_listing"

rm -f "$full_listing"

FILE_HASH_MATCH=true
if [[ "$diff_files" -gt 0 ]]; then
    FILE_HASH_MATCH=false
fi

# Verdict
if [[ "$CRITICAL_MATCH" == "true" ]] && [[ "$MODULES_MATCH" == "true" ]] && [[ "$FILE_COUNT_MATCH" == "true" ]] && [[ "$FILE_HASH_MATCH" == "true" ]]; then
    STATUS="reproducible"
    VERDICT="✅ REPRODUCIBLE"
else
    STATUS="not_reproducible"
    VERDICT="❌ NOT REPRODUCIBLE"

    [[ "$CRITICAL_MATCH" != "true" ]] && echo "  Reason: Critical binaries differ"
    [[ "$MODULES_MATCH" != "true" ]]  && echo "  Reason: Module classes differ"
    [[ "$FILE_COUNT_MATCH" != "true" ]] && echo "  Reason: File count mismatch ($build_count built vs $official_count official)"
    [[ "$FILE_HASH_MATCH" != "true" ]]  && echo "  Reason: $diff_files file(s) have different content (Phase 4)"
fi

mkdir -p /output

cat > /output/COMPARISON_RESULTS.yaml << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${STATUS}
notes: |
  Built from source at tag ${SPARROW_VERSION} using ./gradlew jpackage inside Ubuntu 22.04
  with Eclipse Temurin JDK 25.0.2+10. lib/runtime/legal/ files excluded from comparison
  (jpackage omits these in containers; not executable code). RPM archive hash may differ
  due to embedded build metadata; verdict is based on file-by-file comparison of extracted
  contents. critical_binaries=${CRITICAL_MATCH} modules=${MODULES_MATCH} file_count=${FILE_COUNT_MATCH} file_hashes=${FILE_HASH_MATCH}
YAML_END

echo "========================================================"
echo "FINAL VERDICT: $VERDICT"
echo "========================================================"
echo ""
VERIFY_END
    chmod +x verify.sh
}

create_dockerfile() {
    cat > Dockerfile << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wget \
    git \
    tar \
    xz-utils \
    zstd \
    rpm \
    cpio \
    fakeroot \
    binutils \
    diffutils \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

# Install JDK (Eclipse Temurin 25.0.2+10 — matches Sparrow 2.4.0+ official builds)
WORKDIR /opt
RUN wget -q https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.2%2B10/OpenJDK25U-jdk_x64_linux_hotspot_25.0.2_10.tar.gz && \
    tar -xzf OpenJDK25U-jdk_x64_linux_hotspot_25.0.2_10.tar.gz && \
    rm OpenJDK25U-jdk_x64_linux_hotspot_25.0.2_10.tar.gz

ENV JAVA_HOME=/opt/jdk-25.0.2+10
ENV PATH=${JAVA_HOME}/bin:${PATH}

# Clone and build Sparrow
WORKDIR /build
RUN git clone --recursive https://github.com/sparrowwallet/sparrow.git

WORKDIR /build/sparrow
ARG SPARROW_VERSION
ENV SPARROW_VERSION=${SPARROW_VERSION}
RUN git checkout "${SPARROW_VERSION}" && \
    git submodule update --init --recursive

# Build (produces Sparrow/ image dir, .deb, and .rpm in build/jpackage/)
ARG BUILD_TYPE
RUN ./gradlew jpackage && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        cd build/jpackage && \
        DEB_FILE=$(ls *.deb | head -1) && \
        echo "Repackaging $DEB_FILE: ZSTD -> XZ compression" && \
        ar x "$DEB_FILE" && \
        unzstd control.tar.zst && \
        unzstd data.tar.zst && \
        xz -c control.tar > control.tar.xz && \
        xz -c data.tar > data.tar.xz && \
        rm "$DEB_FILE" && \
        ar cr "$DEB_FILE" debian-binary control.tar.xz data.tar.xz && \
        rm -f control.tar* data.tar* debian-binary && \
        echo "Repackaging complete: $DEB_FILE"; \
    fi

# Extract built artifact to /built/Sparrow/
ARG BUILD_TYPE
RUN mkdir -p /built && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        cp build/jpackage/*.deb /built/ && \
        cd /built && \
        DEB_FILE=$(ls *.deb | head -1) && \
        ar x "$DEB_FILE" && \
        tar -xf data.tar.xz && \
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        if [ -z "$SPARROW_DIR" ]; then \
            echo "ERROR: Could not find Sparrow directory in repackaged deb" && exit 1; \
        fi && \
        mv "$SPARROW_DIR" Sparrow && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    elif [ "${BUILD_TYPE}" = "rpm" ]; then \
        RPM_FILE=$(ls /build/sparrow/build/jpackage/*.rpm 2>/dev/null | head -1) && \
        if [ -z "$RPM_FILE" ]; then \
            echo "ERROR: No .rpm file found in build/jpackage/" && exit 1; \
        fi && \
        cp "$RPM_FILE" /built/ && \
        mkdir -p /tmp/rpm_extract_built && \
        (cd /tmp/rpm_extract_built && rpm2cpio /built/$(basename "$RPM_FILE") | cpio -idmv 2>/dev/null) && \
        SPARROW_DIR=$(find /tmp/rpm_extract_built -maxdepth 6 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        if [ -z "$SPARROW_DIR" ]; then \
            echo "ERROR: Could not find Sparrow directory in built rpm" && exit 1; \
        fi && \
        cp -r "$SPARROW_DIR" /built/Sparrow; \
    else \
        cp -r build/jpackage/Sparrow /built/; \
    fi

# Obtain official release: use --binary if provided, otherwise download from GitHub
WORKDIR /official
ARG BUILD_TYPE
ARG SPARROW_VERSION
ARG BINARY_PROVIDED=0
COPY sparrow_official_binary /tmp/sparrow_official_binary

RUN if [ "${BUILD_TYPE}" = "deb" ]; then \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet_${SPARROW_VERSION}-1_amd64.deb; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet_${SPARROW_VERSION}-1_amd64.deb; \
        fi && \
        ar x sparrowwallet_${SPARROW_VERSION}-1_amd64.deb && \
        if [ -f data.tar.xz ]; then \
            tar -xf data.tar.xz; \
        elif [ -f data.tar.gz ]; then \
            tar -xzf data.tar.gz; \
        else \
            echo "ERROR: Unknown data archive format in official deb" && exit 1; \
        fi && \
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        if [ -z "$SPARROW_DIR" ]; then \
            echo "ERROR: Could not find Sparrow directory in official deb" && \
            echo "Contents:" && find . -maxdepth 3 -type d && \
            exit 1; \
        fi && \
        mv "$SPARROW_DIR" Sparrow && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    elif [ "${BUILD_TYPE}" = "rpm" ]; then \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm; \
        fi && \
        mkdir -p /tmp/rpm_extract_official && \
        (cd /tmp/rpm_extract_official && rpm2cpio /official/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm | cpio -idmv 2>/dev/null) && \
        SPARROW_DIR=$(find /tmp/rpm_extract_official -maxdepth 6 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        if [ -z "$SPARROW_DIR" ]; then \
            echo "ERROR: Could not find Sparrow directory in official rpm" && exit 1; \
        fi && \
        cp -r "$SPARROW_DIR" /official/Sparrow; \
    else \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
        fi && \
        tar -xzf sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
    fi

# Align legal files: remove extra legal modules from built that are absent in official
RUN if [ -d "/official/Sparrow/lib/runtime/legal" ] && [ -d "/built/Sparrow/lib/runtime/legal" ]; then \
        cd /built/Sparrow/lib/runtime/legal && \
        find . -mindepth 1 -maxdepth 1 -type d | while read -r module_dir; do \
            module="${module_dir#./}"; \
            if [ ! -d "/official/Sparrow/lib/runtime/legal/${module}" ]; then \
                rm -rf "$module_dir"; \
            fi; \
        done; \
    fi

ARG SCRIPT_VERSION
ARG BUILD_ARCH
ARG BUILD_TYPE
ENV SCRIPT_VERSION=${SCRIPT_VERSION}
ENV BUILD_ARCH=${BUILD_ARCH}
ENV BUILD_TYPE=${BUILD_TYPE}

COPY verify.sh /verify.sh
RUN chmod +x /verify.sh
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

    local verdict
    verdict=$(grep "^verdict:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)

    if [[ "$verdict" == "reproducible" ]]; then
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
    echo "sparrowdesktop_build.sh - Version: $SCRIPT_VERSION"
    echo ""

    parse_arguments "$@"
    detect_container_cmd
    build_and_verify
}

main "$@"
