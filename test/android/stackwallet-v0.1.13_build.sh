#!/bin/bash
# ==============================================================================
# stackwallet_build.sh - Stack Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.13
# Organization:  WalletScrutiny.com
# Last Modified: 2026-09-28
# Project:       https://github.com/cypherstack/stack_wallet
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding the security,
# functionality, or fitness for any particular purpose. Users assume all risks.
# This script performs automated builds and APK comparisons.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws. The developers assume no liability for any misuse.
# By using this script, you acknowledge these disclaimers.
#
# SCRIPT SUMMARY:
# - --binary: Play split directory (base.apk + split_config.*.apk) OR one APK (upstream's GitHub
#   per-ABI APK from `flutter build apk --split-per-abi`, or the all-ABI APK): file or a dir with one .apk
# - Stack Wallet uses AAB on Play Store: base.apk + split_config.arm64_v8a.apk
#   + split_config.en.apk + split_config.xxhdpi.apk
# - Auto-generates device-spec.json from official split metadata
# - Builds inside a container: Ubuntu 24.04, JDK 21, Flutter 3.44.9 (Dart 3.12.2),
#   Rust 1.89.0 + 1.85.1 (+ 1.92.0 installed as `stable` for the cargokit crates tor_ffi_plugin
#   and xelis_flutter), Go 1.24.4, NDK 28.2.13676358 + 28.0.13004108
# - Mimics the maintainer's release environment: the official 2.7.3 was built on a workstation,
#   not in upstream's Docker, and libapp.so plus the Rust/Go plugins embed its paths. So the container
#   uses HOME=/home/diego, source at /home/diego/Desktop/releases/stack_wallet, SDK at
#   /home/diego/Android/Sdk, and the rustc/Go versions found in the official libraries.
# - Source revision: --commit, else the commit upstream embeds in the official libapp.so
#   (app_config.g.dart _commitHash), else tag build_{versionCode} (per-ABI APKs: minus Flutter's ABI*1000)
# - Applies Riverpod 1.0.4 / Flutter AOT compatibility patch
# - Uses bundletool 1.17.2 to extract split APKs from the built AAB
# - Compares each split pair, writes per-split diff files
# - Generates COMPARISON_RESULTS.yaml

SCRIPT_VERSION="v0.1.13"
SCRIPT_HASH="$(sha256sum "$(readlink -f "$0")" | awk '{print $1}')"
echo "$(basename "$0") ${SCRIPT_VERSION} sha256:${SCRIPT_HASH}"

set -uo pipefail

APP_ID="com.cypherstack.stackwallet"
REPO_URL="https://github.com/cypherstack/stack_wallet.git"
BUILD_IMAGE_NAME="stackwallet_build_env"
BASE_IMAGE="docker.io/library/ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3"
BUNDLETOOL_VERSION="1.17.2"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"
build_timestamp="$(date -u +%Y%m%d%H%M%S)"
build_pid="$$"

requested_version=""
requested_arch="arm64-v8a"
requested_type=""
requested_commit=""
splits_input_dir=""
should_cleanup=false

version_name=""
version_code=""
git_tag=""
signer=""
official_base_hash=""
total_diff_count=0
additional_info=""
work_dir=""
yaml_status="not_reproducible"
verdict="differences found"
split_verdicts=()
input_mode=""; official_abis=""; apk_target=""; base_code=""; commit_hash="unknown"; commit_source="unknown"
reproducible_count=0
not_reproducible_count=0
total_splits=0

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*"; }

append_info() {
  [[ -n "${additional_info}" ]] && additional_info="${additional_info}
$1" || additional_info="$1"
}

write_yaml() {
  local v="$1" notes="$2"
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<YAML
script_version: ${SCRIPT_VERSION}
verdict: ${v}
notes: |
$(echo "${notes}" | sed 's/^/  /')
YAML
}

die_invalid() {
  log_error "$*"
  write_yaml "ftbfs" "Invalid parameters: $*"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  write_yaml "ftbfs" "Build failed: $*"
  exit "${EXIT_FAILED}"
}

on_error() {
  local code=$? line=$1
  set +e
  log_error "Script failed at line ${line} (exit ${code})"
  write_yaml "ftbfs" "Script failed at line ${line} with exit code ${code}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

CONTAINER_CMD="" VOLUME_RO="" VOLUME_RW=""
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"; VOLUME_RO=":ro,Z"; VOLUME_RW=":Z"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"; VOLUME_RO=":ro"; VOLUME_RW=""
else
  die_failed "Neither podman nor docker found (the only host requirement)."
fi

# Hand the per-run workspace back to the caller at exit (containers write as root; no sudo on the host).
reclaim_workspace() {
  [[ -n "${work_dir}" && -d "${work_dir}" ]] || return 0
  local owner="$(id -u):$(id -g)"; [[ "${CONTAINER_CMD}" == podman ]] && owner="0:0"
  ${CONTAINER_CMD} run --rm -v "${work_dir}:/w${VOLUME_RW}" "${BASE_IMAGE}" chown -R "${owner}" /w >/dev/null 2>&1 || true
}
trap reclaim_workspace EXIT

usage() {
  cat <<EOF
NAME
       stackwallet_build.sh - Stack Wallet reproducible build verification

SYNOPSIS
       ${script_name} --binary <splits_dir | apk> [--version <version>] [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Split directory: builds the AAB, renders splits with bundletool, compares
       each against the official Play Store split. One APK: builds upstream's
       flutter build apk --split-per-abi (or the all-ABI APK) and compares it.

       Use apkextractor_sync.sh to pull splits from device:
         apkextractor_sync.sh com.cypherstack.stackwallet
       Then pass the resulting directory:
         --binary /var/shared/apk/com.cypherstack.stackwallet/2.4.4/

       Split directory: base.apk + split_config.*.apk. APK: a file, or a directory with one .apk.

OPTIONS
       --version <version>   App version name, e.g. 2.4.4 (required)
       --binary <dir|apk>    Official split directory, or one APK (required)
       --apk <dir|apk>       Alias for --binary
       --arch <arch>         ABI override (default: auto-detected from splits)
       --type <type>         Accepted for ABS compatibility (ignored)
       --commit <sha>        Upstream commit to build (default: the commit embedded in the official
                             libapp.so; tag build_<n> only if no single embedded commit resolves)
       --cleanup             Remove work directory after completion
       --script-version      Print script version and exit
       --help                Show this help and exit

EXIT CODES
       0    All splits identical (excluding acceptable Play Store artifacts)
       1    Differences found or build failed
       2    Invalid parameters

NOTES
       First run: 60-90+ minutes (Rust crypto libs compile from source).
       Subsequent runs reuse Docker layer cache for toolchain.
       GitHub releases carry per-ABI APKs (sw-v<ver>-<abi>-release.apk) and an all-ABI APK.

EXAMPLES
       ${script_name} --version 2.4.4 --binary /var/shared/apk/com.cypherstack.stackwallet/2.4.4/
EOF
}

require_arg() {
  if [[ -z "${2:-}" || "${2}" == --* ]]; then
    die_invalid "Option ${1} requires a value."
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)        require_arg "$1" "${2:-}"; requested_version="$2"; shift ;;
    --binary|--apk)   require_arg "$1" "${2:-}"; splits_input_dir="$2"; shift ;;
    --arch)           require_arg "$1" "${2:-}"; requested_arch="$2"; shift ;;
    --type)           require_arg "$1" "${2:-}"; requested_type="$2"; shift ;;
    --commit)         require_arg "$1" "${2:-}"; requested_commit="$2"; shift ;;
    --cleanup)        should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
    --help)           usage; exit "${EXIT_SUCCESS}" ;;
    *)                log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

[[ -z "${splits_input_dir}" ]] && die_invalid "--binary is required (Play split directory or one APK)."
[[ -z "${requested_commit}" || "${requested_commit}" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_invalid "--commit must be a 7-40 hex git commit id: ${requested_commit}"
if [[ -f "${splits_input_dir}" ]]; then
  [[ "${splits_input_dir}" == *.apk ]] || die_invalid "--binary file must be an .apk: ${splits_input_dir}"
  input_mode="apk"
elif [[ -d "${splits_input_dir}" ]]; then
  if [[ -f "${splits_input_dir}/base.apk" ]]; then
    input_mode="splits"
  else
    mapfile -t _apks < <(find "${splits_input_dir}" -maxdepth 1 -type f -name '*.apk' | sort)
    [[ ${#_apks[@]} -eq 1 ]] || die_invalid "--binary directory needs base.apk (+ split_config.*.apk) or exactly one .apk (found ${#_apks[@]})."
    splits_input_dir="${_apks[0]}"; input_mode="apk"
  fi
else
  die_invalid "--binary not found: ${splits_input_dir}"
fi
[[ "$(id -u)" -eq 0 ]] && die_invalid "Do not run as root."

version_name="${requested_version}"

aapt_field() {
  local apk="$1" field="$2"
  local d; d="$(dirname "$(realpath "${apk}")")"
  local n; n="$(basename "${apk}")"
  case "${field}" in
    sdkVersion)
      ${CONTAINER_CMD} run --rm \
        --volume "${d}:/apk${VOLUME_RO}" \
        "${build_image}" \
        sh -c "aapt dump badging /apk/${n} 2>/dev/null | grep '^sdkVersion:' | sed \"s/sdkVersion:'\\([^']*\\)'.*/\\1/\"" ;;
    native)
      ${CONTAINER_CMD} run --rm \
        --volume "${d}:/apk${VOLUME_RO}" \
        "${build_image}" \
        sh -c "aapt dump badging /apk/${n} 2>/dev/null | sed -n \"s/^native-code: //p\" | tr -d \"'\"" ;;
    *)
      ${CONTAINER_CMD} run --rm \
        --volume "${d}:/apk${VOLUME_RO}" \
        "${build_image}" \
        sh -c "aapt dump badging /apk/${n} 2>/dev/null | grep '^package:' | grep -o \" ${field}='[^']*'\" | sed \"s/ ${field}='//;s/'$//\"" ;;
  esac
}

sha256_file() {
  local f="$1"
  local d; d="$(dirname "$(realpath "${f}")")"
  local n; n="$(basename "${f}")"
  ${CONTAINER_CMD} run --rm \
    --volume "${d}:/data${VOLUME_RO}" \
    "${build_image}" \
    sh -c "sha256sum /data/${n} | awk '{print \$1}'"
}

signer_cert() {
  local apk="$1"
  local d; d="$(dirname "$(realpath "${apk}")")"
  local n; n="$(basename "${apk}")"
  ${CONTAINER_CMD} run --rm \
    --volume "${d}:/apk${VOLUME_RO}" \
    "${build_image}" \
    sh -c "apksigner verify --print-certs /apk/${n} 2>/dev/null \
           | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

log_info "========================================================"
log_info " Stack Wallet Verification ${SCRIPT_VERSION}"
log_info "========================================================"

# ------------------------------------------------------------------------------
# Build toolchain image first — used for aapt, apksigner, sha256sum, apktool,
# and the actual Flutter+Rust build. Eliminates external container dependency.
# ------------------------------------------------------------------------------
build_image="${BUILD_IMAGE_NAME}:toolchain-${SCRIPT_VERSION}"
log_info "Building toolchain image: ${build_image}"
log_info "Downloads ~5 GB on first run; subsequent builds use layer cache."

${CONTAINER_CMD} build --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t "${build_image}" - << 'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
# Maintainer-workstation layout (paths are embedded in the official native libraries)
ENV HOME=/home/diego
ENV ANDROID_HOME=/home/diego/Android/Sdk
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH=${PATH}:/home/diego/Android/Sdk/cmdline-tools/latest/bin:/home/diego/Android/Sdk/platform-tools:/home/diego/Android/Sdk/build-tools/35.0.0:/opt/flutter/bin:/home/diego/.cargo/bin:/usr/local/go/bin
RUN mkdir -p /home/diego/Desktop/releases

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk-headless git wget curl unzip zip ca-certificates \
    cmake clang pkg-config libssl-dev build-essential python3 \
    xz-utils rsync libstdc++-12-dev && rm -rf /var/lib/apt/lists/*

# Podman rootless fix: tar wrapper passes --no-same-owner so uid/gid errors
# from Flutter/gradle archive extraction do not abort the build.
RUN printf '#!/bin/sh\nexec /usr/bin/tar --no-same-owner "$@"\n' \
    > /usr/local/bin/tar && chmod +x /usr/local/bin/tar

# Android command-line tools (14742923, sha1: 48833c34b761c10cb20bcd16582129395d121b27)
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip \
         -O /tmp/ct.zip && \
    echo "04453066b540409d975c676d781da1477479dde3761310f1a7eb92a1dfb15af7  /tmp/ct.zip" | sha256sum -c - && \
    unzip -q /tmp/ct.zip -d /tmp/ct && \
    mv /tmp/ct/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm -rf /tmp/ct.zip /tmp/ct

RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true && \
    sdkmanager "platforms;android-36" "build-tools;35.0.0" \
               "ndk;28.2.13676358" "ndk;28.0.13004108" \
               "cmake;3.22.1" "platform-tools"

# Rust: 1.89.0 default + 1.85.1 for libmwc (upstream rust_version.sh); Android targets; cargo-ndk.
# cargokit builds tor_ffi_plugin/xelis_flutter with `rustup run stable` (ignores rust-toolchain.toml);
# the official 2.7.3 libraries carry rustc 1.92.0 (ded5c06cf), so 1.92.0 is installed as `stable`
# (copied toolchain dir; cargokit only reinstalls `stable` when it is missing from `rustup toolchain list`).
RUN curl -fsSL -o /tmp/rustup-init https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init && \
    echo "20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c  /tmp/rustup-init" | sha256sum -c - && \
    chmod +x /tmp/rustup-init && /tmp/rustup-init -y --default-toolchain 1.89.0 --no-modify-path && rm /tmp/rustup-init && \
    /home/diego/.cargo/bin/rustup toolchain install 1.85.1 1.92.0 && \
    for tc in 1.89.0 1.85.1 1.92.0; do \
      /home/diego/.cargo/bin/rustup target add \
          aarch64-linux-android armv7-linux-androideabi x86_64-linux-android \
          --toolchain "${tc}"; \
    done && \
    cp -a /home/diego/.rustup/toolchains/1.92.0-x86_64-unknown-linux-gnu \
          /home/diego/.rustup/toolchains/stable-x86_64-unknown-linux-gnu && \
    /home/diego/.cargo/bin/rustup run stable rustc --version | grep -q '^rustc 1\.92\.0 ' && \
    /home/diego/.cargo/bin/cargo install cargo-ndk --version "=3.5.4" --locked

# Go 1.24.4 (version in the official libmwebd.so; GOTOOLCHAIN=local blocks silent toolchain switches)
ENV GOTOOLCHAIN=local
RUN wget -q https://go.dev/dl/go1.24.4.linux-amd64.tar.gz -O /tmp/go.tar.gz && \
    echo "77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717  /tmp/go.tar.gz" | sha256sum -c - && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz

# Flutter 3.44.9 (ships with Dart SDK 3.12.2; upstream pubspec.lock sdks: dart >=3.12.2, flutter >=3.44.9, and upstream Dockerfile pin at the built commit)
ENV FLUTTER_SUPPRESS_ANALYTICS=true
ENV PUB_SUPPRESS_ANALYTICS=true
RUN git clone --depth 1 --branch 3.44.9 \
        https://github.com/flutter/flutter.git /opt/flutter && \
    test "$(git -C /opt/flutter rev-parse HEAD)" = 6b182d2c7585eba26d4edce0f97630effd256c33
# Pre-warm cache; failures are non-fatal (Flutter re-downloads missing
# artifacts on first use). The tar wrapper above handles Podman rootless
# uid/gid errors during extraction.
RUN flutter precache --android || true
RUN flutter doctor --android-licenses -y >/dev/null 2>&1 || true

# bundletool 1.17.2 standalone
RUN wget -q "https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar" \
         -O /usr/local/lib/bundletool.jar && \
    echo "2d4ad908faea64047c1cc9cb747e6aa667c6ab192e09607bd16b67246a8cd6ae  /usr/local/lib/bundletool.jar" | sha256sum -c -

# apktool 2.9.3 (for APK decoding during comparison)
RUN wget -q "https://github.com/iBotPeaches/Apktool/releases/download/v2.9.3/apktool_2.9.3.jar" \
         -O /usr/local/bin/apktool.jar && \
    echo "7956eb04194300ce0d0a84ad18771eebc94b89fb8d1ddcce8ea4c056818646f4  /usr/local/bin/apktool.jar" | sha256sum -c - && \
    printf '#!/bin/sh\nexec java -jar /usr/local/bin/apktool.jar "$@"\n' \
         > /usr/local/bin/apktool && chmod +x /usr/local/bin/apktool

WORKDIR /build
DOCKERFILE

if [[ "${input_mode}" == "apk" ]]; then
  base_apk="$(realpath "${splits_input_dir}")"; splits_input_dir="$(dirname "${base_apk}")"
  log_info "Official APK: ${base_apk}"
  ls -lh "${base_apk}" | awk '{print "  " $5 "\t" $9}'
else
  splits_input_dir="$(realpath "${splits_input_dir}")"; base_apk="${splits_input_dir}/base.apk"
  log_info "Official splits: ${splits_input_dir}"
  ls -lh "${splits_input_dir}"/*.apk 2>/dev/null | awk '{print "  " $5 "\t" $9}' || true
fi

pkg_name="$(aapt_field "${base_apk}" "name")"
version_name_apk="$(aapt_field "${base_apk}" "versionName")"
version_code="$(aapt_field "${base_apk}" "versionCode")"
sdk_version="$(aapt_field "${base_apk}" "sdkVersion")"

log_info "  Package:      ${pkg_name:-<not detected>}"
log_info "  Version name: ${version_name_apk:-<not detected>}"
log_info "  Version code: ${version_code:-<not detected>}"
log_info "  SDK version:  ${sdk_version:-<not detected>}"

if [[ -n "${pkg_name}" && "${pkg_name}" != "${APP_ID}" ]]; then
  die_invalid "Package mismatch: expected ${APP_ID}, got ${pkg_name}."
fi

# Derive version_name from APK if --version was not passed
if [[ -z "${version_name}" ]]; then
  [[ -z "${version_name_apk}" ]] && die_failed "Could not detect versionName from base.apk. Pass --version explicitly."
  version_name="${version_name_apk}"
  log_info "  Version derived from APK: ${version_name}"
elif [[ -n "${version_name_apk}" && "${version_name_apk}" != "${version_name}" ]]; then
  log_warn "APK versionName (${version_name_apk}) != --version (${version_name})."
  append_info "Version mismatch: --version=${version_name}, APK=${version_name_apk}."
fi

[[ -z "${version_code}" ]] && die_failed "Could not read versionCode from base.apk."

# Flutter --split-per-abi sets versionCode = ABI*1000 + build number (armeabi-v7a 1, arm64-v8a 2, x86 3, x86_64 4).
base_code="${version_code}"
if [[ "${input_mode}" == "apk" ]]; then
  official_abis="$(aapt_field "${base_apk}" "native")"
  read -ra _abis <<< "${official_abis}"
  if [[ ${#_abis[@]} -eq 1 ]]; then
    apk_target="${_abis[0]}"; requested_arch="${apk_target}"
    case "${apk_target}" in armeabi-v7a) _m=1 ;; arm64-v8a) _m=2 ;; x86) _m=3 ;; x86_64) _m=4 ;; *) _m=0 ;; esac
    (( _m > 0 && version_code > _m * 1000 )) && base_code=$((version_code - _m * 1000))
  else
    apk_target="all"; requested_arch="all"
  fi
  log_info "  APK ABIs:     ${official_abis:-none} -> build target ${apk_target}, build number ${base_code}"
fi
git_tag="build_${base_code}"
log_info "  Git tag:  ${git_tag}"

official_base_hash="$(sha256_file "${base_apk}")"
signer="$(signer_cert "${base_apk}")"
log_info "  SHA-256:  ${official_base_hash}"
log_info "  Signer:   ${signer}"

if [[ "${input_mode}" == "apk" ]]; then official_split_files=("${base_apk}")
else mapfile -t official_split_files < <(ls "${splits_input_dir}"/*.apk 2>/dev/null | sort); fi

detected_abi="${requested_arch}"
screen_density="480"
locale_list=""

for f in "${official_split_files[@]}"; do
  case "$(basename "${f}")" in
    split_config.arm64_v8a.apk)   detected_abi="arm64-v8a" ;;
    split_config.armeabi_v7a.apk) detected_abi="armeabi-v7a" ;;
    split_config.x86_64.apk)      detected_abi="x86_64" ;;
    split_config.xxxhdpi.apk) screen_density="640" ;;
    split_config.xxhdpi.apk)  screen_density="480" ;;
    split_config.xhdpi.apk)   screen_density="320" ;;
    split_config.hdpi.apk)    screen_density="240" ;;
    split_config.mdpi.apk)    screen_density="160" ;;
  esac
  fname="$(basename "${f}")"
  if [[ "${fname}" =~ split_config\.([a-z]{2,3})\.apk$ ]]; then
    loc="${BASH_REMATCH[1]}"
    case "${loc}" in
      arm64|armeabi|x86|hdpi|xhdpi|xxhdpi|xxxhdpi|mdpi|ldpi|tvdpi) continue ;;
      *) locale_list+="${locale_list:+,}\"${loc}\"" ;;
    esac
  fi
done
requested_arch="${detected_abi}"
locale_list="${locale_list:-\"en\"}"
sdk_val="${sdk_version:-24}"

work_dir="${execution_dir}/workdir_stackwallet_${version_name}_${requested_arch}_${build_timestamp}_${build_pid}"
mkdir -p "${work_dir}"
log_info "Work dir: ${work_dir}"

cat > "${work_dir}/device-spec.json" <<EOF
{
  "supportedAbis": ["${detected_abi}"],
  "supportedLocales": [${locale_list}],
  "screenDensity": ${screen_density},
  "sdkVersion": ${sdk_val}
}
EOF
log_info "device-spec.json: abi=${detected_abi} density=${screen_density} locales=[${locale_list}] sdk=${sdk_val}"

official_splits_dir="${work_dir}/official-split-apks"
mkdir -p "${official_splits_dir}"
if [[ "${input_mode}" == "apk" ]]; then cp "${base_apk}" "${official_splits_dir}/base.apk"
else cp "${splits_input_dir}"/*.apk "${official_splits_dir}/"; fi

# Source revision. Upstream's configure_stack_wallet.sh compiles `git log -1` into the app
# (lib/app_config.g.dart _commitHash), so the official libapp.so names the commit that shipped.
# Collect every 40-hex string in it; the build container resolves them against upstream's history
# (exactly one must be a real commit). Tags have lied before (2.4.4: build_301 != shipped commit).
embedded_candidates="${work_dir}/embedded-commit-candidates.txt"
: > "${embedded_candidates}"
if [[ -z "${requested_commit}" ]]; then
  libapp_apk="${official_splits_dir}/base.apk"
  for f in "${official_splits_dir}"/split_config.*.apk; do
    [[ -f "${f}" ]] || continue
    case "$(basename "${f}")" in
      split_config.arm64_v8a.apk|split_config.armeabi_v7a.apk|split_config.x86_64.apk) libapp_apk="${f}" ;;
    esac
  done
  libapp_name="$(basename "${libapp_apk}")"
  ${CONTAINER_CMD} run --rm \
    --volume "${official_splits_dir}:/apk${VOLUME_RO}" \
    -e "APK=${libapp_name}" \
    "${build_image}" \
    sh -c 'so="$(unzip -Z1 "/apk/$APK" | grep -m1 "^lib/.*/libapp\.so$")" && unzip -p "/apk/$APK" "$so" | grep -a -o -E "[0-9a-f]{40}" | sort -u' \
    > "${embedded_candidates}" || true
  log_info "  Embedded-commit candidates: $(grep -c . "${embedded_candidates}" || true) 40-hex strings in ${libapp_name} libapp.so"
else
  log_info "  Source revision requested: --commit ${requested_commit}"
fi

# ------------------------------------------------------------------------------
# Build script (executes inside container via docker run)
# ------------------------------------------------------------------------------
cat > "${work_dir}/run_build.sh" << 'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

GIT_TAG="${1}"
APP_VERSION="${2}"
BUILD_NUM="${3}"
MODE="${4:-splits}"
TARGET="${5:-}"
SOURCE_COMMIT="${6:-}"

# Source path as on the maintainer's workstation (embedded in libapp.so and the Rust plugins).
SRC=/home/diego/Desktop/releases/stack_wallet
echo "[BUILD] Cloning stack_wallet (full history, blobs fetched on checkout) into ${SRC}..."
git clone --filter=blob:none --no-checkout \
    https://github.com/cypherstack/stack_wallet.git "${SRC}"
cd "${SRC}"
tag_commit=""
if git rev-parse -q --verify "refs/tags/${GIT_TAG}^{commit}" >/dev/null 2>&1; then
  tag_commit="$(git rev-parse "refs/tags/${GIT_TAG}^{commit}")"
fi
source_commit=""; source_how=""
if [[ -n "${SOURCE_COMMIT}" ]]; then
  source_commit="$(git rev-parse -q --verify "${SOURCE_COMMIT}^{commit}" 2>/dev/null || true)"
  [[ -n "${source_commit}" ]] || { echo "[ERROR] --commit ${SOURCE_COMMIT} is not a commit in upstream's history"; exit 1; }
  source_how="--commit"
else
  # Match against the commit list, not cat-file: a partial clone lazily fetches every unknown id.
  git rev-list --all > /tmp/upstream-commits.txt
  mapfile -t matches < <(grep -x -F -f /embedded-commit-candidates.txt /tmp/upstream-commits.txt | sort -u)
  echo "[BUILD] Embedded-commit candidates: $(grep -c . /embedded-commit-candidates.txt || true); upstream commits among them: ${#matches[@]}${matches[*]:+ (${matches[*]})}"
  if [[ ${#matches[@]} -eq 1 ]]; then
    source_commit="${matches[0]}"; source_how="commit embedded in the official libapp.so"
  elif [[ -n "${tag_commit}" ]]; then
    source_commit="${tag_commit}"; source_how="tag ${GIT_TAG} (no single embedded commit resolved)"
  else
    echo "[ERROR] No source revision: ${#matches[@]} embedded candidates resolve to upstream commits and tag ${GIT_TAG} does not exist. Pass --commit."
    exit 1
  fi
fi
if [[ -z "${tag_commit}" ]]; then
  echo "[BUILD] Tag ${GIT_TAG} does not exist upstream."
  source_how="${source_how}; no tag ${GIT_TAG} upstream"
elif [[ "${tag_commit}" != "${source_commit}" ]]; then
  echo "[BUILD] WARNING: tag ${GIT_TAG} = ${tag_commit} differs from the source revision ${source_commit}."
  source_how="${source_how}; tag ${GIT_TAG} = ${tag_commit} differs"
else
  source_how="${source_how}; same as tag ${GIT_TAG}"
fi
echo "[BUILD] Source revision: ${source_commit} (${source_how})"
git checkout -q "${source_commit}"
git rev-parse HEAD > /output/commit.txt
echo "${source_how}" > /output/commit-source.txt
git submodule update --init --recursive

echo "[BUILD] Configuring and compiling crypto plugins (build_app.sh)..."
echo "[BUILD] Rust compilation takes 40-60 minutes on first run."
cd scripts
echo "yes" | ./build_app.sh -v "${APP_VERSION}" -b "${BUILD_NUM}" -p android -a stack_wallet
cd "${SRC}"

echo "[BUILD] Applying Riverpod 1.0.4 / Flutter AOT compatibility patch..."
# flutter_riverpod 1.0.4 ConsumerState lacks a concrete activate() needed by
# SingleTickerProviderStateMixin.super.activate() under Flutter strict AOT (seen with 3.38.1, kept for 3.44.9).
cat > lib/utilities/consumer_state_mixin_compat.dart << 'DARTEOF'
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Reproducibility workaround: flutter_riverpod 1.0.4 ConsumerState does not
// provide a concrete activate() for SingleTickerProviderStateMixin under
// Flutter AOT. This intermediate base class inserts one into the MRO.
abstract class ConsumerStateWithMixinCompat<W extends ConsumerStatefulWidget>
    extends ConsumerState<W> {
  @override
  void activate() => super.activate();
}
DARTEOF

sed -i "s|extends ConsumerState<DesktopMenuItem<T>>|extends ConsumerStateWithMixinCompat<DesktopMenuItem<T>>|" \
    lib/pages_desktop_specific/desktop_menu_item.dart
grep -q "consumer_state_mixin_compat" lib/pages_desktop_specific/desktop_menu_item.dart || \
    sed -i "1s|^|import 'package:stackwallet/utilities/consumer_state_mixin_compat.dart';\n|" \
        lib/pages_desktop_specific/desktop_menu_item.dart

sed -i "s|extends ConsumerState<DesktopTorStatusButton>|extends ConsumerStateWithMixinCompat<DesktopTorStatusButton>|" \
    lib/widgets/desktop/desktop_tor_status_button.dart
grep -q "consumer_state_mixin_compat" lib/widgets/desktop/desktop_tor_status_button.dart || \
    sed -i "1s|^|import 'package:stackwallet/utilities/consumer_state_mixin_compat.dart';\n|" \
        lib/widgets/desktop/desktop_tor_status_button.dart

sed -i "s|extends ConsumerState<_TorAnimatedButton>|extends ConsumerStateWithMixinCompat<_TorAnimatedButton>|" \
    lib/pages/settings_views/global_settings_view/tor_settings/tor_settings_view.dart
grep -q "consumer_state_mixin_compat" \
    lib/pages/settings_views/global_settings_view/tor_settings/tor_settings_view.dart || \
    sed -i "1s|^|import 'package:stackwallet/utilities/consumer_state_mixin_compat.dart';\n|" \
        lib/pages/settings_views/global_settings_view/tor_settings/tor_settings_view.dart

if [[ "${MODE}" == "apk" ]]; then
  # Flutter only finds a signed release APK: throwaway key through upstream's own key.properties.
  echo "[BUILD] Throwaway release key via android/key.properties (as upstream CI writes it)..."
  keytool -genkeypair -keystore android/keystore.jks -storetype PKCS12 -alias ws -storepass wsverify \
      -keypass wsverify -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=WalletScrutiny" >/dev/null 2>&1
  printf 'storeFile=../keystore.jks\nstorePassword=wsverify\nkeyPassword=wsverify\nkeyAlias=ws\n' > android/key.properties
else
  echo "[BUILD] Removing release signing config (unsigned AAB for comparison)..."
  sed -i '/signingConfig signingConfigs.release/d' android/app/build.gradle
fi

echo "[BUILD] Writing local.properties and empty API keys..."
printf 'sdk.dir=/home/diego/Android/Sdk\nflutter.sdk=/opt/flutter\n' > android/local.properties
# Same template as upstream scripts/prebuild.sh (gitignored file); 2.7.3 also imports the
# LetsExchange and CypherGoat constants. Upstream CI decodes its real keys here, so the
# key strings are an expected diff in libapp.so.
printf 'const kChangeNowApiKey = "";\nconst kSimpleSwapApiKey = "";\nconst kNanswapApiKey = "";\nconst kNanoSwapRpcApiKey = "";\nconst kWizSwapApiKey = "";\nconst kShopInBitAccessKey = "";\nconst kShopInBitPartnerSecret = "";\nconst kCakePayApiToken = "";\nconst kExolixApiKey = "";\nconst kLetsExchangeId = "";\nconst kLetsExchangeToken = "";\nconst kCypherGoatApiKey = "";\nconst kCypherGoatAffiliate = "";\n' \
    > lib/external_api_keys.dart

echo "[BUILD] flutter pub get..."
flutter pub get

if [[ "${MODE}" == "apk" ]]; then
  if [[ "${TARGET}" == "all" ]]; then
    echo "[BUILD] flutter build apk --release (all ABIs)..."
    flutter build apk --release
    apk="build/app/outputs/flutter-apk/app-release.apk"
  else
    echo "[BUILD] flutter build apk --split-per-abi --release (upstream CI) -> ${TARGET}..."
    flutter build apk --split-per-abi --release
    apk="build/app/outputs/flutter-apk/app-${TARGET}-release.apk"
  fi
  [[ -f "${apk}" ]] || { echo "[ERROR] APK not found at ${apk}"; exit 1; }
  cp "${apk}" /output/app.apk
  echo "[BUILD] APK: $(du -h /output/app.apk | cut -f1). Done."
  exit 0
fi

echo "[BUILD] flutter build appbundle --release..."
flutter build appbundle --release

aab="build/app/outputs/bundle/release/app-release.aab"
[[ -f "${aab}" ]] || { echo "[ERROR] AAB not found at ${aab}"; exit 1; }
cp "${aab}" /output/app.aab
echo "[BUILD] AAB: $(du -h /output/app.aab | cut -f1)"

echo "[BUILD] Extracting splits via bundletool..."
java -jar /usr/local/lib/bundletool.jar build-apks \
    --bundle=/output/app.aab \
    --output=/output/built-splits.apks \
    --device-spec=/device-spec.json \
    --overwrite

unzip -q /output/built-splits.apks -d /output/bundletool-out/
echo "[BUILD] Done."
BUILDSCRIPT
chmod +x "${work_dir}/run_build.sh"

output_dir="${work_dir}/build-output"
mkdir -p "${output_dir}"

log_info "Running build (first run: 60-90+ min)..."
${CONTAINER_CMD} run --rm \
  --volume "${work_dir}/run_build.sh:/run_build.sh${VOLUME_RO}" \
  --volume "${output_dir}:/output${VOLUME_RW}" \
  --volume "${work_dir}/device-spec.json:/device-spec.json${VOLUME_RO}" \
  --volume "${embedded_candidates}:/embedded-commit-candidates.txt${VOLUME_RO}" \
  "${build_image}" \
  bash /run_build.sh "${git_tag}" "${version_name}" "${base_code}" "${input_mode}" "${apk_target}" "${requested_commit}"
commit_hash="$(cat "${output_dir}/commit.txt" 2>/dev/null || echo unknown)"
commit_source="$(cat "${output_dir}/commit-source.txt" 2>/dev/null || echo unknown)"

# ------------------------------------------------------------------------------
# Normalize bundletool split names to Play Store naming convention
# ------------------------------------------------------------------------------
bundletool_raw="${output_dir}/bundletool-out/splits"
[[ -d "${bundletool_raw}" ]] || bundletool_raw="${output_dir}/bundletool-out"
built_splits_dir="${work_dir}/built-split-apks"
mkdir -p "${built_splits_dir}"

if [[ "${input_mode}" == "apk" ]]; then
  [[ -f "${output_dir}/app.apk" ]] || die_failed "No APK was produced."
  cp "${output_dir}/app.apk" "${built_splits_dir}/base.apk"
  log_info "  app.apk → base.apk"
fi
for f in "${bundletool_raw}"/*.apk; do
  [[ "${input_mode}" == "apk" ]] && break
  [[ -f "${f}" ]] || continue
  fname="$(basename "${f}")"
  case "${fname}" in
    base-master.apk) dest="base.apk" ;;
    base-*.apk)      dest="split_config.${fname#base-}" ;;
    *)               dest="${fname}" ;;
  esac
  cp "${f}" "${built_splits_dir}/${dest}"
  log_info "  ${fname} → ${dest}"
done

log_info "Built splits:"
ls -lh "${built_splits_dir}"/*.apk 2>/dev/null | awk '{print "  " $5 "\t" $9}' || true

# ------------------------------------------------------------------------------
# Compare splits: apktool decode + per-artifact verdict (Leo's model)
# resources.arsc is decoded to res/ XML — packaging-only diffs show as identical
# ------------------------------------------------------------------------------
log_info "Comparing splits via apktool decode..."

decoded_dir="${work_dir}/decoded"
mkdir -p "${decoded_dir}"

# Play Store distribution artifacts — injected after build, not part of source
ACCEPTABLE='com\.android\.stamp\.|vending\.derived\.apk\.id|stamp-cert-sha256'

apktool_decode() {
  local apk="$1" out="$2"
  mkdir -p "${out}"
  ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${apk}"):/src${VOLUME_RO}" \
    --volume "${out}:/out${VOLUME_RW}" \
    "${build_image}" \
    apktool d -f --no-src --no-debug-info "/src/$(basename "${apk}")" -o /out 2>/dev/null
}

aggregated_diff=""
total_diff_count=0
found_stamp_artifacts=false
found_locale_norm=false
all_so_diffs=()
all_so_identical=()
all_decoded_diff_files=()

for off_apk in "${official_splits_dir}"/*.apk; do
  [[ -f "${off_apk}" ]] || continue
  fname="$(basename "${off_apk}")"
  key="${fname%.apk}"; key="${key#split_config.}"

  built_apk="${built_splits_dir}/${fname}"
  off_decoded="${decoded_dir}/official-${key}"
  blt_decoded="${decoded_dir}/built-${key}"

  off_hash="$(sha256_file "${off_apk}")"
  built_hash_s=""
  [[ -f "${built_apk}" ]] && built_hash_s="$(sha256_file "${built_apk}")"

  if [[ ! -f "${built_apk}" ]]; then
    log_warn "${fname}: missing in built output."
    split_verdicts+=("${fname}: not_reproducible (missing in built)")
    not_reproducible_count=$((not_reproducible_count + 1))
    total_diff_count=$((total_diff_count + 1))
    aggregated_diff+="=== ${fname} ===\nMISSING in built output.\n\n"
    continue
  fi

  log_info "  Decoding ${fname} with apktool..."
  apktool_decode "${off_apk}" "${off_decoded}"
  apktool_decode "${built_apk}" "${blt_decoded}"

  # Diff decoded content — apktool converts resources.arsc to res/ XML,
  # so packaging-only differences in resources.arsc appear as no diff here.
  # Exclude apktool metadata, original binaries, unknown files, and .so (handled below).
  xml_diff="$(${CONTAINER_CMD} run --rm \
    --volume "${off_decoded}:/a${VOLUME_RO}" \
    --volume "${blt_decoded}:/b${VOLUME_RO}" \
    "${build_image}" \
    diff -r --exclude="apktool.yml" --exclude="original" \
            --exclude="unknown" --exclude="*.so" \
    /a /b 2>/dev/null || true)"

  # Detect which acceptable diff types appeared (used for YAML notes)
  echo "${xml_diff}" | grep -qE "${ACCEPTABLE}" && found_stamp_artifacts=true
  echo "${xml_diff}" | grep -q 'splits0\.xml' && found_locale_norm=true

  # Count unacceptable decoded diffs only.
  # Handles: < / > text change lines, Binary files lines, Only-in presence lines.
  # Skips: diff headers, range markers, --- separators, splits0.xml blocks,
  # Play Store stamps, and <application> wrapper tags whose only child is a stamp.
  xml_lines="$(echo "${xml_diff}" | awk '
    /^diff / {
      idx = index($0, " /b/"); cur = (idx > 0) ? substr($0, idx+4) : ""
      in_splits0 = (index(cur, "splits0.xml") > 0)
    }
    in_splits0 { next }
    /^[<>]/ {
      if ($0 !~ /com\.android\.stamp\.|vending\.derived\.apk\.id|stamp-cert-sha256/ &&
          $0 !~ /<[\/]?application[ >\/]/) n++
      next
    }
    /^Binary files/ { n++; next }
    /^Only in/ {
      if ($0 !~ /com\.android\.stamp\.|vending\.derived\.apk\.id|stamp-cert-sha256/) n++
    }
    END { print n+0 }
  ')"

  # Identify which specific non-.so files contribute unacceptable diffs.
  # Used for human-readable output and YAML notes.
  decoded_diff_files=()
  while IFS= read -r _f; do
    [[ -n "${_f}" ]] && decoded_diff_files+=("${_f}")
  done < <(echo "${xml_diff}" | awk '
    /^diff / {
      if (cur != "" && bad) print cur
      idx = index($0, " /b/"); cur = (idx > 0) ? substr($0, idx+4) : ""
      in_s0 = (index(cur, "splits0.xml") > 0)
      bad = 0; next
    }
    in_s0 { next }
    /^[<>]/ {
      if ($0 !~ /com\.android\.stamp\.|vending\.derived\.apk\.id|stamp-cert-sha256/ &&
          $0 !~ /<[\/]?application[ >\/]/) bad = 1
      next
    }
    /^Binary files/ {
      if (cur != "" && bad) { print cur; cur = ""; bad = 0 }
      idx = index($0, " /b/")
      if (idx > 0) { p = substr($0, idx+4); sub(/ differ$/, "", p); print p }
      next
    }
    /^Only in/ {
      if (cur != "" && bad) { print cur; cur = ""; bad = 0 }
      if ($0 !~ /com\.android\.stamp\.|vending\.derived\.apk\.id|stamp-cert-sha256/) {
        dir = $3; sub(/:$/, "", dir); sub(/^\/[ab]\//, "", dir)
        print dir "/" $4
      }
      next
    }
    END { if (cur != "" && bad) print cur }
  ')

  # Binary .so comparison (arm64 split carries all native libs; others have no lib/)
  so_diffs=()
  so_identical_local=()
  if [[ -d "${off_decoded}/lib" ]]; then
    while IFS= read -r so_path; do
      [[ -f "${so_path}" ]] || continue
      rel="${so_path#${off_decoded}/}"
      blt_so="${blt_decoded}/${rel}"
      soname="$(basename "${rel}")"
      if [[ ! -f "${blt_so}" ]]; then
        so_diffs+=("${soname} (missing)")
      elif ! cmp -s "${so_path}" "${blt_so}"; then
        so_diffs+=("${soname}")
      else
        so_identical_local+=("${soname}")
      fi
    done < <(find "${off_decoded}/lib" -name "*.so" | sort)
    for _d in "${so_diffs[@]}"; do all_so_diffs+=("${_d}"); done
    for _i in "${so_identical_local[@]}"; do all_so_identical+=("${_i}"); done
  fi
  for _f in "${decoded_diff_files[@]}"; do all_decoded_diff_files+=("${_f}"); done
  so_count="${#so_diffs[@]}"

  split_total=$((xml_lines + so_count))
  total_diff_count=$((total_diff_count + split_total))

  if [[ "${split_total}" -eq 0 ]]; then
    split_verdict="reproducible"
    reproducible_count=$((reproducible_count + 1))
    split_note=""
  else
    split_verdict="not_reproducible"
    not_reproducible_count=$((not_reproducible_count + 1))
    _note_parts=()
    [[ "${so_count}" -gt 0 ]] && _note_parts+=("${so_count} native .so differ")
    if [[ "${#decoded_diff_files[@]}" -gt 0 ]]; then
      _note_parts+=("$(IFS=', '; echo "${decoded_diff_files[*]}")")
    fi
    if [[ "${#_note_parts[@]}" -gt 0 ]]; then
      split_note=" ($(IFS='; '; echo "${_note_parts[*]}"))"
    else
      split_note=""
    fi
  fi

  split_verdicts+=("${fname}: ${split_verdict}${split_note}")
  log_info "  ${fname}: xml=${xml_lines} so=${so_count} → ${split_verdict}"
  log_info "    official: ${off_hash}"
  log_info "    built:    ${built_hash_s}"
  [[ "${so_count}" -gt 0 ]] && log_info "    differing .so: $(IFS=', '; echo "${so_diffs[*]}")"

  aggregated_diff+="=== ${fname} (${split_verdict}) ===\n"
  [[ -n "${xml_diff}" ]] && aggregated_diff+="${xml_diff}\n" || aggregated_diff+="(xml identical)\n"
  [[ "${so_count}" -gt 0 ]] && \
    aggregated_diff+="Differing .so (${so_count}): $(IFS=', '; echo "${so_diffs[*]}")\n"
  aggregated_diff+="\n"

  echo -e "${xml_diff}" > "${work_dir}/diff_${key}_xml.txt"
  printf '%s\n' "${so_diffs[@]}" > "${work_dir}/diff_${key}_so.txt"
done

# Flag extra splits in built output that weren't in official
for blt_apk in "${built_splits_dir}"/*.apk; do
  [[ -f "${blt_apk}" ]] || continue
  fname="$(basename "${blt_apk}")"
  if [[ ! -f "${official_splits_dir}/${fname}" ]]; then
    log_warn "Extra split in built (not in official): ${fname}"
    total_diff_count=$((total_diff_count + 1))
    append_info "Extra split in built output: ${fname}"
  fi
done

total_splits=$((reproducible_count + not_reproducible_count))

# ------------------------------------------------------------------------------
# Verdict and YAML
# ------------------------------------------------------------------------------
if [[ "${total_diff_count}" -eq 0 ]]; then
  yaml_status="reproducible"
  verdict="${total_splits} of ${total_splits} artifacts reproducible"
else
  yaml_status="not_reproducible"
  verdict="${reproducible_count} of ${total_splits} artifacts reproducible"
fi

# Build per-artifact summary for YAML notes
split_summary=""
for entry in "${split_verdicts[@]}"; do
  split_summary+="  ${entry}
"
done

YAML_NOTES="Stack Wallet ${version_name} (versionCode ${version_code}) — tag ${git_tag}.
Input: ${input_mode}${apk_target:+ (${apk_target})}; built from commit ${commit_hash}
(${commit_source}).
Toolchain: Flutter 3.44.9 / Dart SDK 3.12.2, JDK 21, Rust 1.89.0+1.85.1
(+1.92.0 as stable for cargokit), Go 1.24.4, NDK 28.2.13676358 + 28.0.13004108,
bundletool 1.17.2, apktool 2.9.3. Build env mimics the maintainer's workstation
(HOME=/home/diego, source /home/diego/Desktop/releases/stack_wallet).
Comparison method: apktool decode (resources.arsc decoded to res/ XML).

${reproducible_count} of ${total_splits} artifacts reproducible
(device config: ${detected_abi}, ${screen_density}dpi, locales: ${locale_list}).

Per-artifact verdicts:
${split_summary}"

# Acceptable diffs section — only items actually observed during this run
_acceptable=""
[[ "${found_stamp_artifacts}" == true ]] && _acceptable+="
- AndroidManifest.xml: Play Store distribution stamps (com.android.stamp.*, vending.derived.apk.id, stamp-cert-sha256)"
[[ "${found_locale_norm}" == true ]] && _acceptable+="
- res/xml/splits0.xml: locale code normalization in->id, iw->he (Google Play processing)"
_acceptable+="
- resources.arsc: decoded via apktool; binary diffs not visible if decoded res/ is identical"

YAML_NOTES+="
Acceptable diffs excluded from verdict:${_acceptable}"

# Native .so findings — populated from actual comparison results
if [[ "${#all_so_diffs[@]}" -gt 0 ]]; then
  _so_diff_list="$(IFS=', '; echo "${all_so_diffs[*]}")"
  YAML_NOTES+="

Differing native .so (${#all_so_diffs[@]}): ${_so_diff_list}"
fi
if [[ "${#all_so_identical[@]}" -gt 0 ]]; then
  _so_identical_list="$(IFS=', '; echo "${all_so_identical[*]}")"
  YAML_NOTES+="
Identical native .so (${#all_so_identical[@]}): ${_so_identical_list}"
fi
if [[ "${#all_decoded_diff_files[@]}" -gt 0 ]]; then
  _decoded_list="$(IFS=', '; echo "${all_decoded_diff_files[*]}")"
  YAML_NOTES+="

Other differing files (${#all_decoded_diff_files[@]}): ${_decoded_list}"
fi
write_yaml "${yaml_status}" "${YAML_NOTES}"
log_info "COMPARISON_RESULTS.yaml written."

# ------------------------------------------------------------------------------
# Results output
# ------------------------------------------------------------------------------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name_apk:-${version_name}}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${yaml_status}"
echo "appHash:        ${official_base_hash}"
echo "commit:         ${commit_hash}"
echo "commitSource:   ${commit_source}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_HASH}"
echo "gitTag:         ${git_tag}"
echo "summary:        ${verdict}"
echo ""
echo "Per-artifact results:"
for entry in "${split_verdicts[@]}"; do echo "  ${entry}"; done
if [[ "${#all_so_diffs[@]}" -gt 0 ]]; then
  echo ""
  echo "Differing native .so (${#all_so_diffs[@]}):"
  for so in "${all_so_diffs[@]}"; do echo "  ${so}"; done
fi
if [[ "${#all_so_identical[@]}" -gt 0 ]]; then
  echo ""
  echo "Identical native .so (${#all_so_identical[@]}):"
  for so in "${all_so_identical[@]}"; do echo "  ${so}"; done
fi
if [[ "${#all_decoded_diff_files[@]}" -gt 0 ]]; then
  echo ""
  echo "Other differing files (${#all_decoded_diff_files[@]}):"
  for f in "${all_decoded_diff_files[@]}"; do echo "  ${f}"; done
fi
echo ""
echo "Diff detail (first 5 lines; full diffs in ${work_dir}/diff_*_xml.txt + diff_*_so.txt):"
echo -e "${aggregated_diff}" | head -5
if [[ "${should_cleanup}" != "true" ]]; then
  echo ""
  echo "Decoded APK dirs: ${decoded_dir}"
fi
echo "===== End Results ====="

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
if [[ "${should_cleanup}" == "true" ]]; then
  log_info "Cleaning up: ${work_dir}"
  reclaim_workspace
  rm -rf "${work_dir}"
fi

if [[ "${total_diff_count}" -eq 0 ]]; then
  echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}"
else
  echo "Exit code: ${EXIT_FAILED}"; exit "${EXIT_FAILED}"
fi
