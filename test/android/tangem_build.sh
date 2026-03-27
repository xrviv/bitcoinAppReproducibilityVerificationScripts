#!/bin/bash
# ==============================================================================
# tangem_build.sh - Tangem Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.0
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-27
# Project:       https://github.com/tangem/tangem-app-android
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.tangem.wallet/changelog.md
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
# NOTE — DexProtector:
# Tangem release APKs are post-processed with DexProtector (commercial bytecode
# obfuscation by Licel). A source build produces unprotected DEX and native libs.
# Differences in these files are expected and are not a tooling mismatch — they
# result from DexProtector running as a CI post-build step using a paid license
# not present in the public repository. This script provides diff evidence only;
# a human reviewer interprets the verdict in a WS report.
#
# SCRIPT SUMMARY:
# Two operating modes, selected by arguments:
#
#   split mode (--binary <split.apk>):
#     Accepts a single official split APK from Google Play (1 of N splits installed
#     on device). Builds an AAB from source in a container, extracts split APKs
#     using bundletool + device-spec.json, finds the matching built split, and
#     runs a content diff. Generates COMPARISON_RESULTS.yaml with verdict.
#
#   github mode (--version <ver>, no --binary):
#     Downloads the official universal APK from Tangem GitHub releases. Builds a
#     universal APK via assembleGoogleRelease. Runs a content diff. Generates
#     COMPARISON_RESULTS.yaml with verdict. (GitHub release APK only — not the
#     Play Store artifact.)
#
# Both modes require GITHUB_TOKEN (read:packages scope) for Tangem SDK deps on
# GitHub Package Registry.

set -euo pipefail

# Capture execution directory before anything can change CWD
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"

# ------------------------------------------------------------------------------
# Script metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="v0.3.0"
readonly SCRIPT_NAME="tangem_build.sh"
readonly APP_ID="com.tangem.wallet"
readonly REPO_URL="https://github.com/tangem/tangem-app-android.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly TANGEM_BUILD_IMAGE_BASE="tangem_build_env"

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
APK_INPUT_KIND=""   # "file" | ""
INPUT_IS_ZIP=false  # true when --binary points to a .zip (WalletScrutiny Blossom upload)
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
github_token=""
github_user=""
should_cleanup=false

# set during prepare/build
BUILD_MODE=""        # "split" | "github"
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""      # canonical path in WORK_DIR to the official APK/split
OFFICIAL_BASE_APK="" # same as OFFICIAL_APK in split mode (used for metadata)
TARGET_SPLIT_NAME="" # canonical split filename being compared in split mode
BUILT_AAB=""
RESULT_DONE=false    # set true by result() after writing COMPARISON_RESULTS.yaml
TOTAL_DIFFS=1        # default to "failed" until compare_split_apks() runs

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

# ------------------------------------------------------------------------------
# YAML output helpers
# ------------------------------------------------------------------------------
write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "$content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
    fi
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
    # Only write YAML if we got past argument parsing (WORK_DIR is set).
    # Parameter/config errors (exit 2) before prepare() don't need a YAML artifact.
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
        # Cannot call generate_error_yaml yet (WORK_DIR not set); write manually
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
container_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        bash -c "$cmd"
}

container_sha256() {
    local file_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$file_path"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "sha256sum /data/$(basename "$file_path") | awk '{print \$1}'"
}

container_signer() {
    local apk_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$apk_path"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "apksigner verify --print-certs /apk/$(basename "$apk_path") 2>/dev/null \
               | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

# Zeus-pattern: aapt -> aapt2 -> apktool fallback. Never reads from filename.
container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm \
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
# Split APK name helpers (MetaMask pattern)
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
       ${SCRIPT_NAME} - Tangem Wallet Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --binary <split.apk> [--version <version>] [OPTIONS]
       ${SCRIPT_NAME} --version <version> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Builds Tangem Wallet from source in a container and compares against an
       official artifact. Two modes are supported:

       split mode (--binary <file>):
         Accepts one official split APK from Google Play (e.g. base.apk or
         split_config.arm64_v8a.apk). Builds an AAB via bundleGoogleRelease,
         extracts splits with bundletool, and compares the matching split.
         Version is auto-detected from the provided APK unless --version is given.

         NOTE: Tangem releases are post-processed with DexProtector. Differences
         in DEX files and native libs are expected in the comparison output.

       github mode (--version <ver>, no --binary):
         Downloads the official universal APK from Tangem GitHub releases.
         Builds a universal APK via assembleGoogleRelease and runs a content diff.
         This compares the GitHub release artifact, NOT the Play Store artifact.

       GITHUB_TOKEN is required in both modes (read:packages scope) for Tangem
       SDK dependencies on GitHub Package Registry.

OPTIONS
       --binary <file>            Path to one official Play Store split APK.
                                  Alias: --apk.
       --version <version>        Version to verify (e.g. 5.34.1). Required in
                                  github mode; optional in split mode (auto-detect).
       --arch <arch>              Target architecture for device-spec.json used
                                  by bundletool in split mode.
                                  Supported: arm64-v8a, armeabi-v7a, x86_64, x86.
                                  Default: arm64-v8a.
       --type <type>              Accepted for build server compatibility; unused.
       --tag <ref>                Override git tag (default: v<version>).
       --github-token <token>     GitHub PAT with read:packages scope.
                                  Overrides GITHUB_TOKEN env var.
       --github-user <user>       GitHub username for GPR auth.
                                  Default: walletscrutiny. Overrides GITHUB_USER.
       --cleanup                  Remove temporary files after completion.
       --script-version           Print script version and exit.
       --help                     Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF differences, or identical)
       1    Differences found or build failure
       2    Invalid parameters

ENVIRONMENT
       GITHUB_TOKEN     GitHub PAT with read:packages scope (required)
       GITHUB_USER      GitHub username (optional, default: walletscrutiny)

EXAMPLES
       # Split mode — one split from Play Store:
       export GITHUB_TOKEN="ghp_yourtoken"
       ${SCRIPT_NAME} --binary ~/apks/base.apk

       # Split mode — explicit version + arch:
       ${SCRIPT_NAME} --binary ~/apks/split_config.arm64_v8a.apk --version 5.34.1 --arch arm64-v8a

       # GitHub mode — download and compare GitHub release APK:
       ${SCRIPT_NAME} --version 5.34.1
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
            --tag)            REQUESTED_TAG="${2:-}"; shift ;;
            --github-token)   github_token="${2:-}";  shift ;;
            --github-user)    github_user="${2:-}";   shift ;;
            --cleanup)        should_cleanup=true ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)        usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            *)                log_warn "Ignoring unknown argument: $1" ;;
        esac
        shift
    done

    # Resolve credentials
    github_token="${github_token:-${GITHUB_TOKEN:-}}"
    github_user="${github_user:-${GITHUB_USER:-walletscrutiny}}"

    # Root check
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Do not run this script as root."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Token required
    if [[ -z "${github_token}" ]]; then
        echo "[ERROR] GITHUB_TOKEN is required (Tangem uses GitHub Package Registry)."
        echo "        Create a PAT with read:packages scope and set GITHUB_TOKEN."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Determine mode
    if [[ -n "${APK_INPUT}" ]]; then
        BUILD_MODE="split"
        # Resolve relative path before existence check
        [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
        if [[ -f "${APK_INPUT}" ]]; then
            if [[ "${APK_INPUT}" == *.zip ]]; then
                INPUT_IS_ZIP=true
                log_info "--binary is a zip; will extract APKs before comparison."
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
        echo "[ERROR] Provide --binary <split.apk> (split mode) or --version <version> (github mode)."
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

    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
    log_info "Build mode: ${BUILD_MODE}"
    log_info "Work directory: ${WORK_DIR}"
}

# ------------------------------------------------------------------------------
# google-services.json injection
# The repo ships a stub that covers .debug / .internal / .external / .release
# but not com.tangem.wallet (the production Google flavor package name).
# We append a stub entry for com.tangem.wallet so processGoogleReleaseGoogleServices
# finds a matching client. The stub values are non-functional but satisfy the build.
# ------------------------------------------------------------------------------
inject_google_services_json() {
    local target="$1"
    cat > "${target}" <<'GSERVICES_EOF'
{
  "project_info": {
    "project_number": "000000000000",
    "project_id": "___STUB___"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:123456789012:android:abcdef123456",
        "android_client_info": { "package_name": "com.tangem.wallet.debug" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "AIzaSystubstubstubstubstubstubstubstubs" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    },
    {
      "client_info": {
        "mobilesdk_app_id": "1:123456789012:android:abcdef123457",
        "android_client_info": { "package_name": "com.tangem.wallet.internal" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "AIzaSystubstubstubstubstubstubstubstubs" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    },
    {
      "client_info": {
        "mobilesdk_app_id": "1:123456789012:android:abcdef123458",
        "android_client_info": { "package_name": "com.tangem.wallet.external" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "AIzaSystubstubstubstubstubstubstubstubs" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    },
    {
      "client_info": {
        "mobilesdk_app_id": "1:123456789012:android:abcdef123459",
        "android_client_info": { "package_name": "com.tangem.wallet.release" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "AIzaSystubstubstubstubstubstubstubstubs" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    },
    {
      "client_info": {
        "mobilesdk_app_id": "1:123456789012:android:abcdef12345a",
        "android_client_info": { "package_name": "com.tangem.wallet" }
      },
      "oauth_client": [],
      "api_key": [{ "current_key": "AIzaSystubstubstubstubstubstubstubstubs" }],
      "services": { "appinvite_service": { "other_platform_oauth_client": [] } }
    }
  ],
  "configuration_version": "1"
}
GSERVICES_EOF
    log_info "Injected google-services.json with com.tangem.wallet entry."
}

# ------------------------------------------------------------------------------
# Build environment image
# Inline Dockerfile: Ubuntu 22.04, OpenJDK 17, Android SDK 35, NDK 25.1.8937393
# Built once, reused across runs via tag tangem_build_env:1.
# ------------------------------------------------------------------------------
ensure_build_image() {
    if ${CONTAINER_CMD} image inspect "${TANGEM_BUILD_IMAGE_BASE}:1" >/dev/null 2>&1; then
        log_info "Reusing existing build environment image: ${TANGEM_BUILD_IMAGE_BASE}:1"
        return
    fi

    log_info "Building Tangem build environment image (first-time, ~10 min)..."
    local dockerfile_dir="${WORK_DIR}/build_env"
    mkdir -p "${dockerfile_dir}"

    cat > "${dockerfile_dir}/Dockerfile" <<'DOCKERFILE_EOF'
FROM docker.io/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${JAVA_HOME}/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jdk wget unzip git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
         -O /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" && \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" \
       "${ANDROID_SDK_ROOT}/cmdline-tools/latest" && \
    rm /tmp/sdk.zip

RUN yes | sdkmanager --licenses >/dev/null 2>&1 && \
    sdkmanager \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
        "ndk;25.1.8937393" && \
    chmod -R 777 "${ANDROID_SDK_ROOT}"

RUN mkdir -p /workspace && chmod 777 /workspace
WORKDIR /workspace
DOCKERFILE_EOF

    ${CONTAINER_CMD} build --tag "${TANGEM_BUILD_IMAGE_BASE}:1" "${dockerfile_dir}"
    log_info "Build environment image ready."
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
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 33
}
DEVICESPEC_EOF
    log_info "Created device-spec.json for arch: ${arch}"
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
        # Move splits/ subdir contents up if bundletool used it
        if [[ -d \"${output_rel}/splits\" ]]; then
            mv \"${output_rel}/splits\"/*.apk \"${output_rel}/\" 2>/dev/null || true
            rmdir \"${output_rel}/splits\" 2>/dev/null || true
        fi
        # Normalize base-master.apk -> base.apk
        if [[ -f \"${output_rel}/base-master.apk\" ]]; then
            mv \"${output_rel}/base-master.apk\" \"${output_rel}/base.apk\"
        fi
        # Move standalones/standalone.apk -> base.apk if present
        if [[ -f \"${output_rel}/standalones/standalone.apk\" ]]; then
            mv \"${output_rel}/standalones/standalone.apk\" \"${output_rel}/base.apk\"
            rmdir \"${output_rel}/standalones\" 2>/dev/null || true
        fi
        # Normalize base-<suffix>.apk -> split_config.<suffix>.apk
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
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        bash -c "set -euo pipefail
            rm -rf \"/out/${dest_base}\"
            mkdir -p \"/out/${dest_base}\"
            unzip -qq -o \"/apk/${apk_file}\" -d \"/out/${dest_base}\"
        "
}

# ------------------------------------------------------------------------------
# Split-by-split comparison (MetaMask pattern)
# Counts non-META-INF differences using Leo's precise per-path regex.
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

        # Unzip both into results_dir for diff
        local official_unzip="${results_dir}/official_${comparison_name%.apk}"
        local built_unzip="${results_dir}/built_${comparison_name%.apk}"
        unzip_apk_in_container "${official_apk}"  "${official_unzip}"
        unzip_apk_in_container "${built_apk}"     "${built_unzip}"

        # Diff inside container; save full diff to file
        local diff_file="${results_dir}/diff_${comparison_name%.apk}.txt"
        local official_rel built_rel diff_rel
        official_rel="${official_unzip#"${WORK_DIR}/"}"
        built_rel="${built_unzip#"${WORK_DIR}/"}"
        diff_rel="${diff_file#"${WORK_DIR}/"}"
        container_exec "diff -r \"${official_rel}\" \"${built_rel}\" 2>&1 \
            > \"${diff_rel}\" 2>&1 || true"

        # Count non-META-INF diffs using Leo's precise regex
        # Filters only root-level META-INF; nested META-INF still counts
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
# Simple unzip diff (github mode: universal APK vs universal APK)
# Sets TOTAL_DIFFS.
# ------------------------------------------------------------------------------
compare_universal_apks() {
    local official_apk="$1"
    local built_apk="$2"
    local results_dir="$3"

    log_info "Comparing universal APKs..."
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

    # Tag verification output
    local tag_verify_output tag_type tag_status
    tag_verify_output="$(cat "${WORK_DIR}/built-aab/app/tag_verify.txt" 2>/dev/null || true)"
    tag_type="unknown"
    tag_status="[WARNING] Tag signature not checked"
    if echo "${tag_verify_output}" | grep -q "^TAG_TYPE=tag"; then
        tag_type="annotated"
        if echo "${tag_verify_output}" | grep -q "Good signature"; then
            tag_status="[OK] Good signature on annotated tag"
        else
            tag_status="[WARNING] Annotated tag — no valid signature found (gnupg not in build image)"
        fi
    elif echo "${tag_verify_output}" | grep -q "LIGHTWEIGHT_TAG"; then
        tag_type="lightweight"
        tag_status="[INFO] Lightweight tag (cannot carry a signature)"
    elif echo "${tag_verify_output}" | grep -qE "NO_TAG|TAG_TYPE=missing"; then
        tag_type="missing"
        tag_status="[WARNING] Tag not found in repository"
    fi

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

    echo "Revision, tag (and its signature):"
    echo "Tag: ${git_ref} (${tag_type})"
    echo "${tag_status}"
    echo "${tag_verify_output}" | grep -v '^TAG_TYPE=' | grep -v '^---COMMIT---' || true
    echo ""

    if [[ "${should_cleanup}" == "false" ]]; then
        echo "Run for more detail:"
        echo "  diffoscope '${WORK_DIR}/official-split-apks' '${WORK_DIR}/built-split-apks'"
        echo "  meld '${WORK_DIR}/comparison'"
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
        # If --binary is a zip (WalletScrutiny Android Blossom upload), extract it
        # first and copy all contained APKs into official-split-apks/.
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
                generate_error_yaml "ftbfs" "No APK files found inside the provided zip."
                RESULT_DONE=true
                exit "${EXIT_FAILED}"
            fi
            log_info "Zip extracted. ${apk_count} APK(s) found:"
            find "${zip_extract_dir}" -name "*.apk" | sort | while IFS= read -r f; do
                echo "  $(basename "${f}")"
            done
            # Copy and normalize all APKs into official-split-apks/
            while IFS= read -r apk; do
                local apk_name apk_canonical
                apk_name="$(basename "${apk}")"
                apk_canonical="$(canonicalize_split_apk_name "${apk_name}")"
                cp "${apk}" "${WORK_DIR}/official-split-apks/${apk_canonical}"
                [[ "${apk_name}" != "${apk_canonical}" ]] && \
                    log_info "Normalized: ${apk_name} -> ${apk_canonical}"
            done < <(find "${zip_extract_dir}" -name "*.apk" | sort)
            TARGET_SPLIT_NAME="zip ($(find "${WORK_DIR}/official-split-apks" -name "*.apk" | wc -l) splits)"
            OFFICIAL_APK="${WORK_DIR}/official-split-apks/base.apk"
            OFFICIAL_BASE_APK="${OFFICIAL_APK}"
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
        # github mode: download universal APK from GitHub releases
        log_info "Downloading official APK from GitHub releases (v${VERSION})..."
        local api_url="https://api.github.com/repos/tangem/tangem-app-android/releases/tags/v${VERSION}"

        local release_json
        release_json="$(${CONTAINER_CMD} run --rm \
            "${WS_CONTAINER}" \
            sh -c "curl -fsSL --max-time 30 '${api_url}'")"

        if echo "${release_json}" | grep -q '"message".*"Not Found"'; then
            log_fail "GitHub release v${VERSION} not found."
            exit "${EXIT_FAILED}"
        fi

        local apk_url
        apk_url="$(echo "${release_json}" \
            | grep -o '"browser_download_url":[[:space:]]*"[^"]*app-release[^"]*\.apk"' \
            | grep -o 'https://[^"]*' | head -1)"

        if [[ -z "${apk_url}" ]]; then
            apk_url="$(echo "${release_json}" \
                | grep -o '"browser_download_url":[[:space:]]*"[^"]*\.apk"' \
                | grep -o 'https://[^"]*' | head -1)"
        fi

        if [[ -z "${apk_url}" ]]; then
            log_fail "No APK asset found in release v${VERSION}."
            log_fail "Available assets:"
            echo "${release_json}" | grep -o '"name":[[:space:]]*"[^"]*"' | head -10
            exit "${EXIT_FAILED}"
        fi

        local apk_filename
        apk_filename="$(basename "${apk_url}")"
        log_info "Downloading: ${apk_url}"
        ${CONTAINER_CMD} run --rm \
            -v "${WORK_DIR}/official-split-apks:/dl${VOLUME_RW}" \
            "${WS_CONTAINER}" \
            sh -c "curl -fsSL --progress-bar -o /dl/${apk_filename} '${apk_url}'"

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

    ensure_build_image

    local git_ref="${REQUESTED_TAG:-v${VERSION}}"
    log_info "Cloning ${REPO_URL} at ${git_ref}..."

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab:/workspace${VOLUME_RW}" \
        -w /workspace \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        sh -c "git clone --depth 1 --branch '${git_ref}' '${REPO_URL}' app"

    local commit_hash
    commit_hash="$(${CONTAINER_CMD} run --rm \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RO}" \
        -w /workspace \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        sh -c "git rev-parse HEAD")"
    log_info "Checked out ${git_ref} at ${commit_hash}"
    echo "${commit_hash}" > "${WORK_DIR}/built-aab/commit.txt"

    # Tag and signature verification (best-effort; gnupg not in image so sigs show as unverified)
    ${CONTAINER_CMD} run --rm \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RO}" \
        -w /workspace \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        sh -c "
            tag_type=\$(git cat-file -t 'refs/tags/${git_ref}' 2>/dev/null || echo 'missing')
            printf 'TAG_TYPE=%s\n' \"\${tag_type}\" > /workspace/tag_verify.txt
            if [ \"\${tag_type}\" = 'tag' ]; then
                git tag -v '${git_ref}' >> /workspace/tag_verify.txt 2>&1 || true
            elif [ \"\${tag_type}\" = 'commit' ]; then
                printf 'LIGHTWEIGHT_TAG\n' >> /workspace/tag_verify.txt
            else
                printf 'NO_TAG\n' >> /workspace/tag_verify.txt
            fi
            printf '%s\n' '---COMMIT---' >> /workspace/tag_verify.txt
            git verify-commit HEAD >> /workspace/tag_verify.txt 2>&1 || true
        " || true

    # Choose Gradle task based on mode
    local gradle_task
    if [[ "${BUILD_MODE}" == "split" ]]; then
        gradle_task="bundleGoogleRelease"
    else
        gradle_task="assembleGoogleRelease"
    fi
    log_info "Running ./gradlew ${gradle_task} in container..."
    log_info "This may take 20-40 minutes on first dependency download."

    # Overwrite the repo's stub google-services.json with one that includes
    # com.tangem.wallet, which the Google release flavor requires.
    inject_google_services_json "${WORK_DIR}/built-aab/app/app/google-services.json"

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RW}" \
        -w /workspace \
        -e "GITHUB_TOKEN=${github_token}" \
        -e "GITHUB_USER=${github_user}" \
        -e "ANDROID_SDK_ROOT=/opt/android-sdk" \
        -e "HOME=/tmp" \
        -e "GRADLE_USER_HOME=/tmp/.gradle" \
        -e "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        bash -c "set -euo pipefail
            echo 'sdk.dir=/opt/android-sdk'    >  local.properties
            echo 'gpr.user=${github_user}'     >> local.properties
            echo 'gpr.key=${github_token}'     >> local.properties
            chmod +x gradlew
            ./gradlew ${gradle_task} \
                --no-daemon \
                --stacktrace \
                -Dorg.gradle.jvmargs='-Xmx8g -Xms2g -XX:MaxMetaspaceSize=512m'
        "

    if [[ "${BUILD_MODE}" == "split" ]]; then
        # Find the built AAB
        local aab_path
        aab_path="$(find "${WORK_DIR}/built-aab/app" -type f -name "*.aab" \
            -path "*/outputs/bundle/*" \
            ! -path "*/intermediates/*" \
            2>/dev/null | head -1 || true)"
        if [[ -z "${aab_path}" || ! -f "${aab_path}" ]]; then
            log_fail "Built AAB not found after bundleGoogleRelease."
            exit "${EXIT_FAILED}"
        fi
        log_info "Built AAB: ${aab_path}"
        BUILT_AAB="${aab_path}"
    else
        # Find the built universal APK
        local built_apk_path
        built_apk_path="${WORK_DIR}/built-aab/app/app/build/outputs/apk/google/release/app-google-release.apk"
        if [[ ! -f "${built_apk_path}" ]]; then
            built_apk_path="$(find "${WORK_DIR}/built-aab/app" -type f -name "*.apk" \
                ! -name "*unsigned*" ! -name "*test*" ! -path "*/androidTest/*" \
                2>/dev/null | head -1 || true)"
        fi
        if [[ -z "${built_apk_path}" || ! -f "${built_apk_path}" ]]; then
            log_fail "Built APK not found after assembleGoogleRelease."
            exit "${EXIT_FAILED}"
        fi
        log_info "Built APK: ${built_apk_path}"
        BUILT_AAB="${built_apk_path}"  # reuse variable for the built artifact path
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
        compare_universal_apks \
            "${OFFICIAL_APK}" \
            "${BUILT_AAB}" \
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
        log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} split(s) with non-signing differences)"
    fi

    local notes
    if [[ "${BUILD_MODE}" == "split" ]]; then
        notes="Tangem Wallet Android split APK verification.
  Mode: split (--binary ${TARGET_SPLIT_NAME}).
  Build: ./gradlew bundleGoogleRelease -> bundletool split extraction (device-spec: ${ARCH}).
  Environment: Ubuntu 22.04, OpenJDK 17, Android SDK 35, NDK 25.1.8937393.
  NOTE: Official APK is post-processed with DexProtector (commercial obfuscation).
  DEX and native lib differences are expected and are not a tooling mismatch.
  This is not reproducible in the strict sense due to DexProtector."
    else
        notes="Tangem Wallet Android GitHub release APK verification.
  Mode: github (universal APK v${VERSION}).
  Build: ./gradlew assembleGoogleRelease.
  Environment: Ubuntu 22.04, OpenJDK 17, Android SDK 35, NDK 25.1.8937393.
  NOTE: Official APK is post-processed with DexProtector (commercial obfuscation).
  DEX and native lib differences are expected and are not a tooling mismatch."
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
