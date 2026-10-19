#!/bin/bash
set -euo pipefail
EXEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"
readonly SCRIPT_VERSION="v0.3.6"
readonly SCRIPT_NAME="bitkit_build.sh"
readonly APP_ID="to.bitkit"
readonly REPO_URL="https://github.com/synonymdev/bitkit-android.git"
readonly BUILD_IMAGE="bitkitwallet_build_env:3"
readonly BUNDLETOOL_VERSION="1.17.2"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2
VERSION=""            # version string, e.g. "2.1.1"
ARCH=""               # ABI string, e.g. "arm64-v8a"
TYPE=""               # accepted silently for ABS compatibility, unused
APK_INPUT=""          # path to user-supplied official split APK, directory, or zip
INPUT_IS_DIR=false    # true when --binary points to a directory
INPUT_IS_ZIP=false    # true when --binary points to a .zip (WalletScrutiny Blossom upload)
INPUT_IS_TAR=false    # true when --binary points to a .tar.gz/.tar (WalletScrutiny Blossom upload)
WORK_DIR=""           # ${EXEC_DIR}/workdir_to.bitkit_<version>_<arch>
CONTAINER_CMD=""      # "podman" or "docker"
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
github_token=""       # GitHub PAT with read:packages scope
should_cleanup=false
VERSION_SAFE=""       # VERSION with characters safe for directory names
ARCH_SAFE=""          # ARCH with hyphens replaced by underscores
OFFICIAL_APK=""       # canonical path of the primary input APK in WORK_DIR
OFFICIAL_BASE_APK=""  # path to base.apk for metadata (versionName, versionCode)
BUILT_AAB=""          # path to the AAB produced by bundleMainnetRelease
GIT_TAG=""            # resolved git tag, e.g. "v2.1.1"
RESULT_DONE=false     # set true after COMPARISON_RESULTS.yaml is written
TOTAL_DIFFS=1         # default to "failed" until extract_and_compare() runs cleanly
log_info()  { echo "[INFO] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_fail()  { echo "[FAIL] $*"; }
log_warn()  { echo "[WARNING] $*"; }
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
write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "${content}" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "${content}" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
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
    if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" && -n "${WORK_DIR:-}" ]]; then
        log_warn "Script failed with exit code: ${exit_code}"
        log_warn "Work directory preserved: ${WORK_DIR}"
        generate_error_yaml "ftbfs" || true
    fi
}
trap 'on_error $LINENO' ERR
trap 'cleanup_on_error'  EXIT
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
container_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${BUILD_IMAGE}" \
        bash -c "${cmd}"
}
container_sha256() {
    local file_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "${file_path}"):/data${VOLUME_RO}" \
        "${BUILD_IMAGE}" \
        bash -c "sha256sum /data/$(basename "${file_path}") | awk '{print \$1}'"
}
container_signer() {
    local apk_path="$1"
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "${apk_path}"):/apk${VOLUME_RO}" \
        "${BUILD_IMAGE}" \
        bash -c "apksigner verify --print-certs /apk/$(basename "${apk_path}") 2>/dev/null \
                 | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}
container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm \
        -v "${apk_dir}:/apk${VOLUME_RO}" \
        -e "APK_NAME=${apk_name}" \
        -e "FIELD=${field}" \
        "${BUILD_IMAGE}" \
        bash -c '
            out="$(aapt dump badging "/apk/${APK_NAME}" 2>/dev/null \
                || aapt2 dump badging "/apk/${APK_NAME}" 2>/dev/null \
                || true)"
            if [ -n "$out" ]; then
                result="$(printf "%s\n" "$out" \
                    | sed -n "s/.*${FIELD}='"'"'\([^'"'"']*\)'"'"'.*/\1/p" \
                    | head -n1)"
                if [ -n "$result" ]; then
                    printf "%s\n" "$result"
                    exit 0
                fi
            fi
            tmpdir="$(mktemp -d)"
            if apktool d -f -s -o "${tmpdir}/out" "/apk/${APK_NAME}" >/dev/null 2>&1; then
                case "${FIELD}" in
                    versionName)
                        sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" \
                            "${tmpdir}/out/apktool.yml" | head -n1 ;;
                    versionCode)
                        sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" \
                            "${tmpdir}/out/apktool.yml" | head -n1 ;;
                esac
            fi
            rm -rf "${tmpdir}"
        ' 2>/dev/null || true
}
canonicalize_split_apk_name() {
    local apk_name="$1"
    case "${apk_name}" in
        base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
        split_config.*.apk) echo "${apk_name}" ;;
        base-*.apk) echo "split_config.${apk_name#base-}" ;;
        *) echo "${apk_name}" ;;
    esac
}
resolve_built_split_apk() {
    local official_apk="$1"
    local built_dir="$2"
    local official_name canonical_name
    official_name="$(basename "${official_apk}")"
    if [[ -f "${built_dir}/${official_name}" ]]; then
        echo "${built_dir}/${official_name}"
        return 0
    fi
    canonical_name="$(canonicalize_split_apk_name "${official_name}")"
    if [[ -f "${built_dir}/${canonical_name}" ]]; then
        echo "${built_dir}/${canonical_name}"
        return 0
    fi
    return 1
}
find_official_base_apk() {
    local dir="${WORK_DIR}/official-split-apks"
    if [[ -f "${dir}/base.apk" ]]; then
        echo "${dir}/base.apk"
        return
    fi
    if [[ -f "${dir}/base-master.apk" ]]; then
        echo "${dir}/base-master.apk"
        return
    fi
    local matches=("${dir}"/base*.apk)
    if [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]]; then
        echo "${matches[0]}"
        return
    fi
}
create_device_spec() {
    local output_path="$1"
    local arch="$2"
    cat > "${output_path}" <<EOF
{
  "supportedAbis": ["${arch}"],
  "screenDensity": 480,
  "sdkVersion": 36,
  "supportedLocales": ["en"]
}
EOF
    log_info "device-spec.json created (arch=${arch}, screenDensity=480, sdkVersion=36, supportedLocales=[en])"
}
extract_split_apks_from_aab() {
    local aab_path="$1"
    local device_spec_path="$2"
    local output_dir="$3"
    mkdir -p "${output_dir}"
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
        "${BUILD_IMAGE}" \
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
    local splits_subdir="${output_dir}/splits"
    if [[ -f "${splits_subdir}/base-master.apk" ]]; then
        mv "${splits_subdir}/base-master.apk" "${splits_subdir}/base.apk"
        log_info "Renamed base-master.apk -> base.apk"
    fi
    while IFS= read -r split_apk; do
        [[ -f "${split_apk}" ]] || continue
        local split_name suffix
        split_name="$(basename "${split_apk}")"
        [[ "${split_name}" == "base-master.apk" ]] && continue
        suffix="${split_name#base-}"
        mv "${split_apk}" "${splits_subdir}/split_config.${suffix}"
        log_info "Renamed ${split_name} -> split_config.${suffix}"
    done < <(find "${splits_subdir}" -maxdepth 1 -name "base-*.apk" 2>/dev/null || true)
    local split_count
    split_count="$(find "${output_dir}" -name "*.apk" 2>/dev/null | wc -l)"
    log_info "Extracted ${split_count} split APK(s) to ${output_dir}"
    log_info "Available splits:"
    find "${output_dir}" -name "*.apk" 2>/dev/null | while IFS= read -r f; do
        echo "  $(basename "${f}")"
    done
}
unzip_apk_in_container() {
    local apk_path="$1"
    local out_dir="$2"
    local apk_rel out_rel
    apk_rel="${apk_path#"${WORK_DIR}/"}"
    out_rel="${out_dir#"${WORK_DIR}/"}"
    container_exec "mkdir -p '${out_rel}' && \
        unzip -qq '${apk_rel}' -d '${out_rel}' 2>/dev/null || true && \
        chmod -R a+rwX '${out_rel}' 2>/dev/null || true"
}
compare_apks() {
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
    container_exec "diff -r '${official_rel}' '${built_rel}' \
        > '${diff_rel}' 2>&1 || true"
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true
    local total_lines=0
    local non_meta_count=0
    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        non_meta_count="$(grep -E '^Only in |^Files |^Binary files ' "${diff_file}" \
            | grep -cvE \
              '^Only in [^:]+: META-INF$|^Only in [^:]+/META-INF:|^Files [^:]+/META-INF/|^Binary files [^/]+/META-INF/|^Only in [^:]+: stamp-cert-sha256$|AndroidManifest\.xml|resources\.arsc' \
            || true)"
        non_meta_count="${non_meta_count:-0}"
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
    decode_and_diff_binaries "${official_apk}" "${built_apk}" "${split_label}" "${diff_file}"
    local _decoded
    for _decoded in \
        "${results_dir}/diff_manifest_${split_label}.txt" \
        "${results_dir}/diff_resources_${split_label}.txt"; do
        [[ -f "${_decoded}" ]] || continue
        if [[ -s "${_decoded}" ]] && ! grep -q "Decoded output identical" "${_decoded}" 2>/dev/null; then
            TOTAL_DIFFS=$(( TOTAL_DIFFS + 1 ))
        fi
    done
}
decode_and_diff_binaries() {
    local official_apk="$1"
    local built_apk="$2"
    local split_label="$3"
    local main_diff_file="$4"
    local results_dir="${WORK_DIR}/comparison"
    local has_manifest=0 has_resources=0
    grep -q 'Binary files.*AndroidManifest\.xml.*differ' "${main_diff_file}" 2>/dev/null \
        && has_manifest=1 || true
    grep -q 'Binary files.*resources\.arsc.*differ' "${main_diff_file}" 2>/dev/null \
        && has_resources=1 || true
    if [[ "${has_manifest}" -eq 0 && "${has_resources}" -eq 0 ]]; then
        return 0
    fi
    log_info "  Decoding binary files for deeper diff (${split_label})..."
    local official_rel built_rel results_rel
    official_rel="${official_apk#"${WORK_DIR}/"}"
    built_rel="${built_apk#"${WORK_DIR}/"}"
    results_rel="${results_dir#"${WORK_DIR}/"}"
    local decode_cmds=""
    if [[ "${has_manifest}" -eq 1 ]]; then
        local mf_rel="${results_rel}/diff_manifest_${split_label}.txt"
        decode_cmds+="
        aapt dump xmltree '${official_rel}' AndroidManifest.xml > /tmp/o_mf.txt 2>/dev/null || true
        aapt dump xmltree '${built_rel}' AndroidManifest.xml > /tmp/b_mf.txt 2>/dev/null || true
        diff /tmp/o_mf.txt /tmp/b_mf.txt > '${mf_rel}' || true"
    fi
    if [[ "${has_resources}" -eq 1 ]]; then
        local rs_rel="${results_rel}/diff_resources_${split_label}.txt"
        decode_cmds+="
        aapt dump resources '${official_rel}' > /tmp/o_rs.txt 2>/dev/null || true
        aapt dump resources '${built_rel}' > /tmp/b_rs.txt 2>/dev/null || true
        diff /tmp/o_rs.txt /tmp/b_rs.txt > '${rs_rel}' || true"
    fi
    container_exec "${decode_cmds}"
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true
    for _f in "${results_dir}/diff_manifest_${split_label}.txt" \
              "${results_dir}/diff_resources_${split_label}.txt"; do
        if [[ -f "${_f}" && ! -s "${_f}" ]]; then
            echo "# Decoded output identical — binary diff is signing-related (no semantic change)" \
                > "${_f}" 2>/dev/null || true
        fi
    done
    for decoded_diff in \
        "${results_dir}/diff_manifest_${split_label}.txt" \
        "${results_dir}/diff_resources_${split_label}.txt"; do
        [[ -f "${decoded_diff}" ]] || continue
        local dlabel dlines
        dlabel="$(basename "${decoded_diff}" .txt)"
        if [[ -s "${decoded_diff}" ]]; then
            dlines="$(wc -l < "${decoded_diff}")"
            log_info "  ${dlabel} (${dlines} lines — full: ${decoded_diff}):"
            head -5 "${decoded_diff}" | while IFS= read -r line; do echo "    ${line}"; done
            if [[ "${dlines}" -gt 5 ]]; then
                log_info "    ... (${dlines} total lines)"
            fi
        else
            log_pass "  ${dlabel}: no differences after decoding"
        fi
    done
}
print_split_comparison_block() {
    local results_dir="${WORK_DIR}/comparison"
    echo "==== Split by Split Comparison ===="
    local any_non_sig=""
    while IFS= read -r diff_file; do
        local bn; bn="$(basename "${diff_file}" .txt)"
        [[ "${bn}" == diff_manifest_* || "${bn}" == diff_resources_* ]] && continue
        local split_label="${bn#diff_}"
        local prefix_o="comparison/official_${split_label}"
        local prefix_b="comparison/built_${split_label}"
        echo ""
        echo "  ${split_label}.apk | ${split_label}.apk"
        echo "  diffs:"
        if [[ ! -s "${diff_file}" ]]; then
            echo "    (none)"
            continue
        fi
        local split_non_sig=false
        while IFS= read -r line; do
            local fname="" side="" tag=""
            if [[ "${line}" =~ ^Binary\ files\ ${prefix_o}/(.+)\ and\ ${prefix_b}/.+\ differ$ ]]; then
                fname="${BASH_REMATCH[1]}"
            elif [[ "${line}" =~ ^Files\ ${prefix_o}/(.+)\ and\ ${prefix_b}/.+\ differ$ ]]; then
                fname="${BASH_REMATCH[1]}"
            elif [[ "${line}" =~ ^Only\ in\ ${prefix_o}/(.+):\ (.+)$ ]]; then
                fname="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; side=" (official only)"
            elif [[ "${line}" =~ ^Only\ in\ ${prefix_o}:\ (.+)$ ]]; then
                fname="${BASH_REMATCH[1]}"; side=" (official only)"
            elif [[ "${line}" =~ ^Only\ in\ ${prefix_b}/(.+):\ (.+)$ ]]; then
                fname="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; side=" (built only)"
            elif [[ "${line}" =~ ^Only\ in\ ${prefix_b}:\ (.+)$ ]]; then
                fname="${BASH_REMATCH[1]}"; side=" (built only)"
            else
                continue
            fi
            if [[ "${fname}" == META-INF || "${fname}" == META-INF/* ]]; then
                tag=" [signing]"
            elif [[ "${fname}" == "stamp-cert-sha256" ]]; then
                tag=" [signing]"
            elif [[ "${fname}" == "AndroidManifest.xml" ]]; then
                local dm="${results_dir}/diff_manifest_${split_label}.txt"
                if [[ -f "${dm}" ]] && grep -q "Decoded output identical" "${dm}" 2>/dev/null; then
                    tag=" [decoded: identical — signing only]"
                else
                    tag=" [decoded: see diff_manifest_${split_label}.txt]"
                fi
            elif [[ "${fname}" == "resources.arsc" ]]; then
                local dr="${results_dir}/diff_resources_${split_label}.txt"
                if [[ -f "${dr}" ]] && grep -q "Decoded output identical" "${dr}" 2>/dev/null; then
                    tag=" [decoded: identical — signing only]"
                else
                    tag=" [decoded: see diff_resources_${split_label}.txt]"
                fi
            else
                tag=" *** NON-SIGNATURE ***"
                split_non_sig=true
            fi
            echo "    - ${fname}${side}${tag}"
        done < "${diff_file}"
        if [[ "${split_non_sig}" == "true" ]]; then
            echo "  *** Split has non-signature differences"
            any_non_sig="${any_non_sig} ${split_label}"
        fi
    done < <(find "${results_dir}" -maxdepth 1 -name "diff_*.txt" 2>/dev/null | sort)
    echo ""
    echo "  Analysis:"
    if [[ -n "${any_non_sig}" ]]; then
        for s in ${any_non_sig}; do
            echo "    ${s}: non-signature diffs → NOT REPRODUCIBLE"
        done
    else
        echo "    All diffs are signing/Play Store artifacts → REPRODUCIBLE"
    fi
    echo "===="
}
print_results_block() {
    local verdict="$1"
    local results_dir="${WORK_DIR}/comparison"
    local meta_apk="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}"
    local version_name version_code signer app_hash commit tag_info
    version_name="$(container_aapt_version "${meta_apk}" "versionName" || true)"
    version_code="$(container_aapt_version "${meta_apk}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_APK}" || true)"
    app_hash="$(container_sha256 "${OFFICIAL_APK}" || true)"
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
    print_split_comparison_block
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
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <file|dir|.tar.gz|.zip> [--version V] [--arch A] [--github-token T] [--cleanup]
  --binary   Split APK set (single APK, directory, .tar.gz, or .zip). Alias: --apk
  --version  Bitkit version (e.g. 2.1.2). Auto-detected from base.apk if omitted.
  --arch     Target ABI for device-spec.json (default: arm64-v8a).
  --type     Accepted for ABS compatibility; unused.
  --github-token  GitHub PAT with read:packages scope (or GITHUB_TOKEN env var).
  --cleanup  Remove work directory after run.
  Requires: podman or docker. Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid
EOF
}
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)
                VERSION="${2:-}"; shift ;;
            --apk|--binary)
                APK_INPUT="${2:-}"; shift ;;
            --arch)
                ARCH="${2:-}"; shift ;;
            --type)
                TYPE="${2:-}"; shift
                log_warn "--type '${TYPE:-}' accepted but unused (not applicable to Bitkit Android)" ;;
            --cleanup)
                should_cleanup=true ;;
            --github-token)
                github_token="${2:-}"; shift ;;
            --script-version)
                echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
                echo "Exit code: ${EXIT_SUCCESS}"
                exit "${EXIT_SUCCESS}" ;;
            --help|-h)
                usage
                echo "Exit code: ${EXIT_SUCCESS}"
                exit "${EXIT_SUCCESS}" ;;
            *)
                log_warn "Ignoring unknown argument: $1" ;;
        esac
        [[ "$#" -gt 0 ]] && shift
    done
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Do not run this script as root."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi
    if [[ -z "${github_token}" && -n "${GITHUB_TOKEN:-}" ]]; then
        github_token="${GITHUB_TOKEN}"
    fi
    if [[ -z "${APK_INPUT}" ]]; then
        echo "[ERROR] --binary <file|dir> is required."
        echo "        Single file: compare only that split APK."
        echo "        Directory:   compare all *.apk files in that directory."
        echo "        Example:"
        echo "          ${SCRIPT_NAME} --binary /path/to/splits/"
        echo "          ${SCRIPT_NAME} --binary /path/to/splits/base.apk"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi
    if [[ "${APK_INPUT}" != /* ]]; then
        APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
    fi
    if [[ -d "${APK_INPUT}" ]]; then
        INPUT_IS_DIR=true
        log_info "--binary is a directory; all *.apk files will be compared."
    elif [[ -f "${APK_INPUT}" ]]; then
        local _magic
        _magic="$(od -An -N2 -tx1 "${APK_INPUT}" 2>/dev/null | tr -d ' \n')"
        if [[ "${_magic}" == "1f8b" ]]; then
            INPUT_IS_TAR=true
            log_info "--binary is a gzip/tar archive (magic bytes); will extract APKs before comparison."
        elif [[ "${APK_INPUT}" == *.zip ]]; then
            INPUT_IS_ZIP=true
            log_info "--binary is a zip; will extract APKs before comparison."
        elif [[ "${APK_INPUT}" == *.tar.gz || "${APK_INPUT}" == *.tgz || "${APK_INPUT}" == *.tar ]]; then
            INPUT_IS_TAR=true
            log_info "--binary is a tar archive; will extract APKs before comparison."
        else
            INPUT_IS_DIR=false
        fi
    else
        echo "[ERROR] --binary path not found: ${APK_INPUT}"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi
    ARCH="${ARCH:-arm64-v8a}"
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64) ;;
        *)
            log_warn "Unrecognized arch '${ARCH}'; defaulting to arm64-v8a"
            ARCH="arm64-v8a"
            ;;
    esac
    if [[ -z "${github_token}" ]]; then
        cat > "${EXEC_DIR}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  GitHub token not provided. Bitkit depends on three native library AARs
  (com.synonym:bitkit-core-android, com.synonym:ldk-node-android,
  com.synonym:vss-client-android) hosted exclusively on GitHub Packages
  (maven.pkg.github.com). GitHub Packages requires authentication (a PAT
  with read:packages scope) even for packages from public repositories.
  Pass --github-token <PAT> or set the GITHUB_TOKEN environment variable.
EOF
        RESULT_DONE=true
        echo "[ERROR] GitHub token required for com.synonym:* GitHub Packages dependencies."
        echo "        Pass --github-token <PAT> or set GITHUB_TOKEN env var."
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi
    ARCH_SAFE="${ARCH//-/_}"
    VERSION_SAFE="${VERSION:-provided}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
    log_info "Work directory: ${WORK_DIR}"
    log_info "Arch: ${ARCH}"
    log_info "APK input: ${APK_INPUT}"
}
ensure_build_image() {
    if ${CONTAINER_CMD} image inspect "${BUILD_IMAGE}" >/dev/null 2>&1; then
        log_info "Build image ${BUILD_IMAGE} already exists, skipping build."
        return 0
    fi
    log_info "Building ${BUILD_IMAGE} from inline Dockerfile..."
    log_info "Installs: JDK 17 (Zulu), Android SDK (build-tools 36.0.0, android-36), bundletool ${BUNDLETOOL_VERSION}, apktool."
    log_info "Estimated time: 10-20 minutes depending on network speed."
    mkdir -p "${WORK_DIR}"
    local dockerfile_path="${WORK_DIR}/Dockerfile.build"
    cat > "${dockerfile_path}" <<'DOCKERFILE_END'
FROM docker.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV JAVA_HOME=/usr/lib/jvm/zulu17-ca-amd64
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        unzip \
        gnupg \
        lsb-release \
        apt-transport-https \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://repos.azul.com/azul-repo.key | gpg --dearmor \
        -o /usr/share/keyrings/azul.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/azul.gpg] https://repos.azul.com/zulu/deb stable main" \
        > /etc/apt/sources.list.d/zulu.list && \
    apt-get update -q && \
    apt-get install -y --no-install-recommends zulu17-ca-jdk && \
    rm -rf /var/lib/apt/lists/*
RUN mkdir -p "${ANDROID_HOME}" /root/.android && \
    touch /root/.android/repositories.cfg && \
    curl -fsSL \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -o /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d "${ANDROID_HOME}" && \
    rm -f /tmp/sdk.zip
ENV PATH="${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/35.0.0:${ANDROID_HOME}/build-tools/36.0.0:${JAVA_HOME}/bin:${PATH}"
RUN yes | "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" \
        --sdk_root="${ANDROID_HOME}" --licenses && \
    "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" \
        --sdk_root="${ANDROID_HOME}" \
        "platform-tools" \
        "platforms;android-36" \
        "build-tools;35.0.0" \
        "build-tools;36.0.0" && \
    chmod -R a+rwX "${ANDROID_HOME}"
ARG BUNDLETOOL_VERSION=1.17.2
RUN curl -fL \
        "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
        -o /usr/local/lib/bundletool.jar && \
    printf '#!/bin/sh\nexec java -jar /usr/local/lib/bundletool.jar "$@"\n' \
        > /usr/local/bin/bundletool && \
    chmod +x /usr/local/bin/bundletool
RUN curl -fsSL \
        "https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool" \
        -o /usr/local/bin/apktool && \
    curl -fsSL \
        "https://github.com/iBotPeaches/Apktool/releases/download/v2.9.3/apktool_2.9.3.jar" \
        -o /usr/local/bin/apktool.jar && \
    chmod +x /usr/local/bin/apktool
CMD ["bash"]
DOCKERFILE_END
    ${CONTAINER_CMD} build \
        --no-cache \
        --tag "${BUILD_IMAGE}" \
        --file "${dockerfile_path}" \
        "${WORK_DIR}"
    log_pass "Build image ${BUILD_IMAGE} ready."
}
resolve_git_tag() {
    local version="$1"
    local candidates=("v${version}" "${version}")
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
prepare() {
    log_info "=== PREPARE PHASE ==="
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/official-split-apks"
    mkdir -p "${WORK_DIR}/built-output"
    chmod 777 "${WORK_DIR}/built-output"
    if [[ "${INPUT_IS_ZIP}" == "true" || "${INPUT_IS_TAR}" == "true" ]]; then
        local archive_extract_dir="${WORK_DIR}/archive-extracted"
        mkdir -p "${archive_extract_dir}"
        if [[ "${INPUT_IS_TAR}" == "true" ]]; then
            log_info "Extracting tar archive: $(basename "${APK_INPUT}")"
            tar -xf "${APK_INPUT}" -C "${archive_extract_dir}" 2>/dev/null || true
        else
            log_info "Extracting zip: $(basename "${APK_INPUT}")"
            unzip -qq "${APK_INPUT}" -d "${archive_extract_dir}" 2>/dev/null || true
        fi
        chmod -R a+rwX "${archive_extract_dir}" 2>/dev/null || true
        local apk_count
        apk_count="$(find "${archive_extract_dir}" -name "*.apk" 2>/dev/null | wc -l)"
        if [[ "${apk_count}" -eq 0 ]]; then
            log_fail "No APK files found inside archive: ${APK_INPUT}"
            generate_error_yaml "ftbfs" "No APK files found inside the provided archive."
            RESULT_DONE=true
            exit "${EXIT_FAILED}"
        fi
        log_info "Archive extracted. ${apk_count} APK(s) found:"
        find "${archive_extract_dir}" -name "*.apk" | sort | while IFS= read -r f; do
            echo "  $(basename "${f}")"
        done
        APK_INPUT="${archive_extract_dir}"
        INPUT_IS_DIR=true
    fi
    local canonical_name
    if [[ "${INPUT_IS_DIR}" == "true" ]]; then
        log_info "Copying all *.apk from directory: ${APK_INPUT}"
        local copy_count=0
        while IFS= read -r apk; do
            local apk_name apk_canonical
            apk_name="$(basename "${apk}")"
            apk_canonical="$(canonicalize_split_apk_name "${apk_name}")"
            cp "${apk}" "${WORK_DIR}/official-split-apks/${apk_canonical}"
            if [[ "${apk_name}" != "${apk_canonical}" ]]; then
                log_info "  Copied and normalized: ${apk_name} -> ${apk_canonical}"
            else
                log_info "  Copied: ${apk_name}"
            fi
            copy_count=$(( copy_count + 1 ))
        done < <(find "${APK_INPUT}" -maxdepth 1 -name "*.apk" 2>/dev/null || true)
        log_info "Copied ${copy_count} split APK(s) from directory."
        canonical_name="base.apk"
        OFFICIAL_APK="${WORK_DIR}/official-split-apks/base.apk"
    else
        local original_name input_dir
        original_name="$(basename "${APK_INPUT}")"
        canonical_name="$(canonicalize_split_apk_name "${original_name}")"
        input_dir="$(dirname "${APK_INPUT}")"
        cp "${APK_INPUT}" "${WORK_DIR}/official-split-apks/${canonical_name}"
        if [[ "${original_name}" != "${canonical_name}" ]]; then
            log_info "Normalized split name: ${original_name} -> ${canonical_name}"
        fi
        OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
        if [[ "${canonical_name}" != "base.apk" ]]; then
            for _candidate in "${input_dir}/base.apk" "${input_dir}/base-master.apk"; do
                if [[ -f "${_candidate}" ]]; then
                    cp "${_candidate}" "${WORK_DIR}/metadata-base.apk"
                    OFFICIAL_BASE_APK="${WORK_DIR}/metadata-base.apk"
                    log_info "Using sibling $(basename "${_candidate}") for metadata extraction."
                    break
                fi
            done
        fi
    fi
    if [[ -z "${OFFICIAL_BASE_APK:-}" ]]; then
        OFFICIAL_BASE_APK="$(find_official_base_apk || true)"
    fi
    if [[ -z "${OFFICIAL_BASE_APK:-}" ]]; then
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"
        log_warn "No base.apk found; using ${canonical_name} for metadata."
    fi
    if [[ -z "${VERSION}" ]]; then
        log_info "Auto-detecting version from APK content..."
        VERSION="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
        [[ "${VERSION}" == "null" ]] && VERSION=""
        if [[ -z "${VERSION}" ]]; then
            local _fn _stripped _ver
            _fn="$(basename "${APK_INPUT}")"
            _stripped="${_fn#${APP_ID}_}"
            if [[ "${_stripped}" != "${_fn}" ]]; then
                _ver="$(printf '%s' "${_stripped}" | cut -d'_' -f1)"
                [[ "${_ver}" =~ ^[0-9]+\.[0-9] ]] && VERSION="${_ver}"
            fi
            [[ -n "${VERSION}" ]] && log_info "Version detected from filename: ${VERSION}"
        fi
        if [[ -z "${VERSION}" ]]; then
            log_fail "Could not detect versionName from APK. Pass --version explicitly."
            generate_error_yaml "ftbfs" \
                "Could not auto-detect versionName from APK. Pass --version explicitly."
            RESULT_DONE=true
            exit "${EXIT_INVALID}"
        fi
        log_info "Version detected: ${VERSION}"
        VERSION_SAFE="${VERSION}"
        ARCH_SAFE="${ARCH//-/_}"
        local new_work_dir
        new_work_dir="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
        if [[ "${new_work_dir}" != "${WORK_DIR}" ]]; then
            rm -rf "${new_work_dir}"
            mv "${WORK_DIR}" "${new_work_dir}"
            WORK_DIR="${new_work_dir}"
            OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
            if [[ -f "${WORK_DIR}/metadata-base.apk" ]]; then
                OFFICIAL_BASE_APK="${WORK_DIR}/metadata-base.apk"
            else
                OFFICIAL_BASE_APK="$(find_official_base_apk || true)"
                if [[ -z "${OFFICIAL_BASE_APK:-}" ]]; then
                    OFFICIAL_BASE_APK="${OFFICIAL_APK}"
                fi
            fi
            log_info "Work directory updated: ${WORK_DIR}"
        fi
    fi
    VERSION_SAFE="${VERSION}"
    create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"
    log_info "Official splits copied:"
    find "${WORK_DIR}/official-split-apks" -name "*.apk" 2>/dev/null | while IFS= read -r f; do
        echo "  $(basename "${f}")"
    done
    log_pass "Preparation complete. Work directory: ${WORK_DIR}"
}
build_image() {
    log_info "=== BUILD IMAGE PHASE ==="
    ensure_build_image
}
build() {
    log_info "=== BUILD PHASE ==="
    if ! resolve_git_tag "${VERSION_SAFE}"; then
        echo ""
        echo "======================================================"
        echo "  SOURCE NOT FOUND FOR VERSION ${VERSION_SAFE}"
        echo "  Tried tags: v${VERSION_SAFE}, ${VERSION_SAFE}"
        echo "  Repository: ${REPO_URL}"
        echo "======================================================"
        echo ""
        generate_comparison_yaml "ftbfs" \
            "Tag not found for version ${VERSION_SAFE}. Tried: v${VERSION_SAFE}, ${VERSION_SAFE}. Source code for this version has not been tagged in the synonymdev/bitkit-android repository."
        RESULT_DONE=true
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi
    log_info "Git tag: ${GIT_TAG}"
    log_info "Build: bundleMainnetRelease --no-build-cache --no-configuration-cache"
    log_info "Arch target: ${ARCH}"
    log_info "Cloning + building in container. First run may take 30-60 minutes."
    log_info "NOTE: GitHub Packages downloads ~400 MB of native AARs on first run."
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-output:/workspace${VOLUME_RW}" \
        -e "HOME=/workspace" \
        -e "GRADLE_USER_HOME=/workspace/.gradle" \
        -e "ANDROID_HOME=/opt/android-sdk" \
        -e "ANDROID_SDK_ROOT=/opt/android-sdk" \
        -e "JAVA_HOME=/usr/lib/jvm/zulu17-ca-amd64" \
        -e "GITHUB_ACTOR=walletscrutiny" \
        -e "GITHUB_TOKEN=${github_token}" \
        "${BUILD_IMAGE}" \
        bash -c "set -euo pipefail
            echo '[INFO] Cloning ${REPO_URL} at tag ${GIT_TAG}...'
            git clone --branch '${GIT_TAG}' '${REPO_URL}' /workspace/app
            echo '[INFO] Clone complete.'
            cd /workspace/app
            git rev-parse HEAD > /workspace/commit.txt
            echo '[INFO] Commit: '\$(cat /workspace/commit.txt)
            tag_type=\$(git cat-file -t 'refs/tags/${GIT_TAG}' 2>/dev/null || echo 'missing')
            printf 'TAG_TYPE=%s\n' \"\${tag_type}\" > /workspace/tag_verify.txt
            if [ \"\${tag_type}\" = 'tag' ]; then
                echo '[INFO] Annotated tag detected; attempting GPG verify...'
                git tag -v '${GIT_TAG}' >> /workspace/tag_verify.txt 2>&1 || \
                    printf 'GPG verify skipped (no public key in container)\n' >> /workspace/tag_verify.txt
            elif [ \"\${tag_type}\" = 'commit' ]; then
                printf 'LIGHTWEIGHT_TAG (no GPG object attached)\n' >> /workspace/tag_verify.txt
            else
                printf 'NO_TAG_OBJECT found\n' >> /workspace/tag_verify.txt
            fi
            mkdir -p /workspace/app/app/src/mainnetRelease
            cat > /workspace/app/app/src/mainnetRelease/google-services.json <<'GSEOF'
{
  \"project_info\": {
    \"project_number\": \"783092706332\",
    \"project_id\": \"bitkit-prod\",
    \"storage_bucket\": \"bitkit-prod.firebasestorage.app\"
  },
  \"client\": [
    {
      \"client_info\": {
        \"mobilesdk_app_id\": \"1:783092706332:android:1bc9125e3a0db5d3b703d9\",
        \"android_client_info\": {
          \"package_name\": \"to.bitkit\"
        }
      },
      \"api_key\": [
        {
          \"current_key\": \"AIzaSyDIdnCadyHRiBAwYaJHTcXh5gaK0kJbKLc\"
        }
      ],
      \"services\": {
        \"appinvite_service\": {
          \"other_platform_oauth_client\": []
        }
      }
    }
  ],
  \"configuration_version\": \"1\"
}
GSEOF
            echo '[INFO] google-services.json written for mainnetRelease flavor.'
            mkdir -p /workspace/.gradle
            printf 'gpr.user=walletscrutiny\ngpr.key=%s\n' \"\${GITHUB_TOKEN}\" \
                >> /workspace/.gradle/gradle.properties
            echo '[INFO] GitHub Packages credentials written to ~/.gradle/gradle.properties.'
            cd /workspace/app
            keytool -genkeypair \
                -keystore /workspace/debug.keystore \
                -storepass android \
                -alias androiddebugkey \
                -keypass android \
                -keyalg RSA \
                -keysize 2048 \
                -validity 10000 \
                -dname 'CN=Debug,O=Debug,C=US' \
                -noprompt 2>/dev/null
            echo '[INFO] Debug keystore generated at /workspace/debug.keystore.'
            echo '[INFO] Running bundleMainnetRelease...'
            ./gradlew bundleMainnetRelease \
                --no-build-cache \
                --no-configuration-cache \
                --gradle-user-home /workspace/.gradle \
                -Pandroid.injected.signing.store.file=/workspace/debug.keystore \
                -Pandroid.injected.signing.store.password=android \
                -Pandroid.injected.signing.key.alias=androiddebugkey \
                -Pandroid.injected.signing.key.password=android \
                2>&1
            echo '[INFO] Build complete.'
            chmod -R a+rwX /workspace 2>/dev/null || true
        "
    chmod -R a+rwX "${WORK_DIR}/built-output" 2>/dev/null || true
    local aab_path
    aab_path="$(find "${WORK_DIR}/built-output" \
        -name "*.aab" \
        -path "*/outputs/bundle/*" \
        ! -path "*/intermediates/*" \
        2>/dev/null | head -1 || true)"
    if [[ -z "${aab_path}" ]]; then
        log_fail "Built AAB not found after bundleMainnetRelease."
        log_info "All .aab files found under built-output:"
        find "${WORK_DIR}/built-output" -name "*.aab" 2>/dev/null | head -10 || true
        exit "${EXIT_FAILED}"
    fi
    BUILT_AAB="${aab_path}"
    log_pass "Built AAB: ${BUILT_AAB}"
}
extract_and_compare() {
    log_info "=== EXTRACT AND COMPARE PHASE ==="
    TOTAL_DIFFS=0
    local built_splits_dir="${WORK_DIR}/built-split-apks"
    extract_split_apks_from_aab \
        "${BUILT_AAB}" \
        "${WORK_DIR}/device-spec.json" \
        "${built_splits_dir}"
    local official_splits_dir="${WORK_DIR}/official-split-apks"
    local compared=0
    while IFS= read -r official_apk; do
        [[ -f "${official_apk}" ]] || continue
        local split_name split_label built_split
        split_name="$(basename "${official_apk}")"
        split_label="${split_name%.apk}"
        log_info "Looking for built match for: ${split_name}"
        if built_split="$(resolve_built_split_apk "${official_apk}" "${built_splits_dir}/splits")"; then
            log_info "Official split: ${split_name}"
            log_info "Built split:    $(basename "${built_split}")"
            compare_apks "${official_apk}" "${built_split}" "${split_label}"
            compared=$(( compared + 1 ))
        else
            log_warn "No matching built split for: ${split_name} — skipping comparison"
            log_info "  Canonical name tried: $(canonicalize_split_apk_name "${split_name}")"
            log_info "  Available built splits:"
            find "${built_splits_dir}" -name "*.apk" 2>/dev/null \
                | while IFS= read -r f; do echo "    $(basename "${f}")"; done
            TOTAL_DIFFS=$(( TOTAL_DIFFS + 1 ))
        fi
    done < <(find "${official_splits_dir}" -name "*.apk" 2>/dev/null | sort)
    if [[ "${compared}" -eq 0 ]]; then
        log_fail "No official splits were compared. Check official-split-apks directory."
        exit "${EXIT_FAILED}"
    fi
    log_info "Total splits compared: ${compared}"
    log_info "Total non-META-INF diffs (across all splits): ${TOTAL_DIFFS}"
}
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
    local notes
    notes="bundleMainnetRelease, JDK 17 Zulu, AGP 8.13.2, bundletool ${BUNDLETOOL_VERSION}.
  device-spec: arm64-v8a, screenDensity=480, sdkVersion=36.
  Rust AARs (bitkit-core, ldk-node, vss-client) from GitHub Packages at pinned versions.
  google-services.json injected from base.apk public values.
  Expected diffs: META-INF (signing), stamp-cert-sha256 (Play Store)."
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
main() {
    log_info "Starting ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    log_warn "This script is provided as-is. Review before running. Use at your own risk."
    detect_container_runtime
    parse_arguments "$@"
    build_image
    prepare
    build
    extract_and_compare
    result
}
main "$@"
