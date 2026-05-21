#!/bin/bash
# gemwallet_build.sh v0.2.0 — Gem Wallet Android reproducible build verification
# Organization: WalletScrutiny.com
# App: com.gemwallet.android — https://github.com/gemwalletcom/wallet
# License: MIT. No warranty. Security research use only.
#
# GPR token required: trustwallet/wallet-core is on maven.pkg.github.com only.
# Pass --github-token <PAT> or set GITHUB_TOKEN env var (read:packages scope).
#
# R8 map-id caveat (AGP 9.2.x): diffs limited to classes*.dex and
# assets/dexopt/baseline.prof may be caused by non-deterministic pg-map-id.
# See android/reproducible/ in the gemwalletcom/wallet repo before concluding
# not_reproducible. This script does not apply that patch.
#
# Input: --binary accepts a single split APK or a tar.gz of split APKs.
# When a tar.gz is given all APKs are extracted; the arch-specific split
# (split_config.<arch>.apk) is used for comparison, base.apk for metadata.

set -euo pipefail

EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"
readonly SCRIPT_VERSION="v0.2.0"
readonly SCRIPT_NAME="gemwallet_build.sh"
readonly APP_ID="com.gemwallet.android"
readonly REPO_URL="https://github.com/gemwalletcom/wallet.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly GEMWALLET_BUILD_IMAGE="gemwallet_build_env:2"
readonly BUNDLETOOL_VERSION="1.17.2"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

VERSION=""
ARCH=""
TYPE=""
APK_INPUT=""
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
github_token=""
github_user="walletscrutiny"
REQUESTED_TAG=""
should_cleanup=false
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""
OFFICIAL_BASE_APK=""
BUILT_AAB=""
GIT_TAG=""
RESULT_DONE=false
TOTAL_DIFFS=1

log_info()  { echo "[INFO] $*"; }
log_pass()  { echo "[PASS] $*"; }
log_fail()  { echo "[FAIL] $*"; }
log_warn()  { echo "[WARNING] $*"; }

work_dir_path() {
    printf '%s/%s_%s_%s_%s\n' "${EXEC_DIR}" "${WORK_DIR_PREFIX}" "${APP_ID}" "$1" "$2"
}

write_yaml_outputs() {
    local content="$1"
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        printf '%s\n' "$content" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
    fi
}

generate_error_yaml() {
    local status="$1" notes="${2:-}"
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
    local verdict="$1" notes="$2"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}"
    log_info "Generated COMPARISON_RESULTS.yaml (verdict: ${verdict})"
}

on_error() {
    local exit_code=$? line_no=$1
    set +e
    log_fail "Script failed at line ${line_no} (exit code ${exit_code})"
    [[ "${RESULT_DONE}" != "true" ]] && generate_error_yaml "ftbfs" || true
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
        log_info "Using podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        VOLUME_RO=":ro"
        VOLUME_RW=""
        CONTAINER_RUN_EXTRA="--user $(id -u):$(id -g)"
        log_info "Using docker"
    else
        cat > "${EXEC_DIR}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  Neither podman nor docker found on host.
EOF
        echo "[ERROR] Neither podman nor docker is available."
        echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi
}

container_exec() {
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work \
        "${GEMWALLET_BUILD_IMAGE}" bash -c "$1"
}

ws_exec() {
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work \
        "${WS_CONTAINER}" sh -c "$1"
}

container_sha256() {
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$1"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "sha256sum /data/$(basename "$1") | awk '{print \$1}'"
}

container_signer() {
    ${CONTAINER_CMD} run --rm \
        -v "$(dirname "$1"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "apksigner verify --print-certs /apk/$(basename "$1") 2>/dev/null \
               | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}

container_aapt_version() {
    local apk_path="$1" field="$2"
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
                    | sed -n "s/.*'"${field}"'='"'"'\([^'"'"']*\)'"'"'.*/\1/p" | head -n1
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

canonicalize_split_apk_name() {
    case "$1" in
        base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
        split_config.*.apk) echo "$1" ;;
        base-*.apk) echo "split_config.${1#base-}" ;;
        *) echo "$1" ;;
    esac
}

resolve_built_split_apk() {
    local official_apk="$1" built_dir="$2"
    local official_name canonical_name
    official_name="$(basename "$official_apk")"
    [[ -f "${built_dir}/${official_name}" ]] && echo "${built_dir}/${official_name}" && return 0
    canonical_name="$(canonicalize_split_apk_name "$official_name")"
    [[ -f "${built_dir}/${canonical_name}" ]] && echo "${built_dir}/${canonical_name}" && return 0
    return 1
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <split.apk|splits.tar.gz> [OPTIONS]
       ${SCRIPT_NAME} --apk <split.apk|splits.tar.gz> [OPTIONS]

Required:
  --binary <file>       Official split APK or tar.gz of split APKs (alias: --apk)
  --github-token <tok>  GitHub PAT (read:packages) — or set GITHUB_TOKEN env var

Options:
  --version <ver>       App version (auto-detected from APK if omitted)
  --arch <abi>          Target ABI for bundletool (default: arm64-v8a)
  --type <type>         Accepted for ABS compatibility; unused
  --github-user <user>  GPR username (default: walletscrutiny; or GITHUB_USER)
  --tag <ref>           Override git tag resolution
  --cleanup             Remove work directory after completion
  --script-version      Print version and exit
  --help                Show this help

Exit codes: 0=reproducible  1=not_reproducible/ftbfs  2=invalid params
EOF
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)    VERSION="${2:-}"; shift ;;
            --apk|--binary) APK_INPUT="${2:-}"; shift ;;
            --arch)       ARCH="${2:-}"; shift ;;
            --type)       TYPE="${2:-}"; shift; log_warn "--type '${TYPE}' accepted but unused" ;;
            --github-token) github_token="${2:-}"; shift ;;
            --github-user)  github_user="${2:-}"; shift ;;
            --tag)        REQUESTED_TAG="${2:-}"; shift ;;
            --cleanup)    should_cleanup=true ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)    usage; exit "${EXIT_SUCCESS}" ;;
            *)            log_warn "Ignoring unknown argument: $1" ;;
        esac
        shift
    done

    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Do not run as root."; echo "Exit code: ${EXIT_INVALID}"
        exit "${EXIT_INVALID}"
    fi

    [[ -z "${github_token}" && -n "${GITHUB_TOKEN:-}" ]] && github_token="${GITHUB_TOKEN}"
    [[ "${github_user}" == "walletscrutiny" && -n "${GITHUB_USER:-}" ]] && github_user="${GITHUB_USER}"

    if [[ -z "${APK_INPUT}" ]]; then
        echo "[ERROR] --binary <split.apk|splits.tar.gz> is required."
        echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"
    fi
    if [[ ! -f "${APK_INPUT}" ]]; then
        echo "[ERROR] --binary file not found: ${APK_INPUT}"
        echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"
    fi
    [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"

    ARCH="${ARCH:-arm64-v8a}"
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *) log_warn "Unrecognized arch '${ARCH}'; defaulting to arm64-v8a"; ARCH="arm64-v8a" ;;
    esac

    if [[ -z "${github_token}" ]]; then
        cat > "${EXEC_DIR}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  GitHub token not provided. Gem Wallet depends on trustwallet/wallet-core
  from maven.pkg.github.com/trustwallet/wallet-core (private GitHub Package).
  Pass --github-token <PAT> or set GITHUB_TOKEN (read:packages scope).
EOF
        RESULT_DONE=true
        echo "[ERROR] GITHUB_TOKEN required."; echo "Exit code: ${EXIT_FAILED}"
        exit "${EXIT_FAILED}"
    fi

    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
    log_info "Work directory: ${WORK_DIR}"
    log_info "Arch: ${ARCH}"
    log_info "APK input: ${APK_INPUT}"
}

ensure_build_image() {
    if ${CONTAINER_CMD} image inspect "${GEMWALLET_BUILD_IMAGE}" >/dev/null 2>&1; then
        log_info "Build image ${GEMWALLET_BUILD_IMAGE} already exists."
        return 0
    fi
    log_info "Building ${GEMWALLET_BUILD_IMAGE} (~10-20 min)..."
    local dockerfile_path="${WORK_DIR}/Dockerfile.build"
    cat > "${dockerfile_path}" <<'DOCKERFILE_END'
FROM docker.io/library/gradle:jdk17
USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/platform-tools:${PATH}
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
        git curl wget unzip ca-certificates python3 apktool \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fL \
        "https://github.com/casey/just/releases/download/1.45.0/just-1.45.0-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/just.tar.gz && \
    tar -xzf /tmp/just.tar.gz -C /tmp just && \
    mv /tmp/just /usr/local/bin/just && rm -f /tmp/just.tar.gz
RUN mkdir -p "${ANDROID_HOME}" /root/.android && \
    curl -fL \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -o /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d "${ANDROID_HOME}" && rm -f /tmp/sdk.zip
RUN yes | ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} --licenses > /dev/null 2>&1 && \
    ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} \
        "platform-tools" "platforms;android-35" "platforms;android-37" \
        "build-tools;35.0.0" "ndk;28.1.13356709"
RUN wget -q \
        "https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar" \
        -O /usr/local/lib/bundletool.jar && \
    printf '#!/bin/bash\nexec java -jar /usr/local/lib/bundletool.jar "$@"\n' \
        > /usr/local/bin/bundletool && chmod +x /usr/local/bin/bundletool
CMD ["bash"]
DOCKERFILE_END
    ${CONTAINER_CMD} build --no-cache --tag "${GEMWALLET_BUILD_IMAGE}" \
        --file "${dockerfile_path}" "${WORK_DIR}"
    log_pass "Build image ${GEMWALLET_BUILD_IMAGE} ready."
}

resolve_git_tag() {
    local version="$1"
    log_info "Resolving git tag for ${version}..."
    for candidate in "${version}" "v${version}"; do
        if ${CONTAINER_CMD} run --rm "${WS_CONTAINER}" \
                git ls-remote --tags --exit-code "${REPO_URL}" \
                "refs/tags/${candidate}" >/dev/null 2>&1; then
            log_info "Found tag: ${candidate}"
            GIT_TAG="${candidate}"; return 0
        fi
    done
    log_fail "No tag found for ${version}"; return 1
}

create_device_spec() {
    cat > "$1" <<EOF
{
  "supportedAbis": ["$2"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 31
}
EOF
}

extract_split_apks_from_aab() {
    local aab_path="$1" device_spec_path="$2" output_dir="$3"
    mkdir -p "${output_dir}"
    local aab_rel device_spec_rel apks_rel output_rel
    aab_rel="${aab_path#"${WORK_DIR}/"}"
    device_spec_rel="${device_spec_path#"${WORK_DIR}/"}"
    apks_rel="built-splits.apks"
    output_rel="${output_dir#"${WORK_DIR}/"}"
    log_info "Running bundletool to extract splits from $(basename "${aab_path}")..."
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work \
        "${GEMWALLET_BUILD_IMAGE}" bash -c "
            set -euo pipefail
            java -jar /usr/local/lib/bundletool.jar build-apks \
                --bundle='${aab_rel}' --output='${apks_rel}' \
                --device-spec='${device_spec_rel}' --mode=default --overwrite 2>&1
            mkdir -p '${output_rel}'
            unzip -qq -o '${apks_rel}' -d '${output_rel}' 2>&1 || true
            chmod -R a+rwX '${output_rel}' 2>/dev/null || true
        "
    local splits_subdir="${output_dir}/splits"
    [[ -f "${splits_subdir}/base-master.apk" ]] && \
        mv "${splits_subdir}/base-master.apk" "${splits_subdir}/base.apk"
    while IFS= read -r split_apk; do
        [[ -f "${split_apk}" ]] || continue
        local split_name="${split_apk##*/}"
        [[ "${split_name}" == "base-master.apk" ]] && continue
        mv "${split_apk}" "${splits_subdir}/split_config.${split_name#base-}"
    done < <(find "${splits_subdir}" -maxdepth 1 -name "base-*.apk" 2>/dev/null || true)
    local split_count
    split_count="$(find "${output_dir}" -name "*.apk" 2>/dev/null | wc -l)"
    log_info "Extracted ${split_count} split APK(s)"
}

unzip_apk_in_container() {
    local apk_rel out_rel
    apk_rel="${1#"${WORK_DIR}/"}"
    out_rel="${2#"${WORK_DIR}/"}"
    ws_exec "mkdir -p '${out_rel}' && unzip -qq '${apk_rel}' -d '${out_rel}' 2>/dev/null || true && chmod -R a+rwX '${out_rel}' 2>/dev/null || true"
}

compare_split_apks() {
    local official_apk="$1" built_apk="$2" split_label="$3"
    local results_dir="${WORK_DIR}/comparison"
    mkdir -p "${results_dir}"
    log_info "Comparing split: ${split_label}"
    local official_unzip="${results_dir}/official_${split_label}"
    local built_unzip="${results_dir}/built_${split_label}"
    local diff_file="${results_dir}/diff_${split_label}.txt"
    unzip_apk_in_container "${official_apk}" "${official_unzip}"
    unzip_apk_in_container "${built_apk}"    "${built_unzip}"
    local official_rel="${official_unzip#"${WORK_DIR}/"}"
    local built_rel="${built_unzip#"${WORK_DIR}/"}"
    local diff_rel="${diff_file#"${WORK_DIR}/"}"
    ws_exec "diff -r '${official_rel}' '${built_rel}' > '${diff_rel}' 2>&1 || true"
    local non_meta_count=0 total_lines=0
    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        non_meta_count="$(grep -E '^Only in |^Files ' "${diff_file}" \
            | grep -cvE \
              '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' \
            || echo 0)"
    fi
    TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
    log_info "  ${split_label}: ${non_meta_count} non-META-INF diff(s) (${total_lines} total lines)"
    if [[ -s "${diff_file}" ]]; then
        log_info "  First 5 lines (full diff: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
        [[ "${total_lines}" -gt 5 ]] && log_info "    ... (${total_lines} total)"
    else
        log_pass "  ${split_label}: no differences"
    fi
}

print_results_block() {
    local verdict="$1"
    local apk_path="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}"
    local version_name version_code signer app_hash commit tag_info
    version_name="$(container_aapt_version "${apk_path}" "versionName" || true)"
    version_code="$(container_aapt_version "${apk_path}" "versionCode" || true)"
    signer="$(container_signer "${apk_path}" || true)"
    app_hash="$(container_sha256 "${apk_path}" || true)"
    commit=""; tag_info=""
    [[ -f "${WORK_DIR}/built-output/commit.txt" ]] && commit="$(cat "${WORK_DIR}/built-output/commit.txt")"
    [[ -f "${WORK_DIR}/built-output/tag_verify.txt" ]] && tag_info="$(cat "${WORK_DIR}/built-output/tag_verify.txt")"
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
    local results_dir="${WORK_DIR}/comparison" shown=0
    if [[ -d "${results_dir}" ]]; then
        for diff_file in "${results_dir}"/diff_*.txt; do
            [[ -f "${diff_file}" ]] || continue
            local split_label total_lines
            split_label="$(basename "${diff_file}" .txt)"
            if [[ -s "${diff_file}" ]]; then
                total_lines="$(wc -l < "${diff_file}")"
                echo "  ${split_label} (first 5 lines — full diff: ${diff_file}):"
                head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
                [[ "${total_lines}" -gt 5 ]] && echo "    ... (${total_lines} lines total)"
            else
                echo "  ${split_label}: no differences"
            fi
            shown=$(( shown + 1 ))
        done
    fi
    [[ "${shown}" -eq 0 ]] && echo "  (no diff files found)"
    echo ""
    echo "Revision, tag (and its signature):"
    [[ -n "${tag_info}" ]] && echo "${tag_info}" || echo "  (tag verification not available)"
    echo "===== End Results ====="
    echo ""
    if [[ "${should_cleanup}" != "true" ]]; then
        echo "Work directory: ${WORK_DIR}"
        echo "Diff files:     ${WORK_DIR}/comparison/"
        echo ""
        echo "For deeper analysis:"
        echo "  diffoscope '${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK:-base.apk}")' \\"
        echo "             '${WORK_DIR}/built-split-apks/splits/$(basename "${OFFICIAL_APK:-base.apk}")'"
    fi
}

prepare() {
    log_info "=== PREPARE ==="
    chmod -R a+rwX "${WORK_DIR}" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/official-split-apks" "${WORK_DIR}/built-output"
    chmod 777 "${WORK_DIR}/built-output"

    # Detect tar.gz by magic bytes (1f 8b) so extension doesn't matter
    local magic
    magic="$(od -An -N2 -tx1 "${APK_INPUT}" 2>/dev/null | tr -d ' \n')"
    if [[ "${magic}" == "1f8b" ]]; then
        log_info "Input is a tar.gz; extracting APKs..."
        local extract_tmp="${WORK_DIR}/archive-extracted"
        mkdir -p "${extract_tmp}"
        tar -xzf "${APK_INPUT}" -C "${extract_tmp}"
        find "${extract_tmp}" -name "*.apk" \
            -exec cp {} "${WORK_DIR}/official-split-apks/" \;
        rm -rf "${extract_tmp}"
        local apk_count
        apk_count="$(find "${WORK_DIR}/official-split-apks" -name "*.apk" | wc -l)"
        if [[ "${apk_count}" -eq 0 ]]; then
            generate_error_yaml "ftbfs" "No APKs found in provided archive."
            RESULT_DONE=true; exit "${EXIT_FAILED}"
        fi
        log_info "${apk_count} APK(s) extracted."
        local base_apk="${WORK_DIR}/official-split-apks/base.apk"
        local arch_split="${WORK_DIR}/official-split-apks/split_config.${ARCH//-/_}.apk"
        OFFICIAL_BASE_APK="${base_apk}"
        [[ -f "${OFFICIAL_BASE_APK}" ]] || \
            OFFICIAL_BASE_APK="$(find "${WORK_DIR}/official-split-apks" -name "*.apk" | head -1)"
        if [[ -f "${arch_split}" ]]; then
            OFFICIAL_APK="${arch_split}"
        else
            OFFICIAL_APK="${OFFICIAL_BASE_APK}"
        fi
        log_info "Official APK for comparison: $(basename "${OFFICIAL_APK}")"
    else
        local original_name canonical_name
        original_name="$(basename "${APK_INPUT}")"
        canonical_name="$(canonicalize_split_apk_name "${original_name}")"
        cp "${APK_INPUT}" "${WORK_DIR}/official-split-apks/${canonical_name}"
        [[ "${original_name}" != "${canonical_name}" ]] && \
            log_info "Normalized: ${original_name} -> ${canonical_name}"
        OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"
    fi

    if [[ -z "${VERSION}" ]]; then
        log_info "Auto-detecting version from APK metadata..."
        VERSION="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
        if [[ -z "${VERSION}" || "${VERSION}" == "null" ]]; then
            generate_error_yaml "ftbfs" \
                "Could not auto-detect versionName. Pass --version explicitly."
            RESULT_DONE=true; exit "${EXIT_FAILED}"
        fi
        log_info "Version detected: ${VERSION}"
        VERSION_SAFE="${VERSION}"
        local new_work_dir
        new_work_dir="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
        if [[ "${new_work_dir}" != "${WORK_DIR}" ]]; then
            rm -rf "${new_work_dir}"
            mv "${WORK_DIR}" "${new_work_dir}"
            WORK_DIR="${new_work_dir}"
            OFFICIAL_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK}")"
            OFFICIAL_BASE_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_BASE_APK}")"
            log_info "Work directory: ${WORK_DIR}"
        fi
    fi

    create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"
    log_pass "Preparation complete: ${WORK_DIR}"
}

build_image() {
    log_info "=== BUILD IMAGE ==="
    ensure_build_image
}

build() {
    log_info "=== BUILD ==="
    GIT_TAG="${REQUESTED_TAG:-}"
    if [[ -z "${GIT_TAG}" ]]; then
        if ! resolve_git_tag "${VERSION_SAFE}"; then
            generate_comparison_yaml "ftbfs" \
                "Tag not found for ${VERSION_SAFE}. Tried: ${VERSION_SAFE}, v${VERSION_SAFE}."
            RESULT_DONE=true
            echo "Exit code: ${EXIT_FAILED}"; exit "${EXIT_FAILED}"
        fi
    fi
    log_info "Git tag: ${GIT_TAG}"
    log_info "Cloning + building (may take 20-60 min)..."
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
            git clone --depth 1 --recursive --branch '${GIT_TAG}' '${REPO_URL}' /workspace/app
            cd /workspace/app
            git rev-parse HEAD > /workspace/commit.txt
            tag_type=\$(git cat-file -t 'refs/tags/${GIT_TAG}' 2>/dev/null || echo 'missing')
            printf 'TAG_TYPE=%s\n' \"\${tag_type}\" > /workspace/tag_verify.txt
            if [ \"\${tag_type}\" = 'tag' ]; then
                git tag -v '${GIT_TAG}' >> /workspace/tag_verify.txt 2>&1 || \
                    printf 'GPG verify skipped\n' >> /workspace/tag_verify.txt
            elif [ \"\${tag_type}\" = 'commit' ]; then
                printf 'LIGHTWEIGHT_TAG\n' >> /workspace/tag_verify.txt
            fi
            printf '%s\n' '---COMMIT---' >> /workspace/tag_verify.txt
            git verify-commit HEAD >> /workspace/tag_verify.txt 2>&1 || true
            cd /workspace/app/android
            printf 'gpr.username=${github_user}\ngpr.token=${github_token}\n' \
                > /workspace/app/android/local.properties
            printf 'org.gradle.jvmargs=-Xmx8g -Xms2g -XX:MaxMetaspaceSize=512m\n' \
                >> /workspace/app/android/gradle.properties
            SKIP_SIGN=true ./gradlew :app:bundleGoogleRelease \
                --no-daemon --stacktrace -Dorg.gradle.workers.max=4
            chmod -R a+rwX /workspace 2>/dev/null || true
        "
    chmod -R a+rwX "${WORK_DIR}" 2>/dev/null || true
    local aab_path
    aab_path="$(find "${WORK_DIR}/built-output/app/android" \
        -name "*.aab" -path "*/outputs/bundle/*" ! -path "*/intermediates/*" \
        2>/dev/null | head -1)"
    if [[ -z "${aab_path}" ]]; then
        log_fail "Built AAB not found after :app:bundleGoogleRelease"
        find "${WORK_DIR}/built-output" -name "*.aab" 2>/dev/null | head -10 || true
        exit "${EXIT_FAILED}"
    fi
    BUILT_AAB="${aab_path}"
    log_pass "Built AAB: ${BUILT_AAB}"
}

extract_and_compare() {
    log_info "=== EXTRACT AND COMPARE ==="
    TOTAL_DIFFS=0
    local built_splits_dir="${WORK_DIR}/built-split-apks"
    extract_split_apks_from_aab \
        "${BUILT_AAB}" "${WORK_DIR}/device-spec.json" "${built_splits_dir}"
    local built_split
    built_split="$(resolve_built_split_apk "${OFFICIAL_APK}" "${built_splits_dir}/splits")" || {
        log_fail "No matching built split for: $(basename "${OFFICIAL_APK}")"
        find "${built_splits_dir}" -name "*.apk" 2>/dev/null | while IFS= read -r f; do echo "  ${f}"; done
        exit "${EXIT_FAILED}"
    }
    log_info "Official: $(basename "${OFFICIAL_APK}")"
    log_info "Built:    $(basename "${built_split}")"
    local split_label
    split_label="$(basename "${OFFICIAL_APK}" .apk)"
    compare_split_apks "${OFFICIAL_APK}" "${built_split}" "${split_label}"
}

result() {
    log_info "=== RESULT ==="
    local verdict
    if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
        verdict="reproducible"; log_pass "VERDICT: REPRODUCIBLE"
    else
        verdict="not_reproducible"
        log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} non-META-INF difference(s))"
    fi
    local split_name diff_path notes
    split_name="$(basename "${OFFICIAL_APK:-base.apk}")"
    diff_path="${WORK_DIR}/comparison/diff_$(basename "${OFFICIAL_APK:-base.apk}" .apk).txt"
    notes="Split: ${split_name} vs built split from AAB (tag: ${GIT_TAG}).
  Build: SKIP_SIGN=true ./gradlew :app:bundleGoogleRelease --no-daemon.
  Non-META-INF diffs: ${TOTAL_DIFFS}.
  AGP 9.2.x R8 caveat: diffs in classes*.dex/baseline.prof may be pg-map-id
  non-determinism — see android/reproducible/ in gemwalletcom/wallet before
  concluding not_reproducible. GPR token required (trustwallet/wallet-core on GPR only)."
    [[ "${verdict}" == "not_reproducible" ]] && notes="${notes}
  Diff: ${diff_path}"
    generate_comparison_yaml "${verdict}" "${notes}"
    print_results_block "${verdict}"
    RESULT_DONE=true
    if [[ "${should_cleanup}" == "true" ]]; then
        log_info "Cleaning up ${WORK_DIR}..."; rm -rf "${WORK_DIR}"
    fi
    if [[ "${verdict}" == "reproducible" ]]; then
        echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}"
    else
        echo "Exit code: ${EXIT_FAILED}"; exit "${EXIT_FAILED}"
    fi
}

main() {
    log_info "Starting ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    log_warn "Provided as-is. Review before running."
    detect_container_runtime
    parse_arguments "$@"
    prepare
    build_image
    build
    extract_and_compare
    result
}

main "$@"
