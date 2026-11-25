#!/usr/bin/env bash
# coinspacewallet-v0.5.0_build.sh - Coin Wallet Android reproducible build verification
# Version:          v0.5.0
# Last modified by: Claude Opus 5.5 for Danny Garcia
# Last modified on: 2026-11-25
# Organization:     WalletScrutiny.com
# App ID:           com.coinspace.app
# Project:          https://github.com/CoinSpace/CoinSpace
# Disclaimer: provided as-is, without warranty. Review before running. This is not a security audit.
# Steps: read the official APK(s) (Play split set, or the GitHub Coin.Wallet.apk), clone the release tag,
#   build a pinned toolchain image (Node 20.x, Zulu JDK 17, Android SDK, Gradle), run
#   upstream's CI steps (npm ci, i18n:ci, web build, phonegap `npm run build`), compile the unsigned
#   release AAB (Play) or APK (GitHub), compare every ZIP entry, write results.
#   Library ws-rb-core (#1023); build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Needs GITHUB_TOKEN (read:packages): the @coinspace/* npm packages exist only on npm.pkg.github.com.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library.

SCRIPT_NAME="coinspacewallet-v0.5.0_build.sh"
SCRIPT_VERSION="v0.5.0"
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

APP_ID="com.coinspace.app"
REPO_URL="https://github.com/CoinSpace/CoinSpace.git"
API_URL="https://api.github.com/repos/CoinSpace/CoinSpace/releases/tags"
RELEASES_URL="https://github.com/CoinSpace/CoinSpace/releases/download"
GH_ASSET="Coin.Wallet.apk"
# Probe and clone image (aapt/apksigner in build-tools 29.0.3, git), pinned by digest.
WS_IMG="docker.io/walletscrutiny/android@sha256:eabd60543f19831feef6db22e9a1ada0ef469eef723119f1c96bd836198614c3"
BASE_IMG="docker.io/library/ubuntu@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb"  # 22.04, as upstream CI
JDK_URL="https://cdn.azul.com/zulu/bin/zulu17.70.201-ca-jdk17.0.21.1-linux_x64.tar.gz"
JDK_SHA256="2837aee74267e02106ee6006809bb0de23ccfa43bf5005621517194b79975695"
TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
TOOLS_SHA256="2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"
# Gradle 8.14.2 = cordova-android 15.1.0's GRADLE_VERSION. One checked zip is both the bootstrap
# `gradle` and the wrapper's distribution (CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL, file://).
GRADLE_VER="8.14.2"
GRADLE_URL="https://services.gradle.org/distributions/gradle-${GRADLE_VER}-bin.zip"
GRADLE_SHA256="7197a12f450794931532469d4ff21a59ea2c1cd59a3ec3f89c035c3c420a6999"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"
# Node: CI requests "20" (setup-node), not .nvmrc (20.11.1, below cordova-android 15.1.0's engines
# >=20.17.0). Pin 20.20.2, the latest published 20.x before the tag date (2026-11-20); the official
# run's exact patch version was not checked.
NODE_VER="20.20.2"
NODE_SHA="df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d"  # node-v20.20.2-linux-x64.tar.xz
declare -A BUNDLETOOL_SHA256=(
  [1.17.2]=2d4ad908faea64047c1cc9cb747e6aa667c6ab192e09607bd16b67246a8cd6ae
  [1.18.1]=675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c
  [1.18.2]=378b5434cd1378bef6b2bc527b8c7f0ff2584b273830335bce54d6d0813c8584
  [1.18.3]=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29
)

VERSION="" ARCH="" BINARY="" DEVICE_SDK="" MODE="" TAG="" COMMIT="" SIGNER="" VNAME="" VCODE="" APP_HASH=""
COUNTED=0 BG_PID="" W="" HASHES=() bt_ver=""
declare -a OFFICIAL=() LABELS=() NCOUNT=() NACC=() OFF_HASH=() BUILT_HASH=()

nov() { ws_no_verdict "$1"; }   # runtime, network, tool or input problem: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML

ws_refuse_root
ws_install_traps

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--binary <apk|split dir>] [--version <v>] [--arch <abi>] [--type <t>]
  --binary, --apk  Play base.apk, a directory of Play split APKs, or the GitHub ${GH_ASSET}
  --version        release version; read from the APK when omitted. Without --binary the GitHub
                   ${GH_ASSET} of this version is downloaded and checked against its published sha256
  --arch           ABI of the split set (default: the ABI split present, else arm64-v8a)
  --type           accepted for ABS compatibility; unused
  --device-sdk     device API level for bundletool (default: 36)
  --help
Environment: GITHUB_TOKEN with read:packages (required by the @coinspace/* packages).
Exit codes: 0 reproducible, 1 not_reproducible/ftbfs/no verdict, 2 invalid parameters
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary|--apk) ws_require_value "$1" "${2:-}"; BINARY="$2"; shift 2 ;;
    --version)      ws_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --arch)         ws_require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
    --type)         ws_require_value "$1" "${2:-}"; shift 2 ;;
    --device-sdk)   ws_require_value "$1" "${2:-}"; DEVICE_SDK="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;
  esac
done

[[ -n "$BINARY" || -n "$VERSION" ]] || inv "--binary or --version is required."
[[ -z "$BINARY" || -e "$BINARY" ]] || inv "--binary not found: ${BINARY}"
[[ -z "$DEVICE_SDK" || "$DEVICE_SDK" =~ ^[0-9]+$ ]] || inv "--device-sdk must be an integer."
case "$ARCH" in ""|arm64-v8a|armeabi-v7a|x86_64|x86) ;; *) inv "Unsupported --arch: ${ARCH}" ;; esac
[[ -z "$VERSION" || "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || inv "Unsafe version string: ${VERSION}"
[[ -z "$BINARY" ]] || BINARY="$(realpath "$BINARY")"

ws_results_init
ws_engine
command -v curl >/dev/null || nov "curl is required on the host (fetches tools and ws-buildlock.sh)"
[[ -n "${GITHUB_TOKEN:-}" ]] || nov "GITHUB_TOKEN (read:packages) is not set: Coin Wallet's @coinspace/* packages are only on npm.pkg.github.com."
export NODE_AUTH_TOKEN="$GITHUB_TOKEN"   # passed to the build container by name only (-e NODE_AUTH_TOKEN)
CTR=(docker); [[ "$WS_ENGINE" != podman ]] || CTR=(podman --cgroup-manager=cgroupfs)
IMG="localhost/ws-coinspace:${WS_RUN_ID}"

# Background + wait: a signal acts at once; the exit hook stops and reaps it.
bg_wait() { local rc=0; "$@" & BG_PID=$!; wait "$BG_PID" || rc=$?; BG_PID=""; return $rc; }
ws_cleanup_hook() { [[ -z "$BG_PID" ]] || { kill "$BG_PID"; wait "$BG_PID"; } 2>/dev/null || true; }
# ctr STAGE LOG ARGS...: run a named container (removed at exit), output to the terminal and LOG;
# returns the container's exit code, or 90 if LOG was not written.
ctr() {
  local n="coinspace-${WS_RUN_ID}-$1" l="$2" rc=0; shift 2
  ws_track_container "$n"
  bg_wait bash -c 'l="$1"; shift; "$@" < /dev/null 2>&1 | tee "$l"; s=("${PIPESTATUS[@]}"); [[ ${s[1]} == 0 ]] || exit 90; exit "${s[0]}"' \
    _ "$l" "${CTR[@]}" run --rm --name "$n" "$@" || rc=$?
  return $rc
}

read -r -d '' PROBE_SH <<'EOF' || true
A=/opt/android-sdk/build-tools/29.0.3
b="$($A/aapt dump badging "$1" 2>/dev/null | head -n1)"
g() { printf '%s\n' "$b" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
m="$($A/aapt dump xmltree "$1" AndroidManifest.xml 2>/dev/null | grep -c -E 'isSplitRequired|requiredSplitTypes|vending\.splits\.required')"
echo "$(g name)|$(g versionName)|$(g versionCode)|$(g split)|${m:-0}|$(sha256sum "$1" | cut -d' ' -f1)"
EOF

probe() {
  local d out
  d="$(cd "$(dirname "$1")" && pwd -P)"
  out="$(ws_ctr run --rm -v "${d}:/a:ro" --entrypoint sh "$WS_IMG" -c "$PROBE_SH" sh "/a/$(basename "$1")")" \
    || nov "Could not run the APK probe container (${WS_IMG})."
  printf '%s\n' "$out" | tail -n1
}

read_official() {
  local f pkg vn vc split marks hash base="" n=0 x
  local -a files=() codes=()
  if [[ -d "$BINARY" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$BINARY" -maxdepth 1 -type f -name '*.apk' | sort)
  else
    files=("$BINARY")
  fi
  [[ "${#files[@]}" -gt 0 ]] || inv "No APK found in ${BINARY}"
  for f in "${files[@]}"; do
    IFS='|' read -r pkg vn vc split marks hash < <(probe "$f") || true
    [[ -n "$pkg" ]] || nov "Could not read the manifest of $(basename "$f")."
    [[ "$pkg" == "$APP_ID" ]] || inv "Package mismatch: $(basename "$f") is ${pkg}, expected ${APP_ID}."
    if [[ -z "$split" ]]; then
      [[ -z "$base" ]] || inv "More than one base APK in ${BINARY}."
      base="$f" VNAME="$vn" VCODE="$vc" APP_HASH="$hash" n="$marks"
    else
      OFFICIAL+=("${f}|split_config.${split#config.}.apk"); codes+=("$(basename "$f")=${vc}")
    fi
  done
  [[ -n "$base" ]] || inv "No base APK: a config split alone cannot be verified; pass the split directory."
  for x in "${codes[@]}"; do
    [[ "${x##*=}" == "$VCODE" ]] || inv "Split ${x%%=*} has versionCode ${x##*=}, base.apk has ${VCODE}: not one release."
  done
  if [[ "${#files[@]}" -gt 1 || "$n" -gt 0 ]]; then MODE=split; OFFICIAL=("${base}|base.apk" "${OFFICIAL[@]}")
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
  if [[ -n "$ARCH" && "$n" -gt 0 && "$ARCH" != "$abi" ]]; then
    inv "--arch ${ARCH} does not match the ABI split (${abi})."
  fi
  ARCH="${ARCH:-${abi:-arm64-v8a}}"
}

ws_section "PREPARATION"
if [[ -n "$BINARY" ]]; then
  read_official
  [[ -n "$VNAME" && "$VCODE" =~ ^[0-9]+$ ]] || nov "Could not read versionName/versionCode from the base APK."
  [[ -z "$VERSION" || "$VERSION" == "$VNAME" ]] || inv "--version ${VERSION} does not match the APK (${VNAME})."
  VERSION="$VNAME"
  if [[ "$MODE" == split ]]; then check_arch; elif [[ -n "$ARCH" ]]; then ws_warn "--arch ignored: the GitHub APK holds every ABI."; fi
  ws_info "Input: ${MODE} (${#OFFICIAL[@]} APK(s)), version ${VERSION} (${VCODE})"
else
  MODE=apk
fi
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || inv "Unsafe version string: ${VERSION}"
DIST=android-apk PKG_TYPE=apk; [[ "$MODE" == split ]] && DIST=android-play PKG_TYPE=bundle

ws_workspace coinspacewallet "$VERSION"
W="$WS_WORKDIR"
mkdir -p "${W}/official" "${W}/built" "${W}/cmp" "${W}/tools" "${W}/gradle-home" "${W}/home" "${W}/build-lock"

ws_info "Resolving tag for ${VERSION}..."
rc=0
tags="$(ws_ctr run --rm -e HOME=/tmp --entrypoint git "$WS_IMG" ls-remote --tags --exit-code "$REPO_URL" \
  "refs/tags/v${VERSION}" "refs/tags/${VERSION}")" || rc=$?
[[ "$rc" -ne 2 ]] || nov "No git tag v${VERSION} or ${VERSION} in ${REPO_URL}: no source to build."
[[ "$rc" -eq 0 ]] || nov "git ls-remote failed (rc ${rc}); network problem?"
TAG="$(printf '%s\n' "$tags" | sed -n 's#.*refs/tags/\([^^]*\)$#\1#p' | head -n1)"
[[ -n "$TAG" ]] || nov "Could not parse the tag from git ls-remote."
ws_info "Tag: ${TAG}"

if [[ -z "$BINARY" ]]; then
  ws_info "Reading the published sha256 of ${GH_ASSET} (GitHub release API)..."
  ws_fetch "${API_URL}/${TAG}" "${W}/release.json"
  want="$(tr -d ' \n' < "${W}/release.json" | sed 's/{"url":"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\//\n/g' \
    | grep -F "\"name\":\"${GH_ASSET}\"" | grep -oE '"digest":"sha256:[0-9a-f]{64}"' | head -n1 | grep -oE '[0-9a-f]{64}' || true)"
  [[ -n "$want" ]] || nov "Release ${TAG} has no ${GH_ASSET} with a published sha256."
  ws_info "Downloading ${GH_ASSET} (published sha256 ${want})..."
  ws_fetch "${RELEASES_URL}/${TAG}/${GH_ASSET}" "${W}/official/app.apk" "$want"
  BINARY="${W}/official/app.apk"
  IFS='|' read -r pkg VNAME VCODE _ marks APP_HASH < <(probe "$BINARY") || true
  [[ "$pkg" == "$APP_ID" && "${marks:-1}" -eq 0 && "$VCODE" =~ ^[0-9]+$ ]] || nov "Downloaded file is not the ${APP_ID} GitHub APK."
  [[ "$VNAME" == "$VERSION" ]] || nov "Downloaded APK is version ${VNAME}, expected ${VERSION}."
  OFFICIAL=("${BINARY}|app.apk"); HASHES=("$APP_HASH")
fi
for e in "${OFFICIAL[@]}"; do
  [[ "${e%%|*}" -ef "${W}/official/${e##*|}" ]] || cp "${e%%|*}" "${W}/official/${e##*|}"
done
RUN_NUMBER=$((VCODE - 2530))   # phonegap/android.js: versionCode = GITHUB_RUN_NUMBER + 2530
[[ "$RUN_NUMBER" -gt 0 ]] || nov "versionCode ${VCODE} is below 2531; android.js cannot produce it."

ws_section "SOURCE (clone in a container)"
# shellcheck disable=SC2046
ctr clone "${W}/clone.log" $(ws_user_flags) -e HOME=/tmp -v "${W}:/w" -w /w --entrypoint sh "$WS_IMG" -c '
  set -eu
  git clone --quiet --depth 1 --branch "$1" "$2" src || exit 10
  cd src
  git rev-parse HEAD > ../commit.txt
  t="$(git cat-file -t "refs/tags/$1" 2>/dev/null || echo missing)"
  {
    echo "Tag $1 ($t object) at commit $(git rev-parse HEAD)."
    if [ "$t" = tag ]; then git tag -v "$1" 2>&1 | tail -n2 || true; fi
    git verify-commit HEAD >/dev/null 2>&1 && echo "Commit signature: valid." || echo "Commit signature: not verified."
  } > ../tag.txt
' sh "$TAG" "$REPO_URL" || nov "Clone of ${TAG} failed (see ${W}/clone.log)."
COMMIT="$(cat "${W}/commit.txt" 2>/dev/null || true)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || nov "Could not read the commit of ${TAG}."
NVMRC="$(tr -d ' v\r\n' < "${W}/src/.nvmrc" 2>/dev/null || true)"
ws_ok "Commit ${COMMIT}; Node ${NODE_VER} (CI \"20\"; .nvmrc says ${NVMRC:-none}); ${DIST}, versionCode ${VCODE} (GITHUB_RUN_NUMBER ${RUN_NUMBER})"

ws_section "TOOLCHAIN IMAGE (pinned: Ubuntu 22.04, Zulu JDK 17, Node ${NODE_VER}, SDK tools, Gradle ${GRADLE_VER}, apktool 3.0.3)"
cat > "${W}/tools/Containerfile" <<EOF
FROM ${BASE_IMG}
ENV DEBIAN_FRONTEND=noninteractive JAVA_HOME=/opt/jdk ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=/opt/node/bin:/opt/jdk/bin:/opt/gradle-${GRADLE_VER}/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/36.0.0:\$PATH
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates curl git unzip xz-utils python3 > /dev/null && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/jdk.tgz "${JDK_URL}" && echo "${JDK_SHA256}  /tmp/jdk.tgz" | sha256sum -c - \\
 && mkdir -p /opt/jdk && tar -xzf /tmp/jdk.tgz -C /opt/jdk --strip-components=1 && rm /tmp/jdk.tgz
RUN curl -fsSL -o /tmp/node.txz "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz" \\
 && echo "${NODE_SHA}  /tmp/node.txz" | sha256sum -c - && mkdir -p /opt/node && tar -xJf /tmp/node.txz -C /opt/node --strip-components=1 && rm /tmp/node.txz
RUN curl -fsSL -o /tmp/tools.zip "${TOOLS_URL}" && echo "${TOOLS_SHA256}  /tmp/tools.zip" | sha256sum -c - \\
 && mkdir -p /opt/android-sdk/cmdline-tools && unzip -q /tmp/tools.zip -d /tmp && mv /tmp/cmdline-tools /opt/android-sdk/cmdline-tools/latest && rm /tmp/tools.zip \\
 && (yes || true) | sdkmanager --licenses > /dev/null \\
 && sdkmanager "platform-tools" "platforms;android-35" "platforms;android-36" "build-tools;35.0.0" "build-tools;36.0.0" > /dev/null
RUN mkdir -p /opt/dist && curl -fsSL -o /opt/dist/gradle.zip "${GRADLE_URL}" && echo "${GRADLE_SHA256}  /opt/dist/gradle.zip" | sha256sum -c - \\
 && unzip -q /opt/dist/gradle.zip -d /opt
RUN curl -fsSL -o /opt/apktool.jar "${APKTOOL_URL}" && echo "${APKTOOL_SHA256}  /opt/apktool.jar" | sha256sum -c -
RUN mkdir -p /.android && chmod 777 /.android
EOF
ws_track_image "$IMG"
bargs=(-f "${W}/tools/Containerfile" -t "$IMG")
if [[ "$WS_ENGINE" == podman ]]; then bargs=(--format docker --layers=false "${bargs[@]}"); else bargs=(--no-cache "${bargs[@]}"); fi
bg_wait "${CTR[@]}" build "${bargs[@]}" "${W}/tools" || nov "Toolchain image build failed (network, registry or checksum); see the output above."
ws_ok "Image ${IMG} built (per-run, removed at exit)."

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
  echo "Input: ${MODE}; appHash is the official ${first##*|} as provided (publish this one)."
  for i in "${!LABELS[@]}"; do
    echo "  ${LABELS[$i]}: official ${OFF_HASH[$i]}"
    echo "  ${LABELS[$i]}: built    ${BUILT_HASH[$i]}"
  done
  [[ -z "${BUILD_LOCK_FILE:-}" ]] || echo "build-lock.json (attach as output file): ${BUILD_LOCK_FILE}"
  echo "Workspace: ${W}"
}

ws_section "BUILD (upstream CI steps, ${DIST}, unsigned ${PKG_TYPE})"
# Upstream ci.yml "Build app" with its secrets left empty (API hosts, Sentry DSN and upload, partner keys):
# Vite embeds those values in the JS bundle, so the official bundle can differ there; such differences
# are counted. Hidden *.map files are deleted as upstream's Sentry upload step does.
rc=0
# shellcheck disable=SC2046
ctr build "${W}/build.log" $(ws_user_flags) --init -v "${W}:/w" -w /w/src -e HOME=/w/home \
  -e ANDROID_USER_HOME=/w/home/.android -e GRADLE_USER_HOME=/w/gradle-home -e NODE_AUTH_TOKEN -e CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL=file:///opt/dist/gradle.zip \
  -e NODE_OPTIONS=--max-old-space-size=3575 -e VITE_BUILD_TYPE=phonegap -e VITE_PLATFORM=android \
  -e "VITE_DISTRIBUTION=${DIST}" -e "VITE_COMMIT=${COMMIT}" -e VITE_SENTRY_ENVIRONMENT=production \
  -e "GITHUB_RUN_NUMBER=${RUN_NUMBER}" "$IMG" bash -c '
  set -euo pipefail
  printf "@coinspace:registry=https://npm.pkg.github.com\n//npm.pkg.github.com/:_authToken=\${NODE_AUTH_TOKEN}\n" > "$HOME/.npmrc"
  NODE_ENV=ci npm --prefix web ci
  NODE_ENV=ci npm --prefix phonegap ci
  export NODE_ENV=production
  npm --prefix web run i18n:ci
  npm --prefix web run build
  find phonegap/build/www -name "*.map" -type f -delete   # upstream Sentry step deletes these after upload
  npm --prefix phonegap run build
  cd phonegap/build
  ../node_modules/.bin/cordova compile android --release -- --packageType="$1"
' sh "$PKG_TYPE" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  # 90: log not written; 126+: not run, killed or stopped. Only exit 1 (a build step failed) is classified.
  [[ "$rc" -eq 1 ]] || nov "Build container exited ${rc} (log not written, not run or killed); no verdict. Log: ${W}/build.log"
  kind="$(ws_gradle_failure_kind "${W}/build.log")"
  [[ "$kind" == source ]] || nov "Build stopped (exit ${rc}, ${kind}); not a source error, no verdict. Log: ${W}/build.log"
  ws_error "The build reports a source error at ${TAG} (exit ${rc})."
  results ftbfs "source error at ${TAG}"
  ws_write_yaml ftbfs "Coin Wallet ${VERSION} (${MODE}): upstream's CI build steps for ${DIST} failed at tag ${TAG}, commit ${COMMIT}, with a compiler or resource error." "${HASHES[@]}"
  exit 1
fi
OUT="${W}/src/phonegap/build/platforms/android/app/build/outputs"
if [[ "$MODE" == split ]]; then artifact="${OUT}/bundle/release/app-release.aab"; dest="${W}/built/app.aab"
else artifact="${OUT}/apk/release/app-release-unsigned.apk"; dest="${W}/built/app.apk"; fi
[[ -f "$artifact" ]] || nov "The build exited 0 but left no ${artifact#"${W}/"}."
cp "$artifact" "$dest"
ws_ok "Built: ${artifact#"${W}/"}"

ws_section "BUILD RECORD (ws-buildlock, verdict unaffected)"
BUILD_LOCK_FILE=""; BL_SH="${W}/tools/ws-buildlock.sh"; BL_DIR="${W}/build-lock"; bl_rc=0
if curl -fsSL --max-time 60 -o "$BL_SH" "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" < /dev/null \
   && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
  # shellcheck disable=SC2046
  ctr lock "${W}/build-lock.log" $(ws_user_flags) -v "${W}/gradle-home:/gradle-home:ro" -v "${W}/src:/src:ro" -v "${BL_DIR}:/build-lock" \
    -v "${BL_SH}:/ws-buildlock.sh:ro" -e HOME=/tmp "$IMG" bash /ws-buildlock.sh --out /build-lock --gradle-home /gradle-home \
    --src /src --app-id "$APP_ID" --version "$VERSION" --platform android --commit "$COMMIT" > /dev/null || bl_rc=$?
  if [[ "$bl_rc" -eq 0 && -s "${BL_DIR}/build-lock.json" ]] && ! grep -q 'nothing recorded' "${W}/build-lock.log"; then
    bl_n="$(grep -o '"ecosystem": *"gradle"' "${BL_DIR}/build-lock.json" | wc -l || true)"
    if [[ "${bl_n:-0}" -gt 0 ]]; then BUILD_LOCK_FILE="${BL_DIR}/build-lock.json"
      ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (${bl_n} Gradle artifacts, sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
    else ws_warn "build-lock.json lists no Gradle artifacts; not offered for upload."; fi
  else
    ws_warn "No build-lock.json (exit ${bl_rc}; see ${W}/build-lock.log)."
  fi
else
  ws_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256."
fi

# bx STAGE ARGS...: named container in the toolchain image; names are tracked here, before any $(...) call.
for c in btver render signer cmp; do ws_track_container "coinspace-${WS_RUN_ID}-${c}"; done
# shellcheck disable=SC2046
bx() { local n="coinspace-${WS_RUN_ID}-$1"; shift; ws_ctr run --rm --name "$n" $(ws_user_flags) -e HOME=/w/home -v "${W}:/w" -w /w "$IMG" "$@"; }

SIGNER="$(bx signer sh -c "apksigner verify --print-certs 'official/${OFFICIAL[0]##*|}' 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n1" || true)"

if [[ "$MODE" == split ]]; then
  ws_section "RENDER SPLITS"
  bt_ver="$(bx btver sh -c "unzip -p built/app.aab BundleConfig.pb | grep -a -o -m1 '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1" || true)"
  bt_sha="${BUNDLETOOL_SHA256[${bt_ver:-none}]:-}"
  [[ -n "$bt_sha" ]] || nov "AAB was made by bundletool '${bt_ver}', which is not pinned here; add its sha256."
  ws_fetch "https://github.com/google/bundletool/releases/download/${bt_ver}/bundletool-all-${bt_ver}.jar" "${W}/tools/bundletool.jar" "$bt_sha"
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
  ws_info "bundletool ${bt_ver} (from BundleConfig.pb); device spec: $(cat "${W}/device-spec.json")"
  [[ -n "$DEVICE_SDK" ]] || ws_warn "sdkVersion 36 assumed; pass --device-sdk for the phone's API level."
  bx render bash -c "set -euo pipefail
    java -Djava.locale.useOldISOCodes=true -jar tools/bundletool.jar build-apks --bundle=built/app.aab \
      --output=built/app.apks --device-spec=device-spec.json --mode=default --overwrite
    unzip -q -o built/app.apks -d built/apks
    for f in built/apks/splits/*.apk; do
      n=\${f##*/}; n=\${n%.apk}
      case \$n in base-master) cp \"\$f\" built/base.apk ;; base-*) cp \"\$f\" \"built/split_config.\${n#base-}.apk\" ;; esac
    done" || nov "bundletool could not render the splits."
fi

ws_section "COMPARE"
cat > "${W}/cmp.py" <<'EOF'
import hashlib, os, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET
mode, names = sys.argv[1], sys.argv[2:]
SIG = re.compile(r'META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))')
AN = '{http://schemas.android.com/apk/res/android}'
PLAY = {'com.android.stamp.source': lambda v: v == 'https://play.google.com/store',
        'com.android.stamp.type': lambda v: v == 'STAMP_TYPE_DISTRIBUTION_APK',
        'com.android.vending.derived.apk.id': lambda v: v.isdigit()}
def sha(b): return hashlib.sha256(b).hexdigest()
def fsha(p):
    with open(p, 'rb') as f: return sha(f.read())
def entries(p):
    z = zipfile.ZipFile(p)
    return {i.filename: (sha(z.read(i)), i.file_size) for i in z.infolist() if not i.is_dir()}
def decode(p, d):
    if not os.path.isdir(d):
        subprocess.run(['java', '-jar', '/opt/apktool.jar', 'd', '-f', '--no-src', '-o', d, p], check=True, capture_output=True)
    return d
def manifest(d, strip):
    root = ET.parse(d + '/AndroidManifest.xml').getroot()
    for parent in (list(root.iter()) if strip else []):
        for c in list(parent):
            n = c.get(AN + 'name')
            if c.tag == 'meta-data' and n in PLAY and PLAY[n](c.get(AN + 'value') or ''):
                parent.remove(c)
    return ET.canonicalize(ET.tostring(root, encoding='unicode'), strip_text=True)
def tree(d):
    return {os.path.relpath(os.path.join(r, f), d): fsha(os.path.join(r, f)) for r, _, fs in os.walk(d) for f in fs}
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
        elif mode == 'split' and k == 'stamp-cert-sha256' and k not in b and a[k][1] == 32:
            why = 'Play SourceStamp, 32 bytes, official only'
        elif k in a and k in b and k in ('AndroidManifest.xml', 'resources.arsc'):
            try:
                do, db = decode(off, f'cmp/dec_{lab}_off'), decode(bui, f'cmp/dec_{lab}_bui')
                if k == 'resources.arsc' and tree(do + '/res') == tree(db + '/res'):
                    why = 'binary-only; decoded res/ identical'
                elif k == 'AndroidManifest.xml' and mode == 'split' and manifest(do, True) == manifest(db, False):
                    why = 'Play distribution metadata only'
            except (subprocess.CalledProcessError, ET.ParseError, OSError):
                pass
        if why:
            acc.write(f'{lab}: {k} ({why})\n'); na += 1
        else:
            where = 'only in official' if k not in b else 'only in built' if k not in a else 'differs'
            cnt.write(f'{lab}: {k} {where}\n'); nc += 1
    print(f'{lab}|{nc}|{na}|{fsha(off)}|{fsha(bui)}')
EOF
names=()
for e in "${OFFICIAL[@]}"; do names+=("${e##*|}"); done
summary="$(bx cmp python3 cmp.py "$MODE" "${names[@]}")" || nov "Comparison failed."
while IFS='|' read -r lab nc na oh bh; do
  [[ -n "$lab" ]] || continue
  LABELS+=("$lab") NCOUNT+=("$nc") NACC+=("$na") OFF_HASH+=("$oh") BUILT_HASH+=("$bh")
  COUNTED=$((COUNTED + nc))
  ws_info "${lab}: ${nc} differing, ${na} accepted"
done <<< "$summary"
[[ "${#LABELS[@]}" -eq "${#OFFICIAL[@]}" ]] || nov "Comparison returned ${#LABELS[@]} result(s) for ${#OFFICIAL[@]} APK(s)."

ws_section "RESULT"
if [[ "$COUNTED" -eq 0 ]]; then verdict=reproducible; ws_ok "VERDICT: REPRODUCIBLE"
else verdict=not_reproducible; ws_warn "VERDICT: NOT REPRODUCIBLE (${COUNTED} differing entries)"; fi
n_acc="$(wc -l < "${W}/cmp/accepted.txt" || true)"
results "$verdict"
ws_write_yaml "$verdict" "Coin Wallet ${VERSION} (${MODE}, ${#LABELS[@]} APK(s)) vs tag ${TAG}, commit ${COMMIT}.
Build: upstream CI steps (${DIST}, CI secrets empty) in a pinned Ubuntu 22.04 image, Node ${NODE_VER}, Gradle ${GRADLE_VER}, unsigned ${PKG_TYPE}$([[ "$MODE" == split ]] && echo ", then bundletool ${bt_ver}").
Compared: every ZIP entry by SHA-256 of its content. Differing entries: ${COUNTED}. Accepted (WS #574): ${n_acc// /} (signing files, Play SourceStamp and manifest meta-data, decoded-identical res/)." "${HASHES[@]}"
[[ "$verdict" == reproducible ]] && exit 0
exit 1
