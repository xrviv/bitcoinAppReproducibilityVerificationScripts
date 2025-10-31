#!/bin/bash
# ==============================================================================
# verify_myceliumandroid.sh - Mycelium Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.6
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-31
# Project:       https://github.com/mycelium-com/wallet-android
# ==============================================================================
# LICENSE: MIT License
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# Changes in v0.1.6:
# - Removed redundant host-side ensure_owner() calls that were failing (containers handle ownership internally)
#
# Changes in v0.1.5:
# - Workspace re-owned on host after container runs to simplify cleanup
#
# Changes in v0.1.4:
# - Ensure official APK copy is owned by host user before comparison
#
# Changes in v0.1.3:
# - Escaped TAG_REF variables in build.sh and stream container logs directly
#
# Changes in v0.1.2:
# - Switched comparison to unzip inside the container (removes apktool.yml/original noise)
#
# Changes in v0.1.1:
# - Removed host-side apktool/git usage; comparison now runs inside the container
# - Added --type and --arch parameters for build server compatibility
# - Requires official APK via --apk (device extraction/adb flow removed)
# - Container emits diff files, metadata, and git signature summaries
#
# SCRIPT SUMMARY:
# - Accepts official Mycelium APK via --apk
# - Performs fully containerized build (git clone inside container)
# - Uses official Dockerfile with disorderfs for filesystem ordering neutralization
# - Unzips official and built APKs inside the container for comparison (no apktool artifacts)
# - Documents differences and generates reproducibility assessment report
#
# REQUIREMENTS:
# - podman (or docker)

set -euo pipefail

# ============================================================================
# Constants and Configuration
# ============================================================================

SCRIPT_VERSION="v0.1.6"
SCRIPT_NAME="verify_myceliumandroid.sh"

# App identifiers
APP_ID="com.mycelium.wallet"
REPO_URL="https://github.com/mycelium-com/wallet-android.git"
GRADLE_TASK="mbw:assembleProdnetRelease"
APK_PATH_IN_BUILD="mbw/build/outputs/apk/prodnet/release/mbw-prodnet-release.apk"

# Color codes
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# Status indicators
SUCCESS_ICON="[OK]"
WARNING_ICON="[WARNING]"
ERROR_ICON="[ERROR]"
INFO_ICON="[INFO]"

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo -e "${RED}${ERROR_ICON} Neither podman nor docker found. Please install podman.${NC}"
    exit 1
fi

# ============================================================================
# Global Variables
# ============================================================================

versionName=""
officialApkPath=""
appType=""
appArch=""
shouldCleanup=false
workDir=""
containerWorkDir=""
toolsDir=""
builtApkPath=""
builderImageTag=""
officialCompareDir=""
builtCompareDir=""

# ============================================================================
# Utility Functions
# ============================================================================

ensure_owner() {
    local target="$1"
    [[ -e "$target" ]] || return
    if ! chown -R "$(id -u):$(id -g)" "$target" 2>/dev/null; then
        if command -v podman >/dev/null 2>&1; then
            podman unshare chown -R "$(id -u):$(id -g)" "$target" 2>/dev/null || true
        fi
    fi
}

# ============================================================================
# Helper Functions
# ============================================================================

show_help() {
    cat << EOF
Mycelium Android Reproducible Build Verification
Version: ${SCRIPT_VERSION}

USAGE:
    $SCRIPT_NAME --version <version> --apk <path> [OPTIONS]

REQUIRED PARAMETERS:
    --version <version>    Version to verify (e.g., 3.20.0.3)
    --apk <path>           Path to official APK extracted from Google Play

OPTIONAL PARAMETERS:
    --type <type>          Wallet type identifier (pass-through for automation)
    --arch <arch>          Target architecture (pass-through for automation)
    --script-version       Print script version and exit
    --cleanup              Remove working directory after verification
    --help                 Show this help message

REQUIREMENTS:
    - podman or docker (all other tooling runs inside containers)

EXAMPLES:
    # Verify version 3.20.0.3 with official APK
    $SCRIPT_NAME --version 3.20.0.3 --apk /path/to/com.mycelium.wallet.apk

    # Supply metadata for build server automation
    $SCRIPT_NAME --version 3.20.0.3 --apk /path/to/apk --type bitcoin --arch arm64-v8a

    # Verify and clean up workspace afterwards
    $SCRIPT_NAME --version 3.20.0.3 --apk /path/to/apk --cleanup

EXIT CODES:
    0 - Reproducible (only META-INF signature differences)
    1 - Non-reproducible (contains other differences) or error

OUTPUT:
    Working directory: ./mycelium_<version>_verification/
    Contains: official APK, built APK, extracted directories, diff files

EOF
}

check_dependencies() {
    echo -e "${CYAN}Checking dependencies...${NC}"
    echo -e "Container runtime ($CONTAINER_CMD) - ${GREEN}${SUCCESS_ICON}${NC}"
}



build_in_container() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Building APK in container${NC}"
    echo -e "${CYAN}========================================${NC}"

    containerWorkDir="$workDir/container-build"
    mkdir -p "$containerWorkDir"

    # Create Dockerfile (based on official Mycelium Dockerfile)
    cat > "$containerWorkDir/Dockerfile" << 'DOCKERFILE_END'
FROM ubuntu:18.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    openjdk-17-jdk \
    git \
    unzip \
    zip \
    wget \
    curl \
    disorderfs \
    fuse \
    diffutils \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Android SDK setup
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_SDK=/opt/android-sdk
ENV PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools

# Install Android SDK
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip && \
    unzip commandlinetools-linux-11076708_latest.zip && \
    rm commandlinetools-linux-11076708_latest.zip && \
    mv cmdline-tools latest

# Accept licenses and install SDK components
RUN yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" \
    "ndk;21.1.6352462" "cmake;3.22.1"

WORKDIR /workspace
DOCKERFILE_END

    # Build container image
    builderImageTag="mycelium_builder:${versionName}"
    echo -e "${YELLOW}Building container image ${builderImageTag} (this may take several minutes)...${NC}"
    if ! $CONTAINER_CMD build --tag "${builderImageTag}" "$containerWorkDir"; then
        echo -e "${RED}${ERROR_ICON} Container build failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}${SUCCESS_ICON} Container image built${NC}"

    # Run build inside container
    echo -e "${YELLOW}Running containerized build with disorderfs...${NC}"

    # Create build script to run inside container
cat > "$containerWorkDir/build.sh" << BUILDSCRIPT_END
#!/bin/bash
set -euo pipefail

HOST_UID="\${HOST_UID:-0}"
HOST_GID="\${HOST_GID:-0}"

echo "=== Cloning repository ==="
cd /workspace
git clone ${REPO_URL} repo
cd repo

echo "=== Checking out version v${versionName} ==="
if git rev-parse "v${versionName}" >/dev/null 2>&1; then
    git checkout "v${versionName}"
else
    git checkout "${versionName}"
fi

echo "=== Initializing submodules ==="
git submodule update --init --recursive

echo "=== Removing local.properties if present ==="
rm -f local.properties

TAG_REF="v${versionName}"
if git rev-parse "\${TAG_REF}" >/dev/null 2>&1; then
    git rev-parse "\${TAG_REF}" > /workspace/git-commit.txt
    git cat-file -t "\${TAG_REF}" > /workspace/git-tag-type.txt 2>/dev/null || echo "missing" > /workspace/git-tag-type.txt
    git verify-tag "\${TAG_REF}" > /workspace/git-tag-verify.txt 2>&1 || true
else
    echo "missing" > /workspace/git-tag-type.txt
    echo "Tag \${TAG_REF} not found" > /workspace/git-tag-verify.txt
    git rev-parse HEAD > /workspace/git-commit.txt
fi
git verify-commit HEAD > /workspace/git-commit-verify.txt 2>&1 || true

echo "=== Setting up disorderfs ==="
mkdir -p /project
disorderfs --sort-dirents=yes --reverse-dirents=no /workspace/repo /project

echo "=== Building APK ==="
cd /project
./gradlew -x lint -x test --no-daemon clean ${GRADLE_TASK}

echo "=== Copying APK to output ==="
cp ${APK_PATH_IN_BUILD} /workspace/output.apk

echo "=== Build complete ==="
ls -lh /workspace/output.apk

if command -v chown >/dev/null 2>&1; then
    chown -R "\${HOST_UID}:\${HOST_GID}" /workspace
fi
BUILDSCRIPT_END

    chmod +x "$containerWorkDir/build.sh"

    # Run container with required capabilities for disorderfs
    $CONTAINER_CMD run --rm \
        --device /dev/fuse \
        --cap-add SYS_ADMIN \
        --security-opt apparmor:unconfined \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -v "$containerWorkDir/build.sh:/build.sh:ro" \
        -v "$containerWorkDir:/workspace" \
        "${builderImageTag}" \
        /build.sh
    if [[ ! -f "$containerWorkDir/output.apk" ]]; then
        echo -e "${RED}${ERROR_ICON} Build failed - APK not found${NC}"
        exit 1
    fi
    mkdir -p "$workDir/built"
    builtApkPath="$workDir/built/mbw-prodnet-release.apk"
    cp "$containerWorkDir/output.apk" "$builtApkPath"
    for gitFile in git-commit.txt git-tag-type.txt git-tag-verify.txt git-commit-verify.txt; do
        if [[ -f "$containerWorkDir/$gitFile" ]]; then
            cp "$containerWorkDir/$gitFile" "$workDir/$gitFile"
        fi
    done
    echo -e "${GREEN}${SUCCESS_ICON} APK built successfully: $builtApkPath${NC}"
}

compare_apks() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Comparing APKs${NC}"
    echo -e "${CYAN}========================================${NC}"

    toolsDir="$workDir/container-tools"
    mkdir -p "$toolsDir"
    local analysisScript="$toolsDir/analysis.sh"

    cat > "$analysisScript" <<'EOF'
#!/bin/bash
set -euo pipefail

OFFICIAL_APK="$1"
BUILT_APK="$2"
WORKDIR="$3"
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

rm -rf "$WORKDIR/official-unzipped" "$WORKDIR/built-unzipped"
mkdir -p "$WORKDIR/official-unzipped" "$WORKDIR/built-unzipped"

unzip -q "$OFFICIAL_APK" -d "$WORKDIR/official-unzipped"
unzip -q "$BUILT_APK" -d "$WORKDIR/built-unzipped"

set +e
diff -ur "$WORKDIR/official-unzipped" "$WORKDIR/built-unzipped" > "$WORKDIR/diff-full.txt" 2>&1
diff -qr "$WORKDIR/official-unzipped" "$WORKDIR/built-unzipped" > "$WORKDIR/diff-brief.txt" 2>&1
set -e

AAPT=/opt/android-sdk/build-tools/34.0.0/aapt
APKSIGNER=/opt/android-sdk/build-tools/34.0.0/apksigner

official_badging=$($AAPT dump badging "$OFFICIAL_APK" 2> "$WORKDIR/aapt-official.log" || true)
built_badging=$($AAPT dump badging "$BUILT_APK" 2> "$WORKDIR/aapt-built.log" || true)

official_version_name=$(echo "$official_badging" | sed -n "s/.*versionName='\\([^']*\\)'.*/\\1/p" | head -n1)
official_version_code=$(echo "$official_badging" | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p" | head -n1)
built_version_name=$(echo "$built_badging" | sed -n "s/.*versionName='\\([^']*\\)'.*/\\1/p" | head -n1)
built_version_code=$(echo "$built_badging" | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p" | head -n1)

$APKSIGNER verify --print-certs "$OFFICIAL_APK" > "$WORKDIR/apksigner-official.txt" 2>&1 || true
$APKSIGNER verify --print-certs "$BUILT_APK" > "$WORKDIR/apksigner-built.txt" 2>&1 || true

official_signer=$(grep "Signer #1 certificate SHA-256" "$WORKDIR/apksigner-official.txt" | awk '{print $6}' | head -n1)
built_signer=$(grep "Signer #1 certificate SHA-256" "$WORKDIR/apksigner-built.txt" | awk '{print $6}' | head -n1)

official_hash=$(sha256sum "$OFFICIAL_APK" | awk '{print $1}')
built_hash=$(sha256sum "$BUILT_APK" | awk '{print $1}')

cat <<META > "$WORKDIR/metadata.txt"
official_version_name=${official_version_name:-unknown}
official_version_code=${official_version_code:-unknown}
official_signer=${official_signer:-unknown}
official_hash=$official_hash
built_version_name=${built_version_name:-unknown}
built_version_code=${built_version_code:-unknown}
built_signer=${built_signer:-unknown}
built_hash=$built_hash
META

if command -v chown >/dev/null 2>&1; then
    chown -R "$HOST_UID:$HOST_GID" "$WORKDIR"
fi
EOF

    chmod +x "$analysisScript"

    local officialForContainer="/workspace/official/base.apk"
    local builtFilename
    builtFilename=$(basename "$builtApkPath")
    local builtForContainer="/workspace/built/$builtFilename"

    $CONTAINER_CMD run --rm \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -v "$workDir":/workspace \
        -v "$analysisScript":/analysis.sh:ro \
        "${builderImageTag}" \
        /bin/bash /analysis.sh "$officialForContainer" "$builtForContainer" /workspace

    officialCompareDir="$workDir/official-unzipped"
    builtCompareDir="$workDir/built-unzipped"

    echo ""
    echo -e "${CYAN}=== Diff Results ===${NC}"
    if [[ -s "$workDir/diff-brief.txt" ]]; then
        cat "$workDir/diff-brief.txt"
    else
        echo "No differences found (perfectly reproducible)"
    fi
    echo ""
}

verify_git_signatures() {
    local tagTypeRaw=$(tr -d '\r' < "$workDir/git-tag-type.txt" 2>/dev/null || echo "missing")
    local tagInfo=$(cat "$workDir/git-tag-verify.txt" 2>/dev/null || echo "")
    local commitInfo=$(cat "$workDir/git-commit-verify.txt" 2>/dev/null || echo "")
    local commitHash=$(head -n1 "$workDir/git-commit.txt" 2>/dev/null || echo "unknown")

    local tagType="missing"
    local tagSigStatus="[WARNING] No tag signature information"
    local commitSigStatus="[WARNING] No commit signature information"

    case "$tagTypeRaw" in
        tag) tagType="annotated" ;;
        commit) tagType="lightweight" ;;
        missing|"") tagType="missing" ;;
        *) tagType="$tagTypeRaw" ;;
    esac

    if [[ -n "$tagInfo" ]]; then
        if echo "$tagInfo" | grep -q "Good signature"; then
            tagSigStatus="[OK] Good signature on annotated tag"
        elif echo "$tagInfo" | grep -qi "lightweight"; then
            tagSigStatus="[INFO] Lightweight tag (no signature)"
        else
            tagSigStatus="[WARNING] Tag signature verification failed"
        fi
    elif [[ "$tagType" == "lightweight" ]]; then
        tagSigStatus="[INFO] Tag is lightweight (cannot contain signature)"
    fi

    if [[ -n "$commitInfo" ]]; then
        if echo "$commitInfo" | grep -q "Good signature"; then
            commitSigStatus="[OK] Good signature on commit"
        else
            commitSigStatus="[WARNING] Commit signature verification failed"
        fi
    fi

    echo "$tagType|$tagSigStatus|$commitSigStatus|$tagInfo|$commitHash"
}

display_results() {
    local officialExtracted="$1"
    local builtExtracted="$2"
    local sigInfo="$3"

    local metadataFile="$workDir/metadata.txt"
    local versionNameFromApk="unknown"
    local versionCodeFromApk="unknown"
    local signerSha256="unknown"
    local apkHash="unknown"

    if [[ -f "$metadataFile" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                official_version_name) versionNameFromApk="$value" ;;
                official_version_code) versionCodeFromApk="$value" ;;
                official_signer) signerSha256="$value" ;;
                official_hash) apkHash="$value" ;;
            esac
        done < "$metadataFile"
    fi

    IFS='|' read -r tagType tagSigStatus commitSigStatus tagInfo commitHash <<< "$sigInfo"

    local diffBrief=$(cat "$workDir/diff-brief.txt" 2>/dev/null || echo "")
    local filtered=""
    if [[ -n "$diffBrief" ]]; then
        filtered=$(printf '%s\n' "$diffBrief" | grep -vE '^Only in .*: META-INF$|^Only in .*/META-INF: |^Files .*/META-INF/' || true)
    fi
    local diffCount=0
    if [[ -n "$filtered" ]]; then
        diffCount=$(printf '%s\n' "$filtered" | sed '/^$/d' | wc -l)
    fi

    local verdict="differences found"
    if [[ $diffCount -eq 0 ]]; then
        verdict="reproducible"
    fi

    local diffGuide=""
    if [[ "$shouldCleanup" != true ]]; then
        diffGuide="
Run a full
diff --recursive $officialExtracted $builtExtracted
meld $officialExtracted $builtExtracted
or
diffoscope \"$officialApkPath\" \"$builtApkPath\"
for more details."
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          $APP_ID"
    echo "signer:         $signerSha256"
    echo "apkVersionName: $versionNameFromApk"
    echo "apkVersionCode: $versionCodeFromApk"
    echo "verdict:        $verdict"
    echo "appHash:        $apkHash"
    echo "commit:         $commitHash"
    echo ""
    echo "Diff:"
    if [[ -n "$diffBrief" ]]; then
        echo "$diffBrief"
    else
        echo "No differences found (perfectly reproducible)"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    if [[ -n "$tagInfo" ]]; then
        echo "$tagInfo"
    else
        echo "No tag signature information available"
    fi
    echo ""
    echo "Signature Summary:"
    echo "Tag type: $tagType"
    echo "$tagSigStatus"
    echo "$commitSigStatus"
    echo ""
    echo "===== End Results ====="
    echo "$diffGuide"

    if [[ "$verdict" == "reproducible" ]]; then
        echo "Exit code: 0"
        return 0
    else
        echo "Exit code: 1"
        return 1
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Mycelium Android Verification ${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "Container runtime: $CONTAINER_CMD"
    echo ""

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                versionName="$2"
                shift 2
                ;;
            --apk)
                officialApkPath="$2"
                shift 2
                ;;
            --type)
                appType="$2"
                shift 2
                ;;
            --arch)
                appArch="$2"
                shift 2
                ;;
            --script-version)
                echo "$SCRIPT_NAME $SCRIPT_VERSION"
                exit 0
                ;;
            --cleanup)
                shouldCleanup=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}${ERROR_ICON} Unknown parameter: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$versionName" ]]; then
        echo -e "${RED}${ERROR_ICON} --version parameter is required${NC}"
        show_help
        exit 1
    fi
    if [[ -z "$officialApkPath" ]]; then
        echo -e "${RED}${ERROR_ICON} --apk parameter is required${NC}"
        show_help
        exit 1
    fi

    # Setup working directory in current execution path
    local executionDir
    executionDir="$(pwd)"
    workDir="${executionDir}/mycelium_${versionName}_verification"

    if [[ -d "$workDir" ]]; then
        echo -e "${YELLOW}${WARNING_ICON} Working directory already exists: $workDir${NC}"
        echo -e "${YELLOW}Removing existing directory...${NC}"
        rm -rf "$workDir"
    fi

    mkdir -p "$workDir"
    containerWorkDir="$workDir/container-build"
    toolsDir="$workDir/container-tools"
    mkdir -p "$containerWorkDir" "$toolsDir" "$workDir/official" "$workDir/built"
    echo "Working directory: $workDir"
    if [[ -n "$appType" ]]; then
        echo "App type: $appType"
    fi
    if [[ -n "$appArch" ]]; then
        echo "Target architecture: $appArch"
    fi
    echo ""

    # Check dependencies
    check_dependencies
    echo ""

    # Prepare official APK
    if [[ ! -f "$officialApkPath" ]]; then
        echo -e "${RED}${ERROR_ICON} APK file not found: $officialApkPath${NC}"
        exit 1
    fi
    cp "$officialApkPath" "$workDir/official/base.apk"
    officialApkPath="$workDir/official/base.apk"
    echo -e "${GREEN}${SUCCESS_ICON} Official APK copied to workspace: $officialApkPath${NC}"
    echo ""

    # Build in container
    build_in_container
    echo ""

    # Compare APKs
    compare_apks
    officialExtracted="$officialCompareDir"
    builtExtracted="$builtCompareDir"
    echo ""

    # Verify git signatures
    echo "Verifying git signatures..."
    sigInfo=$(verify_git_signatures "$versionName")
    echo ""

    # Display results
    display_results "$officialExtracted" "$builtExtracted" "$sigInfo"
    local exitCode=$?

    # Cleanup
    if [[ "$shouldCleanup" == true ]]; then
        echo ""
        echo "Cleaning up working directory..."
        rm -rf "$workDir"
        echo "Cleanup complete"
    else
        echo ""
        echo "Workspace retained at: $workDir"
    fi

    exit $exitCode
}

# Error handling
on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "${RED}${ERROR_ICON} Script failed at line $line_no with exit code $exit_code${NC}"
    echo -e "${RED}Last command: ${BASH_COMMAND}${NC}"

    if [[ -n "${workDir:-}" && -d "$workDir" ]]; then
        echo -e "${YELLOW}Partial workspace available at: $workDir${NC}"
    fi
}

trap 'on_error $LINENO' ERR

# Run main
main "$@"
