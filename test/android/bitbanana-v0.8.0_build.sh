#!/bin/bash
# bitbanana-v0.8.0_build.sh — BitBanana (app.michaelwuensch.bitbanana) Android reproducible build verification
# Version:          v0.8.0
# Organization:     WalletScrutiny.com
# Last modified by: Bob (WalletScrutiny agent)
# Last modified on: 2026-10-05
# Project:          https://github.com/michaelWuensch/BitBanana
# Scope: one script for all four distribution channels; the input kind is read from the APK
#        manifest, never from flags or file names (ABS stores uploads as base.apk or <hash>.bin).
#        - Google Play split set (base.apk + split_config.*.apk): upstream docs/REPRODUCE_PLAYSTORE.md,
#          gradle bundleRelease under disorderfs, bundletool build-apks against a device spec derived
#          from the supplied splits, per-split comparison with evidence-earned exclusions.
#        - GitHub / F-Droid / Obtainium fat APK (one file, all ABIs): upstream docs/REPRODUCE_GITHUB.md,
#          gradle assembleRelease under disorderfs, unsigned output compared with the supplied file.
#        - A lone Play base.apk or config split is refused: the full set is needed.
#        Every tool runs in containers (podman or docker). No smartphone, no adb, no sudo.
# License: MIT. No warranty. For security research only. Use at your own risk.
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.8.0"
readonly SCRIPT_NAME="bitbanana-v0.8.0_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256=""
readonly APP_ID="app.michaelwuensch.bitbanana"
readonly REPO_URL="https://github.com/michaelWuensch/BitBanana"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
# bundletool decides split naming and packaging, so it is a build input: pinned by hash.
readonly BUNDLETOOL_VERSION="1.18.0"
readonly BUNDLETOOL_SHA256="78343764d2e79c8f55710378b04981fcb1e46daebfc3b5dc577778082e6a98fd"

VERSION=""; ARCH=""; TYPE=""; BINARY=""
WORK_DIR=""; IMAGE_NAME=""; CONTAINER_RUNTIME=""
OFFICIAL_DIR=""; OFFICIAL_FILE=""; OFFICIAL_BASE=""; OFFICIAL_NAME=""; OFFICIAL_APP_HASH=""
INPUT_KIND=""
APP_ID_FROM_APK=""; APK_VERSION_NAME=""; APK_VERSION_CODE=""; SIGNER_SHA256=""; COMMIT_HASH=""
SPEC_ABIS=""; SPEC_DENSITY=""; SPEC_LOCALES=""; SPEC_SDK=""
DIFF_COUNT=0; MISSING_NOTE=""; ARSC_SUMMARY=""; ACCEPTED_SUMMARY=""
LOCALE_ALIGN=true
# The only AndroidManifest.xml entries Google Play may add. Anything else, or ANY entry
# present only on the built side, stays counted as a real difference.
readonly PLAY_MANIFEST_KEYS='com\.android\.stamp\.source|com\.android\.stamp\.type|com\.android\.vending\.derived\.apk\.id'
declare -A ARSC_STATE=()
declare -A MF_STATE=()
RESULT_DONE=false
RESULT_EXIT_CODE=1
declare -a OFFICIAL_SPLITS=()
APKTOOL_MANIFEST=""
APKTOOL_YML=""

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
Usage: ${SCRIPT_NAME} --binary <file|dir> [--version <version>]
  --binary <path>      Official artifact. Either a directory holding the Google Play split set
                       (base.apk plus split_config.*.apk; a path to that base.apk is accepted),
                       or one file: the GitHub / F-Droid / Obtainium release APK under any name
                       (base.apk, <hash>.bin). The kind is detected from the APK manifest.
                       Alias: --apk. Required: Play splits cannot be downloaded.
  --version <version>  Release tag to build (e.g. 1.1.0). Omitted: read from the APK.
  --arch, --type       Accepted for ABS compatibility; the ABI set comes from the artifact.
  --no-locale-align    Play split set only: run bundletool WITHOUT -Djava.locale.useOldISOCodes=true.
                       Default ON because Google Play's split generator emits the legacy language
                       codes (iw/in/ji). The app build itself never receives this property.
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

# Utility container: apktool, apksigner, keytool, unzip. No aapt/aapt2 in that image.
ws_run() {
    ${CONTAINER_RUNTIME} run --rm -v "${WORK_DIR}:/work" -w /work "${WS_CONTAINER}" bash -c "$1"
}

# COMPARISON_RESULTS.yaml: script_version, verdict, notes only. Every notes line is
# indented, because the per-split summaries are multi-line block scalars.
generate_yaml() {
    local verdict="$1" notes="${2:-}"
    if [[ -n "$INPUT_KIND" && -n "$notes" ]]; then notes="inputKind: ${INPUT_KIND}. ${notes}"; fi
    local content="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}"
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

# Log, write the ftbfs YAML and leave. $2 = exit code (default 2, invalid input).
fail_ftbfs() {
    log_fail "$1"
    generate_yaml "ftbfs" "$1"
    exit "${2:-2}"
}

decode_official() {
    APKTOOL_MANIFEST="${WORK_DIR}/comparison/meta/AndroidManifest.xml"
    APKTOOL_YML="${WORK_DIR}/comparison/meta/apktool.yml"
    ws_run "set -e; rm -rf comparison/meta; apktool d -f -s -o comparison/meta $1" \
        || fail_ftbfs "apktool could not decode the supplied APK (${OFFICIAL_NAME})."
    [[ -f "$APKTOOL_MANIFEST" ]] || fail_ftbfs "apktool produced no AndroidManifest.xml."
}

# Anchored to the manifest's own package attribute (a greedy name= match picks up other attributes).
manifest_package() {
    grep -o 'package="[^"]*"' "$APKTOOL_MANIFEST" | head -n1 | cut -d'"' -f2
}

yml_field() {
    [[ -f "$APKTOOL_YML" ]] || return 0
    sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$APKTOOL_YML" | head -n1 | tr -d "'\"" | tr -d '\r'
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
    ws_run "sha256sum \"$1\" | awk '{print \$1}'"
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
        log_fail "Provide --binary <file|dir>: the Play split set directory, or the GitHub/F-Droid/Obtainium APK."
        echo "Run '${SCRIPT_NAME} --help' for usage."
        exit 2
    fi
    if [[ -d "$BINARY" ]]; then
        OFFICIAL_DIR="$(readlink -f "$BINARY")"
    elif [[ -f "$BINARY" ]]; then
        OFFICIAL_FILE="$(readlink -f "$BINARY")"
        OFFICIAL_DIR="$(dirname "$OFFICIAL_FILE")"
    else
        log_fail "--binary not found: $BINARY"
        exit 2
    fi

    local v_safe t_safe a_safe s_safe run_id
    v_safe=$(sanitize_tag "${VERSION:-provided}")
    t_safe=$(sanitize_tag "${TYPE:-default}")
    a_safe=$(sanitize_tag "${ARCH:-auto}")
    s_safe=$(sanitize_tag "$SCRIPT_VERSION")
    run_id="$(date +%s)-$$"
    # Per run, in the caller's directory: a fixed /tmp path is shared by every user (ABS included).
    WORK_DIR="$(pwd -P)/bitbanana_verification_${v_safe}_${a_safe}_${t_safe}_${run_id}"
    IMAGE_NAME="bitbanana-${v_safe}-${a_safe}-${t_safe}-${s_safe}-${run_id}"
    log_info "Work directory: ${WORK_DIR}"
    log_info "Container image tag: ${IMAGE_NAME}"
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
    chmod -R u+rwX "${WORK_DIR}" 2>/dev/null || true
    if find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null | grep -q .; then
        log_warn "Files under ${WORK_DIR} are not owned by $(id -un); manual cleanup may need the container runtime."
    fi
}

on_exit() {
    local code=$?
    if [[ $code -ne 0 && "${RESULT_DONE}" != "true" ]]; then
        log_warn "Script failed with exit code: ${code}"
        [[ -n "${WORK_DIR:-}" ]] && log_warn "Work directory preserved: ${WORK_DIR}"
        [[ -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml" ]] || generate_yaml "ftbfs" "Script aborted before a comparison was produced (exit ${code})."
    fi
    normalize_ownership
    if [[ -n "${IMAGE_NAME:-}" && -n "${CONTAINER_RUNTIME:-}" ]]; then ${CONTAINER_RUNTIME} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true; fi
    return 0
}
trap on_exit EXIT

# Upstream reproducible-builds/Dockerfile (identical from v1.0.1 through v1.1.0), plus the clone
# of the tag and the pinned bundletool. Re-check the version strings against the tag on every bump.
create_dockerfile() {
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

# Device spec from the split names Play delivered (replaces `bundletool --connected-device`).
derive_device_spec() {
    log_info "=== DEVICE SPEC ==="
    local abis="" locales="" density="" name suffix dpi

    for f in "${OFFICIAL_SPLITS[@]}"; do
        name="$(basename "$f")"
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
                # Play writes ABIs with underscores; bundletool wants hyphens, except x86_64.
                local abi="$suffix"
                [[ "$abi" == "arm64_v8a" ]] && abi="arm64-v8a"
                [[ "$abi" == "armeabi_v7a" ]] && abi="armeabi-v7a"
                abis="${abis:+${abis}, }\"${abi}\""
                log_info "ABI split: ${suffix} -> ${abi}"
                ;;
            *)
                locales="${locales:+${locales}, }\"${suffix//_/-}\""
                log_info "Language split: ${suffix}"
                ;;
        esac
    done

    [[ -n "$abis" ]] || fail_ftbfs "Supplied splits contain no split_config.<abi>.apk; cannot derive a device spec."
    [[ -z "$density" ]] && { density=480; log_warn "No density split supplied; defaulting to 480 dpi (xxhdpi)."; }
    # Upstream sets bundle { language.enableSplit = false }; en-US keeps the spec valid.
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

# Input kind of a single file, from its decoded manifest. Google Play marks every APK it serves
# (isSplitRequired, com.android.vending.splits, SourceStamp / derived.apk.id meta-data; a config
# split also carries split="config.*"). The Gradle fat APK has none of these markers.
classify_single() {
    if grep -qE ' split="config\.' "$APKTOOL_MANIFEST"; then
        INPUT_KIND="play-config-split-only"
    elif grep -qE "isSplitRequired=\"true\"|com\.android\.vending\.splits|${PLAY_MANIFEST_KEYS}" "$APKTOOL_MANIFEST"; then
        INPUT_KIND="play-base-only"
    else
        INPUT_KIND="fat-apk"
    fi
}

prepare() {
    log_info "=== PREPARATION PHASE ==="
    mkdir "${WORK_DIR}" || fail_ftbfs "Workspace already exists: ${WORK_DIR}"
    mkdir -p "${WORK_DIR}"/{official,built/splits,comparison}
    chmod 777 "${WORK_DIR}" "${WORK_DIR}/built" "${WORK_DIR}/built/splits" "${WORK_DIR}/comparison"

    shopt -s nullglob
    local sib=("${OFFICIAL_DIR}"/split_config.*.apk) supplied=()
    if [[ -n "$OFFICIAL_FILE" && "$(basename "$OFFICIAL_FILE")" == "base.apk" && ${#sib[@]} -gt 0 ]]; then
        log_info "--binary is the base.apk of a split set; using its directory ${OFFICIAL_DIR}"
        OFFICIAL_FILE=""
    fi
    if [[ -n "$OFFICIAL_FILE" ]]; then
        supplied=("$OFFICIAL_FILE")
    else
        supplied=("${OFFICIAL_DIR}"/*.apk "${OFFICIAL_DIR}"/*.bin)
    fi
    shopt -u nullglob
    [[ ${#supplied[@]} -gt 0 ]] || fail_ftbfs "No .apk or .bin file found at ${BINARY}."

    local single=false
    if [[ ${#supplied[@]} -eq 1 ]]; then
        single=true
        OFFICIAL_NAME="$(basename "${supplied[0]}")"
        cp "${supplied[0]}" "${WORK_DIR}/official/app.apk"
        OFFICIAL_BASE="${WORK_DIR}/official/app.apk"
        OFFICIAL_SPLITS=("$OFFICIAL_BASE")
        log_info "One file supplied: ${OFFICIAL_NAME} (working copy official/app.apk)"
    else
        cp "${supplied[@]}" "${WORK_DIR}/official/"
        shopt -s nullglob
        OFFICIAL_SPLITS=("${WORK_DIR}/official"/*.apk)
        shopt -u nullglob
        OFFICIAL_BASE="${WORK_DIR}/official/base.apk"
        OFFICIAL_NAME="base.apk"
        [[ -f "$OFFICIAL_BASE" ]] || fail_ftbfs "Several APKs supplied but no base.apk; a Play split set must include it."
        INPUT_KIND="play-split-set"
        log_info "Official splits supplied: ${#OFFICIAL_SPLITS[@]}"
        local f
        for f in "${OFFICIAL_SPLITS[@]}"; do log_info "  $(basename "$f")"; done
    fi
    local rel
    rel="official/$(basename "$OFFICIAL_BASE")"

    # appHash is the official artifact exactly as supplied: base.apk of a split set, or the one APK.
    OFFICIAL_APP_HASH="$(sha256_of "$rel")"
    log_info "Official ${OFFICIAL_NAME} SHA256 (as supplied): ${OFFICIAL_APP_HASH}"

    decode_official "$rel"
    APP_ID_FROM_APK="$(manifest_package)"
    APK_VERSION_NAME="$(yml_field versionName)"
    APK_VERSION_CODE="$(yml_field versionCode)"
    SPEC_SDK="$(yml_field targetSdkVersion)"
    SIGNER_SHA256="$(apk_signer "$rel")"

    [[ -n "$APP_ID_FROM_APK" ]] || fail_ftbfs "Package name unreadable from the supplied APK."
    log_info "versionName=${APK_VERSION_NAME:-unset} versionCode=${APK_VERSION_CODE:-unset} targetSdk=${SPEC_SDK:-unset}"
    [[ "$APP_ID_FROM_APK" == "$APP_ID" ]] || fail_ftbfs "Wrong APK: package is '${APP_ID_FROM_APK}', expected '${APP_ID}'."
    log_pass "Package ID verified: ${APP_ID_FROM_APK}"

    if [[ "$single" == "true" ]]; then
        classify_single
        if [[ "$INPUT_KIND" != "fat-apk" ]]; then
            log_fail "inputKind: ${INPUT_KIND}"
            fail_ftbfs "The supplied file is one Google Play APK (${INPUT_KIND}), which cannot be verified alone. Upload the full split set: base.apk plus every split_config.*.apk."
        fi
    fi
    log_info "inputKind: ${INPUT_KIND}"

    if [[ -z "$VERSION" ]]; then
        VERSION="${APK_VERSION_NAME}"
        [[ -n "$VERSION" ]] || fail_ftbfs "Cannot detect the version from the APK; pass --version."
        log_info "Version detected from the APK: ${VERSION}"
    elif [[ -n "$APK_VERSION_NAME" && "$APK_VERSION_NAME" != "$VERSION" ]]; then
        log_warn "The APK reports ${APK_VERSION_NAME}, --version says ${VERSION}. Building ${VERSION}."
    fi
    APK_VERSION_NAME="${APK_VERSION_NAME:-$VERSION}"
    APK_VERSION_CODE="${APK_VERSION_CODE:-unknown}"
    SIGNER_SHA256="${SIGNER_SHA256:-unknown}"

    if [[ "$INPUT_KIND" == "play-split-set" ]]; then derive_device_spec; fi
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
        -t "${IMAGE_NAME}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}" \
        || fail_ftbfs "Container image build failed for v${VERSION} (clone of the tag, SDK or bundletool download)." 1

    # Both upstream playbooks build through disorderfs with sorted directory entries; that
    # ordering is the reproducibility mechanism and is reproduced here unchanged.
    local -a run_args=()
    local cmd='set -euo pipefail
cp /commit.txt /out/commit.txt
mkdir -p /app
disorderfs --sort-dirents=yes --reverse-dirents=no /app-src/ /app/
cd /app
'
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        log_info "Running build in container (disorderfs + gradle assembleRelease, per docs/REPRODUCE_GITHUB.md)"
        cmd+='gradle clean assembleRelease --no-daemon
apk="$(find app/build/outputs/apk/release -name "*-release-unsigned.apk" | head -n1)"
[ -n "$apk" ] || { echo "No unsigned release APK produced"; exit 1; }
echo "APK: $apk"
cp "$apk" /out/splits/app.apk
ls -la /out/splits/'
    else
        run_args+=(-v "${WORK_DIR}/device-spec.json:/device-spec.json:ro")
        # Locale alignment applies to the bundletool step ONLY, never to Gradle: res/xml/splits0.xml
        # is written by bundletool at build-apks time, and Play's generator writes iw/in/ji there.
        if [[ "$LOCALE_ALIGN" == "true" ]]; then
            run_args+=(-e "BT_LOCALE_OPTS=-Djava.locale.useOldISOCodes=true")
            log_info "Locale alignment ON: bundletool runs with -Djava.locale.useOldISOCodes=true"
        else
            run_args+=(-e "BT_LOCALE_OPTS=")
            log_warn "Locale alignment OFF: bundletool may emit he/id/yi where Play emits iw/in/ji"
        fi
        log_info "Running build in container (disorderfs + gradle bundleRelease + bundletool, per docs/REPRODUCE_PLAYSTORE.md)"
        cmd+='gradle clean bundleRelease --no-daemon
aab="$(find app/build/outputs/bundle/release -name "*.aab" | head -n1)"
[ -n "$aab" ] || { echo "No AAB produced"; exit 1; }
echo "AAB: $aab"
cp "$aab" /out/
java ${BT_LOCALE_OPTS:-} -jar /opt/bundletool.jar build-apks \
    --bundle="$aab" --output-format=DIRECTORY --output=/tmp/built-apks --device-spec=/device-spec.json
# MakeComparable.py naming: base-master.apk -> base.apk, base-<x>.apk -> split_config.<x>.apk.
for f in /tmp/built-apks/splits/*.apk; do
    b="$(basename "$f")"
    case "$b" in
        base-master.apk) n="base.apk" ;;
        base-*.apk)      n="split_config.${b#base-}" ;;
        *)               n="$b" ;;
    esac
    cp "$f" "/out/splits/$n"
done
ls -la /out/splits/'
    fi

    ${CONTAINER_RUNTIME} run --rm \
        --device /dev/fuse --cap-add SYS_ADMIN \
        -v "${WORK_DIR}/built:/out" \
        ${run_args[@]+"${run_args[@]}"} \
        "${IMAGE_NAME}" bash -c "$cmd" \
        || fail_ftbfs "Build failed for v${VERSION} (${INPUT_KIND})." 1

    shopt -s nullglob
    local built=("${WORK_DIR}/built/splits"/*.apk)
    shopt -u nullglob
    [[ ${#built[@]} -gt 0 ]] || fail_ftbfs "The build produced no APK." 1

    if [[ -f "${WORK_DIR}/built/commit.txt" ]]; then
        IFS= read -r COMMIT_HASH < "${WORK_DIR}/built/commit.txt"
    fi
    COMMIT_HASH="${COMMIT_HASH:-unknown}"

    log_pass "Build complete: ${#built[@]} APK(s)"
    local f
    for f in "${built[@]}"; do log_info "  $(basename "$f")"; done
}

# resources.arsc evidence. A binary arsc difference is not self-explanatory: decoded res/ trees
# usually match, but a real resource change can hide there (and did, per split, for Tangem 5.39.1).
# Runs per APK and only produces evidence: it never changes DIFF_COUNT or the verdict by itself.
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
    ARSC_STATE[$tag]="$verdict"
    ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: ${verdict} — ${detail}
"
}

# Normalise a decoded AndroidManifest.xml: drop the Play-injected meta-data entries and the
# self-closing <application/> form they leave behind. Both sides get identical treatment.
normalise_manifest() {
    sed -E \
        -e "/<meta-data[^>]*android:name=\"(${PLAY_MANIFEST_KEYS})\"/d" \
        -e '/^[[:space:]]*<\/application>[[:space:]]*$/d' \
        -e 's#/>#>#g' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/[[:space:]]+>/>/g' \
        -e 's/^[[:space:]]+//' \
        -e 's/[[:space:]]+$//' \
        "$1"
}

# Is a split's AndroidManifest.xml difference nothing but Play distribution metadata? Fail-closed:
# anything unexpected, any built-only entry, or a failed decode leaves the difference counted.
assess_split_manifest() {
    local name="$1" tag="$2"
    local off="comparison/arsc_${tag}_official" bui="comparison/arsc_${tag}_built"
    if [[ ! -f "${WORK_DIR}/${off}/AndroidManifest.xml" ]]; then
        log_info "${tag}: decoding both APKs to compare manifests"
        ws_run "set -e
            rm -rf ${off} ${bui}
            apktool d -f -s -o ${off} official/${name} >/dev/null 2>&1
            apktool d -f -s -o ${bui} built/splits/${name} >/dev/null 2>&1" || true
    fi
    local o="${WORK_DIR}/${off}/AndroidManifest.xml"
    local b="${WORK_DIR}/${bui}/AndroidManifest.xml"
    if [[ ! -f "$o" || ! -f "$b" ]]; then
        MF_STATE[$tag]="decode failed"
        log_warn "${tag}: manifest decode failed; difference stays counted"
        return 0
    fi
    # Our build must never produce a Play entry; without this guard the normalisation would
    # strip such an entry from both sides and quietly call the difference acceptable.
    if grep -qE "<meta-data[^>]*android:name=\"(${PLAY_MANIFEST_KEYS})\"" "$b"; then
        MF_STATE[$tag]="semantic"
        log_fail "${tag}: the BUILT manifest carries Play distribution metadata; that should never happen"
        return 0
    fi

    local no="${WORK_DIR}/comparison/mf_${tag}_official.norm"
    local nb="${WORK_DIR}/comparison/mf_${tag}_built.norm"
    normalise_manifest "$o" > "$no"
    normalise_manifest "$b" > "$nb"
    if diff -q "$no" "$nb" >/dev/null 2>&1; then
        MF_STATE[$tag]="play-metadata-only"
        log_pass "${tag}: manifest differs only by Play distribution metadata"
    else
        MF_STATE[$tag]="semantic"
        diff "$no" "$nb" > "${WORK_DIR}/comparison/diff_manifest_${tag}.txt" 2>&1 || true
        log_fail "${tag}: manifest differs beyond Play distribution metadata"
    fi
    return 0
}

# Move one class of line from the counted set into the accepted set, recording why.
accept_lines() {
    local counted="$1" pattern="$2" tag="$3" reason="$4"
    local hits
    hits=$(grep -cE "$pattern" "$counted" 2>/dev/null || true)
    [[ "${hits:-0}" -gt 0 ]] || return 0
    grep -vE "$pattern" "$counted" > "${counted}.keep" 2>/dev/null || true
    mv "${counted}.keep" "$counted"
    ACCEPTED_SUMMARY="${ACCEPTED_SUMMARY}  ${tag}: ${hits} x ${reason}
"
    return 0
}

# Per-APK comparison. Only root-level META-INF is filtered up front (Leo's 2025-10-30 rule); on the
# fat APK path only its signature files. Every other exclusion must be earned by decode evidence.
compare() {
    log_info "=== COMPARISON PHASE ==="
    local aggregate="${WORK_DIR}/comparison/diff_all.txt"
    : > "$aggregate"
    DIFF_COUNT=0
    local fat=false metainf
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        fat=true
        metainf='^Only in [^:]+/official-unzipped/[^/:]+/META-INF: (MANIFEST\.MF|[^ /]+\.(SF|RSA|DSA|EC))$'
    else
        metainf='^Only in [^:]+/(official|built)-unzipped/[^/:]+: META-INF$|^Only in [^:]+/(official|built)-unzipped/[^/:]+/META-INF:|^Files [^ ]+/(official|built)-unzipped/[^/]+/META-INF/'
    fi

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
        grep -vE "$metainf" "$brief" > "$filtered" 2>/dev/null || true
        sed -i '/^$/d' "$filtered" 2>/dev/null || true

        # Gather evidence before deciding what may be excluded.
        if grep -q 'resources\.arsc' "$filtered"; then
            assess_split_arsc "$name" "$tag"
        fi
        if [[ "$fat" == "false" ]] && grep -q 'AndroidManifest\.xml' "$filtered"; then
            assess_split_manifest "$name" "$tag"
        fi

        # Each exclusion is earned by evidence from the decode, never granted by file name.
        # Play SourceStamp and Play manifest metadata are only ever accepted on a Play split set.
        local counted="${WORK_DIR}/comparison/counted_${tag}.txt"
        cp "$filtered" "$counted"
        if [[ "$fat" == "false" ]]; then
            accept_lines "$counted" 'stamp-cert-sha256' "$tag" \
                "stamp-cert-sha256 (Play SourceStamp, official only)"
        fi
        if [[ "${ARSC_STATE[$tag]:-}" == "binary-only" ]]; then
            accept_lines "$counted" 'resources\.arsc' "$tag" \
                "resources.arsc (binary only; decoded res/ identical)"
        fi
        if [[ "${MF_STATE[$tag]:-}" == "play-metadata-only" ]]; then
            accept_lines "$counted" 'AndroidManifest\.xml' "$tag" \
                "AndroidManifest.xml (Play distribution metadata only)"
        fi

        local cnt
        cnt=$(grep -c '^' "$counted" 2>/dev/null || true)
        cnt="${cnt:-0}"
        DIFF_COUNT=$((DIFF_COUNT + cnt))

        printf '=== %s ===\n' "$tag" >> "$aggregate"
        if [[ -s "$brief" ]]; then
            cat "$brief" >> "$aggregate"
        else
            printf '(no differences)\n' >> "$aggregate"
        fi
        printf '\n' >> "$aggregate"

        if [[ "$cnt" -eq 0 ]]; then
            log_pass "${tag}: no differences beyond the accepted classes"
        else
            log_warn "${tag}: ${cnt} unaccounted differences"
            head -n 5 "$counted"
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

    log_info "Total unaccounted differences: ${DIFF_COUNT}"
}

print_results_block() {
    local verdict="$1"
    local aggregate="${WORK_DIR}/comparison/diff_all.txt"
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID_FROM_APK:-$APP_ID}"
    echo "inputKind:      ${INPUT_KIND:-unknown}"
    echo "signer:         ${SIGNER_SHA256}"
    echo "apkVersionName: ${APK_VERSION_NAME}"
    echo "apkVersionCode: ${APK_VERSION_CODE}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${OFFICIAL_APP_HASH:-N/A}"
    echo "commit:         ${COMMIT_HASH}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256}"
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        echo "splitGenFlags:  n/a (fat APK: gradle assembleRelease, no bundletool)"
    elif [[ "$LOCALE_ALIGN" == "true" ]]; then
        echo "splitGenFlags:  -Djava.locale.useOldISOCodes=true (bundletool only; Gradle build unmodified)"
    else
        echo "splitGenFlags:  none (locale alignment disabled)"
    fi
    echo ""
    echo "Official APK hashes (as supplied):"
    local f n
    for f in "${OFFICIAL_SPLITS[@]}"; do
        n="$(basename "$f")"; [[ "$n" == "app.apk" ]] && n="${OFFICIAL_NAME} (copied to app.apk)"
        echo "  ${n}  $(sha256_local "$f")"
    done
    echo ""
    echo "Built APK hashes (unsigned):"
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
    if [[ -n "$ACCEPTED_SUMMARY" ]]; then
        echo "Accepted differences (excluded from the verdict, per APK):"
        printf '%s' "$ACCEPTED_SUMMARY"
    fi
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        echo "  root META-INF signature files only (MANIFEST.MF, *.SF, *.RSA/DSA/EC); the built APK is unsigned"
    else
        echo "  all splits: root META-INF/ (signing material; the built splits are unsigned)"
    fi
    echo ""
    if [[ -n "$ARSC_SUMMARY" ]]; then
        echo "resources.arsc (decoded, per APK):"
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
    echo "Hash legend: appHash is the official artifact exactly as supplied (base.apk of a split set, or"
    echo "the single APK) and is the value to publish. Built APKs are unsigned: upstream declares no signingConfig."
    printf 'Run a full\ndiff --recursive %s/comparison/official-unzipped %s/comparison/built-unzipped\nmeld %s/comparison/official-unzipped %s/comparison/built-unzipped\nor\ndiffoscope "%s" "%s"\nfor more details.\n' \
        "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" \
        "${OFFICIAL_BASE}" "${WORK_DIR}/built/splits/$(basename "$OFFICIAL_BASE")"
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

    local env_note="Build environment inlined from upstream reproducible-builds/Dockerfile: debian:bookworm-slim, JDK 17, Gradle 8.14, Android SDK platform 35, build-tools 35.0.0, NDK 27.2.12479018, built through disorderfs with sorted directory entries. "
    local notes
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        notes="GitHub / F-Droid / Obtainium fat APK path per docs/REPRODUCE_GITHUB.md: gradle clean assembleRelease, the unsigned output compared with the supplied file. ${env_note}Excluded from the count: root META-INF signature files only (MANIFEST.MF, *.SF, *.RSA/DSA/EC), and resources.arsc only where the decoded res/ trees are identical. No Google Play metadata is accepted on this path. "
    else
        if [[ "$LOCALE_ALIGN" == "true" ]]; then
            notes="Split generation aligned to the distributor: bundletool run with -Djava.locale.useOldISOCodes=true so it emits the legacy language codes Google Play's server-side generator emits; the Gradle build received no added flags. "
        else
            notes="Locale alignment disabled via --no-locale-align. "
        fi
        notes="${notes}Google Play AAB path per docs/REPRODUCE_PLAYSTORE.md: gradle bundleRelease, splits materialised with bundletool ${BUNDLETOOL_VERSION} against a device spec derived from the supplied Play splits, not from a connected device. ${env_note}Only root-level META-INF/ is excluded up front (Leo's 2025-10-30 rule); Play SourceStamp (stamp-cert-sha256), the three com.android.stamp/vending manifest meta-data entries and resources.arsc are excluded only with decode evidence and listed below for the report. "
    fi
    notes="${notes}Built APKs are unsigned because upstream declares no signingConfig. ${ACCEPTED_SUMMARY:+Accepted differences excluded from the verdict: ${ACCEPTED_SUMMARY}}${MISSING_NOTE}${ARSC_SUMMARY:+ resources.arsc decoded: ${ARSC_SUMMARY}}"
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
