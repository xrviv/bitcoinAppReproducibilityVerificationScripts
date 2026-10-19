#!/bin/bash
# ==============================================================================
# trustless_build.sh - Trustless Bitcoin Wallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.7
# Organization:  WalletScrutiny.com
# Project:       https://github.com/TrustlessWallet/Trustless
# ==============================================================================
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.btc.trustless/changelog.md
# ==============================================================================
#
# SCRIPT SUMMARY:
# - Accepts official APK via --binary (GitHub release or Play Store APK)
# - Clones Trustless repository inside a React Native container
# - Builds unsigned release APK: npm ci → expo prebuild → Gradle assembleRelease
# - Compares official APK against built APK (excluding META-INF)
# - Generates COMPARISON_RESULTS.yaml
#
# KNOWN CHALLENGES:
# - index.android.bundle (Hermes bytecode) may vary between macOS and Linux builds
# - Node.js version not pinned in repo; container uses Node 22
# - NDK 27.1.12297006 inferred from @react-native/gradle-plugin 0.81.5 template
# - No Play Store APK exists for v2.0.2 (app removed from Google Play 2026-05-12)

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.1.7"
APP_ID="com.btc.trustless"
REPO_URL="https://github.com/TrustlessWallet/Trustless.git"

# WalletScrutiny utility container (apksigner, aapt2, apktool, unzip, sha256sum)
WS_CONTAINER="docker.io/walletscrutiny/android:5"

# React Native Android build image.
# Contains: Node v22.14.0, npm, Android SDK, NDK 27.1.12297006, Gradle.
# Shared with blitzwallet_build.sh (verified 2026-05-06 for RN 0.81.x + Expo 54).
RN_BUILD_IMAGE="docker.io/reactnativecommunity/react-native-android@sha256:88d93a9282e0f54f84cec7b979da6c5e3f20d87f5be246b75c231838be852fec"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

caller_dir="$(pwd)"
execution_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script_name="$(basename "$0")"

downloaded_apk=""
requested_version=""
requested_arch=""
requested_type=""
should_cleanup=false

version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
additional_info=""
result_done=false
work_dir=""

CONTAINER_CMD=""
VOLUME_RO_SUFFIX=""
VOLUME_RW_SUFFIX=""
CONTAINER_RUN_USER_ARGS=""

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*"; }

append_additional_info() {
  local line="$1"
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}
  ${line}"
  else
    additional_info="${line}"
  fi
}

# ------------------------------------------------------------------------------
# YAML output
# ------------------------------------------------------------------------------
write_yaml_outputs() {
  local content="$1"
  printf '%s\n' "${content}" > "${execution_dir}/COMPARISON_RESULTS.yaml"
  if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
    printf '%s\n' "${content}" > "${work_dir}/COMPARISON_RESULTS.yaml" || true
  fi
  result_done=true
}

generate_result_yaml() {
  local verdict="$1"
  local notes="${2:-}"
  local yaml
  yaml="script_version: ${SCRIPT_VERSION}
verdict: ${verdict}"
  if [[ -n "${notes}" ]]; then
    yaml="${yaml}
notes: |
  ${notes}"
  fi
  write_yaml_outputs "${yaml}"
}

generate_error_yaml() {
  generate_result_yaml "${1}" "${2:-}"
}

# ------------------------------------------------------------------------------
# Result printing
# ------------------------------------------------------------------------------
print_results_block() {
  local verdict="$1"
  echo ""
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         ${signer:-unknown}"
  echo "apkVersionName: ${version_name:-unknown}"
  echo "apkVersionCode: ${version_code:-unknown}"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${app_hash:-unknown}"
  echo "commit:         ${commit_hash:-unknown}"
  [[ -n "${additional_info}" ]] && echo "notes:" && echo "  ${additional_info}"
  echo "===== End Results ====="
  echo ""
}

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------
die_invalid() {
  log_error "$*"
  echo "Exit code: ${EXIT_INVALID}"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  generate_error_yaml "ftbfs" "$*"
  print_results_block "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}

on_error() {
  local exit_code=$?
  local line_no="$1"
  set +e
  log_error "Script failed at line ${line_no} (exit code ${exit_code})"
  if [[ "${result_done}" != "true" ]]; then
    generate_error_yaml "ftbfs" "Script failed at line ${line_no} (exit code ${exit_code})"
  fi
  print_results_block "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Container runtime detection
# ------------------------------------------------------------------------------
detect_container_runtime() {
  if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
    VOLUME_RO_SUFFIX=":ro"
    VOLUME_RW_SUFFIX=""
    CONTAINER_RUN_USER_ARGS="--userns=keep-id"
    log_info "Using Podman"
  elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
    VOLUME_RO_SUFFIX=":ro"
    VOLUME_RW_SUFFIX=""
    CONTAINER_RUN_USER_ARGS="--user $(id -u):$(id -g)"
    log_info "Using Docker"
  else
    die_invalid "Neither podman nor docker found. Please install one."
  fi
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       ${script_name} - Trustless Bitcoin Wallet reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk_file> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Clones the Trustless repository at the version tag extracted from the
       provided APK, builds an unsigned release APK inside a container, and
       compares it against the official APK (excluding META-INF).

OPTIONS
       --binary <file>       Path to the official APK to verify. (Alias: --apk)
       --apk <file>          Alias for --binary (Android legacy compatibility)
       --version <version>   Version hint (optional; extracted from APK if omitted)
       --arch <arch>         Accepted for build server compatibility; ignored
       --type <type>         Accepted for build server compatibility; ignored
       --cleanup             Remove temporary workspace after completion
       --script-version      Print script version and exit
       --help                Show this help and exit

EXIT CODES
       0    Reproducible
       1    Differences found or build failure
       2    Invalid parameters

EXAMPLES
       ${script_name} --binary ~/Downloads/trustless-v2.0.2-release.apk
       ${script_name} --binary trustless.apk --version 2.0.2
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing — unknown args warned and ignored (Luis 2026-03-11)
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --binary)         downloaded_apk="${2:-}"; shift ;;
    --apk)            downloaded_apk="${2:-}"; shift ;;
    --version)        requested_version="${2:-}"; shift ;;
    --arch)           requested_arch="${2:-}"; shift ;;
    --type)           requested_type="${2:-}"; shift ;;
    --cleanup)        should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help)           usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *)                log_warn "Ignoring unknown argument: $1" ;;
  esac
  shift
done

log_info "Starting ${script_name} ${SCRIPT_VERSION}"

if [[ -z "${downloaded_apk}" && -n "${requested_version}" ]]; then
  apk_download_dir="$(mktemp -d /tmp/trustless_dl_XXXXXX)"
  apk_download_path="${apk_download_dir}/trustless-v${requested_version}-release.apk"
  apk_url="https://github.com/TrustlessWallet/Trustless/releases/download/${requested_version}/trustless-v${requested_version}-release.apk"
  log_info "No --binary provided; downloading GitHub release APK for v${requested_version}..."
  if ! command -v curl &>/dev/null; then
    die_invalid "curl not found on host. Install curl or supply the APK via --binary."
  fi
  if ! curl --fail --location --silent --show-error \
      --output "${apk_download_path}" "${apk_url}"; then
    die_invalid "Download failed for ${apk_url} — check that v${requested_version} exists on GitHub."
  fi
  downloaded_apk="${apk_download_path}"
  log_info "Downloaded to: ${downloaded_apk}"
fi

if [[ -z "${downloaded_apk}" ]]; then
  die_invalid "Provide either --binary <apk_file> or --version <version>."
fi

[[ "${downloaded_apk}" != /* ]] && downloaded_apk="${caller_dir}/${downloaded_apk}"

if [[ ! -f "${downloaded_apk}" ]]; then
  die_invalid "APK not found: ${downloaded_apk}"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

detect_container_runtime

# ------------------------------------------------------------------------------
# Collect metadata from the official APK
# ------------------------------------------------------------------------------
collect_official_metadata() {
  log_info "Extracting metadata from official APK..."

  local apk_dir apk_file
  apk_dir="$(dirname "${downloaded_apk}")"
  apk_file="$(basename "${downloaded_apk}")"

  # SHA-256 (host-side: sha256sum is standard on Linux)
  app_hash="$(sha256sum "${downloaded_apk}" | awk '{print $1}')"
  log_info "SHA-256: ${app_hash}"

  # versionName and versionCode via aapt/aapt2 (WS container has aapt in PATH)
  local aapt_out
  aapt_out="$("${CONTAINER_CMD}" run --rm \
    --volume "${apk_dir}:/apkdir${VOLUME_RO_SUFFIX}" \
    ${CONTAINER_RUN_USER_ARGS} \
    "${WS_CONTAINER}" \
    sh -c "{ aapt dump badging '/apkdir/${apk_file}' 2>/dev/null || aapt2 dump badging '/apkdir/${apk_file}' 2>/dev/null; } | head -5" \
    2>/dev/null)" || aapt_out=""

  version_name="$(echo "${aapt_out}" | grep -o "versionName='[^']*'" | sed "s/versionName='\([^']*\)'/\1/" || true)"
  version_code="$(echo "${aapt_out}" | grep -o "versionCode='[^']*'" | sed "s/versionCode='\([^']*\)'/\1/" || true)"

  # Override with explicit --version if provided and APK extraction failed
  if [[ -z "${version_name}" && -n "${requested_version}" ]]; then
    version_name="${requested_version}"
    log_warn "Could not extract versionName from APK; using --version ${version_name}"
  fi
  [[ -z "${version_name}" ]] && die_failed "Could not determine versionName from APK."

  # Package name check
  local pkg
  pkg="$(echo "${aapt_out}" | grep -o "package: name='[^']*'" | sed "s/package: name='\([^']*\)'/\1/" || true)"
  if [[ -n "${pkg}" && "${pkg}" != "${APP_ID}" ]]; then
    die_invalid "Package name mismatch: expected ${APP_ID}, got ${pkg}. Wrong APK provided."
  fi
  log_info "Package: ${pkg:-${APP_ID}} (verified)"

  # Signer certificate fingerprint
  signer="$("${CONTAINER_CMD}" run --rm \
    --volume "${apk_dir}:/apkdir${VOLUME_RO_SUFFIX}" \
    ${CONTAINER_RUN_USER_ARGS} \
    "${WS_CONTAINER}" \
    sh -c "apksigner verify --print-certs '/apkdir/${apk_file}' 2>/dev/null \
      | grep 'Signer #1 certificate SHA-256' | awk '{print \$NF}'" \
    2>/dev/null)" || signer="unknown"

  log_info "Version:  ${version_name} (code ${version_code:-unknown})"
  log_info "Signer:   ${signer}"

  if [[ -n "${requested_version}" && "${requested_version}" != "${version_name}" ]]; then
    log_warn "Requested version ${requested_version} does not match APK versionName ${version_name}"
    append_additional_info "Requested version ${requested_version}; APK reports ${version_name}"
  fi
}

# ------------------------------------------------------------------------------
# Write the in-container build script to work_dir
# This avoids heredoc nesting issues when executing bash -c from the host.
# ------------------------------------------------------------------------------
write_build_script() {
  cat > "${work_dir}/run_build.sh" << 'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

# Container UID may not have a /etc/passwd entry; all Java-based tools resolve
# home via /etc/passwd (not shell HOME), so override at JVM level and per-tool.
export HOME=/work
export npm_config_cache=/work/.npm-cache
export GRADLE_USER_HOME=/work/.gradle
export ANDROID_PREFS_ROOT=/work/.android
export JAVA_TOOL_OPTIONS="-Duser.home=/work"

mkdir -p /work/.npm-cache /work/.gradle /work/.android

TAG="$1"
REPO_URL="$2"

echo "[BUILD] Cloning ${REPO_URL} at tag ${TAG}..."
git clone --quiet --branch "${TAG}" --depth 1 "${REPO_URL}" /work/src
cd /work/src
git log -n 1 --pretty=format:'%H' > /work/commit_hash.txt
echo "[BUILD] Commit: $(git log -n 1 --pretty=format:'%h %s')"

echo "[BUILD] Step 1: Generating version metadata..."
node src/scripts/write-version.js

echo "[BUILD] Step 2: Installing dependencies (npm ci)..."
npm ci 2>&1 | tail -3

echo "[BUILD] Step 3: Generating Android project (expo prebuild)..."
CI=1 npx expo prebuild --clean --platform android 2>&1 | tail -5

echo "[BUILD] Step 4: Injecting reproducibility settings..."
cat >> android/app/build.gradle << 'GRADLEBLOCK'

android {
    buildTypes {
        release {
            signingConfig null
        }
    }
}

tasks.withType(AbstractArchiveTask).configureEach {
    preserveFileTimestamps = false
    reproducibleFileOrder = true
}
GRADLEBLOCK

echo "[BUILD] Step 5: Building release APK (this takes 10-20 minutes)..."
cd android
MAX_WORKERS=1 NODE_ENV=production ./gradlew assembleRelease --no-daemon 2>&1 | tee /work/gradle_build.log | tail -50
cd ..

echo "[BUILD] Build complete."
echo "[BUILD] APK: $(find /work/src/android/app/build/outputs/apk/release -name '*.apk' 2>/dev/null | head -1)"
BUILDSCRIPT
  chmod +x "${work_dir}/run_build.sh"
}

# ------------------------------------------------------------------------------
# Build inside container
# ------------------------------------------------------------------------------
build_trustless() {
  work_dir="/tmp/trustless_build_${version_name}_$$"
  mkdir -p "${work_dir}"
  log_info "Workspace: ${work_dir}"

  local tag="${requested_version:-${version_name}}"
  write_build_script

  log_info "Running build inside RN container (tag ${tag})..."
  "${CONTAINER_CMD}" run --rm \
    --volume "${work_dir}:/work" \
    ${CONTAINER_RUN_USER_ARGS} \
    "${RN_BUILD_IMAGE}" \
    bash /work/run_build.sh "${tag}" "${REPO_URL}" \
    || { [[ -f "${work_dir}/commit_hash.txt" ]] && commit_hash="$(cat "${work_dir}/commit_hash.txt")"; \
         die_failed "Build failed inside container. Check output above."; }

  [[ -f "${work_dir}/commit_hash.txt" ]] && commit_hash="$(cat "${work_dir}/commit_hash.txt")"

  local built_apk="${work_dir}/src/android/app/build/outputs/apk/release/app-release-unsigned.apk"
  if [[ ! -f "${built_apk}" ]]; then
    die_failed "Built APK not found at: ${built_apk}"
  fi

  local built_hash
  built_hash="$(sha256sum "${built_apk}" | awk '{print $1}')"
  log_info "Built APK SHA-256: ${built_hash}"
}

# ------------------------------------------------------------------------------
# Compare APKs (exclude META-INF; full diff to file; 5-line terminal preview)
# ------------------------------------------------------------------------------
compare_apks() {
  log_info "Comparing official vs built APK..."

  local compare_dir="${work_dir}/compare"
  local official_dir="${compare_dir}/official"
  local built_dir="${compare_dir}/built"
  local diff_file="${work_dir}/diff_full.txt"
  local built_apk="${work_dir}/src/android/app/build/outputs/apk/release/app-release-unsigned.apk"
  local apk_dir apk_file
  apk_dir="$(dirname "${downloaded_apk}")"
  apk_file="$(basename "${downloaded_apk}")"

  mkdir -p "${official_dir}" "${built_dir}"

  log_info "Unpacking official APK..."
  "${CONTAINER_CMD}" run --rm \
    --volume "${apk_dir}:/apkdir${VOLUME_RO_SUFFIX}" \
    --volume "${official_dir}:/out" \
    ${CONTAINER_RUN_USER_ARGS} \
    "${WS_CONTAINER}" \
    unzip -q -o "/apkdir/${apk_file}" -d /out

  log_info "Unpacking built APK..."
  local built_apk_dir
  built_apk_dir="$(dirname "${built_apk}")"
  local built_apk_file
  built_apk_file="$(basename "${built_apk}")"
  "${CONTAINER_CMD}" run --rm \
    --volume "${built_apk_dir}:/builtdir${VOLUME_RO_SUFFIX}" \
    --volume "${built_dir}:/out" \
    ${CONTAINER_RUN_USER_ARGS} \
    "${WS_CONTAINER}" \
    unzip -q -o "/builtdir/${built_apk_file}" -d /out

  log_info "Running diff (excluding META-INF)..."
  local diff_output
  diff_output="$(diff -r --exclude='META-INF' "${official_dir}" "${built_dir}" 2>/dev/null || true)"
  printf '%s\n' "${diff_output}" > "${diff_file}"

  local diff_lines
  diff_lines="$(wc -l < "${diff_file}")"

  echo ""
  echo "Diff preview (first 5 lines — full diff in ${diff_file}):"
  head -5 "${diff_file}" || true
  if [[ "${diff_lines}" -gt 5 ]]; then
    echo "... (${diff_lines} lines total — see ${diff_file})"
  fi
  echo ""

  local verdict
  if [[ "${diff_lines}" -eq 0 ]]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
    append_additional_info "Diff has ${diff_lines} lines — see diff_full.txt"
  fi

  print_results_block "${verdict}"

  local notes=""
  [[ -n "${additional_info}" ]] && notes="${additional_info}"
  generate_result_yaml "${verdict}" "${notes}"
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
  if [[ "${should_cleanup}" == "true" && -n "${work_dir}" && -d "${work_dir}" ]]; then
    log_info "Removing workspace ${work_dir}..."
    rm -rf "${work_dir}"
  else
    [[ -n "${work_dir}" ]] && log_info "Workspace preserved at: ${work_dir}"
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
collect_official_metadata
build_trustless
compare_apks
cleanup

log_info "Done. Results written to ${execution_dir}/COMPARISON_RESULTS.yaml"
echo "Exit code: ${EXIT_SUCCESS}"
exit "${EXIT_SUCCESS}"
