#!/bin/bash
# bullbitcoin_build.sh — Bull Bitcoin Android Reproducible Build Verification
# Version: v0.8.2
# Last modified on: 2026-09-30
# Last modified by: Bob (WalletScrutiny agent), for Daniel Garcia
# Organization: WalletScrutiny.com
# License: MIT
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.8.2"
readonly SCRIPT_NAME="bullbitcoin_build.sh"
readonly APP_ID="com.bullbitcoin.mobile"
readonly REPO_URL="https://github.com/SatoshiPortal/bullbitcoin-mobile.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
# apktool reads its framework dir from Java user.home, which is unset under keep-id.
readonly JAVA_HOME_FIX="-e _JAVA_OPTIONS=-Duser.home=/tmp"
# bundletool is a comparison input: keep it at the version AGP embeds (8.12.2 -> 1.18.1).
readonly BUNDLETOOL_VERSION="1.18.1"
readonly BUNDLETOOL_SHA256="675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c"
readonly GRADLE_HEAP="4g"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2
SCRIPT_PATH="$(readlink -f "$0")"
if [[ -f "${SCRIPT_PATH}" ]]; then
  SCRIPT_SHA256="$(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')"
else
  SCRIPT_SHA256="unknown"
fi
readonly SCRIPT_SHA256
printf '%s %s sha256:%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${SCRIPT_SHA256}"
RUN_ID="$(date +%s)-$$"
readonly RUN_ID
VERSION=""
ARCH=""
ARCH_EXPLICIT=false
APK_INPUT=""
INPUT_IS_DIR=false
INPUT_KIND=""
PLAY_ACCEPT=false
WORK_DIR=""
WORK_DIR_CREATED=false
DENSITY="480"
SDK_VER="33"
SPEC_ABIS=""
SPEC_LOCALES=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
BUILD_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
should_cleanup=false
VERDICT_REACHED=false
OFFICIAL_APK=""
TARGET_LABEL=""
BUILT_ARTIFACT=""
TOOLS_TAG=""
APP_TAG=""
BUILD_CTR=""
RESULT_DONE=false
TOTAL_DIFFS=1
TOTAL_META_ONLY=0
INTEGRITY_NOTE=""
INTEGRITY_FAIL=false
ACCEPTED_SUMMARY=""
ARSC_SUMMARY=""
ISSUE574_NOTE=""
CLASSIFY_REMAINING=1
MF_STATE=""
ARSC_STATE=""
log_info() { echo "[INFO] $*"; }
log_pass() { echo "[PASS] $*"; }
log_fail() { echo "[FAIL] $*"; }
log_warn() { echo "[WARNING] $*"; }
write_yaml() {
  local notes
  notes="$(printf '%s' "$2" | sed 's/^/  /')"
  printf 'script_version: %s\nverdict: %s\nnotes: |\n%s\n' "${SCRIPT_VERSION}" "$1" "${notes}" \
    > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
  log_info "Generated COMPARISON_RESULTS.yaml (verdict: $1)"
}
abort() {
  log_fail "$2"
  write_yaml "ftbfs" "$2"
  RESULT_DONE=true
  echo "Exit code: $1"
  exit "$1"
}
die_invalid() { abort "${EXIT_INVALID}" "$*"; }
die_failed() { abort "${EXIT_FAILED}" "$*"; }
on_error() {
  local exit_code=$?
  set +e
  log_fail "Script failed at line $1 (exit code ${exit_code})"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
reclaim_workspace() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" && -n "${CONTAINER_CMD:-}" ]] || return 0
  local fix='chown -Rh "$1" "$2" 2>/dev/null; chmod -R u+rwX "$2" 2>/dev/null; true'
  if [[ "${CONTAINER_CMD}" == "podman" ]]; then
    podman unshare sh -c "${fix}" sh 0:0 "${WORK_DIR}" >/dev/null 2>&1 || true
  else
    docker run --rm --user 0:0 -v "${WORK_DIR}:/w${VOLUME_RW}" "${WS_CONTAINER}" \
      sh -c "${fix}" sh "$(id -u):$(id -g)" /w >/dev/null 2>&1 || true
  fi
  local stray
  stray="$(find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null || true)"
  [[ -n "${stray}" ]] && log_warn "Still not caller-owned: ${stray}"
  return 0
}
on_exit() {
  local exit_code=$?
  set +e
  if [[ "${exit_code}" -ne 0 && "${RESULT_DONE}" != "true" ]]; then
    log_warn "Script failed with exit code: ${exit_code}"
    write_yaml "ftbfs" "Script failed before reaching a verdict (exit code ${exit_code})."
  fi
  if [[ -n "${CONTAINER_CMD}" ]]; then
    [[ -n "${BUILD_CTR}" ]] && ${CONTAINER_CMD} rm -f "${BUILD_CTR}" >/dev/null 2>&1
    [[ -n "${APP_TAG}" ]] && ${CONTAINER_CMD} rmi "${APP_TAG}" >/dev/null 2>&1
    [[ -n "${TOOLS_TAG}" ]] && ${CONTAINER_CMD} rmi "${TOOLS_TAG}" >/dev/null 2>&1
    [[ -n "${TOOLS_TAG}" ]] && log_info "Per-run images ${APP_TAG} and ${TOOLS_TAG} removed (if built)."
  fi
  # Only the directory this run created is chowned or removed.
  if [[ "${WORK_DIR_CREATED}" == "true" && -d "${WORK_DIR}" ]]; then
    reclaim_workspace
    if [[ "${should_cleanup}" == "true" && "${VERDICT_REACHED}" == "true" ]]; then
      rm -rf "${WORK_DIR}" && log_info "Workspace removed."
    else
      log_info "Workspace preserved: ${WORK_DIR}"
    fi
  fi
}
trap 'on_error $LINENO' ERR
trap 'on_exit' EXIT
detect_container_runtime() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    VOLUME_RO=":ro,Z"
    VOLUME_RW=":Z"
    CONTAINER_RUN_EXTRA="--userns=keep-id --user $(id -u):$(id -g)"
    BUILD_EXTRA="--layers=false"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    CONTAINER_RUN_EXTRA="--user $(id -u):$(id -g)"
    BUILD_EXTRA="--force-rm"
  else
    die_failed "Neither podman nor docker found on host. Install one to continue."
  fi
  log_info "Using ${CONTAINER_CMD} as container runtime"
}
# Run a command with the workspace mounted at /work. Extra args arrive as $1..:
# a filename is never shell source.
in_work() {
  local image="$1" extra="$2" cmd="$3"
  shift 3
  ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} ${extra} \
    -e HOME=/work/.home -e XDG_CACHE_HOME=/work/.home/.cache \
    -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work "${image}" bash -c "${cmd}" _ "$@"
}
ws_exec() { in_work "${WS_CONTAINER}" "${JAVA_HOME_FIX}" "$@"; }
app_exec() { in_work "${APP_TAG}" "" "$@"; }
# Read-only single-file inspection in the WS image.
apk_sh() {
  local apk="$1" script="$2"
  shift 2
  ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} ${JAVA_HOME_FIX} \
    -v "$(dirname "${apk}"):/apk${VOLUME_RO}" "${WS_CONTAINER}" \
    sh -c "${script}" sh "/apk/$(basename "${apk}")" "$@" 2>/dev/null || true
}
readonly AAPT_DIR='A=$(ls -d /opt/android-sdk/build-tools/*/ 2>/dev/null | head -1)'
readonly BADGING="${AAPT_DIR}"'; "${A}aapt2" dump badging "$1" 2>/dev/null || "${A}aapt" dump badging "$1" 2>/dev/null'
readonly XMLTREE="${AAPT_DIR}"'; "${A}aapt" dump xmltree "$1" AndroidManifest.xml 2>/dev/null'
apk_badging() { apk_sh "$1" "${BADGING}"; }
apk_field() {
  local pat
  case "$2" in
    targetSdkVersion|sdkVersion) pat="s/.*$2:'\([0-9]*\)'.*/\1/p" ;;
    *) pat="s/.*$2='\([^']*\)'.*/\1/p" ;;
  esac
  apk_badging "$1" | sed -n "${pat}" | head -n1
}
apk_sha256() {
  local h
  h="$(apk_sh "$1" 'sha256sum "$1" | cut -d" " -f1')"
  [[ "${h}" =~ ^[0-9a-f]{64}$ ]] && printf '%s\n' "${h}" || printf 'unreadable\n'
}
apk_signer() {
  apk_sh "$1" 'apksigner verify --print-certs "$1" 2>/dev/null | grep "Signer #1 certificate SHA-256" | awk "{print \$6}"'
}
verify_package_name() {
  local pkg
  pkg="$(apk_badging "${OFFICIAL_APK}" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/" | head -n1 || true)"
  [[ -n "${pkg}" ]] || die_invalid "Cannot read the package name from $(basename "${OFFICIAL_APK}"); identity unproven."
  [[ "${pkg}" == "${APP_ID}" ]] || die_invalid "Package name mismatch: APK is '${pkg}', expected '${APP_ID}'."
  log_info "Package name verified: ${pkg}"
}
# The input form is read from the manifest, never from the flag or the file name.
detect_input_kind() {
  local out markers
  out="$(apk_sh "$1" 'X=$('"${XMLTREE}"')
    printf "%s\n" "$X" | grep -q "^ *E: manifest" || exit 1
    printf "%s\n" "$X" | grep -oE "fused\.modules|requiredSplitTypes|split=\"" | sort -u | tr "\n" " "
    echo MANIFEST-READ')"
  [[ "${out}" == *MANIFEST-READ ]] || \
    die_failed "Could not read the manifest of $(basename "$1") (aapt dump xmltree returned nothing); input form unknown, no verdict."
  markers="$(printf '%s' "${out%MANIFEST-READ}" | tr -s ' \n' ' ' | sed 's/ $//')"
  case "${markers}" in
    *fused.modules*) INPUT_KIND="universal"; PLAY_ACCEPT=true ;;
    *requiredSplitTypes*|*split=*) INPUT_KIND="split"; PLAY_ACCEPT=true ;;
    *) INPUT_KIND="fat"; PLAY_ACCEPT=false ;;
  esac
  log_info "inputKind: ${INPUT_KIND} (manifest markers: ${markers:-none})"
}
canonicalize_split_apk_name() {
  case "$1" in
    base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
    split_config.*.apk) echo "$1" ;;
    base-*.apk) echo "split_config.${1#base-}" ;;
    *) echo "$1" ;;
  esac
}
stage_official_splits() {
  local apk name canonical
  while IFS= read -r apk; do
    name="$(basename "${apk}")"
    canonical="$(canonicalize_split_apk_name "${name}")"
    [[ -e "${WORK_DIR}/official/${canonical}" ]] && \
      die_invalid "Two artifacts canonicalise to ${canonical}; refusing to drop one."
    cp "${apk}" "${WORK_DIR}/official/${canonical}"
    [[ "${name}" != "${canonical}" ]] && log_info "Normalized: ${name} -> ${canonical}"
  done < <(find "$1" -name "*.apk" | sort)
  TARGET_LABEL="directory ($(find "${WORK_DIR}/official" -name '*.apk' | wc -l) splits)"
  [[ -f "${WORK_DIR}/official/base.apk" ]] || \
    die_failed "No base APK found in the directory (expected base.apk or base-master.apk)."
  OFFICIAL_APK="${WORK_DIR}/official/base.apk"
}
resolve_built_split_apk() {
  local name canonical
  name="$(basename "$1")"
  [[ -f "$2/${name}" ]] && echo "$2/${name}" && return 0
  canonical="$(canonicalize_split_apk_name "${name}")"
  [[ -f "$2/${canonical}" ]] && echo "$2/${canonical}" && return 0
  return 1
}
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --binary <file|dir> [OPTIONS]
Rebuilds Bull Bitcoin Mobile with upstream's Containerfiles and compares the
result with the official artifact. The input form is read from the manifest:
a Google Play split set (directory with base.apk and split_config.*.apk), a
Play universal APK, or a Gradle fat APK (GitHub release).
Options:
  --binary <path>   Official APK or directory of Play splits (alias: --apk)
  --version <ver>   Override the version read from the APK (e.g. 6.13.0)
  --arch <arch>     arm64-v8a|armeabi-v7a|x86_64|x86 (split mode, default arm64-v8a)
  --type <type>     Ignored (ABS compatibility)
  --cleanup         Remove the work directory after a verdict
  --script-version  Print version, exit
  --help            Show this help
Exit: 0=reproducible 1=not_reproducible/ftbfs 2=invalid
EOF
}
validate_version() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || die_invalid "Refusing version string '$1': expected e.g. 6.13.0."
}
need_val() { [[ "$#" -ge 2 ]] || die_invalid "$1 needs a value."; }
parse_arguments() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --version) need_val "$@"; VERSION="$2"; shift ;;
      --apk|--binary) need_val "$@"; APK_INPUT="$2"; shift ;;
      --arch) need_val "$@"; ARCH="$2"; ARCH_EXPLICIT=true; shift ;;
      --type) need_val "$@"; shift ;;
      --cleanup) should_cleanup=true ;;
      --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
      --help|-h) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
      *) log_warn "Ignoring unknown argument: $1" ;;
    esac
    shift
  done
  [[ -n "${APK_INPUT}" ]] || die_invalid "Provide --binary <file|dir> (the official APK or the full Play split set)."
  [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
  APK_INPUT="${APK_INPUT%/}"
  if [[ -d "${APK_INPUT}" ]]; then
    [[ -n "$(find "${APK_INPUT}" -name '*.apk' 2>/dev/null | head -1)" ]] || \
      die_invalid "--binary directory has no APKs: ${APK_INPUT}"
    INPUT_IS_DIR=true
    log_info "--binary is a directory; all its splits are verified."
  elif [[ ! -f "${APK_INPUT}" ]]; then
    die_invalid "--binary path not found: ${APK_INPUT}"
  fi
  ARCH="${ARCH:-arm64-v8a}"
  case "${ARCH}" in
    arm64-v8a|armeabi-v7a|x86_64|x86) ;;
    *) die_invalid "Unsupported architecture: ${ARCH}" ;;
  esac
  [[ -z "${VERSION}" ]] || validate_version "${VERSION}"
  local arch_safe="${ARCH//-/_}"
  WORK_DIR="$(pwd -P)/bullbitcoin_verification_${VERSION:-provided}_${arch_safe//[^A-Za-z0-9_]/}_${RUN_ID}"
  APP_TAG="localhost/bull-app:${RUN_ID}"
  TOOLS_TAG="localhost/bull-tools:${RUN_ID}"
  BUILD_CTR="bull-build-${RUN_ID}"
  log_info "Work directory: ${WORK_DIR}"
}
# The config splits describe the device; sdk is the base APK targetSdkVersion.
derive_device_spec_from_splits() {
  local f cfg dens="" n_abi=0 n_dens=0
  SPEC_ABIS=""; SPEC_LOCALES=""
  for f in "${WORK_DIR}/official"/split_config.*.apk; do
    [[ -f "${f}" ]] || continue
    cfg="$(basename "${f}")"; cfg="${cfg#split_config.}"; cfg="${cfg%.apk}"
    case "${cfg}" in
      arm64_v8a) SPEC_ABIS="\"arm64-v8a\""; n_abi=$((n_abi+1)) ;;
      armeabi_v7a) SPEC_ABIS="\"armeabi-v7a\""; n_abi=$((n_abi+1)) ;;
      x86_64|x86) SPEC_ABIS="\"${cfg}\""; n_abi=$((n_abi+1)) ;;
      ldpi) dens=120; n_dens=$((n_dens+1)) ;; mdpi) dens=160; n_dens=$((n_dens+1)) ;;
      tvdpi) dens=213; n_dens=$((n_dens+1)) ;; hdpi) dens=240; n_dens=$((n_dens+1)) ;;
      xhdpi) dens=320; n_dens=$((n_dens+1)) ;; xxhdpi) dens=480; n_dens=$((n_dens+1)) ;;
      xxxhdpi) dens=640; n_dens=$((n_dens+1)) ;;
      *) [[ "${cfg}" =~ ^[a-z]{2}(_[A-Za-z]+)?$ ]] && \
           SPEC_LOCALES="${SPEC_LOCALES:+${SPEC_LOCALES}, }\"${cfg//_/-}\"" ;;
    esac
  done
  [[ -n "${SPEC_ABIS}" ]] || die_invalid "No split_config.<abi>.apk supplied; cannot describe the device. Upload the full split set."
  # bundletool matches ONE ABI and density per device spec; several would read as missing splits.
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
  t="$(apk_field "${OFFICIAL_APK}" targetSdkVersion)"
  [[ "${t}" =~ ^[0-9]+$ ]] || die_invalid "targetSdkVersion unreadable from the base APK."
  SDK_VER="${t}"
  log_info "Device spec: abis=[${SPEC_ABIS}] density=${DENSITY} locales=[${SPEC_LOCALES}] sdk=${SDK_VER}"
  printf '{\n  "supportedAbis": [%s],\n  "supportedLocales": [%s],\n  "screenDensity": %s,\n  "sdkVersion": %s\n}\n' \
    "${SPEC_ABIS}" "${SPEC_LOCALES}" "${DENSITY}" "${SDK_VER}" > "${WORK_DIR}/device-spec.json"
}
confirm_bundletool_from_aab() {
  local got
  got="$(app_exec 'unzip -p "$1" BundleConfig.pb 2>/dev/null | tr -c "[:print:]" "\n" | grep -Eo "^[0-9]+\.[0-9]+\.[0-9]+$" | head -1' "$1" 2>/dev/null | tail -1 || true)"
  if [[ ! "${got}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    log_warn "BundleConfig.pb unreadable; ${BUNDLETOOL_VERSION} unconfirmed."
    return 0
  fi
  if [[ "${got}" == "${BUNDLETOOL_VERSION}" ]]; then
    log_pass "BundleConfig.pb confirms bundletool ${got}; extraction matches."
    return 0
  fi
  log_fail "A different bundletool fabricates split differences. Re-pin BUNDLETOOL_VERSION/SHA256 to ${got}."
  die_invalid "bundletool mismatch (AAB built by ${got}, extraction configured ${BUNDLETOOL_VERSION})"
}
# res/xml/splits0.xml language codes come from the split generator; Play emits
# legacy iw/in/ji, so bundletool runs with useOldISOCodes (GitLab #574).
render_apks() {
  local mode="$1" aab_rel="${BUILT_ARTIFACT#"${WORK_DIR}/"}" out="built" spec=""
  [[ "${mode}" == "default" ]] && spec="--device-spec=device-spec.json"
  log_info "Rendering APKs with bundletool ${BUNDLETOOL_VERSION} --mode=${mode}..."
  confirm_bundletool_from_aab "${aab_rel}"
  app_exec "set -euo pipefail
    [[ -f bundletool.jar ]] || curl -fsSL 'https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar' -o bundletool.jar
    echo '${BUNDLETOOL_SHA256}  bundletool.jar' | sha256sum -c -
    rm -rf built.apks '${out}'
    java -Djava.locale.useOldISOCodes=true -jar bundletool.jar build-apks --bundle='${aab_rel}' --output=built.apks ${spec} --mode=${mode} --overwrite
    mkdir -p '${out}' && unzip -o built.apks -d '${out}'
    if [[ -d '${out}/splits' ]]; then mv '${out}'/splits/*.apk '${out}/' 2>/dev/null || true; rmdir '${out}/splits' 2>/dev/null || true; fi
    [[ -f '${out}/standalones/standalone.apk' ]] && mv '${out}/standalones/standalone.apk' '${out}/base-master.apk'
    for s in '${out}'/base-*.apk; do
      [[ -f \"\$s\" ]] || continue
      n=\$(basename \"\$s\")
      if [[ \"\$n\" == base-master.apk ]]; then mv \"\$s\" '${out}/base.apk'; else mv \"\$s\" \"${out}/split_config.\${n#base-}\"; fi
    done
    ls -1 '${out}'/*.apk" || die_failed "bundletool build-apks --mode=${mode} failed."
  log_pass "APKs rendered."
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
    [[ "${entry}" =~ [[:cntrl:]] ]] && return 3
    [[ "${entry}" =~ ${SIG} ]] && continue
    # unzip -p reads the name as a glob: escape * ? [ \ so no other entry is read.
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
  [[ -s "${WORK_DIR}/ws_entry_diff.sh" ]] || die_failed "Could not write the comparator."
  cat > "${WORK_DIR}/comparison/mf_norm.sed" <<'MFSED_EOF'
/<meta-data[^>]*android:name="com\.android\.stamp\.source"[^>]*android:value="https:\/\/[^"]+"/d
/<meta-data[^>]*android:name="com\.android\.stamp\.type"[^>]*android:value="[A-Z_]+"/d
/<meta-data[^>]*android:name="com\.android\.vending\.derived\.apk\.id"[^>]*android:value="[0-9]+"/d
/^[[:space:]]*<\/application>[[:space:]]*$/d
s# */>#>#
s/[[:space:]]+/ /g
s/^ //
s/ $//
MFSED_EOF
  [[ -s "${WORK_DIR}/comparison/mf_norm.sed" ]] || die_failed "Could not write the manifest normaliser."
}
ws_entry_diff() {
  local out res
  out="$(app_exec 'bash ws_entry_diff.sh "$1" "$2" "$3"' "$1" "$2" "$3" 2>&1 | tail -1 || true)"
  res="${out#COUNT=}"
  [[ "${out}" == COUNT=* && "${res}" =~ ^[0-9]+$ ]] && { printf '%s\n' "${res}"; return 0; }
  printf 'ERROR\n'
}
# Play may add exactly these manifest entries, value-shape checked. Anything else,
# or any of them on the BUILT side, fails the assessment.
readonly PLAY_MF_KEYS='com\.android\.stamp\.source|com\.android\.stamp\.type|com\.android\.vending\.derived\.apk\.id'
decode_pair() {
  ws_exec 'set -e
    rm -rf "comparison/dec_$1_off" "comparison/dec_$1_bui"
    apktool d -f -s -o "comparison/dec_$1_off" "$2" >/dev/null 2>&1
    apktool d -f -s -o "comparison/dec_$1_bui" "$3" >/dev/null 2>&1' "$1" "$2" "$3"
}
assess_manifest() {
  local tag="$1"
  local o="${WORK_DIR}/comparison/dec_${tag}_off/AndroidManifest.xml"
  local b="${WORK_DIR}/comparison/dec_${tag}_bui/AndroidManifest.xml"
  if [[ ! -f "${o}" || ! -f "${b}" ]]; then
    MF_STATE="decode failed"; log_warn "${tag}: manifest decode failed; difference stays counted"; return 0
  fi
  if grep -qE "<meta-data[^>]*android:name=\"(${PLAY_MF_KEYS})\"" "${b}"; then
    MF_STATE="semantic"; log_fail "${tag}: BUILT manifest carries Play metadata"; return 0
  fi
  # Normalise (comparison/mf_norm.sed) and diff inside the WS container: 0 identical, 1 differs, else failed.
  local rc=0
  ws_exec 'd="comparison/dec_$1"; m="comparison/mf_$1"
    sed -E -f comparison/mf_norm.sed "${d}_off/AndroidManifest.xml" > "${m}.off" || exit 3
    sed -E -f comparison/mf_norm.sed "${d}_bui/AndroidManifest.xml" > "${m}.bui" || exit 3
    diff -u "${d}_off/AndroidManifest.xml" "${d}_bui/AndroidManifest.xml" > "${m}.diff" 2>&1 || true
    diff -q "${m}.off" "${m}.bui" >/dev/null' "${tag}" || rc=$?
  case "${rc}" in
    0) MF_STATE="play-only"; log_pass "${tag}: manifest differs only by Play distribution metadata" ;;
    1) MF_STATE="semantic"; log_fail "${tag}: manifest differs beyond Play distribution metadata" ;;
    *) MF_STATE="decode failed"; log_warn "${tag}: manifest normalisation/diff failed (rc ${rc}); stays counted" ;;
  esac
}
assess_arsc() {
  local tag="$1" rc=0
  local d="${WORK_DIR}/comparison/res_${tag}.txt"
  local o="${WORK_DIR}/comparison/dec_${tag}_off/res"
  local b="${WORK_DIR}/comparison/dec_${tag}_bui/res"
  if [[ ! -d "${o}" || ! -d "${b}" ]]; then
    ARSC_STATE="decode failed"; log_warn "${tag}: decoded res/ missing; stays counted"; return 0
  fi
  ws_exec 'diff -r "$1" "$2" > "$3" 2>&1' "${o#"${WORK_DIR}/"}" "${b#"${WORK_DIR}/"}" "${d#"${WORK_DIR}/"}" || rc=$?
  if [[ "${rc}" -gt 1 ]]; then
    ARSC_STATE="decode failed"; log_warn "${tag}: res/ diff failed (rc ${rc}); stays counted"; return 0
  fi
  if [[ "${rc}" -eq 0 ]]; then
    ARSC_STATE="binary-only"
    ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: binary-only -- decoded res/ identical.
"
    log_pass "${tag}: decoded res/ identical -- arsc non-semantic"; return 0
  fi
  if grep -qE '^(Only in |Binary files )' "${d}"; then
    ARSC_STATE="semantic"
    ARSC_SUMMARY="${ARSC_SUMMARY}  ${tag}: decoded res/ adds/removes/cannot read a file.
"
    log_fail "${tag}: decoded res/ differs structurally"; return 0
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
# Classes #574 proposes excluding that WS has NOT accepted: counted, but named.
readonly ISSUE574_CANDIDATES='assets/dexopt/baseline\.prof|assets/dexopt/baseline\.profm|res/xml/splits0\.xml'
accept_findings() {
  local counted="$1" pattern="$2" tag="$3" reason="$4" hits rc=0
  hits="$(grep -cE "$pattern" "$counted" 2>/dev/null || true)"
  [[ "${hits:-0}" -gt 0 ]] || return 0
  grep -vE "$pattern" "$counted" > "${counted}.keep" 2>/dev/null || rc=$?
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
# Play's SourceStamp is a raw SHA-256: exactly 32 bytes.
stamp_is_digest() {
  local n
  n="$(app_exec 'unzip -p "$1" stamp-cert-sha256 2>/dev/null | wc -c' "$1" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
  [[ "${n}" == "32" ]]
}
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
  local known beyond
  known="$(grep -cE "${ISSUE574_CANDIDATES}" "${counted}" 2>/dev/null || true)"
  if [[ "${known:-0}" -gt 0 ]]; then
    ISSUE574_NOTE="${ISSUE574_NOTE}  ${tag}: ${known} diff(s) in #574 classes, not accepted by WS:
$(grep -E "${ISSUE574_CANDIDATES}" "${counted}" | sed 's/^/    /')
"
    log_warn "${tag}: ${known} #574 candidate diff(s), counted not accepted"
  fi
  beyond="$(grep -vcE "${ISSUE574_CANDIDATES}" "${counted}" 2>/dev/null || true)"
  [[ "${beyond:-0}" -gt 0 ]] && log_fail "${tag}: ${beyond} difference(s) beyond every #574 class"
  CLASSIFY_REMAINING="$(grep -c . "${counted}" 2>/dev/null || true)"
  [[ "${CLASSIFY_REMAINING}" =~ ^[0-9]+$ ]] || { CLASSIFY_REMAINING=1
    log_fail "${tag}: could not count remaining findings"; INTEGRITY_FAIL=true; }
}
compare_pair() {
  local official_apk="$1" built_apk="$2" tag="$3" off_h bui_h ws_n
  local diff_file="${WORK_DIR}/comparison/diff_${tag}.txt"
  off_h="$(apk_sha256 "${official_apk}")"
  bui_h="$(apk_sha256 "${built_apk}")"
  log_info "  Official $(basename "${official_apk}"): ${off_h}"
  log_info "  Built    $(basename "${built_apk}"): ${bui_h}"
  ws_n="$(ws_entry_diff "${official_apk#"${WORK_DIR}/"}" "${built_apk#"${WORK_DIR}/"}" "${diff_file#"${WORK_DIR}/"}")"
  if [[ "${ws_n}" == "ERROR" ]]; then
    log_fail "${tag}: WS comparator error; no verdict"
    INTEGRITY_NOTE="${INTEGRITY_NOTE}${tag}: WS comparator error. "
    INTEGRITY_FAIL=true
    (( TOTAL_DIFFS++ )) || true
    return 0
  fi
  if [[ "${ws_n}" -eq 0 ]]; then
    log_pass "${tag}: all entries identical (signing excluded)"
    [[ "${off_h}" != "${bui_h}" ]] && { (( TOTAL_META_ONLY++ )) || true; }
    return 0
  fi
  if [[ "${PLAY_ACCEPT}" != "true" ]]; then
    log_warn "${tag}: ${ws_n} differing entries (no Play injection is accepted for a ${INPUT_KIND} APK)"
    (( TOTAL_DIFFS++ )) || true
    return 0
  fi
  classify "${tag}" "${diff_file}" "${official_apk#"${WORK_DIR}/"}" "${built_apk#"${WORK_DIR}/"}"
  if [[ "${CLASSIFY_REMAINING}" -eq 0 ]]; then
    log_pass "${tag}: no differences beyond the accepted classes"
    (( TOTAL_META_ONLY++ )) || true
  else
    log_warn "${tag}: ${CLASSIFY_REMAINING} unaccounted differences"
    (( TOTAL_DIFFS++ )) || true
  fi
}
compare_split_apks() {
  local official_dir="${WORK_DIR}/official" built_dir="${WORK_DIR}/built"
  local -A _matched=()
  local official_apk built_apk name tag
  for official_apk in "${official_dir}"/*.apk; do
    [[ -f "${official_apk}" ]] || continue
    name="$(basename "${official_apk}")"
    built_apk="$(resolve_built_split_apk "${official_apk}" "${built_dir}" || true)"
    if [[ -z "${built_apk}" || ! -f "${built_apk}" ]]; then
      log_warn "No matching built split for official: ${name}"
      (( TOTAL_DIFFS++ )) || true
      continue
    fi
    _matched["$(basename "${built_apk}")"]=1
    tag="$(basename "${built_apk}" .apk)"; tag="${tag#split_config.}"
    compare_pair "${official_apk}" "${built_apk}" "${tag}"
  done
  local b
  for b in "${built_dir}"/*.apk; do
    [[ -f "${b}" ]] || continue
    if [[ -z "${_matched["$(basename "${b}")"]:-}" ]]; then
      log_warn "Extra built split with no official counterpart: $(basename "${b}")"
      (( TOTAL_DIFFS++ )) || true
    fi
  done
}
print_results_block() {
  local verdict="$1" version_name version_code signer official_hash commit_hash
  version_name="$(apk_field "${OFFICIAL_APK}" versionName)"
  version_code="$(apk_field "${OFFICIAL_APK}" versionCode)"
  signer="$(apk_signer "${OFFICIAL_APK}")"
  official_hash="$(apk_sha256 "${OFFICIAL_APK}")"
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
  echo "appHash:        ${official_hash:-unknown}"
  echo "inputKind:      ${INPUT_KIND}"
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
    echo "resources.arsc (decoded, per artifact):"
    printf '%s' "${ARSC_SUMMARY}"
    echo ""
  fi
  echo "===== End Results ====="
}
prepare() {
  log_info "=== PREPARATION PHASE ==="
  mkdir "${WORK_DIR}" 2>/dev/null || die_failed "Cannot create per-run work directory ${WORK_DIR} (exists or not writable)."
  WORK_DIR_CREATED=true
  mkdir -p "${WORK_DIR}"/{official,built,built-aab,comparison,.home/.cache}
  if [[ "${INPUT_IS_DIR}" == "true" ]]; then
    log_info "Staging split APKs from directory: ${APK_INPUT}"
    stage_official_splits "${APK_INPUT}"
  else
    local name canonical
    name="$(basename "${APK_INPUT}")"
    canonical="$(canonicalize_split_apk_name "${name}")"
    cp "${APK_INPUT}" "${WORK_DIR}/official/${canonical}"
    [[ "${name}" != "${canonical}" ]] && log_info "Normalized name: ${name} -> ${canonical}"
    OFFICIAL_APK="${WORK_DIR}/official/${canonical}"
    TARGET_LABEL="file ${name}"
  fi
  verify_package_name
  detect_input_kind "${OFFICIAL_APK}"
  if [[ "${INPUT_IS_DIR}" == "true" && "${INPUT_KIND}" != "split" ]]; then
    die_invalid "--binary directory must hold Google Play splits, but its base APK is a ${INPUT_KIND} APK; pass that file directly."
  fi
  if [[ "${INPUT_IS_DIR}" != "true" && "${INPUT_KIND}" == "split" ]]; then
    die_invalid "Input ${name} is one file of a Google Play split set (base.apk or split_config.*.apk); a split set can only be verified whole, by any script. This ftbfs is about the upload, not about the app: it says nothing about Bull Bitcoin's code. Upload the full split set (base.apk plus every split_config.*.apk) as a directory."
  fi
  if [[ -z "${VERSION}" ]]; then
    VERSION="$(apk_field "${OFFICIAL_APK}" versionName)"
    [[ -n "${VERSION}" ]] || die_invalid "Could not read the version from the APK. Pass --version."
    validate_version "${VERSION}"
    log_info "Version detected: ${VERSION}"
  fi
  [[ "${INPUT_KIND}" == "split" ]] && derive_device_spec_from_splits
  log_pass "Preparation complete."
}
# Replays upstream's `make android release` (container-tools, container-app,
# android targets) with per-run image and container names; containerfiles unmodified.
build() {
  log_info "=== BUILD PHASE ==="
  local git_ref="v${VERSION}" src="${WORK_DIR}/built-aab/app"
  log_info "Cloning ${REPO_URL} at ${git_ref} (WS container)..."
  ws_exec 'git clone --depth 1 --branch "$1" "$2" built-aab/app && git -C built-aab/app rev-parse HEAD > built-aab/commit.txt' \
    "${git_ref}" "${REPO_URL}" || die_failed "Clone of ${git_ref} failed."
  log_info "Checked out ${git_ref} at $(cat "${WORK_DIR}/built-aab/commit.txt")"
  local f
  for f in makefile Containerfile.tools Containerfile.app; do
    [[ -f "${src}/${f}" ]] || die_invalid "${f} absent at ${git_ref}: predates upstream's containerized build; unsupported by ${SCRIPT_NAME} ${SCRIPT_VERSION}."
  done
  grep -q '^FROM bull-tools[[:space:]]*$' "${src}/Containerfile.app" || \
    die_failed "Containerfile.app no longer starts FROM bull-tools; upstream recipe changed, update this script."
  local fv jt api bt ndk bdk kv
  fv="$(awk 'BEGIN{RS="";} { gsub(/\r/,""); s=$0; sub(/.*"flutter"[[:space:]]*:[[:space:]]*"/,"",s); sub(/".*$/,"",s); print s; exit }' "${src}/.fvmrc")"
  jt="$(grep -E '^android\.jvmTarget=' "${src}/android/gradle.properties" | cut -d= -f2)"
  api="$(grep -E '^android\.compileSdk=' "${src}/android/gradle.properties" | cut -d= -f2)"
  bt="$(grep -E '^android\.buildToolsVersion=' "${src}/android/gradle.properties" | cut -d= -f2)"
  ndk="$(grep -E '^android\.ndkVersion=' "${src}/android/gradle.properties" | cut -d= -f2)"
  bdk="$(sed -n 's/^BDK_RUST_VERSION ?= *//p' "${src}/makefile" | head -1 | tr -d '[:space:]')"
  for kv in "flutter (.fvmrc)=${fv}" "android.jvmTarget=${jt}" "android.compileSdk=${api}" \
            "android.buildToolsVersion=${bt}" "android.ndkVersion=${ndk}" "BDK_RUST_VERSION (makefile)=${bdk}"; do
    [[ -n "${kv#*=}" ]] || die_failed "${kv%%=*} resolved empty at ${git_ref}; cannot replay upstream's container-tools recipe."
  done
  log_info "Upstream recipe: FORMAT=$([[ "${INPUT_KIND}" == "fat" ]] && echo apk || echo aab) CONTAINER=${CONTAINER_CMD} GRADLE_HEAP=${GRADLE_HEAP} make android release"
  log_info "Images ${TOOLS_TAG} and ${APP_TAG} are per-run, built without cached layers and removed at exit."
  log_info "Every run builds the toolchain image: hours, >50 GB, freed at exit."
  ${CONTAINER_CMD} build ${BUILD_EXTRA} -f "${src}/Containerfile.tools" -t "${TOOLS_TAG}" \
    --build-arg FLUTTER_VERSION="${fv}" --build-arg JVM_TARGET="${jt}" \
    --build-arg ANDROID_API_LEVEL="${api}" --build-arg ANDROID_BUILD_TOOLS="${bt}" \
    --build-arg ANDROID_NDK="${ndk}" --build-arg BDK_RUST_VERSION="${bdk}" "${src}" \
    || die_failed "Containerfile.tools build failed."
  sed "s|^FROM bull-tools[[:space:]]*\$|FROM ${TOOLS_TAG}|" "${src}/Containerfile.app" \
    | ${CONTAINER_CMD} build ${BUILD_EXTRA} -f - -t "${APP_TAG}" --build-arg GRADLE_HEAP="${GRADLE_HEAP}" "${src}" \
    || die_failed "Containerfile.app build failed."
  local fb="appbundle" out="/app/build/app/outputs/bundle/productionRelease/app-production-release.aab" ext="aab"
  if [[ "${INPUT_KIND}" == "fat" ]]; then
    fb="apk"; out="/app/build/app/outputs/flutter-apk/app-production-release.apk"; ext="apk"
  fi
  log_info "Building: fvm flutter build ${fb} --release --flavor production (container ${BUILD_CTR})"
  ${CONTAINER_CMD} rm -f "${BUILD_CTR}" >/dev/null 2>&1 || true
  ${CONTAINER_CMD} run --name "${BUILD_CTR}" --ulimit nofile=65536:65536 "${APP_TAG}" bash -c '
    SOURCE_DATE_EPOCH=$(git -C /app log -1 --format=%ct) &&
    CARGO_ENCODED_RUSTFLAGS=$(printf "%s\037%s\037%s" "--remap-path-prefix=$HOME/.cargo=/cargo" "--remap-path-prefix=$HOME/.rustup=/rustup" "--remap-path-prefix=/app=/build") &&
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 &&
    CARGO_NET_GIT_FETCH_WITH_CLI=true &&
    export SOURCE_DATE_EPOCH CARGO_ENCODED_RUSTFLAGS CARGO_PROFILE_RELEASE_CODEGEN_UNITS CARGO_NET_GIT_FETCH_WITH_CLI &&
    cd /app && fvm flutter build "$1" --release --flavor production' _ "${fb}" \
    || die_failed "upstream build failed (flutter build ${fb} --release --flavor production)."
  BUILT_ARTIFACT="${WORK_DIR}/built-aab/BULL-release.${ext}"
  ${CONTAINER_CMD} cp "${BUILD_CTR}:${out}" "${BUILT_ARTIFACT}" || die_failed "Expected ${out} in the build container; not found."
  ${CONTAINER_CMD} rm "${BUILD_CTR}" >/dev/null 2>&1 || true
  BUILD_CTR=""
  log_pass "Built: ${BUILT_ARTIFACT} ($(apk_sha256 "${BUILT_ARTIFACT}"))"
}
extract_and_compare() {
  log_info "=== EXTRACTION AND COMPARISON PHASE ==="
  write_ws_comparator
  TOTAL_DIFFS=0
  TOTAL_META_ONLY=0
  case "${INPUT_KIND}" in
    split)
      render_apks default
      log_info "Comparing split APKs (per-entry content hashes)..."
      compare_split_apks ;;
    universal)
      render_apks universal
      [[ -f "${WORK_DIR}/built/universal.apk" ]] || die_failed "bundletool --mode=universal produced no universal.apk."
      log_info "Comparing the universal APK (per-entry content hashes)..."
      compare_pair "${OFFICIAL_APK}" "${WORK_DIR}/built/universal.apk" "universal" ;;
    fat)
      log_info "Comparing the fat APK (per-entry content hashes)..."
      compare_pair "${OFFICIAL_APK}" "${BUILT_ARTIFACT}" "full" ;;
  esac
}
result() {
  log_info "=== RESULTS ==="
  local verdict_label yaml_verdict exit_code notes
  local common="Bull Bitcoin Mobile Android verification. inputKind: ${INPUT_KIND}. Input: ${TARGET_LABEL}.
Built at tag v${VERSION} with upstream's committed pipeline: Containerfile.tools/Containerfile.app and the 'make android release' recipe (FORMAT=$([[ "${INPUT_KIND}" == "fat" ]] && echo apk || echo aab)) replayed with per-run image and container names; containerfiles unmodified except FROM bull-tools resolved to the per-run tools tag. Release builds are UNSIGNED by design; no keystore injected, no tracked source modified.
Verdict: WS per-ZIP-entry content hashing, excluding only anchored legacy JAR signature files."
  case "${INPUT_KIND}" in
    split) common="${common}
Splits: bundletool ${BUNDLETOOL_VERSION} (what AGP 8.12.2 resolves, confirmed against BundleConfig.pb), -Djava.locale.useOldISOCodes=true so splits0.xml carries Play's legacy codes. Device spec: abis=[${SPEC_ABIS}] density=${DENSITY} sdk=${SDK_VER} locales=[${SPEC_LOCALES}].
AndroidManifest.xml, resources.arsc and stamp-cert-sha256 accepted only on decoded/measured evidence." ;;
    universal) common="${common}
Universal APK: bundletool ${BUNDLETOOL_VERSION} --mode=universal from the built AAB, whole-APK compare. Only the Play injections accepted in split mode (value-checked manifest keys, 32-byte SourceStamp, decoded-identical resources.arsc) are excluded; res/xml/splits0.xml stays counted (#574)." ;;
    fat) common="${common}
Fat APK: flutter build apk --release --flavor production -> BULL-release.apk, whole-APK compare. No Play injection is accepted in this path." ;;
  esac
  if [[ "${INTEGRITY_FAIL}" == "true" ]]; then
    log_fail "VERDICT WITHHELD: the comparison could not be trusted (${INTEGRITY_NOTE})"
    write_yaml "ftbfs" "COMPARISON INTEGRITY FAILURE: ${INTEGRITY_NOTE}
The build completed but the comparison could not be trusted, so no statement is made about whether this app reproduces. This is NOT a not_reproducible result.
${common}"
    RESULT_DONE=true
    VERDICT_REACHED=true
    print_results_block "comparison failed"
    echo "Exit code: ${EXIT_FAILED}"
    return "${EXIT_FAILED}"
  fi
  if [[ "${TOTAL_DIFFS:-1}" -eq 0 ]]; then
    verdict_label="reproducible"; yaml_verdict="reproducible"; exit_code="${EXIT_SUCCESS}"
    log_pass "VERDICT: REPRODUCIBLE"
    [[ "${TOTAL_META_ONLY:-0}" -gt 0 ]] && log_info "Note: ${TOTAL_META_ONLY} artifact(s) had only accepted differences"
  else
    verdict_label="differences found"; yaml_verdict="not_reproducible"; exit_code="${EXIT_FAILED}"
    log_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} artifact(s) with unaccounted differences)"
  fi
  notes="${common}"
  [[ -n "${ACCEPTED_SUMMARY}" ]] && notes="${notes}
Accepted differences (excluded from the verdict):
${ACCEPTED_SUMMARY}"
  [[ -n "${ISSUE574_NOTE}" ]] && notes="${notes}
Counted differences in #574 candidate classes (NOT accepted):
${ISSUE574_NOTE}"
  write_yaml "${yaml_verdict}" "${notes}"
  RESULT_DONE=true
  VERDICT_REACHED=true
  print_results_block "${verdict_label}"
  echo "Exit code: ${exit_code}"
  return "${exit_code}"
}
main() {
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
