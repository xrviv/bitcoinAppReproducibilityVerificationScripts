#!/bin/bash
# sparrowdesktop_build.sh — Sparrow Desktop (Linux tarball/deb/rpm) reproducible build verification
# Version: v0.21.1
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-10-30
# Project: https://github.com/sparrowwallet/sparrow
# Disclaimer: for reproducible-build verification and research only. No warranty; users assume all risk and are responsible for legal compliance; the developers assume no liability for misuse.
# Steps: clone the tag in a container, build with upstream's JDK (./gradlew jpackage, plus packageTarDistribution or the deb repack), take the official artifact (--binary or GitHub release), compare extracted contents file by file, write COMPARISON_RESULTS.yaml next to the caller.
# Windows (msi/zip): sparrowwindows_build.sh. Design notes: script-notes/desktop/sparrow/changelog.md
# Exit codes: 0 = reproducible, 1 = not_reproducible or ftbfs, 2 = invalid parameters, 130 = stopped.
set -euo pipefail

SCRIPT_VERSION="v0.21.1"
APP_ID="sparrow"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Upstream's JDK for 2.5.6 (.github/workflows/package.yaml java-version); the build refuses a tag that asks for another.
JDK_VERSION="25.0.5+8"
JDK_SHA256="68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb"
DOCKER_CMD="${DOCKER_CMD:-}"

APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
NO_CACHE=false
KEEP_CONTAINER=false
BINARY_PATH=""
EXEC_DIR="$(pwd -P)"
RESULTS_FILE="${EXEC_DIR}/COMPARISON_RESULTS.yaml"
CONTAINER_NAME=""
IMAGE_NAME=""
APP_HASH="N/A"
APP_COMMIT="N/A"

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

warn() {
    echo "WARN: $1" >&2
}

# A COMPARISON_RESULTS.yaml already here may belong to another script run from the same folder;
# rename it so ABS never reads it and nothing is lost.
keep_existing_results() {
    [[ -e "$RESULTS_FILE" ]] || return 0
    local kept
    kept="${EXEC_DIR}/COMPARISON_RESULTS-kept-$(date -u -r "$RESULTS_FILE" +%Y%m%dT%H%M%SZ)-$$.yaml"
    mv -n "$RESULTS_FILE" "$kept" || die "Could not move the existing COMPARISON_RESULTS.yaml aside" $EXIT_BUILD_FAILED
    warn "Existing COMPARISON_RESULTS.yaml renamed to $(basename "$kept")"
}

cleanup() {
    [[ -n "$IMAGE_NAME" && "$KEEP_CONTAINER" != true ]] || return 0
    "$DOCKER_CMD" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    "$DOCKER_CMD" rmi -f "$IMAGE_NAME" >/dev/null 2>&1 || true
}

detect_container_cmd() {
    if [[ -n "$DOCKER_CMD" ]]; then
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        DOCKER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    else
        die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
    fi
}

require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "Missing value for parameter: $flag" $EXIT_INVALID_PARAMS
    fi
}

sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input#-}"
    input="${input%-}"
    if [[ -z "$input" ]]; then
        input="na"
    fi
    echo "$input"
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION --arch x86_64-linux-gnu --type tarball|deb|rpm [--binary FILE]"
        exit $EXIT_INVALID_PARAMS
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                require_value "$1" "${2:-}"
                APP_VERSION="$2"
                shift 2
                ;;
            --arch)
                require_value "$1" "${2:-}"
                APP_ARCH="$2"
                shift 2
                ;;
            --type)
                require_value "$1" "${2:-}"
                APP_TYPE="$2"
                shift 2
                ;;
            --binary)
                require_value "$1" "${2:-}"
                BINARY_PATH="$2"
                shift 2
                ;;
            --work-dir)
                require_value "$1" "${2:-}"
                CUSTOM_WORK_DIR="$2"
                shift 2
                ;;
            --no-cache)
                NO_CACHE=true
                shift
                ;;
            --keep-container)
                KEEP_CONTAINER=true
                shift
                ;;
            *)
                warn "Ignoring unknown parameter: $1"
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
        esac
    done

    if [[ -z "$APP_VERSION" ]]; then
        die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    fi
    case "${APP_ARCH:-x86_64-linux-gnu}" in
        x86_64-linux-gnu|x86_64-linux|x86_64) APP_ARCH="x86_64-linux-gnu" ;;
        x86_64-windows|win-x64|win64|windows)
            die "Windows (msi/zip) is verified by sparrowwindows_build.sh, not this script" $EXIT_INVALID_PARAMS ;;
        *) die "Unsupported --arch '$APP_ARCH' (this script builds x86_64-linux-gnu)" $EXIT_INVALID_PARAMS ;;
    esac
    if [[ -z "$APP_TYPE" ]]; then
        die "Missing required parameter: --type" $EXIT_INVALID_PARAMS
    fi
    if [[ "$APP_TYPE" != "tarball" ]] && [[ "$APP_TYPE" != "deb" ]] && [[ "$APP_TYPE" != "rpm" ]]; then
        die "Invalid type: $APP_TYPE (must be tarball, deb, or rpm)" $EXIT_INVALID_PARAMS
    fi
    if [[ -n "$BINARY_PATH" && ! -f "$BINARY_PATH" ]]; then
        die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
    fi
    if [[ -n "$BINARY_PATH" ]]; then
        BINARY_PATH=$(realpath "$BINARY_PATH")
        local bname
        bname=$(basename "$BINARY_PATH")
        case "$APP_TYPE" in
            tarball) [[ "$bname" == *.tar.gz ]] || die "--binary '$bname' does not look like a tarball; expected .tar.gz for --type tarball" $EXIT_INVALID_PARAMS ;;
            deb)     [[ "$bname" == *.deb ]]    || die "--binary '$bname' does not look like a deb; expected .deb for --type deb" $EXIT_INVALID_PARAMS ;;
            rpm)     [[ "$bname" == *.rpm ]]    || die "--binary '$bname' does not look like an rpm; expected .rpm for --type rpm" $EXIT_INVALID_PARAMS ;;
        esac
    fi
}

build_and_verify() {
    local version_component arch_component type_component suffix
    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    type_component=$(sanitize_component "$APP_TYPE")
    suffix="$(date +%s)-$$"

    CONTAINER_NAME="sparrow-verify-${version_component}-${arch_component}-${type_component}-${suffix}"
    IMAGE_NAME="localhost/sparrow-verifier:${version_component}-${arch_component}-${type_component}-${suffix}"
    WORK_DIR="${CUSTOM_WORK_DIR:-${EXEC_DIR}/sparrow_verification_${version_component}_${arch_component}_${type_component}_${suffix}}"

    # Exclusive: never reuse or delete a workspace another run may own.
    mkdir "$WORK_DIR" || die "Cannot create a new workspace at $WORK_DIR" $EXIT_INVALID_PARAMS
    cd "$WORK_DIR"
    echo "Workspace: $WORK_DIR"

    # Always create sparrow_official_binary so the Dockerfile COPY succeeds; empty
    # unless --binary was given, in which case the container's wget path is skipped.
    local binary_flag="0"
    if [[ -n "$BINARY_PATH" ]]; then
        cp "$BINARY_PATH" "${WORK_DIR}/sparrow_official_binary"
        binary_flag="1"
        echo "Using provided binary: $(basename "$BINARY_PATH")"
    else
        touch "${WORK_DIR}/sparrow_official_binary"
    fi

    echo "======================================================"
    echo "Sparrow Desktop v$APP_VERSION - Containerized Build ($APP_TYPE)"
    echo "======================================================"
    echo ""

    create_verify_script
    create_dockerfile

    local -a cache_flag=()
    [[ "$NO_CACHE" == true ]] && cache_flag=(--no-cache)
    local jdk_file="OpenJDK25U-jdk_x64_linux_hotspot_${JDK_VERSION/+/_}.tar.gz"

    if ! "$DOCKER_CMD" build "${cache_flag[@]}" \
        --build-arg SPARROW_VERSION="$APP_VERSION" \
        --build-arg BUILD_TYPE="$APP_TYPE" \
        --build-arg BUILD_ARCH="$APP_ARCH" \
        --build-arg SCRIPT_VERSION="$SCRIPT_VERSION" \
        --build-arg BINARY_PROVIDED="$binary_flag" \
        --build-arg META_STRICT="${META_STRICT:-true}" \
        --build-arg JDK_VERSION="$JDK_VERSION" \
        --build-arg JDK_FILE="$jdk_file" \
        --build-arg JDK_URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-${JDK_VERSION/+/%2B}/${jdk_file}" \
        --build-arg JDK_SHA256="$JDK_SHA256" \
        -t "$IMAGE_NAME" . 2>&1 | tee build.log; then
        echo ""
        # ftbfs only when the source itself failed to build; any other failure writes no YAML.
        if grep -q "BUILD FAILED" build.log; then
            keep_existing_results
            printf 'script_version: %s\nverdict: ftbfs\nnotes: "./gradlew failed for tag %s; see the build log."\n' \
                "$SCRIPT_VERSION" "$APP_VERSION" > "$RESULTS_FILE"
            display_results
        fi
        die "Container build failed before a verdict; no COMPARISON_RESULTS.yaml written" $EXIT_BUILD_FAILED
    fi

    echo ""
    echo "Extracting results..."
    "$DOCKER_CMD" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    "$DOCKER_CMD" create --name "$CONTAINER_NAME" "$IMAGE_NAME" > /dev/null
    "$DOCKER_CMD" cp "$CONTAINER_NAME:/output/file-comparison.txt" ./ 2>/dev/null || true
    APP_HASH=$("$DOCKER_CMD" run --rm "$IMAGE_NAME" cat /output/app_hash 2>/dev/null) || APP_HASH="N/A"
    APP_COMMIT=$("$DOCKER_CMD" run --rm "$IMAGE_NAME" cat /output/commit 2>/dev/null) || APP_COMMIT="N/A"
    keep_existing_results
    "$DOCKER_CMD" cp "$CONTAINER_NAME:/output/COMPARISON_RESULTS.yaml" "$RESULTS_FILE" 2>/dev/null || \
        die "Failed to extract YAML results" $EXIT_BUILD_FAILED

    display_results
}

create_verify_script() {
    cat > verify.sh << 'VERIFY_END'
#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="${SCRIPT_VERSION:-unknown}"
BUILD_TYPE="${BUILD_TYPE:-tarball}"
SPARROW_VERSION="${SPARROW_VERSION:-unknown}"
BUILD_ARCH="${BUILD_ARCH:-x86_64-linux-gnu}"
mkdir -p /output
CMP_LOG=/output/file-comparison.txt
: > "$CMP_LOG"

echo "========================================================"
echo "VERIFICATION PHASE"
echo "========================================================"
echo ""

# Hash-compare paths in $1 between built $2 and official $3; sets CMP_TOTAL, CMP_DIFF.
# Every path goes to $CMP_LOG; the terminal shows at most 5 differences.
cmp_tree() {
    local listing="$1" broot="$2" oroot="$3"
    local rel bf of bh oh st idx=0
    CMP_TOTAL=$(wc -l < "$listing" | tr -d ' ')
    CMP_DIFF=0
    while IFS= read -r rel; do
        idx=$((idx + 1))
        bf="${broot}/${rel#./}"
        of="${oroot}/${rel#./}"
        bh="(missing)"; oh="(missing)"; st="MISSING"
        [[ -f "$bf" ]] && bh=$(sha256sum "$bf" | cut -d' ' -f1)
        [[ -f "$of" ]] && oh=$(sha256sum "$of" | cut -d' ' -f1)
        [[ -L "$bf" ]] && bh="symlink -> $(readlink "$bf")"
        [[ -L "$of" ]] && oh="symlink -> $(readlink "$of")"
        if [[ -f "$bf" && -f "$of" ]]; then
            if [[ "$bh" == "$oh" ]]; then
                st="MATCH"
            else
                st="DIFFER"; CMP_DIFF=$((CMP_DIFF + 1))
            fi
        else
            CMP_DIFF=$((CMP_DIFF + 1))
        fi
        printf '%s/%s %s %s\n  built:    %s\n  official: %s\n' "$idx" "$CMP_TOTAL" "$st" "${rel#./}" "$bh" "$oh" >> "$CMP_LOG"
        if [[ "$st" != "MATCH" ]] && (( CMP_DIFF <= 5 )); then
            echo "  ⚠ $st: ${rel#./}"
            echo "      Built:    $bh"
            echo "      Official: $oh"
        fi
    done < "$listing"
    echo "  $CMP_TOTAL path(s) compared, $CMP_DIFF differ (every path: file-comparison.txt in the workspace)"
    echo ""
}

# Phase 1
echo "Phase 1: Critical Binaries Comparison"
echo "------------------------------------------------------"

CRITICAL_MATCH=true
for file in bin/Sparrow lib/libapplauncher.so lib/Sparrow.png lib/app/Sparrow.cfg; do
    built_hash=$(sha256sum /built/Sparrow/$file 2>/dev/null | cut -d' ' -f1)
    official_hash=$(sha256sum /official/Sparrow/$file 2>/dev/null | cut -d' ' -f1)

    echo "  $file:"
    echo "    Built:    $built_hash"
    echo "    Official: $official_hash"

    if [[ "$built_hash" != "$official_hash" ]]; then
        echo "    Status:   ✗ MISMATCH"
        CRITICAL_MATCH=false
    else
        echo "    Status:   ✓ MATCH"
    fi
    echo ""
done

# Phase 2
echo "Phase 2: Modules File Deep Inspection (jimage)"
echo "------------------------------------------------------"
echo ""

modules_built_hash=$(sha256sum /built/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)
modules_official_hash=$(sha256sum /official/Sparrow/lib/runtime/lib/modules 2>/dev/null | cut -d' ' -f1)

echo "  lib/runtime/lib/modules:"
echo "    Built:    $modules_built_hash"
echo "    Official: $modules_official_hash"
echo ""

if [[ "$modules_built_hash" == "$modules_official_hash" ]]; then
    echo "  ✓ Modules file: IDENTICAL"
    MODULES_MATCH=true
    MODULES_DIFF_COUNT=0
else
    echo "  ⚠ Modules file hash differs - performing deep inspection..."
    echo ""

    mkdir -p /extracted/built /extracted/official

    echo "  Extracting built modules..."
    if ! jimage extract --dir /extracted/built /built/Sparrow/lib/runtime/lib/modules 2>&1; then
        echo "  ✗ ERROR: Failed to extract built modules"
        MODULES_MATCH=false
        MODULES_DIFF_COUNT=-1
    else
        echo "  ✓ Built modules extracted"
        echo "  Extracting official modules..."
        if ! jimage extract --dir /extracted/official /official/Sparrow/lib/runtime/lib/modules 2>&1; then
            echo "  ✗ ERROR: Failed to extract official modules"
            MODULES_MATCH=false
            MODULES_DIFF_COUNT=-1
        else
            echo "  ✓ Official modules extracted"
            echo ""
            echo "  Comparing extracted class files..."
            diff_output=/output/modules-diff.txt

            diff_exit=0
            diff -r /extracted/built /extracted/official > "$diff_output" 2>&1 || diff_exit=$?

            if [[ $diff_exit -gt 1 ]]; then
                echo "  ✗ ERROR: diff failed (exit $diff_exit)"
                exit 1
            fi

            MODULES_DIFF_COUNT=$(awk '/^Files .* differ$/ || /^Only in / {count++} END {print count+0}' "$diff_output")

            if [[ "$MODULES_DIFF_COUNT" -eq 0 ]]; then
                echo "  ✓ Deep inspection: All classes IDENTICAL"
                echo "  ℹ Hash difference due to compression/ordering only"
                MODULES_MATCH=true
            else
                echo "  ✗ Deep inspection: $MODULES_DIFF_COUNT class differences (first 5; full list in modules-diff.txt):"
                grep -E '^Files .* differ$|^Only in ' "$diff_output" | head -5 | while read -r line; do
                    f=$(echo "$line" | sed 's/Files \/extracted\/built\//  - /' | sed 's/ and.*//' | sed 's/^Only in /  + Only in /')
                    echo "$f"
                done
                MODULES_MATCH=false
            fi
        fi
    fi
fi
echo ""

# Phase 3
echo "Phase 3: File Count Analysis"
echo "------------------------------------------------------"

built_listing=$(mktemp /tmp/sparrow-built-list.XXXXXX)
official_listing=$(mktemp /tmp/sparrow-official-list.XXXXXX)
built_legal_listing=$(mktemp /tmp/sparrow-built-legal.XXXXXX)
official_legal_listing=$(mktemp /tmp/sparrow-official-legal.XXXXXX)

(cd /built/Sparrow && find . \( -type f -o -type l \) | sort) > "$built_listing"
(cd /official/Sparrow && find . \( -type f -o -type l \) | sort) > "$official_listing"
(cd /built/Sparrow && find . \( -type f -o -type l \) -path '*/lib/runtime/legal/*' | sort) > "$built_legal_listing"
(cd /official/Sparrow && find . \( -type f -o -type l \) -path '*/lib/runtime/legal/*' | sort) > "$official_legal_listing"

build_total=$(wc -l < "$built_listing" | tr -d ' ')
official_total=$(wc -l < "$official_listing" | tr -d ' ')
built_legal_count=$(wc -l < "$built_legal_listing" | tr -d ' ')
official_legal_count=$(wc -l < "$official_legal_listing" | tr -d ' ')

build_count=$((build_total - built_legal_count))
official_count=$((official_total - official_legal_count))

echo "  Total files (built):    $build_total"
echo "  Total files (official): $official_total"
echo ""

if [[ "$built_legal_count" -ne "$official_legal_count" ]]; then
    echo "  ℹ EXCLUDED FROM VERDICT: lib/runtime/legal/ (JDK license texts)"
    echo "    Built has:    $built_legal_count legal files"
    echo "    Official has: $official_legal_count legal files"
    echo "    Reason: jpackage omits these in containers; not executable code"
    echo "    Missing legal files (first 5):"
    comm -23 "$official_legal_listing" "$built_legal_listing" | head -5 | sed 's/^/      - /'
    echo ""
fi

echo "  Comparable files (excluding legal):"
echo "    Built:    $build_count"
echo "    Official: $official_count"

FILE_COUNT_MATCH=true
if [[ "$build_count" -eq "$official_count" ]]; then
    echo "  ✓ File counts match"
else
    echo "  ⚠ File count differs by $((official_count - build_count))"
    FILE_COUNT_MATCH=false
fi
echo ""

ds=0; diff -q "$official_listing" "$built_listing" >/dev/null || ds=$?
[[ "$ds" -le 1 ]] || { echo "ERROR: diff status $ds"; exit "$ds"; }
if [[ "$ds" -eq 1 ]]; then
    diff "$official_listing" "$built_listing" > /output/tree-set-diff.txt || [ $? -eq 1 ]
    echo "  ⚠ Tree file sets differ (official <, built >; first 5, full list in tree-set-diff.txt):"
    grep -E '^[<>]' /output/tree-set-diff.txt | head -5 | sed 's/^/    /'
    FILE_COUNT_MATCH=false
fi
rm -f "$built_listing" "$official_listing" "$built_legal_listing" "$official_legal_listing"

# Phase 4
echo "Phase 4: File-by-file Verification"
echo "------------------------------------------------------"

full_listing=$(mktemp /tmp/sparrow-full-list.XXXXXX)
{ (cd /official/Sparrow && find . \( -type f -o -type l \) -print)
  (cd /built/Sparrow && find . \( -type f -o -type l \) -print); } | sort -u > "$full_listing"
echo "== Phase 4: application tree ==" >> "$CMP_LOG"
cmp_tree "$full_listing" /built/Sparrow /official/Sparrow
diff_files=$CMP_DIFF
rm -f "$full_listing"

FILE_HASH_MATCH=true
if [[ "$diff_files" -gt 0 ]]; then
    FILE_HASH_MATCH=false
fi

# Compare /built/$1 against /official/$1; sets AREA_MATCH true/false, or n/a if absent.
compare_area() {
    AREA_MATCH="n/a"
    [[ -d "/official/$1" && -d "/built/$1" ]] || return 0
    echo "$2"
    echo "------------------------------------------------------"
    local ol bl un
    ol=$(mktemp); bl=$(mktemp); un=$(mktemp)
    (cd "/official/$1" && find . \( -type f -o -type l \) | sort) > "$ol"
    (cd "/built/$1" && find . \( -type f -o -type l \) | sort) > "$bl"
    sort -u "$ol" "$bl" > "$un"
    local ds=0; diff -q "$ol" "$bl" >/dev/null || ds=$?
    [[ "$ds" -le 1 ]] || { echo "ERROR: diff status $ds"; exit "$ds"; }
    if [[ "$ds" -eq 1 ]]; then
        echo "  ⚠ File sets differ (official <, built >; first 5):"
        diff "$ol" "$bl" | grep -E '^[<>]' | head -5 | sed 's/^/    /' || true
        echo ""
    fi
    echo "== $2 ==" >> "$CMP_LOG"
    cmp_tree "$un" "/built/$1" "/official/$1"
    if [[ "$CMP_DIFF" -eq 0 ]]; then
        AREA_MATCH=true
        echo "  ✓ $CMP_TOTAL file(s) match"
    else
        AREA_MATCH=false
        echo "  ⚠ $CMP_DIFF difference(s) found"
    fi
    echo ""
}

compare_area meta "Phase 5: Package Metadata Comparison"
META_MATCH="$AREA_MATCH"
compare_area extra "Phase 6: Out-of-subtree Payload Comparison"
EXTRA_MATCH="$AREA_MATCH"

# META_STRICT=false downgrades a metadata mismatch to a warning that does not
# change the verdict. Default is strict.
META_STRICT="${META_STRICT:-true}"
META_OK=true
if [[ "$META_MATCH" == "false" && "$META_STRICT" != "false" ]]; then
    META_OK=false
fi
EXTRA_OK=true
[[ "$EXTRA_MATCH" == "false" ]] && EXTRA_OK=false

# Whole-artifact comparison: recorded, not gated on.
ARCHIVE_MATCH="n/a"
if [[ -f /built/ARCHIVE_SHA256 && -f /official/ARCHIVE_SHA256 ]]; then
    ab=$(cat /built/ARCHIVE_SHA256); ao=$(cat /official/ARCHIVE_SHA256)
    echo "Whole-artifact Comparison"
    echo "------------------------------------------------------"
    echo "  Built:    $ab"
    echo "  Official: $ao"
    if [[ "$ab" == "$ao" ]]; then
        ARCHIVE_MATCH=true;  echo "  ✓ Archives are byte-identical"
    else
        ARCHIVE_MATCH=false; echo "  ⚠ Archives differ"
    fi
    echo ""
fi

if [[ "$CRITICAL_MATCH" == "true" ]] && [[ "$MODULES_MATCH" == "true" ]] && [[ "$FILE_COUNT_MATCH" == "true" ]] && [[ "$FILE_HASH_MATCH" == "true" ]] && [[ "$META_OK" == "true" ]] && [[ "$EXTRA_OK" == "true" ]]; then
    STATUS="reproducible"
    VERDICT="✅ REPRODUCIBLE"
else
    STATUS="not_reproducible"
    VERDICT="❌ NOT REPRODUCIBLE"

    [[ "$CRITICAL_MATCH" != "true" ]] && echo "  Reason: Critical binaries differ"
    [[ "$MODULES_MATCH" != "true" ]]  && echo "  Reason: Module classes differ"
    [[ "$FILE_COUNT_MATCH" != "true" ]] && echo "  Reason: File set/count mismatch ($build_count built vs $official_count official)"
    [[ "$FILE_HASH_MATCH" != "true" ]]  && echo "  Reason: $diff_files file(s) have different content (Phase 4)"
    [[ "$META_OK" != "true" ]] && echo "  Reason: package install metadata differs (Phase 5); maintainer scripts may run as root"
    [[ "$EXTRA_OK" != "true" ]] && echo "  Reason: payload outside the application subtree differs (Phase 6)"
fi

sha256sum /official/sparrowwallet* | head -1 | cut -d' ' -f1 > /output/app_hash
cp /commit /output/commit

cat > /output/COMPARISON_RESULTS.yaml << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${STATUS}
notes: |
  Built from source at tag ${SPARROW_VERSION} on Ubuntu 22.04 with Eclipse Temurin
  JDK ${JDK_VERSION} via ./gradlew jpackage; tarball also runs ./gradlew
  packageTarDistribution, so the compared artifact is the archive upstream ships, not
  the pre-packaging jpackage tree. Verdict comes from the file-by-file comparison of
  extracted contents; outer archives (tarball) are hashed and reported as
  archive_identical, not gated on. Built-only lib/runtime/legal/ modules are removed
  first. Phase 5 compares package metadata (deb: control, preinst, postinst, prerm,
  postrm, debian-binary; rpm: PREIN/POSTIN/PREUN/POSTUN scriptlets and interpreters).
  Symlinks compare as links. File sets compared both ways. Not compared: modes,
  ownership, timestamps, directory entries. Phase 6 covers payload outside the subtree.
  critical_binaries=${CRITICAL_MATCH} modules=${MODULES_MATCH} file_count=${FILE_COUNT_MATCH} file_hashes=${FILE_HASH_MATCH} package_metadata=${META_MATCH} out_of_subtree=${EXTRA_MATCH} archive_identical=${ARCHIVE_MATCH}
YAML_END

echo "========================================================"
echo "FINAL VERDICT: $VERDICT"
echo "========================================================"
echo ""
VERIFY_END
    chmod +x verify.sh
}

create_dockerfile() {
    cat > Dockerfile << 'DOCKERFILE_END'
FROM docker.io/library/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    wget \
    git \
    tar \
    xz-utils \
    zstd \
    rpm \
    cpio \
    fakeroot \
    binutils \
    diffutils \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

ARG JDK_VERSION
ARG JDK_FILE
ARG JDK_URL
ARG JDK_SHA256
WORKDIR /opt
RUN wget -q "${JDK_URL}" && \
    echo "${JDK_SHA256}  ${JDK_FILE}" | sha256sum -c - && \
    tar -xzf "${JDK_FILE}" && \
    rm "${JDK_FILE}"

ENV JDK_VERSION=${JDK_VERSION}
ENV JAVA_HOME=/opt/jdk-${JDK_VERSION}
ENV PATH=${JAVA_HOME}/bin:${PATH}

# Clone the requested tag directly, so a cached clone can never miss a newer tag.
ARG SPARROW_VERSION
ENV SPARROW_VERSION=${SPARROW_VERSION}
WORKDIR /build
RUN git clone --recursive --branch "${SPARROW_VERSION}" https://github.com/sparrowwallet/sparrow.git

WORKDIR /build/sparrow
RUN git submodule update --init --recursive && \
    git rev-parse HEAD > /commit && \
    echo "Resolved commit: $(cat /commit)" && git submodule status && \
    UPSTREAM_JDK=$(sed -n "s/.*java-version: *'\([^']*\)'.*/\1/p" .github/workflows/package.yaml | head -1) && \
    echo "Upstream workflow JDK: ${UPSTREAM_JDK:-unknown}; this script: ${JDK_VERSION}" && \
    if [ -n "${UPSTREAM_JDK}" ] && [ "${UPSTREAM_JDK}" != "${JDK_VERSION%%+*}" ]; then \
        echo "JDK_MISMATCH: tag ${SPARROW_VERSION} is built upstream with JDK ${UPSTREAM_JDK}; update this script"; exit 1; \
    fi

ARG BUILD_TYPE
RUN ./gradlew jpackage && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        cd build/jpackage && \
        DEB_FILE=$(ls *.deb | head -1) && \
        echo "Repackaging $DEB_FILE: ZSTD -> XZ compression" && \
        ar x "$DEB_FILE" && \
        unzstd control.tar.zst && \
        unzstd data.tar.zst && \
        xz -c control.tar > control.tar.xz && \
        xz -c data.tar > data.tar.xz && \
        rm "$DEB_FILE" && \
        ar cr "$DEB_FILE" debian-binary control.tar.xz data.tar.xz && \
        rm -f control.tar* data.tar* debian-binary && \
        echo "Repackaging complete: $DEB_FILE"; \
    fi

ARG BUILD_TYPE
RUN mkdir -p /built && \
    if [ "${BUILD_TYPE}" = "deb" ]; then \
        cp build/jpackage/*.deb /built/ && \
        cd /built && \
        DEB_FILE=$(ls *.deb | head -1) && \
        ar x "$DEB_FILE" && \
        tar -xf data.tar.xz && \
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in repackaged deb"; exit 1; } && \
        mv "$SPARROW_DIR" Sparrow && \
        mkdir -p /built/meta/control && \
        (set -- control.tar.*; [ $# -eq 1 ] || { echo "ERROR: $# control archives"; exit 1; }; \
            tar -xf "$1" -C /built/meta/control) && \
        cp debian-binary /built/meta/debian-binary && \
        mkdir -p /built/extra && \
        find . -mindepth 1 -maxdepth 1 ! -name Sparrow ! -name meta ! -name extra \
            ! -name "*.tar.*" ! -name debian-binary ! -name "*.deb" -exec cp -a {} /built/extra/ \; && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    elif [ "${BUILD_TYPE}" = "rpm" ]; then \
        RPM_FILE=$(ls /build/sparrow/build/jpackage/*.rpm 2>/dev/null | head -1) && \
        if [ -z "$RPM_FILE" ]; then \
            echo "ERROR: No .rpm file found in build/jpackage/" && exit 1; \
        fi && \
        cp "$RPM_FILE" /built/ && \
        mkdir -p /tmp/rpm_extract_built && \
        (cd /tmp/rpm_extract_built && rpm2cpio /built/$(basename "$RPM_FILE") | cpio -idmv 2>/dev/null) && \
        SPARROW_DIR=$(find /tmp/rpm_extract_built -maxdepth 6 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in built rpm"; exit 1; } && \
        mv "$SPARROW_DIR" /built/Sparrow && \
        mkdir -p /built/extra && \
        (cd /tmp/rpm_extract_built && cp -a . /built/extra/) && \
        mkdir -p /built/meta/scriptlets && \
        for tag in PREIN POSTIN PREUN POSTUN PRETRANS POSTTRANS PREINPROG POSTINPROG \
                     PREUNPROG POSTUNPROG PRETRANSPROG POSTTRANSPROG; do \
            rpm -qp --qf "%{$tag}" "/built/$(basename "$RPM_FILE")" 2>/dev/null \
                > "/built/meta/scriptlets/$tag"; \
        done; \
    else \
        ./gradlew packageTarDistribution && \
        cd build/jpackage && \
        (set -- *.tar.gz; [ $# -eq 1 ] || { echo "ERROR: $# tarballs"; exit 1; }; \
            echo "Built artifact SHA256:" && sha256sum "$1" && \
            sha256sum "$1" | cut -d' ' -f1 > /built/ARCHIVE_SHA256 && \
            tar -xzf "$1" -C /built); \
    fi

WORKDIR /official
ARG BUILD_TYPE
ARG SPARROW_VERSION
ARG BINARY_PROVIDED=0
COPY sparrow_official_binary /tmp/sparrow_official_binary

RUN if [ "${BUILD_TYPE}" = "deb" ]; then \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet_${SPARROW_VERSION}-1_amd64.deb; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet_${SPARROW_VERSION}-1_amd64.deb; \
        fi && \
        ar x sparrowwallet_${SPARROW_VERSION}-1_amd64.deb && \
        (set -- data.tar.*; [ $# -eq 1 ] || { echo "ERROR: $# data archives"; exit 1; }; \
            tar -xf "$1") && \
        SPARROW_DIR=$(find . -maxdepth 3 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in official deb"; exit 1; } && \
        mv "$SPARROW_DIR" Sparrow && \
        mkdir -p /official/meta/control && \
        (set -- control.tar.*; [ $# -eq 1 ] || { echo "ERROR: $# control archives"; exit 1; }; \
            tar -xf "$1" -C /official/meta/control) && \
        cp debian-binary /official/meta/debian-binary && \
        mkdir -p /official/extra && \
        find . -mindepth 1 -maxdepth 1 ! -name Sparrow ! -name meta ! -name extra \
            ! -name "*.tar.*" ! -name debian-binary ! -name "*.deb" -exec cp -a {} /official/extra/ \; && \
        rm -rf opt usr control.tar.* data.tar.* debian-binary; \
    elif [ "${BUILD_TYPE}" = "rpm" ]; then \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm; \
        fi && \
        mkdir -p /tmp/rpm_extract_official && \
        (cd /tmp/rpm_extract_official && rpm2cpio /official/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm | cpio -idmv 2>/dev/null) && \
        SPARROW_DIR=$(find /tmp/rpm_extract_official -maxdepth 6 -type d \( -name 'Sparrow' -o -name 'sparrow' -o -name 'sparrowwallet' \) | head -1) && \
        [ -n "$SPARROW_DIR" ] || { echo "ERROR: no Sparrow dir in official rpm"; exit 1; } && \
        mv "$SPARROW_DIR" /official/Sparrow && \
        mkdir -p /official/extra && \
        (cd /tmp/rpm_extract_official && cp -a . /official/extra/) && \
        mkdir -p /official/meta/scriptlets && \
        for tag in PREIN POSTIN PREUN POSTUN PRETRANS POSTTRANS PREINPROG POSTINPROG \
                     PREUNPROG POSTUNPROG PRETRANSPROG POSTTRANSPROG; do \
            rpm -qp --qf "%{$tag}" \
                "/official/sparrowwallet-${SPARROW_VERSION}-1.x86_64.rpm" 2>/dev/null \
                > "/official/meta/scriptlets/$tag"; \
        done; \
    else \
        if [ "${BINARY_PROVIDED}" = "1" ]; then \
            cp /tmp/sparrow_official_binary sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
        else \
            wget -q https://github.com/sparrowwallet/sparrow/releases/download/${SPARROW_VERSION}/sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
        fi && \
        sha256sum sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz \
            | cut -d' ' -f1 > /official/ARCHIVE_SHA256 && \
        tar -xzf sparrowwallet-${SPARROW_VERSION}-x86_64.tar.gz; \
    fi

RUN echo "Official artifact SHA256:" && sha256sum /official/sparrowwallet*

# Align legal files: remove extra legal modules from built that are absent in official
RUN if [ -d "/official/Sparrow/lib/runtime/legal" ] && [ -d "/built/Sparrow/lib/runtime/legal" ]; then \
        cd /built/Sparrow/lib/runtime/legal && \
        find . -mindepth 1 -maxdepth 1 -type d | while read -r module_dir; do \
            module="${module_dir#./}"; \
            if [ ! -d "/official/Sparrow/lib/runtime/legal/${module}" ]; then \
                echo "Removed built-only legal module: ${module}"; \
                rm -rf "$module_dir"; \
            fi; \
        done; \
    fi

ARG SCRIPT_VERSION
ARG BUILD_ARCH
ARG BUILD_TYPE
ARG META_STRICT=true
ENV META_STRICT=${META_STRICT}
ENV SCRIPT_VERSION=${SCRIPT_VERSION}
ENV BUILD_ARCH=${BUILD_ARCH}
ENV BUILD_TYPE=${BUILD_TYPE}

COPY verify.sh /verify.sh
RUN chmod +x /verify.sh
RUN /verify.sh

CMD ["cat", "/output/COMPARISON_RESULTS.yaml"]
DOCKERFILE_END
}

display_results() {
    local verdict flags
    verdict=$(grep "^verdict:" "$RESULTS_FILE" | cut -d' ' -f2)
    flags=$(grep -E '^  critical_binaries=' "$RESULTS_FILE" | sed 's/^ *//' || true)

    echo ""
    echo "======================================================"
    echo "RESULTS"
    echo "======================================================"
    cat "$RESULTS_FILE"
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${APP_HASH}"
    echo "commit:         ${APP_COMMIT}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_HASH}"
    echo ""
    echo "Diff:"
    echo "${flags:-${verdict}}"
    echo ""
    echo "===== End Results ====="
    echo "appHash = SHA-256 of the official ${APP_TYPE} as downloaded (or given with --binary); publish this one."
    echo "Full comparison: ${WORK_DIR}/build.log and ${WORK_DIR}/file-comparison.txt"
    echo "YAML: $RESULTS_FILE"
    echo ""

    if [[ "$verdict" == "reproducible" ]]; then
        echo "✅ VERDICT: REPRODUCIBLE"
        echo "Exit code: $EXIT_SUCCESS"
        exit $EXIT_SUCCESS
    else
        echo "❌ VERDICT: ${verdict^^}"
        echo "Exit code: $EXIT_BUILD_FAILED"
        exit $EXIT_BUILD_FAILED
    fi
}

main() {
    SCRIPT_HASH=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1) || true
    SCRIPT_HASH="${SCRIPT_HASH:-N/A}"
    echo "$(basename "$0") ${SCRIPT_VERSION} sha256: ${SCRIPT_HASH}"
    echo ""

    [[ "$(id -u)" -ne 0 ]] || die "Refusing to run as root; run as a normal user" $EXIT_INVALID_PARAMS
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    parse_arguments "$@"
    detect_container_cmd
    keep_existing_results
    build_and_verify
}

main "$@"
