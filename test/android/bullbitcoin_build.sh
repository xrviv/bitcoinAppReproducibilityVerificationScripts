#!/bin/bash
# split(--binary+--version)→AAB/bundletool; github(--version)→APK/GitHub. Toolchain: .fvmrc(fail)/gradle.properties/Containerfile.tools; defaults=post-PR#2032.
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"
readonly SCRIPT_VERSION="v0.5.13"
readonly SCRIPT_NAME="bullbitcoin_build.sh"
readonly APP_ID="com.bullbitcoin.mobile"
readonly REPO_URL="https://github.com/SatoshiPortal/bullbitcoin-mobile.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly BULLBITCOIN_BUILD_IMAGE_BASE="bullbitcoin_build_env"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2
VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""        # path given to --binary / --apk
INPUT_IS_ZIP=false  # true when --binary points to a zip (WalletScrutiny Blossom upload)
INPUT_IS_TAR=false  # true when --binary points to a plain tar (WalletScrutiny Blossom upload, new format)
INPUT_IS_DIR=false  # true when --binary points to a directory of split APKs (ABS multi-binary case)
WORK_DIR=""
FLUTTER_VERSION=""      # detected from repo's .fvmrc; set in detect_build_versions
NDK_VERSION="29.0.14206865"     # detected from android/gradle.properties; fallback default
ANDROID_API_LEVEL="36"          # detected from android/gradle.properties; fallback default
ANDROID_BUILD_TOOLS="36.0.0"    # detected from android/gradle.properties; fallback default
RUST_VERSION="1.95.0"           # detected from Containerfile.tools; fallback default
TOOLCHAIN_DEFAULTED=false
DENSITY="480"          # screen density for bundletool device-spec.json (override with --density)
SDK_VER="33"           # SDK version for bundletool device-spec.json (override with --sdk-ver)
LOCALE="en"            # locale for bundletool device-spec.json (override with --locale)
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
should_cleanup=false
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
    local flutter_safe ndk_safe rust_safe script_safe
    flutter_safe="${FLUTTER_VERSION//./_}"
    ndk_safe="${NDK_VERSION//./_}"
    rust_safe="${RUST_VERSION//./_}"
    script_safe="${SCRIPT_VERSION#v}"
    script_safe="${script_safe//./_}"
    printf '%s:flutter_%s_ndk_%s_rust_%s_script_%s\n' \
        "${BULLBITCOIN_BUILD_IMAGE_BASE}" \
        "${flutter_safe}" \
        "${ndk_safe}" \
        "${rust_safe}" \
        "${script_safe}"
}
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
apk_badging() {
    # Raw `aapt dump badging`, run inside the WS container (always ships aapt).
    local apk_path="$1" apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"; apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
        -v "${apk_dir}:/apk${VOLUME_RO}" "${WS_CONTAINER}" \
        sh -c 'aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null' 2>/dev/null || true
}
detect_apk_metadata_field() {
    local apk_path="$1" field="$2" detected apk_dir apk_name
    detected="$(apk_badging "${apk_path}" | sed -n "s/.*${field}='\([^']*\)'.*/\1/p" | head -n1 || true)"
    [[ -n "${detected}" ]] && { printf '%s\n' "${detected}"; return 0; }
    # apktool fallback when badging unavailable
    apk_dir="$(dirname "${apk_path}")"; apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
        -v "${apk_dir}:/apk${VOLUME_RO}" "${WS_CONTAINER}" \
        sh -c '
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
                case "'"${field}"'" in
                    versionName) sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" "$tmpdir/out/apktool.yml" | head -n1 ;;
                    versionCode) sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" "$tmpdir/out/apktool.yml" | head -n1 ;;
                esac
            fi
            rm -rf "$tmpdir"
        ' 2>/dev/null || true
}
infer_version_from_build_context() {
    local path name
    for path in "${EXEC_DIR}" "$(dirname "${APK_INPUT:-${EXEC_DIR}}")"; do
        while [[ -n "${path}" && "${path}" != "/" && "${path}" != "." ]]; do
            name="$(basename "${path}")"
            if [[ "${name}" =~ _[0-9a-fA-F]{64}_([0-9][0-9A-Za-z._+-]*)$|^([0-9]+\.[0-9][0-9A-Za-z._+-]*)$ ]]; then
                printf '%s\n' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
                return 0
            fi
            path="$(dirname "${path}")"
        done
    done
    return 1
}
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
stage_official_splits() {
    # $1=source dir of *.apk  $2=label. Stages canonicalized splits; ftbfs if no base APK.
    local src="$1" label="$2" apk apk_name apk_canonical found_base
    while IFS= read -r apk; do
        apk_name="$(basename "${apk}")"
        apk_canonical="$(canonicalize_split_apk_name "${apk_name}")"
        cp "${apk}" "${WORK_DIR}/official-split-apks/${apk_canonical}"
        [[ "${apk_name}" != "${apk_canonical}" ]] && log_info "Normalized: ${apk_name} -> ${apk_canonical}"
    done < <(find "${src}" -name "*.apk" | sort)
    TARGET_SPLIT_NAME="${label} ($(find "${WORK_DIR}/official-split-apks" -name '*.apk' | wc -l) splits)"
    found_base="$(find_official_base_apk)"
    if [[ -z "${found_base}" ]]; then
        log_fail "No base APK found in ${label} (expected base.apk or base-master.apk)."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"
    fi
    OFFICIAL_APK="${found_base}"; OFFICIAL_BASE_APK="${found_base}"
}
verify_package_name() {
    # Gate: base APK package == APP_ID before build; anchored ^package: avoids versionName=.
    local apk="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}" pkg
    [[ -n "${apk}" && -f "${apk}" ]] || return 0
    pkg="$(apk_badging "${apk}" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/" | head -n1 || true)"
    [[ -z "${pkg}" ]] && { log_warn "Could not read package name from $(basename "${apk}"); skipping gate."; return 0; }
    if [[ "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package name mismatch: APK is '${pkg}', expected '${APP_ID}'."
        generate_error_yaml "ftbfs"; echo "Exit code: ${EXIT_INVALID}"; RESULT_DONE=true; exit "${EXIT_INVALID}"
    fi
    log_info "Package name verified: ${pkg}"
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
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <split.apk|dir|zip|tar.gz> [--version X] [OPTIONS]
       ${SCRIPT_NAME} --version <version> [OPTIONS]
Options:
  --binary <path>   Official split APK, dir of splits, zip, or tar.gz (alias: --apk)
  --version <ver>   App version e.g. 6.5.2
  --arch <arch>     arm64-v8a|armeabi-v7a|x86_64|x86 (default: arm64-v8a)
  --density <dpi>   bundletool screen density (default: 480)
  --sdk-ver <N>     bundletool SDK version (default: 33)
  --locale <tag>    bundletool locale (default: en)
  --type <type>     Ignored (ABS compatibility)
  --cleanup         Remove temp files after run
  --script-version  Print version and exit
  --help            Show this help
Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid
EOF
}
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
    if [[ -n "${APK_INPUT}" ]]; then
        BUILD_MODE="split"
        [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
        APK_INPUT="${APK_INPUT%/}"
        if [[ -d "${APK_INPUT}" ]]; then
            if [[ -z "$(find "${APK_INPUT}" -name '*.apk' 2>/dev/null | head -1)" ]]; then
                echo "[ERROR] --binary directory contains no APKs: ${APK_INPUT}"
                generate_error_yaml "ftbfs"; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"
            fi
            INPUT_IS_DIR=true
            log_info "--binary is a directory; ALL split APKs in it will be verified."
        elif [[ -f "${APK_INPUT}" ]]; then
            if file "${APK_INPUT}" | grep -q "Zip archive" && \
               unzip -l "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
                INPUT_IS_ZIP=true
                log_info "--binary is a zip archive containing APKs; will extract before comparison."
            elif [[ "${APK_INPUT}" == *.tar.gz || "${APK_INPUT}" == *.tgz || "${APK_INPUT}" == *.tar ]]; then
                INPUT_IS_TAR=true
                log_info "--binary is a tar/tar.gz archive containing APKs; will extract before comparison."
            fi
        else
            echo "[ERROR] --binary path not found: ${APK_INPUT}"
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
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            echo "[ERROR] Unsupported architecture: ${ARCH}"
            echo "        Supported: arm64-v8a, armeabi-v7a, x86_64, x86"
            echo "Exit code: ${EXIT_INVALID}"
            exit "${EXIT_INVALID}"
            ;;
    esac
    if ! [[ "${DENSITY}" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] --density must be a positive integer (got: ${DENSITY})"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi
    if ! [[ "${SDK_VER}" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] --sdk-ver must be a positive integer (got: ${SDK_VER})"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi
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
detect_build_versions() {
    command -v git >/dev/null 2>&1 || { log_fail "git missing; needed for toolchain detection."; generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
    local git_ref="v${VERSION}"
    log_info "Detecting toolchain at ${git_ref}..."
    local _tmp raw
    _tmp="$(mktemp -d)"
    git clone --depth 1 --filter=blob:none --no-checkout \
        --branch "${git_ref}" "${REPO_URL}" "${_tmp}/r" 2>/dev/null || \
        log_warn "git clone failed for ${git_ref}; toolchain keys may default"
    raw="$(printf '__FVMRC__\n'
           git -C "${_tmp}/r" show HEAD:.fvmrc 2>/dev/null || true
           printf '__GRADLE__\n'
           git -C "${_tmp}/r" show HEAD:android/gradle.properties 2>/dev/null || true
           printf '__CTOOLS__\n'
           git -C "${_tmp}/r" show HEAD:Containerfile.tools 2>/dev/null || true)"
    rm -rf "${_tmp}"
    local fvmrc gradle ctools
    fvmrc="$(echo  "${raw}" | awk '/^__FVMRC__/{f=1;next} /^__GRADLE__/{f=0} f')"
    gradle="$(echo "${raw}" | awk '/^__GRADLE__/{f=1;next} /^__CTOOLS__/{f=0} f')"
    ctools="$(echo "${raw}" | awk '/^__CTOOLS__/{f=1;next} f')"
    local detected_flutter
    detected_flutter="$(echo "${fvmrc}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -z "${detected_flutter}" ]]; then
        log_fail "Flutter version not in .fvmrc at ${git_ref}; check tag/repo/network."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"
    fi
    FLUTTER_VERSION="${detected_flutter}"
    local detected_ndk detected_api detected_bt
    detected_ndk="$(echo "${gradle}" | grep '^android\.ndkVersion='       | cut -d= -f2 | tr -d '[:space:]' || true)"
    detected_api="$(echo "${gradle}" | grep '^android\.compileSdk='        | cut -d= -f2 | tr -d '[:space:]' || true)"
    detected_bt="$( echo "${gradle}" | grep '^android\.buildToolsVersion=' | cut -d= -f2 | tr -d '[:space:]' || true)"
    if [[ -n "${detected_ndk}" ]]; then NDK_VERSION="${detected_ndk}"
    else log_warn "NDK missing; using default ${NDK_VERSION}"; fi
    if [[ -n "${detected_api}" ]]; then ANDROID_API_LEVEL="${detected_api}"
    else log_warn "compileSdk missing; using default ${ANDROID_API_LEVEL}"; fi
    if [[ -n "${detected_bt}" ]]; then ANDROID_BUILD_TOOLS="${detected_bt}"
    else log_warn "buildToolsVersion missing; using default ${ANDROID_BUILD_TOOLS}"; fi
    local detected_rust
    detected_rust="$(echo "${ctools}" | grep '^ARG RUST_VERSION=' | sed 's/ARG RUST_VERSION="\(.*\)"/\1/' | tr -d '[:space:]' || true)"
    if [[ -n "${detected_rust}" ]]; then RUST_VERSION="${detected_rust}"
    else log_warn "Rust missing; using default ${RUST_VERSION}"; fi
    if [[ -z "${detected_ndk}" && -z "${detected_api}" && -z "${detected_bt}" && -z "${detected_rust}" ]]; then
        TOOLCHAIN_DEFAULTED=true
        log_warn "Toolchain defaults: NDK=${NDK_VERSION} Rust=${RUST_VERSION} (pre-PR#2032?)"
    fi
    log_info "Toolchain: Flutter=${FLUTTER_VERSION} NDK=${NDK_VERSION} SDK=${ANDROID_API_LEVEL} build-tools=${ANDROID_BUILD_TOOLS} Rust=${RUST_VERSION}"
}
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
FROM --platform=linux/amd64 docker.io/debian:trixie
ARG NDK_VERSION=29.0.14206865
ARG ANDROID_API_LEVEL=36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG RUST_VERSION=1.95.0
ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    FLUTTER_HOME=/opt/flutter \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/${NDK_VERSION} \
    NDK_HOME=/opt/android-sdk/ndk/${NDK_VERSION}
ENV PATH="/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-21-openjdk-amd64/bin:/root/.cargo/bin:${PATH}"
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk-headless wget unzip git curl ca-certificates \
        make clang cmake ninja-build pkg-config build-essential \
        xz-utils zip && \
    rm -rf /var/lib/apt/lists/*
RUN mv /usr/bin/git /usr/bin/git.real && \
    printf '#!/bin/sh\nif [ "$1" = "clone" ]; then shift; exec /usr/bin/git.real clone --no-hardlinks "$@"; fi\nexec /usr/bin/git.real "$@"\n' \
        > /usr/bin/git && \
    chmod +x /usr/bin/git
RUN mkdir -p /opt/android-sdk/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip \
         -O /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d /opt/android-sdk/cmdline-tools && \
    mv /opt/android-sdk/cmdline-tools/cmdline-tools \
       /opt/android-sdk/cmdline-tools/latest && \
    rm /tmp/sdk.zip
RUN yes | sdkmanager --licenses >/dev/null 2>&1 && \
    sdkmanager \
        "platform-tools" \
        "platforms;android-${ANDROID_API_LEVEL}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" \
        "ndk;${NDK_VERSION}" && \
    chmod -R 777 /opt/android-sdk
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION} --no-modify-path && \
    /root/.cargo/bin/rustup target add \
        aarch64-linux-android \
        armv7-linux-androideabi \
        x86_64-linux-android \
        i686-linux-android
ARG FLUTTER_VERSION=stable
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter && \
    /opt/flutter/bin/flutter --version && \
    /opt/flutter/bin/flutter config --android-sdk=/opt/android-sdk && \
    yes | /opt/flutter/bin/flutter doctor --android-licenses >/dev/null 2>&1 || true && \
    chmod -R 777 /opt/flutter
RUN printf '#!/bin/sh\ncase "$1" in\n  flutter) shift; exec /opt/flutter/bin/flutter "$@";;\n  dart) shift; exec /opt/flutter/bin/dart "$@";;\n  *) exec /opt/flutter/bin/flutter "$@";;\nesac\n' > /usr/local/bin/fvm && chmod +x /usr/local/bin/fvm
RUN chmod 755 /root && \
    chmod -R 777 /root/.cargo /root/.rustup && \
    mkdir -p /root/.gradle && chmod 777 /root/.gradle && \
    mkdir -p /root/.pub-cache && chmod -R 777 /root/.pub-cache
RUN git config --system --add safe.directory /opt/flutter
RUN /opt/flutter/bin/flutter precache --android 2>/dev/null || true && \
    rm -rf /opt/flutter/bin/cache/artifacts/gradle_wrapper && \
    chmod -R 777 /opt/flutter/bin/cache
RUN mkdir -p /workspace && chmod 777 /workspace
WORKDIR /workspace
DOCKERFILE_EOF
    ${CONTAINER_CMD} build \
        --no-cache \
        --build-arg "FLUTTER_VERSION=${FLUTTER_VERSION}" \
        --build-arg "NDK_VERSION=${NDK_VERSION}" \
        --build-arg "ANDROID_API_LEVEL=${ANDROID_API_LEVEL}" \
        --build-arg "ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS}" \
        --build-arg "RUST_VERSION=${RUST_VERSION}" \
        --tag "${image_tag}" \
        "${dockerfile_dir}"
    log_info "Build environment image ready: ${image_tag}"
}
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
    local -A _matched_built_names=()
    for _off_apk in "${official_dir}"/*.apk; do
        [[ ! -f "${_off_apk}" ]] && continue
        local _resolved
        _resolved="$(resolve_built_split_apk "${_off_apk}" "${built_dir}" || true)"
        [[ -n "${_resolved}" && -f "${_resolved}" ]] && _matched_built_names["$(basename "${_resolved}")"]="1"
    done
    for _built_apk in "${built_dir}"/*.apk; do
        [[ ! -f "${_built_apk}" ]] && continue
        local _bname
        _bname="$(basename "${_built_apk}")"
        if [[ -z "${_matched_built_names["${_bname}"]:-}" ]]; then
            log_warn "Extra built split with no official counterpart: ${_bname}"
            (( TOTAL_DIFFS++ )) || true
        fi
    done
}
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
print_results_block() {
    local verdict="$1"
    local version_name version_code signer official_hash commit_hash
    version_name="$(detect_apk_metadata_field "${OFFICIAL_BASE_APK}" "versionName" || true)"
    version_code="$(detect_apk_metadata_field "${OFFICIAL_BASE_APK}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_BASE_APK}" || true)"
    official_hash="$(container_sha256 "${OFFICIAL_BASE_APK}")"
    commit_hash="$(cat "${WORK_DIR}/built-aab/commit.txt" 2>/dev/null || echo "unknown")"
    echo ""
    echo "===== Begin Results ====="
    echo "scriptVersion:  ${SCRIPT_VERSION}"
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
prepare() {
    log_info "=== PREPARATION PHASE ==="
    if [[ -d "${WORK_DIR}" ]]; then
        log_info "Removing existing work directory: ${WORK_DIR}"
        rm -rf "${WORK_DIR}"
    fi
    mkdir -p "${WORK_DIR}"/{official-split-apks,built-split-apks,built-aab,comparison}
    chmod 777 "${WORK_DIR}/built-aab"
    if [[ "${BUILD_MODE}" == "split" ]]; then
        if [[ "${INPUT_IS_DIR}" == "true" ]]; then
            log_info "Staging split APKs from directory: ${APK_INPUT}"
            stage_official_splits "${APK_INPUT}" "directory"
        elif [[ "${INPUT_IS_ZIP}" == "true" || "${INPUT_IS_TAR}" == "true" ]]; then
            local archive_type extract_dir
            extract_dir="${WORK_DIR}/archive-extracted"
            mkdir -p "${extract_dir}"
            if [[ "${INPUT_IS_ZIP}" == "true" ]]; then
                archive_type="zip"
                log_info "Extracting zip: $(basename "${APK_INPUT}")"
                unzip -qq "${APK_INPUT}" -d "${extract_dir}" 2>/dev/null || true
            else
                archive_type="tar"
                log_info "Extracting tar: $(basename "${APK_INPUT}")"
                tar -xf "${APK_INPUT}" -C "${extract_dir}" || log_warn "tar: extraction errors"
            fi
            chmod -R a+rwX "${extract_dir}" 2>/dev/null || true
            local apk_count
            apk_count="$(find "${extract_dir}" -name "*.apk" 2>/dev/null | wc -l)"
            if [[ "${apk_count}" -eq 0 ]]; then
                log_fail "No APK files found inside ${archive_type}: ${APK_INPUT}"
                generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"
            fi
            log_info "Archive extracted. ${apk_count} APK(s) found."
            stage_official_splits "${extract_dir}" "${archive_type}"
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
            VERSION="$(detect_apk_metadata_field "${OFFICIAL_APK}" "versionName" || true)"
            [[ -z "${VERSION}" ]] && log_warn "aapt/apktool: no version; trying path"
            if [[ -z "${VERSION}" ]]; then
                VERSION="$(infer_version_from_build_context || true)"
                if [[ -n "${VERSION}" ]]; then
                    log_info "Version inferred from build context: ${VERSION}"
                fi
            fi
            if [[ -z "${VERSION}" ]]; then
                log_fail "Could not detect version from APK or build context. Pass --version explicitly."
                exit "${EXIT_INVALID}"
            fi
            log_info "Version detected: ${VERSION}"
            VERSION_SAFE="${VERSION}"
            local old_work_dir="${WORK_DIR}"
            WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
            if [[ "${WORK_DIR}" != "${old_work_dir}" ]]; then
                [[ -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
                mv "${old_work_dir}" "${WORK_DIR}"
                log_info "Work directory renamed to: ${WORK_DIR}"
                OFFICIAL_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK}")"
                OFFICIAL_BASE_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_BASE_APK}")"
            fi
        fi
        create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"
    else
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
    verify_package_name
    log_pass "Preparation complete."
}
build() {
    log_info "=== BUILD PHASE ==="
    detect_build_versions
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
    local build_cmd
    if [[ "${BUILD_MODE}" == "split" ]]; then
        build_cmd="fvm flutter build appbundle --release"
    else
        build_cmd="fvm flutter build apk --release"
    fi
    log_info "Running Flutter build (${build_cmd})..."
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-aab/app:/workspace${VOLUME_RW}" \
        -w /workspace \
        -e "ANDROID_SDK_ROOT=/opt/android-sdk" \
        -e "ANDROID_HOME=/opt/android-sdk" \
        -e "ANDROID_NDK_HOME=/opt/android-sdk/ndk/${NDK_VERSION}" \
        -e "NDK_HOME=/opt/android-sdk/ndk/${NDK_VERSION}" \
        -e "RUSTUP_TOOLCHAIN=${RUST_VERSION}" \
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
            if [[ -f .env.template && ! -f .env ]]; then
                cp .env.template .env
                echo '[INFO] Created .env from template'
            fi
            keytool -genkey -v -keystore /tmp/upload-keystore.jks \
                -keyalg RSA -keysize 2048 -validity 10000 \
                -alias upload -storepass android -keypass android \
                -dname 'CN=WalletScrutiny,O=WalletScrutiny,C=US' 2>/dev/null || true
            if [[ -d android ]]; then
                printf 'storePassword=android\nkeyPassword=android\nkeyAlias=upload\nstoreFile=/tmp/upload-keystore.jks\n' \
                    > android/key.properties
                echo '[INFO] Created android/key.properties'
            fi
            fvm flutter pub get
            fvm dart run build_runner build --delete-conflicting-outputs --force-jit
            fvm flutter gen-l10n
            SOURCE_DATE_EPOCH=\$(git log -1 --format=%ct)
            CARGO_ENCODED_RUSTFLAGS=\$(printf '%s\037%s\037%s' '--remap-path-prefix=/root/.cargo=/cargo' '--remap-path-prefix=/root/.rustup=/rustup' '--remap-path-prefix=/workspace=/build')
            CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
            export SOURCE_DATE_EPOCH CARGO_ENCODED_RUSTFLAGS CARGO_PROFILE_RELEASE_CODEGEN_UNITS
            ${build_cmd}
        " || { log_fail 'Flutter build failed (see above).'; generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
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
    local notes common
    common="Environment: Debian trixie, OpenJDK 21, Flutter ${FLUTTER_VERSION}, Rust ${RUST_VERSION}, Android SDK ${ANDROID_API_LEVEL}, NDK ${NDK_VERSION}.
  SOURCE_DATE_EPOCH + CARGO_ENCODED_RUSTFLAGS path remapping applied (upstream make apk release).
  cargokit: precompiled binaries enabled (not overridden)."
    if [[ "${BUILD_MODE}" == "split" ]]; then
        notes="Bull Bitcoin Mobile Android split APK verification.
  Mode: split (--binary ${TARGET_SPLIT_NAME}).
  Build: fvm flutter build appbundle --release -> bundletool split extraction (device-spec: arch=${ARCH} density=${DENSITY} sdkVersion=${SDK_VER} locale=${LOCALE}).
  ${common}"
    else
        notes="Bull Bitcoin Mobile Android GitHub release APK verification.
  Mode: github (APK v${VERSION}).
  Build: fvm flutter build apk --release -> direct APK comparison against GitHub release APK.
  ${common}"
    fi
    [[ "${TOOLCHAIN_DEFAULTED}" == "true" ]] && notes="WARNING: toolchain defaulted (tag lacks PR#2032 keys); NDK ${NDK_VERSION}/SDK ${ANDROID_API_LEVEL}/Rust ${RUST_VERSION} may be wrong.
  ${notes}"
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
