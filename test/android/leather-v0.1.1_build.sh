#!/usr/bin/env bash
# ==============================================================================
# leather_build.sh - Leather (Android) Reproducible Build Verification
# ==============================================================================
# Version:          v0.1.1
# Organization:     WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-09-23
# App ID:           io.leather.mobilewallet
# Project:          https://github.com/leather-io/mono (apps/mobile)
# Play Store:       https://play.google.com/store/apps/details?id=io.leather.mobilewallet
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include a changelog in this header.
# Changelog: ~/work/ws-notes/script-notes/android/io.leather.mobilewallet/changelog.md
# Findings:  ~/work/ws-notes/build-notes/android/io.leather.mobilewallet/findings.md
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
# Leather ships Android only through Google Play (an app bundle rendered into base.apk +
# split_config.*.apk); GitHub releases carry no APK. --binary must be the directory of Play splits.
# Upstream builds with .github/workflows/mobile:deploy-production.yml, dispatched by hand on branch
# `dev` (not on the tag), on ubuntu-latest. The source revision defaults to the commit of the newest
# SUCCESSFUL public run of that workflow whose apps/mobile/app.config.ts declares the version
# (falling back to tag @leather.io/mobile-v<version>); --commit overrides. The tag difference is printed.
# Build, as the workflow: pnpm install --ignore-scripts, panda-preset, pnpm -w build:mobile,
# expo prebuild --clean, versionCode from the official APK (upstream reads Play's internal track + 1),
# ./gradlew bundleRelease -PunsignedRelease=true. MOBILE_DOTENV (a private repository variable holding
# EXPO_PUBLIC_* values that Expo inlines into the JS bundle) is not public: pass --dotenv FILE with the
# values, else the build runs without them. The AAB is rendered with bundletool from a device-spec
# derived from the official split names and every split is compared; each accepted difference must be
# earned by a named check. COMPARISON_RESULTS.yaml on every exit.
#
# Exit codes: 0 = reproducible, 1 = differences or build failure, 2 = invalid parameters.
# ==============================================================================

SCRIPT_VERSION="v0.1.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "$(basename "$SCRIPT_PATH") $SCRIPT_VERSION sha256:${SCRIPT_HASH:-unknown}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

APP_ID="io.leather.mobilewallet"
REPO_URL="https://github.com/leather-io/mono"
RUNS_API="https://api.github.com/repos/leather-io/mono/actions/workflows/mobile:deploy-production.yml/runs?status=success&per_page=50"
TAG_PREFIX="@leather.io/mobile-v"
CI_HOME="/home/runner"; CI_PATH="/home/runner/work/mono/mono"
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
fail() { generate_yaml ftbfs "$2"; echo ""; echo "Exit code: $1"; exit "$1"; }
die_invalid() { log_error "$1"; fail 2 "Invalid invocation: $1"; }
require_arg() { [[ -z "${2:-}" || "${2:-}" == --* ]] && die_invalid "$1 requires a value"; }

usage() {
  cat <<USAGE
Usage: $(basename "$SCRIPT_PATH") --binary <dir-of-Play-splits> [--version <v>] [--commit <ref>] [--dotenv <file>]

 --binary, --apk  Directory of Play splits (base.apk + split_config.*.apk). Required: Leather
                  publishes no downloadable APK.
 --version        App version (e.g. 2.111.0); default: base.apk's versionName.
 --commit         Build this commit instead of the resolved release-run commit / tag.
 --dotenv         File with the EXPO_PUBLIC_* values upstream's CI writes to apps/mobile/.env.
 --arch, --type   Accepted and ignored (the device-spec comes from the split names).
 WS_DEVICE_SDK    env: override the device-spec API level (default: base.apk minSdkVersion).
 GITHUB_TOKEN     env: optional, for the GitHub API (release-run lookup).

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
    -h|--help)      usage; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || die_invalid "Invalid --version '${version_arg}'"
[[ -z "$commit_arg" || "$commit_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_invalid "--commit must be 7-40 hex characters"
if [[ -n "$dotenv_arg" ]]; then [[ -f "$dotenv_arg" ]] || die_invalid "--dotenv file not found: ${dotenv_arg}"; dotenv_arg="$(readlink -f "$dotenv_arg")"; fi
if [[ -z "$binary_arg" ]]; then
  usage; die_invalid "--binary is required: Leather ships Android only through Google Play (no downloadable APK); pass the directory of Play splits"
fi

# Official artifact set: base.apk + split_config.*.apk; pairing key = each APK's split= attribute.
declare -a OFFICIAL=()
[[ -d "$binary_arg" ]] || die_invalid "--binary must be the directory of Play splits: ${binary_arg}"
OFFICIAL_DIR="$(readlink -f "$binary_arg")"
[[ -f "${OFFICIAL_DIR}/base.apk" ]] || die_invalid "--binary directory has no base.apk: ${OFFICIAL_DIR}"
OFFICIAL+=("${OFFICIAL_DIR}/base.apk")
while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$OFFICIAL_DIR" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
n_other="$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' ! -name base.apk ! -name 'split_config.*.apk' | wc -l)"
[[ "$n_other" -eq 0 ]] || die_invalid "Unexpected APK(s) in the split directory (only base.apk and split_config.*.apk are allowed)"
[[ ${#OFFICIAL[@]} -gt 1 ]] || die_invalid "No split_config.*.apk next to base.apk"

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v podman &>/dev/null; then CONTAINER_CMD=podman
  elif command -v docker &>/dev/null; then CONTAINER_CMD=docker
  else die_invalid "Neither podman nor docker found in PATH (the only host requirement)"; fi
fi
if [[ "$CONTAINER_CMD" == *podman* ]]; then RUN_USER=(--userns=keep-id -e "HOME=${CI_HOME}"); OWNER="0:0"
else RUN_USER=(--user "${HOST_UID}:${HOST_GID}" -e "HOME=${CI_HOME}"); OWNER="${HOST_UID}:${HOST_GID}"; fi
MEM_LIMIT="${MEM_LIMIT-24g}"; MEM_ARGS=(); [[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")
crun() { $CONTAINER_CMD run --rm "${RUN_USER[@]}" "${MEM_ARGS[@]}" "$@"; }

RUN_ID="leather-${version_arg:-bin}-$(date +%s)-$$"
IMG="ws-leather-${RUN_ID}"
WS="$(pwd -P)/leather_verification_${RUN_ID}"
META="${WS}/metadata"; BLD="${WS}/built"; CMP="${WS}/comparison"; CTX="${WS}/ctx"
mkdir -p "$META" "$BLD" "$CMP" "$CTX" || die_invalid "Cannot create workspace ${WS}"
NET=""
cleanup() {
  if $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1; then
    # Rootless podman: container root is the caller, so 0:0; rootful docker: the caller's ids.
    $CONTAINER_CMD run --rm -v "${WS}:/t" "$IMG" chown -R "$OWNER" /t >/dev/null 2>&1
    $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1
  fi
  [[ -n "$NET" ]] && $CONTAINER_CMD network rm -f "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

cat <<EOF

==============================================================
  LEATHER - ANDROID VERIFICATION
==============================================================
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL} (apps/mobile)
 Official:  ${#OFFICIAL[@]} Play split(s) from ${OFFICIAL_DIR}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${WS}
EOF

phase "SETUP: BUILD CONTAINER IMAGE"
# Node 22: the workflow's setup-node asks for major "22" only (root engines: >=22.15.0); this pins the
# 22.x current at writing, recorded in the log. Temurin 17 = the workflow's setup-java. SDK 36,
# build-tools 35/36, NDK 27.1.12297006, CMake 3.22.1 = Expo SDK 54 / RN 0.81 template; the SDK is
# writable so AGP can fetch any other pinned component, and the log lists what got installed.
cat > "${CTX}/Dockerfile" <<DOCKERFILE_END
FROM docker.io/library/node:22.23.2-bookworm@sha256:dd5847a04b0deee391fa145f1f4c6d214196668b6bcc7988ebed67249f226844
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends git unzip zip curl ca-certificates binutils \\
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
    "build-tools;35.0.0" "platform-tools" "ndk;27.1.12297006" "cmake;3.22.1" >/dev/null && chmod -R a+rwX \$ANDROID_HOME
RUN cd /opt && curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar \\
  && echo "${APKTOOL_SHA256}  apktool.jar" | sha256sum -c - \\
  && curl -fsSL -o bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar \\
  && echo "${BUNDLETOOL_SHA256}  bundletool.jar" | sha256sum -c - && chmod 0644 apktool.jar bundletool.jar
RUN corepack enable && mkdir -p /home/runner/work /tmp/afw && chmod 0777 /home/runner /home/runner/work /tmp/afw
WORKDIR /home/runner/work
DOCKERFILE_END
$CONTAINER_CMD build -t "$IMG" -f "${CTX}/Dockerfile" "$CTX" || fail 1 "Container image build failed; no comparison was performed."
log_success "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL ARTIFACT METADATA"
cat > "${CTX}/meta.sh" <<'META_END'
#!/bin/bash
BT="$ANDROID_HOME/build-tools/36.0.0"
for A in /official/*.apk; do
  i="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"; p="$(printf '%s\n' "$i" | grep '^package:')"
  g() { printf '%s\n' "$p" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
  pkg="$(printf '%s\n' "$p" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  abis="$(printf '%s\n' "$i" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
  minsdk="$(printf '%s\n' "$i" | sed -n "s/^\(minSdkVersion\|sdkVersion\):'\([0-9]*\)'.*/\2/p" | head -1)"
  sv="$("$BT/apksigner" verify --verbose --print-certs "$A" 2>/dev/null)"
  signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/{print $NF; exit}')"
  stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
  devip="$("$BT/aapt2" dump resources "$A" 2>/dev/null | grep -A1 'string/react_native_dev_server_ip' | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)"
  agp="$(unzip -p "$A" META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null | sed -n 's/^androidGradlePluginVersion=//p')"
  echo "$(basename "$A")|${pkg}|$(g versionName)|$(g versionCode)|$(g split)|${abis}|${minsdk}|${signer}|${stamp}|${devip}|${agp}" >> /m/apks.txt
  echo "[META] $(basename "$A"): ${pkg} $(g versionName) ($(g versionCode)) split '$(g split)' abis ${abis:-none} minSdk ${minsdk} SourceStamp ${stamp} AGP ${agp:-?} devIP ${devip:-none}"
  echo "[META]   signer ${signer:-?}"
done
META_END
: > "${META}/apks.txt"
crun -v "${OFFICIAL_DIR}:/official:ro" -v "${META}:/m" -v "${CTX}/meta.sh:/meta.sh:ro" "$IMG" bash /meta.sh \
  || fail 1 "Could not read metadata from the official APKs."
main="base.apk"
IFS='|' read -r _ pkg vname vcode main_split _ min_sdk signer _ dev_ip agp <<<"$(grep "^${main}|" "${META}/apks.txt" | head -1)"
[[ "$(awk -F'|' '$2 != "'"$APP_ID"'"' "${META}/apks.txt" | wc -l)" -eq 0 && -n "$pkg" ]] || die_invalid "Not every official APK is ${APP_ID} (see [META] lines)"
[[ -z "$main_split" ]] || die_invalid "base.apk declares split '${main_split}'"
[[ -n "$vname" && "$vcode" =~ ^[0-9]+$ ]] || fail 1 "Could not read versionName/versionCode from base.apk."
app_hash="$(sha256of "${OFFICIAL[0]}")"
if [[ -z "$version_arg" ]]; then version_arg="$vname"
elif [[ "$version_arg" != "$vname" ]]; then log_warn "--version ${version_arg} but base.apk says ${vname}; building ${version_arg}"; fi
log_success "${APP_ID} ${vname} (versionCode ${vcode})"
log_info "base.apk SHA-256 ${app_hash}; signer ${signer:-?}; AGP ${agp:-?}"

phase "PHASE 1: BUILD FROM SOURCE (${version_arg})"
cat > "${CTX}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
V="$1"; REPO="$2"; CIP="$3"; VCODE="$4"; WANT="$5"; TAG="${TAG_PREFIX}${V}"
git config --global --add safe.directory '*'
git clone -q --filter=blob:none "$REPO" "$CIP" || { echo "FATAL: clone failed"; exit 1; }
cd "$CIP" || exit 1
tagc="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}")"
cfgv() { git show "$1:apps/mobile/app.config.ts" 2>/dev/null | sed -n "s/^const version = '\([^']*\)'.*/\1/p"; }
src=""
if [[ -n "$WANT" ]]; then
  c="$(git rev-parse -q --verify "${WANT}^{commit}")" || { git fetch -q origin "$WANT" 2>/dev/null; c="$(git rev-parse -q --verify "${WANT}^{commit}")"; }
  [[ -n "$c" ]] || { echo "FATAL: --commit ${WANT} is not in ${REPO}"; exit 4; }
  src="--commit"
else
  # Upstream releases by dispatching the production workflow on `dev`: take the newest successful
  # public run whose commit declares this version.
  A=(); [[ -n "${GITHUB_TOKEN:-}" ]] && A=(-H "Authorization: Bearer $GITHUB_TOKEN")
  [[ -n "${GITHUB_TOKEN:-}" ]] || echo "  WARNING: no GITHUB_TOKEN: the anonymous runs API can return a stale list (seen 2026-09-23: newest run missing)"
  curl -fsSL "${A[@]}" "$RUNS_API" > /out/runs.json 2>/dev/null
  # A run list older than the tag cannot hold the tag's release run: say so instead of quietly using the tag.
  newest="$(node -e 'const r=(require("/out/runs.json").workflow_runs||[])[0]; console.log(r ? Math.floor(Date.parse(r.created_at)/1000) : 0)' 2>/dev/null)"
  stale=""
  if [[ -n "$tagc" && "${newest:-0}" -lt "$(git show -s --format=%ct "$tagc")" ]]; then
    stale="release-run lookup inconclusive: newest run returned predates the tag (stale list, or no release run since the tag); pass --commit or GITHUB_TOKEN"
    echo "  WARNING: ${stale}"
  fi
  c=""
  for s in $(node -e 'for (const r of (require("/out/runs.json").workflow_runs||[])) console.log(r.head_sha)' 2>/dev/null); do
    git cat-file -e "$s" 2>/dev/null || git fetch -q origin "$s" 2>/dev/null
    [[ "$(cfgv "$s")" == "$V" ]] && { c="$s"; break; }
  done
  if [[ -n "$c" ]]; then src="newest successful mobile:deploy-production run declaring ${V}"
  elif [[ -n "$tagc" ]]; then c="$tagc"; src="tag ${TAG} (${stale:-no successful release run found for ${V}})"
  else echo "FATAL: neither a release run nor tag ${TAG} declares ${V}"; exit 4; fi
fi
git checkout -q "$c" || exit 2
{ echo "COMMIT=$(git rev-parse HEAD)"; echo "TAG_COMMIT=${tagc:-none}"; echo "TAG_TYPE=$(git cat-file -t "refs/tags/${TAG}" 2>/dev/null || echo none)"
  echo "SOURCE=${src}"; echo "CFG_VERSION=$(cfgv HEAD)"; } > /out/src.env
git log -1 --format='  built: %H %ci %s'; echo "  source: ${src}"
echo "  tag ${TAG}: ${tagc:-<missing>}"
if [[ -n "$tagc" && "$tagc" != "$(git rev-parse HEAD)" ]]; then
  echo "  tag..built: $(git rev-list --count "${tagc}..HEAD") commit(s) ahead, $(git rev-list --count "HEAD..${tagc}") behind; files under apps/mobile or packages changed:"
  git diff --stat "$tagc" HEAD -- apps/mobile packages | tail -12 | sed 's/^/    /'
fi
[[ "$(cfgv HEAD)" == "$V" ]] || echo "  WARNING: app.config.ts declares $(cfgv HEAD), not ${V}"

export CI=true PROVISION_MOBILE=true SENTRY_DISABLE_AUTO_UPLOAD=true COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# Gradle takes user.home from the passwd entry, not $HOME; under podman --userns=keep-id that put its cache in
# /home/runner/work/.gradle, and CMake embeds the cache path in native libs. Upstream's is /home/runner/.gradle.
export GRADLE_USER_HOME="${HOME}/.gradle"
echo "  node $(node --version), $(java -version 2>&1 | head -1)"
echo "=== pnpm install --ignore-scripts === $(date)"
pnpm install --ignore-scripts > /out/pnpm-install.log 2>&1 || { tail -30 /out/pnpm-install.log; echo "FATAL: pnpm install failed"; exit 3; }
echo "  pnpm $(pnpm --version)"
run() { echo "=== $1 === $(date)"; shift; "$@" > "/out/step.log" 2>&1 || { tail -30 /out/step.log; echo "FATAL: step failed"; exit 3; }; cat /out/step.log >> /out/build.log; }
run "build panda-preset" pnpm turbo run build --filter="@leather.io/panda-preset"
run "pnpm -w build:mobile" pnpm -w build:mobile
cd apps/mobile || exit 1
# MOBILE_DOTENV: upstream's fastlane writes it to apps/mobile/.env; EXPO_PUBLIC_* values end up in the bundle.
if [[ -f /dotenv ]]; then cp /dotenv .env; echo "  .env from --dotenv: $(grep -c '=' .env) entries ($(cut -d= -f1 .env | paste -sd' ' -))"
else echo "  WARNING: no --dotenv: EXPO_PUBLIC_* values from upstream's private MOBILE_DOTENV are absent"; fi
run "expo prebuild --clean" pnpm prebuild
# fastlane build_android_aab: versionCode = Play internal max + 1 (read here from the official APK).
sed -i -E "s/^([[:space:]]+)versionCode [0-9]+$/\1versionCode ${VCODE}/" android/app/build.gradle
grep -qE "versionCode ${VCODE}$" android/app/build.gradle || { echo "FATAL: versionCode injection failed"; exit 3; }
echo "  host IPv4 (React Native writes it into react_native_dev_server_ip): $(hostname -I 2>/dev/null | awk '{print $1}')"
cd android || exit 1
run "gradle bundleRelease -PunsignedRelease=true" ./gradlew bundleRelease -PunsignedRelease=true --no-daemon
cp app/build/outputs/bundle/release/app-release.aab /out/ || { echo "FATAL: no app-release.aab"; exit 3; }
echo "  $(sha256sum /out/app-release.aab | cut -c1-64)  app-release.aab"
echo "  SDK components after the build: $(cd "$ANDROID_HOME" && ls -d build-tools/* platforms/* ndk/* cmake/* 2>/dev/null | paste -sd' ' -)"
echo "=== build complete $(date) ==="
BUILD_END
# RN 0.81 writes the build host's first IPv4 into react_native_dev_server_ip; the build container gets
# the official value on a per-run network when it is a private address.
NET_ARGS=()
if [[ "$dev_ip" =~ ^(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+$ && "${dev_ip##*.}" != 1 ]]; then
  NET="ws-leather-net-$$"
  if $CONTAINER_CMD network create --subnet "${dev_ip%.*}.0/24" "$NET" >/dev/null 2>&1; then NET_ARGS=(--network "$NET" --ip "$dev_ip")
  else log_warn "Could not create a ${dev_ip%.*}.0/24 network; react_native_dev_server_ip will hold this container's address"; NET=""; fi
fi
DOT_ARGS=(); [[ -n "$dotenv_arg" ]] && DOT_ARGS=(-v "${dotenv_arg}:/dotenv:ro")
log_info "Release inputs: versionCode ${vcode} and build host IPv4 ${dev_ip:-<none>}${NET:+ (network ${NET})} from base.apk; .env ${dotenv_arg:-<none>}"
log_info "Container build (typically 30-90 min)"
crun "${NET_ARGS[@]}" "${DOT_ARGS[@]}" -e "GITHUB_TOKEN=${GITHUB_TOKEN:-}" -e "RUNS_API=${RUNS_API}" -e "TAG_PREFIX=${TAG_PREFIX}" \
  -v "${BLD}:/out" -v "${CTX}/build.sh:/build.sh:ro" "$IMG" \
  bash /build.sh "$version_arg" "$REPO_URL" "$CI_PATH" "$vcode" "$commit_arg" 2>&1 | tee "${BLD}/container.log"
BRC=${PIPESTATUS[0]}
if [[ $BRC -ne 0 ]]; then
  [[ $BRC -eq 4 ]] && fail 1 "No source revision for ${version_arg} (see container.log); nothing was built. Official base.apk SHA-256 ${app_hash}."
  fail 1 "Source build failed (container exit ${BRC}: 1 clone, 2 checkout, 3 install/build). Official base.apk SHA-256 ${app_hash}."
fi
envv() { sed -n "s/^$1=//p" "${BLD}/src.env"; }
commit="$(envv COMMIT)"; tag_commit="$(envv TAG_COMMIT)"; tag_type="$(envv TAG_TYPE)"; rev_source="$(envv SOURCE)"

declare -a PAIRS=()   # "official-path|built-path"
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
# bundletool writes each variant's lower SDK bound into its APKs' minSdkVersion, so the official
# base.apk's minSdkVersion selects the same variant Play delivered.
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
# Pair by split= attribute: device files are split_config.X.apk, bundletool's are base-X.apk.
crun -v "${OFFICIAL_DIR}:/official:ro" -v "${BLD}:/out" "$IMG" bash -c '
  BT=$ANDROID_HOME/build-tools/36.0.0
  cfg() { s=$("$BT/aapt2" dump badging "$1" 2>/dev/null | grep "^package:" | sed -n "s/.*split=.\([^\x27]*\).*/\1/p"); echo "${s#config.}"; }
  for o in /official/base.apk /official/split_config.*.apk; do co=$(cfg "$o"); m=""
    for b in /out/rendered/splits/*.apk; do [[ "$(cfg "$b")" == "$co" ]] && { m="$b"; break; }; done
    echo "$(basename "$o")|${co:-base}|${m:+rendered/splits/$(basename "$m")}"; done
  for b in /out/rendered/splits/*.apk; do echo "#rendered $(basename "$b") split=$(cfg "$b")"; done' > "${BLD}/pairs.txt" 2>/dev/null
prc=$?
[[ $prc -eq 0 && "$(grep -vc '^#' "${BLD}/pairs.txt")" -eq ${#OFFICIAL[@]} ]] || fail 1 "Pairing official and rendered splits failed (exit ${prc}). Official ${main} SHA-256 ${app_hash}."
while IFS='|' read -r o c b; do
  [[ "$o" == \#* ]] && continue
  if [[ -n "$b" ]]; then PAIRS+=("${OFFICIAL_DIR}/${o}|${BLD}/${b}"); echo "  ${o} (split '${c}') <-> ${b}"
  else log_warn "No rendered counterpart for ${o} (split '${c}') -> counted as a difference"; PAIRS+=("${OFFICIAL_DIR}/${o}|"); fi
done < "${BLD}/pairs.txt"
grep '^#rendered' "${BLD}/pairs.txt" | sed 's/^#rendered/  rendered:/'
# Every official APK must enter the comparison; an empty or short pair list never reads as reproducible.
[[ ${#PAIRS[@]} -eq ${#OFFICIAL[@]} && ${#PAIRS[@]} -gt 0 ]] || fail 1 "Only ${#PAIRS[@]} of ${#OFFICIAL[@]} official APK(s) paired."

phase "PHASE 2: COMPARISON"
# Every raw diff must be EARNED by a class with printed evidence: root signature files, Play
# SourceStamp, Play manifest meta-data, or an apktool-decoded-identical resources.arsc.
# Everything else (dex, JS bundle, source maps, native libs, assets, baseline.prof) is material.
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
# Native library evidence per differing .so (both sides): compiler stamp, Go version, build path.
: > "$out/native_${tag}.txt"; nso=0; nsm=0
while IFS= read -r so; do
  rel="${so#/tmp/o/}"; nso=$((nso+1))
  if [[ -f "/tmp/b/$rel" ]] && cmp -s "$so" "/tmp/b/$rel"; then nsm=$((nsm+1)); continue; fi
  for side in o b; do f="/tmp/$side/$rel"; [[ -f "$f" ]] || { echo "$rel [$side] MISSING" >> "$out/native_${tag}.txt"; continue; }
    cc="$(readelf -p .comment "$f" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -oE 'clang version [0-9.]+|Android \([^)]*\)' | head -2 | paste -sd' ' -)"
    gv="$(strings "$f" | grep -oE '^go1\.[0-9]+(\.[0-9]+)?' | head -1)"
    gp="$(strings "$f" | grep -oE '^/(opt/homebrew|Users|home|root|build|tmp)/[^ ]*' | head -1 | cut -c1-60)"
    echo "$rel [$side] $(stat -c%s "$f") B; ${cc:-no .comment}; ${gv:-no Go}; ${gp:-no build path}" >> "$out/native_${tag}.txt"; done
done < <(find /tmp/o -name '*.so' -type f | sort)
dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
js=""; for f in assets/index.android.bundle assets/index.android.bundle.map assets/index.android.bundle.hbc.map; do
  [[ -f /tmp/o/$f ]] && js+="$(basename "$f") $(cmp -s /tmp/o/$f /tmp/b/$f && echo same || echo DIFFERS); "; done
echo "  native libs ${nsm}/${nso} identical; dex differing: ${dx:-none}; JS: ${js:-none in this APK}"
[[ -s "$out/native_${tag}.txt" ]] && { echo "  native evidence (full: native_${tag}.txt):"; head -4 "$out/native_${tag}.txt" | cut -c1-200 | sed 's/^/    /'; }
# Earned classes. Root-level signature files only, anchored to the APK root.
c_sign=$(printf '%s\n' "$raw" | grep -cE '(: |/tmp/[ob]/)META-INF/[^/ ]+\.(SF|RSA|DSA|EC)( |$)|(: |/tmp/[ob]/)META-INF/MANIFEST\.MF( |$)')
c_stamp=$(grep -cx 'Only in /tmp/o: stamp-cert-sha256' <<<"$raw"); c_mani=$(grep -c '^Files /tmp/o/AndroidManifest\.xml ' <<<"$raw"); c_arsc=$(grep -c '^Files /tmp/o/resources\.arsc ' <<<"$raw")
a_sign=$c_sign; a_stamp=0; a_mani=0; a_arsc=0
[[ $c_sign -gt 0 ]] && echo "      signing: ${c_sign} root META-INF signature entr(ies) - vendor key vs our unsigned/throwaway build"
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
    echo "      manifest: NOT EARNED -> material (diff_manifest_${tag}.txt):"; printf '%s\n' "$d" | grep -E '^[<>]' | head -3 | sed 's/^/        /'
  else a_mani=$c_mani; echo "      manifest: only Play distribution meta-data, official-only ($(printf '%s\n' "$left" | grep -c '^E: meta-data') block(s))"; fi
fi
if [[ $c_arsc -gt 0 ]]; then
  if rm -rf /tmp/do /tmp/db && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/do "$o" >/dev/null 2>&1 \
     && $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/db "$b" >/dev/null 2>&1 && [[ -d /tmp/do/res && -d /tmp/db/res ]]; then
    rd="$(diff -r /tmp/do/res /tmp/db/res)"; rdrc=$?; printf '%s\n' "$rd" > "$out/diff_resources_decoded_${tag}.txt"
    if (( rdrc == 0 )); then a_arsc=$c_arsc; echo "      arsc: apktool-decoded res/ IDENTICAL (binary packing artifact)"
    elif (( rdrc > 1 )); then echo "      arsc: NOT EARNED (decoded diff failed, rc $rdrc) -> material"
    else echo "      arsc: decoded res/ differs -> material:"; printf '%s\n' "$rd" | head -2 | sed 's/^/        /'; fi
  else echo "      arsc: NOT EARNED (apktool decode failed) -> material"; fi
fi
printf '%s\n' "$raw" | grep -q 'baseline\.prof' && echo "      baseline.prof: never auto-accepted (embeds dex checksums) -> material"
acc=$((a_sign+a_stamp+a_mani+a_arsc)); un=$((n-acc)); [[ $un -lt 0 ]] && un=0
echo "TOTALS ${n} ${acc} ${un}" > "$out/summary_${tag}.txt"
echo "  raw ${n}, accepted ${acc}, unaccounted ${un}  (full list: diff_${tag}.txt)"
printf '%s\n' "$raw" | grep -v '^$' | head -5 | cut -c1-200 | sed 's/^/    /'
CMP_END
tot_raw=0; tot_acc=0; tot_un=0; pair_notes=""; files_lines=""
for p in "${PAIRS[@]}"; do
  o="${p%%|*}"; b="${p#*|}"; tag="$(basename "$o" .apk)"
  section "Comparing $(basename "$o") <-> $( [[ -n "$b" ]] && basename "$b" || echo '<no counterpart>' )"
  if [[ -z "$b" || ! -f "$b" ]]; then
    tot_un=$((tot_un+1)); tot_raw=$((tot_raw+1)); pair_notes+="${tag}: no built counterpart (1 unaccounted); "
    files_lines+="$(basename "$o") - ${tag} - none - 0 (DOESN'T MATCH)"$'\n'; continue
  fi
  crun -v "${o}:/official.apk:ro" -v "${b}:/built.apk:ro" -v "${CMP}:/out" -v "${CTX}/compare.sh:/compare.sh:ro" \
    "$IMG" bash /compare.sh "$tag" 2>&1 | tee -a "${CMP}/comparison.log"
  read -r _ r a u < "${CMP}/summary_${tag}.txt" 2>/dev/null || fail 1 "Comparison stage failed for ${tag}. Official ${main} SHA-256 ${app_hash}."
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
 Build logs:           ${rel_ws}/built/pnpm-install.log, build.log, container.log
EOF
if [[ "$tot_un" -eq 0 ]]; then verdict="reproducible"; rc=0; head_line="BUILDS MATCH BINARIES"
else verdict="not_reproducible"; rc=1; head_line="BUILDS DO NOT MATCH BINARIES"; fi
tagnote="tag ${TAG_PREFIX}${version_arg} = ${tag_commit}"; [[ "$tag_commit" != "$commit" ]] && tagnote+=" (NOT the built commit)"
generate_yaml "$verdict" "${APP_ID} ${vname} (versionCode ${vcode}; Play splits) built from ${commit} (${rev_source}); ${tagnote}.
Upstream mobile:deploy-production steps; versionCode and build-host IPv4 taken from the official base.apk; .env: ${dotenv_arg:+supplied via --dotenv}${dotenv_arg:-none (EXPO_PUBLIC_* values absent)}.
Official base.apk SHA-256 ${app_hash}, signer ${signer:-unknown}.
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
echo "Tag ${TAG_PREFIX}${version_arg}: $([[ "$tag_type" == commit ]] && echo 'lightweight tag' || echo "${tag_type:-?} object") -> ${tag_commit}"
echo "Signature verification: not implemented"
echo "Release inputs: versionCode ${vcode} + build host IPv4 ${dev_ip:-none} from base.apk; .env $([[ -n "$dotenv_arg" ]] && echo supplied || echo absent)"
echo "===== End Results ====="
echo ""; echo "Exit code: ${rc}"
exit "$rc"
