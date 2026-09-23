#!/usr/bin/env bash
# ==============================================================================
# wasabidesktop_build.sh - Wasabi Wallet Desktop Reproducible Build Verification
# ==============================================================================
# Version:          v1.11.0
# Organization:     WalletScrutiny.com
# Last modified on: 2026-09-03
# Project:          https://github.com/WalletWasabi/WalletWasabi
# ==============================================================================
# MIT License. Provided as-is for reproducible-build verification and security
# research, without warranty; you assume all risk and responsibility for lawful use.
#
# Runs the requested tag's own Contrib/release.sh "debian" target. This keeps the
# verifier aligned with upstream build changes instead of pinning it to one Wasabi
# release. The exact upstream script hash is recorded in the results.
#
# Rationale, limitations, fidelity evidence and version history are kept in this
# app's changelog in WalletScrutiny's script notes.
# ==============================================================================

set -Eeuo pipefail

# ---------- Script Metadata ----------
SCRIPT_VERSION="v1.11.0"
APP_NAME="Wasabi Wallet"
APP_ID="wasabi"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

sha256_local_or_na() {
  local digest=""
  if [ -f "$1" ] && command -v sha256sum >/dev/null 2>&1 && \
     digest="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" && \
     [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' "$digest"
  else
    printf 'N/A\n'
  fi
}

SCRIPT_HASH="$(sha256_local_or_na "$SCRIPT_PATH")"
UPSTREAM_RELEASE_SCRIPT_HASH="N/A"
RELEASE_ADAPTATION="none"

# Identify the exact verifier bytes before container or network work.
log_prefix="[INFO]"
echo "${log_prefix} Script: $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "${log_prefix} sha256: ${SCRIPT_HASH}"

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

log_info()    { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warning() { echo -e "${YELLOW}${WARNING_ICON}${NC} $*"; }
log_error()   { echo -e "${RED}${ERROR_ICON}${NC} $*"; }

# ---------- Minimal COMPARISON_RESULTS.yaml writer (3-field format, 2026-03-12) ----------
# Must disable the ERR trap: bash re-fires ERR on explicit `exit N`, clobbering the verdict.
write_yaml() {
  trap - ERR
  local verdict="$1"
  local notes="$2"
  cat > "${ORIG_DIR:-.}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
${notes}
EOF
  if [ -n "${WORKSPACE:-}" ] && [ "${WORKSPACE}" != "${ORIG_DIR:-.}" ]; then
    cp "${ORIG_DIR:-.}/COMPARISON_RESULTS.yaml" "${WORKSPACE}/COMPARISON_RESULTS.yaml" 2>/dev/null || true
  fi
}

# Safety net: unexpected exits still produce a COMPARISON_RESULTS.yaml for ABS.
on_err() {
  local ec=$?
  log_error "Unexpected failure (exit ${ec}) at line ${BASH_LINENO[0]}"
  write_yaml "ftbfs" "  Script aborted unexpectedly at line ${BASH_LINENO[0]} (exit code ${ec}). See script stdout/stderr for details."
  exit 1
}
trap on_err ERR

# Running as root defeats the host-ownership guarantee and is unnecessary: the
# container image is built as root internally, while every bind-mounted run is
# mapped to the invoking user.
if [ "$(id -u)" -eq 0 ]; then
  log_error "Do not run this verifier as root or through sudo."
  write_yaml "ftbfs" "  Refusing to run as root: invoke the script as a normal user so all workspace files remain removable by that user."
  exit 2
fi

usage() {
  cat <<EOF
Wasabi Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>] [--binary <file>]

Parameters:
  --version <version>   Wasabi version to verify. The script checks out and runs
                         that tag's own Contrib/release.sh build logic.
  --arch <arch>         x86_64-linux-gnu (default) or aarch64-linux-gnu. Both are
                         produced by one run of upstream's "debian" target.
  --type <type>         deb (default), tarball, zip
  --binary <file>       Path to an official binary to compare against, instead of
                         downloading it from GitHub releases.
  --help, -h             Show this help message

Unknown parameters are accepted and ignored with a warning (never fatal), per
WalletScrutiny ABS policy.

Known limitations:
  - linux-arm64 is a real release artifact since v2.8.0 (Contrib/release.sh
    debian cross-builds it alongside x64 regardless) but is not yet exposed
    as a selectable --arch here; deliberately scoped out of this patch.
  - The requested tag must provide Contrib/release.sh with a working "debian"
    target and the expected Wasabi release filenames. Upstream changes are run
    directly; an incompatible build recipe or SDK requirement reports ftbfs.
  - The .NET SDK is resolved from the official artifact's runtimeconfig.json
    (highest SDK shipping that runtime with a published -noble image). Only when
    the runtime cannot be read (zip) does it fall back to the 10.0.301 pin.
  - --arch win64 is rejected outright (exit 2). Wasabi's wininstaller target
    needs the WiX Toolset (heat/candle/light), which is Windows-only with no
    Linux port, so upstream's release script cannot complete in this container.
    It does produce the win-x64 zip mid-run, but only before WiX fails the
    build; reporting a verdict on an artifact pulled from a failed run is not
    acceptable. The win-x64 zip could later be built by inlining just the
    \`dotnet publish -r win-x64\` + zip steps -- a separate, testable change.
    Note also that the published .msi is Authenticode-signed with a private key
    during release and could never hash-match by design, and that upstream does
    not timestamp-normalize any zip (plain \`zip -r\`), so zips are expected to
    differ on that basis alone.

Examples:
  $(basename "$0") --version 2.8.2
  $(basename "$0") --version 2.8.2 --arch x86_64-linux-gnu --type deb
  $(basename "$0") --version 2.8.2 --arch x86_64-linux-gnu --type tarball --binary ~/Downloads/Wasabi-2.8.2-linux-x64.tar.gz

Requirements:
  - Docker or Podman installed (only host dependency)

Output:
  - Exit code 0: reproducible
  - Exit code 1: not_reproducible or ftbfs
  - Exit code 2: invalid parameters
  - COMPARISON_RESULTS.yaml (minimal 3-field format) in the execution directory
  - ===== Begin/End Results ===== human-readable summary block

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ---------- Parse Arguments ----------
VERSION=""
ARCH="x86_64-linux-gnu"
TYPE=""
BINARY_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --version) [ $# -ge 2 ] || { log_error "--version requires a value"; write_yaml "ftbfs" "  --version requires a value."; exit 2; }; VERSION="$2"; shift 2 ;;
    --arch) [ $# -ge 2 ] || { log_error "--arch requires a value"; write_yaml "ftbfs" "  --arch requires a value."; exit 2; }; ARCH="$2"; shift 2 ;;
    --type) [ $# -ge 2 ] || { log_error "--type requires a value"; write_yaml "ftbfs" "  --type requires a value."; exit 2; }; TYPE="$2"; shift 2 ;;
    --binary) [ $# -ge 2 ] || { log_error "--binary requires a value"; write_yaml "ftbfs" "  --binary requires a value."; exit 2; }; BINARY_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) log_warning "Unknown argument: $1 (ignored)"; shift ;;
  esac
done

ORIG_DIR="$(pwd)"

# ---------- Validate Parameters (exit 2 = invalid params, mechanical policy) ----------
if [ -z "$VERSION" ]; then
  log_error "--version parameter is required"
  usage
  write_yaml "ftbfs" "  --version parameter is required and was not provided."
  exit 2
fi

# Tight allow-list regex doubles as a shell-injection guard: only digits/dots/
# optional leading v survive before VERSION is interpolated into URLs/paths.
if ! [[ "$VERSION" =~ ^[vV]?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  log_error "Invalid version format: $VERSION (expected X.Y.Z or vX.Y.Z)"
  write_yaml "ftbfs" "  Invalid --version format: ${VERSION}"
  exit 2
fi

if [ "$ARCH" == "win64" ]; then
  # Rejected: wininstaller needs WiX (Windows-only); run always fails after the zip
  # is produced. See changelog v1.6.1.
  log_error "--arch win64 is not supported by this script."
  log_error "Wasabi's wininstaller target requires the WiX Toolset (heat/candle/light),"
  log_error "which is Windows-only and has no Linux port, so the upstream release script"
  log_error "cannot complete in this container. The win-x64 zip it produces mid-run cannot"
  log_error "be trusted from a failed build. Use --arch x86_64-linux-gnu."
  write_yaml "ftbfs" "  --arch win64 is not supported: Wasabi's wininstaller target requires the WiX Toolset (heat/candle/light), which is Windows-only with no Linux port, so the upstream release script cannot complete in this container. The win-x64 zip is produced mid-run but only before WiX fails the build, and is not retrieved. Use --arch x86_64-linux-gnu."
  exit 2
fi
# Upstream's "debian" target builds linux-x64 AND linux-arm64 in one run, so the arm64
# artifacts cost no extra build -- they were produced and discarded before v1.11.0.
# Accept the spellings a wallet file might carry and normalise to one.
case "$ARCH" in
  aarch64-linux-gnu|aarch64-linux|arm64-linux-gnu|arm64-linux|arm64)
    ARCH="aarch64-linux-gnu" ;;
esac
if [ "$ARCH" != "x86_64-linux-gnu" ] && [ "$ARCH" != "aarch64-linux-gnu" ]; then
  log_error "Unsupported architecture: $ARCH"
  echo "Supported: x86_64-linux-gnu, aarch64-linux-gnu"
  write_yaml "ftbfs" "  Unsupported --arch: ${ARCH}. Supported: x86_64-linux-gnu, aarch64-linux-gnu."
  exit 2
fi

[ -n "$TYPE" ] || TYPE="deb"

if [[ "$TYPE" != "deb" && "$TYPE" != "tarball" && "$TYPE" != "zip" ]]; then
  log_error "Invalid type '$TYPE' for architecture '$ARCH' (valid: deb, tarball, zip)"
  write_yaml "ftbfs" "  Invalid --type '${TYPE}' for --arch '${ARCH}'."
  exit 2
fi

if [ -n "$BINARY_FILE" ]; then
  # Absolute path required: validated here, copied after cd into the workspace.
  BINARY_FILE="$(cd "$(dirname "$BINARY_FILE")" 2>/dev/null && pwd -P || echo "")/$(basename "$BINARY_FILE")"
  BINARY_FILE=$(echo "$BINARY_FILE" | sed 's|//*|/|g')
fi
if [ -n "$BINARY_FILE" ] && [ ! -f "$BINARY_FILE" ]; then
  log_error "--binary file not found: $BINARY_FILE"
  write_yaml "ftbfs" "  --binary file not found: ${BINARY_FILE}"
  exit 2
fi

# ---------- Detect Container Runtime + user-mapping args (avoid root-owned host files) ----------
# Every container step runs mapped to the invoking user, so nothing lands root-owned on the
# host. Payload ownership is handled on the disposable upstream-script copy --
# see the --root-owner-group adaptation below.
CONTAINER_CMD=""
CONTAINER_RUN_USER_ARGS=""
if command -v podman &> /dev/null; then
  CONTAINER_CMD="podman"
  CONTAINER_RUN_USER_ARGS="--userns=keep-id -e HOME=/tmp"
  log_info "Using Podman for containerization"
elif command -v docker &> /dev/null; then
  CONTAINER_CMD="docker"
  CONTAINER_RUN_USER_ARGS="--user $(id -u):$(id -g) -e HOME=/tmp"
  log_info "Using Docker for containerization"
else
  log_error "Neither Docker nor Podman found"
  write_yaml "ftbfs" "  Neither Docker nor Podman found on host."
  exit 1
fi

# ---------- Version Normalization ----------
# Normalise leading V/v: "V2.8.1" would otherwise derive the bad tag "vV2.8.1".
VERSION="${VERSION#[vV]}"
GIT_TAG="v$VERSION"
VERSION_NO_V="$VERSION"

log_info "Building $APP_NAME version: $VERSION (tag: $GIT_TAG) for architecture: $ARCH, type: $TYPE"

# ---------- Setup Workspace ----------
WORKSPACE="$ORIG_DIR/wasabi_build_${VERSION_NO_V}_${ARCH}_${TYPE}"
log_info "Creating workspace: $WORKSPACE"
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/output"
cd "$WORKSPACE"

OWNERSHIP_CHECK_RECORDED=false
find_foreign_owned_workspace_file() {
  [ -d "${WORKSPACE:-}" ] || return 0
  find "$WORKSPACE" ! -uid "$(id -u)" -print -quit 2>/dev/null || true
}
cleanup_container() {
  [ -n "${CONTAINER_NAME:-}" ] || return 0
  $CONTAINER_CMD rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
cleanup_run() {
  local first_foreign=""
  cleanup_container
  first_foreign="$(find_foreign_owned_workspace_file)"
  if [ -n "$first_foreign" ]; then
    log_error "Workspace ownership check failed: $first_foreign is not owned by UID $(id -u)."
  elif [ "$OWNERSHIP_CHECK_RECORDED" != "true" ]; then
    log_success "Exit ownership check passed: every generated path is owned by UID $(id -u)."
  fi
}
trap cleanup_run EXIT

# ---------- Determine Build Configuration ----------
# BUILD_TARGET is what we pass to Contrib/release.sh; EXPECTED_FILE is what we hash.
# Note: "debian" target cross-builds BOTH linux-x64 and linux-arm64 in one pass
# since v2.8.0 (Contrib/release.sh PLATFORMS array) -- confirmed at the tag --
# even though we only select/hash the x64 artifact below. arm64 is a real,
# separately-hashed release asset (Wasabi-<ver>-arm64.deb etc.) that deserves
# its own --arch support in a later version; deliberately out of scope here.
# One build target for both architectures; only the artifact selected for comparison
# differs. Upstream names the x64 deb without an arch suffix and the arm64 one with it.
BUILD_TARGET="debian"
case "$ARCH" in
  x86_64-linux-gnu)
    case "$TYPE" in
      deb) EXPECTED_FILE="Wasabi-${VERSION_NO_V}.deb" ;;
      tarball) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-x64.tar.gz" ;;
      zip) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-x64.zip" ;;
    esac
    ;;
  aarch64-linux-gnu)
    case "$TYPE" in
      deb) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-arm64.deb" ;;
      tarball) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-arm64.tar.gz" ;;
      zip) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-arm64.zip" ;;
    esac
    ;;
esac

DOWNLOAD_URL="https://github.com/WalletWasabi/WalletWasabi/releases/download/$GIT_TAG/$EXPECTED_FILE"

# ---------- Stage official artifact: --binary if provided (host-side copy only) ----------
if [ -n "$BINARY_FILE" ]; then
  log_info "Using provided --binary as official artifact: $BINARY_FILE"
  cp "$BINARY_FILE" "$WORKSPACE/official-$EXPECTED_FILE"
  if [ "$(basename "$BINARY_FILE")" != "$EXPECTED_FILE" ]; then
    log_warning "Provided --binary filename ($(basename "$BINARY_FILE")) differs from the expected release asset name ($EXPECTED_FILE). Proceeding anyway."
  fi
fi

# ---------- Resolve the .NET SDK from the OFFICIAL artifact, not from a guess ----------
# The shipped package records the runtime pack it was built against in
# */WalletWasabi.Fluent.Desktop.runtimeconfig.json. Reading it turns the SDK choice from an
# inference about the upstream runner into an observation of the artifact under test, and stops
# the pin going stale every time Microsoft ships a patch. v1.9.0 pinned SDK 10.0.301 (runtime
# 10.0.9); Wasabi 2.8.2 shipped runtime 10.0.11, so 314 of 425 payload files differed for that
# reason alone.
BOOTSTRAP_IMAGE="wasabi-bootstrap-${VERSION_NO_V}-${ARCH}-${TYPE}"
log_info "Building bootstrap helper image..."
cat > "$WORKSPACE/Dockerfile.bootstrap" <<'BOOTSTRAP_EOF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
BOOTSTRAP_EOF
# python3, not python3-minimal: the latter has no json module (checked 2026-09-03).
if ! $CONTAINER_CMD build -t "$BOOTSTRAP_IMAGE" -f "$WORKSPACE/Dockerfile.bootstrap" "$WORKSPACE" >/dev/null 2>&1; then
  log_error "Failed to build the bootstrap helper image"
  write_yaml "ftbfs" "  Failed to build the bootstrap helper image used to read the official artifact's runtime version."
  exit 1
fi

if [ -z "$BINARY_FILE" ]; then
  log_info "Downloading official artifact: $EXPECTED_FILE"
  if ! $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
    "$BOOTSTRAP_IMAGE" curl -fsSL -o "official-$EXPECTED_FILE" "$DOWNLOAD_URL"; then
    log_error "Failed to download the official release asset"
    write_yaml "ftbfs" "  Failed to download the official release asset.
  URL attempted: ${DOWNLOAD_URL}"
    exit 1
  fi
  log_success "Downloaded official-$EXPECTED_FILE"
fi

# Pull the runtime version out of the official artifact, per package type.
case "$TYPE" in
  deb)     RC_CMD="dpkg-deb --fsys-tarfile official-$EXPECTED_FILE | tar -xO --wildcards '*WalletWasabi.Fluent.Desktop.runtimeconfig.json' 2>/dev/null" ;;
  tarball) RC_CMD="tar -xzO --wildcards -f official-$EXPECTED_FILE '*WalletWasabi.Fluent.Desktop.runtimeconfig.json' 2>/dev/null" ;;
  *)       RC_CMD="" ;;
esac

OBSERVED_RUNTIME=""
if [ -n "$RC_CMD" ]; then
  OBSERVED_RUNTIME=$($CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
    "$BOOTSTRAP_IMAGE" bash -c "$RC_CMD | grep -oE '\"version\": *\"[0-9]+\.[0-9]+\.[0-9]+\"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" 2>"$WORKSPACE/runtime-read-error.txt" || true)
fi

SDK_SELECTION="pinned fallback (runtime not readable from this artifact type)"
SDK_VERSION="10.0.301"
SDK_ALTERNATIVES=""
if [[ "$OBSERVED_RUNTIME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log_success "Official artifact was built against .NET runtime $OBSERVED_RUNTIME"
  RT_BAND="${OBSERVED_RUNTIME%.*}"
  cat > "$WORKSPACE/sdkmap.py" <<'SDKMAP_EOF'
import json, sys
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"sdkmap: cannot parse releases.json: {e}", file=sys.stderr); sys.exit(1)
for rel in data.get("releases", []):
    if rel.get("runtime", {}).get("version") == target:
        vs = {x.get("version") for x in rel.get("sdks", []) if x.get("version")}
        try:
            ordered = sorted(vs, key=lambda v: [int(n) for n in v.split(".")])
        except ValueError:
            ordered = sorted(vs)
        print(" ".join(ordered))
        break
else:
    print(f"sdkmap: runtime {target} not found in releases.json", file=sys.stderr); sys.exit(1)
SDKMAP_EOF
  RELEASES_URL="https://raw.githubusercontent.com/dotnet/core/main/release-notes/${RT_BAND}/releases.json"
  SDK_LIST=$($CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
    "$BOOTSTRAP_IMAGE" bash -c "curl -fsSL '$RELEASES_URL' | python3 /workspace/sdkmap.py '$OBSERVED_RUNTIME'" 2>"$WORKSPACE/sdkmap-error.txt" || true)
  if [ -n "$SDK_LIST" ]; then
    SDK_ALTERNATIVES=$(echo "$SDK_LIST" | tr ' ' ',')
    # Not every SDK patch is published as a -noble image (10.0.303 is not, as of
    # 2026-09-03), so take the highest candidate that actually exists in the registry.
    # rollForward=latestFeature selects the highest feature band, so prefer highest first.
    # The tag list is kept in the workspace as evidence; a response that is not a tag
    # list (outage, proxy page, truncated body) must not reject every candidate.
    MCR_TAGS_FILE="$WORKSPACE/mcr-sdk-tags.json"
    $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
      "$BOOTSTRAP_IMAGE" curl -fsSL -o /workspace/mcr-sdk-tags.json "https://mcr.microsoft.com/v2/dotnet/sdk/tags/list" \
      2>"$WORKSPACE/mcr-tags-error.txt" || true
    if ! grep -q '"tags"' "$MCR_TAGS_FILE" 2>/dev/null; then
      log_warning "Registry tag list unavailable (see $WORKSPACE/mcr-tags-error.txt); taking the highest SDK candidate unverified"
      MCR_TAGS_FILE=""
    fi
    SDK_PICKED=""
    for cand in $(echo "$SDK_LIST" | tr ' ' '\n' | tac); do
      if [ -z "$MCR_TAGS_FILE" ] || grep -q "\"${cand}-noble\"" "$MCR_TAGS_FILE"; then
        SDK_PICKED="$cand"; break
      fi
      log_warning "No mcr.microsoft.com/dotnet/sdk:${cand}-noble image; trying the next candidate"
    done
    if [ -n "$SDK_PICKED" ]; then
      SDK_VERSION="$SDK_PICKED"
      SDK_SELECTION="observed from the official artifact's runtimeconfig.json (runtime ${OBSERVED_RUNTIME}); highest SDK shipping it that is published as a -noble image, mirroring global.json rollForward=latestFeature"
      log_success "Selected .NET SDK $SDK_VERSION (candidates: $SDK_ALTERNATIVES)"
    else
      log_error "None of $SDK_ALTERNATIVES is published as a -noble image on mcr.microsoft.com."
      write_yaml "ftbfs" "  Official artifact records .NET runtime ${OBSERVED_RUNTIME}; SDKs ${SDK_ALTERNATIVES} ship it but none is published as mcr.microsoft.com/dotnet/sdk:<version>-noble. Building with the pinned ${SDK_VERSION} would use a different runtime pack and produce a known-false not_reproducible, so this is a tool/environment failure, not a verdict."
      exit 1
    fi
  else
    # The fallback pin ships a different runtime pack, so a build now is guaranteed to
    # differ for our reasons, not Wasabi's (2026-09-03: 20 minutes to a false verdict).
    log_error "Could not map runtime $OBSERVED_RUNTIME to an SDK (lookup stderr, first lines):"
    head -5 "$WORKSPACE/sdkmap-error.txt" 2>/dev/null | sed 's/^/    /' >&2
    write_yaml "ftbfs" "  Official artifact records .NET runtime ${OBSERVED_RUNTIME} but the runtime-to-SDK lookup against ${RELEASES_URL} produced nothing (see ${WORKSPACE}/sdkmap-error.txt). A build with the pinned SDK ${SDK_VERSION} would use a different runtime pack and produce a known-false not_reproducible, so this is a tool/environment failure, not a verdict."
    exit 1
  fi
else
  log_warning "Could not read a runtime version from the official artifact; falling back to SDK $SDK_VERSION"
fi

# ---------- Generate Embedded Dockerfile ----------
# The SDK is no longer pinned by inference. It is resolved from the official artifact
# itself (see the block above): the shipped runtimeconfig.json names the runtime pack the
# release was built against, and the highest SDK shipping that runtime is selected, mirroring
# global.json's rollForward=latestFeature. mcr.microsoft.com ships no stable Debian-based
# dotnet/sdk image for .NET 10 -- only Ubuntu "noble" -- so "noble" is required, and it also
# matches upstream's ubuntu-latest CI OS.
#
# All tools needed for every later step (git, wget, gpg, zip/unzip, dpkg-dev)
# are installed here, at image-build time, as root. This is deliberate: every
# `run` step after this point uses CONTAINER_RUN_USER_ARGS (a non-root,
# host-UID-mapped user) so files written into the host-mounted workspace are
# never root-owned -- but `apt-get install` needs root, so it cannot happen at
# `run` time once user-mapping is in effect. One image build up front avoids
# that conflict entirely instead of mixing root and mapped-user `run` calls.
log_info "Generating embedded Dockerfile with .NET SDK ${SDK_VERSION}-noble..."
DOCKERFILE_PATH="$WORKSPACE/Dockerfile"
cat > "$DOCKERFILE_PATH" <<DOCKERFILE_EOF
FROM mcr.microsoft.com/dotnet/sdk:${SDK_VERSION}-noble
ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget ca-certificates zip unzip dpkg-dev gnupg dirmngr \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
CMD ["/bin/bash"]
DOCKERFILE_EOF
log_success "Dockerfile generated"

IMAGE_NAME="wasabi-build:${VERSION_NO_V}-${ARCH}-${TYPE}-$$"
log_info "Building container image (this may take a while on first run)..."
if ! $CONTAINER_CMD build -t "$IMAGE_NAME" -f "$DOCKERFILE_PATH" "$WORKSPACE"; then
  log_error "Container build failed"
  write_yaml "ftbfs" "  Failed to build the verification container image (dotnet SDK ${SDK_VERSION}-noble base)."
  exit 1
fi
log_success "Container image built: $IMAGE_NAME"

# ---------- Clone at the exact tag ref (never `git clone --branch`, which silently
# prefers a same-named BRANCH over a tag -- the exact footgun that bit a prior
# audit). `git init` + an explicit `refs/tags/...` fetch refspec is unambiguous
# AND stays shallow (depth=1), unlike a plain `git clone --no-checkout` which
# would otherwise pull the whole repo history before we could narrow it down.
log_info "Cloning repository and checking out tag $GIT_TAG inside a container..."
CLONE_STEPS="git init -q walletwasabi && cd walletwasabi && \
  git remote add origin https://github.com/WalletWasabi/WalletWasabi && \
  git fetch --depth=1 origin refs/tags/$GIT_TAG:refs/tags/$GIT_TAG && \
  git checkout refs/tags/$GIT_TAG"
if ! $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS \
  -v "$WORKSPACE:/workspace:Z" -w /workspace \
  "$IMAGE_NAME" bash -c "$CLONE_STEPS"; then
  log_error "Failed to clone repository at tag $GIT_TAG"
  write_yaml "ftbfs" "  Failed to clone WalletWasabi at tag ${GIT_TAG}."
  exit 1
fi
log_success "Cloned repository at $GIT_TAG"

log_info "Extracting commit timestamp for SOURCE_DATE_EPOCH..."
SOURCE_DATE_EPOCH=$($CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS \
  -v "$WORKSPACE:/workspace:Z" -w /workspace/walletwasabi \
  "$IMAGE_NAME" bash -c "git log -1 --format=%ct")
log_info "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH (source commit time)"
# Note: as of v2.8.0, Contrib/release.sh normalizes the Linux tarball itself using
# this exact same computation (git log -1 --pretty=%ct) if SOURCE_DATE_EPOCH is
# unset -- we still export it explicitly below so the value is visible/logged
# here rather than hidden inside release.sh's own fallback. We no longer patch
# release.sh's tar invocation: upstream already fixed the exact non-determinism
# issue that patch used to work around (added the same SOURCE_DATE_EPOCH-driven
# --mtime normalization natively, plus --sort=name/--owner=0/--group=0/PAX
# header stripping our old patch never touched).

# ---------- Check Git Tag Authenticity ----------
log_info "Verifying Git tag / commit authenticity..."
WASABI_GPG_FINGERPRINT="6FB3 872B 5D42 292F 5992  0797 8563 4832 8949 861E"
GPG_VERIFICATION=$($CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS \
  -v "$WORKSPACE:/workspace:Z" -w /workspace/walletwasabi \
  "$IMAGE_NAME" bash -c "
    set -e
    COMMIT=\$(git rev-parse HEAD)
    echo \"COMMIT:\$COMMIT\"
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys '$WASABI_GPG_FINGERPRINT' 2>&1 || \
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys '$WASABI_GPG_FINGERPRINT' 2>&1 || \
    echo 'KEY_FETCH_FAILED'
    ACTUAL_FP=\$(gpg --fingerprint --with-colons 2>/dev/null | grep '^fpr' | head -1 | cut -d: -f10)
    EXPECTED_FP='${WASABI_GPG_FINGERPRINT// /}'
    # No key == fetch failed (inconclusive); only a present, differing key is a mismatch.
    if [ -z \"\$ACTUAL_FP\" ]; then echo 'KEY_UNAVAILABLE'
    elif [ \"\$ACTUAL_FP\" = \"\$EXPECTED_FP\" ]; then echo 'FINGERPRINT_OK'
    else echo 'FINGERPRINT_MISMATCH'; fi
    # A lightweight tag has no signature: a fact, not a verification failure. And a
    # signature we cannot check (key unavailable) is not the same as an invalid one.
    if git cat-file -t \"refs/tags/$GIT_TAG\" 2>/dev/null | grep -q '^tag\$'; then
      if [ -z \"\$ACTUAL_FP\" ]; then
        echo 'ANNOTATED_TAG_SIGNATURE_UNCHECKED'
      else
        git tag -v $GIT_TAG 2>&1 || echo 'ANNOTATED_TAG_SIGNATURE_INVALID'
      fi
    else
      echo 'LIGHTWEIGHT_TAG_UNSIGNED'
    fi
  ")
ACTUAL_COMMIT=$(echo "$GPG_VERIFICATION" | grep "^COMMIT:" | cut -d: -f2)
log_info "Cloned commit hash: $ACTUAL_COMMIT"
# Fail closed on an annotated tag we could not authenticate, but say WHICH case it is.
if echo "$GPG_VERIFICATION" | grep -q "ANNOTATED_TAG_SIGNATURE_UNCHECKED"; then
  log_error "Tag ${GIT_TAG} is annotated (signed) but its signature could NOT be checked:"
  log_error "the zkSNACKs key could not be fetched from any keyserver. This is a network or"
  log_error "keyserver failure, NOT evidence of a bad signature. Refusing to build rather than"
  log_error "report an unverified signed tag as if it were checked."
  write_yaml "ftbfs" "  Tag ${GIT_TAG} is annotated but its GPG signature could not be checked: the zkSNACKs signing key could not be fetched from any keyserver (network/keyserver failure, not a bad signature). Commit ${ACTUAL_COMMIT}. Refusing to build."
  exit 1
fi
if echo "$GPG_VERIFICATION" | grep -q "ANNOTATED_TAG_SIGNATURE_INVALID"; then
  log_error "Tag ${GIT_TAG} is annotated but its GPG signature did NOT verify."
  log_error "Refusing to build from a tag whose signature fails to validate."
  write_yaml "ftbfs" "  Tag ${GIT_TAG} is annotated but its GPG signature failed to verify (commit ${ACTUAL_COMMIT}). Refusing to build."
  exit 1
fi
if echo "$GPG_VERIFICATION" | grep -q "KEY_UNAVAILABLE"; then
  log_warning "zkSNACKs signing key could not be fetched from any keyserver (network or"
  log_warning "keyserver issue). This is INCONCLUSIVE, not a key mismatch. Recording commit"
  log_warning "  ${ACTUAL_COMMIT}"
elif echo "$GPG_VERIFICATION" | grep -q "FINGERPRINT_MISMATCH"; then
  log_error "GPG key fingerprint mismatch! Possible key substitution attack"
  write_yaml "ftbfs" "  GPG key fingerprint mismatch for zkSNACKs signing key at commit ${ACTUAL_COMMIT}."
  exit 1
elif echo "$GPG_VERIFICATION" | grep -q "FINGERPRINT_OK"; then
  log_success "GPG key fingerprint verified"
  if echo "$GPG_VERIFICATION" | grep -q "Good signature"; then
    log_success "Tag is annotated and carries a valid GPG signature from the expected key"
  elif echo "$GPG_VERIFICATION" | grep -q "LIGHTWEIGHT_TAG_UNSIGNED"; then
    # We RECORD the commit; we do not authenticate it.
    log_warning "Tag ${GIT_TAG} is lightweight (unsigned) -- no signature to verify. The"
    log_warning "fingerprint check above only proves the expected key exists; it does NOT"
    log_warning "authenticate this tag. Recording the checked-out commit for the record:"
    log_warning "  ${ACTUAL_COMMIT}"
  else
    log_warning "Tag signature could not be checked. Recording commit ${ACTUAL_COMMIT} only."
  fi
else
  log_warning "GPG key fingerprint could not be confirmed. Recording commit ${ACTUAL_COMMIT} only;"
  log_warning "no tag authentication performed."
fi

# ---------- Prepare the requested tag's upstream release procedure ----------
RELEASE_SCRIPT_SOURCE="$WORKSPACE/walletwasabi/Contrib/release.sh"
RELEASE_SCRIPT_RUNNER="$WORKSPACE/release-under-test.sh"

if [ ! -f "$RELEASE_SCRIPT_SOURCE" ]; then
  log_error "Tag $GIT_TAG does not contain Contrib/release.sh"
  write_yaml "ftbfs" "  Tag ${GIT_TAG} (commit ${ACTUAL_COMMIT}) does not contain Contrib/release.sh; the upstream Debian build procedure is unavailable."
  exit 1
fi

UPSTREAM_RELEASE_SCRIPT_HASH="$(sha256sum "$RELEASE_SCRIPT_SOURCE" | awk '{print $1}')"
cp "$RELEASE_SCRIPT_SOURCE" "$RELEASE_SCRIPT_RUNNER"
log_info "Upstream release script: Contrib/release.sh from $GIT_TAG"
log_info "Upstream release script sha256: $UPSTREAM_RELEASE_SCRIPT_HASH"

# Upstream GitHub Actions runs this script through sudo, so dpkg-deb sees a
# root-owned staging tree. Our container is deliberately mapped to the invoking
# user so it cannot leave undeletable host files. Apply the equivalent
# dpkg-deb option to a disposable copy of the requested tag's script.
if grep -Fq "dpkg-deb --root-owner-group" "$RELEASE_SCRIPT_RUNNER"; then
  RELEASE_ADAPTATION="upstream already uses dpkg-deb --root-owner-group"
elif [ "$(grep -Fc "dpkg-deb -Zxz --build" "$RELEASE_SCRIPT_RUNNER" || true)" -eq 1 ]; then
  sed -i 's/dpkg-deb -Zxz --build/dpkg-deb --root-owner-group -Zxz --build/' "$RELEASE_SCRIPT_RUNNER"
  RELEASE_ADAPTATION="added dpkg-deb --root-owner-group to match upstream sudo ownership"
else
  RELEASE_ADAPTATION="none; no recognized dpkg-deb ownership command"
  log_warning "Could not identify the upstream dpkg-deb command for the root-owner adaptation."
  log_warning "Proceeding with the requested tag's script unchanged; archive metadata may differ."
fi
log_info "Verifier adaptation: $RELEASE_ADAPTATION"

if ! bash -n "$RELEASE_SCRIPT_RUNNER"; then
  log_error "Contrib/release.sh from $GIT_TAG does not pass bash syntax validation"
  write_yaml "ftbfs" "  Contrib/release.sh from ${GIT_TAG} (sha256 ${UPSTREAM_RELEASE_SCRIPT_HASH}) failed bash syntax validation."
  exit 1
fi

# ---------- Run Official Build ----------
CONTAINER_NAME="wasabi-build-run-${VERSION_NO_V}-${ARCH}-${TYPE}-$$"

log_info "Running Contrib/release.sh from $GIT_TAG with target: $BUILD_TARGET"
# Preserve GitHub Actions' source path for releases before upstream added
# PathMap. Newer tags carry their own path normalization and are still run
# unchanged. RUNNER_OS is normally supplied by GitHub Actions.
if ! $CONTAINER_CMD run --name "$CONTAINER_NAME" $CONTAINER_RUN_USER_ARGS \
  -e RUNNER_OS=Linux \
  -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  -v "$WORKSPACE/walletwasabi:/home/runner/work/WalletWasabi/WalletWasabi:Z" \
  -v "$RELEASE_SCRIPT_RUNNER:/workspace/release-under-test.sh:Z,ro" \
  "$IMAGE_NAME" \
  bash -c "cd /home/runner/work/WalletWasabi/WalletWasabi && bash -x /workspace/release-under-test.sh '$BUILD_TARGET'"; then
  log_error "Build failed inside container"
  write_yaml "ftbfs" "  Upstream Contrib/release.sh from ${GIT_TAG} (sha256 ${UPSTREAM_RELEASE_SCRIPT_HASH}) failed to build from source at commit ${ACTUAL_COMMIT}. Verifier adaptation: ${RELEASE_ADAPTATION}."
  exit 1
fi

log_info "Copying build artifact from container: $EXPECTED_FILE"
if ! $CONTAINER_CMD cp "$CONTAINER_NAME:/home/runner/work/WalletWasabi/WalletWasabi/packages/$EXPECTED_FILE" "$WORKSPACE/output/$EXPECTED_FILE"; then
  log_error "Expected build output not found: $EXPECTED_FILE"
  write_yaml "ftbfs" "  Build succeeded but expected artifact ${EXPECTED_FILE} was not found in packages/."
  exit 1
fi
log_success "Build completed and artifact copied"

# ---------- Compute Hashes (containerized, no host sha256sum dependency) ----------
log_info "Computing SHA256 hashes..."
BUILT_HASH=$($CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
  "$IMAGE_NAME" bash -c "sha256sum output/$EXPECTED_FILE | awk '{print \$1}'")
OFFICIAL_HASH=$($CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
  "$IMAGE_NAME" bash -c "sha256sum official-$EXPECTED_FILE | awk '{print \$1}'")

echo ""
log_info "Built file hash:    $BUILT_HASH"
log_info "Official file hash: $OFFICIAL_HASH"
echo ""

if [ "$BUILT_HASH" == "$OFFICIAL_HASH" ]; then
  MATCH=true
  VERDICT="reproducible"
  log_success "REPRODUCIBLE: Hashes match!"
else
  MATCH=false
  VERDICT="not_reproducible"
  log_error "NOT REPRODUCIBLE: Hashes differ"

  # ---------- Diff Evidence (only generated on mismatch, per Diff Output Policy) ----------
  log_info "Extracting both artifacts for a structural diff (evidence for human review)..."
  DIFF_FILE="$WORKSPACE/diff_full.txt"
  case "$TYPE" in
    deb)
      $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
        "$IMAGE_NAME" bash -c "
          dpkg-deb -R output/$EXPECTED_FILE built-extracted 2>/dev/null
          dpkg-deb -R official-$EXPECTED_FILE official-extracted 2>/dev/null
          diff -r official-extracted built-extracted" > "$DIFF_FILE" 2>&1 || true
      ;;
    tarball)
      $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
        "$IMAGE_NAME" bash -c "
          mkdir -p built-extracted official-extracted
          tar -xzf output/$EXPECTED_FILE -C built-extracted
          tar -xzf official-$EXPECTED_FILE -C official-extracted
          diff -r official-extracted built-extracted" > "$DIFF_FILE" 2>&1 || true
      ;;
    zip)
      $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
        "$IMAGE_NAME" bash -c "
          mkdir -p built-extracted official-extracted
          unzip -q output/$EXPECTED_FILE -d built-extracted
          unzip -q official-$EXPECTED_FILE -d official-extracted
          diff -r official-extracted built-extracted" > "$DIFF_FILE" 2>&1 || true
      ;;
  esac
  DIFF_LINES=$(wc -l < "$DIFF_FILE" 2>/dev/null || echo 0)
  echo "Diff (first 5 lines -- full diff in $DIFF_FILE):"
  head -5 "$DIFF_FILE" 2>/dev/null || true
  [ "$DIFF_LINES" -gt 5 ] && echo "... ($DIFF_LINES lines total -- see $DIFF_FILE)"

  # ---------- Archive Metadata Evidence (deb only; diagnostic, never changes the verdict) ----------
  # The structural diff above extracts both packages and compares file CONTENTS. It cannot see
  # ownership, permission bits, timestamps or member order -- a real ownership mismatch hid
  # behind it on Wasabi 2.8.0 and 2.8.1 and was reported as absent. This step lists both
  # archives with numeric owners and full timestamps, preserving member order (no sort), so a
  # difference in those properties is recorded rather than inferred.
  if [ "$TYPE" = "deb" ]; then
    log_info "Comparing archive metadata (ownership, modes, timestamps, member order)..."
    META_DIFF_FILE="$WORKSPACE/diff_archive_metadata.txt"
    $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS -v "$WORKSPACE:/workspace:Z" -w /workspace \
      "$IMAGE_NAME" bash -c "
        for side in official built; do
          [ \$side = official ] && pkg=official-$EXPECTED_FILE || pkg=output/$EXPECTED_FILE
          dpkg-deb --fsys-tarfile \"\$pkg\" | tar --numeric-owner --full-time -tvf - > listing-\$side-payload.txt 2>/dev/null
          dpkg-deb --ctrl-tarfile \"\$pkg\" | tar --numeric-owner --full-time -tvf - > listing-\$side-control.txt 2>/dev/null
        done
        echo '--- payload archive (data.tar) ---'
        diff listing-official-payload.txt listing-built-payload.txt && echo 'IDENTICAL'
        echo '--- control archive (control.tar) ---'
        diff listing-official-control.txt listing-built-control.txt && echo 'IDENTICAL'" \
      > "$META_DIFF_FILE" 2>&1 || true
    META_PAYLOAD_DIFFS=$(sed -n '/payload archive/,/control archive/p' "$META_DIFF_FILE" | grep -c '^[<>]' || true)
    META_CONTROL_DIFFS=$(sed -n '/control archive/,$p' "$META_DIFF_FILE" | grep -c '^[<>]' || true)
    echo "Archive metadata: payload ${META_PAYLOAD_DIFFS} differing entries, control ${META_CONTROL_DIFFS} -- full listing in $META_DIFF_FILE"
    if [ "$META_PAYLOAD_DIFFS" -eq 0 ] && [ "$META_CONTROL_DIFFS" -eq 0 ]; then
      log_success "Archive metadata identical: ownership, modes, timestamps and member order all match."
      log_info "The package difference is therefore confined to file contents shown above."
    else
      log_warning "Archive metadata differs beyond file contents -- see $META_DIFF_FILE."
      log_warning "This is diagnostic only and does not change the verdict, which rests on the artifact hash."
    fi
  fi
fi

# Acceptance check from non-sudo-directories-guideline.md. The EXIT trap repeats
# it on failed runs; this explicit pass records success in completed validations.
FIRST_FOREIGN_OWNED="$(find_foreign_owned_workspace_file)"
if [ -n "$FIRST_FOREIGN_OWNED" ]; then
  log_error "Workspace contains a file not owned by UID $(id -u): $FIRST_FOREIGN_OWNED"
  write_yaml "ftbfs" "  Workspace ownership guarantee failed: ${FIRST_FOREIGN_OWNED} is not owned by invoking UID $(id -u)."
  exit 1
fi
log_success "Workspace ownership check passed: every generated path is owned by UID $(id -u)."
OWNERSHIP_CHECK_RECORDED=true

# ---------- Generate COMPARISON_RESULTS.yaml (minimal 3-field format) ----------
NOTES="  Wasabi ${VERSION} (--arch ${ARCH} --type ${TYPE}). The build ran
  Contrib/release.sh from requested tag ${GIT_TAG} (sha256
  ${UPSTREAM_RELEASE_SCRIPT_HASH}) with verifier adaptation: ${RELEASE_ADAPTATION}.
  Built inside mcr.microsoft.com/dotnet/sdk:${SDK_VERSION}-noble.
  SDK selection: ${SDK_SELECTION}.
  The official artifact records the runtime pack it was built against in its
  runtimeconfig.json, so the SDK is read from the artifact under test rather than
  inferred from the upstream runner image. Observed runtime: ${OBSERVED_RUNTIME:-unreadable};
  SDKs shipping it: ${SDK_ALTERNATIVES:-none retrieved}. Where several SDKs ship one runtime
  they share the runtime pack but not necessarily the compiler, so a residual difference
  confined to WalletWasabi's own assemblies would point at the feature band, not the runtime.
  The script exports SOURCE_DATE_EPOCH and lets the
  requested tag's release procedure apply its own normalization. New versions are
  attempted rather than rejected; an incompatible release procedure or SDK reports
  ftbfs. zip artifacts are not timestamp-normalized by known 2.8.x upstream scripts
  and are expected to differ on that basis alone. --type msi is
  rejected outright (exit 2): WiX Toolset has no Linux port, and the published
  .msi is Authenticode-signed during release."
write_yaml "$VERDICT" "$NOTES"
log_success "COMPARISON_RESULTS.yaml generated"
cat "$ORIG_DIR/COMPARISON_RESULTS.yaml"

# ---------- Standardized Result Summary ----------
echo "===== Begin Results ====="
echo "appId:          $APP_ID"
echo "signer:         N/A"
echo "apkVersionName: $VERSION"
echo "apkVersionCode: N/A"
echo "verdict:        $VERDICT"
echo "appHash:        $OFFICIAL_HASH"
echo "commit:         $ACTUAL_COMMIT"
echo "scriptVersion:  $SCRIPT_VERSION"
echo "scriptHash:     $SCRIPT_HASH"
echo "releaseScriptHash: $UPSTREAM_RELEASE_SCRIPT_HASH"
echo "releaseAdaptation: $RELEASE_ADAPTATION"
echo "dotnetRuntime:  ${OBSERVED_RUNTIME:-N/A} (read from the official artifact)"
echo "dotnetSdk:      ${SDK_VERSION} (candidates: ${SDK_ALTERNATIVES:-N/A})"
echo ""
echo "Diff:"
if [ "$MATCH" == "true" ]; then
  echo "BUILDS MATCH BINARIES"
  echo "$EXPECTED_FILE - $ARCH - $BUILT_HASH - 1 (MATCHES)"
else
  echo "BUILDS DO NOT MATCH BINARIES"
  echo "$EXPECTED_FILE - $ARCH - $BUILT_HASH - 0 (DOESN'T MATCH)"
  echo "Full diff: $DIFF_FILE"
  if [ "$TYPE" = "deb" ] && [ -n "${META_DIFF_FILE:-}" ]; then
    echo ""
    echo "Archive metadata (diagnostic; does not affect the verdict above):"
    if [ "${META_PAYLOAD_DIFFS:-0}" -eq 0 ] && [ "${META_CONTROL_DIFFS:-0}" -eq 0 ]; then
      echo "  payload and control archives identical in ownership, modes, timestamps and member order"
      echo "  the difference is confined to file contents shown in the diff above"
    else
      echo "  payload archive: ${META_PAYLOAD_DIFFS:-?} differing entries"
      echo "  control archive: ${META_CONTROL_DIFFS:-?} differing entries"
      echo "  compared with numeric owners, full timestamps and original member order"
    fi
    echo "  Full listing: $META_DIFF_FILE"
  fi
fi
echo ""
echo "SUMMARY"
echo "total: 1"
echo "matches: $([ "$MATCH" == "true" ] && echo 1 || echo 0)"
echo "mismatches: $([ "$MATCH" == "true" ] && echo 0 || echo 1)"
echo ""
echo "Revision, tag (and its signature):"
echo "$GPG_VERIFICATION"
echo "COMMIT: $ACTUAL_COMMIT"
echo "===== End Results ====="

if [ "$MATCH" != "true" ]; then
  echo ""
  echo "Run a full comparison with:"
  echo "diff --recursive \"$WORKSPACE/official-extracted\" \"$WORKSPACE/built-extracted\""
  echo "meld \"$WORKSPACE/official-extracted\" \"$WORKSPACE/built-extracted\""
  echo "diffoscope \"$WORKSPACE/official-$EXPECTED_FILE\" \"$WORKSPACE/output/$EXPECTED_FILE\""
fi

echo ""
echo "========================================="
echo "Build Verification Complete"
echo "========================================="
echo "Version:      $VERSION"
echo "Architecture: $ARCH"
echo "Result:       $VERDICT"
echo "Workspace:    $WORKSPACE"
echo "Exit code:    $([ "$MATCH" == "true" ] && echo 0 || echo 1)"
echo "========================================="

trap - ERR
if [ "$MATCH" == "true" ]; then
  exit 0
else
  exit 1
fi
