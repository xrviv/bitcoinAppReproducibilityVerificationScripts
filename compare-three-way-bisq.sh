#!/bin/bash
# Three-way comparison: CI vs Container vs Official Release
# Compares desktop.jar .class files from three sources

set -e

WORK_DIR="/home/dannybuntu/work/bisq-three-way-comparison"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "=========================================="
echo "Bisq v1.9.20 Three-Way Comparison"
echo "=========================================="
echo ""

# ============================================
# Step 1: Prepare directories
# ============================================
echo "[1/7] Creating comparison directories..."
mkdir -p ci-build container-build official-release
mkdir -p ci-classes container-classes official-classes

# ============================================
# Step 2: Get CI artifact (manual download)
# ============================================
echo "[2/7] Checking for CI artifact..."
if [ ! -f "ci-build/desktop.jar" ]; then
    echo "  ⚠ CI desktop.jar not found!"
    echo "  Please download from: https://github.com/xrviv/bisq/actions"
    echo "  Save as: $WORK_DIR/ci-build/desktop.jar"
    echo ""
    read -p "Press Enter after downloading CI artifact..."
fi

if [ ! -f "ci-build/desktop.jar" ]; then
    echo "  ✗ CI artifact still not found. Exiting."
    exit 1
fi
echo "  ✓ CI artifact found"

# ============================================
# Step 3: Get container build artifact
# ============================================
echo "[3/7] Locating container build artifact..."

# Find most recent container build
CONTAINER_BUILD_DIR=$(ls -td /home/dannybuntu/work/scripts/test/desktop/bisq1_desktop_v1-9-20_* 2>/dev/null | head -1)

if [ -z "$CONTAINER_BUILD_DIR" ]; then
    echo "  ✗ No container build found in /home/dannybuntu/work/scripts/test/desktop/"
    echo "  Please run bisq1desktop_build.sh first"
    exit 1
fi

echo "  Using: $CONTAINER_BUILD_DIR"

# Extract desktop.jar from container build .deb
if [ ! -f "container-build/desktop.jar" ]; then
    echo "  Extracting desktop.jar from container .deb..."
    DEB_FILE=$(find "$CONTAINER_BUILD_DIR" -name "Bisq-*.deb" | head -1)

    if [ -z "$DEB_FILE" ]; then
        echo "  ✗ No .deb file found in container build"
        exit 1
    fi

    dpkg-deb -x "$DEB_FILE" container-build/extracted
    DESKTOP_JAR=$(find container-build/extracted -name "desktop-*.jar" | head -1)

    if [ -z "$DESKTOP_JAR" ]; then
        echo "  ✗ desktop.jar not found in .deb"
        exit 1
    fi

    cp "$DESKTOP_JAR" container-build/desktop.jar
    rm -rf container-build/extracted
fi
echo "  ✓ Container artifact found"

# ============================================
# Step 4: Get official release artifact
# ============================================
echo "[4/7] Locating official release artifact..."

# Use the extracted official build from our previous analysis
OFFICIAL_EXTRACTED="/home/dannybuntu/work/scripts/test/desktop/bisq1_desktop_v1-9-20_x86-64-linux-gnu_deb_2346592/official-extracted"

if [ ! -d "$OFFICIAL_EXTRACTED" ]; then
    echo "  ✗ Official extracted build not found"
    echo "  Expected: $OFFICIAL_EXTRACTED"
    exit 1
fi

OFFICIAL_JAR=$(find "$OFFICIAL_EXTRACTED" -name "desktop-*.jar" | head -1)
if [ -z "$OFFICIAL_JAR" ]; then
    echo "  ✗ desktop.jar not found in official build"
    exit 1
fi

cp "$OFFICIAL_JAR" official-release/desktop.jar
echo "  ✓ Official artifact found"

# ============================================
# Step 5: Extract .class files from all three
# ============================================
echo "[5/7] Extracting .class files..."

echo "  Extracting CI build..."
unzip -q ci-build/desktop.jar -d ci-classes

echo "  Extracting container build..."
unzip -q container-build/desktop.jar -d container-classes

echo "  Extracting official release..."
unzip -q official-release/desktop.jar -d official-classes

echo "  ✓ All extractions complete"

# ============================================
# Step 6: Generate checksums
# ============================================
echo "[6/7] Generating checksums..."

(cd ci-classes && find . -name "*.class" -type f -exec sha256sum {} \; | LC_ALL=C sort -k2) > ci-hashes.txt
(cd container-classes && find . -name "*.class" -type f -exec sha256sum {} \; | LC_ALL=C sort -k2) > container-hashes.txt
(cd official-classes && find . -name "*.class" -type f -exec sha256sum {} \; | LC_ALL=C sort -k2) > official-hashes.txt

CI_COUNT=$(wc -l < ci-hashes.txt)
CONTAINER_COUNT=$(wc -l < container-hashes.txt)
OFFICIAL_COUNT=$(wc -l < official-hashes.txt)

echo "  ✓ CI: $CI_COUNT .class files"
echo "  ✓ Container: $CONTAINER_COUNT .class files"
echo "  ✓ Official: $OFFICIAL_COUNT .class files"

# ============================================
# Step 7: Three-way comparison
# ============================================
echo "[7/7] Performing three-way comparison..."
echo ""
echo "=========================================="
echo "COMPARISON RESULTS"
echo "=========================================="
echo ""

# CI vs Container
echo "📊 CI vs Container:"
CI_CONTAINER_DIFF=$(comm -3 <(LC_ALL=C sort ci-hashes.txt) <(LC_ALL=C sort container-hashes.txt) | wc -l)
CI_CONTAINER_MATCH=$((CI_COUNT - CI_CONTAINER_DIFF / 2))

if [ $CI_CONTAINER_DIFF -eq 0 ]; then
    echo "  ✓ IDENTICAL - All $CI_COUNT files match!"
else
    DIFF_FILES=$((CI_CONTAINER_DIFF / 2))
    PERCENTAGE=$(awk "BEGIN {printf \"%.1f\", ($CI_CONTAINER_MATCH / $CI_COUNT) * 100}")
    echo "  ✗ DIFFER - $DIFF_FILES files differ ($PERCENTAGE% reproducible)"

    # Save differing files
    comm -3 <(LC_ALL=C sort ci-hashes.txt) <(LC_ALL=C sort container-hashes.txt) | \
        awk '{print $2}' | sort -u > ci-container-diffs.txt

    echo "  First 10 differing files:"
    head -10 ci-container-diffs.txt | while read file; do
        echo "    - $file"
    done
fi
echo ""

# CI vs Official
echo "📊 CI vs Official Release:"
CI_OFFICIAL_DIFF=$(comm -3 <(LC_ALL=C sort ci-hashes.txt) <(LC_ALL=C sort official-hashes.txt) | wc -l)
CI_OFFICIAL_MATCH=$((CI_COUNT - CI_OFFICIAL_DIFF / 2))

if [ $CI_OFFICIAL_DIFF -eq 0 ]; then
    echo "  ✓ IDENTICAL - All $CI_COUNT files match!"
else
    DIFF_FILES=$((CI_OFFICIAL_DIFF / 2))
    PERCENTAGE=$(awk "BEGIN {printf \"%.1f\", ($CI_OFFICIAL_MATCH / $CI_COUNT) * 100}")
    echo "  ✗ DIFFER - $DIFF_FILES files differ ($PERCENTAGE% reproducible)"

    # Save differing files
    comm -3 <(LC_ALL=C sort ci-hashes.txt) <(LC_ALL=C sort official-hashes.txt) | \
        awk '{print $2}' | sort -u > ci-official-diffs.txt

    echo "  First 10 differing files:"
    head -10 ci-official-diffs.txt | while read file; do
        echo "    - $file"
    done
fi
echo ""

# Container vs Official (we already know this, but for completeness)
echo "📊 Container vs Official Release:"
CONTAINER_OFFICIAL_DIFF=$(comm -3 <(LC_ALL=C sort container-hashes.txt) <(LC_ALL=C sort official-hashes.txt) | wc -l)
CONTAINER_OFFICIAL_MATCH=$((CONTAINER_COUNT - CONTAINER_OFFICIAL_DIFF / 2))

if [ $CONTAINER_OFFICIAL_DIFF -eq 0 ]; then
    echo "  ✓ IDENTICAL - All $CONTAINER_COUNT files match!"
else
    DIFF_FILES=$((CONTAINER_OFFICIAL_DIFF / 2))
    PERCENTAGE=$(awk "BEGIN {printf \"%.1f\", ($CONTAINER_OFFICIAL_MATCH / $CONTAINER_COUNT) * 100}")
    echo "  ✗ DIFFER - $DIFF_FILES files differ ($PERCENTAGE% reproducible)"

    # Save differing files
    comm -3 <(LC_ALL=C sort container-hashes.txt) <(LC_ALL=C sort official-hashes.txt) | \
        awk '{print $2}' | sort -u > container-official-diffs.txt

    echo "  First 10 differing files:"
    head -10 container-official-diffs.txt | while read file; do
        echo "    - $file"
    done
fi
echo ""

# ============================================
# Summary and Insights
# ============================================
echo "=========================================="
echo "INSIGHTS"
echo "=========================================="
echo ""

if [ $CI_CONTAINER_DIFF -eq 0 ]; then
    echo "✓ Our container MATCHES CI exactly!"
    echo "  → Container build process is correct"
    echo ""
fi

if [ $CI_OFFICIAL_DIFF -eq 0 ]; then
    echo "✓ CI MATCHES official release exactly!"
    echo "  → Official releases use standard CI process"
    echo ""
fi

if [ $CI_CONTAINER_DIFF -ne 0 ] && [ $CI_OFFICIAL_DIFF -ne 0 ]; then
    echo "⚠ Both CI and container differ from official release"
    echo "  → Official releases use a DIFFERENT build process"
    echo ""

    # Check if CI and container have the same differences
    if [ $CI_CONTAINER_DIFF -eq 0 ]; then
        echo "  → CI and container have IDENTICAL differences from official"
        echo "  → This suggests official uses different compiler settings"
    fi
fi

echo "=========================================="
echo "Files saved in: $WORK_DIR"
echo "=========================================="
echo ""
echo "Hash files:"
echo "  - ci-hashes.txt"
echo "  - container-hashes.txt"
echo "  - official-hashes.txt"
echo ""
echo "Diff lists:"
echo "  - ci-container-diffs.txt"
echo "  - ci-official-diffs.txt"
echo "  - container-official-diffs.txt"
echo ""
