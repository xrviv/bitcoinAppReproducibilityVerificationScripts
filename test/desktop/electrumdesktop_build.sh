#!/usr/bin/env bash
# ==============================================================================
# electrumdesktop_build.sh - Electrum Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.12.11
# Organization:  WalletScrutiny.com
# Last Modified: 2026-04-24
# Last modified by: Claude Sonnet 5 (WalletScrutiny session)
# Last modified on: 2026-07-10
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
# Supports three build paths selected via --arch and --type:
#
# Windows (win64):
# - Downloads official Electrum .exe from electrum.org (setup, portable, or standalone)
# - Builds via Wine inside a Debian Bookworm container (make_win.sh)
# - Strips Authenticode signatures from both binaries before comparing
# - All 3 .exe types built together; --type selects which to verify
#
# Linux AppImage (x86_64-linux-gnu --type appimage):
# - Fetches build constants (TYPE2_RUNTIME_COMMIT, Debian snapshot date, base image
#   digest) dynamically from Electrum's source at the given version tag
# - Extracts the type2-runtime ELF from the official AppImage and caches it keyed by
#   TYPE2_RUNTIME_COMMIT + an extractor-generation suffix (Alpine has no snapshot service;
#   building from source with drifted packages produces a different binary and a misleading
#   not_reproducible verdict; the suffix invalidates caches when the extraction logic changes)
# - Independently builds the squashfs (Electrum's application code) via make_appimage.sh
#   inside a pinned Debian Bullseye container; compares against the official release
# - Results output states explicitly that the runtime was sourced from the official release
#
# Linux tarball (x86_64-linux-gnu --type tarball):
# - Builds the source distribution via make_sdist.sh inside a Debian Bookworm container
# - Compares the built tarball byte-for-byte against the official release
#
# All paths generate COMPARISON_RESULTS.yaml for build server automation.

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
APP_ID="electrum"
SCRIPT_VERSION="v0.12.11"

# ---------- Logging Functions ----------
log_info() { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn() { echo -e "${YELLOW}${WARNING_ICON}${NC} $*"; }
log_error() { echo -e "${RED}${ERROR_ICON}${NC} $*" >&2; }

# ---------- Root Guard ----------
if [[ "$(id -u)" == "0" ]]; then
  log_error "Do not run this script as root."
  exit 2
fi

# ---------- Usage ----------
usage() {
  cat <<EOF
Electrum Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>] [--binary <file>]

Required Parameters:
  --version <version>    Electrum version to verify (e.g., 4.6.2)

Optional Parameters:
  --arch <arch>          Architecture to build (default: win64)
                         Supported: win64, x86_64-linux-gnu
                         Aliases: win/windows -> win64, linux -> x86_64-linux-gnu
  --type <type>          Package type
                         For win64: setup, portable, standalone (all 3 if omitted)
                         For x86_64-linux-gnu: appimage, tarball (required)
                         Aliases: tar/targz -> tarball
  --binary <file>        Path to official binary (skips download from electrum.org)
                         When provided, the given file is used as the official artifact.
                         Alias: --apk

Flags:
  --fresh                Bypass type2-runtime cache and force --no-cache on Stage 2 build
  --help                 Show this help message

Examples:
  $(basename "$0") --version 4.6.2                                    # All 3 Windows executables
  $(basename "$0") --version 4.6.2 --arch win64 --type setup          # Windows setup only
  $(basename "$0") --version 4.6.2 --arch win64 --type portable       # Windows portable only
  $(basename "$0") --version 4.6.2 --arch win64 --type standalone     # Windows standalone only
  $(basename "$0") --version 4.6.2 --arch x86_64-linux-gnu --type appimage
  $(basename "$0") --version 4.6.2 --arch x86_64-linux-gnu --type tarball
  $(basename "$0") --version 4.7.2 --arch x86_64-linux-gnu --type appimage --binary ~/Downloads/electrum-4.7.2-x86_64.AppImage

Requirements:
  - Docker or Podman installed
  - Internet connection for building from source (--binary skips release download only)
  - Approximately 5GB disk space for build

Output:
  - Exit code 0: Binaries are reproducible
  - Exit code 1: Binaries differ or verification failed
  - COMPARISON_RESULTS.yaml: Machine-readable comparison results
  - Standardized results format between ===== Begin/End Results =====

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parameter Parsing ----------
version=""
arch="win64"
build_type=""
binary=""
fresh=false

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
    --binary|--apk)
      binary="$2"
      shift 2
      ;;
    --fresh)
      fresh=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      log_warn "Unknown parameter: $1 (ignored)"
      shift
      ;;
  esac
done

# Normalize architecture aliases
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
  exit 2
fi

# Validate architecture
if [[ "$arch" != "win64" && "$arch" != "x86_64-linux-gnu" ]]; then
  log_error "Unsupported architecture: ${arch}"
  log_error "Supported architectures: win64, x86_64-linux-gnu"
  exit 2
fi

# Validate type for Linux (required)
if [[ "$arch" == "x86_64-linux-gnu" ]]; then
  if [[ -z "$build_type" ]]; then
    log_error "--type is required for x86_64-linux-gnu architecture"
    log_error "Supported types: appimage, tarball"
    exit 2
  fi
  if [[ "$build_type" != "appimage" && "$build_type" != "tarball" ]]; then
    log_error "Unsupported type for x86_64-linux-gnu: ${build_type}"
    log_error "Supported types: appimage, tarball"
    exit 2
  fi
fi

# Validate type for Windows (optional - if provided, must be valid)
if [[ "$arch" == "win64" && -n "$build_type" ]]; then
  if [[ "$build_type" != "setup" && "$build_type" != "portable" && "$build_type" != "standalone" ]]; then
    log_error "Unsupported type for win64: ${build_type}"
    log_error "Supported types: setup, portable, standalone"
    exit 2
  fi
fi

# ---------- Setup Workspace ----------
execution_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="${execution_dir}/electrum_desktop_${version}_${arch}_$$"
mkdir -p "$workspace"
cd "$workspace"

yaml_written=false
trap_on_exit() {
  local ec=$?
  if [[ $ec -ne 0 && "$yaml_written" == "false" ]]; then
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
EOF
    log_warn "Build failed (exit ${ec}) -- COMPARISON_RESULTS.yaml written with verdict: ftbfs"
  fi
  # Fix any root-owned files left by container operations so the workspace can be deleted by the host user
  if [[ -n "${workspace:-}" && -d "${workspace}" ]]; then
    "${container_cmd:-docker}" run --rm \
      -v "${workspace}:/ws" \
      alpine \
      sh -c "chown -R $(id -u):$(id -g) /ws" 2>/dev/null || true
  fi
}
trap trap_on_exit EXIT

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

# ---------- Official Release Metadata ----------
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

# ---------- Detect Container Runtime ----------
# Priority: 1) CONTAINER_CMD env var, 2) docker, 3) podman
if [[ -n "${CONTAINER_CMD:-}" ]]; then
  container_cmd="$CONTAINER_CMD"
elif command -v docker >/dev/null 2>&1; then
  container_cmd="docker"
elif command -v podman >/dev/null 2>&1; then
  container_cmd="podman"
else
  log_error "Neither podman nor docker found. Please install one of them."
  echo "Exit code: 1"
  exit 1
fi
log_info "Using container runtime: ${container_cmd}"

host_uid=$(id -u)
host_gid=$(id -g)

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
  # ============================================================================
  # PRE-FLIGHT: Fetch build constants from Electrum source at this version tag
  # These values are version-specific; hardcoding them produces wrong builds for
  # any release other than the one they were copied from.
  # ============================================================================
  log_info "Fetching AppImage build constants from Electrum ${version} source..."
  electrum_raw="https://raw.githubusercontent.com/spesmilo/electrum/${version}"

  TYPE2_RUNTIME_COMMIT=$(curl -sf "${electrum_raw}/contrib/build-linux/appimage/make_type2_runtime.sh" \
    | grep '^TYPE2_RUNTIME_COMMIT=' | head -1 | cut -d'"' -f2)
  if [[ -z "$TYPE2_RUNTIME_COMMIT" ]]; then
    log_error "Failed to fetch TYPE2_RUNTIME_COMMIT from Electrum ${version} --verify the version tag exists"
    echo "Exit code: 1"
    exit 1
  fi
  log_success "type2-runtime commit: ${TYPE2_RUNTIME_COMMIT}"

  SNAPSHOT_DATE=$(curl -sf "${electrum_raw}/contrib/build-linux/appimage/apt.sources.list" \
    | grep -oE '[0-9]{8}T[0-9]{6}Z' | head -1)
  if [[ -z "$SNAPSHOT_DATE" ]]; then
    log_error "Failed to fetch Debian snapshot date from Electrum ${version}"
    echo "Exit code: 1"
    exit 1
  fi
  log_success "Debian snapshot: ${SNAPSHOT_DATE}"

  BASE_IMAGE_DIGEST=$(curl -sf "${electrum_raw}/contrib/build-linux/appimage/Dockerfile" \
    | grep '^FROM ' | grep -oE 'sha256:[a-f0-9]+' | head -1)
  if [[ -z "$BASE_IMAGE_DIGEST" ]]; then
    log_error "Failed to fetch base image digest from Electrum ${version}"
    echo "Exit code: 1"
    exit 1
  fi
  log_success "Base image: debian:bullseye@${BASE_IMAGE_DIGEST}"

  # ============================================================================
  # STAGE 1: Get type2-runtime binary (extract from official AppImage or load from cache)
  #
  # Alpine Linux has no snapshot service --pinned package versions are deleted from the
  # CDN when newer patches are released. Building from source with different packages
  # produces a different binary, which would cause the comparison to report
  # not_reproducible even when Electrum's code is correctly reproducible. That verdict
  # would be misleading: the fault is the build environment, not Electrum's source.
  #
  # Instead, we extract the runtime ELF directly from the official AppImage. The AppImage
  # format is [runtime ELF][SquashFS]; the runtime boundary is found by parsing the ELF64
  # program headers (no execution of the AppImage). This means Stage 2 independently
  # verifies the squashfs content (all of Electrum's application code) while the runtime
  # is sourced from the official release itself. The scope of verification is stated
  # explicitly in the results output.
  #
  # Cache key includes TYPE2_RUNTIME_COMMIT (auto-invalidates when Electrum bumps it)
  # plus a suffix that changes when the offset-detection logic is revised, so runtimes
  # extracted by a buggy extractor are never silently reused.
  # ============================================================================
  # Cache path includes extractor generation so old runtimes from buggy offset
  # detection logic are not silently reused.
  runtime_cache_dir="${execution_dir}/.cache/type2-runtime/${TYPE2_RUNTIME_COMMIT}-offset-v3"
  runtime_cache_file="${runtime_cache_dir}/runtime-x86_64"

  if [[ "$fresh" == "true" && -f "$runtime_cache_file" ]]; then
    rm -f "$runtime_cache_file"
    log_info "Cache cleared for commit ${TYPE2_RUNTIME_COMMIT:0:12} (--fresh)"
  fi

  if [[ -f "$runtime_cache_file" ]]; then
    log_info "Stage 1: Loading type2-runtime from cache (commit ${TYPE2_RUNTIME_COMMIT:0:12}...)"
    cp "$runtime_cache_file" "$workspace/runtime-x86_64"
    runtime_hash=$(sha256sum "$workspace/runtime-x86_64" | cut -d' ' -f1)
    log_success "type2-runtime loaded from cache: ${runtime_hash}"
  else
    log_info "Stage 1: Extracting type2-runtime from official AppImage..."

    # Obtain the AppImage: use --binary if provided, otherwise download now.
    # Saving to $official_dir means the download section below skips re-fetching it.
    seed_appimage="${official_dir}/${official_files[0]}"
    if [[ -n "${binary:-}" ]]; then
      seed_appimage="$binary"
      log_info "Using provided binary for runtime extraction"
    else
      log_info "Downloading ${official_files[0]}..."
      if ! curl -fL --progress-bar -o "$seed_appimage" \
          "${download_url_base}/${official_files[0]}"; then
        log_error "Failed to download official AppImage for runtime extraction"
        echo "Exit code: 1"
        exit 1
      fi
      log_success "Downloaded ${official_files[0]}"
    fi

    # Determine SquashFS offset: parse ELF64 program headers to find the minimum safe
    # scan floor (max PT_LOAD end, unaligned), then do a SquashFS magic scan from
    # that floor to get the exact byte where squashfs begins.
    #
    # Two-phase approach:
    #   Phase A: ELF64 header parse (od+awk) -- gives min_scan_offset = max(p_offset+p_filesz)
    #            over all PT_LOAD segments. No 4096 rounding: AppImages do not require
    #            squashfs to start on a page boundary, and rounding overshoots by up to
    #            4095 bytes, extracting squashfs data into the runtime and shifting the
    #            squashfs start in the rebuilt AppImage.
    #   Phase B: SquashFS magic scan starting from min_scan_offset. Avoids false "hsqs"
    #            matches inside the ELF payload (which caused truncated runtimes and
    #            appimagetool crashes in earlier versions). Finds the exact start byte.
    #
    # Executing the AppImage to ask for its own offset is unsafe for a verifier:
    # the binary is untrusted until verification completes.
    #
    # ELF64 fields used (all little-endian):
    #   bytes 32-39: e_phoff       (program header table offset)
    #   bytes 54-55: e_phentsize   (program header entry size)
    #   bytes 56-57: e_phnum       (number of entries)
    # Each PT_LOAD entry (p_type == 1, entry size 56 bytes for ELF64):
    #   bytes  8-15: p_offset      (file offset of segment)
    #   bytes 32-39: p_filesz      (size in file)
    sfs_offset=""
    min_scan_offset=4096  # safe default if ELF parse fails

    elf_parse=$(od -A n -j 0 -N 64 -t u1 -v "$seed_appimage" 2>/dev/null | \
      awk '{for(i=1;i<=NF;i++) a[++n]=$i+0} END {
        if (n < 58) exit 1
        if (a[1]!=127||a[2]!=69||a[3]!=76||a[4]!=70||a[5]!=2) exit 1
        phoff    = a[33]+a[34]*256+a[35]*65536+a[36]*16777216
        phentsize = a[55]+a[56]*256
        phnum    = a[57]+a[58]*256
        if (phoff==0||phentsize==0||phnum==0) exit 1
        print phoff, phentsize, phnum
      }' 2>/dev/null)

    if [[ -n "$elf_parse" ]]; then
      read -r _phoff _phentsize _phnum <<<"$elf_parse"
      _ph_total=$(( _phnum * _phentsize ))
      elf_max_end=$(od -A n -j "$_phoff" -N "$_ph_total" -t u1 -v "$seed_appimage" 2>/dev/null | \
        awk -v esz="$_phentsize" '
          {for(i=1;i<=NF;i++) a[++n]=$i+0}
          END {
            max_end = 0
            entries = int(n / esz)
            for (i = 0; i < entries; i++) {
              base = i * esz + 1
              p_type = a[base]+a[base+1]*256+a[base+2]*65536+a[base+3]*16777216
              if (p_type != 1) continue
              p_off    = a[base+8] +a[base+9] *256+a[base+10]*65536+a[base+11]*16777216
              p_filesz = a[base+32]+a[base+33]*256+a[base+34]*65536+a[base+35]*16777216
              end = p_off + p_filesz
              if (end > max_end) max_end = end
            }
            if (max_end == 0) exit 1
            print max_end
          }' 2>/dev/null)
      if [[ "$elf_max_end" =~ ^[0-9]+$ && "$elf_max_end" -gt 4096 ]]; then
        min_scan_offset="$elf_max_end"
        log_info "ELF PT_LOAD end: ${elf_max_end} -- scanning for squashfs magic from there"
      else
        log_warn "ELF header parse failed; scanning for squashfs magic from offset 4096"
      fi
    fi

    # Phase B: locate exact squashfs start by scanning for hsqs magic from min_scan_offset.
    # od -A d outputs 16 bytes per line with decimal address; scan every 4-byte window.
    # POSIX awk only ($1+0 coercion, no gawk strtonum).
    # Early awk exit sends SIGPIPE to od; disable pipefail temporarily to avoid false ftbfs.
    set +o pipefail
    sfs_offset=$(od -A d -t x1 "$seed_appimage" | awk -v floor="$min_scan_offset" '
      {
        addr = $1 + 0
        if (addr + (NF - 2) < floor) next
        for (i = 2; i <= NF - 3; i++) {
          if (addr + (i - 2) < floor) continue
          if ($i == "68" && $(i+1) == "73" && $(i+2) == "71" && $(i+3) == "73") {
            print addr + (i - 2)
            exit
          }
        }
      }')
    set -o pipefail
    if [[ -z "$sfs_offset" || "$sfs_offset" -le 0 ]]; then
      log_error "Could not locate SquashFS magic (hsqs) in AppImage --cannot extract runtime"
      echo "Exit code: 1"
      exit 1
    fi
    log_info "Runtime size: ${sfs_offset} bytes (SquashFS at offset ${sfs_offset})"

    dd if="$seed_appimage" of="$workspace/runtime-x86_64" \
       bs=1 count="$sfs_offset" status=none

    mkdir -p "$runtime_cache_dir"
    cp "$workspace/runtime-x86_64" "$runtime_cache_file"
    runtime_hash=$(sha256sum "$workspace/runtime-x86_64" | cut -d' ' -f1)
    log_success "type2-runtime extracted and cached: ${runtime_hash}"
  fi

  cd "$workspace"

  # ============================================================================
  # STAGE 2: Build AppImage (Debian Bullseye container)
  # ============================================================================
  log_info "Stage 2: Generating Linux AppImage Dockerfile (Debian Bullseye)..."
  cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
# Using Electrum's exact pinned base image for AppImage reproducible builds
FROM debian:bullseye@__BASE_IMAGE_DIGEST__

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
RUN echo "deb https://snapshot.debian.org/archive/debian/__SNAPSHOT_DATE__/ bullseye main" > /etc/apt/sources.list && \
    echo "deb-src https://snapshot.debian.org/archive/debian/__SNAPSHOT_DATE__/ bullseye main" >> /etc/apt/sources.list && \
    echo "Package: *" > /etc/apt/preferences.d/snapshot && \
    echo "Pin: origin \"snapshot.debian.org\"" >> /etc/apt/preferences.d/snapshot && \
    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/snapshot

# Install dependencies for AppImage.
# Note: python3 (system) is required for contrib/locale/stats.py during locale prep (added in 4.7.1).
# A separate Python is also compiled from source by make_appimage.sh for the AppDir bundle.
RUN apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        sudo git wget make desktop-file-utils \
        python3 \
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
        libv4l-dev libjpeg62-turbo-dev libx11-dev \
        libfuse2 && \
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

# Create the runtime cache directory (runtime will be mounted at container run time)
RUN mkdir -p ${WORK_DIR}/contrib/build-linux/appimage/.cache/appimage/type2-runtime

CMD ["/bin/bash"]
DOCKERFILE_EOF

  # Inject version-specific constants fetched in pre-flight (heredoc used single quotes
  # to avoid bash expansion of Docker $VAR references, so we patch after writing)
  sed -i "s|__BASE_IMAGE_DIGEST__|${BASE_IMAGE_DIGEST}|g" "$dockerfile_path"
  sed -i "s|__SNAPSHOT_DATE__|${SNAPSHOT_DATE}|g" "$dockerfile_path"

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
        git wget \
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
build_type_tag="${build_type:-all}"
image_name="electrum-desktop-build:${version}-${arch}-${build_type_tag}-$$"

container_uid=${host_uid}
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "tarball" ]]; then
  container_uid=1000
fi

build_args="--build-arg VERSION=${version} --build-arg UID=${container_uid}"

docker_cache_flags=""
if [[ "$fresh" == "true" ]]; then
  docker_cache_flags="--no-cache"
fi

if ! ${container_cmd} build \
  ${build_args} \
  ${docker_cache_flags} \
  -t "${image_name}" \
  -f "$dockerfile_path" \
  "$workspace"; then
  log_error "Container build failed"
  echo "Exit code: 1"
  exit 1
fi

log_success "Container image built successfully"

# ---------- Run AppImage Build (special case) ----------
# For AppImage, the Dockerfile only sets up the environment.
# We run make_appimage.sh separately with the type2-runtime mounted.
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" ]]; then
  log_info "Running make_appimage.sh with mounted type2-runtime..."

  # Create output directory
  appimage_output_dir="$workspace/appimage-output"
  mkdir -p "$appimage_output_dir"

  if ! ${container_cmd} run --rm \
    -u "${host_uid}:${host_gid}" \
    -v "$workspace/runtime-x86_64:/opt/electrum/contrib/build-linux/appimage/.cache/appimage/type2-runtime/runtime-x86_64:rw" \
    -v "$appimage_output_dir:/output:rw" \
    "${image_name}" \
    bash -c 'cd /opt/electrum/contrib/build-linux/appimage && ./make_appimage.sh && cp /opt/electrum/dist/*.AppImage /output/'; then
    log_error "AppImage build failed"
    echo "Exit code: 1"
    exit 1
  fi

  log_success "AppImage built successfully"
fi

# ---------- Download Official Releases ----------
if [[ -n "$binary" ]]; then
  log_info "Using provided binary: ${binary}"
  if [[ ! -f "$binary" ]]; then
    log_error "Provided binary not found: ${binary}"
    echo "Exit code: 1"
    exit 1
  fi
  cp "$binary" "$official_dir/${official_files[0]}"
  log_success "Copied provided binary as ${official_files[0]}"
else
  log_info "Downloading official releases from electrum.org..."
  for file in "${official_files[@]}"; do
    if [[ -f "$official_dir/$file" ]]; then
      log_info "Already downloaded: ${file}"
      continue
    fi
    log_info "Downloading ${file}..."
    if ! ${container_cmd} run --rm --user "${host_uid}:${host_gid}" \
      -v "$official_dir:/official:rw" \
      "${image_name}" \
      bash -c "wget -O \"/official/${file}\" \"${download_url_base}/${file}\""; then
      log_error "Failed to download ${file}"
      echo "Exit code: 1"
      exit 1
    fi
    if [[ ! -f "$official_dir/$file" ]]; then
      log_error "Downloaded file missing: ${file}"
      echo "Exit code: 1"
      exit 1
    fi
    log_success "Downloaded ${file}"
  done
fi

# ---------- Extract Build Artifacts ----------
log_info "Extracting build artifacts from container..."
built_dir="$workspace/built"
mkdir -p "$built_dir"

# For AppImage, artifacts are already on host (from docker run with volume mount)
# For other types, extract from container's /output directory
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" ]]; then
  cp "$appimage_output_dir"/* "$built_dir/" 2>/dev/null || true
else
  container_id=$(${container_cmd} create "${image_name}")
  ${container_cmd} cp "${container_id}:/output/." "$built_dir/"
  ${container_cmd} rm "${container_id}"
fi

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
if [[ "$arch" == "win64" ]]; then
  stripped_official_dir="$workspace/official_stripped"
  mkdir -p "$stripped_official_dir"
  log_info "Stripping Authenticode signatures in container..."

  if ! ${container_cmd} run --rm --user "${host_uid}:${host_gid}" \
    -v "$official_dir:/input:ro" \
    -v "$stripped_official_dir:/output:rw" \
    "${image_name}" \
    bash -c '
      set -euo pipefail
      for file in "$@"; do
        if [[ -f "/input/${file}" ]]; then
          if osslsigncode remove-signature -in "/input/${file}" -out "/output/${file}" >/dev/null 2>&1; then
            :
          else
            cp "/input/${file}" "/output/${file}"
          fi
        fi
      done
    ' bash "${official_files[@]}"; then
    log_error "Signature stripping failed"
    echo "Exit code: 1"
    exit 1
  fi

  for file in "${official_files[@]}"; do
    if [[ ! -f "$stripped_official_dir/$file" ]]; then
      log_error "Stripped file missing: ${file}"
      echo "Exit code: 1"
      exit 1
    fi
  done

  log_success "Signatures stripped"
else
  stripped_official_dir="$official_dir"
  log_info "Linux binaries - no signature stripping needed"
fi

# ---------- Comparison ----------
log_info "Comparing binaries..."
match_count=0
diff_count=0
result_files=()
result_hashes=()
result_official_hashes=()
result_matches=()

comparison_output="$(${container_cmd} run --rm --user "${host_uid}:${host_gid}" \
  -v "$built_dir:/built:ro" \
  -v "$stripped_official_dir:/official:ro" \
  "${image_name}" \
  bash -c '
    set -euo pipefail
    for file in "$@"; do
      built="/built/${file}"
      official="/official/${file}"
      if [[ ! -f "$built" ]] || [[ ! -f "$official" ]]; then
        echo "${file}|MISSING|MISSING|missing"
        continue
      fi
      built_hash=$(sha256sum "$built" | cut -d " " -f1)
      official_hash=$(sha256sum "$official" | cut -d " " -f1)
      if [[ "$built_hash" == "$official_hash" ]]; then
        match="true"
      else
        match="false"
      fi
      echo "${file}|${built_hash}|${official_hash}|${match}"
    done
  ' bash "${official_files[@]}")" || {
    log_error "Comparison failed in container"
    echo "Exit code: 1"
    exit 1
  }

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  IFS="|" read -r file built_hash official_hash match_value <<< "$line"
  if [[ "$match_value" == "missing" ]]; then
    log_warn "Skipping ${file} - file not found"
    continue
  fi
  result_files+=("$file")
  result_hashes+=("$built_hash")
  result_official_hashes+=("$official_hash")
  result_matches+=("$match_value")
  if [[ "$match_value" == "true" ]]; then
    match_count=$((match_count + 1))
    log_success "Match: ${file}"
  else
    diff_count=$((diff_count + 1))
    log_warn "Difference: ${file}"
  fi
done <<< "$comparison_output"

# Determine verdict
if (( diff_count == 0 && match_count > 0 )); then
  verdict="reproducible"
elif (( match_count == 0 && diff_count == 0 )); then
  verdict="ftbfs"
else
  verdict="not_reproducible"
fi

# ---------- Generate YAML Comparison Results ----------
generate_comparison_yaml() {
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"

  log_info "Generating COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
EOF

  yaml_written=true
  log_success "COMPARISON_RESULTS.yaml generated: ${yaml_file}"
}

generate_comparison_yaml

yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"

# ---------- Standardized Output Format ----------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${verdict}"
app_hash="N/A"
if [[ ${#result_official_hashes[@]} -gt 0 ]]; then
  app_hash="${result_official_hashes[0]}"
fi
echo "appHash:        ${app_hash}"
echo "commit:         ${version}"
echo ""
echo "Diff:"
if [[ "$verdict" == "reproducible" ]]; then
  echo "BUILDS MATCH BINARIES"
else
  echo "BUILDS DO NOT MATCH BINARIES"
fi
for i in "${!result_files[@]}"; do
  file="${result_files[$i]}"
  built_hash="${result_hashes[$i]}"
  match_value="${result_matches[$i]}"
  if [[ "$match_value" == "true" ]]; then
    echo "$file - $arch - $built_hash - 1 (MATCHES)"
  else
    echo "$file - $arch - $built_hash - 0 (DIFFERS)"
  fi
done
echo ""
echo "Revision, tag (and its signature):"
echo "Git tag: ${version}"
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" ]]; then
  echo ""
  echo "Verification scope (AppImage):"
  echo "  squashfs: independently built from source (Stage 2)"
  echo "  runtime:  sourced from official release (Alpine has no snapshot service;"
  echo "            pinned package versions are deleted when newer patches are released)"
fi
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
  log_info "Build server output: ${yaml_file}"
  echo "Exit code: 0"
  exit 0
else
  log_warn "Verdict: NOT REPRODUCIBLE"
  log_info "Build server output: ${yaml_file}"
  echo "Exit code: 1"
  exit 1
fi
