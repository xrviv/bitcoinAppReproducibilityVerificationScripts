#!/bin/bash
# ==============================================================================
# greenandroid_build.sh - Blockstream Green Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.2
# Organization:  WalletScrutiny.com
# Last Modified: 2026-06-04
# Project:       https://github.com/Blockstream/green_android
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.greenaddress.greenbits_android_wallet/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding the security,
# functionality, or fitness for any particular purpose. Users assume all risks.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws. The developers assume no liability for any misuse.
#
# SCRIPT SUMMARY:
# Phase 1 — GDK from source:
#   - Clones GDK at the tag pinned in green_android's gdk/fetch_android_binaries.sh
#   - Builds GDK Docker image from GDK's own docker/android/Dockerfile
#     (NDK r26b, Debian Bullseye, JDK 11, Rust 1.81; compiles all C deps)
#   - Builds GDK for armeabi-v7a + arm64-v8a inside that image
#   - Downloads official GDK tarball, verifies SHA256
#   - Compares built .so + Java wrapper files vs official → gdk_verdict
# Phase 2 — Green from source (using Phase 1 GDK):
#   - Clones green_android at the release tag
#   - Places Phase 1 .so files into gdk/src/main/jniLibs/ (Gradle skips auto-download)
#   - Builds Green Docker image from contrib/Dockerfile
#   - Runs ./gradlew useBlockstreamKeys assembleProductionGoogleRelease
#   - Compares built APK vs official → apk_verdict
# Output:
#   - Both verdicts reported separately (per-artifact model)
#   - COMPARISON_RESULTS.yaml verdict reflects APK comparison
#   - GDK build time warning: Phase 1 Docker image alone takes 2+ hours

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.2.2"
APP_ID="com.greenaddress.greenbits_android_wallet"
REPO_URL="https://github.com/Blockstream/green_android.git"
GDK_REPO_URL="https://github.com/Blockstream/gdk.git"
WS_CONTAINER="docker.io/walletscrutiny/android:5"

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

build_arch="universal"
version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
additional_info=""

# GDK from-source build state
gdk_tag=""
gdk_sha256_official=""
gdk_tarball_url=""
gdk_image_tag=""
gdk_verdict="unknown"
gdk_diff_output=""
gdk_has_diffs=false

# Play artifact acceptance tracking
manifest_play_only="false"
res_diff_count=0
play_artifacts_present="false"
stamp_official_state="absent"
stamp_built_state="absent"

work_dir=""
build_image_tag=""
build_flavor=""
gradle_task=""
apk_is_fdroid=false

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

append_additional_info() {
  local line="$1"
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n${line}"
  else
    additional_info="${line}"
  fi
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
  die_invalid "Neither podman nor docker is available. Install one to continue."
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       greenandroid_build.sh ${SCRIPT_VERSION} - Blockstream Green reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk_file> [OPTIONS]
       ${script_name} --apk <apk_file> [OPTIONS]
       ${script_name} --apk <apk_file> --version <version> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds GDK from source using the GDK project's own Docker build environment,
       then builds Blockstream Green using that from-source GDK and Green's upstream
       contrib/Dockerfile. Compares built APK to the official APK.

       Two verdicts are reported:
         gdk_verdict  - built GDK .so files vs official pre-built tarball
         apk_verdict  - built APK vs official APK (COMPARISON_RESULTS.yaml verdict)

       WARNING: Phase 1 (GDK Docker image build) compiles all C dependencies from
       source (openssl, boost, tor, libwally-core, Rust) for 4 ABIs. This alone
       takes 2+ hours on a modern machine. Total script runtime: 3-5+ hours.

OPTIONS
       --version <version>     Override version (optional). If omitted, auto-detected
                               from the APK. Must match APK if both are provided.
                               Examples: 5.2.0, 5.1.4
       --apk <file>            Path to official APK (required).
       --binary <file>         Alias for --apk for build-server compatibility.
       --arch <arch>            Architecture label for YAML output
                               (default: universal)
       --type <type>           Build type (accepted for build server compat)
       --cleanup               Remove temporary files after completion
       --script-version        Print script version and exit
       --help                  Show this help and exit

EXIT CODES
       0    Reproducible (only META-INF / Play distribution differences)
       1    Differences found or build failure
       2    Invalid parameters or configuration

EXAMPLES
       ${script_name} --binary ~/Downloads/com.greenaddress.greenbits_android_wallet_v5.2.0.apk
       ${script_name} --apk ~/Downloads/green_5.2.0.apk --version 5.2.0
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) requested_version="$2"; shift ;;
    --apk) downloaded_apk="$2"; shift ;;
    --binary) downloaded_apk="$2"; shift ;;
    --arch) requested_arch="$2"; shift ;;
    --type) requested_type="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

if [[ -z "${downloaded_apk}" ]]; then
  die_invalid "You must provide --binary or --apk with the path to the official APK."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

log_info "Starting ${script_name} script version ${SCRIPT_VERSION}"

if [[ -n "${requested_arch}" ]]; then
  build_arch="${requested_arch}"
fi

if [[ -n "${requested_type}" ]]; then
  append_additional_info "Build type '${requested_type}' accepted for compatibility; Green has a single build type (APK)."
fi

version_name="${requested_version}"

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

container_apk_id() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "
      result=\$({ aapt dump badging /apk/${apk_name} 2>/dev/null || aapt2 dump badging /apk/${apk_name} 2>/dev/null; } | grep '^package:' | sed \"s/.*name='\\([^']*\\)'.*/\\1/\" | head -1 || true)
      if [ -n \"\$result\" ]; then echo \"\$result\"; exit 0; fi
      tmpdir=\$(mktemp -d)
      if apktool d -f -s -o \"\$tmpdir/out\" /apk/${apk_name} >/dev/null 2>&1; then
        grep -o 'package=\"[^\"]*\"' \"\$tmpdir/out/AndroidManifest.xml\" | head -1 | sed 's/package=\"//;s/\"//'
      fi
      rm -rf \"\$tmpdir\"
    "
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

git_in_container() {
  local cmd="$1"
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "${cmd}"
}

generate_error_yaml() {
  local status="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
EOF
}

generate_comparison_yaml() {
  local yaml_verdict="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  cat > "${yaml_file}" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${yaml_verdict}
notes: |
  GDK source build: ${gdk_tag}
  GDK binary verdict: ${gdk_verdict}
  Green APK flavor: ${build_flavor}
  Green APK verdict: ${yaml_verdict}
  Green APK built using GDK compiled from source via GDK's docker/android/Dockerfile.
  Expected APK differences (do not affect reproducibility verdict):
  - META-INF/*: APK signing files
  - AndroidManifest.xml: com.android.vending.derived.apk.id injected by Google Play
  - stamp-cert-sha256: Certificate stamp from Google Play
EOF
}

generate_diff_summary() {
  local summary_dir="${work_dir}/summary"
  local official_dir="${summary_dir}/official"
  local built_dir="${summary_dir}/built"

  rm -rf "${summary_dir}"
  mkdir -p "${summary_dir}"

  if ! ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    --volume "${summary_dir}:/summary${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apktool d -f -o /summary/official /apk/$(basename "${downloaded_apk}")"; then
    append_additional_info "Diff summary: apktool decode failed for official APK."
    return 0
  fi

  if ! ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${built_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    --volume "${summary_dir}:/summary${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apktool d -f -o /summary/built /apk/$(basename "${built_apk}")"; then
    append_additional_info "Diff summary: apktool decode failed for built APK."
    return 0
  fi

  local manifest_diff manifest_changes
  local manifest_lines=0
  local manifest_snip

  manifest_diff="$(diff -u "${official_dir}/AndroidManifest.xml" "${built_dir}/AndroidManifest.xml" || true)"
  manifest_changes="$(echo "${manifest_diff}" | grep -E '^[+-]' | grep -vE '^\+\+\+|^---|^@@' || true)"
  if [[ -z "${manifest_changes}" ]]; then
    manifest_play_only="true"
  elif echo "${manifest_changes}" | grep -v "com.android.vending.derived.apk.id" >/dev/null 2>&1; then
    manifest_play_only="false"
  else
    manifest_play_only="true"
  fi
  if [[ -n "${manifest_changes}" ]]; then
    manifest_lines="$(echo "${manifest_changes}" | wc -l | tr -d ' ')"
  fi

  append_additional_info "Manifest diff lines: ${manifest_lines}"
  if [[ -n "${manifest_diff}" ]]; then
    manifest_snip="$(echo "${manifest_diff}" | grep -E '^[+-]' | grep -vE '^\+\+\+|^---|^@@' | head -n 3)"
    if [[ -n "${manifest_snip}" ]]; then
      append_additional_info "Manifest diff sample:"
      append_additional_info "${manifest_snip}"
    fi
  fi

  local res_diff res_lines=0
  res_diff="$(diff -r "${official_dir}/res" "${built_dir}/res" || true)"
  if [[ -n "${res_diff}" ]]; then
    res_lines="$(echo "${res_diff}" | wc -l | tr -d ' ')"
  fi

  res_diff_count=${res_lines}
  append_additional_info "Resource diffs (res/): ${res_lines}"
  if [[ -n "${res_diff}" ]]; then
    local res_snip
    res_snip="$(echo "${res_diff}" | head -n 5)"
    append_additional_info "Resource diff sample:"
    append_additional_info "${res_snip}"
  fi

  # Check for stamp-cert-sha256
  local stamp_official="" stamp_built=""
  stamp_official_state="absent"
  stamp_built_state="absent"

  stamp_official="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "zipinfo -1 /apk/$(basename "${downloaded_apk}") | grep -E '^stamp-cert-sha256$' || true")"

  stamp_built="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${built_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "zipinfo -1 /apk/$(basename "${built_apk}") | grep -E '^stamp-cert-sha256$' || true")"

  if [[ -n "${stamp_official}" ]]; then
    stamp_official_state="present"
  fi
  if [[ -n "${stamp_built}" ]]; then
    stamp_built_state="present"
  fi

  append_additional_info "stamp-cert-sha256: official ${stamp_official_state}, built ${stamp_built_state}"

  if [[ "${stamp_official_state}" == "present" ]]; then
    local stamp_hex_lines stamp_b64 stamp_len
    stamp_len="$(${CONTAINER_CMD} run --rm \
      --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
      "${WS_CONTAINER}" \
      sh -c "unzip -p /apk/$(basename "${downloaded_apk}") stamp-cert-sha256 2>/dev/null | wc -c | tr -d ' '")"

    stamp_hex_lines="$(${CONTAINER_CMD} run --rm \
      --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
      "${WS_CONTAINER}" \
      sh -c "unzip -p /apk/$(basename "${downloaded_apk}") stamp-cert-sha256 2>/dev/null | od -An -tx1 -w16 -v | head -n 5")"

    stamp_b64="$(${CONTAINER_CMD} run --rm \
      --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
      "${WS_CONTAINER}" \
      sh -c "unzip -p /apk/$(basename "${downloaded_apk}") stamp-cert-sha256 2>/dev/null | base64 -w 64 | head -n 1")"

    append_additional_info "stamp-cert-sha256 bytes: ${stamp_len}"
    if [[ -n "${stamp_hex_lines}" ]]; then
      append_additional_info "stamp-cert-sha256 hex (up to 5 lines):"
      while IFS= read -r line; do
        append_additional_info "${line}"
      done <<< "${stamp_hex_lines}"
    fi
    if [[ -n "${stamp_b64}" ]]; then
      append_additional_info "stamp-cert-sha256 base64 (first line): ${stamp_b64}"
    fi
  fi

  # Detect Play artifacts
  local play_sig=""
  play_sig="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "zipinfo -1 /apk/$(basename "${downloaded_apk}") | grep -E '^META-INF/GOOGPLAY\\.' || true")"

  if [[ -n "${play_sig}" || "${stamp_official_state}" == "present" ]]; then
    play_artifacts_present="true"
    append_additional_info "Note: Google Play distribution artifacts detected (GOOGPLAY.* / stamp-cert-sha256)."
  else
    play_artifacts_present="false"
  fi
}


# ------------------------------------------------------------------------------
# Input preparation
# ------------------------------------------------------------------------------
if [[ "${downloaded_apk}" != /* ]]; then
  downloaded_apk="${execution_dir}/${downloaded_apk}"
fi
if [[ ! -f "${downloaded_apk}" ]]; then
  die_invalid "APK file not found: ${downloaded_apk}"
fi

app_hash="$(container_sha256 "${downloaded_apk}")"
signer="$(container_signer "${downloaded_apk}" || echo "unknown")"
apk_package_id="$(container_apk_id "${downloaded_apk}")"
version_name_from_apk="$(container_aapt_version "${downloaded_apk}" "versionName")"
version_code="$(container_aapt_version "${downloaded_apk}" "versionCode")"

if [[ -z "${apk_package_id}" ]]; then
  die_invalid "Could not read package name from APK. File may be corrupt or unsupported."
fi
if [[ "${apk_package_id}" != "${APP_ID}" ]]; then
  die_invalid "APK package '${apk_package_id}' does not match expected '${APP_ID}'."
fi

if [[ -z "${version_name_from_apk}" ]]; then
  version_name_from_apk="${version_name}"
fi
if [[ -z "${version_code}" ]]; then
  version_code="unknown"
fi

if [[ -z "${version_name}" ]]; then
  if [[ -z "${version_name_from_apk}" ]]; then
    die_invalid "Could not detect version from APK. Pass --version explicitly."
  fi
  version_name="${version_name_from_apk}"
  log_info "Version auto-detected from APK: ${version_name}"
  append_additional_info "Version auto-detected from APK: ${version_name}"
elif [[ -n "${version_name_from_apk}" && "${requested_version}" != "${version_name_from_apk}" ]]; then
  die_invalid "--version ${requested_version} does not match APK version ${version_name_from_apk}."
fi

# Detect build flavor from signer certificate.
# Blockstream's Play Store signing key is stable and distinct from F-Droid's key.
# Unsigned APKs (empty signer) are GitHub/Play releases — use productionGoogle.
BLOCKSTREAM_PLAY_SIGNER="32f9cc00b13fbeace51e2fb51df482044e42ad34a9bd912f179fedb16a42970e"
signer_normalized="$(echo "${signer}" | tr '[:upper:]' '[:lower:]' | tr -d ':')"
log_info "APK signer (raw):        ${signer:-none}"
log_info "APK signer (normalized): ${signer_normalized:-none}"
log_info "Expected Play signer:    ${BLOCKSTREAM_PLAY_SIGNER}"

if [[ "${signer_normalized}" == "${BLOCKSTREAM_PLAY_SIGNER}" || -z "${signer_normalized}" || "${signer}" == "unknown" ]]; then
  apk_is_fdroid=false
  build_flavor="productionGoogle"
  gradle_task="assembleProductionGoogleRelease"
  log_info "Build flavor: Google Play (productionGoogle) — signer: ${signer:-unsigned}"
  append_additional_info "APK flavor: Google Play"
else
  apk_is_fdroid=true
  build_flavor="productionFDroid"
  gradle_task="assembleProductionFDroidRelease"
  log_info "Build flavor: F-Droid (productionFDroid) — signer: ${signer}"
  append_additional_info "APK flavor: F-Droid (signer does not match Blockstream Play key)"
fi

# ------------------------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------------------------
work_dir="${execution_dir}/workdir_${APP_ID}_${version_name}_${build_arch}"
if [[ -d "${work_dir}" ]]; then
  log_info "Removing existing workspace: ${work_dir}"
  rm -rf "${work_dir}"
fi

mkdir -p "${work_dir}"

# ------------------------------------------------------------------------------
# Phase 1a: Clone green_android (needed to read GDK tag)
# ------------------------------------------------------------------------------
log_info "Cloning Blockstream Green repository in container..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone --depth 1 --branch 'release_${version_name}' '${REPO_URL}' app"

commit_hash="$(git_in_container "git rev-parse HEAD")"
log_info "Checked out release_${version_name} at commit ${commit_hash}"

# ------------------------------------------------------------------------------
# Phase 1b: Read GDK tag and SHA256 from green_android repo
# ------------------------------------------------------------------------------
gdk_fetch_script="${work_dir}/app/gdk/fetch_android_binaries.sh"
if [[ ! -f "${gdk_fetch_script}" ]]; then
  die_failed "Could not find gdk/fetch_android_binaries.sh in cloned repo"
fi

gdk_tag="$(grep '^TAGNAME=' "${gdk_fetch_script}" | cut -d'"' -f2)"
gdk_sha256_official="$(grep '^SHA256=' "${gdk_fetch_script}" | cut -d'"' -f2)"

if [[ -z "${gdk_tag}" || -z "${gdk_sha256_official}" ]]; then
  die_failed "Could not parse GDK TAGNAME or SHA256 from gdk/fetch_android_binaries.sh"
fi

gdk_tarball_name="gdk-${gdk_tag}"
gdk_tarball_url="https://github.com/Blockstream/gdk/releases/download/${gdk_tag}/${gdk_tarball_name}.tar.gz"
log_info "GDK tag: ${gdk_tag} | Official SHA256: ${gdk_sha256_official}"

# ------------------------------------------------------------------------------
# Phase 1c: Clone GDK repository
# ------------------------------------------------------------------------------
gdk_src_dir="${work_dir}/gdk_source"
mkdir -p "${gdk_src_dir}"

log_info "Cloning GDK repository at ${gdk_tag}..."
$CONTAINER_CMD run --rm \
  --volume "${gdk_src_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone --depth 1 --branch '${gdk_tag}' '${GDK_REPO_URL}' src"

# Dockerfile COPY requires downloads/ to exist even if empty
mkdir -p "${gdk_src_dir}/src/downloads"

# Qualify all short image names so Podman works without unqualified-search registries
sed -i \
  -e 's|^FROM debian:|FROM docker.io/library/debian:|g' \
  -e 's|^FROM rust:|FROM docker.io/library/rust:|g' \
  "${gdk_src_dir}/src/docker/android/Dockerfile"
log_info "GDK Dockerfile image names qualified for Podman compatibility"

# ------------------------------------------------------------------------------
# Phase 1d: Build GDK Docker image
# ------------------------------------------------------------------------------
gdk_image_tag="gdk_android_builder_${version_name}_$$"
log_info "Building GDK Docker image from docker/android/Dockerfile..."
log_info "WARNING: This compiles openssl, boost, tor, libwally, Rust for 4 ABIs."
log_info "WARNING: Expected build time: 2+ hours. Do not interrupt."

if [[ "${CONTAINER_CMD}" == "docker" ]]; then
  DOCKER_BUILDKIT=1 $CONTAINER_CMD build \
    -t "${gdk_image_tag}" \
    -f "${gdk_src_dir}/src/docker/android/Dockerfile" \
    "${gdk_src_dir}/src/"
else
  $CONTAINER_CMD build \
    -t "${gdk_image_tag}" \
    -f "${gdk_src_dir}/src/docker/android/Dockerfile" \
    "${gdk_src_dir}/src/"
fi

log_info "GDK Docker image built: ${gdk_image_tag}"

# ------------------------------------------------------------------------------
# Phase 1e: Build GDK from source for armeabi-v7a and arm64-v8a
# ------------------------------------------------------------------------------
gdk_built_dir="${work_dir}/gdk_built"
mkdir -p "${gdk_built_dir}/armeabi-v7a" "${gdk_built_dir}/arm64-v8a"

for abi in armeabi-v7a arm64-v8a; do
  log_info "Building GDK from source for ${abi}..."
  $CONTAINER_CMD run --rm \
    --volume "${gdk_src_dir}/src:/root/gdk${VOLUME_RW_SUFFIX}" \
    --volume "${gdk_built_dir}/${abi}:/output${VOLUME_RW_SUFFIX}" \
    "${gdk_image_tag}" \
    bash -c "./tools/build.sh --install /output --ndk ${abi}"
  log_info "GDK build complete for ${abi}"
done

# ------------------------------------------------------------------------------
# Phase 1f: Download and verify official GDK tarball
# ------------------------------------------------------------------------------
gdk_official_dir="${work_dir}/gdk_official"
mkdir -p "${gdk_official_dir}"

log_info "Downloading official GDK tarball: ${gdk_tarball_url}"
$CONTAINER_CMD run --rm \
  --volume "${gdk_official_dir}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "curl -L -f -o /output/gdk.tar.gz '${gdk_tarball_url}'"

log_info "Verifying official GDK SHA256: ${gdk_sha256_official}"
$CONTAINER_CMD run --rm \
  --volume "${gdk_official_dir}:/output${VOLUME_RO_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "echo '${gdk_sha256_official}  /output/gdk.tar.gz' | sha256sum --check"

$CONTAINER_CMD run --rm \
  --volume "${gdk_official_dir}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "cd /output && tar xzf gdk.tar.gz && rm gdk.tar.gz"

log_info "Official GDK extracted to: ${gdk_official_dir}/${gdk_tarball_name}/"

# ------------------------------------------------------------------------------
# Phase 1g: Compare official vs from-source GDK binaries
# ------------------------------------------------------------------------------
log_info "Comparing official GDK binaries vs from-source build..."
gdk_diff_lines=""

for abi in armeabi-v7a arm64-v8a; do
  official_lib="${gdk_official_dir}/${gdk_tarball_name}/lib/${abi}"
  built_lib="${gdk_built_dir}/${abi}/lib/${abi}"

  if [[ ! -d "${official_lib}" ]]; then
    gdk_diff_lines="${gdk_diff_lines}[WARN] Official lib dir missing for ${abi}\n"
    gdk_has_diffs=true
    continue
  fi
  if [[ ! -d "${built_lib}" ]]; then
    gdk_diff_lines="${gdk_diff_lines}[WARN] Built lib dir missing for ${abi}\n"
    gdk_has_diffs=true
    continue
  fi

  abi_diff="$($CONTAINER_CMD run --rm \
    --volume "${gdk_official_dir}:/official${VOLUME_RO_SUFFIX}" \
    --volume "${gdk_built_dir}:/built${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "diff -r '/official/${gdk_tarball_name}/lib/${abi}' '/built/${abi}/lib/${abi}' || true")"

  if [[ -n "${abi_diff}" ]]; then
    gdk_has_diffs=true
    gdk_diff_lines="${gdk_diff_lines}--- GDK .so diff for ${abi}:\n${abi_diff}\n"
  else
    gdk_diff_lines="${gdk_diff_lines}GDK .so for ${abi}: identical\n"
  fi
done

# Compare Java wrapper files (ABI-independent; use arm64-v8a build)
for java_file in \
  "share/java/com/blockstream/green_gdk/GDK.java" \
  "share/java/com/blockstream/libwally/Wally.java"; do

  official_java="${gdk_official_dir}/${gdk_tarball_name}/${java_file}"
  built_java="${gdk_built_dir}/arm64-v8a/${java_file}"
  filename="$(basename "${java_file}")"

  if [[ ! -f "${official_java}" || ! -f "${built_java}" ]]; then
    gdk_diff_lines="${gdk_diff_lines}[WARN] Could not compare ${filename} (file missing)\n"
    gdk_has_diffs=true
    continue
  fi

  java_diff="$(diff "${official_java}" "${built_java}" || true)"
  if [[ -n "${java_diff}" ]]; then
    gdk_has_diffs=true
    gdk_diff_lines="${gdk_diff_lines}--- Java wrapper diff (${filename}):\n${java_diff}\n"
  else
    gdk_diff_lines="${gdk_diff_lines}${filename}: identical\n"
  fi
done

if [[ "${gdk_has_diffs}" == "false" ]]; then
  gdk_verdict="reproducible"
else
  gdk_verdict="not_reproducible"
fi

log_info "GDK binary verdict: ${gdk_verdict}"
append_additional_info "GDK tag: ${gdk_tag}"
append_additional_info "GDK official SHA256 (tarball): ${gdk_sha256_official}"
append_additional_info "GDK binary verdict: ${gdk_verdict}"
if [[ -n "${gdk_diff_lines}" ]]; then
  append_additional_info "GDK diff details:"
  while IFS= read -r dline; do
    append_additional_info "  ${dline}"
  done < <(printf '%b' "${gdk_diff_lines}")
fi

# Save full GDK diff to file
gdk_diff_file="${execution_dir}/diff_gdk_binaries.txt"
printf '%b' "${gdk_diff_lines}" > "${gdk_diff_file}"
log_info "Full GDK diff written to: ${gdk_diff_file}"

# ------------------------------------------------------------------------------
# Phase 1h: Place from-source GDK into green_android tree
# ------------------------------------------------------------------------------
log_info "Placing from-source GDK into green_android tree..."
jni_libs_dir="${work_dir}/app/gdk/src/main/jniLibs"
java_dest_dir="${work_dir}/app/gdk/src/main/java/com/blockstream"
mkdir -p "${java_dest_dir}/green_gdk" "${java_dest_dir}/libwally"

for abi in armeabi-v7a arm64-v8a; do
  mkdir -p "${jni_libs_dir}/${abi}"
  $CONTAINER_CMD run --rm \
    --volume "${gdk_built_dir}/${abi}/lib/${abi}:/src${VOLUME_RO_SUFFIX}" \
    --volume "${jni_libs_dir}/${abi}:/dest${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "cp /src/*.so /dest/"
  log_info "Placed ${abi} .so files from source build"
done

# Copy Java wrappers from arm64-v8a build (identical across ABIs)
$CONTAINER_CMD run --rm \
  --volume "${gdk_built_dir}/arm64-v8a/share/java/com/blockstream:/src${VOLUME_RO_SUFFIX}" \
  --volume "${java_dest_dir}:/dest${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "cp /src/green_gdk/GDK.java /dest/green_gdk/GDK.java && cp /src/libwally/Wally.java /dest/libwally/Wally.java"

log_info "From-source GDK placed in green_android tree. Gradle will skip fetchAndroidBinaries."

# ------------------------------------------------------------------------------
# Phase 2a: Build Green Docker image from contrib/Dockerfile
# ------------------------------------------------------------------------------
build_image_tag="green_builder_${version_name}_$$"
log_info "Building Blockstream Green Docker image from contrib/Dockerfile..."
log_info "Image tag: ${build_image_tag}"

$CONTAINER_CMD build \
  -t "${build_image_tag}" \
  -f "${work_dir}/app/contrib/Dockerfile" \
  "${work_dir}/app/contrib/"

log_info "Green Docker image built: ${build_image_tag}"

# ------------------------------------------------------------------------------
# Phase 2b: Build Green APK using from-source GDK
# ------------------------------------------------------------------------------
log_info "Building Blockstream Green APK (${gradle_task}) with from-source GDK..."
log_info "This may take 15-40 minutes..."

green_build_cmd="set -e; cd /ga; ./gradlew useBlockstreamKeys"
if [[ "${apk_is_fdroid}" == "true" ]]; then
  green_build_cmd="${green_build_cmd}; ./prepare_fdroid.sh"
fi
green_build_cmd="${green_build_cmd}; ./gradlew -x test ${gradle_task}"

$CONTAINER_CMD run --rm \
  --entrypoint /bin/bash \
  --volume "${work_dir}/app:/ga${VOLUME_RW_SUFFIX}" \
  -e HOME=/tmp \
  -e GRADLE_USER_HOME=/tmp/.gradle \
  -e ANDROID_PREFS_ROOT=/tmp \
  "${build_image_tag}" \
  -c "${green_build_cmd}"

# Find built APK
built_apk_name="BlockstreamGreen-v${version_name}-${build_flavor}-release-unsigned.apk"
built_apk="${work_dir}/app/androidApp/build/outputs/apk/${build_flavor}/release/${built_apk_name}"

if [[ ! -f "${built_apk}" ]]; then
  log_warn "Expected APK not found at: ${built_apk}"
  log_info "Searching for built APKs..."
  found_apk="$(find "${work_dir}/app" -type f -name "*.apk" -path "*/${build_flavor}/release/*" -print -quit 2>/dev/null || true)"
  if [[ -n "${found_apk}" && -f "${found_apk}" ]]; then
    built_apk="${found_apk}"
    built_apk_name="$(basename "${built_apk}")"
    log_info "Found APK at: ${built_apk}"
  else
    die_failed "Built APK not found. Check build output above for errors."
  fi
fi

log_info "APK built successfully: ${built_apk}"

# ------------------------------------------------------------------------------
# Phase 2c: Compare built APK vs official
# ------------------------------------------------------------------------------
from_play_unzipped="${work_dir}/fromPlay_${APP_ID}_${version_code}"
from_build_unzipped="${work_dir}/fromBuild_${APP_ID}_${version_code}"
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

# Filter META-INF differences (Leo's regex)
filtered_diff="$(echo "${diff_brief}" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)"
filtered_diff_compact="$(echo "${filtered_diff}" | tr -d '\n\r')"
if [[ -z "${diff_brief}" || -z "${filtered_diff_compact}" ]]; then
  diff_count=0
else
  diff_count="$(echo "${filtered_diff}" | grep -c '^' || true)"
fi

diff_display="$(echo "${diff_brief}" | sed "s|$(basename "${from_play_unzipped}")|${from_play_unzipped}|g; s|$(basename "${from_build_unzipped}")|${from_build_unzipped}|g")"

generate_diff_summary

play_accept=false
if [[ "${play_artifacts_present}" == "true" && "${manifest_play_only}" == "true" && "${res_diff_count}" -eq 0 ]]; then
  allowed_play=true
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if echo "${line}" | grep -q "AndroidManifest.xml"; then
      continue
    fi
    if echo "${line}" | grep -q "stamp-cert-sha256"; then
      continue
    fi
    allowed_play=false
    break
  done <<< "${filtered_diff}"
  if [[ "${allowed_play}" == "true" ]]; then
    play_accept=true
  fi
fi

apk_verdict=""
yaml_status="not_reproducible"
match_value="false"
exit_code="${EXIT_FAILED}"

if [[ "${diff_count}" -eq 0 ]]; then
  apk_verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
elif [[ "${play_accept}" == "true" ]]; then
  apk_verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
  append_additional_info "Play-only diffs accepted; APK verdict set to reproducible."
else
  apk_verdict="differences found"
fi

built_hash="$(container_sha256 "${built_apk}")"

# ------------------------------------------------------------------------------
# Results files
# ------------------------------------------------------------------------------
generate_comparison_yaml "${yaml_status}"

# ------------------------------------------------------------------------------
# Git signature verification (containerized)
# ------------------------------------------------------------------------------
tag_type="commit-only"
tag_signature_status="[INFO] No tag found"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""
tag_ref="release_${version_name}"

if git_in_container "git rev-parse --verify 'refs/tags/${tag_ref}' >/dev/null 2>&1"; then
  if git_in_container "test \"\$(git cat-file -t 'refs/tags/${tag_ref}')\" = 'tag'"; then
    tag_type="annotated"
    tag_output="$(git_in_container "git tag -v '${tag_ref}' 2>&1 || true")"
    if echo "${tag_output}" | grep -q "Good signature"; then
      tag_signature_status="[OK] Good signature on annotated tag"
      tag_key="$(echo "${tag_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
      if [[ -n "${tag_key}" ]]; then
        signature_keys="Tag signed with: ${tag_key}"
      fi
    else
      tag_signature_status="[WARNING] No valid signature found on annotated tag"
      signature_warnings="${signature_warnings}\n- Annotated tag exists but is not signed"
    fi
  else
    tag_type="lightweight"
    tag_signature_status="[INFO] Tag is lightweight (cannot contain signature)"
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
  commit_signature_status="[WARNING] No valid signature found on commit"
  if [[ -z "${signature_warnings}" ]]; then
    signature_warnings="- Commit is not signed"
  else
    signature_warnings="${signature_warnings}\n- Commit is not signed"
  fi
fi

# ------------------------------------------------------------------------------
# Standardized verification output
# ------------------------------------------------------------------------------
diff_guide="
Run a full
diff --recursive ${from_play_unzipped} ${from_build_unzipped}
meld ${from_play_unzipped} ${from_build_unzipped}
or
diffoscope \"${downloaded_apk}\" ${built_apk}
for more details.
GDK binary diff: ${gdk_diff_file}"

if [[ "${should_cleanup}" == true ]]; then
  diff_guide=""
fi

echo "===== Begin Results ====="
echo "appId:             ${APP_ID}"
echo "signer:            ${signer}"
echo "apkVersionName:    ${version_name_from_apk}"
echo "apkVersionCode:    ${version_code}"
echo "gdkTag:            ${gdk_tag}"
echo "gdkBinaryVerdict:  ${gdk_verdict}"
echo "apkFlavor:         ${build_flavor}"
echo "apkVerdict:        ${apk_verdict}"
echo "appHash:           ${app_hash}"
echo "commit:            ${commit_hash}"
echo ""
echo "Diff:"
echo "${diff_display}"
echo ""
echo "Revision, tag (and its signature):"

if git_in_container "git rev-parse --verify 'refs/tags/${tag_ref}' >/dev/null 2>&1"; then
  if [[ "${tag_type}" == "annotated" ]]; then
    echo "${tag_output}"
  else
    echo "Tag: ${tag_ref} (lightweight, no signature possible)"
  fi
else
  echo "No tag (build from commit ${commit_hash})"
fi

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
  echo "Warnings:${signature_warnings}"
fi

if [[ -n "${additional_info}" ]]; then
  echo ""
  echo "===== Also ====="
  echo -e "${additional_info}"
fi

echo ""
echo "===== End Results ====="
echo "${diff_guide}"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
if $CONTAINER_CMD rmi "${gdk_image_tag}" >/dev/null 2>&1; then
  log_info "Removed GDK build image: ${gdk_image_tag}"
fi
if $CONTAINER_CMD rmi "${build_image_tag}" >/dev/null 2>&1; then
  log_info "Removed Green build image: ${build_image_tag}"
fi

if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
else
  log_info "Workspace preserved: ${work_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
