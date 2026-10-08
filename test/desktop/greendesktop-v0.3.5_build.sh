#!/bin/bash
# ==============================================================================
# greendesktop_build.sh - Blockstream Green Desktop (green_qt) Reproducible Build Verifier
# ==============================================================================
# Version:          v0.3.5
# Organization:     WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-09-25
# App ID:           blockstreamgreen
# Project:          https://github.com/Blockstream/green_qt
# Repository:       https://gitlab.com/walletscrutiny/walletScrutinyCom
# ==============================================================================
# IMPORTANT: DO NOT include a changelog in this header.
# ==============================================================================
#
# SCRIPT SUMMARY:
#   Reproducible build verification for the Blockstream Green Desktop Linux
#   AppImage. Builds green_qt and its full native dependency chain (GDK, LWK,
#   GLSDK, sentry-native/crashpad, countly, zxing, hidapi, libusb,
#   kdsingleapplication, libserialport, gpgme, leveldb) from source inside one
#   container image, packages via upstream's own tools/appimage.sh, and compares
#   the extracted squashfs payload against the official release AppImage
#   file-by-file.
#
#   The official AppImage is authenticated in the container before use: the
#   release's SHA256SUMS.asc is verified against Blockstream's release-signing
#   key, pinned by full fingerprint, and the AppImage hash must be listed in the
#   signed text. The outcome is printed in the results block.
#
#   Qt is fetched as the official prebuilt via aqtinstall (token-free;
#   binary-equivalence to the online-installer Qt was confirmed by hash during
#   the 3.4.0 investigation). The Qt version and module list are read from
#   upstream's ci/linux-x86_64/Dockerfile at the release tag. The build runs
#   with the versioned Qt path (/qt/<version>/gcc_64/bin) first on PATH, as
#   upstream's ENV PATH does. The image records its full dpkg package list
#   (build-image-packages.txt) so bundled Ubuntu system libraries can be
#   attributed to package revisions.
#
#   The build drives upstream's tools/ci/build.sh (qt-cmake --preset ci,
#   --parallel 4) and packages with tools/appimage.sh --plugin-qt, both from
#   the pinned checkout. The AppImage packaging tools are pinned and
#   SHA256-checked by upstream's ci/linux-x86_64/download-appimage-binaries.sh;
#   if those pins are stale the current continuous assets are used and every
#   substitution is reported per tool. The AppImage runtime stub is downloaded
#   once, SHA256-checked, and handed to appimagetool with --runtime-file.
#   The executable and every library as they were before linuxdeploy stripped
#   them are kept in the out dir (pre-packaging/).
#
#   Known upstream limitations (documented, not worked around):
#   - liblwk.so release builds are nondeterministic upstream
#     (https://github.com/Blockstream/lwk/issues/165)
#   - Build IDs depend on the checkout path baked into RelWithDebInfo debug
#     info at link time; upstream's CI path is not published.
#   A not_reproducible verdict is expected while lwk#165 is open; the diff
#   files this script produces are the evidence for human review.
#
# Usage:
#   greendesktop_build.sh --version VERSION [--arch x86_64-linux-gnu] [--type appimage]
#   greendesktop_build.sh --binary /path/to/Blockstream-x86_64.AppImage [--version VERSION]
#
# Only host requirement: podman or docker. No credentials needed.
# Exit codes: 0 = reproducible, 1 = not reproducible / build failure, 2 = invalid parameters.
# ==============================================================================

SCRIPT_VERSION="v0.3.5"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_HASH="$(sha256sum "${SCRIPT_PATH}" 2>/dev/null | cut -d' ' -f1)"
echo "$(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION} sha256:${SCRIPT_HASH:-unknown}"

set -euo pipefail

APP_ID="blockstreamgreen"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

GREEN_REPO="https://github.com/Blockstream/green_qt"
APPIMAGE_NAME="Blockstream-x86_64.AppImage"
SUPPORTED_ARCH="x86_64-linux-gnu"
SUPPORTED_TYPE="appimage"
# Base image pinned by digest: docker.io/library/ubuntu:jammy, linux/amd64 manifest as of 2026-09-25.
BASE_IMAGE="docker.io/library/ubuntu@sha256:281c5745f657873d78e5531fc5ba8575f46ab7769b94550ac99543f122679986"
# Blockstream's release-signing key ("GreenAddress Team <info@greenaddress.it>"), full fingerprint.
# SHA256SUMS.asc of every release_* is a clearsigned message from this key.
SIGNING_KEY_FPR="04BEBF2E35A2AF2FFDF1FA5DE7F054AA2E76E792"
# AppImage type2 runtime stub that appimagetool embeds; continuous asset as of 2026-09-25.
# appimagetool downloads it unchecked unless given --runtime-file, so it is fetched here with a hash check.
APPIMAGE_RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"
APPIMAGE_RUNTIME_SHA256="1cc49bcf1e2ccd593c379adb17c9f85a36d619088296504de95b1d06215aebbf"

# AppImage packaging tools are pinned and SHA256-verified by upstream's own
# ci/linux-x86_64/download-appimage-binaries.sh, run in the final image stage
# from the pinned checkout. Upstream fetches them from rolling 'continuous'
# release tags that get rebuilt, so the pins go stale; upstream CI never re-runs
# the check because it builds from a prebuilt image (LINUX_IMAGE digest in
# ci/linux-x86_64.yml). The script tries upstream's pinned check first and only
# then falls back to the current continuous assets. Per tool, the pinned hash,
# the hash used and the tool's own version line are recorded and printed in the
# results block. The fallback can only cause spurious packaging diffs (false
# not_reproducible), never a false reproducible: the payload comparison itself
# never runs through these tools.

APP_VERSION=""
APP_ARCH="${SUPPORTED_ARCH}"
APP_TYPE="${SUPPORTED_TYPE}"
BINARY_PATH=""
NO_CACHE=false
DOCKER_CMD="${DOCKER_CMD:-}"
WORK_DIR=""
IMAGE_TAG=""
OWNER=""
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

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

print_results_header() {
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         Blockstream (GitHub release)"
    echo "versionName:    ${APP_VERSION:-unknown}"
    echo "arch:           ${APP_ARCH}"
    echo "type:           ${APP_TYPE}"
    echo "verdict:        $1"
    echo "appHash:        ${OFFICIAL_SHA256:-unknown}"
    echo "builtHash:      ${BUILT_SHA256:-unknown}"
    echo "commit:         ${COMMIT:-unknown}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_HASH:-unknown}"
    [[ -n "${SIGNATURE:-}" ]] && echo "signature:      ${SIGNATURE}"
    return 0
}

# Every failure path: reason printed, YAML written with verdict ftbfs, results block with what is known.
fail() {
    local code="$1"; local reason="$2"
    trap - ERR
    log_fail "${reason}"
    write_yaml "ftbfs" "${reason}"
    print_results_header "ftbfs"
    echo ""
    echo "NOT BUILT: ${reason}"
    echo "===== End Results ====="
    exit "${code}"
}

on_error() {
    local rc=$?
    # shellcheck disable=SC1091
    [[ -n "${WORK_DIR}" && -f "${WORK_DIR}/out/RESULT.env" ]] && source "${WORK_DIR}/out/RESULT.env"
    fail "${EXIT_BUILD_FAILED}" "Build or comparison step failed (exit ${rc}) before a verdict could be computed; see the output above. Work dir: ${WORK_DIR:-unset}"
}
trap on_error ERR

cleanup_image() {
    # Remove run-specific tag only; layer cache is preserved for future runs.
    if [[ -n "${IMAGE_TAG}" ]] && [[ -n "${DOCKER_CMD}" ]]; then
        "${DOCKER_CMD}" rmi "${IMAGE_TAG}" >/dev/null 2>&1 || true
    fi
}

# The build container runs as root and writes into the bind-mounted out dir.
# On success and on every failure, give the files back to the caller:
# rootless podman maps container root to the caller (0:0 inside), rootful
# docker needs the caller's real ids.
chown_back() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${DOCKER_CMD}" && -n "${OWNER}" ]]; then
        "${DOCKER_CMD}" run --rm -v "${WORK_DIR}:/t" "${BASE_IMAGE}" chown -R "${OWNER}" /t >/dev/null 2>&1 || true
    fi
}
on_exit() {
    chown_back
    cleanup_image
}
trap on_exit EXIT

die_invalid() {
    fail "${EXIT_INVALID_PARAMS}" "Invalid invocation: $1"
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
    if [[ "${DOCKER_CMD}" == *podman* ]]; then OWNER="0:0"; else OWNER="${HOST_UID}:${HOST_GID}"; fi
    log_info "Container engine: ${DOCKER_CMD}"
}

usage() {
    cat <<USAGE
$(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION} - Blockstream Green Desktop reproducible build verifier

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
        die_invalid "no parameters given"
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
            --help) usage; exit "${EXIT_SUCCESS}" ;;
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
        "${BASE_IMAGE}" bash -c '
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
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS src
ARG GREEN_REF
RUN apt-get update -qq && apt-get install -yqq --no-install-recommends git ca-certificates
RUN git clone https://github.com/Blockstream/green_qt /green_qt && \
    cd /green_qt && \
    git checkout "${GREEN_REF}" && \
    git rev-parse HEAD > /green_qt_commit.txt && cat /green_qt_commit.txt

FROM ${BASE_IMAGE} AS base0
COPY --from=src /green_qt/ci/linux-x86_64/setup.sh .
RUN ./setup.sh
ENV PREFIX=/depends/linux-x86_64
ENV HOST=linux
ENV ARCH=x86_64
ENV PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
ENV CMAKE_INSTALL_PREFIX=$PREFIX

FROM base0 AS base
# WS modification: aqtinstall fetches the same prebuilt Qt packages token-free.
# The Qt version and module list come from upstream's own Dockerfile at the pinned
# ref, so a Qt bump upstream is followed automatically (6.11.0 -> 6.11.1 at 3.5.3,
# 6.11.2 at 3.5.4). qtshadertools is appended because aqtinstall does not resolve
# transitive module dependencies, while upstream's online installer pulls it in on
# its own: libQt6ShaderTools.so.6 was present in the official AppImages and absent
# from our rebuilds until v0.3.1.
COPY --from=src /green_qt/ci/linux-x86_64/Dockerfile /upstream-linux-x86_64.Dockerfile
RUN set -e; \
    id="$(grep -oE 'qt\.qt6\.[0-9]+\.linux_gcc_64' /upstream-linux-x86_64.Dockerfile | head -n1 | cut -d. -f3)"; \
    if [ -z "$id" ]; then echo "[WS] no qt.qt6.NNNN.linux_gcc_64 id in upstream ci/linux-x86_64/Dockerfile" >&2; exit 1; fi; \
    major="${id%"${id#?}"}"; patch="${id#"${id%?}"}"; minor="${id#?}"; minor="${minor%?}"; \
    QT_VERSION="${major}.${minor}.${patch}"; \
    modules="$( { grep -oE "qt\.qt6\.${id}\.addons\.[a-z0-9]+" /upstream-linux-x86_64.Dockerfile | sed 's/.*\.addons\.//'; \
                 grep -oE "extensions\.[a-z0-9]+\.${id}\.linux_gcc_64" /upstream-linux-x86_64.Dockerfile | cut -d. -f2; \
                 echo qtshadertools; } | awk '!seen[$0]++' | tr '\n' ' ')"; \
    if ! grep -q "/qt/${QT_VERSION}/gcc_64/bin" /upstream-linux-x86_64.Dockerfile; then \
        echo "[WS] WARNING: upstream Dockerfile PATH does not mention /qt/${QT_VERSION}/gcc_64; installer ids say ${QT_VERSION}, using that" >&2; fi; \
    echo "[WS] Qt ${QT_VERSION} (from upstream ci/linux-x86_64/Dockerfile), modules: ${modules}"; \
    echo "${QT_VERSION}" > /qt-version.txt; echo "${modules}" > /qt-modules.txt; \
    python3 -m venv /aqt-venv && \
    /aqt-venv/bin/pip install --no-cache-dir aqtinstall==3.3.0 && \
    /aqt-venv/bin/aqt install-qt linux desktop "${QT_VERSION}" linux_gcc_64 --outputdir /qt -m ${modules} && \
    ln -s "/qt/${QT_VERSION}/gcc_64" /qt/current
ENV PATH="/qt/current/bin/:$PATH"

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
# The pins point at rolling 'continuous' assets that upstream rebuilds; when a
# rebuild makes a pin stale, fall back to the current assets and leave
# /appimage-tools-pins-stale as a marker. /appimage-tools-report.txt gets one
# line per tool: pinned hash, hash used, substituted or not, the tool's own
# version line.
COPY --from=src /green_qt/ci/linux-x86_64/download-appimage-binaries.sh .
RUN ./download-appimage-binaries.sh || ( \
      echo "[WS] WARNING: upstream AppImage tool pins are stale (continuous assets rebuilt upstream)" && \
      echo "[WS] Falling back to current continuous assets; per-tool report in appimage-tools-report.txt" && \
      rm -f linuxdeploy-x86_64.AppImage linuxdeploy-plugin-qt-x86_64.AppImage appimagetool-x86_64.AppImage && \
      curl -fsSL -o linuxdeploy-x86_64.AppImage https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage && \
      curl -fsSL -o linuxdeploy-plugin-qt-x86_64.AppImage https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage && \
      curl -fsSL -o appimagetool-x86_64.AppImage https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage && \
      chmod +x linuxdeploy-x86_64.AppImage linuxdeploy-plugin-qt-x86_64.AppImage appimagetool-x86_64.AppImage && \
      touch /appimage-tools-pins-stale \
    ) && \
    sha256sum linuxdeploy-x86_64.AppImage linuxdeploy-plugin-qt-x86_64.AppImage appimagetool-x86_64.AppImage | tee /appimage-tools-used.txt && \
    export APPIMAGE_EXTRACT_AND_RUN=1 && : > /appimage-tools-report.txt && \
    for t in linuxdeploy-x86_64.AppImage linuxdeploy-plugin-qt-x86_64.AppImage appimagetool-x86_64.AppImage; do \
      pinned="$(grep -oE "[0-9a-f]{64}  ${t}" download-appimage-binaries.sh | cut -c1-64 | head -n1)"; \
      used="$(sha256sum "${t}" | cut -c1-64)"; \
      if [ "${pinned}" = "${used}" ]; then state="matches pin"; else state="SUBSTITUTED"; fi; \
      ver="$( { "./${t}" --version; "./${t}" --plugin-version; } 2>&1 | grep -m1 -E "git (commit|version)" | tr -d '\r' || true)"; \
      echo "${t}: ${state}; pinned ${pinned:-none}; used ${used}; ${ver:-version line unavailable}" >> /appimage-tools-report.txt; \
    done && cat /appimage-tools-report.txt
# AppImage runtime stub: appimagetool fetches it from a rolling release URL without any
# hash check unless it is given --runtime-file. Fetch it once here, check it against the
# pin, and put a wrapper at the path tools/appimage.sh invokes, so upstream's packaging
# script runs unchanged but with the checked runtime. A stale runtime pin falls back to
# the current asset and is reported like a stale tool pin.
ARG APPIMAGE_RUNTIME_URL
ARG APPIMAGE_RUNTIME_SHA256
RUN curl -fsSL -o /appimage-runtime-x86_64 "${APPIMAGE_RUNTIME_URL}" && \
    used="$(sha256sum /appimage-runtime-x86_64 | cut -c1-64)" && \
    if [ "${used}" = "${APPIMAGE_RUNTIME_SHA256}" ]; then state="matches pin"; else state="SUBSTITUTED (pin stale, current asset used)"; touch /appimage-runtime-pin-stale; fi && \
    echo "runtime-x86_64: ${state}; pinned ${APPIMAGE_RUNTIME_SHA256}; used ${used}" | tee -a /appimage-tools-report.txt && \
    mv /appimagetool-x86_64.AppImage /appimagetool-real-x86_64.AppImage && \
    printf '%s\n' '#!/bin/sh' 'exec env TARGET_APPIMAGE=/appimagetool-real-x86_64.AppImage /appimagetool-real-x86_64.AppImage --runtime-file /appimage-runtime-x86_64 "$@"' > /appimagetool-x86_64.AppImage && \
    chmod +x /appimagetool-x86_64.AppImage
# Release-signing key for SHA256SUMS.asc, pinned by fingerprint. Fetched here so the
# inner build verifies offline; the import is checked against the pin.
ARG SIGNING_KEY_FPR
RUN apt-get update -qq && apt-get install -yqq --no-install-recommends gnupg && rm -rf /var/lib/apt/lists/* && \
    export GNUPGHOME=/release-key && mkdir -m 700 -p "${GNUPGHOME}" && \
    ( curl -fsSL -o /release-key.asc "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${SIGNING_KEY_FPR}" && \
      gpg --batch -q --import /release-key.asc ) || \
    gpg --batch -q --keyserver hkps://keyserver.ubuntu.com --recv-keys "${SIGNING_KEY_FPR}" && \
    gpg --batch --with-colons --fingerprint | grep -q "^fpr:::::::::${SIGNING_KEY_FPR}:" && \
    echo "[WS] release-signing key ${SIGNING_KEY_FPR} imported"
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
# Runs inside the build image. Inputs (env): GREEN_VERSION, SIGNING_KEY_FPR, GITHUB_TOKEN (optional).
# /out must be mounted; if /out/official-<name> exists it is used (user-provided
# --binary), otherwise the official AppImage is downloaded from GitHub releases.
# Either way the release's SHA256SUMS.asc is verified against the pinned key and
# the official file's hash must be listed in it.
set -euo pipefail

OUT=/out
APPIMAGE_NAME="Blockstream-x86_64.AppImage"
RELEASE_URL="https://github.com/Blockstream/green_qt/releases/download/release_${GREEN_VERSION}"
export APPIMAGE_EXTRACT_AND_RUN=1
export GNUPGHOME=/release-key
AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# Use the versioned Qt prefix, not the /qt/current symlink: the pre-packaging
# RUNPATH embeds this path and its length survives packaging as patchelf filler.
export PATH="/qt/$(cat /qt-version.txt)/gcc_64/bin:${PATH}"
echo "[BUILD] qt-cmake: $(command -v qt-cmake)"

# --- [1/6] official AppImage + release signature ---
cd "${OUT}"
if [ ! -f "official-${APPIMAGE_NAME}" ]; then
    echo "[BUILD] Downloading official AppImage (release_${GREEN_VERSION})..."
    curl -fL "${AUTH_ARGS[@]}" -o "official-${APPIMAGE_NAME}" "${RELEASE_URL}/${APPIMAGE_NAME}"
else
    echo "[BUILD] Using provided official AppImage"
fi
curl -fL "${AUTH_ARGS[@]}" -o SHA256SUMS.asc "${RELEASE_URL}/SHA256SUMS.asc"
actual_sha="$(sha256sum "official-${APPIMAGE_NAME}" | cut -d' ' -f1)"
# Verify the clearsigned SHA256SUMS.asc with the pinned key, then read the hash list
# from the verified text only (never from the unverified .asc).
SIGNATURE="FAILED"
rm -f SHA256SUMS.verified
status="$(gpg --batch --status-fd 1 --output SHA256SUMS.verified --decrypt SHA256SUMS.asc 2>/dev/null || true)"
sig_fpr="$(echo "${status}" | grep -oE 'VALIDSIG [0-9A-F]{40} .* [0-9A-F]{40}$' | awk '{print $NF}' | head -n1 || true)"
if echo "${status}" | grep -q '^\[GNUPG:\] GOODSIG' && [ "${sig_fpr}" = "${SIGNING_KEY_FPR}" ] && [ -s SHA256SUMS.verified ]; then
    expected_sha="$(grep -E "^[0-9a-f]{64}  (\./)?${APPIMAGE_NAME}$" SHA256SUMS.verified | cut -c1-64 | head -n1 || true)"
    if [ "${expected_sha}" = "${actual_sha}" ]; then
        SIGNATURE="verified (SHA256SUMS.asc signed by ${SIGNING_KEY_FPR}, ${APPIMAGE_NAME} listed)"
    elif [ -z "${expected_sha}" ]; then
        SIGNATURE="FAILED (signature good, but ${APPIMAGE_NAME} is not listed in the signed SHA256SUMS)"
    else
        SIGNATURE="FAILED (signature good, but official file sha256 ${actual_sha} is not the listed ${expected_sha})"
    fi
else
    SIGNATURE="FAILED (SHA256SUMS.asc signature not valid for key ${SIGNING_KEY_FPR})"
fi
echo "[BUILD] official sha256: ${actual_sha}"
echo "[BUILD] release signature: ${SIGNATURE}"
echo "SIGNATURE=\"${SIGNATURE}\"" > RESULT.env
case "${SIGNATURE}" in
    verified*) ;;
    *) echo "[BUILD] FAIL: official artifact not authenticated; no verdict without a verified official file"; exit 1 ;;
esac

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

# Keep the executable and every bundled library as they were before linuxdeploy
# copied, stripped and re-pathed them, so Build ID and RUNPATH questions can be
# answered from the pre-packaging files directly. Sources, in linuxdeploy's own
# order of precedence: the build tree, the dependency prefix, Qt, the system.
mkdir -p "${OUT}/pre-packaging"
cp -p blockstream "${OUT}/pre-packaging/blockstream"
[ -f build/crashpad_handler ] && cp -p build/crashpad_handler "${OUT}/pre-packaging/" || true
for f in "${PREFIX}"/bin/crashpad_handler; do [ -f "$f" ] && cp -p "$f" "${OUT}/pre-packaging/" || true; done
rm -rf /tmp/built-peek && mkdir -p /tmp/built-peek && (cd /tmp/built-peek && "${OUT}/built-${APPIMAGE_NAME}" --appimage-extract 'usr/lib/*' >/dev/null 2>&1 || true)
for so in /tmp/built-peek/squashfs-root/usr/lib/*; do
    [ -f "${so}" ] || continue
    name="$(basename "${so}")"
    for src in "${PREFIX}/lib/${name}" "/qt/$(cat /qt-version.txt)/gcc_64/lib/${name}" "/lib/x86_64-linux-gnu/${name}" "/usr/lib/x86_64-linux-gnu/${name}"; do
        if [ -e "${src}" ]; then cp -pL "${src}" "${OUT}/pre-packaging/${name}"; break; fi
    done
done
(cd "${OUT}/pre-packaging" && sha256sum -- * > SHA256SUMS && for f in *; do [ "$f" = SHA256SUMS ] && continue; printf '%s %s\n' "$f" "$(readelf -n "$f" 2>/dev/null | grep -oE 'Build ID: [0-9a-f]+' | cut -d' ' -f3)"; done > BUILD-IDS)
echo "[BUILD] pre-packaging copies kept: $(ls "${OUT}/pre-packaging" | wc -l) files"

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
cp /appimage-tools-used.txt "${OUT}/appimage-tools-used.txt"
cp /appimage-tools-report.txt "${OUT}/appimage-tools-report.txt"
cp /qt-version.txt "${OUT}/qt-version.txt"
dpkg-query -W -f '${binary:Package} ${Version}\n' | sort > "${OUT}/build-image-packages.txt"
TOOLS_PINS="upstream"
[ -f /appimage-tools-pins-stale ] && TOOLS_PINS="stale-fallback"
[ -f /appimage-runtime-pin-stale ] && TOOLS_PINS="${TOOLS_PINS}+runtime-stale"
{
    echo "SIGNATURE=\"${SIGNATURE}\""
    echo "OFFICIAL_SHA256=$(sha256sum "official-${APPIMAGE_NAME}" | cut -d' ' -f1)"
    echo "BUILT_SHA256=$(sha256sum "built-${APPIMAGE_NAME}" | cut -d' ' -f1)"
    echo "PAYLOAD_DIFF_LINES=$(wc -l < diff-appimage-payload.txt)"
    echo "METADATA_DIFF_LINES=$(wc -l < diff-appimage-metadata.txt)"
    echo "COMMIT=$(cat commit.txt)"
    echo "TOOLS_PINS=${TOOLS_PINS}"
    echo "QT_VERSION=$(cat /qt-version.txt)"
    echo "QT_MODULES=\"$(cat /qt-modules.txt)\""
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
    log_info "App: ${APP_ID} ${APP_VERSION} (${APP_ARCH}, ${APP_TYPE})"
    log_info "Work dir: ${WORK_DIR}"

    if [[ -n "${BINARY_PATH}" ]]; then
        cp "${BINARY_PATH}" "${WORK_DIR}/out/official-${APPIMAGE_NAME}"
        log_info "Using provided binary as official artifact: ${BINARY_PATH}"
    fi

    write_dockerfile
    write_inner_script

    IMAGE_TAG="greendesktop-build-$$-$(date +%s):${safe_ver}"
    local build_args=(--build-arg "GREEN_REF=release_${APP_VERSION}" --build-arg "BASE_IMAGE=${BASE_IMAGE}"
                      --build-arg "SIGNING_KEY_FPR=${SIGNING_KEY_FPR}"
                      --build-arg "APPIMAGE_RUNTIME_URL=${APPIMAGE_RUNTIME_URL}"
                      --build-arg "APPIMAGE_RUNTIME_SHA256=${APPIMAGE_RUNTIME_SHA256}")
    [[ "${NO_CACHE}" == true ]] && build_args+=(--no-cache)
    log_info "Building container image ${IMAGE_TAG} (first run: ~60-120 min; GDK dominates)..."
    "${DOCKER_CMD}" build -t "${IMAGE_TAG}" "${build_args[@]}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}"

    log_info "Running build + comparison in container..."
    "${DOCKER_CMD}" run --rm \
        -v "${WORK_DIR}/out:/out" \
        -e GREEN_VERSION="${APP_VERSION}" \
        -e SIGNING_KEY_FPR="${SIGNING_KEY_FPR}" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN}" \
        "${IMAGE_TAG}" /usr/local/bin/inner_build.sh

    # ---- verdict ----
    local out="${WORK_DIR}/out"
    [[ -f "${out}/RESULT.env" ]] || fail "${EXIT_BUILD_FAILED}" "RESULT.env missing: the container build did not reach the comparison"
    # shellcheck disable=SC1091
    source "${out}/RESULT.env"
    [[ -n "${BUILT_SHA256:-}" ]] || fail "${EXIT_BUILD_FAILED}" "No built AppImage recorded; release signature: ${SIGNATURE:-unknown}"

    local verdict
    if [[ "${PAYLOAD_DIFF_LINES}" -eq 0 ]]; then
        verdict="reproducible"
    else
        verdict="not_reproducible"
    fi

    print_results_header "${verdict}"
    echo "qt:             ${QT_VERSION:-unknown} (from upstream ci/linux-x86_64/Dockerfile at release_${APP_VERSION})"
    echo ""
    echo "Payload diff: ${PAYLOAD_DIFF_LINES} line(s) (full: ${out}/diff-appimage-payload.txt)"
    if [[ "${PAYLOAD_DIFF_LINES}" -gt 0 ]]; then
        echo "Diff preview (first 5 of ${PAYLOAD_DIFF_LINES} line(s)):"
        head -5 "${out}/diff-appimage-payload.txt"
    fi
    echo "Metadata diff (modes/types/symlinks): ${METADATA_DIFF_LINES} line(s) (full: ${out}/diff-appimage-metadata.txt)"
    echo "AppImage tools: ${TOOLS_PINS:-upstream}"
    sed 's/^/  /' "${out}/appimage-tools-report.txt"
    if [[ "${TOOLS_PINS:-upstream}" != "upstream" ]]; then
        echo "WARNING: a pinned packaging asset was stale (continuous asset rebuilt); the current"
        echo "         asset was used, see the SUBSTITUTED line(s) above. A payload diff limited to"
        echo "         bundled Qt/library selection may stem from that tool drift."
    fi
    echo "Pre-packaging copies: ${out}/pre-packaging (unstripped executable + libraries, SHA256SUMS, BUILD-IDS)"
    echo "===== End Results ====="
    echo ""

    local notes="Payload compared file-by-file after --appimage-extract of both AppImages.
Full diffs: diff-appimage-payload.txt, diff-appimage-metadata.txt in ${out}.
Built with upstream's own tools/ci/build.sh and tools/appimage.sh from the pinned
checkout, with SOURCE_DATE_EPOCH mtime normalisation as upstream CI does it.
Known upstream nondeterminism: liblwk (Blockstream/lwk#165).
Qt ${QT_VERSION:-unknown} prebuilt via aqtinstall, version and modules taken from upstream's
ci/linux-x86_64/Dockerfile at release_${APP_VERSION} (modules: ${QT_MODULES:-unknown}).
Release signature: ${SIGNATURE:-unknown}.
AppImage packaging tools: ${TOOLS_PINS:-upstream} (per-tool pinned/used hashes in
appimage-tools-report.txt in ${out}). Pre-packaging executable and libraries kept
in ${out}/pre-packaging."
    if [[ "${TOOLS_PINS:-upstream}" != "upstream" ]]; then
        notes="${notes}
WARNING: a pinned packaging asset (upstream's rolling 'continuous' tool pins, or this
script's runtime-stub pin) was stale at run time, so the current asset was used instead.
Upstream CI does not hit this because it builds from a prebuilt image created while
its pins were fresh."
    fi
    write_yaml "${verdict}" "${notes}"

    log_info "Artifacts kept in ${WORK_DIR}/out (extracted trees, diffs, both AppImages, RESULT.env) — persistent, not /tmp"
    if [[ "${verdict}" == "reproducible" ]]; then
        exit "${EXIT_SUCCESS}"
    fi
    exit "${EXIT_BUILD_FAILED}"
}

main "$@"
