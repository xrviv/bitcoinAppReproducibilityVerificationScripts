#!/bin/bash
# envoy_build.sh — Envoy (com.foundationdevices.envoy) Android reproducible build verification
# Version:       v0.2.6
# Organization:  WalletScrutiny.com
# Project:       https://github.com/Foundation-Devices/envoy
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes
# only. No warranty is provided regarding security, functionality, or fitness for any particular
# purpose. Users assume all risks associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations. The
# developers assume no liability for any misuse or legal consequences arising from use.
#
# SCOPE: Google Play App Bundle delivery. Envoy's checked-in release environment is Nix, not a
# container (.github/workflows/android-nix.yml), and ABS rule 1 permits nix with flakes. The
# build runs inside `nix develop` at the RELEASE TAG. Artifact metadata is read first, using a
# pinned apktool jar under a pinned nixpkgs JDK, so tag selection never depends on whatever
# `main` happens to be today. bundletool and apktool are SHA-256-pinned jars.
#
# STEPS: parse args -> read metadata from base.apk with pinned tooling -> derive the tag ->
#        clone and check out that tag -> flutter pub get -> unsigned AAB -> device spec ->
#        bundletool build-apks -> per-split unzip and diff -> earned acceptance -> verdict -> YAML.
#
# NO SMARTPHONE IS REQUIRED. ABI, density and locales come from the supplied split filenames;
# sdkVersion comes from base.apk (targetSdkVersion, else minSdk, else 35) — the same chain
# bitkey_build.sh uses. See the SDK PROVENANCE note below: that is an app declaration, not the
# source handset's API level, and the value used is reported in full so a report must disclose it.

set -euo pipefail

EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.2.6"
readonly SCRIPT_NAME="envoy_build.sh"
readonly LAST_MODIFIED_BY="Daniel Garcia"
readonly LAST_MODIFIED_ON="2026-08-29"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256=""

readonly APP_ID="com.foundationdevices.envoy"
readonly REPO_URL="https://github.com/Foundation-Devices/envoy.git"

# Pre-clone tooling comes from the same nixpkgs revision Envoy itself pins (flake.lock ->
# nixpkgs_2), not from the caller's mutable registry, so metadata extraction is repeatable.
readonly NIXPKGS="github:NixOS/nixpkgs/4fd0f759fbe88b1a57902871cf4ba4a2e4f63355"

# bundletool must match the version AGP embeds. android/settings.gradle pins AGP 8.12.0, whose
# published POM declares bundletool 1.18.1. This is the best source-grounded choice; it does NOT
# prove Google Play's server-side generation used 1.18.1. Re-pin whenever AGP moves.
readonly BT_VER="1.18.1"
readonly BT_URL="https://github.com/google/bundletool/releases/download/${BT_VER}/bundletool-all-${BT_VER}.jar"
readonly BT_SHA="675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c"
readonly AT_VER="3.0.3"
readonly AT_URL="https://github.com/iBotPeaches/Apktool/releases/download/v${AT_VER}/apktool_${AT_VER}.jar"
readonly AT_SHA="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"

readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

RUN_ID="envoy-$(date +%s)-$$"
readonly RUN_ID
WORK_DIR=""
SCRATCH=""
OFFICIAL_DIR=""
VERDICT="not_reproducible"
VERSION_NAME=""; VERSION_CODE=""; SIGNER="unknown"; APP_HASH=""; COMMIT_HASH="unknown"
TAG=""; TAG_TYPE="unknown"; SDK=""; SDK_SRC=""; SPEC=""
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

# Print at most N lines without closing the pipe early: `head` makes upstream SIGPIPE, which
# under `set -o pipefail` can abort the run before the results block is written.
cap() { awk -v n="${1:-5}" 'NR<=n{print} {last=NR} END{if(last>n) printf "    ... %d more line(s); full listing saved\n", last-n}'; }

# --- Self-identification (script-notes/script-version-and-hash.md). First action, before
# argument parsing, so even an invalid-argument run records which bytes failed. ---
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

# A previous run's verdict must never survive this invocation, including when this one exits at
# argument validation or preflight. Hence: before anything can exit.
rm -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml"

usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <dir-of-split-apks|base.apk> [--version <v>] [--arch <a>] [--type <t>]

  --binary   REQUIRED. Directory holding the device-pulled Play splits (base.apk
             plus split_config.*.apk), or the path to base.apk itself, in which
             case its siblings in the same directory form the split set.
  --version  Optional. Logged and cross-checked. The authoritative version comes
             from base.apk.
  --arch     Optional. Logged. The ABI comes from the official split set.
  --type     Optional. Logged, unused.

Environment:
  WS_DEVICE_SDK  Optional override for the device spec's sdkVersion. When unset the
                 value is read from base.apk: targetSdkVersion, else minSdk, else 35.
                 No smartphone is required.

Exit codes: 0 = reproducible, 1 = differences or build failure, 2 = invalid parameters.
USAGE
}

write_yaml() {
    local verdict="$1" notes="$2"
    { printf 'script_version: %s\n' "$SCRIPT_VERSION"
      printf 'verdict: %s\n' "$verdict"
      printf 'notes: |\n'
      printf '%s\n' "$notes" | sed 's/^/  /'
    } > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    RESULT_DONE=true
    log "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

cleanup() {
    local rc=$?
    [[ -n "$SCRATCH" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH" 2>/dev/null || true
    # An unexpected abort must still leave a machine-readable result, or ABS records nothing.
    if [[ "$RESULT_DONE" == false && $rc -ne 0 && $rc -ne "$EXIT_INVALID" ]]; then
        write_yaml "ftbfs" "Run aborted unexpectedly with status ${rc} before a verdict was reached. See the terminal output for the failing step."
    fi
}
# A signal trap is not an EXIT trap: after the handler returns, bash can resume. Route signals
# through an explicit exit so the single EXIT path runs exactly once.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

die_invalid() { log_err "$1"; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"; }

fail() {
    log_err "$2"
    write_yaml "$1" "$2"
    echo "Exit code: ${EXIT_FAILED}"
    exit "${EXIT_FAILED}"
}

# Run diff and distinguish "no differences" from "diff could not run". rc 0 = same, 1 = differs,
# >1 = error. Swallowing rc>1 turns a traversal or permission failure into "identical".
DIFF_OUT=""
run_diff() {
    local rc=0
    DIFF_OUT="$("$@" 2>&1)" || rc=$?
    [[ $rc -le 1 ]] && return 0
    return "$rc"
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------
binary_arg=""; version_arg=""; arch_arg=""; type_arg=""
need_arg() { [[ -n "${2:-}" && "${2:0:2}" != "--" ]] || die_invalid "Option $1 requires a value."; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary|--apk) need_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
        --version)      need_arg "$1" "${2:-}"; version_arg="$2"; shift 2 ;;
        --arch)         need_arg "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
        --type)         need_arg "$1" "${2:-}"; type_arg="$2"; shift 2 ;;
        --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
        -h|--help)      usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
        # Unknown parameters must never be fatal (luis-changes-2026-03-11).
        *)              log_warn "Ignoring unrecognised parameter: $1"; shift ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] && die_invalid "Refusing to run as root. Run as a normal user; no sudo is needed."
[[ -n "$binary_arg" ]] || { usage; die_invalid "--binary is required."; }

if [[ -f "$binary_arg" ]]; then
    [[ "$(basename "$binary_arg")" == "base.apk" ]] \
        || die_invalid "A file argument must be base.apk (got $(basename "$binary_arg")). Play splits are only meaningful as a set; pass the directory instead."
    OFFICIAL_DIR="$(cd "$(dirname "$binary_arg")" && pwd)"
    log "base.apk supplied directly; its sibling *.apk files in ${OFFICIAL_DIR} form the split set."
elif [[ -d "$binary_arg" ]]; then
    OFFICIAL_DIR="$(cd "$binary_arg" && pwd)"
else
    die_invalid "--binary path does not exist: ${binary_arg}"
fi

shopt -s nullglob
OFFICIAL_SPLITS=("${OFFICIAL_DIR}"/*.apk)
shopt -u nullglob
[[ ${#OFFICIAL_SPLITS[@]} -gt 0 ]] || die_invalid "No .apk files found in ${OFFICIAL_DIR}"
OFFICIAL_BASE="${OFFICIAL_DIR}/base.apk"
[[ -f "$OFFICIAL_BASE" ]] || die_invalid "base.apk not found in ${OFFICIAL_DIR}. The Play split set must include it."

[[ -n "$arch_arg" ]] && log "--arch ${arch_arg} accepted; the ABI comes from the official split set"
[[ -n "$type_arg" ]] && log "--type ${type_arg} accepted but not used"

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
section "PRE-FLIGHT"
command -v nix >/dev/null 2>&1 || die_invalid "nix is required (ABS rule 1 permits nix with flakes). Install nix and enable flakes."
# An array, not a string: --extra-experimental-features takes ONE argument, so the two feature
# names must stay a single quoted word. Word-splitting a plain string passes "flakes" as a
# positional command and nix rejects it.
NIX=(nix --extra-experimental-features 'nix-command flakes')
"${NIX[@]}" flake --help >/dev/null 2>&1 \
    || die_invalid "nix flakes are not usable here. Enable them in nix.conf (experimental-features = nix-command flakes) or check that this nix supports the flake subcommand."
log_ok "nix present: $(nix --version 2>/dev/null | head -1)"
log "No host JDK, Flutter, Rust, Android SDK, bundletool or apktool is required or used."
log "Host git/curl are used when present; otherwise both are taken from the pinned nixpkgs."

WORK_DIR="${EXEC_DIR}/envoy_verification_${RUN_ID}"
mkdir -p "${WORK_DIR}/comparison" "${WORK_DIR}/built" "${WORK_DIR}/tools" "${WORK_DIR}/home"
readonly WORK_DIR
SCRATCH="$(mktemp -d "${WORK_DIR}/scratch.XXXXXX")"
SRC_DIR="${WORK_DIR}/src"

# Everything the build might otherwise write into the invoking user's home is redirected into
# the workspace: caches are build inputs, and host state must not leak into a verification.
export HOME="${WORK_DIR}/home"
export GRADLE_USER_HOME="${WORK_DIR}/home/.gradle"
export PUB_CACHE="${WORK_DIR}/home/.pub-cache"
export CARGO_HOME="${WORK_DIR}/home/.cargo"
export ANDROID_USER_HOME="${WORK_DIR}/home/.android"
export XDG_CACHE_HOME="${WORK_DIR}/home/.cache"
mkdir -p "$GRADLE_USER_HOME" "$PUB_CACHE" "$CARGO_HOME" "$ANDROID_USER_HOME" "$XDG_CACHE_HOME"

if command -v git >/dev/null 2>&1; then GIT=(git); else GIT=("${NIX[@]}" shell "${NIXPKGS}#git" --command git); fi
JAVA=("${NIX[@]}" shell "${NIXPKGS}#jdk17" --command java)

cat <<BANNER

== ENVOY (com.foundationdevices.envoy) — GOOGLE PLAY SPLIT VERIFICATION ==
 Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Splits:    ${OFFICIAL_DIR}
 Workspace: ${WORK_DIR}
 Date:      $(date)
BANNER

# ------------------------------------------------------------------------------
# Pinned tooling
# ------------------------------------------------------------------------------
section "SETUP: PINNED TOOLING"
fetch_pinned() {
    local url="$1" want="$2" dest="$3" got
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest" || true
    else
        "${NIX[@]}" shell "${NIXPKGS}#curl" --command curl -fsSL "$url" -o "$dest" || true
    fi
    [[ -s "$dest" ]] || fail "ftbfs" "Could not download $(basename "$dest") from ${url}."
    got="$(sha256_of "$dest")"
    [[ "$got" == "$want" ]] || fail "ftbfs" "$(basename "$dest") SHA-256 mismatch. Expected ${want}, got ${got}. Refusing to run an unverified tool."
    log_ok "$(basename "$dest") verified: ${want}"
}
BT_JAR="${WORK_DIR}/tools/bundletool.jar"
AT_JAR="${WORK_DIR}/tools/apktool.jar"
fetch_pinned "$BT_URL" "$BT_SHA" "$BT_JAR"
fetch_pinned "$AT_URL" "$AT_SHA" "$AT_JAR"
APKTOOL_FRAME="${WORK_DIR}/home/apktool-frames"; mkdir -p "$APKTOOL_FRAME"
apktool() { "${JAVA[@]}" -Duser.home="${WORK_DIR}/home" -jar "$AT_JAR" "$@"; }

# ------------------------------------------------------------------------------
# Official metadata, read with pinned tooling BEFORE any clone, so the tag we build is chosen
# from the artifact and never from whatever the default branch happens to be today.
# ------------------------------------------------------------------------------
section "PHASE 0: OFFICIAL BINARY METADATA"
MD="${SCRATCH}/meta"
apktool d -s -f --frame-path "$APKTOOL_FRAME" -o "$MD" "$OFFICIAL_BASE" >/dev/null 2>&1 \
    || fail "ftbfs" "apktool could not decode ${OFFICIAL_BASE}."
yml() { sed -n "s/^[[:space:]]*$1:[[:space:]]*'\{0,1\}\([^']*\)'\{0,1\}[[:space:]]*$/\1/p" "${MD}/apktool.yml" | head -1; }
VERSION_NAME="$(yml versionName)"
VERSION_CODE="$(yml versionCode)"
TARGET_SDK="$(yml targetSdkVersion)"
MIN_SDK="$(yml minSdkVersion)"
pkg="$(sed -n 's/.*package="\([^"]*\)".*/\1/p' "${MD}/AndroidManifest.xml" | head -1)"

[[ "$pkg" == "$APP_ID" ]] || fail "ftbfs" "Package name mismatch: base.apk reports '${pkg}', expected ${APP_ID}. Wrong artifact supplied."
[[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "ftbfs" "Unexpected versionName '${VERSION_NAME}' in base.apk."
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || fail "ftbfs" "Unexpected versionCode '${VERSION_CODE}' in base.apk."
log_ok "Package verified: ${pkg}"
log_ok "Version: ${VERSION_NAME} (versionCode ${VERSION_CODE})"

if [[ -n "$version_arg" && "$version_arg" != "$VERSION_NAME" ]]; then
    log_warn "--version was '${version_arg}' but base.apk reports '${VERSION_NAME}'; using the binary's value"
fi
APP_HASH="$(sha256_of "$OFFICIAL_BASE")"
log "base.apk SHA-256: ${APP_HASH}  (the base artifact's hash, not an aggregate of the split set)"
log "Official split set:"
for f in "${OFFICIAL_SPLITS[@]}"; do printf '  %s  %s\n' "$(sha256_of "$f")" "$(basename "$f")"; done

# SDK PROVENANCE. bitkey_build.sh's chain, by instruction. targetSdkVersion is the app's declared
# target and minSdk is its floor; neither is the source handset's API level. The value used is
# printed here and carried into the results so a report cannot omit it.
if [[ -n "${WS_DEVICE_SDK:-}" ]]; then
    [[ "${WS_DEVICE_SDK}" =~ ^[0-9]+$ ]] || die_invalid "WS_DEVICE_SDK must be numeric, got '${WS_DEVICE_SDK}'."
    SDK="$WS_DEVICE_SDK"; SDK_SRC="supplied via WS_DEVICE_SDK"
elif [[ "$TARGET_SDK" =~ ^[0-9]+$ ]]; then
    SDK="$TARGET_SDK"; SDK_SRC="targetSdkVersion from base.apk (an app declaration, NOT the source device's API level)"
elif [[ "$MIN_SDK" =~ ^[0-9]+$ ]]; then
    SDK="$MIN_SDK"; SDK_SRC="minSdkVersion from base.apk; targetSdkVersion unreadable"
else
    SDK=35; SDK_SRC="fallback 35; neither targetSdkVersion nor minSdkVersion readable"
    log_warn "Neither targetSdkVersion nor minSdkVersion readable; using 35."
fi
log "device-spec sdkVersion: ${SDK} (${SDK_SRC})"

# ------------------------------------------------------------------------------
# Source
# ------------------------------------------------------------------------------
section "PHASE 1: SOURCE"
TAG="v${VERSION_NAME}"
log "Cloning ${REPO_URL}"
"${GIT[@]}" clone "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || fail "ftbfs" "git clone failed for ${REPO_URL}."
( cd "$SRC_DIR" && "${GIT[@]}" rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1 ) \
    || fail "ftbfs" "Upstream has no tag ${TAG} for the shipped version ${VERSION_NAME}; the artifact cannot be tied to published source."
( cd "$SRC_DIR" && "${GIT[@]}" checkout -q "$TAG" ) || fail "ftbfs" "Could not check out ${TAG}."
COMMIT_HASH="$( cd "$SRC_DIR" && "${GIT[@]}" rev-parse HEAD )"
# --porcelain, not diff-index: diff-index ignores untracked files, which are build inputs too.
[[ -z "$( cd "$SRC_DIR" && "${GIT[@]}" status --porcelain )" ]] \
    || fail "ftbfs" "Working tree is not clean immediately after checkout; refusing to build."
TAG_TYPE="$( cd "$SRC_DIR" && "${GIT[@]}" cat-file -t "$TAG" 2>/dev/null || echo unknown )"
log_ok "Building ${TAG} at ${COMMIT_HASH}"
[[ "$TAG_TYPE" == "commit" ]] && log "Tag ${TAG} is lightweight and carries no signature of its own."

# Source cross-check. A mismatch means the tag does not describe the shipped artifact, so the
# comparison would be meaningless — fatal, not a warning.
pv="$(sed -n 's/^version:[[:space:]]*//p' "${SRC_DIR}/pubspec.yaml" | head -1)"
[[ "$pv" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)$ ]] \
    || fail "ftbfs" "pubspec.yaml version '${pv}' is not in the expected X.Y.Z+B form; cannot cross-check the artifact."
expect_code=$(( BASH_REMATCH[1]*1000000 + BASH_REMATCH[2]*10000 + BASH_REMATCH[3]*100 + BASH_REMATCH[4] ))
pvn="${pv%%+*}"
[[ "$pvn" == "$VERSION_NAME" && "$expect_code" == "$VERSION_CODE" ]] \
    || fail "ftbfs" "Source/artifact mismatch: ${TAG}'s pubspec ${pv} yields versionName ${pvn} / versionCode ${expect_code}, but base.apk reports ${VERSION_NAME} / ${VERSION_CODE}. The tag does not describe the shipped artifact."
log_ok "Source cross-check: pubspec ${pv} yields versionCode ${expect_code}, matching the artifact"

[[ -f "${SRC_DIR}/pubspec.lock" && -f "${SRC_DIR}/Cargo.lock" ]] \
    || fail "ftbfs" "pubspec.lock and Cargo.lock must both exist at ${TAG}; cannot check dependency drift without them."
LOCK_BEFORE="$( cd "$SRC_DIR" && sha256sum pubspec.lock Cargo.lock )"

nixrun() { ( cd "$SRC_DIR" && "${NIX[@]}" develop --command "$@" ); }

# Upstream's shellHook echoes an "Envoy Development Environment" banner to STDOUT on every
# `nix develop` (flake.nix), so a plain command substitution captures the banner along with the
# value. Everything we need back from the shell is therefore marked and extracted by marker.
# (That hook also runs `flutter --version | head -1`, which SIGPIPEs flutter and prints a Dart
# stack trace. It is upstream's, it is harmless, and it appears on every entry to the shell.)
nixval() { nixrun bash -c "v=\$($1); [[ -n \"\$v\" ]] && printf 'WSVAL=%s\\n' \"\$v\"" 2>/dev/null | sed -n 's/^WSVAL=//p' | tail -1; }
AAPT2="$(nixval 'ls -1 "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | sort | tail -1' || true)"
APKSIGNER="$(nixval 'ls -1 "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | sort | tail -1' || true)"
[[ -n "$AAPT2" && "$AAPT2" != *$'\n'* && -x "$AAPT2" ]] || fail "ftbfs" "aapt2 could not be located in the nix dev shell (got '${AAPT2}')."
[[ -n "$APKSIGNER" && "$APKSIGNER" != *$'\n'* && -x "$APKSIGNER" ]] || fail "ftbfs" "apksigner could not be located in the nix dev shell (got '${APKSIGNER}')."
log_ok "aapt2:     ${AAPT2}"
log_ok "apksigner: ${APKSIGNER}"
# The SourceStamp class is only ever accepted on cryptographic evidence, so apksigner is
# required — both checks above are hard failures, not warnings.
SIGNER="$(nixrun "$APKSIGNER" verify --print-certs "$OFFICIAL_BASE" 2>/dev/null | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | tail -1 || true)"
SIGNER="${SIGNER:-unknown}"
log "Signer SHA-256: ${SIGNER}"

# ------------------------------------------------------------------------------
# Build — upstream's own command, signing suppressed via the nosign project property.
# ------------------------------------------------------------------------------
section "PHASE 2: BUILD FROM SOURCE (30-90 min cold)"
# pipefail already surfaces the left-hand status; the if/else keeps set -e from exiting before
# the detailed message can be written.
if nixrun flutter pub get 2>&1 | tee "${WORK_DIR}/pub-get.log"; then :; else
    fail "ftbfs" "flutter pub get failed. See pub-get.log."
fi

if ( cd "$SRC_DIR" && ORG_GRADLE_PROJECT_nosign=true "${NIX[@]}" develop --command \
        flutter build aab --release --target-platform android-arm64 ) 2>&1 | tee "${WORK_DIR}/build.log"; then :; else
    fail "ftbfs" "flutter build aab exited non-zero. See build.log."
fi

LOCK_AFTER="$( cd "$SRC_DIR" && sha256sum pubspec.lock Cargo.lock )"
[[ "$LOCK_BEFORE" == "$LOCK_AFTER" ]] \
    || fail "ftbfs" "A tracked lockfile changed during the build; dependency resolution drifted from what the tag pins."

AAB="${SRC_DIR}/build/app/outputs/bundle/release/app-release.aab"
[[ -f "$AAB" ]] || fail "ftbfs" "No AAB produced at build/app/outputs/bundle/release/app-release.aab."
log_ok "AAB built: $(sha256_of "$AAB")"

# ------------------------------------------------------------------------------
# Device spec and split generation
# ------------------------------------------------------------------------------
section "PHASE 3: SPLIT THE AAB"
ABIS=(); DEN=""; LOCS=()
for f in "${OFFICIAL_SPLITS[@]}"; do
    c="$(basename "$f")"; c="${c%.apk}"
    [[ "$c" == "base" ]] && continue
    c="${c#split_config.}"
    case "$c" in
        arm64_v8a) ABIS+=("arm64-v8a") ;;
        armeabi_v7a) ABIS+=("armeabi-v7a") ;;
        x86_64) ABIS+=("x86_64") ;;
        x86) ABIS+=("x86") ;;
        ldpi) DEN=120 ;; mdpi) DEN=160 ;; tvdpi) DEN=213 ;; hdpi) DEN=240 ;;
        xhdpi) DEN=320 ;; xxhdpi) DEN=480 ;; xxxhdpi) DEN=640 ;;
        [a-z][a-z]|[a-z][a-z]_[A-Za-z]*) LOCS+=("${c//_/-}") ;;
        *) fail "ftbfs" "Unrecognised split config '${c}' in the official set; refusing to guess a device spec." ;;
    esac
done
[[ ${#ABIS[@]} -eq 0 ]] && fail "ftbfs" "No ABI split in the official set; cannot build a device spec."
[[ -z "$DEN" ]] && fail "ftbfs" "No density split in the official set; cannot build a device spec."
[[ ${#LOCS[@]} -eq 0 ]] && LOCS=("en")

j() { local o=""; for v in "$@"; do o="${o}\"${v}\","; done; echo "[${o%,}]"; }
SPEC="${WORK_DIR}/device-spec.json"
printf '{"supportedAbis":%s,"supportedLocales":%s,"screenDensity":%s,"sdkVersion":%s}\n' \
    "$(j "${ABIS[@]}")" "$(j "${LOCS[@]}")" "$DEN" "$SDK" > "$SPEC"
cat "$SPEC"

# Envoy ships a language split, so locale codes are load-bearing. bundletool writes legacy codes
# (iw/in/ji) into res/xml/splits0.xml where a modern JDK writes he/id/yi; aligning them is a
# comparison-direction control, not a source change. Gradle is untouched by this flag.
nixrun java -Djava.locale.useOldISOCodes=true -jar "$BT_JAR" build-apks \
    --bundle="$AAB" --output="${WORK_DIR}/built.apks" --device-spec="$SPEC" --overwrite \
    || fail "ftbfs" "bundletool build-apks failed."
nixrun unzip -q -o "${WORK_DIR}/built.apks" 'splits/*.apk' -d "${WORK_DIR}/bt" \
    || fail "ftbfs" "Could not extract splits from built.apks."
cp "${WORK_DIR}"/bt/splits/*.apk "${WORK_DIR}/built/" || fail "ftbfs" "No split APKs produced by bundletool."
log "built splits:"
for f in "${WORK_DIR}"/built/*.apk; do printf '  %s  %s\n' "$(sha256_of "$f")" "$(basename "$f")"; done
log "NOTE: the AAB is unsigned, but bundletool signs the APKs it generates with a debug key"
log "      (kept inside this workspace). Play signing differences are excluded only under the"
log "      exact root-META-INF filename rule below, never because 'our build is unsigned'."

# ------------------------------------------------------------------------------
# Comparison
# ------------------------------------------------------------------------------
section "PHASE 4: PER-SPLIT COMPARISON"
OFF_ROOT="${SCRATCH}/o"; BLT_ROOT="${SCRATCH}/b"
re_esc() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/]/\\&/g'; }
OFF_RE="$(re_esc "$OFF_ROOT")"

# The config key must come from the APK's own split= attribute. Device splits are named
# split_config.arm64_v8a.apk while bundletool emits base-arm64_v8a.apk for the same config;
# matching on filenames pairs nothing and every split reads UNMATCHED.
cfg_of() {
    local s
    s="$(nixrun "$AAPT2" dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
    s="${s#config.}"
    printf '%s' "$s"
}

declare -A OFF BLT
add_key() { # array_name key file — a collision would silently drop a supplied APK
    local -n arr="$1"
    [[ -n "${arr[$2]:-}" ]] && fail "ftbfs" "Two APKs map to config key '$2' ($(basename "${arr[$2]}") and $(basename "$3")); refusing to compare an ambiguous set."
    arr["$2"]="$3"
}
for f in "${OFFICIAL_SPLITS[@]}"; do
    k="$(cfg_of "$f")"
    if [[ "$(basename "$f")" == "base.apk" ]]; then
        [[ -z "$k" ]] || fail "ftbfs" "base.apk declares split='${k}'; it is not a true base APK."
        k="base"
    else
        [[ -n "$k" ]] || fail "ftbfs" "$(basename "$f") declares no split attribute; cannot place it in the split set."
    fi
    add_key OFF "$k" "$f"
done
for f in "${WORK_DIR}"/built/*.apk; do
    k="$(cfg_of "$f")"; [[ -z "$k" ]] && k="base"
    add_key BLT "$k" "$f"
done
[[ -n "${OFF[base]:-}" ]] || fail "ftbfs" "No base APK in the official set."

# Every supplied split must belong to the same app, version and signer as base. A mixed or
# corrupted set would otherwise reach content comparison and be judged as if it were coherent.
for k in "${!OFF[@]}"; do
    f="${OFF[$k]}"
    bd="$(nixrun "$AAPT2" dump badging "$f" 2>/dev/null || true)"
    p2="$(printf '%s' "$bd" | sed -n "s/.*package: name='\([^']*\)'.*/\1/p" | head -1)"
    v2="$(printf '%s' "$bd" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | head -1)"
    [[ "$p2" == "$APP_ID" ]] || fail "ftbfs" "$(basename "$f") reports package '${p2}', expected ${APP_ID}; the supplied set is not coherent."
    [[ "$v2" == "$VERSION_CODE" ]] || fail "ftbfs" "$(basename "$f") reports versionCode '${v2}', but base.apk reports ${VERSION_CODE}; the supplied set mixes versions."
    s2="$(nixrun "$APKSIGNER" verify --print-certs "$f" 2>/dev/null | sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' | head -1)"
    [[ -n "$s2" ]] || fail "ftbfs" "$(basename "$f") has no verifiable signature; refusing to compare an unsigned or damaged official artifact."
    [[ "$s2" == "$SIGNER" ]] || fail "ftbfs" "$(basename "$f") is signed by ${s2} but base.apk by ${SIGNER}; the supplied set is not coherent."
done
log_ok "Split-set identity verified: ${#OFF[@]} official APKs share package, versionCode and signer"
[[ ${#OFF[@]} -eq ${#OFFICIAL_SPLITS[@]} ]] || fail "ftbfs" "Official split set has ${#OFFICIAL_SPLITS[@]} files but only ${#OFF[@]} distinct config keys."

# Root META-INF SIGNING files only, matched by NAME, and only one-sided in the OFFICIAL
# direction — a signing-named file present only in OUR build means something signed it and is
# material. See ws-notes/script-notes/meta-inf-filter-scope.md (2026-08-27).
SIGN_NAME='[^/]*(\.(SF|RSA|DSA|EC)|MANIFEST\.MF)'

# `Only in <official>: META-INF` is the whole directory, not a file, so the filename allowlist
# never sees it. Accept it only after listing what is actually inside: every root entry must be
# a signing file, and the contents are printed so a report can state them.
metainf_dir_ok() {
    local o="$1" entries bad
    # Every depth, not just the root: listing only ^META-INF/[^/]+$ would hide a nested
    # META-INF/services/... entry and let the directory be accepted as "all signing files".
    entries="$(nixrun unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -E '^META-INF/' || true)"
    [[ -n "$entries" ]] || { echo "      META-INF dir: could not list contents -> material"; return 1; }
    bad="$(printf '%s\n' "$entries" | grep -vE "^META-INF/${SIGN_NAME}$" || true)"
    if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
        echo "      META-INF dir: contains non-signing entries -> material:"
        printf '%s\n' "$bad" | cap 5 | sed 's/^/        /'
        return 1
    fi
    echo "      META-INF dir: official-only, $(printf '%s\n' "$entries" | grep -c '^') entry(ies), all signing files:"
    printf '%s\n' "$entries" | cap 5 | sed 's/^/        /'
}

stamp_ok() {
    local o="$1" n sz
    n=$(nixrun unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256' || true)
    [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
    [[ -e "${BLT_ROOT}/stamp-cert-sha256" ]] && { echo "      stamp: present in BUILT too"; return 1; }
    sz=$(stat -c%s "${OFF_ROOT}/stamp-cert-sha256" 2>/dev/null || echo -1)
    [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
    nixrun "$APKSIGNER" verify --verbose --print-certs "$o" 2>/dev/null \
        | grep -q 'Verified for SourceStamp: true' \
        || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
    echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

# Accepted only when the sole delta is Play's distribution meta-data, official-side only, with
# block openers, allowlisted names and allowlisted values in equal number.
manifest_ok() {
    local o="$1" b="$2" c="$3" left bad n m v
    nixrun "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > "${SCRATCH}/mo" 2>/dev/null || return 1
    nixrun "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > "${SCRATCH}/mb" 2>/dev/null || return 1
    run_diff diff -u "${SCRATCH}/mo" "${SCRATCH}/mb" || { echo "      manifest: diff failed to run -> material"; return 1; }
    printf '%s\n' "$DIFF_OUT" > "${WORK_DIR}/comparison/diff_manifest_${c}.txt"
    printf '%s\n' "$DIFF_OUT" | grep -q '^+[^+]' && { echo "      manifest: BUILT-only lines present"; return 1; }
    left="$(printf '%s\n' "$DIFF_OUT" | grep '^-[^-]' | sed 's/^- *//' || true)"
    # LANDMINE: aapt2 appends ` (Raw: "...")` to string attributes and omits it for integers.
    # Anchoring with $ and no Raw clause rejects Play's own stamp.source/stamp.type lines.
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
    echo "      manifest: ${n} off-only Play meta-data block(s); equal non-zero aggregate counts of blocks (${n}), allowed names (${m}) and allowed values (${v}); pairing not proven; none built-only"
}

# resources.arsc: decode both and require the decoded res/ tree to be identical. A decode failure
# or a diff that cannot run is material, never accepted.
arsc_ok() {
    local o="$1" b="$2" c="$3"
    rm -rf "${SCRATCH}/do" "${SCRATCH}/db"
    apktool d -f --no-src --no-debug-info --frame-path "$APKTOOL_FRAME" -o "${SCRATCH}/do" "$o" >/dev/null 2>&1 \
        || { echo "      arsc: DECODE FAILED (official)"; return 1; }
    apktool d -f --no-src --no-debug-info --frame-path "$APKTOOL_FRAME" -o "${SCRATCH}/db" "$b" >/dev/null 2>&1 \
        || { echo "      arsc: DECODE FAILED (built)"; return 1; }
    [[ -d "${SCRATCH}/do/res" && -d "${SCRATCH}/db/res" ]] || { echo "      arsc: no res/ after decode"; return 1; }
    run_diff diff -r "${SCRATCH}/do/res" "${SCRATCH}/db/res" || { echo "      arsc: diff failed to run -> material"; return 1; }
    printf '%s\n' "$DIFF_OUT" > "${WORK_DIR}/comparison/diff_resources_decoded_${c}.txt"
    [[ -z "$(printf '%s' "$DIFF_OUT" | tr -d '[:space:]')" ]] || { echo "      arsc: decoded res/ DIFFERS -> material"; return 1; }
    echo "      arsc: decoded res/ tree IDENTICAL"
}

# Report the signing state we MEASURED, never a fixed assumption. bundletool signs the APKs it
# generates only when a keystore is passed with --ks; this script passes none, so they come out
# unsigned and bundletool says so on stderr. v0.2.4 and earlier printed a hardcoded claim that
# they had been debug-signed, which was false and contradicted the run's own comparison evidence
# (root META-INF signing material was official-only). Measure it from the built artifact instead.
# Root META-INF entries detect ONLY v1/JAR signing. APK Signature Schemes v2 and v3 live in the
# APK Signing Block, not in ZIP entries, so a v2/v3-only APK has no signing files under META-INF
# and counting them would call a properly signed APK "unsigned". That matters here: v1 signatures
# are only required below API 24, so a modern signer may legitimately emit none. apksigner is the
# authority on signing state across all schemes; the v1 entry count is reported alongside it as a
# separate fact, never as the answer. (v0.2.5 got this wrong; fixed v0.2.6.)
signing_state() {
    local b="${BLT[base]:-}" out schemes n rc=0
    [[ -n "$b" && -f "$b" ]] || { echo "AAB unsigned; built APK signing state NOT MEASURED (no built base APK)"; return 0; }
    n="$(nixrun unzip -l "$b" 2>/dev/null | awk '{print $NF}' | grep -cE "^META-INF/${SIGN_NAME}$" || true)"
    out="$(nixrun "$APKSIGNER" verify --verbose "$b" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "AAB unsigned; generated APKs unsigned (apksigner reports no valid signature; ${n} root META-INF v1 entry(ies))"
    else
        schemes="$(printf '%s\n' "$out" | sed -n 's/^Verified using \(v[0-9]*\) scheme.*: true$/\1/p' | paste -sd, -)"
        echo "AAB unsigned; generated APKs SIGNED, apksigner verified via ${schemes:-scheme not reported} (${n} root META-INF v1 entry(ies))"
    fi
}

SUMMARY="${WORK_DIR}/comparison/summary.txt"; : > "$SUMMARY"

for cfg in $(printf '%s\n' "${!OFF[@]}" "${!BLT[@]}" | sort -u); do
    echo ""
    echo "======== split: ${cfg} ========"
    o="${OFF[$cfg]:-}"; b="${BLT[$cfg]:-}"
    if [[ -z "$o" || -z "$b" ]]; then
        echo "  UNMATCHED  official=$([[ -n $o ]] && echo yes || echo NO)  built=$([[ -n $b ]] && echo yes || echo NO)"
        echo "${cfg} UNMATCHED" >> "$SUMMARY"
        MISSING_TOTAL=$((MISSING_TOTAL + 1)); continue
    fi
    echo "  official: $(basename "$o")  sha256 $(sha256_of "$o")"
    echo "  built:    $(basename "$b")  sha256 $(sha256_of "$b")"

    rm -rf "$OFF_ROOT" "$BLT_ROOT"; mkdir -p "$OFF_ROOT" "$BLT_ROOT"
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

    run_diff diff -rq "$OFF_ROOT" "$BLT_ROOT" \
        || fail "ftbfs" "diff could not compare split ${cfg} (exit >1). Refusing to call an unreadable comparison identical."
    raw="$DIFF_OUT"
    printf '%s\n' "$raw" > "${WORK_DIR}/comparison/diff-unzipped-${cfg}.txt"
    n=$(printf '%s\n' "$raw" | grep -vc '^$' || true)
    echo "  raw diffs: ${n}   (full list: comparison/diff-unzipped-${cfg}.txt)"
    [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | grep -v '^$' | cap 5 | sed 's/^/    /'

    # Every class is matched on the EXACT raw line, anchored to the extraction roots. A substring
    # match would let a nested AndroidManifest.xml or resources.arsc ride on the root file's
    # acceptance.
    # -Fx for the three fully literal lines: an execution path containing regex metacharacters
    # must not change what matches. The signing patterns need a regex for the filename, so the
    # root paths are escaped before they are interpolated.
    sign_lines="$(printf '%s\n' "$raw" | grep -E "^Only in ${OFF_RE}/META-INF: ${SIGN_NAME}$|^Files ${OFF_RE}/META-INF/${SIGN_NAME} and " || true)"
    c_sign=$(printf '%s\n' "$sign_lines" | grep -vc '^$' || true)
    c_mdir=$(printf '%s\n' "$raw" | grep -Fxc "Only in ${OFF_ROOT}: META-INF" || true)
    c_stamp=$(printf '%s\n' "$raw" | grep -Fxc "Only in ${OFF_ROOT}: stamp-cert-sha256" || true)
    c_mani=$(printf '%s\n' "$raw" | grep -Fxc "Files ${OFF_ROOT}/AndroidManifest.xml and ${BLT_ROOT}/AndroidManifest.xml differ" || true)
    c_arsc=$(printf '%s\n' "$raw" | grep -Fxc "Files ${OFF_ROOT}/resources.arsc and ${BLT_ROOT}/resources.arsc differ" || true)

    a_sign=0; a_stamp=0; a_mani=0; a_arsc=0
    echo "  accepted-class evidence"
    [[ "$c_sign" -gt 0 ]] && { a_sign=$c_sign; echo "      signing: ${c_sign} root META-INF entry(ies), official-only or two-sided"; }
    [[ "$c_mdir" -eq 1 ]] && { metainf_dir_ok "$o" && a_sign=$((a_sign + 1)) || echo "      META-INF dir: NOT EARNED -> material"; }
    [[ "$c_stamp" -eq 1 ]] && { stamp_ok "$o" && a_stamp=1 || echo "      stamp: NOT EARNED -> material"; }
    [[ "$c_mani" -eq 1 ]] && { manifest_ok "$o" "$b" "$cfg" && a_mani=1 || echo "      manifest: NOT EARNED -> material"; }
    [[ "$c_arsc" -eq 1 ]] && { arsc_ok "$o" "$b" "$cfg" && a_arsc=1 || echo "      arsc: NOT EARNED -> material"; }

    acc=$((a_sign + a_stamp + a_mani + a_arsc))
    # Never clamp. acc > n would mean the accounting itself is broken, and clamping would turn
    # that bug into a possible `reproducible`. Fail closed instead.
    [[ "$acc" -le "$n" ]] || fail "ftbfs" "Internal comparison error on split ${cfg}: ${acc} accepted differences but only ${n} raw. Refusing to produce a verdict from broken accounting."
    un=$((n - acc))
    [[ "$un" -eq 0 ]] && v=reproducible || v=not_reproducible
    echo "  split result: raw ${n}, accepted ${acc} (signing ${a_sign}, stamp ${a_stamp}, manifest ${a_mani}, arsc ${a_arsc}), unaccounted ${un} -> ${v}"
    echo "${cfg} raw=${n} accepted=${acc} unaccounted=${un}" >> "$SUMMARY"

    RAW_TOTAL=$((RAW_TOTAL + n)); UNACC_TOTAL=$((UNACC_TOTAL + un))
    ACC_SIGN=$((ACC_SIGN + a_sign)); ACC_STAMP=$((ACC_STAMP + a_stamp))
    ACC_MANI=$((ACC_MANI + a_mani)); ACC_ARSC=$((ACC_ARSC + a_arsc))
done

ACC_TOTAL=$((ACC_SIGN + ACC_STAMP + ACC_MANI + ACC_ARSC))
if [[ "$UNACC_TOTAL" -eq 0 && "$MISSING_TOTAL" -eq 0 && ${#OFF[@]} -gt 0 ]]; then
    VERDICT="reproducible"
else
    VERDICT="not_reproducible"
fi

section "RESULT"
cat <<SUM
 Official splits:      ${#OFF[@]}
 Raw differences:      ${RAW_TOTAL}
 Accepted (earned):    ${ACC_TOTAL} = sign ${ACC_SIGN} + stamp ${ACC_STAMP} + manifest ${ACC_MANI} + arsc ${ACC_ARSC}
 UNACCOUNTED:          ${UNACC_TOTAL}   <- the verdict is judged on this alone
 Unmatched splits:     ${MISSING_TOTAL}

 Per-split detail:     ${WORK_DIR}/comparison/summary.txt
 Raw diffs:            ${WORK_DIR}/comparison/diff-unzipped-<split>.txt
 Build log:            ${WORK_DIR}/build.log
SUM

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
echo "Last modified by: ${LAST_MODIFIED_BY}"
echo "Last modified on: ${LAST_MODIFIED_ON}"
echo ""
echo "Diff:"
if [[ "$RAW_TOTAL" -eq 0 ]]; then
    echo "(no differing entries)"
else
    cat "${WORK_DIR}/comparison"/diff-unzipped-*.txt 2>/dev/null | grep -v '^$' | cap 5
fi
echo ""
echo "Revision, tag (and its signature):"
echo "Tag: ${TAG} ($([[ "$TAG_TYPE" == "commit" ]] && echo 'lightweight, no signature possible' || echo "$TAG_TYPE"))"
echo ""
echo "===== Also ====="
echo "channel:        google-play (split set)"
echo "appHashMeaning: base.apk exactly as supplied; not an aggregate of the split set"
echo "buildEnv:       nix develop at ${TAG} (Flutter 3.44.2, Rust 1.91.0, pinned Android SDK/NDK)"
echo "buildCmd:       ORG_GRADLE_PROJECT_nosign=true flutter build aab --release --target-platform android-arm64"
echo "bundletool:     ${BT_VER} (declared by AGP 8.12.0's POM; not proven to match Play's generator), sha256 ${BT_SHA}"
echo "deviceSpec:     $(cat "$SPEC")"
echo "sdkVersionSrc:  ${SDK_SRC}"
echo "signingState:   $(signing_state)"
echo "rawDiffs:       ${RAW_TOTAL}"
echo "acceptedDiffs:  ${ACC_TOTAL} (signing ${ACC_SIGN}, sourcestamp ${ACC_STAMP}, manifest ${ACC_MANI}, arsc ${ACC_ARSC})"
echo "unaccounted:    ${UNACC_TOTAL}"
echo "unmatched:      ${MISSING_TOTAL}"
echo "workspacePath:  ${WORK_DIR}  (appears in unstripped Rust DWARF; not a fixed path between runs)"
echo "note:           librust_lib_ngwallet.so ships unstripped with debug info and upstream sets no"
echo "                path remapping, so a difference in its debug sections is expected to be"
echo "                path-dependent. It is still a real difference and is counted, not excluded."
echo "===== End Results ====="
echo ""

write_yaml "$VERDICT" "Envoy Google Play split set, built with the project's own nix flake at ${TAG} and upstream's flutter build aab command, signing suppressed via the nosign project property. ${RAW_TOTAL} raw difference(s); ${ACC_TOTAL} earned exclusions - signing ${ACC_SIGN} (root META-INF signing filenames only, one-sided in the official direction), SourceStamp ${ACC_STAMP} (exactly one root entry, off-only, 32 bytes, apksigner verified), AndroidManifest ${ACC_MANI} (root file only; Play distribution meta-data with equal counts of blocks, allowlisted names and allowlisted values - the PAIRING of a given name to its own value is NOT proven), resources.arsc ${ACC_ARSC} (root file only; decoded res/ tree required identical). ${UNACC_TOTAL} UNACCOUNTED difference(s) - the verdict is judged on this alone. ${MISSING_TOTAL} split(s) unmatched. device-spec sdkVersion ${SDK}: ${SDK_SRC}. bundletool ${BT_VER} chosen from AGP 8.12.0's POM, not proven to match Play's generator. Official base.apk SHA-256 ${APP_HASH}. Rust and Dart git dependencies were fetched at the tag's lockfile-pinned refs and compiled as build inputs; their upstream repositories were not independently verified as separate artifacts."

if [[ "$VERDICT" == "reproducible" ]]; then
    log_ok "Verdict: reproducible -- every split has zero unaccounted differences"
    echo "Exit code: ${EXIT_SUCCESS}"
    exit "${EXIT_SUCCESS}"
fi
log_warn "Verdict: not_reproducible -- ${UNACC_TOTAL} unaccounted difference(s), ${MISSING_TOTAL} unmatched split(s)"
echo "Exit code: ${EXIT_FAILED}"
exit "${EXIT_FAILED}"
