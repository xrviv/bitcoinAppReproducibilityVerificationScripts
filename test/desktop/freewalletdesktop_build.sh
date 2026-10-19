#!/usr/bin/env bash
# ==============================================================================
# freewalletdesktop_build.sh - FreeWallet Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.5.2 (Fixed permissions, tarball structure, binary rename)
# Last Modified: 2026-01-20
# Organization:  WalletScrutiny.com
# ==============================================================================

set -euo pipefail

NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
SUCCESS_ICON="[OK]"
INFO_ICON="[INFO]"

APP_NAME="FreeWallet Desktop"
SCRIPT_VERSION="v0.5.2"
REPO_URL="https://github.com/jdogresorg/freewallet-desktop"

log_info() { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- Help ----------
show_help() {
    cat <<EOF
${APP_NAME} - Reproducible Build Verification Script
Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com

USAGE:
    $0 --version <version> [--arch <arch>]

REQUIRED:
    --version <version>   App version to verify (e.g., 2.0.4)

OPTIONAL:
    --arch <arch>         Target architecture (default: linux64)
                          Supported: linux64 (linux32 not yet implemented)
    --type <type>         Not supported for this desktop build (will exit 2)
    --apk <path>          Not supported for this desktop build (will exit 2)
    --help                Show this help message

EXAMPLES:
    $0 --version 2.0.4
    $0 --version 2.0.4 --arch linux64

OUTPUT:
    Creates directory: ./freewallet_<version>_<arch>/
    Results file:      ./COMPARISON_RESULTS.yaml

EXIT CODES:
    0 - Reproducible (hashes match)
    1 - Not reproducible (hashes differ or build failed)
    2 - Invalid parameters

NOTES:
    - Requires podman or docker
    - Official builds are created on macOS; Linux builds will have
      hash mismatch due to missing ._* Apple Double metadata files
    - App source code can still be verified as identical

EOF
    exit 0
}

# ---------- Parameters ----------
version=""
arch="linux64"
app_type=""
apk_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--version requires a value"
                exit 2
            fi
            version="$2"; shift 2 ;;
        --arch)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--arch requires a value"
                exit 2
            fi
            arch="$2"; shift 2 ;;
        --type)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--type requires a value"
                exit 2
            fi
            app_type="$2"; shift 2 ;;
        --apk)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                log_error "--apk requires a value"
                exit 2
            fi
            apk_path="$2"; shift 2 ;;
        --help|-h) show_help ;;
        *) shift ;;
    esac
done

if [[ -z "$version" ]]; then
    log_error "Missing required parameter: --version"
    echo "Run '$0 --help' for usage information."
    exit 2
fi
if [[ -n "${app_type}" ]]; then
    log_error "Unsupported parameter: --type ${app_type}"
    log_error "This desktop build does not accept --type"
    exit 2
fi
if [[ -n "${apk_path}" ]]; then
    log_error "Unsupported parameter: --apk ${apk_path}"
    log_error "This desktop build does not accept --apk"
    exit 2
fi

# ---------- Validate arch parameter ----------
case "$arch" in
    linux64|linux32)
        # Valid architecture
        ;;
    *)
        log_error "Invalid architecture: $arch"
        log_error "Supported: linux64, linux32"
        exit 2
        ;;
esac

# ---------- Setup ----------
EXECUTION_DIR="$(pwd)"
WORK_DIR="${EXECUTION_DIR}/freewallet_${version}_${arch}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

CONTAINER_CMD="docker"
if command -v podman &>/dev/null; then CONTAINER_CMD="podman"; fi

# ---------- Build Config ----------
case "$arch" in
    linux64) nw_arch="x64" ;;
    linux32) nw_arch="ia32" ;;
esac

# NW.js 0.92.0 confirmed from official v2.0.4 build analysis (2026-01-19)
nw_ver="0.92.0"
nw_file="nwjs-sdk-v${nw_ver}-linux-${nw_arch}.tar.gz"
nw_url="https://dl.nwjs.io/v${nw_ver}/${nw_file}"
# SHA256 checksums for NW.js SDK (from dl.nwjs.io/v0.92.0/SHASUMS256.txt)
case "$arch" in
    linux64) nw_sha256="77dffb987c4fcc7939bdde2a0ddceb58ff2ceb3529835d7fb2397f308cd53bf8" ;;
    linux32)
        log_error "linux32 not yet supported (NW.js checksum not verified)"
        exit 2 ;;
esac

# ---------- Fetch ----------
OFFICIAL_DIR="${WORK_DIR}/official"
RELEASE_FILE="FreeWallet.${arch}.tgz"

log_info "Fetching sources and official release..."
${CONTAINER_CMD} run --rm -v "${WORK_DIR}:/work:Z" -w /work debian:bookworm-slim bash -c "
    apt-get update && apt-get install -y git curl ca-certificates xz-utils >/dev/null 2>&1
    mkdir -p official source
    echo '### Downloading official release...'
    curl -fSL -o \"official/${RELEASE_FILE}\" \"https://github.com/jdogresorg/freewallet-desktop/releases/download/v${version}/${RELEASE_FILE}\"
    echo '### Cloning source repository...'
    git clone --depth 1 --branch \"v${version}\" \"${REPO_URL}\" source
"

log_info "Creating Dockerfile..."
cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE'
FROM node:20-bullseye

RUN apt-get update && apt-get install -y curl xz-utils zip && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY source/ /app/

# Setup App: copy source files and install npm dependencies
RUN mkdir -p build && cp -a css html images js index.html package.json build/
RUN cd build && npm install

DOCKERFILE

# Append build steps with variable substitution
cat >> "${WORK_DIR}/Dockerfile" <<DOCKERFILE
# --- MANUAL BUILD (bypasses nw-builder entirely) ---
# nw-builder/node-tar has TAR_BAD_ARCHIVE issues with NW.js SDK archives
# Solution: Use system tar + manual file assembly

# 1. Download and verify NW.js SDK
RUN curl -fSL "${nw_url}" -o /tmp/nwjs.tar.gz && \\
    echo "${nw_sha256}  /tmp/nwjs.tar.gz" | sha256sum -c -

# 2. Extract NW.js to builds/FreeWallet/ (matching official structure)
RUN mkdir -p builds/FreeWallet && \\
    tar -xzf /tmp/nwjs.tar.gz -C builds/FreeWallet --strip-components=1 && \\
    rm /tmp/nwjs.tar.gz

# 3. Fix permissions (NW.js SDK files have restricted perms)
#    a+rX = read for all files, execute for directories (allows traversal)
RUN chmod -R a+rX builds/FreeWallet/

# 4. Create app.nw (ZIP of app files) - NW.js concatenation method
#    The official build embeds app files INTO the binary, not alongside it
RUN cd build && zip -r ../app.nw . && cd ..

# 5. Concatenate app.nw to nw binary to create FreeWallet (matches official)
#    This is how nw-builder creates the final executable
RUN cat builds/FreeWallet/nw app.nw > builds/FreeWallet/FreeWallet && \\
    rm builds/FreeWallet/nw app.nw

# 6. Remove app files that are now embedded (official doesn't have these loose)
RUN rm -rf builds/FreeWallet/package.json 2>/dev/null || true

# 7. Copy helper files from misc/ (install.sh, .desktop, .png)
RUN cp misc/FreeWallet.desktop misc/FreeWallet.png misc/install.sh builds/FreeWallet/

# 8. Set executable permissions
RUN chmod +x builds/FreeWallet/FreeWallet builds/FreeWallet/install.sh

# 9. Final permission fix - ensure ALL files are readable/writable by anyone
#    Critical for rootless podman: files must be accessible after UID remapping
RUN chmod -R a+rwX builds/

WORKDIR /app/builds
CMD ["/bin/bash", "-c", "cp -a FreeWallet /output/"]
DOCKERFILE

# ---------- Build ----------
log_info "Building image..."
${CONTAINER_CMD} build -t "freewallet-v${version}" .

log_info "Running build..."
BUILD_OUT="${WORK_DIR}/build-output"
mkdir -p "${BUILD_OUT}"
${CONTAINER_CMD} run --rm -v "${BUILD_OUT}:/output:Z" "freewallet-v${version}"

# ---------- Package ----------
log_info "Packaging build..."
cd "${BUILD_OUT}"
# Create tarball with FreeWallet/ at top level (matching official structure)
tar -czvf "${RELEASE_FILE}" FreeWallet

# ---------- Compare ----------
log_info "Comparing hashes..."
BUILT_HASH=$(sha256sum "${BUILD_OUT}/${RELEASE_FILE}" | awk '{print $1}')
OFFICIAL_HASH=$(sha256sum "${OFFICIAL_DIR}/${RELEASE_FILE}" | awk '{print $1}')

echo ""
echo "============================================================"
echo "                    VERIFICATION RESULTS"
echo "============================================================"
echo "App:      ${APP_NAME}"
echo "Version:  ${version}"
echo "Arch:     ${arch}"
echo "Script:   ${SCRIPT_VERSION}"
echo "------------------------------------------------------------"
echo "Official: ${OFFICIAL_HASH}"
echo "Built:    ${BUILT_HASH}"
echo "------------------------------------------------------------"

# ---------- Generate COMPARISON_RESULTS.yaml ----------
RESULTS_FILE="${EXECUTION_DIR}/COMPARISON_RESULTS.yaml"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")

if [[ "$BUILT_HASH" == "$OFFICIAL_HASH" ]]; then
    MATCH_STATUS="true"
    VERDICT_STATUS="reproducible"
    log_success "REPRODUCIBLE - Hashes match!"
else
    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
    log_warn "NOT REPRODUCIBLE - Hashes differ"
fi

# Generate YAML output per script_verifications.md spec
cat > "${RESULTS_FILE}" <<EOF
date: ${TIMESTAMP}
script_version: ${SCRIPT_VERSION}
build_type: standalone
results:
  - architecture: ${arch}
    status: ${VERDICT_STATUS}
    files:
      - filename: ${RELEASE_FILE}
        hash: ${BUILT_HASH}
        match: ${MATCH_STATUS}
EOF

echo "============================================================"
echo "Results written to: ${RESULTS_FILE}"

if [[ "$MATCH_STATUS" == "false" ]]; then
    echo ""
    echo "Extracting tarballs for diff analysis..."

    # Extract both for comparison
    mkdir -p "${WORK_DIR}/comparison/official" "${WORK_DIR}/comparison/built"
    tar -xzf "${OFFICIAL_DIR}/${RELEASE_FILE}" -C "${WORK_DIR}/comparison/official"
    tar -xzf "${BUILD_OUT}/${RELEASE_FILE}" -C "${WORK_DIR}/comparison/built"

    echo ""
    echo "Diff summary (first 50 lines):"
    echo "------------------------------------------------------------"
    diff -rq "${WORK_DIR}/comparison/official" "${WORK_DIR}/comparison/built" 2>/dev/null | head -50 || true
    echo "------------------------------------------------------------"
    echo ""
    echo "Full diff saved to: ${WORK_DIR}/comparison/"
    diff -r "${WORK_DIR}/comparison/official" "${WORK_DIR}/comparison/built" > "${WORK_DIR}/comparison/full-diff.txt" 2>&1 || true
    echo "============================================================"
    exit 1
fi

echo "============================================================"
exit 0
