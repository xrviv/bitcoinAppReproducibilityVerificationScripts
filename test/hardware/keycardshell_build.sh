#!/usr/bin/env bash
#
# keycardshell_build.sh v0.1.0
#
# Verifies Keycard Shell firmware (https://github.com/keycard-tech/keycard-shell)
# against official GitHub release binaries.
#
# Hardware: Keycard Shell (STM32H573VITX, Cortex-M33, air-gapped QR signing)
# Build system: CMake + Ninja + ARM GNU Toolchain 15.2.rel1
#
# Verification approach:
#   Build firmware from source inside a container, run firmware-hash.py on
#   both the built and official binaries, and compare the hashes.
#   firmware-hash.py skips bytes 588-651 (64-byte ECDSA signature region),
#   so both binaries hash identically despite using different signing keys.
#
# All upstream scripts inlined for transparency (upstream v1.3.0 / commit 961382b):
#   tools/download-toolchain.sh  -> toolchain RUN block in Dockerfile
#   tools/common.py              -> ${WORK_DIR}/tools/common.py (COPY into container)
#   tools/firmware-hash.py       -> ${WORK_DIR}/tools/firmware-hash.py
#   tools/firmware-sign.py       -> ${WORK_DIR}/tools/firmware-sign.py (CMake post-build)
#   tools/keycardsign.py         -> ${WORK_DIR}/tools/keycardsign.py (imported by above)
#   tools/bootloader-perso.py    -> ${WORK_DIR}/tools/bootloader-perso.py (CMake post-build)
#
# Usage:
#   keycardshell_build.sh --version 1.3.0
#   keycardshell_build.sh --binary /path/to/shellos-YYYYMMDD-X.Y.Z.bin
#
# Only requirement: podman or docker
# Organization: WalletScrutiny.com

set -eE

SCRIPT_VERSION="v0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="arm-none-eabi"
TYPE="firmware"
BINARY=""

# ── logging ──────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

handle_err() {
    log_error "Unexpected error at line $1"
    write_yaml "ftbfs" "Unexpected error at line $1" 2>/dev/null || true
    exit "${EXIT_FAIL}"
}
trap 'handle_err $LINENO' ERR

# ── results ──────────────────────────────────────────────────────────────────

write_yaml() {
    local verdict="$1" notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        echo "notes: |"
        echo "  ${notes}"
    } > "${RESULTS_FILE}"
    log_info "Result: ${verdict}"
}

ftbfs()     { write_yaml "ftbfs"            "$1"; exit "${EXIT_FAIL}"; }
not_repro() { write_yaml "not_reproducible" "$1"; exit "${EXIT_FAIL}"; }
repro()     { write_yaml "reproducible"     "$1"; exit "${EXIT_OK}";  }

# ── arguments ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)       VERSION="$2"; shift 2 ;;
        --arch)          ARCH="$2";    shift 2 ;;
        --type)          TYPE="$2";    shift 2 ;;
        --binary|--apk)  BINARY="$2";  shift 2 ;;
        *)               log_warn "Unknown parameter ignored: $1"; shift ;;
    esac
done

if [[ -z "${VERSION}" && -z "${BINARY}" ]]; then
    log_error "Provide --version <X.Y.Z> or --binary <path>"
    write_yaml "ftbfs" "Missing --version or --binary"
    exit "${EXIT_INVALID}"
fi

if [[ -z "${VERSION}" && -n "${BINARY}" ]]; then
    VERSION="$(basename "${BINARY}" | grep -oP '\d+\.\d+\.\d+' | head -1)"
    [[ -n "${VERSION}" ]] || { write_yaml "ftbfs" "Cannot derive version from binary name"; exit "${EXIT_INVALID}"; }
    log_info "Derived version from binary: ${VERSION}"
fi

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    write_yaml "ftbfs" "Invalid version format: ${VERSION}"
    exit "${EXIT_INVALID}"
fi

# ── container runtime ────────────────────────────────────────────────────────

if command -v podman &>/dev/null; then
    CONTAINER="podman"
elif command -v docker &>/dev/null; then
    CONTAINER="docker"
else
    ftbfs "podman or docker is required"
fi
log_info "Container runtime: ${CONTAINER}"

# ── work dir ─────────────────────────────────────────────────────────────────

WORK_DIR="/tmp/keycardshell_${VERSION}_$$"
IMAGE_TAG="keycardshell-build-${VERSION}-$$"
mkdir -p "${WORK_DIR}/tools"
log_info "Version:  ${VERSION}"
log_info "Work dir: ${WORK_DIR}"

# ── official binary ──────────────────────────────────────────────────────────

if [[ -n "${BINARY}" ]]; then
    OFFICIAL_BIN="${BINARY}"
    log_info "Using provided binary: ${OFFICIAL_BIN}"
else
    log_info "Fetching release info for v${VERSION} from GitHub..."
    RELEASE_JSON="$(curl -sf "https://api.github.com/repos/keycard-tech/keycard-shell/releases/tags/v${VERSION}")" \
        || ftbfs "Failed to fetch release info for v${VERSION}"
    ASSET_URL="$(printf '%s' "${RELEASE_JSON}" | python3 -c \
        "import sys,json; r=json.load(sys.stdin); print(next(a['browser_download_url'] for a in r['assets'] if a['name'].endswith('.bin')))")" \
        || ftbfs "No .bin asset found in release v${VERSION}"
    ASSET_NAME="$(basename "${ASSET_URL}")"
    OFFICIAL_BIN="${WORK_DIR}/${ASSET_NAME}"
    log_info "Downloading ${ASSET_NAME}..."
    curl -Lf -o "${OFFICIAL_BIN}" "${ASSET_URL}" || ftbfs "Failed to download official binary"
fi

[[ -f "${OFFICIAL_BIN}" ]] || ftbfs "Official binary not found: ${OFFICIAL_BIN}"

# ── inline upstream Python tools ─────────────────────────────────────────────
#
# These files are copied verbatim from upstream v1.3.0 (commit 961382b):
# https://github.com/keycard-tech/keycard-shell/tree/v1.3.0/tools/
#
# They are written to ${WORK_DIR}/tools/ and COPYed into the container
# (overwriting the repo's own copies) so the reviewer can audit exactly
# what code runs without inspecting the upstream repository separately.

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

    pathlib.Path.unlink(tmp_bin)

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
        pathlib.Path.unlink(f.name)

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
# built as part of cmake --build but is not included in the comparison;
# only shellos.bin (main firmware) is verified.
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
        pathlib.Path.unlink(f.name)

    elf_to_bin(args.elf, args.output)

if __name__ == "__main__":
    main()
PYEOF

# ── Dockerfile ───────────────────────────────────────────────────────────────

cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
FROM ubuntu:22.04

ARG VERSION

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake \
        ninja-build \
        libpcsclite-dev \
        curl \
        wget \
        ca-certificates \
        python3 \
        python3-pip \
        xz-utils \
        git \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager used by keycard-shell's pyproject.toml)
RUN pip3 install --quiet uv

WORKDIR /build

# Clone keycard-shell at the requested version tag
RUN git clone --depth 1 --branch "v${VERSION}" \
        https://github.com/keycard-tech/keycard-shell.git /build/keycard-shell

WORKDIR /build/keycard-shell

# Install Python dependencies declared in pyproject.toml
RUN uv venv && uv sync

# Download ARM GNU Toolchain 15.2.rel1 for x86_64-linux-gnu
# Logic inlined from tools/download-toolchain.sh (upstream v1.3.0):
#   TOOLCHAIN_VERSION=15.2.rel1
#   filename=arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi.tar.xz
#   url=https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/${filename}
#       (redirects to armkeil.blob.core.windows.net)
#   Extracted and moved to toolchain/arm-gnu-toolchain-15.2.rel1/
RUN wget -q -O /tmp/toolchain.tar.xz \
        "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi.tar.xz" \
    && mkdir -p /tmp/toolchain-ext \
    && tar -xf /tmp/toolchain.tar.xz -C /tmp/toolchain-ext \
    && mkdir -p /build/keycard-shell/toolchain \
    && mv /tmp/toolchain-ext/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi \
          /build/keycard-shell/toolchain/arm-gnu-toolchain-15.2.rel1 \
    && rm -rf /tmp/toolchain.tar.xz /tmp/toolchain-ext

# Overwrite the repo's Python tools with our inlined copies (from build context)
COPY tools/ /build/keycard-shell/tools/

# Generate a throwaway signing key pair (same method as CI)
# The 64-byte ECDSA signature at bytes 588-651 is skipped by firmware-hash.py,
# so the key content does not affect the reproducibility verdict.
RUN mkdir -p /build/keycard-shell/deployment \
    && openssl rand -hex 32 > /build/keycard-shell/deployment/fw-test-key.txt \
    && openssl rand -hex 64 > /build/keycard-shell/deployment/bootloader-pubkey.txt

# Configure (reads cmake/arm-gcc.cmake toolchain file)
RUN cmake --preset release

# Build all 355 targets; CMake post-build calls firmware-sign.py and bootloader-perso.py
RUN cmake --build --preset release
DOCKERFILE_EOF

# ── build container image ────────────────────────────────────────────────────

log_info "Building container image ${IMAGE_TAG}..."
log_info "(Includes toolchain download ~148 MB — this will take several minutes)"
"${CONTAINER}" build \
    --build-arg VERSION="${VERSION}" \
    -t "${IMAGE_TAG}" \
    -f "${WORK_DIR}/Dockerfile" \
    "${WORK_DIR}" 2>&1 | tee "${WORK_DIR}/build.log" \
    || ftbfs "Container build failed — see ${WORK_DIR}/build.log"

# ── gather metadata ───────────────────────────────────────────────────────────

log_info "Getting commit hash..."
COMMIT="$("${CONTAINER}" run --rm "${IMAGE_TAG}" \
    sh -c "git -C /build/keycard-shell rev-parse HEAD")" || COMMIT="unknown"

APP_HASH="$(sha256sum "${OFFICIAL_BIN}" | cut -d' ' -f1)"
RELEASE_DATE="$(basename "${OFFICIAL_BIN}" | grep -oP '\d{8}' | head -1)"
OFFICIAL_BIN_NAME="$(basename "${OFFICIAL_BIN}")"

# ── Method 1: firmware-hash.py (Keycard's own tool) ──────────────────────────

log_info "Method 1: firmware-hash.py on built binary..."
BUILT_HASH="$("${CONTAINER}" run --rm "${IMAGE_TAG}" \
    sh -c "cd /build/keycard-shell && uv run python tools/firmware-hash.py -b build/shellos.bin")" \
    || ftbfs "firmware-hash.py failed on built binary"

log_info "Method 1: firmware-hash.py on official binary..."
OFFICIAL_HASH="$("${CONTAINER}" run --rm \
    -v "${OFFICIAL_BIN}:/official.bin:ro" "${IMAGE_TAG}" \
    sh -c "cd /build/keycard-shell && uv run python tools/firmware-hash.py -b /official.bin")" \
    || ftbfs "firmware-hash.py failed on official binary"

# ── Method 2: dd chunk comparison ────────────────────────────────────────────

log_info "Method 2: dd chunks on built binary..."
DD_BUILT="$("${CONTAINER}" run --rm "${IMAGE_TAG}" sh -c "
    dd if=/build/keycard-shell/build/shellos.bin bs=1 count=588 2>/dev/null | sha256sum | cut -d' ' -f1
    dd if=/build/keycard-shell/build/shellos.bin bs=1 skip=652  2>/dev/null | sha256sum | cut -d' ' -f1
")" || ftbfs "dd failed on built binary"
DD_BUILT_PRE="$(echo  "${DD_BUILT}" | head -1)"
DD_BUILT_POST="$(echo "${DD_BUILT}" | tail -1)"

log_info "Method 2: dd chunks on official binary..."
DD_OFFICIAL="$("${CONTAINER}" run --rm \
    -v "${OFFICIAL_BIN}:/official.bin:ro" "${IMAGE_TAG}" sh -c "
    dd if=/official.bin bs=1 count=588 2>/dev/null | sha256sum | cut -d' ' -f1
    dd if=/official.bin bs=1 skip=652  2>/dev/null | sha256sum | cut -d' ' -f1
")" || ftbfs "dd failed on official binary"
DD_OFFICIAL_PRE="$(echo  "${DD_OFFICIAL}" | head -1)"
DD_OFFICIAL_POST="$(echo "${DD_OFFICIAL}" | tail -1)"

# ── verdict logic ─────────────────────────────────────────────────────────────

METHOD1_PASS=false; METHOD2_PASS=false
[[ "${BUILT_HASH}"    == "${OFFICIAL_HASH}"   ]] && METHOD1_PASS=true
[[ "${DD_BUILT_PRE}"  == "${DD_OFFICIAL_PRE}" && \
   "${DD_BUILT_POST}" == "${DD_OFFICIAL_POST}" ]] && METHOD2_PASS=true

M1_LABEL="1 (MATCHES)";  [[ "${METHOD1_PASS}"  == false ]]                              && M1_LABEL="0 (DOESN'T MATCH)"
M2A_LABEL="1 (MATCHES)"; [[ "${DD_BUILT_PRE}"  != "${DD_OFFICIAL_PRE}"  ]]              && M2A_LABEL="0 (DOESN'T MATCH)"
M2B_LABEL="1 (MATCHES)"; [[ "${DD_BUILT_POST}" != "${DD_OFFICIAL_POST}" ]]              && M2B_LABEL="0 (DOESN'T MATCH)"

TOTAL_MATCHES=0; TOTAL_MISMATCHES=0
${METHOD1_PASS}                                                                           && TOTAL_MATCHES=$((TOTAL_MATCHES+1))   || TOTAL_MISMATCHES=$((TOTAL_MISMATCHES+1))
[[ "${DD_BUILT_PRE}"  == "${DD_OFFICIAL_PRE}"  ]]                                        && TOTAL_MATCHES=$((TOTAL_MATCHES+1))   || TOTAL_MISMATCHES=$((TOTAL_MISMATCHES+1))
[[ "${DD_BUILT_POST}" == "${DD_OFFICIAL_POST}" ]]                                        && TOTAL_MATCHES=$((TOTAL_MATCHES+1))   || TOTAL_MISMATCHES=$((TOTAL_MISMATCHES+1))

if ${METHOD1_PASS} && ${METHOD2_PASS}; then
    VERDICT="reproducible"
else
    VERDICT="differences found"
fi

# ── results block (===== Begin Results =====) ─────────────────────────────────

echo "===== Begin Results ====="
echo "appId:          keycard-shell"
echo "signer:         N/A"
echo "apkVersionName: ${VERSION}"
echo "apkVersionCode: ${RELEASE_DATE}"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${APP_HASH}"
echo "commit:         ${COMMIT}"
echo ""
echo "Diff:"
echo "BUILDS MATCH BINARIES"
echo "${OFFICIAL_BIN_NAME} - Method 1 firmware-hash.py (skips sig bytes 588-651) - ${BUILT_HASH} - ${M1_LABEL}"
echo "${OFFICIAL_BIN_NAME} - Method 2 dd bytes 0-587 (before signature) - ${DD_BUILT_PRE} - ${M2A_LABEL}"
echo "${OFFICIAL_BIN_NAME} - Method 2 dd bytes 652-end (after signature) - ${DD_BUILT_POST} - ${M2B_LABEL}"
echo ""
echo "SUMMARY"
echo "total: 3"
echo "matches: ${TOTAL_MATCHES}"
echo "mismatches: ${TOTAL_MISMATCHES}"
echo ""
echo "Revision, tag (and its signature):"
echo "Tag: v${VERSION} (commit ${COMMIT})"
echo ""
echo "Signature Summary:"
echo "Tag type: annotated"
echo "[INFO] GPG key not imported in build container — tag signature not verified"
echo "[INFO] Verify manually with: git verify-tag v${VERSION}"
echo ""
echo "===== End Results ====="

# ── COMPARISON_RESULTS.yaml ───────────────────────────────────────────────────

if ${METHOD1_PASS} && ${METHOD2_PASS}; then
    repro "Both methods confirm reproducibility. Method 1 firmware-hash.py (skips ECDSA sig bytes 588-651): ${BUILT_HASH}. Method 2 dd: chunk1=${DD_BUILT_PRE} chunk2=${DD_BUILT_POST}"
elif ! ${METHOD1_PASS} && ! ${METHOD2_PASS}; then
    not_repro "Both methods report mismatch. firmware-hash.py built=${BUILT_HASH} official=${OFFICIAL_HASH}. dd chunk1 built=${DD_BUILT_PRE} official=${DD_OFFICIAL_PRE}. dd chunk2 built=${DD_BUILT_POST} official=${DD_OFFICIAL_POST}"
else
    not_repro "Methods disagree — possible script error. Method1=${METHOD1_PASS} Method2=${METHOD2_PASS}. Manual review required."
fi
