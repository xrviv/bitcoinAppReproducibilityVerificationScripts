#!/bin/bash
# ==============================================================================
# coinspacewallet_build.sh - Coin Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:       v0.3.13
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-24
# App:           Coin Wallet Android
# App ID:        com.coinspace.app
# Project:       https://github.com/CoinSpace/CoinSpace
# ==============================================================================
# LICENSE: MIT License
# Changelog: ~/work/ws-notes/script-notes/android/com.coinspace.app/changelog.md
# Requires: --github-token (GitHub PAT with read:packages) for @coinspace/* GPR deps.
# Only prerequisite on the host: docker or podman.
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
readonly SCRIPT_VERSION="v0.3.13"
readonly SCRIPT_NAME="coinspacewallet_build.sh"
readonly APP_ID="com.coinspace.app"
readonly REPO_URL="https://github.com/CoinSpace/CoinSpace.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly COINSPACE_BUILD_IMAGE="coinspacewallet_build_env:4"
readonly BUNDLETOOL_VERSION="1.17.2"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

# ------------------------------------------------------------------------------
# Global state
# ------------------------------------------------------------------------------
VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""          # path to official split APK (file) or directory of split APKs
INPUT_IS_DIR=false    # true when --binary points to a directory
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
github_token=""
REQUESTED_TAG=""
GITHUB_RUN_NUMBER=""  # optional override; auto-computed from versionCode if not provided
should_cleanup=false

# Set during prepare/build
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""       # canonical path in WORK_DIR to the input split APK
OFFICIAL_BASE_APK=""  # path to base.apk in official-split-apks/ (for metadata)
BUILT_AAB=""          # path to the AAB produced by the build
GIT_TAG=""            # resolved git tag (e.g. "v6.24.0")
RESULT_DONE=false     # set true by result() after writing COMPARISON_RESULTS.yaml
TOTAL_DIFFS=1         # default to "failed" until compare_split_apks() runs cleanly

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
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

# Runs grep safely; returns "0" on no-match instead of failing the script.
# Used to avoid set -e killing the script when grep finds nothing.
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

# ------------------------------------------------------------------------------
# Error handling — dual trap pattern (ERR + EXIT)
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
    if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" && -n "${WORK_DIR:-}" ]]; then
        log_warn "Script failed with exit code: ${exit_code}"
        log_warn "Work directory preserved: ${WORK_DIR}"
        generate_error_yaml "ftbfs" || true
    fi
}

trap 'on_error $LINENO' ERR
trap 'cleanup_on_error'  EXIT

# ------------------------------------------------------------------------------
# Container runtime detection (prefer podman, fall back to docker)
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
container_exec() {
    local cmd="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${COINSPACE_BUILD_IMAGE}" \
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
# Split APK name helpers
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

find_official_base_apk() {
    local dir="${WORK_DIR}/official-split-apks"
    if   [[ -f "${dir}/base.apk" ]];        then echo "${dir}/base.apk"; return; fi
    if   [[ -f "${dir}/base-master.apk" ]]; then echo "${dir}/base-master.apk"; return; fi
    local matches=("${dir}"/base*.apk)
    [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]] && echo "${matches[0]}" && return
}

create_device_spec() {
    local output_path="$1"
    local arch="$2"
    cat > "${output_path}" <<EOF
{
  "supportedAbis": ["${arch}"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 36
}
EOF
    log_info "device-spec.json created (arch=${arch}, sdkVersion=36, density=480)"
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
        "${COINSPACE_BUILD_IMAGE}" \
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
# Uses the WS reference container (lighter than the build image) for this
# simple extraction task; provides unzip, chmod.
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
# META-INF filter (2025-10-30 policy). Full diff written to file; max 5 lines
# printed to terminal. Accumulates into global TOTAL_DIFFS counter.
#
# Leo's filter: only excludes root-level META-INF entries. Nested META-INF
# (e.g. inside a zip within the APK) still counts as a real difference.
# ------------------------------------------------------------------------------
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

    ws_exec "diff -r '${official_rel}' '${built_rel}' \
        > '${diff_rel}' 2>&1 || true"
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true

    local total_lines=0
    local non_meta_count=0

    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        non_meta_count="$(grep -E '^Only in |^Files ' "${diff_file}" \
            | grep -cvE \
              '^Only in [^:]+: META-INF$|^Only in [^:]+/META-INF:|^Files [^:]+/META-INF/|^Only in [^:]+: stamp-cert-sha256$' \
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
}

# ------------------------------------------------------------------------------
# Decoded diffs for known binary files: AndroidManifest.xml, resources.arsc.
# Called from compare_apks() after the main diff when either file differs.
# Uses aapt to produce human-readable text then diffs the output.
# Saves to diff_manifest_<label>.txt and diff_resources_<label>.txt.
# ------------------------------------------------------------------------------
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

    ws_exec "${decode_cmds}"
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true

    # If decoded diff is empty, the binary diff is signing-related (not semantic)
    for _f in "${results_dir}/diff_manifest_${split_label}.txt" \
              "${results_dir}/diff_resources_${split_label}.txt"; do
        if [[ -f "${_f}" && ! -s "${_f}" ]]; then
            echo "# Decoded output identical — binary diff is signing-related (no semantic change)" \
                > "${_f}" 2>/dev/null || true
        fi
    done

    # Handle stamp-cert-sha256 (Play Store signing stamp — only in official)
    local has_stamp=0
    if grep -q 'Only in.*stamp-cert-sha256' "${main_diff_file}" 2>/dev/null; then
        has_stamp=1
    fi
    local stamp_src="${results_dir}/official_${split_label}/stamp-cert-sha256"
    if [[ "${has_stamp}" -eq 1 && -f "${stamp_src}" ]]; then
        local stamp_out="${results_dir}/diff_stamp_${split_label}.txt"
        # stamp-cert-sha256 is a 32-byte binary (raw SHA-256 of signing cert) — show as hex
        { echo "# stamp-cert-sha256 (only in official — Play Store signing stamp):";
          od -A n -t x1 "${stamp_src}" 2>/dev/null | tr -d ' \n'; echo; } \
            > "${stamp_out}" 2>/dev/null || true
    fi

    for decoded_diff in \
        "${results_dir}/diff_manifest_${split_label}.txt" \
        "${results_dir}/diff_resources_${split_label}.txt" \
        "${results_dir}/diff_stamp_${split_label}.txt"; do
        [[ -f "${decoded_diff}" ]] || continue
        local label lines
        label="$(basename "${decoded_diff}" .txt)"
        if [[ -s "${decoded_diff}" ]]; then
            lines="$(wc -l < "${decoded_diff}")"
            log_info "  ${label} (${lines} lines — full: ${decoded_diff}):"
            head -5 "${decoded_diff}" | while IFS= read -r line; do echo "    ${line}"; done
            if [[ "${lines}" -gt 5 ]]; then
                log_info "    ... (${lines} total lines)"
            fi
        else
            log_pass "  ${label}: no differences after decoding"
        fi
    done
}

# ------------------------------------------------------------------------------
# Print the verification results block to stdout.
# ------------------------------------------------------------------------------
print_results_block() {
    local verdict="$1"
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

    local results_dir="${WORK_DIR}/comparison"

    _print_diff_section() {
        local heading="$1"; shift
        local shown=0
        echo "${heading}"
        for diff_file in "$@"; do
            [[ -f "${diff_file}" ]] || continue
            local label lines
            label="$(basename "${diff_file}" .txt)"
            if [[ -s "${diff_file}" ]]; then
                lines="$(wc -l < "${diff_file}")"
                echo "  ${label} (first 5 lines — full diff: ${diff_file}):"
                head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
                if [[ "${lines}" -gt 5 ]]; then
                    echo "    ... (${lines} lines total)"
                fi
            else
                echo "  ${label}: no differences"
            fi
            shown=$(( shown + 1 ))
        done
        if [[ "${shown}" -eq 0 ]]; then
            echo "  (none)"
        fi
    }

    # Main diffs (raw diff -r output per split)
    local main_diffs=()
    if [[ -d "${results_dir}" ]]; then
        while IFS= read -r f; do
            local bn; bn="$(basename "${f}")"
            [[ "${bn}" == diff_manifest_* || "${bn}" == diff_resources_* || "${bn}" == diff_stamp_* ]] && continue
            main_diffs+=("${f}")
        done < <(find "${results_dir}" -maxdepth 1 -name "diff_*.txt" | sort)
    fi
    _print_diff_section "Diff:" "${main_diffs[@]:-}"

    # Decoded diffs (AndroidManifest.xml, resources.arsc)
    local decoded_diffs=()
    if [[ -d "${results_dir}" ]]; then
        while IFS= read -r f; do
            decoded_diffs+=("${f}")
        done < <(find "${results_dir}" -maxdepth 1 \
            \( -name "diff_manifest_*.txt" -o -name "diff_resources_*.txt" \
            -o -name "diff_stamp_*.txt" \) | sort)
    fi
    if [[ "${#decoded_diffs[@]}" -gt 0 ]]; then
        echo ""
        _print_diff_section "Decoded Diffs:" "${decoded_diffs[@]}"
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

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
NAME
       ${SCRIPT_NAME} - Coin Wallet Android reproducible build verification

SYNOPSIS
       ${SCRIPT_NAME} --binary <split.apk> [OPTIONS]
       ${SCRIPT_NAME} --binary <dir/> [OPTIONS]
       ${SCRIPT_NAME} --apk <split.apk> [OPTIONS]
       ${SCRIPT_NAME} --help

DESCRIPTION
       Builds Coin Wallet Android from source in a container and compares
       against official split APKs from Google Play.

       --binary <file> (or --apk <file>):
         Accepts one official split APK from Google Play (e.g. base.apk or
         split_config.en.apk). All sibling splits in the same directory are
         automatically discovered and copied for comparison.
         Version is auto-detected from APK metadata unless --version is provided.
         Builds AAB via Cordova (android-play distribution), extracts splits
         with bundletool + device-spec.json, and compares each split.

REQUIRED
       --github-token <token>   GitHub PAT with read:packages scope.
                                Alias: GITHUB_TOKEN env var.
                                Required for @coinspace/* packages on GPR.

OPTIONS
       --binary <file|dir>      Single APK file: compare only that split.
                                Directory: compare all *.apk files in it.
                                Alias: --apk.
       --version <version>      Version to verify (e.g. 6.24.0). Optional;
                                auto-detected from APK metadata if omitted.
       --arch <arch>            Target ABI for device-spec.json.
                                Default: arm64-v8a.
       --type <type>            Accepted for build server compatibility; unused.
       --github-run-number <n>  Override GITHUB_RUN_NUMBER used for versionCode.
                                Default: auto-computed from official APK versionCode
                                as GITHUB_RUN_NUMBER = versionCode - 2530.
       --tag <ref>              Override git tag (default: v<version>).
       --cleanup                Remove work directory after completion.
       --script-version         Print script version and exit.
       --help                   Show this help and exit.

EXIT CODES
       0    Reproducible (only META-INF differences after filtering, or identical)
       1    Differences found or build failure
       2    Invalid parameters

ENVIRONMENT
       GITHUB_TOKEN     GitHub PAT with read:packages scope (required)

EXAMPLES
       export GITHUB_TOKEN=ghp_yourtoken
       ${SCRIPT_NAME} --binary ~/Downloads/base.apk

       ${SCRIPT_NAME} --binary ~/Downloads/base.apk \\
           --version 6.24.0 --arch arm64-v8a --github-token ghp_xxxx

       ${SCRIPT_NAME} --binary ~/Downloads/split_config.en.apk \\
           --github-run-number 1632 --github-token ghp_xxxx

NOTES
       Only prerequisite on the host: docker or podman.
       Everything else runs inside the container.
       Coin Wallet uses v-prefixed tags (e.g. v6.24.0).
       The Play Store APK is served via AAB -> split APKs (base.apk,
       split_config.en.apk, split_config.xxhdpi.apk, etc.).
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
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
                log_warn "--type '${TYPE:-}' accepted but unused (split APK mode)" ;;
            --github-token)
                github_token="${2:-}"; shift ;;
            --github-run-number)
                GITHUB_RUN_NUMBER="${2:-}"; shift ;;
            --tag)
                REQUESTED_TAG="${2:-}"; shift ;;
            --cleanup)
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
        [[ "$#" -gt 0 ]] && shift
    done

    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Do not run this script as root."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    [[ -z "${github_token}" && -n "${GITHUB_TOKEN:-}" ]] && github_token="${GITHUB_TOKEN}"

    if [[ -z "${APK_INPUT}" ]]; then
        echo "[ERROR] --binary <split.apk|dir> is required."
        echo "        Single file: compare only that split APK."
        echo "        Directory:   compare all *.apk files in that directory."
        echo "        Pass --github-token <PAT> or set GITHUB_TOKEN env var."
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"

    if [[ -d "${APK_INPUT}" ]]; then
        INPUT_IS_DIR=true
        log_info "--binary is a directory; all *.apk files will be compared."
    elif [[ -f "${APK_INPUT}" ]]; then
        INPUT_IS_DIR=false
    else
        echo "[ERROR] --binary path not found: ${APK_INPUT}"
        echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi
    ARCH="${ARCH:-arm64-v8a}"
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
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
  GitHub token not provided. Coin Wallet depends on @coinspace/cs-* wallet
  libraries hosted exclusively on npm.pkg.github.com (GitHub Package Registry).
  The web/.npmrc routes the @coinspace scope to GPR and reads the token from
  NPM_READ_TOKEN. A GitHub Personal Access Token with read:packages scope is
  required for npm ci to succeed.
  Pass --github-token <PAT> or set the GITHUB_TOKEN environment variable.
EOF
        RESULT_DONE=true
        echo "[ERROR] GitHub token required for @coinspace/* GPR dependency."
        echo "        Pass --github-token <PAT> or set GITHUB_TOKEN env var."
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi

    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"

    log_info "Work directory: ${WORK_DIR}"
    log_info "Arch: ${ARCH}"
    log_info "APK input: ${APK_INPUT}"
}

# ------------------------------------------------------------------------------
# Build image management
# ------------------------------------------------------------------------------
ensure_build_image() {
    if ${CONTAINER_CMD} image inspect "${COINSPACE_BUILD_IMAGE}" >/dev/null 2>&1; then
        log_info "Build image ${COINSPACE_BUILD_IMAGE} already exists, skipping build."
        return 0
    fi

    log_info "Building ${COINSPACE_BUILD_IMAGE} from inline Dockerfile..."
    log_info "Installs: Node 20, JDK 17 (Zulu), Android SDK, build-tools 35.0.0, Gradle 8.13, Cordova 12, bundletool ${BUNDLETOOL_VERSION}."
    log_info "Estimated time: 10-20 minutes depending on network speed."

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
        python3 \
        gnupg \
        lsb-release \
        apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://repos.azul.com/azul-repo.key | gpg --dearmor -o /usr/share/keyrings/azul.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/azul.gpg] https://repos.azul.com/zulu/deb stable main" \
        > /etc/apt/sources.list.d/zulu.list && \
    apt-get update -q && \
    apt-get install -y --no-install-recommends zulu17-ca-jdk && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${ANDROID_HOME}" /root/.android && \
    touch /root/.android/repositories.cfg && \
    curl -fsSL \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -o /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d "${ANDROID_HOME}" && \
    rm -f /tmp/sdk.zip

ENV PATH="${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/35.0.0:${JAVA_HOME}/bin:${PATH}"

RUN yes | "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" \
        --sdk_root="${ANDROID_HOME}" --licenses && \
    "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" \
        --sdk_root="${ANDROID_HOME}" \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0"

ARG GRADLE_VERSION=8.13
RUN curl -fL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
    -o /tmp/gradle.zip && \
    unzip -q /tmp/gradle.zip -d /opt && \
    rm -f /tmp/gradle.zip
ENV PATH="/opt/gradle-8.13/bin:${PATH}"

RUN npm install -g cordova@12 --prefer-online

RUN mkdir -p /.android && chmod 777 /.android

ARG BUNDLETOOL_VERSION=1.17.2
RUN curl -fL "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \
    -o /usr/local/lib/bundletool.jar && \
    printf '#!/bin/sh\nexec java -jar /usr/local/lib/bundletool.jar "$@"\n' \
    > /usr/local/bin/bundletool && \
    chmod +x /usr/local/bin/bundletool

CMD ["bash"]
DOCKERFILE_END

    ${CONTAINER_CMD} build \
        --no-cache \
        --tag "${COINSPACE_BUILD_IMAGE}" \
        --file "${dockerfile_path}" \
        "${WORK_DIR}"

    log_pass "Build image ${COINSPACE_BUILD_IMAGE} ready."
}

# ------------------------------------------------------------------------------
# Git tag resolution
# ------------------------------------------------------------------------------
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

# ==============================================================================
# Phase 1: Prepare
# ==============================================================================
prepare() {
    log_info "=== PREPARE PHASE ==="

    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/official-split-apks"
    mkdir -p "${WORK_DIR}/built-output"
    # Ensure the build output dir is world-writable so the container can write.
    chmod 777 "${WORK_DIR}/built-output"

    local canonical_name
    if [[ "${INPUT_IS_DIR}" == "true" ]]; then
        log_info "Copying all *.apk from directory: ${APK_INPUT}"
        local copy_count=0
        while IFS= read -r apk; do
            local apk_name apk_canonical
            apk_name="$(basename "${apk}")"
            apk_canonical="$(canonicalize_split_apk_name "${apk_name}")"
            cp "${apk}" "${WORK_DIR}/official-split-apks/${apk_canonical}"
            [[ "${apk_name}" != "${apk_canonical}" ]] && \
                log_info "  Copied and normalized: ${apk_name} -> ${apk_canonical}" || \
                log_info "  Copied: ${apk_name}"
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
        [[ "${original_name}" != "${canonical_name}" ]] && \
            log_info "Normalized split name: ${original_name} -> ${canonical_name}"
        OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"

        # If the provided split is not base.apk, look for base.apk in the same
        # source directory to use for metadata (versionName, versionCode).
        if [[ "${canonical_name}" != "base.apk" ]]; then
            for _candidate in "${input_dir}/base.apk" "${input_dir}/base-master.apk"; do
                if [[ -f "${_candidate}" ]]; then
                    # Copy to metadata-base.apk (not official-split-apks/) so it
                    # survives the WORK_DIR rename but is NOT compared by extract_and_compare().
                    cp "${_candidate}" "${WORK_DIR}/metadata-base.apk"
                    OFFICIAL_BASE_APK="${WORK_DIR}/metadata-base.apk"
                    log_info "Using sibling $(basename "${_candidate}") for metadata extraction."
                    break
                fi
            done
        fi
    fi

    if [[ -z "${OFFICIAL_BASE_APK}" ]]; then
        OFFICIAL_BASE_APK="$(find_official_base_apk || true)"
    fi
    if [[ -z "${OFFICIAL_BASE_APK}" ]]; then
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"
        log_warn "No base.apk found; using ${canonical_name} for metadata."
    fi

    if [[ -z "${VERSION}" ]]; then
        log_info "Auto-detecting version from APK content..."
        VERSION="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
        [[ "${VERSION}" == "null" ]] && VERSION=""
        if [[ -z "${VERSION}" ]]; then
            log_fail "Could not detect version from APK. Pass --version explicitly."
            generate_error_yaml "ftbfs" \
                "Could not auto-detect versionName from APK. Pass --version explicitly."
            RESULT_DONE=true
            exit "${EXIT_INVALID}"
        fi
        log_info "Version detected: ${VERSION}"
        VERSION_SAFE="${VERSION}"

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
                if [[ -z "${OFFICIAL_BASE_APK}" ]]; then
                    OFFICIAL_BASE_APK="${OFFICIAL_APK}"
                fi
            fi
            log_info "Work directory updated: ${WORK_DIR}"
        fi
    fi

    if [[ -z "${GITHUB_RUN_NUMBER}" ]]; then
        log_info "Auto-detecting GITHUB_RUN_NUMBER from versionCode..."
        local version_code
        version_code="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionCode" || true)"
        if [[ -n "${version_code}" && "${version_code}" =~ ^[0-9]+$ ]]; then
            GITHUB_RUN_NUMBER=$(( version_code - 2530 ))
            log_info "versionCode=${version_code} -> GITHUB_RUN_NUMBER=${GITHUB_RUN_NUMBER} (versionCode - 2530)"
        else
            GITHUB_RUN_NUMBER=1
            log_warn "Could not detect versionCode from APK; defaulting GITHUB_RUN_NUMBER=1"
            log_warn "Pass --github-run-number to override."
        fi
    else
        log_info "GITHUB_RUN_NUMBER=${GITHUB_RUN_NUMBER} (provided via --github-run-number)"
    fi

    create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"

    log_info "Official splits copied:"
    find "${WORK_DIR}/official-split-apks" -name "*.apk" 2>/dev/null | while IFS= read -r f; do
        echo "  $(basename "${f}")"
    done

    log_pass "Preparation complete. Work directory: ${WORK_DIR}"
}

# ==============================================================================
# Phase 2: Build image
# ==============================================================================
build_image() {
    log_info "=== BUILD IMAGE PHASE ==="
    ensure_build_image
}

# ==============================================================================
# Phase 3: Build from source
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
            echo "  Tried tags: v${VERSION_SAFE}, ${VERSION_SAFE}"
            echo "  Repository: ${REPO_URL}"
            echo "======================================================"
            echo ""
            generate_comparison_yaml "ftbfs" \
                "Tag not found for version ${VERSION_SAFE}. Tried: v${VERSION_SAFE}, ${VERSION_SAFE}. Source code for this version has not been tagged in the CoinSpace repository."
            RESULT_DONE=true
            echo "Exit code: ${EXIT_FAILED}"
            exit "${EXIT_FAILED}"
        fi
    fi

    log_info "Git tag: ${GIT_TAG}"
    log_info "Build mode: unsigned release AAB (android-play distribution)"
    log_info "GITHUB_RUN_NUMBER: ${GITHUB_RUN_NUMBER} (versionCode will be $((GITHUB_RUN_NUMBER + 2530)))"
    log_info "Cloning + building in container. May take 20-60 minutes."
    log_info "NOTE: Vite embeds VITE_* API keys; empty values expected vs official build."

    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-output:/workspace${VOLUME_RW}" \
        -e "HOME=/workspace" \
        -e "npm_config_cache=/workspace/.npm-cache" \
        -e "GRADLE_USER_HOME=/workspace/.gradle" \
        -e "GRADLE_OPTS=-Dorg.gradle.native=false" \
        -e "ANDROID_PREFS_ROOT=/workspace" \
        -e "NPM_READ_TOKEN=${github_token}" \
        -e "NODE_AUTH_TOKEN=${github_token}" \
        -e "NODE_ENV=production" \
        -e "NODE_OPTIONS=--max-old-space-size=3575" \
        -e "VITE_BUILD_TYPE=phonegap" \
        -e "VITE_PLATFORM=android" \
        -e "VITE_DISTRIBUTION=android-play" \
        -e "VITE_COMMIT=reproducible-build" \
        -e "VITE_SENTRY_ENVIRONMENT=development" \
        -e "GITHUB_RUN_NUMBER=${GITHUB_RUN_NUMBER}" \
        "${COINSPACE_BUILD_IMAGE}" \
        bash -c "set -euo pipefail

            echo '[INFO] Cloning ${REPO_URL} at tag ${GIT_TAG}...'
            git clone --depth 1 --branch '${GIT_TAG}' '${REPO_URL}' /workspace/app
            echo '[INFO] Clone complete.'

            cd /workspace/app

            git rev-parse HEAD > /workspace/commit.txt
            echo '[INFO] Commit: '\$(cat /workspace/commit.txt)

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

            printf '//npm.pkg.github.com/:_authToken=\${NPM_READ_TOKEN}\n' \
                >> /workspace/app/web/.npmrc
            echo '[INFO] .npmrc updated with GPR auth token placeholder.'

            echo '[INFO] Installing web dependencies (npm ci)...'
            export NODE_ENV=ci
            npm --prefix web ci

            echo '[INFO] Installing phonegap dependencies (npm ci)...'
            npm --prefix phonegap ci

            echo '[INFO] Running i18n check...'
            export NODE_ENV=production
            npm --prefix web run i18n:ci || true

            echo '[INFO] Building web bundle (Vite, VITE_DISTRIBUTION=android-play)...'
            npm --prefix web run build

            mkdir -p /workspace/.gradle /workspace/.android
            printf 'org.gradle.native=false\norg.gradle.jvmargs=-Duser.home=/workspace\n' \
                > /workspace/.gradle/gradle.properties

            echo '[INFO] Running android.js (prepare phase, no CI=true)...'
            cd /workspace/app/phonegap
            node android.js

            echo '[INFO] Compiling unsigned release AAB (android-play)...'
            cd /workspace/app/phonegap/build
            cordova compile android --release -- --packageType=bundle \
                --buildConfig=/dev/null 2>/dev/null || \
            cordova compile android --release -- --packageType=bundle

            echo '[INFO] Build complete.'
            chmod -R a+rwX /workspace 2>/dev/null || true
        "

    chmod -R a+rwX "${WORK_DIR}/built-output" 2>/dev/null || true

    local aab_path
    aab_path="$(find "${WORK_DIR}/built-output/app" \
        -name "app-release.aab" \
        -path "*/outputs/bundle/*" \
        ! -path "*/intermediates/*" \
        2>/dev/null | head -1)"

    if [[ -z "${aab_path}" ]]; then
        log_fail "Unsigned release AAB not found after build."
        log_info "All .aab files found under built-output:"
        find "${WORK_DIR}/built-output" -name "*.aab" 2>/dev/null | head -10 || true
        exit "${EXIT_FAILED}"
    fi

    BUILT_AAB="${aab_path}"
    log_pass "Built AAB: ${BUILT_AAB}"
}

# ==============================================================================
# Phase 4: Extract split APKs and compare
# ==============================================================================
extract_and_compare() {
    log_info "=== EXTRACT AND COMPARE PHASE ==="

    TOTAL_DIFFS=0

    local built_splits_dir="${WORK_DIR}/built-split-apks"
    extract_split_apks_from_aab \
        "${BUILT_AAB}" \
        "${WORK_DIR}/device-spec.json" \
        "${built_splits_dir}"

    # Compare each official split against its matching built split.
    local official_splits_dir="${WORK_DIR}/official-split-apks"
    local compared=0

    while IFS= read -r official_apk; do
        [[ -f "${official_apk}" ]] || continue
        local split_name split_label built_split
        split_name="$(basename "${official_apk}")"
        split_label="${split_name%.apk}"

        log_info "Looking for built match for: ${split_name}"

        built_split="$(resolve_built_split_apk "${official_apk}" "${built_splits_dir}/splits")" || {
            log_warn "No matching built split for: ${split_name} — skipping comparison"
            log_info "  Canonical name tried: $(canonicalize_split_apk_name "${split_name}")"
            log_info "  Available built splits:"
            find "${built_splits_dir}" -name "*.apk" 2>/dev/null \
                | while IFS= read -r f; do echo "    $(basename "${f}")"; done
            # Count as a difference: official split has no matching built split.
            TOTAL_DIFFS=$(( TOTAL_DIFFS + 1 ))
            continue
        }

        log_info "Official split: ${split_name}"
        log_info "Built split:    $(basename "${built_split}")"

        compare_apks "${official_apk}" "${built_split}" "${split_label}"
        compared=$(( compared + 1 ))
    done < <(find "${official_splits_dir}" -name "*.apk" 2>/dev/null | sort)

    if [[ "${compared}" -eq 0 ]]; then
        log_fail "No official splits were compared. Check official-split-apks directory."
        exit "${EXIT_FAILED}"
    fi

    log_info "Total splits compared: ${compared}"
    log_info "Total non-META-INF diffs (across all splits): ${TOTAL_DIFFS}"
}

# ==============================================================================
# Phase 5: Result
# Determines verdict from TOTAL_DIFFS (0 = reproducible, >0 = not_reproducible).
# Writes COMPARISON_RESULTS.yaml (minimal 3-field format per 2026-03-12 spec).
# Prints Begin/End Results block. Sets RESULT_DONE. Exits 0 or 1.
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

    local notes
    notes="Cordova/Vue3 hybrid app. Builds VITE_DISTRIBUTION=android-play to produce an AAB,
  then bundletool extracts split APKs compared against official Play Store splits.
  Expected differences (do not affect reproducibility verdict):
  - META-INF/*: signing artifacts (Play Store signed; built APK is unsigned)
  - assets/www/assets/js/*.js: production VITE_* secrets (API keys, partner refs)
    are embedded in the official bundle but absent in the unsigned build"

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
