#!/usr/bin/env bash
# ==============================================================================
# metamask_build.sh - MetaMask (Android) Reproducible Build Verification
# ==============================================================================
# Version:          v0.3.1
# Organization:     WalletScrutiny.com
# Last modified by: Bob (WalletScrutiny agent)
# Last modified on: 2026-09-25
# App ID:           io.metamask
# Project:          https://github.com/MetaMask/metamask-mobile
# Play Store:       https://play.google.com/store/apps/details?id=io.metamask
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include a changelog in this header.
# Changelog: ~/work/ws-notes/script-notes/android/io.metamask/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
#
# SCRIPT SUMMARY:
# MetaMask ships Android through Google Play only (GitHub releases carry no APK/AAB since 8.10.1), so
# --binary is required: a directory of Play splits (base.apk + split_config.*.apk) or one APK.
# Source: annotated tag v<versionName>. Build follows upstream CI (build.yml, build_name main-prod):
# yarn install --immutable, yarn setup:github-ci --no-build-ios, scripts/set-build-version.sh with the
# official versionCode (not in git), android/gradle.properties.release, then yarn build:android:main:prod
# (scripts/build.sh: builds.yml config, code fencing, expo channel, prebuild, assembleProdRelease +
# bundleProdRelease). NODE_OPTIONS 8192 / METRO_MAX_WORKERS 2 as upstream: a 4096 heap stalls Metro
# and no bundle is written. Splits are rendered from our AAB with bundletool against a device spec
# derived from the official split names. Signed with a throwaway key through upstream's own env vars.
# Private inputs: ~45 secrets inlined into the JS bundle (Infura, Segment, WalletConnect, QuickNode, FCM,
# ...). Values that are public in the official APK (Firebase resources, Braze key/endpoint, Branch keys,
# Expo project id, build paths) are read back from it and printed; pass --dotenv FILE for the rest.
# Every accepted difference must be earned by a named check. COMPARISON_RESULTS.yaml on every exit.
#
# Exit codes: 0 = reproducible, 1 = differences or build failure, 2 = invalid parameters.
# ==============================================================================

SCRIPT_VERSION="v0.3.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "$(basename "$SCRIPT_PATH") $SCRIPT_VERSION sha256:${SCRIPT_HASH:-unknown}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

APP_ID="io.metamask"
REPO_URL="https://github.com/MetaMask/metamask-mobile"
DEF_SRC="/home/runner/_work/metamask-mobile/metamask-mobile"; DEF_GRADLE="/home/runner/_work/.gradle"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
phase()   { printf '\n== %s ==\n  %s\n' "$*" "$(date)"; }
section() { printf -- '\n-- %s --\n' "$*"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# COMPARISON_RESULTS.yaml goes next to the script (ABS reads it there). Three keys only.
generate_yaml() {
  { echo "script_version: $SCRIPT_VERSION"
    echo "verdict: $1"
    echo "notes: |"
    printf '%s\n' "$2" | sed 's/^/  /'; } > "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
  log_info "COMPARISON_RESULTS.yaml written with verdict: $1"
}
# Every failure path prints its reason, writes the YAML and prints a results block with what is known so far.
fail() {
  log_error "$2"; generate_yaml ftbfs "$2"
  echo ""; echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"; echo "signer:         ${signer:-unknown}"
  echo "apkVersionName: ${vname:-unknown}"; echo "apkVersionCode: ${vcode:-unknown}"
  echo "verdict:        ftbfs"; echo "appHash:        ${app_hash:-unknown}"; echo "commit:         ${commit:-unknown}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"; echo "scriptHash:     ${SCRIPT_HASH:-unknown}"
  echo ""; echo "Diff:"; echo "NOT BUILT: $2"; echo "===== End Results ====="
  echo ""; echo "Exit code: $1"; exit "$1"
}
die_invalid() { fail 2 "Invalid invocation: $1"; }
require_arg() { [[ -z "${2:-}" || "${2:-}" == --* ]] && die_invalid "$1 requires a value"; }

usage() {
  cat <<USAGE
Usage: $(basename "$SCRIPT_PATH") --binary <Play-split-dir | apk> [--version <v>] [--commit <ref>] [--dotenv <file>]

 --binary, --apk  Directory of Play splits (base.apk + split_config.*.apk), or one APK. Required:
                  MetaMask publishes no downloadable APK.
 --version        App version (e.g. 8.12.0); default: the official APK's versionName.
 --commit         Build this commit instead of the release tag.
 --dotenv         KEY=value (or export KEY=value) lines for upstream's private production secrets
                  (builds.yml "secrets": MM_INFURA_PROJECT_ID, SEGMENT_WRITE_KEY, MM_FOX_CODE, ...).
 --arch, --type   Accepted and ignored (ABIs come from the split names).
 WS_DEVICE_SDK    env: override the device-spec API level (default: base.apk minSdkVersion).
 MEM_LIMIT        env: container memory limit (default 40g; empty = none).

Exit codes: 0 = reproducible, 1 = differences or build failure, 2 = invalid parameters.
USAGE
}

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; commit_arg=""; dotenv_arg=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      require_arg "$1" "${2:-}"; version_arg="${2#v}"; shift 2 ;;
    --apk|--binary) require_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
    --commit)       require_arg "$1" "${2:-}"; commit_arg="$2"; shift 2 ;;
    --dotenv)       require_arg "$1" "${2:-}"; dotenv_arg="$2"; shift 2 ;;
    --arch|--type)  require_arg "$1" "${2:-}"; log_info "$1 $2 accepted, not used"; shift 2 ;;
    --help)         usage; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || die_invalid "Invalid --version '${version_arg}'"
[[ -z "$commit_arg" || "$commit_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_invalid "--commit must be 7-40 hex characters"
if [[ -n "$dotenv_arg" ]]; then [[ -f "$dotenv_arg" ]] || die_invalid "--dotenv file not found: ${dotenv_arg}"; dotenv_arg="$(readlink -f "$dotenv_arg")"; fi
if [[ -z "$binary_arg" ]]; then
  usage; die_invalid "--binary is required: MetaMask ships Android only through Google Play (no downloadable APK)"
fi

# Official artifact set. MODE splits: base.apk + split_config.*.apk (paired by split= attribute).
# MODE apk: one APK compared against upstream's assembleProdRelease output.
declare -a OFFICIAL=()
binary_arg="$(readlink -f "$binary_arg")" || die_invalid "--binary not found"
if [[ -f "$binary_arg" ]]; then
  [[ "$binary_arg" == *.apk ]] || die_invalid "--binary file must be an .apk: ${binary_arg}"
  OFFICIAL_DIR="$(dirname "$binary_arg")"; OFFICIAL=("$binary_arg"); MODE=apk
elif [[ -d "$binary_arg" ]]; then
  OFFICIAL_DIR="$binary_arg"
  [[ -f "${OFFICIAL_DIR}/base.apk" ]] || die_invalid "--binary directory has no base.apk: ${OFFICIAL_DIR}"
  OFFICIAL+=("${OFFICIAL_DIR}/base.apk")
  while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$OFFICIAL_DIR" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
  n_other="$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' ! -name base.apk ! -name 'split_config.*.apk' | wc -l)"
  [[ "$n_other" -eq 0 ]] || die_invalid "Unexpected APK(s) in the split directory (only base.apk and split_config.*.apk are allowed)"
  if [[ ${#OFFICIAL[@]} -gt 1 ]]; then MODE=splits; else MODE=apk; fi
else die_invalid "--binary is neither a file nor a directory: ${binary_arg}"; fi

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v podman &>/dev/null; then CONTAINER_CMD=podman
  elif command -v docker &>/dev/null; then CONTAINER_CMD=docker
  else die_invalid "Neither podman nor docker found in PATH (the only host requirement)"; fi
fi
if [[ "$CONTAINER_CMD" == *podman* ]]; then RUN_USER=(--userns=keep-id); OWNER="0:0"
else RUN_USER=(--user "${HOST_UID}:${HOST_GID}"); OWNER="${HOST_UID}:${HOST_GID}"; fi
MEM_LIMIT="${MEM_LIMIT-40g}"; MEM_ARGS=(); [[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")
crun() { $CONTAINER_CMD run --rm "${RUN_USER[@]}" -e HOME=/tmp/h "${MEM_ARGS[@]}" "$@"; }

RUN_ID="metamask-${version_arg:-bin}-$(date +%s)-$$"
IMG="ws-metamask-${RUN_ID}"
WS="$(pwd -P)/metamask_verification_${RUN_ID}"
META="${WS}/metadata"; BLD="${WS}/built"; CMP="${WS}/comparison"; CTX="${WS}/ctx"
mkdir -p "$META" "$BLD" "$CMP" "$CTX" "${WS}/src" "${WS}/gradle-home" || die_invalid "Cannot create workspace ${WS}"
cleanup() {
  if $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1; then
    # Rootless podman: container root is the caller, so 0:0; rootful docker: the caller's ids.
    $CONTAINER_CMD run --rm -v "${WS}:/t" "$IMG" chown -R "$OWNER" /t >/dev/null 2>&1
    $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

cat <<EOF

==============================================================
  METAMASK - ANDROID VERIFICATION
==============================================================
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Official:  ${#OFFICIAL[@]} APK(s) from ${OFFICIAL_DIR} (mode: ${MODE})
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${WS}
EOF

phase "SETUP: BUILD CONTAINER IMAGE"
# Node 24.16.0 = upstream .nvmrc; yarn 4.14.1 comes from the repo (packageManager + committed yarnPath).
# Temurin 17 = upstream setup-java. SDK 36, build-tools 36.0.0, NDK 27.1.12297006 = android/build.gradle;
# CMake 3.22.1 = upstream CMAKE_VERSION. The SDK is writable so AGP can fetch any other pinned component.
cat > "${CTX}/Dockerfile" <<DOCKERFILE_END
FROM docker.io/library/node:24.16.0-bookworm@sha256:40ad9f3064e67d6860b4bc3fe1880b2953934fd6320ada990e45fe0efa6badd7
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends git unzip zip curl ca-certificates binutils python3 build-essential \\
  && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && curl -fsSL -o jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz" \\
  && echo "d8afc263758141a66e0e3aafc321e783f7016696f4eaea067d340a269037d331  jdk.tar.gz" | sha256sum -c - \\
  && mkdir -p /opt/jdk17 && tar -xzf jdk.tar.gz -C /opt/jdk17 --strip-components=1 && rm jdk.tar.gz
ENV JAVA_HOME=/opt/jdk17 ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=/opt/jdk17/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:\$PATH
RUN mkdir -p \$ANDROID_HOME/cmdline-tools && cd \$ANDROID_HOME/cmdline-tools \\
  && curl -fsSL -o ct.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \\
  && echo "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258  ct.zip" | sha256sum -c - \\
  && unzip -q ct.zip && rm ct.zip && mv cmdline-tools latest
RUN yes | sdkmanager --licenses >/dev/null && sdkmanager "platforms;android-36" "build-tools;36.0.0" \\
    "platform-tools" "ndk;27.1.12297006" "cmake;3.22.1" >/dev/null && chmod -R a+rwX \$ANDROID_HOME
RUN cd /opt && curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar \\
  && echo "${APKTOOL_SHA256}  apktool.jar" | sha256sum -c - \\
  && curl -fsSL -o bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar \\
  && echo "${BUNDLETOOL_SHA256}  bundletool.jar" | sha256sum -c - && chmod 0644 apktool.jar bundletool.jar
RUN corepack enable && mkdir -p /tmp/h /tmp/afw && chmod 0777 /tmp/h /tmp/afw
DOCKERFILE_END
$CONTAINER_CMD build -t "$IMG" -f "${CTX}/Dockerfile" "$CTX" || fail 1 "Container image build failed; no comparison was performed."
log_success "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL ARTIFACT METADATA"
# Also recovers the release inputs that are public inside the official APKs.
cat > "${CTX}/meta.sh" <<'META_END'
#!/bin/bash
BT="$ANDROID_HOME/build-tools/36.0.0"
res() { "$BT/aapt2" dump resources "$1" 2>/dev/null | grep -A1 "string/$2\b" | sed -n 's/.*"\(.*\)".*/\1/p' | head -1; }
mval() { grep -A2 "\"$2\"" "$1" | sed -n 's/.*android:value([^)]*)="\([^"]*\)".*/\1/p' | head -1; }
for A in "$@"; do
  i="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"; p="$(printf '%s\n' "$i" | grep '^package:')"
  g() { printf '%s\n' "$p" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
  pkg="$(printf '%s\n' "$p" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  abis="$(printf '%s\n' "$i" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
  minsdk="$(printf '%s\n' "$i" | sed -n "s/^\(minSdkVersion\|sdkVersion\):'\([0-9]*\)'.*/\2/p" | head -1)"
  sv="$("$BT/apksigner" verify --verbose --print-certs "$A" 2>/dev/null)"
  signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/{print $NF; exit}')"
  stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
  echo "$(basename "$A")|${pkg}|$(g versionName)|$(g versionCode)|$(g split)|${abis}|${minsdk}|${signer}|${stamp}" >> /m/apks.txt
  echo "[META] $(basename "$A"): ${pkg} $(g versionName) ($(g versionCode)) split '$(g split)' abis ${abis:-none} minSdk ${minsdk} SourceStamp ${stamp}"
  echo "[META]   signer ${signer:-?}"
  # Release inputs (base APK only): Firebase values from google-services, Braze, Branch, Expo project id.
  if [[ -z "$(g split)" ]]; then
    for k in google_app_id gcm_defaultSenderId default_web_client_id firebase_database_url google_api_key google_crash_reporting_api_key google_storage_bucket project_id com_braze_api_key com_braze_custom_endpoint; do
      echo "${k}=$(res "$A" "$k")" >> /m/inputs.txt; done
    "$BT/aapt2" dump xmltree --file AndroidManifest.xml "$A" > /tmp/mf.txt 2>/dev/null
    echo "branch_live=$(mval /tmp/mf.txt io.branch.sdk.BranchKey)" >> /m/inputs.txt
    echo "branch_test=$(mval /tmp/mf.txt io.branch.sdk.BranchKey.test)" >> /m/inputs.txt
    echo "expo_project_id=$(mval /tmp/mf.txt expo.modules.updates.EXPO_UPDATE_URL | sed -n 's|.*u\.expo\.dev/||p')" >> /m/inputs.txt
  fi
  # Build paths baked into native libraries: checkout root and Gradle user home.
  for so in $(unzip -Z1 "$A" 'lib/*.so' 2>/dev/null); do unzip -p "$A" "$so" | strings; done > /tmp/s.txt 2>/dev/null
  # Cut at the first node_modules so a nested node_modules path cannot extend the checkout root.
  r="$(grep -oE '(/[A-Za-z0-9._-]+)+/node_modules/' /tmp/s.txt | grep -v '/\.gradle/' | sed 's|/node_modules/.*||' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  if [[ -n "$r" ]]; then echo "src_root=${r}" >> /m/inputs.txt; fi
  gh="$(grep -oE '^/[^ ]+/\.gradle/caches/' /tmp/s.txt | head -1)"
  if [[ -n "$gh" ]]; then echo "gradle_home=${gh%/caches/}" >> /m/inputs.txt; fi
done
# The last APK is usually a lib-less split with no paths; its empty checks must not become the exit status.
exit 0
META_END
: > "${META}/apks.txt"; : > "${META}/inputs.txt"
declare -a MNT=(); for f in "${OFFICIAL[@]}"; do MNT+=("/official/$(basename "$f")"); done
crun -v "${OFFICIAL_DIR}:/official:ro" -v "${META}:/m" -v "${CTX}/meta.sh:/meta.sh:ro" "$IMG" bash /meta.sh "${MNT[@]}" \
  || fail 1 "Could not read metadata from the official APKs."
main="$(basename "${OFFICIAL[0]}")"
IFS='|' read -r _ pkg vname vcode main_split _ min_sdk signer _ <<<"$(grep "^${main}|" "${META}/apks.txt" | head -1)"
[[ "$(awk -F'|' '$2 != "'"$APP_ID"'"' "${META}/apks.txt" | wc -l)" -eq 0 && -n "$pkg" ]] || die_invalid "Not every official APK is ${APP_ID} (see [META] lines)"
[[ -z "$main_split" ]] || die_invalid "${main} declares split '${main_split}'"
[[ -n "$vname" && "$vcode" =~ ^[0-9]+$ ]] || fail 1 "Could not read versionName/versionCode from ${main}."
app_hash="$(sha256of "${OFFICIAL[0]}")"
if [[ -z "$version_arg" ]]; then version_arg="$vname"
elif [[ "$version_arg" != "$vname" ]]; then log_warn "--version ${version_arg} but ${main} says ${vname}; building ${version_arg}"; fi
inp() { sed -n "s/^$1=//p" "${META}/inputs.txt" | grep -v '^$' | head -1; }
SRC_ROOT="$(inp src_root)"; GRADLE_HOME="$(inp gradle_home)"
# A recovered path becomes a bind-mount target, so it must not shadow the image's own directories.
SYS_RE='^/(bin|boot|dev|etc|lib|lib32|lib64|opt|proc|run|sbin|sys|tmp|usr|var)(/|$)'
[[ "$SRC_ROOT" =~ ^/[A-Za-z0-9._/-]+$ && ! "$SRC_ROOT" =~ $SYS_RE ]] || { log_warn "No usable checkout path in the official native libs ('${SRC_ROOT}'); using ${DEF_SRC}"; SRC_ROOT="$DEF_SRC"; }
[[ "$GRADLE_HOME" =~ ^/[A-Za-z0-9._/-]+$ && ! "$GRADLE_HOME" =~ $SYS_RE ]] || { log_warn "No usable Gradle home in the official native libs ('${GRADLE_HOME}'); using ${DEF_GRADLE}"; GRADLE_HOME="$DEF_GRADLE"; }
log_success "${APP_ID} ${vname} (versionCode ${vcode})"
log_info "${main} SHA-256 ${app_hash}; signer ${signer:-?}"
log_info "Build paths: checkout ${SRC_ROOT}, Gradle home ${GRADLE_HOME}"
n_inp="$(grep -cE '^[a-z_A-Z]+=.+' "${META}/inputs.txt")"
log_info "Release inputs recovered from ${main}: ${n_inp} ($(grep -E '=.+' "${META}/inputs.txt" | cut -d= -f1 | paste -sd' ' -))"

phase "PHASE 1: BUILD FROM SOURCE (${version_arg})"
cat > "${CTX}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
V="$1"; REPO="$2"; WANT="$3"; VCODE="$4"; SRC="$5"
inp() { sed -n "s/^$1=//p" /m/inputs.txt | head -1; }
git config --global --add safe.directory '*'
git clone -q --filter=blob:none "$REPO" "$SRC" || { echo "FATAL: clone failed"; exit 1; }
cd "$SRC" || exit 1
TAG=""; tagc=""
c="$(git rev-parse -q --verify "refs/tags/v${V}^{commit}")" && { TAG="v${V}"; tagc="$c"; }
if [[ -n "$WANT" ]]; then
  c="$(git rev-parse -q --verify "${WANT}^{commit}")" || { git fetch -q origin "$WANT" 2>/dev/null; c="$(git rev-parse -q --verify "${WANT}^{commit}")"; }
  [[ -n "$c" ]] || { echo "FATAL: --commit ${WANT} is not in ${REPO}"; exit 4; }; src="--commit"
elif [[ -n "$tagc" ]]; then c="$tagc"; src="tag ${TAG}"
else echo "FATAL: no tag v${V} in ${REPO}"; exit 4; fi
git checkout -q "$c" || exit 2
gv="$(sed -n 's/^ *versionName "\(.*\)"/\1/p' android/app/build.gradle | head -1)"
{ echo "COMMIT=$(git rev-parse HEAD)"; echo "TAG=${TAG:-none}"; echo "TAG_COMMIT=${tagc:-none}"
  echo "TAG_TYPE=$( [[ -n "$TAG" ]] && git cat-file -t "refs/tags/${TAG}" || echo none)"; echo "SOURCE=${src}"; } > /out/src.env
git log -1 --format='  built: %H %ci %s'; echo "  source: ${src}; tag ${TAG:-<none>} -> ${tagc:-<missing>}"
echo "  build.gradle: versionName ${gv}"; [[ "$gv" == "$V" ]] || echo "  WARNING: build.gradle declares ${gv}, not ${V}"
run() { echo "=== $1 === $(date)"; shift; "$@" > /out/step.log 2>&1 || { tail -60 /out/step.log; cat /out/step.log >> /out/build.log; echo "FATAL: step failed"; exit 3; }; cat /out/step.log >> /out/build.log; }
# versionCode is not in git: CI applies the build number with this script (build.yml "Apply build number").
if ! ./scripts/set-build-version.sh "$VCODE" > /out/setver.log 2>&1; then
  # It also refuses a number <= the iOS placeholder; apply its own Android sed alone.
  echo "  set-build-version.sh refused ($(tail -1 /out/setver.log)); applying its build.gradle sed only"
  sed -i -E "s/(\s*versionCode )[0-9]+/\1${VCODE}/" android/app/build.gradle
fi
echo "  build.gradle versionCode now $(sed -n 's/^ *versionCode \([0-9]*\)/\1/p' android/app/build.gradle | head -1)"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=true
echo "  node $(node --version), $(java -version 2>&1 | head -1), yarn $(yarn --version 2>/dev/null)"
run "yarn install --immutable" yarn install --immutable
# setup-node-modules.yml, Android: generic project setup (patches, inpage bridge, ...).
export BUILD_CONFIG_NAME=main-prod METAMASK_BUILD_TYPE=main METAMASK_ENVIRONMENT=production
run "yarn setup:github-ci --no-build-ios" yarn setup:github-ci --no-build-ios
# Secrets: scripts/build.sh sources .js.env after builds.yml when GITHUB_ACTIONS is unset.
: > .js.env
if [[ -f /dotenv ]]; then sed -nE 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=)/export \2/p' /dotenv >> .js.env; echo "  .js.env += --dotenv ($(grep -c . .js.env) keys)"
else echo "  WARNING: no --dotenv: upstream's private production secrets are absent (inlined into the JS bundle)"; fi
addenv() { [[ -n "$2" ]] && ! grep -q "^export $1=" .js.env && printf 'export %s=%q\n' "$1" "$2" >> .js.env; }
addenv MM_BRAZE_API_KEY_ANDROID "$(inp com_braze_api_key)"; addenv MM_BRAZE_SDK_ENDPOINT "$(inp com_braze_custom_endpoint)"
addenv MM_BRANCH_KEY_LIVE "$(inp branch_live)"; addenv MM_BRANCH_KEY_TEST "$(inp branch_test)"
addenv EXPO_PROJECT_ID "$(inp expo_project_id)"
# build.yml exports GIT_BRANCH (runway-production-builds.yml passes source_branch or github.sha) and the
# Settings screen inlines process.env.GIT_BRANCH into the bundle; default to the built commit, --dotenv overrides.
addenv GIT_BRANCH "$(git rev-parse HEAD)"
echo "  .js.env keys: $(sed -n 's/^export \([A-Za-z0-9_]*\)=.*/\1/p' .js.env | paste -sd' ' -)"
# google-services.json (GOOGLE_SERVICES_B64_ANDROID, a secret) rebuilt from the official APK's resources.
python3 - <<'PY' || { echo "FATAL: google-services.json"; exit 3; }
import json
v = dict(l.rstrip('\n').split('=', 1) for l in open('/m/inputs.txt') if '=' in l)
if not v.get('google_app_id'): print("  WARNING: no google_app_id in the official APK; stub google-services.json"); v['google_app_id'] = '1:0:android:0'
c = {"client_info": {"mobilesdk_app_id": v['google_app_id'], "android_client_info": {"package_name": "io.metamask"}},
     "oauth_client": ([{"client_id": v['default_web_client_id'], "client_type": 3}] if v.get('default_web_client_id') else []),
     "api_key": [{"current_key": v.get('google_api_key') or v.get('google_crash_reporting_api_key') or 'x'}],
     "services": {"appinvite_service": {"other_platform_oauth_client": []}}}
pi = {"project_number": v.get('gcm_defaultSenderId') or '0', "project_id": v.get('project_id') or 'x'}
if v.get('google_storage_bucket'): pi["storage_bucket"] = v['google_storage_bucket']
if v.get('firebase_database_url'): pi["firebase_url"] = v['firebase_database_url']
json.dump({"project_info": pi, "client": [c], "configuration_version": "1"}, open('/tmp/gs.json', 'w'), indent=2)
print("  google-services.json from official resources: " + ", ".join(k for k in ('google_app_id','gcm_defaultSenderId','default_web_client_id','google_api_key','project_id','google_storage_bucket','firebase_database_url') if v.get(k)))
PY
GOOGLE_SERVICES_B64_ANDROID="$(base64 -w0 /tmp/gs.json)"; export GOOGLE_SERVICES_B64_ANDROID
# build.yml: production Gradle config, JDK 17, CMake 3.22.1, Metro heap/workers.
cp android/gradle.properties.release android/gradle.properties || { echo "FATAL: no gradle.properties.release"; exit 3; }
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > android/local.properties
export ANDROID_USER_HOME="${HOME}/.android" CMAKE_VERSION=3.22.1 NODE_OPTIONS=--max-old-space-size=8192 METRO_MAX_WORKERS=2
mkdir -p "$ANDROID_USER_HOME"
# Sentry: uploads stay off (build.sh default); build.sh only needs some alphanumeric token in production.
export SENTRY_DISABLE_AUTO_UPLOAD=true MM_SENTRY_AUTH_TOKEN=wsverifydummy
# Throwaway release key through upstream's own signingConfigs.mainProd env vars (build.gradle not patched).
mkdir -p android/keystores
export BITRISEIO_ANDROID_KEYSTORE_PASSWORD=wsverify BITRISEIO_ANDROID_KEYSTORE_ALIAS=ws BITRISEIO_ANDROID_KEYSTORE_PRIVATE_KEY_PASSWORD=wsverify
keytool -genkeypair -keystore android/keystores/release.keystore -storetype PKCS12 -alias ws -storepass wsverify -keypass wsverify \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=WalletScrutiny" >/dev/null 2>&1 || { echo "FATAL: keytool"; exit 3; }
run "yarn build:android:main:prod (scripts/build.sh android main production)" yarn build:android:main:prod
cp android/app/build/outputs/bundle/prodRelease/app-prod-release.aab /out/app-release.aab || { echo "FATAL: no app-prod-release.aab"; exit 3; }
cp android/app/build/outputs/apk/prod/release/app-prod-release.apk /out/app-release.apk || { echo "FATAL: no app-prod-release.apk"; exit 3; }
sha256sum /out/app-release.* | sed 's/^/  /'
echo "=== build complete $(date) ==="
BUILD_END
DOT_ARGS=(); [[ -n "$dotenv_arg" ]] && DOT_ARGS=(-v "${dotenv_arg}:/dotenv:ro")
log_info "Container build (typically 60-120 min: upstream builds the APK and then the AAB)"
# Source and Gradle home are mounted at the paths the official native libs record.
crun "${DOT_ARGS[@]}" -e "GRADLE_USER_HOME=${GRADLE_HOME}" \
  -v "${WS}/src:${SRC_ROOT}" -v "${WS}/gradle-home:${GRADLE_HOME}" -v "${META}:/m:ro" \
  -v "${BLD}:/out" -v "${CTX}/build.sh:/build.sh:ro" "$IMG" \
  bash /build.sh "$version_arg" "$REPO_URL" "$commit_arg" "$vcode" "$SRC_ROOT" 2>&1 | tee "${BLD}/container.log"
BRC=${PIPESTATUS[0]}
if [[ $BRC -ne 0 ]]; then
  [[ $BRC -eq 4 ]] && fail 1 "No source revision for ${version_arg} (see container.log); nothing was built. Official ${main} SHA-256 ${app_hash}."
  fail 1 "Source build failed (container exit ${BRC}: 1 clone, 2 checkout, 3 install/build). Official ${main} SHA-256 ${app_hash}."
fi
envv() { sed -n "s/^$1=//p" "${BLD}/src.env"; }
commit="$(envv COMMIT)"; tag="$(envv TAG)"; tag_commit="$(envv TAG_COMMIT)"; tag_type="$(envv TAG_TYPE)"; rev_source="$(envv SOURCE)"

declare -a PAIRS=()   # "official-path|built-path"
if [[ "$MODE" == apk ]]; then
  [[ -f "${BLD}/app-release.apk" ]] || fail 1 "No app-release.apk was produced. Official ${main} SHA-256 ${app_hash}."
  PAIRS=("${OFFICIAL[0]}|${BLD}/app-release.apk"); echo "  ${main} <-> app-release.apk"
else
  [[ -f "${BLD}/app-release.aab" ]] || fail 1 "No app-release.aab was produced. Official ${main} SHA-256 ${app_hash}."
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
  SDK="${WS_DEVICE_SDK:-$min_sdk}"
  [[ "$SDK" =~ ^[0-9]+$ ]] || die_invalid "Could not determine the device API level (base.apk minSdkVersion '${min_sdk}'); set WS_DEVICE_SDK"
  abij="$(printf '"%s",' "${ABIS[@]}")"; locj="$(printf '"%s",' "${LOCS[@]}")"
  printf '{"supportedAbis":[%s],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' "${abij%,}" "${locj%,}" "$DEN" "$SDK" > "${BLD}/device-spec.json"
  echo "  device-spec: $(cat "${BLD}/device-spec.json")"
  crun -v "${BLD}:/out" "$IMG" bash -c 'set -e; rm -rf /out/rendered; mkdir -p /out/rendered
    java -jar /opt/bundletool.jar build-apks --bundle=/out/app-release.aab --output=/out/rendered/built.apks \
      --device-spec=/out/device-spec.json --aapt2=$ANDROID_HOME/build-tools/36.0.0/aapt2 --overwrite
    cd /out/rendered && unzip -q -o built.apks "splits/*.apk" && ls splits/' 2>&1 | tee "${BLD}/bundletool.log" | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || fail 1 "bundletool rendering failed (see built/bundletool.log). Official ${main} SHA-256 ${app_hash}."
  crun -v "${OFFICIAL_DIR}:/official:ro" -v "${BLD}:/out" "$IMG" bash -c '
    BT=$ANDROID_HOME/build-tools/36.0.0
    cfg() { s=$("$BT/aapt2" dump badging "$1" 2>/dev/null | grep "^package:" | sed -n "s/.*split=.\([^\x27]*\).*/\1/p"); echo "${s#config.}"; }
    for o in /official/base.apk /official/split_config.*.apk; do co=$(cfg "$o"); m=""
      for b in /out/rendered/splits/*.apk; do [[ "$(cfg "$b")" == "$co" ]] && { m="$b"; break; }; done
      echo "$(basename "$o")|${co:-base}|${m:+rendered/splits/$(basename "$m")}"; done' > "${BLD}/pairs.txt" 2>/dev/null
  prc=$?
  [[ $prc -eq 0 && "$(grep -c . "${BLD}/pairs.txt")" -eq ${#OFFICIAL[@]} ]] || fail 1 "Pairing official and rendered splits failed (exit ${prc}). Official ${main} SHA-256 ${app_hash}."
  while IFS='|' read -r o c b; do
    if [[ -n "$b" ]]; then PAIRS+=("${OFFICIAL_DIR}/${o}|${BLD}/${b}"); echo "  ${o} (split '${c}') <-> ${b}"
    else log_warn "No rendered counterpart for ${o} (split '${c}') -> counted as a difference"; PAIRS+=("${OFFICIAL_DIR}/${o}|"); fi
  done < "${BLD}/pairs.txt"
fi
# Every official APK must enter the comparison; an empty or short pair list never reads as reproducible.
[[ ${#PAIRS[@]} -eq ${#OFFICIAL[@]} && ${#PAIRS[@]} -gt 0 ]] || fail 1 "Only ${#PAIRS[@]} of ${#OFFICIAL[@]} official APK(s) paired."

phase "PHASE 2: COMPARISON"
# Every raw diff must be EARNED by a class with printed evidence: root signature files, Play
# SourceStamp, Play manifest meta-data, or an apktool-decoded-identical resources.arsc.
# Everything else (dex, JS bundle, native libs, assets, baseline.prof) is material.
cat > "${CTX}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
o=/official.apk; b=/built.apk; tag="$1"; out=/out
BT="$ANDROID_HOME/build-tools/36.0.0"; AAPT2="$BT/aapt2"; APKTOOL="java -jar /opt/apktool.jar"
rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
# A failed unzip or diff must never read as "no differences" (exit before the summary -> host fails).
unzip -q -o "$o" -d /tmp/o; r1=$?; unzip -q -o "$b" -d /tmp/b; r2=$?
(( r1 < 2 && r2 < 2 )) && [[ -n $(find /tmp/o -type f -print -quit) && -n $(find /tmp/b -type f -print -quit) ]] || { echo "FATAL: unzip failed ($tag: $r1/$r2)"; exit 3; }
echo "  official: $(sha256sum "$o" | cut -c1-64)  ($(find /tmp/o -type f | wc -l) entries)"
echo "  built:    $(sha256sum "$b" | cut -c1-64)  ($(find /tmp/b -type f | wc -l) entries)"
# diff -rq reports a one-sided directory as one line; expand it so every file is judged by name.
expand_dirs() { while IFS= read -r l; do
  if [[ "$l" =~ ^Only\ in\ (/tmp/[ob])(/[^:]*)?:\ (.*)$ ]]; then
    r="${BASH_REMATCH[1]}"; d="${BASH_REMATCH[2]#/}"; p="${d:+$d/}${BASH_REMATCH[3]}"
    if [[ -d "$r/$p" ]]; then (cd "$r" && find "$p" -type f | sort | sed "s|^|Only in $r: |"); else printf 'Only in %s: %s\n' "$r" "$p"; fi
    continue; fi
  printf '%s\n' "$l"; done; }
raw="$(diff -rq /tmp/o /tmp/b)"; rc=$?; (( rc < 2 )) || { echo "FATAL: diff failed ($tag: rc $rc)"; exit 3; }
raw="$(expand_dirs <<<"$raw")" || { echo "FATAL: expand_dirs failed ($tag)"; exit 3; }; printf '%s\n' "$raw" > "$out/diff_${tag}.txt"
n=$(printf '%s\n' "$raw" | grep -vc '^$')
# Native library evidence per differing .so (both sides): compiler stamp, build path.
: > "$out/native_${tag}.txt"; nso=0; nsm=0
while IFS= read -r so; do
  rel="${so#/tmp/o/}"; nso=$((nso+1))
  if [[ -f "/tmp/b/$rel" ]] && cmp -s "$so" "/tmp/b/$rel"; then nsm=$((nsm+1)); continue; fi
  for side in o b; do f="/tmp/$side/$rel"; [[ -f "$f" ]] || { echo "$rel [$side] MISSING" >> "$out/native_${tag}.txt"; continue; }
    cc="$(readelf -p .comment "$f" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -oE 'clang version [0-9.]+|Android \([^)]*\)' | head -2 | paste -sd' ' -)"
    gp="$(strings "$f" | grep -oE '^/(opt/homebrew|Users|home|root|build|tmp|builds)/[^ ]*' | head -1 | cut -c1-60)"
    echo "$rel [$side] $(stat -c%s "$f") B; ${cc:-no .comment}; ${gp:-no build path}" >> "$out/native_${tag}.txt"; done
done < <(find /tmp/o -name '*.so' -type f | sort)
dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
js=""; [[ -f /tmp/o/assets/index.android.bundle ]] && js="index.android.bundle $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo same || echo DIFFERS)"
echo "  native libs ${nsm}/${nso} identical; dex differing: ${dx:-none}; JS: ${js:-none in this APK}"
[[ -s "$out/native_${tag}.txt" ]] && { echo "  native evidence (full: native_${tag}.txt):"; head -4 "$out/native_${tag}.txt" | cut -c1-200 | sed 's/^/    /'; }
# Earned classes. Root-level signature files only, anchored to the APK root.
c_sign=$(printf '%s\n' "$raw" | grep -cE '(: |/tmp/[ob]/)META-INF/[^/ ]+\.(SF|RSA|DSA|EC)( |$)|(: |/tmp/[ob]/)META-INF/MANIFEST\.MF( |$)')
c_stamp=$(grep -cx 'Only in /tmp/o: stamp-cert-sha256' <<<"$raw"); c_mani=$(grep -c '^Files /tmp/o/AndroidManifest\.xml ' <<<"$raw"); c_arsc=$(grep -c '^Files /tmp/o/resources\.arsc ' <<<"$raw")
a_sign=$c_sign; a_stamp=0; a_mani=0; a_arsc=0
[[ $c_sign -gt 0 ]] && echo "      signing: ${c_sign} root META-INF signature entr(ies) - vendor key vs our throwaway key"
if [[ $c_stamp -gt 0 ]]; then
  if [[ ! -e /tmp/b/stamp-cert-sha256 && "$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null)" == "32" ]] && grep -q 'Verified for SourceStamp: true' <<<"$("$BT/apksigner" verify --verbose "$o" 2>/dev/null)"; then
    a_stamp=$c_stamp; echo "      stamp: official-only 32-byte stamp-cert-sha256, apksigner SourceStamp OK (Play injects it)"
  else echo "      stamp: NOT EARNED -> material"; fi
fi
if [[ $c_mani -gt 0 ]]; then
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null && "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null \
    && [[ -s /tmp/mo.txt && -s /tmp/mb.txt ]] || { echo "      manifest: NOT EARNED (aapt2 dump failed) -> material"; : > /tmp/mo.txt; echo x > /tmp/mb.txt; }
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"; printf '%s\n' "$d" > "$out/diff_manifest_${tag}.txt"
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  bad="$(printf '%s\n' "$left" | grep -vE '^E: meta-data|android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id)"|android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK)"|android:value\(0x[0-9a-f]+\)=[0-9]+$')"
  if printf '%s\n' "$d" | grep -q '^>' || [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: NOT EARNED -> material (diff_manifest_${tag}.txt):"; printf '%s\n' "$d" | grep -E '^[<>]' | head -3 | cut -c1-200 | sed 's/^/        /'
  else a_mani=$c_mani; echo "      manifest: only Play distribution meta-data, official-only ($(printf '%s\n' "$left" | grep -c '^E: meta-data') block(s))"; fi
fi
if [[ $c_arsc -gt 0 ]]; then
  if rm -rf /tmp/do /tmp/db && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/do "$o" >/dev/null 2>&1 \
     && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/db "$b" >/dev/null 2>&1 && [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
    rd="$(diff -r /tmp/do/res /tmp/db/res)"; rdrc=$?; printf '%s\n' "$rd" > "$out/diff_resources_decoded_${tag}.txt"
    left="$(printf '%s\n' "$rd" | grep -E '^[<>]' | grep -v 'com\.google\.firebase\.crashlytics\.mapping_file_id')"
    if (( rdrc == 0 )); then a_arsc=$c_arsc; echo "      arsc: apktool-decoded res/ IDENTICAL (binary packing artifact)"
    elif (( rdrc > 1 )); then echo "      arsc: NOT EARNED (decoded diff failed, rc $rdrc) -> material"
    elif [[ -z "$left" ]] && ! grep -qE '^(Only in|Files)' <<<"$rd"; then a_arsc=$c_arsc; echo "      arsc: decoded res/ differs only in crashlytics mapping_file_id (build-time id)"
    else echo "      arsc: decoded res/ differs -> material:"; printf '%s\n' "$rd" | grep -E '^(<|>|Only)' | head -2 | cut -c1-200 | sed 's/^/        /'; fi
  else echo "      arsc: NOT EARNED (apktool decode failed) -> material"; fi
fi
printf '%s\n' "$raw" | grep -q 'baseline\.prof' && echo "      baseline.prof: never auto-accepted (embeds dex checksums) -> material"
printf '%s\n' "$raw" | grep -q 'sentry-debug-meta\.properties' && echo "      sentry-debug-meta.properties: random ProguardUuid per build (Sentry Gradle plugin) -> material, no policy exception"
acc=$((a_sign+a_stamp+a_mani+a_arsc)); un=$((n-acc)); [[ $un -lt 0 ]] && un=0
echo "TOTALS ${n} ${acc} ${un}" > "$out/summary_${tag}.txt"
echo "  raw ${n}, accepted ${acc}, unaccounted ${un}  (full list: diff_${tag}.txt)"
printf '%s\n' "$raw" | grep -v '^$' | head -5 | cut -c1-200 | sed 's/^/    /'
CMP_END
tot_raw=0; tot_acc=0; tot_un=0; pair_notes=""; files_lines=""
for p in "${PAIRS[@]}"; do
  o="${p%%|*}"; b="${p#*|}"; ptag="$(basename "$o" .apk)"
  section "Comparing $(basename "$o") <-> $( [[ -n "$b" ]] && basename "$b" || echo '<no counterpart>' )"
  if [[ -z "$b" || ! -f "$b" ]]; then
    tot_un=$((tot_un+1)); tot_raw=$((tot_raw+1)); pair_notes+="${ptag}: no built counterpart (1 unaccounted); "
    files_lines+="$(basename "$o") - ${ptag} - none - 0 (DOESN'T MATCH)"$'\n'; continue
  fi
  crun -v "${o}:/official.apk:ro" -v "${b}:/built.apk:ro" -v "${CMP}:/out" -v "${CTX}/compare.sh:/compare.sh:ro" \
    "$IMG" bash /compare.sh "$ptag" 2>&1 | tee -a "${CMP}/comparison.log"
  read -r _ r a u < "${CMP}/summary_${ptag}.txt" 2>/dev/null || fail 1 "Comparison stage failed for ${ptag}. Official ${main} SHA-256 ${app_hash}."
  tot_raw=$((tot_raw+r)); tot_acc=$((tot_acc+a)); tot_un=$((tot_un+u)); pair_notes+="${ptag}: raw ${r}, accepted ${a}, unaccounted ${u}; "
  files_lines+="$(basename "$o") - ${ptag} - $(sha256of "$b") - $([[ "$u" -eq 0 ]] && echo '1 (MATCHES)' || echo "0 (DOESN'T MATCH)")"$'\n'
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
tagnote="tag ${tag} = ${tag_commit}"; [[ "$tag_commit" != "$commit" ]] && tagnote+=" (NOT the built commit)"
dot_note="${dotenv_arg:+supplied via --dotenv}"; dot_note="${dot_note:-absent}"
gradle_task="assembleProdRelease"; [[ "$MODE" == splits ]] && gradle_task="bundleProdRelease"
generate_yaml "$verdict" "${APP_ID} ${vname} (versionCode ${vcode}; ${MODE}) built from ${commit} (${rev_source}); ${tagnote}.
Upstream CI steps (set-build-version ${vcode}, yarn install, setup:github-ci, build:android:main:prod -> ${gradle_task}).
Private production secrets: ${dot_note}; google-services.json, Braze, Branch, Expo project id and build paths recovered from the official APK.
Official ${main} SHA-256 ${app_hash}, signer ${signer:-unknown}.
${pair_notes}
Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}."
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
echo "scriptHash:     ${SCRIPT_HASH:-unknown}"
echo ""
echo "Diff:"
echo "${head_line}"
printf '%s' "$files_lines"
echo "Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}"
echo ""
echo "Revision, tag (and its signature):"
echo "Built: ${commit} (${rev_source})"
echo "Tag ${tag}: $([[ "$tag_type" == commit ]] && echo 'lightweight tag' || echo "${tag_type:-?} object") -> ${tag_commit}"
echo "Signature verification: not implemented"
echo "Release inputs: production secrets ${dot_note}; versionCode ${vcode}; Firebase/Braze/Branch/Expo values and build paths from ${main}"
echo "===== End Results ====="
echo ""; echo "Exit code: ${rc}"
exit "$rc"
