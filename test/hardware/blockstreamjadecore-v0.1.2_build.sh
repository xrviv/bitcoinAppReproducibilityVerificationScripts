#!/bin/bash
# ==============================================================================
# blockstreamjadecore_build.sh - Blockstream Jade Core Reproducible Build Verifier
# ==============================================================================
# Version: v0.1.2
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-08-31
# Project: https://github.com/Blockstream/Jade
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification only. No warranty is provided. Review all operations before
# execution.
#
# SCOPE: Jade Core only: profile jade_v2c, ESP32-S3, endpoint bin/jade2.0c,
# variants ble and noradio. Classic Jade and Jade Plus use different profiles,
# endpoints and scripts. Core's firmware is distinct even where published names
# and sizes collide with bin/jade or bin/jade1.1.
#
# The script checks the tagged layout, binds each supplied/downloaded artifact
# to the Core index entry, builds upstream's Dockerfile at the documented mount
# path, strips the 4096-byte signature sector, and compares the unsigned payload.
# Hash labels distinguish compressed appHash/cmphash, signed-full fwhash,
# stripped official payload, and local build.
#
# Core has three 1216-byte Secure Boot v2 blocks plus 448 bytes of 0xFF fill.
# Their RSA-PSS signatures, CRCs and format are checked, and embedded key digests
# are matched to release/scripts/v2pk{1,2,3}.pub from the tag. These checks are
# informational and do not change reproducibility. An ANCHORED result ties keys
# to tagged source, but only hardware inspection can prove the eFuse digests.

set -eEuo pipefail

SCRIPT_VERSION="v0.1.2"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
APP_ID="blockstreamjadecore"
REPO_URL="https://github.com/Blockstream/Jade"
PROFILE="jade_v2c"
ENDPOINT="bin/jade2.0c"
# Mount path required by REPRODUCIBLE.md:29, which states that
# /builds/blockstream/jade is encoded into the intermediate jade.map/jade.elf
# and that a hash of the ELF is included in the final binary - written once for
# all four hardware targets, unqualified.
# DOCUMENTED, NOT MEASURED for Jade Core: proving it needs two builds of the
# same variant at two mount paths. What IS measured is that the
# esp_app_desc_t.app_elf_sha256 field it names is populated in the official Core
# artifacts, and that no literal "/builds/blockstream" string appears in the
# decompressed payload - a negative that neither confirms nor refutes the
# requirement. Treat the path as mandatory; do not report it as measured.
MOUNT_PATH="/builds/blockstream/jade"
# Jade Core firmware starts at 1.0.39 - bin/jade2.0c/index.json has no earlier
# entry, so below this floor there is nothing to compare a build against. (The
# classic script's 1.0.36 and the Plus endpoint's 1.0.33 are different numbers
# for the same reason; do not copy one to the other.)
MIN_VERSION="1.0.39"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
TOOLS_BASE_IMAGE="debian:bookworm-slim@sha256:12c396bd585df7ec21d5679bb6a83d4878bc4415ce926c9e5ea6426d23c60bdc"
# Ordered key-name tuple expected in the three signature blocks. Pinned from
# measurement, not a Blockstream statement: all six published Jade Core
# artifacts (1.0.39/1.0.40/1.0.41 x ble/noradio) carry exactly these keys in
# exactly this order. A different value is not proof of wrongdoing - it may be a
# legitimate rotation - but must be investigated before publishing, so it warns.
EXPECTED_ANCHORS="v2pk1,v2pk2,v2pk3"
EXPECTED_SIG_BLOCKS=3

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="esp32s3"
TYPE=""
BINARY_PATH=""
WORK_DIR=""
DL_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_USER_ARGS=()
SRC_COMMIT=""
TOOLS_IMAGE=""
BUILD_IMAGE=""
PROD_CFG_PATH=""

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_fail() { echo -e "${RED}[FAIL] $*${NC}" >&2; }

# Hashes a host-side file, returning N/A rather than failing, so a hashing
# problem can never abort a run under `set -eEuo pipefail`. Distinct from
# sha256_local(), which is only ever handed files known to exist.
sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}
sha256_local() { sha256sum "$1" | awk '{print $1}'; }

declare -A V_RESULT V_NOTE V_CMPHASH V_FWHASH V_PAYLOAD V_BUILT
declare -A V_SIGSTATE V_SIGKEYS V_SIGANCHORS V_ANCHORSTATE V_SIGBLOCKS

# The mandated 3-field results file: script_version, verdict, optional notes -
# no date, no results array (COMPARISON-NOTES.yaml-generation.md). Backslashes,
# quotes and CRs are stripped so free text cannot break the YAML.
write_results() {
  local verdict="$1" notes="${2:-}"
  notes="${notes//\\/ }"; notes="${notes//\"/\'}"; notes="${notes//$'\r'/ }"
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${verdict}"
    if [[ -n "${notes}" ]]; then
      echo "notes: |"
      printf '%s\n' "${notes}" | sed 's/^/  /'
    fi
  } > "${RESULTS_FILE}"
  echo -e "${GREEN}Results written to: ${RESULTS_FILE}${NC}"
}

# An unexpected failure still has to produce a results file - a run that dies
# without one looks to the build server like a script that never executed.
handle_err() {
  local rc=$?
  trap - ERR
  log_fail "Unexpected error (exit ${rc})."
  write_results "ftbfs" "Blockstream Jade Core v${VERSION:-unknown} (${TYPE:-both published artifacts}): script failed before a verdict could be computed."
  exit "${EXIT_FAIL}"
}
trap handle_err ERR

usage() {
  cat <<USAGE
blockstreamjadecore_build.sh ${SCRIPT_VERSION} - Blockstream Jade Core firmware verifier

Usage:
  $0 --version VERSION [--type TYPE] [--arch esp32s3] [--binary PATH]

Parameters:
  --version VERSION  Firmware tag without 'v' prefix, e.g. 1.0.41. Required.
                      Numeric X.Y.Z only (beta tags rejected). Must be
                      ${MIN_VERSION} or later - no Core firmware exists below it.
  --type TYPE         One Jade Core artifact, or omit / "all" for both:
                        core-ble      Jade Core, BLE-enabled (bin/jade2.0c)
                        core-noradio  Jade Core, no-radio    (bin/jade2.0c)
  --arch ARCH         ABS compatibility parameter. Jade Core is an ESP32-S3
                      (Xtensa LX7, not ARM); any other value is ignored with a
                      warning. The real target is set by upstream's own
                      tools/switch_to.sh, which this script does not override.
  --binary PATH       Official compressed file (identified by index hash), or a
                      directory containing index-named files for jadecore/all.
  --apk PATH          Not applicable to hardware; accepted as a --binary alias.
  --help              Show this help.

Exit codes: 0 reproducible, 1 not reproducible / ftbfs, 2 invalid parameters.
USAGE
}

require_value() {
  if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    log_fail "Missing value for $1"; exit "${EXIT_INVALID}"
  fi
}

# Unknown arguments are warned about and skipped, never fatal: ABS passes
# parameters this script has no use for, and a hard exit there would turn a
# runnable verification into a parameter error.
parse_args() {
  if [[ $# -eq 0 ]]; then usage; exit "${EXIT_INVALID}"; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
      --arch)    require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
      --type)    require_value "$1" "${2:-}"; TYPE="$2"; shift 2 ;;
      --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --apk) log_warn "--apk is not applicable to hardware; treating as --binary."
             require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --help|-h) usage; exit "${EXIT_OK}" ;;
      *) log_warn "Unknown argument: $1 (ignored)"; shift ;;
    esac
  done
}

normalize_type() {
  case "${1,,}" in
    # `jadecore` is the page's `types:` value, passed through by ABS; it means
    # the whole product, both artifacts. v0.1.0 rejected it and exited 2.
    ""|all|jadecore|core|jade_v2c|jade2.0c) echo "" ;;
    core-ble|jadecore-ble|jade_v2c-ble|jade2.0c-ble) echo "core-ble" ;;
    core-noradio|jadecore-noradio|jade_v2c-noradio|jade2.0c-noradio) echo "core-noradio" ;;
    *) echo "INVALID" ;;
  esac
}

validate_inputs() {
  if [[ -z "${VERSION}" ]]; then
    log_fail "--version is required (this script does not auto-detect firmware version from --binary)."
    exit "${EXIT_INVALID}"
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_fail "Invalid --version '${VERSION}'. Expected numeric X.Y.Z (e.g. 1.0.41). Beta tags are not supported."
    exit "${EXIT_INVALID}"
  fi
  local IFS=. va vb vc ma mb mc
  read -r va vb vc <<<"${VERSION}"; read -r ma mb mc <<<"${MIN_VERSION}"
  if (( va<ma || (va==ma && vb<mb) || (va==ma && vb==mb && vc<mc) )); then
    log_fail "--version ${VERSION} is below ${MIN_VERSION}. Jade Core firmware is published from ${MIN_VERSION} onwards only."
    exit "${EXIT_INVALID}"
  fi

  # --arch is recorded and reported, never acted on: tools/switch_to.sh:77 sets
  # ARCH="esp32s3" for jade_v2c and runs `idf.py set-target` itself (:293), so
  # forcing a target here would fight upstream's own tooling.
  if [[ -n "${ARCH}" && "${ARCH}" != "esp32s3" ]]; then
    log_warn "Jade Core is an ESP32-S3; ignoring --arch '${ARCH}'. (A WS 'arch: arm' label is wrong - ESP32-S3 is Xtensa LX7, not ARM.)"
  fi
  ARCH="esp32s3"

  TYPE="$(normalize_type "${TYPE}")"
  if [[ "${TYPE}" == "INVALID" ]]; then
    log_fail "Unsupported --type. Use core-ble, core-noradio, or jadecore/all/omit for both."
    exit "${EXIT_INVALID}"
  fi

  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ ! -f "${BINARY_PATH}" && ! -d "${BINARY_PATH}" ]]; then
      log_fail "--binary file or directory not found: ${BINARY_PATH}"; exit "${EXIT_INVALID}"
    fi
  fi
}

# Podman gets --userns=keep-id so bind-mounted output is host-owned; docker an
# explicit --user. Both get HOME=/tmp. These apply to the short-lived tools
# container only - the upstream build image runs as root and hands ownership
# back via chown_back().
# No --format docker here, deliberately: that flag exists in the classic script
# because the Dockerfile at tags 1.0.35-1.0.38 used a SHELL instruction podman's
# default OCI format ignores. There is no SHELL instruction at 1.0.39, 1.0.40 or
# 1.0.41 (checked at each tag), the whole range supported here, so it would be
# dead weight. If a future tag reintroduces SHELL the build fails with
# "source: not found" (exit 127) - recognisable, not silent.
detect_container_cmd() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"; CONTAINER_RUN_USER_ARGS=(--userns=keep-id -e HOME=/tmp)
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"; CONTAINER_RUN_USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
  else
    log_fail "Neither podman nor docker found. Install one container runtime."
    write_results "ftbfs" "No container runtime found. Host requirement is podman or docker."
    exit "${EXIT_FAIL}"
  fi
  log_info "Container engine: ${CONTAINER_CMD}"
}

# The upstream build image runs as root - ESP-IDF's environment is baked into
# the image and remapping the user is an unmeasured risk with no reason to take
# it - so everything it writes into the bind-mounted source tree is root-owned
# until this runs. Emitted into the container's EXIT trap so it also runs when
# the build FAILS, which is when leftovers matter most: the build account has no
# sudo, so a root-owned file in the workspace would be permanently undeletable
# (non-sudo-directories-guideline.md).
chown_back() {
  local uid gid; uid="$(id -u)"; gid="$(id -g)"
  printf 'chown -R %s:%s "%s" >/dev/null 2>&1 || true' "${uid}" "${gid}" "$1"
}

variant_radio() { case "$1" in *-noradio) echo noradio ;; *) echo ble ;; esac; }
variant_label() {
  case "$1" in
    core-ble) echo "Jade Core (BLE)" ;;
    core-noradio) echo "Jade Core (no-radio)" ;;
  esac
}
requested_variants() {
  if [[ -n "${TYPE}" ]]; then echo "${TYPE}"; else printf '%s\n' core-ble core-noradio; fi
}

# Writes the signature checker into the work dir. It runs inside the tools
# container (which carries python3-cryptography), so the host needs no Python
# packages. See "ANCHORED SIGNATURE VERIFICATION" in the header for what this is
# and is not evidence of.
write_sigcheck_tool() {
  cat > "${WORK_DIR}/ws_sigcheck.py" <<'PYEOF'
import glob, hashlib, os, struct, sys, zlib
SECTOR, BLOCK, MAGIC, VER = 4096, 1216, 0xE7, 0x02
FMT = "<BB2s32s384sI384sI384sI16s"

def emit(**kw):
    for k in ("SIGSTATE", "SIGBLOCKS", "SIGKEYS", "SIGANCHORS", "SIGANCHORSTATE", "SIGDETAIL"):
        if kw.get(k):
            print("%s=%s" % (k, kw[k]))
    sys.exit(0)

def keydigest(mod, exp, rinv, mprime):
    # What espsecure.py digest_sbv2_public_key emits, and what an ESP32-S3 burns
    # into eFuse SECURE_BOOT_DIGEST0/1/2.
    return hashlib.sha256(struct.pack("<384sI384sI", mod, exp, rinv, mprime)).hexdigest()

def anchors(pubdir):
    # Secure Boot v2 digest of every RSA-3072 public key published in the tagged
    # source tree, so a block's key can be named and not only printed as a bare
    # hash. rinv = R^2 mod n (R = 2^3072), mprime = -n^-1 mod 2^32.
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
    out = {}
    for path in sorted(glob.glob(os.path.join(pubdir, "*.pub"))):
        try:
            n = load_pem_public_key(open(path, "rb").read()).public_numbers()
        except Exception:
            continue
        if (n.n.bit_length() + 7) // 8 != 384:
            continue
        rinv = (1 << (384 * 8 * 2)) % n.n
        mprime = (-pow(n.n, -1, 1 << 32)) % (1 << 32)
        out[keydigest(n.n.to_bytes(384, "little"), n.e,
                      rinv.to_bytes(384, "little"), mprime)] = os.path.basename(path)[:-4]
    return out

try:
    signed = open(sys.argv[1], "rb").read()
    pubdir = sys.argv[2] if len(sys.argv) > 2 else ""
    if len(signed) <= SECTOR:
        emit(SIGSTATE="UNAVAILABLE", SIGDETAIL="file smaller than one signature sector")
    payload, sector = signed[:-SECTOR], signed[-SECTOR:]
    # The signed digest covers the payload 0xFF-padded to a sector boundary. Jade
    # payloads are already aligned, so this is in practice just the payload - but
    # the padding is part of the format and is applied anyway.
    calc = hashlib.sha256(payload + b"\xff" * ((-len(payload)) % SECTOR)).digest()

    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils
    known = anchors(pubdir) if pubdir and os.path.isdir(pubdir) else {}

    states, keys, names = [], [], []
    for off in range(0, SECTOR - BLOCK + 1, BLOCK):
        blk = sector[off:off + BLOCK]
        magic, ver, reserved, digest, mod, exp, rinv, mprime, sig, crc, pad = struct.unpack(FMT, blk)
        if magic != MAGIC or ver != VER:
            break
        kd = keydigest(mod, exp, rinv, mprime)
        keys.append(kd)
        names.append(known.get(kd, "UNKNOWN"))
        if crc != (zlib.crc32(blk[:1196]) & 0xffffffff):
            states.append("CRC-INVALID")
            continue
        if reserved != b"\0\0" or pad != b"\0" * 16:
            states.append("FORMAT-INVALID")
            continue
        if digest != calc:
            states.append("DIGEST-MISMATCH")
            continue
        try:
            # RSA-PSS, MGF1-SHA256, salt 32; modulus stored little-endian and the
            # signature byte-reversed, both per the Secure Boot v2 block layout.
            rsa.RSAPublicNumbers(e=exp, n=int.from_bytes(mod, "little")).public_key().verify(
                sig[::-1], calc,
                padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32),
                utils.Prehashed(hashes.SHA256()))
            states.append("VALID")
        except Exception:
            states.append("INVALID")

    if not states:
        emit(SIGSTATE="UNAVAILABLE", SIGDETAIL="no Secure Boot v2 block found in trailing sector")
    tail = sector[len(states) * BLOCK:]
    detail = "%d block(s); %d bytes of trailing fill%s" % (
        len(states), len(tail), "" if set(tail) <= {0xFF} else " (NOT all 0xFF)")
    if not known:
        astate = "UNAVAILABLE"
    elif "UNKNOWN" not in names:
        astate = "ANCHORED"
    elif set(names) == {"UNKNOWN"}:
        astate = "UNANCHORED"
    else:
        astate = "PARTIAL"
    state = "VALID" if set(states) == {"VALID"} else ",".join(states)
    if set(tail) - {0xFF}:
        state += ",FILL-INVALID"
    emit(SIGSTATE=state,
         SIGBLOCKS=str(len(states)), SIGKEYS=",".join(keys),
         SIGANCHORS=",".join(names), SIGANCHORSTATE=astate, SIGDETAIL=detail)
except ImportError as exc:
    emit(SIGSTATE="UNAVAILABLE", SIGDETAIL="python3-cryptography not present: %s" % exc)
except Exception as exc:
    emit(SIGSTATE="INVALID", SIGDETAIL=str(exc))
PYEOF
}

# Runs the checker against one staged artifact and turns anything unexpected
# into a loud warning. The verdict is never touched by any of it.
check_signature() {
  local key="$1" res="" detail=""
  [[ -f "${DL_DIR}/${key}.full.bin" ]] || return 0
  res="$("${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" \
        "${TOOLS_IMAGE}" python3 /work/ws_sigcheck.py \
        "/work/official/jade2.0c/${key}.full.bin" /work/src/release/scripts 2>&1 || true)"
  V_SIGSTATE[$key]="$(sed -n 's/^SIGSTATE=//p' <<<"${res}" | head -1)"
  V_SIGBLOCKS[$key]="$(sed -n 's/^SIGBLOCKS=//p' <<<"${res}" | head -1)"
  V_SIGKEYS[$key]="$(sed -n 's/^SIGKEYS=//p' <<<"${res}" | head -1)"
  V_SIGANCHORS[$key]="$(sed -n 's/^SIGANCHORS=//p' <<<"${res}" | head -1)"
  V_ANCHORSTATE[$key]="$(sed -n 's/^SIGANCHORSTATE=//p' <<<"${res}" | head -1)"
  detail="$(sed -n 's/^SIGDETAIL=//p' <<<"${res}" | head -1)"
  [[ -z "${V_SIGSTATE[$key]}" ]] && V_SIGSTATE[$key]="UNAVAILABLE"

  case "${V_SIGSTATE[$key]}" in
    VALID) : ;;
    UNAVAILABLE) log_warn "${key}: signature check unavailable${detail:+ (${detail})}. Verdict is unaffected." ;;
    *) log_warn "${key}: SIGNATURE CHECK FAILED (${V_SIGSTATE[$key]})${detail:+ - ${detail}}. Verdict is unaffected, but this needs investigation before publishing." ;;
  esac
  if [[ -n "${V_SIGBLOCKS[$key]:-}" && "${V_SIGBLOCKS[$key]}" != "${EXPECTED_SIG_BLOCKS}" ]]; then
    log_warn "${key}: expected ${EXPECTED_SIG_BLOCKS} Secure Boot v2 blocks (Core is signed by three keys), found ${V_SIGBLOCKS[$key]}. Investigate before publishing."
  fi
  case "${V_ANCHORSTATE[$key]:-}" in
    ANCHORED)
      if [[ "${V_SIGANCHORS[$key]}" != "${EXPECTED_ANCHORS}" ]]; then
        log_warn "${key}: signatures anchor to the repo, but to '${V_SIGANCHORS[$key]}' not the expected '${EXPECTED_ANCHORS}'. May be a legitimate key rotation; investigate before publishing."
      else
        log_info "${key}: signing keys anchored to release/scripts/{v2pk1,v2pk2,v2pk3}.pub at tag ${VERSION}."
      fi ;;
    UNANCHORED) log_warn "${key}: NO signing key matches a .pub file published in the source tree at tag ${VERSION}. Verdict unaffected, but this is the anchoring the script exists to provide - investigate before publishing." ;;
    PARTIAL)    log_warn "${key}: only some signing keys matched published .pub files (${V_SIGANCHORS[$key]}). Investigate before publishing." ;;
    *)          log_warn "${key}: anchor check unavailable - no readable .pub files under release/scripts at tag ${VERSION}." ;;
  esac
  return 0
}

# A pinned Debian image carrying what the host is not asked to have: git, curl,
# jq, python3, python3-cryptography. Everything except the firmware build runs
# in here.
build_tools_image() {
  local dockerfile="${WORK_DIR}/Dockerfile.tools"
  cat > "${dockerfile}" <<DOCKERFILE
FROM ${TOOLS_BASE_IMAGE}
RUN apt-get update -qq && apt-get install -y --no-install-recommends \\
    git ca-certificates curl jq python3-minimal python3-cryptography >/dev/null \\
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  # Image tags carry version, type and PID so parallel ABS runs of the two
  # variants cannot collide on a name (script_verifications.md rule 7).
  TOOLS_IMAGE="ws-jadecore-tools:${VERSION}-${TYPE:-all}-$$"
  "${CONTAINER_CMD}" build -q -t "${TOOLS_IMAGE}" -f "${dockerfile}" "${WORK_DIR}" >/dev/null
}

# Cloning happens in the container so the host needs no git; the tree is written
# with the caller's UID via CONTAINER_RUN_USER_ARGS.
clone_checkout() {
  log_info "Cloning ${REPO_URL} and checking out tag ${VERSION} (submodules included)."
  "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    bash -c "
      set -euo pipefail
      cd /work
      git clone --quiet '${REPO_URL}' src
      cd src
      git checkout --quiet 'tags/${VERSION}'
      git submodule update --init --recursive
      git rev-parse HEAD > /work/src_commit.txt
    "
  SRC_COMMIT="$(cat "${WORK_DIR}/src_commit.txt")"
  log_info "Source commit: ${SRC_COMMIT}"
}

# Fails loudly on an unrecognised repo layout rather than guessing. Three checks:
#  1. tools/switch_to.sh must exist - the only mechanism supported here. The
#     static "cp production/sdkconfig_*.defaults" path the classic script keeps
#     for pre-1.0.39 tags is irrelevant: Core starts at 1.0.39, switch_to.sh
#     predates that.
#  2. It must carry a jade_v2c arm (switch_to.sh:77 at 1.0.39/1.0.40/1.0.41).
#  3. The jade_v2c production sdkconfig must be findable. At 1.0.39/1.0.40 that
#     is production/sdkconfig_jade_v2c_prod.defaults; at 1.0.41 the directory
#     moved to configs/production/. switch_to.sh resolves this itself (its
#     CONFIG_FILE line changed in the same commit) so we do not branch on it -
#     but checking makes a third move fail here with a clear message rather than
#     mid-build.
resolve_layout() {
  local probe
  probe="$("${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" bash -c "
      cd /work/src
      if [ ! -f tools/switch_to.sh ]; then echo 'NO_SWITCH_TO'; exit 0; fi
      if ! grep -q '${PROFILE})' tools/switch_to.sh; then echo 'NO_PROFILE'; exit 0; fi
      if [ -f configs/production/sdkconfig_${PROFILE}_prod.defaults ]; then echo 'configs/production'
      elif [ -f production/sdkconfig_${PROFILE}_prod.defaults ]; then echo 'production'
      else echo 'NO_PROD_CFG'; fi
    ")"
  case "${probe}" in
    NO_SWITCH_TO)
      log_fail "Tag ${VERSION}: tools/switch_to.sh not found."
      write_results "ftbfs" "Unsupported repo layout at tag ${VERSION}: tools/switch_to.sh, the only Jade Core sdkconfig-generation mechanism this script supports, is absent. Script needs updating for this tag."
      exit "${EXIT_FAIL}" ;;
    NO_PROFILE)
      log_fail "Tag ${VERSION}: tools/switch_to.sh has no '${PROFILE}' profile."
      write_results "ftbfs" "Tag ${VERSION} has no '${PROFILE}' (Jade Core) profile in tools/switch_to.sh, so no Jade Core firmware can be built from it. Script needs updating for this tag."
      exit "${EXIT_FAIL}" ;;
    NO_PROD_CFG)
      log_fail "Tag ${VERSION}: sdkconfig_${PROFILE}_prod.defaults not found at either known path."
      write_results "ftbfs" "Unsupported repo layout at tag ${VERSION}: sdkconfig_${PROFILE}_prod.defaults was found at neither configs/production/ (1.0.41+) nor production/ (1.0.39-1.0.40). The production config directory appears to have moved again. Script needs updating for this tag."
      exit "${EXIT_FAIL}" ;;
  esac
  PROD_CFG_PATH="${probe}"
  log_info "Repo layout at ${VERSION}: tools/switch_to.sh with '${PROFILE}' profile; production configs under ${PROD_CFG_PATH}/"
}

# The one FTBFS workaround carried. The `FROM` (Dockerfile:6 at 1.0.41, :15 at
# 1.0.39/1.0.40) is an unqualified NAMESPACED name. Docker assumes Docker Hub;
# podman refuses it unless an unqualified-search registry is set, which needs
# root on the build host. The ref is digest-pinned, so the prefix cannot change
# which image is pulled. Single-name images (debian) are left alone.
# NOT carried: the classic PIP_CONSTRAINT=setuptools<82 patch. That trap needs a
# cbor2 pin whose only permitted hash is an sdist, forcing a source build; at
# 1.0.39-1.0.41 the pin permits many. That a wheel compatible with the builder's
# platform tags is actually selected is UNVERIFIED until the first real build.
patch_dockerfile() {
  local pyfile="${WORK_DIR}/ws_patch_dockerfile.py" rc=0
  cat > "${pyfile}" <<'PYEOF'
import os, re, sys
dockerfile = "/work/src/Dockerfile"
if not os.path.exists(dockerfile):
    print("WS-PATCH: no Dockerfile at this tag."); sys.exit(3)
df = open(dockerfile).read()
before = df

def qualify(m):
    ref = m.group(2)
    head = ref.split("/")[0]
    if "/" in ref and "." not in head and ":" not in head and head != "localhost":
        return m.group(1) + "docker.io/" + ref
    return m.group(0)

df = re.sub(r"(?m)^(FROM\s+)(\S+)", qualify, df)
if df != before:
    open(dockerfile, "w").write(df)
    print("WS-PATCH: qualified namespaced FROM with docker.io/ (digest pinned)")
else:
    print("WS-PATCH: FROM already registry-qualified; no change needed.")
PYEOF
  "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    python3 /work/ws_patch_dockerfile.py || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_fail "Dockerfile patch refused (exit ${rc}): this tag has no Dockerfile where one is expected."
    write_results "ftbfs" "Blockstream Jade Core v${VERSION}: no Dockerfile found at the tag, so the upstream builder image could not be constructed. Script needs updating for this tag."
    exit "${EXIT_FAIL}"
  fi
}

# Builds upstream's own Dockerfile from the tag. It is a thin layer over a
# digest-pinned base image that already carries the ESP-IDF toolchain for BOTH
# esp32 and esp32s3 (upstream CI builds that base with
# IDF_INSTALL_TARGETS=esp32,esp32s3), so Jade Core needs no extra
# idf_tools.py install and no different ESP-IDF pin than classic Jade.
build_upstream_image() {
  patch_dockerfile
  BUILD_IMAGE="ws-jadecore-builder:${VERSION}-${TYPE:-all}-$$"
  log_info "Building upstream Dockerfile from tag ${VERSION} (pulls the pinned ESP-IDF base image; can take a while)."
  "${CONTAINER_CMD}" build -q -f "${WORK_DIR}/src/Dockerfile" -t "${BUILD_IMAGE}" "${WORK_DIR}/src" >/dev/null
}

# Confirms Blockstream published this version/config before spending time on a
# build. The jq selector is the classic script's - the index schema is identical
# across all four Jade endpoints (beta/stable/previous, each full entry carrying
# filename, version, config, fwsize, cmphash, fwhash).
preflight_variant() {
  local key="$1" config entry
  config="$(variant_radio "${key}")"
  log_info "Checking official index ${ENDPOINT}/index.json (${key})"
  if ! entry="$("${CONTAINER_CMD}" run --rm "${TOOLS_IMAGE}" bash -c "
      set -euo pipefail
      curl -sSL --fail --max-time 30 -o /tmp/index.json 'https://jadefw.blockstream.com/${ENDPOINT}/index.json'
      jq -e . /tmp/index.json >/dev/null
      jq -c --arg v '${VERSION}' --arg c '${config}' \
        '[ (.stable.full + .previous.full)[] | select(.version==\$v and .config==\$c) ] |
         if length==0 then empty elif length==1 then .[0] else error(\"duplicate index entries\") end' /tmp/index.json
    ")"; then
    log_fail "${key}: could not fetch or parse ${ENDPOINT}/index.json."
    V_RESULT[$key]="ftbfs"; V_NOTE[$key]="official index fetch or parse failed"
    return 1
  fi
  if [[ -z "${entry}" ]]; then
    log_warn "${key}: no official Jade Core artifact published for v${VERSION} at ${ENDPOINT} (config=${config})."
    V_RESULT[$key]="ftbfs"; V_NOTE[$key]="official artifact not published for this version/config"
    return 1
  fi
  echo "${entry}" > "${WORK_DIR}/index_${key}.json"
  V_RESULT[$key]="pending"
  return 0
}

official_json_field() {
  "${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    bash -c "jq -r '.$2' /work/index_$1.json"
}

resolve_binary_file_variant() {
  local key expected match="" matches=0 actual
  actual="$(sha256_local "${BINARY_PATH}")"
  for key in core-ble core-noradio; do
    preflight_variant "${key}" || return 1
    expected="$(official_json_field "${key}" cmphash)" || return 1
    if [[ "${actual}" == "${expected}" ]]; then match="${key}"; matches=$((matches+1)); fi
  done
  if [[ "${matches}" -ne 1 ]]; then
    log_fail "--binary hash matches ${matches} Core index entries for v${VERSION}; expected exactly one."
    return 1
  fi
  TYPE="${match}"
  log_info "Identified --binary as ${TYPE} from ${ENDPOINT}/index.json."
}

# Downloads (or accepts) the official artifact, checks it against the published
# hashes, decompresses it and strips the signature sector. Everything lands in
# ${DL_DIR} = <workdir>/official/jade2.0c/ - see the collision note in the
# header; never write a Jade firmware download into a shared directory.
stage_official() {
  local key="$1" filename dl src cmp_actual full_actual expected
  dl="${DL_DIR}/${key}.bin.gz"
  if ! filename="$(official_json_field "${key}" filename)" || [[ -z "${filename}" || "${filename}" == */* || "${filename}" == "null" ]]; then
    log_fail "${key}: invalid filename in the selected index entry."
    return 1
  fi
  if [[ -n "${BINARY_PATH}" ]]; then
    if [[ -d "${BINARY_PATH}" ]]; then src="${BINARY_PATH%/}/${filename}"; else src="${BINARY_PATH}"; fi
    if [[ ! -f "${src}" ]]; then
      log_fail "${key}: expected ${filename} in --binary directory ${BINARY_PATH}."
      return 1
    fi
    if ! cp "${src}" "${dl}"; then log_fail "${key}: could not stage --binary ${src}."; return 1; fi
    log_info "${key}: using --binary ${src}; binding it to ${ENDPOINT}/index.json."
  else
    log_info "${key}: downloading ${ENDPOINT}/${filename}"
    if ! "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
      bash -c "curl -sSL --fail --max-time 120 -o '/work/official/jade2.0c/${key}.bin.gz' 'https://jadefw.blockstream.com/${ENDPOINT}/${filename}'"; then
      log_fail "${key}: official artifact download failed."
      return 1
    fi
  fi

  # appHash is this value: the artifact EXACTLY as downloaded, before any
  # decompression or strip (dannys-amendments.md, GitLab 957).
  cmp_actual="$(sha256_local "${dl}")"
  if ! expected="$(official_json_field "${key}" cmphash)" || [[ "${cmp_actual}" != "${expected}" ]]; then
    log_fail "${key}: artifact does not match index.json cmphash (expected ${expected:-unavailable}, got ${cmp_actual})."
    return 1
  fi
  V_CMPHASH[$key]="${cmp_actual}"

  # Raw zlib, not gzip, despite the .bin naming - tools/fwtools.py compresses
  # with zopfli.zlib and decompresses with plain zlib.decompress. `gunzip` fails
  # on these files; `pigz -z -d` works, python avoids the extra dependency.
  if ! "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    bash -c "python3 -c \"import zlib; d=open('/work/official/jade2.0c/${key}.bin.gz','rb').read(); open('/work/official/jade2.0c/${key}.full.bin','wb').write(zlib.decompress(d))\""; then
    log_fail "${key}: artifact decompression failed."
    return 1
  fi

  full_actual="$(sha256_local "${DL_DIR}/${key}.full.bin")"
  if ! expected="$(official_json_field "${key}" fwhash)" || [[ "${full_actual}" != "${expected}" ]]; then
    log_fail "${key}: decompressed artifact does not match index.json fwhash (expected ${expected:-unavailable}, got ${full_actual})."
    return 1
  fi
  V_FWHASH[$key]="${full_actual}"
  if [[ "$(wc -c < "${DL_DIR}/${key}.full.bin")" -le 4096 ]]; then
    log_fail "${key}: signed firmware is too short to contain a signature sector."
    return 1
  fi

  # The trailing signature sector is 4096 bytes on Core exactly as on classic
  # Jade; only its contents differ (Core: three 1216-byte blocks + 448 bytes of
  # 0xFF fill; classic: one block + 2880 bytes of fill). The strip depends on the
  # SECTOR size, so `head -c -4096` is right for both - do NOT compute 3 x 1216.
  head -c -4096 "${DL_DIR}/${key}.full.bin" > "${DL_DIR}/${key}.payload.bin"
}

# One firmware build. `switch_to.sh jade_v2c [--noradio]` selects the profile,
# sets ARCH=esp32s3 and runs `idf.py set-target`; `idf.py fullclean all` is
# upstream's production build command (.gitlab-ci.yml:60). The tree is
# bind-mounted at MOUNT_PATH because REPRODUCIBLE.md:29 requires it.
build_variant() {
  local key="$1" radio gen_cmd chown_cmd rc=0
  radio="$(variant_radio "${key}")"
  if [[ "${radio}" == "noradio" ]]; then gen_cmd="./tools/switch_to.sh ${PROFILE} --noradio"
  else gen_cmd="./tools/switch_to.sh ${PROFILE}"; fi
  chown_cmd="$(chown_back "${WORK_DIR}/src")"
  log_info "Building ${key} ($(variant_label "${key}")): ${gen_cmd}"
  if ! rm -f "${WORK_DIR}/src/build/jade.bin" "${WORK_DIR}/built_${key}.bin"; then
    log_fail "${key}: could not remove stale build output."
    V_RESULT[$key]="ftbfs"; V_NOTE[$key]="could not remove stale build output"
    return 1
  fi
  "${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}/src:${MOUNT_PATH}" \
    "${BUILD_IMAGE}" \
    bash -c "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      if [ -f /root/esp/esp-idf/export.sh ]; then . /root/esp/esp-idf/export.sh
      else . /opt/esp/idf/export.sh; fi
      cd ${MOUNT_PATH}
      git config --global --add safe.directory ${MOUNT_PATH}
      git stash --quiet || true
      ${gen_cmd}
      idf.py fullclean all
    " || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_fail "${key}: build container failed (exit ${rc})."
    V_RESULT[$key]="ftbfs"; V_NOTE[$key]="build container failed with exit ${rc}"
    return 1
  fi
  # build/ lives inside the bind-mounted source tree, so it is on the host at
  # this path once the container exits.
  if [[ -f "${WORK_DIR}/src/build/jade.bin" ]]; then
    if ! cp "${WORK_DIR}/src/build/jade.bin" "${WORK_DIR}/built_${key}.bin"; then
      log_fail "${key}: could not stage build/jade.bin."
      V_RESULT[$key]="ftbfs"; V_NOTE[$key]="could not stage build/jade.bin"
      return 1
    fi
  fi
  if [[ ! -f "${WORK_DIR}/built_${key}.bin" ]]; then
    log_fail "${key}: build did not produce build/jade.bin."
    V_RESULT[$key]="ftbfs"; V_NOTE[$key]="idf.py fullclean all did not produce build/jade.bin"
    return 1
  fi
  return 0
}

compare_variant() {
  local key="$1" built_hash official_hash difffile
  built_hash="$(sha256_local "${WORK_DIR}/built_${key}.bin")"
  official_hash="$(sha256_local "${DL_DIR}/${key}.payload.bin")"
  V_BUILT[$key]="${built_hash}"; V_PAYLOAD[$key]="${official_hash}"
  echo
  echo "----- ${key} ($(variant_label "${key}")) -----"
  echo "officialCompressedHash (as downloaded): ${V_CMPHASH[$key]}"
  echo "officialSignedFullHash (decompressed):  ${V_FWHASH[$key]}"
  echo "officialPayloadHash (signature sector stripped, comparison basis): ${official_hash}"
  echo "builtHash:                              ${built_hash}"
  if [[ "${built_hash}" == "${official_hash}" ]]; then
    echo "RESULT: MATCH"
    V_RESULT[$key]="reproducible"
  else
    echo "RESULT: MISMATCH"
    # Full byte-level diff to a file, 5-line preview on the terminal, so an ABS
    # log is not swamped by a megabyte of cmp output.
    difffile="${WORK_DIR}/diff_${key}.txt"
    cmp -l "${WORK_DIR}/built_${key}.bin" "${DL_DIR}/${key}.payload.bin" > "${difffile}" 2>&1 || true
    echo "First 5 lines of byte-level diff (full diff: ${difffile}):"
    head -5 "${difffile}"
    V_RESULT[$key]="not_reproducible"
  fi
}

# Printed OUTSIDE the Begin/End Results markers on purpose: that block follows a
# key: value convention read field-by-field, so free prose must not sit in it.
print_hash_legend() {
  cat <<LEGEND

----- What these hashes mean -----
officialCompressedHash  SHA-256 of the file exactly as downloaded from
                        jadefw.blockstream.com/${ENDPOINT}, listed in index.json
                        as 'cmphash'. THIS is the official download hash to
                        publish. Reported below as 'appHash'.
officialSignedFullHash  SHA-256 after decompression, signatures still attached.
                        The value a Jade displays on screen during a firmware
                        update, listed in index.json as 'fwhash' and reported
                        below under that name. NOT the same value as appHash - a
                        user comparing the device screen must use fwhash.
officialPayloadHash     The same firmware with its last 4096 bytes removed -
                        Blockstream's signature sector. Published nowhere, shown
                        by no device. It exists only to be compared against a
                        locally built binary, which is unsigned.
builtHash               SHA-256 of the firmware this script built from the
                        source at tag ${VERSION}.

MATCH means builtHash == officialPayloadHash: the code Blockstream signed is the
code in the public repo at this tag. Do not publish officialPayloadHash or
builtHash as the 'official' hash.

signature / signingKeys / keyAnchors are INFORMATIONAL and never change the
verdict. Jade Core carries THREE Secure Boot v2 blocks in that 4096-byte sector
(classic Jade carries one). 'signature: VALID' means all three pass format,
CRC32 and RSA-PSS checks over the payload, with valid remaining-sector fill.

keyAnchors is the part classic Jade cannot have. Each block embeds the signer's
RSA-3072 public key, whose SHA-256 digest is what an ESP32-S3 burns into eFuse
SECURE_BOOT_DIGEST0/1/2. Blockstream publishes those three keys in the
repository at this same tag as release/scripts/v2pk{1,2,3}.pub, so the script
recomputes their digests from the tagged source and names each block's signer.
'ANCHORED' therefore means the signatures are tied to an artifact OUTSIDE the
firmware file - Blockstream's git tag - not only to a key lifted from the file
being checked. It still does not prove those digests are what a shipped Jade
Core enforces: that needs 'espefuse.py summary' on real hardware.
----------------------------------
LEGEND
}

print_disclaimer() {
  echo -e "${YELLOW}"
  echo "=============================================================================="
  echo "                               DISCLAIMER"
  echo "=============================================================================="
  echo "Please examine this script yourself prior to running it."
  echo "This script is provided as-is without warranty and may contain bugs or"
  echo "security vulnerabilities. Use at your own risk."
  echo "=============================================================================="
  echo -e "${NC}"
}

print_variant_detail() {
  local key="$1"
  printf '    %-46s %s\n' "appHash (as downloaded):" "${V_CMPHASH[$key]}"
  printf '    %-46s %s\n' "fwhash (shown on device):" "${V_FWHASH[$key]:-unavailable}"
  if [[ -n "${V_PAYLOAD[$key]:-}" ]]; then
    printf '    %-46s %s\n' "payloadHash (official, signature removed):" "${V_PAYLOAD[$key]}"
    printf '    %-46s %s\n' "builtHash (ours, must equal payloadHash):" "${V_BUILT[$key]}"
  fi
  if [[ -n "${V_SIGSTATE[$key]:-}" ]]; then
    printf '    %-46s %s\n' "signature (${V_SIGBLOCKS[$key]:-?} Secure Boot v2 blocks):" "${V_SIGSTATE[$key]}"
    printf '    %-46s %s\n' "keyAnchors (vs v2pk*.pub at this tag):" "${V_SIGANCHORS[$key]:-unavailable} [${V_ANCHORSTATE[$key]:-unavailable}]"
    printf '    %-46s %s\n' "signingKeys (eFuse DIGEST0/1/2):" "${V_SIGKEYS[$key]:-unavailable}"
  fi
}

main() {
  # FIRST action, before parse_args: the asciinema recording is the only artifact
  # attached to a published verification, so it must establish on its own which
  # script bytes produced the result - and an invalid-argument run exits at parse
  # time, so a later banner would not record which script failed. See
  # ws-notes/script-notes/script-version-and-hash.md.
  SCRIPT_SHA256="$(sha256_of "${SCRIPT_PATH}")"
  log_info "Script:  $(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION}"
  log_info "         sha256: ${SCRIPT_SHA256}"

  parse_args "$@"
  validate_inputs
  detect_container_cmd

  WORK_DIR="$(pwd)/blockstreamjadecore-work_${VERSION}_${TYPE:-all}_$$"
  DL_DIR="${WORK_DIR}/official/jade2.0c"
  mkdir -p "${DL_DIR}"

  print_disclaimer
  echo "Verifying Blockstream Jade Core v${VERSION} (${TYPE:-both published artifacts})"
  echo "Profile ${PROFILE} / ESP32-S3 / endpoint ${ENDPOINT}"
  echo "Work dir: ${WORK_DIR}"
  echo

  build_tools_image
  write_sigcheck_tool
  clone_checkout
  resolve_layout

  if [[ -f "${BINARY_PATH:-}" && -z "${TYPE}" ]] && ! resolve_binary_file_variant; then
    write_results "ftbfs" "Provided binary could not be bound uniquely to a Jade Core v${VERSION} index entry."
    exit "${EXIT_FAIL}"
  fi
  local variants=(); mapfile -t variants < <(requested_variants)

  # What this run does and does not cover, stated plainly. Core publishes exactly
  # two artifacts per release and COMPARISON_RESULTS.yaml carries one verdict, so
  # the honest description differs by mode and neither mode is a mistake: a
  # both-artifact run IS a complete Jade Core verification, a single-artifact run
  # is not and must not be described as one (per-artifact-verdict-model.md).
  if [[ ${#variants[@]} -gt 1 ]]; then
    log_info "This run covers BOTH published Jade Core artifacts for v${VERSION}: ble and noradio."
    log_info "COMPARISON_RESULTS.yaml carries one aggregate verdict for the pair - 'reproducible' only if BOTH match. Per-artifact results appear separately in the results block."
  else
    log_warn "Single-artifact run: only ${variants[0]} is covered. The other published Jade Core artifact for v${VERSION} is UNVERIFIED - do not describe this run as covering Jade Core v${VERSION} as a whole."
  fi

  for key in "${variants[@]}"; do
    [[ -f "${WORK_DIR}/index_${key}.json" ]] || preflight_variant "${key}" || true
  done
  local all_missing=true preflight_summary=""
  for key in "${variants[@]}"; do
    if [[ "${V_RESULT[$key]}" == "ftbfs" ]]; then
      preflight_summary+="${key}: ${V_NOTE[$key]}; "
    else
      all_missing=false
    fi
  done
  if [[ "${all_missing}" == true ]]; then
    write_results "ftbfs" "All requested Jade Core preflights failed for v${VERSION}. ${preflight_summary}No reproducibility verdict was computed."
    exit "${EXIT_FAIL}"
  fi

  build_upstream_image

  for key in "${variants[@]}"; do
    [[ "${V_RESULT[$key]}" == "ftbfs" ]] && continue
    if ! stage_official "${key}"; then
      log_fail "${key}: failed to download/verify the official artifact."
      V_RESULT[$key]="ftbfs"; V_NOTE[$key]="failed to stage or verify the official artifact"
      continue
    fi
    check_signature "${key}"
    if build_variant "${key}"; then compare_variant "${key}"; fi
  done

  print_hash_legend

  echo
  echo "===== Begin Results ====="
  echo "appId:   ${APP_ID}"
  echo "version: ${VERSION}"
  echo "arch:    ${ARCH}"
  echo "commit:  ${SRC_COMMIT}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256}"
  echo "profile: ${PROFILE} (production configs under ${PROD_CFG_PATH}/)"

  # With one artifact, appHash and friends are unambiguous and go at top level.
  # With two, a top-level appHash would silently name one artifact for both, so
  # each artifact prints its own labelled set instead.
  local single=""
  for key in "${variants[@]}"; do
    if [[ -n "${V_CMPHASH[$key]:-}" ]]; then
      if [[ -z "${single}" ]]; then single="${key}"; else single="MULTI"; fi
    fi
  done
  if [[ -n "${single}" && "${single}" != "MULTI" ]]; then
    echo "appHash:        ${V_CMPHASH[$single]}"
    echo "                  hash of the artifact as downloaded (index.json cmphash)"
    echo "fwhash:         ${V_FWHASH[$single]}"
    echo "                  hash shown on the device screen during firmware update"
    if [[ -n "${V_PAYLOAD[$single]:-}" ]]; then
      echo "payloadHash:    ${V_PAYLOAD[$single]}"
      echo "                  official firmware minus its 4096-byte signature sector"
      echo "builtHash:      ${V_BUILT[$single]}"
      echo "                  what this script built - must equal payloadHash above"
    fi
    if [[ -n "${V_SIGSTATE[$single]:-}" ]]; then
      echo "signature:      ${V_SIGSTATE[$single]}"
      echo "                  ${V_SIGBLOCKS[$single]:-?} Secure Boot v2 signatures over payloadHash"
      echo "keyAnchors:     ${V_SIGANCHORS[$single]:-unavailable} [${V_ANCHORSTATE[$single]:-unavailable}]"
      echo "                  block signers named from release/scripts/*.pub at this tag"
      echo "signingKeys:    ${V_SIGKEYS[$single]:-unavailable}"
      echo "                  key digests = eFuse SECURE_BOOT_DIGEST0/1/2"
    fi
  fi

  local reproducible=0 mismatched=0 unavailable=0 summary=""
  for key in "${variants[@]}"; do
    echo "${key} ($(variant_label "${key}")): ${V_RESULT[$key]:-ftbfs}"
    [[ -n "${V_CMPHASH[$key]:-}" && "${single}" == "MULTI" ]] && print_variant_detail "${key}"
    case "${V_RESULT[$key]:-ftbfs}" in
      reproducible) reproducible=$((reproducible+1)) ;;
      not_reproducible) mismatched=$((mismatched+1)) ;;
      *) unavailable=$((unavailable+1)) ;;
    esac
    summary="${summary}${key}: ${V_RESULT[$key]:-ftbfs}${V_NOTE[$key]:+ (${V_NOTE[$key]})}; "
  done
  echo "===== End Results ====="

  # Aggregate verdict. `reproducible` requires that EVERY requested artifact was
  # compared and matched - one that could not be built or downloaded must never
  # disappear into a clean pass for the set (per-artifact-verdict-model.md:
  # preserve partial results, never collapse a multi-artifact version into one
  # optimistic verdict).
  local verdict notes partial=""
  if [[ ${mismatched} -gt 0 ]]; then
    verdict="not_reproducible"
  elif [[ ${reproducible} -gt 0 && ${unavailable} -eq 0 ]]; then
    verdict="reproducible"
  elif [[ ${reproducible} -gt 0 ]]; then
    verdict="ftbfs"
    partial="PARTIAL RESULT: ${reproducible} of $((reproducible + unavailable)) requested artifacts were compared and matched; ${unavailable} could not be compared at all. Nothing mismatched. The aggregate verdict is 'ftbfs' rather than 'reproducible' because an unverifiable artifact must not be reported as a clean pass - see the per-artifact breakdown. "
  else
    verdict="ftbfs"
  fi

  notes="${partial}Blockstream Jade Core v${VERSION} (profile ${PROFILE}, ESP32-S3, endpoint ${ENDPOINT}), commit ${SRC_COMMIT}. Per-artifact: ${summary}Container mount path preserved at ${MOUNT_PATH} as REPRODUCIBLE.md documents (encoded into jade.map/jade.elf, whose hash is embedded in the image) - documented upstream, not independently measured for this target. Comparison strips the trailing 4096-byte signature sector, which on Jade Core holds three Secure Boot v2 blocks plus 0xFF fill, so this verifies the firmware payload and not the signatures over it. Signature and key-anchor results are informational and never affect this verdict."

  write_results "${verdict}" "${notes}"
  if [[ "${verdict}" == "reproducible" ]]; then exit "${EXIT_OK}"; else exit "${EXIT_FAIL}"; fi
}

main "$@"
