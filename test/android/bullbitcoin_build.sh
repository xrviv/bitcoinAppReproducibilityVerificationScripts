#!/bin/bash
# ==============================================================================
# bullbitcoin_build.sh - Bull Bitcoin Mobile Reproducible Build Verification
# ==============================================================================
# Version:       v0.4.8
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-31
# Project:       https://github.com/SatoshiPortal/bullbitcoin-mobile
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.bullbitcoin.mobile/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification
# purposes only. No warranty is provided regarding security, functionality, or
# fitness for any particular purpose. Users assume all risks associated with
# running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build
# verification. Users are responsible for ensuring compliance with all applicable
# laws and regulations. The developers assume no liability for any misuse or legal
# consequences arising from use. By using this script, you acknowledge these
# disclaimers and accept full responsibility.
#
# NOTE — Cargokit / Rust native libraries:
# Bull Bitcoin uses Rust native libraries (libbdk_flutter, libark_wallet, etc.)
# built via cargokit. The official release may use precompiled Rust binaries from
# GitHub Package Registry. This script forces a from-source Rust build by setting
# use_precompiled_binaries: false in cargokit_options.yaml. Differences in native
# .so files are expected if the official release used precompiled binaries.
#
# SCRIPT SUMMARY:
# Two operating modes, selected by arguments:
#
#   split mode (--binary <split.apk|zip>):
#     Accepts a single split APK or a zip archive (WalletScrutiny Android Blossom
#     upload — base.apk + device splits). Zip input is detected by file content
#     (magic bytes + inner APK presence), not file extension — the build server
#     may save a zip as _downloaded.apk depending on Nostr asset tags. Builds an
#     AAB from source in a container, extracts split APKs using bundletool +
#     device-spec.json, compares all splits, and runs a content diff. Generates
#     COMPARISON_RESULTS.yaml with verdict.
#
#   github mode (--version <ver>, no --binary):
#     Downloads the official APK from Bull Bitcoin GitHub releases. Builds a
#     direct release APK from source and compares APK-to-APK. Runs a content
#     diff. Generates
#     COMPARISON_RESULTS.yaml with verdict. (GitHub release APK only — not the
#     Play Store artifact.)

set -euo pipefail

# Capture execution directory before anything can change CWD
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"

# ------------------------------------------------------------------------------
# Script metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="v0.4.8"
readonly SCRIPT_NAME="bullbitcoin_build.sh"
readonly APP_ID="com.bullbitcoin.mobile"
readonly REPO_URL="https://github.com/SatoshiPortal/bullbitcoin-mobile.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly BULLBITCOIN_BUILD_IMAGE_BASE="bullbitcoin_build_env"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

# ------------------------------------------------------------------------------
# Global state (set by argument parsing)
# ------------------------------------------------------------------------------
VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""        # path given to --binary / --apk
INPUT_IS_ZIP=false  # true when --binary points to a zip (WalletScrutiny Blossom upload)
WORK_DIR=""
FLUTTER_VERSION=""      # detected from repo's .fvmrc; set in build() before ensure_build_image
DENSITY="480"          # screen density for bundletool device-spec.json (override with --density)
SDK_VER="33"           # SDK version for bundletool device-spec.json (override with --sdk-ver)
LOCALE="en"            # locale for bundletool device-spec.json (override with --locale)
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
should_cleanup=false

# set during prepare/build
BUILD_MODE=""        # "split" | "github"
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""      # canonical path in WORK_DIR to the official APK/split
OFFICIAL_BASE_APK="" # same as OFFICIAL_APK in split mode (used for metadata)
TARGET_SPLIT_NAME="" # canonical split filename being compared in split mode
BUILT_AAB=""
BUILT_APK=""
RESULT_DONE=false    # set true by result() after writing COMPARISON_RESULTS.yaml
TOTAL_DIFFS=1        # default to "failed" until compare_*() runs
TOTAL_META_ONLY=0

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_fail()  { echo "[FAIL] $*"; }
log_warn()  { echo "[WARNING] $*"; }

work_dir_path() {
    local version_part="$1"
    local arch_part="$2"
    printf '%s/%s_%s_%s_%s\n' \
        "${EXEC_DIR}" \
        "${WORK_DIR_PREFIX}" \
        "${APP_ID}" \
        "${version_part}" \
        "${arch_part}"
}

safe_grep_count() {
    local grep_output
    grep_output="$("$@" 2>/dev/null || true)"
    grep_output="${grep_output//$'\n'/}"
    [[ -n "${grep_output}" ]] && printf '%s\n' "${grep_output}" || printf '0\n'
}

build_image_tag() {
    local flutter_safe script_safe
    flutter_safe="${FLUTTER_VERSION//./_}"
    script_safe="${SCRIPT_VERSION#v}"
    script_safe="${script_safe//./_}"
    printf '%s:flutter_%s_script_%s\n' \
        "${BULLBITCOIN_BUILD_IMAGE_BASE}" \
        "${flutter_safe}" \
        "${script_safe}"
}

# ------------------------------------------------------------------------------
# YAML output helpers
# ------------------------------------------------------------------------------
write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
}

generate_error_yaml() {
    local status="$1"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}"
}

generate_comparison_yaml() {
    local verdict="$1"
    local notes="$2"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    log_info "Generated COMPARISON_RESULTS.yaml (verdict: ${verdict})"
}

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=$1
    set +e
    log_fail "Script failed at line ${line_no} (exit code ${exit_code})"
    if [[ "${RESULT_DONE}" != "true" ]]; then
        generate_error_yaml "ftbfs" || true
    fi
    echo "Exit code: ${EXIT_FAILED}"
    exit "${EXIT_FAILED}"
}

cleanup_on_error() {
    local exit_code=$?
    if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" && -n "${WORK_DIR:-}" ]]; then
        log_warn "Script failed with exit code: ${exit_code}"
        log_warn "Work directory preserved: ${WORK_DIR}"
        generate_error_yaml "ftbfs" || true
    fi
}

trap 'on_error $LINENO' ERR
trap 'cleanup_on_error'  EXIT

# ------------------------------------------------------------------------------
# Container runtime detection
# ------------------------------------------------------------------------------
detect_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        VOLUME_RO=":ro,Z"
        VOLUME_RW=":Z"
        CONTAINER_RUN_EXTRA="--userns=keep-id"
        log_info "Using podman as container runtime"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        VOLUME_RO=":ro"
        VOLUME_RW=""
        CONTAINER_RUN_EXTRA="--user $(id -u):$(id -g)"
        log_info "Using docker as container runtime"
    else
        cat > "${EXEC_DIR}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  Neither podman nor docker found on host. Install one to continue.
EOF
        echo "[ERROR] Neither podman nor docker is available."
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi
}

# ------------------------------------------------------------------------------
# Container helpers
# ------------------------------------------------------------------------------

# Run a command inside WORK_DIR mounted at /work
# FLUTTER_VERSION must be set before this is called.
container_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "$(build_image_tag)" \
        bash -c "$cmd"
}

container_sha256() {
    local file_path="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "$(dirname "$file_path"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "sha256sum /data/$(basename "$file_path") | awk '{print \$1}'"
}

container_signer() {
    local apk_path="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "$(dirname "$apk_path"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "apksigner verify --print-certs /apk/$(basename "$apk_path") 2>/dev/null \
               | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${apk_dir}:/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c '
            out="$({ aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null \
                  || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
            if [ -n "$out" ]; then
                printf "%s\n" "$out" \
                    | sed -n "s/.*'"${field}"'='"'"'\([^'"'"']*\)'"'"'.*/\1/p" \
                    | head -n1
                exit 0
            fi
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
                case "'"${field}"'" in
                    versionName)
                        sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" \
                            "$tmpdir/out/apktool.yml" | head -n1 ;;
                    versionCode)
                        sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" \
                            "$tmpdir/out/apktool.yml" | head -n1 ;;
                esac
            fi
            rm -rf "$tmpdir"
        ' 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Split APK name helpers (MetaMask / tangem pattern)
# ------------------------------------------------------------------------------
canonicalize_split_apk_name() {
    local apk_name="$1"
    case "$apk_name" in
        base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
        split_config.*.apk) echo "$apk_name" ;;
        base-*.apk) echo "split_config.${apk_name#base-}" ;;
        *) echo "$apk_name" ;;
    esac
}

find_official_base_apk() {
    local dir="${WORK_DIR}/official-split-apks"
    if   [[ -f "${dir}/base.apk" ]];        then echo "${dir}/base.apk"; return; fi
    if   [[ -f "${dir}/base-master.apk" ]]; then echo "${dir}/base-master.apk"; return; fi
    local matches=("${dir}"/base*.apk)
    [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]] && echo "${matches[0]}" && return
}

resolve_built_split_apk() {
    local official_apk="$1"
    local built_dir="$2"
    local official_name canonical_name
    official_name="$(basename "$official_apk")"
    [[ -f "${built_dir}/${official_name}" ]] && echo "${built_dir}/${official_name}" && return 0
    canonical_name="$(canonicalize_split_apk_name "$official_name")"
    [[ -f "${built_dir}/${canonical_name}" ]] && echo "${built_dir}/${canonical_name}" && return 0
    return 1
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
NAME
       ${SCRIPT_NAME} - Bull Bitcoin Mobile Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --binary <split.apk|zip> [--version <version>] [OPTIONS]
       ${SCRIPT_NAME} --version <version> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Builds Bull Bitcoin Mobile from source in a container and compares against
       an official artifact. Two modes are supported:

       split mode (--binary <file>):
         Accepts one official split APK from Google Play, or a zip archive
         (WalletScrutiny Android Blossom upload — base.apk + device splits).
         Zip input is detected by file content, not extension. Builds an AAB via
         'flutter build appbundle --release', extracts splits with bundletool,
         and compares the matching split(s).

       github mode (--version <ver>, no --binary):
         Downloads the official APK from Bull Bitcoin GitHub releases.
         Builds a direct release APK from source with
         'flutter build apk --release' and runs an APK-to-APK content diff.

OPTIONS
       --binary <file>            Path to one official Play Store split APK or
                                  a WalletScrutiny zip archive. Alias: --apk.
       --version <version>        Version to verify (e.g. 6.5.2). Required in
                                  github mode; optional in split mode (auto-detect).
       --arch <arch>              Target architecture for device-spec.json.
                                  Supported: arm64-v8a, armeabi-v7a, x86_64, x86.
                                  Default: arm64-v8a.
       --density <dpi>            Screen density for bundletool device-spec.json.
                                  Default: 480. Common values: 320, 480, 560, 640.
       --sdk-ver <N>              SDK version for bundletool device-spec.json.
                                  Default: 33.
       --locale <tag>             Locale for bundletool device-spec.json.
                                  Default: en. Example: fr, zh-Hans, pt-BR.
       --type <type>              Accepted for build server compatibility; unused.
       --cleanup                  Remove temporary files after completion.
       --script-version           Print script version and exit.
       --help                     Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF differences, or identical)
       1    Differences found or build failure
       2    Invalid parameters

EXAMPLES
       # Split mode — from WalletScrutiny Blossom zip upload:
       ${SCRIPT_NAME} --binary ~/apks/cash.bull.android_6.5.2.zip --version 6.5.2

       # Split mode — single split APK:
       ${SCRIPT_NAME} --binary ~/apks/base.apk --version 6.5.2

       # GitHub mode:
       ${SCRIPT_NAME} --version 6.5.2
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)        VERSION="${2:-}";       shift ;;
            --apk|--binary)   APK_INPUT="${2:-}";     shift ;;
            --arch)           ARCH="${2:-}";          shift ;;
            --type)           TYPE="${2:-}";          shift ;;
            --density)        DENSITY="${2:-}";       shift ;;
            --sdk-ver)        SDK_VER="${2:-}";       shift ;;
            --locale)         LOCALE="${2:-}";        shift ;;
            --cleanup)        should_cleanup=true ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)        usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            *)                log_warn "Ignoring unknown argument: $1" ;;
        esac
        shift
    done

    # Determine mode
    if [[ -n "${APK_INPUT}" ]]; then
        BUILD_MODE="split"
        # Resolve relative path before existence check
        [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
        if [[ -f "${APK_INPUT}" ]]; then
            # Detect zip by content, not extension — the build server may save
            # a zip as _downloaded.apk when the Nostr asset has no file-name tag.
            if file "${APK_INPUT}" | grep -q "Zip archive" && \
               unzip -l "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
                INPUT_IS_ZIP=true
                log_info "--binary is a zip archive containing APKs; will extract before comparison."
            fi
        else
            echo "[ERROR] --binary file not found: ${APK_INPUT}"
            generate_error_yaml "ftbfs"
            echo "Exit code: ${EXIT_INVALID}"
            exit "${EXIT_INVALID}"
        fi
        ARCH="${ARCH:-arm64-v8a}"
    elif [[ -n "${VERSION}" ]]; then
        BUILD_MODE="github"
        ARCH="${ARCH:-arm64-v8a}"
    else
        echo "[ERROR] Provide --binary <split.apk|zip> (split mode) or --version <version> (github mode)."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Validate arch
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            echo "[ERROR] Unsupported architecture: ${ARCH}"
            echo "        Supported: arm64-v8a, armeabi-v7a, x86_64, x86"
            echo "Exit code: ${EXIT_INVALID}"
            exit "${EXIT_INVALID}"
            ;;
    esac

    # Validate density (must be a positive integer)
    if ! [[ "${DENSITY}" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] --density must be a positive integer (got: ${DENSITY})"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Validate sdk-ver (must be a positive integer)
    if ! [[ "${SDK_VER}" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] --sdk-ver must be a positive integer (got: ${SDK_VER})"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Validate locale (non-empty, letters/digits/hyphens only)
    if ! [[ "${LOCALE}" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "[ERROR] --locale must be a valid locale tag (got: ${LOCALE})"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
    log_info "Build mode: ${BUILD_MODE}"
    log_info "Work directory: ${WORK_DIR}"
}

# ------------------------------------------------------------------------------
# Detect Flutter version from the repo's .fvmrc at the requested git tag.
# Uses a sparse, blobless clone so only the tree metadata is transferred;
# git-show then fetches just the one file. Exits ftbfs on error because a
# non-pinned Flutter fallback would not be reproducible. Sets FLUTTER_VERSION.
# ------------------------------------------------------------------------------
detect_flutter_version() {
    local git_ref="v${VERSION}"
    log_info "Detecting Flutter version from ${REPO_URL} at ${git_ref}..."
    local fvmrc
    fvmrc="$(${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        "${WS_CONTAINER}" \
        sh -c "git clone --depth 1 --filter=blob:none --no-checkout \
                   --branch '${git_ref}' '${REPO_URL}' /tmp/bb_fvmrc 2>/dev/null && \
               git -C /tmp/bb_fvmrc show HEAD:.fvmrc 2>/dev/null || true" 2>/dev/null || true)"
    # .fvmrc is a single line like "3.29.3" or a JSON {"flutter": "3.29.3"}
    local detected
    detected="$(echo "${fvmrc}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -z "${detected}" ]]; then
        log_fail "Could not read Flutter version from .fvmrc at ${git_ref}."
        log_fail "Either the tag does not exist, the repo has no .fvmrc, or the network is unreachable."
        log_fail "Cannot build reproducibly without a pinned Flutter version."
        generate_error_yaml "ftbfs"
        RESULT_DONE=true
        exit "${EXIT_FAILED}"
    fi
    FLUTTER_VERSION="${detected}"
    log_info "Flutter version pinned to: ${FLUTTER_VERSION}"
}

# ------------------------------------------------------------------------------
# Build environment image
# Inline Dockerfile: Ubuntu 24.04, OpenJDK 21, Android SDK 35, NDK 27.0.12077973,
# Flutter pinned via FLUTTER_VERSION, Rust with Android cross-compilation targets.
# Image tag includes the Flutter version and script version so Dockerfile fixes
# take effect on the next run instead of silently reusing stale images.
# ------------------------------------------------------------------------------
ensure_build_image() {
    local image_tag
    image_tag="$(build_image_tag)"
    if ${CONTAINER_CMD} image inspect "${image_tag}" >/dev/null 2>&1; then
        log_info "Reusing existing build environment image: ${image_tag}"
        return
    fi

    log_info "Building Bull Bitcoin build environment image (first-time, ~30 min)..."
    local dockerfile_dir="${WORK_DIR}/build_env"
    mkdir -p "${dockerfile_dir}"

    cat > "${dockerfile_dir}/Dockerfile" <<'DOCKERFILE_EOF'
FROM docker.io/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    FLUTTER_HOME=/opt/flutter \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.0.12077973 \
    NDK_HOME=/opt/android-sdk/ndk/27.0.12077973

ENV PATH="/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-21-openjdk-amd64/bin:/root/.cargo/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk wget unzip git curl ca-certificates make \
        clang cmake ninja-build pkg-config libgtk-3-dev \
        xz-utils zip libglu1-mesa && \
    rm -rf /var/lib/apt/lists/*

# Install Android SDK command-line tools
RUN mkdir -p /opt/android-sdk/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
         -O /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d /opt/android-sdk/cmdline-tools && \
    mv /opt/android-sdk/cmdline-tools/cmdline-tools \
       /opt/android-sdk/cmdline-tools/latest && \
    rm /tmp/sdk.zip

# Accept licenses and install SDK components including NDK
RUN yes | sdkmanager --licenses >/dev/null 2>&1 && \
    sdkmanager \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
        "ndk;27.0.12077973" && \
    chmod -R 777 /opt/android-sdk

# Install Rust (as root, system-wide)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path && \
    /root/.cargo/bin/rustup target add \
        aarch64-linux-android \
        armv7-linux-androideabi \
        x86_64-linux-android \
        i686-linux-android

# Install Flutter SDK (pinned via build arg) and chmod in the same layer so the
# cache hit is always consistent — if Flutter installed, it is also chmod'd here.
ARG FLUTTER_VERSION=stable
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter && \
    /opt/flutter/bin/flutter --version && \
    /opt/flutter/bin/flutter config --android-sdk=/opt/android-sdk && \
    yes | /opt/flutter/bin/flutter doctor --android-licenses >/dev/null 2>&1 || true && \
    chmod -R 777 /opt/flutter

# Allow non-root container users (Docker --user uid:gid) to traverse and write to tool caches.
# /root itself must be traversable (755) before subdirectory permissions matter.
RUN chmod 755 /root && \
    chmod -R 777 /root/.cargo /root/.rustup && \
    mkdir -p /root/.gradle && chmod 777 /root/.gradle && \
    mkdir -p /root/.pub-cache && chmod -R 777 /root/.pub-cache

RUN git config --system --add safe.directory /opt/flutter

# Pre-warm Flutter Android cache as root, then remove the gradle_wrapper artifact
# dir. flutter precache creates gradle_wrapper/ owned by root; chmod 777 opens
# permissions but non-root users still can't utime those root-owned dirs when
# flutter re-extracts at runtime. Deleting it here lets the non-root user create
# it fresh (and own it) so utime/chmod succeed.
RUN /opt/flutter/bin/flutter precache --android 2>/dev/null || true && \
    rm -rf /opt/flutter/bin/cache/artifacts/gradle_wrapper && \
    chmod -R 777 /opt/flutter/bin/cache

RUN mkdir -p /workspace && chmod 777 /workspace
WORKDIR /workspace
DOCKERFILE_EOF

    ${CONTAINER_CMD} build \
        --no-cache \
        --build-arg "FLUTTER_VERSION=${FLUTTER_VERSION}" \
        --tag "${image_tag}" \
        "${dockerfile_dir}"
    log_info "Build environment image ready: ${image_tag}"
}

# ------------------------------------------------------------------------------
# device-spec.json for bundletool
# ------------------------------------------------------------------------------
create_device_spec() {
    local spec_path="$1"
    local arch="$2"
    cat > "${spec_path}" <<DEVICESPEC_EOF
{
  "supportedAbis": ["${arch}"],
  "supportedLocales": ["${LOCALE}"],
  "screenDensity": ${DENSITY},
  "sdkVersion": ${SDK_VER}
}
DEVICESPEC_EOF
    log_info "Created device-spec.json: arch=${arch} density=${DENSITY} sdkVersion=${SDK_VER} locale=${LOCALE}"
}

# ------------------------------------------------------------------------------
# bundletool split extraction
# Runs inside the build image (which has Java). Downloads bundletool if absent.
# ------------------------------------------------------------------------------
extract_split_apks_from_aab() {
    local aab_path="$1"
    local output_dir="$2"
    local device_spec="$3"

    log_info "Extracting splits from $(basename "${aab_path}") with bundletool..."

    local aab_rel output_rel spec_rel
    aab_rel="${aab_path#"${WORK_DIR}/"}"
    output_rel="${output_dir#"${WORK_DIR}/"}"
    spec_rel="${device_spec#"${WORK_DIR}/"}"

    container_exec "set -euo pipefail
        if [[ ! -f bundletool.jar ]]; then
            curl -fsSL https://github.com/google/bundletool/releases/download/1.15.6/bundletool-all-1.15.6.jar \
                -o bundletool.jar
        fi
        rm -f built.apks
        rm -rf \"${output_rel}\"
        java -jar bundletool.jar build-apks \
            --bundle=\"${aab_rel}\" \
            --output=\"built.apks\" \
            --device-spec=\"${spec_rel}\" \
            --mode=default \
            --overwrite
        mkdir -p \"${output_rel}\"
        unzip -o built.apks -d \"${output_rel}\"
        if [[ -d \"${output_rel}/splits\" ]]; then
            mv \"${output_rel}/splits\"/*.apk \"${output_rel}/\" 2>/dev/null || true
            rmdir \"${output_rel}/splits\" 2>/dev/null || true
        fi
        if [[ -f \"${output_rel}/base-master.apk\" ]]; then
            mv \"${output_rel}/base-master.apk\" \"${output_rel}/base.apk\"
        fi
        if [[ -f \"${output_rel}/standalones/standalone.apk\" ]]; then
            mv \"${output_rel}/standalones/standalone.apk\" \"${output_rel}/base.apk\"
            rmdir \"${output_rel}/standalones\" 2>/dev/null || true
        fi
        for split_apk in \"${output_rel}\"/base-*.apk; do
            split_name=\$(basename \"\$split_apk\")
            [[ \"\$split_name\" == 'base-master.apk' ]] && continue
            suffix=\${split_name#base-}
            mv \"\$split_apk\" \"${output_rel}/split_config.\${suffix}\"
        done
    "

    log_pass "Splits extracted to: ${output_dir}"
    container_exec "ls -la \"${output_rel}\"/*.apk || ls -la \"${output_rel}\""
}

# ------------------------------------------------------------------------------
# Unzip an APK into a directory, inside the build container
# ------------------------------------------------------------------------------
unzip_apk_in_container() {
    local apk_path="$1"
    local dest_dir="$2"
    local apk_dir apk_file dest_parent dest_base
    apk_dir="$(dirname "$apk_path")"
    apk_file="$(basename "$apk_path")"
    dest_parent="$(dirname "$dest_dir")"
    dest_base="$(basename "$dest_dir")"

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${apk_dir}:/apk${VOLUME_RO}" \
        -v "${dest_parent}:/out${VOLUME_RW}" \
        "$(build_image_tag)" \
        bash -c "set -euo pipefail
            rm -rf \"/out/${dest_base}\"
            mkdir -p \"/out/${dest_base}\"
            unzip -qq -o \"/apk/${apk_file}\" -d \"/out/${dest_base}\"
        "
}

# ------------------------------------------------------------------------------
# Split-by-split comparison (MetaMask / tangem pattern)
# Sets TOTAL_DIFFS and TOTAL_META_ONLY.
# ------------------------------------------------------------------------------
compare_split_apks() {
    local official_dir="$1"
    local built_dir="$2"
    local results_dir="$3"

    log_info "Comparing split APKs..."
    mkdir -p "${results_dir}"

    TOTAL_DIFFS=0
    TOTAL_META_ONLY=0

    for official_apk in "${official_dir}"/*.apk; do
        [[ ! -f "${official_apk}" ]] && continue

        local apk_name built_apk comparison_name
        apk_name="$(basename "${official_apk}")"
        built_apk="$(resolve_built_split_apk "${official_apk}" "${built_dir}" || true)"

        if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
            log_warn "No matching built split for official: ${apk_name}"
            (( TOTAL_DIFFS++ )) || true
            continue
        fi

        comparison_name="$(basename "${built_apk}")"
        local official_hash built_hash
        official_hash="$(container_sha256 "${official_apk}")"
        built_hash="$(container_sha256 "${built_apk}")"
        log_info "  Official ${apk_name}: ${official_hash}"
        log_info "  Built    ${comparison_name}: ${built_hash}"

        local official_unzip="${results_dir}/official_${comparison_name%.apk}"
        local built_unzip="${results_dir}/built_${comparison_name%.apk}"
        unzip_apk_in_container "${official_apk}"  "${official_unzip}"
        unzip_apk_in_container "${built_apk}"     "${built_unzip}"

        local diff_file="${results_dir}/diff_${comparison_name%.apk}.txt"
        local official_rel built_rel diff_rel
        official_rel="${official_unzip#"${WORK_DIR}/"}"
        built_rel="${built_unzip#"${WORK_DIR}/"}"
        diff_rel="${diff_file#"${WORK_DIR}/"}"
        container_exec "diff -r \"${official_rel}\" \"${built_rel}\" 2>&1 \
            > \"${diff_rel}\" 2>&1 || true"

        local non_meta_diffs=0
        if [[ -s "${diff_file}" ]]; then
            non_meta_diffs="$(safe_grep_count grep -cvE \
                '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
                "${diff_file}")"
            local blank_lines
            blank_lines="$(safe_grep_count grep -c '^$' "${diff_file}")"
            non_meta_diffs=$(( non_meta_diffs - blank_lines ))
            [[ "${non_meta_diffs}" -lt 0 ]] && non_meta_diffs=0
        fi

        if [[ "${official_hash}" == "${built_hash}" ]]; then
            log_pass "${comparison_name}: IDENTICAL"
        elif [[ "${non_meta_diffs}" -eq 0 ]]; then
            log_pass "${comparison_name}: Only META-INF differences (expected)"
            (( TOTAL_META_ONLY++ )) || true
        else
            log_warn "${comparison_name}: ${non_meta_diffs} non-META-INF differences"
            (( TOTAL_DIFFS++ )) || true
        fi
    done
}

# ------------------------------------------------------------------------------
# Simple unzip diff (github mode: direct APK vs APK)
# Sets TOTAL_DIFFS.
# ------------------------------------------------------------------------------
compare_universal_apks() {
    local official_apk="$1"
    local built_apk="$2"
    local results_dir="$3"

    log_info "Comparing APKs..."
    mkdir -p "${results_dir}"

    local official_unzip="${results_dir}/official_unzipped"
    local built_unzip="${results_dir}/built_unzipped"

    unzip_apk_in_container "${official_apk}" "${official_unzip}"
    unzip_apk_in_container "${built_apk}"    "${built_unzip}"

    local diff_file="${results_dir}/diff_full.txt"
    local official_rel built_rel diff_rel
    official_rel="${official_unzip#"${WORK_DIR}/"}"
    built_rel="${built_unzip#"${WORK_DIR}/"}"
    diff_rel="${diff_file#"${WORK_DIR}/"}"
    container_exec "diff -r \"${official_rel}\" \"${built_rel}\" \
        > \"${diff_rel}\" 2>&1 || true"

    TOTAL_DIFFS=0
    if [[ -s "${diff_file}" ]]; then
        local non_meta_diffs
        non_meta_diffs="$(safe_grep_count grep -cvE \
            '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
            "${diff_file}")"
        local blank_lines
        blank_lines="$(safe_grep_count grep -c '^$' "${diff_file}")"
        non_meta_diffs=$(( non_meta_diffs - blank_lines ))
        [[ "${non_meta_diffs}" -lt 0 ]] && non_meta_diffs=0
        TOTAL_DIFFS="${non_meta_diffs}"

        local total_lines
        total_lines="$(wc -l < "${diff_file}" || echo 0)"
        log_info "Diff: ${TOTAL_DIFFS} non-META-INF differences (${total_lines} total lines)"
        log_info "Full diff: ${diff_file}"
        echo "Diff preview (first 5 lines):"
        head -5 "${diff_file}"
        [[ "${total_lines}" -gt 5 ]] && echo "... (${total_lines} lines — see $(basename "${diff_file}"))"
    else
        log_pass "No differences in unzipped content."
    fi
}

# ------------------------------------------------------------------------------
# Print results block (terminal output)
# ------------------------------------------------------------------------------
print_results_block() {
    local verdict="$1"
    local version_name version_code signer official_hash commit_hash

    version_name="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
    version_code="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_BASE_APK}" || true)"
    official_hash="$(container_sha256 "${OFFICIAL_BASE_APK}")"
    commit_hash="$(cat "${WORK_DIR}/built-aab/commit.txt" 2>/dev/null || echo "unknown")"

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         ${signer:-unknown}"
    echo "apkVersionName: ${version_name:-${VERSION}}"
    echo "apkVersionCode: ${version_code:-unknown}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${official_hash}"
    echo "commit:         ${commit_hash}"
    echo ""

    echo "Diff:"
    if [[ "${BUILD_MODE}" == "split" ]]; then
        for diff_file in "${WORK_DIR}/comparison"/diff_*.txt; do
            [[ -f "${diff_file}" ]] || continue
            local split_label lines
            split_label="$(basename "${diff_file}" .txt)"
            split_label="${split_label#diff_}"
            echo "=== ${split_label} ==="
            if [[ -s "${diff_file}" ]]; then
                head -5 "${diff_file}"
                lines="$(wc -l < "${diff_file}")"
                [[ "${lines}" -gt 5 ]] && \
                    echo "... (${lines} lines total — full diff: ${diff_file})"
            else
                echo "(no differences)"
            fi
            echo ""
        done
    else
        local diff_file="${WORK_DIR}/comparison/diff_full.txt"
        if [[ -s "${diff_file}" ]]; then
            head -5 "${diff_file}"
            local lines
            lines="$(wc -l < "${diff_file}")"
            [[ "${lines}" -gt 5 ]] && \
                echo "... (${lines} lines total — full diff: ${diff_file})"
        else
            echo "(no differences)"
        fi
        echo ""
    fi

    echo "===== End Results ====="
}

# ------------------------------------------------------------------------------
# Phase 1: Prepare
# ------------------------------------------------------------------------------
prepare() {
    log_info "=== PREPARATION PHASE ==="

    if [[ -d "${WORK_DIR}" ]]; then
        log_info "Removing existing work directory: ${WORK_DIR}"
        rm -rf "${WORK_DIR}"
    fi
    mkdir -p "${WORK_DIR}"/{official-split-apks,built-split-apks,built-aab,comparison}
    chmod 777 "${WORK_DIR}/built-aab"

    if [[ "${BUILD_MODE}" == "split" ]]; then
        if [[ "${INPUT_IS_ZIP}" == "true" ]]; then
            log_info "Extracting zip: $(basename "${APK_INPUT}")"
            local zip_extract_dir="${WORK_DIR}/zip-extracted"
            mkdir -p "${zip_extract_dir}"
            unzip -qq "${APK_INPUT}" -d "${zip_extract_dir}" 2>/dev/null || true
            chmod -R a+rwX "${zip_extract_dir}" 2>/dev/null || true
            local apk_count
            apk_count="$(find "${zip_extract_dir}" -name "*.apk" 2>/dev/null | wc -l)"
            if [[ "${apk_count}" -eq 0 ]]; then
                log_fail "No APK files found inside zip: ${APK_INPUT}"
                generate_error_yaml "ftbfs"
                RESULT_DONE=true
                exit "${EXIT_FAILED}"
            fi
            log_info "Zip extracted. ${apk_count} APK(s) found:"
            find "${zip_extract_dir}" -name "*.apk" | sort | while IFS= read -r f; do
                echo "  $(basename "${f}")"
            done
            while IFS= read -r apk; do
                local apk_name apk_canonical
                apk_name="$(basename "${apk}")"
                apk_canonical="$(canonicalize_split_apk_name "${apk_name}")"
                cp "${apk}" "${WORK_DIR}/official-split-apks/${apk_canonical}"
                [[ "${apk_name}" != "${apk_canonical}" ]] && \
                    log_info "Normalized: ${apk_name} -> ${apk_canonical}"
            done < <(find "${zip_extract_dir}" -name "*.apk" | sort)
            TARGET_SPLIT_NAME="zip ($(find "${WORK_DIR}/official-split-apks" -name "*.apk" | wc -l) splits)"
            local found_base
            found_base="$(find_official_base_apk)"
            if [[ -z "${found_base}" ]]; then
                log_fail "No base APK found in extracted zip (expected base.apk or base-master.apk)."
                generate_error_yaml "ftbfs"
                RESULT_DONE=true
                exit "${EXIT_FAILED}"
            fi
            OFFICIAL_APK="${found_base}"
            OFFICIAL_BASE_APK="${found_base}"
        else
            # Single split APK — normalize and copy
            local original_name canonical_name
            original_name="$(basename "${APK_INPUT}")"
            canonical_name="$(canonicalize_split_apk_name "${original_name}")"
            TARGET_SPLIT_NAME="${canonical_name}"

            cp "${APK_INPUT}" "${WORK_DIR}/official-split-apks/${canonical_name}"
            [[ "${original_name}" != "${canonical_name}" ]] && \
                log_info "Normalized split name: ${original_name} -> ${canonical_name}"

            OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
            OFFICIAL_BASE_APK="${OFFICIAL_APK}"
        fi

        # Auto-detect version from APK content if not provided
        if [[ -z "${VERSION}" ]]; then
            log_info "Auto-detecting version from APK content..."
            VERSION="$(container_aapt_version "${OFFICIAL_APK}" "versionName" || true)"
            if [[ -z "${VERSION}" ]]; then
                log_fail "Could not detect version from APK. Pass --version explicitly."
                exit "${EXIT_INVALID}"
            fi
            log_info "Version detected: ${VERSION}"
            VERSION_SAFE="${VERSION}"
        fi

        create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"

    else
        # github mode: download APK from GitHub releases
        log_info "Downloading official APK from GitHub releases (v${VERSION})..."
        if ! command -v curl >/dev/null 2>&1; then
            log_fail "Host curl is required for GitHub release downloads."
            exit "${EXIT_FAILED}"
        fi
        local api_url="https://api.github.com/repos/SatoshiPortal/bullbitcoin-mobile/releases/tags/v${VERSION}"

        local release_json
        release_json="$(curl -fsSL --max-time 30 "${api_url}")"

        if echo "${release_json}" | grep -q '"message".*"Not Found"'; then
            log_fail "GitHub release v${VERSION} not found."
            exit "${EXIT_FAILED}"
        fi

        local apk_url
        apk_url="$(echo "${release_json}" \
            | grep -o '"browser_download_url":[[:space:]]*"[^"]*\.apk"' \
            | grep -o 'https://[^"]*' | head -1)"

        if [[ -z "${apk_url}" ]]; then
            log_fail "No APK asset found in release v${VERSION}."
            log_fail "Available assets:"
            echo "${release_json}" | grep -o '"name":[[:space:]]*"[^"]*"' | head -10
            exit "${EXIT_FAILED}"
        fi

        local apk_filename
        apk_filename="$(basename "${apk_url}")"
        log_info "Downloading: ${apk_url}"
        mkdir -p "${WORK_DIR}/official-split-apks"
        curl -fsSL --progress-bar -o "${WORK_DIR}/official-split-apks/${apk_filename}" "${apk_url}"

        OFFICIAL_APK="${WORK_DIR}/official-split-apks/${apk_filename}"
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"
        [[ -f "${OFFICIAL_APK}" ]] || { log_fail "Download failed."; exit "${EXIT_FAILED}"; }
        log_info "Downloaded: ${apk_filename}"
    fi

    log_pass "Preparation complete."
}

# ------------------------------------------------------------------------------
# Phase 2: Build
# ------------------------------------------------------------------------------
build() {
    log_info "=== BUILD PHASE ==="

    detect_flutter_version
    ensure_build_image

    local git_ref="v${VERSION}"
    log_info "Cloning ${REPO_URL} at ${git_ref}..."

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab:/workspace${VOLUME_RW}" \
        -w /workspace \
        "$(build_image_tag)" \
        sh -c "git clone --depth 1 --branch '${git_ref}' '${REPO_URL}' app"

    local commit_hash
    commit_hash="$(${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RO}" \
        -w /workspace \
        "$(build_image_tag)" \
        sh -c "git rev-parse HEAD")"
    log_info "Checked out ${git_ref} at ${commit_hash}"
    echo "${commit_hash}" > "${WORK_DIR}/built-aab/commit.txt"

    local build_cmd build_label
    if [[ "${BUILD_MODE}" == "split" ]]; then
        build_cmd="flutter build appbundle --release"
        build_label="flutter build appbundle --release"
    else
        build_cmd="flutter build apk --release"
        build_label="flutter build apk --release"
    fi

    log_info "Running Flutter build (${build_label})..."
    log_info "This may take 30-60 minutes on first dependency download."

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RW}" \
        -w /workspace \
        -e "ANDROID_SDK_ROOT=/opt/android-sdk" \
        -e "ANDROID_HOME=/opt/android-sdk" \
        -e "ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.0.12077973" \
        -e "NDK_HOME=/opt/android-sdk/ndk/27.0.12077973" \
        -e "HOME=/tmp/ws-home" \
        -e "XDG_CONFIG_HOME=/tmp/ws-home/.config" \
        -e "XDG_CACHE_HOME=/tmp/ws-home/.cache" \
        -e "GRADLE_USER_HOME=/tmp/ws-home/.gradle" \
        -e "PUB_CACHE=/tmp/ws-home/.pub-cache" \
        -e "CARGO_HOME=/root/.cargo" \
        -e "RUSTUP_HOME=/root/.rustup" \
        -e "CI=true" \
        -e "GIT_CONFIG_COUNT=1" \
        -e "GIT_CONFIG_KEY_0=safe.directory" \
        -e "GIT_CONFIG_VALUE_0=/opt/flutter" \
        "$(build_image_tag)" \
        bash -c "set -euo pipefail
            mkdir -p /tmp/ws-home/.config /tmp/ws-home/.cache /tmp/ws-home/.gradle /tmp/ws-home/.pub-cache

            # Disable cargokit precompiled binaries — force from-source Rust build
            if [[ -f cargokit_options.yaml ]]; then
                sed -i 's/use_precompiled_binaries: true/use_precompiled_binaries: false/' cargokit_options.yaml
                echo '[INFO] cargokit: use_precompiled_binaries set to false'
            fi

            # Create .env from template
            if [[ -f .env.template && ! -f .env ]]; then
                cp .env.template .env
                echo '[INFO] Created .env from template'
            fi

            # Generate a fake keystore for release signing
            keytool -genkey -v -keystore /tmp/upload-keystore.jks \
                -keyalg RSA -keysize 2048 -validity 10000 \
                -alias upload -storepass android -keypass android \
                -dname 'CN=WalletScrutiny,O=WalletScrutiny,C=US' 2>/dev/null || true

            # Create key.properties
            if [[ -d android ]]; then
                printf 'storePassword=android\nkeyPassword=android\nkeyAlias=upload\nstoreFile=/tmp/upload-keystore.jks\n' \
                    > android/key.properties
                echo '[INFO] Created android/key.properties'
            fi

            # Configure Flutter android SDK path
            flutter config --android-sdk=/opt/android-sdk 2>/dev/null || true

            # Get dependencies
            flutter pub get

            # Code generation (non-fatal)
            dart run build_runner build --delete-conflicting-outputs 2>&1 || \
                echo '[WARNING] build_runner skipped or not needed'

            # Generate localizations (non-fatal)
            flutter gen-l10n 2>&1 || \
                echo '[WARNING] flutter gen-l10n skipped or not needed'

            # Build the artifact matching the selected verification mode
            ${build_cmd}
        "

    if [[ "${BUILD_MODE}" == "split" ]]; then
        local aab_path
        aab_path="$(find "${WORK_DIR}/built-aab/app" -type f -name "*.aab" \
            -path "*/outputs/bundle/*" \
            ! -path "*/intermediates/*" \
            2>/dev/null | head -1 || true)"

        if [[ -z "${aab_path}" || ! -f "${aab_path}" ]]; then
            log_fail "Built AAB not found after flutter build appbundle."
            exit "${EXIT_FAILED}"
        fi
        log_info "Built AAB: ${aab_path}"
        BUILT_AAB="${aab_path}"
    else
        local apk_path
        apk_path="$(find "${WORK_DIR}/built-aab/app" -type f -name "app-release.apk" \
            -path "*/outputs/flutter-apk/*" \
            ! -path "*/intermediates/*" \
            2>/dev/null | head -1 || true)"

        if [[ -z "${apk_path}" || ! -f "${apk_path}" ]]; then
            log_fail "Built APK not found after flutter build apk --release."
            exit "${EXIT_FAILED}"
        fi
        log_info "Built APK: ${apk_path}"
        BUILT_APK="${apk_path}"
    fi

    log_pass "Build complete."
}

# ------------------------------------------------------------------------------
# Phase 3: Extract splits and compare
# ------------------------------------------------------------------------------
extract_and_compare() {
    log_info "=== EXTRACTION AND COMPARISON PHASE ==="

    if [[ "${BUILD_MODE}" == "split" ]]; then
        extract_split_apks_from_aab \
            "${BUILT_AAB}" \
            "${WORK_DIR}/built-split-apks" \
            "${WORK_DIR}/device-spec.json"

        compare_split_apks \
            "${WORK_DIR}/official-split-apks" \
            "${WORK_DIR}/built-split-apks" \
            "${WORK_DIR}/comparison"
    else
        log_info "Comparing direct release APK against GitHub release APK..."
        [[ -f "${BUILT_APK}" ]] || { log_fail "Could not produce APK for comparison."; exit "${EXIT_FAILED}"; }
        compare_universal_apks \
            "${OFFICIAL_APK}" \
            "${BUILT_APK}" \
            "${WORK_DIR}/comparison"
    fi
}

# ------------------------------------------------------------------------------
# Phase 4: Result
# ------------------------------------------------------------------------------
result() {
    log_info "=== RESULTS ==="

    local verdict_label yaml_verdict exit_code
    if [[ "${TOTAL_DIFFS:-1}" -eq 0 ]]; then
        verdict_label="reproducible"
        yaml_verdict="reproducible"
        exit_code="${EXIT_SUCCESS}"
        log_pass "VERDICT: REPRODUCIBLE"
        [[ "${TOTAL_META_ONLY:-0}" -gt 0 ]] && \
            log_info "Note: ${TOTAL_META_ONLY} splits had only META-INF differences (expected)"
    else
        verdict_label="differences found"
        yaml_verdict="not_reproducible"
        exit_code="${EXIT_FAILED}"
        if [[ "${BUILD_MODE}" == "split" ]]; then
            log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} split(s) with non-signing differences)"
        else
            log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} APK content differences after META-INF filtering)"
        fi
    fi

    local notes
    if [[ "${BUILD_MODE}" == "split" ]]; then
        notes="Bull Bitcoin Mobile Android split APK verification.
  Mode: split (--binary ${TARGET_SPLIT_NAME}).
  Build: flutter build appbundle --release -> bundletool split extraction (device-spec: arch=${ARCH} density=${DENSITY} sdkVersion=${SDK_VER} locale=${LOCALE}).
  Environment: Ubuntu 24.04, OpenJDK 21, Flutter ${FLUTTER_VERSION}, Rust stable, Android SDK 35, NDK 27.0.12077973.
  NOTE: cargokit precompiled binaries disabled (use_precompiled_binaries: false).
  Differences in native .so files may reflect precompiled vs from-source Rust builds."
    else
        notes="Bull Bitcoin Mobile Android GitHub release APK verification.
  Mode: github (APK v${VERSION}).
  Build: flutter build apk --release -> direct APK comparison against GitHub release APK.
  Environment: Ubuntu 24.04, OpenJDK 21, Flutter ${FLUTTER_VERSION}, Rust stable, Android SDK 35, NDK 27.0.12077973.
  NOTE: cargokit precompiled binaries disabled (use_precompiled_binaries: false)."
    fi

    generate_comparison_yaml "${yaml_verdict}" "${notes}"
    RESULT_DONE=true

    print_results_block "${verdict_label}"

    if [[ "${should_cleanup}" == "true" ]]; then
        rm -rf "${WORK_DIR}"
        log_info "Workspace removed."
    else
        log_info "Workspace preserved: ${WORK_DIR}"
    fi

    echo "Exit code: ${exit_code}"
    return "${exit_code}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    log_info "Starting ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    log_warn "This script is provided as-is. Review before running. Use at your own risk."

    detect_container_runtime
    parse_arguments "$@"
    prepare
    build
    extract_and_compare
    result
}

main "$@"
