#!/bin/bash
# Bisq Build Log Comparison Script
# Analyzes CI vs Container build logs to find environment/compilation differences

set -e

LOG_DIR="/home/dannybuntu/builds/desktop/bisq/2025-12-17.build-ci-comparison-logs"
CI_LOG="$LOG_DIR/bisq-ci-build.log"
CONTAINER_LOG="$LOG_DIR/bisq-container-build.log"
OUTPUT_FILE="$LOG_DIR/log-comparison-findings.txt"

# Colors
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"

echo "=========================================="
echo "Bisq Build Log Comparison Analysis"
echo "=========================================="
echo ""

# Check if logs exist
if [ ! -f "$CI_LOG" ]; then
    echo -e "${RED}✗ CI log not found:${NC} $CI_LOG"
    exit 1
fi

if [ ! -f "$CONTAINER_LOG" ]; then
    echo -e "${RED}✗ Container log not found:${NC} $CONTAINER_LOG"
    echo "  Please save container build log to: $CONTAINER_LOG"
    exit 1
fi

echo -e "${GREEN}✓ Both logs found${NC}"
echo "  CI log: $CI_LOG ($(wc -l < "$CI_LOG") lines)"
echo "  Container log: $CONTAINER_LOG ($(wc -l < "$CONTAINER_LOG") lines)"
echo ""

# Initialize output file
{
    echo "=========================================="
    echo "Bisq Build Log Comparison Findings"
    echo "Date: $(date)"
    echo "=========================================="
    echo ""
} > "$OUTPUT_FILE"

# ============================================
# Function: Extract and compare section
# ============================================
extract_and_compare() {
    local section_name="$1"
    local pattern="$2"
    local context_lines="${3:-0}"

    echo -e "${BLUE}[Analyzing]${NC} $section_name..."

    {
        echo "=========================================="
        echo "$section_name"
        echo "=========================================="
        echo ""
    } >> "$OUTPUT_FILE"

    # Extract from CI log
    if [ $context_lines -eq 0 ]; then
        CI_EXTRACT=$(grep -i "$pattern" "$CI_LOG" 2>/dev/null || true)
    else
        CI_EXTRACT=$(grep -i -A $context_lines "$pattern" "$CI_LOG" 2>/dev/null || true)
    fi

    # Extract from Container log
    if [ $context_lines -eq 0 ]; then
        CONTAINER_EXTRACT=$(grep -i "$pattern" "$CONTAINER_LOG" 2>/dev/null || true)
    else
        CONTAINER_EXTRACT=$(grep -i -A $context_lines "$pattern" "$CONTAINER_LOG" 2>/dev/null || true)
    fi

    # Compare
    if [ "$CI_EXTRACT" == "$CONTAINER_EXTRACT" ]; then
        echo "  ✓ Identical"
        {
            echo "Status: IDENTICAL"
            echo ""
            echo "Value:"
            echo "$CI_EXTRACT"
            echo ""
        } >> "$OUTPUT_FILE"
    else
        echo -e "  ${RED}✗ DIFFER${NC}"
        {
            echo "Status: DIFFER"
            echo ""
            echo "CI Log:"
            echo "---"
            echo "$CI_EXTRACT"
            echo ""
            echo "Container Log:"
            echo "---"
            echo "$CONTAINER_EXTRACT"
            echo ""
        } >> "$OUTPUT_FILE"
    fi
    echo ""
}

# ============================================
# Java Version Analysis
# ============================================
echo -e "${CYAN}=== Java Environment ===${NC}"
echo ""

extract_and_compare "Java Version (java -version)" "java version\|openjdk version" 2
extract_and_compare "Java Compiler Version (javac)" "javac.*version" 1
extract_and_compare "Java Home Path" "JAVA_HOME" 0
extract_and_compare "Java Tool Options" "JAVA_TOOL_OPTIONS" 0

# ============================================
# Gradle Configuration
# ============================================
echo -e "${CYAN}=== Gradle Configuration ===${NC}"
echo ""

extract_and_compare "Gradle Version" "Gradle [0-9]" 0
extract_and_compare "Gradle Opts" "GRADLE_OPTS" 0
extract_and_compare "Gradle Daemon" "daemon" 0
extract_and_compare "Gradle Parallel" "parallel" 0

# ============================================
# Build Environment
# ============================================
echo -e "${CYAN}=== Build Environment ===${NC}"
echo ""

extract_and_compare "Source Date Epoch" "SOURCE_DATE_EPOCH" 0
extract_and_compare "Locale (LC_ALL)" "LC_ALL" 0
extract_and_compare "Timezone (TZ)" "TZ=\|timezone" 0
extract_and_compare "Language (LANG)" "LANG=" 0

# ============================================
# Compilation Details
# ============================================
echo -e "${CYAN}=== Compilation Process ===${NC}"
echo ""

# Count compilation tasks
CI_COMPILE_COUNT=$(grep -c "Compiling.*java" "$CI_LOG" 2>/dev/null || echo "0")
CONTAINER_COMPILE_COUNT=$(grep -c "Compiling.*java" "$CONTAINER_LOG" 2>/dev/null || echo "0")

echo "  CI compilation tasks: $CI_COMPILE_COUNT"
echo "  Container compilation tasks: $CONTAINER_COMPILE_COUNT"

{
    echo "=========================================="
    echo "Compilation Task Count"
    echo "=========================================="
    echo ""
    echo "CI: $CI_COMPILE_COUNT"
    echo "Container: $CONTAINER_COMPILE_COUNT"
    if [ "$CI_COMPILE_COUNT" == "$CONTAINER_COMPILE_COUNT" ]; then
        echo "Status: IDENTICAL"
    else
        echo "Status: DIFFER"
    fi
    echo ""
} >> "$OUTPUT_FILE"

echo ""

extract_and_compare "Deprecation Warnings" "deprecated\|Deprecated" 0

# ============================================
# Desktop Module Specific
# ============================================
echo -e "${CYAN}=== Desktop Module Build ===${NC}"
echo ""

extract_and_compare "Desktop Compile Task" ":desktop:compileJava" 3
extract_and_compare "Desktop Jar Task" ":desktop:jar" 2

# ============================================
# Timing Analysis
# ============================================
echo -e "${CYAN}=== Build Timing ===${NC}"
echo ""

# Extract build duration from "BUILD SUCCESSFUL in Xm Ys"
CI_DURATION=$(grep "BUILD SUCCESSFUL in" "$CI_LOG" 2>/dev/null | tail -1 || true)
CONTAINER_DURATION=$(grep "BUILD SUCCESSFUL in" "$CONTAINER_LOG" 2>/dev/null | tail -1 || true)

echo "  CI: $CI_DURATION"
echo "  Container: $CONTAINER_DURATION"

{
    echo "=========================================="
    echo "Build Duration"
    echo "=========================================="
    echo ""
    echo "CI: $CI_DURATION"
    echo "Container: $CONTAINER_DURATION"
    echo ""
} >> "$OUTPUT_FILE"

echo ""

# ============================================
# String Concatenation Compilation
# ============================================
echo -e "${CYAN}=== String Concatenation Analysis ===${NC}"
echo ""

# Look for makeConcatWithConstants patterns (invokedynamic for string concat)
CI_CONCAT=$(grep -c "makeConcatWithConstants\|StringConcatFactory" "$CI_LOG" 2>/dev/null || echo "0")
CONTAINER_CONCAT=$(grep -c "makeConcatWithConstants\|StringConcatFactory" "$CONTAINER_LOG" 2>/dev/null || echo "0")

echo "  CI mentions: $CI_CONCAT"
echo "  Container mentions: $CONTAINER_CONCAT"

{
    echo "=========================================="
    echo "String Concatenation References"
    echo "=========================================="
    echo ""
    echo "CI: $CI_CONCAT mentions"
    echo "Container: $CONTAINER_CONCAT mentions"
    echo ""
} >> "$OUTPUT_FILE"

echo ""

# ============================================
# Warnings and Errors
# ============================================
echo -e "${CYAN}=== Warnings and Errors ===${NC}"
echo ""

CI_WARNINGS=$(grep -ic "warning:" "$CI_LOG" 2>/dev/null || echo "0")
CONTAINER_WARNINGS=$(grep -ic "warning:" "$CONTAINER_LOG" 2>/dev/null || echo "0")

CI_ERRORS=$(grep -ic "error:" "$CI_LOG" 2>/dev/null || echo "0")
CONTAINER_ERRORS=$(grep -ic "error:" "$CONTAINER_LOG" 2>/dev/null || echo "0")

echo "  CI: $CI_WARNINGS warnings, $CI_ERRORS errors"
echo "  Container: $CONTAINER_WARNINGS warnings, $CONTAINER_ERRORS errors"

{
    echo "=========================================="
    echo "Warnings and Errors"
    echo "=========================================="
    echo ""
    echo "CI: $CI_WARNINGS warnings, $CI_ERRORS errors"
    echo "Container: $CONTAINER_WARNINGS warnings, $CONTAINER_ERRORS errors"
    echo ""
} >> "$OUTPUT_FILE"

echo ""

# ============================================
# Java Compiler Flags
# ============================================
echo -e "${CYAN}=== Compiler Flags ===${NC}"
echo ""

# Look for javac invocations with flags
CI_JAVAC=$(grep "javac.*-" "$CI_LOG" 2>/dev/null | head -5 || true)
CONTAINER_JAVAC=$(grep "javac.*-" "$CONTAINER_LOG" 2>/dev/null | head -5 || true)

if [ -n "$CI_JAVAC" ] || [ -n "$CONTAINER_JAVAC" ]; then
    echo "  Found javac flag usage"
    {
        echo "=========================================="
        echo "Javac Flags Detected"
        echo "=========================================="
        echo ""
        echo "CI:"
        echo "$CI_JAVAC"
        echo ""
        echo "Container:"
        echo "$CONTAINER_JAVAC"
        echo ""
    } >> "$OUTPUT_FILE"
else
    echo "  No explicit javac flags found"
    {
        echo "=========================================="
        echo "Javac Flags"
        echo "=========================================="
        echo ""
        echo "No explicit javac command lines found in logs"
        echo ""
    } >> "$OUTPUT_FILE"
fi

echo ""

# ============================================
# Hash/Checksum Mentions
# ============================================
echo -e "${CYAN}=== Checksums and Hashes ===${NC}"
echo ""

CI_SHA=$(grep -c "sha256\|SHA256\|checksum" "$CI_LOG" 2>/dev/null || echo "0")
CONTAINER_SHA=$(grep -c "sha256\|SHA256\|checksum" "$CONTAINER_LOG" 2>/dev/null || echo "0")

echo "  CI: $CI_SHA hash references"
echo "  Container: $CONTAINER_SHA hash references"

{
    echo "=========================================="
    echo "Hash/Checksum References"
    echo "=========================================="
    echo ""
    echo "CI: $CI_SHA"
    echo "Container: $CONTAINER_SHA"
    echo ""
} >> "$OUTPUT_FILE"

echo ""

# ============================================
# Summary of Key Differences
# ============================================
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo ""

{
    echo "=========================================="
    echo "SUMMARY OF KEY DIFFERENCES"
    echo "=========================================="
    echo ""
    echo "Review the sections marked as 'DIFFER' above."
    echo ""
    echo "Common smoking guns to look for:"
    echo "1. Different Java patch versions (11.0.X vs 11.0.Y)"
    echo "2. Different JAVA_TOOL_OPTIONS or compiler flags"
    echo "3. Different SOURCE_DATE_EPOCH settings"
    echo "4. Different Gradle parallel/daemon settings"
    echo "5. Different locale (LC_ALL, LANG, TZ)"
    echo "6. Different compilation order (task count/sequence)"
    echo ""
    echo "If Java versions differ even by patch level, this explains"
    echo "the bytecode variations (valueOf vs direct concatenation)."
    echo ""
} >> "$OUTPUT_FILE"

echo "Analysis complete!"
echo ""
echo -e "${GREEN}Results saved to:${NC} $OUTPUT_FILE"
echo ""
echo "Key sections to review:"
echo "  - Java Version (patch level matters!)"
echo "  - JAVA_TOOL_OPTIONS"
echo "  - SOURCE_DATE_EPOCH"
echo "  - Gradle configuration"
echo "  - Compiler flags"
echo ""
echo "Open the file with:"
echo "  less $OUTPUT_FILE"
echo ""

# ============================================
# Extract specific version numbers for quick check
# ============================================
echo -e "${CYAN}Quick Version Check:${NC}"
echo ""

CI_JAVA_VER=$(grep -m1 -i "java version\|openjdk version" "$CI_LOG" 2>/dev/null | grep -oP '\d+\.\d+\.\d+[_\-\+][^\s"]+' | head -1 || echo "NOT FOUND")
CONTAINER_JAVA_VER=$(grep -m1 -i "java version\|openjdk version" "$CONTAINER_LOG" 2>/dev/null | grep -oP '\d+\.\d+\.\d+[_\-\+][^\s"]+' | head -1 || echo "NOT FOUND")

echo "  CI Java version:        $CI_JAVA_VER"
echo "  Container Java version: $CONTAINER_JAVA_VER"
echo ""

if [ "$CI_JAVA_VER" != "$CONTAINER_JAVA_VER" ]; then
    echo -e "${RED}★ SMOKING GUN: Java versions differ!${NC}"
    echo "  This likely explains the bytecode variations."
    echo ""
else
    echo -e "${GREEN}✓ Java versions match (at least in version string)${NC}"
    echo "  Look for differences in compiler flags or environment."
    echo ""
fi
