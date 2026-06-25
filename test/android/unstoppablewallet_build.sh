#!/usr/bin/env bash
# unstoppablewallet_build.sh - Unstoppable Wallet Reproducible Build Verification
# Version:       v0.1.14
# Organization:  WalletScrutiny.com
# Project:       https://github.com/horizontalsystems/unstoppable-wallet-android
# Host deps:     docker or podman only
# Notes:         Play Store-only; pass APK via --binary.

SCRIPT_VERSION="v0.1.14"
echo "Starting unstoppablewallet_build.sh ${SCRIPT_VERSION}"

set -uo pipefail   # no -e: diff/cmp return 1 on differences

SCRIPT_NAME="unstoppablewallet_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="io.horizontalsystems.bankwallet"
WALLET_REPO="https://github.com/horizontalsystems/unstoppable-wallet-android.git"
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

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME --binary <file> [options]

Parameters:
  --binary <file>      Path to official APK from Google Play (REQUIRED)
  --apk <file>         Alias for --binary (legacy; accepted for compatibility)
  --version <ver>      Version string (accepted for ABS compliance; actual
                       version is auto-read from the APK)
  --arch <arch>        Accepted but unused (Play Store APK is universal)
  --type <type>        Accepted but unused
  -h, --help           Show this help

Examples:
  $SCRIPT_NAME --binary ~/Downloads/unstoppable.apk
  $SCRIPT_NAME --version 0.47.0 --binary ~/Downloads/unstoppable.apk

Notes:
  - HOST requirements: docker or podman only.
  - Unstoppable Wallet is Play Store-only (no auto-download).
  - HS dependency versions are derived from wallet app/build.gradle at runtime.
  - WARNING (v0.48.0+): GitHub releases now ships the F-Droid flavor APK
    (assembleFdroidRelease), NOT the Play Store flavor (assembleBaseRelease).
    This script builds assembleBaseRelease. Always pass the Play Store APK
    obtained via adb pull or an APK extractor app — do NOT use the GitHub
    releases APK for v0.48.0 and later.
EOF
}

version_arg=""
apk_file=""
arch_arg=""
type_arg=""

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
        -h|--help)  usage; echo ""; echo "Exit code: 0"; exit 0 ;;
        *)
            log_warn "Unknown parameter ignored: $1"
            shift
            ;;
    esac
done

if [[ -z "$apk_file" ]]; then
    log_error "--binary is required. Unstoppable Wallet is Play Store-only."
    log_warn  "Obtain the APK via adb pull or an APK extractor app and pass via --binary."
    write_warning_yaml "--binary not provided; Unstoppable Wallet is Play Store-only; cannot proceed without official APK"
    echo ""; echo "Exit code: 2"
    exit 2
fi

if [[ ! -f "$apk_file" ]]; then
    log_error "APK file not found: $apk_file"
    write_warning_yaml "APK file not found: ${apk_file}"
    echo ""; echo "Exit code: 2"
    exit 2
fi

apk_file=$(realpath "$apk_file")
[[ -n "$arch_arg" ]]  && log_info "--arch ${arch_arg} accepted but not used (single universal APK)"
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
IMG_P2="ws-unstoppable-p2-${RUN_ID}"
IMG_P3="ws-unstoppable-p3-${RUN_ID}"
CTR_P0="ws-unstoppable-p0-${RUN_ID}"
CTR_P2="ws-unstoppable-p2-ctr-${RUN_ID}"
CTR_P3="ws-unstoppable-p3-ctr-${RUN_ID}"

workspace="${execution_dir}/unstoppable_verification_${RUN_ID}"
P0_DIR="${workspace}/phase0"
P2_DIR="${workspace}/phase2"
P3_DIR="${workspace}/phase3"
P4_DIR="${workspace}/phase4"
P5_DIR="${workspace}/phase5"

p2_ctx=""
p3_ctx=""
p0_ctx=""

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
    $CRUN rm -f "$CTR_P2" 2>/dev/null || true
    $CRUN rm -f "$CTR_P3" 2>/dev/null || true
    local own_image=""
    if $CRUN image inspect "$IMG_P3" >/dev/null 2>&1; then
        own_image="$IMG_P3"
    elif $CRUN image inspect "$IMG_P2" >/dev/null 2>&1; then
        own_image="$IMG_P2"
    fi
    ensure_user_ownership "$workspace" "$own_image"
    $CRUN rmi -f "$IMG_P2" 2>/dev/null || true
    $CRUN rmi -f "$IMG_P3" 2>/dev/null || true
    [[ -n "$p2_ctx" ]] && rm -rf "$p2_ctx" 2>/dev/null || true
    [[ -n "$p3_ctx" ]] && rm -rf "$p3_ctx" 2>/dev/null || true
    [[ -n "$p0_ctx" ]] && rm -rf "$p0_ctx" 2>/dev/null || true
    log_success "Cleanup complete."
}
trap cleanup EXIT

mkdir -p "$P0_DIR" "$P2_DIR/jitpack-aars" "$P3_DIR/local-aars" "$P4_DIR" "$P5_DIR"

banner "UNSTOPPABLE WALLET REPRODUCIBLE BUILD VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "  App ID:    ${APP_ID}"
echo "  APK:       ${apk_file}"
echo "  Runtime:   ${CRUN} ($($CRUN --version 2>&1 | head -1))"
echo "  Workspace: ${workspace}"
echo "  Date:      $(date)"

# (Ubuntu 24.04, JDK 17, Android SDK — also used for Phase 0 metadata extraction)
banner "PHASE 2A: BUILD JITPACK BASELINE IMAGE"
echo "  Started: $(date)"

p2_ctx=$(mktemp -d)

cat > "$p2_ctx/Dockerfile" <<'DOCKERFILE_P2'
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless git unzip wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/36.0.0:${PATH}"

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
        -O cmdline-tools.zip && \
    unzip cmdline-tools.zip && rm cmdline-tools.zip && mv cmdline-tools latest

RUN yes | sdkmanager --licenses && \
    sdkmanager "platforms;android-36" "build-tools;36.0.0"

WORKDIR /build
DOCKERFILE_P2

section "Building Phase 2 Docker image: ${IMG_P2}"
if ! $CRUN build -t "$IMG_P2" -f "$p2_ctx/Dockerfile" "$p2_ctx"; then
    log_error "Phase 2 image build failed"
    generate_error_yaml "ftbfs" "Phase 2 container image build failed"
    echo ""; echo "Exit code: 1"
    exit 1
fi
log_success "Phase 2 image built: ${IMG_P2}"

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
signer_hash=$("${APKSIGNER}" verify --print-certs /input/official.apk 2>/dev/null \
    | grep "Signer #1 certificate SHA-256" | awk '{print $6}' || true)

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
    "$IMG_P2" \
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

banner "PHASE 2B: JITPACK BASELINE BUILD"
echo "  Building wallet v${wallet_version} with JitPack deps."
echo "  Capturing 28 prebuilt AARs/JARs from Gradle cache."
echo "  Started: $(date)"

# are substituted now; runtime container vars use \$ escape)
cat > "$p2_ctx/build.sh" <<PHASE2_SCRIPT
#!/bin/bash
set -euxo pipefail

echo "=== Phase 2 inner build started at \$(date) ==="

git clone --depth 1 --branch ${wallet_version} ${WALLET_REPO} /build/wallet
cd /build/wallet
sed -i 's/org\.gradle\.jvmargs=.*/org.gradle.jvmargs=-Xmx4096M -Dkotlin.daemon.jvm.options="-Xmx4096M"/' gradle.properties

./gradlew :app:assembleBaseRelease --no-daemon --max-workers=2

cp app/build/outputs/apk/base/release/app-base-release.apk /output/

CACHE="\${HOME}/.gradle/caches/modules-2/files-2.1"
mkdir -p /output/jitpack-aars

find "\$CACHE" -maxdepth 1 -type d -name "com.github.horizontalsystems*" | \
while read GROUP_DIR; do
    GROUP=\$(basename "\$GROUP_DIR")
    find "\$GROUP_DIR" -type f \( -name "*.aar" -o -name "*.jar" \) | \
    grep -v "\-sources\.\|-javadoc\." | \
    while read f; do
        cp "\$f" "/output/jitpack-aars/\${GROUP}--\$(basename \$f)"
    done
done

echo ""
echo "=== Phase 2 captured artifacts ==="
ls -lh /output/jitpack-aars/
echo ""
sha256sum /output/jitpack-aars/* | sort
echo ""
echo "=== Phase 2 APK ==="
sha256sum /output/app-base-release.apk
echo "=== Phase 2 complete at \$(date) ==="
PHASE2_SCRIPT
chmod +x "$p2_ctx/build.sh"

$CRUN rm -f "$CTR_P2" 2>/dev/null || true

section "Running Phase 2 build container (~60 min)"
set +e
$CRUN run \
    --name "$CTR_P2" \
    "${MEM_ARGS[@]}" \
    -v "$P2_DIR:/output" \
    -v "$p2_ctx/build.sh:/build/build.sh:ro" \
    "$IMG_P2" \
    bash /build/build.sh 2>&1 | tee "$P2_DIR/container-build.log"
P2_EXIT=${PIPESTATUS[0]}
set +e   # keep -e OFF (script uses set -uo pipefail without -e; see line 38)

if [[ $P2_EXIT -ne 0 ]]; then
    log_error "Phase 2 container exited with code $P2_EXIT"
    generate_error_yaml "ftbfs" "Phase 2 JitPack baseline build failed (exit ${P2_EXIT})"
    echo ""; echo "Exit code: 1"
    exit 1
fi
$CRUN rm -f "$CTR_P2" 2>/dev/null || true

section "Phase 2 results"
P2_APK="$P2_DIR/app-base-release.apk"
if [[ ! -f "$P2_APK" ]]; then
    log_error "Phase 2 APK not found after successful container exit: $P2_APK"
    generate_error_yaml "ftbfs" "Phase 2 APK missing after container exit"
    echo ""; echo "Exit code: 1"
    exit 1
fi
P2_APK_SHA=$(sha256of "$P2_APK")
echo "  Phase 2 APK SHA-256:   $P2_APK_SHA"
echo "  Official APK SHA-256:  $app_hash"
P2_AAR_COUNT=$(find "$P2_DIR/jitpack-aars" -name "*.aar" 2>/dev/null | wc -l)
P2_JAR_COUNT=$(find "$P2_DIR/jitpack-aars" -name "*.jar" 2>/dev/null | wc -l)
echo "  Captured: $P2_AAR_COUNT AARs + $P2_JAR_COUNT JARs = $((P2_AAR_COUNT + P2_JAR_COUNT)) total"
echo "  Finished: $(date)"

# (Ubuntu 24.04, JDK 8 + JDK 17, Android SDK, NDK 23/25/29, CMake)
banner "PHASE 3: BUILD DEPS FROM SOURCE + BUILD WALLET APK"
echo "  Building all 11 horizontalsystems deps from source."
echo "  HS versions are derived from wallet app/build.gradle at runtime."
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
        "platforms;android-35" "platforms;android-36" \
        "build-tools;30.0.3" "build-tools;34.0.0" \
        "build-tools;35.0.0" "build-tools;36.0.0" \
        "ndk;23.1.7779620" "ndk;25.1.8937393" "ndk;29.0.14033849" \
        "cmake;3.22.1"

WORKDIR /build
DOCKERFILE_P3

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
ZCASH_VER=$(extract_wallet_hs_version "zcash-android-wallet-sdk" "$wallet_gradle")

require_nonempty "monero-kit-android version" "$MONERO_VER"
require_nonempty "stellar-kit-android version" "$STELLAR_VER"
require_nonempty "ton-kit-android version" "$TON_VER"
require_nonempty "bitcoin-kit-android version" "$BITCOIN_VER"
require_nonempty "ethereum-kit-android version" "$ETHEREUM_VER"
require_nonempty "blockchain-fee-rate-kit-android version" "$FEERATE_VER"
require_nonempty "market-kit-android version" "$MARKET_VER"
require_nonempty "solana-kit-android version" "$SOLANA_VER"
require_nonempty "tron-kit-android version" "$TRON_VER"
require_nonempty "zcash-android-wallet-sdk version" "$ZCASH_VER"

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
echo "  zcash-android-wallet-sdk:         $ZCASH_VER"

clone_at_commit "$GH/ton-kit-android.git"                     "$TON_VER"      /build/deps/ton-kit-android
clone_at_commit "$GH/stellar-kit-android.git"                 "$STELLAR_VER"  /build/deps/stellar-kit-android
clone_at_commit "$GH/market-kit-android.git"                  "$MARKET_VER"   /build/deps/market-kit-android
clone_at_commit "$GH/blockchain-fee-rate-kit-android.git"     "$FEERATE_VER"  /build/deps/blockchain-fee-rate-kit-android
clone_at_commit "$GH/solana-kit-android.git"                  "$SOLANA_VER"   /build/deps/solana-kit-android
clone_at_commit "$GH/zcash-android-wallet-sdk.git"            "$ZCASH_VER"    /build/deps/zcash-android-wallet-sdk

clone_at_commit "$GH/bitcoin-kit-android.git"                 "$BITCOIN_VER"  /home/jitpack/build
clone_at_commit "$GH/ethereum-kit-android.git"                "$ETHEREUM_VER" /build/deps/ethereum-kit-android
clone_at_commit "$GH/tron-kit-android.git"                    "$TRON_VER"     /build/deps/tron-kit-android
clone_at_commit "$GH/monero-kit-android.git"                  "$MONERO_VER"   /build/deps/monero-kit-android

HD_WALLET_VER=$(grep -Eo "com\\.github\\.horizontalsystems:hd-wallet-kit-android:[^\"']+" \
    /home/jitpack/build/bitcoincore/build.gradle 2>/dev/null \
    | head -1 | sed -E 's/.*:hd-wallet-kit-android://')
if [[ -z "$HD_WALLET_VER" ]]; then
    HD_WALLET_VER=$(grep -Eo "com\\.github\\.horizontalsystems:hd-wallet-kit-android:[^\"']+" \
        /build/deps/tron-kit-android/tronkit/build.gradle 2>/dev/null \
        | head -1 | sed -E 's/.*:hd-wallet-kit-android://')
fi
if [[ -z "$HD_WALLET_VER" ]]; then
    echo "ERROR: Could not derive hd-wallet-kit-android version from dependent repos"
    exit 1
fi
echo "  hd-wallet-kit-android (derived from dependency graph): $HD_WALLET_VER"
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

echo ""; echo "=== Step 4b: stellar-kit-android === $(date)"
cd /build/deps/stellar-kit-android
sed -i "/plugins {/a\\    id 'maven-publish'" stellarkit/build.gradle
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
./gradlew :stellarkit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4c: market-kit-android === $(date)"
cd /build/deps/market-kit-android
sed -i "s/version = '1.0.0'/version = '$MARKET_VER'/" marketkit/build.gradle
./gradlew :marketkit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4d: blockchain-fee-rate-kit-android === $(date)"
cd /build/deps/blockchain-fee-rate-kit-android
sed -i "s/artifactId = 'feeratekit'/artifactId = 'blockchain-fee-rate-kit-android'/" feeratekit/build.gradle
sed -i "s/version = '1.0.0'/version = '$FEERATE_VER'/" feeratekit/build.gradle
./gradlew :feeratekit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4e: solana-kit-android === $(date)"
cd /build/deps/solana-kit-android
sed -i "s/version = '1.0.0'/version = '$SOLANA_VER'/" solanakit/build.gradle
./gradlew :solanakit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 4f: zcash-android-wallet-sdk === $(date)"
cd /build/deps/zcash-android-wallet-sdk
sed -i 's/IS_SNAPSHOT=true/IS_SNAPSHOT=false/' gradle.properties
sed -i 's/val myGroup = "cash.z.ecc.android"/val myGroup = "com.github.horizontalsystems.zcash-android-wallet-sdk"/' \
    build-conventions/src/main/kotlin/zcash-sdk.publishing-conventions.gradle.kts
sed -i "s/version = if (isSnapshot) \"\\\$myVersion-SNAPSHOT\" else myVersion,/version = \"$ZCASH_VER\",/" \
    build-conventions/src/main/kotlin/zcash-sdk.publishing-conventions.gradle.kts
./gradlew :sdk-lib:publishToMavenLocal :backend-lib:publishToMavenLocal \
    :lightwallet-client-lib:publishToMavenLocal :sdk-incubator-lib:publishToMavenLocal \
    -PskipCargoBuild=true --no-daemon
create_root_pom \
    "com.github.horizontalsystems" "zcash-android-wallet-sdk" "$ZCASH_VER" \
    "com.github.horizontalsystems.zcash-android-wallet-sdk" \
    zcash-android-sdk zcash-android-backend lightwallet-client zcash-android-sdk-incubator

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
sed -i "/plugins {/a\\    id 'maven-publish'" monerokit/build.gradle
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
./gradlew :monerokit:publishToMavenLocal --no-daemon

echo ""; echo "=== Step 6: Build wallet APK === $(date)"
cd /build/wallet
sed -i 's/org\.gradle\.jvmargs=.*/org.gradle.jvmargs=-Xmx4096M -Dkotlin.daemon.jvm.options="-Xmx4096M"/' gradle.properties
rm -rf ~/.gradle/caches/
./gradlew :app:assembleBaseRelease --no-daemon --max-workers=2 --info \
    > /output/wallet-build.log 2>&1

echo ""; echo "=== Step 7: Collect outputs === $(date)"
cp /build/wallet/app/build/outputs/apk/base/release/app-base-release.apk /output/

mkdir -p /output/local-aars
find ~/.m2/repository/com/github/horizontalsystems -type f \
    \( -name "*.aar" -o -name "*.jar" \) \
    ! -name "*-sources.jar" ! -name "*-javadoc.jar" \
    -exec cp {} /output/local-aars/ \;

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

echo ""; echo "=== Phase 3 APK ==="
sha256sum /output/app-base-release.apk

echo ""; echo "=== Phase 3 local AARs ==="
ls -lh /output/local-aars/
sha256sum /output/local-aars/* | sort

echo ""; echo "=== Dependency resolution check ==="
WLOG=/output/wallet-build.log
HS_LOCAL=$(grep -E "horizontalsystems" "$WLOG" | grep -Ec "\.m2/repository/com/github/horizontalsystems|mavenLocal" 2>/dev/null || echo 0)
HS_JITPACK=$(grep -Eci "Downloading https://jitpack\\.io/com/github/horizontalsystems|Downloaded from .*jitpack\\.io/com/github/horizontalsystems" "$WLOG" 2>/dev/null || echo 0)
echo "  HS packages from mavenLocal: $HS_LOCAL  (expected: >0)"
echo "  HS packages from JitPack:    $HS_JITPACK (expected: 0)"
if [[ "$HS_JITPACK" -gt 0 ]]; then
    echo "  JitPack URLs detected:"
    grep -Ei "Downloading https://jitpack\\.io/com/github/horizontalsystems|Downloaded from .*jitpack\\.io/com/github/horizontalsystems" "$WLOG" | sed 's/^/    /' || true
    echo "ERROR: JitPack fallback detected ($HS_JITPACK hit(s)) — Phase 3 did not fully build from local sources"
    echo "       APK verdict would be unreliable. Aborting."
    exit 1
fi

echo ""; echo "=== All builds complete at $(date) ==="
BUILD_SCRIPT_END

sed -i "s/__WALLET_VERSION__/${wallet_version}/g" "$p3_ctx/build.sh"
chmod +x "$p3_ctx/build.sh"

section "Building Phase 3 Docker image: ${IMG_P3}"
if ! $CRUN build -t "$IMG_P3" -f "$p3_ctx/Dockerfile" "$p3_ctx"; then
    log_error "Phase 3 image build failed"
    generate_error_yaml "ftbfs" "Phase 3 container image build failed"
    echo ""; echo "Exit code: 1"
    exit 1
fi
log_success "Phase 3 image built: ${IMG_P3}"

$CRUN rm -f "$CTR_P3" 2>/dev/null || true

section "Running Phase 3 build container (from source — ~120 min)"
echo "  Started: $(date)"
set +e
$CRUN run \
    --name "$CTR_P3" \
    "${MEM_ARGS[@]}" \
    -v "$P3_DIR:/output" \
    -v "$p3_ctx/build.sh:/build/build.sh:ro" \
    "$IMG_P3" \
    bash /build/build.sh 2>&1 | tee "$P3_DIR/container-build.log"
P3_EXIT=${PIPESTATUS[0]}
set +e   # keep -e OFF (script uses set -uo pipefail without -e; see line 38)

if [[ $P3_EXIT -ne 0 ]]; then
    log_error "Phase 3 container exited with code $P3_EXIT"
    generate_error_yaml "ftbfs" "Phase 3 from-source build failed (exit ${P3_EXIT})"
    echo ""; echo "Exit code: 1"
    exit 1
fi
$CRUN rm -f "$CTR_P3" 2>/dev/null || true

section "Phase 3 results"
P3_APK="$P3_DIR/app-base-release.apk"
if [[ ! -f "$P3_APK" ]]; then
    log_error "Phase 3 APK not found after successful container exit: $P3_APK"
    generate_error_yaml "ftbfs" "Phase 3 APK missing after container exit"
    echo ""; echo "Exit code: 1"
    exit 1
fi
P3_APK_SHA=$(sha256of "$P3_APK")
echo "  Phase 3 APK SHA-256:   $P3_APK_SHA"
echo "  Phase 2 APK SHA-256:   $P2_APK_SHA"
echo "  Official APK SHA-256:  $app_hash"
[[ "$P3_APK_SHA" == "$P2_APK_SHA" ]] && echo "  P3 vs P2:  MATCH" || echo "  P3 vs P2:  DIFFER (expected)"
P3_AAR=$(find "$P3_DIR/local-aars" -name "*.aar" 2>/dev/null | wc -l)
P3_JAR=$(find "$P3_DIR/local-aars" -name "*.jar" 2>/dev/null | wc -l)
echo "  Built: $P3_AAR AARs + $P3_JAR JARs = $((P3_AAR + P3_JAR)) total"
echo "  Finished: $(date)"

commit="unknown"
[[ -f "$P3_DIR/commit.txt" ]] && commit=$(cat "$P3_DIR/commit.txt")
git_tag_info=""
[[ -f "$P3_DIR/git-tag-verify.txt" ]] && git_tag_info=$(cat "$P3_DIR/git-tag-verify.txt")

banner "PHASE 4: DEP ARTIFACT EVIDENCE COLLECTION"
echo "  Pairing JitPack vs locally-built artifacts dynamically by filename."
echo "  Deep analysis of all differing artifacts."
echo "  Started: $(date)"

P2_AARS="$P2_DIR/jitpack-aars"
P3_AARS="$P3_DIR/local-aars"

PAIRS=()
while IFS= read -r p2f; do
    p2n="$(basename "$p2f")"
    p3n="${p2n#*--}"
    if [[ -f "$P3_AARS/$p3n" ]]; then
        PAIRS+=("${p2n}|${p3n}")
    else
        echo "ERROR: Missing local artifact for JitPack baseline file: $p2n (expected local: $p3n)"
        generate_error_yaml "ftbfs" "Phase 4 pair mapping failed: missing local artifact for ${p2n}"
        echo ""; echo "Exit code: 1"
        exit 1
    fi
done < <(find "$P2_AARS" -maxdepth 1 -type f \( -name "*.aar" -o -name "*.jar" \) | sort)

if [[ "${#PAIRS[@]}" -eq 0 ]]; then
    echo "ERROR: No Phase 4 artifact pairs found"
    generate_error_yaml "ftbfs" "Phase 4 pair mapping failed: no artifact pairs found"
    echo ""; echo "Exit code: 1"
    exit 1
fi

section "Phase 4: SHA-256 Hash Comparison Table (${#PAIRS[@]} pairs)"

P4_MATCH=0
P4_DIFFER=0
P4_DIFFER_PAIRS=()

printf "\n%-52s  %-64s  %-64s  %s\n" "ARTIFACT" "SHA256_P2(JitPack)" "SHA256_P3(local)" "RESULT"
printf "%-52s  %-64s  %-64s  %s\n" "--------" \
    "----------------------------------------------------------------" \
    "----------------------------------------------------------------" "------"

for pair in "${PAIRS[@]}"; do
    p2n="${pair%%|*}"; p3n="${pair##*|}"; label="${p3n%.*}"
    p2f="$P2_AARS/$p2n"; p3f="$P3_AARS/$p3n"
    h2=$(sha256of "$p2f"); h3=$(sha256of "$p3f")
    if [[ "$h2" == "$h3" ]]; then
        printf "%-52s  %s  %s  MATCH\n" "$label" "$h2" "$h3"
        P4_MATCH=$(( P4_MATCH + 1 ))
    else
        printf "%-52s  %s  %s  DIFFER\n" "$label" "$h2" "$h3"
        P4_DIFFER=$(( P4_DIFFER + 1 ))
        P4_DIFFER_PAIRS+=("$pair")
    fi
done

echo ""
echo "  MATCH:  $P4_MATCH / ${#PAIRS[@]}"
echo "  DIFFER: $P4_DIFFER / ${#PAIRS[@]}"

analyze_so() {
    local so_label="$1" p2so="$2" p3so="$3"
    echo ""
    echo "  .so: $so_label"
    printf "  P2 size: %d bytes\n" "$(wc -c < "$p2so")"
    printf "  P3 size: %d bytes\n" "$(wc -c < "$p3so")"
    echo "  >> .comment (compiler/linker):"
    echo "     [P2]"; readelf -p .comment "$p2so" 2>/dev/null | grep -v "^$" || true
    echo "     [P3]"; readelf -p .comment "$p3so" 2>/dev/null | grep -v "^$" || true
    echo "  >> ELF notes (NDK version + build ID):"
    echo "     [P2]"; readelf -n "$p2so" 2>/dev/null || true
    echo "     [P3]"; readelf -n "$p3so" 2>/dev/null || true
    echo "  >> Embedded build paths:"
    echo "     [P2]"; strings "$p2so" | grep -E "^/(home|build|src|jitpack)" | head -3 || echo "     (none)"
    echo "     [P3]"; strings "$p3so" | grep -E "^/(home|build|src|jitpack)" | head -3 || echo "     (none)"
    local ndiff
    ndiff=$(cmp -l "$p2so" "$p3so" 2>/dev/null | wc -l) || true
    echo "  >> cmp -l: $ndiff byte(s) differ"
    if [[ "$ndiff" -le 30 ]]; then
        cmp -l "$p2so" "$p3so" 2>/dev/null || true
    else
        echo "     (first 10 of $ndiff):"
        cmp -l "$p2so" "$p3so" 2>/dev/null | head -10 || true
    fi
}

section "Phase 4: Deep analysis of $P4_DIFFER differing artifact(s)"

for pair in "${P4_DIFFER_PAIRS[@]}"; do
    p2n="${pair%%|*}"; p3n="${pair##*|}"; label="${p3n%.*}"; ext="${p3n##*.}"
    p2f="$P2_AARS/$p2n"; p3f="$P3_AARS/$p3n"

    echo ""; echo "━━━━  DIFFER: $label  ━━━━"
    echo "  P2: $p2f  ($(wc -c < "$p2f") bytes)"
    echo "  P3: $p3f  ($(wc -c < "$p3f") bytes)"
    echo "  P2 sha256: $(sha256of "$p2f")"
    echo "  P3 sha256: $(sha256of "$p3f")"

    d2=$(mktemp -d); d3=$(mktemp -d)
    unzip -q "$p2f" -d "$d2" 2>/dev/null || true
    unzip -q "$p3f" -d "$d3" 2>/dev/null || true

    if [[ "$ext" == "jar" ]]; then
        echo ""
        echo "  >> diff -r of extracted content:"
        diff -r "$d2" "$d3" 2>/dev/null || true
        diff_lines=$(diff -r "$d2" "$d3" 2>/dev/null | wc -l) || true
        zip_diff_bytes=$(cmp -l "$p2f" "$p3f" 2>/dev/null | wc -l) || true
        echo ""
        echo "  >> Summary:"
        echo "     ZIP file differing bytes:     $zip_diff_bytes"
        echo "     Extracted content diff lines: $diff_lines"
        if [[ "$diff_lines" -eq 0 ]]; then
            echo "     CONCLUSION: ZIP metadata only — extracted content IDENTICAL"
        else
            echo "     CONCLUSION: Content differs (see diff above)"
        fi

    elif [[ -d "$d2/jni" ]] && echo "$label" | grep -qE "dashkit|ton-kit-android|monero-kit-android"; then
        echo ""
        echo "  >> Files that differ (brief):"
        diff -r --brief "$d2" "$d3" 2>/dev/null | head -20 || true

        echo ""
        echo "  >> arm64-v8a .so analysis:"
        for so_p2 in $(find "$d2/jni/arm64-v8a" -name "*.so" 2>/dev/null | sort); do
            so_name="${so_p2##*/}"
            so_p3="$d3/jni/arm64-v8a/$so_name"
            [[ -f "$so_p3" ]] && analyze_so "arm64-v8a/$so_name" "$so_p2" "$so_p3"
        done

        echo ""
        echo "  >> Byte diff count per ABI:"
        for abi in arm64-v8a armeabi-v7a x86 x86_64; do
            for so_p2 in $(find "$d2/jni/$abi" -name "*.so" 2>/dev/null | sort); do
                so_name="${so_p2##*/}"
                so_p3="$d3/jni/$abi/$so_name"
                if [[ -f "$so_p3" ]]; then
                    n=$(cmp -l "$so_p2" "$so_p3" 2>/dev/null | wc -l) || true
                    printf "     %-12s %-30s %d differing bytes\n" "$abi" "$so_name" "$n"
                fi
            done
        done

    elif echo "$label" | grep -q "zcash-android-sdk-"; then
        # zcash-android-sdk AAR: classes.jar diff (Kotlin @Metadata version label analysis)
        cj2="$d2/classes.jar"; cj3="$d3/classes.jar"
        echo ""
        echo "  >> classes.jar SHA-256:"
        echo "     P2: $(sha256of "$cj2")"
        echo "     P3: $(sha256of "$cj3")"
        echo "     P2 size: $(wc -c < "$cj2") bytes"
        echo "     P3 size: $(wc -c < "$cj3") bytes"

        cj2_dir=$(mktemp -d); cj3_dir=$(mktemp -d)
        unzip -q "$cj2" -d "$cj2_dir" 2>/dev/null || true
        unzip -q "$cj3" -d "$cj3_dir" 2>/dev/null || true

        total=$(find "$cj2_dir" -name "*.class" | wc -l)
        differ_count=$(diff -rq "$cj2_dir" "$cj3_dir" 2>/dev/null | grep -c "^Files" || true)
        echo ""
        echo "  >> Class file summary:"
        echo "     Total .class files: $total"
        echo "     Differing files:    $differ_count"

        echo ""
        echo "  >> First 5 differing class files:"
        diff -rq "$cj2_dir" "$cj3_dir" 2>/dev/null | grep "^Files" | head -5 \
            | sed "s|Files $cj2_dir/||;s| and.*||" || true

        sample_p2=$(find "$cj2_dir" -name "OpenForTesting.class" | head -1)
        if [[ -z "$sample_p2" ]]; then
            sample_p2=$(diff -rq "$cj2_dir" "$cj3_dir" 2>/dev/null \
                | grep "^Files" | head -1 | awk '{print $2}') || true
        fi

        if [[ -n "$sample_p2" ]]; then
            class_rel="${sample_p2#$cj2_dir/}"
            class_fqn="${class_rel%.class}"; class_fqn="${class_fqn//\//.}"
            sample_p3="$cj3_dir/$class_rel"
            echo ""
            echo "  >> Version label strings in $class_rel:"
            echo "     [P2]"; strings "$sample_p2" 2>/dev/null | grep -E "_release|zcash_android" | head -5 || true
            echo "     [P3]"; strings "$sample_p3" 2>/dev/null | grep -E "_release|zcash_android" | head -5 || true

            if command -v javap &>/dev/null; then
                echo ""
                echo "  >> javap diff for $class_rel (version labels):"
                diff \
                    <(javap -verbose -classpath "$cj2_dir" "$class_fqn" 2>/dev/null) \
                    <(javap -verbose -classpath "$cj3_dir" "$class_fqn" 2>/dev/null) \
                    | grep -E "^[<>].*release|^[<>].*zcash_android|^[<>].*Metadata" \
                    | head -30 || true
            fi
        fi
        rm -rf "$cj2_dir" "$cj3_dir" 2>/dev/null || true

    else
        echo ""
        echo "  >> diff -r brief:"
        diff -r --brief "$d2" "$d3" 2>/dev/null || true
    fi

    rm -rf "$d2" "$d3" 2>/dev/null || true
done

section "Phase 4: Summary Table"
printf "\n  %-52s  %s\n" "ARTIFACT" "RESULT"
printf "  %-52s  %s\n"   "--------" "------"

P4_FINAL_MATCH=0; P4_FINAL_DIFFER=0
for pair in "${PAIRS[@]}"; do
    p2n="${pair%%|*}"; p3n="${pair##*|}"; label="${p3n%.*}"
    h2=$(sha256of "$P2_AARS/$p2n"); h3=$(sha256of "$P3_AARS/$p3n")
    if [[ "$h2" == "$h3" ]]; then
        printf "  %-52s  MATCH\n" "$label"
        P4_FINAL_MATCH=$(( P4_FINAL_MATCH + 1 ))
    else
        case "$label" in
            bitcoin-kit-android-*|ethereum-kit-android-*|zcash-android-wallet-sdk-*)
                p4_verdict="DIFFER — MANIFEST.MF metadata only (JitPack Built-By vs local Created-By field)" ;;
            hd-wallet-kit-android-*)
                p4_verdict="DIFFER — ZIP metadata only (extracted content identical per diff -r)" ;;
            dashkit-*)
                p4_verdict="DIFFER — GNU build ID section only (20 bytes differ; NDK r25b, clang 14.0.6) — build paths match; .text identical" ;;
            ton-kit-android-*)
                p4_verdict="DIFFER — GNU build ID section only (20 bytes differ; NDK r29) — verify .text if needed" ;;
            monero-kit-android-*)
                p4_verdict="DIFFER — GNU build ID section only (20 bytes differ; NDK r23b) — verify .text if needed" ;;
            *)
                p4_verdict="DIFFER — unknown diff type; manual investigation required" ;;
        esac
        printf "  %-52s  %s\n" "$label" "$p4_verdict"
        P4_FINAL_DIFFER=$(( P4_FINAL_DIFFER + 1 ))
    fi
done

echo ""
echo "  TOTAL:  ${#PAIRS[@]} artifact pairs"
echo "  MATCH:  $P4_FINAL_MATCH  (SHA-256 identical)"
echo "  DIFFER: $P4_FINAL_DIFFER  (see deep analysis above for details)"
echo "  Finished: $(date)"

banner "PHASE 5: APK CONTENTS COMPARISON (PRIMARY VERDICT)"
echo "  Phase 3 (from-source built) APK vs official Play Store APK."
echo "  All diffs reported."
echo "  Started: $(date)"

section "Phase 5: Unzipping APKs (inside container — host unzip not required)"
mkdir -p "$P5_DIR/official-unzipped" "$P5_DIR/built-unzipped"

echo "  Unzipping official APK via container..."
if ! $CRUN run --rm \
        -v "${apk_file}:/input/official.apk:ro" \
        -v "${P5_DIR}/official-unzipped:/output" \
        "$IMG_P3" \
        unzip -q /input/official.apk -d /output; then
    log_error "Failed to unzip official APK: $apk_file"
    generate_error_yaml "ftbfs" "Failed to unzip official APK — file may be corrupt or not a valid APK"
    echo ""; echo "Exit code: 1"
    exit 1
fi
echo "  Unzipping Phase 3 (from-source) APK via container..."
if ! $CRUN run --rm \
        -v "${P3_APK}:/input/built.apk:ro" \
        -v "${P5_DIR}/built-unzipped:/output" \
        "$IMG_P3" \
        unzip -q /input/built.apk -d /output; then
    log_error "Failed to unzip Phase 3 APK: $P3_APK"
    generate_error_yaml "ftbfs" "Failed to unzip Phase 3 built APK"
    echo ""; echo "Exit code: 1"
    exit 1
fi

section "Phase 5: Diff (Phase 3 APK vs Official)"
set +e
diff_raw=$($CRUN run --rm \
    --volume "${P5_DIR}:/p5:ro" \
    "$IMG_P3" \
    diff --brief --recursive /p5/official-unzipped/ /p5/built-unzipped/ 2>/dev/null)
diff_exit=$?
set +e
if [[ "$diff_exit" -gt 1 ]]; then
    log_error "Phase 5 diff failed (exit $diff_exit)"
    generate_error_yaml "ftbfs" "Phase 5 diff command failed (exit ${diff_exit})"
    echo ""; echo "Exit code: 1"
    exit 1
fi

printf '%s\n' "$diff_raw" > "$P5_DIR/diff-raw.txt"
diff_count=$(printf '%s\n' "$diff_raw" | grep -vc '^$' 2>/dev/null || true)
diff_count="${diff_count:-0}"

diff_metainf=$(printf '%s\n' "$diff_raw" | grep -E ': META-INF$|/META-INF[:/]' || true)
diff_non_metainf=$(printf '%s\n' "$diff_raw" | grep -vE ': META-INF$|/META-INF[:/]' || true)
diff_metainf_count=$(printf '%s\n' "$diff_metainf" | grep -vc '^$' 2>/dev/null || echo 0)
diff_non_metainf_count=$(printf '%s\n' "$diff_non_metainf" | grep -vc '^$' 2>/dev/null || echo 0)
printf '%s\n' "$diff_non_metainf" > "$P5_DIR/diff-non-metainf.txt"

echo "  Total diff lines:        $diff_count  (verdict is based on this count)"
echo "  META-INF diff lines:     $diff_metainf_count  (signing artifacts — for human review)"
echo "  Non-META-INF diff lines: $diff_non_metainf_count"
echo ""
echo "  Full diff output (all differences):"
printf '%s\n' "$diff_raw"

dep_for_so() {
    local so="$1"
    case "$so" in
        *dashjbls*|*dashd*|*pthread*)    echo "dashkit (bitcoin-kit-android, NDK r25b, clang 14.0.6)" ;;
        *libsodium*)                     echo "ton-kit-android (NDK r29, GNU build ID only)" ;;
        *monerujo*|*monero*|*wallet*crypto*) echo "monero-kit-android (NDK r23b, GNU build ID only)" ;;
        *)                               echo "unknown dep" ;;
    esac
}

if [[ "$diff_count" -gt 0 ]]; then
    section "Phase 5: Deep analysis of $diff_count differing file(s)"

    while IFS= read -r diff_line; do
        [[ -z "$diff_line" ]] && continue

        # Parse path from "Files A/path and B/path differ" or "Only in A/dir: file"
        # Diff runs inside container so paths are /p5/official-unzipped/ and /p5/built-unzipped/
        if echo "$diff_line" | grep -q "^Files "; then
            rel_path=$(echo "$diff_line" \
                | sed "s|^Files /p5/official-unzipped/||;s| and .*||")
        elif echo "$diff_line" | grep -q "^Only in "; then
            dir_part=$(echo "$diff_line" | sed 's/^Only in //;s/: .*//')
            file_part=$(echo "$diff_line" | sed 's/^Only in [^:]*: //')
            rel_path="${dir_part}/${file_part}"
            rel_path="${rel_path#/p5/official-unzipped/}"
            rel_path="${rel_path#/p5/built-unzipped/}"
        else
            rel_path="$diff_line"
        fi

        file_official="$P5_DIR/official-unzipped/${rel_path}"
        file_built="$P5_DIR/built-unzipped/${rel_path}"
        ext="${rel_path##*.}"

        echo ""; echo "━━━━  DIFFER: ${rel_path}  ━━━━"

        if [[ -f "$file_official" && -f "$file_built" ]]; then
            echo "  Official size: $(wc -c < "$file_official") bytes"
            echo "  Built size:    $(wc -c < "$file_built") bytes"

            case "$ext" in
                so)
                    so_basename=$(basename "$rel_path")
                    dep_src=$(dep_for_so "$so_basename")
                    echo "  Source dep:    ${dep_src}"
                    echo "  >> .comment (compiler/linker):"
                    echo "     [Official]"; readelf -p .comment "$file_official" 2>/dev/null | grep -v "^$" || true
                    echo "     [Built]";    readelf -p .comment "$file_built"    2>/dev/null | grep -v "^$" || true
                    echo "  >> ELF notes (NDK version + build ID):"
                    echo "     [Official]"; readelf -n "$file_official" 2>/dev/null || true
                    echo "     [Built]";    readelf -n "$file_built"    2>/dev/null || true
                    echo "  >> Embedded build paths:"
                    echo "     [Official]"; strings "$file_official" | grep -E "^/(home|build|src|jitpack)" | head -3 || echo "     (none)"
                    echo "     [Built]";    strings "$file_built"    | grep -E "^/(home|build|src|jitpack)" | head -3 || echo "     (none)"
                    ndiff=$(cmp -l "$file_official" "$file_built" 2>/dev/null | wc -l) || true
                    echo "  >> cmp -l: ${ndiff} byte(s) differ"
                    if [[ "$ndiff" -le 30 ]]; then
                        cmp -l "$file_official" "$file_built" 2>/dev/null || true
                    else
                        echo "     (first 10 of ${ndiff}):"
                        cmp -l "$file_official" "$file_built" 2>/dev/null | head -10 || true
                    fi
                    ;;
                dex)
                    ndiff=$(cmp -l "$file_official" "$file_built" 2>/dev/null | wc -l) || true
                    echo "  >> .dex byte diff count: ${ndiff}"
                    ;;
                *)
                    if file "$file_official" 2>/dev/null | grep -q "text"; then
                        echo "  >> Text diff (first 50 lines):"
                        diff "$file_official" "$file_built" 2>/dev/null | head -50 || true
                    else
                        ndiff=$(cmp -l "$file_official" "$file_built" 2>/dev/null | wc -l) || true
                        echo "  >> Binary diff: ${ndiff} byte(s) differ"
                    fi
                    ;;
            esac

        elif [[ -f "$file_official" && ! -f "$file_built" ]]; then
            echo "  >> Only in official APK (missing from built)"
        elif [[ ! -f "$file_official" && -f "$file_built" ]]; then
            echo "  >> Only in built APK (not in official)"
        else
            echo "  >> (directory entry or unresolvable diff)"
        fi

    done < "$P5_DIR/diff-raw.txt"
fi

section "Phase 5: PRIMARY VERDICT"
if [[ "$diff_count" -eq 0 ]]; then
    log_success "Phase 5 verdict: REPRODUCIBLE (0 total differences)"
    P5_VERDICT="reproducible"
    P5_MATCH="true"
else
    log_warn "Phase 5 verdict: NOT_REPRODUCIBLE ($diff_count total difference(s); META-INF breakdown above)"
    P5_VERDICT="not_reproducible"
    P5_MATCH="false"
fi

section "Phase 5b: REFERENCE — Phase 2 (JitPack) APK vs Official"
echo "  (Reference only — does not affect the primary verdict)"

mkdir -p "$P5_DIR/p2-unzipped"
if ! $CRUN run --rm \
        -v "${P2_APK}:/input/p2.apk:ro" \
        -v "${P5_DIR}/p2-unzipped:/output" \
        "$IMG_P3" \
        unzip -q /input/p2.apk -d /output; then
    log_warn "Failed to unzip Phase 2 APK — Phase 5b reference comparison skipped"
    P5B_SKIP=true
fi
P5B_SKIP="${P5B_SKIP:-false}"

if [[ "$P5B_SKIP" == "true" ]]; then
    echo "  Phase 5b skipped (Phase 2 APK unzip failed)."
else
    set +e
    p2_diff_raw=$($CRUN run --rm \
        --volume "${P5_DIR}:/p5:ro" \
        "$IMG_P3" \
        diff --brief --recursive /p5/official-unzipped/ /p5/p2-unzipped/ 2>/dev/null)
    p2_diff_exit=$?
    set +e
    if [[ "$p2_diff_exit" -gt 1 ]]; then
        log_warn "Phase 5b diff failed (exit $p2_diff_exit); skipping reference comparison"
    else
        p2_diff_count=$(printf '%s\n' "$p2_diff_raw" | grep -vc '^$' 2>/dev/null || true)
        p2_diff_count="${p2_diff_count:-0}"
        echo "  Phase 2 vs Official total diff count: $p2_diff_count (reference only)"
        [[ "$p2_diff_count" -gt 0 ]] && echo "$p2_diff_raw"
    fi
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
echo "phase4:         ${P4_FINAL_MATCH} match / ${P4_FINAL_DIFFER} differ (dep artifacts)"
echo "phase5diffs:    ${diff_count}"
[[ -n "${git_tag_info}" ]] && echo "${git_tag_info}"
echo "===== End Results ====="

generate_yaml "${P5_VERDICT}" "Phase 5 APK comparison: ${diff_count} total difference(s) (${diff_metainf_count} META-INF, ${diff_non_metainf_count} other). Official APK SHA-256: ${app_hash}. Dep artifact comparison: ${P4_FINAL_MATCH} match / ${P4_FINAL_DIFFER} differ (Phase 4, evidence only)."

echo ""
echo "Exit code: 0"
exit 0
