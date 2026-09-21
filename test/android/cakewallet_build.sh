#!/usr/bin/env bash
# cakewallet_build.sh - Cake Wallet (Android) reproducible build verification
# Version:          v0.1.1
# Organization:     WalletScrutiny.com
# Last Modified:    2026-09-21
# App IDs:          com.cakewallet.cake_wallet (Cake Wallet), com.monero.app (Monero.com)
# Project:          https://github.com/cake-tech/cake_wallet
# Play Store:       https://play.google.com/store/apps/details?id=com.cakewallet.cake_wallet
#
# Upstream ships two artifact shapes from one Flutter tree:
#  - GitHub Releases: per-ABI APKs (flutter build apk --split-per-abi, versionCode =
#    ABI index*1000 + build number) plus one fat APK (versionCode = build number).
#  - Google Play: an app bundle rendered by Play into base.apk + split_config.*.apk.
# --binary decides the mode: a single APK is rebuilt with `flutter build apk` (split-per-abi
# or fat, chosen from the APK's native-code list); a DIRECTORY of Play splits is rebuilt with
# `flutter build appbundle` and rendered with bundletool from a device-spec derived from the
# official split names, then paired by each APK's own split= attribute.
#
# The build runs inside upstream's own builder image (FROM line of
# scripts/android/docker/Dockerfile.base at the release tag), which pins Flutter, NDK, Go and
# Rust. Native dependencies (monero_c, torch, mwebd, decred, zcash, reown, bitbox) take hours
# to compile; by default they are taken from the cache images upstream's CI builds from the
# same pinned sources (scripts/android/docker/build.sh), --native-deps source rebuilds them.
#
# Known, unavoidable inputs we cannot reproduce (printed as evidence, never hidden):
#  - lib/.secrets.g.dart: per-build random salts + private API keys compiled into the Dart
#    AOT snapshot (libapp.so). We use fixed placeholder salts and empty keys.
#  - The 6.4.5 release's Go libraries name /opt/homebrew/Cellar/go/1.26.0 (a macOS host),
#    not the image's Go 1.24.1: the vendor did not build that release in the documented image.
#
# Provided for technical analysis and reproducible build verification only, with no warranty
# of any kind. Review before running. Never run as root.
# Exit codes: 0 = identical, 1 = difference or build failure, 2 = bad parameters.

SCRIPT_VERSION="v0.1.1"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "cakewallet_build.sh $SCRIPT_VERSION sha256:${SCRIPT_HASH:-unknown}"
echo "Starting cakewallet_build.sh $SCRIPT_VERSION (Cake Wallet / Monero.com Android)"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="cakewallet_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_URL="https://github.com/cake-tech/cake_wallet"
REGISTRY="ghcr.io/cake-tech/cake_wallet"
# amd64 digest of the builder image named by Dockerfile.base at v6.4.5 (resolved 2026-09-21).
# Other tags are pulled by name and their digest is printed; the pin only guards this one.
PIN_TAG="debian13-flutter3.41.9-ndkr28-go1.24.1-ruststablenightly"
PIN_DIGEST="sha256:e7d05577546aa8959e4865c13838458cfee8ce806ca961eb4307ed9479256e6e"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner()  { echo ""; echo "=============================================================="; echo "  $*"; echo "=============================================================="; }
section() { printf -- '\n-- %s --\n' "$*"; }
phase()   { banner "$*"; echo "  $(date)"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# The YAML lands next to the SCRIPT (the ABS reads it there); the $PWD copy is convenience.
execution_dir="$SCRIPT_DIR"; invocation_dir="$(pwd -P)"
generate_yaml() {   # exactly three keys: script_version, verdict, notes
  local verdict="$1" notes="$2"
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: $SCRIPT_VERSION
verdict: ${verdict}
notes: |
 ${notes}
EOF
  [[ "$invocation_dir" != "$execution_dir" ]] && cp -f "${execution_dir}/COMPARISON_RESULTS.yaml" "${invocation_dir}/" 2>/dev/null
  log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}
fail() { local code="$1" note="$2"; generate_yaml "ftbfs" "$note"; echo ""; echo "Exit code: ${code}"; exit "$code"; }
die_invalid() { log_error "$1"; fail 2 "Invalid invocation: $1"; }

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""; rev_arg="${WS_GIT_REVISION:-}"; deps_mode="prebuilt"
require_arg() { [[ -z "${2:-}" || "${2:-}" == --* ]] && die_invalid "$1 requires a value (got: '${2:-<nothing>}')"; }
usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <apk | directory of Play splits> [--git-revision <sha>]
       [--native-deps prebuilt|source] [--version <v>] [--arch <a>] [--type <t>]

 --binary        REQUIRED. One official APK (GitHub per-ABI or fat APK), or a DIRECTORY of
                 device-pulled Play splits: base.apk + split_config.*.apk.
 --git-revision  Commit to build (7-40 hex). Default: tag v<versionName> read from the APK.
 --native-deps   prebuilt (default): monero_c/torch/mwebd/decred/zcash/reown/bitbox from the
                 cache images upstream's CI publishes for this exact tree (built from the
                 same pinned sources). source: compile them here (several hours).
 --version/--arch/--type  Optional; logged. Version comes from the artifact.
 WS_DEVICE_SDK   env: optional override of the device-spec API level. By default it is read
                 from the official base.apk's minSdkVersion, which bundletool sets to the
                 variant Play delivered, so the same variant is rendered.
 CW_CACHE_DIR    env: directory reused as gradle/pub cache across runs (optional).
 MEM_LIMIT       env: container memory limit (default 24g; empty disables).

Exit codes: 0 = identical, 1 = any difference, 2 = invalid parameters.
USAGE
}
while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      require_arg --version "${2:-}"; version_arg="$2"; shift 2 ;;
    --binary|--apk) require_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
    --arch)         require_arg --arch "${2:-}"; arch_arg="$2"; shift 2 ;;
    --type)         require_arg --type "${2:-}"; type_arg="$2"; shift 2 ;;
    --git-revision) require_arg --git-revision "${2:-}"; rev_arg="$2"; shift 2 ;;
    --native-deps)  require_arg --native-deps "${2:-}"; deps_mode="$2"; shift 2 ;;
    -h|--help)      usage; echo "Exit code: 0"; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done
[[ -n "$binary_arg" ]] || { log_error "--binary is required."; usage; fail 2 "--binary not provided. Pass the official APK or the directory of Play splits."; }
[[ -e "$binary_arg" ]] || die_invalid "--binary path does not exist: ${binary_arg}"
[[ -z "$rev_arg" || "$rev_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_invalid "--git-revision must be 7-40 hex characters (got: '${rev_arg}')"
[[ "$deps_mode" == "prebuilt" || "$deps_mode" == "source" ]] || die_invalid "--native-deps must be prebuilt or source (got: '${deps_mode}')"

# Official artifact set. Play directory: base.apk + split_config.*.apk; the pairing key is
# each APK's split= attribute, never the file name.
declare -a OFFICIAL=()
if [[ -d "$binary_arg" ]]; then
  mode="splits"; OFFICIAL_DIR="$(realpath "$binary_arg")"
  [[ -f "${OFFICIAL_DIR}/base.apk" ]] || die_invalid "--binary directory has no base.apk: ${OFFICIAL_DIR}"
  OFFICIAL+=("${OFFICIAL_DIR}/base.apk")
  while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$OFFICIAL_DIR" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
  n_other="$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' ! -name base.apk ! -name 'split_config.*.apk' | wc -l)"
  [[ "$n_other" -eq 0 ]] || die_invalid "Unexpected APK(s) in the split directory (only base.apk and split_config.*.apk are allowed)"
  [[ ${#OFFICIAL[@]} -gt 1 ]] || die_invalid "No split_config.*.apk next to base.apk; a single APK must be passed as a FILE"
  apk_main="${OFFICIAL_DIR}/base.apk"
else
  [[ -f "$binary_arg" ]] || die_invalid "--binary is not a regular file: ${binary_arg}"
  mode="single"; apk_main="$(realpath "$binary_arg")"; OFFICIAL_DIR="$(dirname "$apk_main")"; OFFICIAL+=("$apk_main")
fi
[[ -n "$arch_arg" ]]    && log_info "--arch ${arch_arg} accepted; ABIs are read from the artifact"
[[ -n "$type_arg" ]]    && log_info "--type ${type_arg} accepted but not used"
[[ -n "$version_arg" ]] && log_info "--version ${version_arg} accepted; the authoritative version comes from the artifact"

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v podman &>/dev/null; then CONTAINER_CMD=podman
  elif command -v docker &>/dev/null; then CONTAINER_CMD=docker
  else die_invalid "Neither podman nor docker found in PATH"; fi
fi
# The image expects root with HOME=/root (Flutter, SDK, rustup, Go live there). Under rootless
# podman, container root is the invoking user, so bind-mounted files come out user-owned; under
# docker they come out root-owned and are chowned in cleanup().
MEM_LIMIT="${MEM_LIMIT-24g}"; MEM_ARGS=(); [[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")
CACHE_ARGS=()
if [[ -n "${CW_CACHE_DIR:-}" ]]; then
  mkdir -p "${CW_CACHE_DIR}/gradle" "${CW_CACHE_DIR}/pub-cache"
  CACHE_ARGS=(-v "${CW_CACHE_DIR}/gradle:/root/.gradle" -v "${CW_CACHE_DIR}/pub-cache:/root/.pub-cache")
fi
crun() { $CONTAINER_CMD run --rm "${MEM_ARGS[@]}" "$@"; }

section "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-10s OK  (%s)\n" "$CONTAINER_CMD" "$(command -v "$CONTAINER_CMD")"
echo "  No host JDK, Flutter, Android SDK, Go, Rust or apktool is required or used."

RUN_ID="cakewallet-$(date +%s)-$$"
workspace="${execution_dir}/cakewallet_verification_${RUN_ID}"
META_DIR="${workspace}/metadata"; SRC_DIR="${workspace}/source"; OUT_DIR="${workspace}/built"
CMP_DIR="${workspace}/comparison"; TOOLS_DIR="${workspace}/tools"
mkdir -p "$META_DIR" "$SRC_DIR" "$OUT_DIR" "$CMP_DIR" "$TOOLS_DIR"
img_ctx="$(mktemp -d)"
BUILD_IMAGE=""
cleanup() {
  if [[ -n "$BUILD_IMAGE" ]] && $CONTAINER_CMD image inspect "$BUILD_IMAGE" >/dev/null 2>&1; then
    $CONTAINER_CMD run --rm -v "${workspace}:/target" "$BUILD_IMAGE" sh -c "chown -R ${HOST_UID}:${HOST_GID} /target" >/dev/null 2>&1 \
      || log_warn "Could not normalise ownership for ${workspace}"
  fi
  rm -rf "$img_ctx" 2>/dev/null
  log_info "Cleanup complete (images are kept; remove with: ${CONTAINER_CMD} rmi ${BUILD_IMAGE:-<image>})"
}
trap cleanup EXIT

banner "CAKE WALLET - ANDROID VERIFICATION"
cat <<EOF
 Script:    ${SCRIPT_NAME} $SCRIPT_VERSION
 Repo:      ${REPO_URL}
 Mode:      ${mode} (${#OFFICIAL[@]} official APK(s) from ${OFFICIAL_DIR})
 Deps:      --native-deps ${deps_mode}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${workspace}
 Date:      $(date)
EOF

phase "PHASE 0: OFFICIAL ARTIFACT METADATA"
# aapt2/apksigner come from the pinned builder image, so pull it first.
section "Pulling builder image ${REGISTRY}:${PIN_TAG}"
if ! $CONTAINER_CMD pull --platform linux/amd64 "${REGISTRY}:${PIN_TAG}" >/dev/null 2>&1 && ! $CONTAINER_CMD pull "${REGISTRY}:${PIN_TAG}" >/dev/null 2>&1; then
  fail 1 "Could not pull the upstream builder image ${REGISTRY}:${PIN_TAG}."
fi
BUILD_IMAGE="${REGISTRY}:${PIN_TAG}"
digest_of() { $CONTAINER_CMD image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null | sed 's/.*@//'; }
img_digest="$(digest_of "$BUILD_IMAGE")"
echo "  image digest: ${img_digest:-unknown}"
if [[ -n "$img_digest" && "$img_digest" != "$PIN_DIGEST" ]]; then
  # podman/docker may report the index digest instead of the platform manifest; record, do not stop.
  log_warn "Digest differs from the pinned amd64 manifest ${PIN_DIGEST} (index digests differ from platform digests; the value above is recorded)"
fi

cat > "${img_ctx}/meta.sh" <<'META_END'
#!/bin/bash
set -uo pipefail
BT="$(ls -d "$ANDROID_HOME"/build-tools/35.* 2>/dev/null | sort | tail -1)"; [[ -n "$BT" ]] || BT="$(ls -d "$ANDROID_HOME"/build-tools/* | sort | tail -1)"
echo "$BT" > /output/bt.txt
for A in /official/*.apk; do
  n="$(basename "$A")"
  info="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"
  pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
  vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
  vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"
  split="$(printf '%s\n' "$info" | grep '^package:' | sed -n "s/.*split='\([^']*\)'.*/\1/p")"
  abis="$(printf '%s\n' "$info" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
  minsdk="$(printf '%s\n' "$info" | sed -n "s/^\(minSdkVersion\|sdkVersion\):'\([0-9]*\)'.*/\2/p" | head -1)"
  sv="$("$BT/apksigner" verify --verbose --print-certs "$A" 2>/dev/null)"
  signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"
  schemes="$(printf '%s\n' "$sv" | sed -nE 's/^Verified using (v[0-9.]+) scheme.*: true/\1/p' | paste -sd, -)"
  stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
  agp="$(unzip -p "$A" META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null | sed -n 's/^androidGradlePluginVersion=//p')"
  vcs="$(unzip -p "$A" META-INF/version-control-info.textproto 2>/dev/null | tr '\n' ' ' | cut -c1-70)"
  engine="$(unzip -p "$A" 'lib/*/libflutter.so' 2>/dev/null | strings | grep -E '^[0-9a-f]{40}$' | head -1)"
  echo "${n}|${pkg}|${vname}|${vcode}|${split}|${abis}|${minsdk}|${signer}|${schemes}|${stamp}|${agp}|${vcs}|${engine}" >> /output/apks.txt
  echo "[META] ${n}: package ${pkg} versionName ${vname} versionCode ${vcode} split '${split:-<none>}' abis ${abis:-<none>} minSdk ${minsdk}"
  echo "[META]   signer ${signer:-?} schemes ${schemes:-none} SourceStamp ${stamp} AGP ${agp:-?} VCS '${vcs:-<none>}'${engine:+ flutter-engine ${engine}}"
done
META_END
: > "${META_DIR}/apks.txt"
# Single mode mounts just the chosen file, so sibling APKs in the same directory are not read.
OFF_MOUNT=(-v "${OFFICIAL_DIR}:/official:ro"); [[ "$mode" == "single" ]] && OFF_MOUNT=(-v "${apk_main}:/official/$(basename "$apk_main"):ro")
if ! crun "${OFF_MOUNT[@]}" -v "${META_DIR}:/output" -v "${img_ctx}/meta.sh:/meta.sh:ro" "$BUILD_IMAGE" bash /meta.sh; then
  fail 1 "Metadata extraction failed - aapt2/apksigner could not read the official APK(s)."
fi
main_line="$(grep "^$(basename "$apk_main")|" "${META_DIR}/apks.txt" | head -1)"
IFS='|' read -r _ pkg_id wallet_version version_code main_split main_abis min_sdk signer _ _ official_agp _ official_engine <<<"$main_line"
app_hash="$(sha256of "$apk_main")"
case "$pkg_id" in
  com.cakewallet.cake_wallet) APP_TYPE="cakewallet"; APP_LABEL="Cake Wallet";;
  com.monero.app)             APP_TYPE="monero.com"; APP_LABEL="Monero.com";;
  *) die_invalid "Package ${pkg_id:-?} is neither com.cakewallet.cake_wallet nor com.monero.app";;
esac
[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || die_invalid "Could not read versionName from the artifact"
[[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]] && log_warn "--version was '${version_arg}' but the artifact reports '${wallet_version}'; using the artifact's value"
[[ -n "$main_split" ]] && die_invalid "$(basename "$apk_main") declares split '${main_split}'; pass the base APK (or the whole split directory)"
# GitHub per-ABI APKs: versionCode = ABI index*1000 + build number (Flutter's ABI_VERSION map).
build_number="$version_code"; build_kind="fat"
if [[ "$mode" == "single" ]]; then
  case "$main_abis" in
    armeabi-v7a) build_kind="split-per-abi"; build_number=$((version_code - 1000)); build_abi="armeabi-v7a";;
    arm64-v8a)   build_kind="split-per-abi"; build_number=$((version_code - 2000)); build_abi="arm64-v8a";;
    x86)         build_kind="split-per-abi"; build_number=$((version_code - 3000)); build_abi="x86";;
    x86_64)      build_kind="split-per-abi"; build_number=$((version_code - 4000)); build_abi="x86_64";;
    *)           build_kind="fat"; build_abi="";;
  esac
  [[ "$build_kind" == "split-per-abi" && "$build_number" -le 0 ]] && { build_kind="fat"; build_number="$version_code"; build_abi=""; }
else
  build_kind="appbundle"
fi
log_success "${APP_LABEL} ${wallet_version} (versionCode ${version_code}, build number ${build_number}) -> rebuild as ${build_kind}"
log_info "signer SHA-256 ${signer}"
log_info "$(basename "$apk_main") SHA-256 ${app_hash}"
[[ "$official_agp" ]] && log_info "AGP ${official_agp}; Flutter engine ${official_engine:-?} (compare with bin/internal/engine.version of the pinned Flutter)"

phase "PHASE 1: SOURCE CHECKOUT"
cat > "${img_ctx}/clone.sh" <<'CLONE_END'
#!/bin/bash
set -o pipefail
REPO_URL="$1"; WANT_V="$2"; WANT_BN="$3"; REV="$4"; APP_TYPE="$5"; REGISTRY="$6"
git config --global --add safe.directory '*' >/dev/null 2>&1
echo "=== Clone ${REPO_URL} -> /w === $(date)"
git clone -q "$REPO_URL" /w || { echo "FATAL: clone failed"; exit 1; }
cd /w || exit 1
if [[ -n "$REV" ]]; then
  git rev-parse -q --verify "${REV}^{commit}" >/dev/null || git fetch -q origin "$REV" 2>/dev/null
  REF="$(git rev-parse -q --verify "${REV}^{commit}")" || { echo "FATAL: revision ${REV} is not in ${REPO_URL}"; exit 4; }
  echo "=== Pinned revision ${REF} (--git-revision) ==="
else
  REF="$(git rev-parse -q --verify "refs/tags/v${WANT_V}^{commit}")" || { echo "FATAL: no tag v${WANT_V} in ${REPO_URL}; pass --git-revision"; exit 4; }
  echo "=== Tag v${WANT_V} ($(git cat-file -t "refs/tags/v${WANT_V}") tag) -> ${REF} ==="
fi
git checkout -q --detach "$REF" || { echo "FATAL: checkout failed"; exit 2; }
git log -1 --pretty=format:'  %H %ci %s'; echo
git rev-parse HEAD > /output/commit.txt
# app_env.sh is the single source of version + build number for the Android artifacts.
key="$(tr '[:lower:].' '[:upper:]_' <<<"$APP_TYPE")"; [[ "$key" == "MONERO_COM" ]] || key="CAKEWALLET"
dv="$(sed -n "s/^${key}_VERSION=\"\([^\"]*\)\".*/\1/p" scripts/android/app_env.sh)"
dn="$(sed -n "s/^${key}_BUILD_NUMBER=\([0-9]*\).*/\1/p" scripts/android/app_env.sh)"
echo "  scripts/android/app_env.sh declares ${key}: version ${dv:-?} build number ${dn:-?}; artifact: ${WANT_V} / ${WANT_BN}"
[[ "$dv" == "$WANT_V" && "$dn" == "$WANT_BN" ]] || echo "WARNING: the checked-out revision does not declare the artifact's version/build number"
echo "${dv}|${dn}" > /output/declared.txt
base_from="$(sed -n 's/^FROM.*[[:space:]]\(ghcr\.io[^[:space:]]*\).*/\1/p' scripts/android/docker/Dockerfile.base 2>/dev/null | head -1)"
echo "${base_from}" > /output/base_image.txt
echo "  builder image named by Dockerfile.base: ${base_from:-<file missing>}"
# Cache-image tag exactly as upstream's build.sh computes it (its tinysha/img lines are sourced,
# nothing is rebuilt here). Empty when the tree has no docker cache flow.
tag=""
if [[ -f scripts/android/docker/build.sh ]]; then
  tag="$(cd scripts/android/docker && CW_DOCKER_REGISTRY="$REGISTRY" SCRIPT_DIR="$(pwd)" REPO_ROOT=/w \
        bash -c 'source <(sed -n "/^tinysha()/,/^final_ver=/p" build.sh) 2>/dev/null; img final "$final_ver"' 2>/dev/null)"
fi
echo "${tag}" > /output/deps_image.txt
echo "  native-deps cache image for this tree: ${tag:-<none computable>}"
echo "  pins: $(grep -h -oE '^HASH=[0-9a-f]{40}|git checkout [0-9a-f]{40}' scripts/prepare_*.sh scripts/build_bitbox_flutter.sh 2>/dev/null | sed 's/^HASH=//; s/git checkout //' | cut -c1-10 | paste -sd' ' -) (torch, reown, zcash, monero_c, bitbox)"
CLONE_END
crun -v "${SRC_DIR}:/w" -v "${META_DIR}:/output" -v "${img_ctx}/clone.sh:/clone.sh:ro" "$BUILD_IMAGE" \
  bash /clone.sh "$REPO_URL" "$wallet_version" "$build_number" "$rev_arg" "$APP_TYPE" "$REGISTRY" 2>&1 | tee "${META_DIR}/clone.log"
CLONE_RC=${PIPESTATUS[0]}
if [[ $CLONE_RC -ne 0 ]]; then
  [[ $CLONE_RC -eq 4 ]] && fail 1 "The source revision could not be pinned (no tag v${wallet_version}${rev_arg:+, revision $rev_arg not found}). Official artifact SHA-256: ${app_hash}."
  fail 1 "Source checkout failed (container exit ${CLONE_RC}). Official artifact SHA-256: ${app_hash}."
fi
built_commit="$(cat "${META_DIR}/commit.txt" 2>/dev/null)"
base_image="$(cat "${META_DIR}/base_image.txt" 2>/dev/null)"
deps_image="$(cat "${META_DIR}/deps_image.txt" 2>/dev/null)"
if [[ -n "$base_image" && "$base_image" != "$BUILD_IMAGE" ]]; then
  section "Switching to the builder image this revision names: ${base_image}"
  if $CONTAINER_CMD pull "$base_image" >/dev/null 2>&1; then BUILD_IMAGE="$base_image"; echo "  digest: $(digest_of "$BUILD_IMAGE")"
  else log_warn "Could not pull ${base_image}; building in ${BUILD_IMAGE} instead (toolchain drift is possible)"; fi
fi

deps_note=""
if [[ "$deps_mode" == "prebuilt" ]]; then
  section "Native dependencies from upstream's CI cache image"
  if [[ -z "$deps_image" ]]; then
    log_error "This revision has no scripts/android/docker/build.sh cache flow; rerun with --native-deps source."
    fail 1 "No native-dependency cache image can be derived for ${built_commit:0:10}; --native-deps source is required. Official artifact SHA-256: ${app_hash}."
  fi
  echo "  ${deps_image}"
  if ! $CONTAINER_CMD pull "$deps_image" >/dev/null 2>&1; then
    log_error "Cache image not published for this tree; rerun with --native-deps source."
    fail 1 "Upstream has not published ${deps_image} for revision ${built_commit:0:10}; rerun with --native-deps source. Official artifact SHA-256: ${app_hash}."
  fi
  deps_digest="$(digest_of "$deps_image")"; echo "  digest: ${deps_digest:-unknown}"
  # The image is alpine + /w.top (the built trees); upstream rsyncs /w.top into the repo root.
  crun -v "${SRC_DIR}:/w" "$deps_image" sh -c 'cp -a /w.top/. /w/ && find /w.top -name "*.so" -o -name "*.aar" -o -name "*.a" | wc -l' > "${META_DIR}/deps_files.txt" 2>&1 \
    || fail 1 "Extracting native dependencies from ${deps_image} failed. Official artifact SHA-256: ${app_hash}."
  echo "  extracted: $(tail -1 "${META_DIR}/deps_files.txt") native artifacts (.so/.aar/.a)"
  deps_note="native deps from upstream cache image ${deps_image}@${deps_digest:-?}"
else
  deps_note="native deps compiled from source in this run"
fi

phase "PHASE 2: BUILD FROM SOURCE (${build_kind})"
cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -o pipefail
APP_TYPE="$1"; BUILD_KIND="$2"; DEPS_MODE="$3"; BUILD_ABI="$4"
L=/output/build.log
run() { echo "=== $* === $(date)"; "$@" >> "$L" 2>&1 || { echo "FATAL: '$*' failed - tail of $L:"; tail -30 "$L"; exit 3; }; }
cd /w || exit 2
export MAKE_JOB_COUNT="${MAKE_JOB_COUNT:-$(nproc)}"
echo "=== Toolchain ==="
flutter --version 2>/dev/null | head -2 | sed 's/^/  /'
echo "  $(go version 2>/dev/null)"; echo "  $(java -version 2>&1 | head -1)"; echo "  rust $(rustc --version 2>/dev/null)"
echo "  NDK ${ANDROID_NDK_VERSION:-?}  SDK ${ANDROID_SDK_ROOT:-?}"
{ flutter --version; go version; java -version 2>&1; rustc --version; cargo --version; echo "NDK ${ANDROID_NDK_VERSION}"; } > /output/toolchain.txt 2>&1
if [[ "$DEPS_MODE" == "source" ]]; then
  cd scripts/android || exit 2
  run ./build_torch.sh
  run ./build_reown_deps.sh
  ( cd .. && run ./build_bitbox_flutter.sh ) || exit 3
  run ./build_monero_all.sh
  run ./build_decred.sh
  run ./build_mwebd.sh
  run ./build_zcash.sh
  cd /w || exit 2
fi
cd scripts/android || exit 2
# app_env.sh has an unset $HAVEN reference; never source it under set -u.
source ./app_env.sh "$APP_TYPE" || { echo "FATAL: app_env.sh rejected type ${APP_TYPE}"; exit 3; }
echo "  app_env: ${APP_ANDROID_NAME} ${APP_ANDROID_VERSION}+${APP_ANDROID_BUILD_NUMBER} ${APP_ANDROID_PACKAGE}"
run ./app_config.sh
cd /w || exit 2
# Signing is mandatory for the release build type; a throwaway key replaces the vendor's.
run keytool -genkey -v -keystore android/app/key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias testKey -noprompt \
  -dname "CN=WalletScrutiny, OU=RB, O=WalletScrutiny, L=Internet, S=Internet, C=US" -storepass wsverify -keypass wsverify
run dart run tool/generate_android_key_properties.dart keyAlias=testKey storeFile=key.jks storePassword=wsverify keyPassword=wsverify
run ./model_generator.sh
run dart run tool/generate_localization.dart
# Secrets: upstream compiles private API keys and per-build RANDOM salts into the Dart AOT
# snapshot. The random salts are pinned to fixed placeholders so our own build is at least
# self-consistent between runs; API keys stay empty. libapp.so cannot match the vendor's.
run dart run tool/generate_new_secrets.dart
for kv in salt:32 keychainSalt:24 key:32 walletSalt:8 shortKey:24 backupSalt:16 backupKeychainSalt:24 walletGroupSalt:32; do
  z="$(printf '%*s' "${kv##*:}" '' | tr ' ' 0)"
  sed -i -E "s/\"${kv%%:*}\": \"[0-9a-f]+\"/\"${kv%%:*}\": \"${z}\"/" tool/.secrets-config.json
done
run dart run tool/import_secrets_config.dart
echo "  secrets: placeholder salts (all-zero hex of the upstream lengths), API keys empty -> lib/.secrets.g.dart $(wc -l < lib/.secrets.g.dart) consts"
# CI compiles res/pictures/*.svg into assets/new-ui/*.svg.vec (632 in the 6.4.5 APK); the
# ANDROID.md recipe omits this step.
run ./compile_graphics.sh
echo "  svg.vec compiled: $(find assets/new-ui -name '*.svg.vec' | wc -l)"
echo "=== Working tree vs HEAD before flutter build (generated files expected) ==="
git status --porcelain > /output/tree-status.txt; wc -l < /output/tree-status.txt | sed 's/^/  changed+untracked paths: /' ; echo "  (list: built/tree-status.txt)"
case "$BUILD_KIND" in
  split-per-abi) run flutter build apk --release --split-per-abi; out="build/app/outputs/flutter-apk/app-${BUILD_ABI}-release.apk";;
  fat)           run flutter build apk --release; out="build/app/outputs/flutter-apk/app-release.apk";;
  appbundle)     run flutter build appbundle --release; out="build/app/outputs/bundle/release/app-release.aab";;
esac
grep -E 'Built |BUILD SUCCESSFUL|FAILURE' "$L" | tail -3 | sed 's/^/  /'
[[ -f "$out" ]] || { echo "FATAL: expected output ${out} missing"; ls -R build/app/outputs 2>/dev/null | head -20; exit 3; }
cp "$out" "/output/$(basename "$out")"
echo "=== built $(basename "$out") sha256 $(sha256sum "$out" | cut -d' ' -f1) === $(date)"
BUILD_END
section "Build ($( [[ "$deps_mode" == "source" ]] && echo "many hours: native deps + " )Flutter/Gradle, ~1-2 h) - $(date)"
crun "${CACHE_ARGS[@]}" -v "${SRC_DIR}:/w" -v "${OUT_DIR}:/output" -v "${img_ctx}/build.sh:/build.sh:ro" "$BUILD_IMAGE" \
  bash /build.sh "$APP_TYPE" "$build_kind" "$deps_mode" "${build_abi:-}" 2>&1 | tee "${OUT_DIR}/container-build.log"
BUILD_RC=${PIPESTATUS[0]}
if [[ $BUILD_RC -ne 0 ]]; then
  log_error "Source build failed (container exit ${BUILD_RC}); logs: ${OUT_DIR}/build.log, container-build.log"
  fail 1 "Source build failed for ${pkg_id} ${wallet_version} at ${built_commit:0:10} (container exit ${BUILD_RC}; ${deps_note}). Official artifact SHA-256: ${app_hash}."
fi
log_success "Source build finished"

# Render the bundle like Play does: one split set for a device-spec derived from the official
# split names. The device API level is a property of the phone, not of the APKs.
declare -a PAIRS=()   # "official-path|built-path"
if [[ "$mode" == "splits" ]]; then
  section "Rendering the app bundle with bundletool ${BUNDLETOOL_VERSION}"
  ABIS=(); DEN=""; LOCS=()
  for f in "${OFFICIAL[@]}"; do
    c="$(basename "$f")"; c="${c#split_config.}"; c="${c%.apk}"
    case "$c" in
      base.apk) ;;
      arm64_v8a|armeabi_v7a|x86_64|x86) ABIS+=("${c//_/-}") ;;
      ldpi) DEN=120;; mdpi) DEN=160;; tvdpi) DEN=213;; hdpi) DEN=240;; xhdpi) DEN=320;; xxhdpi) DEN=480;; xxxhdpi) DEN=640;;
      *) LOCS+=("$c") ;;
    esac
  done
  [[ ${#ABIS[@]} -eq 0 ]] && ABIS=("arm64-v8a"); [[ -z "$DEN" ]] && DEN=480; [[ ${#LOCS[@]} -eq 0 ]] && LOCS=("en")
  # Device API level: bundletool writes each variant's lower SDK bound into its APKs'
  # minSdkVersion, so the official base.apk's minSdkVersion identifies the variant Play
  # delivered. Rendering with exactly that value selects the same variant, whatever phone the
  # splits were pulled from. WS_DEVICE_SDK overrides it.
  if [[ -n "${WS_DEVICE_SDK:-}" ]]; then
    SDK="$WS_DEVICE_SDK"; SDK_SRC="WS_DEVICE_SDK override"
  else
    SDK="$min_sdk"; SDK_SRC="official base.apk minSdkVersion"
  fi
  [[ "$SDK" =~ ^[0-9]+$ ]] || die_invalid "Could not determine the device API level (base.apk minSdkVersion '${min_sdk:-}'); set WS_DEVICE_SDK"
  abij="$(printf '"%s",' "${ABIS[@]}")"; locj="$(printf '"%s",' "${LOCS[@]}")"
  printf '{"supportedAbis":[%s],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' "${abij%,}" "${locj%,}" "$DEN" "$SDK" > "${OUT_DIR}/device-spec.json"
  echo "  device-spec: $(cat "${OUT_DIR}/device-spec.json")  (sdkVersion ${SDK} from ${SDK_SRC})"
  crun -v "${TOOLS_DIR}:/tools" -v "${OUT_DIR}:/out" -v "${META_DIR}:/meta:ro" -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" "$BUILD_IMAGE" bash -c '
    set -e; cd /tools
    j=bundletool-all-'"$BUNDLETOOL_VERSION"'.jar
    [[ -f $j ]] || curl -fsSL --retry 3 ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} -o $j https://github.com/google/bundletool/releases/download/'"$BUNDLETOOL_VERSION"'/$j
    echo "'"$BUNDLETOOL_SHA256"'  $j" | sha256sum -c - >/dev/null || { echo "bundletool checksum mismatch"; exit 5; }
    BT=$(cat /meta/bt.txt 2>/dev/null || ls -d $ANDROID_HOME/build-tools/* | sort | tail -1)
    rm -rf /out/rendered; mkdir -p /out/rendered
    java -jar $j build-apks --bundle=/out/app-release.aab --output=/out/rendered/built.apks --device-spec=/out/device-spec.json --aapt2=$BT/aapt2 --overwrite
    cd /out/rendered && unzip -q -o built.apks "splits/*.apk" && ls splits/' 2>&1 | tee "${OUT_DIR}/bundletool.log" | tail -12 | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || fail 1 "bundletool rendering failed (see built/bundletool.log). Official artifact SHA-256: ${app_hash}."
  # Pair by split= attribute: device files are split_config.X.apk, bundletool's are base-X.apk.
  crun -v "${OFFICIAL_DIR}:/official:ro" -v "${OUT_DIR}:/out" -v "${META_DIR}:/meta:ro" "$BUILD_IMAGE" bash -c '
    BT=$(cat /meta/bt.txt 2>/dev/null || ls -d $ANDROID_HOME/build-tools/* | sort | tail -1)
    cfg() { s=$("$BT/aapt2" dump badging "$1" 2>/dev/null | grep "^package:" | sed -n "s/.*split=.\([^\x27]*\).*/\1/p"); echo "${s#config.}"; }
    for o in /official/*.apk; do co=$(cfg "$o"); m=""
      for b in /out/rendered/splits/*.apk; do [[ "$(cfg "$b")" == "$co" ]] && { m="$b"; break; }; done
      echo "$(basename "$o")|${co:-base}|${m:+rendered/splits/$(basename "$m")}"; done' > "${OUT_DIR}/pairs.txt" 2>/dev/null
  while IFS='|' read -r o c b; do
    if [[ -n "$b" ]]; then PAIRS+=("${OFFICIAL_DIR}/${o}|${OUT_DIR}/${b}"); echo "  ${o} (split '${c}') <-> ${b}"
    else log_warn "No rendered counterpart for ${o} (split '${c}') -> counted as a difference"; PAIRS+=("${OFFICIAL_DIR}/${o}|"); fi
  done < "${OUT_DIR}/pairs.txt"
else
  built_apk="$(find "$OUT_DIR" -maxdepth 1 -name 'app-*.apk' | head -1)"
  [[ -n "$built_apk" ]] || fail 1 "No built APK found under ${OUT_DIR}. Official artifact SHA-256: ${app_hash}."
  PAIRS+=("${apk_main}|${built_apk}")
fi

phase "PHASE 3: COMPARISON"
# Every raw diff must be EARNED by a class with printed evidence: signing entries, Play
# SourceStamp, Play manifest meta-data, or an apktool-decoded-identical resources.arsc.
# Everything else (dex, libapp.so, native libs, assets, baseline.prof) is material.
cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
o=/official.apk; b=/built.apk; tag="$1"; out="/out"
BT="$(cat /meta/bt.txt 2>/dev/null || ls -d "$ANDROID_HOME"/build-tools/* | sort | tail -1)"; AAPT2="$BT/aapt2"
cd /tools || exit 5
if [[ ! -f apktool.jar ]]; then
  curl -fsSL --retry 3 ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} -o apktool.jar "$APKTOOL_URL" || echo "apktool download failed"
fi
echo "${APKTOOL_SHA256}  apktool.jar" | sha256sum -c - >/dev/null 2>&1 && APKTOOL="java -jar /tools/apktool.jar" || APKTOOL=""
rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b /tmp/afw
unzip -q -o "$o" -d /tmp/o; unzip -q -o "$b" -d /tmp/b
echo "  official: $(sha256sum "$o" | cut -c1-64)  ($(find /tmp/o -type f | wc -l) entries)"
echo "  built:    $(sha256sum "$b" | cut -c1-64)  ($(find /tmp/b -type f | wc -l) entries)"
raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"; printf '%s\n' "$raw" > "$out/diff_${tag}.txt"
n=$(printf '%s\n' "$raw" | grep -vc '^$')
# Native library evidence: compiler stamp and Go version per differing .so (both sides).
: > "$out/native_${tag}.txt"
nso=0; nsm=0
while IFS= read -r so; do
  rel="${so#/tmp/o/}"; nso=$((nso+1))
  if [[ -f "/tmp/b/$rel" ]] && cmp -s "$so" "/tmp/b/$rel"; then nsm=$((nsm+1)); continue; fi
  for side in o b; do f="/tmp/$side/$rel"; [[ -f "$f" ]] || { echo "$rel [$side] MISSING" >> "$out/native_${tag}.txt"; continue; }
    cc="$(readelf -p .comment "$f" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -oE 'clang version [0-9.]+|Android \([^)]*\)|GCC[^|]*' | head -2 | paste -sd' ' -)"
    gv="$(strings "$f" | grep -oE '^go1\.[0-9]+(\.[0-9]+)?' | head -1)"
    gp="$(strings "$f" | grep -oE '^/(opt/homebrew|Users|home|root|w|__w|build|tmp)/[^ ]*' | head -1 | cut -c1-60)"
    echo "$rel [$side] $(stat -c%s "$f") B; ${cc:-no .comment}; ${gv:-no Go}; ${gp:-no build path}" >> "$out/native_${tag}.txt"; done
done < <(find /tmp/o -name '*.so' -type f | sort)
dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
la="$(f=$(find /tmp/o -name libapp.so | head -1); [[ -n "$f" ]] && { cmp -s "$f" "/tmp/b/${f#/tmp/o/}" && echo IDENTICAL || echo DIFFERS; })"
fa="$(diff -rq /tmp/o/assets/flutter_assets /tmp/b/assets/flutter_assets 2>/dev/null | grep -vc '^$')"
echo "  native libs ${nsm}/${nso} identical; dex differing: ${dx:-none}; libapp.so (Dart AOT): ${la:-absent}; flutter_assets diffs: ${fa:-0}"
[[ -s "$out/native_${tag}.txt" ]] && { echo "  native evidence (first lines; full: native_${tag}.txt):"; head -4 "$out/native_${tag}.txt" | sed 's/^/    /'; }
# Earned classes
c_sign=$(printf '%s\n' "$raw" | grep -cE 'META-INF/[^/ ]+\.(SF|RSA|DSA|EC)( |$)|META-INF/MANIFEST\.MF( |$)')
c_stamp=$(printf '%s\n' "$raw" | grep -c 'stamp-cert-sha256'); c_mani=$(printf '%s\n' "$raw" | grep -c 'AndroidManifest\.xml'); c_arsc=$(printf '%s\n' "$raw" | grep -c 'resources\.arsc')
a_sign=$c_sign; a_stamp=0; a_mani=0; a_arsc=0
[[ $c_sign -gt 0 ]] && echo "      signing: ${c_sign} META-INF signature entr(ies) - vendor key vs our throwaway key"
if [[ $c_stamp -gt 0 ]]; then
  if [[ ! -e /tmp/b/stamp-cert-sha256 && "$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null)" == "32" ]] && "$BT/apksigner" verify --verbose "$o" 2>/dev/null | grep -q 'Verified for SourceStamp: true'; then
    a_stamp=$c_stamp; echo "      stamp: official-only 32-byte stamp-cert-sha256, apksigner SourceStamp OK (Play injects it)"
  else echo "      stamp: NOT EARNED -> material"; fi
fi
if [[ $c_mani -gt 0 ]]; then
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null; "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"; printf '%s\n' "$d" > "$out/diff_manifest_${tag}.txt"
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  bad="$(printf '%s\n' "$left" | grep -vE '^E: meta-data|android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id)"|android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK)"|android:value\(0x[0-9a-f]+\)=[0-9]+$')"
  if printf '%s\n' "$d" | grep -q '^>' || [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: NOT EARNED -> material (diff_manifest_${tag}.txt):"; printf '%s\n' "$d" | grep -E '^[<>]' | head -3 | sed 's/^/        /'
  else a_mani=$c_mani; echo "      manifest: only Play distribution meta-data, official-only ($(printf '%s\n' "$left" | grep -c '^E: meta-data') block(s))"; fi
fi
if [[ $c_arsc -gt 0 ]]; then
  if [[ -n "$APKTOOL" ]] && rm -rf /tmp/do /tmp/db && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/do "$o" >/dev/null 2>&1 \
     && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/db "$b" >/dev/null 2>&1 && [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
    rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"; printf '%s\n' "$rd" > "$out/diff_resources_decoded_${tag}.txt"
    if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then a_arsc=$c_arsc; echo "      arsc: apktool-decoded res/ IDENTICAL (binary packing artifact)"
    else echo "      arsc: decoded res/ differs -> material:"; printf '%s\n' "$rd" | head -2 | sed 's/^/        /'; fi
  else echo "      arsc: NOT EARNED (apktool unavailable or decode failed) -> material"; fi
fi
printf '%s\n' "$raw" | grep -q 'baseline\.prof' && echo "      baseline.prof: never auto-accepted (embeds dex checksums) -> material"
acc=$((a_sign+a_stamp+a_mani+a_arsc)); un=$((n-acc)); [[ $un -lt 0 ]] && un=0
echo "TOTALS ${n} ${acc} ${un}" > "$out/summary_${tag}.txt"
echo "  raw ${n}, accepted ${acc}, unaccounted ${un}  (full list: comparison/diff_${tag}.txt)"
printf '%s\n' "$raw" | grep -v '^$' | head -5 | sed 's/^/    /'
CMP_END
tot_raw=0; tot_acc=0; tot_un=0; pair_notes=""
for p in "${PAIRS[@]}"; do
  o="${p%%|*}"; b="${p#*|}"; tag="$(basename "$o" .apk)"
  section "Comparing $(basename "$o") <-> ${b:+$(basename "$b")}${b:-<no counterpart>}"
  if [[ -z "$b" || ! -f "$b" ]]; then tot_un=$((tot_un+1)); tot_raw=$((tot_raw+1)); pair_notes+="${tag}: no built counterpart (1 unaccounted); "; continue; fi
  crun -v "${o}:/official.apk:ro" -v "${b}:/built.apk:ro" -v "${CMP_DIR}:/out" -v "${TOOLS_DIR}:/tools" -v "${META_DIR}:/meta:ro" \
    -v "${img_ctx}/compare.sh:/compare.sh:ro" -e APKTOOL_URL="$APKTOOL_URL" -e APKTOOL_SHA256="$APKTOOL_SHA256" -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    "$BUILD_IMAGE" bash /compare.sh "$tag" 2>&1 | tee -a "${CMP_DIR}/comparison.log"
  if ! read -r _ r a u < "${CMP_DIR}/summary_${tag}.txt" 2>/dev/null; then
    log_error "Comparison of ${tag} produced no summary"; fail 1 "Comparison stage failed for ${tag}. Official artifact SHA-256: ${app_hash}."
  fi
  tot_raw=$((tot_raw+r)); tot_acc=$((tot_acc+a)); tot_un=$((tot_un+u)); pair_notes+="${tag}: raw ${r}, accepted ${a}, unaccounted ${u}; "
done

section "RESULT"
cat <<EOF
 Pairs compared:       ${#PAIRS[@]}
 Raw differences:      ${tot_raw}
 Accepted (earned):    ${tot_acc}
 UNACCOUNTED:          ${tot_un}   <- the verdict is judged on this alone
 Diff lists:           ${CMP_DIR}/diff_*.txt, native_*.txt, diff_manifest_*.txt, diff_resources_decoded_*.txt
 Build logs:           ${OUT_DIR}/build.log, container-build.log; toolchain: ${OUT_DIR}/toolchain.txt
EOF
if [[ "$tot_un" -eq 0 ]]; then verdict="reproducible"; rc=0; log_success "Every difference is an earned class with printed evidence; nothing unaccounted."
else verdict="not_reproducible"; rc=1; log_error "${tot_un} difference(s) unaccounted for."; fi
notes="${pkg_id} ${wallet_version} (versionCode ${version_code}, build number ${build_number}, ${build_kind}) built from ${REPO_URL} commit ${built_commit:0:10} in ${BUILD_IMAGE}; ${deps_note}. Official $(basename "$apk_main") SHA-256 ${app_hash}, signer ${signer}. ${pair_notes}Secrets: fixed placeholder salts and empty API keys (upstream compiles private values into libapp.so). Evidence per differing native library in comparison/native_*.txt."
generate_yaml "$verdict" "$notes"
echo ""
cat <<EOF
===== Begin Results =====
appId:           ${pkg_id}
signer:          ${signer}
apkVersionName:  ${wallet_version}
apkVersionCode:  ${version_code}
verdict:         ${verdict}
appHash:         ${app_hash}
commit:          ${built_commit:-unknown}
scriptVersion:   ${SCRIPT_VERSION}
scriptHash:      ${SCRIPT_HASH:-unknown}
===== End Results =====

sourceRef:       ${built_commit:0:10} (${rev_arg:+--git-revision }${rev_arg:-tag v${wallet_version}}), image ${BUILD_IMAGE}
EOF
echo ""; echo "Exit code: ${rc}"; exit "$rc"
