#!/usr/bin/env bash
# ==============================================================================
# bisq2_build.sh - Bisq2 Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.9
# Organization:  WalletScrutiny.com
# Last Modified: 2026-06-01
# Project:       https://github.com/bisq-network/bisq2
# ==============================================================================
# LICENSE: MIT License
#
# LEGAL DISCLAIMER:
# This script is an independent verification tool. It is not affiliated
# with, endorsed by, or sponsored by Bisq Network or any related entity.
# Use of this script is at your own risk. WalletScrutiny.com makes no
# representations about the official release binaries being verified.
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose.
#
# SCRIPT SUMMARY:
# - Builds Bisq2 desktop installer from source in a containerized environment
# - Downloads the official release artifact from GitHub
# - Compares at multiple levels: DEB hash, extracted contents, app JARs, bytecode
# - Writes categorized diff files to the work directory
# - Generates COMPARISON_RESULTS.yaml for build server automation
#
# TRIAGE METHODOLOGY (mirrors manual investigation steps):
# Level 1: SHA256 hash of full DEB
# Level 2: Extracted size comparison (compressed vs uncompressed delta)
# Level 3: diff -r --brief on extracted DEB contents
# Level 4: Categorization — DEBIAN/control, app JARs, JRE, other
# Level 5: Per-JAR class file extraction and comparison
# Level 6: javap -c disassembly comparison on differing class files
#
# MANUAL FINDINGS FOR v2.1.10 (not auto-classified by this script):
# - Bundled JRE differs: Azul CDN serves different binary builds under same version
# - App JARs differ: ZIP timestamp non-determinism (no SOURCE_DATE_EPOCH)
# - ApplicationVersion.class: commit hash truncation (non-functional, 9 vs 10 chars)
# - DEBIAN/control: missing X11 deps if build host lacks them

set -euo pipefail

# ==============================================================================
# Metadata
# ==============================================================================
SCRIPT_VERSION="v0.1.9"
SCRIPT_NAME="bisq2_build.sh"
APP_NAME="Bisq2"
APP_ID="bisq2"
REPO_URL="https://github.com/bisq-network/bisq2"

# ==============================================================================
# Exit codes
# ==============================================================================
EXIT_SUCCESS=0
EXIT_DIFFERENCES=1
EXIT_INVALID_PARAMS=2

# ==============================================================================
# Styling
# ==============================================================================
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ==============================================================================
# Parameters
# ==============================================================================
VERSION=""
ARCH="x86_64-linux"
BUILD_TYPE="deb"
BINARY_FILE=""
NO_CACHE=false
KEEP_CONTAINER=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_EXECUTION_DIR="$SCRIPT_DIR"

IMAGE_NAME=""
CONTAINER_NAME=""
WORK_DIR=""

# ==============================================================================
# Helpers
# ==============================================================================
sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input##-}"
    input="${input%%-}"
    [[ -z "$input" ]] && input="na"
    echo "$input"
}

write_yaml() {
    local verdict="$1"
    local notes="${2:-}"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        if [[ -n "$notes" ]]; then
            echo "notes: |"
            echo "$notes" | sed 's/^/  /'
        fi
    } > "${ORIGINAL_EXECUTION_DIR}/COMPARISON_RESULTS.yaml"
}

die() {
    local msg="$1"
    local code="${2:-$EXIT_DIFFERENCES}"
    log_error "$msg"
    write_yaml "ftbfs" "$msg"
    exit "$code"
}

usage() {
    cat << EOF
Bisq2 Desktop Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>] [--binary <file>]

Required:
  --version <version>    Bisq2 version to verify (e.g., 2.1.10)

Optional:
  --arch <arch>          Architecture (default: x86_64-linux)
  --type <type>          Package type: deb, rpm (default: deb)
                         NOTE: type is NOT auto-detected from --binary filename.
                         Always pass --type rpm explicitly when verifying an RPM.
  --binary <file>        Path to official DEB/RPM — skips download, build always runs
  --no-cache             Force fresh Docker/Podman image build
  --keep-container       Keep container after build for inspection
  --help                 Show this help

Examples:
  $(basename "$0") --version 2.1.10 --type deb
  $(basename "$0") --version 2.1.10 --binary /path/to/Bisq-2.1.10.deb
  $(basename "$0") --version 2.1.10 --type rpm --binary /path/to/Bisq-2.1.10.rpm

Output files (in work directory):
  COMPARISON_RESULTS.yaml      Machine-readable verdict
  diff_brief.txt               diff -r --brief on extracted DEB/RPM
  diff_full.txt                Full diff of extracted DEB/RPM contents
  diff_control.txt             DEBIAN/control differences (DEB only)
  diff_app_jars_brief.txt      Which app JARs differ
  diff_jre_brief.txt           Which JRE files differ
  diff_class_files.txt         Per-class bytecode comparison report
  bi2p-jar.sha256              bi2p shadow JAR hash (reproducibility probe)

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ==============================================================================
# Parameter parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        VERSION="$2";       shift 2 ;;
        --arch)           ARCH="$2";          shift 2 ;;
        --type)           BUILD_TYPE="$2";    shift 2 ;;
        --binary)         BINARY_FILE="$2";   shift 2 ;;
        --no-cache)       NO_CACHE=true;      shift ;;
        --keep-container) KEEP_CONTAINER=true; shift ;;
        --help|-h)        usage; exit 0 ;;
        --apk)
            log_warn "--apk is not applicable for desktop builds — ignoring"
            shift 2
            ;;
        *)
            log_warn "Unknown parameter: $1 — ignoring"
            shift
            ;;
    esac
done

[[ -z "$VERSION" ]] && { log_error "Missing required parameter: --version"; usage; exit "$EXIT_INVALID_PARAMS"; }

VERSION_CLEAN="${VERSION#v}"
GIT_TAG="v${VERSION_CLEAN}"

case "$ARCH" in
    x86_64-linux|x86_64-linux-gnu) ARCH="x86_64-linux" ;;
    *)
        log_warn "Unsupported arch: $ARCH — defaulting to x86_64-linux"
        ARCH="x86_64-linux"
        ;;
esac

case "$BUILD_TYPE" in
    deb|rpm) ;;
    *)
        log_warn "Unsupported type: $BUILD_TYPE — defaulting to deb"
        BUILD_TYPE="deb"
        ;;
esac

# ==============================================================================
# Artifact names
# ==============================================================================
if [[ "$BUILD_TYPE" == "deb" ]]; then
    BUILT_ARTIFACT="bisq2_${VERSION_CLEAN}-1_amd64.deb"
    OFFICIAL_ARTIFACT="Bisq-${VERSION_CLEAN}.deb"
else
    BUILT_ARTIFACT="bisq2-${VERSION_CLEAN}-1.x86_64.rpm"
    OFFICIAL_ARTIFACT="Bisq-${VERSION_CLEAN}.rpm"
fi

GITHUB_RELEASE_URL="${REPO_URL}/releases/download/${GIT_TAG}/${OFFICIAL_ARTIFACT}"

# ==============================================================================
# Work directory and container names
# ==============================================================================
VERSION_SLUG=$(sanitize_component "$VERSION_CLEAN")
ARCH_SLUG=$(sanitize_component "$ARCH")
TYPE_SLUG=$(sanitize_component "$BUILD_TYPE")
SUFFIX=$(sanitize_component "$(date +%s)-$$")

IMAGE_NAME="ws-bisq2-image-${VERSION_SLUG}-${ARCH_SLUG}-${TYPE_SLUG}-${SUFFIX}"
CONTAINER_NAME="ws-bisq2-container-${VERSION_SLUG}-${ARCH_SLUG}-${TYPE_SLUG}-${SUFFIX}"
WORK_DIR="${SCRIPT_DIR}/bisq2_${VERSION_SLUG}_${ARCH_SLUG}_${TYPE_SLUG}_$$"
BUILD_CONTEXT=$(mktemp -d /tmp/ws-bisq2-context-XXXXXX)
mkdir -p "$WORK_DIR"

# ==============================================================================
# Container runtime detection
# ==============================================================================
CONTAINER_RUNTIME=""
if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    die "Neither podman nor docker found"
fi
log_info "Container runtime: $CONTAINER_RUNTIME"

# ==============================================================================
# Cleanup
# ==============================================================================
cleanup_on_exit() {
    if [[ "$KEEP_CONTAINER" == "false" ]] && [[ -n "${CONTAINER_NAME:-}" ]]; then
        $CONTAINER_RUNTIME stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        $CONTAINER_RUNTIME rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ "$KEEP_CONTAINER" == "false" ]] && [[ -n "${IMAGE_NAME:-}" ]]; then
        $CONTAINER_RUNTIME rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
    fi
    rm -rf "${BUILD_CONTEXT:-}" 2>/dev/null || true
}
trap cleanup_on_exit EXIT INT TERM

log_info "========================================================"
log_info "Bisq2 Desktop Reproducible Build Verification"
log_info "========================================================"
log_info "Version:   $VERSION_CLEAN"
log_info "Git tag:   $GIT_TAG"
log_info "Arch:      $ARCH"
log_info "Type:      $BUILD_TYPE"
log_info "Work dir:  $WORK_DIR"
log_info "Script:    $SCRIPT_VERSION"
log_info "========================================================"

# ==============================================================================
# Dockerfile
# ==============================================================================
DOCKERFILE="$BUILD_CONTEXT/Dockerfile"
cat > "$DOCKERFILE" << 'DOCKERFILE_EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y \
    git curl wget unzip fakeroot rpm dpkg cpio \
    libasound2 libxi6 libxrender1 libxtst6 \
    apt-transport-https gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Container runs as root — replace fakeroot with a passthrough so jpackage's
# internal "fakeroot dpkg-deb -b" call succeeds without needing ptrace/preload
# (which breaks in rootless Podman user namespaces even with --privileged).
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/fakeroot \
    && chmod 755 /usr/local/bin/fakeroot

RUN apt-get update && apt-get install -y tor && rm -rf /var/lib/apt/lists/*

ENV ZULU_JDK_ARCHIVE_SHA256=7f15f667580a8977962dc0a709cf2a097cc71244614fad3f236debce9d1c2670

RUN wget -q https://cdn.azul.com/zulu/bin/zulu21.48.15-ca-jdk21.0.10-linux_x64.tar.gz \
        -O /tmp/zulu21.tar.gz \
    && echo "${ZULU_JDK_ARCHIVE_SHA256}  /tmp/zulu21.tar.gz" | sha256sum -c - \
    && mkdir -p /usr/lib/jvm \
    && tar -xzf /tmp/zulu21.tar.gz -C /usr/lib/jvm \
    && rm /tmp/zulu21.tar.gz

ENV JAVA_HOME=/usr/lib/jvm/zulu21.48.15-ca-jdk21.0.10-linux_x64
ENV PATH="${JAVA_HOME}/bin:${PATH}"
RUN java -version

COPY .bisq2-container-script.sh /bisq2-container-script.sh
RUN chmod +x /bisq2-container-script.sh
CMD ["/bisq2-container-script.sh"]
DOCKERFILE_EOF

# ==============================================================================
# Container inner script
# ==============================================================================
CONTAINER_SCRIPT="$BUILD_CONTEXT/.bisq2-container-script.sh"
cat > "$CONTAINER_SCRIPT" << 'CONTAINER_EOF'
#!/bin/bash
set -uo pipefail

GIT_TAG="${GIT_TAG:-v2.1.10}"
VERSION_CLEAN="${VERSION_CLEAN:-2.1.10}"
BUILD_TYPE="${BUILD_TYPE:-deb}"
BUILT_ARTIFACT="${BUILT_ARTIFACT:-bisq2_2.1.10-1_amd64.deb}"
OFFICIAL_ARTIFACT="${OFFICIAL_ARTIFACT:-Bisq-2.1.10.deb}"
GITHUB_RELEASE_URL="${GITHUB_RELEASE_URL:-}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-false}"
BINARY_FILENAME="${BINARY_FILENAME:-}"

OUTPUT="/output"
mkdir -p "$OUTPUT"

export TZ=UTC
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

write_yaml() {
    local verdict="$1"
    local notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        if [[ -n "$notes" ]]; then
            echo "notes: |"
            echo "$notes" | sed 's/^/  /'
        fi
    } > "$OUTPUT/COMPARISON_RESULTS.yaml"
}

fail() {
    echo "[ERROR] $1"
    write_yaml "ftbfs" "$1"
    exit 1
}

echo "=== Bisq2 Verification Container ==="
echo "Version:   $VERSION_CLEAN"
echo "Git tag:   $GIT_TAG"
echo "Type:      $BUILD_TYPE"
echo "Java:      $(java -version 2>&1 | head -1)"
echo "Zulu JDK archive SHA256: $ZULU_JDK_ARCHIVE_SHA256"
echo ""

# ------------------------------------------------------------------
# PHASE 1: BUILD (always runs)
# ------------------------------------------------------------------
echo "[INFO] Cloning $GIT_TAG..."
git clone https://github.com/bisq-network/bisq2.git /build/bisq2 \
    || fail "git clone failed"

cd /build/bisq2
git fetch --tags --force || fail "git fetch --tags failed"
git checkout "$GIT_TAG" || fail "git checkout failed"
git describe --tags --exact-match >/dev/null 2>&1 || fail "checked out commit is not exactly $GIT_TAG"

# Pin git short-hash length to match the official release (10 chars).
# Without this, git auto-selects abbrev length based on repo object count,
# which causes ApplicationVersion.class to embed a 9-char hash instead of 10.
git config core.abbrev 10
echo "[INFO] core.abbrev set to: $(git config core.abbrev)"

# Best-effort reproducibility settings. Bisq2 does not fully honor these yet,
# but they reduce avoidable host-specific timestamp and locale drift.
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct "$GIT_TAG" 2>/dev/null || true)
[[ -n "$SOURCE_DATE_EPOCH" ]] && export SOURCE_DATE_EPOCH
if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS} -Duser.timezone=UTC -Dfile.encoding=UTF-8"
else
    export JAVA_TOOL_OPTIONS="-Duser.timezone=UTC -Dfile.encoding=UTF-8"
fi
echo "[INFO] SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH:-unset}"
echo "[INFO] JAVA_TOOL_OPTIONS: $JAVA_TOOL_OPTIONS"
echo "[INFO] Checked out commit: $(git rev-parse HEAD)"

echo "[INFO] Building all modules (skip tests)..."
./gradlew clean build -x test \
    || fail "gradlew build failed"

echo "[INFO] Generating installer..."
./gradlew :apps:desktop:desktop-app-launcher:clean \
    || fail "gradlew clean failed"
./gradlew :apps:desktop:desktop-app-launcher:generateInstallers \
    || fail "gradlew generateInstallers failed"

BUILT_DEB=$(find /build/bisq2/apps/desktop/desktop-app-launcher/build/packaging/jpackage/packages \
    -name "$BUILT_ARTIFACT" 2>/dev/null | head -1)
[[ -z "$BUILT_DEB" ]] && fail "Built artifact not found: $BUILT_ARTIFACT"

cp "$BUILT_DEB" "$OUTPUT/$BUILT_ARTIFACT"
BUILT_DEB="$OUTPUT/$BUILT_ARTIFACT"

# Capture the independently-versioned bi2p shadow JAR hash when present.
BI2P_JAR=$(find /build/bisq2/apps/desktop/bi2p/build/libs \
    -maxdepth 1 -type f -name 'bi2p-*-all.jar' 2>/dev/null | sort | head -1)
[[ -n "$BI2P_JAR" ]] && sha256sum "$BI2P_JAR" > "$OUTPUT/bi2p-jar.sha256"

# Copy JAR hashes file
cp /build/bisq2/apps/desktop/desktop-app-launcher/build/packaging/jpackage/packages/*.sha256 \
    "$OUTPUT/" 2>/dev/null || true

BUILT_SIZE=$(du -b "$BUILT_DEB" | cut -f1)
echo "[INFO] Built artifact: $(basename "$BUILT_DEB") (${BUILT_SIZE} bytes)"
[[ "$BUILT_SIZE" -lt 1048576 ]] \
    && fail "Built artifact is unexpectedly small (${BUILT_SIZE} bytes); jpackage likely failed"

# Stop Gradle daemon to free memory before analysis phases
./gradlew --stop >/dev/null 2>&1 || true

# ------------------------------------------------------------------
# PHASE 2: OFFICIAL ARTIFACT (download or use provided --binary)
# ------------------------------------------------------------------
OFFICIAL_DEB="$OUTPUT/$OFFICIAL_ARTIFACT"
if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
    echo "[INFO] Official binary provided via --binary — skipping download"
    if [[ -n "$BINARY_FILENAME" ]] && [[ -f "/input/$BINARY_FILENAME" ]]; then
        cp "/input/$BINARY_FILENAME" "$OFFICIAL_DEB"
        echo "[INFO] Using provided official binary: $BINARY_FILENAME"
    else
        PROVIDED_FILE=$(ls /input/ 2>/dev/null | head -1)
        [[ -z "$PROVIDED_FILE" ]] && fail "No binary found in /input/"
        cp "/input/$PROVIDED_FILE" "$OFFICIAL_DEB"
        echo "[WARN] BINARY_FILENAME not set — using first file found: $PROVIDED_FILE"
    fi
else
    echo "[INFO] Downloading official: $GITHUB_RELEASE_URL"
    wget -q --show-progress -O "$OFFICIAL_DEB" "$GITHUB_RELEASE_URL" \
        || fail "Failed to download official release"
fi

OFFICIAL_SIZE=$(du -b "$OFFICIAL_DEB" | cut -f1)
echo "[INFO] Official artifact: $OFFICIAL_ARTIFACT (${OFFICIAL_SIZE} bytes)"

# ------------------------------------------------------------------
# PHASE 3: HASH COMPARISON
# ------------------------------------------------------------------
BUILT_HASH=$(sha256sum "$BUILT_DEB" | cut -d' ' -f1)
OFFICIAL_HASH=$(sha256sum "$OFFICIAL_DEB" | cut -d' ' -f1)

echo ""
echo "=== Hash Comparison ==="
echo "Official: $OFFICIAL_HASH"
echo "Built:    $BUILT_HASH"

if [[ "$OFFICIAL_HASH" == "$BUILT_HASH" ]]; then
    echo "[OK] Hashes MATCH"
    write_yaml "reproducible" \
        "Official and built ${BUILD_TYPE} are byte-for-byte identical. Hash: ${OFFICIAL_HASH}"

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          bisq2"
    echo "signer:         N/A"
    echo "apkVersionName: $VERSION_CLEAN"
    echo "apkVersionCode: N/A"
    echo "verdict:        reproducible"
    echo "appHash:        $OFFICIAL_HASH"
    echo "commit:         $GIT_TAG"
    echo ""
    echo "Revision, tag (and its signature): Git tag: $GIT_TAG"
    echo ""
    echo "Diff:"
    echo "BUILDS MATCH"
    echo "===== End Results ====="
    echo "Exit code: 0"
    exit 0
fi

echo "[WARN] Hashes differ — proceeding with diff analysis"
SIZE_DIFF=$((BUILT_SIZE - OFFICIAL_SIZE))
echo "[INFO] Compressed size delta: ${SIZE_DIFF} bytes (built - official)"

if [[ "$BUILD_TYPE" == "rpm" ]]; then
    # ------------------------------------------------------------------
    # PHASE 4 (RPM): EXTRACT BOTH RPMS
    # ------------------------------------------------------------------
    EXTRACT_OFF="$OUTPUT/extracted-official"
    EXTRACT_BLT="$OUTPUT/extracted-built"
    mkdir -p "$EXTRACT_OFF" "$EXTRACT_BLT"

    echo "[INFO] Extracting RPMs..."
    (cd "$EXTRACT_OFF" && rpm2cpio "$OFFICIAL_DEB" | cpio -idm --quiet) \
        || fail "Failed to extract official RPM"
    (cd "$EXTRACT_BLT" && rpm2cpio "$BUILT_DEB"    | cpio -idm --quiet) \
        || fail "Failed to extract built RPM"

    EXTRACT_OFF_SIZE=$(du -sb "$EXTRACT_OFF" | cut -f1)
    EXTRACT_BLT_SIZE=$(du -sb "$EXTRACT_BLT" | cut -f1)
    EXTRACT_SIZE_DIFF=$((EXTRACT_BLT_SIZE - EXTRACT_OFF_SIZE))

    echo "[INFO] Extracted sizes:"
    echo "       Official: ${EXTRACT_OFF_SIZE} bytes"
    echo "       Built:    ${EXTRACT_BLT_SIZE} bytes"
    echo "       Delta:    ${EXTRACT_SIZE_DIFF} bytes"

    # ------------------------------------------------------------------
    # PHASE 5 (RPM): FULL DIFF
    # ------------------------------------------------------------------
    DIFF_BRIEF="$OUTPUT/diff_brief.txt"
    DIFF_FULL="$OUTPUT/diff_full.txt"

    echo "[INFO] Running diff -r --brief..."
    diff -r --brief "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_BRIEF" 2>&1 || true

    echo "[INFO] Running full diff (→ diff_full.txt)..."
    diff -r "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_FULL" 2>&1 || true

    DIFF_LINES=$(wc -l < "$DIFF_FULL")
    DIFF_BRIEF_COUNT=$(grep -c "^" "$DIFF_BRIEF" 2>/dev/null || echo 0)
    echo "[INFO] Full diff: ${DIFF_LINES} lines across ${DIFF_BRIEF_COUNT} entries"

    # ------------------------------------------------------------------
    # PHASE 6 (RPM): CATEGORIZE DIFFS
    # ------------------------------------------------------------------
    echo ""
    echo "=== Diff Categorization ==="

    # App JARs
    APP_JAR_DIFF_BRIEF="$OUTPUT/diff_app_jars_brief.txt"
    diff -r --brief \
        "$EXTRACT_OFF/opt/bisq2/lib/app" \
        "$EXTRACT_BLT/opt/bisq2/lib/app" \
        > "$APP_JAR_DIFF_BRIEF" 2>&1 || true
    APP_JAR_DIFF_COUNT=$(grep -c "^Files" "$APP_JAR_DIFF_BRIEF" 2>/dev/null || echo 0)
    APP_JAR_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/app" | cut -f1)
    APP_JAR_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/app" | cut -f1)
    echo "[INFO] App JARs differing: ${APP_JAR_DIFF_COUNT} (→ diff_app_jars_brief.txt)"
    echo "[INFO] App JAR dir sizes: official=${APP_JAR_SIZE_OFF}  built=${APP_JAR_SIZE_BLT}"

    # JRE
    JRE_DIFF_BRIEF="$OUTPUT/diff_jre_brief.txt"
    diff -r --brief \
        "$EXTRACT_OFF/opt/bisq2/lib/runtime" \
        "$EXTRACT_BLT/opt/bisq2/lib/runtime" \
        > "$JRE_DIFF_BRIEF" 2>&1 || true
    JRE_DIFF_COUNT=$(grep -c "^" "$JRE_DIFF_BRIEF" 2>/dev/null || echo 0)
    JRE_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/runtime" | cut -f1)
    JRE_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/runtime" | cut -f1)
    echo "[INFO] JRE entries differing: ${JRE_DIFF_COUNT} (→ diff_jre_brief.txt)"
    echo "[INFO] JRE sizes: official=${JRE_SIZE_OFF}  built=${JRE_SIZE_BLT}"

    # ------------------------------------------------------------------
    # PHASE 7 (RPM): JAR CONTENT ANALYSIS (class-level)
    # ------------------------------------------------------------------
    echo ""
    echo "=== JAR Content Analysis ==="

    CLASS_DIFF_REPORT="$OUTPUT/diff_class_files.txt"
    CLASS_DIFF_TOTAL=0
    BYTECODE_DIFF_COUNT=0
    BYTECODE_DIFF_FILES=""

    while IFS= read -r brief_line; do
        [[ "$brief_line" != Files* ]] && continue
        jar_off=$(echo "$brief_line" | awk '{print $2}')
        jar_blt=$(echo "$brief_line" | awk '{print $4}')
        jar_name=$(basename "$jar_off")
        [[ "$jar_name" != *.jar ]] && continue

        JAR_EX_OFF="$OUTPUT/jar-extract/official/${jar_name%.jar}"
        JAR_EX_BLT="$OUTPUT/jar-extract/built/${jar_name%.jar}"
        mkdir -p "$JAR_EX_OFF" "$JAR_EX_BLT"

        unzip -q "$jar_off" -d "$JAR_EX_OFF" 2>/dev/null || continue
        unzip -q "$jar_blt" -d "$JAR_EX_BLT" 2>/dev/null || continue

        jar_class_diff=$(diff -r --brief "$JAR_EX_OFF" "$JAR_EX_BLT" 2>/dev/null \
            | grep "\.class" || true)
        [[ -z "$jar_class_diff" ]] && continue

        echo "=== $jar_name ===" >> "$CLASS_DIFF_REPORT"

        while IFS= read -r class_line; do
            [[ "$class_line" != Files* ]] && continue
            class_off=$(echo "$class_line" | awk '{print $2}')
            class_blt=$(echo "$class_line" | awk '{print $4}')
            [[ ! -f "$class_off" ]] || [[ ! -f "$class_blt" ]] && continue

            CLASS_DIFF_TOTAL=$((CLASS_DIFF_TOTAL + 1))
            javap_off=$(javap -c "$class_off" 2>/dev/null || true)
            javap_blt=$(javap -c "$class_blt" 2>/dev/null || true)

            if [[ "$javap_off" != "$javap_blt" ]]; then
                BYTECODE_DIFF_COUNT=$((BYTECODE_DIFF_COUNT + 1))
                BYTECODE_DIFF_FILES="${BYTECODE_DIFF_FILES} $(basename "$class_off")"
                echo "  [JAVAP -c DIFFERS] $(basename "$class_off")" \
                    >> "$CLASS_DIFF_REPORT"
                diff <(echo "$javap_off") <(echo "$javap_blt") \
                    >> "$CLASS_DIFF_REPORT" 2>/dev/null || true
            else
                echo "  [javap -c matched] $(basename "$class_off")" \
                    >> "$CLASS_DIFF_REPORT"
            fi
        done <<< "$jar_class_diff"
        rm -rf "$JAR_EX_OFF" "$JAR_EX_BLT"
    done < "$APP_JAR_DIFF_BRIEF"

    echo "[INFO] Class files with diffs examined: ${CLASS_DIFF_TOTAL}"
    echo "[INFO] Class disassembly differences:            ${BYTECODE_DIFF_COUNT}"
    [[ -f "$CLASS_DIFF_REPORT" ]] && echo "[INFO] Class diff report → diff_class_files.txt"

    # ------------------------------------------------------------------
    # PHASE 8 (RPM): RESULTS
    # ------------------------------------------------------------------
    echo ""
    echo "=== Summary ==="
    echo "[INFO] RPM hash match:            NO"
    echo "[INFO] Compressed size delta:     ${SIZE_DIFF} bytes"
    echo "[INFO] Extracted size delta:      ${EXTRACT_SIZE_DIFF} bytes"
    echo "[INFO] Full diff lines:           ${DIFF_LINES}"
    echo "[INFO] App JARs differing:        ${APP_JAR_DIFF_COUNT}"
    echo "[INFO] JRE entries differing:     ${JRE_DIFF_COUNT}"
    echo "[INFO] Class files examined:      ${CLASS_DIFF_TOTAL}"
    echo "[INFO] Class disassembly differences:      ${BYTECODE_DIFF_COUNT}"

    if [[ "$BYTECODE_DIFF_COUNT" -gt 0 ]]; then
        VERDICT_NOTES="Class disassembly differences in ${BYTECODE_DIFF_COUNT} class file(s):${BYTECODE_DIFF_FILES}. See diff_class_files.txt."
    else
        VERDICT_NOTES="RPM hash mismatch. Inspected differing class files had matching javap -c disassembly. See diff_full.txt, diff_class_files.txt, and diff_jre_brief.txt."
    fi

    write_yaml "not_reproducible" "$VERDICT_NOTES"

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          bisq2"
    echo "signer:         N/A"
    echo "apkVersionName: $VERSION_CLEAN"
    echo "apkVersionCode: N/A"
    echo "verdict:        differences found"
    echo "appHash:        $OFFICIAL_HASH"
    echo "commit:         $GIT_TAG"
    echo ""
    echo "Revision, tag (and its signature): Git tag: $GIT_TAG"
    echo ""
    echo "Diff (first 5 lines — full diff: diff_full.txt):"
    head -5 "$DIFF_BRIEF"
    echo "===== End Results ====="
    echo "Exit code: 1"
    exit 1
fi

# ------------------------------------------------------------------
# PHASE 4: EXTRACT BOTH DEBS
# ------------------------------------------------------------------
EXTRACT_OFF="$OUTPUT/extracted-official"
EXTRACT_BLT="$OUTPUT/extracted-built"
mkdir -p "$EXTRACT_OFF" "$EXTRACT_BLT"

echo "[INFO] Extracting DEBs..."
dpkg-deb -R "$OFFICIAL_DEB" "$EXTRACT_OFF" || fail "Failed to extract official DEB"
dpkg-deb -R "$BUILT_DEB"    "$EXTRACT_BLT" || fail "Failed to extract built DEB"

EXTRACT_OFF_SIZE=$(du -sb "$EXTRACT_OFF" | cut -f1)
EXTRACT_BLT_SIZE=$(du -sb "$EXTRACT_BLT" | cut -f1)
EXTRACT_SIZE_DIFF=$((EXTRACT_BLT_SIZE - EXTRACT_OFF_SIZE))

echo "[INFO] Extracted sizes:"
echo "       Official: ${EXTRACT_OFF_SIZE} bytes"
echo "       Built:    ${EXTRACT_BLT_SIZE} bytes"
echo "       Delta:    ${EXTRACT_SIZE_DIFF} bytes (note: opposite sign from compressed delta is normal)"

# ------------------------------------------------------------------
# PHASE 5: FULL DIFF
# ------------------------------------------------------------------
DIFF_BRIEF="$OUTPUT/diff_brief.txt"
DIFF_FULL="$OUTPUT/diff_full.txt"

echo "[INFO] Running diff -r --brief..."
diff -r --brief "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_BRIEF" 2>&1 || true

echo "[INFO] Running full diff (→ diff_full.txt)..."
diff -r "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_FULL" 2>&1 || true

DIFF_LINES=$(wc -l < "$DIFF_FULL")
DIFF_BRIEF_COUNT=$(grep -c "^" "$DIFF_BRIEF" 2>/dev/null || echo 0)
echo "[INFO] Full diff: ${DIFF_LINES} lines across ${DIFF_BRIEF_COUNT} entries"

# ------------------------------------------------------------------
# PHASE 6: CATEGORIZE DIFFS
# ------------------------------------------------------------------
echo ""
echo "=== Diff Categorization ==="

# DEBIAN/control
CONTROL_DIFF="$OUTPUT/diff_control.txt"
diff "$EXTRACT_OFF/DEBIAN/control" "$EXTRACT_BLT/DEBIAN/control" \
    > "$CONTROL_DIFF" 2>&1 || true
CONTROL_LINES=$(wc -l < "$CONTROL_DIFF" 2>/dev/null || echo 0)
echo "[INFO] DEBIAN/control diffs: ${CONTROL_LINES} lines (→ diff_control.txt)"
if [[ "$CONTROL_LINES" -gt 0 ]]; then
    head -5 "$CONTROL_DIFF"
fi

# App JARs
APP_JAR_DIFF_BRIEF="$OUTPUT/diff_app_jars_brief.txt"
diff -r --brief \
    "$EXTRACT_OFF/opt/bisq2/lib/app" \
    "$EXTRACT_BLT/opt/bisq2/lib/app" \
    > "$APP_JAR_DIFF_BRIEF" 2>&1 || true
APP_JAR_DIFF_COUNT=$(grep -c "^Files" "$APP_JAR_DIFF_BRIEF" 2>/dev/null || echo 0)
APP_JAR_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/app" | cut -f1)
APP_JAR_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/app" | cut -f1)
echo "[INFO] App JARs differing: ${APP_JAR_DIFF_COUNT} (→ diff_app_jars_brief.txt)"
echo "[INFO] App JAR dir sizes: official=${APP_JAR_SIZE_OFF}  built=${APP_JAR_SIZE_BLT}"

# JRE
JRE_DIFF_BRIEF="$OUTPUT/diff_jre_brief.txt"
diff -r --brief \
    "$EXTRACT_OFF/opt/bisq2/lib/runtime" \
    "$EXTRACT_BLT/opt/bisq2/lib/runtime" \
    > "$JRE_DIFF_BRIEF" 2>&1 || true
JRE_DIFF_COUNT=$(grep -c "^" "$JRE_DIFF_BRIEF" 2>/dev/null || echo 0)
JRE_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/runtime" | cut -f1)
JRE_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/runtime" | cut -f1)
echo "[INFO] JRE entries differing: ${JRE_DIFF_COUNT} (→ diff_jre_brief.txt)"
echo "[INFO] JRE sizes: official=${JRE_SIZE_OFF}  built=${JRE_SIZE_BLT}"

# ------------------------------------------------------------------
# PHASE 7: JAR CONTENT ANALYSIS (class-level)
# ------------------------------------------------------------------
echo ""
echo "=== JAR Content Analysis ==="

CLASS_DIFF_REPORT="$OUTPUT/diff_class_files.txt"
CLASS_DIFF_TOTAL=0
BYTECODE_DIFF_COUNT=0
BYTECODE_DIFF_FILES=""

while IFS= read -r brief_line; do
    # Only process lines like: Files /path/a.jar and /path/b.jar differ
    [[ "$brief_line" != Files* ]] && continue

    jar_off=$(echo "$brief_line" | awk '{print $2}')
    jar_blt=$(echo "$brief_line" | awk '{print $4}')
    jar_name=$(basename "$jar_off")
    [[ "$jar_name" != *.jar ]] && continue

    JAR_EX_OFF="$OUTPUT/jar-extract/official/${jar_name%.jar}"
    JAR_EX_BLT="$OUTPUT/jar-extract/built/${jar_name%.jar}"
    mkdir -p "$JAR_EX_OFF" "$JAR_EX_BLT"

    unzip -q "$jar_off" -d "$JAR_EX_OFF" 2>/dev/null || continue
    unzip -q "$jar_blt" -d "$JAR_EX_BLT" 2>/dev/null || continue

    jar_class_diff=$(diff -r --brief "$JAR_EX_OFF" "$JAR_EX_BLT" 2>/dev/null \
        | grep "\.class" || true)

    [[ -z "$jar_class_diff" ]] && continue

    echo "=== $jar_name ===" >> "$CLASS_DIFF_REPORT"

    while IFS= read -r class_line; do
        [[ "$class_line" != Files* ]] && continue

        class_off=$(echo "$class_line" | awk '{print $2}')
        class_blt=$(echo "$class_line" | awk '{print $4}')
        [[ ! -f "$class_off" ]] || [[ ! -f "$class_blt" ]] && continue

        CLASS_DIFF_TOTAL=$((CLASS_DIFF_TOTAL + 1))

        javap_off=$(javap -c "$class_off" 2>/dev/null || true)
        javap_blt=$(javap -c "$class_blt" 2>/dev/null || true)

        if [[ "$javap_off" != "$javap_blt" ]]; then
            BYTECODE_DIFF_COUNT=$((BYTECODE_DIFF_COUNT + 1))
            BYTECODE_DIFF_FILES="${BYTECODE_DIFF_FILES} $(basename "$class_off")"
            echo "  [JAVAP -c DIFFERS] $(basename "$class_off")" \
                >> "$CLASS_DIFF_REPORT"
            diff <(echo "$javap_off") <(echo "$javap_blt") \
                >> "$CLASS_DIFF_REPORT" 2>/dev/null || true
        else
            echo "  [javap -c matched] $(basename "$class_off")" \
                >> "$CLASS_DIFF_REPORT"
        fi
    done <<< "$jar_class_diff"
    rm -rf "$JAR_EX_OFF" "$JAR_EX_BLT"

done < "$APP_JAR_DIFF_BRIEF"

echo "[INFO] Class files with diffs examined: ${CLASS_DIFF_TOTAL}"
echo "[INFO] Class disassembly differences:            ${BYTECODE_DIFF_COUNT}"
if [[ -f "$CLASS_DIFF_REPORT" ]]; then
    echo "[INFO] Class diff report → diff_class_files.txt"
fi

# ------------------------------------------------------------------
# PHASE 8: RESULTS
# ------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "[INFO] DEB hash match:            NO"
echo "[INFO] Compressed size delta:     ${SIZE_DIFF} bytes"
echo "[INFO] Extracted size delta:      ${EXTRACT_SIZE_DIFF} bytes"
echo "[INFO] Full diff lines:           ${DIFF_LINES}"
echo "[INFO] App JARs differing:        ${APP_JAR_DIFF_COUNT}"
echo "[INFO] JRE entries differing:     ${JRE_DIFF_COUNT}"
echo "[INFO] Class files examined:      ${CLASS_DIFF_TOTAL}"
echo "[INFO] Class disassembly differences:      ${BYTECODE_DIFF_COUNT}"

if [[ "$BYTECODE_DIFF_COUNT" -gt 0 ]]; then
    VERDICT_NOTES="Class disassembly differences in ${BYTECODE_DIFF_COUNT} class file(s):${BYTECODE_DIFF_FILES}. See diff_class_files.txt."
else
    VERDICT_NOTES="DEB hash mismatch. Inspected differing class files had matching javap -c disassembly. See diff_full.txt, diff_control.txt, diff_class_files.txt, and diff_jre_brief.txt."
fi

write_yaml "not_reproducible" "$VERDICT_NOTES"

echo ""
echo "===== Begin Results ====="
echo "appId:          bisq2"
echo "signer:         N/A"
echo "apkVersionName: $VERSION_CLEAN"
echo "apkVersionCode: N/A"
echo "verdict:        differences found"
echo "appHash:        $OFFICIAL_HASH"
echo "commit:         $GIT_TAG"
echo ""
echo "Revision, tag (and its signature): Git tag: $GIT_TAG"
echo ""
echo "Diff (first 5 lines — full diff: diff_full.txt):"
head -5 "$DIFF_BRIEF"
echo "===== End Results ====="
echo "Exit code: 1"
exit 1
CONTAINER_EOF

chmod +x "$CONTAINER_SCRIPT"

# ==============================================================================
# Build container image
# ==============================================================================
log_info "Building container image: $IMAGE_NAME"
NO_CACHE_FLAG=""
[[ "$NO_CACHE" == "true" ]] && NO_CACHE_FLAG="--no-cache"

if ! $CONTAINER_RUNTIME build $NO_CACHE_FLAG \
        -f "$DOCKERFILE" \
        -t "$IMAGE_NAME" \
        "$BUILD_CONTEXT" 2>&1 | tee "$WORK_DIR/image-build.log"; then
    die "Container image build failed"
fi
log_success "Image built: $IMAGE_NAME"

# ==============================================================================
# Run container
# ==============================================================================
SKIP_DOWNLOAD="false"
BINARY_FILENAME=""
VOLUME_ARGS="-v ${WORK_DIR}:/output"

if [[ -n "$BINARY_FILE" ]]; then
    [[ ! -f "$BINARY_FILE" ]] && die "Binary file not found: $BINARY_FILE"
    SKIP_DOWNLOAD="true"
    BINARY_FILENAME=$(basename "$BINARY_FILE")
    BINARY_DIR=$(dirname "$(realpath "$BINARY_FILE")")
    VOLUME_ARGS="$VOLUME_ARGS -v ${BINARY_DIR}:/input:ro"
    log_info "Official binary provided — skipping download, will build from source"
fi

log_info "Starting container..."
set +e
$CONTAINER_RUNTIME run \
    --name "$CONTAINER_NAME" \
    --privileged \
    $VOLUME_ARGS \
    -e GIT_TAG="$GIT_TAG" \
    -e VERSION_CLEAN="$VERSION_CLEAN" \
    -e BUILD_TYPE="$BUILD_TYPE" \
    -e BUILT_ARTIFACT="$BUILT_ARTIFACT" \
    -e OFFICIAL_ARTIFACT="$OFFICIAL_ARTIFACT" \
    -e GITHUB_RELEASE_URL="$GITHUB_RELEASE_URL" \
    -e SKIP_DOWNLOAD="$SKIP_DOWNLOAD" \
    -e BINARY_FILENAME="$BINARY_FILENAME" \
    -e SCRIPT_VERSION="$SCRIPT_VERSION" \
    "$IMAGE_NAME" 2>&1 | tee "$WORK_DIR/container.log"
CONTAINER_EXIT="${PIPESTATUS[0]}"
set -e

# ==============================================================================
# Check output
# ==============================================================================
if [[ ! -f "${WORK_DIR}/COMPARISON_RESULTS.yaml" ]]; then
    die "Container produced no COMPARISON_RESULTS.yaml (container exit: $CONTAINER_EXIT)"
fi

cp "${WORK_DIR}/COMPARISON_RESULTS.yaml" "${ORIGINAL_EXECUTION_DIR}/COMPARISON_RESULTS.yaml"

log_info "========================================================"
log_info "Output files in: $WORK_DIR"
log_info "========================================================"
for f in COMPARISON_RESULTS.yaml diff_brief.txt diff_full.txt \
         diff_control.txt diff_app_jars_brief.txt diff_jre_brief.txt \
         diff_class_files.txt bi2p-jar.sha256; do
    [[ -f "$WORK_DIR/$f" ]] && log_info "  $f ($(wc -l < "$WORK_DIR/$f") lines)"
done

VERDICT=$(grep "verdict:" "${WORK_DIR}/COMPARISON_RESULTS.yaml" | head -1 | awk '{print $2}')
if [[ "$VERDICT" == "reproducible" ]]; then
    log_success "Verdict: REPRODUCIBLE"
    exit "$EXIT_SUCCESS"
else
    log_warn "Verdict: NOT REPRODUCIBLE — see diff files above"
    exit "$EXIT_DIFFERENCES"
fi
