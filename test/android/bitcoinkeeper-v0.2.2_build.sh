#!/usr/bin/env bash
# bitcoinkeeper_build.sh - Bitcoin Keeper (Android) reproducible build verification
# Version:          v0.2.2
# Last modified by: Bob
# Last modified on: 2026-10-12
# Organization:     WalletScrutiny.com
# App ID:           io.hexawallet.bitcoinkeeper
# Project:          https://github.com/KeeperCommunity/bitcoin-keeper
# License: MIT. No warranty; review before running. Steps: read the official artifact (version, signer,
# build-machine paths, Node, node_modules layout, .env keys), build the tag in a pinned container (fat APK
# or AAB + bundletool), compare entry by entry, write COMPARISON_RESULTS.yaml next to this script.
# Exit codes: 0 = identical, 1 = difference or build failure, 2 = bad parameters.

SCRIPT_VERSION="v0.2.2"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
SCRIPT_HASH="${SCRIPT_HASH:-N/A}"
echo "bitcoinkeeper_build.sh $SCRIPT_VERSION sha256:${SCRIPT_HASH}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="bitcoinkeeper_build.sh"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
APP_ID="io.hexawallet.bitcoinkeeper"
REPO_URL="https://github.com/KeeperCommunity/bitcoin-keeper"
# Releases are built on a developer's Mac; HOME, checkout path, Node and package layout end up in
# the artifact. Read from the official APK and mirrored.
BUILD_HOME="/Users/vaibhav"; SRC_DIR=""; NODE_VERSION=""
# 1.18.2+ writes legacy language codes (iw, in) in splits0.xml as Play does.
BT_VER="1.18.3"
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
YAML_WRITTEN=0; CUR_CTR=""; BG_PID=""; workspace=""; IMG=""

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner() { printf '\n== %s ==\n' "$*"; }
section() { printf -- '\n-- %s --\n' "$*"; }
phase() { banner "$*"; echo "  $(date)"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# Only these three keys: script_version, verdict, notes. Next to the script (ABS reads it there).
generate_yaml() {
  printf 'script_version: %s\nverdict: %s\nnotes: |\n  %s\n' "$SCRIPT_VERSION" "$1" "$2" > "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
  YAML_WRITTEN=1
  log_info "COMPARISON_RESULTS.yaml written: verdict $1"
}

fail() {
  local code="$1" note="$2"
  generate_yaml "ftbfs" "$note"
  echo ""; echo "Exit code: ${code}"
  exit "$code"
}

die_invalid() { log_error "$1"; fail 2 "Invalid invocation: $1"; }

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; arch_arg=""; rev_arg="${WS_GIT_REVISION:-}"; node_arg="${WS_NODE_VERSION:-}"

require_arg() {
  [[ -z "${2:-}" || "${2:-}" == --* ]] && die_invalid "$1 requires a value (got: '${2:-<nothing>}')"
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <apk|dir> [--git-revision <sha>] [--node-version <x.y.z>] [--version <v>] [--arch <a>] [--type <t>]

 --binary        REQUIRED. GitHub fat APK, or a directory with the Play split set (base.apk + split_config.*.apk).
 --git-revision  Default: tag v<versionName>, else the newest default-branch commit declaring it.
 --node-version  Default: the version the official bundle embeds.
 --version/--arch/--type  Optional; --arch must be an ABI of the binary.
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      require_arg --version "${2:-}"; version_arg="$2"; shift 2 ;;
    --binary|--apk) require_arg "$1" "${2:-}"; binary_arg="$2";  shift 2 ;;
    --arch)         require_arg --arch    "${2:-}"; arch_arg="$2";    shift 2 ;;
    --type)         require_arg --type    "${2:-}"; shift 2 ;;
    --git-revision) require_arg --git-revision "${2:-}"; rev_arg="$2"; shift 2 ;;
    --node-version) require_arg --node-version "${2:-}"; node_arg="$2"; shift 2 ;;
    -h|--help)      usage; echo "Exit code: 0"; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done

[[ -n "$binary_arg" ]] || die_invalid "--binary is required (official GitHub APK or Play split directory)"
[[ -e "$binary_arg" ]] || die_invalid "--binary path does not exist: ${binary_arg}"
binary_is_dir=0
if [[ -d "$binary_arg" ]]; then
  binary_arg="${binary_arg%/}"
  [[ -f "${binary_arg}/base.apk" ]] || die_invalid "--binary directory contains no base.apk: ${binary_arg}"
  binary_is_dir=1
fi
[[ "$binary_is_dir" -eq 1 || -f "$binary_arg" ]] || die_invalid "--binary is not a regular file: ${binary_arg}"
[[ -z "$rev_arg" || "$rev_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_invalid "--git-revision must be 7-40 hex characters (got: '${rev_arg}')"
[[ -z "$node_arg" || "$node_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_invalid "--node-version must be x.y.z (got: '${node_arg}')"
binary_path="$(realpath "$binary_arg")"

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v podman &>/dev/null; then CONTAINER_CMD=podman
  elif command -v docker &>/dev/null; then CONTAINER_CMD=docker
  else die_invalid "Neither podman nor docker found in PATH"; fi
fi
# Container user = host user (rootless docker: container root = caller; other uids land in subuids).
RECLAIM_OWNER="${HOST_UID}:${HOST_GID}"
if [[ "$CONTAINER_CMD" == podman ]]; then
  RUN_USER_ARGS=(--userns=keep-id)
else
  docker info >/dev/null 2>&1 || die_invalid "docker is installed but 'docker info' fails (daemon not running or no socket access)"
  if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then RUN_USER_ARGS=(--user 0:0); RECLAIM_OWNER="0:0"
  else RUN_USER_ARGS=(--user "${HOST_UID}:${HOST_GID}"); fi
fi

command -v unzip >/dev/null || die_invalid "unzip is required on the host (reads the official APKs)"

# Per-run workspace in the caller's directory: never reused or deleted.
RUN_ID="$(date +%s)-$$"
IMG="ws-bitcoinkeeper-${RUN_ID}"
workspace="$(pwd -P)/bitcoinkeeper_verification_${RUN_ID}"
mkdir "$workspace" || die_invalid "Could not create the per-run workspace ${workspace}"
META_DIR="${workspace}/metadata"; BUILD_DIR="${workspace}/source-build"; CMP_DIR="${workspace}/comparison"
OFF_DIR="${workspace}/official"; BUILT_DIR="${workspace}/built"; img_ctx="${workspace}/context"
mkdir -p "$META_DIR" "$BUILD_DIR" "$CMP_DIR" "$OFF_DIR" "$BUILT_DIR" "$img_ctx"

# Hand back to the caller (no sudo): root inside the container on purpose.
reclaim_workspace() {
  local path="$1" stray
  [[ -e "$path" ]] || return 0
  stray="$(find "$path" ! -uid "$HOST_UID" -print -quit 2>/dev/null || true)"
  [[ -n "$stray" ]] || return 0
  if [[ "$CONTAINER_CMD" == podman ]]; then
    podman unshare chown -R 0:0 "$path" >/dev/null 2>&1
  elif docker image inspect "$IMG" >/dev/null 2>&1; then
    docker run --rm --user 0:0 -v "${path}:/target" "$IMG" chown -R "$RECLAIM_OWNER" /target >/dev/null 2>&1
  fi
  stray="$(find "$path" ! -uid "$HOST_UID" -print -quit 2>/dev/null || true)"
  [[ -n "$stray" ]] && log_warn "Still not caller-owned: ${stray}"
  return 0
}

cleanup() {
  [[ "$YAML_WRITTEN" -eq 1 ]] || generate_yaml "ftbfs" "Run ended before a verdict (interrupted or internal error) for ${APP_ID}; workspace ${workspace}."
  log_info "Cleanup: container, ownership, image"
  [[ -n "$CUR_CTR" ]] && $CONTAINER_CMD rm -f "$CUR_CTR" >/dev/null 2>&1
  reclaim_workspace "$workspace"
  $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1 || true
}
on_signal() {
  log_warn "Signal received: stopping ${CUR_CTR:-the current step}"
  [[ -n "$CUR_CTR" ]] && $CONTAINER_CMD rm -f "$CUR_CTR" >/dev/null 2>&1
  [[ -n "$BG_PID" ]] && kill "$BG_PID" 2>/dev/null
  exit 143
}
trap cleanup EXIT
trap on_signal INT TERM HUP

# Long steps run in the background and are waited for: a signal is handled at once and the
# container is killed by name (its PID 1 ignores the forwarded TERM).
bg_wait() { "$@" & BG_PID=$!; wait "$BG_PID"; local rc=$?; BG_PID=""; return $rc; }
# ctr_run <stage> <log> <run args...>: streams output, returns the container's exit code.
ctr_run() {
  local stage="$1" log="$2" rc; shift 2
  CUR_CTR="${IMG}-${stage}"
  bg_wait bash -c '"$0" run --rm --name "$2" "${@:3}" 2>&1 | tee "$1"; exit "${PIPESTATUS[0]}"' \
    "$CONTAINER_CMD" "$log" "$CUR_CTR" "${RUN_USER_ARGS[@]}" -e "HOME=${BUILD_HOME}" "$@"
  rc=$?; CUR_CTR=""; return $rc
}

# Canonical official names: base.apk, split_config.<cfg>.apk.
canonical_name() {
  case "$1" in
    base.apk|base-master.apk|standalone.apk) echo "base.apk" ;;
    split_config.*.apk) echo "$1" ;;
    base-*.apk) echo "split_config.${1#base-}" ;;
    *) echo "$1" ;;
  esac
}
label_of() { local n="${1%.apk}"; n="${n#split_config.}"; echo "${n//[^A-Za-z0-9_]/_}"; }

if [[ "$binary_is_dir" -eq 1 ]]; then
  n_apk=0
  for f in "${binary_path}"/*.apk; do
    [[ -f "$f" ]] || continue
    cn="$(canonical_name "$(basename "$f")")"
    cp "$f" "${OFF_DIR}/${cn}"
    [[ "$cn" != "$(basename "$f")" ]] && log_info "Normalised split name: $(basename "$f") -> ${cn}"
    n_apk=$((n_apk + 1))
  done
  log_info "Collected ${n_apk} official APK(s) from ${binary_path}"
else
  cp "$binary_path" "${OFF_DIR}/$(canonical_name "$(basename "$binary_path")")"
fi
official_base="$(ls "${OFF_DIR}"/base.apk 2>/dev/null || ls "${OFF_DIR}"/*.apk | head -1)"

section "BUILD-MACHINE INPUTS READ FROM THE OFFICIAL ARTIFACT"
# librealm.so / libappmodules.so keep source and prefab paths in .rodata.
so_src=""
for f in "${OFF_DIR}"/*.apk; do [[ -n "$(unzip -Z1 "$f" 2>/dev/null | grep '^lib/')" ]] && { so_src="$f"; break; }; done
if [[ -n "$so_src" ]]; then
  so_paths="$(unzip -p "$so_src" 'lib/*/librealm.so' 'lib/*/libappmodules.so' 2>/dev/null | grep -aoE '/(Users|home)/[[:graph:]]*' | sort -u)"
  p="$(printf '%s\n' "$so_paths" | grep -oE '^.*/node_modules/realm/' | head -1 | sed 's|/node_modules/realm/$||')"
  h="$(printf '%s\n' "$so_paths" | grep -oE '^/(Users|home)/[^/]+/\.gradle/' | head -1 | sed 's|/\.gradle/$||')"
  [[ -n "$h" ]] && BUILD_HOME="$h" || log_warn "No Gradle cache path in the official native libs; default HOME"
  [[ -n "$p" ]] && SRC_DIR="$p" || log_warn "No checkout path in the official librealm.so; default \$HOME/bitcoin-keeper"
else
  log_warn "No official APK carries lib/: build-machine paths default to HOME=${BUILD_HOME}"
fi
[[ -z "$SRC_DIR" ]] && SRC_DIR="${BUILD_HOME}/bitcoin-keeper"
# The bundling Node's process.version is inlined into the Hermes bundle (rn-nodeify shim); no word boundaries.
node_cands="$(unzip -p "$official_base" assets/index.android.bundle 2>/dev/null | grep -aoE 'v[0-9]{2}\.[0-9]+\.[0-9]+' | sort -u | sort -t. -k1.2,1n -k2,2n -k3,3n | paste -sd' ' -)"
if [[ -n "$node_arg" ]]; then NODE_VERSION="$node_arg"; node_src="--node-version"
elif [[ -n "$node_cands" ]]; then NODE_VERSION="${node_cands##* }"; NODE_VERSION="${NODE_VERSION#v}"; node_src="official Hermes bundle"
else NODE_VERSION="22.23.3"; node_src="default, none in the official bundle"; fi
echo "  HOME (Gradle cache): ${BUILD_HOME}"; echo "  Checkout path:       ${SRC_DIR}"
echo "  Node:                v${NODE_VERSION} (${node_src}; bundle candidates: ${node_cands:-none})"
# Assets named from a realpath outside the checkout ("/assets/../..") = the build machine's node_modules
# was a symlink to a sibling checkout's. Read and mirrored (same files, same relative path).
NM_LINK="$(unzip -p "$official_base" assets/index.android.bundle 2>/dev/null | grep -aoE '/assets/(\.\./)+([A-Za-z0-9_.-]+/)*node_modules/' | sed -E 's|^/assets/||; s|/$||' | sort -u | head -1)"
NM_PARENT=""; [[ -n "$NM_LINK" ]] && NM_PARENT=" $(dirname "$(realpath -m "${SRC_DIR}/${NM_LINK}")")"
echo "  node_modules link:   ${NM_LINK:-none (node_modules inside the checkout)}"

banner "BITCOIN KEEPER - ANDROID VERIFICATION"
cat <<EOF
 App ID:    ${APP_ID}
 Input:     ${binary_path}$( [[ "$binary_is_dir" -eq 1 ]] && echo " (split set)" )
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${workspace}
 Date:      $(date)
EOF

phase "SETUP: BUILD CONTAINER IMAGE"

# Pins from the tag: NDK 27.1.12297006, build-tools 35.0.0, compileSdk 36, Gradle 8.14.3, AGP 8.12.0; JDK Temurin 17.
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
# SDK read-only: everything AGP would auto-install is pre-installed.
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
if ! bg_wait $CONTAINER_CMD build -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx"; then
  log_error "Container image build failed - see the output above."
  fail 1 "Container image build failed; no comparison was performed."
fi
log_success "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL BINARY METADATA"

# react-native-config compiles the private .env into BuildConfig (and string resources);
# recovered from the dex: every String field except the four AGP generates.
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
A=/input/base.apk
info="$("$BT/aapt2" dump badging $A 2>/dev/null)"
# Anchor on '^package:'; a greedy match would return versionName.
pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"
minsdk="$(printf '%s\n' "$info" | sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" | head -1)"
split_name="$(printf '%s\n' "$info" | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
abis="$(printf '%s\n' "$info" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
sv="$("$BT/apksigner" verify --verbose --print-certs $A 2>/dev/null)"
signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"
stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
# grep -c reads to EOF (grep -q would SIGPIPE unzip under pipefail).
has_lib=0; [[ "$(unzip -Z1 $A 2>/dev/null | grep -c '^lib/')" -gt 0 ]] && has_lib=1
vcs="$(unzip -p $A META-INF/version-control-info.textproto 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
agp="$(unzip -p $A META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null | sed -n 's/^androidGradlePluginVersion=//p' | head -1)"
"$BT/aapt2" dump xmltree --file AndroidManifest.xml $A > /output/manifest-official.txt 2>/dev/null
fused="$(grep -c 'com.android.dynamic.apk.fused.modules' /output/manifest-official.txt)"
# The RN gradle plugin writes the BUILD HOST's LAN IP into this release resource.
devip="$("$BT/aapt2" dump resources $A 2>/dev/null | grep -A1 'string/react_native_dev_server_ip' | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)"

python3 /buildconfig.py $A > /output/buildconfig.txt 2>/output/buildconfig.err
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
[META] package:            ${pkg:-unknown}
[META] versionName:        ${vname:-unknown}
[META] versionCode:        ${vcode:-unknown}
[META] minSdkVersion:      ${minsdk:-?}
[META] native ABIs:        ${abis:-<none>} (has lib/: ${has_lib} = fat APK; fused.modules: ${fused})
[META] signer SHA-256:     ${signer:-unknown}
[META] SourceStamp:        ${stamp} (apksigner)
[META] AGP version:        ${agp:-<none>} (META-INF/.../app-metadata.properties)
[META] VCS info:           ${vcs:-<none>} (META-INF/version-control-info.textproto)
[META] dev_server_ip res:  ${devip:+present} (build host LAN IP, RN gradle plugin)
[META] BuildConfig .env:   ${nenv} key(s) recovered from $(grep '^#dex' /output/buildconfig.txt 2>/dev/null | cut -d' ' -f2) (exit ${bc_rc}); values stay in metadata/dotenv
[META] .env keys:          ${keys:-<none>}
META
META_END

if ! ctr_run meta "${META_DIR}/meta.log" \
  --volume "${official_base}:/input/base.apk:ro" --volume "${META_DIR}:/output" \
  --volume "${img_ctx}/meta.sh:/meta.sh:ro" --volume "${img_ctx}/buildconfig.py:/buildconfig.py:ro" \
  "$IMG" bash /meta.sh; then
  log_error "Metadata extraction failed - aapt2/apksigner could not read the APK."
  fail 1 "Could not read metadata from the official APK."
fi

meta() { local v; v="$(cat "${META_DIR}/$1.txt" 2>/dev/null)"; [[ -n "$v" ]] && echo "$v" || echo "${2:-}"; }
pkg_id="$(meta pkg_name unknown)"; wallet_version="$(meta version_name unknown)"; version_code="$(meta version_code unknown)"
signer="$(meta signer unknown)"; official_agp="$(meta agp)"; dev_ip="$(meta dev_ip)"; split_name="$(meta split_name)"
has_lib="$(meta has_lib 0)"; min_sdk="$(meta min_sdk 26)"; n_env="$(meta nenv 0)"; abis_csv="$(meta abis)"
base_hash="$(sha256of "$official_base")"

[[ "$pkg_id" == "$APP_ID" ]] || die_invalid "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
log_success "Package name verified: ${pkg_id}"
log_success "Version: $wallet_version (versionCode $version_code)"
log_info    "Signer SHA-256:   ${signer}"
log_info    "base APK SHA-256: ${base_hash}"
[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || die_invalid "Could not read versionName from the APK"
[[ "$version_code" =~ ^[0-9]+$ ]] || die_invalid "Could not read versionCode from the APK"
[[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]] && \
  log_warn "--version was '${version_arg}' but the APK reports '$wallet_version'; using the APK's"
[[ -z "$split_name" ]] || die_invalid "$(basename "$official_base") is the config split '${split_name}'; pass the directory with base.apk"
[[ "$(meta fused 0)" -eq 0 ]] || die_invalid "fused.modules present: a bundletool universal APK; pass the Play split set or the GitHub APK"
[[ "$n_env" -gt 0 ]] || fail 1 "No react-native-config keys in the official BuildConfig (metadata/buildconfig.err); build not attempted."

# Fat APK (lib/ inside) = assembleProductionRelease; split base = bundleProductionRelease.
if [[ "$has_lib" -eq 1 ]]; then
  build_mode="apk"; gradle_task="assembleProductionRelease"
  [[ "$binary_is_dir" -eq 1 ]] && log_warn "base.apk carries lib/: fat APK; other files ignored"
  log_info "Mode: fat APK (GitHub release layout) -> ${gradle_task}"
else
  build_mode="bundle"; gradle_task="bundleProductionRelease"
  log_info "Mode: Play split set -> ${gradle_task} + bundletool ${BT_VER}"
  [[ "$binary_is_dir" -eq 1 ]] || log_warn "Single split supplied: only base.apk is verified"
  abis_csv=""; for f in "${OFF_DIR}"/split_config.{arm64_v8a,armeabi_v7a,x86_64,x86}.apk; do [[ -f "$f" ]] && { a="${f##*split_config.}"; a="${a%.apk}"; abis_csv+="${a/_/-},"; }; done
fi
# --arch must name an ABI the binary carries (exit 2 otherwise).
if [[ -n "$arch_arg" ]]; then
  a="${arch_arg//_/-}"
  if [[ ",${abis_csv}," == *",${a},"* ]]; then log_info "--arch ${arch_arg} is among the binary's ABIs (${abis_csv})"
  else die_invalid "--arch ${arch_arg} is not among the binary's ABIs (${abis_csv:-none})"; fi
fi

section "Resolving source revision"
if [[ -n "$rev_arg" ]]; then rev_source="--git-revision"
else rev_source="tag v${wallet_version}, else newest default-branch commit declaring versionName ${wallet_version} + versionCode ${version_code}"; fi
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
  echo "=== Pinned revision ${GIT_REF} (--git-revision) ==="
elif git rev-parse -q --verify "refs/tags/v${WANT_VNAME}^{commit}" >/dev/null; then
  GIT_REF="$(git rev-parse "refs/tags/v${WANT_VNAME}^{commit}")"
  echo "=== Tag v${WANT_VNAME} -> ${GIT_REF} ($(git cat-file -t "refs/tags/v${WANT_VNAME}") tag) ==="
  git tag -v "v${WANT_VNAME}" 2>&1 | head -3 | sed 's/^/  /'
else
  # No tag: the newest default-branch commit declaring exactly this build.
  echo "=== No tag v${WANT_VNAME}: searching first-parent ${default_branch} for versionName ${WANT_VNAME} + versionCode ${WANT_VCODE} ==="
  GIT_REF=""; loose=""
  for c in $(git rev-list --first-parent "origin/${default_branch}"); do
    vn="$(gradle_field versionName "$c")"
    [[ "$vn" == "$WANT_VNAME" ]] || { [[ -n "$loose" ]] && break; continue; }
    [[ -z "$loose" ]] && loose="$c"
    if [[ "$(gradle_field versionCode "$c")" == "$WANT_VCODE" ]]; then GIT_REF="$c"; break; fi
  done
  if [[ -z "$GIT_REF" && -n "$loose" ]]; then
    GIT_REF="$loose"
    echo "AMBIGUOUS: no commit declares versionCode ${WANT_VCODE}; using the newest with versionName ${WANT_VNAME} (--git-revision overrides)."
  fi
  [[ -n "$GIT_REF" ]] || { echo "FATAL: no commit on ${default_branch} declares versionName ${WANT_VNAME}"; exit 4; }
fi
echo "Building: ${GIT_REF}"
git checkout -q "$GIT_REF" || { echo "FATAL: could not check out ${GIT_REF}"; exit 2; }
echo "=== Revision under build ==="
git log -1 --pretty=format:'%H %ci %s'; echo
git rev-parse HEAD > /output/commit.txt
git merge-base --is-ancestor HEAD "origin/${default_branch}" 2>/dev/null || echo "  NOTE: not reachable from origin/${default_branch}"

echo "=== Toolchain ==="; node --version; yarn --version; java -version 2>&1 | head -1
echo "  NDK $(sed -n 's/^ *ndkVersion *= *"\([^"]*\)".*/\1/p' android/build.gradle)  Gradle $(sed -n 's|.*gradle-\([0-9.]*\)-.*|\1|p' android/gradle/wrapper/gradle-wrapper.properties)"

# Upstream's private .env, restored from the official BuildConfig (metadata/dotenv). Never printed.
cp /dotenv .env
echo "=== .env restored from the official BuildConfig: $(wc -l < .env) keys ==="

echo "=== yarn install --frozen-lockfile === $(date)"
# setup.sh (prepare hook) runs rn-nodeify, tries `pod install`, writes a macOS sdk.dir (replaced below).
yarn install --frozen-lockfile --non-interactive --ignore-engines > /output/yarn-install.log 2>&1 || { tail -40 /output/yarn-install.log; echo "FATAL: yarn install failed"; exit 3; }
tail -3 /output/yarn-install.log
# The build machine's node_modules was a symlink to a sibling checkout's (read from the official bundle): mirrored.
NM="__NM_LINK__"
if [[ -n "$NM" ]]; then
  mkdir -p "$(dirname "$NM")" && mv node_modules "$NM" && ln -s "$NM" node_modules || { echo "FATAL: node_modules relocation to ${NM} failed"; exit 3; }
  printf '\n// walletscrutiny: watch folder of the official layout\nmodule.exports.watchFolders = [...(module.exports.watchFolders || []), require("path").resolve(__dirname, "%s")];\n' "$NM" >> metro.config.js
  echo "  node_modules -> $(readlink -f node_modules) (Metro watch folder added)"
fi
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > android/local.properties
agp="$(sed -n 's/^agp *= *"\([^"]*\)".*/\1/p' node_modules/@react-native/gradle-plugin/gradle/libs.versions.toml 2>/dev/null)"
printf '%s\n' "$agp" > /output/agp.txt
echo "  AGP from react-native gradle-plugin: ${agp:-?}"

# fastlane bumps versionCode uncommitted before a release; the artifact's values rule.
for kv in "versionCode ${WANT_VCODE}" "versionName \"${WANT_VNAME}\""; do
  sed -i -E "s/^( *)${kv%% *}[[:space:]]+.*/\1${kv}/" android/app/build.gradle
done
# The RN gradle plugin writes the host's IPv4 into react_native_dev_server_ip; the variant API overrides it.
[[ -n "$DEV_IP" ]] && printf '\n// walletscrutiny: dev-server IP of the official artifact\nandroidComponents { onVariants(selector().all()) { v -> v.resValues.put(v.makeResValueKey("string", "react_native_dev_server_ip"), new com.android.build.api.variant.ResValue("%s", null)) } }\n' "$DEV_IP" >> android/app/build.gradle
echo "=== Working tree changes before Gradle ==="
git status --porcelain | grep -v -E '^\?\? (\.env|android/local\.properties)$' | head -5
git diff | grep -E '^[-+] ' | grep -v "${DEV_IP:-__none__}" | head -6
# Official version-control-info.textproto: NO_SUPPORTED_VCS_FOUND, built outside a git checkout. Same here.
rm -rf .git

echo "=== Gradle ${GRADLE_TASK} === $(date)"
cd android
# signingConfigs.release reads KEEPER_ANDROID_KEYSTORE/STORE_PASSWORD/KEY_ALIAS/KEY_PASSWORD (older tags:
# MYAPP_RELEASE_* properties); a throwaway key stands in.
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
  [[ -n "$out" ]] || { echo "FATAL: no AAB under app/build/outputs/bundle/productionRelease"; exit 3; }
  cp "$out" /output/built.aab
else
  out="$(ls app/build/outputs/apk/production/release/*.apk 2>/dev/null | head -1)"
  [[ -n "$out" ]] || { echo "FATAL: no APK under app/build/outputs/apk/production/release"; exit 3; }
  cp "$out" /output/built.apk
fi
echo "=== built: $(basename "$out")  sha256 $(sha256sum "$out" | cut -d' ' -f1)"
echo "=== Build complete $(date) ==="
BUILD_END

sed -i -e "s|__REPO_URL__|${REPO_URL}|g" -e "s|__WANT_VNAME__|$wallet_version|g" -e "s|__WANT_VCODE__|$version_code|g" \
  -e "s|__DEV_IP__|$dev_ip|g" -e "s|__SRC_DIR__|$SRC_DIR|g" -e "s|__NM_LINK__|$NM_LINK|g" -e "s|__GRADLE_TASK__|$gradle_task|g" "${img_ctx}/build.sh"

section "Source build (30-90 min cold) - $(date)"
ctr_run build "${BUILD_DIR}/container-build.log" \
  -e "WS_GIT_REVISION=${rev_arg}" --volume "${BUILD_DIR}:/output" \
  --volume "${META_DIR}/dotenv:/dotenv:ro" --volume "${img_ctx}/build.sh:/build.sh:ro" \
  "$IMG" bash /build.sh
BUILD_RC=$?

if [[ $BUILD_RC -ne 0 ]]; then
  if [[ $BUILD_RC -eq 4 ]]; then
    log_error "Cannot pin a revision (${rev_source}): a FINDING, not a script fault."
    fail 1 "The source revision could not be pinned (${rev_source}${rev_arg:+: $rev_arg}); the artifact cannot be matched to published source. Official base APK SHA-256: ${base_hash}."
  fi
  log_error "Source build failed (container exit ${BUILD_RC}: 1=clone, 2=checkout, 3=yarn/gradle)"
  log_info  "Logs: ${BUILD_DIR}/yarn-install.log, ${BUILD_DIR}/gradle-build.log"
  fail 1 "Source build failed for ${APP_ID} $wallet_version (container exit ${BUILD_RC}). Official base APK SHA-256: ${base_hash}."
fi
log_success "Source build finished"

built_ref="$(cat "${BUILD_DIR}/commit.txt" 2>/dev/null | cut -c1-10)"
built_agp="$(cat "${BUILD_DIR}/agp.txt" 2>/dev/null || echo '')"
[[ -z "$official_agp" || "$official_agp" == "$built_agp" ]] && log_info "AGP: artifact ${official_agp:-?}, revision ${built_agp:-?}" || \
  log_warn "AGP MISMATCH: official artifact built with AGP ${official_agp}, revision declares ${built_agp}"

if [[ "$build_mode" == "bundle" ]]; then
  section "Rendering split APKs from the built AAB (bundletool ${BT_VER})"
  # Device spec mirrors the official set (ABI/density/locale splits, base.apk's minSdkVersion).
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
      *) log_warn "Unrecognised config split '${cfg}' - not reflected in the device spec" ;;
    esac
  done
  [[ ${#abis[@]} -eq 0 ]] && abis=("${arch_arg:-arm64-v8a}")
  [[ ${#locales[@]} -eq 0 ]] && locales=("en")
  [[ -z "$density" ]] && density=480
  abis_json="$(printf '"%s",' "${abis[@]}")"; locales_json="$(printf '"%s",' "${locales[@]}")"
  echo "{\"supportedAbis\": [${abis_json%,}], \"supportedLocales\": [${locales_json%,}], \"screenDensity\": ${density}, \"sdkVersion\": ${min_sdk}}" > "${BUILT_DIR}/device-spec.json"
  log_info "device-spec.json: $(cat "${BUILT_DIR}/device-spec.json")"
  ctr_run render "${BUILT_DIR}/render.log" \
    --volume "${BUILD_DIR}/built.aab:/built.aab:ro" --volume "${BUILT_DIR}:/out" \
    "$IMG" bash -c 'set -e; cd /out
      java -jar /opt/bundletool.jar build-apks --bundle=/built.aab --output=/out/built.apks \
        --device-spec=/out/device-spec.json --mode=default --overwrite
      unzip -qq -o /out/built.apks -d /out/apks
      for f in /out/apks/splits/*.apk; do n="$(basename "$f")"
        case "$n" in base-master.apk) c=base.apk ;; base-master_*.apk) c="variant_${n#base-master_}" ;; base-*.apk) c="split_config.${n#base-}" ;; *) c="$n" ;; esac
        mv "$f" "/out/$c"; done
      rm -rf /out/apks /out/built.apks; ls -1 /out/*.apk' | sed 's/^/  /'
  [[ -f "${BUILT_DIR}/base.apk" ]] || fail 1 "bundletool rendered no base split from the built AAB for ${APP_ID} $wallet_version."
  ls "${BUILT_DIR}"/variant_*.apk >/dev/null 2>&1 && log_warn "several base variants rendered; only base-master compared"
else
  cp "${BUILD_DIR}/built.apk" "${BUILT_DIR}/$(basename "$official_base")"
fi

# PHASE 2: no acceptable-diffs filtering; every raw diff must be EARNED by a class that prints evidence.
phase "PHASE 2: COMPARISON"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"

# SourceStamp: earned, never filename-excluded.
stamp_ok() {
  local n sz
  n=$(unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256')
  [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
  [[ -e /tmp/b/stamp-cert-sha256 ]] && { echo "      stamp: present in BUILT too"; return 1; }
  sz=$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null || echo -1)
  [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
  "$BT/apksigner" verify --verbose --print-certs "$o" 2>/dev/null | grep -q 'Verified for SourceStamp: true' \
    || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
  echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

# AndroidManifest: accepted ONLY if the sole delta is Play's official-only distribution meta-data.
manifest_ok() {
  local d left bad n m
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null || return 1
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null || return 1
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"
  printf '%s\n' "$d" > "/out/diff_manifest_${L}.txt"
  printf '%s\n' "$d" | grep -q '^>' && { echo "      manifest: BUILT-only lines present:"; printf '%s\n' "$d" | grep '^>' | head -3 | sed 's/^/        /'; return 1; }
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  bad="$(printf '%s\n' "$left" | grep -vE '^E: meta-data|^A: [^ ]*android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id|vending\.splits|dynamic\.apk\.fused\.modules)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK|base)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)=(@0x7f[0-9a-f]+|[0-9]+)$')"
  if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: unexpected official-only line(s):"; printf '%s\n' "$bad" | head -3 | sed 's/^/        /'; return 1
  fi
  n=$(printf '%s\n' "$left" | grep -c '^E: meta-data')
  m=$(printf '%s\n' "$left" | grep -c 'android:name(0x[0-9a-f]*)="com\.android\.')
  [[ "$n" -ge 1 && "$n" -eq "$m" ]] || { echo "      manifest: $n block(s) vs $m Play name(s)"; return 1; }
  echo "      manifest: ${n} official-only Play meta-data block(s), none built-only:"
  printf '%s\n' "$left" | grep -vE '^E: meta-data' | sed 's/^A: [^ ]*android:/        /'
}

# resources.arsc / res/**: accepted only if the apktool-decoded res/ trees are identical.
res_ok() {
  local rd
  rm -rf /tmp/do /tmp/db
  $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/do "$o" >/dev/null 2>&1 || { echo "      res: DECODE FAILED (official)"; return 1; }
  $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/db "$b" >/dev/null 2>&1 || { echo "      res: DECODE FAILED (built)"; return 1; }
  [[ -d /tmp/do/res && -d /tmp/db/res ]] || { echo "      res: no res/ after decode"; return 1; }
  rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
  printf '%s\n' "$rd" > "/out/diff_resources_decoded_${L}.txt"
  if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then
    echo "      res: decoded res/ tree IDENTICAL (binary packing artifact)"; return 0
  fi
  echo "      res: decoded res/ differs -> material (diff_resources_decoded_${L}.txt)"; printf '%s\n' "$rd" | head -3 | sed 's/^/        /'
  return 1
}

: > /out/summary.txt
for o in /official/*.apk; do
  name="$(basename "$o")"; L="${name%.apk}"; L="${L#split_config.}"; L="${L//[^A-Za-z0-9_]/_}"
  b="/built/${name}"
  echo ""; echo "--- ${name} (label ${L}) ---"
  echo "  official: sha256 $(sha256sum "$o" | cut -d' ' -f1)"
  if [[ ! -f "$b" ]]; then
    echo "  built:    MISSING - the built AAB rendered no ${name}"
    echo "LABEL ${L} 1 0 0 0 0 0 1 missing" >> /out/summary.txt; continue
  fi
  echo "  built:    sha256 $(sha256sum "$b" | cut -d' ' -f1)"
  rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
  unzip -q -o "$o" -d /tmp/o; unzip -q -o "$b" -d /tmp/b
  echo "  entries: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"
  nso=0; nsm=0; nsi=0; OC="${ANDROID_HOME}/ndk/27.1.12297006/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy"; : > /tmp/id_o; : > /tmp/id_b
  while IFS= read -r so; do
    rel="${so#/tmp/o/}"; nso=$((nso + 1)); b2="/tmp/b/${rel}"
    if [[ -f "$b2" ]] && cmp -s "$so" "$b2"; then nsm=$((nsm + 1)); continue; fi
    # Same code, other compiler ident (.comment): a toolchain-host difference.
    if [[ -f "$b2" ]] && "$OC" -R .comment -R .note.gnu.build-id "$so" /tmp/o.so 2>/dev/null && "$OC" -R .comment -R .note.gnu.build-id "$b2" /tmp/b.so 2>/dev/null && cmp -s /tmp/o.so /tmp/b.so; then
      nsi=$((nsi + 1)); echo "  native IDENT-ONLY ${rel} (code identical; .comment/build-id differ)"
      "${OC%objcopy}readelf" -p .comment "$so" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' >> /tmp/id_o; "${OC%objcopy}readelf" -p .comment "$b2" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' >> /tmp/id_b
    else echo "  native DIFFER/MISSING ${rel}"; fi
  done < <(find /tmp/o -name '*.so' -type f | sort)
  [[ "$nso" -gt 0 ]] && echo "  native libs: ${nsm}/${nso} byte-identical, ${nsi} identical modulo compiler ident, $((nso - nsm - nsi)) differ in code"
  [[ -f /tmp/o/assets/index.android.bundle ]] && echo "  JS bundle:   $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo IDENTICAL || echo DIFFERS)"
  dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
  [[ -n "$(cd /tmp/o && ls classes*.dex 2>/dev/null)" ]] && echo "  dex:         ${dx:-all identical}"

  raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"
  printf '%s\n' "$raw" > "/out/diff_${L}.txt"
  n=$(printf '%s\n' "$raw" | grep -vc '^$')
  echo "  raw diffs: ${n}   (full list: diff_${L}.txt)"
  [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | head -5 | sed 's/^/    /'

  # Signing class (file-name allowlist, OFFICIAL side only): root META-INF *.SF/*.RSA/*.DSA/*.EC/MANIFEST.MF,
  # listed as files or as a whole official-only META-INF/ (config splits). Built-only/both-sided entries stay material.
  read -r c_sign c_dir c_stamp c_mani c_res < <(printf '%s\n' "$raw" | awk '
    /^Only in \/tmp\/o\/META-INF: ([^\/ ]*\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$/{a++;next} /^Only in \/tmp\/o: META-INF$/{e++;next}
    /stamp-cert-sha256/{b++;next} /AndroidManifest\.xml/{c++;next} /resources\.arsc|\/tmp\/o\/res\/|\/tmp\/o: res$/{d++}
    END{print a+0, e+0, b+0, c+0, d+0}')
  a_sign=0; a_stamp=0; a_mani=0; a_res=0
  [[ "$n" -gt 0 ]] && echo "  accepted-class evidence"
  # Native libs identical modulo .comment/.note.gnu.build-id (macOS vs Linux NDK clang): evidence only. NOT an
  # accepted class (policy 2026-10-12: upstream can pin its toolchain); they stay UNACCOUNTED.
  if [[ "$nsi" -gt 0 ]]; then
    echo "      ident: ${nsi} native lib(s) identical modulo compiler ident -> UNACCOUNTED (not an accepted class)"; sort -u /tmp/id_o | sed 's/^/        official: /'; sort -u /tmp/id_b | sed 's/^/        built:    /'; fi
  if [[ "$c_sign" -gt 0 ]]; then a_sign=$c_sign
    echo "      signing: ${c_sign} official-only root META-INF signing file(s) - $(ls /tmp/o/META-INF 2>/dev/null | grep -E '\.(SF|RSA|DSA|EC)$|^MANIFEST\.MF$' | paste -sd' ' -)"; fi
  if [[ "$c_dir" -gt 0 ]]; then
    other="$(find /tmp/o/META-INF -mindepth 1 | grep -vE '^/tmp/o/META-INF/([^/]*\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$')"
    if [[ -z "$other" && -n "$(ls -A /tmp/o/META-INF)" ]]; then a_sign=$((a_sign + 1))
      echo "      signing: official-only META-INF/ holds signing files only - $(ls /tmp/o/META-INF | paste -sd' ' -)"
    else echo "      META-INF: official-only directory with other entries -> material:"; printf '%s\n' "$other" | head -3 | sed 's/^/        /'; fi
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
  un=$((n - acc)); [[ "$un" -lt 0 ]] && un=0
  echo "LABEL ${L} ${n} ${a_sign} ${a_stamp} ${a_mani} ${a_res} ${nsi} ${un} compared" >> /out/summary.txt
  echo "  => ${name}: raw ${n}, accepted ${acc}, unaccounted ${un}"
done
for b in /built/*.apk; do
  [[ -f "/official/$(basename "$b")" ]] || echo "  NOTE: built $(basename "$b") has no official counterpart (not compared)"
done
echo ""; echo "=== comparison complete ==="
CMP_END

ctr_run cmp "${CMP_DIR}/comparison.log" \
  --volume "${OFF_DIR}:/official:ro" --volume "${BUILT_DIR}:/built:ro" --volume "${CMP_DIR}:/out" \
  --volume "${img_ctx}/compare.sh:/compare.sh:ro" "$IMG" bash /compare.sh
CMP_RC=$?
if [[ $CMP_RC -ne 0 ]] || ! grep -q '^LABEL' "${CMP_DIR}/summary.txt" 2>/dev/null; then
  log_error "Comparison stage failed (exit ${CMP_RC}) or wrote no LABEL line; see ${CMP_DIR}/comparison.log"
  fail 1 "Comparison stage failed for ${APP_ID} $wallet_version (exit ${CMP_RC}). Official base APK SHA-256: ${base_hash}."
fi

section "RESULT"
printf ' %-14s %5s %9s %8s %8s %6s %6s %11s  %s\n' artifact raw signing stamp manifest res ident UNACCOUNTED verdict
total_unacc=0; n_art=0; n_ok=0; per_art=""
while read -r _ lbl raw s st m r i un _; do
  n_art=$((n_art + 1))
  if [[ "$un" -eq 0 ]]; then v="reproducible"; n_ok=$((n_ok + 1)); else v="not_reproducible"; fi
  total_unacc=$((total_unacc + un))
  printf ' %-14s %5s %9s %8s %8s %6s %6s %11s  %s\n' "$lbl" "$raw" "$s" "$st" "$m" "$r" "$i" "$un" "$v"
  per_art+="${lbl}=${v}(raw ${raw}, unaccounted ${un}, ident-only native libs ${i}) "
done < "${CMP_DIR}/summary.txt"
echo " Verdict is judged on UNACCOUNTED alone; ident (native libs identical modulo compiler ident) is counted there."
echo " Evidence: ${CMP_DIR}/, build logs: ${BUILD_DIR}/"

if [[ "$total_unacc" -eq 0 ]]; then
  verdict="reproducible"; rc=0
  log_success "All ${n_art} artifact(s) reproduced: every difference is an earned class with evidence."
else
  verdict="not_reproducible"; rc=1
  log_error "${n_ok} of ${n_art} artifact(s) reproduced; ${total_unacc} difference(s) unaccounted for. See ${CMP_DIR}/"
fi

generate_yaml "$verdict" "${APP_ID} ${wallet_version} (versionCode ${version_code}) built from ${REPO_URL} commit ${built_ref} (${rev_source}) as ${gradle_task}$( [[ "$build_mode" == "bundle" ]] && echo ", splits rendered with bundletool ${BT_VER} (device spec from the official set)" ), outside a git checkout as the official version-control-info records. Signer ${signer}; official base APK SHA-256 ${base_hash}; .env restored from the artifact's BuildConfig (${n_env} keys, never printed); build-machine inputs mirrored from the artifact: HOME ${BUILD_HOME}, checkout ${SRC_DIR}, Node v${NODE_VERSION}, node_modules link ${NM_LINK:-none}. ${n_ok} of ${n_art} artifact(s) reproduced: ${per_art}Accepted classes (evidence in comparison.log): official-only signing files, Play SourceStamp and manifest meta-data, resources identical after apktool decode. Native libs identical modulo compiler ident are NOT accepted and count as unaccounted."

cat <<EOF

===== Begin Results =====
appId:           ${APP_ID}
signer:          ${signer}
apkVersionName:  ${wallet_version}
apkVersionCode:  ${version_code}
verdict:         ${verdict}
appHash:         ${base_hash}
commit:          $(cat "${BUILD_DIR}/commit.txt" 2>/dev/null || echo unknown)
scriptVersion:   ${SCRIPT_VERSION}
scriptHash:      ${SCRIPT_HASH}
===== End Results =====

appHash = the official $(basename "$official_base") as supplied. Per artifact (official sha256, verdict):
EOF
for f in "${OFF_DIR}"/*.apk; do
  lbl="$(label_of "$(basename "$f")")"
  v="$(awk -v l="$lbl" '$2==l{print ($9==0)?"reproducible":"not_reproducible"}' "${CMP_DIR}/summary.txt")"
  printf '  %-26s %s  %s\n' "$(basename "$f"):" "$(sha256of "$f")" "${v:-unverified}"
done
echo ""; echo "Full diff lists: ${CMP_DIR}/diff_*.txt"; echo ""
echo "Exit code: ${rc}"
exit "$rc"
