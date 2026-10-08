#!/bin/bash
# metamask_build.sh v0.2.6 — MetaMask Android reproducible build verification
# Organization: WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-08-14
# Project: https://github.com/MetaMask/metamask-mobile
# License: MIT. No warranty. For security research only. Use at your own risk.
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.2.6"
readonly SCRIPT_NAME="metamask_build.sh"
readonly APP_ID="io.metamask"
readonly REPO_URL="https://github.com/MetaMask/metamask-mobile"
readonly GITHUB_API_BASE="https://api.github.com/repos/MetaMask/metamask-mobile/releases/tags"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"

# Globals
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
AGGREGATED_DIFFS=""
BUILD_MODE=""  # "split" (--binary provided: compare vs Google Play splits)
               # "aab"   (--version only: download official AAB, extract splits, compare)
TARGET_SPLIT_APK=""
RESULT_DONE=false  # set to true by result() after writing the comparison YAML

# Helper Functions

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

    if [[ -f "$commit_file" ]]; then
        IFS= read -r COMMIT_HASH < "$commit_file"
    else
        COMMIT_HASH="unknown"
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
    local tag_verify_output
    tag_verify_output="$(cat "${WORK_DIR}/built-aab/tag_verify.txt" 2>/dev/null || true)"
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID_FROM_APK:-$APP_ID}"
    echo "signer:         ${SIGNER_SHA256}"
    echo "apkVersionName: ${APK_VERSION_NAME}"
    echo "apkVersionCode: ${APK_VERSION_CODE}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${OFFICIAL_APP_HASH:-N/A}"
    echo "commit:         ${COMMIT_HASH}"
    echo ""
    echo "Diff:"
    if [[ -n "${AGGREGATED_DIFFS}" ]]; then
        local cnt
        cnt="$(grep -c '^' <<< "${AGGREGATED_DIFFS}" || true)"
        head -5 <<< "${AGGREGATED_DIFFS}" || true
        [[ "${cnt}" -gt 5 ]] && echo "... (${cnt} lines — full diffs: ${WORK_DIR}/comparison/)"
    else
        echo "(no comparison performed)"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    grep -vE '^TAG_TYPE=|^---COMMIT---' <<< "${tag_verify_output}" || true
    echo ""
    echo "===== End Results ====="
    [[ "${should_cleanup}" != "true" ]] && \
        printf 'Full diffs: diff -r %s/comparison/official_* %s/comparison/built_*\n' \
            "${WORK_DIR}" "${WORK_DIR}"
}

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

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --binary <split_apk_dir_or_file> [OPTIONS]
       ${SCRIPT_NAME} --version <version> --arch <arch> [OPTIONS]
  --binary <path>      Official Google Play split APK dir or single file. Alias: --apk
  --version <version>  Version to build (e.g. 7.69.0). Required without --binary.
  --arch <arch>        Target ABI: arm64-v8a (default), armeabi-v7a, x86_64, x86.
  --type <type>        Accepted for ABS compatibility; unused.
  --script-version     Print script version and exit.
  Requires: podman or docker. Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid
EOF
    exit 0
}

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

    if [[ -z "$APK_DIR" && -z "$VERSION" ]]; then
        log_fail "Provide --binary <path> (Google Play splits dir or single split APK) or --version <version> (auto-download AAB)"
        echo "Run '${SCRIPT_NAME} --help' for usage."
        exit 2
    fi

    if [[ -n "$APK_DIR" ]]; then
        BUILD_MODE="split"
        if [[ -d "$APK_DIR" ]]; then
            APK_INPUT_KIND="dir"
        elif [[ -f "$APK_DIR" ]]; then
            local _m; _m="$(od -An -N2 -tx1 "$APK_DIR" 2>/dev/null | tr -d ' \n')"
            [[ "$_m" == "1f8b" ]] && APK_INPUT_KIND="tar" || { [[ "$APK_DIR" == *.zip ]] && APK_INPUT_KIND="zip" || APK_INPUT_KIND="file"; }
        else
            log_fail "--binary path not found: $APK_DIR"
            generate_comparison_yaml "ftbfs" "--binary path not found: $APK_DIR"
            exit 2
        fi
        log_info "Using official split input as ${APK_INPUT_KIND}: $APK_DIR"
        if [[ -z "$ARCH" ]]; then
            ARCH="arm64-v8a"
            log_info "Using default architecture for built AAB extraction: $ARCH"
        fi
    else
        BUILD_MODE="aab"
        if [[ -z "$ARCH" ]]; then
            log_fail "--arch is required when --binary is not provided (e.g. --arch arm64-v8a)"
            exit 2
        fi
    fi
    case "$ARCH" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            log_fail "Unsupported architecture: $ARCH (supported: arm64-v8a, armeabi-v7a, x86_64, x86)"
            exit 2
            ;;
    esac

    TYPE_SAFE=$(sanitize_tag "${TYPE:-default}")
    ARCH_SAFE=$(sanitize_tag "$ARCH")
    VERSION_SAFE=$(sanitize_tag "${VERSION:-provided}")
    SCRIPT_VERSION_SAFE=$(sanitize_tag "$SCRIPT_VERSION")

    WORK_DIR="/tmp/test_${APP_ID}_${VERSION_SAFE}_${ARCH_SAFE}_${TYPE_SAFE}"
    IMAGE_NAME="metamask-build-${VERSION_SAFE}-${ARCH_SAFE}-${TYPE_SAFE}-${SCRIPT_VERSION_SAFE}"
    log_info "Build mode: $BUILD_MODE"
    log_info "Work directory: $WORK_DIR"
    log_info "Container image tag: $IMAGE_NAME"
}

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_warn "Script failed with exit code: $exit_code"
        log_warn "Work directory preserved for debugging: $WORK_DIR"
        if [[ "${RESULT_DONE:-false}" != "true" ]]; then
            generate_error_yaml "ftbfs" || true
        fi
    fi
}

on_error() {
    local exit_code=$?
    local line_no=$1
    set +e
    log_fail "Script failed at line ${line_no} (exit code ${exit_code})"
    if [[ -n "${WORK_DIR:-}" && "${RESULT_DONE:-false}" != "true" ]]; then
        generate_error_yaml "ftbfs" || true
        if [[ -n "${IMAGE_NAME:-}" ]]; then
            ${CONTAINER_RUNTIME} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
        fi
    fi
    echo "Exit code: 1"
    exit 1
}

trap 'on_error $LINENO' ERR
trap cleanup_on_error EXIT

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

create_dockerfile() {
    local dockerfile_path="$1"
    local version="$2"

    cat > "$dockerfile_path" << 'DOCKERFILE_EOF'
FROM node:24.16.0-bookworm
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/36.0.0"
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
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV JAVA_TOOL_OPTIONS="-Dhttps.protocols=TLSv1.2"
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd ${ANDROID_HOME}/cmdline-tools && \
    wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O cmdline-tools.zip && \
    unzip cmdline-tools.zip && \
    rm cmdline-tools.zip && \
    mv cmdline-tools latest
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
               "platforms;android-36" \
               "build-tools;34.0.0" \
               "build-tools;35.0.0" \
               "build-tools;36.0.0" \
               "ndk;27.1.12297006"
ENV ANDROID_NDK_HOME=${ANDROID_HOME}/ndk/27.1.12297006
RUN mkdir -p ${ANDROID_HOME}/cmake/3.22.1/bin && \
    for tool in cmake ctest cpack; do \
        ln -sf "$(which $tool)" "${ANDROID_HOME}/cmake/3.22.1/bin/$tool"; \
    done && \
    echo "SDK cmake 3.22.1 stub using system cmake:" && \
    ${ANDROID_HOME}/cmake/3.22.1/bin/cmake --version
RUN test -f ${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake || \
    (echo "ERROR: NDK toolchain not found at ${ANDROID_NDK_HOME}" && exit 1)
RUN mkdir -p /usr/local/share/android-sdk && \
    ln -sfn "${ANDROID_NDK_HOME}" /usr/local/share/android-sdk/ndk-bundle
RUN corepack enable && corepack prepare yarn@4.14.1 --activate
RUN useradd -m -s /bin/bash builder
USER builder
WORKDIR /home/builder
ARG REPO_URL
ARG VERSION
RUN git clone --depth 1 --branch "v${VERSION}" ${REPO_URL} metamask-mobile \
    || git clone --depth 1 --branch "${VERSION}" ${REPO_URL} metamask-mobile \
    || git clone --depth 1 ${REPO_URL} metamask-mobile
WORKDIR /home/builder/metamask-mobile
DOCKERFILE_EOF

    log_info "Created Dockerfile for MetaMask build"
}

# Build Script (runs inside container)

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
TAG=""
for tag_fmt in "v\${VERSION}" "\${VERSION}" "release/\${VERSION}"; do
    git rev-parse "\$tag_fmt" >/dev/null 2>&1 && TAG="\$tag_fmt" && break || true
done
if [[ -z "\$TAG" ]]; then
    for tag_fmt in "v\${VERSION}" "\${VERSION}"; do
        git fetch --depth=1 origin "refs/tags/\${tag_fmt}:refs/tags/\${tag_fmt}" 2>/dev/null \
            && git rev-parse "\$tag_fmt" >/dev/null 2>&1 && TAG="\$tag_fmt" && break || true
    done
fi
if [[ -z "\$TAG" ]]; then
    echo "ERROR: Cannot find version \${VERSION} in repository"
    exit 1
fi
echo "Found tag: \$TAG"
git checkout "\$TAG"

COMMIT=\$(git rev-parse HEAD)
echo "Checked out commit: \$COMMIT"

mkdir -p /output
echo "\$COMMIT" > /output/commit.txt

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

echo "=== Environment assertions ==="
ndk_want=\$(sed -n 's/.*ndkVersion = "\([^"]*\)".*/\1/p' android/build.gradle | head -1)
sdk_want=\$(sed -n 's/.*compileSdkVersion = \([0-9]*\).*/\1/p' android/build.gradle | head -1)
bt_want=\$(sed -n 's/.*buildToolsVersion = "\([^"]*\)".*/\1/p' android/build.gradle | head -1)
if [ -z "\$ndk_want" ] || [ -z "\$sdk_want" ] || [ -z "\$bt_want" ]; then
    echo "ERROR: could not parse toolchain requirements from android/build.gradle"
    echo "  ndkVersion='\$ndk_want' compileSdkVersion='\$sdk_want' buildToolsVersion='\$bt_want'"
    exit 1
fi
assert_sdk_component() {
    if [ ! -d "\${ANDROID_HOME}/\$1" ]; then
        echo "ERROR: repo v\${VERSION} requires \$2, not installed in this container."
        echo "  Installed NDK:         \$(ls \${ANDROID_HOME}/ndk 2>/dev/null | tr '\n' ' ')"
        echo "  Installed platforms:   \$(ls \${ANDROID_HOME}/platforms 2>/dev/null | tr '\n' ' ')"
        echo "  Installed build-tools: \$(ls \${ANDROID_HOME}/build-tools 2>/dev/null | tr '\n' ' ')"
        echo "  Update the Dockerfile block in metamask_build.sh and bump the script version."
        exit 1
    fi
}
assert_sdk_component "ndk/\${ndk_want}" "NDK \${ndk_want}"
assert_sdk_component "platforms/android-\${sdk_want}" "compileSdk \${sdk_want}"
assert_sdk_component "build-tools/\${bt_want}" "build-tools \${bt_want}"
echo "Toolchain OK: NDK \${ndk_want}, compileSdk \${sdk_want}, build-tools \${bt_want}"

for env_file in .js.env .android.env; do
    if [[ ! -f "\$env_file" && -f "\${env_file}.example" ]]; then
        cp "\${env_file}.example" "\$env_file"
        echo "Created \$env_file from \${env_file}.example"
    fi
done
export METAMASK_BUILD_TYPE="main"
export METAMASK_ENVIRONMENT="production"
export NODE_OPTIONS="--max-old-space-size=4096"
export METRO_MAX_WORKERS="4"
export CI="true"
export SENTRY_DISABLE_AUTO_UPLOAD=true
export WS_DISABLE_SENTRY_UPLOAD=true
if [[ -f android/gradle.properties.github ]]; then
    cp android/gradle.properties.github android/gradle.properties
fi
if [[ -f android/gradle.properties ]]; then
    if grep -q '^reactNativeArchitectures=' android/gradle.properties; then
        sed -i "s/^reactNativeArchitectures=.*/reactNativeArchitectures=\${OFFICIAL_REACT_NATIVE_ARCHES}/" android/gradle.properties
    else
        printf '%s\n' "reactNativeArchitectures=\${OFFICIAL_REACT_NATIVE_ARCHES}" >> android/gradle.properties
    fi
else
    printf '%s\n' "reactNativeArchitectures=\${OFFICIAL_REACT_NATIVE_ARCHES}" > android/gradle.properties
fi
if [[ -f android/gradle.properties ]]; then
    if ! grep -q "org.gradle.jvmargs" android/gradle.properties; then
        echo "org.gradle.jvmargs=-Xmx4096m -XX:+HeapDumpOnOutOfMemoryError" >> android/gradle.properties
    fi
else
    echo "org.gradle.jvmargs=-Xmx4096m -XX:+HeapDumpOnOutOfMemoryError" > android/gradle.properties
fi
echo "Installing dependencies..."
yarn install --immutable || yarn install
YARN_RUN_LOG=\$(mktemp)
yarn run 2>&1 | tee "\$YARN_RUN_LOG" || true
if grep -q "setup:github-ci" "\$YARN_RUN_LOG"; then
    yarn setup:github-ci || true
fi
rm -f "\$YARN_RUN_LOG"
echo "Runtime: node \$(node -v), yarn \$(yarn -v), RN \$(node -p "require('./node_modules/react-native/package.json').version" 2>/dev/null || echo unknown)"
sentry_gradle="node_modules/@sentry/react-native/sentry.gradle"
if [[ -f "\$sentry_gradle" ]]; then
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

write_local_properties() {
    local target_file="\$1"
    mkdir -p "\$(dirname "\$target_file")"
    {
        printf '%s\n' "sdk.dir=\${ANDROID_HOME}"
        printf '%s\n' "cmake.dir=\${ANDROID_HOME}/cmake/3.22.1"
    } > "\$target_file"
}
if [[ -f .js.env ]]; then
    eval "\$(tr -d '\r' < .js.env)"
fi
if [[ -f .android.env ]]; then
    source .android.env
fi
export METAMASK_BUILD_TYPE="main"
export METAMASK_ENVIRONMENT="production"
echo "Env: MM_FOX_CODE='\${MM_FOX_CODE:-}' MM_BRAZE_SDK_ENDPOINT='\${MM_BRAZE_SDK_ENDPOINT:-}' MM_INFURA_PROJECT_ID='\${MM_INFURA_PROJECT_ID:-}'"
mkdir -p android/app/src/main/assets/fonts
cp -rf app/core/InpageBridgeWeb3.js android/app/src/main/assets/.
cp -rf ./app/fonts/Metamask.ttf ./android/app/src/main/assets/fonts/Metamask.ttf
if [[ -f /build-config/google-services.json ]]; then
    GOOGLE_SERVICES_B64_ANDROID="\$(base64 -w0 -i /build-config/google-services.json)"
    export GOOGLE_SERVICES_B64_ANDROID
fi
if [[ -n "\${GOOGLE_SERVICES_B64_ANDROID:-}" ]]; then
    echo -n "\$GOOGLE_SERVICES_B64_ANDROID" | base64 -d > ./android/app/google-services.json
    chmod 664 ./android/app/google-services.json
    echo "google-services.json has been created successfully."
else
    echo "ERROR: GOOGLE_SERVICES_B64_ANDROID is not set"
    exit 1
fi

write_local_properties android/local.properties
mkdir -p android/keystores
export BITRISEIO_ANDROID_KEYSTORE_PASSWORD="walletscrutiny"
export BITRISEIO_ANDROID_KEYSTORE_ALIAS="walletscrutiny"
export BITRISEIO_ANDROID_KEYSTORE_PRIVATE_KEY_PASSWORD="walletscrutiny"
keytool -genkeypair -v \\
    -keystore android/keystores/release.keystore \\
    -storetype PKCS12 \\
    -storepass "\$BITRISEIO_ANDROID_KEYSTORE_PASSWORD" \\
    -keypass "\$BITRISEIO_ANDROID_KEYSTORE_PRIVATE_KEY_PASSWORD" \\
    -alias "\$BITRISEIO_ANDROID_KEYSTORE_ALIAS" \\
    -keyalg RSA -keysize 2048 -validity 10000 \\
    -dname "CN=WalletScrutiny, OU=Verification, O=WalletScrutiny, C=PH"
echo "Building Android AAB..."
cd android
GRADLE_LOG="/output/gradle-build.log"
set +o pipefail
./gradlew bundleProdRelease \
    --no-daemon \
    --stacktrace \
    -PreactNativeArchitectures="\${OFFICIAL_REACT_NATIVE_ARCHES}" 2>&1 | tee "\${GRADLE_LOG}"
GRADLE_EXIT=\${PIPESTATUS[0]}
set -o pipefail
if [[ "\${GRADLE_EXIT}" -ne 0 ]]; then
    echo "=== BUILD FAILED — last 100 lines of gradle-build.log ==="
    tail -100 "\${GRADLE_LOG}"
    echo "=== ERROR LINES ==="
    grep -n "error:\|FAILED\|CXX[0-9]\|Exception\|BUILD FAILED\|> Task.*FAILED" "\${GRADLE_LOG}" | tail -30 || true
    exit 1
fi

ls -la app/build/outputs/bundle/prodRelease/ || ls -la app/build/outputs/bundle/*/

BUILDSCRIPT_EOF

    chmod +x "$script_path"
    log_info "Created build script"
}

create_device_spec() {
    local spec_path="$1"
    local arch="$2"

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

# APK Comparison

compare_split_apks() {
    local official_dir="$1"
    local built_dir="$2"
    local results_dir="$3"

    log_info "Comparing split APKs..."

    mkdir -p "$results_dir"

    local total_diffs=0
    local total_meta_only=0
    FILES_YAML=""

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
            total_diffs=$((total_diffs + 1))
            continue
        fi

        local official_hash
        local built_hash
        official_hash=$(container_sha256 "$official_apk")
        built_hash=$(container_sha256 "$built_apk")

        log_info "Comparing official $apk_name against built $comparison_name..."
        log_info "  Official: $official_hash"
        log_info "  Built:    $built_hash"

        local official_unzip="$results_dir/official_${comparison_name%.apk}"
        local built_unzip="$results_dir/built_${comparison_name%.apk}"

        unzip_apk_in_container "$official_apk" "$official_unzip"
        unzip_apk_in_container "$built_apk" "$built_unzip"

        local diff_file="$results_dir/diff_${comparison_name%.apk}.txt"
        local official_rel
        local built_rel
        local diff_rel
        official_rel=$(container_relpath "$official_unzip")
        built_rel=$(container_relpath "$built_unzip")
        diff_rel=$(container_relpath "$diff_file")
        container_exec "diff -r \"$official_rel\" \"$built_rel\" 2>&1 | tee \"$diff_rel\" || true"

        local non_meta_diffs=0
        if [[ -s "$diff_file" ]]; then
            non_meta_diffs=$(grep -cvE '^Only in [^:]+/(official|built)_[^:/]+: META-INF$|^Only in [^:]+/(official|built)_[^:/]+/META-INF:|^Files [^ ]+/(official|built)_[^ /]+/META-INF/' \
                "$diff_file" 2>/dev/null || true)
            local blank_lines
            blank_lines=$(grep -c '^$' "$diff_file" 2>/dev/null || true)
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
            total_meta_only=$((total_meta_only + 1))
        else
            log_warn "$comparison_name: $non_meta_diffs non-META-INF differences"
            total_diffs=$((total_diffs + 1))
        fi

        FILES_YAML+="      - filename: $comparison_name\n"
        FILES_YAML+="        hash: $built_hash\n"
        FILES_YAML+="        match: $match\n"
    done

    export TOTAL_DIFFS="$total_diffs"
    export TOTAL_META_ONLY="$total_meta_only"
}

# Generate COMPARISON_RESULTS.yaml

write_yaml_outputs() {
    local yaml_content="$1"

    printf '%s\n' "$yaml_content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" ]]; then
        mkdir -p "${WORK_DIR}" 2>/dev/null || true
        printf '%s\n' "$yaml_content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml"
    fi
}

generate_error_yaml() {
    local status="$1"
    local yaml_content
    yaml_content="script_version: ${SCRIPT_VERSION}
verdict: ${status}"
    write_yaml_outputs "$yaml_content"
}

generate_comparison_yaml() {
    local verdict="$1"
    local notes="$2"
    local yaml_content
    yaml_content="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    write_yaml_outputs "$yaml_content"
    log_info "Generated COMPARISON_RESULTS.yaml"
}

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

prepare() {
    log_info "=== PREPARATION PHASE ==="

    mkdir -p "$WORK_DIR"/{official-split-apks,official-aab,built-split-apks,comparison,build-config,built-aab}
    chmod 777 "$WORK_DIR" "$WORK_DIR/built-aab" "$WORK_DIR/comparison"

    rm -f "$WORK_DIR/built-aab"/*.aab
    rm -f "$WORK_DIR/comparison"/diff_*.txt

    create_google_services_json "$WORK_DIR/build-config/google-services.json"
    create_device_spec "$WORK_DIR/device-spec.json" "$ARCH"

    if [[ "$BUILD_MODE" == "split" ]]; then
        rm -f "$WORK_DIR/official-split-apks"/*.apk
        if [[ "$APK_INPUT_KIND" == "tar" || "$APK_INPUT_KIND" == "zip" ]]; then
            local _xd="$WORK_DIR/archive-extracted"
            rm -rf "$WORK_DIR/archive-extracted"
            mkdir -p "$_xd"
            [[ "$APK_INPUT_KIND" == "tar" ]] \
                && { log_info "Extracting tar: $(basename "$APK_DIR")"; tar -xf "$APK_DIR" -C "$_xd"; } \
                || { log_info "Extracting zip: $(basename "$APK_DIR")"; unzip -q "$APK_DIR" -d "$_xd"; }
            shopt -s nullglob; local _ex=("$_xd"/*.apk); shopt -u nullglob
            [[ ${#_ex[@]} -eq 0 ]] && { log_fail "No APKs in archive"; generate_error_yaml "ftbfs"; exit 1; }
            log_info "${#_ex[@]} APK(s) extracted; copying to official-split-apks/"
            cp "${_ex[@]}" "$WORK_DIR/official-split-apks/"
            OFFICIAL_BASE_APK=$(find_official_base_apk)
            [[ -z "$OFFICIAL_BASE_APK" ]] && { log_fail "No base APK in archive"; exit 2; }
        elif [[ "$APK_INPUT_KIND" == "dir" ]]; then
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

        if [[ -z "$VERSION" ]]; then
            log_info "Auto-detecting version from APK content..."
            VERSION="$(_detect_version_from_apk "$OFFICIAL_BASE_APK")"
            if [[ -z "$VERSION" ]]; then
                local _v="${APK_DIR##*/${APP_ID}_}"; _v="${_v%%_*}"
                [[ "$_v" =~ ^[0-9]+\.[0-9] ]] && VERSION="$_v" && log_info "Version from filename: $VERSION"
            fi
            [[ -z "$VERSION" ]] && { log_fail "Cannot detect version. Pass --version explicitly."; exit 2; }
            log_info "Version auto-detected: $VERSION"
        fi

    else
        download_official_aab
    fi

    log_pass "Preparation complete"
}

build() {
    log_info "=== BUILD PHASE ==="

    create_dockerfile "$WORK_DIR/Dockerfile" "$VERSION"
    create_build_script "$WORK_DIR/build.sh" "$VERSION" "$ARCH"
    log_info "Building container image (no cache): $IMAGE_NAME"
    $CONTAINER_RUNTIME build \
        --no-cache \
        --build-arg VERSION="$VERSION" \
        --build-arg REPO_URL="$REPO_URL" \
        -t "$IMAGE_NAME" \
        -f "$WORK_DIR/Dockerfile" \
        "$WORK_DIR"

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

    log_info "Extracting splits from built AAB..."
    extract_split_apks_from_aab "$BUILT_AAB" "$WORK_DIR/built-split-apks" "$WORK_DIR/device-spec.json"

    if [[ "$BUILD_MODE" == "aab" ]]; then
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
    local yaml_notes="Build environment: node:24.16.0-bookworm, JDK 17, Yarn 4.14.1, Android SDK 36, NDK 27.1.12297006. Architecture: ${ARCH}. Split APK comparison via bundletool. AAB finalized with a disposable PKCS12 key (upstream keystore is a CI secret, not in the public source); built splits are bundletool debug-signed, so signatures differ from the Play-signed official splits by design. ${yaml_scope}"

    generate_comparison_yaml "${yaml_verdict}" "${yaml_notes}"
    RESULT_DONE=true

    print_results_block "${verdict_label}"

    log_info "Removing build image: ${IMAGE_NAME}"
    ${CONTAINER_RUNTIME} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
    log_info "Workspace preserved: ${WORK_DIR}"
    echo "Exit code: ${exit_code}"
    return ${exit_code}
}

# Main Entry Point

main() {
    log_info "Starting ${SCRIPT_NAME} script version ${SCRIPT_VERSION}"

    show_disclaimer
    detect_container_runtime
    parse_arguments "$@"
    prepare
    build
    extract_and_compare

    local rc=0
    result || rc=$?
    if [[ "${RESULT_DONE}" == "true" ]]; then
        trap - ERR
        trap - EXIT
    fi
    exit "${rc}"
}
main "$@"
