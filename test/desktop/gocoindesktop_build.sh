#!/usr/bin/env bash
# ==============================================================================
# gocoindesktop_build.sh - Gocoin Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.1
# Organization:  WalletScrutiny.com
# Last Modified: 2026-01-27
# Project:       https://github.com/piotrnar/gocoin
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
# - Downloads official Gocoin release from GitHub releases
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using Go toolchain
# - Builds client (full node) and wallet (CLI wallet) binaries
# - Compares checksums between official and built binaries
# - Generates COMPARISON_RESULTS.yaml for build server automation

set -euo pipefail

# Script metadata
SCRIPT_VERSION="v0.1.1"
SCRIPT_NAME="gocoindesktop_build.sh"
APP_NAME="Gocoin"
APP_ID="gocoin"
REPO_URL="https://github.com/piotrnar/gocoin"

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

# ---------- Usage ----------
usage() {
    cat <<EOF
${APP_NAME} Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>]

Required Parameters:
  --version <version>    Gocoin version to verify (e.g., 1.11.0)

Optional Parameters:
  --arch <arch>          Target architecture (default: linux-amd64)
                         Supported: linux-amd64, macos-amd64, win64
  --type <type>          Not used for Gocoin (exit 2 if provided)
  --apk <path>           Not used for desktop builds (exit 2 if provided)
  --help                 Show this help message

Examples:
  $(basename "$0") --version 1.11.0
  $(basename "$0") --version 1.11.0 --arch linux-amd64
  $(basename "$0") --version 1.11.0 --arch macos-amd64

Output:
  Creates directory: ./gocoin_<version>_<arch>_<pid>/
  Results file:      ./COMPARISON_RESULTS.yaml

Exit Codes:
  0 - Reproducible (all hashes match)
  1 - Not reproducible (hashes differ or build failed)
  2 - Invalid parameters

Requirements:
  - Docker or Podman installed
  - Internet connection for downloading sources and official releases

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parameter Parsing ----------
version=""
arch="linux-amd64"
build_type=""
apk_path=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--version requires a value"
                exit 2
            fi
            version="$2"
            shift 2
            ;;
        --arch)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--arch requires a value"
                exit 2
            fi
            arch="$2"
            shift 2
            ;;
        --type)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--type requires a value"
                exit 2
            fi
            build_type="$2"
            shift 2
            ;;
        --apk)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--apk requires a value"
                exit 2
            fi
            apk_path="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown parameter: $1"
            usage
            exit 2
            ;;
    esac
done

# ---------- Validate Parameters ----------
if [[ -z "$version" ]]; then
    log_error "Missing required parameter: --version"
    echo "Run '$(basename "$0") --help' for usage information."
    exit 2
fi

if [[ -n "$build_type" ]]; then
    log_error "Unsupported parameter: --type ${build_type}"
    log_error "Gocoin desktop build does not use --type parameter"
    exit 2
fi

if [[ -n "$apk_path" ]]; then
    log_error "Unsupported parameter: --apk ${apk_path}"
    log_error "Desktop builds do not use --apk parameter"
    exit 2
fi

# Validate architecture
case "$arch" in
    linux-amd64)
        RELEASE_FILE="gocoin-${version}-linux-amd64.tar.gz"
        GO_OS="linux"
        GO_ARCH="amd64"
        ;;
    macos-amd64)
        RELEASE_FILE="gocoin-${version}-macos-amd64.tar.gz"
        GO_OS="darwin"
        GO_ARCH="amd64"
        ;;
    win64|windows)
        RELEASE_FILE="gocoin-${version}-win.zip"
        GO_OS="windows"
        GO_ARCH="amd64"
        arch="win64"
        ;;
    *)
        log_error "Unsupported architecture: $arch"
        log_error "Supported: linux-amd64, macos-amd64, win64"
        exit 2
        ;;
esac

# ---------- Setup Workspace ----------
EXECUTION_DIR="$(pwd)"
WORKSPACE="${EXECUTION_DIR}/gocoin_${version}_${arch}_$$"
mkdir -p "${WORKSPACE}"
cd "${WORKSPACE}"

log_info "=============================================="
log_info "${APP_NAME} ${version} Verification"
log_info "=============================================="
log_info "Script version: ${SCRIPT_VERSION}"
log_info "Architecture: ${arch}"
log_info "Workspace: ${WORKSPACE}"
log_info ""

# ---------- Detect Container Runtime ----------
CONTAINER_CMD=""
if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
else
    log_error "Neither podman nor docker found. Please install one of them."
    exit 1
fi
log_info "Using container runtime: ${CONTAINER_CMD}"

# ---------- Unique Container/Image Names ----------
TIMESTAMP=$(date +%s)
CONTAINER_NAME="ws-gocoin-${version}-${arch}-${TIMESTAMP}-$$"
IMAGE_NAME="ws-gocoin-image-${version}-${arch}-${TIMESTAMP}-$$"

# ---------- Cleanup Function ----------
cleanup() {
    local exit_code=$?
    if [[ -n "${CONTAINER_NAME:-}" ]]; then
        ${CONTAINER_CMD} rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    fi
    if [[ -n "${IMAGE_NAME:-}" ]]; then
        ${CONTAINER_CMD} rmi -f "${IMAGE_NAME}" 2>/dev/null || true
    fi
    return $exit_code
}
trap cleanup EXIT

# ---------- Generate Error YAML ----------
generate_error_yaml() {
    local error_msg="$1"
    local status="${2:-ftbfs}"

    cat > "${EXECUTION_DIR}/COMPARISON_RESULTS.yaml" << EOF
date: $(date -u '+%Y-%m-%dT%H:%M:%S+0000')
script_version: ${SCRIPT_VERSION}
build_type: tarball
results:
  - architecture: ${arch}
    status: ${status}
    error: ${error_msg}
    files: []
EOF
}

# ---------- Create Dockerfile ----------
log_info "Creating Dockerfile (network and build happen inside container)..."
cat > "${WORKSPACE}/Dockerfile" << 'DOCKERFILE'
FROM docker.io/golang:1.22-bookworm

# Install build dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-lc"]

WORKDIR /work

# Build arguments
ARG VERSION
ARG RELEASE_FILE
ARG REPO_URL
ARG GOOS=linux
ARG GOARCH=amd64

ENV GOOS=${GOOS}
ENV GOARCH=${GOARCH}

# Download official release, clone source, build, and prepare outputs.
# Use POSIX sh syntax because some build runtimes ignore the SHELL directive.
RUN set -eu; \
    mkdir -p /work/official /work/official-extracted /work/source /work/built; \
    OFFICIAL_URL="https://github.com/piotrnar/gocoin/releases/download/${VERSION}/${RELEASE_FILE}"; \
    curl -fSL -o "/work/official/${RELEASE_FILE}" "${OFFICIAL_URL}"; \
    case "${RELEASE_FILE}" in \
        *.zip) unzip -q "/work/official/${RELEASE_FILE}" -d /work/official-extracted ;; \
        *) tar -xzf "/work/official/${RELEASE_FILE}" -C /work/official-extracted ;; \
    esac; \
    OFFICIAL_BIN_DIR="$(find /work/official-extracted -type d -name 'gocoin*' | head -1)"; \
    if [ -z "${OFFICIAL_BIN_DIR}" ]; then OFFICIAL_BIN_DIR="/work/official-extracted"; fi; \
    if [ "${GOOS}" = "windows" ]; then CLIENT_BIN="client.exe"; WALLET_BIN="wallet.exe"; else CLIENT_BIN="client"; WALLET_BIN="wallet"; fi; \
    if ! git clone --depth 1 --branch "${VERSION}" "${REPO_URL}" /work/source 2>/dev/null; then \
        git clone --depth 1 --branch "v${VERSION}" "${REPO_URL}" /work/source; \
    fi; \
    if [ "${GOOS}" != "linux" ]; then export CGO_ENABLED=0; fi; \
    (cd /work/source/client && go build -o "/work/built/${CLIENT_BIN}" .); \
    (cd /work/source/wallet && go build -o "/work/built/${WALLET_BIN}" .); \
    mkdir -p /output/official /output/built; \
    OFFICIAL_CLIENT="$(find "${OFFICIAL_BIN_DIR}" -name "${CLIENT_BIN}" -type f 2>/dev/null | head -1)"; \
    OFFICIAL_WALLET="$(find "${OFFICIAL_BIN_DIR}" -name "${WALLET_BIN}" -type f 2>/dev/null | head -1)"; \
    if [ -n "${OFFICIAL_CLIENT:-}" ] && [ -f "${OFFICIAL_CLIENT}" ]; then cp "${OFFICIAL_CLIENT}" "/output/official/${CLIENT_BIN}"; fi; \
    if [ -n "${OFFICIAL_WALLET:-}" ] && [ -f "${OFFICIAL_WALLET}" ]; then cp "${OFFICIAL_WALLET}" "/output/official/${WALLET_BIN}"; fi; \
    cp "/work/built/${CLIENT_BIN}" "/output/built/${CLIENT_BIN}"; \
    cp "/work/built/${WALLET_BIN}" "/output/built/${WALLET_BIN}"; \
    { \
      if [ -f "/output/official/${CLIENT_BIN}" ]; then echo "official_client $(sha256sum "/output/official/${CLIENT_BIN}" | awk '{print $1}')"; else echo "official_client NOT_FOUND"; fi; \
      echo "built_client $(sha256sum "/output/built/${CLIENT_BIN}" | awk '{print $1}')"; \
      if [ -f "/output/official/${WALLET_BIN}" ]; then echo "official_wallet $(sha256sum "/output/official/${WALLET_BIN}" | awk '{print $1}')"; else echo "official_wallet NOT_FOUND"; fi; \
      echo "built_wallet $(sha256sum "/output/built/${WALLET_BIN}" | awk '{print $1}')"; \
    } > /output/hashes.txt; \
    chmod -R a+rX /output

# Set permissions for rootless containers
RUN chmod -R a+rX /output/

CMD ["cp", "-a", "/output/.", "/artifacts/"]
DOCKERFILE

# ---------- Build Container Image ----------
log_info "Building container image..."
log_info "This may take a few minutes..."

if ! ${CONTAINER_CMD} build \
    --build-arg VERSION="${version}" \
    --build-arg RELEASE_FILE="${RELEASE_FILE}" \
    --build-arg REPO_URL="${REPO_URL}" \
    --build-arg GOOS="${GO_OS}" \
    --build-arg GOARCH="${GO_ARCH}" \
    -t "${IMAGE_NAME}" \
    -f "${WORKSPACE}/Dockerfile" \
    "${WORKSPACE}"; then
    log_error "Container build failed"
    generate_error_yaml "Container build failed" "ftbfs"
    exit 1
fi
log_success "Container image built: ${IMAGE_NAME}"

# ---------- Run Build ----------
log_info "Running build..."
ARTIFACTS_DIR="${WORKSPACE}/artifacts"
mkdir -p "${ARTIFACTS_DIR}"

if ! ${CONTAINER_CMD} run --rm \
    --name "${CONTAINER_NAME}" \
    -v "${ARTIFACTS_DIR}:/artifacts:Z" \
    "${IMAGE_NAME}"; then
    log_error "Build execution failed"
    generate_error_yaml "Build execution failed" "ftbfs"
    exit 1
fi
log_success "Build completed"

# ---------- Compare Binaries ----------
log_info "Comparing binaries..."

# Determine binary names based on platform
if [[ "${GO_OS}" == "windows" ]]; then
    CLIENT_BIN="client.exe"
    WALLET_BIN="wallet.exe"
else
    CLIENT_BIN="client"
    WALLET_BIN="wallet"
fi

# Verify container outputs exist
if [[ ! -f "${ARTIFACTS_DIR}/built/${CLIENT_BIN}" ]]; then
    log_error "Built client binary not found in container output"
    generate_error_yaml "Built client binary not found" "ftbfs"
    exit 1
fi

if [[ ! -f "${ARTIFACTS_DIR}/built/${WALLET_BIN}" ]]; then
    log_error "Built wallet binary not found in container output"
    generate_error_yaml "Built wallet binary not found" "ftbfs"
    exit 1
fi

if [[ ! -f "${ARTIFACTS_DIR}/hashes.txt" ]]; then
    log_error "hashes.txt not found in container output"
    generate_error_yaml "Container did not produce hashes.txt" "ftbfs"
    exit 1
fi

# Read hashes produced inside the container
get_hash() {
    local key="$1"
    awk -v k="$key" '$1==k {print $2}' "${ARTIFACTS_DIR}/hashes.txt" | head -1
}

OFFICIAL_CLIENT_HASH="$(get_hash official_client)"
BUILT_CLIENT_HASH="$(get_hash built_client)"
OFFICIAL_WALLET_HASH="$(get_hash official_wallet)"
BUILT_WALLET_HASH="$(get_hash built_wallet)"

# Record paths for diff/size analysis
OFFICIAL_CLIENT="${ARTIFACTS_DIR}/official/${CLIENT_BIN}"
OFFICIAL_WALLET="${ARTIFACTS_DIR}/official/${WALLET_BIN}"
BUILT_CLIENT="${ARTIFACTS_DIR}/built/${CLIENT_BIN}"
BUILT_WALLET="${ARTIFACTS_DIR}/built/${WALLET_BIN}"

if [[ "${OFFICIAL_CLIENT_HASH}" == "NOT_FOUND" || -z "${OFFICIAL_CLIENT_HASH}" ]]; then
    log_error "Official client binary not found in release archive"
    generate_error_yaml "Official client binary not found in release archive" "nosource"
    exit 1
fi

if [[ "${OFFICIAL_WALLET_HASH}" == "NOT_FOUND" || -z "${OFFICIAL_WALLET_HASH}" ]]; then
    log_error "Official wallet binary not found in release archive"
    generate_error_yaml "Official wallet binary not found in release archive" "nosource"
    exit 1
fi

# Determine match status
CLIENT_MATCH="false"
WALLET_MATCH="false"
OVERALL_STATUS="not_reproducible"

if [[ "${BUILT_CLIENT_HASH}" == "${OFFICIAL_CLIENT_HASH}" ]]; then
    CLIENT_MATCH="true"
    log_success "Client binary: MATCH"
else
    log_warn "Client binary: MISMATCH"
fi

if [[ "${BUILT_WALLET_HASH}" == "${OFFICIAL_WALLET_HASH}" ]]; then
    WALLET_MATCH="true"
    log_success "Wallet binary: MATCH"
else
    log_warn "Wallet binary: MISMATCH"
fi

if [[ "${CLIENT_MATCH}" == "true" ]] && [[ "${WALLET_MATCH}" == "true" ]]; then
    OVERALL_STATUS="reproducible"
fi

# ---------- Generate Results ----------
echo ""
echo "=============================================="
echo "          VERIFICATION RESULTS"
echo "=============================================="
echo "App:            ${APP_NAME}"
echo "Version:        ${version}"
echo "Architecture:   ${arch}"
echo "Script:         ${SCRIPT_VERSION}"
echo "----------------------------------------------"
echo "CLIENT BINARY:"
echo "  Official:     ${OFFICIAL_CLIENT_HASH}"
echo "  Built:        ${BUILT_CLIENT_HASH}"
echo "  Match:        ${CLIENT_MATCH}"
echo "----------------------------------------------"
echo "WALLET BINARY:"
echo "  Official:     ${OFFICIAL_WALLET_HASH}"
echo "  Built:        ${BUILT_WALLET_HASH}"
echo "  Match:        ${WALLET_MATCH}"
echo "----------------------------------------------"
echo "Overall:        ${OVERALL_STATUS}"
echo "=============================================="

# ---------- Generate COMPARISON_RESULTS.yaml ----------
RESULTS_FILE="${EXECUTION_DIR}/COMPARISON_RESULTS.yaml"
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S+0000')

cat > "${RESULTS_FILE}" << EOF
date: ${TIMESTAMP}
script_version: ${SCRIPT_VERSION}
build_type: tarball
results:
  - architecture: ${arch}
    status: ${OVERALL_STATUS}
    files:
      - filename: ${CLIENT_BIN}
        hash: ${BUILT_CLIENT_HASH}
        match: ${CLIENT_MATCH}
      - filename: ${WALLET_BIN}
        hash: ${BUILT_WALLET_HASH}
        match: ${WALLET_MATCH}
EOF

log_info "Results written to: ${RESULTS_FILE}"

# ---------- Standardized Output Format ----------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${OVERALL_STATUS}"
echo "appHash:        ${OFFICIAL_CLIENT_HASH}"
echo "commit:         ${version}"
echo ""
echo "Diff:"
if [[ "${OVERALL_STATUS}" == "reproducible" ]]; then
    echo "BUILDS MATCH BINARIES"
else
    echo "BUILDS DO NOT MATCH BINARIES"
fi
echo ""
echo "${CLIENT_BIN} - ${arch} - ${BUILT_CLIENT_HASH} - $([ "${CLIENT_MATCH}" == "true" ] && echo "1 (MATCHES)" || echo "0 (DOESN'T MATCH)")"
echo "${WALLET_BIN} - ${arch} - ${BUILT_WALLET_HASH} - $([ "${WALLET_MATCH}" == "true" ] && echo "1 (MATCHES)" || echo "0 (DOESN'T MATCH)")"
echo ""
echo "Revision, tag (and its signature):"
echo "Git tag: ${version}"
echo ""
echo "===== End Results ====="
echo ""

# ---------- Exit with appropriate code ----------
if [[ "${OVERALL_STATUS}" == "reproducible" ]]; then
    log_success "Verdict: REPRODUCIBLE"
    exit 0
else
    log_warn "Verdict: NOT REPRODUCIBLE"

    # Additional diff analysis for debugging
    echo ""
    log_info "Generating diff analysis..."
    echo "Binary sizes:"
    echo "  Official client: $(stat -c%s "${OFFICIAL_CLIENT}" 2>/dev/null || echo "N/A") bytes"
    echo "  Built client:    $(stat -c%s "${BUILT_CLIENT}" 2>/dev/null || echo "N/A") bytes"
    echo "  Official wallet: $(stat -c%s "${OFFICIAL_WALLET}" 2>/dev/null || echo "N/A") bytes"
    echo "  Built wallet:    $(stat -c%s "${BUILT_WALLET}" 2>/dev/null || echo "N/A") bytes"

    exit 1
fi
