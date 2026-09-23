#!/usr/bin/env bash
# ==============================================================================
# adamant_build.sh - ADAMANT Messenger Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.1
# Organization:  WalletScrutiny.com
# Project:       https://github.com/Adamant-im/adamant-im
# Last modified by: Danny Garcia, Bob
# Last modified on: 2026-09-23
# ==============================================================================
# LICENSE: GPL-3.0-only (upstream project license)
#
# IMPORTANT: DO NOT include a changelog in this header.
# Changelog is maintained separately: ~/work/ws-notes/script-notes/desktop/adamant/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and binary comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Scope: Linux AppImage only (ADAMANT-Messenger-{version}.AppImage). macOS DMGs,
#   Windows EXE, and the separate Android APK listing (im.adamant.adamantmessengerpwa)
#   are out of scope for this script version.
# - Clones Adamant-im/adamant-im at tag v{version} (or --commit), in a Node image
#   pinned by digest; npm pinned from package.json "packageManager" via corepack.
#   Runs `npm ci` + `npm run schema:generate` + `npm run electron:build`, as
#   upstream .github/workflows/electron-linux.yml does.
# - Downloads (or accepts via --binary) the official release AppImage. Nothing from
#   the official file is ever executed: the launcher/SquashFS boundary is read from
#   the ELF header and both images are unpacked with unsquashfs from that offset.
# - Verdict gates on three things: the launcher (ELF runtime, bytes before the
#   SquashFS) byte for byte, the unpacked file tree (content), and the unpacked
#   tree metadata (modes/types/symlink targets).
# - Generates COMPARISON_RESULTS.yaml (script_version, verdict, notes only), on
#   every exit path including invalid parameters.
#
# KNOWN RESULT FOR 4.12.0 (2026-09-22, Bob): the release asset equals upstream CI's
# artifact for dev commit 9cf71bc2 (3 days after the tag), not tag v4.12.0. Building
# the tag differs only in resources/app.asar; `--commit 9cf71bc2` rebuilds the release.
#
# OPEN RISKS (see ~/work/ws-notes/build-notes/desktop/adamant.im/):
# - The CI job that produced the published release asset is not linked from the
#   release; no official SHA256SUMS manifest exists to cross-check the download.
# - Git tag/commit signatures are not verified (tag object type is reported).
# ==============================================================================
#
# Usage:
#   adamant_build.sh --version VERSION [--arch x86_64-linux-gnu] [--type appimage] [--commit REF]
#   adamant_build.sh --binary FILE_OR_DIR [--version VERSION]
#
# Only host requirement: podman or docker. No credentials needed (GITHUB_TOKEN
# optional, used for the release download if provided by ABS).
# ==============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="v0.2.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256="$(sha256sum "${SCRIPT_PATH}" 2>/dev/null | awk '{print $1}' || true)"
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "[INFO] Script:  $(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION}"
echo "[INFO]          sha256: ${SCRIPT_SHA256}"

APP_ID="adamant.im"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

ADAMANT_REPO="https://github.com/Adamant-im/adamant-im"
SUPPORTED_ARCH="x86_64-linux-gnu"
SUPPORTED_TYPE="appimage"
# Upstream CI (ubuntu-latest + actions/setup-node from .nvmrc, major 24 at 4.12.0) used
# Node 24.19.0 for the build whose artifact became the 4.12.0 release asset (Bob,
# 2026-09-22). Pulled by digest so a moved tag cannot change the toolchain silently.
NODE_IMAGE_TAG="docker.io/library/node:24.19.0-bookworm"
NODE_IMAGE="docker.io/library/node@sha256:107ceb6ad85808049dccef12414bf17b08eceb299eaf755c0339dc5fc8958d6b"

APP_VERSION=""
APP_ARCH="${SUPPORTED_ARCH}"
APP_TYPE="${SUPPORTED_TYPE}"
BINARY_PATH=""
COMMIT_ARG=""
NO_CACHE=false
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
    case "${verdict}" in reproducible|not_reproducible|ftbfs) ;; *) verdict="ftbfs" ;; esac
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        if [[ -n "${notes}" ]]; then
            echo "notes: |"
            printf '%s\n' "${notes}" | sed 's/^/  /'
        fi
    } > "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    log_info "COMPARISON_RESULTS.yaml written to ${SCRIPT_DIR} (verdict: ${verdict})"
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
    # Remove run-specific tag only; layer cache (npm/node base layers) is kept.
    if [[ -n "${IMAGE_TAG}" ]] && [[ -n "${DOCKER_CMD}" ]]; then
        "${DOCKER_CMD}" rmi "${IMAGE_TAG}" >/dev/null 2>&1 || true
    fi
}

die_invalid() {
    # Invalid parameters / unusable host: exit 2, but still leave a YAML behind,
    # because the build server expects COMPARISON_RESULTS.yaml on every run.
    trap - ERR
    log_fail "$1"
    write_yaml "ftbfs" "No build was attempted: $1"
    exit "${EXIT_INVALID_PARAMS}"
}

die_failed() {
    trap - ERR
    log_fail "$1"
    write_yaml "ftbfs" "$1 Work dir: ${WORK_DIR:-unset}"
    cleanup_image
    exit "${EXIT_BUILD_FAILED}"
}

require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "${value}" || "${value}" == --* ]]; then
        die_invalid "Missing value for parameter: ${flag}"
    fi
}

# Reads KEY=VALUE lines written by the container into variables, accepting only
# the listed keys. Never `source` container output: the build runs upstream code.
load_env_file() {
    local file="$1"; shift
    local key value allowed
    while IFS='=' read -r key value; do
        for allowed in "$@"; do
            if [[ "${key}" == "${allowed}" ]]; then
                printf -v "${key}" '%s' "${value}"
            fi
        done
    done < "${file}"
}

detect_container_cmd() {
    if [[ -z "${DOCKER_CMD}" ]]; then
        if command -v podman >/dev/null 2>&1; then
            DOCKER_CMD="podman"
        elif command -v docker >/dev/null 2>&1; then
            DOCKER_CMD="docker"
        else
            die_invalid "Neither podman nor docker found in PATH (only host requirement)"
        fi
    fi
    log_info "Container engine: ${DOCKER_CMD} ($("${DOCKER_CMD}" --version 2>&1 | head -1))"
}

usage() {
    cat <<USAGE
adamant_build.sh ${SCRIPT_VERSION} - ADAMANT Messenger Desktop reproducible build verifier

Usage:
  $0 --version VERSION [--arch x86_64-linux-gnu] [--type appimage] [--commit REF]
  $0 --binary FILE_OR_DIR [--version VERSION]

Parameters:
  --version VERSION   App version without 'v' prefix (e.g. 4.12.0).
                      Source ref used: vVERSION tag (unless --commit).
  --binary FILE|DIR   Official Linux AppImage to verify, or a directory holding
                      one ADAMANT-Messenger-*.AppImage. Skips the GitHub download.
                      If --version is omitted it is read from the file name.
  --commit REF        Build this commit/ref instead of tag vVERSION. Use it when
                      the release asset was built from a later commit.
  --arch ARCH         Target architecture. Only ${SUPPORTED_ARCH} is supported.
  --type TYPE         Artifact type. Only ${SUPPORTED_TYPE} is supported.
  --apk FILE          Android-only parameter; accepted as alias for --binary.
  --no-cache          Build the container image without cache.
  --help              This help.

Exit codes: 0 = reproducible, 1 = not reproducible / build failure, 2 = invalid parameters.
Build time: roughly 5-15 minutes (npm ci + vite build + electron-builder).
USAGE
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        usage
        die_invalid "No parameters given"
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) require_value "$1" "${2:-}"; APP_VERSION="${2#v}"; shift 2 ;;
            --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --apk)
                log_warn "--apk is an Android parameter; treating it as --binary"
                require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --commit)  require_value "$1" "${2:-}"; COMMIT_ARG="$2"; shift 2 ;;
            --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --no-cache) NO_CACHE=true; shift ;;
            --help|-h) usage; exit "${EXIT_SUCCESS}" ;;
            *)
                log_warn "Unknown argument: $1 (ignored)"
                shift ;;
        esac
    done

    case "${APP_ARCH}" in
        x86_64-linux-gnu|x86_64-linux|x86_64) APP_ARCH="${SUPPORTED_ARCH}" ;;
        *) die_invalid "Unsupported --arch '${APP_ARCH}' (only ${SUPPORTED_ARCH} in this script version)" ;;
    esac
    case "${APP_TYPE}" in
        appimage|AppImage|"") APP_TYPE="${SUPPORTED_TYPE}" ;;
        *) die_invalid "Unsupported --type '${APP_TYPE}' (only ${SUPPORTED_TYPE})" ;;
    esac

    if [[ -n "${BINARY_PATH}" ]]; then
        # ABS passes a directory when a submission has more than one file.
        if [[ -d "${BINARY_PATH}" ]]; then
            local found=()
            mapfile -t found < <(find "${BINARY_PATH}" -maxdepth 1 -type f -name 'ADAMANT-Messenger-*.AppImage' | sort)
            if [[ ${#found[@]} -ne 1 ]]; then
                die_invalid "--binary directory must hold exactly one ADAMANT-Messenger-*.AppImage (found ${#found[@]}): ${BINARY_PATH}"
            fi
            BINARY_PATH="${found[0]}"
        fi
        [[ -f "${BINARY_PATH}" ]] || die_invalid "--binary file not found: ${BINARY_PATH}"
        BINARY_PATH="$(readlink -f "${BINARY_PATH}")"
        local bn
        bn="$(basename "${BINARY_PATH}")"
        if [[ -z "${APP_VERSION}" && "${bn}" =~ ^ADAMANT-Messenger-([0-9][0-9A-Za-z._-]*)\.AppImage$ ]]; then
            APP_VERSION="${BASH_REMATCH[1]}"
            log_info "Version inferred from --binary file name: ${APP_VERSION}"
        fi
    fi

    [[ -n "${APP_VERSION}" ]] || die_invalid "Need --version (or a --binary named ADAMANT-Messenger-<version>.AppImage)"
    [[ "${APP_VERSION}" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || die_invalid "Invalid --version '${APP_VERSION}'"
    if [[ -n "${COMMIT_ARG}" && ! "${COMMIT_ARG}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        die_invalid "Invalid --commit '${COMMIT_ARG}'"
    fi
}

# ----------------------------------------------------------------------------
# Inline Dockerfile (source: package.json scripts + .github/workflows/electron-linux.yml)
# ----------------------------------------------------------------------------

write_dockerfile() {
    cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
ARG NODE_IMAGE
FROM ${NODE_IMAGE}
ARG ADAMANT_REPO
ARG ADAMANT_REF
ARG ADAMANT_TAG
ENV DEBIAN_FRONTEND=noninteractive HUSKY=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN apt-get update -qq && apt-get install -yqq --no-install-recommends \
    git ca-certificates python3 build-essential default-jre-headless squashfs-tools \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git clone "${ADAMANT_REPO}" adamant-im && cd adamant-im && \
    git checkout "${ADAMANT_REF}" && \
    { echo "COMMIT=$(git rev-parse HEAD)"; \
      echo "TAG_COMMIT=$(git rev-parse -q --verify "refs/tags/${ADAMANT_TAG}^{commit}" || echo none)"; \
      echo "TAG_TYPE=$(git cat-file -t "refs/tags/${ADAMANT_TAG}" 2>/dev/null || echo none)"; \
      echo "PKG_VERSION=$(node -p 'require("./package.json").version')"; \
      echo "NVMRC=$(tr -d 'v \n' < .nvmrc 2>/dev/null || true)"; } > /adamant_src.env && \
    cat /adamant_src.env
WORKDIR /build/adamant-im
# npm version from package.json "packageManager" (corepack), as upstream pins it.
RUN pm="$(node -p 'String(require("./package.json").packageManager||"")')"; \
    case "${pm}" in npm@*) corepack enable npm && corepack prepare "${pm}" --activate ;; esac; \
    { echo "NODE_V=$(node --version)"; echo "NPM_V=$(npm --version)"; } >> /adamant_src.env && \
    tail -2 /adamant_src.env
# npm ci: reproducible install from the committed package-lock.json (not npm install)
RUN npm ci
# CI runs schema:generate explicitly in addition to the one postinstall triggers.
RUN npm run schema:generate
# --publish never only skips the GitHub upload; the artifact is unchanged.
RUN npm run electron:build -- --publish never
COPY inner_build.sh /usr/local/bin/inner_build.sh
RUN chmod +x /usr/local/bin/inner_build.sh
DOCKERFILE_EOF
}

# ----------------------------------------------------------------------------
# Inner script (runs inside the container; downloads/accepts official AppImage,
# compares launcher, unpacks both with unsquashfs, diffs payload + metadata)
# ----------------------------------------------------------------------------

write_inner_script() {
    cat > "${WORK_DIR}/inner_build.sh" <<'INNER_EOF'
#!/bin/bash
# Inputs (env): ADAMANT_VERSION, GITHUB_TOKEN (optional), OWNER_UID/OWNER_GID.
# /out must be mounted; if /out/official-<name> exists it is used (user-provided
# --binary), otherwise the official AppImage is downloaded from GitHub releases.
set -euo pipefail
# Files under /out are created by container root; hand them back to the caller
# (0:0 under a rootless engine, which already maps to the invoking user).
trap 'chown -R "${OWNER_UID:-0}:${OWNER_GID:-0}" /out 2>/dev/null || true' EXIT

OUT=/out
BUILT_NAME="ADAMANT-Messenger-${ADAMANT_VERSION}.AppImage"
RELEASE_URL="https://github.com/Adamant-im/adamant-im/releases/download/v${ADAMANT_VERSION}"
OFFICIAL="${OUT}/official-${BUILT_NAME}"
BUILT="${OUT}/built-${BUILT_NAME}"
AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# --- [1/6] official AppImage ---
cd "${OUT}"
if [ ! -f "${OFFICIAL}" ]; then
    echo "[BUILD] Downloading official AppImage (v${ADAMANT_VERSION})..."
    curl -fsSL --retry 3 "${AUTH_ARGS[@]}" -o "${OFFICIAL}" "${RELEASE_URL}/${BUILT_NAME}"
else
    echo "[BUILD] Using provided official AppImage"
fi

# --- [2/6] locate built AppImage from the build stage ---
built_src="$(find /build/adamant-im/release-electron -maxdepth 1 -name '*.AppImage' | head -1)"
if [ -z "${built_src}" ]; then
    echo "[BUILD] FAIL: no AppImage produced under release-electron/"; exit 1
fi
cp "${built_src}" "${BUILT}"
cp /adamant_src.env "${OUT}/src.env"

# --- [3/6] launcher / SquashFS boundary, read from the ELF header (never executed) ---
# An AppImage is an ELF runtime (the launcher) with a SquashFS image appended right
# after the ELF section header table. Fails if the SquashFS magic is not there.
sq_offset() {
    python3 - "$1" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    h = f.read(64)
    if h[:4] != b'\x7fELF' or h[4] != 2:
        sys.exit("not a 64-bit ELF file")
    e_shoff = struct.unpack_from('<Q', h, 0x28)[0]
    shentsize, shnum = struct.unpack_from('<HH', h, 0x3a)
    off = e_shoff + shentsize * shnum
    f.seek(off)
    if f.read(4) != b'hsqs':
        sys.exit("no SquashFS magic at the end of the ELF runtime (offset %d)" % off)
print(off)
PY
}
OFF_OFFICIAL="$(sq_offset "${OFFICIAL}")"
OFF_BUILT="$(sq_offset "${BUILT}")"
: > launcher-cmp.txt
LAUNCHER_MATCH=0
if [ "${OFF_OFFICIAL}" = "${OFF_BUILT}" ] && cmp -n "${OFF_OFFICIAL}" "${OFFICIAL}" "${BUILT}" > launcher-cmp.txt 2>&1; then
    LAUNCHER_MATCH=1
fi
OFFICIAL_LAUNCHER_SHA256="$(head -c "${OFF_OFFICIAL}" "${OFFICIAL}" | sha256sum | cut -d' ' -f1)"
BUILT_LAUNCHER_SHA256="$(head -c "${OFF_BUILT}" "${BUILT}" | sha256sum | cut -d' ' -f1)"
echo ""
echo "Launcher (ELF runtime before the SquashFS): official ${OFF_OFFICIAL} bytes sha256 ${OFFICIAL_LAUNCHER_SHA256}"
echo "                                            built    ${OFF_BUILT} bytes sha256 ${BUILT_LAUNCHER_SHA256}"
[ "${LAUNCHER_MATCH}" = 1 ] && echo "Launcher: byte-identical" || { echo "Launcher: DIFFERS"; head -5 launcher-cmp.txt; }

# --- [4/6] unpack both with unsquashfs from the known offset ---
rm -rf official-extracted built-extracted
unsquashfs -no-progress -o "${OFF_OFFICIAL}" -d official-extracted "${OFFICIAL}" > unsquashfs-official.log 2>&1 \
    || { echo "[BUILD] FAIL: unsquashfs could not unpack the official AppImage"; tail -5 unsquashfs-official.log; exit 1; }
unsquashfs -no-progress -o "${OFF_BUILT}" -d built-extracted "${BUILT}" > unsquashfs-built.log 2>&1 \
    || { echo "[BUILD] FAIL: unsquashfs could not unpack the built AppImage"; tail -5 unsquashfs-built.log; exit 1; }
for t in official-extracted built-extracted; do
    n="$(find "${t}" -type f | wc -l)"
    if [ "${n}" -eq 0 ]; then echo "[BUILD] FAIL: ${t} holds no files"; exit 1; fi
done

# --- [5/6] payload + metadata diff (diff exit 2 = trouble, not a difference) ---
rc=0
diff -r --no-dereference official-extracted built-extracted > diff-appimage-payload.txt 2>&1 || rc=$?
if [ "${rc}" -gt 1 ]; then echo "[BUILD] FAIL: diff -r exited ${rc}"; head -5 diff-appimage-payload.txt; exit 1; fi
(cd official-extracted && find . -printf '%M %y %p -> %l\n' | sort) > meta-official.txt
(cd built-extracted && find . -printf '%M %y %p -> %l\n' | sort) > meta-built.txt
rc=0
diff meta-official.txt meta-built.txt > diff-appimage-metadata.txt 2>&1 || rc=$?
if [ "${rc}" -gt 1 ]; then echo "[BUILD] FAIL: metadata diff exited ${rc}"; exit 1; fi

# Per-file payload manifest: every path in either tree, both sides' content hash (or
# symlink target) and MATCH/DIFFER, printed AND written to file-hash-manifest.txt.
# Symlinks are compared by target string, never dereferenced.
echo ""
echo "Phase: Per-file payload verification (official vs built)"
echo "------------------------------------------------------"
all_paths="$(cat \
    <(cd official-extracted && find . \( -type f -o -type l \) | sed 's|^\./||') \
    <(cd built-extracted && find . \( -type f -o -type l \) | sed 's|^\./||') \
    | sort -u)"
total_files=$(printf '%s\n' "${all_paths}" | grep -c .)
: > file-hash-manifest.txt
file_index=0
FILES_MATCH=0
FILES_DIFFER=0
diffs_shown=0
diffs_shown_cap=8
: > asar-differ.txt
while IFS= read -r rel; do
    [ -z "${rel}" ] && continue
    file_index=$((file_index + 1))
    of="official-extracted/${rel}"
    bf="built-extracted/${rel}"
    o_desc="(missing)"
    b_desc="(missing)"
    if [ -L "${of}" ]; then
        o_desc="symlink -> $(readlink "${of}")"
    elif [ -f "${of}" ]; then
        o_desc="$(sha256sum "${of}" | cut -d' ' -f1)"
    fi
    if [ -L "${bf}" ]; then
        b_desc="symlink -> $(readlink "${bf}")"
    elif [ -f "${bf}" ]; then
        b_desc="$(sha256sum "${bf}" | cut -d' ' -f1)"
    fi
    if [ "${o_desc}" != "(missing)" ] && [ "${o_desc}" = "${b_desc}" ]; then
        status="MATCH"
        FILES_MATCH=$((FILES_MATCH + 1))
    else
        status="DIFFER"
        FILES_DIFFER=$((FILES_DIFFER + 1))
    fi
    line="$(printf '%3d/%-3d  %-55s official=%s built=%s [%s]' \
        "${file_index}" "${total_files}" "${rel}" "${o_desc}" "${b_desc}" "${status}")"
    echo "${line}"
    echo "${line}" >> file-hash-manifest.txt
    # Full diff for each differing regular file goes to diff-file-<rel>.txt; only the
    # first 8 are also previewed inline (5 lines each) so a large diff can't swamp the log.
    if [ "${status}" = "DIFFER" ] && [ -f "${of}" ] && [ -f "${bf}" ] && [ ! -L "${of}" ] && [ ! -L "${bf}" ]; then
        [ "${rel##*.}" = "asar" ] && echo "${rel}" >> asar-differ.txt
        safe_name="$(echo "${rel}" | tr '/' '_')"
        diff -u "${of}" "${bf}" > "diff-file-${safe_name}.txt" 2>&1 || true
        if [ "${diffs_shown}" -lt "${diffs_shown_cap}" ]; then
            diffs_shown=$((diffs_shown + 1))
            preview_lines=$(wc -l < "diff-file-${safe_name}.txt")
            echo "    -> diff (${preview_lines} line(s), full: diff-file-${safe_name}.txt):"
            head -5 "diff-file-${safe_name}.txt" | sed 's/^/       /'
        fi
    fi
done <<PATHS_EOF
${all_paths}
PATHS_EOF
FILES_TOTAL="${total_files}"
echo ""
if [ "${FILES_DIFFER}" -gt "${diffs_shown_cap}" ]; then
    echo "${FILES_DIFFER} files differ - see the complete list here: ${OUT}/file-hash-manifest.txt"
fi
echo "Payload summary: ${FILES_TOTAL} total, ${FILES_MATCH} identical, ${FILES_DIFFER} differ"
OFFICIAL_SIZE=$(stat -c%s "${OFFICIAL}")
BUILT_SIZE=$(stat -c%s "${BUILT}")
echo "official binary size: ${OFFICIAL_SIZE} bytes"
echo "built binary size:    ${BUILT_SIZE} bytes"
echo ""

# app.asar contents (diagnostic: the verdict is already set by the payload diff). Unpacked
# with our own reader, never upstream's asar tool (which the build installed), and every
# entry is checked against the SHA-256 the archive records for it in its own header.
asar_extract() {
    python3 - "$1" "$2" <<'ASAR_PY'
import hashlib, json, os, struct, sys
src, dest = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
base = 8 + struct.unpack_from('<I', data, 4)[0]
header = json.loads(data[16:16 + struct.unpack_from('<I', data, 12)[0]])
count = bad = 0
def walk(node, rel):
    global count, bad
    for name, e in node.get('files', {}).items():
        if name in ('', '.', '..') or '/' in name or '\\' in name or '\0' in name:
            sys.exit('unsafe entry name %r' % name)
        p = os.path.join(rel, name)
        out = os.path.join(dest, p)
        if 'files' in e:
            os.makedirs(out, exist_ok=True)
            walk(e, p)
        elif 'link' in e:
            os.symlink(e['link'], out)
        else:
            if e.get('unpacked'):
                u = os.path.join(src + '.unpacked', p)
                b = open(u, 'rb').read() if os.path.isfile(u) else b'(missing from .asar.unpacked)\n'
            else:
                off = base + int(e['offset'])
                b = data[off:off + int(e['size'])]
                if len(b) != int(e['size']):
                    sys.exit('truncated entry ' + p)
            ig = e.get('integrity') or {}
            if ig.get('algorithm') == 'SHA256' and hashlib.sha256(b).hexdigest() != ig.get('hash'):
                bad += 1
                print('[WARN] %s: %s does not match the SHA-256 in the archive header' % (src, p))
            with open(out, 'wb') as f:
                f.write(b)
            if e.get('executable'):
                os.chmod(out, 0o755)
            count += 1
os.makedirs(dest)
walk(header, '')
print('%s: %d entries unpacked, %d header-hash mismatches' % (src, count, bad))
ASAR_PY
}
: > asar-summary.txt
ASAR_ENTRIES_DIFFER=0
while IFS= read -r arel; do
    [ -z "${arel}" ] && continue
    asafe="$(echo "${arel}" | tr '/' '_')"
    ao="asar-official-${asafe}"
    ab="asar-built-${asafe}"
    rm -rf "${ao}" "${ab}"
    if ! asar_extract "official-extracted/${arel}" "${ao}" || ! asar_extract "built-extracted/${arel}" "${ab}"; then
        echo "Inside ${arel}: could not be unpacked (see log)" | tee -a asar-summary.txt
        continue
    fi
    echo ""
    echo "Phase: Contents of ${arel} (official vs built)"
    echo "------------------------------------------------------"
    a_paths="$(cat <(cd "${ao}" && find . \( -type f -o -type l \) | sed 's|^\./||') \
        <(cd "${ab}" && find . \( -type f -o -type l \) | sed 's|^\./||') | sort -u)"
    a_total=$(printf '%s\n' "${a_paths}" | grep -c . || true)
    a_diff=0
    a_shown=0
    : > "asar-manifest-${asafe}.txt"
    while IFS= read -r e; do
        [ -z "${e}" ] && continue
        o="${ao}/${e}"
        b="${ab}/${e}"
        oh="(missing)"
        bh="(missing)"
        if [ -L "${o}" ]; then oh="symlink -> $(readlink "${o}")"; elif [ -f "${o}" ]; then oh="$(sha256sum "${o}" | cut -d' ' -f1)"; fi
        if [ -L "${b}" ]; then bh="symlink -> $(readlink "${b}")"; elif [ -f "${b}" ]; then bh="$(sha256sum "${b}" | cut -d' ' -f1)"; fi
        st="MATCH"
        if [ "${oh}" = "(missing)" ] || [ "${oh}" != "${bh}" ]; then st="DIFFER"; a_diff=$((a_diff + 1)); fi
        echo "[${st}] ${e} official=${oh} built=${bh}" >> "asar-manifest-${asafe}.txt"
        [ "${st}" = "MATCH" ] && continue
        echo "  DIFFER ${e}  official=${oh} built=${bh}"
        if [ -f "${o}" ] && [ -f "${b}" ] && [ ! -L "${o}" ] && [ ! -L "${b}" ]; then
            ef="diff-asar-${asafe}_$(echo "${e}" | tr '/' '_').txt"
            diff -u "${o}" "${b}" > "${ef}" 2>&1 || true
            if [ "${a_shown}" -lt 8 ]; then
                a_shown=$((a_shown + 1))
                echo "    -> diff ($(wc -l < "${ef}") line(s), full: ${ef}), first 5 changed lines (200 chars max):"
                { grep -E '^[-+][^-+]' "${ef}" || true; } | head -5 | cut -c1-200 | sed 's/^/       /' || true
            fi
        fi
    done <<ASAR_PATHS_EOF
${a_paths}
ASAR_PATHS_EOF
    {
        echo "Inside ${arel}: ${a_total} entries, $((a_total - a_diff)) identical, ${a_diff} differ (full: asar-manifest-${asafe}.txt)"
        { grep '^\[DIFFER\]' "asar-manifest-${asafe}.txt" || true; } | head -20 | sed -E 's/^\[DIFFER\] ([^ ]*) .*/  differs: \1/' || true
    } | tee -a asar-summary.txt
    ASAR_ENTRIES_DIFFER=$((ASAR_ENTRIES_DIFFER + a_diff))
done < asar-differ.txt
echo ""

# SquashFS superblock field-by-field comparison, plus the trailer after the SquashFS
# image (electron-builder appends its update blockmap there; it is never executed).
# Explains an outer-hash mismatch when launcher + payload + metadata match.
# Diagnostic only (does not affect the verdict), never fails the run.
python3 - "${OFFICIAL}" "${BUILT}" "${OFF_OFFICIAL}" "${OFF_BUILT}" <<'SBCMP_EOF' || true
import datetime, hashlib, struct, sys

FIELDS = [
    ("magic", 4, "4s"), ("inode_count", 4, "<I"), ("mkfs_time", 4, "<i"),
    ("block_size", 4, "<I"), ("fragment_entry_count", 4, "<I"),
    ("compression_id", 2, "<H"), ("block_log", 2, "<H"), ("flags", 2, "<H"),
    ("id_count", 2, "<H"), ("version_major", 2, "<H"), ("version_minor", 2, "<H"),
    ("root_inode", 8, "<Q"), ("bytes_used", 8, "<Q"), ("id_table_start", 8, "<Q"),
    ("xattr_id_table_start", 8, "<Q"), ("inode_table_start", 8, "<Q"),
    ("directory_table_start", 8, "<Q"), ("fragment_table_start", 8, "<Q"),
    ("export_table_start", 8, "<Q"),
]

def read_superblock(path, offset):
    vals = {}
    with open(path, "rb") as f:
        f.seek(offset)
        for name, size, fmt in FIELDS:
            raw = f.read(size)
            if len(raw) < size:
                return None
            vals[name] = struct.unpack(fmt, raw)[0]
    return vals

def trailer(path, start):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        f.seek(start)
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
    return n, h.hexdigest()

def fmt_val(name, v):
    if name == "mkfs_time":
        dt = datetime.datetime.fromtimestamp(v, datetime.timezone.utc)
        return "{} -> {} UTC".format(v, dt.strftime("%Y-%m-%d %H:%M:%S"))
    if name == "magic":
        return v.decode(errors="replace")
    return str(v)

official_path, built_path = sys.argv[1], sys.argv[2]
off_o, off_b = int(sys.argv[3]), int(sys.argv[4])
sb_o = read_superblock(official_path, off_o)
sb_b = read_superblock(built_path, off_b)
if not sb_o or not sb_b:
    print("[WARN] SquashFS superblock comparison skipped: superblock unreadable")
    sys.exit(0)

rows = [(name, fmt_val(name, sb_o[name]), fmt_val(name, sb_b[name]), sb_o[name] != sb_b[name])
        for name, _, _ in FIELDS]
col1 = max([len("Field")] + [len(r[0]) for r in rows])
col2 = max([len("Official")] + [len(r[1]) for r in rows])
col3 = max([len("Built")] + [len(r[2]) for r in rows])
border = "+-" + "-" * col1 + "-+-" + "-" * col2 + "-+-" + "-" * col3 + "-+"

print("")
print("SquashFS superblock comparison (offsets: official={}, built={}):".format(off_o, off_b))
print(border)
print("| {} | {} | {} |".format("Field".ljust(col1), "Official".ljust(col2), "Built".ljust(col3)))
print(border)
with open("squashfs-superblock-diff.txt", "w") as manifest:
    for name, vo, vb, differs in rows:
        marker = "  <-- DIFFERS" if differs else ""
        print("| {} | {} | {} |{}".format(name.ljust(col1), vo.ljust(col2), vb.ljust(col3), marker))
        manifest.write("{}: official={} built={} [{}]\n".format(name, vo, vb, "DIFFERS" if differs else "same"))
    print(border)
    to = trailer(official_path, off_o + sb_o["bytes_used"])
    tb = trailer(built_path, off_b + sb_b["bytes_used"])
    for label, (n, h) in (("official", to), ("built", tb)):
        line = "trailer after SquashFS ({}): {} bytes sha256 {}".format(label, n, h)
        print(line)
        manifest.write(line + "\n")
print("")
SBCMP_EOF

echo "Evidence for further investigation (all paths under ${OUT}):"
echo "  - launcher-cmp.txt                 first differing launcher byte (empty = identical)"
echo "  - file-hash-manifest.txt           per-file official/built hash + MATCH/DIFFER status"
echo "  - diff-appimage-payload.txt        raw 'diff -r' of the two unpacked trees"
echo "  - diff-appimage-metadata.txt       permissions/type/symlink-target diff"
echo "  - diff-file-<name>.txt             full diff for each individually differing file (if any)"
echo "  - squashfs-superblock-diff.txt     SquashFS superblock fields + trailer hashes"
echo "  - asar-manifest-<name>.txt         per-entry hashes inside a differing .asar archive"
echo "  - diff-asar-<name>_<entry>.txt     full diff for each differing entry inside it"
echo "  - official-${BUILT_NAME} / built-${BUILT_NAME}   the raw AppImages themselves"
echo "  - official-extracted/ / built-extracted/          full unpacked trees"
echo ""

# --- [6/6] machine-readable result (plain KEY=VALUE, parsed by the host, not sourced) ---
{
    echo "OFFICIAL_SHA256=$(sha256sum "${OFFICIAL}" | cut -d' ' -f1)"
    echo "BUILT_SHA256=$(sha256sum "${BUILT}" | cut -d' ' -f1)"
    echo "LAUNCHER_MATCH=${LAUNCHER_MATCH}"
    echo "LAUNCHER_SIZE=${OFF_OFFICIAL}"
    echo "OFFICIAL_LAUNCHER_SHA256=${OFFICIAL_LAUNCHER_SHA256}"
    echo "BUILT_LAUNCHER_SHA256=${BUILT_LAUNCHER_SHA256}"
    echo "PAYLOAD_DIFF_LINES=$(wc -l < diff-appimage-payload.txt)"
    echo "METADATA_DIFF_LINES=$(wc -l < diff-appimage-metadata.txt)"
    echo "FILES_TOTAL=${FILES_TOTAL}"
    echo "FILES_MATCH=${FILES_MATCH}"
    echo "FILES_DIFFER=${FILES_DIFFER}"
    echo "ASAR_ENTRIES_DIFFER=${ASAR_ENTRIES_DIFFER}"
    echo "OFFICIAL_SIZE=${OFFICIAL_SIZE}"
    echo "BUILT_SIZE=${BUILT_SIZE}"
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
    if [[ "$(id -u)" -eq 0 ]]; then
        die_invalid "Do not run as root (sudo is not allowed); run as a normal user with podman or docker"
    fi
    detect_container_cmd

    # Under a rootless engine container root already is the invoking user: a chown to
    # the host uid would land in the subuid range. Rootful engines get the real ids.
    local owner_uid owner_gid
    owner_uid="$(id -u)"; owner_gid="$(id -g)"
    # Asks the engine itself (podman field, then docker field), so a full path in DOCKER_CMD works.
    if [[ "$("${DOCKER_CMD}" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == true ]] \
       || "${DOCKER_CMD}" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        owner_uid=0; owner_gid=0
    fi

    local safe_ver execution_dir source_ref
    safe_ver="$(echo "${APP_VERSION}" | tr -c 'a-zA-Z0-9.' '-' | sed 's/-*$//')"
    execution_dir="$(pwd)"
    WORK_DIR="$(mktemp -d "${execution_dir}/adamant_${safe_ver}_${APP_ARCH}_${APP_TYPE}_XXXXXX")"
    mkdir -p "${WORK_DIR}/out"
    source_ref="${COMMIT_ARG:-v${APP_VERSION}}"
    log_info "App: ${APP_ID} ${APP_VERSION} (${APP_ARCH}, ${APP_TYPE}), source ref ${source_ref}"
    log_info "Build image: ${NODE_IMAGE_TAG} (${NODE_IMAGE#*@})"
    log_info "Work dir: ${WORK_DIR}"

    local built_name="ADAMANT-Messenger-${APP_VERSION}.AppImage"
    if [[ -n "${BINARY_PATH}" ]]; then
        cp "${BINARY_PATH}" "${WORK_DIR}/out/official-${built_name}"
        log_info "Using provided binary as official artifact: ${BINARY_PATH}"
    fi

    write_dockerfile
    write_inner_script

    IMAGE_TAG="ws-adamant-verifier-${safe_ver}-${APP_ARCH}-${APP_TYPE}-$(date +%s)-$$"
    local build_args=(--build-arg "NODE_IMAGE=${NODE_IMAGE}" --build-arg "ADAMANT_REPO=${ADAMANT_REPO}"
        --build-arg "ADAMANT_REF=${source_ref}" --build-arg "ADAMANT_TAG=v${APP_VERSION}")
    [[ "${NO_CACHE}" == true ]] && build_args+=(--no-cache)
    log_info "Building container image ${IMAGE_TAG} (git clone + npm ci + electron-builder)..."
    "${DOCKER_CMD}" build -t "${IMAGE_TAG}" "${build_args[@]}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}"

    log_info "Running comparison in container..."
    "${DOCKER_CMD}" run --rm \
        -v "${WORK_DIR}/out:/out" \
        -e ADAMANT_VERSION="${APP_VERSION}" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN}" \
        -e OWNER_UID="${owner_uid}" -e OWNER_GID="${owner_gid}" \
        "${IMAGE_TAG}" /usr/local/bin/inner_build.sh

    # ---- verdict ----
    local out="${WORK_DIR}/out"
    [[ -f "${out}/RESULT.env" && -f "${out}/src.env" ]] || die_failed "RESULT.env/src.env missing after the comparison step."
    local OFFICIAL_SHA256="" BUILT_SHA256="" LAUNCHER_MATCH="" LAUNCHER_SIZE="" OFFICIAL_LAUNCHER_SHA256=""
    local BUILT_LAUNCHER_SHA256="" PAYLOAD_DIFF_LINES="" METADATA_DIFF_LINES="" FILES_TOTAL="" FILES_MATCH=""
    local FILES_DIFFER="" OFFICIAL_SIZE="" BUILT_SIZE="" ASAR_ENTRIES_DIFFER=""
    local COMMIT="" TAG_COMMIT="" TAG_TYPE="" PKG_VERSION="" NVMRC="" NODE_V="" NPM_V=""
    load_env_file "${out}/RESULT.env" OFFICIAL_SHA256 BUILT_SHA256 LAUNCHER_MATCH LAUNCHER_SIZE \
        OFFICIAL_LAUNCHER_SHA256 BUILT_LAUNCHER_SHA256 PAYLOAD_DIFF_LINES METADATA_DIFF_LINES \
        FILES_TOTAL FILES_MATCH FILES_DIFFER OFFICIAL_SIZE BUILT_SIZE ASAR_ENTRIES_DIFFER
    load_env_file "${out}/src.env" COMMIT TAG_COMMIT TAG_TYPE PKG_VERSION NVMRC NODE_V NPM_V
    [[ "${PAYLOAD_DIFF_LINES}" =~ ^[0-9]+$ && "${METADATA_DIFF_LINES}" =~ ^[0-9]+$ && "${LAUNCHER_MATCH}" =~ ^[01]$ ]] \
        || die_failed "RESULT.env is incomplete; no verdict computed."

    local warnings=""
    [[ "${PKG_VERSION}" == "${APP_VERSION}" ]] || warnings+="package.json version at ${source_ref} is ${PKG_VERSION}, not ${APP_VERSION}.
"
    [[ -z "${NVMRC}" || "${NODE_V#v}" == "${NVMRC%%.*}."* ]] || warnings+="upstream .nvmrc asks for Node ${NVMRC}; the pinned image has ${NODE_V}.
"
    if [[ -n "${COMMIT_ARG}" && "${TAG_COMMIT}" != "${COMMIT}" ]]; then
        warnings+="Built ${COMMIT} (--commit ${COMMIT_ARG}) instead of tag v${APP_VERSION} (${TAG_COMMIT}).
"
    fi
    [[ -z "${warnings}" ]] || printf '%s' "${warnings}" | sed 's/^/[WARN] /' >&2

    # The whole-AppImage hash is recorded but does not gate the verdict: the SquashFS
    # superblock carries a build-time mkfs_time and electron-builder appends a blockmap
    # computed over the image, so the outer hash differs on every build. The verdict
    # requires the launcher bytes, the unpacked payload AND the unpacked metadata
    # (permissions/types/symlinks) to match.
    local verdict
    if [[ "${LAUNCHER_MATCH}" == 1 && "${PAYLOAD_DIFF_LINES}" -eq 0 && "${METADATA_DIFF_LINES}" -eq 0 ]]; then
        verdict="reproducible"
    else
        verdict="not_reproducible"
    fi
    # Paths in the results and YAML are relative to the execution directory: a report
    # quotes this block, and a reader elsewhere has no /home/<user>.
    local rel_out="${WORK_DIR#"${execution_dir}"/}/out"
    local tag_desc="not found"
    case "${TAG_TYPE}" in
        commit) tag_desc="lightweight tag (no tag object, cannot carry a signature)" ;;
        tag) tag_desc="annotated tag (tag object)" ;;
    esac
    local match_line="0 (DOESN'T MATCH)" builds_line="BUILDS DO NOT MATCH BINARIES"
    if [[ "${verdict}" == "reproducible" ]]; then
        match_line="1 (MATCHES)"; builds_line="BUILDS MATCH BINARIES"
    fi
    local launcher_state="DIFFERS"
    [[ "${LAUNCHER_MATCH}" == 1 ]] && launcher_state="identical"

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${verdict}"
    echo "appHash:        ${OFFICIAL_SHA256}"
    echo "builtHash:      ${BUILT_SHA256}"
    echo "commit:         ${COMMIT}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256}"
    echo ""
    echo "Diff:"
    echo "${builds_line}"
    echo "${built_name} - ${APP_ARCH} - ${BUILT_SHA256} - ${match_line}"
    echo "Launcher (ELF runtime, first ${LAUNCHER_SIZE} bytes): ${launcher_state}"
    echo "  official sha256 ${OFFICIAL_LAUNCHER_SHA256}"
    echo "  built    sha256 ${BUILT_LAUNCHER_SHA256}"
    echo "AppImage size: official ${OFFICIAL_SIZE} bytes, built ${BUILT_SIZE} bytes"
    echo "Payload files: ${FILES_TOTAL} total, ${FILES_MATCH} identical, ${FILES_DIFFER} differ"
    echo "Payload diff: ${PAYLOAD_DIFF_LINES} line(s) (full: ${rel_out}/diff-appimage-payload.txt)"
    if [[ "${PAYLOAD_DIFF_LINES}" -gt 0 ]]; then
        echo "Diff preview (first 5 of ${PAYLOAD_DIFF_LINES} line(s)):"
        head -5 "${out}/diff-appimage-payload.txt" | cut -c1-200 | cat -v
    fi
    if [[ -s "${out}/asar-summary.txt" ]]; then
        head -25 "${out}/asar-summary.txt" | cut -c1-200 | cat -v
    fi
    echo "Metadata diff (modes/types/symlinks): ${METADATA_DIFF_LINES} line(s) (full: ${rel_out}/diff-appimage-metadata.txt)"
    if [[ "${OFFICIAL_SHA256}" != "${BUILT_SHA256}" ]]; then
        echo "Outer AppImage hash differs (SquashFS mkfs_time + appended blockmap, see"
        echo "squashfs-superblock-diff.txt); the verdict is taken on launcher + payload + metadata."
    fi
    echo ""
    echo "Revision, tag (and its signature):"
    echo "Ref built: ${source_ref} = ${COMMIT}"
    echo "Tag v${APP_VERSION}: ${tag_desc} -> ${TAG_COMMIT}"
    echo "Signature verification: not implemented"
    echo "Toolchain: ${NODE_IMAGE_TAG} node ${NODE_V} npm ${NPM_V}"
    if [[ -n "${warnings}" ]]; then
        echo ""
        echo "===== Also ===="
        printf '%s' "${warnings}"
    fi
    echo "===== End Results ====="
    echo ""
    echo "Run a full"
    echo "diff -r --no-dereference ${rel_out}/official-extracted ${rel_out}/built-extracted"
    echo "or"
    echo "diffoscope ${rel_out}/official-${built_name} ${rel_out}/built-${built_name}"
    echo ""

    local notes="Rebuilt ${source_ref} (${COMMIT}) in ${NODE_IMAGE_TAG} (node ${NODE_V}, npm ${NPM_V}):
npm ci + npm run schema:generate + npm run electron:build, as upstream electron-linux.yml.
Official AppImage sha256 ${OFFICIAL_SHA256}; built ${BUILT_SHA256}.
Launcher (first ${LAUNCHER_SIZE} bytes, ELF runtime): ${launcher_state}.
Payload unpacked with unsquashfs (official file never executed):
${FILES_MATCH}/${FILES_TOTAL} files identical, metadata diff ${METADATA_DIFF_LINES} line(s).
Entries differing inside differing .asar archives: ${ASAR_ENTRIES_DIFFER:-0} (asar-manifest-*.txt).
Outer AppImage hash is not used for the verdict: the SquashFS superblock carries a
build-time mkfs_time and electron-builder appends a blockmap computed over the image.
Full evidence (diffs, manifests, superblock table) in ${rel_out}.
No official SHA256SUMS manifest exists to cross-check the download."
    if [[ -n "${warnings}" ]]; then
        notes+="
Warnings:
${warnings%$'\n'}"
    fi
    write_yaml "${verdict}" "${notes}"
    cleanup_image

    log_info "Artifacts kept in ${WORK_DIR}/out (unpacked trees, diffs, both AppImages) — persistent, not /tmp"
    if [[ "${verdict}" == "reproducible" ]]; then
        exit "${EXIT_SUCCESS}"
    fi
    exit "${EXIT_BUILD_FAILED}"
}

main "$@"
