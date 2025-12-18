#!/usr/bin/env bash
# ==============================================================================
# bisq1desktop_build.sh - Bisq 1 Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.4
# Organization:  WalletScrutiny.com
# Last Modified: 2025-12-18
# Project:       https://github.com/bisq-network/bisq
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/desktop/bisq1/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and package comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Downloads official Bisq .deb releases from GitHub
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using Gradle + jpackage
# - Extracts and compares .class file hashes between official and built packages
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Documents differences and generates detailed reproducibility assessment

set -euo pipefail

# Script metadata
SCRIPT_VERSION="v0.3.4"
SCRIPT_NAME="bisq1desktop_build.sh"
APP_NAME="Bisq 1"
APP_ID="bisq1"
REPO_URL="https://github.com/bisq-network/bisq"
DEFAULT_VERSION="1.9.21"

# Exit codes (BSA compliant)
EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Parameters
BISQ_VERSION=""
BISQ_ARCH=""
BISQ_TYPE=""

# Directories
WORK_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Docker
IMAGE_NAME=""
CONTAINER_ID=""

# Styling
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Die function
die() {
    local message="$1"
    local exit_code="${2:-$EXIT_BUILD_FAILED}"
    log_error "$message"
    exit "$exit_code"
}

# Cleanup function
cleanup_on_exit() {
    # Use CONTAINER_NAME (the actual variable that gets assigned)
    if [[ -n "${CONTAINER_NAME:-}" ]]; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Clean temporary Dockerfile
    rm -f "$SCRIPT_DIR/.dockerfile-bisq-temp" "$SCRIPT_DIR/verify-container-bisq.sh" 2>/dev/null || true
}

trap cleanup_on_exit EXIT INT TERM

# Sanitize component for Docker names
sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input##-}"
    input="${input%%-}"
    [[ -z "$input" ]] && input="na"
    echo "$input"
}

# Usage
usage() {
    cat << EOF
Bisq 1 Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> --arch <arch> --type <type>

Required Parameters:
  --version <version>    Bisq version to verify (e.g., 1.9.21, 1.9.20)
  --arch <arch>          Target architecture
                         Supported: x86_64-linux-gnu
  --type <type>          Package type
                         Supported: deb

Optional Parameters:
  --help                 Show this help message
  --no-cache             Force fresh Docker build (no cache)
  --keep-container       Keep container after build for inspection

Examples:
  $(basename "$0") --version 1.9.21 --arch x86_64-linux-gnu --type deb
  $(basename "$0") --version 1.9.20 --arch x86_64-linux-gnu --type deb --no-cache

Requirements:
  - Docker installed and running
  - Internet connection for downloading sources and official releases
  - Approximately 4GB disk space for build
  - 20-40 minutes build time

Output:
  - Exit code 0: Build is reproducible
  - Exit code 1: Build differs or verification failed
  - Exit code 2: Invalid parameters
  - COMPARISON_RESULTS.yaml: Machine-readable comparison results

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# Parse parameters
NO_CACHE=false
KEEP_CONTAINER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --version)
            [[ -z "${2:-}" ]] && die "Error: --version requires an argument" "$EXIT_INVALID_PARAMS"
            BISQ_VERSION="$2"
            shift 2
            ;;
        --arch)
            [[ -z "${2:-}" ]] && die "Error: --arch requires an argument" "$EXIT_INVALID_PARAMS"
            BISQ_ARCH="$2"
            shift 2
            ;;
        --type)
            [[ -z "${2:-}" ]] && die "Error: --type requires an argument" "$EXIT_INVALID_PARAMS"
            BISQ_TYPE="$2"
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
        *)
            log_error "Unknown parameter: $1"
            usage
            exit "$EXIT_INVALID_PARAMS"
            ;;
    esac
done

# Validate required parameters
if [[ -z "$BISQ_VERSION" ]] || [[ -z "$BISQ_ARCH" ]] || [[ -z "$BISQ_TYPE" ]]; then
    log_error "Missing required parameters"
    usage
    exit "$EXIT_INVALID_PARAMS"
fi

# Validate architecture (accept both x86_64-linux and x86_64-linux-gnu)
case "$BISQ_ARCH" in
    x86_64-linux|x86_64-linux-gnu)
        # Normalize to x86_64-linux-gnu internally
        BISQ_ARCH="x86_64-linux-gnu"
        ;;
    *)
        die "Unsupported architecture: $BISQ_ARCH (supported: x86_64-linux, x86_64-linux-gnu)" "$EXIT_INVALID_PARAMS"
        ;;
esac

# Validate type
if [[ "$BISQ_TYPE" != "deb" ]]; then
    die "Unsupported package type: $BISQ_TYPE (only deb is supported)" "$EXIT_INVALID_PARAMS"
fi

# Ensure version has 'v' prefix
if [[ ! "$BISQ_VERSION" =~ ^v ]]; then
    BISQ_VERSION="v$BISQ_VERSION"
fi

# Set unique Docker names
VERSION_COMPONENT=$(sanitize_component "$BISQ_VERSION")
ARCH_COMPONENT=$(sanitize_component "$BISQ_ARCH")
TYPE_COMPONENT=$(sanitize_component "$BISQ_TYPE")
SUFFIX=$(sanitize_component "$(date +%s)-$$")

IMAGE_NAME="bisq1-verifier-${VERSION_COMPONENT}-${ARCH_COMPONENT}-${TYPE_COMPONENT}-${SUFFIX}"
CONTAINER_NAME="bisq1-verify-${VERSION_COMPONENT}-${ARCH_COMPONENT}-${TYPE_COMPONENT}-${SUFFIX}"

# Set work directory
WORK_DIR="${SCRIPT_DIR}/bisq1_desktop_${VERSION_COMPONENT}_${ARCH_COMPONENT}_${TYPE_COMPONENT}_$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
chmod 777 "$WORK_DIR" >/dev/null 2>&1 || true

# Save execution directory for YAML handoff to build server
execution_dir="$(pwd)"

log_info "========================================================"
log_info "Bisq 1 Desktop Reproducible Build Verification"
log_info "========================================================"
log_info "Version:      $BISQ_VERSION"
log_info "Architecture: $BISQ_ARCH"
log_info "Type:         $BISQ_TYPE"
log_info "Work Dir:     $WORK_DIR"
log_info "Script:       $SCRIPT_VERSION"
log_info ""

# Generate error YAML
generate_error_yaml() {
    local output_file="$1"
    local error_message="$2"
    local status="${3:-not_reproducible}"

    cat > "$output_file" << EOF
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION}
build_type: ${BISQ_TYPE}
results:
  - architecture: ${BISQ_ARCH}
    status: ${status}
    files:
      - filename: bisq_${BISQ_VERSION#v}-1_amd64.deb
        hash: ""
        match: false
        official_hash: ""
        notes: "Error: ${error_message}"
EOF
}

# Check Docker
log_info "Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Docker not found" "ftbfs"
    die "Docker not found" "$EXIT_BUILD_FAILED"
fi

if ! docker info >/dev/null 2>&1; then
    generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Docker daemon not running" "ftbfs"
    die "Docker daemon not running" "$EXIT_BUILD_FAILED"
fi
log_success "Docker OK"

# Clean Docker environment
log_info "Cleaning Docker environment..."
docker ps -q --filter ancestor="$IMAGE_NAME" 2>/dev/null | xargs -r docker stop 2>/dev/null || true
docker ps -aq --filter ancestor="$IMAGE_NAME" 2>/dev/null | xargs -r docker rm 2>/dev/null || true
if docker images -q "$IMAGE_NAME" >/dev/null 2>&1; then
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
fi

# Create Dockerfile
log_info "Creating Dockerfile..."
cat > "$SCRIPT_DIR/.dockerfile-bisq-temp" << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git wget curl unzip tar xz-utils zstd binutils \
    ca-certificates ca-certificates-java fakeroot dpkg-dev \
    build-essential debhelper rpm gnupg software-properties-common \
    && wget -q https://cdn.azul.com/zulu/bin/zulu-repo_1.0.0-3_all.deb \
    && dpkg -i zulu-repo_1.0.0-3_all.deb \
    && apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9 \
    && apt-get update \
    && apt-get install -y zulu11-jdk zulu17-jdk \
    && rm -rf /var/lib/apt/lists/* zulu-repo_1.0.0-3_all.deb \
    && update-ca-certificates \
    && mkdir -p /usr/lib/jvm/zulu11/lib/security \
    && touch /usr/lib/jvm/zulu11/lib/security/blacklisted.certs \
    && useradd -m -s /bin/bash bisq

ENV JAVA_HOME=/usr/lib/jvm/zulu11
ENV JAVA_17_HOME=/usr/lib/jvm/zulu17
ENV PATH=$JAVA_HOME/bin:$PATH
ENV GRADLE_OPTS="-Xmx4g -Dorg.gradle.daemon=false"

USER bisq
WORKDIR /home/bisq

COPY --chown=bisq:bisq verify-container-bisq.sh /home/bisq/
RUN chmod +x /home/bisq/verify-container-bisq.sh

CMD ["/home/bisq/verify-container-bisq.sh"]
DOCKERFILE

# Create container verification script
log_info "Creating container script..."
cat > "$SCRIPT_DIR/verify-container-bisq.sh" << 'CONTAINER_SCRIPT'
#!/bin/bash
set -uo pipefail
# Note: -e removed to allow script to continue and generate YAML even on errors

echo "=== Bisq Container Verification ==="
echo "Version: ${BISQ_VERSION:-v1.9.21}"
echo "Architecture: ${BISQ_ARCH:-x86_64-linux-gnu}"
echo "Type: ${BISQ_TYPE:-deb}"
echo ""

BISQ_VERSION=${BISQ_VERSION:-v1.9.21}
WORK_DIR="/home/bisq/work"
RESULTS_DIR="/home/bisq/build-results"

mkdir -p "$WORK_DIR" "$RESULTS_DIR"
cd "$WORK_DIR"

# Helper function to generate error YAML and exit
generate_error_and_exit() {
    local error_msg="$1"
    echo "ERROR: $error_msg"
    mkdir -p /output
    cat > /output/COMPARISON_RESULTS.yaml << ERRYAML
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION:-v0.3.4}
build_type: ${BISQ_TYPE:-deb}
results:
  - architecture: ${BISQ_ARCH:-x86_64-linux-gnu}
    status: ftbfs
    files:
      - filename: unknown
        hash: ""
        match: false
        official_hash: ""
        notes: "$error_msg"
ERRYAML
    exit 1
}

echo "Cloning repository..."
if ! git clone --progress https://github.com/bisq-network/bisq.git; then
    generate_error_and_exit "Failed to clone Bisq repository"
fi

cd bisq || generate_error_and_exit "Failed to enter bisq directory"

echo "Checking out version $BISQ_VERSION..."
if ! git checkout "$BISQ_VERSION"; then
    generate_error_and_exit "Failed to checkout version $BISQ_VERSION"
fi
echo "Checkout complete: $(git describe --tags)"

echo "Downloading official release..."
cd "$WORK_DIR" || generate_error_and_exit "Failed to change to work directory"
OFFICIAL_DEB="Bisq-64bit-${BISQ_VERSION#v}.deb"
if ! wget --progress=bar:force "https://github.com/bisq-network/bisq/releases/download/${BISQ_VERSION}/${OFFICIAL_DEB}"; then
    generate_error_and_exit "Failed to download official release $OFFICIAL_DEB"
fi
echo "Download complete"

echo "Building (20-30 min)..."
cd bisq || generate_error_and_exit "Failed to enter bisq directory for build"
if ! ./gradlew clean build -x test; then
    generate_error_and_exit "Gradle build failed"
fi

echo "Creating package..."
echo "Using Java 17 for jpackage..."
export JAVA_HOME=$JAVA_17_HOME
export PATH=$JAVA_17_HOME/bin:$PATH
if ! ./gradlew desktop:generateInstallers --rerun-tasks; then
    generate_error_and_exit "Gradle generateInstallers failed"
fi
echo "Build complete"

# Find built package
LOCAL_DEB=$(find desktop/build/packaging/jpackage/packages -name "bisq_*-1_amd64.deb" 2>/dev/null | head -1)
if [[ -z "$LOCAL_DEB" ]]; then
    echo "ERROR: Built .deb file not found"
    mkdir -p /output
    cat > /output/COMPARISON_RESULTS.yaml << ERRYAML
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION:-v0.3.4}
build_type: ${BISQ_TYPE:-deb}
results:
  - architecture: ${BISQ_ARCH:-x86_64-linux-gnu}
    status: ftbfs
    files:
      - filename: unknown
        hash: ""
        match: false
        official_hash: ""
        notes: "Build failed: .deb file not found in desktop/build/packaging/jpackage/packages"
ERRYAML
    exit 1
fi
LOCAL_DEB=$(realpath "$LOCAL_DEB")

OFFICIAL_DEB="$WORK_DIR/${OFFICIAL_DEB}"

echo ""
echo "Comparing packages..."
echo "  Official: $(basename "$OFFICIAL_DEB")"
echo "  Built:    $(basename "$LOCAL_DEB")"
echo ""

# Extract packages
EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$EXTRACT_DIR"/{official,local,jars/{official,local}}

echo "Extracting official package..."
cd "$EXTRACT_DIR/official"
ar -x "$OFFICIAL_DEB"
tar -xJf data.tar.xz 2>/dev/null || tar --zstd -xf data.tar.zst 2>/dev/null || tar -xzf data.tar.gz

echo "Extracting built package..."
cd "$EXTRACT_DIR/local"
ar -x "$LOCAL_DEB"
tar -xJf data.tar.xz 2>/dev/null || tar --zstd -xf data.tar.zst 2>/dev/null || tar -xzf data.tar.gz

echo "Finding desktop.jar files..."
OFFICIAL_JAR=$(find "$EXTRACT_DIR/official" -name "desktop.jar" | head -1)
LOCAL_JAR=$(find "$EXTRACT_DIR/local" -name "desktop.jar" | head -1)

if [[ -z "$OFFICIAL_JAR" ]] || [[ -z "$LOCAL_JAR" ]]; then
    echo "ERROR: Could not find desktop.jar files"
    mkdir -p /output
    cat > /output/COMPARISON_RESULTS.yaml << ERRYAML
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION:-v0.3.4}
build_type: ${BISQ_TYPE:-deb}
results:
  - architecture: ${BISQ_ARCH:-x86_64-linux-gnu}
    status: ftbfs
    files:
      - filename: unknown
        hash: ""
        match: false
        official_hash: ""
        notes: "Comparison failed: desktop.jar not found in extracted packages"
ERRYAML
    exit 1
fi

echo "  Official JAR: $OFFICIAL_JAR"
echo "  Local JAR:    $LOCAL_JAR"

echo "Extracting JARs..."
if ! (cd "$EXTRACT_DIR/jars/official" && jar -xf "$OFFICIAL_JAR"); then
    generate_error_and_exit "Failed to extract official JAR: $OFFICIAL_JAR"
fi
if ! (cd "$EXTRACT_DIR/jars/local" && jar -xf "$LOCAL_JAR"); then
    generate_error_and_exit "Failed to extract local JAR: $LOCAL_JAR"
fi

echo "Generating hashes..."
cd "$WORK_DIR"

# Generate hashes using a subshell to avoid pipefail issues
(
    find "$EXTRACT_DIR/jars/official" -name "*.class" -type f | sort | while read -r file; do
        hash=$(sha256sum "$file" | cut -d' ' -f1)
        relpath=$(echo "$file" | sed "s|$EXTRACT_DIR/jars/official/||")
        echo "$hash $relpath"
    done
) > official-hashes.txt || true

(
    find "$EXTRACT_DIR/jars/local" -name "*.class" -type f | sort | while read -r file; do
        hash=$(sha256sum "$file" | cut -d' ' -f1)
        relpath=$(echo "$file" | sed "s|$EXTRACT_DIR/jars/local/||")
        echo "$hash $relpath"
    done
) > local-hashes.txt || true

OFFICIAL_COUNT=$(wc -l < official-hashes.txt 2>/dev/null || echo "0")
LOCAL_COUNT=$(wc -l < local-hashes.txt 2>/dev/null || echo "0")

echo "Comparing hashes..."
echo "  Official class files: $OFFICIAL_COUNT"
echo "  Built class files:    $LOCAL_COUNT"

# comm requires fully sorted inputs; use temp files to avoid subshell issues
LC_ALL=C sort official-hashes.txt > official-sorted.txt 2>/dev/null || true
LC_ALL=C sort local-hashes.txt > local-sorted.txt 2>/dev/null || true

# Compare and capture differences
# comm -3 outputs:
#   - Lines only in file1 (official): no leading tab, path in $1
#   - Lines only in file2 (local): leading tab, path in $2
# We need to capture BOTH to get all differing files

# Get files only in official (missing from local build)
OFFICIAL_ONLY=$(comm -23 official-sorted.txt local-sorted.txt 2>/dev/null || true)
# Get files only in local (extra in local build)  
LOCAL_ONLY=$(comm -13 official-sorted.txt local-sorted.txt 2>/dev/null || true)
# Get files in both but with different hashes (hash differs)
# This requires comparing just the file paths that exist in both
DIFF_OUTPUT=$(comm -3 official-sorted.txt local-sorted.txt 2>/dev/null || true)

DIFF_COUNT=0
if [[ -n "$DIFF_OUTPUT" ]]; then
    DIFF_COUNT=$(echo "$DIFF_OUTPUT" | awk 'NF {count++} END {print count+0}')
fi
[[ -z "$DIFF_COUNT" ]] && DIFF_COUNT=0

# Extract differing file paths for module analysis
# Capture paths from both columns (official-only and local-only/different)
if [[ $DIFF_COUNT -gt 0 ]]; then
    {
        # Files only in official (column 1, no tab prefix) - extract path (field 2 of hash+path)
        echo "$OFFICIAL_ONLY" | awk 'NF {print $2}'
        # Files only in local or with different hash (column 2, tab prefix) - extract path
        echo "$LOCAL_ONLY" | awk 'NF {print $2}'
    } | sort -u > differing-files.txt
else
    touch differing-files.txt
fi

# Module breakdown - use grep and wc for reliable counting
CORE_DIFFS=$(grep "bisq/core/" differing-files.txt 2>/dev/null | wc -l | tr -d ' ')
[ -z "$CORE_DIFFS" ] && CORE_DIFFS=0
P2P_DIFFS=$(grep "bisq/p2p/" differing-files.txt 2>/dev/null | wc -l | tr -d ' ')
[ -z "$P2P_DIFFS" ] && P2P_DIFFS=0
DESKTOP_DIFFS=$(grep "bisq/desktop/" differing-files.txt 2>/dev/null | wc -l | tr -d ' ')
[ -z "$DESKTOP_DIFFS" ] && DESKTOP_DIFFS=0
COMMON_DIFFS=$(grep "bisq/common/" differing-files.txt 2>/dev/null | wc -l | tr -d ' ')
[ -z "$COMMON_DIFFS" ] && COMMON_DIFFS=0
PROTO_DIFFS=$(grep "bisq/proto/" differing-files.txt 2>/dev/null | wc -l | tr -d ' ')
[ -z "$PROTO_DIFFS" ] && PROTO_DIFFS=0
OTHER_DIFFS=$(( ${DIFF_COUNT:-0} - ${CORE_DIFFS:-0} - ${P2P_DIFFS:-0} - ${DESKTOP_DIFFS:-0} - ${COMMON_DIFFS:-0} - ${PROTO_DIFFS:-0} ))
[[ $OTHER_DIFFS -lt 0 ]] && OTHER_DIFFS=0

# Security assessment
SECURITY_CRITICAL_DIFFS=$(( ${CORE_DIFFS:-0} + ${P2P_DIFFS:-0} + ${PROTO_DIFFS:-0} ))

echo ""
echo "---"
echo "RESULTS"
echo "---"
echo "Official files: $OFFICIAL_COUNT"
echo "Local files:    $LOCAL_COUNT"
echo "Differences:    $DIFF_COUNT"
echo ""

if [[ $DIFF_COUNT -gt 0 ]]; then
    echo "  ✗ Deep inspection: $DIFF_COUNT class files differ"
    echo ""
    echo "  Differences by module:"
    echo "    Core (crypto/protocol):  $CORE_DIFFS files"
    echo "    P2P (networking):        $P2P_DIFFS files"
    echo "    Desktop (UI):            $DESKTOP_DIFFS files"
    echo "    Common (utilities):      $COMMON_DIFFS files"
    echo "    Proto (messages):        $PROTO_DIFFS files"
    [[ $OTHER_DIFFS -gt 0 ]] && echo "    Other:                   $OTHER_DIFFS files"
    echo ""

    if [[ $SECURITY_CRITICAL_DIFFS -eq 0 ]]; then
        echo "  ✓ SECURITY-CRITICAL MODULES ARE IDENTICAL"
        echo "    All differences are in UI/utility layers (non-security-critical)"
        echo ""
    else
        echo "  ⚠ SECURITY-CRITICAL CODE DIFFERS"
        echo "    $SECURITY_CRITICAL_DIFFS security-critical file(s) differ"
        echo ""
    fi

    echo "  Differing files (all $DIFF_COUNT):"
    while read -r path; do
        echo "    - $path"
    done < differing-files.txt
    echo ""
else
    echo "  ✓ Deep inspection: All $OFFICIAL_COUNT class files IDENTICAL"
    echo ""
fi

# Calculate package hashes
OFFICIAL_HASH=$(sha256sum "$OFFICIAL_DEB" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
LOCAL_HASH=$(sha256sum "$LOCAL_DEB" 2>/dev/null | cut -d' ' -f1 || echo "unknown")

# Determine status with security consideration
if [[ $DIFF_COUNT -eq 0 ]] && [[ $OFFICIAL_COUNT -eq $LOCAL_COUNT ]] && [[ $OFFICIAL_COUNT -gt 0 ]]; then
    STATUS="reproducible"
    MATCH="true"
    VERDICT="FULLY REPRODUCIBLE"
    echo "$VERDICT"
elif [[ $SECURITY_CRITICAL_DIFFS -eq 0 ]] && [[ $DIFF_COUNT -gt 0 ]]; then
    STATUS="not_reproducible"
    MATCH="false"
    VERDICT="FUNCTIONALLY REPRODUCIBLE (security-critical code identical, UI differences only)"
    echo "$VERDICT"
else
    STATUS="not_reproducible"
    MATCH="false"
    VERDICT="NOT REPRODUCIBLE (security-critical code differs)"
    echo "$VERDICT"
fi

# Generate YAML
mkdir -p /output
cat > /output/COMPARISON_RESULTS.yaml << EOF
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION:-v0.3.2}
build_type: ${BISQ_TYPE:-deb}
results:
  - architecture: ${BISQ_ARCH:-x86_64-linux-gnu}
    status: ${STATUS:-not_reproducible}
    files:
      - filename: $(basename "${LOCAL_DEB:-unknown.deb}")
        hash: ${LOCAL_HASH:-unknown}
        match: ${MATCH:-false}
        official_hash: ${OFFICIAL_HASH:-unknown}
        notes: "Compared ${OFFICIAL_COUNT:-0} .class files, ${DIFF_COUNT:-0} differences. Modules: core=${CORE_DIFFS:-0}, p2p=${P2P_DIFFS:-0}, desktop=${DESKTOP_DIFFS:-0}, common=${COMMON_DIFFS:-0}, proto=${PROTO_DIFFS:-0}. Security-critical: ${SECURITY_CRITICAL_DIFFS:-0} diffs"
        verdict: "${VERDICT:-unknown}"
EOF

echo ""
echo "Status: $STATUS"
echo "Complete"
exit 0
CONTAINER_SCRIPT

# Build Docker image
log_info "Building Docker image..."
CACHE_FLAG=""
[[ "$NO_CACHE" == "true" ]] && CACHE_FLAG="--no-cache"

if ! docker build $CACHE_FLAG -t "$IMAGE_NAME" -f "$SCRIPT_DIR/.dockerfile-bisq-temp" "$SCRIPT_DIR" 2>&1 | tee build.log; then
    generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Docker image build failed" "ftbfs"
    die "Docker image build failed" "$EXIT_BUILD_FAILED"
fi
log_success "Image built: $IMAGE_NAME"

# Run container (capture exit code but don't fail immediately)
log_info "Starting container build..."
set +e
docker run \
    -e BISQ_VERSION="$BISQ_VERSION" \
    -e BISQ_ARCH="$BISQ_ARCH" \
    -e BISQ_TYPE="$BISQ_TYPE" \
    -e SCRIPT_VERSION="$SCRIPT_VERSION" \
    -v "${execution_dir}":/output \
    --name "$CONTAINER_NAME" \
    "$IMAGE_NAME" 2>&1 | tee container.log
CONTAINER_EXIT_CODE=${PIPESTATUS[0]}
set -e

# Check if YAML was generated (indicates successful completion)
if [[ ! -f "${execution_dir}/COMPARISON_RESULTS.yaml" ]]; then
    # No YAML = real failure (build crashed, script error, etc.)
    generate_error_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" "Container execution failed (no YAML output)" "ftbfs"
    die "Container execution failed - no COMPARISON_RESULTS.yaml generated" "$EXIT_BUILD_FAILED"
fi

# YAML exists = script completed successfully (reproducible or not)
# Exit code 0 = reproducible, 1 = not reproducible (both are valid outcomes)

# Cleanup container unless --keep-container was specified
if [[ "$KEEP_CONTAINER" != "true" ]]; then
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Display results
log_info ""
log_info "======================================================"
log_info "RESULTS"
log_info "======================================================"
cat "${execution_dir}/COMPARISON_RESULTS.yaml"
log_info ""

# Emit standardized verification summary
RESULT_FILE="${execution_dir}/COMPARISON_RESULTS.yaml"
STATUS=$(grep "^[[:space:]]*status:" "$RESULT_FILE" | head -1 | awk '{print $2}')
BUILT_HASH=$(awk '/^[[:space:]]+hash:[[:space:]]/ {print $2; exit}' "$RESULT_FILE")
OFFICIAL_HASH=$(awk '/official_hash:[[:space:]]/ {print $2; exit}' "$RESULT_FILE")
NOTES_LINE=$(awk -F': ' '/notes:[[:space:]]/ {sub(/^"/,"",$2); sub(/"$/,"",$2); print $2; exit}' "$RESULT_FILE")
VERSION_NO_PREFIX="${BISQ_VERSION#v}"
[[ -z "$BUILT_HASH" ]] && BUILT_HASH="(unknown)"
[[ -z "$OFFICIAL_HASH" ]] && OFFICIAL_HASH="(unknown)"
[[ -z "$NOTES_LINE" ]] && NOTES_LINE="See COMPARISON_RESULTS.yaml for detailed context."

if [[ "$STATUS" == "reproducible" ]]; then
    VERDICT_TEXT="reproducible"
else
    VERDICT_TEXT="differences found"
fi

cat <<EOF
===== Begin Results =====
appId:          $APP_ID
signer:         N/A
apkVersionName: ${VERSION_NO_PREFIX}
apkVersionCode: ${VERSION_NO_PREFIX}
verdict:        $VERDICT_TEXT
appHash:        $OFFICIAL_HASH
commit:         $BISQ_VERSION

Diff:
$NOTES_LINE

Revision, tag (and its signature):
(Not captured; rerun gpg --verify on upstream tag $BISQ_VERSION)

Signature Summary:
Tag type: unknown
[WARNING] Signature status not captured in automated run

Keys used:
N/A

===== End Results =====

Run a full
diffoscope "<official .deb>" "<local .deb>"
meld "<official desktop.jar>" "<local desktop.jar>"
or
diff --recursive /home/bisq/work/extract/official /home/bisq/work/extract/local
for more details.
EOF

# Final verdict (both outcomes are successful completions)
log_info ""
log_info "======================================================"
if [[ "$STATUS" == "reproducible" ]]; then
    log_success "VERIFICATION COMPLETE: REPRODUCIBLE"
    log_info "Exit code: $EXIT_SUCCESS"
    exit "$EXIT_SUCCESS"
else
    log_success "VERIFICATION COMPLETE: NOT REPRODUCIBLE"
    log_info "Result: Build completed successfully, artifacts differ"
    log_info "Exit code: $EXIT_BUILD_FAILED (indicates non-reproducible, not failure)"
    exit "$EXIT_BUILD_FAILED"
fi
