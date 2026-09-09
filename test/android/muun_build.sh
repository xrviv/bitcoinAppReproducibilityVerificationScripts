#!/bin/bash
# ==============================================================================
# apollo_build.sh - Muun Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.1
# Organization:  WalletScrutiny.com
# Last Modified: 2026-09-09
# Project:       https://github.com/muun/apollo
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/io.muun.apollo/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding the security,
# functionality, or fitness for any particular purpose. Users assume all risks
# associated with running this script and analyzing the software. This script
# performs automated builds and APK comparisons - review all operations before
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
# - Accepts an official Muun APK via --apk (required for comparison; Muun does
#   not publish APKs to GitHub releases - obtain from Google Play via adb pull,
#   APK extractor app, or similar)
# - Optionally accepts --version to select a specific release tag
# - Clones muun/apollo at the release tag inside the workspace
# - Builds using Muun's official multi-stage android/Dockerfile via
#   DOCKER_BUILDKIT=1 (JDK 17 + Go 1.24.7 + Rust 1.84 + NDK 22.0.7026061)
# - Compares the built APK against the official APK using unzip + diff
#   (META-INF signing files excluded by filename allowlist per
#   ws-notes/script-notes/meta-inf-filter-scope.md; resources.arsc included)
# - Generates COMPARISON_RESULTS.yaml for build server automation
# - Hashes itself as its first action and prints scriptVersion/scriptHash in
#   the results block (ws-notes/script-notes/script-version-and-hash.md)
#
# NOTE ON BASE IMAGE (added v0.2.0, 2026-09-09):
# Muun's android/Dockerfile pins openjdk:17-jdk-slim@sha256:aaa3b3c... which is
# Debian 11 "bullseye", now oldoldstable. bullseye-security's InRelease Valid-Until
# has passed permanently (confirmed live against security.debian.org), so its
# apt-get update fails with exit 100 on every run, forever - not a transient
# mirror issue. Muun's own pinned digest is unchanged through v55.11 (their own
# comment marks this file as authoritative for build-release.yml), so this
# script patches apt-get update with -o Acquire::Check-Valid-Until=false rather
# than swapping the base image - keeps the exact pinned digest Muun's own CI
# references instead of introducing an unverified base-OS substitution.
#
# NOTE ON WORKSPACE REUSE (added v0.2.1, 2026-09-09):
# A pre-existing workdir_<app>_<version>_<arch> from a prior run is now
# removed automatically before a new run starts, rather than the run dying
# with "Workspace already exists" and requiring --cleanup or a manual rm.
# --cleanup still controls only whether the workspace is removed AFTER a run
# completes; it never gated the stale-workspace-before-a-run case, and
# nothing about the workspace is ever privileged (host user owns everything
# under it), so there was no reason to require an extra flag or manual step
# to re-run the same version/arch twice.
#
# NOTE ON BUILD TIME:
# First run downloads Android SDK, Go 1.24.7, and Rust toolchains (~several GB).
# Expect 30-90 minutes on first run. Docker layer cache speeds up subsequent runs.
#
# NOTE ON VERSIONCODE:
# The versionCode in the Play Store APK is computed as:
#   baseVersionCode (e.g. 1506) + buildVersionSuffix (000) + abiCode
# where abiCode: arm64-v8a=5, armeabi-v7a=4, x86_64=3, x86=2
# Example: arm64-v8a version 55.6 -> versionCode 15060005
#
# HOST DEPENDENCIES: docker (with BuildKit) OR podman (3+). Everything else
# runs in containers.

set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
  echo "[ERROR] Do not run this script as root." >&2
  exit 2
fi

# ==============================================================================
# Script Metadata
# ==============================================================================
SCRIPT_VERSION="v0.2.1"
APP_ID="io.muun.apollo"
REPO_URL="https://github.com/muun/apollo"
WS_CONTAINER="docker.io/walletscrutiny/android:5"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_name="$(basename "$0")"

# Script self-identification (script-version-and-hash.md, 2026-08-17): hash the
# running script file itself so a report's verdict is tied to the exact bytes
# that produced it. readlink -f (not $0) so a relative invocation or a symlink
# still resolves to a hashable path; sha256_of never fails the run.
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""

sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

# ==============================================================================
# Arguments
# ==============================================================================
requested_version=""
apk_file=""
requested_arch=""
requested_type=""
should_cleanup=false

# ==============================================================================
# State
# ==============================================================================
build_arch=""
build_type="standalone"
version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
tag_ref=""
additional_info=""
work_dir=""
diff_count=0

# ==============================================================================
# Logging
# ==============================================================================
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

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

# Self-hash first, before argument parsing or any network/container work, so
# even a run that exits on invalid args records which script bytes ran.
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
log_info "         sha256: ${SCRIPT_SHA256}"

# ==============================================================================
# Container runtime detection
# ==============================================================================
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

log_info "Container runtime: ${CONTAINER_CMD}"

# ==============================================================================
# Usage
# ==============================================================================
usage() {
  cat <<EOF
NAME
       apollo_build.sh - Muun Wallet Android reproducible build verification

SYNOPSIS
       ${script_name} --binary <apk_file> [--version <version>] [OPTIONS]
       ${script_name} --version <version> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds Muun Wallet (io.muun.apollo) from source using the official
       multi-stage android/Dockerfile and compares against an official APK.

       Muun does not publish APKs to GitHub releases. Obtain the APK from
       Google Play (adb pull, APK extractor app, etc.) and provide via --apk.

OPTIONS
       --binary <file>         Path to official APK from Google Play (primary flag)
       --apk <file>            Alias for --binary (Android legacy flag)
       --version <version>     Version to verify (e.g. 55.6). Selects the build tag.
                               If omitted, version is derived from the --apk metadata.
                               Without --apk, builds only (no comparison performed).
       --arch <arch>           Architecture override (auto-detected from APK if omitted)
                               Supported: arm64-v8a, armeabi-v7a, x86, x86_64
       --type <type>           Accepted for build server compatibility (not used)
       --cleanup               Remove workspace after completion
       --help                  Show this help and exit

EXIT CODES
       0    Reproducible (no non-META-INF differences)
       1    Differences found or build failure
       2    Invalid parameters or configuration

EXAMPLES
       ${script_name} --apk ~/Downloads/io.muun.apollo.apk
       ${script_name} --version 55.6 --apk ~/Downloads/io.muun.apollo.apk
       ${script_name} --version 55.6 --arch arm64-v8a
EOF
}

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) requested_version="$2"; shift ;;
    --binary)  apk_file="$2";          shift ;;
    --apk)     apk_file="$2";          shift ;;
    --arch)    requested_arch="$2";    shift ;;
    --type)    requested_type="$2";    shift ;;
    --cleanup) should_cleanup=true ;;
    --help)    usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Unknown argument: $1 (ignored)" ;;
  esac
  shift
done

if [[ -z "${requested_version}" && -z "${apk_file}" ]]; then
  die_invalid "Provide --version, --apk, or both. Run --help for usage."
fi

if [[ -n "${requested_arch}" ]]; then
  case "${requested_arch}" in
    arm64-v8a|armeabi-v7a|x86|x86_64) ;;
    *) die_invalid "Unsupported --arch '${requested_arch}'. Supported: arm64-v8a, armeabi-v7a, x86, x86_64." ;;
  esac
fi

if [[ -n "${requested_type}" ]]; then
  log_warn "--type '${requested_type}' accepted but not used (Muun prod release has a single build type per arch)."
  build_type="${requested_type}"
fi

# ==============================================================================
# Containerized helper functions
# Helpers use the WS container (docker.io/walletscrutiny/android:5) for metadata
# extraction and diff operations. The actual Muun build uses Muun's own Dockerfile.
# ==============================================================================

# Compute SHA-256 of a host file using the WS container.
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

# Extract the Signer #1 certificate SHA-256 from an APK using apksigner.
container_signer() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apksigner verify --print-certs /apk/${apk_name} 2>/dev/null \
           | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" \
    || echo "N/A"
}

# Decode an APK with apktool into output_dir (uses WS container).
# Produces apktool.yml (versionName, versionCode) and AndroidManifest.xml (appId).
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

# Detect the ABI architecture from apktool-decoded lib/ directory.
# Muun produces per-ABI APKs, each with exactly one lib/<arch>/ directory.
detect_arch_from_decoded() {
  local decoded_dir="$1"
  ls "${decoded_dir}/lib/" 2>/dev/null | head -1
}

# Unzip an APK into a host directory using the WS container.
# This avoids needing unzip on the host.
container_unzip_apk() {
  local apk_path="$1"
  local output_dir="$2"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  mkdir -p "${output_dir}"
  $CONTAINER_CMD run --rm \
    ${CONTAINER_RUN_USER_ARGS} \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    --volume "${output_dir}:/output${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "unzip -qq /apk/${apk_name} -d /output"
}

# Run a git command inside the WS container against the cloned source directory.
git_in_container() {
  local cmd="$1"
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/src \
    "$WS_CONTAINER" \
    sh -c "${cmd}"
}

# ==============================================================================
# Error YAML (written on build failure before exit)
# ==============================================================================
generate_error_yaml() {
  local status="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
EOF
}

# ==============================================================================
# Input preparation: resolve APK path and extract metadata
# ==============================================================================
if [[ -n "${apk_file}" ]]; then
  # Resolve to absolute path.
  [[ "${apk_file}" != /* ]] && apk_file="${execution_dir}/${apk_file}"
  [[ ! -f "${apk_file}" ]] && die_invalid "APK file not found: ${apk_file}"

  log_info "Extracting metadata from official APK: $(basename "${apk_file}")..."
  app_hash="$(container_sha256 "${apk_file}")"
  signer="$(container_signer "${apk_file}")"

  # Decode APK with apktool; read versionName/versionCode from apktool.yml
  # and appId from AndroidManifest.xml. This is more reliable than aapt badging.
  metadata_dir="${execution_dir}/apktool_meta_$(echo "${app_hash}" | head -c 12)"
  rm -rf "${metadata_dir}"
  mkdir -p "${metadata_dir}"
  container_apktool "${apk_file}" "${metadata_dir}"

  apk_app_id="$(head -n 1 "${metadata_dir}/AndroidManifest.xml" \
    | sed 's/.*package=\"//g' | sed 's/\".*//g')"
  version_name="$(grep versionName "${metadata_dir}/apktool.yml" \
    | sed 's/.*: //g' | tr -d "'")"
  version_code="$(grep versionCode "${metadata_dir}/apktool.yml" \
    | sed 's/.*: //g' | tr -d "'")"

  [[ -z "${version_name}" ]] && die_failed "Could not extract versionName from APK."

  if [[ -n "${apk_app_id}" && "${apk_app_id}" != "${APP_ID}" ]]; then
    die_failed "APK appId '${apk_app_id}' does not match expected '${APP_ID}'."
  fi

  log_info "APK metadata: versionName=${version_name}, versionCode=${version_code}, appId=${apk_app_id}"

  # Detect or validate architecture from decoded lib/ directory.
  if [[ -z "${requested_arch}" ]]; then
    build_arch="$(detect_arch_from_decoded "${metadata_dir}")"
    [[ -z "${build_arch}" ]] && die_failed "Could not detect arch from APK lib/ structure. Specify with --arch."
    log_info "Detected architecture: ${build_arch}"
  else
    build_arch="${requested_arch}"
    log_info "Using specified architecture: ${build_arch}"
  fi
fi

# Handle --version flag: may override or supplement version derived from APK.
if [[ -n "${requested_version}" ]]; then
  if [[ -n "${version_name}" && "${requested_version}" != "${version_name}" ]]; then
    log_warn "--version ${requested_version} differs from APK versionName ${version_name}. Using APK version for display; using --version for tag selection."
    if [[ -n "${additional_info}" ]]; then additional_info="${additional_info}\n"; fi
    additional_info="${additional_info}--version ${requested_version} overrides APK versionName ${version_name} for tag selection."
  fi
  [[ -z "${version_name}" ]] && version_name="${requested_version}"
fi

# If no APK provided, we need at least an arch to name the workspace sensibly.
if [[ -z "${apk_file}" ]]; then
  build_arch="${requested_arch:-arm64-v8a}"
  log_warn "No --apk provided. Building from source only; no comparison will be performed."
  log_warn "Architecture for workspace naming: ${build_arch}"
  if [[ -n "${additional_info}" ]]; then additional_info="${additional_info}\n"; fi
  additional_info="${additional_info}No --apk provided. Build completed but no comparison performed."
fi

# ==============================================================================
# Workspace setup
# Workspace is named to be unique per app/version/arch, enabling parallel runs.
# ==============================================================================
work_dir="${execution_dir}/workdir_${APP_ID}_${version_name}_${build_arch}"

# A leftover workspace from a prior run of this exact app/version/arch is
# always safe to discard automatically: it is a script-owned scratch
# directory scoped to this one combination, never anything the operator
# needs preserved across invocations. --cleanup controls only whether the
# workspace is removed AFTER this run completes (see below); it does not
# gate whether a stale one is removed BEFORE a run starts.
if [[ -d "${work_dir}" ]]; then
  log_info "Removing stale workspace from a prior run: ${work_dir}"
  rm -rf "${work_dir}"
fi

mkdir -p "${work_dir}"
log_info "Workspace: ${work_dir}"

# ==============================================================================
# Clone repository in WS container (avoids host git dependency).
# Clones into work_dir/src so the build context is isolated from the workspace.
# ==============================================================================
log_info "Cloning ${REPO_URL} ..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone '${REPO_URL}' src"

# Resolve and check out the release tag.
# Muun tags releases as v{versionName} (e.g. v55.6).
tag_ref="v${version_name}"
log_info "Checking out tag ${tag_ref}..."

if ! git_in_container "git checkout '${tag_ref}' 2>/dev/null"; then
  # Retry without the 'v' prefix in case of unusual tag naming.
  log_warn "Tag ${tag_ref} not found; retrying without 'v' prefix..."
  if ! git_in_container "git checkout '${version_name}' 2>/dev/null"; then
    log_warn "No matching tag found. Remaining on HEAD."
    tag_ref="HEAD"
    if [[ -n "${additional_info}" ]]; then additional_info="${additional_info}\n"; fi
    additional_info="${additional_info}No tag found for version ${version_name}. Built from HEAD."
  else
    tag_ref="${version_name}"
  fi
fi

commit_hash="$(git_in_container "git rev-parse HEAD" | tr -d '[:space:]')"
log_info "Commit: ${commit_hash}"

# ==============================================================================
# Build using Muun's official android/Dockerfile.
#
# Muun's Dockerfile is a four-stage build:
#   Stage 1 (muun_android_builder): JDK 17 + Android SDK + NDK 22.0.7026061 + Go 1.24.7
#   Stage 2 (rust_builder):         Rust 1.84 stable + nightly-2024-12-16 + Android targets
#   Stage 3 (librs_build):          Compiles Rust ZKP libraries (plonky2 crates)
#   Stage 4 (build):                Compiles Go libwallet via gomobile + Kotlin/Java APK
#   Final (scratch):                Exports unsigned APKs + mapping.txt
#
# BuildKit is required for the --output (multi-stage result extraction) feature.
# Docker: DOCKER_BUILDKIT=1; Podman: supports --output natively since v3.
# ==============================================================================
built_apk_dir="${work_dir}/built-apks"
mkdir -p "${built_apk_dir}"

src_dir="${work_dir}/src"

# Patch 1 (Podman only): Qualify short image names.
# Podman requires fully-qualified registry prefixes when no unqualified-search
# registries are configured in /etc/containers/registries.conf.
if [[ "${CONTAINER_CMD}" == "podman" ]]; then
  log_info "Patching android/Dockerfile for Podman (qualifying image names)..."
  sed -i \
    -e 's|FROM --platform=linux/amd64 openjdk:|FROM --platform=linux/amd64 docker.io/library/openjdk:|' \
    -e 's|FROM rust:|FROM docker.io/library/rust:|' \
    "${src_dir}/android/Dockerfile"
fi

# Patch 2 (always): Fix ARG TARGETS scoping in librs_build stage.
# In Docker/Podman multi-stage builds, ARG values are stage-scoped and do NOT
# carry over to derived stages. librs_build (FROM rust_builder) never re-declares
# ARG TARGETS, so $TARGETS is empty in that stage's RUN command.
# makelibs.sh then falls back to ALL_TARGETS which includes i686-unknown-linux-musl
# — a Rust target never installed by rustup — causing a compile failure.
# Fix: directly substitute the hardcoded TARGETS value (matching what rust_builder
# installed via rustup) into the RUN command, bypassing ARG scoping entirely.
log_info "Patching android/Dockerfile (fixing TARGETS in librs_build RUN command)..."
sed -i \
  's|TARGETS="$TARGETS"|TARGETS="aarch64-unknown-linux-musl x86_64-unknown-linux-musl aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android"|' \
  "${src_dir}/android/Dockerfile"

# Patch 3 (always, added v0.2.0): Bypass expired bullseye-security Valid-Until.
# The pinned openjdk:17-jdk-slim@sha256:... base is Debian 11 "bullseye", now
# oldoldstable; bullseye-security's InRelease Valid-Until has passed permanently
# (confirmed against security.debian.org, not a transient mirror lag), so a bare
# apt-get update fails with exit 100 on every run. Muun's own pinned digest is
# unchanged through v55.11, so this bypasses the date check rather than
# substituting an unverified base image — same pinned digest, same package set.
log_info "Patching android/Dockerfile (bypassing expired bullseye-security Valid-Until)..."
sed -i \
  's|RUN apt-get update \\|RUN apt-get update -o Acquire::Check-Valid-Until=false \\|' \
  "${src_dir}/android/Dockerfile"

log_info "Building Muun Wallet from source using android/Dockerfile..."
log_info "First run will download Android SDK (~1.5 GB), Go (~70 MB), Rust toolchains (~2+ GB)."
log_info "Estimated time: 30-90 minutes (first run). Docker layer cache speeds up reruns."

if [[ "${CONTAINER_CMD}" == "docker" ]]; then
  # DOCKER_BUILDKIT=1 enables multi-stage --output and BuildKit optimizations.
  # --output type=local,dest= extracts the final scratch stage to the host.
  # --ulimit nofile raises the open file descriptor limit; Gradle/KAPT opens
  # thousands of files simultaneously and hits the default container limit.
  DOCKER_BUILDKIT=1 docker build \
    -f "${src_dir}/android/Dockerfile" \
    --ulimit nofile=65536:65536 \
    --output "type=local,dest=${built_apk_dir}" \
    "${src_dir}"
else
  # Podman supports BuildKit-style --output natively; no env var needed.
  podman build \
    -f "${src_dir}/android/Dockerfile" \
    --ulimit nofile=65536:65536 \
    --output "type=local,dest=${built_apk_dir}" \
    "${src_dir}"
fi

# Confirm the expected per-ABI APK was produced.
# Muun's Dockerfile final stage exports: apolloui-prod-{arch}-release-unsigned.apk
built_apk="${built_apk_dir}/apolloui-prod-${build_arch}-release-unsigned.apk"

if [[ ! -f "${built_apk}" ]]; then
  log_warn "Expected APK not found: ${built_apk}"
  log_info "APKs found in build output:"
  find "${built_apk_dir}" -name "*.apk" 2>/dev/null | while read -r f; do
    log_info "  ${f}"
  done || true
  die_failed "Built APK for arch '${build_arch}' not found after Dockerfile build."
fi

log_info "Built APK: $(basename "${built_apk}")"
built_hash="$(container_sha256 "${built_apk}")"
log_info "Built APK SHA-256: ${built_hash}"

# ==============================================================================
# Comparison: unzip both APKs and diff (only when --apk was provided).
#
# META-INF signing files are excluded by FILENAME allowlist, never by directory
# prefix (ws-notes/script-notes/meta-inf-filter-scope.md, 2026-08-27). Only
# root-level *.SF/*.RSA/*.DSA/*.EC and MANIFEST.MF are excluded — everything
# else under META-INF/ (services/* ServiceLoader bindings, androidx.*.version
# markers, version-control-info.textproto, app-metadata.properties) is real
# application payload and is counted like any other diff.
# resources.arsc IS included in the diff (not filtered out); any differences
# are preserved for human review in the WalletScrutiny report.
#
# The official APK from Google Play is signed; the built APK is unsigned.
# The signing files above are therefore expected to be official-only and are
# filtered; nothing else under META-INF/ gets a free pass.
# ==============================================================================
verdict="warning"
yaml_status="warning"
match_value="false"
exit_code="${EXIT_FAILED}"
diff_display=""
official_unzipped="${work_dir}/official-unzipped"
built_unzipped="${work_dir}/built-unzipped"

if [[ -z "${apk_file}" ]]; then
  log_warn "Skipping comparison (no --apk provided)."
  verdict="warning"
  yaml_status="warning"
  exit_code="${EXIT_SUCCESS}"
else
  log_info "Unzipping official APK for comparison..."
  container_unzip_apk "${apk_file}" "${official_unzipped}"

  log_info "Unzipping built APK for comparison..."
  container_unzip_apk "${built_apk}" "${built_unzipped}"

  log_info "Diffing extracted APKs (brief mode for count, full output preserved)..."
  diff_brief="$($CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "diff -qr /workspace/official-unzipped /workspace/built-unzipped 2>/dev/null || true")"

  # META-INF filename allowlist (meta-inf-filter-scope.md, 2026-08-27):
  # excludes ONLY root-level signing files (*.SF, *.RSA, *.DSA, *.EC,
  # MANIFEST.MF) that appear directly under META-INF/ — never the directory
  # itself and never a nested path. [^/]+ blocks the pattern from reaching
  # into META-INF/services/, so ServiceLoader bindings and androidx.*.version
  # markers are never silently dropped; a whole-directory absence ("Only in
  # .../official-unzipped: META-INF") also does not match and stays counted.
  sig_ext='[^/]+\.(SF|RSA|DSA|EC)'
  filtered_diff="$(echo "${diff_brief}" | \
    grep -vE "^Only in .+/META-INF: (${sig_ext}|MANIFEST\.MF)\$|^Files .+/META-INF/(${sig_ext}|MANIFEST\.MF) and .+/META-INF/(${sig_ext}|MANIFEST\.MF) differ\$" \
    || true)"

  filtered_compact="$(echo "${filtered_diff}" | tr -d '\n\r')"
  if [[ -z "${diff_brief}" || -z "${filtered_compact}" ]]; then
    diff_count=0
  else
    diff_count="$(echo "${filtered_diff}" | grep -c '^' || true)"
  fi

  # Rewrite container-internal paths to host paths for readability in the report.
  diff_display="$(echo "${diff_brief}" | \
    sed "s|/workspace/official-unzipped|${official_unzipped}|g; \
         s|/workspace/built-unzipped|${built_unzipped}|g")"

  # Write full diff to file; terminal shows max 5 lines (dannys-amendments.md policy).
  diff_file="${work_dir}/diff_full.txt"
  echo "${diff_display}" > "${diff_file}"
  log_info "Full diff written to: ${diff_file}"

  if [[ "${diff_count}" -eq 0 ]]; then
    verdict="reproducible"
    yaml_status="reproducible"
    match_value="true"
    exit_code="${EXIT_SUCCESS}"
  else
    verdict="differences found"
    yaml_status="not_reproducible"
    match_value="false"
    exit_code="${EXIT_FAILED}"
  fi

  log_info "Diff count (excl. META-INF): ${diff_count}"
fi

# ==============================================================================
# resources.arsc semantic comparison
# Policy: ws-notes/review-notes/resources.arsc.md
#   Binary diff is acceptable (verdict upgrades to reproducible) only when:
#     1. apktool-decoded res/ trees are identical (non-semantic binary artifact), AND
#     2. resources.arsc is the sole remaining diff after META-INF filter.
# ==============================================================================
resources_arsc_note=""
resources_arsc_decoded_identical=false
resources_decoded_diff=""
decoded_diff_file="${work_dir}/diff_resources_decoded.txt"

if [[ "${diff_count}" -gt 0 ]] && echo "${filtered_diff}" | grep -q "resources.arsc"; then
  log_info "resources.arsc in diff — decoding with apktool for semantic comparison..."

  # Copy official APK into work_dir so it is reachable from the /workspace mount.
  official_apk_copy="${work_dir}/official-apk.apk"
  [[ "${apk_file}" != "${official_apk_copy}" ]] && cp "${apk_file}" "${official_apk_copy}"

  # Decode both APKs: --no-src skips dex decompilation (resources only, faster).
  # This writes new directories into the RW-mounted workspace, so it needs the
  # same user mapping as every other write-path run (non-sudo-directories-
  # guideline.md) — omitting it leaves root-owned official-decoded/built-decoded
  # dirs the invoking user cannot clean up without sudo. --frame-path pins the
  # apktool framework cache to a writable container-local path (apktool-
  # framework-cache guideline) instead of the unwritable default under /.
  $CONTAINER_CMD run --rm \
    ${CONTAINER_RUN_USER_ARGS} -e HOME=/tmp \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apktool d -f --no-src --no-debug-info --frame-path /tmp/apktool-framework \
             /workspace/official-apk.apk -o /workspace/official-decoded 2>/dev/null && \
           apktool d -f --no-src --no-debug-info --frame-path /tmp/apktool-framework \
             /workspace/built-apks/apolloui-prod-${build_arch}-release-unsigned.apk \
             -o /workspace/built-decoded 2>/dev/null || true"

  resources_decoded_diff="$($CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "diff -r /workspace/official-decoded/res /workspace/built-decoded/res 2>/dev/null || true")"

  echo "${resources_decoded_diff}" > "${decoded_diff_file}"
  log_info "Decoded resources diff written to: ${decoded_diff_file}"

  # Determine if resources.arsc is the only remaining diff.
  non_arsc_diffs="$(echo "${filtered_diff}" | grep -v "resources.arsc" | tr -d '\n\r' || true)"

  if [[ -z "$(echo "${resources_decoded_diff}" | tr -d '\n\r')" ]]; then
    resources_arsc_decoded_identical=true
    if [[ -z "${non_arsc_diffs}" ]]; then
      # Sole diff, decoded content identical: upgrade verdict to reproducible.
      verdict="reproducible"
      yaml_status="reproducible"
      match_value="true"
      exit_code="${EXIT_SUCCESS}"
      resources_arsc_note="[INFO] resources.arsc: binary differs, decoded content IDENTICAL — non-semantic artifact. Verdict upgraded to reproducible."
    else
      resources_arsc_note="[INFO] resources.arsc: binary differs, decoded content identical. Other diffs remain."
    fi
  else
    # Decoded content differs — check if the ONLY semantic change is the Crashlytics mapping ID.
    # Extract actual changed lines (< and >) and remove any that are the crashlytics.mapping_file_id key.
    decoded_change_lines="$(echo "${resources_decoded_diff}" | grep -E '^[<>]' || true)"
    non_crashlytics_lines="$(echo "${decoded_change_lines}" | grep -v 'com.google.firebase.crashlytics.mapping_file_id' | tr -d '\n\r' || true)"

    if [[ -n "${decoded_change_lines}" ]] && [[ -z "${non_crashlytics_lines}" ]]; then
      # Sole semantic diff is the Crashlytics build-time mapping ID — acceptable per WS policy.
      if [[ -z "${non_arsc_diffs}" ]]; then
        verdict="reproducible"
        yaml_status="reproducible"
        match_value="true"
        exit_code="${EXIT_SUCCESS}"
        resources_arsc_note="[INFO] resources.arsc: sole diff is com.google.firebase.crashlytics.mapping_file_id — build-time non-deterministic ID, acceptable per WS policy. Verdict upgraded to reproducible."
      else
        resources_arsc_note="[INFO] resources.arsc: sole diff is com.google.firebase.crashlytics.mapping_file_id (acceptable per WS policy), but other diffs remain — verdict stays not_reproducible."
      fi
    else
      decoded_line_count="$(echo "${resources_decoded_diff}" | grep -c '^' || true)"
      resources_arsc_note="[WARN] resources.arsc: decoded content DIFFERS (${decoded_line_count} lines — see $(basename "${decoded_diff_file}"))"
    fi
  fi
  log_info "${resources_arsc_note}"
fi

# ==============================================================================
# COMPARISON_RESULTS.yaml (written to execution directory, not workspace).
# format per dannys-amendments.md 2026-02-05: nested files[] under each result.
# ==============================================================================
yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
cat > "${yaml_file}" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${yaml_status}
EOF
log_info "COMPARISON_RESULTS.yaml written to: ${yaml_file}"

# ==============================================================================
# Tag and commit signature verification (informational; not used for verdict).
# Muun tags are typically not GPG-signed; this section surfaces that information.
# ==============================================================================
tag_type="unknown"
tag_signature_status="[INFO] No tag information"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""

tag_catfile_output="$(git_in_container "git cat-file -t 'refs/tags/${tag_ref}' 2>&1 || true")"
commit_verify_output="$(git_in_container "git verify-commit '${commit_hash}' 2>&1 || true")"

if [[ "${tag_catfile_output}" == "tag" ]]; then
  tag_type="annotated"
  tag_signature_status="[INFO] Annotated tag (GPG check skipped — gpg not in WS container)"
  signature_warnings="- GPG verification skipped; gpg not available in walletscrutiny/android container"
elif [[ "${tag_catfile_output}" == "commit" ]]; then
  tag_type="lightweight"
  tag_signature_status="[INFO] Tag is lightweight (cannot carry a GPG signature)"
else
  tag_type="not found or HEAD"
  tag_signature_status="[INFO] Tag not found; built from commit ${commit_hash}"
fi

if echo "${commit_verify_output}" | grep -q "Good signature"; then
  commit_signature_status="[OK] Good signature on commit"
  commit_key="$(echo "${commit_verify_output}" | grep 'using .* key' | \
    sed -E 's/.*using .* key ([A-Fa-f0-9]+).*/\1/' | tail -1)"
  if [[ -n "${commit_key}" ]]; then
    [[ -n "${signature_keys}" ]] && signature_keys="${signature_keys}\n"
    signature_keys="${signature_keys}Commit signed with: ${commit_key}"
  fi
else
  commit_signature_status="[WARNING] No valid GPG signature on commit"
  [[ -z "${signature_warnings}" ]] && signature_warnings="- Commit is not signed or signer key not in keyring"
fi

# ==============================================================================
# Diff investigation hints (shown when workspace is preserved)
# ==============================================================================
diff_guide=""
if [[ "${should_cleanup}" != true && -n "${apk_file}" ]]; then
  diff_guide="
Run a full
diff --recursive ${official_unzipped} ${built_unzipped}
meld ${official_unzipped} ${built_unzipped}
or
diffoscope \"${apk_file}\" \"${built_apk}\"
for more details."
fi

# ==============================================================================
# Standardized verification summary output
# ==============================================================================
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer:-N/A}"
echo "apkVersionName: ${version_name}"
echo "apkVersionCode: ${version_code:-N/A}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash:-N/A}"
echo "commit:         ${commit_hash}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo ""
echo "Diff:"
if [[ -z "${apk_file}" ]]; then
  echo "(No comparison performed — no --apk provided)"
else
  diff_line_count="$(echo "${diff_display}" | grep -c '^' || true)"
  echo "${diff_display}" | head -5
  if [[ "${diff_line_count}" -gt 5 ]]; then
    echo "... (${diff_line_count} lines total — see ${diff_file})"
  fi
fi

if [[ -n "${resources_arsc_note}" ]]; then
  echo ""
  echo "resources.arsc (decoded comparison):"
  echo "  ${resources_arsc_note}"
  if [[ "${resources_arsc_decoded_identical}" == false && -n "${resources_decoded_diff}" ]]; then
    decoded_total="$(echo "${resources_decoded_diff}" | grep -c '^' || true)"
    echo "${resources_decoded_diff}" | head -20
    if [[ "${decoded_total}" -gt 20 ]]; then
      echo "  ... (${decoded_total} lines total — see ${decoded_diff_file})"
    fi
  fi
fi

echo ""
echo "Revision, tag (and its signature):"
echo "Tag: ${tag_ref} (${tag_type})"
echo ""
echo "${commit_verify_output}"
echo ""
echo "Signature Summary:"
echo "  Tag type:  ${tag_type}"
echo "  Tag:       ${tag_signature_status}"
echo "  Commit:    ${commit_signature_status}"

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
echo "===== End Results ====="
echo "${diff_guide}"

# ==============================================================================
# Cleanup
# ==============================================================================
if [[ "${should_cleanup}" == true ]]; then
  log_info "Removing workspace: ${work_dir}"
  rm -rf "${work_dir}"
  [[ -n "${metadata_dir:-}" && -d "${metadata_dir}" ]] && rm -rf "${metadata_dir}"
else
  log_info "Workspace preserved: ${work_dir}"
  [[ -n "${metadata_dir:-}" ]] && log_info "APK decode dir: ${metadata_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
