#!/bin/bash
# ==============================================================================
# peachbitcoin_build.sh - Peach Bitcoin Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.12
# Organization:  WalletScrutiny.com
# Last Modified: 2026-02-26
# Project:       https://github.com/Peach2Peach/peach-app
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Requires official split APKs directory via --apk (from apkextractor_sync.sh)
# - Peach Bitcoin uses AAB on Play Store; produces: base.apk + split_config.arm64_v8a.apk
#   + split_config.en.apk + split_config.xxhdpi.apk
# - Auto-generates device-spec.json from the split APK filenames and base.apk metadata
# - Builds AAB inside a container (Ubuntu 22.04, JDK 17, Node 20, NDK 27.1.12297006 + 23.1.7779620)
# - Clones repo at tag derived from base.apk versionCode: v<name>(<code>)
# - Runs npm ci + Metro bundler + Gradle bundleProdRelease
# - Uses bundletool to extract split APKs from the built AAB
# - Compares each split pair: official vs built (META-INF filtered in verdict)
# - Generates COMPARISON_RESULTS.yaml with per-split file entries

set -uo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.2.12"
APP_ID="com.peachbitcoin.peach.mainnet"
REPO_URL="https://github.com/Peach2Peach/peach-app.git"
WS_CONTAINER="docker.io/walletscrutiny/android:5"
UTILITY_IMAGE="ubuntu:24.04"
BUILD_ENV_IMAGE="peachbitcoin_build_env"
BUNDLETOOL_VERSION="1.18.1"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"
build_timestamp="$(date -u +%Y%m%d%H%M%S)"
build_pid="$$"

# ------------------------------------------------------------------------------
# State variables
# ------------------------------------------------------------------------------
requested_version=""
requested_arch="arm64-v8a"
requested_type=""
requested_tag=""
splits_input_dir=""        # --apk: directory containing official split APKs
should_cleanup=false

version_name=""
version_code=""
git_ref=""
signer=""
official_base_hash=""
commit_hash="unknown"

verdict=""
yaml_status="not_reproducible"
total_diff_count=0
additional_info=""
work_dir=""

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*"; }

append_info() {
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n$1"
  else
    additional_info="$1"
  fi
}

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------
generate_error_yaml() {
  local status="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  {
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%S+0000')"
    echo "script_version: ${SCRIPT_VERSION}"
    echo "build_type: ${requested_type:-apk}"
    echo "results:"
    echo "  - architecture: ${requested_arch}"
    echo "    status: ${status}"
    echo "    files: []"
    if [[ -n "${additional_info}" ]]; then
      echo "additional_info: |"
      echo -e "${additional_info}" | sed 's/^/  /'
    fi
  } > "${yaml_file}"
}

die_invalid() {
  log_error "$*"
  generate_error_yaml "warning"
  echo "Exit code: ${EXIT_INVALID}"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  generate_error_yaml "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}

on_error() {
  local exit_code=$?
  local line_no=$1
  set +e
  log_error "Script failed at line ${line_no} (exit code ${exit_code})"
  generate_error_yaml "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Container runtime detection
# ------------------------------------------------------------------------------
CONTAINER_CMD=""
VOLUME_RO_SUFFIX=""
VOLUME_RW_SUFFIX=""

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  VOLUME_RW_SUFFIX=""
else
  echo "[ERROR] Neither podman nor docker is available."
  exit "${EXIT_FAILED}"
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       peachbitcoin_build.sh - Peach Bitcoin reproducible build verification (split APKs)

SYNOPSIS
       ${script_name} --version <version> --apk <splits_dir> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds Peach Bitcoin as an AAB from source, extracts split APKs via bundletool,
       and compares them split-by-split against official splits from the Play Store.

       Use apkextractor_sync.sh to pull splits from device first:
         apkextractor_sync.sh com.peachbitcoin.peach.mainnet
       Then pass the resulting splits directory to --apk:
         --apk /var/shared/apk/com.peachbitcoin.peach.mainnet/0.69.0/splits

       The splits directory must contain: base.apk + split_config.*.apk files.

OPTIONS
       --version <version>   App version name (e.g. 0.69.0)
       --apk <dir>           Path to directory containing official split APKs (required)
       --arch <arch>         ABI for device-spec (default: arm64-v8a; auto-detected from splits)
       --tag <ref>           Git tag override (default: v<version>(<versionCode>))
                             Example: --tag 'v0.69.0(330)'
       --type <type>         Accepted for build server compatibility (silently ignored)
       --cleanup             Remove work directory after completion
       --script-version      Print script version and exit
       --help                Show this help and exit

EXIT CODES
       0    All splits identical (META-INF only diffs acceptable)
       1    Differences found or build failed
       2    Invalid parameters

EXAMPLES
       ${script_name} --version 0.69.0 --apk /var/shared/apk/com.peachbitcoin.peach.mainnet/0.69.0/splits
       ${script_name} --version 0.69.0 --apk ~/peach-splits --tag 'v0.69.0(330)'
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
require_arg() {
  if [[ -z "${2:-}" || "${2}" == --* ]]; then
    die_invalid "Option ${1} requires a non-empty value."
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)        require_arg "$1" "${2:-}"; requested_version="$2"; shift ;;
    --apk)            require_arg "$1" "${2:-}"; splits_input_dir="$2"; shift ;;
    --arch)           require_arg "$1" "${2:-}"; requested_arch="$2"; shift ;;
    --tag)            require_arg "$1" "${2:-}"; requested_tag="$2"; shift ;;
    --type)           require_arg "$1" "${2:-}"; requested_type="$2"; shift ;;
    --cleanup)        should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help)           usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *)                die_invalid "Unknown argument: $1" ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------
if [[ -z "${requested_version}" ]]; then
  die_invalid "--version is required."
fi

if [[ -z "${splits_input_dir}" ]]; then
  die_invalid "--apk is required. Provide the directory containing official split APKs. Peach Bitcoin does not publish APKs on GitHub. Use apkextractor_sync.sh to pull from device."
fi

if [[ ! -d "${splits_input_dir}" ]]; then
  die_invalid "--apk path is not a directory: ${splits_input_dir}"
fi

if [[ ! -f "${splits_input_dir}/base.apk" ]]; then
  die_invalid "base.apk not found in ${splits_input_dir}. Expected: base.apk, split_config.arm64_v8a.apk, ..."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

case "${requested_arch}" in
  arm64-v8a|armeabi-v7a|x86_64|x86) ;;
  *) die_invalid "Unsupported --arch '${requested_arch}'. Supported: arm64-v8a, armeabi-v7a, x86_64, x86." ;;
esac

version_name="${requested_version}"

if [[ -n "${requested_type}" ]]; then
  append_info "Build type '${requested_type}' accepted for compatibility; Peach Bitcoin has a single build type."
fi

# ------------------------------------------------------------------------------
# APK inspection helpers (via WS container)
# ------------------------------------------------------------------------------
container_aapt_field() {
  local apk_path="$1"
  local field="$2"
  local apk_dir apk_name
  apk_dir="$(dirname "$(realpath "${apk_path}")")"
  apk_name="$(basename "${apk_path}")"
  ${CONTAINER_CMD} run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "aapt dump badging /apk/${apk_name} 2>/dev/null | sed -n \"s/.*${field}='\\([^']*\\)'.*/\\1/p\" | head -n1"
}

container_sha256() {
  local file_path="$1"
  local file_dir file_name
  file_dir="$(dirname "$(realpath "${file_path}")")"
  file_name="$(basename "${file_path}")"
  ${CONTAINER_CMD} run --rm \
    --volume "${file_dir}:/data${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "sha256sum /data/${file_name} | awk '{print \$1}'"
}

container_diff() {
  local dir_a="$1"
  local dir_b="$2"
  ${CONTAINER_CMD} run --rm \
    --volume "${dir_a}:/a${VOLUME_RO_SUFFIX}" \
    --volume "${dir_b}:/b${VOLUME_RO_SUFFIX}" \
    "${UTILITY_IMAGE}" \
    diff -qr /a /b 2>/dev/null || true
}

container_signer() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$(realpath "${apk_path}")")"
  apk_name="$(basename "${apk_path}")"
  ${CONTAINER_CMD} run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apksigner verify --print-certs /apk/${apk_name} 2>/dev/null | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

# ------------------------------------------------------------------------------
# Step 1: Inspect official splits
# ------------------------------------------------------------------------------
log_info "========================================"
log_info " Peach Bitcoin Build Verification"
log_info " Script: ${SCRIPT_VERSION}"
log_info "========================================"

splits_input_dir="$(realpath "${splits_input_dir}")"
base_apk="${splits_input_dir}/base.apk"

log_info "Inspecting official splits in: ${splits_input_dir}"
log_info "Contents:"
ls -lh "${splits_input_dir}/" | grep '\.apk$' | awk '{print "  " $5 "\t" $9}' || true

version_name_apk="$(container_aapt_field "${base_apk}" "versionName")"
version_code="$(container_aapt_field "${base_apk}" "versionCode")"
pkg_name="$(container_aapt_field "${base_apk}" "name")"
sdk_version="$(container_aapt_field "${base_apk}" "sdkVersion")"

log_info "  Package:      ${pkg_name:-<not detected>}"
log_info "  Version name: ${version_name_apk:-<not detected>}"
log_info "  Version code: ${version_code:-<not detected>}"
log_info "  SDK version:  ${sdk_version:-<not detected>}"

if [[ -n "${version_name_apk}" && "${version_name_apk}" != "${version_name}" ]]; then
  log_warn "base.apk versionName (${version_name_apk}) != --version (${version_name})."
  append_info "Version mismatch: --version=${version_name}, APK versionName=${version_name_apk}."
fi

# Derive git tag (Peach format: v0.69.0(330))
if [[ -n "${requested_tag}" ]]; then
  git_ref="${requested_tag}"
  log_info "Using --tag override: ${git_ref}"
elif [[ -n "${version_code}" ]]; then
  git_ref="v${version_name}(${version_code})"
  log_info "Derived git tag: ${git_ref}"
else
  git_ref="v${version_name}"
  log_warn "Could not read versionCode; using fallback tag: ${git_ref}"
  append_info "versionCode not detected; using fallback tag ${git_ref}."
fi

official_base_hash="$(container_sha256 "${base_apk}")"
signer="$(container_signer "${base_apk}")"
log_info "base.apk SHA-256: ${official_base_hash}"
log_info "Signer:           ${signer}"

# Collect all official split APK paths
mapfile -t official_split_files < <(ls "${splits_input_dir}"/*.apk 2>/dev/null | sort)
log_info "Official splits found: ${#official_split_files[@]}"
for f in "${official_split_files[@]}"; do
  log_info "  $(basename "${f}")"
done

# ------------------------------------------------------------------------------
# Step 2: Auto-generate device-spec.json
# ------------------------------------------------------------------------------
log_info "Generating device-spec.json from splits..."

# Detect ABI from split filename (split_config.arm64_v8a.apk → arm64-v8a)
detected_abi="${requested_arch}"
abi_from_split=""
for f in "${official_split_files[@]}"; do
  fname="$(basename "${f}")"
  case "${fname}" in
    split_config.arm64_v8a.apk)  abi_from_split="arm64-v8a" ;;
    split_config.armeabi_v7a.apk) abi_from_split="armeabi-v7a" ;;
    split_config.x86_64.apk)     abi_from_split="x86_64" ;;
    split_config.x86.apk)        abi_from_split="x86" ;;
  esac
done
if [[ -n "${abi_from_split}" ]]; then
  detected_abi="${abi_from_split}"
  log_info "ABI detected from split filename: ${detected_abi}"
fi
requested_arch="${detected_abi}"

# Detect screen density from split filename
screen_density="480"   # xxhdpi default
for f in "${official_split_files[@]}"; do
  fname="$(basename "${f}")"
  case "${fname}" in
    split_config.xxxhdpi.apk) screen_density="640" ;;
    split_config.xxhdpi.apk)  screen_density="480" ;;
    split_config.xhdpi.apk)   screen_density="320" ;;
    split_config.hdpi.apk)    screen_density="240" ;;
    split_config.mdpi.apk)    screen_density="160" ;;
    split_config.ldpi.apk)    screen_density="120" ;;
  esac
done

# Detect supported locales from split filenames (accumulate all, don't overwrite)
locale_list=""
for f in "${official_split_files[@]}"; do
  fname="$(basename "${f}")"
  if [[ "${fname}" =~ split_config\.([a-z]{2,3})\.apk$ ]]; then
    locale="${BASH_REMATCH[1]}"
    # Skip ABI/density tokens that are not locales
    case "${locale}" in
      arm64|armeabi|x86|hdpi|xhdpi|xxhdpi|xxxhdpi|mdpi|ldpi) continue ;;
      *) locale_list+="${locale_list:+,}\"${locale}\"" ;;
    esac
  fi
done
locale_list="${locale_list:-\"en\"}"

sdk_val="${sdk_version:-36}"

log_info "device-spec.json:"
log_info "  supportedAbis:    [\"${detected_abi}\", \"armeabi-v7a\"]"
log_info "  screenDensity:    ${screen_density}"
log_info "  supportedLocales: [${locale_list}]"
log_info "  sdkVersion:       ${sdk_val}"

# ------------------------------------------------------------------------------
# Step 3: Set up work directory
# ------------------------------------------------------------------------------
work_dir="${execution_dir}/workdir_peachbitcoin_${version_name}_${requested_arch}_${build_timestamp}_${build_pid}"
mkdir -p "${work_dir}"
log_info "Work directory: ${work_dir}"

# Write device-spec.json
cat > "${work_dir}/device-spec.json" <<EOF
{
  "supportedAbis": ["${detected_abi}", "armeabi-v7a"],
  "supportedLocales": [${locale_list}],
  "screenDensity": ${screen_density},
  "sdkVersion": ${sdk_val}
}
EOF
log_info "device-spec.json written to: ${work_dir}/device-spec.json"

# Copy official splits to work_dir for clean access
official_splits_dir="${work_dir}/official-split-apks"
mkdir -p "${official_splits_dir}"
cp "${splits_input_dir}"/*.apk "${official_splits_dir}/"

# ------------------------------------------------------------------------------
# Step 4: Build the build-environment Docker image
# ------------------------------------------------------------------------------
build_image="${BUILD_ENV_IMAGE}:${version_name//[^a-zA-Z0-9._-]/_}"
log_info "Building build environment image: ${build_image}"
log_info "First run downloads JDK 17, Node 20, Android SDK, NDK 27.1.12297006 + 23.1.7779620, bundletool (~2 GB)."

${CONTAINER_CMD} build \
  --ulimit nofile=65536:65536 \
  --build-arg "GIT_REF=${git_ref}" \
  --build-arg "BUNDLETOOL_VERSION=${BUNDLETOOL_VERSION}" \
  -t "${build_image}" - << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.1.12297006
ENV PATH=${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    git \
    wget \
    curl \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    python3 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 20.x (LTS) ───────────────────────────────────────────────────────
# NOTE: nodesource setup_20.x installs the latest 20.x patch at build time; the
# exact patch version is not pinned here. If strict Node version pinning is
# required, replace with a direct binary download of a specific Node 20.x.y release.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ── Android command-line tools ───────────────────────────────────────────────
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-12266719_latest.zip \
         -O /tmp/cmdtools.zip && \
    unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools_extract && \
    mv /tmp/cmdtools_extract/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm -rf /tmp/cmdtools.zip /tmp/cmdtools_extract

# ── Android SDK: platform 36, build-tools 36, NDK 27.1.12297006, CMake ───────
RUN yes | sdkmanager --licenses > /dev/null 2>&1 || true && \
    sdkmanager \
        "platforms;android-36" \
        "build-tools;36.0.0" \
        "ndk;27.1.12297006" \
        "ndk;23.1.7779620" \
        "cmake;3.22.1" \
        "platform-tools"

# ── bundletool (for extracting split APKs from built AAB) ───────────────────
ARG BUNDLETOOL_VERSION
RUN wget -q "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
         -O /usr/local/lib/bundletool.jar

# ── Clone repo at the release tag ────────────────────────────────────────────
ARG GIT_REF
RUN git clone https://github.com/Peach2Peach/peach-app.git /build/peach-app && \
    cd /build/peach-app && \
    git -c advice.detachedHead=false checkout "${GIT_REF}" && \
    git submodule update --init --recursive

# ── Point Gradle at the SDK ──────────────────────────────────────────────────
RUN echo "sdk.dir=${ANDROID_HOME}" > /build/peach-app/android/local.properties

# ── Debug keystore + signing config (for bundleProdRelease) ──────────────────
# signingConfigs.debug in build.gradle is overridden to use MYAPP_RELEASE_* vars.
# Generate a throwaway debug keystore so the build can sign without developer keys.
RUN mkdir -p /root/.android && \
    keytool -genkey -v \
        -keystore /root/.android/debug.keystore \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" 2>/dev/null && \
    printf '\nMYAPP_RELEASE_STORE_FILE=/root/.android/debug.keystore\nMYAPP_RELEASE_STORE_PASSWORD=android\nMYAPP_RELEASE_KEY_ALIAS=androiddebugkey\nMYAPP_RELEASE_KEY_PASSWORD=android\n' \
        >> /build/peach-app/android/gradle.properties

# ── Yarn (required by bdk-rn prepare script) ─────────────────────────────────
RUN npm install -g yarn

# ── Install Node.js dependencies (exact lock file) ───────────────────────────
RUN cd /build/peach-app && npm ci

# ── .env.production with mainnet API endpoints ───────────────────────────────
RUN printf 'API_URL=https://api.peachbitcoin.com\nGROUPHUG_URL=https://grouphug.peachbitcoin.com\nESPLORA_URL=https://btc1.electrs.peachbitcoin.com\nBLOCKEXPLORER=https://mempool.space\nNODE_TYPE=CUSTOM\nNETWORK=mainnet\nDEV=false\n' \
    > /build/peach-app/.env.production

# ── Disable Crashlytics native symbol upload ─────────────────────────────────
RUN echo "firebaseCrashlytics.nativeSymbolUploadEnabled=false" \
    >> /build/peach-app/android/gradle.properties

WORKDIR /build/peach-app
DOCKERFILE

# ------------------------------------------------------------------------------
# Step 5: Extract commit hash and git tag/signature info
# ------------------------------------------------------------------------------
commit_hash="$(${CONTAINER_CMD} run --rm "${build_image}" git -C /build/peach-app rev-parse HEAD 2>/dev/null || echo "unknown")"
log_info "Commit hash: ${commit_hash}"

tag_type="commit-only"
tag_signature_status="[INFO] No tag found"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""
tag_output=""

tag_exists="$(${CONTAINER_CMD} run --rm "${build_image}" \
  bash -c "git -C /build/peach-app rev-parse --verify 'refs/tags/${git_ref}' >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "no")"

if [[ "${tag_exists}" == "yes" ]]; then
  tag_object_type="$(${CONTAINER_CMD} run --rm "${build_image}" \
    git -C /build/peach-app cat-file -t "refs/tags/${git_ref}" 2>/dev/null || echo "unknown")"
  if [[ "${tag_object_type}" == "tag" ]]; then
    tag_type="annotated"
    tag_output="$(${CONTAINER_CMD} run --rm "${build_image}" \
      bash -c "git -C /build/peach-app tag -v '${git_ref}' 2>&1 || true")"
    if echo "${tag_output}" | grep -q "Good signature"; then
      tag_signature_status="[OK] Good signature on annotated tag"
      tag_key="$(echo "${tag_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
      [[ -n "${tag_key}" ]] && signature_keys="Tag signed with: ${tag_key}"
    else
      tag_signature_status="[WARNING] No valid signature found on annotated tag"
      signature_warnings="- Annotated tag exists but is not signed"
    fi
  else
    tag_type="lightweight"
    tag_signature_status="[INFO] Tag is lightweight (cannot contain signature)"
    tag_output="Tag: ${git_ref} (lightweight, no signature possible)"
  fi
else
  tag_output="No tag found for ref '${git_ref}' (built from commit ${commit_hash})"
fi

commit_output="$(${CONTAINER_CMD} run --rm "${build_image}" \
  bash -c "git -C /build/peach-app verify-commit '${commit_hash}' 2>&1 || true")"
if echo "${commit_output}" | grep -q "Good signature"; then
  commit_signature_status="[OK] Good signature on commit"
  commit_key="$(echo "${commit_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
  [[ -n "${commit_key}" ]] && signature_keys="${signature_keys:+${signature_keys}\n}Commit signed with: ${commit_key}"
else
  commit_signature_status="[WARNING] No valid signature found on commit"
  signature_warnings="${signature_warnings:+${signature_warnings}\n}- Commit is not signed"
fi

# ------------------------------------------------------------------------------
# Step 6: Build AAB in container
# ------------------------------------------------------------------------------
log_info "Running AAB build (bundleProdRelease — 30–60 min on first Gradle run)..."

output_dir_abs="${work_dir}/build-output"
mkdir -p "${output_dir_abs}"

# Write build script to file — more reliable than bash -s heredoc with podman
cat > "${work_dir}/run_build.sh" << 'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

cd /build/peach-app

echo "[BUILD] Running Metro bundler..."
mkdir -p android/app/src/main/assets
npx react-native bundle \
  --reset-cache \
  --platform android \
  --dev false \
  --entry-file index.js \
  --bundle-output android/app/src/main/assets/index.android.bundle

echo "[BUILD] Running Gradle bundleProdRelease..."
cd android
NODE_ENV=production ./gradlew clean bundleProdRelease --no-daemon

echo "[BUILD] Locating built AAB..."
aab_file="$(find app/build/outputs/bundle -name '*.aab' | head -1)"
if [[ -z "${aab_file}" ]]; then
  echo "[ERROR] No AAB found after build."
  exit 1
fi
echo "[BUILD] AAB found: ${aab_file}"
cp -v "${aab_file}" /output/app.aab

echo "[BUILD] Extracting split APKs from AAB via bundletool..."
java -jar /usr/local/lib/bundletool.jar build-apks \
  --bundle=/output/app.aab \
  --output=/output/built-splits.apks \
  --device-spec=/device-spec.json \
  --mode=DEFAULT \
  --overwrite

echo "[BUILD] Unzipping built-splits.apks..."
unzip -q /output/built-splits.apks -d /output/bundletool-out/
echo "[BUILD] Done."
BUILDSCRIPT

chmod +x "${work_dir}/run_build.sh"

${CONTAINER_CMD} run --rm \
  --volume "${work_dir}/run_build.sh:/run_build.sh${VOLUME_RO_SUFFIX}" \
  --volume "${output_dir_abs}:/output${VOLUME_RW_SUFFIX}" \
  --volume "${work_dir}/device-spec.json:/device-spec.json${VOLUME_RO_SUFFIX}" \
  "${build_image}" \
  bash /run_build.sh

# ------------------------------------------------------------------------------
# Step 7: Normalize bundletool split filenames to match Play Store naming
# ------------------------------------------------------------------------------
log_info "Normalizing bundletool split filenames..."

bundletool_raw="${work_dir}/build-output/bundletool-out/splits"
built_splits_dir="${work_dir}/built-split-apks"
mkdir -p "${built_splits_dir}"

if [[ ! -d "${bundletool_raw}" ]]; then
  log_warn "Expected splits/ subdir not found. Listing bundletool output:"
  find "${work_dir}/build-output/bundletool-out/" -name '*.apk' | sort | head -20 || true
  # Try the root if splits/ subdir missing
  bundletool_raw="${work_dir}/build-output/bundletool-out"
fi

# Rename bundletool output generically: base-master.apk → base.apk, base-<x>.apk → split_config.<x>.apk
# This handles any locale/density/ABI without a hard-coded list (metamask pattern).
for f in "${bundletool_raw}"/*.apk; do
  [[ -f "${f}" ]] || continue
  fname="$(basename "${f}")"
  case "${fname}" in
    base-master.apk) dest="base.apk" ;;
    base-*.apk)      dest="split_config.${fname#base-}" ;;
    *)               dest="${fname}" ;;
  esac
  cp "${f}" "${built_splits_dir}/${dest}"
  log_info "  ${fname} → ${dest}"
done

log_info "Built splits:"
ls -lh "${built_splits_dir}/"*.apk 2>/dev/null | awk '{print "  " $5 "\t" $9}' || true

# ------------------------------------------------------------------------------
# Step 8: Compare splits
# ------------------------------------------------------------------------------
log_info "Comparing split APKs (official vs built)..."

official_unzipped="${work_dir}/official-unzipped"
built_unzipped="${work_dir}/built-unzipped"
mkdir -p "${official_unzipped}" "${built_unzipped}"

# Unzip official splits
for f in "${official_splits_dir}"/*.apk; do
  [[ -f "${f}" ]] || continue
  fname="$(basename "${f}")"
  split_key="${fname%.apk}"          # e.g. base, split_config.arm64_v8a
  split_dir="${split_key//split_config./}"  # e.g. base, arm64_v8a
  mkdir -p "${official_unzipped}/${split_dir}"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${f}"):/src${VOLUME_RO_SUFFIX}" \
    --volume "${official_unzipped}/${split_dir}:/out${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "unzip -q /src/${fname} -d /out"
done

# Unzip built splits
for f in "${built_splits_dir}"/*.apk; do
  [[ -f "${f}" ]] || continue
  fname="$(basename "${f}")"
  split_key="${fname%.apk}"
  split_dir="${split_key//split_config./}"
  mkdir -p "${built_unzipped}/${split_dir}"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${f}"):/src${VOLUME_RO_SUFFIX}" \
    --volume "${built_unzipped}/${split_dir}:/out${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "unzip -q /src/${fname} -d /out"
done

# Compare each split using Leo's META-INF filter
aggregated_diff=""
total_diff_count=0
yaml_files_block=""

for off_split_dir in "${official_unzipped}"/*/; do
  split_dir_name="$(basename "${off_split_dir}")"
  built_split_dir="${built_unzipped}/${split_dir_name}"

  # Determine display name and APK filename
  if [[ "${split_dir_name}" == "base" ]]; then
    apk_filename="base.apk"
  else
    apk_filename="split_config.${split_dir_name}.apk"
  fi

  official_apk_path="${official_splits_dir}/${apk_filename}"
  built_apk_path="${built_splits_dir}/${apk_filename}"

  # Hash both
  if [[ -f "${official_apk_path}" ]]; then
    off_hash="$(container_sha256 "${official_apk_path}")"
  else
    off_hash="missing"
  fi
  if [[ -f "${built_apk_path}" ]]; then
    built_hash_split="$(container_sha256 "${built_apk_path}")"
  else
    built_hash_split="missing"
  fi

  if [[ ! -d "${built_split_dir}" ]]; then
    log_warn "Split ${split_dir_name} exists in official but not in built APKs."
    aggregated_diff+="=== ${apk_filename} ===\nWARNING: Not found in built APKs.\n\n"
    total_diff_count=$((total_diff_count + 1))
    yaml_files_block+="      - filename: ${apk_filename}\n        hash: ${off_hash}\n        match: false\n"
    continue
  fi

  split_diff_brief="$(container_diff "${off_split_dir}" "${built_split_dir}")"

  filtered="$(echo "${split_diff_brief}" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)"
  filtered_compact="$(echo "${filtered}" | tr -d '\n\r')"

  if [[ -z "${split_diff_brief}" || -z "${filtered_compact}" ]]; then
    split_diff_count=0
  else
    split_diff_count="$(echo "${filtered}" | grep -c '^' || true)"
  fi
  total_diff_count=$((total_diff_count + split_diff_count))

  # match=true when non-META-INF diff count is zero (META-INF only = acceptable)
  if [[ "${split_diff_count}" -eq 0 ]]; then
    split_match="true"
  else
    split_match="false"
  fi

  # Add to aggregated diff display (full diff including META-INF)
  aggregated_diff+="=== ${apk_filename} ===\n"
  if [[ -n "${split_diff_brief}" ]]; then
    aggregated_diff+="${split_diff_brief}\n"
  else
    aggregated_diff+="(no differences)\n"
  fi
  aggregated_diff+="\n"

  yaml_files_block+="      - filename: ${apk_filename}\n        hash: ${built_hash_split}\n        match: ${split_match}\n"

  log_info "  ${apk_filename}: ${split_diff_count} non-META-INF diff lines | match=${split_match}"
done

# Check for splits in built but not in official — these affect the final verdict
for built_split_dir in "${built_unzipped}"/*/; do
  split_dir_name="$(basename "${built_split_dir}")"
  if [[ ! -d "${official_unzipped}/${split_dir_name}" ]]; then
    if [[ "${split_dir_name}" == "base" ]]; then
      apk_filename="base.apk"
    else
      apk_filename="split_config.${split_dir_name}.apk"
    fi
    log_warn "Split ${split_dir_name} exists in built APKs but not in official."
    append_info "Extra split in built output: ${apk_filename} (not present in official)"
    total_diff_count=$((total_diff_count + 1))
    built_extra_hash="$(container_sha256 "${built_splits_dir}/${apk_filename}" 2>/dev/null || echo "unknown")"
    yaml_files_block+="      - filename: ${apk_filename}\n        hash: ${built_extra_hash}\n        match: false\n"
  fi
done

# Overall verdict
if [[ "${total_diff_count}" -eq 0 ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  log_info "Result: REPRODUCIBLE"
else
  verdict="differences found"
  yaml_status="not_reproducible"
  log_info "Result: DIFFERENCES FOUND (${total_diff_count} total non-META-INF diff lines)"
fi

# ------------------------------------------------------------------------------
# Step 9: Generate COMPARISON_RESULTS.yaml
# ------------------------------------------------------------------------------
append_info "base.apk SHA-256: ${official_base_hash}"
append_info "Git ref: ${git_ref}"
append_info ".env.production: uses known mainnet endpoints (api/grouphug/electrs.peachbitcoin.com)."
if [[ "${total_diff_count}" -gt 0 ]]; then
  append_info "Total non-META-INF diff lines across all splits: ${total_diff_count}."
fi

yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
{
  echo "date: $(date -u '+%Y-%m-%dT%H:%M:%S+0000')"
  echo "script_version: ${SCRIPT_VERSION}"
  echo "build_type: ${requested_type:-apk}"
  echo "results:"
  echo "  - architecture: ${requested_arch}"
  echo "    status: ${yaml_status}"
  echo "    files:"
  echo -e "${yaml_files_block}" | grep -v '^$'
  if [[ -n "${additional_info}" ]]; then
    echo "additional_info: |"
    echo -e "${additional_info}" | sed 's/^/  /'
  fi
} > "${yaml_file}"

# ------------------------------------------------------------------------------
# Step 10: Standardized results output
# ------------------------------------------------------------------------------
diff_guide=""
if [[ "${should_cleanup}" != "true" ]]; then
  diff_guide="
Run a full diff on individual splits:
diff --recursive ${official_unzipped}/base ${built_unzipped}/base
diff --recursive ${official_unzipped}/${detected_abi//[-]/_} ${built_unzipped}/${detected_abi//[-]/_}

Or use meld for visual comparison:
meld ${official_unzipped} ${built_unzipped}

Or use diffoscope on split APK pairs:
diffoscope ${official_splits_dir}/base.apk ${built_splits_dir}/base.apk
diffoscope ${official_splits_dir}/split_config.${detected_abi//-/_}.apk ${built_splits_dir}/split_config.${detected_abi//-/_}.apk

for more details."
fi

echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name_apk:-${version_name}}"
echo "apkVersionCode: ${version_code:-unknown}"
echo "verdict:        ${verdict}"
echo "appHash:        ${official_base_hash}"
echo "commit:         ${commit_hash}"
echo ""
echo "Diff:"
echo -e "${aggregated_diff}"
echo ""
echo "Revision, tag (and its signature):"
echo "${tag_output}"
echo ""
echo "${commit_output}"
echo ""
echo "Signature Summary:"
echo "Tag type: ${tag_type}"
echo "${tag_signature_status}"
echo "${commit_signature_status}"
if [[ -n "${signature_keys}" ]]; then
  echo ""
  echo "Keys used:"
  echo -e "${signature_keys}"
fi
if [[ -n "${signature_warnings}" ]]; then
  echo ""
  echo "Warnings:"
  echo -e "${signature_warnings}"
fi
if [[ -n "${additional_info}" ]]; then
  echo ""
  echo "===== Also ===="
  echo -e "${additional_info}"
fi
echo ""
echo "===== End Results ====="
echo "${diff_guide}"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
if [[ "${should_cleanup}" == "true" ]]; then
  log_info "Cleaning up work directory: ${work_dir}"
  rm -rf "${work_dir}"
fi

if [[ "${total_diff_count}" -eq 0 ]]; then
  echo "Exit code: ${EXIT_SUCCESS}"
  exit "${EXIT_SUCCESS}"
else
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
fi
