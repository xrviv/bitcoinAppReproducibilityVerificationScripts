#!/usr/bin/env bash
# mycelium-v0.3.1_build.sh - Mycelium Bitcoin Wallet (Android) reproducible build verification. License: MIT
# Version: v0.3.1
# Organization: WalletScrutiny.com | Project: https://github.com/mycelium-com/wallet-android
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-15
# Disclaimer: build verification only, not a security audit; as-is, no warranty. Use lawfully, at your own risk.
# Steps: check the official APK (app ID, version, signer, hash) -> build upstream's builder image (base image by
# digest, apt snapshot, checksummed SDK tools) -> build the tag with Gradle (disorderfs under rootless podman)
# -> unzip and diff both APKs -> decode resources.arsc with apktool if it differs -> results + YAML.

set -euo pipefail

# Self-hash first, so even a run that stops on bad arguments records which
# script bytes ran. A hashing failure gives N/A and never stops the run.
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256="$(sha256sum "${SCRIPT_PATH}" 2>/dev/null | awk '{print $1}' || true)"
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
SCRIPT_VERSION="v0.3.1"
SCRIPT_NAME="$(basename "${SCRIPT_PATH}")"
echo "[INFO] Script: ${SCRIPT_NAME} ${SCRIPT_VERSION} sha256: ${SCRIPT_SHA256}"

if [[ "$EUID" -eq 0 ]]; then
  echo "[ERROR] Do not run this script as root." >&2
  echo "Exit code: 2"
  exit 2
fi

# ==============================================================================
# Constants and pinned inputs
# ==============================================================================
APP_ID="com.mycelium.wallet"
REPO_URL="https://github.com/mycelium-com/wallet-android"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
# WS tools image (apktool, apksigner) for the APK checks and resources.arsc decode.
WS_CONTAINER="docker.io/walletscrutiny/android:5@sha256:eabd60543f19831feef6db22e9a1ada0ef469eef723119f1c96bd836198614c3"
# ubuntu:22.04 index digest (2026-10-14), as in upstream's Dockerfile FROM line.
BASE_IMAGE="docker.io/library/ubuntu:22.04@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401"
APT_SNAPSHOT="20261015T000000Z"
# commandlinetools-linux-11076708_latest.zip; sha1 d313adb7… matches Google's repository2-3.xml.
SDK_TOOLS_SHA256="2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"

RUN_ID="mycelium-$(date +%s)-$$"
IMAGE_NAME="ws-mycelium-image-${RUN_ID}"
CONTAINER_NAME="ws-mycelium-build-${RUN_ID}"

# Results fields (N/A until known, so a failed run still prints a full block).
signer="N/A"; version_name="N/A"; version_code="N/A"; official_hash="N/A"; commit="N/A"

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[OK] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --binary <apk> [--version <ver>] [options]

  --binary <file>      Official Mycelium APK (Google Play or mycelium.com); required
  --apk <file>         Alias for --binary
  --version <ver>      Expected version, e.g. 3.22.0.2 (tag v3.22.0.2); must match the APK
  --arch, --type       Accepted and ignored (one fat APK covers every ABI)
  --keep-container     Keep this run's builder image after the run
  -h, --help           Show this help

Needs only podman or docker. There is no downloadable official APK to fetch, so
--binary is required. Exit codes: 0 reproducible, 1 not reproducible or failed,
2 invalid input (wrong app, version mismatch, missing file).
EOF
}

# ==============================================================================
# Arguments
# ==============================================================================
version=""; apk_file=""; arch=""; build_type=""; keep_container=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)        version="${2:-}";    shift 2 || shift ;;
    --binary|--apk)   apk_file="${2:-}";   shift 2 || shift ;;
    --arch)           arch="${2:-}";       shift 2 || shift ;;
    --type)           build_type="${2:-}"; shift 2 || shift ;;
    --keep-container) keep_container=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) log_warn "Ignoring unknown parameter: $1"; shift ;;
  esac
done

invalid() { log_error "$*"; echo "Exit code: 2"; exit 2; }

[[ -n "$apk_file" ]] || { usage; invalid "Provide --binary <file> (or --apk <file>) with the official APK."; }
[[ -f "$apk_file" ]] || invalid "APK file not found: $apk_file"
apk_file="$(realpath "$apk_file")"
if [[ -n "$version" && ! "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  invalid "Invalid --version '$version' (expected digits and dots, e.g. 3.22.0.2)"
fi
[[ -n "$arch" ]]       && log_info "--arch $arch ignored (one fat APK covers every ABI)"
[[ -n "$build_type" ]] && log_info "--type $build_type ignored"

# ==============================================================================
# Container runtime (must answer 'info')
# ==============================================================================
container_cmd=""
if command -v podman &>/dev/null && podman info &>/dev/null; then
  container_cmd="podman"
elif command -v docker &>/dev/null && docker info &>/dev/null; then
  container_cmd="docker"
else
  log_error "No working podman or docker (both must answer 'info'). Install or start one."
  echo "Exit code: 1"
  exit 1
fi
log_info "Container runtime: ${container_cmd}"

# disorderfs needs CAP_SYS_ADMIN and /dev/fuse. Only under rootless podman is that
# capability confined to the user namespace; under docker it is real root power.
use_disorderfs=false
if [[ "${container_cmd}" == "podman" && -e /dev/fuse ]]; then
  use_disorderfs=true
else
  log_warn "disorderfs off (needs rootless podman and /dev/fuse); building straight from the checkout."
fi

# ==============================================================================
# YAML, results block, failure exit
# ==============================================================================
YAML_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
generate_yaml() {
  {
    printf 'script_version: %s\n' "${SCRIPT_VERSION}"
    printf 'verdict: %s\n' "$1"
    if [[ -n "${2:-}" ]]; then
      printf 'notes: |\n'
      while IFS= read -r line; do printf '  %s\n' "${line}"; done <<< "$2"
    fi
  } > "${YAML_FILE}"
  log_info "Build server output: ${YAML_FILE}"
}

print_results() {
  echo ""
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         ${signer}"
  echo "apkVersionName: ${version_name}"
  echo "apkVersionCode: ${version_code}"
  echo "verdict:        $1"
  echo "appHash:        ${official_hash}"
  echo "commit:         ${commit}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo "===== End Results ====="
}

fail() {
  log_error "$1"
  generate_yaml "ftbfs" "$1"
  print_results "ftbfs"
  echo "Exit code: 1"
  exit 1
}

# ==============================================================================
# Per-run workspace in the caller's directory. A run only touches the
# directory it created; earlier workspaces are never removed or reused.
# ==============================================================================
rm -f "${YAML_FILE}"
workspace="$(pwd -P)/mycelium_verification_${version:-apk}_$(date +%s)-$$"
mkdir -- "${workspace}"
log_info "Workspace: ${workspace}"
build_context_dir="${workspace}/context"
mkdir -- "${build_context_dir}"

# EXIT: hand the workspace back to the caller (docker writes as root; rootless
# podman as mapped subuids), then remove this run's container and image.
cleanup() {
  local rc=$?
  set +e
  if [[ "${container_cmd}" == "podman" ]]; then
    podman unshare chown -R 0:0 "${workspace}" >/dev/null 2>&1
  elif docker image inspect "${WS_CONTAINER}" >/dev/null 2>&1; then
    docker run --rm --volume "${workspace}:/w" "${WS_CONTAINER}" chown -R "$(id -u):$(id -g)" /w >/dev/null 2>&1
  fi
  local foreign
  foreign="$(find "${workspace}" ! -user "$(id -u)" 2>/dev/null | wc -l)"
  [[ "${foreign}" == 0 ]] || log_warn "${foreign} workspace entries not owned by you: ${workspace}"
  ${container_cmd} rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
  if [[ "${keep_container}" == "true" ]]; then
    log_info "Keeping image (--keep-container): ${IMAGE_NAME}"
  else
    ${container_cmd} rmi -f "${IMAGE_NAME}" >/dev/null 2>&1
  fi
  # No verdict on invalid input (2) or a stop (130): ABS publishes any YAML
  # verdict, and a stopped run did not fail to build. Other failures are ftbfs.
  if [[ "${rc}" != 2 && "${rc}" != 130 && ! -f "${YAML_FILE}" ]]; then
    generate_yaml "ftbfs" "Script stopped before writing a verdict."
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'log_error "Interrupted; no verdict written"; exit 130' INT TERM

# ==============================================================================
# Check the official APK before any build: app ID, version, signer, hash.
# ==============================================================================
log_info "Reading the official APK with apktool and apksigner..."
apk_meta="$(${container_cmd} run --rm -e HOME=/tmp \
  --volume "${apk_file}:/official.apk:ro" "${WS_CONTAINER}" sh -c '
    apktool d -f -s --frame-path /tmp/fw -o /tmp/d /official.apk >/dev/null 2>&1 || exit 3
    echo "package=$(grep -o "package=\"[^\"]*\"" /tmp/d/AndroidManifest.xml | head -1 | cut -d\" -f2)"
    echo "versionName=$(sed -n "s/^ *versionName: *'\''\{0,1\}\([^'\'']*\)'\''\{0,1\} *$/\1/p" /tmp/d/apktool.yml)"
    echo "versionCode=$(sed -n "s/^ *versionCode: *'\''\{0,1\}\([0-9]*\)'\''\{0,1\} *$/\1/p" /tmp/d/apktool.yml)"
    echo "signer=$(apksigner verify --print-certs /official.apk 2>/dev/null | sed -n "s/^Signer #1 certificate SHA-256 digest: //p")"
    echo "sha256=$(sha256sum /official.apk | cut -d" " -f1)"
  ')" || fail "Could not read the official APK with apktool (corrupt or not an APK?)."

meta() { sed -n "s/^$1=//p" <<< "${apk_meta}"; }
apk_package="$(meta package)"
version_name="$(meta versionName)"; version_name="${version_name:-N/A}"
version_code="$(meta versionCode)"; version_code="${version_code:-N/A}"
signer="$(meta signer)";            signer="${signer:-N/A}"
official_hash="$(meta sha256)";     official_hash="${official_hash:-N/A}"

[[ "${apk_package}" == "${APP_ID}" ]] || invalid "APK package '${apk_package}' is not ${APP_ID}; wrong APK."
[[ "${version_name}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || invalid "APK versionName '${version_name}' is not a release version."
if [[ -n "${version}" && "${version}" != "${version_name}" ]]; then
  invalid "--version ${version} does not match the APK's versionName ${version_name}."
fi
TAG_REF="v${version_name}"
log_success "APK: ${apk_package} ${version_name} (${version_code}), signer ${signer}, tag ${TAG_REF}"

# ==============================================================================
# Builder image: upstream's Dockerfile steps with pinned inputs.
# ==============================================================================
cat > "${build_context_dir}/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG APT_SNAPSHOT
ARG SDK_TOOLS_SHA256
ENV DEBIAN_FRONTEND=noninteractive

# ca-certificates first from the image's default archive (apt still checks the
# archive signature), then every source switches to the fixed Ubuntu snapshot.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}/#" /etc/apt/sources.list \
    && rm -rf /var/lib/apt/lists/*

RUN dpkg --add-architecture i386 && \
    apt-get update -y && \
    apt-get install -y wget openjdk-21-jdk git unzip diffutils disorderfs && \
    rm -rf /var/lib/apt/lists/* && apt-get autoremove -y && apt-get clean

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ARG ANDROID_SDK_VERSION=11076708
ARG ANDROID_BUILD_TOOLS_VERSION=34.0.0
ARG ANDROID_NDK_VERSION=21.1.6352462
ARG ANDROID_PLATFORM_VERSION=34
ARG CMAKE_VERSION=3.22.1
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_HOME=${ANDROID_HOME} ANDROID_SDK_ROOT=${ANDROID_HOME} ANDROID_SDK=${ANDROID_HOME}
ENV PATH="${PATH}:${JAVA_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/tools/bin:${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS_VERSION}:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}:${ANDROID_HOME}/emulator"

RUN mkdir -p $ANDROID_HOME && cd $ANDROID_HOME && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip && \
    echo "${SDK_TOOLS_SHA256}  commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip" | sha256sum -c - && \
    unzip -q *commandlinetools*linux*.zip -d cmdline-tools/ && \
    rm *commandlinetools*linux*.zip && \
    mv cmdline-tools/cmdline-tools/ cmdline-tools/latest/ && \
    yes | sdkmanager --licenses >/dev/null

RUN sdkmanager "platform-tools" "platforms;android-${ANDROID_PLATFORM_VERSION}" \
      "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" "ndk;${ANDROID_NDK_VERSION}" "cmake;${CMAKE_VERSION}"
DOCKERFILE

log_info "Building builder image (first run: ~15-20 min for the Android SDK)..."
${container_cmd} build --tag "${IMAGE_NAME}" \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  --build-arg APT_SNAPSHOT="${APT_SNAPSHOT}" \
  --build-arg SDK_TOOLS_SHA256="${SDK_TOOLS_SHA256}" \
  --file "${build_context_dir}/Dockerfile" "${build_context_dir}" \
  || fail "Builder image build failed."
log_success "Builder image: ${IMAGE_NAME}"

# ==============================================================================
# In-container build and comparison
# ==============================================================================
cat > "${build_context_dir}/build_in_container.sh" <<'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail
OUT=/output
echo "[CONTAINER] Cloning ${REPO_URL} at ${TAG_REF} ..."
git clone --branch "${TAG_REF}" --depth 1 "${REPO_URL}" /src
cd /src
sed -i 's|git@github.com:|https://github.com/|g' .gitmodules 2>/dev/null || true
git submodule update --init --recursive
git rev-parse HEAD > "${OUT}/commit.txt"
git tag -v "${TAG_REF}" > "${OUT}/git-tag-verify.txt" 2>&1 || true
rm -f local.properties

build_root=/src
if [[ "${USE_DISORDERFS}" == "true" ]]; then
  mkdir -p /project
  disorderfs --sort-dirents=yes --reverse-dirents=no /src/ /project/
  build_root=/project
fi
cd "${build_root}"
echo "[CONTAINER] gradle :mbw:assembleProdnetRelease (fat APK) ..."
./gradlew -x lint -x test clean :mbw:assembleProdnetRelease

built_apk="${build_root}/mbw/build/outputs/apk/prodnet/release/mbw-prodnet-release.apk"
[[ -f "${built_apk}" ]] || { echo "[CONTAINER] ERROR: built APK not found"; exit 1; }
cp "${built_apk}" "${OUT}/mbw-prodnet-release.apk"
sha256sum "${built_apk}" | cut -d' ' -f1 > "${OUT}/built-hash.txt"

mkdir -p "${OUT}/official-unzipped" "${OUT}/built-unzipped"
unzip -qq /official/base.apk -d "${OUT}/official-unzipped"
unzip -qq "${built_apk}" -d "${OUT}/built-unzipped"

rc=0
diff --brief --recursive "${OUT}/official-unzipped/" "${OUT}/built-unzipped/" \
  > "${OUT}/diff-full.txt" 2> "${OUT}/diff-error.txt" || rc=$?
if [[ "${rc}" -gt 1 ]]; then
  echo "[CONTAINER] ERROR: diff failed (${rc})"; cat "${OUT}/diff-error.txt"; exit 1
fi

# Excluded: root META-INF signing files present ONLY in the official APK.
# Matched by file name, never by directory (meta-inf-filter-scope).
sig_re="^Only in ${OUT}/official-unzipped/META-INF: ([^/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)\$"
grep -E  "${sig_re}" "${OUT}/diff-full.txt" > "${OUT}/diff-excluded.txt" || true
grep -vE "${sig_re}" "${OUT}/diff-full.txt" > "${OUT}/diff-counted.txt" || true
echo "[CONTAINER] Done."
BUILDSCRIPT

run_args=(--rm --name "${CONTAINER_NAME}"
  --volume "${workspace}:/output"
  --volume "${build_context_dir}/build_in_container.sh:/build_in_container.sh:ro"
  --volume "${apk_file}:/official/base.apk:ro"
  --env "TAG_REF=${TAG_REF}" --env "REPO_URL=${REPO_URL}" --env "USE_DISORDERFS=${use_disorderfs}")
[[ "${container_cmd}" == "podman" ]] && run_args+=(--security-opt label=disable)
if [[ "${use_disorderfs}" == "true" ]]; then
  run_args+=(--device /dev/fuse --cap-add SYS_ADMIN)
fi

log_info "Building ${TAG_REF} (Gradle, 5-15 min)..."
${container_cmd} run "${run_args[@]}" "${IMAGE_NAME}" bash /build_in_container.sh \
  || fail "Gradle build or comparison failed inside the container."

[[ -f "${workspace}/mbw-prodnet-release.apk" && -f "${workspace}/diff-counted.txt" ]] \
  || fail "Built APK or comparison output missing after the container run."
commit="$(cat "${workspace}/commit.txt" 2>/dev/null || echo N/A)"
built_hash="$(cat "${workspace}/built-hash.txt" 2>/dev/null || echo N/A)"

# ==============================================================================
# resources.arsc: decode both sides and compare res/ (resources.arsc.md).
# Identical, or only the Crashlytics mapping_file_id differs -> not counted.
# ==============================================================================
arsc_note=""
arsc_line="Files /output/official-unzipped/resources.arsc and /output/built-unzipped/resources.arsc differ"
if grep -qxF "${arsc_line}" "${workspace}/diff-counted.txt"; then
  log_info "resources.arsc differs; decoding both APKs with apktool..."
  cp "${apk_file}" "${workspace}/official.apk"
  ${container_cmd} run --rm -e HOME=/tmp --volume "${workspace}:/w" "${WS_CONTAINER}" sh -c '
    for s in official built; do
      f=/w/official.apk; [ "$s" = built ] && f=/w/mbw-prodnet-release.apk
      apktool d -f -s --frame-path /tmp/fw -o /w/$s-decoded "$f" >/dev/null 2>&1 || exit 3
    done
    diff -r /w/official-decoded/res /w/built-decoded/res > /w/diff_resources_decoded.txt; [ $? -le 1 ]' \
    || fail "apktool decode of resources.arsc failed."
  other="$(grep -E '^[<>]' "${workspace}/diff_resources_decoded.txt" \
    | grep -v 'com.google.firebase.crashlytics.mapping_file_id' || true)"
  if [[ -z "${other}" ]]; then
    grep -vxF "${arsc_line}" "${workspace}/diff-counted.txt" > "${workspace}/diff-counted.tmp" || true
    mv "${workspace}/diff-counted.tmp" "${workspace}/diff-counted.txt"
    if [[ -s "${workspace}/diff_resources_decoded.txt" ]]; then
      arsc_note="resources.arsc: binary differs; decoded res/ differs only in the Crashlytics mapping_file_id; not counted."
    else
      arsc_note="resources.arsc: binary differs; decoded res/ identical; not counted."
    fi
  else
    arsc_note="resources.arsc: decoded res/ differs (see diff_resources_decoded.txt); counted."
  fi
fi

raw_count="$(grep -c . "${workspace}/diff-full.txt" || true)"
excluded_count="$(grep -c . "${workspace}/diff-excluded.txt" || true)"
diff_count="$(grep -c . "${workspace}/diff-counted.txt" || true)"

if [[ "${diff_count}" -eq 0 ]]; then
  verdict="reproducible"; exit_code=0
else
  verdict="not_reproducible"; exit_code=1
fi

print_results "${verdict}"

# Everything below is outside the results block.
echo ""
echo "Diff: raw=${raw_count}, excluded=${excluded_count} (official-only root META-INF signing files), counted=${diff_count}"
echo "Raw diff preview (max 5 lines):"
if [[ "${raw_count}" -gt 0 ]]; then head -n 5 "${workspace}/diff-full.txt"; else echo "(none)"; fi
[[ -n "${arsc_note}" ]] && echo "${arsc_note}"
echo "Full diff: ${workspace}/diff-full.txt (counted: diff-counted.txt)"
echo "Built APK sha256: ${built_hash}"
echo "Git tag ${TAG_REF}: $(head -n 1 "${workspace}/git-tag-verify.txt" 2>/dev/null || echo N/A)"
echo "More detail: diff -r ${workspace}/official-unzipped ${workspace}/built-unzipped"

notes="Built tag ${TAG_REF} with Gradle :mbw:assembleProdnetRelease (fat APK) using upstream's Dockerfile steps
(ubuntu:22.04 by digest, apt snapshot ${APT_SNAPSHOT}, checksummed SDK tools); disorderfs: ${use_disorderfs}.
Compared the unzipped APK with the provided official APK: ${raw_count} raw differences.
Not counted: ${excluded_count} root META-INF signing files (*.SF, *.RSA, *.DSA, *.EC, MANIFEST.MF) present only in the official APK."
[[ -n "${arsc_note}" ]] && notes+=$'\n'"${arsc_note}"
notes+=$'\n'"Counted differences: ${diff_count}."
generate_yaml "${verdict}" "${notes}"

echo ""
echo "Exit code: ${exit_code}"
exit "${exit_code}"
