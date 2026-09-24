#!/bin/bash
# ==============================================================================
# edge_build.sh - Edge Wallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.4
# Organization:  WalletScrutiny.com
# Last Modified: 2026-09-24
# Project:       https://github.com/EdgeApp/edge-react-gui
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/co.edgesecure.app/changelog.md
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
# - Official artifact via --binary: a single APK OR a directory of Play splits (base.apk +
#   split_config.*.apk). A single APK carrying ONE ABI under lib/ is Edge's per-ABI APK
#   (gradlew assembleRelease -PabiSplits; versionCode = build number + 1 armeabi-v7a / + 2 arm64-v8a):
#   rebuilt that way. A single APK carrying both ABIs is compared as a bundletool universal APK.
#   Without --binary, downloads Edge.<ver>.apk from GitHub releases.
# - Source revision: tag v<version>, or --commit <sha>. Edge does not tag every release
#   (no tags after v4.50.3); a missing tag is an error, never a silent fallback.
# - Builds in a container: JDK 17, Node 22, npm from package.json "packageManager",
#   SDK platform 36, build-tools 35.0.0, NDK 27.1.12297006.
#   npm ci + npm run prepare + versionCode/versionName from the official APK + gradlew bundleRelease,
#   then bundletool: --mode=universal (single APK) or --device-spec (split set), as upstream's
#   scripts/deploy.ts does.
# - Compares unzipped APKs pair by pair. Only root META-INF signature files (by NAME) are excluded;
#   every other difference is counted. Upstream's private env.json, google-services.json and
#   Sentry values are not public, so their effects show up as differences.
# - Generates COMPARISON_RESULTS.yaml in 3-field minimal format.

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.2.4"
APP_ID="co.edgesecure.app"
REPO_URL="https://github.com/EdgeApp/edge-react-gui.git"
GITHUB_RELEASE_BASE="https://github.com/EdgeApp/edge-react-gui/releases/download"
WS_CONTAINER="docker.io/walletscrutiny/android:5"
BUILD_TOOLS="35.0.0"
BUNDLETOOL_VERSION="1.18.3"
# Gradle JVM heap. Upstream gradle.properties sets -Xmx4g, which ran out (OutOfMemoryError) on the
# 4.51.0 build. Heap size changes memory headroom only, not compiler input or output. The command
# line outranks gradle.properties.
GRADLE_JVMARGS="-Xmx8g -XX:MaxMetaspaceSize=1g"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"

# --- Self-identification (script-notes/script-version-and-hash.md, 2026-08-17) ---
script_path="$(readlink -f "$0")"
if [[ -f "${script_path}" ]]; then
  script_sha256="$(sha256sum "${script_path}" | awk '{print $1}')"
else
  script_sha256="unknown"
fi
printf '%s %s sha256:%s\n' "${script_name}" "${SCRIPT_VERSION}" "${script_sha256}"

should_cleanup=false
official_arg=""
requested_version=""
requested_commit=""
requested_arch=""
requested_type=""

mode=""              # universal | splits | abisplit
split_abi=""         # abisplit: the one ABI in the official APK
build_version_code="" # versionCode written into build.gradle (abisplit: official minus the ABI offset)
official_dir=""      # directory holding the official APK(s)
main_apk=""          # official single APK, or base.apk of the split set
version_name=""
version_code=""
min_sdk=""
app_hash=""
signer=""
commit_hash=""
git_ref=""
additional_info=""

work_dir=""
build_image_tag=""

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*"; }

append_info() {
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n${1}"
  else
    additional_info="${1}"
  fi
}

# ------------------------------------------------------------------------------
# YAML generators (3-field minimal format per Luis 2026-03-12)
# ------------------------------------------------------------------------------
generate_error_yaml() {
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${1}
EOF
}

generate_comparison_yaml() {
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${1}
notes: |
  ${2}
EOF
}

# ------------------------------------------------------------------------------
# Exit helpers
# ------------------------------------------------------------------------------
remove_build_image() {
  if [[ -n "${build_image_tag}" ]]; then
    ${CONTAINER_CMD} rmi "${build_image_tag}" >/dev/null 2>&1 || true
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
  remove_build_image
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}

on_error() {
  local exit_code=$?
  local line_no=$1
  set +e
  log_error "Script failed at line ${line_no} (exit code ${exit_code})"
  generate_error_yaml "ftbfs"
  remove_build_image
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
CHOWN_TO=""

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
  # rootless podman: UID 0 in the container maps to the invoking user, so files written as root
  # are already the caller's. Never chown inside: that would hand them to a subordinate UID.
  CHOWN_TO="0:0"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  CONTAINER_USER_ARGS="--user $(id -u):$(id -g)"
  CHOWN_TO="$(id -u):$(id -g)"
else
  die_failed "Neither podman nor docker is available. Install one to continue."
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       ${script_name} - Edge Wallet reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk | dir-of-Play-splits> [--commit <sha>] [OPTIONS]
       ${script_name} --version <version> [--commit <sha>] [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds Edge Wallet from source in a container the way upstream's
       scripts/deploy.ts does (gradlew bundleRelease, then bundletool) and compares
       the result with an official artifact:
         - a single APK (e.g. GitHub release Edge.<ver>.apk): bundletool --mode=universal
         - a directory of Play splits (base.apk + split_config.*.apk): bundletool
           --device-spec built from the split names, compared split by split.
       Version, versionCode and minSdk are read from the official APK content.

OPTIONS
       --binary <path>         Official APK file, or directory of Play splits.
       --apk <path>            Alias for --binary.
       --version <version>     Version to verify (e.g. 4.51.0). Optional with --binary.
                               Without --binary, Edge.<version>.apk is downloaded
                               from GitHub releases.
       --commit <sha>          Build this commit (full 40-hex hash). Required when the release
                               has no v<version> tag (Edge stopped tagging after v4.50.3).
       --arch <arch>           Accepted for build server compatibility (ignored).
       --type <type>           Accepted for build server compatibility (ignored).
       --cleanup               Remove temporary files after completion.
       --script-version        Print script version and exit.
       --help                  Show this help and exit.

EXIT CODES
       0    Reproducible (only root META-INF signature files differ)
       1    Differences found or build failure
       2    Invalid parameters

EXAMPLES
       ${script_name} --binary ~/apks/co.edgesecure.app/4.51.0/ --commit 6166f1166cca8e042e9fa36e1181c57b00a59359
       ${script_name} --version 4.50.3
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
      official_arg="$2"; shift ;;
    --commit)
      [[ "$#" -lt 2 ]] && die_invalid "--commit requires a value."
      requested_commit="$2"; shift ;;
    --arch)
      [[ "$#" -lt 2 ]] && die_invalid "--arch requires a value."
      requested_arch="$2"; shift ;;
    --type)
      [[ "$#" -lt 2 ]] && die_invalid "--type requires a value."
      requested_type="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

if [[ -z "${requested_version}" && -z "${official_arg}" ]]; then
  die_invalid "You must provide --binary, or --version to download the GitHub release APK."
fi
if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi
if [[ -n "${requested_commit}" && ! "${requested_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  die_invalid "--commit must be a full 40-character lowercase commit hash (git fetch by SHA needs the full hash)."
fi
[[ -n "${requested_arch}" ]] && append_info "--arch '${requested_arch}' accepted for compatibility and ignored."
[[ -n "${requested_type}" ]] && append_info "--type '${requested_type}' accepted for compatibility and ignored."

# ------------------------------------------------------------------------------
# Containerized helpers
# ------------------------------------------------------------------------------
container_sha256() {
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "$1"):/data${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "sha256sum '/data/$(basename "$1")' | awk '{print \$1}'"
}

container_signer() {
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "$1"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apksigner verify --print-certs '/apk/$(basename "$1")' | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'"
}

# Prints one badging field (versionName, versionCode, sdkVersion) from APK content, never the filename.
container_badging() {
  local apk_name field
  apk_name="$(basename "$1")"; field="$2"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "$1"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c '
      # aapt is not on PATH in the WS container; it lives under $ANDROID_HOME/build-tools/<ver>/
      AAPT="$(command -v aapt || ls /opt/android-sdk/build-tools/*/aapt 2>/dev/null | tail -n1)"
      AAPT2="$(command -v aapt2 || ls /opt/android-sdk/build-tools/*/aapt2 2>/dev/null | tail -n1)"
      b="$({ ${AAPT:-false} dump badging "/apk/'"${apk_name}"'" 2>/dev/null || ${AAPT2:-false} dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
      case "'"${field}"'" in
        sdkVersion) printf "%s\n" "$b" | sed -n "s/^sdkVersion:'\''\([0-9]*\)'\''.*/\1/p" | head -n1 ;;
        *) printf "%s\n" "$b" | sed -n "s/.* '"${field}"'='\''\([^'\'']*\)'\''.*/\1/p" | head -n1 ;;
      esac
    '
}

# ------------------------------------------------------------------------------
# Official artifact
# ------------------------------------------------------------------------------
if [[ -z "${official_arg}" ]]; then
  apk_filename="Edge.${requested_version}.apk"
  apk_url="${GITHUB_RELEASE_BASE}/v${requested_version}/${apk_filename}"
  official_dir="${execution_dir}/download_${APP_ID}_${requested_version}"
  mkdir -p "${official_dir}"
  log_info "No --binary provided. Downloading ${apk_url}"
  if ! ${CONTAINER_CMD} run --rm ${CONTAINER_USER_ARGS} \
    --volume "${official_dir}:/download${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "curl -fsSL -o '/download/${apk_filename}' '${apk_url}'"; then
    die_failed "Download failed. Upstream may not have published a GitHub release for v${requested_version}: ${apk_url}"
  fi
  official_arg="${official_dir}/${apk_filename}"
fi

[[ "${official_arg}" == /* ]] || official_arg="${execution_dir}/${official_arg}"
if [[ -d "${official_arg}" ]]; then
  mode="splits"
  official_dir="${official_arg%/}"
  main_apk="${official_dir}/base.apk"
  [[ -f "${main_apk}" ]] || die_invalid "Split directory has no base.apk: ${official_dir}"
  mapfile -t official_splits < <(find "${official_dir}" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
  n_other="$(find "${official_dir}" -maxdepth 1 -type f -name '*.apk' ! -name base.apk ! -name 'split_config.*.apk' | wc -l)"
  [[ "${n_other}" -eq 0 ]] || die_invalid "Unexpected APK(s) in ${official_dir}: only base.apk and split_config.*.apk are allowed."
  [[ "${#official_splits[@]}" -gt 0 ]] || die_invalid "No split_config.*.apk next to base.apk in ${official_dir}"
  log_info "Official artifact: Play split set (base.apk + ${#official_splits[@]} config split(s)) in ${official_dir}"
elif [[ -f "${official_arg}" ]]; then
  mode="universal"
  official_dir="$(dirname "${official_arg}")"
  main_apk="${official_arg}"
  official_splits=()
  log_info "Official artifact: single APK ${main_apk}"
else
  die_invalid "--binary not found: ${official_arg}"
fi

app_hash="$(container_sha256 "${main_apk}")"
signer="$(container_signer "${main_apk}" || echo "unknown")"
version_name_from_apk="$(container_badging "${main_apk}" versionName)"
version_code="$(container_badging "${main_apk}" versionCode)"
min_sdk="$(container_badging "${main_apk}" sdkVersion)"

[[ "${version_code}" =~ ^[0-9]+$ ]] || die_invalid "Could not read versionCode from ${main_apk}."
if [[ -n "${requested_version}" ]]; then
  version_name="${requested_version}"
  if [[ -n "${version_name_from_apk}" && "${version_name_from_apk}" != "${requested_version}" ]]; then
    append_info "Requested version ${requested_version} but the APK reports ${version_name_from_apk}."
  fi
else
  [[ -n "${version_name_from_apk}" ]] || die_invalid "Could not read versionName from the APK. Pass --version."
  version_name="${version_name_from_apk}"
fi
log_info "versionName ${version_name}  versionCode ${version_code}  minSdk ${min_sdk:-?}"
build_version_code="${version_code}"

# A single APK with exactly one ABI under lib/ is Edge's per-ABI APK. Upstream android/app/build.gradle
# (abiVersionOffsets) gives it versionCode = build number + offset; the build must use the plain
# build number, and Gradle adds the offset back.
if [[ "${mode}" == "universal" ]]; then
  mapfile -t apk_abis < <(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${main_apk}"):/apk${VOLUME_RO_SUFFIX}" "${WS_CONTAINER}" \
    sh -c "unzip -Z1 '/apk/$(basename "${main_apk}")' | sed -n 's|^lib/\([^/]*\)/.*|\1|p' | sort -u")
  log_info "ABIs in the official APK: ${apk_abis[*]:-none}"
  if [[ "${#apk_abis[@]}" -eq 1 ]]; then
    split_abi="${apk_abis[0]}"
    case "${split_abi}" in
      armeabi-v7a) abi_offset=1 ;;
      arm64-v8a)   abi_offset=2 ;;
      *) die_invalid "Official APK carries only ${split_abi}; Edge builds per-ABI APKs for armeabi-v7a and arm64-v8a only." ;;
    esac
    mode="abisplit"
    build_version_code=$((version_code - abi_offset))
    log_info "Per-ABI APK (${split_abi}): build number ${build_version_code} + offset ${abi_offset} = ${version_code}; building assembleRelease -PabiSplits"
  fi
fi

# ------------------------------------------------------------------------------
# Source revision: tag v<version>, or --commit. Never fall back silently.
# ------------------------------------------------------------------------------
tag_name="v${version_name}"
tag_line="$(${CONTAINER_CMD} run --rm "${WS_CONTAINER}" \
  sh -c "git ls-remote --tags '${REPO_URL}' 'refs/tags/${tag_name}' 'refs/tags/${tag_name}^{}'" || true)"
tag_commit="$(echo "${tag_line}" | awk '/\^\{\}$/ {print $1}')"
[[ -z "${tag_commit}" ]] && tag_commit="$(echo "${tag_line}" | awk 'NR==1 {print $1}')"

if [[ -n "${requested_commit}" ]]; then
  git_ref="${requested_commit}"
  if [[ -n "${tag_commit}" ]]; then
    log_info "Tag ${tag_name} exists (${tag_commit}); building --commit ${requested_commit} as requested."
    append_info "Tag ${tag_name} -> ${tag_commit}; built --commit ${requested_commit} instead."
  else
    log_info "No tag ${tag_name} upstream; building --commit ${requested_commit}."
    append_info "No tag ${tag_name} upstream; built --commit ${requested_commit}."
  fi
elif [[ -n "${tag_commit}" ]]; then
  git_ref="${tag_commit}"
  log_info "Tag ${tag_name} -> ${tag_commit}"
else
  die_invalid "No tag ${tag_name} in ${REPO_URL}. Edge does not tag every release; pass --commit <sha> (see the build notes for how the release commit was identified)."
fi

# ------------------------------------------------------------------------------
# Workspace
# ------------------------------------------------------------------------------
work_dir="${execution_dir}/workdir_${APP_ID}_${version_name}_${mode}"
if [[ -d "${work_dir}" ]]; then
  log_info "Removing existing workspace: ${work_dir}"
  ${CONTAINER_CMD} run --rm --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" "${WS_CONTAINER}" \
    sh -c "find /workspace -mindepth 1 -delete" 2>/dev/null || true
  rm -rf "${work_dir}"
fi
mkdir -p "${work_dir}/output" "${work_dir}/ctx"
build_image_tag="edge_build_${version_name}_$$"

# Device spec for split sets: from the official split names (ABI, density, locale) and base.apk's
# minSdkVersion (bundletool writes each variant's lower SDK bound into its APKs).
if [[ "${mode}" == "splits" ]]; then
  abis=(); density=""; locales=()
  for f in "${official_splits[@]}"; do
    c="$(basename "${f}" .apk)"; c="${c#split_config.}"
    case "${c}" in
      arm64_v8a) abis+=("arm64-v8a") ;; armeabi_v7a) abis+=("armeabi-v7a") ;; x86_64|x86) abis+=("${c}") ;;
      ldpi) density=120 ;; mdpi) density=160 ;; tvdpi) density=213 ;; hdpi) density=240 ;;
      xhdpi) density=320 ;; xxhdpi) density=480 ;; xxxhdpi) density=640 ;;
      [a-z][a-z]|[a-z][a-z][a-z]) locales+=("${c}") ;;
      *) log_warn "Unknown config split '${c}'; it will have no built counterpart and count as a difference." ;;
    esac
  done
  [[ "${#abis[@]}" -gt 0 ]] || abis=("arm64-v8a")
  [[ -n "${density}" ]] || density=480
  [[ "${#locales[@]}" -gt 0 ]] || locales=("en")
  [[ "${min_sdk}" =~ ^[0-9]+$ ]] || die_invalid "Could not read minSdkVersion from base.apk (needed for the device spec)."
  abij="$(printf '"%s",' "${abis[@]}")"; locj="$(printf '"%s",' "${locales[@]}")"
  printf '{"supportedAbis":[%s],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' \
    "${abij%,}" "${locj%,}" "${density}" "${min_sdk}" > "${work_dir}/output/device-spec.json"
  log_info "device-spec: $(cat "${work_dir}/output/device-spec.json")"
fi

# ------------------------------------------------------------------------------
# Build environment image
# ------------------------------------------------------------------------------
cat > "${work_dir}/ctx/Dockerfile" <<DOCKEREOF
FROM docker.io/library/eclipse-temurin:17-jdk-jammy

ENV ANDROID_HOME="/opt/android-sdk" \\
    ANDROID_SDK_ROOT="/opt/android-sdk" \\
    GRADLE_USER_HOME="/root/.gradle" \\
    ANDROID_PREFS_ROOT="/root/.android" \\
    PATH="\${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools"

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git wget unzip curl ca-certificates \\
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \\
    && apt-get install -y nodejs \\
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p \${ANDROID_HOME}/cmdline-tools && \\
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip -O /tmp/ct.zip && \\
    unzip -q /tmp/ct.zip -d \${ANDROID_HOME}/cmdline-tools && \\
    mv \${ANDROID_HOME}/cmdline-tools/cmdline-tools \${ANDROID_HOME}/cmdline-tools/latest && rm /tmp/ct.zip

RUN yes | sdkmanager --licenses >/dev/null 2>&1 && \\
    sdkmanager "platform-tools" "platforms;android-36" "build-tools;${BUILD_TOOLS}" "ndk;27.1.12297006" "cmake;3.22.1"

RUN curl -fsSL -o /opt/bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar && \\
    echo "${BUNDLETOOL_SHA256}  /opt/bundletool.jar" | sha256sum -c -
DOCKEREOF

log_info "Building environment image '${build_image_tag}' (JDK 17, Node 22, SDK 36, build-tools ${BUILD_TOOLS}, NDK 27.1.12297006, bundletool ${BUNDLETOOL_VERSION})..."
${CONTAINER_CMD} build -t "${build_image_tag}" "${work_dir}/ctx" || die_failed "Failed to build the environment image."

# ------------------------------------------------------------------------------
# Clone + build + render, inside the container
# ------------------------------------------------------------------------------
log_info "Running fetch + npm ci + npm run prepare + gradlew bundleRelease + bundletool (${mode}) in the container..."
log_info "This typically takes 20-60 minutes."

if ! ${CONTAINER_CMD} run --rm \
  --volume "${work_dir}/output:/output${VOLUME_RW_SUFFIX}" \
  --env "EDGE_REPO_URL=${REPO_URL}" \
  --env "EDGE_REF=${git_ref}" \
  --env "EDGE_TAG=${tag_name}" \
  --env "EDGE_VERSION_NAME=${version_name}" \
  --env "EDGE_VERSION_CODE=${build_version_code}" \
  --env "EDGE_MODE=${mode}" \
  --env "EDGE_ABI=${split_abi}" \
  --env "EDGE_ABI_OFFSET=${abi_offset:-}" \
  --env "BUILD_TOOLS=${BUILD_TOOLS}" \
  --env "GRADLE_JVMARGS=${GRADLE_JVMARGS}" \
  --env "CHOWN_TO=${CHOWN_TO}" \
  "${build_image_tag}" \
  bash -c '
    set -euo pipefail
    trap "chown -R ${CHOWN_TO} /output 2>/dev/null || true" EXIT

    mkdir -p /build/app && cd /build/app
    git init -q && git remote add origin "${EDGE_REPO_URL}"
    git fetch -q --depth 1 origin "${EDGE_REF}"
    git checkout -q FETCH_HEAD
    git rev-parse HEAD > /output/commit_hash.txt
    case "$(cat /output/commit_hash.txt)" in
      "${EDGE_REF}"*) ;;
      *) echo "FATAL: checked out $(cat /output/commit_hash.txt), wanted ${EDGE_REF}"; exit 4 ;;
    esac
    printf "%s\n" "$(git log -1 --format="%H %cI %s")" > /output/commit_info.txt
    git verify-commit HEAD > /output/commit_verify.txt 2>&1 || true

    pm="$(node -p "require(\"./package.json\").packageManager || \"\"")"
    echo "packageManager: ${pm:-<none>}  node $(node --version)"
    case "${pm}" in
      npm@*) npm install -g "${pm}" >/dev/null ;;
      "") ;;
      *) echo "FATAL: unsupported packageManager ${pm} (script expects npm)"; exit 5 ;;
    esac
    echo "npm $(npm --version)" | tee /output/toolchain.txt
    node --version >> /output/toolchain.txt

    npm ci
    npm run prepare

    # Same substitutions as upstream scripts/updateVersion.ts, values from the official APK:
    sed -i -E "s/versionName \"[0-9.]+\"/versionName \"${EDGE_VERSION_NAME}\"/" android/app/build.gradle
    sed -i -E "s/versionCode [0-9]+/versionCode ${EDGE_VERSION_CODE}/" android/app/build.gradle
    grep -nE "versionCode|versionName" android/app/build.gradle | sed -n "1,2p"

    if [ "${EDGE_MODE}" = "abisplit" ]; then
      # The offset this script subtracted must be the one upstream adds back:
      grep -qE "abiVersionOffsets = \[.*${EDGE_ABI}.: ${EDGE_ABI_OFFSET}[],]" android/app/build.gradle \
        || { echo "FATAL: android/app/build.gradle abiVersionOffsets has no ${EDGE_ABI}: ${EDGE_ABI_OFFSET}"; grep -n abiVersionOffsets android/app/build.gradle; exit 6; }
      grep -n "abiVersionOffsets =" android/app/build.gradle
    fi

    cd android
    if [ "${EDGE_MODE}" = "abisplit" ]; then
      # Edge scripts/deploy.ts: ./gradlew assembleRelease -PabiSplits -> app-<abi>-release.apk
      ./gradlew assembleRelease -PabiSplits --no-daemon "-Dorg.gradle.jvmargs=${GRADLE_JVMARGS}" 2>&1 \
        | tee /output/gradle.log | grep --line-buffered -vE "^[[:space:]]+at |^[[:space:]]*$"
      cp "app/build/outputs/apk/release/app-${EDGE_ABI}-release.apk" "/output/built-${EDGE_ABI}.apk"
      exit 0
    fi
    # Full Gradle output goes to /output/gradle.log. The console drops Java stack-frame lines only:
    # D8 prints ~820 Kotlin-metadata warnings with full traces for the Zcash SDK (Kotlin 2.3 vs
    # R8 8.8), ~290k lines that swamp the recording. Warning headers and errors still show.
    ./gradlew bundleRelease --no-daemon "-Dorg.gradle.jvmargs=${GRADLE_JVMARGS}" 2>&1 \
      | tee /output/gradle.log | grep --line-buffered -vE "^[[:space:]]+at |^[[:space:]]*$"
    cp app/build/outputs/bundle/release/app-release.aab /output/app-release.aab

    AAPT2="${ANDROID_HOME}/build-tools/${BUILD_TOOLS}/aapt2"
    if [ "${EDGE_MODE}" = "universal" ]; then
      java -jar /opt/bundletool.jar build-apks --overwrite --mode=universal --aapt2="${AAPT2}" \
        --bundle=/output/app-release.aab --output=/output/built.apks
      (cd /output && unzip -q -o built.apks universal.apk)
    else
      java -jar /opt/bundletool.jar build-apks --overwrite --device-spec=/output/device-spec.json \
        --aapt2="${AAPT2}" --bundle=/output/app-release.aab --output=/output/built.apks
      (cd /output && rm -rf splits && unzip -q -o built.apks "splits/*.apk")
    fi
  '; then
  die_failed "Build failed inside the container. See the output above."
fi

commit_hash="$(cat "${work_dir}/output/commit_hash.txt" 2>/dev/null || echo "unknown")"
log_info "Commit: $(cat "${work_dir}/output/commit_info.txt" 2>/dev/null || echo "${commit_hash}")"
aab_hash=""
if [[ "${mode}" != "abisplit" ]]; then
  aab_hash="$(container_sha256 "${work_dir}/output/app-release.aab")"
  log_info "AAB: ${aab_hash}"
fi

# ------------------------------------------------------------------------------
# Pairs: official <-> built
# ------------------------------------------------------------------------------
declare -a PAIRS=()   # "label|official|built"
if [[ "${mode}" == "abisplit" ]]; then
  built_split="${work_dir}/output/built-${split_abi}.apk"
  [[ -f "${built_split}" ]] || die_failed "Gradle produced no app-${split_abi}-release.apk"
  built_vc="$(container_badging "${built_split}" versionCode)"
  log_info "Built ${split_abi} APK versionCode: ${built_vc} (official ${version_code})"
  [[ "${built_vc}" == "${version_code}" ]] || append_info "Built versionCode ${built_vc} differs from official ${version_code}."
  PAIRS+=("${split_abi}|${main_apk}|${built_split}")
elif [[ "${mode}" == "universal" ]]; then
  [[ -f "${work_dir}/output/universal.apk" ]] || die_failed "bundletool produced no universal.apk"
  PAIRS+=("universal|${main_apk}|${work_dir}/output/universal.apk")
else
  PAIRS+=("base|${main_apk}|${work_dir}/output/splits/base-master.apk")
  for f in "${official_splits[@]}"; do
    c="$(basename "${f}" .apk)"; c="${c#split_config.}"
    PAIRS+=("${c}|${f}|${work_dir}/output/splits/base-${c}.apk")
  done
  log_info "Rendered splits: $(ls "${work_dir}/output/splits" | tr '\n' ' ')"
fi

# ------------------------------------------------------------------------------
# Comparison
# ------------------------------------------------------------------------------
# Only ROOT META-INF signature files are excluded, matched by NAME: "Only in" on the official side,
# or "Files differ" on both sides. services/, version-control-info.textproto, *.version markers and
# anything signing-named that exists only in OUR build are counted (ws-notes/script-notes/meta-inf-filter-scope.md).
SIGN_NAME='[^/]*(\.(SF|RSA|DSA|EC)|MANIFEST\.MF)'
diff_file="${work_dir}/diff_full.txt"
: > "${diff_file}"
total_raw=0
total_counted=0
declare -a SUMMARY=()

for p in "${PAIRS[@]}"; do
  IFS='|' read -r label off_apk blt_apk <<< "${p}"
  od="official_${label}"; bd="built_${label}"
  if [[ ! -f "${blt_apk}" ]]; then
    log_warn "No built counterpart for ${label} ($(basename "${off_apk}")); counted as a difference."
    echo "MISSING built counterpart for $(basename "${off_apk}")" >> "${diff_file}"
    total_raw=$((total_raw + 1)); total_counted=$((total_counted + 1))
    SUMMARY+=("$(basename "${off_apk}") - ${label} - (none) - 0 (NO BUILT COUNTERPART)")
    continue
  fi
  mkdir -p "${work_dir}/${od}" "${work_dir}/${bd}"
  ${CONTAINER_CMD} run --rm ${CONTAINER_USER_ARGS} \
    --volume "$(dirname "${off_apk}"):/in${VOLUME_RO_SUFFIX}" --volume "${work_dir}/${od}:/out${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" sh -c "unzip -qq '/in/$(basename "${off_apk}")' -d /out" \
    || die_failed "unzip failed for official ${label}"
  ${CONTAINER_CMD} run --rm ${CONTAINER_USER_ARGS} \
    --volume "$(dirname "${blt_apk}"):/in${VOLUME_RO_SUFFIX}" --volume "${work_dir}/${bd}:/out${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" sh -c "unzip -qq '/in/$(basename "${blt_apk}")' -d /out" \
    || die_failed "unzip failed for built ${label}"

  # diff exit status: 0 identical, 1 differences, >1 error. An error must never read as "identical".
  set +e
  pair_diff="$(${CONTAINER_CMD} run --rm --volume "${work_dir}:/w${VOLUME_RO_SUFFIX}" --workdir /w \
    "${WS_CONTAINER}" sh -c "diff -qr '${od}' '${bd}'; echo \"__RC=\$?\"")"
  set -e
  rc="$(echo "${pair_diff}" | sed -n 's/^__RC=//p' | tail -1)"
  pair_diff="$(echo "${pair_diff}" | grep -v '^__RC=' || true)"
  [[ "${rc}" == "0" || "${rc}" == "1" ]] || die_failed "diff failed for ${label} (exit ${rc:-none})"

  od_re="$(echo "${od}" | sed 's/[][\.^$*+?(){}|\/]/\\&/g')"
  counted="$(echo "${pair_diff}" \
    | grep -vE "^Only in ${od_re}/META-INF: ${SIGN_NAME}$" \
    | grep -vE "^Files [^/ ]+/META-INF/${SIGN_NAME} and [^/ ]+/META-INF/${SIGN_NAME} differ$" \
    | sed '/^$/d' || true)"
  n_raw=0; n_counted=0
  [[ -n "${pair_diff}" ]] && n_raw="$(echo "${pair_diff}" | grep -c '^' || true)"
  [[ -n "${counted}" ]] && n_counted="$(echo "${counted}" | grep -c '^' || true)"
  total_raw=$((total_raw + n_raw)); total_counted=$((total_counted + n_counted))
  { echo "### ${label}: raw ${n_raw}, counted ${n_counted}"; echo "${pair_diff}"; } >> "${diff_file}"

  blt_hash="$(container_sha256 "${blt_apk}")"
  if [[ "${n_counted}" -eq 0 ]]; then
    SUMMARY+=("$(basename "${off_apk}") - ${label} - ${blt_hash} - 1 (MATCHES)")
  else
    SUMMARY+=("$(basename "${off_apk}") - ${label} - ${blt_hash} - 0 (DOESN'T MATCH)")
  fi
  log_info "${label}: raw ${n_raw}, counted ${n_counted}"
  if [[ "${n_counted}" -gt 0 ]]; then
    # sed -n reads all input; "| head" would SIGPIPE the writer and pipefail turns that into exit 141.
    printf '%s\n' "${counted}" | sed -n '1,5s/^/    /p'
    if [[ "${n_counted}" -gt 5 ]]; then
      echo "    ... (${n_counted} counted lines for ${label}; full list in ${diff_file})"
    fi
  fi
done

if [[ "${total_counted}" -eq 0 && "${#PAIRS[@]}" -gt 0 ]]; then
  verdict="reproducible"; yaml_status="reproducible"; exit_code="${EXIT_SUCCESS}"
else
  verdict="differences found"; yaml_status="not_reproducible"; exit_code="${EXIT_FAILED}"
fi

if [[ "${mode}" == "abisplit" ]]; then
  append_info "Build: gradlew assembleRelease -PabiSplits (upstream deploy.ts per-ABI APK), ${split_abi}, versionCode ${build_version_code} + ${abi_offset}; $(tr '\n' ' ' < "${work_dir}/output/toolchain.txt" 2>/dev/null)"
else
  append_info "Build: gradlew bundleRelease + bundletool ${BUNDLETOOL_VERSION} (${mode}); $(tr '\n' ' ' < "${work_dir}/output/toolchain.txt" 2>/dev/null)"
  append_info "AAB SHA-256: ${aab_hash}"
fi
append_info "Gradle JVM args: ${GRADLE_JVMARGS} (upstream gradle.properties: -Xmx4g -XX:MaxMetaspaceSize=512m). Full Gradle log: workdir output/gradle.log."
append_info "Not public, so absent from this build: upstream env.json (API keys; Sentry DSN/slug that CI patches into build.gradle and MainApplication.kt), google-services.json (sample used)."
generate_comparison_yaml "${yaml_status}" "${total_counted} counted differences (raw ${total_raw}) across ${#PAIRS[@]} APK pair(s); bundleRelease + bundletool ${mode}."

# ------------------------------------------------------------------------------
# Tag / commit signature information
# ------------------------------------------------------------------------------
if [[ -n "${tag_commit}" ]]; then
  tag_text="Tag ${tag_name} -> ${tag_commit}"
else
  tag_text="No tag ${tag_name} upstream"
fi
commit_verify="$(cat "${work_dir}/output/commit_verify.txt" 2>/dev/null || true)"
if echo "${commit_verify}" | grep -q "Good signature"; then
  commit_sig="[OK] Good signature on commit"
elif echo "${commit_verify}" | grep -qiE "cannot run gpg|gpg: not found|No such file"; then
  commit_sig="[INFO] Commit signature not checked (no gpg in the build container)"
else
  commit_sig="[WARNING] No valid signature found on commit"
fi

# ------------------------------------------------------------------------------
# Results
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
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${script_sha256}"
echo ""
echo "Diff:"
if [[ "${exit_code}" -eq "${EXIT_SUCCESS}" ]]; then
  echo "BUILDS MATCH BINARIES"
else
  echo "BUILDS DO NOT MATCH BINARIES"
fi
printf '%s\n' "${SUMMARY[@]}"
echo "Totals: raw ${total_raw}, counted ${total_counted} (root META-INF signature files excluded)"
echo ""
echo "Revision, tag (and its signature):"
echo "${tag_text}"
echo "Built: $(cat "${work_dir}/output/commit_info.txt" 2>/dev/null || echo "${commit_hash}")"
echo "${commit_sig}"
if [[ -n "${additional_info}" ]]; then
  echo ""
  echo "===== Also ====="
  echo -e "${additional_info}"
fi
echo "===== End Results ====="
echo ""
echo "Full diff list: ${diff_file}"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
remove_build_image
if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
  log_info "Workspace cleaned up."
else
  log_info "Workspace preserved: ${work_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
