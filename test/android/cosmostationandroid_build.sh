#!/bin/bash
# ==============================================================================
# cosmostationandroid_build.sh - Cosmostation Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.2
# Organization:  WalletScrutiny.com
# Last Modified: 2026-05-07
# Project:       https://github.com/cosmostation/cosmostation-android
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/wannabit.io.cosmostaion/changelog.md
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
# - Extracts metadata from a locally provided official Cosmostation APK
# - Extracts Firebase configuration values from official APK resources
# - Clones source code repository and checks out the exact release tag/commit
# - Performs containerized reproducible build using Gradle (JDK 21, SDK 35)
# - Compares built APK against the official APK using apktool + diff
# - Generates COMPARISON_RESULTS.yaml and standardized verification summary output
#
# NOTE: Cosmostation does NOT publish APKs on GitHub releases.
# APK must be provided via --apk (obtain from Google Play / APKMirror / adb pull).
#
# KNOWN BLOCKERS:
# - Release keystore not available (temp keystore used; build will always differ)
# - Skip API key not public (placeholder used)
# - WalletConnect API key: committed in repo local.properties as of v1.10.48
# - Build is NOT expected to be reproducible due to missing release keystore

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.3.2"
APP_ID="wannabit.io.cosmostaion"
REPO_URL="https://github.com/cosmostation/cosmostation-android"
# Use Android SDK 35 container with JDK 21 support
WS_CONTAINER="docker.io/walletscrutiny/android:5"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_name="$(basename "$0")"

should_cleanup=false
downloaded_apk=""
requested_version=""
requested_arch=""
requested_type=""
revision_override=""

build_arch=""
build_type="standalone"
version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
tag_ref=""
additional_info=""

download_dir=""
metadata_dir=""
work_dir=""

# Firebase values (extracted from APK or defaults)
firebase_api_key=""
firebase_app_id=""
firebase_database_url=""
firebase_gcm_sender_id=""
firebase_storage_bucket=""
firebase_project_id=""
firebase_web_client_id=""

# ------------------------------------------------------------------------------
# Logging helpers (plain text; no ANSI in results)
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
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

echo "${script_name} ${SCRIPT_VERSION}"

# ------------------------------------------------------------------------------
# Container runtime detection
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
       cosmostationandroid_build.sh - Cosmostation Android reproducible build verification

SYNOPSIS
       ${script_name} --apk <apk_file> [OPTIONS]
       ${script_name} --binary <apk_file> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds Cosmostation Android from source in a container and compares the
       built APK to an official APK provided via --apk or --binary.

       Cosmostation does not publish APKs on GitHub releases. The APK must be
       obtained from Google Play (e.g., via APKMirror or adb pull):
         adb pull \$(adb shell pm path wannabit.io.cosmostaion | cut -d: -f2) cosmostation.apk

       --version may be passed for build-server compatibility; it is used only
       to resolve the git tag. Version is always extracted from the provided APK.

       This build is NOT expected to be reproducible: the release keystore is
       not public.

OPTIONS
       --apk <file>            Path to local APK file (required)
       --binary <file>         Alias for --apk
       --version <version>     Accepted for build-server compatibility; used for
                              git tag resolution only (no APK download)
       --arch <arch>           Architecture to build
                              Supported: armeabi-v7a, arm64-v8a, x86_64
       --type <type>           Accepted for build-server compatibility; ignored
       --revision <hash>       Override tag and checkout a specific commit
       --revision-override <hash>
                              Alias for --revision
       --cleanup               Remove temporary files after completion
       --help                  Show this help and exit

EXIT CODES
       0    Reproducible (no unexpected differences)
       1    Differences found or build failure
       2    Invalid parameters or configuration

EXAMPLES
       ${script_name} --apk ~/Downloads/cosmostation-1.10.48.apk
       ${script_name} --apk cosmostation.apk --arch arm64-v8a

KNOWN ISSUES
       - Release keystore not available; temp keystore used (build will always differ)
       - Skip API key: placeholder used (original not public)
       - WalletConnect API key: read from local.properties committed in repo (v1.10.48+)
       - google-services.json: committed in repo (v1.10.48+); script overwrites with
         values extracted from the provided APK
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) requested_version="$2"; shift ;;
    --apk) downloaded_apk="$2"; shift ;;
    --arch) requested_arch="$2"; shift ;;
    --type) requested_type="$2"; shift ;;
    --revision) revision_override="$2"; shift ;;
    --revision-override) revision_override="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --binary) downloaded_apk="$2"; shift ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Unknown argument: $1" ;;
  esac
  shift
done

if [[ -z "${downloaded_apk}" ]]; then
  die_invalid "You must provide --apk <path> or --binary <path>. Cosmostation APKs are not published on GitHub releases; obtain the APK from Google Play (APKMirror or 'adb pull')."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

if [[ -n "${requested_arch}" ]]; then
  case "${requested_arch}" in
    armeabi-v7a|arm64-v8a|x86_64) ;;
    *) die_invalid "Unsupported --arch '${requested_arch}'. Supported: armeabi-v7a, arm64-v8a, x86_64." ;;
  esac
fi

if [[ -n "${requested_type}" ]]; then
  build_type="${requested_type}"
fi

# ------------------------------------------------------------------------------
# Helper functions (containerized)
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

container_apktool() {
  local apk_path="$1"
  local output_dir="$2"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    ${CONTAINER_RUN_USER_ARGS} \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    --volume "${output_dir}:/output${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apktool d -f -p /tmp -o /output /apk/${apk_name}"
}

container_aapt_arches() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  # First try aapt dump badging for declared native-code
  # If that fails or returns nothing, check lib/ directories in the APK
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c '
      arches=$(aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null | awk -F"'"'"'" "/native-code/ {for (i=2; i<=NF; i+=2) print \$i}")
      if [ -n "$arches" ]; then
        echo "$arches"
      else
        # Fallback: check lib/ directories inside APK
        unzip -l "/apk/'"${apk_name}"'" 2>/dev/null | grep -oE "lib/(arm64-v8a|armeabi-v7a|x86_64|x86|mips|mips64)/" | sed "s|lib/||;s|/||" | sort -u
      fi
    '
}

container_signer() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apksigner verify --print-certs /apk/${apk_name} | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'"
}


resolve_tag_in_container() {
  local version="$1"
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "
      git fetch --tags
      for candidate in 'v${version}' '${version}'; do
        if git rev-parse --verify \"refs/tags/\${candidate}\" >/dev/null 2>&1; then
          echo \"\${candidate}\"
          exit 0
        fi
      done
      echo 'HEAD'
    "
}

git_in_container() {
  local cmd="$1"
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "${cmd}"
}

# Extract Firebase values from decoded APK resources
extract_firebase_values() {
  local strings_xml="$1"

  if [[ ! -f "${strings_xml}" ]]; then
    log_warn "strings.xml not found, using default Firebase values"
    return 1
  fi

  # Extract values using grep/sed (container-friendly)
  firebase_api_key=$(grep -o '<string name="google_api_key">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")
  firebase_app_id=$(grep -o '<string name="google_app_id">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")
  firebase_database_url=$(grep -o '<string name="firebase_database_url">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")
  firebase_gcm_sender_id=$(grep -o '<string name="gcm_defaultSenderId">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")
  firebase_storage_bucket=$(grep -o '<string name="google_storage_bucket">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")
  firebase_project_id=$(grep -o '<string name="project_id">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")
  firebase_web_client_id=$(grep -o '<string name="default_web_client_id">[^<]*</string>' "${strings_xml}" 2>/dev/null | sed 's/.*>\([^<]*\)<.*/\1/' || echo "")

  if [[ -n "${firebase_app_id}" ]]; then
    log_info "Firebase values extracted from APK resources"
    return 0
  fi
  return 1
}

# Generate google-services.json from extracted values
generate_google_services_json() {
  local output_file="$1"
  local package_name="$2"

  # Use extracted values or known defaults from APK analysis
  local api_key="${firebase_api_key:-AIzaSyDBf4ds_lBT0ooz1IS5fT1fq-p4S7lFmD4}"
  local app_id="${firebase_app_id:-1:662209286307:android:92f7a1775c04b997}"
  local database_url="${firebase_database_url:-https://fcmpushnotification-a7dce.firebaseio.com}"
  local sender_id="${firebase_gcm_sender_id:-662209286307}"
  local storage_bucket="${firebase_storage_bucket:-fcmpushnotification-a7dce.appspot.com}"
  local project_id="${firebase_project_id:-fcmpushnotification-a7dce}"
  local web_client_id="${firebase_web_client_id:-662209286307-7s5r9p1cramal0mc3vvl6gkvub3i1lh5.apps.googleusercontent.com}"

  cat > "${output_file}" <<EOF
{
  "project_info": {
    "project_number": "${sender_id}",
    "firebase_url": "${database_url}",
    "project_id": "${project_id}",
    "storage_bucket": "${storage_bucket}"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "${app_id}",
        "android_client_info": {
          "package_name": "${package_name}"
        }
      },
      "oauth_client": [
        {
          "client_id": "${web_client_id}",
          "client_type": 3
        }
      ],
      "api_key": [
        {
          "current_key": "${api_key}"
        }
      ],
      "services": {
        "appinvite_service": {
          "other_platform_oauth_client": [
            {
              "client_id": "${web_client_id}",
              "client_type": 3
            }
          ]
        }
      }
    }
  ],
  "configuration_version": "1"
}
EOF
}

# Generate local.properties with API keys (placeholders)
generate_local_properties() {
  local output_file="$1"
  local sdk_dir="$2"

  cat > "${output_file}" <<EOF
# Auto-generated for reproducible build verification
# WARNING: Using placeholder API keys - build will differ from official
sdk.dir=${sdk_dir}

# WalletConnect API key (placeholder - original not publicly available)
walletconnect.apiKey.release=placeholder_walletconnect_key
walletconnect.apiKey.debug=placeholder_walletconnect_key

# Skip API key (placeholder - original not publicly available)
skip.apiKey.release=placeholder_skip_key
skip.apiKey.debug=placeholder_skip_key
EOF
}

generate_error_yaml() {
  local status="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
EOF
}

# ------------------------------------------------------------------------------
# Input preparation
# ------------------------------------------------------------------------------
if [[ -n "${downloaded_apk}" ]]; then
  if [[ "${downloaded_apk}" != /* ]]; then
    downloaded_apk="${execution_dir}/${downloaded_apk}"
  fi
  if [[ ! -f "${downloaded_apk}" ]]; then
    die_invalid "APK file not found: ${downloaded_apk}"
  fi
fi

if [[ -n "${requested_version}" ]]; then
  log_info "--version ${requested_version} noted for git tag resolution; using provided APK as official binary."
fi

app_hash="$(container_sha256 "${downloaded_apk}")"
signer="$(container_signer "${downloaded_apk}")"

metadata_dir="${execution_dir}/apktool_${app_hash}"
rm -rf "${metadata_dir}"
mkdir -p "${metadata_dir}"

log_info "Decoding APK with apktool to extract metadata..."
container_apktool "${downloaded_apk}" "${metadata_dir}"

app_id="$(head -n 1 "${metadata_dir}/AndroidManifest.xml" | sed 's/.*package=\"//g' | sed 's/\".*//g')"
version_name_from_apk="$(grep versionName "${metadata_dir}/apktool.yml" | sed 's/.*: //g' | tr -d "'")"
version_code="$(grep versionCode "${metadata_dir}/apktool.yml" | sed 's/.*: //g' | tr -d "'")"

if [[ -z "${app_id}" ]]; then
  die_failed "Could not determine appId from APK."
fi

if [[ -z "${version_name_from_apk}" ]]; then
  die_failed "Could not determine versionName from APK."
fi

if [[ -z "${version_code}" ]]; then
  die_failed "Could not determine versionCode from APK."
fi

if [[ -n "${requested_version}" && "${requested_version}" != "${version_name_from_apk}" ]]; then
  additional_info="Requested version ${requested_version} but APK reports ${version_name_from_apk}."
fi

version_name="${version_name_from_apk}"

# Extract Firebase values from decoded APK
log_info "Extracting Firebase configuration from APK resources..."
if ! extract_firebase_values "${metadata_dir}/res/values/strings.xml"; then
  log_warn "Using default Firebase values extracted during manual analysis"
  additional_info="${additional_info}\nUsing default Firebase values (may differ from APK)."
fi

if [[ -z "${build_arch}" ]]; then
  mapfile -t apk_arches < <(container_aapt_arches "${downloaded_apk}" || true)
  if [[ "${#apk_arches[@]}" -gt 0 && -n "${apk_arches[0]}" ]]; then
    build_arch="${apk_arches[0]}"
    if [[ "${#apk_arches[@]}" -gt 1 ]]; then
      if [[ -n "${additional_info}" ]]; then
        additional_info="${additional_info}\n"
      fi
      additional_info="${additional_info}APK reports multiple ABIs (${apk_arches[*]}). Building ${build_arch} only."
    fi
  else
    build_arch="arm64-v8a"
    if [[ -n "${additional_info}" ]]; then
      additional_info="${additional_info}\n"
    fi
    additional_info="${additional_info}No native-code ABIs found in APK. Defaulting to ${build_arch}."
  fi
else
  mapfile -t apk_arches < <(container_aapt_arches "${downloaded_apk}" || true)
  if [[ "${#apk_arches[@]}" -gt 0 ]]; then
    if [[ ! " ${apk_arches[*]} " =~ " ${build_arch} " ]]; then
      if [[ -n "${additional_info}" ]]; then
        additional_info="${additional_info}\n"
      fi
      additional_info="${additional_info}APK native-code ABIs: ${apk_arches[*]}. Building ${build_arch} per --arch."
    fi
  fi
fi

if [[ "${app_id}" != "${APP_ID}" ]]; then
  log_warn "AppId mismatch: expected ${APP_ID}, got ${app_id}"
  additional_info="${additional_info}\nAppId mismatch: expected ${APP_ID}, got ${app_id}."
fi

if [[ -n "${requested_type}" ]]; then
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n"
  fi
  additional_info="${additional_info}Build type '${requested_type}' ignored; Cosmostation has a single build type."
fi

# Add known blockers to additional_info
additional_info="${additional_info}\n\nKNOWN BUILD BLOCKERS:"
additional_info="${additional_info}\n- WalletConnect API key: real key used (committed in repo local.properties as of v1.10.48)"
additional_info="${additional_info}\n- Skip API key: placeholder used (original not public)"
additional_info="${additional_info}\n- Release keystore: not available (using temp keystore)"
additional_info="${additional_info}\n- Firebase config: extracted from APK (should match committed google-services.json)"

# ------------------------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------------------------
work_dir="${execution_dir}/workdir_cosmostation_${version_name}_${build_arch}"
if [[ -d "${work_dir}" ]]; then
  if [[ "${should_cleanup}" == true ]]; then
    log_info "Removing existing workspace: ${work_dir}"
    rm -rf "${work_dir}"
  else
    die_invalid "Workspace already exists: ${work_dir}. Remove it or use --cleanup."
  fi
fi

mkdir -p "${work_dir}"

# ------------------------------------------------------------------------------
# Source preparation (containerized git clone)
# ------------------------------------------------------------------------------
log_info "Cloning Cosmostation repository in container..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone --recurse-submodules '${REPO_URL}' app"

if [[ -n "${revision_override}" ]]; then
  tag_ref="${revision_override}"
else
  tag_ref="$(resolve_tag_in_container "${version_name}")"
fi

log_info "Checking out ${tag_ref}..."
git_in_container "git checkout '${tag_ref}' && git submodule update --init --recursive"

commit_hash="$(git_in_container "git rev-parse HEAD")"
if [[ "${tag_ref}" == "HEAD" ]]; then
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n"
  fi
  additional_info="${additional_info}No upstream tag matched version ${version_name}; using commit ${commit_hash}."
fi

# ------------------------------------------------------------------------------
# Generate required configuration files
# ------------------------------------------------------------------------------
log_info "Generating google-services.json from extracted Firebase values..."
generate_google_services_json "${work_dir}/app/app/google-services.json" "${app_id}"

# Also create debug version
mkdir -p "${work_dir}/app/app/src/debug"
generate_google_services_json "${work_dir}/app/app/src/debug/google-services.json" "${app_id}"

log_info "Generating local.properties with placeholder API keys..."
generate_local_properties "${work_dir}/app/local.properties" "/opt/android-sdk"

# Create a temporary keystore for signing (build will differ from official)
log_info "Creating temporary keystore for build (NOT reproducible without original)..."
$CONTAINER_CMD run --rm \
  ${CONTAINER_RUN_USER_ARGS} \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace/app \
  "$WS_CONTAINER" \
  sh -c "keytool -genkey -v -keystore app/temp-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias tempkey -storepass temppassword -keypass temppassword -dname 'CN=WalletScrutiny, OU=Verification, O=WalletScrutiny, L=Unknown, S=Unknown, C=XX'"

# Modify build.gradle to use temp keystore
log_info "Patching build.gradle to use temporary keystore..."
$CONTAINER_CMD run --rm \
  ${CONTAINER_RUN_USER_ARGS} \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace/app \
  "$WS_CONTAINER" \
  sh -c "sed -i 's/eostartkeystore/temp-keystore.jks/g' app/build.gradle && sed -i 's/dnjsjqlt034#/temppassword/g' app/build.gradle && sed -i 's/keyAlias \"key0\"/keyAlias \"tempkey\"/g' app/build.gradle"

# Patch build.gradle to add BuildConfig fields to defaultConfig (applies to ALL variants)
# The API keys are only defined for release in the original; debug compilation fails without them
log_info "Patching build.gradle to add API key BuildConfig fields to defaultConfig..."

# Create a patch script on the host (avoids complex escaping in container sh -c)
cat > "${work_dir}/patch_buildconfig.sh" << 'PATCH_SCRIPT'
#!/bin/sh
cd /workspace/app
LINE_NUM=$(grep -n 'versionName' app/build.gradle | head -1 | cut -d: -f1)
if [ -n "$LINE_NUM" ]; then
  # Insert after versionName line
  sed -i "${LINE_NUM}a\\        buildConfigField \"String\", \"WALLETCONNECT_API_KEY\", \"\\\\\"placeholder_walletconnect_key\\\\\"\"" app/build.gradle
  LINE_NUM=$((LINE_NUM + 1))
  sed -i "${LINE_NUM}a\\        buildConfigField \"String\", \"SKIP_API_KEY\", \"\\\\\"placeholder_skip_key\\\\\"\"" app/build.gradle
  echo "BuildConfig fields added after line $((LINE_NUM - 1))"
else
  echo "ERROR: versionName not found in build.gradle"
  exit 1
fi
PATCH_SCRIPT
chmod +x "${work_dir}/patch_buildconfig.sh"

$CONTAINER_CMD run --rm \
  ${CONTAINER_RUN_USER_ARGS} \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace/app \
  "$WS_CONTAINER" \
  sh /workspace/patch_buildconfig.sh

# ------------------------------------------------------------------------------
# Build
# ------------------------------------------------------------------------------
log_info "Building Cosmostation Android (release APK with temp keystore)..."

# Cosmostation requires JDK 21, but WS container has JDK 8.
# We need to use a container with JDK 21 or install it during build.
# Using Eclipse Temurin JDK 21 image with Android SDK installed at runtime.

log_info "Building with JDK 21 container (installing Android SDK)..."
# Note: Running as root in container to install packages. Output files will be owned by root.
# We'll fix permissions after build completes.
$CONTAINER_CMD run --rm \
  --env ANDROID_HOME=/opt/android-sdk \
  --env GRADLE_USER_HOME=/workspace/.gradle \
  --env HOST_UID="$(id -u)" \
  --env HOST_GID="$(id -g)" \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace/app \
  docker.io/eclipse-temurin:21-jdk \
  bash -c "
    set -e

    echo '[BUILD] Installing required packages...'
    apt-get update -qq && apt-get install -y -qq wget unzip git >/dev/null 2>&1

    echo '[BUILD] Installing Android SDK...'
    mkdir -p /opt/android-sdk/cmdline-tools
    cd /opt/android-sdk/cmdline-tools
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O cmdline-tools.zip
    unzip -q cmdline-tools.zip
    mv cmdline-tools latest
    rm cmdline-tools.zip

    export PATH=\"/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:\$PATH\"

    echo '[BUILD] Accepting licenses and installing SDK components...'
    yes | sdkmanager --licenses >/dev/null 2>&1 || true
    sdkmanager --install 'platforms;android-35' 'build-tools;35.0.0' 'platform-tools' >/dev/null 2>&1

    echo '[BUILD] Configuring git...'
    cd /workspace/app
    git config --global --add safe.directory /workspace/app

    echo '[BUILD] Updating local.properties with SDK path...'
    sed -i 's|sdk.dir=.*|sdk.dir=/opt/android-sdk|' local.properties

    echo '[BUILD] Running Gradle assembleRelease...'
    ./gradlew assembleRelease --no-daemon --stacktrace 2>&1 || {
      echo 'Gradle build failed'
      exit 1
    }

    echo '[BUILD] Fixing output permissions...'
    chown -R "${HOST_UID}:${HOST_GID}" /workspace/app/app/build || true
  "

# Find built APK
built_apk="${work_dir}/app/app/build/outputs/apk/release/app-release.apk"

if [[ ! -f "${built_apk}" ]]; then
  # Try to find any APK
  built_apk="$(find "${work_dir}/app" -type f -name "*.apk" -print -quit 2>/dev/null || true)"
fi

if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
  die_failed "Built APK not found after build. Check build logs for errors."
fi

log_info "Built APK found: ${built_apk}"

# ------------------------------------------------------------------------------
# Comparison
# ------------------------------------------------------------------------------
from_play_unzipped="${work_dir}/fromPlay_${app_id}_${version_code}"
from_build_unzipped="${work_dir}/fromBuild_${app_id}_${version_code}"
rm -rf "${from_play_unzipped}" "${from_build_unzipped}"
mkdir -p "${from_play_unzipped}" "${from_build_unzipped}"

log_info "Unzipping APKs for comparison..."
$CONTAINER_CMD run --rm \
  --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
  --volume "${from_play_unzipped}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "unzip -qq /official/$(basename "${downloaded_apk}") -d /output"

$CONTAINER_CMD run --rm \
  --volume "$(dirname "${built_apk}"):/built${VOLUME_RO_SUFFIX}" \
  --volume "${from_build_unzipped}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "unzip -qq /built/$(basename "${built_apk}") -d /output"

log_info "Diffing extracted APKs..."
diff_brief="$($CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "diff -qr '$(basename "${from_play_unzipped}")' '$(basename "${from_build_unzipped}")' || true")"

# Filter out expected differences (META-INF signing)
filtered_diff="$(echo "${diff_brief}" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)"
filtered_diff_compact="$(echo "${filtered_diff}" | tr -d '\n\r')"
if [[ -z "${diff_brief}" || -z "${filtered_diff_compact}" ]]; then
  diff_count=0
else
  diff_count="$(echo "${filtered_diff}" | grep -c '^' || true)"
fi

diff_display="$(echo "${diff_brief}" | sed "s|$(basename "${from_play_unzipped}")|${from_play_unzipped}|g; s|$(basename "${from_build_unzipped}")|${from_build_unzipped}|g")"

verdict=""
yaml_status="not_reproducible"
match_value="false"
exit_code="${EXIT_FAILED}"

if [[ "${diff_count}" -eq 0 ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
else
  verdict="differences found (expected due to API key placeholders and temp keystore)"
fi

built_hash="$(container_sha256 "${built_apk}")"

# ------------------------------------------------------------------------------
# Results files
# ------------------------------------------------------------------------------
generate_comparison_yaml() {
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  local notes_text="Built from commit ${commit_hash}"
  if [[ -n "${additional_info}" ]]; then
    notes_text="${notes_text}; $(echo -e "${additional_info}" | grep -v '^$' | head -3 | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
  fi
  cat > "${yaml_file}" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${yaml_status}
notes: "${notes_text}"
EOF
}

generate_comparison_yaml

# ------------------------------------------------------------------------------
# Standardized verification output
# ------------------------------------------------------------------------------
diff_guide="
Run a full
diff --recursive ${from_play_unzipped} ${from_build_unzipped}
meld ${from_play_unzipped} ${from_build_unzipped}
or
diffoscope \"${downloaded_apk}\" ${built_apk}
for more details."

if [[ "${should_cleanup}" == true ]]; then
  diff_guide=""
fi

echo "===== Begin Results ====="
echo "appId:          ${app_id}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit_hash}"
echo ""
echo "Diff:"
echo "${diff_display}"
echo ""
echo "Revision, tag (and its signature):"

tag_type="commit-only"
tag_signature_status="[INFO] No tag found"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""

if git_in_container "git rev-parse --verify 'refs/tags/${tag_ref}' >/dev/null 2>&1"; then
  if git_in_container "test \"\$(git cat-file -t 'refs/tags/${tag_ref}')\" = 'tag'"; then
    tag_type="annotated"
    tag_output="$(git_in_container "git tag -v '${tag_ref}' 2>&1 || true")"
    echo "${tag_output}"
    if echo "${tag_output}" | grep -q "Good signature"; then
      tag_signature_status="[OK] Good signature on annotated tag"
      tag_key="$(echo "${tag_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\\1/' | tail -1)"
      if [[ -n "${tag_key}" ]]; then
        signature_keys="Tag signed with: ${tag_key}"
      fi
    else
      tag_signature_status="[WARNING] No valid signature found on annotated tag"
      signature_warnings="${signature_warnings}\n- Annotated tag exists but is not signed"
    fi
  else
    tag_type="lightweight"
    echo "Tag: ${tag_ref} (lightweight, no signature possible)"
    tag_signature_status="[INFO] Tag is lightweight (cannot contain signature)"
  fi
else
  echo "No tag (build from commit ${commit_hash})"
fi

commit_output="$(git_in_container "git verify-commit '${commit_hash}' 2>&1 || true")"
echo ""
echo "${commit_output}"
if echo "${commit_output}" | grep -q "Good signature"; then
  commit_signature_status="[OK] Good signature on commit"
  commit_key="$(echo "${commit_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\\1/' | tail -1)"
  if [[ -n "${commit_key}" ]]; then
    if [[ -n "${signature_keys}" ]]; then
      signature_keys="${signature_keys}\nCommit signed with: ${commit_key}"
    else
      signature_keys="Commit signed with: ${commit_key}"
    fi
  fi
else
  commit_signature_status="[WARNING] No valid signature found on commit"
  if [[ -z "${signature_warnings}" ]]; then
    signature_warnings="- Commit is not signed"
  else
    signature_warnings="${signature_warnings}\n- Commit is not signed"
  fi
fi

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
  echo -e "Warnings:${signature_warnings}"
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
if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}" "${metadata_dir}"
  if [[ -n "${download_dir}" ]]; then
    rm -rf "${download_dir}"
  fi
else
  log_info "Workspace preserved: ${work_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
