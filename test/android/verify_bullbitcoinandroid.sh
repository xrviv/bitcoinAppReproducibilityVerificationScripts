#!/bin/bash
# ==============================================================================
# verify_bullbitcoinandroid.sh - Bull Bitcoin Mobile Reproducible Build Verification
# ==============================================================================
# Version:       v0.5.1
# Author:        Daniel Garcia (dannybuntu)
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-29 (Philippine Time - exit code visibility)
# Project:       https://github.com/SatoshiPortal/bullbitcoin-mobile
# ==============================================================================
# Changes in v0.5.1:
# - Added exit code echo at end of script for visibility
# - Script now prints "Exit code: 0" or "Exit code: 1" before exiting
#
# Changes in v0.5.0:
# - BREAKING: Updated to new Luis script guidelines (2025-10-29)
# - Changed short flags to long flags: -v → --version, -a → --apk, -t → --type
# - Added --arch parameter (optional, for future multi-architecture support)
# - Kept --revision as custom flag (not in guidelines but useful)
# - --apk now accepts both file (single APK) or directory (split APKs)
# - All examples updated to use new long-form parameters
#
# Changes in v0.4.3:
# - Added --preserve flag to save both official and built split APKs to workspace
# - Split APKs preserved in workspace/official-splits/ and workspace/built-splits/
# - Allows post-verification analysis of actual APK binaries (not just diffs)
#
# Changes in v0.4.2:
# - CRITICAL: Force cargokit to build Rust libraries from source instead of using precompiled binaries
# - Sets use_precompiled_binaries: false in cargokit_options.yaml for reproducibility
# - Ensures native .so files (libbdk_flutter, libark_wallet, etc.) are compiled from source
# - Root cause: v0.4.0/v0.4.1 had Rust targets + NDK but cargokit downloaded precompiled binaries
#
# Changes in v0.4.1:
# - Fixed: Convert workDir to absolute path after creation for podman mounting
# - Prevents "lstat: no such file or directory" error with relative paths
#
# Changes in v0.4.0:
# - CRITICAL: Added Rust Android cross-compilation targets (aarch64, armv7, x86_64, i686)
# - CRITICAL: Set NDK environment variables (ANDROID_NDK_HOME, NDK_HOME) for Rust FFI
# - CRITICAL: Explicitly install NDK via sdkmanager (ndk;27.0.12077973)
# - Changed workspace from /tmp to execution directory (Luis guideline compliance)
# - GitHub APK directory now in execution dir instead of /tmp
# - Fixes missing native libraries: libbdk_flutter, libark_wallet, libboltz, lwk, payjoin_flutter, libtor
#
# Changes in v0.3.9:
# - CRITICAL: Fixed memory exhaustion when reading large diff files (12MB+)
# - Read diff files efficiently: use head/wc without loading entire file into RAM
# - Prevents hang/crash when diff has 466K+ lines (Bull Bitcoin v6.1.0 case)
# - Check file size with -s before reading content
# - Read only first line to check for special markers
#
# Changes in v0.3.8:
# - Truncate large diff output: show only first 3 lines if diff > 3 lines
# - Add "Full diff saved to: <path>" message for truncated diffs
# - Add split labels in device mode for better readability
# - Prevents terminal flooding with massive smali diffs (10K+ lines)
#
# Changes in v0.3.7:
# - Added 6GB memory limit to podman run containers to avoid user-slice OOM kills
# - Keeps Flutter build from taking down GNOME even on 16GB systems
#
# Changes in v0.3.6:
# - Configure git safe.directory=/app inside container before signature checks
# - Prevents git from aborting when container runs as root with /app owned by docker user
#
# Changes in v0.3.5:
# - Align verification summary with Luis + standard result format
# - Populate GitHub download metadata (hash, signer, version code)
# - Emit full diff output instead of truncated previews
# - Sync --version reporting with header metadata
#
# Changes in v0.3.4:
# - CRITICAL FIX: Added memory limit (4GB) to container build to prevent OOM crashes
# - Added pre-build memory check with user warning if < 4GB available
# - Updated REQUIREMENTS: Minimum 8GB RAM (12GB+ recommended)
# - Documented OOM incident: systemd-oomd killed terminal at 3.2GB usage
# - Container now limited to 4GB to ensure system stability
# - Interactive prompt allows user to cancel build on low memory
#
# Changes in v0.3.3:
# - Moved GitHub APK download inside container (~95% containerization!)
# - Removed curl dependency from host (only docker/podman needed now)
# - Container downloads APK directly using wget (already installed)
# - Pass app version to container via environment variable
# - True Luis compliance: absolutely minimal host dependencies
#
# Changes in v0.3.2:
# - Made -a parameter optional (full Luis Guidelines compliance)
# - Added Path 1: GitHub APK verification (no -a, downloads universal APK from GitHub)
# - Added Path 2: Device split APK verification (with -a, uses provided splits)
# - Automatic path selection based on -a presence
# - Universal APK extraction from AAB using bundletool --mode=universal
# - Two comparison modes: universal APK vs APK, or split-by-split
# - Build server can now run without pre-extracted device APKs
#
# Changes in v0.3.1:
# - Changed -v flag to specify app version (not script version)
# - Added --version flag for script version (Unix convention)
# - Script now compares user-specified version against official APK version
# - Added comparison summary: "Comparing v{built} to v{official}"
# - Added version mismatch warning if versions differ
# - Full Luis compliance: -v specifies app version to build
#
# Changes in v0.3.0:
# - BREAKING: Removed git dependency from host (full Luis compliance)
# - Git clone now happens inside Dockerfile using build arg
# - Git verification moved to container, outputs to git_verification.txt
# - Fixed exit code: returns 0 if reproducible, 1 if differences found
# - Removed prepare() and resolve_tag() functions (no longer needed on host)
# - Updated REQUIREMENTS: only docker/podman needed on host
#
# Changes in v0.2.3:
# - Improved diff output readability - now shows only first 3 lines per split
# - Added summary line showing total lines and diff file path
# - Prevents terminal flooding with massive smali diffs
# - Full diffs still saved to workspace for detailed analysis
#
# Changes in v0.2.2:
# - Fixed runtime permission error when writing to mounted /workspace volume
# - Removed host-side mkdir for results directory (line 739 deleted)
# - Added --user root to container run command for volume write access
# - Container script now creates results directory with correct permissions
#
# Changes in v0.2.1:
# - Fixed Podman user namespace permission error in Dockerfile
# - Removed redundant chmod on extract_and_compare.sh (already executable from host)
# - COPY instruction preserves executable permission set on line 580
#
# Changes in v0.2.0:
# - BREAKING: Full containerization - only docker/podman required on host
# - Moved bundletool execution inside container (removes Java host dependency)
# - Moved APK extraction/comparison inside container (removes unzip dependency)
# - Single container run for build + extract + compare (was multi-step)
# - Embedded extraction/comparison script runs inside container
# - Host script only orchestrates and displays results
# - 100% compliant with Luis and standalone script guidelines
#
# Changes in v0.1.0:
# - Initial release: Standalone AAB verification script for Bull Bitcoin Mobile
# - Supports split APKs verification (Play Store AAB distribution)
# - Auto-generates device-spec.json from official APK metadata
# - Embedded Dockerfile for reproducible Flutter AAB build
# - Split-by-split comparison with aggregated diff output
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
# - Reads official Bull Bitcoin Mobile split APKs from provided directory
# - Auto-generates device-spec.json from APK metadata (architectures, SDK, locales, density)
# - Builds container image with Flutter/Android SDK + bundletool + apktool
# - Runs single container that:
#   * Clones source code and checks out exact release tag
#   * Builds AAB using Flutter (reproducible build)
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

# Function to check if a command exists
check_command() {
  if command -v $1 &> /dev/null; then
    echo -e "$1 - ${GREEN}${SUCCESS_ICON} installed${NC}"
  else
    echo -e "$1 - ${RED}${ERROR_ICON} not installed${NC}"
    MISSING_DEPENDENCIES=true
  fi
}

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
       verify_bullbitcoinandroid.sh - Bull Bitcoin Mobile reproducible build verification

SYNOPSIS
       verify_bullbitcoinandroid.sh --version <version> [--apk <path>] [OPTIONS]
       verify_bullbitcoinandroid.sh --script-version | --help

DESCRIPTION
       Performs containerized reproducible AAB build verification for Bull Bitcoin Mobile.
       Extracts split APKs from device, builds AAB from source in Docker/Podman, extracts
       split APKs from built AAB using bundletool, and compares against official release.
       Workspace: ./bullbitcoin_<version>_verification/

OPTIONS
       --script-version        Show script version and exit
       --help                  Show this help and exit

       --version <version>     App version to build (required, e.g., 6.1.0 without 'v' prefix)
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
       docker OR podman (required - that's it!)
       aapt (optional - falls back to container if missing)

       Minimum 8GB RAM (12GB+ recommended for stability)
       - Build requires 4GB+ for container
       - Additional 2-4GB for system operations
       - Low memory may cause system instability or OOM crashes

       Standard tools (typically pre-installed): sha256sum, grep, awk, sed

       Note: APK downloads happen inside container, no curl/wget needed on host

EXIT CODES
       0    Verification reproducible
       1    Verification not reproducible or error occurred
       2    Unsupported appId (not com.bullbitcoin.mobile)

EXAMPLES
       # Path 1: GitHub universal APK verification (no device needed)
       verify_bullbitcoinandroid.sh --version 6.1.0

       # Path 2: Device split APK verification (requires extracted splits)
       verify_bullbitcoinandroid.sh --version 6.1.0 --apk /var/shared/apk/com.bullbitcoin.mobile/6.1.0/
       verify_bullbitcoinandroid.sh --version 6.1.0 --apk ~/bullbitcoin-splits/ --cleanup

       # Preserve split APKs for further analysis
       verify_bullbitcoinandroid.sh --version 6.1.0 --apk ~/bullbitcoin-splits/ --preserve

       # Specify app type for automated builds
       verify_bullbitcoinandroid.sh --version 6.1.0 --type bitcoin

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
  echo "verify_bullbitcoinandroid.sh v0.5.1"
  exit 0
fi

# Validate required arguments
if [[ -z "$appVersion" ]]; then
  echo -e "${RED}Error: App version not specified. Use --version to specify version (e.g., --version 6.1.0).${NC}"
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
  apkDir="./bullbitcoin_${appVersion}_github_apk"
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
    apkDir="./bullbitcoin_${appVersion}_apk"
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

echo "=== Bull Bitcoin Mobile Verification Session Start ==="
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

  if [[ "$appId" != "com.bullbitcoin.mobile" ]]; then
    echo "Unsupported appId $appId (expected com.bullbitcoin.mobile)"
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
  appId="com.bullbitcoin.mobile"
  officialVersion="$appVersion"  # Assume versions match
  versionCode="TBD"
  appHash="TBD"
  signer="TBD"
  echo -e "${CYAN}Will compare v${appVersion} (to be built) to v${appVersion} (GitHub APK)${NC}"
  echo ""
fi

# Define workspace (use appVersion from -v flag)
# Use execution directory as workspace (Luis guideline #2: use directory where script is executed)
workDir="./bullbitcoin_${appVersion}_verification"
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

# Create workspace
mkdir -p "$workDir"
# Convert to absolute path for container mounting
workDir=$(cd "$workDir" && pwd)

echo "Absolute workspace path: $workDir"
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

# Create extraction and comparison script (runs inside container)
# =================================================================

create_extraction_script() {
  cat > "$workDir/extract_and_compare.sh" <<EXTRACT_EOF
#!/bin/bash
set -euo pipefail

MODE="\$1"
OFFICIAL_DIR="\$2"
OUTPUT_DIR="\$3"
APP_VERSION="\${4:-}"
DEVICE_SPEC="\${5:-}"
PRESERVE="\${6:-false}"

echo "[Container] Starting extraction and comparison (mode: \$MODE)..."
mkdir -p "\$OUTPUT_DIR"

if [[ "\$MODE" == "github" ]]; then
  # Path 1: GitHub universal APK comparison
  echo "[Container] Downloading APK from GitHub releases..."

  # Get release page to find actual APK filename
  releaseJson=\$(curl -sL "https://api.github.com/repos/SatoshiPortal/bullbitcoin-mobile/releases/tags/v\${APP_VERSION}")
  apkUrl=\$(echo "\$releaseJson" | grep -o "https://github.com/SatoshiPortal/bullbitcoin-mobile/releases/download/v\${APP_VERSION}/[^\"]*\\.apk" | head -n1)

  if [[ -z "\$apkUrl" ]]; then
    echo "[Container ERROR] Could not find APK in GitHub releases for v\${APP_VERSION}"
    echo "[Container ERROR] Check https://github.com/SatoshiPortal/bullbitcoin-mobile/releases/tag/v\${APP_VERSION}"
    exit 1
  fi

  echo "[Container] Downloading: \$apkUrl"
  wget -q "\$apkUrl" -O "\$OFFICIAL_DIR/github.apk"

  if [ ! -f "\$OFFICIAL_DIR/github.apk" ]; then
    echo "[Container ERROR] Failed to download APK from GitHub"
    exit 1
  fi

  echo "[Container] Downloaded GitHub APK: \${OFFICIAL_DIR}/github.apk"

  echo "[Container] Extracting universal APK from AAB..."
  java -jar /tmp/bundletool.jar build-apks \\
    --bundle=/app/build/app/outputs/bundle/release/app-release.aab \\
    --output=/tmp/built-universal.apks \\
    --mode=universal

  echo "[Container] Unzipping universal APK..."
  mkdir -p /tmp/built-decoded /tmp/official-decoded
  unzip -qq /tmp/built-universal.apks 'universal.apk' -d /tmp/

  echo "[Container] Decoding built universal APK..."
  apktool d -f -o /tmp/built-decoded /tmp/universal.apk 2>/dev/null || true

  echo "[Container] Decoding official GitHub APK..."
  apktool d -f -o /tmp/official-decoded "\$OFFICIAL_DIR/github.apk" 2>/dev/null || true

  echo "[Container] Comparing universal APKs..."
  diff_output=\$(diff -r /tmp/official-decoded /tmp/built-decoded 2>/dev/null || true)

  if [[ -n "\$diff_output" ]]; then
    echo "\$diff_output" > "\$OUTPUT_DIR/diff_universal.txt"
    non_meta=\$(echo "\$diff_output" | grep -vcE "(META-INF|^$)" || echo "0")
    echo "    Differences: \$non_meta (non-META-INF)"
  else
    touch "\$OUTPUT_DIR/diff_universal.txt"
    echo "    No differences found"
    non_meta=0
  fi

  echo "\$non_meta" > "\$OUTPUT_DIR/total_diffs.txt"
  echo "[Container] Total non-META-INF differences: \$non_meta"

  # Preserve universal APKs if requested
  if [[ "\$PRESERVE" == "true" ]]; then
    echo "[Container] Preserving universal APKs to workspace..."
    mkdir -p "\$OUTPUT_DIR/official-apk"
    mkdir -p "\$OUTPUT_DIR/built-apk"

    echo "  Copying official universal APK..."
    cp "\$OFFICIAL_DIR/github.apk" "\$OUTPUT_DIR/official-apk/" 2>/dev/null || true
    cp /tmp/universal.apk "\$OUTPUT_DIR/built-apk/universal.apk" 2>/dev/null || true

    echo "[Container] Universal APKs preserved:"
    echo "  Official: \$OUTPUT_DIR/official-apk/"
    echo "  Built: \$OUTPUT_DIR/built-apk/"
  fi

else
  # Path 2: Device split APK comparison
  echo "[Container] Extracting split APKs from AAB using bundletool..."
  java -jar /tmp/bundletool.jar build-apks \\
    --bundle=/app/build/app/outputs/bundle/release/app-release.aab \\
    --output=/tmp/built-split-apks.apks \\
    --device-spec="\$DEVICE_SPEC" \\
    --mode=default

  echo "[Container] Unzipping split APKs..."
  mkdir -p /tmp/built-raw /tmp/built-decoded /tmp/official-decoded
  unzip -qq /tmp/built-split-apks.apks -d /tmp/built-raw/

  echo "[Container] Decoding built split APKs..."
  for apk in /tmp/built-raw/splits/*.apk; do
    [ -e "\$apk" ] || continue
    name=\$(basename "\$apk" .apk)
    if [[ "\$name" == "base-master" ]]; then
      normalized="base"
    else
      normalized=\$(echo "\$name" | sed 's/^base-//')
    fi
    echo "  Decoding: \$name -> \$normalized"
    apktool d -f -o "/tmp/built-decoded/\$normalized" "\$apk" 2>/dev/null || true
  done

  echo "[Container] Decoding official split APKs..."
  for apk in "\$OFFICIAL_DIR"/*.apk; do
    [ -e "\$apk" ] || continue
    name=\$(basename "\$apk" .apk)
    if [[ "\$name" == "base" ]]; then
      normalized="base"
    else
      normalized=\$(echo "\$name" | sed 's/^split_config\\.//')
    fi
    echo "  Decoding: \$name -> \$normalized"
    apktool d -f -o "/tmp/official-decoded/\$normalized" "\$apk" 2>/dev/null || true
  done

  echo "[Container] Comparing split APKs..."
  total_diffs=0

  for official in /tmp/official-decoded/*; do
    [ -d "\$official" ] || continue
    split_name=\$(basename "\$official")
    built="/tmp/built-decoded/\$split_name"
    if [[ ! -d "\$built" ]]; then
      echo "  [WARNING] Split \$split_name exists in official but not in built"
      echo "missing_in_built" > "\$OUTPUT_DIR/diff_\$split_name.txt"
      continue
    fi
    echo "  Comparing split: \$split_name..."
    diff_output=\$(diff -r "\$official" "\$built" 2>/dev/null || true)
    if [[ -n "\$diff_output" ]]; then
      echo "\$diff_output" > "\$OUTPUT_DIR/diff_\$split_name.txt"
      non_meta=\$(echo "\$diff_output" | grep -vcE "(META-INF|^$)" || echo "0")
      total_diffs=\$((total_diffs + non_meta))
      echo "    Differences: \$non_meta (non-META-INF)"
    else
      touch "\$OUTPUT_DIR/diff_\$split_name.txt"
      echo "    No differences found"
    fi
  done

  for built in /tmp/built-decoded/*; do
    [ -d "\$built" ] || continue
    split_name=\$(basename "\$built")
    official="/tmp/official-decoded/\$split_name"
    if [[ ! -d "\$official" ]]; then
      echo "  [WARNING] Split \$split_name exists in built but not in official"
      echo "extra_in_built" > "\$OUTPUT_DIR/diff_extra_\$split_name.txt"
    fi
  done

  echo "\$total_diffs" > "\$OUTPUT_DIR/total_diffs.txt"
  echo "[Container] Total non-META-INF differences: \$total_diffs"

  # Preserve split APKs if requested
  if [[ "\$PRESERVE" == "true" ]]; then
    echo "[Container] Preserving split APKs to workspace..."
    mkdir -p "\$OUTPUT_DIR/official-splits"
    mkdir -p "\$OUTPUT_DIR/built-splits"

    echo "  Copying official split APKs..."
    cp "\$OFFICIAL_DIR"/*.apk "\$OUTPUT_DIR/official-splits/" 2>/dev/null || true

    echo "  Copying built split APKs..."
    cp /tmp/built-raw/splits/*.apk "\$OUTPUT_DIR/built-splits/" 2>/dev/null || true

    echo "[Container] Split APKs preserved:"
    echo "  Official: \$OUTPUT_DIR/official-splits/"
    echo "  Built: \$OUTPUT_DIR/built-splits/"
  fi
fi

echo "[Container] Comparison complete"
exit 0
EXTRACT_EOF

  chmod +x "$workDir/extract_and_compare.sh"
  echo "Extraction script created at: $workDir/extract_and_compare.sh"
}

# Create Dockerfile
# =================

create_dockerfile() {
  cat > "$workDir/Dockerfile" <<'DOCKERFILE_EOF'
# Bull Bitcoin Mobile Reproducible Build Dockerfile
# Modified from upstream Dockerfile for verification purposes
# v0.3.0: Repository cloned inside container using build arg
FROM --platform=linux/amd64 ubuntu:24.04

# Build argument for app version (from -v flag)
ARG VERSION=APPVERSION_PLACEHOLDER

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

# Install Android Rust targets for cross-compilation
RUN rustup target add aarch64-linux-android
RUN rustup target add armv7-linux-androideabi
RUN rustup target add x86_64-linux-android
RUN rustup target add i686-linux-android

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
RUN sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;27.0.12077973"

# Set NDK environment variables for Rust cross-compilation
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.0.12077973
ENV NDK_HOME=/opt/android-sdk/ndk/27.0.12077973

# Clean up existing app directory
RUN sudo rm -rf /app

RUN sudo mkdir /app

RUN sudo chown -R $USER /app

# Clone the Bull Bitcoin mobile repository at specified version tag
# Uses build arg VERSION (e.g., 6.1.0) -> clones v6.1.0
RUN git clone --branch v${VERSION} https://github.com/SatoshiPortal/bullbitcoin-mobile /app

WORKDIR /app

# Force cargokit to build Rust libraries from source instead of downloading precompiled binaries
# This is CRITICAL for reproducibility - precompiled binaries differ from source builds
RUN sed -i 's/use_precompiled_binaries: true/use_precompiled_binaries: false/' /app/cargokit_options.yaml

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

# Install bundletool for APK extraction (v0.2.0: moved from host to container)
RUN wget -q https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar -O /tmp/bundletool.jar

# Install apktool for APK decoding (v0.2.0: moved from host to container)
RUN sudo wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O /usr/local/bin/apktool && \
    sudo wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O /usr/local/bin/apktool.jar && \
    sudo chmod +x /usr/local/bin/apktool

# Copy extraction and comparison script (created by host, already executable)
COPY extract_and_compare.sh /app/extract_and_compare.sh
DOCKERFILE_EOF

  # Substitute app version placeholder with actual version
  sed -i "s/APPVERSION_PLACEHOLDER/${appVersion}/" "$workDir/Dockerfile"

  echo "Dockerfile created at: $workDir/Dockerfile"
}

# Build and verify in single container (v0.2.0: fully containerized)
# =====================================================================

build_and_verify() {
  echo "Building and verifying in container..."
  echo "This may take 30-60 minutes depending on system resources..."
  echo ""

  # Check system memory before starting resource-intensive build
  check_memory

  # Create both scripts
  create_extraction_script
  create_dockerfile

  cd "$workDir"

  # Build container image with memory limit to prevent OOM crashes
  echo "Building container image with Flutter + bundletool + apktool..."
  $CONTAINER_CMD build --memory=4g --no-cache --ulimit nofile=65536:65536 -t bullbitcoin-verifier:v6.1.0 .

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
      --user root \
      --memory=6g \
      --volume "$workDir":/workspace:rw \
      --volume "$apkDir":/official-apks:rw \
      bullbitcoin-verifier:v6.1.0 \
      bash -c "
        git config --global --add safe.directory /app

        # Run extraction and comparison script (github mode)
        /app/extract_and_compare.sh \
          github \
          /official-apks \
          /workspace/results \
          $appVersion \
          '' \
          $preserveSplits

        # Copy AAB to workspace for host access
        cp /app/build/app/outputs/bundle/release/app-release.aab /workspace/

        # Git verification (v0.3.0: moved from host to container)
        cd /app
        echo \"===== Git Verification =====\" > /workspace/git_verification.txt
        echo \"Commit: \$(git rev-parse HEAD)\" >> /workspace/git_verification.txt
        echo \"\" >> /workspace/git_verification.txt

        # Check if tag exists
        if git describe --exact-match --tags HEAD >/dev/null 2>&1; then
          TAG=\$(git describe --exact-match --tags HEAD)
          echo \"Tag: \$TAG\" >> /workspace/git_verification.txt

          # Check tag type
          if [ \"\$(git cat-file -t refs/tags/\$TAG)\" = \"tag\" ]; then
            echo \"Tag type: annotated\" >> /workspace/git_verification.txt
            echo \"\" >> /workspace/git_verification.txt
            git tag -v \"\$TAG\" >> /workspace/git_verification.txt 2>&1 || echo \"\\[INFO\\] Tag signature check failed or not signed\" >> /workspace/git_verification.txt
          else
            echo \"Tag type: lightweight \\(no signature possible\\)\" >> /workspace/git_verification.txt
          fi
        else
          echo \"Tag: \\(none\\)\" >> /workspace/git_verification.txt
        fi

        # Check commit signature
        echo \"\" >> /workspace/git_verification.txt
        echo \"Commit signature:\" >> /workspace/git_verification.txt
        git verify-commit HEAD >> /workspace/git_verification.txt 2>&1 || echo \"[INFO] Commit signature check failed or not signed\" >> /workspace/git_verification.txt
      "
  else
    # Device mode: needs device-spec.json
    $CONTAINER_CMD run --rm \
      --name "$container_name" \
      --user root \
      --memory=6g \
      --volume "$workDir":/workspace:rw \
      --volume "$apkDir":/official-apks:ro \
      bullbitcoin-verifier:v6.1.0 \
      bash -c "
        git config --global --add safe.directory /app

        # Run extraction and comparison script (device mode)
        /app/extract_and_compare.sh \
          device \
          /official-apks \
          /workspace/results \
          '' \
          /workspace/device-spec.json \
          $preserveSplits

        # Copy AAB to workspace for host access
        cp /app/build/app/outputs/bundle/release/app-release.aab /workspace/

        # Git verification (v0.3.0: moved from host to container)
        cd /app
        echo \"===== Git Verification =====\" > /workspace/git_verification.txt
        echo \"Commit: \$(git rev-parse HEAD)\" >> /workspace/git_verification.txt
        echo \"\" >> /workspace/git_verification.txt

        # Check if tag exists
        if git describe --exact-match --tags HEAD >/dev/null 2>&1; then
          TAG=\$(git describe --exact-match --tags HEAD)
          echo \"Tag: \$TAG\" >> /workspace/git_verification.txt

          # Check tag type
          if [ \"\$(git cat-file -t refs/tags/\$TAG)\" = \"tag\" ]; then
            echo \"Tag type: annotated\" >> /workspace/git_verification.txt
            echo \"\" >> /workspace/git_verification.txt
            git tag -v \"\$TAG\" >> /workspace/git_verification.txt 2>&1 || echo \"\\[INFO\\] Tag signature check failed or not signed\" >> /workspace/git_verification.txt
          else
            echo \"Tag type: lightweight \\(no signature possible\\)\" >> /workspace/git_verification.txt
          fi
        else
          echo \"Tag: \\(none\\)\" >> /workspace/git_verification.txt
        fi

        # Check commit signature
        echo \"\" >> /workspace/git_verification.txt
        echo \"Commit signature:\" >> /workspace/git_verification.txt
        git verify-commit HEAD >> /workspace/git_verification.txt 2>&1 || echo \"[INFO] Commit signature check failed or not signed\" >> /workspace/git_verification.txt
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
  echo "AAB artifact: $workDir/app-release.aab"
  echo "Diff files: $workDir/results/diff_*.txt"
  echo ""

  cd "$workDir"
}

# Note: extract_splits_from_aab() and compare_split_apks() functions removed in v0.2.0
# All extraction and comparison now happens inside container via extract_and_compare.sh

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
  # Read commit hash from git verification file (v0.3.0: generated in container)
  local commit=""
  if [ -f "$workDir/git_verification.txt" ]; then
    commit=$(grep "^Commit:" "$workDir/git_verification.txt" | awk '{print $2}')
  fi

  # Read aggregated diffs from results directory (created by container)
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

    # Check for special marker files without reading entire content
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
      # Add split label for device mode (multiple splits)
      if [[ "$verificationMode" == "device" ]]; then
        diff_output+="=== Split: ${split_name} ==="$'\n'
      fi

      # Count lines efficiently without loading entire file into memory
      line_count=$(wc -l < "$diff_file")

      # If diff has more than 3 lines, truncate and show reference
      if [[ $line_count -gt 3 ]]; then
        diff_output+=$(head -3 "$diff_file")$'\n'
        diff_output+="... (${line_count} total lines)"$'\n'
        diff_output+="Full diff saved to: $workDir/results/${base}"$'\n'
      else
        # Small file, safe to read entirely
        diff_output+=$(cat "$diff_file")$'\n'
      fi
    fi
  done
  shopt -u nullglob

  # Set global verdict for exit code (v0.3.0)
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
  bullbitcoin-verifier:v6.1.0 \\
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

  # Read git verification from file (v0.3.0: generated in container)
  if [ -f "$workDir/git_verification.txt" ]; then
    cat "$workDir/git_verification.txt"
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

# Determine exit code based on verdict (v0.3.0: Luis compliance)
if [[ "$verdict" == "reproducible" ]]; then
  exitCode=0
else
  exitCode=1
fi

cleanup
echo "Exit code: $exitCode"
exit $exitCode
