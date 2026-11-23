#!/bin/bash
# envoy-v0.5.1_build.sh — Envoy (com.foundationdevices.envoy) Android reproducible build verification
# Version:          v0.5.1
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-23
# Organization:     WalletScrutiny.com
# Project:          https://github.com/Foundation-Devices/envoy
# DISCLAIMER: for reproducible build verification only, without warranty; users assume all risks.
# SCOPE: Google Play split set (directory or its base.apk) or GitHub universal APK (--binary, or downloaded with
# --version alone); the kind comes from the manifest. Upstream's reproducible-builds/build.sh (v2.3.4+) runs in upstream's container at its /tmp paths,
# mounted from canonical/ and cache/ (embedded OpenSSL and Dart paths depend on them).
# STEPS: args -> metadata -> tag -> clone -> image -> build.sh -> build-lock -> bundletool -> per-APK diff with
#        earned exclusions -> verdict -> YAML -> prune unless ftbfs. Library ws-rb-core (#1023) pinned below
#        (offline: WS_LIB_FILE); ws-buildlock.sh (#1000) writes <workspace>/build-lock/build-lock.json.
# Exit: 0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input or library unavailable.

set -euo pipefail

EXEC_DIR="$(pwd -P)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.5.1"
readonly SCRIPT_NAME="envoy-v0.5.1_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1)" || true
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"


# ---- WalletScrutiny library (GitLab #1023), pinned by sha256 ------------------
# Goes in each build script right after its self-hash line, before anything else.
# Source: WS_LIB_FILE (offline, must match), else the cache, else GitLab by
# commit. Nothing else. A wrong hash is rejected whichever source sent it.
# No matching copy, or a different version inside: no verdict, no YAML, exit 2.
# First, before anything can fail: no earlier verdict may survive this run. A run
# that holds this folder's lock is still writing its own; that one stays, and the
# library refuses this run when it takes the lock.
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
    # Cache in XDG_CACHE_HOME or HOME; with neither, or no way to create it, a
    # temporary folder for this run only. Every copy is hash-checked either way.
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
  # 1.1.0 and later mount this file into the build container (WS_LIB_PATH)
  # and remove a temporary folder on exit; for 1.0.0 it goes now.
  WS_LIB_PATH="$f" WS_LIB_TMP="$t"
  . "$f"
  [ -z "$t" ] || [ -n "${WS_LIB_MOUNT:-}" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load

readonly APP_ID="com.foundationdevices.envoy"
readonly REPO_URL="https://github.com/Foundation-Devices/envoy.git"
readonly REL_URL="https://github.com/Foundation-Devices/envoy/releases/download"
# Base image of upstream's Dockerfile (checked after the clone).
readonly BASE_IMG="docker.io/nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c"

readonly NIXPKGS="github:NixOS/nixpkgs/4fd0f759fbe88b1a57902871cf4ba4a2e4f63355"
readonly AT_VER="3.0.3"
readonly AT_URL="https://github.com/iBotPeaches/Apktool/releases/download/v${AT_VER}/apktool_${AT_VER}.jar"
readonly AT_SHA="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
readonly BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
readonly BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"

RUN_ID="$WS_RUN_ID"
readonly RUN_ID
STAGE=""; WORK_DIR=""; SCRATCH=""; OFFICIAL_DIR=""; OFFICIAL_MAIN=""; MODE=""; KIND_RULE=""; PRUNE=false
CE=""; IMG=""; PULLED=false; ROOTLESS=false; NIXVOL=""; CRUN_ENV=()
VERDICT="not_reproducible"
VERSION_NAME=""; VERSION_CODE=""; SIGNER="unknown"; APP_HASH=""; COMMIT_HASH="unknown"
TAG=""; TAG_TYPE="unknown"; SDK=""; SDK_SRC=""; SPEC=""
SOURCE_REF=""; TAG_COMMIT=""; TAG_PUBSPEC=""; SDE="unknown"; FLAKE_SHA="unknown"; BT_VER="unknown"
MANIFEST=""; MANIFEST_SRC="not available"; MF_NOTE=""
PAY_AAB="n/a"; PAY_OFF="n/a"; PAY_BLT="n/a"; PAY_STATE="not compared"
RAW_TOTAL=0; UNACC_TOTAL=0; MISSING_TOTAL=0
ACC_SIGN=0; ACC_STAMP=0; ACC_MANI=0; ACC_ARSC=0
BUILD_LOCK_FILE=""

# At most N lines without closing the pipe early (`head` would SIGPIPE under pipefail).
cap() { awk -v n="${1:-5}" 'NR<=n{print} {last=NR} END{if(last>n) printf "    ... %d more line(s); full listing saved\n", last-n}'; }

usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <play-split-dir|base.apk|envoy-X.Y.Z.apk> | --version <X.Y.Z> [--arch <a>]
                      [--type <t>] [--commit <sha>] [--manifest <json>]
  --binary   (alias --apk) Play split directory, its base.apk, or a universal APK; kind from the manifest.
  --version  Without --binary: download the GitHub APK and manifest. With it: cross-checked only.
  --arch     Checked against a split set's ABI. --type: logged.
  --commit   Optional. Build this revision instead of the release tag; the pubspec cross-check stays fatal.
  --manifest Optional envoy-X.Y.Z-android-manifest.json; default: next to the binary, else GitHub release.
Environment: WS_LIB_FILE (offline library); WS_DEVICE_SDK (split-mode sdkVersion); ENVOY_REPRODUCIBLE_BUILD_JOBS /
             _GRADLE_OPTS (docker-build.sh defaults); WS_NIX_VOLUME (existing /nix volume; never removed).
Host needs: podman (preferred) or docker, a normal user. Exit: 0 reproducible, 1 not reproducible, ftbfs or no
             verdict, 2 invalid input.
USAGE
}

fail_ftbfs() { ws_error "$1"; ws_write_yaml ftbfs "$1"; exit "$WS_EXIT_FAIL"; }

finalize_workspace() {
    [[ -n "$STAGE" && -d "$STAGE" ]] || return 0
    local v="${VERSION_NAME:-}" d
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || v=unknown
    d="${EXEC_DIR}/envoy_verification_${v}_${RUN_ID}"
    if mv -T "$STAGE" "$d"; then WORK_DIR="$d"; [[ "$OFFICIAL_DIR" != "$STAGE/official" ]] || { OFFICIAL_DIR="$d/official"; OFFICIAL_MAIN="$d/official/${OFFICIAL_MAIN##*/}"; OFFICIAL_SPLITS=("$OFFICIAL_MAIN"); }; else WORK_DIR="$STAGE"; ws_warn "Could not rename ${STAGE}; using it as the workspace"; fi
    STAGE=""; WS_WORKDIR="$WORK_DIR"
}

# One container per tool; $1 = workdir.
crun() {
    local ws="${WORK_DIR:-$STAGE}" tok=()
    [[ -f "${HOME}/nix.conf" ]] && tok=(-v "${HOME}/nix.conf:/root/.config/nix/nix.conf:ro")
    ctr run --rm --label "envoy-repro=${RUN_ID}" ${OFFICIAL_DIR:+-v "${OFFICIAL_DIR}:${OFFICIAL_DIR}:ro"} \
        -v "${ws}:${ws}" -v "${ws}/canonical:/tmp/envoy-reproducible-build" -v "${ws}/cache:/tmp/envoy-reproducible-cache" \
        -v "${NIXVOL}:/nix" ${tok[@]+"${tok[@]}"} ${CRUN_ENV[@]+"${CRUN_ENV[@]}"} \
        --env XDG_CACHE_HOME=/tmp/envoy-reproducible-cache/xdg --env GIT_TERMINAL_PROMPT=0 --env GIT_CONFIG_COUNT=1 \
        --env GIT_CONFIG_KEY_0=safe.directory --env GIT_CONFIG_VALUE_0='*' -w "$1" "$IMG" "${@:2}"
}
crm() { crun "${WORK_DIR:-$STAGE}" rm -rf "$@"; }

# Run first by ws_on_exit.
ws_cleanup_hook() {
    finalize_workspace
    [[ -z "$WORK_DIR" ]] || rm -f "${WORK_DIR}/home/nix.conf"
    if [[ -n "$CE" ]]; then
        ctr rm -f $(ctr ps -aq --filter "label=envoy-repro=${RUN_ID}" 2>/dev/null) >/dev/null 2>&1 || true
        ( host_env; ws_hand_back ) || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        chmod -R u+rwX "$WORK_DIR" 2>/dev/null || true
        rm -rf "${WORK_DIR}/scratch" 2>/dev/null || true
        if [[ "$PRUNE" == true ]]; then
            rm -rf "${WORK_DIR}/canonical" "${WORK_DIR}/cache" 2>/dev/null || true
            ws_info "Pruned ${WORK_DIR}/canonical and cache (kept only on ftbfs or no verdict)"
        fi
        local foreign
        foreign="$(find "$WORK_DIR" ! -uid "$(id -u)" 2>/dev/null | cap 5)"
        [[ -z "$foreign" ]] && ws_info "Workspace ${WORK_DIR}: $(du -sh "$WORK_DIR" 2>/dev/null | awk '{print $1}'), all owned by uid $(id -u)" \
            || ws_warn "Workspace entries NOT owned by uid $(id -u):"$'\n'"$foreign"
    fi
    if [[ -n "$CE" && -n "$NIXVOL" && -z "${WS_NIX_VOLUME:-}" ]]; then ctr volume rm -f "$NIXVOL" >/dev/null 2>&1 || true; fi
    [[ -z "$CE" ]] || host_env
}

# rc 0 = same, 1 = differs, >1 = diff could not run (never read as "identical").
DIFF_OUT=""
run_diff() {
    local rc=0
    DIFF_OUT="$("$@" 2>&1)" || rc=$?
    [[ $rc -le 1 ]] && return 0
    return "$rc"
}

ws_refuse_root
ws_install_traps

binary_arg=""; version_arg=""; arch_arg=""; type_arg=""; commit_arg=""; manifest_arg=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary|--apk) ws_require_value "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
        --version)      ws_require_value "$1" "${2:-}"; version_arg="$2"; shift 2 ;;
        --arch)         ws_require_value "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
        --type)         ws_require_value "$1" "${2:-}"; type_arg="$2"; shift 2 ;;
        --commit)       ws_require_value "$1" "${2:-}"; commit_arg="$2"; shift 2 ;;
        --manifest)     ws_require_value "$1" "${2:-}"; manifest_arg="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              ws_unknown_arg "$@"; shift "$WS_SHIFT" ;;
    esac
done

[[ -n "$binary_arg" || "$version_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage; ws_invalid "Pass --binary, or --version X.Y.Z to download the GitHub APK."; }
[[ -z "$manifest_arg" || -f "$manifest_arg" ]] || ws_invalid "--manifest file does not exist: ${manifest_arg}"
[[ -z "$manifest_arg" || -n "$binary_arg" ]] || ws_invalid "--manifest needs --binary; downloads use the release manifest."

shopt -s nullglob
if [[ -z "$binary_arg" ]]; then :
elif [[ -f "$binary_arg" ]]; then
    OFFICIAL_DIR="$(cd "$(dirname "$binary_arg")" && pwd -P)"; OFFICIAL_MAIN="${OFFICIAL_DIR}/$(basename "$binary_arg")"
    [[ "$OFFICIAL_MAIN" == *.apk ]] || ws_invalid "--binary must be an .apk file or a directory of APKs (got $(basename "$binary_arg"))."
elif [[ -d "$binary_arg" ]]; then
    OFFICIAL_DIR="$(cd "$binary_arg" && pwd -P)"; apks=("${OFFICIAL_DIR}"/*.apk)
    if [[ -f "${OFFICIAL_DIR}/base.apk" ]]; then OFFICIAL_MAIN="${OFFICIAL_DIR}/base.apk"
    elif [[ ${#apks[@]} -eq 1 ]]; then OFFICIAL_MAIN="${apks[0]}"
    else ws_invalid "${OFFICIAL_DIR} holds ${#apks[@]} APK files and no base.apk; cannot pick the main APK."; fi
else
    ws_invalid "--binary path does not exist: ${binary_arg}"
fi
SIBLINGS=(); [[ -z "$OFFICIAL_DIR" ]] || for f in "${OFFICIAL_DIR}"/*.apk; do [[ "$f" == "$OFFICIAL_MAIN" ]] || SIBLINGS+=("$f"); done
shopt -u nullglob

[[ -n "${arch_arg}${type_arg}" ]] && ws_info "--arch '${arch_arg}' (checked against a split set's ABI) / --type '${type_arg}' (logged)"

ws_section "PRE-FLIGHT"
ws_results_init
# Engine calls keep the caller's HOME (rootless podman storage).
HOST_ENV=("HOME=$HOME"); HOST_UNSET=()
for v in XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME; do if [[ -n "${!v:-}" ]]; then HOST_ENV+=("$v=${!v}"); else HOST_UNSET+=("$v"); fi; done
host_env() { local kv; for kv in "${HOST_ENV[@]}"; do export "${kv?}"; done; for kv in ${HOST_UNSET[@]+"${HOST_UNSET[@]}"}; do unset "$kv"; done; }
ctr() { ( host_env; ws_ctr "$@" ); }
ws_engine
CE="$WS_ENGINE"
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || ws_no_verdict "upstream's canonical builder requires x86_64 Linux."
if [[ "$CE" == podman ]]; then ROOTLESS="$(ctr info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)"
else grep -q rootless <<<"$(ctr info --format '{{.SecurityOptions}}' 2>/dev/null || true)" && ROOTLESS=true || ROOTLESS=false; fi
ws_ok "$(ctr --version 2>/dev/null | head -1 || true); rootless=${ROOTLESS}"

STAGE="$(mktemp -d "${EXEC_DIR}/.envoy_stage_${RUN_ID}.XXXXXX")"; WS_WORKDIR="$STAGE"
mkdir -p "${STAGE}/comparison" "${STAGE}/built" "${STAGE}/tools/bin" "${STAGE}/home" "${STAGE}/scratch" "${STAGE}/canonical" "${STAGE}/cache"
set_home() {
    export HOME="$1/home" XDG_CACHE_HOME="$1/home/.cache" XDG_CONFIG_HOME="$1/home/.config"
    mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
}
set_home "$STAGE"
token_on()  { [[ -n "${GITHUB_TOKEN:-}" ]] || return 0; ( umask 077; printf '%s\n' 'experimental-features = nix-command flakes' 'sandbox = false' 'filter-syscalls = false' 'accept-flake-config = true' "access-tokens = github.com=${GITHUB_TOKEN}" > "${HOME}/nix.conf" ); }
token_off() { rm -f "${HOME}/nix.conf"; unset GITHUB_TOKEN; }
token_on

NIXVOL="${WS_NIX_VOLUME:-envoy-repro-${RUN_ID}}"
ctr image exists "$BASE_IMG" >/dev/null 2>&1 || ctr image inspect "$BASE_IMG" >/dev/null 2>&1 || PULLED=true
ctr pull -q "$BASE_IMG" >/dev/null 2>&1 || { PULLED=false; ws_no_verdict "Could not pull ${BASE_IMG} with ${CE}."; }
IMG="$BASE_IMG"; WS_CHOWN_IMAGE="$BASE_IMG"
ws_ok "base image $([[ "$PULLED" == true ]] && echo 'pulled' || echo 'already present'); /nix volume ${NIXVOL}$([[ -n "${WS_NIX_VOLUME:-}" ]] && echo ' (WS_NIX_VOLUME, reused)')"
crun "$STAGE" nix --version >/dev/null 2>&1 || ws_no_verdict "${CE} cannot run ${BASE_IMG} with the workspace mounted."

NIX=(nix --extra-experimental-features 'nix-command flakes')
GIT=(cgit)
cgit() { crun "${WORK_DIR:-$STAGE}" git "$@"; }
g() { "${GIT[@]}" -C "$SRC_DIR" "$@"; }
apktool() { crun "${WORK_DIR:-$STAGE}" "${NIX[@]}" shell "${NIXPKGS}#jdk17" --command java -Duser.home="${HOME}" -jar "$AT_JAR" "$@"; }

cat <<BANNER

== ENVOY (${APP_ID}) ANDROID VERIFICATION ==
 Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}
 Input:     ${binary_arg:-GitHub release v${version_arg}} (main APK ${OFFICIAL_MAIN##*/}, ${#SIBLINGS[@]} sibling APK(s))
 Date:      $(date)
BANNER

ws_section "SETUP: PINNED TOOLING"
fetch_url() { # url dest -> 0 on success
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else crun "${WORK_DIR:-$STAGE}" curl -fsSL "$1" -o "$2"; fi
}
AT_JAR="${STAGE}/tools/apktool.jar"
ws_fetch "$AT_URL" "$AT_JAR" "$AT_SHA"
ws_ok "apktool ${AT_VER} verified: ${AT_SHA}"
if [[ -z "$binary_arg" ]]; then
    OFFICIAL_DIR="${STAGE}/official"; mkdir -p "$OFFICIAL_DIR"; DL="${REL_URL}/v${version_arg}/envoy-${version_arg}"
    OFFICIAL_MAIN="${OFFICIAL_DIR}/envoy-${version_arg}.apk"; ws_fetch "${DL}.apk" "$OFFICIAL_MAIN"
    ws_fetch "${DL}-android-manifest.json" "${OFFICIAL_DIR}/envoy-${version_arg}-android-manifest.json"
fi
APKTOOL_FRAME="${STAGE}/home/apktool-frames"; mkdir -p "$APKTOOL_FRAME"

ws_section "PHASE 0: OFFICIAL BINARY METADATA"
MD="${STAGE}/scratch/meta"
apktool d -s -f --frame-path "$APKTOOL_FRAME" -o "$MD" "$OFFICIAL_MAIN" > "${STAGE}/apktool.log" 2>&1 \
    || { cap 5 < "${STAGE}/apktool.log"; ws_no_verdict "apktool could not decode ${OFFICIAL_MAIN}."; }
yml() { sed -n "s/^[[:space:]]*$1:[[:space:]]*'\{0,1\}\([^']*\)'\{0,1\}[[:space:]]*$/\1/p" "${MD}/apktool.yml" | head -1; }
VERSION_NAME="$(yml versionName)"
VERSION_CODE="$(yml versionCode)"
TARGET_SDK="$(yml targetSdkVersion)"
MIN_SDK="$(yml minSdkVersion)"
pkg="$(sed -n 's/.*package="\([^"]*\)".*/\1/p' "${MD}/AndroidManifest.xml" | head -1)"

[[ "$pkg" == "$APP_ID" ]] || ws_invalid "Package mismatch: the APK reports '${pkg}', expected ${APP_ID}; wrong artifact."
[[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ws_invalid "Unexpected versionName '${VERSION_NAME}' in the APK."
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || ws_invalid "Unexpected versionCode '${VERSION_CODE}' in the APK."
# split= refused; isSplitRequired = Play base; neither = universal.
grep -q ' split="' "${MD}/AndroidManifest.xml" && ws_invalid "$(basename "$OFFICIAL_MAIN") is a config split; pass the Play split directory."
if grep -q 'isSplitRequired="true"' "${MD}/AndroidManifest.xml"; then MODE="split"; KIND_RULE='manifest has isSplitRequired="true"'
elif [[ ${#SIBLINGS[@]} -gt 0 ]]; then MODE="split"; KIND_RULE="${#SIBLINGS[@]} sibling *.apk file(s) next to $(basename "$OFFICIAL_MAIN")"
else MODE="universal"; KIND_RULE="no split=, isSplitRequired or sibling APKs"; fi
ws_ok "Input kind: ${MODE} (rule: ${KIND_RULE})"
OFFICIAL_SPLITS=("$OFFICIAL_MAIN" "${SIBLINGS[@]}")
ws_ok "Package verified: ${pkg}"
ws_ok "Version: ${VERSION_NAME} (versionCode ${VERSION_CODE})"
if [[ -z "$binary_arg" ]]; then
    [[ "$VERSION_NAME" == "$version_arg" && "$MODE" == universal ]] || ws_no_verdict "GitHub v${version_arg} APK is ${MODE} v${VERSION_NAME}; not the release."
elif [[ -n "$version_arg" && "$version_arg" != "$VERSION_NAME" ]]; then ws_warn "--version ${version_arg} differs from the APK's ${VERSION_NAME}; using the APK's"; fi
APP_HASH="$(ws_sha256 "$OFFICIAL_MAIN")"
ws_info "$(basename "$OFFICIAL_MAIN") SHA-256: ${APP_HASH}"
ws_info "Official APK(s):"
for f in "${OFFICIAL_SPLITS[@]}"; do printf '  %s  %s\n' "$(ws_sha256 "$f")" "$(basename "$f")"; done

finalize_workspace
readonly WORK_DIR
set_home "$WORK_DIR"
SCRATCH="${WORK_DIR}/scratch"; SRC_DIR="${WORK_DIR}/src"
AT_JAR="${WORK_DIR}/tools/apktool.jar"; APKTOOL_FRAME="${HOME}/apktool-frames"
ws_info "Workspace: ${WORK_DIR}"

if [[ "$MODE" == "split" ]]; then
    if [[ -n "${WS_DEVICE_SDK:-}" ]]; then
        [[ "${WS_DEVICE_SDK}" =~ ^[0-9]+$ ]] || ws_invalid "WS_DEVICE_SDK must be numeric, got '${WS_DEVICE_SDK}'."
        SDK="$WS_DEVICE_SDK"; SDK_SRC="supplied via WS_DEVICE_SDK"
    elif [[ "$TARGET_SDK" =~ ^[0-9]+$ ]]; then
        SDK="$TARGET_SDK"; SDK_SRC="targetSdkVersion from base.apk (an app declaration, NOT the device's API level)"
    elif [[ "$MIN_SDK" =~ ^[0-9]+$ ]]; then
        SDK="$MIN_SDK"; SDK_SRC="minSdkVersion from base.apk; targetSdkVersion unreadable"
    else
        SDK=35; SDK_SRC="fallback 35; no SDK value readable"
    fi
    ws_info "device-spec sdkVersion: ${SDK} (${SDK_SRC})"
fi

mf() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*$/\1/p" "$MANIFEST" | head -1; }
MF_NAME="envoy-${VERSION_NAME}-android-manifest.json"
if [[ -n "$manifest_arg" ]]; then
    MANIFEST="$(cd "$(dirname "$manifest_arg")" && pwd -P)/$(basename "$manifest_arg")"; MANIFEST_SRC="--manifest ${MANIFEST}"
elif [[ -f "${OFFICIAL_DIR}/${MF_NAME}" ]]; then
    MANIFEST="${OFFICIAL_DIR}/${MF_NAME}"; MANIFEST_SRC="next to the binary: ${MANIFEST}"
elif fetch_url "${REL_URL}/v${VERSION_NAME}/${MF_NAME}" "${WORK_DIR}/${MF_NAME}" 2>/dev/null && [[ -s "${WORK_DIR}/${MF_NAME}" ]]; then
    MANIFEST="${WORK_DIR}/${MF_NAME}"; MANIFEST_SRC="downloaded from ${REL_URL}/v${VERSION_NAME}/${MF_NAME}"
else
    rm -f "${WORK_DIR}/${MF_NAME}"; ws_warn "No release manifest next to the binary or on the GitHub release; cross-checks skipped."
fi
if [[ -n "$MANIFEST" ]]; then
    ws_ok "Release manifest: ${MANIFEST_SRC} (sha256 $(ws_sha256 "$MANIFEST"))"
    [[ "$(mf versionCode)" == "$VERSION_CODE" ]] || ws_invalid "Release manifest versionCode $(mf versionCode) is not the APK's ${VERSION_CODE}; wrong manifest."
    if [[ "$MODE" == "universal" ]]; then
        [[ "$(mf apkSha256)" == "$APP_HASH" ]] && ws_ok "Supplied APK sha256 equals the manifest's apkSha256 (it is the GitHub release APK)" \
            || { m="APK sha256 ${APP_HASH} is not the manifest's apkSha256 $(mf apkSha256)"; [[ -z "$binary_arg" ]] || ws_invalid "$m"; ws_no_verdict "$m"; }
    fi
fi

ws_section "PHASE 1: SOURCE"
TAG="v${VERSION_NAME}"
"${GIT[@]}" clone "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || ws_no_verdict "git clone failed for ${REPO_URL}."
g rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1 \
    || ws_invalid "Upstream has no tag ${TAG} for version ${VERSION_NAME}; the artifact cannot be tied to published source."
TAG_COMMIT="$(g rev-parse "${TAG}^{commit}")"
TAG_PUBSPEC="$(g show "${TAG}:pubspec.yaml" 2>/dev/null | sed -n 's/^version:[[:space:]]*//p' | head -1)"

if [[ -n "$commit_arg" ]]; then
    g rev-parse --verify "${commit_arg}^{commit}" >/dev/null 2>&1 || ws_invalid "--commit ${commit_arg} is not a commit in ${REPO_URL}."
    g checkout -q "$commit_arg" || ws_no_verdict "Could not check out ${commit_arg}."
    SOURCE_REF="commit ${commit_arg} (explicit --commit; NOT the release tag)"
    ws_warn "Building an explicit commit, not ${TAG} (${TAG_COMMIT}, pubspec ${TAG_PUBSPEC:-unknown}); weaker provenance."
else
    g checkout -q "$TAG" || ws_no_verdict "Could not check out ${TAG}."
    SOURCE_REF="tag ${TAG}"
fi
COMMIT_HASH="$(g rev-parse HEAD)"
st="$(g status --porcelain)" && [[ -z "$st" ]] || ws_no_verdict "Working tree not clean (or git status failed) after checkout."
TAG_TYPE="$(g cat-file -t "$TAG" 2>/dev/null || echo unknown)"
SDE="$(g show -s --format=%ct HEAD)"
FLAKE_SHA="$(ws_sha256 "${SRC_DIR}/flake.lock")"
ws_ok "Building ${SOURCE_REF} at ${COMMIT_HASH} (SOURCE_DATE_EPOCH ${SDE}; flake.lock sha256 ${FLAKE_SHA})"

pv="$(sed -n 's/^version:[[:space:]]*//p' "${SRC_DIR}/pubspec.yaml" | head -1)"
[[ "$pv" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)$ ]] || ws_no_verdict "pubspec.yaml version '${pv}' is not X.Y.Z+B; cannot cross-check."
expect_code=$(( BASH_REMATCH[1]*1000000 + BASH_REMATCH[2]*10000 + BASH_REMATCH[3]*100 + BASH_REMATCH[4] ))
pvn="${pv%%+*}"
[[ "$pvn" == "$VERSION_NAME" && "$expect_code" == "$VERSION_CODE" ]] \
    || { m="${SOURCE_REF}'s pubspec ${pv} gives ${pvn} / ${expect_code}; the APK is ${VERSION_NAME} / ${VERSION_CODE}"; [[ -z "$commit_arg" ]] || ws_invalid "$m"; ws_no_verdict "$m; try --commit"; }
ws_ok "Source cross-check: pubspec ${pv} yields versionCode ${expect_code}, matching the artifact"

RB="${SRC_DIR}/reproducible-builds"
[[ -f "${RB}/build.sh" && -f "${RB}/Dockerfile" ]] || ws_invalid "${SOURCE_REF} has no reproducible-builds/build.sh + Dockerfile (upstream since v2.3.4); for 2.3.3 and earlier run envoy-v0.3.2_build.sh."

if [[ -n "$MANIFEST" ]]; then
    for pair in "gitCommit:${COMMIT_HASH}" "sourceDateEpoch:${SDE}" "flakeLockSha256:${FLAKE_SHA}"; do
        k="${pair%%:*}"; v="${pair#*:}"
        [[ "$(mf "$k")" == "$v" ]] && ws_ok "manifest ${k} matches ${SOURCE_REF}" \
            || { ws_warn "manifest ${k} is $(mf "$k") but ${SOURCE_REF} gives ${v}"; MF_NOTE="${MF_NOTE}${k} mismatch (manifest $(mf "$k") vs source ${v}); "; }
    done
fi

ws_section "PHASE 1b: UPSTREAM CONTAINER IMAGE"
grep -q "^FROM ${BASE_IMG#docker.io/}" "${RB}/Dockerfile" || ws_warn "the tag's Dockerfile does not pin ${BASE_IMG#docker.io/}; metadata was read on a different base image"
RUN_IMG="localhost/envoy-repro:${RUN_ID}"
if ctr build --platform linux/amd64 $([[ "$CE" == podman ]] && echo --layers=false || echo --force-rm) -t "$RUN_IMG" -f "${RB}/Dockerfile" "$RB" > "${WORK_DIR}/image.log" 2>&1; then IMG="$RUN_IMG"; ws_track_image "$RUN_IMG"; else
    cap 5 < "${WORK_DIR}/image.log"; ws_no_verdict "${CE} build of ${RB}/Dockerfile failed; see ${WORK_DIR}/image.log."
fi
ws_ok "image ${IMG} ($(ctr image inspect --format '{{.Id}}' "$IMG" 2>/dev/null | cut -c1-19 || true)) from the tag's Dockerfile"

nixrun() { crun "$SRC_DIR" nix develop "${SRC_DIR}#reproducibleAndroid" --command "$@"; }
if nixrun true > "${WORK_DIR}/devshell.log" 2>&1; then :; else
    cap 5 < "${WORK_DIR}/devshell.log"; ws_no_verdict "nix develop ${SRC_DIR}#reproducibleAndroid failed; see ${WORK_DIR}/devshell.log."
fi
BT_VER="$(nixrun bundletool version 2>/dev/null | awk '{print $NF}' | tail -1 || true)"; BT_VER="${BT_VER:-unknown}"
# bundletool's own aapt2 can't run in the NixOS image: use the flake's.
AAPT2="$(nixrun sh -c 'command -v aapt2' 2>/dev/null | tail -1 || true)"
[[ "$AAPT2" == /nix/store/* ]] || ws_no_verdict "The dev shell provides no aapt2 for bundletool (got '${AAPT2}')."
ws_ok "dev shell ready; bundletool ${BT_VER}; aapt2 ${AAPT2}"
SIGNER="$(nixrun apksigner verify --print-certs "$OFFICIAL_MAIN" 2>/dev/null | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | tail -1 || true)"
SIGNER="${SIGNER:-unknown}"
ws_info "Signer SHA-256: ${SIGNER}"

ws_section "PHASE 2: BUILD VIA UPSTREAM reproducible-builds/build.sh (30-90 min cold)"
# build.sh uses canonical/ and cache/; both pruned unless ftbfs.
token_off; ws_info "GitHub token file removed before the build"
CANON_IN="/tmp/envoy-reproducible-build/${COMMIT_HASH}/project"
ws_info "container ${CANON_IN} and /tmp/envoy-reproducible-cache = ${WORK_DIR}/canonical and cache"
cp "${RB}/shasum" "${WORK_DIR}/tools/bin/shasum" && chmod 755 "${WORK_DIR}/tools/bin/shasum"
CRUN_ENV=(--env "ENVOY_REPRODUCIBLE_BUILD_JOBS=${ENVOY_REPRODUCIBLE_BUILD_JOBS:-2}" --env ENVOY_KEEP_REPRODUCIBLE_WORKDIR=1
    --env "ENVOY_REPRODUCIBLE_GRADLE_OPTS=${ENVOY_REPRODUCIBLE_GRADLE_OPTS:--Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8 -Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false -Dorg.gradle.daemon=false}")
ws_info "BUILD_JOBS=${ENVOY_REPRODUCIBLE_BUILD_JOBS:-2 (default)}  GRADLE_OPTS=${ENVOY_REPRODUCIBLE_GRADLE_OPTS:-<docker-build.sh default>}"
AAB="${WORK_DIR}/built/app-release.aab"
if crun "$SRC_DIR" bash -lc 'set -euo pipefail; export PATH="$1:$PATH"; ./reproducible-builds/build.sh --output "$2"' bash "${WORK_DIR}/tools/bin" "$AAB" 2>&1 | tee "${WORK_DIR}/build.log"; then :; else
    [[ "${PIPESTATUS[1]}" -eq 0 ]] || ws_no_verdict "Could not write ${WORK_DIR}/build.log."
    # Only a compiler or resource error is ftbfs; anything else gives no verdict.
    kind="$(ws_gradle_failure_kind "${WORK_DIR}/build.log")"
    case "$kind" in
        source) fail_ftbfs "upstream reproducible-builds/build.sh failed with a compiler or resource error. See ${WORK_DIR}/build.log." ;;
        infra*) ws_no_verdict "upstream reproducible-builds/build.sh failed on a host or network problem: ${kind#infra: }" ;;
        *)      ws_no_verdict "upstream reproducible-builds/build.sh failed with no recognised cause; see ${WORK_DIR}/build.log." ;;
    esac
fi
CRUN_ENV=()
[[ -f "$AAB" ]] || ws_no_verdict "build.sh reported success but ${AAB} does not exist."
ws_ok "AAB built: $(ws_sha256 "$AAB")"

# Build record (#1000), before the prune.
ws_section "BUILD RECORD"
BL_SH="${WORK_DIR}/tools/ws-buildlock.sh"; bl_rc=0
if curl -fsSL --max-time 60 -o "$BL_SH" "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" < /dev/null \
   && [[ "$(ws_sha256 "$BL_SH")" == "$BUILDLOCK_SHA256" ]]; then
    mkdir -p "${WORK_DIR}/build-lock" || bl_rc=$?
    [[ "$bl_rc" -ne 0 ]] || nixrun bash "$BL_SH" --out "${WORK_DIR}/build-lock" --gradle-home /tmp/envoy-reproducible-cache/gradle \
        --src "${WORK_DIR}/canonical/${COMMIT_HASH}/project" --app-id "$APP_ID" --version "$VERSION_NAME" \
        --platform android --commit "$COMMIT_HASH" > "${WORK_DIR}/build-lock.log" 2>&1 || bl_rc=$?
    if [[ "$bl_rc" -eq 0 && -s "${WORK_DIR}/build-lock/build-lock.json" ]] && ! grep -q 'nothing recorded' "${WORK_DIR}/build-lock.log"; then
        BUILD_LOCK_FILE="${WORK_DIR}/build-lock/build-lock.json"
        ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
    else
        ws_warn "No build-lock.json (exit ${bl_rc}; see ${WORK_DIR}/build-lock.log); verdict unaffected."
    fi
else
    ws_warn "build-lock skipped: no ws-buildlock.sh with the expected sha256; verdict unaffected."
fi

# Payload digest = upstream's apkdiff.archive_payload_digest.
PAYLOAD_PY="${WORK_DIR}/tools/payload.py"
cat > "$PAYLOAD_PY" <<'PY'
import hashlib,sys,zipfile
IGN={"META-INF/MANIFEST.MF","META-INF/code_transparency_signed.jwt","stamp-cert-sha256"}
def ign(n):
    u=n.upper(); return n in IGN or (u.startswith("META-INF/") and u.endswith((".DSA",".EC",".RSA",".SF")))
e=[]
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist():
        if i.is_dir() or ign(i.filename): continue
        e.append((i.filename,hashlib.sha256(z.read(i)).hexdigest()))
h=hashlib.sha256()
for n,d in sorted(e): h.update(n.encode()+b"\0"+d.encode()+b"\n")
print(h.hexdigest())
PY
payload_of() { nixrun python3 "$PAYLOAD_PY" "$1"; }
PAY_AAB="$(payload_of "$AAB" 2>/dev/null || echo error)"
ws_info "AAB payload sha256: ${PAY_AAB}"
if [[ -n "$MANIFEST" ]]; then
    [[ "$(mf aabPayloadSha256)" == "$PAY_AAB" ]] && ws_info "built AAB payload equals the manifest's aabPayloadSha256" \
        || ws_info "built AAB payload differs from the manifest's aabPayloadSha256 $(mf aabPayloadSha256): r8.json records R8 buildTimeNs"
fi

ws_section "PHASE 3: DERIVE APK(S) FROM THE AAB"
if [[ "$MODE" == "universal" ]]; then
    nixrun bundletool build-apks --bundle="$AAB" --output="${WORK_DIR}/built.apks" --mode=universal --aapt2="$AAPT2" --overwrite \
        || ws_no_verdict "bundletool build-apks --mode=universal failed."
    nixrun unzip -p "${WORK_DIR}/built.apks" universal.apk > "${WORK_DIR}/built/universal.apk" \
        || ws_no_verdict "Could not extract universal.apk from built.apks."
    [[ -s "${WORK_DIR}/built/universal.apk" ]] || ws_no_verdict "universal.apk is empty."
else
    ABIS=(); DEN=""; LOCS=()
    for f in "${OFFICIAL_SPLITS[@]}"; do
        [[ "$f" == "$OFFICIAL_MAIN" ]] && continue
        c="$(basename "$f")"; c="${c%.apk}"; c="${c#split_config.}"
        case "$c" in
            arm64_v8a) ABIS+=("arm64-v8a") ;; armeabi_v7a) ABIS+=("armeabi-v7a") ;; x86_64) ABIS+=("x86_64") ;; x86) ABIS+=("x86") ;;
            ldpi) DEN=120 ;; mdpi) DEN=160 ;; tvdpi) DEN=213 ;; hdpi) DEN=240 ;; xhdpi) DEN=320 ;; xxhdpi) DEN=480 ;; xxxhdpi) DEN=640 ;;
            [a-z][a-z]|[a-z][a-z]_[A-Za-z]*) LOCS+=("${c//_/-}") ;;
            *) ws_invalid "Unrecognised split config '${c}' in the official set." ;;
        esac
    done
    [[ ${#ABIS[@]} -eq 0 ]] && ws_invalid "No ABI split in the official set."
    [[ -z "$DEN" ]] && ws_invalid "No density split in the official set."
    [[ ${#LOCS[@]} -eq 0 ]] && LOCS=("en")
    j() { local o=""; for v in "$@"; do o="${o}\"${v}\","; done; echo "[${o%,}]"; }
    SPEC="${WORK_DIR}/device-spec.json"
    printf '{"supportedAbis":%s,"supportedLocales":%s,"screenDensity":%s,"sdkVersion":%s}\n' "$(j "${ABIS[@]}")" "$(j "${LOCS[@]}")" "$DEN" "$SDK" > "$SPEC"
    cat "$SPEC"
    nixrun bundletool build-apks --bundle="$AAB" --output="${WORK_DIR}/built.apks" --device-spec="$SPEC" --aapt2="$AAPT2" --overwrite \
        || ws_no_verdict "bundletool build-apks failed."
    nixrun unzip -q -o "${WORK_DIR}/built.apks" 'splits/*.apk' -d "${WORK_DIR}/bt" || ws_no_verdict "Could not extract splits from built.apks."
    cp "${WORK_DIR}"/bt/splits/*.apk "${WORK_DIR}/built/" || ws_no_verdict "No split APKs produced by bundletool."
fi
ws_info "built APK(s):"
for f in "${WORK_DIR}"/built/*.apk; do printf '  %s  %s\n' "$(ws_sha256 "$f")" "$(basename "$f")"; done

ws_section "PHASE 4: PER-APK COMPARISON"
OFF_ROOT="${SCRATCH}/o"; BLT_ROOT="${SCRATCH}/b"
re_esc() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/]/\\&/g'; }
OFF_RE="$(re_esc "$OFF_ROOT")"

cfg_of() {
    local s
    s="$(nixrun aapt2 dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1 || true)"
    printf '%s' "${s#config.}"
}

declare -A OFF BLT
add_key() { # array_name key file — a collision would silently drop a supplied APK
    local -n arr="$1"
    [[ -n "${arr[$2]:-}" ]] && ws_invalid "Two APKs map to config key '$2' ($(basename "${arr[$2]}") and $(basename "$3"))."
    arr["$2"]="$3"
}
if [[ "$MODE" == "universal" ]]; then
    OFF[universal]="$OFFICIAL_MAIN"; BLT[universal]="${WORK_DIR}/built/universal.apk"
else
    for f in "${OFFICIAL_SPLITS[@]}"; do k="$(cfg_of "$f")"; [[ -z "$k" ]] && k="base"; add_key OFF "$k" "$f"; done
    [[ -z "$arch_arg" || ( "${arch_arg//-/_}" =~ ^(arm64_v8a|armeabi_v7a|x86_64|x86)$ && -n "${OFF[${arch_arg//-/_}]:-}" ) ]] \
        || ws_invalid "--arch ${arch_arg}: no such ABI split (split= attribute) in the set."
    for f in "${WORK_DIR}"/built/*.apk; do k="$(cfg_of "$f")"; [[ -z "$k" ]] && k="base"; add_key BLT "$k" "$f"; done
fi
MAIN_KEY="$([[ "$MODE" == universal ]] && echo universal || echo base)"

for k in "${!OFF[@]}"; do
    f="${OFF[$k]}"
    bd="$(nixrun aapt2 dump badging "$f" 2>/dev/null || true)"
    p2="$(printf '%s' "$bd" | sed -n "s/.*package: name='\([^']*\)'.*/\1/p" | head -1)"
    v2="$(printf '%s' "$bd" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | head -1)"
    [[ "$p2" == "$APP_ID" ]] || ws_invalid "$(basename "$f") reports package '${p2}', expected ${APP_ID}."
    [[ "$v2" == "$VERSION_CODE" ]] || ws_invalid "$(basename "$f") reports versionCode '${v2}', expected ${VERSION_CODE}."
    s2="$(nixrun apksigner verify --print-certs "$f" 2>/dev/null | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -1 || true)"
    [[ -n "$s2" ]] || ws_invalid "$(basename "$f") has no verifiable signature."
    [[ "$s2" == "$SIGNER" ]] || ws_invalid "$(basename "$f") is signed by ${s2} but $(basename "$OFFICIAL_MAIN") by ${SIGNER}."
done
ws_ok "Identity verified: ${#OFF[@]} official APK(s) share package, versionCode and signer"
[[ ${#OFF[@]} -eq ${#OFFICIAL_SPLITS[@]} ]] || ws_invalid "${#OFFICIAL_SPLITS[@]} official files but only ${#OFF[@]} distinct config keys."

# Root META-INF signing files, by name, official side only.
SIGN_NAME='([^/]*\.(SF|RSA|DSA|EC)|MANIFEST\.MF)'

# Whole official-only META-INF dir: earned only if every entry is a signing file.
metainf_dir_ok() {
    local d="${OFF_ROOT}/META-INF" e bad rc=0
    e="$(find "$d" -mindepth 1 ! -type d -printf '%y %P\n' | LC_ALL=C sort)" || ws_no_verdict "Could not list ${d}."
    [[ -z "$(find "$d" -name $'*\n*' -print -quit)" ]] || { echo "      META-INF dir: newline in a name -> material"; return 1; }
    bad="$(grep -vE "^f ${SIGN_NAME}$" <<<"$e")" || rc=$?
    [[ "$rc" -le 1 ]] || ws_no_verdict "grep failed on ${d}."
    [[ -n "$e" && -z "$bad" ]] || { echo "      META-INF dir: non-signing entries -> material:"; cap 5 <<<"$bad"; return 1; }
    echo "      META-INF dir: official-only, $(grep -c '' <<<"$e") signing files:"; cap 5 <<<"$e"
}

stamp_ok() {
    local o="$1" n sz
    n=$(nixrun unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256' || true)
    [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
    [[ -e "${BLT_ROOT}/stamp-cert-sha256" ]] && { echo "      stamp: present in BUILT too"; return 1; }
    sz=$(stat -c%s "${OFF_ROOT}/stamp-cert-sha256" 2>/dev/null || echo -1)
    [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
    # Not piped: under pipefail grep -q's early exit fails the pipe (SIGPIPE) even on a match.
    sz="$(nixrun apksigner verify --verbose --print-certs "$o" 2>/dev/null || true)"
    grep -q 'Verified for SourceStamp: true' <<<"$sz" \
        || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
    echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

# Earned only when the sole delta is Play's meta-data on the official side.
manifest_ok() {
    local o="$1" b="$2" c="$3" left bad n m v
    nixrun aapt2 dump xmltree --file AndroidManifest.xml "$o" > "${SCRATCH}/mo" 2>/dev/null || return 1
    nixrun aapt2 dump xmltree --file AndroidManifest.xml "$b" > "${SCRATCH}/mb" 2>/dev/null || return 1
    run_diff nixrun diff -u "${SCRATCH}/mo" "${SCRATCH}/mb" || { echo "      manifest: diff failed to run -> material"; return 1; }
    printf '%s\n' "$DIFF_OUT" > "${WORK_DIR}/comparison/diff_manifest_${c}.txt"
    grep -q '^+[^+]' <<<"$DIFF_OUT" && { echo "      manifest: BUILT-only lines present"; return 1; }
    left="$(printf '%s\n' "$DIFF_OUT" | grep '^-[^-]' | sed 's/^- *//' || true)"
    # aapt2 appends ` (Raw: "...")` to string attributes and omits it for integers.
    local RAWSUF='( \(Raw: "[^"]*"\))?'
    bad="$(printf '%s\n' "$left" | grep -vE "^E: meta-data|^A: [^ ]*android:name\(0x[0-9a-f]+\)=\"com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id)\"${RAWSUF}\$|^A: [^ ]*android:value\(0x[0-9a-f]+\)=(\"(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK)\"|[0-9]+)${RAWSUF}\$" || true)"
    if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
        echo "      manifest: unexpected off-only line(s):"
        printf '%s\n' "$bad" | cap 3 | sed 's/^/        /'
        return 1
    fi
    n=$(printf '%s\n' "$left" | grep -c '^E: meta-data' || true)
    m=$(printf '%s\n' "$left" | grep -c 'android:name(0x[0-9a-f]*)="com\.android\.' || true)
    v=$(printf '%s\n' "$left" | grep -c 'android:value(0x[0-9a-f]*)=' || true)
    [[ "$n" -ge 1 && "$n" -eq "$m" && "$n" -eq "$v" ]] \
        || { echo "      manifest: ${n} block(s), ${m} allowed name(s), ${v} value(s) — must be equal and non-zero"; return 1; }
    echo "      manifest: ${n} off-only Play meta-data block(s); blocks (${n}), allowed names (${m}), values (${v}) equal; pairing not proven; none built-only"
}

# resources.arsc: decoded res/ trees must be identical.
arsc_ok() {
    local o="$1" b="$2" c="$3"
    crm "${SCRATCH}/do" "${SCRATCH}/db"
    apktool d -f --no-src --no-debug-info --frame-path "$APKTOOL_FRAME" -o "${SCRATCH}/do" "$o" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (official)"; return 1; }
    apktool d -f --no-src --no-debug-info --frame-path "$APKTOOL_FRAME" -o "${SCRATCH}/db" "$b" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (built)"; return 1; }
    [[ -d "${SCRATCH}/do/res" && -d "${SCRATCH}/db/res" ]] || { echo "      arsc: no res/ after decode"; return 1; }
    run_diff nixrun diff -r "${SCRATCH}/do/res" "${SCRATCH}/db/res" || { echo "      arsc: diff failed to run -> material"; return 1; }
    printf '%s\n' "$DIFF_OUT" > "${WORK_DIR}/comparison/diff_resources_decoded_${c}.txt"
    [[ -z "$(printf '%s' "$DIFF_OUT" | tr -d '[:space:]')" ]] || { echo "      arsc: decoded res/ DIFFERS -> material"; return 1; }
    echo "      arsc: decoded res/ tree IDENTICAL"
}

signing_state() {
    local b="${BLT[$MAIN_KEY]:-}" out schemes n rc=0
    [[ -n "$b" && -f "$b" ]] || { echo "AAB unsigned; built APK signing state NOT MEASURED"; return 0; }
    n="$(nixrun unzip -l "$b" 2>/dev/null | awk '{print $NF}' | grep -cE "^META-INF/${SIGN_NAME}$" || true)"
    out="$(nixrun apksigner verify --verbose "$b" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "AAB unsigned; generated APK(s) unsigned (apksigner: no valid signature; ${n} root META-INF v1 entries)"
    else
        schemes="$(printf '%s\n' "$out" | sed -n 's/^Verified using \(v[0-9]*\) scheme.*: true$/\1/p' | paste -sd, -)"
        echo "AAB unsigned; generated APK(s) SIGNED via ${schemes:-scheme not reported} (${n} root META-INF v1 entries)"
    fi
}

SUMMARY="${WORK_DIR}/comparison/summary.txt"; : > "$SUMMARY"

for cfg in $(printf '%s\n' "${!OFF[@]}" "${!BLT[@]}" | sort -u); do
    echo ""
    echo "======== apk: ${cfg} ========"
    o="${OFF[$cfg]:-}"; b="${BLT[$cfg]:-}"
    if [[ -z "$o" || -z "$b" ]]; then
        echo "  UNMATCHED  official=$([[ -n $o ]] && echo yes || echo NO)  built=$([[ -n $b ]] && echo yes || echo NO)"
        echo "${cfg} UNMATCHED" >> "$SUMMARY"
        MISSING_TOTAL=$((MISSING_TOTAL + 1)); continue
    fi
    echo "  official: $(basename "$o")  sha256 $(ws_sha256 "$o")"
    echo "  built:    $(basename "$b")  sha256 $(ws_sha256 "$b")"

    crm "$OFF_ROOT" "$BLT_ROOT"; mkdir -p "$OFF_ROOT" "$BLT_ROOT"
    nixrun unzip -q -o "$o" -d "$OFF_ROOT" || ws_no_verdict "Could not unzip $(basename "$o")."
    nixrun unzip -q -o "$b" -d "$BLT_ROOT" || ws_no_verdict "Could not unzip $(basename "$b")."
    echo "  entries: $(find "$OFF_ROOT" -type f | wc -l) official, $(find "$BLT_ROOT" -type f | wc -l) built"

    while IFS= read -r so; do
        rel="${so#"$OFF_ROOT"/}"
        if [[ -f "${BLT_ROOT}/${rel}" ]]; then
            [[ "$(ws_sha256 "$so")" == "$(ws_sha256 "${BLT_ROOT}/${rel}")" ]] && st=MATCH || st=DIFFER
            echo "  native ${st} ${rel}"
        else
            echo "  native MISSING-IN-BUILT ${rel}"
        fi
    done < <(find "$OFF_ROOT" -name '*.so' -type f | sort)

    run_diff nixrun diff -rq "$OFF_ROOT" "$BLT_ROOT" \
        || ws_no_verdict "diff could not compare ${cfg} (exit >1)."
    raw="$DIFF_OUT"
    printf '%s\n' "$raw" > "${WORK_DIR}/comparison/diff-unzipped-${cfg}.txt"
    n=$(printf '%s\n' "$raw" | grep -vc '^$' || true)
    echo "  raw diffs: ${n}   (full list: comparison/diff-unzipped-${cfg}.txt)"
    [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | grep -v '^$' | cap 5 | sed 's/^/    /'

    # Each class matches the EXACT raw line anchored to the extraction roots.
    sign_lines="$(printf '%s\n' "$raw" | grep -E "^Only in ${OFF_RE}/META-INF: ${SIGN_NAME}$" || true)"
    c_sign=$(printf '%s\n' "$sign_lines" | grep -vc '^$' || true)
    c_mdir=$(printf '%s\n' "$raw" | grep -Fxc "Only in ${OFF_ROOT}: META-INF" || true)
    c_stamp=$(printf '%s\n' "$raw" | grep -Fxc "Only in ${OFF_ROOT}: stamp-cert-sha256" || true)
    c_mani=$(printf '%s\n' "$raw" | grep -Fxc "Files ${OFF_ROOT}/AndroidManifest.xml and ${BLT_ROOT}/AndroidManifest.xml differ" || true)
    c_arsc=$(printf '%s\n' "$raw" | grep -Fxc "Files ${OFF_ROOT}/resources.arsc and ${BLT_ROOT}/resources.arsc differ" || true)

    a_sign=0; a_stamp=0; a_mani=0; a_arsc=0
    echo "  accepted-class evidence"
    [[ "$c_sign" -gt 0 ]] && { a_sign=$c_sign; echo "      signing: ${c_sign} root META-INF entries, official-only"; }
    [[ "$c_mdir" -eq 1 ]] && { metainf_dir_ok && a_sign=$((a_sign + 1)) || echo "      META-INF dir: NOT EARNED -> material"; }
    [[ "$c_stamp" -eq 1 ]] && { stamp_ok "$o" && a_stamp=1 || echo "      stamp: NOT EARNED -> material"; }
    [[ "$c_mani" -eq 1 ]] && { manifest_ok "$o" "$b" "$cfg" && a_mani=1 || echo "      manifest: NOT EARNED -> material"; }
    [[ "$c_arsc" -eq 1 ]] && { arsc_ok "$o" "$b" "$cfg" && a_arsc=1 || echo "      arsc: NOT EARNED -> material"; }

    acc=$((a_sign + a_stamp + a_mani + a_arsc))
    [[ "$acc" -le "$n" ]] || ws_no_verdict "Internal error on ${cfg}: ${acc} accepted > ${n} raw."
    un=$((n - acc))
    [[ "$un" -eq 0 ]] && v=reproducible || v=not_reproducible
    echo "  result: raw ${n}, accepted ${acc} (sign ${a_sign}, stamp ${a_stamp}, manifest ${a_mani}, arsc ${a_arsc}), unaccounted ${un} -> ${v}"
    echo "${cfg} raw=${n} accepted=${acc} unaccounted=${un}" >> "$SUMMARY"

    RAW_TOTAL=$((RAW_TOTAL + n)); UNACC_TOTAL=$((UNACC_TOTAL + un))
    ACC_SIGN=$((ACC_SIGN + a_sign)); ACC_STAMP=$((ACC_STAMP + a_stamp))
    ACC_MANI=$((ACC_MANI + a_mani)); ACC_ARSC=$((ACC_ARSC + a_arsc))
done

ACC_TOTAL=$((ACC_SIGN + ACC_STAMP + ACC_MANI + ACC_ARSC))
if [[ "$UNACC_TOTAL" -eq 0 && "$MISSING_TOTAL" -eq 0 && ${#OFF[@]} -gt 0 ]]; then VERDICT="reproducible"; else VERDICT="not_reproducible"; fi

if [[ "$MODE" == "universal" ]]; then
    PAY_OFF="$(payload_of "$OFFICIAL_MAIN" 2>/dev/null || echo error)"
    PAY_BLT="$(payload_of "${BLT[universal]}" 2>/dev/null || echo error)"
    if [[ "$PAY_OFF" == "$PAY_BLT" && "$PAY_OFF" != error ]]; then PAY_STATE="matches"; ws_info "payload digest MATCH: ${PAY_OFF} (official and built)"; else
        PAY_STATE="differs"; ws_info "payload digest differs: official ${PAY_OFF}, built ${PAY_BLT} (arsc: upstream uses bundletool's own aapt2, we the flake's; decoded res/ is the evidence)"
    fi
    [[ -n "$MANIFEST" ]] && ws_info "manifest apkPayloadSha256 $(mf apkPayloadSha256) $([[ "$(mf apkPayloadSha256)" == "$PAY_BLT" ]] && echo equals || echo 'differs from') the built payload"
fi

ws_section "RESULT"
ws_info "Detail: ${WORK_DIR}/comparison/ (summary.txt, diff-unzipped-<apk>.txt); build log: ${WORK_DIR}/build.log"
echo ""
diff_text="$(
    [[ "$MISSING_TOTAL" -eq 0 ]] || echo "${MISSING_TOTAL} APK(s) unmatched (see comparison/summary.txt)"
    if [[ "$RAW_TOTAL" -eq 0 ]]; then echo "(no differing entries)"; else cat "${WORK_DIR}/comparison"/diff-unzipped-*.txt 2>/dev/null | grep -v '^$' | cap 5 || true; fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Tag: ${TAG} ($([[ "$TAG_TYPE" == "commit" ]] && echo 'lightweight, no signature possible' || echo "$TAG_TYPE"))"
    echo "Built from: ${SOURCE_REF}"
    if [[ -n "$commit_arg" ]]; then echo "NOTE: built from an UNTAGGED commit; ${TAG} (${TAG_COMMIT}, pubspec ${TAG_PUBSPEC:-unknown}) does not describe the artifact."; fi
)"
ws_results_block "$APP_ID" "$SIGNER" "$VERSION_NAME" "$VERSION_CODE" "$VERDICT" "$APP_HASH" "$COMMIT_HASH" "$diff_text"
echo ""
echo "inputKind:        ${MODE} (rule: ${KIND_RULE}); appHash = $(basename "$OFFICIAL_MAIN") as supplied"
echo "signingState:     $(signing_state)"
echo "bundletool:       ${BT_VER} from the flake's nixpkgs (what upstream derives its APKs with)"
echo "container:        ${CE} (rootless=${ROOTLESS}), image ${IMG} from the tag's Dockerfile on ${BASE_IMG#docker.io/}"
echo "canonicalPath:    ${CANON_IN} in the container <- ${WORK_DIR}/canonical"
echo "workspacePath:    ${WORK_DIR} (canonical/, cache/ pruned unless ftbfs or no verdict)"
if [[ -n "$BUILD_LOCK_FILE" ]]; then echo "Upload with the verification: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"; fi
echo ""

ws_write_yaml "$VERDICT" "Envoy ${MODE} input, built with upstream's reproducible-builds/build.sh at ${SOURCE_REF} (commit ${COMMIT_HASH}, SOURCE_DATE_EPOCH ${SDE}, flake.lock ${FLAKE_SHA}) in upstream's container (${CE}, tag's Dockerfile on ${BASE_IMG#docker.io/}) at its default path ${CANON_IN}, unsigned; APK(s) derived with the flake's bundletool ${BT_VER}$([[ "$MODE" == universal ]] && echo ' --mode=universal' || echo " and device spec $(cat "$SPEC") (sdkVersion ${SDK}: ${SDK_SRC})"). ${RAW_TOTAL} raw difference(s); ${ACC_TOTAL} earned exclusions - signing ${ACC_SIGN} (root META-INF signing names, official-side only), SourceStamp ${ACC_STAMP}, AndroidManifest ${ACC_MANI} (Play meta-data only), resources.arsc ${ACC_ARSC} (decoded res/ identical). ${UNACC_TOTAL} UNACCOUNTED difference(s); ${MISSING_TOTAL} APK(s) unmatched.$([[ "$MODE" == universal ]] && echo " APK payload digest ${PAY_STATE} (official ${PAY_OFF}, built ${PAY_BLT}), logged, not a verdict input: arsc bytes depend on the aapt2 build.") AAB payload ${PAY_AAB} logged, not a verdict input: r8.json records R8 buildTimeNs. Release manifest: ${MANIFEST_SRC}; ${MF_NOTE:-$([[ -n "$MANIFEST" ]] && echo 'gitCommit, sourceDateEpoch and flakeLockSha256 match' || echo 'no cross-checks')}. Official $(basename "$OFFICIAL_MAIN") SHA-256 ${APP_HASH}. Rust and Dart git dependencies fetched at the lockfile-pinned refs, not independently verified."
PRUNE=true

if [[ "$VERDICT" == "reproducible" ]]; then
    ws_ok "Verdict: reproducible -- zero unaccounted differences"
    exit "$WS_EXIT_OK"
fi
ws_warn "Verdict: not_reproducible -- ${UNACC_TOTAL} unaccounted, ${MISSING_TOTAL} unmatched APK(s)"
exit "$WS_EXIT_FAIL"
