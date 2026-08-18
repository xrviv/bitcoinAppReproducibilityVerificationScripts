#!/bin/bash
# bitbanana_build.sh v0.6.0 — BitBanana Android reproducible build verification
# Organization: WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-08-18
# Project: https://github.com/michaelWuensch/BitBanana
# Scope: Google Play AAB / split-APK delivery. Builds the app bundle from source,
#        materialises a device-specific APK set with bundletool, and compares it
#        against the official Play split APKs supplied with --binary/--apk.
#        The GitHub/F-Droid universal APK path is a separate variant script.
# Steps: parse args -> read metadata from the official base.apk -> derive a device
#        spec from the supplied splits -> build image (upstream recipe, inlined) ->
#        gradle bundleRelease under disorderfs -> bundletool build-apks ->
#        rename to Play naming -> unzip and diff per split -> decode
#        resources.arsc for any split that differs -> verdict -> YAML.
# No smartphone is required: the device spec is derived from the supplied splits,
# never from `bundletool --connected-device`.
# License: MIT. No warranty. For security research only. Use at your own risk.
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.6.0"
readonly SCRIPT_NAME="bitbanana_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256=""
readonly APP_ID="app.michaelwuensch.bitbanana"
readonly REPO_URL="https://github.com/michaelWuensch/BitBanana"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
# bundletool pin. 1.18.0 is the version used for our published v0.9.8 verification
# (0-reports .../0.9.8/app.michaelwuensch.bitbanana.sh). bundletool decides split
# naming and packaging, so it is a build input and is pinned by hash, not floated.
readonly BUNDLETOOL_VERSION="1.18.0"
readonly BUNDLETOOL_SHA256="78343764d2e79c8f55710378b04981fcb1e46daebfc3b5dc577778082e6a98fd"

VERSION=""
ARCH=""
TYPE=""
BINARY=""
WORK_DIR=""
CONTAINER_RUNTIME=""
IMAGE_NAME=""
OFFICIAL_DIR=""
OFFICIAL_BASE=""
OFFICIAL_APP_HASH=""
APP_ID_FROM_APK=""
APK_VERSION_NAME=""
APK_VERSION_CODE=""
SIGNER_SHA256=""
COMMIT_HASH=""
SPEC_ABIS=""
SPEC_DENSITY=""
SPEC_LOCALES=""
SPEC_SDK=""
DIFF_COUNT=0
MISSING_NOTE=""
ARSC_SUMMARY=""
LOCALE_ALIGN=true
RESULT_DONE=false
RESULT_EXIT_CODE=1
declare -a OFFICIAL_SPLITS=()

sha256_local() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

log_info() { echo "[INFO] $1"; }
log_pass() { echo "[PASS] $1"; }
log_fail() { echo "[FAIL] $1"; }
log_warn() { echo "[WARNING] $1"; }

sanitize_tag() {
    printf '%s' "$1" | tr '/:@ ' '____' | tr -c 'A-Za-z0-9_.-' '_'
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --binary <dir> [--version <version>]
  --binary <path>      Directory holding the official Play split APKs
                       (base.apk plus split_config.*.apk). A path to base.apk
                       itself is accepted; its directory is then used.
                       Alias: --apk. Required — Play splits cannot be downloaded.
  --version <version>  Release version to build (e.g. 1.0.1). Omitted: read from
                       the official base.apk.
  --arch <arch>        Accepted for ABS compatibility; the ABI is taken from the
                       supplied splits, not from this flag.
  --type <type>        Accepted for ABS compatibility; unused.
  --no-locale-align    Turn OFF locale alignment of the bundletool step. By
                       default bundletool runs with
                       -Djava.locale.useOldISOCodes=true, which makes it emit the
                       legacy language codes (iw/in/ji) that Google Play's own
                       server-side split generator emits. The app build itself is
                       never given this property. See the changelog for the
                       measurement this is based on.
  --script-version     Print script version and exit.
  Requires: podman or docker. No smartphone, no adb, no sudo.
  Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid parameters
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

# Utility container helpers. The WS image carries apktool, unzip and a JRE.

ws_run() {
    ${CONTAINER_RUNTIME} run --rm -v "${WORK_DIR}:/work" -w /work "${WS_CONTAINER}" bash -c "$1"
}

# The WS image has no aapt and no aapt2 (checked 2026-08-18: `command -v` found
# neither). All metadata therefore comes from one apktool decode. apksigner IS
# present and is tried first for the certificate; keytool is the fallback, and
# the image has it because apktool needs a JRE.

APKTOOL_MANIFEST=""
APKTOOL_YML=""

decode_official_base() {
    APKTOOL_MANIFEST="${WORK_DIR}/comparison/meta/AndroidManifest.xml"
    APKTOOL_YML="${WORK_DIR}/comparison/meta/apktool.yml"
    if ! ws_run 'set -e
        rm -rf comparison/meta
        apktool d -f -s -o comparison/meta official/base.apk'; then
        log_fail "apktool could not decode base.apk."
        generate_yaml "ftbfs" "apktool failed to decode the supplied base.apk."
        exit 2
    fi
    [[ -f "$APKTOOL_MANIFEST" ]] || { log_fail "apktool produced no AndroidManifest.xml."; exit 2; }
}

# Anchored to the manifest's own package attribute. A greedy match on any
# "name=" is wrong: an aapt badging line ends with compileSdkVersionCodename,
# which such a pattern picks up instead of the package.
manifest_package() {
    grep -o 'package="[^"]*"' "$APKTOOL_MANIFEST" | head -n1 | cut -d'"' -f2
}

# apktool.yml values are sometimes quoted and sometimes not; strip either.
yml_field() {
    local key="$1"
    [[ -f "$APKTOOL_YML" ]] || return 0
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" "$APKTOOL_YML" \
        | head -n1 | tr -d "'\"" | tr -d '\r'
}

apk_signer() {
    local rel="$1" out=""
    out="$(ws_run "apksigner verify --print-certs \"${rel}\" 2>/dev/null | grep -m1 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || true)"
    if [[ -n "$out" ]]; then
        log_info "Signer read with apksigner" >&2
        printf '%s' "$out"
        return 0
    fi
    out="$(ws_run "keytool -printcert -jarfile \"${rel}\" 2>/dev/null | grep -m1 'SHA256:' | awk '{print \$2}' | tr -d ':' | tr 'A-F' 'a-f'" || true)"
    if [[ -n "$out" ]]; then
        log_info "Signer read with keytool" >&2
        printf '%s' "$out"
        return 0
    fi
    log_warn "Neither apksigner nor keytool could read the certificate; signer reported as unknown." >&2
    printf ''
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
            --no-locale-align) LOCALE_ALIGN=false; shift ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) usage ;;
            *) log_warn "Ignoring unknown parameter: $1"; shift ;;
        esac
    done

    if [[ -z "$BINARY" ]]; then
        log_fail "Provide --binary <dir> with the official Play split APKs."
        log_fail "Play splits are device-specific and cannot be downloaded; supply them."
        echo "Run '${SCRIPT_NAME} --help' for usage."
        exit 2
    fi

    # A directory is the documented ABS form for multi-file artifacts. Accept a
    # path to base.apk too and fall back to its directory.
    if [[ -d "$BINARY" ]]; then
        OFFICIAL_DIR="$(readlink -f "$BINARY")"
    elif [[ -f "$BINARY" ]]; then
        OFFICIAL_DIR="$(dirname "$(readlink -f "$BINARY")")"
        log_info "--binary is a file; using its directory: ${OFFICIAL_DIR}"
    else
        log_fail "--binary not found: $BINARY"
        exit 2
    fi

    local v_safe t_safe a_safe s_safe
    v_safe=$(sanitize_tag "${VERSION:-provided}")
    t_safe=$(sanitize_tag "${TYPE:-default}")
    a_safe=$(sanitize_tag "${ARCH:-splits}")
    s_safe=$(sanitize_tag "$SCRIPT_VERSION")

    WORK_DIR="/tmp/test_${APP_ID}_${v_safe}_${a_safe}_${t_safe}"
    IMAGE_NAME="bitbanana-aab-${v_safe}-${a_safe}-${t_safe}-${s_safe}"
    log_info "Work directory: ${WORK_DIR}"
    log_info "Container image tag: ${IMAGE_NAME}"
}

# COMPARISON_RESULTS.yaml — script_version, verdict, notes only.

generate_yaml() {
    local verdict="$1" notes="${2:-}"
    local content="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}"
    # Every line is indented, not just the first: the per-split resources.arsc
    # summary is multi-line, and an unindented continuation line silently breaks
    # the block scalar.
    if [[ -n "$notes" ]]; then
        content="${content}
notes: |
$(printf '%s\n' "$notes" | sed 's/^/  /')"
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
    # Inlined from upstream reproducible-builds/Dockerfile (read at v1.0.1;
    # byte-identical on master at 14a4bb56, checked 2026-08-18). Upstream mounts
    # the working tree from the host; we clone inside the image instead, per WS
    # guidelines. Version strings below are upstream's own and must be re-checked
    # against the tag on every bump. bundletool is added by us — upstream's
    # docs/REPRODUCE_PLAYSTORE.md expects it on the host.
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
ARG BUNDLETOOL_VERSION
ARG BUNDLETOOL_SHA256
RUN set -ex; \
    curl -fSL "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
        -o /opt/bundletool.jar; \
    echo "${BUNDLETOOL_SHA256}  /opt/bundletool.jar" | sha256sum -c -
ARG REPO_URL
ARG VERSION
RUN git clone --depth 1 --branch "v${VERSION}" ${REPO_URL} /app-src \
    || git clone --depth 1 --branch "${VERSION}" ${REPO_URL} /app-src
WORKDIR /app-src
RUN git rev-parse HEAD > /commit.txt
DOCKERFILE_EOF
    log_info "Created Dockerfile (upstream reproducible-builds recipe + pinned bundletool)"
}

# Screen-density bucket names as used in Play split filenames, mapped to the dpi
# integers bundletool expects in a device spec.
density_to_dpi() {
    case "$1" in
        ldpi) echo 120 ;;
        mdpi) echo 160 ;;
        tvdpi) echo 213 ;;
        hdpi) echo 240 ;;
        xhdpi) echo 320 ;;
        xxhdpi) echo 480 ;;
        xxxhdpi) echo 640 ;;
        *) echo "" ;;
    esac
}

# Derive the device spec from the split filenames Play actually delivered.
# This replaces `bundletool --connected-device` from upstream's playbook, which
# ABS rule 3 forbids (no smartphone may be required).
derive_device_spec() {
    log_info "=== DEVICE SPEC ==="
    local abis="" locales="" density="" name suffix dpi

    for f in "${OFFICIAL_SPLITS[@]}"; do
        name="$(basename "$f")"
        [[ "$name" == "base.apk" ]] && continue
        [[ "$name" == split_config.* ]] || continue
        suffix="${name#split_config.}"
        suffix="${suffix%.apk}"

        dpi="$(density_to_dpi "$suffix")"
        if [[ -n "$dpi" ]]; then
            density="$dpi"
            log_info "Density split: ${suffix} -> ${dpi} dpi"
            continue
        fi
        case "$suffix" in
            arm64_v8a|armeabi_v7a|x86_64|x86|mips|mips64)
                # Play writes ABIs with underscores; bundletool wants hyphens,
                # except x86_64 which keeps its underscore.
                local abi="$suffix"
                [[ "$abi" == "arm64_v8a" ]] && abi="arm64-v8a"
                [[ "$abi" == "armeabi_v7a" ]] && abi="armeabi-v7a"
                abis="${abis:+${abis}, }\"${abi}\""
                log_info "ABI split: ${suffix} -> ${abi}"
                ;;
            *)
                # Anything left over of the form xx or xx_YY is a language split.
                locales="${locales:+${locales}, }\"${suffix//_/-}\""
                log_info "Language split: ${suffix}"
                ;;
        esac
    done

    if [[ -z "$abis" ]]; then
        log_fail "No ABI split found among the supplied APKs; cannot derive a device spec."
        generate_yaml "ftbfs" "Supplied splits contain no split_config.<abi>.apk."
        exit 2
    fi
    [[ -z "$density" ]] && { density=480; log_warn "No density split supplied; defaulting to 480 dpi (xxhdpi)."; }
    # Upstream sets bundle { language.enableSplit = false }, so a language split
    # is not expected. en-US keeps the spec valid when none is present.
    [[ -z "$locales" ]] && locales='"en-US"'

    SPEC_ABIS="$abis"
    SPEC_DENSITY="$density"
    SPEC_LOCALES="$locales"
    [[ "${SPEC_SDK}" =~ ^[0-9]+$ ]] || { log_warn "targetSdkVersion unreadable; using 35."; SPEC_SDK=35; }

    cat > "${WORK_DIR}/device-spec.json" << SPEC_EOF
{
  "supportedAbis": [${SPEC_ABIS}],
  "supportedLocales": [${SPEC_LOCALES}],
  "screenDensity": ${SPEC_DENSITY},
  "sdkVersion": ${SPEC_SDK}
}
SPEC_EOF
    log_info "Device spec derived from the supplied splits:"
    cat "${WORK_DIR}/device-spec.json"
}

prepare() {
    log_info "=== PREPARATION PHASE ==="
    mkdir -p "${WORK_DIR}"/{official,built,comparison}
    chmod 777 "${WORK_DIR}" "${WORK_DIR}/built" "${WORK_DIR}/comparison"
    rm -rf "${WORK_DIR}/official"/*.apk "${WORK_DIR}/built"/* "${WORK_DIR}/comparison"/*

    shopt -s nullglob
    local supplied=("${OFFICIAL_DIR}"/*.apk)
    shopt -u nullglob
    if [[ ${#supplied[@]} -eq 0 ]]; then
        log_fail "No .apk files in ${OFFICIAL_DIR}"
        generate_yaml "ftbfs" "No APKs found in the supplied --binary directory."
        exit 2
    fi
    cp "${supplied[@]}" "${WORK_DIR}/official/"

    shopt -s nullglob
    OFFICIAL_SPLITS=("${WORK_DIR}/official"/*.apk)
    shopt -u nullglob
    OFFICIAL_BASE="${WORK_DIR}/official/base.apk"
    if [[ ! -f "$OFFICIAL_BASE" ]]; then
        log_fail "base.apk not found in ${OFFICIAL_DIR}; a Play split set must include it."
        generate_yaml "ftbfs" "Supplied split set has no base.apk."
        exit 2
    fi
    log_info "Official splits supplied: ${#OFFICIAL_SPLITS[@]}"
    local f
    for f in "${OFFICIAL_SPLITS[@]}"; do log_info "  $(basename "$f")"; done

    # appHash is the official artifact exactly as supplied. base.apk carries the
    # manifest and the app identity, so it is the one published as appHash; the
    # per-split hashes are printed alongside it, never in place of it.
    OFFICIAL_APP_HASH="$(sha256_of official/base.apk)"
    log_info "Official base.apk SHA256 (as supplied): ${OFFICIAL_APP_HASH}"

    decode_official_base
    APP_ID_FROM_APK="$(manifest_package)"
    APK_VERSION_NAME="$(yml_field versionName)"
    APK_VERSION_CODE="$(yml_field versionCode)"
    SPEC_SDK="$(yml_field targetSdkVersion)"
    SIGNER_SHA256="$(apk_signer official/base.apk)"

    if [[ -z "$APP_ID_FROM_APK" ]]; then
        log_fail "Could not read the package name from base.apk."
        generate_yaml "ftbfs" "Package name unreadable from the supplied base.apk."
        exit 2
    fi
    log_info "versionName=${APK_VERSION_NAME:-unset} versionCode=${APK_VERSION_CODE:-unset} targetSdk=${SPEC_SDK:-unset}"
    if [[ "$APP_ID_FROM_APK" != "$APP_ID" ]]; then
        log_fail "Wrong APK: package is '${APP_ID_FROM_APK}', expected '${APP_ID}'."
        generate_yaml "ftbfs" "Supplied APK is ${APP_ID_FROM_APK}, not ${APP_ID}."
        exit 2
    fi
    log_pass "Package ID verified: ${APP_ID_FROM_APK}"

    if [[ -z "$VERSION" ]]; then
        VERSION="${APK_VERSION_NAME}"
        [[ -z "$VERSION" ]] && { log_fail "Cannot detect version; pass --version."; exit 2; }
        log_info "Version detected from base.apk: ${VERSION}"
    elif [[ -n "$APK_VERSION_NAME" && "$APK_VERSION_NAME" != "$VERSION" ]]; then
        log_warn "base.apk reports ${APK_VERSION_NAME}, --version says ${VERSION}. Building ${VERSION}."
    fi

    APK_VERSION_NAME="${APK_VERSION_NAME:-$VERSION}"
    APK_VERSION_CODE="${APK_VERSION_CODE:-unknown}"
    SIGNER_SHA256="${SIGNER_SHA256:-unknown}"

    derive_device_spec
    log_pass "Preparation complete"
}

build() {
    log_info "=== BUILD PHASE ==="
    create_dockerfile "${WORK_DIR}/Dockerfile"

    log_info "Building container image (no cache): ${IMAGE_NAME}"
    ${CONTAINER_RUNTIME} build --no-cache \
        --build-arg VERSION="${VERSION}" \
        --build-arg REPO_URL="${REPO_URL}" \
        --build-arg BUNDLETOOL_VERSION="${BUNDLETOOL_VERSION}" \
        --build-arg BUNDLETOOL_SHA256="${BUNDLETOOL_SHA256}" \
        -t "${IMAGE_NAME}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}"

    mkdir -p "${WORK_DIR}/built/splits"
    chmod 777 "${WORK_DIR}/built/splits"

    # Upstream docs/REPRODUCE_PLAYSTORE.md builds through disorderfs with sorted
    # directory entries; that ordering is the reproducibility mechanism, so it is
    # reproduced here rather than building the tree directly. Steps 5 and 7 of
    # that playbook (bundletool, then MakeComparable.py's renaming) are inlined
    # below rather than called, so the whole run stays in one container.
    log_info "Running build in container (disorderfs + gradle bundleRelease + bundletool)"
    # Locale alignment applies to the bundletool step ONLY, never to Gradle.
    # res/xml/splits0.xml is created by bundletool's SplitsXmlInjector at
    # build-apks time and is not present in the AAB at all, so the language code
    # it carries is decided by the split generator, not by the app build. Google
    # Play generates its splits server-side with tooling that emits the legacy
    # codes; bundletool under JDK 17 emits the modern ones unless told otherwise.
    # Measured 2026-08-18: one saved AAB, two bundletool runs differing only in
    # this property, produced `iw` and `he` respectively. Passing it as a plain
    # JVM argument to that one java command keeps `gradle bundleRelease` running
    # exactly as docs/REPRODUCE_PLAYSTORE.md prescribes, with no added flags.
    local -a runtime_env=()
    if [[ "$LOCALE_ALIGN" == "true" ]]; then
        runtime_env+=(-e "BT_LOCALE_OPTS=-Djava.locale.useOldISOCodes=true")
        log_info "Locale alignment ON: bundletool runs with -Djava.locale.useOldISOCodes=true"
    else
        runtime_env+=(-e "BT_LOCALE_OPTS=")
        log_warn "Locale alignment OFF: bundletool may emit he/id/yi where Play emits iw/in/ji"
    fi

    if ! ${CONTAINER_RUNTIME} run --rm \
        --device /dev/fuse --cap-add SYS_ADMIN \
        -v "${WORK_DIR}/built:/out" \
        -v "${WORK_DIR}/device-spec.json:/device-spec.json:ro" \
        "${runtime_env[@]}" \
        "${IMAGE_NAME}" \
        bash -c 'set -euo pipefail
            cp /commit.txt /out/commit.txt
            mkdir -p /app
            disorderfs --sort-dirents=yes --reverse-dirents=no /app-src/ /app/
            cd /app
            gradle clean bundleRelease --no-daemon
            aab="$(find app/build/outputs/bundle/release -name "*.aab" | head -n1)"
            [ -n "$aab" ] || { echo "No AAB produced"; exit 1; }
            echo "AAB: $aab"
            cp "$aab" /out/
            java ${BT_LOCALE_OPTS:-} -jar /opt/bundletool.jar build-apks \
                --bundle="$aab" \
                --output-format=DIRECTORY \
                --output=/tmp/built-apks \
                --device-spec=/device-spec.json
            # MakeComparable.py naming: base-master.apk -> base.apk, and every
            # other base-<x>.apk -> split_config.<x>.apk.
            for f in /tmp/built-apks/splits/*.apk; do
                b="$(basename "$f")"
                case "$b" in
                    base-master.apk) n="base.apk" ;;
                    base-*.apk)      n="split_config.${b#base-}" ;;
                    *)               n="$b" ;;
                esac
                cp "$f" "/out/splits/$n"
            done
            ls -la /out/splits/'; then
        log_fail "Build failed."
        generate_yaml "ftbfs" "gradle bundleRelease or bundletool failed for v${VERSION}."
        exit 1
    fi

    shopt -s nullglob
    local built=("${WORK_DIR}/built/splits"/*.apk)
    shopt -u nullglob
    if [[ ${#built[@]} -eq 0 ]]; then
        log_fail "bundletool produced no split APKs."
        generate_yaml "ftbfs" "No splits materialised from the AAB."
        exit 1
    fi

    if [[ -f "${WORK_DIR}/built/commit.txt" ]]; then
        IFS= read -r COMMIT_HASH < "${WORK_DIR}/built/commit.txt"
    fi
    COMMIT_HASH="${COMMIT_HASH:-unknown}"

    log_pass "Build complete: ${#built[@]} split APKs"
    local f
    for f in "${built[@]}"; do log_info "  $(basename "$f")"; done
}

# resources.arsc evidence, per ws-notes/review-notes/resources.arsc.md and the
# 2026-08-18 precedent survey. A binary arsc difference is not self-explanatory:
# in 18 of 19 recorded cases the decoded res/ trees matched, but Tangem 5.39.1
# proved a real semantic change can hide there — and proved it split by split,
# with one split benign and another genuinely different in the same run. So this
# runs per split and only produces evidence: it never changes DIFF_COUNT or the
# verdict. The human categorises in the report.
assess_split_arsc() {
    local name="$1" tag="$2"
    log_info "${tag}: resources.arsc differs; decoding both APKs to compare resources"
    ws_run "set -e
        rm -rf comparison/arsc_${tag}_official comparison/arsc_${tag}_built
        apktool d -f -s -o comparison/arsc_${tag}_official official/${name} >/dev/null 2>&1
        apktool d -f -s -o comparison/arsc_${tag}_built built/splits/${name} >/dev/null 2>&1
        diff -r comparison/arsc_${tag}_official/res comparison/arsc_${tag}_built/res \
            > comparison/diff_resources_decoded_${tag}.txt 2>&1 || true" || true

    local decoded="${WORK_DIR}/comparison/diff_resources_decoded_${tag}.txt"
    local verdict detail=""
    if [[ ! -f "$decoded" ]]; then
        verdict="decode failed"
        detail="apktool produced no decoded comparison; assess by hand."
        log_warn "${tag}: resources.arsc decode failed"
    elif [[ ! -s "$decoded" ]]; then
        verdict="binary-only"
        detail="decoded res/ trees are identical; the arsc difference carries no resource change."
        log_pass "${tag}: decoded res/ identical — arsc difference is non-semantic"
    else
        local changed residual
        changed=$(grep -cE '^[<>]' "$decoded" 2>/dev/null || true)
        residual=$(grep -E '^[<>]' "$decoded" 2>/dev/null \
            | grep -vc 'com.google.firebase.crashlytics.mapping_file_id' || true)
        changed="${changed:-0}"; residual="${residual:-0}"
        if [[ "$residual" -eq 0 && "$changed" -gt 0 ]]; then
            verdict="crashlytics-only"
            detail="decoded res/ differs only in com.google.firebase.crashlytics.mapping_file_id, an R8 mapping UUID regenerated per build. Accepted class per policy; still counted here."
            log_warn "${tag}: decoded res/ differs only in the Crashlytics mapping id"
        else
            verdict="semantic"
            detail="decoded res/ differs in ${residual} lines beyond any accepted key. This is a real resource difference."
            log_fail "${tag}: decoded res/ differs semantically (${residual} lines)"
        fi
    fi
    ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: ${verdict} — ${detail}
"
}

# Per-split comparison. Leo's rule (2025-10-30): filter root-level META-INF only,
# nothing else. Play's SourceStamp, manifest meta-data and resources.arsc all
# count towards the mechanical verdict; a human categorises them in the report.
compare() {
    log_info "=== COMPARISON PHASE ==="
    local aggregate="${WORK_DIR}/comparison/diff_all.txt"
    : > "$aggregate"
    DIFF_COUNT=0

    local f name built_apk
    for f in "${OFFICIAL_SPLITS[@]}"; do
        name="$(basename "$f")"
        built_apk="${WORK_DIR}/built/splits/${name}"
        local tag="${name%.apk}"
        tag="${tag#split_config.}"

        if [[ ! -f "$built_apk" ]]; then
            log_warn "Split present in official but not built: ${name}"
            MISSING_NOTE="${MISSING_NOTE}Missing in built: ${name}. "
            DIFF_COUNT=$((DIFF_COUNT + 1))
            printf '=== %s ===\n(missing from the built APK set)\n\n' "$tag" >> "$aggregate"
            continue
        fi

        ws_run "set -e
            rm -rf comparison/official-unzipped/${tag} comparison/built-unzipped/${tag}
            mkdir -p comparison/official-unzipped/${tag} comparison/built-unzipped/${tag}
            unzip -qo official/${name} -d comparison/official-unzipped/${tag}
            unzip -qo built/splits/${name} -d comparison/built-unzipped/${tag}
            diff -qr comparison/official-unzipped/${tag} comparison/built-unzipped/${tag} \
                > comparison/diff_${tag}.txt 2>&1 || true"

        local brief="${WORK_DIR}/comparison/diff_${tag}.txt"
        local filtered="${WORK_DIR}/comparison/filtered_${tag}.txt"
        grep -vE '^Only in [^:]+/(official|built)-unzipped/[^/:]+: META-INF$|^Only in [^:]+/(official|built)-unzipped/[^/:]+/META-INF:|^Files [^ ]+/(official|built)-unzipped/[^/]+/META-INF/' \
            "$brief" > "$filtered" 2>/dev/null || true
        sed -i '/^$/d' "$filtered" 2>/dev/null || true

        local cnt
        cnt=$(grep -c '^' "$filtered" 2>/dev/null || true)
        cnt="${cnt:-0}"
        DIFF_COUNT=$((DIFF_COUNT + cnt))

        if [[ "$cnt" -gt 0 ]] && grep -q 'resources\.arsc' "$filtered"; then
            assess_split_arsc "$name" "$tag"
        fi

        printf '=== %s ===\n' "$tag" >> "$aggregate"
        if [[ -s "$brief" ]]; then
            cat "$brief" >> "$aggregate"
        else
            printf '(no differences)\n' >> "$aggregate"
        fi
        printf '\n' >> "$aggregate"

        if [[ "$cnt" -eq 0 ]]; then
            log_pass "${tag}: no differences outside root META-INF/"
        else
            log_warn "${tag}: ${cnt} differences outside root META-INF/"
        fi
    done

    # A split the official set does not have is also a mismatch.
    shopt -s nullglob
    local b
    for b in "${WORK_DIR}/built/splits"/*.apk; do
        name="$(basename "$b")"
        if [[ ! -f "${WORK_DIR}/official/${name}" ]]; then
            log_warn "Split present in built but not official: ${name}"
            MISSING_NOTE="${MISSING_NOTE}Extra in built: ${name}. "
            DIFF_COUNT=$((DIFF_COUNT + 1))
        fi
    done
    shopt -u nullglob

    log_info "Total differences outside root META-INF/: ${DIFF_COUNT}"
}

print_results_block() {
    local verdict="$1"
    local aggregate="${WORK_DIR}/comparison/diff_all.txt"
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID_FROM_APK:-$APP_ID}"
    echo "signer:         ${SIGNER_SHA256}"
    echo "apkVersionName: ${APK_VERSION_NAME}"
    echo "apkVersionCode: ${APK_VERSION_CODE}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${OFFICIAL_APP_HASH:-N/A}"
    echo "commit:         ${COMMIT_HASH}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256}"
    if [[ "$LOCALE_ALIGN" == "true" ]]; then
        echo "splitGenFlags:  -Djava.locale.useOldISOCodes=true (bundletool only; Gradle build unmodified)"
    else
        echo "splitGenFlags:  none (locale alignment disabled)"
    fi
    echo ""
    echo "Official split hashes (as supplied):"
    local f
    for f in "${OFFICIAL_SPLITS[@]}"; do
        echo "  $(basename "$f")  $(sha256_local "$f")"
    done
    echo ""
    echo "Built split hashes:"
    shopt -s nullglob
    for f in "${WORK_DIR}/built/splits"/*.apk; do
        echo "  $(basename "$f")  $(sha256_local "$f")"
    done
    shopt -u nullglob
    echo ""
    echo "Diff:"
    if [[ -s "$aggregate" ]]; then
        cat "$aggregate"
    else
        echo "(no comparison performed)"
    fi
    if [[ -n "$ARSC_SUMMARY" ]]; then
        echo "resources.arsc (decoded, per split):"
        printf '%s' "$ARSC_SUMMARY"
        echo ""
    fi
    echo "Revision, tag (and its signature):"
    echo "Built from tag v${VERSION} at commit ${COMMIT_HASH}."
    echo "No git tag signature check is performed by this script."
    if [[ -n "$MISSING_NOTE" ]]; then
        echo ""
        echo "===== Also ===="
        echo "${MISSING_NOTE}"
    fi
    echo ""
    echo "===== End Results ====="
    echo ""
    echo "Hash legend: appHash is base.apk exactly as supplied and is the value to"
    echo "publish. The per-split hashes above are context and must never be published"
    echo "as appHash. The built splits are unsigned; upstream declares no signingConfig."
    printf 'Run a full\ndiff --recursive %s/comparison/official-unzipped %s/comparison/built-unzipped\nmeld %s/comparison/official-unzipped %s/comparison/built-unzipped\nor\ndiffoscope "%s" "%s"\nfor more details.\n' \
        "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" \
        "${WORK_DIR}/official/base.apk" "${WORK_DIR}/built/splits/base.apk"
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

    local experiment_note=""
    if [[ "$LOCALE_ALIGN" == "true" ]]; then
        experiment_note="Split generation aligned to the distributor: bundletool run with -Djava.locale.useOldISOCodes=true so it emits the same legacy language codes Google Play's server-side generator emits. The Gradle build received no added flags and follows docs/REPRODUCE_PLAYSTORE.md unmodified. "
    else
        experiment_note="Locale alignment disabled via --no-locale-align. "
    fi
    local notes="${experiment_note}Google Play AAB path. Build environment inlined from upstream reproducible-builds/Dockerfile: debian:bookworm-slim, JDK 17, Gradle 8.14, Android SDK 35, build-tools 35.0.0, NDK 27.2.12479018, built through disorderfs with sorted directory entries per docs/REPRODUCE_PLAYSTORE.md. Splits materialised with bundletool ${BUNDLETOOL_VERSION} against a device spec derived from the supplied Play splits, not from a connected device. Only root-level META-INF/ is excluded from the count, per Leo's 2025-10-30 rule; Play SourceStamp (stamp-cert-sha256), the three com.android.stamp/vending manifest meta-data entries and resources.arsc are expected on a Play comparison and are left for a human to categorise in the report. Built splits are unsigned because upstream declares no signingConfig. ${MISSING_NOTE}${ARSC_SUMMARY:+ resources.arsc decoded per split: ${ARSC_SUMMARY}}"
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
    SCRIPT_SHA256="$(sha256_local "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"
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
