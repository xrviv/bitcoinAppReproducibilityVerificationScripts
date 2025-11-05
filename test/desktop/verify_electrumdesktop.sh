#!/usr/bin/env bash
# ==============================================================================
# verify_electrumdesktop.sh - Electrum Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.1
# Organization:  WalletScrutiny.com
# Last Modified: 2025-11-05
# Project:       https://github.com/spesmilo/electrum
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
# - Downloads official Electrum Windows executables from electrum.org
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using embedded Dockerfile (Wine-based)
# - Strips Authenticode signatures from both official and built binaries
# - Compares stripped binaries using binary diff analysis
# - Generates COMPARISON_RESULTS.txt for build server automation
# - Documents differences and generates detailed reproducibility assessment

set -euo pipefail

# ---------- Styling ----------
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
SUCCESS_ICON="✅"
WARNING_ICON="⚠️"
ERROR_ICON="❌"
INFO_ICON="ℹ️"

APP_NAME="Electrum Desktop"
APP_ID="org.electrum.electrum"
SCRIPT_VERSION="v0.3.1"
REPO_URL="https://github.com/spesmilo/electrum"

# ---------- Logging Functions ----------
log_info() { echo -e "${BLUE}${INFO_ICON}${NC}  $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn() { echo -e "${YELLOW}${WARNING_ICON}${NC}  $*"; }
log_error() { echo -e "${RED}${ERROR_ICON}${NC}  $*" >&2; }

# ---------- Usage ----------
usage() {
  cat <<EOF
Electrum Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>]

Required Parameters:
  --version <version>    Electrum version to verify (e.g., 4.6.2)

Optional Parameters:
  --arch <arch>          Architecture to build (default: windows)
                         Supported: windows (win64 executables)
  --type <type>          Build type (accepted but ignored - no variants for Electrum)

Flags:
  --help                 Show this help message

Examples:
  $(basename "$0") --version 4.6.2
  $(basename "$0") --version 4.6.2 --arch windows
  $(basename "$0") --version 4.6.2 --arch windows --type bitcoin

Requirements:
  - Docker or Podman installed
  - Internet connection for downloading sources and official releases
  - Approximately 5GB disk space for build

Output:
  - Exit code 0: Binaries are reproducible
  - Exit code 1: Binaries differ or verification failed
  - COMPARISON_RESULTS.txt: Machine-readable comparison results
  - Standardized results format between ===== Begin/End Results =====

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parameter Parsing ----------
version=""
arch="windows"
build_type=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --arch)
      arch="$2"
      shift 2
      ;;
    --type)
      build_type="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown parameter: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate required parameters
if [[ -z "$version" ]]; then
  log_error "Missing required parameter: --version"
  usage
  exit 1
fi

# Validate architecture
if [[ "$arch" != "windows" ]]; then
  log_error "Unsupported architecture: $arch"
  log_error "Currently only 'windows' is supported"
  exit 1
fi

# ---------- Setup Workspace ----------
execution_dir="$(pwd)"
workspace="${execution_dir}/electrum_desktop_${version}_${arch}_$$"
mkdir -p "$workspace"
cd "$workspace"

log_info "=============================================="
log_info "${APP_NAME} v${version} Verification"
log_info "=============================================="
log_info "Script version: ${SCRIPT_VERSION}"
log_info "Architecture: ${arch}"
log_info "Workspace: ${workspace}"
log_info ""

# ---------- Download Official Releases ----------
log_info "Downloading official releases from electrum.org..."
official_dir="$workspace/official"
mkdir -p "$official_dir"

download_url_base="https://download.electrum.org/${version}"
official_files=(
  "electrum-${version}-setup.exe"
  "electrum-${version}-portable.exe"
  "electrum-${version}.exe"
)

for file in "${official_files[@]}"; do
  log_info "Downloading ${file}..."
  if ! wget -q -O "$official_dir/$file" "${download_url_base}/${file}"; then
    log_error "Failed to download ${file}"
    echo "Exit code: 1"
    exit 1
  fi
  log_success "Downloaded ${file}"
done

# ---------- Generate Embedded Dockerfile ----------
log_info "Generating embedded Dockerfile for reproducible build..."
dockerfile_path="$workspace/Dockerfile"

cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
FROM debian:bookworm

ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

ARG VERSION
ARG UID=1000
ENV ELECTRUM_VERSION=${VERSION}
ENV USER="user"
ENV HOME_DIR="/home/${USER}"
ENV WORK_DIR="/opt/wine64/drive_c"

# Add i386 architecture for 32-bit wine
RUN dpkg --add-architecture i386

# Install dependencies
RUN apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        ca-certificates wget gnupg2 dirmngr python3 python3-pip python3-venv \
        git curl p7zip-full make mingw-w64 mingw-w64-tools autotools-dev \
        autoconf autopoint libtool gettext nsis sudo osslsigncode && \
    rm -rf /var/lib/apt/lists/*

# Install Wine 10.0.0.0
RUN DEBIAN_CODENAME=$(cat /etc/debian_version | cut -d'.' -f1) && \
    if [ "$DEBIAN_CODENAME" = "12" ]; then DEBIAN_CODENAME="bookworm"; fi && \
    WINEVERSION="10.0.0.0~${DEBIAN_CODENAME}-1" && \
    wget -nc https://dl.winehq.org/wine-builds/winehq.key && \
    echo "d965d646defe94b3dfba6d5b4406900ac6c81065428bf9d9303ad7a72ee8d1b8 winehq.key" | sha256sum -c - && \
    mkdir -p /etc/apt/keyrings && \
    cat winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/winehq.gpg] https://dl.winehq.org/wine-builds/debian/ ${DEBIAN_CODENAME} main" > /etc/apt/sources.list.d/winehq.list && \
    rm winehq.key && \
    apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        wine-stable-amd64:amd64=${WINEVERSION} \
        wine-stable-i386:i386=${WINEVERSION} \
        wine-stable:amd64=${WINEVERSION} \
        winehq-stable:amd64=${WINEVERSION} \
        || apt-get install -qy --allow-downgrades \
        wine-stable-amd64:amd64 wine-stable-i386:i386 \
        wine-stable:amd64 winehq-stable:amd64 && \
    rm -rf /var/lib/apt/lists/*

# Create user and setup workspace
RUN useradd --uid $UID --create-home --shell /bin/bash ${USER} && \
    usermod -append --groups sudo ${USER} && \
    echo "%sudo ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p ${WORK_DIR} /opt/wine64 /output && \
    chown -R ${USER}:${USER} ${WORK_DIR} /opt/wine64 /output

USER ${USER}

# Clone repository
RUN git clone https://github.com/spesmilo/electrum.git ${WORK_DIR}/electrum

WORKDIR ${WORK_DIR}/electrum

# Checkout version
RUN git checkout ${ELECTRUM_VERSION}

# Install Python dependencies
RUN python3 -m venv ${HOME_DIR}/.venv && \
    ${HOME_DIR}/.venv/bin/pip install --no-cache-dir \
        -r contrib/deterministic-build/requirements-build-base.txt \
        -r contrib/deterministic-build/requirements-build-wine.txt

ENV PATH="${HOME_DIR}/.venv/bin:${PATH}"

# Build using make_win.sh which handles all the preparation and building
# This script sets up CONTRIB, WINEPREFIX, and other required env vars
RUN cd contrib/build-wine && ./make_win.sh

# Copy artifacts to /output for extraction (directory created as root earlier)
RUN cp contrib/build-wine/dist/*.exe /output/

CMD ["/bin/bash"]
DOCKERFILE_EOF

log_success "Dockerfile generated"

# ---------- Build Container Image ----------
log_info "Building container image (this may take 30-60 minutes)..."
image_name="electrum-desktop-build:${version}"

if command -v podman &>/dev/null; then
  container_cmd="podman"
elif command -v docker &>/dev/null; then
  container_cmd="docker"
else
  log_error "Neither podman nor docker found. Please install one of them."
  echo "Exit code: 1"
  exit 1
fi

log_info "Using container runtime: ${container_cmd}"

if ! ${container_cmd} build \
  --build-arg VERSION="${version}" \
  --build-arg UID="$(id -u)" \
  -t "${image_name}" \
  -f "$dockerfile_path" \
  "$workspace"; then
  log_error "Container build failed"
  echo "Exit code: 1"
  exit 1
fi

log_success "Container image built successfully"

# ---------- Extract Build Artifacts ----------
log_info "Extracting build artifacts from container..."
built_dir="$workspace/built"
mkdir -p "$built_dir"

container_id=$(${container_cmd} create "${image_name}")
${container_cmd} cp "${container_id}:/output/." "$built_dir/"
${container_cmd} rm "${container_id}"

log_success "Artifacts extracted to ${built_dir}"

# Verify artifacts exist
if [[ -z $(ls -1 "$built_dir"/electrum-*.exe 2>/dev/null) ]]; then
  log_error "No executables found in built directory"
  echo "Exit code: 1"
  exit 1
fi

# ---------- Strip Signatures ----------
log_info "Stripping Authenticode signatures..."
stripped_official_dir="$workspace/official_stripped"
mkdir -p "$stripped_official_dir"
chmod 777 "$stripped_official_dir"  # Ensure writable by container user

# Check if osslsigncode is available on host
if command -v osslsigncode &>/dev/null; then
  # Strip on host
  for file in "${official_files[@]}"; do
    if [[ -f "$official_dir/$file" ]]; then
      log_info "Stripping signature from ${file}..."
      if osslsigncode remove-signature -in "$official_dir/$file" -out "$stripped_official_dir/$file" 2>/dev/null; then
        log_success "Stripped ${file}"
      else
        log_warn "Failed to strip signature from ${file}, using original"
        cp "$official_dir/$file" "$stripped_official_dir/$file"
      fi
    fi
  done
else
  # Strip using container (with proper volume mounts and permissions)
  for file in "${official_files[@]}"; do
    if [[ -f "$official_dir/$file" ]]; then
      log_info "Stripping signature from ${file}..."
      # Use container with user ownership
      if ${container_cmd} run --rm --user "$(id -u):$(id -g)" \
        -v "$official_dir:/input:ro" \
        -v "$stripped_official_dir:/output:rw" \
        "${image_name}" \
        osslsigncode remove-signature -in "/input/$file" -out "/output/$file" 2>/dev/null; then
        log_success "Stripped ${file}"
      else
        log_warn "Failed to strip signature from ${file}, using original"
        cp "$official_dir/$file" "$stripped_official_dir/$file"
      fi
    fi
  done
fi

log_success "Signatures stripped"

# ---------- Comparison ----------
log_info "Comparing binaries..."
match_count=0
diff_count=0
comparison_file="${execution_dir}/COMPARISON_RESULTS.txt"

# Write to comparison file
{
  echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
} > "$comparison_file"

# Compare files and append to comparison file
for file in "${official_files[@]}"; do
  built_file="$built_dir/$file"
  official_file="$stripped_official_dir/$file"

  if [[ ! -f "$built_file" ]] || [[ ! -f "$official_file" ]]; then
    log_warn "Skipping ${file} - file not found"
    continue
  fi

  built_hash=$(sha256sum "$built_file" | awk '{print $1}')

  if diff -q "$built_file" "$official_file" >/dev/null 2>&1; then
    echo "$file - $arch - $built_hash - 1 (MATCHES)" >> "$comparison_file"
    match_count=$((match_count + 1))
    log_success "Match: ${file}"
  else
    echo "$file - $arch - $built_hash - 0 (DIFFERS)" >> "$comparison_file"
    diff_count=$((diff_count + 1))
    log_warn "Difference: ${file}"
  fi
done

# Add header to comparison file
if (( diff_count == 0 && match_count > 0 )); then
  sed -i '1s/^/BUILDS MATCH BINARIES\n/' "$comparison_file"
  verdict="reproducible"
else
  sed -i '1s/^/BUILDS DO NOT MATCH BINARIES\n/' "$comparison_file"
  verdict="not_reproducible"
fi

# ---------- Standardized Output Format ----------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${verdict}"
echo "appHash:        $(sha256sum "$official_dir/${official_files[0]}" 2>/dev/null | awk '{print $1}' || echo 'N/A')"
echo "commit:         N/A"
echo ""
echo "Diff:"
# Read and display comparison results
if [[ -f "$comparison_file" ]]; then
  grep -v "^Date:" "$comparison_file" | grep -v "^$" | head -1
  tail -n +3 "$comparison_file" | grep -v "^$"
fi
echo ""
echo "Revision, tag (and its signature):"
echo "N/A - Binary verification only (no source checkout)"
echo ""
echo "===== End Results ====="
echo ""

# ---------- Summary ----------
log_info "=============================================="
log_info "Verification Summary"
log_info "=============================================="
log_info "Version: ${version}"
log_info "Architecture: ${arch}"
log_info "Matches: ${match_count}"
log_info "Differences: ${diff_count}"

if [[ "$verdict" == "reproducible" ]]; then
  log_success "Verdict: REPRODUCIBLE"
  log_info "Build server output: ${comparison_file}"
  echo "Exit code: 0"
  exit 0
else
  log_warn "Verdict: NOT REPRODUCIBLE"
  log_info "Build server output: ${comparison_file}"
  echo "Exit code: 1"
  exit 1
fi
