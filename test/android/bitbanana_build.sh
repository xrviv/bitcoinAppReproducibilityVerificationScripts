#!/bin/bash
# bitbanana_build.sh v0.1.0 — BitBanana Android reproducible build verification
# Organization: WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-08-14
# Project: https://github.com/michaelWuensch/BitBanana
# Scope: GitHub/F-Droid universal release APK. The Play Store AAB/split path is
#        documented separately upstream (docs/REPRODUCE_PLAYSTORE.md) and is not
#        covered by this script.
# License: MIT. No warranty. For security research only. Use at your own risk.
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.1.0"
readonly SCRIPT_NAME="bitbanana_build.sh"
readonly APP_ID="app.michaelwuensch.bitbanana"
readonly REPO_URL="https://github.com/michaelWuensch/BitBanana"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"

VERSION=""
ARCH=""
TYPE=""
BINARY=""
WORK_DIR=""
CONTAINER_RUNTIME=""
IMAGE_NAME=""
OFFICIAL_APK=""
OFFICIAL_APP_HASH=""
BUILT_APK=""
BUILT_HASH=""
APP_ID_FROM_APK=""
APK_VERSION_NAME=""
APK_VERSION_CODE=""
SIGNER_SHA256=""
COMMIT_HASH=""
DIFF_COUNT=0
ARSC_NOTE=""
RESULT_DONE=false
RESULT_EXIT_CODE=1

log_info() { echo "[INFO] $1"; }
log_pass() { echo "[PASS] $1"; }
log_fail() { echo "[FAIL] $1"; }
log_warn() { echo "[WARNING] $1"; }

sanitize_tag() {
    printf '%s' "$1" | tr '/:@ ' '____' | tr -c 'A-Za-z0-9_.-' '_'
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --version <version> [OPTIONS]
       ${SCRIPT_NAME} --binary <apk> [--version <version>]
  --version <version>  Release version to build (e.g. 1.0.1).
  --binary <path>      Official APK to compare against. Alias: --apk.
                       Omitted: downloaded from the GitHub release for --version.
  --arch <arch>        Accepted for ABS compatibility; the release APK is universal.
  --type <type>        Accepted for ABS compatibility; unused.
  --script-version     Print script version and exit.
  Requires: podman or docker. Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid
EOF
    exit 0
}

show_disclaimer() {
    log_warn "This script is provided as-is. Review before running. Use at your own risk."
}

detect_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    else
        log_fail "Neither podman nor docker found. Install one of them."
        exit 1
    fi
    log_info "Using ${CONTAINER_RUNTIME} as container runtime"
}

require_non_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        log_fail "Do not run this script as root."
        exit 2
    fi
}

# Utility container helpers. The WS image carries aapt/apktool/apksigner/unzip.

ws_run() {
    ${CONTAINER_RUNTIME} run --rm -v "${WORK_DIR}:/work" -w /work "${WS_CONTAINER}" bash -c "$1"
}

apk_badging_field() {
    local rel="$1" field="$2"
    ws_run "aapt dump badging \"${rel}\" 2>/dev/null | sed -n \"s/.*${field}='\\([^']*\\)'.*/\\1/p\" | head -n1" || true
}

apk_signer() {
    local rel="$1"
    ws_run "apksigner verify --print-certs \"${rel}\" 2>/dev/null | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || true
}

sha256_of() {
    local rel="$1"
    ws_run "sha256sum \"${rel}\" | awk '{print \$1}'"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) VERSION="${2:-}"; shift 2 ;;
            --arch)    ARCH="${2:-}";    shift 2 ;;
            --type)    TYPE="${2:-}";    shift 2 ;;
            --binary|--apk) BINARY="${2:-}"; shift 2 ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) usage ;;
            *) log_warn "Ignoring unknown parameter: $1"; shift ;;
        esac
    done

    if [[ -n "$BINARY" && ! -f "$BINARY" ]]; then
        log_fail "--binary not found: $BINARY"
        generate_yaml "ftbfs" "--binary path not found."
        exit 2
    fi

    if [[ -z "$VERSION" && -z "$BINARY" ]]; then
        log_fail "Provide --version <version>, or --binary <apk> to compare a local file."
        echo "Run '${SCRIPT_NAME} --help' for usage."
        exit 2
    fi

    local v_safe t_safe a_safe s_safe
    v_safe=$(sanitize_tag "${VERSION:-provided}")
    t_safe=$(sanitize_tag "${TYPE:-default}")
    a_safe=$(sanitize_tag "${ARCH:-universal}")
    s_safe=$(sanitize_tag "$SCRIPT_VERSION")

    WORK_DIR="/tmp/test_${APP_ID}_${v_safe}_${a_safe}_${t_safe}"
    IMAGE_NAME="bitbanana-build-${v_safe}-${a_safe}-${t_safe}-${s_safe}"
    log_info "Work directory: ${WORK_DIR}"
    log_info "Container image tag: ${IMAGE_NAME}"
}

# COMPARISON_RESULTS.yaml — script_version, verdict, notes only.

generate_yaml() {
    local verdict="$1" notes="${2:-}"
    local content="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}"
    if [[ -n "$notes" ]]; then
        content="${content}
notes: |
  ${notes}"
    fi
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "$content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml"
    fi
}

# Leave nothing the invoking user cannot delete. The build server has no sudo.
normalize_ownership() {
    [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" && -n "${CONTAINER_RUNTIME:-}" ]] || return 0
    if [[ "${CONTAINER_RUNTIME}" == "podman" ]]; then
        podman unshare chown -R 0:0 "${WORK_DIR}" 2>/dev/null \
            || log_warn "Could not normalize ownership under ${WORK_DIR}"
    else
        docker run --rm --user 0:0 -v "${WORK_DIR}:/work" "${WS_CONTAINER}" \
            chown -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 \
            || log_warn "Could not normalize ownership under ${WORK_DIR}"
    fi
    if find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null | grep -q .; then
        log_warn "Files under ${WORK_DIR} are not owned by $(id -un); manual cleanup may need the container runtime."
    fi
}

on_exit() {
    local code=$?
    if [[ $code -ne 0 && "${RESULT_DONE}" != "true" ]]; then
        log_warn "Script failed with exit code: ${code}"
        [[ -n "${WORK_DIR:-}" ]] && log_warn "Work directory preserved: ${WORK_DIR}"
        generate_yaml "ftbfs" "Script aborted before a comparison was produced."
    fi
    normalize_ownership
}
trap on_exit EXIT

create_dockerfile() {
    # Inlined from upstream reproducible-builds/Dockerfile at tag v${VERSION}
    # (read at v1.0.1). Upstream mounts the working tree from the host; we clone
    # inside the image instead, per WS guidelines. Version strings below are
    # upstream's own and must be re-checked against the tag on every bump.
    cat > "$1" << 'DOCKERFILE_EOF'
FROM docker.io/debian:bookworm-slim
RUN set -ex; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes -o APT::Install-Suggests=false --no-install-recommends \
        bzip2 make automake ninja-build g++-multilib libtool binutils-gold \
        bsdmainutils pkg-config python3 patch bison curl unzip git openjdk-17-jdk disorderfs; \
    rm -rf /var/lib/apt/lists/*
ENV ANDROID_SDK_ROOT=/sdk
ENV ANDROID_SDK=/sdk
ENV ANDROID_HOME=/sdk
ENV ANDROID_SDK_URL=https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
ENV ANDROID_BUILD_TOOLS_VERSION=35.0.0
ENV ANDROID_VERSION=35
ENV ANDROID_NDK_VERSION=27.2.12479018
ENV ANDROID_CMAKE_VERSION=3.22.1
ENV ANDROID_NDK_HOME=${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}/
ENV PATH=${PATH}:${ANDROID_HOME}/tools:${ANDROID_HOME}/platform-tools
ENV PATH=${ANDROID_NDK_HOME}:$PATH
ENV PATH=${ANDROID_NDK_HOME}/prebuilt/linux-x86_64/bin/:$PATH
RUN set -ex; \
    mkdir "$ANDROID_HOME" && cd "$ANDROID_HOME" && \
    curl -o sdk.zip $ANDROID_SDK_URL && unzip sdk.zip && rm sdk.zip
RUN yes | ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses >/dev/null
RUN $ANDROID_HOME/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME --update
RUN $ANDROID_HOME/cmdline-tools/bin/sdkmanager --sdk_root=$ANDROID_HOME \
    "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" \
    "platforms;android-${ANDROID_VERSION}" \
    "cmake;$ANDROID_CMAKE_VERSION" \
    "platform-tools" \
    "ndk;$ANDROID_NDK_VERSION"
ENV GRADLE_VERSION=8.14
RUN set -ex; \
    curl -fSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-all.zip" -o /tmp/gradle.zip; \
    unzip -q /tmp/gradle.zip -d /opt; \
    rm /tmp/gradle.zip; \
    ln -s "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle
ARG REPO_URL
ARG VERSION
RUN git clone --depth 1 --branch "v${VERSION}" ${REPO_URL} /app-src \
    || git clone --depth 1 --branch "${VERSION}" ${REPO_URL} /app-src
WORKDIR /app-src
RUN git rev-parse HEAD > /commit.txt
DOCKERFILE_EOF
    log_info "Created Dockerfile (upstream reproducible-builds recipe, clone inside image)"
}

prepare() {
    log_info "=== PREPARATION PHASE ==="
    mkdir -p "${WORK_DIR}"/{official,built,comparison}
    chmod 777 "${WORK_DIR}" "${WORK_DIR}/built" "${WORK_DIR}/comparison"
    rm -f "${WORK_DIR}/built"/*.apk "${WORK_DIR}/comparison"/diff_*.txt

    if [[ -n "$BINARY" ]]; then
        log_info "Using supplied official APK: $(basename "$BINARY")"
        cp "$BINARY" "${WORK_DIR}/official/official.apk"
    else
        local url="${REPO_URL}/releases/download/v${VERSION}/bitbanana-${VERSION}-release.apk"
        log_info "Downloading official APK: ${url}"
        if ! ${CONTAINER_RUNTIME} run --rm -v "${WORK_DIR}/official:/dl" "${WS_CONTAINER}" \
            sh -c "curl -fsSL -o /dl/official.apk '${url}'"; then
            log_fail "Could not download the official APK for v${VERSION}."
            log_fail "Check ${REPO_URL}/releases/tag/v${VERSION}"
            generate_yaml "ftbfs" "Official APK download failed for v${VERSION}."
            exit 1
        fi
    fi
    OFFICIAL_APK="${WORK_DIR}/official/official.apk"

    # appHash is the official artifact exactly as downloaded.
    OFFICIAL_APP_HASH="$(sha256_of official/official.apk)"
    log_info "Official APK SHA256 (as downloaded): ${OFFICIAL_APP_HASH}"

    APP_ID_FROM_APK="$(apk_badging_field official/official.apk name)"
    APK_VERSION_NAME="$(apk_badging_field official/official.apk versionName)"
    APK_VERSION_CODE="$(apk_badging_field official/official.apk versionCode)"
    SIGNER_SHA256="$(apk_signer official/official.apk)"

    if [[ -z "$APP_ID_FROM_APK" ]]; then
        log_fail "Could not read the package name from the official APK."
        generate_yaml "ftbfs" "Package name unreadable from the supplied APK."
        exit 2
    fi
    if [[ "$APP_ID_FROM_APK" != "$APP_ID" ]]; then
        log_fail "Wrong APK: package is '${APP_ID_FROM_APK}', expected '${APP_ID}'."
        generate_yaml "ftbfs" "Supplied APK is ${APP_ID_FROM_APK}, not ${APP_ID}."
        exit 2
    fi
    log_pass "Package ID verified: ${APP_ID_FROM_APK}"

    if [[ -z "$VERSION" ]]; then
        VERSION="${APK_VERSION_NAME}"
        [[ -z "$VERSION" ]] && { log_fail "Cannot detect version; pass --version."; exit 2; }
        log_info "Version detected from APK: ${VERSION}"
    elif [[ -n "$APK_VERSION_NAME" && "$APK_VERSION_NAME" != "$VERSION" ]]; then
        log_warn "Official APK reports ${APK_VERSION_NAME}, --version says ${VERSION}. Building ${VERSION}."
    fi

    APK_VERSION_NAME="${APK_VERSION_NAME:-$VERSION}"
    APK_VERSION_CODE="${APK_VERSION_CODE:-unknown}"
    SIGNER_SHA256="${SIGNER_SHA256:-unknown}"
    log_pass "Preparation complete"
}

build() {
    log_info "=== BUILD PHASE ==="
    create_dockerfile "${WORK_DIR}/Dockerfile"

    log_info "Building container image (no cache): ${IMAGE_NAME}"
    ${CONTAINER_RUNTIME} build --no-cache \
        --build-arg VERSION="${VERSION}" \
        --build-arg REPO_URL="${REPO_URL}" \
        -t "${IMAGE_NAME}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}"

    # Upstream docs/REPRODUCE_GITHUB.md builds through disorderfs with sorted
    # directory entries; that ordering is the reproducibility mechanism, so it is
    # reproduced here rather than building the tree directly.
    log_info "Running build in container (disorderfs + gradle assembleRelease)"
    if ! ${CONTAINER_RUNTIME} run --rm \
        --device /dev/fuse --cap-add SYS_ADMIN \
        -v "${WORK_DIR}/built:/out" \
        "${IMAGE_NAME}" \
        bash -c 'set -euo pipefail
            cp /commit.txt /out/commit.txt
            mkdir -p /app
            disorderfs --sort-dirents=yes --reverse-dirents=no /app-src/ /app/
            cd /app
            gradle clean assembleRelease --no-daemon
            cp app/build/outputs/apk/release/*-release-unsigned.apk /out/ 2>/dev/null \
                || cp app/build/outputs/apk/release/*.apk /out/
            ls -la /out/'; then
        log_fail "Build failed."
        generate_yaml "ftbfs" "gradle assembleRelease failed for v${VERSION}."
        exit 1
    fi

    shopt -s nullglob
    local built=("${WORK_DIR}/built"/*.apk)
    shopt -u nullglob
    if [[ ${#built[@]} -eq 0 ]]; then
        log_fail "No APK produced by the build."
        generate_yaml "ftbfs" "Build produced no APK."
        exit 1
    fi
    BUILT_APK="${built[0]}"
    BUILT_HASH="$(sha256_of "built/$(basename "$BUILT_APK")")"

    if [[ -f "${WORK_DIR}/built/commit.txt" ]]; then
        IFS= read -r COMMIT_HASH < "${WORK_DIR}/built/commit.txt"
    fi
    COMMIT_HASH="${COMMIT_HASH:-unknown}"

    log_pass "Build complete: $(basename "$BUILT_APK")"
    log_info "Built APK SHA256:  ${BUILT_HASH}"
}

# resources.arsc decode-and-assess, per ws-notes/review-notes/resources.arsc.md.
# Decode both APKs and diff the decoded res/ trees. A binary arsc difference is
# only acceptable when the decoded resources agree AND nothing else differs.
assess_resources_arsc() {
    log_info "resources.arsc differs; decoding both APKs to compare resources semantically"
    ws_run 'set -e
        rm -rf comparison/official-decoded comparison/built-decoded
        apktool d -f --no-src --no-debug-info -o comparison/official-decoded official/official.apk >/dev/null 2>&1
        apktool d -f --no-src --no-debug-info -o comparison/built-decoded built/*.apk >/dev/null 2>&1
        diff -r comparison/official-decoded/res comparison/built-decoded/res \
            > comparison/diff_resources_decoded.txt 2>&1 || true' || true

    local decoded="${WORK_DIR}/comparison/diff_resources_decoded.txt"
    if [[ ! -s "$decoded" ]]; then
        ARSC_NOTE="resources.arsc differs in binary form but the decoded res/ trees are identical."
        log_info "${ARSC_NOTE}"
        return 0
    fi

    local residual
    residual=$(grep -E '^[<>]' "$decoded" 2>/dev/null \
        | grep -v 'com.google.firebase.crashlytics.mapping_file_id' | grep -c '^' || true)
    if [[ "${residual:-0}" -eq 0 ]]; then
        ARSC_NOTE="Decoded res/ differs only in the Crashlytics mapping_file_id, an accepted build-time ID."
        log_info "${ARSC_NOTE}"
        return 0
    fi
    ARSC_NOTE="Decoded res/ trees differ in ${residual} lines; the resources.arsc difference is semantic."
    log_warn "${ARSC_NOTE}"
    return 1
}

compare() {
    log_info "=== COMPARISON PHASE ==="
    local built_name
    built_name="$(basename "$BUILT_APK")"

    ws_run "set -e
        rm -rf comparison/official-unzipped comparison/built-unzipped
        mkdir -p comparison/official-unzipped comparison/built-unzipped
        unzip -qo official/official.apk -d comparison/official-unzipped
        unzip -qo \"built/${built_name}\" -d comparison/built-unzipped
        diff -r comparison/official-unzipped comparison/built-unzipped \
            > comparison/diff_apk.txt 2>&1 || true"

    local diff_file="${WORK_DIR}/comparison/diff_apk.txt"

    # Filter only root-level signature material and the Play SourceStamp file.
    # Leo's rule: root META-INF only, never META-INF anywhere in the tree.
    local filtered="${WORK_DIR}/comparison/diff_filtered.txt"
    grep -vE '^Only in [^:]+/(official|built)-unzipped: META-INF$|^Only in [^:]+/(official|built)-unzipped/META-INF:|^Files [^ ]+/(official|built)-unzipped/META-INF/|^Only in [^:]+/(official|built)-unzipped: stamp-cert-sha256$' \
        "$diff_file" > "$filtered" 2>/dev/null || true
    sed -i '/^$/d' "$filtered" 2>/dev/null || true

    DIFF_COUNT=$(grep -c '^' "$filtered" 2>/dev/null || true)
    DIFF_COUNT="${DIFF_COUNT:-0}"

    local arsc_only=false
    if [[ "$DIFF_COUNT" -gt 0 ]] && grep -q 'resources\.arsc' "$filtered"; then
        local non_arsc
        non_arsc=$(grep -vc 'resources\.arsc' "$filtered" 2>/dev/null || true)
        [[ "${non_arsc:-0}" -eq 0 ]] && arsc_only=true
        if assess_resources_arsc; then
            if [[ "$arsc_only" == "true" ]]; then
                log_pass "resources.arsc is the only difference and is non-semantic"
                DIFF_COUNT=0
            else
                log_warn "resources.arsc is non-semantic, but other differences remain"
            fi
        fi
    fi

    log_info "Differences after excluding root META-INF/ and stamp-cert-sha256: ${DIFF_COUNT}"
}

print_results_block() {
    local verdict="$1"
    local filtered="${WORK_DIR}/comparison/diff_filtered.txt"
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
    echo "builtHash:      ${BUILT_HASH:-N/A}   (built APK, unsigned by design)"
    echo ""
    echo "Diff:"
    if [[ -s "$filtered" ]]; then
        local cnt
        cnt=$(grep -c '^' "$filtered" 2>/dev/null || true)
        head -5 "$filtered" || true
        [[ "${cnt:-0}" -gt 5 ]] && \
            echo "... (${cnt} lines; full diff: ${WORK_DIR}/comparison/diff_filtered.txt)"
    else
        echo "(no differences outside root META-INF/ and stamp-cert-sha256)"
    fi
    if [[ -n "$ARSC_NOTE" ]]; then
        echo ""
        echo "resources.arsc: ${ARSC_NOTE}"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Built from tag v${VERSION} at commit ${COMMIT_HASH}."
    echo "No git tag signature check is performed by this script."
    echo ""
    echo "===== End Results ====="
    printf 'Run a full\ndiff --recursive %s/comparison/official-unzipped %s/comparison/built-unzipped\nmeld %s/comparison/official-unzipped %s/comparison/built-unzipped\nor\ndiffoscope "%s" "%s"\nfor more details.\n' \
        "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" \
        "${OFFICIAL_APK}" "${BUILT_APK}"
}

result() {
    log_info "=== RESULTS ==="
    local verdict_label yaml_verdict
    if [[ "${DIFF_COUNT}" -eq 0 ]]; then
        verdict_label="reproducible"
        yaml_verdict="reproducible"
        RESULT_EXIT_CODE=0
        log_pass "VERDICT: REPRODUCIBLE"
    else
        verdict_label="differences found"
        yaml_verdict="not_reproducible"
        RESULT_EXIT_CODE=1
        log_warn "VERDICT: NOT REPRODUCIBLE (${DIFF_COUNT} differences)"
    fi

    local notes="Build environment inlined from upstream reproducible-builds/Dockerfile: debian:bookworm-slim, JDK 17, Gradle 8.14, Android SDK 35, build-tools 35.0.0, NDK 27.2.12479018, built through disorderfs with sorted directory entries per docs/REPRODUCE_GITHUB.md. Universal release APK from the GitHub/F-Droid channel; the Play Store AAB path is not covered. The built APK is unsigned because upstream declares no signingConfig, so root-level META-INF/ and stamp-cert-sha256 are excluded from the comparison. ${ARSC_NOTE}"
    generate_yaml "${yaml_verdict}" "${notes}"
    RESULT_DONE=true
    log_info "Generated COMPARISON_RESULTS.yaml"

    print_results_block "${verdict_label}"

    ${CONTAINER_RUNTIME} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
    log_info "Workspace preserved: ${WORK_DIR}"
    echo "Exit code: ${RESULT_EXIT_CODE}"
}

main() {
    log_info "Starting ${SCRIPT_NAME} script version ${SCRIPT_VERSION}"
    show_disclaimer
    require_non_root
    detect_container_runtime
    parse_arguments "$@"
    prepare
    build
    compare
    result
    trap - EXIT
    normalize_ownership
    exit "${RESULT_EXIT_CODE}"
}
main "$@"
