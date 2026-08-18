#!/bin/bash
# bitkey_build.sh v0.2.30 — Bitkey Android Play Store split APK verification
# Organization: WalletScrutiny.com

set -euo pipefail

EXEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXEC_DIR
LOG_DIR="${EXEC_DIR}/build-logs"

readonly SCRIPT_VERSION="v0.2.30"
readonly SCRIPT_NAME="bitkey_build.sh"
readonly APP_ID="world.bitkey.app"
readonly REPO_URL="https://github.com/proto-at-block/bitkey.git"
readonly DEFAULT_REF="main"
readonly BUNDLETOOL_VERSION="1.15.6"
readonly ANDROID_BUILD_TOOLS_VERSION="35.0.0"
# Ubuntu archive snapshot near Bitkey's release date — restores the exact pinned
# .debs after the live mirror retires them (keeps compiler/JDK pins faithful). Bump per release.
readonly UBUNTU_SNAPSHOT="20260701T000000Z"
readonly HELPER_GIT_IMAGE="docker.io/alpine/git:2.47.2"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"

readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2


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
EXACT_BASE_IMAGE=""
EXACT_BUILD_IMAGE=""
RESULT_DONE=false
OFFICIAL_INPUTS_PREPARED=false
COMPARE_LOG_FILE=""
OFFICIAL_VERSION_NAME=""
OFFICIAL_VERSION_CODE=""
OFFICIAL_SDK_VERSION=""
OFFICIAL_SIGNER="unknown"
OFFICIAL_HASH=""
OFFICIAL_APK_SIZE=""
COMMIT_HASH=""
GENERATED_ARCH=""
COMPARE_STATUS=1

log_info()  { echo "[INFO] $*" >&2; }
log_pass()  { echo "[PASS] $*" >&2; }
log_fail()  { echo "[FAIL] $*" >&2; }
log_warn()  { echo "[WARNING] $*" >&2; }

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
Usage: ${SCRIPT_NAME} --binary <dir|apks|zip|tar.gz> [--version <ver>] [--arch <arch>]
  --binary   Split APK set (directory, .apks, .zip, .tar.gz). Alias: --apk
  --version  Bitkey version (e.g. 2026.2.1). Auto-detected from APK if omitted.
  --arch     Override supportedAbis in device-spec.json (e.g. arm64-v8a).
  --type     Accepted for ABS compatibility; unused.
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

assert_package_name() {
    local image="$1"
    local apk_path
    apk_path="$(official_base_apk 2>/dev/null || true)"
    [[ -z "${apk_path}" ]] && return 0
    local apk_rel="${apk_path#"${WORK_DIR}/"}"
    local pkg
    pkg="$(extract_apk_field "${image}" "${apk_rel}" packageName)"
    if [[ -n "${pkg}" && "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package name mismatch: expected ${APP_ID}, got ${pkg}"
        emit_failure_and_exit "Package name mismatch: expected ${APP_ID}, got ${pkg}. Wrong APK provided." "${EXIT_INVALID}"
    fi
    log_info "Package name verified: ${pkg}"
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
    ${CONTAINER_CMD} run --rm \
        --platform=linux/amd64 \
        --memory=32g \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${image}" \
        "${cmd}"
}

patch_bitkey_dockerfile() {
    local src="$1"
    local dst="$2"
    # Repoint apt at the Ubuntu snapshot (exact pinned .debs keep the output-affecting pins
    # faithful) + relax only utility pins git/curl/unzip/zip. ca-certificates is bootstrapped
    # from the default mirror first so the snapshot HTTPS handshake works on the minimal image.
    awk -v snap="${UBUNTU_SNAPSHOT}" '
        /^RUN apt update$/ {
            base = "https://snapshot.ubuntu.com/ubuntu/" snap
            print "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \\"
            print " && rm -f /etc/apt/sources.list \\"
            print " && echo '\''deb [check-valid-until=no] " base " jammy main restricted universe multiverse'\'' >> /etc/apt/sources.list \\"
            print " && echo '\''deb [check-valid-until=no] " base " jammy-updates main restricted universe multiverse'\'' >> /etc/apt/sources.list \\"
            print " && echo '\''deb [check-valid-until=no] " base " jammy-security main restricted universe multiverse'\'' >> /etc/apt/sources.list"
        }
        {
            gsub(/curl=7\.81\.0-1ubuntu1\.[0-9]+/, "curl")
            gsub(/git=1:2\.34\.1-1ubuntu1\.[0-9]+/, "git")
            gsub(/unzip=6\.0-26ubuntu3\.[0-9]+/, "unzip")
            gsub(/zip=3\.0-12build2/, "zip")
            print
        }
    ' "${src}" > "${dst}"
}

build_bitkey_image() {
    local image="$1" repo_dir="$2" target="$3" build_vars_file="${4:-}"
    local patched_df
    local extra=()
    if [[ -n "${build_vars_file}" ]]; then
        extra=(--build-arg "REPRODUCIBLE_BUILD_VARIABLES=$(tr -d '\n' < "${build_vars_file}")")
    fi
    patched_df="$(mktemp --suffix=.Dockerfile)"
    patch_bitkey_dockerfile "${repo_dir}/app/verifiable-build/android/Dockerfile" "${patched_df}"
    log_info "Building Bitkey ${target} image: ${image}"
    ${CONTAINER_CMD} build \
        --platform=linux/amd64 \
        -f "${patched_df}" \
        -t "${image}" \
        --target "${target}" \
        ${extra[@]+"${extra[@]}"} \
        "${repo_dir}"
    rm -f "${patched_df}"
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
                    log_fail "Single .apk input is not supported. Provide a split APK set (directory, .apks, .zip, or .tar.gz)."
                    emit_failure_and_exit "Single .apk input not supported for Play Store verification." "${EXIT_INVALID}"
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
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
                case "'"${field}"'" in
                    versionName)
                        sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" \
                            "$tmpdir/out/apktool.yml" | head -n1
                        rm -rf "$tmpdir"; exit 0 ;;
                    versionCode)
                        sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" \
                            "$tmpdir/out/apktool.yml" | head -n1
                        rm -rf "$tmpdir"; exit 0 ;;
                esac
            fi
            rm -rf "$tmpdir"
        ' 2>/dev/null || true
}

python_parse_version() {
    local apk_path="$1"
    local field="$2"
    [[ "${field}" != "versionName" ]] && return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${apk_path}" <<'PYEOF'
import sys, struct, zipfile

def r16(d, o): return struct.unpack_from('<H', d, o)[0]
def r32(d, o): return struct.unpack_from('<I', d, o)[0]

def get_strings(d, sp):
    sh = r16(d, sp + 2)
    sc = r32(d, sp + 8)
    fl = r32(d, sp + 16)
    ss = r32(d, sp + 20)
    utf8 = bool(fl & 0x100)
    res = []
    for i in range(sc):
        sr = r32(d, sp + sh + i * 4)
        a = sp + ss + sr
        if utf8:
            cc = d[a]; a += 2 if cc & 0x80 else 1
            bc = d[a]
            if bc & 0x80: nb = (bc & 0x7f) << 8 | d[a + 1]; a += 2
            else: nb = bc; a += 1
            res.append(d[a:a + nb].decode('utf-8', 'replace'))
        else:
            cc = r16(d, a)
            if cc & 0x8000: nc = ((cc & 0x7fff) << 16) | r16(d, a + 2); a += 4
            else: nc = cc; a += 2
            res.append(d[a:a + nc * 2].decode('utf-16-le', 'replace'))
    return res

try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        data = z.read('AndroidManifest.xml')
    strings = get_strings(data, 8)
    pos = 8 + r32(data, 12)
    while pos < len(data) - 8:
        ct = r16(data, pos)
        cs = r32(data, pos + 4)
        if cs <= 0: break
        if ct == 0x0102:  # RES_XML_START_ELEMENT_TYPE
            ni = r32(data, pos + 20)
            ac = r16(data, pos + 28)
            ao = pos + r16(data, pos + 2)
            if ni < len(strings) and strings[ni] == 'manifest':
                for a in range(ac):
                    af = ao + a * 20
                    an = r32(data, af + 4)
                    rv = r32(data, af + 8)
                    if an < len(strings) and strings[an] == 'versionName':
                        val = ''
                        if rv != 0xFFFFFFFF and rv < len(strings):
                            val = strings[rv]
                        if not val:
                            td = r32(data, af + 16)
                            if td < len(strings): val = strings[td]
                        if val:
                            print(val)
                            sys.exit(0)
        pos += cs
    sys.exit(1)
except Exception:
    sys.exit(1)
PYEOF
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
    detected="$(container_aapt_version "${apk_path}" "${field}" || true)"
    if [[ -n "${detected}" ]]; then
        printf '%s\n' "${detected}"
        return 0
    fi
    python_parse_version "${apk_path}" "${field}" || true
}

detect_version_from_binary() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

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
        rm -rf "${tmp_dir}"
        log_fail "Could not locate base.apk in --binary input to read versionName. Verify the input is a valid Bitkey APK."
        emit_failure_and_exit "Could not find APK to detect version." "${EXIT_INVALID}"
    fi

    log_info "Detecting version from: $(basename "${base_apk}")"
    local ver
    ver="$(detect_apk_metadata_field "${base_apk}" "versionName" || true)"
    rm -rf "${tmp_dir}"
    if [[ -z "${ver}" ]]; then
        log_fail "Could not read versionName from APK. Verify the input contains a valid Bitkey base.apk."
        emit_failure_and_exit "Could not determine versionName from APK." "${EXIT_INVALID}"
    fi
    VERSION="${ver%% (*}"
    log_info "Version derived from APK metadata: ${VERSION}"
}

collect_official_metadata() {
    local image="$1"
    local apk_path
    apk_path="$(official_base_apk || true)"
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
        echo '=== resources.arsc (aapt2 diff) ==='
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
    log_fail "--binary <file|dir|zip|tar.gz> is required."
    emit_failure_and_exit "--binary <file|dir|zip|tar.gz> is required." "${EXIT_INVALID}"
fi

APK_INPUT="$(realpath "${APK_INPUT}")"
mkdir -p "${LOG_DIR}"
exec 5>&1 6>&2

exec > >(tee "${LOG_DIR}/phase1-preflight.log" >&5) 2>&1
detect_container_runtime

WORK_DIR_INITIAL="$(work_dir_for "${VERSION:-autoversion}" "${ARCH:-auto}")"
WORK_DIR="${WORK_DIR_INITIAL}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "$(comparison_dir)" "$(outputs_dir)"
log_info "Workspace: ${WORK_DIR}"
exec 1>&5 2>&6

exec > >(tee "${LOG_DIR}/phase2-resolve.log" >&5) 2>&1
if [[ -z "${VERSION}" ]]; then
    log_info "Version not provided. Detecting from --binary input (host aapt2 or WS container)."
    detect_version_from_binary
    ensure_work_dir_named_for_version "${VERSION}" "${ARCH:-auto}"
    log_info "Workspace renamed to: ${WORK_DIR}"
fi

clone_ref_into_repo "$(build_ref_from_version "${VERSION}")" "repo-exact" "false"
log_info "Initializing required firmware submodules (nanopb, memfault-firmware-sdk)..."
run_git_container "git -C 'repo-exact' submodule update --init --depth 1 \
    firmware/third-party/nanopb \
    firmware/third-party/memfault-firmware-sdk"
COMMIT_HASH="$(git_commit_hash_from_repo "repo-exact")"
log_info "Resolved Bitkey commit: ${COMMIT_HASH}"
exec 1>&5 2>&6

exec > >(tee "${LOG_DIR}/phase3-prepare.log" >&5) 2>&1
EXACT_BASE_IMAGE="ws-bitkey-base-$(sanitize_path_component "${VERSION}")-$$"
build_bitkey_image "${EXACT_BASE_IMAGE}" "$(repo_exact_dir)" base

if [[ "${OFFICIAL_INPUTS_PREPARED}" != "true" ]]; then
    prepare_official_inputs "${EXACT_BASE_IMAGE}"
fi

collect_official_metadata "${EXACT_BASE_IMAGE}"
BUILD_VARS_FILE="$(extract_reproducible_build_variables "${EXACT_BASE_IMAGE}")"

EXACT_BUILD_IMAGE="ws-bitkey-build-$(sanitize_path_component "${VERSION}")-$$"
build_bitkey_image "${EXACT_BUILD_IMAGE}" "$(repo_exact_dir)" build "${BUILD_VARS_FILE}"
exec 1>&5 2>&6

exec > >(tee "${LOG_DIR}/phase4-build-full.log" >&5) 2>&1
log_info "Building via bundleCustomer (Play Store split APKs)."
generate_device_spec_json "${WORK_DIR}/device-spec.json"
download_bundletool_jar "${EXACT_BUILD_IMAGE}"
build_bitkey_aab "${EXACT_BUILD_IMAGE}"
exec 1>&5 2>&6

exec > >(tee "${LOG_DIR}/phase5-compare.log" >&5) 2>&1
extract_built_split_apks "${EXACT_BUILD_IMAGE}"
run_upstream_normalization "${EXACT_BUILD_IMAGE}"
run_excluded_files_report "${EXACT_BUILD_IMAGE}"
write_plain_diff_file "${EXACT_BUILD_IMAGE}"
run_bitkey_compare "${EXACT_BUILD_IMAGE}"
exec 1>&5 2>&6

exec > >(tee "${LOG_DIR}/phase6-results.log" >&5) 2>&1
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
