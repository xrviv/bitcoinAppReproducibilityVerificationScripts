#!/bin/bash
# envoy-v0.4.0_build.sh — Envoy (com.foundationdevices.envoy) Android reproducible build verification
# Version:          v0.4.0
# Last modified by: Bob (WalletScrutiny agent)
# Last modified on: 2026-10-02
# Organization:     WalletScrutiny.com
# Project:          https://github.com/Foundation-Devices/envoy
#
# DISCLAIMER: for technical analysis and reproducible build verification only, without warranty of any
# kind; users assume all risks and are responsible for compliance with applicable laws.
#
# SCOPE: (a) Google Play split set (directory of device-pulled splits, or its base.apk); (b) GitHub release
# universal APK (envoy-X.Y.Z.apk). The input kind comes from the manifest, never the file name (ABS saves a
# lone upload as base.apk). Every tool runs in upstream's container (reproducible-builds/Dockerfile) via
# podman or docker; the build is upstream's reproducible-builds/build.sh (v2.3.4+) at its default in-container
# paths /tmp/envoy-reproducible-build/<commit>/project and /tmp/envoy-reproducible-cache, bind mounts of
# canonical/ and cache/ in this run's workspace (embedded OpenSSL and Dart paths depend on them).
# STEPS: args -> metadata + input kind -> tag -> clone -> per-run image -> build.sh -> flake bundletool
#        -> per-APK diff with earned exclusions -> manifest cross-check -> verdict -> YAML -> prune
#        build tree and caches unless ftbfs. No smartphone is required.
# CHANGELOG v0.4.0 = v0.3.9 + payload digests logged as [INFO] facts, no longer verdict inputs.

set -euo pipefail

EXEC_DIR="$(pwd -P)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.4.0"
readonly SCRIPT_NAME="envoy-v0.4.0_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256=""

readonly APP_ID="com.foundationdevices.envoy"
readonly REPO_URL="https://github.com/Foundation-Devices/envoy.git"
readonly REL_URL="https://github.com/Foundation-Devices/envoy/releases/download"
# Base image of upstream's Dockerfile (checked against the tag's Dockerfile after the clone).
readonly BASE_IMG="docker.io/nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c"

# Pre-clone JDK for apktool from the nixpkgs revision Envoy's flake.lock pins.
readonly NIXPKGS="github:NixOS/nixpkgs/4fd0f759fbe88b1a57902871cf4ba4a2e4f63355"
readonly AT_VER="3.0.3"
readonly AT_URL="https://github.com/iBotPeaches/Apktool/releases/download/v${AT_VER}/apktool_${AT_VER}.jar"
readonly AT_SHA="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"

readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

RUN_ID="$(date +%s)-$$"
readonly RUN_ID
STAGE=""; WORK_DIR=""; SCRATCH=""; OFFICIAL_DIR=""; OFFICIAL_MAIN=""; MODE=""; KIND_RULE=""; PRUNE=false
CT=(); CE=""; IMG=""; PULLED=false; ROOTLESS=false; NIXVOL=""; CRUN_ENV=()
VERDICT="not_reproducible"
VERSION_NAME=""; VERSION_CODE=""; SIGNER="unknown"; APP_HASH=""; COMMIT_HASH="unknown"
TAG=""; TAG_TYPE="unknown"; SDK=""; SDK_SRC=""; SPEC=""
SOURCE_REF=""; TAG_COMMIT=""; TAG_PUBSPEC=""; SDE="unknown"; FLAKE_SHA="unknown"; BT_VER="unknown"
MANIFEST=""; MANIFEST_SRC="not available"; MF_NOTE=""
PAY_AAB="n/a"; PAY_OFF="n/a"; PAY_BLT="n/a"; PAY_STATE="not compared"
RAW_TOTAL=0; UNACC_TOTAL=0; MISSING_TOTAL=0
ACC_SIGN=0; ACC_STAMP=0; ACC_MANI=0; ACC_ARSC=0
RESULT_DONE=false

log()      { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_err()  { printf '[ERROR] %s\n' "$*" >&2; }
log_ok()   { printf '[OK] %s\n' "$*"; }
section()  { printf '\n== %s ==\n  %s\n' "$1" "$(date)"; }

sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

# At most N lines without closing the pipe early (`head` would SIGPIPE under pipefail).
cap() { awk -v n="${1:-5}" 'NR<=n{print} {last=NR} END{if(last>n) printf "    ... %d more line(s); full listing saved\n", last-n}'; }

# Self-identification first, before argument parsing.
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

# A previous run's verdict must never survive this invocation.
rm -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml"

usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <play-split-dir|base.apk|envoy-X.Y.Z.apk> [--version <v>] [--arch <a>]
                      [--type <t>] [--commit <sha>] [--manifest <json>]
  --binary   REQUIRED. Directory of device-pulled Play splits, its base.apk, or one universal APK (GitHub
             envoy-X.Y.Z.apk, also when saved as base.apk). Kind from the manifest: isSplitRequired or
             sibling *.apk files = split set; a split= attribute is refused.
  --version  Optional, cross-checked; the authoritative version comes from the APK. --arch/--type: logged.
  --commit   Optional. Build this revision instead of the release tag; the pubspec cross-check stays fatal.
  --manifest Optional envoy-X.Y.Z-android-manifest.json; default: next to the binary, else GitHub release.
Environment: WS_DEVICE_SDK (split-mode sdkVersion); ENVOY_REPRODUCIBLE_BUILD_JOBS / _GRADLE_OPTS (docker-build.sh
             defaults); WS_NIX_VOLUME (existing volume for /nix instead of a per-run one; never removed).
Host needs: podman (preferred) or docker, no sudo. Exit: 0 reproducible, 1 not reproducible, 2 ftbfs/invalid.
USAGE
}

write_yaml() {
    local verdict="$1" notes="$2"
    { printf 'script_version: %s\n' "$SCRIPT_VERSION"
      printf 'verdict: %s\n' "$verdict"
      printf 'notes: |\n'
      printf '%s\n' "$notes" | sed 's/^/  /'
    } > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    RESULT_DONE=true; [[ "$verdict" == ftbfs ]] || PRUNE=true
    log "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

# Workspace envoy_verification_<version>_<epoch>-<pid>; staged until the version is read, then renamed.
finalize_workspace() {
    [[ -n "$STAGE" && -d "$STAGE" ]] || return 0
    WORK_DIR="${EXEC_DIR}/envoy_verification_${VERSION_NAME:-unknown}_${RUN_ID}"
    mv "$STAGE" "$WORK_DIR"; STAGE=""
}

# Fresh container per tool: official dir (ro) and workspace at host paths, canonical/ and cache/ at upstream's
# /tmp paths, /nix on a named volume. $1 = workdir. GITHUB_TOKEN only as a ro-mounted 0600 nix.conf.
crun() {
    local ws="${WORK_DIR:-$STAGE}" tok=()
    [[ -f "${HOME}/nix.conf" ]] && tok=(-v "${HOME}/nix.conf:/root/.config/nix/nix.conf:ro")
    "${CT[@]}" run --rm --label "envoy-repro=${RUN_ID}" -v "${OFFICIAL_DIR}:${OFFICIAL_DIR}:ro" \
        -v "${ws}:${ws}" -v "${ws}/canonical:/tmp/envoy-reproducible-build" -v "${ws}/cache:/tmp/envoy-reproducible-cache" \
        -v "${NIXVOL}:/nix" ${tok[@]+"${tok[@]}"} ${CRUN_ENV[@]+"${CRUN_ENV[@]}"} \
        --env XDG_CACHE_HOME=/tmp/envoy-reproducible-cache/xdg --env GIT_CONFIG_COUNT=1 \
        --env GIT_CONFIG_KEY_0=safe.directory --env GIT_CONFIG_VALUE_0='*' -w "$1" "$IMG" "${@:2}"
}
crm() { crun "${WORK_DIR:-$STAGE}" rm -rf "$@"; }   # container-written trees are root-owned under docker

# Hand container-written files back: rootless podman = unshare chown 0:0; rootful = chown in a container.
reclaim() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" && ${#CT[@]} -gt 0 && -n "$IMG" ]] || return 0
    if [[ "$ROOTLESS" == true && "$CE" == podman ]]; then "${CT[@]}" unshare chown -Rh 0:0 "$WORK_DIR" 2>/dev/null || true
    elif [[ "$ROOTLESS" != true ]]; then crun "$WORK_DIR" chown -Rh "$(id -u):$(id -g)" "$WORK_DIR" >/dev/null 2>&1 || true; fi
}

cleanup() {
    local rc=$?
    finalize_workspace
    if [[ ${#CT[@]} -gt 0 ]]; then
        "${CT[@]}" rm -f $("${CT[@]}" ps -aq --filter "label=envoy-repro=${RUN_ID}" 2>/dev/null) >/dev/null 2>&1 || true
        reclaim
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        chmod -R u+rwX "$WORK_DIR" 2>/dev/null || true
        rm -rf "${WORK_DIR}/scratch" 2>/dev/null || true
        if [[ "$PRUNE" == true ]]; then
            rm -rf "${WORK_DIR}/canonical" "${WORK_DIR}/cache" 2>/dev/null || true
            log "Pruned ${WORK_DIR}/canonical and cache (kept only on ftbfs)"
        fi
        local foreign
        foreign="$(find "$WORK_DIR" ! -uid "$(id -u)" 2>/dev/null | cap 5)"
        [[ -z "$foreign" ]] && log "Workspace ${WORK_DIR}: $(du -sh "$WORK_DIR" 2>/dev/null | awk '{print $1}'), all owned by uid $(id -u)" \
            || log_warn "Workspace entries NOT owned by uid $(id -u):"$'\n'"$foreign"
    fi
    # Per-run image and volume go. The base image stays even if this run pulled it: a parallel run may be
    # using it, and `rmi -f` would take that run's containers with it. A WS_NIX_VOLUME volume is not ours.
    if [[ ${#CT[@]} -gt 0 ]]; then
        [[ -n "$IMG" && "$IMG" != "$BASE_IMG" ]] && { "${CT[@]}" rmi -f "$IMG" >/dev/null 2>&1 || true; }
        [[ -n "$NIXVOL" && -z "${WS_NIX_VOLUME:-}" ]] && { "${CT[@]}" volume rm -f "$NIXVOL" >/dev/null 2>&1 || true; }
        log "Per-run image and volume removed; base image left in place"
    fi
    # An unexpected abort must still leave a result file, or ABS records nothing.
    if [[ "$RESULT_DONE" == false && $rc -ne 0 && $rc -ne "$EXIT_INVALID" ]]; then
        write_yaml "ftbfs" "Run aborted unexpectedly with status ${rc} before a verdict; see the terminal output."
        echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

die_invalid() { log_err "$1"; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"; }

fail() {
    local code="$EXIT_FAILED"
    [[ "$1" == "ftbfs" ]] && code="$EXIT_INVALID"
    log_err "$2"
    write_yaml "$1" "$2"
    echo "Exit code: ${code}"
    exit "$code"
}

# rc 0 = same, 1 = differs, >1 = diff could not run (never read as "identical").
DIFF_OUT=""
run_diff() {
    local rc=0
    DIFF_OUT="$("$@" 2>&1)" || rc=$?
    [[ $rc -le 1 ]] && return 0
    return "$rc"
}

# ---- Arguments
binary_arg=""; version_arg=""; arch_arg=""; type_arg=""; commit_arg=""; manifest_arg=""
need_arg() { [[ -n "${2:-}" && "${2:0:2}" != "--" ]] || die_invalid "Option $1 requires a value."; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)       need_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
        --version)      need_arg "$1" "${2:-}"; version_arg="$2"; shift 2 ;;
        --arch)         need_arg "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
        --type)         need_arg "$1" "${2:-}"; type_arg="$2"; shift 2 ;;
        --commit)       need_arg "$1" "${2:-}"; commit_arg="$2"; shift 2 ;;
        --manifest)     need_arg "$1" "${2:-}"; manifest_arg="$2"; shift 2 ;;
        -h|--help)      usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
        *)              log_warn "Ignoring unrecognised parameter: $1"; shift ;;   # never fatal
    esac
done

[[ "$(id -u)" -eq 0 ]] && die_invalid "Refusing to run as root; run as a normal user, no sudo is needed."
[[ -n "$binary_arg" ]] || { usage; die_invalid "--binary is required."; }
[[ -z "$manifest_arg" || -f "$manifest_arg" ]] || die_invalid "--manifest file does not exist: ${manifest_arg}"

# Main APK = the file given, or base.apk / the sole *.apk of a directory; the kind is decided in PHASE 0.
# Bad --binary contents are ftbfs, so ABS always gets a result file.
shopt -s nullglob
if [[ -f "$binary_arg" ]]; then
    OFFICIAL_DIR="$(cd "$(dirname "$binary_arg")" && pwd -P)"; OFFICIAL_MAIN="${OFFICIAL_DIR}/$(basename "$binary_arg")"
    [[ "$OFFICIAL_MAIN" == *.apk ]] || fail "ftbfs" "--binary must be an .apk file or a directory of APKs (got $(basename "$binary_arg"))."
elif [[ -d "$binary_arg" ]]; then
    OFFICIAL_DIR="$(cd "$binary_arg" && pwd -P)"; apks=("${OFFICIAL_DIR}"/*.apk)
    if [[ -f "${OFFICIAL_DIR}/base.apk" ]]; then OFFICIAL_MAIN="${OFFICIAL_DIR}/base.apk"
    elif [[ ${#apks[@]} -eq 1 ]]; then OFFICIAL_MAIN="${apks[0]}"
    else fail "ftbfs" "${OFFICIAL_DIR} holds ${#apks[@]} APK files and no base.apk; cannot pick the main APK."; fi
else
    fail "ftbfs" "--binary path does not exist: ${binary_arg}"
fi
SIBLINGS=(); for f in "${OFFICIAL_DIR}"/*.apk; do [[ "$f" == "$OFFICIAL_MAIN" ]] || SIBLINGS+=("$f"); done
shopt -u nullglob

[[ -n "${arch_arg}${type_arg}" ]] && log "--arch '${arch_arg}' / --type '${type_arg}' accepted (ABI comes from the artifact)"

# ---- Preflight (podman first, docker as fallback)
section "PRE-FLIGHT"
for c in podman docker; do command -v "$c" >/dev/null 2>&1 && "$c" info >/dev/null 2>&1 && { CE=$c; break; }; done
# Engine runs with the caller's own HOME/XDG: a workspace HOME would move rootless podman's storage.
CT=(env); kv=("HOME=$HOME"); for v in XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME; do [[ -n "${!v:-}" ]] && kv+=("$v=${!v}") || CT+=(-u "$v"); done
[[ -n "$CE" ]] && CT+=("${kv[@]}" "$CE") || CT=()
[[ ${#CT[@]} -gt 0 ]] || fail "ftbfs" "podman or docker is required (ABS rule 1); neither is usable here."
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || fail "ftbfs" "upstream's canonical builder requires x86_64 Linux."
if [[ "$CE" == podman ]]; then ROOTLESS="$("${CT[@]}" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)"
else grep -q rootless <<<"$("${CT[@]}" info --format '{{.SecurityOptions}}' 2>/dev/null)" && ROOTLESS=true || ROOTLESS=false; fi
log_ok "$("${CT[@]}" --version 2>/dev/null | head -1); rootless=${ROOTLESS}"

STAGE="$(mktemp -d "${EXEC_DIR}/.envoy_stage_${RUN_ID}.XXXXXX")"
mkdir -p "${STAGE}/comparison" "${STAGE}/built" "${STAGE}/tools/bin" "${STAGE}/home" "${STAGE}/scratch" "${STAGE}/canonical" "${STAGE}/cache"
# HOME is redirected into the workspace: nothing lands in the real HOME, no host state leaks in.
set_home() {
    export HOME="$1/home" XDG_CACHE_HOME="$1/home/.cache" XDG_CONFIG_HOME="$1/home/.config"
    mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
}
set_home "$STAGE"
# nix.conf = upstream's Dockerfile lines plus the access token for nix's github: fetches.
token_on()  { [[ -n "${GITHUB_TOKEN:-}" ]] || return 0; ( umask 077; printf '%s\n' 'experimental-features = nix-command flakes' 'sandbox = false' 'filter-syscalls = false' 'accept-flake-config = true' "access-tokens = github.com=${GITHUB_TOKEN}" > "${HOME}/nix.conf" ); }
token_off() { rm -f "${HOME}/nix.conf"; unset GITHUB_TOKEN; }
token_on

NIXVOL="${WS_NIX_VOLUME:-envoy-repro-${RUN_ID}}"
"${CT[@]}" image exists "$BASE_IMG" >/dev/null 2>&1 || "${CT[@]}" image inspect "$BASE_IMG" >/dev/null 2>&1 || PULLED=true
"${CT[@]}" pull -q "$BASE_IMG" >/dev/null 2>&1 || { PULLED=false; fail "ftbfs" "Could not pull ${BASE_IMG} with ${CE}."; }
IMG="$BASE_IMG"
log_ok "base image $([[ "$PULLED" == true ]] && echo 'pulled' || echo 'already present'); /nix volume ${NIXVOL}$([[ -n "${WS_NIX_VOLUME:-}" ]] && echo ' (WS_NIX_VOLUME, reused)')"
crun "$STAGE" nix --version >/dev/null 2>&1 || fail "ftbfs" "${CE} cannot run ${BASE_IMG} with the workspace mounted."

NIX=(nix --extra-experimental-features 'nix-command flakes')
if command -v git >/dev/null 2>&1; then GIT=(git); else GIT=(cgit); fi
cgit() { crun "${WORK_DIR:-$STAGE}" git "$@"; }
g() { "${GIT[@]}" -C "$SRC_DIR" "$@"; }
apktool() { crun "${WORK_DIR:-$STAGE}" "${NIX[@]}" shell "${NIXPKGS}#jdk17" --command java -Duser.home="${HOME}" -jar "$AT_JAR" "$@"; }

cat <<BANNER

== ENVOY (${APP_ID}) ANDROID VERIFICATION ==
 Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}
 Input:     ${binary_arg} (main APK $(basename "$OFFICIAL_MAIN"), ${#SIBLINGS[@]} sibling APK(s))
 Date:      $(date)
BANNER

# ---- Pinned tooling (apktool)
section "SETUP: PINNED TOOLING"
fetch_url() { # url dest -> 0 on success
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else crun "${WORK_DIR:-$STAGE}" curl -fsSL "$1" -o "$2"; fi
}
AT_JAR="${STAGE}/tools/apktool.jar"
fetch_url "$AT_URL" "$AT_JAR" || true
[[ -s "$AT_JAR" ]] || fail "ftbfs" "Could not download apktool from ${AT_URL}."
[[ "$(sha256_of "$AT_JAR")" == "$AT_SHA" ]] || fail "ftbfs" "apktool.jar SHA-256 mismatch (expected ${AT_SHA}); unverified tool refused."
log_ok "apktool ${AT_VER} verified: ${AT_SHA}"
APKTOOL_FRAME="${STAGE}/home/apktool-frames"; mkdir -p "$APKTOOL_FRAME"

# ---- Official metadata, read before any clone (the tag is chosen from the artifact)
section "PHASE 0: OFFICIAL BINARY METADATA"
MD="${STAGE}/scratch/meta"
apktool d -s -f --frame-path "$APKTOOL_FRAME" -o "$MD" "$OFFICIAL_MAIN" > "${STAGE}/apktool.log" 2>&1 \
    || { cap 5 < "${STAGE}/apktool.log"; fail "ftbfs" "apktool could not decode ${OFFICIAL_MAIN}."; }
yml() { sed -n "s/^[[:space:]]*$1:[[:space:]]*'\{0,1\}\([^']*\)'\{0,1\}[[:space:]]*$/\1/p" "${MD}/apktool.yml" | head -1; }
VERSION_NAME="$(yml versionName)"
VERSION_CODE="$(yml versionCode)"
TARGET_SDK="$(yml targetSdkVersion)"
MIN_SDK="$(yml minSdkVersion)"
pkg="$(sed -n 's/.*package="\([^"]*\)".*/\1/p' "${MD}/AndroidManifest.xml" | head -1)"

[[ "$pkg" == "$APP_ID" ]] || fail "ftbfs" "Package mismatch: the APK reports '${pkg}', expected ${APP_ID}; wrong artifact."
[[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "ftbfs" "Unexpected versionName '${VERSION_NAME}' in the APK."
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || fail "ftbfs" "Unexpected versionCode '${VERSION_CODE}' in the APK."
# Input kind from the manifest: split= refused; isSplitRequired = Play base; neither = universal.
grep -q ' split="' "${MD}/AndroidManifest.xml" && fail "ftbfs" "$(basename "$OFFICIAL_MAIN") declares a split attribute: a config split, not a base or universal APK. Pass the Play split directory."
if grep -q 'isSplitRequired="true"' "${MD}/AndroidManifest.xml"; then MODE="split"; KIND_RULE='manifest has isSplitRequired="true"'
elif [[ ${#SIBLINGS[@]} -gt 0 ]]; then MODE="split"; KIND_RULE="${#SIBLINGS[@]} sibling *.apk file(s) next to $(basename "$OFFICIAL_MAIN")"
else MODE="universal"; KIND_RULE="no split attribute, no isSplitRequired, no sibling APKs; name $(basename "$OFFICIAL_MAIN") ignored"; fi
log_ok "Input kind: ${MODE} (rule: ${KIND_RULE})"
OFFICIAL_SPLITS=("$OFFICIAL_MAIN" "${SIBLINGS[@]}")
log_ok "Package verified: ${pkg}"
log_ok "Version: ${VERSION_NAME} (versionCode ${VERSION_CODE})"
[[ -n "$version_arg" && "$version_arg" != "$VERSION_NAME" ]] && log_warn "--version '${version_arg}' differs from the APK's '${VERSION_NAME}'; using the APK's"
APP_HASH="$(sha256_of "$OFFICIAL_MAIN")"
log "$(basename "$OFFICIAL_MAIN") SHA-256: ${APP_HASH}"
log "Official APK(s):"
for f in "${OFFICIAL_SPLITS[@]}"; do printf '  %s  %s\n' "$(sha256_of "$f")" "$(basename "$f")"; done

finalize_workspace
readonly WORK_DIR
set_home "$WORK_DIR"
SCRATCH="${WORK_DIR}/scratch"; SRC_DIR="${WORK_DIR}/src"
AT_JAR="${WORK_DIR}/tools/apktool.jar"; APKTOOL_FRAME="${HOME}/apktool-frames"
log "Workspace: ${WORK_DIR}"

if [[ "$MODE" == "split" ]]; then
    if [[ -n "${WS_DEVICE_SDK:-}" ]]; then
        [[ "${WS_DEVICE_SDK}" =~ ^[0-9]+$ ]] || die_invalid "WS_DEVICE_SDK must be numeric, got '${WS_DEVICE_SDK}'."
        SDK="$WS_DEVICE_SDK"; SDK_SRC="supplied via WS_DEVICE_SDK"
    elif [[ "$TARGET_SDK" =~ ^[0-9]+$ ]]; then
        SDK="$TARGET_SDK"; SDK_SRC="targetSdkVersion from base.apk (an app declaration, NOT the device's API level)"
    elif [[ "$MIN_SDK" =~ ^[0-9]+$ ]]; then
        SDK="$MIN_SDK"; SDK_SRC="minSdkVersion from base.apk; targetSdkVersion unreadable"
    else
        SDK=35; SDK_SRC="fallback 35; no SDK value readable"
    fi
    log "device-spec sdkVersion: ${SDK} (${SDK_SRC})"
fi

# Release manifest = upstream's provenance record; cross-checks are informational, the comparison decides.
mf() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*$/\1/p" "$MANIFEST" | head -1; }
MF_NAME="envoy-${VERSION_NAME}-android-manifest.json"
if [[ -n "$manifest_arg" ]]; then
    MANIFEST="$(cd "$(dirname "$manifest_arg")" && pwd -P)/$(basename "$manifest_arg")"; MANIFEST_SRC="--manifest ${MANIFEST}"
elif [[ -f "${OFFICIAL_DIR}/${MF_NAME}" ]]; then
    MANIFEST="${OFFICIAL_DIR}/${MF_NAME}"; MANIFEST_SRC="next to the binary: ${MANIFEST}"
elif fetch_url "${REL_URL}/v${VERSION_NAME}/${MF_NAME}" "${WORK_DIR}/${MF_NAME}" 2>/dev/null && [[ -s "${WORK_DIR}/${MF_NAME}" ]]; then
    MANIFEST="${WORK_DIR}/${MF_NAME}"; MANIFEST_SRC="downloaded from ${REL_URL}/v${VERSION_NAME}/${MF_NAME}"
else
    rm -f "${WORK_DIR}/${MF_NAME}"; log_warn "No release manifest next to the binary or on the GitHub release; cross-checks skipped."
fi
if [[ -n "$MANIFEST" ]]; then
    log_ok "Release manifest: ${MANIFEST_SRC} (sha256 $(sha256_of "$MANIFEST"))"
    [[ "$(mf versionCode)" == "$VERSION_CODE" ]] || fail "ftbfs" "Release manifest versionCode $(mf versionCode) is not the APK's ${VERSION_CODE}; wrong manifest."
    if [[ "$MODE" == "universal" ]]; then
        [[ "$(mf apkSha256)" == "$APP_HASH" ]] && log_ok "Supplied APK sha256 equals the manifest's apkSha256 (it is the GitHub release APK)" \
            || { log_warn "Supplied APK sha256 differs from the manifest's apkSha256 $(mf apkSha256)"; MF_NOTE="supplied APK is NOT the manifest's apkSha256; "; }
    fi
fi

# ---- Source
section "PHASE 1: SOURCE"
TAG="v${VERSION_NAME}"
"${GIT[@]}" clone "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || fail "ftbfs" "git clone failed for ${REPO_URL}."
g rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1 \
    || fail "ftbfs" "Upstream has no tag ${TAG} for version ${VERSION_NAME}; the artifact cannot be tied to published source."
TAG_COMMIT="$(g rev-parse "${TAG}^{commit}")"
TAG_PUBSPEC="$(g show "${TAG}:pubspec.yaml" 2>/dev/null | sed -n 's/^version:[[:space:]]*//p' | head -1)"

if [[ -n "$commit_arg" ]]; then
    g rev-parse --verify "${commit_arg}^{commit}" >/dev/null 2>&1 || fail "ftbfs" "--commit ${commit_arg} is not a commit in ${REPO_URL}."
    g checkout -q "$commit_arg" || fail "ftbfs" "Could not check out ${commit_arg}."
    SOURCE_REF="commit ${commit_arg} (explicit --commit; NOT the release tag)"
    log_warn "Building an explicit commit, not ${TAG} (${TAG_COMMIT}, pubspec ${TAG_PUBSPEC:-unknown}); weaker provenance."
else
    g checkout -q "$TAG" || fail "ftbfs" "Could not check out ${TAG}."
    SOURCE_REF="tag ${TAG}"
fi
COMMIT_HASH="$(g rev-parse HEAD)"
[[ -z "$(g status --porcelain)" ]] || fail "ftbfs" "Working tree not clean after checkout; refusing to build."
TAG_TYPE="$(g cat-file -t "$TAG" 2>/dev/null || echo unknown)"
SDE="$(g show -s --format=%ct HEAD)"
FLAKE_SHA="$(sha256_of "${SRC_DIR}/flake.lock")"
log_ok "Building ${SOURCE_REF} at ${COMMIT_HASH} (SOURCE_DATE_EPOCH ${SDE}; flake.lock sha256 ${FLAKE_SHA})"

# Source cross-check: a mismatch means the revision does not describe the artifact.
pv="$(sed -n 's/^version:[[:space:]]*//p' "${SRC_DIR}/pubspec.yaml" | head -1)"
[[ "$pv" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)$ ]] || fail "ftbfs" "pubspec.yaml version '${pv}' is not X.Y.Z+B; cannot cross-check."
expect_code=$(( BASH_REMATCH[1]*1000000 + BASH_REMATCH[2]*10000 + BASH_REMATCH[3]*100 + BASH_REMATCH[4] ))
pvn="${pv%%+*}"
[[ "$pvn" == "$VERSION_NAME" && "$expect_code" == "$VERSION_CODE" ]] \
    || fail "ftbfs" "Source/artifact mismatch: ${SOURCE_REF}'s pubspec ${pv} yields ${pvn} / versionCode ${expect_code}, the APK reports ${VERSION_NAME} / ${VERSION_CODE}.$( [[ -z "$commit_arg" ]] && printf ' Pass the commit whose pubspec yields %s with --commit.' "$VERSION_CODE" )"
log_ok "Source cross-check: pubspec ${pv} yields versionCode ${expect_code}, matching the artifact"

RB="${SRC_DIR}/reproducible-builds"
[[ -f "${RB}/build.sh" && -f "${RB}/Dockerfile" ]] || fail "ftbfs" "${SOURCE_REF} has no reproducible-builds/build.sh + Dockerfile (upstream since v2.3.4); for 2.3.3 and earlier run envoy-v0.3.2_build.sh."

if [[ -n "$MANIFEST" ]]; then
    for pair in "gitCommit:${COMMIT_HASH}" "sourceDateEpoch:${SDE}" "flakeLockSha256:${FLAKE_SHA}"; do
        k="${pair%%:*}"; v="${pair#*:}"
        [[ "$(mf "$k")" == "$v" ]] && log_ok "manifest ${k} matches ${SOURCE_REF}" \
            || { log_warn "manifest ${k} is $(mf "$k") but ${SOURCE_REF} gives ${v}"; MF_NOTE="${MF_NOTE}${k} mismatch (manifest $(mf "$k") vs source ${v}); "; }
    done
fi

# Upstream's container, built per run from the tag's Dockerfile.
section "PHASE 1b: UPSTREAM CONTAINER IMAGE"
grep -q "^FROM ${BASE_IMG#docker.io/}" "${RB}/Dockerfile" || log_warn "the tag's Dockerfile does not pin ${BASE_IMG#docker.io/}; metadata was read on a different base image"
RUN_IMG="localhost/envoy-repro:${RUN_ID}"
if "${CT[@]}" build --platform linux/amd64 $([[ "$CE" == podman ]] && echo --layers=false || echo --force-rm) -t "$RUN_IMG" -f "${RB}/Dockerfile" "$RB" > "${WORK_DIR}/image.log" 2>&1; then IMG="$RUN_IMG"; else
    cap 5 < "${WORK_DIR}/image.log"; fail "ftbfs" "${CE} build of ${RB}/Dockerfile failed; see ${WORK_DIR}/image.log."
fi
log_ok "image ${IMG} ($("${CT[@]}" image inspect --format '{{.Id}}' "$IMG" 2>/dev/null | cut -c1-19)) from the tag's Dockerfile"

# aapt2, apksigner, bundletool, unzip, python3, diff: the flake's reproducibleAndroid shell in the container.
nixrun() { crun "$SRC_DIR" nix develop "${SRC_DIR}#reproducibleAndroid" --command "$@"; }
if nixrun true > "${WORK_DIR}/devshell.log" 2>&1; then :; else
    cap 5 < "${WORK_DIR}/devshell.log"; fail "ftbfs" "nix develop ${SRC_DIR}#reproducibleAndroid failed; see ${WORK_DIR}/devshell.log."
fi
BT_VER="$(nixrun bundletool version 2>/dev/null | awk '{print $NF}' | tail -1 || true)"; BT_VER="${BT_VER:-unknown}"
# bundletool's own aapt2 can't run in the NixOS image (no /lib64 loader): use the flake's.
AAPT2="$(nixrun sh -c 'command -v aapt2' 2>/dev/null | tail -1 || true)"
[[ "$AAPT2" == /nix/store/* ]] || fail "ftbfs" "The dev shell provides no aapt2 for bundletool (got '${AAPT2}')."
log_ok "dev shell ready; bundletool ${BT_VER}; aapt2 ${AAPT2}"
SIGNER="$(nixrun apksigner verify --print-certs "$OFFICIAL_MAIN" 2>/dev/null | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | tail -1 || true)"
SIGNER="${SIGNER:-unknown}"
log "Signer SHA-256: ${SIGNER}"

section "PHASE 2: BUILD VIA UPSTREAM reproducible-builds/build.sh (30-90 min cold)"
# build.sh clones HEAD into /tmp/envoy-reproducible-build/<commit>/project and caches under
# /tmp/envoy-reproducible-cache (CARGO_HOME, GRADLE_USER_HOME, PUB_CACHE, TMPDIR): this workspace's canonical/
# and cache/, so the OpenSSL and Dart paths embedded in the libraries equal upstream's. Jobs and Gradle
# option defaults are docker-build.sh's. The checkout is kept and pruned by the EXIT trap unless ftbfs.
token_off; log "GitHub token file removed before the build"
CANON_IN="/tmp/envoy-reproducible-build/${COMMIT_HASH}/project"
log "canonical checkout in the container: ${CANON_IN}  <-  host ${WORK_DIR}/canonical/${COMMIT_HASH}/project"
log "cache in the container: /tmp/envoy-reproducible-cache  <-  host ${WORK_DIR}/cache"
cp "${RB}/shasum" "${WORK_DIR}/tools/bin/shasum" && chmod 755 "${WORK_DIR}/tools/bin/shasum"   # the Dockerfile's shasum shim
CRUN_ENV=(--env "ENVOY_REPRODUCIBLE_BUILD_JOBS=${ENVOY_REPRODUCIBLE_BUILD_JOBS:-2}" --env ENVOY_KEEP_REPRODUCIBLE_WORKDIR=1
    --env "ENVOY_REPRODUCIBLE_GRADLE_OPTS=${ENVOY_REPRODUCIBLE_GRADLE_OPTS:--Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8 -Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false -Dorg.gradle.daemon=false}")
log "BUILD_JOBS=${ENVOY_REPRODUCIBLE_BUILD_JOBS:-2 (default)}  GRADLE_OPTS=${ENVOY_REPRODUCIBLE_GRADLE_OPTS:-<docker-build.sh default>}"
AAB="${WORK_DIR}/built/app-release.aab"
if crun "$SRC_DIR" bash -lc 'set -euo pipefail; export PATH="$1:$PATH"; ./reproducible-builds/build.sh --output "$2"' bash "${WORK_DIR}/tools/bin" "$AAB" 2>&1 | tee "${WORK_DIR}/build.log"; then :; else
    fail "ftbfs" "upstream reproducible-builds/build.sh exited non-zero. See ${WORK_DIR}/build.log."
fi
CRUN_ENV=()
[[ -f "$AAB" ]] || fail "ftbfs" "build.sh reported success but ${AAB} does not exist."
log_ok "AAB built: $(sha256_of "$AAB")"

# Payload digest = upstream's apkdiff.archive_payload_digest: sha256 over sorted "name\0sha256(content)\n"
# of every file entry, minus signing entries and the stamp.
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
log "AAB payload sha256: ${PAY_AAB}"
if [[ -n "$MANIFEST" ]]; then
    [[ "$(mf aabPayloadSha256)" == "$PAY_AAB" ]] && log "built AAB payload equals the manifest's aabPayloadSha256" \
        || log "built AAB payload differs from the manifest's aabPayloadSha256 $(mf aabPayloadSha256): BUNDLE-METADATA/com.android.tools/r8.json records R8 buildTimeNs (aabdiff.py strips it)"
fi

# ---- Derive APKs with the flake's bundletool (what upstream uses). No keystore: unsigned, see signingState.
section "PHASE 3: DERIVE APK(S) FROM THE AAB"
if [[ "$MODE" == "universal" ]]; then
    nixrun bundletool build-apks --bundle="$AAB" --output="${WORK_DIR}/built.apks" --mode=universal --aapt2="$AAPT2" --overwrite \
        || fail "ftbfs" "bundletool build-apks --mode=universal failed."
    nixrun unzip -p "${WORK_DIR}/built.apks" universal.apk > "${WORK_DIR}/built/universal.apk" \
        || fail "ftbfs" "Could not extract universal.apk from built.apks."
    [[ -s "${WORK_DIR}/built/universal.apk" ]] || fail "ftbfs" "universal.apk is empty."
else
    ABIS=(); DEN=""; LOCS=()
    for f in "${OFFICIAL_SPLITS[@]}"; do
        [[ "$f" == "$OFFICIAL_MAIN" ]] && continue
        c="$(basename "$f")"; c="${c%.apk}"; c="${c#split_config.}"
        case "$c" in
            arm64_v8a) ABIS+=("arm64-v8a") ;; armeabi_v7a) ABIS+=("armeabi-v7a") ;; x86_64) ABIS+=("x86_64") ;; x86) ABIS+=("x86") ;;
            ldpi) DEN=120 ;; mdpi) DEN=160 ;; tvdpi) DEN=213 ;; hdpi) DEN=240 ;; xhdpi) DEN=320 ;; xxhdpi) DEN=480 ;; xxxhdpi) DEN=640 ;;
            [a-z][a-z]|[a-z][a-z]_[A-Za-z]*) LOCS+=("${c//_/-}") ;;
            *) fail "ftbfs" "Unrecognised split config '${c}' in the official set; refusing to guess a device spec." ;;
        esac
    done
    [[ ${#ABIS[@]} -eq 0 ]] && fail "ftbfs" "No ABI split in the official set; cannot build a device spec."
    [[ -z "$DEN" ]] && fail "ftbfs" "No density split in the official set; cannot build a device spec."
    [[ ${#LOCS[@]} -eq 0 ]] && LOCS=("en")
    j() { local o=""; for v in "$@"; do o="${o}\"${v}\","; done; echo "[${o%,}]"; }
    SPEC="${WORK_DIR}/device-spec.json"
    printf '{"supportedAbis":%s,"supportedLocales":%s,"screenDensity":%s,"sdkVersion":%s}\n' "$(j "${ABIS[@]}")" "$(j "${LOCS[@]}")" "$DEN" "$SDK" > "$SPEC"
    cat "$SPEC"
    nixrun bundletool build-apks --bundle="$AAB" --output="${WORK_DIR}/built.apks" --device-spec="$SPEC" --aapt2="$AAPT2" --overwrite \
        || fail "ftbfs" "bundletool build-apks failed."
    nixrun unzip -q -o "${WORK_DIR}/built.apks" 'splits/*.apk' -d "${WORK_DIR}/bt" || fail "ftbfs" "Could not extract splits from built.apks."
    cp "${WORK_DIR}"/bt/splits/*.apk "${WORK_DIR}/built/" || fail "ftbfs" "No split APKs produced by bundletool."
fi
log "built APK(s):"
for f in "${WORK_DIR}"/built/*.apk; do printf '  %s  %s\n' "$(sha256_of "$f")" "$(basename "$f")"; done

# ---- Comparison
section "PHASE 4: PER-APK COMPARISON"
OFF_ROOT="${SCRATCH}/o"; BLT_ROOT="${SCRATCH}/b"
re_esc() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/]/\\&/g'; }
OFF_RE="$(re_esc "$OFF_ROOT")"

# Config key from the APK's own split= attribute (file names differ between Play and bundletool).
cfg_of() {
    local s
    s="$(nixrun aapt2 dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1 || true)"
    printf '%s' "${s#config.}"
}

declare -A OFF BLT
add_key() { # array_name key file — a collision would silently drop a supplied APK
    local -n arr="$1"
    [[ -n "${arr[$2]:-}" ]] && fail "ftbfs" "Two APKs map to config key '$2' ($(basename "${arr[$2]}") and $(basename "$3")); ambiguous set."
    arr["$2"]="$3"
}
if [[ "$MODE" == "universal" ]]; then
    OFF[universal]="$OFFICIAL_MAIN"; BLT[universal]="${WORK_DIR}/built/universal.apk"
else
    # No split attribute = base; a second such file collides on 'base' in add_key.
    for f in "${OFFICIAL_SPLITS[@]}"; do k="$(cfg_of "$f")"; [[ -z "$k" ]] && k="base"; add_key OFF "$k" "$f"; done
    for f in "${WORK_DIR}"/built/*.apk; do k="$(cfg_of "$f")"; [[ -z "$k" ]] && k="base"; add_key BLT "$k" "$f"; done
fi
MAIN_KEY="$([[ "$MODE" == universal ]] && echo universal || echo base)"

for k in "${!OFF[@]}"; do
    f="${OFF[$k]}"
    bd="$(nixrun aapt2 dump badging "$f" 2>/dev/null || true)"
    p2="$(printf '%s' "$bd" | sed -n "s/.*package: name='\([^']*\)'.*/\1/p" | head -1)"
    v2="$(printf '%s' "$bd" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | head -1)"
    [[ "$p2" == "$APP_ID" ]] || fail "ftbfs" "$(basename "$f") reports package '${p2}', expected ${APP_ID}; set not coherent."
    [[ "$v2" == "$VERSION_CODE" ]] || fail "ftbfs" "$(basename "$f") reports versionCode '${v2}', expected ${VERSION_CODE}; set mixes versions."
    s2="$(nixrun apksigner verify --print-certs "$f" 2>/dev/null | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -1 || true)"
    [[ -n "$s2" ]] || fail "ftbfs" "$(basename "$f") has no verifiable signature; unsigned or damaged official artifact."
    [[ "$s2" == "$SIGNER" ]] || fail "ftbfs" "$(basename "$f") is signed by ${s2} but $(basename "$OFFICIAL_MAIN") by ${SIGNER}; set not coherent."
done
log_ok "Identity verified: ${#OFF[@]} official APK(s) share package, versionCode and signer"
[[ ${#OFF[@]} -eq ${#OFFICIAL_SPLITS[@]} ]] || fail "ftbfs" "${#OFFICIAL_SPLITS[@]} official files but only ${#OFF[@]} distinct config keys."

# Root META-INF SIGNING files only, by NAME, official side only (built-only = material).
SIGN_NAME='[^/]*(\.(SF|RSA|DSA|EC)|MANIFEST\.MF)'

# `Only in <official>: META-INF` is the whole dir: earned only if every entry is a signing file.
metainf_dir_ok() {
    local o="$1" entries bad
    entries="$(nixrun unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -E '^META-INF/' || true)"
    [[ -n "$entries" ]] || { echo "      META-INF dir: unlistable -> material"; return 1; }
    bad="$(printf '%s\n' "$entries" | grep -vE "^META-INF/${SIGN_NAME}$" || true)"
    if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
        echo "      META-INF dir: contains non-signing entries -> material:"
        printf '%s\n' "$bad" | cap 5 | sed 's/^/        /'
        return 1
    fi
    echo "      META-INF dir: official-only, $(printf '%s\n' "$entries" | grep -c '^') signing entry(ies):"
    printf '%s\n' "$entries" | cap 5 | sed 's/^/        /'
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

# Earned only when the sole delta is Play's meta-data, official side, blocks/names/values in equal number.
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

# resources.arsc: decode both and require the decoded res/ tree to be identical.
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

# Signing state as MEASURED, never assumed. Root META-INF shows only v1; apksigner is the authority.
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
    echo "  official: $(basename "$o")  sha256 $(sha256_of "$o")"
    echo "  built:    $(basename "$b")  sha256 $(sha256_of "$b")"

    crm "$OFF_ROOT" "$BLT_ROOT"; mkdir -p "$OFF_ROOT" "$BLT_ROOT"
    nixrun unzip -q -o "$o" -d "$OFF_ROOT" || fail "ftbfs" "Could not unzip $(basename "$o")."
    nixrun unzip -q -o "$b" -d "$BLT_ROOT" || fail "ftbfs" "Could not unzip $(basename "$b")."
    echo "  entries: $(find "$OFF_ROOT" -type f | wc -l) official, $(find "$BLT_ROOT" -type f | wc -l) built"

    while IFS= read -r so; do
        rel="${so#"$OFF_ROOT"/}"
        if [[ -f "${BLT_ROOT}/${rel}" ]]; then
            [[ "$(sha256_of "$so")" == "$(sha256_of "${BLT_ROOT}/${rel}")" ]] && st=MATCH || st=DIFFER
            echo "  native ${st} ${rel}"
        else
            echo "  native MISSING-IN-BUILT ${rel}"
        fi
    done < <(find "$OFF_ROOT" -name '*.so' -type f | sort)

    run_diff nixrun diff -rq "$OFF_ROOT" "$BLT_ROOT" \
        || fail "ftbfs" "diff could not compare ${cfg} (exit >1); an unreadable comparison is not identical."
    raw="$DIFF_OUT"
    printf '%s\n' "$raw" > "${WORK_DIR}/comparison/diff-unzipped-${cfg}.txt"
    n=$(printf '%s\n' "$raw" | grep -vc '^$' || true)
    echo "  raw diffs: ${n}   (full list: comparison/diff-unzipped-${cfg}.txt)"
    [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | grep -v '^$' | cap 5 | sed 's/^/    /'

    # Each class matches the EXACT raw line anchored to the extraction roots.
    sign_lines="$(printf '%s\n' "$raw" | grep -E "^Only in ${OFF_RE}/META-INF: ${SIGN_NAME}$|^Files ${OFF_RE}/META-INF/${SIGN_NAME} and " || true)"
    c_sign=$(printf '%s\n' "$sign_lines" | grep -vc '^$' || true)
    c_mdir=$(printf '%s\n' "$raw" | grep -Fxc "Only in ${OFF_ROOT}: META-INF" || true)
    c_stamp=$(printf '%s\n' "$raw" | grep -Fxc "Only in ${OFF_ROOT}: stamp-cert-sha256" || true)
    c_mani=$(printf '%s\n' "$raw" | grep -Fxc "Files ${OFF_ROOT}/AndroidManifest.xml and ${BLT_ROOT}/AndroidManifest.xml differ" || true)
    c_arsc=$(printf '%s\n' "$raw" | grep -Fxc "Files ${OFF_ROOT}/resources.arsc and ${BLT_ROOT}/resources.arsc differ" || true)

    a_sign=0; a_stamp=0; a_mani=0; a_arsc=0
    echo "  accepted-class evidence"
    [[ "$c_sign" -gt 0 ]] && { a_sign=$c_sign; echo "      signing: ${c_sign} root META-INF entries, official-only or two-sided"; }
    [[ "$c_mdir" -eq 1 ]] && { metainf_dir_ok "$o" && a_sign=$((a_sign + 1)) || echo "      META-INF dir: NOT EARNED -> material"; }
    [[ "$c_stamp" -eq 1 ]] && { stamp_ok "$o" && a_stamp=1 || echo "      stamp: NOT EARNED -> material"; }
    [[ "$c_mani" -eq 1 ]] && { manifest_ok "$o" "$b" "$cfg" && a_mani=1 || echo "      manifest: NOT EARNED -> material"; }
    [[ "$c_arsc" -eq 1 ]] && { arsc_ok "$o" "$b" "$cfg" && a_arsc=1 || echo "      arsc: NOT EARNED -> material"; }

    acc=$((a_sign + a_stamp + a_mani + a_arsc))
    [[ "$acc" -le "$n" ]] || fail "ftbfs" "Internal comparison error on ${cfg}: ${acc} accepted differences but only ${n} raw; no verdict from broken accounting."
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

# Universal mode: payload digests are logged facts, not verdict inputs.
if [[ "$MODE" == "universal" ]]; then
    PAY_OFF="$(payload_of "$OFFICIAL_MAIN" 2>/dev/null || echo error)"
    PAY_BLT="$(payload_of "${BLT[universal]}" 2>/dev/null || echo error)"
    if [[ "$PAY_OFF" == "$PAY_BLT" && "$PAY_OFF" != error ]]; then PAY_STATE="matches"; log "payload digest MATCH: ${PAY_OFF} (official and built)"; else
        PAY_STATE="differs"; log "payload digest differs: official ${PAY_OFF}, built ${PAY_BLT}. Cause when only resources.arsc differs: upstream CI derives with bundletool's embedded aapt2, we use the flake's build-tools 35.0.0 aapt2 via --aapt2; decoded res/ is the evidence"
    fi
    [[ -n "$MANIFEST" ]] && log "manifest apkPayloadSha256 $(mf apkPayloadSha256) $([[ "$(mf apkPayloadSha256)" == "$PAY_BLT" ]] && echo equals || echo 'differs from') the built payload"
fi

section "RESULT"
log "Detail: ${WORK_DIR}/comparison/ (summary.txt, diff-unzipped-<apk>.txt); build log: ${WORK_DIR}/build.log"
echo ""
echo "===== Begin Results ====="
echo "appId:            ${APP_ID}"
echo "signer:           ${SIGNER}"
echo "apkVersionName:   ${VERSION_NAME}"
echo "apkVersionCode:   ${VERSION_CODE}"
echo "verdict:          ${VERDICT}"
echo "appHash:          ${APP_HASH}"
echo "commit:           ${COMMIT_HASH}"
echo "scriptVersion:    ${SCRIPT_VERSION}"
echo "scriptHash:       ${SCRIPT_SHA256}"
echo ""
echo "Diff:"
if [[ "$RAW_TOTAL" -eq 0 ]]; then echo "(no differing entries)"; else cat "${WORK_DIR}/comparison"/diff-unzipped-*.txt 2>/dev/null | grep -v '^$' | cap 5; fi
echo ""
echo "Revision, tag (and its signature):"
echo "Tag: ${TAG} ($([[ "$TAG_TYPE" == "commit" ]] && echo 'lightweight, no signature possible' || echo "$TAG_TYPE"))"
echo "Built from: ${SOURCE_REF}"
[[ -n "$commit_arg" ]] && echo "NOTE: built from an UNTAGGED commit; ${TAG} (${TAG_COMMIT}, pubspec ${TAG_PUBSPEC:-unknown}) does not describe the artifact."
echo ""
echo "===== End Results ====="
echo ""
# Measured facts the YAML notes do not carry.
echo "inputKind:        ${MODE} (rule: ${KIND_RULE}); appHash = $(basename "$OFFICIAL_MAIN") as supplied"
echo "signingState:     $(signing_state)"
echo "bundletool:       ${BT_VER} from the flake's nixpkgs (what upstream derives its APKs with)"
echo "container:        ${CE} (rootless=${ROOTLESS}), image ${IMG} from the tag's Dockerfile on ${BASE_IMG#docker.io/}"
echo "canonicalPath:    ${CANON_IN} in the container <- ${WORK_DIR}/canonical"
echo "workspacePath:    ${WORK_DIR} (canonical/, cache/ pruned unless ftbfs)"
echo ""

write_yaml "$VERDICT" "Envoy ${MODE} input, built with upstream's reproducible-builds/build.sh at ${SOURCE_REF} (commit ${COMMIT_HASH}, SOURCE_DATE_EPOCH ${SDE}, flake.lock ${FLAKE_SHA}) in upstream's container (${CE}, tag's Dockerfile on ${BASE_IMG#docker.io/}) at its default path ${CANON_IN}, unsigned; APK(s) derived with the flake's bundletool ${BT_VER}$([[ "$MODE" == universal ]] && echo ' --mode=universal' || echo " and device spec $(cat "$SPEC") (sdkVersion ${SDK}: ${SDK_SRC})"). ${RAW_TOTAL} raw difference(s); ${ACC_TOTAL} earned exclusions - signing ${ACC_SIGN} (root META-INF signing names, official-side only), SourceStamp ${ACC_STAMP}, AndroidManifest ${ACC_MANI} (Play meta-data only), resources.arsc ${ACC_ARSC} (decoded res/ identical). ${UNACC_TOTAL} UNACCOUNTED difference(s); ${MISSING_TOTAL} APK(s) unmatched.$([[ "$MODE" == universal ]] && echo " APK payload digest ${PAY_STATE} (official ${PAY_OFF}, built ${PAY_BLT}), logged, not a verdict input: arsc bytes depend on the aapt2 build.") AAB payload ${PAY_AAB} logged, not a verdict input: r8.json records R8 buildTimeNs. Release manifest: ${MANIFEST_SRC}; ${MF_NOTE:-$([[ -n "$MANIFEST" ]] && echo 'gitCommit, sourceDateEpoch and flakeLockSha256 match' || echo 'no cross-checks')}. Official $(basename "$OFFICIAL_MAIN") SHA-256 ${APP_HASH}. Rust and Dart git dependencies fetched at the lockfile-pinned refs, not independently verified."

if [[ "$VERDICT" == "reproducible" ]]; then
    log_ok "Verdict: reproducible -- zero unaccounted differences"
    echo "Exit code: ${EXIT_SUCCESS}"
    exit "${EXIT_SUCCESS}"
fi
log_warn "Verdict: not_reproducible -- ${UNACC_TOTAL} unaccounted, ${MISSING_TOTAL} unmatched APK(s)"
echo "Exit code: ${EXIT_FAILED}"
exit "${EXIT_FAILED}"
