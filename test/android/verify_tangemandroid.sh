#!/usr/bin/env bash
# ==============================================================================
# verify_tangemandroid.sh - Tangem Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.4.1
# Author:        Daniel Garcia (dannybuntu)
# Organization:  WalletScrutiny.com
# Last Modified: 2025-10-28 (Philippine Time)
# Project:       https://github.com/tangem/tangem-app-android
# ==============================================================================
# LICENSE: MIT License
#
# Changes in v0.4.1:
# - Fixed build failure: Added Platform 35 and Build-Tools 35 to SDK install
# - Fixed SDK write permission error: chmod 777 on SDK directory for non-root access
# - Gradle can now install additional SDK components during build
#
# Changes in v0.4.0:
# - BREAKING FIX: Replaced HTML scraping with GitHub API for APK download
# - GitHub API endpoint: /repos/tangem/tangem-app-android/releases/tags/v{VERSION}
# - More reliable: GitHub API returns JSON, no HTML parsing needed
# - Better error messages: shows available assets if APK not found
# - Fallback logic: tries app-release-*.apk first, then any .apk file
#
# Changes in v0.3.2:
# - Fixed hanging download: added timeouts to curl (30s) and wget (60s)
# - Added retry logic for network operations (curl retries 2 times)
# - Added progress indicators for download steps
# - Improved error messages with troubleshooting hints
#
# Changes in v0.3.1:
# - Fixed permission error when running as non-root user
# - Added /workspace directory creation with proper permissions in Dockerfile
# - Resolves "Permission denied" errors on directory creation
#
# Changes in v0.3.0:
# - Added automatic container runtime detection: tries docker, falls back to podman
# - No longer requires manual --runtime flag when podman is available
# - Improved user experience for environments without docker
#
# Changes in v0.2.2:
# - Fixed Luis guideline #1 violation: container now runs as non-root user (--user flag)
# - Container executes with host user's UID:GID for proper file ownership
#
# Changes in v0.2.1:
# - Fixed Luis guideline #4 violation: moved apksigner dependency into container
# - Certificate extraction now uses keytool (JDK built-in) inside container
# - Removed optional host apksigner dependency completely
#
# Changes in v0.2.0:
# - Added auto-download feature: downloads universal APK from GitHub releases when -a omitted
# - Added dynamic build variant selection: assembleRelease (universal) or assembleGoogleExternalRelease (Play Store)
# - Fixed confusing GitHub token error message (now shows two separate options clearly)
# - Updated usage documentation with two methods: auto-download (recommended) vs provided APK
# - Enhanced configuration display to show current mode and build variant
#
# Changes in v0.1.0:
# - Initial containerized verification script for Tangem Wallet
# - Follows Luis script guidelines (parameters: -v version, -t type, -a apk)
# - Handles GitHub Package Registry authentication requirement (read:packages scope)
# - Outputs standardized WalletScrutiny result format
# - Supports Docker/Podman for reproducible builds
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
# - Auto-downloads universal APK from GitHub releases, or uses APK provided via -a flag
# - Clones source code repository and checks out the specified version tag
# - Performs containerized reproducible build using Gradle (requires GitHub token with read:packages)
# - Builds matching variant: universal APK (GitHub releases) or Play Store variant (device APK)
# - Compares built APK against official release using apktool and binary analysis
# - Documents differences and generates detailed reproducibility assessment report
#
# IMPORTANT REQUIREMENT:
# This script requires a GitHub Personal Access Token with 'read:packages' scope
# to access dependencies from GitHub Package Registry. Set via environment variable:
#   export GITHUB_TOKEN="ghp_your_token_here"
# Or the script will prompt you to create one during execution.

set -euo pipefail

# ================================
# Configuration
# ================================
APP_ID="com.tangem.wallet"
APP_NAME="Tangem Wallet"
REPO_URL="https://github.com/tangem/tangem-app-android"

# ================================
# Color Output (for terminal only)
# ================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

# ================================
# Usage
# ================================
usage() {
  cat <<EOF
Usage: $0 -v <version> [-t <type>] [-a <apk_path>] [options]

Required:
  -v <version>       Version to verify (e.g., 5.29.2)

Optional (Luis guidelines):
  -t <type>          App type (optional, for framework compatibility)
  -a <apk_path>      Path to official APK from device/Play Store
                     If omitted, downloads universal APK from GitHub releases

Additional options:
  --output <dir>     Output directory (default: ./tangem-<version>-verification)
  --runtime <cmd>    Container runtime (default: docker, can use: podman)
  --github-token <token>  GitHub Personal Access Token (or set GITHUB_TOKEN env var)
  --github-user <user>    GitHub username (or set GITHUB_USER env var)
  --help             Show this help message

Environment Variables:
  GITHUB_TOKEN       Personal Access Token with 'read:packages' scope (REQUIRED)
  GITHUB_USER        GitHub username (defaults to 'walletscrutiny')
  CONTAINER_RUNTIME  Container runtime command (docker or podman)

Examples:
  # Method 1: Download universal APK from GitHub releases (recommended)
  export GITHUB_TOKEN="ghp_your_token_here"
  $0 -v 5.29.2

  # Method 2: Use APK from device/Play Store
  adb pull \$(adb shell pm path $APP_ID | cut -d: -f2) tangem-official.apk
  export GITHUB_TOKEN="ghp_your_token_here"
  $0 -v 5.29.2 -a tangem-official.apk

Note: GitHub token creation: https://github.com/settings/tokens
      Required scope: read:packages
EOF
}

# ================================
# Parse Arguments
# ================================
VERSION=""
APP_TYPE=""
OFFICIAL_APK_INPUT=""
OUTPUT_DIR=""
RUNTIME_OVERRIDE=""
GITHUB_TOKEN_ARG=""
GITHUB_USER_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    -v)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: -v requires a value${NC}" >&2; exit 1; }
      VERSION="$2"
      shift 2
      ;;
    -t)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: -t requires a value${NC}" >&2; exit 1; }
      APP_TYPE="$2"
      shift 2
      ;;
    -a)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: -a requires a value${NC}" >&2; exit 1; }
      OFFICIAL_APK_INPUT="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: --output requires a value${NC}" >&2; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --runtime)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: --runtime requires a value${NC}" >&2; exit 1; }
      RUNTIME_OVERRIDE="$2"
      shift 2
      ;;
    --github-token)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: --github-token requires a value${NC}" >&2; exit 1; }
      GITHUB_TOKEN_ARG="$2"
      shift 2
      ;;
    --github-user)
      [[ $# -ge 2 ]] || { echo -e "${RED}Error: --github-user requires a value${NC}" >&2; exit 1; }
      GITHUB_USER_ARG="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}" >&2
      usage
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$VERSION" ]]; then
  echo -e "${RED}Error: -v <version> is required${NC}" >&2
  usage
  exit 1
fi

# Set GitHub credentials
GITHUB_TOKEN="${GITHUB_TOKEN_ARG:-${GITHUB_TOKEN:-}}"
GITHUB_USER="${GITHUB_USER_ARG:-${GITHUB_USER:-walletscrutiny}}"

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo -e "${RED}Error: GitHub Personal Access Token required${NC}" >&2
  echo ""
  echo "Tangem Wallet build requires GitHub Package Registry authentication."
  echo "Please create a token with 'read:packages' scope at:"
  echo "  https://github.com/settings/tokens"
  echo ""
  echo "Then provide it using either method:"
  echo ""
  echo "Option 1 - Environment variable:"
  echo "  export GITHUB_TOKEN=\"ghp_your_token_here\""
  echo "  $0 -v $VERSION"
  echo ""
  echo "Option 2 - Command-line argument:"
  echo "  $0 -v $VERSION --github-token \"ghp_your_token_here\""
  exit 1
fi

# Handle official APK: download from GitHub releases or use provided path
DOWNLOAD_OFFICIAL=false
if [[ -n "$OFFICIAL_APK_INPUT" ]]; then
  if [[ ! -f "$OFFICIAL_APK_INPUT" ]]; then
    echo -e "${RED}Error: Official APK not found at '$OFFICIAL_APK_INPUT'${NC}" >&2
    exit 1
  fi
  OFFICIAL_APK_PATH="$(realpath "$OFFICIAL_APK_INPUT")"
  echo "Using provided APK: $OFFICIAL_APK_PATH"
else
  echo -e "${CYAN}No APK provided via -a flag${NC}"
  echo "Will download universal APK from GitHub releases:"
  echo "  https://github.com/tangem/tangem-app-android/releases/tag/v${VERSION}"
  DOWNLOAD_OFFICIAL=true
fi

# Set output directory
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pwd)/tangem-${VERSION}-verification"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"

# Set container runtime - auto-detect docker or podman
if [[ -n "$RUNTIME_OVERRIDE" ]]; then
  # User explicitly specified runtime
  CONTAINER_RUNTIME="$RUNTIME_OVERRIDE"
elif [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
  # Environment variable set
  CONTAINER_RUNTIME="${CONTAINER_RUNTIME}"
elif command -v docker >/dev/null 2>&1; then
  # Docker available
  CONTAINER_RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
  # Podman available (fallback)
  CONTAINER_RUNTIME="podman"
else
  # Neither found
  echo -e "${RED}Error: No container runtime found${NC}" >&2
  echo "Please install Docker or Podman"
  echo ""
  echo "To install Podman (no root required):"
  echo "  sudo apt-get install -y podman"
  exit 1
fi

# Verify chosen runtime actually works
if ! command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
  echo -e "${RED}Error: Container runtime '$CONTAINER_RUNTIME' not found${NC}" >&2
  exit 1
fi

# ================================
# Display Configuration
# ================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Tangem Wallet Verification Script v0.4.1${NC}"
echo -e "${CYAN}========================================${NC}"
echo "App ID:           $APP_ID"
echo "Version:          $VERSION"
if [[ "$DOWNLOAD_OFFICIAL" == "true" ]]; then
  echo "Mode:             Auto-download from GitHub releases"
  echo "Build Variant:    assembleRelease (universal APK)"
else
  echo "Mode:             Using provided APK"
  echo "Official APK:     $OFFICIAL_APK_PATH"
  echo "Build Variant:    assembleGoogleExternalRelease (Play Store)"
fi
echo "Container:        $CONTAINER_RUNTIME"
echo "Output Directory: $OUTPUT_DIR"
echo "GitHub User:      $GITHUB_USER"
echo "GitHub Token:     ${GITHUB_TOKEN:0:10}... (hidden)"
echo -e "${CYAN}========================================${NC}"
echo ""

# ================================
# Create Temporary Build Directory
# ================================
TMP_BUILD_DIR="$(mktemp -d -t tangem-container-XXXXXXXX)"
cleanup() {
  rm -rf "$TMP_BUILD_DIR"
}
trap cleanup EXIT

DOCKERFILE_PATH="$TMP_BUILD_DIR/Dockerfile"
ENTRYPOINT_PATH="$TMP_BUILD_DIR/entrypoint.sh"

# ================================
# Create Dockerfile
# ================================
cat <<'DOCKERFILE' >"$DOCKERFILE_PATH"
FROM docker.io/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${JAVA_HOME}/bin:${PATH}"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk \
    wget \
    unzip \
    git \
    curl \
    ca-certificates \
    apktool \
    && rm -rf /var/lib/apt/lists/*

# Install Android SDK
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools && \
    mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest && \
    rm /tmp/sdk.zip

# Accept licenses and install SDK components
RUN yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" \
               "platforms;android-35" "build-tools;35.0.0" && \
    chmod -R 777 ${ANDROID_SDK_ROOT}

COPY entrypoint.sh /usr/local/bin/tangem-entrypoint
RUN chmod +x /usr/local/bin/tangem-entrypoint

# Create workspace directory with write permissions for non-root users
RUN mkdir -p /workspace && chmod 777 /workspace

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/tangem-entrypoint"]
DOCKERFILE

# ================================
# Create Entrypoint Script
# ================================
cat <<'ENTRYPOINT' >"$ENTRYPOINT_PATH"
#!/usr/bin/env bash
set -euo pipefail

# Environment variables passed from host
TANGEM_VERSION="${TANGEM_VERSION:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_USER="${GITHUB_USER:-}"
DOWNLOAD_OFFICIAL="${DOWNLOAD_OFFICIAL:-false}"

if [[ -z "$TANGEM_VERSION" ]]; then
  echo "Error: TANGEM_VERSION environment variable required" >&2
  exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Error: GITHUB_TOKEN environment variable required" >&2
  exit 1
fi

# Directories
REPO_DIR="/workspace/tangem-app-android"
OUTPUT_DIR="/workspace/output"
OFFICIAL_DIR="/workspace/official"
DECODE_DIR="/workspace/decoded"

mkdir -p "$OUTPUT_DIR" "$OFFICIAL_DIR" "$DECODE_DIR"

# Download official APK from GitHub releases if needed
if [[ "$DOWNLOAD_OFFICIAL" == "true" ]]; then
  echo "[1/7] Downloading official APK from GitHub releases..."

  # Use GitHub API to get release info (more reliable than HTML scraping)
  API_URL="https://api.github.com/repos/tangem/tangem-app-android/releases/tags/v${TANGEM_VERSION}"
  echo "  Fetching release info from GitHub API..."
  echo "  API URL: $API_URL"

  RELEASE_JSON=$(curl -sL --max-time 30 --retry 2 "$API_URL" 2>&1)
  CURL_EXIT=$?

  if [[ $CURL_EXIT -ne 0 ]]; then
    echo "Error: Failed to fetch release info from GitHub API (curl exit code: $CURL_EXIT)" >&2
    echo "URL: $API_URL" >&2
    echo "This might be a network issue or GitHub rate limiting" >&2
    exit 1
  fi

  # Check if release exists (API returns 404 message in JSON)
  if echo "$RELEASE_JSON" | grep -q "Not Found"; then
    echo "Error: Release v${TANGEM_VERSION} not found" >&2
    echo "API URL: $API_URL" >&2
    exit 1
  fi

  # Extract APK download URL from JSON (search for .apk files in assets)
  echo "  Extracting APK download URL from release assets..."

  # Try to find app-release-*.apk pattern first
  APK_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url":[[:space:]]*"[^"]*app-release[^"]*\.apk"' | grep -o 'https://[^"]*' | head -1)

  # If not found, try any .apk file
  if [[ -z "$APK_URL" ]]; then
    APK_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url":[[:space:]]*"[^"]*\.apk"' | grep -o 'https://[^"]*' | head -1)
  fi

  if [[ -z "$APK_URL" ]]; then
    echo "Error: Could not find APK download URL in release v${TANGEM_VERSION}" >&2
    echo "API URL: $API_URL" >&2
    echo "This might mean:" >&2
    echo "  - The release doesn't have an APK asset" >&2
    echo "  - The release might use AAB instead of APK" >&2
    echo "" >&2
    echo "Available assets in this release:" >&2
    echo "$RELEASE_JSON" | grep -o '"name":[[:space:]]*"[^"]*"' | head -10 >&2
    exit 1
  fi

  echo "  Found APK: $APK_URL"
  echo "  Downloading APK (this may take a few minutes)..."
  wget --timeout=60 --tries=3 --show-progress -O "$OFFICIAL_DIR/tangem-official.apk" "$APK_URL" 2>&1

  if [[ ! -f "$OFFICIAL_DIR/tangem-official.apk" ]]; then
    echo "Error: Failed to download APK" >&2
    exit 1
  fi

  echo "  Downloaded: $(du -h "$OFFICIAL_DIR/tangem-official.apk" | cut -f1)"
  STEP_NUM=2
else
  STEP_NUM=1
fi

echo "[${STEP_NUM}/7] Cloning Tangem repository..."
git clone --depth 1 --branch "master" https://github.com/tangem/tangem-app-android "$REPO_DIR"
cd "$REPO_DIR"
STEP_NUM=$((STEP_NUM + 1))

# Check for version tag
echo "[${STEP_NUM}/7] Checking for version tag v${TANGEM_VERSION}..."
git fetch --tags --depth 1
if git rev-parse "v${TANGEM_VERSION}" >/dev/null 2>&1; then
  echo "Found tag v${TANGEM_VERSION}, checking out..."
  git checkout "v${TANGEM_VERSION}"
elif git rev-parse "${TANGEM_VERSION}" >/dev/null 2>&1; then
  echo "Found tag ${TANGEM_VERSION}, checking out..."
  git checkout "${TANGEM_VERSION}"
else
  echo "Warning: No tag found for version ${TANGEM_VERSION}, using master branch"
fi

COMMIT_HASH=$(git rev-parse HEAD)
echo "Building from commit: $COMMIT_HASH"
STEP_NUM=$((STEP_NUM + 1))

# Configure GitHub Package Registry credentials
echo "[${STEP_NUM}/7] Configuring GitHub Package Registry credentials..."
cat > local.properties <<EOF
sdk.dir=${ANDROID_SDK_ROOT}
gpr.user=${GITHUB_USER}
gpr.key=${GITHUB_TOKEN}
EOF
STEP_NUM=$((STEP_NUM + 1))

# Make gradlew executable
chmod +x gradlew

# Build universal APK (assembleRelease) when downloading official, or googleExternalRelease when using -a flag
BUILD_TASK="assembleRelease"
if [[ "$DOWNLOAD_OFFICIAL" == "true" ]]; then
  echo "[${STEP_NUM}/7] Building universal APK (assembleRelease)..."
  APK_SEARCH_PATTERN="release.*\.apk$"
else
  echo "[${STEP_NUM}/7] Building Play Store variant (assembleGoogleExternalRelease)..."
  BUILD_TASK="assembleGoogleExternalRelease"
  APK_SEARCH_PATTERN="google.*external.*release"
fi

echo "This may take 15-30 minutes depending on system resources..."
./gradlew clean
./gradlew "$BUILD_TASK" --no-daemon --stacktrace
STEP_NUM=$((STEP_NUM + 1))

# Find built APK
echo "[${STEP_NUM}/7] Locating built APK..."
BUILT_APK=$(find app/build/outputs/apk -name "*.apk" -type f | grep -iE "$APK_SEARCH_PATTERN" | grep -v "unsigned" | head -1)

if [[ -z "$BUILT_APK" ]]; then
  echo "Error: Could not find built APK" >&2
  echo "Searching all APKs:" >&2
  find app/build/outputs/apk -name "*.apk" -type f
  exit 1
fi

echo "Built APK: $BUILT_APK"
cp "$BUILT_APK" "$OUTPUT_DIR/tangem-built.apk"
STEP_NUM=$((STEP_NUM + 1))

# Decode APKs for comparison and extract certificate
echo "[${STEP_NUM}/7] Decoding APKs for comparison..."
if [[ -f "$OFFICIAL_DIR/tangem-official.apk" ]]; then
  apktool d "$OFFICIAL_DIR/tangem-official.apk" -o "$DECODE_DIR/official" -f
  apktool d "$OUTPUT_DIR/tangem-built.apk" -o "$DECODE_DIR/built" -f

  # Extract signer certificate SHA-256 from official APK
  if command -v keytool >/dev/null 2>&1; then
    CERT_FILE=$(find "$DECODE_DIR/official/original/META-INF" -name "*.RSA" -o -name "*.DSA" -o -name "*.EC" 2>/dev/null | head -1)
    if [[ -n "$CERT_FILE" ]]; then
      SIGNER_HASH=$(keytool -printcert -file "$CERT_FILE" 2>/dev/null | grep "SHA256:" | awk '{print $2}' | tr -d ':' | tr '[:upper:]' '[:lower:]')
      echo "$SIGNER_HASH" > "$OUTPUT_DIR/signer-hash.txt"
    fi
  fi

  echo ""
  echo "Comparison complete. APKs decoded at:"
  echo "  Official: $DECODE_DIR/official"
  echo "  Built:    $DECODE_DIR/built"
else
  echo "Warning: No official APK provided for comparison"
fi

# Save commit hash
echo "$COMMIT_HASH" > "$OUTPUT_DIR/commit-hash.txt"

echo ""
echo "Build completed successfully!"
echo "Artifacts saved to: $OUTPUT_DIR"
ENTRYPOINT

chmod +x "$ENTRYPOINT_PATH"

# ================================
# Build Container Image
# ================================
echo -e "${CYAN}[Host] Building container image...${NC}"
IMAGE_NAME="tangem-verify:${VERSION}"

$CONTAINER_RUNTIME build -t "$IMAGE_NAME" "$TMP_BUILD_DIR"

if [[ $? -ne 0 ]]; then
  echo -e "${RED}Error: Failed to build container image${NC}" >&2
  exit 1
fi

# ================================
# Run Container Build
# ================================
echo -e "${CYAN}[Host] Running containerized build...${NC}"

CONTAINER_ARGS=(
  run
  --rm
  --user "$(id -u):$(id -g)"
  -e "TANGEM_VERSION=${VERSION}"
  -e "GITHUB_TOKEN=${GITHUB_TOKEN}"
  -e "GITHUB_USER=${GITHUB_USER}"
  -e "DOWNLOAD_OFFICIAL=${DOWNLOAD_OFFICIAL}"
  -v "${OUTPUT_DIR}:/workspace/output"
)

# Mount official APK if provided via -a flag
if [[ -n "$OFFICIAL_APK_INPUT" ]]; then
  CONTAINER_ARGS+=(-v "${OFFICIAL_APK_PATH}:/workspace/official/tangem-official.apk:ro")
fi

CONTAINER_ARGS+=("$IMAGE_NAME")

$CONTAINER_RUNTIME "${CONTAINER_ARGS[@]}"

if [[ $? -ne 0 ]]; then
  echo -e "${RED}Error: Container build failed${NC}" >&2
  exit 1
fi

# ================================
# Extract Metadata and Compare
# ================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Verification Results${NC}"
echo -e "${CYAN}========================================${NC}"

BUILT_APK="${OUTPUT_DIR}/tangem-built.apk"
COMMIT_HASH=$(cat "${OUTPUT_DIR}/commit-hash.txt")

if [[ ! -f "$BUILT_APK" ]]; then
  echo -e "${RED}Error: Built APK not found${NC}" >&2
  exit 1
fi

# Get APK metadata using apktool (if built APK exists in decoded form)
DECODED_BUILT="${OUTPUT_DIR}/decoded/built"
if [[ -d "$DECODED_BUILT" ]]; then
  VERSION_NAME=$(grep "versionName:" "$DECODED_BUILT/apktool.yml" | awk '{print $2}' | tr -d "'\"")
  VERSION_CODE=$(grep "versionCode:" "$DECODED_BUILT/apktool.yml" | awk '{print $2}' | tr -d "'\"")
else
  VERSION_NAME="$VERSION"
  VERSION_CODE="unknown"
fi

# Calculate hashes
BUILT_HASH=$(sha256sum "$BUILT_APK" | awk '{print $1}')

OFFICIAL_HASH=""
if [[ -n "$OFFICIAL_APK_INPUT" ]]; then
  OFFICIAL_HASH=$(sha256sum "$OFFICIAL_APK_PATH" | awk '{print $1}')
fi

# Perform diff if both APKs are decoded
DECODED_OFFICIAL="${OUTPUT_DIR}/decoded/official"
DIFF_OUTPUT=""
VERDICT=""

if [[ -d "$DECODED_OFFICIAL" && -d "$DECODED_BUILT" ]]; then
  echo "Running diff comparison..."
  DIFF_OUTPUT=$(diff --brief --recursive "$DECODED_OFFICIAL" "$DECODED_BUILT" 2>&1 || true)

  # Count non-META-INF differences
  DIFF_COUNT=0
  if [[ -n "$DIFF_OUTPUT" ]]; then
    DIFF_COUNT=$(echo "$DIFF_OUTPUT" | grep -vcE "(META-INF|^$)" || true)
  fi

  if [[ $DIFF_COUNT -eq 0 ]]; then
    VERDICT="reproducible"
  else
    VERDICT="differences found"
  fi
else
  DIFF_OUTPUT="(No official APK provided for comparison)"
  VERDICT=""
fi

# Get signer certificate (extracted in container)
SIGNER_HASH="N/A"
if [[ -f "${OUTPUT_DIR}/signer-hash.txt" ]]; then
  SIGNER_HASH=$(cat "${OUTPUT_DIR}/signer-hash.txt")
fi

# ================================
# Output Standardized Results
# ================================
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${SIGNER_HASH:-N/A}"
echo "apkVersionName: ${VERSION_NAME}"
echo "apkVersionCode: ${VERSION_CODE}"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${OFFICIAL_HASH:-N/A}"
echo "commit:         ${COMMIT_HASH}"
echo ""
echo "Diff:"
echo "$DIFF_OUTPUT"
echo ""
echo "Revision, tag (and its signature):"
echo "Commit: ${COMMIT_HASH}"
echo "(Tag signature verification not implemented in this version)"
echo ""
echo "===== End Results ====="

if [[ -d "$DECODED_OFFICIAL" && -d "$DECODED_BUILT" ]]; then
  echo ""
  echo "Run a full"
  echo "diff --recursive ${DECODED_OFFICIAL} ${DECODED_BUILT}"
  echo "meld ${DECODED_OFFICIAL} ${DECODED_BUILT}"
  echo "or"
  echo "diffoscope \"${OFFICIAL_APK_PATH}\" ${BUILT_APK}"
  echo "for more details."
fi

# ================================
# Summary
# ================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo "Built APK:     $BUILT_APK"
echo "Built Hash:    $BUILT_HASH"
if [[ -n "$OFFICIAL_APK_INPUT" ]]; then
  echo "Official APK:  $OFFICIAL_APK_PATH"
  echo "Official Hash: $OFFICIAL_HASH"

  if [[ "$BUILT_HASH" == "$OFFICIAL_HASH" ]]; then
    echo -e "${GREEN}✓ APKs are IDENTICAL (binary match)${NC}"
    exit 0
  else
    echo -e "${YELLOW}⚠ APKs differ${NC}"
    if [[ "$VERDICT" == "reproducible" ]]; then
      echo -e "${GREEN}✓ Verdict: REPRODUCIBLE (only signatures differ)${NC}"
      exit 0
    else
      echo -e "${RED}✗ Verdict: NON-REPRODUCIBLE (content differences found)${NC}"
      exit 1
    fi
  fi
else
  echo "No official APK provided - build completed successfully"
  echo "Extract official APK and rerun for comparison"
fi

exit 0
