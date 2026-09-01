#!/bin/bash
# ==============================================================================
# blockstreamjadeplus_build.sh - Blockstream Jade Plus Reproducible Build Verifier
# ==============================================================================
# Version: v0.1.1
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-08-31
# Project: https://github.com/Blockstream/Jade
# ==============================================================================
#
# TECHNICAL DISCLAIMER: provided for technical analysis and reproducible build
# verification only. No warranty is provided. Review all operations first.
#
# SCOPE: Jade Plus only - upstream profile "jade_v2", ESP32-S3, endpoint
# bin/jade2.0, two published artifacts per release ("ble" and "noradio").
# Classic Jade is covered by blockstreamjade_build.sh. Jade Core ("jade_v2c",
# bin/jade2.0c) is a different product with its own binaries and is NOT covered -
# a Plus verdict says nothing about a Core artifact.
#
# SUPPORTED TAGS: 1.0.39 and later. Plus is jade_v2s3 at 1.0.33-1.0.36 and
# jade_v2 at 1.0.37-1.0.38, but none has tools/switch_to.sh. WalletScrutiny has
# not exercised that manual layout, so this script rejects it instead of guessing.
#
# The script binds official inputs to bin/jade2.0/index.json, builds both variants
# at upstream's required mount path, strips the 4096-byte signing sector, and
# compares payloads. It separately validates the three Secure Boot v2 blocks and
# anchors their keys to release/scripts/v2pk{1,2,3}.pub at the tag.

set -eEuo pipefail

SCRIPT_VERSION="v0.1.1"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
APP_ID="blockstreamjadeplus"
REPO_URL="https://github.com/Blockstream/Jade"
FW_HOST="https://jadefw.blockstream.com"
ENDPOINT="bin/jade2.0"
PROFILE="jade_v2"
CHIP="esp32s3"
# REPRODUCIBLE.md requires this path because the ELF hash reaches the firmware.
# The requirement is documented, not independently measured for Plus.
MOUNT_PATH="/builds/blockstream/jade"
MIN_VERSION="1.0.39"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
TOOLS_BASE_IMAGE="debian:bookworm-slim@sha256:12c396bd585df7ec21d5679bb6a83d4878bc4415ce926c9e5ea6426d23c60bdc"

# Expected key order; observed digests only warn about a possible rotation.
EXPECTED_KEY_FILES="v2pk1.pub v2pk2.pub v2pk3.pub"
OBSERVED_KEY_DIGESTS="7f71d4718564cbc5d638d60ad69556be91bf043a8723a8f39509d2ae998f7182,f668192cb30c8c9c464e1c752d87ef6bc9c5c0d30aa3ae3482991f002d2dae01,c06f981532971e721e59ad32c24fc28fb4f4a08719c6125803646d11ab3e9708"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH=""
TYPE=""
BINARY_PATH=""
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_USER_ARGS=()
TOOLS_IMAGE=""
BUILD_IMAGE=""
SRC_COMMIT=""

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_fail() { echo -e "${RED}[FAIL] $*${NC}" >&2; }

# Hashes a host-side file, returning N/A rather than failing, so a hashing
# problem can never abort a run under `set -eEuo pipefail`. Distinct from
# sha256_local() below, which is only ever handed files known to exist.
sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}
sha256_local() { sha256sum "$1" | awk '{print $1}'; }

declare -A V_RESULT V_NOTE V_CMPHASH V_FWHASH V_PAYLOAD V_BUILT
declare -A V_SIGSTATE V_SIGKEYS V_SIGDIGESTS V_KEYMATCH V_SIGBLOCKS V_FILE

# COMPARISON_RESULTS.yaml carries exactly three fields - script_version, verdict,
# optional notes. No date, no results array, no architecture, no .txt companion.
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

# Recover user ownership even when a root build container is killed.
normalize_ownership() {
  local uid gid
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] || return 0
  find "${WORK_DIR}" ! -uid "$(id -u)" -print -quit 2>/dev/null | grep -q . || return 0
  uid="$(id -u)"; gid="$(id -g)"
  log_warn "Files under ${WORK_DIR} are not owned by UID ${uid}; normalising so a plain rm -rf can remove them."
  if [[ "${CONTAINER_CMD}" == "podman" ]]; then
    podman unshare chown -R 0:0 "${WORK_DIR}" >/dev/null 2>&1 || true
  elif [[ -n "${CONTAINER_CMD}" ]]; then
    "${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/work" "${TOOLS_BASE_IMAGE}" \
      chown -R "${uid}:${gid}" /work >/dev/null 2>&1 || true
  fi
  if find "${WORK_DIR}" ! -uid "${uid}" -print -quit 2>/dev/null | grep -q .; then
    log_warn "Ownership normalisation did not fully succeed. Some files under ${WORK_DIR} may need manual cleanup."
  fi
}
trap normalize_ownership EXIT

handle_err() {
  local rc=$?
  trap - ERR
  log_fail "Unexpected error (exit ${rc})."
  write_results "ftbfs" "Blockstream Jade Plus v${VERSION:-unknown} (${TYPE:-both Plus artifacts}): script failed before a verdict could be computed. Work dir: ${WORK_DIR:-unset}"
  exit "${EXIT_FAIL}"
}
trap handle_err ERR

usage() {
  cat <<USAGE
blockstreamjadeplus_build.sh ${SCRIPT_VERSION} - Blockstream Jade Plus firmware verifier

Usage:
  $0 --version VERSION [--type TYPE] [--arch ARCH] [--binary PATH]

Parameters:
  --version VERSION   Firmware tag without 'v' prefix, e.g. 1.0.41. Required.
                      Numeric X.Y.Z only (beta tags rejected). ${MIN_VERSION}+
                      only; earlier tags lack tools/switch_to.sh.
  --type TYPE         One Jade Plus artifact, or omit / "all" / "jadeplus" for
                      both: jadeplus-ble, jadeplus-noradio (both ${ENDPOINT}).
  --arch ARCH         ABS compatibility parameter, ignored with a warning: Jade
                      Plus is an ESP32-S3 and switch_to.sh sets the target.
  --binary PATH       Official compressed file (identified by index hash), or a
                      directory containing index-named files for jadeplus/all.
  --apk PATH          Not applicable to hardware; a --binary alias.
  --help              Show this help.

Exit codes: 0 = reproducible, 1 = not reproducible / ftbfs, 2 = invalid parameters.
USAGE
}

require_value() {
  if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    log_fail "Missing value for $1"; exit "${EXIT_INVALID}"
  fi
}

# Unknown arguments warn and continue, never fatal (Luis, 2026-03-11): ABS passes
# parameters this script does not know, and a hard exit would turn a verifiable
# release into an invalid-parameter failure.
parse_args() {
  if [[ $# -eq 0 ]]; then usage; exit "${EXIT_INVALID}"; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) require_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
      --arch) require_value "$1" "${2:-}"; ARCH="$2"; shift 2 ;;
      --type) require_value "$1" "${2:-}"; TYPE="$2"; shift 2 ;;
      --binary) require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --apk) log_warn "--apk is not applicable to hardware; treating as --binary."
             require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --help|-h) usage; exit "${EXIT_OK}" ;;
      *) log_warn "Unknown argument: $1 (ignored)"; shift ;;
    esac
  done
}

# "jadeplus" alone is the type string the WalletScrutiny page declares
# (_hardware/blockstreamjadeplus.md, types: jadeplus) for what are really two
# artifacts, so it means "both", not a third variant.
normalize_type() {
  case "${1,,}" in
    ""|all|jadeplus|jade_v2|jade2.0|plus) echo "" ;;
    jadeplus-ble|jade_v2-ble|jade2.0-ble|plus-ble|ble) echo "jadeplus-ble" ;;
    jadeplus-noradio|jade_v2-noradio|jade2.0-noradio|plus-noradio|noradio) echo "jadeplus-noradio" ;;
    *) echo "INVALID" ;;
  esac
}

validate_inputs() {
  if [[ -z "${VERSION}" ]]; then
    log_fail "--version is required (this script does not auto-detect the firmware version from --binary)."
    exit "${EXIT_INVALID}"
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_fail "Invalid --version '${VERSION}'. Expected numeric X.Y.Z (e.g. 1.0.41). Beta tags (e.g. 1.0.39-beta2) are not supported."
    exit "${EXIT_INVALID}"
  fi
  local IFS=. va vb vc ma mb mc
  read -r va vb vc <<<"${VERSION}"; read -r ma mb mc <<<"${MIN_VERSION}"
  if (( va<ma || (va==ma && vb<mb) || (va==ma && vb==mb && vc<mc) )); then
    log_fail "--version ${VERSION} is below ${MIN_VERSION}. Earlier Plus tags have no tools/switch_to.sh; their manual layout is unsupported."
    exit "${EXIT_INVALID}"
  fi

  # ARCH is a label only. tools/switch_to.sh:76 sets ARCH="esp32s3" for jade_v2
  # and :293 runs `idf.py set-target $ARCH` itself, so nothing passed here changes
  # the target; fighting it would only create a second source of truth.
  if [[ -n "${ARCH}" && "${ARCH}" != "${CHIP}" ]]; then
    log_warn "Ignoring --arch '${ARCH}': the ESP32-S3 target is set by tools/switch_to.sh from the '${PROFILE}' profile, not by this script."
  fi
  ARCH="${CHIP}"

  TYPE="$(normalize_type "${TYPE}")"
  if [[ "${TYPE}" == "INVALID" ]]; then
    log_fail "Unsupported --type. Use jadeplus-ble, jadeplus-noradio, or omit (or 'jadeplus'/'all') for both."
    exit "${EXIT_INVALID}"
  fi

  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ ! -f "${BINARY_PATH}" && ! -d "${BINARY_PATH}" ]]; then
      log_fail "--binary file or directory not found: ${BINARY_PATH}"; exit "${EXIT_INVALID}"
    fi
  fi
}

detect_container_cmd() {
  # No --format docker here, unlike blockstreamjade_build.sh. That flag makes
  # podman honour a `SHELL ["/bin/bash","-c"]` instruction, needed at 1.0.35-1.0.38.
  # `grep -c '^SHELL' Dockerfile` is 0 at 1.0.39, 1.0.40 and 1.0.41 - the whole
  # supported range - so carrying it would be a dead workaround.
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

# The upstream build image bakes its ESP-IDF environment in as root, so the build
# container is not user-mapped; this restores host ownership of the bind-mounted
# source tree on exit. Same mechanism as the classic sibling script, whose 1.0.41
# run left nothing foreign-owned behind.
chown_back() {
  local uid gid; uid="$(id -u)"; gid="$(id -g)"
  printf 'chown -R %s:%s "%s" >/dev/null 2>&1 || true' "${uid}" "${gid}" "$1"
}

variant_radio() { case "$1" in *-noradio) echo noradio ;; *) echo ble ;; esac; }
variant_label() {
  case "$1" in
    jadeplus-ble) echo "Jade Plus (BLE)" ;;
    jadeplus-noradio) echo "Jade Plus (no-radio)" ;;
  esac
}
requested_variants() {
  if [[ -n "${TYPE}" ]]; then echo "${TYPE}";
  else printf '%s\n' jadeplus-ble jadeplus-noradio; fi
}

# Validate every signature block and anchor its ESP32-S3 key digest to tagged
# public keys. Informational only; hardware inspection is needed to prove eFuses.
write_sigcheck_tool() {
  cat > "${WORK_DIR}/ws_sigcheck.py" <<'PYEOF'
import glob, hashlib, os, struct, sys, zlib
SECTOR, BLOCK, MAGIC, VER = 4096, 1216, 0xE7, 0x02
FMT = "<BB2s32s384sI384sI384sI16s"
def emit(k, v): print("%s=%s" % (k, v))
def bail(state, detail):
    emit("SIGSTATE", state); emit("SIGBLOCKS", "0"); emit("KEYMATCH", "UNAVAILABLE")
    emit("SIGDETAIL", detail); sys.exit(0)
try:
    signed = open(sys.argv[1], "rb").read()
    keydir = sys.argv[2] if len(sys.argv) > 2 else ""
    expected = sys.argv[3].split(",") if len(sys.argv) > 3 and sys.argv[3] else []
    if len(signed) <= SECTOR:
        bail("UNAVAILABLE", "file smaller than one signature sector")
    payload, sector = signed[:-SECTOR], signed[-SECTOR:]
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils
    # ESP-IDF signs the image 0xFF-padded to a sector boundary. Every Plus payload
    # observed is already aligned so this is a no-op, but it is part of the scheme.
    padded = payload + b"\xff" * ((-len(payload)) % SECTOR)
    calc = hashlib.sha256(padded).digest()
    def kdig(mod, exp, rinv, mprime):
        return hashlib.sha256(struct.pack("<384sI384sI", mod, exp, rinv, mprime)).hexdigest()
    # Reference digests from the repo's published public keys at the tag. Dev keys
    # are read too, so firmware signed with one is NAMED, not "unknown".
    ref = {}
    for path in sorted(glob.glob(os.path.join(keydir, "*.pub"))) if keydir else []:
        try:
            pub = serialization.load_pem_public_key(open(path, "rb").read())
            n, e, sz = pub.public_numbers().n, pub.public_numbers().e, pub.key_size
            r = kdig(n.to_bytes(384, "little"), e,
                     ((1 << (sz * 2)) % n).to_bytes(384, "little"),
                     (-pow(n, -1, 1 << 32)) % (1 << 32))
            ref[r] = os.path.basename(path)
        except Exception:
            pass
    states, digests, names, nblocks = [], [], [], 0
    for i in range(SECTOR // BLOCK):
        blk = sector[i * BLOCK:(i + 1) * BLOCK]
        if len(blk) < BLOCK or blk[0] != MAGIC:
            break
        nblocks += 1
        _m, ver, reserved, digest, mod, exp, rinv, mprime, sig, crc, pad = struct.unpack(FMT, blk)
        kd = kdig(mod, exp, rinv, mprime)
        if ver != VER or reserved != b"\0\0" or pad != b"\0" * 16:
            st = "FORMAT-INVALID"
        elif crc != (zlib.crc32(blk[:1196]) & 0xffffffff):
            st = "CRC-INVALID"
        elif digest != calc:
            st = "DIGEST-MISMATCH"
        else:
            try:
                rsa.RSAPublicNumbers(e=exp, n=int.from_bytes(mod, "little")).public_key().verify(
                    sig[::-1], calc,
                    padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32),
                    utils.Prehashed(hashes.SHA256()))
                st = "VALID"
            except Exception:
                st = "INVALID"
        states.append(st); digests.append(kd); names.append(ref.get(kd, "UNKNOWN"))
        emit("SIGBLOCK%d" % i, "offset=0x%04X state=%s key=%s digest=%s" % (i * BLOCK, st, names[-1], kd))
    if nblocks == 0:
        bail("UNAVAILABLE", "no Secure Boot v2 block found in the trailing sector")
    tail = sector[nblocks * BLOCK:]
    emit("SIGBLOCKS", str(nblocks))
    emit("SIGFILL", "%d bytes after the last block, all 0xFF: %s"
         % (len(tail), "yes" if set(tail) <= {0xFF} else "NO"))
    if set(tail) - {0xFF}:
        states.append("FILL-INVALID")
    emit("SIGSTATE", "VALID" if set(states) == {"VALID"} else ",".join(sorted(set(states))))
    emit("SIGKEYS", ",".join(names))
    emit("SIGDIGESTS", ",".join(digests))
    if not ref:
        emit("KEYMATCH", "UNAVAILABLE")
        emit("SIGDETAIL", "no reference .pub keys were found at the tag to anchor against")
    elif expected and names == expected:
        emit("KEYMATCH", "OK")
    elif "UNKNOWN" in names:
        emit("KEYMATCH", "UNKNOWN-KEY")
        emit("SIGDETAIL", "at least one signing key is not published in release/scripts/ at this tag")
    else:
        emit("KEYMATCH", "UNEXPECTED-SET")
        emit("SIGDETAIL", "keys are published at this tag but not the expected ordered set %s" % ",".join(expected))
except ImportError as exc:
    bail("UNAVAILABLE", "python3-cryptography not present: %s" % exc)
except Exception as exc:
    bail("UNAVAILABLE", "signature parse failed: %s" % exc)
PYEOF
}

check_signature() {
  local key="$1" res="" detail="" expected_csv
  [[ -f "${WORK_DIR}/official_${key}.full.bin" ]] || return 0
  expected_csv="${EXPECTED_KEY_FILES// /,}"
  res="$("${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" \
        "${TOOLS_IMAGE}" python3 /work/ws_sigcheck.py "/work/official_${key}.full.bin" \
        /work/src/release/scripts "${expected_csv}" 2>&1 || true)"
  echo "${res}" | grep -E '^SIGBLOCK[0-9]=' || true
  V_SIGSTATE[$key]="$(sed -n 's/^SIGSTATE=//p' <<<"${res}" | head -1)"
  V_SIGKEYS[$key]="$(sed -n 's/^SIGKEYS=//p' <<<"${res}" | head -1)"
  V_SIGDIGESTS[$key]="$(sed -n 's/^SIGDIGESTS=//p' <<<"${res}" | head -1)"
  V_KEYMATCH[$key]="$(sed -n 's/^KEYMATCH=//p' <<<"${res}" | head -1)"
  V_SIGBLOCKS[$key]="$(sed -n 's/^SIGBLOCKS=//p' <<<"${res}" | head -1)"
  detail="$(sed -n 's/^SIGDETAIL=//p' <<<"${res}" | head -1)"
  [[ -z "${V_SIGSTATE[$key]}" ]] && V_SIGSTATE[$key]="UNAVAILABLE"
  [[ -z "${V_KEYMATCH[$key]}" ]] && V_KEYMATCH[$key]="UNAVAILABLE"

  # Three blocks is what every Plus artifact examined carries. A different count
  # is not a verdict change, but it is a surprise worth surfacing.
  if [[ "${V_SIGBLOCKS[$key]}" != "3" ]]; then
    log_warn "${key}: expected 3 Secure Boot v2 signature blocks (Plus is signed 3-of-3), found ${V_SIGBLOCKS[$key]:-0}. Verdict unaffected; investigate before publishing."
  fi
  case "${V_SIGSTATE[$key]}" in
    VALID) : ;;
    UNAVAILABLE) log_warn "${key}: signature check unavailable${detail:+ (${detail})}. Verdict unaffected." ;;
    *) log_warn "${key}: SIGNATURE CHECK FAILED (${V_SIGSTATE[$key]})${detail:+ - ${detail}}. Verdict unaffected, but investigate before publishing." ;;
  esac
  case "${V_KEYMATCH[$key]}" in
    OK) log_info "${key}: signing keys ANCHORED - blocks 0/1/2 match ${EXPECTED_KEY_FILES// /, } from release/scripts/ at tag ${VERSION}." ;;
    UNAVAILABLE) log_warn "${key}: signing keys could not be anchored${detail:+ (${detail})}. Verdict unaffected." ;;
    *) log_warn "${key}: SIGNING KEY ANCHOR FAILED (${V_KEYMATCH[$key]})${detail:+ - ${detail}}. Found: ${V_SIGKEYS[$key]:-none}. Expected: ${EXPECTED_KEY_FILES// /, }. Verdict unaffected, investigate before publishing." ;;
  esac
  if [[ -n "${V_SIGDIGESTS[$key]:-}" && "${V_SIGDIGESTS[$key]}" != "${OBSERVED_KEY_DIGESTS}" ]]; then
    log_warn "${key}: signing key digests differ from those observed across the 1.0.41 Plus artifacts. This may be a published key rotation - they still had to match the repo .pub files above - but confirm before publishing."
  fi
  return 0
}

build_tools_image() {
  local dockerfile="${WORK_DIR}/Dockerfile.tools"
  cat > "${dockerfile}" <<DOCKERFILE
FROM ${TOOLS_BASE_IMAGE}
RUN apt-get update -qq && apt-get install -y --no-install-recommends \\
    git ca-certificates curl jq python3-minimal python3-cryptography >/dev/null \\
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  TOOLS_IMAGE="walletscrutiny-jadeplus-tools:${VERSION}-$$"
  "${CONTAINER_CMD}" build -q -t "${TOOLS_IMAGE}" -f "${dockerfile}" "${WORK_DIR}" >/dev/null
}

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

# Fail loudly rather than guess. Three things must hold for the recipe below to be
# the one upstream documents: tools/switch_to.sh exists, it has a jade_v2 arm, and
# the production sdkconfig it selects is at one of the two locations upstream has
# used (production/ to 1.0.40, configs/production/ from 1.0.41). switch_to.sh
# resolves that path itself, so this is only a guard against an unseen layout.
resolve_layout() {
  local out
  out="$("${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" bash -c '
      set -u
      s=/work/src/tools/switch_to.sh
      [ -f "$s" ] || { echo "NO_SWITCH_TO"; exit 0; }
      grep -qE "^[[:space:]]*jade_v2\)" "$s" || { echo "NO_JADE_V2_ARM"; exit 0; }
      if   [ -f /work/src/configs/production/sdkconfig_jade_v2_prod.defaults ]; then echo "OK configs/production"
      elif [ -f /work/src/production/sdkconfig_jade_v2_prod.defaults ];         then echo "OK production"
      else echo "NO_PROD_CONFIG"; fi
    ')"
  case "${out}" in
    OK*)
      log_info "Layout check passed: tools/switch_to.sh has a ${PROFILE} arm, production sdkconfig under ${out#OK }/." ;;
    *)
      log_fail "Tag ${VERSION}: unrecognised repository layout for Jade Plus (${out})."
      write_results "ftbfs" "Unsupported repo layout at tag ${VERSION} (${out}): this script requires tools/switch_to.sh with a '${PROFILE}' profile arm and a production sdkconfig under configs/production/ or production/. It refused to guess a build recipe. Script needs updating for this tag."
      exit "${EXIT_FAIL}" ;;
  esac
}

# ONE upstream defect is worked around, because it bites at every supported tag:
# `FROM blockstream/jade_builder_base@sha256:...` is an unqualified NAMESPACED ref.
# Docker assumes Docker Hub; podman refuses without an unqualified-search registry,
# which needs root on the build host. The ref is digest-pinned, so the prefix
# cannot change which image is pulled. Two classic-script workarounds are NOT
# carried: the old cbor2/setuptools cap (the supported pins have many artifacts,
# but platform wheel selection remains unverified until a real build), and podman
# `--format docker` (no supported Dockerfile has the SHELL instruction it served).
patch_dockerfile() {
  local pyfile="${WORK_DIR}/ws_patch_dockerfile.py" rc=0
  cat > "${pyfile}" <<'PYEOF'
import os, re, sys
dockerfile = "/work/src/Dockerfile"
if not os.path.exists(dockerfile):
    print("WS-PATCH: no Dockerfile at this tag."); sys.exit(3)
df = open(dockerfile).read(); before = df
def qualify(m):
    ref = m.group(2); head = ref.split("/")[0]
    if "/" in ref and "." not in head and ":" not in head and head != "localhost":
        return m.group(1) + "docker.io/" + ref
    return m.group(0)
df = re.sub(r"(?m)^(FROM\s+)(\S+)", qualify, df)
if df != before:
    open(dockerfile, "w").write(df)
    print("WS-PATCH: qualified namespaced FROM image with docker.io/ (digest pin unchanged)")
else:
    print("WS-PATCH: FROM already registry-qualified; no change needed.")
PYEOF
  "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    python3 /work/ws_patch_dockerfile.py || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_fail "Dockerfile patch refused (exit ${rc}): this tag has no Dockerfile where one is expected."
    write_results "ftbfs" "Blockstream Jade Plus v${VERSION}: no Dockerfile found at the tag, so the upstream build environment could not be reconstructed. Script needs updating for this tag."
    exit "${EXIT_FAIL}"
  fi
}

build_upstream_image() {
  patch_dockerfile
  BUILD_IMAGE="walletscrutiny-jadeplus-builder:${VERSION}-$$"
  log_info "Building the upstream Dockerfile from tag ${VERSION}. It layers Jade's pinned Python requirements onto Blockstream's digest-pinned ESP-IDF base image, whose unified Xtensa toolchain already covers esp32 and esp32s3 - no extra idf_tools.py install for Plus. Expect several GB of pull."
  "${CONTAINER_CMD}" build -q -f "${WORK_DIR}/src/Dockerfile" -t "${BUILD_IMAGE}" "${WORK_DIR}/src" >/dev/null
}

# Confirms the release publishes this artifact before build time is spent.
# index.json's schema is identical across all four Jade endpoints, so this is the
# selector the classic script already uses.
preflight_variant() {
  local key="$1" config entry
  config="$(variant_radio "${key}")"
  log_info "Checking official index: ${ENDPOINT}/index.json (${key}, config=${config})"
  if ! entry="$("${CONTAINER_CMD}" run --rm "${TOOLS_IMAGE}" bash -c "
      set -euo pipefail
      curl -sSL --fail --max-time 30 -o /tmp/index.json '${FW_HOST}/${ENDPOINT}/index.json'
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
    log_warn "${key}: no official artifact published for v${VERSION} at ${ENDPOINT} (config=${config})."
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
  for key in jadeplus-ble jadeplus-noradio; do
    preflight_variant "${key}" || return 1
    expected="$(official_json_field "${key}" cmphash)" || return 1
    if [[ "${actual}" == "${expected}" ]]; then match="${key}"; matches=$((matches+1)); fi
  done
  if [[ "${matches}" -ne 1 ]]; then
    log_fail "--binary hash matches ${matches} Jade Plus index entries for v${VERSION}; expected exactly one."
    return 1
  fi
  TYPE="${match}"
  log_info "Identified --binary as ${TYPE} from ${ENDPOINT}/index.json."
}

# Downloads go into a per-endpoint subdirectory. Filenames are
# {version}_{config}_{fwsize}_fw.bin, so two endpoints producing the same image
# size for one version and config publish byte-different files under identical
# names. bin/jade2.0 has no such collision today, but bin/jade1.1 and
# bin/jade2.0c do, so per-endpoint storage keeps correctness independent of a
# count that can change with any release.
stage_official() {
  local key="$1" filename dl dldir src
  dldir="${WORK_DIR}/official/${ENDPOINT}"
  mkdir -p "${dldir}"
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
    dl="${dldir}/${filename}"
    if ! cp "${src}" "${dl}"; then log_fail "${key}: could not stage --binary ${src}."; return 1; fi
    log_info "${key}: using --binary ${src}; binding it to ${ENDPOINT}/index.json."
  else
    dl="${dldir}/${filename}"
    log_info "${key}: downloading official artifact ${filename} into official/${ENDPOINT}/"
    "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
      bash -c "curl -sSL --fail --max-time 120 -o '/work/official/${ENDPOINT}/${filename}' '${FW_HOST}/${ENDPOINT}/${filename}'"
  fi
  V_FILE[$key]="${filename}"

  # appHash is the artifact EXACTLY as downloaded - compressed, before any
  # decompression or strip. An inner form here is the GitLab 957 defect class.
  local cmp_hash_actual full_hash_actual
  cmp_hash_actual="$(sha256_local "${dl}")"
  V_CMPHASH[$key]="${cmp_hash_actual}"

  local cmphash_expected
  cmphash_expected="$(official_json_field "${key}" cmphash)"
  if [[ "${cmp_hash_actual}" != "${cmphash_expected}" ]]; then
    log_fail "${key}: artifact does not match index.json cmphash (expected ${cmphash_expected}, got ${cmp_hash_actual})."
    return 1
  fi

  # Raw zlib, not gzip, despite the .bin naming: tools/fwtools.py:91-95 compresses
  # with zopfli.zlib and decompresses with plain zlib.decompress. `gunzip` fails
  # here; `pigz -z -d` works for the same reason.
  cp "${dl}" "${WORK_DIR}/official_${key}.dl.bin"
  "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    bash -c "python3 -c \"import zlib; d=open('/work/official_${key}.dl.bin','rb').read(); open('/work/official_${key}.full.bin','wb').write(zlib.decompress(d))\""

  full_hash_actual="$(sha256_local "${WORK_DIR}/official_${key}.full.bin")"
  V_FWHASH[$key]="${full_hash_actual}"
  local fwhash_expected fwsize_expected actual_size
  fwhash_expected="$(official_json_field "${key}" fwhash)"
  fwsize_expected="$(official_json_field "${key}" fwsize)"
  actual_size="$(stat -c %s "${WORK_DIR}/official_${key}.full.bin")"
  if [[ "${full_hash_actual}" != "${fwhash_expected}" ]]; then
    log_fail "${key}: decompressed artifact does not match index.json fwhash (expected ${fwhash_expected}, got ${full_hash_actual})."
    return 1
  fi
  if [[ "${actual_size}" != "${fwsize_expected}" ]]; then
    log_fail "${key}: decompressed size ${actual_size} does not match index.json fwsize ${fwsize_expected}."
    return 1
  fi
  if [[ "${actual_size}" -le 4096 ]]; then
    log_fail "${key}: signed firmware is too short to contain a signature sector."
    return 1
  fi

  # The trailing sector is 4096 bytes on Plus exactly as on classic - Plus just
  # fills it with three 1216-byte blocks plus 448 bytes of 0xFF where classic has
  # one block plus 2880. The strip is still `head -c -4096`; do NOT use 3 x 1216.
  head -c -4096 "${WORK_DIR}/official_${key}.full.bin" > "${WORK_DIR}/official_${key}.payload.bin"
}

build_variant() {
  local key="$1" radio gen_cmd chown_cmd rc=0
  radio="$(variant_radio "${key}")"
  if [[ "${radio}" == "noradio" ]]; then
    gen_cmd="./tools/switch_to.sh ${PROFILE} --noradio"
  else
    gen_cmd="./tools/switch_to.sh ${PROFILE}"
  fi
  chown_cmd="$(chown_back "${WORK_DIR}/src")"
  log_info "Building ${key} ($(variant_label "${key}")): ${gen_cmd}"
  log_info "  switch_to.sh picks the production sdkconfig, sets ARCH=${CHIP} and runs 'idf.py set-target' itself, so the target is never specified twice."
  if ! rm -f "${WORK_DIR}/src/build/jade.bin" "${WORK_DIR}/built_${key}.bin"; then
    log_fail "${key}: could not remove stale build output."
    V_RESULT[$key]="ftbfs"; V_NOTE[$key]="could not remove stale build output"
    return 1
  fi
  # Bind-mounted at MOUNT_PATH because REPRODUCIBLE.md:29 requires it - see the
  # MOUNT_PATH comment above (documented by upstream, not measured by us).
  "${CONTAINER_CMD}" run --rm \
    -v "${WORK_DIR}/src:${MOUNT_PATH}" \
    "${BUILD_IMAGE}" \
    bash -c "
      set -euo pipefail
      trap '${chown_cmd}' EXIT
      idf_root=\"\${IDF_PATH:-/opt/esp/idf}\"
      if [ ! -f \"\${idf_root}/export.sh\" ]; then
        echo 'ws: no ESP-IDF export.sh found in the upstream build image' >&2; exit 1
      fi
      . \"\${idf_root}/export.sh\"
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
  # build/ lives inside the bind-mounted source tree, so it is already visible on
  # the host at this path once the container exits.
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
  local key="$1" built_hash official_hash
  built_hash="$(sha256_local "${WORK_DIR}/built_${key}.bin")"
  official_hash="$(sha256_local "${WORK_DIR}/official_${key}.payload.bin")"
  V_BUILT[$key]="${built_hash}"; V_PAYLOAD[$key]="${official_hash}"
  echo
  cat <<CMP
----- ${key} ($(variant_label "${key}")) -----
officialCompressedHash (as downloaded): ${V_CMPHASH[$key]}
officialSignedFullHash (decompressed):  ${V_FWHASH[$key]}
officialPayloadHash (signature stripped, comparison basis): ${official_hash}
builtHash:                              ${built_hash}
CMP
  if [[ "${built_hash}" == "${official_hash}" ]]; then
    echo "RESULT: MATCH"
    V_RESULT[$key]="reproducible"
  else
    echo "RESULT: MISMATCH"
    # Full diff to a file, 5-line preview to the terminal, so a large
    # mismatch cannot swamp the build server log.
    local difffile="${WORK_DIR}/diff_${key}.txt"
    cmp -l "${WORK_DIR}/built_${key}.bin" "${WORK_DIR}/official_${key}.payload.bin" > "${difffile}" 2>&1 || true
    echo "First 5 lines of the byte diff (full diff: ${difffile}):"
    head -5 "${difffile}"
    V_RESULT[$key]="not_reproducible"
  fi
}

# Printed OUTSIDE the Begin/End Results markers on purpose: that block follows a
# key: value convention read field-by-field, so free text must not go inside it.
print_hash_legend() {
  cat <<LEGEND

----- What these hashes mean -----
officialCompressedHash  SHA-256 of the file exactly as downloaded from
                        jadefw.blockstream.com, listed in index.json as
                        'cmphash'. THIS is the official download hash to
                        publish. Reported below as 'appHash'.
officialSignedFullHash  SHA-256 after decompression, signature sector still
                        attached; index.json calls it 'fwhash'. This is what
                        a Jade Plus displays on screen during a firmware
                        update. It is NOT appHash - a user comparing the
                        device screen must use fwhash.
officialPayloadHash     The same firmware with its last 4096 bytes - the
                        signature sector - removed. Published nowhere, shown
                        by no device. It exists only to be compared against a
                        locally built binary, which is unsigned.
builtHash               SHA-256 of what this script built from the source at
                        tag ${VERSION}.

MATCH means builtHash == officialPayloadHash: the code Blockstream signed is
the code in the public repo at this tag.
Do not publish officialPayloadHash or builtHash as the 'official' hash.

----- What the signature lines mean -----
signature / keyAnchor are INFORMATIONAL and never change the verdict.
A Jade Plus artifact carries THREE Secure Boot v2 signature blocks in that
4096-byte sector, at 0x0000 / 0x04C0 / 0x0980, plus 448 bytes of 0xFF fill.
Classic Jade carries one block and 2880 bytes of fill: three blocks means
three signing operations by three keys (release/scripts/v2applysigs.sh).
signature VALID means every present block is a mathematically valid RSA-PSS
signature over exactly the payload compared above, so the signatures cover
the bytes we rebuilt from public source.
keyAnchor is the stronger claim, and is what Plus can do and classic cannot.
Blockstream publishes the three Plus signing PUBLIC keys in the repo
(release/scripts/v2pk1.pub, v2pk2.pub, v2pk3.pub), so keys recovered from the
firmware are checked against material from OUTSIDE it, at the same git tag.
OK means each block's key digest equalled the matching published .pub file's
digest, in order - anchored, not the circular self-check classic is limited
to. What it still does NOT prove: that these are the digests a shipped Jade
Plus enforces in its eFuses. Each digest below is what an ESP32-S3 burns into
SECURE_BOOT_DIGEST0/1/2, so a device owner can settle that with
'espefuse.py summary' on their own hardware.
----------------------------------
LEGEND
}

print_disclaimer() {
  echo -e "${YELLOW}"
  cat <<'DISCLAIMER'
==============================================================================
                               DISCLAIMER
==============================================================================
Please examine this script yourself prior to running it.
This script is provided as-is without warranty and may contain bugs or
security vulnerabilities. Use at your own risk.
==============================================================================
DISCLAIMER
  echo -e "${NC}"
}

print_variant_detail() {
  local key="$1"
  printf '    %-46s %s\n' "artifact file:" "${V_FILE[$key]:-unavailable}"
  printf '    %-46s %s\n' "appHash (as downloaded):" "${V_CMPHASH[$key]:-unavailable}"
  printf '    %-46s %s\n' "fwhash (shown on the device screen):" "${V_FWHASH[$key]:-unavailable}"
  if [[ -n "${V_PAYLOAD[$key]:-}" ]]; then
    printf '    %-46s %s\n' "payloadHash (official, signature removed):" "${V_PAYLOAD[$key]}"
    printf '    %-46s %s\n' "builtHash (ours, must equal payloadHash):" "${V_BUILT[$key]}"
  fi
  if [[ -n "${V_SIGSTATE[$key]:-}" ]]; then
    printf '    %-46s %s\n' "signature (Secure Boot v2, ${V_SIGBLOCKS[$key]:-0} blocks):" "${V_SIGSTATE[$key]}"
    printf '    %-46s %s\n' "keyAnchor (vs release/scripts/*.pub at tag):" "${V_KEYMATCH[$key]:-UNAVAILABLE}"
    [[ -n "${V_SIGKEYS[$key]:-}" ]] && \
      printf '    %-46s %s\n' "signingKeys (block order):" "${V_SIGKEYS[$key]}"
    [[ -n "${V_SIGDIGESTS[$key]:-}" ]] && \
      printf '    %-46s %s\n' "key digests (eFuse DIGEST0,1,2):" "${V_SIGDIGESTS[$key]}"
  fi
  return 0  # a false trailing `[[ ]] &&` would return 1 and trip the ERR trap
}

main() {
  # FIRST action, before parse_args: the asciinema recording is the only artifact
  # attached to a published verification, so it must establish on its own which
  # script bytes produced the result - and an invalid-argument run exits at parse
  # time, so a later banner would not record which script failed.
  # See ws-notes/script-notes/script-version-and-hash.md.
  SCRIPT_SHA256="$(sha256_of "${SCRIPT_PATH}")"
  log_info "Script:  $(basename "${SCRIPT_PATH}") ${SCRIPT_VERSION}"
  log_info "         sha256: ${SCRIPT_SHA256}"

  parse_args "$@"
  validate_inputs
  detect_container_cmd

  WORK_DIR="$(pwd)/blockstreamjadeplus-work_${VERSION}_${TYPE:-all}_$$"
  mkdir -p "${WORK_DIR}"

  print_disclaimer
  cat <<BANNER
Verifying Blockstream Jade Plus firmware v${VERSION} (${TYPE:-both published Plus artifacts})
Hardware profile: ${PROFILE} (ESP32-S3) | firmware endpoint: ${ENDPOINT}
Work dir: ${WORK_DIR}

BANNER

  build_tools_image
  write_sigcheck_tool
  clone_checkout
  resolve_layout

  if [[ -f "${BINARY_PATH:-}" && -z "${TYPE}" ]] && ! resolve_binary_file_variant; then
    write_results "ftbfs" "Provided binary could not be bound uniquely to a Jade Plus v${VERSION} index entry."
    exit "${EXIT_FAIL}"
  fi
  local variants=() ; mapfile -t variants < <(requested_variants)

  # Scope statement, NOT a request to change how the run is invoked. Plus publishes
  # exactly two artifacts per release, and one COMPARISON_RESULTS.yaml verdict can
  # honestly describe both so long as it is 'reproducible' only when BOTH matched -
  # which the aggregation below enforces (per-artifact-verdict-model.md). What is
  # not honest is a single-artifact run read as covering the product, so that case
  # says out loud which artifact it does not cover.
  if [[ ${#variants[@]} -gt 1 ]]; then
    log_info "Verifying both published Jade Plus artifacts (ble and noradio). The single verdict in COMPARISON_RESULTS.yaml covers both and is 'reproducible' only if both match; the per-artifact breakdown is in the results block."
  else
    local other="jadeplus-noradio"
    [[ "${variants[0]}" == "jadeplus-noradio" ]] && other="jadeplus-ble"
    log_warn "Single-artifact run: this verdict covers ${variants[0]} ONLY. It says nothing about ${other}, which Jade Plus also publishes for this release. Say so in the report."
  fi
  log_info "Jade Core (jade_v2c, bin/jade2.0c) is a different product and is outside this script entirely."

  for key in "${variants[@]}"; do
    [[ -f "${WORK_DIR}/index_${key}.json" ]] || preflight_variant "${key}" || true
  done
  local all_missing=true
  for key in "${variants[@]}"; do
    [[ "${V_RESULT[$key]}" != "ftbfs" ]] && all_missing=false
  done
  if [[ "${all_missing}" == true ]]; then
    write_results "ftbfs" "No official artifact is published for v${VERSION} at ${ENDPOINT} for the requested Jade Plus artifact(s): ${variants[*]}. No reproducibility verdict was computed; this is not a hash mismatch."
    exit "${EXIT_FAIL}"
  fi

  build_upstream_image

  for key in "${variants[@]}"; do
    if [[ "${V_RESULT[$key]}" == "ftbfs" ]]; then continue; fi
    if ! stage_official "${key}"; then
      log_fail "${key}: failed to download/verify the official artifact."
      V_RESULT[$key]="ftbfs"; V_NOTE[$key]="failed to stage or verify the official artifact"
      continue
    fi
    check_signature "${key}"
    if build_variant "${key}"; then
      compare_variant "${key}"
    fi
  done

  print_hash_legend

  echo
  cat <<RESULTS
===== Begin Results =====
appId:   ${APP_ID}
version: ${VERSION}
commit:  ${SRC_COMMIT}
scriptVersion:  ${SCRIPT_VERSION}
scriptHash:     ${SCRIPT_SHA256}
hwProfile:      ${PROFILE} (${CHIP})
endpoint:       ${ENDPOINT}
RESULTS
  # "The hash of the official firmware" is two values, not one, and Plus publishes
  # two artifacts per release on top of that. Every value is printed and labelled
  # so nobody has to guess which to submit (GitLab 957).
  local single_key=""
  for key in "${variants[@]}"; do
    if [[ -n "${V_CMPHASH[$key]:-}" ]]; then
      if [[ -z "${single_key}" ]]; then single_key="${key}"; else single_key="MULTI"; fi
    fi
  done
  if [[ -n "${single_key}" && "${single_key}" != "MULTI" ]]; then
    cat <<ARTIFACT
artifact:       ${V_FILE[$single_key]:-unavailable}
appHash:        ${V_CMPHASH[$single_key]}
                  hash of the artifact as downloaded (index.json cmphash)
fwhash:         ${V_FWHASH[$single_key]}
                  hash shown on the device screen during firmware update
ARTIFACT
    if [[ -n "${V_PAYLOAD[$single_key]:-}" ]]; then
      cat <<PAYLOAD
payloadHash:    ${V_PAYLOAD[$single_key]}
                  official firmware minus its 4096-byte signature sector
builtHash:      ${V_BUILT[$single_key]}
                  what this script built - must equal payloadHash above
PAYLOAD
    fi
    if [[ -n "${V_SIGSTATE[$single_key]:-}" ]]; then
      cat <<SIGS
signature:      ${V_SIGSTATE[$single_key]}
                  Secure Boot v2 over payloadHash, ${V_SIGBLOCKS[$single_key]:-0} block(s)
keyAnchor:      ${V_KEYMATCH[$single_key]:-UNAVAILABLE}
                  signing keys matched against release/scripts/*.pub at this tag
signingKeys:    ${V_SIGKEYS[$single_key]:-unavailable}
                  repository filenames, in signature-block order
keyDigests:     ${V_SIGDIGESTS[$single_key]:-unavailable}
                  eFuse SECURE_BOOT_DIGEST0,1,2 as an ESP32-S3 stores them
SIGS
    fi
  fi

  local reproducible=0 mismatched=0 unavailable=0 summary=""
  for key in "${variants[@]}"; do
    echo "${key} ($(variant_label "${key}")): ${V_RESULT[$key]:-ftbfs}"
    if [[ -n "${V_CMPHASH[$key]:-}" && "${single_key}" == "MULTI" ]]; then
      print_variant_detail "${key}"
    fi
    case "${V_RESULT[$key]:-ftbfs}" in
      reproducible) reproducible=$((reproducible+1)) ;;
      not_reproducible) mismatched=$((mismatched+1)) ;;
      *) unavailable=$((unavailable+1)) ;;
    esac
    summary="${summary}${key}: ${V_RESULT[$key]:-ftbfs}${V_NOTE[$key]:+ (${V_NOTE[$key]})}; "
  done
  echo "===== End Results ====="

  local verdict notes partial=""
  # Aggregate verdict. 'reproducible' requires EVERY requested artifact to have
  # been compared and matched - one that could not be built or downloaded must
  # never disappear into a clean pass (per-artifact-verdict-model.md). When some
  # matched but others could not be checked, the honest aggregate is 'ftbfs', with
  # the per-artifact detail kept in notes so passing results are not lost.
  if [[ ${mismatched} -gt 0 ]]; then
    verdict="not_reproducible"
  elif [[ ${reproducible} -gt 0 && ${unavailable} -eq 0 ]]; then
    verdict="reproducible"
  elif [[ ${reproducible} -gt 0 ]]; then
    verdict="ftbfs"
    partial="PARTIAL RESULT: ${reproducible} of $((reproducible + unavailable)) requested artifacts were compared and matched; ${unavailable} could not be compared at all. Nothing mismatched. The aggregate verdict is 'ftbfs' rather than 'reproducible' because an unverifiable artifact must not be reported as a clean pass - see the per-artifact breakdown below. "
  else
    verdict="ftbfs"
  fi

  local scope="both published Jade Plus artifacts (ble and noradio)"
  [[ -n "${TYPE}" ]] && scope="one Plus artifact only (${TYPE}); the other published Plus artifact was NOT verified"
  notes="${partial}Blockstream Jade Plus v${VERSION}, profile ${PROFILE} (${CHIP}), endpoint ${ENDPOINT}, commit ${SRC_COMMIT}. Scope: ${scope}. Jade Core (jade_v2c, bin/jade2.0c) is not covered. Per-artifact: ${summary}Built with ./tools/switch_to.sh ${PROFILE} [--noradio], which selects the production sdkconfig and sets the ESP32-S3 target itself. Mount path preserved at ${MOUNT_PATH} as REPRODUCIBLE.md requires; upstream documents that the path reaches the firmware via the ELF hash - documented, not measured by us for Plus. Comparison strips the trailing 4096-byte signature sector before hashing; on Plus that sector holds three Secure Boot v2 blocks plus 0xFF fill. Signature and key results are informational and never change the verdict; the key check is anchored against release/scripts/v2pk1.pub, v2pk2.pub and v2pk3.pub from the tagged source."

  write_results "${verdict}" "${notes}"
  if [[ "${verdict}" == "reproducible" ]]; then exit "${EXIT_OK}"; else exit "${EXIT_FAIL}"; fi
}

main "$@"
