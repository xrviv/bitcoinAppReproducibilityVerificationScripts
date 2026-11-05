#!/usr/bin/env bash
# ==============================================================================
# shapeshift-v0.1.2_build.sh - ShapeShift (Android) Reproducible Build Verification
# ==============================================================================
# Version:          v0.1.2
# Organization:     WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-11-05
# App ID:           com.shapeshift.droid_shapeshift
# Project:          https://github.com/shapeshift/mobile-app
# Play Store:       https://play.google.com/store/apps/details?id=com.shapeshift.droid_shapeshift
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include a changelog in this header.
# Changelog: ~/work/ws-notes/script-notes/android/com.shapeshift.droid_shapeshift/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# ShapeShift is an Expo (SDK 54, React Native 0.81) WebView shell around https://app.shapeshift.com,
# built on Expo's EAS cloud. No tags or GitHub releases exist for 3.x. Official artifacts:
#  - Google Play: base.apk + split_config.*.apk (pass the directory as --binary), or
#  - Solana dApp Store: one universal APK (pass the file as --binary). Without --binary the script
#    downloads it: release addresses from the repo's config.yaml history -> Solana RPC -> Metaplex
#    metadata -> Arweave APK, checked against the sha256 published on chain.
# Source revision: the newest commit on main whose app.json declares the APK's versionName and that
# is not newer than the commitTime expo-updates embedded in assets/app.manifest (--commit overrides).
# Build as EAS does: node 20.19.4 / JDK 17 / NDK 27.1.12297006, HOME=/home/expo, project in
# /home/expo/workingdir/build, yarn install --immutable, .env from the public .env.template (the
# official bundle holds exactly those EXPO_PUBLIC_* values), expo prebuild --platform android, update
# channel from eas.json, versionCode and expo-updates commitTime from the official APK (a match proves
# nothing about those values), gradle assembleRelease (universal APK) or bundleRelease + bundletool
# (Play splits). Every raw difference must be earned by a named check; everything else is material.
#
# Exit codes: 0 = reproducible, 1 = differences / build failure / other failure, 2 = invalid parameters.
# ==============================================================================

SCRIPT_VERSION="v0.1.2"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "$(basename "$SCRIPT_PATH") $SCRIPT_VERSION sha256:${SCRIPT_HASH:-N/A}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

APP_ID="com.shapeshift.droid_shapeshift"
REPO_URL="https://github.com/shapeshift/mobile-app"
EXPECTED_SIGNER="a94bd24546617ea514165d874107d2ac27530db618c115dd2cfa44fb486581b2"
SOLANA_RPC="${SOLANA_RPC:-https://api.mainnet-beta.solana.com}"
EAS_HOME="/home/expo"; EAS_PATH="/home/expo/workingdir/build"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
YAML="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
phase()   { printf '\n== %s ==\n  %s\n' "$*" "$(date)"; }
section() { printf -- '\n-- %s --\n' "$*"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# COMPARISON_RESULTS.yaml goes next to the script (ABS reads it there), only for a real verdict.
generate_yaml() {
  { echo "script_version: $SCRIPT_VERSION"
    echo "verdict: $1"
    echo "notes: |"
    printf '%s\n' "$2" | sed 's/^/  /'; } > "$YAML"
  log_info "COMPARISON_RESULTS.yaml written with verdict: $1"
}
# ftbfs only when the source fails to build; every other failure leaves no YAML (ABS publishes any YAML).
ftbfs() { generate_yaml ftbfs "$1"; log_error "$1"; echo ""; echo "Exit code: 1"; exit 1; }
abort() { log_error "$1 (no verdict written)"; echo ""; echo "Exit code: 1"; exit 1; }
die_invalid() { log_error "$1"; echo ""; echo "Exit code: 2"; exit 2; }
# Source failures only. Network, memory, disk and tooling errors must never become ftbfs: ABS publishes any YAML.
COMPILE_ERRORS='^e: |\.java:[0-9]+: error:|\.(c|cc|cpp|h|hpp):[0-9]+(:[0-9]+)?: (fatal )?error:|> Task :[^ ]*([Cc]ompile|[Kk]sp|[Kk]apt)[^ ]* FAILED|SyntaxError:|Unable to resolve module|YN0028'
ENV_ERRORS='OutOfMemoryError|Metaspace|heap out of memory|ENOMEM|ENOSPC|No space left|EMFILE|ENFILE|[Tt]oo many open files|ETIMEDOUT|ECONNRESET|EAI_AGAIN|ENOTFOUND|Could not (resolve|download|GET|HEAD)|Connection (timed out|reset|refused)|Read timed out|Network is unreachable|daemon disappeared'
has_compile_error() {
  [[ -f "$1" ]] || return 1
  grep -qE "$ENV_ERRORS" "$1" && return 1
  grep -qE "$COMPILE_ERRORS" "$1"
}
require_arg() { [[ -z "${2:-}" || "${2:-}" == --* ]] && die_invalid "$1 requires a value"; }

usage() {
  cat <<USAGE
Usage: $(basename "$SCRIPT_PATH") [--binary <apk | dir-of-Play-splits>] [--version <v>] [--commit <sha>]

 --binary, --apk  Official artifact: the Solana dApp Store universal APK, or a directory of Play
                  splits (base.apk + split_config.*.apk). Without it, --version is required and the
                  dApp Store APK for that version is downloaded.
 --version        App version (e.g. 3.7.1); default: the APK's versionName.
 --commit         Build this commit instead of the resolved one.
 --arch           Checked against the official split set or APK (mismatch exits 2). --type: accepted, ignored.
 WS_DEVICE_SDK    env: device-spec API level for Play splits (default 36; use the SDK of the phone they came from).
 SOLANA_RPC       env: Solana RPC for the download (default ${SOLANA_RPC}).
 MEM_LIMIT        env: container memory limit (default 12g; empty = none).

Exit codes: 0 = reproducible, 1 = not reproducible / ftbfs / failure, 2 = invalid parameters.
USAGE
}

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; commit_arg=""; arch_arg=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      require_arg "$1" "${2:-}"; version_arg="${2#v}"; shift 2 ;;
    --apk|--binary) require_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
    --commit)       require_arg "$1" "${2:-}"; commit_arg="$2"; shift 2 ;;
    --arch)         require_arg "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
    --type)         require_arg "$1" "${2:-}"; log_info "--type $2 accepted, not used"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done
rm -f "$YAML"   # a stale verdict must never be read as this run's
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_invalid "Invalid --version '${version_arg}'"
[[ -z "$commit_arg" || "$commit_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_invalid "--commit must be 7-40 hex characters"
[[ -n "$binary_arg" || -n "$version_arg" ]] || { usage; die_invalid "Pass --binary, or --version to download the dApp Store APK"; }

MODE=""; OFFICIAL_DIR=""; declare -a OFFICIAL=()
if [[ -n "$binary_arg" ]]; then
  if [[ -d "$binary_arg" ]]; then
    MODE=splits; OFFICIAL_DIR="$(readlink -f "$binary_arg")"
    [[ -f "${OFFICIAL_DIR}/base.apk" ]] || die_invalid "--binary directory has no base.apk: ${OFFICIAL_DIR}"
    OFFICIAL+=("${OFFICIAL_DIR}/base.apk")
    while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$OFFICIAL_DIR" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
    n_other="$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' ! -name base.apk ! -name 'split_config.*.apk' | wc -l)"
    [[ "$n_other" -eq 0 ]] || die_invalid "Unexpected APK(s) in the split directory (only base.apk and split_config.*.apk)"
    [[ ${#OFFICIAL[@]} -gt 1 ]] || die_invalid "No split_config.*.apk next to base.apk"
  elif [[ -f "$binary_arg" ]]; then
    MODE=universal; OFFICIAL+=("$(readlink -f "$binary_arg")"); OFFICIAL_DIR="$(dirname "${OFFICIAL[0]}")"
  else die_invalid "--binary not found: ${binary_arg}"; fi
fi
# --arch against the official set (split name now; the single APK's native-code after metadata).
want_abi=""
if [[ -n "$arch_arg" ]]; then
  case "$arch_arg" in
    arm64-v8a|arm64_v8a|arm64|aarch64) want_abi=arm64-v8a ;; armeabi-v7a|armeabi_v7a|armv7|arm) want_abi=armeabi-v7a ;;
    x86_64|x86-64|amd64) want_abi=x86_64 ;; x86|i686) want_abi=x86 ;;
    *) die_invalid "--arch '${arch_arg}' is not an Android ABI" ;;
  esac
  if [[ "$MODE" == splits && ! -f "${OFFICIAL_DIR}/split_config.${want_abi//-/_}.apk" ]]; then
    die_invalid "--arch ${want_abi}: the official split set has no split_config.${want_abi//-/_}.apk"
  fi
fi

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v podman &>/dev/null; then CONTAINER_CMD=podman
  elif command -v docker &>/dev/null; then CONTAINER_CMD=docker
  else die_invalid "Neither podman nor docker found in PATH (the only host requirement)"; fi
fi
if [[ "$CONTAINER_CMD" == *podman* ]]; then RUN_USER=(--userns=keep-id -e "HOME=${EAS_HOME}"); OWNER="0:0"
else RUN_USER=(--user "${HOST_UID}:${HOST_GID}" -e "HOME=${EAS_HOME}"); OWNER="${HOST_UID}:${HOST_GID}"; fi
MEM_LIMIT="${MEM_LIMIT-12g}"; MEM_ARGS=(); [[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")
crun() { $CONTAINER_CMD run --rm "${RUN_USER[@]}" "${MEM_ARGS[@]}" "$@"; }

RUN_ID="$(date +%s)-$$"
IMG="localhost/ws-shapeshift-${RUN_ID}"
WS="$(pwd -P)/shapeshift_verification_${version_arg:-apk}_${RUN_ID}"
mkdir "$WS" 2>/dev/null || die_invalid "Cannot create a fresh workspace ${WS}"
META="${WS}/metadata"; BLD="${WS}/built"; CMP="${WS}/comparison"; CTX="${WS}/ctx"; DL="${WS}/official"
mkdir -p "$META" "$BLD" "$CMP" "$CTX" || die_invalid "Cannot create workspace subdirectories in ${WS}"
BUILD_CTR="ws-shapeshift-build-${RUN_ID}"
cleanup() {
  $CONTAINER_CMD rm -f "$BUILD_CTR" >/dev/null 2>&1
  if $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1; then
    # Rootless podman: container root is the caller, so 0:0; docker: the caller's ids.
    $CONTAINER_CMD run --rm -v "${WS}:/t" "$IMG" chown -R "$OWNER" /t >/dev/null 2>&1
    $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1
  fi
  [[ -n "${NET:-}" ]] && $CONTAINER_CMD network rm -f "$NET" >/dev/null 2>&1
  chmod -R u+rwX "$WS" 2>/dev/null
}
trap cleanup EXIT
trap 'echo ""; log_error "Interrupted (no verdict written)"; echo "Exit code: 130"; exit 130' INT TERM

cat <<EOF

==============================================================
  SHAPESHIFT - ANDROID VERIFICATION
==============================================================
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Official:  ${MODE:-download from the Solana dApp Store} ${OFFICIAL_DIR}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${WS}
EOF

phase "SETUP: BUILD CONTAINER IMAGE"
# EAS image for SDK 54 (ubuntu-24.04-jdk-17-ndk-r27b): Node 20.19.4, JDK 17, NDK r27b
# (27.1.12297006). Yarn comes from the repo (.yarn/releases/yarn-3.2.3.cjs).
cat > "${CTX}/Dockerfile" <<DOCKERFILE_END
FROM docker.io/library/node:20.19.4-bookworm@sha256:572a90df10a58ebb7d3f223d661d964a6c2383a9c2b5763162b4f631c53dc56a
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends git unzip zip curl ca-certificates binutils \\
  && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && curl -fsSL -o jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz" \\
  && echo "d8afc263758141a66e0e3aafc321e783f7016696f4eaea067d340a269037d331  jdk.tar.gz" | sha256sum -c - \\
  && mkdir -p /opt/jdk17 && tar -xzf jdk.tar.gz -C /opt/jdk17 --strip-components=1 && rm jdk.tar.gz
# EAS keeps the SDK in ~/Android/Sdk; the NDK path is hashed into the build IDs of the native libs.
ENV JAVA_HOME=/opt/jdk17 ANDROID_HOME=${EAS_HOME}/Android/Sdk ANDROID_SDK_ROOT=${EAS_HOME}/Android/Sdk
ENV PATH=/opt/jdk17/bin:${EAS_HOME}/Android/Sdk/cmdline-tools/latest/bin:${EAS_HOME}/Android/Sdk/platform-tools:\$PATH
RUN mkdir -p \$ANDROID_HOME/cmdline-tools && cd \$ANDROID_HOME/cmdline-tools \\
  && curl -fsSL -o ct.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \\
  && echo "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258  ct.zip" | sha256sum -c - \\
  && unzip -q ct.zip && rm ct.zip && mv cmdline-tools latest
RUN yes | sdkmanager --licenses >/dev/null && sdkmanager "platforms;android-36" "build-tools;36.0.0" \\
    "build-tools;35.0.0" "platform-tools" "ndk;27.1.12297006" "cmake;3.22.1" >/dev/null && chmod -R a+rwX \$ANDROID_HOME
RUN cd /opt && curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar \\
  && echo "${APKTOOL_SHA256}  apktool.jar" | sha256sum -c - \\
  && curl -fsSL -o bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar \\
  && echo "${BUNDLETOOL_SHA256}  bundletool.jar" | sha256sum -c - && chmod 0644 apktool.jar bundletool.jar
RUN mkdir -p /opt/sol && cd /opt/sol && npm init -y >/dev/null && npm install --no-audit --no-fund @solana/web3.js@1.98.4 >/dev/null
RUN mkdir -p ${EAS_HOME}/workingdir /tmp/afw && chmod 0777 ${EAS_HOME} ${EAS_HOME}/workingdir ${EAS_HOME}/Android /tmp/afw
WORKDIR ${EAS_HOME}/workingdir
DOCKERFILE_END
$CONTAINER_CMD build -t "$IMG" -f "${CTX}/Dockerfile" "$CTX" || abort "Container image build failed; nothing was compared"
log_success "Image built: ${IMG}"

# The clone (inside the container) is shared by the download and the build.
cat > "${CTX}/clone.sh" <<'CLONE_END'
#!/bin/bash
git config --global --add safe.directory '*'
git clone -q "$1" /out/src || { echo "FATAL: clone failed"; exit 1; }
CLONE_END
crun -v "${BLD}:/out" -v "${CTX}/clone.sh:/clone.sh:ro" "$IMG" bash /clone.sh "$REPO_URL" \
  || abort "git clone of ${REPO_URL} failed"

if [[ -z "$MODE" ]]; then
  phase "DOWNLOAD: SOLANA DAPP STORE APK ${version_arg}"
  cat > "${CTX}/dl.js" <<'DL_END'
// Release NFT addresses from config.yaml history -> Metaplex metadata -> install file for the version.
const { PublicKey, Connection } = require('/opt/sol/node_modules/@solana/web3.js');
const fs = require('fs'); const [want, rpc] = process.argv.slice(2);
const MP = new PublicKey('metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s');
const addrs = [...new Set(fs.readFileSync('/out/addrs.txt', 'utf8').split('\n').filter(Boolean))];
(async () => {
  const c = new Connection(rpc); const seen = [];
  for (const a of addrs) {
    let mint; try { mint = new PublicKey(a); } catch { continue; }
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from('metadata'), MP.toBuffer(), mint.toBuffer()], MP);
    const info = await c.getAccountInfo(pda); if (!info) continue;
    const uri = (info.data.toString('latin1').match(/https:\/\/arweave\.net\/[\w-]+/) || [])[0]; if (!uri) continue;
    const r = await fetch(uri); if (!r.ok) continue;
    const ext = ((await r.json()).extensions || {}).solana_dapp_store || {};
    const ad = ext.android_details || {}; seen.push(`${a}=${ad.version}`);
    if (ad.android_package !== 'com.shapeshift.droid_shapeshift' || ad.version !== want) continue;
    const f = (ext.files || []).find(x => x.purpose === 'install');
    if (f) { console.log(`${a}|${ad.version_code}|${f.uri}|${f.sha256}|${f.size}`); return; }
  }
  console.error(`no dApp Store release for ${want}; releases seen: ${seen.join(' ') || 'none'}`); process.exit(4);
})().catch(e => { console.error(String(e)); process.exit(1); });
DL_END
  crun -v "${BLD}:/out" "$IMG" bash -c 'cd /out/src && git log -p --format= -- config.yaml | sed -n "s/^[+ ] *address: *\([1-9A-HJ-NP-Za-km-z]\{32,44\}\)$/\1/p" > /out/addrs.txt'
  rel="$(crun -v "${BLD}:/out" -v "${CTX}/dl.js:/dl.js:ro" "$IMG" node /dl.js "$version_arg" "$SOLANA_RPC")"; drc=$?
  [[ $drc -eq 4 ]] && die_invalid "No Solana dApp Store release for ${version_arg}; pass --binary"
  [[ $drc -eq 0 && -n "$rel" ]] || abort "dApp Store lookup failed (RPC ${SOLANA_RPC})"
  IFS='|' read -r rel_addr _ rel_uri rel_sha rel_size <<<"$rel"
  log_info "Release NFT ${rel_addr}: ${rel_uri} (${rel_size} B, sha256 ${rel_sha})"
  mkdir -p "$DL"; crun -v "${DL}:/dl" "$IMG" curl -fsSL --retry 3 -o "/dl/shapeshift-${version_arg}.apk" "$rel_uri" || abort "APK download failed"
  [[ "$(sha256of "${DL}/shapeshift-${version_arg}.apk")" == "$rel_sha" ]] || abort "Downloaded APK does not match the on-chain sha256 ${rel_sha}"
  log_success "APK matches the sha256 published on chain"
  MODE=universal; OFFICIAL=("${DL}/shapeshift-${version_arg}.apk"); OFFICIAL_DIR="$DL"
fi

phase "PHASE 0: OFFICIAL ARTIFACT METADATA (${MODE})"
cat > "${CTX}/meta.sh" <<'META_END'
#!/bin/bash
BT="$ANDROID_HOME/build-tools/36.0.0"
for A in "$@"; do
  i="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"; p="$(printf '%s\n' "$i" | grep '^package:')"
  g() { printf '%s\n' "$p" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
  pkg="$(printf '%s\n' "$p" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  abis="$(printf '%s\n' "$i" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
  minsdk="$(printf '%s\n' "$i" | sed -n "s/^\(minSdkVersion\|sdkVersion\):'\([0-9]*\)'.*/\2/p" | head -1)"
  signer="$("$BT/apksigner" verify --print-certs "$A" 2>/dev/null | awk '/Signer #1 certificate SHA-256/{print $NF; exit}')"
  ct="$(unzip -p "$A" assets/app.manifest 2>/dev/null | sed -n 's/.*"commitTime":\([0-9]*\).*/\1/p')"
  ch="$("$BT/aapt2" dump xmltree --file AndroidManifest.xml "$A" 2>/dev/null | grep -o '"{"expo-channel-name":"[A-Za-z0-9_-]*"}"' | head -1 | sed 's/.*:"\([^"]*\)"}"$/\1/')"
  devip="$("$BT/aapt2" dump resources "$A" 2>/dev/null | grep -A1 'string/react_native_dev_server_ip' | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)"
  echo "$(basename "$A")|${pkg}|$(g versionName)|$(g versionCode)|$(g split)|${abis}|${minsdk}|${signer}|${ct}|${ch}|${devip}" >> /m/apks.txt
  echo "[META] $(basename "$A"): ${pkg} $(g versionName) ($(g versionCode)) split '$(g split)' abis ${abis:-none} minSdk ${minsdk} commitTime ${ct:-none} channel ${ch:-none} devIP ${devip:-none}"
  echo "[META]   signer ${signer:-?}"
done
META_END
: > "${META}/apks.txt"
MOUNTS=(); for f in "${OFFICIAL[@]}"; do MOUNTS+=(-v "${f}:/official/$(basename "$f"):ro"); done
crun "${MOUNTS[@]}" -v "${META}:/m" -v "${CTX}/meta.sh:/meta.sh:ro" "$IMG" bash -c 'bash /meta.sh /official/*.apk' \
  || abort "Could not read metadata from the official APK(s)"
main="$(basename "${OFFICIAL[0]}")"
IFS='|' read -r _ pkg vname vcode main_split abis min_sdk signer commit_time channel dev_ip <<<"$(grep "^${main}|" "${META}/apks.txt" | head -1)"
[[ "$(awk -F'|' '$2 != "'"$APP_ID"'"' "${META}/apks.txt" | wc -l)" -eq 0 && -n "$pkg" ]] || die_invalid "Not every official APK is ${APP_ID} (see [META] lines)"
[[ -z "$main_split" ]] || die_invalid "${main} declares split '${main_split}'"
[[ -n "$vname" && "$vcode" =~ ^[0-9]+$ ]] || abort "Could not read versionName/versionCode from ${main}"
if [[ "$MODE" == universal ]]; then
  for a in arm64-v8a armeabi-v7a x86 x86_64; do [[ ",${abis}," == *",${a},"* ]] || die_invalid "${main} is not the universal APK (native-code: ${abis:-none}); for Play pass the split directory"; done
fi
if [[ -n "$want_abi" && "$MODE" == universal && ",${abis}," != *",${want_abi},"* ]]; then
  die_invalid "--arch ${want_abi}: ${main} carries ${abis:-no native code}"
fi
[[ "$signer" == "$EXPECTED_SIGNER" ]] || log_warn "Signer ${signer:-unknown} is not the one the repo's config.yaml records (${EXPECTED_SIGNER})"
app_hash="$(sha256of "${OFFICIAL[0]}")"
if [[ -z "$version_arg" ]]; then version_arg="$vname"
elif [[ "$version_arg" != "$vname" ]]; then die_invalid "--version ${version_arg} but ${main} is ${vname}"; fi
log_success "${APP_ID} ${vname} (versionCode ${vcode})"
log_info "${main} SHA-256 ${app_hash}; signer ${signer:-?}; expo-updates commitTime ${commit_time:-none}, official channel ${channel:-none}"

phase "PHASE 1: BUILD FROM SOURCE (${version_arg})"
cat > "${CTX}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
V="$1"; VCODE="$2"; WANT="$3"; CT="$4"; TASK="$5"; PROFILE="$6"
git config --global --add safe.directory '*'
cp -a /out/src "$EAS_PATH" && cd "$EAS_PATH" || exit 1
appv() { git show "$1:app.json" 2>/dev/null | sed -n 's/^  "version": "\([^"]*\)".*/\1/p'; }
if [[ -n "$WANT" ]]; then
  c="$(git rev-parse -q --verify "${WANT}^{commit}")" || { echo "FATAL: --commit ${WANT} is not in the repo"; exit 4; }
  src="--commit"
else
  # Newest first-parent commit on main declaring V and not newer than the bundle's commitTime.
  c=""; first=""
  while read -r h t; do
    [[ "$(appv "$h")" == "$V" ]] || continue; first="$h"
    if [[ -z "$CT" || "$t" -le $((CT/1000)) ]]; then c="$h"; break; fi
  done < <(git log --first-parent --format='%H %ct' origin/HEAD)
  if [[ -n "$c" ]]; then src="newest commit on main declaring ${V} at or before commitTime ${CT:-n/a}"
  elif [[ -n "$first" ]]; then c="$first"; src="oldest commit declaring ${V} (all are newer than commitTime ${CT})"
  else echo "FATAL: no commit on main declares version ${V} in app.json"; exit 4; fi
fi
git checkout -q "$c" || exit 2
{ echo "COMMIT=$(git rev-parse HEAD)"; echo "SOURCE=${src}"; echo "APP_VERSION=$(appv HEAD)"
  echo "TAGS=$(git tag --points-at HEAD | paste -sd, -)"; } > /out/src.env
git log -1 --format='  built: %H %ci %s'; echo "  source: ${src}"
[[ "$(appv HEAD)" == "$V" ]] || echo "  WARNING: app.json declares $(appv HEAD), not ${V}"
git status --porcelain | head -3
# The release profile decides the channel, and any setting this image does not reproduce stops the run.
IFS='|' read -r CHANNEL EAS_NODE EAS_OTHER <<<"$(node -e 'const b=JSON.parse(require("fs").readFileSync("eas.json")).build[process.argv[1]]||{},a=b.android||{};
console.log([b.channel||"",b.node||"",["env","extends","image"].filter(k=>b[k]).concat(["image","ndk","env"].filter(k=>a[k]).map(k=>"android."+k)).join(",")].join("|"))' "$PROFILE")"
[[ -n "$CHANNEL" ]] || { echo "FATAL: eas.json profile ${PROFILE} has no channel"; exit 5; }
[[ -z "$EAS_NODE" || "v${EAS_NODE}" == "$(node --version)" ]] || { echo "FATAL: eas.json profile ${PROFILE} wants node ${EAS_NODE}; this image has $(node --version)"; exit 5; }
[[ -z "$EAS_OTHER" ]] || { echo "FATAL: eas.json profile ${PROFILE} sets ${EAS_OTHER}; this script does not reproduce that"; exit 5; }

export CI=1 EAS_BUILD=true EAS_BUILD_PLATFORM=android NODE_ENV=production GRADLE_USER_HOME="${HOME}/.gradle"
# The template's 512m metaspace kills KSP (expo-updates) with OutOfMemoryError; JVM sizing does not
# change the output. The user-level file overrides the project's gradle.properties.
mkdir -p "$GRADLE_USER_HOME" && echo "org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=2g" > "$GRADLE_USER_HOME/gradle.properties"
echo "  node $(node --version), $(java -version 2>&1 | head -1)"
# EAS reads EXPO_PUBLIC_* from the project's environment; the official bundle contains exactly the
# public values of .env.template, which is the only source the repo has for them.
cp .env.template .env && echo "  .env from .env.template: $(grep -c '^EXPO_PUBLIC_' .env) EXPO_PUBLIC_* entries"
run() { echo "=== $1 === $(date)"; shift; "$@" > /out/step.log 2>&1 || { tail -40 /out/step.log; cat /out/step.log >> /out/build.log; cp /out/step.log /out/fail.log; echo "FATAL: step failed"; exit 3; }; cat /out/step.log >> /out/build.log; }
run "yarn install --immutable" node .yarn/releases/yarn-3.2.3.cjs install --immutable
# expo-updates stamps the wall clock as commitTime (createManifestForBuildAsync.js). Copied, like versionCode.
if [[ -n "$CT" ]]; then
  F=node_modules/expo-updates/utils/build/createManifestForBuildAsync.js
  sed -i "s/commitTime: new Date().getTime(),/commitTime: ${CT},/" "$F"
  grep -q "commitTime: ${CT}," "$F" || { echo "FATAL: commitTime pin failed"; exit 5; }
  echo "  expo-updates commitTime pinned to ${CT} (from the official APK)"
fi
run "expo prebuild --platform android" npx expo prebuild --no-install --platform android
# EAS adds the build profile's update channel to the manifest (not to app.config) as request headers.
M=android/app/src/main/AndroidManifest.xml
sed -i "/android:name=\"expo.modules.updates.EXPO_UPDATE_URL\"/a\\    <meta-data android:name=\"expo.modules.updates.UPDATES_CONFIGURATION_REQUEST_HEADERS_KEY\" android:value=\"{\&quot;expo-channel-name\&quot;:\&quot;${CHANNEL}\&quot;}\"/>" "$M"
grep -q 'UPDATES_CONFIGURATION_REQUEST_HEADERS_KEY' "$M" || { echo "FATAL: channel injection failed"; exit 5; }
echo "  update channel ${CHANNEL} written to the manifest (eas.json profile ${PROFILE})"
sed -i -E "s/^([[:space:]]+)versionCode [0-9]+$/\1versionCode ${VCODE}/" android/app/build.gradle
grep -qE "versionCode ${VCODE}$" android/app/build.gradle || { echo "FATAL: versionCode injection failed"; exit 5; }
cd android || exit 1
run "gradle ${TASK}" timeout 4h ./gradlew "$TASK" --no-daemon --max-workers=4
if [[ "$TASK" == *bundleRelease ]]; then cp app/build/outputs/bundle/release/app-release.aab /out/ || { echo "FATAL: no app-release.aab"; exit 3; }
else cp app/build/outputs/apk/release/app-release.apk /out/ || { echo "FATAL: no app-release.apk"; exit 3; }; fi
echo "  SDK components after the build: $(cd "$ANDROID_HOME" && ls -d build-tools/* platforms/* ndk/* cmake/* 2>/dev/null | paste -sd' ' -)"
echo "=== build complete $(date) ==="
BUILD_END
TASK=":app:assembleRelease"; PROFILE="dapp-store"; [[ "$MODE" == splits ]] && { TASK=":app:bundleRelease"; PROFILE="production"; }
# RN writes the build host's first IPv4 into react_native_dev_server_ip; the build container gets the
# official value on a per-run network when it is a private address.
NET=""; NET_ARGS=()
if [[ "$dev_ip" =~ ^(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+$ && "${dev_ip##*.}" != 1 ]]; then
  # The subnet comes from the APK, so a parallel run may hold it: wait, and never build on another address.
  for _ in {1..20}; do
    if $CONTAINER_CMD network create --subnet "${dev_ip%.*}.0/24" "ws-shapeshift-net-${RUN_ID}" >/dev/null 2>&1; then
      NET="ws-shapeshift-net-${RUN_ID}"; NET_ARGS=(--network "$NET" --ip "$dev_ip"); break
    fi
    log_warn "Could not create a ${dev_ip%.*}.0/24 network; retrying in 30 s"; sleep 30
  done
  [[ -n "$NET" ]] || abort "Could not create a ${dev_ip%.*}.0/24 network for ${dev_ip}"
fi
log_info "Release inputs from ${main}: versionCode ${vcode}, commitTime ${commit_time:-none}, build host IPv4 ${dev_ip:-none}${NET:+ (network ${NET})}; eas.json profile ${PROFILE}; gradle ${TASK}"
log_info "Container build (typically 30-90 min)"
# A job, so a stop interrupts wait at once; the EXIT trap removes the named container.
crun --name "$BUILD_CTR" "${NET_ARGS[@]}" -e "EAS_PATH=${EAS_PATH}" -v "${BLD}:/out" -v "${CTX}/build.sh:/build.sh:ro" "$IMG" \
  timeout 5h bash /build.sh "$version_arg" "$vcode" "$commit_arg" "$commit_time" "$TASK" "$PROFILE" > >(tee "${BLD}/container.log") 2>&1 &
wait "$!"; BRC=$?; sleep 1
case $BRC in
  0) ;;
  4) abort "No source revision for ${version_arg} (see built/container.log); nothing was built" ;;
  3) has_compile_error "${BLD}/fail.log" && ftbfs "${APP_ID} ${vname} (${vcode}): the source failed to build (see built/fail.log). Official ${main} SHA-256 ${app_hash}."
     abort "Build failed with no source error (network, memory, disk or tooling); see built/container.log" ;;
  5) abort "This script cannot reproduce this release as written (see built/container.log); nothing was compared" ;;
  *) abort "Source preparation failed (container exit ${BRC})" ;;
esac
envv() { sed -n "s/^$1=//p" "${BLD}/src.env"; }
commit="$(envv COMMIT)"; rev_source="$(envv SOURCE)"; tags="$(envv TAGS)"
log_info "SKIP lines in the build log: $(grep -cE '\bSKIP\b' "${BLD}/build.log")"
# Reported only; GitHub's API, so it says nothing about who signed offline.
commit_sig="$(crun -e GITHUB_TOKEN "$IMG" bash -c 'h=(); [[ -n "${GITHUB_TOKEN:-}" ]] && h=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsS --max-time 30 "${h[@]}" "https://api.github.com/repos/shapeshift/mobile-app/commits/$1" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const v=JSON.parse(s).commit.verification;console.log(v.verified+\" (\"+v.reason+\")\")})"' _ "$commit" 2>/dev/null)"

declare -a PAIRS=()   # "official-path|built-path"
if [[ "$MODE" == universal ]]; then
  [[ -f "${BLD}/app-release.apk" ]] || abort "No app-release.apk was produced"
  PAIRS+=("${OFFICIAL[0]}|${BLD}/app-release.apk")
else
  [[ -f "${BLD}/app-release.aab" ]] || abort "No app-release.aab was produced"
  section "Rendering the app bundle with bundletool ${BUNDLETOOL_VERSION}"
  ABIS=(); DEN=""; LOCS=()
  for f in "${OFFICIAL[@]}"; do
    c="$(basename "$f" .apk)"; c="${c#split_config.}"
    case "$c" in
      base) ;;
      arm64_v8a) ABIS+=(arm64-v8a) ;; armeabi_v7a) ABIS+=(armeabi-v7a) ;; x86_64|x86) ABIS+=("$c") ;;
      ldpi) DEN=120;; mdpi) DEN=160;; tvdpi) DEN=213;; hdpi) DEN=240;; xhdpi) DEN=320;; xxhdpi) DEN=480;; xxxhdpi) DEN=640;;
      [a-z][a-z]|[a-z][a-z][a-z]) LOCS+=("$c") ;;
      *) log_warn "Unknown config split '${c}' ($(basename "$f")); it will stay unmatched" ;;
    esac
  done
  [[ ${#ABIS[@]} -eq 0 ]] && ABIS=("arm64-v8a"); [[ -z "$DEN" ]] && DEN=480; [[ ${#LOCS[@]} -eq 0 ]] && LOCS=("en")
  SDK="${WS_DEVICE_SDK:-36}"
  [[ "$SDK" =~ ^[0-9]+$ ]] || die_invalid "WS_DEVICE_SDK must be a number, got '${SDK}'"
  abij="$(printf '"%s",' "${ABIS[@]}")"; locj="$(printf '"%s",' "${LOCS[@]}")"
  printf '{"supportedAbis":[%s],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' "${abij%,}" "${locj%,}" "$DEN" "$SDK" > "${BLD}/device-spec.json"
  echo "  device-spec: $(cat "${BLD}/device-spec.json")"
  crun -v "${BLD}:/out" "$IMG" bash -c 'set -e; rm -rf /out/rendered; mkdir -p /out/rendered
    java -jar /opt/bundletool.jar build-apks --bundle=/out/app-release.aab --output=/out/rendered/built.apks \
      --device-spec=/out/device-spec.json --aapt2=$ANDROID_HOME/build-tools/36.0.0/aapt2 --overwrite
    cd /out/rendered && unzip -q -o built.apks "splits/*.apk" && ls splits/' 2>&1 | tee "${BLD}/bundletool.log" | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || abort "bundletool rendering failed (see built/bundletool.log)"
  crun -v "${OFFICIAL_DIR}:/official:ro" -v "${BLD}:/out" "$IMG" bash -c '
    BT=$ANDROID_HOME/build-tools/36.0.0
    cfg() { s=$("$BT/aapt2" dump badging "$1" 2>/dev/null | grep "^package:" | sed -n "s/.*split=.\([^\x27]*\).*/\1/p"); echo "${s#config.}"; }
    for o in /official/base.apk /official/split_config.*.apk; do co=$(cfg "$o"); m=""
      for b in /out/rendered/splits/*.apk; do [[ "$(cfg "$b")" == "$co" ]] && { m="$b"; break; }; done
      echo "$(basename "$o")|${co:-base}|${m:+rendered/splits/$(basename "$m")}"; done' > "${BLD}/pairs.txt" 2>/dev/null
  [[ $? -eq 0 && "$(wc -l < "${BLD}/pairs.txt")" -eq ${#OFFICIAL[@]} ]] || abort "Pairing official and rendered splits failed"
  while IFS='|' read -r o c b; do
    if [[ -n "$b" ]]; then PAIRS+=("${OFFICIAL_DIR}/${o}|${BLD}/${b}"); echo "  ${o} (split '${c}') <-> ${b}"
    else log_warn "No rendered counterpart for ${o} (split '${c}') -> counted as a difference"; PAIRS+=("${OFFICIAL_DIR}/${o}|"); fi
  done < "${BLD}/pairs.txt"
fi
# Every official APK must enter the comparison; an empty or short pair list never reads as reproducible.
[[ ${#PAIRS[@]} -eq ${#OFFICIAL[@]} && ${#PAIRS[@]} -gt 0 ]] || abort "Only ${#PAIRS[@]} of ${#OFFICIAL[@]} official APK(s) paired"

phase "PHASE 2: COMPARISON"
# Every raw diff must be EARNED by a class with printed evidence: root signature files, Play
# SourceStamp and manifest meta-data (Play splits only), an apktool-decoded-identical resources.arsc,
# or an expo-updates app.manifest that differs only in its random per-build id.
# Everything else (dex, JS bundle, native libs, assets, baseline.prof) is material.
cat > "${CTX}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
o=/official.apk; b=/built.apk; tag="$1"; mode="$2"; preview="$3"; out=/out
BT="$ANDROID_HOME/build-tools/36.0.0"; AAPT2="$BT/aapt2"; APKTOOL="java -jar /opt/apktool.jar"
rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
# A failed unzip or diff must never read as "no differences" (exit before the summary -> host aborts).
unzip -q -o "$o" -d /tmp/o; r1=$?; unzip -q -o "$b" -d /tmp/b; r2=$?
(( r1 < 2 && r2 < 2 )) && [[ -n $(find /tmp/o -type f -print -quit) && -n $(find /tmp/b -type f -print -quit) ]] || { echo "FATAL: unzip failed ($tag: $r1/$r2)"; exit 3; }
echo "  official: $(sha256sum "$o" | cut -c1-64)  ($(find /tmp/o -type f | wc -l) entries)"
echo "  built:    $(sha256sum "$b" | cut -c1-64)  ($(find /tmp/b -type f | wc -l) entries)"
expand_dirs() { while IFS= read -r l; do
  if [[ "$l" =~ ^Only\ in\ (/tmp/[ob])(/[^:]*)?:\ (.*)$ ]]; then
    r="${BASH_REMATCH[1]}"; d="${BASH_REMATCH[2]#/}"; p="${d:+$d/}${BASH_REMATCH[3]}"
    if [[ -d "$r/$p" ]]; then (cd "$r" && find "$p" -type f | sort | sed "s|^|Only in $r: |"); else printf 'Only in %s: %s\n' "$r" "$p"; fi
    continue; fi
  printf '%s\n' "$l"; done; }
raw="$(diff -rq /tmp/o /tmp/b)"; rc=$?; (( rc < 2 )) || { echo "FATAL: diff failed ($tag: rc $rc)"; exit 3; }
raw="$(expand_dirs <<<"$raw")" || { echo "FATAL: expand_dirs failed ($tag)"; exit 3; }; printf '%s\n' "$raw" > "$out/diff_${tag}.txt"
n=$(printf '%s\n' "$raw" | grep -vc '^$')
: > "$out/native_${tag}.txt"; nso=0; nsm=0
while IFS= read -r so; do
  rel="${so#/tmp/o/}"; nso=$((nso+1))
  if [[ -f "/tmp/b/$rel" ]] && cmp -s "$so" "/tmp/b/$rel"; then nsm=$((nsm+1)); continue; fi
  for side in o b; do f="/tmp/$side/$rel"; [[ -f "$f" ]] || { echo "$rel [$side] MISSING" >> "$out/native_${tag}.txt"; continue; }
    bp="$(strings "$f" | grep -oE '/(home|Users|root|build|tmp)/[^ ]*' | head -1 | cut -c1-80)"
    echo "$rel [$side] $(stat -c%s "$f") B; ${bp:-no build path}" >> "$out/native_${tag}.txt"; done
done < <(find /tmp/o -name '*.so' -type f | sort)
dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
js=""; [[ -f /tmp/o/assets/index.android.bundle ]] && js="index.android.bundle $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo same || echo DIFFERS)"
echo "  native libs ${nsm}/${nso} identical; dex differing: ${dx:-none}; JS: ${js:-none in this APK}"
[[ -s "$out/native_${tag}.txt" ]] && echo "  native evidence: native_${tag}.txt"
c_sign=$(printf '%s\n' "$raw" | grep -cE '^Only in /tmp/o: META-INF/([^/ ]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$')
c_stamp=$(grep -cx 'Only in /tmp/o: stamp-cert-sha256' <<<"$raw"); c_mani=$(grep -c '^Files /tmp/o/AndroidManifest\.xml ' <<<"$raw")
c_arsc=$(grep -c '^Files /tmp/o/resources\.arsc ' <<<"$raw"); c_upd=$(grep -c '^Files /tmp/o/assets/app\.manifest ' <<<"$raw")
a_sign=$c_sign; a_stamp=0; a_mani=0; a_arsc=0; a_upd=0
[[ $c_sign -gt 0 ]] && echo "      signing: ${c_sign} official-only root META-INF signature entr(ies)"
if [[ $c_stamp -gt 0 ]]; then
  if [[ "$mode" == splits && ! -e /tmp/b/stamp-cert-sha256 && "$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null)" == "32" ]] && grep -q 'Verified for SourceStamp: true' <<<"$("$BT/apksigner" verify --verbose "$o" 2>/dev/null)"; then
    a_stamp=$c_stamp; echo "      stamp: official-only 32-byte stamp-cert-sha256, apksigner SourceStamp OK (Play injects it)"
  else echo "      stamp: NOT EARNED -> material"; fi
fi
if [[ $c_mani -gt 0 && "$mode" != splits ]]; then
  echo "      manifest: NOT EARNED (no Play injection outside Play splits) -> material"
elif [[ $c_mani -gt 0 ]]; then
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null && "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null \
    && [[ -s /tmp/mo.txt && -s /tmp/mb.txt ]] || { echo "      manifest: NOT EARNED (aapt2 dump failed) -> material"; : > /tmp/mo.txt; echo x > /tmp/mb.txt; }
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"; printf '%s\n' "$d" > "$out/diff_manifest_${tag}.txt"
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  # Official-only entries, each name followed by its own value. diff may shift the "E:" lines, so those are counted.
  bad="$(printf '%s\n' "$left" | awk '
    /^E: meta-data/ { e++; next }
    !w && /android:name\(0x[0-9a-f]+\)="com\.android\.stamp\.source"/ { w="src"; n++; next }
    !w && /android:name\(0x[0-9a-f]+\)="com\.android\.stamp\.type"/ { w="typ"; n++; next }
    !w && /android:name\(0x[0-9a-f]+\)="com\.android\.vending\.derived\.apk\.id"/ { w="id"; n++; next }
    w=="src" && /android:value\(0x[0-9a-f]+\)="https:\/\/play\.google\.com\/store"/ { w=""; next }
    w=="typ" && /android:value\(0x[0-9a-f]+\)="STAMP_TYPE_DISTRIBUTION_APK"/ { w=""; next }
    w=="id" && /android:value\(0x[0-9a-f]+\)=[0-9]+$/ { w=""; next }
    NF { print }
    END { if (w != "" || e != n) print "unpaired meta-data" }')"
  if printf '%s\n' "$d" | grep -q '^>' || [[ -z "$(printf '%s' "$left" | tr -d '[:space:]')" || -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: NOT EARNED -> material (diff_manifest_${tag}.txt)"
  else a_mani=$c_mani; echo "      manifest: only Play distribution meta-data, official-only"; fi
fi
if [[ $c_arsc -gt 0 ]]; then
  if rm -rf /tmp/do /tmp/db && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/do "$o" >/dev/null 2>&1 \
     && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/db "$b" >/dev/null 2>&1 && [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
    rd="$(diff -r /tmp/do/res /tmp/db/res)"; rdrc=$?; printf '%s\n' "$rd" > "$out/diff_resources_decoded_${tag}.txt"
    if (( rdrc == 0 )); then a_arsc=$c_arsc; echo "      arsc: apktool-decoded res/ IDENTICAL (binary packing artifact)"
    elif (( rdrc > 1 )); then echo "      arsc: NOT EARNED (decoded diff failed, rc $rdrc) -> material"
    else echo "      arsc: decoded res/ differs -> material (diff_resources_decoded_${tag}.txt)"; fi
  else echo "      arsc: NOT EARNED (apktool decode failed) -> material"; fi
fi
if [[ $c_upd -gt 0 ]]; then
  # expo-updates' createManifest stamps a random UUID (crypto.randomUUID) into every embedded manifest; no rebuild
  # can repeat it. commitTime is pinned at build time, so here it must match like every other field.
  strip='const m=JSON.parse(require("fs").readFileSync(process.argv[1]));if(!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(m.id))process.exit(1);delete m.id;process.stdout.write(JSON.stringify(m))'
  so="$(node -e "$strip" /tmp/o/assets/app.manifest 2>/dev/null)"; sb="$(node -e "$strip" /tmp/b/assets/app.manifest 2>/dev/null)"
  if [[ -n "$so" && "$so" == "$sb" ]]; then a_upd=$c_upd; echo "      app.manifest: identical except expo-updates' random per-build id"
  else echo "      app.manifest: NOT EARNED (differs beyond a UUID id) -> material"; fi
fi
printf '%s\n' "$raw" | grep -q 'baseline\.prof' && echo "      baseline.prof: never auto-accepted (embeds dex checksums) -> material"
acc=$((a_sign+a_stamp+a_mani+a_arsc+a_upd)); un=$((n-acc)); (( un >= 0 )) || { echo "FATAL: accepted ${acc} exceeds raw ${n} ($tag)"; exit 3; }
echo "TOTALS ${n} ${acc} ${un}" > "$out/summary_${tag}.txt"
echo "  raw ${n}, accepted ${acc}, unaccounted ${un}  (full list: diff_${tag}.txt)"
printf '%s\n' "$raw" | grep -v '^$' | head -n "$preview" | cut -c1-200 | sed 's/^/    /'
CMP_END
tot_raw=0; tot_acc=0; tot_un=0; pair_notes=""; files_lines=""; shown=0   # at most 5 diff lines in the terminal, whole run
for p in "${PAIRS[@]}"; do
  o="${p%%|*}"; b="${p#*|}"; tag="$(basename "$o" .apk)"
  section "Comparing $(basename "$o") <-> $( [[ -n "$b" ]] && basename "$b" || echo '<no counterpart>' )"
  if [[ -z "$b" || ! -f "$b" ]]; then
    tot_un=$((tot_un+1)); tot_raw=$((tot_raw+1)); pair_notes+="${tag}: no built counterpart (1 unaccounted); "
    files_lines+="$(basename "$o") - ${tag} - none - 0 (DOESN'T MATCH)"$'\n'; continue
  fi
  crun -v "${o}:/official.apk:ro" -v "${b}:/built.apk:ro" -v "${CMP}:/out" -v "${CTX}/compare.sh:/compare.sh:ro" \
    "$IMG" bash /compare.sh "$tag" "$MODE" "$((5-shown))" 2>&1 | tee -a "${CMP}/comparison.log"
  read -r _ r a u < "${CMP}/summary_${tag}.txt" 2>/dev/null || abort "Comparison stage failed for ${tag}"
  shown=$(( shown+r < 5 ? shown+r : 5 ))
  tot_raw=$((tot_raw+r)); tot_acc=$((tot_acc+a)); tot_un=$((tot_un+u)); pair_notes+="${tag}: raw ${r}, accepted ${a}, unaccounted ${u}; "
  files_lines+="$(basename "$o") - ${tag} - $(sha256of "$b") - $([[ "$u" -eq 0 ]] && echo '1 (MATCHES)' || echo "0 (DOESN'T MATCH)")"$'\n'
done

section "RESULT"
rel_ws="${WS#"$(pwd -P)"/}"
cat <<EOF
 Pairs compared:       ${#PAIRS[@]}
 Raw differences:      ${tot_raw}
 Accepted (earned):    ${tot_acc}
 UNACCOUNTED:          ${tot_un}   <- the verdict is judged on this alone
 Diff lists:           ${rel_ws}/comparison/diff_*.txt, native_*.txt, diff_manifest_*.txt, diff_resources_decoded_*.txt
 Build logs:           ${rel_ws}/built/build.log, container.log
EOF
if [[ "$tot_un" -eq 0 ]]; then verdict="reproducible"; rc=0; head_line="BUILDS MATCH BINARIES"
else verdict="not_reproducible"; rc=1; head_line="BUILDS DO NOT MATCH BINARIES"; fi
generate_yaml "$verdict" "${APP_ID} ${vname} (versionCode ${vcode}; ${MODE}) built from ${commit} (${rev_source}); no release tag.
EAS-like build; versionCode, expo-updates commitTime and dev-server IPv4 copied from the official APK, so a match proves nothing about those values; update channel from eas.json profile ${PROFILE}; .env from the public .env.template.
Official ${main} SHA-256 ${app_hash}, signer ${signer:-unknown}.
${pair_notes}
Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}.
The APK is a WebView shell: the wallet UI runs from https://app.shapeshift.com and is not covered by this build. The shell stores mnemonics for that page, and an over-the-air update could replace the shell's JS without changing the APK."
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer:-unknown}"
echo "apkVersionName: ${vname}"
echo "apkVersionCode: ${vcode}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_HASH:-N/A}"
echo ""
echo "Diff:"
echo "${head_line}"
printf '%s' "$files_lines"
echo "Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}"
echo ""
echo "Revision, tag (and its signature):"
echo "Built: ${commit} (${rev_source})"
echo "Tags at the built commit: ${tags:-none (upstream does not tag 3.x releases)}"
echo "Tag signature: not applicable (no tag)"
echo "Commit signature (GitHub's API): ${commit_sig:-unknown}"
echo "===== End Results ====="
echo ""
echo "appHash = sha256 of ${main} as supplied/downloaded (publish this one); the per-split and built hashes above are for reference."
echo ""; echo "Exit code: ${rc}"
exit "$rc"
