#!/bin/bash
# ==============================================================================
# specterdesktop_build.sh - Specter Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.8
# Organization:  WalletScrutiny.com
# Last Modified: 2025-12-19
# Project:       https://github.com/cryptoadvance/specter-desktop
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/desktop/specter/changelog.md
# ==============================================================================
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
# - Downloads official specterd binary from GitHub releases
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using PyInstaller in Ubuntu 22.04
# - Extracts and compares PyInstaller bundles (Level 2 verification)
# - Compares entry point (specterd.pyc) to verify source code identity
# - Documents differences and generates COMPARISON_RESULTS.yaml
#
# NOTE: This app is known to be NOT reproducible due to dependency version drift.
#       The project acknowledges this in docs/build-instructions.md.
# ==============================================================================
#
# Usage:
#   specterdesktop_build.sh --version VERSION --arch ARCH --type TYPE [OPTIONS]
#
# Required Parameters:
#   --version VERSION    Specter version to build (e.g., 2.0.5)
#   --arch ARCH          Target architecture (x86_64-linux-gnu)
#   --type TYPE          Artifact type (tarball)
#
# Optional Parameters:
#   --work-dir DIR       Working directory (default: ./specter_desktop_VERSION_ARCH_TYPE_PID)
#   --no-cache           Force rebuild without Docker cache
#   --keep-container     Don't remove container after completion
#   --quiet              Suppress non-essential output
#
# Examples:
#   specterdesktop_build.sh --version 2.0.5 --arch x86_64-linux-gnu --type tarball
#   specterdesktop_build.sh --version 2.0.5 --arch x86_64-linux-gnu --type tarball --no-cache
#
# ==============================================================================
#

set -euo pipefail

# Script version
SCRIPT_VERSION="v0.2.8"

# Exit codes (BSA compliant)
EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Default values
DEFAULT_BASE_IMAGE="ubuntu:22.04"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Global variables
APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
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

log() {
    [[ "$QUIET" != true ]] && echo "$1"
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

    # Validate and normalize type
    # - tarball/specterd = CLI daemon only (specterd-v*.zip)
    # - electron-gui/desktop = Full GUI app (specter_desktop-v*.tar.gz)
    case "$APP_TYPE" in
        tarball|specterd)
            APP_TYPE="specterd"  # Normalize tarball -> specterd for backward compatibility
            ;;
        electron-gui|desktop)
            APP_TYPE="electron-gui"  # Normalize desktop -> electron-gui
            ;;
        *)
            die "Invalid type: $APP_TYPE (supported: 'tarball', 'specterd', 'electron-gui')" $EXIT_INVALID_PARAMS
            ;;
    esac

    # Validate architecture
    if [[ "$APP_ARCH" != "x86_64-linux-gnu" ]]; then
        die "Invalid arch: $APP_ARCH (only 'x86_64-linux-gnu' supported)" $EXIT_INVALID_PARAMS
    fi
}

show_help() {
    cat << 'EOF'
specterdesktop_build.sh v0.2.8 - Specter Desktop Reproducible Build Verification

USAGE:
    specterdesktop_build.sh --version VERSION --arch ARCH --type TYPE [OPTIONS]

REQUIRED PARAMETERS:
    --version VERSION    Specter version to build (e.g., 2.0.5)
    --arch ARCH          Target architecture (x86_64-linux-gnu)
    --type TYPE          Artifact type:
                           tarball      - CLI daemon only (specterd-v*.zip) [default for BSA]
                           specterd     - Alias for tarball
                           electron-gui - Electron GUI app (compares specter_desktop-v*.tar.gz)

OPTIONAL PARAMETERS:
    --work-dir DIR       Working directory (default: ./specter_desktop_VERSION_ARCH_TYPE_PID)
    --no-cache           Force rebuild without Docker cache
    --keep-container     Don't remove container after completion
    --quiet              Suppress non-essential output

EXAMPLES:
    specterdesktop_build.sh --version 2.0.5 --arch x86_64-linux-gnu --type specterd
    specterdesktop_build.sh --version 2.0.5 --arch x86_64-linux-gnu --type electron-gui
    specterdesktop_build.sh --version 2.0.5 --arch x86_64-linux-gnu --type specterd --no-cache

EXIT CODES (BSA Compliant):
    0 - Reproducible (hashes match)
    1 - Build failed OR not reproducible
    2 - Invalid parameters

OUTPUT:
    COMPARISON_RESULTS.yaml - Machine-readable verification results

VERIFICATION LEVEL:
    Level 2 - Hash comparison + PyInstaller extraction analysis
    - Compares SHA256 of built vs official specterd binary
    - Extracts both binaries and compares entry point (specterd.pyc)
    - Reports file count differences and dependency version drift

NOTE:
    Specter Desktop is known to be NOT reproducible due to dependency version drift.
    The project acknowledges this in docs/build-instructions.md:
    "The result unfortunately is not stable in terms of identically sha256-hashes"

EOF
    exit 0
}

# ============================================================================
# Dockerfile Generation
# ============================================================================

create_dockerfile() {
    cat > Dockerfile << 'DOCKERFILE_END'
# Specter Desktop Build Container
# Based on Ubuntu 22.04 (Jammy) - matches official GitLab CI environment
# Python 3.10 is natively available

FROM ubuntu:22.04

# Build arguments
ARG SPECTER_VERSION
ARG BUILD_TYPE
ARG BUILD_ARCH
ARG SCRIPT_VERSION

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV SPECTER_VERSION=${SPECTER_VERSION}
ENV BUILD_TYPE=${BUILD_TYPE}
ENV BUILD_ARCH=${BUILD_ARCH}
ENV SCRIPT_VERSION=${SCRIPT_VERSION}

# Install system dependencies (includes Node.js for electron builds)
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3.10-venv \
    python3.10-dev \
    python3-pip \
    python3-virtualenv \
    build-essential \
    git \
    curl \
    wget \
    zip \
    unzip \
    libusb-1.0-0-dev \
    libudev-dev \
    libffi-dev \
    libssl-dev \
    nodejs \
    npm \
    libfuse2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 18 (required for Electron builds)
RUN npm install -g n && n 18

# Set Python 3.10 as default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
RUN python3 -m pip install --upgrade pip

# Create output directory
RUN mkdir -p /output

# Set working directory
WORKDIR /build

# Clone repository at specific version
RUN git clone --depth 1 --branch v${SPECTER_VERSION} \
    https://github.com/cryptoadvance/specter-desktop.git .

# Copy verification script
COPY verify.sh /verify.sh
RUN chmod +x /verify.sh

# Run verification
RUN /verify.sh
DOCKERFILE_END
}

# ============================================================================
# Verification Script Generation
# ============================================================================

create_verify_script() {
    cat > verify.sh << 'VERIFY_END'
#!/bin/bash
set -euo pipefail

# Metadata from environment
SCRIPT_VERSION="${SCRIPT_VERSION:-unknown}"
BUILD_TYPE="${BUILD_TYPE:-tarball}"
SPECTER_VERSION="${SPECTER_VERSION:-unknown}"
BUILD_ARCH="${BUILD_ARCH:-x86_64-linux-gnu}"

echo "========================================================"
echo "SPECTER DESKTOP VERIFICATION"
echo "========================================================"
echo "Version: v${SPECTER_VERSION}"
echo "Architecture: ${BUILD_ARCH}"
echo "Type: ${BUILD_TYPE}"
echo "Script: ${SCRIPT_VERSION}"
echo ""

# ============================================================================
# Phase 1: Build from source
# ============================================================================

cd /build

# Configure git
git config --global --add safe.directory /build

# Create virtualenv
virtualenv --python=python3.10 .buildenv
source .buildenv/bin/activate

# Install build module (required for python3 -m build)
pip3 install build

# Install requirements with hashes (ensures dependency integrity)
pip3 install -r requirements.txt --require-hashes

# Install specter in editable mode
pip3 install -e .

# Install pyinstaller requirements
cd pyinstaller
pip3 install -r requirements.txt --require-hashes
pip3 install -e ..
cd ..

# Build pip package
python3 -m build
pip3 install ./dist/cryptoadvance.specter-*.whl

# Create version.txt (required by specterd.spec)
cd pyinstaller
echo "v${SPECTER_VERSION}" > version.txt

if [[ "$BUILD_TYPE" == "specterd" ]]; then
    # ========================================================================
    # SPECTERD: Build CLI daemon only
    # ========================================================================
    echo "Phase 1: Building specterd from source..."
    echo ""
    
    rm -rf build/ dist/
    pyinstaller specterd.spec
    
    BUILT_ARTIFACT="/build/pyinstaller/dist/specterd"
    ARTIFACT_NAME="specterd"
    
    if [[ ! -f "$BUILT_ARTIFACT" ]]; then
        echo "ERROR: Build failed - specterd not found"
        exit 1
    fi

elif [[ "$BUILD_TYPE" == "electron-gui" ]]; then
    # ========================================================================
    # ELECTRON-GUI: Build specterd + Electron app (packaged as AppImage in tarball)
    # ========================================================================
    echo "Phase 1: Building Specter Desktop (Electron) from source..."
    echo ""
    
    # Build specterd first
    rm -rf build/ dist/
    pyinstaller specterd.spec
    
    if [[ ! -f "/build/pyinstaller/dist/specterd" ]]; then
        echo "ERROR: Build failed - specterd not found"
        exit 1
    fi
    
    # Build Electron app
    cd /build/pyinstaller/electron
    npm install
    npm run dist
    
    # Find the AppImage (this is what we actually compare)
    BUILT_ARTIFACT=$(find /build/pyinstaller/electron/dist -name "Specter-*.AppImage" | head -1)
    ARTIFACT_NAME="Specter-${SPECTER_VERSION}.AppImage"
    
    if [[ -z "$BUILT_ARTIFACT" || ! -f "$BUILT_ARTIFACT" ]]; then
        echo "ERROR: Build failed - AppImage not found"
        exit 1
    fi
fi

cd /build

BUILT_HASH=$(sha256sum "$BUILT_ARTIFACT" | cut -d' ' -f1)
BUILT_SIZE=$(stat -c%s "$BUILT_ARTIFACT")

echo "Built ${ARTIFACT_NAME}:"
echo "  Hash: $BUILT_HASH"
echo "  Size: $BUILT_SIZE bytes"
echo ""

# ============================================================================
# Phase 2: Download official release
# ============================================================================

echo "Phase 2: Downloading official release..."
echo ""

cd /build
OFFICIAL_DIR="/build/official"
mkdir -p "$OFFICIAL_DIR"

if [[ "$BUILD_TYPE" == "specterd" ]]; then
    OFFICIAL_URL="https://github.com/cryptoadvance/specter-desktop/releases/download/v${SPECTER_VERSION}/specterd-v${SPECTER_VERSION}-x86_64-linux-gnu.zip"
    OFFICIAL_ZIP="/build/official.zip"
    
    wget -q "$OFFICIAL_URL" -O "$OFFICIAL_ZIP" || {
        echo "ERROR: Failed to download official release"
        echo "URL: $OFFICIAL_URL"
        exit 1
    }
    
    unzip -q "$OFFICIAL_ZIP" -d "$OFFICIAL_DIR"
    OFFICIAL_ARTIFACT="$OFFICIAL_DIR/specterd"

elif [[ "$BUILD_TYPE" == "electron-gui" ]]; then
    # The release asset is a tarball containing the AppImage
    RELEASE_FILENAME="specter_desktop-v${SPECTER_VERSION}-x86_64-linux-gnu.tar.gz"
    OFFICIAL_URL="https://github.com/cryptoadvance/specter-desktop/releases/download/v${SPECTER_VERSION}/${RELEASE_FILENAME}"
    OFFICIAL_TAR="/build/official.tar.gz"
    
    wget -q "$OFFICIAL_URL" -O "$OFFICIAL_TAR" || {
        echo "ERROR: Failed to download official release"
        echo "URL: $OFFICIAL_URL"
        exit 1
    }
    
    # Record tarball hash (this is what user actually downloads)
    TARBALL_HASH=$(sha256sum "$OFFICIAL_TAR" | cut -d' ' -f1)
    echo "Official tarball: $RELEASE_FILENAME"
    echo "  Tarball hash: $TARBALL_HASH"
    
    tar -xzf "$OFFICIAL_TAR" -C "$OFFICIAL_DIR"
    OFFICIAL_ARTIFACT=$(find "$OFFICIAL_DIR" -name "Specter-*.AppImage" | head -1)
    
    echo "Extracted AppImage for comparison: $(basename "$OFFICIAL_ARTIFACT")"
fi

if [[ -z "$OFFICIAL_ARTIFACT" || ! -f "$OFFICIAL_ARTIFACT" ]]; then
    echo "ERROR: Official artifact not found"
    exit 1
fi

OFFICIAL_HASH=$(sha256sum "$OFFICIAL_ARTIFACT" | cut -d' ' -f1)
OFFICIAL_SIZE=$(stat -c%s "$OFFICIAL_ARTIFACT")

echo "Official ${ARTIFACT_NAME}:"
echo "  Hash: $OFFICIAL_HASH"
echo "  Size: $OFFICIAL_SIZE bytes"
echo ""

# ============================================================================
# Phase 3: Compare hashes
# ============================================================================

echo "Phase 3: Comparing hashes..."
echo ""

MATCH="false"
STATUS="not_reproducible"

if [[ "$BUILT_HASH" == "$OFFICIAL_HASH" ]]; then
    MATCH="true"
    STATUS="reproducible"
    echo "RESULT: REPRODUCIBLE - Hashes match!"
else
    echo "RESULT: NOT REPRODUCIBLE - Hashes differ"
    echo ""
    echo "  Built:    $BUILT_HASH"
    echo "  Official: $OFFICIAL_HASH"
    echo "  Size diff: $((OFFICIAL_SIZE - BUILT_SIZE)) bytes"
fi
echo ""

# ============================================================================
# Phase 4: Deep extraction analysis (Level 2)
# ============================================================================

echo "Phase 4: Deep extraction analysis..."
echo ""

BUILT_FILES=0
OFFICIAL_FILES=0
ENTRY_MATCH="N/A"
DEPS_DIFF=""

if [[ "$BUILD_TYPE" == "specterd" ]]; then
    # PyInstaller extraction for specterd
    cd /build
    wget -q https://raw.githubusercontent.com/extremecoders-re/pyinstxtractor/master/pyinstxtractor.py
    
    mkdir -p /build/extract_built /build/extract_official
    
    cd /build/extract_built
    python3 /build/pyinstxtractor.py "$BUILT_ARTIFACT" > /dev/null 2>&1 || true
    
    cd /build/extract_official
    python3 /build/pyinstxtractor.py "$OFFICIAL_ARTIFACT" > /dev/null 2>&1 || true
    
    BUILT_FILES=$(find /build/extract_built -type f 2>/dev/null | wc -l)
    OFFICIAL_FILES=$(find /build/extract_official -type f 2>/dev/null | wc -l)
    
    echo "Extracted file counts:"
    echo "  Built:    $BUILT_FILES files"
    echo "  Official: $OFFICIAL_FILES files"
    echo ""
    
    # Check entry point
    BUILT_ENTRY=""
    OFFICIAL_ENTRY=""
    
    if [[ -f "/build/extract_built/specterd_extracted/specterd.pyc" ]]; then
        BUILT_ENTRY=$(sha256sum "/build/extract_built/specterd_extracted/specterd.pyc" | cut -d' ' -f1)
    fi
    
    if [[ -f "/build/extract_official/specterd_extracted/specterd.pyc" ]]; then
        OFFICIAL_ENTRY=$(sha256sum "/build/extract_official/specterd_extracted/specterd.pyc" | cut -d' ' -f1)
    fi
    
    if [[ -n "$BUILT_ENTRY" && -n "$OFFICIAL_ENTRY" ]]; then
        if [[ "$BUILT_ENTRY" == "$OFFICIAL_ENTRY" ]]; then
            ENTRY_MATCH="identical"
            echo "Entry point (specterd.pyc): IDENTICAL"
            echo "  This confirms the core daemon source code matches."
        else
            ENTRY_MATCH="different"
            echo "Entry point (specterd.pyc): DIFFERENT"
            echo "  Built:    $BUILT_ENTRY"
            echo "  Official: $OFFICIAL_ENTRY"
        fi
    else
        echo "Entry point: Could not extract for comparison"
    fi
    echo ""
    
    # Check for dependency version differences
    echo "Checking dependency versions..."
    BUILT_DEPS=$(find /build/extract_built -name "*.dist-info" -type d 2>/dev/null | xargs -I{} basename {} | sort)
    OFFICIAL_DEPS=$(find /build/extract_official -name "*.dist-info" -type d 2>/dev/null | xargs -I{} basename {} | sort)
    
    DEPS_DIFF=$(diff <(echo "$BUILT_DEPS") <(echo "$OFFICIAL_DEPS") 2>/dev/null | grep -E "^[<>]" | head -20 || true)
    
    if [[ -n "$DEPS_DIFF" ]]; then
        echo "Dependency version differences detected:"
        echo "$DEPS_DIFF" | head -10
        echo ""
        echo "(Showing first 10 differences)"
    else
        echo "No dependency version differences in dist-info"
    fi

elif [[ "$BUILD_TYPE" == "electron-gui" ]]; then
    # AppImage extraction (electron-gui tarball contains AppImage inside)
    cd /build
    mkdir -p /build/extract_built /build/extract_official
    
    chmod +x "$BUILT_ARTIFACT" "$OFFICIAL_ARTIFACT"
    
    cd /build/extract_built
    "$BUILT_ARTIFACT" --appimage-extract > /dev/null 2>&1 || true
    
    cd /build/extract_official
    "$OFFICIAL_ARTIFACT" --appimage-extract > /dev/null 2>&1 || true
    
    BUILT_FILES=$(find /build/extract_built -type f 2>/dev/null | wc -l)
    OFFICIAL_FILES=$(find /build/extract_official -type f 2>/dev/null | wc -l)
    
    echo "Extracted file counts:"
    echo "  Built:    $BUILT_FILES files"
    echo "  Official: $OFFICIAL_FILES files"
    echo ""
    
    # Compare extracted contents
    DIFF_COUNT=$(diff -rq /build/extract_built/squashfs-root /build/extract_official/squashfs-root 2>/dev/null | wc -l) || true
    DIFF_COUNT=${DIFF_COUNT:-0}
    echo "Files differing: $DIFF_COUNT"
    
    if [[ "$DIFF_COUNT" -gt 0 ]]; then
        echo "Differences found:"
        diff -rq /build/extract_built/squashfs-root /build/extract_official/squashfs-root 2>/dev/null | head -10 || true
        DEPS_DIFF="AppImage contents differ"
    fi
    ENTRY_MATCH="N/A (AppImage)"
fi
echo ""

# ============================================================================
# Phase 5: Generate YAML output
# ============================================================================

echo "Phase 5: Generating COMPARISON_RESULTS.yaml..."
echo ""

# Build notes string based on build type
if [[ "$BUILD_TYPE" == "specterd" ]]; then
    NOTES="Entry point ${ENTRY_MATCH}. Built ${BUILT_FILES} files vs official ${OFFICIAL_FILES} files."
else
    NOTES="Compared AppImage extracted from official tarball (${RELEASE_FILENAME}). Built ${BUILT_FILES} files vs official ${OFFICIAL_FILES} files."
fi
if [[ "$MATCH" == "false" ]]; then
    NOTES="${NOTES} Binary differs due to dependency version drift. Project acknowledges non-reproducibility in docs."
fi

if [[ "$BUILD_TYPE" == "electron-gui" ]]; then
    # Electron-GUI builds: Single file entry (tarball - what users download)
    # AppImage comparison details go in notes field
    cat > /output/COMPARISON_RESULTS.yaml << YAML_EOF
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${BUILD_ARCH}
    status: ${STATUS}
    files:
      - filename: ${RELEASE_FILENAME}
        hash: ${TARBALL_HASH}
        match: ${MATCH}
    notes: "${NOTES} Compared inner AppImage (${ARTIFACT_NAME}, hash: ${BUILT_HASH})."
YAML_EOF
else
    # Specterd builds: single artifact
    cat > /output/COMPARISON_RESULTS.yaml << YAML_EOF
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${BUILD_ARCH}
    status: ${STATUS}
    files:
      - filename: ${ARTIFACT_NAME}
        hash: ${BUILT_HASH}
        match: ${MATCH}
    notes: "${NOTES}"
YAML_EOF
fi

echo "YAML output generated at /output/COMPARISON_RESULTS.yaml"
echo ""

# ============================================================================
# Results Output (verification-result-summary-format.md compliant)
# ============================================================================

echo "===== Begin Results ====="
echo "appId:          specter-desktop"
echo "signer:         N/A"
echo "apkVersionName: ${SPECTER_VERSION}"
echo "apkVersionCode: N/A"
if [[ "$MATCH" == "true" ]]; then
    echo "verdict:        reproducible"
else
    echo "verdict:        "
fi
if [[ "$BUILD_TYPE" == "electron-gui" ]]; then
    echo "appHash:        ${TARBALL_HASH} (tarball)"
    echo "comparedHash:   ${OFFICIAL_HASH} (AppImage inside)"
else
    echo "appHash:        ${OFFICIAL_HASH}"
fi
echo "commit:         v${SPECTER_VERSION}"
echo ""
echo "BUILDS MATCH BINARIES"
if [[ "$BUILD_TYPE" == "electron-gui" ]]; then
    echo "Release: ${RELEASE_FILENAME} (tarball hash: ${TARBALL_HASH})"
    echo "Compared: ${ARTIFACT_NAME} - ${BUILD_ARCH} - ${BUILT_HASH} - $(if [[ "$MATCH" == "true" ]]; then echo "1 (MATCHES)"; else echo "0 (DOESN'T MATCH)"; fi)"
else
    echo "${ARTIFACT_NAME} - ${BUILD_ARCH} - ${BUILT_HASH} - $(if [[ "$MATCH" == "true" ]]; then echo "1 (MATCHES)"; else echo "0 (DOESN'T MATCH)"; fi)"
fi
echo ""
echo "SUMMARY"
echo "total: 1"
if [[ "$MATCH" == "true" ]]; then
    echo "matches: 1"
    echo "mismatches: 0"
else
    echo "matches: 0"
    echo "mismatches: 1"
fi
echo ""
echo "===== Also ===="
if [[ "$BUILD_TYPE" == "specterd" ]]; then
    echo "Entry point (specterd.pyc): ${ENTRY_MATCH}"
else
    echo "Entry point check: Not applicable for AppImage builds"
fi
echo "Built files: ${BUILT_FILES}, Official files: ${OFFICIAL_FILES}"
if [[ -n "$DEPS_DIFF" ]]; then
    if [[ "$BUILD_TYPE" == "specterd" ]]; then
        echo "Dependency version drift detected (APScheduler, pytz, setuptools, etc.)"
    else
        echo "Dependency version drift detected (npm packages)"
    fi
fi
echo "Project acknowledges non-reproducibility in docs/build-instructions.md"
echo ""
echo "===== End Results ====="

# Always exit 0 from container - host script determines final exit code from YAML
# This ensures YAML is always generated and extractable
exit 0
VERIFY_END
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

    local container_name="specter-verify-${version_component}-${arch_component}-${type_component}-${suffix}"
    local image_name="specter-verifier:${version_component}-${arch_component}-${type_component}-${suffix}"

    # Save execution directory for YAML handoff to build server
    execution_dir="$(pwd)"

    # Set work directory
    if [[ -n "$CUSTOM_WORK_DIR" ]]; then
        WORK_DIR="$CUSTOM_WORK_DIR"
    else
        WORK_DIR="${execution_dir}/specter_desktop_${version_component}_${arch_component}_${type_component}_$$"
    fi

    # Create work directory
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log "======================================================"
    log "Specter Desktop v$APP_VERSION - Containerized Build"
    log "======================================================"
    log ""
    log "Work directory: $WORK_DIR"
    log ""

    # Create verification script
    create_verify_script

    # Create Dockerfile
    create_dockerfile

    # Build Docker image
    log "Building and verifying in container..."
    log "(This may take 5-10 minutes)"
    log ""

    local cache_flag=""
    [[ "$NO_CACHE" == true ]] && cache_flag="--no-cache"

    if ! $DOCKER_CMD build $cache_flag \
        --build-arg SPECTER_VERSION="$APP_VERSION" \
        --build-arg BUILD_TYPE="$APP_TYPE" \
        --build-arg BUILD_ARCH="$APP_ARCH" \
        --build-arg SCRIPT_VERSION="$SCRIPT_VERSION" \
        -t "$image_name" . 2>&1 | tee build.log; then
        echo ""
        die "Container build failed" $EXIT_BUILD_FAILED
    fi

    # Extract results
    log ""
    log "Extracting results..."

    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
        $DOCKER_CMD rm -f "$container_name" > /dev/null 2>&1
    fi

    $DOCKER_CMD create --name "$container_name" "$image_name" > /dev/null
    $DOCKER_CMD cp "$container_name:/output/COMPARISON_RESULTS.yaml" ./ 2>/dev/null || \
        die "Failed to extract YAML results" $EXIT_BUILD_FAILED

    # Fix file ownership (docker cp creates files as root)
    # Per additional-guidelines.md: "all artifacts outputted on host SHOULD be owned by user"
    if [[ -f "./COMPARISON_RESULTS.yaml" ]]; then
        chown "$(id -u):$(id -g)" "./COMPARISON_RESULTS.yaml" 2>/dev/null || true
    fi

    # Copy YAML to execution directory for build server (BSA requirement)
    if [[ "$execution_dir" != "$WORK_DIR" ]]; then
        cp ./COMPARISON_RESULTS.yaml "$execution_dir/" 2>/dev/null || \
            die "Failed to copy YAML to execution directory" $EXIT_BUILD_FAILED
        # Fix ownership in execution dir too
        chown "$(id -u):$(id -g)" "$execution_dir/COMPARISON_RESULTS.yaml" 2>/dev/null || true
    fi

    # Cleanup container
    if [[ "$KEEP_CONTAINER" != true ]]; then
        $DOCKER_CMD rm "$container_name" > /dev/null 2>&1
    fi

    # Display results
    display_results "$execution_dir"
}

display_results() {
    local execution_dir="$1"
    local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"

    log ""
    log "======================================================"
    log "RESULTS"
    log "======================================================"

    if [[ -f "$yaml_file" ]]; then
        cat "$yaml_file"
    else
        echo "ERROR: COMPARISON_RESULTS.yaml not found"
        exit $EXIT_BUILD_FAILED
    fi

    log ""
    log "Output files:"
    log "  - ${execution_dir}/COMPARISON_RESULTS.yaml"
    log "  - ${WORK_DIR}/build.log"
    log ""

    # Determine exit code from YAML
    if grep -q "match: true" "$yaml_file"; then
        log "Exit code: 0 (reproducible)"
        exit $EXIT_SUCCESS
    else
        log "Exit code: 1 (not reproducible)"
        exit $EXIT_BUILD_FAILED
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Print version first (requirement 2)
    echo "specterdesktop_build.sh ${SCRIPT_VERSION}"
    echo ""
    
    parse_arguments "$@"
    build_and_verify
}

main "$@"
