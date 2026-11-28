#!/usr/bin/env bash
# bitkit-v0.4.0_build.sh - Bitkit (to.bitkit) Android reproducible build verification
# Version:       v0.4.0
# Organization:  WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-28
# Project:       https://github.com/synonymdev/bitkit-android
# DISCLAIMER: provided as-is, without warranty; review before running. CPU, RAM and disk heavy.
# SUMMARY: builds a per-run image (Ubuntu 22.04 by digest, JDK 17 Zulu, SDK 36, NDK, bundletool);
# clones the version tag in a container and runs bundleMainnetRelease; makes Play's SDK 32+ splits
# from a copy of the AAB (sparseEncoding=VARIANT_FOR_SDK_32) with bundletool; compares them split by
# split with the official Play splits given by --binary; writes COMPARISON_RESULTS.yaml next to the
# script. GITHUB_TOKEN (read:packages) is needed: the com.synonym AARs come from GitHub Packages. It
# is read from the environment, passed by name only, and masked (***) in the build output.
# Library ws-rb-core (#1023); build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library; 130 stopped.

SCRIPT_NAME="bitkit-v0.4.0_build.sh"
SCRIPT_VERSION="v0.4.0"
SCRIPT_SHA256="$(sha256sum "$(readlink -f "$0")" 2>/dev/null | awk '{print $1}')"
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "${SCRIPT_NAME} ${SCRIPT_VERSION} sha256:${SCRIPT_SHA256}"

set -euo pipefail

# ---- WalletScrutiny library (GitLab #1023), pinned by sha256: standard loader ----
WS_LIB_DIR0="$(dirname "$(readlink -f "$0")")"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WS_LIB_DIR0/.comparison_results.lock" true 2>/dev/null && rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
else
  WS_LIB_P="$(cat "$WS_LIB_DIR0/.comparison_results.lock.d/pid" 2>/dev/null || true)"
  case "$WS_LIB_P" in ''|*[!0-9]*) WS_LIB_P="";; esac
  { [ -n "$WS_LIB_P" ] && kill -0 "$WS_LIB_P" 2>/dev/null; } || rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
fi
WS_LIB=ws-rb-core WS_LIB_VERSION=1.1.0
WS_LIB_REV=3bafe3b5961f11bcf1fa4fbbe3f4f206d53a61d0 WS_LIB_SHA256=4f0920dc8edb1e07aefbb4748d72fd3cc011eb769aaa40de8b5a6a9026312c7e
ws_lib_load() {
  local c f u t=""
  ws_lib_ok() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$WS_LIB_SHA256" ]; }
  if [ -n "${WS_LIB_FILE:-}" ]; then
    f="$WS_LIB_FILE"
    ws_lib_ok "$f" || { echo "[FAIL] WS_LIB_FILE $f is not sha256 $WS_LIB_SHA256: no verdict" >&2; exit 2; }
  else
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
  WS_LIB_PATH="$f" WS_LIB_TMP="$t"
  . "$f"
  [ -z "$t" ] || [ -n "${WS_LIB_MOUNT:-}" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load

readonly APP_ID="to.bitkit"
readonly REPO_URL="https://github.com/synonymdev/bitkit-android.git"
readonly BASE_IMG="docker.io/library/ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb"
readonly CMDLINE_SHA256="2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"
readonly NDK_VERSION="28.1.13356709"  # upstream release.yml NDK_VERSION
readonly BUNDLETOOL_VERSION="1.18.3"  # = bundletool that AGP used to build the AAB
readonly BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
readonly BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
readonly BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"
IMG="localhost/ws-bitkit:${WS_RUN_ID}"
VERSION=""
ARCH=""
APK_INPUT=""
INPUT_IS_DIR=false
INPUT_IS_ZIP=false
WORK_DIR=""
CTR=()
CONTAINER_RUN_EXTRA=""
VOLUME_RO=":ro"
VOLUME_RW=""
github_token=""
should_cleanup=false
OFFICIAL_APK=""
OFFICIAL_BASE_APK=""
BUILT_AAB=""
GIT_TAG=""
COMMIT=""
BUILD_LOCK_FILE=""
TOTAL_DIFFS=1
LEAK_DONE=0

ws_refuse_root
ws_install_traps

# Replaces GITHUB_TOKEN with *** in each output line.
read -r -d '' MASK_AWK <<'EOF' || true
BEGIN { t = ENVIRON["GITHUB_TOKEN"] }
{ s = $0; o = ""; if (t != "") while ((i = index(s, t)) > 0) { o = o substr(s, 1, i - 1) "***"; s = substr(s, i + length(t)) }
  print o s; fflush() }
EOF
# grep_tok PATH...: token via a file descriptor, never an argument; grep's status.
grep_tok() { grep -rlsF -f <(printf '%s\n' "$GITHUB_TOKEN") "$@"; }
# At exit: stop this run's containers, then count workspace files holding the token.
ws_cleanup_hook() {
    local x rc=0 n
    [[ -z "${WS_ENGINE:-}" || "${WS_KEEP:-}" == 1 ]] || for x in "${WS_CONTAINERS[@]}"; do ws_ctr rm -f "$x" &>/dev/null || true; done
    [[ "$LEAK_DONE" -eq 0 && -n "${GITHUB_TOKEN:-}" && -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
    LEAK_DONE=1
    n="$(grep_tok "$WORK_DIR" | wc -l)" || rc=$?
    if [[ "${n:-0}" -gt 0 ]]; then ws_warn "GITHUB_TOKEN found in ${n} workspace file(s); do not share them."
    elif [[ "$rc" -le 1 ]]; then ws_ok "Token scan: GITHUB_TOKEN is in no workspace file."
    else ws_warn "Token scan of ${WORK_DIR} incomplete: check files before sharing them."; fi
}
container_exec() {
    local cmd="$1"
    ws_ctr run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${IMG}" \
        bash -c "${cmd}"
}
container_sha256() {
    local file_path="$1"
    ws_ctr run --rm \
        -v "$(dirname "${file_path}"):/data${VOLUME_RO}" \
        "${IMG}" \
        bash -c "sha256sum /data/$(basename "${file_path}") | awk '{print \$1}'"
}
container_signer() {
    local apk_path="$1"
    ws_ctr run --rm \
        -v "$(dirname "${apk_path}"):/apk${VOLUME_RO}" \
        "${IMG}" \
        bash -c "apksigner verify --print-certs /apk/$(basename "${apk_path}") 2>/dev/null \
                 | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || echo "unknown"
}
container_aapt_version() {
    local apk_path="$1"
    local field="$2"
    local apk_dir apk_name
    apk_dir="$(dirname "${apk_path}")"
    apk_name="$(basename "${apk_path}")"
    ws_ctr run --rm \
        -v "${apk_dir}:/apk${VOLUME_RO}" \
        -e "APK_NAME=${apk_name}" \
        -e "FIELD=${field}" \
        "${IMG}" \
        bash -c 'aapt dump badging "/apk/${APK_NAME}" 2>/dev/null \
            | sed -n "s/.*${FIELD}='"'"'\([^'"'"']*\)'"'"'.*/\1/p" | head -n1' 2>/dev/null || true
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
    local n f; n="$(basename "$1")"
    for f in "$2/${n}" "$2/$(canonicalize_split_apk_name "${n}")"; do
        [[ -f "${f}" ]] && { echo "${f}"; return 0; }
    done
    return 1
}
find_base_apk() {  # $1 = directory
    local f
    for f in "$1"/{base.apk,base-master.apk} "$1"/base*.apk; do
        [[ -f "${f}" ]] && { echo "${f}"; return; }
    done
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
    ws_info "device-spec.json created (arch=${arch}, screenDensity=480, sdkVersion=36, supportedLocales=[en])"
}
write_java_tools() {
    mkdir -p "${WORK_DIR}/tools"
    # SetSparse: copy the AAB entry by entry; only BundleConfig.pb changes.
    cat > "${WORK_DIR}/tools/SetSparse.java" <<'JEOF'
import java.io.*; import java.util.*; import java.util.zip.*; import com.android.bundle.Config.*;
public class SetSparse { public static void main(String[] a) throws Exception {
  try (ZipFile in = new ZipFile(a[0]); ZipOutputStream out = new ZipOutputStream(new FileOutputStream(a[1]))) {
    for (Enumeration<? extends ZipEntry> en = in.entries(); en.hasMoreElements();) {
      ZipEntry e = en.nextElement(); byte[] b = in.getInputStream(e).readAllBytes();
      if (e.getName().equals("BundleConfig.pb")) {
        BundleConfig.Builder c = BundleConfig.parseFrom(b).toBuilder();
        ResourceOptimizations.Builder r = c.getOptimizationsBuilder().getResourceOptimizationsBuilder();
        System.out.println("BundleConfig sparseEncoding: " + r.getSparseEncoding() + " -> VARIANT_FOR_SDK_32");
        r.setSparseEncoding(ResourceOptimizations.SparseEncoding.VARIANT_FOR_SDK_32);
        b = c.build().toByteArray(); }
      ZipEntry o = new ZipEntry(e.getName()); o.setTime(e.getTime());
      if (e.getMethod() == ZipEntry.STORED) { CRC32 k = new CRC32(); k.update(b);
        o.setMethod(ZipEntry.STORED); o.setSize(b.length); o.setCompressedSize(b.length); o.setCrc(k.getValue()); }
      out.putNextEntry(o); out.write(b); out.closeEntry(); } } } }
JEOF
    # ArscCheck: Play writes ResTable_typeSpec.typesCount (number of ResTable_type chunks that
    # follow); bundletool writes 0. Zero that field on both sides only where it equals the real
    # count, then compare every byte. Exit 0 only if nothing else differs.
    cat > "${WORK_DIR}/tools/ArscCheck.java" <<'JEOF'
import java.nio.*; import java.nio.file.*;
public class ArscCheck {
  static int fix(ByteBuffer d, int s, int n) { int tc = d.getShort(s + 10) & 0xffff;
    if (tc != 0 && tc != n) throw new IllegalStateException("typesCount " + tc + " != " + n + " type chunks");
    d.putShort(s + 10, (short) 0); return tc != 0 ? 1 : 0; }
  static int mask(ByteBuffer d) { int k = 0, p = d.getShort(2) & 0xffff;
    while (p < d.capacity()) { int t = d.getShort(p) & 0xffff, h = d.getShort(p + 2) & 0xffff, z = d.getInt(p + 4);
      if (t == 0x200) { int q = p + h, s = -1, n = 0;
        while (q < p + z) { int c = d.getShort(q) & 0xffff;
          if (c == 0x202) { if (s >= 0) k += fix(d, s, n); s = q; n = 0; } else if (c == 0x201 && s >= 0) n++;
          q += d.getInt(q + 4); }
        if (s >= 0) k += fix(d, s, n); }
      p += z; }
    return k; }
  public static void main(String[] a) throws Exception {
    ByteBuffer o = ByteBuffer.wrap(Files.readAllBytes(Paths.get(a[0]))).order(ByteOrder.LITTLE_ENDIAN);
    ByteBuffer b = ByteBuffer.wrap(Files.readAllBytes(Paths.get(a[1]))).order(ByteOrder.LITTLE_ENDIAN);
    int no, nb; try { no = mask(o); nb = mask(b); } catch (IllegalStateException e) { System.out.println(e.getMessage()); System.exit(3); return; }
    boolean same = o.equals(b);
    System.out.println(same ? "typesCount only: set in " + no + " official / " + nb + " built typeSpecs, each equal to its type-chunk count; all other bytes identical"
                            : "resources.arsc bytes differ beyond typesCount");
    System.exit(same ? 0 : 3); } }
JEOF
    # play_meta.awk: move the meta-data Google Play adds (exact names/values) out of the
    # OFFICIAL manifest dump into the -v out file, which the log prints.
    cat > "${WORK_DIR}/tools/play_meta.awk" <<'AEOF'
function ok(s) { return (s ~ /"com\.android\.stamp\.source"/ && s ~ /="https:\/\/play\.google\.com\/store"/) ||
  (s ~ /"com\.android\.stamp\.type"/ && s ~ /="STAMP_TYPE_DISTRIBUTION_APK"/) ||
  (s ~ /"com\.android\.vending\.derived\.apk\.id"/ && s ~ /=\(type 0x10\)0x[0-9a-f]+$/) }
function flush() { if (held) print buf; held = 0 }
/^ *E: meta-data/ { flush(); held = 1; buf = $0; n = 1; next }
held { buf = buf "\n" $0; if (++n == 3) { if (ok(buf)) { print buf > out; held = 0 } else flush() } next }
{ print }
END { flush() }
AEOF
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
    # Google Play serves SDK 32+ devices a variant with sparse resource encoding even when the
    # AAB's BundleConfig does not ask for it. bundletool makes the same variant only when the
    # config says VARIANT_FOR_SDK_32, so set that on a COPY of the AAB (nothing else changes).
    ws_info "Setting BundleConfig sparseEncoding=VARIANT_FOR_SDK_32 on a copy of the AAB (Play's SDK 32+ variant)..."
    write_java_tools
    ws_ctr run --rm ${CONTAINER_RUN_EXTRA} -v "${WORK_DIR}:/work${VOLUME_RW}" -w /work "${IMG}" \
        java -cp /usr/local/lib/bundletool.jar tools/SetSparse.java "${aab_rel}" built-sdk32.aab
    aab_rel="built-sdk32.aab"
    ws_info "Running bundletool ${BUNDLETOOL_VERSION} to extract split APKs from ${aab_rel}..."
    ws_ctr run --rm \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}:/work${VOLUME_RW}" \
        -w /work \
        "${IMG}" \
        bash -c "
            set -euo pipefail
            java -jar /usr/local/lib/bundletool.jar build-apks \
                --bundle='${aab_rel}' \
                --output='${apks_rel}' \
                --device-spec='${device_spec_rel}' \
                --mode=default \
                --overwrite 2>&1
            mkdir -p '${output_rel}'
            unzip -qq -o '${apks_rel}' -d '${output_rel}' 2>&1
            chmod -R a+rwX '${output_rel}' 2>/dev/null || true
        "
    local f n d="${output_dir}/splits"
    for f in "${d}"/base-*.apk; do  # bundletool names -> Play names
        [[ -f "${f}" ]] || continue
        n="$(canonicalize_split_apk_name "$(basename "${f}")")"
        mv "${f}" "${d}/${n}"
        ws_info "Built split: $(basename "${f}") -> ${n}"
    done
}
unzip_apk_in_container() {
    local apk_path="$1"
    local out_dir="$2"
    local apk_rel out_rel
    apk_rel="${apk_path#"${WORK_DIR}/"}"
    out_rel="${out_dir#"${WORK_DIR}/"}"
    # unzip exit != 0 (even a warning) is no verdict (ERR trap)
    container_exec "mkdir -p '${out_rel}' && unzip -qq '${apk_rel}' -d '${out_rel}' && \
        { chmod -R a+rwX '${out_rel}' 2>/dev/null || true; }"
}
# 0 when a diff line is only signing: official-only stamp-cert-sha256, or official-only root
# META-INF/MANIFEST.MF, *.SF, *.RSA, *.DSA, *.EC. Anything else in META-INF counts.
sig_line() {
    local l="$1" o="$2" f re='^(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))$'
    [[ "${l}" == "Only in ${o}: stamp-cert-sha256" ]] && return 0
    if [[ "${l}" == "Only in ${o}/META-INF: "* ]]; then
        [[ "${l#"Only in ${o}/META-INF: "}" =~ ${re} ]]; return; fi
    [[ "${l}" == "Only in ${o}: META-INF" ]] || return 1
    while IFS= read -r f; do [[ "${f}" =~ ${re} ]] || return 1
    done < <(cd "${WORK_DIR}/${o}/META-INF" && find . -mindepth 1 | sed 's|^\./||')
}
compare_apks() {
    local official_apk="$1"
    local built_apk="$2"
    local split_label="$3"
    local results_dir="${WORK_DIR}/comparison"
    mkdir -p "${results_dir}"
    ws_info "Comparing split: ${split_label}"
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
        > '${diff_rel}' 2>&1 || [ \$? -eq 1 ]"  # diff error (2): no verdict
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true
    local total_lines=0
    local non_meta_count=0
    if [[ -s "${diff_file}" ]]; then
        total_lines="$(wc -l < "${diff_file}")"
        local line
        while IFS= read -r line; do
            [[ "${line}" =~ ^(Only\ in|Files|Binary\ files|diff\ -r)\  ]] || continue
            sig_line "${line}" "${official_rel}" && continue
            # decoded and judged below (decode_and_diff_binaries)
            [[ "${line}" =~ ^(Binary\ files|Files)\ ${official_rel}/(AndroidManifest\.xml|resources\.arsc)\ and ]] && continue
            non_meta_count=$(( non_meta_count + 1 ))
        done < "${diff_file}"
    fi
    TOTAL_DIFFS=$(( TOTAL_DIFFS + non_meta_count ))
    ws_info "  ${split_label}: ${non_meta_count} non-signing diff(s) (${total_lines} total diff lines)"
    if [[ -s "${diff_file}" ]]; then
        ws_info "  First 5 lines (full diff: ${diff_file}):"
        head -5 "${diff_file}" | while IFS= read -r line; do echo "    ${line}"; done
        if [[ "${total_lines}" -gt 5 ]]; then
            ws_info "    ... (${total_lines} total lines — see ${diff_file})"
        fi
    else
        ws_ok "  ${split_label}: no differences"
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
    ws_info "  Decoding binary files for deeper diff (${split_label})..."
    local official_rel built_rel results_rel
    official_rel="${official_apk#"${WORK_DIR}/"}"
    built_rel="${built_apk#"${WORK_DIR}/"}"
    results_rel="${results_dir#"${WORK_DIR}/"}"
    # A failed or empty decode is no verdict, never "identical".
    local decode_cmds="set -e"
    if [[ "${has_manifest}" -eq 1 ]]; then
        local mf_rel="${results_rel}/diff_manifest_${split_label}.txt"
        local pa_rel="${results_rel}/play_additions_${split_label}.txt"
        decode_cmds+="
        aapt dump xmltree '${official_rel}' AndroidManifest.xml > /tmp/o_mf.txt
        aapt dump xmltree '${built_rel}' AndroidManifest.xml > /tmp/b_mf.txt
        [ -s /tmp/o_mf.txt ] || exit 2; [ -s /tmp/b_mf.txt ] || exit 2
        : > '${pa_rel}'
        awk -v out='${pa_rel}' -f tools/play_meta.awk /tmp/o_mf.txt > /tmp/o_mf_f.txt
        diff /tmp/o_mf_f.txt /tmp/b_mf.txt > '${mf_rel}' || [ \$? -eq 1 ]"
    fi
    if [[ "${has_resources}" -eq 1 ]]; then
        local rs_rel="${results_rel}/diff_resources_${split_label}.txt"
        decode_cmds+="
        aapt dump resources '${official_rel}' > /tmp/o_rs.txt
        aapt dump resources '${built_rel}' > /tmp/b_rs.txt
        [ -s /tmp/o_rs.txt ] || exit 2; [ -s /tmp/b_rs.txt ] || exit 2
        diff /tmp/o_rs.txt /tmp/b_rs.txt > '${rs_rel}' || [ \$? -eq 1 ]"
    fi
    container_exec "${decode_cmds}"
    chmod -R a+rwX "${results_dir}" 2>/dev/null || true
    local pa_file="${results_dir}/play_additions_${split_label}.txt"
    if [[ -s "${pa_file}" ]]; then
        ws_info "  Google Play manifest additions (official only), left out of the manifest diff:"
        grep -o 'android:name([^)]*)="[^"]*"' "${pa_file}" | sed 's/.*="\(.*\)"/    \1/'
    fi
    for _f in "${results_dir}/diff_manifest_${split_label}.txt" \
              "${results_dir}/diff_resources_${split_label}.txt"; do
        if [[ -f "${_f}" && ! -s "${_f}" ]]; then
            echo "# Decoded output identical apart from the Google Play additions listed in the log" \
                > "${_f}" 2>/dev/null || true
        fi
    done
    local rs_file="${results_dir}/diff_resources_${split_label}.txt"
    if [[ "${has_resources}" -eq 1 ]] && grep -q "Decoded output identical" "${rs_file}" 2>/dev/null; then
        # ArscCheck: 0 same but typesCount, 3 differs, else no verdict
        local arsc_out arsc_rc=0
        arsc_out="$(container_exec "java tools/ArscCheck.java '${results_rel}/official_${split_label}/resources.arsc' '${results_rel}/built_${split_label}/resources.arsc'" 2>&1)" || arsc_rc=$?
        if [[ "${arsc_rc}" -eq 0 ]]; then
            ws_info "  resources.arsc: ${arsc_out}"
        elif [[ "${arsc_rc}" -eq 3 ]]; then
            ws_warn "  resources.arsc: ${arsc_out}"
            echo "# ${arsc_out}" > "${rs_file}"
        else
            ws_no_verdict "ArscCheck failed (exit ${arsc_rc}) on ${split_label}: ${arsc_out:0:300}"
        fi
    fi
    for decoded_diff in \
        "${results_dir}/diff_manifest_${split_label}.txt" \
        "${results_dir}/diff_resources_${split_label}.txt"; do
        [[ -f "${decoded_diff}" ]] || continue
        local dlabel dlines
        dlabel="$(basename "${decoded_diff}" .txt)"
        if [[ -s "${decoded_diff}" ]]; then
            dlines="$(wc -l < "${decoded_diff}")"
            ws_info "  ${dlabel} (${dlines} lines — full: ${decoded_diff}):"
            head -5 "${decoded_diff}" | while IFS= read -r line; do echo "    ${line}"; done
            if [[ "${dlines}" -gt 5 ]]; then
                ws_info "    ... (${dlines} total lines)"
            fi
        else
            ws_ok "  ${dlabel}: no differences after decoding"
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
        local split_non_sig=false shown=0 more=0
        while IFS= read -r line; do
            local fname="" side="" tag=""
            if [[ "${line}" =~ ^diff\ -r\ ${prefix_o}/(.+)\ ${prefix_b}/ ]]; then
                fname="${BASH_REMATCH[1]}"
            elif [[ "${line}" =~ ^Binary\ files\ ${prefix_o}/(.+)\ and\ ${prefix_b}/.+\ differ$ ]]; then
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
            if sig_line "${line}" "${prefix_o}"; then
                tag=" [signing]"
            elif [[ "${fname}" == "AndroidManifest.xml" ]]; then
                local dm="${results_dir}/diff_manifest_${split_label}.txt"
                if [[ -f "${dm}" ]] && grep -q "Decoded output identical" "${dm}" 2>/dev/null; then
                    tag=" [decoded: identical apart from Google Play additions]"
                else
                    tag=" [decoded: see diff_manifest_${split_label}.txt]"
                fi
            elif [[ "${fname}" == "resources.arsc" ]]; then
                local dr="${results_dir}/diff_resources_${split_label}.txt"
                if [[ -f "${dr}" ]] && grep -q "Decoded output identical" "${dr}" 2>/dev/null; then
                    tag=" [decoded: identical; typesCount header only]"
                else
                    tag=" [decoded: see diff_resources_${split_label}.txt]"
                fi
            else
                tag=" *** NON-SIGNATURE ***"
                split_non_sig=true
            fi
            if [[ "${shown}" -lt 5 ]]; then echo "    - ${fname}${side}${tag}"; shown=$(( shown + 1 ))
            else more=$(( more + 1 )); fi
        done < "${diff_file}"
        [[ "${more}" -eq 0 ]] || echo "    ... ${more} more (full list: ${diff_file})"
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
    local meta_apk="${OFFICIAL_BASE_APK:-${OFFICIAL_APK}}"
    local version_name version_code signer app_hash tag_info d
    version_name="$(container_aapt_version "${meta_apk}" "versionName" || true)"
    version_code="$(container_aapt_version "${meta_apk}" "versionCode" || true)"
    signer="$(container_signer "${OFFICIAL_APK}" || true)"
    app_hash="$(container_sha256 "${OFFICIAL_APK}" || true)"
    tag_info="  (tag verification not available)"
    [[ ! -s "${WORK_DIR}/built-output/tag_verify.txt" ]] || tag_info="$(awk "${MASK_AWK}" "${WORK_DIR}/built-output/tag_verify.txt")"
    d="$(print_split_comparison_block)"$'\n\n'"Revision, tag (and its signature):"$'\n'"${tag_info}"
    echo ""
    ws_results_block "${APP_ID}" "${signer:-unknown}" "${version_name:-${VERSION}}" "${version_code:-unknown}" \
        "${verdict}" "${app_hash:-unknown}" "${COMMIT:-unknown}" "${d}"
    echo ""
    echo "Hash legend: appHash = SHA-256 of the official $(basename "${OFFICIAL_APK}") as supplied (publish this one)."
    [[ -z "$BUILD_LOCK_FILE" ]] || echo "build-lock.json (attach as output file): ${BUILD_LOCK_FILE}"
    if [[ "${should_cleanup}" != "true" ]]; then
        echo "Work directory: ${WORK_DIR}"
        echo "Diff files:     ${WORK_DIR}/comparison/"
    fi
}
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --binary <split dir|.zip of splits|split APK> (alias --apk) [--version V]
  [--arch arm64-v8a] [--type (unused)] [--cleanup]
  Env GITHUB_TOKEN (read:packages), required; never pass it as an argument (ps would show it).
Exit: 0 reproducible, 1 not_reproducible/ftbfs/no verdict, 2 invalid input
EOF
}
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)        ws_require_value "$1" "${2:-}"; VERSION="${2#v}"; shift 2 ;;
            --apk|--binary)   ws_require_value "$1" "${2:-}"; APK_INPUT="$2"; shift 2 ;;
            --arch)           ws_require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
            --type)           ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;  # unused for Bitkit
            --cleanup)        should_cleanup=true; shift ;;
            --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            --help|-h)        usage; exit 0 ;;
            *)                ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;
        esac
    done
    github_token="${GITHUB_TOKEN:-}"
    [[ -n "${APK_INPUT}" ]] || ws_invalid "--binary <split dir|split APK|.zip> is required."
    APK_INPUT="$(realpath -e -- "${APK_INPUT}" 2>/dev/null)" || ws_invalid "--binary path not found."
    if [[ -d "${APK_INPUT}" ]]; then
        INPUT_IS_DIR=true
        ws_info "--binary is a directory; all *.apk files will be compared."
    elif [[ "${APK_INPUT,,}" == *.zip ]]; then
        INPUT_IS_ZIP=true
        ws_info "--binary is a zip; its APKs are extracted in a container."
    elif [[ "${APK_INPUT}" != *.apk ]]; then
        ws_invalid "--binary must be a directory of split APKs, a .zip of them, or one .apk file: ${APK_INPUT}"
    fi
    ARCH="${ARCH:-arm64-v8a}"
    case "${ARCH}" in
        arm64-v8a|armeabi-v7a|x86_64) ;;
        *) ws_invalid "Unsupported --arch '${ARCH}'" ;;
    esac
    [[ -z "${VERSION}" || "${VERSION}" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || ws_invalid "Unsafe version string: ${VERSION}"
    [[ -n "${github_token}" ]] || ws_invalid "GitHub token required: the com.synonym:* AARs are on GitHub Packages, which needs a PAT with read:packages even for public packages. Set GITHUB_TOKEN."
    export GITHUB_TOKEN="${github_token}"  # podman gets it by name (-e GITHUB_TOKEN), never by value
    ws_info "Arch: ${ARCH}"
    ws_info "APK input: ${APK_INPUT}"
}
build_image() {
    ws_section "BUILD IMAGE (per-run ${IMG}, removed at exit)"
    ws_info "JDK 17 Zulu, SDK 36, NDK ${NDK_VERSION}, bundletool ${BUNDLETOOL_VERSION}; 10-20 min."
    local dockerfile_path="${WORK_DIR}/Dockerfile.build"
    cat > "${dockerfile_path}" <<DOCKERFILE_END
FROM ${BASE_IMG}
ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV JAVA_HOME=/usr/lib/jvm/zulu17-ca-amd64
RUN apt-get update -q && \\
    apt-get install -y --no-install-recommends \\
        ca-certificates curl wget git unzip gnupg lsb-release apt-transport-https \\
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://repos.azul.com/azul-repo.key | gpg --dearmor \\
        -o /usr/share/keyrings/azul.gpg && \\
    echo "deb [signed-by=/usr/share/keyrings/azul.gpg] https://repos.azul.com/zulu/deb stable main" \\
        > /etc/apt/sources.list.d/zulu.list && \\
    apt-get update -q && \\
    apt-get install -y --no-install-recommends zulu17-ca-jdk && \\
    rm -rf /var/lib/apt/lists/*
RUN mkdir -p "\${ANDROID_HOME}" /root/.android && \\
    touch /root/.android/repositories.cfg && \\
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o /tmp/sdk.zip && \\
    echo "${CMDLINE_SHA256}  /tmp/sdk.zip" | sha256sum -c - && \\
    unzip -q /tmp/sdk.zip -d "\${ANDROID_HOME}" && \\
    rm -f /tmp/sdk.zip
ENV PATH="/opt/android-sdk/cmdline-tools/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.0:/opt/android-sdk/build-tools/36.0.0:/usr/lib/jvm/zulu17-ca-amd64/bin:\${PATH}"
RUN yes | "\${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" --sdk_root="\${ANDROID_HOME}" --licenses && \\
    "\${ANDROID_HOME}/cmdline-tools/bin/sdkmanager" --sdk_root="\${ANDROID_HOME}" \\
        "platform-tools" "platforms;android-36" "build-tools;35.0.0" "build-tools;36.0.0" "ndk;${NDK_VERSION}" && \\
    chmod -R a+rwX "\${ANDROID_HOME}"
RUN curl -fL "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" \\
        -o /usr/local/lib/bundletool.jar && \\
    echo "${BUNDLETOOL_SHA256}  /usr/local/lib/bundletool.jar" | sha256sum -c - && chmod 0644 /usr/local/lib/bundletool.jar
CMD ["bash"]
DOCKERFILE_END
    ws_track_image "${IMG}"
    local bargs=(-f "${dockerfile_path}" -t "${IMG}")
    [[ "${WS_ENGINE}" != podman ]] || bargs=(--format docker "${bargs[@]}")
    ws_ctr build "${bargs[@]}" "${WORK_DIR}" || ws_no_verdict "Build image failed (network, apt or registry?); see the output above."
    ws_ok "Build image ${IMG} ready."
}
resolve_git_tag() {
    local version="$1"
    local candidates=("v${version}" "${version}")
    ws_info "Resolving git tag for version ${version}..."
    for candidate in "${candidates[@]}"; do
        if ws_ctr run --rm "${IMG}" git ls-remote --tags --exit-code "${REPO_URL}" \
                "refs/tags/${candidate}" >/dev/null 2>&1; then
            ws_info "Found tag: ${candidate}"
            GIT_TAG="${candidate}"
            return 0
        fi
        ws_info "  Tag ${candidate}: not found"
    done
    return 1
}
prepare() {
    ws_section "PREPARE"
    local src pkg abi n f apk can copy_count=0 off="${WORK_DIR}/official-split-apks"
    mkdir -p "${off}" "${WORK_DIR}/built-output" "${WORK_DIR}/tools"
    chmod 777 "${WORK_DIR}/built-output"
    cat > "${WORK_DIR}/tools/check_splits.sh" <<'SEOF'
set -eu
d="$1" app="$2" abi="$3" want=""
for a in "$d"/*.apk; do
  l="$(aapt dump badging "$a" | head -n1)"
  p="$(printf '%s' "$l" | sed -n "s/.* name='\([^']*\)'.*/\1/p")"
  c="$(printf '%s' "$l" | sed -n "s/.* versionCode='\([^']*\)'.*/\1/p")"
  [ "$p" = "$app" ] && [ -n "$c" ] || { echo "${a##*/}: package '$p' versionCode '$c'"; exit 3; }
  [ -n "$want" ] || want="$c"
  [ "$c" = "$want" ] || { echo "${a##*/}: versionCode $c, others $want"; exit 3; }
  for x in $(unzip -Z1 "$a" 'lib/*' 2>/dev/null | cut -d/ -f2 | sort -u); do
    [ "$x" = "$abi" ] || { echo "${a##*/}: native code for $x, not $abi"; exit 3; }
  done
done
SEOF
    src="${APK_INPUT}"
    if [[ "${INPUT_IS_ZIP}" == "true" ]]; then
        cp "${APK_INPUT}" "${WORK_DIR}/input.zip"
        container_exec "mkdir -p zip-extracted && unzip -qq input.zip -d zip-extracted"
        src="${WORK_DIR}/zip-extracted"
    fi
    # Stage copies first: every probe reads these, never the caller's files.
    while IFS= read -r apk; do
        can="$(canonicalize_split_apk_name "$(basename "${apk}")")"
        [[ "${can}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$ ]] || ws_invalid "Unsafe APK file name: ${can}"
        [[ ! -e "${off}/${can}" ]] || ws_invalid "Two input APKs map to ${can}; give one split set."
        cp "${apk}" "${off}/${can}"
        ws_info "  Copied: $(basename "${apk}") -> ${can}"
        copy_count=$(( copy_count + 1 ))
    done < <(if [[ "${INPUT_IS_ZIP}" == "true" ]]; then find "${src}" -name "*.apk"
             elif [[ "${INPUT_IS_DIR}" == "true" ]]; then find "${src}" -maxdepth 1 -name "*.apk"; else echo "${src}"; fi)
    [[ "${copy_count}" -gt 0 ]] || ws_invalid "No *.apk in ${APK_INPUT}."
    if [[ "${INPUT_IS_DIR}" == "true" || "${INPUT_IS_ZIP}" == "true" ]]; then
        OFFICIAL_APK="${off}/base.apk"
        [[ -f "${OFFICIAL_APK}" ]] || ws_invalid "No base.apk among the splits in ${APK_INPUT}."
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"
    else
        OFFICIAL_APK="${off}/$(canonicalize_split_apk_name "$(basename "${APK_INPUT}")")"
        OFFICIAL_BASE_APK="${OFFICIAL_APK}"
        f="$(find_base_apk "$(dirname "${APK_INPUT}")" || true)"
        if [[ -n "${f}" && "${OFFICIAL_APK##*/}" != base.apk ]]; then
            cp "${f}" "${WORK_DIR}/metadata-base.apk"
            OFFICIAL_BASE_APK="${WORK_DIR}/metadata-base.apk"
        fi
    fi
    abi="$(find "${off}" -name 'split_config.*.apk' -printf '%f\n' \
        | sed -n 's/^split_config\.\(arm64_v8a\|armeabi_v7a\|x86_64\|x86\)\.apk$/\1/p')"
    n="$(printf '%s\n' "${abi}" | grep -c . || true)"
    [[ "${n}" -le 1 ]] || ws_invalid "Several ABI splits (${abi//$'\n'/ }); give one split set."
    pkg="$(container_aapt_version "${OFFICIAL_BASE_APK}" "package: name" || true)"
    if [[ "${pkg}" != "${APP_ID}" || ( -n "${abi}" && "${abi}" != "${ARCH//-/_}" ) ]]; then
        ws_invalid "Input is package '${pkg:-unknown}' ABI '${abi:-none}'; expected ${APP_ID} ${ARCH}"
    fi
    # Every staged split: same package and versionCode as the others, native code only for --arch.
    local sc_out sc_rc=0
    sc_out="$(container_exec "bash tools/check_splits.sh official-split-apks '${APP_ID}' '${ARCH}'" 2>&1)" || sc_rc=$?
    [[ "${sc_rc}" -ne 3 ]] || ws_invalid "Split set mismatch: ${sc_out}"
    [[ "${sc_rc}" -eq 0 ]] || ws_no_verdict "Split check failed (exit ${sc_rc}): ${sc_out:0:300}"
    if [[ -z "${VERSION}" ]]; then
        VERSION="$(container_aapt_version "${OFFICIAL_BASE_APK}" "versionName" || true)"
        [[ "${VERSION}" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || ws_invalid "Could not read a valid versionName from the base APK; pass --version."
        ws_info "Version detected: ${VERSION}"
        # Rename this run's workspace: exclusive mkdir, then replace that empty dir.
        f="${WS_CALLER_DIR}/bitkit_verification_$(ws_sanitize "${VERSION}")_$(ws_sanitize "${ARCH}")_${WS_RUN_ID}"
        mkdir "${f}" && mv -T "${WORK_DIR}" "${f}" || ws_no_verdict "Cannot rename ${WORK_DIR} to ${f}."
        OFFICIAL_APK="${f}${OFFICIAL_APK#"${WORK_DIR}"}" OFFICIAL_BASE_APK="${f}${OFFICIAL_BASE_APK#"${WORK_DIR}"}"
        WS_WORKDIR="${f}" WORK_DIR="${f}"
        ws_info "Work directory: ${WORK_DIR}"
    fi
    ws_ok "Package ${pkg}, ABI split ${abi:-none} (--arch ${ARCH}), version ${VERSION}"
    create_device_spec "${WORK_DIR}/device-spec.json" "${ARCH}"
}
build() {
    ws_section "BUILD"
    resolve_git_tag "${VERSION}" || ws_no_verdict "No tag v${VERSION} or ${VERSION} in ${REPO_URL} (or no network)."
    ws_info "Git tag: ${GIT_TAG}"
    ws_info "Build: bundleMainnetRelease --no-build-cache --no-configuration-cache; GITHUB_TOKEN passed by name, output masked."
    ws_info "Cloning + building in container. Typically 30-60 minutes."
    local rc=0 n="bitkit-${WS_RUN_ID}-build"
    ws_track_container "${n}"
    # Wrapper: exit 90 if the mask or log failed, else the container's exit code.
    bash -c 'l="$1" m="$2"; shift 2; "$@" < /dev/null 2>&1 | awk "$m" | tee "$l"; s=("${PIPESTATUS[@]}"); [[ ${s[1]} == 0 && ${s[2]} == 0 ]] || exit 90; exit "${s[0]}"' \
        _ "${WORK_DIR}/build.log" "${MASK_AWK}" "${CTR[@]}" run --rm --name "${n}" \
        ${CONTAINER_RUN_EXTRA} \
        -v "${WORK_DIR}/built-output:/workspace${VOLUME_RW}" \
        -e "HOME=/workspace" \
        -e "GRADLE_USER_HOME=/workspace/.gradle" \
        -e "ANDROID_HOME=/opt/android-sdk" \
        -e "ANDROID_SDK_ROOT=/opt/android-sdk" \
        -e "JAVA_HOME=/usr/lib/jvm/zulu17-ca-amd64" \
        -e "GITHUB_ACTOR=walletscrutiny" \
        -e "NDK_VERSION=${NDK_VERSION}" \
        -e GITHUB_TOKEN \
        "${IMG}" \
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
{\"project_info\": {\"project_number\": \"783092706332\",\"project_id\": \"bitkit-prod\",\"storage_bucket\": \"bitkit-prod.firebasestorage.app\"},\"client\": [{\"client_info\": {\"mobilesdk_app_id\": \"1:783092706332:android:1bc9125e3a0db5d3b703d9\",\"android_client_info\": {\"package_name\": \"to.bitkit\"}},\"api_key\": [{\"current_key\": \"AIzaSyDIdnCadyHRiBAwYaJHTcXh5gaK0kJbKLc\"}],\"services\": {\"appinvite_service\": {\"other_platform_oauth_client\": []}}}],\"configuration_version\": \"1\"}
GSEOF
            echo '[INFO] google-services.json written for mainnetRelease flavor.'
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
        " || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        # 90 log, 128 clone, 125+ runtime/kill: no verdict. Only exit 1 is classified.
        [[ "${rc}" -eq 1 ]] || ws_no_verdict "Build container exited ${rc} (clone, runtime, log or kill). Log: ${WORK_DIR}/build.log"
        local kind; kind="$(ws_gradle_failure_kind "${WORK_DIR}/build.log")"
        [[ "${kind}" == source ]] || ws_no_verdict "Build stopped (exit ${rc}, ${kind}); not a source error. Log: ${WORK_DIR}/build.log"
        ws_error "Gradle reports a source error at ${GIT_TAG} (exit ${rc})."
        ws_write_yaml ftbfs "Bitkit ${VERSION}: bundleMainnetRelease failed at tag ${GIT_TAG} with a compiler or resource error; log: build.log in the workspace."
        exit 1
    fi
    COMMIT="$(cat "${WORK_DIR}/built-output/commit.txt" 2>/dev/null || true)"
    [[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]] || ws_no_verdict "Could not read the commit of ${GIT_TAG}."
    chmod -R a+rwX "${WORK_DIR}/built-output" 2>/dev/null || true
    local aabs=()
    mapfile -t aabs < <(find "${WORK_DIR}/built-output/app/app/build/outputs/bundle" -name "*.aab" 2>/dev/null)
    [[ "${#aabs[@]}" -eq 1 ]] || ws_no_verdict "Expected one AAB under app/build/outputs/bundle, found ${#aabs[@]}."
    BUILT_AAB="${aabs[0]}"
    ws_ok "Built AAB: ${BUILT_AAB}"
}
build_lock() {
    ws_section "BUILD RECORD (ws-buildlock, verdict unaffected)"
    local bl_rc=0 bl_n=0 bl_t=0
    bl() { ws_ctr run --rm ${CONTAINER_RUN_EXTRA} -e HOME=/tmp -v "${WORK_DIR}:/w${VOLUME_RW}" -w /w "${IMG}" "$@"; }
    if bl curl -fsSL --max-time 60 -o /w/ws-buildlock.sh "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" \
       && [[ "$(ws_sha256 "${WORK_DIR}/ws-buildlock.sh")" == "${BUILDLOCK_SHA256}" ]]; then
        # Staged first: ABS uploads any build-lock/build-lock.json in its build dir.
        bl bash /w/ws-buildlock.sh --out /w/bl-staging --gradle-home /w/built-output/.gradle --src /w/built-output/app \
            --app-id "${APP_ID}" --version "${VERSION}" --platform android --commit "${COMMIT}" > "${WORK_DIR}/build-lock.log" 2>&1 || bl_rc=$?
        local s="${WORK_DIR}/bl-staging/build-lock.json"
        bl_n="$(grep -o '"ecosystem": *"gradle"' "${s}" 2>/dev/null | wc -l || true)"
        # Offered only if a regular file, no symlinks, and the token scan finds nothing (grep 1).
        if [[ -f "${s}" && ! -L "${s}" && -z "$(find "${WORK_DIR}/bl-staging" -type l)" ]]; then
            grep_tok "${s}" "${WORK_DIR}/bl-staging" >/dev/null || bl_t=$?
        fi
        if [[ "${bl_rc}" -eq 0 && "${bl_n:-0}" -gt 0 && "${bl_t}" -eq 1 ]] && mv -T "${WORK_DIR}/bl-staging" "${WORK_DIR}/build-lock"; then
            BUILD_LOCK_FILE="${WORK_DIR}/build-lock/build-lock.json"
            ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (${bl_n} Gradle artifacts, sha256 $(ws_sha256 "${BUILD_LOCK_FILE}"))"
        else
            ws_warn "No usable build-lock.json (exit ${bl_rc}, ${bl_n:-0} Gradle artifacts, token scan ${bl_t}; see ${WORK_DIR}/build-lock.log)."
        fi
    else
        ws_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256."
    fi
    rm -rf -- "${WORK_DIR}/bl-staging"
}
extract_and_compare() {
    ws_section "EXTRACT AND COMPARE"
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
        if built_split="$(resolve_built_split_apk "${official_apk}" "${built_splits_dir}/splits")"; then
            ws_info "Official ${split_name} <-> built $(basename "${built_split}")"
            compare_apks "${official_apk}" "${built_split}" "${split_label}"
            compared=$(( compared + 1 ))
        else
            ws_warn "No matching built split for: ${split_name} — skipping comparison"
            ws_info "  Built splits:"
            find "${built_splits_dir}" -name "*.apk" 2>/dev/null \
                | while IFS= read -r f; do echo "    $(basename "${f}")"; done
            TOTAL_DIFFS=$(( TOTAL_DIFFS + 1 ))
        fi
    done < <(find "${official_splits_dir}" -name "*.apk" 2>/dev/null | sort)
    [[ "${compared}" -gt 0 ]] || ws_no_verdict "No official splits were compared. Check official-split-apks directory."
    ws_info "Total splits compared: ${compared}"
    ws_info "Total non-signing diffs (across all splits): ${TOTAL_DIFFS}"
}
result() {
    ws_section "RESULT"
    local verdict
    if [[ "${TOTAL_DIFFS}" -eq 0 ]]; then
        verdict="reproducible"
        ws_ok "VERDICT: REPRODUCIBLE"
    else
        verdict="not_reproducible"
        ws_warn "VERDICT: NOT REPRODUCIBLE (${TOTAL_DIFFS} non-signing difference(s))"
    fi
    print_results_block "${verdict}"
    ws_write_yaml "${verdict}" "bundleMainnetRelease, JDK 17 Zulu, AGP 9.3.0, NDK ${NDK_VERSION}, bundletool ${BUNDLETOOL_VERSION}.
device-spec: ${ARCH}, screenDensity=480, sdkVersion=36. Tag ${GIT_TAG}, commit ${COMMIT}.
Rust AARs (bitkit-core, ldk-node, vss-client) from GitHub Packages at pinned versions.
google-services.json injected from base.apk public values.
Splits made from a copy of the AAB with BundleConfig sparseEncoding=VARIANT_FOR_SDK_32 (Play's SDK 32+ variant).
Accepted: root META-INF signing files, stamp-cert-sha256, Play manifest meta-data (stamp.source, stamp.type,
vending.derived.apk.id), resources.arsc typeSpec typesCount equal to its type-chunk count."
    if [[ "${should_cleanup}" == "true" ]]; then
        ws_info "Cleaning up ${WORK_DIR}..."
        rm -rf "${WORK_DIR}"
    fi
    [[ "${verdict}" == "reproducible" ]] && exit 0
    exit 1
}
main() {
    parse_arguments "$@"
    ws_results_init
    ws_engine
    CTR=(docker); [[ "${WS_ENGINE}" != podman ]] || CTR=(podman --cgroup-manager=cgroupfs)
    CONTAINER_RUN_EXTRA="$(ws_user_flags)"
    if [[ "${WS_ENGINE}" == podman ]]; then VOLUME_RO=":ro,Z" VOLUME_RW=":Z"; fi
    ws_workspace bitkit "${VERSION:-provided}" "${ARCH}"
    WORK_DIR="${WS_WORKDIR}"
    build_image
    prepare
    build
    build_lock
    extract_and_compare
    result
}
main "$@"
