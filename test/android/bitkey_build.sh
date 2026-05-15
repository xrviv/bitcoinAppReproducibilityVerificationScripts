#!/bin/bash
# ==============================================================================
# bitkey_build.sh - Bitkey Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.20
# Organization:  WalletScrutiny.com
# Last Modified: 2026-05-02 (v0.2.20)
# Project:       https://github.com/proto-at-block/bitkey
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
# verification. Users are responsible for ensuring compliance with all
# applicable laws and regulations. The developers assume no liability for any
# misuse or legal consequences arising from use. By using this script, you
# acknowledge these disclaimers and accept full responsibility.
# ==============================================================================

set -euo pipefail

EXEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXEC_DIR
LOG_DIR="${EXEC_DIR}/build-logs"

CYAN='\033[1;36m'
RED='\033[0;31m'
NC='\033[0m'

readonly SCRIPT_VERSION="v0.2.21"
readonly SCRIPT_NAME="bitkey_build.sh"
readonly APP_ID="world.bitkey.app"
readonly REPO_URL="https://github.com/proto-at-block/bitkey.git"
readonly DEFAULT_REF="main"
readonly BUNDLETOOL_VERSION="1.15.6"
readonly ANDROID_BUILD_TOOLS_VERSION="35.0.0"
readonly HELPER_GIT_IMAGE="docker.io/alpine/git:2.47.2"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"

readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2
readonly BITKEY_KNOWN_SIGNER="c0d0f9da7158cde788d0281e9ebd07034178165584d635f7ce17f77c037d961a"
readonly GITHUB_RELEASE_BASE="https://github.com/proto-at-block/bitkey/releases/download"

VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""
WORK_DIR=""
WORK_DIR_INITIAL=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
TEMP_BASE_IMAGE=""
EXACT_BASE_IMAGE=""
EXACT_BUILD_IMAGE=""
RESULT_DONE=false
OFFICIAL_INPUTS_PREPARED=false
COMPARE_LOG_FILE=""
TAG_REF=""
TAG_TYPE="not checked"
TAG_VERIFY_OUTPUT="(tag verification not available)"
COMMIT_VERIFY_OUTPUT="(commit verification not available)"
TAG_SIGNATURE_STATUS="[INFO] Not checked"
COMMIT_SIGNATURE_STATUS="[INFO] Not checked"
SIGNATURE_KEYS=""
SIGNATURE_WARNINGS=""


OFFICIAL_VERSION_NAME=""
OFFICIAL_VERSION_CODE=""
OFFICIAL_SDK_VERSION=""
OFFICIAL_SIGNER="unknown"
OFFICIAL_HASH=""
OFFICIAL_APK_SIZE=""
COMMIT_HASH=""
GENERATED_ARCH=""
COMPARE_STATUS=1
SINGLE_APK_MODE=false
SINGLE_APK_PATH=""
SINGLE_APK_PKG_VERIFIED=false
BUILT_APK_HASH=""
BUILT_APK_SIZE=""

log_info()  { echo "[INFO] $*" >&2; }
log_pass()  { echo "[PASS] $*" >&2; }
log_fail()  { echo "[FAIL] $*" >&2; }
log_warn()  { echo "[WARNING] $*" >&2; }

phase_header() {
    local num="$1" name="$2"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}  PHASE ${num}: ${name}${NC}"
    echo -e "${CYAN}=====================================================${NC}"
}

generate_filtered_build_log() {
    local full_log="${LOG_DIR}/phase4-build-full.log"
    local filtered_log="${LOG_DIR}/phase4-build.log"
    [ -f "${full_log}" ] || return 0
    {
        echo "=== PHASE 4 BUILD LOG (FILTERED) ==="
        echo "--- Errors and warnings ---"
        grep -iE "error:|warning:|exception:|failed|daemon disappeared" "${full_log}" || true
        echo "--- Key events ---"
        grep -E "^\[INFO\]|\[DIAG\]|BUILD SUCCESSFUL|BUILD FAILED|Task :" "${full_log}" || true
        echo "--- Last 30 lines ---"
        tail -30 "${full_log}"
    } > "${filtered_log}" 2>/dev/null || true
}

print_exit_code() {
    echo "Exit code: $1"
}

write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "${content}" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    chmod 644 "${EXEC_DIR}/COMPARISON_RESULTS.yaml" 2>/dev/null || true
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "${content}" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
        chmod 644 "${WORK_DIR}/COMPARISON_RESULTS.yaml" 2>/dev/null || true
    fi
    if [[ -n "${LOG_DIR:-}" && -d "${LOG_DIR}" ]]; then
        printf '%s\n' "${content}" > "${LOG_DIR}/phase6-results-yaml.log" || true
    fi
}

generate_error_yaml() {
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
    local verdict="$1"
    local notes="$2"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    log_info "Generated COMPARISON_RESULTS.yaml (verdict: ${verdict})"
}

print_diff_preview() {
    local diff_file
    diff_file="$(comparison_dir)/diff-unzipped-apks.txt"
    echo "Diff (excluding resources.arsc; resources checked by aapt2 diff below):"
    if [[ ! -f "${diff_file}" ]]; then
        echo "(No comparison performed)"
        return 0
    fi

    local preview=""
    preview="$(head -n 5 "${diff_file}" 2>/dev/null || true)"
    if [[ -n "${preview}" ]]; then
        printf '%s\n' "${preview}"
    else
        echo "(no differences)"
    fi

    local total_lines=0
    total_lines="$(wc -l < "${diff_file}" 2>/dev/null || echo 0)"
    if [[ "${total_lines}" -gt 5 ]]; then
        echo "... (${total_lines} lines total - full diff in ${diff_file})"
    fi
}

collect_git_signature_info() {
    local tag_ref="$1"
    TAG_REF="${tag_ref}"
    TAG_TYPE="commit-only"
    TAG_VERIFY_OUTPUT="No tag (build from commit ${COMMIT_HASH:-unknown})"
    COMMIT_VERIFY_OUTPUT="(commit verification not available)"
    TAG_SIGNATURE_STATUS="[INFO] No tag found"
    COMMIT_SIGNATURE_STATUS="[WARNING] No valid signature found on commit"
    SIGNATURE_KEYS=""
    SIGNATURE_WARNINGS=""

    [[ -z "${COMMIT_HASH:-}" ]] && return 0

    if run_git_container "git -C 'repo-exact' rev-parse --verify 'refs/tags/${tag_ref}' >/dev/null 2>&1"; then
        if [[ "$(run_git_container "git -C 'repo-exact' cat-file -t 'refs/tags/${tag_ref}' 2>/dev/null || true" | tr -d '\r\n')" == "tag" ]]; then
            TAG_TYPE="annotated"
            TAG_VERIFY_OUTPUT="$(run_git_container "git -C 'repo-exact' tag -v '${tag_ref}' 2>&1 || true")"
            if echo "${TAG_VERIFY_OUTPUT}" | grep -q "Good signature"; then
                local tag_key=""
                TAG_SIGNATURE_STATUS="[OK] Good signature on annotated tag"
                tag_key="$(echo "${TAG_VERIFY_OUTPUT}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
                if [[ -n "${tag_key}" ]]; then
                    SIGNATURE_KEYS="Tag signed with: ${tag_key}"
                fi
            else
                TAG_SIGNATURE_STATUS="[WARNING] No valid signature found on annotated tag"
                SIGNATURE_WARNINGS="- Annotated tag exists but is not signed or could not be verified"
            fi
        else
            TAG_TYPE="lightweight"
            TAG_VERIFY_OUTPUT="Tag: ${tag_ref} (lightweight, no signature possible)"
            TAG_SIGNATURE_STATUS="[INFO] Tag is lightweight (cannot contain signature)"
        fi
    fi

    COMMIT_VERIFY_OUTPUT="$(run_git_container "git -C 'repo-exact' verify-commit '${COMMIT_HASH}' 2>&1 || true")"
    if echo "${COMMIT_VERIFY_OUTPUT}" | grep -q "Good signature"; then
        local commit_key=""
        COMMIT_SIGNATURE_STATUS="[OK] Good signature on commit"
        commit_key="$(echo "${COMMIT_VERIFY_OUTPUT}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
        if [[ -n "${commit_key}" ]]; then
            if [[ -n "${SIGNATURE_KEYS}" ]]; then
                SIGNATURE_KEYS="${SIGNATURE_KEYS}\nCommit signed with: ${commit_key}"
            else
                SIGNATURE_KEYS="Commit signed with: ${commit_key}"
            fi
        fi
    else
        COMMIT_SIGNATURE_STATUS="[WARNING] No valid signature found on commit"
        if [[ -n "${SIGNATURE_WARNINGS}" ]]; then
            SIGNATURE_WARNINGS="${SIGNATURE_WARNINGS}\n- Commit is not signed or could not be verified"
        else
            SIGNATURE_WARNINGS="- Commit is not signed or could not be verified"
        fi
    fi
}

print_signature_section() {
    echo "Revision, tag (and its signature):"
    printf '%s\n' "${TAG_VERIFY_OUTPUT:-No tag (build from commit ${COMMIT_HASH:-unknown})}"
    echo
    printf '%s\n' "${COMMIT_VERIFY_OUTPUT:-"(commit verification not available)"}"
    echo
    echo "Signature Summary:"
    echo "Tag type: ${TAG_TYPE:-not checked}"
    echo "${TAG_SIGNATURE_STATUS:-[INFO] Not checked}"
    echo "${COMMIT_SIGNATURE_STATUS:-[INFO] Not checked}"

    if [[ -n "${SIGNATURE_KEYS}" ]]; then
        echo
        echo "Keys used:"
        echo -e "${SIGNATURE_KEYS}"
    fi

    if [[ -n "${SIGNATURE_WARNINGS}" ]]; then
        echo
        echo "Warnings:"
        echo -e "${SIGNATURE_WARNINGS}"
    fi
}

print_results_block() {
    local verdict_label="$1"
    echo "===== Begin Results ====="
    printf 'appId:          %s\n' "${APP_ID}"
    printf 'signer:         %s\n' "${OFFICIAL_SIGNER:-unknown}"
    printf 'apkVersionName: %s\n' "${OFFICIAL_VERSION_NAME:-${VERSION:-unknown}}"
    printf 'apkVersionCode: %s\n' "${OFFICIAL_VERSION_CODE:-unknown}"
    printf 'verdict:        %s\n' "${verdict_label}"
    printf 'appHash:        %s\n' "${OFFICIAL_HASH:-unknown}"
    printf 'commit:         %s\n' "${COMMIT_HASH:-unknown}"
    echo
    print_diff_preview
    echo
    print_signature_section

    if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
        echo
        echo "===== Also ===="
        printf 'Single APK built hash: %s\n' "${BUILT_APK_HASH:-unknown}"
        printf 'Single APK official hash: %s\n' "${OFFICIAL_HASH:-unknown}"
        printf 'Single APK built size: %s bytes\n' "${BUILT_APK_SIZE:-unknown}"
        printf 'Single APK official size: %s bytes\n' "${OFFICIAL_APK_SIZE:-unknown}"
    fi

    echo "===== End Results ====="
    if [[ -f "$(comparison_dir)/diff-unzipped-apks.txt" ]]; then
        echo "Plain diff file: $(comparison_dir)/diff-unzipped-apks.txt"
    fi
    if [[ -n "${COMPARE_LOG_FILE}" && -f "${COMPARE_LOG_FILE}" ]]; then
        echo "Compare log:    ${COMPARE_LOG_FILE}"
    fi
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        echo "Work directory: ${WORK_DIR}"
    fi
    local excluded_report
    excluded_report="$(comparison_dir)/excluded-files-report.txt"
    if [[ -f "${excluded_report}" ]]; then
        echo ""
        cat "${excluded_report}"
    fi
}

emit_failure_and_exit() {
    local notes="${1:-}"
    local exit_code="${2:-${EXIT_FAILED}}"
    if [[ "${RESULT_DONE}" != "true" ]]; then
        generate_error_yaml "ftbfs" "${notes}" || true
        RESULT_DONE=true
    fi
    print_results_block "ftbfs"
    print_exit_code "${exit_code}"
    exit "${exit_code}"
}

if [[ ${EUID} -eq 0 ]]; then
    log_fail "Do not run this script as root."
    emit_failure_and_exit "Do not run this script as root." "${EXIT_FAILED}"
fi

on_error() {
    local exit_code=$?
    local line_no=$1
    set +e
    log_fail "Script failed at line ${line_no} (exit code ${exit_code})"
    emit_failure_and_exit "Script failed at line ${line_no} (exit code ${exit_code})." "${EXIT_FAILED}"
}

cleanup_on_exit() {
    local exit_code=$?
    set +e
    { exec 1>&5 2>&6; } 2>/dev/null || true
    if [[ "${exit_code}" -ne 0 && -n "${LOG_DIR:-}" && -d "${LOG_DIR}" ]]; then
        generate_filtered_build_log || true
    fi
    if [[ -n "${TEMP_BASE_IMAGE}" ]]; then
        ${CONTAINER_CMD:-docker} image rm -f "${TEMP_BASE_IMAGE}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${EXACT_BASE_IMAGE}" ]]; then
        ${CONTAINER_CMD:-docker} image rm -f "${EXACT_BASE_IMAGE}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${EXACT_BUILD_IMAGE}" ]]; then
        ${CONTAINER_CMD:-docker} image rm -f "${EXACT_BUILD_IMAGE}" >/dev/null 2>&1 || true
    fi
    if [[ "${exit_code}" -ne 0 && -n "${WORK_DIR:-}" ]]; then
        log_warn "Work directory preserved: ${WORK_DIR}"
    fi
    if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" ]]; then
        generate_error_yaml "ftbfs" || true
    fi
    if [[ -n "${LOG_DIR:-}" && -d "${LOG_DIR}" ]]; then
        log_info "Build logs: ${LOG_DIR}/"
    fi
}

trap 'on_error $LINENO' ERR
trap 'cleanup_on_exit' EXIT

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} --version <version> --binary <file|dir|zip> [OPTIONS]
  ${SCRIPT_NAME} --binary <file|dir|zip> [OPTIONS]

Inputs:
  --binary <path>     Official Bitkey APK input. Accepts:
                        - directory containing *.apk files (base.apk + config splits)
                        - .apks or .zip archive containing the full split set
                        - single .apk file (GitHub release emergency APK)
                      Alias: --apk

Options:
  --version <ver>     Bitkey app version, for example: 2026.2.1
                      If omitted, the script reads versionName from base.apk.
  --arch <arch>       Override supportedAbis in generated device-spec.json.
                      Example: arm64-v8a
  --type <type>       Accepted for ABS compatibility; unused.
  -h, --help          Show this help.

Examples:
  ${SCRIPT_NAME} --version 2026.2.1 --binary ~/Downloads/bitkey-splits/
  ${SCRIPT_NAME} --version 2026.2.1 --binary ~/Downloads/bitkey.apks
  ${SCRIPT_NAME} --binary ~/Downloads/bitkey-splits/ --arch arm64-v8a
  ${SCRIPT_NAME} --version 2026.2.1 --binary ~/Downloads/Bitkey-app-2026.2.1.apk

Notes:
  - Host prerequisite: podman or docker.
  - No phone or ADB session is required.
  - Bitkey upstream requires an x86_64 linux/amd64 build environment.
  - Work directory is preserved at /tmp/test_world.bitkey.app_<version>_<arch>/ for diff inspection.
EOF
}

require_arg() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "${value}" || "${value}" == --* ]]; then
        log_fail "${flag} requires a value."
        emit_failure_and_exit "${flag} requires a value." "${EXIT_INVALID}"
    fi
}

sanitize_path_component() {
    printf '%s' "$1" | tr '/: ' '___' | tr -cd '[:alnum:]_.-'
}

build_ref_from_version() {
    local version="${1#app/}"
    printf 'app/%s\n' "${version}"
}

work_dir_for() {
    local version_part="$1"
    local arch_part="$2"
    printf '/tmp/test_%s_%s_%s\n' \
        "${APP_ID}" \
        "$(sanitize_path_component "${version_part}")" \
        "$(sanitize_path_component "${arch_part}")"
}

official_source_dir()     { printf '%s/official/source\n' "${WORK_DIR}"; }
official_metadata_dir()   { printf '%s/official/metadata\n' "${WORK_DIR}"; }
official_filtered_dir()   { printf '%s/official-filtered\n' "${WORK_DIR}"; }
built_root_dir()          { printf '%s/built\n' "${WORK_DIR}"; }
built_apks_dir()          { printf '%s/built/apks\n' "${WORK_DIR}"; }
built_filtered_dir()      { printf '%s/built-filtered\n' "${WORK_DIR}"; }
comparison_dir()          { printf '%s/comparison\n' "${WORK_DIR}"; }
repo_default_dir()        { printf '%s/repo-default\n' "${WORK_DIR}"; }
repo_exact_dir()          { printf '%s/repo-exact\n' "${WORK_DIR}"; }
outputs_dir()             { printf '%s/outputs\n' "${WORK_DIR}"; }

official_single_apk() {
    find "$(official_source_dir)" -maxdepth 1 -type f -name '*.apk' | sort | head -n1
}

find_base_apk_in_dir() {
    local dir="$1"
    if [[ -f "${dir}/base.apk" ]]; then
        printf '%s\n' "${dir}/base.apk"
        return 0
    fi
    if [[ -f "${dir}/base-master.apk" ]]; then
        printf '%s\n' "${dir}/base-master.apk"
        return 0
    fi
    local candidate
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        printf '%s\n' "${candidate}"
        return 0
    done < <(find "${dir}" -maxdepth 1 -type f -name 'base*.apk' | sort)
    return 1
}

copy_input_apks_from_dir() {
    local src_dir="$1"
    local dst_dir="$2"
    mkdir -p "${dst_dir}"
    local copied=0
    while IFS= read -r apk_file; do
        cp "${apk_file}" "${dst_dir}/"
        copied=1
    done < <(find "${src_dir}" -maxdepth 1 -type f -name '*.apk' | sort)
    if [[ "${copied}" -eq 0 ]]; then
        log_fail "No APK files found in ${src_dir}"
        emit_failure_and_exit "No APK files found in ${src_dir}" "${EXIT_INVALID}"
    fi
}

fast_apk_pre_check() {
    local apk_input="$1"
    local apk_to_check=""

    if [[ -f "${apk_input}" && "${apk_input}" == *.apk ]]; then
        apk_to_check="${apk_input}"
    elif [[ -d "${apk_input}" ]]; then
        apk_to_check="$(find "${apk_input}" -maxdepth 1 \( -name 'base.apk' -o -name 'base-master.apk' \) | head -n1)"
        [[ -z "${apk_to_check}" ]] && apk_to_check="$(find "${apk_input}" -maxdepth 1 -name '*.apk' | sort | head -n1)"
    fi
    [[ -z "${apk_to_check}" ]] && return 0  # archive or no apk found — skip

    log_info "Package name pre-check (lightweight)..."
    local pkg
    pkg="$(${CONTAINER_CMD} run --rm \
        --entrypoint sh \
        ${CONTAINER_RUN_EXTRA} \
        -v "${apk_to_check}:/tmp/check.apk:ro" \
        "${HELPER_GIT_IMAGE}" \
        -c "unzip -p /tmp/check.apk AndroidManifest.xml 2>/dev/null \
            | grep -oa '[a-z][a-z0-9]*\(\.[a-z][a-z0-9]*\)\{2,\}' \
            | head -n1" 2>/dev/null | tr -d '\r\n')"

    [[ -z "${pkg}" ]] && return 0  # couldn't determine — container check will catch it

    if [[ "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package name mismatch: expected ${APP_ID}, got ${pkg}"
        emit_failure_and_exit "Package name mismatch: expected ${APP_ID}, got ${pkg}. Wrong APK provided." "${EXIT_INVALID}"
    fi
    log_info "Package name pre-check passed: ${pkg}"
}

assert_package_name() {
    local image="$1"
    [[ "${SINGLE_APK_PKG_VERIFIED:-false}" == "true" ]] && return 0
    local apk_path
    if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
        apk_path="${SINGLE_APK_PATH}"
    else
        apk_path="$(official_base_apk 2>/dev/null || true)"
        [[ -z "${apk_path}" ]] && apk_path="$(official_single_apk 2>/dev/null || true)"
    fi
    [[ -z "${apk_path}" ]] && return 0  # no APK to check yet, skip
    local apk_rel="${apk_path#"${WORK_DIR}/"}"
    local pkg
    pkg="$(extract_apk_field "${image}" "${apk_rel}" packageName)"
    if [[ -n "${pkg}" && "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package name mismatch: expected ${APP_ID}, got ${pkg}"
        emit_failure_and_exit "Package name mismatch: expected ${APP_ID}, got ${pkg}. Wrong APK provided." "${EXIT_INVALID}"
    fi
    log_info "Package name verified: ${pkg}"
}

detect_single_apk_type() {
    local image="$1"
    local apk_abs="$2"
    local apk_rel="${apk_abs#"${WORK_DIR}/"}"

    local meta
    meta="$(container_exec "${image}" "
        AAPT2='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/aapt2'
        APKSIGNER='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/apksigner'
        BADGING=\"\$(\"\${AAPT2}\" dump badging '${apk_rel}' 2>/dev/null)\"
        SPLIT=\$(echo \"\${BADGING}\" | grep -m1 '^split=' || true)
        PKG=\$(echo \"\${BADGING}\" | sed -n \"s/^package: name='\\([^']*\\)'.*/\\1/p\" | head -n1)
        SIGNER=\$(\"\${APKSIGNER}\" verify --print-certs '${apk_rel}' 2>/dev/null \
            | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -n1)
        printf 'SPLIT=%s\nPKG=%s\nSIGNER=%s\n' \"\${SPLIT}\" \"\${PKG}\" \"\${SIGNER}\"
    " | tr -d '\r')"

    local split_field pkg signer
    split_field="$(echo "${meta}" | grep '^SPLIT=' | sed 's/^SPLIT=//')"
    pkg="$(echo "${meta}" | grep '^PKG=' | sed 's/^PKG=//')"
    signer="$(echo "${meta}" | grep '^SIGNER=' | sed 's/^SIGNER=//')"

    if [[ -n "${split_field}" ]]; then
        log_fail "Lone split APK detected (${split_field}). This is one slice of a Play Store split set."
        log_fail "Provide the full split set as a directory or .apks/.zip, or provide the Bitkey GitHub release APK."
        emit_failure_and_exit "Lone split APK detected. Provide the full split set or the GitHub release emergency APK." "${EXIT_INVALID}"
    fi

    log_info "APK type: full single APK (no split= field — treating as emergency APK)"

    if [[ -n "${signer}" && "${signer}" != "${BITKEY_KNOWN_SIGNER}" ]]; then
        log_warn "Signer mismatch: expected ${BITKEY_KNOWN_SIGNER}"
        log_warn "                 got      ${signer}"
        log_warn "This APK may not be an official Bitkey release artifact."
    else
        log_info "Signer matches known Bitkey certificate."
    fi

    if [[ -n "${pkg}" && "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package name mismatch: expected ${APP_ID}, got ${pkg}"
        emit_failure_and_exit "Package name mismatch: expected ${APP_ID}, got ${pkg}. Wrong APK provided." "${EXIT_INVALID}"
    fi
    log_info "Package name verified: ${pkg}"
    SINGLE_APK_PKG_VERIFIED=true
}

detect_container_runtime() {
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        VOLUME_RO=":ro"
        VOLUME_RW=""
        CONTAINER_RUN_EXTRA="--user $(id -u):$(id -g)"
        log_info "Using docker as container runtime"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        VOLUME_RO=":ro,Z"
        VOLUME_RW=":Z"
        CONTAINER_RUN_EXTRA="--userns=keep-id"
        log_info "Using podman as container runtime"
    else
        log_fail "Neither podman nor docker is available."
        emit_failure_and_exit "Neither podman nor docker found on host. Install one to continue." "${EXIT_FAILED}"
    fi
}

run_git_container() {
    local cmd="$1"
    # alpine/git has ENTRYPOINT ["git"] — override it so we can run shell commands
    ${CONTAINER_CMD} run --rm \
        --entrypoint sh \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${HELPER_GIT_IMAGE}" \
        -lc "${cmd}"
}

container_exec() {
    local image="$1"
    local cmd="$2"
    # Bitkey images use ENTRYPOINT ["/bin/bash", "-c"] — pass cmd directly as
    # the single argument; Docker invokes: /bin/bash -c "${cmd}"
    ${CONTAINER_CMD} run --rm \
        --platform=linux/amd64 \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${image}" \
        "${cmd}"
}

container_exec_build() {
    local image="$1"
    local cmd="$2"
    # Gradle build containers must run without user remapping so they can write
    # to /build (owned by root in the image). Each build function is responsible
    # for chmod-ing its /work outputs so the host user can read them.
    ${CONTAINER_CMD} run --rm \
        --platform=linux/amd64 \
        --memory=32g \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${image}" \
        "${cmd}"
}

build_helper_image() {
    local image="$1"
    local repo_dir="$2"
    log_info "Building Bitkey helper image: ${image}"
    ${CONTAINER_CMD} build \
        --platform=linux/amd64 \
        -f "${repo_dir}/app/verifiable-build/android/Dockerfile" \
        -t "${image}" \
        --target base \
        "${repo_dir}" >/dev/null
}

build_final_image() {
    local image="$1"
    local repo_dir="$2"
    local build_vars_file="$3"
    local build_vars_json
    build_vars_json="$(tr -d '\n' < "${build_vars_file}")"
    log_info "Building Bitkey verification image: ${image}"
    ${CONTAINER_CMD} build \
        --platform=linux/amd64 \
        -f "${repo_dir}/app/verifiable-build/android/Dockerfile" \
        -t "${image}" \
        --target build \
        --build-arg "REPRODUCIBLE_BUILD_VARIABLES=${build_vars_json}" \
        "${repo_dir}" >/dev/null
}

clone_ref_into_repo() {
    local ref="$1"
    local rel_dir="$2"
    local with_submodules="$3"
    local clone_cmd
    rm -rf "${WORK_DIR}/${rel_dir}"
    if [[ "${with_submodules}" == "true" ]]; then
        clone_cmd="git clone --depth 1 --branch '${ref}' '${REPO_URL}' '${rel_dir}' && \
            git -C '${rel_dir}' submodule update --init --recursive --depth 1"
    else
        clone_cmd="git clone --depth 1 --branch '${ref}' '${REPO_URL}' '${rel_dir}'"
    fi
    run_git_container "${clone_cmd}"
}

git_commit_hash_from_repo() {
    local rel_dir="$1"
    run_git_container "git -C '${rel_dir}' rev-parse HEAD"
}

extract_apk_field() {
    local image="$1"
    local apk_rel="$2"
    local field="$3"
    local parser=""
    case "${field}" in
        versionName) parser="sed -n \"s/.*versionName='\\([^']*\\)'.*/\\1/p\" | head -n1" ;;
        versionCode) parser="sed -n \"s/.*versionCode='\\([^']*\\)'.*/\\1/p\" | head -n1" ;;
        sdkVersion) parser="sed -n \"s/.*sdkVersion:'\\([0-9]*\\)'.*/\\1/p\" | head -n1" ;;
        targetSdkVersion) parser="sed -n \"s/.*targetSdkVersion:'\\([0-9]*\\)'.*/\\1/p\" | head -n1" ;;
        packageName) parser="sed -n \"s/^package: name='\\([^']*\\)'.*/\\1/p\" | head -n1" ;;
        *)
            log_fail "Unsupported APK metadata field: ${field}"
            exit "${EXIT_FAILED}"
            ;;
    esac
    container_exec "${image}" "
        AAPT2=\"/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/aapt2\"
        \"\${AAPT2}\" dump badging '${apk_rel}' 2>/dev/null | ${parser}
    " | tr -d '\r'
}

extract_signer_hash() {
    local image="$1"
    local apk_rel="$2"
    container_exec "${image}" "
        APKSIGNER=\"/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/apksigner\"
        \"\${APKSIGNER}\" verify --print-certs '${apk_rel}' 2>/dev/null \
          | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -n1
    " | tr -d '\r'
}

extract_sha256() {
    local image="$1"
    local rel_path="$2"
    container_exec "${image}" "sha256sum '${rel_path}' | awk '{print \$1}'" | tr -d '\r'
}

prepare_official_inputs() {
    local image="$1"
    local src_dir
    src_dir="$(official_source_dir)"
    rm -rf "$(official_source_dir)" "$(official_metadata_dir)"
    mkdir -p "${src_dir}" "$(official_metadata_dir)" "${WORK_DIR}/input"

    if [[ -d "${APK_INPUT}" ]]; then
        log_info "Copying official APKs from directory input"
        copy_input_apks_from_dir "${APK_INPUT}" "${src_dir}"
    elif [[ -f "${APK_INPUT}" ]]; then
        # Detect archive type by content first — ABS may save any format as _downloaded.apk
        local _content_type="unknown"
        if file "${APK_INPUT}" | grep -q "Zip archive" && \
           unzip -l "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
            _content_type="zip"
        elif file "${APK_INPUT}" | grep -qE "gzip compressed|POSIX tar archive|tar archive" && \
             tar -tf "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
            _content_type="tar"
        fi

        case "${APK_INPUT}" in
            *.apks|*.zip)
                log_info "Extracting official APKs from zip archive input"
                cp "${APK_INPUT}" "${WORK_DIR}/input/official-input.zip"
                container_exec "${image}" "
                    set -euo pipefail
                    rm -rf extracted-official
                    mkdir -p extracted-official official/source
                    unzip -qq -o input/official-input.zip -d extracted-official
                    find extracted-official -type f -name '*.apk' -exec cp {} official/source/ \\;
                "
                ;;
            *.tar.gz|*.tgz|*.tar)
                log_info "Extracting official APKs from tar archive input"
                cp "${APK_INPUT}" "${WORK_DIR}/input/official-input.tar"
                container_exec "${image}" "
                    set -euo pipefail
                    rm -rf extracted-official
                    mkdir -p extracted-official official/source
                    tar -xf input/official-input.tar -C extracted-official
                    find extracted-official -type f -name '*.apk' -exec cp {} official/source/ \\;
                "
                ;;
            *.apk)
                if [[ "${_content_type}" == "tar" ]]; then
                    log_info "Detected tar/tar.gz archive saved with .apk extension — extracting as archive"
                    cp "${APK_INPUT}" "${WORK_DIR}/input/official-input.tar"
                    container_exec "${image}" "
                        set -euo pipefail
                        rm -rf extracted-official
                        mkdir -p extracted-official official/source
                        tar -xf input/official-input.tar -C extracted-official
                        find extracted-official -type f -name '*.apk' -exec cp {} official/source/ \\;
                    "
                elif [[ "${_content_type}" == "zip" ]]; then
                    log_info "Detected zip archive saved with .apk extension — extracting as archive"
                    cp "${APK_INPUT}" "${WORK_DIR}/input/official-input.zip"
                    container_exec "${image}" "
                        set -euo pipefail
                        rm -rf extracted-official
                        mkdir -p extracted-official official/source
                        unzip -qq -o input/official-input.zip -d extracted-official
                        find extracted-official -type f -name '*.apk' -exec cp {} official/source/ \\;
                    "
                else
                    log_info "Single .apk file input detected — checking APK type."
                    local single_dest="${src_dir}/$(basename "${APK_INPUT}")"
                    cp "${APK_INPUT}" "${single_dest}"
                    detect_single_apk_type "${image}" "${single_dest}"
                    SINGLE_APK_MODE=true
                    SINGLE_APK_PATH="${single_dest}"
                fi
                ;;
            *)
                log_fail "--binary must be a directory, .apks, .zip, .tar.gz, or .tar file."
                emit_failure_and_exit "Unsupported --binary input: ${APK_INPUT}" "${EXIT_INVALID}"
                ;;
        esac
    else
        log_fail "--binary path not found: ${APK_INPUT}"
        emit_failure_and_exit "--binary path not found: ${APK_INPUT}" "${EXIT_INVALID}"
    fi

    local base_in_source=""
    if base_in_source="$(find_base_apk_in_dir "${src_dir}" 2>/dev/null)"; then
        cp "${base_in_source}" "$(official_metadata_dir)/$(basename "${base_in_source}")"
    fi

    if [[ -z "$(find "$(official_source_dir)" -maxdepth 1 -type f -name '*.apk' -print -quit)" ]]; then
        log_fail "No APK files were prepared from the official input."
        emit_failure_and_exit "No APK files were prepared from the official input." "${EXIT_INVALID}"
    fi

    assert_package_name "${image}"
    OFFICIAL_INPUTS_PREPARED=true
}

official_base_apk() {
    local metadata_base=""
    metadata_base="$(find_base_apk_in_dir "$(official_metadata_dir)" 2>/dev/null || true)"
    if [[ -n "${metadata_base}" ]]; then
        printf '%s\n' "${metadata_base}"
        return 0
    fi
    find_base_apk_in_dir "$(official_source_dir)" 2>/dev/null
}

ensure_work_dir_named_for_version() {
    local version_part="$1"
    local arch_part="$2"
    local final_dir
    final_dir="$(work_dir_for "${version_part}" "${arch_part}")"
    if [[ "${WORK_DIR}" == "${final_dir}" ]]; then
        return 0
    fi
    rm -rf "${final_dir}"
    mv "${WORK_DIR}" "${final_dir}"
    WORK_DIR="${final_dir}"
}

resolve_version_with_temp_helper() {
    local apk_path
    if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
        apk_path="$(official_single_apk || true)"
    else
        apk_path="$(official_base_apk || true)"
    fi
    if [[ -z "${apk_path}" ]]; then
        log_fail "Could not find APK to read version from. Provide --version explicitly."
        emit_failure_and_exit "Could not find APK in the provided official input to read versionName." "${EXIT_INVALID}"
    fi
    local apk_rel="${apk_path#"${WORK_DIR}/"}"
    VERSION="$(extract_apk_field "${TEMP_BASE_IMAGE}" "${apk_rel}" versionName)"
    if [[ -z "${VERSION}" ]]; then
        log_fail "Could not determine versionName from APK. Provide --version explicitly."
        emit_failure_and_exit "Could not determine versionName from APK. Provide --version explicitly." "${EXIT_INVALID}"
    fi
    # Strip Play Store build number suffix e.g. "2026.7.0 (2)" → "2026.7.0".
    VERSION="${VERSION%% (*}"
    log_info "Version derived from APK metadata: ${VERSION}"
}

host_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local tool out detected
    for tool in aapt2 aapt; do
        if command -v "${tool}" >/dev/null 2>&1; then
            out="$("${tool}" dump badging "${apk_path}" 2>/dev/null || true)"
            if [[ -n "${out}" ]]; then
                detected="$(printf '%s\n' "${out}" \
                    | sed -n "s/.*${field}='\([^']*\)'.*/\1/p" \
                    | head -n1)"
                [[ -n "${detected}" ]] && { printf '%s\n' "${detected}"; return 0; }
            fi
        fi
    done
    return 1
}

container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
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
        ' 2>/dev/null || true
}

detect_apk_metadata_field() {
    local apk_path="$1"
    local field="$2"
    local detected
    detected="$(host_aapt_version "${apk_path}" "${field}" || true)"
    if [[ -n "${detected}" ]]; then
        printf '%s\n' "${detected}"
        return 0
    fi
    container_aapt_version "${apk_path}" "${field}" || true
}

detect_version_from_binary() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' RETURN

    local base_apk=""
    if [[ -f "${APK_INPUT}" ]]; then
        local _ct="unknown"
        if file "${APK_INPUT}" | grep -q "Zip archive" && \
           unzip -l "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
            _ct="zip"
        elif file "${APK_INPUT}" | grep -qE "gzip compressed|POSIX tar archive|tar archive" && \
             tar -tf "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
            _ct="tar"
        fi

        if [[ "${APK_INPUT}" == *.apk && "${_ct}" == "unknown" ]]; then
            base_apk="${APK_INPUT}"
        elif [[ "${_ct}" == "tar" || "${APK_INPUT}" == *.tar.gz || "${APK_INPUT}" == *.tgz || "${APK_INPUT}" == *.tar ]]; then
            tar -xf "${APK_INPUT}" -C "${tmp_dir}" 2>/dev/null || true
            base_apk="$(find "${tmp_dir}" -maxdepth 2 \( -name 'base.apk' -o -name 'base-master.apk' \) | head -n1 || true)"
            [[ -z "${base_apk}" ]] && base_apk="$(find "${tmp_dir}" -maxdepth 2 -name '*.apk' | sort | head -n1 || true)"
        elif [[ "${_ct}" == "zip" || "${APK_INPUT}" == *.zip || "${APK_INPUT}" == *.apks ]]; then
            unzip -qq -o "${APK_INPUT}" -d "${tmp_dir}" 2>/dev/null || true
            base_apk="$(find "${tmp_dir}" -maxdepth 2 \( -name 'base.apk' -o -name 'base-master.apk' \) | head -n1 || true)"
            [[ -z "${base_apk}" ]] && base_apk="$(find "${tmp_dir}" -maxdepth 2 -name '*.apk' | sort | head -n1 || true)"
        fi
    elif [[ -d "${APK_INPUT}" ]]; then
        base_apk="$(find "${APK_INPUT}" -maxdepth 1 \( -name 'base.apk' -o -name 'base-master.apk' \) | head -n1 || true)"
        [[ -z "${base_apk}" ]] && base_apk="$(find "${APK_INPUT}" -maxdepth 1 -name '*.apk' | sort | head -n1 || true)"
    fi

    if [[ -z "${base_apk}" ]]; then
        log_fail "Could not locate base.apk in --binary input to read versionName. Provide --version explicitly."
        emit_failure_and_exit "Could not find APK to detect version." "${EXIT_INVALID}"
    fi

    log_info "Detecting version from: $(basename "${base_apk}")"
    local ver
    ver="$(detect_apk_metadata_field "${base_apk}" "versionName" || true)"
    if [[ -z "${ver}" ]]; then
        log_fail "Could not read versionName from APK. Provide --version explicitly."
        emit_failure_and_exit "Could not determine versionName from APK." "${EXIT_INVALID}"
    fi
    VERSION="${ver%% (*}"
    log_info "Version derived from APK metadata: ${VERSION}"
}

collect_official_metadata() {
    local image="$1"
    local apk_path
    if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
        apk_path="$(official_single_apk || true)"
    else
        apk_path="$(official_base_apk || true)"
    fi
    if [[ -z "${apk_path}" ]]; then
        log_fail "No APK found in official input to collect metadata from."
        emit_failure_and_exit "No APK found in official input." "${EXIT_INVALID}"
    fi
    local apk_rel="${apk_path#"${WORK_DIR}/"}"

    OFFICIAL_VERSION_NAME="$(extract_apk_field "${image}" "${apk_rel}" versionName)"
    OFFICIAL_VERSION_CODE="$(extract_apk_field "${image}" "${apk_rel}" versionCode)"
    OFFICIAL_SDK_VERSION="$(extract_apk_field "${image}" "${apk_rel}" targetSdkVersion)"
    if [[ -z "${OFFICIAL_SDK_VERSION}" ]]; then
        OFFICIAL_SDK_VERSION="$(extract_apk_field "${image}" "${apk_rel}" sdkVersion)"
    fi
    OFFICIAL_SIGNER="$(extract_signer_hash "${image}" "${apk_rel}")"
    OFFICIAL_HASH="$(extract_sha256 "${image}" "${apk_rel}")"
    OFFICIAL_APK_SIZE="$(stat -c '%s' "${apk_path}" 2>/dev/null || echo unknown)"
    if [[ -z "${OFFICIAL_SDK_VERSION}" ]]; then
        OFFICIAL_SDK_VERSION="35"
    fi

    local apk_version_base="${OFFICIAL_VERSION_NAME%% (*}"
    if [[ -n "${VERSION}" && -n "${apk_version_base}" && "${VERSION}" != "${apk_version_base}" ]]; then
        log_warn "Requested version ${VERSION}, but APK metadata reports ${OFFICIAL_VERSION_NAME}"
    fi
}

extract_reproducible_build_variables() {
    local image="$1"
    local out_file="${WORK_DIR}/reproducible-build-variables.json"

    if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
        # Emergency APK: download build-variables-emergency-{version}.json from GitHub releases
        local url="${GITHUB_RELEASE_BASE}/app/${VERSION}/build-variables-emergency-${VERSION}.json"
        log_info "Downloading build variables for emergency APK: ${url}"
        container_exec "${image}" "
            set -euo pipefail
            curl -fsSL '${url}' -o reproducible-build-variables.json
        "
        log_info "Downloaded build-variables-emergency-${VERSION}.json"
    else
        # Split APK (Play Store): extract from base.apk
        container_exec "${image}" "
            set -euo pipefail
            found=0
            for apk in official/metadata/*.apk official/source/*.apk; do
                [ -f \"\$apk\" ] || continue
                if unzip -p \"\$apk\" reproducible-build-variables.json > reproducible-build-variables.json 2>/dev/null; then
                    found=1
                    break
                fi
            done
            if [ \"\$found\" -ne 1 ]; then
                echo 'Could not extract reproducible-build-variables.json from official APKs.' >&2
                exit 1
            fi
        "
        log_info "Extracted reproducible-build-variables.json from official APKs"
    fi

    printf '%s\n' "${out_file}"
}

generate_device_spec_json() {
    local output_file="$1"
    local abi_list=()
    local locale_list=()
    local density="480"
    local sdk_version="${OFFICIAL_SDK_VERSION:-35}"
    local filename suffix locale_value

    while IFS= read -r filename; do
        filename="$(basename "${filename}")"
        case "${filename}" in
            split_config.arm64_v8a.apk) abi_list+=("arm64-v8a") ;;
            split_config.armeabi_v7a.apk) abi_list+=("armeabi-v7a") ;;
            split_config.x86_64.apk) abi_list+=("x86_64") ;;
            split_config.x86.apk) abi_list+=("x86") ;;
            split_config.xxxhdpi.apk) density="640" ;;
            split_config.xxhdpi.apk) density="480" ;;
            split_config.xhdpi.apk) density="320" ;;
            split_config.hdpi.apk) density="240" ;;
            split_config.mdpi.apk) density="160" ;;
            split_config.ldpi.apk) density="120" ;;
            split_config.*.apk)
                suffix="${filename#split_config.}"
                suffix="${suffix%.apk}"
                case "${suffix}" in
                    arm64_v8a|armeabi_v7a|x86_64|x86|xxxhdpi|xxhdpi|xhdpi|hdpi|mdpi|ldpi)
                        ;;
                    *)
                        locale_value="${suffix//_/-}"
                        locale_list+=("${locale_value}")
                        ;;
                esac
                ;;
        esac
    done < <(find "$(official_source_dir)" -maxdepth 1 -type f -name '*.apk' | sort)

    if [[ ${#abi_list[@]} -eq 0 ]]; then
        abi_list=("arm64-v8a")
    fi
    if [[ ${#locale_list[@]} -eq 0 ]]; then
        locale_list=("en")
    fi

    mapfile -t abi_list < <(printf '%s\n' "${abi_list[@]}" | awk '!seen[$0]++')

    # If --arch was provided, validate it matches the detected splits.
    # A mismatch means the supplied splits and the requested arch disagree — fail loudly.
    if [[ -n "${ARCH}" ]]; then
        local arch_found=false
        local a
        for a in "${abi_list[@]}"; do
            [[ "${a}" == "${ARCH}" ]] && arch_found=true && break
        done
        if [[ "${arch_found}" == "false" ]]; then
            log_fail "--arch '${ARCH}' not found in detected splits (detected: $(IFS=,; echo "${abi_list[*]}"))."
            log_fail "Either remove --arch or supply splits that match the requested architecture."
            emit_failure_and_exit "--arch '${ARCH}' conflicts with detected split ABIs: $(IFS=,; echo "${abi_list[*]}")." "${EXIT_INVALID}"
        fi
    fi
    mapfile -t locale_list < <(printf '%s\n' "${locale_list[@]}" | awk '!seen[$0]++')

    GENERATED_ARCH="${abi_list[0]}"

    {
        printf '{\n'
        printf '  "supportedAbis": ['
        local first=1 abi
        for abi in "${abi_list[@]}"; do
            [[ ${first} -eq 1 ]] || printf ', '
            printf '"%s"' "${abi}"
            first=0
        done
        printf '],\n'
        printf '  "screenDensity": %s,\n' "${density}"
        printf '  "sdkVersion": %s,\n' "${sdk_version}"
        printf '  "supportedLocales": ['
        first=1
        local locale
        for locale in "${locale_list[@]}"; do
            [[ ${first} -eq 1 ]] || printf ', '
            printf '"%s"' "${locale}"
            first=0
        done
        printf ']\n'
        printf '}\n'
    } > "${output_file}"

    log_info "device-spec.json created (abis=$(IFS=,; echo "${abi_list[*]}"), density=${density}, sdkVersion=${sdk_version})"
}

download_bundletool_jar() {
    local image="$1"
    local target_rel="bundletool.jar"
    container_exec "${image}" "
        set -euo pipefail
        curl -fsSL 'https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar' \
          -o '${target_rel}'
    "
}

build_bitkey_aab() {
    local image="$1"
    mkdir -p "$(outputs_dir)"
    container_exec_build "${image}" "
        set -euo pipefail
        cd /build
        source bin/activate-hermit
        cd app
        export UPLOAD_BUGSNAG_MAPPING=false
        unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER
        export SCCACHE_DISABLE=1
        export CARGO_BUILD_JOBS=4
        export GRADLE_OPTS=\"-Xmx8g -XX:MaxMetaspaceSize=512m\"
        export KOTLIN_DAEMON_JVM_OPTIONS=\"-Xmx4g -XX:MaxMetaspaceSize=512m\"
        aab_path='/build/app/android/app/_build/outputs/bundle/customer/app-customer.aab'
        staging_dir='customer-modify'

        echo '[DIAG] Memory before bundleCustomer:' && free -m

        set +e
        gradle :android:app:bundleCustomer \
          --no-daemon \
          --no-build-cache \
          --stacktrace \
          -Dcom.android.tools.r8.deterministicdebugging=true
        gradle_exit=\$?
        set -e

        echo '[DIAG] Memory after bundleCustomer:' && free -m
        mkdir -p /work/comparison/
        cp -r /root/.gradle/daemon/ /work/comparison/gradle-daemon-logs/ 2>/dev/null || true
        chmod -R a+rwX /work/comparison/gradle-daemon-logs/ 2>/dev/null || true

        [[ \$gradle_exit -eq 0 ]] || exit \$gradle_exit

        rm -rf \"\${staging_dir}\"
        mkdir -p \"\${staging_dir}\"
        unzip -q \"\${aab_path}\" -d \"\${staging_dir}\"
        cd \"\${staging_dir}\"
        rm -f BUNDLE-METADATA/com.android.tools/r8.json
        find . -exec touch -t '202505221555' {} +
        zip -rq -D -X -9 -A --compression-method deflate ../app-customer.aab.zip *
        cd ..
        mv app-customer.aab.zip \"\${aab_path}\"
        cp \"\${aab_path}\" /work/outputs/app-customer.aab
        chmod -R a+rwX /work/outputs 2>/dev/null || true
    "
    log_info "Built normalized AAB: $(outputs_dir)/app-customer.aab"
}

build_bitkey_emergency_apk() {
    local image="$1"
    mkdir -p "$(outputs_dir)"
    container_exec_build "${image}" "
        set -euo pipefail
        cd /build
        source bin/activate-hermit
        cd app
        export UPLOAD_BUGSNAG_MAPPING=false
        unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER
        export SCCACHE_DISABLE=1
        export CARGO_BUILD_JOBS=4
        gradle :android:app:assembleEmergency \
          --no-daemon \
          --no-build-cache \
          -Dcom.android.tools.r8.deterministicdebugging=true

        # Bitkey's upstream release flow copies the emergency APK out of the
        # Gradle outputs tree, where the artifact is typically unsigned.
        build_outputs=''
        for candidate in \
          /build/app/android/app/_build/outputs \
          /build/app/android/app/build/outputs; do
            if [ -d \"\$candidate\" ]; then
                build_outputs=\"\$candidate\"
                break
            fi
        done
        if [ -z \"\$build_outputs\" ]; then
            echo 'Could not find Gradle outputs directory for emergency APK build.' >&2
            exit 1
        fi

        apk_path=''
        for candidate in \
          \"\$build_outputs/apk/emergency/app-emergency-unsigned.apk\" \
          \"\$build_outputs/apk/emergency/release/app-emergency-unsigned.apk\" \
          \"\$build_outputs/apk/emergency/app-emergency.apk\" \
          \"\$build_outputs/apk/emergency/release/app-emergency.apk\"; do
            if [ -f \"\$candidate\" ]; then
                apk_path=\"\$candidate\"
                break
            fi
        done
        if [ -z \"\$apk_path\" ]; then
            apk_path=\"\$(find \"\$build_outputs\" -path '*/apk/emergency/*' -name '*.apk' \
              2>/dev/null | sort | head -n1)\"
        fi
        if [ -z \"\$apk_path\" ]; then
            echo 'Could not find built emergency APK in Gradle outputs.' >&2
            echo \"Checked under: \$build_outputs\" >&2
            find \"\$build_outputs\" -maxdepth 5 -type f -name '*.apk' 2>/dev/null | sort >&2 || true
            exit 1
        fi
        cp \"\$apk_path\" /work/outputs/app-emergency.apk
        printf '%s\n' \"\$apk_path\" > /work/outputs/app-emergency-source-path.txt
        chmod -R a+rwX /work/outputs 2>/dev/null || true
    "
    log_info "Built emergency APK: $(outputs_dir)/app-emergency.apk"
}

extract_built_split_apks() {
    local image="$1"
    mkdir -p "$(built_root_dir)"
    container_exec "${image}" "
        set -euo pipefail
        rm -rf built/tmp built/apks
        mkdir -p built/tmp built/apks
        java -jar bundletool.jar build-apks \
          --bundle=outputs/app-customer.aab \
          --output=built/tmp/bitkey.apks \
          --device-spec=device-spec.json \
          --mode=default \
          --overwrite
        unzip -qq -o built/tmp/bitkey.apks -d built/tmp/unzipped
        find built/tmp/unzipped -type f -name '*.apk' -exec cp {} built/apks/ \\;
        if [ -f built/apks/base-master.apk ]; then
            mv built/apks/base-master.apk built/apks/base.apk
        fi
        chmod -R a+rwX built 2>/dev/null || true
    "
}

run_upstream_normalization() {
    local image="$1"
    rm -rf "${WORK_DIR}/official-work" "${WORK_DIR}/built-work"
    mkdir -p "${WORK_DIR}/official-work" "${WORK_DIR}/built-work"
    container_exec "${image}" "
        set -euo pipefail
        export AAPT2='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/aapt2'
        rm -rf official-work/* built-work/*
        /build/app/verifiable-build/android/verification/steps/normalize-apk-names-new \
          official/source official-work/normalized-names device
        /build/app/verifiable-build/android/verification/steps/unpack-apks \
          official-work/normalized-names official-work/unpacked
        /build/app/verifiable-build/android/verification/steps/normalize-apk-content \
          official-work/unpacked official-work/comparable

        /build/app/verifiable-build/android/verification/steps/normalize-apk-names-new \
          built/apks built-work/normalized-names bundletool
        /build/app/verifiable-build/android/verification/steps/unpack-apks \
          built-work/normalized-names built-work/unpacked
        /build/app/verifiable-build/android/verification/steps/normalize-apk-content \
          built-work/unpacked built-work/comparable

        chmod -R a+rwX official-work built-work 2>/dev/null || true
    "
}

prepare_single_split_compare_dirs() {
    local image="$1"
    rm -rf "$(official_filtered_dir)" "$(built_filtered_dir)"
    mkdir -p "$(official_filtered_dir)" "$(built_filtered_dir)"
    container_exec "${image}" "
        set -euo pipefail
        mkdir -p official-filtered/normalized-names official-filtered/comparable
        mkdir -p built-filtered/normalized-names built-filtered/comparable
        for file in official-work/normalized-names/*; do
            [ -f \"\$file\" ] || continue
            name=\"\$(basename \"\$file\")\"
            stem=\"\${name%.apk}\"
            cp \"\$file\" official-filtered/normalized-names/
            cp -R \"official-work/comparable/\${stem}\" official-filtered/comparable/\${stem}
            if [ ! -f \"built-work/normalized-names/\${name}\" ]; then
                echo \"Missing built split after bundletool normalization: \${name}\" >&2
                exit 1
            fi
            cp \"built-work/normalized-names/\${name}\" built-filtered/normalized-names/
            cp -R \"built-work/comparable/\${stem}\" built-filtered/comparable/\${stem}
        done
        chmod -R a+rwX official-filtered built-filtered 2>/dev/null || true
    "
}

write_plain_diff_file() {
    local image="$1"
    mkdir -p "$(comparison_dir)"
    container_exec "${image}" "
        set -euo pipefail
        diff -x resources.arsc -qr official-work/comparable built-work/comparable > comparison/diff-unzipped-apks.txt 2>&1 || true
        chmod -R a+rwX comparison 2>/dev/null || true
    "
}

run_excluded_files_report() {
    local image="$1"
    local report_file="comparison/excluded-files-report.txt"
    mkdir -p "$(comparison_dir)"
    container_exec "${image}" "
        set -euo pipefail
        export AAPT2='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/aapt2'

        {
        echo '=== Excluded Files ==='
        echo 'Files removed by Bitkey upstream normalize-apk-content before comparison:'
        echo '  AndroidManifest.xml'
        echo '  stamp-cert-sha256'
        echo '  BNDLTOOL.RSA / BNDLTOOL.SF / MANIFEST.MF  (bundletool signing)'
        echo '  EMERGENC.RSA / EMERGENC.SF                 (emergency APK signing)'
        echo '  r8.json                                    (R8 optimizer metadata)'
        echo '  res/xml/splits*.xml                        (bundletool split metadata)'
        echo ''

        echo '=== AndroidManifest.xml Diffs ==='
        found_manifest=0
        for apk in official-work/normalized-names/*.apk; do
            [ -f \"\$apk\" ] || continue
            split_name=\$(basename \"\$apk\" .apk)
            built_apk=\"built-work/normalized-names/\${split_name}.apk\"
            [ -f \"\$built_apk\" ] || continue

            official_xml=\$(\"\${AAPT2}\" dump xmltree \"\$apk\" --file AndroidManifest.xml 2>/dev/null || true)
            built_xml=\$(\"\${AAPT2}\" dump xmltree \"\$built_apk\" --file AndroidManifest.xml 2>/dev/null || true)

            [ -z \"\$official_xml\" ] && [ -z \"\$built_xml\" ] && continue

            found_manifest=1
            echo \"--- \${split_name}.apk ---\"
            echo \"\$official_xml\" > /tmp/ws_official_manifest.txt
            echo \"\$built_xml\" > /tmp/ws_built_manifest.txt
            diff /tmp/ws_official_manifest.txt /tmp/ws_built_manifest.txt || true
            echo ''
        done
        [ \"\$found_manifest\" -eq 0 ] && echo '(no AndroidManifest.xml found in any split APK)'
        echo ''

        echo '=== r8.json ==='
        echo 'Note: r8.json was removed from the built AAB before split generation.'
        echo 'Note: r8.json is also excluded by upstream normalize-apk-content.'
        echo ''
        official_r8=\$(find official-work/unpacked -name r8.json 2>/dev/null | sort | head -5 || true)
        if [ -n \"\$official_r8\" ]; then
            echo 'Found in official unpacked splits:'
            for f in \$official_r8; do
                echo \"  \$f\"
                cat \"\$f\" || true
                echo ''
            done
        else
            echo '(r8.json not present in official split APKs)'
        fi
        built_r8=\$(find built-work/unpacked -name r8.json 2>/dev/null | sort | head -5 || true)
        if [ -n \"\$built_r8\" ]; then
            echo 'Found in built unpacked splits:'
            for f in \$built_r8; do echo \"  \$f\"; done
        else
            echo '(r8.json not present in built split APKs)'
        fi
        echo ''

        echo '=== resources.arsc (aapt2 diff) ==='
        echo 'Note: resources.arsc is excluded from the raw diff above (Google Play reserved-byte issue).'
        echo 'Semantic comparison via aapt2 diff (this is authoritative for resources):'
        echo ''
        found_arsc=0
        for apk in official-work/normalized-names/*.apk; do
            [ -f \"\$apk\" ] || continue
            split_name=\$(basename \"\$apk\" .apk)
            built_apk=\"built-work/normalized-names/\${split_name}.apk\"
            [ -f \"\$built_apk\" ] || continue
            unzip -l \"\$apk\" resources.arsc >/dev/null 2>&1 || continue
            found_arsc=1
            echo \"--- \${split_name}.apk ---\"
            arsc_diff=\$(\"\${AAPT2}\" diff \"\$apk\" \"\$built_apk\" 2>&1 || true)
            if [ -z \"\$arsc_diff\" ]; then
                echo '(identical)'
            else
                echo \"\$arsc_diff\"
            fi
            echo ''
        done
        [ \"\$found_arsc\" -eq 0 ] && echo '(no APKs with resources.arsc found)'
        } > '${report_file}' 2>&1
        chmod -R a+rwX comparison 2>/dev/null || true
    " || true
}

run_bitkey_compare() {
    local image="$1"
    local lhs="official-work"
    local rhs="built-work"

    mkdir -p "$(comparison_dir)"
    COMPARE_LOG_FILE="$(comparison_dir)/compare-apks-new.txt"
    set +e
    container_exec "${image}" "
        set -euo pipefail
        export AAPT2='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/aapt2'
        /build/app/verifiable-build/android/verification/steps/compare-apks-new '${lhs}' '${rhs}'
    " > "${COMPARE_LOG_FILE}" 2>&1
    COMPARE_STATUS=$?
    set -e
}

generate_dex_diff_log() {
    local image="$1"
    local dex_log_rel="comparison/diff-classes-dex.txt"
    mkdir -p "$(comparison_dir)"
    container_exec "${image}" "
        set -euo pipefail
        dexdump_bin='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/dexdump'
        official_dex='official-work/comparable/base/classes.dex'
        built_dex='built-work/comparable/base/classes.dex'
        {
        echo '=== classes.dex diff ==='
        if [ ! -f \"\$official_dex\" ] || [ ! -f \"\$built_dex\" ]; then
            echo '(classes.dex not found in one or both comparable/base dirs)'
        elif cmp -s \"\$official_dex\" \"\$built_dex\"; then
            echo '(identical)'
        else
            echo 'SHA256:'
            echo \"  official: \$(sha256sum \"\$official_dex\" | awk '{print \$1}')\"
            echo \"  built:    \$(sha256sum \"\$built_dex\"    | awk '{print \$1}')\"
            echo ''
            if [ -x \"\$dexdump_bin\" ]; then
                echo 'dexdump -f header diff (checksum, class/method/field counts):'
                \"\$dexdump_bin\" -f \"\$official_dex\" > /tmp/ws_dex_official_hdr.txt 2>/dev/null || true
                \"\$dexdump_bin\" -f \"\$built_dex\"    > /tmp/ws_dex_built_hdr.txt    2>/dev/null || true
                diff /tmp/ws_dex_official_hdr.txt /tmp/ws_dex_built_hdr.txt || true
            else
                echo '(dexdump not available)'
            fi
        fi
        } > '${dex_log_rel}' 2>&1
        chmod -R a+rwX comparison 2>/dev/null || true
    " || true
}

run_single_apk_compare() {
    local image="$1"
    local official_rel="${SINGLE_APK_PATH#"${WORK_DIR}/"}"
    local built_rel="outputs/app-emergency.apk"
    local built_apk_abs
    built_apk_abs="$(outputs_dir)/app-emergency.apk"

    mkdir -p "$(comparison_dir)"

    if [[ -f "${built_apk_abs}" ]]; then
        BUILT_APK_HASH="$(sha256sum "${built_apk_abs}" | awk '{print $1}')"
        BUILT_APK_SIZE="$(stat -c '%s' "${built_apk_abs}" 2>/dev/null || echo unknown)"
    else
        BUILT_APK_HASH="unknown"
        BUILT_APK_SIZE="unknown"
    fi

    COMPARE_LOG_FILE="$(comparison_dir)/compare-single-apk.txt"

    container_exec "${image}" "
        set -euo pipefail
        rm -rf single-compare
        mkdir -p single-compare/official-raw single-compare/built-raw single-compare/official-filtered single-compare/built-filtered
        unzip -qq '${official_rel}' -d single-compare/official-raw
        unzip -qq outputs/app-emergency.apk -d single-compare/built-raw
        cp -a single-compare/official-raw/. single-compare/official-filtered/
        cp -a single-compare/built-raw/. single-compare/built-filtered/
        diff -qr single-compare/official-raw single-compare/built-raw > comparison/diff-unzipped-apks.txt 2>&1 || true
        for dir in single-compare/official-filtered single-compare/built-filtered; do
            find \"\$dir/META-INF\" -name '*.RSA' -delete 2>/dev/null || true
            find \"\$dir/META-INF\" -name '*.SF'  -delete 2>/dev/null || true
            rm -f \"\$dir/META-INF/MANIFEST.MF\" \"\$dir/stamp-cert-sha256\"
        done
        chmod -R a+rwX single-compare 2>/dev/null || true
        chmod -R a+rwX comparison 2>/dev/null || true
    "

    set +e
    container_exec "${image}" "
        set -euo pipefail
        export AAPT2='/opt/android-sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/aapt2'
        overall=0

        : > comparison/compare-single-apk.txt
        diff -qr single-compare/official-filtered single-compare/built-filtered \
          >> comparison/compare-single-apk.txt 2>&1 || overall=1

        # aapt2 diff expects APK/ZIP inputs here, not raw resources.arsc files.
        if [ -f '${official_rel}' ] && [ -f '${built_rel}' ]; then
            if ! \"\${AAPT2}\" diff '${official_rel}' '${built_rel}' \
              >> comparison/compare-single-apk.txt 2>&1; then
                overall=1
            fi
        fi

        chmod -R a+rwX comparison 2>/dev/null || true
        exit \$overall
    "
    COMPARE_STATUS=$?
    set -e
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            require_arg --version "${2:-}"
            VERSION="${2#app/}"
            VERSION="${VERSION%% (*}"
            shift 2
            ;;
        --arch)
            require_arg --arch "${2:-}"
            ARCH="${2}"
            shift 2
            ;;
        --type)
            require_arg --type "${2:-}"
            TYPE="${2}"
            shift 2
            ;;
        --apk|--binary)
            require_arg "$1" "${2:-}"
            APK_INPUT="${2}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_warn "Unknown parameter ignored: $1"
            shift
            ;;
    esac
done

if [[ -z "${APK_INPUT}" ]]; then
    log_fail "--binary <file|dir|zip> is required."
    emit_failure_and_exit "--binary <file|dir|zip> is required." "${EXIT_INVALID}"
fi

APK_INPUT="$(realpath "${APK_INPUT}")"
mkdir -p "${LOG_DIR}"
exec 5>&1 6>&2

# --- PHASE 1: PRE-FLIGHT ---
exec > >(tee "${LOG_DIR}/phase1-preflight.log" >&5) 2>&1
phase_header 1 "PRE-FLIGHT"
detect_container_runtime
fast_apk_pre_check "${APK_INPUT}"

WORK_DIR_INITIAL="$(work_dir_for "${VERSION:-autoversion}" "${ARCH:-auto}")"
WORK_DIR="${WORK_DIR_INITIAL}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "$(comparison_dir)" "$(outputs_dir)"
log_info "Workspace: ${WORK_DIR}"
exec 1>&5 2>&6

# --- PHASE 2: RESOLVE ---
exec > >(tee "${LOG_DIR}/phase2-resolve.log" >&5) 2>&1
phase_header 2 "RESOLVE"
if [[ -z "${VERSION}" ]]; then
    log_info "Version not provided. Detecting from --binary input (host aapt2 or WS container)."
    detect_version_from_binary
    ensure_work_dir_named_for_version "${VERSION}" "${ARCH:-auto}"
    log_info "Workspace renamed to: ${WORK_DIR}"
fi

clone_ref_into_repo "$(build_ref_from_version "${VERSION}")" "repo-exact" "false"
# Only these two firmware submodules are required for the Android Rust build.
log_info "Initializing required firmware submodules (nanopb, memfault-firmware-sdk)..."
run_git_container "git -C 'repo-exact' submodule update --init --depth 1 \
    firmware/third-party/nanopb \
    firmware/third-party/memfault-firmware-sdk"
COMMIT_HASH="$(git_commit_hash_from_repo "repo-exact")"
collect_git_signature_info "$(build_ref_from_version "${VERSION}")"
log_info "Resolved Bitkey commit: ${COMMIT_HASH}"
exec 1>&5 2>&6

# --- PHASE 3: PREPARE ---
exec > >(tee "${LOG_DIR}/phase3-prepare.log" >&5) 2>&1
phase_header 3 "PREPARE"
EXACT_BASE_IMAGE="ws-bitkey-base-$(sanitize_path_component "${VERSION}")-$$"
build_helper_image "${EXACT_BASE_IMAGE}" "$(repo_exact_dir)"

if [[ "${OFFICIAL_INPUTS_PREPARED}" != "true" ]]; then
    prepare_official_inputs "${EXACT_BASE_IMAGE}"
fi

collect_official_metadata "${EXACT_BASE_IMAGE}"
BUILD_VARS_FILE="$(extract_reproducible_build_variables "${EXACT_BASE_IMAGE}")"

EXACT_BUILD_IMAGE="ws-bitkey-build-$(sanitize_path_component "${VERSION}")-$$"
build_final_image "${EXACT_BUILD_IMAGE}" "$(repo_exact_dir)" "${BUILD_VARS_FILE}"
exec 1>&5 2>&6

# --- PHASE 4: BUILD ---
exec > >(tee "${LOG_DIR}/phase4-build-full.log" >&5) 2>&1
phase_header 4 "BUILD"
if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
    log_info "Single APK (emergency) mode: building via assembleEmergency."
    build_bitkey_emergency_apk "${EXACT_BUILD_IMAGE}"
else
    log_info "Split APK (Play Store) mode: building via bundleCustomer."
    generate_device_spec_json "${WORK_DIR}/device-spec.json"
    download_bundletool_jar "${EXACT_BUILD_IMAGE}"
    build_bitkey_aab "${EXACT_BUILD_IMAGE}"
fi
exec 1>&5 2>&6
generate_filtered_build_log

# --- PHASE 5: COMPARE ---
exec > >(tee "${LOG_DIR}/phase5-compare.log" >&5) 2>&1
phase_header 5 "COMPARE"
if [[ "${SINGLE_APK_MODE}" == "true" ]]; then
    run_single_apk_compare "${EXACT_BUILD_IMAGE}"
else
    extract_built_split_apks "${EXACT_BUILD_IMAGE}"
    run_upstream_normalization "${EXACT_BUILD_IMAGE}"
    run_excluded_files_report "${EXACT_BUILD_IMAGE}"
    write_plain_diff_file "${EXACT_BUILD_IMAGE}"
    run_bitkey_compare "${EXACT_BUILD_IMAGE}"
    generate_dex_diff_log "${EXACT_BUILD_IMAGE}"
fi
exec 1>&5 2>&6

# --- PHASE 6: RESULTS ---
exec > >(tee "${LOG_DIR}/phase6-results.log" >&5) 2>&1
phase_header 6 "RESULTS"
if [[ "${COMPARE_STATUS}" -eq 0 ]]; then
    VERDICT="reproducible"
    NOTES="Bitkey verification reported identical builds.
  Plain diff file: $(comparison_dir)/diff-unzipped-apks.txt"
    if [[ -n "${COMPARE_LOG_FILE}" ]]; then
        NOTES="${NOTES}
  Compare log: ${COMPARE_LOG_FILE}"
    fi
    RESULT_DONE=true
    generate_comparison_yaml "${VERDICT}" "${NOTES}"
    print_results_block "reproducible"
    log_pass "Bitkey verification completed successfully."
    print_exit_code "${EXIT_SUCCESS}"
    exec 1>&5 2>&6
    exit "${EXIT_SUCCESS}"
fi

VERDICT="not_reproducible"
NOTES="Differences found during Bitkey verification.
  Plain diff file: $(comparison_dir)/diff-unzipped-apks.txt"
if [[ -n "${COMPARE_LOG_FILE}" ]]; then
    NOTES="${NOTES}
  Compare log: ${COMPARE_LOG_FILE}"
fi
if [[ -f "$(comparison_dir)/diff-classes-dex.txt" ]]; then
    NOTES="${NOTES}
  classes.dex diff: $(comparison_dir)/diff-classes-dex.txt"
fi
RESULT_DONE=true
generate_comparison_yaml "${VERDICT}" "${NOTES}"
print_results_block "differences found"
log_warn "Bitkey verification found differences."
print_exit_code "${EXIT_FAILED}"
exec 1>&5 2>&6
exit "${EXIT_FAILED}"
