#!/bin/bash
# ==============================================================================
# verify_bullbitcoinandroid.sh - Bull Bitcoin Mobile Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.0
# Author:        Daniel Garcia (dannybuntu)
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-21 (Philippine Time)
# Project:       https://github.com/SatoshiPortal/bullbitcoin-mobile
# ==============================================================================
# Changes in v0.1.0:
# - Initial release: Standalone AAB verification script for Bull Bitcoin Mobile
# - Supports split APKs verification (Play Store AAB distribution)
# - Auto-generates device-spec.json from official APK metadata
# - Embedded Dockerfile for reproducible Flutter AAB build
# - Split-by-split comparison with aggregated diff output
# - Compliant with Luis guidelines and verification-result-summary-format.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK/AAB comparisons - review all operations before execution.
# This script requires access to connected Android devices for split APK extraction.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Extracts official Bull Bitcoin Mobile split APKs from device or provided directory
# - Auto-generates device-spec.json from APK metadata (architectures, SDK, locales, density)
# - Clones source code repository and checks out the exact release tag
# - Performs containerized reproducible AAB build using Flutter/Android SDK
# - Extracts split APKs from built AAB using bundletool and device-spec.json
# - Compares built split APKs against official releases (split-by-split diff analysis)
# - Documents differences and generates detailed reproducibility assessment report

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

# Function to check if a command exists
check_command() {
  if command -v $1 &> /dev/null; then
    echo -e "$1 - ${GREEN}${SUCCESS_ICON} installed${NC}"
  else
    echo -e "$1 - ${RED}${ERROR_ICON} not installed${NC}"
    MISSING_DEPENDENCIES=true
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
       verify_bullbitcoinandroid.sh - Bull Bitcoin Mobile reproducible build verification

SYNOPSIS
       verify_bullbitcoinandroid.sh -a <apk_dir> [OPTIONS]
       verify_bullbitcoinandroid.sh -v | -h

DESCRIPTION
       Performs containerized reproducible AAB build verification for Bull Bitcoin Mobile.
       Extracts split APKs from device, builds AAB from source in Docker/Podman, extracts
       split APKs from built AAB using bundletool, and compares against official release.
       Workspace: /tmp/test_com.bullbitcoin.mobile_<version>/

OPTIONS
       -v, --version           Show script version and exit
       -h, --help              Show this help and exit

       -a, --apk-dir <dir>     Directory containing official split APKs (required)
                               Expected files: base.apk, split_config.*.apk

       -t, --type <type>       App type (optional, for Luis guidelines compliance)
       -r, --revision <hash>   Override git tag, checkout specific commit
       -c, --cleanup           Remove temporary files after completion

REQUIREMENTS
       docker OR podman, git, unzip, sha256sum, grep, awk, sed, aapt
       Optional: java (for bundletool), diffoscope, meld

EXIT CODES
       0    Verification completed (check verdict in output for reproducibility status)
       1    Build failed, dependency missing, or runtime error
       2    Unsupported appId (not com.bullbitcoin.mobile)

EXAMPLES
       verify_bullbitcoinandroid.sh -a /var/shared/apk/com.bullbitcoin.mobile/6.1.0/splits/
       verify_bullbitcoinandroid.sh -a ~/bullbitcoin-splits/ -c

For detailed documentation, see: https://walletscrutiny.com

EOF
}

# Read script arguments and flags
# ===============================

apkDir=""
revisionOverride=""
appType=""
showVersion=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--version) showVersion=true ;;
    -a|--apk-dir) apkDir="$2"; shift ;;
    -t|--type) appType="$2"; shift ;;
    -r|--revision) revisionOverride="$2"; shift ;;
    -c|--cleanup) shouldCleanup=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Show script version and exit if requested
if [ "$showVersion" = true ]; then
  echo "verify_bullbitcoinandroid.sh v0.1.0"
  exit 0
fi

# Validate required arguments
if [[ -z "$apkDir" ]]; then
  echo -e "${RED}Error: APK directory not specified. Use -a to provide directory with split APKs.${NC}"
  usage
  exit 1
fi

# Make path absolute
if ! [[ $apkDir =~ ^/.* ]]; then
  apkDir="$PWD/$apkDir"
fi

if [ ! -d "$apkDir" ]; then
  echo -e "${RED}Error: APK directory $apkDir not found!${NC}"
  exit 1
fi

# Check for base.apk
if [ ! -f "$apkDir/base.apk" ]; then
  echo -e "${RED}Error: base.apk not found in $apkDir${NC}"
  exit 1
fi

echo "=== Bull Bitcoin Mobile Verification Session Start ==="
echo "Timestamp: $(date -Iseconds)"
echo "APK Directory: $apkDir"
echo "=============================================="

# Extract metadata from base.apk
# ===============================

echo "Extracting metadata from base.apk..."
tempExtractDir=$(mktemp -d /tmp/extract_base_XXXXXX)
containerApktool "$tempExtractDir" "$apkDir/base.apk"

if [ $? -ne 0 ]; then
  echo -e "${RED}Failed to extract base.apk${NC}"
  exit 1
fi

appId=$(grep 'package=' "$tempExtractDir"/AndroidManifest.xml | sed 's/.*package=\"//g' | sed 's/\".*//g')
versionName=$(grep 'versionName' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")
versionCode=$(grep 'versionCode' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")

rm -rf "$tempExtractDir"

if [ -z "$appId" ]; then
  echo "appId could not be determined from base.apk"
  exit 1
fi

if [ -z "$versionName" ]; then
  echo "versionName could not be determined from base.apk"
  exit 1
fi

if [ -z "$versionCode" ]; then
  echo "versionCode could not be determined from base.apk"
  exit 1
fi

if [[ "$appId" != "com.bullbitcoin.mobile" ]]; then
  echo "Unsupported appId $appId (expected com.bullbitcoin.mobile)"
  exit 2
fi

echo "App ID: $appId"
echo "Version: $versionName ($versionCode)"

# Extract signer and hash from base.apk
appHash=$(sha256sum "$apkDir/base.apk" | awk '{print $1;}')
signer=$( getSigner "$apkDir/base.apk" )

echo "Base APK Hash: $appHash"
echo "Signer: $signer"

# Define workspace
workDir="/tmp/test_${appId}_${versionName}"
repo="https://github.com/SatoshiPortal/bullbitcoin-mobile"
container_name="bullbitcoin_verifier_$$"
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

# Generate device-spec.json
# =========================

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

# Create workspace and device-spec.json
mkdir -p "$workDir"

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

# Extract official split APKs
# ===========================

echo "Extracting official split APKs..."

mkdir -p "$workDir/official-split-apks"
mkdir -p "$workDir/official-unzipped"

# Copy all split APKs to workspace
cp -r "$apkDir"/*.apk "$workDir/official-split-apks/" 2>/dev/null || true

# Unzip each split APK
for apk_file in "$workDir/official-split-apks"/*.apk; do
  [ -e "$apk_file" ] || continue
  apk_name=$(basename "$apk_file")

  # Normalize name: base.apk → base, split_config.arm64_v8a.apk → arm64_v8a
  if [[ "$apk_name" == "base.apk" ]]; then
    normalized_name="base"
  else
    normalized_name=$(echo "$apk_name" | sed 's/^split_config\.//; s/\.apk$//')
  fi

  mkdir -p "$workDir/official-unzipped/$normalized_name"
  unzip -qq "$apk_file" -d "$workDir/official-unzipped/$normalized_name"

  echo "  Extracted: $apk_name → official-unzipped/$normalized_name/"
done

echo "Official split APKs extracted to: $workDir/official-unzipped/"

# Resolve git tag
# ===============

resolve_tag() {
  local version="${versionName:-}"
  if [[ -z "$version" ]]; then
    return 1
  fi

  declare -A seen=()
  local ordered=()

  add_candidate() {
    local candidate="$1"
    if [[ -n "$candidate" && -z "${seen[$candidate]:-}" ]]; then
      ordered+=("$candidate")
      seen[$candidate]=1
    fi
  }

  add_candidate "$version"
  add_candidate "v${version}"

  local candidate
  for candidate in "${ordered[@]}"; do
    if git rev-parse --verify "refs/tags/${candidate}" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# Prepare source repository
# =========================

prepare() {
  echo "Preparing Bull Bitcoin Mobile source repository..."

  cd "$workDir"
  git clone --quiet "$repo" app
  cd app
  git fetch --quiet --tags

  if [[ -n "$revisionOverride" ]]; then
    git checkout --quiet "$revisionOverride"
    tag=""
    commit=$(git rev-parse HEAD)
    echo "Checked out revision: $commit (manual override)"
  else
    tag=$(resolve_tag)
    if [[ -z "$tag" ]]; then
      echo -e "${YELLOW}${WARNING_ICON} No matching tag found for version $versionName${NC}"
      echo "Searching for commit matching version..."
      # Try to find commit from version code in git log
      commit=$(git log --all --grep="$versionName" --format="%H" -n 1 || echo "")
      if [[ -z "$commit" ]]; then
        echo -e "${RED}Cannot find tag or commit for version $versionName${NC}"
        exit 1
      fi
      git checkout --quiet "$commit"
      additionalInfo="No upstream tag matched version $versionName; using commit $commit."
    else
      git checkout --quiet "$tag"
      commit=$(git rev-parse HEAD)
      echo "Checked out tag: $tag (commit: $commit)"
    fi
  fi

  cd "$workDir"
}

# Create Dockerfile
# =================

create_dockerfile() {
  cat > "$workDir/Dockerfile" <<'DOCKERFILE_EOF'
# Bull Bitcoin Mobile Reproducible Build Dockerfile
# Modified from upstream v6.1.0 Dockerfile for verification purposes
FROM --platform=linux/amd64 ubuntu:24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive
ENV USER="docker"

# Install necessary dependencies
RUN apt update && apt install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    wget \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

RUN apt update && apt install -y sudo
RUN adduser --disabled-password --gecos '' $USER
RUN adduser $USER sudo
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER $USER
RUN sudo apt update

# Install OpenJDK 21
RUN sudo apt-get update && sudo apt-get install -y openjdk-21-jdk && sudo rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/home/$USER/.cargo/bin:${PATH}"

# Verify Rust installation
RUN rustc --version && cargo --version

# Set environment variables
ENV FLUTTER_HOME=/opt/flutter
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$FLUTTER_HOME/bin:$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

# Install Flutter
RUN sudo git clone https://github.com/flutter/flutter.git $FLUTTER_HOME
RUN sudo sh -c "cd $FLUTTER_HOME && git checkout stable && ./bin/flutter --version"

# Set up Android SDK
RUN sudo mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    sudo wget -q https://dl.google.com/android/repository/commandlinetools-linux-8092744_latest.zip -O android-cmdline-tools.zip && \
    sudo unzip -q android-cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools && \
    sudo mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    sudo rm android-cmdline-tools.zip

RUN sudo chown -R $USER /opt/flutter
RUN sudo chown -R $USER /opt/android-sdk

RUN flutter config --android-sdk=/opt/android-sdk

# Accept licenses and install necessary Android SDK components
RUN yes | sdkmanager --licenses
RUN sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"

# Clean up existing app directory
RUN sudo rm -rf /app

RUN sudo mkdir /app

RUN sudo chown -R $USER /app

# Clone the Bull Bitcoin mobile repository at v6.1.0 tag
RUN git clone --branch v6.1.0 https://github.com/SatoshiPortal/bullbitcoin-mobile /app

WORKDIR /app

# Setup the project (using direct flutter commands instead of make/fvm)
# Skip clean since this is a fresh clone
RUN flutter pub get
RUN dart run build_runner build --delete-conflicting-outputs
RUN flutter gen-l10n

# Create .env (empty values)
RUN cp .env.template .env

# Generate a fake keystore for reproducible signing
RUN keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload -storepass android -keypass android -dname "CN=Android Debug,O=Android,C=US"

# Set up key.properties
RUN echo "storePassword=android" > /app/android/key.properties && \
    echo "keyPassword=android" >> /app/android/key.properties && \
    echo "keyAlias=upload" >> /app/android/key.properties && \
    echo "storeFile=/app/upload-keystore.jks" >> /app/android/key.properties

# Build AAB (Android App Bundle) instead of APK
RUN flutter build appbundle --release
DOCKERFILE_EOF

  echo "Dockerfile created at: $workDir/Dockerfile"
}

# Build AAB in container
# ======================

build_aab() {
  echo "Building AAB in container..."
  echo "This may take 30-60 minutes depending on system resources..."

  create_dockerfile

  cd "$workDir"

  # Build container image with increased file descriptor limit
  echo "Building container image..."
  $CONTAINER_CMD build --no-cache --ulimit nofile=65536:65536 -t bullbitcoin-mobile:v6.1.0 .

  if [ $? -ne 0 ]; then
    echo -e "${RED}Container build failed${NC}"
    exit 1
  fi

  # Create container to copy artifacts
  echo "Creating container to extract AAB..."
  $CONTAINER_CMD create --name "$container_name" bullbitcoin-mobile:v6.1.0

  # Copy AAB from container to host
  mkdir -p "$workDir/built-aab"
  $CONTAINER_CMD cp "$container_name":/app/build/app/outputs/bundle/release/app-release.aab "$workDir/built-aab/"

  if [ ! -f "$workDir/built-aab/app-release.aab" ]; then
    echo -e "${RED}Failed to copy AAB from container${NC}"
    exit 1
  fi

  echo "AAB built successfully: $workDir/built-aab/app-release.aab"

  # Clean up container
  $CONTAINER_CMD rm "$container_name"

  cd "$workDir"
}

# Extract split APKs from built AAB using bundletool
# ===================================================

extract_splits_from_aab() {
  echo "Extracting split APKs from built AAB using bundletool..."

  # Check if bundletool is available, if not download it
  if [ ! -f "$workDir/bundletool.jar" ]; then
    echo "Downloading bundletool..."
    wget -q https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar -O "$workDir/bundletool.jar"

    if [ ! -f "$workDir/bundletool.jar" ]; then
      echo -e "${RED}Failed to download bundletool${NC}"
      exit 1
    fi
  fi

  # Extract split APKs using bundletool
  echo "Running bundletool to generate split APKs..."
  java -jar "$workDir/bundletool.jar" build-apks \
    --bundle="$workDir/built-aab/app-release.aab" \
    --output="$workDir/built-split-apks.apks" \
    --device-spec="$workDir/device-spec.json" \
    --mode=default

  if [ ! -f "$workDir/built-split-apks.apks" ]; then
    echo -e "${RED}Failed to generate split APKs from AAB${NC}"
    exit 1
  fi

  # Unzip the .apks file (it's a ZIP archive containing split APKs)
  mkdir -p "$workDir/built-split-apks-raw"
  unzip -qq "$workDir/built-split-apks.apks" -d "$workDir/built-split-apks-raw/"

  # Copy and normalize split APKs
  mkdir -p "$workDir/built-split-apks"
  mkdir -p "$workDir/built-unzipped"

  # Bundletool puts APKs in a splits/ subdirectory
  for apk_file in "$workDir/built-split-apks-raw/splits"/*.apk; do
    [ -e "$apk_file" ] || continue
    apk_name=$(basename "$apk_file")

    # Normalize filename: base-master.apk → base.apk, base-*.apk → split_config.*.apk
    if [[ "$apk_name" == "base-master.apk" ]] || [[ "$apk_name" == "base.apk" ]]; then
      cp "$apk_file" "$workDir/built-split-apks/base.apk"
      normalized_name="base"
    else
      # Handle base-en.apk → split_config.en.apk, base-armeabi_v7a.apk → split_config.armeabi_v7a.apk
      config_name=$(echo "$apk_name" | sed 's/^base-//; s/\.apk$//')
      cp "$apk_file" "$workDir/built-split-apks/split_config.${config_name}.apk"
      normalized_name="$config_name"
    fi

    # Unzip to corresponding directory
    mkdir -p "$workDir/built-unzipped/$normalized_name"
    unzip -qq "$apk_file" -d "$workDir/built-unzipped/$normalized_name"

    echo "  Extracted: $apk_name → built-unzipped/$normalized_name/"
  done

  echo "Built split APKs extracted to: $workDir/built-unzipped/"
}

# Compare split APKs
# ==================

compare_split_apks() {
  echo ""
  echo "Comparing split APKs (official vs built)..."
  echo ""

  local all_diffs=""
  local total_non_meta_diffs=0

  # Compare each split
  for official_split_dir in "$workDir/official-unzipped"/*; do
    split_name=$(basename "$official_split_dir")
    built_split_dir="$workDir/built-unzipped/$split_name"

    if [[ ! -d "$built_split_dir" ]]; then
      echo -e "${YELLOW}${WARNING_ICON} Split $split_name exists in official but not in built${NC}"
      additionalInfo+="Missing split: $split_name in built artifacts. "
      continue
    fi

    echo "Comparing split: $split_name..."
    diff_output=$(diff --brief --recursive "$official_split_dir" "$built_split_dir" 2>/dev/null || true)

    if [[ -n "$diff_output" ]]; then
      # Save to file
      echo "$diff_output" > "$workDir/diff_${split_name}.txt"

      # Count non-META-INF diffs
      non_meta_count=$(grep -vcE "(META-INF|^$)" <<<"$diff_output" 2>/dev/null || echo "0")
      total_non_meta_diffs=$((total_non_meta_diffs + non_meta_count))

      # Aggregate for summary with split identifier
      all_diffs+="=== ${split_name} ==="$'\n'
      all_diffs+="$diff_output"$'\n'
      all_diffs+=""$'\n'

      echo "  Differences found: $(echo "$diff_output" | wc -l) files differ (non-META-INF: $non_meta_count)"
    else
      echo "  No differences found"
      touch "$workDir/diff_${split_name}.txt"
    fi
  done

  # Check for extra splits in built that don't exist in official
  for built_split_dir in "$workDir/built-unzipped"/*; do
    split_name=$(basename "$built_split_dir")
    official_split_dir="$workDir/official-unzipped/$split_name"

    if [[ ! -d "$official_split_dir" ]]; then
      echo -e "${YELLOW}${WARNING_ICON} Split $split_name exists in built but not in official${NC}"
      additionalInfo+="Extra split: $split_name in built artifacts. "
    fi
  done

  # Export for result function
  export aggregated_diffs="$all_diffs"
  export total_non_meta_diffs

  echo ""
  echo "Total non-META-INF differences across all splits: $total_non_meta_diffs"
}

# Generate verification summary
# ==============================

result() {
  local verdict=""
  if [[ $total_non_meta_diffs -eq 0 ]]; then
    verdict="reproducible"
  else
    verdict="differences found"
  fi

  local diffGuide="
Run a full diff on individual splits:
diff --recursive $workDir/official-unzipped/base $workDir/built-unzipped/base

Or use meld for visual comparison:
meld $workDir/official-unzipped $workDir/built-unzipped

Or use diffoscope on individual split APKs:
diffoscope $workDir/official-split-apks/base.apk $workDir/built-split-apks/base.apk

for more details."

  if [[ "$shouldCleanup" == true ]]; then
    diffGuide=''
  fi

  local infoBlock=""
  if [[ -n "$additionalInfo" ]]; then
    infoBlock="===== Also ====$newline$additionalInfo$newline"
  fi

  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $versionName"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "commit:         $commit"
  echo
  echo "Diff:"
  echo "$aggregated_diffs"
  echo
  echo "Revision, tag (and its signature):"

  cd "$workDir/app"

  # Check tag type
  if [[ -n "$tag" ]] && git rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    if [[ $(git cat-file -t "refs/tags/$tag") == "tag" ]]; then
      echo "Tag: $tag (annotated)"
      git tag -v "$tag" 2>&1 || echo "[INFO] Tag signature check failed or not signed"
    else
      echo "Tag: $tag (lightweight, no signature possible)"
    fi
  else
    echo "No tag (build from commit $commit)"
  fi

  # Check commit signature
  echo ""
  git verify-commit "$commit" 2>&1 || echo "[INFO] Commit signature check failed or not signed"

  cd "$workDir"

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
prepare
build_aab
extract_splits_from_aab
compare_split_apks
result
echo "=== Verification Complete ==="
echo "Session End: $(date -Iseconds)"

cleanup
