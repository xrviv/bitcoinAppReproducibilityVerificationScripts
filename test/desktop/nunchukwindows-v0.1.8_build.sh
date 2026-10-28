#!/bin/bash
#
# nunchukwindows_build.sh - Nunchuk Desktop Windows Reproducible Build Verifier
# Version: v0.1.8
# Last modified by: Danny Garcia, Carol (Buzz), Claude Code
# Last modified on: 2026-10-21
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
# Usage: nunchukwindows_build.sh --version VERSION [--binary FILE|DIR] [--arch x86_64-windows] [--type setup|portable] [--golden DIR]
# One verdict per run, for the file --type selects. Host needs podman (or docker), /dev/kvm, and read access to the golden image and VM key.
#

set -euo pipefail

SCRIPT_VERSION="v0.1.8"
APP_ID="nunchuk"
APP_NAME="Nunchuk Desktop (Windows)"
GH_REPO="nunchuk-io/nunchuk-desktop"
MIN_VERSION="2.9.1"

EXIT_OK=0
EXIT_DIFF=1
EXIT_INVALID=2

APP_VERSION=""
APP_ARCH="x86_64-windows"
APP_TYPE="setup"
BINARY_PATH=""
CONTAINER_CMD=""
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
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
VERDICT_WRITTEN=false
NO_VERDICT_BY_DESIGN=false
RESOLVED_COMMIT="unknown"
SOURCE_EPOCH=""
PHASE_TIMES=""
# Elapsed time of a phase, for the results block.
phase_done() { PHASE_TIMES+="${1}: $(( (SECONDS - PHASE_T0) / 60 )) min $(( (SECONDS - PHASE_T0) % 60 )) s"$'\n'; PHASE_T0=$SECONDS; }
PHASE_T0=0

# Runner identity and compiler of the release, read from build-info.json in the official ZIP.
# build-info.json ships in both artifacts and records $env:ImageOS/$env:ImageVersion verbatim.
# Only GitHub's runner sets those two; this script does not fake them (Danny, 2026-10-21), so a
# release that records them cannot match. The run says so under Warnings.
REL_IMAGE_OS=""
REL_IMAGE_VERSION=""
REL_MSVC=""

NUNCHUK_RELEASE_KEY_FPR="8C8ECD3F660CA53CD878792A6E38A462ED2EF525"
SIG_MANIFEST_STATUS="[WARNING] Manifest signature not checked"
SIG_DIGEST_STATUS="[WARNING] Digests not checked against a signed manifest"
SIG_WARNINGS=""

# Per artifact (setup, portable): release name, official / rebuilt sha256, diff summary.
declare -A OFF_NAME OFF_SHA BUILT_SHA DIFF_NOTE
ARTIFACTS=()

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die_invalid() { log_error "$1"; write_yaml "ftbfs" "$1"; exit "${EXIT_INVALID}"; }
die_build()   { log_error "$1"; write_yaml "ftbfs" "$1"; exit "${EXIT_DIFF}"; }
# Environment cannot run the build at all (no KVM, golden image missing/expired): no verdict.
die_prereq() {
    log_error "$1"
    NO_VERDICT_BY_DESIGN=true
    exit "${EXIT_INVALID}"
}
die_provenance() {
    log_error "PROVENANCE FAILURE: $1"
    log_error "No verdict is emitted: the artifact compared is not the file upstream signed."
    NO_VERDICT_BY_DESIGN=true
    rm -f "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    exit "${EXIT_DIFF}"
}

write_yaml() {
    local verdict="$1" notes="${2:-}" yaml_file="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    notes="${notes//\"/\'}"
    if [[ -n "$notes" ]]; then
        printf 'script_version: %s\nverdict: %s\nnotes: "%s"\n' "$SCRIPT_VERSION" "$verdict" "$notes" > "$yaml_file"
    else
        printf 'script_version: %s\nverdict: %s\n' "$SCRIPT_VERSION" "$verdict" > "$yaml_file"
    fi
    VERDICT_WRITTEN=true
    log_info "COMPARISON_RESULTS.yaml written to: $yaml_file"
}

# Tools (BusyBox wget/unzip/sha256sum, GnuPG, git, ssh) from the pinned git image, WORK_DIR at /w.
tools_c() {
    local tool="$1"; shift
    "$CONTAINER_CMD" run --rm "${TOOLS_USER[@]}" -e GITHUB_TOKEN -v "${WORK_DIR}:/w" -w /w \
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

sha256_of() { [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || echo "N/A"; }

is_rootless() {
    local r=""
    case "$CONTAINER_CMD" in
        podman) r="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" ;;
        docker) docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && r=true ;;
    esac
    [[ "$r" == "true" ]]
}

detect_container_cmd() {
    if command -v podman >/dev/null 2>&1; then CONTAINER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then CONTAINER_CMD="docker"
    else die_invalid "Neither podman nor docker found in PATH. Install one and retry."; fi
    is_rootless || TOOLS_USER=(--user "$(id -u):$(id -g)")
    log_info "Container runtime: ${CONTAINER_CMD}$(is_rootless && echo ' (rootless)')"
}

require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == --* ]]; then die_invalid "Missing value for parameter: $1"; fi
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --version VERSION [--binary FILE|DIR] [--arch ARCH] [--type setup|portable] [--golden DIR]"
        exit "${EXIT_INVALID}"
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) require_arg "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
            --binary)  require_arg "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --arch)    require_arg "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    require_arg "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --golden)  require_arg "$1" "${2:-}"; GOLDEN_DIR="$2"; shift 2 ;;
            --apk)
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi
                log_warn "--apk is not applicable for desktop builds (ignored)" ;;
            --help) show_help; exit 0 ;;
            *) log_warn "Unknown argument: $1 (ignored)"; shift ;;
        esac
    done
    [[ -n "$APP_VERSION" ]] || die_invalid "--version is required"
    # package_windows.ps1 accepts exactly X.Y.Z.
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die_invalid "Invalid --version '${APP_VERSION}' (expected e.g. 2.9.1, no v prefix)"
    [[ "$APP_ARCH" == "x86_64-windows" ]] \
        || die_invalid "Unsupported --arch '${APP_ARCH}'; only x86_64-windows is implemented"
    case "$APP_TYPE" in
        setup|portable) ARTIFACTS=("$APP_TYPE") ;;
        *) die_invalid "Unsupported --type '${APP_TYPE}'; use setup or portable" ;;
    esac
    if [[ "$(printf '%s\n' "$MIN_VERSION" "$APP_VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]]; then
        die_invalid "Version ${APP_VERSION} predates ${MIN_VERSION}, the first release with build_windows.ps1"
    fi
    if [[ -n "$BINARY_PATH" ]]; then
        [[ -e "$BINARY_PATH" ]] || die_invalid "--binary path does not exist: $BINARY_PATH"
        BINARY_PATH="$(realpath "$BINARY_PATH")"
        local pat m=() magic want
        [[ "$APP_TYPE" == setup ]] && { pat='*-x64-setup*.exe'; want=4d5a; } || { pat='*-x64-portable*.zip'; want=504b0304; }
        # ABS passes a directory when a submission has several files: take the one for --type.
        if [[ -d "$BINARY_PATH" ]]; then
            shopt -s nullglob
            # shellcheck disable=SC2206 # $pat is a glob on purpose
            m=("$BINARY_PATH"/$pat)
            shopt -u nullglob
            [[ ${#m[@]} -eq 1 ]] || die_invalid "--binary directory needs exactly one ${pat} file (found ${#m[@]})"
            BINARY_PATH="${m[0]}"
        fi
        # The installer is a PE file (MZ), the portable build a ZIP (PK\3\4).
        magic="$(head -c 4 "$BINARY_PATH" | od -An -tx1 | tr -d ' \n')"
        [[ "$magic" == "$want"* ]] || die_invalid "--binary is not a ${APP_TYPE} file (starts with ${magic:-nothing})"
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
  --golden DIR         Golden image folder (default: $WS_WINDOWS_GOLDEN or
                       /var/lib/walletscrutiny-windows/golden-2022)

OPTIONAL ENVIRONMENT:
  GITHUB_TOKEN         Used for GitHub downloads, to avoid rate limiting
  WS_WINDOWS_GOLDEN    Golden image folder (default /var/lib/walletscrutiny-windows/golden-2022)
  WS_WINDOWS_KEY       VM SSH key (default /var/lib/walletscrutiny-windows/vm-key/ws-windows-vm)
  WS_WINDOWS_RAM       VM memory (default 8G)

REQUIREMENTS:
  podman (or docker), read/write /dev/kvm, read access to the golden image and the VM key.
  Run as a normal user, not root. Tools missing from the golden image (VS Build Tools 17.14.41,
  pwsh 7.6.6, Python 3.12.10, NASM 3.02, Strawberry Perl 5.32.1.1) are installed per run,
  hash-checked; their versions are asserted either way.

EXIT CODES:
  0  Identical (the selected file is byte-for-byte equal)
  1  Differences found, or build failed
  2  Invalid parameters or missing prerequisites (no verdict for missing prerequisites)
  130  Interrupted (no verdict)

OUTPUT:
  COMPARISON_RESULTS.yaml  (in same directory as this script)
  $WORK_DIR/built/          (rebuilt artifacts)
EOF
}

setup_workdir() {
    local suffix="${APP_VERSION}_${APP_ARCH}_${APP_TYPE}" base
    base="$(pwd -P)"
    for _ in 1 2 3; do
        WORK_DIR="${base}/nunchukwin_verification_${suffix}_$(date +%s)-$$"
        if mkdir "$WORK_DIR" 2>/dev/null; then
            trap reclaim_workspace EXIT
            trap 'NO_VERDICT_BY_DESIGN=true; exit 130' INT TERM
            log_info "Work directory: $WORK_DIR"
            mkdir -p "$WORK_DIR"/{official,built,vm}
            return 0
        fi
        sleep 1
    done
    WORK_DIR=""
    die_build "Could not create a per-run workspace under ${base}"
}

# EXIT trap: remove the VM container, hand the workspace back, delete vm/ (overlays, key copy).
reclaim_workspace() {
    set +e
    if [[ "$VERDICT_WRITTEN" != true && "$NO_VERDICT_BY_DESIGN" != true ]]; then
        write_yaml "ftbfs" "Run ended before a verdict was written (internal error)"
    fi
    [[ -n "$VM_NAME" ]] && "$CONTAINER_CMD" rm -f "$VM_NAME" > /dev/null 2>&1
    [[ -n "$SSH_HELPER" ]] && "$CONTAINER_CMD" rm -f "$SSH_HELPER" > /dev/null 2>&1
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
    if [[ -n "$(find "$WORK_DIR" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]]; then
        local uid gid; uid="$(id -u)"; gid="$(id -g)"
        is_rootless && { uid=0; gid=0; }
        "$CONTAINER_CMD" run --rm -v "${WORK_DIR}:/w" --entrypoint chown "$GIT_IMAGE" -R "${uid}:${gid}" /w > /dev/null 2>&1 \
            || log_warn "Could not restore ownership of ${WORK_DIR}; deleting it may need 'podman unshare rm -rf'"
    fi
    chmod -R u+rwX "$WORK_DIR" > /dev/null 2>&1
    rm -rf "${WORK_DIR}/vm"
    [[ -z "$(find "$WORK_DIR" ! -uid "$(id -u)" -print -quit 2>/dev/null)" ]] \
        || log_warn "Workspace still has files not owned by uid $(id -u): ${WORK_DIR}"
    return 0
}

check_prereqs() {
    local f ends
    [[ -r /dev/kvm && -w /dev/kvm ]] || die_prereq "/dev/kvm is not readable and writable for $(id -un) (needs the kvm group)"
    [[ -e /dev/net/tun ]] || die_prereq "/dev/net/tun is missing"
    for f in storage/data.qcow2 storage2/data2.qcow2 storage/windows.boot GOLDEN-INFO.txt; do
        [[ -r "${GOLDEN_DIR}/${f}" ]] || die_prereq "Golden image file not readable: ${GOLDEN_DIR}/${f} (needs the windows-images group)"
    done
    [[ -r "$VM_KEY" ]] || die_prereq "VM SSH key not readable: ${VM_KEY}"
    ends="$(grep -oE 'evaluation ends ~?[0-9]{4}-[0-9]{2}-[0-9]{2}' "${GOLDEN_DIR}/GOLDEN-INFO.txt" | grep -oE '[0-9-]{10}' | head -1)"
    [[ -n "$ends" ]] || die_prereq "GOLDEN-INFO.txt has no 'evaluation ends YYYY-MM-DD' line"
    [[ "$(date -u +%F)" < "$ends" ]] || die_prereq "The golden image's Windows evaluation ended on ${ends}; rebuild it (#984 runbook)"
    log_ok "Prerequisites: /dev/kvm, golden image ${GOLDEN_DIR} (evaluation ends ${ends}), VM key"
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
                || log_warn "--binary is named $(basename "$BINARY_PATH"), expected ${OFF_NAME[$a]}; compared as ${OFF_NAME[$a]}"
            cp "$BINARY_PATH" "$dest"
        elif [[ "$a" == portable || " ${ARTIFACTS[*]} " == *" $a "* ]]; then
            url="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/${OFF_NAME[$a]}"
            log_info "Downloading official release: $url"
            gh_wget "$dest" "$url" || die_build "Failed to download: $url"
        else
            continue
        fi
        OFF_SHA[$a]="$(sha256_of "$dest")"
        log_ok "Official ${OFF_NAME[$a]} ($(stat -c%s "$dest") bytes) sha256 ${OFF_SHA[$a]}"
    done
    # shellcheck disable=SC2016
    tools_c sh -c 'unzip -p "$1" build-info.json > official/build-info.json' sh "official/${OFF_NAME[portable]}" \
        || die_build "The official portable ZIP has no build-info.json"
    REL_IMAGE_OS="$(sed -nE 's/.*"runnerImage": *"([^"]*)".*/\1/p' "${WORK_DIR}/official/build-info.json")"
    REL_IMAGE_VERSION="$(sed -nE 's/.*"runnerImageVersion": *"([^"]*)".*/\1/p' "${WORK_DIR}/official/build-info.json")"
    REL_MSVC="$(sed -nE 's/.*"msvcFileVersion": *"([^"]*)".*/\1/p' "${WORK_DIR}/official/build-info.json")"
    [[ "$REL_MSVC" =~ ^[0-9.]+$ ]] || die_build "Could not read msvcFileVersion from the official build-info.json"
    log_info "Release built on runner ${REL_IMAGE_OS:-?} ${REL_IMAGE_VERSION:-?} with cl.exe ${REL_MSVC}"
    if [[ -n "$REL_IMAGE_OS$REL_IMAGE_VERSION" ]]; then
        log_warn "build-info.json records GitHub's runner image; this build cannot reproduce that (see Warnings)"
        SIG_WARNINGS+=$'\n'"- UPSTREAM LEAK: build-info.json, inside both Windows files, records GitHub's runner image (runnerImage ${REL_IMAGE_OS}, runnerImageVersion ${REL_IMAGE_VERSION}) from \$env:ImageOS/\$env:ImageVersion. Only GitHub's runner sets them and this script does not fake them, so no build elsewhere can match that file. Upstream should drop these fields or make them settable."
    fi
}

# SHA256SUMS signed by the pinned key; a signed manifest that disagrees is fatal (no verdict).
verify_official_signature() {
    local base="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}" out a listed signed=false
    echo ""; log_info "Verifying release manifest signature (gpg in a container)..."
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
            log_ok "Good signature on SHA256SUMS from the pinned release key"
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
    out="$("$CONTAINER_CMD" run --rm "$GIT_IMAGE" ls-remote "https://github.com/${GH_REPO}.git" \
        "refs/tags/${APP_VERSION}^{}" "refs/tags/${APP_VERSION}" 2>/dev/null || true)"
    RESOLVED_COMMIT="$(printf '%s\n' "$out" | awk 'END{print $1}')"
    [[ "$RESOLVED_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
        || die_build "Could not resolve tag ${APP_VERSION} to a commit; refusing to attribute a build to it"
    log_ok "Tag ${APP_VERSION} = commit ${RESOLVED_COMMIT}"
}

# ssh/scp from a helper container on the host network; the VM port listens on 127.0.0.1 only.
# The VM is per-run and local, so its host key is not pinned.
SSH_OPTS=(-i /k -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o ConnectTimeout=15)
# SSH_NAME (optional) names the helper container, so the EXIT trap can remove it.
vm_ssh() {
    local n=(); [[ -n "${SSH_NAME:-}" ]] && n=(--name "$SSH_NAME")
    "$CONTAINER_CMD" run --rm -i "${n[@]}" --network host -v "${WORK_DIR}/vm/key:/k:ro" --entrypoint ssh \
        "$GIT_IMAGE" "${SSH_OPTS[@]}" -p "$VM_PORT" Docker@127.0.0.1 "$@"
}
# A failed copy is an ftbfs, except while diffing a known mismatch (COPY_SOFT=true):
# then it only warns, so the verdict stays not_reproducible.
COPY_SOFT=false
copy_fail() { [[ "$COPY_SOFT" == true ]] && { log_warn "$1"; return 1; }; die_build "$1"; }
# Copy a host file into the VM, then check its sha256 inside Windows.
vm_push() {
    local src="$1" dst="$2" got
    "$CONTAINER_CMD" run --rm --network host -v "${WORK_DIR}/vm/key:/k:ro" -v "${src}:/f:ro" --entrypoint scp \
        "$GIT_IMAGE" "${SSH_OPTS[@]}" -P "$VM_PORT" /f "Docker@127.0.0.1:${dst//\\//}" > /dev/null 2>&1 \
        || "$CONTAINER_CMD" run --rm --network host -v "${WORK_DIR}/vm/key:/k:ro" -v "${src}:/f:ro" --entrypoint scp \
            "$GIT_IMAGE" -O "${SSH_OPTS[@]}" -P "$VM_PORT" /f "Docker@127.0.0.1:${dst//\\//}" > /dev/null \
        || { copy_fail "Could not copy $(basename "$src") into the VM"; return 1; }
    got="$(vm_ssh "powershell -NoProfile -Command (Get-FileHash '${dst}').Hash" | tr -d '\r\n' | tr 'A-F' 'a-f')"
    [[ "$got" == "$(sha256_of "$src")" ]] || { copy_fail "Copy of $(basename "$src") into the VM is corrupt"; return 1; }
}
# Stream a VM file out over SSH, then check it against Get-FileHash inside Windows.
vm_pull() {
    local src="$1" dst="$2" want
    vm_ssh "powershell -NoProfile -Command \"\$f=[IO.File]::OpenRead('${src}');\$f.CopyTo([Console]::OpenStandardOutput());\$f.Close()\"" > "$dst" \
        || { copy_fail "Could not copy ${src} out of the VM"; return 1; }
    want="$(vm_ssh "powershell -NoProfile -Command (Get-FileHash '${src}').Hash" | tr -d '\r\n' | tr 'A-F' 'a-f')"
    [[ "$want" == "$(sha256_of "$dst")" ]] || { copy_fail "Copy of ${src} out of the VM is corrupt"; return 1; }
}

start_vm() {
    local s
    VM_NAME="nunchukwin-$(date +%s)-$$"
    install -m 600 "$VM_KEY" "${WORK_DIR}/vm/key"
    mkdir -p "${WORK_DIR}/vm/storage" "${WORK_DIR}/vm/storage2"
    # dockur state files (windows.boot = already installed; windows.vars must be writable).
    cp "${GOLDEN_DIR}"/storage/windows.* "${WORK_DIR}/vm/storage/"
    chmod u+w "${WORK_DIR}"/vm/storage/windows.*
    local extra=(); [[ "$CONTAINER_CMD" == podman ]] && extra=(--group-add keep-groups)
    # Copy-on-write overlays; the golden disks are only ever opened read-only.
    for s in "storage/data.qcow2:/golden" "storage2/data2.qcow2:/golden2"; do
        local disk="${s%%:*}" mnt="${s#*:}"
        "$CONTAINER_CMD" run --rm "${extra[@]}" --entrypoint qemu-img \
            -v "${GOLDEN_DIR}/storage:/golden:ro" -v "${GOLDEN_DIR}/storage2:/golden2:ro" -v "${WORK_DIR}/vm:/vm" \
            "$WIN_IMAGE" create -q -f qcow2 -F qcow2 -b "${mnt}/${disk##*/}" "/vm/${disk}" \
            || die_build "Could not create the qcow2 overlay for ${disk}"
    done
    log_info "Starting Windows VM ${VM_NAME} (RAM ${VM_RAM}, 4 cores)..."
    "$CONTAINER_CMD" run -d --name "$VM_NAME" "${extra[@]}" \
        -e VERSION=2022 -e RAM_SIZE="$VM_RAM" -e CPU_CORES=4 -e DISK_SIZE=64G -e DISK2_SIZE=32G -e DISK_FMT=qcow2 \
        -v "${WORK_DIR}/vm/storage:/storage" -v "${WORK_DIR}/vm/storage2:/storage2" \
        -v "${GOLDEN_DIR}/storage:/golden:ro" -v "${GOLDEN_DIR}/storage2:/golden2:ro" \
        -p 127.0.0.1::22 --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --stop-timeout 120 \
        "$WIN_IMAGE" > /dev/null || die_build "Could not start the Windows VM container"
    VM_PORT="$("$CONTAINER_CMD" port "$VM_NAME" 22/tcp | head -1)"; VM_PORT="${VM_PORT##*:}"
    [[ "$VM_PORT" =~ ^[0-9]+$ ]] || die_build "Could not read the VM's SSH port"
    for _ in $(seq 1 90); do
        vm_ssh "type C:\\OEM\\done.txt" > /dev/null 2>&1 && { log_ok "Windows is up (SSH on 127.0.0.1:${VM_PORT})"; phase_done "VM boot"; return 0; }
        "$CONTAINER_CMD" ps -q --filter "name=${VM_NAME}" | grep -q . || die_build "The VM container exited during boot"
        sleep 10
    done
    die_build "Windows did not answer over SSH within 15 min"
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
    function VsPath { if (Test-Path $vsw) { & $vsw -products * -version '[17.14.37710,17.14.37711)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CoreBuildTools Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath | Select-Object -First 1 } }
    if (!(VsPath)) {
        # Fixed-version bootstrapper for VS 17.14.41 (17.14.37710.0), the windows-2022 runner's VS.
        $p = Start-Process (Get-Pinned 'https://download.visualstudio.microsoft.com/download/pr/bc92e2cb-33de-4a0c-995d-efa817f16b16/37bb0fb429d163ecebd272a865d11a37b906d152bef960da2ddb29c2e2fd6eeb/vs_BuildTools.exe' '37bb0fb429d163ecebd272a865d11a37b906d152bef960da2ddb29c2e2fd6eeb') -Wait -PassThru `
            -ArgumentList '--quiet', '--wait', '--norestart', '--nocache', '--add', 'Microsoft.VisualStudio.Workload.VCTools', `
            '--add', 'Microsoft.VisualStudio.Component.VC.CoreBuildTools', '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', `
            '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project', `
            '--add', 'Microsoft.VisualStudio.Component.VC.Redist.14.Latest', '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621'
        Need ($p.ExitCode -in 0, 3010) "VS Build Tools installer exit code $($p.ExitCode)"
        # Ports built with MSBuild (sqlite3) need the C++ build targets, not only cl.exe.
        Need (VsPath) "VS Build Tools installed without the VC.CoreBuildTools / VC.CMake.Project components"
    }
    # Same layering as the runner: msvc-dev-cmd's vcvars, then Python and NASM, Strawberry Perl last.
    $env:Path = "$py;$py\Scripts;$T\nasm-3.02;$env:Path;C:\Strawberry\c\bin;C:\Strawberry\perl\site\bin;C:\Strawberry\perl\bin"
    # vcpkg builds ports in a clean environment that takes PATH from the registry, not from this
    # session. With VCPKG_FORCE_SYSTEM_BINARIES it must find pip's ninja there, or it falls back to
    # MSBuild (sqlite3 then fails: RC2135 sqlite370.ico). The runner has these on the machine PATH.
    $need = @($py, "$py\Scripts", "$T\nasm-3.02", 'C:\Strawberry\c\bin', 'C:\Strawberry\perl\site\bin', 'C:\Strawberry\perl\bin')
    $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $add = $need | Where-Object { ($mp -split ';') -notcontains $_ }
    if ($add) { [Environment]::SetEnvironmentVariable('Path', (@($mp.TrimEnd(';')) + $add) -join ';', 'Machine') }
    $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($d in $need) { Need (($mp -split ';') -contains $d) "machine PATH lacks $d" }
    # vcpkg sets up each port with vcvarsall, which adds VS's bundled Ninja (VC.CMake.Project). Without it
    # vcpkg falls back to MSBuild and sqlite3 fails (RC2135 sqlite370.ico). The runner's full VS has it.
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
    Lap 'tool install'
    Write-Host "Toolchain: PASS (cl $Arg3, VCTools 14.44.35207, SDK 10.0.22621.0, CRT 14.44.35211.0, pwsh 7.6.6, Python 3.12.10, NASM 3.02, Perl 5.32.1)"

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
    log_info "Copying the build driver into the VM..."
    vm_ssh "mkdir C:\\nw" > /dev/null 2>&1 || true
    vm_push "${WORK_DIR}/nw.ps1" 'C:\nw\nw.ps1'
    log_info "Building inside Windows (toolchain, then upstream build_windows.ps1 + package_windows.ps1): about 2-3 h..."
    # In the background so INT/TERM run the trap now (it removes the VM), not after the build.
    set +e
    SSH_HELPER="nunchukwin-ssh-$(date +%s)-$$"
    { SSH_NAME="$SSH_HELPER" vm_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\nw\\nw.ps1 -Phase build -Tag ${APP_VERSION} -Commit ${RESOLVED_COMMIT} -Arg3 ${REL_MSVC}" < /dev/null 2>&1 \
        | tr -d '\r' | tee "${WORK_DIR}/build.log"; } &
    wait $!
    set -e
    grep -q '^NW-BUILD-DONE' "${WORK_DIR}/build.log" || {
        grep -q 'Toolchain check failed' "${WORK_DIR}/build.log" \
            && die_build "Windows toolchain does not match the release's: $(grep -m1 -o 'Toolchain check failed.*' "${WORK_DIR}/build.log")"
        die_build "Upstream Windows build failed: $(grep -m1 -o 'NW-FAIL .*' "${WORK_DIR}/build.log" | cut -c1-200) (log with vcpkg/CMake tails: build.log in the workspace)"
    }
    SOURCE_EPOCH="$(sed -nE 's/^NW-BUILD-DONE epoch=([0-9]+).*/\1/p' "${WORK_DIR}/build.log")"
    # A skipped upstream step can invalidate a verdict: surface such lines, don't judge them.
    grep -nE 'SKIP|Skipping' "${WORK_DIR}/build.log" > "${WORK_DIR}/skip_lines.txt" || true
    if [[ -s "${WORK_DIR}/skip_lines.txt" ]]; then
        n="$(wc -l < "${WORK_DIR}/skip_lines.txt")"
        log_warn "${n} build log lines mention SKIP/Skipping (first 5; all in skip_lines.txt):"
        head -n 5 "${WORK_DIR}/skip_lines.txt"
        SIG_WARNINGS+=$'\n'"- ${n} build log lines mention SKIP/Skipping; review skip_lines.txt in the workspace."
    fi
    # Phases inside Windows, timed there (one SSH session runs them all).
    PHASE_TIMES+="$(sed -nE 's/^NW-TIME (.*)$/\1/p' "${WORK_DIR}/build.log")"$'\n'
    PHASE_T0=$SECONDS
    for a in "${ARTIFACTS[@]}"; do
        log_info "Copying $(built_name "$a") out of the VM..."
        vm_pull "C:\\nunchuk-repro\\artifacts\\$(built_name "$a")" "${WORK_DIR}/built/${OFF_NAME[$a]}"
        BUILT_SHA[$a]="$(sha256_of "${WORK_DIR}/built/${OFF_NAME[$a]}")"
        log_ok "Rebuilt ${OFF_NAME[$a]} sha256 ${BUILT_SHA[$a]}"
    done
    phase_done "copy-out"
}

# Differing entries between two "sha256  path" manifests (written by the caller as m-official / m-built).
diff_manifests() {
    local d="$1" n
    # shellcheck disable=SC2016
    tools_c sh -c 'cd "$1" && awk "NR==FNR {o[substr(\$0,67)]=\$1; next} {b[substr(\$0,67)]=\$1}
        END {for (k in o) if (!(k in b)) print k, o[k], \"MISSING\"; else if (o[k] != b[k]) print k, o[k], b[k]
             for (k in b) if (!(k in o)) print k, \"MISSING\", b[k]}" m-official m-built | sort > differing.txt' sh "$d" \
        || return 1
    n="$(wc -l < "${WORK_DIR}/${d}/differing.txt")"
    DIFF_NOTE[$2]="${n} of $(wc -l < "${WORK_DIR}/${d}/m-official") files differ (path, official sha256, rebuilt sha256 in ${d}/differing.txt)"
    log_warn "${DIFF_NOTE[$2]}"; head -n 5 "${WORK_DIR}/${d}/differing.txt"
}

compare_artifacts() {
    local a all=true
    echo ""; echo "======================================================"
    echo "ARTIFACT COMPARISON (byte for byte)"; echo "======================================================"
    for a in "${ARTIFACTS[@]}"; do
        echo "${OFF_NAME[$a]}"; echo "  official ${OFF_SHA[$a]}"; echo "  rebuilt  ${BUILT_SHA[$a]}"
        if [[ "${OFF_SHA[$a]}" == "${BUILT_SHA[$a]}" ]]; then
            log_ok "${OFF_NAME[$a]} is byte-for-byte IDENTICAL"; continue
        fi
        all=false
        log_warn "${OFF_NAME[$a]} differs; unpacking both to diff file by file..."
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
    local ctx="Built in a Windows Server 2022 VM (${WIN_IMAGE##*@}) with upstream build_windows.ps1 and package_windows.ps1 at tag ${APP_VERSION}, commit ${RESOLVED_COMMIT}, SOURCE_DATE_EPOCH ${SOURCE_EPOCH}; MSVC 14.44.35207 (cl ${REL_MSVC}), SDK 10.0.22621.0, VS 17.14.41; ImageOS/ImageVersion not set: build-info.json records GitHub's runner image (${REL_IMAGE_OS:-none}/${REL_IMAGE_VERSION:-none} in the release), which no build outside GitHub can match (upstream leak)."
    local sums="" a2
    for a2 in "${ARTIFACTS[@]}"; do sums+="${OFF_NAME[$a2]}: official ${OFF_SHA[$a2]}, rebuilt ${BUILT_SHA[$a2]}${DIFF_NOTE[$a2]:+ (${DIFF_NOTE[$a2]})}; "; done
    if [[ "$all" == true ]]; then
        write_yaml "reproducible" "Every compared file is byte-for-byte identical. ${sums}${ctx}"
        return 0
    fi
    write_yaml "not_reproducible" "Rebuilt files differ from the release. ${sums}${ctx}"
    return 1
}

emit_verification_summary() {
    local verdict a
    verdict="$(awk '/^verdict:/{print $2}' "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml" 2>/dev/null)"
    echo ""
    echo "HASH LEGEND"
    echo "  appHash          sha256 of the official file as distributed (first compared file; others below)."
    echo "  builtAppHash     sha256 of our rebuilt file; equality with appHash is the verdict."
    echo "  scriptHash       sha256 of this script."
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${verdict}"
    a="${ARTIFACTS[0]}"
    echo "appHash:        ${OFF_SHA[$a]:-N/A}"
    echo "officialFile:   ${OFF_NAME[$a]:-N/A}"
    echo "builtAppHash:   ${BUILT_SHA[$a]:-N/A}"
    echo "commit:         ${RESOLVED_COMMIT}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
    echo ""
    echo "Diff:"
    for a in "${ARTIFACTS[@]}"; do
        if [[ "${OFF_SHA[$a]}" == "${BUILT_SHA[$a]}" ]]; then
            echo "${OFF_NAME[$a]}: identical (${OFF_SHA[$a]})"
        else
            echo "${OFF_NAME[$a]}: official ${OFF_SHA[$a]}, rebuilt ${BUILT_SHA[$a]:-N/A}"
            echo "  ${DIFF_NOTE[$a]:-not diffed}"
        fi
    done
    echo ""
    echo "Revision, tag (and its signature):"
    echo "tag:            ${APP_VERSION}"
    echo "commit:         ${RESOLVED_COMMIT}"
    echo ""
    echo "Signature Summary:"
    echo "${SIG_MANIFEST_STATUS}"
    echo "${SIG_DIGEST_STATUS}"
    echo "[WARNING] Tag signature not checked by this script"
    echo "[WARNING] Commit signature not checked by this script"
    echo ""
    echo "Keys used:"
    if [[ "$SIG_MANIFEST_STATUS" == "[OK]"* ]]; then echo "Manifest signed with: ${NUNCHUK_RELEASE_KEY_FPR}"; else echo "None established"; fi
    echo ""
    printf 'Warnings:%s\n' "${SIG_WARNINGS:-}"
    echo ""
    echo "===== End Results ====="
    echo ""
    echo "Build environment:"
    echo "VM image:       ${WIN_IMAGE}"
    echo "golden image:   ${GOLDEN_DIR}"
    echo "release runner: ${REL_IMAGE_OS:-?} ${REL_IMAGE_VERSION:-?}, cl.exe ${REL_MSVC} (runner fields not reproduced, see Warnings)"
    echo "toolchain:      VS Build Tools 17.14.41, MSVC 14.44.35207, SDK 10.0.22621.0, pwsh 7.6.6, Python 3.12.10, NASM 3.02, Strawberry Perl 5.32.1.1"
    echo "                cl.exe is checked against the release's build-info.json. build-info.json does not record"
    echo "                Python, NASM or Perl: those are from upstream's CI job logs (2.9.1 run 38044363978, 2.9.2 run 40099229609:"
    echo "                'Successfully set up CPython (3.12.10)', 'nasm v3.2.0', 'NASM version 3.02', C:\\Strawberry perl)"
    echo "                and the runner toolset (strawberryperl 5.32.1.1)."
    [[ "$APP_VERSION" == 2.9.[12] ]] || echo "[WARNING] Toolchain versions were confirmed for 2.9.1 and 2.9.2 only; check them against this release's CI run"
    echo ""
    echo "Elapsed time per phase:"
    printf '%s' "$PHASE_TIMES"
    echo ""
    echo "Limitations:"
    echo "- pip resolves aqtinstall's and py7zr's dependencies at run time (upstream pins only aqtinstall, py7zr, ninja)."
    echo "- VS Build Tools payloads are checked only by the VS installer against Microsoft's signed manifest;"
    echo "  the script checks the bootstrapper's sha256 and asserts the resulting cl/CRT/SDK versions."
    echo "- Qt (aqt from download.qt.io) and vcpkg sources are verified by those tools, not by this script."
    echo "- Built under user Docker, time zone set to UTC; the release was built as runneradmin on GitHub's runner."
    echo "- The bundled hwi.exe is a prebuilt download pinned by sha256 in windows-dependencies.lock.json, not built from source."
    echo ""
}

main() {
    echo ""; echo "======================================================"
    echo "${APP_NAME} Reproducible Build Verifier ${SCRIPT_VERSION}"
    echo "======================================================"; echo ""
    SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
    log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
    log_info "         sha256: ${SCRIPT_SHA256}"
    rm -f "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

    parse_args "$@"
    [[ "$(id -u)" -ne 0 ]] || die_invalid "Do not run as root: run as a normal user (rootless podman, or docker group)"
    detect_container_cmd
    check_prereqs
    setup_workdir
    log_info "Version: ${APP_VERSION}  Arch: ${APP_ARCH}  Type: ${APP_TYPE}"

    prepare_official
    verify_official_signature
    resolve_commit
    write_vm_script
    PHASE_T0=$SECONDS
    start_vm
    run_build

    local verdict_exit=0
    compare_artifacts || verdict_exit=$?
    "$CONTAINER_CMD" rm -f "$VM_NAME" > /dev/null 2>&1 || true
    VM_NAME=""

    emit_verification_summary
    echo ""
    echo "======================================================"
    echo "RESULTS (machine-readable verdict in COMPARISON_RESULTS.yaml)"
    echo "======================================================"
    cat "${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
    echo ""
    echo "Work directory: ${WORK_DIR}"
    echo "Rebuilt artifacts: ${WORK_DIR}/built/"
    echo "======================================================"
    exit "$verdict_exit"
}

main "$@"
