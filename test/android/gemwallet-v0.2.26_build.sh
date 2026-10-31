#!/bin/bash
# gemwallet-v0.2.26_build.sh - Gem Wallet Android reproducible build verification
# Version: v0.2.26
# Organization: WalletScrutiny.com
# Disclaimer: provided as-is, without warranty. Review before running. This is not a security audit.
# Steps: read the official APK(s) (Play split set or GitHub universal APK), clone the release tag,
#   build upstream's release recipe in a per-run container, compare every ZIP entry, write results.
# Last modified by: Claude Opus 5.5 for Danny Garcia
# Last modified on: 2026-10-31

set -Eeuo pipefail

readonly SCRIPT_NAME="gemwallet_build.sh" SCRIPT_VERSION="v0.2.26"
SCRIPT_HASH="$(sha256sum "$0" 2>/dev/null | awk '{print $1}' || true)"
readonly SCRIPT_HASH="${SCRIPT_HASH:-N/A}"
echo "${SCRIPT_NAME} ${SCRIPT_VERSION} sha256:${SCRIPT_HASH}"

readonly APP_ID="com.gemwallet.android"
readonly REPO_URL="https://github.com/gemwalletcom/wallet.git"
readonly RELEASES_URL="https://github.com/gemwalletcom/wallet/releases/download"
readonly WS_IMG="docker.io/walletscrutiny/android:5"
readonly BASE_IMG="docker.io/library/eclipse-temurin:17-jdk-noble@sha256:78dde986267ae7cac62fe7ef624c2a5cee2036b6822933d39fd3870618b91526"
readonly JUST_URL="https://github.com/casey/just/releases/download/1.50.0/just-1.50.0-x86_64-unknown-linux-musl.tar.gz"
readonly SDK_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
readonly UNIVERSAL_MARK="apk.gemwallet.com/gem_wallet_latest.apk"
declare -rA BUNDLETOOL_SHA256=(
    [1.18.1]=675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c
    [1.18.2]=378b5434cd1378bef6b2bc527b8c7f0ff2584b273830335bce54d6d0813c8584
    [1.18.3]=a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29
)
EXEC_DIR="$(pwd -P)"
RUN_ID="$(date +%s)-$$"
readonly EXEC_DIR RUN_ID IMG="localhost/gemwallet-build:${RUN_ID}"

VERSION="" ARCH="" BINARY="" DEVICE_SDK="" CLEANUP=false
RT="" VOL_RO=":ro" VOL_RW="" WORK_DIR="" CREATED=false IMG_BUILT=false
MODE="" TAG="" COMMIT="" SIGNER="" VNAME="" VCODE="" APP_HASH="" COUNTED=0
declare -a OFFICIAL=() LABELS=() NCOUNT=() NACC=() OFF_HASH=() BUILT_HASH=()

info() { echo "[INFO] $*"; }
pass() { echo "[PASS] $*"; }
warn() { echo "[WARNING] $*"; }
fail() { echo "[FAIL] $*"; }
invalid() { echo "[ERROR] $*"; echo "Exit code: 2"; exit 2; }
abort() { echo "[ERROR] $*"; echo "Exit code: 1"; exit 1; }

on_exit() {
    local rc=$?
    set +e
    if [[ "${CREATED}" == true ]]; then
        if [[ "${RT}" == podman ]]; then
            podman unshare chown -R 0:0 "${WORK_DIR}" 2>/dev/null
        else
            docker run --rm -v "${WORK_DIR}:/w" "${WS_IMG}" chown -R "$(id -u):$(id -g)" /w 2>/dev/null
        fi
    fi
    if [[ "${IMG_BUILT}" == true ]]; then
        "${RT}" rmi -f "${IMG}" >/dev/null 2>&1
        info "Per-run image ${IMG} removed."
    fi
    if [[ "${CREATED}" == true ]]; then
        if [[ "${CLEANUP}" == true && "${rc}" -eq 0 ]]; then
            rm -rf "${WORK_DIR}"
        else
            info "Workspace preserved: ${WORK_DIR}"
        fi
    fi
}
trap on_exit EXIT
trap 'echo "[ERROR] Interrupted"; echo "Exit code: 130"; exit 130' INT TERM
trap 'echo "[ERROR] Unexpected failure at line ${LINENO}"; echo "Exit code: 1"; exit 1' ERR

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--binary <apk|split dir>] [--version <v>] [--arch <abi>] [--type <t>]
  --binary, --apk  GitHub universal APK, Play base.apk, or a directory of Play split APKs
  --version        release version; read from the APK when omitted. Without --binary the
                   GitHub universal APK of this version is downloaded
  --arch           ABI of the split set (default: the ABI split present, else arm64-v8a)
  --type           accepted for ABS compatibility; unused
  --device-sdk     device API level for bundletool (default: 32)
  --cleanup        remove the workspace after a reproducible run
  --script-version, --help
Exit codes: 0 reproducible, 1 not_reproducible/ftbfs/failure, 2 invalid parameters
EOF
}

need() { [[ -n "${2-}" && "${2-}" != --* ]] || invalid "$1 requires a value"; }
while (($#)); do
    case "$1" in
        --binary|--apk) need "$@"; BINARY="$2"; shift ;;
        --version) need "$@"; VERSION="$2"; shift ;;
        --arch) need "$@"; ARCH="$2"; shift ;;
        --type) need "$@"; shift ;;
        --device-sdk) need "$@"; DEVICE_SDK="$2"; shift ;;
        --cleanup) CLEANUP=true ;;
        --script-version) echo "Exit code: 0"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) warn "Ignoring unknown argument: $1" ;;
    esac
    shift
done

[[ "$(id -u)" -eq 0 ]] && invalid "Do not run as root."
[[ -z "${BINARY}" && -z "${VERSION}" ]] && invalid "--binary or --version is required."
[[ -n "${BINARY}" && ! -e "${BINARY}" ]] && invalid "--binary not found: ${BINARY}"
[[ -n "${DEVICE_SDK}" && ! "${DEVICE_SDK}" =~ ^[0-9]+$ ]] && invalid "--device-sdk must be an integer."
case "${ARCH}" in ""|arm64-v8a|armeabi-v7a|x86_64|x86) ;; *) invalid "Unsupported --arch: ${ARCH}" ;; esac

if command -v podman >/dev/null 2>&1; then
    RT=podman VOL_RO=":ro,Z" VOL_RW=":Z"
elif command -v docker >/dev/null 2>&1; then
    RT=docker
else
    abort "Neither podman nor docker found."
fi
info "Using ${RT}"
rm -f "${EXEC_DIR}/COMPARISON_RESULTS.yaml"

ws() { "${RT}" run --rm -v "${WORK_DIR}:/w${VOL_RW}" -w /w "${WS_IMG}" sh -c "$1"; }
bx() { "${RT}" run --rm -v "${WORK_DIR}:/workspace${VOL_RW}" -w /workspace "$@"; }

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
    local d
    d="$(cd "$(dirname "$1")" && pwd -P)"
    "${RT}" run --rm -v "${d}:/a${VOL_RO}" "${WS_IMG}" sh -c "${PROBE_SH}" sh "/a/$(basename "$1")" "${UNIVERSAL_MARK}"
}

read_official() {
    local f pkg vn vc split marks univ signer hash base="" n=0
    local -a files=()
    if [[ -d "${BINARY}" ]]; then
        while IFS= read -r f; do files+=("${f}"); done < <(find "${BINARY}" -maxdepth 1 -type f -name '*.apk' | sort)
    else
        files=("${BINARY}")
    fi
    [[ "${#files[@]}" -eq 0 ]] && invalid "No APK found in ${BINARY}"
    for f in "${files[@]}"; do
        IFS='|' read -r pkg vn vc split marks univ signer hash < <(probe "${f}")
        [[ -z "${pkg}" ]] && abort "Could not read the manifest of $(basename "${f}")."
        [[ "${pkg}" != "${APP_ID}" ]] && invalid "Package mismatch: $(basename "${f}") is ${pkg}, expected ${APP_ID}."
        if [[ -z "${split}" ]]; then
            [[ -n "${base}" ]] && invalid "More than one base APK in ${BINARY}."
            base="${f}" VNAME="${vn}" VCODE="${vc}" SIGNER="${signer}" APP_HASH="${hash}" n="${marks}"
            if [[ "${marks}" -eq 0 && "${univ}" -gt 0 ]]; then OFFICIAL+=("${f}|universal.apk"); else OFFICIAL+=("${f}|base.apk"); fi
        else
            OFFICIAL+=("${f}|split_config.${split#config.}.apk")
        fi
    done
    [[ -z "${base}" ]] && invalid "No base APK: a config split alone cannot be verified; pass the split directory."
    if [[ "${#files[@]}" -gt 1 || "${n}" -gt 0 ]]; then
        MODE="split"
    elif [[ "${OFFICIAL[0]}" == *"|universal.apk" ]]; then
        MODE=universal
    else
        invalid "Not a Play split set or the GitHub universal APK (another store channel?)."
    fi
}

check_arch() {
    local e abi="" n=0
    for e in "${OFFICIAL[@]}"; do
        if [[ "${e##*|}" =~ ^split_config\.(arm64_v8a|armeabi_v7a|x86_64|x86)\.apk$ ]]; then
            abi="${BASH_REMATCH[1]}"; n=$((n + 1))
        fi
    done
    [[ "${abi}" == x86_64 ]] || abi="${abi//_/-}"
    if [[ -n "${ARCH}" && "${n}" -gt 0 && "${ARCH}" != "${abi}" ]]; then
        invalid "--arch ${ARCH} does not match the ABI split (${abi})."
    fi
    ARCH="${ARCH:-${abi:-arm64-v8a}}"
}

if [[ -n "${BINARY}" ]]; then
    info "=== PREPARATION ==="
    read_official
    [[ -z "${VNAME}" ]] && abort "Could not read versionName from the base APK."
    [[ -n "${VERSION}" && "${VERSION}" != "${VNAME}" ]] && invalid "--version ${VERSION} does not match the APK (${VNAME})."
    VERSION="${VNAME}"
    [[ "${MODE}" == split ]] && check_arch
    [[ "${MODE}" == universal && -n "${ARCH}" ]] && warn "--arch ignored: the universal APK holds every ABI."
    info "Input: ${MODE} (${#OFFICIAL[@]} APK(s)), version ${VERSION} (${VCODE})"
else
    MODE=universal
fi
[[ "${VERSION}" =~ ^[0-9A-Za-z._-]+$ ]] || invalid "Unsafe version string: ${VERSION}"

WORK_DIR="${EXEC_DIR}/gemwallet_verification_${VERSION}_${RUN_ID}"
mkdir "${WORK_DIR}" || abort "Cannot create per-run workspace ${WORK_DIR}"
CREATED=true
mkdir -p "${WORK_DIR}/official" "${WORK_DIR}/built" "${WORK_DIR}/cmp" "${WORK_DIR}/ctx"
info "Workspace: ${WORK_DIR}"

info "Resolving tag for ${VERSION}..."
rc=0
tags="$(ws "git ls-remote --tags --exit-code '${REPO_URL}' 'refs/tags/${VERSION}' 'refs/tags/v${VERSION}'")" || rc=$?
[[ "${rc}" -eq 2 ]] && TAG=none
[[ "${rc}" -ne 0 && "${rc}" -ne 2 ]] && abort "git ls-remote failed (rc ${rc}); network problem?"
if [[ "${TAG}" != none ]]; then
    TAG="$(printf '%s\n' "${tags}" | sed -n 's#.*refs/tags/\([^^]*\)$#\1#p' | head -n1)"
    info "Tag: ${TAG}"
fi

if [[ -z "${BINARY}" && "${TAG}" != none ]]; then
    info "Downloading gem_wallet_universal_${VERSION}.apk from the GitHub release..."
    ws "wget -q -O official/universal.apk '${RELEASES_URL}/${TAG}/gem_wallet_universal_${VERSION}.apk'" \
        || abort "Download failed: no universal APK for ${TAG}?"
    BINARY="${WORK_DIR}/official/universal.apk"
    IFS='|' read -r pkg VNAME VCODE _ _ univ SIGNER APP_HASH < <(probe "${BINARY}")
    [[ "${pkg}" != "${APP_ID}" || "${univ}" -eq 0 ]] && abort "Downloaded file is not the ${APP_ID} universal APK."
    [[ "${VNAME}" != "${VERSION}" ]] && abort "Downloaded APK is version ${VNAME}, expected ${VERSION}."
    OFFICIAL=("${BINARY}|universal.apk")
fi

for e in "${OFFICIAL[@]}"; do
    [[ "${e%%|*}" -ef "${WORK_DIR}/official/${e##*|}" ]] || cp "${e%%|*}" "${WORK_DIR}/official/${e##*|}"
done

write_yaml() {
    printf 'script_version: %s\nverdict: %s\nnotes: |\n%s\n' "${SCRIPT_VERSION}" "$1" \
        "$(printf '%s\n' "$2" | sed 's/^/  /')" > "${EXEC_DIR}/COMPARISON_RESULTS.yaml"
    info "Generated COMPARISON_RESULTS.yaml (verdict: $1)"
}

results() {
    local i
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         ${SIGNER:-unknown}"
    echo "apkVersionName: ${VNAME:-${VERSION}}"
    echo "apkVersionCode: ${VCODE:-unknown}"
    echo "verdict:        $1"
    echo "appHash:        ${APP_HASH:-unknown}"
    echo "commit:         ${COMMIT:-unknown}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_HASH}"
    echo ""
    echo "Diff:"
    if [[ "$1" == ftbfs ]]; then
        echo "(no build to compare: $2)"
    else
        for i in "${!LABELS[@]}"; do
            echo "=== ${LABELS[$i]} ==="
            [[ "${NCOUNT[$i]}" -eq 0 ]] && echo "(no differing entries)" || echo "${NCOUNT[$i]} differing entr(ies)"
        done
        if [[ "${COUNTED}" -gt 0 ]]; then
            echo ""
            echo "Differing entries (first 5 of ${COUNTED}; full list: cmp/counted.txt in the workspace):"
            head -n5 "${WORK_DIR}/cmp/counted.txt" | sed 's/^/  /'
        fi
        if [[ -s "${WORK_DIR}/cmp/accepted.txt" ]]; then
            echo ""
            echo "Accepted differences (excluded from the verdict):"
            sed 's/^/  /' "${WORK_DIR}/cmp/accepted.txt"
        fi
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    if [[ -s "${WORK_DIR}/tag.txt" ]]; then cat "${WORK_DIR}/tag.txt"; else echo "Tag: ${TAG:-unknown}"; fi
    echo "===== End Results ====="
    echo ""
    local first="${OFFICIAL[0]:-none}"
    echo "Input: ${MODE}; appHash is the official ${first##*|} as provided (publish this one)."
    for i in "${!LABELS[@]}"; do
        echo "  ${LABELS[$i]}: official ${OFF_HASH[$i]}"
        echo "  ${LABELS[$i]}: built    ${BUILT_HASH[$i]}"
    done
    echo "Workspace: ${WORK_DIR}"
}

ftbfs() {
    fail "ftbfs: $1"
    write_yaml ftbfs "Gem Wallet ${VERSION} (${MODE}): $1"
    results ftbfs "$1"
    echo "Exit code: 1"
    exit 1
}

[[ "${TAG}" == none ]] && ftbfs "no git tag ${VERSION} or v${VERSION} in ${REPO_URL}."

info "=== BUILD IMAGE ==="
cat > "${WORK_DIR}/ctx/Containerfile" <<EOF
FROM ${BASE_IMG}
ENV DEBIAN_FRONTEND=noninteractive ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=/root/.cargo/bin:/opt/android-sdk/cmdline-tools/latest/bin:\${PATH}
RUN apt-get update -q && apt-get install -y --no-install-recommends git curl unzip ca-certificates \
    python3 apktool build-essential && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "${JUST_URL}" | tar -xz -C /usr/local/bin just
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
RUN curl -fsSLo /tmp/t.zip "${SDK_TOOLS_URL}" && unzip -q /tmp/t.zip -d /tmp/t \
    && mkdir -p /opt/android-sdk/cmdline-tools && mv /tmp/t/cmdline-tools /opt/android-sdk/cmdline-tools/latest \
    && rm -rf /tmp/t /tmp/t.zip && (yes | sdkmanager --licenses >/dev/null) && sdkmanager platform-tools >/dev/null
EOF
IMG_BUILT=true
if [[ "${RT}" == podman ]]; then
    podman build --layers=false -t "${IMG}" -f "${WORK_DIR}/ctx/Containerfile" "${WORK_DIR}/ctx" \
        || abort "Toolchain image build failed."
else
    docker build --no-cache --force-rm -t "${IMG}" -f "${WORK_DIR}/ctx/Containerfile" "${WORK_DIR}/ctx" \
        || abort "Toolchain image build failed."
fi
pass "Image ${IMG} built (per-run, removed at exit)."

read -r -d '' BUILD_SH <<'EOF' || true
set -euo pipefail
echo clone > stage
git clone --depth 1 --recursive --branch "$TAG" "$REPO" app
cd app
git rev-parse HEAD > ../commit.txt
t="$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || echo missing)"
{
    echo "Tag $TAG ($t object) at commit $(git rev-parse HEAD)."
    if [ "$t" = tag ]; then git tag -v "$TAG" 2>&1 | tail -n2 || true; fi
    git verify-commit HEAD >/dev/null 2>&1 && echo "Commit signature: valid." || echo "Commit signature: not verified."
} > ../tag.txt
echo toolchain > ../stage
rv="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)"
rustup toolchain install "${rv:?}" --profile minimal -c clippy -c rustfmt
rustup target add aarch64-linux-android armv7-linux-androideabi
cv="$(sed -n 's/.*CARGO_NDK_VERSION:-\([0-9.]*\)}.*/\1/p' android/reproducible/versions.sh)"
cargo install --locked "cargo-ndk@${cv:?}"
nv="$(sed -n 's/^androidNdk *= *"\(.*\)"/\1/p' android/gradle/libs.versions.toml)"
sdkmanager "ndk;${nv:?}" >/dev/null
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$nv" ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/$nv" NDK_HOME="$ANDROID_HOME/ndk/$nv"
echo "Toolchain: rust $(rustc --version | cut -d' ' -f2), cargo-ndk $cv, NDK $nv; Gradle installs the platform it needs"
echo gradle > ../stage
cd android
touch local.properties
if [ "$MODE" = universal ]; then set -- assembleUniversalRelease -PuseLegacyPackaging=true; else set -- :app:bundleGoogleRelease; fi
BUILD_MODE=release SKIP_SIGN=true ./gradlew clean "$@" --no-configuration-cache --no-daemon --stacktrace \
    "-Dorg.gradle.jvmargs=-Xmx8g -Dfile.encoding=UTF-8"
echo done > ../stage
EOF

info "=== BUILD (${MODE}) ==="
rc=0
bx -e TAG="${TAG}" -e REPO="${REPO_URL}" -e MODE="${MODE}" -e HOME=/root "${IMG}" bash -c "${BUILD_SH}" \
    2>&1 | tee "${WORK_DIR}/build.log" || rc=$?
COMMIT="$(cat "${WORK_DIR}/commit.txt" 2>/dev/null || true)"
stage="$(cat "${WORK_DIR}/stage" 2>/dev/null || echo none)"
if [[ "${rc}" -ne 0 ]]; then
    [[ "${stage}" == gradle ]] && ftbfs "Gradle release build failed at tag ${TAG}."
    abort "Build stopped during '${stage}' (rc ${rc}); network or toolchain problem, no verdict."
fi
out="${WORK_DIR}/app/android/app/build/outputs"
if [[ "${MODE}" == universal ]]; then
    artifact="$(find "${out}/apk/universal/release" -name '*.apk' 2>/dev/null | head -n1)"
    [[ -n "${artifact}" ]] || ftbfs "assembleUniversalRelease produced no APK."
    cp "${artifact}" "${WORK_DIR}/built/universal.apk"
else
    artifact="$(find "${out}/bundle/googleRelease" -name '*.aab' 2>/dev/null | head -n1)"
    [[ -n "${artifact}" ]] || ftbfs ":app:bundleGoogleRelease produced no AAB."
    cp "${artifact}" "${WORK_DIR}/built/app.aab"
fi
pass "Built: ${artifact#"${WORK_DIR}/"}"

if [[ "${MODE}" == split ]]; then
    info "=== RENDER SPLITS ==="
    bt_ver="$(bx "${IMG}" sh -c "unzip -p built/app.aab BundleConfig.pb | grep -a -o -m1 '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1")"
    bt_sha="${BUNDLETOOL_SHA256[${bt_ver:-none}]:-}"
    [[ -n "${bt_sha}" ]] || abort "AAB was made by bundletool '${bt_ver}', which is not pinned here; add its sha256."
    locales="" density=480 sdk="${DEVICE_SDK:-32}"
    for e in "${OFFICIAL[@]}"; do
        s="${e##*|}"; s="${s#split_config.}"; s="${s%.apk}"
        case "${s}" in
            base|arm64_v8a|armeabi_v7a|x86_64|x86) ;;
            ldpi) density=120 ;; mdpi) density=160 ;; hdpi) density=240 ;; xhdpi) density=320 ;;
            xxhdpi) density=480 ;; xxxhdpi) density=640 ;; tvdpi) density=213 ;;
            *dpi) ;;
            *) locales+="${locales:+,}\"${s}\"" ;;
        esac
    done
    printf '{"supportedAbis":["%s"],"supportedLocales":[%s],"screenDensity":%s,"sdkVersion":%s}\n' \
        "${ARCH}" "${locales:-\"en\"}" "${density}" "${sdk}" > "${WORK_DIR}/device-spec.json"
    info "bundletool ${bt_ver} (from BundleConfig.pb); device spec: $(cat "${WORK_DIR}/device-spec.json")"
    [[ -z "${DEVICE_SDK}" ]] && warn "sdkVersion 32 assumed; pass --device-sdk for the phone's API level."
    bx "${IMG}" bash -c "set -euo pipefail
        curl -fsSLo bundletool.jar https://github.com/google/bundletool/releases/download/${bt_ver}/bundletool-all-${bt_ver}.jar
        echo '${bt_sha}  bundletool.jar' | sha256sum -c -
        java -Djava.locale.useOldISOCodes=true -jar bundletool.jar build-apks --bundle=built/app.aab \
            --output=built/app.apks --device-spec=device-spec.json --mode=default --overwrite
        unzip -q -o built/app.apks -d built/apks
        for f in built/apks/splits/*.apk; do
            n=\${f##*/}; n=\${n%.apk}
            case \$n in base-master) cp \"\$f\" built/base.apk ;; base-*) cp \"\$f\" \"built/split_config.\${n#base-}.apk\" ;; esac
        done" || abort "bundletool could not render the splits."
fi

info "=== COMPARE ==="
cat > "${WORK_DIR}/cmp.py" <<'EOF'
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
        subprocess.run(['apktool', 'd', '-f', '-s', '-o', d, p], check=True, capture_output=True)
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
summary="$(bx "${IMG}" python3 cmp.py "${MODE}" "${names[@]}")" || abort "Comparison failed."
while IFS='|' read -r lab nc na oh bh; do
    LABELS+=("${lab}") NCOUNT+=("${nc}") NACC+=("${na}") OFF_HASH+=("${oh}") BUILT_HASH+=("${bh}")
    COUNTED=$((COUNTED + nc))
    info "${lab}: ${nc} differing, ${na} accepted"
done <<< "${summary}"

info "=== RESULT ==="
if [[ "${COUNTED}" -eq 0 ]]; then
    verdict=reproducible
    pass "VERDICT: REPRODUCIBLE"
else
    verdict=not_reproducible
    warn "VERDICT: NOT REPRODUCIBLE (${COUNTED} differing entries)"
fi
accepted="$(sed 's/^/  /' "${WORK_DIR}/cmp/accepted.txt")"
write_yaml "${verdict}" "Gem Wallet ${VERSION} (${MODE}, ${#LABELS[@]} APK(s)) vs tag ${TAG}, commit ${COMMIT}.
Build: BUILD_MODE=release SKIP_SIGN=true gradlew clean $([[ "${MODE}" == universal ]] && echo 'assembleUniversalRelease -PuseLegacyPackaging=true' || echo ':app:bundleGoogleRelease + bundletool'), toolchain pins read from the tag.
Compared: every ZIP entry by SHA-256 of its content. Differing entries: ${COUNTED}.${accepted:+
Accepted differences (excluded from the verdict):
${accepted}}"
results "${verdict}"
if [[ "${verdict}" == reproducible ]]; then
    echo "Exit code: 0"
    exit 0
fi
echo "Exit code: 1"
exit 1
