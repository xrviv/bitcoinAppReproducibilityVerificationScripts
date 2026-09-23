#!/usr/bin/env bash
# bitcoinkeeper_build.sh - Bitcoin Keeper (Android) reproducible build verification
# Version:          v0.1.2
# Last modified by: Danny Garcia
# Last modified on: 2026-09-23
# Organization:     WalletScrutiny.com
# App ID:           io.hexawallet.bitcoinkeeper
# Project:          https://github.com/bithyve/bitcoin-keeper
#
# Upstream's fastlane "live" lane: bundleProductionRelease for Play (AAB -> config
# splits), assembleProductionRelease for the GitHub fat APK.
# No warranty; review before running.
# Exit codes: 0 = identical, 1 = difference or build failure, 2 = bad parameters.

SCRIPT_VERSION="v0.1.2"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "bitcoinkeeper_build.sh $SCRIPT_VERSION sha256:${SCRIPT_HASH:-unknown}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="bitcoinkeeper_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="io.hexawallet.bitcoinkeeper"
REPO_URL="https://github.com/bithyve/bitcoin-keeper"
# Releases are built on a developer's Mac; its HOME, checkout path and Node end up in the
# artifact. Read from the official APKs and mirrored.
BUILD_HOME="/Users/vaibhav"; SRC_DIR=""; NODE_VERSION=""
# 1.18.2+ writes legacy language codes (iw, in) in res/xml/splits0.xml as Play does.
BT_VER="1.18.3"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner() { printf '\n== %s ==\n' "$*"; }
section() { printf -- '\n-- %s --\n' "$*"; }
phase() { banner "$*"; echo "  $(date)"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# The YAML lands in the script's directory (ABS reads it there).
execution_dir="$SCRIPT_DIR"
invocation_dir="$(pwd -P)"

# Only these three keys, ever: script_version, verdict, notes.
generate_yaml() {
  local verdict="$1" notes="$2"
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: $SCRIPT_VERSION
verdict: ${verdict}
notes: |
 ${notes}
EOF
  if [[ "$invocation_dir" != "$execution_dir" ]]; then
    cp -f "${execution_dir}/COMPARISON_RESULTS.yaml" \
       "${invocation_dir}/COMPARISON_RESULTS.yaml" 2>/dev/null || true
  fi
  log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

fail() {
  local code="$1" note="$2"
  generate_yaml "ftbfs" "$note"
  echo ""; echo "Exit code: ${code}"
  exit "$code"
}

die_invalid() { log_error "$1"; fail 2 "Invalid invocation: $1"; }

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""; rev_arg="${WS_GIT_REVISION:-}"; node_arg="${WS_NODE_VERSION:-}"

require_arg() {
  local flag="$1" val="${2:-}"
  [[ -z "$val" || "$val" == --* ]] && \
    die_invalid "${flag} requires a value (got: '${val:-<nothing>}')"
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <dir|apk> [--git-revision <sha>] [--node-version <x.y.z>] [--version <v>] [--arch <a>] [--type <t>]

 --binary        REQUIRED. Directory with the official Play split set (base.apk +
                 split_config.*.apk, each verified) or one APK (GitHub fat APK or a split).
 --git-revision  Commit to build (7-40 hex). Default: tag v<versionName>, else the newest
                 first-parent default-branch commit declaring versionName + versionCode.
 --node-version  Node for the JS bundle. Default: the version the official bundle embeds.
 --version/--arch/--type  Optional; logged. Version comes from the APK.

Exit codes: 0 = identical, 1 = any difference, 2 = invalid parameters.
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      require_arg --version "${2:-}"; version_arg="$2"; shift 2 ;;
    --binary)       require_arg --binary  "${2:-}"; binary_arg="$2";  shift 2 ;;
    --apk)          require_arg --apk     "${2:-}"; binary_arg="$2";  shift 2 ;;
    --arch)         require_arg --arch    "${2:-}"; arch_arg="$2";    shift 2 ;;
    --type)         require_arg --type    "${2:-}"; type_arg="$2";    shift 2 ;;
    --git-revision) require_arg --git-revision "${2:-}"; rev_arg="$2"; shift 2 ;;
    --node-version) require_arg --node-version "${2:-}"; node_arg="$2"; shift 2 ;;
    -h|--help)      usage; echo "Exit code: 0"; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift; continue ;;
  esac
done

if [[ -z "$binary_arg" ]]; then
  log_error "--binary is required: pass the official Play split directory or APK."
  fail 2 "--binary not provided. Pass the official Google Play split set (directory) or APK of ${APP_ID}."
fi
[[ -e "$binary_arg" ]] || die_invalid "--binary path does not exist: ${binary_arg}"
binary_is_dir=0
if [[ -d "$binary_arg" ]]; then
  binary_arg="${binary_arg%/}"
  [[ -f "${binary_arg}/base.apk" ]] || \
    die_invalid "--binary directory contains no base.apk: ${binary_arg} (a Play split set needs its base.apk)"
  binary_is_dir=1
fi
[[ "$binary_is_dir" -eq 1 || -f "$binary_arg" ]] || die_invalid "--binary is not a regular file: ${binary_arg}"
[[ -z "$rev_arg" || "$rev_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || \
  die_invalid "--git-revision must be 7-40 hex characters (got: '${rev_arg}')"
[[ -z "$node_arg" || "$node_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die_invalid "--node-version must be x.y.z (got: '${node_arg}')"

binary_path="$(realpath "$binary_arg")"

[[ -n "$arch_arg" ]]    && log_info "--arch ${arch_arg} accepted; the ABIs verified are those in the supplied set"
[[ -n "$type_arg" ]]    && log_info "--type ${type_arg} accepted but not used"
[[ -n "$version_arg" ]] && log_info "--version ${version_arg} accepted; the version comes from the APK"
[[ -n "$rev_arg" ]]     && log_info "--git-revision ${rev_arg}: overrides tag/versionCode resolution"

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v podman &>/dev/null; then
    CONTAINER_CMD=podman
  elif command -v docker &>/dev/null; then
    CONTAINER_CMD=docker
  else
    die_invalid "Neither podman nor docker found in PATH"
  fi
fi

# Container user = host user, so no root-owned leftovers.
if [[ "$CONTAINER_CMD" == "podman" ]]; then
  CONTAINER_RUN_USER_ARGS=(--userns=keep-id)
else
  CONTAINER_RUN_USER_ARGS=(--user "${HOST_UID}:${HOST_GID}")
fi

MEM_LIMIT="${MEM_LIMIT:-24g}"
MEM_ARGS=()
[[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")

crun() {
  $CONTAINER_CMD run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -e "HOME=${BUILD_HOME}" "${MEM_ARGS[@]}" "$@"
}

section "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-10s OK  (%s)\n" "$CONTAINER_CMD" "$(command -v "$CONTAINER_CMD")"
command -v unzip >/dev/null || die_invalid "unzip is required on the host (reads the official APKs)"
echo "  unzip + grep read the official APKs; no other host tool."

RUN_ID="bitcoinkeeper-$(date +%s)-$$"
IMG="ws-bitcoinkeeper-${RUN_ID}"
workspace="${execution_dir}/bitcoinkeeper_verification_${RUN_ID}"
META_DIR="${workspace}/metadata"
BUILD_DIR="${workspace}/source-build"
CMP_DIR="${workspace}/comparison"
OFF_DIR="${workspace}/official"
img_ctx=""

mkdir -p "$META_DIR" "$BUILD_DIR" "$CMP_DIR" "$OFF_DIR"

# Root inside the container on purpose: hands everything back to the caller before cleanup.
reclaim_workspace() {
  local path="$1" stray
  [[ -e "$path" ]] || return 0
  if [[ "$CONTAINER_CMD" == *podman ]]; then
    $CONTAINER_CMD unshare chown -R 0:0 "$path" >/dev/null 2>&1 || \
      log_warn "Could not normalise ownership for ${path}"
  elif $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1; then
    $CONTAINER_CMD run --rm --user 0:0 -v "${path}:/target" "$IMG" \
      sh -c "chown -R ${HOST_UID}:${HOST_GID} /target" >/dev/null 2>&1 || \
      log_warn "Could not normalise ownership for ${path}"
  fi
  stray="$(find "$path" ! -uid "$HOST_UID" -print -quit 2>/dev/null || true)"
  [[ -n "$stray" ]] && log_warn "Still not caller-owned: ${stray}"
  return 0
}

cleanup() {
  log_info "Cleaning up build image and temporary context..."
  reclaim_workspace "$workspace"
  $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1 || true
  [[ -n "$img_ctx" ]] && rm -rf "$img_ctx" 2>/dev/null
  log_success "Cleanup complete."
}
trap cleanup EXIT

# Official artifacts get canonical names: base.apk, split_config.<cfg>.apk.
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
  log_info "Collected ${n_apk} official APK(s) from ${binary_path}; all of them will be verified"
else
  cn="$(canonical_name "$(basename "$binary_path")")"
  cp "$binary_path" "${OFF_DIR}/${cn}"
fi
official_base="$(ls "${OFF_DIR}"/base.apk 2>/dev/null || ls "${OFF_DIR}"/*.apk | head -1)"

section "BUILD-MACHINE INPUTS READ FROM THE OFFICIAL ARTIFACT"
# librealm.so / libappmodules.so keep source and prefab header paths in .rodata.
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
# The bundling Node's process.version is inlined into the Hermes bundle (the only bundle
# difference between Node versions); Hermes packs strings back to back, so no word boundaries.
node_cands="$(unzip -p "$official_base" assets/index.android.bundle 2>/dev/null | grep -aoE 'v[0-9]{2}\.[0-9]+\.[0-9]+' | sort -u | sort -t. -k1.2,1n -k2,2n -k3,3n | paste -sd' ' -)"
if [[ -n "$node_arg" ]]; then NODE_VERSION="$node_arg"; node_src="--node-version"
elif [[ -n "$node_cands" ]]; then NODE_VERSION="${node_cands##* }"; NODE_VERSION="${NODE_VERSION#v}"; node_src="official Hermes bundle"
else NODE_VERSION="22.21.1"; node_src="default, nothing found in the official bundle"; fi
echo "  HOME (Gradle cache): ${BUILD_HOME}"
echo "  Checkout path:       ${SRC_DIR}"
echo "  Node:                v${NODE_VERSION} (${node_src}; bundle candidates: ${node_cands:-none})"

banner "BITCOIN KEEPER - ANDROID VERIFICATION"
cat <<EOF
 Script:    ${SCRIPT_NAME} $SCRIPT_VERSION
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Input:     ${binary_path}$( [[ "$binary_is_dir" -eq 1 ]] && echo " (split set)" )
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${workspace}
 Date:      $(date)
EOF

phase "SETUP: BUILD CONTAINER IMAGE"

img_ctx="$(mktemp -d)"

# Pins come from the tag's files: android/build.gradle (NDK 27.1.12297006, build-tools
# 35.0.0, compileSdk 36), gradle-wrapper (8.14.3), @react-native/gradle-plugin (AGP 8.12.0,
# the version the artifact records). No CI builds releases: Temurin 17 is the JDK assumption.
cat > "${img_ctx}/Dockerfile" <<DOCKERFILE_END
FROM ubuntu:24.04@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git unzip zip wget curl ca-certificates xz-utils python3 libatomic1 && \\
  rm -rf /var/lib/apt/lists/*

RUN cd /tmp && \\
  wget -q https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt && \\
  grep " node-v${NODE_VERSION}-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c - && \\
  mkdir -p /opt/node && tar -xJf node-v${NODE_VERSION}-linux-x64.tar.xz -C /opt/node --strip-components=1 && \\
  rm node-v${NODE_VERSION}-linux-x64.tar.xz SHASUMS256.txt && PATH=/opt/node/bin:\$PATH npm install -g yarn@1.22.22 >/dev/null

RUN cd /tmp && \\
  wget -q -O jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz" && \\
  echo "d8afc263758141a66e0e3aafc321e783f7016696f4eaea067d340a269037d331  jdk.tar.gz" | sha256sum -c - && \\
  mkdir -p /opt/jdk && tar -xzf jdk.tar.gz -C /opt/jdk --strip-components=1 && rm jdk.tar.gz

ENV JAVA_HOME=/opt/jdk
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="/opt/node/bin:\${ANDROID_HOME}/cmdline-tools/latest/bin:\${ANDROID_HOME}/platform-tools:\${JAVA_HOME}/bin:\${PATH}"

RUN mkdir -p \${ANDROID_HOME}/cmdline-tools && cd \${ANDROID_HOME}/cmdline-tools && \\
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O ct.zip && \\
  echo "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258  ct.zip" | sha256sum -c - && \\
  unzip -q ct.zip && rm ct.zip && mv cmdline-tools latest

# SDK read-only for the build user: anything AGP would auto-install is pre-installed.
RUN yes | sdkmanager --licenses >/dev/null && \\
  sdkmanager "platforms;android-36" "platforms;android-33" "build-tools;35.0.0" "build-tools;36.0.0" "platform-tools" \\
    "ndk;27.1.12297006" "ndk;27.0.12077973" "cmake;3.22.1" >/dev/null && chmod -R a+rX \${ANDROID_HOME}

RUN cd /opt && \\
  wget -q -O apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar && \\
  echo "dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423  apktool.jar" | sha256sum -c - && \\
  wget -q -O bundletool.jar https://github.com/google/bundletool/releases/download/${BT_VER}/bundletool-all-${BT_VER}.jar && \\
  echo "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29  bundletool.jar" | sha256sum -c - && \\
  chmod 0644 apktool.jar bundletool.jar

RUN mkdir -p /tmp/afw ${BUILD_HOME} $(dirname "${SRC_DIR}") && chmod 0777 /tmp /tmp/afw ${BUILD_HOME} $(dirname "${SRC_DIR}")
WORKDIR ${BUILD_HOME}
DOCKERFILE_END

section "Building image ${IMG}"
if ! $CONTAINER_CMD build -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx"; then
  log_error "Container image build failed - see the output above."
  fail 1 "Container image build failed; no comparison was performed."
fi
log_success "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL BINARY METADATA"

# react-native-config compiles the private .env into BuildConfig; recovered from the dex.
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
    F = [(S[u32(b, fo + 8 * i + 4)], T[struct.unpack_from('<H', b, fo + 8 * i + 2)[0]]) for i in range(fn)]  # (name, type)
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
                if vt == 0x17: vals.append(S[int.from_bytes(b[o:o + va + 1], 'little')]); o += va + 1
                elif vt == 0x1f: vals.append(str(bool(va)).lower())
                elif vt in (0, 2, 3, 4, 6): vals.append(str(int.from_bytes(b[o:o + va + 1], 'little', signed=True))); o += va + 1
                else: vals.append(None); o += va + 1
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
# Anchor on '^package:' and stop at the first quote (a greedy match returns versionName).
pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"
# aapt2: minSdkVersion: (aapt1: sdkVersion:); xmltree is the fallback.
minsdk="$(printf '%s\n' "$info" | sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" | head -1)"
split_name="$(printf '%s\n' "$info" | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
abis="$(printf '%s\n' "$info" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
sv="$("$BT/apksigner" verify --verbose --print-certs $A 2>/dev/null)"
signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"
stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"
# grep -c reads to EOF: grep -q would SIGPIPE unzip under pipefail (has_lib=0 on a fat APK).
has_lib=0; [[ "$(unzip -Z1 $A 2>/dev/null | grep -c '^lib/')" -gt 0 ]] && has_lib=1
vcs="$(unzip -p $A META-INF/version-control-info.textproto 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
agp="$(unzip -p $A META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null \
  | sed -n 's/^androidGradlePluginVersion=//p' | head -1)"
"$BT/aapt2" dump xmltree --file AndroidManifest.xml $A > /output/manifest-official.txt 2>/dev/null
# The RN gradle plugin writes the BUILD HOST's LAN IP into this release resource.
devip="$("$BT/aapt2" dump resources $A 2>/dev/null | grep -A1 'string/react_native_dev_server_ip' \
  | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)"

python3 /buildconfig.py $A > /output/buildconfig.txt 2>/output/buildconfig.err
bc_rc=$?
: > /output/dotenv
nenv=0
if [[ $bc_rc -eq 0 ]]; then
  # Every String field except the ones AGP itself generates is a react-native-config key.
  while IFS=$'\t' read -r name typ val; do
    [[ "$typ" == "Ljava/lang/String;" ]] || continue
    case "$name" in APPLICATION_ID|BUILD_TYPE|FLAVOR|VERSION_NAME) continue ;; esac
    printf '%s=%s\n' "$name" "$val" >> /output/dotenv; nenv=$((nenv + 1))
  done < <(grep -v '^#' /output/buildconfig.txt)
fi
bc_vcode="$(awk -F'\t' '$1=="VERSION_CODE"{print $3}' /output/buildconfig.txt 2>/dev/null)"

for kv in "pkg_name:${pkg:-unknown}" "version_name:${vname:-unknown}" "version_code:${vcode:-unknown}" \
  "signer:${signer:-unknown}" "split_name:${split_name}" "vcs:${vcs}" "agp:${agp}" "abis:${abis}" \
  "stamp:${stamp}" "has_lib:${has_lib}" "min_sdk:${minsdk}" "dev_ip:${devip}" "nenv:${nenv}"; do
  printf '%s\n' "${kv#*:}" > "/output/${kv%%:*}.txt"
done

cat <<META
[META] package:             ${pkg:-unknown}
[META] versionName:         ${vname:-unknown}
[META] versionCode:         ${vcode:-unknown} (BuildConfig.VERSION_CODE: ${bc_vcode:-?})
[META] minSdkVersion:       ${minsdk:-?}
[META] native ABIs:         ${abis:-<none>} (has lib/: ${has_lib}; 1 = fat APK, 0 = split base)
[META] signer SHA-256:      ${signer:-unknown}
[META] SourceStamp:         ${stamp} (apksigner "Verified for SourceStamp")
[META] AGP version:         ${agp:-<none>} (META-INF/.../app-metadata.properties)
[META] VCS info:            ${vcs:-<none>} (META-INF/version-control-info.textproto)
[META] dev_server_ip res:   ${devip:-<none>} (build host LAN IP written by the RN gradle plugin)
[META] split name:          ${split_name:-<none>} (empty = not a split)
[META] BuildConfig .env:    ${nenv} key(s) recovered from $(grep '^#dex' /output/buildconfig.txt 2>/dev/null | cut -d' ' -f2) (exit ${bc_rc})
META
sed 's/^\([^=]*=\)\(.\{0,72\}\).*/  \1\2/' /output/dotenv
META_END
chmod +x "${img_ctx}/meta.sh"

if ! crun \
  --volume "${official_base}:/input/base.apk:ro" \
  --volume "${META_DIR}:/output" \
  --volume "${img_ctx}/meta.sh:/meta.sh:ro" \
  --volume "${img_ctx}/buildconfig.py:/buildconfig.py:ro" \
  "$IMG" bash /meta.sh; then
  log_error "Metadata extraction failed - aapt2/apksigner could not read the APK."
  fail 1 "Could not read metadata from the official APK."
fi

meta() { local v; v="$(cat "${META_DIR}/$1.txt" 2>/dev/null)"; [[ -n "$v" ]] && echo "$v" || echo "${2:-}"; }
pkg_id="$(meta pkg_name unknown)"
wallet_version="$(meta version_name unknown)"
version_code="$(meta version_code unknown)"
signer="$(meta signer unknown)"
official_agp="$(meta agp)"
dev_ip="$(meta dev_ip)"
split_name="$(meta split_name)"
has_lib="$(meta has_lib 0)"
min_sdk="$(meta min_sdk 26)"
n_env="$(meta nenv 0)"
base_hash="$(sha256of "$official_base")"

[[ "$pkg_id" == "$APP_ID" ]] || \
  die_invalid "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
log_success "Package name verified: ${pkg_id}"
log_success "Version: $wallet_version (versionCode $version_code)"
log_info    "Signer SHA-256:   ${signer}"
log_info    "base APK SHA-256: ${base_hash}"

[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || \
  die_invalid "Could not read versionName from the APK"
[[ "$version_code" =~ ^[0-9]+$ ]] || die_invalid "Could not read versionCode from the APK"
[[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]] && \
  log_warn "--version was '${version_arg}' but the APK reports '$wallet_version'; using the binary's value"
if [[ -n "$split_name" ]]; then
  log_error "$(basename "$official_base") declares split name '${split_name}'; pass the directory holding base.apk and its splits."
  fail 2 "The supplied APK is a config split ('${split_name}') without its base.apk."
fi
[[ "$n_env" -gt 0 ]] || \
  fail 1 "No react-native-config keys in the official BuildConfig (metadata/buildconfig.err): .env not recoverable, build not attempted."

# Fat APK (lib/ inside) = `assemble productionRelease`; split base = `bundle productionRelease`.
if [[ "$has_lib" -eq 1 ]]; then
  build_mode="apk"
  [[ "$binary_is_dir" -eq 1 ]] && log_warn "base.apk carries lib/: treating the input as a fat APK, other files in the directory are ignored"
  log_info "Mode: fat APK (GitHub release layout) -> assembleProductionRelease"
else
  build_mode="bundle"
  log_info "Mode: Play split set -> bundleProductionRelease + bundletool ${BT_VER} (device spec from the official splits)"
  [[ "$binary_is_dir" -eq 1 ]] || log_warn "Single split supplied: ONLY base.apk is verified; pass the whole directory for full coverage"
fi

section "Resolving source revision"
if [[ -n "$rev_arg" ]]; then
  rev_source="--git-revision"
else
  rev_source="tag v${wallet_version}, else newest first-parent commit of the default branch declaring versionName ${wallet_version} + versionCode ${version_code}"
fi
echo "  Revision: ${rev_arg:-<resolved in container>}"
echo "  Source:   ${rev_source}"
if [[ -n "$dev_ip" ]]; then
  log_info "react_native_dev_server_ip=${dev_ip} in the official resources (RN gradle plugin, build host IPv4): set on the variant like versionCode"
else
  log_info "No react_native_dev_server_ip resource in the official APK"
fi

phase "PHASE 1: BUILD FROM SOURCE"

cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
REPO_URL="__REPO_URL__"
WANT_VNAME="__WANT_VNAME__"
WANT_VCODE="__WANT_VCODE__"
DEV_IP="__DEV_IP__"
GRADLE_TASK="__GRADLE_TASK__"
SRC="__SRC_DIR__"

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
    echo "FATAL: revision ${WS_GIT_REVISION} is not in the public repository ${REPO_URL}."
    exit 4
  fi
  echo "=== Pinned revision ${GIT_REF} (--git-revision) ==="
elif git rev-parse -q --verify "refs/tags/v${WANT_VNAME}^{commit}" >/dev/null; then
  GIT_REF="$(git rev-parse "refs/tags/v${WANT_VNAME}^{commit}")"
  echo "=== Tag v${WANT_VNAME} -> ${GIT_REF} ($(git cat-file -t "refs/tags/v${WANT_VNAME}") tag) ==="
  git tag -v "v${WANT_VNAME}" 2>&1 | head -3 | sed 's/^/  /'
else
  # No tag: the newest default-branch commit whose build.gradle declares exactly this build.
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
    echo "AMBIGUOUS: no commit declares versionCode ${WANT_VCODE}; using the newest one declaring versionName ${WANT_VNAME} (--git-revision overrides)."
  fi
  [[ -n "$GIT_REF" ]] || { echo "FATAL: no commit on ${default_branch} declares versionName ${WANT_VNAME}"; exit 4; }
fi
echo "Building: ${GIT_REF}"
git checkout -q "$GIT_REF" || { echo "FATAL: could not check out ${GIT_REF}"; exit 2; }
echo "=== Revision under build ==="
git log -1 --pretty=format:'%H %ci %s'; echo
git rev-parse HEAD > /output/commit.txt
git merge-base --is-ancestor HEAD "origin/${default_branch}" 2>/dev/null \
  && echo "  reachable from origin/${default_branch}" || echo "  NOTE: not reachable from origin/${default_branch}"

echo "=== Toolchain ==="; node --version; yarn --version; java -version 2>&1 | head -1
echo "  NDK $(sed -n 's/^ *ndkVersion *= *"\([^"]*\)".*/\1/p' android/build.gradle)  Gradle $(sed -n 's|.*gradle-\([0-9.]*\)-.*|\1|p' android/gradle/wrapper/gradle-wrapper.properties)"

# The release lane fetches the private production .env before building; the values it
# baked into BuildConfig were read back from the official APK (metadata/dotenv).
cp /dotenv .env
echo "=== .env restored from the official BuildConfig: $(wc -l < .env) keys ==="

echo "=== yarn install --frozen-lockfile === $(date)"
# setup.sh (prepare hook) runs rn-nodeify, tries `pod install`, writes a macOS sdk.dir (replaced
# below). Engines are ignored as upstream does (posthog-node vs the bundling Node).
yarn install --frozen-lockfile --non-interactive --ignore-engines > /output/yarn-install.log 2>&1 || { tail -40 /output/yarn-install.log; echo "FATAL: yarn install failed"; exit 3; }
tail -3 /output/yarn-install.log
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > android/local.properties
agp="$(sed -n 's/^agp *= *"\([^"]*\)".*/\1/p' node_modules/@react-native/gradle-plugin/gradle/libs.versions.toml 2>/dev/null)"
printf '%s\n' "$agp" > /output/agp.txt
echo "  AGP from react-native gradle-plugin: ${agp:-?} ($(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' node_modules/@react-native/gradle-plugin/package.json | head -1))"

# fastlane's bump_version_code edits build.gradle before every release build without
# committing; the artifact's own values are authoritative.
for kv in "versionCode ${WANT_VCODE}" "versionName \"${WANT_VNAME}\""; do
  sed -i -E "s/^( *)${kv%% *}[[:space:]]+.*/\1${kv}/" android/app/build.gradle
done
# The RN gradle plugin writes the host's first IPv4 into react_native_dev_server_ip (no property
# override); the variant API has the last word on resValues.
[[ -n "$DEV_IP" ]] && printf '\n// walletscrutiny: dev-server IP of the official artifact (build input, like versionCode)\nandroidComponents { onVariants(selector().all()) { v -> v.resValues.put(v.makeResValueKey("string", "react_native_dev_server_ip"), new com.android.build.api.variant.ResValue("%s", null)) } }\n' "$DEV_IP" >> android/app/build.gradle
echo "=== Working tree changes before Gradle (expected: versionCode/versionName and the dev-server IP block) ==="
git status --porcelain | grep -v -E '^\?\? (\.env|android/local\.properties)$' | head -5
git diff | grep -E '^[-+] ' | head -6

echo "=== Gradle ${GRADLE_TASK} === $(date)"
cd android
# 1adf4f66 names a keystore absent from git in gradle.properties; -P uses a throwaway key.
keytool -genkeypair -keystore /tmp/ws.jks -storepass wsverify -alias ws -keyalg RSA -dname CN=WS >/dev/null 2>&1
./gradlew "$GRADLE_TASK" -PMYAPP_RELEASE_STORE_FILE=/tmp/ws.jks -PMYAPP_RELEASE_KEY_ALIAS=ws -PMYAPP_RELEASE_STORE_PASSWORD=wsverify \
  -PMYAPP_RELEASE_KEY_PASSWORD=wsverify --no-daemon --stacktrace --console=plain > /output/gradle-build.log 2>&1
rc=$?
grep -E '^> Task :app:(createBundle|externalNativeBuild|package|bundle)|BUILD (SUCCESSFUL|FAILED)|FAILURE|What went wrong' /output/gradle-build.log | head -12
echo "=== SDK components present after Gradle (platforms / build-tools / ndk / cmake) ==="
for d in platforms build-tools ndk cmake; do echo "  $d: $(ls ${ANDROID_HOME}/$d 2>/dev/null | tr '\n' ' ')"; done
if [[ $rc -ne 0 ]]; then
  tail -40 /output/gradle-build.log
  echo "FATAL: gradle build failed (exit ${rc}) - full log at /output/gradle-build.log"
  exit 3
fi
if [[ "$GRADLE_TASK" == "bundleProductionRelease" ]]; then
  out="$(ls app/build/outputs/bundle/productionRelease/*.aab 2>/dev/null | head -1)"
  [[ -n "$out" ]] || { echo "FATAL: no AAB under app/build/outputs/bundle/productionRelease"; ls app/build/outputs/bundle/productionRelease 2>/dev/null; exit 3; }
  cp "$out" /output/built.aab
else
  out="$(ls app/build/outputs/apk/production/release/*.apk 2>/dev/null | head -1)"
  [[ -n "$out" ]] || { echo "FATAL: no APK under app/build/outputs/apk/production/release"; ls app/build/outputs/apk/production/release 2>/dev/null; exit 3; }
  cp "$out" /output/built.apk
fi
echo "=== built: $(basename "$out")  sha256 $(sha256sum "$out" | cut -d' ' -f1)"
echo "=== Build complete $(date) ==="
BUILD_END

if [[ "$build_mode" == "bundle" ]]; then gradle_task="bundleProductionRelease"; else gradle_task="assembleProductionRelease"; fi
sed -i \
  -e "s|__REPO_URL__|${REPO_URL}|g" \
  -e "s|__WANT_VNAME__|$wallet_version|g" \
  -e "s|__WANT_VCODE__|$version_code|g" \
  -e "s|__DEV_IP__|$dev_ip|g" \
  -e "s|__SRC_DIR__|$SRC_DIR|g" \
  -e "s|__GRADLE_TASK__|$gradle_task|g" \
  "${img_ctx}/build.sh"
chmod +x "${img_ctx}/build.sh"

section "Source build (30-60 min cold) - $(date)"
crun \
  -e "WS_GIT_REVISION=${rev_arg}" \
  --volume "${BUILD_DIR}:/output" \
  --volume "${META_DIR}/dotenv:/dotenv:ro" \
  --volume "${img_ctx}/build.sh:/build.sh:ro" \
  "$IMG" bash /build.sh 2>&1 | tee "${BUILD_DIR}/container-build.log"
BUILD_RC=${PIPESTATUS[0]}

if [[ $BUILD_RC -ne 0 ]]; then
  # Container exit codes: 1 clone, 2 checkout, 3 yarn/gradle, 4 revision not found.
  if [[ $BUILD_RC -eq 4 ]]; then
    log_error "Cannot pin a revision (${rev_source}). This is a FINDING, not a script fault."
    fail 1 "The source revision could not be pinned (${rev_source}${rev_arg:+: $rev_arg}); the artifact cannot be matched to published source. Official base APK SHA-256: ${base_hash}."
  fi
  log_error "Source build failed (container exit ${BUILD_RC}: 1=clone, 2=checkout, 3=yarn/gradle)"
  log_info  "Logs: ${BUILD_DIR}/yarn-install.log, ${BUILD_DIR}/gradle-build.log"
  fail 1 "Source build failed for ${APP_ID} $wallet_version (container exit ${BUILD_RC}). Official base APK SHA-256: ${base_hash}."
fi
log_success "Source build finished"

built_ref="$(cat "${BUILD_DIR}/commit.txt" 2>/dev/null | cut -c1-10)"
built_agp="$(cat "${BUILD_DIR}/agp.txt" 2>/dev/null || echo '')"
if [[ -n "$official_agp" && -n "$built_agp" ]]; then
  if [[ "$official_agp" == "$built_agp" ]]; then
    log_success "AGP cross-check: official artifact and built revision both use AGP ${built_agp}"
  else
    log_warn "AGP cross-check MISMATCH: official artifact built with AGP ${official_agp}, revision declares ${built_agp}"
  fi
fi

BUILT_DIR="${workspace}/built"
mkdir -p "$BUILT_DIR"
if [[ "$build_mode" == "bundle" ]]; then
  section "Rendering split APKs from the built AAB (bundletool ${BT_VER})"
  # Device spec mirrors the official set (ABI/density/locale splits); the official base.apk's
  # minSdkVersion selects the same minSdk-tier variant Play served.
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
  cat > "${BUILT_DIR}/device-spec.json" <<EOF
{"supportedAbis": [${abis_json%,}], "supportedLocales": [${locales_json%,}], "screenDensity": ${density}, "sdkVersion": ${min_sdk}}
EOF
  log_info "device-spec.json: abis=[${abis_json%,}] locales=[${locales_json%,}] density=${density} sdkVersion=${min_sdk}"
  crun \
    --volume "${BUILD_DIR}/built.aab:/built.aab:ro" \
    --volume "${BUILT_DIR}:/out" \
    "$IMG" bash -c 'set -e; cd /out
      java -jar /opt/bundletool.jar build-apks --bundle=/built.aab --output=/out/built.apks \
        --device-spec=/out/device-spec.json --mode=default --overwrite
      unzip -qq -o /out/built.apks -d /out/apks
      for f in /out/apks/splits/*.apk; do n="$(basename "$f")"
        case "$n" in base-master.apk) c=base.apk ;; base-master_*.apk) c="variant_${n#base-master_}" ;; base-*.apk) c="split_config.${n#base-}" ;; *) c="$n" ;; esac
        mv "$f" "/out/$c"; done
      rm -rf /out/apks /out/built.apks; ls -1 /out/*.apk' 2>&1 | sed 's/^/  /'
  [[ -f "${BUILT_DIR}/base.apk" ]] || fail 1 "bundletool rendered no base split from the built AAB for ${APP_ID} $wallet_version."
  ls "${BUILT_DIR}"/variant_*.apk >/dev/null 2>&1 && log_warn "bundletool rendered several base variants; only base-master (lowest minSdk tier) is compared"
else
  cp "${BUILD_DIR}/built.apk" "${BUILT_DIR}/$(basename "$official_base")"
fi

# PHASE 2: no acceptable-diffs filtering; every raw diff must be EARNED by a class that
# prints its evidence. One pass per official APK.
phase "PHASE 2: COMPARISON"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"

# SourceStamp: EARNED, never filename-excluded. Play injects it post-build.
stamp_ok() {
  local n sz
  n=$(unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256')
  [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
  [[ -e /tmp/b/stamp-cert-sha256 ]] && { echo "      stamp: present in BUILT too"; return 1; }
  sz=$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null || echo -1)
  [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
  "$BT/apksigner" verify --verbose --print-certs "$o" 2>/dev/null \
    | grep -q 'Verified for SourceStamp: true' \
    || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
  echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

# AndroidManifest: accepted ONLY if the sole delta is Play's distribution meta-data,
# official-only. Everything is printed, not counted.
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
    echo "      manifest: unexpected official-only line(s):"
    printf '%s\n' "$bad" | head -3 | sed 's/^/        /'
    return 1
  fi
  n=$(printf '%s\n' "$left" | grep -c '^E: meta-data')
  m=$(printf '%s\n' "$left" | grep -c 'android:name(0x[0-9a-f]*)="com\.android\.')
  [[ "$n" -ge 1 && "$n" -eq "$m" ]] || { echo "      manifest: $n block(s) vs $m Play name(s)"; return 1; }
  echo "      manifest: ${n} official-only Play meta-data block(s), none built-only:"
  printf '%s\n' "$left" | grep -vE '^E: meta-data' | sed 's/^A: [^ ]*android:/        /'
}

# resources.arsc / res/**: accepted only when the apktool-decoded res/ trees are identical.
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
    echo "  built:    MISSING - the built bundle rendered no ${name}"
    echo "LABEL ${L} 1 0 0 0 0 1 missing" >> /out/summary.txt; continue
  fi
  echo "  built:    sha256 $(sha256sum "$b" | cut -d' ' -f1)"
  rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
  unzip -q -o "$o" -d /tmp/o; unzip -q -o "$b" -d /tmp/b
  echo "  entries: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"
  nso=0; nsm=0; nsi=0; OC="${ANDROID_HOME}/ndk/27.1.12297006/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy"; idents=""
  while IFS= read -r so; do
    rel="${so#/tmp/o/}"; nso=$((nso + 1)); b2="/tmp/b/${rel}"
    if [[ -f "$b2" ]] && cmp -s "$so" "$b2"; then nsm=$((nsm + 1)); continue; fi
    # Same code, other compiler ident (.comment): a toolchain-host difference, not a source one.
    if [[ -f "$b2" ]] && "$OC" -R .comment -R .note.gnu.build-id "$so" /tmp/o.so 2>/dev/null && "$OC" -R .comment -R .note.gnu.build-id "$b2" /tmp/b.so 2>/dev/null && cmp -s /tmp/o.so /tmp/b.so; then
      nsi=$((nsi + 1)); echo "  native IDENT-ONLY ${rel} (code identical; .comment/build-id differ)"
    else echo "  native DIFFER/MISSING ${rel}"; fi
    [[ -z "$idents" && -f "$b2" ]] && idents="$(printf 'official: %s\n      built:    %s' "$("${OC%objcopy}strings" -n 8 "$so" | grep -m2 'clang version' | sed 's/ (https[^)]*)//' | paste -sd'|')" "$("${OC%objcopy}strings" -n 8 "$b2" | grep -m2 'clang version' | sed 's/ (https[^)]*)//' | paste -sd'|')")"
  done < <(find /tmp/o -name '*.so' -type f | sort)
  [[ "$nso" -gt 0 ]] && echo "  native libs: ${nsm}/${nso} byte-identical, ${nsi} identical modulo compiler ident, $((nso - nsm - nsi)) differ in code"
  [[ -n "$idents" ]] && printf '  clang idents (.comment) of the first differing lib:\n      %s\n' "$idents"
  [[ -f /tmp/o/assets/index.android.bundle ]] && echo "  JS bundle:   $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo IDENTICAL || echo DIFFERS) (assets/index.android.bundle, Hermes bytecode)"
  dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
  [[ -n "$(cd /tmp/o && ls classes*.dex 2>/dev/null)" ]] && echo "  dex:         ${dx:-all identical}"

  raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"
  printf '%s\n' "$raw" > "/out/diff_${L}.txt"
  n=$(printf '%s\n' "$raw" | grep -vc '^$')
  echo "  raw diffs: ${n}   (full list: diff_${L}.txt)"
  [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | head -5 | sed 's/^/    /'

  read -r c_sign c_stamp c_mani c_res < <(printf '%s\n' "$raw" | awk '
    /^Only in \/tmp\/o: META-INF$/{a++;next}
    /^(Only in \/tmp\/o\/META-INF: |Files \/tmp\/o\/META-INF\/)[^\/ ]*(\.(SF|RSA|DSA|EC)|MANIFEST\.MF)( |$)/{a++;next}
    /stamp-cert-sha256/{b++;next} /AndroidManifest\.xml/{c++;next} /resources\.arsc|\/tmp\/o\/res\/|\/tmp\/o: res$/{d++}
    END{print a+0, b+0, c+0, d+0}')
  a_sign=0; a_stamp=0; a_mani=0; a_res=0
  [[ "$n" -gt 0 ]] && echo "  accepted-class evidence"
  if [[ "$c_sign" -gt 0 ]]; then a_sign=$c_sign
    echo "      signing: ${c_sign} root META-INF entry(ies) - $(ls /tmp/o/META-INF 2>/dev/null | paste -sd' ' -); Play/upstream sign, local build unsigned"; fi
  if [[ "$c_stamp" -gt 0 ]]; then
    if stamp_ok; then a_stamp=$c_stamp; else echo "      stamp: NOT EARNED -> material"; fi
  fi
  if [[ "$c_mani" -gt 0 ]]; then
    if manifest_ok; then a_mani=$c_mani; else echo "      manifest: NOT EARNED -> material (diff_manifest_${L}.txt)"; fi
  fi
  if [[ "$c_res" -gt 0 ]]; then
    if res_ok; then a_res=$c_res; else echo "      res: NOT EARNED -> material"; fi
  fi
  printf '%s\n' "$raw" | grep -q 'baseline\.prof' && \
    echo "      baseline.prof: NEVER auto-accepted (embeds dex checksums) -> material"
  acc=$((a_sign + a_stamp + a_mani + a_res))
  un=$((n - acc)); [[ "$un" -lt 0 ]] && un=0
  echo "LABEL ${L} ${n} ${a_sign} ${a_stamp} ${a_mani} ${a_res} ${un} compared" >> /out/summary.txt
  echo "  => ${name}: raw ${n}, accepted ${acc}, unaccounted ${un}"
done
for b in /built/*.apk; do
  [[ -f "/official/$(basename "$b")" ]] || echo "  NOTE: built $(basename "$b") has no official counterpart (not compared)"
done
echo ""; echo "=== comparison complete ==="
CMP_END
chmod +x "${img_ctx}/compare.sh"

crun \
  --volume "${OFF_DIR}:/official:ro" \
  --volume "${BUILT_DIR}:/built:ro" \
  --volume "${CMP_DIR}:/out" \
  --volume "${img_ctx}/compare.sh:/compare.sh:ro" \
  "$IMG" bash /compare.sh 2>&1 | tee "${CMP_DIR}/comparison.log"
CMP_RC=${PIPESTATUS[0]}

if [[ $CMP_RC -ne 0 ]] || ! grep -q '^LABEL' "${CMP_DIR}/summary.txt" 2>/dev/null; then
  log_error "Comparison stage failed (exit ${CMP_RC}) or wrote no LABEL line"
  log_info  "Comparison log: ${CMP_DIR}/comparison.log"
  fail 1 "Comparison stage failed for ${APP_ID} $wallet_version (exit ${CMP_RC}). Official base APK SHA-256: ${base_hash}."
fi

section "RESULT"
printf ' %-14s %5s %9s %8s %8s %6s %11s  %s\n' artifact raw signing stamp manifest res UNACCOUNTED verdict
total_unacc=0; n_art=0; n_ok=0; per_art=""
while read -r _ lbl raw s st m r un _; do
  n_art=$((n_art + 1))
  if [[ "$un" -eq 0 ]]; then v="reproducible"; n_ok=$((n_ok + 1)); else v="not_reproducible"; fi
  total_unacc=$((total_unacc + un))
  printf ' %-14s %5s %9s %8s %8s %6s %11s  %s\n' "$lbl" "$raw" "$s" "$st" "$m" "$r" "$un" "$v"
  per_art+="${lbl}=${v}(raw ${raw}, unaccounted ${un}) "
done < "${CMP_DIR}/summary.txt"
cat <<EOF

 Verdict is judged on UNACCOUNTED alone. Per artifact: ${CMP_DIR}/diff_<artifact>.txt,
 diff_manifest_<artifact>.txt, diff_resources_decoded_<artifact>.txt. Build logs: ${BUILD_DIR}/
EOF

if [[ "$total_unacc" -eq 0 ]]; then
  verdict="reproducible"; rc=0
  log_success "All ${n_art} artifact(s): every difference is an earned class with evidence; nothing unaccounted."
else
  verdict="not_reproducible"; rc=1
  log_error "${n_ok} of ${n_art} artifact(s) reproduced; ${total_unacc} difference(s) unaccounted for. See ${CMP_DIR}/"
fi

notes="${APP_ID} ${wallet_version} (versionCode ${version_code}) built from ${REPO_URL} commit ${built_ref} (${rev_source}) as ${gradle_task}$( [[ "$build_mode" == "bundle" ]] && echo ", splits rendered with bundletool ${BT_VER} from a device spec derived from the official set" ). Signer ${signer}; official base APK SHA-256 ${base_hash}; .env restored from the artifact's BuildConfig (${n_env} keys); build-machine inputs mirrored from the artifact: HOME ${BUILD_HOME}, checkout ${SRC_DIR}, Node v${NODE_VERSION}. ${n_ok} of ${n_art} artifact(s) reproduced: ${per_art}Accepted classes (evidence in comparison.log): root META-INF signing files, Play SourceStamp, official-only Play manifest meta-data, resources identical after apktool decode."
generate_yaml "$verdict" "$notes"

echo ""
cat <<EOF
===== Begin Results =====
appId:           ${APP_ID}
signer:          ${signer}
apkVersionName:  ${wallet_version}
apkVersionCode:  ${version_code}
verdict:         ${verdict}
appHash:         ${base_hash}
EOF
for f in "${OFF_DIR}"/*.apk; do
  lbl="$(label_of "$(basename "$f")")"
  v="$(awk -v l="$lbl" '$2==l{print ($8==0)?"reproducible":"not_reproducible"}' "${CMP_DIR}/summary.txt")"
  printf '  %-26s %s  %s\n' "$(basename "$f"):" "$(sha256of "$f")" "${v:-unverified}"
done
cat <<EOF
commit:          $(cat "${BUILD_DIR}/commit.txt" 2>/dev/null || echo unknown)
scriptVersion:   ${SCRIPT_VERSION}
scriptHash:      ${SCRIPT_HASH:-unknown}
===== End Results =====

Diff (first 5 lines per artifact; full files in ${CMP_DIR}):
EOF
for f in "${CMP_DIR}"/diff_*.txt; do
  case "$(basename "$f")" in diff_manifest_*|diff_resources_decoded_*) continue ;; esac
  if [[ -s "$f" ]]; then
    echo "  $(basename "$f") ($(wc -l < "$f") lines):"; head -5 "$f" | sed 's/^/    /'
  else
    echo "  $(basename "$f"): no differences"
  fi
done
echo ""
echo "Exit code: ${rc}"
exit "$rc"
