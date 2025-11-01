#!/bin/bash
# ==============================================================================
# verify_electrumandroid.sh - Electrum Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.1
# Author:        Daniel Garcia (dannybuntu)
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-17 (Philippine Time)
# Project:       https://github.com/spesmilo/electrum
# ==============================================================================
# Changes in v0.3.1:
# - CRITICAL FIX: grep -v in result() now handles zero-match case (reproducible builds)
# - Fixed script exit when all diffs are META-INF (verification summary now displays)
#
# Changes in v0.3.0:
# - Refactored for brevity: condensed help text from 233 to 48 lines
# - Simplified signature verification logic (removed complex key management)
# - Removed self-modifying add_known_key() function and KNOWN_SIGNING_KEYS feature
# - Reduced overall verbosity while maintaining all core verification functionality
#
# Changes in v0.2.1:
# - Added workspace collision detection to prevent stale artifact issues
#
# For full changelog history, see: git log verify_electrumandroid.sh
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
# - Downloads official Electrum APK/AAB from app stores or extracts from connected device
# - Clones source code repository and checks out the exact release tag/commit
# - Performs containerized reproducible build using official Android build system
# - Compares built APK/AAB against official releases using apktool and binary analysis
# - Documents differences and generates detailed reproducibility assessment report

set -euo pipefail

# Error handling
on_error() {
  local exit_code=$?
  local line_no=$1
  echo -e "${RED}${ERROR_ICON} Script failed at line $line_no with exit code $exit_code${NC}"
  echo -e "${RED}Last command: ${BASH_COMMAND}${NC}"

  # Log error information
  echo "=== ERROR OCCURRED ==="
  echo "Timestamp: $(date -Iseconds)"

  # Note: Session should be recorded with asciinema manually

  # Android-specific cleanup
  if [[ -n "${container_image:-}" ]]; then
    echo "Cleaning up container: $container_image"
    $CONTAINER_CMD rm -f "$container_image" 2>/dev/null || true
  fi

  # ADB cleanup
  if command -v adb >/dev/null 2>&1; then
    adb kill-server 2>/dev/null || true
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
wsContainer="docker.io/walletscrutiny/android:5"
shouldCleanup=false
extractFromPhone=false

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

# Function to check if a command exists and print status
check_command() {
  if command -v $1 &> /dev/null || alias | grep -q "$1"; then
    echo -e "$1 - ${GREEN}${SUCCESS_ICON} installed${NC}"
  else
    echo -e "$1 - ${RED}${ERROR_ICON} not installed${NC}"
    MISSING_DEPENDENCIES=true
  fi
}

is_app_installed() {
  local package_name="$1"
  if adb shell pm list packages | grep -q "^package:$package_name$"; then
    return 0 # App is installed
  else
    return 1 # App is not installed
  fi
}

extract_apk_from_phone() {
  local bundleId="org.electrum.electrum"

  echo -e "${YELLOW}======== PHONE EXTRACTION MODE ========${NC}"
  echo -e "${YELLOW}Ensure phone is connected via USB with $bundleId installed.${NC}"
  echo -e "${RED}WARNING: This grants script access to your Android device. Review code before running.${NC}"
  echo

  MISSING_DEPENDENCIES=false

  # Check dependencies
  check_command "adb"
  check_command "java"
  check_command "aapt"

  if [ "$MISSING_DEPENDENCIES" = true ]; then
    echo -e "${RED}Please install the missing dependencies before running the script.${NC}"
    exit 1
  fi

  # Check if a phone is connected
  connected_devices=$(adb devices | grep -w "device")
  if [ -z "$connected_devices" ]; then
    echo -e "${RED}No phone connected. Enable USB Debugging on your Android device and connect it.${NC}"
    exit 1
  fi

  echo -e "${GREEN}Device connected successfully.${NC}"

  # Check if the app is installed
  if ! is_app_installed "$bundleId"; then
    echo -e "${RED}Error: The app '$bundleId' is not installed on the connected device.${NC}"
    exit 1
  fi

  # Get APK paths
  echo "Retrieving APK paths for bundle ID: $bundleId"
  apks=$(adb shell pm path $bundleId)

  echo "APK paths retrieved:"
  echo "$apks"

  # Determine if the app uses single or split APKS
  if echo "$apks" | grep -qE "split_|config."; then
    echo -e "${YELLOW}App uses split APKs${NC}"
  else
    echo -e "${YELLOW}App uses single APK${NC}"
  fi

  # Create temporary directory for APKs
  local temp_dir="/tmp/test_org.electrum.electrum_$(date +%s)"
  mkdir -p "$temp_dir/official-apk"

  # Pull APKs
  echo "Pulling APKs..."
  for apk in $apks; do
    apkPath=$(echo $apk | awk '{print $NF}' FS=':' | tr -d '\r\n')
    echo "Pulling $apkPath"
    adb pull "$apkPath" "$temp_dir/official-apk/"
  done

  # Set downloadedApk to the base.apk
  downloadedApk="$temp_dir/official-apk/base.apk"

  echo "APK extracted to: $downloadedApk"
}

usage() {
  cat <<'EOF'
NAME
       verify_electrumandroid.sh - Electrum Android reproducible build verification

SYNOPSIS
       verify_electrumandroid.sh -a <apk_file> [OPTIONS]
       verify_electrumandroid.sh -b <version> [OPTIONS]
       verify_electrumandroid.sh -x [OPTIONS]
       verify_electrumandroid.sh -v | -h

DESCRIPTION
       Performs containerized reproducible build verification for Electrum Android.
       Clones source, builds APK in Docker/Podman, compares against official release,
       and verifies signatures. Workspace: /tmp/test_org.electrum.electrum_<version>/

OPTIONS
       -v, --version           Show script version and exit
       -h, --help              Show this help and exit

       -a, --apk <file>        Path to APK file to verify (auto-detects version)
       -b, --build <version>   Build version from source without APK comparison
       -x, --extract           Extract APK from connected Android device via ADB

       -r, --revision <hash>   Override git tag, checkout specific commit
       -c, --cleanup           Remove temporary files after completion

REQUIREMENTS
       docker OR podman, git, unzip, sha256sum, grep, awk, sed
       Optional: adb (for -x), aapt, java, diffoscope, meld

EXIT CODES
       0    Verification completed (check verdict in output for reproducibility status)
       1    Build failed, dependency missing, or runtime error
       2    Unsupported appId (not org.electrum.electrum)

EXAMPLES
       verify_electrumandroid.sh -a ~/Downloads/Electrum-4.6.2.apk
       verify_electrumandroid.sh -b 4.6.2
       verify_electrumandroid.sh -x -c

For detailed documentation, see: https://walletscrutiny.com

EOF
}

# Read script arguments and flags
# ===============================

downloadedApk=""
revisionOverride=""
buildVersion=""
showVersion=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--version) showVersion=true ;;
    -b|--build) buildVersion="$2"; shift ;;
    -a|--apk) downloadedApk="$2"; shift ;;
    -x|--extract) extractFromPhone=true ;;
    -r|--revision-override) revisionOverride="$2"; shift ;;
    -c|--cleanup) shouldCleanup=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Show script version and exit if requested
if [ "$showVersion" = true ]; then
  echo "verify_electrumandroid.sh v0.3.1"
  exit 0
fi

# Check for mutual exclusivity of -a and -b flags
if [[ -n "$downloadedApk" && -n "$buildVersion" ]]; then
  echo "Error: Cannot use -a and -b together."
  echo "  -a: Verify APK (auto-detects version from APK metadata)"
  echo "  -b: Build specific version from source (no APK needed)"
  echo
  usage
  exit 1
fi

# make sure path is absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Functions
# =========

containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")

  # Check if APK file exists and is readable
  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  # Run apktool in a container so apktool doesn't need to be installed.
  # The folder with the apk file is mounted read only and only the output folder
  # is mounted with write permission.
  echo "Running apktool with $CONTAINER_CMD..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume "$targetFolderParent:/tfp" \
    --volume "$appFolder:/af:ro" \
    "$wsContainer" \
    sh -c "apktool d -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then

    echo -e "${RED}Container apktool failed. This might be due to storage issues.${NC}"
    if [ "$CONTAINER_CMD" = "podman" ]; then
      echo -e "${YELLOW}Try running: podman system reset --force${NC}"
      echo -e "${YELLOW}Or install docker: sudo apt install docker.io${NC}"
    elif [ "$CONTAINER_CMD" = "docker" ]; then
      echo -e "${YELLOW}Try running: docker system prune -f${NC}"
    fi
    return 1
  fi
  return 0
}

getSigner() {
  DIR=$(dirname "$1")
  BASE=$(basename "$1")
  s=$(
    $CONTAINER_CMD run \
      --rm \
      --volume "$DIR:/mnt:ro" \
      --workdir /mnt \
      "$wsContainer" \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256"  | awk '{print $6}' )
  echo $s
}

# Handle different modes: -b (build mode), -x (extract), or -a (verify APK)
if [[ -n "$buildVersion" ]]; then
  # Build mode: no APK needed, just build from source
  appId="org.electrum.electrum"
  versionName="$buildVersion"
  versionCode=""  # Not needed for build-only mode
  downloadedApk=""  # No APK in build mode
  signer=""
  appHash=""
  fromPlayFolder=""

  echo "=== Electrum Android Build Mode ==="
  echo "Timestamp: $(date -Iseconds)"
  echo "Building version: $versionName"
  echo "Mode: Build only (no APK comparison)"

elif [ "$extractFromPhone" = true ]; then
  # Extract mode: pull APK from connected phone
  extract_apk_from_phone

  # Extract metadata after pulling
  if ! command -v "$CONTAINER_CMD" >/dev/null 2>&1; then
    echo "Error: $CONTAINER_CMD is required to run this script" >&2
    exit 1
  fi

  appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
  fromPlayFolder="/tmp/fromPlay$appHash"
  rm -rf "$fromPlayFolder"
  signer=$( getSigner "$downloadedApk" )
  echo "Extracting APK content ..."
  containerApktool "$fromPlayFolder" "$downloadedApk" || exit 1
  appId=$( head -n 1 "$fromPlayFolder/AndroidManifest.xml" | sed 's/.*package="//g' | sed 's/".*//g' )
  versionName=$( grep versionName "$fromPlayFolder/apktool.yml" | sed 's/.*: //g' | tr -d "'" )
  versionCode=$( grep versionCode "$fromPlayFolder/apktool.yml" | sed 's/.*: //g' | tr -d "'" )

else
  # Verify mode: validate APK file and extract metadata
  if [[ -z "$downloadedApk" ]]; then
    echo "Error: APK file not specified. Use -a to provide APK or -b to build without APK."
    echo
    usage
    exit 1
  fi

  if [ ! -f "$downloadedApk" ]; then
    echo "APK file not found: $downloadedApk"
    echo
    usage
    exit 1
  fi

  if ! command -v "$CONTAINER_CMD" >/dev/null 2>&1; then
    echo "Error: $CONTAINER_CMD is required to run this script" >&2
    exit 1
  fi

  appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
  fromPlayFolder="/tmp/fromPlay$appHash"
  rm -rf "$fromPlayFolder"
  signer=$( getSigner "$downloadedApk" )
  echo "Extracting APK content ..."
  containerApktool "$fromPlayFolder" "$downloadedApk" || exit 1
  appId=$( head -n 1 "$fromPlayFolder/AndroidManifest.xml" | sed 's/.*package="//g' | sed 's/".*//g' )
  versionName=$( grep versionName "$fromPlayFolder/apktool.yml" | sed 's/.*: //g' | tr -d "'" )
  versionCode=$( grep versionCode "$fromPlayFolder/apktool.yml" | sed 's/.*: //g' | tr -d "'" )
fi

# Common variables for all modes
workDir="/tmp/test_${appId}_${versionName}"
repo="https://github.com/spesmilo/electrum"
electrum_checkout="$workDir/app"
container_image="walletscrutiny/electrum-android:local"
builtApk=""
additionalInfo=""

# Note: Session recording should be done manually with asciinema before running script
# Example: asciinema rec output.cast && ./verify_electrumandroid.sh -a app.apk

if [[ -z "$buildVersion" ]]; then
  # Standard verification mode output
  echo "=== Electrum Android Verification Session Start ==="
  echo "Timestamp: $(date -Iseconds)"
  echo "AppID: $appId"
  echo "Version: $versionName ($versionCode)"
  echo "Workspace: $workDir"
  echo "=============================================="
fi

if [[ -z "$appId" ]]; then
  echo "appId could not be determined"
  exit 1
fi

if [[ -z "$versionName" ]]; then
  echo "versionName could not be determined"
  exit 1
fi

# versionCode not required for build-only mode
if [[ -z "$buildVersion" && -z "$versionCode" ]]; then
  echo "versionCode could not be determined"
  exit 1
fi

if [[ "$appId" != "org.electrum.electrum" ]]; then
  echo "Unsupported appId $appId (expected org.electrum.electrum)"
  exit 2
fi

if [[ -z "$buildVersion" ]]; then
  echo
  echo "Testing \"$downloadedApk\" ($appId version $versionName)"
  echo
else
  echo "Workspace: $workDir"
  echo "=============================================="
  echo
fi

# Check if workspace already exists from a previous run
# This prevents issues with stale artifacts and inconsistent state
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
  if [[ "$version" =~ ^(.+)\.0$ ]]; then
    add_candidate "${BASH_REMATCH[1]}"
  fi

  local base
  for base in "${ordered[@]}"; do
    add_candidate "v${base}"
  done

  local candidate
  for candidate in "${ordered[@]}"; do
    if git rev-parse --verify "refs/tags/${candidate}^{tag}" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

determine_architectures() {
  local apk="$1"
  local output

  if command -v aapt >/dev/null 2>&1; then
    output=$(aapt dump badging "$apk" 2>/dev/null || true)
  else
    local apk_dir apk_name
    apk_dir="$(dirname "$apk")"
    apk_name="$(basename "$apk")"
    output=$($CONTAINER_CMD run --rm --volume "$apk_dir":/apk:ro "$wsContainer" \
      sh -c "aapt dump badging /apk/$apk_name" 2>/dev/null || true)
  fi

  if [[ -z "$output" ]]; then
    return 0
  fi

  awk -F"'" '/native-code/ {for (i=2; i<=NF; i+=2) print $i}' <<<"$output"
}

prepare() {
  echo "Preparing Electrum source repository..."
  rm -rf "$workDir"
  mkdir -p "$workDir"
  cd "$workDir"

  git clone --quiet --recurse-submodules "$repo" "$electrum_checkout"
  cd "$electrum_checkout"
  git fetch --quiet --tags

  if [[ -n "$revisionOverride" ]]; then
    git checkout --quiet "$revisionOverride"
    tag="$revisionOverride"
  else
    local resolved
    if resolved=$(resolve_tag); then
      git checkout --quiet "refs/tags/$resolved"
      tag="$resolved"
    else
      tag="$(git rev-parse HEAD)"
      echo "Warning: No matching tag for version $versionName; using commit $tag" >&2
      if [[ -n "$additionalInfo" ]]; then
        additionalInfo+=$'\n'
      fi
      additionalInfo+="No upstream tag matched version $versionName; using commit $tag."
    fi
  fi

  git submodule update --init --recursive
  commit="$(git rev-parse HEAD)"
  echo "Using Electrum revision $tag (commit $commit)"
}

test() {
  cd "$electrum_checkout"

  local build_arch
  if [[ -n "$buildVersion" ]]; then
    # Build-only mode: default to armeabi-v7a (most common architecture)
    build_arch="armeabi-v7a"
    echo "Build-only mode: building for $build_arch architecture"
  else
    # Verification mode: detect architecture from APK
    local native_arches=()
    mapfile -t native_arches < <(determine_architectures "$downloadedApk")

    if [[ ${#native_arches[@]} -eq 0 || -z "${native_arches[0]:-}" ]]; then
      echo "Unable to determine APK architecture from $downloadedApk" >&2
      exit 1
    fi

    build_arch="${native_arches[0]}"
    if [[ ${#native_arches[@]} -gt 1 ]]; then
      if [[ -n "$additionalInfo" ]]; then
        additionalInfo+=$'\n'
      fi
      additionalInfo+="APK reports multiple ABIs (${native_arches[*]}). Building ${build_arch} only."
    fi
  fi

  if [[ ! -f contrib/android/Dockerfile ]]; then
    echo "Missing contrib/android/Dockerfile in Electrum checkout" >&2
    exit 1
  fi

  cp contrib/deterministic-build/requirements-build-android.txt contrib/android/ || true

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  $CONTAINER_CMD build \
    --tag "$container_image" \
    --file contrib/android/Dockerfile \
    --build-arg UID="$uid" \
    --build-arg GID="$gid" \
    .

  # Pre-create directories that the build process expects
  # This prevents FileNotFoundError when buildozer tries to copy APK to dist/
  mkdir -p "$electrum_checkout/.gradle"
  mkdir -p "$electrum_checkout/dist"
  chmod -R 777 "$electrum_checkout/dist" 2>/dev/null || true

  echo "Starting containerized build for architecture: $build_arch"
  echo "This may take 15-30 minutes depending on your system..."

  $CONTAINER_CMD run --rm \
    --userns=keep-id \
    --env GIT_PAGER=cat \
    --env PAGER=cat \
    --env VIRTUAL_ENV=/opt/venv \
    --env PATH="/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --volume "$electrum_checkout:/home/user/wspace/electrum:Z" \
    --volume "$electrum_checkout/.gradle:/home/user/.gradle:Z" \
    --workdir /home/user/wspace/electrum \
    "$container_image" \
    bash -lc "set -x && \
      source /opt/venv/bin/activate && \
      which buildozer && \
      git config --global --add safe.directory /home/user/wspace/electrum && \
      pwd && \
      ls -la && \
      mkdir -p dist && \
      chmod +x contrib/android/make_apk.sh && \
      cd /home/user/wspace/electrum && \
      ./contrib/android/make_apk.sh qml '$build_arch' release-unsigned || \
      { echo '=== Build failed, searching for APK in build directories ==='; \
        find . -type f -name '*${build_arch}*release*.apk' -ls; \
        find . -type f -name '*Electrum*.apk' -ls; \
        exit 1; }"

  echo "Build process completed, searching for APK..."

  builtApk="$electrum_checkout/dist/Electrum-$versionName-$build_arch-release-unsigned.apk"

  # Enhanced APK finding logic with multiple fallback strategies
  if [[ ! -f "$builtApk" ]]; then
    echo "Primary APK location not found: $builtApk"
    echo "Searching for APK in all build directories..."

    # Search in common buildozer output directories
    builtApk=$(find "$electrum_checkout" -type f \
      \( -name "*${build_arch}*release*.apk" -o \
         -name "*Electrum*${versionName}*.apk" -o \
         -name "*Electrum*release*.apk" \) \
      -not -path "*.buildozer/android/platform/build*/build/*" \
      -not -path "*/.gradle/*" \
      -print -quit 2>/dev/null)

    # If still not found, search more broadly including buildozer bin directories
    if [[ -z "$builtApk" || ! -f "$builtApk" ]]; then
      echo "Searching buildozer bin directories..."
      builtApk=$(find "$electrum_checkout/.buildozer" -type f -name "*.apk" 2>/dev/null | \
        grep -E "(${build_arch}|release)" | head -1)
    fi

    if [[ -n "$builtApk" && -f "$builtApk" ]]; then
      echo "Found APK at alternate location: $builtApk"
    fi
  fi

  if [[ -z "$builtApk" || ! -f "$builtApk" ]]; then
    echo "=== APK NOT FOUND ===" >&2
    echo "Searched locations:" >&2
    echo "  - $electrum_checkout/dist/" >&2
    echo "  - $electrum_checkout/.buildozer/android/platform/build*/bin/" >&2
    echo "" >&2
    echo "Available APK files in checkout:" >&2
    find "$electrum_checkout" -type f -name "*.apk" -ls 2>/dev/null || echo "  (none found)" >&2
    exit 1
  fi

  echo "APK found: $builtApk"
  ls -lh "$builtApk"

  mkdir -p "$workDir/app/dist"
  local targetApkPath="$workDir/app/dist/$(basename "$builtApk")"

  if [[ -e "$targetApkPath" && "$(readlink -f "$builtApk")" == "$(readlink -f "$targetApkPath")" ]]; then
    echo "Built APK already present in workspace dist; skipping copy"
  else
    cp "$builtApk" "$workDir/app/dist/"
  fi

  builtApk="$targetApkPath"

  # Clean up container image (disable error exit temporarily to ensure script continues)
  set +e
  $CONTAINER_CMD image rm "$container_image" >/dev/null 2>&1
  set -e
}

result() {
  # Consolidate all artifacts into workDir for better organization
  local fromPlayUnzipped="$workDir/fromPlay_${appId}_$versionCode"
  local fromBuildUnzipped="$workDir/fromBuild_${appId}_$versionCode"

  rm -rf "$fromBuildUnzipped" "$fromPlayUnzipped"
  unzip -qq "$downloadedApk" -d "$fromPlayUnzipped"
  unzip -qq "$builtApk" -d "$fromBuildUnzipped"

  local diffResult
  diffResult=$(diff --brief --recursive "$fromPlayUnzipped" "$fromBuildUnzipped" || true)

  local diffCount=0
  if [[ -n "$diffResult" ]]; then
    diffCount=$(grep -vcE "(META-INF|^$)" <<<"$diffResult" || true)
  fi

  local verdict=""
  if [[ $diffCount -eq 0 ]]; then
    verdict="reproducible"
  else
    verdict="differences found"
  fi

  local diffGuide="
Run a full
diff --recursive $fromPlayUnzipped $fromBuildUnzipped
meld $fromPlayUnzipped $fromBuildUnzipped
or
diffoscope \"$downloadedApk\" $builtApk
for more details."
  if [[ "$shouldCleanup" == true ]]; then
    diffGuide=''
  fi

  local infoBlock=""
  if [[ -n "$additionalInfo" ]]; then
    infoBlock="===== Also ====
$additionalInfo
"
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
  echo "$diffResult"
  echo
  echo "Revision, tag, and signatures:"

  # Check tag type
  if git rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
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

  echo -e "\n${infoBlock}===== End Results ====="
  echo "$diffGuide"
}

cleanup() {
  if [[ "$shouldCleanup" == "true" ]]; then
    rm -rf "$fromPlayFolder" "$workDir"
  else
    echo "Workspace preserved: $workDir"
  fi
}

# Main execution with logging
echo "=== Starting Verification Process ==="
prepare
test

# Only run result() and cleanup() if we have an APK to compare
if [[ -z "$buildVersion" ]]; then
  result
  echo "=== Verification Complete ==="
else
  echo "=== Build Complete ==="
  echo "Built APK: $builtApk"
  ls -lh "$builtApk"
  echo "Workspace: $workDir"
fi

echo "Session End: $(date -Iseconds)"

# Always run cleanup to handle logs
if [[ -z "$buildVersion" ]]; then
  cleanup
else
  echo "Build artifacts preserved at: $workDir"
fi
