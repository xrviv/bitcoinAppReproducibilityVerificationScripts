#!/usr/bin/env bash
# bitcoinkeeper-v0.3.0_build.sh - Bitcoin Keeper (Android) reproducible build verification
# Version:          v0.3.0
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-24
# Organization:     WalletScrutiny.com
# App ID:           io.hexawallet.bitcoinkeeper
# Project:          https://github.com/KeeperCommunity/bitcoin-keeper
# License: MIT, no warranty. Mirrors the official artifact's build inputs, builds in a pinned container
# (fat APK or AAB + bundletool), compares entry by entry. Library ws-rb-core (#1023), per-run workspace in
# the caller's directory; build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library.

SCRIPT_NAME="bitcoinkeeper-v0.3.0_build.sh"
SCRIPT_VERSION="v0.3.0"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "${SCRIPT_NAME} ${SCRIPT_VERSION} sha256:${SCRIPT_SHA256}"

# No -e: diff and cmp return 1 on legitimate differences.
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

APP_ID="io.hexawallet.bitcoinkeeper"
REPO_URL="https://github.com/KeeperCommunity/bitcoin-keeper"
BUILD_HOME="/Users/vaibhav"; SRC_DIR=""; NODE_VERSION=""
BT_VER="1.18.3"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
BG_PID=""; workspace=""; IMG=""

banner() { printf '\n== %s ==\n' "$*"; }
section() { printf -- '\n-- %s --\n' "$*"; }
phase() { banner "$*"; echo "  $(date)"; }
nov() { ws_no_verdict "$1"; }   # runtime, network, tool or input problem: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML
ftbfs() { ws_error "$1"; ws_write_yaml ftbfs "$2"; exit 1; }   # the source itself does not build

ws_refuse_root
ws_install_traps

version_arg=""; binary_arg=""; arch_arg=""; rev_arg="${WS_GIT_REVISION:-}"; node_arg="${WS_NODE_VERSION:-}"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <GitHub APK | Play split dir> [--git-revision <sha>]
 [--node-version <x.y.z>] [--version <x.y.z>] [--arch <abi>] [--type <t>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      ws_require_value --version "${2:-}"; version_arg="$2"; shift 2 ;;
    --binary|--apk) ws_require_value "$1" "${2:-}"; binary_arg="$2";  shift 2 ;;
    --arch)         ws_require_value --arch    "${2:-}"; arch_arg="$2";    shift 2 ;;
    --type)         ws_require_value --type    "${2:-}"; shift 2 ;;
    --git-revision) ws_require_value --git-revision "${2:-}"; rev_arg="$2"; shift 2 ;;
    --node-version) ws_require_value --node-version "${2:-}"; node_arg="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;
  esac
done

[[ -n "$binary_arg" ]] || inv "--binary is required (official GitHub APK or Play split directory)"
[[ -e "$binary_arg" ]] || inv "--binary path does not exist: ${binary_arg}"
binary_is_dir=0
if [[ -d "$binary_arg" ]]; then
  binary_arg="${binary_arg%/}"
  [[ -f "${binary_arg}/base.apk" ]] || inv "--binary directory contains no base.apk: ${binary_arg}"
  binary_is_dir=1
fi
[[ "$binary_is_dir" -eq 1 || -f "$binary_arg" ]] || inv "--binary is not a regular file: ${binary_arg}"
[[ -z "$rev_arg" || "$rev_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || inv "--git-revision must be 7-40 hex characters (got: '${rev_arg}')"
[[ -z "$node_arg" || "$node_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || inv "--node-version must be x.y.z (got: '${node_arg}')"
[[ -z "$version_arg" || "$version_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || inv "--version must be x.y.z (got: '${version_arg}')"
binary_path="$(realpath "$binary_arg")"

ws_results_init
ws_engine
command -v unzip >/dev/null || nov "unzip is required on the host (reads the official APKs)"
command -v curl >/dev/null || nov "curl is required on the host (fetches ws-buildlock.sh)"
CTR=(docker); [[ "$WS_ENGINE" == podman ]] && CTR=(podman --cgroup-manager=cgroupfs)
if [[ "$WS_ENGINE" == podman ]]; then
  RUN_USER_ARGS=(--userns=keep-id)
elif [[ "$(ws_ctr info -f '{{.SecurityOptions}}' 2>/dev/null || true)" == *rootless* ]]; then RUN_USER_ARGS=(--user 0:0)
else RUN_USER_ARGS=(--user "${HOST_UID}:${HOST_GID}"); fi

IMG="ws-bitcoinkeeper-${WS_RUN_ID}"
ws_track_image "$IMG"   # removed at exit; docker hand-back runs chown in it first
for c in meta build lock render cmp; do ws_track_container "${IMG}-${c}"; done
ws_workspace bitcoinkeeper "${version_arg:-artifact}"
workspace="$WS_WORKDIR"
META_DIR="${workspace}/metadata"; BUILD_DIR="${workspace}/source-build"; CMP_DIR="${workspace}/comparison"
OFF_DIR="${workspace}/official"; BUILT_DIR="${workspace}/built"; img_ctx="${workspace}/context"
GRADLE_DIR="${workspace}/gradle-home"; BL_DIR="${workspace}/build-lock"
mkdir -p "$META_DIR" "$BUILD_DIR" "$CMP_DIR" "$OFF_DIR" "$BUILT_DIR" "$img_ctx" "$GRADLE_DIR" "$BL_DIR"

# Background + wait: a signal acts at once; the exit hook stops and reaps it.
bg_wait() { local rc=0; "$@" & BG_PID=$!; wait "$BG_PID" || rc=$?; BG_PID=""; return $rc; }
ws_cleanup_hook() { [[ -z "$BG_PID" ]] || { kill "$BG_PID"; wait "$BG_PID"; } 2>/dev/null || true; }
# ctr_run STAGE LOG ARGS...: container exit code; 90 if the log was not written.
ctr_run() {
  local n="${IMG}-$1" l="$2" rc=0; shift 2
  bg_wait bash -c 'l="$1"; shift; "$@" 2>&1 | tee "$l"; s=("${PIPESTATUS[@]}"); [[ ${s[1]} == 0 ]] || exit 90; exit "${s[0]}"' _ "$l" \
    "${CTR[@]}" run --rm --name "$n" "${RUN_USER_ARGS[@]}" -e "HOME=${BUILD_HOME}" "$@" || rc=$?
  return $rc
}

canonical_name() {
  case "$1" in
    base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
    split_config.*.apk) echo "$1" ;;
    base-*.apk) echo "split_config.${1#base-}" ;;
    *) echo "$1" ;;
  esac
}
abi_of() { case "$1" in arm64_v8a) echo arm64-v8a ;; armeabi_v7a) echo armeabi-v7a ;; *) echo "$1" ;; esac; }
label_of() { local n="${1%.apk}"; n="${n#split_config.}"; echo "${n//[^A-Za-z0-9_]/_}"; }

if [[ "$binary_is_dir" -eq 1 ]]; then
  n_apk=0
  for f in "${binary_path}"/*.apk; do
    [[ -f "$f" ]] || continue
    cn="$(canonical_name "$(basename "$f")")"
    [[ ! -e "${OFF_DIR}/${cn}" ]] || inv "Two files in --binary map to ${cn}"
    cp "$f" "${OFF_DIR}/${cn}"
    n_apk=$((n_apk + 1))
  done
  ws_info "Collected ${n_apk} official APK(s) from ${binary_path}"
else
  cp "$binary_path" "${OFF_DIR}/$(canonical_name "$(basename "$binary_path")")"
fi
official_base="${OFF_DIR}/base.apk"
[[ -f "$official_base" ]] || official_base="$(find "$OFF_DIR" -maxdepth 1 -name '*.apk' -type f | sort | head -1 || true)"
[[ -n "$official_base" ]] || inv "--binary holds no .apk file: ${binary_path}"

section "BUILD-MACHINE INPUTS READ FROM THE OFFICIAL ARTIFACT"
so_src=""
for f in "${OFF_DIR}"/*.apk; do [[ "$(unzip -Z1 "$f" 2>/dev/null | grep -c '^lib/' || true)" -gt 0 ]] && { so_src="$f"; break; }; done
if [[ -n "$so_src" ]]; then
  so_paths="$(unzip -p "$so_src" 'lib/*/librealm.so' 'lib/*/libappmodules.so' 2>/dev/null | grep -aoE '/(Users|home)/[[:graph:]]*' | sort -u || true)"
  p="$(printf '%s\n' "$so_paths" | grep -oE '^.*/node_modules/realm/' | head -1 | sed 's|/node_modules/realm/$||' || true)"
  h="$(printf '%s\n' "$so_paths" | grep -oE '^/(Users|home)/[^/]+/\.gradle/' | head -1 | sed 's|/\.gradle/$||' || true)"
  [[ -n "$h" ]] && BUILD_HOME="$h" || ws_warn "No Gradle cache path in the official native libs; default HOME"
  [[ -n "$p" ]] && SRC_DIR="$p" || ws_warn "No checkout path in the official librealm.so; default \$HOME/bitcoin-keeper"
else
  ws_warn "No official APK carries lib/: build-machine paths default to HOME=${BUILD_HOME}"
fi
[[ -z "$SRC_DIR" ]] && SRC_DIR="${BUILD_HOME}/bitcoin-keeper"
node_cands="$(unzip -p "$official_base" assets/index.android.bundle 2>/dev/null | grep -aoE 'v[0-9]{2}\.[0-9]+\.[0-9]+' | sort -u | sort -t. -k1.2,1n -k2,2n -k3,3n | paste -sd' ' - || true)"
if [[ -n "$node_arg" ]]; then NODE_VERSION="$node_arg"; node_src="--node-version"
elif [[ -n "$node_cands" ]]; then NODE_VERSION="${node_cands##* }"; NODE_VERSION="${NODE_VERSION#v}"; node_src="official Hermes bundle"
else NODE_VERSION="22.23.3"; node_src="default, none in the official bundle"; fi
echo "  HOME (Gradle cache): ${BUILD_HOME}"; echo "  Checkout path:       ${SRC_DIR}"
echo "  Node:                v${NODE_VERSION} (${node_src}; bundle candidates: ${node_cands:-none})"
NM_LINK="$(unzip -p "$official_base" assets/index.android.bundle 2>/dev/null | grep -aoE '/assets/(\.\./)+([A-Za-z0-9_.-]+/)*node_modules/' | sed -E 's|^/assets/||; s|/$||' | sort -u | head -1 || true)"
NM_PARENT=""; [[ -n "$NM_LINK" ]] && NM_PARENT=" $(dirname "$(realpath -m "${SRC_DIR}/${NM_LINK}")")"
echo "  node_modules link:   ${NM_LINK:-none (node_modules inside the checkout)}"
ok_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1/" != */../* ]]; }
ok_path "$BUILD_HOME" && ok_path "$SRC_DIR" && { [[ -z "$NM_PARENT" ]] || ok_path "${NM_PARENT# }"; } \
  || inv "Unsafe build-machine path read from the official APK: ${BUILD_HOME} ${SRC_DIR}${NM_PARENT}"

banner "BITCOIN KEEPER - ANDROID VERIFICATION"
cat <<EOF
 App ID:    ${APP_ID}
 Input:     ${binary_path}$( [[ "$binary_is_dir" -eq 1 ]] && echo " (split set)" )
 Runtime:   ${WS_ENGINE} ($(ws_ctr --version 2>&1 | head -1 || true))
EOF

phase "SETUP: BUILD CONTAINER IMAGE"

cat > "${img_ctx}/Dockerfile" <<DOCKERFILE_END
FROM ubuntu:24.04@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \\
    git unzip zip wget curl ca-certificates xz-utils python3 libatomic1 && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && \\
  wget -q https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt && \\
  grep " node-v${NODE_VERSION}-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c - && \\
  mkdir -p /opt/node && tar -xJf node-v${NODE_VERSION}-linux-x64.tar.xz -C /opt/node --strip-components=1 && \\
  rm node-v${NODE_VERSION}-linux-x64.tar.xz SHASUMS256.txt && PATH=/opt/node/bin:\$PATH npm install -g yarn@1.22.22 >/dev/null
RUN cd /tmp && \\
  wget -q -O jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz" && \\
  echo "d8afc263758141a66e0e3aafc321e783f7016696f4eaea067d340a269037d331  jdk.tar.gz" | sha256sum -c - && \\
  mkdir -p /opt/jdk && tar -xzf jdk.tar.gz -C /opt/jdk --strip-components=1 && rm jdk.tar.gz
ENV JAVA_HOME=/opt/jdk ANDROID_HOME=/opt/android-sdk
ENV PATH="/opt/node/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/jdk/bin:\${PATH}"
RUN mkdir -p \${ANDROID_HOME}/cmdline-tools && cd \${ANDROID_HOME}/cmdline-tools && \\
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O ct.zip && \\
  echo "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258  ct.zip" | sha256sum -c - && \\
  unzip -q ct.zip && rm ct.zip && mv cmdline-tools latest
RUN yes | sdkmanager --licenses >/dev/null && \\
  sdkmanager "platforms;android-36" "platforms;android-33" "build-tools;35.0.0" "build-tools;36.0.0" "platform-tools" \\
    "ndk;27.1.12297006" "ndk;27.0.12077973" "cmake;3.22.1" >/dev/null && chmod -R a+rX \${ANDROID_HOME}
RUN cd /opt && \\
  wget -q -O apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar && \\
  echo "dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423  apktool.jar" | sha256sum -c - && \\
  wget -q -O bundletool.jar https://github.com/google/bundletool/releases/download/${BT_VER}/bundletool-all-${BT_VER}.jar && \\
  echo "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29  bundletool.jar" | sha256sum -c - && \\
  chmod 0644 apktool.jar bundletool.jar
RUN mkdir -p /tmp/afw ${BUILD_HOME} $(dirname "${SRC_DIR}")${NM_PARENT} && chmod 0777 /tmp /tmp/afw ${BUILD_HOME} $(dirname "${SRC_DIR}")${NM_PARENT}
WORKDIR ${BUILD_HOME}
DOCKERFILE_END

section "Building image ${IMG}"
bg_wait "${CTR[@]}" build -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx" || nov "Container image build failed - see the output above"

ws_ok "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL BINARY METADATA"

cat > "${img_ctx}/buildconfig.py" <<'PY_END'
import struct, sys, zipfile
CLS = 'Lio/hexawallet/keeper/BuildConfig;'
def uleb(b, o):
 r = s = 0
 while True:
  c = b[o]; o += 1; r |= (c & 0x7f) << s; s += 7
  if not c & 0x80: return r, o
def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def fields_of(b):
 sn, so = u32(b, 56), u32(b, 60)
 S = []
 for i in range(sn):
  p = uleb(b, u32(b, so + 4 * i))[1]; S.append(b[p:b.index(b'\0', p)].decode('utf-8', 'replace'))
 tn, to = u32(b, 64), u32(b, 68); T = [S[u32(b, to + 4 * i)] for i in range(tn)]
 fn, fo = u32(b, 80), u32(b, 84)
 F = [(S[u32(b, fo + 8 * i + 4)], T[struct.unpack_from('<H', b, fo + 8 * i + 2)[0]]) for i in range(fn)]
 cn, co = u32(b, 96), u32(b, 100)
 for i in range(cn):
  c = struct.unpack_from('<8I', b, co + 32 * i)
  if T[c[0]] != CLS or not c[6]: continue
  o = c[6]; nsf, o = uleb(b, o); o = uleb(b, uleb(b, uleb(b, o)[1])[1])[1]
  ids, idx = [], 0
  for _ in range(nsf):
   d, o = uleb(b, o); idx += d; ids.append(idx); o = uleb(b, o)[1]
  vals = []
  if c[7]:
   n, o = uleb(b, c[7])
   for _ in range(n):
    h = b[o]; o += 1; vt, va = h & 0x1f, h >> 5
    if vt == 0x17: vals.append(S[int.from_bytes(b[o:o + va + 1], 'little')])
    else: vals.append('')
    if vt != 0x1f: o += va + 1
  return [(F[f][0], F[f][1], v) for f, v in zip(ids, vals)]
 return None
z = zipfile.ZipFile(sys.argv[1])
for n in sorted(z.namelist()):
 if n.startswith('classes') and n.endswith('.dex'):
  r = fields_of(z.read(n))
  if r is not None:
   print('#dex', n)
   for name, typ, val in r: print('%s\t%s\t%s' % (name, typ, val))
   sys.exit(0)
sys.exit(3)
PY_END

cat > "${img_ctx}/meta.sh" <<'META_END'
#!/bin/bash
set -uo pipefail
BT="${ANDROID_HOME}/build-tools/36.0.0"
A="/input/$BASE"
info="$("$BT/aapt2" dump badging "$A" 2>/dev/null)"
pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"
minsdk="$(printf '%s\n' "$info" | sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" | head -1)"
split_name="$(printf '%s\n' "$info" | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
abis="$(printf '%s\n' "$info" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
sv="$("$BT/apksigner" verify --verbose --print-certs "$A" 2>/dev/null)" || { echo "[META] apksigner verify FAILED"; exit 4; }
signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"
[[ "$signer" =~ ^[0-9a-f]{64}$ ]] || { echo "[META] no signer digest"; exit 4; }
for s in /input/*.apk; do
  [[ "$s" == "$A" ]] && continue
  i="$("$BT/aapt2" dump badging "$s" 2>/dev/null | grep '^package:')"
  w="$(basename "$s" .apk)"; w="config.${w#split_config.}"
  [[ "$i" == *"name='$pkg' "* && "$i" == *"versionCode='$vcode' "* && "$i" == *"split='$w'"* ]] || { echo "[META] $s: package, versionCode or split name differs"; exit 4; }
  ss="$("$BT/apksigner" verify --print-certs "$s" 2>/dev/null)" && [[ "$(awk '/Signer #1 certificate SHA-256/ {print $NF; exit}' <<< "$ss")" == "$signer" ]] \
    || { echo "[META] $s: not verified with signer ${signer}"; exit 4; }
done
stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
# grep -c reads to EOF (grep -q would SIGPIPE unzip under pipefail).
has_lib=0; [[ "$(unzip -Z1 "$A" 2>/dev/null | grep -c '^lib/')" -gt 0 ]] && has_lib=1
vcs="$(unzip -p "$A" META-INF/version-control-info.textproto 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
agp="$(unzip -p "$A" META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null | sed -n 's/^androidGradlePluginVersion=//p' | head -1)"
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$A" > /output/manifest-official.txt 2>/dev/null
fused="$(grep -c 'com.android.dynamic.apk.fused.modules' /output/manifest-official.txt)"
devip="$("$BT/aapt2" dump resources "$A" 2>/dev/null | grep -A1 'string/react_native_dev_server_ip' | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)"

python3 /buildconfig.py "$A" > /output/buildconfig.txt 2>/output/buildconfig.err
bc_rc=$?
: > /output/dotenv; chmod 0600 /output/dotenv
nenv=0; keys=""
if [[ $bc_rc -eq 0 ]]; then
  while IFS=$'\t' read -r name typ val; do
    [[ "$typ" == "Ljava/lang/String;" ]] || continue
    case "$name" in APPLICATION_ID|BUILD_TYPE|FLAVOR|VERSION_NAME) continue ;; esac
    printf '%s=%s\n' "$name" "$val" >> /output/dotenv; nenv=$((nenv + 1)); keys="${keys}${name} "
  done < <(grep -v '^#' /output/buildconfig.txt)
fi
for kv in "pkg_name:${pkg:-unknown}" "version_name:${vname:-unknown}" "version_code:${vcode:-unknown}" \
  "signer:${signer:-unknown}" "split_name:${split_name}" "agp:${agp}" "abis:${abis}" "fused:${fused}" \
  "has_lib:${has_lib}" "min_sdk:${minsdk}" "dev_ip:${devip}" "nenv:${nenv}"; do
  printf '%s\n' "${kv#*:}" > "/output/${kv%%:*}.txt"
done
cat <<META
[META] package: ${pkg:-unknown}
[META] versionName: ${vname:-unknown}
[META] versionCode: ${vcode:-unknown}
[META] minSdkVersion: ${minsdk:-?}
[META] native ABIs: ${abis:-<none>} (has lib/: ${has_lib} = fat APK; fused.modules: ${fused})
[META] signer SHA-256: ${signer:-unknown}
[META] SourceStamp: ${stamp} (apksigner)
[META] VCS info: ${vcs:-<none>} (META-INF/version-control-info.textproto)
[META] BuildConfig .env: ${nenv} key(s) recovered from $(grep '^#dex' /output/buildconfig.txt 2>/dev/null | cut -d' ' -f2) (exit ${bc_rc}); values stay in metadata/dotenv
[META] .env keys: ${keys:-<none>}
META
META_END

m_rc=0; ctr_run meta "${META_DIR}/meta.log" -e "BASE=$(basename "$official_base")" \
  --volume "${OFF_DIR}:/input:ro" --volume "${META_DIR}:/output" \
  --volume "${img_ctx}/meta.sh:/meta.sh:ro" --volume "${img_ctx}/buildconfig.py:/buildconfig.py:ro" \
  "$IMG" bash /meta.sh || m_rc=$?
[[ $m_rc -ne 4 ]] || inv "The official APKs do not verify as one signed set (see ${META_DIR}/meta.log)"
[[ $m_rc -eq 0 ]] || nov "Metadata extraction failed (exit ${m_rc}; see ${META_DIR}/meta.log)"

meta() { local v; v="$(cat "${META_DIR}/$1.txt" 2>/dev/null || true)"; [[ -n "$v" ]] && echo "$v" || echo "${2:-}"; }
pkg_id="$(meta pkg_name unknown)"; wallet_version="$(meta version_name unknown)"; version_code="$(meta version_code unknown)"
signer="$(meta signer unknown)"; official_agp="$(meta agp)"; dev_ip="$(meta dev_ip)"; split_name="$(meta split_name)"
has_lib="$(meta has_lib 0)"; min_sdk="$(meta min_sdk 26)"; n_env="$(meta nenv 0)"; abis_csv="$(meta abis)"
base_hash="$(ws_sha256 "$official_base")"

[[ "$pkg_id" == "$APP_ID" ]] || inv "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
ws_ok "Package name verified: ${pkg_id}"
ws_ok "Version: $wallet_version (versionCode $version_code)"
ws_info    "Signer SHA-256:   ${signer}"
ws_info    "base APK SHA-256: ${base_hash}"
[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || inv "Could not read versionName from the APK"
[[ "$version_code" =~ ^[0-9]+$ ]] || inv "Could not read versionCode from the APK"
[[ "$wallet_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || inv "versionName '${wallet_version}' is not x.y.z"
[[ -z "$version_arg" || "$version_arg" == "$wallet_version" ]] || inv "--version ${version_arg}, but the APK is ${wallet_version}"
[[ -z "$split_name" ]] || inv "$(basename "$official_base") is the config split '${split_name}'; pass the directory with base.apk"
[[ "$(meta fused 0)" -eq 0 ]] || inv "fused.modules present: a bundletool universal APK; pass the Play split set or the GitHub APK"
[[ "$n_env" -gt 0 ]] || nov "No react-native-config keys in the official BuildConfig (metadata/buildconfig.err); build not attempted"

if [[ "$has_lib" -eq 1 ]]; then
  build_mode="apk"; gradle_task="assembleProductionRelease"
  [[ "$binary_is_dir" -eq 1 ]] && ws_warn "base.apk carries lib/: fat APK; other files ignored"
  ws_info "Mode: fat APK (GitHub release layout) -> ${gradle_task}"
else
  build_mode="bundle"; gradle_task="bundleProductionRelease"
  ws_info "Mode: Play split set -> ${gradle_task} + bundletool ${BT_VER}"
  [[ "$binary_is_dir" -eq 1 ]] || ws_warn "Single split supplied: only base.apk is verified"
  abis_csv=""; for f in "${OFF_DIR}"/split_config.{arm64_v8a,armeabi_v7a,x86_64,x86}.apk; do [[ -f "$f" ]] && { a="${f##*split_config.}"; abis_csv+="$(abi_of "${a%.apk}"),"; }; done
fi
if [[ -n "$arch_arg" ]]; then
  a="$(abi_of "$arch_arg")"
  if [[ ",${abis_csv}," == *",${a},"* ]]; then ws_info "--arch ${arch_arg} is among the binary's ABIs (${abis_csv})"
  else inv "--arch ${arch_arg} is not among the binary's ABIs (${abis_csv:-none})"; fi
fi

rev_source="tag v${wallet_version}, else newest default-branch commit declaring it"; [[ -z "$rev_arg" ]] || rev_source="--git-revision"
echo "  Revision: ${rev_arg:-<resolved in container>} (${rev_source})"

phase "PHASE 1: BUILD FROM SOURCE"

cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
REPO_URL="__REPO_URL__"; WANT_VNAME="__WANT_VNAME__"; WANT_VCODE="__WANT_VCODE__"
DEV_IP="__DEV_IP__"; GRADLE_TASK="__GRADLE_TASK__"; SRC="__SRC_DIR__"
export GRADLE_USER_HOME="$HOME/.gradle"
mkdir -p "$GRADLE_USER_HOME"
git config --global --add safe.directory '*'

echo "=== Clone ${REPO_URL} === $(date)"
git clone "$REPO_URL" "$SRC" || { echo "FATAL: clone failed"; exit 1; }
cd "$SRC"
default_branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
default_branch="${default_branch:-main}"
gradle_field() { git show "$2:android/app/build.gradle" 2>/dev/null | sed -n "s/^ *$1 *\"\{0,1\}\([^\" ]*\)\"\{0,1\}.*/\1/p" | head -1; }

GIT_REF="${WS_GIT_REVISION:-}"
if [[ -n "$GIT_REF" ]]; then
  git rev-parse -q --verify "${GIT_REF}^{commit}" >/dev/null || git fetch -q origin "$GIT_REF" 2>/dev/null
  if ! GIT_REF="$(git rev-parse -q --verify "${GIT_REF}^{commit}")"; then
    echo "FATAL: revision ${WS_GIT_REVISION} is not in the public repository ${REPO_URL}."; exit 4
  fi
  echo "=== Pinned revision ${GIT_REF} (--git-revision) ==="; echo "pinned by --git-revision" > /output/ref_note.txt
elif git rev-parse -q --verify "refs/tags/v${WANT_VNAME}^{commit}" >/dev/null; then
  GIT_REF="$(git rev-parse "refs/tags/v${WANT_VNAME}^{commit}")"
  echo "=== Tag v${WANT_VNAME} -> ${GIT_REF} ($(git cat-file -t "refs/tags/v${WANT_VNAME}") tag) ==="
  [[ "$(git cat-file -t "refs/tags/v${WANT_VNAME}")" == tag ]] && n="annotated, signature not checked" || n="lightweight, no signature possible"
  echo "tag v${WANT_VNAME}, ${n}" > /output/ref_note.txt
else
  echo "=== No tag v${WANT_VNAME}: searching first-parent ${default_branch} for versionName ${WANT_VNAME} + versionCode ${WANT_VCODE} ==="
  GIT_REF=""; loose=""; amb=""
  for c in $(git rev-list --first-parent "origin/${default_branch}"); do
    vn="$(gradle_field versionName "$c")"
    [[ "$vn" == "$WANT_VNAME" ]] || { [[ -n "$loose" ]] && break; continue; }
    [[ -z "$loose" ]] && loose="$c"
    if [[ "$(gradle_field versionCode "$c")" == "$WANT_VCODE" ]]; then GIT_REF="$c"; break; fi
  done
  if [[ -z "$GIT_REF" && -n "$loose" ]]; then
    GIT_REF="$loose"; amb=", versionCode not matched"
    echo "AMBIGUOUS: no commit declares versionCode ${WANT_VCODE}; newest with versionName ${WANT_VNAME} used"
  fi
  [[ -n "$GIT_REF" ]] || { echo "FATAL: no commit on ${default_branch} declares versionName ${WANT_VNAME}"; exit 4; }
  echo "no tag v${WANT_VNAME}; newest ${default_branch} commit declaring it${amb}" > /output/ref_note.txt
fi
echo "Building: ${GIT_REF}"
git checkout -q "$GIT_REF" || { echo "FATAL: could not check out ${GIT_REF}"; exit 2; }
echo "=== Revision under build ==="
git log -1 --pretty=format:'%H %ci %s'; echo
git rev-parse HEAD > /output/commit.txt
git merge-base --is-ancestor HEAD "origin/${default_branch}" 2>/dev/null || echo "  NOTE: not reachable from origin/${default_branch}"

echo "=== Toolchain ==="; node --version; yarn --version; java -version 2>&1 | head -1
echo "  NDK $(sed -n 's/^ *ndkVersion *= *"\([^"]*\)".*/\1/p' android/build.gradle)  Gradle $(sed -n 's|.*gradle-\([0-9.]*\)-.*|\1|p' android/gradle/wrapper/gradle-wrapper.properties)"

cp /dotenv .env
echo "=== .env restored from the official BuildConfig: $(wc -l < .env) keys ==="

echo "=== yarn install --frozen-lockfile === $(date)"
# prepare hook: rn-nodeify, pod install attempt, macOS sdk.dir (replaced below).
yarn install --frozen-lockfile --non-interactive --ignore-engines > /output/yarn-install.log 2>&1 || { tail -40 /output/yarn-install.log; echo "FATAL: yarn install failed"; exit 5; }
tail -3 /output/yarn-install.log
NM="__NM_LINK__"
if [[ -n "$NM" ]]; then
  mkdir -p "$(dirname "$NM")" && mv node_modules "$NM" && ln -s "$NM" node_modules || { echo "FATAL: node_modules relocation to ${NM} failed"; exit 6; }
  printf '\n// walletscrutiny: watch folder of the official layout\nmodule.exports.watchFolders = [...(module.exports.watchFolders || []), require("path").resolve(__dirname, "%s")];\n' "$NM" >> metro.config.js
  echo "  node_modules -> $(readlink -f node_modules) (Metro watch folder added)"
fi
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > android/local.properties
agp="$(sed -n 's/^agp *= *"\([^"]*\)".*/\1/p' node_modules/@react-native/gradle-plugin/gradle/libs.versions.toml 2>/dev/null)"
printf '%s\n' "$agp" > /output/agp.txt
echo "  AGP from react-native gradle-plugin: ${agp:-?}"

# fastlane bumps versionCode uncommitted: the artifact's values rule.
for kv in "versionCode ${WANT_VCODE}" "versionName \"${WANT_VNAME}\""; do
  sed -i -E "s/^( *)${kv%% *}[[:space:]]+.*/\1${kv}/" android/app/build.gradle
done
# react_native_dev_server_ip = the build host's IPv4: set to the official value.
[[ -n "$DEV_IP" ]] && printf '\n// walletscrutiny: dev-server IP of the official artifact\nandroidComponents { onVariants(selector().all()) { v -> v.resValues.put(v.makeResValueKey("string", "react_native_dev_server_ip"), new com.android.build.api.variant.ResValue("%s", null)) } }\n' "$DEV_IP" >> android/app/build.gradle
echo "=== Working tree changes before Gradle ==="
git status --porcelain | grep -v -E '^\?\? (\.env|android/local\.properties)$' | head -5
git diff | grep -E '^[-+] ' | grep -v "${DEV_IP:-__none__}" | head -6
# Official version-control-info says NO_SUPPORTED_VCS_FOUND: built outside git, so here too.
rm -rf .git

echo "=== Gradle ${GRADLE_TASK} === $(date)"
cd android
keytool -genkeypair -keystore /tmp/ws.jks -storepass wsverify -alias ws -keyalg RSA -dname CN=WS >/dev/null 2>&1
KEEPER_ANDROID_KEYSTORE=/tmp/ws.jks STORE_PASSWORD=wsverify KEY_ALIAS=ws KEY_PASSWORD=wsverify \
./gradlew "$GRADLE_TASK" -PMYAPP_RELEASE_STORE_FILE=/tmp/ws.jks -PMYAPP_RELEASE_KEY_ALIAS=ws -PMYAPP_RELEASE_STORE_PASSWORD=wsverify \
  -PMYAPP_RELEASE_KEY_PASSWORD=wsverify --no-daemon --stacktrace --console=plain > /output/gradle-build.log 2>&1
rc=$?
grep -E '^> Task :app:(createBundle|externalNativeBuild|package|bundle)|BUILD (SUCCESSFUL|FAILED)|FAILURE|What went wrong' /output/gradle-build.log | head -12
if [[ $rc -ne 0 ]]; then
  tail -40 /output/gradle-build.log
  echo "FATAL: gradle build failed (exit ${rc}) - full log at /output/gradle-build.log"; exit 3
fi
if [[ "$GRADLE_TASK" == "bundleProductionRelease" ]]; then
  out="$(ls app/build/outputs/bundle/productionRelease/*.aab 2>/dev/null | head -1)"
  [[ -n "$out" ]] || { echo "FATAL: no AAB under app/build/outputs/bundle/productionRelease"; exit 6; }
  cp "$out" /output/built.aab || exit 6
else
  out="$(ls app/build/outputs/apk/production/release/*.apk 2>/dev/null | head -1)"
  [[ -n "$out" ]] || { echo "FATAL: no APK under app/build/outputs/apk/production/release"; exit 6; }
  cp "$out" /output/built.apk || exit 6
fi
echo "=== built: $(basename "$out")  sha256 $(sha256sum "$out" | cut -d' ' -f1)"
echo "=== Build complete $(date) ==="
BUILD_END

sed -i -e "s|__REPO_URL__|${REPO_URL}|g" -e "s|__WANT_VNAME__|$wallet_version|g" -e "s|__WANT_VCODE__|$version_code|g" \
  -e "s|__DEV_IP__|$dev_ip|g" -e "s|__SRC_DIR__|$SRC_DIR|g" -e "s|__NM_LINK__|$NM_LINK|g" -e "s|__GRADLE_TASK__|$gradle_task|g" "${img_ctx}/build.sh"

section "Source build (30-90 min cold) - $(date)"
BUILD_RC=0
ctr_run build "${BUILD_DIR}/container-build.log" \
  -e "WS_GIT_REVISION=${rev_arg}" --volume "${BUILD_DIR}:/output" --volume "${GRADLE_DIR}:${BUILD_HOME}/.gradle" \
  --volume "${META_DIR}/dotenv:/dotenv:ro" --volume "${img_ctx}/build.sh:/build.sh:ro" \
  "$IMG" bash /build.sh || BUILD_RC=$?
case "$BUILD_RC" in
  0) ;;
  1) nov "Clone of ${REPO_URL} failed (see output above)" ;;
  2) nov "Checkout of the resolved revision failed (see output above)" ;;
  4) nov "The source revision could not be pinned (${rev_source}${rev_arg:+: $rev_arg}); source and artifact identity unresolved" ;;
  5) nov "yarn install failed (see ${BUILD_DIR}/yarn-install.log)" ;;
  3) kind="$(ws_gradle_failure_kind "${BUILD_DIR}/gradle-build.log")"
     [[ "$kind" == source ]] || nov "Gradle build failed, cause ${kind} (see ${BUILD_DIR}/gradle-build.log)"
     ftbfs "Gradle build failed with a source diagnostic (see ${BUILD_DIR}/gradle-build.log)" \
       "Gradle ${gradle_task} failed with a compiler or resource error for ${APP_ID} ${wallet_version}; official base APK SHA-256 ${base_hash}." ;;
  *) nov "Build container failed (exit ${BUILD_RC}; see ${BUILD_DIR}/container-build.log)" ;;
esac
commit="$(cat "${BUILD_DIR}/commit.txt" 2>/dev/null || true)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || nov "The build wrote no commit (${BUILD_DIR}/commit.txt)"
ws_ok "Source build finished"

built_agp="$(cat "${BUILD_DIR}/agp.txt" 2>/dev/null || true)"
[[ -z "$official_agp" || "$official_agp" == "$built_agp" ]] || ws_warn "AGP MISMATCH: official ${official_agp}, revision ${built_agp}"
ws_info "AGP: artifact ${official_agp:-?}, revision ${built_agp:-?}"

section "BUILD RECORD (ws-buildlock, verdict unaffected)"
BUILD_LOCK_FILE=""; BL_SH="${img_ctx}/ws-buildlock.sh"; bl_rc=0
if curl -fsSL --max-time 60 -o "$BL_SH" "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" < /dev/null \
   && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
  ctr_run lock "${workspace}/build-lock.log" -v "${GRADLE_DIR}:/gradle-home:ro" -v "${BL_DIR}:/build-lock" -v "${BL_SH}:/ws-buildlock.sh:ro" \
    "$IMG" bash /ws-buildlock.sh --out /build-lock --gradle-home /gradle-home --app-id "$APP_ID" \
    --version "$wallet_version" --platform android --commit "$commit" > /dev/null || bl_rc=$?
  if [[ "$bl_rc" -eq 0 && -s "${BL_DIR}/build-lock.json" ]] && ! grep -q 'nothing recorded' "${workspace}/build-lock.log"; then
    bl_n=$(grep -o '"ecosystem": *"gradle"' "${BL_DIR}/build-lock.json" | wc -l || true)
    if [[ "${bl_n:-0}" -gt 0 ]]; then BUILD_LOCK_FILE="${BL_DIR}/build-lock.json"
      ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (${bl_n} Gradle artifacts, sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
    else ws_warn "build-lock.json lists no Gradle artifacts; not offered for upload."; fi
  else
    ws_warn "No build-lock.json (exit ${bl_rc}; see ${workspace}/build-lock.log)."
  fi
else
  ws_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256."
fi

if [[ "$build_mode" == "bundle" ]]; then
  section "Rendering split APKs from the built AAB (bundletool ${BT_VER})"
  abis=(); locales=(); density=""
  for f in "${OFF_DIR}"/split_config.*.apk; do
    [[ -f "$f" ]] || continue
    cfg="$(basename "$f")"; cfg="${cfg#split_config.}"; cfg="${cfg%.apk}"
    case "$cfg" in
      arm64_v8a) abis+=("arm64-v8a") ;; armeabi_v7a) abis+=("armeabi-v7a") ;;
      x86_64) abis+=("x86_64") ;; x86) abis+=("x86") ;;
      ldpi) density=120 ;; mdpi) density=160 ;; tvdpi) density=213 ;; hdpi) density=240 ;;
      xhdpi) density=320 ;; xxhdpi) density=480 ;; xxxhdpi) density=640 ;;
      [a-z][a-z]|[a-z][a-z][a-z]|[a-z][a-z]_*|[a-z][a-z][a-z]_*) locales+=("${cfg//_/-}") ;;
      *) ws_warn "Unrecognised config split '${cfg}' - not reflected in the device spec" ;;
    esac
  done
  [[ ${#abis[@]} -eq 0 ]] && abis=("${arch_arg:-arm64-v8a}")
  [[ ${#locales[@]} -eq 0 ]] && locales=("en")
  [[ -z "$density" ]] && density=480
  abis_json="$(printf '"%s",' "${abis[@]}")"; locales_json="$(printf '"%s",' "${locales[@]}")"
  echo "{\"supportedAbis\": [${abis_json%,}], \"supportedLocales\": [${locales_json%,}], \"screenDensity\": ${density}, \"sdkVersion\": ${min_sdk}}" > "${BUILT_DIR}/device-spec.json"
  ws_info "device-spec.json: $(cat "${BUILT_DIR}/device-spec.json")"
  ctr_run render "${BUILT_DIR}/render.log" \
    --volume "${BUILD_DIR}/built.aab:/built.aab:ro" --volume "${BUILT_DIR}:/out" \
    "$IMG" bash -c 'set -e; cd /out
      java -jar /opt/bundletool.jar build-apks --bundle=/built.aab --output=/out/built.apks \
        --device-spec=/out/device-spec.json --mode=default --overwrite
      unzip -qq -o /out/built.apks -d /out/apks
      for f in /out/apks/splits/*.apk; do n="$(basename "$f")"
        case "$n" in base-master.apk) c=base.apk ;; base-master_*.apk) c="variant_${n#base-master_}" ;; base-*.apk) c="split_config.${n#base-}" ;; *) c="$n" ;; esac
        mv "$f" "/out/$c"; done
      rm -rf /out/apks /out/built.apks; ls -1 /out/*.apk' || nov "bundletool could not render splits from the built AAB (see ${BUILT_DIR}/render.log)"
  [[ -f "${BUILT_DIR}/base.apk" ]] || nov "bundletool rendered no base split from the built AAB for ${APP_ID} $wallet_version"
  ls "${BUILT_DIR}"/variant_*.apk >/dev/null 2>&1 && ws_warn "several base variants rendered; only base-master compared"
else
  cp "${BUILD_DIR}/built.apk" "${BUILT_DIR}/$(basename "$official_base")"
fi

phase "PHASE 2: COMPARISON"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"
ind() { sed 's/^/        /'; }

stamp_ok() {
  local n sz v
  n=$(unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256')
  [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
  [[ -e /tmp/b/stamp-cert-sha256 ]] && { echo "      stamp: present in BUILT too"; return 1; }
  sz=$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null || echo -1)
  [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
  v="$("$BT/apksigner" verify --verbose --print-certs "$o" 2>/dev/null)" && grep -q 'Verified for SourceStamp: true' <<< "$v" \
    || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
  echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

manifest_ok() {
  local d left bad n m
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null && "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null \
    || { echo "FATAL: aapt2 manifest ${L}"; exit 3; }
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"; [[ $? -le 1 ]] || exit 3
  printf '%s\n' "$d" > "/out/diff_manifest_${L}.txt"
  grep -q '^>' <<< "$d" && { echo "      manifest: BUILT-only lines present:"; printf '%s\n' "$d" | grep '^>' | head -3 | ind; return 1; }
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  bad="$(printf '%s\n' "$left" | grep -vE '^E: meta-data|^A: [^ ]*android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id|vending\.splits|dynamic\.apk\.fused\.modules)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK|base)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)=(@0x7f[0-9a-f]+|[0-9]+)$')"
  if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: unexpected official-only line(s):"; printf '%s\n' "$bad" | head -3 | ind; return 1
  fi
  n=$(printf '%s\n' "$left" | grep -c '^E: meta-data')
  m=$(printf '%s\n' "$left" | grep -c 'android:name(0x[0-9a-f]*)="com\.android\.')
  [[ "$n" -ge 1 && "$n" -eq "$m" ]] || { echo "      manifest: $n block(s) vs $m Play name(s)"; return 1; }
  echo "      manifest: ${n} official-only Play meta-data block(s), none built-only:"
  printf '%s\n' "$left" | grep -vE '^E: meta-data' | sed 's/^A: [^ ]*android:/        /'
}

res_ok() {
  local rd
  rm -rf /tmp/do /tmp/db
  for x in o b; do $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/d$x "${!x}" >/dev/null 2>&1 && [[ -d /tmp/d$x/res ]] \
    || { echo "FATAL: apktool decode ($x) ${L}"; exit 3; }; done
  rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"; [[ $? -le 1 ]] || exit 3
  printf '%s\n' "$rd" > "/out/diff_resources_decoded_${L}.txt"
  if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then
    echo "      res: decoded res/ tree IDENTICAL (binary packing artifact)"; return 0
  fi
  echo "      res: decoded res/ differs -> material (diff_resources_decoded_${L}.txt)"; printf '%s\n' "$rd" | head -3 | ind
  return 1
}

: > /out/summary.txt
for o in /official/*.apk; do
  name="$(basename "$o")"; L="${name%.apk}"; L="${L#split_config.}"; L="${L//[^A-Za-z0-9_]/_}"
  b="/built/${name}"
  echo ""; echo "--- ${name} (label ${L}) ---"
  echo "  official: sha256 $(sha256sum "$o" | cut -d' ' -f1)"
  if [[ ! -f "$b" ]]; then
    echo "  built:    MISSING - the built AAB rendered no ${name}"; echo "MISSING built ${name}" > "/out/diff_${L}.txt"
    echo "LABEL ${L} 1 0 0 0 0 0 1 missing" >> /out/summary.txt; continue
  fi
  echo "  built:    sha256 $(sha256sum "$b" | cut -d' ' -f1)"
  rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
  unzip -q -o "$o" -d /tmp/o && unzip -q -o "$b" -d /tmp/b && [[ -n "$(find /tmp/o -type f -print -quit)" && -n "$(find /tmp/b -type f -print -quit)" ]] || { echo "FATAL: unzip ${name}"; exit 3; }
  echo "  entries: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"
  nso=0; nsm=0; nsi=0; OC="${ANDROID_HOME}/ndk/27.1.12297006/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy"; : > /tmp/id_o; : > /tmp/id_b
  while IFS= read -r so; do
    rel="${so#/tmp/o/}"; nso=$((nso + 1)); b2="/tmp/b/${rel}"
    if [[ -f "$b2" ]] && cmp -s "$so" "$b2"; then nsm=$((nsm + 1)); continue; fi
    if [[ -f "$b2" ]] && "$OC" -R .comment -R .note.gnu.build-id "$so" /tmp/o.so 2>/dev/null && "$OC" -R .comment -R .note.gnu.build-id "$b2" /tmp/b.so 2>/dev/null && cmp -s /tmp/o.so /tmp/b.so; then
      nsi=$((nsi + 1)); echo "  native IDENT-ONLY ${rel} (code identical; .comment/build-id differ)"
      "${OC%objcopy}readelf" -p .comment "$so" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' >> /tmp/id_o; "${OC%objcopy}readelf" -p .comment "$b2" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' >> /tmp/id_b
    else echo "  native DIFFER/MISSING ${rel}"; fi
  done < <(find /tmp/o -name '*.so' -type f | sort)
  [[ "$nso" -gt 0 ]] && echo "  native libs: ${nsm}/${nso} byte-identical, ${nsi} identical modulo compiler ident, $((nso - nsm - nsi)) differ in code"
  [[ -f /tmp/o/assets/index.android.bundle ]] && echo "  JS bundle:   $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo IDENTICAL || echo DIFFERS)"
  dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
  [[ -n "$(cd /tmp/o && ls classes*.dex 2>/dev/null)" ]] && echo "  dex:         ${dx:-all identical}"

  raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"; [[ $? -le 1 ]] || { echo "FATAL: diff ${name}"; exit 3; }
  printf '%s\n' "$raw" > "/out/diff_${L}.txt"
  n=$(printf '%s\n' "$raw" | grep -vc '^$')
  echo "  raw diffs: ${n}   (full list: diff_${L}.txt)"
  [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | head -5 | sed 's/^/    /'

  # Signing: official-only root META-INF *.SF/RSA/DSA/EC, MANIFEST.MF; else material.
  read -r c_sign c_dir c_stamp c_mani c_res < <(printf '%s\n' "$raw" | awk '
    /^Only in \/tmp\/o\/META-INF: ([^\/ ]*\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$/{a++;next} /^Only in \/tmp\/o: META-INF$/{e++;next}
    /^Only in \/tmp\/o: stamp-cert-sha256$/{b++;next} /^Files \/tmp\/o\/AndroidManifest\.xml and \/tmp\/b\/AndroidManifest\.xml differ$/{c++;next}
    /^Files \/tmp\/o\/(resources\.arsc|res\/[^ ]+) and \/tmp\/b\/[^ ]+ differ$|^Only in \/tmp\/o\/res(\/[^:]*)?: [^\/]+$|^Only in \/tmp\/o: res$/{d++}
    END{print a+0, e+0, b+0, c+0, d+0}')
  a_sign=0; a_stamp=0; a_mani=0; a_res=0
  if [[ "$nsi" -gt 0 ]]; then
    echo "      ident: ${nsi} native lib(s) same code, other compiler ident -> UNACCOUNTED"; sort -u /tmp/id_o | sed 's/^/        official: /'; sort -u /tmp/id_b | sed 's/^/        built:    /'; fi
  if [[ "$c_sign" -gt 0 ]]; then a_sign=$c_sign
    echo "      signing: ${c_sign} official-only root META-INF signing file(s) - $(ls /tmp/o/META-INF 2>/dev/null | grep -E '\.(SF|RSA|DSA|EC)$|^MANIFEST\.MF$' | paste -sd' ' -)"; fi
  if [[ "$c_dir" -gt 0 ]]; then
    other="$(find /tmp/o/META-INF -mindepth 1 | grep -vE '^/tmp/o/META-INF/([^/]*\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$')"
    if [[ -z "$other" && -n "$(ls -A /tmp/o/META-INF)" ]]; then a_sign=$((a_sign + 1))
      echo "      signing: official-only META-INF/ holds signing files only - $(ls /tmp/o/META-INF | paste -sd' ' -)"
    else echo "      META-INF: official-only directory with other entries -> material:"; printf '%s\n' "$other" | head -3 | ind; fi
  fi
  if [[ "$c_stamp" -gt 0 ]]; then
    if stamp_ok; then a_stamp=$c_stamp; else echo "      stamp: NOT EARNED -> material"; fi
  fi
  if [[ "$c_mani" -gt 0 ]]; then
    if manifest_ok; then a_mani=$c_mani; else echo "      manifest: NOT EARNED -> material (diff_manifest_${L}.txt)"; fi
  fi
  if [[ "$c_res" -gt 0 ]]; then
    if res_ok; then a_res=$c_res; else echo "      res: NOT EARNED -> material"; fi
  fi
  printf '%s\n' "$raw" | grep -q 'baseline\.prof' && echo "      baseline.prof: never auto-accepted (embeds dex checksums) -> material"
  acc=$((a_sign + a_stamp + a_mani + a_res))
  un=$((n - acc)); [[ "$un" -ge 0 ]] || { echo "FATAL: ${acc} accepted > ${n} raw"; exit 3; }
  echo "LABEL ${L} ${n} ${a_sign} ${a_stamp} ${a_mani} ${a_res} ${nsi} ${un} compared" >> /out/summary.txt
  echo "  => ${name}: raw ${n}, accepted ${acc}, unaccounted ${un}"
done
echo ""; echo "=== comparison complete ==="
CMP_END

CMP_RC=0
ctr_run cmp "${CMP_DIR}/comparison.log" \
  --volume "${OFF_DIR}:/official:ro" --volume "${BUILT_DIR}:/built:ro" --volume "${CMP_DIR}:/out" \
  --volume "${img_ctx}/compare.sh:/compare.sh:ro" "$IMG" bash /compare.sh || CMP_RC=$?
if [[ $CMP_RC -ne 0 ]] || ! grep -q '^LABEL' "${CMP_DIR}/summary.txt" 2>/dev/null; then
  nov "Comparison stage failed (exit ${CMP_RC}) or wrote no LABEL line; see ${CMP_DIR}/comparison.log"
fi

section "RESULT"
rf=' %-14s %5s %9s %8s %8s %6s %6s %11s  %s\n'; printf "$rf" artifact raw signing stamp manifest res ident UNACCOUNTED verdict
total_unacc=0; n_art=0; n_ok=0; per_art=""; declare -A seen=()
while IFS= read -r row; do
  [[ "$row" =~ ^LABEL\ ([A-Za-z0-9_]+)((\ [0-9]+){7})\ (compared|missing)$ ]] || nov "Malformed summary row '${row}'"
  lbl="${BASH_REMATCH[1]}"; read -r raw s st m r i un <<< "${BASH_REMATCH[2]}"
  [[ -z "${seen[$lbl]:-}" && "$raw" -eq $((s + st + m + r + un)) ]] || nov "Repeated or unbalanced summary row '${row}'"
  seen[$lbl]=1
  n_art=$((n_art + 1))
  if [[ "$un" -eq 0 ]]; then v="reproducible"; n_ok=$((n_ok + 1)); else v="not_reproducible"; fi
  total_unacc=$((total_unacc + un))
  printf "$rf" "$lbl" "$raw" "$s" "$st" "$m" "$r" "$i" "$un" "$v"
  per_art+="${lbl}=${v}(raw ${raw}, unaccounted ${un}, ident-only native libs ${i}) "
done < "${CMP_DIR}/summary.txt"
n_exp=$(find "$OFF_DIR" -maxdepth 1 -name '*.apk' | wc -l)
for f in "${OFF_DIR}"/*.apk; do [[ -n "${seen[$(label_of "$(basename "$f")")]:-}" ]] || nov "No summary row for $(basename "$f")"; done
[[ "$n_art" -eq "$n_exp" ]] || nov "${n_art} summary rows for ${n_exp} official APKs"

if [[ "$total_unacc" -eq 0 ]]; then
  verdict="reproducible"; rc=0
  ws_ok "All ${n_art} artifact(s) reproduced: every difference is an earned class with evidence."
else
  verdict="not_reproducible"; rc=1
  ws_error "${n_ok} of ${n_art} artifact(s) reproduced; ${total_unacc} difference(s) unaccounted for. See ${CMP_DIR}/"
fi

for f in "${CMP_DIR}"/diff_*.txt; do
  [[ -f "$f" ]] || continue
  case "$f" in */diff_manifest_*|*/diff_resources_decoded_*|*/diff_full.txt) continue ;; esac
  l="${f##*/diff_}"; l="${l%.txt}"
  sed "/^$/d; s|/tmp/o|o|g; s|/tmp/b|b|g; s|^|${l}: |" "$f" || nov "cannot read $f"
done > "${CMP_DIR}/diff_full.txt"
diff_n=$(wc -l < "${CMP_DIR}/diff_full.txt")
ref_note="$(cat "${BUILD_DIR}/ref_note.txt" 2>/dev/null || true)"; [[ -n "$ref_note" ]] || nov "build.sh wrote no ref_note.txt"
diff_text="$(
  if [[ "$diff_n" -eq 0 ]]; then echo "(no differing entries)"; else sed -n 1,5p "${CMP_DIR}/diff_full.txt"
    [[ "$diff_n" -le 5 ]] || echo "    ... $((diff_n - 5)) more line(s); full list: ${CMP_DIR}/diff_full.txt"; fi
  echo ""
  echo "Revision, tag (and its signature):"
  echo "Built from: ${commit} (${ref_note})"
)"
echo ""
ws_results_block "$APP_ID" "$signer" "$wallet_version" "$version_code" "$verdict" "$base_hash" "$commit" "$diff_text"
echo ""
[[ -z "$BUILD_LOCK_FILE" ]] || echo "Upload with the verification: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
echo ""
ws_write_yaml "$verdict" "${APP_ID} ${wallet_version} (versionCode ${version_code}), commit ${commit} (${ref_note}), ${gradle_task}$( [[ "$build_mode" == "bundle" ]] && echo " + bundletool ${BT_VER} splits" || true ). Mirrored: .env (${n_env} keys), HOME, checkout path, Node v${NODE_VERSION}. ${n_ok} of ${n_art} artifact(s) reproduced: ${per_art}Accepted (WS #574): signing files, Play SourceStamp and manifest meta-data, decoded-identical res/."
exit "$rc"
