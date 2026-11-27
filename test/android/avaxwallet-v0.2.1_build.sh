#!/usr/bin/env bash
# avaxwallet-v0.2.1_build.sh - Avax (Core Wallet by Ava Labs) Android reproducible build verification
# Version:          v0.2.1
# Last modified by: Claude Opus 5.5 for Danny Garcia
# Last modified on: 2026-11-27
# Organization:     WalletScrutiny.com
# App ID:           com.avaxwallet
# Project:          https://github.com/ava-labs/core-mobile (packages/core-mobile)
# License: MIT. Changelog: ~/work/ws-notes/script-notes/android/com.avaxwallet/changelog.md
# Disclaimer: provided as-is, without warranty, for reproducible-build verification only. Review before
#   running. This is not a security audit; you are responsible for lawful use.
# Steps: Core ships Android through Google Play only, so --binary (Play split dir or one APK) is required.
#   Builds the highest <version>-rcN tag (Bitrise `android` workflow) unless --commit: yarn install
#   --immutable && yarn setup, .env.production, google-services.json, versionName/Code in build.gradle,
#   CI=true (R8), ccache as Bitrise Build Cache, gradlew :app:bundleExternalRelease, bundletool splits
#   for a device spec from the official split names. Unsigned, source not patched. .env, Firebase values
#   and build paths are read back from the official APK. Every accepted difference is earned by a named
#   check. Library ws-rb-core (#1023); build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library; 130 stopped.

SCRIPT_VERSION="v0.2.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"; SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "$(basename "$SCRIPT_PATH") $SCRIPT_VERSION sha256:${SCRIPT_SHA256}"

# No -e: diff/cmp return 1 on differences; the library's ERR trap makes unguarded failures no verdict.
set -uo pipefail

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

APP_ID="com.avaxwallet"
REPO_URL="https://github.com/ava-labs/core-mobile"
DEF_SRC="/bitrise/src"; DEF_GRADLE="/root/.gradle"; SDK_DIR="/opt/android-sdk-linux"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"
APT_SNAPSHOT="20261101T000000Z"   # snapshot.debian.org: same apt packages on every run

phase()   { printf '\n== %s ==\n  %s\n' "$*" "$(date)"; }
section() { printf -- '\n-- %s --\n' "$*"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }
nov() { ws_no_verdict "$1"; }   # says nothing about the source: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML
ftbfs() { ws_error "$1"; ws_write_yaml ftbfs "$1"; exit 1; }

ws_refuse_root
ws_install_traps

usage() {
  cat <<USAGE
Usage: $(basename "$SCRIPT_PATH") --binary <Play-split-dir | apk> [--commit <sha>] [--dotenv <file>] [--app-env <unset|ci>] [--rn-archs <list>]
 --binary, --apk  Directory of Play splits (base.apk + split_config.*.apk), or one APK. Required.
 --version        Accepted; the version is read from the official APK.
 --commit         Build this commit instead of the highest <version>-rcN tag.
 --dotenv         KEY=value lines overriding the .env.production recovered from the official APK.
 --app-env        APP_ENV for the OpenAPI codegen (default unset; ci = mobile-pr.yml).
 --rn-archs       reactNativeArchitectures (default arm64-v8a,x86_64).
 --arch           Checked against the official split set (mismatch exits 2). --type: ignored.
 WS_DEVICE_SDK    env: device-spec API level (default 36; the SDK of the phone the splits came from).
Exit codes: 0 = reproducible, 1 = differences, ftbfs or no verdict, 2 = invalid parameters.
USAGE
}

version_arg=""; binary_arg=""; commit_arg=""; dotenv_arg=""; app_env="unset"; rn_archs="arm64-v8a,x86_64"; arch_arg=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      ws_require_value "$1" "${2:-}"; version_arg="${2#v}"; shift 2 ;;
    --apk|--binary) ws_require_value "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
    --commit)       ws_require_value "$1" "${2:-}"; commit_arg="$2"; shift 2 ;;
    --dotenv)       ws_require_value "$1" "${2:-}"; dotenv_arg="$2"; shift 2 ;;
    --app-env)      ws_require_value "$1" "${2:-}"; app_env="$2"; shift 2 ;;
    --rn-archs)     ws_require_value "$1" "${2:-}"; rn_archs="$2"; shift 2 ;;
    --arch)         ws_require_value "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
    --type)         ws_require_value "$1" "${2:-}"; ws_info "$1 $2 accepted, not used"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;
  esac
done
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || inv "Invalid --version '${version_arg}'"
[[ -z "$commit_arg" || "$commit_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || inv "--commit must be 7-40 hex characters"
[[ "$app_env" == unset || "$app_env" == ci ]] || inv "--app-env must be unset or ci"
[[ "$rn_archs" =~ ^(arm64-v8a|armeabi-v7a|x86|x86_64)(,(arm64-v8a|armeabi-v7a|x86|x86_64))*$ ]] || inv "--rn-archs: comma list of arm64-v8a, armeabi-v7a, x86, x86_64"
if [[ -n "$dotenv_arg" ]]; then [[ -f "$dotenv_arg" ]] || inv "--dotenv file not found: ${dotenv_arg}"; dotenv_arg="$(readlink -f "$dotenv_arg")"; fi
SDK="${WS_DEVICE_SDK:-36}"; [[ "$SDK" =~ ^[0-9]+$ ]] || inv "WS_DEVICE_SDK must be a number, got '${SDK}'"
[[ -n "$binary_arg" ]] || { usage; inv "--binary is required: Core ships Android only through Google Play (no downloadable APK)"; }

# MODE splits: base.apk + split_config.*.apk (paired by split=); MODE apk: one APK vs bundletool universal.
declare -a OFFICIAL=()
binary_arg="$(readlink -f "$binary_arg")" || inv "--binary not found"
if [[ -f "$binary_arg" ]]; then
  [[ "$(head -c 4 "$binary_arg" | od -An -tx1 | tr -d ' \n')" == 504b0304 ]] || inv "--binary file is not an APK (no ZIP header): ${binary_arg}"
  OFFICIAL_DIR="$(dirname "$binary_arg")"; OFFICIAL=("$binary_arg"); MODE=apk
elif [[ -d "$binary_arg" ]]; then
  OFFICIAL_DIR="$binary_arg"
  [[ -f "${OFFICIAL_DIR}/base.apk" ]] || inv "--binary directory has no base.apk: ${OFFICIAL_DIR}"
  OFFICIAL+=("${OFFICIAL_DIR}/base.apk")
  while IFS= read -r f; do OFFICIAL+=("$f"); done < <(find "$OFFICIAL_DIR" -maxdepth 1 -type f -name 'split_config.*.apk' | sort)
  n_other="$(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' ! -name base.apk ! -name 'split_config.*.apk' | wc -l)"
  [[ "$n_other" -eq 0 ]] || inv "Unexpected APK(s) in the split directory (only base.apk and split_config.*.apk are allowed)"
  if [[ ${#OFFICIAL[@]} -gt 1 ]]; then MODE=splits; else MODE=apk; fi
else inv "--binary is neither a file nor a directory: ${binary_arg}"; fi

# --arch: split name now, a single APK's native-code after metadata.
want_abi=""
if [[ -n "$arch_arg" ]]; then
  case "$arch_arg" in
    arm64-v8a|arm64_v8a|arm64|aarch64) want_abi=arm64-v8a ;; armeabi-v7a|armeabi_v7a|armv7|arm) want_abi=armeabi-v7a ;;
    x86_64|x86-64|amd64) want_abi=x86_64 ;; x86|i686) want_abi=x86 ;;
    *) inv "--arch '${arch_arg}' is not an Android ABI" ;;
  esac
  if [[ "$MODE" == splits ]]; then
    [[ -f "${OFFICIAL_DIR}/split_config.${want_abi//-/_}.apk" ]] || inv "--arch ${want_abi}: the official split set has no split_config.${want_abi//-/_}.apk"
  fi
fi

ws_results_init   # one run per folder; a stale YAML is removed here, after --help
ws_engine
# Rootless podman + cgroupfs can't set memory limits: --memory (MEM_LIMIT, default 24g) is docker only.
MEM_ARGS=(); if [[ "$WS_ENGINE" == docker ]]; then MEM_LIMIT="${MEM_LIMIT-24g}"; [[ -z "$MEM_LIMIT" ]] || MEM_ARGS=(--memory="$MEM_LIMIT"); fi
# Every container is named and tracked, so the exit trap stops it if the run ends early.
CN="avaxwallet-${WS_RUN_ID}"
for c in meta build render pair lock; do ws_track_container "${CN}-${c}"; done
# shellcheck disable=SC2046
crun() { local n="${CN}-$1"; shift; ws_ctr run --rm --name "$n" $(ws_user_flags) -e HOME=/tmp/h "${MEM_ARGS[@]}" "$@"; }

# Per-run workspace in the caller's directory, named once. Without --version the name says "provided".
ws_workspace avaxwallet "${version_arg:-provided}"
WS="$WS_WORKDIR"
IMG="localhost/ws-avaxwallet:${WS_RUN_ID}"; ws_track_image "$IMG"
NET=""
ws_cleanup_hook() { [[ -n "$NET" ]] || return 0; ws_ctr rm -f "${CN}-build" &>/dev/null; ws_ctr network rm -f "$NET" &>/dev/null; return 0; }
CTX="${WS}/ctx"; mkdir -p "$CTX"

cat <<EOF

==============================================================
  CORE WALLET (AVA LABS) - ANDROID VERIFICATION
==============================================================
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Official:  ${#OFFICIAL[@]} APK(s) from ${OFFICIAL_DIR} (mode: ${MODE})
 Runtime:   ${WS_ENGINE} ($(ws_ctr --version 2>&1 | head -1))
EOF

phase "SETUP: BUILD CONTAINER IMAGE"
# Node 20.19.0, JDK 17 = bitrise.yml; SDK 36, build-tools 36.0.0, NDK 27.1.12297006 = android/build.gradle;
# SDK path = Bitrise stack; apt packages = _build-android, from a Debian snapshot. SDK writable for AGP.
cat > "${CTX}/Dockerfile" <<DOCKERFILE_END
FROM docker.io/library/node:20.19.0-bookworm@sha256:a5fb035ac1dff34a4ecaea85f90f7321185695d3fd22c12ba12f4535a4647cc5
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN sed -i -E 's#http://deb.debian.org/(debian(-security)?)\$#http://snapshot.debian.org/archive/\1/${APT_SNAPSHOT}#' /etc/apt/sources.list.d/debian.sources \\
  && ! grep -q 'deb.debian.org' /etc/apt/sources.list.d/debian.sources && apt-get -o Acquire::Check-Valid-Until=false update \\
  && apt-get install -y --no-install-recommends git unzip zip curl ca-certificates binutils python3 \\
    gnupg build-essential autoconf automake libtool && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && curl -fsSL -o jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz" \\
  && echo "d8afc263758141a66e0e3aafc321e783f7016696f4eaea067d340a269037d331  jdk.tar.gz" | sha256sum -c - \\
  && mkdir -p /opt/jdk17 && tar -xzf jdk.tar.gz -C /opt/jdk17 --strip-components=1 && rm jdk.tar.gz
ENV JAVA_HOME=/opt/jdk17 ANDROID_HOME=${SDK_DIR} ANDROID_SDK_ROOT=${SDK_DIR}
ENV PATH=/opt/jdk17/bin:${SDK_DIR}/cmdline-tools/latest/bin:${SDK_DIR}/platform-tools:\$PATH
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
# ccache 4.13.2 = what bitrise-build-cache-cli installs for activate-build-cache-for-react-native.
RUN cd /tmp && curl -fsSL -o cc.tgz https://github.com/ccache/ccache/releases/download/v4.13.2/ccache-4.13.2-linux-x86_64-glibc.tar.gz \\
  && echo "e531303ffded7ddf0f275674d866f6ac1ad89148c235346e7b12c3c915d15f56  cc.tgz" | sha256sum -c - \\
  && tar -xzf cc.tgz && install -m 0755 ccache-4.13.2-linux-x86_64-glibc/ccache /usr/local/bin/ccache && rm -rf cc.tgz ccache-4.13.2-*
# /root traversable: Gradle home mounts at /root/.gradle.
RUN mkdir -p /tmp/h /tmp/afw && chmod 0777 /tmp/h /tmp/afw && chmod 0755 /root
DOCKERFILE_END
ws_ctr build -t "$IMG" -f "${CTX}/Dockerfile" "$CTX" || nov "Container image build failed (network, apt snapshot or base image); nothing was built."
ws_ok "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL ARTIFACT METADATA"
cat > "${CTX}/meta.sh" <<'META_END'
#!/bin/bash
BT="$ANDROID_HOME/build-tools/36.0.0"
for A in "$@"; do
  i="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"; p="$(printf '%s\n' "$i" | grep '^package:')"
  g() { printf '%s\n' "$p" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
  pkg="$(printf '%s\n' "$p" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  abis="$(printf '%s\n' "$i" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
  minsdk="$(printf '%s\n' "$i" | sed -n "s/^\(minSdkVersion\|sdkVersion\):'\([0-9]*\)'.*/\2/p" | head -1)"
  sv="$("$BT/apksigner" verify --verbose --print-certs "$A" 2>/dev/null)"
  signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/{print $NF; exit}')"
  stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
  sreq="$("$BT/aapt2" dump xmltree --file AndroidManifest.xml "$A" 2>/dev/null | grep -cE 'isSplitRequired|requiredSplitTypes')"
  unzip -l "$A" resources.arsc >/dev/null 2>&1; z=$?
  if [[ $z == 11 && -n "$(g split)" ]]; then : > /tmp/r.txt
  else [[ $z == 0 ]] && "$BT/aapt2" dump resources "$A" > /tmp/r.txt 2>/dev/null || { echo "[META] resource dump failed (unzip $z)"; exit 7; }; fi
  devip="$(grep -A1 'string/react_native_dev_server_ip$' /tmp/r.txt | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
  echo "$(basename "$A")|${pkg}|$(g versionName)|$(g versionCode)|$(g split)|${abis}|${minsdk}|${signer}|${stamp}|${devip}|${sreq}" >> /m/apks.txt
  echo "[META] $(basename "$A"): ${pkg} $(g versionName) ($(g versionCode)) split '$(g split)' abis ${abis:-none} minSdk ${minsdk} SourceStamp ${stamp} devIP ${devip:-none}"
  echo "[META]   signer ${signer:-?}"
  if [[ -z "$(g split)" ]]; then
    # react-native-config (dotenv.gradle) writes each .env key as resValue string/<KEY>; the
    # google-services plugin writes its lower-case Firebase values. Default-config strings only.
    python3 - /tmp/r.txt <<'PY' || exit 7
import re, sys
fb = {'google_app_id','gcm_defaultSenderId','default_web_client_id','firebase_database_url','google_api_key','google_crash_reporting_api_key','google_storage_bucket','project_id'}
env, inp, name = [], [], None
for l in open(sys.argv[1], encoding='utf-8', errors='replace'):
    m = re.match(r'\s*resource 0x[0-9a-f]+ string/(\S+)', l)
    if m: name = m.group(1); continue
    m = re.match(r'\s*\(\) "(.*)"\s*$', l)
    if name and m:
        v = m.group(1)
        if re.fullmatch(r'[A-Z][A-Z0-9_]*', name): env.append(f'{name}={v}')
        elif name in fb: inp.append(f'{name}={v}')
    name = None
open('/m/dotenv.recovered', 'w').write(''.join(x + '\n' for x in env))
open('/m/inputs.txt', 'a').write(''.join(x + '\n' for x in inp))
print(f'[META]   .env keys from string resources: {len(env)}; Firebase values: {len(inp)}')
PY
  fi
  # Build paths baked into native libraries: checkout root, Gradle user home, SDK root.
  for so in $(unzip -Z1 "$A" 'lib/*.so' 2>/dev/null); do unzip -p "$A" "$so" | strings; done > /tmp/s.txt 2>/dev/null
  r="$(grep -oE '(/[A-Za-z0-9._-]+)+/node_modules/' /tmp/s.txt | grep -vE '/\.gradle/|/\.\./' | sed 's|/node_modules/$||; s|/packages/[^/]*$||' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  [[ -n "$r" ]] && echo "src_root=${r}" >> /m/inputs.txt
  gh="$(grep -oE '^/[^ ]+/\.gradle/caches/' /tmp/s.txt | head -1)"; [[ -n "$gh" ]] && echo "gradle_home=${gh%/caches/}" >> /m/inputs.txt
  sd="$(grep -oE '/[A-Za-z0-9._/-]+/ndk/[0-9.]+/' /tmp/s.txt | sed 's|/ndk/.*||' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  [[ -n "$sd" ]] && echo "sdk_root=${sd}" >> /m/inputs.txt
done
exit 0
META_END
META="${WS}/metadata"; mkdir -p "$META"; : > "${META}/apks.txt"; : > "${META}/inputs.txt"; : > "${META}/dotenv.recovered"
declare -a MNT=(); for f in "${OFFICIAL[@]}"; do MNT+=("/official/$(basename "$f")"); done
crun meta -v "${OFFICIAL_DIR}:/official:ro" -v "${META}:/m" -v "${CTX}/meta.sh:/meta.sh:ro" "$IMG" bash /meta.sh "${MNT[@]}" \
  || nov "Could not read metadata from the official APKs."
main="$(basename "${OFFICIAL[0]}")"
IFS='|' read -r _ pkg vname vcode main_split main_abis min_sdk signer _ dev_ip split_req <<<"$(grep "^${main}|" "${META}/apks.txt" | head -1 || true)"
[[ "$(awk -F'|' '$2 != "'"$APP_ID"'"' "${META}/apks.txt" | wc -l)" -eq 0 && -n "$pkg" ]] || inv "Not every official APK is ${APP_ID} (see [META] lines)"
[[ -z "$main_split" ]] || inv "${main} declares split '${main_split}'"
[[ -n "$vname" && "$vcode" =~ ^[0-9]+$ ]] || nov "Could not read versionName/versionCode from ${main}."
[[ "$vname" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || nov "Unexpected versionName '${vname}' in ${main}."
[[ "$MODE" == apk && "${split_req:-0}" -gt 0 ]] && inv "${main} requires config splits (isSplitRequired); pass the whole split directory"
if [[ -n "$want_abi" && "$MODE" == apk ]]; then
  [[ ",${main_abis}," == *",${want_abi},"* ]] || inv "--arch ${want_abi}: ${main} carries ${main_abis:-no native code}"
fi
app_hash="$(sha256of "${OFFICIAL[0]}")"
[[ -n "$version_arg" && "$version_arg" != "$vname" ]] && ws_warn "--version ${version_arg} ignored: ${main} says ${vname}"
inp() { sed -n "s/^$1=//p" "${META}/inputs.txt" | grep -v '^$' | head -1 || true; }
SRC_ROOT="$(inp src_root)"; GRADLE_HOME="$(inp gradle_home)"; sdk_seen="$(inp sdk_root)"
[[ "$SRC_ROOT" =~ ^/[A-Za-z0-9._/-]+$ && "${SRC_ROOT}/" != */../* ]] || { ws_warn "No checkout path found in the official native libs; using ${DEF_SRC}"; SRC_ROOT="$DEF_SRC"; }
[[ "$GRADLE_HOME" =~ ^/[A-Za-z0-9._/-]+$ && "${GRADLE_HOME}/" != */../* ]] || { ws_warn "No Gradle home found in the official native libs; using ${DEF_GRADLE}"; GRADLE_HOME="$DEF_GRADLE"; }
[[ -n "$sdk_seen" && "$sdk_seen" != "$SDK_DIR" ]] && ws_warn "Official native libs name SDK root ${sdk_seen}; this image uses ${SDK_DIR}"

BLD="${WS}/built"; CMP="${WS}/comparison"
mkdir -p "$BLD" "$CMP" "${WS}/src" "${WS}/gradle-home" || nov "Cannot populate workspace ${WS}."
ws_ok "${APP_ID} ${vname} (versionCode ${vcode})"
ws_info "Workspace: ${WS}"
ws_info "${main} SHA-256 ${app_hash}; signer ${signer:-?}"
ws_info "Build paths from the official native libs: checkout ${SRC_ROOT}, Gradle home ${GRADLE_HOME}, SDK ${sdk_seen:-not seen}"
n_env="$(grep -c '=' "${META}/dotenv.recovered" 2>/dev/null || true)"
ws_info ".env.production recovered from ${main}: ${n_env:-0} keys ($(cut -d= -f1 "${META}/dotenv.recovered" 2>/dev/null | paste -sd' ' - || true))"
ws_info "Firebase values recovered: $(grep -E '^[a-z_A-Z]+=.+' "${META}/inputs.txt" | cut -d= -f1 | grep -vE '^(src_root|gradle_home|sdk_root)$' | paste -sd' ' - || true)"

phase "PHASE 1: BUILD FROM SOURCE (${vname})"
cat > "${CTX}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
V="$1"; REPO="$2"; WANT="$3"; MODE="$4"; VC="$5"; SRC="$6"; APPENV="$7"; ARCHS="$8"
NETRE='ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ECONNRESET|ECONNREFUSED|socket hang up|fetch failed|UnknownHostException|Temporary failure in name resolution|Connection (timed out|reset)|Read timed out|Could not (GET|HEAD) .https?://'
r7() { echo "FATAL: recipe step failed: $1 (not the source)"; exit 7; }
git config --global --add safe.directory '*'
git clone -q --filter=blob:none "$REPO" "$SRC" || { echo "FATAL: clone failed"; exit 5; }
cd "$SRC" || exit 5
# Bitrise's getAppVersion.sh takes the version from an -rc tag; Play then gets the promoted build.
TAG="$(git tag -l "${V}-rc*" | sort -V | tail -1)"; tagc=""; [[ -n "$TAG" ]] && tagc="$(git rev-parse "refs/tags/${TAG}^{commit}")"
if [[ -n "$WANT" ]]; then
  c="$(git rev-parse -q --verify "${WANT}^{commit}")" || { git fetch -q origin "$WANT" 2>/dev/null; c="$(git rev-parse -q --verify "${WANT}^{commit}")"; }
  [[ -n "$c" ]] || { echo "FATAL: --commit ${WANT} is not in ${REPO}"; exit 4; }; src="--commit"
elif [[ -n "$tagc" ]]; then c="$tagc"; src="tag ${TAG}"
else echo "FATAL: no tag ${V}-rcN in ${REPO}"; exit 4; fi
git checkout -q "$c" || exit 5
curl -fsSL https://github.com/web-flow.gpg 2>/dev/null | gpg --batch --import >/dev/null 2>&1
sig="$(git verify-commit "$c" 2>&1 | grep -oE 'Good signature from "[^"]*"|BAD signature|Can.t check signature' | head -1)"
{ echo "COMMIT=$(git rev-parse HEAD)"; echo "TAG=${TAG:-none}"; echo "TAG_COMMIT=${tagc:-none}"; echo "SIG=${sig:-unsigned}"
  echo "TAG_TYPE=$( [[ -n "$TAG" ]] && git cat-file -t "refs/tags/${TAG}" || echo none)"; echo "SOURCE=${src}"
  echo "RC_TAGS=$(git tag -l "${V}-rc*" | sort -V | paste -sd' ' -)"; echo "PLAIN_TAG=$(git tag -l "${V}")"; } > /out/src.env
git log -1 --format='  built: %H %ci %s'; echo "  source: ${src}; rc tags for ${V}: $(git tag -l "${V}-rc*" | sort -V | paste -sd' ' -)"
echo "  commit signature: ${sig:-none}"
echo "  node $(node --version), $(java -version 2>&1 | head -1)"
# exit 5 = network, 6 = killed, 7 = a recipe step outside the source build (all no verdict);
# exit 3 = a build step failed: the host calls it ftbfs only for a compiler or resource error.
# Step output goes to the terminal too, so the recording carries the whole build log.
run() { echo "=== $1 === $(date)"; shift; "$@" 2>&1 | tee /out/step.log; local rc=${PIPESTATUS[0]}; cat /out/step.log >> /out/build.log
  (( rc == 0 )) && return 0
  (( rc >= 128 )) && { echo "FATAL: step killed by signal $((rc-128)) (memory?)"; exit 6; }
  grep -qE 'No space left on device|java\.lang\.OutOfMemoryError|daemon disappeared unexpectedly|Killed signal terminated program|exit value 137' /out/step.log && { echo "FATAL: step killed, out of memory or disk"; exit 6; }
  if grep -qE "$NETRE" /out/step.log; then echo "FATAL: step failed on the network"; exit 5; fi; echo "FATAL: step failed"; exit 3; }
# bitrise.yml runs on CI=true; app/build.gradle enables R8 only when CI == 'true'.
export CI=true
[[ "$APPENV" == ci ]] && export APP_ENV=ci || unset APP_ENV
echo "  CI=true, APP_ENV=${APP_ENV:-<unset>} (OpenAPI codegen schema URLs)"
yj="$(ls .yarn/releases/yarn-*.cjs 2>/dev/null | head -1)"; [[ -n "$yj" ]] || r7 "no .yarn/releases"; Y=(node "$SRC/$yj")
echo "  yarn $("${Y[@]}" --version)"
# scripts/bitrise/yarnSetup.sh: yarn install --immutable && yarn setup (committed yarnPath, not corepack).
run "yarn install --immutable" "${Y[@]}" install --immutable
run "yarn setup" "${Y[@]}" setup
cd packages/core-mobile || r7 "no packages/core-mobile"
find app/utils/api/generated -type f 2>/dev/null | sort | xargs -r sha256sum > /out/codegen.sha256
echo "  OpenAPI codegen output: $(wc -l < /out/codegen.sha256) files, combined $(sha256sum /out/codegen.sha256 | cut -c1-16)"
# scripts/bitrise/setEnv.sh: ENVIRONMENT=production, APP_TITLE "Core Mobile" -> .env.production, external Firebase.
cp /m/dotenv.recovered .env || r7 .env
if [[ -f /dotenv ]]; then
  ov="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' /dotenv)"; (( $? < 2 )) || r7 --dotenv
  while IFS= read -r l; do [[ -n "$l" ]] || continue; k="${l%%=*}"; grep -v "^${k}=" .env > .env.t
    (( $? < 2 )) && mv .env.t .env && echo "$l" >> .env || r7 --dotenv; done <<<"$ov"
  echo "  .env += --dotenv ($(grep -cE '^[A-Za-z_]' /dotenv) keys)"; fi
echo "  .env keys: $(cut -d= -f1 .env | paste -sd' ' -)"
[[ -s .env ]] || echo "  WARNING: .env is empty; the official APK carried no react-native-config strings"
python3 - <<'PY' || r7 google-services.json
import json
v = dict(l.rstrip('\n').split('=', 1) for l in open('/m/inputs.txt') if '=' in l)
if not v.get('google_app_id'): print("  WARNING: no google_app_id in the official APK; stub google-services.json"); v['google_app_id'] = '1:0:android:0'
c = {"client_info": {"mobilesdk_app_id": v['google_app_id'], "android_client_info": {"package_name": "com.avaxwallet"}},
     "oauth_client": ([{"client_id": v['default_web_client_id'], "client_type": 3}] if v.get('default_web_client_id') else []),
     "api_key": [{"current_key": v.get('google_api_key') or v.get('google_crash_reporting_api_key') or 'x'}],
     "services": {"appinvite_service": {"other_platform_oauth_client": []}}}
pi = {"project_number": v.get('gcm_defaultSenderId') or '0', "project_id": v.get('project_id') or 'x'}
if v.get('google_storage_bucket'): pi["storage_bucket"] = v['google_storage_bucket']
if v.get('firebase_database_url'): pi["firebase_url"] = v['firebase_database_url']
json.dump({"project_info": pi, "client": [c], "configuration_version": "1"}, open('android/app/google-services.json', 'w'), indent=2)
print("  google-services.json from official resources: " + ", ".join(k for k in ('google_app_id','gcm_defaultSenderId','default_web_client_id','google_api_key','project_id','google_storage_bucket','firebase_database_url') if v.get(k)))
PY
# Bitrise step change-android-versioncode-and-versionname: rewrites both lines of app/build.gradle.
sed -i -E "s/^([[:space:]]*)versionCode .*/\1versionCode ${VC}/; s/^([[:space:]]*)versionName .*/\1versionName \"${V}\"/" android/app/build.gradle \
  && grep -qE "versionCode ${VC}$" android/app/build.gradle && grep -qF "versionName \"${V}\"" android/app/build.gradle || r7 "version rewrite"
grep -nE '^[[:space:]]*version(Code|Name) ' android/app/build.gradle | sed 's/^/  build.gradle: /'
# AGP keeps its prefs in ANDROID_USER_HOME, else user.home from passwd ("/" under podman keep-id).
export ANDROID_USER_HOME="${HOME}/.android"; mkdir -p "$ANDROID_USER_HOME" || r7 ANDROID_USER_HOME
# sentry.gradle uploads source maps to upstream's Sentry account; its own switch skips only the upload.
export SENTRY_DISABLE_AUTO_UPLOAD=true
# Bitrise activate-build-cache-for-react-native: C/C++ through ccache, CCACHE_BASEDIR = checkout,
# CCACHE_NOHASHDIR=true (paths become relative: __FILE__, debug info, build IDs). Fresh local cache.
export CCACHE_BASEDIR="$SRC" CCACHE_NOHASHDIR=true CCACHE_COMPILERCHECK=content CCACHE_DIR=/tmp/h/ccache
export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
ccache -z >/dev/null; echo "  $(ccache --version | head -1), CCACHE_BASEDIR=${CCACHE_BASEDIR}"
cd android || r7 "no android/"
run "gradle :app:bundleExternalRelease -PreactNativeArchitectures=${ARCHS}" ./gradlew :app:bundleExternalRelease --no-daemon "-PreactNativeArchitectures=${ARCHS}"
ccache -s -v > /out/ccache-stats.txt 2>&1; ncc="$(ccache --print-stats 2>/dev/null | awk -F'\t' '$1 ~ /^(cache_miss|direct_cache_hit|preprocessed_cache_hit)$/ {s+=$2} END {print s+0}')"
echo "  ccache saw ${ncc} compilations (built/ccache-stats.txt)"; [[ "$ncc" -gt 0 ]] || echo "  WARNING: no compilation went through ccache; native paths will not match Bitrise"
cp app/build/outputs/bundle/externalRelease/app-external-release.aab /out/app-release.aab || r7 "no app-external-release.aab"
sha256sum /out/app-release.aab | sed 's/^/  /'
echo "=== build complete $(date) ==="
BUILD_END
# RN bakes the build host's IPv4 into react_native_dev_server_ip: reuse the official private one.
NET_ARGS=()
if [[ "$dev_ip" =~ ^(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+$ && "${dev_ip##*.}" != 1 ]]; then
  NET="ws-avaxwallet-net-${WS_RUN_ID}"
  if ws_ctr network create --subnet "${dev_ip%.*}.0/24" "$NET" >/dev/null 2>&1; then NET_ARGS=(--network "$NET" --ip "$dev_ip")
  else ws_warn "Could not create a ${dev_ip%.*}.0/24 network; react_native_dev_server_ip will hold this container's address"; NET=""; fi
fi
DOT_ARGS=(); [[ -n "$dotenv_arg" ]] && DOT_ARGS=(-v "${dotenv_arg}:/dotenv:ro")
ws_info "Container build (typically 60-150 min)"
# Source and Gradle home at the paths the official native libs record.
BRC=0
crun build "${NET_ARGS[@]}" "${DOT_ARGS[@]}" -e "GRADLE_USER_HOME=${GRADLE_HOME}" \
  -v "${WS}/src:${SRC_ROOT}" -v "${WS}/gradle-home:${GRADLE_HOME}" -v "${META}:/m:ro" \
  -v "${BLD}:/out" -v "${CTX}/build.sh:/build.sh:ro" "$IMG" \
  bash /build.sh "$vname" "$REPO_URL" "$commit_arg" "$MODE" "$vcode" "$SRC_ROOT" "$app_env" "$rn_archs" 2>&1 | tee "${BLD}/container.log" || BRC=${PIPESTATUS[0]}
if [[ $BRC -ne 0 ]]; then
  [[ $BRC -eq 4 ]] && nov "No source revision for ${vname} (no tag ${vname}-rcN; see built/container.log); nothing was built."
  [[ $BRC -eq 5 ]] && nov "Clone, checkout or a download failed on the network (see built/container.log); not a verdict on the source."
  [[ $BRC -eq 6 ]] && nov "A build step was killed or ran out of memory/disk (raise MEM_LIMIT or free space; see built/container.log); not a verdict on the source."
  [[ $BRC -eq 7 ]] && nov "A recipe step outside the source build failed (google-services.json, layout or bundle path; see built/container.log)."
  [[ $BRC -eq 3 ]] || nov "Build container failed outside the build (exit ${BRC}: runtime); not a verdict on the source."
  kind="$(ws_gradle_failure_kind "${BLD}/step.log")"
  [[ "$kind" == source ]] || nov "A build step failed (${kind}): no compiler or resource error, so not a verdict on the source (see built/step.log)."
  ftbfs "Source build failed with a compiler or resource error (see built/step.log). Official ${main} SHA-256 ${app_hash}."
fi
envv() { sed -n "s/^$1=//p" "${BLD}/src.env"; }
commit="$(envv COMMIT)"; tag="$(envv TAG)"; tag_commit="$(envv TAG_COMMIT)"; tag_type="$(envv TAG_TYPE)"
rev_source="$(envv SOURCE)"; commit_sig="$(envv SIG)"; rc_tags="$(envv RC_TAGS)"
[[ -f "${BLD}/app-release.aab" && "$commit" =~ ^[0-9a-f]{40}$ ]] || nov "The build exited 0 but left no app bundle or commit record."

section "Build record (ws-buildlock, verdict unaffected)"
BUILD_LOCK_FILE=""; BL_SH="${CTX}/ws-buildlock.sh"; BL_DIR="${WS}/build-lock"; bl_rc=0; mkdir -p "$BL_DIR"
if crun lock -v "${CTX}:/c" "$IMG" curl -fsSL --max-time 60 -o /c/ws-buildlock.sh "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" \
   && [[ "$(sha256of "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
  crun lock -v "${WS}/gradle-home:/gh:ro" -v "${WS}/src:/src:ro" -v "${BL_DIR}:/bl" -v "${BL_SH}:/ws-buildlock.sh:ro" "$IMG" \
    bash /ws-buildlock.sh --out /bl --gradle-home /gh --src /src --app-id "$APP_ID" --version "$vname" --platform android \
    --commit "$commit" > "${WS}/build-lock.log" 2>&1 || bl_rc=$?
  bl_n="$(grep -o '"ecosystem": *"gradle"' "${BL_DIR}/build-lock.json" 2>/dev/null | wc -l || true)"
  if [[ $bl_rc -eq 0 && "${bl_n:-0}" -gt 0 ]]; then BUILD_LOCK_FILE="${BL_DIR}/build-lock.json"
    ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (${bl_n} Gradle artifacts, sha256 $(sha256of "$BUILD_LOCK_FILE"))"
  else ws_warn "No usable build-lock.json (exit ${bl_rc}; see ${WS}/build-lock.log)"; fi
else ws_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256"; fi

section "Rendering the app bundle with bundletool ${BUNDLETOOL_VERSION}"
declare -a PAIRS=()   # "official-path|built-path"
if [[ "$MODE" == apk ]]; then
  crun render -v "${BLD}:/out" "$IMG" bash -c 'set -e; rm -rf /out/rendered; mkdir -p /out/rendered
    java -jar /opt/bundletool.jar build-apks --bundle=/out/app-release.aab --output=/out/rendered/built.apks --mode=universal \
      --aapt2=$ANDROID_HOME/build-tools/36.0.0/aapt2 --overwrite
    cd /out/rendered && unzip -q -o built.apks universal.apk && ls' 2>&1 | tee "${BLD}/bundletool.log" | sed 's/^/  /' \
    || nov "bundletool rendering failed (tooling, see built/bundletool.log)."
  PAIRS=("${OFFICIAL[0]}|${BLD}/rendered/universal.apk"); echo "  ${main} <-> rendered/universal.apk"
else
  ABIS=(); DEN=""; LOCS=()
  for f in "${OFFICIAL[@]}"; do
    c="$(basename "$f" .apk)"; c="${c#split_config.}"
    case "$c" in
      base) ;;
      arm64_v8a) ABIS+=(arm64-v8a) ;; armeabi_v7a) ABIS+=(armeabi-v7a) ;; x86_64|x86) ABIS+=("$c") ;;
      ldpi) DEN=120;; mdpi) DEN=160;; tvdpi) DEN=213;; hdpi) DEN=240;; xhdpi) DEN=320;; xxhdpi) DEN=480;; xxxhdpi) DEN=640;;
      [a-z][a-z]|[a-z][a-z][a-z]) LOCS+=("$c") ;;
      *) ws_warn "Unknown config split '${c}' ($(basename "$f")); it will stay unmatched" ;;
    esac
  done
  [[ ${#ABIS[@]} -eq 0 ]] && ABIS=("arm64-v8a"); [[ -z "$DEN" ]] && DEN=480; [[ ${#LOCS[@]} -eq 0 ]] && LOCS=("en")
  for a in "${ABIS[@]}"; do [[ ",${rn_archs}," == *",${a},"* ]] || ws_warn "Official split ABI ${a} is not in --rn-archs ${rn_archs}"; done
  abij="$(printf '"%s",' "${ABIS[@]}")"; locj="$(printf '"%s",' "${LOCS[@]}")"
  printf '{"supportedAbis":[%s],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' "${abij%,}" "${locj%,}" "$DEN" "$SDK" > "${BLD}/device-spec.json"
  echo "  device-spec: $(cat "${BLD}/device-spec.json")"
  crun render -v "${BLD}:/out" "$IMG" bash -c 'set -e; rm -rf /out/rendered; mkdir -p /out/rendered
    java -jar /opt/bundletool.jar build-apks --bundle=/out/app-release.aab --output=/out/rendered/built.apks \
      --device-spec=/out/device-spec.json --aapt2=$ANDROID_HOME/build-tools/36.0.0/aapt2 --overwrite
    cd /out/rendered && unzip -q -o built.apks "splits/*.apk" && ls splits/' 2>&1 | tee "${BLD}/bundletool.log" | sed 's/^/  /' \
    || nov "bundletool rendering failed (tooling, see built/bundletool.log)."
  prc=0
  crun pair -v "${OFFICIAL_DIR}:/official:ro" -v "${BLD}:/out" "$IMG" bash -c '
    BT=$ANDROID_HOME/build-tools/36.0.0
    cfg() { s=$("$BT/aapt2" dump badging "$1" 2>/dev/null) || exit 9; s=$(printf "%s\n" "$s" | grep "^package:" | sed -n "s/.*split=.\([^\x27]*\).*/\1/p"); echo "${s#config.}"; }
    for o in /official/base.apk /official/split_config.*.apk; do co=$(cfg "$o") || exit 9; m=""
      for b in /out/rendered/splits/*.apk; do cb=$(cfg "$b") || exit 9; [[ "$cb" == "$co" ]] && { m="$b"; break; }; done
      echo "$(basename "$o")|${co:-base}|${m:+rendered/splits/$(basename "$m")}"; done' > "${BLD}/pairs.txt" 2>/dev/null || prc=$?
  [[ $prc -eq 0 && "$(grep -c . "${BLD}/pairs.txt" || true)" -eq ${#OFFICIAL[@]} ]] || nov "Pairing official and rendered splits failed (exit ${prc})."
  while IFS='|' read -r o c b; do
    if [[ -n "$b" ]]; then PAIRS+=("${OFFICIAL_DIR}/${o}|${BLD}/${b}"); echo "  ${o} (split '${c}') <-> ${b}"
    else ws_warn "No rendered counterpart for ${o} (split '${c}') -> counted as a difference"; PAIRS+=("${OFFICIAL_DIR}/${o}|"); fi
  done < "${BLD}/pairs.txt"
  n_rend="$(find "${BLD}/rendered/splits" -name '*.apk' | wc -l)"; n_used="$(cut -d'|' -f3 "${BLD}/pairs.txt" | grep -c . || true)"
  extra=$((n_rend - n_used)); [[ $extra -gt 0 ]] && ws_warn "${extra} rendered split(s) have no official counterpart (counted as differences)"
fi
# Every official APK must enter the comparison; a short pair list never reads as reproducible.
[[ ${#PAIRS[@]} -eq ${#OFFICIAL[@]} && ${#PAIRS[@]} -gt 0 ]] || nov "Only ${#PAIRS[@]} of ${#OFFICIAL[@]} official APK(s) paired."

phase "PHASE 2: COMPARISON"
# A raw diff is accepted only when a class with printed evidence earns it; everything else is material.
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
raw="$(expand_dirs <<<"$raw")" || { echo "FATAL: expand_dirs failed ($tag)"; exit 3; }; printf '%s\n' "$raw" | grep -v '^$' > "$out/diff_${tag}.txt"
n=$(printf '%s\n' "$raw" | grep -vc '^$')
# Native library evidence per differing .so (both sides): compiler stamp, build path.
: > "$out/native_${tag}.txt"; nso=0; nsm=0
while IFS= read -r so; do
  rel="${so#/tmp/o/}"; nso=$((nso+1))
  if [[ -f "/tmp/b/$rel" ]] && cmp -s "$so" "/tmp/b/$rel"; then nsm=$((nsm+1)); continue; fi
  for side in o b; do f="/tmp/$side/$rel"; [[ -f "$f" ]] || { echo "$rel [$side] MISSING" >> "$out/native_${tag}.txt"; continue; }
    cc="$(readelf -p .comment "$f" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | grep -oE 'clang version [0-9.]+|Android \([^)]*\)' | head -2 | paste -sd' ' -)"
    gp="$(strings "$f" | grep -oE '^/(opt|Users|home|root|bitrise|build|tmp|builds)/[^ ]*' | head -1 | cut -c1-60)"
    echo "$rel [$side] $(stat -c%s "$f") B; ${cc:-no .comment}; ${gp:-no build path}" >> "$out/native_${tag}.txt"; done
done < <(find /tmp/o -name '*.so' -type f | sort)
dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
js=""; [[ -f /tmp/o/assets/index.android.bundle ]] && js="index.android.bundle $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo same || echo DIFFERS)"
echo "  native libs ${nsm}/${nso} identical; dex differing: ${dx:-none}; JS: ${js:-none in this APK}"
# Earned classes. D5: root-level signature files present on the official side only.
c_sign=$(grep -cE '^Only in /tmp/o: META-INF/([^/ ]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$' <<<"$raw")
c_stamp=$(grep -cx 'Only in /tmp/o: stamp-cert-sha256' <<<"$raw"); c_mani=$(grep -c '^Files /tmp/o/AndroidManifest\.xml ' <<<"$raw"); c_arsc=$(grep -c '^Files /tmp/o/resources\.arsc ' <<<"$raw")
a_sign=$c_sign; a_stamp=0; a_mani=0; a_arsc=0
[[ $c_sign -gt 0 ]] && echo "      signing: ${c_sign} official-only root META-INF signature entr(ies); the rebuilt splits are unsigned"
if [[ $c_stamp -gt 0 ]]; then
  if [[ "$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null)" == "32" ]] && grep -q 'Verified for SourceStamp: true' <<<"$("$BT/apksigner" verify --verbose "$o" 2>/dev/null)"; then
    a_stamp=$c_stamp; echo "      stamp: official-only 32-byte stamp-cert-sha256, apksigner SourceStamp OK (Play injects it)"
  else echo "      stamp: NOT EARNED -> material"; fi
fi
# Manifest: drop an official meta-data block only if it is exactly one allowed name=value pair (stamp.source =
# Play URL, stamp.type = STAMP_TYPE_DISTRIBUTION_APK, vending.derived.apk.id = number); the rest must equal built.
if [[ $c_mani -gt 0 ]]; then
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null && "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null \
    && [[ -s /tmp/mo.txt && -s /tmp/mb.txt ]]; mrc=$?
  diff /tmp/mo.txt /tmp/mb.txt > "$out/diff_manifest_${tag}.txt"
  awk -v Q='"' 'function flush() { if (n) { if (n == 3 && ((nm == "com.android.stamp.source" && vl == Q "https://play.google.com/store" Q) || (nm == "com.android.stamp.type" && vl == Q "STAMP_TYPE_DISTRIBUTION_APK" Q) || (nm == "com.android.vending.derived.apk.id" && vl ~ /^[0-9]+$/))) k++; else printf "%s", buf }; n = 0; buf = "" }
    { match($0, /^ */); i = RLENGTH; if (n && i <= bi) flush() }
    !n && /^ *E: meta-data / { n = 1; bi = i; buf = $0 "\n"; nm = vl = ""; next }
    n { n++; buf = buf $0 "\n"; s = $0
      if (s ~ /android:name\(0x[0-9a-f]+\)="/) { sub(/.*android:name\(0x[0-9a-f]+\)="/, "", s); sub(/".*/, "", s); nm = s }
      else if (s ~ /android:value\(0x[0-9a-f]+\)=/) { sub(/.*android:value\(0x[0-9a-f]+\)=/, "", s); sub(/ \(Raw: .*$/, "", s); vl = s }
      next }
    { print }
    END { flush(); print k + 0 > "/tmp/mk.txt" }' /tmp/mo.txt > /tmp/mos.txt; arc=$?
  k="$(cat /tmp/mk.txt 2>/dev/null)"
  if [[ $mrc -eq 0 && $arc -eq 0 && "${k:-0}" -gt 0 ]] && cmp -s /tmp/mos.txt /tmp/mb.txt; then
    a_mani=$c_mani; echo "      manifest: equal after removing ${k} official-only Play meta-data block(s) with allowed values"
  else echo "      manifest: NOT EARNED -> material (diff_manifest_${tag}.txt)"; fi
fi
# D6: resources.arsc is judged only after apktool decodes both sides of this split.
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
acc=$((a_sign+a_stamp+a_mani+a_arsc)); un=$((n-acc)); [[ $un -lt 0 ]] && un=0
echo "TOTALS ${n} ${acc} ${un}" > "$out/summary_${tag}.txt"
echo "  raw ${n}, accepted ${acc}, unaccounted ${un}  (full list: diff_${tag}.txt)"
CMP_END
extra="${extra:-0}"; tot_raw=$extra; tot_acc=0; tot_un=$extra; pair_notes=""; [[ $extra -gt 0 ]] && pair_notes="${extra} rendered split(s) without official counterpart; "
files_lines=""; declare -a DIFFS=()
for p in "${PAIRS[@]}"; do
  o="${p%%|*}"; b="${p#*|}"; ptag="$(basename "$o" .apk)"; DIFFS+=("${CMP}/diff_${ptag}.txt")
  section "Comparing $(basename "$o") <-> $( [[ -n "$b" ]] && basename "$b" || echo '<no counterpart>' )"
  if [[ -z "$b" || ! -f "$b" ]]; then
    tot_un=$((tot_un+1)); tot_raw=$((tot_raw+1)); pair_notes+="${ptag}: no built counterpart (1 unaccounted); "
    echo "Only in official: $(basename "$o") (no rendered split)" > "${CMP}/diff_${ptag}.txt"
    files_lines+="$(basename "$o") - ${ptag} - none - 0 (DOESN'T MATCH)"$'\n'; continue
  fi
  ws_track_container "${CN}-cmp-${ptag}"
  crun "cmp-${ptag}" -v "${o}:/official.apk:ro" -v "${b}:/built.apk:ro" -v "${CMP}:/out" -v "${CTX}/compare.sh:/compare.sh:ro" \
    "$IMG" bash /compare.sh "$ptag" 2>&1 | tee -a "${CMP}/comparison.log" || true
  read -r _ r a u < "${CMP}/summary_${ptag}.txt" 2>/dev/null || nov "Comparison stage failed for ${ptag} (tooling, see comparison/comparison.log)."
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
 Build logs:           ${rel_ws}/built/build.log, container.log; codegen hashes: built/codegen.sha256
EOF
if [[ "$tot_raw" -gt 0 ]]; then
  echo " First raw differences (at most 5; full lists above):"
  cat "${DIFFS[@]}" 2>/dev/null | grep -v '^$' | head -5 | cut -c1-160 | sed 's/^/   /' || true
fi
n_skip="$(grep -c 'SKIP' "${BLD}/build.log" 2>/dev/null || true)"
echo " Upstream fidelity: CI=true and ccache CCACHE_BASEDIR (as Bitrise); 'SKIP' lines in build.log: ${n_skip:-0}"
if [[ "$tot_un" -eq 0 ]]; then verdict="reproducible"; rc=0; head_line="BUILDS MATCH BINARIES"
else verdict="not_reproducible"; rc=1; head_line="BUILDS DO NOT MATCH BINARIES"; fi
tagnote="tag ${tag} = ${tag_commit}"; [[ "$tag_commit" != "$commit" ]] && tagnote+=" (NOT the built commit)"
dot_note="recovered from ${main}"; [[ -n "$dotenv_arg" ]] && dot_note+=", overridden by --dotenv"
ws_write_yaml "$verdict" "${APP_ID} ${vname} (versionCode ${vcode}; ${MODE}) built from ${commit} (${rev_source}); ${tagnote}; rc tags: ${rc_tags:-none}.
Upstream Bitrise android workflow steps (yarn install --immutable, yarn setup, gradle :app:bundleExternalRelease, CI=true, ccache with CCACHE_BASEDIR as activate-build-cache-for-react-native); -PreactNativeArchitectures=${rn_archs} assumed from the android-internal workflow; APP_ENV ${app_env}.
Unpinned inputs: the rc tag Play promoted is not recorded anywhere public, and postinstall generates API clients from live schema URLs. Either can change the build output; any difference they cause is counted, not accepted.
.env.production ${dot_note}; google-services.json and build paths recovered from the official APK.
Official ${main} SHA-256 ${app_hash}, signer ${signer:-unknown}.
${pair_notes}
Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}."
echo ""
sig_line="$([[ "$tag_type" == commit ]] && echo 'lightweight tag (no signature possible)' || echo "${tag_type:-?} object")"
ws_results_block "$APP_ID" "${signer:-unknown}" "$vname" "$vcode" "$verdict" "$app_hash" "$commit" "${head_line}
${files_lines}Totals: raw ${tot_raw}, accepted ${tot_acc}, unaccounted ${tot_un}

Revision, tag (and its signature):
Built: ${commit} (${rev_source})
Tag ${tag}: ${sig_line} -> ${tag_commit}
Commit signature: ${commit_sig:-unknown} (checked against GitHub's web-flow key only)"
echo ""
echo "Hash legend: appHash = SHA-256 of the official ${main} exactly as supplied (publish this one)."
echo "Diff-line hashes: the rebuilt, unsigned bundletool splits (evidence only)."
echo "Release inputs: .env.production ${dot_note}; APP_ENV ${app_env}; Firebase values, dev IP ${dev_ip:-none} and build paths from ${main}"
[[ -z "$BUILD_LOCK_FILE" ]] || echo "build-lock.json (attach as output file): ${BUILD_LOCK_FILE}"
echo "Workspace: ${WS}"
exit "$rc"
