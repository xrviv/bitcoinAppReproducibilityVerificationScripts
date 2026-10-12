#!/bin/bash
# nunchukandroid_build.sh — Nunchuk Android Reproducible Build Verification
# Version: v0.5.4
# Last modified on: 2026-09-29
# Organization: WalletScrutiny.com
# License: MIT
set -euo pipefail
EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.5.4"
readonly SCRIPT_NAME="nunchukandroid_build.sh"
readonly APP_ID="io.nunchuk.android"
readonly REPO_URL="https://github.com/nunchuk-io/nunchuk-android.git"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
readonly BUNDLETOOL_URL="https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar"
readonly BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
readonly APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.2/apktool_3.0.2.jar"
readonly APKTOOL_SHA256="eee4669a704a14e0623407e6701b0b91887e61e1e4049cb7a82833e14ae8b5fd"
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
VERSION=""
ARCH=""
APK_INPUT=""
APK_INPUT_IS_DIR="false"
INPUT_KIND=""
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
REQUESTED_TAG=""
REQUESTED_REV=""
should_cleanup=false
OFFICIAL_APK=""
BUILT_AAB=""
BUILT_APK=""
GIT_TAG=""
GRADLE_TASK=""
RESULT_DONE=false
TOTAL_DIFFS=0
SEMANTIC_UPGRADE="true"
SEMANTIC_NOTES=""
IMAGE_TAG=""
RUN_ID="$(date +%s)-$$"
readonly RUN_ID
log_info() { echo "[INFO] $*"; }
log_pass() { echo "[PASS] $*"; }
log_fail() { echo "[FAIL] $*"; }
log_warn() { echo "[WARNING] $*"; }
write_yaml_outputs() {
  printf '%s\n' "$1" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
    printf '%s\n' "$1" > "${WORK_DIR}/COMPARISON_RESULTS.yaml" || true
  fi
}
generate_comparison_yaml() {
  local notes
  notes="$(printf '%s' "$2" | sed 's/^/  /')"
  write_yaml_outputs "script_version: ${SCRIPT_VERSION}
verdict: $1
notes: |
${notes}"
  log_info "Generated COMPARISON_RESULTS.yaml (verdict: $1)"
}
abort() {
  log_fail "$2"
  generate_comparison_yaml "ftbfs" "$2"
  RESULT_DONE=true
  echo "Exit code: $1"
  exit "$1"
}
die_invalid() { abort "${EXIT_INVALID}" "$*"; }
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
    generate_comparison_yaml "ftbfs" "Script failed before reaching a verdict (exit code ${exit_code})."
  fi
  reclaim_workspace
  if [[ -n "${IMAGE_TAG}" && -n "${CONTAINER_CMD}" ]]; then
    ${CONTAINER_CMD} rmi "${IMAGE_TAG}" >/dev/null 2>&1 || true
  fi
  if [[ "${exit_code}" -ne 0 && -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
    log_warn "Work directory preserved: ${WORK_DIR}"
  fi
}
trap 'on_error $LINENO' ERR
trap 'on_exit' EXIT
detect_container_runtime() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    VOLUME_RO=":ro,Z"
    VOLUME_RW=":Z"
    CONTAINER_RUN_EXTRA="--userns=keep-id"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    CONTAINER_RUN_EXTRA="--user $(id -u):$(id -g)"
  else
    abort "${EXIT_FAILED}" "Neither podman nor docker found on host. Install one to continue."
  fi
  log_info "Using ${CONTAINER_CMD} as container runtime"
}
in_work() {
  ${CONTAINER_CMD} run --rm ${CONTAINER_RUN_EXTRA} \
    -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work "$1" sh -c "$2"
}
ws_exec() { in_work "${WS_CONTAINER}" "$1"; }
apk_sh() {
  local apk="$1" script="$2"
  shift 2
  ${CONTAINER_CMD} run --rm -v "$(dirname "${apk}"):/apk${VOLUME_RO}" "${WS_CONTAINER}" \
    sh -c "${script}" sh "/apk/$(basename "${apk}")" "$@" 2>/dev/null | tr -d '\r\n' || true
}
readonly XMLTREE='A=$(ls -d /opt/android-sdk/build-tools/*/aapt | tail -n1); "$A" dump xmltree "$1" AndroidManifest.xml 2>/dev/null'
manifest_attr() {
  apk_sh "$1" "${XMLTREE}"' | sed -n "/^ *A: $2[(=]/{s/.*=\"\([^\"]*\)\".*/\1/p; s/.*=(type 0x10)0x\([0-9a-fA-F]*\).*/0x\1/p; q}"' "$2"
}
apk_sha256() { apk_sh "$1" 'sha256sum "$1" | cut -d" " -f1'; }
apk_signer() {
  apk_sh "$1" 'apksigner verify --print-certs --max-sdk-version 32 "$1" 2>/dev/null | grep "Signer #1 certificate SHA-256" | awk "{print \$6}"'
}
assert_package_name() {
  local pkg
  pkg="$(manifest_attr "$1" package)"
  if [[ "${pkg}" != "${APP_ID}" ]]; then
    die_invalid "Package check failed for $(basename "$1"): expected ${APP_ID}, got '${pkg:-unreadable}'."
  fi
  log_info "Package verified: ${pkg}"
}
detect_input_kind() {
  local markers
  markers="$(apk_sh "$1" "${XMLTREE}"' | grep -oE "fused\.modules|requiredSplitTypes|split=\"" | sort -u | tr "\n" " "')"
  case "${markers}" in
    *fused.modules*) INPUT_KIND="universal" ;;
    *requiredSplitTypes*|*split=*) INPUT_KIND="split" ;;
    *) INPUT_KIND="fat" ;;
  esac
  log_info "Input kind: ${INPUT_KIND} (manifest markers: ${markers:-none})"
}
canonicalize_split_apk_name() {
  case "$1" in
    base.apk|base-master.apk) echo "base.apk" ;;
    base-*.apk) echo "split_config.${1#base-}" ;;
    *) echo "$1" ;;
  esac
}
resolve_built_split_apk() {
  local name="$1" built_dir="$2"
  [[ -f "${built_dir}/${name}" ]] && echo "${built_dir}/${name}" && return 0
  if [[ "${name}" == split_config.*.apk ]]; then
    local bt_name="base-${name#split_config.}"
    [[ -f "${built_dir}/${bt_name}" ]] && echo "${built_dir}/${bt_name}" && return 0
  fi
  return 1
}
usage() {
  cat <<EOF
SYNOPSIS
  ${SCRIPT_NAME} --binary <file|dir> [OPTIONS]
DESCRIPTION
  Rebuilds Nunchuk Android with upstream's reproducible-builds/Dockerfile and
  compares the result with the official artifact. The input kind is read from
  the file's manifest, never from its name: a Play split (one split or a
  directory of splits containing base.apk), a Play universal APK, or a Gradle
  fat APK.
OPTIONS
  --binary <file|dir>  Official APK, split, or directory of Play splits. Alias: --apk.
  --version <ver>      Override the version read from the APK (e.g. 2.8.5).
  --arch <arch>        ABI when no ABI split is supplied (default arm64-v8a).
  --tag <ref>          Override the git tag (default: android.<version>).
  --revision <sha>     Pin an untagged commit, full 40-hex SHA. Alias: --revision-override.
  --cleanup            Remove the work directory after completion.
  --script-version     Print script version and exit.
  --help               Show this help and exit.
EXIT CODES
  0 reproducible   1 differences or build failure   2 invalid parameters
EOF
}
parse_arguments() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --version) VERSION="${2:-}"; shift ;;
      --apk|--binary) APK_INPUT="${2:-}"; shift ;;
      --arch) ARCH="${2:-}"; shift ;;
      --type) shift ;;
      --tag)
        [[ "${2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die_invalid "--tag has invalid characters."
        REQUESTED_TAG="$2"; shift ;;
      --revision|--revision-override)
        [[ "${2:-}" =~ ^[0-9a-fA-F]{40}$ ]] || die_invalid "--revision needs a full 40-hex SHA."
        REQUESTED_REV="$2"; shift ;;
      --cleanup) should_cleanup=true ;;
      --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
      --help|-h) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
      *) log_warn "Ignoring unknown argument: $1" ;;
    esac
    shift
  done
  [[ "$(id -u)" -ne 0 ]] || die_invalid "Do not run this script as root."
  [[ -z "${REQUESTED_REV}" || -z "${REQUESTED_TAG}" ]] || die_invalid "--revision and --tag are mutually exclusive."
  [[ -n "${APK_INPUT}" ]] || die_invalid "Provide --binary <file|dir> (the official APK or Play split set)."
  if [[ -d "${APK_INPUT}" ]]; then
    APK_INPUT="${APK_INPUT%/}"
    [[ -f "${APK_INPUT}/base.apk" ]] || die_invalid "--binary directory contains no base.apk: ${APK_INPUT}"
    APK_INPUT_IS_DIR="true"
    log_info "--binary is a directory; ALL split APKs in it will be verified"
  elif [[ ! -f "${APK_INPUT}" ]]; then
    die_invalid "--binary file not found: ${APK_INPUT}"
  fi
  [[ "${APK_INPUT}" != /* ]] && APK_INPUT="${EXEC_DIR}/${APK_INPUT}"
  ARCH="${ARCH:-arm64-v8a}"
  case "${ARCH}" in
    arm64-v8a|armeabi-v7a|x86_64|x86) ;;
    *) die_invalid "Unsupported architecture: ${ARCH} (supported: arm64-v8a, armeabi-v7a, x86_64, x86)" ;;
  esac
  WORK_DIR="$(pwd -P)/nunchuk_verification_${VERSION:-provided}_${ARCH//-/_}_${RUN_ID}"
  IMAGE_TAG="localhost/nunchuk_build_env:${RUN_ID}"
  log_info "${SCRIPT_NAME} ${SCRIPT_VERSION}"
  log_info "Work directory: ${WORK_DIR}"
}
resolve_git_tag() {
  local candidate
  log_info "Resolving git tag for version $1..."
  for candidate in "android.$1" "v$1" "$1"; do
    if git ls-remote --tags --exit-code "${REPO_URL}" "refs/tags/${candidate}" >/dev/null 2>&1; then
      log_info "Found tag: ${candidate}"
      GIT_TAG="${candidate}"
      return 0
    fi
    log_info "  Tag ${candidate}: not found"
  done
  return 1
}
build_image() {
  local dockerfile="${WORK_DIR}/Dockerfile" url="https://raw.githubusercontent.com/nunchuk-io/nunchuk-android/${GIT_TAG}/reproducible-builds/Dockerfile"
  local upstream
  log_info "Fetching Nunchuk Dockerfile from ref ${GIT_TAG}..."
  upstream="$(curl -fsSL --max-time 30 ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "${url}" 2>/dev/null || true)"
  [[ -n "${upstream}" ]] || abort "${EXIT_FAILED}" "Could not fetch reproducible-builds/Dockerfile for ref ${GIT_TAG}"
  cat > "${dockerfile}" <<DOCKERFILE_EOF
${upstream}
RUN set -e; \\
  curl -fsSL -o /tmp/bundletool.jar "${BUNDLETOOL_URL}"; \\
  echo "${BUNDLETOOL_SHA256}  /tmp/bundletool.jar" | sha256sum -c -; \\
  curl -fsSL -o /tmp/apktool.jar "${APKTOOL_URL}"; \\
  echo "${APKTOOL_SHA256}  /tmp/apktool.jar" | sha256sum -c -
DOCKERFILE_EOF
  log_info "Building per-run image ${IMAGE_TAG} (removed at exit)..."
  ${CONTAINER_CMD} build -t "${IMAGE_TAG}" -f "${dockerfile}" "${WORK_DIR}"
  log_pass "Build image ${IMAGE_TAG} ready."
}
create_device_spec() {
  local abis=() locales=() density="" f cfg
  for f in "${WORK_DIR}/official"/split_config.*.apk; do
    [[ -f "${f}" ]] || continue
    cfg="$(basename "${f}")"; cfg="${cfg#split_config.}"; cfg="${cfg%.apk}"
    case "${cfg}" in
      arm64_v8a) abis+=("arm64-v8a") ;;
      armeabi_v7a) abis+=("armeabi-v7a") ;;
      x86_64) abis+=("x86_64") ;;
      x86) abis+=("x86") ;;
      ldpi) density=120 ;;
      mdpi) density=160 ;;
      tvdpi) density=213 ;;
      hdpi) density=240 ;;
      xhdpi) density=320 ;;
      xxhdpi) density=480 ;;
      xxxhdpi) density=640 ;;
      [a-z][a-z]|[a-z][a-z][a-z]|[a-z][a-z]_*|[a-z][a-z][a-z]_*) locales+=("${cfg//_/-}") ;;
      *) log_warn "Unrecognized config split '${cfg}' — not reflected in device-spec" ;;
    esac
  done
  [[ ${#abis[@]} -eq 0 ]] && abis=("${ARCH}")
  [[ ${#locales[@]} -eq 0 ]] && locales=("en")
  [[ -z "${density}" ]] && density=480
  local abis_json locales_json
  abis_json="$(printf '"%s",' "${abis[@]}")"; abis_json="${abis_json%,}"
  locales_json="$(printf '"%s",' "${locales[@]}")"; locales_json="${locales_json%,}"
  printf '{"supportedAbis": [%s], "supportedLocales": [%s], "screenDensity": %s, "sdkVersion": 31}\n' \
    "${abis_json}" "${locales_json}" "${density}" > "${WORK_DIR}/device-spec.json"
  log_info "device-spec.json: abis=[${abis_json}], locales=[${locales_json}], density=${density} (from the official split set)"
}
render_apks() {
  local mode="$1" out="${WORK_DIR}/built-apks" aab_rel="${BUILT_AAB#"${WORK_DIR}/"}" spec=""
  [[ "${mode}" == "default" ]] && spec="--device-spec=device-spec.json"
  log_info "Running bundletool build-apks --mode=${mode}..."
  in_work "${IMAGE_TAG}" "set -e
    unzip -tqq '${aab_rel}' >/dev/null 2>&1 || { echo '[ERROR] Built AAB is not a valid zip archive'; exit 1; }
    java -jar /tmp/bundletool.jar build-apks --bundle='${aab_rel}' --output=built.apks ${spec} --mode=${mode} --overwrite 2>&1
    mkdir -p built-apks && unzip -qq -o built.apks -d built-apks" \
    || abort "${EXIT_FAILED}" "bundletool failed to render APKs from the built AAB"
  if [[ -f "${out}/splits/base-master.apk" ]]; then
    mv "${out}/splits/base-master.apk" "${out}/splits/base.apk"
  fi
  local n
  n="$(find "${out}" -name '*.apk' | wc -l)"
  [[ "${n}" -gt 0 ]] || abort "${EXIT_FAILED}" "bundletool produced no APKs in ${out}"
  log_info "Rendered ${n} APK(s) into ${out}"
}
unzip_apk_in_container() {
  local apk_rel="${1#"${WORK_DIR}/"}" out_rel="${2#"${WORK_DIR}/"}"
  ws_exec "mkdir -p '${out_rel}' && { unzip -qq '${apk_rel}' -d '${out_rel}' 2>/dev/null; rc=\$?; [ \"\${rc}\" -le 1 ]; }" \
    || abort "${EXIT_FAILED}" "unzip failed for $1"
}
show_diff_head() {
  local n
  n="$(wc -l < "$1")"
  head -5 "$1" | sed "s/^/$2/"
  [[ "${n}" -gt 5 ]] && echo "$2... (${n} lines total)"
  return 0
}
DIFF_LINE_MATCH='^Only in |^Files |^Binary files |^diff '
SIGN_NAME='[^/]*(\.(SF|RSA|DSA|EC)|MANIFEST\.MF)'
META_INF_ROOT_EXCLUDE="^Only in comparison/official_[^/:]+/META-INF: ${SIGN_NAME}\$|^(Files|Binary files) comparison/(official|built)_[^/]+/META-INF/${SIGN_NAME} and |^diff (-r )?comparison/(official|built)_[^/]+/META-INF/${SIGN_NAME} "
compare_apks() {
  local official_apk="$1" built_apk="$2" label="$3"
  local results_dir="${WORK_DIR}/comparison"
  mkdir -p "${results_dir}"
  log_info "Comparing: ${label}"
  local diff_file="${results_dir}/diff_${label}.txt"
  unzip_apk_in_container "${official_apk}" "${results_dir}/official_${label}"
  unzip_apk_in_container "${built_apk}" "${results_dir}/built_${label}"
  ws_exec "diff -r 'comparison/official_${label}' 'comparison/built_${label}' > 'comparison/diff_${label}.txt' 2>&1; rc=\$?; [ \"\${rc}\" -le 1 ]" \
    || abort "${EXIT_FAILED}" "diff -r failed (operational error) -- see ${diff_file}"
  local total_lines=0 non_meta_count=0
  if [[ -s "${diff_file}" ]]; then
    total_lines="$(wc -l < "${diff_file}")"
    non_meta_count="$(grep -E "${DIFF_LINE_MATCH}" "${diff_file}" | grep -cvE "${META_INF_ROOT_EXCLUDE}" || true)"
  fi
  TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
  log_info "  ${label}: ${non_meta_count} non-META-INF diff(s) (${total_lines} lines total)"
  if [[ -s "${diff_file}" ]]; then
    log_info "  First 5 lines (full diff: ${diff_file}):"
    show_diff_head "${diff_file}" "    "
  fi
  if [[ "${non_meta_count}" -gt 0 ]]; then
    analyze_acceptable_diffs "${official_apk}" "${built_apk}" "${label}" "${diff_file}"
  fi
}
write_manifest_norm_awk() {
  cat > "${WORK_DIR}/manifest_norm.awk" <<'AWK_EOF'
function accepted_play_metadata(name) {
  return name == "com.android.stamp.source" ||
         name == "com.android.stamp.type" ||
         name == "com.android.vending.derived.apk.id" ||
         name == "com.android.vending.splits" ||
         name == "com.android.dynamic.apk.fused.modules"
}
function meta_name(line,   nm) {
  if (line !~ /^[[:space:]]*<meta-data[[:space:]]/) return ""
  if (line !~ /android:name="/) return ""
  nm = line; sub(/^.*android:name="/, "", nm); sub(/".*$/, "", nm); return nm
}
role == "built" && NR == FNR {
  nm = meta_name($0)
  if (nm != "" && accepted_play_metadata(nm)) avail[$0]++
  next
}
{ raw[++n] = $0 }
END {
  m = 0
  for (k = 1; k <= n; k++) {
    line = raw[k]; nm = meta_name(line)
    if (nm != "" && accepted_play_metadata(nm)) {
      if (role == "official") continue
      else if (avail[line] > 0) { avail[line]--; continue }
    }
    L[++m] = line
  }
  i = 1
  while (i <= m) {
    cur = L[i]; nxt = (i < m) ? L[i+1] : ""
    if (cur ~ /^[[:space:]]*<[A-Za-z][A-Za-z0-9_.:-]*/ && cur ~ />[[:space:]]*$/ && cur !~ /\/>[[:space:]]*$/ && cur !~ /^[[:space:]]*<\//) {
      tag = cur; sub(/^[[:space:]]*</, "", tag); sub(/[[:space:]>].*/, "", tag)
      if (nxt ~ ("^[[:space:]]*</" tag ">[[:space:]]*$")) {
        c = cur; sub(/>[[:space:]]*$/, "/>", c); print c; i += 2; continue
      }
    }
    print cur; i++
  }
}
AWK_EOF
}
diff_body() { grep -vE '^diff -r |^[0-9]+(,[0-9]+)?[acd][0-9]+(,[0-9]+)?$|^---$|^$' "$1" 2>/dev/null || true; }
analyze_acceptable_diffs() {
  local official_apk="$1" built_apk="$2" label="$3" diff_file="$4"
  local results_dir="${WORK_DIR}/comparison"
  local stamp_re='^Only in comparison/official_[^/:]+: stamp-cert-sha256$'
  local splits_re='^Only in comparison/official_[^/:]+/res/xml: splits0\.xml$'
  local manifest_re='^Binary files .*AndroidManifest\.xml .* differ$'
  local arsc_re='^Binary files .*resources\.arsc .* differ$'
  write_manifest_norm_awk
  log_info "  Semantic analysis of diffs (${label})..."
  local counted_lines
  counted_lines="$(grep -E "${DIFF_LINE_MATCH}" "${diff_file}" | grep -vE "${META_INF_ROOT_EXCLUDE}" || true)"
  local unexplained="" accepted="" needs_manifest=0 needs_arsc=0 line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" =~ ${stamp_re} ]]; then
      accepted+="${label}: stamp-cert-sha256 only in official (Google Play SourceStamp certificate hash)"$'\n'
    elif [[ "${line}" =~ ${splits_re} ]]; then
      accepted+="${label}: res/xml/splits0.xml only in official (Google Play splits table, referenced by com.android.vending.splits)"$'\n'
    elif [[ "${line}" =~ ${manifest_re} ]]; then
      needs_manifest=1
    elif [[ "${line}" =~ ${arsc_re} ]]; then
      needs_arsc=1
    else
      unexplained+="${line}"$'\n'
    fi
  done <<< "${counted_lines}"
  if [[ "${needs_manifest}" -eq 1 || "${needs_arsc}" -eq 1 ]]; then
    cp "${official_apk}" "${results_dir}/official_${label}.apk"
    cp "${built_apk}" "${results_dir}/built_${label}.apk"
    log_info "  Decoding both APKs with pinned apktool 3.0.2 (nunchuk image, --no-src)..."
    in_work "${IMAGE_TAG}" "java -jar /tmp/apktool.jar d -f --no-src --no-debug-info 'comparison/official_${label}.apk' -o 'comparison/official_${label}_decoded' >/dev/null 2>&1 && \
      java -jar /tmp/apktool.jar d -f --no-src --no-debug-info 'comparison/built_${label}.apk' -o 'comparison/built_${label}_decoded' >/dev/null 2>&1" || {
      log_warn "  apktool decode failed — semantic analysis inconclusive"
      unexplained+="apktool decode failed"$'\n'
      needs_manifest=0
      needs_arsc=0
    }
  fi
  if [[ "${needs_manifest}" -eq 1 ]]; then
    local mf_diff_file="${results_dir}/diff_manifest_decoded_${label}.txt"
    local mf_res_file="${results_dir}/residual_manifest_${label}.txt"
    local off_mf="comparison/official_${label}_decoded/AndroidManifest.xml"
    local built_mf="comparison/built_${label}_decoded/AndroidManifest.xml"
    if ! ws_exec "diff '${off_mf}' '${built_mf}' > 'comparison/diff_manifest_decoded_${label}.txt' 2>&1; rc=\$?; [ \"\${rc}\" -le 1 ]"; then
      unexplained+="AndroidManifest.xml decoded diff command failed"$'\n'
    elif [[ -z "$(diff_body "${mf_diff_file}")" ]]; then
      accepted+="${label}: AndroidManifest.xml binary differs, decoded content IDENTICAL (non-semantic artifact)"$'\n'
    elif ! ws_exec "set -e
        awk -v role=official -f /work/manifest_norm.awk '${off_mf}' > 'comparison/norm_off_manifest_${label}.txt'
        awk -v role=built -f /work/manifest_norm.awk '${off_mf}' '${built_mf}' > 'comparison/norm_built_manifest_${label}.txt'
        diff 'comparison/norm_off_manifest_${label}.txt' 'comparison/norm_built_manifest_${label}.txt' > 'comparison/residual_manifest_${label}.txt' 2>&1; rc=\$?; [ \"\${rc}\" -le 1 ]"; then
      unexplained+="AndroidManifest.xml normalization failed"$'\n'
    elif [[ -z "$(diff_body "${mf_res_file}")" ]]; then
      accepted+="${label}: AndroidManifest.xml diff is only official Google Play-injected meta-data (structure-normalized; raw diff: $(basename "${mf_diff_file}"))"$'\n'
    else
      unexplained+="AndroidManifest.xml has non-Play-injection changes after normalization — see $(basename "${mf_res_file}")"$'\n'
    fi
  fi
  if [[ "${needs_arsc}" -eq 1 ]]; then
    local rs_diff_file="${results_dir}/diff_resources_decoded_${label}.txt"
    ws_exec "diff -r 'comparison/official_${label}_decoded/res' 'comparison/built_${label}_decoded/res' > 'comparison/diff_resources_decoded_${label}.txt' 2>&1 || true"
    local rs_changed rs_bad
    rs_changed="$(diff_body "${rs_diff_file}")"
    rs_bad="$(echo "${rs_changed}" | grep -v 'com.google.firebase.crashlytics.mapping_file_id' | grep -vE '^$' || true)"
    if [[ -z "${rs_changed}" ]]; then
      accepted+="${label}: resources.arsc binary differs, decoded res/ IDENTICAL (non-semantic artifact)"$'\n'
    elif [[ -z "${rs_bad}" ]]; then
      accepted+="${label}: resources.arsc sole decoded diff is com.google.firebase.crashlytics.mapping_file_id (build-time ID, acceptable per WS policy) — see $(basename "${rs_diff_file}")"$'\n'
    else
      unexplained+="resources.arsc decoded res/ diff has non-crashlytics changes — see $(basename "${rs_diff_file}")"$'\n'
    fi
  fi
  if [[ -n "${accepted}" ]]; then
    log_info "  Acceptable diffs:"
    echo "${accepted}" | sed '/^$/d; s/^/    - /'
  fi
  if [[ -z "${unexplained//[$'\n ']}" ]]; then
    SEMANTIC_NOTES+="${accepted}"
    log_pass "  ${label}: all diffs are documented acceptable classes."
  else
    SEMANTIC_UPGRADE="false"
    log_warn "  ${label}: unexplained diffs remain — verdict stays not_reproducible:"
    echo "${unexplained}" | sed '/^$/d; s/^/    ! /'
  fi
}
print_results_block() {
  local verdict="$1" version_name version_code signer app_hash commit="" tag_info=""
  version_name="$(manifest_attr "${OFFICIAL_APK}" android:versionName)"
  version_code="$(manifest_attr "${OFFICIAL_APK}" android:versionCode)"
  [[ "${version_code}" == 0x* ]] && version_code=$(( version_code ))
  signer="$(apk_signer "${OFFICIAL_APK}")"
  app_hash="$(apk_sha256 "${OFFICIAL_APK}")"
  [[ -f "${WORK_DIR}/built-aab/commit.txt" ]] && commit="$(cat "${WORK_DIR}/built-aab/commit.txt")"
  [[ -f "${WORK_DIR}/built-aab/tag_verify.txt" ]] && tag_info="$(cat "${WORK_DIR}/built-aab/tag_verify.txt")"
  echo ""
  echo "===== Begin Results ====="
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo "appId:          ${APP_ID}"
  echo "signer:         ${signer:-unknown}"
  echo "apkVersionName: ${version_name:-unknown}"
  echo "apkVersionCode: ${version_code:-unknown}"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${app_hash:-unknown}"
  echo "inputKind:      ${INPUT_KIND}"
  if [[ "${INPUT_KIND}" == "split" ]]; then
    echo "officialSplits (sha256, as provided):"
    local sp
    for sp in "${WORK_DIR}/official"/*.apk; do
      [[ -f "${sp}" ]] || continue
      echo "  $(basename "${sp}"): $(apk_sha256 "${sp}")"
    done
  fi
  echo "commit:         ${commit:-unknown}"
  echo ""
  echo "Diff:"
  local shown=0 diff_file label
  for diff_file in "${WORK_DIR}/comparison"/diff_*.txt; do
    [[ -f "${diff_file}" ]] || continue
    label="$(basename "${diff_file}" .txt)"
    if [[ -s "${diff_file}" ]]; then
      echo "  ${label} (first 5 lines — full diff: ${diff_file}):"
      show_diff_head "${diff_file}" "    "
    else
      echo "  ${label}: no differences"
    fi
    shown=$(( shown + 1 ))
  done
  [[ "${shown}" -eq 0 ]] && echo "  (no diff files found)"
  echo ""
  echo "Revision, tag (and its signature):"
  echo "${tag_info:-  (tag verification not available)}"
  echo "===== End Results ====="
  echo ""
  if [[ "${should_cleanup}" != "true" ]]; then
    echo "Work directory: ${WORK_DIR}"
    echo "Diff files:     ${WORK_DIR}/comparison/"
  fi
}
prepare() {
  log_info "=== PREPARE PHASE ==="
  mkdir "${WORK_DIR}" || abort "${EXIT_FAILED}" "Cannot create per-run work directory ${WORK_DIR}"
  mkdir -p "${WORK_DIR}/official" "${WORK_DIR}/built-aab"
  local src name canonical count=0
  if [[ "${APK_INPUT_IS_DIR}" == "true" ]]; then
    for src in "${APK_INPUT}"/*.apk; do
      [[ -f "${src}" ]] || continue
      name="$(basename "${src}")"
      canonical="$(canonicalize_split_apk_name "${name}")"
      cp "${src}" "${WORK_DIR}/official/${canonical}"
      [[ "${name}" != "${canonical}" ]] && log_info "Normalized split name: ${name} -> ${canonical}"
      count=$(( count + 1 ))
    done
    log_info "Collected ${count} official split APK(s) for verification"
    OFFICIAL_APK="${WORK_DIR}/official/base.apk"
  else
    name="$(basename "${APK_INPUT}")"
    canonical="$(canonicalize_split_apk_name "${name}")"
    cp "${APK_INPUT}" "${WORK_DIR}/official/${canonical}"
    [[ "${name}" != "${canonical}" ]] && log_info "Normalized split name: ${name} -> ${canonical}"
    OFFICIAL_APK="${WORK_DIR}/official/${canonical}"
  fi
  assert_package_name "${OFFICIAL_APK}"
  detect_input_kind "${OFFICIAL_APK}"
  if [[ "${APK_INPUT_IS_DIR}" == "true" && "${INPUT_KIND}" != "split" ]]; then
    die_invalid "--binary directory must hold Play splits, but base.apk is a ${INPUT_KIND} APK; pass that file directly."
  fi
  if [[ "${INPUT_KIND}" == "split" && "${APK_INPUT_IS_DIR}" != "true" ]]; then
    log_warn "Single-split mode: ONLY $(basename "${OFFICIAL_APK}") verified; pass the splits dir for full coverage."
  fi
  if [[ -z "${VERSION}" ]]; then
    VERSION="$(manifest_attr "${OFFICIAL_APK}" android:versionName)"
    [[ -n "${VERSION}" ]] || die_invalid "Could not read versionName from the APK. Pass --version explicitly."
    log_info "Version detected: ${VERSION}"
  fi
  if [[ "${INPUT_KIND}" == "fat" ]]; then
    GRADLE_TASK="assembleProductionRelease"
  else
    GRADLE_TASK="bundleProductionRelease"
    [[ "${INPUT_KIND}" == "split" ]] && create_device_spec
  fi
  log_pass "Preparation complete."
}
build() {
  log_info "=== BUILD PHASE ==="
  GIT_TAG="${REQUESTED_REV:-${REQUESTED_TAG:-}}"
  if [[ -z "${GIT_TAG}" ]] && ! resolve_git_tag "${VERSION}"; then
    abort "${EXIT_FAILED}" "No tag for ${VERSION} (tried android.${VERSION}, v${VERSION}, ${VERSION}). If the source exists untagged, re-run with --revision <sha>."
  fi
  log_info "Git ref: ${GIT_TAG}${REQUESTED_REV:+ (untagged commit, pinned)}"
  build_image
  local clone_cmd="git clone --depth 1 --branch '${GIT_TAG}' '${REPO_URL}' /workspace/app"
  if [[ -n "${REQUESTED_REV}" ]]; then
    clone_cmd="git init -q /workspace/app && cd /workspace/app && git remote add origin '${REPO_URL}' && git fetch -q --depth 1 origin '${GIT_TAG}' && git checkout -q FETCH_HEAD"
  fi
  log_info "Cloning + building in container with ./gradlew ${GRADLE_TASK} (this may take 20-40 minutes)..."
  log_info "NOTE: Requires --privileged for disorderfs (FUSE)."
  ${CONTAINER_CMD} run --rm --privileged \
    -v "${WORK_DIR}/built-aab:/workspace${VOLUME_RW}" \
    -e "HOME=/tmp" -e "GRADLE_USER_HOME=/tmp/.gradle" \
    "${IMAGE_TAG}" bash -c "set -euo pipefail
  echo '[INFO] Cloning ${REPO_URL} at ${GIT_TAG}...'
  ${clone_cmd}
  cd /workspace/app
  git rev-parse HEAD > /workspace/commit.txt
  echo \"[INFO] Commit: \$(cat /workspace/commit.txt)\"
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
  echo '[INFO] Mounting source with disorderfs...'
  mkdir -p /build-src
  disorderfs --sort-dirents=yes --reverse-dirents=no /workspace/app /build-src/ 2>&1 || {
    echo '[WARNING] disorderfs failed or not available; building without it'
    cp -a /workspace/app/. /build-src/ 2>/dev/null || true
  }
  cd /build-src
  chmod +x gradlew
  echo 'org.gradle.daemon=false' >> gradle.properties
  echo 'org.gradle.parallel=false' >> gradle.properties
  echo '[INFO] Running ./gradlew ${GRADLE_TASK}...'
  ./gradlew ${GRADLE_TASK} --no-daemon --stacktrace
  if ! mountpoint -q /build-src; then
    echo '[INFO] Copying build outputs to workspace...'
    find /build-src \\( -name '*.aab' -o -name '*.apk' \\) -not -path '*/intermediates/*' 2>/dev/null \\
      | while read -r f; do
          rel=\"\${f#/build-src/}\"
          mkdir -p \"/workspace/app/\$(dirname \"\${rel}\")\"
          cp \"\${f}\" \"/workspace/app/\${rel}\" 2>/dev/null || true
        done || true
  fi
  echo '[INFO] Build complete.'"
  if [[ "${INPUT_KIND}" == "fat" ]]; then
    BUILT_APK="$(find "${WORK_DIR}/built-aab/app" -name '*.apk' -path '*/outputs/apk/*' ! -path '*/intermediates/*' | head -1)"
    [[ -n "${BUILT_APK}" ]] || abort "${EXIT_FAILED}" "Built APK not found after ${GRADLE_TASK}"
    log_pass "Built APK: ${BUILT_APK}"
  else
    BUILT_AAB="$(find "${WORK_DIR}/built-aab/app" -name '*.aab' -path '*/outputs/bundle/*' ! -path '*/intermediates/*' | head -1)"
    [[ -n "${BUILT_AAB}" ]] || abort "${EXIT_FAILED}" "Built AAB not found after ${GRADLE_TASK}"
    log_pass "Built AAB: ${BUILT_AAB}"
  fi
}
extract_and_compare() {
  log_info "=== EXTRACT AND COMPARE PHASE ==="
  TOTAL_DIFFS=0
  local built_dir="${WORK_DIR}/built-apks/splits" official built name
  case "${INPUT_KIND}" in
    split)
      render_apks default
      local compared=0
      for official in "${WORK_DIR}/official"/*.apk; do
        [[ -f "${official}" ]] || continue
        name="$(basename "${official}")"
        built="$(resolve_built_split_apk "${name}" "${built_dir}")" || {
          log_info "Available built splits:"
          find "${built_dir}" -name '*.apk' | sed 's/^/  /'
          abort "${EXIT_FAILED}" "Could not find matching built split for ${name}"
        }
        log_info "Official: ${name}  <->  Built: $(basename "${built}")"
        compare_apks "${official}" "${built}" "${name%.apk}"
        compared=$(( compared + 1 ))
      done
      log_info "Compared ${compared} split pair(s)."
      for built in "${built_dir}"/*.apk; do
        [[ -f "${built}" ]] || continue
        name="$(canonicalize_split_apk_name "$(basename "${built}")")"
        [[ -f "${WORK_DIR}/official/${name}" ]] || log_warn "Built split $(basename "${built}") has no official counterpart (not compared)"
      done ;;
    universal)
      render_apks universal
      built="$(find "${WORK_DIR}/built-apks" -name 'universal.apk' | head -1)"
      [[ -n "${built}" ]] || abort "${EXIT_FAILED}" "bundletool --mode=universal produced no universal.apk"
      compare_apks "${OFFICIAL_APK}" "${built}" "universal" ;;
    fat)
      compare_apks "${OFFICIAL_APK}" "${BUILT_APK}" "full" ;;
  esac
}
result() {
  log_info "=== RESULT PHASE ==="
  local verdict semantic_summary="" head
  if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
    verdict="reproducible"
  elif [[ "${SEMANTIC_UPGRADE}" == "true" ]]; then
    verdict="reproducible"
    semantic_summary="
  All ${TOTAL_DIFFS} diff(s) are documented acceptable classes (decoded evidence in comparison/):
$(echo "${SEMANTIC_NOTES}" | sed '/^$/d; s/^/    - /')"
  else
    verdict="not_reproducible"
  fi
  case "${INPUT_KIND}" in
    split)
      if [[ "${APK_INPUT_IS_DIR}" == "true" ]]; then
        head="Split-set mode: all supplied official splits vs matching built splits from ${GIT_TAG}."
      else
        head="Split mode: official $(basename "${OFFICIAL_APK}") vs built split from ${GIT_TAG}."
      fi ;;
    universal) head="Universal mode: official Play universal APK vs bundletool --mode=universal render of the AAB built from ${GIT_TAG}." ;;
    *) head="Fat-APK mode: official APK vs built ${GRADLE_TASK} output from ${GIT_TAG}." ;;
  esac
  generate_comparison_yaml "${verdict}" "${head}
  Input kind: ${INPUT_KIND} (detected from the manifest).
  Build: ./gradlew ${GRADLE_TASK} with disorderfs (reproducible directory ordering).
  Non-META-INF diffs: ${TOTAL_DIFFS}.${semantic_summary}"
  print_results_block "${verdict}"
  RESULT_DONE=true
  reclaim_workspace
  if [[ "${should_cleanup}" == "true" ]]; then
    log_info "Cleaning up ${WORK_DIR}..."
    rm -rf "${WORK_DIR}"
  else
    log_info "Work directory preserved: ${WORK_DIR}"
  fi
  if [[ "${verdict}" == "reproducible" ]]; then
    echo "Exit code: ${EXIT_SUCCESS}"
    exit "${EXIT_SUCCESS}"
  fi
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
detect_container_runtime
parse_arguments "$@"
prepare
build
extract_and_compare
result
