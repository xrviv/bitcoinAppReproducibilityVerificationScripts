#!/usr/bin/env bash
# tangem-v0.6.1_build.sh - Tangem Wallet Android reproducible build verification
# Version:          v0.6.1
# Last modified by: Claude Opus 5.5 for Danny Garcia
# Last modified on: 2026-11-27
# Organization:     WalletScrutiny.com
# App ID:           com.tangem.wallet
# Project:          https://github.com/tangem/tangem-app-android
# Disclaimer: provided as-is, without warranty. Review before running. This is not a security audit.
# Steps: read the official APK(s): a Play split directory, or the GitHub release APK (downloaded and
#   checked against the release's published sha256 when only --version is given). Clone tag v<version>,
#   build in an Ubuntu 22.04 + OpenJDK 17 image: Play = bundleGoogleRelease + bundletool splits,
#   GitHub = assembleGoogleRelease. Version name/code come from the official APK (Gradle properties);
#   google-services.json is the repo's stub plus com.tangem.wallet. Compare every ZIP entry.
#   GITHUB_TOKEN (read:packages) is needed for the build only: Tangem's SDKs come from GitHub Packages,
#   which refuses anonymous reads (A10 exception; the release lookup works without it). The script reads
#   it from the environment and passes it by name only; Gradle and its plugins can read it in the build
#   container. Clone/build output is masked (***) before the terminal and logs; workspace files are
#   scanned for it at every exit, after the containers stop (count only). Gradle heap: GRADLE_XMX (default 16g; Tangem's 8g ran out of memory on 6.9).
#   Library ws-rb-core (#1023); build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library; 130 stopped.

SCRIPT_NAME="tangem-v0.6.1_build.sh"
SCRIPT_VERSION="v0.6.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "${SCRIPT_NAME} ${SCRIPT_VERSION} sha256:${SCRIPT_SHA256}"

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

APP_ID="com.tangem.wallet"
REPO_URL="https://github.com/tangem/tangem-app-android.git"
API_URL="https://api.github.com/repos/tangem/tangem-app-android/releases/tags"
# Probe, tag lookup and download image (aapt/apksigner in build-tools 29.0.3, git, wget; no curl), by digest.
WS_IMG="docker.io/walletscrutiny/android@sha256:eabd60543f19831feef6db22e9a1ada0ef469eef723119f1c96bd836198614c3"
BASE_IMG="docker.io/library/ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb"
CMDLINE_SHA256="2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"

VERSION="" ARCH="" BINARY="" DEVICE_SDK="" MODE="" TAG="" REQ_TAG="" COMMIT="" SIGNER="" VNAME="" VCODE="" APP_HASH=""
COUNTED=0 BG_PID="" BASE_NATIVE="" W="" HASHES=() BUILD_LOCK_FILE="" FTBFS_NOTE="" LEAK_DONE=0
declare -a OFFICIAL=() LABELS=() NCOUNT=() NACC=() OFF_HASH=() BUILT_HASH=()

nov() { ws_no_verdict "$1"; }   # runtime, network, tool or input problem: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML

ws_refuse_root
ws_install_traps

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--binary <apk|split dir>] [--version <v>] [--arch <abi>] [--type <t>]
  --binary, --apk  directory of Play split APKs (base.apk + split_config.*.apk), or the GitHub release APK
  --version        release version; read from the APK when omitted. Without --binary the GitHub
                   release APK of this version is downloaded and checked against its published sha256
  --arch           ABI of the split set (default: the ABI split present, else arm64-v8a)
  --type           accepted for ABS compatibility; unused
  --tag            git tag to build (default v<version>)
  --device-sdk     device API level for bundletool (default 36)
  --help
Env: GITHUB_TOKEN (read:packages, needed to build); GITHUB_USER (default walletscrutiny);
     GRADLE_XMX (Gradle heap, default 16g); MEM_LIMIT (docker only).
Exit codes: 0 reproducible, 1 not_reproducible/ftbfs/no verdict, 2 invalid parameters
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary|--apk) ws_require_value "$1" "${2:-}"; BINARY="$2"; shift 2 ;;
    --version)      ws_require_value "$1" "${2:-}"; VERSION="${2#v}"; shift 2 ;;
    --arch)         ws_require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
    --type)         ws_require_value "$1" "${2:-}"; shift 2 ;;
    --tag)          ws_require_value "$1" "${2:-}"; REQ_TAG="$2"; shift 2 ;;
    --device-sdk)   ws_require_value "$1" "${2:-}"; DEVICE_SDK="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;
  esac
done

[[ -n "$BINARY" || -n "$VERSION" ]] || inv "--binary or --version is required."
[[ -z "$BINARY" || -e "$BINARY" ]] || inv "--binary not found: ${BINARY}"
[[ -z "$DEVICE_SDK" || "$DEVICE_SDK" =~ ^[0-9]+$ ]] || inv "--device-sdk must be an integer."
case "$ARCH" in ""|arm64-v8a|armeabi-v7a|x86_64|x86) ;; *) inv "Unsupported --arch: ${ARCH}" ;; esac
[[ -z "$VERSION" || "$VERSION" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || inv "Unsafe version string: ${VERSION}"
[[ -z "$REQ_TAG" || "$REQ_TAG" =~ ^[0-9A-Za-z._/-]+$ ]] || inv "Unsafe tag: ${REQ_TAG}"
[[ -z "$BINARY" ]] || BINARY="$(realpath "$BINARY")"

ws_results_init
ws_engine
GRADLE_XMX="${GRADLE_XMX:-16g}"
[[ "$GRADLE_XMX" =~ ^[1-9][0-9]*[gm]$ ]] || inv "GRADLE_XMX must look like 16g or 12000m."
GH_ACTOR="${GITHUB_USER:-walletscrutiny}"
[[ "$GH_ACTOR" =~ ^[A-Za-z0-9-]+$ ]] || inv "GITHUB_USER must be a GitHub user name."
CTR=(docker); [[ "$WS_ENGINE" != podman ]] || CTR=(podman --cgroup-manager=cgroupfs)
# Rootless podman with cgroupfs can't set memory limits: --memory (MEM_LIMIT, default 28g) is docker only.
MEM_ARGS=(); if [[ "$WS_ENGINE" == docker ]]; then MEM_LIMIT="${MEM_LIMIT-28g}"; [[ -z "$MEM_LIMIT" ]] || MEM_ARGS=(--memory="$MEM_LIMIT"); fi
IMG="localhost/ws-tangem:${WS_RUN_ID}"

# Background + wait: a signal acts at once; the exit hook stops and reaps it.
bg_wait() { local rc=0; "$@" & BG_PID=$!; wait "$BG_PID" || rc=$?; BG_PID=""; return $rc; }
# At exit: stop the wrapper and every tracked container first, so nothing writes after the token scan.
ws_cleanup_hook() {
  local x
  [[ -z "$BG_PID" ]] || { kill "$BG_PID"; wait "$BG_PID"; } 2>/dev/null || true
  [[ -z "${WS_ENGINE:-}" || "${WS_KEEP:-}" == 1 ]] || for x in "${WS_CONTAINERS[@]}"; do ws_ctr rm -f "$x" &>/dev/null || true; done
  leak_scan
}
# Replaces GITHUB_TOKEN (read from the environment, never an argument) with *** in each output line.
read -r -d '' MASK_AWK <<'EOF' || true
BEGIN { t = ENVIRON["GITHUB_TOKEN"] }
{ s = $0; o = ""; if (t != "") while ((i = index(s, t)) > 0) { o = o substr(s, 1, i - 1) "***"; s = substr(s, i + length(t)) }
  print o s; fflush() }
EOF
# ctr STAGE LOG ARGS...: run a named container (removed at exit), masked output to the terminal and LOG;
# returns the container's exit code, or 90 if the mask or LOG failed.
ctr() {
  local n="tangem-${WS_RUN_ID}-$1" l="$2" rc=0; shift 2
  ws_track_container "$n"
  bg_wait bash -c 'l="$1" m="$2"; shift 2; "$@" < /dev/null 2>&1 | awk "$m" | tee "$l"; s=("${PIPESTATUS[@]}"); [[ ${s[1]} == 0 && ${s[2]} == 0 ]] || exit 90; exit "${s[0]}"' \
    _ "$l" "$MASK_AWK" "${CTR[@]}" run --rm --name "$n" "$@" || rc=$?
  return $rc
}
# grep_tok PATH...: grep -rlsF for the token, given on a file descriptor (never an argument); grep's status.
grep_tok() { grep -rlsF -f <(printf '%s\n' "$GITHUB_TOKEN") "$@"; }
# Final workspace scan, once, at exit. Prints a count and our own top-level folder names only (a file name
# could hold the token). The whole list is read; grep's status is kept (1 = none, 2+ = incomplete).
leak_scan() {
  local rc x d=""; local -a hits=()
  [[ "$LEAK_DONE" -eq 0 && -n "${GITHUB_TOKEN:-}" && -n "$W" && -d "$W" ]] || return 0
  mapfile -t hits < <(grep_tok "$W"; echo "rc=$?")
  rc="${hits[-1]#rc=}"; unset 'hits[-1]'; LEAK_DONE=1
  for x in "${hits[@]}"; do x="${x#"$W"/}"; x="${x%%/*}"
    case "$x" in official|built|cmp|ctx|gradle-home|build-lock|src|*.log|*.json|*.txt|*.py) [[ " $d " == *" $x "* ]] || d+="${d:+ }$x" ;; esac
  done
  if [[ "${#hits[@]}" -gt 0 ]]; then ws_warn "GITHUB_TOKEN found in ${#hits[@]} workspace file(s) (in: ${d:-?}); do not share them."
  elif [[ "$rc" -eq 1 ]]; then ws_ok "Token scan: GITHUB_TOKEN is in no workspace file."; fi
  [[ "$rc" -le 1 ]] || ws_warn "Token scan of ${W} incomplete (grep exit ${rc}): check files before sharing them."
}

read -r -d '' PROBE_SH <<'EOF' || true
A=/opt/android-sdk/build-tools/29.0.3
b="$($A/aapt dump badging "$1" 2>/dev/null)" || exit 3
p="$(printf '%s\n' "$b" | head -n1)"
g() { printf '%s\n' "$p" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
x="$($A/aapt dump xmltree "$1" AndroidManifest.xml 2>/dev/null)" || exit 4
m="$(printf '%s\n' "$x" | grep -c -E 'isSplitRequired|requiredSplitTypes|vending\.splits\.required' || true)"
v="$($A/apksigner verify --print-certs "$1" 2>/dev/null)" || exit 5
s="$(printf '%s\n' "$v" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
c="$(printf '%s\n' "$b" | sed -n "s/^native-code: //p" | tr -d "'")"
echo "$(g name)|$(g versionName)|$(g versionCode)|$(g split)|${m:-0}|${s}|$(sha256sum "$1" | cut -d' ' -f1)|${c}"
EOF

probe() {
  local d out
  d="$(cd "$(dirname "$1")" && pwd -P)"
  out="$(ws_ctr run --rm -v "${d}:/a:ro" --entrypoint sh "$WS_IMG" -c "$PROBE_SH" sh "/a/$(basename "$1")")" \
    || nov "APK probe failed for $(basename "$1") (container, aapt or apksigner verify); see output above."
  printf '%s\n' "$out" | tail -n1
}

read_official() {
  local f pkg vn vc split marks signer hash nat base="" n=0 x e
  local -a files=() codes=() sigs=()
  if [[ -d "$BINARY" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$BINARY" -maxdepth 1 -type f -name '*.apk' | sort)
  else
    files=("$BINARY")
  fi
  [[ "${#files[@]}" -gt 0 ]] || inv "No APK found in ${BINARY}"
  for f in "${files[@]}"; do
    IFS='|' read -r pkg vn vc split marks signer hash nat < <(probe "$f") || true
    [[ -n "$pkg" ]] || nov "Could not read the manifest of $(basename "$f")."
    [[ "$pkg" == "$APP_ID" ]] || inv "Package mismatch: $(basename "$f") is ${pkg}, expected ${APP_ID}."
    [[ "$signer" =~ ^[0-9a-f]{64}$ ]] || nov "No verified signer for $(basename "$f")."
    sigs+=("$(basename "$f")=${signer}")
    if [[ -z "$split" ]]; then
      [[ -z "$base" ]] || inv "More than one base APK in ${BINARY}."
      base="$f" VNAME="$vn" VCODE="$vc" SIGNER="$signer" APP_HASH="$hash" n="$marks" BASE_NATIVE="$nat"
      OFFICIAL+=("${f}|base.apk")
    else
      [[ "$split" =~ ^[A-Za-z0-9_.-]+$ ]] || inv "Unsafe split name in $(basename "$f"): ${split}"
      x="split_config.${split#config.}.apk"
      for e in "${OFFICIAL[@]}"; do [[ "${e##*|}" != "$x" ]] || inv "Two APKs are split ${split} ($(basename "${e%%|*}"), $(basename "$f")): pass one device's set."; done
      OFFICIAL+=("${f}|${x}"); codes+=("$(basename "$f")=${vc}")
    fi
  done
  [[ -n "$base" ]] || inv "No base APK: a config split alone cannot be verified; pass the split directory."
  for x in "${codes[@]}"; do
    [[ "${x##*=}" == "$VCODE" ]] || inv "Split ${x%%=*} has versionCode ${x##*=}, base.apk has ${VCODE}: not one release."
  done
  for x in "${sigs[@]}"; do
    [[ "${x##*=}" == "$SIGNER" ]] || inv "${x%%=*} is signed by ${x##*=}, base.apk by ${SIGNER}: not one release."
  done
  if [[ "${#files[@]}" -gt 1 ]]; then MODE=split
  elif [[ "$n" -gt 0 ]]; then inv "A Play base.apk alone (it requires splits): pass the directory with its splits."
  else MODE=apk; OFFICIAL=("${base}|app.apk"); fi
}

check_arch() {
  local e abi="" n=0 all=""
  for e in "${OFFICIAL[@]}"; do
    if [[ "${e##*|}" =~ ^split_config\.(arm64_v8a|armeabi_v7a|x86_64|x86)\.apk$ ]]; then
      abi="${BASH_REMATCH[1]}"; n=$((n + 1)); all+="${all:+, }${abi}"
    fi
  done
  [[ "$n" -le 1 ]] || inv "The split set holds ${n} ABI splits (${all}); pass one device's set (one ABI)."
  [[ "$abi" == x86_64 ]] || abi="${abi//_/-}"
  [[ -z "$ARCH" || "$n" -eq 0 || "$ARCH" == "$abi" ]] || inv "--arch ${ARCH} does not match the ABI split (${abi})."
  if [[ "$n" -eq 0 && -n "$BASE_NATIVE" ]]; then   # no ABI split: native code sits in base.apk
    ARCH="${ARCH:-${BASE_NATIVE%% *}}"
    [[ " ${BASE_NATIVE} " == *" ${ARCH} "* ]] || inv "--arch ${ARCH} is not in base.apk's native code (${BASE_NATIVE})."
  fi
  ARCH="${ARCH:-${abi:-arm64-v8a}}"
}

ws_section "PREPARATION"
if [[ -n "$BINARY" ]]; then
  read_official
  [[ -n "$VNAME" && "$VCODE" =~ ^[0-9]+$ ]] || nov "Could not read versionName/versionCode from the base APK."
  [[ -z "$VERSION" || "$VERSION" == "$VNAME" ]] || inv "--version ${VERSION} does not match the APK (${VNAME})."
  VERSION="$VNAME"
  [[ "$MODE" != split ]] || check_arch
  [[ "$MODE" != apk || -z "$ARCH" ]] || ws_warn "--arch ignored: one APK is compared whole."
  ws_info "Input: ${MODE} (${#OFFICIAL[@]} APK(s)), version ${VERSION} (${VCODE})"
else
  MODE=apk
fi
[[ "$VERSION" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || inv "Unsafe version string: ${VERSION}"
TAG="${REQ_TAG:-v${VERSION}}"

ws_workspace tangem "$VERSION"
W="$WS_WORKDIR"
mkdir -p "${W}/official" "${W}/built" "${W}/cmp" "${W}/ctx" "${W}/gradle-home" "${W}/build-lock" || nov "Cannot populate ${W}."
# Containers whose output is read through $(...) are tracked here, in this shell.
for c in api dl tag lock-get; do ws_track_container "tangem-${WS_RUN_ID}-${c}"; done
# wsi STAGE [run options] -c SCRIPT sh ARGS...: sh in the WS image; options before -c go to the engine.
wsi() {
  local n="tangem-${WS_RUN_ID}-$1"; local -a o=(); shift
  while [[ $# -gt 0 && "$1" != -c ]]; do o+=("$1"); shift; done
  ws_ctr run --rm --name "$n" -e HOME=/tmp "${o[@]}" --entrypoint sh "$WS_IMG" "$@"
}

ws_info "Resolving tag ${TAG}..."
rc=0
tags="$(wsi tag -c 'git ls-remote --tags --exit-code "$1" "refs/tags/$2"' sh "$REPO_URL" "$TAG")" || rc=$?
[[ "$rc" -ne 2 ]] || nov "No git tag ${TAG} in ${REPO_URL}: no source to build."
[[ "$rc" -eq 0 && -n "$tags" ]] || nov "git ls-remote failed (rc ${rc}); network problem?"

if [[ -z "$BINARY" ]]; then
  ws_info "Reading release ${TAG} (GitHub API, in a container)..."
  # The token (if set) goes into a private wgetrc in the container's /tmp (printf is a builtin), never on a
  # command line; no redirects, so the header goes to api.github.com only.
  wsi api -e GITHUB_TOKEN -c 'umask 077; c="$(mktemp)" || exit 9
    if [ -n "$GITHUB_TOKEN" ]; then printf "header = Authorization: Bearer %s\n" "$GITHUB_TOKEN" > "$c" || exit 9; fi
    wget --config="$c" --max-redirect=0 -q -O - --tries=3 --timeout=60 "$1"; r=$?; rm -f "$c"; exit $r' \
    sh "${API_URL}/${TAG}" > "${W}/release.json" || nov "GitHub API request for release ${TAG} failed."
  # One asset per line, then the release APK of this version with its published digest.
  line="$(tr -d '\n' < "${W}/release.json" | sed 's/"url": *"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\//\n/g' \
    | grep -E "\"name\": *\"app-release[A-Za-z0-9_-]*-${VERSION//./\\.}\.apk\"" || true)"
  [[ "$(printf '%s\n' "$line" | grep -c . || true)" -eq 1 ]] || nov "Release ${TAG} has no single app-release*-${VERSION}.apk asset."
  asset="$(printf '%s\n' "$line" | grep -oE '"name": *"[^"]+"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  want="$(printf '%s\n' "$line" | grep -oE '"digest": *"sha256:[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' | head -n1 || true)"
  url="$(printf '%s\n' "$line" | grep -oE '"browser_download_url": *"https://github\.com/[^"]+"' | sed 's/.*"\(https:[^"]*\)"$/\1/' | head -n1)"
  [[ -n "$want" && -n "$url" ]] || nov "Asset ${asset} has no published sha256 or download URL."
  ws_info "Downloading ${asset} (published sha256 ${want})..."
  # shellcheck disable=SC2046
  wsi dl $(ws_user_flags) -v "${W}/official:/o" -c 'wget -q -O /o/app.apk --tries=3 --timeout=300 "$1"' sh "$url" \
    || nov "Download of ${asset} failed."
  got="$(ws_sha256 "${W}/official/app.apk")"
  [[ "$got" == "$want" ]] || { rm -f "${W}/official/app.apk"; nov "sha256 mismatch for ${asset}: expected ${want}, got ${got}."; }
  BINARY="${W}/official/app.apk"
  IFS='|' read -r pkg VNAME VCODE split _ SIGNER APP_HASH _ < <(probe "$BINARY") || true
  [[ "$pkg" == "$APP_ID" && -z "$split" && "$SIGNER" =~ ^[0-9a-f]{64}$ ]] || nov "Downloaded file is not a signed ${APP_ID} APK."
  [[ "$VNAME" == "$VERSION" && "$VCODE" =~ ^[0-9]+$ ]] || nov "Downloaded APK is version ${VNAME} (${VCODE}), expected ${VERSION}."
  OFFICIAL=("${BINARY}|app.apk"); HASHES=("$APP_HASH")
fi
for e in "${OFFICIAL[@]}"; do
  [[ "${e%%|*}" -ef "${W}/official/${e##*|}" ]] || cp "${e%%|*}" "${W}/official/${e##*|}" || nov "Cannot copy ${e%%|*}."
done

# The build reads Tangem's SDKs from GitHub Packages, which refuses anonymous reads.
[[ -n "${GITHUB_TOKEN:-}" ]] || nov "GITHUB_TOKEN is not set: Tangem's SDKs come from GitHub Packages (token with read:packages). Nothing was built."
export GITHUB_TOKEN
ws_section "BUILD IMAGE (Ubuntu 22.04 by digest, OpenJDK 17, SDK, pinned tools)"
cat > "${W}/ctx/Dockerfile" <<EOF
FROM ${BASE_IMG}
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk \\
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-17-openjdk-amd64/bin:\$PATH
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-17-jdk unzip git curl ca-certificates python3 \\
  && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/android-sdk/cmdline-tools && cd /opt/android-sdk/cmdline-tools \\
  && curl -fsSL -o ct.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \\
  && echo "${CMDLINE_SHA256}  ct.zip" | sha256sum -c - && unzip -q ct.zip && rm ct.zip && mv cmdline-tools latest
RUN yes | sdkmanager --licenses >/dev/null && sdkmanager "platform-tools" "platforms;android-35" "platforms;android-36" \\
    "build-tools;35.0.0" "ndk;25.1.8937393" >/dev/null && chmod -R a+rwX /opt/android-sdk
RUN cd /opt && curl -fsSL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar \\
  && echo "${APKTOOL_SHA256}  apktool.jar" | sha256sum -c - \\
  && curl -fsSL -o bundletool.jar https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar \\
  && echo "${BUNDLETOOL_SHA256}  bundletool.jar" | sha256sum -c - && chmod 0644 apktool.jar bundletool.jar
RUN mkdir -p /tmp/h && chmod 0777 /tmp/h
EOF
ws_track_image "$IMG"
bargs=(-f "${W}/ctx/Dockerfile" -t "$IMG"); [[ "$WS_ENGINE" != podman ]] || bargs=(--format docker "${bargs[@]}")
bg_wait "${CTR[@]}" build "${bargs[@]}" "${W}/ctx" || nov "Build image failed (network, apt or registry?); see the output above."
ws_ok "Image ${IMG} built (per-run, removed at exit)."
# shellcheck disable=SC2046
bx() { local n="tangem-${WS_RUN_ID}-$1"; shift; ws_ctr run --rm --name "$n" $(ws_user_flags) -e HOME=/tmp/h -v "${W}:/w" -w /w "$IMG" "$@"; }
for c in render cmp lock; do ws_track_container "tangem-${WS_RUN_ID}-${c}"; done

ws_section "SOURCE (tag ${TAG}, cloned in a container)"
# shellcheck disable=SC2046
ctr clone "${W}/clone.log" $(ws_user_flags) -e HOME=/tmp/h -v "${W}:/w" -w /w "$IMG" sh -c '
  set -eu
  git clone --quiet --depth 1 --branch "$1" "$2" src || exit 10
  cd src
  git rev-parse HEAD > ../commit.txt
  t="$(git cat-file -t "refs/tags/$1" 2>/dev/null || echo missing)"
  echo "Tag $1 (${t} object) at commit $(git rev-parse HEAD); signatures not checked." > ../tag.txt
' sh "$TAG" "$REPO_URL" || nov "Clone of ${TAG} failed (see ${W}/clone.log)."
COMMIT="$(cat "${W}/commit.txt" 2>/dev/null || true)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || nov "Could not read the commit of ${TAG}."
[[ -f "${W}/src/gradlew" && -d "${W}/src/app" ]] || nov "Tag ${TAG} has no gradlew or app/ (layout changed?)."
# The repo's stub has no com.tangem.wallet client; the google-services plugin needs one for the release id.
{
  printf '{"project_info":{"project_number":"000000000000","project_id":"___STUB___"},"client":['
  first=1
  for pair in com.tangem.wallet.debug:abcdef123456 com.tangem.wallet.internal:abcdef123457 \
              com.tangem.wallet.external:abcdef123458 com.tangem.wallet.release:abcdef123459 com.tangem.wallet:abcdef12345a; do
    [[ "$first" -eq 1 ]] || printf ','; first=0
    printf '{"client_info":{"mobilesdk_app_id":"1:123456789012:android:%s","android_client_info":{"package_name":"%s"}},"oauth_client":[],"api_key":[{"current_key":"AIzaSystubstubstubstubstubstubstubstubs"}],"services":{"appinvite_service":{"other_platform_oauth_client":[]}}}' "${pair#*:}" "${pair%:*}"
  done
  printf '],"configuration_version":"1"}\n'
} > "${W}/src/app/google-services.json" || nov "Cannot write google-services.json."
printf 'sdk.dir=/opt/android-sdk\n' > "${W}/src/local.properties" || nov "Cannot write local.properties."
ws_ok "Commit ${COMMIT}; $(cat "${W}/tag.txt")"

results() {
  local i d="" first="${OFFICIAL[0]:-none}"
  if [[ "$1" == ftbfs ]]; then
    d="(no build to compare: $2)"
  else
    for i in "${!LABELS[@]}"; do
      d+="=== ${LABELS[$i]} ==="$'\n'
      if [[ "${NCOUNT[$i]}" -eq 0 ]]; then d+="(no differing entries)"$'\n'; else d+="${NCOUNT[$i]} differing entr(ies)"$'\n'; fi
    done
    if [[ "$COUNTED" -gt 0 ]]; then
      d+=$'\n'"Differing entries (first 5 of ${COUNTED}; full list: ${W}/cmp/counted.txt):"$'\n'
      d+="$(head -n5 "${W}/cmp/counted.txt" | sed 's/^/  /')"$'\n'
    fi
    if [[ -s "${W}/cmp/accepted.txt" ]]; then
      d+=$'\n'"Accepted differences, excluded from the verdict: $(wc -l < "${W}/cmp/accepted.txt") (full list: ${W}/cmp/accepted.txt)"$'\n'
    fi
  fi
  d+=$'\n'"Revision, tag (and its signature):"$'\n'
  if [[ -s "${W}/tag.txt" ]]; then d+="$(cat "${W}/tag.txt")"; else d+="Tag: ${TAG:-unknown}"; fi
  echo ""
  ws_results_block "$APP_ID" "${SIGNER:-unknown}" "${VNAME:-$VERSION}" "${VCODE:-unknown}" "$1" "${APP_HASH:-unknown}" "${COMMIT:-unknown}" "$d"
  echo ""
  echo "Hash legend: appHash = SHA-256 of the official ${first##*|} as supplied (publish this one)."
  for i in "${!LABELS[@]}"; do
    echo "  ${LABELS[$i]}: official ${OFF_HASH[$i]}"
    echo "  ${LABELS[$i]}: built    ${BUILT_HASH[$i]} (unsigned, evidence only)"
  done
  [[ -z "$BUILD_LOCK_FILE" ]] || echo "build-lock.json (attach as output file): ${BUILD_LOCK_FILE}"
  echo "Workspace: ${W}"
}

TASK=assembleGoogleRelease; [[ "$MODE" == split ]] && TASK=bundleGoogleRelease
ws_section "BUILD (gradlew ${TASK}, versionCode ${VCODE}, versionName ${VNAME})"
ws_info "Typically 30-60 min; GITHUB_TOKEN is passed by name (-e), never by value. Gradle heap ${GRADLE_XMX} (upstream 8g)."
rc=0
# shellcheck disable=SC2046
ctr build "${W}/build.log" $(ws_user_flags) "${MEM_ARGS[@]}" -e HOME=/tmp/h -e GRADLE_USER_HOME=/gh -e GITHUB_TOKEN \
  -e "GITHUB_ACTOR=${GH_ACTOR}" -e "GRADLE_OPTS=-Xmx12g -XX:MaxMetaspaceSize=512m" \
  -e "KOTLIN_DAEMON_JVM_OPTIONS=-Xmx4g -XX:MaxMetaspaceSize=512m" \
  -v "${W}/src:/src" -v "${W}/gradle-home:/gh" -w /src "$IMG" bash -c \
  'chmod +x gradlew && exec ./gradlew "$@" -x :core:ui:verifyDesignTokens --no-daemon --no-build-cache --stacktrace --max-workers=4' \
  sh "$TASK" "-PversionCode=${VCODE}" "-PversionName=${VNAME}" \
  "-Dorg.gradle.jvmargs=-Xmx${GRADLE_XMX} -XX:MaxMetaspaceSize=1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Dfile.encoding=UTF-8" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  # 90: log not written; 126+: not run, killed or stopped. Only exit 1 (Gradle failed) is classified.
  [[ "$rc" -eq 1 ]] || nov "Build container exited ${rc} (log not written, not run or killed); no verdict. Log: ${W}/build.log"
  kind="$(ws_gradle_failure_kind "${W}/build.log")"
  [[ "$kind" == source ]] || nov "Build stopped (exit ${rc}, ${kind}); not a source error, no verdict. Log: ${W}/build.log"
  ws_error "Gradle reports a source error at ${TAG} (exit ${rc})."
  FTBFS_NOTE="Tangem ${VERSION} (${MODE}): gradlew ${TASK} failed at tag ${TAG}, commit ${COMMIT}, with a compiler or resource error."
  results ftbfs "Gradle source error at ${TAG}"
  ws_write_yaml ftbfs "$FTBFS_NOTE" "${HASHES[@]}"
  exit 1
fi

if [[ "$MODE" == split ]]; then
  mapfile -t arts < <(find "${W}/src/app/build/outputs/bundle/googleRelease" -maxdepth 1 -type f -name '*.aab' 2>/dev/null)
  [[ "${#arts[@]}" -eq 1 ]] || nov "Expected one AAB in app/build/outputs/bundle/googleRelease, found ${#arts[@]}."
  cp "${arts[0]}" "${W}/built/app.aab" || nov "Cannot copy the AAB."
else
  mapfile -t arts < <(find "${W}/src/app/build/outputs/apk/google/release" -maxdepth 1 -type f -name '*.apk' 2>/dev/null)
  [[ "${#arts[@]}" -eq 1 ]] || nov "Expected one APK in app/build/outputs/apk/google/release, found ${#arts[@]}."
  cp "${arts[0]}" "${W}/built/app.apk" || nov "Cannot copy the APK."
fi
ws_ok "Built: ${arts[0]#"${W}/"}"

ws_section "BUILD RECORD (ws-buildlock, verdict unaffected)"
BL_SH="${W}/ctx/ws-buildlock.sh"; bl_rc=0
if bx lock-get curl -fsSL --max-time 60 -o /w/ctx/ws-buildlock.sh "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" \
   && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
  bx lock bash /w/ctx/ws-buildlock.sh --out /w/build-lock --gradle-home /w/gradle-home --src /w/src --app-id "$APP_ID" \
    --version "$VERSION" --platform android --commit "$COMMIT" > "${W}/build-lock.log" 2>&1 || bl_rc=$?
  bl_n="$(grep -o '"ecosystem": *"gradle"' "${W}/build-lock/build-lock.json" 2>/dev/null | wc -l || true)"
  if [[ "$bl_rc" -eq 0 && "${bl_n:-0}" -gt 0 ]]; then BUILD_LOCK_FILE="${W}/build-lock/build-lock.json"
    ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (${bl_n} Gradle artifacts, sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
  else ws_warn "No usable build-lock.json (exit ${bl_rc}; see ${W}/build-lock.log)."; fi
else ws_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256."; fi
# Offer build-lock.json only if a complete scan finds no token in it (0 = found, 2+ = scan failed).
if [[ -n "$BUILD_LOCK_FILE" && -n "${GITHUB_TOKEN:-}" ]]; then
  bl_t=0; grep_tok "$BUILD_LOCK_FILE" >/dev/null || bl_t=$?
  [[ "$bl_t" -eq 1 ]] || { BUILD_LOCK_FILE=""; ws_warn "build-lock.json holds the token or could not be scanned: not offered."; }
fi

if [[ "$MODE" == split ]]; then
  ws_section "RENDER SPLITS (bundletool ${BUNDLETOOL_VERSION})"
  locales="" density=480 sdk="${DEVICE_SDK:-36}"
  for e in "${OFFICIAL[@]}"; do
    s="${e##*|}"; s="${s#split_config.}"; s="${s%.apk}"
    case "$s" in
      base|arm64_v8a|armeabi_v7a|x86_64|x86) ;;
      ldpi) density=120 ;; mdpi) density=160 ;; hdpi) density=240 ;; xhdpi) density=320 ;;
      xxhdpi) density=480 ;; xxxhdpi) density=640 ;; tvdpi) density=213 ;;
      *dpi) ;;
      *) locales+="${locales:+,}\"${s}\"" ;;
    esac
  done
  printf '{"supportedAbis":["%s"],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' \
    "$ARCH" "${locales:-\"en\"}" "$density" "$sdk" > "${W}/device-spec.json"
  ws_info "Device spec: $(cat "${W}/device-spec.json")"
  [[ -n "$DEVICE_SDK" ]] || ws_warn "sdkVersion 36 assumed; pass --device-sdk for the phone's API level."
  bx render bash -c 'set -euo pipefail
    java -jar /opt/bundletool.jar build-apks --bundle=built/app.aab --output=built/app.apks --device-spec=device-spec.json \
      --mode=default --overwrite
    unzip -q -o built/app.apks -d built/apks
    for f in built/apks/splits/*.apk; do
      n=${f##*/}; n=${n%.apk}
      case $n in base-master) cp "$f" built/base.apk ;; base-*) cp "$f" "built/split_config.${n#base-}.apk" ;;
        *) echo "Unexpected rendered APK ${f##*/} (feature module?): not handled" >&2; exit 3 ;; esac
    done' || nov "bundletool could not render the splits."
fi

ws_section "COMPARE"
cat > "${W}/cmp.py" <<'EOF'
import hashlib, os, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET
mode, names = sys.argv[1], sys.argv[2:]
SIG = re.compile(r'META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))')
AN = '{http://schemas.android.com/apk/res/android}'
CL = 'com.google.firebase.crashlytics.mapping_file_id'
PLAY = {'com.android.stamp.source': lambda v: v == 'https://play.google.com/store',
        'com.android.stamp.type': lambda v: v == 'STAMP_TYPE_DISTRIBUTION_APK',
        'com.android.vending.derived.apk.id': lambda v: v.isdigit()}
def sha(b): return hashlib.sha256(b).hexdigest()
def fsha(p):
    with open(p, 'rb') as f: return sha(f.read())
def entries(p):
    z = zipfile.ZipFile(p)
    fs = [i for i in z.infolist() if not i.is_dir()]
    if len({i.filename for i in fs}) != len(fs): sys.exit(f'{p}: duplicate ZIP entry names; cannot compare')
    return {i.filename: (sha(z.read(i)), i.file_size) for i in fs}
class Undecided(Exception): pass
def decode(p, d):
    if not os.path.isdir(d):
        subprocess.run(['java', '-jar', '/opt/apktool.jar', 'd', '-f', '--no-src', '-o', d, p], check=True, capture_output=True)
    return d
def stamp_ok(p):
    r = subprocess.run(['/opt/android-sdk/build-tools/35.0.0/apksigner', 'verify', '--verbose', p], capture_output=True, text=True)
    if r.returncode: raise Undecided(f'apksigner verify failed on {p}')
    return 'Verified for SourceStamp: true' in r.stdout
def manifest(d, strip):
    root = ET.parse(d + '/AndroidManifest.xml').getroot()
    for parent in (list(root.iter()) if strip else []):
        for c in list(parent):
            n, v = c.get(AN + 'name'), c.get(AN + 'value') or ''
            # only a childless <meta-data> with exactly android:name + android:value, both as allowed
            if c.tag == 'meta-data' and len(c) == 0 and set(c.attrib) == {AN + 'name', AN + 'value'} and n in PLAY and PLAY[n](v):
                parent.remove(c)
    return ET.canonicalize(ET.tostring(root, encoding='unicode'), strip_text=True)
def tree(d):
    return {os.path.relpath(os.path.join(r, f), d): fsha(os.path.join(r, f)) for r, _, fs in os.walk(d) for f in fs}
def no_cl(d):
    root = ET.parse(d + '/res/values/strings.xml').getroot()
    hit = [c for c in root if c.tag == 'string' and c.get('name') == CL and len(c) == 0 and set(c.attrib) == {'name'}]
    if len(hit) != 1: return None
    root.remove(hit[0])
    return ET.canonicalize(ET.tostring(root, encoding='unicode'))
def res_why(do, db):
    if not (os.path.isdir(do + '/res') and os.path.isdir(db + '/res')): raise Undecided('apktool produced no res/')
    a, b = tree(do + '/res'), tree(db + '/res')
    if a == b: return 'binary-only; decoded res/ identical'
    if [k for k in set(a) | set(b) if a.get(k) != b.get(k)] != ['values/strings.xml'] or 'values/strings.xml' not in a or 'values/strings.xml' not in b: return None
    x, y = no_cl(do), no_cl(db)
    return 'decoded res/ differs only in the one Crashlytics mapping_file_id string' if x is not None and x == y else None
cnt, acc = open('cmp/counted.txt', 'w'), open('cmp/accepted.txt', 'w')
for name in names:
    lab, off, bui = name[:-4].replace('split_config.', ''), 'official/' + name, 'built/' + name
    if not os.path.exists(bui):
        cnt.write(f'{lab}: no built counterpart\n'); print(f'{lab}|1|0|{fsha(off)}|-'); continue
    a, b, nc, na = entries(off), entries(bui), 0, 0
    for k in sorted(set(a) | set(b)):
        if k in a and k in b and a[k][0] == b[k][0]: continue
        why = None
        if k not in b and SIG.fullmatch(k): why = 'signature file, official only'
        try:
            if mode == 'split' and k == 'stamp-cert-sha256' and k not in b and a[k][1] == 32 and stamp_ok(off):
                why = 'Play SourceStamp, 32 bytes, official only, apksigner SourceStamp verified'
            elif k in a and k in b and (k == 'resources.arsc' or (k == 'AndroidManifest.xml' and mode == 'split')):
                do, db = decode(off, f'cmp/dec_{lab}_off'), decode(bui, f'cmp/dec_{lab}_bui')
                if k == 'resources.arsc': why = res_why(do, db)
                elif mode == 'split' and manifest(do, True) == manifest(db, False):
                    why = 'Play distribution metadata only'
        except (Undecided, subprocess.CalledProcessError, ET.ParseError, OSError, UnicodeDecodeError) as e:
            cnt.write(f'{lab}: {k} could not be classified ({e})\n'); cnt.close()
            sys.exit(f'{lab}: {k}: classification failed ({e}); no verdict')
        if why:
            acc.write(f'{lab}: {k} ({why})\n'); na += 1
        else:
            where = 'only in official' if k not in b else 'only in built' if k not in a else 'differs'
            cnt.write(f'{lab}: {k} {where}\n'); nc += 1
    print(f'{lab}|{nc}|{na}|{fsha(off)}|{fsha(bui)}')
built = {n for n in os.listdir('built') if n.endswith('.apk') and (n != 'app.apk' or mode == 'apk')}
for n in sorted(built - set(names)):
    lab = n[:-4].replace('split_config.', '')
    cnt.write(f'{lab}: built split with no official counterpart\n'); print(f'{lab}|1|0|-|{fsha("built/" + n)}')
EOF
names=()
for e in "${OFFICIAL[@]}"; do names+=("${e##*|}"); done
summary="$(bx cmp python3 cmp.py "$MODE" "${names[@]}")" || nov "Comparison failed."
# One record per official APK (official hash set) plus built-only extras (official hash "-"); labels unique.
n_off=0; seen=" " want=" "
for x in "${names[@]}"; do x="${x%.apk}"; want+="${x#split_config.} "; done
while IFS='|' read -r lab nc na oh bh; do
  [[ -n "$lab" ]] || continue
  [[ "$seen" != *" ${lab} "* && "$nc" =~ ^[0-9]+$ && "$na" =~ ^[0-9]+$ ]] || nov "Malformed or duplicate comparison record: ${lab}"
  [[ "$oh" == - || "$want" == *" ${lab} "* ]] || nov "Comparison record ${lab} is not one of the official APKs."
  seen+="${lab} "; [[ "$oh" == - ]] || n_off=$((n_off + 1))
  LABELS+=("$lab") NCOUNT+=("$nc") NACC+=("$na") OFF_HASH+=("$oh") BUILT_HASH+=("$bh")
  COUNTED=$((COUNTED + nc))
  ws_info "${lab}: ${nc} differing, ${na} accepted"
done <<< "$summary"
[[ "$n_off" -eq "${#OFFICIAL[@]}" ]] || nov "Comparison returned ${n_off} result(s) for ${#OFFICIAL[@]} official APK(s)."

ws_section "RESULT"
if [[ "$COUNTED" -eq 0 ]]; then verdict=reproducible; ws_ok "VERDICT: REPRODUCIBLE"
else verdict=not_reproducible; ws_warn "VERDICT: NOT REPRODUCIBLE (${COUNTED} differing entries)"; fi
n_acc="$(wc -l < "${W}/cmp/accepted.txt" || true)"
results "$verdict"
ws_write_yaml "$verdict" "Tangem ${VERSION} (${VCODE}; ${MODE}, ${#OFFICIAL[@]} official APK(s)) vs tag ${TAG}, commit ${COMMIT}.
Build: Ubuntu 22.04 (by digest), OpenJDK 17, gradlew ${TASK} with -PversionCode/-PversionName from the official APK and google-services.json = the repo's stub plus com.tangem.wallet$([[ "$MODE" == split ]] && echo "; bundletool ${BUNDLETOOL_VERSION}, device spec $(tr -d '\n' < "${W}/device-spec.json")").
Compared: every ZIP entry by SHA-256 of its content. Differing entries: ${COUNTED}. Accepted (WS #574): ${n_acc// /} (signing files, Play SourceStamp and manifest meta-data, decoded-identical res/, Crashlytics mapping_file_id only)." "${HASHES[@]}"
[[ "$verdict" == reproducible ]] && exit 0
exit 1
