#!/bin/bash
# ==============================================================================
# verify_electrumandroid.sh - Electrum Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.6.0
# Organization:  WalletScrutiny.com
# Last Modified: 2025-11-01
# Project:       https://github.com/spesmilo/electrum
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/org.electrum.electrum/changelog.md
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
# - Verifies provided Electrum APK file against reproducible build from source
# - Clones source code repository and checks out the exact release tag/commit
# - Performs containerized reproducible build using official Android build system
# - Compares built APK against provided APK using apktool and binary analysis
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

usage() {
  cat <<'EOF'
NAME
       verify_electrumandroid.sh - Electrum Android reproducible build verification

SYNOPSIS
       verify_electrumandroid.sh --apk <apk_file> [OPTIONS]
       verify_electrumandroid.sh --build <version> [OPTIONS]
       verify_electrumandroid.sh --version | --help

DESCRIPTION
       Performs containerized reproducible build verification for Electrum Android.
       Clones source, builds APK in Docker/Podman, compares against official release,
       and verifies signatures. Workspace: /tmp/test_org.electrum.electrum_<version>/

OPTIONS
       --version               Show script version and exit
       --help                  Show this help and exit

       --apk <file>            Path to APK file to verify (auto-detects version)
       --build <version>       Build version from source without APK comparison

       --revision <hash>       Override git tag, checkout specific commit
       --cleanup               Remove temporary files after completion

REQUIREMENTS
       docker OR podman (ONLY dependency - fully containerized)
       Optional: diffoscope, meld (for manual diff inspection)

EXIT CODES
       0    Reproducible - binaries match (only acceptable differences)
       1    Not reproducible - differences found OR build/runtime error

EXAMPLES
       verify_electrumandroid.sh --apk ~/Downloads/Electrum-4.6.2.apk
       verify_electrumandroid.sh --build 4.6.2 --cleanup

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
    --version) showVersion=true ;;
    --build) buildVersion="$2"; shift ;;
    --apk) downloadedApk="$2"; shift ;;
    --revision) revisionOverride="$2"; shift ;;
    --cleanup) shouldCleanup=true ;;
    --help) usage; echo "Exit code: 0"; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; echo "Exit code: 1"; exit 1 ;;
  esac
  shift
done

# Show script version and exit if requested
if [ "$showVersion" = true ]; then
  echo "verify_electrumandroid.sh v0.6.0"
  echo "Exit code: 0"
  exit 0
fi

# Check for mutual exclusivity of --apk and --build flags
if [[ -n "$downloadedApk" && -n "$buildVersion" ]]; then
  echo "Error: Cannot use --apk and --build together."
  echo "  --apk: Verify APK (auto-detects version from APK metadata)"
  echo "  --build: Build specific version from source (no APK needed)"
  echo
  usage
  echo "Exit code: 1"
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

# Handle different modes: --build (build mode) or --apk (verify APK)
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

else
  # Verify mode: validate APK file and extract metadata
  if [[ -z "$downloadedApk" ]]; then
    echo "Error: APK file not specified. Use --apk to provide APK or --build to build without APK."
    echo
    usage
    echo "Exit code: 1"
    exit 1
  fi

  if [ ! -f "$downloadedApk" ]; then
    echo "APK file not found: $downloadedApk"
    echo
    usage
    echo "Exit code: 1"
    exit 1
  fi

  if ! command -v "$CONTAINER_CMD" >/dev/null 2>&1; then
    echo "Error: $CONTAINER_CMD is required to run this script" >&2
    exit 1
  fi

  # Calculate hash in container
  local apk_dir apk_name
  apk_dir="$(dirname "$downloadedApk")"
  apk_name="$(basename "$downloadedApk")"
  appHash=$($CONTAINER_CMD run --rm --volume "$apk_dir":/apk:ro "$wsContainer" \
    sh -c "sha256sum /apk/$apk_name | awk '{print \$1}'")
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
  echo "Exit code: 1"
  exit 1
fi

if [[ -z "$versionName" ]]; then
  echo "versionName could not be determined"
  echo "Exit code: 1"
  exit 1
fi

# versionCode not required for build-only mode
if [[ -z "$buildVersion" && -z "$versionCode" ]]; then
  echo "versionCode could not be determined"
  echo "Exit code: 1"
  exit 1
fi

if [[ "$appId" != "org.electrum.electrum" ]]; then
  echo "Unsupported appId $appId (expected org.electrum.electrum)"
  echo "Exit code: 1"
  exit 1
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
  echo "Exit code: 1"
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

  # Always use containerized aapt
  local apk_dir apk_name
  apk_dir="$(dirname "$apk")"
  apk_name="$(basename "$apk")"
  output=$($CONTAINER_CMD run --rm --volume "$apk_dir":/apk:ro "$wsContainer" \
    sh -c "aapt dump badging /apk/$apk_name" 2>/dev/null || true)

  if [[ -z "$output" ]]; then
    return 0
  fi

  awk -F"'" '/native-code/ {for (i=2; i<=NF; i+=2) print $i}' <<<"$output"
}

prepare() {
  echo "Preparing Electrum source repository (containerized)..."
  rm -rf "$workDir"
  mkdir -p "$workDir"

  # Run git operations in container
  echo "Cloning repository in container..."
  $CONTAINER_CMD run --rm \
    --volume "$workDir":/workspace:Z \
    --workdir /workspace \
    "$wsContainer" \
    sh -c "git clone --quiet --recurse-submodules '$repo' app"

  # Determine which tag/commit to use
  local target_ref="$revisionOverride"
  if [[ -z "$target_ref" ]]; then
    # Try to resolve tag from version name
    target_ref=$($CONTAINER_CMD run --rm \
      --volume "$workDir":/workspace:Z \
      --workdir /workspace/app \
      "$wsContainer" \
      sh -c "
        git fetch --quiet --tags
        # Try version as-is
        if git rev-parse --verify 'refs/tags/$versionName^{tag}' >/dev/null 2>&1; then
          echo '$versionName'
        # Try with v prefix
        elif git rev-parse --verify 'refs/tags/v$versionName^{tag}' >/dev/null 2>&1; then
          echo 'v$versionName'
        # Try without .0 suffix
        elif [[ '$versionName' =~ ^(.+)\.0$ ]] && git rev-parse --verify \"refs/tags/\${BASH_REMATCH[1]}^{tag}\" >/dev/null 2>&1; then
          echo '\${BASH_REMATCH[1]}'
        # Try without .0 suffix and with v prefix
        elif [[ '$versionName' =~ ^(.+)\.0$ ]] && git rev-parse --verify \"refs/tags/v\${BASH_REMATCH[1]}^{tag}\" >/dev/null 2>&1; then
          echo 'v\${BASH_REMATCH[1]}'
        else
          echo 'HEAD'
        fi
      " || echo "HEAD")
  fi

  # Checkout the target ref
  echo "Checking out $target_ref..."
  $CONTAINER_CMD run --rm \
    --volume "$workDir":/workspace:Z \
    --workdir /workspace/app \
    "$wsContainer" \
    sh -c "git checkout --quiet '$target_ref' && git submodule update --init --recursive"

  # Get commit hash and tag info
  commit=$($CONTAINER_CMD run --rm \
    --volume "$workDir":/workspace:Z \
    --workdir /workspace/app \
    "$wsContainer" \
    sh -c "git rev-parse HEAD")
  
  tag="$target_ref"
  if [[ "$tag" == "HEAD" ]]; then
    echo "Warning: No matching tag for version $versionName; using commit $commit" >&2
    if [[ -n "$additionalInfo" ]]; then
      additionalInfo+=$'\n'
    fi
    additionalInfo+="No upstream tag matched version $versionName; using commit $commit."
  fi

  echo "Using Electrum revision $tag (commit $commit)"
}

test() {
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

  if [[ ! -f "$electrum_checkout/contrib/android/Dockerfile" ]]; then
    echo "Missing contrib/android/Dockerfile in Electrum checkout" >&2
    exit 1
  fi

  cp "$electrum_checkout/contrib/deterministic-build/requirements-build-android.txt" "$electrum_checkout/contrib/android/" 2>/dev/null || true

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  $CONTAINER_CMD build \
    --tag "$container_image" \
    --file "$electrum_checkout/contrib/android/Dockerfile" \
    --build-arg UID="$uid" \
    --build-arg GID="$gid" \
    "$electrum_checkout"

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
  mkdir -p "$fromPlayUnzipped" "$fromBuildUnzipped"

  # Unzip in container
  echo "Extracting APKs in container..."
  local apk_dir apk_name built_dir built_name
  apk_dir="$(dirname "$downloadedApk")"
  apk_name="$(basename "$downloadedApk")"
  built_dir="$(dirname "$builtApk")"
  built_name="$(basename "$builtApk")"

  $CONTAINER_CMD run --rm \
    --volume "$apk_dir":/official:ro \
    --volume "$fromPlayUnzipped":/output:Z \
    "$wsContainer" \
    sh -c "unzip -qq /official/$apk_name -d /output"

  $CONTAINER_CMD run --rm \
    --volume "$built_dir":/built:ro \
    --volume "$fromBuildUnzipped":/output:Z \
    "$wsContainer" \
    sh -c "unzip -qq /built/$built_name -d /output"

  # Diff in container
  echo "Comparing APKs in container..."
  local diffResult
  diffResult=$($CONTAINER_CMD run --rm \
    --volume "$fromPlayUnzipped":/official:ro \
    --volume "$fromBuildUnzipped":/built:ro \
    "$wsContainer" \
    sh -c "diff --brief --recursive /official /built || true" | sed 's|/official|$fromPlayUnzipped|g; s|/built|$fromBuildUnzipped|g')

  local diffCount=0
  if [[ -n "$diffResult" ]]; then
    diffCount=$(grep -vcE "(META-INF|^$)" <<<"$diffResult" || true)
  fi

  local verdict=""
  local exit_code=0
  if [[ $diffCount -eq 0 ]]; then
    verdict="reproducible"
    exit_code=0
  else
    verdict="differences found"
    exit_code=1
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
  
  return $exit_code
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
  verification_exit_code=$?
  echo "=== Verification Complete ==="
  cleanup
  echo "Session End: $(date -Iseconds)"
  echo "Exit code: $verification_exit_code"
  exit $verification_exit_code
else
  echo "=== Build Complete ==="
  echo "Built APK: $builtApk"
  ls -lh "$builtApk"
  echo "Workspace: $workDir"
  echo "Build artifacts preserved at: $workDir"
  echo "Session End: $(date -Iseconds)"
  echo "Exit code: 0"
  exit 0
fi
