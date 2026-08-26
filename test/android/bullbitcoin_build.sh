#!/bin/bash
# Bull Bitcoin Play split verifier.
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly WORK_DIR_PREFIX="workdir"
readonly SCRIPT_VERSION="v0.8.0"
readonly SCRIPT_NAME="bullbitcoin_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}
readonly APP_ID="com.bullbitcoin.mobile"
readonly REPO_URL="https://github.com/SatoshiPortal/bullbitcoin-mobile.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly BUILD_IMAGE="bull-app"
# apktool takes its framework dir from Java user.home, not $HOME; under keep-id
# that resolves to / and the decode dies. Measured 2026-08-26.
readonly JAVA_HOME_FIX="-e _JAVA_OPTIONS=-Duser.home=/tmp"
# LANDMINE (P.CASH 0.59.2): bundletool is a comparison input and must match the
# version AGP embeds. AGP 8.12.2 resolves 1.18.1; upstream's
# reproducibility/Dockerfile pins 1.17.2, stale -- do not copy. Re-pin with AGP.
BUNDLETOOL_VERSION="1.18.1"
BUNDLETOOL_SHA256="675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c"
# res/xml/splits0.xml is written by bundletool at build-apks time and is absent
# from the AAB, so its language codes are the split generator's. Play emits the
# legacy codes (iw/in/ji), bundletool under JDK 17 emits he/id/yi unless told
# otherwise -- a false splits0.xml difference (GitLab #574, bitbanana 1.0.1).
# Bull declares no bundle{} block, so language splits are on. Split step only.
GRADLE_HEAP="4g"       # not readonly: used as a make env prefix
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2
VERSION=""
ARCH=""
APK_INPUT=""        # path given to --binary / --apk
INPUT_IS_ZIP=false  # true when --binary points to a zip (WalletScrutiny Blossom upload)
INPUT_IS_TAR=false  # true when --binary points to a plain tar (WalletScrutiny Blossom upload, new format)
INPUT_IS_DIR=false  # true when --binary points to a directory of split APKs (ABS multi-binary case)
WORK_DIR=""
DENSITY="480"          # derived from the supplied splits
SDK_VER="33"           # derived from the base APK targetSdkVersion
SPEC_ABIS=""
SPEC_LOCALES=""
ARCH_EXPLICIT=false
LOCALE="en"            # derived from the supplied splits
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
should_cleanup=false
VERSION_SAFE=""
ARCH_SAFE=""
OFFICIAL_APK=""      # canonical path in WORK_DIR to the official APK/split
OFFICIAL_BASE_APK="" # same as OFFICIAL_APK in split mode (used for metadata)
TARGET_SPLIT_NAME="" # canonical split filename being compared in split mode
BUILT_AAB=""
RESULT_DONE=false    # set true by result() after writing COMPARISON_RESULTS.yaml
TOTAL_DIFFS=1        # default to "failed" until compare_*() runs
TOTAL_META_ONLY=0
CROSSCHECK_NOTE=""      # non-empty => comparators disagreed or errored
INTEGRITY_FAIL=false    # true => we learned nothing about the app, verdict is ftbfs
CROSSCHECK_STATE=""
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
    printf '%s\n' "$content" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
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
script_hash: ${SCRIPT_SHA256}
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
        RESULT_DONE=true
    fi
    echo "Exit code: ${EXIT_FAILED}"
    exit "${EXIT_FAILED}"
}
cleanup_on_error() {
    local exit_code=$?
    if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" && -n "${WORK_DIR:-}" ]]; then
        normalize_workdir_ownership || log_warn "Could not restore workspace ownership."
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
        CONTAINER_RUN_EXTRA="--userns=keep-id --user $(id -u):$(id -g)"
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
normalize_workdir_ownership() {
    [[ -d "${WORK_DIR:-}" && -n "${CONTAINER_CMD:-}" ]] || return 0
    [[ -n "$(find "${WORK_DIR}" \( ! -uid "$(id -u)" -o -type d ! -perm -u+w \) -print -quit 2>/dev/null || true)" ]] || return 0
    log_info "Restoring workspace ownership to $(id -u):$(id -g)."
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} --user 0 \
        -v "${WORK_DIR}:/work${VOLUME_RW}" "${WS_CONTAINER}" \
        sh -c 'chown -R "$1" /work && chmod -R u+rwX /work' _ "$(id -u):$(id -g)"
}
container_exec() { container_exec_args "$1"; }
# Decoding runs in the WS image: bull-app has no apktool.
ws_exec() {
    local cmd="$1"; shift
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} ${JAVA_HOME_FIX} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work "${WS_CONTAINER}" \
        bash -c "$cmd" _ "$@"
}
# Extra arguments arrive as $1.. inside cmd: a filename is never shell source.
container_exec_args() {
    local cmd="$1"; shift
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -e HOME=/work/.home -e XDG_CACHE_HOME=/work/.home/.cache \
        -w /work \
        "${BUILD_IMAGE}" \
        bash -c "set -euo pipefail
                 mkdir -p /work/.home/.cache
                 for t in curl unzip java sha256sum awk sed cut sort uniq grep mktemp tr; do
                     command -v \$t >/dev/null 2>&1 || { echo \"[FAIL] ${BUILD_IMAGE} lacks \$t\"; exit 3; }
                 done
                 $cmd" _ "$@"
}
container_sha256() {
    local file_path="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "$(dirname "$file_path"):/data${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c 'sha256sum "/data/$1" | awk "{print \$1}"' _ "$(basename "$file_path")"
}
container_signer() {
    local apk_path="$1"
    ${CONTAINER_CMD} run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "$(dirname "$apk_path"):/apk${VOLUME_RO}" \
        "${WS_CONTAINER}" \
        sh -c 'apksigner verify --print-certs "/apk/$1" 2>/dev/null \
               | grep "Signer #1 certificate SHA-256" | awk "{print \$6}"' _ "$(basename "$apk_path")" \
        || echo "unknown"
}
apk_badging() {
    local apk_path="$1" apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"; apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
        -v "${apk_dir}:/apk${VOLUME_RO}" "${WS_CONTAINER}" \
        sh -c 'A=$(ls -d /opt/android-sdk/build-tools/*/ 2>/dev/null | head -1)
               "${A}aapt2" dump badging "/apk/$1" 2>/dev/null \
               || "${A}aapt" dump badging "/apk/$1" 2>/dev/null' \
            _ "${apk_name}" 2>/dev/null || true
}
detect_apk_metadata_field() {
    local apk_path="$1" field="$2" detected apk_dir apk_name pat
    # badging prints versionName='x' but targetSdkVersion:'36'.
    case "${field}" in
        targetSdkVersion|sdkVersion) pat="s/.*${field}:'\([0-9]*\)'.*/\1/p" ;;
        *)                           pat="s/.*${field}='\([^']*\)'.*/\1/p" ;;
    esac
    detected="$(apk_badging "${apk_path}" | sed -n "${pat}" | head -n1 || true)"
    [[ -n "${detected}" ]] && { printf '%s\n' "${detected}"; return 0; }
    apk_dir="$(dirname "${apk_path}")"; apk_name="$(basename "${apk_path}")"
    ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} ${JAVA_HOME_FIX} \
        -v "${apk_dir}:/apk${VOLUME_RO}" "${WS_CONTAINER}" \
        sh -c '
            tmpdir=$(mktemp -d)
            if apktool d -f -s -o "$tmpdir/out" "/apk/$1" >/dev/null 2>&1; then
                case "$2" in
                    versionName|versionCode|targetSdkVersion|minSdkVersion)
                        sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" \
                            "$tmpdir/out/apktool.yml" | head -n1 | tr -d "\047\042" ;;
                esac
            fi
            rm -rf "$tmpdir"
        ' _ "${apk_name}" "${field}" 2>/dev/null || true
}
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
stage_official_splits() {
    local src="$1" label="$2" apk apk_name apk_canonical found_base
    while IFS= read -r apk; do
        apk_name="$(basename "${apk}")"
        apk_canonical="$(canonicalize_split_apk_name "${apk_name}")"
        if [[ -e "${WORK_DIR}/official-split-apks/${apk_canonical}" ]]; then
            log_fail "Two artifacts canonicalise to ${apk_canonical}; refusing to drop one."
            generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_INVALID}"
        fi
        cp "${apk}" "${WORK_DIR}/official-split-apks/${apk_canonical}"
        [[ "${apk_name}" != "${apk_canonical}" ]] && log_info "Normalized: ${apk_name} -> ${apk_canonical}"
    done < <(find "${src}" -name "*.apk" | sort)
    TARGET_SPLIT_NAME="${label} ($(find "${WORK_DIR}/official-split-apks" -name '*.apk' | wc -l) splits)"
    found_base="$(find_official_base_apk)"
    if [[ -z "${found_base}" ]]; then
        log_fail "No base APK found in ${label} (expected base.apk or base-master.apk)."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"
    fi
    OFFICIAL_APK="${found_base}"; OFFICIAL_BASE_APK="${found_base}"
}
verify_package_name() {
    # Gate: base APK package == APP_ID before build; anchored ^package: avoids versionName=.
    local apk="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}" pkg
    [[ -n "${apk}" && -f "${apk}" ]] || return 0
    pkg="$(apk_badging "${apk}" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/" | head -n1 || true)"
    if [[ -z "${pkg}" ]]; then
        log_fail "Cannot read the package name from $(basename "${apk}"); identity unproven."
        generate_error_yaml "ftbfs"; echo "Exit code: ${EXIT_INVALID}"; RESULT_DONE=true; exit "${EXIT_INVALID}"
    fi
    if [[ "${pkg}" != "${APP_ID}" ]]; then
        log_fail "Package name mismatch: APK is '${pkg}', expected '${APP_ID}'."
        generate_error_yaml "ftbfs"; echo "Exit code: ${EXIT_INVALID}"; RESULT_DONE=true; exit "${EXIT_INVALID}"
    fi
    log_info "Package name verified: ${pkg}"
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
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <split.apk|dir|zip|tar.gz> [OPTIONS]
Verifies Google Play split APKs against a build from source.
Options:
  --binary <path>   Split APK, dir, zip or tar.gz (alias: --apk)
  --version <ver>   Optional; else read from the base APK
  --arch <arch>     arm64-v8a|armeabi-v7a|x86_64|x86 (default arm64-v8a)
  --type <type>     Ignored (ABS compatibility)
  --cleanup         Remove temp files after run
  --script-version  Print version, exit
  --help            Show this help
Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid
EOF
}
validate_version() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || \
        die_invalid "Refusing version string '$1': expected e.g. 6.13.0."
}
guard_work_dir() {
    case "$1" in
        "${EXEC_DIR}/${WORK_DIR_PREFIX}_${APP_ID}_"*) : ;;
        *) die_invalid "Work directory outside ${EXEC_DIR}: $1" ;;
    esac
    [[ "$1" == *"/../"* || "$1" == *"/.." ]] && die_invalid "Work directory contains '..': $1"
    return 0
}
die_invalid() {
    echo "[ERROR] $*"
    echo "Exit code: ${EXIT_INVALID}"
    exit "${EXIT_INVALID}"
}
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)        VERSION="${2:-}";       shift ;;
            --apk|--binary)   APK_INPUT="${2:-}";     shift ;;
            --arch)           ARCH="${2:-}"; ARCH_EXPLICIT=true; shift ;;
            --type)           shift ;;   # accepted for ABS, unused
            --cleanup)        should_cleanup=true ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            --help|-h)        usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
            *)                usage; die_invalid "Unknown argument: $1" ;;
        esac
        shift
    done
    if [[ -n "${APK_INPUT}" ]]; then
        [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
        APK_INPUT="${APK_INPUT%/}"
        if [[ -d "${APK_INPUT}" ]]; then
            if [[ -z "$(find "${APK_INPUT}" -name '*.apk' 2>/dev/null | head -1)" ]]; then
                die_invalid "--binary directory has no APKs: ${APK_INPUT}"
            fi
            INPUT_IS_DIR=true
            log_info "--binary is a directory; all its splits are verified."
        elif [[ -f "${APK_INPUT}" ]]; then
            if file "${APK_INPUT}" | grep -q "Zip archive" && \
               unzip -l "${APK_INPUT}" 2>/dev/null | grep -q "\.apk"; then
                INPUT_IS_ZIP=true
                log_info "--binary: zip of APKs; extracting."
            elif [[ "${APK_INPUT}" == *.tar.gz || "${APK_INPUT}" == *.tgz || "${APK_INPUT}" == *.tar ]]; then
                INPUT_IS_TAR=true
                log_info "--binary: tar of APKs; extracting."
            fi
        else
            die_invalid "--binary path not found: ${APK_INPUT}"
        fi
        ARCH="${ARCH:-arm64-v8a}"
    else
        die_invalid "Provide --binary <split.apk|dir|zip|tar.gz>."
    fi
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64|x86) ;;
        *)
            die_invalid "Unsupported architecture: ${ARCH}" ;;
    esac
    [[ -n "${VERSION}" ]] && validate_version "${VERSION}"
    VERSION_SAFE="${VERSION:-provided}"
    ARCH_SAFE="${ARCH//-/_}"
    ARCH_SAFE="${ARCH_SAFE//[^A-Za-z0-9_]/}"
    WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
    log_info "Work dir: ${WORK_DIR}"
}
# Ported from bitbanana_build.sh: the config splits describe the device. sdk is
# the base APK targetSdkVersion, as bitbanana does.
derive_device_spec_from_splits() {
    local f cfg dens="" n_abi=0 n_dens=0
    SPEC_ABIS=""; SPEC_LOCALES=""
    for f in "${WORK_DIR}/official-split-apks"/split_config.*.apk; do
        [[ -f "${f}" ]] || continue
        cfg="$(basename "${f}")"; cfg="${cfg#split_config.}"; cfg="${cfg%.apk}"
        case "${cfg}" in
            arm64_v8a)   SPEC_ABIS="\"arm64-v8a\"";   n_abi=$((n_abi+1)) ;;
            armeabi_v7a) SPEC_ABIS="\"armeabi-v7a\""; n_abi=$((n_abi+1)) ;;
            x86_64|x86)  SPEC_ABIS="\"${cfg}\"";      n_abi=$((n_abi+1)) ;;
            ldpi) dens=120; n_dens=$((n_dens+1)) ;; mdpi) dens=160; n_dens=$((n_dens+1)) ;; tvdpi) dens=213; n_dens=$((n_dens+1)) ;; hdpi) dens=240; n_dens=$((n_dens+1)) ;;
            xhdpi) dens=320; n_dens=$((n_dens+1)) ;; xxhdpi) dens=480; n_dens=$((n_dens+1)) ;; xxxhdpi) dens=640; n_dens=$((n_dens+1)) ;;
            *) [[ "${cfg}" =~ ^[a-z]{2}(_[A-Za-z]+)?$ ]] && \
                   SPEC_LOCALES="${SPEC_LOCALES:+${SPEC_LOCALES}, }\"${cfg//_/-}\"" ;;
        esac
    done
    [[ -n "${SPEC_ABIS}" ]] || die_invalid "No split_config.<abi>.apk supplied; cannot describe the device."
    # --device-spec describes ONE device: bundletool matches a single ABI and
    # density per module, so listing several is a preference order, not a request
    # to generate them all. Unnarrowed, the unselected splits read as missing.
    if [[ "${ARCH_EXPLICIT}" == "true" ]]; then
        SPEC_ABIS="\"${ARCH}\""
    elif [[ "${n_abi}" -gt 1 ]]; then
        die_invalid "Splits name ${n_abi} ABIs; bundletool builds one per device. Use --arch."
    fi
    [[ "${n_dens}" -le 1 ]] || die_invalid "Splits name ${n_dens} densities; supply a single density split."
    [[ -n "${dens}" ]] || { dens=480; log_warn "No density split supplied; using 480."; }
    DENSITY="${dens}"
    [[ -n "${SPEC_LOCALES}" ]] || SPEC_LOCALES='"en-US"'
    local t
    t="$(detect_apk_metadata_field "${OFFICIAL_BASE_APK}" "targetSdkVersion" || true)"
    [[ "${t}" =~ ^[0-9]+$ ]] || die_invalid "targetSdkVersion unreadable from the base APK."
    SDK_VER="${t}"
    log_info "Device spec: abis=[${SPEC_ABIS}] density=${DENSITY} locales=[${SPEC_LOCALES}] sdk=${SDK_VER}"
}
create_device_spec() {
    local spec_path="$1"
    cat > "${spec_path}" <<DEVICESPEC_EOF
{
  "supportedAbis": [${SPEC_ABIS}],
  "supportedLocales": [${SPEC_LOCALES}],
  "screenDensity": ${DENSITY},
  "sdkVersion": ${SDK_VER}
}
DEVICESPEC_EOF
}
confirm_bundletool_from_aab() {
    local aab_rel="$1" got
    got="$(container_exec "unzip -p '${aab_rel}' BundleConfig.pb 2>/dev/null \
        | tr -c '[:print:]' '\n' | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1" \
        2>/dev/null | tail -1 || true)"
    if [[ ! "${got}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
        log_warn "BundleConfig.pb unreadable; ${BUNDLETOOL_VERSION} unconfirmed."
        return 0
    fi
    if [[ "${got}" == "${BUNDLETOOL_VERSION}" ]]; then
        log_pass "BundleConfig.pb confirms bundletool ${got}; extraction matches."
        return 0
    fi
    log_fail "AAB built by bundletool ${got}, extraction set to ${BUNDLETOOL_VERSION}."
    log_fail "A different version fabricates split differences. Re-pin BUNDLETOOL_VERSION/SHA256 to ${got}."
    RESULT_DONE=true
    die_invalid "bundletool mismatch (AAB ${got}, configured ${BUNDLETOOL_VERSION})"
}
extract_split_apks_from_aab() {
    local aab_path="$1"
    local output_dir="$2"
    local device_spec="$3"
    log_info "Extracting splits with bundletool ${BUNDLETOOL_VERSION}..."
    local aab_rel output_rel spec_rel
    aab_rel="${aab_path#"${WORK_DIR}/"}"
    output_rel="${output_dir#"${WORK_DIR}/"}"
    spec_rel="${device_spec#"${WORK_DIR}/"}"
    confirm_bundletool_from_aab "${aab_rel}"
    container_exec "set -euo pipefail
        if [[ ! -f bundletool.jar ]]; then
            curl -fsSL \"https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar\" \
                -o bundletool.jar
        fi
        [[ -n \"${BUNDLETOOL_SHA256}\" ]] && \
            echo \"${BUNDLETOOL_SHA256}  bundletool.jar\" | sha256sum -c -
        rm -f built.apks
        rm -rf \"${output_rel}\"
        java -Djava.locale.useOldISOCodes=true -jar bundletool.jar build-apks \
            --bundle=\"${aab_rel}\" \
            --output=\"built.apks\" \
            --device-spec=\"${spec_rel}\" \
            --mode=default \
            --overwrite
        mkdir -p \"${output_rel}\"
        unzip -o built.apks -d \"${output_rel}\"
        if [[ -d \"${output_rel}/splits\" ]]; then
            mv \"${output_rel}/splits\"/*.apk \"${output_rel}/\" 2>/dev/null || true
            rmdir \"${output_rel}/splits\" 2>/dev/null || true
        fi
        [[ -f \"${output_rel}/standalones/standalone.apk\" ]] && \
            mv \"${output_rel}/standalones/standalone.apk\" \"${output_rel}/base-master.apk\"
        for split_apk in \"${output_rel}\"/base-*.apk; do
            split_name=\$(basename \"\$split_apk\")
            if [[ \"\$split_name\" == 'base-master.apk' ]]; then
                mv \"\$split_apk\" \"${output_rel}/base.apk\"
            else
                mv \"\$split_apk\" \"${output_rel}/split_config.\${split_name#base-}\"
            fi
        done
        ls -1 \"${output_rel}\"/*.apk
    "
    log_pass "Splits extracted."
}
write_ws_comparator() {
    cat > "${WORK_DIR}/ws_entry_diff.sh" <<'WSCMP_EOF'
#!/bin/bash
# WalletScrutiny per-entry APK comparator. Args: <a> <b> <out>
set -uo pipefail
fail() { printf '%s\n' "$*" >> "${out:-/dev/null}" 2>/dev/null; echo "COUNT=ERROR"; exit 3; }
[[ $# -eq 3 ]] || { echo "COUNT=ERROR"; exit 3; }
a="$1"; b="$2"; out="$3"
: > "${out}" || { echo "COUNT=ERROR"; exit 3; }
SIG='^META-INF/(MANIFEST\.MF|[^/]+\.(RSA|SF|EC|DSA))$'
shopt -s nocasematch
hash_entries() {
    local apk="$1" dest="$2" names entry escaped h
    names="$(unzip -Z1 "${apk}" 2>/dev/null)" || return 3
    : > "${dest}" || return 3
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        [[ "${entry}" == */ ]] && continue
        # unzip -Z1 cannot frame control characters; refuse rather than guess.
        [[ "${entry}" =~ [[:cntrl:]] ]] && return 3
        [[ "${entry}" =~ ${SIG} ]] && continue
        # unzip -p reads the name as a glob: * ? [ \ would extract some OTHER
        # entry, identically from both, hashing a real difference as equal.
        escaped="$(printf '%s' "${entry}" | sed 's/[][*?\\]/\\&/g')" || return 3
        unzip -p "${apk}" "${escaped}" > "${tmp}" 2>/dev/null || return 3
        h="$(sha256sum < "${tmp}" | cut -d" " -f1)" || return 3
        [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || return 3
        printf '%s\t%s\n' "${h}" "${entry}" >> "${dest}" || return 3
    done <<< "${names}"
    return 0
}
tmp="$(mktemp)" || fail "MKTEMP-FAILED"
ol="$(mktemp)" || fail "MKTEMP-FAILED"
bl="$(mktemp)" || fail "MKTEMP-FAILED"
trap 'rm -f "${tmp}" "${ol}" "${bl}"' EXIT
hash_entries "${a}" "${ol}" || fail "READ-ERROR ${a}"
hash_entries "${b}" "${bl}" || fail "READ-ERROR ${b}"
# Empty lists must never compare equal: false "identical".
[[ -s "${ol}" && -s "${bl}" ]] || fail "EMPTY-ENTRY-LIST"
for f in "${ol}" "${bl}"; do
    d="$(cut -f2 "${f}" | LC_ALL=C sort | uniq -d)" || fail "DUP-CHECK-FAILED"
    [[ -z "${d}" ]] || fail "DUPLICATE-ENTRY-NAME"
done
findings="$(awk -F'\t' '
    NR==FNR { o[$2]=$1; seen[$2]=1; next }
            { b[$2]=$1; seen[$2]=1 }
    END {
        for (k in seen) {
            if      (!(k in o))  print "ONLY-IN-BUILT\t" k
            else if (!(k in b))  print "ONLY-IN-OFFICIAL\t" k
            else if (o[k]!=b[k]) print "CONTENT-DIFFERS\t" k
        }
    }' "${ol}" "${bl}")" || fail "AWK-FAILED"
if [[ -n "${findings}" ]]; then
    printf '%s\n' "${findings}" | LC_ALL=C sort >> "${out}" || fail "WRITE-FAILED"
    n="$(printf '%s\n' "${findings}" | grep -c .)" || fail "COUNT-FAILED"
else
    n=0
fi
[[ "${n}" =~ ^[0-9]+$ ]] || fail "COUNT-FAILED"
echo "COUNT=${n}"
exit 0
WSCMP_EOF
    [[ -s "${WORK_DIR}/ws_entry_diff.sh" ]] || {
        log_fail "Could not write the comparator."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
}

ws_entry_diff() {
    local out res
    out="$(container_exec_args 'bash ws_entry_diff.sh "$1" "$2" "$3"' "$1" "$2" "$3" 2>&1 | tail -1 || true)"
    res="${out#COUNT=}"
    [[ "${out}" == COUNT=* && "${res}" =~ ^[0-9]+$ ]] && { printf '%s\n' "${res}"; return 0; }
    printf 'ERROR\n'
}
# Diagnostic only. Upstream's comparator reports IDENTICAL/DIFFERS on raw
# non-signature entries; Play splits always have raw differences, so it cannot
# corroborate an accepted-difference verdict. Recorded, never decisive.
upstream_cross_check() {
    local script="built-aab/app/reproducibility/compare_apk_entries.sh"
    [[ -f "${WORK_DIR}/${script}" ]] || { printf 'ABSENT\n'; return 0; }
    local rc=0
    container_exec_args 'sh "$1" "$2" "$3" >/dev/null 2>&1' "${script}" "$1" "$2" || rc=$?
    case "${rc}" in
        0) printf 'IDENTICAL\n' ;;
        1) printf 'DIFFERS\n'   ;;
        *) printf 'ERROR\n'     ;;
    esac
}
# Acceptable-diff classification per review-notes/. Each exclusion is earned by
# decoded evidence and printed.
ACCEPTED_SUMMARY=""
ARSC_SUMMARY=""
ISSUE574_NOTE=""
CLASSIFY_REMAINING=1
MF_STATE=""
ARSC_STATE=""
# Play may add exactly these three manifest entries. Anything else, or any of
# them on the BUILT side, fails the assessment.
readonly PLAY_MF_KEYS='com\.android\.stamp\.source|com\.android\.stamp\.type|com\.android\.vending\.derived\.apk\.id'
decode_pair() {
    local tag="$1" off="$2" bui="$3"
    ws_exec 'set -e
        rm -rf "comparison/dec_$1_off" "comparison/dec_$1_bui"
        apktool d -f -s -o "comparison/dec_$1_off" "$2" >/dev/null 2>&1
        apktool d -f -s -o "comparison/dec_$1_bui" "$3" >/dev/null 2>&1' \
        "${tag}" "${off}" "${bui}"
}
assess_manifest() {
    local tag="$1"
    local o="${WORK_DIR}/comparison/dec_${tag}_off/AndroidManifest.xml"
    local b="${WORK_DIR}/comparison/dec_${tag}_bui/AndroidManifest.xml"
    if [[ ! -f "${o}" || ! -f "${b}" ]]; then
        MF_STATE="decode failed"; log_warn "${tag}: manifest decode failed; difference stays counted"; return 0
    fi
    if grep -qE "<meta-data[^>]*android:name=\"(${PLAY_MF_KEYS})\"" "${b}"; then
        MF_STATE="semantic"
        log_fail "${tag}: BUILT manifest carries Play metadata"
        return 0
    fi
    local no="${WORK_DIR}/comparison/mf_${tag}.off" nb="${WORK_DIR}/comparison/mf_${tag}.bui"
    local f
    for f in "${o}:${no}" "${b}:${nb}"; do
        # Key alone is not enough: the value must fit the shape Play emits, or
        # the line survives normalisation and is counted.
        if ! sed -E \
               -e '/<meta-data[^>]*android:name="com\.android\.stamp\.source"[^>]*android:value="https:\/\/[^"]+"/d' \
               -e '/<meta-data[^>]*android:name="com\.android\.stamp\.type"[^>]*android:value="[A-Z_]+"/d' \
               -e '/<meta-data[^>]*android:name="com\.android\.vending\.derived\.apk\.id"[^>]*android:value="[0-9]+"/d' \
               -e '/^[[:space:]]*<\/application>[[:space:]]*$/d' \
               -e 's# */>#>#' -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//' \
               "${f%%:*}" > "${f##*:}"; then
            MF_STATE="decode failed"
            log_warn "${tag}: manifest normalisation failed; stays counted"
            return 0
        fi
    done
    diff -u "${o}" "${b}" > "${WORK_DIR}/comparison/mf_${tag}.diff" 2>&1 || true
    if diff -q "${no}" "${nb}" >/dev/null 2>&1; then
        MF_STATE="play-only"; log_pass "${tag}: manifest differs only by Play distribution metadata"
    else
        MF_STATE="semantic"; log_fail "${tag}: manifest differs beyond Play distribution metadata"
    fi
}
assess_arsc() {
    local tag="$1" rc=0
    local d="${WORK_DIR}/comparison/res_${tag}.txt"
    local o="${WORK_DIR}/comparison/dec_${tag}_off/res"
    local b="${WORK_DIR}/comparison/dec_${tag}_bui/res"
    # Both trees must exist: checking only one let a missing tree read identical.
    if [[ ! -d "${o}" || ! -d "${b}" ]]; then
        ARSC_STATE="decode failed"
        log_warn "${tag}: decoded res/ missing; stays counted"
        return 0
    fi
    diff -r "${o}" "${b}" > "${d}" 2>&1 || rc=$?
    if [[ "${rc}" -gt 1 ]]; then
        ARSC_STATE="decode failed"
        log_warn "${tag}: res/ diff failed (rc ${rc}); stays counted"
        return 0
    fi
    if [[ "${rc}" -eq 0 ]]; then
        ARSC_STATE="binary-only"
        ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: binary-only -- decoded res/ identical.
"
        log_pass "${tag}: decoded res/ identical -- arsc non-semantic"
        return 0
    fi
    # Added/removed/unreadable files are structural and never acceptable.
    if grep -qE '^(Only in |Binary files )' "${d}"; then
        ARSC_STATE="semantic"
        ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: decoded res/ adds/removes/cannot read a file.
"
        log_fail "${tag}: decoded res/ differs structurally"
        return 0
    fi
    local changed residual
    changed="$(grep -cE '^[<>]' "${d}" 2>/dev/null || true)"; changed="${changed:-0}"
    residual="$(grep -E '^[<>]' "${d}" 2>/dev/null | grep -vc 'crashlytics.mapping_file_id' || true)"
    residual="${residual:-0}"
    if [[ "${changed}" -gt 0 && "${residual}" -eq 0 ]]; then
        ARSC_STATE="crashlytics-only"
        ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: decoded res/ differs only in crashlytics.mapping_file_id (R8 UUID).
"
        log_warn "${tag}: decoded res/ differs only in the Crashlytics id"
    else
        ARSC_STATE="semantic"
        ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: decoded res/ differs in ${residual} line(s) beyond accepted keys.
"
        log_fail "${tag}: decoded res/ differs semantically (${residual} lines)"
    fi
}
# Classes #574 proposes excluding that WS has NOT accepted: still counted (the
# issue is open) but named, so a reader knows it is a known candidate.
readonly ISSUE574_CANDIDATES='assets/dexopt/baseline\.prof|assets/dexopt/baseline\.profm|res/xml/splits0\.xml'
# Move one class out of the counted set, recording why. Nothing is dropped silently.
accept_findings() {
    local counted="$1" pattern="$2" tag="$3" reason="$4" hits
    hits="$(grep -cE "$pattern" "$counted" 2>/dev/null || true)"
    [[ "${hits:-0}" -gt 0 ]] || return 0
    local rc=0
    grep -vE "$pattern" "$counted" > "${counted}.keep" 2>/dev/null || rc=$?
    # grep exits 1 when all lines matched: empty, not a failure.
    if [[ "${rc}" -gt 1 ]]; then
        rm -f "${counted}.keep"
        log_fail "${tag}: findings rewrite failed; nothing excluded"
        INTEGRITY_FAIL=true
        return 0
    fi
    mv -f "${counted}.keep" "$counted"
    ACCEPTED_SUMMARY="${ACCEPTED_SUMMARY}  ${tag}: ${hits} x ${reason}
"
}
# Play's SourceStamp is a raw SHA-256: exactly 32 bytes. Anything else under
# that name is not what we mean to exclude.
stamp_is_digest() {
    local n
    n="$(container_exec_args 'unzip -p "$1" stamp-cert-sha256 2>/dev/null | wc -c' \
        "$1" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
    [[ "${n}" == "32" ]]
}
# Classify one split's differing entries. Returns the count that remains real.
classify() {
    local tag="$1" counted="$2" off="$3" bui="$4" decoded=false
    if grep -q 'stamp-cert-sha256' "${counted}"; then
        if stamp_is_digest "${off}"; then
            accept_findings "${counted}" "^ONLY-IN-OFFICIAL$(printf '\t')stamp-cert-sha256\$" \
                "${tag}" "stamp-cert-sha256 (Play SourceStamp, 32-byte digest, official side only)"
        else
            log_fail "${tag}: stamp-cert-sha256 not a 32-byte digest; counted"
        fi
    fi
    if grep -qE 'AndroidManifest\.xml|resources\.arsc' "${counted}"; then
        if decode_pair "${tag}" "${off}" "${bui}"; then
            decoded=true
        else
            log_warn "${tag}: apktool decode failed; diffs stay counted"
        fi
    fi
    if [[ "${decoded}" == "true" ]] && grep -q 'AndroidManifest\.xml' "${counted}"; then
        assess_manifest "${tag}"
        [[ "${MF_STATE}" == "play-only" ]] && \
            accept_findings "${counted}" "^CONTENT-DIFFERS$(printf '\t')AndroidManifest\.xml\$" \
                "${tag}" "AndroidManifest.xml (Play distribution metadata only)"
    fi
    if [[ "${decoded}" == "true" ]] && grep -q 'resources\.arsc' "${counted}"; then
        assess_arsc "${tag}"
        [[ "${ARSC_STATE}" == "binary-only" || "${ARSC_STATE}" == "crashlytics-only" ]] && \
            accept_findings "${counted}" "^CONTENT-DIFFERS$(printf '\t')resources\.arsc\$" \
                "${tag}" "resources.arsc (${ARSC_STATE}; decoded evidence recorded)"
    fi
    local known
    known="$(grep -cE "${ISSUE574_CANDIDATES}" "${counted}" 2>/dev/null || true)"
    if [[ "${known:-0}" -gt 0 ]]; then
        ISSUE574_NOTE="${ISSUE574_NOTE}  ${tag}: ${known} diff(s) in #574 classes, not accepted by WS:
$(grep -E "${ISSUE574_CANDIDATES}" "${counted}" | sed 's/^/    /')
"
        log_warn "${tag}: ${known} #574 candidate diff(s), counted not accepted"
    fi
    local beyond
    beyond="$(grep -vcE "${ISSUE574_CANDIDATES}" "${counted}" 2>/dev/null || true)"
    [[ "${beyond:-0}" -gt 0 ]] && \
        log_fail "${tag}: ${beyond} difference(s) beyond every #574 class"
    CLASSIFY_REMAINING="$(grep -c . "${counted}" 2>/dev/null || true)"
    [[ "${CLASSIFY_REMAINING}" =~ ^[0-9]+$ ]] || { CLASSIFY_REMAINING=1
        log_fail "${tag}: could not count remaining findings"; INTEGRITY_FAIL=true; }
}
compare_split_apks() {
    local official_dir="$1" built_dir="$2" results_dir="$3"
    log_info "Comparing split APKs (per-entry content hashes)..."
    mkdir -p "${results_dir}"
    write_ws_comparator
    TOTAL_DIFFS=0
    TOTAL_META_ONLY=0
    local -A _matched=()
    local official_apk
    for official_apk in "${official_dir}"/*.apk; do
        [[ -f "${official_apk}" ]] || continue
        local apk_name built_apk comparison_name
        apk_name="$(basename "${official_apk}")"
        built_apk="$(resolve_built_split_apk "${official_apk}" "${built_dir}" || true)"
        if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
            log_warn "No matching built split for official: ${apk_name}"
            (( TOTAL_DIFFS++ )) || true
            continue
        fi
        comparison_name="$(basename "${built_apk}")"
        _matched["${comparison_name}"]=1
        local official_hash built_hash
        official_hash="$(container_sha256 "${official_apk}")"
        built_hash="$(container_sha256 "${built_apk}")"
        log_info "  Official ${apk_name}: ${official_hash}"
        log_info "  Built    ${comparison_name}: ${built_hash}"
        local tag="${comparison_name%.apk}"
        tag="${tag#split_config.}"
        local diff_file="${results_dir}/diff_${tag}.txt"
        local ws_n
        ws_n="$(ws_entry_diff "${official_apk#"${WORK_DIR}/"}" \
                              "${built_apk#"${WORK_DIR}/"}" \
                              "${diff_file#"${WORK_DIR}/"}")"
        # A comparator that did not run is not evidence about the app.
        if [[ "${ws_n}" == "ERROR" ]]; then
            log_fail "${comparison_name}: WS comparator error; no verdict"
            CROSSCHECK_NOTE="${CROSSCHECK_NOTE}${comparison_name}: WS comparator error. "
            INTEGRITY_FAIL=true
            (( TOTAL_DIFFS++ )) || true
            continue
        fi
        CROSSCHECK_STATE="${CROSSCHECK_STATE}${tag}=$(upstream_cross_check \
            "${official_apk#"${WORK_DIR}/"}" "${built_apk#"${WORK_DIR}/"}") "
        if [[ "${ws_n}" -eq 0 ]]; then
            log_pass "${comparison_name}: all entries identical (signing excluded)"
            [[ "${official_hash}" != "${built_hash}" ]] && { (( TOTAL_META_ONLY++ )) || true; }
            continue
        fi
        classify "${tag}" "${diff_file}" \
            "${official_apk#"${WORK_DIR}/"}" "${built_apk#"${WORK_DIR}/"}"
        if [[ "${CLASSIFY_REMAINING}" -eq 0 ]]; then
            log_pass "${comparison_name}: no differences beyond the accepted classes"
            (( TOTAL_META_ONLY++ )) || true
        else
            log_warn "${comparison_name}: ${CLASSIFY_REMAINING} unaccounted differences"
            (( TOTAL_DIFFS++ )) || true
        fi
    done
    # A split we built that Play does not ship is also a mismatch.
    local _b _n
    for _b in "${built_dir}"/*.apk; do
        [[ -f "${_b}" ]] || continue
        _n="$(basename "${_b}")"
        if [[ -z "${_matched["${_n}"]:-}" ]]; then
            log_warn "Extra built split with no official counterpart: ${_n}"
            (( TOTAL_DIFFS++ )) || true
        fi
    done
}

print_results_block() {
    local verdict="$1"
    local version_name version_code signer official_hash commit_hash
    version_name="$(detect_apk_metadata_field "${OFFICIAL_BASE_APK}" "versionName" || true)"
    version_code="$(detect_apk_metadata_field "${OFFICIAL_BASE_APK}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_BASE_APK}" || true)"
    official_hash="$(container_sha256 "${OFFICIAL_BASE_APK}")"
    commit_hash="$(cat "${WORK_DIR}/built-aab/commit.txt" 2>/dev/null || echo "unknown")"
    echo ""
    echo "===== Begin Results ====="
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256}"
    echo "appId:          ${APP_ID}"
    echo "signer:         ${signer:-unknown}"
    echo "apkVersionName: ${version_name:-${VERSION}}"
    echo "apkVersionCode: ${version_code:-unknown}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${official_hash}"
    echo "commit:         ${commit_hash}"
    echo ""
    echo "Diff:"
    local diff_file lines label
    for diff_file in "${WORK_DIR}/comparison"/diff_*.txt; do
        [[ -f "${diff_file}" ]] || continue
        label="$(basename "${diff_file}" .txt)"; label="${label#diff_}"
        echo "=== ${label} ==="
        if [[ -s "${diff_file}" ]]; then
            head -5 "${diff_file}"
            lines="$(grep -c . "${diff_file}" || true)"
            [[ "${lines}" -gt 5 ]] && echo "... (${lines} differing entries total)"
        else
            echo "(no differing entries)"
        fi
        echo ""
    done
    if [[ -n "${ACCEPTED_SUMMARY}" ]]; then
        echo "Accepted differences (excluded from the verdict):"
        printf '%s' "${ACCEPTED_SUMMARY}"
        echo ""
    fi
    echo "Revision, tag (and its signature):"
    echo "Built from tag v${VERSION} at commit ${commit_hash}."
    echo "No tag signature check is performed."
    echo ""
    if [[ -n "${ISSUE574_NOTE}" ]]; then
        echo "Counted differences in #574 candidate classes (NOT accepted):"
        printf '%s' "${ISSUE574_NOTE}"
        echo ""
    fi
    if [[ -n "${ARSC_SUMMARY}" ]]; then
        echo "resources.arsc (decoded, per split):"
        printf '%s' "${ARSC_SUMMARY}"
        echo ""
    fi
    echo "===== End Results ====="
}
prepare() {
    log_info "=== PREPARATION PHASE ==="
    guard_work_dir "${WORK_DIR}"
    if [[ -d "${WORK_DIR}" ]]; then
        log_info "Removing existing work directory."
        normalize_workdir_ownership
        rm -rf "${WORK_DIR}"
    fi
    mkdir -p "${WORK_DIR}"/{official-split-apks,built-split-apks,built-aab,comparison}
    chmod 777 "${WORK_DIR}/built-aab"
    if [[ "${INPUT_IS_DIR}" == "true" ]]; then
            log_info "Staging split APKs from directory: ${APK_INPUT}"
            stage_official_splits "${APK_INPUT}" "directory"
        elif [[ "${INPUT_IS_ZIP}" == "true" || "${INPUT_IS_TAR}" == "true" ]]; then
            local archive_type extract_dir apk_count
            extract_dir="${WORK_DIR}/archive-extracted"
            mkdir -p "${extract_dir}"
            if [[ "${INPUT_IS_ZIP}" == "true" ]]; then
                archive_type="zip"
                unzip -qq "${APK_INPUT}" -d "${extract_dir}" 2>/dev/null || true
            else
                archive_type="tar"
                tar -xf "${APK_INPUT}" -C "${extract_dir}" || log_warn "tar: extraction errors"
            fi
            log_info "Extracted ${archive_type}."
            chmod -R a+rwX "${extract_dir}" 2>/dev/null || true
            apk_count="$(find "${extract_dir}" -name "*.apk" 2>/dev/null | wc -l)"
            [[ "${apk_count}" -gt 0 ]] || \
                die_invalid "No APK files inside ${archive_type}: ${APK_INPUT}"
            log_info "${apk_count} APK(s)."
            stage_official_splits "${extract_dir}" "${archive_type}"
        else
            local original_name canonical_name
            original_name="$(basename "${APK_INPUT}")"
            canonical_name="$(canonicalize_split_apk_name "${original_name}")"
            TARGET_SPLIT_NAME="${canonical_name}"
            cp "${APK_INPUT}" "${WORK_DIR}/official-split-apks/${canonical_name}"
            [[ "${original_name}" != "${canonical_name}" ]] && \
                log_info "Normalized split name: ${original_name} -> ${canonical_name}"
            OFFICIAL_APK="${WORK_DIR}/official-split-apks/${canonical_name}"
            OFFICIAL_BASE_APK="${OFFICIAL_APK}"
        fi
        if [[ -z "${VERSION}" ]]; then
            log_info "Auto-detecting version from APK content..."
            VERSION="$(detect_apk_metadata_field "${OFFICIAL_APK}" "versionName" || true)"
            [[ -n "${VERSION}" ]] || die_invalid "Could not read the version from the APK. Pass --version."
            log_info "Version detected: ${VERSION}"
            validate_version "${VERSION}"
            VERSION_SAFE="${VERSION}"
            local old_work_dir="${WORK_DIR}"
            WORK_DIR="$(work_dir_path "${VERSION_SAFE}" "${ARCH_SAFE}")"
            guard_work_dir "${WORK_DIR}"
            if [[ "${WORK_DIR}" != "${old_work_dir}" ]]; then
                [[ -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
                mv "${old_work_dir}" "${WORK_DIR}"
                log_info "Work directory renamed to: ${WORK_DIR}"
                OFFICIAL_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_APK}")"
                OFFICIAL_BASE_APK="${WORK_DIR}/official-split-apks/$(basename "${OFFICIAL_BASE_APK}")"
            fi
        fi
        derive_device_spec_from_splits
        create_device_spec "${WORK_DIR}/device-spec.json"
    verify_package_name
    log_pass "Preparation complete."
}
build() {
    log_info "=== BUILD PHASE ==="
    local t
    for t in git make; do
        command -v "${t}" >/dev/null 2>&1 || {
            log_fail "Host tool '${t}' not found; upstream's makefile drives the build."
            generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
    done
    local git_ref="v${VERSION}"
    local src_dir="${WORK_DIR}/built-aab/app"
    log_info "Cloning ${REPO_URL} at ${git_ref}..."
    rm -rf "${src_dir}"
    git clone --depth 1 --branch "${git_ref}" "${REPO_URL}" "${src_dir}" || {
        log_fail "Clone of ${git_ref} failed."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
    local commit_hash
    commit_hash="$(git -C "${src_dir}" rev-parse HEAD)"
    echo "${commit_hash}" > "${WORK_DIR}/built-aab/commit.txt"
    log_info "Checked out ${git_ref} at ${commit_hash}"
    local f
    for f in makefile Containerfile.tools Containerfile.app; do
        [[ -f "${src_dir}/${f}" ]] || {
            log_fail "${f} absent at ${git_ref}: predates upstream's containerized build (v6.13.0)."
            log_fail "That is a limitation of this verifier, not a build failure, so no result file is written."
            RESULT_DONE=true; die_invalid "unsupported tag for ${SCRIPT_NAME} ${SCRIPT_VERSION}"; }
    done
    log_info "Upstream build: FORMAT=aab CONTAINER=${CONTAINER_CMD} GRADLE_HEAP=${GRADLE_HEAP} make android release"
    log_info "First run builds bull-tools/bull-app: hours, >50 GB."
    (
        cd "${src_dir}" || exit 1
        GRADLE_HEAP="${GRADLE_HEAP}" FORMAT=aab CONTAINER="${CONTAINER_CMD}" \
            make android release
    ) || {
        log_fail "upstream make android release failed."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
    local produced="${src_dir}/BULL-release.aab"
    [[ -f "${produced}" ]] || {
        log_fail "Expected ${produced}; not found."
        generate_error_yaml "ftbfs"; RESULT_DONE=true; exit "${EXIT_FAILED}"; }
    BUILT_AAB="${produced}"
    log_info "Built AAB: ${BUILT_AAB}"
    log_pass "Build complete."
}
extract_and_compare() {
    log_info "=== EXTRACTION AND COMPARISON PHASE ==="
    extract_split_apks_from_aab "${BUILT_AAB}" \
        "${WORK_DIR}/built-split-apks" "${WORK_DIR}/device-spec.json"
    compare_split_apks "${WORK_DIR}/official-split-apks" \
        "${WORK_DIR}/built-split-apks" "${WORK_DIR}/comparison"
}
result() {
    log_info "=== RESULTS ==="
    local verdict_label yaml_verdict exit_code
    # The comparison did not happen. not_reproducible would be a false fact.
    if [[ "${INTEGRITY_FAIL}" == "true" ]]; then
        log_fail "VERDICT WITHHELD: the comparison could not be trusted (${CROSSCHECK_NOTE})"
        generate_comparison_yaml "ftbfs" "COMPARISON INTEGRITY FAILURE: ${CROSSCHECK_NOTE}
  The build completed but the comparison could not be trusted, so no statement is made about whether this app reproduces. This is NOT a not_reproducible result."
        RESULT_DONE=true
        print_results_block "comparison failed"
        echo "Exit code: ${EXIT_FAILED}"
        return "${EXIT_FAILED}"
    fi
    if [[ "${TOTAL_DIFFS:-1}" -eq 0 ]]; then
        verdict_label="reproducible"
        yaml_verdict="reproducible"
        exit_code="${EXIT_SUCCESS}"
        log_pass "VERDICT: REPRODUCIBLE"
        [[ "${TOTAL_META_ONLY:-0}" -gt 0 ]] && \
            log_info "Note: ${TOTAL_META_ONLY} split(s) had only accepted differences"
    else
        verdict_label="differences found"
        yaml_verdict="not_reproducible"
        exit_code="${EXIT_FAILED}"
        log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} split(s) with unaccounted differences)"
    fi
    local notes
    notes="Bull Bitcoin Mobile Android split APK verification (Google Play delivery).
  Input: ${TARGET_SPLIT_NAME}. Built at tag v${VERSION} with upstream's committed pipeline ('make android release', containerfiles unmodified). Release builds are UNSIGNED by design; no keystore injected, no tracked source modified.
  Splits: bundletool ${BUNDLETOOL_VERSION} (what AGP 8.12.2 resolves, confirmed against BundleConfig.pb), -Djava.locale.useOldISOCodes=true so splits0.xml carries Play's legacy codes. Device spec: abis=[${SPEC_ABIS}] density=${DENSITY} sdk=${SDK_VER} locales=[${SPEC_LOCALES}].
  Verdict: WS per-ZIP-entry content hashing, excluding only anchored legacy JAR signature files. AndroidManifest.xml, resources.arsc and stamp-cert-sha256 accepted only on decoded/measured evidence.
  Raw-entry cross-check (upstream compare_apk_entries.sh): ${CROSSCHECK_STATE}-- raw non-signature entries only; it does not assess the accepted classes."
    [[ -n "${CROSSCHECK_NOTE}" ]] && notes="COMPARATOR INTEGRITY: ${CROSSCHECK_NOTE}Verdict is not publishable without review.
  ${notes}"
    generate_comparison_yaml "${yaml_verdict}" "${notes}"
    RESULT_DONE=true
    print_results_block "${verdict_label}"
    normalize_workdir_ownership
    if [[ "${should_cleanup}" == "true" ]]; then
        rm -rf "${WORK_DIR}"
        log_info "Workspace removed."
    else
        log_info "Workspace preserved: ${WORK_DIR}"
    fi
    echo "Exit code: ${exit_code}"
    return "${exit_code}"
}
main() {
    SCRIPT_SHA256="$(sha256_of "${SCRIPT_PATH}")"
    log_info "Script:  $(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"
    rm -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    log_warn "This script is provided as-is. Review before running. Use at your own risk."
    detect_container_runtime
    parse_arguments "$@"
    prepare
    build
    extract_and_compare
    result
}
main "$@"
