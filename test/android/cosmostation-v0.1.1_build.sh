#!/bin/bash
# cosmostation-v0.1.1_build.sh - Cosmostation (wannabit.io.cosmostaion) Android reproducible build verification
# Version:          v0.1.1
# Organization:     WalletScrutiny.com
# Last modified by: Claude Code (WalletScrutiny forensic agent) for Danny
# Last modified on: 2026-10-13
# Project:          https://github.com/cosmostation/cosmostation-android
# Scope: --binary is one APK (universal build, gradle assembleRelease) or a directory holding a
#        Google Play split set (base.apk + split_config.*.apk: gradle bundleRelease, then bundletool
#        build-apks against a device spec derived from the supplied splits). One verdict per artifact;
#        the overall verdict is the worst one. Every tool runs in a pinned container (podman or
#        docker) as the invoking user. No smartphone, no adb, no sudo.
# Inputs the repo withholds (gitignored): release keystore (a throw-away one is generated, so the
#        signature always differs), local.properties (two BuildConfig keys) and google-services.json.
#        The keys and the Firebase values are read out of the OFFICIAL APK at run time and are never
#        printed. If a key cannot be read, an empty value is used and the notes say so.
# License: MIT. No warranty. For security research only. Use at your own risk.
#
# TECHNICAL DISCLAIMER: provided for technical analysis and reproducible build verification only.
# No warranty is given regarding security, functionality or fitness for any purpose.
# LEGAL DISCLAIMER: for legitimate security research. Users are responsible for complying with all
# applicable laws; by running it you accept full responsibility.
set -euo pipefail
readonly SCRIPT_VERSION="v0.1.1"
readonly SCRIPT_NAME="cosmostation-v0.1.1_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
readonly YAML_PATH="$(dirname "${SCRIPT_PATH}")/COMPARISON_RESULTS.yaml"
SCRIPT_SHA256=""
readonly APP_ID="wannabit.io.cosmostaion"
readonly REPO_URL="https://github.com/cosmostation/cosmostation-android"
# Build inputs, all pinned by hash. The wrapper of the 1.10.52 tag asks for Gradle 8.12.
readonly BASE_IMAGE="docker.io/library/eclipse-temurin@sha256:b468c3fc688b14450571494f588bd939378e7fd542ed5a73f8efc13f17872a87"
readonly CMDLINE_SHA256="2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"
readonly GRADLE_VERSION="8.12"
readonly GRADLE_SHA256="7a00d51fb93147819aab76024feece20b6b84e420694101f276be952e08bef03"
readonly BUNDLETOOL_VERSION="1.18.0"
readonly BUNDLETOOL_SHA256="78343764d2e79c8f55710378b04981fcb1e46daebfc3b5dc577778082e6a98fd"
readonly APKTOOL_VERSION="2.11.1"
readonly APKTOOL_SHA256="56d59c524fc764263ba8d345754d8daf55b1887818b15cd3b594f555d249e2db"
# The only AndroidManifest.xml entries Google Play may add; anything else stays a difference.
readonly PLAY_KEYS='com\.android\.stamp\.source|com\.android\.stamp\.type|com\.android\.vending\.derived\.apk\.id'

VERSION=""; ARCH=""; BINARY=""; LOCALE_ALIGN=true
WORK_DIR=""; IMAGE_NAME=""; RT=""; USER_ARGS=""; RUN_ID=""; CN_PREFIX=""; ROOTLESS=0
OFFICIAL_DIR=""; OFFICIAL_FILE=""; OBASE=""; OFFICIAL_APP_HASH=""; INPUT_KIND=""
APK_VERSION_NAME=""; APK_VERSION_CODE=""; SIGNER_SHA256=""; COMMIT_HASH=""; TARGET_SDK=""
INPUTS_NOTE=""; ACCEPTED_SUMMARY=""; ARSC_SUMMARY=""; MISSING_NOTE=""; DIFF_COUNT=0
RESULT_DONE=false; RESULT_EXIT_CODE=1
declare -a OFFICIAL_SPLITS=() ART_TAG=() ART_CNT=() ART_TOP=()
declare -A ARSC_STATE=() MF_STATE=()

sha256_local() { [[ -f "$1" ]] || { echo "N/A"; return 0; }; sha256sum "$1" | awk '{print $1}'; }
log_info() { echo "[INFO] $1"; }
log_pass() { echo "[PASS] $1"; }
log_fail() { echo "[FAIL] $1"; }
log_warn() { echo "[WARNING] $1"; }

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --binary <apk|dir> [--version <version>]
  --binary <path>      Official artifact: one APK (any file name), or a directory holding the Google
                       Play split set (base.apk + split_config.*.apk). Alias: --apk.
  --version <version>  Release to build (e.g. 1.10.52). Optional: read from the APK; exit 2 if the
                       APK says otherwise.
  --arch, --type       Accepted for ABS compatibility. With a split set, --arch must match its ABI split.
  --no-locale-align    Split set only: run bundletool without -Djava.locale.useOldISOCodes=true
                       (Play emits the legacy language codes iw/in/ji).
  --script-version     Print the script version and exit.
Requires podman or docker. Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid parameters
EOF
}

# COMPARISON_RESULTS.yaml: script_version, verdict, notes only. Written next to the script.
generate_yaml() {
    local verdict="$1" notes="${2:-}" content
    content="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}"
    if [[ -n "$notes" ]]; then content="${content}
notes: |
$(printf '%s\n' "$notes" | sed 's/^/  /')"; fi
    printf '%s\n' "$content" > "${YAML_PATH}" || log_warn "Cannot write ${YAML_PATH}"
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then printf '%s\n' "$content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml"; fi
}

fail_ftbfs() { log_fail "$1"; generate_yaml "ftbfs" "$1"; RESULT_DONE=true; exit "${2:-2}"; }

# Leave nothing the invoking user cannot delete. The build server has no sudo.
normalize_ownership() {
    [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${RT}" ]] || return 0
    if [[ "${RT}" == "podman" ]]; then
        podman unshare chown -R 0:0 "${WORK_DIR}" >/dev/null 2>&1 || true
    else
        # Rootless docker: container root IS the caller, so 0:0; rootful: the caller's uid:gid.
        local own="$(id -u):$(id -g)"; [[ "${ROOTLESS}" -eq 1 ]] && own="0:0"
        docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1 && docker run --rm --user 0:0 -v "${WORK_DIR}:/work" "${IMAGE_NAME}" chown -R "${own}" /work >/dev/null 2>&1 || true
    fi
    chmod -R u+rwX "${WORK_DIR}" 2>/dev/null || true
    if find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null | grep -q .; then
        log_warn "Some files under ${WORK_DIR} are not owned by $(id -un)."
    fi
}

on_exit() {
    local code=$?
    if [[ $code -ne 0 && "${RESULT_DONE}" != "true" ]]; then
        log_warn "Script failed with exit code ${code}; workspace kept: ${WORK_DIR:-none}"
        generate_yaml "ftbfs" "Script aborted before a comparison was produced (exit ${code})."
    fi
    if [[ -n "${RT}" && -n "${CN_PREFIX}" ]]; then
        # shellcheck disable=SC2046
        ${RT} rm -f $(${RT} ps -aq --filter "name=${CN_PREFIX}-" 2>/dev/null) >/dev/null 2>&1 || true
    fi
    normalize_ownership
    if [[ -n "${RT}" && -n "${IMAGE_NAME}" ]]; then ${RT} rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true; fi
    return 0
}
on_signal() { log_warn "Interrupted (signal $1)"; exit "$2"; }
trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# One container per call, as the invoking user (writes to the workspace stay user-owned).
crun() {
    # shellcheck disable=SC2086
    ${RT} run --rm --name "${CN_PREFIX}-${RANDOM}" ${USER_ARGS} -e HOME=/tmp \
        -e VERSION="${VERSION}" -e REPO_URL="${REPO_URL}" -e GRADLE_VERSION="${GRADLE_VERSION}" \
        -e KIND="${INPUT_KIND}" -e OBASE="${OBASE}" -e BT_LOCALE_OPTS="${BT_LOCALE_OPTS:-}" \
        -v "${WORK_DIR}:/work" -w /work "${IMAGE_NAME}" "$@"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) VERSION="${2:-}"; shift 2 || shift ;;
            --arch) ARCH="${2:-}"; shift 2 || shift ;;
            --type) log_info "--type is not used by this script (ignored)"; shift 2 || shift ;;
            --binary|--apk) BINARY="${2:-}"; shift 2 || shift ;;
            --no-locale-align) LOCALE_ALIGN=false; shift ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) log_warn "Unknown argument: $1 (ignored)"; shift ;;
        esac
    done
    if [[ -z "$BINARY" ]]; then
        log_fail "Provide --binary <apk|dir>: one APK, or the directory with the Play split set."
        echo "Run '${SCRIPT_NAME} --help' for usage."; exit 2
    fi
    if [[ -d "$BINARY" ]]; then OFFICIAL_DIR="$(readlink -f "$BINARY")"
    elif [[ -f "$BINARY" ]]; then OFFICIAL_FILE="$(readlink -f "$BINARY")"; OFFICIAL_DIR="$(dirname "$OFFICIAL_FILE")"
    else log_fail "--binary not found: $BINARY"; exit 2; fi
    if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then log_fail "Invalid --version: $VERSION"; exit 2; fi
    RUN_ID="$(date +%s)-$$"
    WORK_DIR="$(pwd -P)/cosmostation_verification_${VERSION:-auto}_${RUN_ID}"
    IMAGE_NAME="cosmostation-ws-${RUN_ID}"
    CN_PREFIX="cosmostation-${RUN_ID}"
    log_info "Work directory (new for this run): ${WORK_DIR}"
}

detect_runtime() {
    # A runtime that actually works (info answers), podman first. Rootless podman: keep-id maps
    # the caller in. Rootless docker: container uid 0 IS the caller, so run as 0:0.
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then RT="podman"; USER_ARGS="--userns=keep-id"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RT="docker"; USER_ARGS="--user $(id -u):$(id -g)"
        if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then ROOTLESS=1; USER_ARGS="--user 0:0"; fi
    else log_fail "No working container runtime: podman info and docker info both failed."; exit 1; fi
    log_info "Using ${RT} as container runtime$([[ ${ROOTLESS} -eq 1 ]] && echo ' (rootless docker)')"
}

write_files() {
    cat > "${WORK_DIR}/image/Dockerfile" << DOCKERFILE_EOF
FROM ${BASE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends git unzip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN set -e; mkdir -p /opt/android-sdk/cmdline-tools; \
    curl -fsSL -o /tmp/c.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip; \
    echo "${CMDLINE_SHA256}  /tmp/c.zip" | sha256sum -c -; \
    unzip -q /tmp/c.zip -d /opt/android-sdk/cmdline-tools; \
    mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest; rm /tmp/c.zip
ENV ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/build-tools/35.0.0:/opt/gradle-${GRADLE_VERSION}/bin:\$PATH
RUN set -e; (yes || true) | sdkmanager --licenses >/dev/null; \
    sdkmanager "platforms;android-36" "platforms;android-33" "build-tools;35.0.0" "platform-tools" >/dev/null
RUN set -e; \
    curl -fsSL -o /tmp/g.zip https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip; \
    echo "${GRADLE_SHA256}  /tmp/g.zip" | sha256sum -c -; unzip -q /tmp/g.zip -d /opt; rm /tmp/g.zip; \
    curl -fsSL -o /opt/bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar; \
    echo "${BUNDLETOOL_SHA256}  /opt/bundletool.jar" | sha256sum -c -; \
    curl -fsSL -o /opt/apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar; \
    echo "${APKTOOL_SHA256}  /opt/apktool.jar" | sha256sum -c -
DOCKERFILE_EOF

    # prep.sh: clone the tag, rebuild the gitignored inputs from the official APK, make a temp keystore.
    cat > "${WORK_DIR}/scripts/prep.sh" << 'PREP_EOF'
set -euo pipefail
cd /work
git clone --depth 1 --branch "v${VERSION}" "${REPO_URL}" src 2>/dev/null \
    || git clone --depth 1 --branch "${VERSION}" "${REPO_URL}" src
git -C src rev-parse HEAD > commit.txt
grep -q "gradle-${GRADLE_VERSION}-bin.zip" src/gradle/wrapper/gradle-wrapper.properties \
    || { echo "The tag's Gradle wrapper does not ask for ${GRADLE_VERSION}; update the script pins."; exit 3; }
rev="$(unzip -p "${OBASE}" META-INF/version-control-info.textproto 2>/dev/null | sed -n 's/.*revision: "\([0-9a-f]*\)".*/\1/p' | head -n1 || true)"
echo "Official APK VCS revision: ${rev:-none}; built commit: $(cat commit.txt)"
mkdir -p comparison/inputs; cd comparison/inputs
ad() { java -jar /opt/apktool.jar d -f --frame-path /tmp/apktool-framework "$@"; }
ad -s -o res "/work/${OBASE}" >/dev/null 2>&1 || true
ad --no-res -o smali "/work/${OBASE}" >/dev/null 2>&1 || true
st=""
sv() { sed -n "s/.*<string name=\"$1\">\([^<]*\)<\/string>.*/\1/p" res/res/values/strings.xml 2>/dev/null | head -n1; }
bc="$(find smali -path '*wannabit/io/cosmostaion/BuildConfig.smali' -print -quit 2>/dev/null || true)"
kv() { [ -n "${bc}" ] && sed -n "s/^\.field public static final $1:Ljava\/lang\/String; = \"\(.*\)\"\$/\1/p" "${bc}" | head -n1 || true; }
wc="$(kv WALLETCONNECT_API_KEY)"; sk="$(kv SKIP_API_KEY)"
printf 'walletconnect.apiKey.release=%s\nskip.apiKey.release=%s\n' "${wc}" "${sk}" > /work/src/local.properties
[ -n "${wc}" ] && st="${st}WALLETCONNECT_API_KEY=read-from-official-APK " || st="${st}WALLETCONNECT_API_KEY=EMPTY(unreadable) "
[ -n "${sk}" ] && st="${st}SKIP_API_KEY=read-from-official-APK " || st="${st}SKIP_API_KEY=EMPTY(unreadable) "
aid="$(sv google_app_id)"
if [ -n "${aid}" ]; then
cat > /work/src/app/google-services.json << EOF
{"project_info":{"project_number":"$(sv gcm_defaultSenderId)","firebase_url":"$(sv firebase_database_url)","project_id":"$(sv project_id)","storage_bucket":"$(sv google_storage_bucket)"},
"client":[{"client_info":{"mobilesdk_app_id":"${aid}","android_client_info":{"package_name":"wannabit.io.cosmostaion"}},
"oauth_client":[{"client_id":"$(sv default_web_client_id)","client_type":3}],"api_key":[{"current_key":"$(sv google_api_key)"}],
"services":{"appinvite_service":{"other_platform_oauth_client":[{"client_id":"$(sv default_web_client_id)","client_type":3}]}}}],"configuration_version":"1"}
EOF
st="${st}google-services.json=rebuilt-from-official-APK-resources"
else st="${st}google-services.json=ABSENT(not found in official APK)"; fi
echo "${st}" > /work/comparison/inputs.status
g=/work/src/app/build.gradle
sp="$(sed -n 's/^[[:space:]]*storePassword "\(.*\)"[[:space:]]*$/\1/p' "$g" | head -n1)"
kp="$(sed -n 's/^[[:space:]]*keyPassword "\(.*\)"[[:space:]]*$/\1/p' "$g" | head -n1)"
al="$(sed -n 's/^[[:space:]]*keyAlias "\(.*\)"[[:space:]]*$/\1/p' "$g" | head -n1)"
kf="$(sed -n "s/^[[:space:]]*storeFile file('\(.*\)')[[:space:]]*\$/\1/p" "$g" | head -n1)"
[ -n "${sp}${kp}${al}${kf}" ] || { echo "Signing config of the tag not recognised"; exit 4; }
keytool -genkeypair -keystore "/work/src/app/${kf}" -storetype JKS -alias "${al}" -storepass "${sp}" \
    -keypass "${kp}" -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=WalletScrutiny Verification" >/dev/null 2>&1
echo "Prepared: source at tag, inputs rebuilt, throw-away keystore generated"
PREP_EOF

    cat > "${WORK_DIR}/scripts/build.sh" << 'BUILD_EOF'
set -euo pipefail
cd /work/src
export GRADLE_USER_HOME=/work/gradle-home
mkdir -p /work/built/splits
if [ "${KIND}" = "single" ]; then
    gradle --no-daemon :app:assembleRelease
    apk="$(find app/build/outputs/apk/release -name '*.apk' -print -quit)"
    [ -n "${apk}" ] || { echo "No release APK produced"; exit 1; }
    cp "${apk}" /work/built/splits/app.apk
else
    gradle --no-daemon :app:bundleRelease
    aab="$(find app/build/outputs/bundle/release -name '*.aab' -print -quit)"
    [ -n "${aab}" ] || { echo "No AAB produced"; exit 1; }
    cp "${aab}" /work/built/app-release.aab
    # shellcheck disable=SC2086
    java ${BT_LOCALE_OPTS} -jar /opt/bundletool.jar build-apks --bundle="${aab}" --output-format=DIRECTORY \
        --output=/tmp/built-apks --device-spec=/work/device-spec.json
    # Play naming: base-master.apk -> base.apk, base-<x>.apk -> split_config.<x>.apk
    for f in /tmp/built-apks/splits/*.apk; do
        b="$(basename "$f")"
        case "$b" in base-master.apk) n="base.apk" ;; base-*.apk) n="split_config.${b#base-}" ;; *) n="$b" ;; esac
        cp "$f" "/work/built/splits/$n"
    done
fi
ls -la /work/built/splits
BUILD_EOF

    cat > "${WORK_DIR}/scripts/cmp.sh" << 'CMP_EOF'
set -euo pipefail
cd /work
ad() { java -jar /opt/apktool.jar d -f --frame-path /tmp/apktool-framework "$@"; }
case "$1" in
  meta) aapt2 dump badging "$2" 2>/dev/null | tr -d '\r'; echo "XMLTREE"; aapt2 dump xmltree --file AndroidManifest.xml "$2" 2>/dev/null | tr -d '\r' ;;
  signer) apksigner verify --print-certs "$2" 2>/dev/null | grep -m1 'Signer #1 certificate SHA-256' | awk '{print $6}' || true ;;
  stamp) apksigner verify --verbose --print-certs "$2" 2>&1 | grep -q 'Verified for SourceStamp: true' && echo yes || echo no ;;
  diff) t="$2"; o="comparison/official-unzipped/$t"; b="comparison/built-unzipped/$t"; mkdir -p "$o" "$b"
    unzip -qo "$3" -d "$o" || [ $? -le 1 ]; unzip -qo "$4" -d "$b" || [ $? -le 1 ]
    (cd "$o" && find . -type f | sort) > "comparison/.o.$t"; (cd "$b" && find . -type f | sort) > "comparison/.b.$t"
    { comm -23 "comparison/.o.$t" "comparison/.b.$t" | sed 's/^/Only in official: /'
      comm -13 "comparison/.o.$t" "comparison/.b.$t" | sed 's/^/Only in built: /'
      comm -12 "comparison/.o.$t" "comparison/.b.$t" | while IFS= read -r f; do cmp -s "$o/$f" "$b/$f" || echo "Differs: $f"; done
    } > "comparison/diff_$t.txt"
    diff -r "$o" "$b" > "comparison/diff_full_$t.txt" 2>&1 || true ;;
  dec) t="$2"; rm -rf "comparison/dec_${t}_o" "comparison/dec_${t}_b"
    ad -s -o "comparison/dec_${t}_o" "$3" >/dev/null 2>&1 || true; ad -s -o "comparison/dec_${t}_b" "$4" >/dev/null 2>&1 || true ;;
esac
CMP_EOF
}

density_to_dpi() {
    case "$1" in ldpi) echo 120 ;; mdpi) echo 160 ;; tvdpi) echo 213 ;; hdpi) echo 240 ;; xhdpi) echo 320 ;;
        xxhdpi) echo 480 ;; xxxhdpi) echo 640 ;; *) echo "" ;; esac
}

# Device spec from the split names Play delivered (replaces `bundletool --connected-device`).
derive_device_spec() {
    log_info "=== DEVICE SPEC ==="
    local abis="" locales="" density="" f name suffix dpi abi abi_list=""
    for f in "${OFFICIAL_SPLITS[@]}"; do
        name="$(basename "$f")"; [[ "$name" == split_config.* ]] || continue
        suffix="${name#split_config.}"; suffix="${suffix%.apk}"
        dpi="$(density_to_dpi "$suffix")"
        if [[ -n "$dpi" ]]; then density="$dpi"; log_info "Density split ${suffix} -> ${dpi} dpi"; continue; fi
        case "$suffix" in
            arm64_v8a|armeabi_v7a|x86_64|x86|mips|mips64)
                abi="${suffix//_/-}"; [[ "$abi" == "x86-64" ]] && abi="x86_64"
                abis="${abis:+${abis}, }\"${abi}\""; abi_list="${abi_list} ${abi}"; log_info "ABI split ${suffix} -> ${abi}" ;;
            *) locales="${locales:+${locales}, }\"${suffix//_/-}\""; log_info "Language split ${suffix}" ;;
        esac
    done
    [[ -n "$abis" ]] || fail_ftbfs "The supplied splits contain no split_config.<abi>.apk; cannot derive a device spec."
    if [[ -n "$ARCH" && " ${abi_list} " != *" ${ARCH} "* ]]; then
        fail_ftbfs "--arch ${ARCH} does not match the ABI split supplied (${abi_list# })."
    fi
    [[ -z "$density" ]] && { density=480; log_warn "No density split supplied; using 480 dpi."; }
    [[ -z "$locales" ]] && locales='"en-US"'
    [[ "${TARGET_SDK}" =~ ^[0-9]+$ ]] || { log_warn "targetSdkVersion unreadable; using 36."; TARGET_SDK=36; }
    cat > "${WORK_DIR}/device-spec.json" << SPEC_EOF
{
  "supportedAbis": [${abis}],
  "supportedLocales": [${locales}],
  "screenDensity": ${density},
  "sdkVersion": ${TARGET_SDK}
}
SPEC_EOF
    log_info "Device spec derived from the supplied splits:"; cat "${WORK_DIR}/device-spec.json"
}

prepare() {
    log_info "=== PREPARATION PHASE ==="
    mkdir "${WORK_DIR}" || fail_ftbfs "Workspace already exists: ${WORK_DIR}"
    mkdir -p "${WORK_DIR}"/{official,built/splits,comparison,scripts,image}
    write_files

    shopt -s nullglob
    local sib=("${OFFICIAL_DIR}"/split_config.*.apk) supplied=()
    if [[ -n "$OFFICIAL_FILE" && "$(basename "$OFFICIAL_FILE")" == "base.apk" && ${#sib[@]} -gt 0 ]]; then
        log_info "--binary is the base.apk of a split set; using its directory"; OFFICIAL_FILE=""
    fi
    if [[ -n "$OFFICIAL_FILE" ]]; then supplied=("$OFFICIAL_FILE"); else supplied=("${OFFICIAL_DIR}"/*.apk); fi
    shopt -u nullglob
    [[ ${#supplied[@]} -gt 0 ]] || fail_ftbfs "No .apk file found at ${BINARY}."
    if [[ ${#supplied[@]} -eq 1 ]]; then
        INPUT_KIND="single"; cp "${supplied[0]}" "${WORK_DIR}/official/app.apk"
        OBASE="official/app.apk"; OFFICIAL_SPLITS=("${WORK_DIR}/official/app.apk")
        log_info "One APK supplied: $(basename "${supplied[0]}") (working copy official/app.apk)"
    else
        INPUT_KIND="splits"; cp "${supplied[@]}" "${WORK_DIR}/official/"
        shopt -s nullglob; OFFICIAL_SPLITS=("${WORK_DIR}/official"/*.apk); shopt -u nullglob
        OBASE="official/base.apk"
        [[ -f "${WORK_DIR}/${OBASE}" ]] || fail_ftbfs "Several APKs supplied but no base.apk; a Play split set must include it."
        log_info "Official splits supplied: ${#OFFICIAL_SPLITS[@]}"
    fi
    OFFICIAL_APP_HASH="$(sha256_local "${WORK_DIR}/${OBASE}")"
    log_info "Official $(basename "${OBASE}") SHA256 (as supplied): ${OFFICIAL_APP_HASH}"

    log_info "Building the tool image (pinned base image, SDK, Gradle ${GRADLE_VERSION}, bundletool, apktool)..."
    ${RT} build -t "${IMAGE_NAME}" -f "${WORK_DIR}/image/Dockerfile" "${WORK_DIR}/image" \
        || fail_ftbfs "Tool image build failed (pinned downloads or base image unavailable)." 1

    local meta pkg
    meta="$(crun bash /work/scripts/cmp.sh meta "/work/${OBASE}")" || true
    pkg="$(printf '%s\n' "$meta" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1)"
    APK_VERSION_CODE="$(printf '%s\n' "$meta" | sed -n "/^package:/s/.* versionCode='\([^']*\)'.*/\1/p" | head -n1)"
    APK_VERSION_NAME="$(printf '%s\n' "$meta" | sed -n "/^package:/s/.* versionName='\([^']*\)'.*/\1/p" | head -n1)"
    TARGET_SDK="$(printf '%s\n' "$meta" | sed -n "s/^targetSdkVersion:'\([0-9]*\)'.*/\1/p" | head -n1)"
    SIGNER_SHA256="$(crun bash /work/scripts/cmp.sh signer "/work/${OBASE}" || true)"
    [[ -n "$pkg" ]] || fail_ftbfs "Package name unreadable from the supplied APK."
    [[ "$pkg" == "$APP_ID" ]] || fail_ftbfs "Wrong APK: package is '${pkg}', expected '${APP_ID}'."
    log_pass "Package ID verified: ${pkg}"
    log_info "versionName=${APK_VERSION_NAME:-unset} versionCode=${APK_VERSION_CODE:-unset} targetSdk=${TARGET_SDK:-unset}"

    if [[ "$INPUT_KIND" == "single" ]]; then
        if grep -qE ' split="config\.' <<< "$meta"; then
            fail_ftbfs "The supplied file is a Play config split; upload the full split set (base.apk + split_config.*.apk)."
        elif grep -qE 'isSplitRequired\(0x[0-9a-f]+\)=true|com\.android\.vending\.splits' <<< "$meta"; then
            fail_ftbfs "The supplied file is a Play base.apk that needs its splits; upload the full split set."
        fi
    fi
    if [[ -z "$VERSION" ]]; then
        VERSION="${APK_VERSION_NAME}"
        [[ -n "$VERSION" ]] || fail_ftbfs "Cannot read the version from the APK; pass --version."
        log_info "Version read from the APK: ${VERSION}"
    elif [[ -n "$APK_VERSION_NAME" && "$APK_VERSION_NAME" != "$VERSION" ]]; then
        fail_ftbfs "--version ${VERSION} disagrees with the APK versionName ${APK_VERSION_NAME}."
    fi
    log_info "inputKind: ${INPUT_KIND}"
    if [[ "$INPUT_KIND" == "splits" ]]; then derive_device_spec; fi
    log_pass "Preparation complete"
}

build() {
    log_info "=== BUILD PHASE ==="
    log_info "Cloning v${VERSION} and rebuilding the withheld inputs from the official APK (values are not printed)"
    crun bash /work/scripts/prep.sh || fail_ftbfs "Source preparation failed for v${VERSION} (tag clone, Gradle pin or signing config)." 1
    COMMIT_HASH="$(cat "${WORK_DIR}/commit.txt" 2>/dev/null || echo unknown)"
    INPUTS_NOTE="$(cat "${WORK_DIR}/comparison/inputs.status" 2>/dev/null || echo unknown)"
    log_info "Withheld inputs: ${INPUTS_NOTE}"
    if [[ "$INPUT_KIND" == "splits" && "$LOCALE_ALIGN" == "true" ]]; then BT_LOCALE_OPTS="-Djava.locale.useOldISOCodes=true"; else BT_LOCALE_OPTS=""; fi
    if [[ "$INPUT_KIND" == "single" ]]; then log_info "Running gradle :app:assembleRelease"; else log_info "Running gradle :app:bundleRelease, then bundletool ${BUNDLETOOL_VERSION}"; fi
    crun bash /work/scripts/build.sh || fail_ftbfs "Gradle build failed for v${VERSION} (${INPUT_KIND})." 1
    shopt -s nullglob; local built=("${WORK_DIR}/built/splits"/*.apk); shopt -u nullglob
    [[ ${#built[@]} -gt 0 ]] || fail_ftbfs "The build produced no APK." 1
    log_pass "Build complete: ${#built[@]} APK(s)"
}

# resources.arsc evidence (review-notes/resources.arsc.md): decode both sides, diff res/.
assess_arsc() {
    local tag="$1" d="${WORK_DIR}/comparison" out changed residual
    out="${d}/diff_resources_decoded_${tag}.txt"
    diff -r "${d}/dec_${tag}_o/res" "${d}/dec_${tag}_b/res" > "$out" 2>&1 || true
    if [[ ! -d "${d}/dec_${tag}_o/res" || ! -d "${d}/dec_${tag}_b/res" ]]; then
        ARSC_STATE[$tag]="decode-failed"
    elif [[ ! -s "$out" ]]; then
        ARSC_STATE[$tag]="binary-only"; log_pass "${tag}: decoded res/ identical (resources.arsc is non-semantic)"
    else
        changed="$(grep -cE '^[<>]' "$out" || true)"
        residual="$(grep -E '^[<>]' "$out" | grep -vc 'com.google.firebase.crashlytics.mapping_file_id' || true)"
        if [[ "${residual:-0}" -eq 0 && "${changed:-0}" -gt 0 ]]; then ARSC_STATE[$tag]="crashlytics-only"
        else ARSC_STATE[$tag]="semantic"; log_fail "${tag}: decoded res/ differs (${residual} lines)"; fi
    fi
    ARSC_SUMMARY="${ARSC_SUMMARY}resources.arsc ${tag}: ${ARSC_STATE[$tag]}
"
}

normalise_manifest() {
    sed -E -e "/<meta-data[^>]*android:name=\"(${PLAY_KEYS})\"/d" -e '/^[[:space:]]*<\/application>[[:space:]]*$/d' \
        -e 's#/>#>#g' -e 's/[[:space:]]+/ /g' -e 's/[[:space:]]+>/>/g' -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' "$1"
}

# Is the AndroidManifest.xml difference nothing but Play distribution metadata? Fail-closed.
assess_manifest() {
    local tag="$1" d="${WORK_DIR}/comparison" o b
    o="${d}/dec_${tag}_o/AndroidManifest.xml"; b="${d}/dec_${tag}_b/AndroidManifest.xml"
    if [[ ! -f "$o" || ! -f "$b" ]]; then MF_STATE[$tag]="decode-failed"; return 0; fi
    if grep -qE "<meta-data[^>]*android:name=\"(${PLAY_KEYS})\"" "$b"; then MF_STATE[$tag]="semantic"; return 0; fi
    normalise_manifest "$o" > "${d}/mf_${tag}_o.norm"; normalise_manifest "$b" > "${d}/mf_${tag}_b.norm"
    if diff -q "${d}/mf_${tag}_o.norm" "${d}/mf_${tag}_b.norm" >/dev/null 2>&1; then MF_STATE[$tag]="play-metadata-only"
    else MF_STATE[$tag]="semantic"; diff "${d}/mf_${tag}_o.norm" "${d}/mf_${tag}_b.norm" > "${d}/diff_manifest_${tag}.txt" 2>&1 || true; fi
}

# Move one class of lines out of the counted set, recording why.
accept_lines() {
    local counted="$1" pattern="$2" tag="$3" reason="$4" hits
    hits="$(grep -cE "$pattern" "$counted" || true)"
    [[ "${hits:-0}" -gt 0 ]] || return 0
    grep -vE "$pattern" "$counted" > "${counted}.keep" || true
    mv "${counted}.keep" "$counted"
    ACCEPTED_SUMMARY="${ACCEPTED_SUMMARY}${tag}: ${hits} x ${reason}
"
}

compare() {
    log_info "=== COMPARISON PHASE ==="
    local d="${WORK_DIR}/comparison" sig f name tag cnt counted total
    if [[ "$INPUT_KIND" == "single" ]]; then
        sig='^(Only in official|Only in built|Differs): \./META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))$'
    else
        sig='^Only in official: \./META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))$'
    fi
    for f in "${OFFICIAL_SPLITS[@]}"; do
        name="$(basename "$f")"; tag="${name%.apk}"; tag="${tag#split_config.}"
        if [[ ! -f "${WORK_DIR}/built/splits/${name}" ]]; then
            log_warn "Split in official set but not built: ${name}"
            MISSING_NOTE="${MISSING_NOTE}Missing in built: ${name}. "
            ART_TAG+=("$tag"); ART_CNT+=(1); ART_TOP+=("(missing from the built set)"); DIFF_COUNT=$((DIFF_COUNT + 1)); continue
        fi
        crun bash /work/scripts/cmp.sh diff "$tag" "official/${name}" "built/splits/${name}"
        counted="${d}/counted_${tag}.txt"; cp "${d}/diff_${tag}.txt" "$counted"
        total="$(grep -c '^' "$counted" || true)"
        if grep -q 'resources\.arsc\|AndroidManifest\.xml' "$counted"; then
            crun bash /work/scripts/cmp.sh dec "$tag" "official/${name}" "built/splits/${name}"
            if grep -q 'resources\.arsc' "$counted"; then assess_arsc "$tag"; fi
            if grep -q 'AndroidManifest\.xml' "$counted"; then assess_manifest "$tag"; fi
        fi
        accept_lines "$counted" "$sig" "$tag" "root META-INF signing files (MANIFEST.MF, *.SF, *.RSA/DSA/EC)"
        if grep -q 'stamp-cert-sha256' "$counted" && [[ "$(crun bash /work/scripts/cmp.sh stamp "/work/official/${name}")" == "yes" ]]; then
            accept_lines "$counted" '^Only in official: \./stamp-cert-sha256$' "$tag" "stamp-cert-sha256 (Play SourceStamp, verified by apksigner)"
        fi
        if [[ "${ARSC_STATE[$tag]:-}" == "binary-only" || "${ARSC_STATE[$tag]:-}" == "crashlytics-only" ]]; then
            accept_lines "$counted" '\./resources\.arsc$' "$tag" "resources.arsc (${ARSC_STATE[$tag]}, per resources.arsc policy)"
        fi
        if [[ "${MF_STATE[$tag]:-}" == "play-metadata-only" ]]; then
            accept_lines "$counted" '\./AndroidManifest\.xml$' "$tag" "AndroidManifest.xml (Play distribution metadata only)"
        fi
        cnt="$(grep -c '^' "$counted" || true)"; cnt="${cnt:-0}"
        DIFF_COUNT=$((DIFF_COUNT + cnt))
        ART_TAG+=("$tag"); ART_CNT+=("$cnt"); ART_TOP+=("$(head -n 25 "$counted")")
        log_info "${tag}: ${total} differing paths, ${cnt} unaccounted"
    done
    local b
    shopt -s nullglob
    for b in "${WORK_DIR}/built/splits"/*.apk; do
        name="$(basename "$b")"
        if [[ ! -f "${WORK_DIR}/official/${name}" ]]; then
            log_warn "Split built but not in the official set: ${name}"
            MISSING_NOTE="${MISSING_NOTE}Extra in built: ${name}. "
            ART_TAG+=("extra:${name}"); ART_CNT+=(1); ART_TOP+=("(not in the official set)"); DIFF_COUNT=$((DIFF_COUNT + 1))
        fi
    done
    shopt -u nullglob
}

print_results() {
    local verdict_label="$1" i f
    echo ""; echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "inputKind:      ${INPUT_KIND}"
    echo "signer:         ${SIGNER_SHA256:-unknown}"
    echo "apkVersionName: ${APK_VERSION_NAME:-${VERSION}}"
    echo "apkVersionCode: ${APK_VERSION_CODE:-unknown}"
    echo "verdict:        ${verdict_label}"
    echo "appHash:        ${OFFICIAL_APP_HASH}"
    echo "commit:         ${COMMIT_HASH}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256}"
    echo ""; echo "Per-artifact verdicts (overall = worst):"
    for i in "${!ART_TAG[@]}"; do
        echo "  ${ART_TAG[$i]}: $([[ ${ART_CNT[$i]} -eq 0 ]] && echo reproducible || echo "not_reproducible (${ART_CNT[$i]} unaccounted)")"
    done
    echo ""; echo "Official APK hashes (as supplied):"
    for f in "${OFFICIAL_SPLITS[@]}"; do echo "  $(basename "$f")  $(sha256_local "$f")"; done
    echo "Built APK hashes:"
    shopt -s nullglob; for f in "${WORK_DIR}/built/splits"/*.apk; do echo "  $(basename "$f")  $(sha256_local "$f")"; done; shopt -u nullglob
    echo ""; echo "Diff (unaccounted paths, first 5 per artifact; full lists in ${WORK_DIR}/comparison/diff_<artifact>.txt):"
    for i in "${!ART_TAG[@]}"; do
        echo "=== ${ART_TAG[$i]} (${ART_CNT[$i]} unaccounted) ==="
        [[ -n "${ART_TOP[$i]}" ]] && printf '%s\n' "${ART_TOP[$i]}" | head -n 5
        [[ ${ART_CNT[$i]} -gt 5 ]] && echo "... ($((ART_CNT[i] - 5)) more)"
    done
    if [[ -n "$ACCEPTED_SUMMARY" ]]; then echo ""; echo "Accepted (evidence-earned, excluded from the count):"; printf '%s' "$ACCEPTED_SUMMARY"; fi
    if [[ -n "$ARSC_SUMMARY" ]]; then echo ""; printf '%s' "$ARSC_SUMMARY"; fi
    echo ""; echo "Withheld inputs: ${INPUTS_NOTE}"
    echo ""; echo "Revision, tag (and its signature):"
    echo "Built from tag v${VERSION} at commit ${COMMIT_HASH}. No git tag signature check is performed."
    [[ -n "$MISSING_NOTE" ]] && { echo ""; echo "===== Also ===="; echo "${MISSING_NOTE}"; }
    echo ""; echo "===== End Results ====="; echo ""
    echo "Hash legend: appHash is the official artifact exactly as supplied (the single APK, or base.apk of the"
    echo "split set) and is the value to publish. Built APKs carry a throw-away signature (single) or none (splits)."
    echo "Compare by hand: diff --recursive ${WORK_DIR}/comparison/official-unzipped ${WORK_DIR}/comparison/built-unzipped"
}

result() {
    log_info "=== RESULTS ==="
    local label yaml notes i
    if [[ "${DIFF_COUNT}" -eq 0 ]]; then label="reproducible"; yaml="reproducible"; RESULT_EXIT_CODE=0; log_pass "VERDICT: REPRODUCIBLE"
    else label="differences found"; yaml="not_reproducible"; RESULT_EXIT_CODE=1; log_warn "VERDICT: NOT REPRODUCIBLE (${DIFF_COUNT} unaccounted differences)"; fi
    notes="inputKind: ${INPUT_KIND}. Built from tag v${VERSION} (${COMMIT_HASH}) in a pinned container: temurin 21, Gradle ${GRADLE_VERSION}, build-tools 35.0.0, platforms 36 and 33$([[ $INPUT_KIND == splits ]] && echo ", bundletool ${BUNDLETOOL_VERSION}" || true)."
    notes="${notes}
Withheld inputs: ${INPUTS_NOTE}. A throw-away keystore signs the build, so signatures differ."
    notes="${notes}
Per-artifact:"
    for i in "${!ART_TAG[@]}"; do
        notes="${notes}
  ${ART_TAG[$i]}: $([[ ${ART_CNT[$i]} -eq 0 ]] && echo reproducible || echo "not_reproducible, ${ART_CNT[$i]} unaccounted")"
        [[ ${ART_CNT[$i]} -gt 0 && -n "${ART_TOP[$i]}" ]] && notes="${notes}
$(printf '%s\n' "${ART_TOP[$i]}" | sed 's/^/    /')"
        [[ ${ART_CNT[$i]} -gt 25 ]] && notes="${notes}
    ... ($((ART_CNT[i] - 25)) more unaccounted paths)"
    done
    [[ -n "$ACCEPTED_SUMMARY" ]] && notes="${notes}
Accepted differences (evidence-earned):
$(printf '%s' "$ACCEPTED_SUMMARY" | sed 's/^/  /')"
    [[ -n "$MISSING_NOTE" ]] && notes="${notes}
${MISSING_NOTE}"
    generate_yaml "${yaml}" "${notes}"
    RESULT_DONE=true
    log_info "Generated ${YAML_PATH}"
    print_results "${label}"
    log_info "Workspace preserved: ${WORK_DIR}"
    echo "Exit code: ${RESULT_EXIT_CODE}"
}

main() {
    SCRIPT_SHA256="$(sha256_local "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"
    log_warn "Provided as-is for security research. Review before running."
    if [[ "$(id -u)" -eq 0 ]]; then log_fail "Do not run this script as root."; RESULT_DONE=true; exit 2; fi
    parse_arguments "$@"
    rm -f "${YAML_PATH}"   # stale result from an earlier run
    detect_runtime
    prepare
    build
    compare
    result
    exit "${RESULT_EXIT_CODE}"
}
main "$@"
