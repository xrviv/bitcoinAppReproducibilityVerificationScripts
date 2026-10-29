#!/bin/bash
# coconut-v0.1.20_build.sh — Coconut Wallet (onl.coconut.wallet) Android reproducible build verification
# Version: v0.1.20
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-10-29
# Project: https://github.com/noncelab/coconut_wallet
# Disclaimer: for reproducible-build verification and research only. No warranty; users assume all risk and are responsible for legal compliance; the developers assume no liability for misuse.
# Steps: build the mainnet AAB from the tag in podman (Fastlane recipe), derive bundletool splits for the official device spec, compare split by split with the official Play splits (--binary/--apk).
# Notes A-D (.env from the official APK, no google-services, BitBox02 fork, Makefile repair) and all design notes: script-notes/android/onl.coconut.wallet/changelog.md
# Exit codes: 0 = reproducible, 1 = not_reproducible or ftbfs, 2 = invalid parameters.
set -euo pipefail

EXEC_DIR="$(pwd)"
readonly EXEC_DIR
readonly SCRIPT_VERSION="v0.1.20"
readonly SCRIPT_NAME="coconut_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_SHA256=""

readonly APP_ID="onl.coconut.wallet"
readonly REPO_URL="https://github.com/noncelab/coconut_wallet.git"
readonly BITBOX_FORK_URL="https://github.com/4xvgal/bitbox02-api-go.git"
readonly BITBOX_FORK_BRANCH="fix/nil-guard-psbt"

readonly BT_VER="1.18.3"
readonly BT_URL="https://github.com/google/bundletool/releases/download/${BT_VER}/bundletool-all-${BT_VER}.jar"
readonly BT_SHA="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
readonly AT_VER="3.0.3"
readonly AT_URL="https://github.com/iBotPeaches/Apktool/releases/download/v${AT_VER}/apktool_${AT_VER}.jar"
readonly AT_SHA="dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423"
readonly HELPER_IMAGE="docker.io/library/eclipse-temurin:17-jre@sha256:4faa9eaf440514dd4f7ef71fecb92526e13679aea039bed5d2fc98e885c60dee"
readonly GO_VER="1.26.0"
readonly GO_URL="https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
readonly GO_SHA="aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235"
readonly PUB_OVERRIDE="url_launcher_android: 6.3.25"

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

cap() { awk -v n="${1:-5}" 'NR<=n{print} {last=NR} END{if(last>n) printf "    ... %d more line(s); full listing saved\n", last-n}'; }

SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
printf '%s %s sha256:%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

rm -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml"

usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} --binary <dir-of-official-splits|base.apk> [--version <v>]
                      [--arch <a>] [--type <t>] [--commit <sha>]

  --binary   REQUIRED. Directory holding the official Play split APKs (base.apk plus
             split_config.*.apk), or the path to base.apk itself, whose siblings in
             the same directory then form the split set. Alias: --apk.
  --version  Optional. Selects tag v<version>, whose .fvmrc sets the Flutter version;
             read from base.apk's versionName when omitted (ABS passes none).
  --arch     Optional. Checked against the split set's ABI split; mismatch exits 2.
  --type     Optional. Logged, unused (mainnet flavor only — see header SCOPE).
  --commit   Optional. Build this revision instead of the derived release tag.

Requires: podman or docker only. No smartphone, no adb, no root.
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
    log "COMPARISON_RESULTS.yaml written with verdict: ${verdict}"
}

WORK_DIR=""
CONTAINER_RUNTIME=""

normalize_ownership() {
    [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${CONTAINER_RUNTIME}" ]] || return 0
    if [[ "${CONTAINER_RUNTIME}" == "podman" ]]; then
        podman unshare chown -R 0:0 "${WORK_DIR}" 2>/dev/null \
            || log_warn "Could not normalize ownership under ${WORK_DIR}"
    else
        docker run --rm --user 0:0 -v "${WORK_DIR}:/work" "$HELPER_IMAGE" \
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
    return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

die_invalid() { log_err "$1"; echo "Exit code: ${EXIT_INVALID}"; exit "${EXIT_INVALID}"; }
die_err() { log_err "$1 No YAML written."; echo "Exit code: ${EXIT_FAILED}"; exit "${EXIT_FAILED}"; }

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
        *)              log_warn "Ignoring unrecognised parameter: $1"; shift ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] && die_invalid "Refusing to run as root. Run as a normal user."
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

if [[ -n "$arch_arg" ]]; then
    case "$arch_arg" in
        *arm64*|*aarch64*) abi="arm64_v8a" ;;
        *armeabi*|*armv7*|arm) abi="armeabi_v7a" ;;
        *x86_64*|*x86-64*|*amd64*) abi="x86_64" ;;
        x86|*i686*|*i386*) abi="x86" ;;
        *) die_invalid "Unsupported --arch '${arch_arg}' (arm64-v8a, armeabi-v7a, x86_64, x86)." ;;
    esac
    has_abi=false
    for a in arm64_v8a armeabi_v7a x86_64 x86; do [[ -f "${OFFICIAL_DIR}/split_config.${a}.apk" ]] && has_abi=true; done
    if [[ "$has_abi" == true ]]; then
        [[ -f "${OFFICIAL_DIR}/split_config.${abi}.apk" ]] \
            || die_invalid "--arch ${arch_arg} does not match the split set: no split_config.${abi}.apk in ${OFFICIAL_DIR}."
        log_ok "--arch ${arch_arg} matches split_config.${abi}.apk"
    else
        log_warn "--arch ${arch_arg}: the split set has no ABI split; the device spec's ABI comes from base.apk"
    fi
fi
[[ -n "$type_arg" ]] && log "--type ${type_arg} accepted but not used (mainnet flavor only)"

section "PRE-FLIGHT"
if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    die_invalid "Neither podman nor docker found. Install one of them (podman preferred)."
fi
log_ok "Using ${CONTAINER_RUNTIME} as container runtime"
HELPER_USER=(); [[ "$CONTAINER_RUNTIME" == docker ]] && HELPER_USER=(--user "$(id -u):$(id -g)")
hrun() { "$CONTAINER_RUNTIME" run --rm "${HELPER_USER[@]}" -e HOME=/tmp "$@"; }
if [[ -z "$version_arg" ]]; then
    version_arg="$(hrun -v "${OFFICIAL_DIR}:/o:ro" "$HELPER_IMAGE" sh -c 'curl -fsSL "$1" -o /tmp/at.jar \
        && echo "$2  /tmp/at.jar" | sha256sum -c --quiet \
        && java -jar /tmp/at.jar d -f -s -o /tmp/m /o/base.apk >/dev/null 2>&1 \
        && sed -n "s/^ *versionName: *'"'"'\{0,1\}\([^'"'"']*\).*/\1/p" /tmp/m/apktool.yml' sh "$AT_URL" "$AT_SHA")" \
        || die_err "Could not read versionName from base.apk (apktool in ${HELPER_IMAGE})."
    log "--version not given; base.apk versionName = ${version_arg}"
fi
[[ "$version_arg" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die_invalid "Version '${version_arg}' is not of the form X.Y.Z."

RUN_ID="$(date +%s)-$$"
WORK_DIR="$(pwd -P)/coconut_verification_${version_arg:-unset}_${RUN_ID}"  # per run, caller dir (never /tmp)
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

section "SETUP: PINNED TOOLING"
fetch_pinned() {
    hrun -v "${WORK_DIR}/tools:/t" "$HELPER_IMAGE" sh -c 'curl -fsSL "$1" -o "/t/$3" && echo "$2  /t/$3" | sha256sum -c --quiet' sh "$1" "$2" "$3" \
        || die_err "Could not download or verify $3 (${1}; expected sha256 ${2})."
    log_ok "$3 verified: $2"
}
fetch_pinned "$BT_URL" "$BT_SHA" bundletool.jar
fetch_pinned "$AT_URL" "$AT_SHA" apktool.jar

section "SETUP: TOOLCHAIN VERSIONS"
FVMRC_URL="https://raw.githubusercontent.com/noncelab/coconut_wallet/v${version_arg}/.fvmrc"
FLUTTER_TAG="$(hrun "$HELPER_IMAGE" curl -fsSL "$FVMRC_URL" | sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" || true
[[ "$FLUTTER_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_err "Could not read a Flutter version from ${FVMRC_URL}."
NDK_VER=""
for f in packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt packages/flutter_tools/gradle/src/main/groovy/flutter.groovy; do
    NDK_VER="$(hrun "$HELPER_IMAGE" curl -fsSL "https://raw.githubusercontent.com/flutter/flutter/${FLUTTER_TAG}/${f}" 2>/dev/null \
        | sed -n 's/.*ndkVersion[^=]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1)" || true
    [[ -n "$NDK_VER" ]] && break
done
[[ "$NDK_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_err "Could not read Flutter ${FLUTTER_TAG}'s default ndkVersion."
readonly FLUTTER_TAG NDK_VER
log_ok "Flutter ${FLUTTER_TAG} (tag v${version_arg} .fvmrc), NDK ${NDK_VER} (Flutter ${FLUTTER_TAG} default)"

section "BUILD: TOOLCHAIN IMAGE"
DOCKERFILE="${WORK_DIR}/Dockerfile"
cat > "$DOCKERFILE" <<DOCKERFILE_EOF
FROM docker.io/debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN set -ex; apt-get update; apt-get install -y --no-install-recommends \\
      curl git unzip xz-utils ca-certificates openjdk-17-jdk-headless \\
      build-essential clang cmake ninja-build pkg-config protobuf-compiler \\
      python3 file rsync libglu1-mesa libdbus-1-dev; \\
    rm -rf /var/lib/apt/lists/*
ENV ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk
RUN set -ex; mkdir -p \$ANDROID_SDK_ROOT/cmdline-tools; \\
    curl -fsSL -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip; \\
    unzip -q /tmp/cmdline-tools.zip -d \$ANDROID_SDK_ROOT/cmdline-tools; \\
    mv \$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools \$ANDROID_SDK_ROOT/cmdline-tools/latest; \\
    rm /tmp/cmdline-tools.zip
ENV PATH=\$PATH:\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/build-tools/36.0.0:/usr/local/go/bin:/root/go/bin:/root/.cargo/bin
RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true; \\
    sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;${NDK_VER}" >/dev/null
ENV ANDROID_NDK_HOME=\$ANDROID_SDK_ROOT/ndk/${NDK_VER}
ENV TAR_OPTIONS=--no-same-owner
ENV PATH=\$PATH:/opt/flutter/bin
RUN set -ex; git clone --branch ${FLUTTER_TAG} --depth 1 https://github.com/flutter/flutter.git /opt/flutter; \\
    git config --system --add safe.directory /opt/flutter; \\
    flutter config --no-analytics --android-sdk \$ANDROID_SDK_ROOT >/dev/null; \\
    flutter precache --android >/dev/null 2>&1 || true; \\
    chmod -R a+rwX /opt/flutter
RUN set -ex; curl -fsSL -o /tmp/go.tgz ${GO_URL}; \\
    echo "${GO_SHA}  /tmp/go.tgz" | sha256sum -c -; \\
    tar -C /usr/local -xzf /tmp/go.tgz; rm /tmp/go.tgz
RUN go install golang.org/x/mobile/cmd/gomobile@latest; \\
    gomobile init || echo "WARNING: gomobile init failed (non-fatal, continuing)"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \\
    . /root/.cargo/env; \\
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; \\
    cargo install cargo-ndk
ENV CARGO_HOME=/root/.cargo RUSTUP_HOME=/root/.rustup
RUN chmod 755 /root
COPY bundletool.jar /opt/bundletool.jar
COPY apktool.jar /opt/apktool.jar
RUN printf '#!/bin/sh\nexec java -jar /opt/bundletool.jar "\$@"\n' > /usr/local/bin/bundletool && chmod +x /usr/local/bin/bundletool; \\
    printf '#!/bin/sh\nexec java -jar /opt/apktool.jar "\$@"\n' > /usr/local/bin/apktool && chmod +x /usr/local/bin/apktool
WORKDIR /build
RUN chmod 1777 /build
DOCKERFILE_EOF
cp "${WORK_DIR}/tools/bundletool.jar" "${WORK_DIR}/tools/apktool.jar" "${WORK_DIR}/"
IMAGE_NAME="coconut-verify-$(sha256_of "$DOCKERFILE" | cut -c1-12)"
( cd "${WORK_DIR}" && "$CONTAINER_RUNTIME" build -t "$IMAGE_NAME" -f Dockerfile . ) \
    || die_err "Toolchain image build failed. See terminal output above."
log_ok "Image built: ${IMAGE_NAME}"

DRIVER="${WORK_DIR}/driver.sh"
cat > "$DRIVER" <<'DRIVER_EOF'
#!/bin/bash
set -euo pipefail
APP_ID="onl.coconut.wallet"
REPO_URL="https://github.com/noncelab/coconut_wallet.git"
BITBOX_FORK_URL="https://github.com/4xvgal/bitbox02-api-go.git"
BITBOX_FORK_BRANCH="fix/nil-guard-psbt"
cd /work
echo "error" > /work/verdict.txt

echo "== PHASE 0: OFFICIAL METADATA =="
apktool d -f -s --frame-path /tmp/apktool-frame -o /work/comparison/meta /work/official/base.apk >/dev/null
pkg="$(grep -o 'package="[^"]*"' /work/comparison/meta/AndroidManifest.xml | head -1 | cut -d'"' -f2)"
[[ "$pkg" == "$APP_ID" ]] || { echo "PACKAGE MISMATCH: expected ${APP_ID}, got ${pkg}" >&2; echo "invalid" > /work/verdict.txt; exit 1; }
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
    echo "Tag ${TAG} not found upstream; stopping." >&2
    exit 1
fi
COMMIT_HASH="$(git rev-parse HEAD)"
echo "$COMMIT_HASH" > /work/commit.txt
fvm_pin="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .fvmrc 2>/dev/null | head -1)"
if [[ "$fvm_pin" != "$FLUTTER_TAG" ]]; then
    echo "FLUTTER MISMATCH: tag ${TAG} .fvmrc says '${fvm_pin}', image has ${FLUTTER_TAG} (check --version)" >&2
    echo "invalid" > /work/verdict.txt
    exit 1
fi
echo "Flutter ${FLUTTER_TAG} = .fvmrc at ${TAG}"
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
        || { echo "Could not extract ${f} from the official APK's Flutter assets." >&2; exit 1; }
done
echo "Recovered: mainnet.env regtest.env testnet.env"

echo "== PHASE 4: NATIVE BRIDGES FROM SOURCE (policy: no vendored first-party blobs) =="
. /root/.cargo/env
export CARGO_HOME=/tmp/cargo-home
mkdir -p "$CARGO_HOME"
cd /build/coconut_wallet/go && go mod tidy
cd /build/coconut_wallet

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

{ make gomobile-android && make trezor-android; } || { echo "Native bridge build failed." >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }

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
if grep -q '^dependency_overrides:' pubspec.yaml; then
    echo "upstream $(sed -n '/^dependency_overrides:/,/^[^ #]/{/^  [a-z]/p}' pubspec.yaml | xargs)" > /work/pub_override.txt
else
    printf '\ndependency_overrides:\n  %s\n' "$PUB_OVERRIDE" >> pubspec.yaml
    echo "ours (not upstream, a guess) ${PUB_OVERRIDE}" > /work/pub_override.txt
fi
echo "Dependency override: $(cat /work/pub_override.txt)"
flutter pub get 2>&1 | tee /work/pub-get.log || { echo "flutter pub get failed." >&2; echo "ftbfs" > /work/verdict.txt; exit 1; }
cp pubspec.lock /work/pubspec.lock.resolved
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
cp "$AAB" /work/app-mainnet-release.aab

echo "== PHASE 7: DEVICE SPEC FROM THE OFFICIAL SPLITS =="
abis=""; locales=""; density=""
for f in /work/official/split_config.*.apk; do
    base="$(basename "$f" .apk)"; tag="${base#split_config.}"
    case "$tag" in
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
    od="/work/unzipped/official/${cfg}"; bd="/work/unzipped/built/${cfg}"
    rm -rf "$od" "$bd"; mkdir -p "$od" "$bd"
    unzip -q -o "$o" -d "$od"; unzip -q -o "$b" -d "$bd"
    raw="$(diff -rq "$od" "$bd" || true)"
    printf '%s\n' "$raw" > "/work/comparison/diff-unzipped-${cfg}.txt"
    n="$(printf '%s\n' "$raw" | grep -vc '^$' || true)"
    echo "raw diffs: ${n} (full: comparison/diff-unzipped-${cfg}.txt)"

    sign_re="^(Only in ${od}/META-INF: (MANIFEST\.MF|[A-Z0-9]+\.(SF|RSA|DSA|EC))\$|Files ${od}/META-INF/(MANIFEST\.MF|[A-Z0-9]+\.(SF|RSA|DSA|EC)) and ${bd}/META-INF/(MANIFEST\.MF|[A-Z0-9]+\.(SF|RSA|DSA|EC)) differ)\$"
    sign_lines="$(printf '%s\n' "$raw" | grep -E "$sign_re" || true)"
    c_sign="$(printf '%s\n' "$sign_lines" | grep -vc '^$' || true)"
    c_arsc="$(printf '%s\n' "$raw" | grep -Fxc "Files ${od}/resources.arsc and ${bd}/resources.arsc differ" || true)"
    a_arsc=0
    if [[ "$c_arsc" -eq 1 ]]; then
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
    [[ "$acc" -le "$n" ]] || { echo "Internal accounting error on split ${cfg}." >&2; exit 1; }
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

section "BUILD + COMPARE"
RUN_USER_ARGS="--user 0:0"
"$CONTAINER_RUNTIME" run --rm ${RUN_USER_ARGS} --env "FLUTTER_TAG=${FLUTTER_TAG}" --env "PUB_OVERRIDE=${PUB_OVERRIDE}" --volume "${WORK_DIR}:/work" "$IMAGE_NAME" \
    bash /work/driver.sh 2>&1 | tee "${WORK_DIR}/container-run.log" \
    || true   # verdict/exit handling below reads /work/verdict.txt regardless of container rc

VERDICT="$(cat "${WORK_DIR}/verdict.txt" 2>/dev/null || echo error)"
case "$VERDICT" in
    reproducible|not_reproducible|ftbfs) ;;
    invalid) die_invalid "Input does not match this app or version (see container output above)." ;;
    *) die_err "Run stopped before a verdict (see container output above, ${WORK_DIR}/container-run.log)." ;;
esac
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
PUB_USED="$(cat "${WORK_DIR}/pub_override.txt" 2>/dev/null || echo unknown)"

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
echo "pubOverride:    ${PUB_USED} (upstream = the tag's pubspec.yaml; ours = matches the official APK's androidx)"
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

NOTES="Coconut Wallet ${APP_ID} v${VERSION_NAME} (commit ${COMMIT_HASH}), Google Play split set built with the project's own Fastlane recipe reverse-engineered from android/fastlane/Fastfile (no upstream CI builds this artifact). ${RAW_TOTAL} raw difference(s) across splits; excluded only root META-INF signing filenames and a resources.arsc decode match (review-notes/resources.arsc.md) -- both sanctioned, evidence-backed exceptions, not general acceptable-diff filtering. ${UNACC_TOTAL} unaccounted difference(s) -- the verdict is judged on this alone. ${MISSING_TOTAL} split(s) unmatched. Known open items, NOT resolved by this script: (1) mainnet/regtest/testnet .env recovered from the official APK's bundled Flutter assets rather than from upstream (gitignored, obtainable only by emailing the vendor) -- review this design decision; (2) built WITHOUT REQUIRE_GOOGLE_SERVICES=true because google-services.json is unobtainable and unlike the .env files is not bundled into the APK, while the official mainnet build sets it -- any Firebase/google-services-shaped diff should be attributed to this; (3a) upstream's Makefile does not parse at this tag (line 23 space-indented instead of TAB, broken since 2025-10-08 commit 5579122b), which breaks every make target including the gomobile/trezor bridge targets its own README tells you to run; this run applied a whitespace-only make-syntax repair -- ${MAKEFILE_NOTE}; (3) the BitBox02 bridge is built against a non-upstream fork (${BITBOX_FORK_URL} @ ${BITBOX_FORK_BRANCH}, commit ${BITBOX_FORK_COMMIT}) the README requires in place of upstream BitBoxSwiss; (4) the NDK revision used to compile the Trezor bridge (${NDK_VER}) is Flutter ${FLUTTER_TAG}'s ndkVersion default; the vendor's own NDK for that bridge is unknown; (5) dependency override: ${PUB_USED}. Official base.apk SHA-256 ${APP_HASH}."
write_yaml "$VERDICT" "$NOTES"

if [[ "$VERDICT" == "reproducible" ]]; then
    log_ok "Verdict: reproducible -- every split has zero unaccounted differences"
    echo "Exit code: ${EXIT_SUCCESS}"
    exit "${EXIT_SUCCESS}"
fi
log_warn "Verdict: ${VERDICT} -- ${UNACC_TOTAL} unaccounted difference(s), ${MISSING_TOTAL} unmatched split(s)"
echo "Exit code: ${EXIT_FAILED}"
exit "${EXIT_FAILED}"
