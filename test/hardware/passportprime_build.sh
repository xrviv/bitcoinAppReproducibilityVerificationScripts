#!/bin/bash
#
# passportprime_build.sh - Foundation Passport Prime (KeyOS) Reproducible Build Verifier
#
# Version: v0.3.3
#
# Last modified by: Danny Garcia
# Last modified on: 2026-08-11
#
# Description:
#   Reproducible build verification for the Foundation Passport Prime hardware
#   wallet firmware (KeyOS, Xous-based, armv7a / SAMA5D2). Follows the vendor's
#   official Nix-based recipe (REPRODUCIBILITY.md in the KeyOS repository)
#   inside a single pinned container image:
#
#     nix develop .#build
#     scripts/generate-cosign2-dev-key.sh
#     cargo xtask build-all --production-bootloader --production-firmware
#
#   It then extracts all non-bootloader filesystem members from the locally
#   assembled firmware image (boot.img) and compares each against the
#   corresponding loose file in the versioned branch of the KeyOS-Releases
#   repository (forward direction). The branch's own file inventory (GitHub
#   tree API) is then checked so an official member ABSENT from the built
#   image is also caught (reverse closure):
#     - Compiled firmware (app.bin, recovery.bin, app ELFs): signed binaries
#       carry a non-deterministic 2048-byte cosign2 header, so they are hashed
#       over the content AFTER the first 2048 bytes (tail -c +2049), per vendor.
#     - Source-derived manifests + assets (app permission manifests, fonts,
#       icons, boot/UI assets): hashed whole.
#   The terminal prints the compiled-component table in full and summarises the
#   manifests/assets; the complete per-member table is written to
#   comparison-hashes.txt (evidence file).
#
#   Out of scope by vendor design: the bootloader. boot.bin is the plaintext
#   build output carrying a secret 32-byte EXTRA_ENTROPY; boot.cip is the
#   separately encrypted image that ships. Excluded because the production
#   EXTRA_ENTROPY is not public, so there is no comparand.
#
#   Additional boundaries (disclosed in the YAML notes; 2026-07-29 review):
#   the comparison covers file payloads only. It does NOT reproduce the raw
#   Factory image bytes (MBR/FAT metadata, partition layout), the
#   user-distributed OTA update package (release.tar / Update.tar), or the
#   packaged composite assets on the KeyOS GitHub Releases page. Verifying
#   the distributed OTA package is a separate phase pending a product/ABS
#   decision — do not read a "reproducible" verdict here as covering it.
#
#   Exit codes are mechanical by policy (0 identical / 1 any difference or
#   build failure / 2 invalid params; Danny 2025-10-30). NOTE: current ABS
#   ingests COMPARISON_RESULTS.yaml only when the script exits 0
#   (external/build_server/verifications.mjs:815-850,873), so negative
#   verdicts from this script are not ABS-ingestable until that policy
#   conflict is resolved with Luis. Run manually until then.
#
#   Architecture note: the vendor recommends aarch64 hosts for "perfect
#   reproducibility", but an x86_64 build of v1.2.1 matched all 11 components
#   (WalletScrutiny, 2026-06-12). A hash match on any architecture is valid
#   evidence; on a mismatch, an aarch64 rerun is required before concluding
#   not_reproducible.
#
#   Container note: the Nix build sandbox is disabled inside the container
#   (rootless engines cannot grant it namespaces). Determinism comes from the
#   vendor's flake.lock pinning plus the --production-firmware reproducible
#   flags, and is checked by the hash comparison itself.
#
# Usage:
#   passportprime_build.sh --version VERSION [--arch armv7a] [--type firmware]
#   passportprime_build.sh --version VERSION --binary /path/to/file-or-dir
#
# Only host requirement: podman or docker. No credentials needed.
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#

set -euo pipefail

SCRIPT_VERSION="v0.3.3"
APP_ID="passportprime"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Upstream URLs (KeyOS repo, KeyOS-Releases raw base) are set where they are
# used: the Dockerfile heredoc (clone) and inner_build.sh (RAW_BASE, tree API).
# Pinned Nix base image (single-user Nix). Digest-pinned: a tag is mutable.
NIX_IMAGE="docker.io/nixos/nix:2.31.5@sha256:4ae3542b89e38bf739a98d9e1ffd082c3c7b8a6455ec0c2331560b9440aec442"
SUPPORTED_ARCH="armv7a"
SUPPORTED_TYPE="firmware"

APP_VERSION=""
APP_ARCH="${SUPPORTED_ARCH}"
APP_TYPE="${SUPPORTED_TYPE}"
BINARY_PATH=""
NO_CACHE=false
# Cap cargo parallelism to bound peak RAM. KeyOS GUI apps build with
# codegen-units=1 (one large rustc each); the default of one job per core can
# exhaust memory on smaller hosts and trigger a (silent) OOM kill. Job count
# does NOT affect output bytes, so this is reproducibility-neutral. Override
# with CARGO_JOBS (e.g. CARGO_JOBS=2 on a very small machine, or =nproc on a
# large build server).
CARGO_JOBS="${CARGO_JOBS:-4}"
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
passportprime_build.sh ${SCRIPT_VERSION} - Foundation Passport Prime (KeyOS) reproducible build verifier

Usage:
  $0 --version VERSION [--arch ${SUPPORTED_ARCH}] [--type ${SUPPORTED_TYPE}]
  $0 --version VERSION --binary /path/to/file-or-directory

Parameters:
  --version VERSION   Firmware version without 'v' prefix (e.g. 1.2.1).
                      Source ref used: tag vVERSION. Official binaries:
                      KeyOS-Releases branch VERSION, directory VERSION/.
                      Required (firmware blobs carry no extractable version).
  --binary PATH       Optional official artifact(s) used as the comparand for
                      their matching members (components not provided are
                      downloaded from KeyOS-Releases). A directory may contain
                      any of: app.bin, recovery.bin, gui-app-*.elf (or
                      gui-app-*/app.elf). A single file must be named app.bin,
                      recovery.bin or gui-app-*.elf; unrecognized names are
                      fatal (the script refuses to guess which member a
                      supplied file is). A provided file that matches no built
                      member fails the run rather than being silently ignored.
  --arch ARCH         Target architecture. Only ${SUPPORTED_ARCH} is supported
                      (firmware target; the build host can be x86_64 or aarch64).
  --type TYPE         Artifact type. Only ${SUPPORTED_TYPE} is supported.
  --apk FILE          Android-only parameter; accepted as alias for --binary.
  --no-cache          Build the container image without cache.
  --help              This help.

Exit codes: 0 = reproducible, 1 = not reproducible / build failure, 2 = invalid parameters.
Build time: roughly 60-120 minutes on first run (Nix toolchain download + full
firmware build); cached reruns are much faster. Disk: ~20-25 GB for the image.
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

    # Unexpected --arch/--type values warn and fall back; exiting 2 would kill an
    # ABS run that passes a host arch rather than the firmware target.
    if [[ "${APP_ARCH}" != "${SUPPORTED_ARCH}" ]]; then
        log_warn "--arch '${APP_ARCH}' ignored; firmware target is ${SUPPORTED_ARCH}"
        APP_ARCH="${SUPPORTED_ARCH}"
    fi
    if [[ -n "${APP_TYPE}" && "${APP_TYPE}" != "${SUPPORTED_TYPE}" ]]; then
        log_warn "--type '${APP_TYPE}' ignored; only ${SUPPORTED_TYPE} is produced"
        APP_TYPE="${SUPPORTED_TYPE}"
    fi
    if [[ -z "${APP_VERSION}" ]]; then
        die_invalid "--version is required (e.g. --version 1.2.1)"
    fi
    if [[ -n "${BINARY_PATH}" && ! -e "${BINARY_PATH}" ]]; then
        die_invalid "--binary path not found: ${BINARY_PATH}"
    fi
}

# ----------------------------------------------------------------------------
# Provided binaries (--binary): normalize into out/provided/ as flat files
# named app.bin, recovery.bin, gui-app-NAME.elf so the inner script can use
# them in place of downloads.
# ----------------------------------------------------------------------------

stage_provided_binaries() {
    local dest="${WORK_DIR}/out/provided"
    mkdir -p "${dest}"
    local staged=0

    stage_dest() {  # $1=source $2=dest-name ; duplicate logical artifacts are
                    # ambiguous — find order must never decide the comparand.
        if [[ -e "${dest}/$2" ]]; then
            die_invalid "--binary: duplicate artifact for '$2' (multiple supplied files map to the same release member; remove one)"
        fi
        cp "$1" "${dest}/$2"; staged=$((staged+1))
    }

    stage_one() {
        local f="$1" mode="${2:-strict}"
        local base
        base="$(basename "$f")"
        case "${base}" in
            app.bin|recovery.bin|gui-app-*.elf)
                stage_dest "$f" "${base}" ;;
            app.elf)
                # An app.elf is identified by its gui-app-* parent directory.
                local parent
                parent="$(basename "$(dirname "$f")")"
                if [[ "${parent}" == gui-app-* ]]; then
                    stage_dest "$f" "${parent}.elf"
                elif [[ "${mode}" == strict ]]; then
                    die_invalid "--binary: cannot determine app name for ${f} (parent dir not gui-app-*)"
                else
                    log_warn "Cannot determine app name for ${f} (parent dir not gui-app-*); ignored"
                fi ;;
            *)
                # Refuse to guess which release member an unknown file is:
                # comparing a user-supplied binary against the wrong member
                # would produce a confidently wrong verdict.
                die_invalid "--binary: unrecognized file name '${base}' (expected app.bin, recovery.bin or gui-app-*.elf)" ;;
        esac
    }

    if [[ -d "${BINARY_PATH}" ]]; then
        while IFS= read -r -d '' f; do
            stage_one "$f" lenient
        done < <(find "${BINARY_PATH}" \( -name 'app.bin' -o -name 'recovery.bin' -o -name 'gui-app-*.elf' -o -name 'app.elf' \) -type f -print0)
        local total_files
        total_files="$(find "${BINARY_PATH}" -type f | wc -l)"
        if (( total_files > staged )); then
            log_warn "--binary directory: $((total_files - staged)) file(s) did not match expected member names and were ignored"
        fi
    else
        stage_one "${BINARY_PATH}" strict
    fi
    if (( staged == 0 )); then
        die_invalid "--binary: no usable official artifacts found at ${BINARY_PATH}"
    fi
    log_info "Provided artifacts staged: ${staged}; they are the official comparand for their members (unprovided members are downloaded)"
}

# ----------------------------------------------------------------------------
# Comparison library: pure mapping/classification helpers shared by the inner
# container script and the host test suite (passportprime_build_tests.sh).
# No side effects; safe to source anywhere.
# ----------------------------------------------------------------------------

write_comparison_lib() {
    cat > "${WORK_DIR}/comparison_lib.sh" <<'LIB_EOF'
#!/bin/bash
# Pure helpers shared by inner_build.sh (in-container) and the host tests.

# Per vendor REPRODUCIBILITY.md: signed binaries carry a 2048-byte cosign2
# signature header; hashes are computed over the content after it.
unsigned_sha256() { tail -c +2049 "$1" | sha256sum | cut -d' ' -f1; }

release_path_for() {   # $1=partition $2=relpath -> release path ('' = excluded)
    local part="$1" rel="$2"
    if [ "${part}" = "boot" ]; then
        case "${rel}" in
            boot.bin|boot.cip|boot-signed.cip) echo "" ;;          # bootloader: excluded
            common/*) echo "common-boot/${rel#common/}" ;;          # boot 'common' == release 'common-boot'
            *)        echo "${rel}" ;;                               # recovery.bin, blassets/*
        esac
    else
        echo "${rel}"                                               # system: keyos/*
    fi
}

is_signed() {          # only these carry the 2048-byte cosign2 header
    case "$1" in
        recovery.bin|keyos/app.bin|keyos/apps/*/app.elf) return 0 ;;
        *) return 1 ;;
    esac
}

member_hash() {        # $1=release-path $2=file ; signed -> after header, else whole
    if is_signed "$1"; then unsigned_sha256 "$2"; else sha256sum "$2" | cut -d' ' -f1; fi
}

provided_name_for() {  # $1=release-path -> expected name under /out/provided ('' = n/a)
    case "$1" in
        recovery.bin)                 echo "recovery.bin" ;;
        keyos/app.bin)                echo "app.bin" ;;
        keyos/apps/gui-app-*/app.elf) echo "$(basename "$(dirname "$1")").elf" ;;
        *)                            echo "" ;;
    esac
}

# Classify a release member (path relative to <version>/) for reverse closure.
# POSITIVE classifier (2026-07-29 codex review, finding 1): only paths that
# map to boot-image members are closure candidates. Composite/OTA/companion
# artifacts are a disclosed verification boundary, NOT missing members; an
# unrecognized path is surfaced for human review, never silently ignored and
# never a silent verdict-changer.
closure_class_for() {  # $1 -> compare|bootloader|out_of_scope|unknown
    case "$1" in
        boot.bin|boot.cip|boot-signed.cip)                echo bootloader ;;
        recovery.bin|blassets/*|common-boot/*|keyos/*)    echo compare ;;
        KeyOS-v*-Factory.img)                             echo out_of_scope ;;
        KeyOS-v*-Recovery.bin|KeyOS-v*-CoreSystemRecovery.bin) echo out_of_scope ;;
        KeyOS-v*Update.tar|envoy-server/*)                echo out_of_scope ;;
        v[0-9]*-v[0-9]*.zip)                              echo out_of_scope ;;  # versioned update bundle (e.g. v1.2.2-v1.3.0.zip, LFS; classified 2026-07-29)
        *)                                                 echo unknown ;;
    esac
}
LIB_EOF
    chmod +x "${WORK_DIR}/comparison_lib.sh"
}

# ----------------------------------------------------------------------------
# Inline Dockerfile: pinned Nix image, vendor source at the release tag,
# build environment pre-realized into a cacheable layer.
# ----------------------------------------------------------------------------

write_dockerfile() {
    cat > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
ARG NIX_IMAGE
FROM ${NIX_IMAGE}
ARG KEYOS_REF

# Flakes on; Nix build sandbox off (cannot be granted inside a rootless
# container). Determinism is provided by flake.lock pinning and verified by
# the final hash comparison.
RUN mkdir -p /etc/nix && \
    printf 'experimental-features = nix-command flakes\nsandbox = false\n' >> /etc/nix/nix.conf

# The nixos/nix base image already provides git, curl and coreutils on the
# runtime PATH (/root/.nix-profile/bin), and openssl is provided inside the
# 'nix develop .#build' dev shell (used by generate-cosign2-dev-key.sh). We do
# NOT run 'nix-env -iA' here: installing into the root profile rewrites its
# manifest and DROPS the pre-installed curl, which broke the official-binary
# download step (curl: command not found) while leaving the build itself fine.

ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

# Vendor source at the exact release tag, submodules included.
# refs/tags/ is explicit: a bare ref name resolves a same-named branch first.
RUN git clone --recurse-submodules https://github.com/Foundation-Devices/KeyOS.git /keyos && \
    cd /keyos && \
    git rev-parse --verify "refs/tags/${KEYOS_REF}" >/dev/null && \
    git checkout "refs/tags/${KEYOS_REF}" && \
    git submodule update --init --recursive && \
    git rev-parse HEAD > /keyos_commit.txt && cat /keyos_commit.txt

WORKDIR /keyos

# Pre-realize the vendor's pinned build environment (Rust toolchain, ARM
# tools, custom stdlib) into an image layer, and pre-fetch crates - the two
# big downloads - so reruns hit the layer cache.
RUN nix develop .#build --command true
RUN nix develop .#build --command cargo fetch

COPY comparison_lib.sh /usr/local/bin/comparison_lib.sh
COPY inner_build.sh /usr/local/bin/inner_build.sh
RUN chmod +x /usr/local/bin/comparison_lib.sh /usr/local/bin/inner_build.sh

# The nixos/nix image has no /bin/bash (only /bin/sh -> bash via the nix
# profile). Vendor build scripts use '#!/bin/bash' shebangs, so provide it.
# Placed last to keep the expensive nix-develop / cargo-fetch layers cached.
RUN ln -sf /bin/sh /bin/bash
DOCKERFILE_EOF
}

# ----------------------------------------------------------------------------
# Inner script (runs inside the container; builds the firmware, hashes every
# verifiable component, obtains official hashes, compares)
# ----------------------------------------------------------------------------

write_inner_script() {
    cat > "${WORK_DIR}/inner_build.sh" <<'INNER_EOF'
#!/bin/bash
# Runs inside the build image. Inputs (env): KEYOS_VERSION, GITHUB_TOKEN
# (optional). /out must be mounted; /out/provided/ may contain user-supplied
# official artifacts (app.bin, recovery.bin, gui-app-*.elf).
set -euo pipefail

OUT=/out
TARGET_DIR="target/armv7a-unknown-xous-elf/release"
RAW_BASE="https://raw.githubusercontent.com/Foundation-Devices/KeyOS-Releases/${KEYOS_VERSION}/${KEYOS_VERSION}"
AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# Pure mapping/classification helpers (shared with the host test suite).
. /usr/local/bin/comparison_lib.sh

cd /keyos
expected_commit="$(cat /keyos_commit.txt)"
actual_commit="$(git rev-parse HEAD)"
if [ "${expected_commit}" != "${actual_commit}" ]; then
    echo "[BUILD] FAIL: commit mismatch (expected ${expected_commit}, got ${actual_commit})"; exit 1
fi
echo "${actual_commit}" > "${OUT}/commit.txt"
echo "[BUILD] Source: tag v${KEYOS_VERSION} = ${actual_commit}"

# --- [1/4] build (vendor recipe; throwaway signing key - comparison ignores
#           the signature header, so the key does not affect the verdict) ---
nix develop .#build --command bash -c '
    set -euo pipefail
    scripts/generate-cosign2-dev-key.sh
    cargo xtask build-all --production-bootloader --production-firmware
    cargo xtask print-hashes
' | tee "${OUT}/build-log.txt" | tail -50
# Full vendor hash listing for the record (independent of our own hashing below).
nix develop .#build --command cargo xtask print-hashes > "${OUT}/print-hashes.txt"

# --- [2/4] locate the built firmware image (contains every release member) ---
# 'cargo xtask build-all' assembles boot.img from the freshly built components
# + assets. We verify the boot image's non-bootloader FILE MEMBERS by
# extracting them from THIS image and comparing each with its loose
# counterpart in the release branch. Composite/OTA/companion artifacts are a
# disclosed boundary, not covered. Sanity check the loose compiled outputs first.
for img in app.bin recovery.bin; do
    [ -f "${TARGET_DIR}/images/${img}" ] || { echo "[BUILD] FAIL: missing built ${img}"; exit 1; }
done
BOOT_IMG=""
for cand in boot.img "${TARGET_DIR}/boot.img" out/boot.img images/boot.img; do
    [ -f "${cand}" ] && BOOT_IMG="${cand}" && break
done
[ -n "${BOOT_IMG}" ] || { echo "[BUILD] FAIL: built boot.img not found (build-all should produce it)"; exit 1; }
echo "[BUILD] Built firmware image: ${BOOT_IMG} ($(stat -c%s "${BOOT_IMG}") bytes)"

# --- [3/4] extract all filesystem members from the built image ---
# mtools is taken from the SAME nixpkgs revision the vendor's flake.lock pins,
# so the verification tooling is as pinned as the build itself (falls back to
# the registry alias with a warning if the lock cannot be parsed). It runs in
# an ephemeral 'nix shell' so it never rewrites the root profile (a profile
# mutation previously dropped curl). Boot partition @ off 512, system
# partition @ off 268435456 (FAT32 LBA, fixed by the vendor image-builder).
# nix itself parses the lock file: the minimal image has no jq or sed.
# Only trust the rev if the locked source really is github:NixOS/nixpkgs —
# constructing that flake ref from a lock that moved elsewhere would pin the
# wrong thing (2026-07-29 codex review, finding 8 caveat).
NIXPKGS_REV="$(nix eval --raw --impure --expr 'let l = builtins.fromJSON (builtins.readFile "/keyos/flake.lock"); r = l.nodes.${l.root}.inputs.nixpkgs; key = if builtins.isString r then r else "nixpkgs"; lk = l.nodes.${key}.locked; in if lk.type == "github" && lk.owner == "NixOS" && lk.repo == "nixpkgs" then lk.rev else ""' 2>/dev/null || true)"
if [ -n "${NIXPKGS_REV}" ]; then
    MTOOLS_FLAKE="github:NixOS/nixpkgs/${NIXPKGS_REV}"
else
    MTOOLS_FLAKE="nixpkgs"
    echo "[BUILD] WARN: could not resolve nixpkgs rev from vendor flake.lock; using registry nixpkgs for mtools (extraction-only tool; does not affect built bytes)"
fi
{ echo "mtools_flake=${MTOOLS_FLAKE}"; nix shell "${MTOOLS_FLAKE}#mtools" --command mcopy -V 2>/dev/null | head -1 || true; } > "${OUT}/tooling.txt"
EX="${OUT}/built-members"
rm -rf "${EX}"; mkdir -p "${EX}/boot" "${EX}/system"
nix shell "${MTOOLS_FLAKE}#mtools" --command mcopy -s -n -i "${BOOT_IMG}@@512"       ::/ "${EX}/boot/"
nix shell "${MTOOLS_FLAKE}#mtools" --command mcopy -s -n -i "${BOOT_IMG}@@268435456" ::/ "${EX}/system/"
echo "[BUILD] Extracted members: $(find "${EX}" -type f | wc -l) (mtools from ${MTOOLS_FLAKE})"

# --- [4/4] compare every member to the official release (bidirectional) ---
# Forward: every extracted built member is hashed and compared against the
# corresponding official file (user-provided via --binary when available,
# otherwise downloaded). Reverse: the version branch's own file inventory
# (GitHub tree API) is checked afterwards, so an official member ABSENT from
# the built image is caught too — enumeration of built files alone cannot see
# those.
# Map an extracted member to its path under the KeyOS-Releases <version>/ dir.
# The bootloader is excluded by vendor design (disclosed, not a mismatch):
# boot.bin carries a secret EXTRA_ENTROPY, boot.cip is its encrypted form.
# (release_path_for / is_signed / member_hash / provided_name_for /
# closure_class_for are defined in comparison_lib.sh, sourced above.)

# Each member is tagged COMPILED (the signed firmware: app.bin, recovery.bin,
# app ELFs) or ASSET (manifests + static assets). Both are compared; the full
# table is written to comparison-hashes.txt. The terminal prints the COMPILED
# table in full and summarises the ASSET set, to avoid swamping build logs.
mkdir -p "${OUT}/official"
c_total=0; c_match=0; c_mis=0; c_miss=0     # COMPILED (signed) components
a_total=0; a_match=0; a_mis=0; a_miss=0     # ASSET (manifests + static assets)
excluded=0; provided_used=0
declare -A COMPARED
: > "${OUT}/comparison-hashes.txt"
: > "${OUT}/provided-used.txt"
while IFS= read -r -d '' f; do
    # Determine partition via bash patterns (the minimal nix image has no sed).
    case "${f}" in
        "${EX}/boot/"*)   part=boot ;;
        "${EX}/system/"*) part=system ;;
        *) continue ;;
    esac
    rel="${f#"${EX}/${part}/"}"
    relp="$(release_path_for "${part}" "${rel}")"
    if [ -z "${relp}" ]; then
        echo "EXCLUDED bootloader ${part}/${rel} (secret EXTRA_ENTROPY, no public comparand; vendor design)" >> "${OUT}/comparison-hashes.txt"
        excluded=$((excluded+1)); continue
    fi
    COMPARED["${relp}"]=1
    if is_signed "${relp}"; then cls=COMPILED; else cls=ASSET; fi
    built_hash="$(member_hash "${relp}" "${f}")"
    safe="$(printf '%s' "${relp}" | tr '/' '_')"
    # User-provided official artifact takes precedence over downloading.
    src=downloaded
    prov="$(provided_name_for "${relp}")"
    if [ -n "${prov}" ] && [ -f "${OUT}/provided/${prov}" ]; then
        cp "${OUT}/provided/${prov}" "${OUT}/official/${safe}"
        src=provided
        provided_used=$((provided_used+1))
        echo "${prov}" >> "${OUT}/provided-used.txt"
    else
        url="${RAW_BASE}/${relp}"
        if ! curl -fsSL "${AUTH_ARGS[@]}" -o "${OUT}/official/${safe}" "${url}"; then
            echo "MISSING_OFFICIAL ${cls} ${relp} (${url})" >> "${OUT}/comparison-hashes.txt"
            if [ "${cls}" = COMPILED ]; then c_total=$((c_total+1)); c_miss=$((c_miss+1)); else a_total=$((a_total+1)); a_miss=$((a_miss+1)); fi
            continue
        fi
    fi
    official_hash="$(member_hash "${relp}" "${OUT}/official/${safe}")"
    if [ "${built_hash}" = "${official_hash}" ]; then
        echo "MATCH ${cls} ${relp} ${built_hash} [${src}]" >> "${OUT}/comparison-hashes.txt"
        if [ "${cls}" = COMPILED ]; then c_total=$((c_total+1)); c_match=$((c_match+1)); else a_total=$((a_total+1)); a_match=$((a_match+1)); fi
    else
        echo "MISMATCH ${cls} ${relp} built=${built_hash} official=${official_hash} [${src}]" >> "${OUT}/comparison-hashes.txt"
        if [ "${cls}" = COMPILED ]; then c_total=$((c_total+1)); c_mis=$((c_mis+1)); else a_total=$((a_total+1)); a_mis=$((a_mis+1)); fi
    fi
done < <(find "${EX}" -type f -print0)

# Every user-provided artifact must have been consumed by the comparison.
# A provided file that matched no built member means the user is verifying an
# artifact this run never looked at — fail loudly rather than report a verdict
# that silently ignored their binary.
if [ -d "${OUT}/provided" ]; then
    declare -A USED
    while IFS= read -r u; do [ -n "${u}" ] && USED["${u}"]=1; done < "${OUT}/provided-used.txt"
    for pf in "${OUT}/provided"/*; do
        [ -e "${pf}" ] || continue
        pb="$(basename "${pf}")"
        if [ -z "${USED[${pb}]:-}" ]; then
            echo "[BUILD] FAIL: provided artifact ${pb} was never used (no matching built member)"
            exit 1
        fi
    done
fi

# Reverse closure: list the version branch's own files and flag official
# members the built image does not contain. The POSITIVE classifier in
# comparison_lib.sh decides what is a closure candidate: composite/OTA/
# companion artifacts are a disclosed boundary (out_of_scope), unrecognized
# paths are surfaced as UNKNOWN_OFFICIAL for human review — neither silently
# fails a clean run. Network/API failure degrades to 'unverified' with a
# warning; the YAML notes then downgrade the claim to forward-only.
missing_in_build=0
oos_official=0
unknown_official=0
closure=unverified
TREE_JSON="${OUT}/official-tree.json"
if curl -fsSL "${AUTH_ARGS[@]}" -o "${TREE_JSON}" \
        "https://api.github.com/repos/Foundation-Devices/KeyOS-Releases/git/trees/${KEYOS_VERSION}?recursive=1"; then
    if [[ "$(tr -d ' \n' < "${TREE_JSON}")" == *'"truncated":true'* ]]; then
        echo "[BUILD] WARN: tree listing truncated by API; reverse closure unverified"
    else
        # nix parses the JSON (no jq/sed in the minimal image). Trailing
        # newline appended so the last entry survives the read loop.
        nix eval --raw --impure --expr "let j = builtins.fromJSON (builtins.readFile \"${TREE_JSON}\"); in (builtins.concatStringsSep \"\n\" (map (e: e.path) (builtins.filter (e: e.type == \"blob\") j.tree))) + \"\n\"" > "${OUT}/official-inventory.txt" 2>/dev/null || true
        if [ -s "${OUT}/official-inventory.txt" ]; then
            closure=ok
            while IFS= read -r opath || [ -n "${opath}" ]; do
                case "${opath}" in
                    "${KEYOS_VERSION}/"*) orel="${opath#"${KEYOS_VERSION}/"}" ;;
                    *) continue ;;
                esac
                case "$(closure_class_for "${orel}")" in
                    bootloader) continue ;;   # secret EXTRA_ENTROPY, excluded by vendor design
                    out_of_scope)
                        echo "OUT_OF_SCOPE ${orel} (composite/OTA/companion artifact; disclosed verification boundary)" >> "${OUT}/comparison-hashes.txt"
                        oos_official=$((oos_official+1)); continue ;;
                    unknown)
                        echo "UNKNOWN_OFFICIAL ${orel} (unclassified release member; needs human review)" >> "${OUT}/comparison-hashes.txt"
                        unknown_official=$((unknown_official+1)); continue ;;
                esac
                if [ -z "${COMPARED[${orel}]:-}" ]; then
                    echo "MISSING_IN_BUILD ${orel} (official boot-image member absent from built image)" >> "${OUT}/comparison-hashes.txt"
                    missing_in_build=$((missing_in_build+1))
                fi
            done < "${OUT}/official-inventory.txt"
            # An unknown official member is a scope change the classifier
            # cannot adjudicate — different from a network failure. Full
            # closure is only 'ok' when every member is classified.
            if [ "${unknown_official}" -gt 0 ]; then
                closure=needs_review
                echo "[BUILD] WARN: ${unknown_official} unclassified official member(s); closure set to needs_review — do not publish before classifying them"
            fi
        else
            echo "[BUILD] WARN: could not parse tree listing; reverse closure unverified"
        fi
    fi
else
    echo "[BUILD] WARN: could not fetch KeyOS-Releases tree listing; reverse closure unverified (network/API)"
fi

{
    echo "COMMIT=${actual_commit}"
    echo "C_TOTAL=${c_total}";  echo "C_MATCHED=${c_match}"; echo "C_MISMATCHED=${c_mis}"; echo "C_MISSING=${c_miss}"
    echo "A_TOTAL=${a_total}";  echo "A_MATCHED=${a_match}"; echo "A_MISMATCHED=${a_mis}"; echo "A_MISSING=${a_miss}"
    echo "EXCLUDED=${excluded}"
    echo "TOTAL=$((c_total+a_total))"
    echo "MATCHED=$((c_match+a_match))"
    echo "MISMATCHED=$((c_mis+a_mis))"
    echo "MISSING=$((c_miss+a_miss))"
    echo "MISSING_IN_BUILD=${missing_in_build}"
    echo "CLOSURE=${closure}"
    echo "OOS_OFFICIAL=${oos_official}"
    echo "UNKNOWN_OFFICIAL=${unknown_official}"
    echo "PROVIDED_USED=${provided_used}"
} > "${OUT}/RESULT.env"
echo "[BUILD] Compiled: ${c_match}/${c_total} matched | Assets: ${a_match}/${a_total} matched | excluded(bootloader): ${excluded} | mismatched=$((c_mis+a_mis)) missing=$((c_miss+a_miss)) | official-absent-from-build: ${missing_in_build} (closure: ${closure}; out-of-scope: ${oos_official}; unclassified: ${unknown_official}) | provided used: ${provided_used}"
echo "[BUILD] Evidence table sha256: $(sha256sum "${OUT}/comparison-hashes.txt" | cut -d' ' -f1)"
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

    local safe_ver
    safe_ver="$(echo "${APP_VERSION}" | tr -c 'a-zA-Z0-9.' '-' | sed 's/-*$//')"
    WORK_DIR="$(mktemp -d "/tmp/passportprime_${safe_ver}_${APP_ARCH}_XXXXXX")"
    mkdir -p "${WORK_DIR}/out"
    log_info "Script version: ${SCRIPT_VERSION}"
    log_info "Script sha256: $(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
    log_info "App: ${APP_ID} ${APP_VERSION} (${APP_ARCH}, ${APP_TYPE})"
    log_info "Work dir: ${WORK_DIR}"

    if [[ -n "${BINARY_PATH}" ]]; then
        stage_provided_binaries
    fi

    write_dockerfile
    write_comparison_lib
    write_inner_script
    # Keep out/ (and any provided binaries) out of the image build context.
    echo "out/" > "${WORK_DIR}/.dockerignore"

    IMAGE_TAG="passportprime-build-$$-$(date +%s):${safe_ver}"
    local build_args=(--build-arg "NIX_IMAGE=${NIX_IMAGE}" --build-arg "KEYOS_REF=v${APP_VERSION}")
    [[ "${NO_CACHE}" == true ]] && build_args+=(--no-cache)
    log_info "Building container image ${IMAGE_TAG} (first run: ~30-60 min; Nix env download dominates)..."
    "${DOCKER_CMD}" build -t "${IMAGE_TAG}" "${build_args[@]}" -f "${WORK_DIR}/Dockerfile" "${WORK_DIR}"

    log_info "Running firmware build + comparison in container (~30-90 min)..."
    # Invoke via 'bash' on PATH rather than relying on the script's shebang:
    # the nixos/nix base image has no /bin/bash (it ships /bin/sh -> bash and
    # bash on PATH via the nix profile), so a direct exec of #!/bin/bash fails.
    log_info "Cargo parallelism capped at ${CARGO_JOBS} job(s) to bound peak RAM (override with CARGO_JOBS)"
    "${DOCKER_CMD}" run --rm \
        -v "${WORK_DIR}/out:/out" \
        -e KEYOS_VERSION="${APP_VERSION}" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN}" \
        -e CARGO_BUILD_JOBS="${CARGO_JOBS}" \
        "${IMAGE_TAG}" bash /usr/local/bin/inner_build.sh

    # ---- verdict ----
    local out="${WORK_DIR}/out"
    if [[ ! -f "${out}/RESULT.env" ]]; then
        # Explicit exit paths bypass the ERR trap, so write the YAML here too.
        log_fail "RESULT.env missing"
        write_yaml "ftbfs" "Inner build finished without producing RESULT.env; no comparison result is available. Work dir: ${WORK_DIR}"
        cleanup_image
        exit "${EXIT_BUILD_FAILED}"
    fi
    # shellcheck disable=SC1091
    source "${out}/RESULT.env"

    local verdict
    if [[ "${TOTAL}" -gt 0 && "${MISMATCHED}" -eq 0 && "${MISSING}" -eq 0 && "${MISSING_IN_BUILD:-0}" -eq 0 ]]; then
        verdict="reproducible"
    else
        verdict="not_reproducible"
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         Foundation Devices (KeyOS-Releases, branch ${APP_VERSION})"
    echo "versionName:    ${APP_VERSION}"
    echo "arch:           ${APP_ARCH}"
    echo "type:           ${APP_TYPE}"
    echo "verdict:        ${verdict}"
    echo "commit:         ${COMMIT}"
    echo "compiled:       ${C_MATCHED}/${C_TOTAL} matched (${C_MISMATCHED} mismatched, ${C_MISSING} missing)"
    echo "assets+manifests: ${A_MATCHED}/${A_TOTAL} matched (${A_MISMATCHED} mismatched, ${A_MISSING} missing)"
    echo "total verified: ${MATCHED}/${TOTAL} matched (${MISMATCHED} mismatched, ${MISSING} missing); excluded: ${EXCLUDED} (bootloader)"
    echo "official members absent from build: ${MISSING_IN_BUILD:-0} (reverse closure: ${CLOSURE:-unverified}; out-of-scope composites: ${OOS_OFFICIAL:-0}; unclassified: ${UNKNOWN_OFFICIAL:-0})"
    echo "provided (--binary) artifacts used as comparand: ${PROVIDED_USED:-0}"
    echo ""
    echo "Full per-member comparison table (COMPILED entries hashed after the 2048-byte cosign2 signature header, vendor convention):"
    # The COMPLETE table goes into the cast: ABS publishes only the recording
    # and deletes the build dir on a reproducible verdict, so a hash pointer
    # alone is not auditable evidence (2026-07-29 codex review, finding 4).
    # Bounded output: ~130 lines for KeyOS 1.2.1/1.3.0.
    cat "${out}/comparison-hashes.txt"
    echo ""
    echo "Source-derived manifests & assets: ${A_MATCHED}/${A_TOTAL} matched (app permission manifests, fonts, icons, boot/UI assets)."
    echo "Bootloader: excluded by vendor design. boot.bin is the plaintext build output carrying a secret 32-byte EXTRA_ENTROPY; boot.cip is its separately encrypted, shipped form. No public comparand, so it is not verified here."
    echo "Not covered: raw Factory image bytes (MBR/FAT metadata, layout), the distributed OTA update package (release.tar/Update.tar), packaged composite GitHub release assets."
    echo "Full per-member evidence table: ${out}/comparison-hashes.txt (sha256: $(sha256sum "${out}/comparison-hashes.txt" | cut -d' ' -f1))"
    echo "===== End Results ====="
    echo ""

    # The closure sentence must not overclaim: when the reverse pass could not
    # run, the YAML says so and the coverage claim downgrades to forward-only.
    local closure_note
    case "${CLOSURE:-unverified}" in
        ok)
            closure_note="Reverse closure ok: branch inventory checked, every member classified; boot-image members absent from build: ${MISSING_IN_BUILD:-0}; composite/OTA members out of scope by disclosed boundary: ${OOS_OFFICIAL:-0}." ;;
        needs_review)
            closure_note="Reverse closure NEEDS REVIEW: ${UNKNOWN_OFFICIAL:-0} unclassified official release member(s) (see UNKNOWN_OFFICIAL lines in the comparison table). Treat this result as forward-only; DO NOT publish until each unclassified member is reviewed and the classifier updated." ;;
        *)
            closure_note="Reverse closure UNVERIFIED (tree listing unavailable): this run establishes the forward comparison only — an official member absent from the build would not have been detected." ;;
    esac

    local notes="Vendor Nix recipe (REPRODUCIBILITY.md) run in a pinned ${NIX_IMAGE} container. All non-bootloader file members of the locally assembled boot.img compared against the corresponding loose files in the KeyOS-Releases version branch. ${closure_note}
Compiled firmware: ${C_MATCHED}/${C_TOTAL} matched (app.bin, recovery.bin, app ELFs; hashed after the 2048-byte cosign2 header per vendor docs).
Source-derived manifests & assets: ${A_MATCHED}/${A_TOTAL} matched. Provided (--binary) artifacts used as comparand: ${PROVIDED_USED:-0}.
Not covered by this verdict: raw Factory image bytes (MBR/FAT metadata, partition layout), the user-distributed OTA update package (release.tar/Update.tar), and packaged composite GitHub release assets. Bootloader excluded by vendor design: boot.bin is the plaintext build output carrying a secret 32-byte EXTRA_ENTROPY, and boot.cip is its separately encrypted shipped form; the production entropy is not public, so no comparand exists for either (root-of-trust caveat).
Full per-member table: comparison-hashes.txt. On mismatch, vendor recommends an aarch64 rebuild before drawing conclusions."
    write_yaml "${verdict}" "${notes}"
    cleanup_image

    log_info "Artifacts kept in ${WORK_DIR}/out (hashes, comparison table, official binaries, vendor print-hashes output)"
    if [[ "${verdict}" == "reproducible" ]]; then
        exit "${EXIT_SUCCESS}"
    fi
    exit "${EXIT_BUILD_FAILED}"
}

# Sourcing the script (for tests) loads functions without running a build.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
