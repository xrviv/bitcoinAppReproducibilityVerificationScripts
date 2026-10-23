#!/bin/bash
# trezort_build.sh - Trezor Model T (T2T1) firmware reproducible build verification
# Version: v0.2.0 · Organization: WalletScrutiny.com · License: MIT
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-23
# Disclaimer: for reproducible-build verification only; no warranty; runs containers and
#   downloads source; you are responsible for lawful use. Read the script before running it.
# Steps: build the firmware from core/v<version> (build-docker.sh) and compare it with the official
#   file, its 65-byte signature field zeroed (4608-byte vendor header + 959); rebuild the signed
#   bootloader it embeds from its own release tag and compare outside the signature and code hash.
# Reproducible only if both match. Exit 0 reproducible, 1 not/ftbfs/failure, 2 invalid, 130 stop.
# Host needs only docker or podman: the work runs in a pinned Alpine tools container that drives the
#   same engine through its socket, so Trezor's build-docker.sh runs unchanged. History: changelog.

set -eE

# ---- Globals (bash parameter expansion only; no host dirname/readlink) -------
SCRIPT_VERSION="v0.2.0"
_src="${BASH_SOURCE[0]}"
if [[ "$_src" == */* ]]; then _srcDir="${_src%/*}"; else _srcDir="."; fi
SCRIPT_DIR="$(cd "$_srcDir" && pwd -P)"
SCRIPT_NAME="${_src##*/}"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
TOOLS_BASE="docker.io/library/alpine:3.22@sha256:d406446bc05b82480756ce8f1287964d28768c23955fa9480d2a74a2eae7a654"
TOOLS_PACKAGES="bash coreutils diffutils findutils gawk git wget openssl docker-cli docker-cli-buildx"
ENGINE_SOCK="/run/engine.sock"   # the host engine's socket, as seen inside the tools container
repo="https://github.com/trezor/trezor-firmware.git"

PRODUCT="Trezor Model T"
APP_ID="trezorT"
MODEL="T2T1"
EXPECTED_VH_LEN=4608   # Model T vendor header size (upstream docs/common/reproducible-build.md)
SIG_INNER=959          # signature offset inside the 1024-byte firmware header (0x3bf)

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# no_verdict: a failure that says nothing about the source (runtime, network, a missing tag,
# an official file of the wrong shape). Writes no YAML, so ABS publishes nothing.
no_verdict() {
  echo -e "${RED}Error: $1${NC}"
  echo -e "${RED}No verdict written (this is not a build failure of the source).${NC}"
  exit "$EXIT_FAIL"
}

# Any unguarded command failure is a script/infrastructure problem, never a verdict.
handle_err() {
  local rc=$?
  trap - ERR
  no_verdict "unexpected error (exit ${rc}) during verification"
}

# =============================================================================
# Inner part: runs inside the tools container (WS_INNER=1). The host passes workDir, RUN_ID,
# version, normalizedVersion, firmwareType, SCRIPT_SHA256, OFFICIAL_GIVEN and DOCKER/DOCKER_HOST.
# =============================================================================

sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

# The verdict goes to the host as two lines (verdict, notes); the host writes the YAML.
write_verdict() {
  printf '%s\n%s\n' "$1" "$2" > "$workDir/.verdict"
}

# Read a firmware file's header: prints "<magicHex> <vhLen> <fwMagicHex> <hwModel>".
read_header() {
  local f="$1" m vh fm hw
  m=$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  vh=$(od -An -tu4 -j4 -N4 "$f" 2>/dev/null | tr -d '[:space:]')
  fm=""; hw=""
  if [[ "$vh" =~ ^[0-9]+$ ]]; then
    fm=$(od -An -tx1 -j"$vh" -N4 "$f" 2>/dev/null | tr -d ' \n')
    hw=$(dd if="$f" bs=1 skip=$(( vh + 24 )) count=4 2>/dev/null | tr -cd 'A-Z0-9')
  fi
  echo "${m:-none} ${vh:-none} ${fm:-none} ${hw:-none}"
}

# Run a command with its output also appended to build.log; returns the command's own status.
logged() {
  "$@" 2>&1 | tee -a "$workDir/build.log"
  return "${PIPESTATUS[0]}"
}

# Signature presence in a raw git object. Reported, not verified (no trusted keys here).
sig_kind() {
  case "$1" in
    *"BEGIN SSH SIGNATURE"*) echo "SSH signature present" ;;
    *"BEGIN PGP SIGNATURE"*) echo "PGP signature present" ;;
    *)                       echo "not signed" ;;
  esac
}

prepare() {
  cd "$workDir"
  echo "Cloning Trezor firmware repository..."
  if ! git clone "$repo" trezor-firmware; then
    no_verdict "failed to clone ${repo}"
  fi
  cd trezor-firmware
  echo "Checking out core/v${normalizedVersion}..."
  if ! git checkout "core/v${normalizedVersion}"; then
    echo -e "${RED}Error: git tag core/v${normalizedVersion} not found (not a released version).${NC}"
    exit "$EXIT_INVALID"
  fi
  commit=$(git rev-parse "HEAD")
  tagType=$(git cat-file -t "core/v${normalizedVersion}" 2>/dev/null || echo "unknown")
  case "$tagType" in
    tag)    tagType="annotated"; tagSig=$(sig_kind "$(git cat-file -p "core/v${normalizedVersion}")") ;;
    commit) tagType="lightweight"; tagSig="none (lightweight tag)" ;;
    *)      tagSig="unknown" ;;
  esac
  commitSig=$(sig_kind "$(git cat-file -p HEAD)")
  echo -e "${GREEN}Repository prepared at commit: $commit${NC}"
}

download_official() {
  cd "$workDir"
  local url
  if [[ "${OFFICIAL_GIVEN:-0}" == "1" ]]; then
    echo "Using provided official binary"
    cp /ws/official.bin official.bin
  else
    url="https://data.trezor.io/firmware/t2t1/trezor-t2t1-${normalizedVersion}${editionSuffix}.bin"
    echo "Downloading official firmware..."
    wget -q -O official.bin "$url" || no_verdict "failed to download official firmware: $url"
  fi
  officialHash=$(sha256_of official.bin)
  echo -e "${GREEN}Official firmware hash: ${officialHash}${NC}"
}

build_firmware() {
  cd "$workDir/trezor-firmware"
  # Builds the default board pinned in this tag's model.toml; no HW_REVISION override, matching
  # upstream's own production build. Per-run image/container name keeps parallel runs apart.
  local edition="standard" skipFlag="--skip-bitcoinonly" buildArgs
  if [[ "$firmwareType" == "bitcoin-only" ]]; then edition="bitcoinonly"; skipFlag="--skip-normal"; fi
  export CONTAINER_NAME="trezor-firmware-env-t2t1-${edition}-${normalizedVersion}-${RUN_ID}.nix"
  local tagRef="core/v${normalizedVersion}"
  # Only the firmware target, as upstream CI does (.github/workflows/common.yml: --targets 'firmware');
  # T2T1 has no secmon. build-docker.sh bind-mounts build/core-T2T1{,-bitcoinonly} without creating
  # them; rootless podman refuses missing bind sources, so create them first.
  mkdir -p "build/core-${MODEL}" "build/core-${MODEL}-bitcoinonly"
  buildArgs=(--models "$MODEL" --targets firmware "$skipFlag")

  # Step 1, environment only (upstream --init-only): downloads only, so a failure is not a verdict.
  echo "Preparing the build environment (downloads only)..."
  if ! logged ./build-docker.sh "${buildArgs[@]}" --init-only "$tagRef"; then
    no_verdict "build-docker.sh --init-only failed (environment or dependency download)"
  fi
  # Step 2, the build itself (upstream --no-init) in the snapshot from step 1.
  echo "Building ${firmwareType} firmware for ${MODEL}..."
  if ! logged ./build-docker.sh "${buildArgs[@]}" --no-init "$tagRef"; then
    echo -e "${RED}Build failed!${NC}"
    write_verdict "ftbfs" "${PRODUCT} v${version} (${firmwareType}): build-docker.sh build failed after the environment and sources were prepared."
    exit "$EXIT_FAIL"
  fi
  builtFirmware="build/core-${MODEL}${editionSuffix}/firmware/firmware.bin"
  if [[ ! -f "$builtFirmware" ]]; then
    write_verdict "ftbfs" "${PRODUCT} v${version} (${firmwareType}): build completed but firmware.bin not found."
    exit "$EXIT_FAIL"
  fi
  echo -e "${GREEN}Firmware built successfully${NC}"

  # Fingerprint from build/<commit>.fingerprints: the line after this edition's artifact header
  # (labels are useless here: T2T1 uses the same vendor-header text for both editions).
  local fpFile="build/${commit}.fingerprints" fpHeader="# core-${MODEL}${editionSuffix}/firmware/"
  builtFingerprint=$(awk -v h="$fpHeader" 'found { sub(/^[^:]*:/, ""); gsub(/[[:space:]]/, ""); print; exit }
                                           index($0, h) == 1 { found = 1 }' "$fpFile" 2>/dev/null || true)
  [[ "$builtFingerprint" =~ ^[0-9a-f]{64}$ ]] || builtFingerprint="N/A"
}

compare_firmware() {
  cd "$workDir"
  local magicHex vhLen fwMagicHex hwModel
  builtHash=$(sha256_of "trezor-firmware/${builtFirmware}")
  # Fail closed on header shape: "TRZV", a 4608-byte vendor header, "TRZF" right after it and
  # hw_model T2T1. The 65-byte signature (sigmask 1B + signature 64B) sits at 4608 + 959 = 5567.
  read -r magicHex vhLen fwMagicHex hwModel <<< "$(read_header official.bin)"
  if [[ "$magicHex" != "54525a56" || "$vhLen" != "$EXPECTED_VH_LEN" || "$fwMagicHex" != "54525a46" || "$hwModel" != "$MODEL" ]]; then
    no_verdict "unexpected official firmware header (magic=0x${magicHex}, vendor header=${vhLen}B, firmware magic=0x${fwMagicHex}, hw_model=${hwModel}); expected TRZV / ${EXPECTED_VH_LEN}B / TRZF / ${MODEL} - refusing to guess the signature offset"
  fi
  seekSize=$(( vhLen + SIG_INNER ))
  cp official.bin official.zeroed
  dd if=/dev/zero of=official.zeroed bs=1 seek="$seekSize" count=65 conv=notrunc 2>/dev/null
  officialZeroedHash=$(sha256_of official.zeroed)
  echo
  echo "============================================================"
  echo "Vendor header:       ${vhLen} bytes  (signature zeroed at offset ${seekSize}, 65 bytes)"
  echo "Official (signed):   ${officialHash}"
  echo "Official (zeroed):   ${officialZeroedHash}"
  echo "Built (unsigned):    ${builtHash}"
  echo "============================================================"
  if [[ "$builtHash" == "$officialZeroedHash" ]]; then
    echo -e "${GREEN}REPRODUCIBLE: firmware matches${NC}"; FW_MATCH=1; verdict="reproducible"
  else
    echo -e "${RED}NOT REPRODUCIBLE: firmware differs${NC}"; FW_MATCH=0; verdict="not_reproducible"
    # Full byte diff in the workspace; the results block shows at most 5 lines of it.
    cmp -l official.zeroed "trezor-firmware/${builtFirmware}" > diff_firmware.txt 2>&1 || true
  fi
}

# ---- Embedded bootloader ----------------------------------------------------
# The firmware does not compile its bootloader; it embeds the signed bootloader_T2T1.bin committed in
# the repository (core/embed/projects/firmware/build.rs). Signing adds the 65-byte signature
# (sigmask 0x3BF + signature 0x3C0) and the code hash at 0x20 (docs/core/misc/boot.md). The signature
# is zeroed on both sides; the committed code hash must equal the BLAKE2s of OUR built code
# (T2T1_HASH_PARAMS in python/src/trezorlib/firmware/models.py), so it is recomputed, not ignored.
check_bootloader() {
  local committed="$1" built="$2" size codelen want got
  BL_SIGNED=$(sha256_of "$committed"); BL_BUILT=$(sha256_of "$built"); BL_MATCH=0
  if [[ ! -f "$built" ]]; then BL_NOTE="no built bootloader"; return 0; fi
  size=$(wc -c < "$committed")
  codelen=$(od -An -tu4 -j12 -N4 "$committed" | tr -d '[:space:]')
  # One code chunk only (header 1 KiB + code <= 127 KiB); otherwise more hash slots are used.
  if [[ "$size" != "$(wc -c < "$built")" || $(( 1024 + codelen )) -ne "$size" || "$codelen" -gt 130048 ]]; then
    BL_NOTE="size/codelen mismatch (committed ${size} B, codelen ${codelen}, built $(wc -c < "$built") B)"; return 0
  fi
  cp "$committed" bl.committed.cmp; cp "$built" bl.built.cmp
  for f in bl.committed.cmp bl.built.cmp; do
    dd if=/dev/zero of="$f" bs=1 seek=959 count=65 conv=notrunc 2>/dev/null   # sigmask + signature
    dd if=/dev/zero of="$f" bs=1 seek=32 count=32 conv=notrunc 2>/dev/null    # code hash (checked below)
  done
  if ! cmp -s bl.committed.cmp bl.built.cmp; then
    cmp -l bl.committed.cmp bl.built.cmp > diff_bootloader.txt 2>&1 || true
    BL_NOTE="$(wc -l < diff_bootloader.txt) bytes differ outside the signature and code hash"; return 0
  fi
  want=$(od -An -tx1 -j32 -N32 "$committed" | tr -d ' \n')
  got=$(tail -c +1025 "$built" | openssl dgst -blake2s256 -r | cut -c1-64)
  if [[ "$got" == "$want" ]]; then BL_MATCH=1; BL_NOTE="match (signature zeroed; code hash = BLAKE2s of our build)"; return 0; fi
  BL_NOTE="code hash at 0x20 (${want}) is not the BLAKE2s of the built code (${got})"
}

build_bootloader() {
  cd "$workDir"
  local committed="trezor-firmware/core/embed/models/${MODEL}/bootloaders/bootloader_${MODEL}.bin" magic hdr cn
  BL_MATCH=0; BL_VER="?"; BL_TAG="?"; BL_COMMIT="?"
  if [[ ! -f "$committed" ]]; then BL_NOTE="no committed bootloader_${MODEL}.bin at core/v${normalizedVersion}"; verdict="not_reproducible"; return 0; fi
  magic=$(head -c4 "$committed"); hdr=$(od -An -tu4 -j4 -N4 "$committed" | tr -d '[:space:]')
  BL_VER=$(od -An -tu1 -j16 -N3 "$committed" | awk '{print $1"."$2"."$3}')
  if [[ "$magic" != "TRZB" || "$hdr" != "1024" ]]; then BL_NOTE="unexpected bootloader header (magic ${magic}, ${hdr} B)"; verdict="not_reproducible"; return 0; fi
  BL_TAG="core/bl${BL_VER}"
  if ! git -C trezor-firmware rev-parse -q --verify "refs/tags/${BL_TAG}" >/dev/null; then
    BL_NOTE="no release tag ${BL_TAG} for bootloader ${BL_VER}"; verdict="not_reproducible"; return 0
  fi
  BL_COMMIT=$(git -C trezor-firmware rev-parse "${BL_TAG}^{commit}")
  echo "Building bootloader ${BL_VER} from ${BL_TAG} (${BL_COMMIT})..."
  git clone -q --depth 1 --branch "$BL_TAG" "$repo" src-bootloader || no_verdict "failed to clone ${BL_TAG}"
  cn="trezor-bootloader-env-t2t1-${RUN_ID}.nix"
  ( cd src-bootloader && mkdir -p "build/core-${MODEL}" "build/core-${MODEL}-bitcoinonly" \
    && export CONTAINER_NAME="$cn" && logged ./build-docker.sh --models "$MODEL" --targets bootloader --skip-bitcoinonly "$BL_TAG" ) \
    || no_verdict "bootloader build at ${BL_TAG} failed (that tag's build-docker.sh has no download-only step, so network and source failures cannot be told apart; check the log)"
  check_bootloader "$committed" "src-bootloader/build/core-${MODEL}/bootloader/bootloader.bin"
  if [[ "$BL_MATCH" == "1" ]]; then
    echo -e "${GREEN}Bootloader ${BL_VER} matches${NC}"
  else
    echo -e "${RED}Bootloader ${BL_VER} does not match: ${BL_NOTE}${NC}"; verdict="not_reproducible"
  fi
}

print_hash_legend() {
  echo
  echo "----- What these hashes mean -----"
  echo "appHash       SHA-256 of the official firmware exactly as downloaded from data.trezor.io"
  echo "              (signed). THIS is the official hash to publish for that file."
  echo "zeroedHash    (after End) The official firmware with its 65-byte firmware-header signature"
  echo "              (offset 5567) set to zero. Comparison only; never publish."
  echo "builtHash     (in Diff) SHA-256 of the firmware built from core/v${normalizedVersion}."
  echo "fingerprint   (after End) Trezor's firmware fingerprint of the build; the value a Trezor shows"
  echo "              during a firmware update and lists in data.trezor.io/firmware/t2t1/releases.json."
  echo "bootloader    (in Diff) SHA-256 of the bootloader built from its own release tag, unsigned."
  echo "              The signed committed hash is after End; never publish."
  echo
  echo "MATCH means builtHash == zeroedHash. It does NOT verify Trezor's signature."
  echo "----------------------------------"
}

print_results_block() {
  local flag n lines=() blflag
  if [[ "$FW_MATCH" == "1" ]]; then flag="1 (MATCHES)"; else flag="0 (DOESN'T MATCH)"; fi
  if [[ "$BL_MATCH" == "1" ]]; then blflag="1 (MATCHES)"; else blflag="0 (DOESN'T MATCH)"; fi
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${normalizedVersion}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${verdict}"
  echo "appHash:        ${officialHash}"
  echo "commit:         ${commit}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo
  echo "Diff:"
  echo "BUILDS MATCH BINARIES"
  echo "trezor-t2t1-${normalizedVersion}${editionSuffix}.bin - ${MODEL}-${firmwareType} - ${builtHash} - ${flag}"
  echo "bootloader_T2T1.bin ${BL_VER} - ${MODEL} - ${BL_BUILT:-N/A} - ${blflag}"
  for f in diff_firmware.txt diff_bootloader.txt; do
    if [[ -s "$workDir/$f" ]]; then
      n=$(wc -l < "$workDir/$f"); mapfile -t -n 5 lines < "$workDir/$f"
      echo "First differing bytes in ${f%.txt} (offset official built), ${n} lines in total:"
      printf '%s\n' "${lines[@]}"
      echo "Full diff: $workDir/$f"
    fi
  done
  echo
  echo "Revision, tag (and its signature):"
  echo "Tag type: ${tagType} (core/v${normalizedVersion} -> ${commit})"
  echo "Tag signature: ${tagSig} (not verified)"
  echo "Commit signature: ${commitSig} (not verified)"
  echo "===== End Results ====="
}

inner_main() {
  trap handle_err ERR
  trap 'exit 130' INT TERM
  unset CI GITHUB_ACTIONS
  if [[ "$firmwareType" == "bitcoin-only" ]]; then editionSuffix="-bitcoinonly"; else editionSuffix=""; fi
  cd "$workDir"
  # A provided file says which model it is: hw_model sits 24 bytes into the firmware header.
  if [[ "${OFFICIAL_GIVEN:-0}" == "1" ]]; then
    local fileModel
    read -r _ _ _ fileModel <<< "$(read_header /ws/official.bin)"
    if [[ "$fileModel" != "$MODEL" ]]; then
      echo -e "${RED}Error: --binary is not ${PRODUCT} firmware (hw_model '${fileModel}', expected ${MODEL})${NC}"
      exit "$EXIT_INVALID"
    fi
  fi
  echo "Starting ${PRODUCT} verification..."
  echo "This may take 45-75 minutes (firmware, then the bootloader)."
  echo
  prepare
  download_official
  build_firmware
  compare_firmware
  build_bootloader

  local skipCount
  skipCount=$(grep -c 'SKIP' "$workDir/build.log" 2>/dev/null || true)
  print_hash_legend
  echo
  print_results_block
  echo "type:           ${firmwareType}"
  echo "zeroedHash:     ${officialZeroedHash}  (signature zeroed at offset ${seekSize}; never publish)"
  echo "fingerprint:    ${builtFingerprint}  (Trezor firmware fingerprint of the build)"
  echo "bootloader:     ${BL_VER} from ${BL_TAG} (commit ${BL_COMMIT}): ${BL_NOTE}"
  echo "  signed committed bootloader_T2T1.bin: ${BL_SIGNED:-N/A}  (never publish)"
  echo "upstreamLog:    ${skipCount:-0} lines with SKIP in $workDir/build.log (CI and GITHUB_ACTIONS unset)"
  echo
  echo "Overall verdict: ${verdict}"
  echo

  local summary="firmware match"
  [[ "$FW_MATCH" == "1" ]] || summary="firmware built ${builtHash} != zeroed ${officialZeroedHash}"
  summary="${summary}, bootloader ${BL_VER} (${BL_TAG}): ${BL_NOTE}"
  if [[ "$verdict" == "reproducible" ]]; then
    write_verdict "reproducible" "${PRODUCT} v${version} (${firmwareType}) reproducible from the tagged repository via build-docker.sh at core/v${normalizedVersion} (commit ${commit}); ${summary}; official firmware-header signature (offset 5567, 65B) zeroed before SHA-256 comparison."
    exit "$EXIT_OK"
  fi
  write_verdict "not_reproducible" "${PRODUCT} v${version} (${firmwareType}) not reproducible (firmware and bootloader must both match): ${summary}; firmware signature zeroed at offset 5567, 65B."
  exit "$EXIT_FAIL"
}

# =============================================================================
# Host part: bash builtins plus mkdir/rm and the container runtime. Nothing else runs on the host.
# =============================================================================

# Host-only state. Inside the tools container workDir and RUN_ID come from the host's environment
# and must not be reset here.
if [[ "${WS_INNER:-}" != "1" ]]; then
  CALLER_DIR="$(pwd -P)"
  RUN_ID="$(printf '%(%s)T' -1)-$$"
  workDir=""
fi
RESULTS_WRITTEN=0
CONTAINER_CMD=""
TOOLS_IMAGE=""
HOST_SOCK=""
OWN_SOCK=""
SERVICE_PID=""
ROOTFUL=0
ENGINE_OPTS=()
INNER_ENV=()
USER_OPTS=()

# Every engine call goes through here. Podman runs with cgroupfs, never systemd: a systemd scope
# for a rootless container can fall back to the system bus and pop up a password prompt
# (polkit org.freedesktop.systemd1.manage-units), and a headless account may have no user session.
engine() {
  if [[ "$CONTAINER_CMD" == "podman" ]]; then podman --cgroup-manager=cgroupfs "$@"; else docker "$@"; fi
}

# Results writer (single-line notes; minimal 3-field YAML), printf only.
write_results() {
  local verdict="$1" notes="$2" f
  notes="${notes//\\/ }"
  notes="${notes//\"/\'}"
  notes="${notes//$'\n'/ }"
  notes="${notes//$'\r'/ }"
  # Per-run copy inside the workspace. Deliberately NOT named COMPARISON_RESULTS.yaml:
  # ABS searches its build directory recursively for that name.
  for f in "$RESULTS_FILE" "$workDir/results_${RUN_ID}.yaml"; do
    printf 'script_version: %s\nverdict: %s\nnotes: "%s"\n' "$SCRIPT_VERSION" "$verdict" "$notes" > "$f"
  done
  RESULTS_WRITTEN=1
  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

# ---- Exit cleanup: this run's containers, ownership hand-back, this run's images ----
cleanup() {
  local rc=$? name img id foreign="" names=() imgs=() ids=()
  trap - ERR
  if [[ -n "$CONTAINER_CMD" ]]; then
    mapfile -t imgs < <(engine images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
    for img in "${imgs[@]}"; do
      [[ "$img" == *"$RUN_ID"* ]] || continue
      mapfile -t ids < <(engine ps -aq --filter "ancestor=$img" 2>/dev/null || true)
      for id in "${ids[@]}"; do engine rm -f "$id" &>/dev/null || true; done
    done
    mapfile -t names < <(engine ps -a --format '{{.Names}}' 2>/dev/null || true)
    for name in "${names[@]}"; do
      if [[ "$name" == *"$RUN_ID"* ]]; then engine rm -f "$name" &>/dev/null || true; fi
    done
  fi
  if [[ -n "$workDir" && -d "$workDir" && -n "$TOOLS_IMAGE" ]]; then
    if [[ "$CONTAINER_CMD" == "podman" ]]; then
      podman unshare chown -R 0:0 "$workDir" &>/dev/null || true
      foreign=$(engine run --rm --security-opt label=disable -v "$workDir:$workDir" "$TOOLS_IMAGE" \
        find "$workDir" ! -uid 0 -print -quit 2>/dev/null || true)
    elif (( ROOTFUL )); then
      docker run --rm -v "$workDir:$workDir" "$TOOLS_IMAGE" chown -R "$UID:${GROUPS[0]}" "$workDir" &>/dev/null || true
      foreign=$(docker run --rm -v "$workDir:$workDir" "$TOOLS_IMAGE" \
        find "$workDir" ! -uid "$UID" -print -quit 2>/dev/null || true)
    fi
    [[ -z "$foreign" ]] || echo -e "${YELLOW}[WARN] Some files under $workDir are not owned by the caller: ${foreign}${NC}"
  fi
  if [[ -n "$CONTAINER_CMD" ]]; then
    for img in "${imgs[@]}" "$TOOLS_IMAGE"; do
      if [[ -n "$img" && "$img" == *"$RUN_ID"* ]]; then engine rmi -f "$img" &>/dev/null || true; fi
    done
  fi
  if [[ -n "$SERVICE_PID" ]]; then kill "$SERVICE_PID" &>/dev/null || true; fi
  if [[ -n "$OWN_SOCK" ]]; then rm -f -- "$OWN_SOCK"; fi
  [[ "$RESULTS_WRITTEN" == "1" ]] || echo -e "${YELLOW}[WARN] No COMPARISON_RESULTS.yaml written for this run.${NC}"
  echo "Exit code: ${rc}"
}

usage() {
  echo 'NAME
       trezort_build.sh - verify Trezor Model T (T2T1) firmware

SYNOPSIS
       trezort_build.sh --version VERSION [--type TYPE] [--binary PATH] [--arch ARCH]

DESCRIPTION
       --version   Firmware version to verify, e.g. "2.13.0" (required)
       --type      Firmware type. Accepted: standard|universal|multi  or
                   bitcoin-only|btc-only|btconly  (default: standard)
       --binary    Official firmware .bin, or a directory holding
                   trezor-t2t1-VERSION[-bitcoinonly].bin (optional; downloaded if omitted)
       --arch      Accepted for ABS compatibility; unused

EXAMPLES
       trezort_build.sh --version 2.13.0 --type btc-only
       trezort_build.sh --version 2.13.0 --type universal'
}

# The tools container reaches the host engine through its socket and sees the workspace at the
# same path as the host, so the bind mounts build-docker.sh asks the engine for resolve correctly.
setup_engine() {
  local h
  ENGINE_OPTS=(-v "$workDir:$workDir")
  if [[ "$CONTAINER_CMD" == "docker" ]]; then
    h="${DOCKER_HOST:-}"
    [[ -n "$h" ]] || h="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    [[ "$h" == unix://* ]] || no_verdict "docker endpoint '${h}' is not a local unix socket"
    HOST_SOCK="${h#unix://}"
    [[ "$(docker info --format '{{.SecurityOptions}}' 2>/dev/null)" == *rootless* ]] || ROOTFUL=1
    INNER_ENV=(-e DOCKER=docker -e "DOCKER_HOST=unix://${ENGINE_SOCK}")
  else
    # Always a private API service for this run (cgroupfs, see engine()), stopped at exit. The
    # desktop's socket-activated podman.socket uses systemd cgroups, so it is never used.
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" ]]; then
      HOST_SOCK="${XDG_RUNTIME_DIR}/ws-trezort-${RUN_ID}.sock"
    else
      HOST_SOCK="${workDir}/.engine.sock"
    fi
    (( ${#HOST_SOCK} < 100 )) || no_verdict "podman socket path too long: ${HOST_SOCK}"
    OWN_SOCK="$HOST_SOCK"
    podman --cgroup-manager=cgroupfs system service --time=0 "unix://${HOST_SOCK}" &>/dev/null &
    SERVICE_PID=$!
    for _ in {1..40}; do
      [[ -S "$HOST_SOCK" ]] && break
      read -rt 0.5 <> <(:) || true
    done
    [[ -S "$HOST_SOCK" ]] || no_verdict "could not start a podman API service"
    ENGINE_OPTS+=(--security-opt label=disable)
    INNER_ENV=(-e DOCKER=docker -e "DOCKER_HOST=unix://${ENGINE_SOCK}" -e DOCKER_BUILDKIT=0)
  fi
  ENGINE_OPTS+=(-v "${HOST_SOCK}:${ENGINE_SOCK}")
  echo "Engine socket: ${HOST_SOCK}"
}

# Tools image: the pinned Alpine base plus git, wget, coreutils, openssl and the docker client.
build_tools() {
  local sockGid
  TOOLS_IMAGE="localhost/ws-trezort-tools:${RUN_ID}"
  mkdir -- "$workDir/tools-image"
  printf '%s\n' "FROM ${TOOLS_BASE}" "RUN apk add --no-cache ${TOOLS_PACKAGES}" > "$workDir/tools-image/Dockerfile"
  echo "Building the tools image (${TOOLS_BASE%%@*} + ${TOOLS_PACKAGES})..."
  engine build -q -t "$TOOLS_IMAGE" "$workDir/tools-image" >/dev/null \
    || no_verdict "could not build the tools image"
  # Rootful docker: run the tools container as the caller, in the socket's group.
  if (( ROOTFUL )); then
    sockGid="$(docker run --rm -v "${HOST_SOCK}:${ENGINE_SOCK}" "$TOOLS_IMAGE" stat -c %g "$ENGINE_SOCK" 2>/dev/null || true)"
    [[ "$sockGid" =~ ^[0-9]+$ ]] || no_verdict "could not read the docker socket's group"
    USER_OPTS=(--user "${UID}:${GROUPS[0]}" --group-add "$sockGid")
  fi
}

host_main() {
  trap handle_err ERR
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  # Refuse to run as root (WS rule: runs as a normal user, never with elevated privileges).
  # Never write the privilege-escalation command's name as a word anywhere in this file: the
  # build server refuses any script whose text contains it (scriptContainsSudo in
  # external/build_server/utils.mjs).
  if (( EUID == 0 )); then
    echo -e "${RED}Error: do not run this script as root.${NC}"
    exit "$EXIT_INVALID"
  fi

  echo -e "${YELLOW}"
  echo "=============================================================================="
  echo "                               DISCLAIMER"
  echo "=============================================================================="
  echo "Please examine this script yourself prior to running it."
  echo "This script is provided as-is without warranty and may contain bugs or"
  echo "security vulnerabilities. Running this script will execute Docker containers,"
  echo "download source code, and perform deterministic builds that may consume"
  echo "significant system resources (CPU, memory, disk space)."
  echo "Use at your own risk and ensure you understand what the script does before"
  echo "execution."
  echo "=============================================================================="
  echo -e "${NC}"

  # Container runtime: the first whose engine answers 'info'.
  local c
  for c in docker podman; do
    if command -v "$c" &>/dev/null && "$c" info &>/dev/null; then CONTAINER_CMD="$c"; break; fi
  done

  # Self-identification before argument parsing, hashed in the pinned base image (N/A on failure).
  SCRIPT_SHA256="N/A"
  if [[ -n "$CONTAINER_CMD" ]]; then
    local out
    out="$(engine run --rm -v "${SCRIPT_PATH}:/s.sh:ro" "$TOOLS_BASE" sha256sum /s.sh </dev/null 2>/dev/null || true)"
    [[ "${out%% *}" =~ ^[0-9a-f]{64}$ ]] && SCRIPT_SHA256="${out%% *}"
  fi
  echo "Script:  ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  echo "         sha256: ${SCRIPT_SHA256}"
  echo

  # One run at a time per script directory: every run writes the same COMPARISON_RESULTS.yaml
  # next to the script (where ABS reads it). flock releases on any exit. Refusing writes no verdict.
  if command -v flock &>/dev/null; then
    exec 9>"${SCRIPT_DIR}/.comparison_results.lock"
    if ! flock -n 9; then
      echo -e "${RED}Error: another verification is already running from ${SCRIPT_DIR} (it shares COMPARISON_RESULTS.yaml). Run this one after it, or from a copy of the script in another folder.${NC}"
      echo -e "${RED}No verdict written.${NC}"
      exit "$EXIT_FAIL"
    fi
  else
    echo -e "${YELLOW}[WARN] flock not found; parallel runs from this folder would share COMPARISON_RESULTS.yaml.${NC}"
  fi

  # Remove a previous verdict before this invocation can fail.
  rm -f -- "$RESULTS_FILE"

  [[ -n "$CONTAINER_CMD" ]] || no_verdict "no working docker or podman found; install one of them"
  echo "Container runtime: $CONTAINER_CMD"

  # ---- Arguments (unknown args warn and continue; never fatal) --------------
  local version="" firmwareType="standard" BINARY_PATH=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --binary)   BINARY_PATH="${2:-}";  shift 2 || shift ;;
      --version)  version="${2:-}";      shift 2 || shift ;;
      --arch)     shift 2 || shift ;;    # accepted for ABS; the Model T has one architecture
      --type)     firmwareType="${2:-}"; shift 2 || shift ;;
      -h|--help)  usage; exit "$EXIT_OK" ;;
      *)          echo -e "${YELLOW}[WARN] Ignoring unknown argument: $1${NC}"; shift ;;
    esac
  done

  # Version: digits and dots only (blocks injection / path traversal). Accept X.Y.Z, or the
  # 4-part Trezor form X.Y.Z.0 trimmed to X.Y.Z; reject any other shape.
  if [[ -z "$version" ]]; then
    echo -e "${RED}Error: --version is required${NC}"; echo
    usage
    exit "$EXIT_INVALID"
  fi
  local normalizedVersion
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    normalizedVersion="$version"
  elif [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0$ ]]; then
    normalizedVersion="${BASH_REMATCH[1]}"
  else
    echo -e "${RED}Error: invalid --version '$version' (expected X.Y.Z or X.Y.Z.0)${NC}"
    exit "$EXIT_INVALID"
  fi

  # Type: alias ABS keys btc-only/universal to internal names.
  case "${firmwareType,,}" in
    bitcoin-only|bitcoinonly|btc-only|btconly|btc) firmwareType="bitcoin-only" ;;
    standard|universal|multi|normal)               firmwareType="standard" ;;
    *)
      echo -e "${RED}Error: invalid --type '$firmwareType' (use standard|universal or bitcoin-only|btc-only)${NC}"
      exit "$EXIT_INVALID" ;;
  esac
  local editionSuffix=""
  [[ "$firmwareType" != "bitcoin-only" ]] || editionSuffix="-bitcoinonly"

  # --binary: a file, or a directory (ABS passes one when an asset has several files) holding the
  # file for exactly this --version and --type. Mounted read-only; its model is checked inside.
  local officialFile=""
  if [[ -n "$BINARY_PATH" ]]; then
    [[ "$BINARY_PATH" == /* ]] || BINARY_PATH="$PWD/$BINARY_PATH"
    if [[ -d "$BINARY_PATH" ]]; then
      officialFile="${BINARY_PATH%/}/trezor-t2t1-${normalizedVersion}${editionSuffix}.bin"
      if [[ ! -f "$officialFile" ]]; then
        echo -e "${RED}Error: ${officialFile##*/} not found in directory: ${BINARY_PATH}${NC}"
        exit "$EXIT_INVALID"
      fi
      echo "Selected from --binary directory: $officialFile"
    elif [[ -f "$BINARY_PATH" ]]; then
      officialFile="$BINARY_PATH"
    else
      echo -e "${RED}Error: --binary file not found: $BINARY_PATH${NC}"
      exit "$EXIT_INVALID"
    fi
  fi

  # Per-run workspace in the caller's directory, created with an exclusive mkdir. Never reused,
  # renamed or deleted, so concurrent runs (same or other users, e.g. ABS) cannot collide.
  local wd="${CALLER_DIR}/trezorT_verification_${version}_${firmwareType}_t2t1_${RUN_ID}"
  if ! mkdir -- "$wd"; then
    echo -e "${RED}Error: work directory already exists or cannot be created: $wd${NC}"
    exit "$EXIT_INVALID"
  fi
  workDir="$wd"
  echo
  echo "Verifying ${PRODUCT} (${MODEL}) firmware v$version ($firmwareType)"
  echo "Work dir: $workDir"
  echo

  setup_engine
  build_tools

  local binOpts=() rc=0
  [[ -z "$officialFile" ]] || binOpts=(-v "${officialFile}:/ws/official.bin:ro" -e OFFICIAL_GIVEN=1)
  # Run in the background and wait, so a stop reaches the trap at once and cleanup removes the container.
  # The subshell drops the ERR trap so the container's own exit code (0/1/2/130) comes back unchanged.
  ( trap - ERR; engine run --rm --init --name "ws-trezort-${RUN_ID}" \
    "${ENGINE_OPTS[@]}" "${USER_OPTS[@]}" "${INNER_ENV[@]}" "${binOpts[@]}" \
    -v "${SCRIPT_PATH}:/ws/verify.sh:ro" -w "$workDir" \
    -e WS_INNER=1 -e HOME=/tmp -e "workDir=$workDir" -e "RUN_ID=$RUN_ID" -e "version=$version" \
    -e "normalizedVersion=$normalizedVersion" -e "firmwareType=$firmwareType" -e "SCRIPT_SHA256=$SCRIPT_SHA256" \
    "$TOOLS_IMAGE" bash /ws/verify.sh ) &
  wait "$!" || rc=$?

  if [[ -f "$workDir/.verdict" ]]; then
    local v=()
    mapfile -t v < "$workDir/.verdict"
    case "${v[0]:-}" in
      reproducible|not_reproducible|ftbfs) ;;
      *) no_verdict "unexpected verdict '${v[0]:-}' from the tools container" ;;
    esac
    write_results "${v[0]}" "${v[1]:-}"
    echo
    echo "${PRODUCT} verification finished!"
    [[ "${v[0]}" == "reproducible" ]] && exit "$EXIT_OK"
    exit "$EXIT_FAIL"
  fi
  (( rc != 0 )) || rc="$EXIT_FAIL"   # finished without a verdict
  exit "$rc"
}

if [[ "${WS_INNER:-}" == "1" ]]; then
  inner_main
else
  host_main "$@"
fi
