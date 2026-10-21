#!/usr/bin/env bash
# ==============================================================================
# freewalletdesktop-v0.5.6_build.sh - FreeWallet Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.5.6
# Organization:  WalletScrutiny.com
# Project:       https://github.com/jdogresorg/freewallet-desktop
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-21
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/desktop/freewalletdesktop/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# Please examine this script yourself prior to running it.
# This script is provided as-is without warranty and may contain bugs or
# security vulnerabilities. Running this script will execute Docker containers,
# download source code, and perform deterministic builds that may consume
# significant system resources (CPU, memory, disk space).
# Use at your own risk and ensure you understand what the script does before
# execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Downloads the official FreeWallet.<arch>.tgz and checksums.txt from the GitHub release
#   (or uses the file given with --binary)
# - Clones the release tag inside a container
# - Builds the app with the NW.js SDK and the nwjs-ffmpeg-prebuilt libffmpeg.so the
#   upstream README asks for (both checksum-verified) in node:20-bullseye (digest-pinned)
# - Packages FreeWallet/ as a tarball and compares its sha256 with the official one
# - On a mismatch, lists every differing file (5-line preview, full list in diff_full.txt)
# - Writes COMPARISON_RESULTS.yaml next to the script
# ==============================================================================

set -euo pipefail

NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
SUCCESS_ICON="[OK]"
INFO_ICON="[INFO]"

APP_NAME="FreeWallet Desktop"
APP_ID="freewallet"
SCRIPT_VERSION="v0.5.6"
REPO_URL="https://github.com/jdogresorg/freewallet-desktop"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
YAML_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
# debian:bookworm-slim, pinned by index digest
HELPER_IMAGE="docker.io/library/debian@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

log_info() { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Never fatal: a hashing problem is not a build outcome.
sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

# Self-identification before anything else.
SCRIPT_SHA256="$(sha256_of "${SCRIPT_PATH}")"
log_info "Script:  $(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION}"
log_info "         sha256: ${SCRIPT_SHA256}"

# A stale verdict from an earlier run must never be read as this run's,
# including when this run stops early (help, invalid input, root).
rm -f "${YAML_FILE}"

# Parameter problems: exit 2 and no verdict (ABS publishes any YAML it finds).
die_invalid() {
    log_error "$1"
    exit "${EXIT_INVALID}"
}

# 3-field format read by the build server.
write_yaml() {
    local verdict="$1" notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        echo "notes: |"
        printf '%s\n' "${notes}" | sed 's/^/  /'
    } > "${YAML_FILE}"
}

# ---------- Help ----------
show_help() {
    cat <<EOF
${APP_NAME} - Reproducible Build Verification Script
Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com

USAGE:
    $0 --version <version> [--arch <arch>] [--type tarball] [--binary <file|dir>]

REQUIRED:
    --version <version>   App version to verify, without the v prefix (e.g., 2.0.4)

OPTIONAL:
    --arch <arch>         x86_64-linux-gnu (default; aliases: x86_64-linux, linux64)
    --type <type>         tarball (default; the only type this script builds)
    --binary <file|dir>   Official FreeWallet.linux64.tgz to compare against, or a
                          directory containing it. Skips the download.
    --apk <path>          Not applicable to this desktop build (ignored)
    --help                Show this help message

EXAMPLES:
    $0 --version 2.0.4
    $0 --version 2.0.4 --arch x86_64-linux-gnu --type tarball
    $0 --version 2.0.4 --binary ~/Downloads/FreeWallet.linux64.tgz

OUTPUT:
    Workspace:    ./freewallet_verification_<version>_<arch>_<epoch>-<pid>/ (new per run)
    Results file: COMPARISON_RESULTS.yaml next to this script

EXIT CODES:
    0 - Reproducible (hashes match)
    1 - Not reproducible, or the build failed (ftbfs)
    2 - Invalid parameters or unusable input

NOTES:
    - Requires podman or docker; must not run as root
    - Only the linux64 tarball is built (linux32, Windows and macOS are not)

EOF
    exit "${EXIT_SUCCESS}"
}

# ---------- Parameters ----------
version=""
arch="x86_64-linux-gnu"
app_type="tarball"
binary_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--arch|--type|--binary|--apk)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                die_invalid "$1 requires a value"
            fi
            case "$1" in
                --version) version="$2" ;;
                --arch) arch="$2" ;;
                --type) app_type="$2" ;;
                --binary) binary_path="$2" ;;
                --apk) log_warn "--apk is not applicable to this desktop build; ignoring it" ;;
            esac
            shift 2 ;;
        --help|-h) show_help ;;
        *) log_warn "Ignoring unknown parameter: $1"; shift ;;
    esac
done

if [[ "$(id -u)" -eq 0 ]]; then
    die_invalid "Do not run this script as root"
fi
if [[ -z "$version" ]]; then
    log_error "Missing required parameter: --version"
    echo "Run '$0 --help' for usage information."
    exit "${EXIT_INVALID}"
fi
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    die_invalid "Invalid --version '${version}' (expected e.g. 2.0.4, without the v prefix)"
fi

# ---------- Validate arch and type ----------
case "$arch" in
    x86_64-linux-gnu|x86_64-linux|linux64)
        release_arch="linux64"; nw_arch="x64" ;;
    i686-linux-gnu|i386-linux-gnu|linux32)
        die_invalid "Architecture ${arch} (linux32) is not supported yet" ;;
    *)
        die_invalid "Invalid architecture: ${arch} (supported: x86_64-linux-gnu)" ;;
esac
case "$app_type" in
    tarball|tgz) ;;
    *) die_invalid "Invalid type: ${app_type} (supported: tarball)" ;;
esac

RELEASE_FILE="FreeWallet.${release_arch}.tgz"

# ---------- Official artifact supplied by the caller ----------
binary_file=""
if [[ -n "${binary_path}" ]]; then
    if [[ -d "${binary_path}" ]]; then
        if [[ -f "${binary_path}/${RELEASE_FILE}" ]]; then
            binary_file="${binary_path}/${RELEASE_FILE}"
        else
            mapfile -t tgz_files < <(find "${binary_path}" -maxdepth 1 -type f -name '*.tgz')
            [[ ${#tgz_files[@]} -eq 1 ]] || die_invalid "--binary directory must contain ${RELEASE_FILE} or exactly one .tgz"
            binary_file="${tgz_files[0]}"
        fi
    elif [[ -f "${binary_path}" ]]; then
        binary_file="${binary_path}"
    else
        die_invalid "--binary not found: ${binary_path}"
    fi
    binary_file="$(readlink -f "${binary_file}")"
fi

CONTAINER_CMD=""
if command -v podman &>/dev/null; then CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then CONTAINER_CMD="docker"
else die_invalid "Neither podman nor docker was found in PATH"
fi

# ---------- Setup ----------
# Per-run workspace in the caller's directory. A run only touches the
# directory it created; earlier workspaces are never removed or reused.
EXECUTION_DIR="$(pwd -P)"
RUN_ID="$(date +%s)-$$"
WORK_DIR="${EXECUTION_DIR}/freewallet_verification_${version}_${release_arch}_${RUN_ID}"
IMAGE_NAME="freewallet-verify-${RUN_ID}"
mkdir -- "${WORK_DIR}"
log_info "Workspace: ${WORK_DIR}"
cd "${WORK_DIR}"

# EXIT: hand the workspace back to the caller (docker writes as root; rootless
# podman as mapped subuids), remove this run's image, and record a build failure
# as ftbfs. No verdict on invalid input (2) or a stop (130).
cleanup() {
    local rc=$?
    set +e
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
        podman unshare chown -R 0:0 "${WORK_DIR}" >/dev/null 2>&1
    elif docker image inspect "${HELPER_IMAGE}" >/dev/null 2>&1; then
        docker run --rm -v "${WORK_DIR}:/w" "${HELPER_IMAGE}" chown -R "$(id -u):$(id -g)" /w >/dev/null 2>&1
    fi
    chmod -R u+rwX "${WORK_DIR}" 2>/dev/null
    local foreign
    foreign="$(find "${WORK_DIR}" ! -user "$(id -u)" 2>/dev/null | wc -l)"
    [[ "${foreign}" == 0 ]] || log_warn "${foreign} workspace entries not owned by you: ${WORK_DIR}"
    ${CONTAINER_CMD} rmi -f "${IMAGE_NAME}" >/dev/null 2>&1
    if [[ "${rc}" != 2 && "${rc}" != 130 && ! -f "${YAML_FILE}" ]]; then
        log_error "Script stopped before writing a verdict (exit ${rc}); recording ftbfs"
        write_yaml "ftbfs" "Build or packaging of ${RELEASE_FILE} v${version} failed (script exit ${rc}); see the run log."
        rc="${EXIT_FAILED}"
    fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'log_error "Interrupted; no verdict written"; exit 130' INT TERM

# ---------- Build Config ----------
# NW.js 0.92.0 confirmed from official v2.0.4 build analysis (2026-01-19)
nw_ver="0.92.0"
nw_file="nwjs-sdk-v${nw_ver}-linux-${nw_arch}.tar.gz"
nw_url="https://dl.nwjs.io/v${nw_ver}/${nw_file}"
# SHA256 checksum for the NW.js SDK (from dl.nwjs.io/v0.92.0/SHASUMS256.txt)
nw_sha256="77dffb987c4fcc7939bdde2a0ddceb58ff2ceb3529835d7fb2397f308cd53bf8"
# Upstream README: replace lib/libffmpeg.so with the nwjs-ffmpeg-prebuilt build for the
# same NW.js version. Its libffmpeg.so (46502c03...) is the one in the official v2.0.4 tarball.
ff_url="https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/${nw_ver}/${nw_ver}-linux-${nw_arch}.zip"
ff_sha256="d18d26f701991aa1fbf0b4cf496c3e3824efc5dea49888ee63349a7a9c2df7f2"

# ---------- Fetch ----------
OFFICIAL_DIR="${WORK_DIR}/official"
mkdir -- "${OFFICIAL_DIR}" "${WORK_DIR}/logs"
if [[ -n "${binary_file}" ]]; then
    log_info "Using provided binary: ${binary_file}"
    cp -- "${binary_file}" "${OFFICIAL_DIR}/${RELEASE_FILE}"
    BINARY_SOURCE="provided with --binary: $(basename "${binary_file}")"
    fetch_official="false"
else
    BINARY_SOURCE="GitHub release v${version}"
    fetch_official="true"
fi

if [[ "${fetch_official}" == "true" ]]; then
    log_info "Downloading official release..."
    # No official artifact means nothing to compare: invalid input, not a build failure.
    ${CONTAINER_CMD} run --rm -v "${WORK_DIR}:/work:Z" -w /work "${HELPER_IMAGE}" bash -c "
        set -e
        apt-get update >/dev/null && apt-get install -y curl ca-certificates >/dev/null 2>&1
        curl -fSL -o 'official/${RELEASE_FILE}' '${REPO_URL}/releases/download/v${version}/${RELEASE_FILE}'
        curl -fsSL -o 'official/checksums.txt' '${REPO_URL}/releases/download/v${version}/checksums.txt' || true
    " || die_invalid "Could not download ${RELEASE_FILE} for v${version} (use --binary to provide it)"
fi

log_info "Cloning source repository..."
${CONTAINER_CMD} run --rm -v "${WORK_DIR}:/work:Z" -w /work "${HELPER_IMAGE}" bash -c "
    set -e
    apt-get update >/dev/null && apt-get install -y git ca-certificates >/dev/null 2>&1
    git clone --depth 1 --branch 'v${version}' '${REPO_URL}' source
    git -C source rev-parse HEAD > logs/commit.txt
"
COMMIT="$(tr -d '[:space:]' < "${WORK_DIR}/logs/commit.txt" 2>/dev/null || echo unknown)"
OFFICIAL_HASH="$(sha256_of "${OFFICIAL_DIR}/${RELEASE_FILE}")"

CHECKSUM_STATUS="not checked (official file provided with --binary)"
if [[ "${fetch_official}" == "true" ]]; then
    published_hash="$(awk -v n="${RELEASE_FILE}" '$2 == n {print $1; exit}' "${OFFICIAL_DIR}/checksums.txt" 2>/dev/null || true)"
    if [[ -z "${published_hash}" ]]; then
        CHECKSUM_STATUS="no entry (checksums.txt missing or lacks ${RELEASE_FILE})"
        log_warn "Could not check the download against checksums.txt"
    elif [[ "${published_hash}" == "${OFFICIAL_HASH}" ]]; then
        CHECKSUM_STATUS="matches release checksums.txt (unsigned)"
        log_success "Official download matches checksums.txt"
    else
        die_invalid "Official download ${OFFICIAL_HASH} does not match checksums.txt ${published_hash}"
    fi
fi

log_info "Creating Dockerfile..."
printf '%s\n' official build-output logs > "${WORK_DIR}/.dockerignore"
cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE'
# node:20-bullseye, pinned by index digest (the image used for the published 2.0.4 run)
FROM docker.io/library/node@sha256:c0122351f25f04facee976f9db7214789eabadb489f4e4aea9cd00a0d6af77c4

# --no-upgrade: curl, xz-utils and unzip ship in the image; bullseye-security upgrades now 404
RUN apt-get update && apt-get install -y --no-upgrade curl xz-utils zip && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY source/ /app/

# Setup App: copy source files and install npm dependencies
RUN mkdir -p build && cp -a css html images js index.html package.json build/
RUN cd build && npm install

DOCKERFILE

# Append build steps with variable substitution
cat >> "${WORK_DIR}/Dockerfile" <<DOCKERFILE
# --- MANUAL BUILD (bypasses nw-builder entirely) ---
# nw-builder/node-tar has TAR_BAD_ARCHIVE issues with NW.js SDK archives
# Solution: Use system tar + manual file assembly

# 1. Download and verify NW.js SDK
RUN curl -fSL "${nw_url}" -o /tmp/nwjs.tar.gz && \\
    echo "${nw_sha256}  /tmp/nwjs.tar.gz" | sha256sum -c -

# 2. Extract NW.js to builds/FreeWallet/ (matching official structure)
RUN mkdir -p builds/FreeWallet && \\
    tar -xzf /tmp/nwjs.tar.gz -C builds/FreeWallet --strip-components=1 && \\
    rm /tmp/nwjs.tar.gz

# 3. Fix permissions (NW.js SDK files have restricted perms)
#    a+rX = read for all files, execute for directories (allows traversal)
RUN chmod -R a+rX builds/FreeWallet/

# 3b. Replace libffmpeg.so with the nwjs-ffmpeg-prebuilt build (upstream README step)
RUN curl -fSL "${ff_url}" -o /tmp/ffmpeg.zip && \\
    echo "${ff_sha256}  /tmp/ffmpeg.zip" | sha256sum -c - && \\
    unzip -o /tmp/ffmpeg.zip libffmpeg.so -d builds/FreeWallet/lib/ && \\
    rm /tmp/ffmpeg.zip

# 4. Create app.nw (ZIP of app files) - NW.js concatenation method
#    The official build embeds app files INTO the binary, not alongside it.
#    Same selection as upstream's nw-builder glob ./build/**: no dot-named
#    files or directories, no directory entries.
RUN cd build && zip -r -D ../app.nw . -x '.*' '*/.*' && cd ..

# 5. Concatenate app.nw to nw binary to create FreeWallet (matches official)
#    This is how nw-builder creates the final executable
RUN cat builds/FreeWallet/nw app.nw > builds/FreeWallet/FreeWallet && \\
    rm builds/FreeWallet/nw app.nw

# 6. Remove app files that are now embedded (official doesn't have these loose)
RUN rm -rf builds/FreeWallet/package.json 2>/dev/null || true

# 7. Copy helper files from misc/ (install.sh, .desktop, .png)
RUN cp misc/FreeWallet.desktop misc/FreeWallet.png misc/install.sh builds/FreeWallet/

# 8. Set executable permissions
RUN chmod +x builds/FreeWallet/FreeWallet builds/FreeWallet/install.sh

# 9. Final permission fix - ensure ALL files are readable/writable by anyone
#    Critical for rootless podman: files must be accessible after UID remapping
RUN chmod -R a+rwX builds/

WORKDIR /app/builds
CMD ["/bin/bash", "-c", "cp -a FreeWallet /output/"]
DOCKERFILE

# ---------- Build ----------
log_info "Building image..."
${CONTAINER_CMD} build -t "${IMAGE_NAME}" .

log_info "Running build..."
BUILD_OUT="${WORK_DIR}/build-output"
mkdir -- "${BUILD_OUT}"
${CONTAINER_CMD} run --rm -v "${BUILD_OUT}:/output:Z" "${IMAGE_NAME}"

# ---------- Package ----------
log_info "Packaging build..."
cd "${BUILD_OUT}"
# Create tarball with FreeWallet/ at top level (matching official structure)
tar -czf "${RELEASE_FILE}" FreeWallet

# ---------- Compare ----------
log_info "Comparing hashes..."
BUILT_HASH="$(sha256_of "${BUILD_OUT}/${RELEASE_FILE}")"
NOTES="Rebuilt ${RELEASE_FILE} from tag v${version} (commit ${COMMIT}) with NW.js SDK ${nw_ver} and nwjs-ffmpeg-prebuilt ${nw_ver} libffmpeg.so (both sha256-checked) in node:20-bullseye (digest-pinned), then compared the tarball sha256 with the official release asset (${BINARY_SOURCE})."
diff_summary=""
diff_preview=""

if [[ "$BUILT_HASH" == "$OFFICIAL_HASH" ]]; then
    VERDICT="reproducible"
    log_success "REPRODUCIBLE - Hashes match!"
else
    VERDICT="not_reproducible"
    log_warn "NOT REPRODUCIBLE - Hashes differ"
    cmp_dir="${WORK_DIR}/comparison"
    mkdir -- "${cmp_dir}" "${cmp_dir}/official" "${cmp_dir}/built"
    # Statuses are kept: a failed extraction or diff error means the list below is incomplete.
    # (GNU tar exits 0 on the official tarball's LIBARCHIVE.xattr warnings.)
    tar_official_rc=0; tar_built_rc=0; diff_rc=0
    tar -xzf "${OFFICIAL_DIR}/${RELEASE_FILE}" -C "${cmp_dir}/official" 2>"${WORK_DIR}/logs/tar-official.txt" || tar_official_rc=$?
    tar -xzf "${BUILD_OUT}/${RELEASE_FILE}" -C "${cmp_dir}/built" 2>"${WORK_DIR}/logs/tar-built.txt" || tar_built_rc=$?
    (cd "${cmp_dir}" && diff -rq official built > "${WORK_DIR}/diff_full.txt" 2>&1) || diff_rc=$?
    only_official="$(grep -c '^Only in official' "${WORK_DIR}/diff_full.txt" || true)"
    only_built="$(grep -c '^Only in built' "${WORK_DIR}/diff_full.txt" || true)"
    differ="$(grep -c ' differ$' "${WORK_DIR}/diff_full.txt" || true)"
    total="$(wc -l < "${WORK_DIR}/diff_full.txt")"
    diff_summary="Differences: ${total} (files differ ${differ}, only in official ${only_official}, only in built ${only_built})"
    if [[ ${tar_official_rc} -ne 0 || ${tar_built_rc} -ne 0 || ${diff_rc} -gt 1 ]]; then
        log_warn "File comparison incomplete: tar official ${tar_official_rc}, tar built ${tar_built_rc}, diff ${diff_rc}"
        diff_summary="${diff_summary}; INCOMPLETE (tar official exit ${tar_official_rc}, tar built exit ${tar_built_rc}, diff exit ${diff_rc})"
    elif [[ ${diff_rc} -eq 0 ]]; then
        diff_summary="${diff_summary}; all extracted files are identical, so the tarballs differ only in archive metadata (owners, modes, dates, order)"
    fi
    diff_preview="$(head -5 "${WORK_DIR}/diff_full.txt")"
    NOTES="${NOTES}
${diff_summary}. Full list: diff_full.txt in the workspace."
fi

write_yaml "${VERDICT}" "${NOTES}"

echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${OFFICIAL_HASH}"
echo "commit:         ${COMMIT}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo "===== End Results ====="
echo ""
echo "officialFile:   ${RELEASE_FILE} (${BINARY_SOURCE})"
echo "builtHash:      ${BUILT_HASH}"
echo "checksums.txt:  ${CHECKSUM_STATUS}"
echo "arch/type:      ${arch} / ${app_type}"
if [[ -n "${diff_summary}" ]]; then
    echo ""
    echo "${diff_summary}"
    echo "Diff (first 5 lines; full list in ${WORK_DIR}/diff_full.txt):"
    echo "${diff_preview}"
fi
echo ""
echo "Results written to: ${YAML_FILE}"

if [[ "${VERDICT}" == "reproducible" ]]; then
    exit "${EXIT_SUCCESS}"
fi
exit "${EXIT_FAILED}"
