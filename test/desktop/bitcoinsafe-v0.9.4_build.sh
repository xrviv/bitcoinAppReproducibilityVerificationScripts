#!/usr/bin/env bash
# ======================================================================================
# bitcoinsafe-v0.9.4_build.sh - Bitcoin Safe Desktop Reproducible Build Verification
# ======================================================================================
# Version:       v0.9.4
# Organization:  WalletScrutiny.com
# Last Modified: 2026-10-15
# Project:       https://github.com/andreasgriffin/bitcoin-safe
# LICENSE: MIT License
#
# DISCLAIMER: Please examine this script yourself prior to running it. It is provided
# as-is without warranty and may contain bugs or security vulnerabilities. It runs Docker
# containers, downloads source code and builds, using significant CPU, memory and disk.
#
# SCRIPT SUMMARY:
# - Downloads official Bitcoin Safe release artifacts from GitHub releases
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible build using Poetry build system
# - Compares built artifacts against official releases using binary analysis
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Documents differences and generates detailed reproducibility assessment report
#
# ======================================================================================

set -euo pipefail

# ======================================================================================
# CONFIGURATION
# ======================================================================================

APP_ID="bitcoin.safe"
SCRIPT_VERSION="v0.9.4"
REPO_URL="https://github.com/andreasgriffin/bitcoin-safe.git"
RELEASE_BASE="https://github.com/andreasgriffin/bitcoin-safe/releases/download"

# Release signing key, pinned by fingerprint. Published on the project website
# (https://bitcoin-safe.org/en/download/) alongside every download link, which is a
# different host from the GitHub release assets it signs.
SIGNING_KEY_FPR="2759AA7148568ECCB03B76301D82124B440F612D"
SIGNING_KEY_URL="https://keys.openpgp.org/vks/v1/by-fingerprint/${SIGNING_KEY_FPR}"
SIG_STATUS="not checked"

# Bootstrap image, pinned by digest; apt uses the Debian snapshot it was built from.
BASE_IMAGE="docker.io/library/python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1"
SCRIPT_HASH="$(sha256sum "$(readlink -f "$0")" | cut -d' ' -f1)"

# Build configuration variables
NEEDS_SIGNATURE_STRIP=false
BINARY_FILE=""
CHECKED_OUT_TAG=""
SOURCE_COMMIT=""
APP_HASH=""; OFFICIAL_HASH=""; BUILT_HASH=""; COMPARE_BASIS="file as downloaded"
MATCH_STATUS="false"; VERDICT_STATUS="not_reproducible"

# Resolve script directory (for COMPARISON_RESULTS.yaml output)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Color codes for output
readonly CYAN='\033[1;36m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# ======================================================================================
# LOGGING FUNCTIONS
# ======================================================================================

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { echo -e "${CYAN}[$(timestamp)] INFO${NC} $*"; }
log_warn() { echo -e "${YELLOW}[$(timestamp)] WARN${NC} $*"; }
log_error() { echo -e "${RED}[$(timestamp)] ERROR${NC} $*"; }
log_success() { echo -e "${GREEN}[$(timestamp)] SUCCESS${NC} $*"; }

# ======================================================================================
# HELP TEXT
# ======================================================================================

show_help() {
  local n="${0##*/}"
  cat <<EOF
Bitcoin Safe Desktop Reproducible Build Verification Script

Builds Bitcoin Safe from its release tag with upstream's Docker-based build
(tools/build.py) and compares the result with the official release artifact.

USAGE:
  ./$n --version <version> [--arch <arch>] [--type <type>] [--binary <file>]

  --version <version>    Release version (e.g. 2.1.3); inferred from --binary if omitted
  --arch <arch>          x86_64-linux (default) | x86_64-windows
  --type <type>          Linux: appimage (default) | deb | flatpak
                         Windows: portable (default) | setup
  --binary <file>        Official artifact to compare (skips the download)
  --help, -h             Show this help

OUTPUT:
  Exit code 0 reproducible, 1 not reproducible or failed, 2 invalid parameters.
  COMPARISON_RESULTS.yaml next to the script; results between ===== Begin/End Results =====.
  Each run gets a new workspace in the current directory (kept afterwards):
  ./bitcoinsafe_verification_<version>_<arch>_<type>_<epoch>-<pid>/{official,source,built}

EXAMPLES:
  ./$n --version 2.1.3
  ./$n --version 2.1.3 --arch x86_64-windows --type setup
  ./$n --binary ~/Downloads/Bitcoin-Safe-2.1.3-x86_64.AppImage.tar.gz

REQUIREMENTS:
  docker or podman (the only host dependency). Everything else runs in
  $BASE_IMAGE.
EOF
}

invalid() { log_error "$1"; exit 2; }

# ======================================================================================
# UTILITY FUNCTIONS
# ======================================================================================

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command_exists "$cmd"; then
    log_error "Required command '${cmd}' not found. ${hint}"
    exit 1
  fi
}

# Try candidate release paths (with and without 'v' prefix)
fetch_release_file() {
  local version="$1"
  local filename="$2"
  local dest="$3"

  for prefix in "v${version}" "${version}"; do
    local url="${RELEASE_BASE}/${prefix}/${filename}"
    if curl -fLs "$url" -o "$dest" 2>/dev/null; then
      log_success "Downloaded ${filename}"
      return 0
    fi
  done

  log_error "Failed to download ${filename}"
  rm -f "$dest"
  return 1
}

# ======================================================================================
# CONTAINER BOOTSTRAP
# ======================================================================================
# When invoked on the host, this function launches a python:3.12-slim container with
# all build dependencies, then re-invokes the script inside the container. The only
# host requirement is docker (or podman). The Docker socket is bind-mounted so that
# build.py can spawn sibling containers for compilation.

detect_build_socket() {
  if [[ -S "/var/run/docker.sock" ]]; then
    echo "/var/run/docker.sock"
    return 0
  fi

  if command_exists podman; then
    local podman_socket=""
    podman_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ -S "$podman_socket" ]]; then
      echo "$podman_socket"
      return 0
    fi

    podman_socket="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
    if [[ -n "$podman_socket" && -S "$podman_socket" ]]; then
      echo "$podman_socket"
      return 0
    fi
  fi

  return 1
}

bootstrap_container() {
  local CONTAINER_CMD=""
  local BUILD_SOCKET=""
  if command_exists docker; then
    CONTAINER_CMD="docker"
  elif command_exists podman; then
    CONTAINER_CMD="podman"
  else
    log_error "Neither Docker nor Podman found. Install one of them to proceed."
    log_error "  - Docker: https://docs.docker.com/engine/install/"
    log_error "  - Podman: https://podman.io/getting-started/installation"
    exit 1
  fi

  if ! BUILD_SOCKET="$(detect_build_socket)"; then
    log_error "No Docker-compatible build socket found."
    log_error "For Docker, ensure /var/run/docker.sock exists."
    log_error "For Podman, ensure podman.socket is running."
    exit 1
  fi

  local HOST_UID HOST_GID DOCKER_SOCK_GID OWNER
  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  DOCKER_SOCK_GID=$(stat -c '%g' "$BUILD_SOCKET" 2>/dev/null || echo "0")
  # Hand-back owner: under a rootless runtime, container root is the caller.
  OWNER="$HOST_UID:$HOST_GID"
  local rl
  if [[ "$CONTAINER_CMD" == podman ]]; then
    rl="$(podman info --format 'rootless={{.Host.Security.Rootless}}' 2>/dev/null || true)"
  else
    rl="$(docker info --format '{{.SecurityOptions}}' 2>/dev/null || true)"
  fi
  [[ "$rl" == *rootless=true* || "$rl" == *name=rootless* ]] && OWNER="0:0"

  local SCRIPT_PATH
  SCRIPT_PATH="$(readlink -f "$0")"

  # Per-run workspace in the caller's directory; never reused or deleted.
  local RUN_ID CNAME
  RUN_ID="$(date +%s)-$$"
  CNAME="ws-bitcoinsafe-${RUN_ID}"
  WORKDIR="$(pwd -P)/bitcoinsafe_verification_${VERSION}_${ARCH}_${BUILD_TYPE}_${RUN_ID}"
  mkdir "$WORKDIR" || { log_error "Cannot create workspace $WORKDIR"; exit 1; }

  log_info "Launching container for build environment..."
  log_info "Container image: $BASE_IMAGE"
  log_info "Container runtime: $CONTAINER_CMD"
  log_info "Workspace: $WORKDIR"

  # Build run args as array so we can conditionally add --binary mount
  local run_args=(
    --rm --name "$CNAME"
    -v "$WORKDIR:$WORKDIR"
    -v "$BUILD_SOCKET:/var/run/docker.sock"
    -v "$SCRIPT_PATH:$SCRIPT_PATH:ro"
    -v "$SCRIPT_DIR:$SCRIPT_DIR"
    -w "$WORKDIR"
    -e "_INSIDE_CONTAINER=1"
    -e "BS_WORKDIR=$WORKDIR"
    -e "BS_OWNER=$OWNER"
    -e "BS_YAML_DIR=$SCRIPT_DIR"
    -e "BS_SV=$SCRIPT_VERSION"
    -e "BS_CNAME=$CNAME"
    -e "BS_VERSION=$VERSION"
    -e "BS_ARCH=$ARCH"
    -e "BS_TYPE=$BUILD_TYPE"
    -e "BS_BINARY="
    -e "BS_SCRIPT_PATH=$SCRIPT_PATH"
    -e "HOST_UID=$HOST_UID"
    -e "HOST_GID=$HOST_GID"
    -e "DOCKER_SOCK_GID=$DOCKER_SOCK_GID"
  )

  # If --binary was provided, mount the file into the container at the same path
  if [[ -n "$BINARY_FILE" ]]; then
    local abs_binary
    abs_binary="$(readlink -f "$BINARY_FILE")"
    run_args+=( -v "$abs_binary:$abs_binary:ro" )
    run_args+=( -e "BS_BINARY=$abs_binary" )
  fi

  $CONTAINER_CMD run "${run_args[@]}" "$BASE_IMAGE" \
    bash -c '
      # On every exit (also stop/interrupt): end the build, remove upstream build
      # containers that mount this workspace, publish the YAML (ftbfs if none; none
      # on exit 2 or a stop, since ABS publishes any verdict), and hand the workspace back.
      W="$BS_WORKDIR"; Y="$W/COMPARISON_RESULTS.yaml"
      finish() {
        local s=$?
        trap - EXIT INT TERM
        kill -TERM -1 2>/dev/null; wait; sleep 2
        for c in $(docker ps -aq 2>/dev/null); do
          m=$(docker inspect -f "{{.Name}} {{range .Mounts}}{{.Source}}/ {{end}}" "$c" 2>/dev/null) || continue
          [[ "${m%% *}" != *"$BS_CNAME" && "$m" == *" $W/"* ]] && docker rm -f "$c" >/dev/null 2>&1
        done
        [[ -f "$Y" || "$s" -eq 2 || "$s" -eq 130 ]] || printf "script_version: %s\nverdict: ftbfs\nnotes: |\n  Stopped or failed before a verdict (exit %s).\n" "$BS_SV" "$s" > "$Y"
        [[ ! -f "$Y" ]] || { cp "$Y" "$BS_YAML_DIR/" && chown "$BS_OWNER" "$BS_YAML_DIR/COMPARISON_RESULTS.yaml"; } || s=1
        if ! chown -R "$BS_OWNER" "$W"; then
          echo "ERROR: Failed to restore workspace ownership: $W" >&2
          [[ "$s" -ne 0 ]] || s=1
        fi
        exit "$s"
      }
      trap finish EXIT
      trap "exit 130" INT TERM

      # Install dependencies (as root) from the Debian snapshot the image was built
      # from (its debian.sources carries the snapshot URL as a comment).
      sed -i -E "s|^# (http://snapshot\.debian\.org/\S+)$|URIs: \1|; /^URIs: http:\/\/deb\.debian\.org/d" /etc/apt/sources.list.d/debian.sources
      grep "^URIs:" /etc/apt/sources.list.d/debian.sources
      { apt-get -o Acquire::Check-Valid-Until=false update -qq && apt-get install -y -qq \
        git curl ca-certificates docker.io coreutils gnupg \
        build-essential \
        osslsigncode \
        libglib2.0-0 libgl1 libegl1 libfontconfig1 \
        libxkbcommon0 libxkbcommon-x11-0 \
        libxcb1 libxcb-xinerama0 libxcb-randr0 libxcb-render0 \
        libxcb-shm0 libxcb-shape0 libxcb-sync1 libxcb-xfixes0 \
        libxcb-xkb1 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
        libxcb-cursor0 libxcb-util1 libxcb-render-util0 \
        libx11-xcb1 libdbus-1-3 >/dev/null 2>&1; } &
      # Background + wait: bash defers traps until a foreground command ends.
      wait $! || { echo "ERROR: apt-get failed" >&2; exit 1; }

      # Create builder user matching host UID/GID
      groupadd -g "$HOST_GID" hostgrp 2>/dev/null || true
      groupadd -g "$DOCKER_SOCK_GID" dockerhost 2>/dev/null || true
      useradd -m -u "$HOST_UID" -g "$HOST_GID" builder 2>/dev/null || true
      usermod -aG dockerhost builder 2>/dev/null || true
      chown "$HOST_UID:$HOST_GID" "$W"

      # Re-invoke script as builder user (pass --binary if provided)
      su -p builder -c "export HOME=/home/builder && export PATH=\"/home/builder/.local/bin:\$PATH\" && cd \"$W\" && bash \"$BS_SCRIPT_PATH\" --version \"$BS_VERSION\" --arch \"$BS_ARCH\" --type \"$BS_TYPE\"${BS_BINARY:+ --binary \"$BS_BINARY\"}" &
      wait $!
    ' &
  local cpid=$! rc=0
  # Background + wait so INT/TERM reach this trap; docker stop gives the
  # container time to run its cleanup.
  trap "$CONTAINER_CMD stop -t 300 $CNAME >/dev/null 2>&1; wait $cpid || true; log_info 'Workspace kept: $WORKDIR'; exit 130" INT TERM
  wait "$cpid" || rc=$?
  trap - INT TERM
  log_info "Workspace kept: $WORKDIR"
  exit "$rc"
}

# ======================================================================================
# PARAMETER PARSING
# ======================================================================================

VERSION=""
ARCH=""
BUILD_TYPE=""

infer_metadata_from_binary() {
  local binary_name
  binary_name="$(basename "$BINARY_FILE")"

  if [[ -z "$VERSION" && "$binary_name" =~ ^Bitcoin-Safe-([0-9][0-9A-Za-z._-]*)- ]]; then
    VERSION="${BASH_REMATCH[1]}"
    log_info "Inferred version from --binary filename: $VERSION"
  fi

  case "$binary_name" in
    Bitcoin-Safe-*-x86_64.AppImage.tar.gz)
      [[ -n "$ARCH" ]] || ARCH="x86_64-linux"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="appimage"
      ;;
    Bitcoin-Safe-*-x86_64.deb)
      [[ -n "$ARCH" ]] || ARCH="x86_64-linux"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="deb"
      ;;
    Bitcoin-Safe-*-portable.exe)
      [[ -n "$ARCH" ]] || ARCH="x86_64-windows"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="portable"
      ;;
    Bitcoin-Safe-*-setup.exe)
      [[ -n "$ARCH" ]] || ARCH="x86_64-windows"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="setup"
      ;;
    Bitcoin-Safe-*-x86_64.flatpak)
      [[ -n "$ARCH" ]] || ARCH="x86_64-linux"
      [[ -n "$BUILD_TYPE" ]] || BUILD_TYPE="flatpak"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || invalid "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --arch)
        [[ $# -ge 2 ]] || invalid "--arch requires a value"
        ARCH="$2"
        shift 2
        ;;
      --type)
        [[ $# -ge 2 ]] || invalid "--type requires a value"
        BUILD_TYPE="$2"
        shift 2
        ;;
      --binary)
        [[ $# -ge 2 ]] || invalid "--binary requires a value"
        BINARY_FILE="$2"
        shift 2
        ;;
      --apk)
        # Accepted but unused (desktop app - no APK). Required by build server
        # which may pass --apk to all scripts. Must not fail per Rule 11.
        [[ $# -ge 2 ]] || invalid "--apk requires a value"
        log_info "Ignoring --apk parameter: Bitcoin Safe is a desktop app, not an Android app"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        # Silently ignore unrecognised parameters (build server may pass unknown flags)
        log_warn "Ignoring unknown parameter: $1"
        shift
        ;;
    esac
  done

  if [[ -n "$BINARY_FILE" ]]; then
    infer_metadata_from_binary
  fi

  if [[ -z "$VERSION" ]]; then
    invalid "Missing version. Pass --version or provide a recognizable Bitcoin Safe file with --binary."
  fi

  if [[ -z "$ARCH" ]]; then
    ARCH="x86_64-linux"
  fi

  # Default --type based on architecture if not explicitly provided
  if [[ -z "$BUILD_TYPE" ]]; then
    case "$ARCH" in
      x86_64-linux)   BUILD_TYPE="appimage" ;;
      x86_64-windows) BUILD_TYPE="portable" ;;
      *)              BUILD_TYPE="appimage" ;;
    esac
  fi
}

# ======================================================================================
# ARCHITECTURE AND TYPE MAPPING
# ======================================================================================

map_build_config() {
  local arch="$1"
  local type="$2"

  case "${arch}_${type}" in
    x86_64-linux_appimage)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-x86_64.AppImage.tar.gz"
      BUILD_TARGET="appimage"
      BUILT_PATTERN="*${VERSION}*.AppImage.tar.gz"
      ;;
    x86_64-linux_deb)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-x86_64.deb"
      BUILD_TARGET="deb"
      BUILT_PATTERN="*${VERSION}*.deb"
      ;;
    x86_64-windows_portable)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-portable.exe"
      BUILD_TARGET="windows"
      BUILT_PATTERN="*${VERSION}*portable.exe"
      NEEDS_SIGNATURE_STRIP=true
      ;;
    x86_64-windows_setup)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-setup.exe"
      BUILD_TARGET="windows"
      BUILT_PATTERN="*${VERSION}*setup.exe"
      NEEDS_SIGNATURE_STRIP=true
      ;;
    x86_64-linux_flatpak)
      OFFICIAL_FILENAME="Bitcoin-Safe-${VERSION}-x86_64.flatpak"
      BUILD_TARGET="flatpak"
      BUILT_PATTERN="*${VERSION}*.flatpak"
      ;;
    *)
      log_error "Unsupported architecture/type combination: ${arch}/${type}"
      log_error "Supported combinations:"
      log_error "  - x86_64-linux / appimage"
      log_error "  - x86_64-linux / deb"
      log_error "  - x86_64-linux / flatpak"
      log_error "  - x86_64-windows / portable"
      log_error "  - x86_64-windows / setup"
      exit 2
      ;;
  esac
}

# ======================================================================================
# DIRECTORY SETUP
# ======================================================================================

setup_workspace() {
  # Created on the host by bootstrap_container (per run, caller's directory).
  WORKDIR="${BS_WORKDIR:?run this script on the host, not inside a container}"
  OFFICIAL_DIR="$WORKDIR/official"
  SOURCE_DIR="$WORKDIR/source"
  REPO_DIR="$SOURCE_DIR/bitcoin-safe"
  BUILT_DIR="$WORKDIR/built"

  mkdir -p "$OFFICIAL_DIR" "$SOURCE_DIR" "$BUILT_DIR"
  
  log_info "Workspace: $WORKDIR"
  log_info "Version: $VERSION"
  log_info "Architecture: $ARCH"
  log_info "Build Type: $BUILD_TYPE"
}

# ======================================================================================
# REPOSITORY OPERATIONS
# ======================================================================================

prepare_repository() {
  log_info "Cloning repository..."
  git clone "$REPO_URL" "$REPO_DIR" || return 1

  local ref="v${VERSION}"
  if (cd "$REPO_DIR" && git rev-parse "$ref" >/dev/null 2>&1); then
    log_info "Checking out tag $ref"
    (cd "$REPO_DIR" && git checkout "$ref") || return 1
    CHECKED_OUT_TAG="$ref"
  else
    log_warn "Tag $ref not found, trying ${VERSION}"
    (cd "$REPO_DIR" && git checkout "$VERSION") || return 1
    CHECKED_OUT_TAG="$VERSION"
  fi

  (cd "$REPO_DIR" && git submodule update --init --recursive) || return 1

  SOURCE_COMMIT=$(cd "$REPO_DIR" && git rev-parse HEAD)
  export SOURCE_COMMIT
  if [[ "${BUILD_TYPE:-}" == "deb" ]]; then
    unset SOURCE_DATE_EPOCH
    log_info "SOURCE_DATE_EPOCH: unset (deb converter fallback, as used by the official release)"
  else
    SOURCE_DATE_EPOCH=$(cd "$REPO_DIR" && git log -1 --format=%ct HEAD)
    export SOURCE_DATE_EPOCH
    log_info "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
  fi
  log_info "SOURCE_COMMIT: $SOURCE_COMMIT"
}

# ======================================================================================
# BUILD PROCESS
# ======================================================================================

# Fixed name of the container upstream tools/build.py uses for Windows/wine builds.
readonly WINE_CONTAINER="bitcoin_safe-wine-builder-img-container"

# Clears any leftover upstream Windows-build container and waits until Docker
# confirms it is gone (it can wedge in "removal in progress"). See changelog.
cleanup_wine_container() {
  local waited=0 timeout=120 names
  # A failed query must not be mistaken for "container absent".
  if ! names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
    log_error "Unable to query Docker (daemon unreachable?); cannot verify build container state"
    return 1
  fi
  grep -qx "$WINE_CONTAINER" <<<"$names" || return 0
  log_info "Removing leftover Windows build container '$WINE_CONTAINER'..."
  docker rm -f "$WINE_CONTAINER" >/dev/null 2>&1 || true
  while true; do
    if ! names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
      log_error "Unable to query Docker while waiting for container removal"
      return 1
    fi
    grep -qx "$WINE_CONTAINER" <<<"$names" || break
    if (( waited >= timeout )); then
      log_error "Container '$WINE_CONTAINER' still present after ${timeout}s; Docker may be wedged (try: sudo systemctl restart docker)"
      return 1
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  log_success "Leftover Windows build container cleared"
  return 0
}

run_build() {
  log_info "Starting containerized build (this may take several minutes)..."

  local start_ts end_ts build_rc
  start_ts=$(date +%s)

  (
    cd "$REPO_DIR"
    export SOURCE_DATE_EPOCH
    export PYTHONHASHSEED=22
    export PYTHONIOENCODING="utf-8"
    export DOCKER_BUILDKIT=1

    # Install Poetry (python:3.12-slim base provides pip3)
    # Poetry version from upstream's own poetry.lock (dev dependency) at this tag
    local pv
    pv=$(grep -A1 '^name = "poetry"$' poetry.lock 2>/dev/null | sed -n 's/^version = "\(.*\)"$/\1/p')
    [[ -n "$pv" ]] || { log_error "Poetry version not found in poetry.lock"; exit 1; }
    log_info "Installing Poetry ${pv} (from poetry.lock)..."
    pip3 install --user "poetry==${pv}" >/dev/null 2>&1 || { log_error "pip install poetry==${pv} failed"; exit 1; }
    export PATH="$HOME/.local/bin:$PATH"
    log_info "Poetry version: $(poetry --version)"

    # Install project dependencies
    log_info "Installing project dependencies with Poetry..."
    poetry install || {
      log_error "Poetry install failed"
      exit 1
    }

    # Map BUILD_TARGET to build.py --targets argument
    # DEB requires AppImage first (it is converted from AppImage)
    local build_targets=""
    case "$BUILD_TARGET" in
      appimage)
        build_targets="appimage"
        ;;
      deb)
        build_targets="appimage deb"
        ;;
      windows)
        build_targets="windows"
        ;;
      flatpak)
        build_targets="flatpak"
        ;;
      *)
        log_error "Unsupported build target: ${BUILD_TARGET}"
        exit 1
        ;;
    esac

    # Windows builds share one upstream container name; serialize concurrent
    # setup/portable invocations and clear any leftover before building.
    if [[ "$BUILD_TARGET" == "windows" ]]; then
      # Serialize by locking the script's own file: it is bind-mounted at the
      # same host path (read-only) into every bootstrap container, so all
      # invocations share one inode. Advisory flock works on a read fd and
      # creates no lock file (self-contained; nothing to .gitignore).
      exec 9<"${BS_SCRIPT_PATH:-$0}"
      flock -w 1800 9 || { log_error "Timed out waiting for another Windows build"; exit 1; }
      cleanup_wine_container || exit 1
    fi

    log_info "Running: poetry run python tools/build.py --targets ${build_targets} --commit None"
    poetry run python tools/build.py --targets ${build_targets} --commit None || {
      log_error "Build failed"
      exit 1
    }
  )
  build_rc=$?

  end_ts=$(date +%s)
  BUILD_DURATION=$(( end_ts - start_ts ))

  if [[ $build_rc -ne 0 ]]; then
    log_error "Build failed after ${BUILD_DURATION}s"
    return 1
  fi

  log_success "Build completed in ${BUILD_DURATION}s"
  return 0
}

# ======================================================================================
# ARTIFACT COMPARISON
# ======================================================================================

download_official() {
  # If --binary was provided, use it directly instead of downloading
  if [[ -n "$BINARY_FILE" ]]; then
    if [[ ! -f "$BINARY_FILE" ]]; then
      log_error "--binary file not found: $BINARY_FILE"
      return 1
    fi
    OFFICIAL_FILE="$BINARY_FILE"
    OFFICIAL_FILENAME="$(basename "$BINARY_FILE")"
    log_info "Using provided binary as official artifact: $BINARY_FILE"
    APP_HASH=$(sha256sum "$OFFICIAL_FILE" | cut -d' ' -f1)
    return 0
  fi

  log_info "Downloading official artifact: $OFFICIAL_FILENAME"

  local dest="$OFFICIAL_DIR/$OFFICIAL_FILENAME"
  if fetch_release_file "$VERSION" "$OFFICIAL_FILENAME" "$dest"; then
    OFFICIAL_FILE="$dest"
    APP_HASH=$(sha256sum "$OFFICIAL_FILE" | cut -d' ' -f1)
    return 0
  else
    log_error "Failed to download official artifact"
    return 1
  fi
}

verify_official_signature() {
  # Verifies the downloaded release asset against the pinned signing key. Informational:
  # it never changes the reproducibility verdict, so every failure path returns 0.
  if [[ -n "$BINARY_FILE" ]]; then
    SIG_STATUS="skipped (--binary supplied, not a release download)"
    return 0
  fi
  if ! command_exists gpg; then
    SIG_STATUS="skipped (gpg unavailable)"
    return 0
  fi

  local sig="${OFFICIAL_FILE}.asc"
  local key="$OFFICIAL_DIR/signing-key.asc"
  local gpg_home="$OFFICIAL_DIR/gnupg"

  log_info "Verifying release signature against ${SIGNING_KEY_FPR}"
  if ! fetch_release_file "$VERSION" "${OFFICIAL_FILENAME}.asc" "$sig"; then
    SIG_STATUS="no .asc published for this artifact"
    log_warn "$SIG_STATUS"
    return 0
  fi
  if ! curl -fLs "$SIGNING_KEY_URL" -o "$key"; then
    SIG_STATUS="signing key fetch failed"
    log_warn "$SIG_STATUS"
    return 0
  fi

  rm -rf "$gpg_home"
  mkdir -p -m700 "$gpg_home"
  local out=""
  gpg --homedir "$gpg_home" --batch --quiet --import "$key" >/dev/null 2>&1 || true
  out="$(gpg --homedir "$gpg_home" --batch --status-fd 1 --verify "$sig" "$OFFICIAL_FILE" 2>/dev/null || true)"
  rm -rf "$gpg_home"

  # VALIDSIG carries the primary key fingerprint, so it is what pins the signer.
  if grep -q '^\[GNUPG:\] GOODSIG ' <<<"$out" && grep -q "^\[GNUPG:\] VALIDSIG .*${SIGNING_KEY_FPR}" <<<"$out"; then
    SIG_STATUS="good signature from ${SIGNING_KEY_FPR}"
    log_success "$SIG_STATUS"
  else
    SIG_STATUS="SIGNATURE VERIFICATION FAILED (expected ${SIGNING_KEY_FPR})"
    log_error "$SIG_STATUS"
  fi
  return 0
}

find_built_artifact() {
  log_info "Looking for built artifact matching: $BUILT_PATTERN"
  
  local found
  found=$(find "$REPO_DIR/dist" -maxdepth 1 -type f -name "$BUILT_PATTERN" 2>/dev/null | head -n1)
  
  if [[ -z "$found" ]]; then
    log_error "Built artifact not found in $REPO_DIR/dist"
    return 1
  fi

  BUILT_FILE="$BUILT_DIR/$(basename "$found")"
  cp "$found" "$BUILT_FILE"
  log_success "Found built artifact: $(basename "$BUILT_FILE")"
  return 0
}

strip_windows_signature() {
  local input_file="$1"
  local output_file="$2"

  log_info "Stripping signature from Windows executable..."

  # osslsigncode is installed in the bootstrap container (no sibling container needed).
  # Running it directly avoids Docker-socket permission issues when writing output files.
  local strip_output
  strip_output=$(osslsigncode remove-signature -in "$input_file" -out "$output_file" 2>&1) || true

  if [[ -f "$output_file" ]]; then
    log_success "Signature stripped successfully"
  elif echo "$strip_output" | grep -qiE "does not have any signature|no signature found"; then
    log_info "No signature found in $(basename "$input_file") - using file as-is"
    cp "$input_file" "$output_file"
  else
    log_error "Failed to strip signature: $strip_output"
    return 1
  fi

  return 0
}

print_diff_preview() {
  local diff_file="$1"
  local label="$2"
  local max_lines=5
  local total_lines=0

  [[ -f "$diff_file" ]] || return 0

  total_lines=$(wc -l < "$diff_file")
  echo "${label} (first ${max_lines} lines; full diff in ${diff_file}):"
  head -"${max_lines}" "$diff_file"
  if [[ "$total_lines" -gt "$max_lines" ]]; then
    echo "... (${total_lines} lines total)"
  fi
}

compare_artifacts() {
  if [[ ! -f "$BUILT_FILE" ]]; then
    log_error "Built file not found: $BUILT_FILE"
    return 1
  fi

  if [[ ! -f "$OFFICIAL_FILE" ]]; then
    log_error "Official file not found: $OFFICIAL_FILE"
    return 1
  fi

  local built_compare="$BUILT_FILE"
  local official_compare="$OFFICIAL_FILE"
  
  # For Windows builds, strip signatures before comparison
  if [[ "$NEEDS_SIGNATURE_STRIP" == "true" ]]; then
    log_info "Windows build detected - stripping signatures for comparison"

    local official_signed_hash built_signed_hash
    official_signed_hash=$(sha256sum "$OFFICIAL_FILE" | awk '{print $1}')
    built_signed_hash=$(sha256sum "$BUILT_FILE" | awk '{print $1}')
    log_info "Official SHA256 (pre-strip): $official_signed_hash"
    log_info "Built SHA256    (pre-strip): $built_signed_hash"

    built_compare="${WORKDIR}/$(basename "$BUILT_FILE").stripped"
    official_compare="${WORKDIR}/$(basename "$OFFICIAL_FILE").stripped"

    strip_windows_signature "$BUILT_FILE" "$built_compare" || return 1
    strip_windows_signature "$OFFICIAL_FILE" "$official_compare" || return 1
    COMPARE_BASIS="signature-stripped executables"
  fi

  BUILT_HASH=$(sha256sum "$built_compare" | awk '{print $1}')
  OFFICIAL_HASH=$(sha256sum "$official_compare" | awk '{print $1}')

  log_info "Built SHA256:    $BUILT_HASH"
  log_info "Official SHA256: $OFFICIAL_HASH"
  
  if [[ "$NEEDS_SIGNATURE_STRIP" == "true" ]]; then
    log_info "Note: Hashes are of signature-stripped executables"
  fi

  if [[ "$BUILT_HASH" == "$OFFICIAL_HASH" ]]; then
    MATCH_STATUS="true"
    VERDICT_STATUS="reproducible"
    log_success "Hashes match - Build is reproducible!"
    return 0
  fi

  # Tar.gz hashes differ -- if this is an AppImage tar.gz, extract and
  # compare the raw AppImage inside (tar metadata is often non-deterministic)
  if [[ "$built_compare" == *.AppImage.tar.gz ]]; then
    log_info "Tar.gz hashes differ - extracting raw AppImages for comparison..."

    local compare_dir="$WORKDIR/appimage_compare"
    mkdir -p "$compare_dir/built" "$compare_dir/official"

    tar xzf "$built_compare" -C "$compare_dir/built/"
    tar xzf "$official_compare" -C "$compare_dir/official/"

    local built_appimage official_appimage
    built_appimage=$(find "$compare_dir/built" -maxdepth 1 -name '*.AppImage' | head -n1)
    official_appimage=$(find "$compare_dir/official" -maxdepth 1 -name '*.AppImage' | head -n1)

    if [[ -z "$built_appimage" || -z "$official_appimage" ]]; then
      log_error "Could not extract AppImage from tar.gz"
      MATCH_STATUS="false"
      VERDICT_STATUS="not_reproducible"
      return 1
    fi

    local built_ai_hash official_ai_hash
    built_ai_hash=$(sha256sum "$built_appimage" | awk '{print $1}')
    official_ai_hash=$(sha256sum "$official_appimage" | awk '{print $1}')

    log_info "Raw AppImage Built SHA256:    $built_ai_hash"
    log_info "Raw AppImage Official SHA256: $official_ai_hash"

    if [[ "$built_ai_hash" == "$official_ai_hash" ]]; then
      BUILT_HASH="$built_ai_hash"
      OFFICIAL_HASH="$official_ai_hash"
      COMPARE_BASIS="raw AppImage inside the .tar.gz"
      MATCH_STATUS="true"
      VERDICT_STATUS="reproducible"
      log_success "Raw AppImage hashes match - Build is reproducible (tar.gz wrapper differs only)"
      return 0
    fi

    # Raw AppImages also differ -- extract contents and diff
    log_warn "Raw AppImage hashes also differ - running diff on extracted contents..."

    chmod +x "$built_appimage" "$official_appimage"

    local diff_output="$WORKDIR/diff-appimage-contents.txt"

    # Clean any stale extraction directories to prevent nesting
    rm -rf "$compare_dir/built/squashfs-root" "$compare_dir/built-squashfs"
    rm -rf "$compare_dir/official/squashfs-root" "$compare_dir/official-squashfs"

    (cd "$compare_dir/built" && ./*.AppImage --appimage-extract) >/dev/null 2>&1
    mv "$compare_dir/built/squashfs-root" "$compare_dir/built-squashfs"

    (cd "$compare_dir/official" && ./*.AppImage --appimage-extract) >/dev/null 2>&1
    mv "$compare_dir/official/squashfs-root" "$compare_dir/official-squashfs"

    diff -r --no-dereference "$compare_dir/built-squashfs" "$compare_dir/official-squashfs" > "$diff_output" 2>&1 || true

    local diff_lines
    diff_lines=$(wc -l < "$diff_output")
    log_info "AppImage content diff: ${diff_lines} lines written to ${diff_output}"

    if [[ "$diff_lines" -eq 0 ]]; then
      log_success "AppImage contents are identical (squashfs packaging differs)"
      BUILT_HASH="$built_ai_hash"
      OFFICIAL_HASH="$official_ai_hash"
      COMPARE_BASIS="raw AppImages differ; extracted contents identical"
      MATCH_STATUS="true"
      VERDICT_STATUS="reproducible"
      return 0
    fi

    log_warn "AppImage contents differ."
    print_diff_preview "$diff_output" "AppImage diff preview"

    BUILT_HASH="$built_ai_hash"
    OFFICIAL_HASH="$official_ai_hash"
    COMPARE_BASIS="raw AppImage inside the .tar.gz; extracted contents differ"
    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
    return 1
  fi

  # DEB hashes differ -- extract data and control, diff contents
  if [[ "$built_compare" == *.deb ]]; then
    log_info "DEB hashes differ - extracting and comparing package contents..."

    local compare_dir="$WORKDIR/deb_compare"
    rm -rf "$compare_dir"
    mkdir -p "$compare_dir/built-data" "$compare_dir/official-data"
    mkdir -p "$compare_dir/built-control" "$compare_dir/official-control"

    # Extract installed files (data) and package metadata (control)
    dpkg-deb -x "$built_compare" "$compare_dir/built-data"
    dpkg-deb -x "$official_compare" "$compare_dir/official-data"
    dpkg-deb -e "$built_compare" "$compare_dir/built-control"
    dpkg-deb -e "$official_compare" "$compare_dir/official-control"

    local data_diff="$WORKDIR/diff-deb-data.txt"
    local control_diff="$WORKDIR/diff-deb-control.txt"
    local diff_output="$WORKDIR/diff-deb-contents.txt"

    diff -r --no-dereference "$compare_dir/built-data" "$compare_dir/official-data" > "$data_diff" 2>&1 || true
    diff -r --no-dereference "$compare_dir/built-control" "$compare_dir/official-control" > "$control_diff" 2>&1 || true

    local data_lines control_lines
    data_lines=$(wc -l < "$data_diff")
    control_lines=$(wc -l < "$control_diff")

    # Combined report
    {
      echo "=== DEB Data Files (installed content): ${data_lines} diff lines ==="
      cat "$data_diff"
      echo ""
      echo "=== DEB Control Metadata: ${control_lines} diff lines ==="
      cat "$control_diff"
    } > "$diff_output"

    log_info "DEB data diff: ${data_lines} lines | control diff: ${control_lines} lines"
    log_info "Full diff written to ${diff_output}"

    # Data identical = reproducible (control metadata may differ cosmetically,
    # same logic as AppImage: outer packaging ≠ application content)
    if [[ "$data_lines" -eq 0 ]]; then
      if [[ "$control_lines" -eq 0 ]]; then
        log_success "DEB contents are identical (ar archive metadata differs)"
      else
        log_success "DEB installed files are identical (control metadata differs only)"
        print_diff_preview "$control_diff" "DEB control diff preview"
      fi
      COMPARE_BASIS=".deb files differ; installed files identical"
      MATCH_STATUS="true"
      VERDICT_STATUS="reproducible"
      return 0
    fi

    log_warn "DEB installed files differ."
    print_diff_preview "$data_diff" "DEB data diff preview"

    if [[ "$control_lines" -gt 0 ]]; then
      log_warn "Control metadata also differs (${control_lines} lines, see ${control_diff})"
    fi

    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
    return 1
  fi

  # Flatpak hashes differ -- report not_reproducible with OSTree note.
  # Flatpak bundles are OSTree repositories; the KDE runtime and SDK
  # (org.kde.Platform//6.9, org.kde.Sdk//6.9) are Flathub branch refs,
  # not content-pinned OSTree commits. If Flathub updated either ref
  # between the official release build and this verification run, hashes
  # will differ even if the application content is identical. Full content
  # diffing requires OSTree checkout comparison (manual follow-up).
  if [[ "$built_compare" == *.flatpak ]]; then
    local flatpak_diff_note="$WORKDIR/flatpak-hash-mismatch-note.txt"
    {
      echo "Flatpak bundle hashes differ."
      echo "Official: ${OFFICIAL_HASH}"
      echo "Built:    ${BUILT_HASH}"
      echo ""
      echo "Possible cause: KDE runtime/SDK refs (org.kde.Platform//6.9, org.kde.Sdk//6.9)"
      echo "are Flathub branch refs, not content-pinned OSTree commits. If Flathub updated"
      echo "either ref between the official release build and this run, the bundle hash changes."
      echo "To confirm: for official-vs-built comparison, import both bundles with"
      echo "  ostree and diff the checked-out /app trees."
      echo "Note: tools/build-linux/flatpak/check_reproducibility.sh compares two"
      echo "  local builds only; it does not compare against the official release."
    } > "$flatpak_diff_note"
    log_warn "Flatpak hashes differ. See ${flatpak_diff_note} for details."
    MATCH_STATUS="false"
    VERDICT_STATUS="not_reproducible"
    return 1
  fi

  MATCH_STATUS="false"
  VERDICT_STATUS="not_reproducible"
  log_warn "Hashes differ - Build is NOT reproducible"
  return 1
}

# ======================================================================================
# YAML OUTPUT GENERATION
# ======================================================================================

generate_comparison_yaml() {
  local yaml_file="${WORKDIR}/COMPARISON_RESULTS.yaml"  # copied next to the script at exit

  log_info "Generating COMPARISON_RESULTS.yaml..."

  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${VERDICT_STATUS}
notes: |
  Bitcoin Safe uses Poetry + Docker to build cross-platform AppImage, DEB, Flatpak, and Windows executables.
  Release signature of the downloaded artifact: ${SIG_STATUS}
  Expected differences that do not affect verdict:
  - AppImage tar.gz wrapper: non-deterministic tar metadata; raw AppImage inside is compared directly.
  - DEB control metadata: cosmetic package metadata differences; installed file content is what matters.
  - Windows executables compared after signature stripping (official is signed, built is unsigned).
  Caveats that may affect verdict:
  - Flatpak: KDE runtime/SDK refs (org.kde.Platform//6.9, org.kde.Sdk//6.9) are Flathub branch refs,
    not content-pinned OSTree commits. If Flathub updated either ref between the official release build
    and this verification run, the bundle hash changes. A hash mismatch returns not_reproducible;
    OSTree content comparison is required to determine if the application payload itself differs.
EOF

  log_success "COMPARISON_RESULTS.yaml generated: ${yaml_file}"
}

generate_error_yaml() {
  local error_status="$1"
  local error_msg="$2"
  local yaml_file="${WORKDIR}/COMPARISON_RESULTS.yaml"  # copied next to the script at exit

  log_info "Generating error COMPARISON_RESULTS.yaml..."

  case "$error_status" in
    reproducible|not_reproducible|ftbfs) ;;
    *) error_status="ftbfs" ;;
  esac

  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${error_status}
notes: |
  ${error_msg}
EOF

  log_info "Error YAML generated: ${yaml_file}"
}

# ======================================================================================
# RESULTS SUMMARY
# ======================================================================================

print_summary() {
  echo
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${VERDICT_STATUS}"
  echo "appHash:        ${APP_HASH:-N/A}"
  echo "commit:         ${SOURCE_COMMIT:-N/A}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_HASH}"
  echo "===== End Results ====="
  echo
  # Everything below is outside the results block.
  [[ -z "$APP_HASH" ]] || echo "appHash: sha256 of ${OFFICIAL_FILENAME} exactly as downloaded/supplied"
  if [[ -n "$BUILT_HASH" ]]; then
    echo "Compared (${COMPARE_BASIS}): official ${OFFICIAL_HASH} / built ${BUILT_HASH}"
  fi
  echo "Tag: ${CHECKED_OUT_TAG:-unknown} (git tag signature not checked)"
  echo "Release signature (${OFFICIAL_FILENAME:-artifact}.asc): ${SIG_STATUS}"
  local f
  for f in diff-appimage-contents diff-deb-contents; do
    [[ ! -f "$WORKDIR/$f.txt" ]] || print_diff_preview "$WORKDIR/$f.txt" "${f#diff-}"
  done
  [[ ! -f "$WORKDIR/flatpak-hash-mismatch-note.txt" ]] || head -4 "$WORKDIR/flatpak-hash-mismatch-note.txt"
  local c="$WORKDIR/appimage_compare"
  [[ ! -d "$c/built-squashfs" ]] || echo "More detail: diff -r $c/official-squashfs $c/built-squashfs"
  c="$WORKDIR/deb_compare"
  [[ ! -d "$c" ]] || echo "More detail: diff -r $c/official-data $c/built-data"
  echo "Workspace: $WORKDIR"
  echo
}

fail_ftbfs() {
  log_error "$1"
  generate_error_yaml "ftbfs" "$1"
  VERDICT_STATUS="ftbfs"
  print_summary
  exit 1
}

print_finding() {
  local finding="$1"
  echo "Finding: Bitcoin Safe ${VERSION} ${ARCH} ${BUILD_TYPE} -> ${finding}"
}

# ======================================================================================
# MAIN EXECUTION
# ======================================================================================

main() {
  # No stale YAML from an earlier run, also when parameters are invalid (exit 2)
  [[ "${_INSIDE_CONTAINER:-}" == "1" ]] || rm -f "$SCRIPT_DIR/COMPARISON_RESULTS.yaml"
  parse_args "$@"
  map_build_config "$ARCH" "$BUILD_TYPE"

  # If not inside container, bootstrap and re-invoke
  if [[ "${_INSIDE_CONTAINER:-}" != "1" ]]; then
    [[ "$(id -u)" -ne 0 ]] || invalid "Run as a normal user, not root."
    log_info "Script: ${0##*/} ${SCRIPT_VERSION} sha256: ${SCRIPT_HASH}"
    bootstrap_container
  fi

  setup_workspace
  prepare_repository || fail_ftbfs "Could not clone or check out ${VERSION}"
  download_official || fail_ftbfs "Failed to obtain official release artifact"
  verify_official_signature
  run_build || fail_ftbfs "Build process failed - see logs above"
  find_built_artifact || fail_ftbfs "Build completed but artifact not found in dist/"

  local comparison_result=0
  compare_artifacts || comparison_result=$?
  # Comparison failed before any hash was computed (e.g. signature strip error)
  if [[ "$comparison_result" -ne 0 && -z "$BUILT_HASH" ]]; then
    fail_ftbfs "Artifact comparison failed before hash computation - see logs above"
  fi

  generate_comparison_yaml
  print_summary
  print_finding "${VERDICT_STATUS}"
  [[ "$comparison_result" -eq 0 ]] && exit 0
  exit 1
}

# Run main function
main "$@"
