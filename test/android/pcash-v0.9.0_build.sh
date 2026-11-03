#!/usr/bin/env bash
# pcash_build.sh - P.CASH Terminal reproducible build verification, every channel
# Version:          v0.9.0
# Organization:     WalletScrutiny.com
# Last modified by: Carol (Buzz), Claude Code for Danny
# Last modified on: 2026-11-02
# App ID:           cash.p.terminal
# Project:          https://github.com/piratecash/pcash-wallet
#
# One script for every P.CASH artifact; the kind is read from CONTENTS, never the file name:
#   Play split set (dir)            -> master, :app:bundleRelease + bundletool, per split
#   p.cash.apk with Firebase        -> master (tag -google), :app:assembleRelease
#   p.cash.apk without Firebase     -> f-droid (tag -fdroid), :app:assembleRelease -Pfdroid=true
#   lone base.apk or config split   -> exit 2, no YAML
# Steps: 1 parse args. 2 no --binary: download + GPG-verify p.cash.apk. 3 classify input, read
# metadata, detect lineage. 4 build in a pinned container. 5 compare; only EARNED exclusions.
# 6 results block + COMPARISON_RESULTS.yaml. Rationale: ws-notes script-notes/android/cash.p.terminal/changelog.md
#
# For technical analysis and reproducible build verification only; no warranty of any kind.
# Users are responsible for lawful use. Review before running.
# Exit codes: 0 = identical, 1 = difference or build failure, 2 = wrong input (no YAML).

SCRIPT_VERSION="v0.9.0"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "pcash_build.sh $SCRIPT_VERSION sha256:${SCRIPT_HASH:-N/A}"

# No -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="pcash_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="cash.p.terminal"
REPO_URL="https://github.com/piratecash/pcash-wallet"
GPG_FPR="8A47C2ABED2839E671B50620A6F0CB1BB25FFE99"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner() { printf '\n== %s ==\n  %s\n' "$*" "$(date)"; }
section() { printf -- '\n-- %s --\n' "$*"; }
sha256of() { sha256sum "$1" | awk '{print $1}'; }

# The YAML must land in the SCRIPT's directory (ABS reads it there); $PWD copy is convenience.
execution_dir="$SCRIPT_DIR"
invocation_dir="$(pwd -P)"
# A stale verdict must never outlive a refused run. --help is not a run.
[[ " $* " == *" --help "* || " $* " == *" -h "* ]] || \
  rm -f "${execution_dir}/COMPARISON_RESULTS.yaml" "${invocation_dir}/COMPARISON_RESULTS.yaml"

# Only these three keys, ever: script_version, verdict, notes.
generate_yaml() {
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: $SCRIPT_VERSION
verdict: $1
notes: |
 $2
EOF
  [[ "$invocation_dir" != "$execution_dir" ]] && cp -f "${execution_dir}/COMPARISON_RESULTS.yaml" \
    "${invocation_dir}/COMPARISON_RESULTS.yaml" 2>/dev/null
  log_info "COMPARISON_RESULTS.yaml written with verdict: $1"
}

# ftbfs: only when the source itself fails to build (or cannot be pinned to published source).
fail() { generate_yaml "ftbfs" "$2"; echo ""; echo "Exit code: $1"; exit "$1"; }

# Wrong input is not a build result: no YAML, exit 2, so ABS tries its next script.
die_invalid() {
  log_error "$1"
  echo ""; echo "Exit code: 2 (wrong input; no COMPARISON_RESULTS.yaml written)"
  exit 2
}

# Not a build result either (image, network, download, tooling): no YAML, exit 1.
abort() {
  log_error "$1"
  echo ""; echo "Exit code: 1 (no verdict; no COMPARISON_RESULTS.yaml written)"
  exit 1
}

[[ "$EUID" -eq 0 ]] && die_invalid "Do not run this script as root."

version_arg=""; binary_arg=""; arch_arg=""; type_arg=""; rev_arg="${WS_GIT_REVISION:-}"

require_arg() {
  [[ -z "${2:-}" || "$2" == --* ]] && die_invalid "$1 requires a value (got: '${2:-<nothing>}')"
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [--binary <path>] [--version <v>] [--type google|fdroid] [--arch <a>] [--git-revision <sha>]
 --binary        Play split directory, or one p.cash.apk; kind read from contents. Omitted:
                 download + GPG-verify p.cash.apk of release v<version>-<type> (Play: supply it).
 --version/--type  Without --binary: release (default latest) and google|fdroid (default fdroid).
 --git-revision  Commit to build. Default: the APK's version-control-info.textproto, then the
                 release tag, then (Play) the oldest master commit with its versionName+versionCode.
 --arch          Logged. WS_DEVICE_SDK env: Play device API level (36). GITHUB_TOKEN env: optional.

Exit codes: 0 = identical, 1 = any difference, 2 = wrong input (no YAML written).
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
    -h|--help)      usage; echo "Exit code: 0"; exit 0 ;;
    *)              log_warn "Unknown argument: $1 (ignored)"; shift ;;
  esac
done

NEED_DOWNLOAD=0; DL_CHANNEL=""
if [[ -z "$binary_arg" ]]; then
  NEED_DOWNLOAD=1
  case "$type_arg" in
    ""|fdroid) DL_CHANNEL=fdroid ;;
    google)    DL_CHANNEL=google ;;
    *) die_invalid "--type '${type_arg}' without --binary: use google or fdroid. Play splits cannot be downloaded." ;;
  esac
  [[ -z "$version_arg" || "$version_arg" =~ ^[0-9][0-9A-Za-z.]*$ ]] || die_invalid "--version '${version_arg}' is not a version number"
else
  [[ -e "$binary_arg" ]] || die_invalid "--binary path does not exist: ${binary_arg}"
  [[ -f "$binary_arg" || -d "$binary_arg" ]] || die_invalid "--binary is neither a file nor a directory: ${binary_arg}"
  binary_arg="$(realpath "$binary_arg")"
  [[ -n "$type_arg$version_arg" ]] && log_info "--type/--version logged only; the artifact decides"
fi
[[ -z "$rev_arg" || "$rev_arg" =~ ^[0-9a-fA-F]{7,40}$ ]] || \
  die_invalid "--git-revision must be 7-40 hex characters (got: '${rev_arg}')"
[[ -n "$arch_arg" ]] && log_info "--arch ${arch_arg} logged; ABIs come from the artifact"

if [[ -z "${CONTAINER_CMD:-}" ]]; then
  if command -v docker &>/dev/null; then CONTAINER_CMD=docker
  elif command -v podman &>/dev/null; then CONTAINER_CMD=podman
  else die_invalid "Neither docker nor podman found in PATH"; fi
fi

# Container user = host user, so no root-owned leftovers. HOME=/tmp: apktool caches there.
if [[ "$CONTAINER_CMD" == "podman" ]]; then
  CONTAINER_RUN_USER_ARGS=(--userns=keep-id -e HOME=/tmp)
else
  CONTAINER_RUN_USER_ARGS=(--user "${HOST_UID}:${HOST_GID}" -e HOME=/tmp)
fi
MEM_LIMIT="${MEM_LIMIT:-16g}"
MEM_ARGS=()
[[ -n "$MEM_LIMIT" ]] && MEM_ARGS=(--memory="$MEM_LIMIT")
crun() { $CONTAINER_CMD run --rm "${CONTAINER_RUN_USER_ARGS[@]}" "${MEM_ARGS[@]}" "$@"; }

section "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-10s OK  (%s)\n" "$CONTAINER_CMD" "$(command -v "$CONTAINER_CMD")"
echo "  Nothing else on the host: JDK, SDK, gpg, apktool run in the container."

RUN_ID="$(date +%s)-$$"
IMG="localhost/ws-pcash-${RUN_ID}"
workspace="${invocation_dir}/pcash_verification_${version_arg:-provided}_${RUN_ID}"
META_DIR="${workspace}/metadata"
BUILD_DIR="${workspace}/source-build"
CMP_DIR="${workspace}/comparison"
OFFICIAL_DIR="${workspace}/official"
DL_DIR="${workspace}/download"
img_ctx=""

# Exclusive: a run only ever touches the directory it created.
mkdir "$workspace" || abort "Could not create workspace ${workspace}"
mkdir -p "$META_DIR" "$BUILD_DIR" "$CMP_DIR" "$OFFICIAL_DIR" "$DL_DIR" || abort "Could not create workspace folders"

# Docker: root in the container, so it can chown. Rootless podman: caller = 0 in its namespace.
ensure_user_ownership() {
  [[ -e "$1" ]] || return 0
  if [[ "$CONTAINER_CMD" == "podman" ]]; then
    podman unshare chown -R 0:0 "$1" >/dev/null 2>&1 || log_warn "Could not normalise ownership for $1"
    return 0
  fi
  $CONTAINER_CMD image inspect "$IMG" >/dev/null 2>&1 || return 0
  $CONTAINER_CMD run --rm -v "$1:/target" "$IMG" sh -c "chown -R ${HOST_UID}:${HOST_GID} /target" \
    >/dev/null 2>&1 || log_warn "Could not normalise ownership for $1"
}

cleanup() {
  ensure_user_ownership "$workspace"
  $CONTAINER_CMD rmi -f "$IMG" >/dev/null 2>&1 || true
  [[ -n "$img_ctx" ]] && rm -rf "$img_ctx" 2>/dev/null
}
trap cleanup EXIT

banner "P.CASH TERMINAL WALLET - REPRODUCIBLE BUILD VERIFICATION"
cat <<EOF
 Script:    ${SCRIPT_NAME} $SCRIPT_VERSION
 App ID:    ${APP_ID}
 Repo:      ${REPO_URL}
 Binary:    ${binary_arg:-<download v${version_arg:-latest}-${DL_CHANNEL} from GitHub Releases>}
 Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))
 Workspace: ${workspace}
EOF

banner "SETUP: BUILD CONTAINER IMAGE"
img_ctx="$(mktemp -d -p "$workspace")"

# bundletool must match the one AGP embeds (AGP 9.0.1 -> 1.18.3); /build chmod:
# WORKDIR alone is root-owned and the mapped-user clone fails.
cat > "${img_ctx}/Dockerfile" <<'DOCKERFILE_END'
FROM docker.io/library/ubuntu:24.04@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk-headless git unzip zip wget curl ca-certificates binutils python3 gnupg && \
  rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${JAVA_HOME}/bin:${PATH}"
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && cd ${ANDROID_HOME}/cmdline-tools && \
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O c.zip && \
  unzip -q c.zip && rm c.zip && mv cmdline-tools latest
RUN yes | sdkmanager --licenses >/dev/null && \
  sdkmanager "platforms;android-36" "platforms;android-37.0" "build-tools;36.0.0" "platform-tools" >/dev/null
ADD https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar /opt/bundletool.jar
ADD https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar /opt/apktool.jar
RUN chmod 0644 /opt/bundletool.jar /opt/apktool.jar
RUN mkdir -p /tmp/afw /build && chmod 0777 /tmp /tmp/afw /build
WORKDIR /build
DOCKERFILE_END

section "Building image ${IMG}"
$CONTAINER_CMD build -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx" || \
  abort "Container image build failed (see above; mirror or network). No verdict."
log_success "Image built: ${IMG}"

# Both detached signatures must be VALIDSIG by the pinned fingerprint and the checksum must match.
if [[ "$NEED_DOWNLOAD" -eq 1 ]]; then
  banner "PHASE A: DOWNLOAD AND AUTHENTICATE p.cash.apk"
  cat > "${img_ctx}/fetch.sh" <<'FETCH_END'
#!/bin/bash
set -uo pipefail
cd /output || exit 1
H=(); [[ -n "${GITHUB_TOKEN:-}" ]] && H=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
if [[ -z "$VER" ]]; then
  VER="$(curl -fsSL "${H[@]}" https://api.github.com/repos/piratecash/pcash-wallet/releases/latest \
    | sed -n 's/.*"tag_name": *"v\([^"-]*\)-[a-z]*".*/\1/p' | head -1)"
fi
[[ -n "$VER" ]] || { echo "FATAL: could not resolve the latest release"; exit 1; }
tag="v${VER}-${CH}"; echo "Release tag: ${tag}"
for f in p.cash.apk p.cash.apk.asc p.cash.apk.sha256 p.cash.apk.sha256.asc; do
  echo "  fetching ${f}"
  curl -fsSL --retry 3 --connect-timeout 30 -o "$f" "${REPO}/releases/download/${tag}/${f}" \
    || { echo "FATAL: cannot download ${f} of ${tag}"; exit 1; }
done
curl -fsSL -o pubkey.asc "https://raw.githubusercontent.com/piratecash/pcash-wallet/${tag}/security/piratecash-release-public-key.asc" \
  || { echo "FATAL: cannot fetch the release public key"; exit 1; }
export GNUPGHOME=/tmp/gnupg; mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
gpg --batch --import pubkey.asc 2>&1 | sed 's/^/  /'
ok=0
for s in p.cash.apk p.cash.apk.sha256; do
  echo "=== gpg --verify ${s}.asc (want VALIDSIG by ${FPR}) ==="
  st="$(gpg --batch --status-fd 1 --verify "${s}.asc" "$s" 2>&1)"; printf '%s\n' "$st" | grep -v '^\[GNUPG'
  grep -qE "^\[GNUPG:\] VALIDSIG .*${FPR}" <<<"$st" && echo "  OK: valid signature by ${FPR}" || { echo "  BAD: ${s}"; ok=1; }
done
sha256sum -c p.cash.apk.sha256 || ok=1
[[ $ok -eq 0 ]] || { echo "FATAL: p.cash.apk of ${tag} failed authentication"; exit 1; }
echo "Authenticated: ${tag} p.cash.apk, key ${FPR}"
FETCH_END
  crun -e "REPO=${REPO_URL}" -e "VER=${version_arg}" -e "CH=${DL_CHANNEL}" -e "FPR=${GPG_FPR}" -e GITHUB_TOKEN \
    --volume "${DL_DIR}:/output" --volume "${img_ctx}/fetch.sh:/fetch.sh:ro" "$IMG" bash /fetch.sh || \
    abort "Could not download or authenticate the official p.cash.apk (key ${GPG_FPR}). No verdict."
  binary_arg="${DL_DIR}/p.cash.apk"
  log_success "Official p.cash.apk downloaded and GPG-verified"
fi

banner "PHASE 0: CLASSIFY INPUT, OFFICIAL METADATA"

# Classify from contents: aapt2 split= attribute and the manifest's required-splits markers.
cat > "${img_ctx}/meta.sh" <<'META_END'
#!/bin/bash
set -uo pipefail
BT="${ANDROID_HOME}/build-tools/36.0.0"; AAPT2="$BT/aapt2"; APKSIGNER="$BT/apksigner"
out() { printf '%s\n' "$2" > "/output/$1.txt"; }
if [[ -d /in ]]; then F=(); for f in /in/*; do [[ -f "$f" ]] && F+=("$f"); done; else F=(/in); fi
nb=0; ns=0; bad=""; ids=""; base=""
for f in "${F[@]}"; do
  i="$("$AAPT2" dump badging "$f" 2>/dev/null)"
  p="$(grep '^package:' <<<"$i")" || { bad="${bad} $(basename "$f")"; continue; }
  ids="${ids}$(sed "s/^package: name='\([^']*\)' versionCode='\([^']*\)'.*/\1 \2/" <<<"$p")"$'\n'
  s="$(sed -n "s/.*split='\([^']*\)'.*/\1/p" <<<"$p" | head -1)"
  if [[ -z "$s" ]]; then nb=$((nb + 1)); base="$f"; else ns=$((ns + 1)); cp "$f" "/stage/split_${s}.apk"; fi
done
nid="$(sort -u <<<"$ids" | grep -c .)"
req=0; x=""
[[ -n "$base" ]] && x="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$base" 2>/dev/null)"
grep -qE 'vending\.splits\.required|isSplitRequired|requiredSplitTypes' <<<"$x" && req=1
if [[ -n "$bad" ]]; then k="notapk:${bad}"
elif [[ "${#F[@]}" -eq 0 ]]; then k="empty"
elif [[ "$nid" -ne 1 ]]; then k="mixed"
elif [[ "$nb" -gt 1 ]]; then k="multibase"
elif [[ "$nb" -eq 0 ]]; then k="lonesplit"
elif [[ "$ns" -gt 0 ]]; then k="play"
elif [[ "$req" -eq 1 ]]; then k="lonebase"
else k="apk"; fi
echo "[META] input: ${#F[@]} file(s), ${nb} base, ${ns} split(s), requires splits: ${req} -> ${k}"
out kind "$k"
[[ "$k" == play || "$k" == apk ]] || { rm -f /stage/*; exit 0; }
if [[ "$k" == play ]]; then A=/stage/base.apk; else A=/stage/p.cash.apk; fi
cp "$base" "$A"

info="$("$AAPT2" dump badging $A 2>/dev/null)"
# Anchor on '^package:' and stop at the first quote (a greedy match returns versionName).
pkg="$(grep '^package:' <<<"$info" | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(grep '^package:' <<<"$info" | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(grep '^package:' <<<"$info" | sed "s/.*versionCode='\([^']*\)'.*/\1/")"
signer="$("$APKSIGNER" verify --print-certs $A 2>/dev/null | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"
rev="$(unzip -p $A META-INF/version-control-info.textproto 2>/dev/null \
  | sed -n 's/.*revision: *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
agp="$(unzip -p $A META-INF/com/android/build/gradle/app-metadata.properties 2>/dev/null \
  | sed -n 's/^androidGradlePluginVersion=//p' | head -1)"

# Read the dex strings ONCE into a file: `strings | grep -q` under pipefail reports a false
# "no match" when grep exits early and strings dies of SIGPIPE.
rm -rf /tmp/dex && mkdir -p /tmp/dex
unzip -q -o $A 'classes*.dex' -d /tmp/dex 2>/dev/null
: > /tmp/ds.txt
compgen -G "/tmp/dex/classes*.dex" > /dev/null && strings -a /tmp/dex/classes*.dex > /tmp/ds.txt 2>/dev/null
# GIT_HASH is "<10hex>[-dirty][-fdroid]"; only the literal for the recorded revision is probative.
gh=""; [[ -n "$rev" ]] && gh="$(grep -m1 -xE "${rev:0:10}(-dirty)?(-fdroid)?" /tmp/ds.txt)"
# Report EVERY branch literal: head -1 would always claim "f-droid" (sorts first).
gitbr="$(grep -xE 'f-droid|master' /tmp/ds.txt | sort -u | paste -sd, -)"

# Lineage: ANY hit in any staged APK = present. A bare com.google.android.gms dex string is
# NOT a signal: the f-droid 1.0.260 dex carries one.
GPAT='firebase|crashlytics|com/google/android/gms'
fb=0; bp=0; sigs=""
for f in /stage/*.apk; do
  L="$(unzip -l "$f" 2>/dev/null)"; n="$(basename "$f")"
  grep -qiE "$GPAT" <<<"$L" && { fb=1; sigs="${sigs}zipnames:${n} "; }
  grep -qiE 'lib/[^/]+/lib(crashlytics|gms|google)' <<<"$L" && { fb=1; sigs="${sigs}nativelib:${n} "; }
  grep -q 'assets/dexopt/baseline.prof' <<<"$L" && bp=1
done
grep -qE 'com\.google\.firebase' /tmp/ds.txt && { fb=1; sigs="${sigs}dexstrings:$(basename $A) "; }
rm -rf /tmp/dres
if java -jar /opt/apktool.jar d -f --no-src --no-debug-info --frame-path /tmp/afw -o /tmp/dres $A >/dev/null 2>&1; then
  grep -rqiE 'common_google_signin|com\.google\.android\.gms' /tmp/dres/res 2>/dev/null && { fb=1; sigs="${sigs}resources.arsc:$(basename $A) "; }
else
  sigs="${sigs}resources.arsc:DECODE-FAILED "
fi

for kv in "pkg_name:${pkg:-unknown}" "version_name:${vname:-unknown}" "version_code:${vcode:-unknown}" \
  "signer:${signer:-unknown}" "vcs_revision:${rev}" "agp:${agp}" "gh:${gh}" "git_branch:${gitbr}" \
  "has_firebase:${fb}" "has_baseline_profile:${bp}" "google_signals:${sigs:-none}"; do
  out "${kv%%:*}" "${kv#*:}"
done
echo "[META] ${pkg} ${vname}/${vcode}, vcs revision ${rev:-<none>}, AGP ${agp:-?}"
META_END

crun --volume "${binary_arg}:/in:ro" --volume "${OFFICIAL_DIR}:/stage" --volume "${META_DIR}:/output" \
  --volume "${img_ctx}/meta.sh:/meta.sh:ro" "$IMG" bash /meta.sh || \
  abort "Input classification / metadata extraction failed (aapt2/apksigner). No verdict."

meta() { cat "${META_DIR}/$1.txt" 2>/dev/null || echo "${2:-}"; }
KIND="$(meta kind unknown)"
case "$KIND" in
  play|apk) ;;
  lonebase)  die_invalid "--binary is a Play base.apk without the config splits its manifest requires. Pass the whole split set as one directory (one kind-9401 bundle)." ;;
  lonesplit) die_invalid "--binary holds config split(s) without their base APK; a split alone cannot be verified. Pass the whole set as one directory." ;;
  multibase) die_invalid "--binary holds more than one base APK." ;;
  mixed)     die_invalid "--binary holds APKs of different packages or versionCodes." ;;
  empty)     die_invalid "--binary directory is empty." ;;
  notapk:*)  die_invalid "--binary holds non-APK file(s):${KIND#notapk:}" ;;
  *)         abort "Input classification gave no result. No verdict." ;;
esac
pkg_id="$(meta pkg_name unknown)"
wallet_version="$(meta version_name unknown)"
version_code="$(meta version_code unknown)"
signer="$(meta signer unknown)"
vcs_revision="$(meta vcs_revision)"
official_agp="$(meta agp)"
git_hash="$(meta gh)"
git_branch="$(meta git_branch)"
has_firebase="$(meta has_firebase 0)"
has_baseline="$(meta has_baseline_profile 0)"
google_signals="$(meta google_signals none)"
declare -a OFFICIAL_APKS=()
while IFS= read -r f; do OFFICIAL_APKS+=("$f"); done < <(find "$OFFICIAL_DIR" -maxdepth 1 -name '*.apk' | sort)
if [[ "$KIND" == play ]]; then apk_file="${OFFICIAL_DIR}/base.apk"; else apk_file="${OFFICIAL_DIR}/p.cash.apk"; fi
app_hash="$(sha256of "$apk_file")"

[[ "$pkg_id" == "$APP_ID" ]] || die_invalid "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
log_success "Package name verified: ${pkg_id}"
[[ -n "$wallet_version" && "$wallet_version" != "unknown" ]] || die_invalid "Could not read versionName from the APK"
log_success "Version: $wallet_version (versionCode $version_code)"
log_info    "Signer SHA-256:   ${signer}"
log_info    "$(basename "$apk_file") SHA-256: ${app_hash}"
[[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]] && \
  log_warn "--version was '${version_arg}' but the APK reports '$wallet_version'; using the binary's value"

section "Input kind and lineage"
GRADLE_FLAGS=""; FLAG_WHY=""
if [[ "$KIND" == play ]]; then
  [[ "$has_firebase" == "1" ]] || die_invalid "Play split set without any Google/Firebase signal: not the master build Play ships. Check provenance."
  LINEAGE="master"; CHANNEL="google-play (split set, ${#OFFICIAL_APKS[@]} APKs)"; TAG="v${wallet_version}-google"
  TASK=":app:bundleRelease"
elif [[ "$has_firebase" == "1" ]]; then
  LINEAGE="master"; CHANNEL="github p.cash.apk (-google)"; TAG="v${wallet_version}-google"
  TASK=":app:assembleRelease"
else
  LINEAGE="f-droid"; CHANNEL="github/f-droid p.cash.apk (-fdroid)"; TAG="v${wallet_version}-fdroid"
  TASK=":app:assembleRelease"; GRADLE_FLAGS="-Pfdroid=true"; FLAG_WHY="F-Droid recipe (gradleProps fdroid=true)"
fi
# -Pfdroid=true only disables the ArtProfile tasks: an APK without baseline.prof was built so.
if [[ "$KIND" == apk && "$LINEAGE" == master && "$has_baseline" == "0" ]]; then
  GRADLE_FLAGS="-Pfdroid=true"; FLAG_WHY="official APK has no assets/dexopt/baseline.prof"
fi
case "$git_hash" in
  *-dirty)  log_warn "GIT_HASH ends in -dirty: the vendor built from uncommitted changes." ;;
  *-fdroid) [[ "$LINEAGE" == master ]] && log_warn "GIT_HASH ends in -fdroid (branch f-droid), but Firebase is present." ;;
  ?*)       [[ "$LINEAGE" == f-droid ]] && log_warn "GIT_HASH lacks -fdroid, but Firebase is absent." ;;
esac
cat <<EOF
 Input:     ${KIND} -> ${CHANNEL}, lineage/branch ${LINEAGE}
 Firebase:  ${has_firebase} (${google_signals})   baseline.prof: ${has_baseline}
 GIT_HASH:  ${git_hash:-<not in dex>} (for the recorded revision)   GIT_BRANCH literals: ${git_branch:-<none>}
 Gradle:    ./gradlew clean ${TASK} ${GRADLE_FLAGS}${FLAG_WHY:+  (${FLAG_WHY})}
EOF

if [[ -n "$rev_arg" ]]; then
  build_rev="$rev_arg"; rev_source="--git-revision"
elif [[ -n "$vcs_revision" ]]; then
  build_rev="$vcs_revision"; rev_source="META-INF/version-control-info.textproto in $(basename "$apk_file")"
elif [[ "$KIND" == apk ]]; then
  build_rev=""; rev_source="release tag ${TAG}"
else
  build_rev=""; rev_source="oldest master commit declaring versionName $wallet_version + versionCode $version_code"
fi
echo "  Revision: ${build_rev:-<resolved in container>}   source: ${rev_source}"
[[ -n "$vcs_revision" && -z "$git_hash" ]] && \
  log_warn "No GIT_HASH literal for ${vcs_revision:0:10} in the official dex; expect classes.dex to differ by that string."

banner "PHASE 1: BUILD FROM SOURCE"

cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail
# app/build.gradle throws if some but not all FIREBASE_DEV_* are set; BUILD_NUMBER overrides versionCode.
unset FIREBASE_DEV_KEYSTORE_PATH FIREBASE_DEV_STORE_PASSWORD FIREBASE_DEV_KEY_ALIAS FIREBASE_DEV_KEY_PASSWORD BUILD_NUMBER
export GRADLE_USER_HOME=/tmp/gradle-home
mkdir -p "$GRADLE_USER_HOME"

echo "=== Clone ${REPO_URL} === $(date)"
# The checkout directory name is the Gradle root project name unless settings.gradle pins it
# (upstream 5bc084d32, 2026-09-19); it leaks into KMP module names and so into the dex.
SRC=/build/pcash-wallet-android
git clone "$REPO_URL" "$SRC" || { echo "FATAL: clone failed"; exit 1; }
cd "$SRC"
git config --global --add safe.directory "$SRC"

gradle_ver() { git show "$1:app/build.gradle" 2>/dev/null | grep -m1 "$2" | sed "s/.*$2 *\"\{0,1\}\([^\" ]*\).*/\1/"; }
tag_commit="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}")"

GIT_REF="${WS_GIT_REVISION:-}"; n=1
if [[ -z "$GIT_REF" && "$MODE" == apk ]]; then
  GIT_REF="$tag_commit"
  [[ -n "$GIT_REF" ]] || { echo "FATAL: release tag ${TAG} does not exist in ${REPO_URL}."; exit 4; }
fi
if [[ -n "$GIT_REF" ]]; then
  git rev-parse -q --verify "${GIT_REF}^{commit}" >/dev/null || git fetch -q origin "$GIT_REF" 2>/dev/null
  if ! GIT_REF="$(git rev-parse -q --verify "${GIT_REF}^{commit}")"; then
    echo "FATAL: revision ${WS_GIT_REVISION} is not in the public repository ${REPO_URL}."
    exit 4
  fi
  echo "=== Pinned revision ${GIT_REF} ==="
  git merge-base --is-ancestor "$GIT_REF" "origin/${BRANCH}" && echo "  reachable from origin/${BRANCH}" \
    || echo "  note: not reachable from origin/${BRANCH} (f-droid is force-rebased; tags are the stable refs)"
  vn="$(gradle_ver "$GIT_REF" versionName)"; vc="$(gradle_ver "$GIT_REF" versionCode)"
  [[ "$vn" == "$WANT_VNAME" && "$vc" == "$WANT_VCODE" ]] \
    || echo "  WARNING: it declares versionName ${vn:-?} / versionCode ${vc:-?}, the artifact is ${WANT_VNAME}/${WANT_VCODE}"
else
  # Walk master's first-parent line for commits declaring BOTH versionName and versionCode.
  echo "=== Pinning master revision for ${WANT_VNAME} / versionCode ${WANT_VCODE} ==="
  : > /output/mc.txt
  for c in $(git rev-list --first-parent origin/master); do
    if [[ "$(gradle_ver "$c" versionName)" == "$WANT_VNAME" && "$(gradle_ver "$c" versionCode)" == "$WANT_VCODE" ]]; then
      echo "$c" >> /output/mc.txt
    elif [[ -s /output/mc.txt ]]; then
      break
    fi
  done
  n=$(wc -l < /output/mc.txt)
  echo "Candidate commits: ${n}"
  while read -r c; do echo "  ${c:0:10}  $(git log -1 --format=%s "$c" | cut -c1-60)"; done < /output/mc.txt
  [[ "$n" -eq 0 ]] && { echo "FATAL: no master commit declares versionName ${WANT_VNAME} with versionCode ${WANT_VCODE}."; exit 4; }
  GIT_REF="$(tail -1 /output/mc.txt)"
  [[ "$n" -gt 1 ]] && echo "AMBIGUOUS: ${n} commits share this versionName+versionCode; building the oldest."
fi
printf '%s\n' "$n" > /output/candidate-count.txt

# Named branch, not detached HEAD: the branch name feeds getGitVersionSuffix() (-fdroid suffix).
git checkout -B "$BRANCH" "$GIT_REF" || { echo "FATAL: could not check out ${GIT_REF}"; exit 2; }
echo "=== Revision under build ==="
git log -1 --pretty=format:'%H %ci %s' ; echo
git rev-parse HEAD > /output/commit.txt
git rev-parse --short=10 HEAD > /output/expected_git_hash.txt
agp="$(sed -n 's/^\(gradle\|androidGradlePlugin\) = "\([^"]*\)".*/\2/p' gradle/libs.versions.toml 2>/dev/null | head -1)"
printf '%s\n' "$agp" > /output/agp.txt
echo "AGP at this revision: ${agp:-?}"

# Release tag provenance (reported, never decisive).
t="${TAG}: absent"
if [[ -n "$tag_commit" ]]; then
  ty="$(git cat-file -t "refs/tags/${TAG}")"
  t="${TAG}: $([[ $ty == tag ]] && echo annotated || echo lightweight) -> ${tag_commit:0:10} ($([[ $tag_commit == $(git rev-parse HEAD) ]] && echo = || echo NOT) built commit)"
  [[ "$ty" == tag ]] && { git tag -v "$TAG" >/output/tag-verify.txt 2>&1 && t="$t, signature verified" || t="$t, signature unverified (no key)"; }
fi
echo "$t" > /output/tag.txt; echo "Tag: $t"

if ! git diff-index --quiet HEAD --; then
  echo "FATAL: working tree is dirty immediately after checkout; refusing to build"
  git status --porcelain | head -20
  exit 2
fi

echo "=== Toolchain ==="; java -version 2>&1; ./gradlew --version 2>&1 | sed -n '1,12p'
echo "=== Gradle: ./gradlew clean ${TASK} ${GFLAGS} === $(date)"
./gradlew --no-daemon --max-workers=2 clean "$TASK" $GFLAGS > /output/gradle-build.log 2>&1
rc=$?
tail -60 /output/gradle-build.log
[[ $rc -ne 0 ]] && { echo "FATAL: gradle build failed (exit ${rc}) - full log at /output/gradle-build.log"; exit 3; }
mkdir -p /output/built

if [[ "$MODE" == apk ]]; then
  # app/build.gradle renames every release output to p.cash.apk (androidComponents.onVariants).
  out="app/build/outputs/apk/release/p.cash.apk"
  [[ -f "$out" ]] || { echo "FATAL: ${out} not found"; find app/build/outputs -name '*.apk' | head; exit 3; }
  cp "$out" /output/built/p.cash.apk
else
  echo "=== Split the AAB with bundletool === $(date)"
  aab="$(find app/build/outputs/bundle -name '*.aab' | head -1)"
  [[ -n "$aab" ]] || { echo "FATAL: no .aab produced under app/build/outputs/bundle"; exit 3; }
  AAPT2="$(find "$ANDROID_HOME/build-tools" -name aapt2 | sort | tail -1)"
  # Device-spec from the OFFICIAL split names; a wrong spec surfaces as UNMATCHED, never a false pass.
  ABIS=(); DEN=""
  for f in /official/*.apk; do
    c="$(basename "$f")"; c="${c#*config.}"; c="${c%.apk}"
    case "$c" in
      arm64_v8a|armeabi_v7a|x86_64|x86) ABIS+=("${c//_/-}") ;;
      ldpi) DEN=120 ;; mdpi) DEN=160 ;; tvdpi) DEN=213 ;; hdpi) DEN=240 ;;
      xhdpi) DEN=320 ;; xxhdpi) DEN=480 ;; xxxhdpi) DEN=640 ;;
    esac
  done
  [[ ${#ABIS[@]} -eq 0 ]] && ABIS=("arm64-v8a")
  [[ -z "$DEN" ]] && DEN=480
  # Device API level is a property of the PHONE, not readable from the APKs.
  if [[ -n "${WS_DEVICE_SDK:-}" ]]; then SDK="$WS_DEVICE_SDK"; SDK_SRC="supplied via WS_DEVICE_SDK"
  else SDK=36; SDK_SRC="DEFAULT GUESS -- pass WS_DEVICE_SDK=\$(adb shell getprop ro.build.version.sdk)"; fi
  echo "=== device sdkVersion: ${SDK} (${SDK_SRC}) ==="
  ABIJSON="$(printf '"%s",' "${ABIS[@]}")"; ABIJSON="[${ABIJSON%,}]"
  printf '{"supportedAbis":%s,"supportedLocales":["en"],"screenDensity":%s,"sdkVersion":%s}\n' \
    "$ABIJSON" "$DEN" "$SDK" > /output/device-spec.json
  cat /output/device-spec.json
  java -jar /opt/bundletool.jar build-apks --bundle="$aab" --output=/output/built.apks \
    --device-spec=/output/device-spec.json --aapt2="$AAPT2" --overwrite || { echo "FATAL: bundletool build-apks failed"; exit 3; }
  mkdir -p /output/bt
  unzip -q -o /output/built.apks 'splits/*.apk' -d /output/bt
  cp /output/bt/splits/*.apk /output/built/
fi
echo "=== built APKs ==="; sha256sum /output/built/*.apk
grep -q 'assets/dexopt/baseline.prof' <<<"$(unzip -l /output/built/*.apk 2>/dev/null)" && echo "built: baseline.prof present" || echo "built: no baseline.prof"

grep -Eo 'https://jitpack\.io/[^ ]+\.(aar|jar|pom)' /output/gradle-build.log 2>/dev/null | sort -u > /output/jitpack-artifacts.txt
find "$GRADLE_USER_HOME/caches/modules-2/files-2.1" -path '*com.github.piratecash*' -name '*.aar' -print0 2>/dev/null \
  | xargs -0 -r sha256sum > /output/aar-hashes.txt 2>&1
echo "JitPack URLs: $(wc -l < /output/jitpack-artifacts.txt), piratecash AARs: $(wc -l < /output/aar-hashes.txt)"
echo "=== Build complete $(date) ==="
BUILD_END

MODE=play; [[ "$KIND" == apk ]] && MODE=apk
section "Source build (30-90 min cold) - $(date)"
crun -e "WS_DEVICE_SDK=${WS_DEVICE_SDK:-}" -e "WS_GIT_REVISION=${build_rev}" -e "REPO_URL=${REPO_URL}" \
  -e "MODE=${MODE}" -e "BRANCH=${LINEAGE}" -e "TAG=${TAG}" -e "TASK=${TASK}" -e "GFLAGS=${GRADLE_FLAGS}" \
  -e "WANT_VNAME=${wallet_version}" -e "WANT_VCODE=${version_code}" \
  --volume "$OFFICIAL_DIR:/official:ro" --volume "${BUILD_DIR}:/output" \
  --volume "${img_ctx}/build.sh:/build/build.sh:ro" \
  "$IMG" bash /build/build.sh 2>&1 | tee "${BUILD_DIR}/container-build.log"
BUILD_RC=${PIPESTATUS[0]}

if [[ $BUILD_RC -ne 0 ]]; then
  # 1 clone, 2 checkout/dirty tree, 3 gradle/bundletool, 4 revision not found.
  if [[ $BUILD_RC -eq 4 ]]; then
    log_error "Cannot pin a revision (${rev_source}). This is a FINDING, not a script fault."
    fail 1 "${CHANNEL}, ${LINEAGE} lineage: no published source revision found (${rev_source}${build_rev:+: $build_rev}). No build attempted. Official $(basename "$apk_file") SHA-256: ${app_hash}."
  fi
  [[ $BUILD_RC -eq 1 ]] && abort "git clone failed (container exit 1). Network, not a build result. No verdict."
  log_error "Source build failed (exit ${BUILD_RC}: 2 checkout, 3 gradle/bundletool). Log: ${BUILD_DIR}/gradle-build.log"
  fail 1 "Source build failed for ${APP_ID} $wallet_version, ${CHANNEL} (container exit ${BUILD_RC}). Official $(basename "$apk_file") SHA-256: ${app_hash}."
fi
log_success "Source build finished"

candidate_count="$(cat "${BUILD_DIR}/candidate-count.txt" 2>/dev/null || echo 1)"
built_ref="$(cut -c1-10 "${BUILD_DIR}/commit.txt" 2>/dev/null)"
built_agp="$(cat "${BUILD_DIR}/agp.txt" 2>/dev/null)"
tag_info="$(cat "${BUILD_DIR}/tag.txt" 2>/dev/null || echo 'not recorded')"
[[ "${candidate_count:-1}" -gt 1 ]] && \
  log_warn "AMBIGUOUS: ${candidate_count} commits declare $wallet_version/$version_code; built the oldest (${built_ref})"
if [[ -n "$official_agp" && -n "$built_agp" ]]; then
  [[ "$official_agp" == "$built_agp" ]] && log_success "AGP cross-check: both use AGP ${built_agp}" \
    || log_warn "AGP cross-check MISMATCH: official artifact built with AGP ${official_agp}, revision declares ${built_agp}"
fi
built_hash_expect="$(cat "${BUILD_DIR}/expected_git_hash.txt" 2>/dev/null)"
if [[ -n "$git_hash" && -n "$built_hash_expect" ]]; then
  [[ "${git_hash%%-*}" == "$built_hash_expect" ]] && log_success "Revision cross-check: official GIT_HASH matches the built commit (${built_hash_expect})" \
    || log_warn "Revision cross-check MISMATCH: binary reports '${git_hash}', built commit is '${built_hash_expect}'"
fi
log_info "Release tag: ${tag_info}"

# PHASE 2: no general acceptable-diffs filtering; every raw diff must be EARNED by a class.
banner "PHASE 2: COMPARISON (per APK / per split)"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"
BT="${ANDROID_HOME}/build-tools/36.0.0"
AAPT2="$BT/aapt2"
APKSIGNER="$BT/apksigner"

# Pair by the APK's own split= attribute, never by filename (bundletool names base-X.apk).
cfg_of() {
  local s
  s="$("$AAPT2" dump badging "$1" 2>/dev/null | sed -n "s/.*split='\([^']*\)'.*/\1/p" | head -1)"
  s="${s#config.}"
  printf '%s' "${s:-base}"
}

# Resource-aware (ElementTree) Crashlytics build_ids canonicaliser; every guard fails CLOSED.
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
if co != cb: die("multiset differs: %d off-only, %d blt-only" % (sum((co - cb).values()), sum((cb - co).values())))
canon(oo, to); canon(bb, tb)
print("%d build_ids triples both sides, Counter equal (multiplicity kept)" % len(to))
PYEOF

# Crashlytics mapping_file_id: a random ID per build since v0.60.1-google (mappingFileUploadEnabled).
# Accepted ONLY as the sole decoded difference (Danny, 2026-10-12): one file, one line, 32 hex each side.
cat > /tmp/mf.py <<'PYEOF'
import sys, os, re, filecmp
K = 'com.google.firebase.crashlytics.mapping_file_id'
R = re.compile(r'\s*<string name="' + re.escape(K) + r'">([0-9a-f]{32})</string>\s*')
def die(m): print("mapping_file_id: REFUSED: " + m); sys.exit(1)
o, b = sys.argv[1], sys.argv[2]
def files(r): return {os.path.relpath(os.path.join(d, f), r) for d, _, fs in os.walk(r) for f in fs}
fo, fb = files(o), files(b)
if fo != fb: die("file sets differ")
dif = [p for p in sorted(fo) if not filecmp.cmp(os.path.join(o, p), os.path.join(b, p), shallow=False)]
if dif != ['values/strings.xml']: die("differing files: %s" % dif[:3])
lo, lb = (open(os.path.join(r, dif[0]), encoding='utf-8').read().split('\n') for r in (o, b))
if len(lo) != len(lb): die("line counts differ")
d = [i for i in range(len(lo)) if lo[i] != lb[i]]
if len(d) != 1: die("%d lines differ" % len(d))
mo, mb = R.fullmatch(lo[d[0]]), R.fullmatch(lb[d[0]])
if not (mo and mb): die("the differing line is not mapping_file_id")
if sum(K in x for x in lo) != 1 or sum(K in x for x in lb) != 1: die("key not unique")
print("sole decoded difference is mapping_file_id %s vs %s" % (mo[1], mb[1]))
PYEOF

# SourceStamp: EARNED, never filename-excluded. Play injects it post-build.
stamp_ok() {
  local o="$1" n sz
  n=$(unzip -l "$o" 2>/dev/null | awk '{print $NF}' | grep -cx 'stamp-cert-sha256')
  [[ "$n" -eq 1 ]] || { echo "      stamp: ${n} root entries, expected 1"; return 1; }
  [[ -e /tmp/b/stamp-cert-sha256 ]] && { echo "      stamp: present in BUILT too"; return 1; }
  sz=$(stat -c%s /tmp/o/stamp-cert-sha256 2>/dev/null || echo -1)
  [[ "$sz" -eq 32 ]] || { echo "      stamp: ${sz} bytes, expected 32"; return 1; }
  "$APKSIGNER" verify --verbose --print-certs "$o" > /tmp/sv.txt 2>/dev/null
  grep -q 'Verified for SourceStamp: true' /tmp/sv.txt || { echo "      stamp: apksigner SourceStamp not verified"; return 1; }
  echo "      stamp: 1 root entry, off-only, 32 bytes, apksigner SourceStamp OK"
}

# AndroidManifest: accepted ONLY if the sole delta is Play's distribution meta-data, off-only.
# base has 3 entries, config splits only derived.apk.id: blocks must equal allowlisted names.
manifest_ok() {
  local o="$1" b="$2" c="$3" d left bad n m
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$o" > /tmp/mo.txt 2>/dev/null || return 1
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$b" > /tmp/mb.txt 2>/dev/null || return 1
  d="$(diff /tmp/mo.txt /tmp/mb.txt)"
  printf '%s\n' "$d" > "/out/diff_manifest_${c}.txt"
  grep -q '^>' <<<"$d" && { echo "      manifest: BUILT-only lines present"; return 1; }
  left="$(grep '^<' <<<"$d" | sed 's/^< *//')"
  bad="$(grep -vE '^E: meta-data|^A: [^ ]*android:name\(0x[0-9a-f]+\)="com\.android\.(stamp\.source|stamp\.type|vending\.derived\.apk\.id)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)="(https://play\.google\.com/store|STAMP_TYPE_DISTRIBUTION_APK)"|^A: [^ ]*android:value\(0x[0-9a-f]+\)=4$' <<<"$left")"
  if [[ -n "$(tr -d '[:space:]' <<<"$bad")" ]]; then
    echo "      manifest: unexpected off-only line(s):"
    head -3 <<<"$bad" | sed 's/^/        /'
    return 1
  fi
  n=$(grep -c '^E: meta-data' <<<"$left")
  m=$(grep -c 'android:name(0x[0-9a-f]*)="com\.android\.' <<<"$left")
  [[ "$n" -ge 1 && "$n" -eq "$m" ]] || { echo "      manifest: $n block(s) vs $m Play name(s)"; return 1; }
  echo "      manifest: $n off-only Play meta-data, none built-only"
}

# resources.arsc: decode both; accepted only when the decoded (or canonicalised) trees are identical.
ARSC_CLASS=""
arsc_ok() {
  local o="$1" b="$2" c="$3" rd rd2 pre=""
  rm -rf /tmp/do /tmp/db
  for x in "o $o" "b $b"; do
    $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/afw -o "/tmp/d${x%% *}" "${x#* }" >/dev/null 2>&1 || { echo "      arsc: DECODE FAILED (${x%% *})"; return 1; }
  done
  [[ -d /tmp/do/res && -d /tmp/db/res ]] || { echo "      arsc: no res/ after decode"; return 1; }
  rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
  printf '%s\n' "$rd" > "/out/diff_resources_decoded_${c}.txt"
  if [[ -z "$(tr -d '[:space:]' <<<"$rd")" ]]; then
    ARSC_CLASS="decoded-identical"; echo "      arsc: decoded res/ tree IDENTICAL (binary packing artifact)"
    return 0
  fi
  if python3 /tmp/cn.py /tmp/do/res /tmp/db/res > /tmp/cn.txt 2>&1; then
    sed 's/^/      arsc: /' /tmp/cn.txt
    rd2="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
    printf '%s\n' "$rd2" > "/out/diff_resources_normalised_${c}.txt"
    if [[ -z "$(tr -d '[:space:]' <<<"$rd2")" ]]; then
      ARSC_CLASS="cl-buildid-order-only"; echo "      arsc: canonicalised FULL decoded res/ IDENTICAL"
      return 0
    fi
    pre="cl-buildid-order+"
  else
    sed 's/^/      arsc: /' /tmp/cn.txt
  fi
  if python3 /tmp/mf.py /tmp/do/res /tmp/db/res > /tmp/mf.txt 2>&1; then
    sed 's/^/      arsc: /' /tmp/mf.txt
    ARSC_CLASS="${pre}mapping-file-id"; echo "$c" >> /out/mapping_id.txt
    return 0
  fi
  sed 's/^/      arsc: /' /tmp/mf.txt
  echo "      arsc: other decoded changes remain -> material"
  diff -r /tmp/do/res /tmp/db/res 2>/dev/null | head -5 | sed 's/^/        /'
  return 1
}

declare -A OFF BLT
for f in /official/*.apk; do OFF["$(cfg_of "$f")"]="$f"; done
for f in /built/*.apk;    do BLT["$(cfg_of "$f")"]="$f"; done

RAW=0; SIGN=0; STAMP=0; MANI=0; ARSC=0; UNACC=0; MISSING=0
: > /out/summary.txt; : > /out/mapping_id.txt

for cfg in $(printf '%s\n' "${!OFF[@]}" "${!BLT[@]}" | sort -u); do
  printf '\n======== %s ========\n' "$cfg"
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

  while IFS= read -r so; do r="${so#/tmp/o/}"
    if [[ ! -f "/tmp/b/$r" ]]; then st=MISSING-IN-BUILT; elif cmp -s "$so" "/tmp/b/$r"; then st=MATCH; else st=DIFFER; fi
    echo "  native $st $r"
  done < <(find /tmp/o -name '*.so' -type f | sort)

  raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"
  printf '%s\n' "$raw" > "/out/diff-unzipped-${cfg}.txt"
  n=$(grep -vc '^$' <<<"$raw")
  echo "  raw diffs: ${n}   (full list: diff-unzipped-${cfg}.txt)"
  [[ "$n" -gt 0 ]] && head -5 <<<"$raw" | sed 's/^/    /'

  read -r c_sign c_stamp c_mani c_arsc < <(awk '
    /\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)/{a++;next}
    /stamp-cert-sha256/{b++} /AndroidManifest\.xml/{c++} /resources\.arsc/{d++}
    END{print a+0, b+0, c+0, d+0}' <<<"$raw")
  a_sign=0; a_stamp=0; a_mani=0; a_arsc=0
  echo "  accepted-class evidence"
  [[ "$c_sign" -gt 0 ]] && { a_sign=$c_sign
    echo "      signing: ${c_sign} META-INF entry(ies); the release is signed, the local build unsigned"; }
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
  grep -q 'baseline\.prof' <<<"$raw" && \
    echo "      baseline.prof: NEVER auto-accepted (FDROID.md: non-deterministic) -> material"

  acc=$((a_sign + a_stamp + a_mani + a_arsc))
  un=$((n - acc)); [[ "$un" -lt 0 ]] && un=0
  echo "  result: raw ${n}, accepted ${acc} (signing ${a_sign}, stamp ${a_stamp}, manifest ${a_mani}, arsc ${a_arsc}), unaccounted ${un}"
  echo "${cfg} ${n} ${a_sign} ${a_stamp} ${a_mani} ${a_arsc} ${un}" >> /out/summary.txt
  RAW=$((RAW + n)); SIGN=$((SIGN + a_sign)); STAMP=$((STAMP + a_stamp))
  MANI=$((MANI + a_mani)); ARSC=$((ARSC + a_arsc)); UNACC=$((UNACC + un))
done

echo "TOTALS ${RAW} ${SIGN} ${STAMP} ${MANI} ${ARSC} ${UNACC} ${MISSING}" >> /out/summary.txt
echo ""
echo "=== comparison complete: raw ${RAW}, unaccounted ${UNACC}, unmatched ${MISSING} ==="
CMP_END

crun --volume "$OFFICIAL_DIR:/official:ro" --volume "${BUILD_DIR}/built:/built:ro" --volume "${CMP_DIR}:/out" \
  --volume "${img_ctx}/compare.sh:/compare.sh:ro" "$IMG" bash /compare.sh 2>&1 | tee "${CMP_DIR}/comparison.log"
CMP_RC=${PIPESTATUS[0]}

if [[ $CMP_RC -ne 0 ]] || ! grep -q '^TOTALS' "${CMP_DIR}/summary.txt" 2>/dev/null; then
  log_info "Comparison log: ${CMP_DIR}/comparison.log"
  abort "Comparison stage failed (exit ${CMP_RC}); the build worked, so no ftbfs. No verdict."
fi

read -r _ raw_total t_sign t_stamp t_mani t_arsc t_unacc t_missing < <(grep '^TOTALS' "${CMP_DIR}/summary.txt")
raw_total="${raw_total:-1}"; t_sign="${t_sign:-0}"; t_stamp="${t_stamp:-0}"
t_mani="${t_mani:-0}"; t_arsc="${t_arsc:-0}"; t_unacc="${t_unacc:-1}"; t_missing="${t_missing:-1}"
t_acc=$((t_sign + t_stamp + t_mani + t_arsc))
t_mfid="$(grep -c . "${CMP_DIR}/mapping_id.txt" 2>/dev/null)"; t_mfid="${t_mfid:-0}"

section "RESULT"
cat <<EOF
 ${#OFFICIAL_APKS[@]} official APK(s): ${raw_total} raw differences, ${t_acc} earned (sign ${t_sign}, stamp ${t_stamp}, manifest ${t_mani}, arsc ${t_arsc}; mapping_file_id on ${t_mfid})
 UNACCOUNTED: ${t_unacc}, unmatched: ${t_missing}   <- the verdict is judged on these alone
 Full diffs: ${CMP_DIR}/   Gradle log: ${BUILD_DIR}/gradle-build.log
 Per APK (cfg raw sign stamp manifest arsc unaccounted):
$(sed 's/^/   /' "${CMP_DIR}/summary.txt")
EOF

if [[ "$t_missing" -gt 0 ]]; then
  log_warn "Verdict: not_reproducible -- ${t_missing} APK(s) present on only one side"
  VERDICT="not_reproducible"; EXIT_CODE=1
elif [[ "$t_unacc" -eq 0 ]]; then
  log_success "Verdict: reproducible -- zero unaccounted differences"
  VERDICT="reproducible"; EXIT_CODE=0
else
  log_warn "Verdict: not_reproducible -- ${t_unacc} unaccounted difference(s)"
  VERDICT="not_reproducible"; EXIT_CODE=1
fi
if [[ "$KIND" == play ]]; then SIGNER_NOTE="Play App Signing's key, not the developer key"
else SIGNER_NOTE="the developer's release key (v2 scheme)"; fi

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
scriptHash:      ${SCRIPT_HASH:-N/A}

Diff:            ${raw_total} raw, ${t_acc} accepted, ${t_unacc} unaccounted, ${t_missing} unmatched
tag:             ${tag_info}
===== End Results =====

channel:         ${CHANNEL}
lineage:         ${LINEAGE} (signals: $google_signals)
sourceRef:       ${built_ref:-unknown} (branch ${LINEAGE}), from ${rev_source}
candidateCommits: ${candidate_count:-1}
gitHashInBinary: ${git_hash:-none}
agpVersion:      official ${official_agp:-?}, built revision ${built_agp:-?}
gradle:          ${TASK} ${GRADLE_FLAGS}${FLAG_WHY:+ (${FLAG_WHY})}
depProvenance:   JitPack deps consumed as published binaries, not rebuilt from source

 Publish appHash: $(basename "$apk_file") as supplied/downloaded. Built hashes (comparison log)
 are never the official hash. signer is ${SIGNER_NOTE}.
EOF

generate_yaml "${VERDICT}" "${CHANNEL}, ${LINEAGE} lineage detected from contents ($google_signals). Revision ${built_ref:-unknown} from ${rev_source}; tag ${tag_info}. Built ${TASK} ${GRADLE_FLAGS}${FLAG_WHY:+ (${FLAG_WHY})}. ${raw_total} raw difference(s), ${t_acc} earned exclusions: signing ${t_sign}, SourceStamp ${t_stamp}, Play manifest meta-data ${t_mani}, resources.arsc ${t_arsc} (decoded res/ identical, after canonicalising the Crashlytics build_ids triples; on ${t_mfid} APK(s) the sole remaining decoded difference was the random Crashlytics mapping_file_id, approved by Danny 2026-10-12). ${t_unacc} unaccounted, ${t_missing} unmatched; the verdict is judged on these alone. Official $(basename "$apk_file") SHA-256 ${app_hash}. JitPack deps were consumed as published binaries, not rebuilt from source."

echo ""
echo "Exit code: ${EXIT_CODE}"
exit "${EXIT_CODE}"
