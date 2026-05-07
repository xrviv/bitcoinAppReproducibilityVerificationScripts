#!/bin/bash
# ==============================================================================
# blixt_build.sh - Blixt Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.30
# Organization:  WalletScrutiny.com
# Last Modified: 2026-05-07
# Project:       https://github.com/hsjoberg/blixt-wallet
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose. Users assume all risks
# associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws and regulations. The developers assume no liability for any
# misuse or legal consequences arising from use. By using this script, you
# acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# Accepts a zip of official split APKs from Google Play (via --apk/--binary)
# or a version string (via --version). Clones the source at the matching git
# tag, builds an AAB (bundleChainmainnetNormalRelease), uses bundletool to
# reconstruct matching split APKs, and compares each split against the
# official split using raw unzip + diff. Outputs COMPARISON_RESULTS.yaml.
#
# IMPORTANT NOTE on liblnd.so:
# react-native-turbo-lnd is a github SHA dep (not npm 0.0.18). It is cloned
# manually at the exact SHA from package.json, then its src/fetch-lnd.js is run
# from the workspace root to download a pre-built liblnd-android.zip from the
# react-native-turbo-lnd GitHub releases (tag v0.0.20) and extract it to
# android/app/src/main/jniLibs/. This binary is NOT compiled from source.
# Reproducibility of liblnd.so must be verified separately.
#
# TOOLCHAIN (matches .github/workflows/build.yml):
# - Node.js 22.11.0 (exact, via tarball + SHASUMS256.txt)
# - Bun 1.3.11
# - Java 17 (OpenJDK)
# - Android NDK 28.2.13676358
# - Android Build-tools 36.0.0
# - Android Platform 36
# - Build task: bundleChainmainnetNormalRelease (AAB)
# - bundletool 1.17.2 for split APK extraction
# ==============================================================================

set -euo pipefail

EXEC_DIR="$(pwd)"
readonly EXEC_DIR

# ------------------------------------------------------------------------------
# Script metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="v0.2.30"
readonly SCRIPT_NAME="blixt_build.sh"
readonly APP_ID="com.blixtwallet"
readonly REPO_URL="https://github.com/hsjoberg/blixt-wallet.git"
readonly BUILD_IMAGE="blixt_build_env_$$"
readonly BUILD_TASK="bundleChainmainnetNormalRelease"
readonly BUILD_ABI="arm64-v8a"

# Toolchain versions (matches .github/workflows/build.yml)
readonly NODE_VERSION="22.11.0"
readonly BUN_VERSION="1.3.11"
readonly NDK_VERSION="28.2.13676358"
readonly BUNDLETOOL_VERSION="1.17.2"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

# ------------------------------------------------------------------------------
# Global state
# ------------------------------------------------------------------------------
VERSION=""
APK_INPUT=""
ARCH="${BUILD_ABI}"
WORK_DIR=""
CONTAINER_CMD=""
VOLUME_RO=""
VOLUME_RW=""
should_cleanup=false
RESULT_DONE=false
FINAL_EXIT="${EXIT_SUCCESS}"
TOTAL_DIFFS=0
APK_VERSION_CODE=""
APP_HASH=""
SIGNER_CERT="N/A"
BUILD_COMMIT=""
GIT_TAG_SIG_INFO=""
ARCH_SET_BY_USER=false

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info() { echo "[INFO] $*" >&2; }
log_pass() { echo "[PASS] $*" >&2; }
log_fail() { echo "[FAIL] $*" >&2; }
log_warn() { echo "[WARNING] $*" >&2; }

# ------------------------------------------------------------------------------
# YAML output
# ------------------------------------------------------------------------------
write_yaml() {
    local content="$1"
    printf '%s\n' "${content}" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "${content}" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
    fi
}

generate_error_yaml() {
    local verdict="$1"
    local msg="${2:-}"
    write_yaml "script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${msg}"
    RESULT_DONE=true
}

# ------------------------------------------------------------------------------
# Cleanup / error trap
# ------------------------------------------------------------------------------
cleanup() {
    if [[ "${should_cleanup}" == "true" && -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        log_info "Cleaning up ${WORK_DIR}"
        rm -rf "${WORK_DIR}"
    fi
    if [[ -n "${CONTAINER_CMD:-}" && -n "${BUILD_IMAGE:-}" ]]; then
        ${CONTAINER_CMD} rmi "${BUILD_IMAGE}" 2>/dev/null || true
    fi
    if [[ "${RESULT_DONE}" != "true" ]]; then
        generate_error_yaml "ftbfs" "Script exited without producing a result."
    fi
}
trap cleanup EXIT

on_error() {
    local code=$? line=$1
    log_fail "Unexpected error at line ${line} (exit code ${code})"
    generate_error_yaml "ftbfs" "Unexpected error at line ${line} (exit code ${code})."
    exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Usage (defined before container detection so --help works without Docker)
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
NAME
       blixt_build.sh - Blixt Wallet Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --apk <zip_or_apk> [OPTIONS]
       ${SCRIPT_NAME} --version <version> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Accepts a zip of official split APKs (from Google Play via apkextractor)
       or a version string. Builds an AAB from source, uses bundletool to
       reconstruct split APKs, and compares each split against the official.

OPTIONS
       --apk <file>        Zip of split APKs, single split APK, or directory of splits
       --binary <file>     Alias for --apk
       --version <ver>     Version string (used to find the git tag)
       --arch <arch>       Override ABI for device-spec.json (default: arm64-v8a)
       --type <type>       Accepted for build server compatibility (ignored)
       --cleanup           Remove temporary work directory after completion
       --help              Show this help and exit

EXIT CODES
       0  Reproducible
       1  Not reproducible or build failure
       2  Invalid parameters

EXAMPLES
       ${SCRIPT_NAME} --apk ~/Downloads/com.blixtwallet_v0.9.0-splits.zip
       ${SCRIPT_NAME} --version 0.9.0 --apk ~/Downloads/com.blixtwallet_v0.9.0-splits.zip
EOF
}

# Handle --help before container detection (no Docker/Podman needed to print usage)
for _arg in "$@"; do
    if [[ "${_arg}" == "--help" ]]; then
        usage
        RESULT_DONE=true
        exit "${EXIT_SUCCESS}"
    fi
done
unset _arg

# ------------------------------------------------------------------------------
# Container detection
# ------------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    VOLUME_RO=":ro,Z"
    VOLUME_RW=":Z"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    VOLUME_RO=":ro"
    VOLUME_RW=""
else
    log_fail "Neither podman nor docker found. Install one to continue."
    generate_error_yaml "ftbfs" "Neither podman nor docker found."
    exit "${EXIT_FAILED}"
fi

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --apk|--binary) APK_INPUT="${2:-}"; shift ;;
        --version)      VERSION="${2:-}"; shift ;;
        --arch)         ARCH="${2:-}"; ARCH_SET_BY_USER=true; shift ;;
        --type)         shift ;;
        --cleanup)      should_cleanup=true ;;
        --help)         usage; RESULT_DONE=true; exit "${EXIT_SUCCESS}" ;;
        *)              log_warn "Unknown argument: $1 (ignored)" ;;
    esac
    shift
done

if [[ -z "${APK_INPUT}" && -z "${VERSION}" ]]; then
    log_fail "Provide --apk <zip> (official splits) and/or --version <version>."
    usage
    exit "${EXIT_INVALID}"
fi

if [[ "$(id -u)" -eq 0 ]]; then
    log_fail "Do not run this script as root."
    exit "${EXIT_INVALID}"
fi

# ------------------------------------------------------------------------------
# Build toolchain Docker image
# (includes bundletool for split APK extraction from the built AAB)
# ------------------------------------------------------------------------------
build_toolchain_image() {
    log_info "Building toolchain image '${BUILD_IMAGE}' ..."
    log_info "  Node ${NODE_VERSION}, Bun ${BUN_VERSION}, NDK ${NDK_VERSION}, bundletool ${BUNDLETOOL_VERSION}"
    ${CONTAINER_CMD} build --tag "${BUILD_IMAGE}" \
        --build-arg "NODE_VERSION=${NODE_VERSION}" \
        --build-arg "BUN_VERSION=${BUN_VERSION}" \
        --build-arg "BUNDLETOOL_VERSION=${BUNDLETOOL_VERSION}" \
        - <<'DOCKERFILE'
FROM ubuntu:22.04

ARG NODE_VERSION
ARG BUN_VERSION
ARG BUNDLETOOL_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV BUN_INSTALL=/usr/local
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:/usr/local/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    curl \
    git \
    xz-utils \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Android commandlinetools
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools \
    && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
       -o /tmp/cmdtools.zip \
    && unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools_staging \
    && mv /tmp/cmdtools_staging/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && rm -rf /tmp/cmdtools.zip /tmp/cmdtools_staging

# Android SDK: platform-tools, platform-36, build-tools-36, NDK 28
RUN yes | sdkmanager --licenses > /dev/null 2>&1 \
    && sdkmanager \
       "platform-tools" \
       "platforms;android-36" \
       "build-tools;36.0.0" \
       "ndk;28.2.13676358"

# cmake 3.28.6 from cmake.org — Google's SDK repository only ships up to 3.22.1.
# cmake 3.22.1 uses -fuse-ld=gold in its IPO/LTO check, which NDK 28 rejects
# (gold linker removed). Fixed in cmake 3.26+.
RUN curl -fsSL "https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz" \
    -o /tmp/cmake.tar.gz \
    && tar -xzf /tmp/cmake.tar.gz -C /opt \
    && mv /opt/cmake-3.28.6-linux-x86_64 /opt/cmake-3.28.6 \
    && rm /tmp/cmake.tar.gz

ENV PATH="/opt/cmake-3.28.6/bin:${PATH}"

ENV ANDROID_NDK_HOME=${ANDROID_HOME}/ndk/28.2.13676358

# Node.js — exact version via official tarball + checksum
RUN cd /tmp \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
       -o "node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
       | grep "node-v${NODE_VERSION}-linux-x64.tar.xz$" | sha256sum -c - \
    && tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 \
    && rm "node-v${NODE_VERSION}-linux-x64.tar.xz"

# Yarn — required by react-native-turbo-lnd's prepare script
# (github: SHA dependency; its prepare runs: yarn generate-bindings && yarn generate-codegen-specs && bob build)
# GitHub Actions ubuntu-latest has yarn pre-installed; we must match that.
RUN npm install -g yarn

# Bun — exact version
RUN curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION}" \
    && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
    && printf '#!/bin/sh\nexec /usr/local/bin/bunx "$@"\n' > /usr/local/bin/npx \
    && chmod +x /usr/local/bin/npx

# bundletool — for extracting split APKs from the built AAB
RUN curl -fsSL \
    "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
    -o /opt/bundletool.jar

WORKDIR /workspace
DOCKERFILE
    log_info "Toolchain image '${BUILD_IMAGE}' ready."
}

# ------------------------------------------------------------------------------
# Run a command inside the build container with WORK_DIR mounted at /work
# ------------------------------------------------------------------------------
build_exec() {
    ${CONTAINER_CMD} run --rm \
        --volume "${WORK_DIR}:/work${VOLUME_RW}" \
        --workdir /work \
        "${BUILD_IMAGE}" \
        bash -c "$*"
}

# ------------------------------------------------------------------------------
# Stage official splits — handles .zip/.apks, directory, or single .apk.
# Outputs all *.apk files into ${WORK_DIR}/official-splits/
# ------------------------------------------------------------------------------
stage_official_splits() {
    local input="$1"
    local splits_dir="${WORK_DIR}/official-splits"
    mkdir -p "${splits_dir}"

    if [[ -d "${input}" ]]; then
        log_info "Input is a directory — copying split APKs ..."
        find "${input}" -maxdepth 1 -name "*.apk" -exec cp {} "${splits_dir}/" \;

    elif [[ -f "${input}" ]]; then
        case "${input}" in
            *.zip|*.apks)
                log_info "Input is an archive — extracting split APKs ..."
                local extract_dir="${WORK_DIR}/official-splits-raw"
                mkdir -p "${extract_dir}"
                unzip -qq -o "${input}" -d "${extract_dir}"
                find "${extract_dir}" -name "*.apk" -exec cp {} "${splits_dir}/" \;
                ;;
            *.apk)
                log_info "Input is a single APK — staging ..."
                cp "${input}" "${splits_dir}/"
                ;;
            *)
                log_fail "Unsupported input format: ${input}"
                generate_error_yaml "ftbfs" \
                    "Unsupported --apk input. Provide a .zip, .apks, directory, or single .apk."
                exit "${EXIT_FAILED}"
                ;;
        esac
    else
        log_fail "Path not found: ${input}"
        generate_error_yaml "ftbfs" "--apk path not found: ${input}"
        exit "${EXIT_FAILED}"
    fi

    local count
    count="$(find "${splits_dir}" -maxdepth 1 -name "*.apk" | wc -l)"
    if [[ "${count}" -eq 0 ]]; then
        log_fail "No APK files found in input."
        generate_error_yaml "ftbfs" "No APK files found in provided input."
        exit "${EXIT_FAILED}"
    fi
    log_info "Staged ${count} split APK(s) to ${splits_dir}"
}

# ------------------------------------------------------------------------------
# Find base.apk in the staged splits dir (base.apk or base-master.apk)
# ------------------------------------------------------------------------------
find_base_apk() {
    local splits_dir="${WORK_DIR}/official-splits"
    local base
    base="$(find "${splits_dir}" -maxdepth 1 \
        \( -name 'base.apk' -o -name 'base-master.apk' \) | head -1)"
    if [[ -z "${base}" ]]; then
        log_fail "No base.apk or base-master.apk found in staged splits."
        generate_error_yaml "ftbfs" "No base.apk found in official splits."
        exit "${EXIT_FAILED}"
    fi
    echo "${base}"
}

# ------------------------------------------------------------------------------
# Extract version and verify package name from base.apk
# ------------------------------------------------------------------------------
extract_apk_metadata() {
    local apk_path="$1"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"

    log_info "Extracting metadata from ${apk_name} ..."

    # Use BUILD_IMAGE (has aapt at build-tools/36.0.0/aapt) — avoids WS_CONTAINER dependency
    local badging
    badging="$(${CONTAINER_CMD} run --rm \
        --volume "${apk_dir}:/apk_in${VOLUME_RO}" \
        "${BUILD_IMAGE}" \
        sh -c "\${ANDROID_HOME}/build-tools/36.0.0/aapt dump badging /apk_in/${apk_name} 2>/dev/null")"

    local pkg ver ver_code
    pkg="$(echo "${badging}" | grep -oP "^package: name='\\K[^']+" | head -1)"
    ver="$(echo "${badging}" | grep -oP "versionName='\\K[^']+" | head -1)"
    ver_code="$(echo "${badging}" | grep -oP "versionCode='\\K[^']+" | head -1)"

    if [[ "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package mismatch: expected ${APP_ID}, got '${pkg}'"
        generate_error_yaml "ftbfs" \
            "Wrong APK provided. Expected package ${APP_ID}, got ${pkg}."
        exit "${EXIT_FAILED}"
    fi

    log_info "Package: ${pkg}"
    log_info "Version: ${ver} (code: ${ver_code})"
    APK_VERSION_CODE="${ver_code}"

    if [[ -z "${VERSION}" ]]; then
        VERSION="${ver}"
    fi

    # SHA-256 of official base.apk
    APP_HASH="$(sha256sum "${apk_path}" | awk '{print $1}')"
    log_info "appHash: ${APP_HASH}"

    # Signer certificate SHA-256 via apksigner
    local signer_raw
    signer_raw="$(${CONTAINER_CMD} run --rm \
        --volume "${apk_dir}:/apk_in${VOLUME_RO}" \
        "${BUILD_IMAGE}" \
        sh -c "\${ANDROID_HOME}/build-tools/36.0.0/apksigner verify --print-certs /apk_in/${apk_name} 2>/dev/null" 2>/dev/null || true)"
    SIGNER_CERT="$(echo "${signer_raw}" | grep -oP 'SHA-256 digest: \K[0-9a-f]+' | head -1)"
    [[ -z "${SIGNER_CERT}" ]] && SIGNER_CERT="N/A"
    log_info "Signer: ${SIGNER_CERT}"
}

# ------------------------------------------------------------------------------
# Detect device spec parameters from split filenames
# ------------------------------------------------------------------------------
detect_device_spec_params() {
    local splits_dir="${WORK_DIR}/official-splits"
    local detected_density=480
    local detected_locale="en"

    # Density from split filename
    if find "${splits_dir}" -name "split_config.xxxhdpi.apk" | grep -q .; then
        detected_density=640
    elif find "${splits_dir}" -name "split_config.xxhdpi.apk" | grep -q .; then
        detected_density=480
    elif find "${splits_dir}" -name "split_config.xhdpi.apk" | grep -q .; then
        detected_density=320
    elif find "${splits_dir}" -name "split_config.hdpi.apk" | grep -q .; then
        detected_density=240
    fi

    # Locale from split filename (first match)
    local locale_file
    locale_file="$(find "${splits_dir}" -name "split_config.*.apk" \
        ! -name "split_config.arm*" \
        ! -name "split_config.x86*" \
        ! -name "split_config.*dpi.apk" | head -1)"
    if [[ -n "${locale_file}" ]]; then
        local fname
        fname="$(basename "${locale_file}" .apk)"
        detected_locale="${fname#split_config.}"
    fi

    # ABI from split filename — only when user did not explicitly pass --arch
    if [[ "${ARCH_SET_BY_USER}" != "true" ]]; then
        if find "${splits_dir}" -name "split_config.armeabi_v7a.apk" | grep -q .; then
            ARCH="armeabi-v7a"
        elif find "${splits_dir}" -name "split_config.x86_64.apk" | grep -q .; then
            ARCH="x86_64"
        elif find "${splits_dir}" -name "split_config.x86.apk" | grep -q .; then
            ARCH="x86"
        fi
        # arm64-v8a is already the default; no branch needed for it
    fi

    log_info "Detected device spec: ABI=${ARCH}, density=${detected_density}, locale=${detected_locale}"
    echo "${detected_density} ${detected_locale}"
}

# ------------------------------------------------------------------------------
# Create device-spec.json for bundletool
# ------------------------------------------------------------------------------
create_device_spec() {
    local output_path="$1"
    local density="$2"
    local locale="$3"

    cat > "${output_path}" <<EOF
{
  "supportedAbis": ["${ARCH}"],
  "supportedLocales": ["${locale}"],
  "screenDensity": ${density},
  "sdkVersion": 34
}
EOF
    log_info "device-spec.json: ABI=${ARCH}, density=${density}, locale=${locale}, sdkVersion=34"
}

# ------------------------------------------------------------------------------
# Clone and build AAB
# ------------------------------------------------------------------------------
clone_and_build() {
    local version="$1"
    local src_dir="${WORK_DIR}/src"
    local tag="v${version}"

    log_info "Cloning ${REPO_URL} at tag ${tag} ..."
    mkdir -p "${src_dir}"

    ${CONTAINER_CMD} run --rm \
        --volume "${src_dir}:/src${VOLUME_RW}" \
        "${BUILD_IMAGE}" \
        bash -c "
            set -e
            git clone --depth 1 --branch '${tag}' '${REPO_URL}' /src/blixt-wallet
            echo 'Clone complete.'
        "

    BUILD_COMMIT="$(${CONTAINER_CMD} run --rm \
        --volume "${src_dir}/blixt-wallet:/workspace${VOLUME_RO}" \
        "${BUILD_IMAGE}" \
        git -C /workspace rev-parse HEAD 2>/dev/null || echo "unknown")"
    log_info "Build commit: ${BUILD_COMMIT}"

    log_info "Detecting package manager from lockfile ..."

    # Detect lockfile to choose the correct package manager.
    # v0.9.0+ uses bun (bun.lock); v0.8.x and earlier use yarn (yarn.lock).
    # Running bun install against a yarn-lock repo would cause npx autolinking
    # failures at Gradle settings evaluation time.
    local pkg_install_cmd
    if ${CONTAINER_CMD} run --rm \
            --volume "${src_dir}/blixt-wallet:/workspace${VOLUME_RO}" \
            --workdir /workspace \
            "${BUILD_IMAGE}" \
            bash -c "test -f bun.lock || test -f bun.lockb" 2>/dev/null; then
        log_info "  Lockfile: bun.lock — using bun install"
        # --ignore-scripts: react-native-turbo-lnd is a github SHA dep (v0.1.2, unreleased).
        # Its prepare script needs bob + codegen tools that are its own dev deps — bun never
        # installs those before running prepare, so prepare always fails and bun drops the
        # package silently. We clone it manually at the exact SHA instead (see below).
        pkg_install_cmd="timeout 300 bun install --frozen-lockfile --backend=copyfile --ignore-scripts"
    elif ${CONTAINER_CMD} run --rm \
            --volume "${src_dir}/blixt-wallet:/workspace${VOLUME_RO}" \
            --workdir /workspace \
            "${BUILD_IMAGE}" \
            bash -c "test -f yarn.lock" 2>/dev/null; then
        log_info "  Lockfile: yarn.lock — using corepack + yarn install"
        pkg_install_cmd="corepack enable && (yarn install --immutable || YARN_CHECKSUM_BEHAVIOR=update yarn install)"
    else
        log_warn "  No recognized lockfile found — defaulting to bun install"
        pkg_install_cmd="timeout 300 bun install --frozen-lockfile --backend=copyfile --ignore-scripts"
    fi

    log_info "Installing dependencies ..."
    ${CONTAINER_CMD} run --rm \
        --volume "${src_dir}/blixt-wallet:/workspace${VOLUME_RW}" \
        --workdir /workspace \
        --env JAVA_OPTS="-XX:MaxHeapSize=6g" \
        --env GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=2048m" \
        "${BUILD_IMAGE}" \
        bash -c "
            set -eo pipefail
            ${pkg_install_cmd}

            # Manually install react-native-turbo-lnd from the exact github SHA.
            # RN 0.85 Gradle codegen reads TypeScript source directly, so skipping
            # prepare (bob build / generate-codegen-specs) is safe here.
            TURBO_SHA=\$(grep -oP '(?<=react-native-turbo-lnd#)[0-9a-f]+' package.json | head -1)
            echo \"[INFO] Cloning react-native-turbo-lnd at SHA \${TURBO_SHA} ...\"
            git clone --quiet https://github.com/hsjoberg/react-native-turbo-lnd.git \
                /tmp/rntl-src
            git -C /tmp/rntl-src checkout --quiet \"\${TURBO_SHA}\"
            rm -rf node_modules/react-native-turbo-lnd
            cp -a /tmp/rntl-src node_modules/react-native-turbo-lnd

            # Patch turbo-lnd cpp/CMakeLists.txt: remove the explicit -std=c++17 from
            # add_compile_options. CMAKE_CXX_STANDARD is already set to 20 in that file,
            # but add_compile_options(-std=c++17) overrides it because explicit flags beat
            # CMake variables. The RN 0.84+ headers use C++20 'requires' clauses and fail
            # to compile under C++17.
            sed -i 's/add_compile_options(-fexceptions -frtti -std=c++17)/add_compile_options(-fexceptions -frtti)/' \
                node_modules/react-native-turbo-lnd/cpp/CMakeLists.txt
            echo '[INFO] Patched turbo-lnd CMakeLists.txt: removed -std=c++17 from add_compile_options'

            # Download pre-built liblnd.so for all ABIs.
            # fetch-lnd.js in the turbo-lnd package only follows HTTP 302 redirects but
            # GitHub release asset URLs return 301 — so the Node script fails. Use curl
            # with -L (follows all redirects) to download liblnd-android.zip directly.
            echo '[INFO] Downloading liblnd-android.zip ...'
            # 0.0.0 is the smolcars upstream binary (65 MB) and predates the gossipSync /
            # cancelGossipSync / getStatus symbols that blixt-wallet's speedloader-turbomodule
            # requires. The hsjoberg releases (v0.0.2+, ~85 MB) contain those symbols.
            LIBLND_URL=\"https://github.com/hsjoberg/react-native-turbo-lnd/releases/download/v0.0.20/liblnd-android.zip\"
            JNILIBS_DIR=\"android/app/src/main/jniLibs\"
            mkdir -p \"\${JNILIBS_DIR}\"
            curl -fsSL \"\${LIBLND_URL}\" -o liblnd-android.zip
            unzip -o liblnd-android.zip -d \"\${JNILIBS_DIR}\"
            rm -f liblnd-android.zip
            LIBLND_PATH=\"\${JNILIBS_DIR}/${BUILD_ABI}/liblnd.so\"
            if [[ ! -f \"\${LIBLND_PATH}\" ]]; then
                echo \"[FAIL] liblnd.so not found at \${LIBLND_PATH} after download.\"
                exit 1
            fi
            echo \"[PASS] liblnd.so confirmed at \${LIBLND_PATH}\"

            # Preflight: verify key packages are present before Gradle runs.
            for pkg in react-native @react-native-community/cli react-native-turbo-lnd; do
                if [[ ! -f \"node_modules/\${pkg}/package.json\" ]]; then
                    echo \"[FAIL] Preflight: node_modules/\${pkg}/package.json not found after install.\"
                    exit 1
                fi
            done
            echo '[INFO] Preflight OK: react-native, @react-native-community/cli, and react-native-turbo-lnd found.'

            # Generate proto/lightning.js from .proto files.
            # proto/lightning.js is NOT committed at v0.9.0 and the gen-proto script
            # was removed from package.json. Metro fails without it. protobufjs-cli@2.0.0
            # is in devDependencies and is installed by bun, so pbjs/pbts are available.
            echo '[INFO] Generating proto/lightning.js ...'
            find proto -name "*.proto" | sort | xargs node_modules/.bin/pbjs -t static-module -w es6 --force-long -p proto -o proto/lightning.js
            node_modules/.bin/pbts -o proto/lightning.d.ts proto/lightning.js
            echo '[INFO] proto/lightning.js generated.'

            # Override cmake version via local.properties — AGP respects cmake.dir and
            # will use cmake 3.28.0 regardless of what build.gradle specifies.
            # Required because build.gradle may pin cmake 3.22.1, which fails with NDK 28
            # due to the -fuse-ld=gold IPO check (gold linker removed in NDK 28).
            echo "cmake.dir=/opt/cmake-3.28.6" >> android/local.properties

            chmod +x android/gradlew
            cd android
            ./gradlew ${BUILD_TASK} -PreactNativeArchitectures=${BUILD_ABI} --info 2>&1 | tee /workspace/gradle-build.log
            echo 'Gradle build complete.'
        "

    log_info "Build complete."
}

# ------------------------------------------------------------------------------
# Find built AAB
# ------------------------------------------------------------------------------
find_built_aab() {
    local src_dir="${WORK_DIR}/src/blixt-wallet"
    local aab_path

    aab_path="$(find "${src_dir}/android/app/build/outputs/bundle" \
        -name "*.aab" 2>/dev/null | head -1)"

    if [[ -z "${aab_path}" ]]; then
        log_fail "No AAB found after build."
        generate_error_yaml "ftbfs" \
            "Build succeeded but no .aab found in android/app/build/outputs/bundle/."
        exit "${EXIT_FAILED}"
    fi

    log_info "Built AAB: ${aab_path}"
    echo "${aab_path}"
}

# ------------------------------------------------------------------------------
# Extract split APKs from built AAB using bundletool
# ------------------------------------------------------------------------------
extract_splits_from_aab() {
    local aab_path="$1"
    local device_spec_path="$2"
    local output_dir="${WORK_DIR}/built-splits"
    mkdir -p "${output_dir}"

    local aab_rel device_spec_rel
    aab_rel="${aab_path#"${WORK_DIR}/"}"
    device_spec_rel="${device_spec_path#"${WORK_DIR}/"}"

    log_info "Running bundletool to extract built split APKs ..."
    build_exec "
        set -e
        java -jar /opt/bundletool.jar build-apks \
            --bundle='/work/${aab_rel}' \
            --output='/work/built-splits.apks' \
            --device-spec='/work/${device_spec_rel}' \
            --mode=default \
            --overwrite 2>&1
        mkdir -p /work/built-splits
        unzip -qq -o /work/built-splits.apks -d /work/built-splits 2>&1 || true
        chmod -R a+rwX /work/built-splits 2>/dev/null || true
    " >&2

    # Normalize base-master.apk → base.apk
    local splits_subdir="${output_dir}/splits"
    if [[ -f "${splits_subdir}/base-master.apk" ]]; then
        mv "${splits_subdir}/base-master.apk" "${splits_subdir}/base.apk"
        log_info "Renamed base-master.apk -> base.apk"
    fi

    local count
    count="$(find "${output_dir}" -name "*.apk" 2>/dev/null | wc -l)"
    log_info "Extracted ${count} built split APK(s)"

    echo "${splits_subdir}"
}

# ------------------------------------------------------------------------------
# Compare one pair of split APKs (unzip + diff)
# ------------------------------------------------------------------------------
compare_one_split() {
    local official_apk="$1"
    local built_apk="$2"
    local split_label="$3"
    local cmp_dir="${WORK_DIR}/comparison"
    mkdir -p "${cmp_dir}"

    local official_unzip="${cmp_dir}/official_${split_label}"
    local built_unzip="${cmp_dir}/built_${split_label}"
    local diff_file="${cmp_dir}/diff-${split_label}.txt"

    local off_rel built_rel official_out_rel built_out_rel diff_rel
    off_rel="${official_apk#"${WORK_DIR}/"}"
    built_rel="${built_apk#"${WORK_DIR}/"}"
    official_out_rel="${official_unzip#"${WORK_DIR}/"}"
    built_out_rel="${built_unzip#"${WORK_DIR}/"}"
    diff_rel="${diff_file#"${WORK_DIR}/"}"

    build_exec "
        set -e
        mkdir -p /work/${official_out_rel} /work/${built_out_rel}
        unzip -qq /work/${off_rel}   -d /work/${official_out_rel} 2>/dev/null || true
        unzip -qq /work/${built_rel} -d /work/${built_out_rel}    2>/dev/null || true
        diff -r /work/${official_out_rel} /work/${built_out_rel} \
            > /work/${diff_rel} 2>&1 || true
        chmod -R a+rwX /work/${official_out_rel} /work/${built_out_rel} /work/${diff_rel} \
            2>/dev/null || true
    "

    local total_lines=0
    local non_meta_count=0

    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        # Count distinct file differences: Binary files, text diff headers (diff -r),
        # Only-in-one-side, and brief-mode Files lines — excluding META-INF entries.
        # Uses wc -l (always exits 0) to avoid the grep -c exit-1 / || echo 0 double-output crash.
        non_meta_count="$(grep -E '^Only in |^Binary files |^diff -r |^Files ' "${diff_file}" \
            | grep -vE 'META-INF|stamp-cert-sha256' | wc -l)"
    fi

    TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
    log_info "  ${split_label}: ${non_meta_count} non-META-INF diff(s) (${total_lines} lines total)"

    if [[ -s "${diff_file}" ]]; then
        log_info "  First 5 lines (full diff: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
        if [[ "${total_lines}" -gt 5 ]]; then
            log_info "    ... (${total_lines} total lines)"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Compare all official splits against matching built splits
# ------------------------------------------------------------------------------
compare_all_splits() {
    local official_splits_dir="$1"
    local built_splits_dir="$2"

    log_info "Comparing splits ..."

    local any_missing=false
    while IFS= read -r official_apk; do
        local split_name
        split_name="$(basename "${official_apk}" .apk)"

        # Find matching built split
        local built_apk="${built_splits_dir}/${split_name}.apk"

        # Normalise: base-master → base
        if [[ ! -f "${built_apk}" && "${split_name}" == "base" ]]; then
            built_apk="${built_splits_dir}/base-master.apk"
        fi

        # Normalise: Play Store uses split_config.{suffix} naming;
        # bundletool --mode=default produces base-{suffix} naming.
        # Try base-{suffix} as a fallback when split_config.{suffix} is missing.
        if [[ ! -f "${built_apk}" && "${split_name}" == split_config.* ]]; then
            local suffix="${split_name#split_config.}"
            local candidate="${built_splits_dir}/base-${suffix}.apk"
            if [[ -f "${candidate}" ]]; then
                built_apk="${candidate}"
            fi
        fi

        if [[ ! -f "${built_apk}" ]]; then
            log_warn "  No matching built split for: ${split_name}.apk"
            log_info "  Available built splits:"
            find "${built_splits_dir}" -name "*.apk" | while IFS= read -r f; do
                log_info "    $(basename "${f}")"
            done
            any_missing=true
            TOTAL_DIFFS=$(( TOTAL_DIFFS + 1 ))
            continue
        fi

        compare_one_split "${official_apk}" "${built_apk}" "${split_name}"
    done < <(find "${official_splits_dir}" -maxdepth 1 -name "*.apk" | sort)

    if [[ "${any_missing}" == "true" ]]; then
        log_warn "Some official splits had no matching built counterpart."
    fi
}

# ------------------------------------------------------------------------------
# Verify git tag signature
# ------------------------------------------------------------------------------
verify_git_tag_signature() {
    local version="$1"
    local src_dir="${WORK_DIR}/src/blixt-wallet"
    local tag="v${version}"

    log_info "Checking git tag signature for ${tag} ..."

    local tag_type
    tag_type="$(${CONTAINER_CMD} run --rm \
        --volume "${src_dir}:/workspace${VOLUME_RO}" \
        "${BUILD_IMAGE}" \
        bash -c "git -C /workspace cat-file -t 'refs/tags/${tag}' 2>/dev/null || echo unknown")"

    if [[ "${tag_type}" == "tag" ]]; then
        local sig_output
        sig_output="$(${CONTAINER_CMD} run --rm \
            --volume "${src_dir}:/workspace${VOLUME_RO}" \
            "${BUILD_IMAGE}" \
            bash -c "git -C /workspace verify-tag '${tag}' 2>&1 || true")"
        if echo "${sig_output}" | grep -q "Good signature"; then
            GIT_TAG_SIG_INFO="Tag type: annotated
[OK] Good signature on annotated tag ${tag}
${sig_output}"
        else
            GIT_TAG_SIG_INFO="Tag type: annotated
[WARNING] No valid signature found on tag ${tag}
${sig_output}"
        fi
    elif [[ "${tag_type}" == "commit" ]]; then
        GIT_TAG_SIG_INFO="Tag type: lightweight
[INFO] Tag ${tag} is a lightweight tag (cannot contain a GPG signature)"
    else
        GIT_TAG_SIG_INFO="Tag type: unknown
[WARNING] Could not determine tag type for ${tag} (got: ${tag_type})"
    fi
}

# ------------------------------------------------------------------------------
# Print human-readable verification summary (verification-result-summary-format.md)
# ------------------------------------------------------------------------------
print_verification_summary() {
    local verdict_display
    if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
        verdict_display="reproducible"
    else
        verdict_display="differences found"
    fi

    # Aggregate diff output from per-split diff files; strip container-internal path prefix
    local combined_diff=""
    local cmp_dir="${WORK_DIR}/comparison"
    if [[ -d "${cmp_dir}" ]]; then
        while IFS= read -r diff_file; do
            if [[ -s "${diff_file}" ]]; then
                while IFS= read -r line; do
                    combined_diff+="${line//\/work\/comparison\//}"$'\n'
                done < "${diff_file}"
            fi
        done < <(find "${cmp_dir}" -name "diff-*.txt" | sort)
    fi

    echo "===== Begin Results ====="
    printf "appId:          %s\n" "${APP_ID}"
    printf "signer:         %s\n" "${SIGNER_CERT}"
    printf "apkVersionName: %s\n" "${VERSION}"
    printf "apkVersionCode: %s\n" "${APK_VERSION_CODE}"
    printf "verdict:        %s\n" "${verdict_display}"
    printf "appHash:        %s\n" "${APP_HASH}"
    printf "commit:         %s\n" "${BUILD_COMMIT}"
    echo ""
    echo "Diff:"
    if [[ -n "${combined_diff}" ]]; then
        printf '%s' "${combined_diff}"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "${GIT_TAG_SIG_INFO}"
    echo ""
    echo "===== End Results ====="

    if [[ "${should_cleanup}" != "true" ]]; then
        local official_splits="${WORK_DIR}/official-splits"
        local built_splits="${WORK_DIR}/built-splits/splits"
        printf '\nRun a full\ndiff --recursive %s %s\nmeld %s %s\nor\ndiffoscope "%s/base.apk" "%s/base.apk"\nfor more details.\n' \
            "${official_splits}" "${built_splits}" \
            "${official_splits}" "${built_splits}" \
            "${official_splits}" "${built_splits}"
    fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    local ts
    ts="$(date +%Y%m%d_%H%M%S_$$)"
    WORK_DIR="${EXEC_DIR}/blixt_android_${ts}"
    mkdir -p "${WORK_DIR}"
    log_info "Work directory: ${WORK_DIR}"
    log_info "Script version: ${SCRIPT_VERSION}"
    log_info "Container runtime: ${CONTAINER_CMD}"

    # Build toolchain image
    build_toolchain_image

    # Stage official splits
    if [[ -n "${APK_INPUT}" ]]; then
        if [[ ! -e "${APK_INPUT}" ]]; then
            log_fail "Path not found: ${APK_INPUT}"
            exit "${EXIT_INVALID}"
        fi
        stage_official_splits "${APK_INPUT}"
    else
        log_fail "No --apk provided. For --version-only mode, provide --apk with the official splits."
        log_fail "Download from: https://github.com/hsjoberg/blixt-wallet/releases or extract from device."
        generate_error_yaml "ftbfs" \
            "No official APK provided. Use --apk <splits.zip> alongside --version."
        exit "${EXIT_FAILED}"
    fi

    # Find base.apk for metadata
    local base_apk
    base_apk="$(find_base_apk)"

    # Extract version and verify package
    extract_apk_metadata "${base_apk}"

    # Detect device spec from split filenames
    local spec_params
    spec_params="$(detect_device_spec_params)"
    local density locale
    density="$(echo "${spec_params}" | awk '{print $1}')"
    locale="$(echo "${spec_params}" | awk '{print $2}')"

    # Create device-spec.json
    create_device_spec "${WORK_DIR}/device-spec.json" "${density}" "${locale}"

    # Clone and build AAB
    clone_and_build "${VERSION}"

    # Find built AAB
    local built_aab
    built_aab="$(find_built_aab)"

    # Extract split APKs from AAB using bundletool
    local built_splits_dir
    built_splits_dir="$(extract_splits_from_aab "${built_aab}" "${WORK_DIR}/device-spec.json")"

    # Compare all splits
    compare_all_splits "${WORK_DIR}/official-splits" "${built_splits_dir}"

    # Git tag signature check
    verify_git_tag_signature "${VERSION}"

    # Human-readable summary (verification-result-summary-format.md)
    print_verification_summary

    # Verdict + YAML
    if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
        log_pass "All splits are identical (excluding META-INF signing artifacts)."
        write_yaml "script_version: ${SCRIPT_VERSION}
verdict: reproducible
notes: |
  Blixt Wallet v${VERSION} (${APP_ID}) ${ARCH}.
  Built AAB from source tag v${VERSION} (commit ${BUILD_COMMIT}) using Bun ${BUN_VERSION}, Node ${NODE_VERSION}, NDK ${NDK_VERSION}.
  Splits extracted via bundletool ${BUNDLETOOL_VERSION}.
  All splits matched (META-INF excluded from verdict).
  Note: liblnd.so is a pre-built binary downloaded from react-native-turbo-lnd GitHub releases (v0.0.20)."
        RESULT_DONE=true
        FINAL_EXIT="${EXIT_SUCCESS}"
    else
        log_fail "Differences found across splits (${TOTAL_DIFFS} non-META-INF diff(s))."
        write_yaml "script_version: ${SCRIPT_VERSION}
verdict: not_reproducible
notes: |
  Blixt Wallet v${VERSION} (${APP_ID}) ${ARCH}.
  ${TOTAL_DIFFS} non-META-INF diff(s) across splits. See comparison/diff-*.txt for details.
  Note: liblnd.so is a pre-built binary downloaded from react-native-turbo-lnd GitHub releases (v0.0.20)."
        RESULT_DONE=true
        FINAL_EXIT="${EXIT_FAILED}"
    fi

    exit "${FINAL_EXIT}"
}

main "$@"
