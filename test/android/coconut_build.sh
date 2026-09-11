#!/bin/bash
# coconut_build.sh v0.1.16 — Coconut Wallet (onl.coconut.wallet) Android reproducible build
# verification
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-09-11
# Project: https://github.com/noncelab/coconut_wallet
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
# SCOPE: mainnet flavor only (onl.coconut.wallet); regtest is a separate Play listing, out of
# scope. Builds the AAB from source and compares a bundletool split set, split by split, against
# the official Play splits supplied via --binary/--apk. No upstream Android CI exists; the recipe
# is reconstructed from android/fastlane/Fastfile, Makefile and the release helper script.
#
# NOTE A: the three .env assets are recovered from the official APK (gitignored upstream).
# NOTE B: google-services.json is not reconstructed; REQUIRE_GOOGLE_SERVICES stays unset.
# NOTE C: the BitBox02 bridge is built from the non-upstream fork upstream's README requires.
# NOTE D: upstream's Makefile does not parse at v0.17.0; a whitespace-only repair is applied.
# The full design notes (SCOPE, STEPS, NOTE A-D) are kept in this script's changelog.
#
# Exit codes: 0 = reproducible, 1 = not_reproducible or ftbfs, 2 = invalid parameters.
set -euo pipefail

EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.1.16"
readonly SCRIPT_NAME="coconut_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256=""

readonly APP_ID="onl.coconut.wallet"
readonly REPO_URL="https://github.com/noncelab/coconut_wallet.git"
readonly BITBOX_FORK_URL="https://github.com/4xvgal/bitbox02-api-go.git"
readonly BITBOX_FORK_BRANCH="fix/nil-guard-psbt"

# Pinned tooling. bundletool 1.16.0 (what AGP 8.6.0's POM declares) was tried first and does NOT
# match Google Play's server-side split generator for this release: res/xml/splits0.xml used
# locale codes id/he where Play's has in/iw, and the split manifests differed in the
# requiredSplitTypes namespace and isSplitRequired. With 1.18.3, tested against the v0.17.0 AAB,
# splits0.xml is byte-identical and the only manifest differences left are Play's own additions
# (stamp meta-data, derived.apk.id, PairIP). apktool 3.0.3 is the current stable release at time
# of writing. Both hashes were computed from the actual downloaded release asset.
readonly BT_VER="1.18.3"
readonly BT_URL="https://github.com/google/bundletool/releases/download/${BT_VER}/bundletool-all-${BT_VER}.jar"
readonly BT_SHA="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
readonly AT_VER="3.0.3"
readonly AT_URL="https://github.com/iBotPeaches/Apktool/releases/download/v${AT_VER}/apktool_${AT_VER}.jar"
readonly AT_SHA="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
readonly GO_VER="1.26.0"
readonly GO_URL="https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
readonly GO_SHA="aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235"
readonly FLUTTER_TAG="3.29.1"
# NDK: android/app/build.gradle uses `ndkVersion flutter.ndkVersion`, which Flutter 3.29.1 defines as
# 26.3.11579264 (packages/flutter_tools/gradle/src/main/groovy/flutter.groovy at tag 3.29.1). AGP
# 8.6 needs exactly that revision present to strip the release jniLibs (llvm-strip); if it is
# missing it either auto-downloads it through sdkmanager at build time or packages the .so files
# unstripped, both of which are diff sources. One NDK in the image, used by both cargo ndk (Trezor
# bridge, via ANDROID_NDK_HOME) and AGP (app), removes that variable. Which NDK the vendor's macOS
# build used for the Trezor bridge is unknown.
readonly NDK_VER="26.3.11579264"

readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_INVALID=2

log()      { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_err()  { printf '[ERROR] %s\n' "$*" >&2; }
log_ok()   { printf '[OK] %s\n' "$*"; }
section()  { printf '\n== %s ==\n' "$1"; }

sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

# Print at most N lines. `head` makes the upstream writer see SIGPIPE, which under
# `set -o pipefail` can abort the run before a verdict is written — this drains the input instead.
cap() { awk -v n="${1:-5}" 'NR<=n{print} {last=NR} END{if(last>n) printf "    ... %d more line(s); full listing saved\n", last-n}'; }

# --- Self-identification (script-notes/script-version-and-hash.md). First action, before
# argument parsing, so even an invalid-argument run records which bytes ran. ---
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

# A previous run's verdict must never survive this invocation, including one that exits during
# argument validation or preflight.
rm -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml"

usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <dir-of-official-splits|base.apk> [--version <v>]
                      [--arch <a>] [--type <t>] [--commit <sha>]

  --binary   REQUIRED. Directory holding the official Play split APKs (base.apk plus
             split_config.*.apk), or the path to base.apk itself, whose siblings in
             the same directory then form the split set. Alias: --apk.
  --version  Optional. Logged and cross-checked; the authoritative versionName/Code
             come from base.apk / the tag's pubspec.yaml app_versions.aos_mainnet.
  --arch     Optional. Logged; the device spec's ABI comes from the official splits.
  --type     Optional. Logged, unused (mainnet flavor only — see header SCOPE).
  --commit   Optional. Build this revision instead of the derived release tag.

Requires: podman or docker. No smartphone, no adb, no sudo.
Exit codes: 0 = reproducible, 1 = not_reproducible / ftbfs, 2 = invalid parameters.
USAGE
}

write_yaml() {
    local verdict="$1" notes="$2"
    { printf 'script_version: %s\n' "$SCRIPT_VERSION"
      printf 'verdict: %s\n' "$verdict"
      if [[ -n "$notes" ]]; then
          printf 'notes: |\n'
          printf '%s\n' "$notes" | sed 's/^/  /'
      fi
    } > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    RESULT_DONE=true
    log "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

RESULT_DONE=false
WORK_DIR=""
CONTAINER_RUNTIME=""

# Leave nothing the invoking user cannot delete — the build server has no sudo
# (non-sudo-directories-guideline.md).
normalize_ownership() {
    [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${CONTAINER_RUNTIME}" ]] || return 0
    if [[ "${CONTAINER_RUNTIME}" == "podman" ]]; then
        # Inside "podman unshare" the caller IS uid 0; the caller's real uid maps to a subuid there,
        # so chown to $(id -u) would hand the tree to e.g. 166536 and the host could not delete it.
        # 0:0 in the namespace == the invoking user on the host (same form as bitbox02_build.sh).
        podman unshare chown -R 0:0 "${WORK_DIR}" 2>/dev/null \
            || log_warn "Could not normalize ownership under ${WORK_DIR}"
    else
        docker run --rm --user 0:0 -v "${WORK_DIR}:/work" debian:bookworm-slim \
            chown -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 \
            || log_warn "Could not normalize ownership under ${WORK_DIR}"
    fi
    if find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null | grep -q .; then
        log_warn "Files under ${WORK_DIR} are not owned by $(id -un); manual cleanup may need the container runtime."
    fi
}

cleanup() {
    local rc=$?
    normalize_ownership
    if [[ "$RESULT_DONE" == false && $rc -ne 0 && $rc -ne "$EXIT_INVALID" ]]; then
        write_yaml "ftbfs" "Run aborted unexpectedly with status ${rc} before a verdict was reached. See the terminal output for the failing step."
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

die_invalid() { log_err "$1"; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"; }
fail() { log_err "$2"; write_yaml "$1" "$2"; echo "Exit code: ${EXIT_FAILED}"; exit "${EXIT_FAILED}"; }

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------
binary_arg=""; version_arg=""; arch_arg=""; type_arg=""; commit_arg=""
need_arg() { [[ -n "${2:-}" && "${2:0:2}" != "--" ]] || die_invalid "Option $1 requires a value."; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary|--apk) need_arg "$1" "${2:-}"; binary_arg="$2"; shift 2 ;;
        --version)      need_arg "$1" "${2:-}"; version_arg="$2"; shift 2 ;;
        --arch)         need_arg "$1" "${2:-}"; arch_arg="$2"; shift 2 ;;
        --type)         need_arg "$1" "${2:-}"; type_arg="$2"; shift 2 ;;
        --commit)       need_arg "$1" "${2:-}"; commit_arg="$2"; shift 2 ;;
        --script-version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
        -h|--help)      usage; exit "${EXIT_SUCCESS}" ;;
        # Unknown parameters must never be fatal (luis-changes-2026-03-11 / -03-12).
        *)              log_warn "Ignoring unrecognised parameter: $1"; shift ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] && die_invalid "Refusing to run as root. Run as a normal user; no sudo is needed."
[[ -n "$binary_arg" ]] || { usage; die_invalid "--binary (alias --apk) is required — Play splits cannot be downloaded, they must be supplied."; }

OFFICIAL_DIR=""
if [[ -f "$binary_arg" ]]; then
    [[ "$(basename "$binary_arg")" == "base.apk" ]] \
        || die_invalid "A file argument must be base.apk (got $(basename "$binary_arg")). Play splits are only meaningful as a set; pass the directory instead."
    OFFICIAL_DIR="$(cd "$(dirname "$binary_arg")" && pwd)"
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

[[ -n "$arch_arg" ]] && log "--arch ${arch_arg} accepted; the device spec's ABI comes from the official split set"
[[ -n "$type_arg" ]] && log "--type ${type_arg} accepted but not used (mainnet flavor only)"

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
section "PRE-FLIGHT"
if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    die_invalid "Neither podman nor docker found. Install one of them (podman preferred)."
fi
log_ok "Using ${CONTAINER_RUNTIME} as container runtime"

RUN_ID="$(date +%s)-$$"
WORK_DIR="/tmp/test_${APP_ID}_${version_arg:-unset}_${RUN_ID}"
mkdir -p "${WORK_DIR}/official" "${WORK_DIR}/comparison" "${WORK_DIR}/tools"
readonly WORK_DIR
cp "${OFFICIAL_SPLITS[@]}" "${WORK_DIR}/official/"
log "Official splits staged: ${#OFFICIAL_SPLITS[@]} file(s) -> ${WORK_DIR}/official/"

cat <<BANNER

== COCONUT WALLET (${APP_ID}) — GOOGLE PLAY SPLIT VERIFICATION ==
 Script:    ${SCRIPT_NAME} ${SCRIPT_VERSION}
 Repo:      ${REPO_URL}
 Splits:    ${OFFICIAL_DIR}
 Workspace: ${WORK_DIR}
 Date:      $(date)
BANNER

# ------------------------------------------------------------------------------
# Pinned host-side tooling (bundletool, apktool) — fetched and hash-verified once
# on the host so the container build below does not need outbound trust beyond
# these two pins plus what the Dockerfile itself fetches (Flutter/Go/rustup/SDK,
# all likewise pinned by tag/version below).
# ------------------------------------------------------------------------------
section "SETUP: PINNED TOOLING"
fetch_pinned() {
    local url="$1" want="$2" dest="$3" got
    curl -fsSL "$url" -o "$dest" || fail "ftbfs" "Could not download $(basename "$dest") from ${url}."
    got="$(sha256_of "$dest")"
    [[ "$got" == "$want" ]] || fail "ftbfs" "$(basename "$dest") SHA-256 mismatch. Expected ${want}, got ${got}. Refusing to run an unverified tool."
    log_ok "$(basename "$dest") verified: ${want}"
}
fetch_pinned "$BT_URL" "$BT_SHA" "${WORK_DIR}/tools/bundletool.jar"
fetch_pinned "$AT_URL" "$AT_SHA" "${WORK_DIR}/tools/apktool.jar"

# ------------------------------------------------------------------------------
# Build the toolchain image. Everything below this point that touches the
# network, Flutter, Go, Rust, the Android SDK/NDK or Gradle runs inside it.
# ------------------------------------------------------------------------------
section "BUILD: TOOLCHAIN IMAGE"
DOCKERFILE="${WORK_DIR}/Dockerfile"
cat > "$DOCKERFILE" <<DOCKERFILE_EOF
FROM docker.io/debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
# Pin the locale for the WHOLE image. Two reasons, and the second is the important one:
#  1. JDK 17 predates JEP 400, so javac's default source charset follows the locale. bookworm-slim
#     sets no LANG (POSIX/C -> US-ASCII), and gomobile copies Go doc comments verbatim into the
#     Java it generates -- go/bridge.go:34 contains an em dash, so javac aborts with
#     "unmappable character (0xE2) for encoding US-ASCII". Upstream's source is valid UTF-8; a
#     normal dev machine has a UTF-8 locale and never sees this. The gap is ours, not theirs.
#  2. Locale is a build-determinism input in its own right -- it can change sort order, date and
#     number formatting, and text processing anywhere in the pipeline. A reproducible-build
#     verifier should fix it explicitly for the entire image rather than inherit whatever the base
#     image happens to default to. C.UTF-8 is built into glibc on bookworm; no locales package.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN set -ex; apt-get update; apt-get install -y --no-install-recommends \\
      curl git unzip xz-utils ca-certificates openjdk-17-jdk-headless \\
      build-essential clang cmake ninja-build pkg-config protobuf-compiler \\
      python3 file rsync libglu1-mesa libdbus-1-dev; \\
    rm -rf /var/lib/apt/lists/*
# libdbus-1-dev is a HOST-side build dependency only: rust/trezor-bridge pulls trezor-connect-rs
# with the "bluetooth" feature, whose Linux BLE backend goes through BlueZ over D-Bus, so
# libdbus-sys is compiled for x86_64-unknown-linux-gnu while cross-compiling the Android targets.
# It does not enter any Android .so. Upstream builds on macOS, where BLE resolves to CoreBluetooth
# instead, which is why their own builds never need it.
# Android cmdline-tools + SDK components pinned to what android/app/build.gradle and
# android/settings.gradle declare (compileSdk/targetSdk 36, AGP 8.6.0's toolchain).
# ANDROID_HOME as well as ANDROID_SDK_ROOT: gomobile reads the older ANDROID_HOME name and, when it
# is unset, falls back to \$HOME/Android/Sdk, which is not where this image puts the SDK. Flutter
# likewise falls back to these env vars when its own "flutter config --android-sdk" setting (written
# under the build user's \$HOME) is not visible. Pinning both names in the image makes every consumer
# find the SDK regardless of which user or HOME the container runs with. (First hit while the
# container still ran non-root; kept because it is correct either way.)
ENV ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk
RUN set -ex; mkdir -p \$ANDROID_SDK_ROOT/cmdline-tools; \\
    curl -fsSL -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip; \\
    unzip -q /tmp/cmdline-tools.zip -d \$ANDROID_SDK_ROOT/cmdline-tools; \\
    mv \$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools \$ANDROID_SDK_ROOT/cmdline-tools/latest; \\
    rm /tmp/cmdline-tools.zip
# /root/go/bin is where the "go install" step below puts the gomobile binary (default
# GOPATH=\$HOME/go, GOBIN unset) -- without it on PATH, the "gomobile init" a few steps down
# no-ops and the driver's "make gomobile-android" would fail outright at runtime.
# NOTE: this heredoc is unquoted, so no backticks in these comments --
# bash would run them as command substitution on the host while writing the Dockerfile.
ENV PATH=\$PATH:\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/build-tools/36.0.0:/usr/local/go/bin:/root/go/bin:/root/.cargo/bin
RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true; \\
    sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;${NDK_VER}" >/dev/null
ENV ANDROID_NDK_HOME=\$ANDROID_SDK_ROOT/ndk/${NDK_VER}
# tar restores the stored owner when it runs as root, and rootless podman only maps 65536 uids into
# the container, so extracting a tarball whose entries carry a large uid fails with "Cannot change
# ownership to uid 397546: Invalid argument" even as container root. Flutter's gradle-wrapper.tgz
# is exactly that (entries owned by jakobr/eng = 397546:5000). GNU tar reads TAR_OPTIONS from the
# environment, so this applies to every tar the toolchain runs, at image build and at run time.
ENV TAR_OPTIONS=--no-same-owner
# Flutter, pinned to the exact tag .fvmrc declares — no FVM wrapper needed, this IS 3.29.1.
ENV PATH=\$PATH:/opt/flutter/bin
# Clone, configure, precache and open permissions in ONE layer. Two problems, both from the image
# building as root while the container runs as the invoking user:
#  - git refuses to operate on a repo owned by another user ("detected dubious ownership"), and
#    flutter shells out to git constantly. safe.directory is set --system (/etc/gitconfig) so every
#    UID picks it up; --global would land in /root/.gitconfig, which is not read when the container
#    runs as anyone but root.
#  - flutter takes a write lock on bin/cache/lockfile for every command and updates artifacts
#    under bin/cache, so FLUTTER_ROOT has to be writable by that user. chmod, not chown: the
#    runtime UID is not known at image-build time.
# Deliberately one RUN: a later "chmod -R" would force an overlayfs copy-up of the entire SDK into
# a new layer, roughly doubling image size.
RUN set -ex; git clone --branch ${FLUTTER_TAG} --depth 1 https://github.com/flutter/flutter.git /opt/flutter; \\
    git config --system --add safe.directory /opt/flutter; \\
    flutter config --no-analytics --android-sdk \$ANDROID_SDK_ROOT >/dev/null; \\
    flutter precache --android >/dev/null 2>&1 || true; \\
    chmod -R a+rwX /opt/flutter
# Go, pinned to what go/go.mod declares (go 1.26), verified by upstream's own published checksum.
RUN set -ex; curl -fsSL -o /tmp/go.tgz ${GO_URL}; \\
    echo "${GO_SHA}  /tmp/go.tgz" | sha256sum -c -; \\
    tar -C /usr/local -xzf /tmp/go.tgz; rm /tmp/go.tgz
# "gomobile init" stays non-fatal (modern gomobile bind provisions its own toolchain), but its
# failure is now printed instead of swallowed -- a bare "|| true" hid whether it had EVER run.
RUN go install golang.org/x/mobile/cmd/gomobile@latest; \\
    gomobile init || echo "WARNING: gomobile init failed (non-fatal, continuing)"
# Rust stable + cargo-ndk + the three Android targets rust/trezor-bridge/scripts/build_android.sh
# installs itself (repeated here so the image has them pre-warmed).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \\
    . /root/.cargo/env; \\
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; \\
    cargo install cargo-ndk
# rustup-init installs under root's \$HOME (/root), which the base image leaves at mode 0700 --
# unreadable to the non-root UID this image runs as at runtime (--userns=keep-id / --user).
# CARGO_HOME/RUSTUP_HOME also default to \$HOME, so pinning them explicitly keeps the rustup shims
# pointing at the toolchain this image actually installed no matter which user or HOME the container
# runs with. Same class of bug as the /build permission fix above.
ENV CARGO_HOME=/root/.cargo RUSTUP_HOME=/root/.rustup
RUN chmod 755 /root
COPY bundletool.jar /opt/bundletool.jar
COPY apktool.jar /opt/apktool.jar
RUN printf '#!/bin/sh\nexec java -jar /opt/bundletool.jar "\$@"\n' > /usr/local/bin/bundletool && chmod +x /usr/local/bin/bundletool; \\
    printf '#!/bin/sh\nexec java -jar /opt/apktool.jar "\$@"\n' > /usr/local/bin/apktool && chmod +x /usr/local/bin/apktool
WORKDIR /build
# Built as root; the container actually runs as the invoking host user via --userns=keep-id
# (podman) / --user (docker), which varies per caller and isn't known at image-build time. A
# root-owned 0755 /build would refuse that user's writes (git clone's internal mkdir for the
# worktree included) -- open it up the same way /tmp is.
RUN chmod 1777 /build
DOCKERFILE_EOF
cp "${WORK_DIR}/tools/bundletool.jar" "${WORK_DIR}/tools/apktool.jar" "${WORK_DIR}/"
IMAGE_NAME="coconut-verify-$(sha256_of "$DOCKERFILE" | cut -c1-12)"
( cd "${WORK_DIR}" && "$CONTAINER_RUNTIME" build -t "$IMAGE_NAME" -f Dockerfile . ) \
    || fail "ftbfs" "Toolchain image build failed. See terminal output above."
log_ok "Image built: ${IMAGE_NAME}"

# ------------------------------------------------------------------------------
# In-container build + comparison driver. One script so the entire clone,
# native-bridge build, app build, split generation and diff run under a single
# `podman run`, writing all results back into the mounted /work.
# ------------------------------------------------------------------------------
DRIVER="${WORK_DIR}/driver.sh"
cat > "$DRIVER" <<'DRIVER_EOF'
#!/bin/bash
set -euo pipefail
APP_ID="onl.coconut.wallet"
REPO_URL="https://github.com/noncelab/coconut_wallet.git"
BITBOX_FORK_URL="https://github.com/4xvgal/bitbox02-api-go.git"
BITBOX_FORK_BRANCH="fix/nil-guard-psbt"
cd /work

echo "== PHASE 0: OFFICIAL METADATA =="
apktool d -f -s --frame-path /tmp/apktool-frame -o /work/comparison/meta /work/official/base.apk >/dev/null
pkg="$(grep -o 'package="[^"]*"' /work/comparison/meta/AndroidManifest.xml | head -1 | cut -d'"' -f2)"
[[ "$pkg" == "$APP_ID" ]] || { echo "PACKAGE MISMATCH: expected ${APP_ID}, got ${pkg}" >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }
yml() { sed -n "s/^[[:space:]]*$1:[[:space:]]*'\{0,1\}\([^']*\)'\{0,1\}[[:space:]]*\$/\1/p" /work/comparison/meta/apktool.yml | head -1; }
VERSION_NAME="$(yml versionName)"
VERSION_CODE="$(yml versionCode)"
TARGET_SDK="$(yml targetSdkVersion)"
echo "package=${pkg} versionName=${VERSION_NAME} versionCode=${VERSION_CODE} targetSdk=${TARGET_SDK}"
printf '%s\n' "$VERSION_NAME" > /work/version_name.txt
printf '%s\n' "$VERSION_CODE" > /work/version_code.txt
apksigner verify --print-certs /work/official/base.apk 2>/dev/null | grep -m1 'SHA-256' | awk '{print $NF}' > /work/signer.txt || true
[[ -s /work/signer.txt ]] || echo "unknown" > /work/signer.txt

echo "== PHASE 1: CLONE AT TAG v${VERSION_NAME} =="
git clone --quiet "$REPO_URL" /build/coconut_wallet
cd /build/coconut_wallet
TAG="v${VERSION_NAME}"
if ! git checkout --quiet "$TAG" 2>/dev/null; then
    echo "Tag ${TAG} not found; falling back to matching pubspec app_versions.aos_mainnet on develop tip." >&2
    echo "ftbfs" > /work/verdict.txt
    exit 1
fi
COMMIT_HASH="$(git rev-parse HEAD)"
echo "$COMMIT_HASH" > /work/commit.txt
pubcode="$(sed -n 's/^[[:space:]]*aos_mainnet:[[:space:]]*[0-9.]*+\([0-9]*\)[[:space:]]*$/\1/p' pubspec.yaml | head -1)"
if [[ -n "$pubcode" && "$pubcode" != "$VERSION_CODE" ]]; then
    echo "WARNING: tag ${TAG} pubspec app_versions.aos_mainnet build number (${pubcode}) does not match official APK versionCode (${VERSION_CODE})." >&2
fi

echo "== PHASE 2: BITBOX02 BRIDGE FORK (non-upstream, see script NOTE C) =="
git clone --quiet --branch "$BITBOX_FORK_BRANCH" "$BITBOX_FORK_URL" /build/bitbox02-api-go
git -C /build/bitbox02-api-go rev-parse HEAD > /work/bitbox_fork_commit.txt
echo "bitbox02-api-go fork resolved to commit: $(cat /work/bitbox_fork_commit.txt)"

echo "== PHASE 3: RECOVER .env ASSETS FROM THE OFFICIAL APK (script NOTE A) =="
for f in mainnet.env regtest.env testnet.env; do
    unzip -p /work/official/base.apk "assets/flutter_assets/${f}" > "/build/coconut_wallet/${f}" \
        || { echo "Could not extract ${f} from the official APK's Flutter assets." >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }
done
echo "Recovered: mainnet.env regtest.env testnet.env"

echo "== PHASE 4: NATIVE BRIDGES FROM SOURCE (policy: no vendored first-party blobs) =="
. /root/.cargo/env
# cargo must WRITE its registry (the Trezor bridge pulls ~241 crates). The image's
# (Retained from the non-root run model, where CARGO_HOME=/root/.cargo was readable but not
# writable. Harmless now that the container runs as root, and keeps the docker path safe.)
# CARGO_HOME=/root/.cargo is readable to a non-root runtime user but not writable -- the earlier
# fix made /root traversable, not writable. Move only the MUTABLE part: the cargo/rustc/cargo-ndk
# binaries are still found via PATH (/root/.cargo/bin) and the toolchains via RUSTUP_HOME
# (/root/.rustup), for which read access is enough. Per-run and container-local by design, so no
# build state survives between runs -- the right default for a reproducibility verifier.
export CARGO_HOME=/tmp/cargo-home
mkdir -p "$CARGO_HOME"
cd /build/coconut_wallet/go && go mod tidy
cd /build/coconut_wallet

# Upstream Makefile does not parse -- see NOTE D. GNU make reads the whole file before running any
# target, so one space-indented recipe line breaks EVERY target, including the gomobile-android and
# trezor-android ones upstream's own README instructs you to run. Repair make SYNTAX only
# (leading spaces -> TAB on recipe lines); never touch a recipe's command text. The full before/after
# diff is printed here and saved to makefile-repair.diff so a reader can audit exactly what changed.
echo "0" > /work/makefile_repaired.txt
if ! make -n gomobile-android >/dev/null 2>&1; then
    echo "Upstream Makefile does not parse. Applying whitespace-only make-syntax repair (NOTE D)."
    cp Makefile /work/Makefile.upstream-original
    sed -i -E 's/^ {2,}([^ ])/\t\1/' Makefile
    diff -u /work/Makefile.upstream-original Makefile > /work/makefile-repair.diff || true
    echo "--- make-syntax repair diff (saved to makefile-repair.diff) ---"
    cat /work/makefile-repair.diff
    echo "--- end repair diff ---"
    make -n gomobile-android >/dev/null 2>&1 || {
        echo "Makefile still does not parse after the whitespace repair -- not proceeding." >&2
        echo "ftbfs" > /work/verdict.txt; exit 1; }
    echo "1" > /work/makefile_repaired.txt
    echo "Repair applied. Only leading whitespace changed; no recipe command text was modified."
fi

make gomobile-android
make trezor-android

echo "== PHASE 5: THROWAWAY RELEASE KEYSTORE =="
mkdir -p /build/coconut_wallet/android
keytool -genkey -v -keystore /build/coconut_wallet/android/app/ws-throwaway.jks \
    -storepass wschangeme -alias wsthrow -keypass wschangeme \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=WalletScrutiny Verification,O=WalletScrutiny,C=US" >/dev/null
cat > /build/coconut_wallet/android/key_mainnet.properties <<KEYPROPS
keyAlias=wsthrow
storeFile=../app/ws-throwaway.jks
KEYPROPS
export ANDROID_SIGNING_STORE_PASSWORD=wschangeme
export ANDROID_SIGNING_KEY_PASSWORD=wschangeme
echo "Throwaway keystore generated. Root META-INF signing-file differences against the official"
echo "(Play App Signing re-signed) artifact are EXPECTED and are the standard root-filename"
echo "exclusion (meta-inf-filter-scope.md), not a fabricated signature match."

echo "== PHASE 6: fvm flutter build appbundle (REQUIRE_GOOGLE_SERVICES intentionally unset -- NOTE B) =="
cd /build/coconut_wallet
flutter pub get 2>&1 | tee /work/pub-get.log
# pubspec.lock is gitignored upstream (.gitignore: "*.lock", no exception), so pub get resolves the
# dependency graph afresh at build time. Keep the resolved lockfile with the run for the record.
cp pubspec.lock /work/pubspec.lock.resolved
# Generated Dart is gitignored upstream too (*.g.dart, *.realm.dart, and slang's
# lib/localization/strings.g.dart, imported by 150+ files). README "Code generation" / Makefile
# "ready" target: build_runner, realm generate, slang -- run here in that order, without the fvm
# prefix (the image's flutter IS 3.29.1). The Fastlane lane does not run this; developers do.
{ dart run build_runner clean \
    && dart run build_runner build --delete-conflicting-outputs \
    && dart run realm generate \
    && dart run slang; } 2>&1 | tee /work/codegen.log \
    || { echo "Dart code generation failed (build_runner / realm / slang)." >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }
flutter build appbundle --flavor mainnet --release \
    --dart-define=USE_FIREBASE=true \
    --build-name="${VERSION_NAME}" --build-number="${VERSION_CODE}" \
    2>&1 | tee /work/build.log || { echo "ftbfs" > /work/verdict.txt; exit 1; }
AAB="$(find build/app/outputs/bundle/mainnetRelease -name '*.aab' | head -1)"
[[ -n "$AAB" ]] || { echo "No AAB produced." >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }
sha256sum "$AAB" | awk '{print $1}' > /work/aab_hash.txt
# Keep the bundle itself: /build dies with the container, and a follow-up bundletool run or a
# diffoscope against it needs the artifact, not just its hash.
cp "$AAB" /work/app-mainnet-release.aab

echo "== PHASE 7: DEVICE SPEC FROM THE OFFICIAL SPLITS =="
# Every dimension comes from the official split names, so bundletool selects the SAME splits Play
# did: ABI from split_config.<abi>, density from split_config.<bucket> (a hardcoded 280 dpi would
# make bundletool pick a different density split than the official xxhdpi one and both sides would
# show as UNMATCHED), locales from whatever is left (split_config.en -> "en").
abis=""; locales=""; density=""
for f in /work/official/split_config.*.apk; do
    base="$(basename "$f" .apk)"; tag="${base#split_config.}"
    case "$tag" in
        # bundletool's device spec takes Android ABI names (arm64-v8a), not the ARM64_V8A enum style:
        # with the latter it rejects the bundle as "doesn't support ABI architectures of the device".
        arm64_v8a) abis="${abis:+$abis,}\"arm64-v8a\"" ;;
        armeabi_v7a) abis="${abis:+$abis,}\"armeabi-v7a\"" ;;
        x86_64) abis="${abis:+$abis,}\"x86_64\"" ;;
        x86) abis="${abis:+$abis,}\"x86\"" ;;
        ldpi) density=120 ;; mdpi) density=160 ;; tvdpi) density=213 ;; hdpi) density=240 ;;
        xhdpi) density=320 ;; xxhdpi) density=480 ;; xxxhdpi) density=640 ;;
        *) locales="${locales:+$locales,}\"${tag//_/-}\"" ;;
    esac
done
[[ -n "$abis" ]] || abis='"arm64-v8a"'
[[ -n "$locales" ]] || locales='"en"'
[[ -n "$density" ]] || density=480
cat > /work/device-spec.json <<SPEC
{"supportedAbis":[${abis}],"supportedLocales":[${locales}],"screenDensity":${density},"sdkVersion":${TARGET_SDK:-36}}
SPEC
echo "device-spec.json: $(cat /work/device-spec.json)"

echo "== PHASE 8: BUNDLETOOL build-apks =="
bundletool build-apks --bundle="$AAB" --output-format=DIRECTORY --output=/work/built-apks \
    --ks=/build/coconut_wallet/android/app/ws-throwaway.jks --ks-pass=pass:wschangeme \
    --ks-key-alias=wsthrow --key-pass=pass:wschangeme \
    --device-spec=/work/device-spec.json
# bundletool names its module-relative splits base-master.apk / base-<dimension>.apk; Google Play
# names the same artifacts base.apk / split_config.<dimension>.apk. Rename onto Play's convention
# so the two sides key-match below (same mapping bitbanana_build.sh uses).
mkdir -p /work/built-renamed
for f in /work/built-apks/splits/*.apk; do
    bn="$(basename "$f")"
    case "$bn" in
        base-master.apk) n="base.apk" ;;
        base-*.apk)      n="split_config.${bn#base-}" ;;
        *)               n="$bn" ;;
    esac
    cp "$f" "/work/built-renamed/${n}"
done

echo "== PHASE 9: PER-SPLIT COMPARISON =="
declare -A OFF BLT
for f in /work/official/*.apk; do
    n="$(basename "$f" .apk)"; OFF["$n"]="$f"
done
for f in /work/built-renamed/*.apk; do
    n="$(basename "$f" .apk)"; BLT["$n"]="$f"
done
RAW_TOTAL=0; UNACC_TOTAL=0; MISSING_TOTAL=0
: > /work/comparison/summary.txt
for cfg in $(printf '%s\n' "${!OFF[@]}" "${!BLT[@]}" | sort -u); do
    o="${OFF[$cfg]:-}"; b="${BLT[$cfg]:-}"
    echo "---- split: ${cfg} ----"
    if [[ -z "$o" || -z "$b" ]]; then
        echo "UNMATCHED official=$([[ -n $o ]] && echo yes || echo no) built=$([[ -n $b ]] && echo yes || echo no)"
        echo "${cfg} UNMATCHED" >> /work/comparison/summary.txt
        MISSING_TOTAL=$((MISSING_TOTAL + 1)); continue
    fi
    # Unzipped into /work (bind-mounted), not /tmp, so they survive the container exiting and a
    # human can run a follow-up diff/meld/diffoscope against them (report-generation-guidelines).
    od="/work/unzipped/official/${cfg}"; bd="/work/unzipped/built/${cfg}"
    rm -rf "$od" "$bd"; mkdir -p "$od" "$bd"
    unzip -q -o "$o" -d "$od"; unzip -q -o "$b" -d "$bd"
    raw="$(diff -rq "$od" "$bd" || true)"
    printf '%s\n' "$raw" > "/work/comparison/diff-unzipped-${cfg}.txt"
    n="$(printf '%s\n' "$raw" | grep -vc '^$' || true)"
    echo "raw diffs: ${n} (full: comparison/diff-unzipped-${cfg}.txt)"

    # Sanctioned exclusion 1: root META-INF signing filenames ONLY, matched by name, never by
    # directory prefix (meta-inf-filter-scope.md). Everything else under META-INF counts.
    sign_re="^(Only in ${od}/META-INF: (MANIFEST\.MF|[A-Z0-9]+\.(SF|RSA|DSA|EC))\$|Files ${od}/META-INF/(MANIFEST\.MF|[A-Z0-9]+\.(SF|RSA|DSA|EC)) and ${bd}/META-INF/(MANIFEST\.MF|[A-Z0-9]+\.(SF|RSA|DSA|EC)) differ)\$"
    sign_lines="$(printf '%s\n' "$raw" | grep -E "$sign_re" || true)"
    c_sign="$(printf '%s\n' "$sign_lines" | grep -vc '^$' || true)"
    c_arsc="$(printf '%s\n' "$raw" | grep -Fxc "Files ${od}/resources.arsc and ${bd}/resources.arsc differ" || true)"
    a_arsc=0
    if [[ "$c_arsc" -eq 1 ]]; then
        # Sanctioned exclusion 2: resources.arsc decode-compare (review-notes/resources.arsc.md).
        rm -rf /tmp/arsc_o /tmp/arsc_b
        if apktool d -f --no-src --no-debug-info --frame-path /tmp/apktool-frame -o /tmp/arsc_o "$o" >/dev/null 2>&1 \
            && apktool d -f --no-src --no-debug-info --frame-path /tmp/apktool-frame -o /tmp/arsc_b "$b" >/dev/null 2>&1; then
            arsc_diff="$(diff -r /tmp/arsc_o/res /tmp/arsc_b/res 2>&1 || true)"
            printf '%s\n' "$arsc_diff" > "/work/comparison/diff_resources_decoded_${cfg}.txt"
            residual="$(printf '%s\n' "$arsc_diff" | grep -E '^[<>]' | grep -v 'com\.google\.firebase\.crashlytics\.mapping_file_id' || true)"
            if [[ -z "$(printf '%s' "$residual" | tr -d '[:space:]')" ]]; then
                a_arsc=1
                echo "resources.arsc: decoded res/ tree identical (or only mapping_file_id differs) -- non-semantic, excluded"
            else
                echo "resources.arsc: decoded res/ DIFFERS -- genuine, NOT excluded (see diff_resources_decoded_${cfg}.txt)"
            fi
        else
            echo "resources.arsc: apktool decode failed -- treated as a real difference, NOT excluded"
        fi
    fi
    acc=$((c_sign + a_arsc))
    [[ "$acc" -le "$n" ]] || { echo "Internal accounting error on split ${cfg}." >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }
    un=$((n - acc))
    echo "accepted: ${acc} (signing-filename ${c_sign}, resources.arsc ${a_arsc}) | unaccounted: ${un}"
    [[ "$un" -gt 0 ]] && printf '%s\n' "$raw" | grep -v '^$'
    echo "${cfg} raw=${n} accepted=${acc} unaccounted=${un}" >> /work/comparison/summary.txt
    RAW_TOTAL=$((RAW_TOTAL + n)); UNACC_TOTAL=$((UNACC_TOTAL + un))
done

if [[ "$UNACC_TOTAL" -eq 0 && "$MISSING_TOTAL" -eq 0 && ${#OFF[@]} -gt 0 ]]; then
    echo "reproducible" > /work/verdict.txt
else
    echo "not_reproducible" > /work/verdict.txt
fi
echo "$RAW_TOTAL" > /work/raw_total.txt
echo "$UNACC_TOTAL" > /work/unacc_total.txt
echo "$MISSING_TOTAL" > /work/missing_total.txt
DRIVER_EOF
chmod +x "$DRIVER"

# ------------------------------------------------------------------------------
# Run it. Everything the container writes lands under WORK_DIR via the bind mount.
# ------------------------------------------------------------------------------
section "BUILD + COMPARE"
# Run as root INSIDE the container. This is the fix for a whole recurring class of failures, not a
# shortcut: the image is necessarily built as root, so every path in it (/opt/flutter, /root/.cargo,
# /root/go, the Android SDK) is root-owned. A non-root runtime user could be granted write access by
# chmod, but NOT ownership -- and several steps need ownership specifically. tar restoring mtime and
# mode while unpacking Flutter's gradle-wrapper artifact is the case that forced this: utime() and
# chmod() on a directory require being its owner (or CAP_FOWNER); no amount of a+rwX helps.
#
# This does NOT leave root-owned droppings on the host:
#   - rootless podman (what the build server uses): container UID 0 maps to the INVOKING user's UID
#     on the host, so everything written through the /work bind mount is already owned correctly.
#   - docker (rootful fallback): output would be real-root owned, which the cleanup path already
#     handles -- normalize_ownership() chowns WORK_DIR back to the caller from the EXIT trap, on
#     failure paths too (non-sudo-directories-guideline.md).
# HOME is left at the image default (/root) rather than forced to /tmp, so the toolchain state the
# image installed under /root -- cargo, rustup, the flutter --no-analytics config -- is actually
# found at runtime instead of being invisible.
# The earlier defensive fixes (chmod 1777 /build, chmod 755 /root, chmod -R a+rwX /opt/flutter,
# CARGO_HOME relocation, git safe.directory) are deliberately RETAINED: they are harmless here and
# keep the docker path and any future non-root run model working.
RUN_USER_ARGS="--user 0:0"
"$CONTAINER_RUNTIME" run --rm ${RUN_USER_ARGS} --volume "${WORK_DIR}:/work" "$IMAGE_NAME" \
    bash /work/driver.sh 2>&1 | tee "${WORK_DIR}/container-run.log" \
    || true   # verdict/exit handling below reads /work/verdict.txt regardless of container rc

VERDICT="$(cat "${WORK_DIR}/verdict.txt" 2>/dev/null || echo ftbfs)"
VERSION_NAME="$(cat "${WORK_DIR}/version_name.txt" 2>/dev/null || echo "$version_arg")"
VERSION_CODE="$(cat "${WORK_DIR}/version_code.txt" 2>/dev/null || echo unknown)"
COMMIT_HASH="$(cat "${WORK_DIR}/commit.txt" 2>/dev/null || echo unknown)"
APP_HASH="$(sha256_of "$OFFICIAL_BASE")"
RAW_TOTAL="$(cat "${WORK_DIR}/raw_total.txt" 2>/dev/null || echo 0)"
UNACC_TOTAL="$(cat "${WORK_DIR}/unacc_total.txt" 2>/dev/null || echo 0)"
MISSING_TOTAL="$(cat "${WORK_DIR}/missing_total.txt" 2>/dev/null || echo 0)"
BITBOX_FORK_COMMIT="$(cat "${WORK_DIR}/bitbox_fork_commit.txt" 2>/dev/null || echo unknown)"
MAKEFILE_REPAIRED="$(cat "${WORK_DIR}/makefile_repaired.txt" 2>/dev/null || echo unknown)"
case "$MAKEFILE_REPAIRED" in
    1) MAKEFILE_NOTE="YES -- upstream Makefile did not parse; whitespace-only make-syntax repair applied (NOTE D). Diff: makefile-repair.diff in the workspace." ;;
    0) MAKEFILE_NOTE="no -- upstream Makefile parsed as-is (upstream may have fixed it; re-check NOTE D)" ;;
    *) MAKEFILE_NOTE="unknown -- run did not reach the Makefile check" ;;
esac
SIGNER="$(cat "${WORK_DIR}/signer.txt" 2>/dev/null || echo unknown)"

section "RESULT"
echo "Official splits: ${#OFFICIAL_SPLITS[@]}   Raw diffs: ${RAW_TOTAL}   Unaccounted: ${UNACC_TOTAL}   Unmatched: ${MISSING_TOTAL}"
echo "Per-split detail: ${WORK_DIR}/comparison/summary.txt"
echo "Raw diffs:        ${WORK_DIR}/comparison/diff-unzipped-<split>.txt"
echo "Build log:        ${WORK_DIR}/build.log"

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
if [[ "$RAW_TOTAL" -eq 0 ]]; then
    echo "(no differing entries)"
else
    cat "${WORK_DIR}/comparison"/diff-unzipped-*.txt 2>/dev/null | grep -v '^$' | cap 5
fi
echo ""
echo "Revision, tag (and its signature):"
echo "Tag: v${VERSION_NAME}  Built from commit: ${COMMIT_HASH}"
echo "(No CI workflow builds this artifact upstream; the recipe was reverse-engineered from"
echo " android/fastlane/Fastfile. Tag signature verification not performed by this draft.)"
echo ""
echo "===== Also ====="
echo "channel:        google-play (split set, mainnet flavor)"
echo "appHashMeaning: base.apk exactly as supplied; not an aggregate of the split set"
echo "buildEnv:       podman image with Flutter ${FLUTTER_TAG}, Go ${GO_VER}, Rust stable + cargo-ndk, JDK 17, Android SDK 36 / NDK ${NDK_VER}"
echo "buildCmd:       flutter build appbundle --flavor mainnet --release --dart-define=USE_FIREBASE=true --build-name=<versionName> --build-number=<versionCode>"
echo "bundletool:     ${BT_VER} (reproduces Play's splits0.xml and split manifest attributes for this release; AGP 8.6.0 itself declares 1.16.0), sha256 ${BT_SHA}"
echo "lockfile:       pubspec.lock is gitignored upstream; dependencies resolved at build time (saved as pubspec.lock.resolved in the workspace)"
echo "envRecovery:    mainnet.env/regtest.env/testnet.env extracted from the official APK's Flutter assets (script NOTE A) -- review before trusting"
echo "googleServices: REQUIRE_GOOGLE_SERVICES intentionally NOT set; official build sets it (script NOTE B) -- UNRESOLVED divergence"
echo "makefileRepair: ${MAKEFILE_NOTE}"
echo "bitboxForkRepo: ${BITBOX_FORK_URL} @ ${BITBOX_FORK_BRANCH} (non-upstream, mutable ref -- script NOTE C)"
echo "bitboxForkSha:  ${BITBOX_FORK_COMMIT}"
echo "signingNote:    built splits are signed with a throwaway WalletScrutiny keystore generated at run time; the official splits carry Google Play App Signing's certificate. Root META-INF signing FILENAMES (MANIFEST.MF/*.SF/*.RSA/*.DSA/*.EC) are excluded per meta-inf-filter-scope.md; all other META-INF entries are counted."
echo "rawDiffs:       ${RAW_TOTAL}"
echo "unaccounted:    ${UNACC_TOTAL}"
echo "unmatched:      ${MISSING_TOTAL}"
echo "workspacePath:  ${WORK_DIR}"
echo "===== End Results ====="
echo ""
echo "Run a full"
echo "diff --recursive ${WORK_DIR}/unzipped/official/<split> ${WORK_DIR}/unzipped/built/<split>"
echo "or diffoscope \"${OFFICIAL_BASE}\" ${WORK_DIR}/built-renamed/base.apk"
echo "for more details."

NOTES="Coconut Wallet ${APP_ID} v${VERSION_NAME} (commit ${COMMIT_HASH}), Google Play split set built with the project's own Fastlane recipe reverse-engineered from android/fastlane/Fastfile (no upstream CI builds this artifact). ${RAW_TOTAL} raw difference(s) across splits; excluded only root META-INF signing filenames and a resources.arsc decode match (review-notes/resources.arsc.md) -- both sanctioned, evidence-backed exceptions, not general acceptable-diff filtering. ${UNACC_TOTAL} unaccounted difference(s) -- the verdict is judged on this alone. ${MISSING_TOTAL} split(s) unmatched. Known open items, NOT resolved by this script: (1) mainnet/regtest/testnet .env recovered from the official APK's bundled Flutter assets rather than from upstream (gitignored, obtainable only by emailing the vendor) -- review this design decision; (2) built WITHOUT REQUIRE_GOOGLE_SERVICES=true because google-services.json is unobtainable and unlike the .env files is not bundled into the APK, while the official mainnet build sets it -- any Firebase/google-services-shaped diff should be attributed to this; (3a) upstream's Makefile does not parse at this tag (line 23 space-indented instead of TAB, broken since 2025-10-08 commit 5579122b), which breaks every make target including the gomobile/trezor bridge targets its own README tells you to run; this run applied a whitespace-only make-syntax repair -- ${MAKEFILE_NOTE}; (3) the BitBox02 bridge is built against a non-upstream fork (${BITBOX_FORK_URL} @ ${BITBOX_FORK_BRANCH}, commit ${BITBOX_FORK_COMMIT}) the README requires in place of upstream BitBoxSwiss; (4) the NDK revision used to compile the Trezor bridge (${NDK_VER}) is pinned by this script, not confirmed against Flutter ${FLUTTER_TAG}'s own default. Official base.apk SHA-256 ${APP_HASH}."
write_yaml "$VERDICT" "$NOTES"

if [[ "$VERDICT" == "reproducible" ]]; then
    log_ok "Verdict: reproducible -- every split has zero unaccounted differences"
    echo "Exit code: ${EXIT_SUCCESS}"
    exit "${EXIT_SUCCESS}"
fi
log_warn "Verdict: ${VERDICT} -- ${UNACC_TOTAL} unaccounted difference(s), ${MISSING_TOTAL} unmatched split(s)"
echo "Exit code: ${EXIT_FAILED}"
exit "${EXIT_FAILED}"
