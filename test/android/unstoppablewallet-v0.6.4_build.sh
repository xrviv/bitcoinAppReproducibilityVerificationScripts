#!/usr/bin/env bash
# unstoppablewallet_build.sh - Unstoppable Wallet Reproducible Build Verification
# Version:       v0.6.4
# Organization:  WalletScrutiny.com
# License:       MIT
# Last modified by: Bob (WalletScrutiny agent)
# Last modified on: 2026-10-07
# Project:       https://github.com/horizontalsystems/unstoppable-wallet-android
# Host deps:     docker or podman only
# Disclaimer:    Provided as-is, without warranty. It checks whether the published APK matches a build
#                of the tagged source; it does not audit the code. Use at your own risk.
# Notes:         --binary = DIRECTORY of device-pulled Play splits => AAB + bundletool per-split compare;
#                or ONE fat GitHub release APK (Zapstore ships it; installed as base.apk) =>
#                whole-APK compare. Flavor by GitHub asset digest (google_play => assembleBaseRelease,
#                github => assembleFdroidRelease), else by the flavor's BuildConfig key in the DEX.
#                Lone Play base.apk, config split, non-upstream signer (F-Droid store build): exit 2.
#                zano-kit built, ~290 MB prebuilt .a trusted; thorchain-kit built and published locally.

SCRIPT_VERSION="v0.6.4"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
if [[ -f "$SCRIPT_PATH" ]]; then
    SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
else
    SCRIPT_SHA256="N/A"
fi
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

set -uo pipefail   # no -e: diff/cmp return 1 on differences

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="io.horizontalsystems.bankwallet"
UPSTREAM_SIGNER="c1899493e440489178b8748851b72cbed50c282aaa8c03ae236a4652f8c4f27b"   # GitHub + Play releases
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

HB="############################################################"
SB="------------------------------------------------------------"
banner()  { printf '\n\n%s\n##\n##  %s\n##\n%s\n' "$HB" "$*" "$HB"; }
section() { printf '\n%s\n  %s\n%s\n' "$SB" "$*" "$SB"; }

sha256of() { sha256sum "$1" | awk '{print $1}'; }

execution_dir="$SCRIPT_DIR"
RESULT_DONE=0
rm -f "${execution_dir}/COMPARISON_RESULTS.yaml"   # never leave a previous run's verdict for ABS

write_yaml() {
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: $1
notes: |
  $2
EOF
    RESULT_DONE=1
    log_info "COMPARISON_RESULTS.yaml verdict: $1"
}
# die <code> <note>: ftbfs YAML, then exit (2 = bad input/env, 1 = build/compare failure)
die() { write_yaml ftbfs "$2"; echo ""; echo "Exit code: $1"; exit "$1"; }

if [[ "$EUID" -eq 0 ]]; then
    log_error "Do not run this script as root."
    die 2 "Script was run as root; refusing to proceed"
fi


version_arg=""
apk_file=""
device_sdk_arg=""

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        die 2 "${flag} requires a value"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)  require_arg --version "${2:-}"; version_arg="$2";  shift 2 ;;
        --binary)   require_arg --binary  "${2:-}"; apk_file="$2";     shift 2 ;;
        --apk)      require_arg --apk     "${2:-}"; apk_file="$2";     shift 2 ;;
        --arch|--type) require_arg "$1" "${2:-}"; log_info "$1 $2 accepted (configs come from the official APK)"; shift 2 ;;
        --device-sdk) require_arg --device-sdk "${2:-}"; device_sdk_arg="$2"; shift 2 ;;
        -h|--help)  echo "Usage: $SCRIPT_NAME --binary <split-dir|fat-apk> [--version v]"; exit 0 ;;
        *)
            log_warn "Unknown parameter ignored: $1"
            shift
            ;;
    esac
done

DEVICE_SDK="${device_sdk_arg:-${WS_DEVICE_SDK:-36}}"
if [[ ! "$DEVICE_SDK" =~ ^[0-9]+$ || "$DEVICE_SDK" -lt 21 || "$DEVICE_SDK" -gt 99 ]]; then
    die 2 "Invalid Android device SDK/API level (21-99): ${DEVICE_SDK}"
fi

if [[ -z "$apk_file" ]]; then
    log_error "--binary is required: the device-pulled split directory or one GitHub release APK."
    die 2 "--binary not provided; cannot proceed without the official APK(s)"
fi

declare -a OFFICIAL_SPLITS=() OFF_MOUNT=()
INPUT_MODE=""
if [[ -d "$apk_file" ]]; then
    INPUT_MODE=splits
    OFFICIAL_DIR=$(realpath "$apk_file")
    [[ -f "$OFFICIAL_DIR/base.apk" ]] || { log_error "base.apk not found in $OFFICIAL_DIR (required)"
        die 2 "Split set missing base.apk in ${OFFICIAL_DIR}"; }
    while IFS= read -r f; do OFFICIAL_SPLITS+=("$f"); done \
        < <(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.apk" | sort)
    for f in "${OFFICIAL_SPLITS[@]}"; do   # reject stray APKs
        bn=$(basename "$f")
        [[ "$bn" == "base.apk" || "$bn" == split_config*.apk ]] || {
            log_error "Unexpected APK in split dir: $bn (only base.apk + split_config*.apk allowed)"
            die 2 "Unexpected APK in split dir: ${bn}"; }
    done
    abi_split=0; for f in "$OFFICIAL_DIR"/split_config.{arm64_v8a,armeabi_v7a,x86_64,x86}.apk; do [[ -f "$f" ]] && abi_split=1; done
    [[ "$abi_split" -eq 1 ]] || {
        die 2 "Split directory has no ABI split (split_config.<abi>.apk); pass the full device-pulled set"; }
    apk_file="$OFFICIAL_DIR/base.apk"   # base.apk drives Phase 0 metadata
    OFF_MOUNT=(-v "${OFFICIAL_DIR}:/official:ro")
    log_info "${#OFFICIAL_SPLITS[@]} official split(s) in ${OFFICIAL_DIR}"
elif [[ -f "$apk_file" ]]; then
    INPUT_MODE=fat
    apk_file=$(realpath "$apk_file")
    OFFICIAL_SPLITS=("$apk_file")
    OFF_MOUNT=(-v "${apk_file}:/official/official.apk:ro")
    log_info "Single APK: ${apk_file} (kind decided in Phase 0)"
else
    die 2 "--binary is neither a split directory nor an APK file: ${apk_file}"
fi

if [[ -z "${CRUN:-}" ]]; then
    if command -v docker &>/dev/null; then
        CRUN=docker
    elif command -v podman &>/dev/null; then
        CRUN=podman
    else
        log_error "Neither docker nor podman found in PATH"
        die 2 "Neither docker nor podman found in PATH"
    fi
fi

MEM_ARGS=(--memory="${MEM_LIMIT:-20g}")
ROOTLESS=0
if [[ "$CRUN" == podman ]]; then
    [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == true ]] && ROOTLESS=1
elif docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then ROOTLESS=1; fi

RUN_ID="$(date +%s)-$$"
IMG_P3="ws-unstoppable-source-${RUN_ID}"
CTR_P0="ws-unstoppable-p0-${RUN_ID}"
CTR_P3="ws-unstoppable-source-ctr-${RUN_ID}"
CTR_P5="ws-unstoppable-p5-${RUN_ID}"

# Per-run workspace in the caller's directory (helper scripts inside, no /tmp).
workspace="$(pwd -P)/unstoppable_verification_${version_arg:-unknown}_${RUN_ID}"
P0_DIR="${workspace}/metadata"
P3_DIR="${workspace}/source-build"
P5_DIR="${workspace}/comparison"
ctx="${workspace}/ctx"

ensure_user_ownership() {
    local path="$1" image="$2" own="${HOST_UID}:${HOST_GID}"
    [[ -e "$path" ]] || return 0
    # Rootless runtime: container root == caller, so chown 0:0 (a host uid would land in the subuid range).
    [[ "$ROOTLESS" -eq 1 ]] && own="0:0"
    if [[ "$CRUN" == podman && "$ROOTLESS" -eq 1 ]]; then
        podman unshare chown -R 0:0 "$path" >/dev/null 2>&1 || log_warn "Could not fix ownership for ${path}"
    elif [[ -n "$image" ]]; then
        $CRUN run --rm -v "${path}:/target" "$image" sh -c "chown -R ${own} /target" >/dev/null 2>&1 || \
            log_warn "Could not fix ownership for ${path}"
    fi
    local stray; stray=$(find "$path" ! -uid "$HOST_UID" -print -quit 2>/dev/null)
    [[ -n "$stray" ]] && log_warn "Not caller-owned: ${stray}"; return 0
}

cleanup() {
    [[ "$RESULT_DONE" -eq 1 ]] || write_yaml ftbfs "Run ended before a verdict was written (interrupted or internal error)"
    $CRUN rm -f "$CTR_P0" "$CTR_P3" "$CTR_P5" 2>/dev/null || true
    local own_image=""; $CRUN image inspect "$IMG_P3" >/dev/null 2>&1 && own_image="$IMG_P3"
    ensure_user_ownership "$workspace" "$own_image"
    $CRUN rmi -f "$IMG_P3" 2>/dev/null || true
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

mkdir -p "$P0_DIR" "$P3_DIR" "$P5_DIR" "$ctx"

banner "UNSTOPPABLE WALLET REPRODUCIBLE BUILD VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}   App ID: ${APP_ID}   Device SDK: ${DEVICE_SDK}"
echo "  APK:       ${apk_file}"
echo "  Runtime:   ${CRUN} ($($CRUN --version 2>&1 | head -1)), rootless=${ROOTLESS}"
echo "  Workspace: ${workspace}   Date: $(date)"

banner "SETUP: BUILD CONTAINER IMAGE ($(date))"

cat > "$ctx/Dockerfile" <<'DOCKERFILE_P3'
# ubuntu:24.04 (noble) multi-arch index digest, pinned 2026-10-07
FROM docker.io/library/ubuntu@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-8-jdk-headless openjdk-17-jdk-headless \
        git unzip wget ca-certificates cmake && \
    rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
        -O cmdline-tools.zip && \
    unzip cmdline-tools.zip && rm cmdline-tools.zip && mv cmdline-tools latest

RUN yes | sdkmanager --licenses && \
    sdkmanager \
        "platforms;android-33" "platforms;android-34" \
        "platforms;android-35" "platforms;android-36" "platforms;android-37.0" \
        "build-tools;30.0.3" "build-tools;34.0.0" \
        "build-tools;35.0.0" "build-tools;36.0.0" \
        "ndk;23.1.7779620" "ndk;25.1.8937393" "ndk;29.0.14033849" \
        "ndk;27.0.12077973" \
        "cmake;3.22.1"

ADD https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar /opt/bundletool.jar
ADD https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar /opt/apktool.jar
RUN echo "2d4ad908faea64047c1cc9cb747e6aa667c6ab192e09607bd16b67246a8cd6ae  /opt/bundletool.jar" | sha256sum -c - && \
    echo "dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423  /opt/apktool.jar" | sha256sum -c -

WORKDIR /build
DOCKERFILE_P3

section "Building source-build image: ${IMG_P3}"
if ! $CRUN build -t "$IMG_P3" -f "$ctx/Dockerfile" "$ctx"; then
    die 1 "Source-build container image failed"
fi

banner "PHASE 0: APK METADATA EXTRACTION ($(date))"

cat > "$ctx/extract_meta.sh" <<'META_SCRIPT'
#!/bin/bash
set -euo pipefail

AAPT2="${ANDROID_HOME}/build-tools/36.0.0/aapt2"
APKSIGNER="${ANDROID_HOME}/build-tools/36.0.0/apksigner"

apk_info=$("${AAPT2}" dump badging /input/official.apk 2>/dev/null || true)
version_name=$(echo "$apk_info" | grep -oP "versionName='[^']+'" | sed "s/versionName='//;s/'$//" || true)
version_code=$(echo "$apk_info" | grep -oP "versionCode='[^']+'" | sed "s/versionCode='//;s/'$//" || true)
signer_output=$("${APKSIGNER}" verify --verbose --print-certs /input/official.apk 2>&1) || {
    echo "ERROR: official base.apk signature verification failed"
    printf '%s\n' "$signer_output"
    exit 1
}
# "Signer #1" or rotated SDK-range labels; SourceStamp excluded.
signer_hash=$(printf '%s\n' "$signer_output" \
    | sed -nE '/^Signer( #[0-9]+| \(minSdkVersion=[^)]*\)) certificate SHA-256 digest:/ {s/.*digest: //;p;}' \
    | sort -u | paste -sd, -)

pkg_name=$(echo "$apk_info" | grep -oP "^package: name='[^']+'" | sed "s/^package: name='//;s/'$//" || true)
split_name=$(echo "$apk_info" | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)
abis=$(echo "$apk_info" | sed -n "s/^native-code: //p" | tr -d "'" | head -1)
echo "${split_name}" > /output/split_name.txt
echo "${abis}"       > /output/abis.txt
# bundletool output has splits0.xml or a SourceStamp; Gradle fat APKs do not.
unzip -l /input/official.apk 2>/dev/null | grep -qE ' (res/xml/splits0\.xml|stamp-cert-sha256)$' && echo 1 > /output/universal.txt || echo 0 > /output/universal.txt
# Release asset digests (sha256 name) for flavor detection; GITHUB_TOKEN optional.
hdr=(); [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(--header="Authorization: Bearer ${GITHUB_TOKEN}")
wget -qO- --timeout=30 "${hdr[@]}" "https://api.github.com/repos/horizontalsystems/unstoppable-wallet-android/releases/tags/${version_name}" 2>/dev/null \
  | grep -oE '"(name|digest)": *"[^"]*"' | awk -F'"' '$2=="name"{n=$4} $2=="digest"{sub(/^sha256:/,"",$4); print $4, n}' > /output/gh_assets.txt || true
echo "[META] GitHub release ${version_name}: $(wc -l < /output/gh_assets.txt) asset digest(s)"

echo "${version_name:-unknown}" > /output/version_name.txt
echo "${version_code:-unknown}" > /output/version_code.txt
echo "${signer_hash:-unknown}"  > /output/signer.txt
echo "${pkg_name:-unknown}"     > /output/pkg_name.txt

echo "[META] ${pkg_name:-unknown} versionName=${version_name:-unknown} versionCode=${version_code:-unknown} signer=${signer_hash:-unknown} split=${split_name:-<none>} native-code=${abis:-<none>}"
META_SCRIPT
chmod +x "$ctx/extract_meta.sh"

if ! $CRUN run \
    --rm \
    --name "$CTR_P0" \
    "${MEM_ARGS[@]}" \
    -v "${apk_file}:/input/official.apk:ro" \
    -v "${P0_DIR}:/output" \
    -e GITHUB_TOKEN \
    -v "${ctx}/extract_meta.sh:/extract_meta.sh:ro" \
    "$IMG_P3" \
    bash /extract_meta.sh; then
    die 2 "APK metadata extraction failed (not a valid, signed APK?)"
fi

wallet_version=$(cat "${P0_DIR}/version_name.txt" 2>/dev/null || echo "unknown")
version_code=$(cat   "${P0_DIR}/version_code.txt"  2>/dev/null || echo "unknown")
signer=$(cat          "${P0_DIR}/signer.txt"        2>/dev/null || echo "unknown")
app_hash=$(sha256of "$apk_file")

pkg_id=$(cat "${P0_DIR}/pkg_name.txt" 2>/dev/null || echo "unknown")
if [[ "$pkg_id" != "$APP_ID" ]]; then
    log_error "APK app ID mismatch: expected $APP_ID, got ${pkg_id}"
    die 2 "APK app ID mismatch: expected $APP_ID, got ${pkg_id}"
fi
log_success "APK app ID verified: ${pkg_id}"
if [[ "$INPUT_MODE" == fat ]]; then
    split_name=$(cat "${P0_DIR}/split_name.txt" 2>/dev/null); abis=$(cat "${P0_DIR}/abis.txt" 2>/dev/null)
    if [[ -n "$split_name" ]]; then
        log_error "Single APK is the config split '${split_name}'; it cannot be verified alone."
        die 2 "Single APK is config split '${split_name}'; pass the whole split directory (base.apk + split_config.*)"
    elif [[ -z "$abis" ]]; then
        log_error "Single APK has no native libraries: a lone Play base.apk cannot be verified alone."
        die 2 "Single APK is a lone Play base.apk (no native libs); pass the whole split directory (base.apk + split_config.*)"
    fi
    # Kind by evidence, not file name: asset digest first, then the DEX key literal (in-container).
    gh_asset=$(awk -v h="$app_hash" '$1==h{print $2; exit}' "${P0_DIR}/gh_assets.txt" 2>/dev/null)
    case "$gh_asset" in
        *_google_play_*) FLAVOR=base;   KIND_RULE="sha256 = GitHub release asset ${gh_asset}" ;;
        *_github_*)      FLAVOR=fdroid; KIND_RULE="sha256 = GitHub release asset ${gh_asset}" ;;
        "") [[ "$(cat "${P0_DIR}/universal.txt" 2>/dev/null)" == 1 ]] && die 2 "Single APK is a bundletool universal APK (splits0.xml/SourceStamp), not a GitHub release asset; pass the Play split directory"
            if [[ "$signer" != "$UPSTREAM_SIGNER" ]]; then
                die 2 "Fat APK is neither a GitHub release asset nor upstream-signed (signer ${signer}; F-Droid store build? use unstoppablefdroid_build.sh)"
            fi
            FLAVOR=auto; KIND_RULE="no GitHub asset digest match; upstream-signed; flavor from the BuildConfig key literal in the official DEX" ;;
        *)  die 2 "Unrecognised GitHub release asset (neither google_play nor github flavor): ${gh_asset}" ;;
    esac
    log_success "Fat APK (ABIs: ${abis}), flavor ${FLAVOR}: ${KIND_RULE}"
else
    FLAVOR=base; KIND_RULE="directory input = Play split set (AAB + bundletool, base flavor)"
fi

log_success "APK metadata: v${wallet_version} (code ${version_code}), signer ${signer}"
log_info    "Official APK SHA-256 (appHash = first line):"
for official_split in "${OFFICIAL_SPLITS[@]}"; do
    printf '  %s  %s\n' "$(sha256of "$official_split")" "$(basename "$official_split")"
done

banner "PHASE 1: HS DEPS FROM SOURCE + WALLET BUILD ($(date))"

cat > "$ctx/build.sh" <<'BUILD_SCRIPT_END'
#!/bin/bash
set -euxo pipefail

GH="https://github.com/horizontalsystems"
ORIG_PATH="$PATH"

clone_at_commit() {
    local url="$1" commit="$2" dir="$3"
    git clone "$url" "$dir"
    git -C "$dir" checkout "$commit"
    git -C "$dir" submodule update --init --recursive
}

# Version catalog (gradle/libs.versions.toml, wallet >= 0.48.0): module -> version.ref -> version.
extract_wallet_hs_version() {
    local toml="/build/wallet/gradle/libs.versions.toml" ref
    ref=$(grep -E "module\s*=\s*\"com\.github\.horizontalsystems:$1\"" "$toml" \
          | sed -E 's/.*version\.ref\s*=\s*"([^"]+)".*/\1/' | head -1 || true)
    [[ -n "$ref" ]] || return 0   # empty -> caught by require_nonempty
    grep -E "^\s*${ref}\s*=" "$toml" | sed -E 's/.*=\s*"([^"]+)".*/\1/' | head -1 || true
}

# ensure_pub <build.gradle> <artifactId> <version> [sv]: maven-publish + release publication at <version>;
# sv adds the AGP 8 singleVariant opt-in.
ensure_pub() {
    local g="$1" a="$2" v="$3"
    grep -qF "maven-publish" "$g" || sed -i "/plugins {/a\\    id 'maven-publish'" "$g"
    [[ "${4:-}" == sv ]] && { grep -qF "singleVariant('release')" "$g" || sed -i "/^android {/a\\    publishing { singleVariant('release') }" "$g"; }
    if grep -qF "release(MavenPublication)" "$g"; then
        sed -i "/artifactId = '$a'/{n;s/version = '[^']*'/version = '$v'/;}" "$g"
    else
        printf "\nafterEvaluate {\n    publishing {\n        publications {\n            release(MavenPublication) {\n                from components.release\n                groupId = 'com.github.horizontalsystems'\n                artifactId = '%s'\n                version = '%s'\n            }\n        }\n    }\n}\n" "$a" "$v" >> "$g"
    fi
    grep -qF "version = '$v'" "$g" || { echo "ERROR: $a publication version not set to $v"; exit 1; }
}

require_nonempty() {
    local name="$1" value="$2"
    if [[ -z "$value" ]]; then
        echo "ERROR: Could not derive ${name} from wallet dependencies"
        exit 1
    fi
}

create_root_pom() {
    local group="$1" artifact="$2" version="$3" subgroup="$4"
    shift 4
    local modules=("$@")
    local group_path="${group//./\/}"
    local pom_dir="$HOME/.m2/repository/${group_path}/${artifact}/${version}"
    mkdir -p "$pom_dir"
    local pom_file="${pom_dir}/${artifact}-${version}.pom"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0">\n<modelVersion>4.0.0</modelVersion>\n<groupId>%s</groupId><artifactId>%s</artifactId><version>%s</version><packaging>pom</packaging>\n<dependencies>\n' "$group" "$artifact" "$version"
        for mod in "${modules[@]}"; do
            printf '<dependency><groupId>%s</groupId><artifactId>%s</artifactId><version>%s</version><scope>compile</scope></dependency>\n' "$subgroup" "$mod" "$version"
        done
        printf '</dependencies>\n</project>\n'
    } > "$pom_file"
    local jar_file="${pom_dir}/${artifact}-${version}.jar"
    local tmpjar="/tmp/empty-jar-$$"
    mkdir -p "$tmpjar/META-INF"
    echo "Manifest-Version: 1.0" > "$tmpjar/META-INF/MANIFEST.MF"
    jar cfm "$jar_file" "$tmpjar/META-INF/MANIFEST.MF" -C "$tmpjar" META-INF
    rm -rf "$tmpjar"
    echo "Created root POM stub: ${group}:${artifact}:${version}"
}

echo ""; echo "=== Step 1: Clone all repos === $(date)"

git clone --depth 1 --branch __WALLET_VERSION__ "$GH/unstoppable-wallet-android.git" /build/wallet
WS_FLAVOR="${WS_FLAVOR:-base}"
if [[ "$WS_FLAVOR" == auto ]]; then
    # base/fdroid differ only in BuildConfig literals; exactly one flavor's USWAP key sits in the official DEX.
    kb=$(sed -nE 's/.*uswapApiKeyAndroid *= *"([^"]+)".*/\1/p' /build/wallet/app/build.gradle.kts | head -1)
    kf=$(sed -nE 's/.*uswapApiKeyFdroid *= *"([^"]+)".*/\1/p' /build/wallet/app/build.gradle.kts | head -1)
    mkdir -p /tmp/dx && unzip -qo -j /official/official.apk 'classes*.dex' -d /tmp/dx
    hb=0; hf=0
    [[ -n "$kb" ]] && hb=$(cat /tmp/dx/*.dex | grep -ac "$kb" || true)
    [[ -n "$kf" ]] && hf=$(cat /tmp/dx/*.dex | grep -ac "$kf" || true)
    if   (( hb > 0 && hf == 0 )); then WS_FLAVOR=base
    elif (( hf > 0 && hb == 0 )); then WS_FLAVOR=fdroid
    else echo "ERROR: flavor undetermined (DEX hits: base key $hb, fdroid key $hf)"; exit 64; fi
    echo "Flavor by BuildConfig USWAP key literal in the official DEX: $WS_FLAVOR (base $hb, fdroid $hf)"
fi
echo "$WS_FLAVOR" > /output/flavor.txt
[[ -f /build/wallet/gradle/libs.versions.toml ]] || { echo "ERROR: no gradle/libs.versions.toml (wallet < 0.48.0 is not supported)"; exit 1; }
# The tag must describe the APK: defaultConfig versionName/versionCode vs the official APK's.
src_vn=$(sed -nE 's/^\s*versionName = "([^"]+)".*/\1/p' /build/wallet/app/build.gradle.kts | head -1)
src_vc=$(sed -nE 's/^\s*versionCode = ([0-9]+).*/\1/p' /build/wallet/app/build.gradle.kts | head -1)
echo "Tag __WALLET_VERSION__ source: versionName=$src_vn versionCode=$src_vc | official APK: ${WS_VERSION_NAME:-?} / ${WS_VERSION_CODE:-?}"
[[ "$src_vn" == "${WS_VERSION_NAME:-}" && "$src_vc" == "${WS_VERSION_CODE:-}" ]] || { echo "ERROR: tag __WALLET_VERSION__ does not describe the official APK"; exit 65; }

compile_sdk=$(sed -nE 's/^[[:space:]]*compileSdk[[:space:]]*=[[:space:]]*"([0-9]+)".*/\1/p' \
    /build/wallet/gradle/libs.versions.toml | head -1)
require_nonempty "compileSdk" "$compile_sdk"
platform_dir=$(find "$ANDROID_HOME/platforms" -maxdepth 1 -type d \
    \( -name "android-${compile_sdk}" -o -name "android-${compile_sdk}.0" \) -print -quit)
[[ -n "$platform_dir" ]] || { echo "ERROR: compileSdk ${compile_sdk} not installed under $ANDROID_HOME/platforms"; exit 1; }
echo "Compile SDK ${compile_sdk} present: ${platform_dir}"

MONERO_VER=$(extract_wallet_hs_version "monero-kit-android")
STELLAR_VER=$(extract_wallet_hs_version "stellar-kit-android")
TON_VER=$(extract_wallet_hs_version "ton-kit-android")
BITCOIN_VER=$(extract_wallet_hs_version "bitcoin-kit-android")
ETHEREUM_VER=$(extract_wallet_hs_version "ethereum-kit-android")
FEERATE_VER=$(extract_wallet_hs_version "blockchain-fee-rate-kit-android")
MARKET_VER=$(extract_wallet_hs_version "market-kit-android")
SOLANA_VER=$(extract_wallet_hs_version "solana-kit-android")
TRON_VER=$(extract_wallet_hs_version "tron-kit-android")
ZANO_VER=$(extract_wallet_hs_version "zano-kit-android")
HD_WALLET_VER=$(extract_wallet_hs_version "hd-wallet-kit-android" || true)
THORCHAIN_VER=$(extract_wallet_hs_version "thorchain-kit-android" || true)

for kv in monero:$MONERO_VER stellar:$STELLAR_VER ton:$TON_VER bitcoin:$BITCOIN_VER ethereum:$ETHEREUM_VER \
          blockchain-fee-rate:$FEERATE_VER market:$MARKET_VER solana:$SOLANA_VER tron:$TRON_VER zano:$ZANO_VER; do
    require_nonempty "${kv%%:*}-kit-android version" "${kv#*:}"
done
echo "Derived HS versions (wallet version catalog): monero=$MONERO_VER stellar=$STELLAR_VER ton=$TON_VER" \
     "bitcoin=$BITCOIN_VER ethereum=$ETHEREUM_VER feerate=$FEERATE_VER market=$MARKET_VER solana=$SOLANA_VER" \
     "tron=$TRON_VER zano=$ZANO_VER hd-wallet=${HD_WALLET_VER:-<from deps>} thorchain=${THORCHAIN_VER:-<none>}"

clone_at_commit "$GH/ton-kit-android.git"                     "$TON_VER"      /build/deps/ton-kit-android
clone_at_commit "$GH/stellar-kit-android.git"                 "$STELLAR_VER"  /build/deps/stellar-kit-android
clone_at_commit "$GH/market-kit-android.git"                  "$MARKET_VER"   /build/deps/market-kit-android
clone_at_commit "$GH/blockchain-fee-rate-kit-android.git"     "$FEERATE_VER"  /build/deps/blockchain-fee-rate-kit-android
clone_at_commit "$GH/solana-kit-android.git"                  "$SOLANA_VER"   /build/deps/solana-kit-android
clone_at_commit "$GH/zano-kit-android.git"                    "$ZANO_VER"     /build/deps/zano-kit-android

clone_at_commit "$GH/bitcoin-kit-android.git"                 "$BITCOIN_VER"  /home/jitpack/build
clone_at_commit "$GH/ethereum-kit-android.git"                "$ETHEREUM_VER" /build/deps/ethereum-kit-android
clone_at_commit "$GH/tron-kit-android.git"                    "$TRON_VER"     /build/deps/tron-kit-android
clone_at_commit "$GH/monero-kit-android.git"                  "$MONERO_VER"   /build/deps/monero-kit-android
if [[ -n "$THORCHAIN_VER" ]]; then
    clone_at_commit "$GH/thorchain-kit-android.git"            "$THORCHAIN_VER" /build/deps/thorchain-kit-android
fi

for g in /home/jitpack/build/bitcoincore/build.gradle /build/deps/tron-kit-android/tronkit/build.gradle; do
    [[ -z "$HD_WALLET_VER" ]] || break
    HD_WALLET_VER=$(grep -Eo "com\\.github\\.horizontalsystems:hd-wallet-kit-android:[^\"']+" "$g" 2>/dev/null | head -1 | sed -E 's/.*:hd-wallet-kit-android://' || true)
done
require_nonempty "hd-wallet-kit-android version" "$HD_WALLET_VER"
echo "  hd-wallet-kit-android (resolved direct or dependency pin): $HD_WALLET_VER"
clone_at_commit "$GH/hd-wallet-kit-android.git" "$HD_WALLET_VER" /build/deps/hd-wallet-kit-android

echo "All repos cloned."

echo ""; echo "=== Step 2: hd-wallet-kit-android (Java 8) === $(date)"
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="$JAVA_HOME/bin:$ORIG_PATH"

cd /build/deps/hd-wallet-kit-android
sed -i "s/version '1.0.0'/version '$HD_WALLET_VER'/" build.gradle
./gradlew install --no-daemon
ls -la ~/.m2/repository/com/github/horizontalsystems/hd-wallet-kit-android/"$HD_WALLET_VER"/

echo ""; echo "=== Step 3: Switch to JDK 17 === $(date)"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$ORIG_PATH"
java -version

echo ""; echo "=== Step 4a: ton-kit-android === $(date)"
cd /build/deps/ton-kit-android
sed -i "s/from components.release/from components.release\\n                groupId = \\\"com.github.horizontalsystems\\\"\\n                artifactId = \\\"ton-kit-android\\\"\\n                version = \\\"$TON_VER\\\"/" tonkit/build.gradle
./gradlew :tonkit:publishToMavenLocal --no-daemon

if [[ -n "$THORCHAIN_VER" ]]; then
    echo ""; echo "=== Step 4b: thorchain-kit-android === $(date)"
    cd /build/deps/thorchain-kit-android
    sed -i '/maven.*jitpack/i\        mavenLocal()' settings.gradle
    sed -i -E "s/(com\\.github\\.horizontalsystems:hd-wallet-kit-android:)[^\"']+/\\1$HD_WALLET_VER/g" thorchainkit/build.gradle
    if grep -qF "artifactId = 'thorchain-kit-android'" thorchainkit/build.gradle; then
        sed -i "/artifactId = 'thorchain-kit-android'/{n;s/version = '[^']*'/version = '$THORCHAIN_VER'/;}" thorchainkit/build.gradle
    else
        sed -i "/from components.release/a\\                groupId = 'com.github.horizontalsystems'\\n                artifactId = 'thorchain-kit-android'\\n                version = '$THORCHAIN_VER'" thorchainkit/build.gradle
    fi
    grep -qF "version = '$THORCHAIN_VER'" thorchainkit/build.gradle || {
        echo "ERROR: thorchain-kit publication version not set to $THORCHAIN_VER"; exit 1; }
    ./gradlew :thorchainkit:publishToMavenLocal --no-daemon
fi

echo ""; echo "=== Step 4c: stellar-kit-android === $(date)"
cd /build/deps/stellar-kit-android
ensure_pub stellarkit/build.gradle stellar-kit-android "$STELLAR_VER"
./gradlew :stellarkit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4d: market-kit-android === $(date)"
cd /build/deps/market-kit-android
sed -i "s/version = '1.0.0'/version = '$MARKET_VER'/" marketkit/build.gradle
./gradlew :marketkit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4e: blockchain-fee-rate-kit-android === $(date)"
cd /build/deps/blockchain-fee-rate-kit-android
sed -i "s/artifactId = 'feeratekit'/artifactId = 'blockchain-fee-rate-kit-android'/" feeratekit/build.gradle
sed -i "s/version = '1.0.0'/version = '$FEERATE_VER'/" feeratekit/build.gradle
./gradlew :feeratekit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4f: solana-kit-android === $(date)"
cd /build/deps/solana-kit-android
sed -i "s/version = '1.0.0'/version = '$SOLANA_VER'/" solanakit/build.gradle
./gradlew :solanakit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4g: zano-kit-android === $(date)"
echo "  [BLOB CAVEAT] zano links prebuilt .a (Zano engine/Boost/OpenSSL), not rebuilt"
cd /build/deps/zano-kit-android
ensure_pub zanokit/build.gradle zano-kit-android "$ZANO_VER" sv   # AGP 8.11.1
./gradlew :zanokit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 5a: bitcoin-kit-android === $(date)"
cd /home/jitpack/build
sed -i '/maven.*jitpack/i\        mavenLocal()' build.gradle
for module in bitcoincore bitcoinkit bitcoincashkit dashkit ecashkit hodler litecoinkit; do
    sed -i -E "s/(com\\.github\\.horizontalsystems:hd-wallet-kit-android:)[^\"']+/\1$HD_WALLET_VER/g" "$module/build.gradle" 2>/dev/null || true
    sed -i "s/from components.release/from components.release\\n                groupId = \\\"com.github.horizontalsystems.bitcoin-kit-android\\\"\\n                version = \\\"$BITCOIN_VER\\\"/" "$module/build.gradle"
done
./gradlew publishToMavenLocal --no-daemon
create_root_pom \
    "com.github.horizontalsystems" "bitcoin-kit-android" "$BITCOIN_VER" \
    "com.github.horizontalsystems.bitcoin-kit-android" \
    bitcoincore bitcoinkit bitcoincashkit dashkit ecashkit hodler litecoinkit

echo ""; echo "=== Step 5b: ethereum-kit-android === $(date)"
cd /build/deps/ethereum-kit-android
sed -i '/maven.*jitpack/i\        mavenLocal()' build.gradle
for module in ethereumkit erc20kit uniswapkit oneinchkit nftkit merkleiokit; do
    sed -i -E "s/(com\\.github\\.horizontalsystems:hd-wallet-kit-android:)[^\"']+/\1$HD_WALLET_VER/g" "$module/build.gradle" 2>/dev/null || true
    sed -i "s/from components.release/from components.release\\n                groupId = \\\"com.github.horizontalsystems.ethereum-kit-android\\\"\\n                version = \\\"$ETHEREUM_VER\\\"/" "$module/build.gradle"
done
./gradlew publishToMavenLocal --no-daemon
create_root_pom \
    "com.github.horizontalsystems" "ethereum-kit-android" "$ETHEREUM_VER" \
    "com.github.horizontalsystems.ethereum-kit-android" \
    ethereumkit erc20kit uniswapkit oneinchkit nftkit merkleiokit

echo ""; echo "=== Step 5c: tron-kit-android === $(date)"
cd /build/deps/tron-kit-android
sed -i '/maven.*jitpack/i\        mavenLocal()' settings.gradle
sed -i -E "s/(com\\.github\\.horizontalsystems:hd-wallet-kit-android:)[^\"']+/\\1$HD_WALLET_VER/g" tronkit/build.gradle
sed -i "s/from components.release/from components.release\\n                groupId = \\\"com.github.horizontalsystems\\\"\\n                artifactId = \\\"tron-kit-android\\\"\\n                version = \\\"$TRON_VER\\\"/" tronkit/build.gradle
./gradlew :tronkit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 5d: monero-kit-android === $(date)"
cd /build/deps/monero-kit-android
sed -i '/maven.*jitpack/i\        mavenLocal()' settings.gradle
ensure_pub monerokit/build.gradle monero-kit-android "$MONERO_VER" sv   # AGP 8.11.1, like zano
./gradlew :monerokit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 6: Build wallet === $(date)"
cd /build/wallet
sed -i 's/org\.gradle\.jvmargs=.*/org.gradle.jvmargs=-Xmx4096M -Dkotlin.daemon.jvm.options="-Xmx4096M"/' gradle.properties
rm -rf ~/.gradle/caches/
mkdir -p /output/built-splits
if [[ "${WS_INPUT_MODE:-splits}" == fat ]]; then
    # build_apk.yml: assemble<Flavor>Release, then apksigner.
    ./gradlew ":app:assemble${WS_FLAVOR^}Release" --no-daemon --max-workers=2 --info > /output/wallet-build.log 2>&1
    find "app/build/outputs/apk/${WS_FLAVOR}/release" -name '*.apk' -exec cp -t /output/built-splits/ {} +
    echo "=== built fat APK ==="; ls -lh /output/built-splits/
else
    ./gradlew :app:bundleBaseRelease --no-daemon --max-workers=2 --info > /output/wallet-build.log 2>&1
    AAB=$(find app/build/outputs/bundle -name "*.aab" | head -1)
    cp "$AAB" /output/app-base-release.aab
    AAPT2=$(find "$ANDROID_HOME/build-tools" -name aapt2 | sort | tail -1)
    # device-spec from the official split= names (not universal).
    DABIS=(); DDEN=""; DLOC=()
    for f in /official/*.apk; do c=$("$AAPT2" dump badging "$f" 2>/dev/null | sed -n "s/.*split='config\.\([^']*\)'.*/\1/p" | head -1)
        case "$c" in
        "") ;; arm64_v8a) DABIS+=(arm64-v8a) ;; armeabi_v7a) DABIS+=(armeabi-v7a) ;; x86_64|x86|armeabi) DABIS+=("$c") ;;
        ldpi) DDEN=120 ;; mdpi) DDEN=160 ;; tvdpi) DDEN=213 ;; hdpi) DDEN=240 ;;
        xhdpi) DDEN=320 ;; xxhdpi) DDEN=480 ;; xxxhdpi) DDEN=640 ;;
        [a-z][a-z]|[a-z][a-z][a-z]) DLOC+=("$c") ;;
        *) echo "WARNING: unknown config split '$c' stays unmatched" ;;
        esac; done
    [[ -z "$DDEN" ]] && DDEN=480; [[ ${#DLOC[@]} -eq 0 ]] && DLOC=(en)
    # sdkVersion = DEVICE API level (not app targetSdk).
    DSDK="${WS_DEVICE_SDK:-34}"
    DABIJSON=$(printf '"%s",' "${DABIS[@]}"); DABIJSON="[${DABIJSON%,}]"
    DLOCJSON=$(printf '"%s",' "${DLOC[@]}"); DLOCJSON="[${DLOCJSON%,}]"
    printf '{"supportedAbis":%s,"supportedLocales":%s,"screenDensity":%s,"sdkVersion":%s}\n' \
        "$DABIJSON" "$DLOCJSON" "$DDEN" "$DSDK" > /tmp/device-spec.json
    cp /tmp/device-spec.json /output/device-spec.json
    echo "=== device-spec.json ==="; cat /tmp/device-spec.json
    java -jar /opt/bundletool.jar build-apks --bundle="$AAB" \
        --output=/output/built.apks --device-spec=/tmp/device-spec.json \
        --aapt2="$AAPT2" --overwrite
    mkdir -p /output/bt-extract
    unzip -o /output/built.apks 'splits/*.apk' -d /output/bt-extract
    cp /output/bt-extract/splits/*.apk /output/built-splits/
    echo "=== built splits ==="; ls -lh /output/built-splits/
fi

echo ""; echo "=== Step 7: Collect outputs === $(date)"
mkdir -p /output/patches
for dep_dir in /build/deps/*/; do
    dep_name=$(basename "$dep_dir")
    git -C "$dep_dir" diff > "/output/patches/${dep_name}.patch" 2>/dev/null || true
done

echo ""; echo "=== Step 8: Tag type === $(date)"
git -C /build/wallet log -1 --pretty=format:"%H" > /output/commit.txt 2>/dev/null || true
tt=$(git -C /build/wallet cat-file -t __WALLET_VERSION__ 2>/dev/null || echo unknown)
[[ "$tt" == tag ]] && tt="annotated tag (signature not checked: no gpg in image)" || tt="lightweight ($tt)"
echo "tagType:        __WALLET_VERSION__ is $tt" > /output/git-tag-verify.txt

echo ""; echo "=== Source-build output ==="
sha256sum /output/built-splits/*.apk

echo ""; echo "=== Dependency resolution check ==="
WLOG=/output/wallet-build.log
HS_LOCAL=$(grep -E "horizontalsystems" "$WLOG" 2>/dev/null | grep -Ec "\.m2/repository/com/github/horizontalsystems|mavenLocal" || true); HS_LOCAL=${HS_LOCAL:-0}
JP_RE="Downloading https://jitpack\\.io/com/github/horizontalsystems|Downloaded from .*jitpack\\.io/com/github/horizontalsystems"
HS_JITPACK=$(grep -Eci "$JP_RE" "$WLOG" 2>/dev/null || true); HS_JITPACK=${HS_JITPACK:-0}
echo "  HS packages from mavenLocal: $HS_LOCAL (expected >0), from JitPack: $HS_JITPACK (expected 0)"
if [[ "$HS_LOCAL" -eq 0 || "$HS_JITPACK" -gt 0 ]]; then
    [[ "$HS_JITPACK" -gt 0 ]] && { grep -Ei "$JP_RE" "$WLOG" | head -5 | sed 's/^/    /' || true; }
    echo "ERROR: dependency source check failed (mavenLocal=$HS_LOCAL, JitPack=$HS_JITPACK); verdict would not prove a source build"
    exit 1
fi

echo ""; echo "=== All builds complete at $(date) ==="
BUILD_SCRIPT_END

sed -i "s/__WALLET_VERSION__/${wallet_version}/g" "$ctx/build.sh"
chmod +x "$ctx/build.sh"

$CRUN rm -f "$CTR_P3" 2>/dev/null || true

section "Running source build container (~120 min, $(date))"
# & + wait: INT/TERM traps fire at once (cleanup removes the container).
$CRUN run \
    --name "$CTR_P3" \
    "${MEM_ARGS[@]}" \
    -e "WS_DEVICE_SDK=${DEVICE_SDK}" -e "WS_INPUT_MODE=${INPUT_MODE}" -e "WS_FLAVOR=${FLAVOR}" \
    -e "WS_VERSION_NAME=${wallet_version}" -e "WS_VERSION_CODE=${version_code}" \
    "${OFF_MOUNT[@]}" \
    -v "$P3_DIR:/output" \
    -v "$ctx/build.sh:/build/build.sh:ro" \
    "$IMG_P3" \
    bash /build/build.sh 2>&1 | tee "$P3_DIR/container-build.log" &
wait $!; P3_EXIT=$?

if [[ $P3_EXIT -ne 0 ]]; then
    log_error "Source-build container exited with code $P3_EXIT"
    [[ $P3_EXIT -eq 64 ]] && die 2 "Fat APK flavor undetermined: no GitHub asset digest match and the official DEX carries neither flavor's BuildConfig key"
    [[ $P3_EXIT -eq 65 ]] && die 1 "Source tag ${wallet_version} has a different versionName/versionCode than the official APK (${wallet_version}/${version_code})"
    die 1 "From-source build failed (exit ${P3_EXIT})"
fi
[[ -s "$P3_DIR/flavor.txt" ]] && FLAVOR=$(cat "$P3_DIR/flavor.txt")
$CRUN rm -f "$CTR_P3" 2>/dev/null || true

section "Source-build results"
P3_SPLITS_DIR="$P3_DIR/built-splits"
P3_NSPLITS=$(find "$P3_SPLITS_DIR" -maxdepth 1 -name "*.apk" 2>/dev/null | wc -l)
if [[ "$P3_NSPLITS" -eq 0 ]]; then
    log_error "Source build produced no APK in $P3_SPLITS_DIR"
    die 1 "Source build produced no APK"
fi
echo "  Source-built APK(s): $P3_NSPLITS, official: ${#OFFICIAL_SPLITS[@]}, finished $(date)"

commit="unknown"
[[ -f "$P3_DIR/commit.txt" ]] && commit=$(cat "$P3_DIR/commit.txt")
git_tag_info=""
[[ -f "$P3_DIR/git-tag-verify.txt" ]] && git_tag_info=$(cat "$P3_DIR/git-tag-verify.txt")

if [[ "$INPUT_MODE" == fat ]]; then
    CMP_LABEL="Whole-APK comparison (fat GitHub/Zapstore APK vs :app:assemble${FLAVOR^}Release)"
else
    CMP_LABEL="Per-split comparison (Play split set vs AAB + bundletool)"
fi
banner "PHASE 2: APK CONTENTS COMPARISON ($(date))"
echo "  ${CMP_LABEL}; signing files excluded by name."
cat > "$ctx/p5.sh" <<'P5_SPLIT_END'
#!/bin/bash
set -uo pipefail
AAPT2=$(find "$ANDROID_HOME/build-tools" -name aapt2 | sort | tail -1)
APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name apksigner | sort | tail -1)
# One-sided diff entries -> root-relative paths, dirs expanded.
norm() { while IFS= read -r l; do
  if [[ "$l" =~ ^Only\ in\ (/tmp/[ob])(/[^:]*)?:\ (.*)$ ]]; then r="${BASH_REMATCH[1]}"; d="${BASH_REMATCH[2]#/}"; p="${d:+$d/}${BASH_REMATCH[3]}"
    if [[ -d "$r/$p" ]]; then (cd "$r" && find "$p" -type f | sort | sed "s|^|Only in $r: |"); else echo "Only in $r: $p"; fi
  else printf '%s\n' "$l"; fi; done; }
# config identity from split=; base/master has none -> "base"
cfg_of() { local s; s=$("$AAPT2" dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1); s="${s#config.}"; [[ -z "$s" ]] && s="base"; printf '%s' "$s"; }
classify_manifest_diff() {
    local md="$1" cfg="$2" mch mnx
    mch=$(printf '%s\n' "$md" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')
    # Only Play-injected metadata (and the self-closed <application> it leaves) passes.
    mnx=$(printf '%s\n' "$mch" | grep -vE \
        '^[+-][[:space:]]*<meta-data android:name="(com\.android\.vending\.derived\.apk\.id|com\.android\.stamp\.source|com\.android\.stamp\.type)"[^>]*/>$|^[+-][[:space:]]*<application android:extractNativeLibs="true" android:hasCode="false"(/>|>)$|^[+-][[:space:]]*</application>$' \
        | tr -d '\n\r')
    if [[ -n "$mch" && -z "$mnx" ]]; then
        echo "  AndroidManifest.xml: only Google Play distribution metadata differs — acceptable"
        acc=$((acc + 1))
    else
        echo "  AndroidManifest.xml: decoded XML DIFFERS ($(printf '%s\n' "$md" | grep -c '^') lines) — full diff: diff_manifest_${cfg}.txt"
        printf '%s\n' "$mch" | head -5 | sed 's/^/    /'
    fi
}
declare -A OFF BLT
for f in /official/*.apk; do OFF["$(cfg_of "$f")"]="$f"; done
for f in /built/*.apk;    do BLT["$(cfg_of "$f")"]="$f"; done
APKTOOL="java -jar /opt/apktool.jar"
T=0; M=0; N=0; MISS=0; ACC=0
: > /out/p5-summary.txt
for cfg in $(printf '%s\n' "${!OFF[@]}" "${!BLT[@]}" | sort -u); do
    echo "━━━━ config: $cfg ━━━━"
    o="${OFF[$cfg]:-}"; b="${BLT[$cfg]:-}"
    if [[ -z "$o" || -z "$b" ]]; then
        echo "  MISSING official=$([[ -n $o ]] && echo y || echo N) built=$([[ -n $b ]] && echo y || echo N)"
        echo "$cfg MISSING" >> /out/p5-summary.txt; MISS=$((MISS + 1)); continue
    fi
    rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
    # A failed unzip or diff must never read as "no differences".
    unzip -q -o "$o" -d /tmp/o; r1=$?; unzip -q -o "$b" -d /tmp/b; r2=$?
    (( r1 == 0 && r2 == 0 )) && [[ -n $(find /tmp/o -type f -print -quit) && -n $(find /tmp/b -type f -print -quit) ]] || { echo "FATAL: unzip failed ($cfg: $r1/$r2)"; exit 3; }
    echo "  files compared: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"
    while IFS= read -r so; do
        rel="${so#/tmp/o/}"
        if [[ -f "/tmp/b/$rel" ]]; then
            ho=$(sha256sum "$so" | cut -d' ' -f1); hb=$(sha256sum "/tmp/b/$rel" | cut -d' ' -f1)
            [[ "$ho" == "$hb" ]] && st=MATCH || st=DIFFER
            echo "  native $st $rel"; echo "    official $ho"; echo "    built    $hb"
        else
            echo "  native MISSING-IN-BUILT $rel"
        fi
    done < <(find /tmp/o -name '*.so' -type f | sort)
    draw=$(diff -rq /tmp/o /tmp/b); rc=$?
    (( rc < 2 )) || { echo "FATAL: diff failed ($cfg: rc $rc)"; exit 3; }
    draw=$(norm <<<"$draw") || { echo "FATAL: norm failed ($cfg)"; exit 3; }
    printf '%s\n' "$draw" > "/out/diff-unzipped-${cfg}.txt"
    echo "  raw diff (unfiltered): $(grep -c . <<<"$draw") entries, first 5; full list: comparison/diff-unzipped-${cfg}.txt"
    grep . <<<"$draw" | head -5 | sed 's/^/    /'
    # SourceStamp: only root, official-only, 32 B, apksigner-verified.
    ss='Only in /tmp/o: stamp-cert-sha256'; cnt="$draw"; st=0
    if grep -qxF "$ss" <<<"$draw" && [[ $(stat -c%s /tmp/o/stamp-cert-sha256) == 32 ]] && grep -q 'Verified for SourceStamp: true' <<<"$("$APKSIGNER" verify --verbose "$o" 2>/dev/null)"; then cnt=$(grep -vxF "$ss" <<<"$draw"); st=1; fi
    # Signing: official-only JAR signature files in root META-INF/.
    n=$(grep -vc '^$' <<<"$cnt"); m=$(grep -Ec '^Only in /tmp/o: META-INF/([^/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$' <<<"$cnt"); nn=$((n - m))
    acc=0
    if grep -qE '^Files /tmp/o/(resources\.arsc|AndroidManifest\.xml) ' <<<"$cnt"; then
        rm -rf /tmp/do /tmp/db
        dec=1
        $APKTOOL d -f --no-src --no-debug-info "$o" -o /tmp/do >/dev/null 2>&1 || dec=0
        $APKTOOL d -f --no-src --no-debug-info "$b" -o /tmp/db >/dev/null 2>&1 || dec=0
        # A failed decode never reads as identical.
        [[ "$dec" -eq 1 ]] || echo "  DECODE FAILED — no semantic classification possible for this config"
    else
        dec=0
    fi
    if [[ "$dec" -eq 1 ]] && grep -q '^Files /tmp/o/resources\.arsc ' <<<"$cnt"; then
        if [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
            rd=$(diff -r /tmp/do/res /tmp/db/res); rr=$?
            printf '%s\n' "$rd" > "/out/diff_resources_decoded_${cfg}.txt"
            ch=$(printf '%s\n' "$rd" | grep -E '^[<>]')
            nx=$(printf '%s\n' "$ch" | grep -v 'com.google.firebase.crashlytics.mapping_file_id' | tr -d '\n\r')
            if (( rr == 0 )); then
                echo "  resources.arsc: binary differs, decoded res/ IDENTICAL — acceptable (WS #574)"
                acc=$((acc + 1))
            elif (( rr == 1 )) && [[ -n "$ch" && -z "$nx" ]]; then
                echo "  resources.arsc: only crashlytics.mapping_file_id differs — build-time ID, acceptable (WS #574)"
                acc=$((acc + 1))
            else
                echo "  resources.arsc: decoded res/ DIFFERS (rc $rr, $(printf '%s\n' "$rd" | grep -c '^') lines) — full diff: diff_resources_decoded_${cfg}.txt"
                printf '%s\n' "$rd" | head -5 | sed 's/^/    /'
            fi
        else
            echo "  resources.arsc: decoded res/ missing on one side — not classified"
        fi
    fi
    if [[ "$dec" -eq 1 ]] && grep -q '^Files /tmp/o/AndroidManifest\.xml ' <<<"$cnt"; then
        if [[ -f /tmp/do/AndroidManifest.xml && -f /tmp/db/AndroidManifest.xml ]]; then
            md=$(diff -u /tmp/do/AndroidManifest.xml /tmp/db/AndroidManifest.xml); mr=$?
            printf '%s\n' "$md" > "/out/diff_manifest_${cfg}.txt"
            if (( mr > 1 )); then
                echo "  AndroidManifest.xml: decoded diff failed (rc $mr) — not classified"
            elif (( mr == 0 )); then
                echo "  AndroidManifest.xml: binary differs, decoded XML IDENTICAL — binary-encoding artifact; NOT auto-accepted, human judgement per WS #574"
            else
                classify_manifest_diff "$md" "$cfg"
            fi
        else
            echo "  AndroidManifest.xml: decoded manifest missing on one side — not classified"
        fi
    fi
    echo "  diffs: $n total ($m META-INF, $nn non-META-INF; SourceStamp excluded: $st; $acc acceptable per WS #574)"
    echo "$cfg $n $m $nn $acc" >> /out/p5-summary.txt
    T=$((T + n)); M=$((M + m)); N=$((N + nn)); ACC=$((ACC + acc))
done
echo "TOTALS $T $M $N $MISS $ACC" >> /out/p5-summary.txt
echo "=== per-split comparison complete ==="
P5_SPLIT_END
$CRUN run --rm --name "$CTR_P5" "${MEM_ARGS[@]}" \
    "${OFF_MOUNT[@]}" \
    -v "$P3_DIR/built-splits:/built:ro" \
    -v "$P5_DIR:/out" \
    -v "$ctx/p5.sh:/p5.sh:ro" \
    "$IMG_P3" bash /p5.sh 2>&1 | tee "$P5_DIR/p5-split.log"
P5_EXIT=${PIPESTATUS[0]}
if [[ $P5_EXIT -ne 0 ]] || ! grep -q '^TOTALS' "$P5_DIR/p5-summary.txt" 2>/dev/null; then
    log_error "Comparison failed (exit $P5_EXIT) or produced no summary"
    die 1 "APK comparison failed (exit ${P5_EXIT})"
fi
read -r _ diff_count diff_metainf_count diff_non_metainf_count missing_cfgs accepted_count \
    < <(grep '^TOTALS' "$P5_DIR/p5-summary.txt")
diff_count="${diff_count:-1}"; diff_metainf_count="${diff_metainf_count:-0}"
diff_non_metainf_count="${diff_non_metainf_count:-1}"; missing_cfgs="${missing_cfgs:-1}"
accepted_count="${accepted_count:-0}"
material_count=$((diff_non_metainf_count - accepted_count))
[[ "$material_count" -lt 0 ]] && material_count=0
section "VERDICT (non-signature diffs)"
echo "  Totals: ${diff_count} diff(s) (${diff_metainf_count} META-INF, ${diff_non_metainf_count} non-META-INF), ${missing_cfgs} unmatched config(s)"
echo "  Acceptable per WS #574: ${accepted_count}; material (verdict-bearing): ${material_count}"
if [[ "$missing_cfgs" -gt 0 ]]; then
    log_warn "Verdict: NOT_REPRODUCIBLE — ${missing_cfgs} config(s) present on only one side"
    P5_VERDICT="not_reproducible"
elif [[ "$material_count" -eq 0 ]]; then
    log_success "Verdict: REPRODUCIBLE (0 material diffs; ${diff_metainf_count} signing-only, ${accepted_count} acceptable per WS #574)"
    P5_VERDICT="reproducible"
else
    log_warn "Verdict: NOT_REPRODUCIBLE (${material_count} material diff(s))"
    P5_VERDICT="not_reproducible"
fi

echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${wallet_version}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${P5_VERDICT}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo "===== End Results ====="
echo "comparisonDiffs: ${diff_count}"
echo "acceptableDiffs: ${accepted_count} (WS #574)"
echo "materialDiffs:  ${material_count}"
echo "method:         ${CMP_LABEL}"
echo "inputKind:      ${INPUT_MODE}, flavor ${FLAVOR} (${KIND_RULE})"
[[ -n "${git_tag_info}" ]] && echo "${git_tag_info}"

write_yaml "${P5_VERDICT}" "Input: ${INPUT_MODE}, flavor ${FLAVOR} (${KIND_RULE}). ${CMP_LABEL}: ${diff_count} diff(s) (${diff_metainf_count} META-INF signing), ${accepted_count} acceptable per WS #574, ${material_count} material, ${missing_cfgs} unmatched split(s). Official APK SHA-256: ${app_hash}. HS deps built locally, no JitPack fallback."

echo ""
[[ "$P5_VERDICT" == "reproducible" ]] && { echo "Exit code: 0"; exit 0; }
echo "Exit code: 1"; exit 1
