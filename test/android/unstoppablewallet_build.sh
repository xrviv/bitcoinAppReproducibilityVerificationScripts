#!/usr/bin/env bash
# unstoppablewallet_build.sh - Unstoppable Wallet Reproducible Build Verification
# Version:       v0.5.0
# Organization:  WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-09-01
# Project:       https://github.com/horizontalsystems/unstoppable-wallet-android
# Host deps:     docker or podman only
# Notes:         Play Store-only, split-only. --binary must be a DIRECTORY of device-pulled
#                split APKs (base.apk + split_config.*) => AAB + bundletool per-split compare.
#                Single-APK releases (<= v0.47.x) are NOT supported by v0.3.0 (use an older script).
#                v0.49.0: zcash de-forked → external cash.z.ecc.android (not built); zano-kit-android
#                built from source, but its ~290 MB prebuilt .a (Zano/Boost/OpenSSL) are trusted blobs.
#                v0.50.1: compileSdk 37; thorchain-kit-android is built and published locally.

SCRIPT_VERSION="v0.5.0"
SCRIPT_NAME="unstoppablewallet_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
if [[ -f "$SCRIPT_PATH" ]]; then
    SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
else
    SCRIPT_SHA256="N/A"
fi
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

set -uo pipefail   # no -e: diff/cmp return 1 on differences

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="io.horizontalsystems.bankwallet"
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

banner() {
    echo ""; echo ""
    echo "############################################################"
    echo "##"
    printf "##  %s\n" "$*"
    echo "##"
    echo "############################################################"
}

section() {
    echo ""
    echo "------------------------------------------------------------"
    printf "  %s\n" "$*"
    echo "------------------------------------------------------------"
}

sha256of() { sha256sum "$1" | awk '{print $1}'; }

execution_dir="$SCRIPT_DIR"

write_warning_yaml() {
    local msg="$1"
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  ${msg}
EOF
    log_warn "COMPARISON_RESULTS.yaml written with verdict: ftbfs"
}

if [[ "$EUID" -eq 0 ]]; then
    log_error "Do not run this script as root."
    write_warning_yaml "Script was run as root; refusing to proceed"
    echo ""; echo "Exit code: 2"
    exit 2
fi


version_arg=""
apk_file=""
arch_arg=""
type_arg=""
device_sdk_arg=""

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        log_error "${flag} requires a value (got: '${val:-<nothing>}')"
        write_warning_yaml "${flag} requires a value"
        echo ""; echo "Exit code: 2"
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)  require_arg --version "${2:-}"; version_arg="$2";  shift 2 ;;
        --binary)   require_arg --binary  "${2:-}"; apk_file="$2";     shift 2 ;;
        --apk)      require_arg --apk     "${2:-}"; apk_file="$2";     shift 2 ;;
        --arch)     require_arg --arch    "${2:-}"; arch_arg="$2";     shift 2 ;;
        --type)     require_arg --type    "${2:-}"; type_arg="$2";     shift 2 ;;
        --device-sdk) require_arg --device-sdk "${2:-}"; device_sdk_arg="$2"; shift 2 ;;
        -h|--help)  echo "Usage: $SCRIPT_NAME --binary <dir-of-split-apks> [--version v] [--arch a] [--type t] [--device-sdk N]"; echo "Exit code: 0"; exit 0 ;;
        *)
            log_warn "Unknown parameter ignored: $1"
            shift
            ;;
    esac
done

DEVICE_SDK="${device_sdk_arg:-${WS_DEVICE_SDK:-36}}"
if [[ ! "$DEVICE_SDK" =~ ^[0-9]+$ || "$DEVICE_SDK" -lt 21 || "$DEVICE_SDK" -gt 99 ]]; then
    log_error "--device-sdk/WS_DEVICE_SDK must be an Android API level (21-99); got: ${DEVICE_SDK}"
    write_warning_yaml "Invalid Android device SDK/API level: ${DEVICE_SDK}"
    echo ""; echo "Exit code: 2"
    exit 2
fi

if [[ -z "$apk_file" ]]; then
    log_error "--binary is required. Unstoppable Wallet is Play Store-only."
    log_warn  "Obtain the APK via adb pull or an APK extractor app and pass via --binary."
    write_warning_yaml "--binary not provided; Unstoppable Wallet is Play Store-only; cannot proceed without official APK"
    echo ""; echo "Exit code: 2"
    exit 2
fi

# --binary must be a DIRECTORY of device-pulled split APKs (base.apk + split_config.*).
# Unstoppable ships split-only; the universal single-APK path was removed in v0.3.0.
declare -a OFFICIAL_SPLITS=()
if [[ ! -d "$apk_file" ]]; then
    log_error "--binary must be a DIRECTORY of split APKs (base.apk + split_config.*). Unstoppable is split-only."
    write_warning_yaml "--binary must be a directory of device-pulled split APKs (base.apk + split_config.*)"
    echo ""; echo "Exit code: 2"; exit 2
fi
OFFICIAL_DIR=$(realpath "$apk_file")
if [[ ! -f "$OFFICIAL_DIR/base.apk" ]]; then
    log_error "base.apk not found in $OFFICIAL_DIR (required)"
    write_warning_yaml "Split set missing base.apk in ${OFFICIAL_DIR}"
    echo ""; echo "Exit code: 2"; exit 2
fi
while IFS= read -r f; do OFFICIAL_SPLITS+=("$f"); done \
    < <(find "$OFFICIAL_DIR" -maxdepth 1 -name "*.apk" | sort)
# reject stray/unknown APKs so they can't pollute the official artifact set
for f in "${OFFICIAL_SPLITS[@]}"; do
    bn=$(basename "$f")
    [[ "$bn" == "base.apk" || "$bn" == split_config*.apk ]] || {
        log_error "Unexpected APK in split dir: $bn (only base.apk + split_config*.apk allowed)"
        write_warning_yaml "Unexpected APK in split dir: ${bn}"; echo ""; echo "Exit code: 2"; exit 2; }
done
apk_file="$OFFICIAL_DIR/base.apk"   # base.apk drives Phase 0 metadata
log_info "${#OFFICIAL_SPLITS[@]} official split(s) in ${OFFICIAL_DIR}"
log_info "Device SDK/API for bundletool: ${DEVICE_SDK}"
[[ -n "$arch_arg" ]]  && log_info "--arch ${arch_arg} accepted but not used (configs derived from official splits)"
[[ -n "$type_arg" ]]  && log_info "--type ${type_arg} accepted but not used"
[[ -n "$version_arg" ]] && log_info "--version ${version_arg} accepted; actual version derived from APK metadata"

if [[ -z "${CRUN:-}" ]]; then
    if command -v docker &>/dev/null; then
        CRUN=docker
    elif command -v podman &>/dev/null; then
        CRUN=podman
    else
        log_error "Neither docker nor podman found in PATH"
        write_warning_yaml "Neither docker nor podman found in PATH"
        echo ""; echo "Exit code: 2"
        exit 2
    fi
fi

MEM_LIMIT="${MEM_LIMIT:-20g}"
MEM_ARGS=()
[[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")

banner "PRE-FLIGHT: HOST TOOL CHECK"

printf "  %-12s OK  (%s)\n" "$CRUN" "$(command -v "$CRUN")"
echo "  Host requirement satisfied."

RUN_ID="unstoppable-$(date +%s)-$$"
IMG_P3="ws-unstoppable-source-${RUN_ID}"
CTR_P0="ws-unstoppable-p0-${RUN_ID}"
CTR_P3="ws-unstoppable-source-ctr-${RUN_ID}"

workspace="${execution_dir}/unstoppable_verification_${RUN_ID}"
P0_DIR="${workspace}/metadata"
P3_DIR="${workspace}/source-build"
P5_DIR="${workspace}/comparison"

p3_ctx=""
p0_ctx=""
p5_ctx=""

ensure_user_ownership() {
    local path="$1" image="$2"
    [[ -e "$path" ]] || return 0
    [[ -n "$image" ]] || return 0
    $CRUN run --rm \
        -v "${path}:/target" \
        "$image" \
        sh -c "chown -R ${HOST_UID}:${HOST_GID} /target" >/dev/null 2>&1 || \
        log_warn "Could not fix ownership for ${path}"
}

generate_yaml() {
    local verdict="$1" notes="$2"
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}
EOF
    log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

generate_error_yaml() {
    local verdict="${1:-ftbfs}" error_msg="${2:-Build failed}"
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${error_msg}
EOF
    log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

cleanup() {
    log_info "Cleaning up containers and images..."
    $CRUN rm -f "$CTR_P3" 2>/dev/null || true
    local own_image=""
    if $CRUN image inspect "$IMG_P3" >/dev/null 2>&1; then
        own_image="$IMG_P3"
    fi
    ensure_user_ownership "$workspace" "$own_image"
    $CRUN rmi -f "$IMG_P3" 2>/dev/null || true
    [[ -n "$p3_ctx" ]] && rm -rf "$p3_ctx" 2>/dev/null || true
    [[ -n "$p0_ctx" ]] && rm -rf "$p0_ctx" 2>/dev/null || true
    [[ -n "$p5_ctx" ]] && rm -rf "$p5_ctx" 2>/dev/null || true
    log_success "Cleanup complete."
}
trap cleanup EXIT

mkdir -p "$P0_DIR" "$P3_DIR" "$P5_DIR"

banner "UNSTOPPABLE WALLET REPRODUCIBLE BUILD VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "  App ID:    ${APP_ID}"
echo "  APK:       ${apk_file}"
echo "  Device SDK:${DEVICE_SDK}"
echo "  Runtime:   ${CRUN} ($($CRUN --version 2>&1 | head -1))"
echo "  Workspace: ${workspace}"
echo "  Date:      $(date)"

# One image is used for metadata extraction, source builds, and split comparison.
banner "SETUP: BUILD SHARED CONTAINER IMAGE"
echo "  Started: $(date)"

p3_ctx=$(mktemp -d)

cat > "$p3_ctx/Dockerfile" <<'DOCKERFILE_P3'
FROM ubuntu:24.04
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

WORKDIR /build
DOCKERFILE_P3

section "Building source-build image: ${IMG_P3}"
if ! $CRUN build -t "$IMG_P3" -f "$p3_ctx/Dockerfile" "$p3_ctx"; then
    log_error "Source-build image failed"
    generate_error_yaml "ftbfs" "Source-build container image failed"
    echo ""; echo "Exit code: 1"
    exit 1
fi
log_success "Source-build image built: ${IMG_P3}"

banner "PHASE 0: APK METADATA EXTRACTION"
echo "  Extracting versionName, versionCode, signer from official APK..."
echo "  Started: $(date)"

p0_ctx=$(mktemp -d)

cat > "$p0_ctx/extract_meta.sh" <<'META_SCRIPT'
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
# Supports both legacy "Signer #1" and rotated SDK-range signer labels while excluding SourceStamp.
signer_hash=$(printf '%s\n' "$signer_output" \
    | sed -nE '/^Signer( #[0-9]+| \(minSdkVersion=[^)]*\)) certificate SHA-256 digest:/ {s/.*digest: //;p;}' \
    | sort -u | paste -sd, -)

pkg_name=$(echo "$apk_info" | grep -oP "^package: name='[^']+'" | sed "s/^package: name='//;s/'$//" || true)

echo "${version_name:-unknown}" > /output/version_name.txt
echo "${version_code:-unknown}" > /output/version_code.txt
echo "${signer_hash:-unknown}"  > /output/signer.txt
echo "${pkg_name:-unknown}"     > /output/pkg_name.txt

echo "[META] versionName: ${version_name:-unknown}"
echo "[META] versionCode: ${version_code:-unknown}"
echo "[META] signer SHA-256: ${signer_hash:-unknown}"
echo "[META] pkg_name: ${pkg_name:-unknown}"
META_SCRIPT
chmod +x "$p0_ctx/extract_meta.sh"

if ! $CRUN run \
    --rm \
    --name "$CTR_P0" \
    "${MEM_ARGS[@]}" \
    -v "${apk_file}:/input/official.apk:ro" \
    -v "${P0_DIR}:/output" \
    -v "${p0_ctx}/extract_meta.sh:/extract_meta.sh:ro" \
    "$IMG_P3" \
    bash /extract_meta.sh; then
    log_error "Phase 0 metadata extraction failed"
    generate_error_yaml "ftbfs" "APK metadata extraction failed"
    echo ""; echo "Exit code: 1"
    exit 1
fi

wallet_version=$(cat "${P0_DIR}/version_name.txt" 2>/dev/null || echo "unknown")
version_code=$(cat   "${P0_DIR}/version_code.txt"  2>/dev/null || echo "unknown")
signer=$(cat          "${P0_DIR}/signer.txt"        2>/dev/null || echo "unknown")
app_hash=$(sha256of "$apk_file")

pkg_id=$(cat "${P0_DIR}/pkg_name.txt" 2>/dev/null || echo "unknown")
if [[ "$pkg_id" != "$APP_ID" ]]; then
    log_error "APK app ID mismatch: expected $APP_ID, got ${pkg_id}"
    generate_error_yaml "ftbfs" "APK app ID mismatch: expected $APP_ID, got ${pkg_id}"
    echo ""; echo "Exit code: 1"; exit 1
fi
log_success "APK app ID verified: ${pkg_id}"

log_success "APK metadata: v${wallet_version} (code ${version_code})"
log_info    "Signer SHA-256: ${signer}"
log_info    "Official APK SHA-256: ${app_hash}"
log_info    "Official split APK SHA-256 values:"
for official_split in "${OFFICIAL_SPLITS[@]}"; do
    printf '  %s  %s\n' "$(sha256of "$official_split")" "$(basename "$official_split")"
done

banner "PHASE 1: BUILD DEPS FROM SOURCE + BUILD WALLET"
echo "  Building horizontalsystems deps from source (zano: Kotlin/JNI wrapper only — links prebuilt .a blobs)."
echo "  HS versions are derived from wallet app/build.gradle at runtime."
echo "  Started: $(date)"

# __WALLET_VERSION__ is substituted by sed after the heredoc is written to file.
cat > "$p3_ctx/build.sh" <<'BUILD_SCRIPT_END'
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

extract_wallet_hs_version() {
    local artifact="$1"
    local wallet_gradle="$2"
    local toml="/build/wallet/gradle/libs.versions.toml"
    # Version catalog (libs.versions.toml) — used from v0.48.0+
    if [[ -f "$toml" ]]; then
        local ref
        ref=$(grep -E "module\s*=\s*\"com\.github\.horizontalsystems:${artifact}\"" "$toml" \
              | sed -E 's/.*version\.ref\s*=\s*"([^"]+)".*/\1/' | head -1 || true)
        if [[ -n "$ref" ]]; then
            grep -E "^\s*${ref}\s*=" "$toml" | sed -E 's/.*=\s*"([^"]+)".*/\1/' | head -1
            return 0
        fi
    fi
    # Inline coordinates in build.gradle (pre-v0.48.0)
    local line
    line=$(grep -E "com\\.github\\.horizontalsystems:${artifact}:[^\"']+" "$wallet_gradle" | head -1 || true)
    if [[ -z "$line" ]]; then
        echo ""
        return 1
    fi
    echo "$line" | sed -E "s/.*com\\.github\\.horizontalsystems:${artifact}:([^\"']+).*/\\1/"
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
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<project xmlns="http://maven.apache.org/POM/4.0.0">'
        echo '    <modelVersion>4.0.0</modelVersion>'
        echo "    <groupId>${group}</groupId>"
        echo "    <artifactId>${artifact}</artifactId>"
        echo "    <version>${version}</version>"
        echo '    <packaging>pom</packaging>'
        echo '    <dependencies>'
        for mod in "${modules[@]}"; do
            echo '        <dependency>'
            echo "            <groupId>${subgroup}</groupId>"
            echo "            <artifactId>${mod}</artifactId>"
            echo "            <version>${version}</version>"
            echo '            <scope>compile</scope>'
            echo '        </dependency>'
        done
        echo '    </dependencies>'
        echo '</project>'
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

compile_sdk=$(sed -nE 's/^[[:space:]]*compileSdk[[:space:]]*=[[:space:]]*"([0-9]+)".*/\1/p' \
    /build/wallet/gradle/libs.versions.toml | head -1)
require_nonempty "compileSdk" "$compile_sdk"
platform_dir=$(find "$ANDROID_HOME/platforms" -maxdepth 1 -type d \
    \( -name "android-${compile_sdk}" -o -name "android-${compile_sdk}.0" \) -print -quit)
if [[ -z "$platform_dir" ]]; then
    echo "ERROR: compileSdk ${compile_sdk} is not installed under $ANDROID_HOME/platforms"
    echo "       Refusing to build dependencies before this environment defect is fixed."
    exit 1
fi
echo "Compile SDK ${compile_sdk} present: ${platform_dir}"

if [[ -f "/build/wallet/app/build.gradle.kts" ]]; then
    wallet_gradle="/build/wallet/app/build.gradle.kts"
elif [[ -f "/build/wallet/app/build.gradle" ]]; then
    wallet_gradle="/build/wallet/app/build.gradle"
else
    echo "ERROR: wallet app/build.gradle(.kts) not found under /build/wallet/app/"
    exit 1
fi

MONERO_VER=$(extract_wallet_hs_version "monero-kit-android" "$wallet_gradle")
STELLAR_VER=$(extract_wallet_hs_version "stellar-kit-android" "$wallet_gradle")
TON_VER=$(extract_wallet_hs_version "ton-kit-android" "$wallet_gradle")
BITCOIN_VER=$(extract_wallet_hs_version "bitcoin-kit-android" "$wallet_gradle")
ETHEREUM_VER=$(extract_wallet_hs_version "ethereum-kit-android" "$wallet_gradle")
FEERATE_VER=$(extract_wallet_hs_version "blockchain-fee-rate-kit-android" "$wallet_gradle")
MARKET_VER=$(extract_wallet_hs_version "market-kit-android" "$wallet_gradle")
SOLANA_VER=$(extract_wallet_hs_version "solana-kit-android" "$wallet_gradle")
TRON_VER=$(extract_wallet_hs_version "tron-kit-android" "$wallet_gradle")
ZANO_VER=$(extract_wallet_hs_version "zano-kit-android" "$wallet_gradle")
HD_WALLET_VER=$(extract_wallet_hs_version "hd-wallet-kit-android" "$wallet_gradle" || true)
THORCHAIN_VER=$(extract_wallet_hs_version "thorchain-kit-android" "$wallet_gradle" || true)

require_nonempty "monero-kit-android version" "$MONERO_VER"
require_nonempty "stellar-kit-android version" "$STELLAR_VER"
require_nonempty "ton-kit-android version" "$TON_VER"
require_nonempty "bitcoin-kit-android version" "$BITCOIN_VER"
require_nonempty "ethereum-kit-android version" "$ETHEREUM_VER"
require_nonempty "blockchain-fee-rate-kit-android version" "$FEERATE_VER"
require_nonempty "market-kit-android version" "$MARKET_VER"
require_nonempty "solana-kit-android version" "$SOLANA_VER"
require_nonempty "tron-kit-android version" "$TRON_VER"
require_nonempty "zano-kit-android version" "$ZANO_VER"

echo "Derived HS direct versions from wallet app/build.gradle:"
echo "  monero-kit-android:               $MONERO_VER"
echo "  stellar-kit-android:              $STELLAR_VER"
echo "  ton-kit-android:                  $TON_VER"
echo "  bitcoin-kit-android:              $BITCOIN_VER"
echo "  ethereum-kit-android:             $ETHEREUM_VER"
echo "  blockchain-fee-rate-kit-android:  $FEERATE_VER"
echo "  market-kit-android:               $MARKET_VER"
echo "  solana-kit-android:               $SOLANA_VER"
echo "  tron-kit-android:                 $TRON_VER"
echo "  zano-kit-android:                 $ZANO_VER"
[[ -n "$HD_WALLET_VER" ]] && echo "  hd-wallet-kit-android:            $HD_WALLET_VER"
[[ -n "$THORCHAIN_VER" ]] && echo "  thorchain-kit-android:             $THORCHAIN_VER"

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

if [[ -z "$HD_WALLET_VER" ]]; then
    HD_WALLET_VER=$(grep -Eo "com\\.github\\.horizontalsystems:hd-wallet-kit-android:[^\"']+" \
        /home/jitpack/build/bitcoincore/build.gradle 2>/dev/null \
        | head -1 | sed -E 's/.*:hd-wallet-kit-android://')
fi
if [[ -z "$HD_WALLET_VER" ]]; then
    HD_WALLET_VER=$(grep -Eo "com\\.github\\.horizontalsystems:hd-wallet-kit-android:[^\"']+" \
        /build/deps/tron-kit-android/tronkit/build.gradle 2>/dev/null \
        | head -1 | sed -E 's/.*:hd-wallet-kit-android://')
fi
if [[ -z "$HD_WALLET_VER" ]]; then
    echo "ERROR: Could not derive hd-wallet-kit-android version from dependent repos"
    exit 1
fi
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
grep -qF "maven-publish" stellarkit/build.gradle || sed -i "/plugins {/a\\    id 'maven-publish'" stellarkit/build.gradle
if grep -qF "release(MavenPublication)" stellarkit/build.gradle; then
    sed -i "/artifactId = 'stellar-kit-android'/{n;s/version = '[^']*'/version = '$STELLAR_VER'/;}" stellarkit/build.gradle
else
    cat >> stellarkit/build.gradle <<STELLAR_PUB

afterEvaluate {
    publishing {
        publications {
            release(MavenPublication) {
                from components.release
                groupId = 'com.github.horizontalsystems'
                artifactId = 'stellar-kit-android'
                version = '$STELLAR_VER'
            }
        }
    }
}
STELLAR_PUB
fi
grep -qF "version = '$STELLAR_VER'" stellarkit/build.gradle || { echo "ERROR: stellar-kit publication version not set to $STELLAR_VER"; exit 1; }
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

# Step 4g: zano-kit-android (new in v0.49.0; native C++/JNI). Build Kotlin SDK + libzanokit.so
# from source + publish. CAVEAT: links ~290 MB prebuilt .a (Zano engine/Boost/OpenSSL) NOT rebuilt
# (upstream builds them macOS-only) — trusted vendor blobs, flag in report. Needs NDK 27.0.12077973.
echo ""; echo "=== Step 4g: zano-kit-android === $(date)"
echo "  [BLOB CAVEAT] zano links prebuilt .a (Zano engine/Boost/OpenSSL) — not rebuilt from source"
cd /build/deps/zano-kit-android
grep -qF "maven-publish" zanokit/build.gradle || sed -i "/plugins {/a\\    id 'maven-publish'" zanokit/build.gradle
# AGP 8.11.1: components.release does not exist without the release-variant publishing opt-in.
grep -qF "singleVariant('release')" zanokit/build.gradle || sed -i "/^android {/a\\    publishing { singleVariant('release') }" zanokit/build.gradle
if grep -qF "release(MavenPublication)" zanokit/build.gradle; then
    sed -i "/artifactId = 'zano-kit-android'/{n;s/version = '[^']*'/version = '$ZANO_VER'/;}" zanokit/build.gradle
else
    cat >> zanokit/build.gradle <<ZANO_PUB

afterEvaluate {
    publishing {
        publications {
            release(MavenPublication) {
                from components.release
                groupId = 'com.github.horizontalsystems'
                artifactId = 'zano-kit-android'
                version = '$ZANO_VER'
            }
        }
    }
}
ZANO_PUB
fi
grep -qF "version = '$ZANO_VER'" zanokit/build.gradle || { echo "ERROR: zano-kit publication version not set to $ZANO_VER"; exit 1; }
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
grep -qF "maven-publish" monerokit/build.gradle || sed -i "/plugins {/a\\    id 'maven-publish'" monerokit/build.gradle
# monero-kit is AGP 8.11.1 like zano and declares no publishing opt-in of its own.
grep -qF "singleVariant('release')" monerokit/build.gradle || sed -i "/^android {/a\\    publishing { singleVariant('release') }" monerokit/build.gradle
if grep -qF "release(MavenPublication)" monerokit/build.gradle; then
    sed -i "/artifactId = 'monero-kit-android'/{n;s/version = '[^']*'/version = '$MONERO_VER'/;}" monerokit/build.gradle
else
    cat >> monerokit/build.gradle <<MONERO_PUB

afterEvaluate {
    publishing {
        publications {
            release(MavenPublication) {
                from components.release
                groupId = 'com.github.horizontalsystems'
                artifactId = 'monero-kit-android'
                version = '$MONERO_VER'
            }
        }
    }
}
MONERO_PUB
fi
grep -qF "version = '$MONERO_VER'" monerokit/build.gradle || { echo "ERROR: monero-kit publication version not set to $MONERO_VER"; exit 1; }
./gradlew :monerokit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 6: Build wallet === $(date)"
cd /build/wallet
sed -i 's/org\.gradle\.jvmargs=.*/org.gradle.jvmargs=-Xmx4096M -Dkotlin.daemon.jvm.options="-Xmx4096M"/' gradle.properties
rm -rf ~/.gradle/caches/
# Build the AAB (source of Play's splits), derive a device-spec from the official
    # split set, then bundletool-generate the device-matched splits (NOT --mode=universal).
    ./gradlew :app:bundleBaseRelease --no-daemon --max-workers=2 --info > /output/wallet-build.log 2>&1
    AAB=$(find app/build/outputs/bundle -name "*.aab" | head -1)
    cp "$AAB" /output/app-base-release.aab
    AAPT2=$(find "$ANDROID_HOME/build-tools" -name aapt2 | sort | tail -1)
    DABIS=(); DDEN=""
    for f in /official/*.apk; do case "$(basename "$f")" in
        *config.arm64_v8a*)   DABIS+=("arm64-v8a") ;;
        *config.armeabi_v7a*) DABIS+=("armeabi-v7a") ;;
        *config.x86_64*)      DABIS+=("x86_64") ;;
        *config.x86.apk)      DABIS+=("x86") ;;
        *config.ldpi*) DDEN=120 ;; *config.mdpi*) DDEN=160 ;; *config.tvdpi*) DDEN=213 ;;
        *config.hdpi*) DDEN=240 ;; *config.xhdpi*) DDEN=320 ;;
        *config.xxhdpi*) DDEN=480 ;; *config.xxxhdpi*) DDEN=640 ;;
    esac; done
    [[ -z "$DDEN" ]] && DDEN=480
    # sdkVersion = DEVICE API level (not app targetSdk); locales fixed to en. Both provisional —
    # a wrong device-spec yields a mismatched split set, which the config set-match guard fails on.
    DSDK="${WS_DEVICE_SDK:-34}"
    DABIJSON=$(printf '"%s",' "${DABIS[@]}"); DABIJSON="[${DABIJSON%,}]"
    printf '{"supportedAbis":%s,"supportedLocales":["en"],"screenDensity":%s,"sdkVersion":%s}\n' \
        "$DABIJSON" "$DDEN" "$DSDK" > /tmp/device-spec.json
    cp /tmp/device-spec.json /output/device-spec.json
    echo "=== device-spec.json ==="; cat /tmp/device-spec.json
    java -jar /opt/bundletool.jar build-apks --bundle="$AAB" \
        --output=/output/built.apks --device-spec=/tmp/device-spec.json \
        --aapt2="$AAPT2" --overwrite
    mkdir -p /output/built-splits /output/bt-extract
    unzip -o /output/built.apks 'splits/*.apk' -d /output/bt-extract
    cp /output/bt-extract/splits/*.apk /output/built-splits/
    echo "=== built splits ==="; ls -lh /output/built-splits/

echo ""; echo "=== Step 7: Collect outputs === $(date)"
mkdir -p /output/patches
for dep_dir in /build/deps/*/; do
    dep_name=$(basename "$dep_dir")
    git -C "$dep_dir" diff > "/output/patches/${dep_name}.patch" 2>/dev/null || true
done

echo ""; echo "=== Step 8: Git tag verification === $(date)"
git -C /build/wallet log -1 --pretty=format:"%H" > /output/commit.txt 2>/dev/null || true
tag_obj_type=$(git -C /build/wallet cat-file -t __WALLET_VERSION__ 2>/dev/null || echo "unknown")
if [[ "$tag_obj_type" == "tag" ]]; then
    git -C /build/wallet tag -v __WALLET_VERSION__ > /output/git-tag-verify.txt 2>&1 || true
else
    echo "Tag __WALLET_VERSION__ is a ${tag_obj_type} (lightweight tag — GPG verification not possible; no signature to verify)" > /output/git-tag-verify.txt
fi

echo ""; echo "=== Source-build output ==="
sha256sum /output/built-splits/*.apk

echo ""; echo "=== Dependency resolution check ==="
WLOG=/output/wallet-build.log
# grep -c prints 0 on no match but exits 1, so keep its output while neutralising the status.
# `|| true` forces exit 0 while keeping grep's "0" on stdout (NOT `|| echo 0`, which appends a 2nd 0 → "0\n0").
HS_LOCAL=$(grep -E "horizontalsystems" "$WLOG" 2>/dev/null | grep -Ec "\.m2/repository/com/github/horizontalsystems|mavenLocal" || true); HS_LOCAL=${HS_LOCAL:-0}
HS_JITPACK=$(grep -Eci "Downloading https://jitpack\\.io/com/github/horizontalsystems|Downloaded from .*jitpack\\.io/com/github/horizontalsystems" "$WLOG" 2>/dev/null || true); HS_JITPACK=${HS_JITPACK:-0}
echo "  HS packages from mavenLocal: $HS_LOCAL  (expected: >0)"
echo "  HS packages from JitPack:    $HS_JITPACK (expected: 0)"
if [[ "$HS_LOCAL" -eq 0 || "$HS_JITPACK" -gt 0 ]]; then
    if [[ "$HS_JITPACK" -gt 0 ]]; then
        echo "  JitPack URLs detected:"
        grep -Ei "Downloading https://jitpack\\.io/com/github/horizontalsystems|Downloaded from .*jitpack\\.io/com/github/horizontalsystems" "$WLOG" | sed 's/^/    /' || true
    fi
    echo "ERROR: dependency source check failed (mavenLocal=$HS_LOCAL, JitPack=$HS_JITPACK)"
    echo "       The APK verdict would not prove a full source build. Aborting."
    exit 1
fi

echo ""; echo "=== All builds complete at $(date) ==="
BUILD_SCRIPT_END

sed -i "s/__WALLET_VERSION__/${wallet_version}/g" "$p3_ctx/build.sh"
chmod +x "$p3_ctx/build.sh"

$CRUN rm -f "$CTR_P3" 2>/dev/null || true

section "Running source build container (~120 min)"
echo "  Started: $(date)"
set +e
$CRUN run \
    --name "$CTR_P3" \
    "${MEM_ARGS[@]}" \
    -e "WS_DEVICE_SDK=${DEVICE_SDK}" \
    -v "${OFFICIAL_DIR}:/official:ro" \
    -v "$P3_DIR:/output" \
    -v "$p3_ctx/build.sh:/build/build.sh:ro" \
    "$IMG_P3" \
    bash /build/build.sh 2>&1 | tee "$P3_DIR/container-build.log"
P3_EXIT=${PIPESTATUS[0]}
set +e   # keep -e OFF (script uses set -uo pipefail without -e; see line 38)

if [[ $P3_EXIT -ne 0 ]]; then
    log_error "Source-build container exited with code $P3_EXIT"
    generate_error_yaml "ftbfs" "From-source build failed (exit ${P3_EXIT})"
    echo ""; echo "Exit code: 1"
    exit 1
fi
$CRUN rm -f "$CTR_P3" 2>/dev/null || true

section "Source-build results"
P3_SPLITS_DIR="$P3_DIR/built-splits"
P3_NSPLITS=$(find "$P3_SPLITS_DIR" -maxdepth 1 -name "*.apk" 2>/dev/null | wc -l)
if [[ "$P3_NSPLITS" -eq 0 ]]; then
    log_error "Source build produced no splits in $P3_SPLITS_DIR"
    generate_error_yaml "ftbfs" "Source build produced no split APKs"
    echo ""; echo "Exit code: 1"; exit 1
fi
echo "  Source-built splits:   $P3_NSPLITS"
echo "  Official splits:       ${#OFFICIAL_SPLITS[@]}"
echo "  Finished: $(date)"

commit="unknown"
[[ -f "$P3_DIR/commit.txt" ]] && commit=$(cat "$P3_DIR/commit.txt")
git_tag_info=""
[[ -f "$P3_DIR/git-tag-verify.txt" ]] && git_tag_info=$(cat "$P3_DIR/git-tag-verify.txt")

banner "PHASE 2: PER-SPLIT CONTENTS COMPARISON"
echo "  Official split vs built split, paired by config identity; contents-only (signing ignored)."
echo "  Started: $(date)"
p5_ctx=$(mktemp -d)
cat > "$p5_ctx/p5.sh" <<'P5_SPLIT_END'
#!/bin/bash
set -uo pipefail
AAPT2=$(find "$ANDROID_HOME/build-tools" -name aapt2 | sort | tail -1)
# config identity from the APK manifest: base/master has no split= → "base"; configs → token
cfg_of() { local s; s=$("$AAPT2" dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1); s="${s#config.}"; [[ -z "$s" ]] && s="base"; printf '%s' "$s"; }
classify_manifest_diff() {
    local md="$1" cfg="$2" mch mnx
    mch=$(printf '%s\n' "$md" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')
    # Google Play injects these distribution/source-stamp entries after the developer
    # build. Removing them can also turn an empty <application> pair into a self-closing
    # tag, so accept only those exact wrapper lines alongside the three metadata names.
    mnx=$(printf '%s\n' "$mch" | grep -vE \
        '^[+-][[:space:]]*<meta-data android:name="(com\.android\.vending\.derived\.apk\.id|com\.android\.stamp\.source|com\.android\.stamp\.type)"[^>]*/>$|^[+-][[:space:]]*<application android:extractNativeLibs="true" android:hasCode="false"(/>|>)$|^[+-][[:space:]]*</application>$' \
        | tr -d '\n\r')
    if [[ -n "$mch" && -z "$mnx" ]]; then
        echo "  AndroidManifest.xml: sole decoded changes are Google Play distribution metadata — acceptable"
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
    unzip -q -o "$o" -d /tmp/o; unzip -q -o "$b" -d /tmp/b
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
    draw=$(diff -rq /tmp/o /tmp/b 2>/dev/null)
    printf '%s\n' "$draw"
    # Exclude Google Play SourceStamp (stamp-cert-sha256) from counted diffs — Play-injected artifact, not developer output
    cnt=$(printf '%s\n' "$draw" | grep -v 'stamp-cert-sha256')
    n=$(printf '%s\n' "$cnt" | grep -vc '^$'); m=$(printf '%s\n' "$cnt" | grep -Ec '\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)'); nn=$((n - m))
    acc=0
    if printf '%s\n' "$cnt" | grep -qE 'resources\.arsc|AndroidManifest\.xml'; then
        rm -rf /tmp/do /tmp/db
        dec=1
        $APKTOOL d -f --no-src --no-debug-info "$o" -o /tmp/do >/dev/null 2>&1 || dec=0
        $APKTOOL d -f --no-src --no-debug-info "$b" -o /tmp/db >/dev/null 2>&1 || dec=0
        # A failed decode must never read as "identical" — no acceptance without a verified decode.
        [[ "$dec" -eq 1 ]] || echo "  DECODE FAILED — no semantic classification possible for this config"
    else
        dec=0
    fi
    if [[ "$dec" -eq 1 ]] && printf '%s\n' "$cnt" | grep -q 'resources\.arsc'; then
        if [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
            rd=$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)
            printf '%s\n' "$rd" > "/out/diff_resources_decoded_${cfg}.txt"
            ch=$(printf '%s\n' "$rd" | grep -E '^[<>]')
            nx=$(printf '%s\n' "$ch" | grep -v 'com.google.firebase.crashlytics.mapping_file_id' | tr -d '\n\r')
            if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then
                echo "  resources.arsc: binary differs, decoded res/ IDENTICAL — non-semantic artifact, acceptable (WS #574)"
                acc=$((acc + 1))
            elif [[ -n "$ch" && -z "$nx" ]]; then
                echo "  resources.arsc: sole decoded change is crashlytics.mapping_file_id — build-time ID, acceptable (WS #574)"
                acc=$((acc + 1))
            else
                echo "  resources.arsc: decoded res/ DIFFERS ($(printf '%s\n' "$rd" | grep -c '^') lines) — full diff: diff_resources_decoded_${cfg}.txt"
                printf '%s\n' "$rd" | head -5 | sed 's/^/    /'
            fi
        else
            echo "  resources.arsc: decoded res/ missing on one side — not classified"
        fi
    fi
    if [[ "$dec" -eq 1 ]] && printf '%s\n' "$cnt" | grep -q 'AndroidManifest\.xml'; then
        if [[ -f /tmp/do/AndroidManifest.xml && -f /tmp/db/AndroidManifest.xml ]]; then
            md=$(diff -u /tmp/do/AndroidManifest.xml /tmp/db/AndroidManifest.xml 2>/dev/null)
            printf '%s\n' "$md" > "/out/diff_manifest_${cfg}.txt"
            if [[ -z "$(printf '%s' "$md" | tr -d '[:space:]')" ]]; then
                echo "  AndroidManifest.xml: binary differs, decoded XML IDENTICAL — binary-encoding artifact; NOT auto-accepted, human judgement per WS #574"
            else
                classify_manifest_diff "$md" "$cfg"
            fi
        else
            echo "  AndroidManifest.xml: decoded manifest missing on one side — not classified"
        fi
    fi
    echo "  diffs: $n total ($m META-INF, $nn non-META-INF; stamp-cert-sha256 excluded as Play SourceStamp; $acc acceptable per WS #574)"
    echo "$cfg $n $m $nn $acc" >> /out/p5-summary.txt
    T=$((T + n)); M=$((M + m)); N=$((N + nn)); ACC=$((ACC + acc))
done
echo "TOTALS $T $M $N $MISS $ACC" >> /out/p5-summary.txt
echo "=== per-split comparison complete ==="
P5_SPLIT_END
$CRUN run --rm \
    -v "$OFFICIAL_DIR:/official:ro" \
    -v "$P3_DIR/built-splits:/built:ro" \
    -v "$P5_DIR:/out" \
    -v "$p5_ctx/p5.sh:/p5.sh:ro" \
    "$IMG_P3" bash /p5.sh 2>&1 | tee "$P5_DIR/p5-split.log"
P5_EXIT=${PIPESTATUS[0]}
if [[ $P5_EXIT -ne 0 ]] || ! grep -q '^TOTALS' "$P5_DIR/p5-summary.txt" 2>/dev/null; then
    log_error "Split comparison failed (exit $P5_EXIT) or produced no summary"
    generate_error_yaml "ftbfs" "Per-split comparison failed (exit ${P5_EXIT})"
    echo ""; echo "Exit code: 1"; exit 1
fi
read -r _ diff_count diff_metainf_count diff_non_metainf_count missing_cfgs accepted_count \
    < <(grep '^TOTALS' "$P5_DIR/p5-summary.txt")
diff_count="${diff_count:-1}"; diff_metainf_count="${diff_metainf_count:-0}"
diff_non_metainf_count="${diff_non_metainf_count:-1}"; missing_cfgs="${missing_cfgs:-1}"
accepted_count="${accepted_count:-0}"
material_count=$((diff_non_metainf_count - accepted_count))
[[ "$material_count" -lt 0 ]] && material_count=0
section "Phase 2: VERDICT (judged on non-signature diffs)"
echo "  Totals: ${diff_count} diff(s) (${diff_metainf_count} META-INF, ${diff_non_metainf_count} non-META-INF), ${missing_cfgs} unmatched config(s)"
echo "  Acceptable per WS #574 (decoded resources / Google Play manifest metadata): ${accepted_count}"
echo "  Material (verdict-bearing) diffs: ${material_count}"
echo "  Acceptable-diffs policy: https://gitlab.com/walletscrutiny/walletScrutinyCom/-/issues/574"
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
echo "comparisonDiffs: ${diff_count}"
echo "acceptableDiffs: ${accepted_count} (WS #574)"
echo "materialDiffs:  ${material_count}"
echo "method:         source-built splits vs official Play splits"
echo "jitpack:        no Horizontal Systems fallback allowed"
[[ -n "${git_tag_info}" ]] && echo "${git_tag_info}"
echo "===== End Results ====="

generate_yaml "${P5_VERDICT}" "Source-built split comparison: ${diff_count} total difference(s) (${diff_metainf_count} META-INF, ${diff_non_metainf_count} other), of which ${accepted_count} are acceptable per WS issue 574 (decoded-identical resources, crashlytics mapping ID, or decoded manifest changes limited to Google Play distribution metadata) and ${material_count} are material. Official APK SHA-256: ${app_hash}. Horizontal Systems dependencies were built locally; JitPack fallback was prohibited. The former JitPack baseline comparison was removed because commit artifacts are not durably available."

echo ""
echo "Exit code: 0"
exit 0
