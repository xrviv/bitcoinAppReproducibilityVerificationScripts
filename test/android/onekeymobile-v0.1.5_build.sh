#!/usr/bin/env bash
# ==============================================================================
# onekeymobile-v0.1.5_build.sh - OneKey Wallet (Android) Reproducible Build Verification
# ==============================================================================
# Version:          v0.1.5
# Organization:     WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-11-09
# App ID:           so.onekey.app.wallet
# Project:          https://github.com/OneKeyHQ/app-monorepo
# Play Store:       https://play.google.com/store/apps/details?id=so.onekey.app.wallet
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include a changelog in this header.
# Changelog: ~/work/ws-notes/script-notes/android/so.onekey.app.wallet/changelog.md
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
# OneKey is a React Native (0.86) / Expo (57) monorepo, built on Expo's EAS cloud from the release
# workflow (.github/workflows/release-android.yml). Official artifacts:
#  - Google Play: base.apk + split_config.*.apk (pass the directory as --binary); eas.json profile
#    production-store, gradle :app:bundleGoogleRelease, ANDROID_CHANNEL=google, then bundletool.
#  - GitHub release APK OneKey-Wallet-<v>-android.apk (pass the file, or only --version to download it
#    and check it against the GPG-signed SHA256SUMS.asc with the key the repo ships); profile
#    production, gradle :app:assembleProdRelease, ANDROID_CHANNEL=direct.
# Source: tag v<versionName>. Build as EAS does: node 24.13.0 / JDK 17 / NDK 27.1.12297006, HOME=/home/expo,
# repo in /home/expo/workingdir/build, env from eas.json, yarn install --immutable, gradle. The values
# CI injects from secrets or the clock are copied from the official APK, so a match proves nothing
# about them: versionCode (BUILD_NUMBER), BUNDLE_VERSION and JPUSH_APPKEY (manifest), the React Native
# Sentry DSN (BuildConfig), the Firebase values google-services.json generates (resources), the web Sentry
# DSN and BUILD_TIME (web-embed JS), the two native BUILD_TIMEs (Hermes disassembly of common.bundle), the
# React Native dev-server IP (the CI machine's address, a resource) and the sentry-debug-meta.properties date.
# Every raw difference must be earned by a named check; everything else is material.
#
# Exit codes: 0 = reproducible, 1 = differences / build failure / other failure, 2 = invalid parameters.
# ==============================================================================

SCRIPT_VERSION="v0.1.5"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "$(basename "$SCRIPT_PATH") $SCRIPT_VERSION sha256:${SCRIPT_HASH:-N/A}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

APP_ID="so.onekey.app.wallet"
REPO_URL="https://github.com/OneKeyHQ/app-monorepo"
GH_SIGNER="f5cc38b706a5c1d6f094785dfdf58e093ce3314e35a7f35b2a79c1050c07e384"   # GitHub release APKs
GPG_FPR="EB68AE544F1FDD8CD264624FB369A67A90BF387B"   # dev@onekey.so, apps/desktop/app/constant/gpg.js
EAS_HOME="/home/expo"; EAS_PATH="/home/expo/workingdir/build"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
YAML="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
rm -f "$YAML"   # before any exit: a stale verdict must never be read as this run's
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
ENV_ERRORS='OutOfMemoryError|Metaspace|heap out of memory|ENOMEM|ENOSPC|No space left|EMFILE|ENFILE|[Tt]oo many open files|ETIMEDOUT|ECONNRESET|EAI_AGAIN|ENOTFOUND|Could not (resolve|download|GET|HEAD)|Connection (timed out|reset|refused)|Read timed out|Network is unreachable|daemon disappeared|exit code 137|Killed'
has_compile_error() {
  [[ -f "$1" ]] || return 1
  grep -qE "$ENV_ERRORS" "$1" && return 1
  grep -qE "$COMPILE_ERRORS" "$1"
}
require_arg() { [[ -z "${2:-}" || "${2:-}" == --* ]] && die_invalid "$1 requires a value"; }

usage() {
  cat <<USAGE
Usage: $(basename "$SCRIPT_PATH") [--binary <apk | dir-of-Play-splits>] [--version <v>]

 --binary, --apk  Official artifact: a directory of Play splits (base.apk + split_config.*.apk), or the
                  GitHub release APK. Without it, --version is required and the GitHub release APK for
                  that version is downloaded and checked against its GPG-signed SHA256SUMS.asc.
 --version        App version (e.g. 6.6.4); default: the APK's versionName.
 --arch           Checked against the official split set or APK (mismatch exits 2). --type: accepted, ignored.
 WS_DEVICE_SDK    env: device-spec API level for Play splits (default 36; use the SDK of the phone they came from).
 MEM_LIMIT        env: container memory limit (default 14g; empty = none).
 BUILD_CPUS       env: CPUs for the build container (default 6; Metro starts one worker per CPU, EAS uses 8 vCPU).

Exit codes: 0 = reproducible, 1 = not reproducible / ftbfs / failure, 2 = invalid parameters.
USAGE
}

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; arch_arg=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      require_arg "$1" "${2:-}"; version_arg="${2#v}"; shift 2 ;;
    --apk|--binary) require_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
    --arch)         require_arg "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
    --type)         require_arg "$1" "${2:-}"; log_info "--type $2 accepted, not used"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_invalid "Invalid --version '${version_arg}'"
[[ -n "$binary_arg" || -n "$version_arg" ]] || { usage; die_invalid "Pass --binary, or --version to download the GitHub release APK"; }

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
    MODE=single; OFFICIAL+=("$(readlink -f "$binary_arg")"); OFFICIAL_DIR="$(dirname "${OFFICIAL[0]}")"
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
# Rootless podman maps container root to the caller; docker runs as the caller.
if [[ "$CONTAINER_CMD" == *podman* ]]; then RUN_USER=(-e "HOME=${EAS_HOME}"); OWNER="0:0"
else RUN_USER=(--user "${HOST_UID}:${HOST_GID}" -e "HOME=${EAS_HOME}"); OWNER="${HOST_UID}:${HOST_GID}"; fi
MEM_LIMIT="${MEM_LIMIT-14g}"; MEM_ARGS=(); [[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")
crun() { $CONTAINER_CMD run --rm "${RUN_USER[@]}" "${MEM_ARGS[@]}" "$@"; }

RUN_ID="$(date +%s)-$$"
IMG="localhost/ws-onekeymobile-${RUN_ID}"
WS="$(pwd -P)/onekeymobile_verification_${version_arg:-apk}_${RUN_ID}"
mkdir "$WS" 2>/dev/null || die_invalid "Cannot create a fresh workspace ${WS}"
META="${WS}/metadata"; BLD="${WS}/built"; CMP="${WS}/comparison"; CTX="${WS}/ctx"; DL="${WS}/official"
mkdir -p "$META" "$BLD" "$CMP" "$CTX" || die_invalid "Cannot create workspace subdirectories in ${WS}"
BUILD_CTR="ws-onekeymobile-build-${RUN_ID}"
cleanup() {
  $CONTAINER_CMD rm -f "$BUILD_CTR" >/dev/null 2>&1
  if $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1; then
    $CONTAINER_CMD run --rm -v "${WS}:/t" "$IMG" chown -R "$OWNER" /t >/dev/null 2>&1
    $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1
  fi
  chmod -R u+rwX "$WS" 2>/dev/null
}
trap cleanup EXIT
trap 'echo ""; log_error "Interrupted (no verdict written)"; echo "Exit code: 130"; exit 130' INT TERM

cat <<EOF

==============================================================
  ONEKEY WALLET - ANDROID VERIFICATION
==============================================================
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Official:  ${MODE:-download the GitHub release APK} ${OFFICIAL_DIR}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${WS}
EOF

phase "SETUP: BUILD CONTAINER IMAGE"
# EAS image ubuntu-24.04-jdk-17-ndk-r27b (Bun 1.2.20, rsync) with eas.json's node 24.13.0, JDK 17, NDK r27b (27.1.12297006).
# Yarn comes from the repo (.yarn/releases/yarn-4.12.0.cjs).
cat > "${CTX}/Dockerfile" <<DOCKERFILE_END
FROM docker.io/library/node:24.13.0-bookworm@sha256:bbedd05c4f49b270ea04664d661fd894fe4ddaa6ebbb7757bcc5f12b0eda0085
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends git unzip zip curl ca-certificates binutils gnupg rsync \\
  && rm -rf /var/lib/apt/lists/*
# Bun as on the EAS image (react-native-video's postinstall runs it).
RUN cd /tmp && curl -fsSL -o bun.zip https://github.com/oven-sh/bun/releases/download/bun-v1.2.20/bun-linux-x64.zip \\
  && echo "4e9edc4cba0c7c1623a288be01e53bbde11a4d073f2cf339cab026627858b548  bun.zip" | sha256sum -c - \\
  && unzip -q bun.zip && install -m 0755 bun-linux-x64/bun /usr/local/bin/bun && rm -rf bun.zip bun-linux-x64
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
    "platform-tools" "ndk;27.1.12297006" "cmake;3.22.1" >/dev/null && chmod -R a+rwX \$ANDROID_HOME
RUN cd /opt && curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar \\
  && echo "${APKTOOL_SHA256}  apktool.jar" | sha256sum -c - \\
  && curl -fsSL -o bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar \\
  && echo "${BUNDLETOOL_SHA256}  bundletool.jar" | sha256sum -c - && chmod 0644 apktool.jar bundletool.jar
# hermes-dec (pure Python) disassembles the official Hermes bundle to read the inlined BUILD_TIME values.
RUN cd /tmp && curl -fsSL -o hd.whl https://files.pythonhosted.org/packages/79/46/4db716ac625ba3cf40c666fb83450c310b7c400e682ecc9b26b02eea0a32/hermes_dec-0.1.8-py3-none-any.whl \\
  && echo "6be7858a11edc3bc27d37abad65c80a36b51683283eed6331cd5c7d3fb399a4c  hd.whl" | sha256sum -c - && mkdir -p /opt/hd && unzip -q hd.whl -d /opt/hd && rm hd.whl
RUN mkdir -p ${EAS_HOME}/workingdir /tmp/afw && chmod 0777 ${EAS_HOME} ${EAS_HOME}/workingdir ${EAS_HOME}/Android /tmp/afw
WORKDIR ${EAS_HOME}/workingdir
DOCKERFILE_END
$CONTAINER_CMD build -t "$IMG" -f "${CTX}/Dockerfile" "$CTX" || abort "Container image build failed; nothing was compared"
log_success "Image built: ${IMG}"

if [[ -z "$MODE" ]]; then
  phase "DOWNLOAD: GITHUB RELEASE APK ${version_arg}"
  # The SHA256SUMS.asc is checked with the key from the repo at the release tag, pinned by fingerprint.
  cat > "${CTX}/dl.sh" <<'DL_END'
#!/bin/bash
V="$1"; FPR="$2"; U="https://github.com/OneKeyHQ/app-monorepo/releases/download/v${V}/OneKey-Wallet-${V}-android.apk"
cd /dl || exit 1
curl -fsSL -o key.js "https://raw.githubusercontent.com/OneKeyHQ/app-monorepo/v${V}/apps/desktop/app/constant/gpg.js" || { echo "no gpg.js at v${V}"; exit 1; }
curl -fsSL -o sums.asc "${U}.SHA256SUMS.asc" || { echo "no SHA256SUMS.asc for ${V}"; exit 4; }
curl -fsSL --retry 3 -o "OneKey-Wallet-${V}-android.apk" "$U" || { echo "APK download failed"; exit 1; }
export GNUPGHOME="$(mktemp -d)"
sed -n '/BEGIN PGP PUBLIC/,/END PGP PUBLIC/p' key.js | sed 's/^.*\(-----BEGIN\)/\1/; s/\(BLOCK-----\)`.*$/\1/' | gpg -q --import 2>/dev/null
gpg --status-fd 1 --verify sums.asc 2>/dev/null > gpg.txt
grep -q "^\[GNUPG:\] VALIDSIG ${FPR} " gpg.txt || { echo "SHA256SUMS.asc is not signed by ${FPR}"; exit 3; }
want="$(gpg --decrypt sums.asc 2>/dev/null | awk -v f="OneKey-Wallet-${V}-android.apk" '$2==f{print $1}')"
got="$(sha256sum "OneKey-Wallet-${V}-android.apk" | cut -c1-64)"
[[ -n "$want" && "$want" == "$got" ]] || { echo "sha256 ${got} is not the signed ${want:-<none>}"; exit 3; }
echo "OK ${got}"
DL_END
  mkdir -p "$DL"; dlo="$(crun -v "${DL}:/dl" -v "${CTX}/dl.sh:/dl.sh:ro" "$IMG" bash /dl.sh "$version_arg" "$GPG_FPR" 2>&1)"; drc=$?
  echo "  ${dlo}"
  [[ $drc -eq 4 ]] && die_invalid "No GitHub release APK for ${version_arg}; pass --binary"
  [[ $drc -eq 0 ]] || abort "GitHub release APK download or check failed"
  log_success "APK matches the SHA256SUMS.asc signed by ${GPG_FPR}"
  MODE=single; OFFICIAL=("${DL}/OneKey-Wallet-${version_arg}-android.apk"); OFFICIAL_DIR="$DL"
fi

phase "PHASE 0: OFFICIAL ARTIFACT METADATA (${MODE})"
# Also reads the injected values the build needs: manifest meta-data, BuildConfig's Sentry DSN, and
# the Firebase strings google-services.json generates (rebuilt into a google-services.json).
cat > "${CTX}/meta.sh" <<'META_END'
#!/bin/bash
BT="$ANDROID_HOME/build-tools/36.0.0"
mval() { "$BT/aapt2" dump xmltree --file AndroidManifest.xml "$1" 2>/dev/null | grep -A1 "android:name(0x01010003)=\"$2\"" | sed -n 's/.*android:value(0x01010024)=\(.*\)$/\1/p' | sed 's/ (Raw.*//; s/^"//; s/"$//' | head -1; }
for A in "$@"; do
  i="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"; p="$(printf '%s\n' "$i" | grep '^package:')"
  g() { printf '%s\n' "$p" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
  pkg="$(printf '%s\n' "$p" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  abis="$(printf '%s\n' "$i" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
  signer="$("$BT/apksigner" verify --print-certs "$A" 2>/dev/null | awk '/Signer #1 certificate SHA-256/{print $NF; exit}')"
  echo "$(basename "$A")|${pkg}|$(g versionName)|$(g versionCode)|$(g split)|${abis}|${signer}|$(mval "$A" BUNDLE_VERSION)|$(mval "$A" JPUSH_APPKEY)" >> /m/apks.txt
  echo "[META] $(basename "$A"): ${pkg} $(g versionName) ($(g versionCode)) split '$(g split)' abis ${abis:-none}"
  echo "[META]   signer ${signer:-?}"
done
A="$1"; rm -rf /tmp/x && mkdir /tmp/x && unzip -q -o "$A" 'classes*.dex' -d /tmp/x
for d in /tmp/x/classes*.dex; do
  "$BT/dexdump" -l plain "$d" 2>/dev/null | sed -n '/Class descriptor  : .Lso\/onekey\/app\/wallet\/BuildConfig;/,/Instance fields/p' \
    | grep -A3 "name          : 'SENTRY_DSN_REACT_NATIVE'" | sed -n 's/^ *value *: "\(.*\)"$/\1/p'
done | head -1 > /m/dsn.txt
r="$("$BT/aapt2" dump resources "$A" 2>/dev/null)"
s() { printf '%s\n' "$r" | grep -A1 " string/$1\$" | sed -n 's/^ *() "\(.*\)"$/\1/p' | head -1; }
P="$(s project_id)"; N="$(s gcm_defaultSenderId)"; K="$(s google_api_key)"; I="$(s google_app_id)"; S="$(s google_storage_bucket)"; W="$(s default_web_client_id)"; U="$(s firebase_database_url)"
[[ -n "$P" && -n "$N" && -n "$K" && -n "$I" ]] || exit 0
cat > /m/google-services.json <<GS
{
  "project_info": { "project_number": "$N", $([[ -n "$U" ]] && echo "\"firebase_url\": \"$U\",") "project_id": "$P", "storage_bucket": "$S" },
  "client": [ {
    "client_info": { "mobilesdk_app_id": "$I", "android_client_info": { "package_name": "so.onekey.app.wallet" } },
    "oauth_client": [ $([[ -n "$W" ]] && echo "{ \"client_id\": \"$W\", \"client_type\": 3 }") ],
    "api_key": [ { "current_key": "$K" } ]
  } ],
  "configuration_version": "1"
}
GS
echo "[META] Firebase project ${P}, app ${I}; Sentry DSN $(cut -c1-40 /m/dsn.txt)..."
# Clock values CI bakes in: BUILD_TIME (Date.now() per bundler process: once in web-embed, once per Babel
# worker for platformEnv.ts and systemTimeUtils.ts in common.bundle), the web Sentry DSN and the
# sentry-debug-meta.properties date. Any that cannot be read unambiguously stay unpinned.
rm -rf /tmp/p && mkdir /tmp/p && unzip -q -o "$A" assets/common.bundle 'assets/web-embed/web-embed.*.js' assets/sentry-debug-meta.properties -d /tmp/p 2>/dev/null
we="$(grep -l 'buildTime:Number("' /tmp/p/assets/web-embed/web-embed.*.js 2>/dev/null)"
one() { [[ "$(printf '%s\n' "$1" | grep -c .)" == 1 ]] && printf '%s' "$1"; }
WBT="$(one "$(grep -aoE 'buildTime:Number\("[0-9]+"\)' $we 2>/dev/null | grep -oE '[0-9]+' | sort -u)")"
WDSN="$(one "$(grep -aoE 'sdk_init\(\{dsn:"[^"]*"' /tmp/p/assets/web-embed/web-embed.*.js 2>/dev/null | sed 's/.*dsn:"//; s/"$//' | sort -u)")"
SDATE="$(sed -n '2s/^#\([A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9 ][0-9] [0-9:]\{8\} [A-Z]* [0-9]\{4\}\)$/\1/p' /tmp/p/assets/sentry-debug-meta.properties 2>/dev/null)"
# platformEnv: Number("t") stored into the env object; systemTimeUtils: Math.max(Number("t"), <constant>).
PYTHONPATH=/opt/hd timeout 30m python3 -m hermes_dec.disassembly.hbc_disassembler /tmp/p/assets/common.bundle /tmp/c.dis >/dev/null 2>&1
read -r EBT SBT < <(awk '/<LoadConstString>.*String: .[0-9]+. \(String\)/ { v=$0; sub(/.*String: ./,"",v); sub(/. \(String\).*/,"",v); if (length(v) == 13) k=2; next }
  k && --k == 0 { if ($0 ~ /<LoadConstDouble>/) s[++ns]=v; else if ($0 ~ /<PutOwnBySlotIdx>|<PutById>|<PutNewOwnById/) e[++ne]=v }
  END { if (ne == 1 && ns == 1) print e[1], s[1] }' /tmp/c.dis 2>/dev/null)
printf 'WEB_BUILD_TIME=%s\nWEB_DSN=%s\nENV_BUILD_TIME=%s\nSYS_BUILD_TIME=%s\nSENTRY_DATE=%s\nDEV_SERVER_IP=%s\n' "$WBT" "$WDSN" "$EBT" "$SBT" "$SDATE" "$(s react_native_dev_server_ip)" > /m/pins.env
sed 's/^/[META]   pin /' /m/pins.env
META_END
: > "${META}/apks.txt"
MOUNTS=(); for f in "${OFFICIAL[@]}"; do MOUNTS+=(-v "${f}:/official/$(basename "$f"):ro"); done
crun "${MOUNTS[@]}" -v "${META}:/m" -v "${CTX}/meta.sh:/meta.sh:ro" "$IMG" bash -c "bash /meta.sh /official/$(basename "${OFFICIAL[0]}") \$(ls /official/*.apk | grep -vx /official/$(basename "${OFFICIAL[0]}"))" \
  || abort "Could not read metadata from the official APK(s)"
main="$(basename "${OFFICIAL[0]}")"
IFS='|' read -r _ pkg vname vcode main_split abis signer bundle_version jpush_key <<<"$(grep "^${main}|" "${META}/apks.txt" | head -1)"
[[ "$(awk -F'|' '$2 != "'"$APP_ID"'"' "${META}/apks.txt" | wc -l)" -eq 0 && -n "$pkg" ]] || die_invalid "Not every official APK is ${APP_ID} (see [META] lines)"
[[ -z "$main_split" ]] || die_invalid "${main} declares split '${main_split}'"
[[ -n "$vname" && "$vcode" =~ ^[0-9]+$ ]] || abort "Could not read versionName/versionCode from ${main}"
[[ "$MODE" == single && -n "$want_abi" && ",${abis}," != *",${want_abi},"* ]] && die_invalid "--arch ${want_abi}: ${main} carries ${abis:-no native code}"
[[ "$bundle_version" =~ ^[0-9]+$ ]] || abort "No BUNDLE_VERSION meta-data in ${main}"
dsn="$(cat "${META}/dsn.txt" 2>/dev/null)"
[[ -n "$dsn" ]] || abort "No SENTRY_DSN_REACT_NATIVE in ${main}'s BuildConfig (EAS release builds require it)"
[[ -f "${META}/google-services.json" ]] || abort "Could not read the Firebase strings from ${main}"
[[ "$MODE" == single && "$signer" != "$GH_SIGNER" ]] && log_warn "Signer ${signer:-unknown} is not the GitHub release signer ${GH_SIGNER}"
app_hash="$(sha256of "${OFFICIAL[0]}")"
if [[ -z "$version_arg" ]]; then version_arg="$vname"
elif [[ "$version_arg" != "$vname" ]]; then die_invalid "--version ${version_arg} but ${main} is ${vname}"; fi
log_success "${APP_ID} ${vname} (versionCode ${vcode})"
log_info "${main} SHA-256 ${app_hash}; signer ${signer:-?}; BUNDLE_VERSION ${bundle_version}; JPUSH_APPKEY ${jpush_key:-none}"

phase "PHASE 1: BUILD FROM SOURCE (v${version_arg})"
cat > "${CTX}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
TAG="$1"; VCODE="$2"; BV="$3"; JPK="$4"; PROFILE="$5"; DSN="$(cat /m/dsn.txt)"
pv() { sed -n "s/^$1=//p" /m/pins.env 2>/dev/null; }
git config --global --add safe.directory '*'
git clone -q --depth 1 --branch "$TAG" "$REPO_URL" "$EAS_PATH" || { echo "FATAL: no tag ${TAG} (clone failed)"; exit 4; }
cd "$EAS_PATH" || exit 1
C="$(git rev-parse HEAD)"; T="$(git cat-file -t "refs/tags/${TAG}" 2>/dev/null)"
{ echo "COMMIT=${C}"; echo "TAG_TYPE=$([[ "$T" == tag ]] && echo annotated || echo lightweight)"; } > /out/src.env
git log -1 --format='  built: %H %ci %s'
V="$(sed -n 's/^VERSION=//p' .env.version)"; [[ "v${V}" == "$TAG" ]] || echo "  WARNING: .env.version says ${V}, not ${TAG#v}"
# Resolve the eas.json profile (with extends); settings this image does not reproduce stop the run.
node -e 'const b=JSON.parse(require("fs").readFileSync("apps/mobile/eas.json")).build;
const m=(x,y)=>({...x,...y,env:{...x.env,...y.env},android:{...x.android,...y.android,env:{...(x.android||{}).env,...(y.android||{}).env}}});
const r=n=>{const q=b[n];if(!q)process.exit(5);return q.extends?m(r(q.extends),q):m({},q)};const c=r(process.argv[1]),a=c.android||{};
for(const[k,v]of Object.entries({...c.env,...a.env}))console.log("export "+k+"="+JSON.stringify(String(v)));
console.log(["GRADLE_CMD","EAS_NODE","EAS_IMAGE","EAS_NDK"].map((k,i)=>k+"="+JSON.stringify([a.gradleCommand,c.node,a.image,a.ndk][i]||"")).join("\n"))' "$PROFILE" > /tmp/eas.env \
  || { echo "FATAL: no eas.json profile ${PROFILE}"; exit 5; }
. /tmp/eas.env; sed 's/^/  eas.json: /' /tmp/eas.env
[[ "v${EAS_NODE}" == "$(node --version)" ]] || { echo "FATAL: eas.json wants node ${EAS_NODE}; this image has $(node --version)"; exit 5; }
[[ "$EAS_IMAGE" == ubuntu-24.04-jdk-17-ndk-r27b && "$EAS_NDK" == 27.1.12297006 ]] || { echo "FATAL: eas.json wants image ${EAS_IMAGE}, NDK ${EAS_NDK}"; exit 5; }
[[ -n "$GRADLE_CMD" ]] || { echo "FATAL: no gradleCommand in profile ${PROFILE}"; exit 5; }
# What the release workflow writes before eas build (shared-env action, build-gradle-edit, keys secret).
# Secrets not shipped in the APK stay empty; GITHUB_TAG is the workflow branch, not inlined in the app.
{ echo "GITHUB_SHA=${C}"; echo "GITHUB_TAG=${TAG}"; echo "CI_BUILD_APP_VERSION=${V}"; echo "CI_BUILD_NUMBER=${VCODE}"
  echo "BUNDLE_VERSION=${BV}"; echo "COVALENT_KEY="; echo "SENTRY_AUTH_TOKEN="; echo "SENTRY_TOKEN="; echo "SENTRY_PROJECT="
  echo "SENTRY_RELEASE_NAME=${TAG}-${VCODE}"; for s in EXT DESKTOP MAS SNAP WINMS; do echo "SENTRY_DSN_${s}="; done; echo "SENTRY_DSN_WEB=$(pv WEB_DSN)"
  echo "SENTRY_DSN_REACT_NATIVE=${DSN}"; echo "ONEKEY_ALLOW_SKIP_GPG_VERIFICATION=false"; echo "NO_FLIPPER=1"
  echo "SENTRY_DISABLE_AUTO_UPLOAD=false"; echo "JPUSH_KEY=${JPK}"; } >> .env.expo
echo "BUILD_NUMBER=${VCODE}" >> .env.version
G=apps/mobile/android/app/build.gradle
sed -i "0,/versionCode.*/s//versionCode ${VCODE}/" "$G"; sed -i "0,/versionName \".*\"/s//versionName \"${V}\"/" "$G"
grep -qE "^\s*versionCode ${VCODE}$" "$G" && grep -qE "^\s*versionName \"${V}\"$" "$G" || { echo "FATAL: version injection failed"; exit 5; }
cp /m/google-services.json apps/mobile/android/app/google-services.json
# development/env.js inlines BUILD_TIME=Date.now() per bundler process. The values read from the official
# bundles go into its two readers: web-embed's during yarn install, then the native ones for gradle.
BT_FILES=(packages/shared/src/platformEnv.ts packages/shared/src/utils/systemTimeUtils.ts)
pin_bt() { local f="$1" from="$2" to="$3"
  [[ "$(grep -cF "Number(${from})" "$f")" == 1 ]] || { echo "FATAL: ${f} has no single Number(${from})"; exit 5; }
  sed -i "s/Number(${from//./\\.})/Number(\"${to}\")/" "$f"; }
WBT="$(pv WEB_BUILD_TIME)"; EBT="$(pv ENV_BUILD_TIME)"; SBT="$(pv SYS_BUILD_TIME)"
if [[ -n "$WBT" && -n "$EBT" && -n "$SBT" ]]; then
  for f in "${BT_FILES[@]}"; do pin_bt "$f" process.env.BUILD_TIME "$WBT"; done
  echo "  BUILD_TIME pinned: web-embed ${WBT}, then platformEnv ${EBT}, systemTimeUtils ${SBT} (from the official APK)"
else echo "  WARNING: BUILD_TIME not pinned (not readable from the official APK)"; fi
SD="$(pv SENTRY_DATE)"
if [[ -n "$SD" ]]; then
  # The Sentry plugin writes java.util.Properties, whose first comment is the wall clock; copied like versionCode.
  cat >> "$G" <<GRADLE
tasks.matching { it.name.startsWith("injectSentryDebugMetaPropertiesIntoAssets") }.configureEach { t ->
    t.doLast { t.outputs.files.asFileTree.matching { include "**/sentry-debug-meta.properties" }.each { f ->
        f.text = f.text.replaceFirst(/(?m)^#[A-Z][a-z]{2} [A-Z][a-z]{2} .*\$/, "#${SD}") } }
}
GRADLE
  echo "  sentry-debug-meta.properties date pinned to ${SD} (from the official APK)"
fi
# React Native stores the build machine's first IPv4 as a resource (debug dev server only); copied like versionCode.
DIP="$(pv DEV_SERVER_IP)"; DIPA=()
if [[ "$DIP" =~ ^[0-9.]+$ ]]; then DIPA=("-PreactNativeDevServerIp=${DIP}"); echo "  react_native_dev_server_ip pinned to ${DIP} (from the official APK)"
else echo "  WARNING: react_native_dev_server_ip not pinned (not readable from the official APK)"; fi
# sentry.gradle reads this from the environment; without the CI token the upload task fails. Uploads only.
export SENTRY_DISABLE_AUTO_UPLOAD=true CI=1 EAS_BUILD=true EAS_BUILD_PLATFORM=android EAS_BUILD_PROFILE="$PROFILE" NODE_ENV=production GRADLE_USER_HOME="${HOME}/.gradle"
mkdir -p "$GRADLE_USER_HOME" && echo "org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g" > "$GRADLE_USER_HOME/gradle.properties"
echo "  node $(node --version), $(java -version 2>&1 | head -1)"
run() { echo "=== $1 === $(date)"; shift; "$@" > /out/step.log 2>&1 || { tail -40 /out/step.log; cat /out/step.log >> /out/build.log; cp /out/step.log /out/fail.log; echo "FATAL: step failed"; exit 3; }; cat /out/step.log >> /out/build.log; }
run "yarn install --immutable" yarn install --immutable
if [[ -n "$WBT" && -n "$EBT" && -n "$SBT" ]]; then pin_bt "${BT_FILES[0]}" "\"${WBT}\"" "$EBT"; pin_bt "${BT_FILES[1]}" "\"${WBT}\"" "$SBT"; fi
cd apps/mobile/android || exit 1
run "gradle ${GRADLE_CMD}" timeout 5h ./gradlew "$GRADLE_CMD" "${DIPA[@]}" --no-daemon --max-workers=4
if [[ "$GRADLE_CMD" == *bundle* ]]; then f="$(find app/build/outputs/bundle -name '*.aab' | head -1)"; cp "$f" /out/app-release.aab || { echo "FATAL: no .aab"; exit 3; }
else f="$(find app/build/outputs/apk -name '*.apk' | head -1)"; cp "$f" /out/app-release.apk || { echo "FATAL: no .apk"; exit 3; }; fi
echo "  output: ${f}"; echo "=== build complete $(date) ==="
BUILD_END
PROFILE="production"; [[ "$MODE" == splits ]] && PROFILE="production-store"
log_info "Release inputs from ${main}: versionCode ${vcode}, BUNDLE_VERSION ${bundle_version}, JPush key, Sentry DSN, Firebase config; eas.json profile ${PROFILE}"
log_info "Container build (typically 60-120 min)"
# A job, so a stop interrupts wait at once; the EXIT trap removes the named container.
# The source tree and gradle home live in the workspace (tens of GB), at EAS's paths inside the container.
# CPU affinity (taskset; rootless podman often lacks the cpuset controller) sizes Metro's worker pool.
mkdir -p "${WS}/eas" "${WS}/gradle" || abort "Cannot create ${WS}/eas"
ncpu="$(nproc)"; BUILD_CPUS="${BUILD_CPUS:-6}"; [[ "$BUILD_CPUS" =~ ^[1-9][0-9]*$ ]] || die_invalid "BUILD_CPUS must be a positive number"
(( BUILD_CPUS > ncpu )) && BUILD_CPUS="$ncpu"; log_info "Build container: ${BUILD_CPUS} of ${ncpu} CPUs, memory ${MEM_LIMIT:-unlimited}"
crun --name "$BUILD_CTR" -e "EAS_PATH=${EAS_PATH}" -e "REPO_URL=${REPO_URL}" -v "${WS}/eas:${EAS_HOME}/workingdir" -v "${WS}/gradle:${EAS_HOME}/.gradle" \
  -v "${BLD}:/out" -v "${META}:/m:ro" -v "${CTX}/build.sh:/build.sh:ro" "$IMG" \
  taskset -c "0-$((BUILD_CPUS-1))" timeout 5h bash /build.sh "v${version_arg}" "$vcode" "$bundle_version" "$jpush_key" "$PROFILE" > >(tee "${BLD}/container.log") 2>&1 &
wait "$!"; BRC=$?; sleep 1
case $BRC in
  0) ;;
  4) abort "No tag v${version_arg} in ${REPO_URL}; nothing was built" ;;
  3) has_compile_error "${BLD}/fail.log" && ftbfs "${APP_ID} ${vname} (${vcode}): the source failed to build (see built/fail.log). Official ${main} SHA-256 ${app_hash}."
     abort "Build failed with no source error (network, memory, disk or tooling); see built/container.log" ;;
  5) abort "This script cannot reproduce this release as written (see built/container.log); nothing was compared" ;;
  137) abort "The build container was killed (out of memory? try a lower BUILD_CPUS or a higher MEM_LIMIT)" ;;
  *) abort "Source preparation failed (container exit ${BRC})" ;;
esac
envv() { sed -n "s/^$1=//p" "${BLD}/src.env"; }
commit="$(envv COMMIT)"; tag_type="$(envv TAG_TYPE)"
log_info "SKIP lines in the build log: $(grep -cE '\bSKIP\b' "${BLD}/build.log")"
# Reported only; GitHub's API, so it says nothing about who signed offline.
commit_sig="$(crun -e GITHUB_TOKEN "$IMG" bash -c 'h=(); [[ -n "${GITHUB_TOKEN:-}" ]] && h=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsS --max-time 30 "${h[@]}" "https://api.github.com/repos/OneKeyHQ/app-monorepo/commits/$1" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const v=JSON.parse(s).commit.verification;console.log(v.verified+\" (\"+v.reason+\")\")})"' _ "$commit" 2>/dev/null)"

declare -a PAIRS=()   # "official-path|built-path"
if [[ "$MODE" == single ]]; then
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
# SourceStamp and manifest meta-data (Play splits only), or an apktool-decoded-identical resources.arsc.
# Everything else (dex, Hermes bundles and segments, native libs, assets, baseline.prof) is material.
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
nh=0; nhm=0
while IFS= read -r h; do nh=$((nh+1)); [[ -f "/tmp/b/${h#/tmp/o/}" ]] && cmp -s "$h" "/tmp/b/${h#/tmp/o/}" && nhm=$((nhm+1)); done \
  < <(find /tmp/o/assets -maxdepth 2 -type f \( -name '*.bundle' -o -name '*.hbc' \) 2>/dev/null)
echo "  native libs ${nsm}/${nso} identical; dex differing: ${dx:-none}; Hermes bundles/segments ${nhm}/${nh} identical"
[[ -s "$out/native_${tag}.txt" ]] && echo "  native evidence: native_${tag}.txt"
grep -qr 'com/pairip' /tmp/o/classes*.dex 2>/dev/null && echo "      dex: official carries com.pairip (Play Integrity rewrite) -> material"
c_sign=$(printf '%s\n' "$raw" | grep -cE '^Only in /tmp/o: META-INF/([^/ ]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$')
c_stamp=$(grep -cx 'Only in /tmp/o: stamp-cert-sha256' <<<"$raw"); c_mani=$(grep -c '^Files /tmp/o/AndroidManifest\.xml ' <<<"$raw")
c_arsc=$(grep -c '^Files /tmp/o/resources\.arsc ' <<<"$raw")
a_sign=$c_sign; a_stamp=0; a_mani=0; a_arsc=0
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
printf '%s\n' "$raw" | grep -q 'baseline\.prof' && echo "      baseline.prof: never auto-accepted (embeds dex checksums) -> material"
acc=$((a_sign+a_stamp+a_mani+a_arsc)); un=$((n-acc)); (( un >= 0 )) || { echo "FATAL: accepted ${acc} exceeds raw ${n} ($tag)"; exit 3; }
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
 Build logs:           ${rel_ws}/built/build.log, container.log (source tree: ${rel_ws}/eas/build)
EOF
if [[ "$tot_un" -eq 0 ]]; then verdict="reproducible"; rc=0; head_line="BUILDS MATCH BINARIES"
else verdict="not_reproducible"; rc=1; head_line="BUILDS DO NOT MATCH BINARIES"; fi
generate_yaml "$verdict" "${APP_ID} ${vname} (versionCode ${vcode}; ${MODE}) built from tag v${vname} (${tag_type:-?}) at ${commit}.
EAS-like build, eas.json profile ${PROFILE}. Copied from the official APK, so a match proves nothing about them: versionCode, BUNDLE_VERSION ${bundle_version}, JPUSH_APPKEY, the React Native and web Sentry DSNs, the Firebase strings (google-services.json is a CI secret), the React Native dev-server IP, the three BUILD_TIME clock values inlined into the JS and the sentry-debug-meta.properties date.
Secrets the APK does not expose (Covalent key, other Sentry DSNs, KEY_SECRET for libkeys.so) are left empty.
Official ${main} SHA-256 ${app_hash}, signer ${signer:-unknown}.
${pair_notes}
Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}.
The app can replace its JS bundle over the air (GPG-checked bundle updates); that is not covered by this build."
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
echo "Tag: v${vname} (${tag_type:-unknown}) -> ${commit}"
echo "Tag signature: $([[ "$tag_type" == annotated ]] && echo 'not checked' || echo 'none (lightweight tag)')"
echo "Commit signature (GitHub's API): ${commit_sig:-unknown}"
echo "===== End Results ====="
echo ""
echo "appHash = sha256 of ${main} as supplied/downloaded (publish this one); the per-split and built hashes above are for reference."
echo ""; echo "Exit code: ${rc}"
exit "$rc"
