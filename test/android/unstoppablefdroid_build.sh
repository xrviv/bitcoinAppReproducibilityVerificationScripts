#!/usr/bin/env bash
# unstoppablefdroid_build.sh - Unstoppable Wallet (F-Droid variant) Reproducible Build Verification
# Version:       v0.1.2
# Organization:  WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-09-02
# Project:       https://github.com/horizontalsystems/unstoppable-wallet-android
# Host deps:     docker or podman, plus curl (only when downloading the official APK)
# Notes:         F-Droid variant. Sibling of unstoppablewallet_build.sh (Play/split-only).
#
#                DISTRIBUTION FORM: F-Droid ships ONE fat APK per version
#                (io.horizontalsystems.bankwallet_<versionCode>.apk) built with
#                `assembleFdroidRelease`. There are no splits and no AAB anywhere in this
#                path, so there is no bundletool step. See
#                ~/work/ws-notes/review-notes/android-apk-forms-fat-universal-splits.md
#
#                SIGNER: F-Droid builds from source and signs with F-DROID's key, not the
#                developer's. fdroiddata declares no `Binaries:` and no
#                `AllowedAPKSigningKeys` for this app, so this is NOT F-Droid's
#                reproducible-builds republish mode. Expect a signer that differs from the
#                Play/GitHub artifacts; that is correct, not a finding.
#
#                FDROIDDATA PATCHES: F-Droid does NOT build the pristine tag. Per
#                metadata/io.horizontalsystems.bankwallet.yml the build applies:
#                  rm:       subscriptions-google-play
#                  prebuild: sed -i -e '/marketKit.sendStats/d' <StatsManager.kt>
#                This script reproduces both. Without them the build cannot match.
#
#                DEPENDENCIES: like the Play script, the twelve first-party
#                horizontalsystems kits are rebuilt from source and published to
#                mavenLocal, and any horizontalsystems JitPack fallback aborts the run.
#                F-Droid's own build does NOT do this (it consumes JitPack artifacts), so a
#                match here is a strictly stronger claim than F-Droid's.

SCRIPT_VERSION="v0.1.2"
SCRIPT_NAME="unstoppablefdroid_build.sh"
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
FDROID_REPO="https://f-droid.org/repo"
FDROID_API="https://f-droid.org/api/v1/packages/${APP_ID}"
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
version_code_arg=""

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        log_error "${flag} requires a value (got: '${val:-<nothing>}')"
        write_warning_yaml "${flag} requires a value"
        echo ""; echo "Exit code: 2"
        exit 2
    fi
}

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [--binary <apk>] [--version <name>] [--version-code <N>] [--arch a] [--type t]

  --binary       Official F-Droid APK. If omitted, the script downloads
                 ${FDROID_REPO}/${APP_ID}_<versionCode>.apk
  --version      versionName to verify, e.g. 0.50.1. Resolved to an F-Droid
                 versionCode via the API. Default: F-Droid's suggested version.
  --version-code F-Droid versionCode to download (default: suggested version from the
                 F-Droid API)
  --arch/--type  accepted and ignored; F-Droid publishes one fat APK per version
USAGE
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)      require_arg --version "${2:-}";      version_arg="$2";      shift 2 ;;
        --version-code) require_arg --version-code "${2:-}"; version_code_arg="$2"; shift 2 ;;
        --binary)       require_arg --binary  "${2:-}";      apk_file="$2";         shift 2 ;;
        --apk)          require_arg --apk     "${2:-}";      apk_file="$2";         shift 2 ;;
        --arch)         require_arg --arch    "${2:-}";      arch_arg="$2";         shift 2 ;;
        --type)         require_arg --type    "${2:-}";      type_arg="$2";         shift 2 ;;
        -h|--help)      usage; echo "Exit code: 0"; exit 0 ;;
        *)
            log_warn "Unknown parameter ignored: $1"
            shift
            ;;
    esac
done

[[ -n "$arch_arg" ]] && log_info "--arch ${arch_arg} accepted but not used (F-Droid ships one fat APK)"
[[ -n "$type_arg" ]] && log_info "--type ${type_arg} accepted but not used"

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
if [[ -z "$apk_file" ]]; then
    if ! command -v curl &>/dev/null; then
        log_error "curl not found in PATH and --binary was not supplied"
        write_warning_yaml "curl required to download the official F-Droid APK; or pass --binary"
        echo ""; echo "Exit code: 2"; exit 2
    fi
    printf "  %-12s OK  (%s)\n" "curl" "$(command -v curl)"
fi
echo "  Host requirement satisfied."

RUN_ID="unstoppablefdroid-$(date +%s)-$$"
IMG_P3="ws-unstoppablefdroid-source-${RUN_ID}"
CTR_P0="ws-unstoppablefdroid-p0-${RUN_ID}"
CTR_P3="ws-unstoppablefdroid-source-ctr-${RUN_ID}"
CTR_P5="ws-unstoppablefdroid-cmp-${RUN_ID}"

workspace="${execution_dir}/unstoppablefdroid_verification_${RUN_ID}"
DL_DIR="${workspace}/official"
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
    $CRUN rm -f "$CTR_P5" 2>/dev/null || true
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

mkdir -p "$DL_DIR" "$P0_DIR" "$P3_DIR" "$P5_DIR"

banner "UNSTOPPABLE WALLET (F-DROID) REPRODUCIBLE BUILD VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "  App ID:    ${APP_ID}"
echo "  Variant:   F-Droid (single fat APK, assembleFdroidRelease)"
echo "  Runtime:   ${CRUN} ($($CRUN --version 2>&1 | head -1))"
echo "  Workspace: ${workspace}"
echo "  Date:      $(date)"

# ---------------------------------------------------------------------------
# OFFICIAL ARTIFACT: download from F-Droid unless --binary was supplied.
# ---------------------------------------------------------------------------
banner "OFFICIAL ARTIFACT"

if [[ -n "$apk_file" ]]; then
    if [[ ! -f "$apk_file" ]]; then
        log_error "--binary path is not a file: $apk_file"
        write_warning_yaml "--binary path is not a file: ${apk_file}"
        echo ""; echo "Exit code: 2"; exit 2
    fi
    apk_file=$(realpath "$apk_file")
    log_info "Using supplied official APK: ${apk_file}"
else
    fdroid_version_code="$version_code_arg"
    if [[ -z "$fdroid_version_code" ]]; then
        log_info "Querying ${FDROID_API}"
        api_json=$(curl -fsSL "$FDROID_API" 2>/dev/null || true)
        if [[ -z "$api_json" ]]; then
            log_error "Could not reach the F-Droid package API"
            write_warning_yaml "F-Droid package API unreachable; pass --version-code or --binary"
            echo ""; echo "Exit code: 2"; exit 2
        fi
        # One JSON object per line so a versionName can be paired with its versionCode.
        api_lines=$(printf '%s' "$api_json" | tr '{' '\n')
        if [[ -n "$version_arg" ]]; then
            # --version selects the release: resolve versionName -> versionCode.
            esc_ver=$(printf '%s' "$version_arg" | sed 's/[][\.*^$/]/\\&/g')
            fdroid_version_code=$(printf '%s\n' "$api_lines" \
                | grep -E "\"versionName\"[[:space:]]*:[[:space:]]*\"${esc_ver}\"" \
                | grep -oE '"versionCode"[[:space:]]*:[[:space:]]*[0-9]+' \
                | grep -oE '[0-9]+' | head -1 || true)
            if [[ -z "$fdroid_version_code" ]]; then
                log_error "Version ${version_arg} is not published in the F-Droid repo"
                log_warn  "Versions currently available:"
                printf '%s\n' "$api_lines" \
                    | grep -oE '"versionName"[[:space:]]*:[[:space:]]*"[^"]+"' \
                    | sed -E 's/.*"([^"]+)"$/    \1/' | sort -u >&2 || true
                write_warning_yaml "Version ${version_arg} not published in the F-Droid repo"
                echo ""; echo "Exit code: 2"; exit 2
            fi
            log_info "--version ${version_arg} resolves to F-Droid versionCode ${fdroid_version_code}"
        else
            fdroid_version_code=$(printf '%s' "$api_json" \
                | grep -oE '"suggestedVersionCode"[[:space:]]*:[[:space:]]*[0-9]+' \
                | grep -oE '[0-9]+' | head -1 || true)
            log_info "No --version given; using suggested versionCode ${fdroid_version_code}"
        fi
    fi
    if [[ ! "$fdroid_version_code" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine an F-Droid versionCode"
        write_warning_yaml "Could not determine F-Droid versionCode; pass --version-code or --binary"
        echo ""; echo "Exit code: 2"; exit 2
    fi
    apk_url="${FDROID_REPO}/${APP_ID}_${fdroid_version_code}.apk"
    apk_file="${DL_DIR}/${APP_ID}_${fdroid_version_code}.apk"
    log_info "Downloading ${apk_url}"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$apk_file" "$apk_url"; then
        log_error "Download failed: ${apk_url}"
        write_warning_yaml "Failed to download official F-Droid APK: ${apk_url}"
        echo ""; echo "Exit code: 2"; exit 2
    fi
    log_success "Downloaded $(basename "$apk_file") ($(stat -c%s "$apk_file") bytes)"
    echo "  Source URL: ${apk_url}"
fi

official_size=$(stat -c%s "$apk_file")
app_hash=$(sha256of "$apk_file")
log_info "Official APK SHA-256: ${app_hash}"
log_info "Official APK size:    ${official_size} bytes"

# ---------------------------------------------------------------------------
# CONTAINER IMAGE (shared by metadata extraction, source build and comparison)
# ---------------------------------------------------------------------------
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
echo "  Extracting versionName, versionCode, signer from the official F-Droid APK..."
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
    echo "ERROR: official APK signature verification failed"
    printf '%s\n' "$signer_output"
    exit 1
}
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

pkg_id=$(cat "${P0_DIR}/pkg_name.txt" 2>/dev/null || echo "unknown")
if [[ "$pkg_id" != "$APP_ID" ]]; then
    log_error "APK app ID mismatch: expected $APP_ID, got ${pkg_id}"
    generate_error_yaml "ftbfs" "APK app ID mismatch: expected $APP_ID, got ${pkg_id}"
    echo ""; echo "Exit code: 1"; exit 1
fi
log_success "APK app ID verified: ${pkg_id}"

if [[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]]; then
    log_error "Requested --version ${version_arg} but the official APK reports versionName ${wallet_version}"
    generate_error_yaml "ftbfs" "Requested version ${version_arg} but official APK is ${wallet_version}"
    echo ""; echo "Exit code: 2"; exit 2
fi
if [[ "$wallet_version" == "unknown" || -z "$wallet_version" ]]; then
    log_error "Could not derive versionName from the official APK"
    generate_error_yaml "ftbfs" "Could not derive versionName from the official APK"
    echo ""; echo "Exit code: 1"; exit 1
fi

log_success "APK metadata: v${wallet_version} (code ${version_code})"
log_info    "Signer SHA-256: ${signer}"
log_info    "NOTE: F-Droid signs with its own key; this signer is expected to differ from the"
log_info    "      Google Play / GitHub artifacts of the same release."

banner "PHASE 1: BUILD DEPS FROM SOURCE + BUILD WALLET (F-DROID FLAVOR)"
echo "  Building horizontalsystems deps from source (zano: Kotlin/JNI wrapper only — links prebuilt .a blobs)."
echo "  HS versions are derived from wallet app/build.gradle at runtime."
echo "  fdroiddata patches are applied before the wallet build; see script header."
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


echo ""; echo "=== Step 6: Apply fdroiddata build modifications === $(date)"
# F-Droid does NOT build the pristine tag. metadata/io.horizontalsystems.bankwallet.yml
# declares, for this versionCode:
#     rm:       subscriptions-google-play
#     prebuild: sed -i -e '/marketKit.sendStats/d' <StatsManager.kt>
# Both are reproduced here. Each is asserted so a silent upstream layout change fails the
# run instead of quietly producing an unmatchable build.
cd /build/wallet

# (a) remove the Google Play subscriptions module and its settings entry
if [[ -d subscriptions-google-play ]]; then
    rm -rf subscriptions-google-play
    echo "[fdroiddata] removed subscriptions-google-play/"
else
    echo "ERROR: subscriptions-google-play/ not present; fdroiddata 'rm' no longer applies"
    exit 1
fi
settings_file=""
for f in settings.gradle.kts settings.gradle; do
    [[ -f "$f" ]] && settings_file="$f" && break
done
if [[ -z "$settings_file" ]]; then
    echo "ERROR: no settings.gradle(.kts) found"
    exit 1
fi
# Upstream guards the include with a directory-existence check precisely so fdroiddata's
# `rm` works:  if (file("subscriptions-google-play").exists()) { include(...) }
# So deleting the directory is sufficient and editing settings is WRONG — a blanket
# sed would remove the `if` line too and leave a dangling brace. Assert the guard is
# still there; if upstream ever makes the include unconditional, drop just that line.
if grep -qE 'file\("subscriptions-google-play"\)\.exists\(\)' "$settings_file"; then
    echo "[fdroiddata] ${settings_file} guards the include with file().exists(); no edit needed"
elif grep -qE '^[[:space:]]*include\(":subscriptions-google-play"\)' "$settings_file"; then
    sed -i -E '/^[[:space:]]*include\(":subscriptions-google-play"\)/d' "$settings_file"
    echo "[fdroiddata] removed unconditional include from ${settings_file}"
else
    echo "ERROR: ${settings_file} references subscriptions-google-play in an unrecognised form"
    grep -n 'subscriptions-google-play' "$settings_file" || true
    exit 1
fi

# (b) strip the stats call. Upstream moved this file between releases (app/ -> walletkit/),
#     so search rather than hardcode, and fail if no occurrence is found.
stats_files=$(grep -rl 'marketKit\.sendStats' --include='StatsManager.kt' . || true)
if [[ -z "$stats_files" ]]; then
    echo "ERROR: no StatsManager.kt containing marketKit.sendStats; fdroiddata prebuild no longer applies"
    exit 1
fi
for sf in $stats_files; do
    sed -i -e '/marketKit.sendStats/d' "$sf"
    echo "[fdroiddata] stripped marketKit.sendStats from ${sf}"
done
if grep -rq 'marketKit\.sendStats' --include='StatsManager.kt' .; then
    echo "ERROR: marketKit.sendStats still present after prebuild patch"
    exit 1
fi

# Record exactly what was changed relative to the tag, for the report.
git -C /build/wallet diff > /output/fdroiddata-patches.diff 2>/dev/null || true
git -C /build/wallet status --porcelain > /output/fdroiddata-status.txt 2>/dev/null || true

echo ""; echo "=== Step 7: Build wallet (assembleFdroidRelease) === $(date)"
sed -i 's/org\.gradle\.jvmargs=.*/org.gradle.jvmargs=-Xmx4096M -Dkotlin.daemon.jvm.options="-Xmx4096M"/' gradle.properties
rm -rf ~/.gradle/caches/
# F-Droid builds a single fat APK with `assemble`. There is no AAB and no bundletool in
# this path — do NOT substitute a bundle task here.
./gradlew :app:assembleFdroidRelease --no-daemon --max-workers=2 --info > /output/wallet-build.log 2>&1

# Modern AGP appends -unsigned to release APKs when no signing config is present. Accept
# either name rather than hardcoding one (a stale hardcoded name is a known false-FTBFS).
BUILT_APK=$(find app/build/outputs/apk/fdroid/release -name "*.apk" -type f 2>/dev/null | sort | head -1)
if [[ -z "$BUILT_APK" ]]; then
    echo "ERROR: build succeeded but no APK found under app/build/outputs/apk/fdroid/release"
    find app/build/outputs -type f -name "*.apk" || true
    exit 1
fi
echo "Built APK: ${BUILT_APK}"
mkdir -p /output/built
cp "$BUILT_APK" /output/built/built.apk

echo ""; echo "=== Step 8: Collect outputs === $(date)"
mkdir -p /output/patches
for dep_dir in /build/deps/*/; do
    dep_name=$(basename "$dep_dir")
    git -C "$dep_dir" diff > "/output/patches/${dep_name}.patch" 2>/dev/null || true
done

echo ""; echo "=== Step 9: Git tag verification === $(date)"
git -C /build/wallet log -1 --pretty=format:"%H" > /output/commit.txt 2>/dev/null || true
tag_obj_type=$(git -C /build/wallet cat-file -t __WALLET_VERSION__ 2>/dev/null || echo "unknown")
if [[ "$tag_obj_type" == "tag" ]]; then
    git -C /build/wallet tag -v __WALLET_VERSION__ > /output/git-tag-verify.txt 2>&1 || true
else
    echo "Tag __WALLET_VERSION__ is a ${tag_obj_type} (lightweight tag — GPG verification not possible; no signature to verify)" > /output/git-tag-verify.txt
fi

echo ""; echo "=== Source-build output ==="
sha256sum /output/built/built.apk

echo ""; echo "=== Dependency resolution check ==="
WLOG=/output/wallet-build.log
# grep -c prints 0 on no match but exits 1, so keep its output while neutralising the status.
HS_LOCAL=$(grep -E "horizontalsystems" "$WLOG" 2>/dev/null \
    | grep -Ec "\.m2/repository/com/github/horizontalsystems|mavenLocal" || true); HS_LOCAL=${HS_LOCAL:-0}
HS_JITPACK=$(grep -Eci "Downloading https://jitpack\.io/com/github/horizontalsystems|Downloaded from .*jitpack\.io/com/github/horizontalsystems" "$WLOG" 2>/dev/null || true); HS_JITPACK=${HS_JITPACK:-0}
echo "  HS resolution lines from mavenLocal: $HS_LOCAL  (expected: >0)"
echo "  HS packages from JitPack:            $HS_JITPACK (expected: 0)"
if [[ "$HS_LOCAL" -eq 0 || "$HS_JITPACK" -gt 0 ]]; then
    if [[ "$HS_JITPACK" -gt 0 ]]; then
        echo "  JitPack URLs detected:"
        grep -Ei "Downloading https://jitpack\.io/com/github/horizontalsystems|Downloaded from .*jitpack\.io/com/github/horizontalsystems" "$WLOG" | sed 's/^/    /' || true
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
$CRUN run \
    --name "$CTR_P3" \
    "${MEM_ARGS[@]}" \
    -v "$P3_DIR:/output" \
    -v "$p3_ctx/build.sh:/build/build.sh:ro" \
    "$IMG_P3" \
    bash /build/build.sh 2>&1 | tee "$P3_DIR/container-build.log"
P3_EXIT=${PIPESTATUS[0]}

if [[ $P3_EXIT -ne 0 ]]; then
    log_error "Source-build container exited with code $P3_EXIT"
    generate_error_yaml "ftbfs" "From-source build failed (exit ${P3_EXIT})"
    echo ""; echo "Exit code: 1"
    exit 1
fi
$CRUN rm -f "$CTR_P3" 2>/dev/null || true

BUILT_APK="$P3_DIR/built/built.apk"
if [[ ! -f "$BUILT_APK" ]]; then
    log_error "Source build produced no APK at $BUILT_APK"
    generate_error_yaml "ftbfs" "Source build produced no APK"
    echo ""; echo "Exit code: 1"; exit 1
fi
built_hash=$(sha256of "$BUILT_APK")
built_size=$(stat -c%s "$BUILT_APK")

section "Source-build results"
echo "  Built APK:   ${BUILT_APK}"
echo "  Built SHA-256: ${built_hash}"
echo "  Built size:    ${built_size} bytes"
echo "  Finished: $(date)"

commit="unknown"
[[ -f "$P3_DIR/commit.txt" ]] && commit=$(cat "$P3_DIR/commit.txt")
git_tag_info=""
[[ -f "$P3_DIR/git-tag-verify.txt" ]] && git_tag_info=$(cat "$P3_DIR/git-tag-verify.txt")

banner "PHASE 2: CONTENTS COMPARISON (single APK)"
echo "  Official F-Droid APK vs source-built APK; contents-only (signing ignored)."
echo "  Started: $(date)"

p5_ctx=$(mktemp -d)

cat > "$p5_ctx/compare.sh" <<'CMP_SCRIPT_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"

rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
# A silent unzip failure would leave an empty tree, which diff would then report as
# "no differences" — a false reproducible verdict. Both unpacks are fatal.
if ! unzip -q -o /input/official.apk -d /tmp/o; then
    echo "ERROR: failed to unpack the official APK"; exit 3
fi
if ! unzip -q -o /input/built.apk -d /tmp/b; then
    echo "ERROR: failed to unpack the built APK"; exit 3
fi
for d in /tmp/o /tmp/b; do
    if [[ "$(find "$d" -type f | head -1)" == "" ]]; then
        echo "ERROR: ${d} is empty after unpacking; refusing to compare"; exit 3
    fi
done

# Signing material is never comparable: F-Droid signs with its own key, our build is
# unsigned. Remove the whole root META-INF signing set on both sides before diffing.
find /tmp/o /tmp/b -maxdepth 2 -path '*/META-INF/*' \
    \( -iname '*.RSA' -o -iname '*.DSA' -o -iname '*.EC' -o -iname '*.SF' -o -iname 'MANIFEST.MF' \) \
    -print -delete | sed 's/^/  excluded (signing): /'

OFF_N=$(find /tmp/o -type f | wc -l)
BLT_N=$(find /tmp/b -type f | wc -l)
echo "  files compared: ${OFF_N} official, ${BLT_N} built"

diff -rq /tmp/o /tmp/b > /tmp/rawdiff.txt 2>&1
diff_rc=$?
# diff exits 0 (same) or 1 (differences). Anything else is a tool error, and treating it
# as "no differences" would be a false reproducible verdict.
if [[ "$diff_rc" -ne 0 && "$diff_rc" -ne 1 ]]; then
    echo "ERROR: diff -rq failed with exit ${diff_rc}; refusing to emit a verdict"
    sed 's/^/    /' /tmp/rawdiff.txt | head -20
    exit 3
fi
cnt=$(grep -E '^(Files|Only in)' /tmp/rawdiff.txt || true)
# Every line diff produced must be one we understand. An unparsed line (a permission
# error, a symlink warning) must not be silently dropped from the count.
unparsed=$(grep -vE '^(Files|Only in)' /tmp/rawdiff.txt | grep -v '^$' || true)
if [[ -n "$unparsed" ]]; then
    echo "ERROR: unrecognised diff output; refusing to emit a verdict"
    printf '%s\n' "$unparsed" | sed 's/^/    /' | head -20
    exit 3
fi
raw_total=$(printf '%s\n' "$cnt" | grep -c . || true); raw_total=${raw_total:-0}
if [[ "$diff_rc" -eq 1 && "$raw_total" -eq 0 ]]; then
    echo "ERROR: diff reported differences but none were parsed; refusing to emit a verdict"
    exit 3
fi
echo "  raw differences: ${raw_total}"
printf '%s\n' "$cnt" | head -5 | sed 's/^/    /'
[[ "$raw_total" -gt 5 ]] && echo "    ... full list: diff_full.txt"
printf '%s\n' "$cnt" > /out/diff_full.txt

acc=0; mat=0
declare -a MATERIAL=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rel=""
    if [[ "$line" =~ ^Files\ /tmp/o/(.*)\ and\ /tmp/b/.*\ differ$ ]]; then
        rel="${BASH_REMATCH[1]}"
    else
        # "Only in ..." — a file present on one side only is always material here; the
        # Play-only SourceStamp does not exist in the F-Droid channel.
        MATERIAL+=("$line"); mat=$((mat + 1)); continue
    fi

    case "$rel" in
        resources.arsc)
            # WS #574: a binary resources.arsc difference is acceptable ONLY when the
            # decoded resource tree is identical. Decode both and compare.
            rm -rf /tmp/do /tmp/db
            $APKTOOL d -f --no-src --no-debug-info -o /tmp/do /input/official.apk >/dev/null 2>&1
            $APKTOOL d -f --no-src --no-debug-info -o /tmp/db /input/built.apk    >/dev/null 2>&1
            if [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
                if diff -r /tmp/do/res /tmp/db/res > /out/diff_res.txt 2>&1; then
                    echo "  resources.arsc: binary differs, decoded res/ IDENTICAL — non-semantic artifact, acceptable (WS #574)"
                    acc=$((acc + 1))
                else
                    echo "  resources.arsc: decoded res/ DIFFERS — material (see diff_res.txt)"
                    head -5 /out/diff_res.txt | sed 's/^/    /'
                    MATERIAL+=("resources.arsc (decoded res/ differs)"); mat=$((mat + 1))
                fi
            else
                echo "  resources.arsc: decode failed on one side — not classified, treated as material"
                MATERIAL+=("resources.arsc (decode failed)"); mat=$((mat + 1))
            fi
            ;;
        AndroidManifest.xml)
            # F-Droid does not inject distribution metadata the way Google Play does, so
            # there is no allowlist here. Accept only if the decoded manifest is identical.
            rm -rf /tmp/do /tmp/db
            $APKTOOL d -f --no-src --no-debug-info -o /tmp/do /input/official.apk >/dev/null 2>&1
            $APKTOOL d -f --no-src --no-debug-info -o /tmp/db /input/built.apk    >/dev/null 2>&1
            if [[ -f /tmp/do/AndroidManifest.xml && -f /tmp/db/AndroidManifest.xml ]]; then
                if diff -u /tmp/do/AndroidManifest.xml /tmp/db/AndroidManifest.xml > /out/diff_manifest.txt 2>&1; then
                    echo "  AndroidManifest.xml: binary differs, decoded XML IDENTICAL — binary-encoding artifact, acceptable"
                    acc=$((acc + 1))
                else
                    echo "  AndroidManifest.xml: decoded XML DIFFERS — material (see diff_manifest.txt)"
                    head -5 /out/diff_manifest.txt | sed 's/^/    /'
                    MATERIAL+=("AndroidManifest.xml (decoded XML differs)"); mat=$((mat + 1))
                fi
            else
                echo "  AndroidManifest.xml: decode failed on one side — not classified, treated as material"
                MATERIAL+=("AndroidManifest.xml (decode failed)"); mat=$((mat + 1))
            fi
            ;;
        *)
            MATERIAL+=("$rel"); mat=$((mat + 1))
            ;;
    esac
done < <(printf '%s\n' "$cnt")

echo ""
echo "  acceptable: ${acc}"
echo "  material:   ${mat}"
if [[ "$mat" -gt 0 ]]; then
    echo "  material entries:"
    printf '    %s\n' "${MATERIAL[@]}" | head -20
fi

{
    echo "raw_total=${raw_total}"
    echo "acceptable=${acc}"
    echo "material=${mat}"
    printf '%s\n' "${MATERIAL[@]:-}" | sed 's/^/material_entry=/'
} > /out/summary.txt
CMP_SCRIPT_END
chmod +x "$p5_ctx/compare.sh"

$CRUN run --rm \
    --name "$CTR_P5" \
    "${MEM_ARGS[@]}" \
    -v "${apk_file}:/input/official.apk:ro" \
    -v "${BUILT_APK}:/input/built.apk:ro" \
    -v "${P5_DIR}:/out" \
    -v "${p5_ctx}/compare.sh:/compare.sh:ro" \
    "$IMG_P3" \
    bash /compare.sh 2>&1 | tee "$P5_DIR/comparison.log"
P5_EXIT=${PIPESTATUS[0]}

if [[ $P5_EXIT -ne 0 ]]; then
    log_error "Comparison phase failed (exit ${P5_EXIT})"
    generate_error_yaml "ftbfs" "Comparison phase failed (exit ${P5_EXIT})"
    echo ""; echo "Exit code: 1"; exit 1
fi

raw_total=$(sed -nE 's/^raw_total=([0-9]+)$/\1/p' "$P5_DIR/summary.txt" | head -1)
acc_count=$(sed -nE 's/^acceptable=([0-9]+)$/\1/p' "$P5_DIR/summary.txt" | head -1)
mat_count=$(sed -nE 's/^material=([0-9]+)$/\1/p'   "$P5_DIR/summary.txt" | head -1)
raw_total=${raw_total:-0}; acc_count=${acc_count:-0}; mat_count=${mat_count:-1}

section "Phase 2: VERDICT (judged on non-signature diffs)"
echo "  Raw differences:              ${raw_total}"
echo "  Acceptable per WS #574:       ${acc_count}"
echo "  Material (verdict-bearing):   ${mat_count}"
echo "  Acceptable-diffs policy: https://gitlab.com/walletscrutiny/walletScrutinyCom/-/issues/574"

if [[ "$mat_count" -eq 0 ]]; then
    VERDICT="reproducible"
    log_success "Verdict: REPRODUCIBLE (0 material diffs; ${acc_count} acceptable per WS #574)"
else
    VERDICT="not_reproducible"
    log_error "Verdict: NOT_REPRODUCIBLE (${mat_count} material diff(s))"
fi

echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${wallet_version}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${app_hash}"
echo "builtHash:      ${built_hash}"
echo "commit:         ${commit}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo "variant:        fdroid (single fat APK, assembleFdroidRelease)"
echo "rawDiffs:       ${raw_total}"
echo "acceptableDiffs:${acc_count} (WS #574)"
echo "materialDiffs:  ${mat_count}"
echo "method:         source-built fat APK vs official F-Droid APK, contents-only"
echo "fdroidPatches:  rm subscriptions-google-play; sed -e '/marketKit.sendStats/d' StatsManager.kt"
echo "jitpack:        no Horizontal Systems fallback allowed"
echo "signerNote:     F-Droid signs with its own key; differs from Play/GitHub artifacts by design"
[[ -n "$git_tag_info" ]] && echo "$git_tag_info"
echo "===== End Results ====="

generate_yaml "${VERDICT}" "Source-built F-Droid fat APK vs official F-Droid APK: ${raw_total} raw difference(s) after excluding root META-INF signing material, of which ${acc_count} are acceptable per WS issue 574 (decoded-identical resources or decoded-identical manifest) and ${mat_count} are material. Official APK SHA-256: ${app_hash}. Built APK SHA-256: ${built_hash}. F-Droid's own build consumes JitPack artifacts; this run rebuilt all Horizontal Systems dependencies from source and prohibited JitPack fallback. The fdroiddata build modifications (remove subscriptions-google-play; strip marketKit.sendStats) were reproduced from metadata/${APP_ID}.yml."

if [[ "$VERDICT" == "reproducible" ]]; then
    echo ""; echo "Exit code: 0"; exit 0
else
    echo ""; echo "Exit code: 1"; exit 1
fi
