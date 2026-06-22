#!/bin/bash
# gemwallet_build.sh v0.2.23 — Gem Wallet Android reproducible build verification
# Organization: WalletScrutiny.com | App: com.gemwallet.android
# Repo: https://github.com/gemwalletcom/wallet | License: MIT. No warranty.
# --github-token optional; TrustWallet wallet-core GPR dependency remains.
# R8 caveat: classes*.dex/baseline.prof diffs may be non-deterministic pg-map-id.
# --binary: single split APK or tar.gz of all splits.

set -euo pipefail

EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"
readonly SCRIPT_VERSION="v0.2.24"
readonly SCRIPT_NAME="gemwallet_build.sh"
readonly APP_ID="com.gemwallet.android"
readonly REPO_URL="https://github.com/gemwalletcom/wallet.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly GEMWALLET_BUILD_IMAGE="gemwallet_build_env:8"
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
TOTAL_DIFFS=0
RESOURCES_ARSC_NOTES=""
DEVICE_SPEC_INPUT=""
DEVICE_SDK_INPUT=""

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
    local status="$1" notes="${2:-(no details)}"
    write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  ${notes}"
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
        log_warn "Failed (${exit_code}); work dir preserved: ${WORK_DIR}"
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
        generate_error_yaml "ftbfs" "Neither podman nor docker found."
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
                        sed -n "s/^[[:space:]]*versionName:[[:space:]]*'"'"'\([^'"'"']*\)'"'"'/\1/p" \
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

Options:
  --version <ver>       App version (auto-detected from APK if omitted)
  --arch <abi>          Target ABI for bundletool (default: arm64-v8a)
  --type <type>         Accepted for ABS compatibility; unused
  --device-sdk <api>   Device API level for bundletool (inferred from SDK splits or 32)
  --device-spec <json>  Override bundletool device spec JSON; default: derived from splits
  --github-token <tok>  GitHub PAT (read:packages) — optional for this monorepo
  --github-user <user>  GPR username (default: walletscrutiny; or GITHUB_USER env)
  --tag <ref>           Override git tag resolution
  --cleanup             Remove work directory after completion
  --script-version      Print version and exit
  --help                Show this help

Exit codes: 0=reproducible  1=not_reproducible/ftbfs  2=invalid params
EOF
}

die_invalid() { generate_error_yaml "ftbfs" "$1"; RESULT_DONE=true; echo "[ERROR] $1"; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"; }

require_arg() {
    local opt="$1" value="${2-}"
    [[ -z "${value}" || "${value}" == --* ]] && die_invalid "${opt} requires a value" || true
}

handle_early_exit_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h) usage; exit "${EXIT_SUCCESS}" ;;
        esac
        shift
    done
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)      require_arg "$1" "${2-}"; VERSION="$2"; shift ;;
            --apk|--binary) require_arg "$1" "${2-}"; APK_INPUT="$2"; shift ;;
            --arch)         require_arg "$1" "${2-}"; ARCH="$2"; shift ;;
            --type)         require_arg "$1" "${2-}"; TYPE="$2"; shift; log_warn "--type '${TYPE}' accepted but unused" ;;
            --github-token) require_arg "$1" "${2-}"; github_token="$2"; shift ;;
            --device-sdk)   require_arg "$1" "${2-}"; DEVICE_SDK_INPUT="$2"; shift ;;
            --github-user)  require_arg "$1" "${2-}"; github_user="$2"; shift ;;
            --device-spec)  require_arg "$1" "${2-}"; DEVICE_SPEC_INPUT="$2"; shift ;;
            --tag)          require_arg "$1" "${2-}"; REQUESTED_TAG="$2"; shift ;;
            --cleanup)      should_cleanup=true ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)      usage; exit "${EXIT_SUCCESS}" ;;
            *)              log_warn "Ignoring unknown argument: $1" ;;
        esac
        shift
    done

    [[ "$(id -u)" -eq 0 ]] && die_invalid "Do not run as root"

    [[ -z "${github_token}" && -n "${GITHUB_TOKEN:-}" ]] && github_token="${GITHUB_TOKEN}"
    [[ "${github_user}" == "walletscrutiny" && -n "${GITHUB_USER:-}" ]] && github_user="${GITHUB_USER}"

    [[ -z "${APK_INPUT}" ]] && die_invalid "--binary <split.apk|splits.tar.gz> is required"
    [[ ! -f "${APK_INPUT}" ]] && die_invalid "--binary file not found: ${APK_INPUT}"
    [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"

    ARCH="${ARCH:-arm64-v8a}"
    case "${ARCH}" in

        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *) log_warn "Unrecognized arch '${ARCH}'; defaulting to arm64-v8a"; ARCH="arm64-v8a" ;;
    esac

    if [[ -z "${github_token}" ]]; then
        log_warn "GITHUB_TOKEN not set; TrustWallet wallet-core GPR dependency remains — pass --github-token if Gradle fails."
    fi

    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"

    if [[ -n "${DEVICE_SPEC_INPUT}" ]]; then
        [[ "${DEVICE_SPEC_INPUT}" != /* ]] && DEVICE_SPEC_INPUT="${EXEC_DIR}/${DEVICE_SPEC_INPUT}"
        [[ ! -f "${DEVICE_SPEC_INPUT}" ]] && die_invalid "--device-spec file not found: ${DEVICE_SPEC_INPUT}"
    fi
    [[ -n "${DEVICE_SDK_INPUT}" && ! "${DEVICE_SDK_INPUT}" =~ ^[0-9]+$ ]] && die_invalid "--device-sdk must be an integer: ${DEVICE_SDK_INPUT}"
    if [[ -n "${DEVICE_SPEC_INPUT}" && -n "${DEVICE_SDK_INPUT}" ]]; then
        log_warn "--device-sdk ignored because --device-spec was provided"
    fi
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
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/28.1.13356709
ENV ANDROID_NDK_ROOT=/opt/android-sdk/ndk/28.1.13356709
ENV PATH=${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/platform-tools:${PATH}
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
        git curl wget unzip ca-certificates python3 apktool \
        build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fL \
        "https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/just.tar.gz && \
    tar -xzf /tmp/just.tar.gz -C /tmp just && \
    mv /tmp/just /usr/local/bin/just && rm -f /tmp/just.tar.gz
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain 1.94.1 --no-modify-path
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
RUN cargo install cargo-ndk@4.1.2 --locked
RUN mkdir -p "${ANDROID_HOME}" /root/.android && \
    curl -fL \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -o /tmp/sdk.zip && \
    unzip -q /tmp/sdk.zip -d "${ANDROID_HOME}" && rm -f /tmp/sdk.zip
RUN yes | ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} --licenses > /dev/null 2>&1 && \
    ${ANDROID_HOME}/cmdline-tools/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} \
        "platform-tools" "platforms;android-35" \
        "build-tools;35.0.0" "ndk;28.1.13356709" \
        "cmdline-tools;latest"
RUN yes | ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} --licenses > /dev/null 2>&1 && \
    ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager \
        --sdk_root=${ANDROID_HOME} --channel=3 \
        "platforms;android-CinnamonBun" "build-tools;37.0.0" || \
    { echo "[ERROR] platforms;android-CinnamonBun or build-tools;37.0.0 not available"; exit 1; }
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
    local version="$1" output
    log_info "Resolving git tag for ${version}..."
    for candidate in "${version}" "v${version}"; do
        output=$(${CONTAINER_CMD} run --rm "${GEMWALLET_BUILD_IMAGE}" \
            git ls-remote --tags --exit-code "${REPO_URL}" \
            "refs/tags/${candidate}" 2>&1) && {
            log_info "Found tag: ${candidate}"
            GIT_TAG="${candidate}"; return 0
        }
    done
    log_fail "No tag found for ${version}. Last resolver output:"
    printf '%s\n' "${output}" >&2
    return 1
}

derive_device_spec() {
    local spec_path="$1" arch="$2"
    local splits_dir="${WORK_DIR}/official-split-apks"

    local sdk_ver="${DEVICE_SDK_INPUT:-}"
    if [[ -n "${sdk_ver}" ]]; then
        log_info "Device spec: sdkVersion=${sdk_ver} (from --device-sdk)"
    else
        local sdk_split sdk_name
        sdk_split="$(find "${splits_dir}" -name "split_config.sdk*.apk" 2>/dev/null | sort | head -1 || true)"
        if [[ -n "${sdk_split}" ]]; then
            sdk_name="${sdk_split##*/split_config.}"; sdk_name="${sdk_name%.apk}"
            if [[ "${sdk_name}" =~ ^sdk[_-]?([0-9]+)$ ]]; then
                sdk_ver="${BASH_REMATCH[1]}"
                log_info "Device spec: sdkVersion=${sdk_ver} (from official SDK split ${sdk_name})"
            fi
        fi
    fi
    if [[ -z "${sdk_ver}" ]]; then
        sdk_ver=32
        log_warn "Device spec: sdkVersion not inferred — using default ${sdk_ver}; pass --device-sdk or --device-spec"
    fi

    local locales=()
    while IFS= read -r f; do
        local name="${f##*/split_config.}"; name="${name%.apk}"
        [[ "${name}" =~ ^(arm64_v8a|armeabi_v7a|x86_64|x86)$ ]] && continue
        [[ "${name}" =~ ^sdk[_-]?[0-9]+$ ]] && continue
        [[ "${name}" =~ ^([0-9]+dpi|ldpi|mdpi|hdpi|xhdpi|xxhdpi|xxxhdpi|nodpi|tvdpi|anydpi)$ ]] && continue
        locales+=("\"${name}\"")
    done < <(find "${splits_dir}" -name "split_config.*.apk" 2>/dev/null | sort)
    local locales_json
    if [[ "${#locales[@]}" -gt 0 ]]; then
        locales_json="$(printf '%s,' "${locales[@]}" | sed 's/,$//')"
        log_info "Device spec: locales=[${locales_json}]"
    else
        locales_json='"en"'
        log_warn "Device spec: no locale splits found — using [\"en\"]"
    fi

    local density=480
    local density_split
    density_split="$(find "${splits_dir}" -name "split_config.*dpi*.apk" 2>/dev/null | head -1 || true)"
    if [[ -n "${density_split}" ]]; then
        local dname="${density_split##*/split_config.}"; dname="${dname%.apk}"
        case "${dname}" in
            ldpi)    density=120 ;;
            mdpi)    density=160 ;;
            hdpi)    density=240 ;;
            xhdpi)   density=320 ;;
            xxhdpi)  density=480 ;;
            xxxhdpi) density=640 ;;
            *dpi)    local n="${dname%dpi}"; [[ "${n}" =~ ^[0-9]+$ ]] && density="${n}" || density=480 ;;
        esac
        log_info "Device spec: density=${density} (from ${dname})"
    else
        log_warn "Device spec: no density split — using default ${density}"
    fi

    cat > "${spec_path}" <<EOF
{
  "supportedAbis": ["${arch}"],
  "supportedLocales": [${locales_json}],
  "screenDensity": ${density},
  "sdkVersion": ${sdk_ver}
}
EOF
    log_info "Device spec written: ${spec_path}"
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
            if ! unzip -qq -o '${apks_rel}' -d '${output_rel}' 2>&1; then
                echo 'ERROR: Failed to unzip bundletool output archive: ${apks_rel}' >&2
                exit 1
            fi
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
    if [[ "${split_count}" -eq 0 ]]; then
        log_fail "bundletool extraction produced no split APKs"
        exit "${EXIT_FAILED}"
    fi
    log_info "Extracted ${split_count} split APK(s)"
}

unzip_apk_in_container() {
    local apk_rel out_rel
    apk_rel="${1#"${WORK_DIR}/"}"
    out_rel="${2#"${WORK_DIR}/"}"
    ws_exec "mkdir -p '${out_rel}' && { unzip -qq '${apk_rel}' -d '${out_rel}' 2>/dev/null; rc=\$?; [ \$rc -le 1 ] || exit \$rc; }; chmod -R a+rwX '${out_rel}' 2>/dev/null || true"
    local file_count
    file_count="$(find "${WORK_DIR}/${out_rel}" -type f 2>/dev/null | wc -l)"
    if [[ "${file_count}" -eq 0 ]]; then
        log_fail "APK extraction produced no files: ${1}"
        exit "${EXIT_FAILED}"
    fi
}

# _semantic_verdict name off_sz built_sz diff_lines filtered_log ok_msg
# Modifies caller's non_meta_count (bash scope). Returns: 0=filtered 1=empty 2=counted.
_semantic_verdict() {
    local _n="$1" _os="$2" _bs="$3" _dl="$4" _fl="$5" _ok="$6"
    if [[ "${_os}" -eq 0 || "${_bs}" -eq 0 ]]; then
        log_warn "  ${_n}: dump empty — counting conservatively"
        echo "COUNTED [${_n} dump empty — conservative]: ${split_label}" >> "${_fl}"
        non_meta_count=$(( non_meta_count + 1 ))
        return 1
    fi
    if [[ "${_dl}" -eq 0 ]]; then
        log_info "  ${_n}: ${_ok} — filter confirmed"
        echo "FILTERED [${_ok} — ${_n}]: ${split_label}" >> "${_fl}"
        return 0
    fi
    log_warn "  ${_n}: ${_dl}-line diff — real diff"
    echo "COUNTED [${_n} ${_dl} semantic diff lines]: ${split_label}" >> "${_fl}"
    non_meta_count=$(( non_meta_count + 1 ))
    return 2
}

compare_split_apks() {
    local official_apk="$1" built_apk="$2" split_label="$3"
    local results_dir="${WORK_DIR}/comparison"
    mkdir -p "${results_dir}"
    local off_apk_rel built_apk_rel
    off_apk_rel="${official_apk#"${WORK_DIR}/"}"
    built_apk_rel="${built_apk#"${WORK_DIR}/"}"
    cat > "${results_dir}/play_strip.awk" << 'AWKEOF'
BEGIN{s="normal"}
/E: meta-data/{m=$0;s="got_meta";next}
s=="got_meta"{if(/com\.android\.stamp\.|com\.android\.vending\.derived\./){s="skip_value"}else{print m;print;s="normal"};next}
s=="skip_value"{s="normal";next}
{s="normal";print}
AWKEOF
    log_info "Comparing split: ${split_label}"
    local official_unzip="${results_dir}/official_${split_label}"
    local built_unzip="${results_dir}/built_${split_label}"
    local diff_file="${results_dir}/diff_${split_label}.txt"
    local filtered_log="${results_dir}/filtered_${split_label}.txt"
    unzip_apk_in_container "${official_apk}" "${official_unzip}"
    unzip_apk_in_container "${built_apk}"    "${built_unzip}"
    local official_rel="${official_unzip#"${WORK_DIR}/"}"
    local built_rel="${built_unzip#"${WORK_DIR}/"}"
    local diff_rel="${diff_file#"${WORK_DIR}/"}"
    ws_exec "diff -r '${official_rel}' '${built_rel}' > '${diff_rel}' 2>&1; rc=\$?; [ \$rc -le 1 ] || exit \$rc"

    local non_meta_count=0 total_lines=0
    local manifest_filtered=false resources_arsc_found=false splits0_found=false
    local so_off_paths=() so_built_paths=() so_names=()
    > "${filtered_log}"

    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        while IFS= read -r _line; do
            case "${_line}" in
                *stamp-cert-sha256*)
                    echo "FILTERED [stamp-cert-sha256 Play artifact]: ${_line}" >> "${filtered_log}"
                    log_info "  Filtered: stamp-cert-sha256"
                    continue ;;
                'diff -r '*)
                    [[ "${_line}" == *"/META-INF/"* ]] && continue
                    ;;
                'Only in '*)
                    [[ "${_line}" == *": META-INF" ]] && continue
                    [[ "${_line}" == *"/META-INF:"* ]] && continue
                    [[ "${_line}" == *"/META-INF/"* ]] && continue
                    ;;
                'Files '*)
                    [[ "${_line}" == *"/META-INF/"* ]] && continue
                    ;;
                'Binary files '*)
                    [[ "${_line}" =~ '/META-INF/' ]] && continue
                    if [[ "${_line}" =~ '/AndroidManifest.xml' ]]; then
                        echo "DEFERRED [AndroidManifest.xml semantic check pending]: ${_line}" >> "${filtered_log}"
                        log_info "  Deferred: AndroidManifest.xml (Play stamp + bundletool metadata)"
                        manifest_filtered=true
                        continue
                    fi
                    if [[ "${_line}" =~ '/res/xml/splits0.xml' ]]; then
                        splits0_found=true
                        continue
                    fi
                    if [[ "${_line}" =~ '/resources.arsc' ]]; then
                        resources_arsc_found=true
                        continue
                    fi
                    if [[ "${_line}" == *'.so and '* ]]; then
                        local _off_so _built_so
                        _off_so="$(echo "${_line}" | awk '{print $3}')"
                        _built_so="$(echo "${_line}" | awk '{print $5}')"
                        so_off_paths+=("${WORK_DIR}/${_off_so}")
                        so_built_paths+=("${WORK_DIR}/${_built_so}")
                        so_names+=("$(basename "${_off_so}")")
                    fi
                    ;;
                *) continue ;;
            esac
            echo "COUNTED [raw diff]: ${_line}" >> "${filtered_log}"
            non_meta_count=$(( non_meta_count + 1 ))
        done < "${diff_file}"
    fi

    if [[ "${resources_arsc_found}" == "true" ]]; then
        log_info "  resources.arsc in diff — running aapt2 semantic check..."
        local res_rel="${results_dir#"${WORK_DIR}/"}"
        local aapt2_off_rel="${res_rel}/aapt2_off_${split_label}.txt"
        local aapt2_built_rel="${res_rel}/aapt2_built_${split_label}.txt"
        local aapt2_diff_rel="${res_rel}/aapt2_diff_resources_${split_label}.txt"
        ws_exec "aapt2 dump resources '${off_apk_rel}' > '${aapt2_off_rel}' 2>/dev/null || aapt dump resources '${off_apk_rel}' > '${aapt2_off_rel}' 2>/dev/null || true"
        ws_exec "aapt2 dump resources '${built_apk_rel}' > '${aapt2_built_rel}' 2>/dev/null || aapt dump resources '${built_apk_rel}' > '${aapt2_built_rel}' 2>/dev/null || true"
        local aapt2_off_sz aapt2_built_sz aapt2_diff_lines=0
        aapt2_off_sz="$(wc -c < "${WORK_DIR}/${aapt2_off_rel}" 2>/dev/null || echo 0)"
        aapt2_built_sz="$(wc -c < "${WORK_DIR}/${aapt2_built_rel}" 2>/dev/null || echo 0)"
        if [[ "${aapt2_off_sz}" -gt 0 && "${aapt2_built_sz}" -gt 0 ]]; then
            ws_exec "diff '${aapt2_off_rel}' '${aapt2_built_rel}' > '${aapt2_diff_rel}' 2>/dev/null || true"
            aapt2_diff_lines="$(wc -l < "${WORK_DIR}/${aapt2_diff_rel}" 2>/dev/null || echo 1)"
        fi
        local _rc=0
        _semantic_verdict "resources.arsc" "${aapt2_off_sz}" "${aapt2_built_sz}" "${aapt2_diff_lines}" "${filtered_log}" "aapt2 semantic identical" || _rc=$?
        case ${_rc} in
            0) RESOURCES_ARSC_NOTES+="${split_label}: binary differs, aapt2 identical. " ;;
            1) RESOURCES_ARSC_NOTES+="${split_label}: aapt2 dump empty; counted. " ;;
            2) RESOURCES_ARSC_NOTES+="${split_label}: aapt2 diff ${aapt2_diff_lines} lines. " ;;
        esac
    fi

    if [[ "${splits0_found}" == "true" ]]; then
        log_info "  res/xml/splits0.xml in diff — verifying locale alias canonicalization..."
        local s0_rel="${results_dir#"${WORK_DIR}/"}"
        local s0_off="${s0_rel}/splits0_off_${split_label}.txt"
        local s0_built="${s0_rel}/splits0_built_${split_label}.txt"
        local s0_norm_off="${s0_rel}/splits0_norm_off_${split_label}.txt"
        local s0_norm_built="${s0_rel}/splits0_norm_built_${split_label}.txt"
        local s0_diff="${s0_rel}/splits0_diff_${split_label}.txt"
        ws_exec "
            aapt dump xmltree '${off_apk_rel}' res/xml/splits0.xml > '${s0_off}' 2>/dev/null || true
            aapt dump xmltree '${built_apk_rel}' res/xml/splits0.xml > '${s0_built}' 2>/dev/null || true
            sed 's/config\.in/config.LOCALE_IN_ID/g; s/config\.id/config.LOCALE_IN_ID/g; s/config\.iw/config.LOCALE_IW_HE/g; s/config\.he/config.LOCALE_IW_HE/g' '${s0_off}' > '${s0_norm_off}' 2>/dev/null || true
            sed 's/config\.in/config.LOCALE_IN_ID/g; s/config\.id/config.LOCALE_IN_ID/g; s/config\.iw/config.LOCALE_IW_HE/g; s/config\.he/config.LOCALE_IW_HE/g' '${s0_built}' > '${s0_norm_built}' 2>/dev/null || true
            diff '${s0_norm_off}' '${s0_norm_built}' > '${s0_diff}' 2>/dev/null || true
        "
        local s0_off_sz s0_built_sz s0_diff_lines
        s0_off_sz="$(wc -c < "${WORK_DIR}/${s0_off}" 2>/dev/null || echo 0)"
        s0_built_sz="$(wc -c < "${WORK_DIR}/${s0_built}" 2>/dev/null || echo 0)"
        s0_diff_lines="$(wc -l < "${WORK_DIR}/${s0_diff}" 2>/dev/null || echo 1)"
        _semantic_verdict "splits0.xml" "${s0_off_sz}" "${s0_built_sz}" "${s0_diff_lines}" "${filtered_log}" "locale alias canonicalization (in→id, iw→he)" || true
        log_info "  splits0.xml normalized diff: ${WORK_DIR}/${s0_diff}"
    fi

    if [[ "${manifest_filtered}" == "true" ]]; then
        local mf_rel="${results_dir#"${WORK_DIR}/"}"
        local awk_rel="${mf_rel}/play_strip.awk"
        local xmltree_off_rel="${mf_rel}/xmltree_off_${split_label}.txt"
        local xmltree_built_rel="${mf_rel}/xmltree_built_${split_label}.txt"
        local xmltree_diff_rel="${mf_rel}/xmltree_diff_${split_label}.txt"
        ws_exec "
            aapt dump xmltree '${off_apk_rel}' AndroidManifest.xml 2>/dev/null | awk -f '${awk_rel}' > '${xmltree_off_rel}' || true
            aapt dump xmltree '${built_apk_rel}' AndroidManifest.xml 2>/dev/null | awk -f '${awk_rel}' > '${xmltree_built_rel}' || true
            diff '${xmltree_off_rel}' '${xmltree_built_rel}' > '${xmltree_diff_rel}' 2>/dev/null || true
        "
        local xmltree_off_sz xmltree_built_sz xmltree_diff_lines
        xmltree_off_sz="$(wc -c < "${WORK_DIR}/${xmltree_off_rel}" 2>/dev/null || echo 0)"
        xmltree_built_sz="$(wc -c < "${WORK_DIR}/${xmltree_built_rel}" 2>/dev/null || echo 0)"
        xmltree_diff_lines="$(wc -l < "${WORK_DIR}/${xmltree_diff_rel}" 2>/dev/null || echo 1)"
        _semantic_verdict "AndroidManifest.xml" "${xmltree_off_sz}" "${xmltree_built_sz}" "${xmltree_diff_lines}" "${filtered_log}" "Play stamp/bundletool metadata only" || true
        log_info "  Manifest xmltree diff: ${WORK_DIR}/${xmltree_diff_rel}"
    fi

    local i
    for i in "${!so_off_paths[@]}"; do
        local off_so="${so_off_paths[$i]}" built_so="${so_built_paths[$i]}" so_name="${so_names[$i]}"
        local elf_log="${results_dir}/elf_${so_name}_${split_label}.txt"
        local elf_rel="${elf_log#"${WORK_DIR}/"}"
        local off_so_rel="${off_so#"${WORK_DIR}/"}"
        local built_so_rel="${built_so#"${WORK_DIR}/"}"
        ws_exec "{
            printf '=== ELF: %s (%s) ===\nofficial: %s\nbuilt:    %s\n\n-- sizes --\n' '${so_name}' '${split_label}' '${off_so_rel}' '${built_so_rel}'
            wc -c '${off_so_rel}' '${built_so_rel}' 2>&1 || true
            printf '\n-- readelf sections official --\n'; readelf --wide --sections '${off_so_rel}' 2>&1 || true
            printf '\n-- readelf sections built --\n'; readelf --wide --sections '${built_so_rel}' 2>&1 || true
            printf '\n-- nm -D official --\n'; nm -D '${off_so_rel}' 2>/dev/null | awk '{print \$2, \$3}' | sort || true
            printf '\n-- nm -D built --\n'; nm -D '${built_so_rel}' 2>/dev/null | awk '{print \$2, \$3}' | sort || true
        } > '${elf_rel}' 2>&1"
        log_info "  ELF analysis: ${elf_log}"
    done

    TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
    log_info "  ${split_label}: ${non_meta_count} counted diff(s) of ${total_lines} raw lines"
    if [[ -s "${diff_file}" ]]; then
        log_info "  First 5 lines of raw diff (full: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
        if [[ "${total_lines}" -gt 5 ]]; then
            log_info "    ... (${total_lines} total)"
        fi
    else
        log_pass "  ${split_label}: no differences"
    fi
    return 0
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
    echo "counted diffs:  ${TOTAL_DIFFS}"
    echo "appHash:        ${app_hash:-unknown}"
    echo "commit:         ${commit:-unknown}"
    echo ""
    echo "Diff:"
    local results_dir="${WORK_DIR}/comparison" shown=0
    if [[ -d "${results_dir}" ]]; then
        for diff_file in "${results_dir}"/diff_*.txt; do
            [[ -f "${diff_file}" ]] || continue
            local split_label apk_label total_lines
            split_label="$(basename "${diff_file}" .txt)"; apk_label="${split_label#diff_}.apk"
            if [[ -s "${diff_file}" ]]; then
                total_lines="$(wc -l < "${diff_file}")"
                echo ""; echo "diffs on ${apk_label} (${total_lines} raw line(s))"; echo "  raw: ${diff_file}"
                awk '
                    function rel(p){sub(/^.*\/(official|built)_[^\/]+\/?/,"",p);return p}
                    /META-INF|stamp-cert-sha256/{next}
                    /^Missing built split: /{sub(/^Missing built split: /,"");print "  - "$0" missing from built APKs";next}
                    /^Only in /{s=$0;sub(/^Only in /,"",s);split(s,a,": ");p=rel(a[1]);f=(p?p"/":"")a[2];side=(a[1]~/official_/ ? "official" : "built");print "  - "f" only in "side" APK";next}
                    /^Binary files /{s=$0;sub(/^Binary files /,"",s);sub(/ and .*/,"",s);print "  - "rel(s)" differs";next}
                    /^Files /{s=$0;sub(/^Files /,"",s);sub(/ and .*/,"",s);print "  - "rel(s)" differs";next}
                    /^diff -r /{s=$3;print "  - "rel(s)" differs";next}
                ' "${diff_file}" | head -12
            else
                echo ""; echo "diffs on ${apk_label}"; echo "  raw: ${diff_file}"; echo "  - no differences"
            fi
            shown=$(( shown + 1 ))
        done
    fi
    echo ""
    echo "Analysis files (comparison/):"
    local af=0
    while IFS= read -r _f; do echo "  $(basename "${_f}")"; af=1; done < <(find "${results_dir}" -maxdepth 1 -name "*.txt" ! -name "diff_*.txt" 2>/dev/null | sort)
    [[ "${af}" -eq 0 ]] && echo "  (none)"
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
        local official_diff_apk built_diff_apk built_splits_dir
        official_diff_apk="${OFFICIAL_APK:-${OFFICIAL_BASE_APK:-${WORK_DIR}/official-split-apks/base.apk}}"
        built_splits_dir="${WORK_DIR}/built-split-apks/splits"
        if built_diff_apk="$(resolve_built_split_apk "${official_diff_apk}" "${built_splits_dir}" 2>/dev/null)"; then
            echo "  diffoscope '${official_diff_apk}' \\"
            echo "             '${built_diff_apk}'"
        else
            echo "  (built split not resolved; see ${WORK_DIR}/built-split-apks/)"
        fi
    fi
}

prepare() {
    log_info "=== PREPARE ==="
    chmod -R a+rwX "${WORK_DIR}" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}/official-split-apks" "${WORK_DIR}/built-output"
    chmod 777 "${WORK_DIR}/built-output"

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

    local detected_pkg base_apk_name
    base_apk_name="$(basename "${OFFICIAL_BASE_APK}")"
    detected_pkg="$(${CONTAINER_CMD} run --rm \
        -v "$(dirname "${OFFICIAL_BASE_APK}"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c "aapt dump badging \"/apk/${base_apk_name}\" 2>/dev/null | grep '^package:' | sed \"s/.*name='\\([^']*\\)'.*/\\1/\" | head -n1" \
        2>/dev/null || true)"
    if [[ -n "${detected_pkg}" && "${detected_pkg}" != "${APP_ID}" ]]; then
        generate_error_yaml "ftbfs" \
            "Package name mismatch: APK contains '${detected_pkg}', expected '${APP_ID}'."
        RESULT_DONE=true; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"
    fi
    [[ -z "${detected_pkg}" ]] && log_warn "Could not verify APK package name (aapt returned empty)"

    if [[ -z "${VERSION}" ]]; then
        log_info "Auto-detecting version from APK metadata..."
        VERSION="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
        VERSION="${VERSION//\'/}"
        VERSION="${VERSION//\"/}"
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
            if [[ -d "${new_work_dir}" ]]; then
                rm -rf "${new_work_dir}" 2>/dev/null || \
                    "${CONTAINER_CMD}" unshare rm -rf "${new_work_dir}" 2>/dev/null || \
                    { log_warn "Cannot remove ${new_work_dir} (root-owned files). Remove manually: podman unshare rm -rf ${new_work_dir}"; exit "${EXIT_FAILED}"; }
            fi
            mv "${WORK_DIR}" "${new_work_dir}"
            WORK_DIR="${new_work_dir}"
            OFFICIAL_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK}")"
            OFFICIAL_BASE_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_BASE_APK}")"
            log_info "Work directory: ${WORK_DIR}"
        fi
    fi

    if [[ -n "${DEVICE_SPEC_INPUT}" ]]; then
        cp "${DEVICE_SPEC_INPUT}" "${WORK_DIR}/device-spec.json"
        log_info "Device spec: using provided ${DEVICE_SPEC_INPUT}"
    else
        derive_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"
    fi
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
            trap 'chmod -R a+rwX /workspace 2>/dev/null || true' EXIT
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
        " 2>&1 | tee "${WORK_DIR}/build.log"
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
    log_info "=== EXTRACT AND COMPARE ==="; TOTAL_DIFFS=0
    local built_splits_dir="${WORK_DIR}/built-split-apks" compared=0
    extract_split_apks_from_aab "${BUILT_AAB}" "${WORK_DIR}/device-spec.json" "${built_splits_dir}"
    local sha256_log="${WORK_DIR}/comparison/sha256_splits.txt"
    mkdir -p "${WORK_DIR}/comparison"
    printf '%-8s  %-64s  %s\n%s\n' "side" "sha256" "file" "$(printf '%0.s-' {1..80})" > "${sha256_log}"
    while IFS= read -r official_apk; do
        local split_label built_split off_hash built_hash
        split_label="$(basename "${official_apk}" .apk)"
        if ! built_split="$(resolve_built_split_apk "${official_apk}" "${built_splits_dir}/splits")"; then
            log_warn "No matching built split for: $(basename "${official_apk}") — counting as diff"
            TOTAL_DIFFS=$(( TOTAL_DIFFS + 1 ))
            printf 'Missing built split: %s\n' "$(basename "${official_apk}")" > "${WORK_DIR}/comparison/diff_${split_label}.txt"
            printf '%-8s  %-64s  %s\n' "MISSING" "(no built counterpart)" "$(basename "${official_apk}")" >> "${sha256_log}"
            continue
        fi
        off_hash="$(sha256sum "${official_apk}" | awk '{print $1}')"
        built_hash="$(sha256sum "${built_split}"  | awk '{print $1}')"
        printf '%-8s  %s  %s\n%-8s  %s  %s\n' "official" "${off_hash}" "$(basename "${official_apk}")" "built" "${built_hash}" "$(basename "${built_split}")" >> "${sha256_log}"
        [[ "${off_hash}" == "${built_hash}" ]] && printf '          ^^^ IDENTICAL\n\n' >> "${sha256_log}" || printf '          ^^^ DIFFER\n\n' >> "${sha256_log}"
        log_info "Official: $(basename "${official_apk}") [${off_hash:0:12}...]"
        log_info "Built:    $(basename "${built_split}") [${built_hash:0:12}...]"
        compare_split_apks "${official_apk}" "${built_split}" "${split_label}"
        compared=$(( compared + 1 ))
    done < <(find "${WORK_DIR}/official-split-apks" -name "*.apk" | sort)
    [[ "${compared}" -eq 0 ]] && { log_fail "No splits were compared"; exit "${EXIT_FAILED}"; }
    log_info "SHA256 log: ${sha256_log}"
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
    local notes
    notes="Splits vs AAB (tag: ${GIT_TAG}). SKIP_SIGN=true gradlew :app:bundleGoogleRelease.
  Non-META-INF diffs: ${TOTAL_DIFFS}.
  R8 caveat: classes*.dex/baseline.prof diffs may be non-deterministic pg-map-id.
  --github-token optional; wallet-core GPR dep removed in monorepo migration."
    [[ -n "${RESOURCES_ARSC_NOTES}" ]] && notes="${notes}
  resources.arsc: ${RESOURCES_ARSC_NOTES}"
    [[ "${verdict}" == "not_reproducible" ]] && notes="${notes}
  Diffs: ${WORK_DIR}/comparison/"
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
    handle_early_exit_args "$@"
    detect_container_runtime
    parse_arguments "$@"
    prepare
    build_image
    build
    extract_and_compare
    result
}

main "$@"
