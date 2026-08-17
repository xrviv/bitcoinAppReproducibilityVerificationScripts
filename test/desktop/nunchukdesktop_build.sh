#!/bin/bash
#
# nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verifier
#
# Version: v0.1.7
#
# Description:
#   Reproducible build verification for Nunchuk Desktop (Linux x86_64 AppImage).
#   Builds the app from source inside an inline Docker/Podman container matching
#   the upstream reproducible_linux.yml execution model, then compares the built
#   AppImage against the official release at the extracted-squashfs level.
#
#   Upstream embeds three OAuth values at compile time, and its workflow does not
#   publish the Actions artifact as the GitHub release asset. These limitations are
#   reported as context when substantive extracted-content differences are found.
#
#   Whole-AppImage hashes will always differ because appimagetool embeds wall-clock
#   time in the squashfs superblock and no SOURCE_DATE_EPOCH is set upstream.
#   Comparison is therefore done by extracting both AppImages with unsquashfs and
#   running diff -r on the resulting directory trees.
#
#   The distributed artifact is a ZIP wrapping the AppImage, so two different hashes are
#   meaningful. appHash is the artifact EXACTLY AS DOWNLOADED (the ZIP) per
#   verification-result-summary-format.md; the AppImage's own hash is printed alongside it
#   as the payload that was compared. See the hash legend printed before the results block.
#
# Usage:
#   nunchukdesktop_build.sh --version VERSION [--arch ARCH] [--type TYPE] [--binary FILE]
#
# Required:
#   --version VERSION    App version without v prefix (e.g. 1.9.50)
#
# Optional:
#   --binary FILE        Path to official AppImage or ZIP (skips download)
#   --arch ARCH          Architecture (only x86_64-linux-gnu supported; default)
#   --type TYPE          Build type (only appimage supported; default)
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
# Changelog: ~/work/ws-notes/script-notes/desktop/nunchuk/changelog.md
#

set -euo pipefail

SCRIPT_VERSION="v0.1.7"
APP_ID="nunchuk"
APP_NAME="Nunchuk Desktop"
GH_REPO="nunchuk-io/nunchuk-desktop"

EXIT_OK=0
EXIT_DIFF=1
EXIT_INVALID=2

APP_VERSION=""
APP_ARCH="x86_64-linux-gnu"
APP_TYPE="appimage"
BINARY_PATH=""
CONTAINER_CMD=""
WORK_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
MISSING_OAUTH_INPUTS=""

# Artifact identity. OFFICIAL_ARTIFACT_* describes the file exactly as distributed (the release
# ZIP, or whatever --binary pointed at); OFFICIAL_APPIMAGE_SHA256 is the payload actually compared.
OFFICIAL_ARTIFACT_NAME=""
OFFICIAL_ARTIFACT_SHA256=""
OFFICIAL_APPIMAGE_SHA256=""
BUILT_APPIMAGE_SHA256=""

NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die_invalid() {
    log_error "$1"
    write_yaml "ftbfs" "$1"
    exit "${EXIT_INVALID}"
}

die_build() {
    log_error "$1"
    write_yaml "ftbfs" "$1"
    exit "${EXIT_DIFF}"
}

write_yaml() {
    local verdict="$1"
    local notes="${2:-}"
    # Keep the YAML double-quoted scalar valid even if error text contains quotes.
    notes="${notes//\"/\'}"
    local yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    if [[ -n "$notes" ]]; then
        printf 'script_version: %s\nverdict: %s\nnotes: "%s"\n' \
            "$SCRIPT_VERSION" "$verdict" "$notes" > "$yaml_file"
    else
        printf 'script_version: %s\nverdict: %s\n' \
            "$SCRIPT_VERSION" "$verdict" > "$yaml_file"
    fi
    log_info "COMPARISON_RESULTS.yaml written to: $yaml_file"
}

sha256_of() {
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

check_build_inputs() {
    local name
    local -a missing=()

    for name in OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET OAUTH_REDIRECT_URI; do
        [[ -n "${!name:-}" ]] || missing+=("$name")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        MISSING_OAUTH_INPUTS="$(IFS=,; echo "${missing[*]}")"
        log_warn "Missing compile-time OAuth inputs: ${MISSING_OAUTH_INPUTS}"
        log_warn "The build will continue; any differences require triage and the missing inputs limit root-cause attribution."
    else
        log_info "All upstream compile-time OAuth inputs are present in the environment."
    fi

    log_warn "Upstream does not establish that the published release asset came from reproducible_linux.yml."
}

comparison_context_note() {
    local note="The published release asset is not proven to come from the recreated reproducible_linux.yml pipeline."
    if [[ -n "$MISSING_OAUTH_INPUTS" ]]; then
        note+=" Missing compile-time inputs: ${MISSING_OAUTH_INPUTS}."
    fi
    printf '%s' "$note"
}

# Validate that a SquashFS superblock exists at the given byte offset.
#   0 = valid, 1 = not valid, 2 = cannot validate (no host unsquashfs)
validate_squashfs_offset() {
    local appimage="$1" off="$2"
    command -v unsquashfs >/dev/null 2>&1 || return 2
    unsquashfs -s -o "$off" "$appimage" >/dev/null 2>&1 && return 0
    return 1
}

# Determine the byte offset of the SquashFS payload inside a type-2 AppImage.
# A type-2 AppImage is an ELF runtime with the SquashFS filesystem APPENDED at an
# offset, so unsquashfs must be told that offset with -o. Three tiers (per code review):
#   Tier 1: ask the AppImage runtime (`--appimage-offset`) — no FUSE needed, but it
#           must execute the runtime, which can fail on noexec/perm/arch/container.
#   Tier 2: parse the ELF header — squashfs starts right after the section-header
#           table (offset = e_shoff + e_shentsize * e_shnum). FUSE-free, deterministic.
#   Tier 3: scan for the 'hsqs' SquashFS magic — accepted ONLY if positively validated
#           by unsquashfs, since false positives can occur inside the ELF/runtime data.
# Echoes the numeric offset on success; returns non-zero on total failure.
detect_appimage_offset() {
    local appimage="$1"
    local fsize; fsize="$(stat -c%s "$appimage")"
    local off rc

    # Tier 1: runtime --appimage-offset
    if chmod +x "$appimage" 2>/dev/null; then
        off="$("$appimage" --appimage-offset 2>/dev/null | tr -d '[:space:]')"
        if [[ "$off" =~ ^[0-9]+$ ]] && (( off > 0 && off < fsize )); then
            validate_squashfs_offset "$appimage" "$off"; rc=$?
            if [[ "$rc" -ne 1 ]]; then echo "$off"; return 0; fi
        fi
    fi

    # Tier 2: ELF section-header-table end = squashfs start
    off="$(python3 - "$appimage" <<'PY' 2>/dev/null
import sys, struct
d = open(sys.argv[1], 'rb').read(64)
if d[:4] != b'\x7fELF': sys.exit(1)
is64 = d[4] == 2
end = '<' if d[5] == 1 else '>'
if is64:
    e_shoff = struct.unpack(end + 'Q', d[40:48])[0]
    e_shentsize, e_shnum = struct.unpack(end + 'H', d[58:60])[0], struct.unpack(end + 'H', d[60:62])[0]
else:
    e_shoff = struct.unpack(end + 'I', d[32:36])[0]
    e_shentsize, e_shnum = struct.unpack(end + 'H', d[46:48])[0], struct.unpack(end + 'H', d[48:50])[0]
print(e_shoff + e_shentsize * e_shnum)
PY
)"
    if [[ "$off" =~ ^[0-9]+$ ]] && (( off > 0 && off < fsize )); then
        validate_squashfs_offset "$appimage" "$off"; rc=$?
        if [[ "$rc" -ne 1 ]]; then echo "$off"; return 0; fi
    fi

    # Tier 3: scan for 'hsqs' magic; accept only a positively validated candidate
    local cand
    while IFS= read -r cand; do
        [[ "$cand" =~ ^[0-9]+$ ]] || continue
        (( cand < fsize )) || continue
        if validate_squashfs_offset "$appimage" "$cand"; then echo "$cand"; return 0; fi
    done < <(grep -aboe 'hsqs' "$appimage" 2>/dev/null | cut -d: -f1)

    return 1
}

detect_container_cmd() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    else
        die_invalid "Neither podman nor docker found in PATH. Install one and retry."
    fi
    log_info "Container runtime: $CONTAINER_CMD"
}

require_arg() {
    local flag="$1" val="${2:-}"
    if [[ -z "$val" || "$val" == --* ]]; then
        die_invalid "Missing value for parameter: $flag"
    fi
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION [--binary FILE] [--arch ARCH] [--type TYPE]"
        echo "Run $0 --help for details"
        exit "${EXIT_INVALID}"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                require_arg "$1" "${2:-}"
                APP_VERSION="$2"; shift 2 ;;
            --binary)
                require_arg "$1" "${2:-}"
                BINARY_PATH="$2"; shift 2 ;;
            --arch)
                require_arg "$1" "${2:-}"
                APP_ARCH="$2"; shift 2 ;;
            --type)
                require_arg "$1" "${2:-}"
                APP_TYPE="$2"; shift 2 ;;
            --apk)
                # Android alias accepted for ABS compatibility; not applicable here
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi
                log_warn "--apk is not applicable for desktop builds (ignored)" ;;
            --help)
                show_help; exit 0 ;;
            *)
                log_warn "Unknown argument: $1 (ignored)"
                shift ;;
        esac
    done

    if [[ -z "$APP_VERSION" ]]; then
        die_invalid "--version is required"
    fi

    # Reject recognized-but-unsupported arch/type so a wrong combo can't masquerade as a
    # Linux AppImage result. Only x86_64-linux-gnu/appimage is implemented (Windows/macOS
    # are separate, not-yet-supported targets).
    if [[ "$APP_ARCH" != "x86_64-linux-gnu" ]]; then
        die_invalid "Unsupported --arch '${APP_ARCH}'; only x86_64-linux-gnu is implemented"
    fi
    if [[ "$APP_TYPE" != "appimage" ]]; then
        die_invalid "Unsupported --type '${APP_TYPE}'; only appimage is implemented"
    fi

    if [[ -n "$BINARY_PATH" && ! -f "$BINARY_PATH" ]]; then
        die_invalid "--binary path does not exist: $BINARY_PATH"
    fi
    if [[ -n "$BINARY_PATH" ]]; then
        BINARY_PATH="$(realpath "$BINARY_PATH")"
    fi
}

show_help() {
    cat << 'EOF'
nunchukdesktop_build.sh - Nunchuk Desktop Reproducible Build Verification

USAGE:
  nunchukdesktop_build.sh --version VERSION [OPTIONS]

REQUIRED:
  --version VERSION    App version without v prefix (e.g. 1.9.50)

OPTIONAL:
  --binary FILE        Official AppImage or ZIP (skip GitHub download)
  --arch ARCH          x86_64-linux-gnu (default, only supported value)
  --type TYPE          appimage (default, only supported value)

OPTIONAL ENVIRONMENT:
  OAUTH_CLIENT_ID       Upstream compile-time OAuth client ID
  OAUTH_CLIENT_SECRET   Upstream compile-time OAuth client secret
  OAUTH_REDIRECT_URI    Upstream compile-time OAuth redirect URI

EXAMPLES:
  nunchukdesktop_build.sh --version 1.9.50
  nunchukdesktop_build.sh --version 1.9.50 --binary ~/Downloads/nunchuk-linux-v1.9.50.zip

EXIT CODES:
  0  Identical (reproducible at squashfs-contents level)
  1  Differences found or build failed
  2  Invalid parameters

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/diff_squashfs.txt  (full squashfs diff for human review)
  $WORK_DIR/diff_squashfs_brief.txt  (one line per differing entry)
  $WORK_DIR/why_not_reproducible.txt (categorized reason summary when differences exist)
EOF
}

setup_workdir() {
    # Use a unique work dir per version+arch+type+PID so parallel ABS runs do not collide.
    local suffix="${APP_VERSION}_${APP_ARCH}_${APP_TYPE}_$$"
    suffix="${suffix//[^a-zA-Z0-9._-]/_}"
    WORK_DIR="/tmp/nunchuk_${suffix}"
    mkdir -p "$WORK_DIR"
    log_info "Work directory: $WORK_DIR"
}

prepare_official() {
    # Obtain the official AppImage: either extract from the provided ZIP/AppImage binary,
    # or download the release ZIP from GitHub and extract the AppImage from it.
    local official_appimage="${WORK_DIR}/official.AppImage"

    if [[ -n "$BINARY_PATH" ]]; then
        log_info "Using provided binary: $(basename "$BINARY_PATH")"
        local bname; bname="$(basename "$BINARY_PATH")"
        # The provided file IS the distributed artifact, whatever its form.
        OFFICIAL_ARTIFACT_NAME="$bname"
        OFFICIAL_ARTIFACT_SHA256="$(sha256_of "$BINARY_PATH")"
        log_ok "Official artifact as provided: ${bname}"
        log_ok "  sha256: ${OFFICIAL_ARTIFACT_SHA256}"
        if [[ "$bname" == *.zip ]]; then
            log_info "Archive contents:"
            unzip -l "$BINARY_PATH" || true
            log_info "Extracting AppImage from provided ZIP..."
            unzip -q "$BINARY_PATH" -d "${WORK_DIR}/official_zip"
            local found; found="$(find "${WORK_DIR}/official_zip" -name "*.AppImage" | head -1)"
            if [[ -z "$found" ]]; then
                die_build "No .AppImage found inside provided ZIP: $BINARY_PATH"
            fi
            cp "$found" "$official_appimage"
        elif [[ "$bname" == *.AppImage ]]; then
            cp "$BINARY_PATH" "$official_appimage"
        else
            die_invalid "--binary must be a .zip or .AppImage file, got: $bname"
        fi
    else
        local zip_name="nunchuk-linux-v${APP_VERSION}.zip"
        local dl_url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/${zip_name}"
        local zip_path="${WORK_DIR}/${zip_name}"
        log_info "Downloading official release: $dl_url"
        # Download release ZIP; pass GitHub token header if available to avoid rate limiting.
        if ! wget -q ${GITHUB_TOKEN:+--header="Authorization: token ${GITHUB_TOKEN}"} \
                -O "$zip_path" "$dl_url"; then
            die_build "Failed to download: $dl_url"
        fi
        # Hash the distributed artifact as downloaded, BEFORE unpacking it. This is the value a
        # user can reproduce with sha256sum against the release page, and the one to publish.
        OFFICIAL_ARTIFACT_NAME="$zip_name"
        OFFICIAL_ARTIFACT_SHA256="$(sha256_of "$zip_path")"
        log_ok "Official artifact as downloaded: ${zip_name} ($(stat -c%s "$zip_path") bytes)"
        log_ok "  sha256: ${OFFICIAL_ARTIFACT_SHA256}"
        log_info "Archive contents:"
        unzip -l "$zip_path" || true
        log_info "Extracting AppImage from downloaded ZIP..."
        unzip -q "$zip_path" -d "${WORK_DIR}/official_zip"
        local found; found="$(find "${WORK_DIR}/official_zip" -name "*.AppImage" | head -1)"
        if [[ -z "$found" ]]; then
            die_build "No .AppImage found inside downloaded ZIP: $zip_path"
        fi
        cp "$found" "$official_appimage"
    fi

    local sz; sz="$(stat -c%s "$official_appimage")"
    OFFICIAL_APPIMAGE_SHA256="$(sha256_of "$official_appimage")"
    log_ok "Official AppImage ready: $(basename "$official_appimage") (${sz} bytes)"
    log_ok "  sha256: ${OFFICIAL_APPIMAGE_SHA256} (payload compared; NOT the publishable hash)"
}

run_build() {
    # Prepare Nunchuk's build environment using an inline Dockerfile that mirrors
    # upstream reproducible-builds/Dockerfile.linux, with these deltas:
    #   - Source is git-cloned at the release TAG inside the container (no host build context)
    #   - debug_info is KEPT (content parity); the flaky module download is retried w/ timeout
    #   - The build runs when the container starts, matching reproducible_linux.yml, so
    #     OAuth environment variables reach CMake instead of being lost at image-build time
    # squashfs-tools is also added so the comparison step can run unsquashfs in-container.
    log_info "Writing inline Dockerfile..."

    cat > "${WORK_DIR}/Dockerfile.build" << 'DOCKERFILE_END'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG QT_VERSION=5.15.2
ENV QT_INSTALL_DIR=/opt/Qt
ENV QT5_DIR=$QT_INSTALL_DIR/$QT_VERSION/gcc_64/lib/cmake/Qt5
ENV QT_INSTALLED_PREFIX=$QT_INSTALL_DIR/$QT_VERSION/gcc_64

ARG TAG=0.0.0
RUN echo "Building version $TAG"

RUN apt update && apt install -y \
        cmake g++ make ninja-build \
        libboost-all-dev libzmq3-dev libevent-dev libdb++-dev \
        sqlite3 libsqlite3-dev libsecret-1-dev \
        git dpkg-dev python3-pip wget unzip curl patchelf p7zip-full \
        libgl1-mesa-dev

RUN apt update && apt install -y \
        fuse libfuse2 squashfuse \
        mesa-common-dev libglu1-mesa-dev \
        libpulse-dev libxcb-xinerama0 software-properties-common \
        libnss3-dev libasound2-dev libxrandr-dev libxcomposite-dev \
        libxcursor-dev libxi-dev libxdamage-dev libxtst-dev libxss-dev \
        libx11-xcb-dev libxt-dev libdbus-1-dev libegl1-mesa-dev \
        squashfs-tools

RUN add-apt-repository ppa:ubuntu-toolchain-r/ppa -y && \
    apt update && apt install -y gcc-14 g++-14 && \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 && \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100

ENV CC=gcc-14
ENV CXX=g++-14

# debug_info is KEPT (matches upstream Dockerfile.linux:44). The official AppImage bundles the
# Qt .debug companion files via CQtDeployer; omitting debug_info drops ~10 MB and breaks content
# parity. The debug-symbols download is flaky, so the module install is retried with a longer timeout.
RUN pip3 install --break-system-packages aqtinstall && \
    aqt install-qt linux desktop $QT_VERSION gcc_64 --outputdir "$QT_INSTALL_DIR" && \
    for attempt in 1 2 3 4 5; do \
        aqt install-qt linux desktop $QT_VERSION gcc_64 --outputdir "$QT_INSTALL_DIR" --timeout 120 \
            --modules qtcharts qtdatavis3d qtlottie qtnetworkauth qtpurchasing qtquick3d \
                      qtquicktimeline qtscript qtvirtualkeyboard qtwaylandcompositor \
                      qtwebengine qtwebglplugin debug_info && break; \
        echo "aqt module install attempt $attempt failed"; \
        [ "$attempt" = 5 ] && { echo "all aqt attempts failed"; exit 1; }; \
        sleep 15; \
    done

RUN git clone --depth 1 --branch 0.15.0 https://github.com/frankosterfeld/qtkeychain.git /tmp/qtkeychain && \
    cd /tmp/qtkeychain && mkdir build && cd build && \
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DQt5_DIR=$QT5_DIR && \
    make -j$(nproc) && make install && ldconfig

RUN git clone https://gitlab.matrix.org/matrix-org/olm.git /tmp/olm && \
    cd /tmp/olm && git checkout 3.2.16 && mkdir build && cd build && \
    cmake .. -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && make -j$(nproc) && \
    make install && ldconfig

RUN wget https://github.com/QuasarApp/CQtDeployer/releases/download/v1.6.2365/CQtDeployer_1.6.2365.7cce7f3_Linux_x86_64.deb && \
    dpkg -i CQtDeployer_1.6.2365.7cce7f3_Linux_x86_64.deb

RUN wget https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1g/openssl-1.1.1g.tar.gz && \
    tar xzf openssl-1.1.1g.tar.gz && \
    cd openssl-1.1.1g && ./config --prefix=/opt/openssl-1.1.1g && \
    make -j$(nproc) && make install_dev

ENV OPENSSL_ROOT_DIR=/opt/openssl-1.1.1g

RUN wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage && \
    chmod +x appimagetool-x86_64.AppImage && mv appimagetool-x86_64.AppImage /usr/local/bin/appimagetool

# Clone the exact release tag from GitHub INSIDE the container (no host build context),
# so the script is self-contained and ABS-ready. TAG is the bare version (e.g. 1.9.50).
RUN git clone --depth=1 --shallow-submodules --recurse-submodules --branch "${TAG}" \
        https://github.com/nunchuk-io/nunchuk-desktop.git /project
WORKDIR /project

CMD ["bash", "/project/reproducible-builds/build_linux.sh"]
DOCKERFILE_END

    log_info "Building container image — this takes 20-40 min on first run..."
    local image_name="nunchuk-verifier-${APP_VERSION}-$$"
    local container_name="nunchuk-extract-${APP_VERSION}-$$"

    # TAG selects the source during image creation and is passed again to the runtime package script.
    # Source is cloned from GitHub inside the container, so the build context is WORK_DIR and the
    # script does not depend on a host checkout (ABS-ready).
    if ! "$CONTAINER_CMD" build \
            --build-arg TAG="${APP_VERSION}" \
            -t "$image_name" \
            -f "${WORK_DIR}/Dockerfile.build" \
            "${WORK_DIR}" 2>&1; then
        die_build "Container build failed"
    fi

    log_info "Running upstream build command inside the container..."
    local -a create_args=(create --name "$container_name" --env "TAG=${APP_VERSION}")
    local oauth_name
    for oauth_name in OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET OAUTH_REDIRECT_URI; do
        if [[ -v "$oauth_name" ]]; then
            # Pass only the variable name so its value is not exposed in the process list.
            create_args+=(--env "$oauth_name")
        fi
    done

    if ! "$CONTAINER_CMD" "${create_args[@]}" "$image_name" > /dev/null; then
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Could not create build container"
    fi
    if ! "$CONTAINER_CMD" start --attach "$container_name"; then
        "$CONTAINER_CMD" rm "$container_name" > /dev/null 2>&1 || true
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Containerized upstream build failed"
    fi

    log_info "Extracting built AppImage from container..."
    if ! "$CONTAINER_CMD" cp \
            "${container_name}:/project/nunchuk-linux-v${APP_VERSION}/nunchuk-linux-v${APP_VERSION}.AppImage" \
            "${WORK_DIR}/built.AppImage"; then
        "$CONTAINER_CMD" rm "$container_name" > /dev/null 2>&1 || true
        "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true
        die_build "Could not extract built AppImage from container"
    fi
    "$CONTAINER_CMD" rm "$container_name" > /dev/null
    "$CONTAINER_CMD" rmi "$image_name" > /dev/null 2>&1 || true

    local sz; sz="$(stat -c%s "${WORK_DIR}/built.AppImage")"
    BUILT_APPIMAGE_SHA256="$(sha256_of "${WORK_DIR}/built.AppImage")"
    log_ok "Built AppImage ready: built.AppImage (${sz} bytes)"
    log_ok "  sha256: ${BUILT_APPIMAGE_SHA256}"
}

compare_appimages() {
    # Extract both AppImages with unsquashfs and run diff -r on the directory trees.
    # Whole-AppImage hash comparison is not used: appimagetool embeds a wall-clock timestamp
    # in the squashfs superblock, so hashes always differ even with identical contents.
    log_info "Extracting AppImages with unsquashfs..."
    local official_dir="${WORK_DIR}/official-squashfs"
    local built_dir="${WORK_DIR}/built-squashfs"
    rm -rf "$official_dir" "$built_dir"

    # Each AppImage carries its SquashFS at a byte offset after the ELF runtime, and
    # the official and built images can have DIFFERENT offsets — detect each on the
    # host (works without unsquashfs) so the same values feed both the host and the
    # container extraction paths. A failure here is an extraction-tooling problem,
    # not a build outcome.
    local official_offset built_offset
    official_offset="$(detect_appimage_offset "${WORK_DIR}/official.AppImage")" \
        || die_build "Could not determine SquashFS offset for official AppImage (extraction tooling failure, not a build result)"
    built_offset="$(detect_appimage_offset "${WORK_DIR}/built.AppImage")" \
        || die_build "Could not determine SquashFS offset for built AppImage (extraction tooling failure, not a build result)"
    log_info "SquashFS offsets -- official: ${official_offset}, built: ${built_offset}"

    if command -v unsquashfs >/dev/null 2>&1; then
        # Use host unsquashfs if available -- faster than spinning up a container.
        unsquashfs -o "$official_offset" -d "$official_dir" "${WORK_DIR}/official.AppImage" > /dev/null 2>&1 || \
            die_build "unsquashfs failed on official AppImage at offset ${official_offset} (extraction tooling failure)"
        unsquashfs -o "$built_offset" -d "$built_dir" "${WORK_DIR}/built.AppImage" > /dev/null 2>&1 || \
            die_build "unsquashfs failed on built AppImage at offset ${built_offset} (extraction tooling failure)"
    else
        log_info "Host unsquashfs not found; extracting via container (installs squashfs-tools)..."
        # Mount WORK_DIR into an ubuntu container and run unsquashfs there, using the
        # host-computed offsets (the AppImage cannot self-execute inside the container).
        "$CONTAINER_CMD" run --rm \
            -v "${WORK_DIR}:/work" \
            ubuntu:24.04 \
            bash -c "apt-get update -qq && apt-get install -y -qq squashfs-tools > /dev/null && \
                     unsquashfs -o ${official_offset} -d /work/official-squashfs /work/official.AppImage > /dev/null && \
                     unsquashfs -o ${built_offset}    -d /work/built-squashfs    /work/built.AppImage    > /dev/null" \
            || die_build "Container unsquashfs extraction failed (offsets official=${official_offset} built=${built_offset}; extraction tooling failure)"
    fi

    log_info "Running diff -r on extracted squashfs trees..."
    local diff_file="${WORK_DIR}/diff_squashfs.txt"
    local diff_exit=0
    # diff returns 1 if files differ; 2 on error. Capture exit without triggering set -e.
    diff -r "$official_dir" "$built_dir" > "$diff_file" 2>&1 || diff_exit=$?
    if [[ "$diff_exit" -gt 1 ]]; then
        die_build "diff -r failed with exit code $diff_exit"
    fi

    local total_lines; total_lines="$(wc -l < "$diff_file")"
    log_info "Full diff: $diff_file ($total_lines lines)"

    local official_sz; official_sz="$(stat -c%s "${WORK_DIR}/official.AppImage")"
    local built_sz;    built_sz="$(stat -c%s "${WORK_DIR}/built.AppImage")"
    local size_delta=$(( official_sz - built_sz ))
    local brief_diff_file="${WORK_DIR}/diff_squashfs_brief.txt"
    local reason_file="${WORK_DIR}/why_not_reproducible.txt"
    local brief_exit=0
    diff -rq "$official_dir" "$built_dir" > "$brief_diff_file" 2>&1 || brief_exit=$?
    if [[ "$brief_exit" -gt 1 ]]; then
        die_build "diff -rq failed with exit code $brief_exit"
    fi

    local differing_files official_only built_only
    differing_files="$(grep -c '^Files ' "$brief_diff_file" || true)"
    official_only="$(grep -F -c "Only in ${official_dir}" "$brief_diff_file" || true)"
    built_only="$(grep -F -c "Only in ${built_dir}" "$brief_diff_file" || true)"

    local context_note=""
    if [[ "$brief_exit" -eq 1 ]]; then
        context_note="$(comparison_context_note)"
        {
            echo "WHY NOT REPRODUCIBLE"
            echo "Reason: the extracted official and rebuilt AppImages contain substantive differences."
            printf 'Differing files: %s; official-only entries: %s; rebuilt-only entries: %s\n' \
                "$differing_files" "$official_only" "$built_only"
            echo "AppImage size delta: ${size_delta} bytes"
            echo "Context: $context_note"
            echo ""
            echo "Differing executables:"
            grep -E '^Files .*/bin/' "$brief_diff_file" | sed "s#${WORK_DIR}/##g" || echo "(none)"
            echo ""
            echo "Differing shared libraries:"
            grep -E '^Files .*/lib/' "$brief_diff_file" | sed "s#${WORK_DIR}/##g" || echo "(none)"
            echo ""
            echo "Official-only entries:"
            grep -F "Only in ${official_dir}" "$brief_diff_file" | sed "s#${WORK_DIR}/##g" || echo "(none)"
            echo ""
            echo "Rebuilt-only entries:"
            grep -F "Only in ${built_dir}" "$brief_diff_file" | sed "s#${WORK_DIR}/##g" || echo "(none)"
            echo ""
            echo "All brief differences:"
            sed "s#${WORK_DIR}/##g" "$brief_diff_file"
        } > "$reason_file"
        log_info "Reason summary: $reason_file"
        echo ""
        echo "======================================================"
        sed -n '1,18p' "$reason_file"
        echo "Full categorized reason: $reason_file"
        echo "======================================================"
        echo ""
    fi


    echo ""
    echo "======================================================"
    echo "SQUASHFS DIFF PREVIEW (first 5 lines; full diff in ${WORK_DIR}/diff_squashfs.txt)"
    echo "======================================================"
    if [[ "$total_lines" -eq 0 ]]; then
        echo "(No differences)"
    else
        head -5 "$diff_file"
        if [[ "$total_lines" -gt 5 ]]; then
            echo "... ($total_lines lines total)"
        fi
    fi
    echo ""
    echo "Official AppImage: $official_sz bytes"
    echo "Built AppImage:    $built_sz bytes"
    echo "Size delta:        $size_delta bytes"
    echo "======================================================"
    echo ""

    if [[ "$total_lines" -eq 0 && "$diff_exit" -eq 0 ]]; then
        log_ok "Squashfs contents IDENTICAL"
        write_yaml "reproducible" \
            "Built from source at tag ${APP_VERSION}. Squashfs-extracted contents are identical."
        return 0
    else
        local context_note
        context_note="$(comparison_context_note)"
        log_warn "Squashfs contents DIFFER ($total_lines diff lines; size delta $size_delta bytes)"
        log_warn "$context_note"
        write_yaml "not_reproducible" \
            "Substantive squashfs differences found: ${total_lines} diff lines; AppImage size delta: ${size_delta} bytes. ${context_note} See diff_squashfs.txt."
        return 1
    fi
}

# Resolve the git commit that tag APP_VERSION points at (dereferences annotated tags).
# Network is already required for the build, so a remote lookup here is acceptable.
resolve_commit() {
    local ref
    ref="$(git ls-remote "https://github.com/${GH_REPO}.git" \
              "refs/tags/${APP_VERSION}^{}" "refs/tags/${APP_VERSION}" 2>/dev/null \
              | awk 'END{print $1}')"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && echo "$ref" || echo "unknown"
}

# Plain-language legend for the several meaningful hashes this app produces. Kept OUTSIDE the
# Begin/End Results markers so that block stays a clean key: value list (dannys-amendments.md,
# "Ambiguous Artifact Hashes"; reference implementation blockstreamjade_build.sh v0.2.0).
print_hash_legend() {
    echo ""
    echo "HASH LEGEND"
    echo "  appHash          sha256 of ${OFFICIAL_ARTIFACT_NAME:-the official artifact} exactly as"
    echo "                   distributed. THIS is the hash to publish — a user reproduces it with"
    echo "                   sha256sum on the file they downloaded."
    echo "  appImageHash     sha256 of the AppImage extracted from that artifact. This is the"
    echo "                   payload the comparison actually ran against. DO NOT publish it."
    echo "  builtAppImageHash sha256 of our rebuilt AppImage. Recorded for the record only; it is"
    echo "                   never expected to match, because appimagetool embeds wall-clock time"
    echo "                   in the squashfs superblock and upstream sets no SOURCE_DATE_EPOCH."
    echo "  scriptHash       sha256 of this verification script, so a reader can confirm which"
    echo "                   revision of the tooling produced these results."
}

# Standardized WalletScrutiny verification summary (verification-result-summary-format.md).
# Parsed by the legacy test.sh format; the machine verdict still lives in COMPARISON_RESULTS.yaml.
emit_verification_summary() {
    local yaml_verdict summary_verdict commit
    yaml_verdict="$(awk '/^verdict:/{print $2}' "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml" 2>/dev/null)"
    case "$yaml_verdict" in
        reproducible)     summary_verdict="reproducible" ;;
        not_reproducible) summary_verdict="differences found" ;;
        ftbfs)            summary_verdict="" ;;
        *)                summary_verdict="$yaml_verdict" ;;
    esac
    commit="$(resolve_commit)"

    print_hash_legend

    # appHash is the artifact EXACTLY AS DOWNLOADED (the release ZIP), per
    # verification-result-summary-format.md and test.sh:149. Through v0.1.6 this field wrongly
    # carried the inner AppImage hash — the same defect class as GitLab issue 957.
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A (unsigned AppImage)"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${summary_verdict}"
    echo "appHash:        ${OFFICIAL_ARTIFACT_SHA256:-N/A}"
    echo "officialFile:   ${OFFICIAL_ARTIFACT_NAME:-N/A}"
    echo "appImageHash:   ${OFFICIAL_APPIMAGE_SHA256:-N/A}"
    echo "builtAppImageHash: ${BUILT_APPIMAGE_SHA256:-N/A}"
    echo "commit:         ${commit}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
    echo ""
    echo "Diff:"
    # Brief (one line per differing file) so the summary stays log-friendly; the full
    # content diff is in diff_squashfs.txt.
    if [[ -s "${WORK_DIR}/diff_squashfs.txt" ]]; then
        # diff returns 1 when files differ (expected for Nunchuk); never let that abort
        # the summary under set -e/pipefail.
        { diff -rq "${WORK_DIR}/official-squashfs" "${WORK_DIR}/built-squashfs" 2>&1 || true; } \
            | sed "s#${WORK_DIR}/##g"
    else
        echo "(no differences)"
    fi
    echo ""
    echo "===== End Results ====="
}

main() {
    echo ""
    echo "======================================================"
    echo "${APP_NAME} Reproducible Build Verifier ${SCRIPT_VERSION}"
    echo "======================================================"
    echo ""

    # Self-identify before doing anything else, so a recording of this run always shows which
    # bytes of tooling produced the result without the operator having to remember to hash it.
    SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"

    parse_args "$@"
    detect_container_cmd
    setup_workdir

    log_info "Version: ${APP_VERSION}"
    log_info "Arch:    ${APP_ARCH}"
    log_info "Type:    ${APP_TYPE}"
    [[ -n "$BINARY_PATH" ]] && log_info "Binary:  ${BINARY_PATH}"
    echo ""

    prepare_official
    check_build_inputs

    local verdict_exit=0
    run_build
    compare_appimages || verdict_exit=$?

    emit_verification_summary

    echo ""
    echo "======================================================"
    echo "RESULTS (machine-readable verdict in COMPARISON_RESULTS.yaml)"
    echo "======================================================"
    cat "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    echo ""
    echo "Work directory: ${WORK_DIR}"
    echo "Full squashfs diff: ${WORK_DIR}/diff_squashfs.txt"
    if [[ -f "${WORK_DIR}/why_not_reproducible.txt" ]]; then
        echo "Reason summary: ${WORK_DIR}/why_not_reproducible.txt"
    fi
    echo "Brief squashfs diff: ${WORK_DIR}/diff_squashfs_brief.txt"
    echo "======================================================"
    echo ""

    exit "$verdict_exit"
}

main "$@"
