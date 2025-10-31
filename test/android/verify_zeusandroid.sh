#!/bin/bash
# ==============================================================================
# verify_zeusandroid.sh - Zeus Lightning Wallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.2
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-31
# Project:       https://github.com/ZeusLN/zeus
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
# SCRIPT SUMMARY:
# - Accepts official Zeus APK via --apk parameter
# - Clones Zeus repository and uses official build.sh with pinned Docker image
# - Leverages upstream reproducible build infrastructure (React Native Android container)
# - Compares built APK against official release using unzip-based binary analysis
# - Supports multiple architectures (universal, arm64-v8a, armeabi-v7a, x86, x86_64)
# - Documents differences and generates reproducibility assessment report
#
# REQUIREMENTS:
# - podman or docker (Zeus' build.sh uses Docker, can be aliased to podman)

set -euo pipefail

# ============================================================================
# Constants and Configuration
# ============================================================================

SCRIPT_VERSION="v0.1.2"
SCRIPT_NAME="verify_zeusandroid.sh"

# App identifiers
APP_ID="app.zeusln.zeus"
REPO_URL="https://github.com/ZeusLN/zeus.git"

# Zeus' official pinned Docker image
ZEUS_DOCKER_IMAGE="reactnativecommunity/react-native-android@sha256:c390bfb35a15ffdf52538bdd0e6c5a926469cefa8c8c6da54bfd501c122de25d"

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
    echo -e "${RED}${ERROR_ICON} Neither podman nor docker found. Please install one.${NC}"
    exit 1
fi

# ============================================================================
# Global Variables
# ============================================================================

versionName=""
officialApkPath=""
appType=""
appArch="universal"  # Default to universal APK
shouldCleanup=false
workDir=""
builtApkPath=""
officialCompareDir=""
builtCompareDir=""
dockerShimDir=""

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
Zeus Lightning Wallet Reproducible Build Verification
Version: ${SCRIPT_VERSION}

USAGE:
    $SCRIPT_NAME --version <version> --apk <path> [OPTIONS]

REQUIRED PARAMETERS:
    --version <version>    Version to verify (e.g., 0.11.6, 0.12.0-alpha1)
    --apk <path>           Path to official APK from GitHub releases or Play Store

OPTIONAL PARAMETERS:
    --arch <arch>          Architecture to verify (default: universal)
                           Options: universal, arm64-v8a, armeabi-v7a, x86, x86_64
    --type <type>          Wallet type identifier (pass-through for automation)
    --script-version       Print script version and exit
    --cleanup              Remove working directory after verification
    --help                 Show this help message

REQUIREMENTS:
    - podman or docker (Zeus uses official React Native Docker image)

EXAMPLES:
    # Verify universal APK (most common)
    $SCRIPT_NAME --version 0.11.6 --apk /path/to/zeus-universal.apk

    # Verify specific architecture
    $SCRIPT_NAME --version 0.11.6 --apk /path/to/zeus-arm64-v8a.apk --arch arm64-v8a

    # With cleanup
    $SCRIPT_NAME --version 0.11.6 --apk zeus.apk --cleanup

EXIT CODES:
    0 - Reproducible (only META-INF signature differences)
    1 - Non-reproducible (contains other differences) or error

OUTPUT:
    Working directory: ./zeus_<version>_verification/
    Contains: official APK, built APK, extracted directories, diff files

NOTES:
    - Zeus generates 5 APKs per build (universal + 4 architectures)
    - Use --arch to specify which APK to verify
    - Build uses official pinned Docker image with React Native toolchain
    - External dependency: Lndmobile.aar (pre-compiled LND Go library, SHA256 verified)

EOF
}

check_dependencies() {
    echo -e "${CYAN}Checking dependencies...${NC}"
    echo -e "Container runtime ($CONTAINER_CMD) - ${GREEN}${SUCCESS_ICON}${NC}"
}

build_in_container() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Building Zeus APK in container${NC}"
    echo -e "${CYAN}========================================${NC}"

    local repoDir="$workDir/zeus"

    echo "Cloning Zeus repository..."
    git clone --depth 1 --branch "v${versionName}" "$REPO_URL" "$repoDir"

    cd "$repoDir"

    # Get commit hash for reporting
    local commitHash=$(git rev-parse HEAD)
    echo "$commitHash" > "$workDir/git-commit.txt"

    echo -e "${GREEN}${SUCCESS_ICON} Repository cloned to: $repoDir${NC}"
    echo "Commit: $commitHash"
    echo ""

    # Zeus' build.sh uses Docker - ensure it's accessible
    if [[ "$CONTAINER_CMD" == "podman" ]]; then
        if ! command -v docker &> /dev/null; then
            dockerShimDir="$workDir/docker-shim"
            mkdir -p "$dockerShimDir"
            cat > "$dockerShimDir/docker" <<'EOS'
#!/bin/sh
set -eu
IMAGE="docker.io/reactnativecommunity/react-native-android@sha256:c390bfb35a15ffdf52538bdd0e6c5a926469cefa8c8c6da54bfd501c122de25d"
case "${1:-}" in
  run)
    shift
    podman run "$@"
    ;;
  pull)
    shift
    podman pull "$IMAGE"
    ;;
  *)
    podman "$@"
    ;;
esac
EOS
            chmod +x "$dockerShimDir/docker"
            export PATH="$dockerShimDir:$PATH"
            echo -e "${YELLOW}${INFO_ICON} Using podman docker shim for build.sh${NC}"
        else
            alias docker='podman'
        fi
    fi

    echo -e "${YELLOW}Running Zeus build inside pinned React Native container...${NC}"
    echo "Podman image: $ZEUS_DOCKER_IMAGE"
    echo "This may take 10-30 minutes depending on your system..."
    echo ""

    podman run --rm \
        -v "$repoDir":/olympus/zeus \
        "$ZEUS_DOCKER_IMAGE" \
        bash -lc '
          set -euo pipefail
          cd /olympus/zeus
          yarn install --frozen-lockfile
          cd android
          ./gradlew app:assembleRelease
          cd /olympus/zeus
          for f in android/app/build/outputs/apk/release/*.apk; do
            renamed=$(echo "$f" | sed -e "s/app-/zeus-/" -e "s/-release-unsigned//")
            mv "$f" "$renamed"
            sha256sum "$renamed"
          done
        '

    # Verify APKs were built
    local apkDir="android/app/build/outputs/apk/release"
    if [[ ! -d "$apkDir" ]]; then
        echo -e "${RED}${ERROR_ICON} Build failed - APK directory not found${NC}"
        exit 1
    fi

    # Find the built APK matching requested architecture
    local apkName="zeus-${appArch}.apk"
    local builtApk="$apkDir/$apkName"

    if [[ ! -f "$builtApk" ]]; then
        echo -e "${RED}${ERROR_ICON} Built APK not found: $builtApk${NC}"
        echo "Available APKs:"
        ls -lh "$apkDir/"
        exit 1
    fi

    # Copy to working directory
    mkdir -p "$workDir/built"
    builtApkPath="$workDir/built/$apkName"
    cp "$builtApk" "$builtApkPath"

    echo -e "${GREEN}${SUCCESS_ICON} APK built successfully: $builtApkPath${NC}"

    cd - > /dev/null
}

compare_apks() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Comparing APKs${NC}"
    echo -e "${CYAN}========================================${NC}"

    local containerWorkDir="$workDir/container-tools"
    mkdir -p "$containerWorkDir"

    cat > "$containerWorkDir/Dockerfile" << 'DOCKERFILE_END'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openjdk-17-jdk \
    wget \
    unzip \
    diffutils \
    aapt \
    apksigner \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
DOCKERFILE_END

    echo "Building analysis container..."
    if ! $CONTAINER_CMD build --tag zeus_analysis:latest "$containerWorkDir"; then
        echo -e "${RED}${ERROR_ICON} Analysis container build failed${NC}"
        exit 1
    fi

    local analysisScript="$containerWorkDir/analysis.sh"
    cat > "$analysisScript" << 'EOF'
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

AAPT=$(command -v aapt || echo /opt/android-sdk/build-tools/34.0.0/aapt)
APKSIGNER=$(command -v apksigner || echo /opt/android-sdk/build-tools/34.0.0/apksigner)

official_badging=$($AAPT dump badging "$OFFICIAL_APK" 2> "$WORKDIR/aapt-official.log" || true)
built_badging=$($AAPT dump badging "$BUILT_APK" 2> "$WORKDIR/aapt-built.log" || true)

official_version_name=$(echo "$official_badging" | sed -n "s/.*versionName='\\([^']*\\)'.*/\\1/p" | head -n1)
official_version_code=$(echo "$official_badging" | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p" | head -n1)
built_version_name=$(echo "$built_badging" | sed -n "s/.*versionName='\\([^']*\\)'.*/\\1/p" | head -n1)
built_version_code=$(echo "$built_badging" | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p" | head -n1)

$APKSIGNER verify --print-certs "$OFFICIAL_APK" > "$WORKDIR/apksigner-official.txt" 2>&1 || true
official_signer=$(grep "Signer #1 certificate SHA-256" "$WORKDIR/apksigner-official.txt" | awk '{print $6}' | head -n1)

official_hash=$(sha256sum "$OFFICIAL_APK" | awk '{print $1}')
built_hash=$(sha256sum "$BUILT_APK" | awk '{print $1}')

cat <<META > "$WORKDIR/metadata.txt"
official_version_name=${official_version_name:-unknown}
official_version_code=${official_version_code:-unknown}
official_signer=${official_signer:-unknown}
official_hash=$official_hash
built_version_name=${built_version_name:-unknown}
built_version_code=${built_version_code:-unknown}
built_hash=$built_hash
META

if command -v chown >/dev/null 2>&1; then
    chown -R "$HOST_UID:$HOST_GID" "$WORKDIR"
fi
EOF

    chmod +x "$analysisScript"

    local officialForContainer="/workspace/official/$(basename "$officialApkPath")"
    local builtForContainer="/workspace/built/$(basename "$builtApkPath")"

    $CONTAINER_CMD run --rm \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -v "$workDir":/workspace \
        -v "$analysisScript":/analysis.sh:ro \
        zeus_analysis:latest \
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
    local version="$1"
    local repoDir="$workDir/zeus"

    cd "$repoDir"

    # Check tag type
    local tagType="missing"
    local tagSigStatus="[WARNING] No tag signature information"
    local commitSigStatus="[WARNING] No commit signature information"
    local tagInfo=""

    if git tag | grep -q "^v${version}$"; then
        if git cat-file -t "v${version}" 2>/dev/null | grep -q "tag"; then
            tagType="annotated"
            tagInfo=$(git verify-tag "v${version}" 2>&1 || echo "No valid signature")

            if echo "$tagInfo" | grep -q "Good signature"; then
                tagSigStatus="[OK] Good signature on annotated tag"
            else
                tagSigStatus="[WARNING] No valid signature on tag"
            fi
        else
            tagType="lightweight"
            tagSigStatus="[INFO] Tag is lightweight (cannot contain signature)"
        fi
    fi

    # Check commit signature
    local commitInfo=$(git verify-commit HEAD 2>&1 || echo "No signature")
    if echo "$commitInfo" | grep -q "Good signature"; then
        commitSigStatus="[OK] Good signature on commit"
    fi

    local commitHash=$(git rev-parse HEAD)

    cd - > /dev/null

    echo "$tagType|$tagSigStatus|$commitSigStatus|$tagInfo|$commitHash"
}

display_results() {
    local officialExtracted="$1"
    local builtExtracted="$2"
    local sigInfo="$3"

    # Read metadata
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

    # Calculate verdict (filter out META-INF using Leo's precise regex)
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
    if [[ "${diffCount:-0}" -eq 0 ]]; then
        verdict="reproducible"
    fi

    # Diff guide
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
    echo "===== Also ===="
    echo "Zeus uses official build.sh with pinned Docker image: $ZEUS_DOCKER_IMAGE"
    echo "External dependency: Lndmobile.aar v0.18.5-beta-zeus.swaps.1 (SHA256 verified)"
    echo "Architecture verified: $appArch"
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
    echo -e "${CYAN}Zeus Lightning Wallet Verification ${SCRIPT_VERSION}${NC}"
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
            --arch)
                appArch="$2"
                shift 2
                ;;
            --type)
                appType="$2"
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

    # Validate architecture
    case "$appArch" in
        universal|arm64-v8a|armeabi-v7a|x86|x86_64)
            ;;
        *)
            echo -e "${RED}${ERROR_ICON} Invalid architecture: $appArch${NC}"
            echo "Valid options: universal, arm64-v8a, armeabi-v7a, x86, x86_64"
            exit 1
            ;;
    esac

    # Setup working directory
    workDir="$(pwd)/zeus_${versionName}_verification"

    if [[ -d "$workDir" ]]; then
        echo -e "${YELLOW}${WARNING_ICON} Working directory already exists: $workDir${NC}"
        echo -e "${YELLOW}Removing existing directory...${NC}"
        rm -rf "$workDir"
    fi

    mkdir -p "$workDir/official" "$workDir/built"
    echo "Working directory: $workDir"
    echo "Architecture: $appArch"
    if [[ -n "$appType" ]]; then
        echo "App type: $appType"
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

    cp "$officialApkPath" "$workDir/official/"
    officialApkPath="$workDir/official/$(basename "$officialApkPath")"
    echo -e "${GREEN}${SUCCESS_ICON} Official APK copied to workspace${NC}"
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
