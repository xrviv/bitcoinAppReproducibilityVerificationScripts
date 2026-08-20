#!/usr/bin/env bash
# ==============================================================================
# pcash_play_build.sh - P.CASH Terminal (Google Play) reproducible build verification
# ==============================================================================
# Version:          v0.6.3
# Organization:     WalletScrutiny.com
# Last Modified:    2026-08-20
# Last Modified by: WalletScrutiny.com
# App ID:           cash.p.terminal
# Project:          https://github.com/piratecash/pcash-wallet
# Play Store:       https://play.google.com/store/apps/details?id=cash.p.terminal
# ==============================================================================
#
# CHANNEL: GOOGLE PLAY (split APK set). For the single GPG-signed p.cash.apk on
# GitHub/F-Droid use pcash_fdroid_build.sh.
#
# P.CASH ships TWO builds from two branches with IDENTICAL versionName and
# versionCode, so version metadata cannot tell them apart. master (Firebase/GMS
# present) goes to Play; f-droid (those groups excluded) goes to GitHub/F-Droid.
# Lineage is DETECTED from artifact contents in PHASE 0, never assumed. master
# carries no tag: its revision is pinned by versionName AND versionCode.
#
# DISCLAIMER: provided for technical analysis and reproducible build verification
# only, with no warranty of security, functionality or fitness for any purpose.
# It performs automated builds and APK comparisons - review before running. Users
# are responsible for compliance with applicable laws.
#
# Exit codes: 0 = identical, 1 = difference or build failure, 2 = bad parameters.
# ==============================================================================

SCRIPT_VERSION="v0.6.3"

# Ties a verdict to the exact script bytes.
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "pcash_play_build.sh $SCRIPT_VERSION sha256:${SCRIPT_HASH:-unknown}"
echo "Starting pcash_play_build.sh $SCRIPT_VERSION (Google Play lineage)"

# Deliberately no -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="pcash_play_build.sh"
COUNTERPART="pcash_fdroid_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="cash.p.terminal"
REPO_URL="https://github.com/piratecash/pcash-wallet"
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

# LANDMINE: script_verifications.md rule 4 - the YAML MUST land in the SCRIPT's
# directory; that is where ABS looks. A $PWD-only copy is invisible to ABS when
# cwd != script dir. The $PWD copy below is convenience only.
# LANDMINE: do not "fix" this to $PWD alone; that silently breaks ABS pickup.
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
  # Convenience copy where the operator actually ran, so a local run does not
  # require digging in the scripts directory. ABS reads the one above.
  if [[ "$invocation_dir" != "$execution_dir" ]]; then
    cp -f "${execution_dir}/COMPARISON_RESULTS.yaml" \
       "${invocation_dir}/COMPARISON_RESULTS.yaml" 2>/dev/null || true
  fi
  log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

# Exit code is the CALLER's: 2 = bad params, 1 = build/compare failure.
fail() {
  local code="$1" note="$2"
  generate_yaml "ftbfs" "$note"
  echo ""; echo "Exit code: ${code}"
  exit "$code"
}

die_invalid() { log_error "$1"; fail 2 "Invalid invocation: $1"; }

# Root would leave root-owned artifacts, defeating the user mapping.
[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

# --version is OPTIONAL (ABS omits it); version comes from base.apk.
# Unknown parameters warn and continue, never fatal.

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""

require_arg() {
  local flag="$1" val="${2:-}"
  [[ -z "$val" || "$val" == --* ]] && \
    die_invalid "${flag} requires a value (got: '${val:-<nothing>}')"
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <dir-of-split-apks> [--version <v>] [--arch <a>] [--type <t>]

 --binary   REQUIRED. DIRECTORY of device-pulled splits: base.apk +
      split_config.*.apk. A single p.cash.apk is the other channel:
      use $COUNTERPART.
 --version/--arch/--type  Optional; logged. Version comes from base.apk.
 WS_DEVICE_SDK  env: device API level for the device-spec.

Exit codes: 0 = identical, 1 = any difference, 2 = invalid parameters.
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --version) require_arg --version "${2:-}"; version_arg="$2"; shift 2 ;;
    --binary)  require_arg --binary  "${2:-}"; binary_arg="$2";  shift 2 ;;
    --apk)     require_arg --apk     "${2:-}"; binary_arg="$2";  shift 2 ;;  # Android alias
    --arch)    require_arg --arch    "${2:-}"; arch_arg="$2";    shift 2 ;;
    --type)    require_arg --type    "${2:-}"; type_arg="$2";    shift 2 ;;
    -h|--help) usage; echo "Exit code: 0"; exit 0 ;;
    *)         log_warn "Unknown argument: $1 (ignored)"; shift; continue ;;
  esac
done

# --- --binary must be a DIRECTORY of splits: Play publishes nothing downloadable.

if [[ -z "$binary_arg" ]]; then
  log_error "--binary is required: the Play lineage cannot be downloaded."
  log_error "Pull the split set off a device (base.apk + split_config.*.apk) and pass its directory."
  log_error "If you have a single official p.cash.apk from GitHub Releases or F-Droid,"
  log_error "that is the other lineage - use $COUNTERPART instead."
  fail 2 "--binary not provided. The Google Play lineage requires a directory of device-pulled split APKs; it cannot be downloaded. For a single p.cash.apk use $COUNTERPART."
fi
[[ -e "$binary_arg" ]] || die_invalid "--binary path does not exist: ${binary_arg}"
if [[ ! -d "$binary_arg" ]]; then
  log_error "--binary must be a DIRECTORY of split APKs, but a single file was given:"
  log_error "  ${binary_arg}"
  log_error "A single p.cash.apk is the F-Droid/GitHub-release lineage, built from branch"
  log_error "f-droid with Firebase stripped. Verify it with $COUNTERPART instead."
  fail 2 "--binary was a single file, but the Google Play lineage is distributed as split APKs. A single p.cash.apk belongs to the F-Droid/GitHub lineage; use $COUNTERPART."
fi

OFFICIAL_DIR="$(realpath "$binary_arg")"
[[ -f "${OFFICIAL_DIR}/base.apk" ]] || \
  die_invalid "Split directory has no base.apk: ${OFFICIAL_DIR}"

declare -a OFFICIAL_SPLITS=()
while IFS= read -r f; do OFFICIAL_SPLITS+=("$f"); done \
  < <(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' | sort)
# Reject stray APKs: none may silently join the official set.
for f in "${OFFICIAL_SPLITS[@]}"; do
  bn="$(basename "$f")"
  [[ "$bn" == "base.apk" || "$bn" == split_config*.apk ]] || \
    die_invalid "Unexpected APK in split dir: ${bn} (only base.apk and split_config*.apk allowed)"
done
apk_file="${OFFICIAL_DIR}/base.apk"
log_info "${#OFFICIAL_SPLITS[@]} official split(s) found in ${OFFICIAL_DIR}"

[[ -n "$arch_arg" ]]    && log_info "--arch ${arch_arg} accepted; ABIs are derived from the official split set"
[[ -n "$type_arg" ]]    && log_info "--type ${type_arg} accepted but not used"
[[ -n "$version_arg" ]] && log_info "--version ${version_arg} accepted; the authoritative version comes from base.apk"

# Write-path runs map container user -> host user (else root-owned leftovers
# need sudo). HOME=/tmp: apktool caches under $HOME.

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v docker &>/dev/null; then
    CONTAINER_CMD=docker
  elif command -v podman &>/dev/null; then
    CONTAINER_CMD=podman
  else
    die_invalid "Neither docker nor podman found in PATH"
  fi
fi

if [[ "$CONTAINER_CMD" == "podman" ]]; then
  CONTAINER_RUN_USER_ARGS=(--userns=keep-id -e HOME=/tmp)
else
  CONTAINER_RUN_USER_ARGS=(--user "${HOST_UID}:${HOST_GID}" -e HOME=/tmp)
fi

MEM_LIMIT="${MEM_LIMIT:-16g}"
MEM_ARGS=()
[[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")

# Single entry point so the user mapping cannot be forgotten.
crun() {
  $CONTAINER_CMD run --rm "${CONTAINER_RUN_USER_ARGS[@]}" "${MEM_ARGS[@]}" "$@"
}

section "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-10s OK  (%s)\n" "$CONTAINER_CMD" "$(command -v "$CONTAINER_CMD")"
echo "  No host JDK, Gradle, Android SDK, bundletool or apktool is required or used."

# Keeps parallel arch/type runs from colliding on image/workspace names.
RUN_ID="pcash-play-$(date +%s)-$$"
IMG="ws-pcash-play-${RUN_ID}"
workspace="${execution_dir}/pcash_play_verification_${RUN_ID}"
META_DIR="${workspace}/metadata"
BUILD_DIR="${workspace}/source-build"
CMP_DIR="${workspace}/comparison"
img_ctx=""

mkdir -p "$META_DIR" "$BUILD_DIR" "$CMP_DIR"

# Reclaims ownership on EVERY exit path so cleanup never needs sudo.
# LANDMINE: deliberately does NOT use crun() - it must run as ROOT inside the
# container to chown. Adding the user mapping here would break cleanup.
ensure_user_ownership() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1 || return 0
  $CONTAINER_CMD run --rm -v "${path}:/target" "$IMG" \
    sh -c "chown -R ${HOST_UID}:${HOST_GID} /target" >/dev/null 2>&1 || \
    log_warn "Could not normalise ownership for ${path}"
}

cleanup() {
  log_info "Cleaning up build image and temporary context..."
  ensure_user_ownership "$workspace"
  $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1 || true
  [[ -n "$img_ctx" ]] && rm -rf "$img_ctx" 2>/dev/null
  log_success "Cleanup complete."
}
trap cleanup EXIT

banner "P.CASH TERMINAL WALLET - GOOGLE PLAY LINEAGE VERIFICATION"
cat <<EOF
 Script:    ${SCRIPT_NAME} $SCRIPT_VERSION
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Splits:    ${OFFICIAL_DIR}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${workspace}
 Date:      $(date)
EOF

# One pinned image for metadata, build and comparison. JDK 21 (app
# targets Java 17). No NDK: nothing native is compiled.

phase "SETUP: BUILD CONTAINER IMAGE"

img_ctx="$(mktemp -d)"

cat > "${img_ctx}/Dockerfile" <<'DOCKERFILE_END'
FROM ubuntu:24.04@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk-headless git unzip zip wget curl ca-certificates binutils python3 && \
  rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${JAVA_HOME}/bin:${PATH}"

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
  cd ${ANDROID_HOME}/cmdline-tools && \
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    -O cmdline-tools.zip && \
  unzip -q cmdline-tools.zip && rm cmdline-tools.zip && mv cmdline-tools latest

RUN yes | sdkmanager --licenses >/dev/null && \
  sdkmanager "platforms;android-36" "build-tools;36.0.0" "platform-tools" >/dev/null

# LANDMINE: must match the bundletool AGP embeds (AGP 9.0.1 -> 1.18.3), which
# sparse-encodes SDK 32+ and injects the variant min into split manifests; older
# versions do neither and fake diffs. Re-pin whenever AGP moves.
ADD https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar /opt/bundletool.jar
ADD https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar /opt/apktool.jar
RUN chmod 0644 /opt/bundletool.jar /opt/apktool.jar

# LANDMINE: WORKDIR alone creates /build root-owned and the mapped-user git clone
# then fails with "could not create work tree dir". Keep /build in this chmod.
RUN mkdir -p /tmp/afw /build && chmod 0777 /tmp /tmp/afw /build
WORKDIR /build
DOCKERFILE_END

section "Building image ${IMG}"
if ! $CONTAINER_CMD build -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx"; then
  log_error "Container image build failed - see the build output above."
  fail 1 "Container image build failed; no comparison was performed."
fi
log_success "Image built: ${IMG}"

# --- PHASE 0: metadata from base.apk + the lineage detector over the whole set.

phase "PHASE 0: OFFICIAL BINARY METADATA"

cat > "${img_ctx}/meta.sh" <<'META_END'
#!/bin/bash
set -uo pipefail
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"
APKSIGNER="$BT/apksigner"

info="$("$AAPT2" dump badging /input/official.apk 2>/dev/null)"

# LANDMINE: anchor on '^package:' and stop at the first quote. A greedy '.*name='
# matches versionName= and silently returns the wrong value.
pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"

signer="$("$APKSIGNER" verify --print-certs /input/official.apk 2>/dev/null \
  | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"

# A true base APK declares no split name; config splits do.
split_name="$(printf '%s\n' "$info" | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
printf '%s\n' "${split_name}" > /output/base_split_name.txt

printf '%s\n' "${pkg:-unknown}"    > /output/pkg_name.txt
printf '%s\n' "${vname:-unknown}"  > /output/version_name.txt
printf '%s\n' "${vcode:-unknown}"  > /output/version_code.txt
printf '%s\n' "${signer:-unknown}" > /output/signer.txt

rm -rf /tmp/dex && mkdir -p /tmp/dex
unzip -q -o /input/official.apk 'classes*.dex' -d /tmp/dex 2>/dev/null
: > /output/gh.txt
: > /output/git_branch.txt
: > /output/ghc.txt
if compgen -G "/tmp/dex/classes*.dex" > /dev/null; then
  # LANDMINE: this app's GIT_HASH is ALWAYS "<10hex>-fdroid" or the literal
  # "unknown" - a BARE 10-hex string is an unrelated dex literal. Do not loosen
  # this pattern or drop the all-same-char filter: it then picks "0000000000".
  strings -a /tmp/dex/classes*.dex 2>/dev/null \
    | grep -xE '[0-9a-f]{10}(-dirty)?(-fdroid)?|unknown' \
    | awk '{ h=$0; sub(/-.*$/,"",h);
        if (h=="unknown") { print; next }
        c=substr(h,1,1); u=0;
        for(i=2;i<=length(h);i++) if(substr(h,i,1)!=c) { u=1; break }
        if (u) print }' \
    | sort -u > /output/ghc.txt
  # Preference order matches what the branch can actually emit.
  grep -m1 -xE '[0-9a-f]{10}(-dirty)?-fdroid' /output/ghc.txt \
    > /output/gh.txt 2>/dev/null || \
  grep -m1 -x 'unknown' /output/ghc.txt \
    > /output/gh.txt 2>/dev/null || \
  head -1 /output/ghc.txt > /output/gh.txt 2>/dev/null || true
  # LANDMINE: report EVERY match, never `head -1`. "f-droid" sorts before
  # "master", so head -1 always claims "f-droid" when both literals appear
  # anywhere in the dex - making it non-probative. See changelog 2026-08-20.
  strings -a /tmp/dex/classes*.dex 2>/dev/null \
    | grep -xE 'f-droid|master' | sort -u | paste -sd, - > /output/git_branch.txt || true
fi

# LANDMINE: scan the WHOLE split set and look PAST zip entry names.
# libcrashlytics*.so live in split_config.<abi>.apk; Google Sign-In resources are
# compiled INSIDE resources.arsc. Four signals; ANY hit = present; the firing
# signal is reported. bp (baseline.prof) NEVER infers lineage.
GPAT='firebase|crashlytics|com/google/android/gms|com\.google\.android\.gms'
fb=0; bp=0; sigs=""

# (a) zip entry names and (b) native lib names, in EVERY split - one listing each
for f in /official/*.apk; do
  L="$(unzip -l "$f" 2>/dev/null)"; n="$(basename "$f")"
  printf '%s' "$L" | grep -qiE "$GPAT" && { fb=1; sigs="${sigs}zipnames:${n} "; }
  printf '%s' "$L" | grep -qiE 'lib/[^/]+/lib(crashlytics|gms|google)' \
    && { fb=1; sigs="${sigs}nativelib:${n} "; }
  printf '%s' "$L" | grep -q 'assets/dexopt/baseline.prof' && bp=1
done
# (c) dex string pool of base.apk (class names, not entry names)
if compgen -G "/tmp/dex/classes*.dex" > /dev/null; then
  if strings -a /tmp/dex/classes*.dex 2>/dev/null \
    | grep -qE 'com\.google\.firebase|com\.google\.android\.gms'; then
    fb=1; sigs="${sigs}dexstrings:base.apk "
  fi
fi
# (d) DECODED resources.arsc of base.apk - compiled-in resources, invisible to grep.
rm -rf /tmp/dres
if java -jar /opt/apktool.jar d -f --no-src --no-debug-info \
    --frame-path /tmp/afw -o /tmp/dres /official/base.apk >/dev/null 2>&1; then
  if [ -d /tmp/dres/res ] && grep -rqiE 'common_google_signin|com\.google\.android\.gms' /tmp/dres/res 2>/dev/null; then
    fb=1; sigs="${sigs}resources.arsc:base.apk "
  fi
else
  sigs="${sigs}resources.arsc:DECODE-FAILED "
fi

printf '%s\n' "$fb" > /output/has_firebase.txt
printf '%s\n' "$bp" > /output/has_baseline_profile.txt
printf '%s\n' "${sigs:-none}" > /output/google_signals.txt

cat <<META
[META] package:             ${pkg:-unknown}
[META] versionName:         ${vname:-unknown}
[META] versionCode:         ${vcode:-unknown}
[META] signer SHA-256:      ${signer:-unknown}
[META] GIT_HASH (dex):      $(cat /output/gh.txt 2>/dev/null)
[META] GIT_HASH candidates: $(wc -l < /output/ghc.txt 2>/dev/null) (>1 means the choice is ambiguous)
[META] GIT_BRANCH literals: $(cat /output/git_branch.txt 2>/dev/null) (all matches; not proof of source branch)
[META] base split name:     $(cat /output/base_split_name.txt 2>/dev/null) (empty = true base APK)
[META] google/firebase:     ${fb}   signals: ${sigs:-none}
[META] baseline.prof:       ${bp}
META
META_END
chmod +x "${img_ctx}/meta.sh"

if ! crun \
  --volume "${apk_file}:/input/official.apk:ro" \
  --volume "$OFFICIAL_DIR:/official:ro" \
  --volume "${META_DIR}:/output" \
  --volume "${img_ctx}/meta.sh:/meta.sh:ro" \
  "$IMG" bash /meta.sh; then
  log_error "Metadata extraction failed - aapt2/apksigner could not read base.apk."
  fail 1 "Could not read metadata from base.apk."
fi

pkg_id="$(cat "${META_DIR}/pkg_name.txt" 2>/dev/null || echo unknown)"
wallet_version="$(cat "${META_DIR}/version_name.txt" 2>/dev/null || echo unknown)"
version_code="$(cat "${META_DIR}/version_code.txt" 2>/dev/null || echo unknown)"
signer="$(cat "${META_DIR}/signer.txt" 2>/dev/null || echo unknown)"
git_hash="$(cat "${META_DIR}/git_hash.txt" 2>/dev/null || echo '')"
git_branch="$(cat "${META_DIR}/git_branch.txt" 2>/dev/null || echo '')"
has_firebase="$(cat "${META_DIR}/has_firebase.txt" 2>/dev/null || echo 0)"
has_baseline="$(cat "${META_DIR}/has_baseline_profile.txt" 2>/dev/null || echo 0)"
google_signals="$(cat "${META_DIR}/google_signals.txt" 2>/dev/null || echo none)"
app_hash="$(sha256of "$apk_file")"

# Mandatory package-name check, before anything is built.
[[ "$pkg_id" == "$APP_ID" ]] || \
  die_invalid "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
log_success "Package name verified: ${pkg_id}"
log_success "Version: $wallet_version (versionCode $version_code)"
log_info    "Signer SHA-256:   ${signer}"
log_info    "base.apk SHA-256: ${app_hash}"
log_info    "GIT_HASH in dex:  ${git_hash:-<not recovered>}"

[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || \
  die_invalid "Could not read versionName from base.apk"
[[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]] && \
  log_warn "--version was '${version_arg}' but base.apk reports '$wallet_version'; using the binary's value"

# --- Packaging guard: Play ships a split set, the other channel one APK. This
# checks SHAPE only; lineage comes from the detector above.

section "Packaging check"
base_split="$(cat "${META_DIR}/base_split_name.txt" 2>/dev/null || echo '')"
config_splits=0
for f in "${OFFICIAL_SPLITS[@]}"; do
  [[ "$(basename "$f")" == split_config*.apk ]] && config_splits=$((config_splits + 1))
done
cat <<EOF
 base.apk split name:      ${base_split:-<none>}  (a true base APK declares none)
 split_config APKs:        ${config_splits}
 Google/Firebase present:  ${has_firebase}  <- SELECTS THE SOURCE BRANCH
 detector signals:         $google_signals
 baseline.prof present:    ${has_baseline}  (reported only; never infers lineage)
 GIT_HASH literal:         ${git_hash:-<not recovered>}  (informational)
 GIT_BRANCH literals:      ${git_branch:-<none>}  (informational)
EOF

if [[ -n "$base_split" ]]; then
  log_error "base.apk declares split name '${base_split}', so it is not a base APK."
  log_error "Supply the directory exactly as pulled from the device."
  fail 2 "base.apk declares split name '${base_split}'; a Play base APK declares none. Not a valid Play split set."
fi
if [[ "$config_splits" -eq 0 ]]; then
  log_error "No split_config.*.apk found - this is a single-APK artifact, not a Play split set."
  log_error "Google Play delivers this app as an App Bundle split set; a lone p.cash.apk"
  log_error "is the GitHub/F-Droid packaging of the SAME source."
  log_error "Verify it with $COUNTERPART instead."
  fail 2 "No split_config APKs present: the artifact is a single APK, which is the GitHub/F-Droid packaging built from a DIFFERENT branch (f-droid). Use $COUNTERPART."
fi
log_success "Play packaging confirmed: base APK + ${config_splits} config split(s)"

# Revision follows DETECTED lineage: Firebase/GMS => master (no tag; pinned by
# versionName+versionCode). Absent => f-droid.

section "Resolving source revision"
if [[ "$has_firebase" != "1" ]]; then
  log_error "No Google/Firebase signal in this split set, so it is not the master"
  log_error "build that Play ships. Refusing: building the f-droid branch and"
  log_error "comparing across lineages is exactly how v0.3.x produced 1,314 bogus"
  log_error "diffs. Check the artifact's provenance, or use $COUNTERPART."
  fail 2 "Lineage anomaly: a Play split set with no Google/Firebase signal (detector: $google_signals). Play ships the master build, which contains both. Refusing rather than comparing across lineages."
fi
LINEAGE="master"
GIT_BRANCH_NAME="master"
log_info "Google/Firebase present -> MASTER lineage. Signals: $google_signals"
echo "  Revision: pinned in-container by versionName $wallet_version + versionCode $version_code"
echo "  Branch to recreate: ${GIT_BRANCH_NAME}   Gradle flag: none (-Pfdroid is f-droid only)"

# LANDMINE: GIT_HASH cannot be recovered reliably from a dex string pool - only
# the "<10hex>-fdroid" form is distinctive; bare 10-hex and "unknown" collide with
# unrelated literals. Informational cross-check ONLY, never a gate.
case "$git_hash" in
  *-dirty) log_warn "GIT_HASH ends in -dirty: built from uncommitted changes." ;;
  *)       log_info "GIT_HASH in binary: ${git_hash:-<none>} (not authoritative)" ;;
esac

# --- PHASE 1: build. Needs a real git checkout - app/build.gradle shells out to
# `git rev-parse`. No secrets to inject.

phase "PHASE 1: BUILD FROM SOURCE"
echo "  Gradle:  ./gradlew clean :app:bundleRelease"

cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail

REPO_URL="__REPO_URL__"
GIT_BRANCH_NAME="__GIT_BRANCH_NAME__"
WANT_VNAME="__WANT_VNAME__"
WANT_VCODE="__WANT_VCODE__"

# app/build.gradle THROWS if some but not all four FIREBASE_DEV_* are set;
# BUILD_NUMBER overrides versionCode.
unset FIREBASE_DEV_KEYSTORE_PATH FIREBASE_DEV_STORE_PASSWORD \
   FIREBASE_DEV_KEY_ALIAS FIREBASE_DEV_KEY_PASSWORD BUILD_NUMBER

export GRADLE_USER_HOME=/tmp/gradle-home
mkdir -p "$GRADLE_USER_HOME"

echo "=== Clone ${REPO_URL} === $(date)"
# Full clone: the recovered abbreviated commit is not fetchable by a shallow one.
git clone "$REPO_URL" /build/src || { echo "FATAL: clone failed"; exit 1; }
cd /build/src
git config --global --add safe.directory /build/src

# Pin by walking master's first-parent line for commits declaring BOTH
# versionName and versionCode; the code disambiguates a shared name.
echo "=== Pinning master revision for ${WANT_VNAME} / versionCode ${WANT_VCODE} ==="
: > /output/mc.txt
for c in $(git rev-list --first-parent origin/master); do
  g=$(git show "$c:app/build.gradle" 2>/dev/null)
  vn=$(printf '%s' "$g" | grep -m1 'versionName' | sed 's/.*versionName *"\([^"]*\)".*/\1/')
  vc=$(printf '%s' "$g" | grep -m1 'versionCode' | sed 's/.*versionCode *\([0-9]*\).*/\1/')
  if [[ "$vn" == "$WANT_VNAME" && "$vc" == "$WANT_VCODE" ]]; then
    echo "$c" >> /output/mc.txt
  elif [[ -s /output/mc.txt ]]; then
    break   # walked past the version window; stop
  fi
done
n=$(wc -l < /output/mc.txt)
echo "Candidate commits: ${n}"
while read -r c; do echo "  ${c:0:10}  $(git log -1 --format=%s "$c" | cut -c1-60)"; done < /output/mc.txt
if [[ "$n" -eq 0 ]]; then
  echo "FATAL: no master commit declares versionName ${WANT_VNAME} with versionCode ${WANT_VCODE}."
  echo "The published artifact cannot be matched to any public master revision."
  exit 4
fi
# Newest candidate is the release tip for that versionCode. Overridable.
GIT_REF="${WS_MASTER_COMMIT:-$(head -1 /output/mc.txt)}"
printf '%s\n' "$n" > /output/candidate-count.txt
echo "Building: ${GIT_REF}"
[[ "$n" -gt 1 ]] && echo "AMBIGUOUS: ${n} commits share this versionName+versionCode."

# Named branch, not detached HEAD: the branch name feeds getGitVersionSuffix().
if ! git checkout -B "$GIT_BRANCH_NAME" "$GIT_REF"; then
  echo "FATAL: could not check out tag '${GIT_REF}'"
  echo "Tags near this version:"
  git tag | grep -F "${GIT_REF%-fdroid}" || true
  exit 2
fi

echo "=== Revision under build ==="
git log -1 --pretty=format:'%H %ci %s' ; echo
git rev-parse HEAD > /output/commit.txt
git rev-parse --short=10 HEAD > /output/expected_git_hash.txt

# A dirty tree makes app/build.gradle append "-dirty" to BuildConfig.GIT_HASH.
if ! git diff-index --quiet HEAD --; then
  echo "FATAL: working tree is dirty immediately after checkout; refusing to build"
  git status --porcelain | head -20
  exit 2
fi

echo "=== Toolchain ==="; java -version 2>&1; ./gradlew --version 2>&1 | sed -n '1,12p'
echo "=== Gradle build === $(date)"
./gradlew --no-daemon --max-workers=2 clean :app:bundleRelease \
  > /output/gradle-build.log 2>&1
rc=$?
tail -60 /output/gradle-build.log
if [[ $rc -ne 0 ]]; then
  echo "FATAL: gradle build failed (exit ${rc}) - full log at /output/gradle-build.log"
  exit 3
fi

echo ""
echo "=== Split the AAB with bundletool === $(date)"
aab="$(find app/build/outputs/bundle -name '*.aab' | head -1)"
if [[ -z "$aab" ]]; then
  echo "FATAL: no .aab produced under app/build/outputs/bundle"
  exit 3
fi
cp "$aab" /output/app-release.aab
AAPT2="$(find "$ANDROID_HOME/build-tools" -name aapt2 | sort | tail -1)"

# Device-spec from OFFICIAL split names; a wrong spec surfaces as UNMATCHED,
# never a false pass. No language splits exist.
ABIS=(); DEN=""
for f in /official/*.apk; do
  c="$(basename "$f")"; c="${c#*config.}"; c="${c%.apk}"
  case "$c" in
    arm64_v8a|armeabi_v7a|x86_64|x86) ABIS+=("${c//_/-}") ;;
    ldpi) DEN=120 ;; mdpi) DEN=160 ;; tvdpi) DEN=213 ;; hdpi) DEN=240 ;;
    xhdpi) DEN=320 ;; xxhdpi) DEN=480 ;; xxxhdpi) DEN=640 ;;
  esac
done
# app/build.gradle restricts abiFilters to armeabi-v7a and arm64-v8a.
[[ ${#ABIS[@]} -eq 0 ]] && ABIS=("arm64-v8a")
[[ -z "$DEN" ]] && DEN=480
# Device API level: a property of the PHONE, not readable from the APKs. Selects
# the AAB variant. Pass WS_DEVICE_SDK=$(adb shell getprop ro.build.version.sdk).
if [[ -n "${WS_DEVICE_SDK:-}" ]]; then
  SDK="$WS_DEVICE_SDK"; SDK_SRC="supplied via WS_DEVICE_SDK"
else
  SDK=36; SDK_SRC="DEFAULT GUESS -- pass WS_DEVICE_SDK to set the real value"
fi
echo "=== device sdkVersion: ${SDK} (${SDK_SRC}) ==="
ABIJSON="$(printf '"%s",' "${ABIS[@]}")"; ABIJSON="[${ABIJSON%,}]"
printf '{"supportedAbis":%s,"supportedLocales":["en"],"screenDensity":%s,"sdkVersion":%s}\n' \
  "$ABIJSON" "$DEN" "$SDK" > /output/device-spec.json
echo "=== device-spec.json ==="; cat /output/device-spec.json

java -jar /opt/bundletool.jar build-apks --bundle="$aab" \
  --output=/output/built.apks --device-spec=/output/device-spec.json \
  --aapt2="$AAPT2" --overwrite || { echo "FATAL: bundletool build-apks failed"; exit 3; }
mkdir -p /output/built /output/bt
unzip -q -o /output/built.apks 'splits/*.apk' -d /output/bt
cp /output/bt/splits/*.apk /output/built/
echo "=== built splits ==="
sha256sum /output/built/*.apk

echo ""
echo "=== Dependency provenance (JitPack / piratecash forks) ==="
# PUBLISHED BINARIES, not rebuilt: a byte-match proves both sides fetched the same
# AAR, NOT that the AAR matches its source. Recorded so a re-run spots a moved tag.
grep -Eo 'https://jitpack\.io/[^ ]+\.(aar|jar|pom)' /output/gradle-build.log 2>/dev/null \
  | sort -u > /output/jitpack-artifacts.txt || true
find "$GRADLE_USER_HOME/caches/modules-2/files-2.1" -path '*com.github.piratecash*' \
  -name '*.aar' -print0 2>/dev/null | xargs -0 -r sha256sum > /output/aar-hashes.txt 2>&1 || true
echo "  JitPack URLs: $(wc -l < /output/jitpack-artifacts.txt 2>/dev/null || echo 0)  AARs: $(wc -l < /output/aar-hashes.txt 2>/dev/null || echo 0)"

echo ""
echo "=== Build complete $(date) ==="
BUILD_END

sed -i \
  -e "s|__REPO_URL__|${REPO_URL}|g" \
  -e "s|__GIT_BRANCH_NAME__|${GIT_BRANCH_NAME}|g" \
  -e "s|__WANT_VNAME__|$wallet_version|g" \
  -e "s|__WANT_VCODE__|$version_code|g" \
  "${img_ctx}/build.sh"
chmod +x "${img_ctx}/build.sh"

section "Source build (30-90 min cold) - $(date)"
crun \
  -e "WS_DEVICE_SDK=${WS_DEVICE_SDK:-}" \
  --volume "$OFFICIAL_DIR:/official:ro" \
  --volume "${BUILD_DIR}:/output" \
  --volume "${img_ctx}/build.sh:/build/build.sh:ro" \
  "$IMG" bash /build/build.sh 2>&1 | tee "${BUILD_DIR}/container-build.log"
BUILD_RC=${PIPESTATUS[0]}

if [[ $BUILD_RC -ne 0 ]]; then
  # Container exit codes: 1 clone, 2 checkout/dirty tree, 3 gradle/bundletool,
  # 4 = no master commit matches this versionName+versionCode.
  if [[ $BUILD_RC -eq 4 ]]; then
    log_error "Cannot pin a revision: no master commit declares versionName $wallet_version"
    log_error "with versionCode $version_code. This is a FINDING, not a script fault."
    fail 1 "Google Play (master lineage): no public master commit declares versionName $wallet_version with versionCode $version_code, so the shipped artifact cannot be matched to published source. No build attempted. Official base.apk SHA-256: ${app_hash}."
  fi
  log_error "Source build failed (container exit ${BUILD_RC}: 1=clone, 2=checkout, 3=gradle/bundletool)"
  log_info  "Full Gradle log: ${BUILD_DIR}/gradle-build.log"
  fail 1 "Source build failed for ${APP_ID} $wallet_version (container exit ${BUILD_RC}). Official base.apk SHA-256: ${app_hash}."
fi
log_success "Source build finished"

candidate_count="$(cat "${BUILD_DIR}/candidate-count.txt" 2>/dev/null || echo 1)"
built_ref="$(cat "${BUILD_DIR}/commit.txt" 2>/dev/null | cut -c1-10)"
if [[ "${candidate_count:-1}" -gt 1 ]]; then
  log_warn "AMBIGUOUS: ${candidate_count} master commits declare $wallet_version/$version_code."
  log_warn "Built the newest (${built_ref}). List: ${BUILD_DIR}/master-candidates.txt"
fi
built_hash_expect="$(cat "${BUILD_DIR}/expected_git_hash.txt" 2>/dev/null || echo '')"
if [[ -n "$git_hash" && -n "$built_hash_expect" ]]; then
  if [[ "${git_hash%%-*}" == "$built_hash_expect" ]]; then
    log_success "Revision cross-check: official GIT_HASH matches the built commit (${built_hash_expect})"
  else
    log_warn "Revision cross-check MISMATCH: binary reports '${git_hash}', built commit is '${built_hash_expect}'"
  fi
fi

# --- PHASE 2: compare. NO general acceptable-diffs filtering. resources.arsc
# decode is the one sanctioned exception. Previews capped at 5 lines.

phase "PHASE 2: PER-SPLIT COMPARISON"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"
APKSIGNER="$BT/apksigner"

# LANDMINE: the config key MUST come from the APK's own split= attribute, never
# its filename. Device splits are split_config.arm64_v8a.apk while bundletool
# emits base-arm64_v8a.apk for the same config, so filename matching pairs
# nothing and every config reads UNMATCHED -> false not_reproducible.
cfg_of() {
  local s
  s="$("$AAPT2" dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
  s="${s#config.}"
  [[ -z "$s" ]] && s="base"
  printf '%s' "$s"
}

# LANDMINE: resource-aware (ElementTree), NEVER a line filter - <item> lines do
# not carry their parent array name, so a grep filter can silently swallow a
# change elsewhere. Every guard fails CLOSED.
cat > /tmp/cn.py <<'PYEOF'
import sys, os, re, collections
import xml.etree.ElementTree as ET
B = 'com.google.firebase.crashlytics.build_ids_'
N = (B + 'lib', B + 'arch', B + 'build_id')
def die(m): print("REFUSED: " + m); sys.exit(1)
def collect(root, sd):
    out = {}
    for dp, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith('.xml'): continue
            p = os.path.join(dp, f)
            try: t = ET.parse(p)
            except Exception as e: die("XML parse fail %s (%s): %s" % (p, sd, e))
            for el in t.getroot().iter('string-array'):
                nm = el.get('name')
                if nm not in N: continue
                if os.path.basename(dp) != 'values': die("qualified %s in %s (%s)" % (nm, dp, sd))
                if nm in out: die("duplicate %s (%s)" % (nm, sd))
                out[nm] = [p, t, el]
    return out
def triples(o, sd):
    cols = []
    for nm in N:
        if nm not in o: die("%s missing (%s)" % (nm, sd))
        cols.append([(e.text or '').strip() for e in o[nm][2].findall('item')])
    L = len(cols[0])
    if L == 0: die("empty arrays (%s)" % sd)
    if any(len(c) != L for c in cols): die("lengths %s (%s)" % ([len(c) for c in cols], sd))
    t = list(zip(*cols))
    for lib, arch, bid in t:
        if not (lib and arch and bid): die("empty field (%s)" % sd)
        if not re.fullmatch(r'[0-9a-fA-F]+', bid): die("non-hex build_id %r (%s)" % (bid, sd))
    return t
def canon(o, t):
    cols = list(zip(*sorted(t)))
    for i, nm in enumerate(N):
        path, tree, el = o[nm]
        for it in list(el.findall('item')): el.remove(it)
        for v in cols[i]: ET.SubElement(el, 'item').text = v
        tree.write(path, encoding='utf-8', xml_declaration=True)
oo, bb = collect(sys.argv[1], 'off'), collect(sys.argv[2], 'blt')
to, tb = triples(oo, 'off'), triples(bb, 'blt')
if len(to) != len(tb): die("count %d off vs %d blt" % (len(to), len(tb)))
co, cb = collections.Counter(to), collections.Counter(tb)
if co != cb: die("multiset differs: %d off-only, %d blt-only occurrence(s)"
                 % (sum((co - cb).values()), sum((cb - co).values())))
canon(oo, to); canon(bb, tb)
print("3 arrays, lengths %d/%d/%d both sides, %d triples, Counter equal "
      "(multiplicity kept)" % ((len(to),) * 4))
PYEOF

# SourceStamp: EARNED, never filename-excluded. Play injects it post-build.
stamp_ok() {
  local o="$1" n sz
  n=$(unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256')
  [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
  [[ -e /tmp/b/stamp-cert-sha256 ]] && { echo "      stamp: present in BUILT too"; return 1; }
  sz=$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null || echo -1)
  [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
  "$APKSIGNER" verify --verbose --print-certs "$o" 2>/dev/null \
    | grep -q 'Verified for SourceStamp: true' \
    || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
  echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

# AndroidManifest: accepted ONLY if the sole delta is Play's three distribution
# meta-data entries, off-only, with exactly the expected values.
manifest_ok() {
  local o="$1" b="$2" c="$3" d left bad n
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null || return 1
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null || return 1
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"
  printf '%s\n' "$d" > "/out/diff_manifest_${c}.txt"
  printf '%s\n' "$d" | grep -q '^>' && { echo "      manifest: BUILT-only lines present"; return 1; }
  left="$(printf '%s\n' "$d" | grep '^<' | sed 's/^< *//')"
  # LANDMINE: aapt2 prints the full ns URI before :name/:value, ints as bare "=4".
  bad="$(printf '%s\n' "$left" | grep -vE '^E: meta-data|^A: [^ ]*android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)=4$')"
  if [[ -n "$(printf '%s' "$bad" | tr -d '[:space:]')" ]]; then
    echo "      manifest: unexpected off-only line(s):"
    printf '%s\n' "$bad" | head -3 | sed 's/^/        /'
    return 1
  fi
  # LANDMINE: base has 3 Play entries, config splits only derived.apk.id; a fixed
  # count of 3 falsely fails them. Blocks must equal allowlisted names.
  n=$(printf '%s\n' "$left" | grep -c '^E: meta-data')
  m=$(printf '%s\n' "$left" | grep -c 'android:name(0x[0-9a-f]*)="com\.android\.')
  [[ "$n" -ge 1 && "$n" -eq "$m" ]] || { echo "      manifest: $n block(s) vs $m Play name(s)"; return 1; }
  echo "      manifest: $n off-only Play meta-data, none built-only"
}

# resources.arsc: decode both, then the verdict table extended with the
# cl-buildid-order-only class. Decode failure is NEVER accepted.
ARSC_CLASS=""
arsc_ok() {
  local o="$1" b="$2" c="$3" rd rd2
  rm -rf /tmp/do /tmp/db
  $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw \
    -o /tmp/do "$o" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (official)"; return 1; }
  $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw \
    -o /tmp/db "$b" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (built)"; return 1; }
  [[ -d /tmp/do/res && -d /tmp/db/res ]] || { echo "      arsc: no res/ after decode"; return 1; }
  rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
  printf '%s\n' "$rd" > "/out/diff_resources_decoded_${c}.txt"
  if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then
    ARSC_CLASS="decoded-identical"
    echo "      arsc: decoded res/ tree IDENTICAL (binary packing artifact)"
    return 0
  fi
  if python3 /tmp/cn.py /tmp/do/res /tmp/db/res > /tmp/cn.txt 2>&1; then
    sed 's/^/      arsc: /' /tmp/cn.txt
    rd2="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
    printf '%s\n' "$rd2" > "/out/diff_resources_normalised_${c}.txt"
    if [[ -z "$(printf '%s' "$rd2" | tr -d '[:space:]')" ]]; then
      ARSC_CLASS="cl-buildid-order-only"
      echo "      arsc: canonicalised FULL decoded res/ IDENTICAL"
      return 0
    fi
    echo "      arsc: other decoded changes remain AFTER normalisation -> material"
    printf '%s\n' "$rd2" | head -5 | sed 's/^/        /'
    return 1
  fi
  sed 's/^/      arsc: /' /tmp/cn.txt
  return 1
}

declare -A OFF BLT
for f in /official/*.apk; do OFF["$(cfg_of "$f")"]="$f"; done
for f in /built/*.apk;    do BLT["$(cfg_of "$f")"]="$f"; done

RAW=0; SIGN=0; STAMP=0; MANI=0; ARSC=0; UNACC=0; MISSING=0; FAILED=0
SIGRE='\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)'
: > /out/summary.txt

for cfg in $(printf '%s\n' "${!OFF[@]}" "${!BLT[@]}" | sort -u); do
  echo ""
  echo "======== split: ${cfg} ========"
  o="${OFF[$cfg]:-}"; b="${BLT[$cfg]:-}"
  if [[ -z "$o" || -z "$b" ]]; then
    echo "  UNMATCHED  official=$([[ -n $o ]] && echo yes || echo NO)  built=$([[ -n $b ]] && echo yes || echo NO)"
    echo "${cfg} UNMATCHED 0 0 0 0 0" >> /out/summary.txt
    MISSING=$((MISSING + 1)); continue
  fi

  echo "  official: $(basename "$o")  sha256 $(sha256sum "$o" | cut -d' ' -f1)"
  echo "  built:    $(basename "$b")  sha256 $(sha256sum "$b" | cut -d' ' -f1)"

  rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
  unzip -q -o "$o" -d /tmp/o
  unzip -q -o "$b" -d /tmp/b
  echo "  entries: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"

  # Per-ABI native lib hashes. A .so on one side only is a hard fail.
  while IFS= read -r so; do
    rel="${so#/tmp/o/}"
    if [[ -f "/tmp/b/${rel}" ]]; then
      ho="$(sha256sum "$so" | cut -d' ' -f1)"; hb="$(sha256sum "/tmp/b/${rel}" | cut -d' ' -f1)"
      [[ "$ho" == "$hb" ]] && st=MATCH || st=DIFFER
      echo "  native ${st} ${rel}"
    else
      echo "  native MISSING-IN-BUILT ${rel}"
    fi
  done < <(find /tmp/o -name '*.so' -type f | sort)

  raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"
  printf '%s\n' "$raw" > "/out/diff-unzipped-${cfg}.txt"
  n=$(printf '%s\n' "$raw" | grep -vc '^$')
  echo "  raw diffs: ${n}   (full list: diff-unzipped-${cfg}.txt)"
  [[ "$n" -gt 0 ]] && printf '%s\n' "$raw" | head -5 | sed 's/^/    /'

  # Every raw line must be claimed by an EARNED class or it stays unaccounted.
  read -r c_sign c_stamp c_mani c_arsc < <(printf '%s\n' "$raw" | awk '
    /\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)/{a++;next}
    /stamp-cert-sha256/{b++} /AndroidManifest\.xml/{c++} /resources\.arsc/{d++}
    END{print a+0, b+0, c+0, d+0}')
  a_sign=0; a_stamp=0; a_mani=0; a_arsc=0
  echo "  accepted-class evidence"
  [[ "$c_sign" -gt 0 ]] && { a_sign=$c_sign
    echo "      signing: ${c_sign} META-INF entry(ies); Play re-signs, local build unsigned"; }
  if [[ "$c_stamp" -gt 0 ]]; then
    if stamp_ok "$o"; then a_stamp=$c_stamp; else echo "      stamp: NOT EARNED -> material"; fi
  fi
  if [[ "$c_mani" -gt 0 ]]; then
    if manifest_ok "$o" "$b" "$cfg"; then a_mani=$c_mani; else echo "      manifest: NOT EARNED -> material"; fi
  fi
  if [[ "$c_arsc" -gt 0 ]]; then
    ARSC_CLASS=""
    if arsc_ok "$o" "$b" "$cfg"; then a_arsc=$c_arsc; echo "      arsc class: ${ARSC_CLASS}"
    else echo "      arsc: NOT EARNED -> material"; fi
  fi
  printf '%s\n' "$raw" | grep -q 'baseline\.prof' && \
    echo "      baseline.prof: NEVER auto-accepted (FDROID.md: non-deterministic) -> material"

  acc=$((a_sign + a_stamp + a_mani + a_arsc))
  un=$((n - acc)); [[ "$un" -lt 0 ]] && un=0
  if [[ "$un" -eq 0 ]]; then v=reproducible; else v=not_reproducible; FAILED=$((FAILED + 1)); fi
  echo "  split result: raw ${n}, accepted ${acc} (signing ${a_sign}, stamp ${a_stamp}, manifest ${a_mani}, arsc ${a_arsc}), unaccounted ${un} -> ${v}"

  echo "${cfg} ${n} ${a_sign} ${a_stamp} ${a_mani} ${a_arsc} ${un}" >> /out/summary.txt
  RAW=$((RAW + n)); SIGN=$((SIGN + a_sign)); STAMP=$((STAMP + a_stamp))
  MANI=$((MANI + a_mani)); ARSC=$((ARSC + a_arsc)); UNACC=$((UNACC + un))
done

echo "TOTALS ${RAW} ${SIGN} ${STAMP} ${MANI} ${ARSC} ${UNACC} ${MISSING}" >> /out/summary.txt
echo ""
echo "=== comparison complete: raw ${RAW}, unaccounted ${UNACC}, unmatched ${MISSING} ==="
CMP_END
chmod +x "${img_ctx}/compare.sh"

crun \
  --volume "$OFFICIAL_DIR:/official:ro" \
  --volume "${BUILD_DIR}/built:/built:ro" \
  --volume "${CMP_DIR}:/out" \
  --volume "${img_ctx}/compare.sh:/compare.sh:ro" \
  "$IMG" bash /compare.sh 2>&1 | tee "${CMP_DIR}/comparison.log"
CMP_RC=${PIPESTATUS[0]}

if [[ $CMP_RC -ne 0 ]] || ! grep -q '^TOTALS' "${CMP_DIR}/summary.txt" 2>/dev/null; then
  log_error "Comparison stage failed (exit ${CMP_RC}) or wrote no TOTALS line"
  log_info  "Comparison log: ${CMP_DIR}/comparison.log"
  fail 1 "Comparison stage failed for ${APP_ID} $wallet_version (exit ${CMP_RC}). Official base.apk SHA-256: ${app_hash}."
fi

read -r _ raw_total t_sign t_stamp t_mani t_arsc t_unacc t_missing \
  < <(grep '^TOTALS' "${CMP_DIR}/summary.txt")
raw_total="${raw_total:-1}"; t_sign="${t_sign:-0}"; t_stamp="${t_stamp:-0}"
t_mani="${t_mani:-0}"; t_arsc="${t_arsc:-0}"; t_unacc="${t_unacc:-1}"; t_missing="${t_missing:-1}"
t_acc=$((t_sign + t_stamp + t_mani + t_arsc))


section "RESULT"
cat <<EOF
 Official splits:      ${#OFFICIAL_SPLITS[@]}
 Raw differences:      ${raw_total}
 Accepted (earned): ${t_acc} = sign ${t_sign} + stamp ${t_stamp} + manifest ${t_mani} + arsc ${t_arsc}
 UNACCOUNTED:          ${t_unacc}   <- the verdict is judged on this alone
 Unmatched splits:     ${t_missing}

 Per-split detail:     ${CMP_DIR}/summary.txt
 Raw diffs:            ${CMP_DIR}/diff-unzipped-<split>.txt
 Decoded res/ diffs:   ${CMP_DIR}/diff_resources_decoded_<split>.txt
 Normalised res/ diff: ${CMP_DIR}/diff_resources_normalised_<split>.txt
 Manifest diffs:       ${CMP_DIR}/diff_manifest_<split>.txt
 Gradle log:           ${BUILD_DIR}/gradle-build.log

 Per-split (passes only at zero unaccounted):
EOF
while read -r cfg a b c d e f; do
  [[ "$cfg" == "TOTALS" ]] && continue
  if [[ "$a" == "UNMATCHED" ]]; then
    printf "    %-22s unverified (present on one side only)\n" "$cfg"
  elif [[ "${f:-1}" -eq 0 ]]; then
    printf "    %-22s reproducible  raw %-3s accepted %-3s unaccounted 0\n" \
      "$cfg" "$a" "$((b + c + d + e))"
  else
    printf "    %-22s not_reproducible  raw %-3s unaccounted %s\n" "$cfg" "$a" "$f"
  fi
done < "${CMP_DIR}/summary.txt"

if [[ "$t_missing" -gt 0 ]]; then
  log_warn "Verdict: not_reproducible -- ${t_missing} split(s) present on only one side"
  VERDICT="not_reproducible"; EXIT_CODE=1
elif [[ "$t_unacc" -eq 0 ]]; then
  log_success "Verdict: reproducible -- every split has zero unaccounted differences"
  VERDICT="reproducible"; EXIT_CODE=0
else
  log_warn "Verdict: not_reproducible -- ${t_unacc} unaccounted difference(s)"
  VERDICT="not_reproducible"; EXIT_CODE=1
fi

# appId..commit per script_verifications.md; scriptVersion/scriptHash after
# commit per script-version-and-hash.md. Others below End Results.
cat <<EOF

===== Begin Results =====
appId:           ${APP_ID}
signer:          ${signer}
apkVersionName:  $wallet_version
apkVersionCode:  $version_code
verdict:         ${VERDICT}
appHash:         ${app_hash}
commit:          $(cat "${BUILD_DIR}/commit.txt" 2>/dev/null || echo unknown)
scriptVersion:   $SCRIPT_VERSION
scriptHash:      ${SCRIPT_HASH:-unknown}
===== End Results =====

channel:         google-play (split set)
lineage:         ${LINEAGE} (signals: $google_signals)
sourceRef:       ${built_ref:-pinned-in-container} (branch ${GIT_BRANCH_NAME})
candidateCommits: ${candidate_count:-1}
gitHashInBinary: ${git_hash:-unknown}
rawDiffs:        ${raw_total}
acceptedDiffs:   ${t_acc} (signing ${t_sign}, sourcestamp ${t_stamp}, manifest ${t_mani}, arsc ${t_arsc})
unaccountedDiffs: ${t_unacc}
method:          AAB built in a pinned container, split with bundletool 1.18.3, compared per split
depProvenance:   JitPack deps consumed as published binaries, not rebuilt from source

 appHash is base.apk (carries app identity); each split's SHA-256 is in the
 comparison log. signer is Play App Signing's key, not the developer key.
EOF

generate_yaml "${VERDICT}" "Google Play split set, master lineage DETECTED from artifact contents ($google_signals). master has no tag; revision pinned by versionName $wallet_version + versionCode $version_code, ${candidate_count:-1} commit(s) matched (ref ${built_ref:-unknown}). Built :app:bundleRelease, split with bundletool 1.18.3 (matches AGP 9.0.1). ${raw_total} raw difference(s); ${t_acc} EARNED exclusions - signing ${t_sign} (Play re-signs, local build unsigned), SourceStamp ${t_stamp} (1 root entry, off-only, 32 bytes, apksigner SourceStamp OK), AndroidManifest ${t_mani} (only Play's three off-only distribution meta-data entries), resources.arsc ${t_arsc} (decoded res/ compared; where the sole delta was the three positional Crashlytics build_ids arrays, triples were zipped by index, Counter-compared with multiplicity preserved, canonicalised, and the ENTIRE decoded res/ tree then compared identical). ${t_unacc} UNACCOUNTED difference(s) - the verdict is judged on this alone. ${t_missing} split(s) unmatched. Official base.apk SHA-256 ${app_hash}. JitPack deps (com.github.piratecash forks) were consumed as published binaries, NOT rebuilt from source, so a byte-match does not attest their provenance."

echo ""
echo "Exit code: ${EXIT_CODE}"
exit "${EXIT_CODE}"
