#!/bin/bash
# tangem_build.sh - Tangem Wallet Android Reproducible Build Verification
# Version: v0.4.1 | Organization: WalletScrutiny.com | Last Modified: 2026-05-16
# Project: https://github.com/tangem/tangem-app-android
# Changelog: ~/work/ws-notes/script-notes/android/com.tangem.wallet/changelog.md
# LICENSE: MIT | For research use only. No warranty.
# Outputs build and diff evidence only; root-cause analysis belongs in the WS report.
# Two modes: split (--binary <apk|zip>) and github (--version, no --binary).
# Both require GITHUB_TOKEN (read:packages). Zip detected by content, not extension.

set -euo pipefail

# Capture execution directory before anything can change CWD
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"

# Script metadata
readonly SCRIPT_VERSION="v0.4.1"
readonly SCRIPT_NAME="tangem_build.sh"
readonly APP_ID="com.tangem.wallet"
readonly REPO_URL="https://github.com/tangem/tangem-app-android.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly TANGEM_BUILD_IMAGE_BASE="tangem_build_env"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2
readonly DEFAULT_ARCH="arm64-v8a"

# Global state (set by argument parsing)
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
REQUESTED_TAG=""

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
RESOLVED_GIT_REF=""

# Logging
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

normalize_detected_arch() {
    local raw="$1"
    case "${raw}" in
        arm64-v8a|arm64_v8a) echo "arm64-v8a" ;;
        armeabi-v7a|armeabi_v7a) echo "armeabi-v7a" ;;
        x86_64) echo "x86_64" ;;
        x86) echo "x86" ;;
        *) echo "" ;;
    esac
}

extract_arch_tokens_from_text() {
    local input="$1"
    printf '%s\n' "${input}" \
        | grep -Eoi 'arm64[-_]?v8a|armeabi[-_]?v7a|x86_64|x86' \
        | sed 's/-/_/g' \
        | sort -u || true
}

auto_detect_arch_from_binary_input() {
    local binary_path="$1"
    local is_zip="$2"
    local collected="" token normalized unique_count

    collected="$(extract_arch_tokens_from_text "$(basename "${binary_path}")")"

    if [[ "${is_zip}" == "true" ]]; then
        local zip_entries
        zip_entries="$(unzip -Z1 "${binary_path}" 2>/dev/null || true)"
        if [[ -n "${zip_entries}" ]]; then
            collected="$(printf '%s\n%s\n' "${collected}" "$(extract_arch_tokens_from_text "${zip_entries}")" \
                | sed '/^$/d' | sort -u)"
        fi
    else
        local apk_entries
        apk_entries="$(unzip -Z1 "${binary_path}" 2>/dev/null || true)"
        if [[ -n "${apk_entries}" ]]; then
            collected="$(printf '%s\n%s\n' "${collected}" "$(extract_arch_tokens_from_text "${apk_entries}")" \
                | sed '/^$/d' | sort -u)"
        fi

        local sibling_dir sibling_listing
        sibling_dir="$(dirname "${binary_path}")"
        sibling_listing="$(ls -1 "${sibling_dir}" 2>/dev/null || true)"
        if [[ -n "${sibling_listing}" ]]; then
            collected="$(printf '%s\n%s\n' "${collected}" "$(extract_arch_tokens_from_text "${sibling_listing}")" \
                | sed '/^$/d' | sort -u)"
        fi
    fi

    collected="$(printf '%s\n' "${collected}" | sed '/^$/d' | sort -u)"
    unique_count="$(printf '%s\n' "${collected}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${unique_count}" -eq 1 ]]; then
        token="$(printf '%s\n' "${collected}" | head -1)"
        normalized="$(normalize_detected_arch "${token}")"
        printf '%s\n' "${normalized}"
        return
    fi

    if [[ "${unique_count}" -gt 1 ]]; then
        if printf '%s\n' "${collected}" | grep -q '^arm64_v8a$'; then
            printf '%s\n' "arm64-v8a"
            return
        fi
        token="$(printf '%s\n' "${collected}" | head -1)"
        normalized="$(normalize_detected_arch "${token}")"
        printf '%s\n' "${normalized}"
        return
    fi

    printf '%s\n' ""
}

# YAML output helpers
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

# Error handling
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

# Container runtime detection
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

# Container helpers

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

# Split APK name helpers (MetaMask pattern)
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

# Usage
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <split.apk|zip> [--version <ver>] [--arch <arch>] [OPTIONS]
       ${SCRIPT_NAME} --version <ver> [OPTIONS]
Options: --github-token <tok>, --github-user <user>, --tag <ref>, --cleanup, --script-version
Split mode (--binary): bundleGoogleRelease -> bundletool splits -> content diff. GITHUB_TOKEN required.
GitHub mode (--version, no --binary): downloads universal APK, assembleGoogleRelease, content diff.
Arch auto-detected from --binary when --arch is omitted. Supported: arm64-v8a armeabi-v7a x86_64 x86.
Exit: 0=reproducible, 1=differences/failure, 2=invalid params. Env: GITHUB_TOKEN, GITHUB_USER.
EOF
}

# Argument parsing
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
        if [[ -z "${ARCH}" ]]; then
            ARCH="$(auto_detect_arch_from_binary_input "${APK_INPUT}" "${INPUT_IS_ZIP}")"
            if [[ -n "${ARCH}" ]]; then
                log_info "Auto-detected architecture from --binary: ${ARCH}"
            else
                ARCH="${DEFAULT_ARCH}"
                log_warn "Could not auto-detect architecture from --binary; defaulting to ${ARCH}. Pass --arch to override."
            fi
        fi
    elif [[ -n "${VERSION}" ]]; then
        BUILD_MODE="github"
        ARCH="${ARCH:-${DEFAULT_ARCH}}"
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

# google-services.json injection: stub for com.tangem.wallet (prod flavor not in repo stub)
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

# Build environment image
# Inline Dockerfile: Ubuntu 22.04, OpenJDK 17, Android SDK 35, NDK 25.1.8937393
# Built once, reused across runs via tag tangem_build_env:1.
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

# device-spec.json for bundletool
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

# bundletool split extraction
# Runs inside the build image (which has Java). Downloads bundletool if absent.
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

# Unzip an APK into a directory, inside the build container
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

# Split-by-split comparison (MetaMask pattern)
# Counts non-META-INF differences using Leo's precise per-path regex.
# Sets TOTAL_DIFFS and TOTAL_META_ONLY.
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

# Simple unzip diff (github mode: universal APK vs universal APK)
# Sets TOTAL_DIFFS.
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

# Print results block (terminal output)
print_results_block() {
    local verdict="$1"
    local version_name version_code signer official_hash commit_hash git_ref_display

    version_name="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
    version_code="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_BASE_APK}" || true)"
    official_hash="$(container_sha256 "${OFFICIAL_BASE_APK}")"
    commit_hash="$(cat "${WORK_DIR}/built-aab/commit.txt" 2>/dev/null || echo "unknown")"
    git_ref_display="${RESOLVED_GIT_REF:-${REQUESTED_TAG:-v${VERSION:-unknown}}}"

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
    echo "Tag: ${git_ref_display} (${tag_type})"
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

# Phase 1: Prepare
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

# Phase 2: Build
build() {
    log_info "=== BUILD PHASE ==="

    ensure_build_image

    RESOLVED_GIT_REF="${REQUESTED_TAG:-v${VERSION}}"
    log_info "Cloning ${REPO_URL} at ${RESOLVED_GIT_REF}..."

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab:/workspace${VOLUME_RW}" \
        -w /workspace \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        sh -c "git clone --depth 1 --branch '${RESOLVED_GIT_REF}' '${REPO_URL}' app"

    local commit_hash
    commit_hash="$(${CONTAINER_CMD} run --rm \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RO}" \
        -w /workspace \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        sh -c "git rev-parse HEAD")"
    log_info "Checked out ${RESOLVED_GIT_REF} at ${commit_hash}"
    echo "${commit_hash}" > "${WORK_DIR}/built-aab/commit.txt"

    # Tag and signature verification (best-effort; gnupg not in image so sigs show as unverified)
    ${CONTAINER_CMD} run --rm \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RO}" \
        -w /workspace \
        "${TANGEM_BUILD_IMAGE_BASE}:1" \
        sh -c "
            tag_type=\$(git cat-file -t 'refs/tags/${RESOLVED_GIT_REF}' 2>/dev/null || echo 'missing')
            printf 'TAG_TYPE=%s\n' \"\${tag_type}\" > /workspace/tag_verify.txt
            if [ \"\${tag_type}\" = 'tag' ]; then
                git tag -v '${RESOLVED_GIT_REF}' >> /workspace/tag_verify.txt 2>&1 || true
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
        --memory=20g \
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
            export GRADLE_OPTS='-Xmx12g -XX:MaxMetaspaceSize=512m'
            export KOTLIN_DAEMON_JVM_OPTIONS='-Xmx4g -XX:MaxMetaspaceSize=512m'
            echo 'sdk.dir=/opt/android-sdk'    >  local.properties
            echo 'gpr.user=${github_user}'     >> local.properties
            echo 'gpr.key=${github_token}'     >> local.properties
            chmod +x gradlew
            echo '[DIAG] Memory before ${gradle_task}:' && free -m
            ./gradlew ${gradle_task} \
                --no-daemon \
                --no-build-cache \
                --stacktrace \
                --max-workers=4
            echo '[DIAG] Memory after ${gradle_task}:' && free -m
        "

    if [[ "${BUILD_MODE}" == "split" ]]; then
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

# Phase 3: Extract splits and compare
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

# Phase 4: Result
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
  Diff handling: script stores full evidence in comparison/diff_*.txt.
  Root-cause attribution is done in the verification report."
    else
        notes="Tangem Wallet Android GitHub release APK verification.
  Mode: github (universal APK v${VERSION}).
  Build: ./gradlew assembleGoogleRelease.
  Environment: Ubuntu 22.04, OpenJDK 17, Android SDK 35, NDK 25.1.8937393.
  Diff handling: script stores full evidence in comparison/diff_full.txt.
  Root-cause attribution is done in the verification report."
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

# Main
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
