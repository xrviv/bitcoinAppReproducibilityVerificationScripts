#!/usr/bin/env bash
# ==============================================================================
# electrumdesktop_build.sh - Electrum Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.7.1
# Organization:  WalletScrutiny.com
# Last Modified: 2025-11-06
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
SUCCESS_ICON="[OK]"
WARNING_ICON="[WARN]"
ERROR_ICON="[ERROR]"
INFO_ICON="[INFO]"

APP_NAME="Electrum Desktop"
APP_ID="org.electrum.electrum"
SCRIPT_VERSION="v0.7.1"
REPO_URL="https://github.com/spesmilo/electrum"

# ---------- Logging Functions ----------
log_info() { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn() { echo -e "${YELLOW}${WARNING_ICON}${NC} $*"; }
log_error() { echo -e "${RED}${ERROR_ICON}${NC} $*" >&2; }

# ---------- Usage ----------
usage() {
  cat <<EOF
Electrum Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>]

Required Parameters:
  --version <version>    Electrum version to verify (e.g., 4.6.2)

Optional Parameters:
  --arch <arch>          Architecture to build (default: win64)
                         Supported: win64, x86_64-linux-gnu
                         Aliases: win/windows → win64, linux → x86_64-linux-gnu
  --type <type>          Package type
                         For win64: setup, portable, standalone (all 3 if omitted)
                         For x86_64-linux-gnu: appimage, tarball (required)
                         Aliases: tar/targz → tarball

Flags:
  --help                 Show this help message

Examples:
  $(basename "$0") --version 4.6.2                                    # All 3 Windows executables
  $(basename "$0") --version 4.6.2 --arch win64 --type setup          # Windows setup only
  $(basename "$0") --version 4.6.2 --arch win64 --type portable       # Windows portable only
  $(basename "$0") --version 4.6.2 --arch win64 --type standalone     # Windows standalone only
  $(basename "$0") --version 4.6.2 --arch x86_64-linux-gnu --type appimage
  $(basename "$0") --version 4.6.2 --arch x86_64-linux-gnu --type tarball

Requirements:
  - Docker or Podman installed
  - Internet connection for downloading sources and official releases
  - Approximately 5GB disk space for build

Output:
  - Exit code 0: Binaries are reproducible
  - Exit code 1: Binaries differ or verification failed
  - Exit code 2: Invalid parameters (configuration error)
  - COMPARISON_RESULTS.txt: Machine-readable comparison results
  - Standardized results format between ===== Begin/End Results =====

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parameter Parsing ----------
version=""
arch="win64"
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
      exit 2  # Invalid parameter
      ;;
  esac
done

# Normalize architecture aliases
arch_input="$arch"
arch_lower="${arch,,}"
case "$arch_lower" in
  win|windows)
    arch="win64"
    ;;
  x86_64-linux-gnu|linux)
    arch="x86_64-linux-gnu"
    ;;
  *)
    arch="$arch_lower"
    ;;
esac

# Normalize type aliases (if provided)
if [[ -n "$build_type" ]]; then
  build_type_lower="${build_type,,}"
  case "$build_type_lower" in
    tarball|targz|tar)
      build_type="tarball"
      ;;
    appimage)
      build_type="appimage"
      ;;
    setup)
      build_type="setup"
      ;;
    portable)
      build_type="portable"
      ;;
    standalone)
      build_type="standalone"
      ;;
    *)
      build_type="$build_type_lower"
      ;;
  esac
fi

# Validate required parameters
if [[ -z "$version" ]]; then
  log_error "Missing required parameter: --version"
  usage
  exit 2  # Invalid parameter
fi

# Validate architecture
if [[ "$arch" != "win64" && "$arch" != "x86_64-linux-gnu" ]]; then
  log_error "Unsupported architecture: ${arch}"
  log_error "Supported architectures: win64, x86_64-linux-gnu"
  exit 2  # Invalid parameter
fi

# Validate type for Linux (required)
if [[ "$arch" == "x86_64-linux-gnu" ]]; then
  if [[ -z "$build_type" ]]; then
    log_error "--type is required for x86_64-linux-gnu architecture"
    log_error "Supported types: appimage, tarball"
    exit 2  # Invalid parameter
  fi
  if [[ "$build_type" != "appimage" && "$build_type" != "tarball" ]]; then
    log_error "Unsupported type for x86_64-linux-gnu: ${build_type}"
    log_error "Supported types: appimage, tarball"
    exit 2  # Invalid parameter
  fi
fi

# Validate type for Windows (optional - if provided, must be valid)
if [[ "$arch" == "win64" && -n "$build_type" ]]; then
  if [[ "$build_type" != "setup" && "$build_type" != "portable" && "$build_type" != "standalone" ]]; then
    log_error "Unsupported type for win64: ${build_type}"
    log_error "Supported types: setup, portable, standalone"
    exit 2  # Invalid parameter - MR !1272: prevents win64+appimage from being treated as build failure
  fi
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
if [[ -n "$build_type" ]]; then
  log_info "Type: ${build_type}"
fi
log_info "Workspace: ${workspace}"
log_info ""

# ---------- Download Official Releases ----------
log_info "Downloading official releases from electrum.org..."
official_dir="$workspace/official"
mkdir -p "$official_dir"

download_url_base="https://download.electrum.org/${version}"

# Set files based on architecture and type
if [[ "$arch" == "win64" ]]; then
  # If --type specified for Windows, only download/verify that specific type
  if [[ -n "$build_type" ]]; then
    case "$build_type" in
      setup)
        official_files=("electrum-${version}-setup.exe")
        ;;
      portable)
        official_files=("electrum-${version}-portable.exe")
        ;;
      standalone)
        official_files=("electrum-${version}.exe")
        ;;
    esac
  else
    # No type specified - download all 3 (backward compatible behavior)
    official_files=(
      "electrum-${version}-setup.exe"
      "electrum-${version}-portable.exe"
      "electrum-${version}.exe"
    )
  fi
elif [[ "$arch" == "x86_64-linux-gnu" ]]; then
  if [[ "$build_type" == "appimage" ]]; then
    official_files=(
      "electrum-${version}-x86_64.AppImage"
    )
  elif [[ "$build_type" == "tarball" ]]; then
    official_files=(
      "Electrum-${version}.tar.gz"
    )
  fi
fi

for file in "${official_files[@]}"; do
  log_info "Downloading ${file}..."
  if ! wget -O "$official_dir/$file" "${download_url_base}/${file}"; then
    log_error "Failed to download ${file}"
    echo "Exit code: 1"
    exit 1
  fi
  log_success "Downloaded ${file}"
done

# ---------- Generate Embedded Dockerfile ----------
log_info "Generating embedded Dockerfile for reproducible build..."
dockerfile_path="$workspace/Dockerfile"

if [[ "$arch" == "win64" ]]; then
  log_info "Generating Windows (Wine) build Dockerfile..."
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

elif [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" ]]; then
  log_info "Generating Linux AppImage Dockerfile (Debian Bullseye)..."
  cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
# Using Electrum's exact pinned base image for AppImage reproducible builds
FROM debian:bullseye@sha256:cf48c31af360e1c0a0aedd33aae4d928b68c2cdf093f1612650eb1ff434d1c34

ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

ARG VERSION
ARG UID=1000
ENV ELECTRUM_VERSION=${VERSION}
ENV USER="user"
ENV HOME_DIR="/home/${USER}"
ENV WORK_DIR="/opt/electrum"

# Install ca-certificates first (needed for snapshot.debian.org)
RUN apt-get update -qq > /dev/null && apt-get install -qq --yes --no-install-recommends \
    ca-certificates

# Pin packages to Debian snapshot for reproducible builds
RUN echo "deb https://snapshot.debian.org/archive/debian/20250530T143637Z/ bullseye main" > /etc/apt/sources.list && \
    echo "deb-src https://snapshot.debian.org/archive/debian/20250530T143637Z/ bullseye main" >> /etc/apt/sources.list && \
    echo "Package: *" > /etc/apt/preferences.d/snapshot && \
    echo "Pin: origin \"snapshot.debian.org\"" >> /etc/apt/preferences.d/snapshot && \
    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/snapshot

# Install dependencies for AppImage (NO Python - built from source by make_appimage.sh)
RUN apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        sudo git wget make \
        autotools-dev autoconf libtool autopoint pkg-config xz-utils gettext \
        libssl-dev libssl1.1 openssl \
        zlib1g-dev libffi-dev \
        libncurses5-dev libncurses5 libtinfo-dev libtinfo5 \
        libsqlite3-dev \
        libusb-1.0-0-dev libudev-dev libudev1 \
        libdbus-1-3 xutils-dev \
        libxkbcommon0 libxkbcommon-x11-0 \
        libxcb1-dev libxcb-xinerama0 libxcb-randr0 libxcb-render0 \
        libxcb-shm0 libxcb-shape0 libxcb-sync1 libxcb-xfixes0 libxcb-xkb1 \
        libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-util1 \
        libxcb-render-util0 libxcb-cursor0 libx11-xcb1 \
        libc6-dev libc6 libc-dev-bin \
        libv4l-dev libjpeg62-turbo-dev libx11-dev && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get autoremove -y && \
    apt-get clean

# Create user and setup workspace
RUN useradd --uid $UID --create-home --shell /bin/bash ${USER} && \
    mkdir -p ${WORK_DIR} /output && \
    chown -R ${USER}:${USER} ${WORK_DIR} /output

USER ${USER}

# Clone repository
RUN git clone https://github.com/spesmilo/electrum.git ${WORK_DIR}

WORKDIR ${WORK_DIR}

# Checkout version
RUN git checkout ${ELECTRUM_VERSION}

# Build AppImage (make_appimage.sh builds Python 3.12.11 from source)
RUN cd contrib/build-linux/appimage && ./make_appimage.sh && \
    cp ../../../dist/*.AppImage /output/

CMD ["/bin/bash"]
DOCKERFILE_EOF

elif [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "tarball" ]]; then
  log_info "Generating Linux Tarball Dockerfile (Debian Bookworm)..."
  cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
# Using Electrum's exact base image for tarball builds (requires Python 3.10+)
# Build as unprivileged user matching Electrum's official tarball workflow
FROM debian:bookworm@sha256:b877a1a3fdf02469440f1768cf69c9771338a875b7add5e80c45b756c92ac20a

ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

ARG VERSION
ARG UID=1000
ENV USER="user"
ENV HOME_DIR="/home/${USER}"
ENV ELECTRUM_VERSION=${VERSION}
ENV WORK_DIR="/opt/electrum"

# Install ca-certificates first (needed for snapshot.debian.org)
RUN apt-get update -qq > /dev/null && apt-get install -qq --yes --no-install-recommends \
    ca-certificates

# Pin packages to Debian snapshot for reproducible builds
# Using snapshot from 2024-06-17 (around Debian 12.6 stable release)
RUN echo "deb https://snapshot.debian.org/archive/debian/20240617T085507Z/ bookworm main" > /etc/apt/sources.list && \
    echo "deb-src https://snapshot.debian.org/archive/debian/20240617T085507Z/ bookworm main" >> /etc/apt/sources.list && \
    echo "Package: *" > /etc/apt/preferences.d/snapshot && \
    echo "Pin: origin \"snapshot.debian.org\"" >> /etc/apt/preferences.d/snapshot && \
    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/snapshot

# Install minimal dependencies for tarball build
RUN apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        git \
        gettext \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-venv && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get autoremove -y && \
    apt-get clean

# Create user and setup workspace (Electrum tarball built as regular user)
RUN useradd --uid $UID --non-unique --create-home --shell /bin/bash ${USER} && \
    mkdir -p ${WORK_DIR} /output && \
    chown -R ${USER}:${USER} ${WORK_DIR} /output

USER ${USER}

# Clone repository
RUN git clone https://github.com/spesmilo/electrum.git ${WORK_DIR}

WORKDIR ${WORK_DIR}

# Checkout version
RUN git checkout ${ELECTRUM_VERSION}

# Build tarball (make_sdist.sh uses system Python with setup.py)
RUN ./contrib/build-linux/sdist/make_sdist.sh && \
    cp dist/*.tar.gz /output/

CMD ["/bin/bash"]
DOCKERFILE_EOF

fi

log_success "Dockerfile generated"

# ---------- Build Container Image ----------
log_info "Building container image (this may take 30-60 minutes)..."
image_name="electrum-desktop-build:${version}"

if command -v podman >/dev/null 2>&1; then
  container_cmd="podman"
elif command -v docker >/dev/null 2>&1; then
  container_cmd="docker"
else
  log_error "Neither podman nor docker found. Please install one of them."
  echo "Exit code: 1"
  exit 1
fi

log_info "Using container runtime: ${container_cmd}"

# Build container with appropriate build args
host_uid=$(id -u)
host_gid=$(id -g)
container_uid=${host_uid}
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "tarball" ]]; then
  container_uid=1000
fi

build_args="--build-arg VERSION=${version} --build-arg UID=${container_uid}"
if [[ "$arch" == "x86_64-linux-gnu" ]]; then
  build_args="${build_args} --build-arg BUILD_TYPE=${build_type}"
fi

if ! ${container_cmd} build \
  ${build_args} \
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

# Ensure extracted artifacts are owned by host user
chown -R "${host_uid}:${host_gid}" "$built_dir" || true

log_success "Artifacts extracted to ${built_dir}"

# Verify artifacts exist
if [[ "$arch" == "win64" ]]; then
  if [[ -z $(ls -1 "$built_dir"/electrum-*.exe) ]]; then
    log_error "No executables found in built directory"
    echo "Exit code: 1"
    exit 1
  fi
elif [[ "$arch" == "x86_64-linux-gnu" ]]; then
  if [[ -z $(ls -1 "$built_dir"/[Ee]lectrum-* 2>/dev/null) ]]; then
    log_error "No artifacts found in built directory"
    echo "Exit code: 1"
    exit 1
  fi
fi

# ---------- Strip Signatures (Windows only) ----------
stripped_official_dir="$workspace/official_stripped"
mkdir -p "$stripped_official_dir"

if [[ "$arch" == "win64" ]]; then
  log_info "Stripping Authenticode signatures..."
  chmod 777 "$stripped_official_dir"  # Ensure writable by container user

# Check if osslsigncode is available on host
if command -v osslsigncode >/dev/null 2>&1; then
  # Strip on host
  for file in "${official_files[@]}"; do
    if [[ -f "$official_dir/$file" ]]; then
      log_info "Stripping signature from ${file}..."
      if osslsigncode remove-signature -in "$official_dir/$file" -out "$stripped_official_dir/$file"; then
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
        osslsigncode remove-signature -in "/input/$file" -out "/output/$file"; then
        log_success "Stripped ${file}"
      else
        log_warn "Failed to strip signature from ${file}, using original"
        cp "$official_dir/$file" "$stripped_official_dir/$file"
      fi
    fi
  done
fi

  log_success "Signatures stripped"
elif [[ "$arch" == "x86_64-linux-gnu" ]]; then
  # Linux binaries don't have Authenticode signatures, copy directly
  log_info "Linux binaries - no signature stripping needed"
  cp "$official_dir"/* "$stripped_official_dir/"
  log_success "Official files copied for comparison"
fi

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

  if diff "$built_file" "$official_file" >/dev/null 2>&1; then
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
echo "appHash:        $(sha256sum "$official_dir/${official_files[0]}" | awk '{print $1}' || echo 'N/A')"
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
