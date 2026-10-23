#!/bin/bash
# passportprime_build.sh - Foundation Passport Prime (KeyOS) reproducible build verification
# Version: v0.7.0 · Organization: WalletScrutiny.com · License: MIT
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-23
# Disclaimer: for reproducible-build verification only; no warranty; runs containers and
#   downloads source; you are responsible for lawful use. Read the script before running it.
# Steps: build KeyOS v<version> with the vendor's pinned Nix recipe in a container, extract the
#   boot.img members and compare them both ways with the KeyOS release assets (signed files are
#   authenticated, then hashed after their 2048-byte cosign2 header). Out of scope: bootloader
#   (no public plaintext production boot.bin), raw Factory image, OTA Update.tar.
# Exit 0 reproducible, 1 not/ftbfs/failure, 2 invalid, 130 stop. Host needs only docker or podman.

set -eE

SCRIPT_VERSION="v0.7.0"
APP_ID="passportprime"
_src="${BASH_SOURCE[0]}"
if [[ "$_src" == */* ]]; then _srcDir="${_src%/*}"; else _srcDir="."; fi
SCRIPT_DIR="$(cd "$_srcDir" && pwd -P)"
SCRIPT_NAME="${_src##*/}"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
KEYOS_REPO="https://github.com/Foundation-Devices/KeyOS.git"
NIX_IMAGE="docker.io/nixos/nix:2.31.5@sha256:4ae3542b89e38bf739a98d9e1ffd082c3c7b8a6455ec0c2331560b9440aec442"
SUPPORTED_ARCH="armv7a"
SUPPORTED_TYPE="firmware"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

APP_VERSION=""
APP_ARCH="${SUPPORTED_ARCH}"
APP_TYPE="${SUPPORTED_TYPE}"
BINARY_PATH=""
NO_CACHE=false
# Cap cargo jobs to bound peak RAM; job count never changes output bytes.
CARGO_JOBS="${CARGO_JOBS:-4}"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
CONTAINER_CMD=""
ROOTFUL=false
WORK_DIR=""
IMAGE_TAG=""
SCRIPT_SHA256="N/A"
RUN_ID="$(printf '%(%s)T' -1)-$$"
RESULTS_WRITTEN=false

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_fail() { echo "[FAIL] $*" >&2; }

# emit: prints stdin unchanged (bash builtins only; replaces cat on the host)
emit() { local c=""; IFS= read -r -d '' c || true; printf '%s' "$c"; }

# Podman runs with cgroupfs, never systemd: a systemd scope can fall back to the system bus and
# raise a polkit password prompt, and a headless account may have no user session.
engine() {
  if [[ "$CONTAINER_CMD" == "podman" ]]; then podman --cgroup-manager=cgroupfs "$@"; else docker "$@"; fi
}

write_yaml() {   # exactly 3 fields; printf only
  local verdict="$1" notes="$2" f
  for f in "$RESULTS_FILE" "${WORK_DIR}/results_${RUN_ID}.yaml"; do
    [[ "$f" == "$RESULTS_FILE" || -d "$WORK_DIR" ]] || continue
    printf 'script_version: %s\nverdict: %s\nnotes: |\n  %s\n' "$SCRIPT_VERSION" "$verdict" "${notes//$'\n'/$'\n  '}" > "$f"
  done
  RESULTS_WRITTEN=true
  log_info "COMPARISON_RESULTS.yaml written to ${SCRIPT_DIR} (verdict: ${verdict})"
}

comparison_verdict() { # total mismatched missing missing_in_build
  if [[ "$1" -gt 0 && "$2" -eq 0 && "$3" -eq 0 && "$4" -eq 0 ]]; then echo "reproducible"; else echo "not_reproducible"; fi
}

# no_verdict: a failure that says nothing about the source (runtime, network, downloads, a
# blocked authentication). Writes no YAML, so ABS publishes nothing.
no_verdict() {
  log_fail "$1"
  log_fail "No verdict written (this is not a build failure of the source)."
  exit "$EXIT_FAIL"
}

die_invalid() { log_fail "$1"; exit "$EXIT_INVALID"; }

handle_err() {
  local rc=$?
  trap - ERR
  no_verdict "unexpected error (exit ${rc}) during verification"
}

# Hand the workspace back to the caller and check for foreign-owned files, both in a container.
hand_back() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" && -n "$CONTAINER_CMD" ]] || return 0
  local foreign=""
  if [[ "$ROOTFUL" == true ]]; then
    engine run --rm -v "${WORK_DIR}:/w" "$NIX_IMAGE" chown -R "${UID}:${GROUPS[0]}" /w >/dev/null 2>&1 || true
    foreign="$(engine run --rm -v "${WORK_DIR}:/w" "$NIX_IMAGE" find /w ! -uid "$UID" -print -quit 2>/dev/null || true)"
  elif [[ "$CONTAINER_CMD" == "podman" ]]; then
    podman unshare chown -R 0:0 "$WORK_DIR" >/dev/null 2>&1 || true
    foreign="$(engine run --rm -v "${WORK_DIR}:/w" "$NIX_IMAGE" find /w ! -uid 0 -print -quit 2>/dev/null || true)"
  fi
  [[ -z "$foreign" ]] || log_warn "Foreign-owned workspace entry: ${foreign}"
}

cleanup() {
  local rc=$?
  trap - ERR
  if [[ -n "$CONTAINER_CMD" ]]; then
    engine rm -f "passportprime-run-${RUN_ID}" >/dev/null 2>&1 || true
    hand_back
    # Run-specific tag only; the layer cache stays for later runs.
    [[ -z "$IMAGE_TAG" ]] || engine rmi "$IMAGE_TAG" >/dev/null 2>&1 || true
  fi
  [[ "$RESULTS_WRITTEN" == true ]] || log_warn "No COMPARISON_RESULTS.yaml written for this run."
  echo "Exit code: ${rc}"
}

usage() {
  emit <<USAGE
passportprime_build.sh ${SCRIPT_VERSION} - Foundation Passport Prime (KeyOS) reproducible build verifier

  ${SCRIPT_NAME} --version VERSION [--arch ${SUPPORTED_ARCH}] [--type ${SUPPORTED_TYPE}] [--binary PATH]

  --version VERSION  KeyOS version without 'v' (e.g. 1.4.1); source = tag vVERSION. Required.
  --binary PATH      Optional official file or directory: the release bundles
                     KeyOS-vVERSION-Recovery.bin / -CoreSystemRecovery.bin (checked against their
                     published .sha256), or members app.bin, recovery.bin, gui-app-*.elf
                     (or gui-app-*/app.elf). Anything not provided is downloaded.
  --arch ARCH        Only ${SUPPORTED_ARCH}.     --type TYPE   Only ${SUPPORTED_TYPE}.
  --apk FILE         Alias for --binary.        --no-cache    Build the image without cache.

Exit: 0 reproducible, 1 not reproducible / ftbfs / failure with no verdict, 2 invalid, 130 stopped.
First run 60-120 min (Nix toolchain + full firmware build); ~20-25 GB disk for the image.
USAGE
}

parse_arguments() {
  [[ $# -gt 0 ]] || { usage; exit "$EXIT_INVALID"; }
  while [[ $# -gt 0 ]]; do
    case $1 in
      --version) [[ -n "${2:-}" && "${2:-}" != --* ]] || die_invalid "Missing value for $1"; APP_VERSION="$2"; shift 2 ;;
      --binary|--apk) [[ -n "${2:-}" && "${2:-}" != --* ]] || die_invalid "Missing value for $1"; BINARY_PATH="$2"; shift 2 ;;
      --arch)    [[ -n "${2:-}" && "${2:-}" != --* ]] || die_invalid "Missing value for $1"; APP_ARCH="$2"; shift 2 ;;
      --type)    [[ -n "${2:-}" && "${2:-}" != --* ]] || die_invalid "Missing value for $1"; APP_TYPE="$2"; shift 2 ;;
      --no-cache) NO_CACHE=true; shift ;;
      --help|-h) usage; exit "$EXIT_OK" ;;
      *) log_warn "Unknown argument: $1 (ignored)"; shift ;;
    esac
  done
  # Fatal by design: rewriting these would publish a run under a target it did not build.
  [[ "$APP_ARCH" == "$SUPPORTED_ARCH" ]] || die_invalid "Unsupported --arch '${APP_ARCH}' (only ${SUPPORTED_ARCH})"
  [[ -z "$APP_TYPE" || "$APP_TYPE" == "$SUPPORTED_TYPE" ]] || die_invalid "Unsupported --type '${APP_TYPE}' (only ${SUPPORTED_TYPE})"
  [[ -n "$APP_VERSION" ]] || die_invalid "--version is required (e.g. --version 1.4.1)"
  [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_invalid "Invalid --version '${APP_VERSION}' (expected X.Y.Z)"
  if [[ -n "$BINARY_PATH" ]]; then
    [[ "$BINARY_PATH" == /* ]] || BINARY_PATH="${PWD}/${BINARY_PATH}"
    [[ -e "$BINARY_PATH" ]] || die_invalid "--binary path not found: ${BINARY_PATH}"
    # Fail fast on names the container would reject, before the long image build (bash only).
    local ok=0 f
    if [[ -d "$BINARY_PATH" ]]; then
      shopt -s globstar nullglob
      for f in "$BINARY_PATH"/**; do [[ -f "$f" ]] && accepted_name "$f" && ok=1 && break; done
      shopt -u globstar nullglob
    else
      accepted_name "$BINARY_PATH" && ok=1
    fi
    (( ok )) || die_invalid "--binary: no usable official file (KeyOS-v${APP_VERSION}-Recovery.bin, -CoreSystemRecovery.bin, app.bin, recovery.bin or gui-app-*.elf)"
  fi
}

accepted_name() { # $1=path
  local b="${1##*/}" p="${1%/*}"
  case "$b" in
    "KeyOS-v${APP_VERSION}-Recovery.bin"|"KeyOS-v${APP_VERSION}-CoreSystemRecovery.bin"|app.bin|recovery.bin|gui-app-*.elf) return 0 ;;
    app.elf) [[ "${p##*/}" == gui-app-* ]] ;;
    *) return 1 ;;
  esac
}

# Comparison library: pure mapping/classification helpers used by inner_build.sh.
write_comparison_lib() {
  emit > "${WORK_DIR}/comparison_lib.sh" <<'LIB_EOF'
#!/bin/bash
# Per vendor REPRODUCIBILITY.md: signed binaries carry a 2048-byte cosign2 header.
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
        recovery.bin|keyos/app.bin|keyos/apps/*/app.elf|keyos/apps/*/manifest.json) return 0 ;;
        *) return 1 ;;
    esac
}

# Trust policy from KeyOS commit 9056b480, utils/fw-utils/src/hash.rs KNOWN_SIGNERS (L14-36):
# github.com/Foundation-Devices/KeyOS/blob/9056b4805315cad3a8dd58f7c7d06a08e27a1a31/utils/fw-utils/src/hash.rs#L14-L36
is_known_signer() {
    case "$1" in
        03bf014e1a37a113089bea7b50ee9bd7733189ecd6afb7e051a6e95f99b97da5e9|\
        03040e47c1cde8978085bdc8b44df85e7c0b2e1ea586697b5d385e523d3f908bc3|\
        038de8dd1cbad8bf1da7ff64b8a9b4a375f0205eff41f7f9dca8e91c4cf0951daa|\
        03cb8e4219d3c8f269ab2ed3acb71a4b1722c76a0c348ea11fa79b4639bef45094) return 0 ;;
        *) return 1 ;;
    esac
}

signature_is_source_trusted() { # magic pubkey1 pubkey2
    [[ "$1" == atsama5d27-keyos && "$2" != "$3" ]] && is_known_signer "$2" && is_known_signer "$3"
}

verification_state_for() { # authentication-failures unknown-official
    if (( $1 > 0 )); then echo AUTHENTICATION_FAILED
    elif (( $2 > 0 )); then echo SCOPE_REVIEW_REQUIRED
    else echo COMPLETE
    fi
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

# Reverse-closure classifier (positive): only boot-image member paths are compared; composite/OTA
# artifacts are a disclosed boundary; anything unrecognised needs human review.
closure_class_for() {  # $1 -> compare|bootloader|out_of_scope|unknown
    case "$1" in
        boot.bin|boot.cip|boot-signed.cip)                echo bootloader ;;
        recovery.bin|blassets/*|common-boot/*|keyos/*)    echo compare ;;
        KeyOS-v*-Factory.img)                             echo out_of_scope ;;
        KeyOS-v*-Recovery.bin|KeyOS-v*-CoreSystemRecovery.bin) echo out_of_scope ;;
        KeyOS-v*Update.tar|envoy-server/*)                echo out_of_scope ;;
        v[0-9]*-v[0-9]*.zip)                              echo out_of_scope ;;
        manifest.json.*)                                  echo out_of_scope ;;
        *)                                                 echo unknown ;;
    esac
}
LIB_EOF
}

# Dockerfile: pinned Nix image, vendor source at the release tag, build environment pre-realized.
write_dockerfile() {
  emit > "${WORK_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
ARG NIX_IMAGE
FROM ${NIX_IMAGE}
ARG KEYOS_REF
# Flakes on; Nix sandbox off (not available in a rootless container). flake.lock pins the inputs.
RUN mkdir -p /etc/nix && \
    printf 'experimental-features = nix-command flakes\nsandbox = false\n' >> /etc/nix/nix.conf
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
# refs/tags/ is explicit: a bare ref name resolves a same-named branch first.
RUN git clone --recurse-submodules https://github.com/Foundation-Devices/KeyOS.git /keyos && \
    cd /keyos && \
    git rev-parse --verify "refs/tags/${KEYOS_REF}" >/dev/null && \
    git checkout --detach "refs/tags/${KEYOS_REF}" && \
    git submodule update --init --recursive && \
    git rev-parse HEAD > /keyos_commit.txt && \
    git cat-file -t "refs/tags/${KEYOS_REF}" > /keyos_tagtype.txt && \
    t="$(git cat-file -p "refs/tags/${KEYOS_REF}")" && \
    case "$t" in *"BEGIN SSH SIGNATURE"*) echo ssh ;; *"BEGIN PGP SIGNATURE"*) echo pgp ;; *) echo none ;; esac > /keyos_tagsig.txt && \
    c="$(git cat-file -p HEAD)" && \
    case "$c" in *gpgsig*) echo yes ;; *) echo no ;; esac > /keyos_commitsig.txt
WORKDIR /keyos
# Pre-realize the pinned toolchain and crates (the big downloads), so the run step only builds.
RUN nix develop .#build --command true
RUN nix develop .#build --command cargo fetch
COPY comparison_lib.sh /usr/local/bin/comparison_lib.sh
COPY inner_build.sh /usr/local/bin/inner_build.sh
RUN chmod +x /usr/local/bin/comparison_lib.sh /usr/local/bin/inner_build.sh
# The nixos/nix image has no /bin/bash; vendor scripts use #!/bin/bash.
RUN ln -sf /bin/sh /bin/bash
DOCKERFILE_EOF
}

# Inner script (in the container). Exit 0 compared, 3 no verdict (download, authentication,
# tooling), 4 ftbfs (the source did not build), 5 invalid --binary input; anything else: no verdict.
write_inner_script() {
  emit > "${WORK_DIR}/inner_build.sh" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
OUT=/out
TARGET_DIR="target/armv7a-unknown-xous-elf/release"
AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
. /usr/local/bin/comparison_lib.sh

block_verification() { # state detail
    printf 'state=%s\ndetail=%s\n' "$1" "$2" > "${OUT}/verification-state.txt"
    echo "[BUILD] BLOCKED ($1): $2"; exit 3
}
bad_input() { echo "[BUILD] INVALID --binary: $1"; exit 5; }

cd /keyos
expected_commit="$(cat /keyos_commit.txt)"
actual_commit="$(git rev-parse HEAD)"
[ "${expected_commit}" = "${actual_commit}" ] || block_verification VERIFICATION_ERROR "commit mismatch (expected ${expected_commit}, got ${actual_commit})"
echo "${actual_commit}" > "${OUT}/commit.txt"
cp /keyos_tagtype.txt /keyos_tagsig.txt /keyos_commitsig.txt "${OUT}/"
echo "[BUILD] Source: tag v${KEYOS_VERSION} = ${actual_commit}"

# Provided official files (--binary, mounted read-only at /provided-src): release bundles go to the
# release dir (still checked against their published .sha256), members to /out/provided.
RELEASE_DIR="$(mktemp -d /tmp/keyos-release.XXXXXX)"
RELEASE_TREE="${RELEASE_DIR}/tree"
mkdir -p "${RELEASE_TREE}" "${OUT}/provided"
stage() { # $1=file
    local b; b="$(basename "$1")"
    case "${b}" in
        "KeyOS-v${KEYOS_VERSION}-Recovery.bin"|"KeyOS-v${KEYOS_VERSION}-CoreSystemRecovery.bin") dst="${RELEASE_DIR}/${b}" ;;
        app.bin|recovery.bin|gui-app-*.elf) dst="${OUT}/provided/${b}" ;;
        app.elf) p="$(basename "$(dirname "$1")")"
                 case "${p}" in gui-app-*) dst="${OUT}/provided/${p}.elf" ;; *) bad_input "cannot name ${1} (parent dir not gui-app-*)" ;; esac ;;
        *) return 1 ;;
    esac
    [ ! -e "${dst}" ] || bad_input "two files map to $(basename "${dst}")"
    cp "$1" "${dst}"; echo "[BUILD] Provided: ${b}"
}
if [ -d /provided-src ]; then
    staged=0
    while IFS= read -r -d '' f; do stage "$f" && staged=$((staged+1)) || true; done < <(find /provided-src -type f -print0)
    [ "${staged}" -gt 0 ] || bad_input "no usable official file in the directory"
elif [ -f /provided-src.bin ]; then
    # A single file keeps its original name in PROVIDED_NAME.
    mkdir -p /tmp/single && cp /provided-src.bin "/tmp/single/${PROVIDED_NAME}"
    stage "/tmp/single/${PROVIDED_NAME}" || bad_input "unrecognized file name '${PROVIDED_NAME}'"
fi

# Official release bundles: download what was not provided; check each against its .sha256.
RELEASE_ASSET_BASE="https://github.com/Foundation-Devices/KeyOS/releases/download/v${KEYOS_VERSION}"
: > "${OUT}/release-asset-hashes.txt"
for bundle in Recovery.bin CoreSystemRecovery.bin; do
    fname="KeyOS-v${KEYOS_VERSION}-${bundle}"
    if [ ! -f "${RELEASE_DIR}/${fname}" ]; then
        curl -fsSL "${AUTH_ARGS[@]}" -o "${RELEASE_DIR}/${fname}" "${RELEASE_ASSET_BASE}/${fname}" \
            || block_verification VERIFICATION_ERROR "could not download ${fname}"
    fi
    curl -fsSL "${AUTH_ARGS[@]}" -o "${RELEASE_DIR}/${fname}.sha256" "${RELEASE_ASSET_BASE}/${fname}.sha256" \
        || block_verification VERIFICATION_ERROR "could not download ${fname}.sha256"
    published_hash="$(cut -d' ' -f1 "${RELEASE_DIR}/${fname}.sha256")"
    actual_hash="$(sha256sum "${RELEASE_DIR}/${fname}" | cut -d' ' -f1)"
    [ "${published_hash}" = "${actual_hash}" ] \
        || block_verification VERIFICATION_ERROR "${fname} sha256 mismatch: got ${actual_hash}, expected ${published_hash}"
    printf '%s %s\n' "${fname}" "${actual_hash}" >> "${OUT}/release-asset-hashes.txt"
    tar -xf "${RELEASE_DIR}/${fname}" -C "${RELEASE_TREE}"
    # The bundles carry different manifests; rename so extraction cannot clobber one.
    manifest_path="${RELEASE_TREE}/${KEYOS_VERSION}/manifest.json"
    [ -f "${manifest_path}" ] && mv "${manifest_path}" "${manifest_path}.${bundle%.bin}"
done
: > "${OUT}/official-inventory.txt"
while IFS= read -r -d '' f; do
    printf '%s\n' "${f#"${RELEASE_TREE}"/}" >> "${OUT}/official-inventory.txt"
done < <(find "${RELEASE_TREE}" -type f -print0)
[ -s "${OUT}/official-inventory.txt" ] || block_verification VERIFICATION_ERROR "empty inventory"
RELEASE_PIN="$(paste -sd';' "${OUT}/release-asset-hashes.txt")"
echo "[BUILD] Comparands: KeyOS release assets v${KEYOS_VERSION} (${RELEASE_PIN})"

COSIGN_PROBE="${OUT}/cosign2-probe.bin"; printf x > "${COSIGN_PROBE}"
nix develop .#build --command cosign2 dump --input "${COSIGN_PROBE}" >/dev/null 2>&1 \
    || block_verification VERIFICATION_ERROR "vendor devshell does not provide cosign2"
rm -f "${COSIGN_PROBE}"

# [1/4] build with the vendor recipe (throwaway signing key; the comparison ignores the header).
# Keep this single-quoted block free of apostrophes: one closes the quote (v0.6.0 bug).
if ! nix develop .#build --command bash -c '
    set -euo pipefail
    scripts/generate-cosign2-dev-key.sh
    KEYOS_VERSION_ARG=()
    if cargo xtask build-all --help 2>&1 | grep -q -- "--keyos-version"; then
        KEYOS_VERSION_ARG=(--keyos-version "$KEYOS_VERSION")
    fi
    cargo xtask build-all --production-bootloader --production-firmware "${KEYOS_VERSION_ARG[@]}"
    cargo xtask print-hashes
' > "${OUT}/build-log.txt" 2>&1; then
    tail -50 "${OUT}/build-log.txt"; echo "[BUILD] FAIL: cargo xtask build-all failed"; exit 4
fi
tail -50 "${OUT}/build-log.txt"
grep -c SKIP "${OUT}/build-log.txt" > "${OUT}/skip-count.txt" || true
nix develop .#build --command cargo xtask print-hashes > "${OUT}/print-hashes.txt" 2>/dev/null || true

# [2/4] locate the built boot.img (it holds every release member).
for img in app.bin recovery.bin; do
    [ -f "${TARGET_DIR}/images/${img}" ] || { echo "[BUILD] FAIL: missing built ${img}"; exit 4; }
done
BOOT_IMG=""
for cand in boot.img "${TARGET_DIR}/boot.img" out/boot.img images/boot.img; do
    [ -f "${cand}" ] && BOOT_IMG="${cand}" && break
done
[ -n "${BOOT_IMG}" ] || { echo "[BUILD] FAIL: built boot.img not found"; exit 4; }
echo "[BUILD] Built firmware image: ${BOOT_IMG} ($(stat -c%s "${BOOT_IMG}") bytes)"

# [3/4] extract the boot (offset 512) and system (offset 268435456) FAT partitions. mtools comes
# from the nixpkgs revision the vendor flake.lock pins (registry nixpkgs if it cannot be resolved).
NIXPKGS_REV="$(nix eval --raw --impure --expr 'let l = builtins.fromJSON (builtins.readFile "/keyos/flake.lock"); r = l.nodes.${l.root}.inputs.nixpkgs; key = if builtins.isString r then r else "nixpkgs"; lk = l.nodes.${key}.locked; in if lk.type == "github" && lk.owner == "NixOS" && lk.repo == "nixpkgs" then lk.rev else ""' 2>/dev/null || true)"
MTOOLS_FLAKE="nixpkgs"; [ -n "${NIXPKGS_REV}" ] && MTOOLS_FLAKE="github:NixOS/nixpkgs/${NIXPKGS_REV}"
{ echo "mtools_flake=${MTOOLS_FLAKE}"; nix shell "${MTOOLS_FLAKE}#mtools" --command mcopy -V 2>/dev/null | head -1 || true; } > "${OUT}/tooling.txt"
EX="${OUT}/built-members"
rm -rf "${EX}"; mkdir -p "${EX}/boot" "${EX}/system"
nix shell "${MTOOLS_FLAKE}#mtools" --command mcopy -s -n -i "${BOOT_IMG}@@512" ::/ "${EX}/boot/" \
    || block_verification VERIFICATION_ERROR "mtools extraction of the boot partition failed"
nix shell "${MTOOLS_FLAKE}#mtools" --command mcopy -s -n -i "${BOOT_IMG}@@268435456" ::/ "${EX}/system/" \
    || block_verification VERIFICATION_ERROR "mtools extraction of the system partition failed"
echo "[BUILD] Extracted members: $(find "${EX}" -type f | wc -l) (mtools from ${MTOOLS_FLAKE})"

# [4/4] compare every member with the release, both ways. COMPILED = cosign2-signed members.
mkdir -p "${OUT}/official"
c_total=0; c_match=0; c_mis=0; c_miss=0
a_total=0; a_match=0; a_mis=0; a_miss=0
excluded=0; provided_used=0; signature_verified=0; authentication_failed=0
declare -A COMPARED
: > "${OUT}/comparison-hashes.txt"; : > "${OUT}/provided-used.txt"; : > "${OUT}/bootloader-hashes.txt"
: > "${OUT}/official-downloaded-hashes.txt"; : > "${OUT}/signature-verification.txt"

verify_official_signature() { # $1=release path $2=file
    local relp="$1" file="$2" dump="" field value p1="" p2="" magic=""
    if ! dump="$(nix develop .#build --command cosign2 dump --input "${file}" 2>&1)"; then
        echo "FAILED ${relp} invalid_cosign2" >> "${OUT}/signature-verification.txt"; return 1
    fi
    while read -r field value _; do
        case "${field}" in magic) magic="${value}" ;; pubkey1) p1="${value}" ;; pubkey2) p2="${value}" ;; esac
    done <<< "${dump}"
    if ! signature_is_source_trusted "${magic}" "${p1}" "${p2}"; then
        echo "FAILED ${relp} magic=${magic:-missing} pubkey1=${p1:-missing} pubkey2=${p2:-missing}" >> "${OUT}/signature-verification.txt"; return 1
    fi
    echo "VERIFIED ${relp} pubkey1=${p1} pubkey2=${p2}" >> "${OUT}/signature-verification.txt"
    signature_verified=$((signature_verified+1))
}
count() { # $1=class $2=field
    if [ "$1" = COMPILED ]; then c_total=$((c_total+1)); eval "c_$2=\$((c_$2+1))"; else a_total=$((a_total+1)); eval "a_$2=\$((a_$2+1))"; fi
}
while IFS= read -r -d '' f; do
    case "${f}" in "${EX}/boot/"*) part=boot ;; "${EX}/system/"*) part=system ;; *) continue ;; esac
    rel="${f#"${EX}/${part}/"}"
    relp="$(release_path_for "${part}" "${rel}")"
    if [ -z "${relp}" ]; then
        echo "EXCLUDED bootloader ${part}/${rel} (no like-for-like public plaintext production artifact)" >> "${OUT}/comparison-hashes.txt"
        printf '%s %s %s\n' "${rel}" "$(stat -c%s "${f}")" "$(sha256sum "${f}" | cut -d' ' -f1)" >> "${OUT}/bootloader-hashes.txt"
        excluded=$((excluded+1)); continue
    fi
    COMPARED["${relp}"]=1
    if is_signed "${relp}"; then cls=COMPILED; else cls=ASSET; fi
    built_hash="$(member_hash "${relp}" "${f}")"
    safe="$(printf '%s' "${relp}" | tr '/' '_')"
    src=downloaded
    prov="$(provided_name_for "${relp}")"
    if [ -n "${prov}" ] && [ -f "${OUT}/provided/${prov}" ]; then
        cp "${OUT}/provided/${prov}" "${OUT}/official/${safe}"; src=provided
        provided_used=$((provided_used+1)); echo "${prov}" >> "${OUT}/provided-used.txt"
    else
        src_path="${RELEASE_TREE}/${KEYOS_VERSION}/${relp}"
        if [ ! -f "${src_path}" ] || ! cp "${src_path}" "${OUT}/official/${safe}"; then
            echo "MISSING_OFFICIAL ${cls} ${relp}" >> "${OUT}/comparison-hashes.txt"; count "${cls}" miss; continue
        fi
    fi
    if is_signed "${relp}"; then
        if ! verify_official_signature "${relp}" "${OUT}/official/${safe}"; then
            echo "AUTHENTICATION_FAILED COMPILED ${relp} [${src}]" >> "${OUT}/comparison-hashes.txt"
            c_total=$((c_total+1)); authentication_failed=$((authentication_failed+1)); continue
        fi
        printf '%s %s %s\n' "${relp}" "$(stat -c%s "${OUT}/official/${safe}")" \
            "$(sha256sum "${OUT}/official/${safe}" | cut -d' ' -f1)" >> "${OUT}/official-downloaded-hashes.txt"
    fi
    official_hash="$(member_hash "${relp}" "${OUT}/official/${safe}")"
    if [ "${built_hash}" = "${official_hash}" ]; then
        echo "MATCH ${cls} ${relp} ${built_hash} [${src}]" >> "${OUT}/comparison-hashes.txt"; count "${cls}" match
    else
        echo "MISMATCH ${cls} ${relp} built=${built_hash} official=${official_hash} [${src}]" >> "${OUT}/comparison-hashes.txt"; count "${cls}" mis
    fi
done < <(find "${EX}" -type f -print0)

# Every provided member must have been used; otherwise the run never looked at the user's file.
declare -A USED
while IFS= read -r u; do [ -n "${u}" ] && USED["${u}"]=1; done < "${OUT}/provided-used.txt"
for pf in "${OUT}/provided"/*; do
    [ -e "${pf}" ] || continue
    [ -n "${USED[$(basename "${pf}")]:-}" ] || bad_input "provided $(basename "${pf}") matches no built member"
done

# Reverse closure over the release inventory captured before the build.
missing_in_build=0; oos_official=0; unknown_official=0; closure=ok
while IFS= read -r opath || [ -n "${opath}" ]; do
    case "${opath}" in
        "${KEYOS_VERSION}/"*) orel="${opath#"${KEYOS_VERSION}/"}" ;;
        *) echo "UNKNOWN_OFFICIAL ${opath} (outside ${KEYOS_VERSION}/ prefix)" >> "${OUT}/comparison-hashes.txt"
           unknown_official=$((unknown_official+1)); continue ;;
    esac
    case "$(closure_class_for "${orel}")" in
        bootloader) continue ;;
        out_of_scope) echo "OUT_OF_SCOPE ${orel} (disclosed composite/OTA/companion boundary)" >> "${OUT}/comparison-hashes.txt"
                      oos_official=$((oos_official+1)); continue ;;
        unknown) echo "UNKNOWN_OFFICIAL ${orel} (unclassified; human review required)" >> "${OUT}/comparison-hashes.txt"
                 unknown_official=$((unknown_official+1)); continue ;;
    esac
    if [ -z "${COMPARED[${orel}]:-}" ]; then
        echo "MISSING_IN_BUILD ${orel} (official boot-image member absent from build)" >> "${OUT}/comparison-hashes.txt"
        missing_in_build=$((missing_in_build+1))
    fi
done < "${OUT}/official-inventory.txt"
(( unknown_official == 0 )) || closure=needs_review

verification_state="$(verification_state_for "${authentication_failed}" "${unknown_official}")"
if [ "${verification_state}" != COMPLETE ]; then
    { printf 'state=%s\nauthentication_failed=%s\nunknown_official=%s\n' "${verification_state}" "${authentication_failed}" "${unknown_official}"
      grep -E '^(AUTHENTICATION_FAILED|UNKNOWN_OFFICIAL)' "${OUT}/comparison-hashes.txt" || true
      grep '^FAILED' "${OUT}/signature-verification.txt" || true; } > "${OUT}/verification-state.txt"
fi
grep -E '^(MISMATCH|MISSING_OFFICIAL|MISSING_IN_BUILD|AUTHENTICATION_FAILED)' "${OUT}/comparison-hashes.txt" > "${OUT}/diff.txt" || true

{
    echo "COMMIT=${actual_commit}"
    echo "RELEASE_PIN=\"${RELEASE_PIN}\""
    echo "C_TOTAL=${c_total}"; echo "C_MATCHED=${c_match}"; echo "C_MISMATCHED=${c_mis}"; echo "C_MISSING=${c_miss}"
    echo "A_TOTAL=${a_total}"; echo "A_MATCHED=${a_match}"; echo "A_MISMATCHED=${a_mis}"; echo "A_MISSING=${a_miss}"
    echo "EXCLUDED=${excluded}"; echo "TOTAL=$((c_total+a_total))"; echo "MATCHED=$((c_match+a_match))"
    echo "MISMATCHED=$((c_mis+a_mis))"; echo "MISSING=$((c_miss+a_miss))"; echo "MISSING_IN_BUILD=${missing_in_build}"
    echo "CLOSURE=${closure}"; echo "OOS_OFFICIAL=${oos_official}"; echo "UNKNOWN_OFFICIAL=${unknown_official}"
    echo "PROVIDED_USED=${provided_used}"; echo "SIGNATURE_VERIFIED=${signature_verified}"
    echo "AUTHENTICATION_FAILED=${authentication_failed}"; echo "VERIFICATION_STATE=${verification_state}"
} > "${OUT}/RESULT.env"
echo "[BUILD] Compiled ${c_match}/${c_total} matched, assets ${a_match}/${a_total}, excluded (bootloader) ${excluded}, absent from build ${missing_in_build}, unclassified ${unknown_official}"
echo "[BUILD] inner build complete"
INNER_EOF
}

main() {
  trap handle_err ERR
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  # Never write the privilege-escalation command's name as a word in this file (ABS refuses it).
  (( EUID != 0 )) || die_invalid "Do not run this script as root."

  echo "=============================================================================="
  echo "DISCLAIMER: examine this script before running it. Provided as-is, without warranty; it may"
  echo "contain bugs. It runs Docker/Podman containers, downloads source and builds firmware, using"
  echo "significant CPU, memory and disk (~20-25 GB). Use at your own risk."
  echo "=============================================================================="

  local c
  for c in docker podman; do
    if command -v "$c" >/dev/null 2>&1 && "$c" info >/dev/null 2>&1; then CONTAINER_CMD="$c"; break; fi
  done

  # Self-identification before argument parsing, hashed in the pinned image (N/A on failure).
  if [[ -n "$CONTAINER_CMD" ]]; then
    local out
    out="$(engine run --rm -v "${SCRIPT_PATH}:/s.sh:ro" "$NIX_IMAGE" sha256sum /s.sh </dev/null 2>/dev/null || true)"
    [[ "${out%% *}" =~ ^[0-9a-f]{64}$ ]] && SCRIPT_SHA256="${out%% *}"
  fi
  log_info "Script: ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  log_info "        sha256: ${SCRIPT_SHA256}"

  # One run per script folder (runs share COMPARISON_RESULTS.yaml); flock is optional.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${SCRIPT_DIR}/.comparison_results.lock"
    flock -n 9 || no_verdict "another verification is already running from ${SCRIPT_DIR}; run this one after it or from a copy in another folder"
  fi
  # A failed or invalid run must never leave an earlier verdict in place.
  rm -f -- "$RESULTS_FILE"

  [[ -n "$CONTAINER_CMD" ]] || no_verdict "no working docker or podman found (the only host requirement)"
  log_info "Container engine: ${CONTAINER_CMD}"
  parse_arguments "$@"
  if [[ "$CONTAINER_CMD" == "docker" ]]; then
    [[ "$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null)" == *rootless* ]] || ROOTFUL=true
  fi

  # A version without a release tag is invalid input, checked before the long image build.
  local tag_rc=0
  engine run --rm "$NIX_IMAGE" git ls-remote --exit-code --tags "$KEYOS_REPO" "refs/tags/v${APP_VERSION}" >/dev/null 2>&1 || tag_rc=$?
  case "$tag_rc" in
    0) ;;
    2) die_invalid "No release tag v${APP_VERSION} in ${KEYOS_REPO}" ;;
    *) no_verdict "Could not look up tag v${APP_VERSION} (network)" ;;
  esac

  # Per-run workspace in the caller's directory, exclusive mkdir; never reused or deleted.
  local wd
  wd="$(pwd -P)/passportprime_verification_${APP_VERSION}_${RUN_ID}"
  mkdir -- "$wd" || die_invalid "Work directory already exists or cannot be created: ${wd}"
  WORK_DIR="$wd"
  mkdir -- "${WORK_DIR}/out"
  log_info "App: ${APP_ID} ${APP_VERSION} (${APP_ARCH}, ${APP_TYPE})"
  log_info "Work dir: ${WORK_DIR}"

  write_dockerfile
  write_comparison_lib
  write_inner_script
  echo "out/" > "${WORK_DIR}/.dockerignore"

  IMAGE_TAG="localhost/passportprime-build:${RUN_ID}"
  local build_args=(--build-arg "NIX_IMAGE=${NIX_IMAGE}" --build-arg "KEYOS_REF=v${APP_VERSION}")
  [[ "$NO_CACHE" != true ]] || build_args+=(--no-cache)
  log_info "Building container image ${IMAGE_TAG} (clone + pinned Nix toolchain + crates; first run ~30-60 min)..."
  engine build -t "$IMAGE_TAG" "${build_args[@]}" -f "${WORK_DIR}/Dockerfile" "$WORK_DIR" \
    || no_verdict "Image build failed (clone, Nix toolchain or crate download) - infrastructure, not the source"

  log_info "Running firmware build + comparison (~30-90 min; cargo jobs capped at ${CARGO_JOBS})..."
  local run_args=(--rm --name "passportprime-run-${RUN_ID}" -v "${WORK_DIR}/out:/out"
    -e "KEYOS_VERSION=${APP_VERSION}" -e "GITHUB_TOKEN=${GITHUB_TOKEN}" -e "CARGO_BUILD_JOBS=${CARGO_JOBS}")
  if [[ -d "$BINARY_PATH" ]]; then
    run_args+=(-v "${BINARY_PATH}:/provided-src:ro")
  elif [[ -n "$BINARY_PATH" ]]; then
    run_args+=(-v "${BINARY_PATH}:/provided-src.bin:ro" -e "PROVIDED_NAME=${BINARY_PATH##*/}")
  fi
  local inner='bash /usr/local/bin/inner_build.sh'
  # Rootful docker: the container writes as root, so hand /out back before it exits.
  # shellcheck disable=SC2016 # expands inside the container
  [[ "$ROOTFUL" != true ]] || inner='bash /usr/local/bin/inner_build.sh; rc=$?; chown -R "$HOST_UID:$HOST_GID" /out; exit $rc'
  local container_rc=0
  ( trap - ERR; engine run "${run_args[@]}" -e "HOST_UID=${UID}" -e "HOST_GID=${GROUPS[0]}" "$IMAGE_TAG" bash -c "$inner" ) &
  wait "$!" || container_rc=$?

  local out="${WORK_DIR}/out" lines=()
  case "$container_rc" in
    0) ;;
    4) write_yaml "ftbfs" "KeyOS v${APP_VERSION}: cargo xtask build-all failed at tag v${APP_VERSION} after the toolchain and sources were prepared."
       exit "$EXIT_FAIL" ;;
    5) die_invalid "--binary input rejected (see the [BUILD] INVALID line above)" ;;
    *) if [[ -s "${out}/verification-state.txt" ]]; then
         mapfile -t lines < "${out}/verification-state.txt"; printf '  %s\n' "${lines[@]}"
       fi
       no_verdict "Verification blocked or failed before a verdict (container exit ${container_rc})" ;;
  esac
  [[ -f "${out}/RESULT.env" ]] || no_verdict "Inner run finished without RESULT.env"
  # shellcheck disable=SC1091
  source "${out}/RESULT.env"

  local verdict="" app_hash="N/A" app_file="" tagtype="unknown" tagsig="unknown" commitsig="unknown" skips="?" n f h
  [[ "${VERIFICATION_STATE:-}" != COMPLETE ]] || verdict="$(comparison_verdict "$TOTAL" "$MISMATCHED" "$MISSING" "${MISSING_IN_BUILD:-0}")"
  # appHash = the release bundle under test: the provided one, else Recovery.bin.
  app_file="KeyOS-v${APP_VERSION}-Recovery.bin"
  [[ "${BINARY_PATH##*/}" != "KeyOS-v${APP_VERSION}-CoreSystemRecovery.bin" ]] || app_file="${BINARY_PATH##*/}"
  while read -r f h; do [[ "$f" != "$app_file" ]] || app_hash="$h"; done < "${out}/release-asset-hashes.txt"
  [[ -f "${out}/keyos_tagtype.txt" ]] && read -r tagtype < "${out}/keyos_tagtype.txt"
  [[ -f "${out}/keyos_tagsig.txt" ]] && read -r tagsig < "${out}/keyos_tagsig.txt"
  [[ -f "${out}/keyos_commitsig.txt" ]] && read -r commitsig < "${out}/keyos_commitsig.txt"
  [[ -f "${out}/skip-count.txt" ]] && read -r skips < "${out}/skip-count.txt"
  case "$tagtype" in tag) tagtype="annotated" ;; commit) tagtype="lightweight" ;; esac

  echo ""
  echo "----- What these hashes mean -----"
  echo "appHash      SHA-256 of the official release file ${app_file} exactly as downloaded and"
  echo "             checked against its published .sha256. THIS is the hash to publish."
  echo "member lines (after End) compare each boot.img member; signed members are hashed after"
  echo "             their 2048-byte cosign2 header. Comparison only; never publish."
  echo "----------------------------------"
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${APP_VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${verdict:-blocked (${VERIFICATION_STATE}; nothing published)}"
  echo "appHash:        ${app_hash}"
  echo "commit:         ${COMMIT}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo ""
  echo "Diff:"
  echo "compiled (signed): ${C_MATCHED}/${C_TOTAL} match (${C_MISMATCHED} mismatched, ${C_MISSING} missing; ${SIGNATURE_VERIFIED:-0} signatures source-trusted, ${AUTHENTICATION_FAILED:-0} failed)"
  echo "assets+manifests:  ${A_MATCHED}/${A_TOTAL} match (${A_MISMATCHED} mismatched, ${A_MISSING} missing)"
  echo "official members absent from build: ${MISSING_IN_BUILD:-0}; unclassified: ${UNKNOWN_OFFICIAL:-0}; excluded: ${EXCLUDED} (bootloader)"
  if [[ -s "${out}/diff.txt" ]]; then
    n=0; while IFS= read -r f; do n=$((n+1)); done < "${out}/diff.txt"
    mapfile -t -n 5 lines < "${out}/diff.txt"
    echo "First differences (${n} in total):"; printf '%s\n' "${lines[@]}"
    echo "Full diff: ${out}/diff.txt"
  fi
  echo ""
  echo "Revision, tag (and its signature):"
  echo "Tag type: ${tagtype} (v${APP_VERSION} -> ${COMMIT})"
  echo "Tag signature: ${tagsig} (presence only; not verified)"
  echo "Commit signed: ${commitsig} (presence only; not verified)"
  echo "===== End Results ====="
  echo ""
  echo "release assets: ${RELEASE_PIN}"
  echo "signature policy: KeyOS 9056b480 utils/fw-utils/src/hash.rs:14-36 (source consistency; not independent identity)"
  echo "provided (--binary) members used as comparand: ${PROVIDED_USED:-0}; upstream log lines with SKIP: ${skips}"
  # The full table stays in the cast: ABS publishes only the recording and deletes the build dir.
  echo "Per-member comparison table (${out}/comparison-hashes.txt):"
  mapfile -t lines < "${out}/comparison-hashes.txt"; printf '%s\n' "${lines[@]}"
  if [[ -s "${out}/official-downloaded-hashes.txt" ]]; then
    echo "Official signed members as downloaded (whole file, cosign2 wrapper included):"
    while read -r f n h; do echo "  ${f}  ${n} bytes  sha256=${h}"; done < "${out}/official-downloaded-hashes.txt"
  fi
  if [[ -s "${out}/bootloader-hashes.txt" ]]; then
    echo "Bootloader of OUR rebuild (informational, not compared; owners can check Boot Menu > System Information):"
    while read -r f n h; do echo "  ${f}  ${n} bytes  sha256=${h}"; done < "${out}/bootloader-hashes.txt"
  fi
  echo "Not covered: bootloader (no public plaintext production boot.bin; boot.cip is encrypted), raw Factory image bytes, the OTA Update.tar."
  echo ""

  local closure_note
  case "${CLOSURE:-unverified}" in
    ok) closure_note="Reverse closure ok: every release member classified; boot-image members absent from build: ${MISSING_IN_BUILD:-0}; composite/OTA members out of scope: ${OOS_OFFICIAL:-0}." ;;
    needs_review) closure_note="Reverse closure NEEDS REVIEW: ${UNKNOWN_OFFICIAL:-0} unclassified release member(s)." ;;
    *) closure_note="Reverse closure unverified." ;;
  esac
  if [[ -z "$verdict" ]]; then
    no_verdict "Publication blocked (${VERIFICATION_STATE}); artifacts kept in ${out}"
  fi
  write_yaml "$verdict" "KeyOS v${APP_VERSION}, vendor Nix recipe in ${NIX_IMAGE%%@*}, commit ${COMMIT}. Comparands: release assets (${RELEASE_PIN}), sha256-checked. ${closure_note}
Compiled: ${C_MATCHED}/${C_TOTAL} matched (${SIGNATURE_VERIFIED:-0} signed by two keys trusted in KeyOS 9056b480 hash.rs:14-36, hashed after the 2048-byte cosign2 header). Assets+manifests: ${A_MATCHED}/${A_TOTAL} matched.
Not covered: bootloader, raw Factory image, OTA Update.tar. On mismatch, the vendor recommends an aarch64 rebuild."
  log_info "Artifacts kept in ${out}"
  [[ "$verdict" != "reproducible" ]] || exit "$EXIT_OK"
  exit "$EXIT_FAIL"
}

# Sourcing the script (for tests) loads the functions without running a build.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
