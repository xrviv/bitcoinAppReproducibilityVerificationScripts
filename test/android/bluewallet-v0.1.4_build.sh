#!/usr/bin/env bash
# bluewallet_build.sh - BlueWallet reproducible build verification (Android fat APK)
# Version:          v0.1.4
# Organization:     WalletScrutiny.com
# Last modified by: Bob (WalletScrutiny agent)
# Last modified on: 2026-10-09
# App ID:           io.bluewallet.bluewallet
# Project:          https://github.com/BlueWallet/BlueWallet
# Play Store:       https://play.google.com/store/apps/details?id=io.bluewallet.bluewallet
#
# Play ships the single fat APK (assembleRelease, four ABIs) that upstream's
# BuildReleaseApk workflow produces (fastlane lane build_release_apk), re-signed by
# Play App Signing. The same build is also shipped as a GitHub release asset signed
# with BlueWallet's own key (no SourceStamp, no Play meta-data); both are verified.
# Design notes, history and rationale: ws-notes script-notes/android/io.bluewallet.bluewallet/changelog.md
#
# Provided for technical analysis and reproducible build verification only, with
# no warranty of any kind. Review before running.
# Exit codes: 0 = identical, 1 = difference or build failure, 2 = bad parameters.

SCRIPT_VERSION="v0.1.4"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "bluewallet_build.sh $SCRIPT_VERSION sha256:${SCRIPT_HASH:-unknown}"
echo "Starting bluewallet_build.sh $SCRIPT_VERSION (BlueWallet fat APK: Play or GitHub release)"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="bluewallet_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="io.bluewallet.bluewallet"
REPO_URL="https://github.com/BlueWallet/BlueWallet"
# Upstream CI (ubuntu-24.04 runner) builds here; matched so no baked path can differ.
CI_PATH="/home/runner/work/BlueWallet/BlueWallet"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
# ABS reads the YAML next to the script; nothing is written to the caller's directory.
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
# Hand-back helper for docker / rootful podman (digest-pinned alpine 3.22; runs chown only).
CHOWN_IMAGE="docker.io/library/alpine@sha256:3e9b4b680bfc9fb5269227cffbd6d42be39fbf7c0b908123913864aa4447e764"

# Per-run state: empty until created, so the EXIT trap only touches what this run made.
RESULTS_WRITTEN=0; CONTAINER_CMD=""; ROOTLESS=0; CTR_PID=""
RUN_ID=""; RUN_LABEL=""; IMG=""; workspace=""; CMP_DIR=""; BUILD_DIR=""

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner() { printf '\n== %s ==\n' "$*"; }
section() { printf -- '\n-- %s --\n' "$*"; }
phase() { banner "$*"; echo "  $(date)"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# A verdict left by an earlier run must never be mistaken for this run's.
rm -f "$RESULTS_FILE"

# Only these three keys, ever: script_version, verdict, notes.
generate_yaml() {
  local verdict="$1" notes="$2"
  cat > "$RESULTS_FILE" <<EOF
script_version: $SCRIPT_VERSION
verdict: ${verdict}
notes: |
 ${notes}
EOF
  RESULTS_WRITTEN=1
  log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

fail() {
  local code="$1" note="$2"
  generate_yaml "ftbfs" "$note"
  exit "$code"
}

die_invalid() { log_error "$1"; fail 2 "Invalid invocation: $1"; }

# Long container steps run in the background and are waited for, so INT/TERM reach
# the traps at once instead of after the container finishes; ctr_wait_tee also tees
# the step's output to a log (a foreground pipeline would hold the signal).
ctr_wait() {
  local rc=0
  "$@" &
  CTR_PID=$!
  wait "$CTR_PID" || rc=$?
  CTR_PID=""
  return "$rc"
}
ctr_wait_tee() {
  local log="$1" rc=0; shift
  { "$@" 2>&1 | tee "$log"; exit "${PIPESTATUS[0]}"; } &
  CTR_PID=$!
  wait "$CTR_PID" || rc=$?
  CTR_PID=""
  return "$rc"
}

# Removes only what this run created: containers and images carrying its run label.
cleanup() {
  [[ -n "$CONTAINER_CMD" && -n "$RUN_LABEL" ]] || return 0
  local ids
  ids="$($CONTAINER_CMD ps -aq --filter "label=${RUN_LABEL}" 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    echo "$ids" | xargs -r $CONTAINER_CMD kill >/dev/null 2>&1 || true
    echo "$ids" | xargs -r $CONTAINER_CMD rm -f >/dev/null 2>&1 || true
  fi
  if [[ -n "$CTR_PID" ]] && kill -0 "$CTR_PID" 2>/dev/null; then
    kill "$CTR_PID" 2>/dev/null || true
    wait "$CTR_PID" 2>/dev/null || true
  fi
  ids="$($CONTAINER_CMD images -q --filter "label=${RUN_LABEL}" 2>/dev/null || true)"
  [[ -n "$ids" ]] && { echo "$ids" | xargs -r $CONTAINER_CMD rmi -f >/dev/null 2>&1 || true; }
  [[ -n "$IMG" ]] && { $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1 || true; }
  return 0
}

# Hands the workspace back to the caller on every exit; never fails the script.
# Rootless runtime: container root == caller, so chown 0:0 (a host uid would map
# into the subuid range); rootful docker/podman: chown to the caller's uid:gid.
hand_back_workspace() {
  [[ -n "$workspace" && -d "$workspace" ]] || return 0
  local own="${HOST_UID}:${HOST_GID}" stray
  [[ "$ROOTLESS" -eq 1 ]] && own="0:0"
  if [[ "$CONTAINER_CMD" == podman && "$ROOTLESS" -eq 1 ]]; then
    podman unshare chown -R 0:0 "$workspace" >/dev/null 2>&1 || true
  elif [[ -n "$CONTAINER_CMD" ]]; then
    $CONTAINER_CMD run --rm --name "ws-bluewallet-chown-${RUN_ID}" --user root \
      --volume "${workspace}:/w" "$CHOWN_IMAGE" chown -R "$own" /w >/dev/null 2>&1 || true
  fi
  stray="$(find "$workspace" ! -uid "$HOST_UID" -print -quit 2>/dev/null || true)"
  if [[ -n "$stray" ]]; then
    log_warn "Not caller-owned after hand-back: ${stray}"
  else
    echo "Workspace ownership: all files owned by uid ${HOST_UID} (${workspace})"
  fi
  return 0
}

# Runs on every exit (success, failure, interrupt): stops this run's containers,
# removes its image, hands the workspace back and guarantees a verdict.
on_exit() {
  local rc=$?
  trap - INT TERM
  set +e
  cleanup
  hand_back_workspace
  if [[ "$RESULTS_WRITTEN" -eq 0 ]]; then
    generate_yaml "ftbfs" "Run ended before a verdict was written (exit code ${rc}: build failure, invalid input or interruption). See the terminal log for the failing step."
  fi
  echo "Results YAML: ${RESULTS_FILE}"
  [[ -n "$workspace" ]] && echo "Workspace (logs, diffs): ${workspace}"
  case "$rc" in 0|1|2) ;; *) rc=1 ;; esac
  echo "Exit code: ${rc}"
  exit "$rc"
}
trap on_exit EXIT
trap 'echo; echo "Interrupted (SIGINT)."; exit 130' INT
trap 'echo; echo "Terminated (SIGTERM)."; exit 143' TERM

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""; rev_arg="${WS_GIT_REVISION:-}"

require_arg() {
  local flag="$1" val="${2:-}"
  [[ -z "$val" || "$val" == --* ]] && \
    die_invalid "${flag} requires a value (got: '${val:-<nothing>}')"
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <official.apk> [--git-revision <sha>] [--version <v>] [--arch <a>] [--type <t>]

 --binary        REQUIRED. The official APK (Play or GitHub release; one fat APK), or a
                 directory holding exactly one .apk.
 --git-revision  Commit to build (7-40 hex). Default: the newest first-parent
                 master commit committed before the artifact's versionCode read
                 as a unix timestamp (upstream CI sets versionCode=\$(date +%s)
                 seconds before the build) that declares its versionName.
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
    -h|--help)      trap - EXIT; usage; echo "Exit code: 0"; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift; continue ;;
  esac
done

if [[ -z "$binary_arg" ]]; then
  log_error "--binary is required: pass the official APK."
  fail 2 "--binary not provided. Pass the official APK of ${APP_ID}."
fi
[[ -e "$binary_arg" ]] || die_invalid "--binary path does not exist: ${binary_arg}"
if [[ -d "$binary_arg" ]]; then
  n_apk="$(find "$binary_arg" -maxdepth 1 -name '*.apk' | wc -l)"
  [[ "$n_apk" -eq 1 ]] || \
    die_invalid "--binary directory must hold exactly one .apk (found ${n_apk}); BlueWallet ships a single fat APK"
  binary_arg="$(find "$binary_arg" -maxdepth 1 -name '*.apk')"
fi
[[ -f "$binary_arg" ]] || die_invalid "--binary is not a regular file: ${binary_arg}"
[[ -z "$rev_arg" || "$rev_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || \
  die_invalid "--git-revision must be 7-40 hex characters (got: '${rev_arg}')"

apk_file="$(realpath "$binary_arg")"

[[ -n "$arch_arg" ]]    && log_info "--arch ${arch_arg} accepted; the fat APK carries every ABI"
[[ -n "$type_arg" ]]    && log_info "--type ${type_arg} accepted but not used"
[[ -n "$version_arg" ]] && log_info "--version ${version_arg} accepted; the authoritative version comes from the APK"
[[ -n "$rev_arg" ]]     && log_info "--git-revision ${rev_arg}: overrides the versionCode-timestamp pin"

# A runtime that actually works (docker needs its daemon), docker first, then podman.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  CONTAINER_CMD=docker
  docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && ROOTLESS=1
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  CONTAINER_CMD=podman
  [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == true ]] && ROOTLESS=1
else
  log_error "No working container runtime: docker info and podman info both failed."
  fail 1 "No working container runtime: docker info and podman info both failed. Install or start docker or podman."
fi

# Container user, so nothing is left that the caller does not own. Rootless podman:
# keep-id maps the caller to the same uid inside. Rootless docker: container uid 0 IS
# the caller (a host uid would map into the subuid range), so run as 0:0. Rootful
# docker: the caller's uid:gid. HOME=/home/runner as on CI.
if [[ "$CONTAINER_CMD" == "podman" ]]; then
  CONTAINER_RUN_USER_ARGS=(--userns=keep-id -e HOME=/home/runner)
elif [[ "$ROOTLESS" -eq 1 ]]; then
  CONTAINER_RUN_USER_ARGS=(--user 0:0 -e HOME=/home/runner)
else
  CONTAINER_RUN_USER_ARGS=(--user "${HOST_UID}:${HOST_GID}" -e HOME=/home/runner)
fi

MEM_LIMIT="${MEM_LIMIT:-24g}"
MEM_ARGS=()
[[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")

# crun <step> <run args...>: per-run container name and label, so the EXIT trap can
# stop exactly this run's containers.
crun() {
  local step="$1"; shift
  $CONTAINER_CMD run --rm --name "ws-bluewallet-${step}-${RUN_ID}" --label "$RUN_LABEL" \
    "${CONTAINER_RUN_USER_ARGS[@]}" "${MEM_ARGS[@]}" "$@"
}

section "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-10s OK  (%s, rootless=%s)\n" "$CONTAINER_CMD" "$(command -v "$CONTAINER_CMD")" "$ROOTLESS"
echo "  No host JDK, node, Gradle, Android SDK or apktool is required or used."

# Per-run workspace in the caller's directory, created exclusively; never reused,
# renamed or deleted. The version part is the --version hint (ABS always passes it);
# the APK's own versionName is read later, inside the build image.
safe_version="$(printf '%s' "${version_arg:-unknown}" | tr -c '[:alnum:]._-' '-')"
WORK_BASE="$(pwd -P)"
for _try in 1 2 3; do
  RUN_ID="$(date +%s)-$$"
  candidate="${WORK_BASE}/bluewallet_verification_${safe_version}_${RUN_ID}"
  if mkdir "$candidate" 2>/dev/null; then workspace="$candidate"; break; fi
  log_warn "Workspace ${candidate} already exists; retrying with a new run id"; sleep 1
done
[[ -n "$workspace" ]] || fail 1 "Could not create a fresh workspace under ${WORK_BASE} (exists or not writable)."
RUN_LABEL="walletscrutiny.run=${RUN_ID}"
IMG="ws-bluewallet-${RUN_ID}"
META_DIR="${workspace}/metadata"
BUILD_DIR="${workspace}/source-build"
CMP_DIR="${workspace}/comparison"
mkdir "$META_DIR" "$BUILD_DIR" "$CMP_DIR"

banner "BLUEWALLET - REPRODUCIBLE BUILD VERIFICATION"
cat <<EOF
 Script:    ${SCRIPT_NAME} $SCRIPT_VERSION
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 APK:       ${apk_file}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1), rootless=${ROOTLESS})
 Workspace: ${workspace}
 Date:      $(date)
EOF

phase "SETUP: BUILD CONTAINER IMAGE"

img_ctx="$(mktemp -d -p "$workspace" ctx.XXXXXX)"

# Pins are what BuildReleaseApk run 11977 (the run that produced 8.0.1) used:
# node 24.18.0 (setup-node "24"), Temurin 17.0.19+10, SDK 36 / build-tools 36.0.0 /
# NDK 28.2.13676358; AGP auto-installed NDK 27.0.12077973 (realm) and CMake 3.22.1
# there, so they are pre-installed here (the SDK is read-only for the build user).
# Paths match the runner exactly: the NDK/prefab include paths end up in the GNU
# build-id of every locally compiled .so, and one lands in libappmodules .rodata.
# /home/runner chmod: the mapped user must be able to clone into the CI path.
cat > "${img_ctx}/Dockerfile" <<'DOCKERFILE_END'
FROM ubuntu:24.04@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    git unzip zip wget curl ca-certificates xz-utils && \
  rm -rf /var/lib/apt/lists/*

RUN cd /tmp && \
  wget -q https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz && \
  echo "55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742  node-v24.18.0-linux-x64.tar.xz" | sha256sum -c - && \
  mkdir -p /opt/hostedtoolcache/node/24.18.0/x64 && tar -xJf node-v24.18.0-linux-x64.tar.xz -C /opt/hostedtoolcache/node/24.18.0/x64 --strip-components=1 && \
  rm node-v24.18.0-linux-x64.tar.xz

RUN cd /tmp && \
  wget -q -O jdk.tar.gz "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz" && \
  echo "d8afc263758141a66e0e3aafc321e783f7016696f4eaea067d340a269037d331  jdk.tar.gz" | sha256sum -c - && \
  mkdir -p /opt/hostedtoolcache/Java_Temurin-Hotspot_jdk/17.0.19-10/x64 && \
  tar -xzf jdk.tar.gz -C /opt/hostedtoolcache/Java_Temurin-Hotspot_jdk/17.0.19-10/x64 --strip-components=1 && rm jdk.tar.gz

ENV JAVA_HOME=/opt/hostedtoolcache/Java_Temurin-Hotspot_jdk/17.0.19-10/x64
ENV ANDROID_HOME=/usr/local/lib/android/sdk
ENV ANDROID_SDK_ROOT=/usr/local/lib/android/sdk
ENV PATH="/opt/hostedtoolcache/node/24.18.0/x64/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${JAVA_HOME}/bin:${PATH}"

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && cd ${ANDROID_HOME}/cmdline-tools && \
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O ct.zip && \
  echo "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258  ct.zip" | sha256sum -c - && \
  unzip -q ct.zip && rm ct.zip && mv cmdline-tools latest

RUN yes | sdkmanager --licenses >/dev/null && \
  sdkmanager "platforms;android-36" "build-tools;36.0.0" "platform-tools" \
    "ndk;28.2.13676358" "ndk;27.0.12077973" "cmake;3.22.1" >/dev/null && chmod -R a+rX ${ANDROID_HOME}

ADD https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar /opt/apktool.jar
RUN chmod 0644 /opt/apktool.jar

RUN mkdir -p /tmp/afw /home/runner/work && chmod 0777 /tmp /tmp/afw /home/runner /home/runner/work
WORKDIR /home/runner/work
DOCKERFILE_END

section "Building image ${IMG}"
if ! ctr_wait $CONTAINER_CMD build --label "$RUN_LABEL" -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx"; then
  log_error "Container image build failed - see the build output above."
  fail 1 "Container image build failed; no comparison was performed."
fi
log_success "Image built: ${IMG}"

phase "PHASE 0: OFFICIAL BINARY METADATA"

cat > "${img_ctx}/meta.sh" <<'META_END'
#!/bin/bash
set -uo pipefail
BT="${ANDROID_HOME}/build-tools/36.0.0"
A=/input/official.apk

info="$("$BT/aapt2" dump badging $A 2>/dev/null)"
# Anchor on '^package:' and stop at the first quote (a greedy match returns versionName).
pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"
split_name="$(printf '%s\n' "$info" | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
abis="$(printf '%s\n' "$info" | sed -n "s/^native-code: //p" | tr -d "'" | tr ' ' ',')"
sv="$("$BT/apksigner" verify --verbose --print-certs $A 2>/dev/null)"
signer="$(printf '%s\n' "$sv" | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"
stamp="$(printf '%s\n' "$sv" | grep -c 'Verified for SourceStamp: true')"

# AGP records its version; the VCS file is present but says NO_SUPPORTED_VCS_FOUND
# on upstream CI, so it never names a commit for this app.
vcs="$(unzip -p $A META-INF/version-control-info.textproto 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
agp="$(unzip -p $A META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null \
  | sed -n 's/^androidGradlePluginVersion=//p' | head -1)"

"$BT/aapt2" dump xmltree --file AndroidManifest.xml $A > /output/manifest-official.txt 2>/dev/null
# The Bugsnag gradle plugin appends a random BUILD_UUID meta-data on every build.
uuid="$(grep -A1 'android:name([^)]*)="com.bugsnag.android.BUILD_UUID"' /output/manifest-official.txt \
  | sed -n 's/.*android:value([^)]*)="\([^"]*\)".*/\1/p' | head -1)"
bp=0; unzip -l $A 2>/dev/null | grep -q 'assets/dexopt/baseline.prof' && bp=1
# The react-native gradle plugin writes the BUILD HOST's LAN IP into this release
# resource (AgpConfiguratorUtils.configureDevServerLocation); -PreactNativeDevServerIp overrides it.
devip="$("$BT/aapt2" dump resources $A 2>/dev/null | grep -A1 'string/react_native_dev_server_ip' \
  | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)"

# versionCode = $(date +%s) of the CI step that built it; only trust timestamp-shaped values.
ts=""
[[ "$vcode" =~ ^[0-9]{10}$ ]] && ts="$(date -u -d "@${vcode}" '+%Y-%m-%d %H:%M:%S UTC')"

for kv in "pkg_name:${pkg:-unknown}" "version_name:${vname:-unknown}" "version_code:${vcode:-unknown}" \
  "signer:${signer:-unknown}" "split_name:${split_name}" "vcs:${vcs}" "agp:${agp}" "abis:${abis}" \
  "build_uuid:${uuid}" "stamp:${stamp}" "has_baseline_profile:${bp}" "build_time:${ts}" "dev_ip:${devip}"; do
  printf '%s\n' "${kv#*:}" > "/output/${kv%%:*}.txt"
done

cat <<META
[META] package:             ${pkg:-unknown}
[META] versionName:         ${vname:-unknown}
[META] versionCode:         ${vcode:-unknown}  -> build timestamp ${ts:-<not a unix timestamp>}
[META] native ABIs:         ${abis:-<none>}
[META] signer SHA-256:      ${signer:-unknown}
[META] SourceStamp:         ${stamp} (apksigner "Verified for SourceStamp")
[META] AGP version:         ${agp:-<none>} (META-INF/.../app-metadata.properties)
[META] VCS info:            ${vcs:-<none>} (META-INF/version-control-info.textproto)
[META] Bugsnag BUILD_UUID:  ${uuid:-<none>} (manifest meta-data, random per build)
[META] dev_server_ip res:   ${devip:-<none>} (build host LAN IP written by the RN gradle plugin)
[META] split name:          ${split_name:-<none>} (empty = not a split)
[META] baseline.prof:       ${bp}
META
META_END
chmod +x "${img_ctx}/meta.sh"

if ! ctr_wait crun meta \
  --volume "${apk_file}:/input/official.apk:ro" \
  --volume "${META_DIR}:/output" \
  --volume "${img_ctx}/meta.sh:/meta.sh:ro" \
  "$IMG" bash /meta.sh; then
  log_error "Metadata extraction failed - aapt2/apksigner could not read the APK."
  fail 1 "Could not read metadata from the official APK."
fi

meta() { cat "${META_DIR}/$1.txt" 2>/dev/null || echo "${2:-}"; }
pkg_id="$(meta pkg_name unknown)"
wallet_version="$(meta version_name unknown)"
version_code="$(meta version_code unknown)"
signer="$(meta signer unknown)"
official_agp="$(meta agp)"
official_uuid="$(meta build_uuid)"
dev_ip="$(meta dev_ip)"
build_time="$(meta build_time)"
split_name="$(meta split_name)"
app_hash="$(sha256of "$apk_file")"

[[ "$pkg_id" == "$APP_ID" ]] || \
  die_invalid "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
log_success "Package name verified: ${pkg_id}"
log_success "Version: $wallet_version (versionCode $version_code)"
log_info    "Signer SHA-256:   ${signer}"
log_info    "APK SHA-256:      ${app_hash}"

[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || \
  die_invalid "Could not read versionName from the APK"
[[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]] && \
  log_warn "--version was '${version_arg}' but the APK reports '$wallet_version'; using the binary's value"
if [[ -n "$split_name" ]]; then
  log_error "The APK declares split name '${split_name}'; BlueWallet ships a single fat APK, not splits."
  fail 2 "The supplied APK is a config split ('${split_name}'), not the fat APK."
fi

section "Resolving source revision"
if [[ -n "$rev_arg" ]]; then
  build_rev="$rev_arg"; rev_source="--git-revision"
elif [[ -n "$build_time" ]]; then
  build_rev=""; rev_source="newest first-parent master commit before versionCode timestamp ${build_time} declaring versionName ${wallet_version}"
else
  build_rev=""; rev_source="oldest first-parent master commit declaring versionName ${wallet_version} (versionCode is not a timestamp)"
fi
echo "  Revision: ${build_rev:-<resolved in container>}"
echo "  Source:   ${rev_source}"
[[ -z "$official_uuid" ]] && \
  log_warn "No Bugsnag BUILD_UUID in the official manifest; the built manifest will carry one unless upstream removed the plugin."
if [[ -n "$dev_ip" ]]; then
  log_info "react_native_dev_server_ip=${dev_ip} in the official resources: passed as -PreactNativeDevServerIp (build input, like versionCode)"
else
  log_warn "No react_native_dev_server_ip resource in the official APK; the built one will carry this container's IP"
fi

phase "PHASE 1: BUILD FROM SOURCE"
echo "  npm ci --omit=dev  ->  ./gradlew assembleRelease --no-daemon --stacktrace --console=plain"

# Upload/report tasks would push NDK symbols and a build report to BlueWallet's
# Bugsnag account from OUR build; the manifest UUID task stays enabled as in CI.
cat > "${img_ctx}/no-upload.gradle" <<'INIT_END'
allprojects { p ->
  p.plugins.withId('com.bugsnag.android.gradle') {
    def b = p.extensions.getByName('bugsnag')
    ['uploadJvmMappings','uploadNdkMappings','uploadReactNativeMappings','reportBuilds'].each { b."$it".set(false) }
  }
}
INIT_END

cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
umask 022
REPO_URL="__REPO_URL__"
CI_PATH="__CI_PATH__"
WANT_VNAME="__WANT_VNAME__"
WANT_VCODE="__WANT_VCODE__"
BUILD_TS="__BUILD_TS__"
DEV_IP="__DEV_IP__"

# CI's ~/.gradle: the prefab include path under it is baked into libappmodules.so.
export GRADLE_USER_HOME=/home/runner/.gradle
mkdir -p "$GRADLE_USER_HOME"
git config --global --add safe.directory '*'

echo "=== Clone ${REPO_URL} === $(date)"
git clone "$REPO_URL" "$CI_PATH" || { echo "FATAL: clone failed"; exit 1; }
cd "$CI_PATH"

gradle_vname() { git show "$1:android/app/build.gradle" 2>/dev/null | sed -n 's/^ *versionName *"\([^"]*\)".*/\1/p' | head -1; }

GIT_REF="${WS_GIT_REVISION:-}"
if [[ -n "$GIT_REF" ]]; then
  git rev-parse -q --verify "${GIT_REF}^{commit}" >/dev/null || git fetch -q origin "$GIT_REF" 2>/dev/null
  if ! GIT_REF="$(git rev-parse -q --verify "${GIT_REF}^{commit}")"; then
    echo "FATAL: revision ${WS_GIT_REVISION} is not in the public repository ${REPO_URL}."
    exit 4
  fi
  echo "=== Pinned revision ${GIT_REF} ==="
  git merge-base --is-ancestor "$GIT_REF" origin/master && echo "  reachable from origin/master" \
    || echo "  WARNING: not reachable from origin/master"
  vn="$(gradle_vname "$GIT_REF")"
  [[ "$vn" == "$WANT_VNAME" ]] || echo "  WARNING: it declares versionName ${vn:-?}, the artifact is ${WANT_VNAME}"
elif [[ -n "$BUILD_TS" ]]; then
  # CI: BUILD_NUMBER=$(date +%s) is generated ~3 min after checkout of the pushed
  # commit, so the built commit is the last master commit before that second.
  echo "=== Pinning: last first-parent master commit before ${BUILD_TS} ($(date -u -d "@${BUILD_TS}" '+%F %T') UTC) ==="
  GIT_REF="$(git rev-list -1 --first-parent --before="@${BUILD_TS}" origin/master)"
  [[ -n "$GIT_REF" ]] || { echo "FATAL: no master commit before ${BUILD_TS}"; exit 4; }
  NEXT="$(git rev-list --first-parent --reverse --after="@${BUILD_TS}" origin/master | head -1)"
  echo "  chosen:  $(git log -1 --format='%h %ci %s' "$GIT_REF" | cut -c1-100)"
  [[ -n "$NEXT" ]] && echo "  next:    $(git log -1 --format='%h %ci %s' "$NEXT" | cut -c1-100)  (after the build, excluded)"
  vn="$(gradle_vname "$GIT_REF")"
  if [[ "$vn" != "$WANT_VNAME" ]]; then
    echo "FATAL: commit ${GIT_REF:0:10} declares versionName ${vn:-?}, the artifact is ${WANT_VNAME}; pass --git-revision."
    exit 4
  fi
else
  echo "=== Pinning: oldest first-parent master commit declaring versionName ${WANT_VNAME} ==="
  GIT_REF=""
  for c in $(git rev-list --first-parent origin/master); do
    if [[ "$(gradle_vname "$c")" == "$WANT_VNAME" ]]; then GIT_REF="$c"
    elif [[ -n "$GIT_REF" ]]; then break; fi
  done
  [[ -n "$GIT_REF" ]] || { echo "FATAL: no master commit declares versionName ${WANT_VNAME}"; exit 4; }
  echo "AMBIGUOUS: versionCode is not a timestamp; built the oldest candidate. Pass --git-revision."
fi
echo "Building: ${GIT_REF}"

# Branch "master", not detached HEAD: scripts/current-branch.sh writes the branch
# name into current-branch.json, which the JS bundle embeds.
git checkout -q -B master "$GIT_REF" || { echo "FATAL: could not check out ${GIT_REF}"; exit 2; }
git branch -q -u origin/master master 2>/dev/null
echo "=== Revision under build ==="
git log -1 --pretty=format:'%H %ci %s'; echo
git rev-parse HEAD > /output/commit.txt

# scripts/release-notes.sh embeds `git log <newest tag>..HEAD` (newest by `git tag | sort`)
# into release-notes.json: drop tags created after the build so the tag set matches CI's.
if [[ -n "$BUILD_TS" ]]; then
  late="$(git for-each-ref --format='%(creatordate:unix) %(refname:short)' refs/tags | awk -v t="$BUILD_TS" '$1>t{print $2}')"
  [[ -n "$late" ]] && { echo "=== Tags created after the build, removed locally: $(echo $late)"; git tag -d $late >/dev/null; }
fi
echo "  newest tag by sort: $(git tag | sort | tail -1)"

echo "=== Toolchain ==="; node --version; npm --version; java -version 2>&1 | head -1

echo "=== npm ci --omit=dev === $(date)"
npm ci --omit=dev --no-audit --no-fund > /output/npm-ci.log 2>&1 || { tail -40 /output/npm-ci.log; echo "FATAL: npm ci failed"; exit 3; }
tail -5 /output/npm-ci.log
echo "  current-branch.json: $(cat current-branch.json 2>/dev/null)"
echo "  release-notes.json:  $(wc -c < release-notes.json 2>/dev/null) bytes, sha256 $(sha256sum release-notes.json 2>/dev/null | cut -c1-16)…"
agp="$(sed -n 's/^agp *= *"\([^"]*\)".*/\1/p' node_modules/@react-native/gradle-plugin/gradle/libs.versions.toml 2>/dev/null)"
printf '%s\n' "$agp" > /output/agp.txt
echo "  AGP from react-native gradle-plugin: ${agp:-?}"

# fastlane's version_name_and_update_code!: versionCode <- BUILD_NUMBER.
sed -i -E "s/versionCode[[:space:]]+[0-9]+/versionCode ${WANT_VCODE}/" android/app/build.gradle
echo "=== Working tree changes before Gradle (expected: versionCode only) ==="
git diff --stat; git diff | grep -E '^[-+] ' | head -4

echo "=== Gradle assembleRelease === $(date)"
cd android
./gradlew assembleRelease --no-daemon --stacktrace --console=plain -I /no-upload.gradle \
  ${DEV_IP:+-PreactNativeDevServerIp=$DEV_IP} > /output/gradle-build.log 2>&1
rc=$?
grep -E '^> Task :app:(createBundle|externalNativeBuild|package|processBugsnag)|BUILD (SUCCESSFUL|FAILED)|FAILURE|What went wrong' /output/gradle-build.log | head -12
if [[ $rc -ne 0 ]]; then
  tail -40 /output/gradle-build.log
  echo "FATAL: gradle build failed (exit ${rc}) - full log at /output/gradle-build.log"
  exit 3
fi
apk="app/build/outputs/apk/release/app-release-unsigned.apk"
[[ -f "$apk" ]] || apk="app/build/outputs/apk/release/app-release.apk"
[[ -f "$apk" ]] || { echo "FATAL: no release APK under app/build/outputs/apk/release"; ls app/build/outputs/apk/release; exit 3; }
cp "$apk" /output/built.apk
echo "=== built: $(basename "$apk")  sha256 $(sha256sum /output/built.apk | cut -d' ' -f1)"
echo "=== Build complete $(date) ==="
BUILD_END

sed -i \
  -e "s|__REPO_URL__|${REPO_URL}|g" \
  -e "s|__CI_PATH__|${CI_PATH}|g" \
  -e "s|__WANT_VNAME__|$wallet_version|g" \
  -e "s|__WANT_VCODE__|$version_code|g" \
  -e "s|__BUILD_TS__|$([[ -n "$build_time" ]] && echo "$version_code")|g" \
  -e "s|__DEV_IP__|$dev_ip|g" \
  "${img_ctx}/build.sh"
chmod +x "${img_ctx}/build.sh"

section "Source build (40-90 min cold) - $(date)"
ctr_wait_tee "${BUILD_DIR}/container-build.log" crun build \
  -e "WS_GIT_REVISION=${build_rev}" \
  --add-host upload.bugsnag.com:127.0.0.1 --add-host build.bugsnag.com:127.0.0.1 \
  --volume "${BUILD_DIR}:/output" \
  --volume "${img_ctx}/build.sh:/build.sh:ro" \
  --volume "${img_ctx}/no-upload.gradle:/no-upload.gradle:ro" \
  "$IMG" bash /build.sh
BUILD_RC=$?

if [[ $BUILD_RC -ne 0 ]]; then
  # Container exit codes: 1 clone, 2 checkout, 3 npm/gradle, 4 revision not found.
  if [[ $BUILD_RC -eq 4 ]]; then
    log_error "Cannot pin a revision (${rev_source}). This is a FINDING, not a script fault."
    fail 1 "The source revision could not be pinned (${rev_source}${build_rev:+: $build_rev}); the shipped artifact cannot be matched to published source. No build attempted. Official APK SHA-256: ${app_hash}."
  fi
  log_error "Source build failed (container exit ${BUILD_RC}: 1=clone, 2=checkout, 3=npm/gradle)"
  log_info  "Logs: ${BUILD_DIR}/npm-ci.log, ${BUILD_DIR}/gradle-build.log"
  fail 1 "Source build failed for ${APP_ID} $wallet_version (container exit ${BUILD_RC}). Official APK SHA-256: ${app_hash}."
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

# PHASE 2: no general acceptable-diffs filtering; every raw diff must be EARNED by a class,
# and every earned class prints its evidence.
phase "PHASE 2: COMPARISON"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"
o=/official.apk; b=/built.apk

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

# AndroidManifest: accepted ONLY if, after equating the Bugsnag BUILD_UUID (random per
# build by the gradle plugin; both values printed), the sole delta is Play's
# distribution meta-data, official-only. Everything is printed, not counted.
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
uuid_of() { grep -A1 'android:name([^)]*)="com.bugsnag.android.BUILD_UUID"' "$1" | sed -n 's/.*android:value([^)]*)="\([^"]*\)".*/\1/p' | head -1; }
manifest_ok() {
  local d left bad n m uo ub
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null || return 1
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null || return 1
  diff /tmp/mo.txt /tmp/mb.txt > /out/diff_manifest_raw.txt
  uo="$(uuid_of /tmp/mo.txt)"; ub="$(uuid_of /tmp/mb.txt)"
  if [[ -n "$uo" || -n "$ub" ]]; then
    echo "      manifest: com.bugsnag.android.BUILD_UUID official=${uo:-<none>} built=${ub:-<none>}"
    [[ "$uo" =~ ^${UUID_RE}$ && "$ub" =~ ^${UUID_RE}$ ]] || { echo "      manifest: BUILD_UUID missing or malformed on one side"; return 1; }
    [[ "$uo" == "$ub" ]] || sed -i "s/\"${ub}\"/\"${uo}\"/g" /tmp/mb.txt
  fi
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"
  printf '%s\n' "$d" > /out/diff_manifest_uuid_equated.txt
  printf '%s\n' "$d" | grep -q '^>' && { echo "      manifest: BUILT-only lines present:"; printf '%s\n' "$d" | grep '^>' | head -3 | sed 's/^/        /'; return 1; }
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  bad="$(printf '%s\n' "$left" | grep -vE '^E: meta-data|^A: [^ ]*android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)=[0-9]+$')"
  if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: unexpected official-only line(s):"
    printf '%s\n' "$bad" | head -3 | sed 's/^/        /'
    return 1
  fi
  n=$(printf '%s\n' "$left" | grep -c '^E: meta-data')
  m=$(printf '%s\n' "$left" | grep -c 'android:name(0x[0-9a-f]*)="com\.android\.')
  # Non-Play artifact (BlueWallet's own signing key, no SourceStamp): no Play meta-data is
  # expected, so the manifest is earned only if nothing at all is left after the UUID.
  if [[ "$n" -eq 0 && -z "$(printf '%s' "$left" | tr -d '[:space:]')" ]]; then
    if "$BT/apksigner" verify --verbose "$o" 2>/dev/null | grep -q 'Verified for SourceStamp: true'; then
      echo "      manifest: SourceStamp present but no Play meta-data block"; return 1
    fi
    echo "      manifest: identical once BUILD_UUID is equated (no SourceStamp: not Play-distributed, no Play meta-data expected)"
    return 0
  fi
  [[ "$n" -ge 1 && "$n" -eq "$m" ]] || { echo "      manifest: $n block(s) vs $m Play name(s)"; return 1; }
  echo "      manifest: ${n} official-only Play meta-data block(s), none built-only:"
  printf '%s\n' "$left" | grep -vE '^E: meta-data' | sed 's/^A: [^ ]*android:/        /'
}

# resources.arsc: accepted only when the apktool-decoded res/ trees are identical.
arsc_ok() {
  local rd
  rm -rf /tmp/do /tmp/db
  $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/do "$o" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (official)"; return 1; }
  $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/db "$b" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (built)"; return 1; }
  [[ -d /tmp/do/res && -d /tmp/db/res ]] || { echo "      arsc: no res/ after decode"; return 1; }
  rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
  printf '%s\n' "$rd" > /out/diff_resources_decoded.txt
  if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then
    echo "      arsc: decoded res/ tree IDENTICAL (binary packing artifact)"; return 0
  fi
  echo "      arsc: decoded res/ differs -> material"; printf '%s\n' "$rd" | head -3 | sed 's/^/        /'
  return 1
}

echo "  official: sha256 $(sha256sum "$o" | cut -d' ' -f1)"
echo "  built:    sha256 $(sha256sum "$b" | cut -d' ' -f1)"
rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
unzip -q -o "$o" -d /tmp/o
unzip -q -o "$b" -d /tmp/b
echo "  entries: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"

nso=0; nsm=0
while IFS= read -r so; do
  rel="${so#/tmp/o/}"; nso=$((nso + 1))
  if [[ -f "/tmp/b/${rel}" ]] && cmp -s "$so" "/tmp/b/${rel}"; then nsm=$((nsm + 1)); else echo "  native DIFFER/MISSING ${rel}"; fi
done < <(find /tmp/o -name '*.so' -type f | sort)
echo "  native libs: ${nsm}/${nso} byte-identical"
echo "  JS bundle:   $(cmp -s /tmp/o/assets/index.android.bundle /tmp/b/assets/index.android.bundle && echo IDENTICAL || echo DIFFERS) (assets/index.android.bundle, Hermes bytecode)"
dx="$(cd /tmp/o && ls classes*.dex 2>/dev/null | while read -r f; do cmp -s "$f" "/tmp/b/$f" || printf '%s ' "$f"; done)"
echo "  dex:         ${dx:-all identical}"

raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"
printf '%s\n' "$raw" > /out/diff-unzipped.txt
n=$(printf '%s\n' "$raw" | grep -vc '^$')
echo "  raw diffs: ${n}   (full list: diff-unzipped.txt)"
[[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | head -5 | sed 's/^/    /'

# Signing: excluded only when the entry is OFFICIAL-ONLY, sits at the ZIP root META-INF/
# and is named *.SF, *.RSA, *.DSA, *.EC or MANIFEST.MF. A signing-named entry that is
# built-only, nested deeper or present on both sides is a real difference and is listed.
SIGN_OK='^Only in /tmp/o/META-INF: ([^ /]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$'
read -r c_sign c_sbad c_stamp c_mani c_arsc < <(printf '%s\n' "$raw" | awk '
  /^Only in \/tmp\/o\/META-INF: ([^ \/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$/{a++;next}
  /\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)/{e++;next}
  /stamp-cert-sha256/{b++} /AndroidManifest\.xml/{c++} /resources\.arsc/{d++}
  END{print a+0, e+0, b+0, c+0, d+0}')
a_sign=0; a_stamp=0; a_mani=0; a_arsc=0
echo "  accepted-class evidence"
if [[ "$c_sign" -gt 0 ]]; then a_sign=$c_sign
  echo "      signing: ${c_sign} official-only root META-INF entry(ies) excluded - $(printf '%s\n' "$raw" | grep -E "$SIGN_OK" | sed 's/^[^:]*: //' | sort | paste -sd' ' -); official APK signed, local build unsigned"; fi
if [[ "$c_sbad" -gt 0 ]]; then
  echo "      signing: ${c_sbad} signing-named entry(ies) NOT excluded (built-only, nested or on both sides) -> material:"
  printf '%s\n' "$raw" | grep -E '\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)' | grep -vE "$SIGN_OK" | head -3 | sed 's/^/        /'
fi
if [[ "$c_stamp" -gt 0 ]]; then
  if stamp_ok; then a_stamp=$c_stamp; else echo "      stamp: NOT EARNED -> material"; fi
fi
if [[ "$c_mani" -gt 0 ]]; then
  if manifest_ok; then a_mani=$c_mani; else echo "      manifest: NOT EARNED -> material (diff_manifest_raw.txt)"; fi
fi
if [[ "$c_arsc" -gt 0 ]]; then
  if arsc_ok; then a_arsc=$c_arsc; else echo "      arsc: NOT EARNED -> material"; fi
fi
printf '%s\n' "$raw" | grep -q 'baseline\.prof' && \
  echo "      baseline.prof: NEVER auto-accepted (embeds dex checksums) -> material"

acc=$((a_sign + a_stamp + a_mani + a_arsc))
un=$((n - acc)); [[ "$un" -lt 0 ]] && un=0
echo "TOTALS ${n} ${a_sign} ${a_stamp} ${a_mani} ${a_arsc} ${un}" > /out/summary.txt
echo ""
echo "=== comparison complete: raw ${n}, accepted ${acc}, unaccounted ${un} ==="
CMP_END
chmod +x "${img_ctx}/compare.sh"

ctr_wait_tee "${CMP_DIR}/comparison.log" crun compare \
  --volume "${apk_file}:/official.apk:ro" \
  --volume "${BUILD_DIR}/built.apk:/built.apk:ro" \
  --volume "${CMP_DIR}:/out" \
  --volume "${img_ctx}/compare.sh:/compare.sh:ro" \
  "$IMG" bash /compare.sh
CMP_RC=$?

if [[ $CMP_RC -ne 0 ]] || ! grep -q '^TOTALS' "${CMP_DIR}/summary.txt" 2>/dev/null; then
  log_error "Comparison stage failed (exit ${CMP_RC}) or wrote no TOTALS line"
  log_info  "Comparison log: ${CMP_DIR}/comparison.log"
  fail 1 "Comparison stage failed for ${APP_ID} $wallet_version (exit ${CMP_RC}). Official APK SHA-256: ${app_hash}."
fi

read -r _ raw_total t_sign t_stamp t_mani t_arsc t_unacc < <(grep '^TOTALS' "${CMP_DIR}/summary.txt")
raw_total="${raw_total:-1}"; t_sign="${t_sign:-0}"; t_stamp="${t_stamp:-0}"
t_mani="${t_mani:-0}"; t_arsc="${t_arsc:-0}"; t_unacc="${t_unacc:-1}"
t_acc=$((t_sign + t_stamp + t_mani + t_arsc))
built_uuid="$(grep -o 'BUILD_UUID official=[^ ]* built=[^ ]*' "${CMP_DIR}/comparison.log" | head -1 | sed 's/.*built=//')"

section "RESULT"
cat <<EOF
 Raw differences:      ${raw_total}
 Accepted (earned):    ${t_acc} = signing ${t_sign} + stamp ${t_stamp} + manifest ${t_mani} + arsc ${t_arsc}
 UNACCOUNTED:          ${t_unacc}   <- the verdict is judged on this alone

 Raw diffs:            ${CMP_DIR}/diff-unzipped.txt
 Manifest diffs:       ${CMP_DIR}/diff_manifest_raw.txt, diff_manifest_uuid_equated.txt
 Decoded res/ diff:    ${CMP_DIR}/diff_resources_decoded.txt
 Build logs:           ${BUILD_DIR}/npm-ci.log, gradle-build.log, container-build.log
EOF

if [[ "$t_unacc" -eq 0 ]]; then
  verdict="reproducible"; rc=0
  log_success "Every difference is an earned class with printed evidence; nothing unaccounted."
else
  verdict="not_reproducible"; rc=1
  log_error "${t_unacc} difference(s) unaccounted for. See ${CMP_DIR}/diff-unzipped.txt"
fi

notes="${APP_ID} ${wallet_version} (versionCode ${version_code}${build_time:+ = build timestamp $build_time}) built from ${REPO_URL} commit ${built_ref} (${rev_source}). Official APK SHA-256 ${app_hash}, signer ${signer}. Raw diffs ${raw_total}: signing ${t_sign}, SourceStamp ${t_stamp}, manifest ${t_mani}${official_uuid:+ (Bugsnag BUILD_UUID official ${official_uuid} vs built ${built_uuid:-?}, random per build by the Bugsnag gradle plugin; Play meta-data printed in comparison.log)}, resources ${t_arsc}, unaccounted ${t_unacc}."
generate_yaml "$verdict" "$notes"

echo ""
cat <<EOF
===== Begin Results =====
appId:           ${APP_ID}
signer:          ${signer}
apkVersionName:  ${wallet_version}
apkVersionCode:  ${version_code}
verdict:         ${verdict}
appHash:         ${app_hash}
commit:          $(cat "${BUILD_DIR}/commit.txt" 2>/dev/null || echo unknown)
scriptVersion:   ${SCRIPT_VERSION}
scriptHash:      ${SCRIPT_HASH:-unknown}
===== End Results =====

sourceRef:       ${built_ref:-unknown} (branch master, ${rev_source})
EOF
exit "$rc"
