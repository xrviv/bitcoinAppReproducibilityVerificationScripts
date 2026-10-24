#!/usr/bin/env bash
# onekeyclassic1s_build.sh - OneKey Classic 1S firmware reproducible build verification
# Version: v0.1.0 · Organization: WalletScrutiny.com · License: MIT
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-24
# Disclaimer: for reproducible-build verification only; no warranty; runs containers and
#   downloads source; you are responsible for lawful use. Read the script before running it.
# Steps: fetch the official MCU firmware from the GitHub release (or take --binary) and check
#   it against the release's published sha256; cross-check the file OneKey's update server
#   serves; build tag v<version> (universal) or v<version>-btc (btc-only) in containers the
#   way upstream CI does (Nix 2.23.3, nix-shell, poetry, legacy/script/cibuild, PRODUCTION=1);
#   zero the 260-byte signature area on both and compare; rebuild the bootloader the firmware
#   embeds (bootloader.dat) and compare it too. The secure-element blob (thd89) is closed
#   source and is not verified. Only host need: Docker or Podman.
# Exit 0 reproducible, 1 not reproducible/ftbfs/failure, 2 invalid, 130 stopped. History: changelog.

set -euo pipefail

SCRIPT_VERSION="v0.1.0"
APP_ID="onekey.classic.1s"
REPO_URL="https://github.com/OneKeyHQ/firmware-classic1s"
API_URL="https://api.github.com/repos/OneKeyHQ/firmware-classic1s"
CDN_CONFIG_URL="https://data.onekey.so/config.json"
RESULTS_WRITTEN=false
ENV_IMAGE=""
BUILD_IMAGE=""
TEMP_CONTAINER=""
WORK_DIR=""

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

ALPINE_IMAGE="docker.io/library/alpine:3.15.0@sha256:21a3deaa0d32a8057914f36584b5288d2e5ecc984380bc0118285c70fa8c9300"

# ---- Colors and logging ----
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# emit: prints stdin unchanged (bash builtins only; replaces cat on the host)
emit() { local c=""; IFS= read -r -d '' c || true; printf '%s' "$c"; }

# read_val FILE VAR: first line of FILE into VAR (empty when missing)
read_val() { local _v=""; [[ -f "$1" ]] && read -r _v < "$1" || true; printf -v "$2" '%s' "$_v"; }

# ---- Paths (bash parameter expansion; no host dirname/basename/readlink) ----
_src="${BASH_SOURCE[0]}"
if [[ "$_src" == */* ]]; then _src_dir="${_src%/*}"; else _src_dir="."; fi
SCRIPT_DIR="$(cd "$_src_dir" && pwd -P)"
SCRIPT_NAME="${_src##*/}"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
CANONICAL_RESULTS="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"

# ---- Container runtime: the first whose engine answers 'info' ----
CONTAINER_CMD=""
for _candidate in docker podman; do
  if command -v "$_candidate" &>/dev/null && "$_candidate" info &>/dev/null; then
    CONTAINER_CMD="$_candidate"
    break
  fi
done
if [[ -z "$CONTAINER_CMD" ]]; then
  for _candidate in docker podman; do
    if command -v "$_candidate" &>/dev/null; then
      CONTAINER_CMD="$_candidate"
      break
    fi
  done
fi

# ---- Self-identification first (hashed in a container; N/A on failure) ----
SCRIPT_SHA256="N/A"
if [[ -n "$CONTAINER_CMD" && -f "$SCRIPT_PATH" ]]; then
  _hash_out="$(${CONTAINER_CMD} run --rm -v "${SCRIPT_PATH}:/script.sh:ro" "${ALPINE_IMAGE}" \
    sha256sum /script.sh </dev/null 2>/dev/null || true)"
  _hash="${_hash_out%% *}"
  [[ "$_hash" =~ ^[0-9a-f]{64}$ ]] && SCRIPT_SHA256="$_hash"
fi
log_info "Script: ${SCRIPT_NAME} ${SCRIPT_VERSION} sha256 ${SCRIPT_SHA256}"

# One run per script folder: runs share COMPARISON_RESULTS.yaml (flock optional).
if command -v flock &>/dev/null; then
  exec 9>"${SCRIPT_DIR}/.comparison_results.lock"
  if ! flock -n 9; then
    log_error "Another verification is already running from ${SCRIPT_DIR} (it shares COMPARISON_RESULTS.yaml). Run this one after it, or from a copy of the script in another folder."
    log_error "No verdict written."
    exit "$EXIT_FAIL"
  fi
else
  log_warn "flock not found; parallel runs from this folder would share COMPARISON_RESULTS.yaml."
fi

# Remove a previous verdict before this invocation can fail, so ABS can never
# pick up a stale COMPARISON_RESULTS.yaml from an earlier run.
rm -f -- "$CANONICAL_RESULTS"

# ---- Disclaimer banner ----
echo -e "${YELLOW}"
emit << 'BANNER_EOF'
==============================================================================
                             DISCLAIMER
==============================================================================
Please examine this script prior to running it. This script downloads source
code, runs Docker/Podman containers, and builds ARM firmware. It may consume
significant CPU, memory (4+ GB), and disk space (10+ GB).
Build time: 20-60 minutes on first run (Nix downloads toolchains cold).
Use at your own risk.
==============================================================================
BANNER_EOF
echo -e "${NC}"

# ---- Root guard ----
if (( EUID == 0 )); then
  log_error "Do not run this script as root. Please run as a normal user."
  exit "$EXIT_INVALID"
fi

if [[ -z "$CONTAINER_CMD" ]]; then
  log_error "Neither docker nor podman found. Please install Docker or Podman."
  exit "$EXIT_FAIL"
fi
log_info "Container runtime: ${CONTAINER_CMD}"

# ---- Usage ----
usage() {
  emit << EOF
OneKey Classic 1S Firmware Reproducible Build Verification

  ${SCRIPT_NAME} --version VERSION [--arch ARCH] [--type TYPE] [--binary FILE|DIR]

  --version   Firmware version without 'v' prefix (e.g., 3.21.0)
  --arch      Architecture (default: arm, the only valid value)
  --type      Firmware type: universal (default, tag vX.Y.Z) or btc-only (tag vX.Y.Z-btc)
  --binary    Official firmware (skips the download): the MCU file
              classic1s.X.Y.Z-Stable-[btc-]<commit>.signed.bin, the combined
              ..._thd89_....signed.bin, or a directory holding the release files

  GITHUB_TOKEN is used for the GitHub API when set; it is never required.

EXIT CODES
  0   = reproducible
  1   = not_reproducible, ftbfs, or a failure with no verdict
  2   = invalid parameters
  130 = stopped
EOF
}

# ---- Argument parsing (unknown parameters warn, never fatal) ----
version=""
arch="arm"
build_type="universal"
binary_file=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || { log_error "--version requires a value"; exit "$EXIT_INVALID"; }; version="$2"; shift 2 ;;
    --arch)    [[ $# -ge 2 ]] || { log_error "--arch requires a value"; exit "$EXIT_INVALID"; }; arch="$2"; shift 2 ;;
    --type)    [[ $# -ge 2 ]] || { log_error "--type requires a value"; exit "$EXIT_INVALID"; }; build_type="$2"; shift 2 ;;
    --binary)  [[ $# -ge 2 ]] || { log_error "--binary requires a value"; exit "$EXIT_INVALID"; }; binary_file="$2"; shift 2 ;;
    --help|-h) usage; exit "$EXIT_OK" ;;
    *) log_warn "Ignoring unknown parameter: $1"; shift ;;
  esac
done

# ---- Validate inputs (--version may be inferred from the --binary filename) ----
version="${version#v}"
if [[ -z "$version" && -n "$binary_file" && -f "$binary_file" ]]; then
  if [[ "${binary_file##*/}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
    log_warn "No --version provided; inferred '${version}' from filename '${binary_file##*/}'"
  fi
fi

if [[ -z "$version" ]]; then
  log_error "--version is required (and could not be inferred from the binary filename)"
  echo
  usage
  exit "$EXIT_INVALID"
fi

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log_error "Invalid version format '${version}'. Expected X.Y.Z (e.g., 3.21.0)"
  exit "$EXIT_INVALID"
fi

case "${build_type,,}" in
  universal|multi|standard|full)          build_type="universal" ;;
  btc-only|bitcoin-only|bitcoinonly|btc)  build_type="btc-only" ;;
  *)
    log_error "Unknown --type '${build_type}'. Expected universal or btc-only"
    exit "$EXIT_INVALID"
    ;;
esac

if [[ "${arch,,}" != "arm" ]]; then
  log_warn "--arch '${arch}' is not valid for the Classic 1S (only 'arm'); continuing with 'arm'"
  arch="arm"
fi

binary_abs=""
if [[ -n "$binary_file" ]]; then
  if [[ ! -e "$binary_file" ]]; then
    log_error "--binary not found: ${binary_file}"
    exit "$EXIT_INVALID"
  fi
  if [[ "$binary_file" == /* ]]; then binary_abs="$binary_file"; else binary_abs="${PWD}/${binary_file}"; fi
fi

BITCOIN_ONLY_VAL="$( [[ "$build_type" == "btc-only" ]] && echo 1 || echo 0 )"
GIT_TAG="v${version}$( [[ "$build_type" == "btc-only" ]] && echo "-btc" || true )"

# ---- Per-run workspace in the caller's directory ----
printf -v RUN_ID '%(%s)T-%s' -1 "$$"
WORK_DIR_CANDIDATE="$(pwd -P)/onekeyclassic1s_verification_${version}_${build_type}_${RUN_ID}"
BUILD_OUTPUT_DIR="${WORK_DIR_CANDIDATE}/build_output"

if ! mkdir -- "$WORK_DIR_CANDIDATE"; then
  log_error "Work directory already exists or cannot be created: ${WORK_DIR_CANDIDATE}"
  exit "$EXIT_INVALID"
fi
WORK_DIR="$WORK_DIR_CANDIDATE"
mkdir -- "$BUILD_OUTPUT_DIR"

# Image names: localhost/ keeps them fully qualified (no short-name lookup);
# the run id keeps cleanup from touching another run's images.
_tag_suffix="${build_type}-${version//./_}-${RUN_ID}"
ENV_IMAGE_NAME="localhost/onekey-classic1s-env-${_tag_suffix}"
BUILD_IMAGE_NAME="localhost/onekey-classic1s-build-${_tag_suffix}"

log_info "=============================================="
log_info "OneKey Classic 1S Firmware Verification"
log_info "=============================================="
log_info "Script  : ${SCRIPT_VERSION}"
log_info "Version : ${version} | Type: ${build_type} | Tag: ${GIT_TAG}"
log_info "Work dir: ${WORK_DIR}"
log_info "=============================================="

# write_results_yaml: 3-field YAML, written only for a real verdict
write_results_yaml() {
  local v="$1" notes="${2:-}"
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${v}"
    if [[ -n "$notes" ]]; then
      echo "notes: |"
      echo "  ${notes}"
    fi
  } > "${CANONICAL_RESULTS}"
  RESULTS_WRITTEN=true
  # Per-run copy in this run's workspace. Deliberately NOT named COMPARISON_RESULTS.yaml:
  # ABS searches its build directory recursively for that name.
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    printf '%s\n' "$(<"${CANONICAL_RESULTS}")" > "${WORK_DIR}/results_${RUN_ID}.yaml" || true
  fi
  log_info "COMPARISON_RESULTS.yaml written (verdict: ${v})"
}

# no_verdict: failure that says nothing about the source (network, stop,
# provenance): no YAML, so ABS publishes nothing.
no_verdict() {
  log_error "$1"
  log_error "No verdict written (this is not a build failure of the source)."
  exit "$EXIT_FAIL"
}

# hand_back_workspace: return root-written files to the caller (docker chown / podman unshare)
hand_back_workspace() {
  [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]] || return 0
  if [[ "$CONTAINER_CMD" == "podman" ]]; then
    podman unshare chown -R 0:0 "$WORK_DIR" >/dev/null 2>&1 || true
  else
    # GROUPS[0] is the caller's primary gid (bash builtin; no host id command)
    ${CONTAINER_CMD} run --rm -v "${WORK_DIR}:/work" "${ALPINE_IMAGE}" \
      sh -c "chown -R ${EUID}:${GROUPS[0]} /work && chmod -R u+rwX /work" >/dev/null 2>&1 || true
  fi
}

# cleanup: remove this run's container/images, hand back the workspace; never writes a verdict
cleanup() {
  local ec=$?
  [[ -n "$TEMP_CONTAINER" ]] && ${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  [[ -n "$BUILD_IMAGE" ]]    && ${CONTAINER_CMD} rmi -f "$BUILD_IMAGE"   >/dev/null 2>&1 || true
  [[ -n "$ENV_IMAGE" ]]      && ${CONTAINER_CMD} rmi -f "$ENV_IMAGE"     >/dev/null 2>&1 || true
  hand_back_workspace
  if [[ "$RESULTS_WRITTEN" != "true" ]]; then
    log_warn "No COMPARISON_RESULTS.yaml written for this run."
  fi
  echo "Exit code: ${ec}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- Helper Python (written here, run in containers) ----

# release_assets.py: picks the MCU, combined and SE assets of a GitHub release and
# OneKey's update-server URL for this version. Exit 3 when the MCU asset is missing.
emit > "${WORK_DIR}/release_assets.py" << 'PYEOF'
import json, re, sys
rel_path, cdn_path, ver, btype = sys.argv[1:5]
btc = "btc-" if btype == "btc-only" else ""
v = re.escape(ver)
pats = {
    "mcu": rf"^classic1s\.{v}-Stable-{btc}[0-9a-f]{{7}}\.signed\.bin$",
    "combined": rf"^classic1s\.{v}-Stable-{btc}[0-9a-f]{{7}}[._]thd89.*\.signed\.bin$",
    "se": r"^thd89.*\.bin$",
}
assets = json.load(open(rel_path)).get("assets", [])
for role, pat in pats.items():
    hit = next((a for a in assets if re.match(pat, a.get("name", ""))), None)
    with open(f"/work/asset_{role}.txt", "w") as f:
        if hit:
            d = (hit.get("digest") or "").removeprefix("sha256:")
            f.write(f"{hit['name']} {hit['browser_download_url']} {d or '-'}\n")
# OneKey's update server: the classic1s entry for this version and edition
cdn_url = ""
try:
    cfg = json.load(open(cdn_path)).get("classic1s", {})
    want = [int(x) for x in ver.split(".")]
    for key, entries in cfg.items():
        if not key.startswith("firmware") or (("btc" in key) != (btype == "btc-only")):
            continue
        for e in entries if isinstance(entries, list) else []:
            if e.get("version") == want and e.get("url"):
                cdn_url = e["url"]
except Exception:
    pass
open("/work/cdn_url.txt", "w").write(cdn_url + "\n")
sys.exit(0 if open("/work/asset_mcu.txt").read().strip() else 3)
PYEOF

# split_fw.py FILE OUT_MCU OUT_SE: the MCU image is the TRZF header plus codelen bytes;
# anything after it is the appended SE blob. Exit 4 when the file is no TRZF image.
emit > "${WORK_DIR}/split_fw.py" << 'PYEOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
if len(data) < 1024 or data[:4] != b"TRZF":
    sys.exit(4)
codelen = struct.unpack_from("<I", data, 12)[0]
end = 1024 + codelen
if end > len(data):
    sys.exit(4)
open(sys.argv[2], "wb").write(data[:end])
open(sys.argv[3], "wb").write(data[end:])
PYEOF

# ---- PHASE 1: fetch (container) ----
# Exit 3 version not released, 4 download, 5 published checksum, 6 bad --binary
log_info ""
log_info "--- Phase 1: Fetch and check the official firmware ---"

BINARY_MOUNT=()
if [[ -n "$binary_abs" ]]; then
  BINARY_MOUNT=(-v "${binary_abs}:/input:ro")
  log_info "Using provided binary: ${binary_abs}"
fi
TOKEN_ENV=()
[[ -n "${GITHUB_TOKEN:-}" ]] && TOKEN_ENV=(-e GITHUB_TOKEN)

phase1_rc=0
${CONTAINER_CMD} run --rm -i \
  -v "${WORK_DIR}:/work" \
  "${BINARY_MOUNT[@]}" \
  "${TOKEN_ENV[@]}" \
  -e "VERSION=${version}" -e "BUILD_TYPE=${build_type}" -e "GIT_TAG=${GIT_TAG}" \
  -e "API_URL=${API_URL}" -e "CDN_CONFIG_URL=${CDN_CONFIG_URL}" \
  "${ALPINE_IMAGE}" \
  sh << 'FETCH_SCRIPT' || phase1_rc=$?
set -e
apk add --no-cache curl python3 >/dev/null 2>&1 || exit 4
cd /work

echo "[Phase1] Reading release ${GIT_TAG} from the GitHub API..."
set -- -H "Accept: application/vnd.github+json"
[ -n "${GITHUB_TOKEN:-}" ] && set -- "$@" -H "Authorization: Bearer ${GITHUB_TOKEN}"
code=$(curl -sSL -o release.json -w '%{http_code}' "$@" "${API_URL}/releases/tags/${GIT_TAG}") || exit 4
[ "$code" = "404" ] && exit 3
[ "$code" = "200" ] || { echo "[Phase1] GitHub API answered HTTP ${code}"; exit 4; }

echo "[Phase1] Reading OneKey's update server config..."
curl -sSL --fail "${CDN_CONFIG_URL}" -o cdn_config.json || echo '{}' > cdn_config.json

python3 release_assets.py release.json cdn_config.json "${VERSION}" "${BUILD_TYPE}" || exit $?
read -r MCU_NAME MCU_URL MCU_DIGEST < asset_mcu.txt
COMB_NAME=""; COMB_URL=""; COMB_DIGEST=""
[ -s asset_combined.txt ] && read -r COMB_NAME COMB_URL COMB_DIGEST < asset_combined.txt
echo "[Phase1] MCU asset:      ${MCU_NAME}"
echo "[Phase1] Combined asset: ${COMB_NAME:-none}"

# check FILE DIGEST LABEL: sha256 against the release's published digest
check() {
  h=$(sha256sum "$1" | cut -d' ' -f1)
  if [ "$2" = "-" ] || [ -z "$2" ]; then
    echo "[Phase1] ${3}: no published digest, check skipped"; echo SKIPPED >> digest_check.txt
  elif [ "$h" = "$2" ]; then
    echo "[Phase1] ${3}: sha256 matches the release digest"; echo OK >> digest_check.txt
  else
    echo "[Phase1] FATAL: ${3} sha256 ${h} is not the published ${2}"; exit 5
  fi
}
: > digest_check.txt

if [ -e /input ]; then
  SRC=""
  if [ -d /input ]; then
    if [ -f "/input/${MCU_NAME}" ]; then SRC="/input/${MCU_NAME}"
    elif [ -n "$COMB_NAME" ] && [ -f "/input/${COMB_NAME}" ]; then SRC="/input/${COMB_NAME}"
    else echo "[Phase1] --binary directory holds neither ${MCU_NAME} nor ${COMB_NAME:-a combined file}"; exit 6; fi
  else
    SRC=/input
  fi
  python3 split_fw.py "$SRC" official_mcu.bin given_tail.bin || exit 6
  if [ -s given_tail.bin ]; then
    echo "[Phase1] Provided file is MCU firmware + appended SE blob; using its MCU part"
    cp "$SRC" official_combined.bin
    check official_combined.bin "$COMB_DIGEST" "provided combined file"
  else
    check official_mcu.bin "$MCU_DIGEST" "provided MCU file"
  fi
  rm -f given_tail.bin
else
  echo "[Phase1] Downloading ${MCU_NAME}..."
  curl -sSL --fail "${MCU_URL}" -o official_mcu.bin || exit 4
  check official_mcu.bin "$MCU_DIGEST" "${MCU_NAME}"
  if [ -n "$COMB_URL" ]; then
    echo "[Phase1] Downloading ${COMB_NAME}..."
    curl -sSL --fail "${COMB_URL}" -o official_combined.bin || exit 4
    check official_combined.bin "$COMB_DIGEST" "${COMB_NAME}"
  fi
fi
python3 split_fw.py official_mcu.bin mcu_check.bin mcu_tail.bin || exit 6
[ -s mcu_tail.bin ] && { echo "[Phase1] MCU image carries trailing data"; exit 6; }
rm -f mcu_check.bin mcu_tail.bin

# The combined file must be the MCU image with the SE blob appended
if [ -f official_combined.bin ]; then
  python3 split_fw.py official_combined.bin comb_mcu.bin official_se.bin || exit 6
  if cmp -s comb_mcu.bin official_mcu.bin; then echo yes; else echo no; fi > combined_prefix_match.txt
  sha256sum official_combined.bin | cut -d' ' -f1 > official_combined_sha256.txt
  sha256sum official_se.bin | cut -d' ' -f1 > official_se_sha256.txt
  rm -f comb_mcu.bin
fi

# What OneKey's update server serves for this version (what the OneKey app installs)
read -r CDN_URL < cdn_url.txt || CDN_URL=""
if [ -z "$CDN_URL" ]; then
  echo NOT_LISTED > cdn_check.txt
elif curl -sSL --fail "$CDN_URL" -o cdn_file.bin && python3 split_fw.py cdn_file.bin cdn_mcu.bin cdn_se.bin; then
  sha256sum cdn_file.bin | cut -d' ' -f1 > cdn_sha256.txt
  if cmp -s cdn_mcu.bin official_mcu.bin; then echo MATCH; else echo MISMATCH; fi > cdn_check.txt
  rm -f cdn_mcu.bin cdn_se.bin
else
  echo FAILED > cdn_check.txt
fi
echo "[Phase1] Update server (${CDN_URL:-not listed}): $(cat cdn_check.txt)"

echo "${MCU_NAME}" > official_name.txt
sha256sum official_mcu.bin | cut -d' ' -f1 > official_mcu_sha256.txt
# Hash the device shows (Device parameters): sha256 of the code after the 1024-byte header
tail -c +1025 official_mcu.bin | sha256sum | cut -d' ' -f1 > official_code_sha256.txt
# Zero the signature area 544-803 (4 x 64-byte signatures + 4 index bytes; legacy/script/hash.py)
cp official_mcu.bin official_mcu_nosig.bin
dd if=/dev/zero of=official_mcu_nosig.bin bs=1 seek=544 count=260 conv=notrunc 2>/dev/null
sha256sum official_mcu_nosig.bin | cut -d' ' -f1 > official_nosig_sha256.txt
echo "[Phase1] Official MCU sha256:   $(cat official_mcu_sha256.txt)"
echo "[Phase1] Official nosig sha256: $(cat official_nosig_sha256.txt)"
FETCH_SCRIPT

case "$phase1_rc" in
  0) ;;
  3) log_error "Release ${GIT_TAG} (or its MCU firmware asset) does not exist"
     exit "$EXIT_INVALID" ;;
  5) no_verdict "Official file fails the release's published sha256: not the published release" ;;
  6) log_error "--binary is not a Classic 1S firmware image for ${version} (${build_type})"
     exit "$EXIT_INVALID" ;;
  *) no_verdict "Phase 1 (fetch) failed (exit ${phase1_rc}): network or download problem" ;;
esac

read_val "${WORK_DIR}/official_name.txt"            OFFICIAL_NAME
read_val "${WORK_DIR}/official_mcu_sha256.txt"      OFFICIAL_SHA256
read_val "${WORK_DIR}/official_nosig_sha256.txt"    OFFICIAL_NOSIG_SHA256
read_val "${WORK_DIR}/official_code_sha256.txt"     OFFICIAL_CODE_SHA256
read_val "${WORK_DIR}/official_combined_sha256.txt" COMBINED_SHA256
read_val "${WORK_DIR}/official_se_sha256.txt"       SE_SHA256
read_val "${WORK_DIR}/combined_prefix_match.txt"    COMBINED_PREFIX
read_val "${WORK_DIR}/cdn_check.txt"                CDN_CHECK
read_val "${WORK_DIR}/cdn_sha256.txt"               CDN_SHA256
read_val "${WORK_DIR}/cdn_url.txt"                  CDN_URL
[[ -n "$OFFICIAL_NOSIG_SHA256" ]] || no_verdict "Phase 1 did not produce the official firmware hash"
log_success "Phase 1 complete: ${OFFICIAL_NAME}"

# ---- PHASE 2a: environment image (downloads only; failure = no verdict) ----
log_info ""
log_info "--- Phase 2a: Preparing build environment and source ---"

ENV_DOCKERFILE="${WORK_DIR}/Dockerfile.env"
emit > "$ENV_DOCKERFILE" << DOCKERFILE_EOF
FROM ${ALPINE_IMAGE}

# Minimal host tools needed before Nix takes over.
RUN apk add --no-cache \\
    bash curl xz git shadow ca-certificates \\
    coreutils findutils grep gzip tar util-linux

# Non-root build user. A single-user Nix install needs no privileges
# when /nix already exists and belongs to that user, so /nix is created here.
RUN adduser -D -s /bin/bash builder && \\
    mkdir -m 0755 /nix && chown builder /nix

USER builder
ENV HOME=/home/builder
ENV USER=builder
WORKDIR /home/builder

# Nix 2.23.3 single-user, as upstream CI (.github/workflows/build-classic1s.yml).
RUN curl --silent --location https://releases.nixos.org/nix/nix-2.23.3/install | \\
    sh -s -- --no-daemon

ENV PATH="/home/builder/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\${PATH}"

# Clone the release tag with submodules.
ARG GIT_TAG
RUN git clone --branch "\${GIT_TAG}" --recurse-submodules ${REPO_URL}.git /home/builder/fw

WORKDIR /home/builder/fw
RUN git rev-parse HEAD > /home/builder/BUILD_COMMIT.txt && \\
    git cat-file -t "\${GIT_TAG}" > /home/builder/BUILD_TAG_TYPE.txt && \\
    t=\$(git cat-file tag "\${GIT_TAG}" 2>/dev/null || true); \\
    case "\$t" in *"BEGIN SSH SIGNATURE"*) echo ssh ;; *"BEGIN PGP SIGNATURE"*) echo pgp ;; *) echo none ;; esac \\
      > /home/builder/BUILD_TAG_SIG.txt; \\
    c=\$(git cat-file commit HEAD); \\
    case "\$c" in *"gpgsig"*) echo yes ;; *) echo no ;; esac > /home/builder/BUILD_COMMIT_SIG.txt

# Toolchain (shell.nix) and Python deps (poetry.lock), as upstream CI. Downloads only,
# so the build step below fails only on the source.
RUN . /home/builder/.nix-profile/etc/profile.d/nix.sh && nix-shell --run "poetry install"
DOCKERFILE_EOF

if ! ${CONTAINER_CMD} build \
  --build-arg "GIT_TAG=${GIT_TAG}" \
  --no-cache \
  --tag "${ENV_IMAGE_NAME}" \
  --file "${ENV_DOCKERFILE}" \
  "${WORK_DIR}"; then
  no_verdict "Environment image failed (Nix install, clone of ${GIT_TAG}, toolchain or poetry install): infrastructure, not the source"
fi
ENV_IMAGE="$ENV_IMAGE_NAME"
log_success "Environment image created: ${ENV_IMAGE}"

# ---- PHASE 2b: build image (setup + cibuild; failure = ftbfs) ----
log_info ""
log_info "--- Phase 2b: Building firmware ---"

BUILD_DOCKERFILE="${WORK_DIR}/Dockerfile.build"
emit > "$BUILD_DOCKERFILE" << DOCKERFILE_EOF
FROM ${ENV_IMAGE}

WORKDIR /home/builder/fw

# Upstream CI steps: legacy/script/setup, then cibuild with PRODUCTION=1 [BITCOIN_ONLY=1].
ARG BITCOIN_ONLY_VAL
RUN . /home/builder/.nix-profile/etc/profile.d/nix.sh && \\
    nix-shell --run "poetry run ./legacy/script/setup" && \\
    if [ "\${BITCOIN_ONLY_VAL}" = "1" ]; then export BITCOIN_ONLY=1; fi && \\
    export PRODUCTION=1 && \\
    nix-shell --run "poetry run ./legacy/script/cibuild" && \\
    mkdir -p /home/builder/out && \\
    cp legacy/firmware/classic1s*Stable*.bin /home/builder/out/ && \\
    cp legacy/bootloader/classic1s_bootloader*Stable*.bin /home/builder/out/ && \\
    cp legacy/firmware/bootloader.dat /home/builder/out/bootloader.dat

CMD ["ls", "-la", "/home/builder/out/"]
DOCKERFILE_EOF

if ! ${CONTAINER_CMD} build \
  --build-arg "BITCOIN_ONLY_VAL=${BITCOIN_ONLY_VAL}" \
  --no-cache \
  --tag "${BUILD_IMAGE_NAME}" \
  --file "${BUILD_DOCKERFILE}" \
  "${WORK_DIR}"; then
  log_error "Firmware build failed: the source at ${GIT_TAG} did not build"
  write_results_yaml "ftbfs" "OneKey Classic 1S ${version} (${build_type}): legacy/script/cibuild failed at ${GIT_TAG}; the environment and source download had succeeded"
  exit "$EXIT_FAIL"
fi
BUILD_IMAGE="$BUILD_IMAGE_NAME"
log_success "Build image created: ${BUILD_IMAGE}"

TEMP_CONTAINER="onekey-classic1s-extract-${_tag_suffix}"
if ! ${CONTAINER_CMD} create --name "$TEMP_CONTAINER" "$BUILD_IMAGE" >/dev/null; then
  TEMP_CONTAINER=""
  no_verdict "Could not create a container from the build image to extract artifacts"
fi
${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/out/." "${BUILD_OUTPUT_DIR}/" \
  || no_verdict "Failed to copy build artifacts from the container"
for _f in BUILD_COMMIT BUILD_TAG_TYPE BUILD_TAG_SIG BUILD_COMMIT_SIG; do
  ${CONTAINER_CMD} cp "${TEMP_CONTAINER}:/home/builder/${_f}.txt" "${WORK_DIR}/${_f}.txt" 2>/dev/null || true
done
${CONTAINER_CMD} rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true; TEMP_CONTAINER=""
${CONTAINER_CMD} rmi -f "$BUILD_IMAGE"   >/dev/null 2>&1 || true; BUILD_IMAGE=""
${CONTAINER_CMD} rmi -f "$ENV_IMAGE"     >/dev/null 2>&1 || true; ENV_IMAGE=""

read_val "${WORK_DIR}/BUILD_COMMIT.txt"     BUILD_COMMIT
read_val "${WORK_DIR}/BUILD_TAG_TYPE.txt"   BUILD_TAG_TYPE
read_val "${WORK_DIR}/BUILD_TAG_SIG.txt"    TAG_SIG_KIND
read_val "${WORK_DIR}/BUILD_COMMIT_SIG.txt" COMMIT_SIG

BUILT_NAME="${OFFICIAL_NAME%.signed.bin}.bin"
if [[ ! -f "${BUILD_OUTPUT_DIR}/${BUILT_NAME}" ]]; then
  log_error "${BUILT_NAME} not found in build output"
  write_results_yaml "ftbfs" "OneKey Classic 1S ${version} (${build_type}): cibuild at ${GIT_TAG} did not produce ${BUILT_NAME} (commit ${BUILD_COMMIT})"
  exit "$EXIT_FAIL"
fi
log_success "Phase 2 complete: ${BUILT_NAME} extracted"

# ---- PHASE 3: compare (container) ----
log_info ""
log_info "--- Phase 3: Comparing firmware and embedded bootloader ---"

if ! ${CONTAINER_CMD} run --rm -i \
  -v "${WORK_DIR}:/work" \
  -e "BUILT_NAME=${BUILT_NAME}" \
  "${ALPINE_IMAGE}" \
  sh << 'COMPARE_SCRIPT'
set -e
cd /work
cp "build_output/${BUILT_NAME}" built_mcu_nosig.bin
dd if=/dev/zero of=built_mcu_nosig.bin bs=1 seek=544 count=260 conv=notrunc 2>/dev/null
sha256sum built_mcu_nosig.bin | cut -d' ' -f1 > built_nosig_sha256.txt
tail -c +1025 built_mcu_nosig.bin | sha256sum | cut -d' ' -f1 > built_code_sha256.txt

echo "=== Firmware (signature area 544-803 zeroed) ==="
echo "  official: $(cat official_nosig_sha256.txt)"
echo "  built:    $(cat built_nosig_sha256.txt)"
if cmp -s official_mcu_nosig.bin built_mcu_nosig.bin; then
  echo yes > firmware_match.txt; echo "  result: MATCH"
else
  echo no > firmware_match.txt; echo "  result: MISMATCH"
  cmp -l official_mcu_nosig.bin built_mcu_nosig.bin > diff_firmware.txt 2>&1 || true
  wc -l < diff_firmware.txt > diff_firmware_lines.txt
fi

# Embedded bootloader: the firmware embeds the committed legacy/firmware/bootloader.dat
# (bl_data.py zero-pads it to 64 KiB). cibuild rebuilt the bootloader from the same commit.
BL=$(ls build_output/classic1s_bootloader*Stable*.bin | head -n 1)
echo "${BL##*/}" > bl_built_name.txt
cp "$BL" bl_rebuilt_padded.bin
size=$(wc -c < bl_rebuilt_padded.bin)
if [ "$size" -lt 65536 ]; then
  dd if=/dev/zero bs=1 count=$((65536 - size)) 2>/dev/null >> bl_rebuilt_padded.bin
fi
sha256sum build_output/bootloader.dat | cut -d' ' -f1 > bl_dat_sha256.txt
sha256sum bl_rebuilt_padded.bin | cut -d' ' -f1 > bl_rebuilt_sha256.txt
echo "=== Embedded bootloader (bootloader.dat vs rebuilt ${BL##*/}, zero-padded to 64 KiB) ==="
echo "  bootloader.dat: $(cat bl_dat_sha256.txt)"
echo "  rebuilt:        $(cat bl_rebuilt_sha256.txt)"
if cmp -s build_output/bootloader.dat bl_rebuilt_padded.bin; then
  echo yes > bl_match.txt; echo "  result: MATCH"
else
  echo no > bl_match.txt; echo "  result: MISMATCH"
  cmp -l build_output/bootloader.dat bl_rebuilt_padded.bin > diff_bootloader.txt 2>&1 || true
fi
COMPARE_SCRIPT
then
  no_verdict "Phase 3 (comparison) container failed"
fi

read_val "${WORK_DIR}/built_nosig_sha256.txt" BUILT_NOSIG_SHA256
read_val "${WORK_DIR}/built_code_sha256.txt"  BUILT_CODE_SHA256
read_val "${WORK_DIR}/firmware_match.txt"     FIRMWARE_MATCH
read_val "${WORK_DIR}/diff_firmware_lines.txt" DIFF_LINES
read_val "${WORK_DIR}/bl_built_name.txt"      BL_BUILT_NAME
read_val "${WORK_DIR}/bl_dat_sha256.txt"      BL_DAT_SHA256
read_val "${WORK_DIR}/bl_rebuilt_sha256.txt"  BL_REBUILT_SHA256
read_val "${WORK_DIR}/bl_match.txt"           BL_MATCH
[[ -n "$FIRMWARE_MATCH" ]] || no_verdict "Phase 3 did not record a firmware comparison result"
log_success "Phase 3 complete"

# ---- Verdict ----
FIRMWARE_VERDICT="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo "reproducible" || echo "not_reproducible" )"
BOOTLOADER_VERDICT="$( [[ "$BL_MATCH" == "yes" ]] && echo "reproducible" || echo "not_reproducible" )"
NOTES_EXTRA=""
OVERALL_VERDICT="not_reproducible"
if [[ "$FIRMWARE_VERDICT" == "reproducible" && "$BOOTLOADER_VERDICT" == "reproducible" ]]; then
  OVERALL_VERDICT="reproducible"
fi
# What the OneKey app installs must be the same MCU image as the GitHub release.
if [[ "$CDN_CHECK" == "MISMATCH" ]]; then
  OVERALL_VERDICT="not_reproducible"
  NOTES_EXTRA=" The update server's file for this version carries a different MCU image than the GitHub release."
fi
if [[ "$COMBINED_PREFIX" == "no" ]]; then
  OVERALL_VERDICT="not_reproducible"
  NOTES_EXTRA="${NOTES_EXTRA} The combined release file carries a different MCU image than the MCU-only file."
fi

FW_INT="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo 1 || echo 0 )"
FW_LABEL="$( [[ "$FIRMWARE_MATCH" == "yes" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
BL_INT="$( [[ "$BL_MATCH" == "yes" ]] && echo 1 || echo 0 )"
BL_LABEL="$( [[ "$BL_MATCH" == "yes" ]] && echo "MATCHES" || echo "DOESN'T MATCH" )"
MATCH_COUNT=$(( FW_INT + BL_INT ))

TAG_TYPE_LABEL="unknown"; TAG_SIG_LINE="[WARNING] Tag signature status unknown"
case "${BUILD_TAG_TYPE}" in
  tag)
    TAG_TYPE_LABEL="annotated"
    case "$TAG_SIG_KIND" in
      ssh)  TAG_SIG_LINE="[INFO] Tag carries an SSH signature (not verified: no OneKey key pinned)" ;;
      pgp)  TAG_SIG_LINE="[INFO] Tag carries a PGP signature (not verified: no OneKey key pinned)" ;;
      *)    TAG_SIG_LINE="[WARNING] Tag is not signed" ;;
    esac ;;
  commit) TAG_TYPE_LABEL="lightweight"; TAG_SIG_LINE="[INFO] Lightweight tag (cannot contain a signature)" ;;
esac
case "$COMMIT_SIG" in
  yes) COMMIT_SIG_LINE="[INFO] Commit carries a signature (not verified)" ;;
  no)  COMMIT_SIG_LINE="[WARNING] Commit is not signed" ;;
  *)   COMMIT_SIG_LINE="[WARNING] Commit signature status unknown" ;;
esac

# First 5 differing bytes for the terminal (bash mapfile; no host head)
DIFF_PREVIEW=()
if [[ "$FIRMWARE_MATCH" != "yes" && -f "${WORK_DIR}/diff_firmware.txt" ]]; then
  mapfile -t -n 5 DIFF_PREVIEW < "${WORK_DIR}/diff_firmware.txt"
fi

echo ""
echo "Hash legend:"
echo "  appHash = SHA-256 of the official MCU firmware file ${OFFICIAL_NAME} as published"
echo "  (when --binary was the combined file: of its MCU part, byte-identical to that file)."
echo "  Publish this one. The hashes after End are for comparison only:"
echo "  *NosigHash = the image with the signature area (bytes 544-803) zeroed;"
echo "  deviceHash = SHA-256 of the code after the 1024-byte header, whose first 7 hex"
echo "  digits the device shows next to its version under Device parameters."
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version}"
echo "apkVersionCode: N/A"
echo "verdict:        ${OVERALL_VERDICT}"
echo "appHash:        ${OFFICIAL_SHA256}"
echo "commit:         ${BUILD_COMMIT}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_SHA256}"
echo ""
echo "Diff:"
echo "BUILDS MATCH BINARIES"
echo "${OFFICIAL_NAME} - arm-${build_type} - ${BUILT_NOSIG_SHA256} - ${FW_INT} (${FW_LABEL})"
echo "bootloader.dat (embedded, vs ${BL_BUILT_NAME:-rebuilt bootloader}) - arm - ${BL_REBUILT_SHA256:-N/A} - ${BL_INT} (${BL_LABEL})"
echo ""
echo "SUMMARY"
echo "total: 2"
echo "matches: ${MATCH_COUNT}"
echo "mismatches: $(( 2 - MATCH_COUNT ))"
if (( ${#DIFF_PREVIEW[@]} > 0 )); then
  echo ""
  echo "First differing bytes (offset official built), ${DIFF_LINES} lines in total:"
  printf '%s\n' "${DIFF_PREVIEW[@]}"
  echo "Full diff: ${WORK_DIR}/diff_firmware.txt"
fi
echo ""
echo "Revision, tag (and its signature):"
echo "${GIT_TAG} -> ${BUILD_COMMIT}"
echo ""
echo "Signature Summary:"
echo "Tag type: ${TAG_TYPE_LABEL}"
echo "${TAG_SIG_LINE}"
echo "${COMMIT_SIG_LINE}"
echo "===== End Results ====="
echo ""
echo "type:                ${build_type}"
echo "tag:                 ${GIT_TAG}"
echo "officialFile:        ${OFFICIAL_NAME}"
echo "officialNosigHash:   ${OFFICIAL_NOSIG_SHA256}"
echo "builtNosigHash:      ${BUILT_NOSIG_SHA256}"
echo "deviceHash official: ${OFFICIAL_CODE_SHA256} (device shows ${OFFICIAL_CODE_SHA256:0:7})"
echo "deviceHash built:    ${BUILT_CODE_SHA256}"
echo "firmwareVerdict:     ${FIRMWARE_VERDICT}"
echo "bootloaderVerdict:   ${BOOTLOADER_VERDICT} (bootloader.dat sha256 ${BL_DAT_SHA256:-N/A})"
if [[ -n "$COMBINED_SHA256" ]]; then
  echo "combinedFile:        sha256 ${COMBINED_SHA256}; MCU part identical to ${OFFICIAL_NAME}: ${COMBINED_PREFIX}"
  echo "secureElementBlob:   sha256 ${SE_SHA256} (thd89, closed source, NOT verified)"
fi
echo "updateServer:        ${CDN_CHECK} ${CDN_URL}${CDN_SHA256:+ (sha256 ${CDN_SHA256})}"
echo ""
echo "Run a full"
echo "diffoscope \"${WORK_DIR}/official_mcu_nosig.bin\" \"${WORK_DIR}/built_mcu_nosig.bin\""
echo "for more details."
echo ""

YAML_NOTES="Firmware v${version} type=${build_type} tag=${GIT_TAG} commit=${BUILD_COMMIT}. MCU firmware: ${FIRMWARE_VERDICT}. Embedded bootloader: ${BOOTLOADER_VERDICT}. Update server: ${CDN_CHECK}. The appended secure-element firmware (thd89) is closed source and not verified.${NOTES_EXTRA}"
write_results_yaml "$OVERALL_VERDICT" "$YAML_NOTES"
[[ "$OVERALL_VERDICT" == "reproducible" ]] && exit "$EXIT_OK"
exit "$EXIT_FAIL"
