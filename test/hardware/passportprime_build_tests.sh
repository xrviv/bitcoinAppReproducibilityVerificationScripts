#!/bin/bash
#
# passportprime_build_tests.sh - fast host-side regression tests for
# passportprime_build.sh (no container, no network, no build).
#
# Covers: argument parsing/exit codes, --binary staging (mapping, fail-fast,
# duplicate rejection), COMPARISON_RESULTS.yaml location + 3-field schema,
# the shared comparison library (release-path mapping, signedness, provided
# mapping, reverse-closure classifier — including the seven 1.2.1/1.3.0
# out-of-scope files that caused the v0.3.0 false-negative blocker), and
# syntax of the two generated in-container files.
#
# Usage: ./passportprime_build_tests.sh   (exit 0 = all pass)
#
# Organization: WalletScrutiny.com

set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/passportprime_build.sh"
PASS=0
FAIL=0

t() {  # $1=name $2=expected-exit $3...=args
    local name="$1" expected="$2"; shift 2
    local rc=0
    "${SCRIPT}" "$@" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq "${expected}" ]]; then
        echo "PASS ${name} (exit ${rc})"; PASS=$((PASS+1))
    else
        echo "FAIL ${name} (expected exit ${expected}, got ${rc})"; FAIL=$((FAIL+1))
    fi
}

check() {  # $1=name $2=result(0=pass)
    local name="$1" rc="$2"
    if [[ "${rc}" -eq 0 ]]; then
        echo "PASS ${name}"; PASS=$((PASS+1))
    else
        echo "FAIL ${name}"; FAIL=$((FAIL+1))
    fi
}

TMP="$(mktemp -d /tmp/passportprime_tests_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# ---- argument parsing / exit codes -----------------------------------------

t "help exits 0"                    0 --help
t "no args -> invalid (2)"          2
t "--version without value -> 2"    2 --version
t "bad --arch -> 2"                 2 --version 1.3.0 --arch mips
t "bad --type -> 2"                 2 --version 1.3.0 --type recovery
t "--binary missing path -> 2"      2 --version 1.3.0 --binary /nonexistent/path
t "unknown arg alone -> 2 (warn, not fatal parse)" 2 --frobnicate

rc=1
"${SCRIPT}" --frobnicate 2>&1 | grep -q "Unknown argument: --frobnicate" && rc=0
check "unknown arg produces a warning" "${rc}"

# ---- write_yaml: location + 3-field schema ----------------------------------

mkdir -p "${TMP}/yamltest"
cp "${SCRIPT}" "${TMP}/yamltest/passportprime_build.sh"
( cd "${TMP}/yamltest" && bash -c '
    source ./passportprime_build.sh
    write_yaml "ftbfs" "test note line"
' ) >/dev/null 2>&1
rc=1
[[ -f "${TMP}/yamltest/COMPARISON_RESULTS.yaml" ]] && rc=0
check "YAML written next to script" "${rc}"

rc=1
if [[ -f "${TMP}/yamltest/COMPARISON_RESULTS.yaml" ]]; then
    fields="$(grep -cE '^(script_version|verdict|notes):' "${TMP}/yamltest/COMPARISON_RESULTS.yaml")"
    total="$(grep -cE '^[a-z_]+:' "${TMP}/yamltest/COMPARISON_RESULTS.yaml")"
    [[ "${fields}" -eq 3 && "${total}" -eq 3 ]] && rc=0
fi
check "YAML has exactly the 3 allowed fields" "${rc}"

rc=1
grep -q '^  test note line$' "${TMP}/yamltest/COMPARISON_RESULTS.yaml" && rc=0
check "YAML notes remain correctly indented" "${rc}"

# A human-review state is deliberately not an ABS verdict. It must remove any
# stale result and return nonzero without writing a replacement YAML.
echo stale > "${TMP}/yamltest/COMPARISON_RESULTS.yaml"
rc_actual=0
( cd "${TMP}/yamltest" && bash -c '
    source ./passportprime_build.sh
    if publish_yaml "" "must not publish" SCOPE_REVIEW_REQUIRED; then exit 99; else exit 1; fi
' ) >/dev/null 2>&1 || rc_actual=$?
rc=1
[[ "${rc_actual}" -eq 1 && ! -e "${TMP}/yamltest/COMPARISON_RESULTS.yaml" ]] && rc=0
check "blocked verification removes stale YAML" "${rc}"

verdict_t() {
    local name="$1" expected="$2"; shift 2
    local got
    got="$(bash -c 'source "'"${SCRIPT}"'"; comparison_verdict "$@"' _ "$@")"
    [[ "${got}" == "${expected}" ]]; rc=$?
    check "${name}" "${rc}"
}
verdict_t "clean comparison -> reproducible" reproducible 10 0 0 0
verdict_t "mismatch -> not_reproducible" not_reproducible 10 1 0 0
verdict_t "empty comparison -> not_reproducible" not_reproducible 0 0 0 0

# ---- generated in-container files: write + syntax ----------------------------

mkdir -p "${TMP}/gen"
bash -c '
    source "'"${SCRIPT}"'"
    WORK_DIR="'"${TMP}/gen"'"
    write_dockerfile
    write_comparison_lib
    write_inner_script
' >/dev/null 2>&1
rc=1
[[ -f "${TMP}/gen/Dockerfile" && -f "${TMP}/gen/comparison_lib.sh" && -f "${TMP}/gen/inner_build.sh" ]] && \
    bash -n "${TMP}/gen/comparison_lib.sh" && bash -n "${TMP}/gen/inner_build.sh" && rc=0
check "generated Dockerfile, comparison library and inner script are present/syntax-valid" "${rc}"

rc=1
grep -q 'git checkout --detach "refs/tags/' "${TMP}/gen/Dockerfile" && rc=0
check "source checkout uses an explicit detached tag" "${rc}"

rc=1
# 2026-09-08: some versions have no matching KeyOS-Releases branch (1.3.2
# confirmed absent 2026-09-08; branch existence is per-version, not a
# permanent channel discontinuation -- do not assert the branch is gone for
# good). For those, official binaries come from two GitHub Release assets on
# the KeyOS repo, each checked against its own published .sha256 before
# extraction. No git clone of KeyOS-Releases and no api.github.com call
# (release asset downloads, like the old raw.githubusercontent.com ones,
# avoid the rate-limited API).
if grep -q 'releases/download/v${KEYOS_VERSION}' "${TMP}/gen/inner_build.sh" &&
   grep -q 'sha256 mismatch: got' "${TMP}/gen/inner_build.sh" &&
   ! grep -q 'KeyOS-Releases.git' "${TMP}/gen/inner_build.sh" &&
   ! grep -q 'api.github.com' "${TMP}/gen/inner_build.sh"; then rc=0; fi
check "official binaries come from KeyOS GitHub Release assets, each verified against its published sha256" "${rc}"

rc=1
grep -q 'mv "${manifest_path}" "${manifest_path}.${bundle%.bin}"' "${TMP}/gen/inner_build.sh" && rc=0
check "each bundle's manifest.json is renamed apart, not clobbered by the next extraction" "${rc}"

rc=1
grep -q 'UNKNOWN_OFFICIAL ${opath} (outside' "${TMP}/gen/inner_build.sh" && rc=0
check "an official path outside the version prefix is surfaced, not silently skipped" "${rc}"

rc=1
# 2026-09-08 live build server run (v1.3.2): plain 'tar' extracted fine into
# the nested "<version>/" dir (confirmed by RELEASE_TREE/${KEYOS_VERSION}/relp
# resolving real files) -- nixos/nix does provide tar, no nix-shell wrapper needed.
grep -q 'tar -xf "${RELEASE_DIR}/${fname}" -C "${RELEASE_TREE}"' "${TMP}/gen/inner_build.sh" &&
    grep -q 'RELEASE_TREE}/${KEYOS_VERSION}/${relp}' "${TMP}/gen/inner_build.sh" && rc=0
check "release assets extract and resolve under their nested <version>/ dir" "${rc}"

rc=1
# v1.4.0's xtask added a required --keyos-version flag to --production-firmware,
# absent at v1.3.2 -- probed via --help rather than a hardcoded version cutoff.
grep -q -- '--keyos-version' "${TMP}/gen/inner_build.sh" &&
    grep -q 'xtask build-all --help' "${TMP}/gen/inner_build.sh" &&
    grep -q 'KEYOS_VERSION_ARG\[@\]' "${TMP}/gen/inner_build.sh" && rc=0
check "xtask build-all passes --keyos-version only when the flag is supported" "${rc}"

rc=1
grep -q 'verify_official_signature' "${TMP}/gen/inner_build.sh" &&
    grep -q 'two distinct keys trusted by KeyOS source' "${TMP}/gen/inner_build.sh" &&
    grep -q 'vendor devshell does not provide cosign2' "${TMP}/gen/inner_build.sh" && rc=0
check "cosign2 is probed early and signatures use the source trust set" "${rc}"

rc=1
grep -q 'KeyOS/blob/9056b4805315cad3a8dd58f7c7d06a08e27a1a31/utils/fw-utils/src/hash.rs#L14-L36' "${TMP}/gen/comparison_lib.sh" && rc=0
check "signer trust keys carry exact source provenance" "${rc}"

rc=1
probe_line="$(grep -n "cosign2 dump --input \"\${COSIGN_PROBE}\"" "${TMP}/gen/inner_build.sh" | cut -d: -f1)"
build_line="$(grep -n '^[[:space:]]*cargo xtask build-all' "${TMP}/gen/inner_build.sh" | cut -d: -f1)"
[[ -n "${probe_line}" && -n "${build_line}" && "${probe_line}" -lt "${build_line}" ]] && rc=0
check "cosign2 probe runs before the firmware build" "${rc}"

rc=1
grep -q 'verification-state.txt' "${TMP}/gen/inner_build.sh" &&
    grep -q 'AUTHENTICATION_FAILED COMPILED' "${TMP}/gen/inner_build.sh" && rc=0
check "blocked runs retain a machine-readable state record" "${rc}"

rc=1
grep -q 'echo "publication:    blocked"' "${SCRIPT}" &&
    grep -q "echo \"review_state:   \${VERIFICATION_STATE}\"" "${SCRIPT}" && rc=0
check "blocked cast output does not invent a reproducibility verdict" "${rc}"

# ---- comparison library semantics --------------------------------------------

LIB="${TMP}/gen/comparison_lib.sh"

lib_t() {  # $1=name $2=expected $3=function $4...=args
    local name="$1" expected="$2" fn="$3"; shift 3
    local got
    got="$(bash -c 'source "'"${LIB}"'"; '"${fn}"' "$@"' _ "$@" 2>/dev/null)"
    if [[ "${got}" == "${expected}" ]]; then
        echo "PASS ${name}"; PASS=$((PASS+1))
    else
        echo "FAIL ${name} (expected '${expected}', got '${got}')"; FAIL=$((FAIL+1))
    fi
}

# release_path_for: partition mapping and bootloader exclusion
lib_t "map boot common/ -> common-boot/"      "common-boot/x.bin" release_path_for boot common/x.bin
lib_t "map boot recovery.bin unchanged"       "recovery.bin"      release_path_for boot recovery.bin
lib_t "map boot boot.bin -> excluded"         ""                  release_path_for boot boot.bin
lib_t "map system keyos/app.bin unchanged"    "keyos/app.bin"     release_path_for system keyos/app.bin

# is_signed
rc=1; bash -c 'source "'"${LIB}"'"; is_signed keyos/app.bin' && rc=0
check "is_signed: keyos/app.bin signed" "${rc}"
rc=1; bash -c 'source "'"${LIB}"'"; is_signed keyos/apps/gui-app-bitcoin/app.elf' && rc=0
check "is_signed: gui-app ELF signed" "${rc}"
rc=1; bash -c 'source "'"${LIB}"'"; is_signed blassets/font.bin' || rc=0
check "is_signed: asset not signed" "${rc}"

rc=1; bash -c 'source "'"${LIB}"'"; is_known_signer 03bf014e1a37a113089bea7b50ee9bd7733189ecd6afb7e051a6e95f99b97da5e9' && rc=0
check "key trusted by KeyOS source accepted" "${rc}"
rc=1; bash -c 'source "'"${LIB}"'"; is_known_signer 02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' || rc=0
check "unknown signer rejected" "${rc}"
rc=1; bash -c 'source "'"${LIB}"'"; signature_is_source_trusted atsama5d27-keyos 03bf014e1a37a113089bea7b50ee9bd7733189ecd6afb7e051a6e95f99b97da5e9 03cb8e4219d3c8f269ab2ed3acb71a4b1722c76a0c348ea11fa79b4639bef45094' && rc=0
check "two distinct source-trusted keys accepted" "${rc}"
rc=1; bash -c 'source "'"${LIB}"'"; signature_is_source_trusted atsama5d27-keyos 03bf014e1a37a113089bea7b50ee9bd7733189ecd6afb7e051a6e95f99b97da5e9 02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' || rc=0
check "unknown cosign2 key blocks authentication" "${rc}"
lib_t "authentication failure blocks verdict" "AUTHENTICATION_FAILED" verification_state_for 1 0
lib_t "unknown member requires scope review" "SCOPE_REVIEW_REQUIRED" verification_state_for 0 1
lib_t "clean verification state completes" "COMPLETE" verification_state_for 0 0
rc=1; bash -c 'source "'"${LIB}"'"; is_sha40 0123456789abcdef0123456789abcdef01234567' && rc=0
check "40-character release commit accepted" "${rc}"
rc=1; bash -c 'source "'"${LIB}"'"; is_sha40 1.3.0' || rc=0
check "mutable release ref rejected as commit" "${rc}"

# Host-owned workspace acceptance check (no container/build required).
mkdir -p "${TMP}/ownership/child"
rc=1
bash -c 'source "'"${SCRIPT}"'"; WORK_DIR="'"${TMP}/ownership"'"; NORMALIZE_OWNERSHIP=false; normalize_workspace' && rc=0
check "ownership acceptance check passes for caller-owned workspace" "${rc}"

# provided_name_for
lib_t "provided map: recovery.bin"            "recovery.bin"        provided_name_for recovery.bin
lib_t "provided map: keyos/app.bin -> app.bin" "app.bin"            provided_name_for keyos/app.bin
lib_t "provided map: gui-app ELF"             "gui-app-bitcoin.elf" provided_name_for keyos/apps/gui-app-bitcoin/app.elf
lib_t "provided map: asset -> none"           ""                    provided_name_for blassets/font.bin

# closure classifier: candidates
lib_t "closure: keyos/** compares"            "compare"    closure_class_for keyos/apps/gui-app-seed-vault/app.elf
lib_t "closure: blassets/** compares"         "compare"    closure_class_for blassets/splash.png
lib_t "closure: common-boot/** compares"      "compare"    closure_class_for common-boot/uenv.txt
lib_t "closure: recovery.bin compares"        "compare"    closure_class_for recovery.bin
lib_t "closure: boot.cip -> bootloader"       "bootloader" closure_class_for boot.cip

# closure classifier: the seven files that caused the v0.3.0 false negative
lib_t "closure: Update.tar out_of_scope"      "out_of_scope" closure_class_for KeyOS-v1.2.1-to-v1.3.0-Update.tar
lib_t "closure: Factory.img out_of_scope"     "out_of_scope" closure_class_for KeyOS-v1.3.0-Factory.img
lib_t "closure: pkg Recovery out_of_scope"    "out_of_scope" closure_class_for KeyOS-v1.3.0-Recovery.bin
lib_t "closure: pkg CoreSysRec out_of_scope"  "out_of_scope" closure_class_for KeyOS-v1.3.0-CoreSystemRecovery.bin
lib_t "closure: envoy manifest out_of_scope"  "out_of_scope" closure_class_for envoy-server/manifest.json
lib_t "closure: envoy release.tar out_of_scope" "out_of_scope" closure_class_for envoy-server/release.tar
# Per-bundle top-level manifest.json: new in the 2026-09-08 GitHub-Release
# packaging (one distinct signed PRM1 manifest per bundle). Each is renamed on
# extraction (release-asset loop) to avoid the two bundles' manifests
# colliding on the shared path; classifier matches the renamed form. The bare
# name falling to "unknown" (not out_of_scope) is deliberate: it should never
# survive extraction, and a reappearance means the rename step regressed.
lib_t "closure: Recovery bundle manifest out_of_scope" "out_of_scope" closure_class_for manifest.json.Recovery
lib_t "closure: CoreSystemRecovery bundle manifest out_of_scope" "out_of_scope" closure_class_for manifest.json.CoreSystemRecovery
lib_t "closure: bare manifest.json is unknown (must be renamed first)" "unknown" closure_class_for manifest.json
lib_t "closure: nested app manifest still compares" "compare" closure_class_for keyos/apps/gui-app-bitcoin/manifest.json
lib_t "closure: envoy release.tar.sig out_of_scope" "out_of_scope" closure_class_for envoy-server/release.tar.sig
lib_t "closure: versioned update ZIP out_of_scope (live 1.3.0 eighth composite)" "out_of_scope" closure_class_for v1.2.2-v1.3.0.zip

# closure classifier: never silently ignore new material
lib_t "closure: unrecognized -> unknown"      "unknown"    closure_class_for something-new-v2.bin

# ---- --binary staging: mapping and fail-fast --------------------------------

stage_in_subshell() {  # $1=binary-path $2=workdir ; exit code of staging
    bash -c '
        source "'"${SCRIPT}"'"
        WORK_DIR="'"$2"'"
        BINARY_PATH="'"$1"'"
        stage_provided_binaries
    ' >/dev/null 2>&1
}

mkdir -p "${TMP}/dir1/gui-app-bitcoin"
echo a > "${TMP}/dir1/app.bin"
echo b > "${TMP}/dir1/gui-app-bitcoin/app.elf"
echo j > "${TMP}/dir1/junk.txt"
mkdir -p "${TMP}/w1"
rc=1
stage_in_subshell "${TMP}/dir1" "${TMP}/w1" && \
    [[ -f "${TMP}/w1/out/provided/app.bin" && -f "${TMP}/w1/out/provided/gui-app-bitcoin.elf" && ! -e "${TMP}/w1/out/provided/junk.txt" ]] && rc=0
check "--binary dir: maps app.bin + gui-app-*/app.elf, ignores junk" "${rc}"

mkdir -p "${TMP}/w2"
echo c > "${TMP}/gui-app-seed-vault.elf"
rc=1
stage_in_subshell "${TMP}/gui-app-seed-vault.elf" "${TMP}/w2" && \
    [[ -f "${TMP}/w2/out/provided/gui-app-seed-vault.elf" ]] && rc=0
check "--binary single gui-app-*.elf: staged" "${rc}"

mkdir -p "${TMP}/w3"
echo d > "${TMP}/firmware.bin"
rc_actual=0; stage_in_subshell "${TMP}/firmware.bin" "${TMP}/w3" || rc_actual=$?
rc=1; [[ "${rc_actual}" -eq 2 ]] && rc=0
check "--binary unrecognized single file: fatal exit 2" "${rc}"

mkdir -p "${TMP}/plain" "${TMP}/w4"
echo e > "${TMP}/plain/app.elf"
rc_actual=0; stage_in_subshell "${TMP}/plain/app.elf" "${TMP}/w4" || rc_actual=$?
rc=1; [[ "${rc_actual}" -eq 2 ]] && rc=0
check "--binary app.elf with non-gui-app parent: fatal exit 2" "${rc}"

mkdir -p "${TMP}/empty" "${TMP}/w5"
echo z > "${TMP}/empty/notes.md"
rc_actual=0; stage_in_subshell "${TMP}/empty" "${TMP}/w5" || rc_actual=$?
rc=1; [[ "${rc_actual}" -eq 2 ]] && rc=0
check "--binary dir with no usable artifacts: fatal exit 2" "${rc}"

# Duplicate logical artifacts collapse to one destination -> must be fatal,
# never decided by find order (v0.3.0 review, finding 5).
mkdir -p "${TMP}/dup1/a" "${TMP}/dup1/b" "${TMP}/w6"
echo x > "${TMP}/dup1/a/app.bin"
echo y > "${TMP}/dup1/b/app.bin"
rc_actual=0; stage_in_subshell "${TMP}/dup1" "${TMP}/w6" || rc_actual=$?
rc=1; [[ "${rc_actual}" -eq 2 ]] && rc=0
check "--binary duplicate app.bin: fatal exit 2" "${rc}"

mkdir -p "${TMP}/dup2/gui-app-bitcoin" "${TMP}/w7"
echo x > "${TMP}/dup2/gui-app-bitcoin.elf"
echo y > "${TMP}/dup2/gui-app-bitcoin/app.elf"
rc_actual=0; stage_in_subshell "${TMP}/dup2" "${TMP}/w7" || rc_actual=$?
rc=1; [[ "${rc_actual}" -eq 2 ]] && rc=0
check "--binary gui-app-X.elf + gui-app-X/app.elf duplicate: fatal exit 2" "${rc}"

# ---- summary -----------------------------------------------------------------

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
