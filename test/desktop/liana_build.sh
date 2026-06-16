#!/usr/bin/env bash
# ==============================================================================
# liana_build.sh - Liana Desktop Wallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.1.11
# Organization:  WalletScrutiny.com
# Project:       https://github.com/wizardsardine/liana
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose. Users assume all
# risks associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws and regulations. The developers assume no liability for any
# misuse or legal consequences arising from use of this script.
#
# SCRIPT SUMMARY:
# - Clones Liana at the release tag, builds via the official guix-build.sh in an
#   Alpine+Guix container, compares SHA256 vs the official release (or --binary),
#   and writes COMPARISON_RESULTS.yaml for build server automation.
#
# CREDITS: Alpine+Guix approach adapted from fanquake/core-review and WS bitcoincore_build.sh.

set -euo pipefail

# ==============================================================================
# Metadata
# ==============================================================================
SCRIPT_VERSION="v0.1.11"
SCRIPT_NAME="liana_build.sh"
APP_NAME="Liana"
APP_ID="liana"
CONTAINER_NAME=""
IMAGE_NAME=""
VERIFICATION_EXIT_CODE=1
TRAP_CLEANUP_COMPLETED=false
TAG_SIG_STATUS="not verified"
BUILT_COMMIT_HASH=""

# ==============================================================================
# Styling
# ==============================================================================
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
SUCCESS_ICON="[OK]"
WARNING_ICON="[WARN]"
ERROR_ICON="[ERROR]"
INFO_ICON="[INFO]"

# ==============================================================================
# Logging
# ==============================================================================
log_info()    { echo -e "${BLUE}${INFO_ICON}${NC} $*"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON}${NC} $*"; }
log_warn()    { echo -e "${YELLOW}${WARNING_ICON}${NC} $*"; }
log_error()   { echo -e "${RED}${ERROR_ICON}${NC} $*" >&2; }

# ==============================================================================
# YAML Output
# ==============================================================================
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
comparison_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

generate_yaml() {
    local verdict="$1"
    local notes="${2:-}"
    cat > "$comparison_file" << YAML
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}
YAML
}

generate_error_yaml() {
    local verdict="${1:-ftbfs}"
    local notes="${2:-Build or verification step failed. See script output for details.}"
    generate_yaml "$verdict" "$notes"
}

# ==============================================================================
# Usage
# ==============================================================================
usage() {
    cat << EOF
${APP_NAME} Reproducible Build Verification Script

Usage:
  $(basename "$0") --version <version> [--arch <arch>] [--type <type>]

Required Parameters:
  --version <version>    Liana version to verify (e.g., 13.0, 13.1)

Optional Parameters:
  --arch <arch>          Target architecture (default: x86_64-linux-gnu)
                         Supported: x86_64-linux-gnu
  --type <type>          Artifact type (default: tarball)
                         Supported: tarball, deb, exe
  --binary <file>        Path to official release file (skips download)
                         For tarball: path to .tar.gz
                         For deb:     path to .deb
                         For exe:     path to liana-VERSION-noncodesigned.exe

Flags:
  --help                 Show this help message
  --keep-container       Keep container running after build (for debugging)

Examples:
  $(basename "$0") --version 13.0
  $(basename "$0") --version 13.1 --arch x86_64-linux-gnu --type tarball
  $(basename "$0") --version 13.0 --binary /tmp/liana-13.0-x86_64-linux-gnu.tar.gz

Requirements:
  - Docker or Podman installed (only host dependency)
  - Internet connection (for Guix substitutes and source download)
  - ~10 GB disk space for Guix store + build artifacts
  - 60-180 minutes build time (Guix downloads packages on first run)

Output:
  - Exit code 0: Binaries are reproducible
  - Exit code 1: Binaries differ or build failed
  - Exit code 2: Invalid parameters
  - COMPARISON_RESULTS.yaml: Machine-readable result

Note: Windows (.exe) is supported via Nix MinGW cross-compile (--type exe).
macOS is not supported (requires a non-redistributable Xcode 12.2 SDK).

Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com
EOF
}

# ==============================================================================
# Helpers
# ==============================================================================
sanitize_name() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g')
    input="${input##-}"
    input="${input%%-}"
    [[ -z "$input" ]] && input="na"
    echo "$input"
}

set_unique_names() {
    local ver arch typ suffix
    ver=$(sanitize_name "$1")
    arch=$(sanitize_name "$2")
    typ=$(sanitize_name "$3")
    suffix=$(sanitize_name "$(date +%s)-$$")
    CONTAINER_NAME="ws-liana-verifier-${ver}-${arch}-${typ}-${suffix}"
    IMAGE_NAME="ws-liana-image-${ver}-${arch}-${typ}-${suffix}"
}

require_arg() {
    local flag="$1"
    local val="$2"
    if [[ -z "$val" ]]; then
        log_error "Flag ${flag} requires an argument"
        exit 2
    fi
}

# ==============================================================================
# Cleanup
# ==============================================================================
cleanup_containers() {
    if [[ -n "$CONTAINER_NAME" ]]; then
        ${container_cmd} rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi
    if [[ -n "$IMAGE_NAME" ]]; then
        ${container_cmd} rmi -f "$IMAGE_NAME" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    if [[ "$TRAP_CLEANUP_COMPLETED" == "true" ]]; then
        return
    fi
    log_warn "Unexpected exit — running cleanup"
    generate_error_yaml "ftbfs" "Script exited unexpectedly before verification completed."
    cleanup_containers
}
trap cleanup_on_exit EXIT

# ==============================================================================
# Check dependencies
# ==============================================================================
check_dependencies() {
    if [[ "$(id -u)" -eq 0 ]]; then
        log_error "This script must not be run as root."
        generate_error_yaml "ftbfs" "Script was run as root. Run as a normal user."
        exit 1
    fi
    if command -v docker &>/dev/null; then
        container_cmd="docker"
    elif command -v podman &>/dev/null; then
        container_cmd="podman"
    else
        log_error "Docker or Podman is required but not found."
        generate_error_yaml "ftbfs" "Docker or Podman not installed on host."
        exit 1
    fi
    log_info "Using container runtime: ${container_cmd}"
}

# ==============================================================================
# Dockerfile (Alpine + Guix 1.4.0)
# Adapted from fanquake/core-review and bitcoincore_build.sh
# Guix 1.4.0 checksums from https://ftpmirror.gnu.org/gnu/guix/
# rust + cargo added via apk for the cargo vendor step in guix-build.sh
# ==============================================================================
create_imagefile() {
    local imagefile_path="$1"
    log_info "Creating Alpine+Guix imagefile..."

    cat > "$imagefile_path" << 'DOCKERFILE'
FROM alpine:3.22 AS base

RUN apk --no-cache --update add \
      bash \
      binutils \
      bzip2 \
      ca-certificates \
      curl \
      git \
      make \
      rust \
      cargo \
      shadow \
      wget \
      xz

ARG guix_download_path=https://ftpmirror.gnu.org/gnu/guix/
ARG guix_version=1.4.0
ARG guix_checksum_aarch64=72d807392889919940b7ec9632c45a259555e6b0942ea7bfd131101e08ebfcf4
ARG guix_checksum_x86_64=236ca7c9c5958b1f396c2924fcc5bc9d6fdebcb1b4cf3c7c6d46d4bf660ed9c9
ARG builder_count=32

ENV PATH=/root/.config/guix/current/bin:$PATH
ENV GUIX_LOCPATH=/root/.guix-profile/lib/locale
ENV LC_ALL=en_US.UTF-8

RUN guix_file_name=guix-binary-${guix_version}.$(uname -m)-linux.tar.xz       && \
    eval "guix_checksum=\${guix_checksum_$(uname -m)}"                         && \
    cd /tmp                                                                     && \
    wget -q -O "$guix_file_name" "${guix_download_path}/${guix_file_name}"     && \
    echo "${guix_checksum}  ${guix_file_name}" | sha256sum -c                  && \
    tar xJf "$guix_file_name"                                                   && \
    mv var/guix /var/                                                           && \
    mv gnu /                                                                    && \
    mkdir -p ~root/.config/guix                                                 && \
    ln -sf /var/guix/profiles/per-user/root/current-guix ~root/.config/guix/current && \
    . ~root/.config/guix/current/etc/profile

RUN groupadd --system guixbuild
RUN for i in $(seq -w 1 ${builder_count}); do       \
      useradd -g guixbuild -G guixbuild             \
              -d /var/empty -s $(which nologin)      \
              -c "Guix build user ${i}" --system     \
              "guixbuilder${i}" ;                    \
    done

RUN for k in bordeaux.guix.gnu.org ci.guix.gnu.org; do guix archive --authorize < ~root/.config/guix/current/share/guix/$k.pub; done

# Daemon started by start_container with the chosen substitute server.
CMD ["sleep","infinity"]
DOCKERFILE

    log_success "Imagefile created: $imagefile_path"
}

# ==============================================================================
# Build container image
# ==============================================================================
build_container() {
    local imagefile_path="$1"
    log_info "Building Alpine+Guix container image: ${IMAGE_NAME}"
    log_info "This installs Guix 1.4.0 — may take 5-15 minutes..."

    if ! ${container_cmd} build --pull --no-cache -t "$IMAGE_NAME" - < "$imagefile_path"; then
        log_error "Container image build failed"
        generate_error_yaml "ftbfs" "Failed to build Alpine+Guix Docker image."
        exit 1
    fi
    log_success "Container image built: ${IMAGE_NAME}"
}

# ==============================================================================
# Start container (privileged — required for Guix inner containers)
# ==============================================================================
start_container() {
    log_info "Starting container: ${CONTAINER_NAME}"

    if ${container_cmd} container inspect "$CONTAINER_NAME" &>/dev/null; then
        ${container_cmd} rm -f "$CONTAINER_NAME" || true
    fi

    if ! ${container_cmd} run -d --name "$CONTAINER_NAME" --privileged "$IMAGE_NAME"; then
        log_error "Failed to start container"
        generate_error_yaml "ftbfs" "Failed to start Guix daemon container."
        exit 1
    fi

    # ci.guix flaky; if down, log it (non-fatal) and use bordeaux.
    local sub_urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org"
    if ! curl -fsS -o /dev/null --max-time 15 https://ci.guix.gnu.org/ 2>/dev/null; then
        log_error "ci.guix.gnu.org unreachable — falling back to bordeaux.guix.gnu.org substitutes"
        sub_urls="https://bordeaux.guix.gnu.org"
    fi
    ${container_cmd} exec -d "$CONTAINER_NAME" /root/.config/guix/current/bin/guix-daemon \
        --build-users-group=guixbuild --substitute-urls="${sub_urls}"

    sleep 3
    log_success "Container started: ${CONTAINER_NAME}"
}

# ==============================================================================
# Clone and checkout Liana at the release tag
# ==============================================================================
prepare_liana_build() {
    local version="$1"

    log_info "Cloning Liana repository inside container..."
    ${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "git clone --depth=1 --branch v${version} https://github.com/wizardsardine/liana.git /liana"

    log_info "Verifying tag v${version}..."
    local sig_output
    sig_output=$(${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "cd /liana && git verify-tag v${version} 2>&1" || true)
    if echo "$sig_output" | grep -q "Good signature"; then
        TAG_SIG_STATUS="verified — $(echo "$sig_output" | grep 'Good signature' | head -1 | sed 's/^[[:space:]]*//')"
        log_success "GPG tag signature verified for v${version}"
    else
        TAG_SIG_STATUS="not verified"
        log_warn "GPG tag signature not verified for v${version} — continuing"
    fi

    BUILT_COMMIT_HASH=$(${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "cd /liana && git rev-parse HEAD")
    log_info "Commit hash: ${BUILT_COMMIT_HASH}"

    local actual_version
    actual_version=$(${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "grep '^version' /liana/Cargo.toml | head -1 | sed 's/.*= *\"//;s/\".*//'")
    log_info "Cargo.toml version: ${actual_version}"

    log_success "Liana v${version} ready for build"
}

# ==============================================================================
# Execute the official Guix build inside the container
# guix-build.sh: cargo vendor, time-machine, zigbuild, patchelf
# First run downloads Guix packages from substitutes — may take 60-180 minutes
# ==============================================================================
execute_guix_build() {
    local version="$1"
    local jobs
    jobs=$(nproc 2>/dev/null || echo 4)

    log_info "Starting official Guix reproducible build for Liana v${version}..."
    log_info "Architecture: x86_64-unknown-linux-gnu.2.31"
    log_info "This will take 60-180 minutes on first run (Guix downloads packages)."
    log_info "Subsequent runs are faster if the Guix store is cached."

    local start_time
    start_time=$(date +%s)

    local build_cmd
    build_cmd="cd /liana && BUILD_ROOT=/tmp/liana-guix-build OUT_DIR=/tmp/liana-guix-out JOBS=${jobs} ./contrib/reproducible/guix/guix-build.sh"

    if ${container_cmd} exec "$CONTAINER_NAME" bash -c "$build_cmd"; then
        local end_time duration
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log_success "Guix build completed in ${duration}s"
    else
        log_error "Guix build failed"
        generate_error_yaml "ftbfs" "Official Guix build script failed. See output above."
        exit 1
    fi
}

# ==============================================================================
# Copy built binaries out of container
# ==============================================================================
copy_built_binaries() {
    local dest_dir="$1"

    log_info "Copying built binaries from container..."
    mkdir -p "${dest_dir}"

    for bin in lianad liana-cli liana-gui; do
        if ! ${container_cmd} cp "${CONTAINER_NAME}:${CONTAINER_BUILT_RELEASE_PATH}/${bin}" "${dest_dir}/${bin}"; then
            log_error "Could not copy ${bin} from container — build may have failed"
            generate_error_yaml "ftbfs" "Built binary ${bin} not found at expected path ${CONTAINER_BUILT_RELEASE_PATH}/${bin}."
            exit 1
        fi
        local size
        size=$(${container_cmd} exec "$CONTAINER_NAME" stat -c "%s" "${CONTAINER_BUILT_RELEASE_PATH}/${bin}")
        log_success "Copied: ${bin} (${size} bytes)"
    done
}

# ==============================================================================
# DEB: download, verify, and extract official deb inside container
# Called by prepare_official_binaries when --type deb is used.
# Sets globals CONTAINER_OFFICIAL_PATH and OFFICIAL_EXTRACTED_DIR.
# Tarball pipeline is completely unaffected by this function.
# ==============================================================================
_fetch_and_extract_deb() {
    local version="$1"
    local binary_file="$2"
    local dest_dir="$3"

    local deb_name="liana-${version}-1_amd64.deb"
    local shasums_name="liana-${version}-shasums.txt"
    local base_url="https://github.com/wizardsardine/liana/releases/download/v${version}"
    local container_dir="/tmp/liana-official"
    local container_bins="${container_dir}/deb-bins"

    ${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "mkdir -p ${container_dir} ${container_bins} ${container_dir}/deb-work ${container_dir}/deb-data"

    if [[ -n "$binary_file" ]]; then
        log_info "Using provided binary: ${binary_file}"
        if [[ ! -f "$binary_file" ]]; then
            log_error "--binary file not found: ${binary_file}"
            generate_error_yaml "ftbfs" "--binary file not found: ${binary_file}"
            exit 1
        fi
        ${container_cmd} cp "$binary_file" "${CONTAINER_NAME}:${container_dir}/${deb_name}"
    else
        log_info "Downloading official deb inside container: ${deb_name}"
        ${container_cmd} exec "$CONTAINER_NAME" bash -c \
            "curl -fsSL -o ${container_dir}/${deb_name} ${base_url}/${deb_name}"

        log_info "Downloading checksums inside container: ${shasums_name}"
        ${container_cmd} exec "$CONTAINER_NAME" bash -c \
            "curl -fsSL -o ${container_dir}/${shasums_name} ${base_url}/${shasums_name}"

        log_info "Verifying official deb integrity inside container..."
        if ${container_cmd} exec "$CONTAINER_NAME" bash -c "
            expected=\$(grep '${deb_name}' '${container_dir}/${shasums_name}' | cut -d' ' -f1)
            actual=\$(sha256sum '${container_dir}/${deb_name}' | cut -d' ' -f1)
            [ \"\$expected\" = \"\$actual\" ]
        "; then
            log_success "Official deb integrity verified"
        else
            log_error "Official deb checksum mismatch — aborting"
            generate_error_yaml "ftbfs" "Official deb checksum verification failed."
            exit 1
        fi
    fi

    log_info "Extracting deb inside container..."
    if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "
        cd ${container_dir}/deb-work && ar x ${container_dir}/${deb_name}
        data_archive=\$(ls data.tar.* 2>/dev/null | head -1)
        if [[ -z \"\$data_archive\" ]]; then
            echo 'ERROR: no data.tar.* found in deb' >&2
            exit 1
        fi
        tar -xf \"\${data_archive}\" -C ${container_dir}/deb-data/
    "; then
        log_error "Failed to extract official deb"
        generate_error_yaml "ftbfs" "Failed to extract official deb data archive."
        exit 1
    fi

    log_info "Locating binaries inside deb..."
    for bin in lianad liana-cli liana-gui; do
        if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "
            found=\$(find ${container_dir}/deb-data/ -name '${bin}' -type f | head -1)
            if [[ -z \"\$found\" ]]; then
                echo 'ERROR: ${bin} not found in deb' >&2
                exit 1
            fi
            cp \"\$found\" ${container_bins}/${bin}
        "; then
            log_error "Binary ${bin} not found inside official deb"
            generate_error_yaml "ftbfs" "Binary ${bin} not found inside official deb."
            exit 1
        fi
    done
    log_success "Deb binaries extracted to container: ${container_bins}"

    mkdir -p "${dest_dir}"
    for bin in lianad liana-cli liana-gui; do
        if ! ${container_cmd} cp "${CONTAINER_NAME}:${container_bins}/${bin}" "${dest_dir}/${bin}"; then
            log_error "Failed to copy deb binary ${bin} from container to host"
            generate_error_yaml "ftbfs" "Failed to copy deb binary ${bin} from container."
            exit 1
        fi
    done

    CONTAINER_OFFICIAL_PATH="$container_bins"
    OFFICIAL_EXTRACTED_DIR="$dest_dir"
}

# ==============================================================================
# Download and verify official release
# Sets global OFFICIAL_EXTRACTED_DIR — do not capture stdout from this function
# (log_info writes to stdout; capturing would mix log text with the path)
# Dispatches to _fetch_and_extract_deb for --type deb; tarball path unchanged.
# ==============================================================================
OFFICIAL_EXTRACTED_DIR=""
CONTAINER_BUILT_RELEASE_PATH="/tmp/liana-guix-out/x86_64-unknown-linux-gnu/release"
CONTAINER_OFFICIAL_PATH=""
CONTAINER_NIX_EXE_PATH=""
CONTAINER_OFFICIAL_EXE_PATH=""

prepare_official_binaries() {
    local version="$1"
    local binary_file="$2"
    local dest_dir="$3"

    # Dispatch to deb handler — tarball path below is untouched
    if [[ "$build_type" == "deb" ]]; then
        _fetch_and_extract_deb "$version" "$binary_file" "$dest_dir"
        return
    fi

    local tarball_name="liana-${version}-x86_64-linux-gnu.tar.gz"
    local shasums_name="liana-${version}-shasums.txt"
    local base_url="https://github.com/wizardsardine/liana/releases/download/v${version}"
    local container_dir="/tmp/liana-official"
    local container_extracted="${container_dir}/liana-${version}-x86_64-linux-gnu"

    # All download, verify, and extract steps run inside the container.
    # Only Docker/Podman is required on the host.
    ${container_cmd} exec "$CONTAINER_NAME" bash -c "mkdir -p ${container_dir}"

    if [[ -n "$binary_file" ]]; then
        log_info "Using provided binary: ${binary_file}"
        if [[ ! -f "$binary_file" ]]; then
            log_error "--binary file not found: ${binary_file}"
            generate_error_yaml "ftbfs" "--binary file not found: ${binary_file}"
            exit 1
        fi
        ${container_cmd} cp "$binary_file" "${CONTAINER_NAME}:${container_dir}/${tarball_name}"
    else
        log_info "Downloading official release inside container: ${tarball_name}"
        ${container_cmd} exec "$CONTAINER_NAME" bash -c \
            "curl -fsSL -o ${container_dir}/${tarball_name} ${base_url}/${tarball_name}"

        log_info "Downloading checksums inside container: ${shasums_name}"
        ${container_cmd} exec "$CONTAINER_NAME" bash -c \
            "curl -fsSL -o ${container_dir}/${shasums_name} ${base_url}/${shasums_name}"

        log_info "Verifying official download integrity inside container..."
        # grep-isolate the line — avoids busybox sha256sum --ignore-missing issues
        if ${container_cmd} exec "$CONTAINER_NAME" bash -c "
            expected=\$(grep '${tarball_name}' '${container_dir}/${shasums_name}' | cut -d' ' -f1)
            actual=\$(sha256sum '${container_dir}/${tarball_name}' | cut -d' ' -f1)
            [ \"\$expected\" = \"\$actual\" ]
        "; then
            log_success "Official download integrity verified"
        else
            log_error "Official download checksum mismatch — aborting"
            generate_error_yaml "ftbfs" "Official release checksum verification failed."
            exit 1
        fi
    fi

    log_info "Extracting official binaries inside container..."
    ${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "tar -xzf ${container_dir}/${tarball_name} -C ${container_dir}"

    # Tar extracts to liana-{VERSION}-x86_64-linux-gnu/ (not liana-{VERSION}/)
    if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "[[ -d ${container_extracted} ]]"; then
        log_error "Expected extraction directory not found in container: ${container_extracted}"
        generate_error_yaml "ftbfs" "Official tar.gz did not extract to expected directory."
        exit 1
    fi

    for bin in lianad liana-cli liana-gui; do
        if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "[[ -f ${container_extracted}/${bin} ]]"; then
            log_error "Binary not found in official release: ${bin}"
            generate_error_yaml "ftbfs" "Official binary ${bin} missing from tar.gz."
            exit 1
        fi
    done

    # Copy extracted binaries to host for human analysis (diffoscope, etc.)
    mkdir -p "${dest_dir}"
    for bin in lianad liana-cli liana-gui; do
        if ! ${container_cmd} cp "${CONTAINER_NAME}:${container_extracted}/${bin}" "${dest_dir}/${bin}"; then
            log_error "Failed to copy official binary ${bin} from container to host"
            generate_error_yaml "ftbfs" "Failed to copy official binary ${bin} from container."
            exit 1
        fi
    done

    CONTAINER_OFFICIAL_PATH="$container_extracted"
    OFFICIAL_EXTRACTED_DIR="$dest_dir"
}

# ==============================================================================
# Compare binaries and generate results
# ==============================================================================
verify_checksums() {
    local version="$1"
    local built_dir="$2"
    local official_dir="$3"

    log_info "Comparing built binaries against official release..."

    local match_count=0
    local diff_count=0
    local verdict="reproducible"
    local notes=""

    echo ""
    echo "===== Begin Results ====="
    echo "appId:       ${APP_ID}"
    echo "signer:      N/A"
    echo "version:     ${version}"
    echo ""
    echo "Binary comparison:"
    echo ""

    for bin in lianad liana-cli liana-gui; do
        local host_built_path="${built_dir}/${bin}"
        local host_official_path="${official_dir}/${bin}"
        local raw_built raw_official built_hash official_hash built_size official_size
        # Hash/measure inside the container — no host tools required
        raw_built=$(${container_cmd} exec "$CONTAINER_NAME" sha256sum "${CONTAINER_BUILT_RELEASE_PATH}/${bin}")
        raw_official=$(${container_cmd} exec "$CONTAINER_NAME" sha256sum "${CONTAINER_OFFICIAL_PATH}/${bin}")
        built_hash="${raw_built%% *}"
        official_hash="${raw_official%% *}"
        built_size=$(${container_cmd} exec "$CONTAINER_NAME" stat -c "%s" "${CONTAINER_BUILT_RELEASE_PATH}/${bin}")
        official_size=$(${container_cmd} exec "$CONTAINER_NAME" stat -c "%s" "${CONTAINER_OFFICIAL_PATH}/${bin}")

        if [[ "$built_hash" == "$official_hash" ]]; then
            echo "  MATCH    ${bin}"
            match_count=$((match_count + 1))
        else
            echo "  DIFFER   ${bin}"
            diff_count=$((diff_count + 1))
            verdict="not_reproducible"
        fi

        echo "    Built:    ${host_built_path}"
        echo "              ${built_hash}"
        echo "    Official: ${host_official_path}"
        echo "              ${official_hash}"
        echo ""
        echo "    File sizes:"
        echo "      Built:    ${built_size} bytes  ${host_built_path}"
        echo "      Official: ${official_size} bytes  ${host_official_path}"
        echo ""
    done

    echo ""

    if [[ "$verdict" == "reproducible" ]]; then
        echo "verdict:     reproducible"
        notes="All 3 binaries (lianad, liana-cli, liana-gui) match the official release byte-for-byte."
    else
        echo "verdict:     not_reproducible"
        notes="SHA256 mismatch on ${diff_count} of 3 binaries. Matching: ${match_count}. Run diffoscope for analysis."
    fi

    echo "commit:      ${BUILT_COMMIT_HASH}"
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Git tag:     v${version}"
    echo "Tag sig:     ${TAG_SIG_STATUS}"
    echo ""
    echo "===== End Results ====="
    echo ""

    generate_yaml "$verdict" "$notes"

    log_info "=============================================="
    log_info "Verification Summary"
    log_info "=============================================="
    log_info "App:          ${APP_NAME} v${version}"
    log_info "Matching:     ${match_count} / 3"
    log_info "Differing:    ${diff_count} / 3"

    if [[ "$verdict" == "reproducible" ]]; then
        log_success "Verdict: REPRODUCIBLE"
        VERIFICATION_EXIT_CODE=0
    else
        log_warn "Verdict: NOT REPRODUCIBLE"
        log_info "Run diffoscope on differing binaries for detailed analysis."
        VERIFICATION_EXIT_CODE=1
    fi

    log_info "Results: ${comparison_file}"
    log_info "Exit code: ${VERIFICATION_EXIT_CODE}"
}

# ==============================================================================
# Cleanup
# ==============================================================================
final_cleanup() {
    local keep="$1"
    if [[ "$keep" == "false" ]]; then
        log_info "Cleaning up container and image..."
        cleanup_containers
        log_success "Cleanup complete"
    else
        log_info "Container kept: ${CONTAINER_NAME}"
        log_info "To connect: ${container_cmd} exec -it ${CONTAINER_NAME} bash"
        log_info "To clean up later: ${container_cmd} rm -f ${CONTAINER_NAME} && ${container_cmd} rmi -f ${IMAGE_NAME}"
    fi
    TRAP_CLEANUP_COMPLETED=true
}

# ==============================================================================
# EXE: Dockerfile for Nix flakes + MinGW cross-compile (Windows noncodesigned.exe)
# Completely separate from the Alpine+Guix pipeline above — no shared code.
# ==============================================================================
_create_nix_imagefile() {
    local imagefile_path="$1"
    log_info "Creating NixOS imagefile for Windows exe build..."
    cat > "$imagefile_path" << 'DOCKERFILE'
FROM nixos/nix:2.24.10

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf && \
    echo "sandbox = false" >> /etc/nix/nix.conf

RUN nix-env -iA nixpkgs.git nixpkgs.curl
DOCKERFILE
    log_success "Nix imagefile created: $imagefile_path"
}

# ==============================================================================
# EXE: Compare liana-gui.exe built vs official (single binary, Nix/MinGW labels)
# Isolated to the exe path; does not touch the Linux trio.
# ==============================================================================
_verify_exe_checksums() {
    local version="$1"
    local built_dir="$2"
    local official_dir="$3"

    log_info "Comparing liana-gui.exe against official release..."

    local bin="liana-gui.exe"
    local host_built_path="${built_dir}/${bin}"
    local host_official_path="${official_dir}/${bin}"
    local raw_built raw_official built_hash official_hash built_size official_size

    raw_built=$(${container_cmd} exec "$CONTAINER_NAME" sha256sum "${CONTAINER_NIX_EXE_PATH}/${bin}")
    raw_official=$(${container_cmd} exec "$CONTAINER_NAME" sha256sum "${CONTAINER_OFFICIAL_EXE_PATH}/${bin}")
    built_hash="${raw_built%% *}"
    official_hash="${raw_official%% *}"
    built_size=$(${container_cmd} exec "$CONTAINER_NAME" stat -c "%s" "${CONTAINER_NIX_EXE_PATH}/${bin}")
    official_size=$(${container_cmd} exec "$CONTAINER_NAME" stat -c "%s" "${CONTAINER_OFFICIAL_EXE_PATH}/${bin}")

    local verdict notes

    echo ""
    echo "===== Begin Results ====="
    echo "appId:       ${APP_ID}"
    echo "signer:      N/A"
    echo "version:     ${version}"
    echo "pipeline:    Nix flakes / MinGW cross-compile"
    echo ""
    echo "Binary comparison:"
    echo ""

    if [[ "$built_hash" == "$official_hash" ]]; then
        echo "  MATCH    ${bin}"
        verdict="reproducible"
        notes="${bin} matches the official release byte-for-byte (Nix flakes / MinGW cross-compile)."
    else
        echo "  DIFFER   ${bin}"
        verdict="not_reproducible"
        notes="${bin} SHA256 mismatch. Run diffoscope for analysis."
    fi

    echo "    Built:    ${host_built_path}"
    echo "              ${built_hash}"
    echo "    Official: ${host_official_path}"
    echo "              ${official_hash}"
    echo ""
    echo "    File sizes:"
    echo "      Built:    ${built_size} bytes  ${host_built_path}"
    echo "      Official: ${official_size} bytes  ${host_official_path}"
    echo ""
    echo ""
    echo "verdict:     ${verdict}"
    echo "commit:      ${BUILT_COMMIT_HASH}"
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Git tag:     v${version}"
    echo "Tag sig:     ${TAG_SIG_STATUS}"
    echo ""
    echo "===== End Results ====="
    echo ""

    generate_yaml "$verdict" "$notes"

    log_info "=============================================="
    log_info "Verification Summary"
    log_info "=============================================="
    log_info "App:         ${APP_NAME} v${version} (Windows exe)"
    log_info "Pipeline:    Nix flakes / MinGW cross-compile"

    if [[ "$verdict" == "reproducible" ]]; then
        log_success "Verdict: REPRODUCIBLE"
        VERIFICATION_EXIT_CODE=0
    else
        log_warn "Verdict: NOT REPRODUCIBLE"
        log_info "Run diffoscope on differing binaries for detailed analysis."
        VERIFICATION_EXIT_CODE=1
    fi

    log_info "Results: ${comparison_file}"
    log_info "Exit code: ${VERIFICATION_EXIT_CODE}"
}

# ==============================================================================
# EXE: Full isolated Windows exe pipeline
# Owns its own container image, container lifecycle, clone, build, and compare.
# Exits before ANY Guix code runs — the caller does `exit "$VERIFICATION_EXIT_CODE"`
# immediately after this function returns.
# ==============================================================================
_run_nix_exe_pipeline() {
    local version="$1"
    local binary_file="$2"
    local workspace="$3"
    local built_dir="$4"
    local official_dir="$5"

    local exe_name="liana-${version}-noncodesigned.exe"
    local container_built="/tmp/liana-nix-out"
    local container_staging="/tmp/liana-nix-staging"
    local container_official="/tmp/liana-exe-official"

    log_info "=============================================="
    log_info "${APP_NAME} v${version} Windows exe Verification"
    log_info "=============================================="
    log_info "Script version:  ${SCRIPT_VERSION}"
    log_info "Pipeline:        Nix flakes / MinGW cross-compile"
    log_info "Container:       ${CONTAINER_NAME}"
    log_info "Workspace:       ${workspace}"
    log_info "=============================================="
    log_info ""

    local temp_nix_imagefile
    temp_nix_imagefile=$(mktemp /tmp/liana-nix-imagefile-XXXXXX)
    # Expand $temp_nix_imagefile NOW — double quotes bake the literal path into
    # the trap string so the local variable need not be in scope at EXIT time.
    # shellcheck disable=SC2064
    trap "rm -f '${temp_nix_imagefile}'; cleanup_on_exit" EXIT

    _create_nix_imagefile "$temp_nix_imagefile"

    log_info "Building Nix container image: ${IMAGE_NAME}"
    if ! ${container_cmd} build --pull --no-cache -t "$IMAGE_NAME" - < "$temp_nix_imagefile"; then
        log_error "Nix container image build failed"
        generate_error_yaml "ftbfs" "Failed to build NixOS Docker image."
        exit 1
    fi
    log_success "Nix container image built: ${IMAGE_NAME}"

    log_info "Starting Nix container: ${CONTAINER_NAME}"
    if ${container_cmd} container inspect "$CONTAINER_NAME" &>/dev/null; then
        ${container_cmd} rm -f "$CONTAINER_NAME" || true
    fi
    if ! ${container_cmd} run -d --name "$CONTAINER_NAME" --privileged "$IMAGE_NAME" sleep infinity; then
        log_error "Failed to start Nix container"
        generate_error_yaml "ftbfs" "Failed to start Nix container."
        exit 1
    fi
    log_success "Nix container started: ${CONTAINER_NAME}"

    log_info "Cloning Liana repository inside container..."
    ${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "git clone --depth=1 --branch v${version} https://github.com/wizardsardine/liana.git /liana"

    log_info "Verifying tag v${version}..."
    local sig_output
    sig_output=$(${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "cd /liana && git verify-tag v${version} 2>&1" || true)
    if echo "$sig_output" | grep -q "Good signature"; then
        TAG_SIG_STATUS="verified — $(echo "$sig_output" | grep 'Good signature' | head -1 | sed 's/^[[:space:]]*//')"
        log_success "GPG tag signature verified for v${version}"
    else
        TAG_SIG_STATUS="not verified"
        log_warn "GPG tag signature not verified for v${version} — continuing"
    fi

    BUILT_COMMIT_HASH=$(${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "cd /liana && git rev-parse HEAD")
    log_info "Commit hash: ${BUILT_COMMIT_HASH}"

    # v14.0+ nests the Nix Windows target under `liana`; v13.x is top-level. Gate per major version.
    local win_flake_target=".#x86_64-pc-windows-gnu"
    if [[ "${version%%.*}" -ge 14 ]]; then
        win_flake_target=".#liana.x86_64-pc-windows-gnu"
    fi

    log_info "Running Nix Windows build: nix build ${win_flake_target}"
    log_info "This downloads dependencies and cross-compiles — may take 30-90 minutes."
    local start_time
    start_time=$(date +%s)

    if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c \
        "cd /liana && nix build ${win_flake_target} --out-link ${container_built}"; then
        log_error "Nix Windows build failed"
        generate_error_yaml "ftbfs" "nix build ${win_flake_target} failed. See output above."
        exit 1
    fi
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    log_success "Nix build completed in ${duration}s"

    log_info "Locating liana-gui.exe in Nix build output..."
    # Use -L so find follows the out-link symlink into the Nix store.
    # Stage into a separate writable dir — never write into the store (immutable).
    if ! ${container_cmd} exec "$CONTAINER_NAME" bash -c "
        found=\$(find -L ${container_built} -name 'liana-gui.exe' -type f | head -1)
        if [[ -z \"\$found\" ]]; then
            echo 'ERROR: liana-gui.exe not found in Nix build output' >&2
            exit 1
        fi
        mkdir -p ${container_staging}
        cp \"\$found\" ${container_staging}/liana-gui.exe
    "; then
        log_error "liana-gui.exe not found in Nix build output"
        generate_error_yaml "ftbfs" "liana-gui.exe not found in nix build output."
        exit 1
    fi
    CONTAINER_NIX_EXE_PATH="${container_staging}"

    mkdir -p "${built_dir}"
    if ! ${container_cmd} cp "${CONTAINER_NAME}:${container_staging}/liana-gui.exe" "${built_dir}/liana-gui.exe"; then
        log_error "Failed to copy built exe from container to host"
        generate_error_yaml "ftbfs" "Failed to copy built liana-gui.exe from container."
        exit 1
    fi
    log_success "Built exe copied to host: ${built_dir}/liana-gui.exe"

    # Official binary
    ${container_cmd} exec "$CONTAINER_NAME" bash -c "mkdir -p ${container_official}"

    if [[ -n "$binary_file" ]]; then
        log_info "Using provided binary: ${binary_file}"
        if [[ ! -f "$binary_file" ]]; then
            log_error "--binary file not found: ${binary_file}"
            generate_error_yaml "ftbfs" "--binary file not found: ${binary_file}"
            exit 1
        fi
        ${container_cmd} cp "$binary_file" "${CONTAINER_NAME}:${container_official}/liana-gui.exe"
    else
        local base_url="https://github.com/wizardsardine/liana/releases/download/v${version}"
        local shasums_name="liana-${version}-shasums.txt"
        log_info "Downloading official ${exe_name} inside container..."
        ${container_cmd} exec "$CONTAINER_NAME" bash -c \
            "curl -fsSL -o ${container_official}/liana-gui.exe ${base_url}/${exe_name}"

        log_info "Downloading checksums inside container: ${shasums_name}"
        ${container_cmd} exec "$CONTAINER_NAME" bash -c \
            "curl -fsSL -o ${container_official}/${shasums_name} ${base_url}/${shasums_name}"

        log_info "Verifying official exe integrity inside container..."
        if ${container_cmd} exec "$CONTAINER_NAME" bash -c "
            expected=\$(grep '${exe_name}' '${container_official}/${shasums_name}' | cut -d' ' -f1)
            actual=\$(sha256sum '${container_official}/liana-gui.exe' | cut -d' ' -f1)
            [ \"\$expected\" = \"\$actual\" ]
        "; then
            log_success "Official exe integrity verified"
        else
            log_error "Official exe checksum mismatch — aborting"
            generate_error_yaml "ftbfs" "Official exe checksum verification failed."
            exit 1
        fi
    fi

    CONTAINER_OFFICIAL_EXE_PATH="$container_official"

    mkdir -p "${official_dir}"
    if ! ${container_cmd} cp "${CONTAINER_NAME}:${container_official}/liana-gui.exe" "${official_dir}/liana-gui.exe"; then
        log_error "Failed to copy official exe from container to host"
        generate_error_yaml "ftbfs" "Failed to copy official liana-gui.exe from container."
        exit 1
    fi
    log_success "Official exe copied to host: ${official_dir}/liana-gui.exe"

    _verify_exe_checksums "$version" "$built_dir" "$official_dir"
    final_cleanup "$keep_container"
}

# ==============================================================================
# Parameter Parsing
# ==============================================================================
execution_dir="$(pwd)"
version=""
arch="x86_64-linux-gnu"
build_type="tarball"
binary_file=""
keep_container="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            require_arg "$1" "${2:-}"
            version="$2"
            shift 2
            ;;
        --arch)
            require_arg "$1" "${2:-}"
            arch="$2"
            shift 2
            ;;
        --type)
            require_arg "$1" "${2:-}"
            build_type="$2"
            shift 2
            ;;
        --binary)
            require_arg "$1" "${2:-}"
            binary_file="$2"
            shift 2
            ;;
        --apk)
            log_warn "--apk is not applicable to desktop scripts; ignoring"
            # Consume the optional value if present and not another flag
            if [[ "${2:-}" != "" && "${2:-}" != --* ]]; then
                shift 2
            else
                shift
            fi
            ;;
        --keep-container)
            keep_container="true"
            shift
            ;;
        --help)
            usage
            TRAP_CLEANUP_COMPLETED=true
            exit 0
            ;;
        *)
            log_warn "Unknown parameter: $1 — ignoring"
            shift
            ;;
    esac
done

# ==============================================================================
# Validation
# ==============================================================================
if [[ -z "$version" ]]; then
    log_error "Missing required parameter: --version"
    generate_error_yaml "ftbfs" "Missing required parameter: --version"
    usage
    exit 2
fi

# Strip leading v if user passed it
version="${version#v}"

# Validate version: digits and dots only — prevents shell injection when
# version is interpolated into bash -c strings run inside --privileged containers
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    log_error "Invalid --version format: '${version}'. Expected digits and dots only (e.g. 13.1)."
    generate_error_yaml "ftbfs" "Invalid --version format: ${version}"
    exit 2
fi

# Only x86_64-linux-gnu is supported
if [[ "$arch" != "x86_64-linux-gnu" ]]; then
    log_error "Unsupported architecture: ${arch}. Only x86_64-linux-gnu is supported."
    generate_error_yaml "ftbfs" "Unsupported architecture: ${arch}"
    exit 2
fi

if [[ "$build_type" != "tarball" && "$build_type" != "deb" && "$build_type" != "exe" ]]; then
    log_error "Unsupported type: ${build_type}. Supported: tarball, deb, exe."
    generate_error_yaml "ftbfs" "Unsupported type: ${build_type}"
    exit 2
fi

# Fail fast if --binary extension conflicts with or implies a different --type.
# Silent auto-switching can hide mistakes in automation.
if [[ -n "$binary_file" ]]; then
    if [[ "$binary_file" == *.deb && "$build_type" == "tarball" ]]; then
        log_error "--binary '${binary_file}' looks like a deb but --type is tarball (default or explicit)."
        log_error "Add --type deb to confirm your intent."
        generate_error_yaml "ftbfs" "--binary/.deb extension conflicts with --type tarball."
        exit 2
    fi
    if [[ "$binary_file" == *.tar.gz && "$build_type" == "deb" ]]; then
        log_error "--binary '${binary_file}' looks like a tarball but --type is deb."
        log_error "Remove --type deb or provide a .deb file."
        generate_error_yaml "ftbfs" "--binary/.tar.gz extension conflicts with --type deb."
        exit 2
    fi
    if [[ "$binary_file" == *.exe && "$build_type" != "exe" ]]; then
        log_error "--binary '${binary_file}' looks like an exe but --type is ${build_type}."
        log_error "Add --type exe to confirm your intent."
        generate_error_yaml "ftbfs" "--binary/.exe extension conflicts with --type ${build_type}."
        exit 2
    fi
    if [[ "$binary_file" != *.exe && "$build_type" == "exe" ]]; then
        log_error "--binary '${binary_file}' is not an exe but --type is exe."
        log_error "Provide a liana-VERSION-noncodesigned.exe file."
        generate_error_yaml "ftbfs" "--binary extension conflicts with --type exe."
        exit 2
    fi
fi

# ==============================================================================
# Main
# ==============================================================================
check_dependencies
set_unique_names "$version" "$arch" "$build_type"

workspace="${execution_dir}/liana_${version}_${arch}_$$"
built_dir="${workspace}/built"
official_dir="${workspace}/official"
mkdir -p "$workspace"

# Exe pipeline: completely isolated — exits here, Guix code never runs
if [[ "$build_type" == "exe" ]]; then
    _run_nix_exe_pipeline "$version" "$binary_file" "$workspace" "$built_dir" "$official_dir"
    exit "$VERIFICATION_EXIT_CODE"
fi

log_info "=============================================="
log_info "${APP_NAME} v${version} Verification"
log_info "=============================================="
log_info "Script version:  ${SCRIPT_VERSION}"
log_info "Architecture:    ${arch}"
log_info "Type:            ${build_type}"
log_info "Container:       ${CONTAINER_NAME}"
log_info "Workspace:       ${workspace}"
log_info "=============================================="
log_info ""

temp_imagefile=$(mktemp /tmp/liana-imagefile-XXXXXX)
trap 'rm -f "$temp_imagefile"; cleanup_on_exit' EXIT

create_imagefile "$temp_imagefile"
build_container "$temp_imagefile"
start_container
prepare_liana_build "$version"
execute_guix_build "$version"
copy_built_binaries "$built_dir"

prepare_official_binaries "$version" "$binary_file" "$official_dir"

verify_checksums "$version" "$built_dir" "$OFFICIAL_EXTRACTED_DIR"
final_cleanup "$keep_container"

exit "$VERIFICATION_EXIT_CODE"
