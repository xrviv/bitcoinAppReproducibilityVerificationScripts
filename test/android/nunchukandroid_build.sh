#!/bin/bash
# ==============================================================================
# nunchukandroid_build.sh - Nunchuk Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.0
# Organization:  WalletScrutiny.com
# Last Modified: 2026-07-16
# Project:       https://github.com/nunchuk-io/nunchuk-android
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose. Users assume all risks
# associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build
# verification. Users are responsible for ensuring compliance with all applicable
# laws and regulations. The developers assume no liability for any misuse or
# legal consequences arising from use. By using this script, you acknowledge
# these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# Two operating modes, selected by arguments:
#
#   split mode (--binary <split.apk>):
#     Accepts one official split APK from Google Play. Auto-detects version from
#     APK metadata. Fetches Nunchuk's official reproducible-builds/Dockerfile
#     from the matching tag, extends it with bundletool, and builds a container
#     image. Builds AAB via bundleProductionRelease (with disorderfs for
#     reproducible directory ordering). Extracts split APKs via bundletool +
#     device-spec.json, finds the matching built split, runs a content diff.
#     Generates COMPARISON_RESULTS.yaml with verdict.
#
#   github mode (--version <ver>, no --binary):
#     Downloads the official APK from Nunchuk GitHub releases. Builds via
#     assembleProductionRelease. Runs a content diff. Generates
#     COMPARISON_RESULTS.yaml with verdict.
#
# NOTE: Nunchuk uses disorderfs (FUSE) for reproducible directory ordering.
# The build container runs with --privileged to enable FUSE mounts.
# ==============================================================================

set -euo pipefail

# Capture execution directory before anything can change CWD
EXEC_DIR="$(pwd)"
readonly EXEC_DIR

# ------------------------------------------------------------------------------
# Script metadata
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="v0.2.0"
readonly SCRIPT_NAME="nunchukandroid_build.sh"
readonly APP_ID="io.nunchuk.android"
readonly REPO_URL="https://github.com/nunchuk-io/nunchuk-android.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly NUNCHUK_IMAGE_BASE="nunchuk_build_env"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

# ------------------------------------------------------------------------------
# Global state (set by argument parsing)
# ------------------------------------------------------------------------------
VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
REQUESTED_TAG=""
should_cleanup=false

# Set during prepare/build
BUILD_MODE=""
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""
OFFICIAL_BASE_APK=""
BUILT_AAB=""
GIT_TAG=""
RESULT_DONE=false
TOTAL_DIFFS=0

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_fail()  { echo "[FAIL] $*"; }
log_warn()  { echo "[WARNING] $*"; }

safe_grep_count() {
    local grep_output
    grep_output="$("$@" 2>/dev/null || true)"
    grep_output="${grep_output//$'\n'/}"
    [[ -n "${grep_output}" ]] && printf '%s\n' "${grep_output}" || printf '0\n'
}

# ------------------------------------------------------------------------------
# YAML output helpers
# ------------------------------------------------------------------------------
write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "$content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
    fi
}

generate_error_yaml() {
    local status="$1"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}"
}

generate_comparison_yaml() {
    local verdict="$1"
    local notes="$2"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    log_info "Generated COMPARISON_RESULTS.yaml (verdict: ${verdict})"
}

# ------------------------------------------------------------------------------
# Error handling
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
    # Only write YAML if we got past argument parsing (WORK_DIR is set).
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
# ------------------------------------------------------------------------------

# Run a command in WORK_DIR using the WS container
ws_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${WS_CONTAINER}" \
        sh -c "$cmd"
}

container_sha256() {
    local file_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$file_path"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "sha256sum /data/$(basename "$file_path") | awk '{print \$1}'"
}

container_signer() {
    local apk_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$apk_path"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "apksigner verify --print-certs /apk/$(basename "$apk_path") 2>/dev/null \
               | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

# Zeus-pattern: aapt -> aapt2 -> apktool fallback. Never reads from filename.
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
# Split APK name helpers (MetaMask pattern)
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

find_official_base_apk() {
    local dir="${WORK_DIR}/official-split-apks"
    if   [[ -f "${dir}/base.apk" ]];        then echo "${dir}/base.apk"; return; fi
    if   [[ -f "${dir}/base-master.apk" ]]; then echo "${dir}/base-master.apk"; return; fi
    local matches=("${dir}"/base*.apk)
    [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]] && echo "${matches[0]}" && return
}

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
       ${SCRIPT_NAME} - Nunchuk Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --binary <split.apk> [--version <version>] [OPTIONS]
       ${SCRIPT_NAME} --version <version> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Builds Nunchuk Android from source using Nunchuk's official
       reproducible-builds/Dockerfile and compares against an official artifact.

       split mode (--binary <file>):
         Accepts one official split APK from Google Play (e.g. base.apk).
         Fetches Nunchuk's Dockerfile from the matching tag, extends it with
         bundletool, builds AAB via bundleProductionRelease (using disorderfs
         for reproducible directory ordering), extracts splits with bundletool,
         and compares the matching split.
         Version is auto-detected from the APK unless --version is given.

       github mode (--version <ver>, no --binary):
         Downloads the official APK from Nunchuk GitHub releases. Builds via
         assembleProductionRelease and runs a content diff.

OPTIONS
       --binary <file|dir>        Path to one official Play Store split APK,
                                  or a directory containing base.apk (the
                                  base split is used). Alias: --apk.
       --version <version>        Version to verify (e.g. 1.9.47). Required in
                                  github mode; optional in split mode (auto-detect).
       --arch <arch>              Target architecture for device-spec.json.
                                  Supported: arm64-v8a, armeabi-v7a, x86_64, x86.
                                  Default: arm64-v8a.
       --type <type>              Accepted for build server compatibility; unused.
       --tag <ref>                Override git tag (default: android.<version>).
       --cleanup                  Remove work directory after completion.
       --script-version           Print script version and exit.
       --help                     Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF differences, or identical)
       1    Differences found or build failure
       2    Invalid parameters

EXAMPLES
       # Split mode — one split from Play Store (version auto-detected):
       ${SCRIPT_NAME} --binary ~/apks/base.apk

       # Split mode — explicit version:
       ${SCRIPT_NAME} --binary ~/apks/base.apk --version 1.9.47

       # GitHub mode — download and compare GitHub release APK:
       ${SCRIPT_NAME} --version 1.9.47
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)        VERSION="${2:-}";         shift ;;
            --apk|--binary)   APK_INPUT="${2:-}";       shift ;;
            --arch)           ARCH="${2:-}";            shift ;;
            --type)           TYPE="${2:-}";            shift ;;
            --tag)            REQUESTED_TAG="${2:-}";   shift ;;
            --cleanup)        should_cleanup=true ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)        usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            *)                log_warn "Ignoring unknown argument: $1" ;;
        esac
        shift
    done

    # Root check
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Do not run this script as root."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Determine mode
    if [[ -n "${APK_INPUT}" ]]; then
        BUILD_MODE="split"
        # A directory is accepted; the base split inside it is what gets compared.
        if [[ -d "${APK_INPUT}" ]]; then
            if [[ -f "${APK_INPUT%/}/base.apk" ]]; then
                APK_INPUT="${APK_INPUT%/}/base.apk"
                log_info "--binary is a directory; using ${APK_INPUT}"
            else
                echo "[ERROR] --binary directory contains no base.apk: ${APK_INPUT}"
                generate_error_yaml "ftbfs"
                echo "Exit code: ${EXIT_INVALID}"
                exit "${EXIT_INVALID}"
            fi
        fi
        if [[ ! -f "${APK_INPUT}" ]]; then
            echo "[ERROR] --binary file not found: ${APK_INPUT}"
            generate_error_yaml "ftbfs"
            echo "Exit code: ${EXIT_INVALID}"
            exit "${EXIT_INVALID}"
        fi
        # Resolve relative path
        [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
        ARCH="${ARCH:-arm64-v8a}"
    elif [[ -n "${VERSION}" ]]; then
        BUILD_MODE="github"
        ARCH="${ARCH:-arm64-v8a}"
    else
        echo "[ERROR] Provide --binary <split.apk> (split mode) or --version <version> (github mode)."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    # Validate arch
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            echo "[ERROR] Unsupported architecture: ${ARCH}"
            echo "        Supported: arm64-v8a, armeabi-v7a, x86_64, x86"
            echo "Exit code: ${EXIT_INVALID}"
            exit "${EXIT_INVALID}"
            ;;
    esac

    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="/tmp/test_${APP_ID}_${VERSION_SAFE}_${ARCH_SAFE}"
    log_info "Build mode: ${BUILD_MODE}"
    log_info "Work directory: ${WORK_DIR}"
}

# ------------------------------------------------------------------------------
# Git tag resolution
# Nunchuk uses tag format android.X.Y.Z (fallback: vX.Y.Z, X.Y.Z)
# ------------------------------------------------------------------------------
# Sets global GIT_TAG. Uses git ls-remote on the host (avoids container network issues).
resolve_git_tag() {
    local version="$1"
    local candidates=("android.${version}" "v${version}" "${version}")

    log_info "Resolving git tag for version ${version}..."
    for candidate in "${candidates[@]}"; do
        if git ls-remote --tags --exit-code "${REPO_URL}" "refs/tags/${candidate}" >/dev/null 2>&1; then
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
# Fetch Nunchuk's Dockerfile and extend it with bundletool
# ------------------------------------------------------------------------------
fetch_and_extend_dockerfile() {
    local git_tag="$1"
    local output_path="$2"

    local dockerfile_url="https://raw.githubusercontent.com/nunchuk-io/nunchuk-android/${git_tag}/reproducible-builds/Dockerfile"
    log_info "Fetching Nunchuk Dockerfile from tag ${git_tag}..."

    local original_dockerfile
    original_dockerfile="$(curl -fsSL --max-time 30 "${dockerfile_url}" 2>/dev/null || true)"

    if [[ -z "${original_dockerfile}" ]]; then
        log_fail "Could not fetch Dockerfile for tag ${git_tag}"
        exit "${EXIT_FAILED}"
    fi

    # Write extended Dockerfile: Nunchuk's official + bundletool for split extraction
    cat > "${output_path}" <<DOCKERFILE_EOF
${original_dockerfile}

# WalletScrutiny: install bundletool for split APK extraction from built AAB
RUN wget -q https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar \
    -O /tmp/bundletool.jar
DOCKERFILE_EOF

    log_info "Extended Dockerfile written to ${output_path}"
}

# ------------------------------------------------------------------------------
# Build the extended Nunchuk image (once per version)
# ------------------------------------------------------------------------------
ensure_build_image() {
    local image_tag="${NUNCHUK_IMAGE_BASE}:${VERSION_SAFE}"

    if ${CONTAINER_CMD} image inspect "${image_tag}" >/dev/null 2>&1; then
        log_info "Build image ${image_tag} already exists, skipping build."
        return 0
    fi

    log_info "Building Nunchuk build image ${image_tag}..."
    local dockerfile_path="${WORK_DIR}/Dockerfile"
    fetch_and_extend_dockerfile "${GIT_TAG}" "${dockerfile_path}"

    ${CONTAINER_CMD} build \
        --no-cache \
        -t "${image_tag}" \
        -f "${dockerfile_path}" \
        "${WORK_DIR}"

    log_pass "Build image ${image_tag} ready."
}

# ------------------------------------------------------------------------------
# Create device-spec.json for bundletool
# ------------------------------------------------------------------------------
create_device_spec() {
    local output_path="$1"
    local arch="$2"
    cat > "${output_path}" <<EOF
{
  "supportedAbis": ["${arch}"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 31
}
EOF
    log_info "device-spec.json created (arch=${arch})"
}

# ------------------------------------------------------------------------------
# Extract split APKs from built AAB using bundletool
# ------------------------------------------------------------------------------
extract_split_apks_from_aab() {
    local aab_path="$1"
    local device_spec_path="$2"
    local output_dir="$3"
    local image_tag="${NUNCHUK_IMAGE_BASE}:${VERSION_SAFE}"

    mkdir -p "${output_dir}"

    local aab_rel device_spec_rel apks_rel output_rel
    aab_rel="${aab_path#"${WORK_DIR}/"}"
    device_spec_rel="${device_spec_path#"${WORK_DIR}/"}"
    apks_rel="built-splits.apks"
    output_rel="${output_dir#"${WORK_DIR}/"}"

    log_info "Running bundletool to extract split APKs..."
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${image_tag}" \
        bash -c "
            java -jar /tmp/bundletool.jar build-apks \
                --bundle=\"${aab_rel}\" \
                --output=\"${apks_rel}\" \
                --device-spec=\"${device_spec_rel}\" \
                --mode=default \
                --overwrite 2>&1
            mkdir -p \"${output_rel}\"
            unzip -qq -o \"${apks_rel}\" -d \"${output_rel}\" 2>&1 || true
        "

    # Normalize: base-master.apk → base.apk
    local splits_subdir="${output_dir}/splits"
    if [[ -f "${splits_subdir}/base-master.apk" ]]; then
        mv "${splits_subdir}/base-master.apk" "${splits_subdir}/base.apk"
        log_info "Renamed base-master.apk -> base.apk"
    fi

    local split_count
    split_count="$(find "${output_dir}" -name "*.apk" | wc -l)"
    log_info "Extracted ${split_count} split APK(s) to ${output_dir}"
}

# ------------------------------------------------------------------------------
# Unzip APK in WS container
# ------------------------------------------------------------------------------
unzip_apk_in_container() {
    local apk_path="$1"
    local out_dir="$2"
    local apk_rel out_rel
    apk_rel="${apk_path#"${WORK_DIR}/"}"
    out_rel="${out_dir#"${WORK_DIR}/"}"
    ws_exec "mkdir -p '${out_rel}' && unzip -qq '${apk_rel}' -d '${out_rel}' 2>/dev/null || true"
}

# ------------------------------------------------------------------------------
# Compare split APKs (split mode)
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

    unzip_apk_in_container "${official_apk}" "${official_unzip}"
    unzip_apk_in_container "${built_apk}"    "${built_unzip}"

    local official_rel built_rel diff_rel
    official_rel="${official_unzip#"${WORK_DIR}/"}"
    built_rel="${built_unzip#"${WORK_DIR}/"}"
    diff_rel="${diff_file#"${WORK_DIR}/"}"

    ws_exec "diff -r \"${official_rel}\" \"${built_rel}\" \
        > \"${diff_rel}\" 2>&1 || true"

    local total_lines=0
    local non_meta_count=0

    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        non_meta_count="$(grep -E '^Only in |^Files ' "${diff_file}" \
            | grep -cvE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
            || echo 0)"
    fi

    TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
    log_info "  ${split_label}: ${non_meta_count} non-META-INF diff(s) (${total_lines} lines total)"

    if [[ -s "${diff_file}" ]]; then
        log_info "  First 5 lines (full diff: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
        if [[ "${total_lines}" -gt 5 ]]; then
            log_info "    ... (${total_lines} total lines)"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Compare universal APKs (github mode)
# ------------------------------------------------------------------------------
compare_universal_apks() {
    local official_apk="$1"
    local built_apk="$2"
    local results_dir="${WORK_DIR}/comparison"

    mkdir -p "${results_dir}"
    log_info "Comparing universal APKs..."

    local official_unzip="${results_dir}/official_unzipped"
    local built_unzip="${results_dir}/built_unzipped"
    local diff_file="${results_dir}/diff_full.txt"

    unzip_apk_in_container "${official_apk}" "${official_unzip}"
    unzip_apk_in_container "${built_apk}"    "${built_unzip}"

    local official_rel built_rel diff_rel
    official_rel="${official_unzip#"${WORK_DIR}/"}"
    built_rel="${built_unzip#"${WORK_DIR}/"}"
    diff_rel="${diff_file#"${WORK_DIR}/"}"

    ws_exec "diff -r \"${official_rel}\" \"${built_rel}\" \
        > \"${diff_rel}\" 2>&1 || true"

    TOTAL_DIFFS=0
    if [[ -s "${diff_file}" ]]; then
        local total_lines
        total_lines="$(wc -l < "${diff_file}")"
        TOTAL_DIFFS="$(grep -E '^Only in |^Files ' "${diff_file}" \
            | grep -cvE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
            || echo 0)"
        log_info "diff_full.txt: ${TOTAL_DIFFS} non-META-INF diff(s) (${total_lines} total lines)"
        log_info "First 5 lines (full diff: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "  ${line}"; done
        if [[ "${total_lines}" -gt 5 ]]; then
            log_info "  ... (${total_lines} total lines)"
        fi
    else
        log_pass "No differences found."
    fi
}

# ------------------------------------------------------------------------------
# Print verification results block
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
    if [[ -f "${WORK_DIR}/built-aab/commit.txt" ]]; then
        commit="$(cat "${WORK_DIR}/built-aab/commit.txt")"
    fi

    tag_info=""
    if [[ -f "${WORK_DIR}/built-aab/tag_verify.txt" ]]; then
        tag_info="$(cat "${WORK_DIR}/built-aab/tag_verify.txt")"
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         ${signer:-unknown}"
    echo "apkVersionName: ${version_name:-unknown}"
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
            local split_label
            split_label="$(basename "${diff_file}" .txt)"
            if [[ -s "${diff_file}" ]]; then
                local total_lines
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
    fi
}

# ------------------------------------------------------------------------------
# Phase 1: Prepare
# ------------------------------------------------------------------------------
prepare() {
    log_info "=== PREPARE PHASE ==="

    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/official-split-apks"
    mkdir -p "${WORK_DIR}/built-aab"

    if [[ "${BUILD_MODE}" == "split" ]]; then
        local original_name canonical_name
        original_name="$(basename "${APK_INPUT}")"
        canonical_name="$(canonicalize_split_apk_name "${original_name}")"
        cp "${APK_INPUT}" "${WORK_DIR}/official-split-apks/${canonical_name}"

        if [[ "${original_name}" != "${canonical_name}" ]]; then
            log_info "Normalized split name: ${original_name} -> ${canonical_name}"
        fi

        OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"

        # Auto-detect version from APK content if not provided
        if [[ -z "${VERSION}" ]]; then
            log_info "Auto-detecting version from APK content..."
            VERSION="$(container_aapt_version "${OFFICIAL_APK}" "versionName" || true)"
            if [[ -z "${VERSION}" ]]; then
                log_fail "Could not detect version from APK. Pass --version explicitly."
                exit "${EXIT_INVALID}"
            fi
            log_info "Version detected: ${VERSION}"
            VERSION_SAFE="${VERSION}"
        fi

        create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"
    fi

    log_pass "Preparation complete."
}

# ------------------------------------------------------------------------------
# Phase 2: Build
# ------------------------------------------------------------------------------
build() {
    log_info "=== BUILD PHASE ==="

    # Resolve git tag
    GIT_TAG="${REQUESTED_TAG:-}"
    if [[ -z "${GIT_TAG}" ]]; then
        if ! resolve_git_tag "${VERSION}"; then
            echo ""
            echo "======================================================"
            echo "  SOURCE NOT FOUND FOR VERSION ${VERSION}"
            echo "  Nunchuk has not published a tagged release for this"
            echo "  version in the repository. Cannot verify."
            echo "  Repository: ${REPO_URL}"
            echo "======================================================"
            echo ""
            generate_comparison_yaml "ftbfs" \
                "Tag not found for version ${VERSION}. Tried: android.${VERSION}, v${VERSION}, ${VERSION}. Source code for this version has not been published in the Nunchuk repository."
            RESULT_DONE=true
            echo "Exit code: ${EXIT_FAILED}"
            exit "${EXIT_FAILED}"
        fi
    fi
    log_info "Git tag: ${GIT_TAG}"

    ensure_build_image

    local image_tag="${NUNCHUK_IMAGE_BASE}:${VERSION_SAFE}"
    local gradle_task
    if [[ "${BUILD_MODE}" == "split" ]]; then
        gradle_task="bundleProductionRelease"
    else
        gradle_task="assembleProductionRelease"
    fi

    log_info "Cloning + building in container (this may take 20-40 minutes)..."
    log_info "NOTE: Requires --privileged for disorderfs (FUSE)."

    # Clone, verify tag, and build all in one privileged container run.
    # disorderfs mounts the cloned source with sorted directory entries for
    # reproducible builds — this is Nunchuk's official reproducible build approach.
    ${CONTAINER_CMD} run --rm \
        --privileged \
        -v "${WORK_DIR}/built-aab:/workspace${VOLUME_RW}" \
        -e "HOME=/tmp" \
        -e "GRADLE_USER_HOME=/tmp/.gradle" \
        "${image_tag}" \
        bash -c "set -euo pipefail

            echo '[INFO] Cloning ${REPO_URL} at ${GIT_TAG}...'
            git clone --depth 1 --branch '${GIT_TAG}' '${REPO_URL}' /workspace/app

            cd /workspace/app
            git rev-parse HEAD > /workspace/commit.txt
            echo '[INFO] Commit: \$(cat /workspace/commit.txt)'

            # Tag and signature verification (best-effort)
            tag_type=\$(git cat-file -t 'refs/tags/${GIT_TAG}' 2>/dev/null || echo 'missing')
            printf 'TAG_TYPE=%s\n' \"\${tag_type}\" > /workspace/tag_verify.txt
            if [ \"\${tag_type}\" = 'tag' ]; then
                git tag -v '${GIT_TAG}' >> /workspace/tag_verify.txt 2>&1 || true
            elif [ \"\${tag_type}\" = 'commit' ]; then
                printf 'LIGHTWEIGHT_TAG\n' >> /workspace/tag_verify.txt
            else
                printf 'NO_TAG\n' >> /workspace/tag_verify.txt
            fi
            printf '%s\n' '---COMMIT---' >> /workspace/tag_verify.txt
            git verify-commit HEAD >> /workspace/tag_verify.txt 2>&1 || true

            # disorderfs: mount source with sorted directory entries for reproducibility.
            # This matches Nunchuk's official reproducible build process.
            echo '[INFO] Mounting source with disorderfs...'
            mkdir -p /build-src
            disorderfs --sort-dirents=yes --reverse-dirents=no /workspace/app /build-src/ 2>&1 || {
                echo '[WARNING] disorderfs failed or not available; building without it'
                cp -a /workspace/app/. /build-src/ 2>/dev/null || true
            }

            cd /build-src
            chmod +x gradlew

            echo 'org.gradle.daemon=false'       >> gradle.properties
            echo 'org.gradle.parallel=false'     >> gradle.properties

            echo '[INFO] Running ./gradlew ${gradle_task}...'
            ./gradlew ${gradle_task} \
                --no-daemon \
                --stacktrace \
                -Dorg.gradle.jvmargs='-Xmx8g -Xms2g -XX:MaxMetaspaceSize=512m'

            # Copy build outputs back to workspace (disorderfs mount is read-only for outputs)
            echo '[INFO] Copying build outputs to workspace...'
            find /build-src -name '*.aab' -o -name '*.apk' 2>/dev/null \
                | grep -v '/intermediates/' \
                | while read -r f; do
                    rel=\"\${f#/build-src/}\"
                    mkdir -p \"/workspace/app/\$(dirname \"\${rel}\")\"
                    cp \"\${f}\" \"/workspace/app/\${rel}\" 2>/dev/null || true
                done || true

            echo '[INFO] Build complete.'
        "

    if [[ "${BUILD_MODE}" == "split" ]]; then
        local aab_path
        aab_path="$(find "${WORK_DIR}/built-aab/app" \
            -name "*.aab" \
            -path "*/outputs/bundle/*" \
            ! -path "*/intermediates/*" \
            | head -1)"
        if [[ -z "${aab_path}" ]]; then
            log_fail "Built AAB not found after ${gradle_task}"
            log_info "Build outputs in ${WORK_DIR}/built-aab/app:"
            find "${WORK_DIR}/built-aab/app" -name "*.aab" 2>/dev/null | head -10 || true
            exit "${EXIT_FAILED}"
        fi
        BUILT_AAB="${aab_path}"
        log_pass "Built AAB: ${BUILT_AAB}"
    fi
}

# ------------------------------------------------------------------------------
# Phase 3: Extract and compare
# ------------------------------------------------------------------------------
extract_and_compare() {
    log_info "=== EXTRACT AND COMPARE PHASE ==="

    TOTAL_DIFFS=0

    if [[ "${BUILD_MODE}" == "split" ]]; then
        local built_splits_dir="${WORK_DIR}/built-split-apks"
        extract_split_apks_from_aab \
            "${BUILT_AAB}" \
            "${WORK_DIR}/device-spec.json" \
            "${built_splits_dir}"

        # Find the matching built split for the provided official split
        local built_split
        built_split="$(resolve_built_split_apk "${OFFICIAL_APK}" "${built_splits_dir}/splits")" || {
            log_fail "Could not find matching built split for $(basename "${OFFICIAL_APK}")"
            log_info "Available built splits:"
            find "${built_splits_dir}" -name "*.apk" | while IFS= read -r f; do echo "  ${f}"; done
            exit "${EXIT_FAILED}"
        }

        log_info "Official: $(basename "${OFFICIAL_APK}")"
        log_info "Built:    $(basename "${built_split}")"

        local split_label
        split_label="$(basename "${OFFICIAL_APK}" .apk)"
        compare_split_apks "${OFFICIAL_APK}" "${built_split}" "${split_label}"

    else
        # github mode: download official APK then compare
        log_info "Downloading official APK from GitHub releases (tag: ${GIT_TAG})..."

        local api_url="https://api.github.com/repos/nunchuk-io/nunchuk-android/releases/tags/${GIT_TAG}"
        local release_json
        release_json="$(${CONTAINER_CMD} run --rm \
            "${WS_CONTAINER}" \
            sh -c "curl -fsSL --max-time 30 '${api_url}'")"

        if echo "${release_json}" | grep -q '"message".*"Not Found"'; then
            log_fail "GitHub release not found for tag ${GIT_TAG}"
            exit "${EXIT_FAILED}"
        fi

        local apk_url
        apk_url="$(echo "${release_json}" \
            | grep -o '"browser_download_url":"[^"]*\.apk"' \
            | head -1 \
            | sed 's/"browser_download_url":"//; s/"//')"

        if [[ -z "${apk_url}" ]]; then
            log_fail "No APK asset found in GitHub release for ${GIT_TAG}"
            exit "${EXIT_FAILED}"
        fi

        log_info "Downloading: ${apk_url}"
        ${CONTAINER_CMD} run --rm \
            -v "${WORK_DIR}:/work${VOLUME_RW}" \
            "${WS_CONTAINER}" \
            sh -c "curl -fsSL --max-time 300 '${apk_url}' -o '/work/official-github.apk'"

        OFFICIAL_APK="${WORK_DIR}/official-github.apk"
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"

        # Find built APK
        local built_apk
        built_apk="$(find "${WORK_DIR}/built-aab/app" \
            -name "*.apk" \
            -path "*/outputs/apk/*" \
            ! -path "*/intermediates/*" \
            | head -1)"

        if [[ -z "${built_apk}" ]]; then
            log_fail "Built APK not found after assembleProductionRelease"
            exit "${EXIT_FAILED}"
        fi
        log_info "Built APK: ${built_apk}"

        compare_universal_apks "${OFFICIAL_APK}" "${built_apk}"
    fi
}

# ------------------------------------------------------------------------------
# Phase 4: Result
# ------------------------------------------------------------------------------
result() {
    log_info "=== RESULT PHASE ==="

    local verdict
    if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
        verdict="reproducible"
    else
        verdict="not_reproducible"
    fi

    local notes
    if [[ "${BUILD_MODE}" == "split" ]]; then
        notes="Split mode: official $(basename "${OFFICIAL_APK}") vs built split from ${GIT_TAG}.
  Build: ./gradlew bundleProductionRelease with disorderfs (reproducible directory ordering).
  Non-META-INF diffs: ${TOTAL_DIFFS}."
    else
        notes="GitHub mode: official APK from GitHub releases vs built assembleProductionRelease.
  Build: ./gradlew assembleProductionRelease with disorderfs (reproducible directory ordering).
  Tag: ${GIT_TAG}. Non-META-INF diffs: ${TOTAL_DIFFS}."
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

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
detect_container_runtime
parse_arguments "$@"
prepare
build
extract_and_compare
result
