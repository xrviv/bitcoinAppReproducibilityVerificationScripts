#!/bin/bash

# Bisq Reproducible Build Verification Tool - Simple Version
# All output visible in terminal, no complex logging
#
# Version: 2.0.1
# Last Updated: 2025-10-10
#
# Changelog:
# v2.0.1 - Renamed from verify_bisqdesktop.sh to verify_bisq1.sh (2025-10-10)
# v1.4 - Added detailed file difference analysis and terminal output transparency (2025-09-06)
# v1.3 - Added container inspection + fixed extraction paths (2025-08-27)
# v1.2 - Added manual jpackage fallback (2025-08-27)
# v1.1 - Added RPM support (2025-08-27)

set -euo pipefail  # Enhanced error handling
set -x             # Debug mode - show all commands as they execute

VERSION="2.0.1"

# Cleanup function for interruptions
cleanup_on_exit() {
    echo ""
    echo "ð§¹ Cleaning up on exit..."
    
    # Clean up container if it exists
    if [[ -n "${CONTAINER_ID:-}" ]]; then
        echo "  â Stopping container $CONTAINER_ID..."
        docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi
    
    # Clean up temporary files
    rm -f "$SCRIPT_DIR/.dockerfile-temp" "$SCRIPT_DIR/verify-container.sh" 2>/dev/null || true
    echo "â Exit cleanup completed"
}

# Set up cleanup on script exit (including interruption)
trap cleanup_on_exit EXIT INT TERM
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
IMAGE_NAME="bisq-verify"

# Configuration
BISQ_VERSION=${BISQ_VERSION:-${1:-v1.9.21}}
MODE=${MODE:-verify}  # 'build', 'verify', or 'shell'

show_help() {
    cat << EOF
Bisq Build Reproducibility Verification Tool v$VERSION

USAGE:
    ./verify_bisq1.sh [VERSION] [MODE]

MODES:
    verify  - Verification only using existing .deb files (default, ~2 min)
    build   - Full build + verification (~30 min)

EXAMPLES:
    ./verify_bisq1.sh                    # Verify v1.9.21 using existing files
    ./verify_bisq1.sh v1.9.20           # Verify v1.9.20 using existing files
    ./verify_bisq1.sh v1.9.21 build     # Full build + verify v1.9.21
    MODE=build ./verify_bisq1.sh         # Full build + verify v1.9.21

ENVIRONMENT:
    BISQ_VERSION - Version to verify (default: v1.9.21)
    MODE         - Operation mode: 'verify' or 'build' (default: verify)

FILES REQUIRED FOR VERIFY MODE:
    /home/dannybuntu/builds/desktop/bisq/bisq/desktop/build/packaging/jpackage/packages/bisq_*-1_amd64.deb
    /home/dannybuntu/builds/desktop/bisq/bisq/bisq-official-comparison/Bisq-64bit-*.deb

RESULTS:
    All outputs saved to: $RESULTS_DIR/
EOF
}

# Parse arguments
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ $# -gt 1 ]] && [[ -n "${2:-}" ]]; then
    MODE="$2"
elif [[ "${1:-}" == "build" ]] || [[ "${1:-}" == "verify" ]]; then
    MODE="$1"
    BISQ_VERSION="v1.9.21"
fi

echo "Bisq Build Reproducibility Tool v$VERSION"
echo "=========================================="
echo "Version: $BISQ_VERSION"
echo "Mode: $MODE"
echo "Results: $RESULTS_DIR"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Comprehensive cleanup
echo "ð§¹ Comprehensive environment cleanup..."

# Clean up any hung Docker containers only
echo "  â Terminating any previous bisq-verify containers..."
# Only kill Docker containers, not this script
docker ps -q --filter ancestor=bisq-verify | xargs -r docker kill 2>/dev/null || true

# Clean temporary directories
echo "  â Cleaning temporary directories..."
rm -rf /tmp/manual-verify* 2>/dev/null || true
rm -rf /tmp/official-only.txt /tmp/local-only.txt 2>/dev/null || true

# Clean Docker environment
echo "  â Cleaning Docker environment..."
# Stop and remove any running containers with our image
docker ps -q --filter ancestor="$IMAGE_NAME" | xargs -r docker stop 2>/dev/null || true
docker ps -aq --filter ancestor="$IMAGE_NAME" | xargs -r docker rm 2>/dev/null || true

# Remove Docker image and prune system
if docker images -q "$IMAGE_NAME" >/dev/null 2>&1; then
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
fi
docker system prune -f >/dev/null 2>&1 || true

# Clean previous results to avoid contamination
echo "  â Cleaning previous result files..."
rm -f "$RESULTS_DIR"/*.txt 2>/dev/null || true
rm -f "$RESULTS_DIR"/*.log 2>/dev/null || true

# Clean up any leftover temporary files from previous runs
echo "  â Cleaning script temporary files..."
rm -f "$SCRIPT_DIR"/.dockerfile-temp "$SCRIPT_DIR"/verify-container.sh 2>/dev/null || true

# Ensure clean results directory
mkdir -p "$RESULTS_DIR"

echo "â Comprehensive cleanup completed"

# Check Docker
echo "ð³ Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    echo "â ERROR: Docker is not installed or not in PATH"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "â ERROR: Docker daemon is not running"
    exit 1
fi
echo "â Docker is available"

# Build Docker image
echo "ð¨ Preparing Docker environment..."
cat > "$SCRIPT_DIR/.dockerfile-temp" << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git wget curl unzip tar xz-utils zstd binutils \
    openjdk-11-jdk ca-certificates ca-certificates-java fakeroot dpkg-dev \
    build-essential debhelper rpm \
    libx11-6 libxext6 libxrender1 libxtst6 libxi6 libxrandr2 libxcb1 libxau6 \
    xvfb x11-apps \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates \
    && useradd -m -s /bin/bash bisq

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
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

set -euo pipefail  # Enhanced error handling
set -x             # Debug mode - show all commands as they execute

# Ensure output is not buffered
export PYTHONUNBUFFERED=1
stty -icanon min 1 time 0 2>/dev/null || true  # Set terminal to immediate mode
exec 1> >(stdbuf -oL cat)  # Line buffer stdout
exec 2> >(stdbuf -oL cat >&2)  # Line buffer stderr

echo "=== Bisq Container Verification ==="
echo "Version: ${BISQ_VERSION:-v1.9.21}"
echo "Mode: ${MODE:-verify}" 
echo "Java: $(java -version 2>&1 | head -1)"
echo ""

BISQ_VERSION=${BISQ_VERSION:-v1.9.21}
MODE=${MODE:-verify}
WORK_DIR="/home/bisq/work"
RESULTS_DIR="/home/bisq/build-results"

mkdir -p "$WORK_DIR" "$RESULTS_DIR"
cd "$WORK_DIR"

if [[ "$MODE" == "build" ]]; then
    echo "ð¨ FULL BUILD MODE"
    echo ""
    
    echo "ð¦ Cloning Bisq repository..."
    git clone --progress https://github.com/bisq-network/bisq.git
    cd bisq
    echo "â Repository cloned"
    
    echo "ð Checking out $BISQ_VERSION..."
    git checkout "$BISQ_VERSION"
    echo "â Checked out: $(git describe --tags)"
    
    echo "ð¥ Downloading official release..."
    cd "$WORK_DIR"
    wget --progress=bar:force "https://github.com/bisq-network/bisq/releases/download/${BISQ_VERSION}/Bisq-64bit-${BISQ_VERSION#v}.deb"
    echo "â Official release downloaded"
    
    echo "ðï¸  Building Bisq (this will take 20+ minutes)..."
    cd bisq
    ./gradlew clean build -x test
    
    echo "ð§ Configuring for DEB package creation..."
    ./gradlew desktop:generateInstallers
    echo "â Build completed"
    
    echo ""
    echo "ð Checking what was built..."
    find desktop/build -name "*.deb" -o -name "*.rpm" -o -name "*.dmg" -o -name "*.exe" -o -name "*bisq*" | head -10
    
    LOCAL_DEB=$(find desktop/build/packaging/jpackage/packages -name "bisq_*-1_amd64.deb" | head -1)
    if [[ -n "$LOCAL_DEB" ]]; then
        LOCAL_DEB=$(realpath "$LOCAL_DEB")
    fi
    OFFICIAL_DEB="$WORK_DIR/Bisq-64bit-${BISQ_VERSION#v}.deb"
    
    if [[ -z "$LOCAL_DEB" ]]; then
        echo "â ï¸  Gradle task failed to create .deb file, trying manual jpackage..."
        echo "Available build artifacts:"
        find desktop/build -type f | grep -E "\.(deb|rpm|jar)$" | head -10
        
        # Get Java 17 toolchain path for jpackage
        JPACKAGE_PATH=$(find /home/bisq/.gradle/jdks -name "jpackage" -path "*/azul*17*/bin/jpackage" | head -1)
        if [[ -z "$JPACKAGE_PATH" ]]; then
            echo "â ERROR: Could not find jpackage in Java 17 toolchain"
            exit 1
        fi
        
        echo "ð§ Running manual jpackage with correct paths..."
        echo "Using jpackage: $JPACKAGE_PATH"
        
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
            echo "â ERROR: Manual jpackage also failed to create .deb file"
            exit 1
        fi
        # Convert to absolute path for extraction
        LOCAL_DEB=$(realpath "$LOCAL_DEB")
        echo "â Manual jpackage succeeded: $(basename "$LOCAL_DEB")"
    fi
    
else
    echo "â VERIFICATION-ONLY MODE"
    echo ""
    
    echo "ð Finding existing files..."
    LOCAL_DEB=$(find /home/bisq/host-bisq -name "bisq_*-1_amd64.deb" -path "*/desktop/build/packaging/jpackage/packages/*" | head -1)
    OFFICIAL_DEB=$(find /home/bisq/host-bisq -name "Bisq-64bit-*.deb" | head -1)
    
    if [[ ! -f "$LOCAL_DEB" ]] || [[ ! -f "$OFFICIAL_DEB" ]]; then
        echo "â ERROR: Required .deb files not found"
        echo "Local: $LOCAL_DEB"
        echo "Official: $OFFICIAL_DEB"
        exit 1
    fi
    echo "â Found both .deb files"
fi

echo ""
echo "ð Files to compare:"
echo "  Local: $(basename "$LOCAL_DEB")"
echo "  Official: $(basename "$OFFICIAL_DEB")"
echo ""

echo "ð¦ Extracting packages..."
EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$EXTRACT_DIR"/{official,local,jars/{official,local}}

# Extract official
echo "  â Extracting official package..."
cd "$EXTRACT_DIR/official"
echo "    Working in: $(pwd)"
echo "    Extracting: $OFFICIAL_DEB"
ar -x "$OFFICIAL_DEB"
if [[ -f data.tar.xz ]]; then
    tar -xJf data.tar.xz
    echo "    â Official extracted (tar.xz)"
elif [[ -f data.tar.zst ]]; then
    tar --zstd -xf data.tar.zst
    echo "    â Official extracted (tar.zst)"
else
    tar -xzf data.tar.gz
    echo "    â Official extracted (tar.gz)"
fi

# Extract local  
echo "  â Extracting local package..."
cd "$EXTRACT_DIR/local"
echo "    Working in: $(pwd)"
echo "    Extracting: $LOCAL_DEB"
ar -x "$LOCAL_DEB"
if [[ -f data.tar.xz ]]; then
    tar -xJf data.tar.xz
    echo "    â Local extracted (tar.xz)"
elif [[ -f data.tar.zst ]]; then
    tar --zstd -xf data.tar.zst
    echo "    â Local extracted (tar.zst)"
else
    tar -xzf data.tar.gz
    echo "    â Local extracted (tar.gz)"
fi

cd "$WORK_DIR"

# Find and extract JARs
echo "ð Finding desktop.jar files..."
echo "    Searching in: $EXTRACT_DIR"
ls -la "$EXTRACT_DIR"/ || echo "    ERROR: Extract directory not found"
ls -la "$EXTRACT_DIR/official/" || echo "    ERROR: Official directory not found"  
ls -la "$EXTRACT_DIR/local/" || echo "    ERROR: Local directory not found"

OFFICIAL_JAR=$(find "$EXTRACT_DIR/official" -name "desktop.jar" | head -1)
LOCAL_JAR=$(find "$EXTRACT_DIR/local" -name "desktop.jar" | head -1)

echo "  Official: $OFFICIAL_JAR"
echo "  Local: $LOCAL_JAR"

if [[ -z "$OFFICIAL_JAR" ]] || [[ -z "$LOCAL_JAR" ]]; then
    echo "â ERROR: Could not find desktop.jar files"
    echo "Available files in official:"
    find "$EXTRACT_DIR/official" -name "*.jar" | head -5
    echo "Available files in local:"
    find "$EXTRACT_DIR/local" -name "*.jar" | head -5
    exit 1
fi

echo "ð¦ Extracting JAR contents..."
cd "$EXTRACT_DIR/jars/official" && jar -xf "$OFFICIAL_JAR" && cd "$WORK_DIR"
cd "$EXTRACT_DIR/jars/local" && jar -xf "$LOCAL_JAR" && cd "$WORK_DIR"  
echo "â JAR contents extracted"

# Compare hashes with detailed file analysis
echo "ð Generating hashes with file mapping..."
echo "    Generating hashes from: $EXTRACT_DIR/jars/"
ls -la "$EXTRACT_DIR/jars/" || echo "    ERROR: JAR extraction directory not found"

# Generate hash-to-filename mapping
echo "  â Creating detailed hash mappings..."
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

echo "â Generated hashes: Official=$OFFICIAL_COUNT, Local=$LOCAL_COUNT"

echo "ð¬ Comparing results..."
DIFF_OUTPUT=$(diff official-hashes.txt local-hashes.txt 2>/dev/null || true)
DIFF_COUNT=$(echo "$DIFF_OUTPUT" | grep -c "^[<>]" 2>/dev/null || echo "0")
DIFF_COUNT=$(echo "$DIFF_COUNT" | tr -d '\n')

# Generate detailed file difference analysis
echo "  â Analyzing file differences..."
if [[ $DIFF_COUNT -gt 0 ]]; then
    echo "  â Creating detailed difference report..."
    
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
    
    echo "â Detailed analysis saved to file-differences-detailed.txt"
fi

echo ""
echo "========================================="
echo "ð VERIFICATION RESULTS"
echo "========================================="

if [[ $DIFF_COUNT -eq 0 ]] && [[ $OFFICIAL_COUNT -eq $LOCAL_COUNT ]] && [[ $OFFICIAL_COUNT -gt 0 ]]; then
    echo "ð BUILD IS REPRODUCIBLE!"
    echo "   â $OFFICIAL_COUNT files analyzed"
    echo "   â All SHA256 hashes match"
    echo "   â No differences detected"
    STATUS="PASSED"
    REPRODUCIBLE="YES"
else
    echo "â ï¸  DIFFERENCES DETECTED"
    echo "   Files: Official=$OFFICIAL_COUNT, Local=$LOCAL_COUNT"
    echo "   Differences: $DIFF_COUNT"
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
echo "ð ANALYSIS FILES GENERATED:"
echo "  â¢ verification-report.txt - Summary report"
echo "  â¢ official-hashes.txt - Official build file hashes" 
echo "  â¢ local-hashes.txt - Local build file hashes"
echo "  â¢ official-hashes-with-files.txt - Official hashes with filenames"
echo "  â¢ local-hashes-with-files.txt - Local hashes with filenames"
[[ -f file-differences-detailed.txt ]] && echo "  â¢ file-differences-detailed.txt - Detailed file-by-file analysis"
echo "  â¢ differences.txt - Raw hash differences"

echo "ð Results saved to: $RESULTS_DIR"
echo "========================================="

# Completion
echo ""
echo "ð Results saved to: $RESULTS_DIR"
echo "ð¯ Verification complete"
echo ""
echo "ð Container ready for analysis. Use 'docker exec -it \$(docker ps -l -q) bash' to access."
echo "   Container will keep running until manually stopped."
echo ""

# Keep container running for analysis
while true; do
    sleep 60
done
CONTAINER_SCRIPT

echo "ð¨ Building Docker image..."
if docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/.dockerfile-temp" "$SCRIPT_DIR"; then
    echo "â Docker image built successfully"
else
    echo "â ERROR: Failed to build Docker image"
    exit 1
fi

# Run verification
echo ""
echo "ð Starting verification..."
echo "âââââââââââââââââââââââââââââââââââââââââââââââââââ"

# Run container with direct terminal attachment (keep container for inspection)
docker run -it \
    -e BISQ_VERSION="$BISQ_VERSION" \
    -e MODE="$MODE" \
    -v "$RESULTS_DIR":/home/bisq/build-results \
    -v "/home/dannybuntu/builds/desktop/bisq":/home/bisq/host-bisq \
    "$IMAGE_NAME"

CONTAINER_EXIT_CODE=$?
echo "Container execution completed with exit code: $CONTAINER_EXIT_CODE"

# Get the last container ID for inspection instructions
CONTAINER_ID=$(docker ps -l -q --filter ancestor=bisq-verify)
if [[ -n "$CONTAINER_ID" ]]; then
    echo ""
    echo "ð CONTAINER ACCESS & CLEANUP INSTRUCTIONS:"
    echo "âââââââââââââââââââââââââââââââââââââââââââââââââââ"
    echo "Container is available for inspection:"
    echo ""
    echo "  â¢ Enter container: docker exec -it $CONTAINER_ID bash"
    echo "  â¢ View logs again: docker logs $CONTAINER_ID"
    echo "  â¢ Copy files out:  docker cp $CONTAINER_ID:/path/to/file ."
    echo ""
    echo "Manual cleanup (when you're done):"
    echo "  â¢ Stop container:  docker stop $CONTAINER_ID"
    echo "  â¢ Remove container: docker rm $CONTAINER_ID"
    echo "  â¢ Remove image:    docker rmi bisq-verify"
    echo "  â¢ Cleanup system:  docker system prune -f"
    echo ""
fi

# Check results to determine exit code
if [[ -f "$RESULTS_DIR/verification-report.txt" ]] && grep -q "Reproducible: YES" "$RESULTS_DIR/verification-report.txt"; then
    CONTAINER_EXIT_CODE=0
else
    CONTAINER_EXIT_CODE=1
fi

# Cleanup temp files but keep container
rm -f "$SCRIPT_DIR/.dockerfile-temp" "$SCRIPT_DIR/verify-container.sh"

echo ""
echo "âââââââââââââââââââââââââââââââââââââââââââââââââââ"
if [[ $CONTAINER_EXIT_CODE -eq 0 ]]; then
    echo "â VERIFICATION COMPLETED SUCCESSFULLY"
    [[ -f "$RESULTS_DIR/verification-report.txt" ]] && grep -q "Reproducible: YES" "$RESULTS_DIR/verification-report.txt" && echo "ð BUILD IS REPRODUCIBLE!"
else
    echo "â VERIFICATION FAILED OR BUILD NOT REPRODUCIBLE"
fi

echo ""
echo "ð Results available in: $RESULTS_DIR"
[[ -f "$RESULTS_DIR/verification-report.txt" ]] && echo "ð Report: verification-report.txt"

# Yellow text for cleanup instructions
echo -e "\033[1;33m"
echo "ð CONTAINER ACCESS & CLEANUP INSTRUCTIONS:"
echo "âââââââââââââââââââââââââââââââââââââââââââââââââââ"
echo "Container is still running and available for inspection:"
echo ""
echo "  â¢ Enter container: docker exec -it $CONTAINER_ID bash"
echo "  â¢ View logs again: docker logs $CONTAINER_ID"
echo "  â¢ Copy files out:  docker cp $CONTAINER_ID:/path/to/file ."
echo ""
echo "Manual cleanup (when you're done):"
echo "  â¢ Stop container:  docker stop $CONTAINER_ID"
echo "  â¢ Remove container: docker rm $CONTAINER_ID"
echo "  â¢ Remove image:    docker rmi $IMAGE_NAME"
echo "  â¢ Cleanup system:  docker system prune -f"
echo -e "\033[0m"

echo ""
echo "ð Container $CONTAINER_ID is ready for analysis!"
echo "   Press Ctrl+C when you're done to cleanup and exit."
echo ""

# Wait indefinitely - user can Ctrl+C when done
while true; do
    sleep 1
done
