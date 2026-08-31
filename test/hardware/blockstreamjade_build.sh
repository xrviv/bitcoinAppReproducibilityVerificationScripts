#!/bin/bash
# ==============================================================================
# blockstreamjade_build.sh - Blockstream Jade (classic) Reproducible Build Verifier
# ==============================================================================
# Version: v0.3.0
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Date last modified: 2026-08-05
# Project: https://github.com/Blockstream/Jade
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided. Review all operations
# before execution.
#
# SCOPE: classic Jade only (hw targets "jade" and "jade_v1_1", endpoints
# bin/jade and bin/jade1.1). Jade Plus / Jade Core ("jade_v2", "jade_v2c",
# endpoints bin/jade2.0 and bin/jade2.0c) are out of scope - see changelog.
#
# SCRIPT SUMMARY:
# - Clones Jade inside a container and checks out the requested release tag.
# - Detects which sdkconfig-generation mechanism the tag uses (static
#   production/*.defaults files pre-1.0.39, or tools/switch_to.sh 1.0.39+)
#   and fails loudly instead of guessing if neither is present.
# - Checks official firmware availability (index.json) before building.
# - Builds the upstream Dockerfile from the checked-out tag.
# - Builds each requested classic-Jade variant (jade/jade_v1_1 x ble/noradio)
#   with the exact container mount path Blockstream's own REPRODUCIBLE.md
#   requires, since that path is hashed into the firmware.
# - Downloads the official artifact, verifies its hash against the values
#   published in index.json, decompresses it (zlib, per tools/fwtools.py),
#   strips the trailing 4096-byte Blockstream signature block, and compares
#   the remaining payload against the local build.
# - Reports one result per variant (per-artifact verdict model).
#
# THE FOUR HASHES, AND WHICH ONE IS THE "OFFICIAL" ONE:
# Official Jade firmware is published compressed, and the uncompressed file
# carries a 4096-byte Blockstream signature block at the end. That gives three
# different hashes of "the official firmware", plus the hash of our build.
# Publishing the wrong one is what caused GitLab issue 957, so the script
# prints all four with an explicit legend (print_hash_legend) rather than
# leaving the reader to guess:
#   officialCompressedHash - the file exactly as downloaded ("cmphash" in
#                            index.json). The official download hash.
#   officialSignedFullHash - decompressed, signature still attached ("fwhash"
#                            in index.json). What the Jade shows on screen.
#   officialPayloadHash    - signature block removed. Published nowhere, shown
#                            by no device. Comparison basis only.
#   builtHash              - what this script built from the tagged source.
# A MATCH means builtHash == officialPayloadHash, i.e. the code Blockstream
# signed is the code in the public repo at that tag. It does NOT verify
# Blockstream's signature - that needs their private key, which we do not have.

set -eEuo pipefail

SCRIPT_VERSION="v0.3.0"
APP_ID="blockstreamjade"
REPO_URL="https://github.com/Blockstream/Jade"
MOUNT_PATH="/builds/blockstream/jade"
MIN_VERSION="1.0.36"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/COMPARISON_RESULTS.yaml"
TOOLS_BASE_IMAGE="debian:bookworm-slim@sha256:12c396bd585df7ec21d5679bb6a83d4878bc4415ce926c9e5ea6426d23c60bdc"

EXIT_OK=0
EXIT_FAIL=1
EXIT_INVALID=2

VERSION=""
ARCH="esp32"
TYPE=""
BINARY_PATH=""
WORK_DIR=""
CONTAINER_CMD=""
CONTAINER_RUN_USER_ARGS=()
CONTAINER_BUILD_FMT_ARGS=()
TOOLS_IMAGE=""
BUILD_IMAGE=""
SRC_COMMIT=""
SDK_METHOD=""

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo "[INFO] $*"; }
log_warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
log_fail() { echo -e "${RED}[FAIL] $*${NC}" >&2; }

declare -A V_RESULT V_NOTE V_CMPHASH V_FWHASH V_PAYLOAD V_BUILT V_SIGSTATE V_SIGKEY

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

handle_err() {
  local rc=$?
  trap - ERR
  log_fail "Unexpected error (exit ${rc})."
  write_results "ftbfs" "Blockstream Jade v${VERSION:-unknown} (${TYPE:-all classic variants}): script failed before a verdict could be computed. Work dir: ${WORK_DIR:-unset}"
  exit "${EXIT_FAIL}"
}
trap handle_err ERR

usage() {
  cat <<USAGE
blockstreamjade_build.sh ${SCRIPT_VERSION} - Blockstream Jade (classic) firmware verifier

Usage:
  $0 --version VERSION [--type TYPE] [--arch esp32] [--binary PATH]

Parameters:
  --version VERSION  Firmware tag without 'v' prefix, e.g. 1.0.40. Required.
                      Numeric X.Y.Z only (beta tags rejected). Must be
                      ${MIN_VERSION} or later - earlier tags use a different
                      repo layout this script does not support.
  --type TYPE         One classic-Jade variant, or omit/"all" to build and
                      compare all four in one run:
                        jade-ble       Jade 1.0, BLE-enabled  (bin/jade)
                        jade-noradio   Jade 1.0, no-radio     (bin/jade)
                        jade1.1-ble    Jade 1.1, BLE-enabled  (bin/jade1.1)
                        jade1.1-noradio Jade 1.1, no-radio    (bin/jade1.1)
  --arch ARCH         ABS compatibility parameter. Classic Jade only builds
                      for esp32; any other value is ignored with a warning.
  --binary PATH       Optional official firmware file (compressed *_fw.bin as
                      published). Only valid together with a single --type.
  --apk PATH          Not applicable to hardware; accepted as --binary alias.
  --help              Show this help.

Exit codes: 0 = reproducible, 1 = not reproducible / ftbfs, 2 = invalid parameters.
USAGE
}

require_value() {
  if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    log_fail "Missing value for $1"; exit "${EXIT_INVALID}"
  fi
}

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

normalize_type() {
  case "${1,,}" in
    ""|all) echo "" ;;
    jade-ble|jade1.0-ble|jade_ble) echo "jade-ble" ;;
    jade-noradio|jade1.0-noradio|jade_noradio) echo "jade-noradio" ;;
    jade1.1-ble|jade1_1-ble|jade11-ble) echo "jade1.1-ble" ;;
    jade1.1-noradio|jade1_1-noradio|jade11-noradio) echo "jade1.1-noradio" ;;
    *) echo "INVALID" ;;
  esac
}

validate_inputs() {
  if [[ -z "${VERSION}" ]]; then
    log_fail "--version is required (this script does not auto-detect firmware version from --binary)."
    exit "${EXIT_INVALID}"
  fi
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_fail "Invalid --version '${VERSION}'. Expected numeric X.Y.Z (e.g. 1.0.40). Beta tags (e.g. 1.0.39-beta2) are not supported."
    exit "${EXIT_INVALID}"
  fi
  local IFS=. va vb vc ma mb mc
  read -r va vb vc <<<"${VERSION}"; read -r ma mb mc <<<"${MIN_VERSION}"
  if (( va<ma || (va==ma && vb<mb) || (va==ma && vb==mb && vc<mc) )); then
    log_fail "--version ${VERSION} is below ${MIN_VERSION}. This script supports Jade firmware ${MIN_VERSION} and later only."
    exit "${EXIT_INVALID}"
  fi

  if [[ "${ARCH}" != "esp32" && -n "${ARCH}" ]]; then
    log_warn "Classic Jade only builds for esp32; ignoring --arch '${ARCH}'."
  fi
  ARCH="esp32"

  TYPE="$(normalize_type "${TYPE}")"
  if [[ "${TYPE}" == "INVALID" ]]; then
    log_fail "Unsupported --type. Use one of: jade-ble, jade-noradio, jade1.1-ble, jade1.1-noradio, or omit for all four."
    exit "${EXIT_INVALID}"
  fi

  if [[ -n "${BINARY_PATH}" ]]; then
    [[ "${BINARY_PATH}" != /* ]] && BINARY_PATH="${PWD}/${BINARY_PATH}"
    if [[ ! -f "${BINARY_PATH}" ]]; then
      log_fail "--binary file not found: ${BINARY_PATH}"; exit "${EXIT_INVALID}"
    fi
    if [[ -z "${TYPE}" ]]; then
      log_fail "--binary requires a single --type (Jade publishes 4 separate classic-Jade artifacts per version)."
      exit "${EXIT_INVALID}"
    fi
  fi
}

detect_container_cmd() {
  # CONTAINER_BUILD_FMT_ARGS: Blockstream's Dockerfile (tags 1.0.35-1.0.38) sets
  # SHELL ["/bin/bash", "-c"] and then relies on `source /venv/bin/activate`.
  # SHELL is a Docker-format-only instruction: podman builds OCI format by
  # default and silently ignores it, dropping that RUN to /bin/sh (dash), where
  # `source` does not exist -> exit 127. --format docker honours SHELL.
  # docker build has no --format flag, so this stays podman-only.
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"; CONTAINER_RUN_USER_ARGS=(--userns=keep-id -e HOME=/tmp)
    CONTAINER_BUILD_FMT_ARGS=(--format docker)
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"; CONTAINER_RUN_USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
    CONTAINER_BUILD_FMT_ARGS=()
  else
    log_fail "Neither podman nor docker found. Install one container runtime."
    write_results "ftbfs" "No container runtime found. Host requirement is podman or docker."
    exit "${EXIT_FAIL}"
  fi
  log_info "Container engine: ${CONTAINER_CMD}"
}

chown_back() {
  # Build-image steps run as root (see changelog: ESP-IDF's tool path is
  # baked in under /root at image-build time; remapping HOME breaks it).
  # This restores host ownership on the bind-mounted output afterwards.
  local uid gid; uid="$(id -u)"; gid="$(id -g)"
  printf 'chown -R %s:%s "%s" >/dev/null 2>&1 || true' "${uid}" "${gid}" "$1"
}

variant_profile()  { case "$1" in jade-ble|jade-noradio) echo jade ;; *) echo jade_v1_1 ;; esac; }
variant_radio()    { case "$1" in *-noradio) echo noradio ;; *) echo ble ;; esac; }
variant_endpoint() { case "$1" in jade-ble|jade-noradio) echo bin/jade ;; *) echo bin/jade1.1 ;; esac; }
variant_label() {
  case "$1" in
    jade-ble) echo "Jade 1.0 (BLE)" ;; jade-noradio) echo "Jade 1.0 (no-radio)" ;;
    jade1.1-ble) echo "Jade 1.1 (BLE)" ;; jade1.1-noradio) echo "Jade 1.1 (no-radio)" ;;
  esac
}

requested_variants() {
  if [[ -n "${TYPE}" ]]; then echo "${TYPE}";
  else printf '%s\n' jade-ble jade-noradio jade1.1-ble jade1.1-noradio; fi
}

# Signature-block check. INFORMATIONAL ONLY - it never changes the verdict.
# The trailing 4096 bytes stripped before comparison are an ESP-IDF Secure Boot
# v2 block, whose format embeds the signer's RSA-3072 PUBLIC key next to the
# signature. So without any secret we can check that the signature is valid over
# exactly the payload we compare against, and report which key signed it.
# What this does NOT do: prove the key is Blockstream's. Verifying a file with a
# key taken from that same file shows internal consistency, not authorship. Its
# value is that it binds Blockstream's published signature to the reproduced
# bytes. The key digest is the value an ESP32 burns into eFuse as
# SECURE_BOOT_DIGEST0, so a device owner can compare it with `espefuse.py summary`.
# EXPECTED_SIGNING_KEY is pinned from observation, not from anything Blockstream
# publishes: the same key signed all 24 classic-Jade artifacts across 1.0.35-1.0.40
# (both endpoints x both radio configs). A different value is not proof of
# wrongdoing - it may be a legitimate key rotation - but it must be investigated
# before any verdict is published, so it is warned about loudly.
EXPECTED_SIGNING_KEY="96bf3b2e840dc9d74ff8fffe2ca43f95d1362a1b1860506420531fae7242f4f7"

write_sigcheck_tool() {
  cat > "${WORK_DIR}/ws_sigcheck.py" <<'PYEOF'
import binascii, hashlib, struct, sys
SECTOR, BLOCK, MAGIC, VER = 4096, 1216, 0xE7, 0x02
FMT = "<BBxx32s384sI384sI384sI16x"
def out(state, key="", detail=""):
    print("SIGSTATE=%s" % state); print("SIGKEY=%s" % key)
    if detail: print("SIGDETAIL=%s" % detail)
    sys.exit(0)
try:
    signed = open(sys.argv[1], "rb").read()
    if len(signed) <= SECTOR:
        out("UNAVAILABLE", "", "file smaller than one signature sector")
    payload, block = signed[:-SECTOR], signed[-SECTOR:][:BLOCK]
    magic, ver, digest, mod, exp, rinv, mprime, sig, _crc = struct.unpack(FMT, block)
    if magic != MAGIC or ver != VER:
        out("UNAVAILABLE", "", "no Secure Boot v2 block (magic 0x%02X, version 0x%02X)" % (magic, ver))
    keydig = hashlib.sha256(struct.pack("<384sI384sI", mod, exp, rinv, mprime)).hexdigest()
    padded = payload + b"\xff" * ((-len(payload)) % SECTOR)
    calc = hashlib.sha256(padded).digest()
    if calc != digest:
        out("DIGEST-MISMATCH", keydig, "signature covers different bytes than the payload compared")
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils
    pub = rsa.RSAPublicNumbers(e=exp, n=int.from_bytes(mod, "little")).public_key()
    pub.verify(sig[::-1], calc,
               padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32),
               utils.Prehashed(hashes.SHA256()))
    out("VALID", keydig)
except ImportError as exc:
    out("UNAVAILABLE", "", "python3-cryptography not present: %s" % exc)
except Exception as exc:
    out("INVALID", "", str(exc))
PYEOF
}

check_signature() {
  local key="$1" res=""
  [[ -f "${WORK_DIR}/official_${key}.full.bin" ]] || return 0
  res="$("${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" \
        "${TOOLS_IMAGE}" python3 /work/ws_sigcheck.py "/work/official_${key}.full.bin" 2>&1 || true)"
  V_SIGSTATE[$key]="$(sed -n 's/^SIGSTATE=//p' <<<"${res}" | head -1)"
  V_SIGKEY[$key]="$(sed -n 's/^SIGKEY=//p' <<<"${res}" | head -1)"
  local detail; detail="$(sed -n 's/^SIGDETAIL=//p' <<<"${res}" | head -1)"
  [[ -z "${V_SIGSTATE[$key]}" ]] && V_SIGSTATE[$key]="UNAVAILABLE"
  case "${V_SIGSTATE[$key]}" in
    VALID)
      if [[ -n "${V_SIGKEY[$key]}" && "${V_SIGKEY[$key]}" != "${EXPECTED_SIGNING_KEY}" ]]; then
        log_warn "${key}: signature is valid but signed by an UNEXPECTED key (${V_SIGKEY[$key]}); expected ${EXPECTED_SIGNING_KEY}. Investigate before publishing - this may be a legitimate key rotation."
      fi ;;
    UNAVAILABLE) log_warn "${key}: signature check unavailable${detail:+ (${detail})}. Verdict is unaffected." ;;
    *)           log_warn "${key}: SIGNATURE CHECK FAILED (${V_SIGSTATE[$key]})${detail:+ - ${detail}}. Verdict is unaffected, but this needs investigation before publishing." ;;
  esac
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
  TOOLS_IMAGE="walletscrutiny-jade-tools:${VERSION}-$$"
  "${CONTAINER_CMD}" build "${CONTAINER_BUILD_FMT_ARGS[@]}" -q -t "${TOOLS_IMAGE}" -f "${dockerfile}" "${WORK_DIR}" >/dev/null
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

resolve_sdk_method() {
  if "${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
      bash -c "test -f /work/src/tools/switch_to.sh"; then
    SDK_METHOD="switch_to"
  elif "${CONTAINER_CMD}" run --rm -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
      bash -c "test -f /work/src/production/sdkconfig_jade_prod.defaults"; then
    SDK_METHOD="cp"
  else
    log_fail "Tag ${VERSION}: neither tools/switch_to.sh nor production/sdkconfig_jade_prod.defaults found."
    write_results "ftbfs" "Unsupported repo layout at tag ${VERSION}: this script's two known sdkconfig-generation mechanisms (static production/*.defaults, or tools/switch_to.sh) were both absent. Script needs updating for this tag."
    exit "${EXIT_FAIL}"
  fi
  log_info "sdkconfig-generation mechanism for ${VERSION}: ${SDK_METHOD}"
}

# Tags 1.0.35-1.0.38 pin cbor2==5.4.6 with only its sdist hash. That sdist's
# setup.py does `from pkg_resources import parse_version`, and pkg_resources was
# removed in setuptools 82.0.0. PEP 517 build isolation builds the overlay from
# cbor2's own unbounded `setuptools>=61`, so the backend now resolves past 82
# and the wheel build dies - Blockstream's pinned image no longer builds as-is.
# Fix: cap the BUILD BACKEND at setuptools<82 via PIP_CONSTRAINT, leaving
# upstream's pip command otherwise verbatim. Build isolation and --require-hashes
# both stay intact and no package is added to /venv. (--no-build-isolation was
# tried first and is wrong: cbor2 builds its version with setuptools_scm, which
# isolation supplies, so without it the sdist reports version 0.0.0 and pip
# rejects it. Verified in a matching container.) Needs a pip where PIP_CONSTRAINT
# still reaches build environments; the venv seeds pip 23.0.1, which does. If a
# future tag seeds pip >= 25.3, this stops working and the original
# pkg_resources error returns - recognisable, not silent.
# The constraint is intended to limit setuptools in isolated source builds;
# upstream's requirement versions and download hashes remain unchanged. Those
# hashes verify downloaded archives, not the wheels built from them. cbor2 lands
# in /venv, while the firmware build sources ESP-IDF's separate environment and
# does not use /venv, so no path from this wheel to jade.bin is used here.
# Disclose this deviation in the report. Fail-closed: anything other than exactly
# the expected layout aborts.
# Second thing this fixes (1.0.39+): `FROM blockstream/jade_builder_base@sha256:...`
# is an unqualified NAMESPACED image name. Docker assumes Docker Hub; podman
# refuses unless an unqualified-search registry is configured, which we cannot
# do without root on the build host. Official single-name images (debian) are
# unaffected - podman resolves those through its built-in short-name alias
# table - so only namespaced refs are rewritten, keeping the 1.0.35-1.0.38
# Dockerfile byte-identical to the already-validated run. The ref is pinned by
# digest, so adding the registry prefix cannot change which image is pulled.
patch_dockerfile() {
  local pyfile="${WORK_DIR}/ws_patch_dockerfile.py" rc=0
  cat > "${pyfile}" <<'PYEOF'
import os, re, sys
src = "/work/src"
dockerfile, reqs = os.path.join(src, "Dockerfile"), os.path.join(src, "requirements.txt")
if not os.path.exists(dockerfile):
    print("WS-PATCH: no Dockerfile at this tag."); sys.exit(3)
df = open(dockerfile).read()
before = df

# (1) Qualify namespaced short-name FROM refs so podman can resolve them.
def qualify(m):
    ref = m.group(2)
    head = ref.split("/")[0]
    if "/" in ref and "." not in head and ":" not in head and head != "localhost":
        return m.group(1) + "docker.io/" + ref
    return m.group(0)
df = re.sub(r"(?m)^(FROM\s+)(\S+)", qualify, df)
if df != before:
    print("WS-PATCH: qualified namespaced FROM image with docker.io/ (digest pin unchanged)")

# (2) Cap the build backend when a hash-pinned sdist needs pre-82 setuptools.
if not os.path.exists(reqs):
    print("WS-PATCH: no requirements.txt at this tag; skipping build-backend cap.")
else:
    cb = [l.strip() for l in open(reqs).read().splitlines() if l.strip().startswith("cbor2==")]
    if len(cb) != 1:
        print("WS-PATCH: expected exactly 1 cbor2 pin, found %d; refusing to guess." % len(cb)); sys.exit(3)
    elif cb[0].endswith("\\"):
        print("WS-PATCH: cbor2 pin carries multiple hashes (wheel available); no cap needed.")
    else:
        m = re.match(r"^(cbor2==\S+)\s+(--hash=sha256:[0-9a-f]{64})$", cb[0])
        if not m:
            print("WS-PATCH: unrecognised cbor2 pin format: %r" % cb[0]); sys.exit(3)
        req, sha = m.group(1), m.group(2)
        orig = "pip install --require-hashes -r /requirements.txt"
        if df.count(orig) != 1:
            print("WS-PATCH: expected exactly 1 requirements install, found %d." % df.count(orig)); sys.exit(3)
        repl = ("echo 'WS-PATCH: capping build-backend setuptools<82 for hash-pinned sdists' && "
                "printf 'setuptools<82\\n' > /ws-build-constraint.txt && "
                "PIP_CONSTRAINT=/ws-build-constraint.txt %s" % orig)
        df = df.replace(orig, repl)
        print("WS-PATCH: applied for %s %s (build-backend cap, isolation and hash pinning preserved)" % (req, sha))

if df != before:
    open(dockerfile, "w").write(df)
else:
    print("WS-PATCH: no changes needed for this tag.")
PYEOF
  "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    python3 /work/ws_patch_dockerfile.py || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_fail "Dockerfile patch refused (exit ${rc}): this tag's layout is not what the patch expects."
    write_results "ftbfs" "Blockstream Jade v${VERSION}: the Dockerfile patch refused to apply because the tag's requirements.txt/Dockerfile layout differs from the expected one. The script was not willing to guess and build a differently-patched image. Script needs updating for this tag."
    exit "${EXIT_FAIL}"
  fi
}

build_upstream_image() {
  patch_dockerfile
  BUILD_IMAGE="walletscrutiny-jade-builder:${VERSION}-$$"
  log_info "Building upstream Dockerfile from tag ${VERSION} (this installs the ESP-IDF toolchain; can take a while)."
  "${CONTAINER_CMD}" build "${CONTAINER_BUILD_FMT_ARGS[@]}" -q -f "${WORK_DIR}/src/Dockerfile" -t "${BUILD_IMAGE}" "${WORK_DIR}/src" >/dev/null
}

preflight_variant() {
  local key="$1" endpoint config entry
  endpoint="$(variant_endpoint "${key}")"; config="$(variant_radio "${key}")"
  if [[ -n "${BINARY_PATH}" ]]; then
    V_RESULT[$key]="pending"; return 0
  fi
  log_info "Checking official index: ${endpoint}/index.json (${key})"
  entry="$("${CONTAINER_CMD}" run --rm "${TOOLS_IMAGE}" bash -c "
      curl -sSL --fail --max-time 30 'https://jadefw.blockstream.com/${endpoint}/index.json' \
        | jq -c --arg v '${VERSION}' --arg c '${config}' \
          '(.stable.full + .previous.full)[] | select(.version==\$v and .config==\$c)'
    " 2>/dev/null || true)"
  if [[ -z "${entry}" ]]; then
    log_warn "${key}: no official artifact published for v${VERSION} at ${endpoint} (config=${config})."
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

sha256_local() { sha256sum "$1" | awk '{print $1}'; }

stage_official() {
  local key="$1" endpoint filename dl
  endpoint="$(variant_endpoint "${key}")"
  dl="${WORK_DIR}/official_${key}.bin.gz"
  if [[ -n "${BINARY_PATH}" ]]; then
    cp "${BINARY_PATH}" "${dl}"
    log_info "${key}: using provided --binary as official artifact."
  else
    filename="$(official_json_field "${key}" filename)"
    log_info "${key}: downloading official artifact ${filename}"
    "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
      bash -c "curl -sSL --fail --max-time 60 -o '/work/official_${key}.bin.gz' 'https://jadefw.blockstream.com/${endpoint}/${filename}'"
  fi

  local cmp_hash_actual full_hash_actual
  cmp_hash_actual="$(sha256_local "${dl}")"
  echo "${cmp_hash_actual}" > "${WORK_DIR}/official_${key}.cmphash.actual"
  V_CMPHASH[$key]="${cmp_hash_actual}"

  if [[ -z "${BINARY_PATH}" ]]; then
    local cmphash_expected
    cmphash_expected="$(official_json_field "${key}" cmphash)"
    if [[ "${cmp_hash_actual}" != "${cmphash_expected}" ]]; then
      log_warn "${key}: downloaded compressed artifact does not match index.json cmphash (expected ${cmphash_expected}, got ${cmp_hash_actual})."
    fi
  fi

  "${CONTAINER_CMD}" run --rm "${CONTAINER_RUN_USER_ARGS[@]}" -v "${WORK_DIR}:/work" "${TOOLS_IMAGE}" \
    bash -c "python3 -c \"import zlib,sys; d=open('/work/official_${key}.bin.gz','rb').read(); open('/work/official_${key}.full.bin','wb').write(zlib.decompress(d))\""

  full_hash_actual="$(sha256_local "${WORK_DIR}/official_${key}.full.bin")"
  V_FWHASH[$key]="${full_hash_actual}"
  if [[ -z "${BINARY_PATH}" ]]; then
    local fwhash_expected
    fwhash_expected="$(official_json_field "${key}" fwhash)"
    if [[ "${full_hash_actual}" != "${fwhash_expected}" ]]; then
      log_warn "${key}: decompressed artifact does not match index.json fwhash (expected ${fwhash_expected}, got ${full_hash_actual})."
    fi
  fi

  head -c -4096 "${WORK_DIR}/official_${key}.full.bin" > "${WORK_DIR}/official_${key}.payload.bin"
}

generate_sdkconfig_cmd() {
  local profile="$1" radio="$2"
  if [[ "${SDK_METHOD}" == "switch_to" ]]; then
    if [[ "${radio}" == "noradio" ]]; then
      echo "./tools/switch_to.sh ${profile} --noradio"
    else
      echo "./tools/switch_to.sh ${profile}"
    fi
  else
    if [[ "${radio}" == "noradio" ]]; then
      echo "cp production/sdkconfig_${profile}_noradio_prod.defaults sdkconfig.defaults && rm -f sdkconfig"
    else
      echo "cp production/sdkconfig_${profile}_prod.defaults sdkconfig.defaults && rm -f sdkconfig"
    fi
  fi
}

build_variant() {
  local key="$1" profile radio gen_cmd chown_cmd
  profile="$(variant_profile "${key}")"; radio="$(variant_radio "${key}")"
  gen_cmd="$(generate_sdkconfig_cmd "${profile}" "${radio}")"
  chown_cmd="$(chown_back "${WORK_DIR}/src")"
  log_info "Building ${key} ($(variant_label "${key}")): ${gen_cmd}"
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
    " || true
  # build/ lives inside the bind-mounted source tree, so it is already
  # visible on the host at this path once the container exits.
  if [[ -f "${WORK_DIR}/src/build/jade.bin" ]]; then
    cp "${WORK_DIR}/src/build/jade.bin" "${WORK_DIR}/built_${key}.bin"
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
  echo "----- ${key} ($(variant_label "${key}")) -----"
  echo "officialCompressedHash (as downloaded): $(sha256_local "${WORK_DIR}/official_${key}.bin.gz")"
  echo "officialSignedFullHash (decompressed):  $(sha256_local "${WORK_DIR}/official_${key}.full.bin")"
  echo "officialPayloadHash (signature stripped, comparison basis): ${official_hash}"
  echo "builtHash:                              ${built_hash}"
  if [[ "${built_hash}" == "${official_hash}" ]]; then
    echo "RESULT: MATCH"
    V_RESULT[$key]="reproducible"
  else
    echo "RESULT: MISMATCH"
    local difffile="${WORK_DIR}/diff_${key}.txt"
    cmp -l "${WORK_DIR}/built_${key}.bin" "${WORK_DIR}/official_${key}.payload.bin" > "${difffile}" 2>&1 || true
    echo "First 5 lines of byte-level diff (full diff: ${difffile}):"
    head -5 "${difffile}"
    V_RESULT[$key]="not_reproducible"
  fi
}

# Printed OUTSIDE the Begin/End Results markers on purpose: that block is
# parsed field-by-field by the build server, so free text must not sit inside it.
print_hash_legend() {
  echo
  echo "----- What these hashes mean -----"
  echo "officialCompressedHash  SHA-256 of the file exactly as downloaded from"
  echo "                        jadefw.blockstream.com. Blockstream lists this in"
  echo "                        index.json as 'cmphash'. THIS is the official"
  echo "                        download hash to publish. Reported below as"
  echo "                        'appHash'."
  echo "officialSignedFullHash  SHA-256 after decompression, signature still"
  echo "                        attached. This is the value a Jade displays on"
  echo "                        screen during a firmware update. Blockstream lists"
  echo "                        it in index.json as 'fwhash'. Reported below"
  echo "                        under that same name. It is NOT the same value as"
  echo "                        appHash - a user comparing the device screen must"
  echo "                        use fwhash, not appHash."
  echo "officialPayloadHash     The same firmware with its last 4096 bytes removed"
  echo "                        - Blockstream's release signature block. Published"
  echo "                        nowhere, shown by no device. It exists only so it"
  echo "                        can be compared against a locally built binary,"
  echo "                        which is unsigned."
  echo "builtHash               SHA-256 of the firmware this script built from the"
  echo "                        source at tag ${VERSION}."
  echo
  echo "MATCH means builtHash == officialPayloadHash: the code Blockstream signed is"
  echo "the code in the public repo at this tag. It does NOT verify Blockstream's"
  echo "signature - that is made with a private key we do not have."
  echo
  echo "Do not publish officialPayloadHash or builtHash as the 'official' hash."
  echo
  echo "signature / signingKey are INFORMATIONAL and never change the verdict."
  echo "VALID means Blockstream's Secure Boot v2 signature is a mathematically"
  echo "valid RSA-PSS signature over exactly the payload compared above - so the"
  echo "signature covers the bytes we rebuilt from public source. It does NOT"
  echo "prove the key is Blockstream's: the key is read out of the same file, so"
  echo "this shows internal consistency, not authorship. signingKey is the value"
  echo "an ESP32 burns into eFuse SECURE_BOOT_DIGEST0, so a device owner can"
  echo "compare it against their own hardware with 'espefuse.py summary'."
  echo "----------------------------------"
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

main() {
  parse_args "$@"
  validate_inputs
  detect_container_cmd

  WORK_DIR="$(pwd)/blockstreamjade-work_${VERSION}_${TYPE:-all}_$$"
  mkdir -p "${WORK_DIR}"

  print_disclaimer
  # Printed to the terminal, not just written to the YAML: the asciinema
  # recording is the only artifact attached to a published verification, so it
  # must be able to establish on its own which script version produced the result.
  echo "blockstreamjade_build.sh ${SCRIPT_VERSION}"
  echo "Verifying Blockstream Jade firmware v${VERSION} (${TYPE:-all classic variants})"
  echo "Work dir: ${WORK_DIR}"
  echo

  build_tools_image
  write_sigcheck_tool
  clone_checkout
  resolve_sdk_method

  local variants=() ; mapfile -t variants < <(requested_variants)

  # One YAML verdict cannot honestly describe four separate artifacts. Publishing
  # and ABS runs should pass --type so each artifact gets its own verdict event
  # (per-artifact-verdict-model.md); the all-variants mode is a human convenience
  # for surveying a release in one pass.
  if [[ ${#variants[@]} -gt 1 ]]; then
    log_warn "Building ${#variants[@]} variants in one run. COMPARISON_RESULTS.yaml can carry only ONE verdict for all of them."
    log_warn "For a published verification or an ABS run, pass --type <variant> so each artifact gets its own verdict."
  fi

  for key in "${variants[@]}"; do
    preflight_variant "${key}" || true
  done
  local all_missing=true
  for key in "${variants[@]}"; do
    [[ "${V_RESULT[$key]}" != "ftbfs" ]] && all_missing=false
  done
  if [[ "${all_missing}" == true ]]; then
    write_results "ftbfs" "No official artifact is published for v${VERSION} for the requested classic-Jade variant(s): ${variants[*]}. No reproducibility verdict was computed; this is not a hash mismatch."
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
  echo "===== Begin Results ====="
  echo "appId:   ${APP_ID}"
  echo "script_version: ${SCRIPT_VERSION}"
  echo "version: ${VERSION}"
  echo "commit:  ${SRC_COMMIT}"
  echo "sdkconfig method: ${SDK_METHOD}"
  # Jade publishes a compressed artifact whose decompressed form carries the
  # signature block, so "the hash of the official firmware" is two values, not
  # one. Both are printed, each labelled, so nobody has to guess which to
  # submit (GitLab 957). Values stay on their own clean lines; the descriptions
  # sit on separate continuation lines so a "key: value" reader is unaffected.
  local single_key=""
  for key in "${variants[@]}"; do
    if [[ -n "${V_CMPHASH[$key]:-}" ]]; then
      if [[ -z "${single_key}" ]]; then single_key="${key}"; else single_key="MULTI"; fi
    fi
  done
  if [[ -n "${single_key}" && "${single_key}" != "MULTI" ]]; then
    echo "appHash:        ${V_CMPHASH[$single_key]}"
    echo "                  hash of the artifact as downloaded (index.json cmphash)"
    echo "fwhash:         ${V_FWHASH[$single_key]}"
    echo "                  hash shown on the device screen during firmware update"
    if [[ -n "${V_PAYLOAD[$single_key]:-}" ]]; then
      echo "payloadHash:    ${V_PAYLOAD[$single_key]}"
      echo "                  official firmware minus its 4096-byte signature block"
      echo "builtHash:      ${V_BUILT[$single_key]}"
      echo "                  what this script built - must equal payloadHash above"
    fi
    if [[ -n "${V_SIGSTATE[$single_key]:-}" ]]; then
      echo "signature:      ${V_SIGSTATE[$single_key]}"
      echo "                  Blockstream's Secure Boot v2 signature over payloadHash"
      if [[ -n "${V_SIGKEY[$single_key]:-}" ]]; then
        echo "signingKey:     ${V_SIGKEY[$single_key]}"
        echo "                  SHA-256 of the signing public key = eFuse SECURE_BOOT_DIGEST0"
      fi
    fi
  fi

  local reproducible=0 mismatched=0 unavailable=0 summary=""
  for key in "${variants[@]}"; do
    echo "${key} ($(variant_label "${key}")): ${V_RESULT[$key]:-ftbfs}"
    if [[ -n "${V_CMPHASH[$key]:-}" && "${single_key}" == "MULTI" ]]; then
      printf '    %-44s %s\n' "appHash (as downloaded):" "${V_CMPHASH[$key]}"
      printf '    %-44s %s\n' "fwhash (shown on device):" "${V_FWHASH[$key]:-unavailable}"
      if [[ -n "${V_PAYLOAD[$key]:-}" ]]; then
        printf '    %-44s %s\n' "payloadHash (official, signature removed):" "${V_PAYLOAD[$key]}"
        printf '    %-44s %s\n' "builtHash (ours, must equal payloadHash):" "${V_BUILT[$key]}"
      fi
      if [[ -n "${V_SIGSTATE[$key]:-}" ]]; then
        printf '    %-44s %s\n' "signature over payload (Secure Boot v2):" "${V_SIGSTATE[$key]}"
        [[ -n "${V_SIGKEY[$key]:-}" ]] && \
          printf '    %-44s %s\n' "signing key digest (eFuse DIGEST0):" "${V_SIGKEY[$key]}"
      fi
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
  # Aggregate verdict. `reproducible` requires that EVERY requested variant was
  # actually compared and matched - one variant that could not be built or
  # downloaded must never disappear into a clean pass for the whole set.
  # per-artifact-verdict-model.md: "do not collapse a product version into one
  # final reproducibility verdict when that version ships multiple artifacts",
  # and Leo: "at the artifact level we cannot take short-cuts". When some
  # variants matched but others could not be checked, the honest aggregate is
  # `ftbfs` (something was not verifiable), with the per-variant detail kept in
  # notes so the passing results are not lost.
  if [[ ${mismatched} -gt 0 ]]; then
    verdict="not_reproducible"
  elif [[ ${reproducible} -gt 0 && ${unavailable} -eq 0 ]]; then
    verdict="reproducible"
  elif [[ ${reproducible} -gt 0 ]]; then
    verdict="ftbfs"
    partial="PARTIAL RESULT: ${reproducible} of $((reproducible + unavailable)) requested variants were compared and matched; ${unavailable} could not be compared at all. No variant mismatched. The aggregate verdict is 'ftbfs' rather than 'reproducible' because an unverifiable artifact must not be reported as a clean pass - see the per-variant breakdown below for which ones passed. "
  else
    verdict="ftbfs"
  fi

  notes="${partial}Blockstream Jade v${VERSION}, sdkconfig method '${SDK_METHOD}', commit ${SRC_COMMIT}. Per-variant: ${summary}Container mount path preserved at ${MOUNT_PATH} per REPRODUCIBLE.md (encoded into jade.map/jade.elf and hashed into the built image). Comparison strips the trailing 4096-byte Blockstream release-signature block (espsecure.py sign_data --version 2) from the official artifact before hashing; this verifies the firmware payload, not Blockstream's signature over it."

  write_results "${verdict}" "${notes}"
  if [[ "${verdict}" == "reproducible" ]]; then exit "${EXIT_OK}"; else exit "${EXIT_FAIL}"; fi
}

main "$@"
