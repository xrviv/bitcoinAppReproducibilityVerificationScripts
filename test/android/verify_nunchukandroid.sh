#!/bin/bash
# ==============================================================================
# verify_nunchukandroid.sh - Nunchuk Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.0
# Author:        Daniel Garcia (dannybuntu)
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-17 (Philippine Time)
# Project:       https://github.com/nunchuk-io/nunchuk-android
# ==============================================================================
# LICENSE: MIT License
#
# Changes in v0.2.0:
# - Integrated APK extraction from Android device (from apkextractor_sync.sh)
# - Changed -d flag to -a (accepts appId or directory)
# - Added --extract-only mode for APK extraction without verification
# - Fixed git tag format (removed .0 stripping, now uses full version)
# - Added detailed device connection error messages
# - Added adb dependency check for device extraction
#
# Changes in v0.1.0:
# - Initial standalone script combining testAAB.sh, io.nunchuk.android.sh, and Dockerfile
# - Embedded Dockerfile for reproducible build environment
# - Automatic device-spec.json generation from official APKs
# - Complete AAB build and split APK generation workflow
# - Hash comparison and diff analysis
# - Follows Luis script guidelines and standalone script guidelines
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK/AAB comparisons - review all operations before execution.
# This script may require access to connected Android devices for APK extraction.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Extracts metadata from official Nunchuk split APKs
# - Generates device-spec.json for bundletool based on official APK characteristics
# - Clones Nunchuk source repository and checks out the correct release tag
# - Builds Docker container with Android SDK and NDK for reproducible builds
# - Performs containerized AAB build using disorderfs for filesystem ordering
# - Converts AAB to split APKs using bundletool with matching device configuration
# - Compares official vs built APKs using hash comparison and binary diff analysis
# - Generates detailed reproducibility assessment with diffoscope analysis
# ==============================================================================

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo ""
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Running this script grants it access to your"
echo "connected Android device and may modify system files."
echo "Use at your own risk and ensure you understand what the script does before"
echo "execution."
echo ""
echo "=============================================================================="
echo -e "\033[0m"
sleep 3

# Global Variables
SCRIPT_VERSION="v0.2.0"
BUNDLETOOL_VERSION="1.18.0"
wsContainer="docker.io/walletscrutiny/android:5"

# Color Constants
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD_CYAN='\033[1;36m'
BRIGHT_GREEN='\033[1;32m'
NC='\033[0m'

# Usage function
usage() {
    cat << 'USAGE_EOF'
Usage: verify_nunchukandroid.sh -a <appId_or_directory> [-v <version>] [-t <tag>] [OPTIONS]

Required:
  -a, --apk-source PATH   Either:
                          - AppId to extract from connected Android device (e.g., io.nunchuk.android)
                          - Directory containing official split APKs (must have base.apk)

Optional:
  -v, --version VERSION   Override versionName detection (e.g., 1.9.64)
  -t, --tag TAG          Override git tag/branch (e.g., android.1.9.64)
  -c, --cleanup          Remove artifacts after successful verification
  --work-dir PATH        Custom working directory (default: /tmp/test_<appId>_<version>)
  --verbose              Enable verbose output
  --extract-only         Extract APKs from device and exit (no verification)
  -h, --help             Show this help message

Examples:
  # Extract from device and verify
  verify_nunchukandroid.sh -a io.nunchuk.android

  # Verify from existing directory
  verify_nunchukandroid.sh -a /var/shared/apk/io.nunchuk.android/1.9.64/

  # Extract only (no verification)
  verify_nunchukandroid.sh -a io.nunchuk.android --extract-only

  # With options
  verify_nunchukandroid.sh -a ./official-apks/ -v 1.9.64 -t android.1.9.64 --cleanup

Exit Codes:
  0 - Verification completed (reproducible)
  1 - Verification completed (not reproducible) or fatal error

Requirements:
  - podman, git, aapt, unzip, curl, sha256sum
  - adb (if extracting from device)
  - diffoscope (optional)

USAGE_EOF
    exit 0
}

# Parse arguments
apkSource=""
versionOverride=""
tagOverride=""
shouldCleanup=false
workDirOverride=""
verbose=false
extractOnly=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--apk-source) apkSource="$2"; shift ;;
        -v|--version) versionOverride="$2"; shift ;;
        -t|--tag) tagOverride="$2"; shift ;;
        -c|--cleanup) shouldCleanup=true ;;
        --work-dir) workDirOverride="$2"; shift ;;
        --verbose) verbose=true ;;
        --extract-only) extractOnly=true ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
    shift
done

# Validate required arguments
if [ -z "$apkSource" ]; then
    echo -e "${RED}Error: APK source not specified!${NC}"
    usage
fi

# Helper functions for APK extraction
is_app_installed() {
    local package_name="$1"
    if adb shell pm list packages 2>/dev/null | grep -q "^package:$package_name$"; then
        return 0
    else
        return 1
    fi
}

get_version_code_from_apk() {
    local apk_path="$1"
    aapt dump badging "$apk_path" | grep versionCode | awk '{print $3}' | sed "s/versionCode='//" | sed "s/'//"
}

get_version_name_from_apk() {
    local apk_path="$1"
    aapt dump badging "$apk_path" | grep versionName | awk '{print $4}' | sed "s/versionName='//" | sed "s/'//"
}

extract_apks_from_device() {
    local bundleId="$1"
    local outputDir="$2"
    
    echo -e "${CYAN}Extracting APKs from connected Android device...${NC}"
    
    # Check if adb is available
    if ! command -v adb &> /dev/null; then
        echo -e "${RED}Error: adb not found. Please install Android Debug Bridge.${NC}"
        exit 1
    fi
    
    # Check if device is connected
    local connected_devices=$(adb devices | grep -w "device")
    if [ -z "$connected_devices" ]; then
        echo -e "${RED}Error: No Android device connected.${NC}"
        echo ""
        echo "Please ensure:"
        echo "  1. Device is connected via USB"
        echo "  2. Developer options are enabled on your device"
        echo "     (Settings → About phone → Tap 'Build number' 7 times)"
        echo "  3. USB debugging is enabled"
        echo "     (Settings → Developer options → USB debugging)"
        echo "  4. Check your device screen for USB debugging authorization prompt"
        echo ""
        exit 1
    fi
    
    echo -e "${GREEN}Device connected:${NC}"
    echo "  Model: $(adb shell getprop ro.product.model | tr -d '\r')"
    echo "  Manufacturer: $(adb shell getprop ro.product.manufacturer | tr -d '\r')"
    echo "  Android Version: $(adb shell getprop ro.build.version.release | tr -d '\r')"
    
    # Check if app is installed
    if ! is_app_installed "$bundleId"; then
        echo -e "${RED}Error: App '$bundleId' is not installed on the device.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}App found on device: $bundleId${NC}"
    
    # Get APK paths
    local apks=$(adb shell pm path "$bundleId")
    
    # Determine if split APKs
    if echo "$apks" | grep -qE "split_|config."; then
        echo -e "${YELLOW}App uses split APKs${NC}"
    else
        echo -e "${YELLOW}App uses single APK${NC}"
    fi
    
    # Create output directory
    mkdir -p "$outputDir"
    
    # Pull APKs
    echo -e "${CYAN}Pulling APKs from device...${NC}"
    for apk in $apks; do
        apkPath=$(echo $apk | awk '{print $NF}' FS=':' | tr -d '\r\n')
        apkName=$(basename "$apkPath")
        echo "  Pulling $apkName"
        adb pull "$apkPath" "$outputDir/$apkName" > /dev/null 2>&1
    done
    
    echo -e "${GREEN}APKs extracted to: $outputDir${NC}"
    
    # List extracted files
    echo -e "${CYAN}Extracted files:${NC}"
    ls -lh "$outputDir"/*.apk | awk '{print "  " $9 " (" $5 ")"}'
}

# Check dependencies
echo -e "${CYAN}Checking dependencies...${NC}"
missing_deps=()
for cmd in podman git aapt unzip curl sha256sum; do
    if ! command -v $cmd &> /dev/null; then
        missing_deps+=("$cmd")
    fi
done

if [ ${#missing_deps[@]} -ne 0 ]; then
    echo -e "${RED}Error: Missing required dependencies: ${missing_deps[*]}${NC}"
    exit 1
fi

# Helper Functions
log() {
    if [ "$verbose" = true ]; then
        echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    fi
}

containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")

  # Build the command to run inside the container
  cmd=$(cat <<EOF
apt-get update && apt-get install -y wget && \
wget https://raw.githubusercontent.com/iBotPeaches/Apktool/v2.10.0/scripts/linux/apktool -O /usr/local/bin/apktool && \
wget https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar -O /usr/local/bin/apktool.jar && \
chmod +x /usr/local/bin/apktool && \
apktool d -f -o "/tfp/$targetFolderBase" "/af/$appFile"
EOF
  )

  # Run apktool in a container as root
  podman run \
    --rm \
    --user root \
    --volume "$targetFolderParent":/tfp \
    --volume "$appFolder":/af:ro \
    "$wsContainer" \
    sh -c "$cmd"

  return $?
}

getSigner() {
  apkFile=$1
  DIR=$(dirname "$apkFile")
  BASE=$(basename "$apkFile")
  s=$(
    podman run \
      --rm \
      --volume "$DIR":/mnt:ro \
      --workdir /mnt \
      $wsContainer \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256"  | awk '{print $6}' )
  echo $s
}

list_apk_hashes() {
  local dir="$1"
  local title="$2"
  echo -e "${BOLD_CYAN}========================================${NC}"
  echo -e "${BOLD_CYAN}**$title**${NC}"
  for apk_file in "$dir"/*.apk; do
    [ -e "$apk_file" ] || continue
    apk_hash=$(sha256sum "$apk_file" | awk '{print $1}')
    echo "$apk_hash $(basename "$apk_file")"
  done
  echo -e "${BOLD_CYAN}========================================${NC}"
}

# Main Process
echo -e "${BRIGHT_GREEN}========================================${NC}"
echo -e "${BRIGHT_GREEN}Nunchuk Android Verification Script${NC}"
echo -e "${BRIGHT_GREEN}Version: $SCRIPT_VERSION${NC}"
echo -e "${BRIGHT_GREEN}========================================${NC}"

# Determine if apkSource is a directory or an appId
apkDir=""
if [ -d "$apkSource" ]; then
    # It's a directory
    apkDir="$apkSource"
    echo -e "${CYAN}Using APKs from directory: $apkDir${NC}"
    
    # Validate base.apk exists
    baseApk="$apkDir/base.apk"
    if [ ! -f "$baseApk" ]; then
        echo -e "${RED}Error: base.apk not found in $apkDir!${NC}"
        exit 2
    fi
else
    # It's an appId - extract from device
    bundleId="$apkSource"
    echo -e "${CYAN}Extracting APKs from device for: $bundleId${NC}"
    
    # Create temporary directory for extracted APKs
    extractedApkDir="/tmp/extracted_apks_${bundleId}_$$"
    extract_apks_from_device "$bundleId" "$extractedApkDir"
    
    apkDir="$extractedApkDir"
    baseApk="$apkDir/base.apk"
    
    if [ ! -f "$baseApk" ]; then
        echo -e "${RED}Error: base.apk not found after extraction!${NC}"
        rm -rf "$extractedApkDir"
        exit 2
    fi
    
    # If extract-only mode, show summary and exit
    if [ "$extractOnly" = true ]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}APK Extraction Complete${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo -e "${CYAN}Location:${NC} $extractedApkDir"
        echo ""
        echo -e "${CYAN}APK Hashes:${NC}"
        for apk in "$extractedApkDir"/*.apk; do
            hash=$(sha256sum "$apk" | awk '{print $1}')
            echo "  $hash $(basename "$apk")"
        done
        echo ""
        echo -e "${YELLOW}Note: Files will remain in $extractedApkDir${NC}"
        echo -e "${YELLOW}To verify, run: $0 -a $extractedApkDir${NC}"
        exit 0
    fi
fi

# Step 1: Extract metadata from base.apk
echo -e "\n${CYAN}Step 1: Extracting metadata from base.apk...${NC}"
tempExtractDir=$(mktemp -d /tmp/extract_base_XXXXXX)

if command -v apktool &> /dev/null; then
    apktool d -f -o "$tempExtractDir" "$baseApk" > /dev/null 2>&1
else
    containerApktool "$tempExtractDir" "$baseApk"
fi

appId=$(grep 'package=' "$tempExtractDir"/AndroidManifest.xml | sed 's/.*package=\"//g' | sed 's/\".*//g')
versionName=$(grep 'versionName' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")
versionCode=$(grep 'versionCode' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")

if [ -n "$versionOverride" ]; then
    versionName="$versionOverride"
    echo -e "${YELLOW}Version override applied: $versionName${NC}"
fi

if [ -z "$appId" ] || [ -z "$versionName" ] || [ -z "$versionCode" ]; then
    echo -e "${RED}Error: Could not extract metadata from base.apk${NC}"
    rm -rf "$tempExtractDir"
    exit 1
fi

echo -e "${GREEN}Extracted metadata:${NC}"
echo "  appId: $appId"
echo "  versionName: $versionName"
echo "  versionCode: $versionCode"

# Define working directory
if [ -n "$workDirOverride" ]; then
    workDir="$workDirOverride"
else
    workDir="/tmp/test_${appId}_${versionName}"
fi

echo -e "${CYAN}Working directory: $workDir${NC}"
mkdir -p "$workDir"

mkdir -p "$workDir/fromPlay-decoded/base"
mv "$tempExtractDir"/* "$workDir/fromPlay-decoded/base/"
rm -rf "$tempExtractDir"

# Step 2: Generate device-spec.json
echo -e "\n${CYAN}Step 2: Generating device-spec.json...${NC}"

supportedAbis=$(aapt dump badging "$baseApk" 2>/dev/null | grep "native-code" | sed 's/.*native-code: //g' | sed 's/\"//g')
if [ -z "$supportedAbis" ]; then
    supportedAbis='["armeabi-v7a"]'
else
    IFS=', ' read -r -a abisArray <<< "$supportedAbis"
    jsonAbis="["
    for abi in "${abisArray[@]}"; do
        jsonAbis+="\"$abi\", "
    done
    jsonAbis=$(echo "$jsonAbis" | sed 's/, $//')
    jsonAbis+="]"
    supportedAbis="$jsonAbis"
fi

sdkVersion=$(aapt dump badging "$baseApk" 2>/dev/null | grep "sdkVersion" | head -n1 | sed "s/.*sdkVersion:'\([0-9]*\)'.*/\1/")
if [ -z "$sdkVersion" ]; then
    sdkVersion=31
fi

supportedLocales='["en"]'
screenDensity=280

echo -e "${GREEN}Device spec configuration:${NC}"
echo "  supportedAbis: $supportedAbis"
echo "  supportedLocales: $supportedLocales"
echo "  screenDensity: $screenDensity"
echo "  sdkVersion: $sdkVersion"

deviceSpec="$workDir/device-spec.json"
cat > "$deviceSpec" <<DEVICE_SPEC_EOF
{
  "supportedAbis": $supportedAbis,
  "supportedLocales": $supportedLocales,
  "screenDensity": $screenDensity,
  "sdkVersion": $sdkVersion
}
DEVICE_SPEC_EOF

if [ ! -s "$deviceSpec" ]; then
    echo -e "${RED}Error: Failed to create device-spec.json${NC}"
    exit 1
fi

echo -e "${GREEN}Device spec created at: $deviceSpec${NC}"

# Step 3: Process official APKs
echo -e "\n${CYAN}Step 3: Processing official APKs...${NC}"
list_apk_hashes "$apkDir" "Official APKs"

mkdir -p "$workDir/fromPlay-unzipped/base"
unzip -q -o "$baseApk" -d "$workDir/fromPlay-unzipped/base"

for apk_file in "$apkDir"/*.apk; do
    [ -e "$apk_file" ] || continue
    apk_name=$(basename "$apk_file")
    if [ "$apk_name" = "base.apk" ]; then
        continue
    fi
    normalized_name=$(echo "$apk_name" | sed 's/^split_config\.//; s/\.apk$//')
    mkdir -p "$workDir/fromPlay-unzipped/$normalized_name"
    unzip -q -o "$apk_file" -d "$workDir/fromPlay-unzipped/$normalized_name"
done

appHash=$(sha256sum "$baseApk" | awk '{print $1;}')
signer=$(getSigner "$baseApk")

echo -e "${GREEN}Official APK info:${NC}"
echo "  SHA256: $appHash"
echo "  Signer: $signer"

# Step 4: Clone repository
echo -e "\n${CYAN}Step 4: Cloning Nunchuk repository...${NC}"
repoDir="$workDir/nunchuk-android"

if [ -d "$repoDir/.git" ]; then
    echo -e "${YELLOW}Repository already exists, updating...${NC}"
    cd "$repoDir"
    git fetch --all --tags --prune --quiet
    git reset --hard --quiet
    git clean -fdx --quiet
else
    git clone --quiet https://github.com/nunchuk-io/nunchuk-android "$repoDir"
    cd "$repoDir"
fi

if [ -n "$tagOverride" ]; then
    gitTag="$tagOverride"
    echo -e "${YELLOW}Tag override applied: $gitTag${NC}"
else
    gitTag="android.$versionName"
fi

echo -e "${CYAN}Checking out tag: $gitTag${NC}"
if ! git checkout "$gitTag" --quiet 2>/dev/null; then
    echo -e "${RED}Error: Failed to checkout tag $gitTag${NC}"
    echo "Available tags:"
    git tag | grep android | tail -5
    exit 1
fi

commit=$(git rev-parse HEAD)
echo -e "${GREEN}Checked out commit: $commit${NC}"

# Step 5: Build Docker image
echo -e "\n${CYAN}Step 5: Building Docker image...${NC}"

dockerfileContent=$(cat <<'DOCKERFILE_END'
FROM docker.io/debian:stable-20240722-slim

RUN set -ex; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes -o APT::Install-Suggests=false --no-install-recommends \
        bzip2 make automake ninja-build g++-multilib libtool binutils-gold \
        bsdmainutils pkg-config python3 patch bison curl unzip git openjdk-17-jdk sudo nano; \
    rm -rf /var/lib/apt/lists/*; \
    useradd -ms /bin/bash appuser; \
    usermod -aG sudo appuser; \
    echo "appuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER appuser
WORKDIR /home/appuser
RUN mkdir -p /home/appuser/app
ENV ANDROID_SDK_ROOT=/home/appuser/app/sdk
ENV ANDROID_SDK=/home/appuser/app/sdk
ENV ANDROID_HOME=/home/appuser/app/sdk
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
WORKDIR /home/appuser/app/nunchuk

ENV ANDROID_SDK_URL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
ENV ANDROID_BUILD_TOOLS_VERSION 34.0.0
ENV ANDROID_VERSION 34
ENV ANDROID_NDK_VERSION 25.1.8937393
ENV ANDROID_CMAKE_VERSION 3.18.1
ENV ANDROID_NDK_HOME ${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}/
ENV PATH ${PATH}:${ANDROID_HOME}/tools:${ANDROID_HOME}/platform-tools

RUN set -ex; \
    mkdir -p "$ANDROID_HOME/cmdline-tools" && \
    cd "$ANDROID_HOME/cmdline-tools" && \
    curl -o sdk.zip $ANDROID_SDK_URL && \
    unzip sdk.zip && \
    mv cmdline-tools latest && \
    rm sdk.zip

RUN chmod +x ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager

RUN ls -l ${ANDROID_HOME}/cmdline-tools/latest/bin/

RUN yes | ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses
RUN ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME --update

RUN $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME \
    "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" \
    "platforms;android-${ANDROID_VERSION}" \
    "cmake;$ANDROID_CMAKE_VERSION" \
    "platform-tools" \
    "ndk;$ANDROID_NDK_VERSION"

ENV PATH ${ANDROID_NDK_HOME}:$PATH
ENV PATH ${ANDROID_NDK_HOME}/prebuilt/linux-x86_64/bin/:$PATH

ENV GRADLE_USER_HOME=/home/appuser/app/nunchuk/.gradle-home
DOCKERFILE_END
)

echo "$dockerfileContent" > "$workDir/Dockerfile.nunchuk"

cd "$workDir"
echo -e "${YELLOW}Building Docker image (this may take 10-15 minutes)...${NC}"
if [ "$verbose" = true ]; then
    podman build --platform linux/amd64 -t nunchuk-android -f Dockerfile.nunchuk .
else
    podman build --platform linux/amd64 -t nunchuk-android -f Dockerfile.nunchuk . > "$workDir/docker-build.log" 2>&1
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Docker image build failed${NC}"
    [ "$verbose" = false ] && echo "Check $workDir/docker-build.log for details"
    exit 1
fi

echo -e "${GREEN}Docker image built successfully${NC}"

# Step 6: Adjust Gradle memory settings
echo -e "\n${CYAN}Step 6: Adjusting Gradle memory settings...${NC}"
cd "$repoDir"
if [ -f "gradle.properties" ]; then
    sed -i 's/-Xmx8192m/-Xmx4096m/' gradle.properties
    sed -i 's/-XX:MetaspaceSize=8192m/-XX:MetaspaceSize=4096m/' gradle.properties
    echo -e "${GREEN}Memory settings adjusted${NC}"
fi

# Step 7: Build AAB
echo -e "\n${CYAN}Step 7: Building AAB (this may take 20-30 minutes)...${NC}"
mkdir -p "$workDir/built-split_apks"

buildCmd='mkdir -p /app && disorderfs --sort-dirents=yes --reverse-dirents=no /app-src/ /app/ && cd /app && ./gradlew clean bundleProductionRelease'

if [ "$verbose" = true ]; then
    podman run --rm --privileged \
        -v "$repoDir":/app-src \
        --device /dev/fuse \
        --cap-add SYS_ADMIN \
        nunchuk-android \
        bash -c "$buildCmd"
else
    echo -e "${YELLOW}Building... (output suppressed, check $workDir/gradle-build.log for details)${NC}"
    podman run --rm --privileged \
        -v "$repoDir":/app-src \
        --device /dev/fuse \
        --cap-add SYS_ADMIN \
        nunchuk-android \
        bash -c "$buildCmd" > "$workDir/gradle-build.log" 2>&1
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: AAB build failed${NC}"
    if [ "$verbose" = false ]; then
        echo "Check $workDir/gradle-build.log for details"
        tail -50 "$workDir/gradle-build.log"
    fi
    exit 1
fi

aabPath="$repoDir/nunchuk-app/build/outputs/bundle/productionRelease/nunchuk-app-production-release.aab"
if [ ! -f "$aabPath" ]; then
    echo -e "${RED}Error: AAB not found at expected location${NC}"
    exit 1
fi

echo -e "${GREEN}AAB built successfully${NC}"

# Step 8: Download bundletool
echo -e "\n${CYAN}Step 8: Downloading bundletool...${NC}"
mkdir -p "$workDir/bundletool"
bundletoolJar="$workDir/bundletool/bundletool-all-${BUNDLETOOL_VERSION}.jar"

if [ ! -f "$bundletoolJar" ]; then
    curl -L --fail --silent --show-error \
        "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
        -o "$bundletoolJar"
    
    if [ $? -ne 0 ] || [ ! -f "$bundletoolJar" ]; then
        echo -e "${RED}Error: Failed to download bundletool${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Bundletool ready${NC}"

# Step 9: Generate split APKs from AAB
echo -e "\n${CYAN}Step 9: Generating split APKs from AAB...${NC}"

rm -f "$workDir/built-split_apks/bundle.apks"

podman run --rm \
    -v "$workDir":/work \
    --workdir /work \
    docker.io/openjdk:11-jre \
    java -jar /work/bundletool/bundletool-all-${BUNDLETOOL_VERSION}.jar build-apks \
    --bundle="/work/nunchuk-android/nunchuk-app/build/outputs/bundle/productionRelease/nunchuk-app-production-release.aab" \
    --output="/work/built-split_apks/bundle.apks" \
    --device-spec=/work/device-spec.json \
    --mode=default > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: bundletool build-apks failed${NC}"
    exit 1
fi

rm -rf "$workDir/built-split_apks/extracted"

podman run --rm \
    -v "$workDir":/work \
    --workdir /work \
    docker.io/openjdk:11-jre \
    java -jar /work/bundletool/bundletool-all-${BUNDLETOOL_VERSION}.jar extract-apks \
    --apks="/work/built-split_apks/bundle.apks" \
    --output-dir="/work/built-split_apks/extracted" \
    --device-spec=/work/device-spec.json > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: bundletool extract-apks failed${NC}"
    exit 1
fi

# Normalize APK names
cd "$workDir/built-split_apks/extracted"
find . -name "base-master.apk" -exec mv {} ../base.apk \;
find . -name "base-*.apk" ! -name "base-master.apk" -exec sh -c '
    for f; do
        config_name=$(basename "$f" | sed "s/base-/split_config./")
        mv "$f" ../"$config_name"
    done
' sh {} +
find . -name "*.apk" -exec mv {} ../ \;
cd "$workDir/built-split_apks"
rm -rf extracted

echo -e "${GREEN}Split APKs generated and normalized${NC}"

# Step 10: List built APKs
echo -e "\n${CYAN}Step 10: Built APKs${NC}"
list_apk_hashes "$workDir/built-split_apks" "Built APKs"

# Step 11: Extract built APKs
echo -e "\n${CYAN}Step 11: Extracting built APKs for comparison...${NC}"
for apk_file in "$workDir/built-split_apks"/*.apk; do
    [ -e "$apk_file" ] || continue
    apk_name=$(basename "$apk_file")
    
    if [ "$apk_name" = "base-master.apk" ]; then
        mkdir -p "$workDir/fromBuild-unzipped/base"
        unzip -q -o "$apk_file" -d "$workDir/fromBuild-unzipped/base"
        continue
    fi
    
    normalized_name=$(echo "$apk_name" | sed 's/^base-//; s/^split_config\.//; s/\.apk$//')
    mkdir -p "$workDir/fromBuild-unzipped/$normalized_name"
    unzip -q -o "$apk_file" -d "$workDir/fromBuild-unzipped/$normalized_name"
done

built_base_apk="$workDir/built-split_apks/base.apk"
if [ -f "$built_base_apk" ]; then
    mkdir -p "$workDir/fromBuild-decoded"
    if command -v apktool &> /dev/null; then
        apktool d -f -o "$workDir/fromBuild-decoded/base" "$built_base_apk" > /dev/null 2>&1
    else
        containerApktool "$workDir/fromBuild-decoded/base" "$built_base_apk"
    fi
fi

# Step 12: Run comparisons
echo -e "\n${CYAN}Step 12: Running comparisons...${NC}"

mkdir -p "$workDir/analysis"
diffResult=""
for dir in "$workDir/fromPlay-unzipped"/*; do
    dir_name=$(basename "$dir")
    if [ -d "$workDir/fromBuild-unzipped/$dir_name" ]; then
        diff_output=$(diff --brief --recursive "$dir" "$workDir/fromBuild-unzipped/$dir_name" 2>/dev/null || true)
        if [ -z "$diff_output" ]; then
            echo -e "${GREEN}✓ No differences: $dir_name${NC}"
            touch "$workDir/analysis/diff_$dir_name.txt"
        else
            echo -e "${YELLOW}✗ Differences found: $dir_name${NC}"
            echo "$diff_output" > "$workDir/analysis/diff_$dir_name.txt"
            diffResult="$diffResult$diff_output"$'\n'
        fi
    else
        echo -e "${YELLOW}⚠ Built directory not found: $dir_name${NC}"
    fi
done

if command -v diffoscope &> /dev/null; then
    echo -e "\n${CYAN}Running diffoscope on AndroidManifest.xml...${NC}"
    diffoscope --html "$workDir/analysis/diffoscope_AndroidManifest.html" \
        "$workDir/fromPlay-decoded/base/AndroidManifest.xml" \
        "$workDir/fromBuild-decoded/base/AndroidManifest.xml" > /dev/null 2>&1 || true
    echo -e "${GREEN}Diffoscope output: $workDir/analysis/diffoscope_AndroidManifest.html${NC}"
fi

# Calculate verdict
diffCount=0
if [[ -n "$diffResult" ]]; then
    diffCount=$(grep -vcE "(META-INF|^$)" <<<"$diffResult" 2>/dev/null || echo "0")
fi

if [[ $diffCount -eq 0 ]]; then
    verdict="reproducible"
else
    verdict="differences found"
fi

# Output Results (following verification-result-summary-format.md)
echo ""
echo "===== Begin Results ====="
echo "appId:          $appId"
echo "signer:         $signer"
echo "apkVersionName: $versionName"
echo "apkVersionCode: $versionCode"
echo "verdict:        $verdict"
echo "appHash:        $appHash"
echo "commit:         $commit"
echo ""
echo "Diff:"
for diff_file in "$workDir/analysis"/diff_*.txt; do
    [ -e "$diff_file" ] || continue
    if [ -s "$diff_file" ]; then
        cat "$diff_file"
    fi
done
echo ""
echo "Revision, tag (and its signature):"
cd "$repoDir"
if git cat-file -t "$gitTag" 2>/dev/null | grep -q "tag"; then
    git verify-tag "$gitTag" 2>&1 || echo "[WARNING] Tag verification failed or no signature"
    echo ""
    echo "Signature Summary:"
    echo "Tag type: annotated"
    if git verify-tag "$gitTag" 2>&1 | grep -q "Good signature"; then
        echo "[OK] Good signature on annotated tag"
    else
        echo "[WARNING] No valid signature found on tag"
    fi
else
    echo "Tag type: lightweight"
    echo ""
    echo "Signature Summary:"
    echo "[INFO] Tag is lightweight (cannot contain signature)"
fi

if git verify-commit "$commit" 2>&1 | grep -q "Good signature"; then
    echo "[OK] Good signature on commit"
else
    echo "[WARNING] No valid signature found on commit"
fi
echo ""
echo "===== End Results ====="

# Provide investigation commands
if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Run a full"
    echo "diff --recursive $workDir/fromPlay-unzipped $workDir/fromBuild-unzipped"
    echo "meld $workDir/fromPlay-unzipped $workDir/fromBuild-unzipped"
    echo "or"
    echo "diffoscope \"$baseApk\" $built_base_apk"
    echo "for more details."
fi

# Cleanup if requested
if [ "$shouldCleanup" = true ]; then
    echo -e "\n${CYAN}Cleaning up artifacts...${NC}"
    rm -rf "$workDir"
    echo -e "${GREEN}Cleanup complete${NC}"
fi

echo -e "\n${GREEN}Verification complete!${NC}"
echo -e "${GREEN}Working directory: $workDir${NC}"

# Exit with appropriate code
if [ "$verdict" = "reproducible" ]; then
    exit 0
else
    exit 1
fi
