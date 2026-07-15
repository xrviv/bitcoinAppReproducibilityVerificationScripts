#!/usr/bin/env bash
# ==============================================================================
# wasabidesktop_build.sh - Wasabi Wallet Desktop Reproducible Build Verification
# ==============================================================================
# Version:          v1.6.1
# Organization:     WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-07-15
# Project:          https://github.com/WalletWasabi/WalletWasabi
# ==============================================================================
# MIT License. Provided as-is for reproducible-build verification and security
# research, without warranty; you assume all risk and responsibility for lawful use.
#
# Inlines upstream Contrib/release.sh's "debian" target (source: tag v2.8.0,
# https://github.com/WalletWasabi/WalletWasabi/blob/v2.8.0/Contrib/release.sh).
# A transcription, not an improvement: re-justify any change against the source
# file, and re-diff release.sh on every new upstream tag.
#
# Rationale, limitations, fidelity evidence and version history are kept in this
# app's changelog in WalletScrutiny's script notes.
# ==============================================================================

set -Eeuo pipefail

# ---------- Script Metadata ----------
SCRIPT_VERSION="v1.6.1"
APP_NAME="Wasabi Wallet"
APP_ID="wasabi"

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

usage() {
  cat <<EOF
Wasabi Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>] [--binary <file>]

Parameters:
  --version <version>   Wasabi version to verify. THIS SCRIPT VERSION SUPPORTS 2.8.0 ONLY.
  --arch <arch>         x86_64-linux-gnu (default, and the only supported value)
  --type <type>         deb (default), tarball, zip
  --binary <file>       Path to an official binary to compare against, instead of
                         downloading it from GitHub releases.
  --apk <file>          Accepted for ABS cross-platform compatibility; not
                         applicable to desktop builds, ignored.
  --help, -h             Show this help message

Unknown parameters are accepted and ignored with a warning (never fatal), per
WalletScrutiny ABS policy.

Known limitations:
  - linux-arm64 is a real release artifact since v2.8.0 (Contrib/release.sh
    debian cross-builds it alongside x64 regardless) but is not yet exposed
    as a selectable --arch here; deliberately scoped out of this patch.
  - Pinned to Wasabi 2.8.0 EXACTLY (exit 2 otherwise). The inlined release
    logic is transcribed from Contrib/release.sh at tag v2.8.0 and the .NET SDK
    pin (10.0.301-noble) was derived from that release's runner image. Both are
    release-specific: reusing them for another version could produce an invalid
    verdict. A new release needs the SDK pin re-derived, release.sh re-diffed
    against the transcription, and a new script version.
  - --arch win64 is rejected outright (exit 2). Wasabi's wininstaller target
    needs the WiX Toolset (heat/candle/light), which is Windows-only with no
    Linux port, so upstream's release script cannot complete in this container.
    It does produce the win-x64 zip mid-run, but only before WiX fails the
    build; reporting a verdict on an artifact pulled from a failed run is not
    acceptable. The win-x64 zip could later be built by inlining just the
    `dotnet publish -r win-x64` + zip steps -- a separate, testable change.
    Note also that the published .msi is Authenticode-signed with a private key
    during release and could never hash-match by design, and that upstream does
    not timestamp-normalize any zip (plain `zip -r`), so zips are expected to
    differ on that basis alone.

Examples:
  $(basename "$0") --version 2.8.0
  $(basename "$0") --version 2.8.0 --arch x86_64-linux-gnu --type deb
  $(basename "$0") --version 2.8.0 --arch x86_64-linux-gnu --type tarball --binary ~/Downloads/Wasabi-2.8.0-linux-x64.tar.gz

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
    --apk) log_info "--apk is not applicable to desktop builds; ignoring."; [ $# -ge 2 ] && shift 2 || shift ;;
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

# This script is pinned to ONE upstream release. It embeds logic transcribed from
# Contrib/release.sh at v2.8.0 and an SDK chosen for v2.8.0's runner; both go stale the
# moment upstream moves. Building another version with them would yield an authoritative
# looking but invalid verdict, so refuse rather than guess. See changelog v1.6.1.
SUPPORTED_VERSION="2.8.0"
if [ "${VERSION#[vV]}" != "$SUPPORTED_VERSION" ]; then
  log_error "This script version supports Wasabi ${SUPPORTED_VERSION} only; got: ${VERSION}"
  log_error "It embeds release logic transcribed from Contrib/release.sh at tag v${SUPPORTED_VERSION}"
  log_error "and a .NET SDK pin chosen to match that release's build. Reusing either for a"
  log_error "different version could produce an invalid verdict. Verifying another release"
  log_error "requires re-deriving the SDK pin, re-diffing release.sh, and a new script version."
  write_yaml "ftbfs" "  Unsupported --version '${VERSION}': this script version supports Wasabi ${SUPPORTED_VERSION} only. It embeds release logic transcribed from Contrib/release.sh at tag v${SUPPORTED_VERSION} and an SDK pin matched to that release's build environment; both are release-specific. Verifying another version requires re-deriving the SDK pin, re-diffing release.sh against the inlined transcription, and issuing a new script version."
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
if [ "$ARCH" != "x86_64-linux-gnu" ]; then
  log_error "Unsupported architecture: $ARCH"
  echo "Supported: x86_64-linux-gnu"
  # linux-arm64 is a real v2.8.0 release artifact (the inlined debian target
  # builds it alongside x64 regardless -- see the build step below) but is
  # deliberately not exposed as a selectable --arch in this patch; scoped out
  # per Danny's review, deserves its own version bump later.
  write_yaml "ftbfs" "  Unsupported --arch: ${ARCH}"
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
# Normalise leading V/v: "V2.8.0" would otherwise derive the bad tag "vV2.8.0".
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

# ---------- Determine Build Configuration ----------
# BUILD_TARGET is what we pass to Contrib/release.sh; EXPECTED_FILE is what we hash.
# Note: "debian" target cross-builds BOTH linux-x64 and linux-arm64 in one pass
# since v2.8.0 (Contrib/release.sh PLATFORMS array) -- confirmed at the tag --
# even though we only select/hash the x64 artifact below. arm64 is a real,
# separately-hashed release asset (Wasabi-<ver>-arm64.deb etc.) that deserves
# its own --arch support in a later version; deliberately out of scope here.
case "$ARCH" in
  x86_64-linux-gnu)
    BUILD_TARGET="debian"
    case "$TYPE" in
      deb) EXPECTED_FILE="Wasabi-${VERSION_NO_V}.deb" ;;
      tarball) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-x64.tar.gz" ;;
      zip) EXPECTED_FILE="Wasabi-${VERSION_NO_V}-linux-x64.zip" ;;
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

# ---------- Generate Embedded Dockerfile ----------
# Base image pin rationale (verified at the tag v2.8.0):
# - global.json @ v2.8.0: sdk.version=10.0.100, rollForward=latestFeature
# - .github/workflows/release.yml job "debian-package-and-zips" runs on
#   ubuntu-latest with NO explicit setup-dotnet step for Linux -- it resolves
#   whichever preinstalled SDK satisfies global.json.
# - The actual v2.8.0 release run (workflow run 28274724492, job 83779062333)
#   ran on runner image ubuntu-24.04 release ubuntu24/20260622.220, which
#   ships .NET SDKs 10.0.109 / 10.0.204 / 10.0.301. Per documented
#   rollForward=latestFeature semantics (highest feature band + highest patch
#   within the same major.minor), 10.0.301 is the only self-consistent match.
# - mcr.microsoft.com no longer ships a stable/GA Debian-based dotnet/sdk image
#   for .NET 10 (only Ubuntu "noble"; "trixie" is preview-only) -- confirmed
#   live against the registry tag list -- so "noble" is required, not just a
#   nice-to-have match for the CI OS.
#
# All tools needed for every later step (git, wget, gpg, zip/unzip, dpkg-dev)
# are installed here, at image-build time, as root. This is deliberate: every
# `run` step after this point uses CONTAINER_RUN_USER_ARGS (a non-root,
# host-UID-mapped user) so files written into the host-mounted workspace are
# never root-owned -- but `apt-get install` needs root, so it cannot happen at
# `run` time once user-mapping is in effect. One image build up front avoids
# that conflict entirely instead of mixing root and mapped-user `run` calls.
log_info "Generating embedded Dockerfile pinned to the SDK that built official v2.8.0..."
DOCKERFILE_PATH="$WORKSPACE/Dockerfile"
cat > "$DOCKERFILE_PATH" <<'DOCKERFILE_EOF'
FROM mcr.microsoft.com/dotnet/sdk:10.0.301-noble@sha256:ea8bde36c11b6e7eec2656d0e59101d4462f6bd630730f2c8201ed0572b295d5
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
  write_yaml "ftbfs" "  Failed to build the verification container image (dotnet SDK 10.0.301-noble base)."
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
if [ -z "$BINARY_FILE" ]; then
  CLONE_STEPS="$CLONE_STEPS && cd .. && wget -q --show-progress '$DOWNLOAD_URL' -O 'official-$EXPECTED_FILE'"
fi

if ! $CONTAINER_CMD run --rm $CONTAINER_RUN_USER_ARGS \
  -v "$WORKSPACE:/workspace:Z" -w /workspace \
  "$IMAGE_NAME" bash -c "$CLONE_STEPS"; then
  log_error "Failed to clone repository at tag $GIT_TAG$( [ -z "$BINARY_FILE" ] && echo " or download official release")"
  write_yaml "ftbfs" "  Failed to clone WalletWasabi at tag ${GIT_TAG}$( [ -z "$BINARY_FILE" ] && echo " or download the official release asset").
  URL attempted: ${DOWNLOAD_URL}"
  exit 1
fi
log_success "Cloned repository at $GIT_TAG$( [ -z "$BINARY_FILE" ] && echo " and downloaded official release")"

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

# ---------- Check Git Tag Authenticity (v2.8.0's tag is lightweight and unsigned) ----------
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

# ---------- Run Official Build ----------
CONTAINER_NAME="wasabi-build-run-${VERSION_NO_V}-${ARCH}-${TYPE}-$$"
cleanup_container() { $CONTAINER_CMD rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
trap 'cleanup_container' EXIT

  # ---------- Generate the inlined debian-target build script ----------
  # Transcribed from Contrib/release.sh at tag v2.8.0 (see script header for
  # the full citation and fidelity rule). Single-quoted heredoc: no variable
  # expansion by THIS script -- every $VAR below is evaluated inside the
  # container by the generated script itself, exactly as in the source.
  log_info "Generating inlined debian-target build script (from Contrib/release.sh @ v2.8.0)..."
  cat > "$WORKSPACE/inline-release-debian.sh" <<'INLINE_EOF'
#!/usr/bin/env bash
# Transcribed from WalletWasabi Contrib/release.sh, "debian" target, tag
# v2.8.0: https://github.com/WalletWasabi/WalletWasabi/blob/v2.8.0/Contrib/release.sh
# This is the code path GitHub Actions runs via
# `sudo bash -x ./Contrib/release.sh debian` in .github/workflows/release.yml
# job "debian-package-and-zips". The argument-dispatch scaffolding for the
# other targets (wininstaller/dmg/releasenote/gpgsign) is removed below since
# their guard variables are unconditionally "no" on this path in the source
# and produce no side effects -- everything that DOES execute here is an
# unmodified transcription. Do not "improve" this logic; any change must be
# re-justified against the source file above.
set -xe

STASH_MESSAGE="Stashed changes for script execution"
if [[ -n $(git status --porcelain) ]]; then
  git stash push -m "$STASH_MESSAGE" --quiet
fi

LATEST_TAG=$(git describe --tags --abbrev=0)
VERSION=${LATEST_TAG:1}
SHORT_VERSION=${VERSION:0:${#VERSION}-2}

DESKTOP="WalletWasabi.Fluent.Desktop"
COORDINATOR="WalletWasabi.Coordinator"
DAEMON="WalletWasabi.Daemon"
DAEMON_PROJECT="./$DAEMON/$DAEMON.csproj"
DESKTOP_PROJECT="./$DESKTOP/$DESKTOP.csproj"
COORDINATOR_PROJECT="./$COORDINATOR/$COORDINATOR.csproj"

ROOT_DIR=$(pwd)
BUILD_DIR="$ROOT_DIR/build"

EXECUTABLE_NAME="wassabee"
COORDINATOR_EXECUTABLE_NAME="wcoordinator"

PACKAGES_DIR="$ROOT_DIR/packages"
PACKAGE_FILE_NAME_PREFIX="Wasabi-$VERSION"

if [[ "$RUNNER_OS" == "Windows" ]]; then
  ZIP="7z.exe a"
else
  ZIP="zip -r"
fi

# Hardcoded target selection: this file IS the "debian" branch of release.sh
# ($1 = "debian" in the source's argument dispatch).
PLATFORMS=("linux-x64" "linux-arm64")
CREATE_DEBIAN_PACKAGE="yes"
PACKAGE_COORDINATOR="yes"

mkdir -p "$BUILD_DIR"
mkdir -p "$PACKAGES_DIR"

#------------------------------------------------------------------------------------#
# BUILD DESKTOP FOR ALL PLATFORMS                                                    #
#------------------------------------------------------------------------------------#
for PLATFORM in "${PLATFORMS[@]}"; do
  OUTPUT_DIR=$BUILD_DIR/$PLATFORM

  if [[ "$PACKAGE_COORDINATOR" == "yes" ]]; then
    PROJECTS_TO_BUILD=("$DAEMON_PROJECT" "$DESKTOP_PROJECT" "$COORDINATOR_PROJECT" )
  else
    PROJECTS_TO_BUILD=("$DAEMON_PROJECT" "$DESKTOP_PROJECT" )
  fi

  for PROJECT in "${PROJECTS_TO_BUILD[@]}"; do
    dotnet restore $PROJECT --locked-mode
    dotnet publish $PROJECT \
            --configuration Release \
            --runtime $PLATFORM \
            --force \
            --output $OUTPUT_DIR \
            --self-contained true \
            --disable-parallel \
            --no-cache \
            --no-restore \
            --property:SelfContained=true \
            --property:VersionPrefix=$VERSION \
            --property:DebugType=none \
            --property:DebugSymbols=false \
            --property:ErrorReport=none \
            --property:DocumentationFile='' \
            --property:Deterministic=true \
            /clp:ErrorsOnly
  done

  EXE_FILE_EXTENSION=''
  PLATFORM_PREFIX="${PLATFORM:0:3}"
  if [[ "$PLATFORM_PREFIX" == "win" ]]; then
    EXE_FILE_EXTENSION=".exe"
  fi

  mv $OUTPUT_DIR/{$DESKTOP,${EXECUTABLE_NAME}}$EXE_FILE_EXTENSION
  mv $OUTPUT_DIR/{$DAEMON,${EXECUTABLE_NAME}d}$EXE_FILE_EXTENSION
  if [[ "$PACKAGE_COORDINATOR" == "yes" ]]; then
    mv $OUTPUT_DIR/{$COORDINATOR,${COORDINATOR_EXECUTABLE_NAME}}$EXE_FILE_EXTENSION
  fi

  # Remove bundled app binaries for other platforms
  BUNDLED_APPS_DIR="$OUTPUT_DIR/BundledApps/Binaries"
  if [[ "${PLATFORM_PREFIX}" == "osx" ]]; then
    find $BUNDLED_APPS_DIR -mindepth 1 -maxdepth 1 -type d ! -name "osx64" -exec rm -rf {} +
  else
    find $BUNDLED_APPS_DIR -mindepth 1 -maxdepth 1 -type d ! -name "$PLATFORM" -exec rm -rf {} +
  fi

  # Hack! *.deps.json files contains this SHA512 that depends on the absolute path of
  # the nuget packages. This means that these files are different in different computers
  # and for different users. (End goal: reproducibility)
  if [[ "${PLATFORM_PREFIX}" == "osx" ]]; then
    sed -i '' 's/"sha512": "sha512-[^"]*"/"sha512": ""/g' "$OUTPUT_DIR/$DESKTOP.deps.json"
  else
    sed -i 's/"sha512": "sha512-[^"]*"/"sha512": ""/g' "$OUTPUT_DIR/$DESKTOP.deps.json"
  fi

  ALTER_PLATFORM=$PLATFORM
  if [[ "${PLATFORM_PREFIX}" == "osx" ]]; then
    ALTER_PLATFORM="macOS${PLATFORM:3}"
  fi

  # Create compressed package files (.zip and .tar.gz)
  PACKAGE_FILE_NAME=$PACKAGE_FILE_NAME_PREFIX-$ALTER_PLATFORM
  if [[ "${PLATFORM_PREFIX}" == "lin" ]]; then
     if [ -z "$SOURCE_DATE_EPOCH" ]; then
       export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
     fi

     PARENT_DIR=$(dirname "$OUTPUT_DIR")
     BASE_NAME=$(basename "$OUTPUT_DIR")

     tar --sort=name \
         --mtime="@${SOURCE_DATE_EPOCH}" \
         --owner=0 \
         --group=0 \
         --numeric-owner \
         --transform="s|^$BASE_NAME|WasabiWallet|" \
         --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
         -pczf $PACKAGES_DIR/$PACKAGE_FILE_NAME.tar.gz \
         -C "$PARENT_DIR" \
         "$BASE_NAME"
  fi

  pushd "$OUTPUT_DIR" || exit
  $ZIP "$PACKAGES_DIR/$PACKAGE_FILE_NAME.zip" .
  popd || exit

done

#------------------------------------------------------------------------------------#
# CREATE DEBIAN PACKAGE                                                              #
#------------------------------------------------------------------------------------#
if [ "$CREATE_DEBIAN_PACKAGE" = "yes" ]; then
for DEBIAN_ZIP_PACKAGE in $PACKAGES_DIR/Wasabi*linux*.zip; do

CURRENT_ARCH=$(echo "$DEBIAN_ZIP_PACKAGE" | grep -o 'arm64\|x64')
ZIP_PACKAGE=$(basename "$DEBIAN_ZIP_PACKAGE")

DEBIAN_PACKAGE_DIR=$BUILD_DIR/$ZIP_PACKAGE/deb
DEBIAN=$DEBIAN_PACKAGE_DIR/DEBIAN
DEBIAN_USR=$DEBIAN_PACKAGE_DIR/usr
DEBIAN_BIN=$DEBIAN_USR/local/bin

DEBIAN_ARCH_NAME=""
DEBIAN_FULL_PLATFORM_NAME="linux-x64"

if [ "$CURRENT_ARCH" = "arm64" ]; then
  DEBIAN_ARCH_NAME="-arm64"
  DEBIAN_FULL_PLATFORM_NAME="linux-arm64"
fi

mkdir -p $DEBIAN
mkdir -p $DEBIAN_BIN
mkdir -p $DEBIAN_USR/share/{applications,icons/hicolor}

for ICON_FILE in ./Contrib/Assets/WasabiLogo*.png; do
  SIZE=$(echo "$ICON_FILE" | grep -oP '\d+')
  ICON_DIR="$DEBIAN_USR/share/icons/hicolor/${SIZE}x${SIZE}/apps"
  mkdir -p "$ICON_DIR"
  cp "$ICON_FILE" "$ICON_DIR/$EXECUTABLE_NAME.png"
done

DEBIAN_PACKAGE_SIZE=$(du -s "${BUILD_DIR}/${DEBIAN_FULL_PLATFORM_NAME}" | cut -f1)

DEBIAN_CONTROL_FILE_CONTENT="Package: ${EXECUTABLE_NAME}
Priority: optional
Section: utils
Maintainer: Wasabi Wallet Team
Version: ${VERSION}
Homepage: https://wasabiwallet.io
Vcs-Git: git://github.com/WalletWasabi/WalletWasabi.git
Vcs-Browser: https://github.com/WalletWasabi/WalletWasabi
Architecture: amd64
License: Open Source (MIT)
Installed-Size: ${DEBIAN_PACKAGE_SIZE}
Recommends: policykit-1
Description: open-source, non-custodial, privacy focused Bitcoin wallet
  Built-in Tor, coinjoin, payjoin and coin control features."

echo "${DEBIAN_CONTROL_FILE_CONTENT}" > $DEBIAN/control

USR_LOCAL_BIN_DIR="/usr/local/bin"
INSTALL_DIR="${USR_LOCAL_BIN_DIR}/wasabiwallet"
DEBIAN_POST_INST_SCRIPT_CONTENT="#!/usr/bin/env sh
${INSTALL_DIR}/BundledApps/Binaries/${DEBIAN_FULL_PLATFORM_NAME}/hwi installudevrules
exit 0"
echo "${DEBIAN_POST_INST_SCRIPT_CONTENT}" > $DEBIAN/postinst
chmod 0775 ${DEBIAN}/postinst

DEBIAN_DESKTOP_CONTENT="[Desktop Entry]
Type=Application
Name=Wasabi Wallet
StartupWMClass=Wasabi Wallet
GenericName=Bitcoin Wallet
Comment=Privacy focused Bitcoin wallet.
Icon=${EXECUTABLE_NAME}
Terminal=false
Exec=${EXECUTABLE_NAME}
Categories=Office;Finance;
Keywords=bitcoin;wallet;crypto;blockchain;wasabi;privacy;anon;awesome;"

DEBIAN_DESKTOP="${DEBIAN_USR}/share/applications/${EXECUTABLE_NAME}.desktop"
echo "${DEBIAN_DESKTOP_CONTENT}" > $DEBIAN_DESKTOP
chmod 0644 $DEBIAN_DESKTOP

cp -a "${BUILD_DIR}/${DEBIAN_FULL_PLATFORM_NAME}" $DEBIAN_BIN/wasabiwallet

echo "#!/usr/bin/env sh
${INSTALL_DIR}/${EXECUTABLE_NAME} \$@" > ${DEBIAN_BIN}/${EXECUTABLE_NAME}

echo "#!/usr/bin/env sh
${INSTALL_DIR}/${EXECUTABLE_NAME}d \$@" > ${DEBIAN_BIN}/${EXECUTABLE_NAME}d

chmod 0755 ${DEBIAN_BIN}/wasabiwallet
find ${DEBIAN_BIN}/wasabiwallet -type f -exec chmod 655 {} \;
find ${DEBIAN_BIN}/wasabiwallet -type d -not -path ${DEBIAN_BIN}/wasabiwallet -exec chmod 755 {} \;
chmod 0755 ${DEBIAN_BIN}/wasabiwallet/${EXECUTABLE_NAME}{,d}
chmod 0755 ${DEBIAN_BIN}/${EXECUTABLE_NAME}{,d}

if [[ "$PACKAGE_COORDINATOR" == "yes" ]]; then
  echo "#!/usr/bin/env sh
  ${INSTALL_DIR}/${COORDINATOR_EXECUTABLE_NAME} \$@" > ${DEBIAN_BIN}/${COORDINATOR_EXECUTABLE_NAME}

  chmod 0755 ${DEBIAN_BIN}/wasabiwallet/${COORDINATOR_EXECUTABLE_NAME}
  chmod 0755 ${DEBIAN_BIN}/${COORDINATOR_EXECUTABLE_NAME}
fi

dpkg-deb -Zxz --build "${DEBIAN_PACKAGE_DIR}" "$PACKAGES_DIR/${PACKAGE_FILE_NAME_PREFIX}${DEBIAN_ARCH_NAME}.deb"

done
fi

# Unstash changes if there were any (present on every target in the source,
# including debian -- transcribed for fidelity even though our fresh checkout
# never has uncommitted changes to stash in the first place).
if git stash list | head -1 | grep -q "$STASH_MESSAGE"; then
  git stash pop
  echo "Changes unstashed."
fi
INLINE_EOF
  log_success "Inlined build script generated"

  log_info "Running inlined debian-target build inside container..."
  log_info "(inlined transcription of Contrib/release.sh @ v2.8.0 -- see script header)"
  # Build path must be GitHub's CI path: [CallerFilePath] bakes it into
  # Fluent.Desktop.dll, so building elsewhere breaks reproduction. See changelog v1.6.0.
  if ! $CONTAINER_CMD run --name "$CONTAINER_NAME" $CONTAINER_RUN_USER_ARGS \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -v "$WORKSPACE/walletwasabi:/home/runner/work/WalletWasabi/WalletWasabi:Z" \
    -v "$WORKSPACE/inline-release-debian.sh:/workspace/inline-release-debian.sh:Z" \
    "$IMAGE_NAME" \
    bash -c "cd /home/runner/work/WalletWasabi/WalletWasabi && bash /workspace/inline-release-debian.sh"; then
    log_error "Build failed inside container"
    write_yaml "ftbfs" "  Inlined debian-target build (transcribed from Contrib/release.sh @ v2.8.0) failed to build from source at tag ${GIT_TAG} (commit ${ACTUAL_COMMIT})."
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
fi

# ---------- Generate COMPARISON_RESULTS.yaml (minimal 3-field format) ----------
NOTES="  Wasabi ${VERSION} (--arch ${ARCH} --type ${TYPE}). For x86_64-linux-gnu, this
  script transcribes upstream Contrib/release.sh's debian-target logic (at tag
  ${GIT_TAG}) directly rather than calling it. Built inside
  mcr.microsoft.com/dotnet/sdk:10.0.301-noble.
  That SDK was INFERRED, not observed: the official release run's log prints no
  resolved SDK version, so 10.0.301 was derived from the ubuntu-24.04 runner image
  it used (which ships 10.0.109/10.0.204/10.0.301) plus global.json's rollForward:
  latestFeature. It is corroborated by every bundled runtime assembly and other
  payload file matching the official package byte-for-byte, which a different SDK
  would likely have changed. Since v2.8.0, upstream's release.sh normalizes Linux
  tarball timestamps itself via SOURCE_DATE_EPOCH; this transcription preserves
  that normalization unmodified. zip artifacts are not timestamp-normalized by
  upstream and are expected to differ on that basis alone. --type msi is
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
echo ""
echo "Diff:"
if [ "$MATCH" == "true" ]; then
  echo "BUILDS MATCH BINARIES"
  echo "$EXPECTED_FILE - $ARCH - $BUILT_HASH - 1 (MATCHES)"
else
  echo "BUILDS DO NOT MATCH BINARIES"
  echo "$EXPECTED_FILE - $ARCH - $BUILT_HASH - 0 (DOESN'T MATCH)"
  echo "Full diff: $DIFF_FILE"
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
