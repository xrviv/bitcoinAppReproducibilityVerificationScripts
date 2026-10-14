#!/bin/bash
# ==============================================================================
# airgapvault-v0.3.2_build.sh - AirGap Vault Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.2
# Organization:  WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-14
# Project:       https://github.com/airgap-it/airgap-vault
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/it.airgap.vault/changelog.md
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
# - Accepts official AirGap Vault APK via --apk or auto-downloads from GitHub
# - Clones the repository inside a container (no host git dependency)
# - Patches versionName in build.gradle, then runs docker build using the
#   project's own build/android/Dockerfile with BUILD_NR=<versionCode>
# - Extracts unsigned APK from the built image via docker create + docker cp
# - Compares built APK against official using unzip-based binary analysis
# - Generates COMPARISON_RESULTS.yaml and standardized verification summary

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.3.2"
APP_ID="it.airgap.vault"
REPO_URL="https://github.com/airgap-it/airgap-vault.git"
WS_CONTAINER="docker.io/walletscrutiny/android:5@sha256:eabd60543f19831feef6db22e9a1ada0ef469eef723119f1c96bd836198614c3"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd -P)"
script_name="$(basename "$0")"
# Self-identification first: tie the verdict to the exact script bytes.
script_sha256="$(sha256sum "$(readlink -f "$0")" 2>/dev/null | awk '{print $1}')"
printf '%s %s sha256:%s\n' "${script_name}" "${SCRIPT_VERSION}" "${script_sha256:-unknown}"
rm -f -- "${execution_dir}/COMPARISON_RESULTS.yaml"

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
sapling_verdict=""
sapling_notes=""

# Play artifact acceptance tracking
manifest_play_only="false"
res_diff_count=0
play_artifacts_present="false"
stamp_official_state="absent"
stamp_built_state="absent"

download_dir=""
work_dir=""
build_image_tag=""
build_container_name=""

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

generate_error_yaml() {
  local status="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  printf 'script_version: %s\nverdict: %s\n' "${SCRIPT_VERSION}" "${status}" > "${yaml_file}"
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

if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
  CONTAINER_RUN_USER_ARGS="--userns=keep-id -e HOME=/tmp"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  VOLUME_RW_SUFFIX=""
  CONTAINER_RUN_USER_ARGS="--user $(id -u):$(id -g) -e HOME=/tmp"
else
  die_invalid "No working podman or docker (both must answer 'info'). Install or start one."
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       airgapvault_build.sh - AirGap Vault reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk_file> [--version <version>] [OPTIONS]
       ${script_name} --version <version> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds AirGap Vault from source using the project's own Dockerfile
       (build/android/Dockerfile) and compares the built APK to an official APK.
       Also rebuilds the airgap-sapling JitPack dependency from source and
       verifies its .so files match (Leo's directive, GitLab #866).

       The official APK can be provided via --binary/--apk or auto-downloaded
       from GitHub releases when --version is given without --binary.

       When --binary is provided without --version, the version is detected
       automatically from the APK (ABS-compatible path).

OPTIONS
       --version <version>     Version to verify. Optional when --binary is
                               provided (auto-detected from APK). Required for
                               GitHub auto-download. Examples: 3.34.3, 3.34.4
       --binary <file>         Path to official APK (alias: --apk). When
                               provided without --version, version is detected
                               from the APK via aapt.
       --apk <file>            Alias for --binary.
       --arch <arch>           Architecture label (default: universal).
                               AirGap Vault produces universal APKs only.
       --type <type>           Build type (accepted for build server compat)
       --cleanup               Remove temporary files after completion
       --script-version        Print script version and exit
       --help                  Show this help and exit

EXIT CODES
       0    Reproducible (APK and sapling dependency both verified)
       1    Differences found, build failure, or sapling not verified
       2    Invalid parameters or configuration

EXAMPLES
       ${script_name} --binary ~/Downloads/airgap-vault.apk
       ${script_name} --version 3.34.4 --binary ~/Downloads/airgap-vault.apk
       ${script_name} --version 3.34.4
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) [[ -z "${2:-}" ]] && die_invalid "--version requires a value."; requested_version="$2"; shift ;;
    --apk|--binary) [[ -z "${2:-}" ]] && die_invalid "--binary/--apk requires a value."; downloaded_apk="$2"; shift ;;
    --arch) [[ -z "${2:-}" ]] && die_invalid "--arch requires a value."; requested_arch="$2"; shift ;;
    --type) [[ -z "${2:-}" ]] && die_invalid "--type requires a value."; requested_type="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Unknown argument: $1 (ignored)" ;;
  esac
  shift
done

# --version is required only when no --binary/--apk is given (auto-download path).
# When ABS passes --binary without --version, version is extracted from the APK below.
if [[ -z "${requested_version}" && -z "${downloaded_apk}" ]]; then
  die_invalid "You must provide --version (or --binary with an APK to detect version automatically)."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

# Validate architecture — AirGap Vault is universal only
if [[ -n "${requested_arch}" ]]; then
  case "${requested_arch}" in
    universal) ;;
    *) die_invalid "Unsupported --arch '${requested_arch}'. AirGap Vault produces universal APKs only (no native ABI splits). Supported: universal." ;;
  esac
  build_arch="${requested_arch}"
fi

if [[ -n "${requested_type}" ]]; then
  append_additional_info "Build type '${requested_type}' accepted for compatibility; AirGap Vault has a single build type (APK)."
fi

# version_name resolved after APK inspection when --version is omitted (ABS path)
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
    sh -c "sha256sum \"/data/${file_name}\" | awk '{print \$1}'"
}

container_signer() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apksigner verify --print-certs \"/apk/${apk_name}\" | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'"
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
    sh -c "aapt_bin=\$(command -v aapt || true); \
      if [ -z \"\$aapt_bin\" ] && [ -n \"\${ANDROID_HOME:-}\" ] && [ -d \"\$ANDROID_HOME/build-tools\" ]; then \
        aapt_bin=\$(ls -1 \"\$ANDROID_HOME\"/build-tools/*/aapt 2>/dev/null | sort -V | tail -n1); \
      fi; \
      if [ -z \"\$aapt_bin\" ]; then exit 0; fi; \
      \"\$aapt_bin\" dump badging \"/apk/${apk_name}\" 2>/dev/null | sed -n \"s/.*${field}='\\([^']*\\)'.*/\\1/p\" | head -n1"
}

container_aapt_package() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "aapt_bin=\$(command -v aapt || true); \
      if [ -z \"\$aapt_bin\" ] && [ -n \"\${ANDROID_HOME:-}\" ] && [ -d \"\$ANDROID_HOME/build-tools\" ]; then \
        aapt_bin=\$(ls -1 \"\$ANDROID_HOME\"/build-tools/*/aapt 2>/dev/null | sort -V | tail -n1); \
      fi; \
      if [ -z \"\$aapt_bin\" ]; then exit 0; fi; \
      \"\$aapt_bin\" dump badging \"/apk/${apk_name}\" 2>/dev/null \
        | grep '^package:' | sed \"s/^package: name='\\([^']*\\)'.*/\\1/\""
}

download_apk_from_url() {
  local url="$1"
  local output_file="$2"
  local output_dir
  output_dir="$(dirname "$output_file")"

  mkdir -p "$output_dir"
  $CONTAINER_CMD run --rm ${CONTAINER_RUN_USER_ARGS} \
    --volume "${output_dir}:/download${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "wget -q -O /download/$(basename "$output_file") '${url}'"   # no curl in the tools image
}

git_in_container() {
  local cmd="$1"
  $CONTAINER_CMD run --rm ${CONTAINER_RUN_USER_ARGS} \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "${cmd}"
}

generate_comparison_yaml() {
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${yaml_status}"
    echo "notes: |"
    echo "  Built with AirGap's build/android/Dockerfile (BUILD_NR=${version_code}; versionName set to"
    echo "  ${version_name} in build.gradle, as AirGap's CI does). Unzipped entries compared."
    echo "  Root META-INF signing files (*.SF, *.RSA, *.DSA, *.EC, MANIFEST.MF) excluded by file name only."
    [[ "${play_accept}" == "true" ]] && echo "  Google Play additions accepted: stamp-cert-sha256 and the com.android.vending.derived.apk.id manifest attribute; decoded res/ identical."
    echo "  Sapling dependency check: ${sapling_verdict:-not_run}${sapling_notes:+ — ${sapling_notes}}"
    true
  } > "${yaml_file}"
}

generate_diff_summary() {
  local summary_dir="${work_dir}/summary"
  local official_dir="${summary_dir}/official"
  local built_dir="${summary_dir}/built"

  rm -rf "${summary_dir}"
  mkdir -p "${summary_dir}"

  if ! ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_USER_ARGS} \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    --volume "${summary_dir}:/summary${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apktool d -f --frame-path /tmp/apktool-framework -o /summary/official /apk/$(basename "${downloaded_apk}")"; then
    append_additional_info "Diff summary: apktool decode failed for official APK."
    return 0
  fi

  if ! ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_USER_ARGS} \
    --volume "$(dirname "${built_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    --volume "${summary_dir}:/summary${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apktool d -f --frame-path /tmp/apktool-framework -o /summary/built /apk/$(basename "${built_apk}")"; then
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
# Sapling dependency verification (Leo's directive, GitLab #866)
# Rebuilds airgap-sapling from source and compares stripped .so hashes
# against the JitPack AAR cached inside the vault build image.
# ------------------------------------------------------------------------------
verify_sapling_dependency() {
  log_info "================================================================"
  log_info "  PHASE: Sapling Dependency Verification (airgap-sapling)"
  log_info "================================================================"

  # Detect sapling version from vault source
  local sapling_ver
  sapling_ver="$(grep 'def saplingVersion' "${work_dir}/app/android/app/build.gradle" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

  if [[ -z "${sapling_ver}" ]]; then
    log_warn "Sapling: could not detect version from build.gradle; skipping."
    sapling_verdict="skipped"
    sapling_notes="sapling: version not detected (skipped)"
    return 0
  fi
  log_info "Sapling version detected: ${sapling_ver}"

  # Find JitPack AAR in vault build image Gradle cache (scoped to detected version)
  local jitpack_aar_in_image
  # --user 0: from 3.35.0 the image ends with USER nobody, which cannot read /root/.gradle
  jitpack_aar_in_image="$(${CONTAINER_CMD} run --rm --user 0 "${build_image_tag}" \
    find /root/.gradle/caches/modules-2/files-2.1/com.github.airgap-it/airgap-sapling/"${sapling_ver}" \
    -name "*.aar" -type f 2>/dev/null | head -1 || true)"

  if [[ -z "${jitpack_aar_in_image}" ]]; then
    log_warn "Sapling: JitPack AAR not found in vault build image Gradle cache; skipping."
    sapling_verdict="skipped"
    sapling_notes="sapling ${sapling_ver}: JitPack AAR not cached in build image (skipped)"
    return 0
  fi
  log_info "JitPack AAR in image: ${jitpack_aar_in_image}"

  # Extract JitPack AAR to host via docker create + docker cp
  local sapling_extract_container="sapling-extract-$$"
  local jitpack_aar_host="${work_dir}/jitpack-sapling-${sapling_ver}.aar"
  ${CONTAINER_CMD} create --name "${sapling_extract_container}" "${build_image_tag}" echo done
  ${CONTAINER_CMD} cp "${sapling_extract_container}:${jitpack_aar_in_image}" "${jitpack_aar_host}"
  ${CONTAINER_CMD} rm "${sapling_extract_container}"

  local jitpack_hash
  jitpack_hash="$(sha256sum "${jitpack_aar_host}" | awk '{print $1}')"
  log_info "JitPack AAR SHA-256: ${jitpack_hash}"

  # Build sapling container with pinned NDK/CMake toolchain (matches JitPack build log)
  local sapling_image="airgap-sapling-build:${sapling_ver}_$$"
  local sapling_work="${work_dir}/sapling-build"
  mkdir -p "${sapling_work}"

  log_info "Building sapling verification container (NDK 21.1.6352462, CMake 3.10.2.4988404)..."
  cat > "${sapling_work}/Dockerfile" <<'__SAPLING_DF__'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
RUN apt-get update && apt-get install -y ca-certificates curl git unzip zip openjdk-11-jdk openjdk-17-jdk binutils && rm -rf /var/lib/apt/lists/*
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools && curl -fsSL -o /tmp/ct.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip && unzip -q /tmp/ct.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest && rm -f /tmp/ct.zip
ENV PATH=${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}
RUN yes | sdkmanager --sdk_root=${ANDROID_SDK_ROOT} --licenses && sdkmanager --sdk_root=${ANDROID_SDK_ROOT} "platform-tools" "platforms;android-29" "build-tools;29.0.3" "ndk;21.1.6352462" "cmake;3.10.2.4988404"
WORKDIR /work
__SAPLING_DF__

  ${CONTAINER_CMD} build -t "${sapling_image}" -f "${sapling_work}/Dockerfile" "${sapling_work}"

  # Write inner verification script (runs inside container)
  cat > "${sapling_work}/sapling-inner.sh" <<'__SAPLING_INNER__'
#!/usr/bin/env bash
set -euo pipefail
NDK_OC="/opt/android-sdk/ndk/21.1.6352462/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy"
JDK11="/usr/lib/jvm/java-11-openjdk-amd64"
echo "--- Cloning airgap-sapling ${SAPLING_VER}"
git clone --depth 1 --branch "${SAPLING_VER}" https://github.com/airgap-it/airgap-sapling.git /work/sapling
cd /work/sapling/packages/sapling-android
chmod +x gradlew
JAVA_HOME="${JDK11}" ./gradlew publishToMavenLocal
LOCAL_AAR="/root/.m2/repository/it/airgap/sapling/${SAPLING_VER}/sapling-${SAPLING_VER}.aar"
LOCAL_HASH=$(sha256sum "${LOCAL_AAR}" | awk '{print $1}')
echo "RESULT_LOCAL_HASH=${LOCAL_HASH}"
unzip -q /jitpack.aar -d /tmp/jp-aar
unzip -q "${LOCAL_AAR}" -d /tmp/lo-aar
ALL_MATCH=true
MATCHED_ABIS=0
EXPECTED_ABIS=4
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  jp="/tmp/jp-aar/jni/${abi}/libsapling.so"
  lo="/tmp/lo-aar/jni/${abi}/libsapling.so"
  if [ ! -f "${jp}" ] || [ ! -f "${lo}" ]; then
    echo "RESULT_MISSING_ABI=${abi}"
    ALL_MATCH=false
    continue
  fi
  MATCHED_ABIS=$((MATCHED_ABIS + 1))
  "${NDK_OC}" --remove-section=.note.gnu.build-id "${jp}" "/tmp/jp-${abi}.s"
  "${NDK_OC}" --remove-section=.note.gnu.build-id "${lo}" "/tmp/lo-${abi}.s"
  jp_h=$(sha256sum "/tmp/jp-${abi}.s" | awk '{print $1}')
  lo_h=$(sha256sum "/tmp/lo-${abi}.s" | awk '{print $1}')
  if [ "${jp_h}" != "${lo_h}" ]; then
    ALL_MATCH=false
    echo "RESULT_MISMATCH_ABI=${abi}"
  fi
done
echo "RESULT_MATCHED_ABIS=${MATCHED_ABIS}"
if [ "${MATCHED_ABIS}" -ne "${EXPECTED_ABIS}" ]; then
  ALL_MATCH=false
fi
${ALL_MATCH} && echo "RESULT_VERDICT=reproducible" || echo "RESULT_VERDICT=not_reproducible"
__SAPLING_INNER__

  local sapling_log="${work_dir}/sapling-build.log"
  log_info "Building airgap-sapling ${sapling_ver} from source (~8-10 min)..."
  log_info "Full sapling build log: ${sapling_log}"
  set +e
  ${CONTAINER_CMD} run --rm \
    -e "SAPLING_VER=${sapling_ver}" \
    --volume "${sapling_work}:/out${VOLUME_RO_SUFFIX}" \
    --volume "${jitpack_aar_host}:/jitpack.aar${VOLUME_RO_SUFFIX}" \
    "${sapling_image}" bash /out/sapling-inner.sh 2>&1 | tee "${sapling_log}"
  local sapling_container_exit="${PIPESTATUS[0]}"
  set -e
  if [[ "${sapling_container_exit}" -ne 0 ]]; then
    echo "RESULT_BUILD_FAILED=true" >> "${sapling_log}"
  fi

  ${CONTAINER_CMD} rmi "${sapling_image}" >/dev/null 2>&1 || true

  # Parse results from log file
  local local_hash sapling_result abi_mismatch missing_abis build_failed
  local_hash="$(grep '^RESULT_LOCAL_HASH=' "${sapling_log}" | cut -d= -f2 || true)"
  sapling_result="$(grep '^RESULT_VERDICT=' "${sapling_log}" | cut -d= -f2 || true)"
  abi_mismatch="$(grep '^RESULT_MISMATCH_ABI=' "${sapling_log}" | cut -d= -f2 | tr '\n' ',' | sed 's/,$//' || true)"
  missing_abis="$(grep '^RESULT_MISSING_ABI=' "${sapling_log}" | cut -d= -f2 | tr '\n' ',' | sed 's/,$//' || true)"
  build_failed="$(grep '^RESULT_BUILD_FAILED=' "${sapling_log}" | cut -d= -f2 || true)"

  log_info "Sapling JitPack hash: ${jitpack_hash}"
  log_info "Sapling local hash:   ${local_hash:-unknown}"
  log_info "Sapling result:       ${sapling_result:-unknown}"

  if [[ "${build_failed}" == "true" || -z "${sapling_result}" ]]; then
    log_warn "Sapling: source build failed or produced no result (see ${sapling_log})."
    sapling_verdict="build_failed"
    sapling_notes="sapling ${sapling_ver}: source build failed; JitPack hash ${jitpack_hash}"
    append_additional_info "WARNING: sapling ${sapling_ver} source build failed; dependency not independently verified."
    return 0
  fi

  if [[ -n "${missing_abis}" ]]; then
    append_additional_info "Sapling: missing .so files for ABI(s): ${missing_abis}."
  fi

  if [[ "${sapling_result}" == "reproducible" ]]; then
    sapling_verdict="reproducible"
    sapling_notes="sapling ${sapling_ver}: reproducible (Build-ID only diff, stripped .so match all 4 ABIs)"
  else
    sapling_verdict="not_reproducible"
    if [[ -n "${missing_abis}" && -z "${abi_mismatch}" ]]; then
      sapling_notes="sapling ${sapling_ver}: NOT reproducible (missing .so for ABI(s): ${missing_abis})"
      append_additional_info "WARNING: sapling ${sapling_ver} missing .so for ABI(s): ${missing_abis}."
    else
      sapling_notes="sapling ${sapling_ver}: NOT reproducible (stripped .so mismatch ABI: ${abi_mismatch:-unknown}${missing_abis:+; missing: ${missing_abis}})"
      append_additional_info "WARNING: sapling ${sapling_ver} dependency not independently reproducible. Mismatched ABIs: ${abi_mismatch:-unknown}."
    fi
  fi
  log_info "Sapling verdict: ${sapling_verdict}"
}

# ------------------------------------------------------------------------------
# Per-run workspace in the caller's directory, created before any work; the
# official download, sources, sapling check and diffs all live inside it.
# ------------------------------------------------------------------------------
if [[ -n "${downloaded_apk}" && "${downloaded_apk}" != /* ]]; then
  downloaded_apk="${execution_dir}/${downloaded_apk}"
fi
if [[ -n "${downloaded_apk}" && ! -f "${downloaded_apk}" ]]; then
  die_invalid "APK file not found: ${downloaded_apk}"
fi
run_id="$(date +%s)-$$"
work_dir="${execution_dir}/airgapvault_verification_${requested_version:-apk}_${run_id}"
mkdir -- "${work_dir}" || die_failed "Cannot create workspace ${work_dir}"
log_info "Workspace: ${work_dir}"

# EXIT: remove this run's containers and images (also after a failure), hand
# the workspace back to the caller, and record ftbfs if no YAML exists.
images_before=""
hand_back_workspace() {
  local rc=$?
  trap - ERR
  set +e
  [[ -n "${build_container_name}" ]] && ${CONTAINER_CMD} rm -f "${build_container_name}" >/dev/null 2>&1
  ${CONTAINER_CMD} rm -f "sapling-extract-$$" >/dev/null 2>&1
  [[ -n "${build_image_tag}" ]] && ${CONTAINER_CMD} rmi "${build_image_tag}" >/dev/null 2>&1
  if [[ "${CONTAINER_CMD}" == "podman" && -n "${images_before}" ]]; then
    local pass id   # untagged stage images this run created; in-use ones refuse removal
    for pass in 1 2 3; do
      for id in $(podman images -a --no-trunc --format '{{.ID}} {{.Repository}}' | awk '$2=="<none>"{print $1}'); do
        grep -qxF "${id}" <<< "${images_before}" || podman rmi "${id}" >/dev/null 2>&1
      done
    done
  fi
  if [[ -d "${work_dir}" ]]; then
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
      podman unshare chown -R 0:0 "${work_dir}" >/dev/null 2>&1
    else
      docker run --rm --volume "${work_dir}:/w" "${WS_CONTAINER}" chown -R "$(id -u):$(id -g)" /w >/dev/null 2>&1
    fi
    chmod -R u+rwX "${work_dir}" 2>/dev/null
    local foreign
    foreign="$(find "${work_dir}" ! -user "$(id -u)" 2>/dev/null | wc -l)"
    [[ "${foreign}" == 0 ]] || log_warn "${foreign} workspace entries not owned by you: ${work_dir}"
  fi
  [[ -f "${execution_dir}/COMPARISON_RESULTS.yaml" ]] || generate_error_yaml "ftbfs"
  exit "${rc}"
}
trap hand_back_workspace EXIT
trap 'log_error "Interrupted"; generate_error_yaml "ftbfs"; exit 130' INT TERM
if [[ "${CONTAINER_CMD}" == "podman" ]]; then
  images_before="$(podman images -a --no-trunc -q 2>/dev/null | sort -u || true)"
  [[ -n "${images_before}" ]] || images_before="none"
fi

# ------------------------------------------------------------------------------
# Input preparation
# ------------------------------------------------------------------------------
if [[ -n "${downloaded_apk}" ]]; then
  # --apk provided
  if [[ "${downloaded_apk}" != /* ]]; then
    downloaded_apk="${execution_dir}/${downloaded_apk}"
  fi
  if [[ ! -f "${downloaded_apk}" ]]; then
    die_invalid "APK file not found: ${downloaded_apk}"
  fi

  app_hash="$(container_sha256 "${downloaded_apk}")"
  signer="$(container_signer "${downloaded_apk}" || echo "unknown")"
  version_name_from_apk="$(container_aapt_version "${downloaded_apk}" "versionName")"
  version_code="$(container_aapt_version "${downloaded_apk}" "versionCode")"

  if [[ -z "${version_name_from_apk}" ]]; then
    version_name_from_apk="${version_name}"
  fi
  if [[ -z "${version_code}" ]]; then
    version_code="unknown"
  fi

  # ABS path: --version not supplied — derive from APK
  if [[ -z "${version_name}" ]]; then
    if [[ -z "${version_name_from_apk}" ]]; then
      die_invalid "Could not detect version from APK. Provide --version explicitly."
    fi
    version_name="${version_name_from_apk}"
    log_info "Version detected from APK: ${version_name}"
  elif [[ "${requested_version}" != "${version_name_from_apk}" ]]; then
    die_invalid "Version mismatch: --version ${requested_version} but APK reports ${version_name_from_apk}. Provide the correct APK or version."
  fi

else
  # No --apk: try GitHub releases
  # AirGap Vault release assets are named: airgap-vault-{versionCode}.apk
  # Since we don't know the versionCode yet, we list assets via GitHub API
  download_dir="${work_dir}/official"
  mkdir -p "${download_dir}"

  log_info "Querying GitHub releases for v${version_name} asset list..."
  asset_info="$($CONTAINER_CMD run --rm \
    --volume "${download_dir}:/download${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "wget -q -O - 'https://api.github.com/repos/airgap-it/airgap-vault/releases/tags/v${version_name}' \
      | grep -oE '\"browser_download_url\": \"[^\"]+airgap-vault-[^\"]+\\.apk\"' \
      | head -n 1 \
      | sed 's/\"browser_download_url\": \"//;s/\"$//'" || true)"

  if [[ -z "${asset_info}" ]]; then
    die_failed "Could not find GitHub release for v${version_name}. Provide the APK via --apk."
  fi

  # Extract filename from URL
  asset_filename="$(basename "${asset_info}")"
  downloaded_apk="${download_dir}/${asset_filename}"

  log_info "Downloading: ${asset_info}"
  if ! download_apk_from_url "${asset_info}" "${downloaded_apk}"; then
    die_failed "Failed to download APK from GitHub releases: ${asset_info}"
  fi
  log_info "Downloaded APK to: ${downloaded_apk}"

  app_hash="$(container_sha256 "${downloaded_apk}")"
  signer="$(container_signer "${downloaded_apk}" || echo "unknown")"
  version_name_from_apk="$(container_aapt_version "${downloaded_apk}" "versionName")"
  version_code="$(container_aapt_version "${downloaded_apk}" "versionCode")"

  if [[ -z "${version_name_from_apk}" ]]; then
    version_name_from_apk="${version_name}"
  fi
  if [[ -z "${version_code}" ]]; then
    version_code="unknown"
  fi
fi

if [[ "${version_code}" == "unknown" ]]; then
  die_failed "Could not determine versionCode from APK. AirGap Vault requires the correct versionCode (BUILD_NR) for reproducible builds."
fi

# Verify APK package name matches APP_ID before investing time in the build
apk_package="$(container_aapt_package "${downloaded_apk}")"
if [[ "${apk_package}" != "${APP_ID}" ]]; then
  die_invalid "APK package name mismatch: expected '${APP_ID}', got '${apk_package:-unknown}'. Provide the correct APK."
fi

log_info "Version: ${version_name}, VersionCode: ${version_code}"

# ------------------------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------------------------
# (per-run workspace created above, before any work)

# ------------------------------------------------------------------------------
# Source preparation (containerized git clone)
# ------------------------------------------------------------------------------
log_info "Cloning AirGap Vault repository in container..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone --depth 1 --branch 'v${version_name}' '${REPO_URL}' app"

commit_hash="$(git_in_container "git rev-parse HEAD")"
log_info "Checked out v${version_name} at commit ${commit_hash}"

# ------------------------------------------------------------------------------
# Patch versionName in build.gradle (BEFORE docker build)
# ------------------------------------------------------------------------------
# AirGap Vault hardcodes versionName "0.0.0" in android/app/build.gradle.
# The GitLab CI patches this via sed before running docker build.
# versionCode is handled inside the Dockerfile via BUILD_NR arg.
log_info "Patching versionName from \"0.0.0\" to \"${version_name}\" in build.gradle..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace/app \
  "$WS_CONTAINER" \
  sh -c "sed -i -e 's/versionName \"0.0.0\"/versionName \"${version_name}\"/g' android/app/build.gradle"

# Verify the patch was applied
patched_check="$($CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RO_SUFFIX}" \
  --workdir /workspace/app \
  "$WS_CONTAINER" \
  sh -c "grep 'versionName' android/app/build.gradle")"
log_info "build.gradle versionName after patch: ${patched_check}"

# ------------------------------------------------------------------------------
# Build Docker image from project's build/android/Dockerfile
# ------------------------------------------------------------------------------
# Podman requires fully-qualified image names; rewrite if needed
if [[ "${CONTAINER_CMD}" == "podman" ]]; then
  log_info "Podman detected; ensuring Dockerfile uses fully-qualified base image..."
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "sed -i -e 's|^FROM[[:space:]]\\+beevelop/|FROM docker.io/beevelop/|g' build/android/Dockerfile"
fi

build_image_tag="airgap-vault-build:v${version_name}_$$"
build_container_name="airgap-vault-extract_${version_name}_$$"

log_info "Building AirGap Vault Docker image from build/android/Dockerfile..."
log_info "Image tag: ${build_image_tag}"
log_info "BUILD_NR (versionCode): ${version_code}"
log_info "This may take 20-60 minutes depending on your system..."

$CONTAINER_CMD build \
  -t "${build_image_tag}" \
  -f "${work_dir}/app/build/android/Dockerfile" \
  --ulimit nofile=10000:10000 \
  --build-arg BUILD_NR="${version_code}" \
  "${work_dir}/app"

log_info "Docker image built successfully: ${build_image_tag}"

# ------------------------------------------------------------------------------
# Extract built APK from image
# ------------------------------------------------------------------------------
# The Dockerfile copies the unsigned APK to /app/android-release-unsigned.apk
built_apk_name="airgap-vault-v${version_name}-release-unsigned.apk"
built_apk="${work_dir}/${built_apk_name}"

log_info "Extracting built APK from Docker image..."
$CONTAINER_CMD create --name "${build_container_name}" "${build_image_tag}" echo "extract"
$CONTAINER_CMD cp "${build_container_name}:/app/android-release-unsigned.apk" "${built_apk}"
$CONTAINER_CMD rm "${build_container_name}"

if [[ ! -f "${built_apk}" ]]; then
  die_failed "Built APK not found after extraction: ${built_apk}"
fi

log_info "APK extracted successfully: ${built_apk}"

# ------------------------------------------------------------------------------
# Comparison
# ------------------------------------------------------------------------------
from_play_unzipped="${work_dir}/fromPlay_${APP_ID}_${version_code}"
from_build_unzipped="${work_dir}/fromBuild_${APP_ID}_${version_code}"
rm -rf "${from_play_unzipped}" "${from_build_unzipped}"
mkdir -p "${from_play_unzipped}" "${from_build_unzipped}"

log_info "Unzipping APKs for comparison..."
$CONTAINER_CMD run --rm ${CONTAINER_RUN_USER_ARGS} \
  --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
  --volume "${from_play_unzipped}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "unzip -qq \"/official/$(basename "${downloaded_apk}")\" -d /output"

$CONTAINER_CMD run --rm ${CONTAINER_RUN_USER_ARGS} \
  --volume "$(dirname "${built_apk}"):/built${VOLUME_RO_SUFFIX}" \
  --volume "${from_build_unzipped}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "unzip -qq \"/built/$(basename "${built_apk}")\" -d /output"

log_info "Diffing extracted APKs..."
diff_brief="$($CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "diff -qr '$(basename "${from_play_unzipped}")' '$(basename "${from_build_unzipped}")' || true")"

# Filter root META-INF SIGNING files only, by NAME (meta-inf-filter-scope.md,
# 2026-08-27). Never the META-INF/ directory as a whole: it also carries
# services/ bindings and library version markers, which are app payload.
# "Only in" is exempt only on the OFFICIAL side (our build is unsigned); a
# signing-named file only in OUR build means something signed it, and counts.
SIGN_NAME='[^/]*(\.(SF|RSA|DSA|EC)|MANIFEST\.MF)'
official_dir_re="$(basename "${from_play_unzipped}" | sed 's/[][\.^$*+?(){}|\/]/\\&/g')"
filtered_diff="$(echo "${diff_brief}" \
  | grep -vE "^Only in ${official_dir_re}/META-INF: ${SIGN_NAME}$" \
  | grep -vE "^Files [^/ ]+/META-INF/${SIGN_NAME} and " || true)"
# If our build has no META-INF/ at all, diff reports only the directory; drop
# that line only when everything in the official one is a root signing file.
if grep -qxF "Only in $(basename "${from_play_unzipped}"): META-INF" <<< "${filtered_diff}"; then
  meta_entries="$(cd "${from_play_unzipped}/META-INF" && find . -mindepth 1 | sed 's|^\./||')"
  if [[ -n "${meta_entries}" ]] && ! grep -qvE "^${SIGN_NAME}$" <<< "${meta_entries}"; then
    filtered_diff="$(grep -vxF "Only in $(basename "${from_play_unzipped}"): META-INF" <<< "${filtered_diff}" || true)"
  fi
fi
filtered_diff_compact="$(echo "${filtered_diff}" | tr -d '\n\r')"
if [[ -z "${diff_brief}" || -z "${filtered_diff_compact}" ]]; then
  diff_count=0
else
  diff_count="$(echo "${filtered_diff}" | grep -c '^' || true)"
fi

diff_display="$(echo "${diff_brief}" | sed "s|$(basename "${from_play_unzipped}")|${from_play_unzipped}|g; s|$(basename "${from_build_unzipped}")|${from_build_unzipped}|g")"

generate_diff_summary

# Verify sapling JitPack dependency from source (Leo's directive, GitLab #866)
verify_sapling_dependency

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

verdict=""
yaml_status="not_reproducible"
match_value="false"
exit_code="${EXIT_FAILED}"

if [[ "${diff_count}" -eq 0 ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
elif [[ "${play_accept}" == "true" ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
  append_additional_info "Play-only diffs accepted by default; verdict set to reproducible."
else
  verdict="not_reproducible"
fi

# Sapling result gates the final verdict (Leo's directive, GitLab #866)
if [[ "${verdict}" == "reproducible" ]]; then
  case "${sapling_verdict}" in
    not_reproducible)
      verdict="not_reproducible"
      yaml_status="not_reproducible"
      exit_code="${EXIT_FAILED}"
      ;;
    build_failed|skipped|"")
      verdict="ftbfs"
      yaml_status="ftbfs"
      exit_code="${EXIT_FAILED}"
      ;;
  esac
fi

built_hash="$(container_sha256 "${built_apk}")"

# ------------------------------------------------------------------------------
# Results files
# ------------------------------------------------------------------------------
generate_comparison_yaml

# ------------------------------------------------------------------------------
# Git signature verification (containerized)
# ------------------------------------------------------------------------------
tag_type="commit-only"
tag_signature_status="[INFO] No tag found"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""
tag_ref="v${version_name}"

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
for more details."

if [[ "${should_cleanup}" == true ]]; then
  diff_guide=""
fi

echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name_from_apk}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit_hash}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${script_sha256:-unknown}"
echo "saplingVerdict: ${sapling_verdict:-not_run}"
echo "saplingNotes:   ${sapling_notes:-}"
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
# (build image, containers and this run's untagged images are removed in the EXIT trap)

if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
else
  log_info "Workspace preserved: ${work_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
