#!/bin/bash
# ==============================================================================
# kraken_build.sh - Kraken Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.0
# Organization:  WalletScrutiny.com
# Last Modified: 2026-04-10
# Project:       https://github.com/krakenfx/wallet
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.kraken.superwallet/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding the security,
# functionality, or fitness for any particular purpose.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws. The developers assume no liability for any misuse.
#
# SCRIPT SUMMARY:
# - Accepts a zip of Play Store split APKs (WalletScrutiny Android Blossom upload)
#   or a single APK via --binary/--apk. Zip input is detected by file content
#   (magic bytes + inner APK presence), not file extension.
# - Clones krakenfx/wallet at the matching release tag (format: v.X.Y.Z)
# - Builds a fully containerized Docker image (JDK 17, Node.js 20, Android SDK 35,
#   NDK 28.2.13676358, Yarn 3.6.4 via corepack)
# - Creates a minimal stub .env file (required by react-native-config)
# - Runs yarn install --immutable + ./gradlew bundleRelease inside that image
# - Injects versionCode/versionName (extracted from official APK) before building
#   (repo hardcodes versionCode=1 / versionName="1.0" as placeholders)
# - Extracts split APKs from built AAB using bundletool + device-spec.json
# - Compares each official split against the matching built split using diff -r
#   (root-level META-INF diff lines filtered from non-signing count)
# - Generates COMPARISON_RESULTS.yaml in 3-field minimal format
#
# KNOWN LIMITATIONS:
# - The public repo is a point-in-time mirror of a private internal repo.
#   The full release pipeline (fastlane Fastfile, release CI) is not present.
# - The release signing keystore is private; built APK will be unsigned/debug-signed.
# - git2json postinstall embeds branch+commit SHA into the JS bundle at build time;
#   the public mirror commit may differ from the private commit used for the official APK,
#   causing diffs in the JS bundle regardless of other build factors.
# - google-services.json is absent; Firebase plugin is in classpath but not applied
#   in app/build.gradle, so this should be non-blocking.
# - WalletConnect project ID is stubbed in .env; this may affect Firebase/push config
#   embedded in the bundle but should not block the build.
# - electrum-client dep is pinned to a specific commit on github:BlueWallet/rn-electrum-client;
#   yarn install --immutable will use the lockfile entry.

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.3.0"
APP_ID="com.kraken.superwallet"
REPO_URL="https://github.com/krakenfx/wallet.git"
WS_CONTAINER="docker.io/walletscrutiny/android:5"
BUNDLETOOL_VERSION="1.15.6"
DEFAULT_ARCH="arm64-v8a"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"

should_cleanup=false
force_version_mismatch=false
apk_input=""
INPUT_IS_ZIP=false
requested_version=""
requested_arch=""
requested_type=""

ARCH=""
version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
additional_info=""

work_dir=""
build_image_tag=""
TOTAL_DIFFS=0
TOTAL_META_ONLY=0

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_error() { echo "[ERROR] $*"; }

append_info() {
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n${1}"
  else
    additional_info="${1}"
  fi
}

# ------------------------------------------------------------------------------
# YAML generators (3-field minimal format)
# ------------------------------------------------------------------------------
write_yaml() {
  local content="$1"
  printf '%s\n' "$content" > "${execution_dir}/COMPARISON_RESULTS.yaml"
}

generate_error_yaml() {
  local status="$1"
  write_yaml "script_version: ${SCRIPT_VERSION}
verdict: ${status}"
}

generate_comparison_yaml() {
  local yaml_verdict="$1"
  local yaml_notes="$2"
  write_yaml "script_version: ${SCRIPT_VERSION}
verdict: ${yaml_verdict}
notes: |
  ${yaml_notes}"
  log_info "Generated COMPARISON_RESULTS.yaml (verdict: ${yaml_verdict})"
}

# ------------------------------------------------------------------------------
# Exit helpers
# ------------------------------------------------------------------------------
die_invalid() {
  log_error "$*"
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
  if [[ -n "${build_image_tag}" ]]; then
    ${CONTAINER_CMD} rmi "${build_image_tag}" >/dev/null 2>&1 || true
  fi
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
CONTAINER_USER_ARGS=""

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
  CONTAINER_USER_ARGS=""
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  VOLUME_RW_SUFFIX=""
  CONTAINER_USER_ARGS="--user $(id -u):$(id -g)"
else
  die_failed "Neither podman nor docker is available. Install one to continue."
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       ${script_name} - Kraken Wallet Android reproducible build verification

SYNOPSIS
       ${script_name} --binary <zip|apk> [--version <version>] [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds Kraken Wallet from source in a fully self-contained container
       (JDK 17, Node.js 20, Android SDK 35, NDK 28.2.13676358, Yarn 3.6.4)
       and compares against official Play Store split APKs.

       --binary accepts a zip archive of split APKs (WalletScrutiny Android
       Blossom upload) or a single APK. Zip input is detected by file content,
       not file extension.

       Version and versionCode are auto-detected from the official APK content
       using aapt/apktool (never from filename). --version overrides this.

OPTIONS
       --binary <file>         Path to official zip (split APKs) or single APK.
                               Required.
       --apk <file>            Alias for --binary.
       --version <version>     Override version (e.g. 1.26.0). Optional.
       --arch <arch>           Target architecture for bundletool device-spec.
                               Supported: arm64-v8a, armeabi-v7a, x86_64, x86.
                               Default: arm64-v8a.
       --type <type>           Accepted for build server compatibility; unused.
       --force-version-mismatch  Proceed even if --version does not match the
                               versionName detected in the APK. Default: fail.
       --cleanup               Remove temporary files after completion.
       --script-version        Print script version and exit.
       --help                  Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF signature differences across all splits)
       1    Differences found or build failure
       2    Invalid parameters

EXAMPLES
       ${script_name} --binary ~/apks/com.kraken.superwallet/splits.zip
       ${script_name} --binary ~/apks/com.kraken.superwallet/base.apk --version 1.26.0
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version)
      [[ "$#" -lt 2 ]] && die_invalid "--version requires a value."
      requested_version="$2"; shift ;;
    --binary|--apk)
      [[ "$#" -lt 2 ]] && die_invalid "$1 requires a value."
      apk_input="$2"; shift ;;
    --arch)
      [[ "$#" -lt 2 ]] && die_invalid "--arch requires a value."
      requested_arch="$2"; shift ;;
    --type)
      [[ "$#" -lt 2 ]] && die_invalid "--type requires a value."
      requested_type="$2"; shift ;;
    --force-version-mismatch) force_version_mismatch=true ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

if [[ -z "${apk_input}" ]]; then
  die_invalid "You must provide --binary/--apk pointing to the official zip or APK."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

# Resolve path
[[ "${apk_input}" != /* ]] && apk_input="${execution_dir}/${apk_input}"
[[ ! -f "${apk_input}" ]] && die_invalid "File not found: ${apk_input}"

# Detect zip by content (magic bytes + inner APK), not extension
if file "${apk_input}" | grep -q "Zip archive" && \
   unzip -l "${apk_input}" 2>/dev/null | grep -q "\.apk"; then
  INPUT_IS_ZIP=true
  log_info "--binary is a zip archive containing APKs."
fi

# Arch selection
case "${requested_arch:-}" in
  arm64-v8a|armeabi-v7a|x86_64|x86) ARCH="${requested_arch}" ;;
  "")
    # Auto-detect from zip entry names or filename
    if [[ "${INPUT_IS_ZIP}" == "true" ]]; then
      detected="$(unzip -Z1 "${apk_input}" 2>/dev/null \
        | grep -Eoi 'arm64[-_]v8a|armeabi[-_]v7a|x86_64|x86' \
        | sed 's/_/-/g' | sort -u | head -1 || true)"
      ARCH="${detected:-${DEFAULT_ARCH}}"
    else
      ARCH="${DEFAULT_ARCH}"
    fi
    log_info "Architecture: ${ARCH}"
    ;;
  *) die_invalid "Unsupported architecture: ${requested_arch}. Use arm64-v8a, armeabi-v7a, x86_64, or x86." ;;
esac

[[ -n "${requested_type}" ]] && \
  append_info "Build type '${requested_type}' accepted for compatibility."

version_name="${requested_version}"

# ------------------------------------------------------------------------------
# Containerized helpers
# ------------------------------------------------------------------------------
container_sha256() {
  local file_path="$1"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${file_path}"):/data${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "sha256sum /data/$(basename "${file_path}") | awk '{print \$1}'"
}

container_signer() {
  local apk_path="$1"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${apk_path}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apksigner verify --print-certs /apk/$(basename "${apk_path}") \
           | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

# Zeus-pattern: aapt -> aapt2 -> apktool fallback (never uses filename/path)
container_aapt_version() {
  local apk_path="$1"
  local field="$2"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${apk_path}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c '
      apk_name="'"$(basename "${apk_path}")"'"
      field="'"${field}"'"
      badging="$({ aapt dump badging "/apk/${apk_name}" 2>/dev/null \
                || aapt2 dump badging "/apk/${apk_name}" 2>/dev/null; } || true)"
      if [ -n "$badging" ]; then
        printf "%s\n" "$badging" \
          | sed -n "s/.*${field}='"'"'\([^'"'"']*\)'"'"'.*/\1/p" | head -n1
        exit 0
      fi
      tmpdir=$(mktemp -d)
      if apktool d -f -s -o "$tmpdir/out" "/apk/${apk_name}" >/dev/null 2>&1; then
        case "${field}" in
          versionName) sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" \
                           "$tmpdir/out/apktool.yml" | head -n1 ;;
          versionCode) sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" \
                           "$tmpdir/out/apktool.yml" | head -n1 ;;
        esac
      fi
      rm -rf "$tmpdir"
    ' 2>/dev/null || true
}

container_aapt_package() {
  local apk_path="$1"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${apk_path}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c '
      apk_name="'"$(basename "${apk_path}")"'"
      badging="$({ aapt dump badging "/apk/${apk_name}" 2>/dev/null \
                || aapt2 dump badging "/apk/${apk_name}" 2>/dev/null; } || true)"
      if [ -n "$badging" ]; then
        result="$(printf "%s\n" "$badging" \
          | sed -n "s/^package: name='"'"'\([^'"'"']*\)'"'"'.*/\1/p" | head -n1)"
        [ -n "$result" ] && printf "%s\n" "$result" && exit 0
      fi
      # Fallback: apktool decode — handles split APKs that aapt/aapt2 badging skips
      tmpdir=$(mktemp -d)
      if apktool d -f -s -o "$tmpdir/out" "/apk/${apk_name}" >/dev/null 2>&1; then
        grep -m1 "package=" "$tmpdir/out/AndroidManifest.xml" 2>/dev/null \
          | sed -n "s/.*package=\"\([^\"]*\)\".*/\1/p"
      fi
      rm -rf "$tmpdir"
    ' 2>/dev/null || true
}

canonicalize_split_name() {
  local name="$1"
  case "${name}" in
    base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
    split_config.*.apk) echo "${name}" ;;
    base-*.apk) echo "split_config.${name#base-}" ;;
    *) echo "${name}" ;;
  esac
}

# ------------------------------------------------------------------------------
# Prepare official splits
# ------------------------------------------------------------------------------
log_info "=== PREPARATION ==="

work_dir="${execution_dir}/workdir_${APP_ID}_${version_name:-detect}_${ARCH//-/_}_$$"
if [[ -d "${work_dir}" ]]; then
  log_info "Removing existing workspace: ${work_dir}"
  ${CONTAINER_CMD} run --rm \
    --volume "${work_dir}:/ws${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "find /ws -mindepth 1 -delete" 2>/dev/null || true
  rm -rf "${work_dir}"
fi
mkdir -p "${work_dir}"/{official-splits,built-splits,output,comparison}
chmod 777 "${work_dir}/output"

official_dir="${work_dir}/official-splits"

if [[ "${INPUT_IS_ZIP}" == "true" ]]; then
  log_info "Extracting zip: $(basename "${apk_input}")"
  local_extract="${work_dir}/zip-extracted"
  mkdir -p "${local_extract}"
  unzip -qq "${apk_input}" -d "${local_extract}" 2>/dev/null || true
  chmod -R a+rwX "${local_extract}" 2>/dev/null || true

  apk_count="$(find "${local_extract}" -name "*.apk" | wc -l)"
  [[ "${apk_count}" -eq 0 ]] && die_failed "No APK files found inside zip: ${apk_input}"
  log_info "${apk_count} APK(s) found in zip:"

  while IFS= read -r apk; do
    orig="$(basename "${apk}")"
    canon="$(canonicalize_split_name "${orig}")"
    cp "${apk}" "${official_dir}/${canon}"
    [[ "${orig}" != "${canon}" ]] && log_info "  Normalized: ${orig} -> ${canon}" || log_info "  ${canon}"
  done < <(find "${local_extract}" -name "*.apk" | sort)

  # Use base.apk for metadata extraction
  base_apk="${official_dir}/base.apk"
  [[ ! -f "${base_apk}" ]] && base_apk="$(find "${official_dir}" -name "*.apk" | sort | head -1)"
else
  # Single APK
  orig="$(basename "${apk_input}")"
  canon="$(canonicalize_split_name "${orig}")"
  cp "${apk_input}" "${official_dir}/${canon}"
  base_apk="${official_dir}/${canon}"
  log_info "Single APK: ${canon}"
fi

# Extract metadata from base APK
app_hash="$(container_sha256 "${base_apk}")"
signer="$(container_signer "${base_apk}")"
version_name_from_apk="$(container_aapt_version "${base_apk}" "versionName")"
# Strip parenthetical suffix e.g. "1.27.2 (1)" -> "1.27.2" (Kraken appends versionCode in parens)
version_name_from_apk="${version_name_from_apk%% (*}"
version_name_from_apk="${version_name_from_apk%% }"
version_code="$(container_aapt_version "${base_apk}" "versionCode")"
[[ -z "${version_code}" ]] && version_code="unknown"

# Package name guard (HIGH): fail fast if APK is not com.kraken.superwallet
detected_pkg="$(container_aapt_package "${base_apk}")"
if [[ -n "${detected_pkg}" && "${detected_pkg}" != "${APP_ID}" ]]; then
  die_invalid "APK package name mismatch: expected '${APP_ID}', got '${detected_pkg}'. Pass the correct APK."
fi
if [[ -n "${detected_pkg}" ]]; then
  log_pass "Package name verified: ${detected_pkg}"
else
  log_warn "Package name could not be verified from APK (aapt/aapt2 returned empty)."
fi

if [[ -z "${version_name}" ]]; then
  [[ -z "${version_name_from_apk}" ]] && \
    die_invalid "Could not detect version from APK. Pass --version explicitly."
  version_name="${version_name_from_apk}"
  log_info "Version auto-detected from APK: ${version_name}"
elif [[ -n "${version_name_from_apk}" && "${requested_version}" != "${version_name_from_apk}" ]]; then
  if [[ "${force_version_mismatch}" == "true" ]]; then
    log_warn "Version mismatch: --version ${requested_version} but APK reports ${version_name_from_apk}. Proceeding (--force-version-mismatch)."
    append_info "Version mismatch: requested ${requested_version}, APK reports ${version_name_from_apk}."
  else
    die_failed "Version mismatch: --version ${requested_version} but APK reports ${version_name_from_apk}. Use --force-version-mismatch to override."
  fi
fi

log_info "versionName: ${version_name}  versionCode: ${version_code}  signer: ${signer}"

# Rename work_dir now that we have version_name
final_work_dir="${execution_dir}/workdir_${APP_ID}_${version_name}_${ARCH//-/_}_$$"
if [[ "${work_dir}" != "${final_work_dir}" ]]; then
  mv "${work_dir}" "${final_work_dir}"
  work_dir="${final_work_dir}"
  official_dir="${work_dir}/official-splits"
  base_apk="${official_dir}/$(basename "${base_apk}")"
fi

# device-spec for bundletool
cat > "${work_dir}/device-spec.json" <<DEVSPEC
{
  "supportedAbis": ["${ARCH}"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 33
}
DEVSPEC
log_info "Created device-spec.json for arch: ${ARCH}"

# Unique image tag
build_image_tag="kraken_build_${version_name}_$$"
# git_tag will be resolved inside the build container (probes v.X, vX, X formats)
git_tag="v.${version_name}"  # default for display; overridden after build

# ------------------------------------------------------------------------------
# Build environment Docker image
# JDK 17, Node.js 20, Android SDK 35, NDK 28.2.13676358, Yarn 3.6.4 via corepack
# ------------------------------------------------------------------------------
log_info "=== BUILD IMAGE ==="

cat > "${work_dir}/Dockerfile" <<'DOCKEREOF'
FROM docker.io/library/eclipse-temurin:17-jdk-jammy

ENV ANDROID_HOME="/opt/android-sdk" \
    ANDROID_SDK_ROOT="/opt/android-sdk" \
    GRADLE_USER_HOME="/root/.gradle" \
    ANDROID_PREFS_ROOT="/root/.android" \
    PATH="${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools"

RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget unzip curl ca-certificates python3 make g++ \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && corepack enable \
    && corepack prepare yarn@3.6.4 --activate \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip \
         -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools && \
    mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm /tmp/cmdline-tools.zip

RUN yes | sdkmanager --licenses >/dev/null 2>&1 && \
    sdkmanager \
      "platform-tools" \
      "platforms;android-35" \
      "build-tools;35.0.0" \
      "ndk;28.2.13676358" && \
    chmod -R 777 ${ANDROID_HOME}

RUN mkdir -p /workspace && chmod 777 /workspace
WORKDIR /workspace
DOCKEREOF

log_info "Building Docker image '${build_image_tag}'..."
if ! ${CONTAINER_CMD} build --tag "${build_image_tag}" "${work_dir}"; then
  die_failed "Failed to build Docker image."
fi
log_info "Image built: ${build_image_tag}"

# ------------------------------------------------------------------------------
# Clone + build inside container
# ------------------------------------------------------------------------------
log_info "=== BUILD ==="

version_code_arg="${version_code}"
[[ "${version_code_arg}" == "unknown" || -z "${version_code_arg}" ]] && \
  version_code_arg="1" && \
  log_warn "versionCode unknown — using placeholder 1."

log_info "Probing tag formats for version ${version_name} (v.X, vX, X), then bundleRelease..."
log_info "First run may take 30-60 minutes."

if ! ${CONTAINER_CMD} run --rm \
  --memory=20g \
  --volume "${work_dir}/output:/output${VOLUME_RW_SUFFIX}" \
  --env "KRAKEN_VERSION_NAME=${version_name}" \
  --env "KRAKEN_VERSION_CODE=${version_code_arg}" \
  --env "KRAKEN_REPO_URL=${REPO_URL}" \
  --env "HOST_UID=$(id -u)" \
  --env "HOST_GID=$(id -g)" \
  "${build_image_tag}" \
  bash -c '
    set -euo pipefail
    trap "chown -R ${HOST_UID}:${HOST_GID} /output 2>/dev/null || true" EXIT

    # Probe tag formats in order: v.X.Y.Z, vX.Y.Z, X.Y.Z
    KRAKEN_VERSION_TAG=""
    for candidate in "v.${KRAKEN_VERSION_NAME}" "v${KRAKEN_VERSION_NAME}" "${KRAKEN_VERSION_NAME}"; do
      if git ls-remote --exit-code --tags "${KRAKEN_REPO_URL}" "${candidate}" >/dev/null 2>&1; then
        KRAKEN_VERSION_TAG="${candidate}"
        echo "[INFO] Resolved tag: ${KRAKEN_VERSION_TAG}"
        break
      fi
    done
    if [[ -z "${KRAKEN_VERSION_TAG}" ]]; then
      echo "[ERROR] No matching tag found for version ${KRAKEN_VERSION_NAME} (tried v.X, vX, X formats)"
      exit 1
    fi
    printf "%s\n" "${KRAKEN_VERSION_TAG}" > /output/resolved_tag.txt

    git clone --depth 1 --branch "${KRAKEN_VERSION_TAG}" --single-branch \
      "${KRAKEN_REPO_URL}" /build/app
    cd /build/app

    # Stub .env required by react-native-config
    cat > .env <<ENV_EOF
DEFAULT_HARMONY_BASE_URI=https://wallet.kraken.com/api/data
DEFAULT_GROUNDCONTROL_BASE_URI=https://wallet.kraken.com/api/push
WALLETCONNECT_PROJECT_ID=00000000000000000000000000000000
DEBUG_KEYSTORE_ANDROID_PASSWORD=android
ENV_EOF

    export GRADLE_OPTS="-Xmx12g -XX:MaxMetaspaceSize=512m"
    export KOTLIN_DAEMON_JVM_OPTIONS="-Xmx4g -XX:MaxMetaspaceSize=512m"

    yarn install --immutable

    # Inject real versionCode/versionName (repo hardcodes 1/"1.0" as placeholders)
    sed -i "s/versionCode [0-9]*/versionCode ${KRAKEN_VERSION_CODE}/" android/app/build.gradle
    sed -i "s/versionName \"[^\"]*\"/versionName \"${KRAKEN_VERSION_NAME}\"/" android/app/build.gradle

    # Tag / commit verification
    TAG_TYPE=$(git cat-file -t "refs/tags/${KRAKEN_VERSION_TAG}" 2>/dev/null || echo "missing")
    printf "TAG_TYPE=%s\n" "${TAG_TYPE}" > /output/tag_verify.txt
    if [ "${TAG_TYPE}" = "tag" ]; then
      git tag -v "${KRAKEN_VERSION_TAG}" >> /output/tag_verify.txt 2>&1 || true
    elif [ "${TAG_TYPE}" = "commit" ]; then
      printf "LIGHTWEIGHT_TAG\n" >> /output/tag_verify.txt
    else
      printf "NO_TAG\n" >> /output/tag_verify.txt
    fi
    printf "---COMMIT---\n" >> /output/tag_verify.txt
    git verify-commit HEAD >> /output/tag_verify.txt 2>&1 || true
    git rev-parse HEAD > /output/commit_hash.txt

    echo "[DIAG] Memory before bundleRelease:" && free -m

    cd android
    ./gradlew bundleRelease \
      --no-daemon \
      --no-build-cache \
      --max-workers=4

    echo "[DIAG] Memory after bundleRelease:" && free -m

    aab_path=$(find /build/app/android -name "*.aab" -path "*/outputs/bundle/*" \
               ! -path "*/intermediates/*" 2>/dev/null | head -1)
    [[ -z "${aab_path}" ]] && { echo "[ERROR] AAB not found after bundleRelease"; exit 1; }
    cp "${aab_path}" /output/app-release.aab
  '; then
  die_failed "Build failed. Check output above for details."
fi

built_aab="${work_dir}/output/app-release.aab"
[[ ! -f "${built_aab}" ]] && die_failed "Built AAB not found after container run."
commit_hash="$(cat "${work_dir}/output/commit_hash.txt" 2>/dev/null || echo "unknown")"
# Override git_tag with the format actually resolved inside the container
resolved_tag="$(cat "${work_dir}/output/resolved_tag.txt" 2>/dev/null || true)"
[[ -n "${resolved_tag}" ]] && git_tag="${resolved_tag}"
log_pass "Build complete: app-release.aab (commit: ${commit_hash}, tag: ${git_tag})"

# ------------------------------------------------------------------------------
# Extract built splits from AAB using bundletool
# ------------------------------------------------------------------------------
log_info "=== SPLIT EXTRACTION ==="

built_splits_dir="${work_dir}/built-splits"

${CONTAINER_CMD} run --rm \
  ${CONTAINER_USER_ARGS} \
  --volume "${work_dir}:/work${VOLUME_RW_SUFFIX}" \
  --workdir /work \
  "${build_image_tag}" \
  bash -c "
    set -euo pipefail
    if [[ ! -f bundletool.jar ]]; then
      curl -fsSL https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar \
        -o bundletool.jar
    fi
    rm -f built.apks
    java -jar bundletool.jar build-apks \
      --bundle=output/app-release.aab \
      --output=built.apks \
      --device-spec=device-spec.json \
      --mode=default \
      --overwrite
    mkdir -p built-splits
    unzip -o built.apks -d built-splits
    if [[ -d built-splits/splits ]]; then
      mv built-splits/splits/*.apk built-splits/ 2>/dev/null || true
      rmdir built-splits/splits 2>/dev/null || true
    fi
    if [[ -f built-splits/base-master.apk ]]; then
      mv built-splits/base-master.apk built-splits/base.apk
    fi
    for f in built-splits/base-*.apk; do
      [[ \"\$(basename \$f)\" == 'base-master.apk' ]] && continue
      suffix=\"\${f#built-splits/base-}\"
      mv \"\$f\" \"built-splits/split_config.\${suffix}\"
    done
    ls -la built-splits/*.apk || true
  "

log_pass "Splits extracted to: ${built_splits_dir}"

# ------------------------------------------------------------------------------
# Split-by-split comparison
# ------------------------------------------------------------------------------
log_info "=== COMPARISON ==="

safe_grep_count() {
  local out
  out="$("$@" 2>/dev/null || true)"
  out="${out//$'\n'/}"
  [[ -n "${out}" ]] && printf '%s\n' "${out}" || printf '0\n'
}

unzip_apk() {
  local apk_path="$1"
  local dest_dir="$2"
  local apk_dir apk_file dest_parent dest_base
  apk_dir="$(dirname "${apk_path}")"
  apk_file="$(basename "${apk_path}")"
  dest_parent="$(dirname "${dest_dir}")"
  dest_base="$(basename "${dest_dir}")"
  ${CONTAINER_CMD} run --rm \
    ${CONTAINER_USER_ARGS} \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    --volume "${dest_parent}:/out${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    bash -c "rm -rf /out/${dest_base}; mkdir -p /out/${dest_base}; \
             unzip -qq -o /apk/${apk_file} -d /out/${dest_base}"
}

resolve_built_split() {
  local official_name="$1"
  local canon
  canon="$(canonicalize_split_name "${official_name}")"
  [[ -f "${built_splits_dir}/${official_name}" ]] && echo "${built_splits_dir}/${official_name}" && return 0
  [[ -f "${built_splits_dir}/${canon}" ]]         && echo "${built_splits_dir}/${canon}"         && return 0
  return 1
}

TOTAL_DIFFS=0
TOTAL_META_ONLY=0

for official_apk in "${official_dir}"/*.apk; do
  [[ ! -f "${official_apk}" ]] && continue
  apk_name="$(basename "${official_apk}")"
  built_apk="$(resolve_built_split "${apk_name}" || true)"

  if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
    log_warn "No matching built split for: ${apk_name}"
    (( TOTAL_DIFFS++ )) || true
    continue
  fi

  official_hash="$(container_sha256 "${official_apk}")"
  built_hash="$(container_sha256 "${built_apk}")"
  log_info "  Official ${apk_name}: ${official_hash}"
  log_info "  Built    $(basename "${built_apk}"): ${built_hash}"

  off_unzip="${work_dir}/comparison/official_${apk_name%.apk}"
  blt_unzip="${work_dir}/comparison/built_${apk_name%.apk}"
  unzip_apk "${official_apk}" "${off_unzip}"
  unzip_apk "${built_apk}"    "${blt_unzip}"

  diff_file="${work_dir}/comparison/diff_${apk_name%.apk}.txt"
  off_rel="${off_unzip#"${work_dir}/"}"
  blt_rel="${blt_unzip#"${work_dir}/"}"
  diff_rel="${diff_file#"${work_dir}/"}"

  ${CONTAINER_CMD} run --rm \
    ${CONTAINER_USER_ARGS} \
    --volume "${work_dir}:/work${VOLUME_RW_SUFFIX}" \
    --workdir /work \
    "${WS_CONTAINER}" \
    bash -c "diff -r \"${off_rel}\" \"${blt_rel}\" > \"${diff_rel}\" 2>&1 || true"

  non_meta=0
  if [[ -s "${diff_file}" ]]; then
    non_meta="$(safe_grep_count grep -cvE \
      '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
      "${diff_file}")"
    blank="$(safe_grep_count grep -c '^$' "${diff_file}")"
    non_meta=$(( non_meta - blank ))
    [[ "${non_meta}" -lt 0 ]] && non_meta=0
  fi

  if [[ "${official_hash}" == "${built_hash}" ]]; then
    log_pass "${apk_name}: IDENTICAL"
  elif [[ "${non_meta}" -eq 0 ]]; then
    log_pass "${apk_name}: Only META-INF differences (signing only)"
    (( TOTAL_META_ONLY++ )) || true
  else
    log_warn "${apk_name}: ${non_meta} non-META-INF differences"
    (( TOTAL_DIFFS++ )) || true
  fi
done

# ------------------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------------------
log_info "=== RESULTS ==="
tag_verify_output="$(cat "${work_dir}/output/tag_verify.txt" 2>/dev/null || true)"

if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  log_pass "VERDICT: REPRODUCIBLE"
  [[ "${TOTAL_META_ONLY}" -gt 0 ]] && \
    log_info "Note: ${TOTAL_META_ONLY} split(s) had only META-INF differences (signing only)"
else
  verdict="differences found"
  yaml_status="not_reproducible"
  log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} split(s) with non-signing differences)"
fi

yaml_notes="Build: bundleRelease -> bundletool (device-spec: ${ARCH})."
yaml_notes="${yaml_notes} Environment: eclipse-temurin:17-jdk-jammy, JDK 17, Node.js 20, Android SDK 35, NDK 28.2.13676358, Yarn 3.6.4."
generate_comparison_yaml "${yaml_status}" "${yaml_notes}"

# Tag verification
tag_type="unknown"
tag_signature_status="[INFO] Not checked"
if echo "${tag_verify_output}" | grep -q "TAG_TYPE=tag"; then
  tag_type="annotated"
  echo "${tag_verify_output}" | grep -q "Good signature" && \
    tag_signature_status="[OK] Good signature on annotated tag" || \
    tag_signature_status="[WARNING] Annotated tag — no valid signature found"
elif echo "${tag_verify_output}" | grep -q "LIGHTWEIGHT_TAG"; then
  tag_type="lightweight"
  tag_signature_status="[INFO] Lightweight tag (cannot carry a signature)"
elif echo "${tag_verify_output}" | grep -qE "TAG_TYPE=missing|NO_TAG"; then
  tag_type="missing"
  tag_signature_status="[WARNING] Tag ${git_tag} not found in repository"
fi

# ------------------------------------------------------------------------------
# Standardized output
# ------------------------------------------------------------------------------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit_hash}"
echo ""
echo "Diff:"
for diff_file in "${work_dir}/comparison"/diff_*.txt; do
  [[ -f "${diff_file}" ]] || continue
  label="$(basename "${diff_file}" .txt)"
  label="${label#diff_}"
  echo "=== ${label} ==="
  if [[ -s "${diff_file}" ]]; then
    head -5 "${diff_file}"
    lines="$(wc -l < "${diff_file}")"
    [[ "${lines}" -gt 5 ]] && echo "... (${lines} lines — full diff: ${diff_file})"
  else
    echo "(no differences)"
  fi
  echo ""
done
echo "Revision, tag (and its signature):"
echo "Tag: ${git_tag} (${tag_type})"
echo "${tag_signature_status}"
echo "${tag_verify_output}" | grep -v '^TAG_TYPE=' | grep -v '^---COMMIT---' || true
echo ""
if [[ "${should_cleanup}" == "false" ]]; then
  echo "Run for more detail:"
  echo "  diffoscope '${work_dir}/official-splits' '${work_dir}/built-splits'"
  echo "  meld '${work_dir}/comparison'"
fi
if [[ -n "${additional_info}" ]]; then
  echo ""
  echo "===== Also ====="
  echo -e "${additional_info}"
fi
echo "===== End Results ====="

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
log_info "Removing build image: ${build_image_tag}"
${CONTAINER_CMD} rmi "${build_image_tag}" >/dev/null 2>&1 || true

if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
  log_info "Workspace cleaned up."
else
  log_info "Workspace preserved: ${work_dir}"
fi

exit_code="${EXIT_FAILED}"
[[ "${yaml_status}" == "reproducible" ]] && exit_code="${EXIT_SUCCESS}"
echo "Exit code: ${exit_code}"
exit "${exit_code}"
