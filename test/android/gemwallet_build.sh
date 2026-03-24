#!/bin/bash
# ==============================================================================
# gemwallet_build.sh - Gem Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.6
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-24
# App:           Gem Wallet Android
# App ID:        com.gemwallet.android
# Project:       https://github.com/gemwalletcom/gem-android
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/com.gemwallet.android/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose. Users assume all risks
# associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws and regulations. The developers assume no liability for any
# misuse or legal consequences arising from use. By using this script, you
# acknowledge these disclaimers and accept full responsibility.
#
# NOTE — GPR Token Required:
# Gem Wallet depends on trustwallet/wallet-core published as a GitHub Package
# (Maven) at maven.pkg.github.com/trustwallet/wallet-core. This package is NOT
# on Maven Central. A GitHub Personal Access Token with read:packages scope is
# required. Without it, Gradle fails at ":app:mergeUniversalReleaseNativeLibs"
# with "Username must not be null!".
# Pass --github-token <PAT> or set the GITHUB_TOKEN environment variable.
#
# NOTE — R8 Map-ID Non-Determinism (AGP 9.0.x Known Issue):
# AGP 9.0.x embeds a non-deterministic pg-map-id in classes*.dex and
# assets/dexopt/baseline.prof. Gem Wallet ships fix_pg_map_id.py to patch
# this, but v0.1.0 of this script does NOT apply the patch. If diffs are
# limited to classes*.dex and assets/dexopt/baseline.prof, consult the upstream
# fix before concluding not_reproducible. Human verdict writers should evaluate
# this evidence carefully.
#
# SCRIPT SUMMARY:
# Single operating mode: split mode (--binary or --apk).
#
#   split mode (--binary <split.apk> or --apk <split.apk>):
#     Accepts one official split APK from Google Play (e.g. base.apk or
#     split_config.arm64_v8a.apk). Auto-detects version from APK metadata
#     unless --version is supplied (Zeus-pattern: aapt -> aapt2 -> apktool).
#     Builds AAB via :app:bundleGoogleRelease inside a container. Extracts
#     split APKs from the AAB using bundletool + device-spec.json. Finds the
#     matching built split by name, unzips both, and runs diff -r. Applies
#     Leo's META-INF filter. Generates COMPARISON_RESULTS.yaml with verdict.
#
# GPR credentials are injected into local.properties inside the container.
# google-services.json is committed in the repo at app/google-services.json
# and does NOT need to be injected (unlike Tangem).
# ==============================================================================

set -euo pipefail

# Capture execution directory before anything can change CWD.
# COMPARISON_RESULTS.yaml is always written here (build server picks it up).
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"

# ------------------------------------------------------------------------------
# Script metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="v0.1.6"
readonly SCRIPT_NAME="gemwallet_build.sh"
readonly APP_ID="com.gemwallet.android"
readonly REPO_URL="https://github.com/gemwalletcom/gem-android.git"
# WalletScrutiny reference container — provides apksigner, apktool, aapt, aapt2
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
# Build environment image tag (built once, reused across runs)
readonly GEMWALLET_BUILD_IMAGE="gemwallet_build_env:1"
# Bundletool version pinned to match upstream (bundletool 1.17.2 in Gem Wallet CI)
readonly BUNDLETOOL_VERSION="1.17.2"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

# ------------------------------------------------------------------------------
# Global state (set during argument parsing and prepare phases)
# ------------------------------------------------------------------------------
VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""         # absolute path to the split APK passed via --binary/--apk
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
github_token=""
github_user="walletscrutiny"
REQUESTED_TAG=""
should_cleanup=false

# Set during prepare/build
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""       # canonical path in WORK_DIR to the official split APK
OFFICIAL_BASE_APK=""  # same as OFFICIAL_APK (used for metadata extraction)
BUILT_AAB=""          # path to the AAB produced by the build
GIT_TAG=""            # resolved git tag (e.g. "1.3.105")
RESULT_DONE=false     # set true by result() after writing COMPARISON_RESULTS.yaml
TOTAL_DIFFS=1         # default to "failed" until compare_split_apks() runs cleanly

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_fail()  { echo "[FAIL] $*"; }
log_warn()  { echo "[WARNING] $*"; }

# Runs grep safely; returns "0" on no-match instead of failing the script.
# Used to avoid set -e killing the script when grep finds nothing.
safe_grep_count() {
    local grep_output
    grep_output="$("$@" 2>/dev/null || true)"
    grep_output="${grep_output//$'\n'/}"
    [[ -n "${grep_output}" ]] && printf '%s\n' "${grep_output}" || printf '0\n'
}

work_dir_path() {
    local version_part="$1"
    local arch_part="$2"
    printf '%s/%s_%s_%s_%s\n' \
        "${EXEC_DIR}" \
        "${WORK_DIR_PREFIX}" \
        "${APP_ID}" \
        "${version_part}" \
        "${arch_part}"
}

# ------------------------------------------------------------------------------
# YAML output helpers
# Writes COMPARISON_RESULTS.yaml to both EXEC_DIR (required by build server)
# and WORK_DIR (copy for post-analysis). The EXEC_DIR write is always attempted
# first; the WORK_DIR copy is best-effort (WORK_DIR may not exist yet for early
# errors like a missing container runtime).
# ------------------------------------------------------------------------------
write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "$content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
    fi
}

generate_error_yaml() {
    # Writes a minimal ftbfs YAML with an optional notes field.
    # Used for early-exit conditions (missing token, missing runtime, etc.)
    local status="$1"
    local notes="${2:-}"
    if [[ -n "${notes}" ]]; then
        write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  ${notes}"
    else
        write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}"
    fi
}

generate_comparison_yaml() {
    # Writes the final 3-field COMPARISON_RESULTS.yaml per the 2026-03-12 format.
    # Fields: script_version, verdict, notes (notes is a YAML literal block scalar).
    local verdict="$1"
    local notes="$2"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    log_info "Generated COMPARISON_RESULTS.yaml (verdict: ${verdict})"
}

# ------------------------------------------------------------------------------
# Error handling — dual trap pattern (tangem/nunchuk proven pattern)
#
# on_error: fired by ERR trap. Catches any unexpected non-zero exit during build.
#   Writes ftbfs YAML if RESULT_DONE is false, then exits 1.
#
# cleanup_on_error: fired by EXIT trap. Guards against the on_error trap being
#   bypassed (e.g. explicit exit calls). Only writes YAML if WORK_DIR is set,
#   so that early parameter errors (exit 2, before prepare()) do NOT produce a
#   false ftbfs artifact.
# ------------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=$1
    set +e
    log_fail "Script failed at line ${line_no} (exit code ${exit_code})"
    if [[ "${RESULT_DONE}" != "true" ]]; then
        generate_error_yaml "ftbfs" || true
    fi
    echo "Exit code: ${EXIT_FAILED}"
    exit "${EXIT_FAILED}"
}

cleanup_on_error() {
    local exit_code=$?
    # Only write ftbfs YAML if:
    #   (a) script is exiting non-zero, AND
    #   (b) RESULT_DONE is false (no verdict was written yet), AND
    #   (c) WORK_DIR is set (we are past argument parsing)
    # This prevents a false ftbfs YAML for parameter validation errors
    # that happen before prepare() sets WORK_DIR.
    if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" && -n "${WORK_DIR:-}" ]]; then
        log_warn "Script failed with exit code: ${exit_code}"
        log_warn "Work directory preserved: ${WORK_DIR}"
        generate_error_yaml "ftbfs" || true
    fi
}

trap 'on_error $LINENO' ERR
trap 'cleanup_on_error'  EXIT

# ------------------------------------------------------------------------------
# Container runtime detection
# Prefer podman (rootless); fall back to docker. Sets CONTAINER_CMD,
# VOLUME_RO, VOLUME_RW, and CONTAINER_RUN_EXTRA for the detected runtime.
# ------------------------------------------------------------------------------
detect_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        VOLUME_RO=":ro,Z"
        VOLUME_RW=":Z"
        CONTAINER_RUN_EXTRA="--userns=keep-id"
        log_info "Using podman as container runtime"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        VOLUME_RO=":ro"
        VOLUME_RW=""
        CONTAINER_RUN_EXTRA="--user $(id -u):$(id -g)"
        log_info "Using docker as container runtime"
    else
        # WORK_DIR is not set at this point — write YAML directly to EXEC_DIR
        cat > "${EXEC_DIR}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  Neither podman nor docker found on host. Install one to continue.
EOF
        echo "[ERROR] Neither podman nor docker is available."
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi
}

# ------------------------------------------------------------------------------
# Container helpers
# container_exec: runs a bash command inside WORK_DIR (mounted at /work) using
#   the build image. Used for bundletool, diff, and other build tasks.
# ws_exec: same but uses the WalletScrutiny reference container. Used for
#   apktool, aapt, aapt2, apksigner, sha256sum — tools not in the build image.
# ------------------------------------------------------------------------------
container_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${GEMWALLET_BUILD_IMAGE}" \
        bash -c "$cmd"
}

ws_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${WS_CONTAINER}" \
        sh -c "$cmd"
}

# Compute SHA-256 of a file using the WS container's sha256sum.
# Returns the hex digest only (no filename suffix).
container_sha256() {
    local file_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$file_path"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "sha256sum /data/$(basename "$file_path") | awk '{print \$1}'"
}

# Extract the signing certificate SHA-256 from an APK via apksigner.
# Returns only the hex fingerprint of Signer #1.
container_signer() {
    local apk_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$apk_path"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "apksigner verify --print-certs /apk/$(basename "$apk_path") 2>/dev/null \
               | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

# Extract versionName or versionCode from an APK using the Zeus-pattern:
# Try aapt first, then aapt2, then apktool as fallback. Never reads from filename.
# This is the most robust method for split APKs where aapt may be unavailable.
container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm \
        -v "${apk_dir}:/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c '
            out="$({ aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null \
                  || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
            if [ -n "$out" ]; then
                printf "%s\n" "$out" \
                    | sed -n "s/.*'"${field}"'='"'"'\([^'"'"']*\)'"'"'.*/\1/p" \
                    | head -n1
                exit 0
            fi
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
                case "'"${field}"'" in
                    versionName)
                        sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" \
                            "$tmpdir/out/apktool.yml" | head -n1 ;;
                    versionCode)
                        sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" \
                            "$tmpdir/out/apktool.yml" | head -n1 ;;
                esac
            fi
            rm -rf "$tmpdir"
        ' 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Split APK name helpers (MetaMask/Tangem pattern)
# Google Play split APK naming is inconsistent: Play may serve base.apk,
# base-master.apk, or split_config.<abi>.apk. canonicalize_split_apk_name
# normalizes all known variants to a stable canonical form so we can match
# them against bundletool output.
# ------------------------------------------------------------------------------
canonicalize_split_apk_name() {
    local apk_name="$1"
    case "$apk_name" in
        base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
        split_config.*.apk) echo "$apk_name" ;;
        base-*.apk) echo "split_config.${apk_name#base-}" ;;
        *) echo "$apk_name" ;;
    esac
}

# Find the base split APK in the official-split-apks directory.
# Tries base.apk first, then base-master.apk, then any base*.apk.
find_official_base_apk() {
    local dir="${WORK_DIR}/official-split-apks"
    if   [[ -f "${dir}/base.apk" ]];        then echo "${dir}/base.apk"; return; fi
    if   [[ -f "${dir}/base-master.apk" ]]; then echo "${dir}/base-master.apk"; return; fi
    local matches=("${dir}"/base*.apk)
    [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]] && echo "${matches[0]}" && return
}

# Find the built split APK in built_dir that corresponds to official_apk.
# Tries exact name match first, then canonical name match.
resolve_built_split_apk() {
    local official_apk="$1"
    local built_dir="$2"
    local official_name canonical_name
    official_name="$(basename "$official_apk")"
    [[ -f "${built_dir}/${official_name}" ]] && echo "${built_dir}/${official_name}" && return 0
    canonical_name="$(canonicalize_split_apk_name "$official_name")"
    [[ -f "${built_dir}/${canonical_name}" ]] && echo "${built_dir}/${canonical_name}" && return 0
    return 1
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
NAME
       ${SCRIPT_NAME} - Gem Wallet Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --binary <split.apk> [OPTIONS]
       ${SCRIPT_NAME} --apk <split.apk> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Builds Gem Wallet Android from source in a container and compares
       against an official split APK from Google Play.

       --binary <file> (or --apk <file>):
         Accepts one official split APK from Google Play (e.g. base.apk or
         split_config.arm64_v8a.apk). Version is auto-detected from APK
         metadata unless --version is provided.
         Builds AAB via :app:bundleGoogleRelease, extracts splits with
         bundletool + device-spec.json, and compares the matching split.

REQUIRED
       --github-token <token>   GitHub PAT with read:packages scope.
                                Alias: GITHUB_TOKEN env var.
                                Required for trustwallet/wallet-core from GPR.

OPTIONS
       --binary <file>          Path to one official Play Store split APK.
                                Alias: --apk.
       --version <version>      Version to verify (e.g. 1.3.105). Optional;
                                auto-detected from APK metadata if omitted.
       --arch <arch>            Target ABI for device-spec.json.
                                Default: arm64-v8a.
       --type <type>            Accepted for build server compatibility; unused.
       --github-user <user>     GitHub username for GPR (default: walletscrutiny).
                                Alias: GITHUB_USER env var.
       --tag <ref>              Override git tag (default: auto-resolved from
                                version using bare tag format e.g. 1.3.105).
       --cleanup                Remove work directory after completion.
       --script-version         Print script version and exit.
       --help                   Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF differences after filtering, or identical)
       1    Differences found or build failure
       2    Invalid parameters

ENVIRONMENT
       GITHUB_TOKEN     GitHub PAT with read:packages scope (required)
       GITHUB_USER      GitHub username (optional, default: walletscrutiny)

EXAMPLES
       # Provide the base.apk from Google Play (version auto-detected):
       export GITHUB_TOKEN=ghp_yourtoken
       ${SCRIPT_NAME} --binary ~/apks/base.apk

       # Explicit version + architecture:
       ${SCRIPT_NAME} --binary ~/apks/split_config.arm64_v8a.apk \\
           --version 1.3.105 --arch arm64-v8a --github-token ghp_xxxx

NOTES
       Only prerequisite on the host: docker or podman.
       Everything else runs inside the container.
       Gem Wallet uses bare version number tags (e.g. 1.3.105, not v1.3.105).
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# All unknown parameters are logged as warnings and silently ignored.
# Scripts must never fail on unknown/extra parameters (ABS compliance,
# Luis 2026-03-12: unknown params must not be fatal).
# --type is accepted with a warning (unused for Android split mode).
# ------------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)
                # Version of the app to verify. Optional in split mode.
                VERSION="${2:-}"; shift ;;
            --apk|--binary)
                # Path to one official split APK from Google Play.
                APK_INPUT="${2:-}"; shift ;;
            --arch)
                # Target ABI for device-spec.json (default: arm64-v8a).
                ARCH="${2:-}"; shift ;;
            --type)
                # Accepted for build server compatibility; unused in split mode.
                TYPE="${2:-}"; shift
                log_warn "--type '${TYPE}' accepted but unused (android split mode)" ;;
            --github-token)
                # GitHub PAT with read:packages scope for GPR dependency.
                github_token="${2:-}"; shift ;;
            --github-user)
                # GitHub username for GPR authentication.
                github_user="${2:-}"; shift ;;
            --tag)
                # Override git tag resolution (bypass auto-detect).
                REQUESTED_TAG="${2:-}"; shift ;;
            --cleanup)
                # Remove work directory after script completes.
                should_cleanup=true ;;
            --script-version)
                echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
                echo "Exit code: ${EXIT_SUCCESS}"
                exit "${EXIT_SUCCESS}" ;;
            --help|-h)
                usage
                echo "Exit code: ${EXIT_SUCCESS}"
                exit "${EXIT_SUCCESS}" ;;
            *)
                # Unknown parameter: log and continue. Never fatal (ABS rule).
                log_warn "Ignoring unknown argument: $1" ;;
        esac
        shift
    done

    # Root check: build server runs as normal user; root is never required.
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Do not run this script as root."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Resolve credentials from environment if not provided via flags.
    [[ -z "${github_token}" && -n "${GITHUB_TOKEN:-}" ]] && github_token="${GITHUB_TOKEN}"
    [[ "${github_user}" == "walletscrutiny" && -n "${GITHUB_USER:-}" ]] && github_user="${GITHUB_USER}"

    # --binary / --apk is required (this script is split mode only).
    if [[ -z "${APK_INPUT}" ]]; then
        echo "[ERROR] --binary <split.apk> is required."
        echo "        This script verifies one split APK from Google Play."
        echo "        Pass a GITHUB_TOKEN (read:packages) for the wallet-core dependency."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Validate that the APK file exists on the host before doing anything else.
    if [[ ! -f "${APK_INPUT}" ]]; then
        echo "[ERROR] --binary file not found: ${APK_INPUT}"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Resolve relative path to absolute so it stays valid after any CWD changes.
    [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"

    # Default architecture for device-spec.json.
    ARCH="${ARCH:-arm64-v8a}"

    # Validate arch. Non-fatal: unknown arch gets a warning and uses the default.
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            log_warn "Unrecognized arch '${ARCH}'; defaulting to arm64-v8a"
            ARCH="arm64-v8a"
            ;;
    esac

    # GPR token check: must happen BEFORE setting WORK_DIR so that
    # cleanup_on_error does NOT fire (WORK_DIR is empty = no false ftbfs YAML
    # from the EXIT trap). We write the YAML explicitly here, set RESULT_DONE,
    # and exit with EXIT_FAILED (code 1, not 2, per ftbfs convention).
    if [[ -z "${github_token}" ]]; then
        # Write ftbfs YAML directly to EXEC_DIR (WORK_DIR not set yet).
        cat > "${EXEC_DIR}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  GitHub token not provided. Gem Wallet depends on trustwallet/wallet-core
  from maven.pkg.github.com/trustwallet/wallet-core (a private GitHub Package
  not available on Maven Central). A GitHub Personal Access Token with
  read:packages scope is required.
  Pass --github-token <PAT> or set the GITHUB_TOKEN environment variable.
EOF
        RESULT_DONE=true
        echo "[ERROR] GitHub token required for wallet-core GPR dependency."
        echo "        Pass --github-token <PAT> or set GITHUB_TOKEN env var."
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi

    # Set safe-for-filesystem version and arch strings (used in WORK_DIR name).
    # VERSION_SAFE is "provided" until auto-detection updates it in prepare().
    # The work directory lives under EXEC_DIR, not /tmp, so the launching user
    # can remove stale runs without requiring host root privileges.
    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"

    log_info "Work directory: ${WORK_DIR}"
    log_info "Arch: ${ARCH}"
    log_info "APK input: ${APK_INPUT}"
}

# ------------------------------------------------------------------------------
# Build image management
# Builds gemwallet_build_env:1 from an inline Dockerfile if the image does not
# already exist. Image is inspected first; if present it is reused without a
# rebuild (saving 10-20 minutes on repeat runs).
#
# Inline Dockerfile mirrors the repo's Dockerfile (gradle:9.0.0-jdk17 base)
# except:
#   - No --mount=type=cache (not universally supported across Docker/Podman)
#   - No setup-multiarch-apt.sh (helper script not in our build context)
#   - Adds bundletool 1.17.2 for split APK extraction from AAB
#   - Adds apktool for version metadata fallback (Zeus-pattern)
#   - android-36 installed via --channel=3 (may not be in stable channel yet)
# ------------------------------------------------------------------------------
ensure_build_image() {
    if ${CONTAINER_CMD} image inspect "${GEMWALLET_BUILD_IMAGE}" >/dev/null 2>&1; then
        log_info "Build image ${GEMWALLET_BUILD_IMAGE} already exists, skipping build."
        return 0
    fi

    log_info "Building ${GEMWALLET_BUILD_IMAGE} from inline Dockerfile..."
    log_info "Installs: Android SDK 35+36, NDK 28.1.13356709, just 1.45.0, bundletool ${BUNDLETOOL_VERSION}."
    log_info "Estimated time: 10-20 minutes depending on network speed."

    local dockerfile_path="${WORK_DIR}/Dockerfile.build"

    # The Dockerfile below targets linux/amd64 (x86_64 just binary, standard apt).
    # Base image gradle:9.0.0-jdk17 matches the repo's ARG GRADLE_IMAGE.
    cat > "${dockerfile_path}" <<'DOCKERFILE_END'
FROM docker.io/library/gradle:9.0.0-jdk17

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/platform-tools:${PATH}

# Install system packages required by Android SDK tools and the build process.
# apktool is included for the Zeus-pattern version metadata fallback.
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        wget \
        unzip \
        ca-certificates \
        python3 \
        apktool \
    && rm -rf /var/lib/apt/lists/*

# Install just 1.45.0 task runner (x86_64 musl binary, statically linked).
# Gem Wallet uses just for its justfile recipes. Version is pinned to match CI.
RUN curl -fL \
        "https://github.com/casey/just/releases/download/1.45.0/just-1.45.0-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/just.tar.gz && \
    tar -xzf /tmp/just.tar.gz -C /tmp just && \
    mv /tmp/just /usr/local/bin/just && \
    rm -f /tmp/just.tar.gz

# Download Android cmdline-tools 11076708. This is the specific build that the
# repo's Dockerfile references (ARG CMDLINE_TOOLS_VERSION=11076708).
RUN mkdir -p "${ANDROID_HOME}" /root/.android && \
    curl -fL \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -o /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d "${ANDROID_HOME}" && \
    rm -f /tmp/sdk.zip

# Accept SDK licenses, then install platform-tools, android-35, build-tools 35.0.0,
# and NDK 28.1.13356709. android-36 is attempted from the stable channel first,
# then from --channel=3 (canary/beta) as it may not yet be in stable.
RUN yes | ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} --licenses > /dev/null 2>&1 && \
    ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
        "ndk;28.1.13356709" && \
    ( ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} \
        "platforms;android-36" 2>/dev/null || \
      ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} \
        --channel=3 \
        "platforms;android-36" 2>/dev/null || \
      echo "[WARNING] android-36 not installed — build may fail if compileSdk=36 is required" )

# Install bundletool 1.17.2 so split APKs can be extracted from the built AAB.
# The jar is placed at a fixed path and a wrapper script makes it callable as
# a plain command inside the container.
RUN wget -q \
        "https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar" \
        -O /usr/local/lib/bundletool.jar && \
    printf '#!/bin/bash\nexec java -jar /usr/local/lib/bundletool.jar "$@"\n' \
        > /usr/local/bin/bundletool && \
    chmod +x /usr/local/bin/bundletool

CMD ["bash"]
DOCKERFILE_END

    # Build the image. --no-cache ensures a clean reproducible image.
    ${CONTAINER_CMD} build \
        --no-cache \
        --tag "${GEMWALLET_BUILD_IMAGE}" \
        --file "${dockerfile_path}" \
        "${WORK_DIR}"

    log_pass "Build image ${GEMWALLET_BUILD_IMAGE} ready."
}

# ------------------------------------------------------------------------------
# Git tag resolution
# Gem Wallet uses bare version tags (e.g. 1.3.105) without a 'v' prefix.
# Tries the bare version first, then v<version> as a fallback in case the
# project's convention changes.
# Sets global GIT_TAG on success; returns 1 on failure.
# ------------------------------------------------------------------------------
resolve_git_tag() {
    local version="$1"
    local candidates=("${version}" "v${version}")

    log_info "Resolving git tag for version ${version}..."
    for candidate in "${candidates[@]}"; do
        if git ls-remote --tags --exit-code "${REPO_URL}" \
                "refs/tags/${candidate}" >/dev/null 2>&1; then
            log_info "Found tag: ${candidate}"
            GIT_TAG="${candidate}"
            return 0
        fi
        log_info "  Tag ${candidate}: not found"
    done

    log_fail "Could not find git tag for version ${version}"
    log_fail "Tried: ${candidates[*]}"
    return 1
}

# ------------------------------------------------------------------------------
# device-spec.json for bundletool
# Specifies the target device capabilities. bundletool uses this to select
# which split APKs to include when extracting from the AAB.
# ------------------------------------------------------------------------------
create_device_spec() {
    local output_path="$1"
    local arch="$2"
    # sdkVersion 31 covers the vast majority of modern Play Store devices.
    # screenDensity 480 = xxhdpi (most common for flagship phones).
    cat > "${output_path}" <<EOF
{
  "supportedAbis": ["${arch}"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 31
}
EOF
    log_info "device-spec.json created (arch=${arch}, sdkVersion=31, density=480)"
}

# ------------------------------------------------------------------------------
# Extract split APKs from a built AAB using bundletool
# Runs inside GEMWALLET_BUILD_IMAGE which has bundletool installed at
# /usr/local/lib/bundletool.jar. Outputs splits to ${output_dir}/splits/.
# Normalizes base-master.apk -> base.apk (bundletool may use either name).
# ------------------------------------------------------------------------------
extract_split_apks_from_aab() {
    local aab_path="$1"
    local device_spec_path="$2"
    local output_dir="$3"

    mkdir -p "${output_dir}"

    # Compute paths relative to WORK_DIR for use inside the container
    # (container mounts WORK_DIR at /work).
    local aab_rel device_spec_rel apks_rel output_rel
    aab_rel="${aab_path#"${WORK_DIR}/"}"
    device_spec_rel="${device_spec_path#"${WORK_DIR}/"}"
    apks_rel="built-splits.apks"
    output_rel="${output_dir#"${WORK_DIR}/"}"

    log_info "Running bundletool to extract split APKs from $(basename "${aab_path}")..."

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${GEMWALLET_BUILD_IMAGE}" \
        bash -c "
            set -euo pipefail
            java -jar /usr/local/lib/bundletool.jar build-apks \
                --bundle='${aab_rel}' \
                --output='${apks_rel}' \
                --device-spec='${device_spec_rel}' \
                --mode=default \
                --overwrite 2>&1
            mkdir -p '${output_rel}'
            unzip -qq -o '${apks_rel}' -d '${output_rel}' 2>&1 || true
            chmod -R a+rwX '${output_rel}' 2>/dev/null || true
        "

    # bundletool puts splits under a splits/ subdirectory inside the .apks archive.
    local splits_subdir="${output_dir}/splits"

    # Normalize: base-master.apk -> base.apk (bundletool naming varies by version).
    if [[ -f "${splits_subdir}/base-master.apk" ]]; then
        mv "${splits_subdir}/base-master.apk" "${splits_subdir}/base.apk"
        log_info "Renamed base-master.apk -> base.apk"
    fi

    # Normalize: base-<suffix>.apk -> split_config.<suffix>.apk for ABI splits.
    # The 2>/dev/null must be part of the subshell, not the for-in glob pattern.
    while IFS= read -r split_apk; do
        [[ -f "${split_apk}" ]] || continue
        local split_name suffix
        split_name="$(basename "${split_apk}")"
        [[ "${split_name}" == "base-master.apk" ]] && continue
        suffix="${split_name#base-}"
        mv "${split_apk}" "${splits_subdir}/split_config.${suffix}"
    done < <(find "${splits_subdir}" -maxdepth 1 -name "base-*.apk" 2>/dev/null || true)

    local split_count
    split_count="$(find "${output_dir}" -name "*.apk" 2>/dev/null | wc -l)"
    log_info "Extracted ${split_count} split APK(s) to ${output_dir}"
    log_info "Available splits:"
    find "${output_dir}" -name "*.apk" 2>/dev/null | while IFS= read -r f; do
        echo "  $(basename "${f}")"
    done
}

# ------------------------------------------------------------------------------
# Unzip an APK into a directory using the WS container.
# Uses the WS reference container because it has unzip installed and is lighter
# than the full build image for this simple extraction task.
# ------------------------------------------------------------------------------
unzip_apk_in_container() {
    local apk_path="$1"
    local out_dir="$2"
    local apk_rel out_rel
    apk_rel="${apk_path#"${WORK_DIR}/"}"
    out_rel="${out_dir#"${WORK_DIR}/"}"
    ws_exec "mkdir -p '${out_rel}' && unzip -qq '${apk_rel}' -d '${out_rel}' 2>/dev/null || true && chmod -R a+rwX '${out_rel}' 2>/dev/null || true"
}

# ------------------------------------------------------------------------------
# Compare one official split APK against one built split APK.
# Unzips both into WORK_DIR/comparison/, runs diff -r, applies Leo's
# META-INF filter (2025-10-30). Full diff written to file; max 5 lines printed
# to terminal. Accumulates into global TOTAL_DIFFS counter.
#
# Leo's filter: only excludes root-level META-INF entries. Uses precise
# regex to avoid over-filtering META-INF appearing deeper in the tree.
# ------------------------------------------------------------------------------
compare_split_apks() {
    local official_apk="$1"
    local built_apk="$2"
    local split_label="$3"
    local results_dir="${WORK_DIR}/comparison"

    mkdir -p "${results_dir}"
    log_info "Comparing split: ${split_label}"

    local official_unzip="${results_dir}/official_${split_label}"
    local built_unzip="${results_dir}/built_${split_label}"
    local diff_file="${results_dir}/diff_${split_label}.txt"

    # Unzip both APKs for content-level comparison.
    unzip_apk_in_container "${official_apk}" "${official_unzip}"
    unzip_apk_in_container "${built_apk}"    "${built_unzip}"

    local official_rel built_rel diff_rel
    official_rel="${official_unzip#"${WORK_DIR}/"}"
    built_rel="${built_unzip#"${WORK_DIR}/"}"
    diff_rel="${diff_file#"${WORK_DIR}/"}"

    # Run recursive diff. Non-zero exit from diff is expected and suppressed.
    # Full output goes to the diff file for post-analysis.
    ws_exec "diff -r '${official_rel}' '${built_rel}' \
        > '${diff_rel}' 2>&1 || true"

    local total_lines=0
    local non_meta_count=0

    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        # Leo's META-INF filter (2025-10-30 policy): exclude only root-level
        # META-INF entries. Nested META-INF (e.g. inside a zip within the APK)
        # still counts as a real difference.
        non_meta_count="$(grep -E '^Only in |^Files ' "${diff_file}" \
            | grep -cvE \
              '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
            || echo 0)"
    fi

    TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
    log_info "  ${split_label}: ${non_meta_count} non-META-INF diff(s) (${total_lines} total diff lines)"

    if [[ -s "${diff_file}" ]]; then
        log_info "  First 5 lines (full diff: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
        if [[ "${total_lines}" -gt 5 ]]; then
            log_info "    ... (${total_lines} total lines — see ${diff_file})"
        fi
    else
        log_pass "  ${split_label}: no differences"
    fi
}

# ------------------------------------------------------------------------------
# Print the verification results block to stdout.
# Format follows the WalletScrutiny standardized output (Begin/End Results).
# Reads version, signer, and hash from the official APK via WS container.
# Reads commit hash and tag info from files saved during the build phase.
# ------------------------------------------------------------------------------
print_results_block() {
    local verdict="$1"
    local apk_path="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}"

    local version_name version_code signer app_hash commit tag_info
    version_name="$(container_aapt_version "${apk_path}" "versionName" || true)"
    version_code="$(container_aapt_version "${apk_path}" "versionCode" || true)"
    signer="$(container_signer "${apk_path}" || true)"
    app_hash="$(container_sha256 "${apk_path}" || true)"

    commit=""
    if [[ -f "${WORK_DIR}/built-output/commit.txt" ]]; then
        commit="$(cat "${WORK_DIR}/built-output/commit.txt")"
    fi

    tag_info=""
    if [[ -f "${WORK_DIR}/built-output/tag_verify.txt" ]]; then
        tag_info="$(cat "${WORK_DIR}/built-output/tag_verify.txt")"
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         ${signer:-unknown}"
    echo "apkVersionName: ${version_name:-${VERSION_SAFE}}"
    echo "apkVersionCode: ${version_code:-unknown}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${app_hash:-unknown}"
    echo "commit:         ${commit:-unknown}"
    echo ""

    echo "Diff:"
    local results_dir="${WORK_DIR}/comparison"
    local shown=0
    if [[ -d "${results_dir}" ]]; then
        for diff_file in "${results_dir}"/diff_*.txt; do
            [[ -f "${diff_file}" ]] || continue
            local split_label total_lines
            split_label="$(basename "${diff_file}" .txt)"
            if [[ -s "${diff_file}" ]]; then
                total_lines="$(wc -l < "${diff_file}")"
                echo "  ${split_label} (first 5 lines — full diff: ${diff_file}):"
                head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
                if [[ "${total_lines}" -gt 5 ]]; then
                    echo "    ... (${total_lines} lines total)"
                fi
            else
                echo "  ${split_label}: no differences"
            fi
            shown=$(( shown + 1 ))
        done
    fi
    if [[ "${shown}" -eq 0 ]]; then
        echo "  (no diff files found)"
    fi

    echo ""
    echo "Revision, tag (and its signature):"
    if [[ -n "${tag_info}" ]]; then
        echo "${tag_info}"
    else
        echo "  (tag verification not available)"
    fi

    echo "===== End Results ====="
    echo ""

    if [[ "${should_cleanup}" != "true" ]]; then
        echo "Work directory: ${WORK_DIR}"
        echo "Diff files:     ${WORK_DIR}/comparison/"
        echo ""
        echo "For deeper analysis:"
        echo "  diffoscope '${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK:-base.apk}")' \\"
        echo "             '${WORK_DIR}/built-split-apks/splits/$(basename "${OFFICIAL_APK:-base.apk}")'"
        echo "  meld '${WORK_DIR}/comparison'"
    fi
}

# ==============================================================================
# Phase 1: Prepare
# Sets up WORK_DIR. Copies the official APK, canonicalizes its name,
# auto-detects version from metadata if not provided, creates device-spec.json.
# ==============================================================================
prepare() {
    log_info "=== PREPARE PHASE ==="

    chmod -R a+rwX "${WORK_DIR}" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/official-split-apks"
    mkdir -p "${WORK_DIR}/built-output"
    # Ensure the build output dir is world-writable so the container user can write.
    chmod 777 "${WORK_DIR}/built-output"

    # Canonicalize the split APK name so matching against bundletool output is stable.
    local original_name canonical_name
    original_name="$(basename "${APK_INPUT}")"
    canonical_name="$(canonicalize_split_apk_name "${original_name}")"

    cp "${APK_INPUT}" "${WORK_DIR}/official-split-apks/${canonical_name}"
    if [[ "${original_name}" != "${canonical_name}" ]]; then
        log_info "Normalized split name: ${original_name} -> ${canonical_name}"
    fi

    OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
    OFFICIAL_BASE_APK="${OFFICIAL_APK}"

    # Auto-detect version from APK metadata if not provided via --version.
    # Zeus-pattern: aapt -> aapt2 -> apktool fallback. Never reads from filename.
    if [[ -z "${VERSION}" ]]; then
        log_info "Auto-detecting version from APK content..."
        VERSION="$(container_aapt_version "${OFFICIAL_APK}" "versionName" || true)"
        if [[ -z "${VERSION}" ]]; then
            log_fail "Could not detect version from APK. Pass --version explicitly."
            generate_error_yaml "ftbfs" \
                "Could not auto-detect versionName from split APK. Pass --version explicitly."
            RESULT_DONE=true
            exit "${EXIT_INVALID}"
        fi
        log_info "Version detected: ${VERSION}"
        VERSION_SAFE="${VERSION}"

        # Rename WORK_DIR to include the detected version (was "provided").
        local new_work_dir
        new_work_dir="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
        if [[ "${new_work_dir}" != "${WORK_DIR}" ]]; then
            rm -rf "${new_work_dir}"
            mv "${WORK_DIR}" "${new_work_dir}"
            WORK_DIR="${new_work_dir}"
            OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
            OFFICIAL_BASE_APK="${OFFICIAL_APK}"
            log_info "Work directory updated: ${WORK_DIR}"
        fi
    fi

    # Generate device-spec.json for bundletool to select the correct splits.
    create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"

    log_pass "Preparation complete. Work directory: ${WORK_DIR}"
}

# ==============================================================================
# Phase 2: Build image
# Ensures GEMWALLET_BUILD_IMAGE is ready. Separated from Phase 3 so that
# image build failures produce a clear ftbfs signal without attempting a clone.
# ==============================================================================
build_image() {
    log_info "=== BUILD IMAGE PHASE ==="
    ensure_build_image
}

# ==============================================================================
# Phase 3: Build from source
# Resolves the git tag, then runs clone + Gradle build in a single container
# invocation. GPR credentials are written to local.properties inside the
# container (not as Docker env vars to reduce exposure in docker inspect).
# SKIP_SIGN=true disables signing config in app/build.gradle.kts.
# google-services.json is committed in the repo; no injection needed.
# Saves commit hash and tag verification info to files for the results block.
# ==============================================================================
build() {
    log_info "=== BUILD PHASE ==="

    # Resolve git tag, preferring REQUESTED_TAG override if provided.
    GIT_TAG="${REQUESTED_TAG:-}"
    if [[ -z "${GIT_TAG}" ]]; then
        if ! resolve_git_tag "${VERSION_SAFE}"; then
            echo ""
            echo "======================================================"
            echo "  SOURCE NOT FOUND FOR VERSION ${VERSION_SAFE}"
            echo "  Tried tags: ${VERSION_SAFE}, v${VERSION_SAFE}"
            echo "  Repository: ${REPO_URL}"
            echo "======================================================"
            echo ""
            generate_comparison_yaml "ftbfs" \
                "Tag not found for version ${VERSION_SAFE}. Tried: ${VERSION_SAFE}, v${VERSION_SAFE}. Source code for this version has not been published as a tag in the Gem Wallet repository."
            RESULT_DONE=true
            echo "Exit code: ${EXIT_FAILED}"
            exit "${EXIT_FAILED}"
        fi
    fi
    log_info "Git tag: ${GIT_TAG}"
    log_info "Build task: :app:bundleGoogleRelease (AAB for Play Store split APK verification)"
    log_info "Cloning + building in container. May take 20-60 minutes."
    log_info "NOTE: --recursive clone required for Rust core/ (gemstone) submodule."
    log_info "NOTE: GPR credentials written to local.properties inside container."

    # All build steps run in a single container invocation to avoid leaking
    # credentials between steps. Volumes: built-output mounted at /workspace.
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-output:/workspace${VOLUME_RW}" \
        -e "HOME=/root" \
        -e "GRADLE_USER_HOME=/root/.gradle" \
        -e "SKIP_SIGN=true" \
        -e "ANDROID_HOME=/opt/android-sdk" \
        -e "ANDROID_SDK_ROOT=/opt/android-sdk" \
        "${GEMWALLET_BUILD_IMAGE}" \
        bash -c "set -euo pipefail

            echo '[INFO] Cloning ${REPO_URL} at tag ${GIT_TAG} (recursive for Rust submodule)...'
            git clone --depth 1 --recursive --branch '${GIT_TAG}' '${REPO_URL}' /workspace/app
            echo '[INFO] Clone complete.'

            cd /workspace/app

            # Record commit hash for the results block and for reproducibility evidence.
            git rev-parse HEAD > /workspace/commit.txt
            echo '[INFO] Commit: '\$(cat /workspace/commit.txt)

            # Tag type and signature verification (best-effort; no gnupg in container).
            # Gem Wallet uses lightweight tags (no GPG signing per CI analysis).
            # This will show GPG verify as unavailable — that is expected and OK.
            tag_type=\$(git cat-file -t 'refs/tags/${GIT_TAG}' 2>/dev/null || echo 'missing')
            printf 'TAG_TYPE=%s\n' \"\${tag_type}\" > /workspace/tag_verify.txt
            if [ \"\${tag_type}\" = 'tag' ]; then
                echo '[INFO] Annotated tag detected; attempting GPG verify...'
                git tag -v '${GIT_TAG}' >> /workspace/tag_verify.txt 2>&1 || \
                    printf 'GPG verify skipped (gnupg not in container)\n' >> /workspace/tag_verify.txt
            elif [ \"\${tag_type}\" = 'commit' ]; then
                printf 'LIGHTWEIGHT_TAG (no GPG object attached)\n' >> /workspace/tag_verify.txt
            else
                printf 'NO_TAG_OBJECT found\n' >> /workspace/tag_verify.txt
            fi
            printf '%s\n' '---COMMIT---' >> /workspace/tag_verify.txt
            git verify-commit HEAD >> /workspace/tag_verify.txt 2>&1 || true

            # Inject GPR credentials into local.properties so Gradle can resolve
            # trustwallet/wallet-core from maven.pkg.github.com/trustwallet/wallet-core.
            # The property keys gpr.username and gpr.token are read by build.gradle.kts
            # via localProperties (LocalProperties plugin or local.properties lookup).
            printf 'gpr.username=${github_user}\ngpr.token=${github_token}\n' \
                > /workspace/app/local.properties
            echo '[INFO] local.properties written with GPR credentials.'

            # Increase JVM heap for Gradle. AGP 9.x + Kotlin + Rust NDK needs memory.
            printf 'org.gradle.jvmargs=-Xmx8g -Xms2g -XX:MaxMetaspaceSize=512m\n' \
                >> gradle.properties

            echo '[INFO] Running ./gradlew :app:bundleGoogleRelease --no-daemon ...'
            SKIP_SIGN=true ./gradlew :app:bundleGoogleRelease \
                --no-daemon \
                --stacktrace \
                -Dorg.gradle.workers.max=4

            echo '[INFO] Build complete. Locating AAB artifact...'
            chmod -R a+rwX /workspace 2>/dev/null || true
        "

    # Ensure host-side work directory is accessible by the current user regardless
    # of whether the container build succeeded or failed (container runs as root,
    # so created files are root-owned; the in-container chmod above only runs on
    # success).
    chmod -R a+rwX "${WORK_DIR}" 2>/dev/null || true

    # Find the built AAB. Use the lesson from Tangem/Nunchuk:
    # -path "*/outputs/bundle/*" ! -path "*/intermediates/*" avoids picking up
    # intermediate AABs from the build system's working directories.
    local aab_path
    aab_path="$(find "${WORK_DIR}/built-output/app" \
        -name "*.aab" \
        -path "*/outputs/bundle/*" \
        ! -path "*/intermediates/*" \
        2>/dev/null | head -1)"

    if [[ -z "${aab_path}" ]]; then
        log_fail "Built AAB not found after :app:bundleGoogleRelease"
        log_info "All .aab files found under built-output:"
        find "${WORK_DIR}/built-output" -name "*.aab" 2>/dev/null | head -10 || true
        exit "${EXIT_FAILED}"
    fi

    BUILT_AAB="${aab_path}"
    log_pass "Built AAB: ${BUILT_AAB}"
}

# ==============================================================================
# Phase 4: Extract split APKs and compare
# Uses bundletool to extract splits from the built AAB. Resolves the matching
# built split for the official split APK. Runs the content diff.
# ==============================================================================
extract_and_compare() {
    log_info "=== EXTRACT AND COMPARE PHASE ==="

    # Reset TOTAL_DIFFS before comparison so that default "1" does not persist.
    TOTAL_DIFFS=0

    local built_splits_dir="${WORK_DIR}/built-split-apks"
    extract_split_apks_from_aab \
        "${BUILT_AAB}" \
        "${WORK_DIR}/device-spec.json" \
        "${built_splits_dir}"

    # Resolve the matching built split for the provided official split APK.
    # bundletool places splits in a splits/ subdirectory inside the .apks archive.
    local built_split
    built_split="$(resolve_built_split_apk "${OFFICIAL_APK}" "${built_splits_dir}/splits")" || {
        log_fail "Could not find matching built split for: $(basename "${OFFICIAL_APK}")"
        log_info "Official APK canonical name: $(canonicalize_split_apk_name "$(basename "${OFFICIAL_APK}")")"
        log_info "Available built splits:"
        find "${built_splits_dir}" -name "*.apk" 2>/dev/null \
            | while IFS= read -r f; do echo "  ${f}"; done
        exit "${EXIT_FAILED}"
    }

    log_info "Official split: $(basename "${OFFICIAL_APK}")"
    log_info "Built split:    $(basename "${built_split}")"

    local split_label
    split_label="$(basename "${OFFICIAL_APK}" .apk)"
    compare_split_apks "${OFFICIAL_APK}" "${built_split}" "${split_label}"
}

# ==============================================================================
# Phase 5: Result
# Determines verdict from TOTAL_DIFFS (0 = reproducible, >0 = not_reproducible).
# Writes COMPARISON_RESULTS.yaml (minimal 3-field format per 2026-03-12 spec).
# Prints the Begin/End Results block. Sets RESULT_DONE to prevent double-write.
# Exits with EXIT_SUCCESS (0) or EXIT_FAILED (1) per mechanical exit code policy.
# ==============================================================================
result() {
    log_info "=== RESULT PHASE ==="

    local verdict
    if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
        verdict="reproducible"
        log_pass "VERDICT: REPRODUCIBLE"
    else
        verdict="not_reproducible"
        log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} non-META-INF difference(s))"
    fi

    # Build the notes field for COMPARISON_RESULTS.yaml.
    # Include R8 caveat and diff file path if not_reproducible.
    local split_name diff_path
    split_name="$(basename "${OFFICIAL_APK:-base.apk}")"
    diff_path="${WORK_DIR}/comparison/diff_$(basename "${OFFICIAL_APK:-base.apk}" .apk).txt"
    local notes
    notes="Split mode: official ${split_name} vs built split from AAB (tag: ${GIT_TAG}).
  Build: SKIP_SIGN=true ./gradlew :app:bundleGoogleRelease --no-daemon inside ${GEMWALLET_BUILD_IMAGE}.
  Non-META-INF diffs: ${TOTAL_DIFFS}.
  CAVEAT: AGP 9.0.x R8 non-determinism may cause diffs in classes*.dex and
  assets/dexopt/baseline.prof (pg-map-id embedded by R8). If diffs are limited
  to these files, see reproducible/fix_pg_map_id.py in the gem-android repo
  before concluding not_reproducible. v0.1.0 does not apply this patch.
  GPR token required: trustwallet/wallet-core is on maven.pkg.github.com only."
    if [[ "${verdict}" == "not_reproducible" ]]; then
        notes="${notes}
  Diff file: ${diff_path}"
    fi

    generate_comparison_yaml "${verdict}" "${notes}"
    print_results_block "${verdict}"
    RESULT_DONE=true

    if [[ "${should_cleanup}" == "true" ]]; then
        log_info "Cleaning up ${WORK_DIR}..."
        rm -rf "${WORK_DIR}"
    else
        log_info "Work directory preserved: ${WORK_DIR}"
    fi

    if [[ "${verdict}" == "reproducible" ]]; then
        echo "Exit code: ${EXIT_SUCCESS}"
        exit "${EXIT_SUCCESS}"
    else
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    log_info "Starting ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    log_warn "This script is provided as-is. Review before running. Use at your own risk."

    detect_container_runtime
    parse_arguments "$@"
    prepare
    build_image
    build
    extract_and_compare
    result
}

main "$@"
