#!/bin/bash
# ==============================================================================
# phoenixmainnet_build.sh - Phoenix Wallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.10
# Organization:  WalletScrutiny.com
# Last Modified: 2026-07-29
# Project:       https://github.com/ACINQ/phoenix
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/fr.acinq.phoenix.mainnet/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding the security,
# functionality, or fitness for any particular purpose.
#
# SCRIPT SUMMARY:
# - Builds Phoenix Wallet from source inside a fully self-contained Docker container
# - Inline Dockerfile (Ubuntu 24.04, JDK 17, Android SDK) — no host dependencies beyond Docker
# - Compares built APK against official APK via containerized unzip + diff
#   (only JAR signature FILENAMES directly under META-INF are exempt; archive-level
#   structures such as the v2/v3 APK Signing Block are outside this comparison)
# - Generates COMPARISON_RESULTS.yaml
# - Phoenix produces a single universal APK (no architecture splits)
# - Tag/commit signature verification included
# - Pins Phoenix embedded git short hash to 9 characters for ACINQ CI compatibility
# - Runs a clean release-only Gradle build with daemon/cache disabled

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.2.10"
APP_ID="fr.acinq.phoenix.mainnet"
REPO_URL="https://github.com/ACINQ/phoenix.git"

# Build environment. Kept as named constants rather than literals buried in the
# Dockerfile so the toolchain a verification used is visible at the top of the
# script and can be overridden for a rebuild without editing the recipe.
UTILITY_IMAGE="${UTILITY_IMAGE:-ubuntu:24.04}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"
ANDROID_CMDLINETOOLS_FILE="${ANDROID_CMDLINETOOLS_FILE:-commandlinetools-linux-8092744_latest.zip}"
# Must match what the Phoenix source declares (compileSdk/targetSdk). If these
# lag the source, Gradle silently auto-provisions the real ones at build time
# and the "pinned" toolchain is a fiction — v2.8.1 needs Platform 36 and
# Build-Tools 35.0.0 (found in review of the 2.8.1 run).
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-android-36}"
ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-35.0.0}"
JDK_PACKAGE="${JDK_PACKAGE:-openjdk-17-jdk}"

# Tag naming upstream: ACINQ tags Android releases as android-vX.Y.Z.
TAG_PREFIX="${TAG_PREFIX:-android-v}"

# Built APK filename pattern: phoenix-<versionCode>-<versionName>-mainnet-release.apk
BUILT_APK_GLOB="${BUILT_APK_GLOB:-phoenix-*-mainnet-release.apk}"

# Accepted per ABS rule 8 if the build server exports it, but this script makes
# no authenticated GitHub calls: the Phoenix repository is public and is reached
# by git clone, not the API. Recorded here only so its presence is visible.
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"
# COMPARISON_RESULTS.yaml must sit in the same directory as the script
# (docs/script_verifications.md, Results File).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

requested_version=""
requested_arch=""
requested_type=""
apk_path=""
should_cleanup=false

version_name=""
build_arch="universal"
additional_info=""

image_name=""
work_dir=""
container_name=""

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
# YAML generators (defined early so die_failed can call generate_error_yaml)
# ------------------------------------------------------------------------------
generate_error_yaml() {
  local status="$1"
  cat > "${script_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
EOF
}

generate_comparison_yaml() {
  local yaml_verdict="$1"
  local base_pinned="false" utility_pinned="false"
  [[ "${BASE_IMAGE}" == *"@sha256:"* ]] && base_pinned="true"
  [[ "${UTILITY_IMAGE}" == *"@sha256:"* ]] && utility_pinned="true"
  cat > "${script_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${yaml_verdict}
notes: |
  Phoenix Wallet is built using Gradle inside a container based on ${BASE_IMAGE}.
  Container image provenance:
  - base requested: ${base_image_requested:-unset}
  - base resolved: ${BASE_IMAGE} (digest-pinned: ${base_pinned})
  - utility requested: ${utility_image_requested:-unset}
  - utility resolved: ${UTILITY_IMAGE} (digest-pinned: ${utility_pinned})
  - NOT pinned by the above: apt repositories, the Android command-line-tools
    archive, and any SDK packages Gradle provisions during the build.
  Reproducibility hardening applied:
  - git rev-parse --short is pinned to 9 characters across Phoenix Gradle modules
  - Gradle runs release-only after clean with daemon/cache/configuration-cache disabled
  Expected differences (do not affect reproducibility verdict):
  - Regular files named MANIFEST.MF or *.SF / *.RSA / *.DSA / *.EC located DIRECTLY
    under META-INF (JAR signature files). Verified by name AND file type; directories
    and symlinks with matching names are NOT exempt, nor is any nested path.
    The v2/v3 APK Signing Block and ZIP archive metadata are not zip entries and are
    therefore outside this entry-by-entry comparison.
EOF
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
  fix_workspace_ownership "${work_dir:-}"
  # Clean up image on failure
  if [[ -n "${image_name}" ]]; then
    ${CONTAINER_CMD} rmi "${image_name}" >/dev/null 2>&1 || true
  fi
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Container runtime detection
# ------------------------------------------------------------------------------
CONTAINER_CMD=""
if command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
else
  die_failed "Neither docker nor podman is available. Install one to continue."
fi

# ------------------------------------------------------------------------------
# Containerized utility helpers
# ------------------------------------------------------------------------------
# All file operations run inside containers — no host unzip/sha256sum/diff needed.
# Uses ubuntu:24.04 (already cached from the build image) as the utility image.

# Resolve a mutable image tag to its immutable digest and use that for the rest
# of the run. Provenance must not depend on the operator remembering to pass a
# digest by hand: a forgotten override silently downgrades the evidence. If the
# caller already supplied a digest-qualified ref it is honoured untouched; if
# resolution fails (offline, registry down) the run continues on the tag and the
# limitation is recorded rather than hidden.
resolve_image_digest() {
  local ref="$1" digest_ref=""
  if [[ "${ref}" == *"@sha256:"* ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi
  ${CONTAINER_CMD} pull "${ref}" >/dev/null 2>&1 || true
  digest_ref="$(${CONTAINER_CMD} image inspect \
    --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
    "${ref}" 2>/dev/null || true)"
  if [[ "${digest_ref}" == *"@sha256:"* ]]; then
    printf '%s\n' "${digest_ref}"
  else
    printf '%s\n' "${ref}"
  fi
}

container_sha256() {
  local file_path="$1"
  local file_dir file_name
  file_dir="$(dirname "${file_path}")"
  file_name="$(basename "${file_path}")"
  ${CONTAINER_CMD} run --rm \
    -v "${file_dir}:/data:ro" \
    "${UTILITY_IMAGE}" \
    sha256sum "/data/${file_name}" | awk '{print $1}'
}

container_unzip() {
  local zip_path="$1"
  local output_dir="$2"
  local zip_dir zip_name
  zip_dir="$(dirname "${zip_path}")"
  zip_name="$(basename "${zip_path}")"
  # Positional parameter, not interpolation: /output is writable, so a crafted
  # file name executing in this shell could rewrite the extracted tree and thus
  # the verdict.
  ${CONTAINER_CMD} run --rm \
    -v "${zip_dir}:/input:ro" \
    -v "${output_dir}:/output" \
    "${UTILITY_IMAGE}" \
    bash -c 'apt-get update -qq && apt-get install -y -qq unzip >/dev/null 2>&1 && unzip -qq "/input/$1" -d /output' _ "${zip_name}"
}

extract_version_from_apk() {
  local apk="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "${apk}")"
  apk_name="$(basename "${apk}")"
  # The file name is passed as a positional parameter, never interpolated into
  # the command string: a name containing quotes, $(), or backticks would
  # otherwise execute inside the container.
  ${CONTAINER_CMD} run --rm \
    -v "${apk_dir}:/input:ro" \
    "${UTILITY_IMAGE}" \
    bash -c 'apt-get update -qq && apt-get install -y -qq apktool >/dev/null 2>&1 \
      && apktool d -o /tmp/decoded "/input/$1" >/dev/null 2>&1 \
      && grep versionName /tmp/decoded/apktool.yml | sed "s/.*: //;s/'"'"'//g"' _ "${apk_name}"
}

# Extract the official APK's signing certificate using apksigner from the build
# image (build-tools ships it; the utility image has no Android SDK). Prints one
# line: "<cert-sha256>|<DN>|<schemes>". Never fatal — a failure leaves the signer
# fields unset and the run continues, because the signing certificate is evidence
# ABOUT the comparand, not an input to the reproducibility comparison.
# --verbose is required: without it apksigner prints certificate fields but no
# "Verified using ... scheme" lines, so scheme detection would silently yield
# nothing (found in review of v0.2.6).
container_signer_info() {
  local apk="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "${apk}")"
  apk_name="$(basename "${apk}")"
  ${CONTAINER_CMD} run --rm \
    -v "${apk_dir}:/input:ro" \
    -e BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION}" \
    "${image_name}" \
    bash -c '
      set -e
      APKSIGNER="${ANDROID_HOME}/build-tools/${BUILD_TOOLS_VERSION}/apksigner"
      [ -x "${APKSIGNER}" ] || APKSIGNER="$(ls -d ${ANDROID_HOME}/build-tools/*/apksigner 2>/dev/null | head -1)"
      [ -n "${APKSIGNER}" ] && [ -x "${APKSIGNER}" ] || exit 1
      out="$("${APKSIGNER}" verify --verbose --print-certs "/input/$1" 2>/dev/null)" || exit 1
      digest="$(printf "%s" "${out}" | grep -m1 "certificate SHA-256 digest:" | sed "s/.*digest: *//")"
      dn="$(printf "%s" "${out}" | grep -m1 "certificate DN:" | sed "s/.*DN: *//")"
      schemes=""
      printf "%s" "${out}" | grep -qi "v1 scheme (JAR signing): true" && schemes="v1"
      for s in v2 v3 v4; do
        printf "%s" "${out}" | grep -qi "APK Signature Scheme ${s}): true" && schemes="${schemes}${schemes:+,}${s}"
      done
      printf "%s|%s|%s\n" "${digest}" "${dn}" "${schemes}"
    ' _ "${apk_name}" 2>/dev/null || true
}

# Runs diff -qr in a container and PRESERVES its exit status. diff exits 0 when
# the trees are identical and 1 when they differ; anything higher (or a
# container/mount failure) means the comparison did not happen. v0.2.6 sent
# stderr to /dev/null and appended `|| true`, so an infrastructure failure
# produced an empty diff that the caller then read as "no differences" —
# a false reproducible. Status is now returned to the caller, stderr is kept.
container_diff() {
  local dir_a="$1"
  local dir_b="$2"
  ${CONTAINER_CMD} run --rm \
    -v "${dir_a}:/a:ro" \
    -v "${dir_b}:/b:ro" \
    "${UTILITY_IMAGE}" \
    diff -qr /a /b
}

fix_workspace_ownership() {
  local target_dir="${1:-}"
  if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
    return 0
  fi

  if [[ "${CONTAINER_CMD}" == "docker" ]]; then
    ${CONTAINER_CMD} run --rm \
      -v "${target_dir}:/work" \
      "${UTILITY_IMAGE}" \
      chown -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       phoenixmainnet_build.sh - Phoenix Wallet reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk_file> [--version <version>] [OPTIONS]
       ${script_name} --help

       The official APK is REQUIRED. Phoenix ships only through Google Play,
       so there is no public download: supply the artifact extracted from a
       device. Without it no comparison is possible and no verdict is issued.

DESCRIPTION
       Builds Phoenix Wallet from source in a fully self-contained Docker
       container and compares the built APK to an official APK.

       Phoenix is distributed via Google Play only. There is no public APK
       download URL, so the official artifact must be supplied from a device.

OPTIONS
       --binary <file>         REQUIRED. Official APK to verify against.
                                Without it no comparison is possible and the
                                script exits 2.
       --apk <file>            Alias for --binary.
       --version <version>     Optional; auto-detected from the APK when
                                omitted. Example: 2.8.1
       --arch <arch>           Accepted for build server compatibility.
                                Phoenix produces a single universal APK.
       --type <type>           Accepted for build server compatibility.
       --cleanup               Remove temporary files after completion.
       --script-version        Print script version and exit.
       --help                  Show this help and exit.

ENVIRONMENT
       BASE_IMAGE, UTILITY_IMAGE
                               Container images, overridable. Tags are
                                resolved to their immutable digest
                                automatically at run time and the resolved
                                refs are printed; pass an image@sha256:...
                                ref to pin a specific one yourself.

EXIT CODES
       0    Reproducible (differences limited to JAR signature files)
       1    Differences found or build failure
       2    Invalid parameters, or no official APK supplied

EXAMPLES
       ${script_name} --binary /path/to/official-phoenix.apk
       ${script_name} --version 2.8.1 --binary /path/to/official-phoenix.apk
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) requested_version="$2"; shift ;;
    --apk) apk_path="$2"; shift ;;
    --binary) apk_path="$2"; shift ;;
    --arch) requested_arch="$2"; shift ;;
    --type) requested_type="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

if [[ -z "${requested_version}" && -z "${apk_path}" ]]; then
  die_invalid "You must provide --version, or --binary/--apk to auto-detect the version."
fi

# Validate every caller-supplied string that will later become part of a
# filesystem path, an image tag, a git ref, or a command argument. Without this,
# a crafted --version/--arch could traverse out of the workspace root (which is
# removed with rm -rf) or inject shell syntax into the nested container
# commands.
validate_token() {
  local label="$1" value="$2"
  if [[ ! "${value}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die_invalid "${label} contains characters outside [A-Za-z0-9._-]: ${value}"
  fi
  if [[ "${value}" == *".."* ]]; then
    die_invalid "${label} must not contain '..': ${value}"
  fi
}

version_name="${requested_version}"
if [[ -n "${version_name}" ]]; then
  validate_token "--version" "${version_name}"
fi
if [[ -n "${requested_type}" ]]; then
  validate_token "--type" "${requested_type}"
fi

# Architecture: Phoenix is universal, but echo back --arch for YAML compliance
if [[ -n "${requested_arch}" ]]; then
  validate_token "--arch" "${requested_arch}"
  build_arch="${requested_arch}"
  append_info "Architecture '${requested_arch}' accepted for compatibility; Phoenix produces a single universal APK."
fi

if [[ -n "${requested_type}" ]]; then
  append_info "Build type '${requested_type}' accepted for compatibility; Phoenix has a single build type."
fi

# Identify this script in the recording. A cast that does not name the script
# version cannot be tied to the code that produced the result; pair this with a
# pre-run sha256sum of the script itself for full provenance.
log_info "Script: ${script_name} ${SCRIPT_VERSION}"
log_info "App: ${APP_ID}"

# Pin the container images for this run before anything uses them, and record
# what was pinned. Both the requested ref and the resolved one go into the
# recording so the environment can be reconstructed from the cast alone.
base_image_requested="${BASE_IMAGE}"
utility_image_requested="${UTILITY_IMAGE}"
BASE_IMAGE="$(resolve_image_digest "${BASE_IMAGE}")"
UTILITY_IMAGE="$(resolve_image_digest "${UTILITY_IMAGE}")"

if [[ "${BASE_IMAGE}" == *"@sha256:"* ]]; then
  log_info "Base image pinned: ${base_image_requested} -> ${BASE_IMAGE}"
else
  log_warn "Base image NOT pinned (could not resolve a digest for ${base_image_requested}); this run's container provenance is a mutable tag"
  append_info "Base image provenance: mutable tag ${base_image_requested} (digest could not be resolved)."
fi
if [[ "${UTILITY_IMAGE}" == *"@sha256:"* ]]; then
  log_info "Utility image pinned: ${utility_image_requested} -> ${UTILITY_IMAGE}"
else
  log_warn "Utility image NOT pinned (could not resolve a digest for ${utility_image_requested})"
  append_info "Utility image provenance: mutable tag ${utility_image_requested} (digest could not be resolved)."
fi
if [[ "${BASE_IMAGE}" == *"@sha256:"* && "${UTILITY_IMAGE}" == *"@sha256:"* ]]; then
  append_info "Container images pinned by digest: base ${BASE_IMAGE}; utility ${UTILITY_IMAGE}. Note this does not pin apt repositories or the Android command-line-tools archive."
fi

# Resolve APK path to absolute
if [[ -n "${apk_path}" ]]; then
  if [[ "${apk_path}" != /* ]]; then
    apk_path="${execution_dir}/${apk_path}"
  fi
  if [[ ! -f "${apk_path}" ]]; then
    die_invalid "APK file not found: ${apk_path}"
  fi
  log_info "Official APK provided: ${apk_path}"

  # Auto-detect version from APK if --version was not supplied
  if [[ -z "${version_name}" ]]; then
    log_info "No --version provided. Extracting versionName from APK..."
    version_name="$(extract_version_from_apk "${apk_path}")"
    if [[ -z "${version_name}" ]]; then
      die_invalid "Could not extract versionName from APK: ${apk_path}"
    fi
    validate_token "versionName extracted from APK" "${version_name}"
    log_info "Detected versionName: ${version_name}"
    append_info "Version auto-detected from APK: ${version_name}"
  fi
else
  # No comparand means no comparison. Reporting `not_reproducible` here would
  # publish an absence of evidence as evidence of failure, so the run is
  # refused instead (the YAML vocabulary has no "unverified" value).
  log_error "Phoenix is distributed via Google Play only; there is no public APK to download."
  die_invalid "--binary/--apk is required: supply the official APK to verify against. Without it no comparison is possible and no verdict can be issued."
fi

# ------------------------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------------------------
# Unique per run (ABS rule 7): concurrent invocations for the same app/version/
# arch — or different types sharing an arch — must not share or delete each
# other's workspace. mktemp guarantees a fresh directory, so nothing existing is
# ever removed here.
work_dir="$(mktemp -d "${execution_dir}/workdir_${APP_ID}_${version_name}_${build_arch}${requested_type:+_${requested_type}}_XXXXXX")"
mkdir -p "${work_dir}/output"
log_info "Workspace: ${work_dir}"

# Unique container/image names for parallel safety (includes arch for BSA)
image_name="phoenix_build_${version_name}_${build_arch}_$$"
container_name="phoenix_run_${version_name}_${build_arch}_$$"

# ------------------------------------------------------------------------------
# Generate inline Dockerfile
# ------------------------------------------------------------------------------
log_info "Generating Dockerfile..."

cat > "${work_dir}/Dockerfile" <<'DOCKEREOF'
# Values arrive as build args from the script constants; nothing here is a
# literal that would have to be edited to change the toolchain.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG ANDROID_CMDLINETOOLS_FILE
ARG ANDROID_API_LEVELS
ARG ANDROID_BUILD_TOOLS_VERSION
ARG JDK_PACKAGE
ARG REPO_URL

ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV ANDROID_CMDLINETOOLS_FILE=${ANDROID_CMDLINETOOLS_FILE}
ENV ANDROID_CMDLINETOOLS_URL=https://dl.google.com/android/repository/${ANDROID_CMDLINETOOLS_FILE}
ENV ANDROID_API_LEVELS=${ANDROID_API_LEVELS}
ENV ANDROID_BUILD_TOOLS_VERSION=${ANDROID_BUILD_TOOLS_VERSION}
ENV ANDROID_HOME=/usr/local/android-sdk
ENV PATH=${PATH}:${ANDROID_HOME}/tools/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin
ENV JAVA_OPTS="-Dprofile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8 -Dfile.encoding=UTF-8"
ENV GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.caching=false"

RUN apt-get update -y && \
    apt-get install -y software-properties-common locales && \
    locale-gen en_US.UTF-8 && \
    apt-get install -y ${JDK_PACKAGE} wget git unzip dos2unix

RUN mkdir -p /usr/local/android-sdk && \
    cd /usr/local/android-sdk && \
    wget -q ${ANDROID_CMDLINETOOLS_URL} && \
    unzip ${ANDROID_CMDLINETOOLS_FILE} && \
    mv cmdline-tools latest && \
    mkdir cmdline-tools && \
    mv latest cmdline-tools && \
    rm ${ANDROID_CMDLINETOOLS_FILE}

RUN echo y | sdkmanager "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" "platforms;${ANDROID_API_LEVELS}" && \
    yes | sdkmanager --licenses

ARG VERSION_TAG
# CACHEBUST changes every run so the clone layer is never served from cache:
# Docker cannot know the remote moved, and a stale layer would silently verify
# yesterday's source against today's release.
ARG CACHEBUST
RUN echo "cache-bust: ${CACHEBUST}" && git clone ${REPO_URL} /home/ubuntu/phoenix && \
    cd /home/ubuntu/phoenix && \
    git checkout ${VERSION_TAG}

RUN find /home/ubuntu/phoenix -name build.gradle.kts -print0 | \
    xargs -0 sed -i \
      -e 's/--short HEAD/--short=9 HEAD/g' \
      -e 's/"--verify", "--short"/"--verify", "--short=9"/g' && \
    echo "--- patched call sites ---" && \
    grep -R -n -- '--short=9' /home/ubuntu/phoenix/*/build.gradle.kts /home/ubuntu/phoenix/build.gradle.kts && \
    echo "--- residual unpinned short forms (must be none) ---" && \
    ! grep -R -n -E --include=build.gradle.kts -- "--short([^=]|\$)" /home/ubuntu/phoenix

RUN rm -f /home/ubuntu/phoenix/local.properties && \
    find /home/ubuntu/phoenix -type f -print0 | xargs -0 dos2unix -- && \
    chmod +x /home/ubuntu/phoenix/gradlew

WORKDIR /home/ubuntu/phoenix
DOCKEREOF

# ------------------------------------------------------------------------------
# Build Docker image
# ------------------------------------------------------------------------------
tag_name="${TAG_PREFIX}${version_name}"
log_info "Building Docker image '${image_name}' with tag ${tag_name}..."
log_info "This includes cloning the repo and setting up the SDK (~20 min first time)..."

if ! ${CONTAINER_CMD} build \
  --build-arg VERSION_TAG="${tag_name}" \
  --build-arg CACHEBUST="$(date -u +%Y%m%dT%H%M%SZ)" \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  --build-arg ANDROID_CMDLINETOOLS_FILE="${ANDROID_CMDLINETOOLS_FILE}" \
  --build-arg ANDROID_API_LEVELS="${ANDROID_API_LEVEL}" \
  --build-arg ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION}" \
  --build-arg JDK_PACKAGE="${JDK_PACKAGE}" \
  --build-arg REPO_URL="${REPO_URL}" \
  -t "${image_name}" \
  "${work_dir}"; then
  die_failed "Docker image build failed."
fi

log_info "Docker image built successfully."

# Record the toolchain that actually exists in the image. Gradle may still
# auto-provision additional SDK packages during the build; those appear in the
# build log and are part of the recorded evidence.
log_info "Resolved build environment:"
${CONTAINER_CMD} run --rm "${image_name}" bash -c '
  echo "  base: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}")"
  echo "  jdk: $(java -version 2>&1 | head -1)"
  echo "  sdk platforms: $(ls "${ANDROID_HOME}/platforms" 2>/dev/null | tr "\n" " ")"
  echo "  sdk build-tools: $(ls "${ANDROID_HOME}/build-tools" 2>/dev/null | tr "\n" " ")"
' || log_warn "Could not enumerate the resolved build environment"

# ------------------------------------------------------------------------------
# Extract commit hash from inside the image
# ------------------------------------------------------------------------------
commit_hash="$(${CONTAINER_CMD} run --rm "${image_name}" git rev-parse HEAD)"
log_info "Source commit: ${commit_hash}"

# ------------------------------------------------------------------------------
# Build APK inside container
# ------------------------------------------------------------------------------
log_info "Building clean release APK inside container (~10-15 min)..."

if ! ${CONTAINER_CMD} run --rm \
  --name "${container_name}" \
  -v "${work_dir}/output:/output" \
  -w /home/ubuntu/phoenix \
  "${image_name}" \
  bash -c './gradlew --no-daemon --no-build-cache --no-configuration-cache clean :phoenix-android:assembleRelease && cp -r phoenix-android/build/outputs/apk/release/* /output/'; then
  die_failed "Gradle assembleRelease failed inside container."
fi

log_info "Build completed."

# Fix file ownership (Docker creates files as root)
if [[ "${CONTAINER_CMD}" == "docker" ]]; then
  ${CONTAINER_CMD} run --rm \
    -v "${work_dir}:/work" \
    "${UTILITY_IMAGE}" \
    chown -R "$(id -u):$(id -g)" /work/output
fi

# ------------------------------------------------------------------------------
# Find built APK
# ------------------------------------------------------------------------------
built_apk="$(find "${work_dir}/output" -name "${BUILT_APK_GLOB}" -print -quit 2>/dev/null || true)"

if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
  die_failed "Built APK not found in ${work_dir}/output/"
fi

built_apk_name="$(basename "${built_apk}")"
built_hash="$(container_sha256 "${built_apk}")"

log_info "Built APK: ${built_apk_name}"
log_info "Built hash: ${built_hash}"

# ------------------------------------------------------------------------------
# Official APK metadata
# ------------------------------------------------------------------------------
official_hash=""
signer="N/A"
signer_dn=""
signer_schemes=""
version_code="unknown"
app_hash=""

if [[ -n "${apk_path}" ]]; then
  official_hash="$(container_sha256 "${apk_path}")"
  app_hash="${official_hash}"
  log_info "Official APK hash: ${official_hash}"

  # Signing certificate of the OFFICIAL APK. This is evidence about the artifact
  # being compared (who signed it), not about reproducibility; the local build is
  # unsigned by design. Failure is a warning, never fatal.
  signer_line="$(container_signer_info "${apk_path}")"
  signer_digest="${signer_line%%|*}"
  if [[ -n "${signer_digest}" ]]; then
    signer="${signer_digest}"
    signer_rest="${signer_line#*|}"
    signer_dn="${signer_rest%%|*}"
    signer_schemes="${signer_rest#*|}"
    log_info "Official APK signer (certificate SHA-256): ${signer}"
    [[ -n "${signer_dn}" ]] && log_info "Official APK signer DN: ${signer_dn}"
    [[ -n "${signer_schemes}" ]] && log_info "APK signature schemes verified: ${signer_schemes}"
    append_info "Official APK signer certificate SHA-256: ${signer}"
    [[ -n "${signer_dn}" ]] && append_info "Official APK signer DN: ${signer_dn}"
    [[ -n "${signer_schemes}" ]] && append_info "APK signature schemes verified: ${signer_schemes} (v2/v3 signatures live in the APK Signing Block, which is not a zip entry and is therefore outside the entry-by-entry comparison below)"
  else
    log_warn "Could not extract the official APK's signing certificate; signer remains N/A"
    append_info "Signing certificate extraction failed; signer not established by this run."
  fi

  # Extract versionCode from the built APK filename (phoenix-{code}-{version}-mainnet-release.apk)
  version_code="$(echo "${built_apk_name}" | sed -n 's/^phoenix-\([0-9]*\)-.*/\1/p')"
  if [[ -z "${version_code}" ]]; then
    version_code="unknown"
  fi
fi

# ------------------------------------------------------------------------------
# Comparison (fully containerized)
# ------------------------------------------------------------------------------
match_value="false"
verdict_status="not_reproducible"
exit_code="${EXIT_FAILED}"
diff_output=""

from_official="${work_dir}/from_official"
from_built="${work_dir}/from_built"

if [[ -n "${apk_path}" ]]; then
  if [[ "${built_hash}" == "${official_hash}" ]]; then
    log_info "Hashes match exactly — APK is reproducible."
    match_value="true"
    verdict_status="reproducible"
    exit_code="${EXIT_SUCCESS}"
  else
    log_info "Hashes differ. Performing containerized unzip + diff analysis..."

    mkdir -p "${from_official}" "${from_built}"

    container_unzip "${apk_path}" "${from_official}"
    container_unzip "${built_apk}" "${from_built}"

    # Fix permissions so diff containers can read extracted APK contents.
    if [[ "${CONTAINER_CMD}" == "docker" ]]; then
      ${CONTAINER_CMD} run --rm \
        -v "${from_official}:/d1" -v "${from_built}:/d2" \
        "${UTILITY_IMAGE}" \
        bash -c 'chmod -R a+r /d1 /d2'
    fi

    # Preserve diff's exit status: 0 = identical, 1 = differences found, >1 =
    # the comparison itself failed. An infrastructure failure must never be read
    # as "no differences".
    diff_status=0
    diff_output="$(container_diff "${from_official}" "${from_built}")" || diff_status=$?
    if (( diff_status > 1 )); then
      die_failed "Comparison failed to run (diff/container exit ${diff_status}); no verdict can be derived."
    fi

    # Remap container paths to host paths for readable output
    diff_display="$(echo "${diff_output}" | sed "s|/a/|${from_official}/|g; s|/b/|${from_built}/|g")"

    # Classify each diff line: is it an expected publisher-signature artifact?
    #
    # History of this check, each version unsound in a different way:
    #   v0.2.5  `grep -vE 'META-INF'` — matched that substring anywhere in a
    #           path (Leo, 2025-10-30), so assets/x/META-INF/ was exempt too.
    #   v0.2.6  anchored to root META-INF but was a DIRECTORY-prefix rule, so
    #           any arbitrary file in root META-INF, a whole one-sided META-INF
    #           subtree, and descendants like META-INF/services/* were exempt.
    #   v0.2.7  filename whitelist — but `diff -qr` prints the same
    #           "Only in <dir>: NAME" line for a file, a directory, and a
    #           symlink. A one-sided DIRECTORY named EVIL.RSA therefore matched
    #           the whitelist and its contents were never enumerated.
    #
    # So the name is necessary but not sufficient: each candidate is resolved
    # back to the extracted tree and must be a REGULAR, NON-SYMLINK file.
    # Anything else — directory, symlink, missing, unexpected name, nested
    # path — is a real difference. False-fail is preferred to false-pass.
    sig_name_re='^(MANIFEST\.MF|[A-Za-z0-9_.-]+\.(SF|RSA|DSA|EC))$'

    is_signature_artifact() {
      local line="$1" side name root path n1 n2
      if [[ "${line}" =~ ^Only\ in\ /([ab])/META-INF:\ (.+)$ ]]; then
        side="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"
        [[ "${name}" =~ ${sig_name_re} ]] || return 1
        if [[ "${side}" == "a" ]]; then root="${from_official}"; else root="${from_built}"; fi
        path="${root}/META-INF/${name}"
        # Regular file only: a directory or symlink with a signature-looking
        # name would otherwise hide everything beneath it.
        [[ -f "${path}" && ! -L "${path}" ]] || return 1
        return 0
      fi
      if [[ "${line}" =~ ^Files\ /a/META-INF/(.+)\ and\ /b/META-INF/(.+)\ differ$ ]]; then
        n1="${BASH_REMATCH[1]}"; n2="${BASH_REMATCH[2]}"
        [[ "${n1}" == "${n2}" ]] || return 1
        [[ "${n1}" =~ ${sig_name_re} ]] || return 1
        [[ -f "${from_official}/META-INF/${n1}" && ! -L "${from_official}/META-INF/${n1}" ]] || return 1
        [[ -f "${from_built}/META-INF/${n2}"   && ! -L "${from_built}/META-INF/${n2}"   ]] || return 1
        return 0
      fi
      return 1
    }

    filtered_diff=""
    ignored_diff=""
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      if is_signature_artifact "${line}"; then
        ignored_diff="${ignored_diff}${ignored_diff:+$'\n'}${line}"
      else
        filtered_diff="${filtered_diff}${filtered_diff:+$'\n'}${line}"
      fi
    done <<< "${diff_output}"

    # Both sets are printed, so the recording shows exactly what was set aside
    # and on what basis — the classification is auditable from the cast alone.
    echo "[INFO] Raw comparison output (unfiltered):"
    if [[ -n "$(echo "${diff_output}" | tr -d '[:space:]')" ]]; then
      echo "${diff_output}"
    else
      echo "(none — extracted trees are identical)"
    fi

    if [[ -n "$(echo "${ignored_diff}" | tr -d '[:space:]')" ]]; then
      log_info "Accepted as publisher signature artifacts (whitelisted filenames directly under META-INF):"
      echo "${ignored_diff}"
    fi

    if [[ -z "$(echo "${filtered_diff}" | tr -d '[:space:]')" ]]; then
      log_info "No differences outside the whitelisted signature files — APK is reproducible."
      match_value="true"
      verdict_status="reproducible"
      exit_code="${EXIT_SUCCESS}"
      append_info "Differences limited to JAR signature files directly under META-INF (MANIFEST.MF, *.SF, *.RSA/DSA/EC), expected for an unsigned local build. Nested paths, unexpected files in META-INF, and whole-directory absences are NOT exempt. The comparison covers the extracted file tree only: the APK Signing Block (v2/v3) and ZIP archive metadata are not zip entries and are outside its reach."
    else
      log_warn "Differences outside the signature whitelist:"
      echo "${filtered_diff}"
      match_value="false"
      verdict_status="not_reproducible"
      exit_code="${EXIT_FAILED}"
    fi
  fi
else
  log_warn "No official APK — skipping comparison."
  append_info "No official APK provided for comparison. Phoenix is distributed via Google Play only (no public APK download). Hash of built APK recorded."
  verdict_status="not_reproducible"
  match_value="false"
  exit_code="${EXIT_FAILED}"
fi

# ------------------------------------------------------------------------------
# Generate COMPARISON_RESULTS.yaml
# ------------------------------------------------------------------------------
generate_comparison_yaml "${verdict_status}"

# ------------------------------------------------------------------------------
# Tag/commit signature verification (containerized)
# ------------------------------------------------------------------------------
tag_type="unknown"
tag_signature_status="[INFO] Not checked"
commit_signature_status="[WARNING] No valid signature found on commit"
tag_ref="${tag_name}"

tag_verify_output="$(${CONTAINER_CMD} run --rm "${image_name}" \
  bash -c "
    TAG_TYPE=\$(git cat-file -t 'refs/tags/${tag_ref}' 2>/dev/null || echo 'missing')
    echo \"TAG_TYPE=\${TAG_TYPE}\"
    if [ \"\${TAG_TYPE}\" = 'tag' ]; then
      git tag -v '${tag_ref}' 2>&1 || true
    elif [ \"\${TAG_TYPE}\" = 'commit' ]; then
      echo 'LIGHTWEIGHT_TAG'
    else
      echo 'NO_TAG'
    fi
    echo '---COMMIT---'
    if git cat-file commit HEAD | grep -q '^gpgsig'; then
      echo 'COMMIT_HAS_GPGSIG'
    else
      echo 'COMMIT_NO_GPGSIG'
    fi
    git verify-commit HEAD 2>&1 || true
  " 2>&1 || true)"

# Parse tag info
if echo "${tag_verify_output}" | grep -q "TAG_TYPE=tag"; then
  tag_type="annotated"
  if echo "${tag_verify_output}" | grep -q "Good signature"; then
    tag_signature_status="[OK] Good signature on annotated tag"
  else
    tag_signature_status="[WARNING] Annotated tag exists but signature could not be verified"
  fi
elif echo "${tag_verify_output}" | grep -q "LIGHTWEIGHT_TAG"; then
  tag_type="lightweight"
  tag_signature_status="[INFO] Tag is lightweight (cannot contain signature)"
elif echo "${tag_verify_output}" | grep -q "TAG_TYPE=missing"; then
  tag_type="missing"
  tag_signature_status="[WARNING] Tag ${tag_ref} not found"
fi

# Parse commit info. "Signed but we lack the key" is NOT "unsigned" — reporting
# them identically previously led to a published claim that a signed commit had
# no signature. Each state is distinguished and the raw verifier output is kept.
commit_section="$(echo "${tag_verify_output}" | sed -n '/---COMMIT---/,$p')"
if echo "${commit_section}" | grep -q "Good signature"; then
  commit_signature_status="[OK] Good signature on commit"
elif echo "${commit_section}" | grep -q "BAD signature"; then
  commit_signature_status="[ERROR] BAD signature on commit"
elif echo "${commit_section}" | grep -q "COMMIT_HAS_GPGSIG"; then
  if echo "${commit_section}" | grep -qi "No public key\|Can't check signature"; then
    commit_signature_status="[WARNING] Commit IS signed, but the signing key is not available in this environment — signature not validated (this is not an unsigned commit)"
  else
    commit_signature_status="[WARNING] Commit IS signed; signature could not be validated here"
  fi
elif echo "${commit_section}" | grep -q "COMMIT_NO_GPGSIG"; then
  commit_signature_status="[INFO] Commit carries no OpenPGP signature"
else
  commit_signature_status="[WARNING] Commit signature state could not be determined"
fi

# Raw verifier output belongs in the cast: a summary line is an interpretation,
# and the reader must be able to check it.
echo "[INFO] Raw tag/commit verification output:"
echo "${tag_verify_output}"

# ------------------------------------------------------------------------------
# Verification summary output
# ------------------------------------------------------------------------------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict_status}"
echo "appHash:        ${app_hash:-${built_hash}}"
echo "commit:         ${commit_hash}"
echo ""

if [[ -n "${diff_display:-}" ]]; then
  echo "Diff:"
  echo "${diff_display}"
  echo ""
elif [[ -n "${diff_output}" ]]; then
  echo "Diff:"
  echo "${diff_output}"
  echo ""
elif [[ "${match_value}" == "true" ]]; then
  echo "Diff: (none — hashes match)"
  echo ""
else
  echo "Diff: (no comparison performed — no official APK provided)"
  echo ""
fi

echo "Revision, tag (and its signature):"
echo "Tag type: ${tag_type}"
echo "${tag_signature_status}"
echo "${commit_signature_status}"

if [[ -n "${additional_info}" ]]; then
  echo ""
  echo "===== Also ====="
  echo -e "${additional_info}"
fi

echo ""
echo "===== End Results ====="

# Diff command hints (when workspace is preserved)
if [[ "${should_cleanup}" != true && -d "${from_official:-/nonexistent}" && -d "${from_built:-/nonexistent}" ]]; then
  echo ""
  echo "Run a full"
  echo "diff --recursive ${from_official} ${from_built}"
  echo "meld ${from_official} ${from_built}"
  echo "for more details."
fi

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
log_info "Removing Docker image: ${image_name}"
${CONTAINER_CMD} rmi "${image_name}" >/dev/null 2>&1 || true

fix_workspace_ownership "${work_dir}"

if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
  log_info "Workspace cleaned up."
else
  log_info "Workspace preserved: ${work_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
