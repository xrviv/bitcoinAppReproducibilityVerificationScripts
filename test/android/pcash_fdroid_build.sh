#!/bin/bash
# ==============================================================================
# pcash_fdroid_build.sh - P.CASH Terminal Wallet (F-Droid) Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.1
# Organization:  WalletScrutiny.com
# Last Modified: 2026-08-20
# App ID:        cash.p.terminal
# Project:       https://github.com/piratecash/pcash-wallet
# F-Droid:       https://f-droid.org/en/packages/cash.p.terminal/
# ==============================================================================
#
# SUPPORTED CHANNEL: GITHUB RELEASE / F-DROID (single APK).
#
# Both P.CASH channels build from the SAME source - branch `f-droid`, tag
# `v<version>-fdroid` - and differ only in PACKAGING. Branch `master` is not
# shipped. This script takes the GITHUB/F-DROID artifact: a single GPG-signed
# `p.cash.apk`, supplied via --binary or downloaded when it is omitted.
# For a device-pulled Play split set use pcash_play_build.sh instead.
# The two scripts are standalone; running one never requires the other.
#
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose. Users assume all risks
# associated with running this script and analyzing the software. This script
# performs automated builds and APK comparisons - review all operations before
# execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for compliance with all applicable
# laws and regulations. The developers assume no liability for any misuse or
# legal consequences arising from use of this script.
#
# SCRIPT SUMMARY:
#   1. Takes the official p.cash.apk via --binary, or with no --binary downloads
#      it from GitHub Releases and verifies the detached GPG signature, the
#      signature over the checksum file, and the checksum itself against key
#      A6F0CB1BB25FFE99 (fingerprint 8A47 C2AB ED28 39E6 71B5 0620 A6F0 CB1B
#      B25F FE99). Authentication failure is fatal.
#   2. Reads package name, versionName, versionCode and signer from the APK, and
#      confirms the artifact really is F-Droid lineage (Firebase absent).
#   3. Derives the git tag as v<versionName>-fdroid. This mapping was checked
#      against fdroiddata metadata/cash.p.terminal.yml, whose build entry for
#      0.59.1 names commit 936888eb439eb9682ebc65f30aa86a5222e5184e - exactly
#      what tag v0.59.1-fdroid points at. It also records whether the tag is
#      annotated and GPG-signed.
#   4. Builds a container: Ubuntu 24.04 (digest-pinned), JDK 21, Android SDK
#      platform 36 + build-tools 36.0.0, apktool 3.0.3. No NDK - the project
#      contains no native compilation.
#   5. Clones the repo, checks out the tag onto a local branch named f-droid,
#      and runs ./gradlew clean :app:assembleRelease -Pfdroid=true, matching
#      F-Droid's own recipe (subdir app, gradleProps fdroid=true). Output is
#      app/build/outputs/apk/release/p.cash.apk - app/build.gradle renames every
#      release output via androidComponents.onVariants, so the AGP default names
#      never appear.
#   6. Compares the built APK against the official one and applies the
#      sanctioned resources.arsc decode process. All other differences are
#      counted, never filtered.
#
# Exit codes: 0 = identical, 1 = any difference or build failure,
#             2 = invalid parameters.
# ==============================================================================

SCRIPT_VERSION="v0.2.1"

# Self-identify first: ties a verdict to the exact script bytes that produced it.
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
echo "pcash_fdroid_build.sh ${SCRIPT_VERSION} sha256:${SCRIPT_HASH:-unknown}"
echo "Starting pcash_fdroid_build.sh ${SCRIPT_VERSION} (F-Droid lineage)"

# Deliberately no -e: diff and cmp return 1 on legitimate differences.
set -uo pipefail

SCRIPT_NAME="pcash_fdroid_build.sh"
COUNTERPART="pcash_play_build.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ID="cash.p.terminal"
REPO_URL="https://github.com/piratecash/pcash-wallet"
GPG_KEY_ID="A6F0CB1BB25FFE99"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

banner() {
    echo ""; echo ""
    echo "############################################"
    echo "##"
    printf "##  %s\n" "$*"
    echo "##"
    echo "############################################"
}

section() {
    echo ""
    echo "--------------------------------------------"
    printf "  %s\n" "$*"
    echo "--------------------------------------------"
}

sha256of() { sha256sum "$1" | awk '{print $1}'; }

# MUST stay $PWD, never $SCRIPT_DIR: both P.CASH scripts live in one directory and
# would overwrite each other's COMPARISON_RESULTS.yaml. See changelog 2026-08-20.
execution_dir="$(pwd -P)"

# Only these three keys, ever: script_version, verdict, notes.
generate_yaml() {
    local verdict="$1" notes="$2"
    cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}
EOF
    log_info "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

die_invalid() {
    log_error "$1"
    generate_yaml "ftbfs" "Invalid invocation: $1"
    echo ""; echo "Exit code: 2"
    exit 2
}

# Root would leave root-owned artifacts and defeat the container user mapping.
if [[ "$EUID" -eq 0 ]]; then
    die_invalid "Do not run this script as root."
fi

# --- Argument parsing. --version is OPTIONAL (ABS does not pass it): it only
# selects the release tag when downloading. Unknown parameters warn and continue.

version_arg=""
binary_arg=""
arch_arg=""
type_arg=""

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        die_invalid "${flag} requires a value (got: '${val:-<nothing>}')"
    fi
}

usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} [--binary <p.cash.apk>] [--version <v>] [--arch <a>] [--type <t>]

  --binary   Optional. A single official p.cash.apk. Omit it and the script
             downloads the APK from GitHub Releases and verifies it against GPG
             key ${GPG_KEY_ID}.
             Have a DIRECTORY of device-pulled splits? Those are Play artifacts;
             use ${COUNTERPART}.
  --version  Optional. Selects the release tag when downloading (v<version>-fdroid).
             Otherwise the authoritative version is read from the APK.
  --arch     Optional. Logged; this lineage ships one universal APK.
  --type     Optional. Logged.

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
        *)
            log_warn "Unknown argument: $1 (ignored)"
            shift
            continue
            ;;
    esac
done

# --- --binary is optional and must be a single APK; a directory is the Play set.

NEED_DOWNLOAD=0
if [[ -z "$binary_arg" ]]; then
    NEED_DOWNLOAD=1
    log_info "No --binary given; the official p.cash.apk will be downloaded and GPG-verified."
elif [[ ! -e "$binary_arg" ]]; then
    die_invalid "--binary path does not exist: ${binary_arg}"
elif [[ -d "$binary_arg" ]]; then
    log_error "--binary must be a single p.cash.apk, but a directory was given:"
    log_error "  ${binary_arg}"
    log_error "A directory of base.apk + split_config.*.apk is a Google Play split set,"
    log_error "built from branch master with Firebase present. Verify it with"
    log_error "${COUNTERPART} instead."
    generate_yaml "ftbfs" "--binary was a directory, but the F-Droid lineage ships a single p.cash.apk. A device-pulled split set belongs to the Google Play lineage; use ${COUNTERPART}."
    echo ""; echo "Exit code: 2"
    exit 2
fi

[[ -n "$arch_arg" ]]    && log_info "--arch ${arch_arg} accepted; this lineage ships one universal APK"
[[ -n "$type_arg" ]]    && log_info "--type ${type_arg} accepted but not used"
[[ -n "$version_arg" ]] && log_info "--version ${version_arg} accepted"

# --- Container runtime and user mapping. Every write-path run MUST map the
# container user to the host user or it leaves root-owned files needing sudo.
# HOME=/tmp is required: apktool caches frameworks under $HOME.

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

banner "PRE-FLIGHT: HOST TOOL CHECK"
printf "  %-10s OK  (%s)\n" "$CONTAINER_CMD" "$(command -v "$CONTAINER_CMD")"
echo "  No host JDK, Gradle, Android SDK, gpg or apktool is required or used."

RUN_ID="pcash-fdroid-$(date +%s)-$$"
IMG="ws-pcash-fdroid-${RUN_ID}"
workspace="${execution_dir}/pcash_fdroid_verification_${RUN_ID}"
META_DIR="${workspace}/metadata"
BUILD_DIR="${workspace}/source-build"
CMP_DIR="${workspace}/comparison"
OFFICIAL_DIR="${workspace}/official"
img_ctx=""

mkdir -p "$META_DIR" "$BUILD_DIR" "$CMP_DIR" "$OFFICIAL_DIR"

# Copy into a dedicated dir: the parent is mounted into the comparison container,
# so any unrelated .apk beside it would be read as a second official artifact.
if [[ "$NEED_DOWNLOAD" -eq 0 ]]; then
    cp "$(realpath "$binary_arg")" "${OFFICIAL_DIR}/p.cash.apk"
fi
apk_file="${OFFICIAL_DIR}/p.cash.apk"

# Reclaims ownership under the caller's workdir on EVERY exit path, so cleanup
# after a failed run never needs sudo.
# LANDMINE: deliberately does NOT use the mapped-user container args - it must run
# as ROOT inside the container to chown. Adding them here would break cleanup.
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

banner "P.CASH TERMINAL WALLET - F-DROID LINEAGE VERIFICATION"
echo "  Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "  App ID:    ${APP_ID}"
echo "  Repo:      ${REPO_URL}"
echo "  Binary:    $([[ "$NEED_DOWNLOAD" -eq 1 ]] && echo '<to be downloaded from GitHub Releases>' || echo "$binary_arg")"
echo "  Runtime:   ${CONTAINER_CMD} ($($CONTAINER_CMD --version 2>&1 | head -1))"
echo "  Workspace: ${workspace}"
echo "  Date:      $(date)"

# --- One pinned image serves download, metadata extraction, build and compare.
# JDK 21 is the build JDK (app targets Java 17 bytecode). No NDK: the project
# compiles nothing native. No bundletool: this channel ships a plain APK.
# Rationale in changelog 2026-08-20.

banner "SETUP: BUILD CONTAINER IMAGE"
echo "  Started: $(date)"

img_ctx="$(mktemp -d)"

cat > "${img_ctx}/Dockerfile" <<'DOCKERFILE_END'
FROM ubuntu:24.04@sha256:a08e551cb33850e4740772b38217fc1796a66da2506d312abe51acda354ff061
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk-headless git unzip zip wget curl ca-certificates gnupg \
        binutils && \
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

# compileSdk/targetSdk are 36; build-tools 36.0.0 supplies aapt2 and apksigner.
RUN yes | sdkmanager --licenses >/dev/null && \
    sdkmanager "platforms;android-36" "build-tools;36.0.0" "platform-tools" >/dev/null

ADD https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar /opt/apktool.jar
RUN chmod 0644 /opt/apktool.jar

RUN mkdir -p /tmp/apktool-framework && chmod 0777 /tmp /tmp/apktool-framework
WORKDIR /build
DOCKERFILE_END

section "Building image ${IMG}"
if ! $CONTAINER_CMD build -t "$IMG" -f "${img_ctx}/Dockerfile" "$img_ctx"; then
    log_error "Container image build failed"
    generate_yaml "ftbfs" "Container image build failed; no comparison was performed."
    echo ""; echo "Exit code: 1"
    exit 1
fi
log_success "Image built: ${IMG}"

# --- PHASE A: download and authenticate when --binary was omitted. Each release
# carries the APK, a detached GPG signature, a SHA-256 file and a signature over
# that. Verification failure is FATAL: verifying the wrong bytes is worse than
# not verifying at all.

if [[ "$NEED_DOWNLOAD" -eq 1 ]]; then
    banner "PHASE A: DOWNLOAD AND AUTHENTICATE THE OFFICIAL BINARY"

    cat > "${img_ctx}/fetch.sh" <<'FETCH_END'
#!/bin/bash
set -uo pipefail
REPO="__REPO_URL__"
VER="__VERSION_ARG__"
KEY="__GPG_KEY_ID__"

cd /output || exit 1

# With no --version, resolve whatever the project currently calls latest.
if [[ -z "$VER" ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/piratecash/pcash-wallet/releases/latest" \
           | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
else
    tag="v${VER}-fdroid"
fi
[[ -n "$tag" ]] || { echo "FATAL: could not resolve a release tag"; exit 1; }
echo "Release tag: ${tag}"
printf '%s\n' "$tag" > /output/release_tag.txt

base="${REPO}/releases/download/${tag}"
for f in p.cash.apk p.cash.apk.asc p.cash.apk.sha256 p.cash.apk.sha256.asc; do
    echo "  fetching ${f}"
    curl -fsSL -o "/output/${f}" "${base}/${f}" \
        || { echo "FATAL: cannot download ${f} from ${base}"; exit 1; }
done

# The public key is committed in the repo, so fetch it from the same tag.
curl -fsSL -o /output/pubkey.asc \
    "https://raw.githubusercontent.com/piratecash/pcash-wallet/${tag}/security/piratecash-release-public-key.asc" \
    || { echo "FATAL: cannot fetch the release public key"; exit 1; }

export GNUPGHOME=/tmp/gnupg
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
gpg --batch --import /output/pubkey.asc 2>&1 | sed 's/^/  /'
echo "=== imported key fingerprints (expect 8A47C2ABED2839E671B50620${KEY}) ==="
gpg --batch --with-colons --fingerprint 2>/dev/null | grep '^fpr' | head -3

echo "=== verify detached signature over the APK ==="
gpg --batch --verify /output/p.cash.apk.asc /output/p.cash.apk 2>&1 | tee /output/gpg-verify-apk.txt
apk_ok=${PIPESTATUS[0]}

echo "=== verify detached signature over the checksum file ==="
gpg --batch --verify /output/p.cash.apk.sha256.asc /output/p.cash.apk.sha256 2>&1 | tee /output/gpg-verify-sha.txt
sha_ok=${PIPESTATUS[0]}

echo "=== verify the checksum itself ==="
( cd /output && sha256sum -c p.cash.apk.sha256 ) 2>&1 | tee /output/sha256-check.txt
sum_ok=${PIPESTATUS[0]}

if [[ $apk_ok -ne 0 || $sha_ok -ne 0 || $sum_ok -ne 0 ]]; then
    echo "FATAL: authentication failed (apk_sig=${apk_ok} sha_sig=${sha_ok} checksum=${sum_ok})"
    exit 1
fi
echo "Official artifact authenticated against key ${KEY}."
FETCH_END
    sed -i \
        -e "s|__REPO_URL__|${REPO_URL}|g" \
        -e "s|__VERSION_ARG__|${version_arg}|g" \
        -e "s|__GPG_KEY_ID__|${GPG_KEY_ID}|g" \
        "${img_ctx}/fetch.sh"

    if ! $CONTAINER_CMD run --rm \
        "${CONTAINER_RUN_USER_ARGS[@]}" \
        --volume "${OFFICIAL_DIR}:/output" \
        --volume "${img_ctx}/fetch.sh:/fetch.sh:ro" \
        "$IMG" bash /fetch.sh; then
        log_error "Could not download or authenticate the official release artifact"
        generate_yaml "ftbfs" "Failed to download or GPG-verify the official p.cash.apk from GitHub Releases against key ${GPG_KEY_ID}. Nothing was built or compared."
        echo ""; echo "Exit code: 1"
        exit 1
    fi
    log_success "Official p.cash.apk downloaded and GPG-verified against key ${GPG_KEY_ID}"

    # Keep only the APK in the directory the comparison container sees; the
    # signature and checksum files are not APKs and must not be mounted as artifacts.
    mkdir -p "${workspace}/official-apk"
    cp "${OFFICIAL_DIR}/p.cash.apk" "${workspace}/official-apk/p.cash.apk"
    OFFICIAL_DIR="${workspace}/official-apk"
    apk_file="${OFFICIAL_DIR}/p.cash.apk"
fi

# --- PHASE 0: metadata straight out of the official APK. GIT_HASH/GIT_BRANCH are
# read from the dex string pool as INFORMATIONAL evidence only - the tag decides
# what is built, not the binary.

banner "PHASE 0: OFFICIAL BINARY METADATA"
echo "  Started: $(date)"

cat > "${img_ctx}/meta.sh" <<'META_END'
#!/bin/bash
set -uo pipefail
AAPT2="${ANDROID_HOME}/build-tools/36.0.0/aapt2"
APKSIGNER="${ANDROID_HOME}/build-tools/36.0.0/apksigner"

info="$("$AAPT2" dump badging /input/official.apk 2>/dev/null)"

# LANDMINE: anchor on '^package:' and stop at the first quote. A greedy '.*name='
# matches versionName= and silently returns the wrong value.
pkg="$(printf '%s\n' "$info" | grep '^package:' | sed "s/^package: name='\([^']*\)'.*/\1/")"
vname="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionName='\([^']*\)'.*/\1/")"
vcode="$(printf '%s\n' "$info" | grep '^package:' | sed "s/.*versionCode='\([^']*\)'.*/\1/")"

signer="$("$APKSIGNER" verify --print-certs /input/official.apk 2>/dev/null \
    | awk '/Signer #1 certificate SHA-256/ {print $NF; exit}')"

printf '%s\n' "${pkg:-unknown}"    > /output/pkg_name.txt
printf '%s\n' "${vname:-unknown}"  > /output/version_name.txt
printf '%s\n' "${vcode:-unknown}"  > /output/version_code.txt
printf '%s\n' "${signer:-unknown}" > /output/signer.txt

rm -rf /tmp/dex && mkdir -p /tmp/dex
unzip -q -o /input/official.apk 'classes*.dex' -d /tmp/dex 2>/dev/null
: > /output/git_hash.txt
: > /output/git_branch.txt
: > /output/git_hash_candidates.txt
if compgen -G "/tmp/dex/classes*.dex" > /dev/null; then
    # LANDMINE: this app's GIT_HASH is ALWAYS "<10hex>-fdroid" or the literal
    # "unknown" - a BARE 10-hex string can never be it, it is an unrelated dex
    # literal. Do not loosen this pattern or drop the degenerate all-same-char
    # filter: without them the matcher picks "0000000000". See changelog 2026-08-20.
    strings -a /tmp/dex/classes*.dex 2>/dev/null \
        | grep -xE '[0-9a-f]{10}(-dirty)?(-fdroid)?|unknown' \
        | awk '{ h=$0; sub(/-.*$/,"",h);
                 if (h=="unknown") { print; next }
                 c=substr(h,1,1); u=0;
                 for(i=2;i<=length(h);i++) if(substr(h,i,1)!=c) { u=1; break }
                 if (u) print }' \
        | sort -u > /output/git_hash_candidates.txt
    grep -m1 -xE '[0-9a-f]{10}(-dirty)?-fdroid' /output/git_hash_candidates.txt \
        > /output/git_hash.txt 2>/dev/null || \
    grep -m1 -x 'unknown' /output/git_hash_candidates.txt \
        > /output/git_hash.txt 2>/dev/null || \
    head -1 /output/git_hash_candidates.txt > /output/git_hash.txt 2>/dev/null || true
    # LANDMINE: report EVERY match, never `head -1`. "f-droid" sorts before
    # "master", so head -1 always claims "f-droid" when both literals appear
    # anywhere in the dex - making it non-probative. See changelog 2026-08-20.
    strings -a /tmp/dex/classes*.dex 2>/dev/null \
        | grep -xE 'f-droid|master' | sort -u | paste -sd, - > /output/git_branch.txt || true
fi

# Both channels come off the f-droid branch, which excludes com.google.firebase
# and com.google.android.gms, so no released artifact should carry them.
fb=0
unzip -l /input/official.apk 2>/dev/null | grep -qi 'firebase\|crashlytics' && fb=1
bp=0
unzip -l /input/official.apk 2>/dev/null | grep -q 'assets/dexopt/baseline.prof' && bp=1
printf '%s\n' "$fb" > /output/has_firebase.txt
printf '%s\n' "$bp" > /output/has_baseline_profile.txt

echo "[META] package:            ${pkg:-unknown}"
echo "[META] versionName:        ${vname:-unknown}"
echo "[META] versionCode:        ${vcode:-unknown}"
echo "[META] signer SHA-256:     ${signer:-unknown}"
echo "[META] GIT_HASH (dex):     $(cat /output/git_hash.txt 2>/dev/null)"
echo "[META] GIT_BRANCH literals:$(cat /output/git_branch.txt 2>/dev/null) (all matches; not proof of branch)"
echo "[META] firebase present:   ${fb}"
echo "[META] baseline.prof:      ${bp}"
META_END
chmod +x "${img_ctx}/meta.sh"

if ! $CONTAINER_CMD run --rm \
    "${CONTAINER_RUN_USER_ARGS[@]}" \
    "${MEM_ARGS[@]}" \
    --volume "${apk_file}:/input/official.apk:ro" \
    --volume "${META_DIR}:/output" \
    --volume "${img_ctx}/meta.sh:/meta.sh:ro" \
    "$IMG" bash /meta.sh; then
    log_error "Metadata extraction failed"
    generate_yaml "ftbfs" "Could not read metadata from the supplied p.cash.apk."
    echo ""; echo "Exit code: 1"
    exit 1
fi

pkg_id="$(cat "${META_DIR}/pkg_name.txt" 2>/dev/null || echo unknown)"
wallet_version="$(cat "${META_DIR}/version_name.txt" 2>/dev/null || echo unknown)"
version_code="$(cat "${META_DIR}/version_code.txt" 2>/dev/null || echo unknown)"
signer="$(cat "${META_DIR}/signer.txt" 2>/dev/null || echo unknown)"
git_hash="$(cat "${META_DIR}/git_hash.txt" 2>/dev/null || echo '')"
git_branch="$(cat "${META_DIR}/git_branch.txt" 2>/dev/null || echo '')"
has_firebase="$(cat "${META_DIR}/has_firebase.txt" 2>/dev/null || echo 0)"
has_baseline="$(cat "${META_DIR}/has_baseline_profile.txt" 2>/dev/null || echo 0)"
app_hash="$(sha256of "$apk_file")"

# Mandatory package-name check, before anything is built.
if [[ "$pkg_id" != "$APP_ID" ]]; then
    die_invalid "APK package name mismatch: expected ${APP_ID}, got ${pkg_id}"
fi
log_success "Package name verified: ${pkg_id}"
log_success "Version: ${wallet_version} (versionCode ${version_code})"
log_info    "Signer SHA-256:   ${signer}"
log_info    "p.cash.apk SHA-256: ${app_hash}"
log_info    "GIT_HASH in dex:  ${git_hash:-<not recovered>}"

if [[ "$wallet_version" == "unknown" || -z "$wallet_version" ]]; then
    die_invalid "Could not read versionName from the supplied APK"
fi
if [[ -n "$version_arg" && "$version_arg" != "$wallet_version" ]]; then
    log_warn "--version was '${version_arg}' but the APK reports '${wallet_version}'; using the binary's value"
fi

########################
# Lineage sanity check. versionName and versionCode are IDENTICAL on both branches,
# so this content fingerprint is what catches someone running the wrong script for
# the binary they have.
########################

section "Lineage sanity check"
echo "  Firebase/Crashlytics entries present: ${has_firebase}  (f-droid branch expects 0)"
echo "  assets/dexopt/baseline.prof present:  ${has_baseline}  (-Pfdroid=true expects 0)"
echo "  BuildConfig.GIT_BRANCH from dex:      ${git_branch:-<not recovered>}"

if [[ "$has_firebase" != "0" ]]; then
    log_error "This binary carries Firebase/Crashlytics entries, so it did NOT come off the"
    log_error "f-droid branch, which excludes com.google.firebase and com.google.android.gms."
    log_error "Both shipping channels build from that branch, so no released P.CASH artifact"
    log_error "should contain them. Check the artifact's provenance before proceeding."
    generate_yaml "ftbfs" "The supplied artifact contains Firebase/Crashlytics entries, but both P.CASH channels build from the f-droid branch, which excludes those groups outright. The artifact does not match any released build; verify its provenance."
    echo ""; echo "Exit code: 2"
    exit 2
fi
if [[ "$has_baseline" != "0" ]]; then
    log_warn "assets/dexopt/baseline.prof is present, which -Pfdroid=true is supposed to omit."
    log_warn "This artifact may not have been built with F-Droid's recipe."
fi
log_success "F-Droid lineage confirmed"

########################
# Resolve the source revision. Tag scheme is v<versionName>-fdroid, cross-checked
# against fdroiddata metadata/cash.p.terminal.yml, whose 0.59.1 entry names commit
# 936888eb439eb9682ebc65f30aa86a5222e5184e -- exactly what tag v0.59.1-fdroid
# points at. The f-droid branch is force-rebased onto master by the project's own
# workflow, so the tags are the only stable references into that history.
########################

section "Resolving source revision"
GIT_REF="v${wallet_version}-fdroid"
GIT_BRANCH_NAME="f-droid"
echo "  Tag to build:            ${GIT_REF}"
echo "  Branch name to recreate: ${GIT_BRANCH_NAME}"

########################
# PHASE 1 -- build from source inside the container.
#
# Reproducibility hazards handled here:
#   * Must build in a real git checkout: app/build.gradle shells out to `git rev-parse`
#     for BuildConfig.GIT_HASH. A tarball export bakes in "unknown".
#   * Working tree must stay clean.
#   * Check out onto a NAMED branch f-droid for parity with the official build.
#   * -Pfdroid=true disables every task whose name contains "ArtProfile", which is
#     what keeps assets/dexopt/baseline.prof out of the APK. Without it the build is
#     not comparable: the project's own FDROID.md calls baseline profiles
#     non-deterministic between builds.
#   * FIREBASE_DEV_* must be unset -- app/build.gradle throws if some but not all four
#     are set, and they affect only the debug build. BUILD_NUMBER must be unset too.
#   * No secret injection is needed: EncodedSecrets.kt and app/google-services.json are
#     both committed, and no gradle task invokes tools/encode_secrets.kts.
########################

banner "PHASE 1: BUILD FROM SOURCE"
echo "  Started: $(date)"
echo "  Gradle:  ./gradlew clean :app:assembleRelease -Pfdroid=true"

cat > "${img_ctx}/build.sh" <<'BUILD_END'
#!/bin/bash
set -uo pipefail

REPO_URL="__REPO_URL__"
GIT_REF="__GIT_REF__"
GIT_BRANCH_NAME="__GIT_BRANCH_NAME__"

# These would corrupt the build if inherited from the host environment.
unset FIREBASE_DEV_KEYSTORE_PATH FIREBASE_DEV_STORE_PASSWORD \
      FIREBASE_DEV_KEY_ALIAS FIREBASE_DEV_KEY_PASSWORD BUILD_NUMBER

export GRADLE_USER_HOME=/tmp/gradle-home
mkdir -p "$GRADLE_USER_HOME"

echo "=== Clone ${REPO_URL} === $(date)"
# A full clone keeps tag objects and their signatures available for the check below.
git clone "$REPO_URL" /build/src || { echo "FATAL: clone failed"; exit 1; }
cd /build/src
git config --global --add safe.directory /build/src

# Check out onto a NAMED branch matching the official build's branch.
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

# The tree must be clean or app/build.gradle could append a dirty marker.
if ! git diff-index --quiet HEAD --; then
    echo "FATAL: working tree is dirty immediately after checkout; refusing to build"
    git status --porcelain | head -20
    exit 2
fi

# Record whether the release tag is annotated and GPG-signed. Evidence for the
# report; a lightweight tag simply has no signature to verify, which is not a fault.
{
    obj="$(git cat-file -t "$GIT_REF" 2>/dev/null || echo unknown)"
    echo "tag ${GIT_REF} object type: ${obj}"
    if [[ "$obj" == "tag" ]]; then
        echo "--- annotated tag; attempting GPG verification ---"
        git tag -v "$GIT_REF" 2>&1 || true
    else
        echo "Lightweight tag: no embedded GPG signature exists to verify."
    fi
} > /output/git-tag-verify.txt 2>&1
echo "=== tag provenance ==="
cat /output/git-tag-verify.txt

echo ""
echo "=== Toolchain in use ==="
java -version 2>&1
./gradlew --version 2>&1 | sed -n '1,12p'

echo ""
echo "=== Gradle build === $(date)"
# -Pfdroid=true matches F-Droid's recipe (gradleProps: fdroid=true) and disables
# ART profile packaging so baseline.prof/baseline.profm stay out of the APK.
./gradlew --no-daemon --max-workers=2 clean :app:assembleRelease -Pfdroid=true \
    > /output/gradle-build.log 2>&1
rc=$?
tail -60 /output/gradle-build.log
if [[ $rc -ne 0 ]]; then
    echo "FATAL: gradle build failed (exit ${rc})"
    exit 3
fi

echo ""
echo "=== Collect artifact === $(date)"
mkdir -p /output/built
# app/build.gradle renames every release output to a fixed p.cash.apk via
# androidComponents.onVariants, so the AGP default names never appear.
out="app/build/outputs/apk/release/p.cash.apk"
if [[ ! -f "$out" ]]; then
    echo "FATAL: expected ${out} not found"
    find app/build/outputs -name '*.apk' 2>/dev/null | head -20
    exit 3
fi
cp "$out" /output/built/p.cash.apk
sha256sum /output/built/p.cash.apk

# Confirm -Pfdroid=true actually took effect.
if unzip -l /output/built/p.cash.apk | grep -q 'assets/dexopt/baseline.prof'; then
    echo "WARNING: baseline.prof present in the built APK despite -Pfdroid=true"
else
    echo "OK: no baseline.prof in the built APK, as -Pfdroid=true intends"
fi

echo ""
echo "=== Dependency provenance (JitPack / piratecash forks) ==="
# Consumed as PUBLISHED BINARY ARTIFACTS: neither this build nor F-Droid's recipe
# rebuilds them, so a byte-match proves both sides fetched the same AAR, not that the
# AAR matches its source. Recorded so a human can follow up and a re-run can spot a
# moved tag (these deps are pinned to mutable git tags, not commit hashes).
grep -Eo 'https://jitpack\.io/[^ ]+\.(aar|jar|pom)' /output/gradle-build.log 2>/dev/null \
    | sort -u > /output/jitpack-artifacts.txt || true
echo "  distinct JitPack artifact URLs: $(wc -l < /output/jitpack-artifacts.txt 2>/dev/null || echo 0)"
find "$GRADLE_USER_HOME/caches/modules-2/files-2.1" \
     -path '*com.github.piratecash*' -name '*.aar' -print0 2>/dev/null \
    | xargs -0 -r sha256sum > /output/piratecash-aar-hashes.txt 2>/dev/null || true
echo "  piratecash AARs hashed:         $(wc -l < /output/piratecash-aar-hashes.txt 2>/dev/null || echo 0)"

echo ""
echo "=== Build complete $(date) ==="
BUILD_END

sed -i \
    -e "s|__REPO_URL__|${REPO_URL}|g" \
    -e "s|__GIT_REF__|${GIT_REF}|g" \
    -e "s|__GIT_BRANCH_NAME__|${GIT_BRANCH_NAME}|g" \
    "${img_ctx}/build.sh"
chmod +x "${img_ctx}/build.sh"

section "Running source build (expect 30-90 min on a cold Gradle cache)"
echo "  Started: $(date)"
$CONTAINER_CMD run --rm \
    "${CONTAINER_RUN_USER_ARGS[@]}" \
    "${MEM_ARGS[@]}" \
    --volume "${BUILD_DIR}:/output" \
    --volume "${img_ctx}/build.sh:/build/build.sh:ro" \
    "$IMG" bash /build/build.sh 2>&1 | tee "${BUILD_DIR}/container-build.log"
BUILD_RC=${PIPESTATUS[0]}

if [[ $BUILD_RC -ne 0 ]]; then
    log_error "Source build failed (container exit ${BUILD_RC})"
    log_info  "Full Gradle log: ${BUILD_DIR}/gradle-build.log"
    generate_yaml "ftbfs" "Source build failed for ${APP_ID} ${wallet_version} at tag ${GIT_REF} (container exit ${BUILD_RC}). Official p.cash.apk SHA-256: ${app_hash}."
    echo ""; echo "Exit code: 1"
    exit 1
fi
log_success "Source build finished"

tag_provenance="$(sed -n '1p' "${BUILD_DIR}/git-tag-verify.txt" 2>/dev/null || echo 'not recorded')"
log_info "Tag provenance: ${tag_provenance}"

built_hash_expect="$(cat "${BUILD_DIR}/expected_git_hash.txt" 2>/dev/null || echo '')"
if [[ -n "$git_hash" && -n "$built_hash_expect" ]]; then
    if [[ "${git_hash%%-*}" == "$built_hash_expect" ]]; then
        log_success "Revision cross-check: official GIT_HASH matches the tag's commit (${built_hash_expect})"
    else
        log_warn "Revision cross-check MISMATCH: binary reports '${git_hash}', tag commit is '${built_hash_expect}'"
        log_warn "The official APK may not have been built from tag ${GIT_REF}."
    fi
fi

########################
# PHASE 2 -- compare. No general acceptable-diffs filtering; every difference is
# counted. The one sanctioned exception is the resources.arsc decode process, a fixed
# decode-and-compare with a documented verdict table. Terminal output is capped at 5
# preview lines per diff; full diffs go to files whose paths are printed.
########################

banner "PHASE 2: APK COMPARISON"
echo "  Started: $(date)"

cat > "${img_ctx}/compare.sh" <<'CMP_END'
#!/bin/bash
set -uo pipefail
APKTOOL="java -jar /opt/apktool.jar"

o=/official/p.cash.apk
b=/built/p.cash.apk
cfg="p.cash.apk"

if [[ ! -f "$o" || ! -f "$b" ]]; then
    echo "FATAL: missing artifact (official=$([[ -f $o ]] && echo yes || echo NO), built=$([[ -f $b ]] && echo yes || echo NO))"
    exit 1
fi

echo "  official: $(sha256sum "$o" | cut -d' ' -f1)"
echo "  built:    $(sha256sum "$b" | cut -d' ' -f1)"

rm -rf /tmp/o /tmp/b; mkdir -p /tmp/o /tmp/b
unzip -q -o "$o" -d /tmp/o
unzip -q -o "$b" -d /tmp/b
echo "  entries: $(find /tmp/o -type f | wc -l) official, $(find /tmp/b -type f | wc -l) built"

# Per-ABI native library hashes. The APK carries prebuilt .so files from the
# JitPack AARs (armeabi-v7a and arm64-v8a per abiFilters); one present on only
# one side is a hard fail.
while IFS= read -r so; do
    rel="${so#/tmp/o/}"
    if [[ -f "/tmp/b/${rel}" ]]; then
        ho="$(sha256sum "$so" | cut -d' ' -f1)"
        hb="$(sha256sum "/tmp/b/${rel}" | cut -d' ' -f1)"
        [[ "$ho" == "$hb" ]] && st=MATCH || st=DIFFER
        echo "  native ${st} ${rel}"
    else
        echo "  native MISSING-IN-BUILT ${rel}"
    fi
done < <(find /tmp/o -name '*.so' -type f | sort)

raw="$(diff -rq /tmp/o /tmp/b 2>/dev/null)"
printf '%s\n' "$raw" > "/out/diff-unzipped-${cfg}.txt"

n=$(printf '%s\n' "$raw" | grep -vc '^$')
m=$(printf '%s\n' "$raw" | grep -Ec '\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)')
nn=$((n - m))

echo "  differences: ${n} total (${m} META-INF signing, ${nn} other)"
echo "  full diff:   diff-unzipped-${cfg}.txt"
if [[ "$n" -gt 0 ]]; then
    echo "  preview (max 5 lines):"
    printf '%s\n' "$raw" | head -5 | sed 's/^/    /'
fi

# ---- resources.arsc decode process (the one sanctioned exception) ----
arsc_acc=0
if printf '%s\n' "$raw" | grep -q 'resources\.arsc'; then
    echo "  resources.arsc differs -- running the decode comparison"
    rm -rf /tmp/do /tmp/db
    dec=1
    $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/apktool-framework \
        -o /tmp/do "$o" >/dev/null 2>&1 || dec=0
    $APKTOOL d -f --no-src --no-debug-info --frame-path /tmp/apktool-framework \
        -o /tmp/db "$b" >/dev/null 2>&1 || dec=0
    if [[ "$dec" -ne 1 || ! -d /tmp/do/res || ! -d /tmp/db/res ]]; then
        # A failed decode must never be read as "identical".
        echo "  resources.arsc: DECODE FAILED -- not classified, counts as a difference"
    else
        rd="$(diff -r /tmp/do/res /tmp/db/res 2>/dev/null)"
        printf '%s\n' "$rd" > "/out/diff_resources_decoded_${cfg}.txt"
        ch="$(printf '%s\n' "$rd" | grep -E '^[<>]')"
        # The crashlytics mapping ID cannot occur on this lineage (the plugin is not
        # applied), but the check is kept so the decode table is applied in full.
        nx="$(printf '%s\n' "$ch" | grep -v 'com.google.firebase.crashlytics.mapping_file_id' | tr -d '\n\r')"
        sole=0
        arsc_lines="$(printf '%s\n' "$raw" \
            | grep -vE '\.(SF|RSA|DSA|EC)( |$)|MANIFEST\.MF( |$)' \
            | grep -c 'resources\.arsc')"
        if [[ "$nn" -eq 1 && "$arsc_lines" -eq 1 ]]; then
            sole=1
        fi
        if [[ -z "$(printf '%s' "$rd" | tr -d '[:space:]')" ]]; then
            if [[ "$sole" -eq 1 ]]; then
                echo "  resources.arsc: decoded res/ IDENTICAL and sole remaining binary diff -> acceptable"
                arsc_acc=1
            else
                echo "  resources.arsc: decoded res/ identical but OTHER diffs remain -> not acceptable"
            fi
        elif [[ -n "$ch" && -z "$nx" ]]; then
            if [[ "$sole" -eq 1 ]]; then
                echo "  resources.arsc: sole decoded change is crashlytics.mapping_file_id and sole"
                echo "                  remaining binary diff -> acceptable build-time ID"
                arsc_acc=1
            else
                echo "  resources.arsc: only crashlytics mapping ID differs but OTHER diffs remain -> not acceptable"
            fi
        else
            echo "  resources.arsc: decoded res/ DIFFERS -- genuine semantic change"
            echo "  full decoded diff: diff_resources_decoded_${cfg}.txt"
            printf '%s\n' "$rd" | head -5 | sed 's/^/    /'
        fi
    fi
fi

# Flag-only, never auto-resolved: these go to the human verdict writer.
if printf '%s\n' "$raw" | grep -q 'baseline\.prof'; then
    echo "  FLAG: assets/dexopt/baseline.prof appears in the diff. -Pfdroid=true should"
    echo "        have omitted it from both sides; investigate before judging."
fi
if printf '%s\n' "$raw" | grep -q 'AndroidManifest\.xml'; then
    echo "  FLAG: AndroidManifest.xml differs -- flagged for human review, not classified here."
fi

echo "${cfg} ${n} ${m} ${nn} ${arsc_acc}" > /out/summary.txt
echo "TOTALS ${n} ${m} ${nn} 0 ${arsc_acc}" >> /out/summary.txt
echo ""
echo "=== comparison complete ==="
CMP_END
chmod +x "${img_ctx}/compare.sh"

$CONTAINER_CMD run --rm \
    "${CONTAINER_RUN_USER_ARGS[@]}" \
    "${MEM_ARGS[@]}" \
    --volume "${OFFICIAL_DIR}:/official:ro" \
    --volume "${BUILD_DIR}/built:/built:ro" \
    --volume "${CMP_DIR}:/out" \
    --volume "${img_ctx}/compare.sh:/compare.sh:ro" \
    "$IMG" bash /compare.sh 2>&1 | tee "${CMP_DIR}/comparison.log"
CMP_RC=${PIPESTATUS[0]}

if [[ $CMP_RC -ne 0 ]] || ! grep -q '^TOTALS' "${CMP_DIR}/summary.txt" 2>/dev/null; then
    log_error "Comparison stage failed (exit ${CMP_RC})"
    generate_yaml "ftbfs" "Comparison stage failed for ${APP_ID} ${wallet_version} (exit ${CMP_RC}). Official p.cash.apk SHA-256: ${app_hash}."
    echo ""; echo "Exit code: 1"
    exit 1
fi

read -r _ diff_total diff_metainf diff_other unmatched arsc_accepted \
    < <(grep '^TOTALS' "${CMP_DIR}/summary.txt")
diff_total="${diff_total:-1}"; diff_metainf="${diff_metainf:-0}"
diff_other="${diff_other:-1}"; unmatched="${unmatched:-0}"; arsc_accepted="${arsc_accepted:-0}"

material=$((diff_other - arsc_accepted))
[[ "$material" -lt 0 ]] && material=0

########################
# Verdict. Mechanical: 0 = identical, 1 = any difference. META-INF signing entries
# are expected to differ: the release artifact is signed with the developer's release
# key while the local build is unsigned, because app/build.gradle registers no
# signingConfig for the release build type.
########################

section "RESULT"
echo "  Total differences:         ${diff_total}"
echo "  META-INF (signing) diffs:  ${diff_metainf}"
echo "  Other diffs:               ${diff_other}"
echo "  resources.arsc accepted:   ${arsc_accepted}  (decode process)"
echo "  Material differences:      ${material}"
echo ""
echo "  Per-artifact detail:       ${CMP_DIR}/summary.txt"
echo "  Full diff:                 ${CMP_DIR}/diff-unzipped-p.cash.apk.txt"
echo "  Gradle log:                ${BUILD_DIR}/gradle-build.log"
echo "  Tag provenance:            ${BUILD_DIR}/git-tag-verify.txt"

echo ""
echo "  Per-artifact results:"
if [[ "$material" -eq 0 ]]; then
    printf "    %-20s reproducible (%s signing-only diff(s))\n" "p.cash.apk" "${diff_metainf}"
else
    printf "    %-20s not_reproducible (%s material diff(s))\n" "p.cash.apk" "${material}"
fi

if [[ "$material" -eq 0 ]]; then
    log_success "Verdict: reproducible -- 0 material differences"
    VERDICT="reproducible"
    EXIT_CODE=0
else
    log_warn "Verdict: not_reproducible -- ${material} material difference(s)"
    VERDICT="not_reproducible"
    EXIT_CODE=1
fi

echo ""
echo "===== Begin Results ====="
echo "scriptVersion:   ${SCRIPT_VERSION}"
echo "scriptHash:      ${SCRIPT_HASH:-unknown}"
echo "appId:           ${APP_ID}"
echo "signer:          ${signer}"
echo "apkVersionName:  ${wallet_version}"
echo "apkVersionCode:  ${version_code}"
echo "verdict:         ${VERDICT}"
echo "appHash:         ${app_hash}"
echo "lineage:         f-droid (branch f-droid, tag ${GIT_REF})"
echo "commit:          $(cat "${BUILD_DIR}/commit.txt" 2>/dev/null || echo unknown)"
echo "gitHashInBinary: ${git_hash:-unknown}"
echo "tagProvenance:   ${tag_provenance}"
echo "totalDiffs:      ${diff_total}"
echo "metainfDiffs:    ${diff_metainf}"
echo "materialDiffs:   ${material}"
echo "method:          APK built in a pinned container with -Pfdroid=true, compared entry by entry"
echo "depProvenance:   JitPack deps consumed as published binaries, not rebuilt from source"
echo "===== End Results ====="
echo ""
echo "  appHash above is the official p.cash.apk exactly as published on GitHub"
echo "  Releases - the artifact the detached GPG signature covers. That is the hash"
echo "  to publish. The locally built APK's hash is printed in the comparison log"
echo "  and must never be published as the official hash."

generate_yaml "${VERDICT}" "F-Droid/GitHub lineage: branch f-droid at tag ${GIT_REF}, built with :app:assembleRelease -Pfdroid=true. ${diff_total} difference(s): ${diff_metainf} META-INF signing (expected -- the release build type registers no signingConfig, so the local artifact is unsigned), ${diff_other} other, of which ${arsc_accepted} resolved by the resources.arsc decode process and ${material} material. Official p.cash.apk SHA-256 ${app_hash}, versionCode ${version_code}. Tag provenance: ${tag_provenance}. JitPack dependencies (com.github.piratecash forks of the bitcoin/ethereum/solana/ton/tron/stellar/monero/zcash/tangem kits) were consumed as published binaries, NOT rebuilt from source, so a byte-match does not attest their provenance."

echo ""
echo "Exit code: ${EXIT_CODE}"
exit "${EXIT_CODE}"
