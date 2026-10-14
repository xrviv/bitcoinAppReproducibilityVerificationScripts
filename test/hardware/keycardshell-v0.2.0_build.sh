#!/usr/bin/env bash
#
# keycardshell-v0.2.0_build.sh - reproducible-build check of Keycard Shell firmware
# Version: v0.2.0
# Organization: WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-14
# Project: https://github.com/keycard-tech/keycard-shell
# App ID: keycard-shell
#
# Verifies Keycard Shell firmware (shellos-YYYYMMDD-X.Y.Z.bin) AND bootloader
# (shellos-bootloader-YYYYMMDD-X.Y.Z.bin, published from v1.4.0) against the
# official GitHub release binaries. Hardware: STM32H573VITX, Cortex-M33.
# Build system: CMake + Ninja + ARM GNU Toolchain 15.2.rel1.
#
# Steps: take or download both official binaries, build the release tag inside a
# container, compare, write COMPARISON_RESULTS.yaml beside this script.
# Firmware: firmware-hash.py skips bytes 588-651 (64-byte ECDSA signature), so
# binaries signed with different keys hash identically; dd cross-check.
# Bootloader (unsigned): bytes 588-651 hold the firmware verification key. Our
# ELF is personalised with the official file's key bytes and must then equal
# the official bootloader byte for byte. Both must match for "reproducible".
#
# Upstream Python tools are inlined for transparency (same in v1.3.0 and v1.4.0, except
# two pathlib patches for Python 3.10, marked PATCH below):
#   tools/download-toolchain.sh  -> toolchain download below
#   tools/common.py, firmware-hash.py, firmware-sign.py, keycardsign.py,
#   bootloader-perso.py          -> ${WORK_DIR}/tools/ (COPY into container)
#
# Usage:
#   keycardshell-v0.2.0_build.sh --version 1.4.0
#   keycardshell-v0.2.0_build.sh --binary /path/to/shellos-YYYYMMDD-X.Y.Z.bin
#   keycardshell-v0.2.0_build.sh --binary /path/to/shellos-bootloader-YYYYMMDD-X.Y.Z.bin
#   (--binary may also be a directory; the binary not supplied is downloaded)
#
# Host requirements: Bash, curl, tar and Podman or Docker. Run as a normal user.
# Each run uses its own workspace in the caller's directory and hands ownership back.
#
# Disclaimer: provided as-is, without warranty. A reproducible result is not a
# security audit; it only shows the official binary matches the public source.

set -eEo pipefail

SCRIPT_VERSION="v0.2.0"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
SCRIPT_HASH="$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
echo "$(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION} sha256:${SCRIPT_HASH}"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
rm -f -- "${RESULTS_FILE}"

# Pinned build inputs (2026-10-14)
APT_SNAPSHOT="20261014T000000Z"
UV_VERSION="0.13.1"
PY_EXCLUDE_NEWER="2026-10-14T00:00:00Z"
TOOLCHAIN_SHA256="597893282ac8c6ab1a4073977f2362990184599643b4c5ee34870a8215783a16"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="arm"
TYPE="firmware"
BINARY=""
CONTAINER=""
WORK_DIR=""
IMAGE_TAG=""
IMAGE_ID=""
FINAL_WRITTEN=false

# ── logging ──────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# ── results ──────────────────────────────────────────────────────────────────

write_yaml() {
    local verdict="$1" notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        echo "notes: |"
        printf '%s\n' "${notes}" | sed 's/^/  /'
    } > "${RESULTS_FILE}"
    FINAL_WRITTEN=true
    log_info "Result: ${verdict}"
}

ftbfs()     { write_yaml "ftbfs"            "$1"; exit "${EXIT_FAIL}"; }
not_repro() { write_yaml "not_reproducible" "$1"; exit "${EXIT_FAIL}"; }
repro()     { write_yaml "reproducible"     "$1"; exit "${EXIT_OK}";  }
invalid()   { log_error "$1"; write_yaml "ftbfs" "$1"; exit "${EXIT_INVALID}"; }

handle_err() {
    trap - ERR
    log_error "Unexpected error at line $1"
    write_yaml "ftbfs" "Unexpected error at line $1" 2>/dev/null || true
    exit "${EXIT_FAIL}"
}
trap 'handle_err $LINENO' ERR
trap 'trap - ERR; log_error "Interrupted"; write_yaml "ftbfs" "Run interrupted before a verdict." 2>/dev/null || true; exit 130' INT TERM

# EXIT: remove this run's image, hand the workspace back to the caller, and
# record ftbfs if the run ended without a verdict.
cleanup() {
    local rc=$?
    trap - ERR
    set +e
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${CONTAINER}" ]]; then
        if [[ "${CONTAINER}" == podman ]]; then
            podman unshare chown -R 0:0 "${WORK_DIR}" >/dev/null 2>&1
        elif [[ -n "${IMAGE_ID}" ]]; then
            docker run --rm -v "${WORK_DIR}:/w" "${IMAGE_ID}" chown -R "$(id -u):$(id -g)" /w >/dev/null 2>&1
        fi
        chmod -R u+rwX "${WORK_DIR}" 2>/dev/null
        local foreign
        foreign="$(find "${WORK_DIR}" ! -user "$(id -u)" 2>/dev/null | wc -l)"
        [[ "${foreign}" == 0 ]] || log_warn "${foreign} workspace entries not owned by you: ${WORK_DIR}"
    fi
    [[ -n "${IMAGE_TAG}" && -n "${CONTAINER}" ]] && "${CONTAINER}" rmi -f "${IMAGE_TAG}" >/dev/null 2>&1
    if [[ "${FINAL_WRITTEN}" != true ]]; then
        write_yaml "ftbfs" "Run ended (exit ${rc}) before a verdict." 2>/dev/null
        [[ ${rc} -eq 0 ]] && rc=${EXIT_FAIL}
    fi
    exit "${rc}"
}
trap cleanup EXIT

[[ "$(id -u)" -ne 0 ]] || invalid "Run as a normal user, not root."

# ── arguments ────────────────────────────────────────────────────────────────

usage() {
    sed -n '/^# Usage:/,/^# Host requirements/p' "${SCRIPT_PATH}" | sed '$d; s/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)       VERSION="${2:-}"; shift 2 || shift ;;
        --arch)          ARCH="${2:-}";    shift 2 || shift ;;
        --type)          TYPE="${2:-}";    shift 2 || shift ;;
        --binary|--apk)  BINARY="${2:-}";  shift 2 || shift ;;
        --help|-h)       usage; FINAL_WRITTEN=true; rm -f -- "${RESULTS_FILE}"; exit "${EXIT_OK}" ;;
        *)               log_warn "Unknown parameter ignored: $1"; shift ;;
    esac
done

[[ -n "${VERSION}" || -n "${BINARY}" ]] || invalid "Provide --version <X.Y.Z> or --binary <path>."

# --binary: the main firmware (shellos-YYYYMMDD-X.Y.Z.bin), the bootloader
# (shellos-bootloader-YYYYMMDD-X.Y.Z.bin), or a directory holding one or both.
# Whatever is not supplied is downloaded from the release. appHash is the
# supplied file (the firmware when a directory holds both).
FW_BIN=""
BL_BIN=""
pick_one() {  # dir pattern label → PICKED
    local found
    mapfile -t found < <(find "$1" -maxdepth 1 -type f -name "$2" | sort)
    [[ ${#found[@]} -le 1 ]] || invalid "More than one $3 in $1."
    PICKED="${found[0]:-}"
}
if [[ -n "${BINARY}" ]]; then
    if [[ -d "${BINARY}" ]]; then
        pick_one "${BINARY}" 'shellos-[0-9]*.bin' firmware;           FW_BIN="${PICKED}"
        pick_one "${BINARY}" 'shellos-bootloader-*.bin' bootloader;   BL_BIN="${PICKED}"
        [[ -n "${FW_BIN}${BL_BIN}" ]] || invalid "No shellos-*.bin in ${BINARY}."
    elif [[ -f "${BINARY}" ]]; then
        case "$(basename "${BINARY}")" in
            *bootloader*) BL_BIN="${BINARY}" ;;
            *)            FW_BIN="${BINARY}" ;;
        esac
    else
        invalid "Binary not found: ${BINARY}"
    fi
    APP_BIN="${FW_BIN:-${BL_BIN}}"
    BIN_VERSION="$(basename "${APP_BIN}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -z "${VERSION}" ]]; then
        VERSION="${BIN_VERSION}"
        [[ -n "${VERSION}" ]] || invalid "Cannot derive version from binary name."
        log_info "Derived version from binary: ${VERSION}"
    elif [[ -n "${BIN_VERSION}" && "${BIN_VERSION}" != "${VERSION}" ]]; then
        invalid "--version ${VERSION} does not match binary name version ${BIN_VERSION}."
    fi
fi

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || invalid "Invalid version format: ${VERSION}"

# ── container runtime (must answer info; broken podman falls through) ───────

if command -v podman &>/dev/null && podman info >/dev/null 2>&1; then
    CONTAINER="podman"
elif command -v docker &>/dev/null && docker info >/dev/null 2>&1; then
    CONTAINER="docker"
else
    invalid "A working podman or docker is required."
fi
log_info "Container runtime: ${CONTAINER}"

# ── per-run workspace in the caller's directory ──────────────────────────────

RUN_ID="$(date +%s)-$$"
WORK_DIR="$(pwd -P)/keycardshell_verification_${VERSION}_${RUN_ID}"
mkdir -- "${WORK_DIR}" || invalid "Cannot create workspace ${WORK_DIR}"
mkdir -- "${WORK_DIR}/tools"
IMAGE_TAG="keycardshell-build-${VERSION}-${RUN_ID}"
log_info "Version:  ${VERSION}"
log_info "Work dir: ${WORK_DIR}"

# ── official binaries (firmware + bootloader) ─────────────────────────────────

mkdir -- "${WORK_DIR}/official"
BL_PUBLISHED=true
if [[ -z "${FW_BIN}" || -z "${BL_BIN}" ]]; then
    log_info "Fetching release info for v${VERSION} from GitHub..."
    AUTH=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    RELEASE_JSON="$(curl -sf "${AUTH[@]}" "https://api.github.com/repos/keycard-tech/keycard-shell/releases/tags/v${VERSION}")" \
        || ftbfs "Failed to fetch release info for v${VERSION}"
    asset_url() {
        printf '%s' "${RELEASE_JSON}" | grep -oE "\"browser_download_url\": *\"[^\"]*/$1\"" \
            | sed -E 's/.*"(https:[^"]+)"$/\1/' | head -1 || true
    }
    if [[ -z "${FW_BIN}" ]]; then
        URL="$(asset_url "shellos-[0-9]{8}-[^\"/]*\\.bin")"
        [[ -n "${URL}" ]] || ftbfs "No shellos-YYYYMMDD-${VERSION}.bin asset in release v${VERSION}"
        FW_BIN="${WORK_DIR}/official/$(basename "${URL}")"
        log_info "Downloading $(basename "${URL}")..."
        curl -sfL -o "${FW_BIN}" "${URL}" || ftbfs "Failed to download the official firmware"
    fi
    if [[ -z "${BL_BIN}" ]]; then
        URL="$(asset_url "shellos-bootloader-[0-9]{8}-[^\"/]*\\.bin")"
        if [[ -n "${URL}" ]]; then
            BL_BIN="${WORK_DIR}/official/$(basename "${URL}")"
            log_info "Downloading $(basename "${URL}")..."
            curl -sfL -o "${BL_BIN}" "${URL}" || ftbfs "Failed to download the official bootloader"
        else
            BL_PUBLISHED=false
            log_warn "Release v${VERSION} publishes no bootloader binary; firmware only."
        fi
    fi
fi
APP_BIN="${APP_BIN:-${FW_BIN}}"
log_info "Official firmware:   ${FW_BIN}"
${BL_PUBLISHED} && log_info "Official bootloader: ${BL_BIN}"

# ── inline upstream Python tools ─────────────────────────────────────────────
#
# These files are copied verbatim from upstream v1.3.0 (commit 961382b):
# https://github.com/keycard-tech/keycard-shell/tree/v1.3.0/tools/
#
# They are written to ${WORK_DIR}/tools/ and COPYed into the container
# (overwriting the repo's own copies) so the reviewer can audit exactly
# what code runs without inspecting the upstream repository separately.
# NOTE: firmware-sign.py and bootloader-perso.py are patched for Python 3.10
# compatibility: pathlib.Path.unlink(str) → pathlib.Path(str).unlink().
# All other logic is verbatim from upstream v1.3.0.

# tools/common.py — shared constants and helpers used by all Python tools
cat > "${WORK_DIR}/tools/common.py" <<'PYEOF'
import subprocess
import hashlib
import os
from secp256k1Crypto import PrivateKey

# Path to arm-none-eabi-objcopy, set via CMake environment variable
OBJCOPY = os.environ.get("OBJCOPY", "arm-none-eabi-objcopy")

PAGE_SIZE = 8192
WORD_SIZE = 16

BANK_PAGE_COUNT = 128
BANK_SIZE = BANK_PAGE_COUNT * PAGE_SIZE
FLASH_SIZE = BANK_SIZE * 2

FW_PAGE_COUNT = 76
BL_PAGE_COUNT = 4
FW_SIZE = PAGE_SIZE * FW_PAGE_COUNT
BL_SIZE = PAGE_SIZE * BL_PAGE_COUNT
FW_IV_SIZE = 588
SIG_SIZE = 64

FW1_OFFSET = BL_SIZE
FW2_OFFSET = BANK_SIZE + FW1_OFFSET

FS_OFFSET = FW1_OFFSET + FW_SIZE

def sign(sign_key, m):
    key = PrivateKey(bytes(bytearray.fromhex(sign_key)), raw=True)
    sig = key.ecdsa_sign(m, raw=True)
    return key.ecdsa_serialize_compact(sig)

def elf_to_bin(elf_path, out_path):
    subprocess.run([OBJCOPY, "-O", "binary", "--gap-fill=255", elf_path, out_path], check=True)

def replace_elf_section(elf_path, section_name, section_content):
    subprocess.run([OBJCOPY, "--update-section", f'.{section_name}={section_content}', elf_path, elf_path], check=True)

def hash_firmware(fw):
    h = hashlib.sha256()
    h.update(fw[:FW_IV_SIZE])
    h.update(fw[FW_IV_SIZE+SIG_SIZE:])
    return h.digest()

def hash_db(db):
    h = hashlib.sha256()
    h.update(db[:-64])
    return h.digest()
PYEOF

# tools/firmware-hash.py — computes the reproducibility hash
# Pads the binary to 622592 bytes (76 pages x 8192), hashes bytes 0-587
# then bytes 652-end, skipping the 64-byte ECDSA signature at bytes 588-651.
cat > "${WORK_DIR}/tools/firmware-hash.py" <<'PYEOF'
import argparse

from common import *

def main():
    parser = argparse.ArgumentParser(description='Output the SHA256 hash of the firmware')
    parser.add_argument('-b', '--binary', help="the firmware bin file")
    args = parser.parse_args()

    fw = bytearray(b'\xff') * FW_SIZE

    with open(args.binary, 'rb') as f:
        f.readinto(fw)
        hash = hash_firmware(fw)
        print(hash.hex())

if __name__ == "__main__":
    main()
PYEOF

# tools/firmware-sign.py — called by CMake post-build (CMakeLists.txt lines 333, 352)
# Signs shellos.elf with a throwaway test key and converts to shellos.bin.
# Production firmware uses an HSM key; the hash comparison skips the signature
# region so the key content does not affect the reproducibility verdict.
# PATCH (Python 3.10): line 29: pathlib.Path(tmp_bin).unlink() instead of
# pathlib.Path.unlink(tmp_bin) — tmp_bin is a str, not a Path object.
cat > "${WORK_DIR}/tools/firmware-sign.py" <<'PYEOF'
# This tool is for development only, not to be used for releases

import argparse
import tempfile
import pathlib

from common import *
from keycardsign import *

def main():
    parser = argparse.ArgumentParser(description='Sign the firmware and convert ELF to bin')
    parser.add_argument('-s', '--secret-key', help="the secret key file")
    parser.add_argument('-k', '--keycard', help="sign with Keycard", action='store_true')
    parser.add_argument('-e', '--elf', help="the firmware ELF file")
    parser.add_argument('-o', '--output', help="the output binary file")
    args = parser.parse_args()

    if not args.keycard:
        with open(args.secret_key) as f:
            sign_key = f.read()

    fw = bytearray(b'\xff') * FW_SIZE
    tmp_bin = tempfile.mktemp()
    elf_to_bin(args.elf, tmp_bin)

    with open(tmp_bin, 'rb') as f:
        fw_size = f.readinto(fw)

    pathlib.Path(tmp_bin).unlink()

    m = hash_firmware(fw)
    if args.keycard:
        signature = keycard_sign("m/43'/60'/1581'/35'/0", m)
    else:
        signature = sign(sign_key, m)

    with tempfile.NamedTemporaryFile('wb', delete=False) as f:
        f.write(signature)
        f.write(fw[FW_IV_SIZE+SIG_SIZE:FW_IV_SIZE+SIG_SIZE+4])
        f.close()
        replace_elf_section(args.elf, "header", f.name)
        pathlib.Path(f.name).unlink()

    elf_to_bin(args.elf, args.output)

    if (fw_size % 16) != 0:
        with open(args.output, 'ab') as f:
            f.seek(0, 2)
            f.write(bytearray(b'\xff') * (16 - (fw_size % 16)))

if __name__ == "__main__":
    main()
PYEOF

# tools/keycardsign.py — imported by firmware-sign.py for hardware Keycard signing.
# Our build uses --secret-key (throwaway key pair), so keycard_sign() is never called.
cat > "${WORK_DIR}/tools/keycardsign.py" <<'PYEOF'
def get_pin():
    try:
        import tkinter.simpledialog
    except ImportError:
        raise "Tkinter enabled version of Python required"
    return tkinter.simpledialog.askstring("Keycard PIN", "Enter PIN:", show='*')

def keycard_sign(path, digest):
    try:
        from keycard.keycard import KeyCard
    except ImportError:
        raise "Please install the Keycard module"

    with KeyCard() as card:
        card.select()
        pairing_index, pairing_key = card.pair("KeycardDefaultPairing")
        card.open_secure_channel(pairing_index, pairing_key)

        pin = get_pin()

        while not card.verify_pin(pin):
            pin = get_pin()

        try:
            sig = card.sign_with_path(digest, path)
            return sig.signature
        finally:
            card.unpair(pairing_index)
PYEOF

# tools/bootloader-perso.py — called by CMake post-build (CMakeLists.txt line 300)
# Personalises the bootloader ELF with the public key. The bootloader binary is
# built by cmake --build; the script re-runs it with the official key bytes
# to compare the bootloader byte for byte.
# PATCH (Python 3.10): line 23: pathlib.Path(f.name).unlink() instead of
# pathlib.Path.unlink(f.name) — f.name is a str, not a Path object.
cat > "${WORK_DIR}/tools/bootloader-perso.py" <<'PYEOF'
# This tool is for development only, not to be used for releases

import argparse
import tempfile
import pathlib

from common import *

def main():
    parser = argparse.ArgumentParser(description='Replace the bootloader public key and convert ELF to bin')
    parser.add_argument('-p', '--public-key', help="the public key file")
    parser.add_argument('-e', '--elf', help="the bootloader ELF file")
    parser.add_argument('-o', '--output', help="the output binary file")
    args = parser.parse_args()

    with open(args.public_key) as f:
        pub_key = bytearray.fromhex(f.read())

    with tempfile.NamedTemporaryFile('wb', delete=False) as f:
        f.write(pub_key)
        f.close()
        replace_elf_section(args.elf, "header", f.name)
        pathlib.Path(f.name).unlink()

    elf_to_bin(args.elf, args.output)

if __name__ == "__main__":
    main()
PYEOF

# ── Dockerfile ───────────────────────────────────────────────────────────────

cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
# ubuntu:22.04 pinned by digest (index digest, 2026-10-14)
FROM docker.io/library/ubuntu:22.04@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401

ARG VERSION
ARG APT_SNAPSHOT
ARG UV_VERSION
ARG PY_EXCLUDE_NEWER

ENV DEBIAN_FRONTEND=noninteractive

# ca-certificates comes first from the image's default archive (apt still checks
# the archive signature), then every source switches to the fixed Ubuntu snapshot.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && sed -i -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}/#" /etc/apt/sources.list \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake \
        ninja-build \
        libpcsclite-dev \
        gcc \
        swig \
        curl \
        wget \
        ca-certificates \
        python3 \
        python3-dev \
        python3-pip \
        xz-utils \
        git \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager used by keycard-shell's pyproject.toml)
RUN pip3 install --quiet "uv==${UV_VERSION}"

WORKDIR /build

# Clone keycard-shell at the requested version tag
RUN git clone --depth 1 --branch "v${VERSION}" \
        https://github.com/keycard-tech/keycard-shell.git /build/keycard-shell

WORKDIR /build/keycard-shell

# Install Python dependencies declared in pyproject.toml. Upstream ships no
# uv.lock, so resolution (here and in every later "uv run") is limited to
# packages published before a fixed date.
ENV UV_EXCLUDE_NEWER=${PY_EXCLUDE_NEWER}
RUN uv venv && uv sync

# Overwrite the repo's Python tools with our inlined copies (from build context)
COPY tools/ /build/keycard-shell/tools/

# Generate a throwaway signing key pair (same method as CI)
# The 64-byte ECDSA signature at bytes 588-651 is skipped by firmware-hash.py,
# so the key content does not affect the reproducibility verdict.
RUN mkdir -p /build/keycard-shell/deployment \
    && openssl rand -hex 32 > /build/keycard-shell/deployment/fw-test-key.txt \
    && openssl rand -hex 64 > /build/keycard-shell/deployment/bootloader-pubkey.txt
# Toolchain is mounted from host at runtime to avoid a ~500 MB image layer.
# cmake configure + build run via docker run -v, not during image build.
DOCKERFILE_EOF

# ── download ARM GNU Toolchain to host (avoids 500 MB container layer) ────────
# Logic inlined from tools/download-toolchain.sh (upstream v1.3.0):
#   TOOLCHAIN_VERSION=15.2.rel1
#   filename=arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi.tar.xz
#   url=https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/${filename}
#       (redirects to armkeil.blob.core.windows.net)

TOOLCHAIN_ARCHIVE="${WORK_DIR}/toolchain.tar.xz"
TOOLCHAIN_EXTRACTED="arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi"
TOOLCHAIN_HOST="${WORK_DIR}/toolchain/arm-gnu-toolchain-15.2.rel1"

log_info "Downloading ARM GNU Toolchain 15.2.rel1 (~148 MB)..."
curl -sfL -o "${TOOLCHAIN_ARCHIVE}" \
    "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi.tar.xz" \
    || ftbfs "Toolchain download failed"
# sha256 published by Arm next to the archive (.sha256asc)
echo "${TOOLCHAIN_SHA256}  ${TOOLCHAIN_ARCHIVE}" | sha256sum -c - \
    || ftbfs "Toolchain archive sha256 mismatch"
mkdir -p "${WORK_DIR}/toolchain"
tar -xf "${TOOLCHAIN_ARCHIVE}" -C "${WORK_DIR}/toolchain" \
    || ftbfs "Toolchain extraction failed"
mv "${WORK_DIR}/toolchain/${TOOLCHAIN_EXTRACTED}" "${TOOLCHAIN_HOST}" \
    || ftbfs "Toolchain move failed"
rm -f "${TOOLCHAIN_ARCHIVE}"

# ── build environment image (no toolchain layer) ─────────────────────────────

log_info "Building container image ${IMAGE_TAG}..."
"${CONTAINER}" build \
    --build-arg VERSION="${VERSION}" \
    --build-arg APT_SNAPSHOT="${APT_SNAPSHOT}" \
    --build-arg UV_VERSION="${UV_VERSION}" \
    --build-arg PY_EXCLUDE_NEWER="${PY_EXCLUDE_NEWER}" \
    -t "${IMAGE_TAG}" \
    -f "${WORK_DIR}/Dockerfile" \
    "${WORK_DIR}" 2>&1 | tee "${WORK_DIR}/build.log" \
    || ftbfs "Container build failed — see ${WORK_DIR}/build.log"

# Resolve to image ID so subsequent run calls never trigger a registry lookup
IMAGE_ID="$("${CONTAINER}" images -q "${IMAGE_TAG}" 2>/dev/null | head -1)"
[[ -z "${IMAGE_ID}" ]] && ftbfs "Image not found after build"
log_info "Image ID: ${IMAGE_ID}"

# ── cmake configure + build (toolchain mounted from host) ────────────────────

mkdir -p "${WORK_DIR}/build-output"
log_info "Running cmake configure + build (toolchain mounted, ~5 min)..."
"${CONTAINER}" run --rm \
    -v "${TOOLCHAIN_HOST}:/build/keycard-shell/toolchain/arm-gnu-toolchain-15.2.rel1:ro" \
    -v "${WORK_DIR}/build-output:/output:rw" \
    "${IMAGE_ID}" \
    sh -c "cd /build/keycard-shell && cmake --preset release && cmake --build --preset release && cp build/shellos.bin build/shellos-bootloader.bin build/shellos-bootloader.elf deployment/bootloader-pubkey.txt /output/" \
    2>&1 | tee -a "${WORK_DIR}/build.log" \
    || ftbfs "cmake build failed — see ${WORK_DIR}/build.log"



# ── gather metadata ───────────────────────────────────────────────────────────

log_info "Getting commit hash..."
COMMIT="$("${CONTAINER}" run --rm "${IMAGE_ID}" \
    sh -c "git -C /build/keycard-shell rev-parse HEAD")" || COMMIT="unknown"

APP_HASH="$(sha256sum "${APP_BIN}" | cut -d' ' -f1)"
RELEASE_DATE="$(basename "${APP_BIN}" | grep -oE '[0-9]{8}' | head -1 || true)"
FW_NAME="$(basename "${FW_BIN}")"
OUT="${WORK_DIR}/build-output"

# Two byte ranges of a file (before / after the 64 bytes at 588-651).
chunks() {
    "${CONTAINER}" run --rm -v "$1:/f.bin:ro" "${IMAGE_ID}" sh -c "
        dd if=/f.bin bs=1 count=588 2>/dev/null | sha256sum | cut -d' ' -f1
        dd if=/f.bin bs=1 skip=652  2>/dev/null | sha256sum | cut -d' ' -f1"
}
mark() { [[ "$1" == "$2" ]] && echo "1 (MATCHES)" || echo "0 (DOESN'T MATCH)"; }

# ── firmware, method 1: firmware-hash.py (Keycard's own tool) ────────────────

log_info "Firmware method 1: firmware-hash.py on built and official binaries..."
fw_hash() {
    "${CONTAINER}" run --rm -v "$1:/f.bin:ro" "${IMAGE_ID}" \
        sh -c "cd /build/keycard-shell && uv run python tools/firmware-hash.py -b /f.bin"
}
BUILT_HASH="$(fw_hash "${OUT}/shellos.bin")"   || ftbfs "firmware-hash.py failed on built firmware"
OFFICIAL_HASH="$(fw_hash "${FW_BIN}")"         || ftbfs "firmware-hash.py failed on official firmware"

# ── firmware, method 2: dd over the same byte ranges ─────────────────────────

log_info "Firmware method 2: dd chunks..."
DD_FW_BUILT="$(chunks "${OUT}/shellos.bin")" || ftbfs "dd failed on built firmware"
DD_FW_OFFICIAL="$(chunks "${FW_BIN}")"       || ftbfs "dd failed on official firmware"

FW_PASS=false
[[ "${BUILT_HASH}" == "${OFFICIAL_HASH}" && "${DD_FW_BUILT}" == "${DD_FW_OFFICIAL}" ]] && FW_PASS=true

# ── bootloader: rebuild with the official key bytes, compare whole files ─────
# The bootloader is unsigned; bytes 588-651 hold the 64-byte firmware
# verification key that bootloader-perso.py writes from deployment/
# bootloader-pubkey.txt. Our build used a random key, so we copy the official
# file's 64 bytes into a key file, personalise our own bootloader ELF with it,
# and require the result to equal the official file byte for byte.

BL_PASS=true
BL_LINES=()
if ${BL_PUBLISHED}; then
    BL_NAME="$(basename "${BL_BIN}")"
    OUR_KEY="$(tr -d ' \n' < "${OUT}/bootloader-pubkey.txt")"
    [[ "$(od -An -v -tx1 -j588 -N64 "${OUT}/shellos-bootloader.bin" | tr -d ' \n')" == "${OUR_KEY}" ]] \
        || ftbfs "Built bootloader key is not at bytes 588-651; layout changed."
    od -An -v -tx1 -j588 -N64 "${BL_BIN}" | tr -d ' \n' > "${OUT}/official-bootloader-key.txt"
    log_info "Bootloader: personalising our ELF with the official key bytes..."
    "${CONTAINER}" run --rm \
        -v "${TOOLCHAIN_HOST}:/build/keycard-shell/toolchain/arm-gnu-toolchain-15.2.rel1:ro" \
        -v "${OUT}:/output:rw" "${IMAGE_ID}" sh -c "
        cd /build/keycard-shell && cp /output/shellos-bootloader.elf /tmp/bl.elf &&
        OBJCOPY=/build/keycard-shell/toolchain/arm-gnu-toolchain-15.2.rel1/bin/arm-none-eabi-objcopy \
        uv run python tools/bootloader-perso.py -p /output/official-bootloader-key.txt \
            -e /tmp/bl.elf -o /output/shellos-bootloader-official-key.bin" \
        2>&1 | tee -a "${WORK_DIR}/build.log" || ftbfs "bootloader-perso.py failed"
    BL_OFFICIAL_SHA="$(sha256sum "${BL_BIN}" | cut -d' ' -f1)"
    BL_REBUILT_SHA="$(sha256sum "${OUT}/shellos-bootloader-official-key.bin" | cut -d' ' -f1)"
    DD_BL_BUILT="$(chunks "${OUT}/shellos-bootloader.bin")" || ftbfs "dd failed on built bootloader"
    DD_BL_OFFICIAL="$(chunks "${BL_BIN}")"                  || ftbfs "dd failed on official bootloader"
    [[ "${BL_REBUILT_SHA}" == "${BL_OFFICIAL_SHA}" && "${DD_BL_BUILT}" == "${DD_BL_OFFICIAL}" ]] || BL_PASS=false
    BL_LINES=(
        "${BL_NAME} - whole file, our build + official key bytes 588-651 - ${BL_REBUILT_SHA} - $(mark "${BL_REBUILT_SHA}" "${BL_OFFICIAL_SHA}")"
        "${BL_NAME} - our build, dd bytes 0-587 - $(head -1 <<< "${DD_BL_BUILT}") - $(mark "$(head -1 <<< "${DD_BL_BUILT}")" "$(head -1 <<< "${DD_BL_OFFICIAL}")")"
        "${BL_NAME} - our build, dd bytes 652-end - $(tail -1 <<< "${DD_BL_BUILT}") - $(mark "$(tail -1 <<< "${DD_BL_BUILT}")" "$(tail -1 <<< "${DD_BL_OFFICIAL}")")"
    )
fi

# ── results block ─────────────────────────────────────────────────────────────

if ${FW_PASS} && ${BL_PASS}; then VERDICT="reproducible"; else VERDICT="not_reproducible"; fi

FW_LINES=(
    "${FW_NAME} - firmware-hash.py (skips signature bytes 588-651) - ${BUILT_HASH} - $(mark "${BUILT_HASH}" "${OFFICIAL_HASH}")"
    "${FW_NAME} - dd bytes 0-587 (before signature) - $(head -1 <<< "${DD_FW_BUILT}") - $(mark "$(head -1 <<< "${DD_FW_BUILT}")" "$(head -1 <<< "${DD_FW_OFFICIAL}")")"
    "${FW_NAME} - dd bytes 652-end (after signature) - $(tail -1 <<< "${DD_FW_BUILT}") - $(mark "$(tail -1 <<< "${DD_FW_BUILT}")" "$(tail -1 <<< "${DD_FW_OFFICIAL}")")"
)
ALL_LINES=("${FW_LINES[@]}" "${BL_LINES[@]}")
MATCHES=0
for line in "${ALL_LINES[@]}"; do [[ "${line}" == *"1 (MATCHES)" ]] && MATCHES=$((MATCHES + 1)); done

echo "===== Begin Results ====="
echo "appId:          keycard-shell"
echo "signer:         N/A"
echo "apkVersionName: ${VERSION}"
echo "apkVersionCode: ${RELEASE_DATE}"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${APP_HASH}"
echo "commit:         ${COMMIT}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_HASH}"
echo ""
echo "Diff:"
printf '%s\n' "${ALL_LINES[@]}"
${BL_PUBLISHED} || echo "Bootloader: not published for v${VERSION}; firmware only."
echo ""
echo "SUMMARY"
echo "total: ${#ALL_LINES[@]}"
echo "matches: ${MATCHES}"
echo "mismatches: $(( ${#ALL_LINES[@]} - MATCHES ))"
echo ""
echo "Tag: v${VERSION} (commit ${COMMIT}); tag signature not checked (verify with: git verify-tag v${VERSION})"
echo "===== End Results ====="
echo "Official firmware sha256:   $(sha256sum "${FW_BIN}" | cut -d' ' -f1)"
${BL_PUBLISHED} && echo "Official bootloader sha256: ${BL_OFFICIAL_SHA}"
${BL_PUBLISHED} && echo "Official bootloader key bytes 588-651: $(cat "${OUT}/official-bootloader-key.txt")"
echo "Evidence: ${WORK_DIR}"

# ── COMPARISON_RESULTS.yaml ───────────────────────────────────────────────────

NOTES="Firmware: Keycard's firmware-hash.py over bytes 0-587 and 652-end of the padded
622592-byte image; bytes 588-651 (64-byte ECDSA signature) excluded, because the release
is signed with the production key and our build with a throwaway key. Cross-checked with dd.
Bootloader: unsigned. Bytes 588-651 hold the firmware verification key; our build is
personalised with the official file's 64 key bytes and must then equal the official
bootloader byte for byte (also dd-checked outside those bytes).
firmware-sign.py and bootloader-perso.py carry a Python 3.10 pathlib patch; other tool
logic is verbatim upstream."
${BL_PUBLISHED} || NOTES="${NOTES}
Release v${VERSION} publishes no bootloader binary; only the firmware was compared."

if [[ "${VERDICT}" == reproducible ]]; then
    repro "${NOTES}"
else
    not_repro "Firmware match: ${FW_PASS}; bootloader match: ${BL_PASS}.
${NOTES}"
fi
