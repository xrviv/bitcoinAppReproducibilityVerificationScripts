#!/usr/bin/env bash
# airgapvault-v0.4.1_build.sh - AirGap Vault Android reproducible build verification
# Version:          v0.4.1
# Last modified by: Claude Opus 5.5 for Danny Garcia
# Last modified on: 2026-11-25
# Organization:     WalletScrutiny.com
# App ID:           it.airgap.vault
# Project:          https://github.com/airgap-it/airgap-vault
# Disclaimer: provided as-is, without warranty. Review before running. This is not a security audit.
# Steps: read the official APK (GitHub release or Google Play: both are one universal APK), clone
#   the release tag, build it with the tag's own
#   build/android/Dockerfile (base image pinned by digest), rebuild the airgap-sapling AAR from its
#   tag and compare it with the JitPack AAR the build used, compare every ZIP entry, write results.
#   Library ws-rb-core (#1023); build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Changelog: script-notes/android/it.airgap.vault/changelog.md
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library.

SCRIPT_NAME="airgapvault-v0.4.1_build.sh"
SCRIPT_VERSION="v0.4.1"
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
# A1: no host curl. Every download runs curl 8.17.0 in a digest-pinned container; this shell writes
# its stdout, so files belong to the caller. GITHUB_TOKEN goes to curl on stdin (GitHub only), never
# on a command line. Uses $WS_ENGINE once set, else podman, then docker.
CURL_IMG="docker.io/curlimages/curl@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"
ws_dl() {  # ws_dl URL OUT: 0 when downloaded
  local e h=""; local -a c
  [[ -n "${GITHUB_TOKEN:-}" && "$1" =~ ^https://(api\.)?github\.com/ ]] && h="Authorization: Bearer ${GITHUB_TOKEN}"
  for e in podman docker; do
    [[ -z "${WS_ENGINE:-}" || "$WS_ENGINE" == "$e" ]] && command -v "$e" >/dev/null 2>&1 || continue
    c=("$e"); [[ "$e" != podman ]] || c+=(--cgroup-manager=cgroupfs)
    if [[ -n "$h" ]]; then
      printf '%s\n' "$h" | "${c[@]}" run --rm -i --entrypoint curl "$CURL_IMG" -fsSL --retry 3 --max-time 1800 -H @- "$1" > "$2" && return 0
    else
      "${c[@]}" run --rm --entrypoint curl "$CURL_IMG" -fsSL --retry 3 --max-time 1800 "$1" < /dev/null > "$2" && return 0
    fi
  done
  return 1
}
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
      ws_dl "$u" "$f.$$" 2>/dev/null && ws_lib_ok "$f.$$" && mv -f "$f.$$" "$f"
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

# Upstream's build runs entirely inside `docker build`, which passes no host environment in;
# unset anyway so no step can take a CI-only path (none was found at v3.35.0).
unset CI GITHUB_ACTIONS

APP_ID="it.airgap.vault"
REPO_URL="https://github.com/airgap-it/airgap-vault.git"
SAPLING_URL="https://github.com/airgap-it/airgap-sapling.git"
API_URL="https://api.github.com/repos/airgap-it/airgap-vault/releases/tags"
# Probe and clone image (aapt/apksigner in build-tools 29.0.3, git), pinned by digest.
WS_IMG="docker.io/walletscrutiny/android@sha256:eabd60543f19831feef6db22e9a1ada0ef469eef723119f1c96bd836198614c3"
# The only base image upstream's Dockerfile may name, and its digest (single-arch amd64 manifest).
IONIC_FROM="beevelop/ionic:v2021.06.1"
IONIC_PIN="docker.io/beevelop/ionic@sha256:c43687a2f695a2e41b6210603e9c532c43a9f64d5b9fe86de9e0d21091d654d4"
# Sapling builder and comparison image: ubuntu 22.04 (index digest), SDK tools checked by sha256.
UBUNTU_PIN="docker.io/library/ubuntu@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb"
CT_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
CT_SHA256="2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"
PLATFORM="linux/amd64"

VERSION="" BINARY="" ARCH="" SRC="" N_SAP=0 TAG="" COMMIT="" SIGNER="" VNAME="" VCODE="" APP_HASH="" SV=""
COUNTED=0 BG_PID="" W="" HASHES=() SAP_VERDICT="not_run" SAP_NOTES="" SAP_COMMIT=""
declare -a LABELS=() NCOUNT=() OFF_HASH=() BUILT_HASH=()

nov() { ws_no_verdict "$1"; }   # runtime, network, tool or input problem: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML

ws_refuse_root
ws_install_traps

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--binary <apk|dir>] [--version <v>] [--arch <abi>] [--type <t>]
  --binary, --apk  the official APK: GitHub release (airgap-vault-<versionCode>.apk) or Google
                   Play (one universal APK), or a directory holding exactly one APK
  --version        release version; read from the APK when omitted. Without --binary the
                   GitHub release APK of this version is downloaded and checked against
                   the release's published sha256
  --arch           accepted for ABS compatibility; the APK is universal (all four ABIs)
  --type           accepted for ABS compatibility; unused
  --help
Exit codes: 0 reproducible, 1 not_reproducible/ftbfs/no verdict, 2 invalid parameters
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary|--apk) ws_require_value "$1" "${2:-}"; BINARY="$2"; shift 2 ;;
    --version)      ws_require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --arch)         ws_require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
    --type)         ws_require_value "$1" "${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              ws_unknown_arg "$1" "${2:-}"; shift "$WS_SHIFT" ;;
  esac
done

[[ -n "$BINARY" || -n "$VERSION" ]] || inv "--binary or --version is required."
[[ -z "$BINARY" || -e "$BINARY" ]] || inv "--binary not found: ${BINARY}"
[[ -z "$VERSION" || "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || inv "Unsafe version string: ${VERSION}"
case "$ARCH" in ""|universal|arm64-v8a|armeabi-v7a|x86_64|x86) ;; *) inv "Unsupported --arch: ${ARCH}" ;; esac
if [[ -d "$BINARY" ]]; then
  mapfile -t apks < <(find "$BINARY" -maxdepth 1 -type f -name '*.apk' | sort)
  [[ "${#apks[@]}" -eq 1 ]] || inv "${BINARY} holds ${#apks[@]} APKs; AirGap Vault ships one universal APK."
  BINARY="${apks[0]}"
fi
[[ -z "$BINARY" ]] || BINARY="$(realpath "$BINARY")"

ws_results_init
ws_engine
CTR=(docker); [[ "$WS_ENGINE" != podman ]] || CTR=(podman --cgroup-manager=cgroupfs)
# Docker hand-back chowns from inside an image this run already has: the pinned probe image,
# never one of the per-run images (those may not exist when a build fails).
WS_CHOWN_IMAGE="$WS_IMG"

IMG="localhost/ws-airgapvault:${WS_RUN_ID}"; TOOLS_IMG="localhost/ws-airgapvault-tools:${WS_RUN_ID}"

# fetch URL OUT [SHA256]: ws_fetch's contract (no verdict on failure or mismatch), curl in a container.
fetch() {
  local got
  ws_dl "$1" "$2.part.$$" || { rm -f "$2.part.$$"; nov "download failed: $1"; }
  mv -f "$2.part.$$" "$2"
  [[ -z "${3:-}" ]] || { got="$(ws_sha256 "$2")"; [[ "$got" == "$3" ]] || { rm -f "$2"; nov "sha256 mismatch for $1: expected $3, got $got"; }; }
}
# Background + wait: a signal acts at once; the exit hook stops and reaps it.
bg_wait() { local rc=0; "$@" & BG_PID=$!; wait "$BG_PID" || rc=$?; BG_PID=""; return $rc; }
ws_cleanup_hook() { [[ -z "$BG_PID" ]] || { kill "$BG_PID"; wait "$BG_PID"; } 2>/dev/null || true; }
# logged LOG IN CMD...: output to the terminal and LOG, stdin from IN; the command's exit code,
# or 90 if LOG was not written.
logged() {
  local l="$1" in="$2" rc=0; shift 2
  bg_wait bash -c 'l="$1"; i="$2"; shift 2; "$@" < "$i" 2>&1 | tee "$l"; s=("${PIPESTATUS[@]}"); [[ ${s[1]} == 0 ]] || exit 90; exit "${s[0]}"' \
    _ "$l" "$in" "$@" || rc=$?
  return $rc
}
# ctr STAGE LOG IN ARGS...: a named container (removed at exit) through logged.
ctr() {
  local n="airgapvault-${WS_RUN_ID}-$1" l="$2" in="$3"; shift 3
  ws_track_container "$n"
  logged "$l" "$in" "${CTR[@]}" run --rm --name "$n" "$@"
}
# failure_kind LOG: ws_gradle_failure_kind, plus TypeScript/Angular diagnostics as source
# errors and npm/yarn network errors as infrastructure.
failure_kind() {
  local k; k="$(ws_gradle_failure_kind "$1")"
  if [[ "$k" == unknown ]]; then
    if grep -qE 'ETIMEDOUT|ECONNRESET|ENOTFOUND|EAI_AGAIN|getaddrinfo|socket hang up|network connection' "$1" 2>/dev/null; then k="infra: npm/yarn network error"
    elif grep -qE 'error TS[0-9]+:|^Error: src/.*\.ts:[0-9]+' "$1" 2>/dev/null; then k=source; fi
  fi
  echo "$k"
}

read -r -d '' PROBE_SH <<'EOF' || true
A=/opt/android-sdk/build-tools/29.0.3
b="$($A/aapt dump badging "$1" 2>/dev/null | head -n1)"
g() { printf '%s\n' "$b" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
p="$(unzip -Z1 "$1" 2>/dev/null | grep -c -E '^stamp-cert-sha256$|^META-INF/GOOGPLAY\.')"
p=$((p + $($A/aapt dump xmltree "$1" AndroidManifest.xml 2>/dev/null | grep -c -E 'isSplitRequired|vending\.derived\.apk\.id')))
l="$(unzip -Z1 "$1" 2>/dev/null | grep -c '/libsapling\.so$')"
s="$($A/apksigner verify --print-certs "$1" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
echo "$(g name)|$(g versionName)|$(g versionCode)|$(g split)|${p}|${l}|${s}|$(sha256sum "$1" | cut -d' ' -f1)"
EOF

probe() {
  local d out
  d="$(cd "$(dirname "$1")" && pwd -P)"
  out="$(ws_ctr run --rm -v "${d}:/a:ro" --entrypoint sh "$WS_IMG" -c "$PROBE_SH" sh "/a/$(basename "$1")")" \
    || nov "Could not run the APK probe container (${WS_IMG})."
  printf '%s\n' "$out" | tail -n1
}

# read_apk FILE: sets VNAME VCODE SIGNER APP_HASH N_SAP SRC; refuses config splits.
read_apk() {
  local pkg split play
  IFS='|' read -r pkg VNAME VCODE split play N_SAP SIGNER APP_HASH < <(probe "$1") || true
  [[ -n "$pkg" ]] || nov "Could not read the manifest of $(basename "$1")."
  [[ "$pkg" == "$APP_ID" ]] || inv "Package mismatch: $(basename "$1") is ${pkg}, expected ${APP_ID}."
  [[ -z "$split" ]] || inv "$(basename "$1") is a config split; AirGap ships one universal APK on GitHub and Google Play."
  # GitHub and Play ship the same universal APK build; Play may add its stamp and manifest labels,
  # which cmp.py sets aside (WS #574). Without those marks the two channels look alike.
  if [[ "${play:-0}" -gt 0 ]]; then SRC="Google Play APK"; else SRC="${SRC:-official APK (GitHub release or Google Play)}"; fi
  [[ "$VCODE" =~ ^[0-9]+$ ]] || nov "Could not read versionCode (BUILD_NR) from $(basename "$1")."
  [[ "$VNAME" =~ ^[0-9A-Za-z._-]+$ ]] || nov "Could not read a usable versionName from $(basename "$1")."
}

ws_section "PREPARATION"
if [[ -n "$BINARY" ]]; then
  read_apk "$BINARY"
  [[ -z "$VERSION" || "$VERSION" == "$VNAME" ]] || inv "--version ${VERSION} does not match the APK (${VNAME})."
  VERSION="$VNAME"
fi
[[ -z "$ARCH" || "$ARCH" == universal ]] || ws_warn "--arch ${ARCH} ignored: the APK holds every ABI."
ws_info "Version ${VERSION}${VCODE:+ (${VCODE})}"

ws_workspace airgapvault "$VERSION"
W="$WS_WORKDIR"
BL_DIR="${W}/build-lock"; SAP="${W}/sapling"
mkdir -p "${W}/official" "${W}/built" "${W}/cmp" "${W}/tools" "$BL_DIR" "$SAP"

TAG="v${VERSION}"
if [[ -z "$BINARY" ]]; then
  ws_info "Reading the published sha256 of the release APK (GitHub release API)..."
  fetch "${API_URL}/${TAG}" "${W}/release.json"
  rel="$(tr -d ' \n' < "${W}/release.json" | sed 's/{"url":"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\//\n/g' \
    | grep -E '"name":"airgap-vault-[0-9]+\.apk"' || true)"
  [[ "$(printf '%s' "$rel" | grep -c . || true)" -eq 1 ]] || nov "Release ${TAG} has no single airgap-vault-<versionCode>.apk asset."
  asset="$(printf '%s' "$rel" | grep -oE '"name":"airgap-vault-[0-9]+\.apk"' | cut -d'"' -f4)"
  want="$(printf '%s' "$rel" | grep -oE '"digest":"sha256:[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' || true)"
  url="$(printf '%s' "$rel" | grep -oE '"browser_download_url":"https://github\.com/[^"]+\.apk"' | cut -d'"' -f4)"
  [[ -n "$want" && -n "$url" ]] || nov "Release ${TAG} publishes no sha256 for ${asset}."
  ws_info "Downloading ${asset} (published sha256 ${want})..."
  fetch "$url" "${W}/official/${asset}" "$want"
  BINARY="${W}/official/${asset}"
  read_apk "$BINARY"
  [[ "$VNAME" == "$VERSION" ]] || nov "Downloaded APK is version ${VNAME}, expected ${VERSION}."
  HASHES=("$APP_HASH") SRC="GitHub release APK"
fi
[[ "$BINARY" -ef "${W}/official/app.apk" ]] || cp "$BINARY" "${W}/official/app.apk"
ws_ok "Official APK: ${APP_HASH}, versionCode ${VCODE}, signer ${SIGNER:-unknown}"

ws_section "SOURCE (clone in a container)"
# shellcheck disable=SC2046
ctr clone "${W}/clone.log" /dev/null $(ws_user_flags) -e HOME=/tmp -v "${W}:/w" -w /w --entrypoint sh "$WS_IMG" -c '
  set -eu
  git ls-remote --exit-code --tags "$2" "refs/tags/$1" >/dev/null || exit 20
  git clone --quiet --depth 1 --branch "$1" "$2" src || exit 10
  cd src
  git rev-parse HEAD > ../commit.txt
  t="$(git cat-file -t "refs/tags/$1" 2>/dev/null || echo missing)"
  {
    echo "Tag $1 ($t object) at commit $(git rev-parse HEAD)."
    if [ "$t" = tag ]; then git tag -v "$1" 2>&1 | tail -n2 || true; fi
    git verify-commit HEAD >/dev/null 2>&1 && echo "Commit signature: valid." || echo "Commit signature: not verified."
  } > ../tag.txt
' sh "$TAG" "$REPO_URL" || nov "No tag ${TAG}, or the clone failed (see ${W}/clone.log)."
COMMIT="$(cat "${W}/commit.txt" 2>/dev/null || true)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || nov "Could not read the commit of ${TAG}."
G="${W}/src/android/app/build.gradle"; DF="${W}/src/build/android/Dockerfile"
[[ -f "$G" && -f "$DF" ]] || nov "Tag ${TAG} has no android/app/build.gradle or build/android/Dockerfile."
# As AirGap's CI: versionName is "0.0.0" in the source and set from the tag before the build.
grep -q 'versionName "0.0.0"' "$G" || nov "build.gradle at ${TAG} has no versionName \"0.0.0\" to set."
sed -i "s/versionName \"0.0.0\"/versionName \"${VERSION}\"/" "$G"
SV="$(sed -n 's/^ *def saplingVersion = "\([0-9.]*\)".*/\1/p' "$G" | head -n1)"
if [[ -z "$SV" && "${N_SAP:-0}" -gt 0 ]]; then
  nov "The APK ships libsapling.so but build.gradle at ${TAG} names no saplingVersion."
fi
ws_ok "Commit ${COMMIT}; airgap-sapling ${SV:-not used}"

ws_section "BUILD IMAGE (the tag's build/android/Dockerfile, BUILD_NR=${VCODE})"
# Two changes to the tag's file, both shown: FROM pinned by digest (same image), and the base
# image's Gradle module cache emptied (its maintainer's sample builds filled it), so
# build-lock.json lists only what this build fetched.
[[ "$(grep -c '^FROM ' "$DF" || true)" -eq 1 ]] && grep -qxE "FROM ${IONIC_FROM//./\\.} *" "$DF" \
  || nov "The tag's Dockerfile does not use ${IONIC_FROM} (the only base image pinned here); add its digest."
sed -E "s#^FROM ${IONIC_FROM//./\\.} *\$#FROM ${IONIC_PIN}\nRUN rm -rf /root/.gradle/caches/modules-2#" "$DF" > "${W}/Dockerfile.ws"
diff "$DF" "${W}/Dockerfile.ws" | sed -n 's/^> /  + /p' || true
ws_track_image "$IMG"
bargs=(--platform "$PLATFORM" --ulimit nofile=10000:10000 --build-arg "BUILD_NR=${VCODE}" -f "${W}/Dockerfile.ws" -t "$IMG")
if [[ "$WS_ENGINE" == podman ]]; then bargs=(--format docker --layers=false "${bargs[@]}"); else bargs=(--no-cache "${bargs[@]}"); fi
rc=0
logged "${W}/build.log" /dev/null "${CTR[@]}" build "${bargs[@]}" "${W}/src" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  [[ "$rc" -ne 90 && "$rc" -lt 128 ]] || nov "Image build exited ${rc} (log not written, killed or stopped); no verdict."
  kind="$(failure_kind "${W}/build.log")"
  [[ "$kind" == source ]] || nov "Image build failed (exit ${rc}, ${kind}); not a source error, no verdict. Log: ${W}/build.log"
  ws_error "The build reports a source error at ${TAG}."
  ftbfs_note="AirGap Vault ${VERSION}: the tag's build/android/Dockerfile failed at ${TAG}, commit ${COMMIT}, with a compiler or resource error."
fi

results() {
  local i d=""
  if [[ "$1" == ftbfs ]]; then
    d="(no build to compare: $2)"$'\n'
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
  echo "saplingVerdict: ${SAP_VERDICT}"
  echo "saplingNotes:   ${SAP_NOTES:-none}"
  echo ""
  echo "appHash is the ${SRC:-official APK} as provided (publish this one); the hashes below are labelled."
  for i in "${!LABELS[@]}"; do
    echo "  ${LABELS[$i]}: official ${OFF_HASH[$i]}"
    echo "  ${LABELS[$i]}: built    ${BUILT_HASH[$i]}"
  done
  echo "Not rebuilt from source here (prebuilt in the inputs): ${W}/cmp/prebuilt.txt"
  [[ -z "${BUILD_LOCK_FILE:-}" ]] || echo "build-lock.json (attach as output file): ${BUILD_LOCK_FILE}"
  echo "Workspace: ${W}"
}

# Prebuilt binaries in the APK's inputs that have public source but are not rebuilt here.
cat > "${W}/cmp/prebuilt.txt" <<EOF
lib/*/libsapling.so: links airgap-sapling ${SV:-?}'s committed Rust static libraries (packages/sapling-android/app/src/main/cpp/libs/*/libsapling_ffi.a; no Cargo.lock or rustc version at the tag), so only the JNI wrapper is rebuilt
lib/*/libsqlc-ndk-native-driver.so: prebuilt jars in the npm package cordova-sqlite-storage-dependencies (source: github.com/brodybits/android-sqlite-ndk-native-driver)
lib/*/libtool-checker.so: prebuilt in the Maven Central AAR com.scottyab:rootbeer-lib (source: github.com/scottyab/rootbeer)
assets/public/**/*.js: npm packages as published (dist code, e.g. @airgap-community/iso-rootstock) and the committed src/assets/workers/sha3.min.js
other Gradle/Maven artifacts: as downloaded (listed in build-lock.json)
EOF

if [[ -n "${ftbfs_note:-}" ]]; then
  results ftbfs "source error at ${TAG}"
  ws_write_yaml ftbfs "$ftbfs_note" "${HASHES[@]}"
  exit 1
fi
ws_ok "Image ${IMG} built (per-run, removed at exit)."

ws_section "EXTRACT (APK and the JitPack sapling AAR from the build image)"
XN="airgapvault-${WS_RUN_ID}-extract"; ws_track_container "$XN"
ws_ctr create --name "$XN" "$IMG" true >/dev/null || nov "Could not create a container from ${IMG}."
ws_ctr cp "${XN}:/app/android-release-unsigned.apk" "${W}/built/app.apk" || nov "The image has no /app/android-release-unsigned.apk."
if [[ -n "$SV" ]]; then
  # --user 0: the image ends with USER nobody, which cannot read /root/.gradle.
  aar="$(ws_ctr run --rm --user 0 --entrypoint find "$IMG" "/root/.gradle/caches/modules-2/files-2.1/com.github.airgap-it/airgap-sapling/${SV}" \
    -name '*.aar' -type f 2>/dev/null || true)"
  [[ "$(printf '%s' "$aar" | grep -c . || true)" -eq 1 ]] || nov "Expected one airgap-sapling ${SV} AAR in the build's Gradle cache, found: ${aar:-none}."
  ws_ctr cp "${XN}:${aar}" "${SAP}/jitpack.aar" || nov "Could not copy ${aar} out of ${IMG}."
  ws_info "JitPack AAR the build used: ${aar##*/} sha256 $(ws_sha256 "${SAP}/jitpack.aar")"
fi
ws_ok "Built APK: $(ws_sha256 "${W}/built/app.apk")"

ws_section "BUILD RECORD (ws-buildlock, verdict unaffected)"
BUILD_LOCK_FILE=""; BL_SH="${W}/tools/ws-buildlock.sh"; bl_rc=0
if ws_dl "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" "$BL_SH" \
   && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
  ctr lock "${W}/build-lock.log" /dev/null --user 0 -v "${BL_DIR}:/build-lock" -v "${BL_SH}:/ws-buildlock.sh:ro" \
    --entrypoint bash "$IMG" /ws-buildlock.sh --out /build-lock --gradle-home /root/.gradle --src /app \
    --app-id "$APP_ID" --version "$VERSION" --platform android --commit "$COMMIT" > /dev/null || bl_rc=$?
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

ws_section "TOOLS IMAGE (ubuntu 22.04 by digest, cmdline-tools and apktool 3.0.3 by sha256; sapling build and comparison)"
fetch "$APKTOOL_URL" "${W}/tools/apktool.jar" "$APKTOOL_SHA256"
cat > "${W}/tools/Containerfile" <<EOF
FROM ${UBUNTU_PIN}
ENV DEBIAN_FRONTEND=noninteractive ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk
RUN apt-get update && apt-get install -y ca-certificates curl git unzip zip openjdk-11-jdk openjdk-17-jdk binutils python3 && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/android-sdk/cmdline-tools && curl -fsSL -o /tmp/ct.zip "${CT_URL}" && echo "${CT_SHA256}  /tmp/ct.zip" | sha256sum -c - \\
 && unzip -q /tmp/ct.zip -d /opt/android-sdk/cmdline-tools && mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest && rm -f /tmp/ct.zip
ENV PATH=/opt/android-sdk/cmdline-tools/latest/bin:\${PATH}
# sdkmanager checks each package against the checksum in Google's repository index.
RUN yes | sdkmanager --licenses > /dev/null && sdkmanager "platform-tools" "platforms;android-29" "build-tools;29.0.3" "ndk;21.1.6352462" "cmake;3.10.2.4988404"
COPY apktool.jar /opt/apktool.jar
EOF
ws_track_image "$TOOLS_IMG"
targs=(--platform "$PLATFORM" -t "$TOOLS_IMG" -f "${W}/tools/Containerfile"); [[ "$WS_ENGINE" != podman ]] || targs=(--format docker --layers=false "${targs[@]}")
bg_wait "${CTR[@]}" build "${targs[@]}" "${W}/tools" || nov "Tools image build failed (network or registry?); see the output above."

if [[ -n "$SV" ]]; then
  ws_section "SAPLING (airgap-sapling ${SV} from its tag, compared with the JitPack AAR)"
  rc=0
  ctr sapling "${SAP}/build.log" /dev/null --platform "$PLATFORM" -e HOME=/w/home -v "${SAP}:/w" -w /w --entrypoint bash "$TOOLS_IMG" -c '
    set -eu
    git clone --quiet --depth 1 --branch "$1" "$2" src || exit 10
    git -C src rev-parse HEAD > commit.txt
    (cd src/packages/sapling-android/app/src/main/cpp/libs && sha256sum */*.a) > committed-a.txt || true
    cd src/packages/sapling-android
    chmod +x gradlew
    # Java takes user.home from the passwd entry (/root), not $HOME: name the Maven repo explicitly.
    JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64 ./gradlew --no-daemon -Dmaven.repo.local=/w/home/.m2/repository publishToMavenLocal
    a="$(find /w/home/.m2/repository -type f -name "*-$1.aar")"
    [ -n "$a" ] && [ "$(printf "%s\n" "$a" | wc -l)" -eq 1 ] || { echo "published AAR(s) for $1: ${a:-none}"; exit 30; }
    echo "Published AAR: ${a#/w/home/.m2/repository/}"
    cp "$a" /w/built.aar
  ' sh "$SV" "$SAPLING_URL" || rc=$?
  SAP_COMMIT="$(cat "${SAP}/commit.txt" 2>/dev/null || true)"
  [[ "$rc" -ne 30 ]] || nov "airgap-sapling ${SV} built, but not exactly one published AAR was found (a script problem): no verdict. Log: ${SAP}/build.log"
  # The app itself built: a failed rebuild of its dependency gives no verdict for the app (Danny, 2026-11-25).
  if [[ "$rc" -ne 0 ]]; then
    nov "airgap-sapling ${SV} (commit ${SAP_COMMIT:-?}) did not build from its tag (exit ${rc}, $(failure_kind "${SAP}/build.log")). The app built, but its sapling AAR cannot be checked: no verdict. Log: ${SAP}/build.log"
  fi
  [[ -s "${SAP}/built.aar" ]] || nov "The sapling build exited 0 but left no AAR."
  ws_info "Committed Rust static libraries (prebuilt, not rebuilt):"; sed 's/^/  /' "${SAP}/committed-a.txt"
fi

ws_section "COMPARE"
cat > "${W}/cmp.py" <<'EOF'
import hashlib, io, os, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET
AN = '{http://schemas.android.com/apk/res/android}'
PLAY = {'com.android.stamp.source': lambda v: v == 'https://play.google.com/store',
        'com.android.stamp.type': lambda v: v == 'STAMP_TYPE_DISTRIBUTION_APK',
        'com.android.vending.derived.apk.id': lambda v: v.isdigit()}
SIG = re.compile(r'META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))')
# librustzcash zcash_proofs SAPLING_SPEND_HASH / SAPLING_OUTPUT_HASH (BLAKE2b-512)
PARAMS = {'assets/public/assets/sapling/sapling-spend.params': '8270785a1a0d0bc77196f000ee6d221c9c9894f55307bd9357c3f0105d31ca63991ab91324160d8f53e2bbd3c2633a6eb8bdf5205d822e7f3f73edac51b2b70c',
          'assets/public/assets/sapling/sapling-output.params': '657e3d38dbb5cb5e7dd2970e8b03d69b4787dd907285b5a7f0790dcc8072f60bf593b32cc2d1c030e00ff5ae64bf84c5c3beb84ddc841d48264b4a171744d028'}
def sha(b): return hashlib.sha256(b).hexdigest()
def fsha(p):
    with open(p, 'rb') as f: return sha(f.read())
def entries(z): return {i.filename: z.read(i) for i in z.infolist() if not i.is_dir()}
def decode(apk, d):
    if not os.path.isdir(d):
        subprocess.run(['java', '-jar', '/opt/apktool.jar', 'd', '-f', '--no-src', '-o', d, apk], check=True, capture_output=True)
    return d
def res_tree(d):
    return {os.path.relpath(os.path.join(r, f), d): fsha(os.path.join(r, f)) for r, _, fs in os.walk(d + '/res') for f in fs}
def manifest(d, strip):  # canonical XML, and how many Play labels were removed (official side only)
    root, n = ET.parse(d + '/AndroidManifest.xml').getroot(), 0
    for parent in (list(root.iter()) if strip else []):
        for c in list(parent):
            k = c.get(AN + 'name')
            if c.tag == 'meta-data' and k in PLAY and PLAY[k](c.get(AN + 'value') or ''):
                parent.remove(c); n += 1
    return ET.canonicalize(ET.tostring(root, encoding='unicode'), strip_text=True), n
def decoded_same(off, bui, k):
    try:
        do, db = decode(off, 'cmp/dec_off'), decode(bui, 'cmp/dec_bui')
        if k == 'resources.arsc': return res_tree(do) == res_tree(db)
        (mo, n), (mb, _) = manifest(do, True), manifest(db, False)
        return n > 0 and mo == mb
    except (subprocess.CalledProcessError, ET.ParseError, OSError): return False
def elf(b, tag):
    p = f'cmp/{tag}.so'
    open(p, 'wb').write(b)
    n = subprocess.run(['readelf', '-n', p], capture_output=True, text=True).stdout
    c = subprocess.run(['readelf', '-p', '.comment', p], capture_output=True, text=True).stdout
    bid = re.findall(r'Build ID: (\w+)', n)
    return (bid[0] if bid else 'none') + ' / ' + ' '.join(re.findall(r'\]\s+(.+)', c))[:300]
cnt, acc, diag = open('cmp/counted.txt', 'w'), open('cmp/accepted.txt', 'w'), open('cmp/sapling-diag.txt', 'w')
def compare(lab, off, bui, apk, prefix=''):
    a, b = entries(zipfile.ZipFile(off)), entries(zipfile.ZipFile(bui))
    nc = 0
    for k in sorted(set(a) | set(b)):
        if k in a and k in b and a[k] == b[k]: continue
        name = prefix + k
        if apk and not prefix and k not in b and SIG.fullmatch(k):
            acc.write(f'{lab}: {name} (signature file, official only)\n'); continue
        if apk and not prefix and k == 'stamp-cert-sha256' and k not in b and len(a[k]) == 32:
            acc.write(f'{lab}: {name} (Google Play SourceStamp, 32 bytes, official only)\n'); continue
        if apk and not prefix and k == 'resources.arsc' and k in a and k in b and decoded_same(off, bui, k):
            acc.write(f'{lab}: {name} (binary-only; apktool-decoded res/ identical)\n'); continue
        if apk and not prefix and k == 'AndroidManifest.xml' and k in a and k in b and decoded_same(off, bui, k):
            acc.write(f'{lab}: {name} (Google Play labels only: stamp.source, stamp.type, derived.apk.id)\n'); continue
        if not apk and k in a and k in b and k.endswith('.jar'):
            n = compare(lab, io.BytesIO(a[k]), io.BytesIO(b[k]), False, name + '!/')
            if n == 0: acc.write(f'{lab}: {name} (zip container bytes only; every inner entry identical)\n')
            nc += n; continue
        where = 'only in official' if k not in b else 'only in built' if k not in a else 'differs'
        cnt.write(f'{lab}: {name} {where}\n'); nc += 1
        if not apk and k.endswith('.so') and k in a and k in b:
            diag.write(f'{k}\n  jitpack: {elf(a[k], "j")}\n  built:   {elf(b[k], "b")}\n')
    return nc
apk = zipfile.ZipFile('official/app.apk')
names = set(apk.namelist())
nc = compare('apk', 'official/app.apk', 'built/app.apk', True)
for k, want in PARAMS.items():
    if k in names and hashlib.blake2b(apk.read(k)).hexdigest() != want:
        cnt.write(f'apk: {k} is not the Zcash parameter file (BLAKE2b differs from librustzcash)\n'); nc += 1
print(f'apk|{nc}|{fsha("official/app.apk")}|{fsha("built/app.apk")}')
if len(sys.argv) > 1:
    n = compare('sapling AAR', 'sapling/jitpack.aar', 'sapling/built.aar', False)
    print(f'sapling AAR|{n}|{fsha("sapling/jitpack.aar")}|{fsha("sapling/built.aar")}')
EOF
ws_track_container "airgapvault-${WS_RUN_ID}-cmp"
summary="$(ws_ctr run --rm --name "airgapvault-${WS_RUN_ID}-cmp" --platform "$PLATFORM" -v "${W}:/w" -w /w --entrypoint python3 "$TOOLS_IMG" cmp.py ${SV:+sapling})" \
  || nov "Comparison failed."
while IFS='|' read -r lab nc oh bh; do
  [[ -n "$lab" ]] || continue
  LABELS+=("$lab") NCOUNT+=("$nc") OFF_HASH+=("$oh") BUILT_HASH+=("$bh")
  COUNTED=$((COUNTED + nc))
  ws_info "${lab}: ${nc} differing"
done <<< "$summary"
[[ "${#LABELS[@]}" -eq "$([[ -n "$SV" ]] && echo 2 || echo 1)" ]] || nov "Comparison returned ${#LABELS[@]} result(s)."
if [[ -n "$SV" ]]; then
  n="${NCOUNT[1]}"
  if [[ "$n" -eq 0 ]]; then SAP_VERDICT=reproducible SAP_NOTES="airgap-sapling ${SV} (${SAP_COMMIT}): every AAR entry identical, .so files unmodified"
  else SAP_VERDICT=not_reproducible SAP_NOTES="airgap-sapling ${SV} (${SAP_COMMIT}): ${n} AAR entries differ (counted); ELF notes: ${W}/cmp/sapling-diag.txt"; fi
  ws_info "Sapling: ${SAP_VERDICT}"; ws_diff_preview "${W}/cmp/sapling-diag.txt"
else
  SAP_NOTES="build.gradle names no airgap-sapling and the APK ships no libsapling.so"
fi

ws_section "RESULT"
if [[ "$COUNTED" -eq 0 ]]; then verdict=reproducible; ws_ok "VERDICT: REPRODUCIBLE"
else verdict=not_reproducible; ws_warn "VERDICT: NOT REPRODUCIBLE (${COUNTED} differing entries)"; fi
n_acc="$(wc -l < "${W}/cmp/accepted.txt" || true)"
results "$verdict"
ws_write_yaml "$verdict" "AirGap Vault ${VERSION} (${VCODE}) ${SRC} vs tag ${TAG}, commit ${COMMIT}.
Build: the tag's build/android/Dockerfile, BUILD_NR=${VCODE}, versionName set from the tag as AirGap's CI does; FROM pinned to ${IONIC_PIN#docker.io/}, base Gradle module cache emptied first.
Compared: every ZIP entry by SHA-256 of its content. Differing entries: ${COUNTED} (APK ${NCOUNT[0]}$([[ -n "$SV" ]] && echo ", sapling AAR ${NCOUNT[1]}")). Accepted (WS #574): ${n_acc// /} (root META-INF signing files, official only; Google Play SourceStamp and manifest labels; resources.arsc when the apktool-decoded res/ trees match$([[ -n "$SV" ]] && echo "; nested jars whose every entry matches")).
Sapling: ${SAP_VERDICT}; ${SAP_NOTES}. Zcash Sapling params checked against librustzcash's BLAKE2b hashes.
Not rebuilt (prebuilt with public source): sapling's committed Rust .a libraries, libsqlc-ndk-native-driver.so (npm), libtool-checker.so (rootbeer-lib AAR), npm dist JS, other Maven artifacts." "${HASHES[@]}"
[[ "$verdict" == reproducible ]] && exit 0
exit 1
