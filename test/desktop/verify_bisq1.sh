#!/bin/bash

# Bisq Reproducible Build Verification Tool
#
# Version: 3.4.0
# Last Updated: 2025-10-10
#
# Changelog:
# v3.4.0 - Removed docker system prune, infinite loops; script now exits cleanly (2025-10-10)
# v3.3.0 - Added Java 17 for jpackage support, improved fallback logic (2025-10-10)
# v3.2.0 - Accept version with or without 'v' prefix (1.9.21 or v1.9.21) (2025-10-10)
# v3.1.0 - Changed default mode to 'build' for correct workflow (2025-10-10)
# v3.0.1 - Removed emojis and verbose output for cleaner terminal display (2025-10-10)
# v3.0.0 - Added --build-path parameter for portable path configuration (2025-10-10)
# v2.0.1 - Renamed from verify_bisqdesktop.sh to verify_bisq1.sh (2025-10-10)
# v1.4 - Added detailed file difference analysis and terminal output transparency (2025-09-06)
# v1.3 - Added container inspection + fixed extraction paths (2025-08-27)
# v1.2 - Added manual jpackage fallback (2025-08-27)
# v1.1 - Added RPM support (2025-08-27)

set -euo pipefail # Enhanced error handling
# set -x     # Debug mode - show all commands as they execute

VERSION="3.4.0"

# Cleanup function for interruptions
cleanup_on_exit() {
  echo ""
  echo "Cleaning up..."

  # Clean up container if it exists
  if [[ -n "${CONTAINER_ID:-}" ]]; then
   docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
   docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  # Clean up temporary files
  rm -f "$SCRIPT_DIR/.dockerfile-temp" "$SCRIPT_DIR/verify-container.sh" 2>/dev/null || true
}

# Set up cleanup on script exit (including interruption)
trap cleanup_on_exit EXIT INT TERM
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
IMAGE_NAME="bisq-verify"

# Color codes
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# Configuration
BUILD_PATH=""
DEFAULT_BUILD_PATH="$HOME/builds/desktop/bisq1-build"
BISQ_VERSION=""
MODE=${MODE:-build} # 'build' or 'verify' - default is build then verify

show_help() {
  cat << EOF
Bisq Build Reproducibility Verification Tool v$VERSION

USAGE:
  ./verify_bisq1.sh [OPTIONS] [VERSION] [MODE]

OPTIONS:
  --build-path PATH  Specify build directory path
        (default: $DEFAULT_BUILD_PATH)
  -h, --help    Show this help message

MODES:
  build - Full build + verification (default, ~30 min)
  verify - Verification only using existing .deb files (~2 min)

EXAMPLES:
  ./verify_bisq1.sh
   # Build and verify v1.9.21 (default)

  ./verify_bisq1.sh v1.9.20
   # Build and verify v1.9.20

  ./verify_bisq1.sh --build-path ~/my-builds/bisq
   # Build and verify using custom build path

  ./verify_bisq1.sh v1.9.21 verify
   # Verify only (requires existing .deb files)

  ./verify_bisq1.sh --build-path /custom/path v1.9.21
   # Build and verify v1.9.21 using custom path

ENVIRONMENT:
  BISQ_VERSION - Version to verify (default: v1.9.21)
  MODE   - Operation mode: 'build' or 'verify' (default: build)

BUILD PATH STRUCTURE:
  If --build-path is not specified, the script will create and use:
   $DEFAULT_BUILD_PATH

  For verify mode, this directory should contain:
   bisq/desktop/build/packaging/jpackage/packages/bisq_*-1_amd64.deb
   bisq-official-comparison/Bisq-64bit-*.deb

RESULTS:
  All outputs saved to: $RESULTS_DIR/
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
   -h|--help)
    show_help
    exit 0
    ;;
   --build-path)
    if [[ -n "${2:-}" ]] && [[ "$2" != -* ]]; then
      BUILD_PATH="$2"
      shift 2
    else
      echo "Error: --build-path requires a path argument"
      exit 1
    fi
    ;;
   --build-path=*)
    BUILD_PATH="${1#*=}"
    shift
    ;;
   build|verify)
    MODE="$1"
    shift
    ;;
   v*.*.*)
    BISQ_VERSION="$1"
    shift
    ;;
   [0-9]*.[0-9]*.[0-9]*)
    # Version without 'v' prefix - add it
    BISQ_VERSION="v$1"
    shift
    ;;
   *)
    echo "Unknown argument: $1"
    show_help
    exit 1
    ;;
  esac
done

# Set default build path if not specified
if [[ -z "$BUILD_PATH" ]]; then
  BUILD_PATH="$DEFAULT_BUILD_PATH"
  echo -e "${CYAN}No --build-path specified. Using default: $BUILD_PATH${NC}"
  echo -e "${CYAN}Creating directory if it doesn't exist...${NC}"
  mkdir -p "$BUILD_PATH"
  echo ""
fi

# Set default version if not specified
if [[ -z "$BISQ_VERSION" ]]; then
  BISQ_VERSION="v1.9.21"
fi

# Ensure version has 'v' prefix
if [[ ! "$BISQ_VERSION" =~ ^v ]]; then
  BISQ_VERSION="v$BISQ_VERSION"
fi

# Validate build path
if [[ ! -d "$BUILD_PATH" ]]; then
  echo "Error: Build path does not exist: $BUILD_PATH"
  echo "Please create it or specify a different path with --build-path"
  exit 1
fi

# Convert to absolute path
BUILD_PATH="$(cd "$BUILD_PATH" && pwd)"

echo "Bisq Build Reproducibility Tool v$VERSION"
echo "=========================================="
echo "Version: $BISQ_VERSION"
echo "Mode: $MODE"
echo "Build Path: $BUILD_PATH"
echo "Results: $RESULTS_DIR"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Comprehensive cleanup
echo "Cleaning environment..."

# Clean up any hung Docker containers only
echo "Removing previous containers..."
# Only kill Docker containers, not this script
docker ps -q --filter ancestor=bisq-verify | xargs -r docker kill 2>/dev/null || true

# Clean temporary directories
echo "Cleaning temp directories..."
rm -rf /tmp/manual-verify* 2>/dev/null || true
rm -rf /tmp/official-only.txt /tmp/local-only.txt 2>/dev/null || true

# Clean Docker environment
echo "Cleaning Docker..."
# Stop and remove any running containers with our image
docker ps -q --filter ancestor="$IMAGE_NAME" | xargs -r docker stop 2>/dev/null || true
docker ps -aq --filter ancestor="$IMAGE_NAME" | xargs -r docker rm 2>/dev/null || true

# Remove old Docker image
if docker images -q "$IMAGE_NAME" >/dev/null 2>&1; then
  docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
fi

# Clean previous results to avoid contamination
echo "Cleaning results..."
rm -f "$RESULTS_DIR"/*.txt 2>/dev/null || true
rm -f "$RESULTS_DIR"/*.log 2>/dev/null || true

# Clean up any leftover temporary files from previous runs
echo "Cleaning temp files..."
rm -f "$SCRIPT_DIR"/.dockerfile-temp "$SCRIPT_DIR"/verify-container.sh 2>/dev/null || true

# Ensure clean results directory
mkdir -p "$RESULTS_DIR"

echo "Cleanup complete"

# Check Docker
echo "Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker not found"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon not running"
  exit 1
fi
echo "Docker OK"

# Build Docker image
echo "Building Docker image..."
cat > "$SCRIPT_DIR/.dockerfile-temp" << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
  git wget curl unzip tar xz-utils zstd binutils \
  openjdk-11-jdk openjdk-17-jdk \
  ca-certificates ca-certificates-java fakeroot dpkg-dev \
  build-essential debhelper rpm \
  libx11-6 libxext6 libxrender1 libxtst6 libxi6 libxrandr2 libxcb1 libxau6 \
  xvfb x11-apps \
  && rm -rf /var/lib/apt/lists/* \
  && update-ca-certificates \
  && useradd -m -s /bin/bash bisq

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV JAVA_17_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH
ENV GRADLE_OPTS="-Xmx4g -Dorg.gradle.daemon=false"

USER bisq
WORKDIR /home/bisq

COPY --chown=bisq:bisq verify-container.sh /home/bisq/
RUN chmod +x /home/bisq/verify-container.sh

CMD ["/home/bisq/verify-container.sh"]
DOCKERFILE

# Create container verification script
cat > "$SCRIPT_DIR/verify-container.sh" << 'CONTAINER_SCRIPT'
#!/bin/bash

set -euo pipefail # Enhanced error handling
set -x     # Debug mode - show all commands as they execute

# Ensure output is not buffered
export PYTHONUNBUFFERED=1
stty -icanon min 1 time 0 2>/dev/null || true # Set terminal to immediate mode
exec 1> >(stdbuf -oL cat) # Line buffer stdout
exec 2> >(stdbuf -oL cat >&2) # Line buffer stderr

echo "=== Bisq Container Verification ==="
echo "Version: ${BISQ_VERSION:-v1.9.21}"
echo "Mode: ${MODE:-build}" 
echo "Java: $(java -version 2>&1 | head -1)"
echo ""

BISQ_VERSION=${BISQ_VERSION:-v1.9.21}
MODE=${MODE:-build}
WORK_DIR="/home/bisq/work"
RESULTS_DIR="/home/bisq/build-results"

mkdir -p "$WORK_DIR" "$RESULTS_DIR"
cd "$WORK_DIR"

if [[ "$MODE" == "build" ]]; then
  echo "BUILD MODE"
  echo ""
  
  echo "Cloning repository..."
  git clone --progress https://github.com/bisq-network/bisq.git
  cd bisq
  echo "Clone complete"
  
  echo "Checking out version..."
  git checkout "$BISQ_VERSION"
  echo "Checkout complete: $(git describe --tags)"
  
  echo "Downloading official release..."
  cd "$WORK_DIR"
  wget --progress=bar:force "https://github.com/bisq-network/bisq/releases/download/${BISQ_VERSION}/Bisq-64bit-${BISQ_VERSION#v}.deb"
  echo "Download complete"
  
  echo "Building (20+ min)..."
  cd bisq
  ./gradlew clean build -x test
  
  echo "Creating package..."
  ./gradlew desktop:generateInstallers
  echo "Build complete"
  
  echo ""
  echo "Checking build output..."
  find desktop/build -name "*.deb" -o -name "*.rpm" -o -name "*.dmg" -o -name "*.exe" -o -name "*bisq*" | head -10
  
  LOCAL_DEB=$(find desktop/build/packaging/jpackage/packages -name "bisq_*-1_amd64.deb" | head -1)
  if [[ -n "$LOCAL_DEB" ]]; then
   LOCAL_DEB=$(realpath "$LOCAL_DEB")
  fi
  OFFICIAL_DEB="$WORK_DIR/Bisq-64bit-${BISQ_VERSION#v}.deb"
  
  if [[ -z "$LOCAL_DEB" ]]; then
   echo "Gradle task did not create .deb file, trying manual jpackage..."
   echo "Available build artifacts:"
   find desktop/build -type f | grep -E "\.(deb|rpm|jar)$" | head -10

   # Try multiple jpackage locations in order of preference
   JPACKAGE_PATH=""

   # 1. Try Java 17 from system
   if [[ -x "$JAVA_17_HOME/bin/jpackage" ]]; then
    JPACKAGE_PATH="$JAVA_17_HOME/bin/jpackage"
    echo "Using system Java 17 jpackage"
   # 2. Try Gradle toolchain (Java 17)
   elif [[ -n "$(find /home/bisq/.gradle/jdks -name "jpackage" -path "*17*/bin/jpackage" 2>/dev/null | head -1)" ]]; then
    JPACKAGE_PATH=$(find /home/bisq/.gradle/jdks -name "jpackage" -path "*17*/bin/jpackage" | head -1)
    echo "Using Gradle toolchain jpackage: $JPACKAGE_PATH"
   # 3. Try Gradle toolchain (Java 16)
   elif [[ -n "$(find /home/bisq/.gradle/jdks -name "jpackage" -path "*16*/bin/jpackage" 2>/dev/null | head -1)" ]]; then
    JPACKAGE_PATH=$(find /home/bisq/.gradle/jdks -name "jpackage" -path "*16*/bin/jpackage" | head -1)
    echo "Using Gradle toolchain jpackage: $JPACKAGE_PATH"
   else
    echo "ERROR: Could not find jpackage (requires Java 16+)"
    echo "Checked:"
    echo " - $JAVA_17_HOME/bin/jpackage"
    echo " - /home/bisq/.gradle/jdks/*/bin/jpackage"
    exit 1
   fi

   echo "Running manual jpackage..."
   mkdir -p desktop/build/packaging/jpackage/packages

   # Run manual jpackage command
   "$JPACKAGE_PATH" \
    --dest desktop/build/packaging/jpackage/packages \
    --name Bisq \
    --app-version ${BISQ_VERSION#v} \
    --input desktop/build/app/lib \
    --main-jar desktop.jar \
    --main-class bisq.desktop.app.BisqAppMain \
    --type deb \
    --verbose
   
   # Check if manual jpackage succeeded
   LOCAL_DEB=$(find desktop/build/packaging/jpackage/packages -name "bisq_*-1_amd64.deb" | head -1)
   if [[ -z "$LOCAL_DEB" ]]; then
    echo " ERROR: Manual jpackage also failed to create .deb file"
    exit 1
   fi
   # Convert to absolute path for extraction
   LOCAL_DEB=$(realpath "$LOCAL_DEB")
   echo "Manual build succeeded"
  fi
  
else
  echo "VERIFY MODE"
  echo ""
  
  echo "Finding files..."
  LOCAL_DEB=$(find /home/bisq/host-bisq -name "bisq_*-1_amd64.deb" -path "*/desktop/build/packaging/jpackage/packages/*" | head -1)
  OFFICIAL_DEB=$(find /home/bisq/host-bisq -name "Bisq-64bit-*.deb" | head -1)
  
  if [[ ! -f "$LOCAL_DEB" ]] || [[ ! -f "$OFFICIAL_DEB" ]]; then
   echo " ERROR: Required .deb files not found"
   echo "Local: $LOCAL_DEB"
   echo "Official: $OFFICIAL_DEB"
   exit 1
  fi
  echo "Files found"
fi

echo ""
echo "Comparing:"
echo " Local: $(basename "$LOCAL_DEB")"
echo " Official: $(basename "$OFFICIAL_DEB")"
echo ""

echo "Extracting packages..."
EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$EXTRACT_DIR"/{official,local,jars/{official,local}}

# Extract official
echo "Extracting official..."
cd "$EXTRACT_DIR/official"
echo ""
echo ""
ar -x "$OFFICIAL_DEB"
if [[ -f data.tar.xz ]]; then
  tar -xJf data.tar.xz
  echo ""
elif [[ -f data.tar.zst ]]; then
  tar --zstd -xf data.tar.zst
  echo ""
else
  tar -xzf data.tar.gz
  echo ""
fi

# Extract local 
echo "Extracting local..."
cd "$EXTRACT_DIR/local"
echo ""
echo ""
ar -x "$LOCAL_DEB"
if [[ -f data.tar.xz ]]; then
  tar -xJf data.tar.xz
  echo ""
elif [[ -f data.tar.zst ]]; then
  tar --zstd -xf data.tar.zst
  echo ""
else
  tar -xzf data.tar.gz
  echo ""
fi

cd "$WORK_DIR"

# Find and extract JARs
echo "Finding JAR files..."
echo ""
ls -la "$EXTRACT_DIR"/ || echo "  ERROR: Extract directory not found"
ls -la "$EXTRACT_DIR/official/" || echo "  ERROR: Official directory not found" 
ls -la "$EXTRACT_DIR/local/" || echo "  ERROR: Local directory not found"

OFFICIAL_JAR=$(find "$EXTRACT_DIR/official" -name "desktop.jar" | head -1)
LOCAL_JAR=$(find "$EXTRACT_DIR/local" -name "desktop.jar" | head -1)

echo " Official: $OFFICIAL_JAR"
echo " Local: $LOCAL_JAR"

if [[ -z "$OFFICIAL_JAR" ]] || [[ -z "$LOCAL_JAR" ]]; then
  echo " ERROR: Could not find desktop.jar files"
  echo "Available files in official:"
  find "$EXTRACT_DIR/official" -name "*.jar" | head -5
  echo "Available files in local:"
  find "$EXTRACT_DIR/local" -name "*.jar" | head -5
  exit 1
fi

echo "Extracting JARs..."
cd "$EXTRACT_DIR/jars/official" && jar -xf "$OFFICIAL_JAR" && cd "$WORK_DIR"
cd "$EXTRACT_DIR/jars/local" && jar -xf "$LOCAL_JAR" && cd "$WORK_DIR" 
echo "Extraction complete"

# Compare hashes with detailed file analysis
echo "Generating hashes..."
echo ""
ls -la "$EXTRACT_DIR/jars/" || echo "  ERROR: JAR extraction directory not found"

# Generate hash-to-filename mapping
echo "Creating hash mappings..."
find "$EXTRACT_DIR/jars/official" -name "*.class" | sort | while read file; do
  hash=$(sha256sum "$file" | cut -d' ' -f1)
  relpath=$(echo "$file" | sed "s|$EXTRACT_DIR/jars/official/||")
  echo "$hash $relpath"
done > official-hashes-with-files.txt

find "$EXTRACT_DIR/jars/local" -name "*.class" | sort | while read file; do
  hash=$(sha256sum "$file" | cut -d' ' -f1)
  relpath=$(echo "$file" | sed "s|$EXTRACT_DIR/jars/local/||")
  echo "$hash $relpath"
done > local-hashes-with-files.txt

# Generate simple hash lists for comparison (backward compatibility)
cut -d' ' -f1 official-hashes-with-files.txt | sort > official-hashes.txt
cut -d' ' -f1 local-hashes-with-files.txt | sort > local-hashes.txt

OFFICIAL_COUNT=$(wc -l < official-hashes.txt)
LOCAL_COUNT=$(wc -l < local-hashes.txt)

echo "Hashes generated: Official=$OFFICIAL_COUNT, Local=$LOCAL_COUNT"

echo "Comparing..."
DIFF_OUTPUT=$(diff official-hashes.txt local-hashes.txt 2>/dev/null || true)
DIFF_COUNT=$(echo "$DIFF_OUTPUT" | grep -c "^[<>]" 2>/dev/null || echo "0")
DIFF_COUNT=$(echo "$DIFF_COUNT" | tr -d '\n')

# Generate detailed file difference analysis
echo "Analyzing differences..."
if [[ $DIFF_COUNT -gt 0 ]]; then
  echo "Creating diff report..."
  
  # Create file-specific analysis
  echo "=== DETAILED FILE DIFFERENCE ANALYSIS ===" > file-differences-detailed.txt
  echo "Generated: $(date)" >> file-differences-detailed.txt
  echo "" >> file-differences-detailed.txt
  
  # Find files that only exist in official build
  echo "FILES ONLY IN OFFICIAL BUILD:" >> file-differences-detailed.txt
  comm -23 <(cut -d' ' -f2- official-hashes-with-files.txt | sort) <(cut -d' ' -f2- local-hashes-with-files.txt | sort) >> file-differences-detailed.txt
  echo "" >> file-differences-detailed.txt
  
  # Find files that only exist in local build 
  echo "FILES ONLY IN LOCAL BUILD:" >> file-differences-detailed.txt
  comm -13 <(cut -d' ' -f2- official-hashes-with-files.txt | sort) <(cut -d' ' -f2- local-hashes-with-files.txt | sort) >> file-differences-detailed.txt
  echo "" >> file-differences-detailed.txt
  
  # Find files with different hashes (same filename, different content)
  echo "FILES WITH DIFFERENT CONTENT (same name, different hash):" >> file-differences-detailed.txt
  join -j 2 -o 1.1,1.2,2.1 <(sort -k2 official-hashes-with-files.txt) <(sort -k2 local-hashes-with-files.txt) | \
  awk '$1 != $3 {print $2 " (Official: " substr($1,1,16) "... vs Local: " substr($3,1,16) "...)"}' >> file-differences-detailed.txt
  echo "" >> file-differences-detailed.txt
  
  # Summary statistics
  OFFICIAL_ONLY=$(comm -23 <(cut -d' ' -f2- official-hashes-with-files.txt | sort) <(cut -d' ' -f2- local-hashes-with-files.txt | sort) | wc -l)
  LOCAL_ONLY=$(comm -13 <(cut -d' ' -f2- official-hashes-with-files.txt | sort) <(cut -d' ' -f2- local-hashes-with-files.txt | sort) | wc -l)
  DIFFERENT_CONTENT=$(join -j 2 -o 1.1,1.2,2.1 <(sort -k2 official-hashes-with-files.txt) <(sort -k2 local-hashes-with-files.txt) | awk '$1 != $3' | wc -l)
  
  echo "SUMMARY:" >> file-differences-detailed.txt
  echo "- Files only in official: $OFFICIAL_ONLY" >> file-differences-detailed.txt
  echo "- Files only in local: $LOCAL_ONLY" >> file-differences-detailed.txt 
  echo "- Files with different content: $DIFFERENT_CONTENT" >> file-differences-detailed.txt
  echo "- Total differences: $DIFF_COUNT" >> file-differences-detailed.txt
  
  echo "Diff report saved"
fi

echo ""
echo "---"
echo "RESULTS"
echo "---"

if [[ $DIFF_COUNT -eq 0 ]] && [[ $OFFICIAL_COUNT -eq $LOCAL_COUNT ]] && [[ $OFFICIAL_COUNT -gt 0 ]]; then
  echo "REPRODUCIBLE"
  echo "  $OFFICIAL_COUNT files analyzed"
  echo "  All SHA256 hashes match"
  echo "  No differences detected"
  STATUS="PASSED"
  REPRODUCIBLE="YES"
else
  echo " DIFFERENCES DETECTED"
  echo " Files: Official=$OFFICIAL_COUNT, Local=$LOCAL_COUNT"
  echo " Differences: $DIFF_COUNT"
  STATUS="FAILED" 
  REPRODUCIBLE="NO"
fi

echo ""
echo "Status: $STATUS"
echo "Reproducible: $REPRODUCIBLE"
echo "Date: $(date)"

# Save results
cat > "$RESULTS_DIR/verification-report.txt" << EOF
Bisq Build Verification Report
============================
Date: $(date)
Version: $BISQ_VERSION
Mode: $MODE
Status: $STATUS
Reproducible: $REPRODUCIBLE

Analysis:
- Official files: $OFFICIAL_COUNT
- Local files: $LOCAL_COUNT
- Hash differences: $DIFF_COUNT

Files:
- Local: $(basename "$LOCAL_DEB")
- Official: $(basename "$OFFICIAL_DEB")

Result: $([ "$REPRODUCIBLE" == "YES" ] && echo "Build produces identical binaries" || echo "Build differences detected")
EOF

# Copy all analysis files to results directory
cp official-hashes.txt local-hashes.txt "$RESULTS_DIR/" 2>/dev/null || true
cp official-hashes-with-files.txt local-hashes-with-files.txt "$RESULTS_DIR/" 2>/dev/null || true
[[ -f file-differences-detailed.txt ]] && cp file-differences-detailed.txt "$RESULTS_DIR/" 2>/dev/null || true
[[ -n "$DIFF_OUTPUT" ]] && echo "$DIFF_OUTPUT" > "$RESULTS_DIR/differences.txt"

# Display summary of available analysis files
echo ""
echo "ANALYSIS FILES:"
echo " verification-report.txt - Summary report"
echo " official-hashes.txt - Official build file hashes" 
echo " local-hashes.txt - Local build file hashes"
echo " official-hashes-with-files.txt - Official hashes with filenames"
echo " local-hashes-with-files.txt - Local hashes with filenames"
[[ -f file-differences-detailed.txt ]] && echo " file-differences-detailed.txt - Detailed file-by-file analysis"
echo " differences.txt - Raw hash differences"

echo "Results: $RESULTS_DIR"
echo "---"

# Completion
echo ""
echo "Results: $RESULTS_DIR"
echo "Complete"
echo ""

# Exit cleanly - no infinite loop
exit 0
CONTAINER_SCRIPT

echo "Building image..."
if docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/.dockerfile-temp" "$SCRIPT_DIR"; then
  echo "Image built"
else
  echo " ERROR: Failed to build Docker image"
  exit 1
fi

# Run verification
echo ""
echo "Starting..."
echo ""

# Run container with direct terminal attachment (keep container for inspection)
docker run -it \
  -e BISQ_VERSION="$BISQ_VERSION" \
  -e MODE="$MODE" \
  -v "$RESULTS_DIR":/home/bisq/build-results \
  -v "$BUILD_PATH":/home/bisq/host-bisq \
  "$IMAGE_NAME"

CONTAINER_EXIT_CODE=$?

# Get the last container ID
CONTAINER_ID=$(docker ps -l -q)

# Check results to determine exit code
if [[ -f "$RESULTS_DIR/verification-report.txt" ]] && grep -q "Reproducible: YES" "$RESULTS_DIR/verification-report.txt"; then
  CONTAINER_EXIT_CODE=0
else
  CONTAINER_EXIT_CODE=1
fi

# Cleanup temp files
rm -f "$SCRIPT_DIR/.dockerfile-temp" "$SCRIPT_DIR/verify-container.sh"

echo ""
echo "---"
if [[ $CONTAINER_EXIT_CODE -eq 0 ]]; then
  echo "VERIFICATION PASSED"
  [[ -f "$RESULTS_DIR/verification-report.txt" ]] && grep -q "Reproducible: YES" "$RESULTS_DIR/verification-report.txt" && echo "BUILD IS REPRODUCIBLE"
else
  echo "VERIFICATION FAILED"
fi

echo ""
echo "Results: $RESULTS_DIR"
[[ -f "$RESULTS_DIR/verification-report.txt" ]] && echo "Report: verification-report.txt"

# Bright yellow text for container cleanup instructions
echo ""
echo -e "\033[1;33m"
echo "Container created: $CONTAINER_ID"
echo ""
echo "To delete the container:"
echo "  docker rm $CONTAINER_ID"
echo ""
echo "To delete the image:"
echo "  docker rmi $IMAGE_NAME"
echo -e "\033[0m"

# Exit cleanly with appropriate code
exit $CONTAINER_EXIT_CODE
