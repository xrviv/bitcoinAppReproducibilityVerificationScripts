#!/bin/bash
#
# nunchukwindows_build.sh - Nunchuk Desktop Windows Reproducible Build Verifier
# Version: v0.2.1
# Last modified by: Danny Garcia, Carol (Buzz), Claude Code
# Last modified on: 2026-11-24
# Organization: WalletScrutiny.com
# Project: https://github.com/nunchuk-io/nunchuk-desktop
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER: provided for reproducible build verification only, without warranty of
# security, functionality or fitness for any purpose. Users assume all risks of running it.
# LEGAL DISCLAIMER: an independent verification tool, not affiliated with or endorsed by Nunchuk.
# All trademarks belong to their respective owners.
#
# Rebuilds the Windows x64 installer (Inno Setup) and portable ZIP with upstream's
# reproducible-builds/build_windows.ps1 + package_windows.ps1 at the release tag, inside a Windows
# Server 2022 VM (dockurr/windows under QEMU/KVM, booted from a per-run overlay of a read-only golden
# image), and compares the selected file (--type) byte for byte with the release. Upstream marks Windows
# verification "standby": expect differences.
#
# Shared steps come from ws-rb-core 1.1.0, pinned by sha256. One verdict per run, for --type. Usage: --help.
#

set -euo pipefail

SCRIPT_VERSION="v0.2.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1)" || true
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
printf '%s %s sha256:%s\n' "$(basename "$SCRIPT_PATH")" "$SCRIPT_VERSION" "$SCRIPT_SHA256"

# ---- WalletScrutiny library (GitLab #1023), pinned by sha256 ------------------
# Goes in each build script right after its self-hash line, before anything else.
# Source: WS_LIB_FILE (offline, must match), else the cache, else GitLab by
# commit. Nothing else. A wrong hash is rejected whichever source sent it.
# No matching copy, or a different version inside: no verdict, no YAML, exit 2.
# First, before anything can fail: no earlier verdict may survive this run. A run
# that holds this folder's lock is still writing its own; that one stays, and the
# library refuses this run when it takes the lock.
WS_LIB_DIR0="$(dirname "$(readlink -f "$0")")"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WS_LIB_DIR0/.comparison_results.lock" true 2>/dev/null && rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
else
  WS_LIB_P="$(cat "$WS_LIB_DIR0/.comparison_results.lock.d/pid" 2>/dev/null || true)"
  case "$WS_LIB_P" in ''|*[!0-9]*) WS_LIB_P="";; esac
  { [ -n "$WS_LIB_P" ] && kill -0 "$WS_LIB_P" 2>/dev/null; } || rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
fi
WS_LIB=ws-rb-core WS_LIB_VERSION=1.1.0
WS_LIB_REV=3bafe3b5961f11bcf1fa4fbbe3f4f206d53a61d0 WS_LIB_SHA256=4f0920dc8edb1e07aefbb4748d72fd3cc011eb769aaa40de8b5a6a9026312c7e
ws_lib_load() {
  local c f u t=""
  ws_lib_ok() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$WS_LIB_SHA256" ]; }
  if [ -n "${WS_LIB_FILE:-}" ]; then
    f="$WS_LIB_FILE"
    ws_lib_ok "$f" || { echo "[FAIL] WS_LIB_FILE $f is not sha256 $WS_LIB_SHA256: no verdict" >&2; exit 2; }
  else
    # Cache in XDG_CACHE_HOME or HOME; with neither, or no way to create it, a
    # temporary folder for this run only. Every copy is hash-checked either way.
    c="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
    if [ -n "$c" ] && mkdir -p "$c/ws-rb-lib" 2>/dev/null; then c="$c/ws-rb-lib"
    else t="$(mktemp -d 2>/dev/null)" || { echo "[FAIL] no folder to fetch $WS_LIB into: no verdict" >&2; exit 2; }; c="$t"; fi
    f="$c/$WS_LIB_SHA256.sh"
    if ! ws_lib_ok "$f"; then
      u="https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/$WS_LIB_REV/scripts/rb/lib/$WS_LIB-$WS_LIB_VERSION.sh"
      curl -fsSL --max-time 60 -o "$f.$$" "$u" 2>/dev/null && ws_lib_ok "$f.$$" && mv -f "$f.$$" "$f"
      rm -f "$f.$$"
    fi
  fi
  ws_lib_ok "$f" || { [ -z "$t" ] || rm -rf -- "$t"; echo "[FAIL] $WS_LIB $WS_LIB_VERSION ($WS_LIB_SHA256) unavailable or altered: no verdict" >&2; exit 2; }
  # 1.1.0 and later mount this file into the build container (WS_LIB_PATH)
  # and remove a temporary folder on exit; for 1.0.0 it goes now.
  WS_LIB_PATH="$f" WS_LIB_TMP="$t"
  . "$f"
  [ -z "$t" ] || [ -n "${WS_LIB_MOUNT:-}" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load

APP_ID="nunchuk"
APP_NAME="Nunchuk Desktop (Windows)"
GH_REPO="nunchuk-io/nunchuk-desktop"
MIN_VERSION="2.9.1"

APP_VERSION=""
APP_ARCH="x86_64-windows"
APP_TYPE="setup"
BINARY_PATH=""
GIT_IMAGE="${GIT_IMAGE:-docker.io/alpine/git@sha256:6f8eae2205a85c51106a9650e574a37fb1d5e4f645e5f6ea57cb57b9462cd4cf}"
WIN_IMAGE="docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea"
GOLDEN_DIR="${WS_WINDOWS_GOLDEN:-/var/lib/walletscrutiny-windows/golden-2022}"
VM_KEY="${WS_WINDOWS_KEY:-/var/lib/walletscrutiny-windows/vm-key/ws-windows-vm}"
VM_RAM="${WS_WINDOWS_RAM:-8G}"
WORK_DIR=""
VM_NAME=""
VM_PORT=""
SSH_HELPER=""
TOOLS_USER=()
RESOLVED_COMMIT="unknown"
SOURCE_EPOCH=""
D3D_REDIST=""
PHASE_TIMES=""
# Elapsed time of a phase, for the results block.
phase_done() { PHASE_TIMES+="${1}: $(( (SECONDS - PHASE_T0) / 60 )) min $(( (SECONDS - PHASE_T0) % 60 )) s"$'\n'; PHASE_T0=$SECONDS; }
PHASE_T0=0

# From build-info.json: runner image (only GitHub sets it; not faked, Danny 2026-10-21) and compiler.
REL_IMAGE_OS=""
REL_IMAGE_VERSION=""
REL_MSVC=""
VS_REL=""

NUNCHUK_RELEASE_KEY_FPR="8C8ECD3F660CA53CD878792A6E38A462ED2EF525"
SIG_MANIFEST_STATUS="[WARNING] Manifest signature not checked"
SIG_DIGEST_STATUS="[WARNING] Digests not checked against a signed manifest"
SIG_WARNINGS=""

# Per artifact (setup, portable): release name, official / rebuilt sha256, diff summary.
declare -A OFF_NAME OFF_SHA BUILT_SHA DIFF_NOTE
ARTIFACTS=()

# Upstream build failure: ftbfs.
die_build() { ws_error "$1"; ws_write_yaml ftbfs "$1"; exit "$WS_EXIT_FAIL"; }
die_provenance() { ws_no_verdict "PROVENANCE FAILURE: $1. The artifact compared is not the file upstream signed."; }

# Tools (BusyBox wget/unzip/sha256sum, GnuPG, git, ssh) from the pinned git image, WORK_DIR at /w.
tools_c() {
    local tool="$1"; shift
    ws_ctr run --rm "${TOOLS_USER[@]}" -e GITHUB_TOKEN -v "${WORK_DIR}:/w" -w /w \
        --entrypoint "$tool" "$GIT_IMAGE" "$@"
}
gpg_c() { tools_c gpg --homedir /w/gnupg --no-autostart "$@"; }

# GitHub hosts: token first, then anonymous. Other hosts never see the token.
gh_wget() {
    local rel="${1#"${WORK_DIR}"/}" url="$2"
    case "$url" in
        https://github.com/*|https://api.github.com/*) ;;
        *) GITHUB_TOKEN="" tools_c wget -q -O "$rel" "$url" 2>/dev/null; return ;;
    esac
    # shellcheck disable=SC2016
    tools_c sh -c 'if [ -n "${GITHUB_TOKEN:-}" ]; then
            wget -q --header="Authorization: token ${GITHUB_TOKEN}" -O "$1" "$2" 2>/dev/null && exit 0
            echo "[WARN] Token download failed, retrying anonymously: $2"
        fi
        wget -q -O "$1" "$2" 2>/dev/null' sh "$rel" "$url"
}

ws_sha256() { [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || echo "N/A"; }

is_rootless() {
    local r=""
    case "$WS_ENGINE" in
        podman) r="$(ws_ctr info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" ;;
        docker) ws_ctr info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && r=true ;;
    esac
    [[ "$r" == "true" ]]
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION [--binary FILE|DIR] [--arch ARCH] [--type setup|portable] [--golden DIR]"
        exit "$WS_EXIT_INVALID"
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) ws_require_value "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
            --binary)  ws_require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --arch)    ws_require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    ws_require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --golden)  ws_require_value "$1" "${2:-}"; GOLDEN_DIR="$2"; shift 2 ;;
            --apk)
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi
                ws_warn "--apk is not applicable for desktop builds (ignored)" ;;
            --help) show_help; exit 0 ;;
            *) ws_unknown_arg "$@"; shift "$WS_SHIFT" ;;
        esac
    done
    [[ -n "$APP_VERSION" ]] || ws_invalid "--version is required"
    # package_windows.ps1 accepts exactly X.Y.Z.
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || ws_invalid "Invalid --version '${APP_VERSION}' (expected e.g. 2.9.1, no v prefix)"
    [[ "$APP_ARCH" == "x86_64-windows" ]] \
        || ws_invalid "Unsupported --arch '${APP_ARCH}'; only x86_64-windows is implemented"
    case "$APP_TYPE" in
        setup|portable) ARTIFACTS=("$APP_TYPE") ;;
        *) ws_invalid "Unsupported --type '${APP_TYPE}'; use setup or portable" ;;
    esac
    if [[ "$(printf '%s\n' "$MIN_VERSION" "$APP_VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]]; then
        ws_invalid "Version ${APP_VERSION} predates ${MIN_VERSION}, the first release with build_windows.ps1"
    fi
    if [[ -n "$BINARY_PATH" ]]; then
        [[ -e "$BINARY_PATH" ]] || ws_invalid "--binary path does not exist: $BINARY_PATH"
        BINARY_PATH="$(realpath "$BINARY_PATH")"
        local pat m=() magic want
        [[ "$APP_TYPE" == setup ]] && { pat='*-x64-setup*.exe'; want=4d5a; } || { pat='*-x64-portable*.zip'; want=504b0304; }
        # ABS passes a directory when a submission has several files: take the one for --type.
        if [[ -d "$BINARY_PATH" ]]; then
            shopt -s nullglob
            # shellcheck disable=SC2206 # $pat is a glob on purpose
            m=("$BINARY_PATH"/$pat)
            shopt -u nullglob
            [[ ${#m[@]} -eq 1 ]] || ws_invalid "--binary directory needs exactly one ${pat} file (found ${#m[@]})"
            BINARY_PATH="${m[0]}"
        fi
        # The installer is a PE file (MZ), the portable build a ZIP (PK\3\4).
        magic="$(head -c 4 "$BINARY_PATH" | od -An -tx1 | tr -d ' \n')"
        [[ "$magic" == "$want"* ]] || ws_invalid "--binary is not a ${APP_TYPE} file (starts with ${magic:-nothing})"
    fi
}

show_help() {
    cat << 'EOF'
nunchukwindows_build.sh - Nunchuk Desktop Windows Reproducible Build Verification

USAGE:
  nunchukwindows_build.sh --version VERSION [OPTIONS]

REQUIRED:
  --version VERSION    Release version without v prefix, 2.9.1 or later

OPTIONAL:
  --binary FILE|DIR    Official file of the selected --type, or a folder holding it (skip its download)
  --arch ARCH          x86_64-windows (default, only supported value)
  --type TYPE          setup (default, the Inno Setup installer) or portable (the ZIP)
  --golden DIR         Golden image folder (default: $WS_WINDOWS_GOLDEN)

OPTIONAL ENVIRONMENT:
  GITHUB_TOKEN         Used for GitHub downloads, to avoid rate limiting
  WS_WINDOWS_GOLDEN    Golden image folder (default /var/lib/walletscrutiny-windows/golden-2022)
  WS_WINDOWS_KEY       VM SSH key (default /var/lib/walletscrutiny-windows/vm-key/ws-windows-vm)
  WS_WINDOWS_RAM       VM memory (default 8G)

REQUIREMENTS:
  podman (or docker), read/write /dev/kvm, read access to the golden image and the VM key.
  Run as a normal user. Tools missing from the golden image are installed per run, hash-checked;
  their versions are asserted either way.

EXIT CODES:
  0  Identical (the selected file is byte-for-byte equal)
  1  Differences found, build failed, or a failure with no verdict (host, network, VM, prerequisites)
  2  Invalid parameters, or ws-rb-core could not be loaded
  130  Interrupted (no verdict)

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/built/          (rebuilt artifacts)
EOF
}

setup_workdir() {
    ws_workspace nunchukwin "$APP_VERSION" "${APP_ARCH}_${APP_TYPE}"
    WORK_DIR="$WS_WORKDIR"
    mkdir -p "$WORK_DIR"/{official,built,vm}
}

# Run first by ws_on_exit: remove the VM, hand files back, delete vm/ (overlays, key copy).
ws_cleanup_hook() {
    [[ -z "$VM_NAME" ]] || ws_ctr rm -f "$VM_NAME" > /dev/null 2>&1 || true
    [[ -z "$SSH_HELPER" ]] || ws_ctr rm -f "$SSH_HELPER" > /dev/null 2>&1 || true
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
    ws_hand_back
    chmod -R u+rwX "$WORK_DIR" > /dev/null 2>&1 || true
    rm -rf "${WORK_DIR}/vm" || true
}

check_prereqs() {
    local f ends
    [[ -r /dev/kvm && -w /dev/kvm ]] || ws_no_verdict "/dev/kvm is not readable and writable for $(id -un) (needs the kvm group)"
    [[ -e /dev/net/tun ]] || ws_no_verdict "/dev/net/tun is missing"
    for f in storage/data.qcow2 storage2/data2.qcow2 storage/windows.boot GOLDEN-INFO.txt; do
        [[ -r "${GOLDEN_DIR}/${f}" ]] || ws_no_verdict "Golden image file not readable: ${GOLDEN_DIR}/${f} (needs the windows-images group)"
    done
    [[ -r "$VM_KEY" ]] || ws_no_verdict "VM SSH key not readable: ${VM_KEY}"
    ends="$(grep -oE 'evaluation ends ~?[0-9]{4}-[0-9]{2}-[0-9]{2}' "${GOLDEN_DIR}/GOLDEN-INFO.txt" | grep -oE '[0-9-]{10}' | head -1 || true)"
    [[ -n "$ends" ]] || ws_no_verdict "GOLDEN-INFO.txt has no 'evaluation ends YYYY-MM-DD' line"
    [[ "$(date -u +%F)" < "$ends" ]] || ws_no_verdict "The golden image's Windows evaluation ended on ${ends}; rebuild it (#984 runbook)"
    ws_ok "Prerequisites: /dev/kvm, golden image ${GOLDEN_DIR} (evaluation ends ${ends}), VM key"
}

# Release names: 2.9.1 renamed CI's -unsigned files; from 2.9.2 the release keeps the CI names.
asset_name() {
    [[ "$APP_VERSION" == 2.9.1 ]] || { built_name "$1"; return; }
    case "$1" in
        setup) printf 'nunchuk-windows-v%s-x64-setup.exe' "$APP_VERSION" ;;
        portable) printf 'nunchuk-windows-v%s-x64-portable.zip' "$APP_VERSION" ;;
    esac
}
built_name() {
    case "$1" in
        setup) printf 'nunchuk-windows-v%s-x64-setup-unsigned.exe' "$APP_VERSION" ;;
        portable) printf 'nunchuk-windows-v%s-x64-portable-unsigned.zip' "$APP_VERSION" ;;
    esac
}

prepare_official() {
    local a dest url
    # The portable ZIP is always fetched: its build-info.json names the runner image and compiler.
    for a in setup portable; do
        OFF_NAME[$a]="$(asset_name "$a")"
        dest="${WORK_DIR}/official/${OFF_NAME[$a]}"
        if [[ -n "$BINARY_PATH" && "$a" == "$APP_TYPE" ]]; then
            [[ "$(basename "$BINARY_PATH")" == "${OFF_NAME[$a]}" ]] \
                || ws_warn "--binary is named $(basename "$BINARY_PATH"), expected ${OFF_NAME[$a]}; compared as ${OFF_NAME[$a]}"
            cp "$BINARY_PATH" "$dest"
        elif [[ "$a" == portable || " ${ARTIFACTS[*]} " == *" $a "* ]]; then
            url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/${OFF_NAME[$a]}"
            ws_info "Downloading official release: $url"
            gh_wget "$dest" "$url" || ws_no_verdict "Failed to download: $url"
        else
            continue
        fi
        OFF_SHA[$a]="$(ws_sha256 "$dest")"
        ws_ok "Official ${OFF_NAME[$a]} ($(stat -c%s "$dest") bytes) sha256 ${OFF_SHA[$a]}"
    done
    # shellcheck disable=SC2016
    tools_c sh -c 'unzip -p "$1" build-info.json > official/build-info.json' sh "official/${OFF_NAME[portable]}" \
        || ws_no_verdict "The official portable ZIP has no build-info.json"
    REL_IMAGE_OS="$(sed -nE 's/.*"runnerImage": *"([^"]*)".*/\1/p' "${WORK_DIR}/official/build-info.json")"
    REL_IMAGE_VERSION="$(sed -nE 's/.*"runnerImageVersion": *"([^"]*)".*/\1/p' "${WORK_DIR}/official/build-info.json")"
    REL_MSVC="$(sed -nE 's/.*"msvcFileVersion": *"([^"]*)".*/\1/p' "${WORK_DIR}/official/build-info.json")"
    # Keep in sync with $vs in nw.ps1.
    case "$REL_MSVC" in
        19.44.35229.0) VS_REL=17.14.41 ;;
        19.44.35230.0) VS_REL=17.14.45 ;;
        *) ws_no_verdict "No VS Build Tools pinned for the release's cl.exe '${REL_MSVC}' (msvcFileVersion)" ;;
    esac
    ws_info "Release built on runner ${REL_IMAGE_OS:-?} ${REL_IMAGE_VERSION:-?} with cl.exe ${REL_MSVC}"
    if [[ -n "$REL_IMAGE_OS$REL_IMAGE_VERSION" ]]; then
        ws_warn "build-info.json records GitHub's runner image; this build cannot reproduce that (see Warnings)"
        SIG_WARNINGS+=$'\n'"- UPSTREAM LEAK: build-info.json, inside both Windows files, records GitHub's runner image (runnerImage ${REL_IMAGE_OS}, runnerImageVersion ${REL_IMAGE_VERSION}) from \$env:ImageOS/\$env:ImageVersion. Only GitHub's runner sets them and this script does not fake them, so no build elsewhere can match that file. Upstream should drop these fields or make them settable."
    fi
}

# SHA256SUMS signed by the pinned key; a signed manifest that disagrees is fatal (no verdict).
verify_official_signature() {
    local base="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}" out a listed signed=false
    echo ""; ws_info "Verifying release manifest signature (gpg in a container)..."
    if ! gh_wget "${WORK_DIR}/SHA256SUMS" "${base}/SHA256SUMS" || ! gh_wget "${WORK_DIR}/SHA256SUMS.asc" "${base}/SHA256SUMS.asc"; then
        SIG_MANIFEST_STATUS="[WARNING] SHA256SUMS or SHA256SUMS.asc not published"
        SIG_WARNINGS+=$'\n- No signed manifest was retrievable; digests not cross-checked.'
        return 0
    fi
    mkdir -p "${WORK_DIR}/gnupg"; chmod 700 "${WORK_DIR}/gnupg"
    if GITHUB_TOKEN="" tools_c wget -q -T 60 -O release-key.asc \
            "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${NUNCHUK_RELEASE_KEY_FPR}" 2>/dev/null \
            && gpg_c --batch --quiet --import /w/release-key.asc >/dev/null 2>&1; then
        out="$(gpg_c --batch --status-fd 1 --verify /w/SHA256SUMS.asc /w/SHA256SUMS 2>/dev/null || true)"
        if grep -q "^\[GNUPG:\] GOODSIG " <<<"$out" \
                && grep -qE "^\[GNUPG:\] VALIDSIG .*${NUNCHUK_RELEASE_KEY_FPR}\$" <<<"$out"; then
            signed=true
            SIG_MANIFEST_STATUS="[OK] Good signature on SHA256SUMS from pinned key ${NUNCHUK_RELEASE_KEY_FPR}"
            ws_ok "Good signature on SHA256SUMS from the pinned release key"
        else
            SIG_MANIFEST_STATUS="[WARNING] No valid signature from ${NUNCHUK_RELEASE_KEY_FPR} on SHA256SUMS"
            SIG_WARNINGS+=$'\n- gpg reported no valid signature from the pinned key over the release manifest.'
        fi
    else
        SIG_MANIFEST_STATUS="[WARNING] Release key ${NUNCHUK_RELEASE_KEY_FPR} could not be retrieved"
        SIG_WARNINGS+=$'\n- The pinned release key could not be fetched; signature not verified.'
    fi
    SIG_DIGEST_STATUS="[OK] Measured digests match the signed manifest"
    for a in "${ARTIFACTS[@]}"; do
        listed="$(awk -v n="${OFF_NAME[$a]}" '$2 == n || $2 == "*" n {print $1}' "${WORK_DIR}/SHA256SUMS")"
        if [[ "${listed,,}" == "${OFF_SHA[$a]}" ]]; then continue; fi
        [[ "$signed" == true ]] && die_provenance "${OFF_NAME[$a]} is missing from, or does not match, the signed SHA256SUMS"
        SIG_WARNINGS+=$'\n'"- ${OFF_NAME[$a]} does not match the (unverified) manifest entry."
    done
    [[ "$signed" == true ]] || SIG_DIGEST_STATUS="[WARNING] Digests checked only against an unverified manifest"
}

resolve_commit() {
    local out
    out="$(ws_ctr run --rm "$GIT_IMAGE" ls-remote "https://github.com/${GH_REPO}.git" \
        "refs/tags/${APP_VERSION}^{}" "refs/tags/${APP_VERSION}" 2>/dev/null || true)"
    RESOLVED_COMMIT="$(printf '%s\n' "$out" | awk 'END{print $1}')"
    [[ "$RESOLVED_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
        || ws_no_verdict "Could not resolve tag ${APP_VERSION} to a commit; refusing to attribute a build to it"
    ws_ok "Tag ${APP_VERSION} = commit ${RESOLVED_COMMIT}"
}

# ssh/scp from a helper container on the host network; the VM port listens on 127.0.0.1 only.
# The VM is per-run and local, so its host key is not pinned.
SSH_OPTS=(-i /k -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o ConnectTimeout=15)
# SSH_NAME (optional) names the helper container, so the EXIT trap can remove it.
vm_ssh() {
    local n=(); [[ -n "${SSH_NAME:-}" ]] && n=(--name "$SSH_NAME")
    ws_ctr run --rm -i "${n[@]}" --network host -v "${WORK_DIR}/vm/key:/k:ro" --entrypoint ssh \
        "$GIT_IMAGE" "${SSH_OPTS[@]}" -p "$VM_PORT" Docker@127.0.0.1 "$@"
}
# A failed copy is an ftbfs, except while diffing a known mismatch (COPY_SOFT=true):
# then it only warns, so the verdict stays not_reproducible.
COPY_SOFT=false
copy_fail() { [[ "$COPY_SOFT" == true ]] && { ws_warn "$1"; return 1; }; ws_no_verdict "$1"; }
# Copy a host file into the VM, then check its sha256 inside Windows.
vm_push() {
    local src="$1" dst="$2" got
    ws_ctr run --rm --network host -v "${WORK_DIR}/vm/key:/k:ro" -v "${src}:/f:ro" --entrypoint scp \
        "$GIT_IMAGE" "${SSH_OPTS[@]}" -P "$VM_PORT" /f "Docker@127.0.0.1:${dst//\\//}" > /dev/null 2>&1 \
        || ws_ctr run --rm --network host -v "${WORK_DIR}/vm/key:/k:ro" -v "${src}:/f:ro" --entrypoint scp \
            "$GIT_IMAGE" -O "${SSH_OPTS[@]}" -P "$VM_PORT" /f "Docker@127.0.0.1:${dst//\\//}" > /dev/null \
        || { copy_fail "Could not copy $(basename "$src") into the VM"; return 1; }
    got="$(vm_ssh "powershell -NoProfile -Command (Get-FileHash '${dst}').Hash" | tr -d '\r\n' | tr 'A-F' 'a-f')"
    [[ "$got" == "$(ws_sha256 "$src")" ]] || { copy_fail "Copy of $(basename "$src") into the VM is corrupt"; return 1; }
}
# Stream a VM file out over SSH, then check it against Get-FileHash inside Windows.
vm_pull() {
    local src="$1" dst="$2" want
    vm_ssh "powershell -NoProfile -Command \"\$f=[IO.File]::OpenRead('${src}');\$f.CopyTo([Console]::OpenStandardOutput());\$f.Close()\"" > "$dst" \
        || { copy_fail "Could not copy ${src} out of the VM"; return 1; }
    want="$(vm_ssh "powershell -NoProfile -Command (Get-FileHash '${src}').Hash" | tr -d '\r\n' | tr 'A-F' 'a-f')"
    [[ "$want" == "$(ws_sha256 "$dst")" ]] || { copy_fail "Copy of ${src} out of the VM is corrupt"; return 1; }
}

start_vm() {
    local s
    VM_NAME="nunchukwin-$(date +%s)-$$"
    install -m 600 "$VM_KEY" "${WORK_DIR}/vm/key"
    mkdir -p "${WORK_DIR}/vm/storage" "${WORK_DIR}/vm/storage2"
    # dockur state files (windows.boot = already installed; windows.vars must be writable).
    cp "${GOLDEN_DIR}"/storage/windows.* "${WORK_DIR}/vm/storage/"
    chmod u+w "${WORK_DIR}"/vm/storage/windows.*
    local extra=(); [[ "$WS_ENGINE" == podman ]] && extra=(--group-add keep-groups)
    # Copy-on-write overlays; the golden disks are only ever opened read-only.
    for s in "storage/data.qcow2:/golden" "storage2/data2.qcow2:/golden2"; do
        local disk="${s%%:*}" mnt="${s#*:}"
        ws_ctr run --rm "${extra[@]}" --entrypoint qemu-img \
            -v "${GOLDEN_DIR}/storage:/golden:ro" -v "${GOLDEN_DIR}/storage2:/golden2:ro" -v "${WORK_DIR}/vm:/vm" \
            "$WIN_IMAGE" create -q -f qcow2 -F qcow2 -b "${mnt}/${disk##*/}" "/vm/${disk}" \
            || ws_no_verdict "Could not create the qcow2 overlay for ${disk}"
    done
    ws_info "Starting Windows VM ${VM_NAME} (RAM ${VM_RAM}, 4 cores)..."
    ws_ctr run -d --name "$VM_NAME" "${extra[@]}" \
        -e VERSION=2022 -e RAM_SIZE="$VM_RAM" -e CPU_CORES=4 -e DISK_SIZE=64G -e DISK2_SIZE=32G -e DISK_FMT=qcow2 \
        -v "${WORK_DIR}/vm/storage:/storage" -v "${WORK_DIR}/vm/storage2:/storage2" \
        -v "${GOLDEN_DIR}/storage:/golden:ro" -v "${GOLDEN_DIR}/storage2:/golden2:ro" \
        -p 127.0.0.1::22 --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --stop-timeout 120 \
        "$WIN_IMAGE" > /dev/null || ws_no_verdict "Could not start the Windows VM container"
    VM_PORT="$(ws_ctr port "$VM_NAME" 22/tcp | head -1)"; VM_PORT="${VM_PORT##*:}"
    [[ "$VM_PORT" =~ ^[0-9]+$ ]] || ws_no_verdict "Could not read the VM's SSH port"
    for _ in $(seq 1 90); do
        vm_ssh "type C:\\OEM\\done.txt" > /dev/null 2>&1 && { ws_ok "Windows is up (SSH on 127.0.0.1:${VM_PORT})"; phase_done "VM boot"; return 0; }
        ws_ctr ps -q --filter "name=${VM_NAME}" | grep -q . || ws_no_verdict "The VM container exited during boot"
        sleep 10
    done
    ws_no_verdict "Windows did not answer over SSH within 15 min"
}

# Runs inside Windows. Starts under PowerShell 5.1, installs pwsh 7 if needed, then re-runs itself
# under pwsh (whose native stderr does not trip -ErrorAction Stop).
write_vm_script() {
    cat > "${WORK_DIR}/nw.ps1" << 'PS1'
param([string]$Phase, [string]$Tag = 'x', [string]$Commit = 'x', [string]$Arg1 = 'x', [string]$Arg2 = 'x', [string]$Arg3 = 'x')
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$T = 'C:\tools'
function Need($ok, $what) { if (-not $ok) { throw "Toolchain check failed: $what" } }
function Get-Pinned($url, $sha) {
    New-Item -ItemType Directory -Force C:\nw\dl | Out-Null
    $p = Join-Path C:\nw\dl ($url -split '/')[-1]
    Write-Host "Downloading $url"
    Invoke-WebRequest -UseBasicParsing $url -OutFile $p
    if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $sha.ToUpper()) { throw "sha256 mismatch: $url" }
    $p
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (!(Test-Path "$T\pwsh\pwsh.exe")) {
        Expand-Archive (Get-Pinned 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip' '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860') "$T\pwsh"
    }
    & "$T\pwsh\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Phase $Phase -Tag $Tag -Commit $Commit -Arg1 $Arg1 -Arg2 $Arg2 -Arg3 $Arg3
    exit $LASTEXITCODE
}
function Run($exe) { & $exe @args; if ($LASTEXITCODE) { throw "$exe failed with exit code $LASTEXITCODE" } }

function Lap($name) { Write-Host ("NW-TIME {0}: {1} min {2} s" -f $name, [int][math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds); $sw.Restart() }
# A tool already present (e.g. baked into a later golden image) is used only at the exact version.
function Present($exe, $want, [scriptblock]$ver) {
    if (!(Test-Path $exe)) { return $false }
    $got = & $ver; Need ($got -eq $want) "$exe is $got, want $want"; $true
}
if ($Phase -eq 'build') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    tzutil /s UTC
    # GitHub's runner enables long paths; vcpkg buildtrees can pass 260 chars (overlay only).
    Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1
    try { Add-MpPreference -ExclusionPath 'C:\nunchuk-repro', 'D:\a'; Set-MpPreference -DisableRealtimeMonitoring $true }
    catch { Write-Warning "Defender not configured (continuing): $_" }
    # Missing tools: install per run (option a); present (option b image): only asserted below.
    $py = "$T\Python312"
    if (!(Present "$py\python.exe" 'Python 3.12.10' { & "$py\python.exe" --version })) {
        $p = Start-Process (Get-Pinned 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' '67b5635e80ea51072b87941312d00ec8927c4db9ba18938f7ad2d27b328b95fb') -Wait -PassThru `
            -ArgumentList '/quiet', 'InstallAllUsers=1', "TargetDir=$py", 'PrependPath=0', 'Include_test=0', 'Include_launcher=0', 'Shortcuts=0'
        Need ($p.ExitCode -eq 0) "Python installer exit code $($p.ExitCode)"
    }
    if (!(Present "$T\nasm-3.02\nasm.exe" 'NASM version 3.02' { (& "$T\nasm-3.02\nasm.exe" -v) -replace ' compiled.*' })) {
        Expand-Archive (Get-Pinned 'https://www.nasm.us/pub/nasm/releasebuilds/3.02/win64/nasm-3.02-win64.zip' '161d0bfaff53c2f9e9f3e69fd0672323ebabafd1268976a5cec11be92a19aee7') $T
    }
    if (!(Present 'C:\Strawberry\perl\bin\perl.exe' 'v5.32.1' { & C:\Strawberry\perl\bin\perl.exe -e 'print $^V' })) {
        Expand-Archive (Get-Pinned 'https://strawberryperl.com/download/5.32.1.1/strawberry-perl-5.32.1.1-64bit-portable.zip' '692646105b0f5e058198a852dc52a48f1cebcaf676d63bbdeae12f4eaee9bf5c') 'C:\Strawberry'
    }
    $vsw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    # VS with the release's cl.exe: download id, bootstrapper/installer sha256, vswhere range. Without
    # --offline the bootstrapper takes the newest installer (VS 2026 since 2026-11-11): exit 5008.
    $vs = @{ '19.44.35229.0' = 'bc92e2cb-33de-4a0c-995d-efa817f16b16', '37bb0fb429d163ecebd272a865d11a37b906d152bef960da2ddb29c2e2fd6eeb', 'E7A630D8BBE402A3A221F7D6ECFDC2A21A1711BCE7ED933FB1A8999C8D5C565C', '[17.14.37710,17.14.37711)'
        '19.44.35230.0' = '95995f57-8355-4ff5-8d90-a7e1669fb3b3', '310c13b8238876afb4e823a91112230ee2d2c5a45c431d4062af7aadedff9c4c', 'F5C892222A82F790498BFFFB69092EC14506FA8E9B8465033386CB2F30E17C0A', '[17.14.37906,17.14.37907)' }[$Arg3]
    Need $vs "no VS Build Tools pinned for cl.exe $Arg3"
    $dl = "https://download.visualstudio.microsoft.com/download/pr/$($vs[0])"
    function VsPath { if (Test-Path $vsw) { & $vsw -products * -version $vs[3] -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CoreBuildTools Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath | Select-Object -First 1 } }
    if (!(VsPath)) {
        $opc = Get-Pinned "$dl/$($vs[2])/vs_installer.opc" $vs[2]
        $p = Start-Process (Get-Pinned "$dl/$($vs[1])/vs_BuildTools.exe" $vs[1]) -Wait -PassThru `
            -ArgumentList '--quiet', '--wait', '--norestart', '--nocache', '--offline', $opc, '--add', 'Microsoft.VisualStudio.Workload.VCTools', `
            '--add', 'Microsoft.VisualStudio.Component.VC.CoreBuildTools', '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', `
            '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project', `
            '--add', 'Microsoft.VisualStudio.Component.VC.Redist.14.Latest', '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621', `
            '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100', '--add', 'Microsoft.VisualStudio.Component.Windows10SDK.19041'
        Need ($p.ExitCode -in 0, 3010) "VS Build Tools installer exit code $($p.ExitCode)"
        # Ports built with MSBuild (sqlite3) need the C++ build targets, not only cl.exe.
        Need (VsPath) "VS Build Tools installed without the VC.CoreBuildTools / VC.CMake.Project components"
    }
    # Same layering as the runner: msvc-dev-cmd's vcvars, then Python and NASM, Strawberry Perl last.
    $env:Path = "$py;$py\Scripts;$T\nasm-3.02;$env:Path;C:\Strawberry\c\bin;C:\Strawberry\perl\site\bin;C:\Strawberry\perl\bin"
    # vcpkg ports take PATH from the registry: without pip's ninja there (VCPKG_FORCE_SYSTEM_BINARIES) they
    # fall back to MSBuild and sqlite3 fails (RC2135 sqlite370.ico). The runner has these on the machine PATH.
    $need = @($py, "$py\Scripts", "$T\nasm-3.02", 'C:\Strawberry\c\bin', 'C:\Strawberry\perl\site\bin', 'C:\Strawberry\perl\bin')
    $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $add = $need | Where-Object { ($mp -split ';') -notcontains $_ }
    if ($add) { [Environment]::SetEnvironmentVariable('Path', (@($mp.TrimEnd(';')) + $add) -join ';', 'Machine') }
    $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($d in $need) { Need (($mp -split ';') -contains $d) "machine PATH lacks $d" }
    # vcvarsall gives each vcpkg port VS's bundled Ninja (VC.CMake.Project); same MSBuild fallback otherwise.
    Need (Test-Path "$(VsPath)\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe") "VS bundled ninja.exe missing (VC.CMake.Project)"
    Set-Content C:\nw\env.cmd "@call `"$(VsPath)\VC\Auxiliary\Build\vcvarsall.bat`" x64 10.0.22621.0 -vcvars_ver=14.44.35207 >nul`r`n@set" -Encoding ascii
    cmd /c C:\nw\env.cmd | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) } }
    $cl = (Get-Command cl.exe).Source
    $crt = Join-Path "$env:VCToolsRedistDir" 'x64\Microsoft.VC143.CRT\msvcp140.dll'
    Need ("$env:VCToolsVersion".TrimEnd('\') -eq '14.44.35207') "VCToolsVersion '$env:VCToolsVersion', want 14.44.35207"
    Need ("$env:WindowsSDKVersion".TrimEnd('\') -eq '10.0.22621.0') "WindowsSDKVersion '$env:WindowsSDKVersion', want 10.0.22621.0"
    Need ((Get-Item $cl).VersionInfo.FileVersion -eq $Arg3) "cl.exe $((Get-Item $cl).VersionInfo.FileVersion), release used $Arg3"
    Need ((Test-Path $crt) -and (Get-Item $crt).VersionInfo.FileVersion -eq '14.44.35211.0') "redist msvcp140.dll, want 14.44.35211.0"
    Need ($PSVersionTable.PSVersion.ToString() -eq '7.6.6') "pwsh $($PSVersionTable.PSVersion), want 7.6.6"
    Need ((& python --version) -eq 'Python 3.12.10') "python $(& python --version), want 3.12.10"
    Need ((& nasm -v) -match '^NASM version 3\.02 ') "nasm $(& nasm -v), want 3.02"
    Need ((& perl -e 'print $^V') -eq 'v5.32.1') "perl $(& perl -e 'print $^V'), want v5.32.1"
    # windeployqt copies these; MSI keeps the highest version of SDKs 19041/22621/26100, as on the runner.
    $d3d = "${env:ProgramFiles(x86)}\Windows Kits\10\Redist\D3D\x64"
    $d3dv = foreach ($n in 'd3dcompiler_47.dll', 'dxcompiler.dll', 'dxil.dll') { if (Test-Path "$d3d\$n") { "$n $((Get-Item "$d3d\$n").VersionInfo.FileVersion)" } else { "$n missing" } }
    Write-Host "D3D redist: $($d3dv -join ', ')"
    Need (-not ($d3dv -like '* missing')) "D3D redist incomplete ($($d3dv -join ', '))"
    Need ((Get-Item "$d3d\dxcompiler.dll").VersionInfo.FileVersion -like '10.0.19041.*') "dxcompiler.dll is not from SDK 10.0.19041 ($($d3dv[1]))"
    Need ((Get-Item "$d3d\d3dcompiler_47.dll").VersionInfo.FileVersion -like '10.0.26100.*') "d3dcompiler_47.dll is not from SDK 10.0.26100 ($($d3dv[0]))"
    Lap 'tool install'
    Write-Host "Toolchain: PASS (cl $Arg3, VCTools 14.44.35207, SDK 10.0.22621.0, D3D 26100/19041, CRT 14.44.35211.0, pwsh 7.6.6, Python 3.12.10, NASM 3.02, Perl 5.32.1)"

    # Checkout as in build-windows.yml, at the runner's workspace path.
    Run git config --global core.autocrlf false
    Run git config --global core.longpaths true
    Run git config --global core.symlinks false
    $src = 'D:\a\nunchuk-desktop\nunchuk-desktop'
    if (Test-Path $src) { Remove-Item -Recurse -Force $src }
    Run git clone --quiet --depth 1 --branch $Tag --recurse-submodules --shallow-submodules "https://github.com/nunchuk-io/nunchuk-desktop.git" $src
    $head = (git -C $src rev-parse HEAD).Trim()
    Need ($head -eq $Commit) "checkout HEAD $head is not tag commit $Commit"
    $epoch = [long](git -C $src show -s --format=%ct HEAD).Trim()
    # $env:ImageOS/$env:ImageVersion stay unset: only GitHub's runner has them (see Warnings).
    Set-Location $src
    # On failure, print the newest vcpkg/CMake logs: the VM (and every log in it) is deleted at exit.
    function FailLogs($what) {
        Write-Host "NW-FAIL ${what}: $_"
        Get-ChildItem C:\nunchuk-repro -Recurse -File -Include *-out.log, *-err.log, CMakeError.log, CMakeConfigureLog.yaml -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
                Write-Host "===== NW-FAILLOG $($_.FullName) (last 60 lines)"; Get-Content $_.FullName -Tail 60 }
    }
    try { & .\reproducible-builds\build_windows.ps1 -Replica a -ExpectedCommit $Commit -ReleaseVersion $Tag -SourceDateEpoch $epoch }
    catch { FailLogs 'build_windows.ps1'; throw }
    Lap 'build'
    try {
        & .\reproducible-builds\package_windows.ps1 -ExpectedCommit $Commit -ReleaseVersion $Tag -SourceDateEpoch $epoch `
            -ArtifactFlavor unsigned -ApplicationExe C:\nunchuk-repro\build-output\nunchuk-qt.exe `
            -BuildInfoFile C:\nunchuk-repro\build-output\build-info.json -TlsProbeExe C:\nunchuk-repro\build-output\qt-tls-probe.exe -SmokeTest
    } catch { FailLogs 'package_windows.ps1'; throw }
    Lap 'package'
    Write-Host "NW-BUILD-DONE epoch=$epoch"
}
elseif ($Phase -eq 'unpack') {
    # Arg1 = installer, Arg2 = manifest out. innoextract cannot read Inno 6.7, so install it silently.
    $d = "C:\nwcmp\$(Split-Path -LeafBase $Arg2)"
    $p = Start-Process $Arg1 -Wait -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', '/TASKS=', "/DIR=$d"
    Need ($p.ExitCode -eq 0) "silent install of $Arg1 exit code $($p.ExitCode)"
    Get-ChildItem $d -Recurse -File | Where-Object Name -notlike 'unins000.*' | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash $_.FullName).Hash.ToLower(), [IO.Path]::GetRelativePath($d, $_.FullName).Replace('\', '/')
    } | Set-Content $Arg2 -Encoding ascii
    Start-Process "$d\unins000.exe" -Wait -ArgumentList '/VERYSILENT', '/NORESTART' | Out-Null
    for ($i = 0; $i -lt 60 -and (Test-Path "$d\unins000.exe"); $i++) { Start-Sleep 2 }
}
PS1
}

run_build() {
    local a n
    ws_info "Copying the build driver into the VM..."
    vm_ssh "mkdir C:\\nw" > /dev/null 2>&1 || true
    vm_push "${WORK_DIR}/nw.ps1" 'C:\nw\nw.ps1'
    ws_info "Building inside Windows (toolchain, then upstream build_windows.ps1 + package_windows.ps1): about 2-3 h..."
    # In the background so INT/TERM run the trap now (it removes the VM), not after the build.
    SSH_HELPER="nunchukwin-ssh-$(date +%s)-$$"
    { SSH_NAME="$SSH_HELPER" vm_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\nw\\nw.ps1 -Phase build -Tag ${APP_VERSION} -Commit ${RESOLVED_COMMIT} -Arg3 ${REL_MSVC}" < /dev/null 2>&1 \
        | tr -d '\r' | tee "${WORK_DIR}/build.log" || true; } &
    # A failed SSH session is judged from build.log below, not by the ERR trap.
    wait $! || true
    grep -q '^NW-BUILD-DONE' "${WORK_DIR}/build.log" || {
        # Toolchain not passed: no verdict. [^$] skips pwsh's echo of the throw.
        grep -q '^Toolchain: PASS' "${WORK_DIR}/build.log" \
            || ws_no_verdict "Windows toolchain setup failed (build.log in the workspace): $(grep -m1 -oE '(Toolchain check failed|sha256 mismatch): [^$].*' "${WORK_DIR}/build.log" | cut -c1-200)"
        # ftbfs only if an upstream step threw (NW-FAIL).
        grep -q '^NW-FAIL' "${WORK_DIR}/build.log" || ws_no_verdict "Build stopped with no upstream failure logged (SSH, VM or clone; build.log in the workspace)"
        die_build "Upstream Windows build failed: $(grep -m1 -o 'NW-FAIL .*' "${WORK_DIR}/build.log" | cut -c1-200) (log with vcpkg/CMake tails: build.log in the workspace)"
    }
    D3D_REDIST="$(sed -nE 's/^D3D redist: (.*)$/\1/p' "${WORK_DIR}/build.log" | head -1)"
    SOURCE_EPOCH="$(sed -nE 's/^NW-BUILD-DONE epoch=([0-9]+).*/\1/p' "${WORK_DIR}/build.log")"
    # A skipped upstream step can invalidate a verdict: surface such lines, don't judge them.
    grep -nE 'SKIP|Skipping' "${WORK_DIR}/build.log" > "${WORK_DIR}/skip_lines.txt" || true
    if [[ -s "${WORK_DIR}/skip_lines.txt" ]]; then
        n="$(wc -l < "${WORK_DIR}/skip_lines.txt")"
        ws_warn "${n} build log lines mention SKIP/Skipping (first 5; all in skip_lines.txt):"
        head -n 5 "${WORK_DIR}/skip_lines.txt"
        SIG_WARNINGS+=$'\n'"- ${n} build log lines mention SKIP/Skipping; review skip_lines.txt in the workspace."
    fi
    # Phases inside Windows, timed there (one SSH session runs them all).
    PHASE_TIMES+="$(sed -nE 's/^NW-TIME (.*)$/\1/p' "${WORK_DIR}/build.log")"$'\n'
    PHASE_T0=$SECONDS
    for a in "${ARTIFACTS[@]}"; do
        ws_info "Copying $(built_name "$a") out of the VM..."
        vm_pull "C:\\nunchuk-repro\\artifacts\\$(built_name "$a")" "${WORK_DIR}/built/${OFF_NAME[$a]}"
        BUILT_SHA[$a]="$(ws_sha256 "${WORK_DIR}/built/${OFF_NAME[$a]}")"
        ws_ok "Rebuilt ${OFF_NAME[$a]} sha256 ${BUILT_SHA[$a]}"
    done
    phase_done "copy-out"
}

# Differing entries between the "sha256  path" manifests m-official and m-built.
diff_manifests() {
    local d="$1" n
    # shellcheck disable=SC2016
    tools_c sh -c 'cd "$1" && awk "NR==FNR {o[substr(\$0,67)]=\$1; next} {b[substr(\$0,67)]=\$1}
        END {for (k in o) if (!(k in b)) print k, o[k], \"MISSING\"; else if (o[k] != b[k]) print k, o[k], b[k]
             for (k in b) if (!(k in o)) print k, \"MISSING\", b[k]}" m-official m-built | sort > differing.txt' sh "$d" \
        || return 1
    n="$(wc -l < "${WORK_DIR}/${d}/differing.txt")"
    DIFF_NOTE[$2]="${n} of $(wc -l < "${WORK_DIR}/${d}/m-official") files differ (path, official sha256, rebuilt sha256 in ${d}/differing.txt)"
    ws_warn "${DIFF_NOTE[$2]}"; head -n 5 "${WORK_DIR}/${d}/differing.txt"
}

compare_artifacts() {
    local a all=true
    echo ""; echo "======================================================"
    echo "ARTIFACT COMPARISON (byte for byte)"; echo "======================================================"
    for a in "${ARTIFACTS[@]}"; do
        echo "${OFF_NAME[$a]}"; echo "  official ${OFF_SHA[$a]}"; echo "  rebuilt  ${BUILT_SHA[$a]}"
        if [[ "${OFF_SHA[$a]}" == "${BUILT_SHA[$a]}" ]]; then
            ws_ok "${OFF_NAME[$a]} is byte-for-byte IDENTICAL"; continue
        fi
        all=false
        ws_warn "${OFF_NAME[$a]} differs; unpacking both to diff file by file..."
        mkdir -p "${WORK_DIR}/diff-${a}"
        if [[ "$a" == portable ]]; then
            # shellcheck disable=SC2016
            tools_c sh -c 'cd "$1" && for n in official built; do
                    mkdir -p "$n" && unzip -q -o "../$n/$2" -d "$n" && (cd "$n" && find . -type f -exec sha256sum {} + | sed "s#  \./#  #") > "m-$n"
                done' sh "diff-${a}" "${OFF_NAME[$a]}" && diff_manifests "diff-${a}" "$a" \
                || DIFF_NOTE[$a]="the ZIPs could not be unpacked"
        else
            COPY_SOFT=true
            if vm_push "${WORK_DIR}/official/${OFF_NAME[$a]}" 'C:\nw\official-setup.exe' \
                && vm_ssh "C:\\tools\\pwsh\\pwsh.exe -NoProfile -File C:\\nw\\nw.ps1 -Phase unpack -Arg1 C:\\nw\\official-setup.exe -Arg2 C:\\nw\\m-official.txt" \
                && vm_ssh "C:\\tools\\pwsh\\pwsh.exe -NoProfile -File C:\\nw\\nw.ps1 -Phase unpack -Arg1 C:\\nunchuk-repro\\artifacts\\$(built_name "$a") -Arg2 C:\\nw\\m-built.txt"; then
                if vm_pull 'C:\nw\m-official.txt' "${WORK_DIR}/diff-${a}/m-official" \
                    && vm_pull 'C:\nw\m-built.txt' "${WORK_DIR}/diff-${a}/m-built"; then
                    sed -i 's/\r$//' "${WORK_DIR}/diff-${a}"/m-*
                    diff_manifests "diff-${a}" "$a" || DIFF_NOTE[$a]="the installed trees could not be compared"
                else
                    DIFF_NOTE[$a]="the installed file lists could not be copied out of the VM"
                fi
            else
                DIFF_NOTE[$a]="the installers could not be copied into or installed in the VM to diff their contents"
            fi
            COPY_SOFT=false
        fi
    done
    phase_done "compare"
    local ctx="Built in a Windows Server 2022 VM (${WIN_IMAGE##*@}) with upstream build_windows.ps1 and package_windows.ps1 at tag ${APP_VERSION}, commit ${RESOLVED_COMMIT}, SOURCE_DATE_EPOCH ${SOURCE_EPOCH}; MSVC 14.44.35207 (cl ${REL_MSVC}), SDK 10.0.22621.0 (SDKs 19041, 26100 also installed; D3D redist ${D3D_REDIST:-not logged}), VS ${VS_REL}; ImageOS/ImageVersion not set: build-info.json records GitHub's runner image (${REL_IMAGE_OS:-none}/${REL_IMAGE_VERSION:-none} in the release), which only GitHub can match (upstream leak)."
    local sums="" a2
    for a2 in "${ARTIFACTS[@]}"; do sums+="${OFF_NAME[$a2]}: official ${OFF_SHA[$a2]}, rebuilt ${BUILT_SHA[$a2]}${DIFF_NOTE[$a2]:+ (${DIFF_NOTE[$a2]})}; "; done
    if [[ "$all" == true ]]; then
        ws_write_yaml "reproducible" "Every compared file is byte-for-byte identical. ${sums}${ctx}"
        return 0
    fi
    ws_write_yaml "not_reproducible" "Rebuilt files differ from the release. ${sums}${ctx}"
    return 1
}

emit_verification_summary() {
    local verdict a
    verdict="$(awk '/^verdict:/{print $2}' "${WS_RESULTS_FILE}" 2>/dev/null)"
    echo ""
    echo "HASH LEGEND"
    echo "  appHash     sha256 of the official file as distributed (first compared file; Diff gives the rebuilt one)."
    echo "  scriptHash  sha256 of this script; libHash of the ws-rb-core library it loaded."
    echo ""
    local d=""
    for a in "${ARTIFACTS[@]}"; do
        if [[ "${OFF_SHA[$a]}" == "${BUILT_SHA[$a]}" ]]; then d+="${OFF_NAME[$a]}: identical (${OFF_SHA[$a]})"$'\n'
        else d+="${OFF_NAME[$a]}: official ${OFF_SHA[$a]}, rebuilt ${BUILT_SHA[$a]:-N/A}"$'\n'"  ${DIFF_NOTE[$a]:-not diffed}"$'\n'; fi
    done
    d+=$'\n'"Revision, tag (and its signature):"$'\n'"tag:            ${APP_VERSION}"$'\n'"commit:         ${RESOLVED_COMMIT}"$'\n\n'
    d+="Signature Summary:"$'\n'"${SIG_MANIFEST_STATUS}"$'\n'"${SIG_DIGEST_STATUS}"$'\n'
    d+="[WARNING] Tag signature not checked by this script"$'\n'"[WARNING] Commit signature not checked by this script"$'\n\n'"Keys used:"$'\n'
    if [[ "$SIG_MANIFEST_STATUS" == "[OK]"* ]]; then d+="Manifest signed with: ${NUNCHUK_RELEASE_KEY_FPR}"; else d+="None established"; fi
    d+=$'\n\n'"Warnings:${SIG_WARNINGS:-}"
    a="${ARTIFACTS[0]}"
    ws_results_block "$APP_ID" N/A "$APP_VERSION" N/A "$verdict" "${OFF_SHA[$a]:-N/A}" "$RESOLVED_COMMIT" "$d"
    echo ""
    echo "Build environment:"
    echo "VM image:       ${WIN_IMAGE}"
    echo "golden image:   ${GOLDEN_DIR}"
    echo "release runner: ${REL_IMAGE_OS:-?} ${REL_IMAGE_VERSION:-?}, cl.exe ${REL_MSVC} (runner fields not reproduced, see Warnings)"
    echo "toolchain:      VS Build Tools ${VS_REL}, MSVC 14.44.35207, SDK 10.0.22621.0, pwsh 7.6.6, Python 3.12.10, NASM 3.02, Strawberry Perl 5.32.1.1"
    echo "D3D redist:     ${D3D_REDIST:-not logged}"
    echo "                cl.exe is checked against build-info.json; Python, NASM and Perl against upstream's CI logs"
    echo "                (runs 38044363978, 40099229609, 41083969010, 43581994636 for 2.9.1 to 2.9.4) and runner toolsets."
    [[ "$APP_VERSION" == 2.9.[1-4] ]] || echo "[WARNING] Toolchain versions were confirmed for 2.9.1 to 2.9.4 only; check them against this release's CI run"
    echo ""
    echo "Elapsed time per phase:"
    printf '%s' "$PHASE_TIMES"
    echo ""
    echo "Limitations:"
    echo "- pip resolves aqtinstall's and py7zr's dependencies at run time (upstream pins only aqtinstall, py7zr, ninja)."
    echo "- VS Build Tools payloads are checked only by the VS installer against Microsoft's signed manifest;"
    echo "  the script checks the bootstrapper's and installer's sha256 and asserts the resulting cl/CRT/SDK versions."
    echo "- Qt (aqt from download.qt.io) and vcpkg sources are verified by those tools, not by this script."
    echo "- Built under user Docker, time zone set to UTC; the release was built as runneradmin on GitHub's runner."
    echo "- The bundled hwi.exe is a prebuilt download pinned by sha256 in windows-dependencies.lock.json, not built from source."
    echo ""
}

main() {
    echo ""; echo "======================================================"
    echo "${APP_NAME} Reproducible Build Verifier ${SCRIPT_VERSION}"
    echo "======================================================"; echo ""
    ws_refuse_root
    ws_install_traps
    parse_args "$@"
    ws_results_init
    ws_engine
    # Rootless: container root is the caller. Otherwise the tools run as the caller.
    is_rootless || TOOLS_USER=(--user "$(id -u):$(id -g)")
    WS_CHOWN_IMAGE="$GIT_IMAGE"
    check_prereqs
    setup_workdir
    ws_info "Version: ${APP_VERSION}  Arch: ${APP_ARCH}  Type: ${APP_TYPE}"

    prepare_official
    verify_official_signature
    resolve_commit
    write_vm_script
    PHASE_T0=$SECONDS
    start_vm
    run_build

    local verdict_exit=0
    compare_artifacts || verdict_exit=$?
    ws_ctr rm -f "$VM_NAME" > /dev/null 2>&1 && VM_NAME=""

    emit_verification_summary
    echo ""
    echo "======================================================"
    echo "RESULTS (machine-readable verdict in COMPARISON_RESULTS.yaml)"
    echo "======================================================"
    cat "${WS_RESULTS_FILE}"
    echo ""
    echo "Work directory: ${WORK_DIR}"
    echo "Rebuilt artifacts: ${WORK_DIR}/built/"
    echo "======================================================"
    exit "$verdict_exit"
}

main "$@"
