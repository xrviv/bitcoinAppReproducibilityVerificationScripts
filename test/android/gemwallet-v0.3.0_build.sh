#!/usr/bin/env bash
# gemwallet-v0.3.0_build.sh - Gem Wallet Android reproducible build verification
# Version:          v0.3.0
# Last modified by: Claude Opus 5.5 for Danny Garcia
# Last modified on: 2026-11-25
# Organization:     WalletScrutiny.com
# App ID:           com.gemwallet.android
# Project:          https://github.com/gemwalletcom/wallet
# Disclaimer: provided as-is, without warranty. Review before running. This is not a security audit.
# Steps: read the official APK(s) (Play split set or GitHub universal APK), clone the release tag,
#   build the tag's own android/reproducible toolchain image (linux/amd64) and run its entrypoint for
#   the matching channel (universal or google), compare every ZIP entry, write results.
#   Library ws-rb-core (#1023); build-lock.json from the Gradle cache (#1000) never changes the verdict.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or no library.

SCRIPT_NAME="gemwallet-v0.3.0_build.sh"
SCRIPT_VERSION="v0.3.0"
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

APP_ID="com.gemwallet.android"
REPO_URL="https://github.com/gemwalletcom/wallet.git"
API_URL="https://api.github.com/repos/gemwalletcom/wallet/releases/tags"
RELEASES_URL="https://github.com/gemwalletcom/wallet/releases/download"
# Probe and clone image (aapt/apksigner in build-tools 29.0.3, git), pinned by digest.
WS_IMG="docker.io/walletscrutiny/android@sha256:eabd60543f19831feef6db22e9a1ada0ef469eef723119f1c96bd836198614c3"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"
APKTOOL_SHA256="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"
UNIVERSAL_MARK="apk.gemwallet.com/gem_wallet_latest.apk"
PLATFORM="linux/amd64"   # upstream's docker.sh builds every channel as x86-64 Linux (since 2.114.103)
declare -A BUNDLETOOL_SHA256=(
  [1.18.1]=675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c
  [1.18.2]=378b5434cd1378bef6b2bc527b8c7f0ff2584b273830335bce54d6d0813c8584
  [1.18.3]=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29
)

VERSION="" ARCH="" BINARY="" DEVICE_SDK="" MODE="" TAG="" COMMIT="" SIGNER="" VNAME="" VCODE="" APP_HASH=""
COUNTED=0 BG_PID="" W="" HASHES=()
declare -a OFFICIAL=() LABELS=() NCOUNT=() NACC=() OFF_HASH=() BUILT_HASH=()

nov() { ws_no_verdict "$1"; }   # runtime, network, tool or input problem: no YAML
inv() { ws_invalid "$1"; }      # invalid parameters: exit 2, no YAML

ws_refuse_root
ws_install_traps

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--binary <apk|split dir>] [--version <v>] [--arch <abi>] [--type <t>]
  --binary, --apk  GitHub universal APK, Play base.apk, or a directory of Play split APKs
  --version        release version; read from the APK when omitted. Without --binary the
                   GitHub universal APK of this version is downloaded and checked against
                   the release's published sha256
  --arch           ABI of the split set (default: the ABI split present, else arm64-v8a)
  --type           accepted for ABS compatibility; unused
  --device-sdk     device API level for bundletool (default: 32)
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
CTR=(docker); [[ "$WS_ENGINE" != podman ]] || CTR=(podman --cgroup-manager=cgroupfs)

IMG="localhost/ws-gemwallet:${WS_RUN_ID}"; CMP_IMG="localhost/ws-gemwallet-cmp:${WS_RUN_ID}"

# Background + wait: a signal acts at once; the exit hook stops and reaps it.
bg_wait() { local rc=0; "$@" & BG_PID=$!; wait "$BG_PID" || rc=$?; BG_PID=""; return $rc; }
ws_cleanup_hook() { [[ -z "$BG_PID" ]] || { kill "$BG_PID"; wait "$BG_PID"; } 2>/dev/null || true; }
# ctr STAGE LOG IN ARGS...: run a named container (removed at exit), stdin from IN, output to the
# terminal and LOG; returns the container's exit code, or 90 if LOG was not written.
ctr() {
  local n="gemwallet-${WS_RUN_ID}-$1" l="$2" in="$3" rc=0; shift 3
  ws_track_container "$n"
  bg_wait bash -c 'l="$1"; i="$2"; shift 2; "$@" < "$i" 2>&1 | tee "$l"; s=("${PIPESTATUS[@]}"); [[ ${s[1]} == 0 ]] || exit 90; exit "${s[0]}"' \
    _ "$l" "$in" "${CTR[@]}" run --rm --name "$n" "$@" || rc=$?
  return $rc
}

read -r -d '' PROBE_SH <<'EOF' || true
A=/opt/android-sdk/build-tools/29.0.3
b="$($A/aapt dump badging "$1" 2>/dev/null | head -n1)"
g() { printf '%s\n' "$b" | sed -n "s/.* $1='\([^']*\)'.*/\1/p"; }
m="$($A/aapt dump xmltree "$1" AndroidManifest.xml 2>/dev/null | grep -c -E 'isSplitRequired|requiredSplitTypes|vending\.splits\.required')"
u="$(unzip -p "$1" 'classes*.dex' 2>/dev/null | grep -a -c "$2")"
s="$($A/apksigner verify --print-certs "$1" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
echo "$(g name)|$(g versionName)|$(g versionCode)|$(g split)|${m:-0}|${u:-0}|${s}|$(sha256sum "$1" | cut -d' ' -f1)"
EOF

probe() {
  local d out
  d="$(cd "$(dirname "$1")" && pwd -P)"
  out="$(ws_ctr run --rm -v "${d}:/a:ro" --entrypoint sh "$WS_IMG" -c "$PROBE_SH" sh "/a/$(basename "$1")" "$UNIVERSAL_MARK")" \
    || nov "Could not run the APK probe container (${WS_IMG})."
  printf '%s\n' "$out" | tail -n1
}

read_official() {
  local f pkg vn vc split marks univ signer hash base="" n=0 x
  local -a files=() codes=()
  if [[ -d "$BINARY" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$BINARY" -maxdepth 1 -type f -name '*.apk' | sort)
  else
    files=("$BINARY")
  fi
  [[ "${#files[@]}" -gt 0 ]] || inv "No APK found in ${BINARY}"
  for f in "${files[@]}"; do
    IFS='|' read -r pkg vn vc split marks univ signer hash < <(probe "$f") || true
    [[ -n "$pkg" ]] || nov "Could not read the manifest of $(basename "$f")."
    [[ "$pkg" == "$APP_ID" ]] || inv "Package mismatch: $(basename "$f") is ${pkg}, expected ${APP_ID}."
    if [[ -z "$split" ]]; then
      [[ -z "$base" ]] || inv "More than one base APK in ${BINARY}."
      base="$f" VNAME="$vn" VCODE="$vc" SIGNER="$signer" APP_HASH="$hash" n="$marks"
      if [[ "$marks" -eq 0 && "$univ" -gt 0 ]]; then OFFICIAL+=("${f}|universal.apk"); else OFFICIAL+=("${f}|base.apk"); fi
    else
      OFFICIAL+=("${f}|split_config.${split#config.}.apk"); codes+=("$(basename "$f")=${vc}")
    fi
  done
  for x in "${codes[@]}"; do
    [[ "${x##*=}" == "$VCODE" ]] || inv "Split ${x%%=*} has versionCode ${x##*=}, base.apk has ${VCODE}: not one release."
  done
  [[ -n "$base" ]] || inv "No base APK: a config split alone cannot be verified; pass the split directory."
  if [[ "${#files[@]}" -gt 1 || "$n" -gt 0 ]]; then
    MODE=split
  elif [[ "${OFFICIAL[0]}" == *"|universal.apk" ]]; then
    MODE=universal
  else
    inv "Not a Play split set or the GitHub universal APK (another store channel?)."
  fi
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
  [[ -n "$VNAME" ]] || nov "Could not read versionName from the base APK."
  [[ -z "$VERSION" || "$VERSION" == "$VNAME" ]] || inv "--version ${VERSION} does not match the APK (${VNAME})."
  VERSION="$VNAME"
  [[ "$MODE" != split ]] || check_arch
  [[ "$MODE" != universal || -z "$ARCH" ]] || ws_warn "--arch ignored: the universal APK holds every ABI."
  ws_info "Input: ${MODE} (${#OFFICIAL[@]} APK(s)), version ${VERSION} (${VCODE})"
else
  MODE=universal
fi
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || inv "Unsafe version string: ${VERSION}"
CHANNEL=universal; [[ "$MODE" == split ]] && CHANNEL=google

ws_workspace gemwallet "$VERSION"
W="$WS_WORKDIR"
GRADLE_HOME_DIR="${W}/gradle-home"; OUT_DIR="${W}/outputs"; BL_DIR="${W}/build-lock"
mkdir -p "${W}/official" "${W}/built" "${W}/cmp" "${W}/tools" "$GRADLE_HOME_DIR/caches" "$OUT_DIR" "$BL_DIR"

ws_info "Resolving tag for ${VERSION}..."
rc=0
tags="$(ws_ctr run --rm -e HOME=/tmp --entrypoint git "$WS_IMG" ls-remote --tags --exit-code "$REPO_URL" \
  "refs/tags/${VERSION}" "refs/tags/v${VERSION}")" || rc=$?
[[ "$rc" -ne 2 ]] || nov "No git tag ${VERSION} or v${VERSION} in ${REPO_URL}: no source to build."
[[ "$rc" -eq 0 ]] || nov "git ls-remote failed (rc ${rc}); network problem?"
TAG="$(printf '%s\n' "$tags" | sed -n 's#.*refs/tags/\([^^]*\)$#\1#p' | head -n1)"
[[ -n "$TAG" ]] || nov "Could not parse the tag from git ls-remote."
ws_info "Tag: ${TAG}"

if [[ -z "$BINARY" ]]; then
  asset="gem_wallet_universal_${VERSION}.apk"
  ws_info "Reading the published sha256 of ${asset} (GitHub release API)..."
  ws_fetch "${API_URL}/${TAG}" "${W}/release.json"
  want="$(tr -d ' \n' < "${W}/release.json" | sed 's/{"url":"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\//\n/g' \
    | grep -F "\"name\":\"${asset}\"" | grep -oE '"digest":"sha256:[0-9a-f]{64}"' | head -n1 | grep -oE '[0-9a-f]{64}' || true)"
  [[ -n "$want" ]] || nov "Release ${TAG} has no ${asset} with a published sha256."
  ws_info "Downloading ${asset} (published sha256 ${want})..."
  ws_fetch "${RELEASES_URL}/${TAG}/${asset}" "${W}/official/universal.apk" "$want"
  BINARY="${W}/official/universal.apk"
  IFS='|' read -r pkg VNAME VCODE _ _ univ SIGNER APP_HASH < <(probe "$BINARY") || true
  [[ "$pkg" == "$APP_ID" && "${univ:-0}" -gt 0 ]] || nov "Downloaded file is not the ${APP_ID} universal APK."
  [[ "$VNAME" == "$VERSION" ]] || nov "Downloaded APK is version ${VNAME}, expected ${VERSION}."
  OFFICIAL=("${BINARY}|universal.apk"); HASHES=("$APP_HASH")
fi
for e in "${OFFICIAL[@]}"; do
  [[ "${e%%|*}" -ef "${W}/official/${e##*|}" ]] || cp "${e%%|*}" "${W}/official/${e##*|}"
done

ws_section "SOURCE (clone in a container, git archive as upstream's docker.sh)"
# shellcheck disable=SC2046
ctr clone "${W}/clone.log" /dev/null $(ws_user_flags) -e HOME=/tmp -v "${W}:/w" -w /w --entrypoint sh "$WS_IMG" -c '
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
  git -c tar.umask=0022 archive --format=tar HEAD > ../src.tar || exit 11
  mkdir ../ctx
  git archive --format=tar HEAD android/reproducible android/gradlew android/gradle/wrapper rust-toolchain.toml \
    | tar -x -C ../ctx || exit 11
' sh "$TAG" "$REPO_URL" || nov "Clone or git archive of ${TAG} failed (see ${W}/clone.log)."
COMMIT="$(cat "${W}/commit.txt" 2>/dev/null || true)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || nov "Could not read the commit of ${TAG}."
NDK="$(sed -n 's/^androidNdk = "\(.*\)"$/\1/p' "${W}/src/android/gradle/libs.versions.toml" 2>/dev/null || true)"
RUST="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "${W}/src/rust-toolchain.toml" 2>/dev/null || true)"
[[ "$NDK" =~ ^[0-9.]+$ ]] || nov "androidNdk is missing from android/gradle/libs.versions.toml at ${TAG}."
DF="${W}/ctx/android/reproducible/Dockerfile"
[[ -f "$DF" && -x "${W}/ctx/android/reproducible/entrypoint.sh" ]] \
  || nov "Tag ${TAG} has no android/reproducible/Dockerfile and entrypoint.sh (recipe added later?)."
ws_ok "Commit ${COMMIT}; NDK ${NDK}; Rust ${RUST:-?}; channel ${CHANNEL}"

ws_section "TOOLCHAIN IMAGE (the tag's android/reproducible/Dockerfile, ${PLATFORM})"
# Podman 4.9 (buildah 1.33) rejects `ADD --checksum`. Each such line becomes a curl download of the
# same URL checked with sha256sum -c against the same pin; everything else is the tag's file as is.
n_add="$(grep -c '^ADD --checksum=sha256:' "$DF" || true)"
# Podman resolves an unqualified FROM through the host's short-name config: name Docker Hub, same digest.
sed -E -e 's#^ADD --checksum=sha256:([^ ]+) ([^ ]+) ([^ ]+)$#RUN curl -fsSL -o \3 "\2" \&\& echo "\1  \3" | sha256sum -c -#' \
  -e 's#^FROM ([a-z0-9][a-z0-9._-]*)([:@][^ /]*)( .*)?$#FROM docker.io/library/\1\2\3#' "$DF" > "${DF}.ws"
if grep -E '^FROM ' "${DF}.ws" | grep -vqE '^FROM [a-z0-9.-]+\.[a-z]+(:[0-9]+)?/'; then
  nov "The tag's Dockerfile has a FROM image without a registry that this script cannot qualify."
fi
n_run="$(grep -c '^RUN curl -fsSL -o .* | sha256sum -c -$' "${DF}.ws" || true)"
first_add="$(grep -n -m1 '^ADD ' "$DF" | cut -d: -f1 || true)"
curl_line="$(grep -n -m1 'apt-get install.* curl' "$DF" | cut -d: -f1 || true)"
if [[ "$n_add" != "$n_run" ]] || grep -q '^ADD ' "${DF}.ws" || [[ -n "$first_add" && ( -z "$curl_line" || "$first_add" -lt "$curl_line" ) ]]; then
  nov "The tag's Dockerfile has ADD lines this script cannot convert (${n_add} checksummed, ${n_run} converted)."
fi
ws_info "Converted ${n_add} ADD --checksum line(s) and qualified the FROM image(s):"
diff "$DF" "${DF}.ws" | grep '^>' | sed 's/^> /  /' || true
ws_track_image "$IMG"
bargs=(--platform "$PLATFORM" --build-arg "NDK_VERSION=${NDK}" -f "${DF}.ws" -t "$IMG")
if [[ "$WS_ENGINE" == podman ]]; then bargs=(--format docker --layers=false "${bargs[@]}"); else bargs=(--no-cache "${bargs[@]}"); fi
bg_wait "${CTR[@]}" build "${bargs[@]}" "${W}/ctx" || nov "Toolchain image build failed (network or registry?); see the output above."
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

ws_section "BUILD (upstream entrypoint, channel ${CHANNEL})"
rc=0
ctr build "${W}/build.log" "${W}/src.tar" --init -i --platform "$PLATFORM" \
  -v "${OUT_DIR}:/outputs" -v "${GRADLE_HOME_DIR}/caches:/root/.gradle/caches" "$IMG" "$CHANNEL" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  # 90: log not written; 126+: not run, killed or stopped. Only exit 1 (Gradle failed) is classified.
  [[ "$rc" -eq 1 ]] || nov "Build container exited ${rc} (log not written, not run or killed); no verdict. Log: ${W}/build.log"
  kind="$(ws_gradle_failure_kind "${W}/build.log")"
  if [[ "$kind" == source ]]; then
    ws_error "Gradle reports a source error at ${TAG} (exit ${rc})."
    FTBFS_NOTE="Gem Wallet ${VERSION} (${MODE}): upstream's android/reproducible build of channel ${CHANNEL} failed at tag ${TAG}, commit ${COMMIT}, with a compiler or resource error."
  else
    nov "Build stopped (exit ${rc}, ${kind}); not a source error, no verdict. Log: ${W}/build.log"
  fi
fi

if [[ -n "${FTBFS_NOTE:-}" ]]; then
  results ftbfs "Gradle source error at ${TAG}"
  ws_write_yaml ftbfs "$FTBFS_NOTE" "${HASHES[@]}"
  exit 1
fi

if [[ -z "${FTBFS_NOTE:-}" ]]; then
  if [[ "$CHANNEL" == universal ]]; then
    artifact="${OUT_DIR}/apk/universal/release/app-universal-release-unsigned.apk"
    [[ -f "$artifact" ]] || nov "The build exited 0 but left no ${artifact#"${W}/"}."
    cp "$artifact" "${W}/built/universal.apk"
  else
    artifact="${OUT_DIR}/bundle/googleRelease/app-google-release.aab"
    [[ -f "$artifact" ]] || nov "The build exited 0 but left no ${artifact#"${W}/"}."
    cp "$artifact" "${W}/built/app.aab"
  fi
  ws_ok "Built: ${artifact#"${W}/"}"

  ws_section "BUILD RECORD (ws-buildlock, verdict unaffected)"
  BUILD_LOCK_FILE=""; BL_SH="${W}/tools/ws-buildlock.sh"; bl_rc=0
  if curl -fsSL --max-time 60 -o "$BL_SH" "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" < /dev/null \
     && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
    ctr lock "${W}/build-lock.log" /dev/null -v "${GRADLE_HOME_DIR}:/gradle-home:ro" -v "${W}/src:/src:ro" -v "${BL_DIR}:/build-lock" \
      -v "${BL_SH}:/ws-buildlock.sh:ro" --entrypoint bash "$IMG" /ws-buildlock.sh --out /build-lock --gradle-home /gradle-home \
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
fi

ws_section "COMPARE IMAGE (toolchain image + python3 + apktool 3.0.3, pinned)"
ws_fetch "$APKTOOL_URL" "${W}/tools/apktool.jar" "$APKTOOL_SHA256"
cat > "${W}/tools/Containerfile" <<EOF
FROM ${IMG}
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 > /dev/null && rm -rf /var/lib/apt/lists/*
COPY apktool.jar /opt/apktool.jar
ENTRYPOINT []
EOF
ws_track_image "$CMP_IMG"
cargs=(--platform "$PLATFORM" -t "$CMP_IMG" -f "${W}/tools/Containerfile"); [[ "$WS_ENGINE" != podman ]] || cargs=(--format docker "${cargs[@]}")
bg_wait "${CTR[@]}" build "${cargs[@]}" "${W}/tools" || nov "Compare image build failed; see the output above."
# bx STAGE ARGS...: named container in the compare image; names are tracked here, before any $(...) call.
for c in btver render cmp; do ws_track_container "gemwallet-${WS_RUN_ID}-${c}"; done
bx() { local n="gemwallet-${WS_RUN_ID}-$1"; shift; ws_ctr run --rm --name "$n" --platform "$PLATFORM" -v "${W}:/workspace" -w /workspace "$CMP_IMG" "$@"; }


if [[ "$MODE" == split ]]; then
  ws_section "RENDER SPLITS"
  bt_ver="$(bx btver sh -c "unzip -p built/app.aab BundleConfig.pb | grep -a -o -m1 '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1" || true)"
  bt_sha="${BUNDLETOOL_SHA256[${bt_ver:-none}]:-}"
  [[ -n "$bt_sha" ]] || nov "AAB was made by bundletool '${bt_ver}', which is not pinned here; add its sha256."
  ws_fetch "https://github.com/google/bundletool/releases/download/${bt_ver}/bundletool-all-${bt_ver}.jar" "${W}/tools/bundletool.jar" "$bt_sha"
  locales="" density=480 sdk="${DEVICE_SDK:-32}"
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
  [[ -n "$DEVICE_SDK" ]] || ws_warn "sdkVersion 32 assumed; pass --device-sdk for the phone's API level."
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
ws_write_yaml "$verdict" "Gem Wallet ${VERSION} (${MODE}, ${#LABELS[@]} APK(s)) vs tag ${TAG}, commit ${COMMIT}.
Build: the tag's android/reproducible Dockerfile (${PLATFORM}; ADD --checksum lines run as curl + sha256sum -c) and entrypoint, channel ${CHANNEL}$([[ "$MODE" == split ]] && echo ", then bundletool ${bt_ver}").
Compared: every ZIP entry by SHA-256 of its content. Differing entries: ${COUNTED}. Accepted (WS #574): ${n_acc// /} (signing files, Play SourceStamp and manifest meta-data, decoded-identical res/)." "${HASHES[@]}"
[[ "$verdict" == reproducible ]] && exit 0
exit 1
