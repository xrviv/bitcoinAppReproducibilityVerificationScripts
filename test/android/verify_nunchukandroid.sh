#!/bin/bash
# ==============================================================================
# verify_nunchukandroid.sh - Nunchuk Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.5.5
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-30
# Project:       https://github.com/nunchuk-io/nunchuk-android
# ==============================================================================
# LICENSE: MIT License
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK/AAB comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Reads official Nunchuk Android split APKs from provided directory OR downloads from GitHub
# - Fetches Nunchuk's official reproducible-builds/Dockerfile from GitHub (via curl)
# - Extends Dockerfile with verification tools (bundletool, apktool)
# - Builds container image with Android SDK/NDK + Gradle build system
# - Runs single container that:
#   * Clones source code and checks out exact release tag
#   * Builds AAB using Gradle (reproducible build with disorderfs)
#   * Extracts split APKs from AAB using bundletool
#   * Decodes both official and built APKs using apktool
#   * Compares split-by-split and generates diff reports
# - Reads verification results from container output
# - Displays reproducibility assessment summary
#
# HOST DEPENDENCIES: Only docker or podman required (no Java, unzip, or build tools)

set -euo pipefail

# Error handling
on_error() {
  local exit_code=$?
  local line_no=$1
  echo -e "${RED}${ERROR_ICON} Script failed at line $line_no with exit code $exit_code${NC}"
  echo -e "${RED}Last command: ${BASH_COMMAND}${NC}"

  echo "=== ERROR OCCURRED ==="
  echo "Timestamp: $(date -Iseconds)"

  # Container cleanup
  if [[ -n "${container_name:-}" ]]; then
    echo "Cleaning up container: $container_name"
    $CONTAINER_CMD rm -f "$container_name" 2>/dev/null || true
  fi

  # Workspace preservation
  if [[ -n "${workDir:-}" && -d "$workDir" ]]; then
    echo -e "${YELLOW}Partial workspace available at: $workDir${NC}"
  fi
}
trap 'on_error $LINENO' ERR

# Global Constants
# ================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
shouldCleanup=false
additionalInfo=""

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# Status indicators
SUCCESS_ICON="[OK]"
WARNING_ICON="[WARNING]"
ERROR_ICON="[ERROR]"
INFO_ICON="[INFO]"

# Detect available container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo -e "${RED}Error: Neither podman nor docker found. Please install one of them.${NC}"
    exit 1
fi

# Helper functions
# ===============

# Append message to the "Also" section of the summary
append_additional_info() {
  local message="$1"
  local current="${additionalInfo:-}"
  if [[ -z "$current" ]]; then
    additionalInfo="$message"
  else
    additionalInfo="$current"$'\n'"$message"
  fi
}

# Check available system memory before starting build
check_memory() {
  local available_mem_gb=$(free -g | awk '/^Mem:/ {print $7}')
  local total_mem_gb=$(free -g | awk '/^Mem:/ {print $2}')

  echo "System Memory Status:"
  echo "  Total: ${total_mem_gb}GB"
  echo "  Available: ${available_mem_gb}GB"
  echo ""

  if [[ $available_mem_gb -lt 4 ]]; then
    echo -e "${RED}${WARNING_ICON} Low Available Memory Detected${NC}"
    echo -e "${YELLOW}  Available: ${available_mem_gb}GB (Recommended: 6GB+)${NC}"
    echo -e "${YELLOW}  This build requires significant memory resources.${NC}"
    echo -e "${YELLOW}  System may become unstable or build may fail.${NC}"
    echo ""
    echo -e "${YELLOW}Recommendations:${NC}"
    echo -e "${YELLOW}  - Close unnecessary applications${NC}"
    echo -e "${YELLOW}  - Stop memory-intensive processes${NC}"
    echo -e "${YELLOW}  - Consider upgrading RAM if builds fail frequently${NC}"
    echo ""

    if [[ $total_mem_gb -lt 8 ]]; then
      echo -e "${RED}${WARNING_ICON} Total RAM: ${total_mem_gb}GB (Minimum: 8GB recommended)${NC}"
      echo ""
    fi

    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Build cancelled by user"
      exit 1
    fi
  else
    echo -e "${GREEN}${SUCCESS_ICON} Sufficient memory available for build${NC}"
    echo ""
  fi
}

# Run apktool in container to decode APK
containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")

  # Build command to run inside container
  cmd=$(cat <<EOF
apt-get update && apt-get install -y wget && \
wget https://raw.githubusercontent.com/iBotPeaches/Apktool/v2.10.0/scripts/linux/apktool -O /usr/local/bin/apktool && \
wget https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar -O /usr/local/bin/apktool.jar && \
chmod +x /usr/local/bin/apktool && \
apktool d -f -o "/tfp/$targetFolderBase" "/af/$appFile"
EOF
  )

  # Run apktool in container as root
  $CONTAINER_CMD run \
    --rm \
    --user root \
    --volume "$targetFolderParent":/tfp \
    --volume "$appFolder":/af:ro \
    docker.io/walletscrutiny/android:5 \
    sh -c "$cmd"

  return $?
}

# Extract signer certificate SHA-256 from APK
getSigner() {
  apkFile=$1
  DIR=$(dirname "$apkFile")
  BASE=$(basename "$apkFile")
  s=$(
    $CONTAINER_CMD run \
      --rm \
      --volume "$DIR":/mnt:ro \
      --workdir /mnt \
      docker.io/walletscrutiny/android:5 \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256"  | awk '{print $6}' )
  echo $s
}

usage() {
  cat <<'EOF'
NAME
       verify_nunchukandroid.sh - Nunchuk Android reproducible build verification

SYNOPSIS
       verify_nunchukandroid.sh --version <version> [--apk <path>] [OPTIONS]
       verify_nunchukandroid.sh --script-version | --help

DESCRIPTION
       Performs containerized reproducible AAB build verification for Nunchuk Android.
       Uses Nunchuk's official reproducible-builds/Dockerfile as base.
       Supports both GitHub universal APK and device split APK verification modes.
       Workspace: ./nunchuk_<version>_verification/

OPTIONS
       --script-version        Show script version and exit
       --help                  Show this help and exit

       --version <version>     App version to build (required, e.g., 1.9.47)
       --apk <path>            APK file or directory containing split APKs (optional)
                               If file: Single universal APK
                               If directory: Split APKs (expects base.apk, split_config.*.apk)
                               If omitted: Downloads universal APK from GitHub releases

       --type <type>           App type (optional, e.g., bitcoin, multi)
       --arch <architecture>   Target architecture (optional, e.g., x86_64-linux-gnu)
       --revision <hash>       Override git tag, checkout specific commit (custom flag)
       --cleanup               Remove temporary files after completion
       --preserve              Preserve both official and built split APKs in workspace
                               Creates: workspace/official-splits/ and workspace/built-splits/

REQUIREMENTS
       docker OR podman (required)
       curl (required - for fetching Nunchuk's Dockerfile from GitHub)
       aapt (optional - falls back to container if missing)

       Minimum 12GB RAM (16GB+ recommended for stability)
       - Build requires 10GB for container (Gradle + Kotlin compilation)
       - Additional 2-4GB for system operations
       - Low memory will cause Gradle daemon crashes (OOM)

       Standard tools (typically pre-installed): sha256sum, grep, awk, sed

       Note: APK downloads happen inside container (wget used in container)

EXIT CODES
       0    Verification reproducible
       1    Verification not reproducible or error occurred
       2    Unsupported appId (not io.nunchuk.android)

EXAMPLES
       # Path 1: GitHub universal APK verification (no device needed)
       verify_nunchukandroid.sh --version 1.9.47

       # Path 2: Device split APK verification (requires extracted splits)
       verify_nunchukandroid.sh --version 1.9.47 --apk /var/shared/apk/io.nunchuk.android/1.9.47/
       verify_nunchukandroid.sh --version 1.9.47 --apk ~/nunchuk-splits/ --cleanup

       # Preserve split APKs for further analysis
       verify_nunchukandroid.sh --version 1.9.47 --apk ~/nunchuk-splits/ --preserve

       # Specify app type for automated builds
       verify_nunchukandroid.sh --version 1.9.47 --type bitcoin

For detailed documentation, see: https://walletscrutiny.com

EOF
}

# Read script arguments and flags
# ===============================

apkPath=""
appVersion=""
revisionOverride=""
appType=""
appArch=""
showScriptVersion=false
preserveSplits=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --script-version) showScriptVersion=true ;;
    --version) appVersion="$2"; shift ;;
    --apk) apkPath="$2"; shift ;;
    --type) appType="$2"; shift ;;
    --arch) appArch="$2"; shift ;;
    --revision) revisionOverride="$2"; shift ;;
    --cleanup) shouldCleanup=true ;;
    --preserve) preserveSplits=true ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Show script version and exit if requested
if [ "$showScriptVersion" = true ]; then
  echo "verify_nunchukandroid.sh v0.5.5"
  exit 0
fi

# Validate required arguments
if [[ -z "$appVersion" ]]; then
  echo -e "${RED}Error: App version not specified. Use --version to specify version (e.g., --version 1.9.47).${NC}"
  usage
  exit 1
fi

# Determine verification path based on --apk parameter
verificationMode=""
apkDir=""  # Will store the directory path (either provided or created)

if [[ -z "$apkPath" ]]; then
  # No --apk provided: GitHub mode
  verificationMode="github"
  echo "=== Verification Mode: GitHub Universal APK ==="
  echo "No --apk parameter provided. Container will download universal APK from GitHub releases."
  echo ""

  # Create placeholder directory in execution directory (container will populate it)
  apkDir="./nunchuk_${appVersion}_github_apk"
  mkdir -p "$apkDir"
  apkDir=$(cd "$apkDir" && pwd)  # Get absolute path
else
  # --apk provided: check if it's a file or directory
  # Make path absolute
  if ! [[ $apkPath =~ ^/.* ]]; then
    apkPath="$PWD/$apkPath"
  fi

  if [ -f "$apkPath" ]; then
    # Single APK file provided
    verificationMode="device"
    echo "=== Verification Mode: Single APK File ==="
    echo "Using APK file: $apkPath"

    # Create directory and copy file
    apkDir="./nunchuk_${appVersion}_apk"
    mkdir -p "$apkDir"
    cp "$apkPath" "$apkDir/base.apk"
    apkDir=$(cd "$apkDir" && pwd)  # Get absolute path
    echo ""
  elif [ -d "$apkPath" ]; then
    # Directory with split APKs provided
    verificationMode="device"
    echo "=== Verification Mode: Device Split APKs ==="
    apkDir="$apkPath"

    # Check for base.apk
    if [ ! -f "$apkDir/base.apk" ]; then
      echo -e "${RED}Error: base.apk not found in $apkDir${NC}"
      exit 1
    fi

    echo "Using split APKs from: $apkDir"
    echo ""
  else
    echo -e "${RED}Error: APK path $apkPath not found (not a file or directory)!${NC}"
    exit 1
  fi
fi

echo "=== Nunchuk Android Verification Session Start ==="
echo "Timestamp: $(date -Iseconds)"
echo "APK Source: $verificationMode"
if [[ "$verificationMode" == "device" ]]; then
  echo "APK Directory: $apkDir"
fi
echo "=============================================="

# Extract metadata from APK (device mode only)
# =============================================

if [[ "$verificationMode" == "device" ]]; then
  echo "Extracting metadata from base.apk..."
  tempExtractDir=$(mktemp -d /tmp/extract_base_XXXXXX)
  containerApktool "$tempExtractDir" "$apkDir/base.apk"

  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to extract base.apk${NC}"
    exit 1
  fi

  appId=$(grep 'package=' "$tempExtractDir"/AndroidManifest.xml | sed 's/.*package=\"//g' | sed 's/\".*//g')
  officialVersion=$(grep 'versionName' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")
  versionCode=$(grep 'versionCode' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")

  rm -rf "$tempExtractDir"

  if [ -z "$appId" ]; then
    echo "appId could not be determined from base.apk"
    exit 1
  fi

  if [ -z "$officialVersion" ]; then
    echo "officialVersion could not be determined from base.apk"
    exit 1
  fi

  if [ -z "$versionCode" ]; then
    echo "versionCode could not be determined from base.apk"
    exit 1
  fi

  if [[ "$appId" != "io.nunchuk.android" ]]; then
    echo "Unsupported appId $appId (expected io.nunchuk.android)"
    exit 2
  fi

  echo "App ID: $appId"
  echo "Official APK Version: $officialVersion ($versionCode)"
  echo "Building Version: $appVersion"
  echo ""

  # Version comparison and warning
  if [[ "$appVersion" != "$officialVersion" ]]; then
    echo -e "${YELLOW}${WARNING_ICON} Version Mismatch Detected${NC}"
    echo -e "${YELLOW}  Building: v$appVersion${NC}"
    echo -e "${YELLOW}  Official APK: v$officialVersion${NC}"
    echo -e "${YELLOW}  This may result in expected differences.${NC}"
    echo ""
    append_additional_info "Requested build: v$appVersion. Device APK reports v$officialVersion."
  fi

  echo -e "${CYAN}Now comparing v${appVersion} (to be built) to v${officialVersion} (official APKs)${NC}"
  echo ""

  # Extract signer and hash from APK
  appHash=$(sha256sum "$apkDir/base.apk" | awk '{print $1;}')
  signer=$( getSigner "$apkDir/base.apk" )

  echo "Base APK Hash: $appHash"
  echo "Signer: $signer"
else
  # GitHub mode: metadata will be extracted in container
  echo "GitHub mode: Metadata will be extracted from downloaded APK in container"
  appId="io.nunchuk.android"
  officialVersion="$appVersion"  # Assume versions match
  versionCode="TBD"
  appHash="TBD"
  signer="TBD"
  echo -e "${CYAN}Will compare v${appVersion} (to be built) to v${appVersion} (GitHub APK)${NC}"
  echo ""
fi

# Define workspace (use appVersion from -v flag)
# Use execution directory as workspace (Luis guideline #2: use directory where script is executed)
workDir="./nunchuk_${appVersion}_verification"
container_name="nunchuk_verifier_$$"
additionalInfo=""

echo "Workspace: $workDir"
echo

# Check if workspace already exists
if [[ -d "$workDir" ]]; then
  echo -e "${RED}${ERROR_ICON} Workspace already exists: $workDir${NC}"
  echo
  echo -e "${YELLOW}This workspace may contain artifacts from a previous run.${NC}"
  echo -e "${YELLOW}To proceed, please remove the existing workspace:${NC}"
  echo
  echo -e "${CYAN}  rm -rf $workDir${NC}"
  echo
  echo -e "${YELLOW}Then re-run the script.${NC}"
  exit 1
fi

# Create workspace
mkdir -p "$workDir"
# Convert to absolute path for container mounting
workDir=$(cd "$workDir" && pwd)

echo "Absolute workspace path: $workDir"
echo ""

# Fetch Nunchuk's Dockerfile from GitHub (no git required)
# ===========================================================

echo "Fetching Nunchuk's official Dockerfile from GitHub..."

# Determine git tag to use
gitTag=""
originalDockerfile=""

if [[ -n "$revisionOverride" ]]; then
  gitTag="$revisionOverride"
  echo "Using revision override: $gitTag"

  # Try to fetch Dockerfile
  dockerfileUrl="https://raw.githubusercontent.com/nunchuk-io/nunchuk-android/$gitTag/reproducible-builds/Dockerfile"
  echo "Fetching from: $dockerfileUrl"
  originalDockerfile=$(curl -sS -f "$dockerfileUrl" 2>/dev/null)

  if [[ -z "$originalDockerfile" ]]; then
    echo -e "${RED}Error: Could not fetch Dockerfile for revision $gitTag${NC}"
    echo "URL tried: $dockerfileUrl"
    exit 1
  fi
else
  # Try common tag patterns for Nunchuk
  candidates=("android.${appVersion}" "v${appVersion}" "${appVersion}")

  echo "Trying tag patterns: ${candidates[*]}"

  for candidate in "${candidates[@]}"; do
    dockerfileUrl="https://raw.githubusercontent.com/nunchuk-io/nunchuk-android/$candidate/reproducible-builds/Dockerfile"
    echo -n "  Trying $candidate... "

    originalDockerfile=$(curl -sS -f "$dockerfileUrl" 2>/dev/null)

    if [[ -n "$originalDockerfile" ]]; then
      gitTag="$candidate"
      echo -e "${GREEN}Found!${NC}"
      break
    else
      echo "not found"
    fi
  done

  if [[ -z "$gitTag" ]]; then
    echo -e "${RED}Error: Could not find Dockerfile for version $appVersion${NC}"
    echo -e "${YELLOW}Tried tags: ${candidates[*]}${NC}"
    echo ""
    echo "Use --revision to specify exact commit/tag:"
    echo "  $0 --version $appVersion --revision android.$appVersion"
    exit 1
  fi
fi

echo "Using git tag: $gitTag"
echo "Dockerfile successfully fetched"
echo ""

# Generate device-spec.json (only for device mode)
# =================================================

if [[ "$verificationMode" == "device" ]]; then
  echo "Generating device-spec.json from official APKs..."

  # Determine architectures from base.apk
  if command -v aapt >/dev/null 2>&1; then
    abiOutput=$(aapt dump badging "$apkDir/base.apk" 2>/dev/null | grep "native-code" || true)
  else
    # Use container to run aapt
    apkDirName=$(dirname "$apkDir/base.apk")
    apkBaseName=$(basename "$apkDir/base.apk")
    abiOutput=$($CONTAINER_CMD run --rm --volume "$apkDirName":/apk:ro docker.io/walletscrutiny/android:5 \
      sh -c "aapt dump badging /apk/$apkBaseName" 2>/dev/null | grep "native-code" || true)
  fi

  # Parse ABIs
  supportedAbis='["armeabi-v7a"]'  # Default
  if [[ -n "$abiOutput" ]]; then
    abisRaw=$(echo "$abiOutput" | sed "s/.*native-code: '//g" | sed "s/'.*//g")
    IFS=' ' read -r -a abisArray <<< "$abisRaw"
    jsonAbis="["
    for abi in "${abisArray[@]}"; do
       jsonAbis+="\"$abi\", "
    done
    jsonAbis=$(echo "$jsonAbis" | sed 's/, $//')
    jsonAbis+="]"
    supportedAbis="$jsonAbis"
  fi

  # Determine SDK version from base.apk
  if command -v aapt >/dev/null 2>&1; then
    sdkVersion=$(aapt dump badging "$apkDir/base.apk" 2>/dev/null | grep "sdkVersion" | head -n1 | sed "s/.*sdkVersion:'\([0-9]*\)'.*/\1/" || echo "31")
  else
    sdkVersion=$($CONTAINER_CMD run --rm --volume "$apkDirName":/apk:ro docker.io/walletscrutiny/android:5 \
      sh -c "aapt dump badging /apk/$apkBaseName" 2>/dev/null | grep "sdkVersion" | head -n1 | sed "s/.*sdkVersion:'\([0-9]*\)'.*/\1/" || echo "31")
  fi

  # Set defaults for supportedLocales and screenDensity
  supportedLocales='["en"]'
  screenDensity=320

  echo -e "${GREEN}Generated device-spec.json with these values:${NC}"
  echo "{"
  echo "  \"supportedAbis\": $supportedAbis,"
  echo "  \"supportedLocales\": $supportedLocales,"
  echo "  \"screenDensity\": $screenDensity,"
  echo "  \"sdkVersion\": $sdkVersion"
  echo "}"
  echo

  cat > "$workDir/device-spec.json" <<EOF
{
  "supportedAbis": $supportedAbis,
  "supportedLocales": $supportedLocales,
  "screenDensity": $screenDensity,
  "sdkVersion": $sdkVersion
}
EOF

  if [ ! -s "$workDir/device-spec.json" ]; then
    echo -e "${RED}Error: Failed to create device-spec.json${NC}"
    exit 1
  fi

  echo "device-spec.json saved to: $workDir/device-spec.json"
  echo ""
fi

echo "Verification mode: $verificationMode"
if [[ "$verificationMode" == "device" ]]; then
  echo "Official split APKs will be mounted from: $apkDir"
else
  echo "GitHub APK will be mounted from: $apkDir"
fi
echo "(Extraction and comparison will happen inside container)"
echo ""

# Create extended Dockerfile
# ===========================

echo "Creating extended Dockerfile from Nunchuk's official Dockerfile..."

# Create extended Dockerfile (originalDockerfile already fetched via curl)
cat > "$workDir/Dockerfile" <<DOCKERFILE_EOF
# Extended Nunchuk Android Reproducible Build Dockerfile
# Base: Nunchuk's official reproducible-builds/Dockerfile
# Extensions: WalletScrutiny verification tools (bundletool, apktool)
$originalDockerfile

# WalletScrutiny additions for verification tools
RUN set -ex; \\
    apt-get update; \\
    DEBIAN_FRONTEND=noninteractive apt-get install --yes -o APT::Install-Suggests=false --no-install-recommends \\
        wget \\
        curl \\
        coreutils; \\
    rm -rf /var/lib/apt/lists/*

# Install bundletool for APK extraction
RUN wget -q https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar -O /tmp/bundletool.jar

# Install apktool for APK decoding
RUN wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O /usr/local/bin/apktool && \\
    wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O /usr/local/bin/apktool.jar && \\
    chmod +x /usr/local/bin/apktool

# Set working directory
WORKDIR /workspace
DOCKERFILE_EOF

echo "Extended Dockerfile created at: $workDir/Dockerfile"
echo ""

# Create extraction and comparison script (runs inside container)
# =================================================================

create_extraction_script() {
  cat > "$workDir/extract_and_compare.sh" <<'EXTRACT_EOF'
#!/bin/bash
set -euo pipefail

MODE="$1"
OFFICIAL_DIR="$2"
OUTPUT_DIR="$3"
APP_VERSION="${4:-}"
DEVICE_SPEC="${5:-}"
PRESERVE="${6:-false}"
GIT_TAG="${7:-}"
REPO_URL="https://github.com/nunchuk-io/nunchuk-android"

echo "[Container] Starting extraction and comparison (mode: $MODE)..."
mkdir -p "$OUTPUT_DIR"

# Clone Nunchuk repository and build AAB
echo "[Container] Cloning Nunchuk repository..."
cd /workspace
git clone --quiet "$REPO_URL" nunchuk-source
cd nunchuk-source

echo "[Container] Checking out tag: $GIT_TAG..."
git checkout "$GIT_TAG" --quiet

echo "[Container] Building AAB with disorderfs..."
# Create mount point for disorderfs
mkdir -p /app
disorderfs --sort-dirents=yes --reverse-dirents=no . /app/
cd /app

# Configure Gradle JVM args to prevent daemon crashes
echo "[Container] Configuring Gradle JVM settings..."
echo "org.gradle.jvmargs=-Xmx6g -XX:MaxMetaspaceSize=512m -XX:+HeapDumpOnOutOfMemoryError" >> gradle.properties
echo "org.gradle.daemon=true" >> gradle.properties
echo "org.gradle.parallel=false" >> gradle.properties

# Build AAB using Gradle
echo "[Container] Running Gradle build (this may take 15-30 minutes)..."
./gradlew clean bundleProductionRelease --no-daemon

# Copy AAB to output
cp /app/nunchuk-app/build/outputs/bundle/productionRelease/nunchuk-app-production-release.aab "$OUTPUT_DIR/app-release.aab"
echo "[Container] AAB built: $OUTPUT_DIR/app-release.aab"

# Git verification
echo "[Container] Recording git verification..."
cd /app
echo "===== Git Verification =====" > "$OUTPUT_DIR/git_verification.txt"
echo "Commit: $(git rev-parse HEAD)" >> "$OUTPUT_DIR/git_verification.txt"
echo "" >> "$OUTPUT_DIR/git_verification.txt"

if git describe --exact-match --tags HEAD >/dev/null 2>&1; then
  TAG=$(git describe --exact-match --tags HEAD)
  echo "Tag: $TAG" >> "$OUTPUT_DIR/git_verification.txt"
  
  if [ "$(git cat-file -t refs/tags/$TAG)" = "tag" ]; then
    echo "Tag type: annotated" >> "$OUTPUT_DIR/git_verification.txt"
    echo "" >> "$OUTPUT_DIR/git_verification.txt"
    git tag -v "$TAG" >> "$OUTPUT_DIR/git_verification.txt" 2>&1 || echo "[INFO] Tag signature check failed or not signed" >> "$OUTPUT_DIR/git_verification.txt"
  else
    echo "Tag type: lightweight (no signature possible)" >> "$OUTPUT_DIR/git_verification.txt"
  fi
else
  echo "Tag: (none)" >> "$OUTPUT_DIR/git_verification.txt"
fi

echo "" >> "$OUTPUT_DIR/git_verification.txt"
echo "Commit signature:" >> "$OUTPUT_DIR/git_verification.txt"
git verify-commit HEAD >> "$OUTPUT_DIR/git_verification.txt" 2>&1 || echo "[INFO] Commit signature check failed or not signed" >> "$OUTPUT_DIR/git_verification.txt"

if [[ "$MODE" == "github" ]]; then
  # Path 1: GitHub universal APK comparison
  echo "[Container] Downloading APK from GitHub releases..."
  
  releaseJson=$(curl -sL "https://api.github.com/repos/nunchuk-io/nunchuk-android/releases/tags/$GIT_TAG")
  apkUrl=$(echo "$releaseJson" | grep -o "https://github.com/nunchuk-io/nunchuk-android/releases/download/$GIT_TAG/[^\"]*\\.apk" | head -n1)
  
  if [[ -z "$apkUrl" ]]; then
    echo "[Container ERROR] Could not find APK in GitHub releases for $GIT_TAG"
    echo "[Container ERROR] Check https://github.com/nunchuk-io/nunchuk-android/releases/tag/$GIT_TAG"
    exit 1
  fi
  
  echo "[Container] Downloading: $apkUrl"
  wget -q "$apkUrl" -O "$OFFICIAL_DIR/github.apk"
  
  if [ ! -f "$OFFICIAL_DIR/github.apk" ]; then
    echo "[Container ERROR] Failed to download APK from GitHub"
    exit 1
  fi
  
  echo "[Container] Downloaded GitHub APK: ${OFFICIAL_DIR}/github.apk"
  
  echo "[Container] Extracting universal APK from AAB..."
  java -jar /tmp/bundletool.jar build-apks \
    --bundle="$OUTPUT_DIR/app-release.aab" \
    --output=/tmp/built-universal.apks \
    --mode=universal
  
  echo "[Container] Unzipping universal APK..."
  mkdir -p /tmp/built-decoded /tmp/official-decoded
  unzip -qq /tmp/built-universal.apks 'universal.apk' -d /tmp/
  
  echo "[Container] Decoding built universal APK..."
  apktool d -f -o /tmp/built-decoded /tmp/universal.apk 2>/dev/null || true
  
  echo "[Container] Decoding official GitHub APK..."
  apktool d -f -o /tmp/official-decoded "$OFFICIAL_DIR/github.apk" 2>/dev/null || true
  
  echo "[Container] Comparing universal APKs..."
  diff_output=$(diff -r /tmp/official-decoded /tmp/built-decoded 2>/dev/null || true)

  if [[ -n "$diff_output" ]]; then
    echo "$diff_output" > "$OUTPUT_DIR/diff_universal.txt"

    # Count non-META-INF diffs using Leo's stricter filtering (2025-10-30)
    # Get brief file list for accurate counting
    diff_brief=$(diff -qr /tmp/official-decoded /tmp/built-decoded 2>/dev/null || true)
    # Filter out ONLY root-level META-INF using Leo's precise regex
    filtered=$(echo "$diff_brief" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)
    non_meta=$(echo "$filtered" | grep -c '^' || echo "0")

    echo "    Differences: $non_meta (non-META-INF)"
  else
    touch "$OUTPUT_DIR/diff_universal.txt"
    echo "    No differences found"
    non_meta=0
  fi
  
  echo "$non_meta" > "$OUTPUT_DIR/total_diffs.txt"
  echo "[Container] Total non-META-INF differences: $non_meta"
  
  if [[ "$PRESERVE" == "true" ]]; then
    echo "[Container] Preserving universal APKs to workspace..."
    mkdir -p "$OUTPUT_DIR/official-apk"
    mkdir -p "$OUTPUT_DIR/built-apk"
    
    echo "  Copying official universal APK..."
    cp "$OFFICIAL_DIR/github.apk" "$OUTPUT_DIR/official-apk/" 2>/dev/null || true
    cp /tmp/universal.apk "$OUTPUT_DIR/built-apk/universal.apk" 2>/dev/null || true
    
    echo "[Container] Universal APKs preserved:"
    echo "  Official: $OUTPUT_DIR/official-apk/"
    echo "  Built: $OUTPUT_DIR/built-apk/"
  fi

else
  # Path 2: Device split APK comparison
  echo "[Container] Extracting split APKs from AAB using bundletool..."
  java -jar /tmp/bundletool.jar build-apks \
    --bundle="$OUTPUT_DIR/app-release.aab" \
    --output=/tmp/built-split-apks.apks \
    --device-spec="$DEVICE_SPEC" \
    --mode=default
  
  echo "[Container] Unzipping split APKs..."
  mkdir -p /tmp/built-raw /tmp/built-decoded /tmp/official-decoded
  unzip -qq /tmp/built-split-apks.apks -d /tmp/built-raw/
  
  echo "[Container] Decoding built split APKs..."
  for apk in /tmp/built-raw/splits/*.apk; do
    [ -e "$apk" ] || continue
    name=$(basename "$apk" .apk)
    if [[ "$name" == "base-master" ]]; then
      normalized="base"
    else
      normalized=$(echo "$name" | sed 's/^base-//')
    fi
    echo "  Decoding: $name -> $normalized"
    apktool d -f -o "/tmp/built-decoded/$normalized" "$apk" 2>/dev/null || true
  done
  
  echo "[Container] Decoding official split APKs..."
  for apk in "$OFFICIAL_DIR"/*.apk; do
    [ -e "$apk" ] || continue
    name=$(basename "$apk" .apk)
    if [[ "$name" == "base" ]]; then
      normalized="base"
    else
      normalized=$(echo "$name" | sed 's/^split_config\.//')
    fi
    echo "  Decoding: $name -> $normalized"
    apktool d -f -o "/tmp/official-decoded/$normalized" "$apk" 2>/dev/null || true
  done
  
  echo "[Container] Comparing split APKs..."
  total_diffs=0
  
  for official in /tmp/official-decoded/*; do
    [ -d "$official" ] || continue
    split_name=$(basename "$official")
    built="/tmp/built-decoded/$split_name"
    if [[ ! -d "$built" ]]; then
      echo "  [WARNING] Split $split_name exists in official but not in built"
      echo "missing_in_built" > "$OUTPUT_DIR/diff_$split_name.txt"
      continue
    fi
    echo "  Comparing split: $split_name..."
    diff_output=$(diff -r "$official" "$built" 2>/dev/null || true)
    if [[ -n "$diff_output" ]]; then
      echo "$diff_output" > "$OUTPUT_DIR/diff_$split_name.txt"

      # Count non-META-INF diffs using Leo's stricter filtering (2025-10-30)
      # Get brief file list for accurate counting
      diff_brief=$(diff -qr "$official" "$built" 2>/dev/null || true)
      # Filter out ONLY root-level META-INF using Leo's precise regex
      filtered=$(echo "$diff_brief" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)
      non_meta=$(echo "$filtered" | grep -c '^' || echo "0")

      total_diffs=$((total_diffs + non_meta))
      echo "    Differences: $non_meta (non-META-INF)"
    else
      touch "$OUTPUT_DIR/diff_$split_name.txt"
      echo "    No differences found"
    fi
  done
  
  for built in /tmp/built-decoded/*; do
    [ -d "$built" ] || continue
    split_name=$(basename "$built")
    official="/tmp/official-decoded/$split_name"
    if [[ ! -d "$official" ]]; then
      echo "  [WARNING] Split $split_name exists in built but not in official"
      echo "extra_in_built" > "$OUTPUT_DIR/diff_extra_$split_name.txt"
    fi
  done
  
  echo "$total_diffs" > "$OUTPUT_DIR/total_diffs.txt"
  echo "[Container] Total non-META-INF differences: $total_diffs"
  
  if [[ "$PRESERVE" == "true" ]]; then
    echo "[Container] Preserving split APKs to workspace..."
    mkdir -p "$OUTPUT_DIR/official-splits"
    mkdir -p "$OUTPUT_DIR/built-splits"
    
    echo "  Copying official split APKs..."
    cp "$OFFICIAL_DIR"/*.apk "$OUTPUT_DIR/official-splits/" 2>/dev/null || true
    
    echo "  Copying built split APKs..."
    cp /tmp/built-raw/splits/*.apk "$OUTPUT_DIR/built-splits/" 2>/dev/null || true
    
    echo "[Container] Split APKs preserved:"
    echo "  Official: $OUTPUT_DIR/official-splits/"
    echo "  Built: $OUTPUT_DIR/built-splits/"
  fi
fi

echo "[Container] Comparison complete"
exit 0
EXTRACT_EOF

  chmod +x "$workDir/extract_and_compare.sh"
  echo "Extraction script created at: $workDir/extract_and_compare.sh"
}

# Build and verify in single container
# ====================================

build_and_verify() {
  echo "Building and verifying in container..."
  echo "This may take 30-60 minutes depending on system resources..."
  echo ""

  # Check system memory before starting resource-intensive build
  check_memory

  # Create extraction script
  create_extraction_script

  cd "$workDir"

  # Build container image
  echo "Building container image from Nunchuk's Dockerfile..."
  $CONTAINER_CMD build --memory=6g --no-cache --ulimit nofile=65536:65536 -t nunchuk-verifier:${appVersion} -f Dockerfile .

  if [ $? -ne 0 ]; then
    echo -e "${RED}Container build failed${NC}"
    exit 1
  fi

  echo ""
  echo "Container image built successfully"
  echo ""

  # Run container with all verification steps
  echo "Running verification inside container..."

  if [[ "$verificationMode" == "github" ]]; then
    # GitHub mode: container downloads APK
    $CONTAINER_CMD run --rm \
      --name "$container_name" \
      --privileged \
      --memory=10g \
      --volume "$workDir":/workspace:rw \
      --volume "$workDir/extract_and_compare.sh":/extract_and_compare.sh:ro \
      --volume "$apkDir":/official-apks:rw \
      nunchuk-verifier:${appVersion} \
      bash -c "
        /extract_and_compare.sh \
          github \
          /official-apks \
          /workspace/results \
          $appVersion \
          '' \
          $preserveSplits \
          $gitTag
      "
  else
    # Device mode: needs device-spec.json
    $CONTAINER_CMD run --rm \
      --name "$container_name" \
      --privileged \
      --memory=10g \
      --volume "$workDir":/workspace:rw \
      --volume "$workDir/extract_and_compare.sh":/extract_and_compare.sh:ro \
      --volume "$apkDir":/official-apks:ro \
      nunchuk-verifier:${appVersion} \
      bash -c "
        /extract_and_compare.sh \
          device \
          /official-apks \
          /workspace/results \
          '' \
          /workspace/device-spec.json \
          $preserveSplits \
          $gitTag
      "
  fi

  if [ $? -ne 0 ]; then
    echo -e "${RED}Verification failed${NC}"
    exit 1
  fi

  # Read results
  total_non_meta_diffs=$(cat "$workDir/results/total_diffs.txt" 2>/dev/null || echo "0")
  
  echo ""
  echo "Verification complete"
  echo "AAB artifact: $workDir/results/app-release.aab"
  echo "Diff files: $workDir/results/diff_*.txt"
  echo ""

  cd "$workDir"
}

finalize_github_metadata() {
  echo ""
  echo "Extracting metadata from downloaded GitHub APK..."
  local githubApk="$apkDir/github.apk"

  if [[ ! -f "$githubApk" ]]; then
    echo -e "${RED}Error: Expected GitHub APK at $githubApk but it was not found.${NC}"
    exit 1
  fi

  appHash=$(sha256sum "$githubApk" | awk '{print $1;}')
  signer=$(getSigner "$githubApk")

  local tempExtractDir
  tempExtractDir=$(mktemp -d /tmp/github_meta_XXXXXX)

  if ! containerApktool "$tempExtractDir" "$githubApk"; then
    echo -e "${RED}Error: Failed to decode GitHub APK for metadata extraction.${NC}"
    rm -rf "$tempExtractDir"
    exit 1
  fi

  if [[ -f "$tempExtractDir/apktool.yml" ]]; then
    officialVersion=$(grep 'versionName' "$tempExtractDir/apktool.yml" | awk '{print $2}' | tr -d "'" | head -n1)
    versionCode=$(grep 'versionCode' "$tempExtractDir/apktool.yml" | awk '{print $2}' | tr -d "'" | head -n1)
  fi

  if [[ -f "$tempExtractDir/AndroidManifest.xml" ]]; then
    appId=$(grep 'package=' "$tempExtractDir/AndroidManifest.xml" | sed 's/.*package="//; s/".*//')
  fi

  rm -rf "$tempExtractDir"

  if [[ -z "$officialVersion" ]]; then
    officialVersion="$appVersion"
  fi

  if [[ -z "$versionCode" ]]; then
    versionCode="unknown"
  fi

  if [[ "$appVersion" != "$officialVersion" ]]; then
    append_additional_info "Requested build: v$appVersion. GitHub APK reports v$officialVersion."
  fi

  echo "Metadata extraction complete."
  echo ""
}

# Generate verification summary
# ==============================

result() {
  echo "Generating verification summary..."
  echo ""
  
  # Read commit hash from git verification file
  local commit=""
  if [ -f "$workDir/results/git_verification.txt" ]; then
    commit=$(grep "^Commit:" "$workDir/results/git_verification.txt" | awk '{print $2}')
  fi

  # Read aggregated diffs from results directory
  local diff_output=""
  local split_mismatch=false

  shopt -s nullglob
  for diff_file in "$workDir/results"/diff_*.txt "$workDir/results"/diff_extra_*.txt; do
    [ -f "$diff_file" ] || continue
    local base split_name line_count first_line
    base=$(basename "$diff_file")
    if [[ "$base" == diff_extra_* ]]; then
      split_name=${base#diff_extra_}
    else
      split_name=${base#diff_}
    fi
    split_name=${split_name%.txt}

    # Check for special marker files
    first_line=$(head -1 "$diff_file" 2>/dev/null)

    if [[ "$first_line" == "missing_in_built" ]]; then
      split_mismatch=true
      diff_output+="Split ${split_name} exists only in the official APK set."$'\n'
      continue
    fi

    if [[ "$first_line" == "extra_in_built" ]]; then
      split_mismatch=true
      diff_output+="Split ${split_name} exists only in the rebuilt APK set."$'\n'
      continue
    fi

    # Check if file is non-empty
    if [[ -s "$diff_file" ]]; then
      # Add split label for device mode
      if [[ "$verificationMode" == "device" ]]; then
        diff_output+="=== Split: ${split_name} ==="$'\n'
      fi

      # Count lines efficiently
      line_count=$(wc -l < "$diff_file")

      # If diff has more than 3 lines, truncate
      if [[ $line_count -gt 3 ]]; then
        diff_output+=$(head -3 "$diff_file")$'\n'
        diff_output+="... (${line_count} total lines)"$'\n'
        diff_output+="Full diff saved to: $workDir/results/${base}"$'\n'
      else
        diff_output+=$(cat "$diff_file")$'\n'
      fi
    fi
  done
  shopt -u nullglob

  # Set verdict
  verdict=""
  if [[ $total_non_meta_diffs -eq 0 && "$split_mismatch" == false ]]; then
    verdict="reproducible"
  else
    verdict="differences found"
  fi

  local preservedApksInfo=""
  if [[ "$preserveSplits" == true ]]; then
    if [[ "$verificationMode" == "device" ]]; then
      preservedApksInfo="
Preserved split APKs:
  Official: $workDir/results/official-splits/
  Built:    $workDir/results/built-splits/
"
    else
      preservedApksInfo="
Preserved universal APKs:
  Official: $workDir/results/official-apk/
  Built:    $workDir/results/built-apk/
"
    fi
  fi

  local diffGuide="
Detailed diff files available at:
$workDir/results/
${preservedApksInfo}
To investigate further, you can re-run the container:
podman run -it --rm \\
  --volume $workDir:/workspace:rw \\
  --volume $apkDir:/official-apks:ro \\
  nunchuk-verifier:${appVersion} \\
  bash

for more details."

  if [[ "$shouldCleanup" == true ]]; then
    diffGuide=''
  fi

  local infoBlock=""
  if [[ -n "${additionalInfo:-}" ]]; then
    infoBlock="===== Also =====\n${additionalInfo}\n"
  fi

  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $officialVersion"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "commit:         $commit"
  echo
  echo "Diff:"
  printf '%s\n' "$diff_output"
  echo
  echo "Revision, tag (and its signature):"

  if [ -f "$workDir/results/git_verification.txt" ]; then
    cat "$workDir/results/git_verification.txt"
  else
    echo "[WARNING] git_verification.txt not found"
  fi

  echo -e "\n${infoBlock}===== End Results ====="
  echo "$diffGuide"
}

# Cleanup
# =======

cleanup() {
  if [[ "$shouldCleanup" == "true" ]]; then
    echo "Cleaning up workspace..."
    rm -rf "$workDir"
    echo "Cleanup complete"
  else
    echo "Workspace preserved: $workDir"
  fi
}

# Main execution
# ==============

echo "=== Starting Verification Process ==="
build_and_verify
if [[ "$verificationMode" == "github" ]]; then
  finalize_github_metadata
fi
result
echo "=== Verification Complete ==="
echo "Session End: $(date -Iseconds)"

# Determine exit code based on verdict
if [[ "$verdict" == "reproducible" ]]; then
  exitCode=0
else
  exitCode=1
fi

cleanup
echo "Exit code: $exitCode"
exit $exitCode
