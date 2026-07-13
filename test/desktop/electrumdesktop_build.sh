#!/usr/bin/env bash
# ==============================================================================
# electrumdesktop_build.sh - Electrum Desktop Reproducible Build Verification
# ==============================================================================
# Version:          v0.15.0
# Organization:     WalletScrutiny.com
# Last modified by: Claude Fable 5 (WalletScrutiny session)
# Last modified on: 2026-07-13
# Project:          https://github.com/spesmilo/electrum
# ==============================================================================
# MIT License. Provided as-is for reproducible-build verification and security
# research, without warranty; you assume all risk and responsibility for lawful use.
# Build paths / methodology + full history: script-notes/desktop/electrum/changelog.md
# ==============================================================================

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
SCRIPT_VERSION="v0.15.0"

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
  $(basename "$0") --version 4.6.2 --arch win64 --type setup          # One Windows type (setup|portable|standalone)
  $(basename "$0") --version 4.6.2 --arch x86_64-linux-gnu --type appimage
  $(basename "$0") --version 4.6.2 --arch x86_64-linux-gnu --type tarball
  $(basename "$0") --version 4.7.2 --arch x86_64-linux-gnu --type appimage --binary ~/Downloads/electrum-4.7.2-x86_64.AppImage

Requirements: Docker or Podman, internet, ~5GB disk space

Output: exit 0 reproducible / exit 1 differs or failed; COMPARISON_RESULTS.yaml;
  standardized block between ===== Begin/End Results =====

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
electrum_raw="https://raw.githubusercontent.com/spesmilo/electrum/${version}"

if [[ "$arch" == "win64" ]]; then
  # Pre-flight: fetch upstream's win64 pins at this tag (changelog v0.15.0)
  log_info "Fetching win64 build constants from Electrum ${version} source..."
  win_upstream_df=$(curl -sf "${electrum_raw}/contrib/build-wine/Dockerfile" || true)
  WIN_BASE_IMAGE=$(echo "$win_upstream_df" | grep -m1 '^FROM ' | awk '{print $2}' || true)
  WINE_VER=$(echo "$win_upstream_df" | grep -oE 'WINEVERSION="[0-9.]+' | head -1 | cut -d'"' -f2 || true)
  WIN_SNAPSHOT=$(curl -sf "${electrum_raw}/contrib/build-wine/apt.sources.list" \
    | grep -oE '[0-9]{8}T[0-9]{6}Z' | head -1 || true)
  _t="${WIN_BASE_IMAGE#*:}"; WIN_CODENAME="${_t%%@*}"
  if [[ -z "$WIN_BASE_IMAGE" || -z "$WINE_VER" || -z "$WIN_SNAPSHOT" || -z "$WIN_CODENAME" ]]; then
    log_error "Failed to fetch win64 build constants from Electrum ${version} -- verify the tag exists"
    echo "Exit code: 1"
    exit 1
  fi
  log_success "Base image: ${WIN_BASE_IMAGE} | Wine: ${WINE_VER}~${WIN_CODENAME}-1 | snapshot: ${WIN_SNAPSHOT}"

  cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
FROM __WIN_BASE_IMAGE__

ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

ARG VERSION
ARG UID=1000
ENV ELECTRUM_VERSION=${VERSION}
ENV USER="user"
ENV HOME_DIR="/home/${USER}"
ENV WORK_DIR="/opt/wine64/drive_c"

RUN apt-get update -qq > /dev/null && apt-get install -qq --yes --no-install-recommends \
    ca-certificates

RUN echo "deb https://snapshot.debian.org/archive/debian/__WIN_SNAPSHOT__/ __WIN_CODENAME__ main" > /etc/apt/sources.list && \
    echo "Package: *" > /etc/apt/preferences.d/snapshot && \
    echo "Pin: origin \"snapshot.debian.org\"" >> /etc/apt/preferences.d/snapshot && \
    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/snapshot

RUN dpkg --add-architecture i386 && \
    apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        wget gnupg2 dirmngr python3 python3-pip python3-venv \
        git curl p7zip-full make cmake pkgconf mingw-w64 mingw-w64-tools autotools-dev \
        autoconf autopoint libtool gettext nsis sudo osslsigncode && \
    rm -rf /var/lib/apt/lists/*

RUN WINEVERSION="__WINE_VER__~__WIN_CODENAME__-1" && \
    wget -nc https://dl.winehq.org/wine-builds/winehq.key && \
    echo "d965d646defe94b3dfba6d5b4406900ac6c81065428bf9d9303ad7a72ee8d1b8 winehq.key" | sha256sum -c - && \
    mkdir -p /etc/apt/keyrings && \
    cat winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/winehq.gpg] https://dl.winehq.org/wine-builds/debian/ __WIN_CODENAME__ main" > /etc/apt/sources.list.d/winehq.list && \
    rm winehq.key && \
    apt-get update -q && \
    apt-get install -qy --allow-downgrades \
        wine-stable-amd64:amd64=${WINEVERSION} \
        wine-stable-i386:i386=${WINEVERSION} \
        wine-stable:amd64=${WINEVERSION} \
        winehq-stable:amd64=${WINEVERSION} && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --uid $UID --create-home --shell /bin/bash ${USER} && \
    usermod -append --groups sudo ${USER} && \
    echo "%sudo ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p ${WORK_DIR} /opt/wine64 /output && \
    chown -R ${USER}:${USER} ${WORK_DIR} /opt/wine64 /output

USER ${USER}

RUN git clone https://github.com/spesmilo/electrum.git ${WORK_DIR}/electrum

WORKDIR ${WORK_DIR}/electrum

RUN git checkout ${ELECTRUM_VERSION}

RUN python3 -m venv ${HOME_DIR}/.venv && \
    ${HOME_DIR}/.venv/bin/pip install --no-cache-dir \
        -r contrib/deterministic-build/requirements-build-base.txt \
        -r contrib/deterministic-build/requirements-build-wine.txt

ENV PATH="${HOME_DIR}/.venv/bin:${PATH}"

RUN cd contrib/build-wine && ./make_win.sh

RUN cp contrib/build-wine/dist/*.exe /output/

CMD ["/bin/bash"]
DOCKERFILE_EOF

  sed -i "s|__WIN_BASE_IMAGE__|${WIN_BASE_IMAGE}|g" "$dockerfile_path"
  sed -i "s|__WIN_SNAPSHOT__|${WIN_SNAPSHOT}|g" "$dockerfile_path"
  sed -i "s|__WIN_CODENAME__|${WIN_CODENAME}|g" "$dockerfile_path"
  sed -i "s|__WINE_VER__|${WINE_VER}|g" "$dockerfile_path"

elif [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" ]]; then
  # ============================================================================
  # PRE-FLIGHT: Fetch build constants from Electrum source at this version tag
  # These values are version-specific; hardcoding them produces wrong builds for
  # any release other than the one they were copied from.
  # ============================================================================
  log_info "Fetching AppImage build constants from Electrum ${version} source..."

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
  # STAGE 1: Obtain type2-runtime binary
  # Primary: build from source. Fallback: extract from official AppImage.
  # Full design rationale: script-notes/desktop/electrum/changelog.md (v0.13.0)
  # ============================================================================

  # Locate the byte offset where the SquashFS starts inside an AppImage
  # (ELF64 program-header parse for the scan floor, then hsqs magic scan;
  # the untrusted AppImage is never executed). Logs go to stderr so command
  # substitution captures only the offset.
  find_squashfs_offset() {
    local appimage="$1"
    local min_scan_offset=4096
    local elf_parse elf_max_end sfs_offset _phoff _phentsize _phnum _ph_total

    elf_parse=$(od -A n -j 0 -N 64 -t u1 -v "$appimage" 2>/dev/null | \
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
      elf_max_end=$(od -A n -j "$_phoff" -N "$_ph_total" -t u1 -v "$appimage" 2>/dev/null | \
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
        log_info "ELF PT_LOAD end: ${elf_max_end} -- scanning for squashfs magic from there" >&2
      else
        log_warn "ELF header parse failed; scanning for squashfs magic from offset 4096" >&2
      fi
    fi

    # od -A d outputs 16 bytes per line with decimal address; scan every 4-byte window.
    # POSIX awk only. Early awk exit sends SIGPIPE to od; disable pipefail temporarily.
    set +o pipefail
    sfs_offset=$(od -A d -t x1 "$appimage" | awk -v floor="$min_scan_offset" '
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
    echo "$sfs_offset"
  }

  # Build type2-runtime from source. Logic inlined from:
  #   electrum contrib/build-linux/appimage/make_type2_runtime.sh (tag ${version})
  #   type2-runtime scripts/docker/{build-with-docker.sh,create-build-container.sh}
  #     (commit ${TYPE2_RUNTIME_COMMIT})
  # Success: $workspace/runtime-x86_64 exists, returns 0. Any failure returns 1
  # so the caller falls back to official-AppImage extraction.
  build_runtime_from_source() {
    local src_dir="$workspace/type2-runtime-src"
    local out_dir="$workspace/runtime-build-out"
    local patch_file="$workspace/type2-runtime-reproducible-build.patch"
    local img="type2-runtime-build:${version}-$$"

    log_info "Stage 1: Building type2-runtime from source (commit ${TYPE2_RUNTIME_COMMIT:0:12}...)"

    # Upstream's reproducibility patch (absent at older tags -> fall back)
    if ! curl -sf -o "$patch_file" \
        "${electrum_raw}/contrib/build-linux/appimage/patches/type2-runtime-reproducible-build.patch"; then
      log_warn "type2-runtime reproducible-build patch not found at electrum tag ${version}"
      return 1
    fi

    # Clone at the pinned commit + apply patch (root inside throwaway container:
    # apk needs it; integrity comes from the full-SHA checkout)
    rm -rf "$src_dir" "$out_dir"
    mkdir -p "$out_dir"
    if ! ${container_cmd} run --rm -v "$workspace:/ws:rw" alpine sh -c "
        apk add --no-cache -q git >/dev/null 2>&1 &&
        git config --global --add safe.directory /ws/type2-runtime-src &&
        git clone -q https://github.com/AppImage/type2-runtime.git /ws/type2-runtime-src &&
        cd /ws/type2-runtime-src &&
        git checkout -q ${TYPE2_RUNTIME_COMMIT} &&
        git apply /ws/type2-runtime-reproducible-build.patch &&
        chown -R ${host_uid}:${host_gid} /ws/type2-runtime-src"; then
      log_warn "type2-runtime clone/checkout/patch failed"
      return 1
    fi

    # Pinned-Alpine build image (context = repo root, as create-build-container.sh does)
    if ! ${container_cmd} build --platform linux/amd64 -t "$img" \
        -f "$src_dir/scripts/docker/Dockerfile" "$src_dir"; then
      log_warn "type2-runtime build image failed (pinned Alpine packages may no longer be available)"
      return 1
    fi

    # Run the patched build-runtime.sh (same mounts/user as create-build-container.sh)
    if ! ${container_cmd} run --rm -u "${host_uid}:${host_gid}" --platform linux/amd64 \
        -w /ws -v "$src_dir:/ws:rw" -v "$out_dir:/ws/out:rw" \
        -e ARCH=x86_64 "$img" bash scripts/build-runtime.sh; then
      log_warn "type2-runtime source build failed"
      return 1
    fi

    if [[ ! -f "$out_dir/runtime-x86_64" ]]; then
      log_warn "runtime-x86_64 missing after source build"
      return 1
    fi
    cp "$out_dir/runtime-x86_64" "$workspace/runtime-x86_64"
    return 0
  }
  ext_cache_dir="${execution_dir}/.cache/type2-runtime/${version}-${TYPE2_RUNTIME_COMMIT}-offset-v3"
  ext_cache_file="${ext_cache_dir}/runtime-x86_64"

  if [[ "$fresh" == "true" ]]; then
    rm -f "$ext_cache_file"
    log_info "Runtime cache cleared for ${version} (commit ${TYPE2_RUNTIME_COMMIT:0:12}) (--fresh)"
  fi

  # runtime_source drives scope wording, YAML notes, and component comparison.
  # The source-built runtime is deliberately NOT cached: it is rebuilt on every
  # run so the "independently built from source" claim holds for THIS run.
  runtime_source=""
  if build_runtime_from_source; then
    runtime_hash=$(sha256sum "$workspace/runtime-x86_64" | cut -d' ' -f1)
    log_success "type2-runtime built from source: ${runtime_hash}"
    runtime_source="source-build"
  elif [[ -f "$ext_cache_file" ]]; then
    log_warn "Runtime source build unavailable -- falling back to official-AppImage extraction"
    log_info "Stage 1 (fallback): Loading extracted type2-runtime from cache (${version}, commit ${TYPE2_RUNTIME_COMMIT:0:12}...)"
    cp "$ext_cache_file" "$workspace/runtime-x86_64"
    runtime_hash=$(sha256sum "$workspace/runtime-x86_64" | cut -d' ' -f1)
    log_success "type2-runtime (extracted) loaded from cache: ${runtime_hash}"
    runtime_source="official-extraction"
  else
    log_warn "Runtime source build unavailable -- falling back to official-AppImage extraction"
    log_info "Stage 1 (fallback): Extracting type2-runtime from official AppImage..."

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

    sfs_offset=$(find_squashfs_offset "$seed_appimage")
    if [[ -z "$sfs_offset" || "$sfs_offset" -le 0 ]]; then
      log_error "Could not locate SquashFS magic (hsqs) in AppImage --cannot extract runtime"
      echo "Exit code: 1"
      exit 1
    fi
    log_info "Runtime size: ${sfs_offset} bytes (SquashFS at offset ${sfs_offset})"

    dd if="$seed_appimage" of="$workspace/runtime-x86_64" \
       bs=1 count="$sfs_offset" status=none

    mkdir -p "$ext_cache_dir"
    cp "$workspace/runtime-x86_64" "$ext_cache_file"
    runtime_hash=$(sha256sum "$workspace/runtime-x86_64" | cut -d' ' -f1)
    log_success "type2-runtime extracted and cached: ${runtime_hash}"
    runtime_source="official-extraction"
  fi

  cd "$workspace"

  # ============================================================================
  # STAGE 2: Build AppImage (Debian Bullseye container)
  # ============================================================================
  log_info "Stage 2: Generating Linux AppImage Dockerfile (Debian Bullseye)..."
  cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
FROM debian:bullseye@__BASE_IMAGE_DIGEST__

ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

ARG VERSION
ARG UID=1000
ENV ELECTRUM_VERSION=${VERSION}
ENV USER="user"
ENV HOME_DIR="/home/${USER}"
ENV WORK_DIR="/opt/electrum"

RUN apt-get update -qq > /dev/null && apt-get install -qq --yes --no-install-recommends \
    ca-certificates

RUN echo "deb https://snapshot.debian.org/archive/debian/__SNAPSHOT_DATE__/ bullseye main" > /etc/apt/sources.list && \
    echo "deb-src https://snapshot.debian.org/archive/debian/__SNAPSHOT_DATE__/ bullseye main" >> /etc/apt/sources.list && \
    echo "Package: *" > /etc/apt/preferences.d/snapshot && \
    echo "Pin: origin \"snapshot.debian.org\"" >> /etc/apt/preferences.d/snapshot && \
    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/snapshot

# python3 (system) needed by contrib/locale/stats.py; make_appimage.sh compiles its own
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

RUN useradd --uid $UID --create-home --shell /bin/bash ${USER} && \
    mkdir -p ${WORK_DIR} /output && \
    chown -R ${USER}:${USER} ${WORK_DIR} /output

USER ${USER}

RUN git clone https://github.com/spesmilo/electrum.git ${WORK_DIR}

WORKDIR ${WORK_DIR}

RUN git checkout ${ELECTRUM_VERSION}

RUN mkdir -p ${WORK_DIR}/contrib/build-linux/appimage/.cache/appimage/type2-runtime

CMD ["/bin/bash"]
DOCKERFILE_EOF

  sed -i "s|__BASE_IMAGE_DIGEST__|${BASE_IMAGE_DIGEST}|g" "$dockerfile_path"
  sed -i "s|__SNAPSHOT_DATE__|${SNAPSHOT_DATE}|g" "$dockerfile_path"

elif [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "tarball" ]]; then
  log_info "Generating Linux Tarball Dockerfile (Debian Bookworm)..."
  cat > "$dockerfile_path" <<'DOCKERFILE_EOF'
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

RUN echo "deb https://snapshot.debian.org/archive/debian/20240617T085507Z/ bookworm main" > /etc/apt/sources.list && \
    echo "deb-src https://snapshot.debian.org/archive/debian/20240617T085507Z/ bookworm main" >> /etc/apt/sources.list && \
    echo "Package: *" > /etc/apt/preferences.d/snapshot && \
    echo "Pin: origin \"snapshot.debian.org\"" >> /etc/apt/preferences.d/snapshot && \
    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/snapshot

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

RUN useradd --uid $UID --non-unique --create-home --shell /bin/bash ${USER} && \
    mkdir -p ${WORK_DIR} /output && \
    chown -R ${USER}:${USER} ${WORK_DIR} /output

USER ${USER}

# Clone repository
RUN git clone https://github.com/spesmilo/electrum.git ${WORK_DIR}

WORKDIR ${WORK_DIR}

# Checkout version
RUN git checkout ${ELECTRUM_VERSION}

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

# Strict semantics: an extraction-fallback run may not claim reproducible ->
# downgrade to ftbfs; a mismatch stays not_reproducible (changelog v0.14.0)
runtime_fallback_downgrade=false
if [[ "${runtime_source:-}" == "official-extraction" && "$verdict" == "reproducible" ]]; then
  verdict="ftbfs"
  runtime_fallback_downgrade=true
fi

# ---------- Component Comparison (AppImage: runtime | squashfs) ----------
# Evidence only; verdict = whole-file hash + fallback ftbfs downgrade (v0.14.0)
official_runtime_prefix_hash=""
built_runtime_prefix_hash=""
official_sfs_hash=""
built_sfs_hash=""
srcbuilt_runtime_hash=""
runtime_component_note=""
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" ]]; then
  official_appimage="$official_dir/${official_files[0]}"
  built_appimage="$built_dir/${official_files[0]}"
  if [[ -f "$official_appimage" && -f "$built_appimage" ]]; then
    echo ""
    log_info "=============================================="
    log_info "Component Comparison (runtime | squashfs)"
    log_info "=============================================="
    official_sfs_offset=$(find_squashfs_offset "$official_appimage")
    built_sfs_offset=$(find_squashfs_offset "$built_appimage")
    if [[ -n "$official_sfs_offset" && -n "$built_sfs_offset" ]]; then
      log_info "SquashFS offset: official=${official_sfs_offset} built=${built_sfs_offset}"
      head -c "$official_sfs_offset" "$official_appimage" > "$workspace/official-runtime-prefix.bin"
      official_runtime_prefix_hash=$(sha256sum "$workspace/official-runtime-prefix.bin" | cut -d' ' -f1)
      built_runtime_prefix_hash=$(head -c "$built_sfs_offset" "$built_appimage" | sha256sum | cut -d' ' -f1)
      official_sfs_hash=$(tail -c +"$((official_sfs_offset + 1))" "$official_appimage" | sha256sum | cut -d' ' -f1)
      built_sfs_hash=$(tail -c +"$((built_sfs_offset + 1))" "$built_appimage" | sha256sum | cut -d' ' -f1)
      srcbuilt_runtime_hash=$(sha256sum "$workspace/runtime-x86_64" | cut -d' ' -f1)
      log_info "Runtime  (official AppImage prefix) SHA256: ${official_runtime_prefix_hash}"
      log_info "Runtime  (built AppImage prefix)    SHA256: ${built_runtime_prefix_hash}"
      log_info "Runtime  (Stage 1, pre-assembly)    SHA256: ${srcbuilt_runtime_hash} (${runtime_source})"
      log_info "SquashFS (official)                 SHA256: ${official_sfs_hash}"
      log_info "SquashFS (built)                    SHA256: ${built_sfs_hash}"
      if [[ "$official_sfs_hash" == "$built_sfs_hash" ]]; then
        log_success "SquashFS payloads are byte-identical"
      else
        log_warn "SquashFS payloads DIFFER"
      fi
      if [[ "$runtime_source" == "source-build" ]]; then
        # Byte-level runtime analysis (.digest_md5 is filled by appimagetool at
        # assembly; source build carries zeros there -- changelog v0.13.0).
        # Full byte diff to file; terminal preview capped at 5 lines.
        cmp -l "$workspace/runtime-x86_64" "$workspace/official-runtime-prefix.bin" \
          > "$workspace/diff_runtime_cmp.txt" 2>&1 || true
        cmp_lines=$(wc -l < "$workspace/diff_runtime_cmp.txt")
        log_info "Runtime bytes differing (source-built vs official prefix): ${cmp_lines}"
        if (( cmp_lines > 0 )); then
          head -5 "$workspace/diff_runtime_cmp.txt"
          if (( cmp_lines > 5 )); then
            log_info "... full byte diff in ${workspace}/diff_runtime_cmp.txt"
          fi
        fi
        # Mask .digest_md5 (located via ELF section headers) in both, compare rest
        cat > "$workspace/compare_runtime_masked.py" <<'PYEOF'
import struct, sys
def read(p):
    with open(p, "rb") as f:
        return f.read()
def digest_section(data):
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    shnum = struct.unpack_from("<H", data, 0x3C)[0]
    shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    stroff = struct.unpack_from("<Q", data, shoff + shstrndx * shentsize + 0x18)[0]
    for i in range(shnum):
        o = shoff + i * shentsize
        nameoff = struct.unpack_from("<I", data, o)[0]
        name = data[stroff + nameoff:data.index(b"\0", stroff + nameoff)].decode()
        if name == ".digest_md5":
            return struct.unpack_from("<Q", data, o + 0x18)[0], struct.unpack_from("<Q", data, o + 0x20)[0]
    return None, None
built, official = read(sys.argv[1]), read(sys.argv[2])
if len(built) != len(official):
    print(f"sizes differ: built={len(built)} official={len(official)}")
    sys.exit(0)
off, size = digest_section(built)
ooff, osize = digest_section(official)
if off is None or ooff is None:
    print(f"digest_md5_section=not-found (built={off} official={ooff})")
    sys.exit(0)
if (off, size) != (ooff, osize):
    print(f"digest_md5_section MISMATCH: built offset {off} size {size} vs official offset {ooff} size {osize}")
    print("masked_identical=no")
    sys.exit(0)
print(f"digest_md5_section=offset {off} (0x{off:x}), size {size} (same offset/size in both ELFs)")
bm, om = bytearray(built), bytearray(official)
bm[off:off + size] = b"\0" * size
om[off:off + size] = b"\0" * size
print("masked_identical=" + ("yes" if bm == om else "no"))
PYEOF
        masked_result=$(${container_cmd} run --rm -u "${host_uid}:${host_gid}" \
          -v "$workspace:/ws:ro" "${image_name}" \
          python3 /ws/compare_runtime_masked.py /ws/runtime-x86_64 /ws/official-runtime-prefix.bin) \
          || masked_result="masked comparison failed"
        echo "$masked_result"
        if echo "$masked_result" | grep -q "masked_identical=yes"; then
          runtime_component_note="source-built; byte-identical to official modulo 16-byte .digest_md5 (embedded by appimagetool at assembly)"
          log_success "Runtime: source-built binary is byte-identical to official (modulo .digest_md5)"
        else
          runtime_component_note="source-built; DIFFERS beyond .digest_md5 -- see diff_runtime_cmp.txt"
          log_warn "Runtime: source-built binary differs from official beyond .digest_md5"
        fi
      else
        runtime_component_note="sourced from official release (extraction fallback); runtime comparison is not independent evidence"
        log_warn "Runtime was extracted from the official AppImage -- its comparison is not independent evidence"
      fi
    else
      log_warn "Could not locate squashfs offset in one of the AppImages -- component comparison skipped"
    fi
  fi
fi

# ---------- Generate YAML Comparison Results ----------
generate_comparison_yaml() {
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"

  log_info "Generating COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
EOF

  if [[ "${runtime_source:-}" == "official-extraction" ]]; then
    if [[ "$runtime_fallback_downgrade" == "true" ]]; then
      echo "notes: verdict downgraded to ftbfs -- runtime failed to build from source (extraction fallback); whole-file hash MATCHED official and squashfs was independently rebuilt, but the runtime was not independently verified. Human review required for any scoped verdict." >> "$yaml_file"
    else
      echo "notes: AppImage runtime sourced from official release (runtime source build unavailable); squashfs independently rebuilt from source" >> "$yaml_file"
    fi
  fi

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
echo "version:        ${version}"
echo "verdict:        ${verdict}"
app_hash="N/A"
if [[ ${#result_official_hashes[@]} -gt 0 ]]; then
  app_hash="${result_official_hashes[0]}"
fi
echo "appHash:        ${app_hash}"
echo "commit:         ${version}"
echo ""
echo "Diff:"
# Reflects file comparison; verdict may be ftbfs-downgraded above
if (( diff_count == 0 && match_count > 0 )); then
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
  if [[ "$runtime_source" == "source-build" ]]; then
    echo "  runtime:  independently built from source (Stage 1; upstream"
    echo "            make_type2_runtime.sh logic, pinned Alpine image + packages)"
  else
    echo "  runtime:  sourced from official release (Alpine has no snapshot service;"
    echo "            pinned package versions are deleted when newer patches are released)"
  fi
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
if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" && -n "$official_runtime_prefix_hash" ]]; then
  log_info "Runtime SHA256 (built, ${runtime_source}): ${srcbuilt_runtime_hash}"
  log_info "Runtime SHA256 (official AppImage prefix): ${official_runtime_prefix_hash}"
  log_info "Runtime status: ${runtime_component_note}"
  log_info "SquashFS SHA256 (official): ${official_sfs_hash}"
  log_info "SquashFS SHA256 (built): ${built_sfs_hash}"
fi

if [[ "$arch" == "x86_64-linux-gnu" && "$build_type" == "appimage" && "${runtime_source:-}" == "official-extraction" ]]; then
  log_warn "=============================================="
  log_warn "RUNTIME NOT INDEPENDENTLY VERIFIED"
  log_warn "The AppImage runtime was sourced from the official release (extraction"
  log_warn "fallback -- runtime source build unavailable)."
  if [[ "$runtime_fallback_downgrade" == "true" ]]; then
    log_warn "Whole-file hash MATCHED official, but the verdict is downgraded to"
    log_warn "FTBFS: the runtime failed to build from source. Component evidence"
    log_warn "above is diagnostic; any scoped verdict requires human review."
  fi
  log_warn "=============================================="
fi

if [[ "$verdict" == "reproducible" ]]; then
  log_success "Verdict: REPRODUCIBLE"
  log_info "Build server output: ${yaml_file}"
  echo "Exit code: 0"
  exit 0
elif [[ "$verdict" == "ftbfs" ]]; then
  log_warn "Verdict: FTBFS"
  log_info "Build server output: ${yaml_file}"
  echo "Exit code: 1"
  exit 1
else
  log_warn "Verdict: NOT REPRODUCIBLE"
  log_info "Build server output: ${yaml_file}"
  echo "Exit code: 1"
  exit 1
fi
