#!/bin/bash
# ==============================================================================
# metamask_build.sh - MetaMask Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.42
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-17
# Project:       https://github.com/MetaMask/metamask-mobile
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs containerized builds and split APK comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Uses official split APKs as the comparison baseline (AAB distribution)
# - Accepts official splits via --binary as either a directory or one split APK
# - Clones source code repository and checks out the exact release tag/commit
# - Performs containerized AAB build using embedded Dockerfile
# - Extracts split APKs with bundletool and a device-spec.json
# - Compares hashes and unzipped contents for each split APK
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Preserves diff artifacts for manual inspection

set -euo pipefail

# Script metadata
readonly SCRIPT_VERSION="v0.1.42"
readonly SCRIPT_NAME="metamask_build.sh"
readonly APP_ID="io.metamask"
readonly REPO_URL="https://github.com/MetaMask/metamask-mobile"
readonly GITHUB_API_BASE="https://api.github.com/repos/MetaMask/metamask-mobile/releases/tags"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"

# Global variables (set by argument parsing)
VERSION=""
ARCH=""
TYPE=""
APK_DIR=""
APK_INPUT_KIND=""
WORK_DIR=""
CONTAINER_RUNTIME=""
IMAGE_NAME=""
TYPE_SAFE=""
ARCH_SAFE=""
VERSION_SAFE=""
SCRIPT_VERSION_SAFE=""
FILES_YAML=""
OFFICIAL_BASE_APK=""
OFFICIAL_APP_HASH=""
OFFICIAL_AAB=""           # path to downloaded official AAB (aab mode)
APP_ID_FROM_APK=""
APK_VERSION_NAME=""
APK_VERSION_CODE=""
SIGNER_SHA256=""
COMMIT_HASH=""
TAG_NAME=""
AGGREGATED_DIFFS=""
BUILD_MODE=""  # "split" (--binary provided: compare vs Google Play splits)
               # "aab"   (--version only: download official AAB, extract splits, compare)
TARGET_SPLIT_APK=""

###############################################################################
# Helper Functions
###############################################################################

log_info() { echo "[INFO] $1"; }
log_pass() { echo "[PASS] $1"; }
log_fail() { echo "[FAIL] $1"; }
log_warn() { echo "[WARNING] $1"; }

sanitize_tag() {
    printf '%s' "$1" | tr '/:@ ' '____' | tr -c 'A-Za-z0-9_.-' '_'
}

container_relpath() {
    local host_path="$1"
    if [[ "$host_path" == "$WORK_DIR/"* ]]; then
        echo "${host_path#"$WORK_DIR"/}"
    else
        echo "$host_path"
    fi
}

container_exec() {
    local cmd="$1"
    $CONTAINER_RUNTIME run --rm \
        -v "$WORK_DIR:/work" \
        -w /work \
        "$IMAGE_NAME" \
        bash -c "$cmd"
}

container_sha256() {
    local host_path="$1"
    local rel_path
    rel_path=$(container_relpath "$host_path")
    container_exec "sha256sum \"$rel_path\" | awk '{print \$1}'"
}

# Zeus-pattern: aapt -> aapt2 -> apktool fallback (never uses filename/path)
container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_RUNTIME} run --rm \
        --volume "${apk_dir}:/apk:ro" \
        "${IMAGE_NAME}" \
        sh -c '
            badging_output="$({ aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
            if [ -n "$badging_output" ]; then
                printf "%s\n" "$badging_output" | sed -n "s/.*'"${field}"'='\''\([^'\'']*\)'\''.*/\1/p" | head -n1
                exit 0
            fi
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
                case "'"${field}"'" in
                    versionName)
                        sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" "$tmpdir/out/apktool.yml" | head -n1
                        ;;
                    versionCode)
                        sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'\''\([^'\'']*\)'\''/\1/p" "$tmpdir/out/apktool.yml" | head -n1
                        ;;
                esac
            fi
            rm -rf "$tmpdir"
        '
}

container_signer() {
    local apk_path="$1"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_RUNTIME} run --rm \
        --volume "${apk_dir}:/apk:ro" \
        "${IMAGE_NAME}" \
        sh -c "apksigner verify --print-certs /apk/${apk_name} | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'"
}

show_disclaimer() {
    log_warn "This script is provided as-is. Review before running. Use at your own risk."
}

find_official_base_apk() {
    local base_apk="$WORK_DIR/official-split-apks/base.apk"
    local base_master="$WORK_DIR/official-split-apks/base-master.apk"

    if [[ -f "$base_apk" ]]; then
        echo "$base_apk"
        return
    fi

    if [[ -f "$base_master" ]]; then
        echo "$base_master"
        return
    fi

    local matches=("$WORK_DIR/official-split-apks"/base*.apk)
    if [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]]; then
        echo "${matches[0]}"
        return
    fi
}

canonicalize_split_apk_name() {
    local apk_name="$1"

    case "$apk_name" in
        base.apk|base-master.apk|standalone.apk)
            echo "base.apk"
            ;;
        split_config.*.apk)
            echo "$apk_name"
            ;;
        base-*.apk)
            echo "split_config.${apk_name#base-}"
            ;;
        *)
            echo "$apk_name"
            ;;
    esac
}

resolve_built_split_apk() {
    local official_apk="$1"
    local built_dir="$2"
    local official_name canonical_name

    official_name="$(basename "$official_apk")"

    if [[ -f "$built_dir/$official_name" ]]; then
        echo "$built_dir/$official_name"
        return 0
    fi

    canonical_name="$(canonicalize_split_apk_name "$official_name")"
    if [[ -f "$built_dir/$canonical_name" ]]; then
        echo "$built_dir/$canonical_name"
        return 0
    fi

    return 1
}

collect_official_metadata() {
    if [[ -z "$OFFICIAL_BASE_APK" || ! -f "$OFFICIAL_BASE_APK" ]]; then
        return
    fi

    if [[ -z "$OFFICIAL_APP_HASH" ]]; then
        OFFICIAL_APP_HASH=$(container_sha256 "$OFFICIAL_BASE_APK")
    fi

    if [[ -n "$IMAGE_NAME" ]]; then
        # Zeus-pattern: aapt -> aapt2 -> apktool fallback, never uses filename
        local version_name_from_apk
        local version_code_from_apk
        version_name_from_apk="$(container_aapt_version "$OFFICIAL_BASE_APK" "versionName" || true)"
        version_code_from_apk="$(container_aapt_version "$OFFICIAL_BASE_APK" "versionCode" || true)"

        if [[ -n "$version_name_from_apk" ]]; then
            APK_VERSION_NAME="$version_name_from_apk"
        fi
        if [[ -n "$version_code_from_apk" ]]; then
            APK_VERSION_CODE="$version_code_from_apk"
        fi

        local signer
        signer="$(container_signer "$OFFICIAL_BASE_APK" || true)"
        if [[ -n "$signer" ]]; then
            SIGNER_SHA256="$signer"
        fi
    fi

    APP_ID_FROM_APK=${APP_ID_FROM_APK:-$APP_ID}
    APK_VERSION_NAME=${APK_VERSION_NAME:-$VERSION}
    APK_VERSION_CODE=${APK_VERSION_CODE:-unknown}
    SIGNER_SHA256=${SIGNER_SHA256:-unknown}
}

collect_build_metadata() {
    local commit_file="$WORK_DIR/built-aab/commit.txt"
    local tag_file="$WORK_DIR/built-aab/tag.txt"

    if [[ -f "$commit_file" ]]; then
        IFS= read -r COMMIT_HASH < "$commit_file"
    else
        COMMIT_HASH="unknown"
    fi

    if [[ -f "$tag_file" ]]; then
        IFS= read -r TAG_NAME < "$tag_file"
    else
        TAG_NAME="none"
    fi
}

aggregate_diff_output() {
    local diff_file
    AGGREGATED_DIFFS=""

    for diff_file in "$WORK_DIR/comparison"/diff_*.txt; do
        local split_name
        [[ -f "$diff_file" ]] || continue

        split_name=$(basename "$diff_file")
        split_name=${split_name#diff_}
        split_name=${split_name%.txt}

        AGGREGATED_DIFFS+=$(printf "=== %s ===\n" "$split_name")
        if [[ -s "$diff_file" ]]; then
            AGGREGATED_DIFFS+=$(cat "$diff_file")
            AGGREGATED_DIFFS+=$'\n'
        else
            AGGREGATED_DIFFS+="(no differences)"
            AGGREGATED_DIFFS+=$'\n'
        fi
        AGGREGATED_DIFFS+=$'\n'
    done
}

print_results_block() {
    local verdict="$1"
    local should_cleanup="${2:-false}"

    collect_official_metadata
    collect_build_metadata
    aggregate_diff_output

    local app_id_value="${APP_ID_FROM_APK:-$APP_ID}"

    # Parse tag/signature verification output
    local tag_verify_output
    tag_verify_output="$(cat "${WORK_DIR}/built-aab/tag_verify.txt" 2>/dev/null || true)"

    local tag_type="unknown"
    local tag_signature_status="[WARNING] Tag signature not checked"
    local commit_signature_status="[WARNING] No valid signature found on commit"
    local signature_keys=""
    local signature_warnings=""

    if echo "${tag_verify_output}" | grep -q "TAG_TYPE=tag"; then
        tag_type="annotated"
        if echo "${tag_verify_output}" | grep -q "Good signature"; then
            tag_signature_status="[OK] Good signature on annotated tag"
            local tag_key
            tag_key="$(echo "${tag_verify_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9a-f]+).*/\1/' | tail -1)"
            [[ -n "${tag_key}" ]] && signature_keys="Tag signed with: ${tag_key}"
        else
            tag_signature_status="[WARNING] No valid signature found on annotated tag"
            signature_warnings="- Annotated tag exists but is not signed"
        fi
    elif echo "${tag_verify_output}" | grep -q "LIGHTWEIGHT_TAG"; then
        tag_type="lightweight"
        tag_signature_status="[INFO] Tag is lightweight (cannot contain signature)"
    elif echo "${tag_verify_output}" | grep -qE "TAG_TYPE=missing|NO_TAG"; then
        tag_type="missing"
        tag_signature_status="[WARNING] Tag not found in repository"
    fi

    local commit_section
    commit_section="$(echo "${tag_verify_output}" | sed -n '/---COMMIT---/,$p')"
    if echo "${commit_section}" | grep -q "Good signature"; then
        commit_signature_status="[OK] Good signature on commit"
        local commit_key
        commit_key="$(echo "${commit_section}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9a-f]+).*/\1/' | tail -1)"
        if [[ -n "${commit_key}" ]]; then
            [[ -n "${signature_keys}" ]] && \
                signature_keys="${signature_keys}\nCommit signed with: ${commit_key}" || \
                signature_keys="Commit signed with: ${commit_key}"
        fi
    else
        commit_signature_status="[WARNING] No valid signature found on commit"
        [[ -z "${signature_warnings}" ]] && \
            signature_warnings="- Commit is not signed" || \
            signature_warnings="${signature_warnings}\n- Commit is not signed"
    fi

    # Build diff guide
    local diff_guide=""
    if [[ "${should_cleanup}" != "true" ]]; then
        diff_guide="
Run a full
diff --recursive ${WORK_DIR}/comparison/official_* ${WORK_DIR}/comparison/built_*
meld ${WORK_DIR}/official-split-apks ${WORK_DIR}/built-split-apks
or
diffoscope ${WORK_DIR}/official-split-apks ${WORK_DIR}/built-split-apks
for more details."
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${app_id_value}"
    echo "signer:         ${SIGNER_SHA256}"
    echo "apkVersionName: ${APK_VERSION_NAME}"
    echo "apkVersionCode: ${APK_VERSION_CODE}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${OFFICIAL_APP_HASH:-N/A}"
    echo "commit:         ${COMMIT_HASH}"
    echo ""
    echo "Diff:"
    if [[ -n "${AGGREGATED_DIFFS}" ]]; then
        # Show first 20 lines of aggregated diffs, truncate if long
        local diff_line_count
        diff_line_count="$(echo "${AGGREGATED_DIFFS}" | grep -c '^' || true)"
        local diff_preview
        diff_preview="$(echo "${AGGREGATED_DIFFS}" | head -20 || true)"
        echo "${diff_preview}"
        if [[ "${diff_line_count}" -gt 20 ]]; then
            echo "... (${diff_line_count} total lines — full diffs in: ${WORK_DIR}/comparison/)"
        fi
    else
        echo "(no comparison performed)"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "${tag_verify_output}" | grep -v '^TAG_TYPE=' | grep -v '^---COMMIT---' || true
    echo ""
    echo "Signature Summary:"
    echo "Tag type: ${tag_type}"
    echo "${tag_signature_status}"
    echo "${commit_signature_status}"
    if [[ -n "${signature_keys}" ]]; then
        echo ""
        echo "Keys used:"
        echo -e "${signature_keys}"
    fi
    if [[ -n "${signature_warnings}" ]]; then
        echo ""
        echo "Warnings:"
        echo -e "${signature_warnings}"
    fi
    echo ""
    echo "===== End Results ====="
    echo "${diff_guide}"
}

# Detect container runtime (podman preferred, then docker)
detect_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_RUNTIME="podman"
        log_info "Using podman as container runtime"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
        log_info "Using docker as container runtime"
    else
        log_fail "Neither podman nor docker found. Please install one of them."
        exit 1
    fi
}

# Print usage information
usage() {
    cat << EOF
NAME
       ${SCRIPT_NAME} - MetaMask Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --binary <split_apk_dir_or_file> [OPTIONS]
       ${SCRIPT_NAME} --version <version> --arch <arch> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Builds MetaMask from source (AAB via bundleProdRelease) and compares
       against official artifacts via split APK comparison using bundletool.

       --binary mode: compares built AAB splits against Google Play split APKs
         provided by the user (extracted from a device or downloaded via
         apkpure/etc.). The path may be a directory of splits or a single
         split APK file. Version is auto-detected from the provided APK content.

       --version mode: downloads the official AAB from GitHub releases, extracts
         splits from both the official and built AAB using bundletool with the
         given device spec (--arch), then compares split by split.

OPTIONS
       --binary <path>     Directory containing official Google Play split APKs,
                           or a single official split APK file.
                           Version auto-detected from APK content.
       --apk <path>        Alias for --binary.
       --version <version> Version to build (e.g. 7.69.0). Required when
                           --binary is not provided.
       --arch <arch>       Target architecture for device spec (bundletool).
                           Required when --binary is not provided.
                           Supported: arm64-v8a, armeabi-v7a, x86_64, x86.
                           Default (--binary mode): arm64-v8a.
       --type <type>       Accepted for build server compatibility.
       --script-version    Print script version and exit.
       --help              Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF signing differences across all splits)
       1    Differences found or build failure
       2    Invalid parameters

EXAMPLES
       ${SCRIPT_NAME} --binary ~/apks/io.metamask/7.69.0/
       ${SCRIPT_NAME} --binary ~/apks/io.metamask/7.69.0/split_config.arm64_v8a.apk
       ${SCRIPT_NAME} --version 7.69.0 --arch arm64-v8a
       ${SCRIPT_NAME} --version 7.69.0 --arch arm64-v8a --type release
EOF
    exit 0
}

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)   VERSION="$2";  shift 2 ;;
            --arch)      ARCH="$2";     shift 2 ;;
            --type)      TYPE="$2";     shift 2 ;;
            --apk|--binary) APK_DIR="$2"; shift 2 ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help)   usage ;;
            *)           log_warn "Ignoring unknown parameter: $1"; shift ;;
        esac
    done

    # At least one of --binary or --version must be provided
    if [[ -z "$APK_DIR" && -z "$VERSION" ]]; then
        log_fail "Provide --binary <path> (Google Play splits dir or single split APK) or --version <version> (auto-download AAB)"
        echo "Run '${SCRIPT_NAME} --help' for usage."
        exit 2
    fi

    # Determine build mode
    if [[ -n "$APK_DIR" ]]; then
        BUILD_MODE="split"
        if [[ -d "$APK_DIR" ]]; then
            APK_INPUT_KIND="dir"
        elif [[ -f "$APK_DIR" ]]; then
            APK_INPUT_KIND="file"
        else
            log_fail "--binary path not found: $APK_DIR"
            generate_comparison_yaml "ftbfs" "--binary path not found: $APK_DIR"
            exit 2
        fi
        log_info "Using official split input as ${APK_INPUT_KIND}: $APK_DIR"
        # --arch defaults to arm64-v8a in split mode (used for built AAB extraction)
        if [[ -z "$ARCH" ]]; then
            ARCH="arm64-v8a"
            log_info "Using default architecture for built AAB extraction: $ARCH"
        fi
    else
        BUILD_MODE="aab"
        # --arch is required in aab mode (defines the device spec for both extractions)
        if [[ -z "$ARCH" ]]; then
            log_fail "--arch is required when --binary is not provided (e.g. --arch arm64-v8a)"
            exit 2
        fi
    fi

    # Validate architecture
    case "$ARCH" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            log_fail "Unsupported architecture: $ARCH (supported: arm64-v8a, armeabi-v7a, x86_64, x86)"
            exit 2
            ;;
    esac

    TYPE_SAFE=$(sanitize_tag "${TYPE:-default}")
    ARCH_SAFE=$(sanitize_tag "$ARCH")
    # VERSION may be empty in split mode until auto-detected from APK content in prepare()
    VERSION_SAFE=$(sanitize_tag "${VERSION:-provided}")
    SCRIPT_VERSION_SAFE=$(sanitize_tag "$SCRIPT_VERSION")

    WORK_DIR="/tmp/test_${APP_ID}_${VERSION_SAFE}_${ARCH_SAFE}_${TYPE_SAFE}"
    IMAGE_NAME="metamask-build-${VERSION_SAFE}-${ARCH_SAFE}-${TYPE_SAFE}-${SCRIPT_VERSION_SAFE}"
    log_info "Build mode: $BUILD_MODE"
    log_info "Work directory: $WORK_DIR"
    log_info "Container image tag: $IMAGE_NAME"
}

# Cleanup function for error handling
cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_warn "Script failed with exit code: $exit_code"
        log_warn "Work directory preserved for debugging: $WORK_DIR"
        if [[ -n "${WORK_DIR:-}" && ! -f "${WORK_DIR}/COMPARISON_RESULTS.yaml" ]]; then
            generate_error_yaml "ftbfs" 2>/dev/null || true
        fi
    fi
}

on_error() {
    local exit_code=$?
    local line_no=$1
    set +e
    log_fail "Script failed at line ${line_no} (exit code ${exit_code})"
    if [[ -n "${WORK_DIR:-}" ]]; then
        generate_error_yaml "ftbfs" 2>/dev/null || true
        if [[ -n "${IMAGE_NAME:-}" ]]; then
            ${CONTAINER_RUNTIME} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    echo "Exit code: 1"
    exit 1
}

trap 'on_error $LINENO' ERR
trap cleanup_on_error EXIT

###############################################################################
# Firebase Configuration (extracted from official APK)
###############################################################################

# Firebase config extracted from MetaMask 7.63.0 official APK
# These values are public and visible in the APK's strings.xml
create_google_services_json() {
    local output_path="$1"

    cat > "$output_path" << 'FIREBASE_EOF'
{
  "project_info": {
    "project_number": "824598429541",
    "project_id": "metamask-mobile",
    "storage_bucket": "metamask-mobile.appspot.com"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:824598429541:android:d3ab9dbb55e13514beab8c",
        "android_client_info": {
          "package_name": "io.metamask"
        }
      },
      "api_key": [
        {
          "current_key": "AIzaSyCSDViJbOOO2RXFwNdb80ZLFcsDUJ9DGHk"
        }
      ]
    }
  ],
  "configuration_version": "1"
}
FIREBASE_EOF

    log_info "Created google-services.json with Firebase config"
}

###############################################################################
# Dockerfile Generation (embedded for standalone operation)
###############################################################################

create_dockerfile() {
    local dockerfile_path="$1"
    local version="$2"

    cat > "$dockerfile_path" << 'DOCKERFILE_EOF'
# MetaMask Android Build Environment
# Based on forensic analysis of version 7.63.0

FROM node:20-bookworm

LABEL maintainer="WalletScrutiny"
LABEL description="MetaMask Android reproducible build environment"

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/35.0.0"

# Install system dependencies
# Note: cmake required by some RN native modules with C++ code
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ca-certificates-java \
    curl \
    git \
    gnupg \
    unzip \
    zip \
    wget \
    openjdk-17-jdk \
    build-essential \
    python3 \
    ruby-full \
    cmake \
    ninja-build \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set JAVA_HOME
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV JAVA_TOOL_OPTIONS="-Dhttps.protocols=TLSv1.2"

# Install Android SDK command-line tools
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd ${ANDROID_HOME}/cmdline-tools && \
    wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O cmdline-tools.zip && \
    unzip cmdline-tools.zip && \
    rm cmdline-tools.zip && \
    mv cmdline-tools latest

# Accept Android SDK licenses and install components
# Note: Various RN modules target different SDK versions (legacy modules need 24-27)
# Pre-install all to avoid Gradle auto-install failures (SDK dir not writable)
RUN yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" \
               "platforms;android-24" \
               "platforms;android-25" \
               "platforms;android-26" \
               "platforms;android-27" \
               "platforms;android-28" \
               "platforms;android-29" \
               "platforms;android-30" \
               "platforms;android-31" \
               "platforms;android-32" \
               "platforms;android-33" \
               "platforms;android-34" \
               "platforms;android-35" \
               "build-tools;34.0.0" \
               "build-tools;35.0.0" \
               "ndk;26.1.10909125"

ENV ANDROID_NDK_HOME=${ANDROID_HOME}/ndk/26.1.10909125

# AGP requires cmake;3.22.1 by name. sdkmanager cmake binaries are built for older Linux
# and may not install reliably on Debian 12 Bookworm. cmake is already installed via apt above
# (cmake 3.25.x, natively compiled for Bookworm). Stub it into the exact SDK path AGP expects:
# AGP auto-discovers cmake versions under $ANDROID_HOME/cmake/ and will find 3.22.1/bin/cmake.
RUN mkdir -p ${ANDROID_HOME}/cmake/3.22.1/bin && \
    for tool in cmake ctest cpack; do \
        ln -sf "$(which $tool)" "${ANDROID_HOME}/cmake/3.22.1/bin/$tool"; \
    done && \
    echo "SDK cmake 3.22.1 stub using system cmake:" && \
    ${ANDROID_HOME}/cmake/3.22.1/bin/cmake --version
RUN test -f ${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake && \
    echo "NDK toolchain verified at ${ANDROID_NDK_HOME}" || \
    (echo "ERROR: NDK toolchain not found at ${ANDROID_NDK_HOME}" && exit 1)

# MetaMask production builds look for Bitrise's NDK path.
# Mirror our installed NDK there so upstream Gradle logic resolves the same path.
RUN mkdir -p /usr/local/share/android-sdk && \
    ln -sfn "${ANDROID_NDK_HOME}" /usr/local/share/android-sdk/ndk-bundle

# Enable Yarn via corepack
RUN corepack enable && corepack prepare yarn@4.10.3 --activate

# Create build user (non-root)
RUN useradd -m -s /bin/bash builder
USER builder
WORKDIR /home/builder

# Clone repository (version will be checked out by build script)
ARG REPO_URL
ARG VERSION
RUN git clone --depth 1 ${REPO_URL} metamask-mobile || \
    git clone ${REPO_URL} metamask-mobile

WORKDIR /home/builder/metamask-mobile

# Build script will handle checkout and build
DOCKERFILE_EOF

    log_info "Created Dockerfile for MetaMask build"
}

###############################################################################
# Build Script (runs inside container)
###############################################################################

create_build_script() {
    local script_path="$1"
    local version="$2"
    local target_arch="$3"

    cat > "$script_path" << BUILDSCRIPT_EOF
#!/bin/bash
set -euo pipefail

VERSION="$version"
TARGET_ARCH="$target_arch"
OFFICIAL_REACT_NATIVE_ARCHES="armeabi-v7a,arm64-v8a,x86,x86_64"
echo "Building MetaMask version: \$VERSION"
echo "Target extraction architecture: \$TARGET_ARCH"
echo "React Native build architectures: \$OFFICIAL_REACT_NATIVE_ARCHES"

cd /home/builder/metamask-mobile

# Fetch all tags and find the correct one
git fetch --all --tags --prune

# Try different tag formats
TAG=""
for tag_format in "v\${VERSION}" "\${VERSION}" "release/\${VERSION}"; do
    if git rev-parse "\$tag_format"; then
        TAG="\$tag_format"
        break
    fi
done

if [[ -z "\$TAG" ]]; then
    echo "Tag not found, searching commits..."
    COMMIT=\$(git log --all --oneline --grep="\$VERSION" | head -1 | awk '{print \$1}')
    if [[ -n "\$COMMIT" ]]; then
        git checkout "\$COMMIT"
    else
        echo "ERROR: Cannot find version \$VERSION in repository"
        exit 1
    fi
else
    echo "Found tag: \$TAG"
    git checkout "\$TAG"
fi

COMMIT=\$(git rev-parse HEAD)
echo "Checked out commit: \$COMMIT"

mkdir -p /output
echo "\$COMMIT" > /output/commit.txt

# Tag and signature verification
TAG_TYPE=\$(git cat-file -t "refs/tags/\${TAG}" 2>/dev/null || echo "missing")
printf "TAG_TYPE=%s\n" "\${TAG_TYPE}" > /output/tag_verify.txt
if [ "\${TAG_TYPE}" = "tag" ]; then
    git tag -v "\${TAG}" >> /output/tag_verify.txt 2>&1 || true
elif [ "\${TAG_TYPE}" = "commit" ]; then
    printf "LIGHTWEIGHT_TAG\n" >> /output/tag_verify.txt
else
    printf "NO_TAG\n" >> /output/tag_verify.txt
fi
printf '%s\n' "---COMMIT---" >> /output/tag_verify.txt
git verify-commit HEAD >> /output/tag_verify.txt 2>&1 || true

if git describe --tags --exact-match 2>/dev/null; then
    echo "\$(git describe --tags --exact-match)" > /output/tag.txt
else
    echo "none" > /output/tag.txt
fi

# Copy google-services.json if provided
if [[ -f /build-config/google-services.json ]]; then
    cp /build-config/google-services.json android/app/google-services.json
    echo "Copied google-services.json"
fi

# Set up environment
export METAMASK_BUILD_TYPE="main"
export METAMASK_ENVIRONMENT="production"
export NODE_OPTIONS="--max-old-space-size=4096"
export METRO_MAX_WORKERS="4"
export CI="true"
# Disable Sentry uploads (no auth in reproducible build container)
export SENTRY_DISABLE_AUTO_UPLOAD=true
export WS_DISABLE_SENTRY_UPLOAD=true
# Prevent Gradle from re-downloading Boost
export WS_DISABLE_BOOST_DOWNLOAD=true
export WS_DISABLE_BOOST_PREPARE=true

# Copy CI gradle properties
if [[ -f android/gradle.properties.github ]]; then
    cp android/gradle.properties.github android/gradle.properties
fi

# MetaMask production builds compile all four ABIs into the AAB.
# Keep the upstream ABI list for the build, then use TARGET_ARCH only when
# extracting device-specific split APKs from the finished AAB.
if [[ -f android/gradle.properties ]]; then
    if grep -q '^reactNativeArchitectures=' android/gradle.properties; then
        sed -i "s/^reactNativeArchitectures=.*/reactNativeArchitectures=\${OFFICIAL_REACT_NATIVE_ARCHES}/" android/gradle.properties
    else
        printf '%s\n' "reactNativeArchitectures=\${OFFICIAL_REACT_NATIVE_ARCHES}" >> android/gradle.properties
    fi
else
    printf '%s\n' "reactNativeArchitectures=\${OFFICIAL_REACT_NATIVE_ARCHES}" > android/gradle.properties
fi

# Ensure Gradle has enough memory for large builds
if [[ -f android/gradle.properties ]]; then
    if ! grep -q "org.gradle.jvmargs" android/gradle.properties; then
        echo "org.gradle.jvmargs=-Xmx4096m -XX:+HeapDumpOnOutOfMemoryError" >> android/gradle.properties
    fi
else
    echo "org.gradle.jvmargs=-Xmx4096m -XX:+HeapDumpOnOutOfMemoryError" > android/gradle.properties
fi

# Install dependencies
echo "Installing dependencies..."
yarn install --immutable || yarn install

# Run setup if available (avoid broken pipe from grep -q)
YARN_RUN_LOG=\$(mktemp)
yarn run 2>&1 | tee "\$YARN_RUN_LOG" || true
if grep -q "setup:github-ci" "\$YARN_RUN_LOG"; then
    yarn setup:github-ci || true
fi
rm -f "\$YARN_RUN_LOG"

# Disable Sentry upload tasks (container-only patch)
sentry_gradle="node_modules/@sentry/react-native/sentry.gradle"
if [[ -f "\$sentry_gradle" ]]; then
    echo "Disabling Sentry upload tasks in sentry.gradle..."
    if ! grep -q "WS_DISABLE_SENTRY_UPLOAD" "\$sentry_gradle"; then
        cat << 'SENTRY_PATCH' > /tmp/ws-sentry-disable.groovy
if (System.getenv("WS_DISABLE_SENTRY_UPLOAD") == "true") {
    gradle.taskGraph.whenReady { graph ->
        graph.allTasks.each { t ->
            if (t.name.toLowerCase().contains("sentryupload")) {
                t.enabled = false
            }
        }
    }
}
SENTRY_PATCH
        cat /tmp/ws-sentry-disable.groovy "\$sentry_gradle" > /tmp/ws-sentry.gradle
        mv /tmp/ws-sentry.gradle "\$sentry_gradle"
    fi
fi

# Patch ALL deprecated Gradle dependency configurations in node_modules
# Gradle 8.x removed these deprecated configurations:
#   compile -> implementation
#   testCompile -> testImplementation
#   androidTestCompile -> androidTestImplementation
#   provided -> compileOnly
#   apk -> runtimeOnly
# Global patch prevents whack-a-mole fixes for each module.
echo "NOTE: Patches are applied inside the container only; host repo is unchanged."
echo "Patching all node_modules build.gradle files (deprecated configs)..."
find node_modules -name "build.gradle" -type f 2>/dev/null | while read -r gradle_file; do
    if grep -qE "^[[:space:]]*(compile|testCompile|androidTestCompile|provided|apk)[[:space:]]+" "\$gradle_file" 2>/dev/null; then
        echo "  Patching: \$gradle_file"
        sed -i -E '
            s/^([[:space:]]*)androidTestCompile([[:space:]]+)/\1androidTestImplementation\2/
            s/^([[:space:]]*)testCompile([[:space:]]+)/\1testImplementation\2/
            s/^([[:space:]]*)compile([[:space:]]+)/\1implementation\2/
            s/^([[:space:]]*)provided([[:space:]]+)/\1compileOnly\2/
            s/^([[:space:]]*)apk([[:space:]]+)/\1runtimeOnly\2/
        ' "\$gradle_file"
    fi
done
echo "Gradle dependency configuration patches complete."

# Patch low compileSdkVersion in node_modules to satisfy Java 9+ compilation
echo "Patching node_modules compileSdkVersion < 30..."
find node_modules -name "build.gradle" -type f 2>/dev/null | while read -r gradle_file; do
    if grep -qE "compileSdkVersion[[:space:]]*=?[[:space:]]*[0-2][0-9]" "\$gradle_file" 2>/dev/null; then
        echo "  Updating compileSdkVersion in: \$gradle_file"
        sed -i -E '
            s/(compileSdkVersion[[:space:]]*=?[[:space:]]*)([0-2][0-9])([^0-9])/\130\3/g
            s/(compileSdkVersion[[:space:]]*=?[[:space:]]*)([0-2][0-9])$/\130/g
        ' "\$gradle_file"
    fi
done
echo "compileSdkVersion patch complete."

# Resolve ReactAndroid layout across React Native versions
react_android_dir=""
react_native_gradle_root=""
if [[ -d node_modules/react-native/packages/react-native/ReactAndroid ]]; then
    react_android_dir="node_modules/react-native/packages/react-native/ReactAndroid"
    react_native_gradle_root="node_modules/react-native/packages/react-native"
elif [[ -d node_modules/react-native/ReactAndroid ]]; then
    react_android_dir="node_modules/react-native/ReactAndroid"
    react_native_gradle_root="node_modules/react-native"
else
    echo "ERROR: Could not locate ReactAndroid directory under node_modules/react-native"
    exit 1
fi

# Refresh Boost tarball to avoid corrupt downloads
boost_dir="\${react_android_dir}/build/downloads"
boost_tar="\$boost_dir/boost_1_83_0.tar.gz"
boost_url=""
if [[ -f "\$boost_tar" ]]; then
    echo "Removing cached Boost tarball to force re-download..."
    rm -f "\$boost_tar"
fi
boost_url=\$(grep -R "boost_1_83_0.tar.gz" -n "\$react_android_dir" 2>/dev/null | \
    sed -n 's/.*\\(https[^\"'"'"']*boost_1_83_0.tar.gz\\).*/\\1/p' | head -1 || true)
boost_urls=()
if [[ -n "\$boost_url" ]]; then
    boost_urls+=("\$boost_url")
fi
boost_urls+=("https://archives.boost.io/release/1.83.0/source/boost_1_83_0.tar.gz")
boost_urls+=("https://boostorg.jfrog.io/artifactory/main/release/1.83.0/source/boost_1_83_0.tar.gz")

mkdir -p "\$boost_dir"
download_ok=0
for url in "\${boost_urls[@]}"; do
    echo "Downloading Boost from: \$url"
    if curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -o "\$boost_tar" "\$url"; then
        if tar -tzf "\$boost_tar" >/dev/null 2>&1; then
            download_ok=1
            break
        fi
    fi
    rm -f "\$boost_tar"
done

if [[ "\$download_ok" -ne 1 ]]; then
    echo "ERROR: Boost tarball verification failed"
    exit 1
fi
echo "Repacking Boost tarball for Gradle compatibility..."
tmp_boost_dir=\$(mktemp -d)
tar -xzf "\$boost_tar" -C "\$tmp_boost_dir"
rm -f "\$boost_tar"
tar -czf "\$boost_tar" -C "\$tmp_boost_dir" .
rm -rf "\$tmp_boost_dir"

# Pre-extract Boost to expected build directory and skip prepareBoost
boost_extract_dir="\${react_android_dir}/build/third-party-ndk/boost_1_83_0"
rm -rf "\$boost_extract_dir"
mkdir -p "\$boost_extract_dir"
tar -xzf "\$boost_tar" -C "\$boost_extract_dir" --strip-components=1

# Disable Gradle Boost download task to avoid overwriting verified tarball
boost_gradle="\${react_android_dir}/build.gradle"
if [[ -f "\$boost_gradle" ]]; then
    if ! grep -q "WS_DISABLE_BOOST_DOWNLOAD" "\$boost_gradle"; then
        cat << 'BOOST_PATCH' >> "\$boost_gradle"
if (System.getenv("WS_DISABLE_BOOST_DOWNLOAD") == "true") {
    tasks.matching { it.name.toLowerCase().contains("downloadboost") }.configureEach { t ->
        t.enabled = false
    }
}
if (System.getenv("WS_DISABLE_BOOST_PREPARE") == "true") {
    tasks.matching { it.name.toLowerCase().contains("prepareboost") }.configureEach { t ->
        t.enabled = false
    }
}
BOOST_PATCH
    fi
fi

# Write local.properties for the app build and all react-native included-build roots.
# cmake.dir points to the system cmake stub we created in the Dockerfile at the SDK cmake
# path. Unlike v0.1.32 (dangling symlink), this stub contains a working cmake binary.
# We write to four locations:
#   1. android/local.properties          — root Android project
#   2. node_modules/react-native/        — included build ROOT (includeBuild path in settings.gradle)
#   3. react_native_gradle_root/         — packages/react-native subproject
#   4. react_android_dir/                — ReactAndroid subproject
write_local_properties() {
    local target_file="\$1"
    mkdir -p "\$(dirname "\$target_file")"
    {
        printf '%s\n' "sdk.dir=\${ANDROID_HOME}"
        printf '%s\n' "ndk.dir=\${ANDROID_NDK_HOME}"
        printf '%s\n' "cmake.dir=\${ANDROID_HOME}/cmake/3.22.1"
    } > "\$target_file"
}

write_local_properties android/local.properties
write_local_properties "node_modules/react-native/local.properties"
write_local_properties "\${react_native_gradle_root}/local.properties"
write_local_properties "\${react_android_dir}/local.properties"

echo "=== cmake discovery ==="
ls -la "\${ANDROID_HOME}/cmake/" 2>/dev/null || echo "no cmake dir in SDK"
ls -la "\${ANDROID_HOME}/cmake/3.22.1/bin/" 2>/dev/null || echo "no cmake 3.22.1 stub"
"\${ANDROID_HOME}/cmake/3.22.1/bin/cmake" --version 2>/dev/null || echo "cmake stub not executable"
echo "NDK selected for build:"
printf '%s\n' "\${ANDROID_NDK_HOME}"
ls -ld /usr/local/share/android-sdk/ndk-bundle
test -f /usr/local/share/android-sdk/ndk-bundle/source.properties && echo "Bitrise NDK shim ready"

# Build the AAB
echo "Building Android AAB..."
cd android
./gradlew bundleProdRelease \
    --no-daemon \
    --stacktrace \
    --info \
    -PreactNativeArchitectures="\${OFFICIAL_REACT_NATIVE_ARCHES}" || {
    echo "=== BUILD FAILED — cmake config logs ==="
    find .. -path '*/.cxx*' \( -name "*.txt" -o -name "*.log" -o -name "cmake_server_log*" \) 2>/dev/null \
        | head -20 \
        | while IFS= read -r f; do
            echo "--- \$f ---"
            cat "\$f" 2>/dev/null
        done
    echo "=== cmake prefab logs ==="
    find .. -path '*/prefab*' -name "*.json" 2>/dev/null | head -5 | while IFS= read -r f; do
        echo "--- \$f ---"
        cat "\$f" 2>/dev/null
    done
    exit 1
}

echo "Build complete!"
ls -la app/build/outputs/bundle/prodRelease/ || ls -la app/build/outputs/bundle/*/

BUILDSCRIPT_EOF

    chmod +x "$script_path"
    log_info "Created build script"
}

###############################################################################
# Device Spec Generation
###############################################################################

create_device_spec() {
    local spec_path="$1"
    local arch="$2"

    # Convert architecture name to ABI format
    local abi="$arch"
    case "$arch" in
        arm64-v8a) abi="arm64-v8a" ;;
        armeabi-v7a) abi="armeabi-v7a" ;;
        x86_64) abi="x86_64" ;;
        x86) abi="x86" ;;
    esac

    cat > "$spec_path" << DEVICESPEC_EOF
{
  "supportedAbis": ["$abi"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 33
}
DEVICESPEC_EOF

    log_info "Created device-spec.json for architecture: $arch"
}

###############################################################################
# Split APK Extraction using bundletool
###############################################################################

extract_split_apks_from_aab() {
    local aab_path="$1"
    local output_dir="$2"
    local device_spec="$3"

    log_info "Extracting split APKs from AAB using bundletool..."

    local aab_base
    local device_spec_base
    local output_base

    aab_base=$(basename "$aab_path")
    device_spec_base=$(basename "$device_spec")
    output_base=$(basename "$output_dir")

    $CONTAINER_RUNTIME run --rm \
        -v "$WORK_DIR:/work" \
        -w /work \
        "$IMAGE_NAME" \
        bash -c "set -euo pipefail
            shopt -s nullglob
            if [[ ! -f bundletool.jar ]]; then
                curl -L 'https://github.com/google/bundletool/releases/download/1.15.6/bundletool-all-1.15.6.jar' \
                    -o bundletool.jar
            fi
            rm -f built.apks
            rm -rf \"$output_base\"
            java -jar bundletool.jar build-apks \
                --bundle=\"built-aab/$aab_base\" \
                --output=\"built.apks\" \
                --device-spec=\"$device_spec_base\" \
                --mode=default \
                --overwrite
            mkdir -p \"$output_base\"
            unzip -o built.apks -d \"$output_base\"
            if [[ -d \"$output_base/splits\" ]]; then
                mv \"$output_base\"/splits/*.apk \"$output_base\"/ || true
                rmdir \"$output_base/splits\" || true
            fi
            if [[ -f \"$output_base/base-master.apk\" ]]; then
                mv \"$output_base/base-master.apk\" \"$output_base/base.apk\"
            fi
            if [[ -f \"$output_base/standalones/standalone.apk\" ]]; then
                mv \"$output_base/standalones/standalone.apk\" \"$output_base/base.apk\"
            fi
            rmdir \"$output_base/standalones\" || true
            for split_apk in \"$output_base\"/base-*.apk; do
                split_name=\$(basename \"\$split_apk\")
                if [[ \"\$split_name\" == \"base-master.apk\" ]]; then
                    continue
                fi
                split_suffix=\${split_name#base-}
                mv \"\$split_apk\" \"$output_base/split_config.\$split_suffix\"
            done
        "

    log_pass "Extracted split APKs to: $output_dir"
    local output_rel
    output_rel=$(container_relpath "$output_dir")
    container_exec "ls -la \"$output_rel\"/*.apk || ls -la \"$output_rel\""
}

unzip_apk_in_container() {
    local apk_path="$1"
    local dest_dir="$2"

    local apk_dir
    local apk_file
    local dest_parent
    local dest_base

    apk_dir=$(dirname "$apk_path")
    apk_file=$(basename "$apk_path")
    dest_parent=$(dirname "$dest_dir")
    dest_base=$(basename "$dest_dir")

    $CONTAINER_RUNTIME run --rm \
        -v "$apk_dir:/apk:ro" \
        -v "$dest_parent:/out" \
        "$IMAGE_NAME" \
        bash -c "set -euo pipefail
            rm -rf \"/out/$dest_base\"
            mkdir -p \"/out/$dest_base\"
            unzip -o \"/apk/$apk_file\" -d \"/out/$dest_base\"
        "
}

###############################################################################
# APK Comparison
###############################################################################

compare_split_apks() {
    local official_dir="$1"
    local built_dir="$2"
    local results_dir="$3"

    log_info "Comparing split APKs..."

    mkdir -p "$results_dir"

    local total_diffs=0
    local total_meta_only=0
    FILES_YAML=""
    COMPARISON_TXT=""

    # Process each official APK
    for official_apk in "$official_dir"/*.apk; do
        [[ ! -f "$official_apk" ]] && continue

        local apk_name
        local built_apk
        local comparison_name
        apk_name=$(basename "$official_apk")
        built_apk="$(resolve_built_split_apk "$official_apk" "$built_dir" || true)"
        comparison_name="$(basename "${built_apk:-$official_apk}")"

        if [[ -z "$built_apk" || ! -f "$built_apk" ]]; then
            log_warn "Built APK not found for official split: $apk_name"
            FILES_YAML+="      - filename: $comparison_name\n"
            FILES_YAML+="        hash: missing\n"
            FILES_YAML+="        match: false\n"
            COMPARISON_TXT+="$comparison_name - $ARCH - missing - 0\n"
            ((total_diffs++))
            continue
        fi

        # Calculate hashes (inside container)
        local official_hash
        local built_hash
        official_hash=$(container_sha256 "$official_apk")
        built_hash=$(container_sha256 "$built_apk")

        log_info "Comparing official $apk_name against built $comparison_name..."
        log_info "  Official: $official_hash"
        log_info "  Built:    $built_hash"

        # Unzip and compare contents (in container)
        local official_unzip="$results_dir/official_${comparison_name%.apk}"
        local built_unzip="$results_dir/built_${comparison_name%.apk}"

        unzip_apk_in_container "$official_apk" "$official_unzip"
        unzip_apk_in_container "$built_apk" "$built_unzip"

        # Run diff (inside container)
        local diff_file="$results_dir/diff_${comparison_name%.apk}.txt"
        local official_rel
        local built_rel
        local diff_rel
        official_rel=$(container_relpath "$official_unzip")
        built_rel=$(container_relpath "$built_unzip")
        diff_rel=$(container_relpath "$diff_file")
        container_exec "diff -r \"$official_rel\" \"$built_rel\" 2>&1 | tee \"$diff_rel\" || true"

        # Count non-META-INF differences using Leo's precise regex
        # Filters ONLY root-level META-INF; nested META-INF differences still count
        local non_meta_diffs=0
        if [[ -s "$diff_file" ]]; then
            non_meta_diffs=$(grep -cvE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
                "$diff_file" 2>/dev/null || true)
            # Subtract blank lines
            local blank_lines
            blank_lines=$(grep -c '^$' "$diff_file" 2>/dev/null || echo 0)
            non_meta_diffs=$(( non_meta_diffs - blank_lines ))
            [[ "${non_meta_diffs}" -lt 0 ]] && non_meta_diffs=0
        fi

        local match="false"
        if [[ "$official_hash" == "$built_hash" ]]; then
            match="true"
            log_pass "$comparison_name: IDENTICAL"
        elif [[ "$non_meta_diffs" -eq 0 ]]; then
            match="true"
            log_pass "$comparison_name: Only META-INF differences (expected)"
            ((total_meta_only++))
        else
            log_warn "$comparison_name: $non_meta_diffs non-META-INF differences"
            ((total_diffs++))
        fi

        FILES_YAML+="      - filename: $comparison_name\n"
        FILES_YAML+="        hash: $built_hash\n"
        FILES_YAML+="        match: $match\n"
        if [[ "$match" == "true" ]]; then
            COMPARISON_TXT+="$comparison_name - $ARCH - $built_hash - 1\n"
        else
            COMPARISON_TXT+="$comparison_name - $ARCH - $built_hash - 0\n"
        fi
    done

    export TOTAL_DIFFS="$total_diffs"
    export TOTAL_META_ONLY="$total_meta_only"
}

###############################################################################
# Generate COMPARISON_RESULTS.yaml (minimal 3-field format per Luis 2026-03-12)
###############################################################################

generate_error_yaml() {
    local status="$1"
    local yaml_content
    yaml_content="script_version: ${SCRIPT_VERSION}
verdict: ${status}"
    if [[ -n "$WORK_DIR" ]]; then
        echo "$yaml_content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml"
        cp "${WORK_DIR}/COMPARISON_RESULTS.yaml" ./COMPARISON_RESULTS.yaml 2>/dev/null || true
    else
        echo "$yaml_content" > ./COMPARISON_RESULTS.yaml
    fi
}

generate_comparison_yaml() {
    local verdict="$1"
    local notes="$2"
    local yaml_content
    yaml_content="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    if [[ -n "$WORK_DIR" ]]; then
        echo "$yaml_content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml"
        cp "${WORK_DIR}/COMPARISON_RESULTS.yaml" ./COMPARISON_RESULTS.yaml
    else
        echo "$yaml_content" > ./COMPARISON_RESULTS.yaml
    fi
    log_info "Generated COMPARISON_RESULTS.yaml"
}

###############################################################################
# Version detection from APK content (split mode, --binary only)
# Uses WS_CONTAINER (walletscrutiny/android:5) — no build image needed yet.
# Zeus-pattern: aapt -> aapt2 -> apktool fallback. Never reads filename/path.
###############################################################################

_detect_version_from_apk() {
    local apk_path="$1"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_RUNTIME} run --rm \
        --volume "${apk_dir}:/apk:ro" \
        "${WS_CONTAINER}" \
        sh -c '
            out="$({ aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null \
                  || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
            if [ -n "$out" ]; then
                printf "%s\n" "$out" \
                    | sed -n "s/.*versionName='"'"'\([^'"'"']*\)'"'"'.*/\1/p" \
                    | head -n1
                exit 0
            fi
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
                sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" \
                    "$tmpdir/out/apktool.yml" | head -n1
            fi
            rm -rf "$tmpdir"
        '
}

###############################################################################
# Download official AAB from GitHub releases (aab mode, --version only)
# Queries the GitHub API to find the AAB asset for the given version tag,
# then downloads it into $WORK_DIR/official-aab/.
###############################################################################

download_official_aab() {
    local api_url="${GITHUB_API_BASE}/v${VERSION}"
    local download_dir="${WORK_DIR}/official-aab"
    mkdir -p "${download_dir}"

    log_info "Querying GitHub Releases API for v${VERSION}..."

    local aab_url
    aab_url="$(${CONTAINER_RUNTIME} run --rm \
        "${WS_CONTAINER}" \
        sh -c "curl -fsSL '${api_url}' 2>/dev/null | \
            python3 -c \"
import sys, json
data = json.load(sys.stdin)
assets = data.get('assets', [])
aabs = [a for a in assets if a['name'].endswith('.aab') and 'metamask-main-prod' in a['name']]
print(aabs[0]['browser_download_url'] if aabs else '')
\" 2>/dev/null || true")"

    if [[ -z "${aab_url}" ]]; then
        log_fail "No AAB asset found in GitHub release v${VERSION}."
        log_fail "Check: https://github.com/MetaMask/metamask-mobile/releases/tag/v${VERSION}"
        exit 1
    fi

    local aab_filename
    aab_filename="$(basename "${aab_url}")"
    log_info "Found AAB: ${aab_filename}"
    log_info "Downloading (${aab_url})..."

    if ! ${CONTAINER_RUNTIME} run --rm \
        --volume "${download_dir}:/download" \
        "${WS_CONTAINER}" \
        sh -c "wget -q -O '/download/${aab_filename}' '${aab_url}' \
               || curl -fsSL -o '/download/${aab_filename}' '${aab_url}'"; then
        log_fail "Download failed for: ${aab_url}"
        exit 1
    fi

    OFFICIAL_AAB="${download_dir}/${aab_filename}"
    if [[ ! -f "${OFFICIAL_AAB}" ]]; then
        log_fail "Downloaded AAB not found at: ${OFFICIAL_AAB}"
        exit 1
    fi
    log_info "Downloaded: ${OFFICIAL_AAB}"
}

###############################################################################
# Main Build Process
###############################################################################

prepare() {
    log_info "=== PREPARATION PHASE ==="

    mkdir -p "$WORK_DIR"/{official-split-apks,official-aab,built-split-apks,comparison,build-config,built-aab}
    chmod 777 "$WORK_DIR/built-aab"

    create_google_services_json "$WORK_DIR/build-config/google-services.json"
    create_device_spec "$WORK_DIR/device-spec.json" "$ARCH"

    if [[ "$BUILD_MODE" == "split" ]]; then
        # Copy Google Play split APKs provided via --binary
        if [[ "$APK_INPUT_KIND" == "dir" ]]; then
            log_info "Copying official Google Play split APKs from directory: $APK_DIR"
            shopt -s nullglob
            local apk_files=("$APK_DIR"/*.apk)
            shopt -u nullglob
            if [[ ${#apk_files[@]} -eq 0 ]]; then
                log_fail "No APK files found in: $APK_DIR"
                exit 2
            fi
            cp "${apk_files[@]}" "$WORK_DIR/official-split-apks/"

            OFFICIAL_BASE_APK=$(find_official_base_apk)
            if [[ -z "$OFFICIAL_BASE_APK" ]]; then
                log_fail "Could not find base APK in: $WORK_DIR/official-split-apks"
                exit 2
            fi
        else
            local original_name canonical_name
            original_name="$(basename "$APK_DIR")"
            canonical_name="$(canonicalize_split_apk_name "$original_name")"
            TARGET_SPLIT_APK="$canonical_name"

            log_info "Copying single official split APK: $APK_DIR"
            cp "$APK_DIR" "$WORK_DIR/official-split-apks/$canonical_name"
            if [[ "$original_name" != "$canonical_name" ]]; then
                log_info "Normalized split name: $original_name -> $canonical_name"
            fi

            OFFICIAL_BASE_APK="$WORK_DIR/official-split-apks/$canonical_name"
        fi

        # Auto-detect VERSION from the provided official APK content (never from filename)
        if [[ -z "$VERSION" ]]; then
            log_info "Auto-detecting version from official APK content..."
            VERSION="$(_detect_version_from_apk "$OFFICIAL_BASE_APK")"
            if [[ -z "$VERSION" ]]; then
                log_fail "Could not detect version from APK content. Pass --version explicitly."
                exit 2
            fi
            log_info "Version auto-detected: $VERSION"
        fi

    else
        # aab mode: download official AAB from GitHub releases
        # Splits will be extracted from it in extract_and_compare() after build image is ready
        download_official_aab
    fi

    log_pass "Preparation complete"
}

build() {
    log_info "=== BUILD PHASE ==="

    # Create Dockerfile
    create_dockerfile "$WORK_DIR/Dockerfile" "$VERSION"

    # Create build script
    create_build_script "$WORK_DIR/build.sh" "$VERSION" "$ARCH"

    # Build container image
    log_info "Building container image (no cache): $IMAGE_NAME"

    $CONTAINER_RUNTIME build \
        --no-cache \
        --build-arg VERSION="$VERSION" \
        --build-arg REPO_URL="$REPO_URL" \
        -t "$IMAGE_NAME" \
        -f "$WORK_DIR/Dockerfile" \
        "$WORK_DIR"

    # Run build in container
    log_info "Running build in container..."
    $CONTAINER_RUNTIME run --rm \
        -v "$WORK_DIR/build-config:/build-config:ro" \
        -v "$WORK_DIR/build.sh:/build.sh:ro" \
        -v "$WORK_DIR/built-aab:/output" \
        "$IMAGE_NAME" \
        bash -c "set -euo pipefail
            cd /home/builder/metamask-mobile
            /build.sh
            cp android/app/build/outputs/bundle/prodRelease/*.aab /output/ || \
            cp android/app/build/outputs/bundle/*/*.aab /output/ || \
            echo 'AAB not found in expected location'
            ls -la /output/
        "

    # Find the built AAB (inside container)
    local aab_rel
    aab_rel=$(container_exec "ls -1 built-aab/*.aab | tee /dev/stderr | head -1" || true)
    if [[ -z "$aab_rel" ]]; then
        log_fail "AAB file not found after build"
        exit 1
    fi

    log_pass "Build complete: $WORK_DIR/$aab_rel"
    export BUILT_AAB="$WORK_DIR/$aab_rel"
}

extract_and_compare() {
    log_info "=== EXTRACTION AND COMPARISON PHASE ==="

    if [[ -z "${BUILT_AAB:-}" || ! -f "$BUILT_AAB" ]]; then
        log_fail "No built AAB file found after build phase"
        exit 1
    fi

    # Extract splits from built AAB (same for both modes)
    log_info "Extracting splits from built AAB..."
    extract_split_apks_from_aab "$BUILT_AAB" "$WORK_DIR/built-split-apks" "$WORK_DIR/device-spec.json"

    if [[ "$BUILD_MODE" == "aab" ]]; then
        # Extract splits from official AAB (downloaded in prepare())
        # Build image is now available so bundletool can run inside it
        log_info "Extracting splits from official AAB..."
        extract_split_apks_from_aab "$OFFICIAL_AAB" "$WORK_DIR/official-split-apks" "$WORK_DIR/device-spec.json"

        OFFICIAL_BASE_APK=$(find_official_base_apk)
        if [[ -z "$OFFICIAL_BASE_APK" ]]; then
            log_fail "Could not find base APK in extracted official splits"
            exit 1
        fi
    fi

    compare_split_apks \
        "$WORK_DIR/official-split-apks" \
        "$WORK_DIR/built-split-apks" \
        "$WORK_DIR/comparison"
}

result() {
    log_info "=== RESULTS ==="

    local verdict_label="differences found"
    local yaml_verdict="not_reproducible"
    local exit_code=1

    if [[ "${TOTAL_DIFFS:-1}" -eq 0 ]]; then
        verdict_label="reproducible"
        yaml_verdict="reproducible"
        exit_code=0
        log_pass "VERDICT: REPRODUCIBLE"
        if [[ "${TOTAL_META_ONLY:-0}" -gt 0 ]]; then
            log_info "Note: ${TOTAL_META_ONLY} APKs had only META-INF differences (expected)"
        fi
    else
        log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} APKs with non-signing differences)"
    fi

    local yaml_scope="Compared full split set."
    if [[ "$BUILD_MODE" == "split" && "$APK_INPUT_KIND" == "file" && -n "$TARGET_SPLIT_APK" ]]; then
        yaml_scope="Compared single split: ${TARGET_SPLIT_APK}."
    fi
    local yaml_notes="Build environment: node:20-bookworm, JDK 17, Yarn 4.10.3, Android SDK 35, NDK 26.1.10909125. Architecture: ${ARCH}. Split APK comparison via bundletool. ${yaml_scope}"

    generate_comparison_yaml "${yaml_verdict}" "${yaml_notes}"

    print_results_block "${verdict_label}"

    log_info "Removing build image: ${IMAGE_NAME}"
    ${CONTAINER_RUNTIME} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
    log_info "Workspace preserved: ${WORK_DIR}"
    echo "Exit code: ${exit_code}"
    return ${exit_code}
}

###############################################################################
# Main Entry Point
###############################################################################

main() {
    log_info "Starting ${SCRIPT_NAME} script version ${SCRIPT_VERSION}"

    show_disclaimer

    # Detect container runtime
    detect_container_runtime

    # Parse arguments
    parse_arguments "$@"

    # Run build phases
    prepare
    build
    extract_and_compare
    result
}

# Run main function
main "$@"
