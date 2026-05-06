#!/bin/bash
# ==============================================================================
# blitzwallet_build.sh - BlitzWallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.9
# Organization:  WalletScrutiny.com
# Last Modified: 2026-05-06
# Project:       https://github.com/BlitzWallet/BlitzWallet
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.blitzwallet/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding the security,
# functionality, or fitness for any particular purpose. Users assume all risks
# associated with running this script and analyzing the software. This script
# performs automated builds and APK comparisons -- review all operations before
# execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws and regulations. The developers assume no liability for any
# misuse or legal consequences arising from use. By using this script, you
# acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Accepts official split APKs via --binary (path to directory or .apks zip)
# - Clones BlitzWallet repository inside a container (no host git dependency)
# - Builds using bundleRelease (AAB) inside a React Native Android container
# - Extracts matching split APKs from built AAB via bundletool + device-spec.json
# - Compares official split APKs against built split APKs, split-by-split
# - Filters META-INF differences using Leo's regex pattern
# - Generates COMPARISON_RESULTS.yaml and standardized verification summary
#
# DISTRIBUTION: BlitzWallet is distributed via Google Play as split APKs.
# The Play Store generates device-specific splits (base, arch, lang, density)
# from an AAB. This script builds that AAB and extracts matching splits.
#
# KNOWN CHALLENGES:
# - No official build.sh or reproducible build documentation exists
# - Metro/Hermes JS bundle may be non-deterministic across environments
# - Firebase SDK introduces proprietary native libraries
# - NDK 27.1.12297006 must match exactly for native module output
# - All git tags are lightweight (no GPG signatures possible on tags)

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.1.9"
APP_ID="com.blitzwallet"
REPO_URL="https://github.com/BlitzWallet/BlitzWallet.git"
REQUIRED_NDK_VERSION="27.1.12297006"

# WalletScrutiny utility container (apksigner, aapt, apktool, sha256sum, curl, git)
WS_CONTAINER="docker.io/walletscrutiny/android:5"

# React Native Android build image.
# Verified 2026-05-06: contains /opt/android/ndk/27.1.12297006,
# Node v22.14.0, and Yarn 1.22.22.
RN_BUILD_IMAGE="docker.io/reactnativecommunity/react-native-android@sha256:88d93a9282e0f54f84cec7b979da6c5e3f20d87f5be246b75c231838be852fec"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"

should_cleanup=false
downloaded_apk=""
requested_version=""
requested_arch=""
requested_type=""
requested_tag=""

version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
additional_info=""
result_done=false

work_dir=""
official_splits_dir=""
built_splits_dir=""
built_aab_path=""

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARNING] $*"
}

log_error() {
  echo "[ERROR] $*"
}

append_additional_info() {
  local line="$1"
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n${line}"
  else
    additional_info="${line}"
  fi
}

write_yaml_outputs() {
  local content="$1"
  printf '%s\n' "${content}" > "${execution_dir}/COMPARISON_RESULTS.yaml"
  if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
    printf '%s\n' "${content}" > "${work_dir}/COMPARISON_RESULTS.yaml" || true
  fi
  result_done=true
}

die_invalid() {
  log_error "$*"
  echo "Exit code: ${EXIT_INVALID}"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  generate_error_yaml "ftbfs" "$*"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}

on_error() {
  local exit_code=$?
  local line_no=$1
  set +e
  log_error "Script failed at line ${line_no} (exit code ${exit_code})"
  if [[ "${result_done}" != "true" ]]; then
    generate_error_yaml "ftbfs" "Script failed at line ${line_no} (exit code ${exit_code})."
  fi
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Container runtime detection
# Podman and Docker have different volume suffix and user argument conventions.
# ------------------------------------------------------------------------------
CONTAINER_CMD=""
VOLUME_RO_SUFFIX=""
VOLUME_RW_SUFFIX=""
CONTAINER_RUN_USER_ARGS=""

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
  CONTAINER_RUN_USER_ARGS="--userns=keep-id"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  VOLUME_RW_SUFFIX=""
  CONTAINER_RUN_USER_ARGS="--user $(id -u):$(id -g)"
else
  die_failed "Neither podman nor docker is available. Install one to continue."
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       blitzwallet_build.sh - BlitzWallet reproducible build verification (AAB/split APKs)

SYNOPSIS
       ${script_name} --version <version> --binary <apks_dir_or_file> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds BlitzWallet from source (AAB) in a container, extracts matching
       split APKs using bundletool, and compares them against the official split
       APKs provided via --binary.

       BlitzWallet is distributed via Google Play as split APKs. The script
       expects official split APKs as input (base.apk, split_config.arm64_v8a.apk,
       split_config.en.apk, split_config.xxhdpi.apk, etc.).

OPTIONS
       --version <version>     Version to verify (required). E.g.: 0.7.7
       --binary <path>         Path to a directory of official split APKs, a .apks
                               zip file, or a single .apk file. When a single .apk
                               is provided, only that split is compared. (Alias: --apk)
       --apk <path>            Alias for --binary (Android legacy compatibility)
       --arch <arch>           Architecture hint (default: arm64-v8a).
                               Used to select the matching native split.
                               Supported: arm64-v8a, armeabi-v7a, x86, x86_64
       --tag <ref>             Git tag or branch to clone (default: Android-v<version>).
                               Use when the Play Store release uses a different tag.
       --type <type>           Build type (accepted for build server compatibility; ignored)
       --cleanup               Remove temporary workspace after completion
       --script-version        Print script version and exit
       --help                  Show this help and exit

EXIT CODES
       0    Reproducible (only META-INF differences between official and built)
       1    Differences found or build failure
       2    Invalid parameters or configuration

SPLIT APK INPUT FORMAT
       Provide --binary pointing to a directory with split APKs:
         base.apk
         split_config.arm64_v8a.apk   (or armeabi_v7a, x86, x86_64)
         split_config.en.apk
         split_config.xxhdpi.apk      (or other density)

       Or provide a .apks file (ZIP archive containing the above APKs).

EXAMPLES
       ${script_name} --version 0.7.7 --binary ~/splits/
       ${script_name} --version 0.7.7 --binary ~/splits/ --arch arm64-v8a
       ${script_name} --version 0.7.7 --binary ~/blitzwallet.apks
       ${script_name} --version 0.7.7 --binary ~/splits/ --tag Android-v0.7.7-pre10
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# Unknown arguments are warned and ignored (never fatal) per Luis 2026-03-11/12.
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) requested_version="$2"; shift ;;
    --apk) downloaded_apk="$2"; shift ;;
    --binary) downloaded_apk="$2"; shift ;;
    --arch) requested_arch="$2"; shift ;;
    --type) requested_type="$2"; shift ;;
    --tag) requested_tag="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Ignoring unknown argument: $1" ;;
  esac
  shift
done

# --binary is required for split APK builds (no auto-download: Play splits are device-specific)
if [[ -z "${downloaded_apk}" ]]; then
  die_invalid "You must provide --binary <path> pointing to official split APKs directory or .apks file."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

# version_name may be empty here; it will be derived from APK metadata if not provided
version_name="${requested_version}"

# Validate and normalize --arch
build_arch="arm64-v8a"
if [[ -n "${requested_arch}" ]]; then
  case "${requested_arch}" in
    arm64-v8a|armeabi-v7a|x86|x86_64) build_arch="${requested_arch}" ;;
    *) log_warn "Unsupported --arch '${requested_arch}'. Defaulting to arm64-v8a." ;;
  esac
fi

# Note unused --type for compatibility
if [[ -n "${requested_type}" ]]; then
  append_additional_info "Build type '${requested_type}' accepted for compatibility; BlitzWallet has a single build type."
fi

# git_ref is resolved after extract_official_metadata() sets version_name
git_ref=""

# ------------------------------------------------------------------------------
# Helper: containerized sha256sum
# Runs sha256sum inside the WS utility container to avoid host tool dependency.
# ------------------------------------------------------------------------------
container_sha256() {
  local file_path="$1"
  local file_dir file_name
  file_dir="$(dirname "$file_path")"
  file_name="$(basename "$file_path")"
  $CONTAINER_CMD run --rm \
    --volume "${file_dir}:/data${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "sha256sum /data/${file_name} | awk '{print \$1}'"
}

# ------------------------------------------------------------------------------
# Helper: extract signer certificate fingerprint from an APK
# Uses apksigner inside the WS container so no host tool required.
# ------------------------------------------------------------------------------
container_signer() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apksigner verify --print-certs /apk/${apk_name} 2>/dev/null | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" \
    || echo "unknown"
}

# ------------------------------------------------------------------------------
# Helper: extract versionName or versionCode from an APK via aapt/apktool
# Runs in the WS container with a read-only APK mount.
# ------------------------------------------------------------------------------
container_aapt_version() {
  local apk_path="$1"
  local field="$2"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c '
      badging_output="$({ aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
      if [ -n "$badging_output" ]; then
        printf "%s\n" "$badging_output" | sed -n "s/.*'"${field}"'='\''\([^'\'']*\)'\''.*/\1/p" | head -n1
        exit 0
      fi
      tmpdir=$(mktemp -d)
      if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
        case "'"${field}"'" in
          versionName)
            sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" "$tmpdir/out/apktool.yml" | head -n1
            ;;
          versionCode)
            sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'\''\([^'\'']*\)'\''/\1/p" "$tmpdir/out/apktool.yml" | head -n1
            ;;
        esac
      fi
      rm -rf "$tmpdir"
    '
}

# ------------------------------------------------------------------------------
# Helper: run a git command in the cloned source repo inside a container
# The repo lives at ${work_dir}/app which is mounted read-only.
# ------------------------------------------------------------------------------
git_in_container() {
  local cmd="$1"
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "${cmd}"
}

# ------------------------------------------------------------------------------
# YAML generation helpers
# ------------------------------------------------------------------------------
generate_error_yaml() {
  local status="$1"
  local notes="${2:-}"

  if [[ -n "${notes}" ]]; then
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
$(printf '%s\n' "${notes}" | sed 's/^/  /')"
    return
  fi

  write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}"
}

generate_comparison_yaml() {
  local yaml_status="$1"
  write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${yaml_status}
notes: |
  BlitzWallet is a React Native 0.81.4 + Expo SDK 54 app distributed as AAB/split APKs.
  Build uses: Node >=20, Yarn, Android SDK 36, NDK 27.1.12297006, Gradle 8.14.3.
  No official build.sh or reproducible build docs exist ("Build: Coming soon" in README).
  All git tags are lightweight (no GPG signatures possible).
  Known non-determinism sources:
  - META-INF/*: Google Play signing artifacts (expected in all Play-distributed splits)
  - index.android.bundle: Metro/Hermes JS bundle (non-deterministic across environments)
  - Firebase SDK native libraries (pre-compiled .so files from Google BOM 34.3.0)
  - NDK-compiled native modules: Breez SDK Liquid, react-native-quick-crypto, vision-camera
"
}

detect_known_build_failure() {
  local build_log="${work_dir}/app/gradle-build.log"
  local reanimated_version=""
  local worklets_version=""

  if [[ -f "${work_dir}/app/node_modules/react-native-reanimated/package.json" ]]; then
    reanimated_version="$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
      "${work_dir}/app/node_modules/react-native-reanimated/package.json" | head -n1)"
  fi

  if [[ -f "${work_dir}/app/node_modules/react-native-worklets/package.json" ]]; then
    worklets_version="$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
      "${work_dir}/app/node_modules/react-native-worklets/package.json" | head -n1)"
  fi

  if [[ "${reanimated_version}" == 4.* && -n "${worklets_version}" ]]; then
    local worklets_major worklets_minor
    worklets_major="${worklets_version%%.*}"
    worklets_minor="${worklets_version#*.}"
    worklets_minor="${worklets_minor%%.*}"

    if [[ "${worklets_major:-0}" -eq 0 && "${worklets_minor:-0}" -lt 7 ]]; then
      die_failed "Build failed because react-native-reanimated ${reanimated_version:-unknown} requires react-native-worklets 0.7.x or newer, but the repo installs ${worklets_version:-unknown}. This tag does not build cleanly from its checked-in dependency state."
    fi
  fi

  if [[ -f "${build_log}" ]] && grep -q "assertWorkletsVersionTask" "${build_log}"; then
    die_failed "Build failed because react-native-reanimated ${reanimated_version:-unknown} requires react-native-worklets 0.7.x or newer, but the repo installs ${worklets_version:-unknown}. This tag does not build cleanly from its checked-in dependency state."
  fi

  die_failed "Gradle build failed. See ${build_log} for details."
}

detect_build_image_failure() {
  local build_log="${work_dir}/app/gradle-build.log"
  if [[ -f "${build_log}" ]]; then
    if grep -q "Required Android NDK ${REQUIRED_NDK_VERSION} not found" "${build_log}"; then
      die_failed "Build image does not contain Android NDK ${REQUIRED_NDK_VERSION}. Pin or rebuild the container image with the required NDK."
    fi
    if grep -q "@expo/cli is not resolvable" "${build_log}"; then
      die_failed "Expo CLI is not resolvable after yarn install. Gradle uses @expo/cli for bundleCommand export:embed, so JS bundling cannot proceed."
    fi
    if grep -q "yarn.lock changed during yarn install" "${build_log}"; then
      die_failed "yarn.lock changed during yarn install. This indicates dependency drift; refusing to continue with a mutated dependency graph."
    fi
  fi
}

# ------------------------------------------------------------------------------
# Prepare official split APKs directory
# Handles: directory input, .apks zip input
# ------------------------------------------------------------------------------
prepare_official_splits() {
  log_info "Preparing official split APKs..."

  # Resolve absolute path
  if [[ "${downloaded_apk}" != /* ]]; then
    downloaded_apk="${execution_dir}/${downloaded_apk}"
  fi

  if [[ ! -e "${downloaded_apk}" ]]; then
    die_invalid "Path not found: ${downloaded_apk}"
  fi

  if [[ -d "${downloaded_apk}" ]]; then
    # Directory input: use as-is
    official_splits_dir="${downloaded_apk}"
    log_info "Using split APKs directory: ${official_splits_dir}"
    if [[ ! -f "${official_splits_dir}/base.apk" ]]; then
      die_invalid "base.apk not found in: ${official_splits_dir}"
    fi
  elif [[ -f "${downloaded_apk}" && "${downloaded_apk}" == *.apks ]]; then
    # .apks file input: extract to a temp directory
    local apks_extract_dir="${work_dir}/official-apks-extracted"
    mkdir -p "${apks_extract_dir}"
    log_info "Extracting .apks file: ${downloaded_apk}"
    $CONTAINER_CMD run --rm \
      --volume "$(dirname "${downloaded_apk}"):/input${VOLUME_RO_SUFFIX}" \
      --volume "${apks_extract_dir}:/output${VOLUME_RW_SUFFIX}" \
      "$WS_CONTAINER" \
      sh -c "unzip -qq /input/$(basename "${downloaded_apk}") -d /output"
    # bundletool puts splits in a 'splits/' subdir inside the .apks archive
    if [[ -d "${apks_extract_dir}/splits" ]]; then
      official_splits_dir="${apks_extract_dir}/splits"
    else
      official_splits_dir="${apks_extract_dir}"
    fi
    log_info "Extracted splits to: ${official_splits_dir}"
    if [[ ! -f "${official_splits_dir}/base.apk" ]]; then
      die_invalid "base.apk not found in extracted .apks: ${official_splits_dir}"
    fi
  elif [[ -f "${downloaded_apk}" && "${downloaded_apk}" == *.apk ]]; then
    # Single APK file: wrap in a temp directory; only this split will be compared
    local single_dir="${work_dir}/official-single-apk"
    mkdir -p "${single_dir}"
    local fname
    fname="$(basename "${downloaded_apk}")"
    cp "${downloaded_apk}" "${single_dir}/${fname}"
    official_splits_dir="${single_dir}"
    log_info "Single APK mode: only '${fname}' will be compared."
  else
    die_invalid "--binary must be a directory of split APKs, a .apks file, or a single .apk file. Got: ${downloaded_apk}"
  fi
}

# ------------------------------------------------------------------------------
# Extract metadata from official base.apk
# base.apk contains the core app metadata (versionName, versionCode, signer).
# ------------------------------------------------------------------------------
extract_official_metadata() {
  local base_apk="${official_splits_dir}/base.apk"
  if [[ ! -f "${base_apk}" ]]; then
    # Single APK mode: use the provided file for metadata extraction
    base_apk="$(find "${official_splits_dir}" -maxdepth 1 -name "*.apk" -print -quit 2>/dev/null || true)"
    if [[ -z "${base_apk}" ]]; then
      die_invalid "No APK files found in: ${official_splits_dir}"
    fi
    log_warn "base.apk not present; using '$(basename "${base_apk}")' for metadata extraction."
  fi

  app_hash="$(container_sha256 "${base_apk}")"
  signer="$(container_signer "${base_apk}")"
  version_name_from_apk="$(container_aapt_version "${base_apk}" "versionName")"
  version_code="$(container_aapt_version "${base_apk}" "versionCode")"

  if [[ -z "${version_name_from_apk}" ]]; then
    version_name_from_apk="${version_name}"
  fi
  if [[ -z "${version_code}" ]]; then
    version_code="unknown"
  fi

  log_info "Official base.apk metadata:"
  log_info "  versionName: ${version_name_from_apk}"
  log_info "  versionCode: ${version_code}"
  log_info "  signer: ${signer}"
  log_info "  sha256: ${app_hash}"

  if [[ -n "${requested_version}" && -n "${version_name_from_apk}" && "${requested_version}" != "${version_name_from_apk}" ]]; then
    append_additional_info "Requested version ${requested_version} but base.apk reports ${version_name_from_apk}."
    log_warn "Version mismatch: requested ${requested_version}, APK reports ${version_name_from_apk}"
  fi
}

# ------------------------------------------------------------------------------
# Auto-generate device-spec.json from the official split APK filenames and
# base.apk metadata. bundletool needs this to know which splits to extract.
# ------------------------------------------------------------------------------
generate_device_spec() {
  local spec_file="${work_dir}/device-spec.json"

  # Detect architecture from split APK filenames in official_splits_dir
  local detected_abi="${build_arch}"
  local detected_density="480"
  local detected_locale="en"
  local sdk_version="34"

  # Architecture detection from split filenames
  for f in "${official_splits_dir}"/split_config.*.apk; do
    [[ -f "$f" ]] || continue
    local fname
    fname="$(basename "$f")"
    case "${fname}" in
      *arm64_v8a*) detected_abi="arm64-v8a" ;;
      *armeabi_v7a*) detected_abi="armeabi-v7a" ;;
      *x86_64*) detected_abi="x86_64" ;;
      *x86*) detected_abi="x86" ;;
    esac
    # Density detection from split filenames
    case "${fname}" in
      *xxxhdpi*) detected_density="640" ;;
      *xxhdpi*) detected_density="480" ;;
      *xhdpi*) detected_density="320" ;;
      *hdpi*) detected_density="240" ;;
      *mdpi*) detected_density="160" ;;
      *ldpi*) detected_density="120" ;;
    esac
    # Locale detection (simple: check for common locales)
    case "${fname}" in
      *_en.apk|*_en_*) detected_locale="en" ;;
    esac
  done

  # Extract sdkVersion from base.apk using aapt inside the WS container
  local apk_sdk
  apk_sdk="$($CONTAINER_CMD run --rm \
    --volume "${official_splits_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "aapt dump badging /apk/base.apk 2>/dev/null | grep 'sdkVersion' | sed \"s/.*sdkVersion:'\\([0-9]*\\)'.*/\\1/\" | head -n1" || echo "")"
  if [[ -n "${apk_sdk}" ]]; then
    sdk_version="${apk_sdk}"
  fi

  log_info "Generating device-spec.json:"
  log_info "  supportedAbis: [\"${detected_abi}\", \"armeabi-v7a\"]"
  log_info "  screenDensity: ${detected_density}"
  log_info "  supportedLocales: [\"${detected_locale}\"]"
  log_info "  sdkVersion: ${sdk_version}"

  cat > "${spec_file}" <<EOF
{
  "supportedAbis": ["${detected_abi}", "armeabi-v7a"],
  "supportedLocales": ["${detected_locale}"],
  "screenDensity": ${detected_density},
  "sdkVersion": ${sdk_version}
}
EOF

  log_info "device-spec.json written to: ${spec_file}"
}

# ------------------------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------------------------
log_info "Setting up workspace..."
# Use a temporary name; renamed below once version_name is known from APK metadata.
work_dir="${execution_dir}/workdir_${APP_ID}_${build_arch}_$$"
if [[ -d "${work_dir}" ]]; then
  log_info "Removing existing workspace: ${work_dir}"
  rm -rf "${work_dir}"
fi
mkdir -p "${work_dir}"

# ------------------------------------------------------------------------------
# Prepare official splits (must happen after work_dir exists for .apks extraction)
# ------------------------------------------------------------------------------
prepare_official_splits
extract_official_metadata

# Derive version_name from APK metadata if --version was not provided
if [[ -z "${version_name}" ]]; then
  if [[ -n "${version_name_from_apk}" ]]; then
    version_name="${version_name_from_apk}"
    log_info "Version derived from APK metadata: ${version_name}"
  else
    die_invalid "Could not determine version from APK metadata. Provide --version explicitly."
  fi
fi

# Rename workspace now that version_name is known
final_work_dir="${execution_dir}/workdir_${APP_ID}_${version_name}_${build_arch}_$$"
mv "${work_dir}" "${final_work_dir}"
work_dir="${final_work_dir}"
log_info "Workspace: ${work_dir}"

# Resolve git_ref now that version_name is known
if [[ -n "${requested_tag}" ]]; then
  log_info "Using git ref override: ${requested_tag}"
  append_additional_info "Git ref override: --tag ${requested_tag} used instead of default Android-v${version_name}."
fi
git_ref="${requested_tag:-Android-v${version_name}}"

# ------------------------------------------------------------------------------
# Generate device-spec.json for bundletool
# ------------------------------------------------------------------------------
generate_device_spec

# ------------------------------------------------------------------------------
# Source clone (containerized)
# All git operations run inside the WS container -- no host git dependency.
# ------------------------------------------------------------------------------
log_info "Cloning BlitzWallet repository (tag: ${git_ref})..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone --depth 1 --branch '${git_ref}' '${REPO_URL}' app"

commit_hash="$(git_in_container "git rev-parse HEAD")"
log_info "Checked out ${git_ref} at commit: ${commit_hash}"

# Verify tag type for signature check (all BlitzWallet tags are lightweight, no signatures)
tag_type="commit-only"
tag_signature_status="[INFO] No annotated tag found (BlitzWallet uses lightweight tags)"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""

if git_in_container "git rev-parse --verify 'refs/tags/${git_ref}' >/dev/null 2>&1"; then
  if git_in_container "test \"\$(git cat-file -t 'refs/tags/${git_ref}')\" = 'tag'"; then
    tag_type="annotated"
    tag_output="$(git_in_container "git tag -v '${git_ref}' 2>&1 || true")"
    if echo "${tag_output}" | grep -q "Good signature"; then
      tag_signature_status="[OK] Good signature on annotated tag"
      tag_key="$(echo "${tag_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
      if [[ -n "${tag_key}" ]]; then
        signature_keys="Tag signed with: ${tag_key}"
      fi
    else
      tag_signature_status="[WARNING] Annotated tag found but no valid GPG signature"
      signature_warnings="- Annotated tag exists but is not GPG-signed"
    fi
  else
    tag_type="lightweight"
    tag_signature_status="[INFO] Tag is lightweight -- cannot contain a GPG signature"
  fi
fi

commit_output="$(git_in_container "git verify-commit '${commit_hash}' 2>&1 || true")"
if echo "${commit_output}" | grep -q "Good signature"; then
  commit_signature_status="[OK] Good signature on commit"
  commit_key="$(echo "${commit_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
  if [[ -n "${commit_key}" ]]; then
    if [[ -n "${signature_keys}" ]]; then
      signature_keys="${signature_keys}\nCommit signed with: ${commit_key}"
    else
      signature_keys="Commit signed with: ${commit_key}"
    fi
  fi
else
  commit_signature_status="[WARNING] No valid GPG signature on commit"
  signature_warnings="${signature_warnings:+${signature_warnings}\n}- Commit is not GPG-signed"
fi

# ------------------------------------------------------------------------------
# Containerized AAB Build
# The build runs inside the React Native Android community image which includes:
# JDK 17, Android SDK, NDK, and a compatible Node version.
# We set HOME and GRADLE_USER_HOME to /tmp to avoid permission issues.
# We patch the signing config to use the debug keystore (release key not available).
# ------------------------------------------------------------------------------
log_info "Starting containerized AAB build..."
log_info "This may take 20-40 minutes on first run (downloading Gradle, npm packages)..."

# Patch release signing to use debug keystore so the build does not fail on
# missing MY_STORE_PASSWORD / MY_KEY_PASSWORD environment variables.
# The debug keystore is committed at android/app/debug.keystore.
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace/app \
  "$WS_CONTAINER" \
  sh -c "
    sed -i 's/signingConfig signingConfigs.release/signingConfig signingConfigs.debug/g' android/app/build.gradle
    echo '[PATCH] Replaced release signingConfig with debug signingConfig in android/app/build.gradle'
  "

# Run the full build inside the React Native Android image.
# Steps mirror the manual build instructions:
#  1. Add JSR npm registry (required for some deps)
#  2. yarn install, then fail if yarn.lock changes
#  3. bundleRelease -- produces app-release.aab
if ! $CONTAINER_CMD run --rm \
  ${CONTAINER_RUN_USER_ARGS} \
  --volume "${work_dir}/app:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  --env HOME=/tmp \
  --env GRADLE_USER_HOME=/tmp/.gradle \
  --env ANDROID_SDK_HOME=/tmp \
  --env ANDROID_PREFS_ROOT=/tmp \
  --env NODE_ENV=production \
  "$RN_BUILD_IMAGE" \
  bash -c "
    set -euxo pipefail
    : > /workspace/gradle-build.log

    echo '=== Step 0: Verify pinned build image toolchain ===' | tee -a /workspace/gradle-build.log
    if [ ! -d \"\${ANDROID_HOME:-/opt/android}/ndk/${REQUIRED_NDK_VERSION}\" ] && [ ! -d \"/opt/android/ndk/${REQUIRED_NDK_VERSION}\" ] && [ ! -d \"/opt/android-sdk/ndk/${REQUIRED_NDK_VERSION}\" ]; then
      echo '[ERROR] Required Android NDK ${REQUIRED_NDK_VERSION} not found in build image.' | tee -a /workspace/gradle-build.log
      find /opt -path '*/ndk/*' -maxdepth 4 -type d 2>/dev/null | tee -a /workspace/gradle-build.log || true
      exit 88
    fi
    node --version | tee -a /workspace/gradle-build.log
    yarn --version | tee -a /workspace/gradle-build.log

    echo '=== Step 1: Configure npm registry for JSR packages ==='
    echo '@jsr:registry=https://npm.jsr.io' >> .npmrc
    yarn config set registry https://registry.npmjs.org/

    echo '=== Step 2: Install JavaScript dependencies ==='
    # NODE_ENV=production skips devDependencies; override for this step so Babel
    # plugins (react-native-dotenv, babel-plugin-module-resolver, etc.) are installed.
    NODE_ENV=development yarn install

    echo '=== Step 2a: Check yarn.lock did not drift ==='
    if ! git diff --quiet -- yarn.lock; then
      echo '[ERROR] yarn.lock changed during yarn install.' | tee -a /workspace/gradle-build.log
      git diff -- yarn.lock > /workspace/yarn-lock-drift.diff || true
      exit 87
    fi

    echo '=== Step 2b: Check Babel plugin dependencies and Expo CLI ==='
    node -e \"require.resolve('react-native-dotenv/package.json'); require.resolve('babel-plugin-module-resolver/package.json'); require.resolve('react-native-worklets/package.json')\" \
      || echo '[WARNING] One or more Babel plugin deps not found at top level; proceeding anyway.'
    node -e \"require.resolve('@expo/cli')\" \
      || { echo '[ERROR] @expo/cli is not resolvable after yarn install.' | tee -a /workspace/gradle-build.log; exit 89; }

    echo '=== Step 2c: Check Reanimated/Worklets compatibility ==='
    node <<'NODE'
const fs = require('fs');
const path = require('path');

function readVersion(pkgName) {
  const pkgPath = path.join(process.cwd(), 'node_modules', pkgName, 'package.json');
  if (!fs.existsSync(pkgPath)) return '';
  return JSON.parse(fs.readFileSync(pkgPath, 'utf8')).version || '';
}

function parseSemver(version) {
  return version.split('-')[0].split('.').map((part) => parseInt(part, 10) || 0);
}

function isLessThan(left, right) {
  for (let i = 0; i < 3; i += 1) {
    const a = left[i] || 0;
    const b = right[i] || 0;
    if (a < b) return true;
    if (a > b) return false;
  }
  return false;
}

const reanimatedVersion = readVersion('react-native-reanimated');
const workletsVersion = readVersion('react-native-worklets');

if (reanimatedVersion.startsWith('4.') && workletsVersion && isLessThan(parseSemver(workletsVersion), [0, 7, 0])) {
  console.error('[ERROR] Incompatible dependency state detected before Gradle build.');
  console.error('[ERROR] react-native-reanimated=' + reanimatedVersion);
  console.error('[ERROR] react-native-worklets=' + workletsVersion);
  console.error('[ERROR] Reanimated 4.x requires Worklets 0.7.x or newer.');
  process.exit(86);
}
NODE

    echo '=== Step 2d: Create empty env files if repo does not ship them ==='
    [ -f .env ] || : > .env
    [ -f .env.production ] || cp .env .env.production

    echo '=== Step 2e: Select Node binary for Gradle/Metro ==='
    export NODE_BINARY=\"\$(command -v node)\"
    echo \"Using NODE_BINARY=\${NODE_BINARY}\"
    node --version

    echo '=== Step 3: Build AAB (bundleRelease) ==='
    cd android
    ./gradlew bundleRelease \
      -PNODE_BINARY=\"\${NODE_BINARY}\" \
      -Dorg.gradle.jvmargs='-Xmx4096m -XX:MaxMetaspaceSize=1024m' \
      --no-daemon \
      --stacktrace \
      2>&1 | tee /workspace/gradle-build.log
    # Re-check exit code after tee (tee swallows it)
    grep -q "BUILD FAILED" /workspace/gradle-build.log && exit 1 || true
  "; then
  detect_build_image_failure
  detect_known_build_failure
fi

# Locate the built AAB
built_aab_path="${work_dir}/app/android/app/build/outputs/bundle/release/app-release.aab"
if [[ ! -f "${built_aab_path}" ]]; then
  log_warn "Expected AAB not found at: ${built_aab_path}"
  log_info "Searching for built AABs..."
  found_aab="$(find "${work_dir}/app" -type f -name "*.aab" -print -quit 2>/dev/null || true)"
  if [[ -n "${found_aab}" && -f "${found_aab}" ]]; then
    built_aab_path="${found_aab}"
    log_info "Found AAB at: ${built_aab_path}"
  else
    die_failed "Built AAB not found after build step."
  fi
fi

log_info "AAB built successfully: ${built_aab_path}"

# ------------------------------------------------------------------------------
# Extract split APKs from built AAB using bundletool
# bundletool reads the device-spec.json and extracts only the matching splits.
# The output .apks file is a ZIP containing: splits/base-master.apk,
# splits/split_config.arm64_v8a.apk, splits/split_config.en.apk, etc.
# ------------------------------------------------------------------------------
log_info "Extracting split APKs from built AAB via bundletool..."

built_apks_file="${work_dir}/built-splits.apks"
built_splits_dir="${work_dir}/built-split-apks"
mkdir -p "${built_splits_dir}"

$CONTAINER_CMD run --rm \
  ${CONTAINER_RUN_USER_ARGS} \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --volume "${work_dir}/app/android/app:/aab${VOLUME_RO_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  bash -c "
    set -euxo pipefail

    echo '=== Downloading bundletool ==='
    curl -L -f -o /workspace/bundletool.jar \
      'https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar'

    echo '=== Generating debug keystore for bundletool signing ==='
    keytool -genkey -v \
      -keystore /workspace/verify-debug.keystore \
      -alias androiddebugkey \
      -keyalg RSA \
      -keysize 2048 \
      -validity 10000 \
      -storepass android \
      -keypass android \
      -dname 'CN=Android Debug,O=Android,C=US' 2>/dev/null || true

    echo '=== Extracting split APKs from AAB ==='
    java -jar /workspace/bundletool.jar build-apks \
      --bundle=/aab/build/outputs/bundle/release/app-release.aab \
      --output=/workspace/built-splits.apks \
      --device-spec=/workspace/device-spec.json \
      --ks=/workspace/verify-debug.keystore \
      --ks-key-alias=androiddebugkey \
      --ks-pass=pass:android \
      --key-pass=pass:android \
      --overwrite

    echo '=== Unzipping .apks archive ==='
    unzip -qq /workspace/built-splits.apks -d /workspace/built-split-apks/

    echo '=== Listing extracted splits ==='
    ls -la /workspace/built-split-apks/splits/ 2>/dev/null || ls -la /workspace/built-split-apks/
  "

# Normalize bundletool output: base-master.apk -> base.apk
if [[ -f "${built_splits_dir}/splits/base-master.apk" ]]; then
  cp "${built_splits_dir}/splits/base-master.apk" "${built_splits_dir}/splits/base.apk"
  log_info "Normalized: base-master.apk -> base.apk"
fi

# The actual splits are in the splits/ subdirectory inside the .apks archive
if [[ -d "${built_splits_dir}/splits" ]]; then
  built_splits_dir="${built_splits_dir}/splits"
  log_info "Built splits directory: ${built_splits_dir}"
else
  log_warn "Expected splits/ subdir not found; using: ${built_splits_dir}"
fi

if [[ ! -f "${built_splits_dir}/base.apk" ]]; then
  die_failed "Built base.apk not found in: ${built_splits_dir}"
fi

# ------------------------------------------------------------------------------
# Split-by-split comparison
# Unzip official and built splits into separate directories, then diff -r.
# META-INF differences are expected (Google Play signing) and filtered using
# Leo's regex pattern from zeus_build.sh line 761.
# All diff output is preserved in files for human review.
# ------------------------------------------------------------------------------
log_info "Comparing split APKs..."

official_unzipped_dir="${work_dir}/official-unzipped"
built_unzipped_dir="${work_dir}/built-unzipped"
comparison_dir="${work_dir}/comparison"
mkdir -p "${official_unzipped_dir}" "${built_unzipped_dir}" "${comparison_dir}"

all_diff_output=""
total_non_meta_diffs=0
split_results=""

# Collect all official split names
declare -a official_splits=()
while IFS= read -r -d '' f; do
  fname="$(basename "$f")"
  official_splits+=("$fname")
done < <(find "${official_splits_dir}" -maxdepth 1 -name "*.apk" -print0 | sort -z)

log_info "Official splits found: ${official_splits[*]}"

for split_apk_name in "${official_splits[@]}"; do
  official_apk="${official_splits_dir}/${split_apk_name}"
  built_apk="${built_splits_dir}/${split_apk_name}"

  # Determine a safe directory name for this split (strip .apk, replace dots/hyphens)
  split_dir_name="${split_apk_name%.apk}"
  split_dir_name="${split_dir_name//split_config./}"
  split_dir_name="${split_dir_name//-/_}"

  official_unzipped="${official_unzipped_dir}/${split_dir_name}"
  built_unzipped="${built_unzipped_dir}/${split_dir_name}"
  diff_file="${comparison_dir}/diff-unzipped-${split_dir_name}.txt"

  mkdir -p "${official_unzipped}" "${built_unzipped}"

  log_info "--- Processing split: ${split_apk_name} ---"

  # Unzip official split
  $CONTAINER_CMD run --rm \
    --volume "${official_splits_dir}:/official${VOLUME_RO_SUFFIX}" \
    --volume "${official_unzipped}:/output${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "unzip -qq /official/${split_apk_name} -d /output"

  if [[ ! -f "${built_apk}" ]]; then
    log_warn "Built split not found: ${split_apk_name} -- skipping comparison for this split"
    append_additional_info "Missing built split: ${split_apk_name}"
    total_non_meta_diffs=$((total_non_meta_diffs + 1))
    split_results="${split_results}=== ${split_apk_name} ===\nMISSING in built output\n\n"
    continue
  fi

  # Unzip built split
  $CONTAINER_CMD run --rm \
    --volume "${built_splits_dir}:/built${VOLUME_RO_SUFFIX}" \
    --volume "${built_unzipped}:/output${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "unzip -qq /built/${split_apk_name} -d /output"

  # Run diff -r and save full output to file
  # The diff runs with absolute paths substituted for human readability.
  split_diff_brief=""
  split_diff_brief="$($CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace \
    "$WS_CONTAINER" \
    sh -c "diff -qr 'official-unzipped/${split_dir_name}' 'built-unzipped/${split_dir_name}' || true")" || true

  # Save full diff to file for human review (with real paths)
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace \
    "$WS_CONTAINER" \
    sh -c "diff -r 'official-unzipped/${split_dir_name}' 'built-unzipped/${split_dir_name}' > 'comparison/diff-unzipped-${split_dir_name}.txt' 2>&1 || true"

  # Filter META-INF using Leo's regex pattern (zeus_build.sh line 761)
  filtered_diff=""
  filtered_diff="$(echo "${split_diff_brief}" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)"
  filtered_compact="$(echo "${filtered_diff}" | tr -d '\n\r')"

  local_non_meta_count=0
  if [[ -n "${filtered_compact}" ]]; then
    local_non_meta_count="$(echo "${filtered_diff}" | grep -c '^' || true)"
  fi

  total_non_meta_diffs=$((total_non_meta_diffs + local_non_meta_count))

  # Replace container-relative paths with real paths in display output
  split_diff_display="$(echo "${split_diff_brief}" | sed "s|official-unzipped/${split_dir_name}|${official_unzipped}|g; s|built-unzipped/${split_dir_name}|${built_unzipped}|g")"
  split_results="${split_results}=== ${split_apk_name} (non-META-INF diffs: ${local_non_meta_count}) ===\n${split_diff_display}\n\n"

  log_info "Split ${split_apk_name}: ${local_non_meta_count} non-META-INF differences (full diff: ${diff_file})"
done

# ------------------------------------------------------------------------------
# Verdict determination
# Exit 0 = reproducible (0 non-META-INF diffs across all splits)
# Exit 1 = any differences found (or build failure)
# ------------------------------------------------------------------------------
verdict=""
yaml_status="not_reproducible"
exit_code="${EXIT_FAILED}"

if [[ "${total_non_meta_diffs}" -eq 0 ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  exit_code="${EXIT_SUCCESS}"
else
  verdict="differences found"
  yaml_status="not_reproducible"
fi

built_base_hash="$(container_sha256 "${built_splits_dir}/base.apk")"

# Write COMPARISON_RESULTS.yaml
generate_comparison_yaml "${yaml_status}"

# ------------------------------------------------------------------------------
# Standardized results output (===== Begin Results ===== block)
# Format matches zeus_build.sh for build server compatibility.
# ------------------------------------------------------------------------------
diff_guide=""
if [[ "${should_cleanup}" == false ]]; then
  diff_guide="
Run full diff per split:
  diff --recursive ${official_unzipped_dir}/base ${built_unzipped_dir}/base
  diff --recursive ${official_unzipped_dir}/arm64_v8a ${built_unzipped_dir}/arm64_v8a

Or use diffoscope on individual split APKs:
  diffoscope ${official_splits_dir}/base.apk ${built_splits_dir}/base.apk

Diff files saved in: ${comparison_dir}/"
fi

echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name_from_apk:-${version_name}}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit_hash}"
echo ""
echo "Diff (total non-META-INF differences across all splits: ${total_non_meta_diffs}):"
echo -e "${split_results}"
echo ""
echo "Revision, tag (and its signature):"

if git_in_container "git rev-parse --verify 'refs/tags/${git_ref}' >/dev/null 2>&1"; then
  if [[ "${tag_type}" == "annotated" ]]; then
    echo "${tag_output:-}"
  else
    echo "Tag: ${git_ref} (lightweight -- no GPG signature possible)"
  fi
else
  echo "No tag found for: ${git_ref} (build from commit ${commit_hash})"
fi

echo ""
echo "${commit_output:-}"
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
  echo "===== Also ====="
  echo -e "${additional_info}"
fi

echo ""
echo "Built base.apk sha256: ${built_base_hash}"
echo ""
echo "===== End Results ====="
echo "${diff_guide}"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
  log_info "Workspace cleaned up."
else
  log_info "Workspace preserved: ${work_dir}"
  log_info "Diff files: ${comparison_dir}/"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
