#!/bin/bash
# bitbanana-v0.9.3_build.sh — BitBanana (app.michaelwuensch.bitbanana) Android reproducible build verification
# Version:          v0.9.3
# Organization:     WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-19
# Project:          https://github.com/michaelWuensch/BitBanana
# Scope: one script for all four distribution channels; the input kind is read from the APK
#        manifest, never from flags or file names (ABS stores uploads as base.apk or <hash>.bin).
#        - Google Play split set (base.apk + split_config.*.apk): upstream docs/REPRODUCE_PLAYSTORE.md,
#          gradle bundleRelease under disorderfs, bundletool build-apks against a device spec derived
#          from the supplied splits, per-split comparison with evidence-earned exclusions.
#        - GitHub / F-Droid / Obtainium fat APK (one file, all ABIs): upstream docs/REPRODUCE_GITHUB.md,
#          gradle assembleRelease under disorderfs, unsigned output compared with the supplied file.
#        - A lone Play base.apk or config split is refused: the full set is needed.
#        Every tool runs in containers (podman or docker). No smartphone, no adb, no root.
# Shared steps (engine pick, workspace, traps, YAML, results block, cleanup) come from the
# WalletScrutiny library ws-rb-core, pinned by sha256 below (GitLab #1023).
# Offline: WS_LIB_FILE=/path/to/ws-rb-core-1.0.0.sh.
# After the build, ws-buildlock.sh (WS repo, pinned commit + sha256; GitLab #1000) records what
# Gradle fetched in <workspace>/build-lock/build-lock.json. It never changes the verdict.
# Exit codes: 0 reproducible; 1 not reproducible, ftbfs or no verdict;
# 2 invalid parameters or library unavailable; 130 stopped.
# License: MIT. No warranty. For security research only. Use at your own risk.
set -euo pipefail
readonly SCRIPT_VERSION="v0.9.3"
readonly SCRIPT_NAME="bitbanana-v0.9.3_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH

# ---- Self-identification (first action, before arguments or any network) -----
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1)" || true
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "         sha256: ${SCRIPT_SHA256}"
echo

# ---- WalletScrutiny library (GitLab #1023), pinned by sha256 ------------------
# Goes in each build script right after its self-hash line, before anything else.
# Source: WS_LIB_FILE (offline, must match), else the cache, else GitLab by
# commit. Nothing else. A wrong hash is rejected whichever source sent it.
# No matching copy, or a different version inside: no verdict, no YAML, exit 2.
# First, before anything can fail: no earlier verdict may survive this run. A run
# that holds this folder's lock is still writing its own; that one stays, and the
# library refuses this run when it takes the lock.
WS_LIB_DIR0="$(dirname "$(readlink -f "$0")")"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WS_LIB_DIR0/.comparison_results.lock" true 2>/dev/null && rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
else
  WS_LIB_P="$(cat "$WS_LIB_DIR0/.comparison_results.lock.d/pid" 2>/dev/null || true)"
  case "$WS_LIB_P" in ''|*[!0-9]*) WS_LIB_P="";; esac
  { [ -n "$WS_LIB_P" ] && kill -0 "$WS_LIB_P" 2>/dev/null; } || rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
fi
WS_LIB=ws-rb-core WS_LIB_VERSION=1.0.0
WS_LIB_REV=3581020196b35eefa501a19ed0abb43e96f4db42 WS_LIB_SHA256=d321b7c6937bbfc4a42db273c3fb6ec02c58e930c7c2b962492b8966188a0fcf
ws_lib_load() {
  local c f u t=""
  ws_lib_ok() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$WS_LIB_SHA256" ]; }
  if [ -n "${WS_LIB_FILE:-}" ]; then
    f="$WS_LIB_FILE"
    ws_lib_ok "$f" || { echo "[FAIL] WS_LIB_FILE $f is not sha256 $WS_LIB_SHA256: no verdict" >&2; exit 2; }
  else
    # Cache in XDG_CACHE_HOME or HOME; with neither, or no way to create it, a
    # temporary folder for this run only. Every copy is hash-checked either way.
    c="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
    if [ -n "$c" ] && mkdir -p "$c/ws-rb-lib" 2>/dev/null; then c="$c/ws-rb-lib"
    else t="$(mktemp -d 2>/dev/null)" || { echo "[FAIL] no folder to fetch $WS_LIB into: no verdict" >&2; exit 2; }; c="$t"; fi
    f="$c/$WS_LIB_SHA256.sh"
    if ! ws_lib_ok "$f"; then
      u="https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/$WS_LIB_REV/scripts/rb/lib/$WS_LIB-$WS_LIB_VERSION.sh"
      curl -fsSL --max-time 60 -o "$f.$$" "$u" 2>/dev/null && ws_lib_ok "$f.$$" && mv -f "$f.$$" "$f"
      rm -f "$f.$$"
    fi
  fi
  ws_lib_ok "$f" || { [ -z "$t" ] || rm -rf -- "$t"; echo "[FAIL] $WS_LIB $WS_LIB_VERSION ($WS_LIB_SHA256) unavailable or altered: no verdict" >&2; exit 2; }
  . "$f"
  [ -z "$t" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load

readonly APP_ID="app.michaelwuensch.bitbanana"
readonly REPO_URL="https://github.com/michaelWuensch/BitBanana"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
# The utility image (not removed at exit) hands docker-written files back to the caller.
WS_CHOWN_IMAGE="${WS_CONTAINER}"
# bundletool decides split naming and packaging, so it is a build input: pinned by hash.
readonly BUNDLETOOL_VERSION="1.18.0"
readonly BUNDLETOOL_SHA256="78343764d2e79c8f55710378b04981fcb1e46daebfc3b5dc577778082e6a98fd"
# Build record helper (#1000), pinned by commit and sha256.
readonly BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
readonly BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"

VERSION=""; ARCH=""; TYPE=""; BINARY=""
WORK_DIR=""; IMAGE_NAME=""
OFFICIAL_DIR=""; OFFICIAL_FILE=""; OFFICIAL_BASE=""; OFFICIAL_NAME=""; OFFICIAL_APP_HASH=""
INPUT_KIND=""
APP_ID_FROM_APK=""; APK_VERSION_NAME=""; APK_VERSION_CODE=""; SIGNER_SHA256=""; COMMIT_HASH=""
SPEC_ABIS=""; SPEC_DENSITY=""; SPEC_LOCALES=""; SPEC_SDK=""
DIFF_COUNT=0; MISSING_NOTE=""; ARSC_SUMMARY=""; ACCEPTED_SUMMARY=""
LOCALE_ALIGN=true
BUILD_LOCK_FILE=""
declare -a YAML_HASHES=()
# The only AndroidManifest.xml entries Google Play may add. Anything else, or ANY entry
# present only on the built side, stays counted as a real difference.
readonly PLAY_MANIFEST_KEYS='com\.android\.stamp\.source|com\.android\.stamp\.type|com\.android\.vending\.derived\.apk\.id'
declare -A ARSC_STATE=()
declare -A MF_STATE=()
declare -a OFFICIAL_SPLITS=()
APKTOOL_MANIFEST=""
APKTOOL_YML=""

log_info() { ws_info "$1"; }
log_pass() { ws_ok "$1"; }
log_fail() { echo "[FAIL] $1"; }
log_warn() { ws_warn "$1"; }

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --binary <file|dir> [--version <version>] | --version <version>
  --binary <path>      Official artifact. Either a directory holding the Google Play split set
                       (base.apk plus split_config.*.apk; a path to that base.apk is accepted),
                       or one file: the GitHub / F-Droid / Obtainium release APK under any name
                       (base.apk, <hash>.bin). The kind is detected from the APK manifest.
                       Alias: --apk. Play splits cannot be downloaded, so they need --binary.
  --version <version>  Release tag to build (e.g. 1.1.0). Omitted: read from the APK.
                       Without --binary: the GitHub release APK of that version is downloaded.
  --arch <abi>         Checked against the artifact (arm64-v8a, armeabi-v7a, x86, x86_64); mismatch exits 2.
  --type               Accepted for ABS compatibility.
  --no-locale-align    Play split set only: run bundletool WITHOUT -Djava.locale.useOldISOCodes=true.
                       Default ON because Google Play's split generator emits the legacy language
                       codes (iw/in/ji). The app build itself never receives this property.
  --script-version     Print script version and exit.
  Requires: podman or docker, curl, sha256sum. No smartphone, no adb, no root.
  Exit: 0=reproducible 1=not_reproducible/ftbfs/no verdict 2=invalid parameters 130=stopped
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) ws_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
            --arch)    ws_require_value "$1" "${2:-}"; ARCH="$2";    shift 2 ;;
            --type)    ws_require_value "$1" "${2:-}"; TYPE="$2";    shift 2 ;;
            --binary|--apk) ws_require_value "$1" "${2:-}"; BINARY="$2"; shift 2 ;;
            --no-locale-align) LOCALE_ALIGN=false; shift ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) usage ;;
            *) ws_unknown_arg "$@"; shift "${WS_SHIFT}" ;;
        esac
    done

    [[ -n "$BINARY" || -n "$VERSION" ]] \
        || ws_invalid "Provide --binary <file|dir> (Play split set or release APK), or --version to download the GitHub release APK. Run '${SCRIPT_NAME} --help' for usage."
    if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
        ws_invalid "invalid --version '${VERSION}'"
    fi
    if [[ -z "$BINARY" ]]; then
        log_info "No --binary: the GitHub release APK of v${VERSION} will be downloaded."
    elif [[ -d "$BINARY" ]]; then
        OFFICIAL_DIR="$(readlink -f "$BINARY")"
    elif [[ -f "$BINARY" ]]; then
        OFFICIAL_FILE="$(readlink -f "$BINARY")"
        OFFICIAL_DIR="$(dirname "$OFFICIAL_FILE")"
    else
        ws_invalid "--binary not found: $BINARY"
    fi
}

# Every container is named bitbanana-<run id>-..., so the exit trap stops it if the run ends early.
# Containers started inside $(...) are not in the parent's list; ws_cleanup_hook finds them by name.
CN=0
crun() { local n="bitbanana-${WS_RUN_ID}-${BASHPID}-$((++CN))"; ws_track_container "$n"; ws_ctr run --rm --name "$n" "$@"; }
ws_cleanup_hook() {
    [[ -n "$WS_ENGINE" && "$WS_KEEP" != 1 ]] || return 0
    local id
    for id in $(ws_ctr ps -aq --filter "name=bitbanana-${WS_RUN_ID}-" 2>/dev/null); do
        ws_ctr rm -f "$id" &>/dev/null || true
    done
}

# Utility container: apktool, apksigner, keytool, unzip. No aapt/aapt2 in that image.
ws_run() {
    crun -v "${WORK_DIR}:/work" -w /work "${WS_CONTAINER}" bash -c "$1"
}

# YAML notes start with the input kind.
yaml_notes() {
    if [[ -n "$INPUT_KIND" && -n "$1" ]]; then printf 'inputKind: %s. %s' "$INPUT_KIND" "$1"; else printf '%s' "$1"; fi
}

# A --version-only run (no --binary) downloaded the official APK: its hash goes in the YAML.
yaml_hashes() {
    if [[ -z "$BINARY" && -n "$OFFICIAL_APP_HASH" ]]; then YAML_HASHES=("$OFFICIAL_APP_HASH"); else YAML_HASHES=(); fi
}

# The source failed to build: log, write the ftbfs YAML and leave with exit 1.
fail_ftbfs() {
    log_fail "$1"
    yaml_hashes
    ws_write_yaml ftbfs "$(yaml_notes "$1")" ${YAML_HASHES[@]+"${YAML_HASHES[@]}"}
    exit "$WS_EXIT_FAIL"
}

decode_official() {
    APKTOOL_MANIFEST="${WORK_DIR}/comparison/meta/AndroidManifest.xml"
    APKTOOL_YML="${WORK_DIR}/comparison/meta/apktool.yml"
    ws_run "set -e; rm -rf comparison/meta; apktool d -f -s -o comparison/meta $1" \
        || ws_no_verdict "apktool could not decode the supplied APK (${OFFICIAL_NAME})."
    [[ -f "$APKTOOL_MANIFEST" ]] || ws_no_verdict "apktool produced no AndroidManifest.xml."
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

# No --binary: fetch the GitHub release APK (bitbanana-<v>-release.apk). A failed download is
# no verdict, never ftbfs.
fetch_official() {
    local name="bitbanana-${VERSION}-release.apk"
    local url="${REPO_URL}/releases/download/v${VERSION}/${name}"
    mkdir -p "${WORK_DIR}/download"
    log_info "Downloading ${url}"
    ws_fetch "$url" "${WORK_DIR}/download/${name}"
    OFFICIAL_FILE="${WORK_DIR}/download/${name}"
    OFFICIAL_DIR="${WORK_DIR}/download"
    log_info "Downloaded ${name}, sha256 $(ws_sha256 "$OFFICIAL_FILE")"
}

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

    [[ -n "$abis" ]] || ws_invalid "Supplied splits contain no split_config.<abi>.apk; cannot derive a device spec."
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
    # Per-run workspace in the caller's directory (exclusive mkdir, never reused).
    ws_workspace bitbanana "${VERSION:-provided}" "${ARCH:-auto}-${TYPE:-default}"
    WORK_DIR="${WS_WORKDIR}"
    mkdir -p "${WORK_DIR}"/{official,built/splits,build-lock,comparison}
    chmod 777 "${WORK_DIR}" "${WORK_DIR}/built" "${WORK_DIR}/built/splits" "${WORK_DIR}/build-lock" "${WORK_DIR}/comparison"
    # No --binary: the script downloads the official artifact itself (sets OFFICIAL_FILE/OFFICIAL_DIR).
    [[ -n "$BINARY" ]] || fetch_official

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
    [[ ${#supplied[@]} -gt 0 ]] || ws_invalid "No .apk or .bin file found at ${BINARY}."

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
        [[ -f "$OFFICIAL_BASE" ]] || ws_invalid "Several APKs supplied but no base.apk; a Play split set must include it."
        INPUT_KIND="play-split-set"
        log_info "Official splits supplied: ${#OFFICIAL_SPLITS[@]}"
        local f
        for f in "${OFFICIAL_SPLITS[@]}"; do log_info "  $(basename "$f")"; done
    fi
    local rel
    rel="official/$(basename "$OFFICIAL_BASE")"

    # appHash is the official artifact exactly as supplied: base.apk of a split set, or the one APK.
    OFFICIAL_APP_HASH="$(ws_sha256 "$OFFICIAL_BASE")"
    log_info "Official ${OFFICIAL_NAME} SHA256 (as supplied): ${OFFICIAL_APP_HASH}"

    decode_official "$rel"
    APP_ID_FROM_APK="$(manifest_package || true)"
    APK_VERSION_NAME="$(yml_field versionName)"
    APK_VERSION_CODE="$(yml_field versionCode)"
    SPEC_SDK="$(yml_field targetSdkVersion)"
    SIGNER_SHA256="$(apk_signer "$rel")"

    [[ -n "$APP_ID_FROM_APK" ]] || ws_invalid "Package name unreadable from the supplied APK."
    log_info "versionName=${APK_VERSION_NAME:-unset} versionCode=${APK_VERSION_CODE:-unset} targetSdk=${SPEC_SDK:-unset}"
    [[ "$APP_ID_FROM_APK" == "$APP_ID" ]] || ws_invalid "Wrong APK: package is '${APP_ID_FROM_APK}', expected '${APP_ID}'."
    log_pass "Package ID verified: ${APP_ID_FROM_APK}"

    if [[ "$single" == "true" ]]; then
        classify_single
        if [[ "$INPUT_KIND" != "fat-apk" ]]; then
            log_fail "inputKind: ${INPUT_KIND}"
            ws_invalid "The supplied file is one Google Play APK (${INPUT_KIND}), which cannot be verified alone. Upload the full split set: base.apk plus every split_config.*.apk."
        fi
    fi
    log_info "inputKind: ${INPUT_KIND}"

    if [[ -z "$VERSION" ]]; then
        VERSION="${APK_VERSION_NAME}"
        [[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || ws_invalid "Cannot detect the version from the APK; pass --version."
        log_info "Version detected from the APK: ${VERSION}"
    elif [[ -n "$APK_VERSION_NAME" && "$APK_VERSION_NAME" != "$VERSION" ]]; then
        log_warn "The APK reports ${APK_VERSION_NAME}, --version says ${VERSION}. Building ${VERSION}."
    fi
    APK_VERSION_NAME="${APK_VERSION_NAME:-$VERSION}"
    APK_VERSION_CODE="${APK_VERSION_CODE:-unknown}"
    SIGNER_SHA256="${SIGNER_SHA256:-unknown}"

    if [[ "$INPUT_KIND" == "play-split-set" ]]; then derive_device_spec; fi
    check_arch
    log_pass "Preparation complete"
}

# --arch against the supplied artifact (the ABS passes none for Android). Split set: the ABI split
# Play delivered. Fat APK: its lib/<abi>/ folders; an APK with no native code fits any ABI.
check_arch() {
    [[ -n "${ARCH:-}" ]] || return 0
    local want="$ARCH"
    case "$want" in
        aarch64|arm64) want="arm64-v8a" ;;
        armv7|armv7l|arm) want="armeabi-v7a" ;;
        amd64) want="x86_64" ;;
    esac
    case "$want" in
        arm64-v8a|armeabi-v7a|x86|x86_64) ;;
        *) log_warn "Unknown --arch '${ARCH}'; not checked."; return 0 ;;
    esac
    if [[ "$INPUT_KIND" == "play-split-set" ]]; then
        [[ "$SPEC_ABIS" == *"\"${want}\""* ]] \
            || ws_invalid "--arch ${ARCH} does not match the supplied ABI split(s): ${SPEC_ABIS}."
    else
        local abis
        abis="$(ws_run "unzip -Z1 official/app.apk 'lib/*' 2>/dev/null | cut -d/ -f2 | sort -u | tr '\n' ' '" || true)"
        if [[ -n "${abis// /}" && " ${abis} " != *" ${want} "* ]]; then
            ws_invalid "--arch ${ARCH} is not in the APK's native libraries: ${abis}"
        fi
    fi
    log_pass "--arch ${ARCH} matches the supplied artifact"
}

# Gradle failed: "infra: <line>" for network, disk or memory; "source" only for a compiler or resource
# diagnostic (Kotlin e:, javac error, AAPT, script compile); else "unknown". A bare task failure is unknown.
gradle_failure_kind() {
    local log="$1" hit
    [[ -s "$log" ]] || { echo unknown; return; }
    hit="$(grep -m1 -E 'Could not (resolve|GET|HEAD|download)|Connect(ion)? (refused|timed out|reset)|Read timed out|UnknownHostException|SSLHandshake|Received status code [45][0-9][0-9]|No space left on device|OutOfMemoryError|Java heap space|Metaspace|Failed to install the following' "$log" || true)"
    if [[ -n "$hit" ]]; then echo "infra: ${hit:0:160}"
    elif grep -qE '^e: (file:|/)|\.(java|kt):[0-9]+: error:|Compilation failed; see the compiler error|Script compilation error|AAPT: error:|Android resource linking failed' "$log"; then echo source
    else echo unknown; fi
}

build() {
    log_info "=== BUILD PHASE ==="
    create_dockerfile "${WORK_DIR}/Dockerfile"
    IMAGE_NAME="localhost/bitbanana-build:$(ws_sanitize "$VERSION")-${WS_RUN_ID}"

    log_info "Building container image (no cache): ${IMAGE_NAME}"
    ws_track_image "${IMAGE_NAME}"
    ws_ctr build --no-cache \
        --build-arg VERSION="${VERSION}" \
        --build-arg REPO_URL="${REPO_URL}" \
        --build-arg BUNDLETOOL_VERSION="${BUNDLETOOL_VERSION}" \
        --build-arg BUNDLETOOL_SHA256="${BUNDLETOOL_SHA256}" \
        -t "${IMAGE_NAME}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}" \
        || ws_no_verdict "Container image build failed for v${VERSION} (clone of the tag, SDK or bundletool download)."

    # Both upstream playbooks build through disorderfs with sorted directory entries; that
    # ordering is the reproducibility mechanism and is reproduced here unchanged.
    local -a run_args=()
    local cmd='set -euo pipefail
cp /commit.txt /out/commit.txt
mkdir -p /app
disorderfs --sort-dirents=yes --reverse-dirents=no /app-src/ /app/
cd /app
# Gradle output goes live to the cast and to /out/gradle.log. Exit 90 = the log could not be written.
run_gradle() {
  set +e; gradle "$@" --no-daemon 2>&1 | tee /out/gradle.log; local st=("${PIPESTATUS[@]}"); set -e
  [ "${st[1]}" -eq 0 ] || { echo "[ERROR] tee exit ${st[1]}: Gradle log not written"; exit 90; }
  [ "${st[0]}" -eq 0 ] || exit "${st[0]}"
  touch /out/.gradle-ok
}
touch /out/.gradle-started
'
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        log_info "Running build in container (disorderfs + gradle assembleRelease, per docs/REPRODUCE_GITHUB.md)"
        cmd+='run_gradle clean assembleRelease
apk="$(find app/build/outputs/apk/release -name "*-release-unsigned.apk" | head -n1)"
[ -n "$apk" ] || { echo "No unsigned release APK produced"; exit 1; }
touch /out/.gradle-done
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
        cmd+='run_gradle clean bundleRelease
aab="$(find app/build/outputs/bundle/release -name "*.aab" | head -n1)"
[ -n "$aab" ] || { echo "No AAB produced"; exit 1; }
touch /out/.gradle-done
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
    # Build record (#1000), after the APKs are in /out/splits: reads the Gradle cache this build
    # filled (fresh in every container) and the checkout's committed binaries. Never changes the
    # build output or the verdict.
    cmd+='
if curl -fsSL --max-time 60 -o /tmp/ws-buildlock.sh "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BL_REV}/scripts/rb/ws-buildlock.sh" \
   && echo "${BL_SHA}  /tmp/ws-buildlock.sh" | sha256sum -c --quiet -; then
  bash /tmp/ws-buildlock.sh --out /build-lock --gradle-home "${GRADLE_USER_HOME:-$HOME/.gradle}" --src /app-src \
    --app-id "${BL_APP_ID}" --version "${BL_VERSION}" --platform android --commit "$(cat /commit.txt)" \
    || echo "[WARN] ws-buildlock.sh failed; no build-lock.json, verdict unaffected"
else
  echo "[WARN] build-lock skipped: could not fetch ws-buildlock.sh with the expected sha256"
fi'
    run_args+=(-v "${WORK_DIR}/build-lock:/build-lock")
    run_args+=(-e "BL_REV=${BUILDLOCK_REV}" -e "BL_SHA=${BUILDLOCK_SHA256}" -e "BL_APP_ID=${APP_ID}" -e "BL_VERSION=${VERSION}")

    local rc=0
    crun \
        --device /dev/fuse --cap-add SYS_ADMIN \
        -v "${WORK_DIR}/built:/out" \
        ${run_args[@]+"${run_args[@]}"} \
        "${IMAGE_NAME}" bash -c "$cmd" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        # 125-127: the engine could not start the container; 137/143: killed (memory, stop).
        case "$rc" in
            125|126|127|137|143) ws_no_verdict "Build container failed (exit ${rc}): engine or host problem, not the source." ;;
            90) ws_no_verdict "Gradle log could not be written (tee failed); Gradle's result is unknown." ;;
        esac
        [[ -f "${WORK_DIR}/built/.gradle-started" ]] \
            || ws_no_verdict "Build container failed (exit ${rc}) before Gradle started (disorderfs or setup)."
        [[ ! -f "${WORK_DIR}/built/.gradle-done" ]] \
            || ws_no_verdict "Build container failed (exit ${rc}) after Gradle succeeded (bundletool or copy step)."
        # Gradle exited 0 but left no APK/AAB: the source's build config, not the host.
        [[ ! -f "${WORK_DIR}/built/.gradle-ok" ]] \
            || fail_ftbfs "Gradle succeeded but produced no ${INPUT_KIND} output for v${VERSION}."
        local kind; kind="$(gradle_failure_kind "${WORK_DIR}/built/gradle.log")"
        case "$kind" in
            source) fail_ftbfs "Build failed for v${VERSION} (${INPUT_KIND}): Gradle task or compile error, exit ${rc}." ;;
            infra*) ws_no_verdict "Gradle failed (exit ${rc}) on a host or network problem: ${kind#infra: }" ;;
            *)      ws_no_verdict "Gradle failed (exit ${rc}) with no recognised cause; check ${WORK_DIR}/built/gradle.log." ;;
        esac
    fi

    shopt -s nullglob
    local built=("${WORK_DIR}/built/splits"/*.apk)
    shopt -u nullglob
    [[ ${#built[@]} -gt 0 ]] || fail_ftbfs "The build produced no APK."

    if [[ -f "${WORK_DIR}/built/commit.txt" ]]; then
        IFS= read -r COMMIT_HASH < "${WORK_DIR}/built/commit.txt"
    fi
    COMMIT_HASH="${COMMIT_HASH:-unknown}"
    if [[ -f "${WORK_DIR}/build-lock/build-lock.json" ]]; then
        BUILD_LOCK_FILE="${WORK_DIR}/build-lock/build-lock.json"
        log_pass "build-lock.json: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
    else
        log_warn "No build-lock.json produced; the verdict is unaffected."
    fi

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
                > comparison/diff_${tag}.txt 2>&1 || true" \
            || ws_no_verdict "could not unzip or diff ${name}"

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

# Text under "Diff:" in the results block: 5 lines of the full diff and its path, then the
# accepted classes, the resources.arsc evidence and the revision.
diff_section() {
    local aggregate="${WORK_DIR}/comparison/diff_all.txt"
    if [[ -s "$aggregate" ]]; then
        ws_diff_preview "$aggregate"
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
    if [[ -n "$ARSC_SUMMARY" ]]; then
        echo ""
        echo "resources.arsc (decoded, per APK):"
        printf '%s' "$ARSC_SUMMARY"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Built from tag v${VERSION} at commit ${COMMIT_HASH}."
    echo "No git tag signature check is performed by this script."
    if [[ -n "$MISSING_NOTE" ]]; then
        echo ""
        echo "Also: ${MISSING_NOTE}"
    fi
}

print_results_block() {
    local verdict="$1" f n
    echo ""
    ws_results_block "${APP_ID_FROM_APK:-$APP_ID}" "${SIGNER_SHA256}" "${APK_VERSION_NAME}" \
        "${APK_VERSION_CODE}" "${verdict}" "${OFFICIAL_APP_HASH:-N/A}" "${COMMIT_HASH}" "$(diff_section)"
    echo ""
    echo "inputKind:      ${INPUT_KIND:-unknown}"
    if [[ "$INPUT_KIND" == "fat-apk" ]]; then
        echo "splitGenFlags:  n/a (fat APK: gradle assembleRelease, no bundletool)"
    elif [[ "$LOCALE_ALIGN" == "true" ]]; then
        echo "splitGenFlags:  -Djava.locale.useOldISOCodes=true (bundletool only; Gradle build unmodified)"
    else
        echo "splitGenFlags:  none (locale alignment disabled)"
    fi
    echo "Official APK hashes (as supplied):"
    for f in "${OFFICIAL_SPLITS[@]}"; do
        n="$(basename "$f")"; [[ "$n" == "app.apk" ]] && n="${OFFICIAL_NAME} (copied to app.apk)"
        echo "  ${n}  $(ws_sha256 "$f")"
    done
    echo "Built APK hashes (unsigned):"
    shopt -s nullglob
    for f in "${WORK_DIR}/built/splits"/*.apk; do
        echo "  $(basename "$f")  $(ws_sha256 "$f")"
    done
    shopt -u nullglob
    echo "Hash legend: appHash is the official artifact exactly as supplied (base.apk of a split set, or"
    echo "the single APK) and is the value to publish. Built APKs are unsigned: upstream declares no signingConfig."
    echo "libVersion/libHash: the shared library this run loaded."
    printf 'Run a full\ndiff --recursive %s/comparison/official-unzipped %s/comparison/built-unzipped\nmeld %s/comparison/official-unzipped %s/comparison/built-unzipped\nor\ndiffoscope "%s" "%s"\nfor more details.\n' \
        "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" "${WORK_DIR}" \
        "${OFFICIAL_BASE}" "${WORK_DIR}/built/splits/$(basename "$OFFICIAL_BASE")"
}

result() {
    log_info "=== RESULTS ==="
    local verdict rc
    if [[ "${DIFF_COUNT}" -eq 0 ]]; then
        verdict="reproducible"; rc="$WS_EXIT_OK"
        log_pass "VERDICT: REPRODUCIBLE"
    else
        verdict="not_reproducible"; rc="$WS_EXIT_FAIL"
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
    yaml_hashes
    ws_write_yaml "${verdict}" "$(yaml_notes "${notes}")" ${YAML_HASHES[@]+"${YAML_HASHES[@]}"}

    print_results_block "${verdict}"

    log_info "Workspace preserved: ${WORK_DIR}"
    if [[ -n "$BUILD_LOCK_FILE" ]]; then
        echo "Upload with the verification: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
    fi
    exit "$rc"
}

main() {
    ws_warn "This script is provided as-is. Review before running. Use at your own risk."
    ws_refuse_root
    ws_install_traps
    parse_arguments "$@"
    ws_results_init        # one run per script folder; stale COMPARISON_RESULTS.yaml removed
    ws_engine
    prepare
    build
    compare
    result
}
main "$@"
