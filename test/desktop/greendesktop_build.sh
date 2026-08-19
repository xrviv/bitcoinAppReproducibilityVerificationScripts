#!/bin/bash
#
# greendesktop_build.sh - Blockstream Green Desktop (green_qt) Reproducible Build Verifier
#
# Version: v0.3.0
#
# Description:
#   Reproducible build verification for Blockstream Green Desktop Linux AppImage.
#   Builds green_qt and its full native dependency chain (GDK, LWK, GLSDK,
#   sentry-native/crashpad, countly, zxing, hidapi, libusb, kdsingleapplication,
#   libserialport, gpgme, leveldb) from source inside a single container image,
#   packages via upstream's own tools/appimage.sh, and compares the extracted
#   squashfs payload against the official release AppImage file-by-file.
#
#   Qt 6.11.0 is fetched as the official prebuilt via aqtinstall (token-free;
#   binary-equivalence to the official online-installer Qt was confirmed by
#   hash comparison during the 3.4.0 investigation). NOTE: upstream bumped Qt
#   to 6.11.1 for Windows/macOS CI in the 3.4.1 release and has kept the Linux
#   x86_64 Dockerfile (ci/linux-x86_64/Dockerfile) at 6.11.0 through 3.5.0 —
#   verified by diffing release_3.4.0..3.4.1 and release_3.4.1..3.5.0. The
#   6.11.1 PATH in ci/linux-x86_64.yml points at a directory that does not
#   exist in the image and is silently skipped. Do not bump this without
#   re-checking that specific Dockerfile at the target release tag.
#
#   From 3.5.0 the build mirrors upstream CI more closely: it drives
#   tools/ci/build.sh (qt-cmake --preset ci, --parallel 4) and packages with
#   tools/appimage.sh --plugin-qt, both taken from the pinned checkout. The
#   AppImage packaging tools are pinned and SHA256-checked by upstream's own
#   ci/linux-x86_64/download-appimage-binaries.sh, so this script no longer
#   carries its own pins.
#
#   Known upstream limitations (documented, not worked around):
#   - liblwk.so release builds are nondeterministic upstream
#     (https://github.com/Blockstream/lwk/issues/165)
#   - libglsdk.so (Greenlight SDK, added in 3.4.1) is a Rust cdylib; assumed
#     nondeterministic until upstream confirms otherwise (same pattern as liblwk)
#   - https://github.com/Blockstream/green_qt/issues/187 reported checkout-time
#     QML mtimes, an OpenSSL build timestamp, and unpinned 'continuous' AppImage
#     tools. As of 3.5.0 upstream has addressed the mtimes (SOURCE_DATE_EPOCH +
#     git ls-files touch, replicated below) and the tool pinning (SHA256 checks).
#     The OpenSSL timestamp is unconfirmed either way at 3.5.0 — check the diff.
#   A not_reproducible verdict is still expected while lwk#165 is open; the diff
#   files this script produces are the evidence for human review.
#
# Usage:
#   greendesktop_build.sh --version VERSION [--arch x86_64-linux-gnu] [--type appimage]
#   greendesktop_build.sh --binary /path/to/Blockstream-x86_64.AppImage [--version VERSION]
#
# Only host requirement: podman or docker. No credentials needed.
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#

set -euo pipefail

SCRIPT_VERSION="v0.3.0"
APP_ID="blockstreamgreen"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

GREEN_REPO="https://github.com/Blockstream/green_qt"
APPIMAGE_NAME="Blockstream-x86_64.AppImage"
SUPPORTED_ARCH="x86_64-linux-gnu"
SUPPORTED_TYPE="appimage"

# AppImage packaging tools are pinned and SHA256-verified by upstream's own
# ci/linux-x86_64/download-appimage-binaries.sh, run in the final image stage
# and taken from the pinned checkout. This script carries no pins of its own.
# NOTE: upstream fetches those tools from the rolling 'continuous' release tag
# and verifies recorded hashes. If the continuous assets are rebuilt upstream,
# that hash check fails and the image build FTBFSes — which is the correct,
# loud failure. Hashes recorded at release_3.5.0 were confirmed live 2026-08-19.

APP_VERSION=""
APP_ARCH="${SUPPORTED_ARCH}"
APP_TYPE="${SUPPORTED_TYPE}"
BINARY_PATH=""
NO_CACHE=false
KEEP_WORKDIR=true
DOCKER_CMD="${DOCKER_CMD:-}"
WORK_DIR=""
IMAGE_TAG=""
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_fail() { echo "[FAIL] $*" >&2; }

write_yaml() {
    # COMPARISON_RESULTS.yaml: exactly 3 fields (script_version, verdict, notes)
    local verdict="$1"
    local notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        if [[ -n "${notes}" ]]; then
            echo "notes: |"
            echo "${notes}" | sed 's/^/  /'
        fi
    } > "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    log_info "COMPARISON_RESULTS.yaml written to ${SCRIPT_DIR}"
}

on_error() {
    local rc=$?
    trap - ERR
    log_fail "Script failed (exit ${rc}). See output above."
    write_yaml "ftbfs" "Build or comparison step failed before a verdict could be computed. Work dir: ${WORK_DIR:-unset}"
    cleanup_image
    exit "${EXIT_BUILD_FAILED}"
}
trap on_error ERR

cleanup_image() {
    # Remove run-specific tag only; layer cache is preserved for future runs.
    if [[ -n "${IMAGE_TAG}" ]] && [[ -n "${DOCKER_CMD}" ]]; then
        "${DOCKER_CMD}" rmi "${IMAGE_TAG}" >/dev/null 2>&1 || true
    fi
}

die_invalid() {
    log_fail "$1"
    exit "${EXIT_INVALID_PARAMS}"
}

require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "${value}" || "${value}" == --* ]]; then
        die_invalid "Missing value for parameter: ${flag}"
    fi
}

detect_container_cmd() {
    if [[ -n "${DOCKER_CMD}" ]]; then return; fi
    if command -v podman >/dev/null 2>&1; then
        DOCKER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    else
        die_invalid "Neither podman nor docker found in PATH (only host requirement)"
    fi
    log_info "Container engine: ${DOCKER_CMD}"
}

usage() {
    cat <<USAGE
greendesktop_build.sh ${SCRIPT_VERSION} - Blockstream Green Desktop reproducible build verifier

Usage:
  $0 --version VERSION [--arch x86_64-linux-gnu] [--type appimage]
  $0 --binary /path/to/${APPIMAGE_NAME} [--version VERSION]

Parameters:
  --version VERSION   App version without 'v' prefix (e.g. 3.4.0).
                      Source ref used: release_VERSION tag.
  --binary FILE       Path to the official AppImage to verify. When provided,
                      the GitHub download step is skipped. If --version is
                      omitted, the script attempts to detect it from the file.
  --arch ARCH         Target architecture. Only ${SUPPORTED_ARCH} is supported.
  --type TYPE         Artifact type. Only ${SUPPORTED_TYPE} is supported.
  --apk FILE          Android-only parameter; accepted as alias for --binary.
  --no-cache          Build the container image without cache.
  --help              This help.

Exit codes: 0 = reproducible, 1 = not reproducible / build failure, 2 = invalid parameters.
Build time: roughly 60-120 minutes on first run (GDK dominates); cached reruns are much faster.
Disk: ~25-30 GB for the image build.
USAGE
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        usage
        exit "${EXIT_INVALID_PARAMS}"
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) require_value "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
            --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --apk)
                log_warn "--apk is an Android parameter; treating it as --binary"
                require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --no-cache) NO_CACHE=true; shift ;;
            --help|-h) usage; exit "${EXIT_SUCCESS}" ;;
            *)
                log_warn "Unknown argument: $1 (ignored)"
                shift ;;
        esac
    done

    if [[ "${APP_ARCH}" != "${SUPPORTED_ARCH}" ]]; then
        die_invalid "Unsupported --arch '${APP_ARCH}' (only ${SUPPORTED_ARCH})"
    fi
    if [[ -n "${APP_TYPE}" && "${APP_TYPE}" != "${SUPPORTED_TYPE}" ]]; then
        die_invalid "Unsupported --type '${APP_TYPE}' (only ${SUPPORTED_TYPE})"
    fi
    if [[ -z "${APP_VERSION}" && -z "${BINARY_PATH}" ]]; then
        die_invalid "Need --version and/or --binary"
    fi
    if [[ -n "${BINARY_PATH}" && ! -f "${BINARY_PATH}" ]]; then
        die_invalid "--binary file not found: ${BINARY_PATH}"
    fi
}

# ----------------------------------------------------------------------------
# Version detection from provided binary (containerized; used only when
# --binary is given without --version; ABS always passes --version)
# ----------------------------------------------------------------------------

detect_version_from_binary() {
    log_info "Detecting version from provided AppImage (in container)..."
    local detected
    detected="$("${DOCKER_CMD}" run --rm -v "${BINARY_PATH}:/in/app.AppImage:ro" \
        docker.io/library/ubuntu:jammy bash -c '
        set -e
        cd /tmp
        cp /in/app.AppImage .
        chmod +x app.AppImage
        export APPIMAGE_EXTRACT_AND_RUN=1
        ./app.AppImage --appimage-extract >/dev/null 2>&1
        desktop_file=$(find squashfs-root -maxdepth 1 -name "*.desktop" | head -1)
        ver=""
        [ -n "$desktop_file" ] && ver=$(grep -o "X-AppImage-Version=.*" "$desktop_file" | cut -d= -f2 | head -1)
        echo "${ver}"
    ' 2>/dev/null || true)"
    detected="$(echo "${detected}" | tr -d '[:space:]')"
    if [[ -n "${detected}" ]]; then
        APP_VERSION="${detected}"
        log_info "Detected version: ${APP_VERSION}"
    else
        die_invalid "Could not detect version from binary; pass --version explicitly"
    fi
}

# ----------------------------------------------------------------------------
# Inline Dockerfile (mirrors upstream ci/linux-x86_64/Dockerfile at the release
# ref, with two WS modifications: source cloned at the pinned ref inside the
# image, and Qt via aqtinstall instead of the JWT-gated online installer)
# ----------------------------------------------------------------------------

write_dockerfile() {
    cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
ARG GREEN_REF=master
FROM docker.io/library/ubuntu:jammy AS src
ARG GREEN_REF
RUN apt-get update -qq && apt-get install -yqq --no-install-recommends git ca-certificates
RUN git clone https://github.com/Blockstream/green_qt /green_qt && \
    cd /green_qt && \
    git checkout "${GREEN_REF}" && \
    git rev-parse HEAD > /green_qt_commit.txt && cat /green_qt_commit.txt

FROM docker.io/library/ubuntu:jammy AS base0
COPY --from=src /green_qt/ci/linux-x86_64/setup.sh .
RUN ./setup.sh
ENV PREFIX=/depends/linux-x86_64
ENV HOST=linux
ENV ARCH=x86_64
ENV PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
ENV CMAKE_INSTALL_PREFIX=$PREFIX

FROM base0 AS base
# WS modification: aqtinstall fetches the same prebuilt Qt packages token-free.
RUN python3 -m venv /aqt-venv && \
    /aqt-venv/bin/pip install --no-cache-dir aqtinstall==3.3.0 && \
    /aqt-venv/bin/aqt install-qt linux desktop 6.11.0 linux_gcc_64 --outputdir /qt \
      -m qtwebengine qt5compat qtconnectivity qtmultimedia qtserialport qtpositioning qtwebview qtwebchannel
ENV PATH="/qt/6.11.0/gcc_64/bin/:$PATH"

FROM base AS hidapi
COPY --from=src /green_qt/tools/buildlibusb.sh /green_qt/tools/buildhidapi.sh tools/
RUN tools/buildlibusb.sh && tools/buildhidapi.sh

FROM base AS countly
COPY --from=src /green_qt/tools/buildcountly.sh tools/
RUN tools/buildcountly.sh

FROM base AS gdk
COPY --from=src /green_qt/tools/buildgdk.sh tools/
RUN . /root/.cargo/env && tools/buildgdk.sh --static

FROM base AS zxing
COPY --from=src /green_qt/tools/buildzxing.sh tools/
RUN tools/buildzxing.sh

FROM base AS kdsa
COPY --from=src /green_qt/tools/buildkdsingleapplication.sh tools/
RUN tools/buildkdsingleapplication.sh

FROM base AS libserialport
COPY --from=src /green_qt/tools/buildlibserialport.sh tools/
RUN tools/buildlibserialport.sh --disable-shared

FROM base AS sentry
COPY --from=gdk /build/gdk/build-gcc/external_deps/ /depends/linux-x86_64/
ENV OPENSSL_ROOT_DIR=$PREFIX
COPY --from=src /green_qt/tools/buildlibcurl.sh tools/
RUN tools/buildlibcurl.sh
ENV CMAKE_PREFIX_PATH=$PREFIX
COPY --from=src /green_qt/tools/patches/ tools/patches/
COPY --from=src /green_qt/tools/buildsentry.sh tools/
RUN tools/buildsentry.sh

FROM base AS gpgme
COPY --from=src /green_qt/tools/buildgpgme.sh tools/
RUN tools/buildgpgme.sh

FROM base AS leveldb
COPY --from=src /green_qt/tools/buildleveldb.sh tools/
RUN tools/buildleveldb.sh

FROM base AS lwk
COPY --from=src /green_qt/tools/buildlwk.sh tools/
RUN . /root/.cargo/env && tools/buildlwk.sh

FROM base AS glsdk
COPY --from=src /green_qt/tools/buildglsdk.sh tools/
RUN . /root/.cargo/env && tools/buildglsdk.sh --verbose

FROM base
COPY --from=hidapi /depends /depends
COPY --from=countly /depends /depends
COPY --from=zxing /depends /depends
COPY --from=gdk /depends /depends
COPY --from=kdsa /depends /depends
COPY --from=libserialport /depends /depends
COPY --from=sentry /depends /depends
COPY --from=gpgme /depends /depends
COPY --from=leveldb /depends /depends
COPY --from=lwk /depends /depends
COPY --from=glsdk /depends /depends
COPY --from=src /green_qt /green_qt
COPY --from=src /green_qt_commit.txt /green_qt_commit.txt
# Upstream's own pinned + SHA256-checked AppImage tools; tools/appimage.sh
# expects them at image root (it does `cp /linuxdeploy-x86_64.AppImage .`).
COPY --from=src /green_qt/ci/linux-x86_64/download-appimage-binaries.sh .
RUN ./download-appimage-binaries.sh
COPY inner_build.sh /usr/local/bin/inner_build.sh
RUN chmod +x /usr/local/bin/inner_build.sh
DOCKERFILE_EOF
}

# ----------------------------------------------------------------------------
# Inner script (runs inside the container; does download/verify, SENTRY_KEY
# extraction, clean clone + build, packaging, extraction and diff)
# ----------------------------------------------------------------------------

write_inner_script() {
    cat > "${WORK_DIR}/inner_build.sh" <<'INNER_EOF'
#!/bin/bash
# Runs inside the build image. Inputs (env): GREEN_VERSION, GITHUB_TOKEN (optional).
# /out must be mounted; if /out/official-<name> exists it is used (user-provided
# --binary), otherwise the official AppImage is downloaded from GitHub releases.
# AppImage packaging tools are already baked into the image at / by upstream's
# ci/linux-x86_64/download-appimage-binaries.sh (pinned + SHA256-checked there).
set -euo pipefail

OUT=/out
APPIMAGE_NAME="Blockstream-x86_64.AppImage"
RELEASE_URL="https://github.com/Blockstream/green_qt/releases/download/release_${GREEN_VERSION}"
export APPIMAGE_EXTRACT_AND_RUN=1
AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

echo "[BUILD] qt-cmake: $(command -v qt-cmake)"

# --- [1/6] official AppImage ---
cd "${OUT}"
if [ ! -f "official-${APPIMAGE_NAME}" ]; then
    echo "[BUILD] Downloading official AppImage (release_${GREEN_VERSION})..."
    curl -fL "${AUTH_ARGS[@]}" -o "official-${APPIMAGE_NAME}" "${RELEASE_URL}/${APPIMAGE_NAME}"
    curl -fL "${AUTH_ARGS[@]}" -O "${RELEASE_URL}/SHA256SUMS.asc"
    expected_sha="$(grep "${APPIMAGE_NAME}" SHA256SUMS.asc | grep -o '^[0-9a-f]\{64\}' || true)"
    actual_sha="$(sha256sum "official-${APPIMAGE_NAME}" | cut -d' ' -f1)"
    echo "[BUILD] official sha256: ${actual_sha} (SHA256SUMS.asc: ${expected_sha:-UNPARSED})"
    if [ -n "${expected_sha}" ] && [ "${expected_sha}" != "${actual_sha}" ]; then
        echo "[BUILD] FAIL: official AppImage sha256 mismatch vs SHA256SUMS.asc"; exit 1
    fi
else
    echo "[BUILD] Using provided official AppImage"
fi

# --- [2/6] extract official + sentry DSN (key + project) ---
rm -rf official-extracted squashfs-root
chmod +x "official-${APPIMAGE_NAME}"
"./official-${APPIMAGE_NAME}" --appimage-extract >/dev/null
mv squashfs-root official-extracted
bin_path="official-extracted/usr/bin/blockstream"
[ -f "${bin_path}" ] || bin_path="$(find official-extracted -name blockstream -type f | head -1 || true)"
# From 3.5.0 the app needs BOTH SENTRY_KEY and SENTRY_PROJECT: cmake/AppOptions.cmake
# FATAL_ERRORs if either is empty while ENABLE_SENTRY=ON. src/main.cpp builds the DSN
# from three adjacent string literals, which the compiler folds into one constant:
#   "https://" SENTRY_KEY "@sentry.blockstream.io/" SENTRY_PROJECT
# so a single regex over `strings` recovers both.
SENTRY_DSN="$(strings "${bin_path}" 2>/dev/null | grep -oE 'https://[0-9a-zA-Z]+@sentry\.blockstream\.io/[0-9A-Za-z._-]+' | head -1 || true)"
SENTRY_KEY=""
SENTRY_PROJECT=""
if [ -n "${SENTRY_DSN}" ]; then
    SENTRY_KEY="${SENTRY_DSN#https://}"; SENTRY_KEY="${SENTRY_KEY%%@*}"
    SENTRY_PROJECT="${SENTRY_DSN##*/}"
fi
# Pre-3.5.0 fallback: older binaries carried a bare `sentry_key=` string.
if [ -z "${SENTRY_KEY}" ]; then
    SENTRY_KEY="$(strings "${bin_path}" 2>/dev/null | grep -o 'sentry_key=[^",) ]*' | head -1 | cut -d= -f2 || true)"
fi
if [ -n "${SENTRY_KEY}" ] && [ -n "${SENTRY_PROJECT}" ]; then
    echo "[BUILD] SENTRY_KEY + SENTRY_PROJECT extracted from official binary (project=${SENTRY_PROJECT})"
    export ENABLE_SENTRY_BUILD=1
elif [ -n "${SENTRY_KEY}" ]; then
    echo "[BUILD] WARNING: SENTRY_KEY found but SENTRY_PROJECT missing; cmake would FATAL_ERROR."
    echo "[BUILD] WARNING: building ENABLE_SENTRY=OFF (will not match official)"
    export ENABLE_SENTRY_BUILD=0
else
    echo "[BUILD] WARNING: no sentry DSN found; building ENABLE_SENTRY=OFF (will not match official)"
    export ENABLE_SENTRY_BUILD=0
fi

# --- [3/6] clean clone + cmake build (release config from .gitlab-ci.yml) ---
# --no-hardlinks: plain local clone fails on overlayfs ("hardlink different
# from source"); discovered during the 3.4.0 phase-1 run on the build server.
rm -rf /work
mkdir -p /work
git config --global --add safe.directory /green_qt
git clone --no-hardlinks /green_qt /work/green_qt
cd /work/green_qt
expected_commit="$(cat /green_qt_commit.txt)"
actual_commit="$(git rev-parse HEAD)"
if [ "${expected_commit}" != "${actual_commit}" ]; then
    echo "[BUILD] FAIL: commit mismatch (expected ${expected_commit}, got ${actual_commit})"; exit 1
fi
echo "${actual_commit}" > "${OUT}/commit.txt"
echo "[BUILD] Source commit: ${actual_commit}"
export CMAKE_PREFIX_PATH="${PREFIX}"
export PATH="${PREFIX}/bin:${PATH}"

# Upstream CI normalises all tracked file mtimes to the release commit timestamp
# before building (ci/linux-x86_64.yml build-appimage job). This is upstream's fix
# for the checkout-time QML mtimes reported in green_qt#187 — replicate it exactly
# or the packaged QML will carry our clone times instead.
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
git ls-files -z | xargs -0 touch -d "@${SOURCE_DATE_EPOCH}"
echo "[BUILD] SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ'))"

# Drive upstream's own build entrypoint rather than re-deriving its flags.
# tools/ci/build.sh derives GREEN_ENV=Production and GREEN_BUILD_ID='' from a
# release_* ref, then runs `qt-cmake --preset ci` + `cmake --build build --parallel 4`.
# The ci preset reads GREEN_LOG_FILE from CI_COMMIT_BRANCH, which is empty on a tag
# pipeline. --parallel 4 is upstream's value and is kept deliberately: job count is a
# plausible codegen-ordering input, so it is matched rather than assumed harmless.
export CI_COMMIT_REF_NAME="release_${GREEN_VERSION}"
export CI_COMMIT_BRANCH=""
export SENTRY_KEY SENTRY_PROJECT
if [ "${ENABLE_SENTRY_BUILD}" = "1" ]; then
    tools/ci/build.sh
else
    # Same preset, sentry forced off because the DSN could not be recovered.
    export GREEN_ENV=Production
    export GREEN_BUILD_ID=""
    qt-cmake --preset ci -DENABLE_SENTRY=OFF
    cmake --build build --parallel 4
fi
mv build/blockstream .

# --- [4/6] AppImage packaging via upstream's own tools/appimage.sh ---
# From 3.5.0 this also bundles crashpad_handler as a second --executable and copies
# the shared libcurl next to it (crashpad's uploader dlopen()s libcurl.so.4, so it is
# not a NEEDED dep and linuxdeploy will not pick it up by itself). Hand-rolling the
# linuxdeploy invocation would silently omit both. The three packaging tools are
# already at image root, pinned and SHA256-checked by upstream's downloader script.
tools/appimage.sh --plugin-qt /work/green_qt
cp "${APPIMAGE_NAME}" "${OUT}/built-${APPIMAGE_NAME}"

# --- [5/6] extraction + comparison ---
cd "${OUT}"
rm -rf built-extracted squashfs-root
chmod +x "built-${APPIMAGE_NAME}"
"./built-${APPIMAGE_NAME}" --appimage-extract >/dev/null
mv squashfs-root built-extracted

diff -r official-extracted built-extracted > diff-appimage-payload.txt 2>&1 || true
(cd official-extracted && find . -printf '%M %y %p -> %l\n' | sort) > meta-official.txt
(cd built-extracted && find . -printf '%M %y %p -> %l\n' | sort) > meta-built.txt
diff meta-official.txt meta-built.txt > diff-appimage-metadata.txt 2>&1 || true

# --- [6/6] machine-readable result ---
{
    echo "OFFICIAL_SHA256=$(sha256sum "official-${APPIMAGE_NAME}" | cut -d' ' -f1)"
    echo "BUILT_SHA256=$(sha256sum "built-${APPIMAGE_NAME}" | cut -d' ' -f1)"
    echo "PAYLOAD_DIFF_LINES=$(wc -l < diff-appimage-payload.txt)"
    echo "METADATA_DIFF_LINES=$(wc -l < diff-appimage-metadata.txt)"
    echo "COMMIT=$(cat commit.txt)"
} > RESULT.env
echo "[BUILD] inner build complete"
INNER_EOF
    chmod +x "${WORK_DIR}/inner_build.sh"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    parse_arguments "$@"
    detect_container_cmd

    if [[ -z "${APP_VERSION}" ]]; then
        detect_version_from_binary
    fi

    local safe_ver execution_dir
    safe_ver="$(echo "${APP_VERSION}" | tr -c 'a-zA-Z0-9.' '-' | sed 's/-*$//')"
    execution_dir="$(pwd)"
    WORK_DIR="$(mktemp -d "${execution_dir}/greendesktop_${safe_ver}_${APP_ARCH}_XXXXXX")"
    mkdir -p "${WORK_DIR}/out"
    log_info "Script version: ${SCRIPT_VERSION}"
    log_info "App: ${APP_ID} ${APP_VERSION} (${APP_ARCH}, ${APP_TYPE})"
    log_info "Work dir: ${WORK_DIR}"

    if [[ -n "${BINARY_PATH}" ]]; then
        cp "${BINARY_PATH}" "${WORK_DIR}/out/official-${APPIMAGE_NAME}"
        log_info "Using provided binary as official artifact: ${BINARY_PATH}"
    fi

    write_dockerfile
    write_inner_script

    IMAGE_TAG="greendesktop-build-$$-$(date +%s):${safe_ver}"
    local build_args=(--build-arg "GREEN_REF=release_${APP_VERSION}")
    [[ "${NO_CACHE}" == true ]] && build_args+=(--no-cache)
    log_info "Building container image ${IMAGE_TAG} (first run: ~60-120 min; GDK dominates)..."
    "${DOCKER_CMD}" build -t "${IMAGE_TAG}" "${build_args[@]}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}"

    log_info "Running build + comparison in container..."
    "${DOCKER_CMD}" run --rm \
        -v "${WORK_DIR}/out:/out" \
        -e GREEN_VERSION="${APP_VERSION}" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN}" \
        "${IMAGE_TAG}" /usr/local/bin/inner_build.sh

    # ---- verdict ----
    local out="${WORK_DIR}/out"
    [[ -f "${out}/RESULT.env" ]] || { log_fail "RESULT.env missing"; exit "${EXIT_BUILD_FAILED}"; }
    # shellcheck disable=SC1091
    source "${out}/RESULT.env"

    local verdict
    if [[ "${PAYLOAD_DIFF_LINES}" -eq 0 ]]; then
        verdict="reproducible"
    else
        verdict="not_reproducible"
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         Blockstream (GitHub release)"
    echo "versionName:    ${APP_VERSION}"
    echo "arch:           ${APP_ARCH}"
    echo "type:           ${APP_TYPE}"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${OFFICIAL_SHA256}"
    echo "builtHash:      ${BUILT_SHA256}"
    echo "commit:         ${COMMIT}"
    echo ""
    echo "Payload diff: ${PAYLOAD_DIFF_LINES} line(s) (full: ${out}/diff-appimage-payload.txt)"
    if [[ "${PAYLOAD_DIFF_LINES}" -gt 0 ]]; then
        echo "Diff preview (first 5 of ${PAYLOAD_DIFF_LINES} line(s)):"
        head -5 "${out}/diff-appimage-payload.txt"
    fi
    echo "Metadata diff (modes/types/symlinks): ${METADATA_DIFF_LINES} line(s) (full: ${out}/diff-appimage-metadata.txt)"
    echo "===== End Results ====="
    echo ""

    local notes="Payload compared file-by-file after --appimage-extract of both AppImages.
Full diffs: diff-appimage-payload.txt, diff-appimage-metadata.txt in ${out}.
Built with upstream's own tools/ci/build.sh and tools/appimage.sh from the pinned
checkout, with SOURCE_DATE_EPOCH mtime normalisation as upstream CI does it.
Known upstream nondeterminism: liblwk (Blockstream/lwk#165); libglsdk (Rust cdylib,
added in 3.4.1, assumed nondeterministic until upstream confirms otherwise). As of
3.5.0 upstream fixed the QML mtimes and pinned the AppImage tools it was asked about
in Blockstream/green_qt#187; the OpenSSL build timestamp from that issue is unconfirmed."
    write_yaml "${verdict}" "${notes}"
    cleanup_image

    log_info "Artifacts kept in ${WORK_DIR}/out (extracted trees, diffs, both AppImages, RESULT.env) — persistent, not /tmp"
    if [[ "${verdict}" == "reproducible" ]]; then
        exit "${EXIT_SUCCESS}"
    fi
    exit "${EXIT_BUILD_FAILED}"
}

main "$@"
