#!/bin/bash
# ==============================================================================
# coinspacewallet_build.sh - Coin Wallet Android Reproducible Build Verification
# ==============================================================================
# Version:          v0.4.3
# Organization:     WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-18
# App:              Coin Wallet Android (com.coinspace.app)
# Project:          https://github.com/CoinSpace/CoinSpace
# Disclaimer: for reproducible-build verification and research only. No warranty;
# users assume all risk and are responsible for legal compliance.
# Steps: copy the official split APKs (--binary), build the Cordova app as an AAB
# in a container (the tag is cloned there too), cut split APKs with bundletool,
# compare each split unzipped, write COMPARISON_RESULTS.yaml next to this script.
# Shared steps (engine pick, workspace, traps, YAML, results block, cleanup) come
# from the WalletScrutiny library ws-rb-core, pinned by sha256 below (GitLab #1023).
# Offline: WS_LIB_FILE=/path/to/ws-rb-core-1.0.0.sh.
# Needs GITHUB_TOKEN (read:packages) for the @coinspace/* packages on GitHub's
# npm registry. Only prerequisite on the host: podman or docker.
# Exit codes: 0 reproducible; 1 not reproducible, ftbfs or no verdict;
# 2 invalid parameters or library unavailable; 130 stopped.
# ==============================================================================

set -eo pipefail

SCRIPT_VERSION="v0.4.3"
SCRIPT_NAME="coinspacewallet_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"

# ---- Self-identification (first action, before arguments or any network) -----
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1)" || true
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "         sha256: ${SCRIPT_SHA256}"
echo

# ---- WalletScrutiny library (GitLab #1023), pinned by sha256 ------------------
# Goes in each build script right after its self-hash line, before anything else.
# Source: WS_LIB_FILE (offline, must match), else the cache, else GitLab by
# commit. Nothing else. A wrong hash is rejected whichever source sent it.
# No matching copy, or a different version inside: no verdict, no YAML, exit 2.
# First, before anything can fail: no earlier verdict may survive this run. A run
# that holds this folder's lock is still writing its own; that one stays, and the
# library refuses this run when it takes the lock.
WS_LIB_DIR0="$(dirname "$(readlink -f "$0")")"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WS_LIB_DIR0/.comparison_results.lock" true 2>/dev/null && rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
else
  WS_LIB_P="$(cat "$WS_LIB_DIR0/.comparison_results.lock.d/pid" 2>/dev/null || true)"
  case "$WS_LIB_P" in ''|*[!0-9]*) WS_LIB_P="";; esac
  { [ -n "$WS_LIB_P" ] && kill -0 "$WS_LIB_P" 2>/dev/null; } || rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
fi
WS_LIB=ws-rb-core WS_LIB_VERSION=1.0.0
WS_LIB_REV=3581020196b35eefa501a19ed0abb43e96f4db42 WS_LIB_SHA256=d321b7c6937bbfc4a42db273c3fb6ec02c58e930c7c2b962492b8966188a0fcf
ws_lib_load() {
  local c f u t=""
  ws_lib_ok() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$WS_LIB_SHA256" ]; }
  if [ -n "${WS_LIB_FILE:-}" ]; then
    f="$WS_LIB_FILE"
    ws_lib_ok "$f" || { echo "[FAIL] WS_LIB_FILE $f is not sha256 $WS_LIB_SHA256: no verdict" >&2; exit 2; }
  else
    # Cache in XDG_CACHE_HOME or HOME; with neither, or no way to create it, a
    # temporary folder for this run only. Every copy is hash-checked either way.
    c="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
    if [ -n "$c" ] && mkdir -p "$c/ws-rb-lib" 2>/dev/null; then c="$c/ws-rb-lib"
    else t="$(mktemp -d 2>/dev/null)" || { echo "[FAIL] no folder to fetch $WS_LIB into: no verdict" >&2; exit 2; }; c="$t"; fi
    f="$c/$WS_LIB_SHA256.sh"
    if ! ws_lib_ok "$f"; then
      u="https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/$WS_LIB_REV/scripts/rb/lib/$WS_LIB-$WS_LIB_VERSION.sh"
      curl -fsSL --max-time 60 -o "$f.$$" "$u" 2>/dev/null && ws_lib_ok "$f.$$" && mv -f "$f.$$" "$f"
      rm -f "$f.$$"
    fi
  fi
  ws_lib_ok "$f" || { [ -z "$t" ] || rm -rf -- "$t"; echo "[FAIL] $WS_LIB $WS_LIB_VERSION ($WS_LIB_SHA256) unavailable or altered: no verdict" >&2; exit 2; }
  . "$f"
  [ -z "$t" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load

readonly APP_ID="com.coinspace.app"
readonly REPO_URL="https://github.com/CoinSpace/CoinSpace.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly BUNDLETOOL_VERSION="1.17.2"
# Per run, removed at exit by the library.
readonly COINSPACE_BUILD_IMAGE="localhost/coinspacewallet-build-env:${WS_RUN_ID}"

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

# Set during prepare/build
VERSION_SAFE=""
OFFICIAL_APK=""       # canonical path in WORK_DIR to the input split APK
OFFICIAL_BASE_APK=""  # path to base.apk in official-split-apks/ (for metadata)
BUILT_AAB=""          # path to the AAB produced by the build
GIT_TAG=""            # resolved git tag (e.g. "v6.24.0")
TOTAL_DIFFS=1         # default to "failed" until compare_split_apks() runs cleanly

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()  { echo "[INFO] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_fail()  { echo "[FAIL] $*"; }
log_warn()  { echo "[WARNING] $*"; }
# Each container is named and tracked, so the exit trap stops it if the run ends early.
CN=0
crun() { local n="csw-${WS_RUN_ID}-${BASHPID}-$((++CN))"; ws_track_container "$n"; ${CONTAINER_CMD} run --rm --name "$n" "$@"; }

# ------------------------------------------------------------------------------
# Container runtime: the library picks it (podman if it works, else docker).
# ------------------------------------------------------------------------------
set_container_runtime() {
    ws_engine
    CONTAINER_CMD="ws_ctr"
    CONTAINER_RUN_EXTRA="$(ws_user_flags)"
    if [[ "${WS_ENGINE}" == "podman" ]]; then
        VOLUME_RO=":ro,Z"; VOLUME_RW=":Z"
    else
        VOLUME_RO=":ro"; VOLUME_RW=""
    fi
}

# ------------------------------------------------------------------------------
# Container helpers
# ------------------------------------------------------------------------------
container_exec() {
    local cmd="$1"
    crun \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${COINSPACE_BUILD_IMAGE}" \
        bash -c "$cmd"
}

ws_exec() {
    local cmd="$1"
    crun \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${WS_CONTAINER}" \
        sh -c "$cmd"
}

container_sha256() {
    local file_path="$1"
    crun \
        -v "$(dirname "$file_path"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "sha256sum /data/$(basename "$file_path") | awk '{print \$1}'"
}

container_signer() {
    local apk_path="$1"
    crun \
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
    crun \
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

    crun \
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

# Unzip an APK in the WS container. unzip exit >1 = no verdict.
unzip_apk_in_container() {
    local apk_path="$1"
    local out_dir="$2"
    local apk_rel out_rel
    apk_rel="${apk_path#"${WORK_DIR}/"}"
    out_rel="${out_dir#"${WORK_DIR}/"}"
    ws_exec "mkdir -p '${out_rel}' && { unzip -qq '${apk_rel}' -d '${out_rel}'; [ \$? -le 1 ]; } && { chmod -R a+rwX '${out_rel}' 2>/dev/null; true; }" \
        || ws_no_verdict "could not unzip ${apk_path}"
}

# Compare one split: diff -rq of both unzipped trees; see the exclusions below.
# diff exit >1 = no verdict.
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

    ws_exec "diff -rq '${official_rel}' '${built_rel}' > '${diff_rel}' 2>&1; [ \$? -le 1 ]" \
        || ws_no_verdict "diff failed on ${split_label}: see ${diff_file}"
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true

    local total_lines=0
    local non_meta_count=0

    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        # Every line diff -rq prints counts, except Play signing only in the official
        # split's root: stamp-cert-sha256, a plain file in META-INF, or a META-INF
        # holding only plain files (diff names a one-sided folder once).
        local line p o
        while IFS= read -r line; do
            if [[ "${line}" =~ ^Only\ in\ (comparison/official_[^/:]+)(/META-INF)?:\ (.+)$ ]]; then
                p="${WORK_DIR}/${BASH_REMATCH[1]}${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
                case "${BASH_REMATCH[2]}:${BASH_REMATCH[3]}" in
                    :stamp-cert-sha256|/META-INF:*) [[ -f "${p}" && ! -L "${p}" ]] && continue ;;
                    :META-INF)
                        if [[ -d "${p}" && ! -L "${p}" ]]; then
                            o="$(find "${p}" -mindepth 1 ! -type f -print -quit)" || ws_no_verdict "cannot read ${p}"
                            [[ -z "${o}" ]] && continue
                        fi ;;
                esac
            fi
            non_meta_count=$(( non_meta_count + 1 ))
        done < "${diff_file}"
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

# aapt-decoded diffs of AndroidManifest.xml and resources.arsc (evidence only).
decode_and_diff_binaries() {
    local official_apk="$1"
    local built_apk="$2"
    local split_label="$3"
    local main_diff_file="$4"
    local results_dir="${WORK_DIR}/comparison"

    local has_manifest=0 has_resources=0
    grep -q 'AndroidManifest\.xml and .* differ' "${main_diff_file}" 2>/dev/null \
        && has_manifest=1 || true
    grep -q 'resources\.arsc and .* differ' "${main_diff_file}" 2>/dev/null \
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
# Results block: the library prints the fields; the Diff section is this script's.
# ------------------------------------------------------------------------------
_print_diff_section() {
    local heading="$1"; shift
    local shown=0
    [[ -z "${heading}" ]] || echo "${heading}"
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

diff_section() {
    local results_dir="${WORK_DIR}/comparison" f bn
    local main_diffs=() decoded_diffs=()
    if [[ -d "${results_dir}" ]]; then
        while IFS= read -r f; do
            bn="$(basename "${f}")"
            case "${bn}" in
                diff_manifest_*|diff_resources_*|diff_stamp_*) decoded_diffs+=("${f}") ;;
                *) main_diffs+=("${f}") ;;
            esac
        done < <(find "${results_dir}" -maxdepth 1 -name "diff_*.txt" | sort)
    fi
    _print_diff_section "" "${main_diffs[@]:-}"
    if [[ "${#decoded_diffs[@]}" -gt 0 ]]; then
        echo ""
        _print_diff_section "Decoded Diffs:" "${decoded_diffs[@]}"
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    if [[ -f "${WORK_DIR}/built-output/tag_verify.txt" ]]; then
        cat "${WORK_DIR}/built-output/tag_verify.txt"
    else
        echo "  (tag verification not available)"
    fi
}

print_results_block() {
    local verdict="$1"
    local meta_apk="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}"
    local version_name version_code signer app_hash commit=""
    version_name="$(container_aapt_version "${meta_apk}" "versionName" || true)"
    version_code="$(container_aapt_version "${meta_apk}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_APK}" || true)"
    app_hash="$(container_sha256 "${OFFICIAL_APK}" || true)"
    [[ -f "${WORK_DIR}/built-output/commit.txt" ]] && commit="$(cat "${WORK_DIR}/built-output/commit.txt")"

    echo ""
    ws_results_block "${APP_ID}" "${signer:-unknown}" "${version_name:-${VERSION_SAFE}}" \
        "${version_code:-unknown}" "${verdict}" "${app_hash:-unknown}" "${commit:-unknown}" \
        "$(diff_section)"
    echo "appHash: sha256 of the official $(basename "${OFFICIAL_APK}") as given (publish this one)."
    echo "libVersion/libHash: the shared library this run loaded."
    echo ""
    echo "Work directory: ${WORK_DIR}"
    echo "Diff files:     ${WORK_DIR}/comparison/"
    echo "For deeper analysis:"
    echo "  diffoscope '${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK:-base.apk}")' \\"
    echo "             '${WORK_DIR}/built-split-apks/splits/$(basename "${OFFICIAL_APK:-base.apk}")'"
    echo "  meld '${WORK_DIR}/comparison'"
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <split.apk|dir> [--arch ABI] [--version V] [OPTIONS]

Builds Coin Wallet Android from source in a container and compares it with the
official Google Play split APKs, split by split.

  --binary, --apk <file|dir>  One official split APK (its sibling base.apk is used
                              for metadata), or a directory: every *.apk in it is
                              compared. Required.
  --version <v>               Version (e.g. 6.24.0). Default: read from base.apk.
  --arch <abi>                ABI for device-spec.json. Default: arm64-v8a.
  --type <type>               Accepted for the build server; unused.
  --github-run-number <n>     GITHUB_RUN_NUMBER for versionCode.
                              Default: versionCode - 2530 from the official APK.
  --tag <ref>                 Git tag. Default: v<version>, then <version>.
  --github-token <token>      Prefer GITHUB_TOKEN in the environment: a token on
                              the command line is visible to other users.
  --script-version, --help

GITHUB_TOKEN (read:packages) is required: the @coinspace/* packages are only on
npm.pkg.github.com. Coin Wallet tags are v-prefixed (v6.24.0).

Exit codes: 0 reproducible; 1 not reproducible, ftbfs or no verdict;
2 invalid parameters; 130 stopped.
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)
                ws_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
            --apk|--binary)
                ws_require_value "$1" "${2:-}"; APK_INPUT="$2"; shift 2 ;;
            --arch)
                ws_require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
            --type)
                ws_require_value "$1" "${2:-}"; TYPE="$2"; shift 2
                log_warn "--type '${TYPE}' accepted but unused (split APK mode)" ;;
            --github-token)
                ws_require_value "$1" "${2:-}"; github_token="$2"; shift 2
                log_warn "--github-token is visible to other users; prefer GITHUB_TOKEN" ;;
            --github-run-number)
                ws_require_value "$1" "${2:-}"; GITHUB_RUN_NUMBER="$2"; shift 2 ;;
            --tag)
                ws_require_value "$1" "${2:-}"; REQUESTED_TAG="$2"; shift 2 ;;
            --cleanup)
                log_warn "--cleanup is ignored: each run has its own workspace"; shift ;;
            --script-version)
                echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)
                usage; exit "${EXIT_SUCCESS}" ;;
            *)
                # Unknown parameter: warn and continue. Never fatal (ABS rule).
                ws_unknown_arg "$@"; shift "${WS_SHIFT}" ;;
        esac
    done

    [[ -z "${github_token}" && -n "${GITHUB_TOKEN:-}" ]] && github_token="${GITHUB_TOKEN}"

    [[ -n "${APK_INPUT}" ]] || ws_invalid "--binary <split.apk|dir> is required"
    [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${WS_CALLER_DIR}/${APK_INPUT}"

    if [[ -d "${APK_INPUT}" ]]; then
        INPUT_IS_DIR=true
        log_info "--binary is a directory; all *.apk files will be compared."
    elif [[ -f "${APK_INPUT}" ]]; then
        INPUT_IS_DIR=false
    else
        ws_invalid "--binary path not found: ${APK_INPUT}"
    fi
    ARCH="${ARCH:-arm64-v8a}"
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            log_warn "Unrecognized arch '${ARCH}'; defaulting to arm64-v8a"
            ARCH="arm64-v8a"
            ;;
    esac
    if [[ -n "${VERSION}" && ! "${VERSION}" =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
        ws_invalid "invalid --version '${VERSION}'"
    fi
    if [[ -n "${GITHUB_RUN_NUMBER}" && ! "${GITHUB_RUN_NUMBER}" =~ ^[0-9]+$ ]]; then
        ws_invalid "--github-run-number must be a number"
    fi

    [[ -n "${github_token}" ]] || ws_invalid "GITHUB_TOKEN (read:packages) is required: Coin Wallet's @coinspace/* packages are only on npm.pkg.github.com"
    # Passed to the build container by name only (-e NAME), never as a value on a command line.
    export NPM_READ_TOKEN="${github_token}" NODE_AUTH_TOKEN="${github_token}"

    VERSION_SAFE="${VERSION:-provided}"
    log_info "Arch: ${ARCH}"
    log_info "APK input: ${APK_INPUT}"
}

# ------------------------------------------------------------------------------
# Build image management
# ------------------------------------------------------------------------------
ensure_build_image() {
    log_info "Building ${COINSPACE_BUILD_IMAGE} from inline Dockerfile..."
    log_info "Installs: Node 20, JDK 17 (Zulu), Android SDK, build-tools 35.0.0 and 36.0.0, Gradle 8.13, Cordova 12, bundletool ${BUNDLETOOL_VERSION}."
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

ENV PATH="${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/36.0.0:${JAVA_HOME}/bin:${PATH}"

RUN yes | "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" \
        --sdk_root="${ANDROID_HOME}" --licenses && \
    "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" \
        --sdk_root="${ANDROID_HOME}" \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
        "platforms;android-36" \
        "build-tools;36.0.0"

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

    ws_track_image "${COINSPACE_BUILD_IMAGE}"
    ${CONTAINER_CMD} build \
        --no-cache \
        --tag "${COINSPACE_BUILD_IMAGE}" \
        --file "${dockerfile_path}" \
        "${WORK_DIR}"

    log_pass "Build image ${COINSPACE_BUILD_IMAGE} ready."
}


# ------------------------------------------------------------------------------
# Git tag resolution, inside the build image (no git on the host)
# ------------------------------------------------------------------------------
resolve_git_tag() {
    local candidate rc
    for candidate in "$@"; do
        rc=0
        crun "${COINSPACE_BUILD_IMAGE}" \
            git ls-remote --tags --exit-code "${REPO_URL}" "refs/tags/${candidate}" >/dev/null 2>&1 || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            log_info "Found tag: ${candidate}"
            GIT_TAG="${candidate}"
            return 0
        fi
        [[ "${rc}" -eq 2 ]] || ws_no_verdict "cannot reach ${REPO_URL} to look up tag ${candidate} (git exit ${rc})"
        log_info "  Tag ${candidate}: not found"
    done
    return 1
}

# ==============================================================================
# Phase 1: Prepare
# ==============================================================================
prepare() {
    log_info "=== PREPARE PHASE ==="

    # Per-run workspace in the caller's directory (exclusive mkdir, never reused).
    ws_workspace coinspacewallet "${VERSION:-auto}" "${ARCH}"
    WORK_DIR="${WS_WORKDIR}"
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
                    # is NOT compared by extract_and_compare().
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
        [[ -n "${VERSION}" ]] || ws_invalid "could not read versionName from the APK; pass --version"
        log_info "Version detected: ${VERSION}"
        VERSION_SAFE="${VERSION}"
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

    if [[ -n "${REQUESTED_TAG}" ]]; then
        [[ "${REQUESTED_TAG}" =~ ^[A-Za-z0-9._/-]+$ ]] || ws_invalid "invalid --tag '${REQUESTED_TAG}'"
        resolve_git_tag "${REQUESTED_TAG}" || ws_invalid "tag ${REQUESTED_TAG} not found in ${REPO_URL}"
    else
        resolve_git_tag "v${VERSION_SAFE}" "${VERSION_SAFE}" \
            || ws_invalid "no source tag for version ${VERSION_SAFE} in ${REPO_URL} (tried v${VERSION_SAFE}, ${VERSION_SAFE})"
    fi

    log_info "Git tag: ${GIT_TAG}"
    log_info "Build mode: unsigned release AAB (android-play distribution)"
    log_info "GITHUB_RUN_NUMBER: ${GITHUB_RUN_NUMBER} (versionCode will be $((GITHUB_RUN_NUMBER + 2530)))"
    log_info "Cloning + building in container. May take 20-60 minutes."
    log_info "NOTE: Vite embeds VITE_* API keys; empty values expected vs official build."

    # A failure here is not a verdict: npm and Gradle download during the build, so a
    # network failure cannot be told from a compile failure. Check the log.
    crun \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-output:/workspace${VOLUME_RW}" \
        -e "HOME=/workspace" \
        -e "npm_config_cache=/workspace/.npm-cache" \
        -e "GRADLE_USER_HOME=/workspace/.gradle" \
        -e "GRADLE_OPTS=-Dorg.gradle.native=false" \
        -e "ANDROID_PREFS_ROOT=/workspace" \
        -e NPM_READ_TOKEN \
        -e NODE_AUTH_TOKEN \
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
        ws_write_yaml ftbfs "Coin Wallet ${VERSION_SAFE}: the build finished but produced no app-release.aab."
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
        ws_no_verdict "no official split was compared; check official-split-apks"
    fi

    log_info "Total splits compared: ${compared}"
    log_info "Total non-META-INF diffs (across all splits): ${TOTAL_DIFFS}"
}

# Phase 5: verdict from TOTAL_DIFFS, YAML, results block; exits 0 or 1.
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
  then bundletool cuts split APKs, compared unzipped against the official Play splits.
  Not counted: META-INF, its files and stamp-cert-sha256 only in an official
  split's root (Play signing). Every other difference counts."

    ws_write_yaml "${verdict}" "${notes}"
    print_results_block "${verdict}"

    if [[ "${verdict}" == "reproducible" ]]; then
        exit "${EXIT_SUCCESS}"
    else
        exit "${EXIT_FAILED}"
    fi
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    ws_refuse_root
    ws_install_traps
    ws_results_init        # one run per script folder; stale COMPARISON_RESULTS.yaml removed
    parse_arguments "$@"
    set_container_runtime
    prepare
    build_image
    build
    extract_and_compare
    result
}

main "$@"
