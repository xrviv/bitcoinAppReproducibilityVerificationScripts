#!/bin/bash
# ==============================================================================
# electrumandroid-v2.4.0_build.sh - Electrum Android Reproducible Build Verification
# ==============================================================================
# Version:          v2.4.0
# Organization:     WalletScrutiny.com
# Last modified by: Bob (WalletScrutiny agent)
# Last modified on: 2026-10-09
# Project:          https://github.com/spesmilo/electrum
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/android/org.electrum.electrum/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.

# Self-identification first: name, version and own sha256, before anything else runs.
SCRIPT_VERSION="v2.4.0"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
: "${SCRIPT_SHA256:=N/A}"
echo "Starting ${SCRIPT_NAME} script version ${SCRIPT_VERSION}"
echo "Script sha256: ${SCRIPT_SHA256}"

set -eo pipefail

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"
sleep 3
echo

# Global Variables
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
RESULTS_FILE="$SCRIPT_DIR/COMPARISON_RESULTS.yaml"
wsContainer="docker.io/walletscrutiny/android:5"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
RESULTS_WRITTEN=0
FINAL_VERDICT=""
CONTAINER_CMD=""
ROOTLESS=0
CTR_PID=""
# Per-run resources: empty until created, so the EXIT trap only touches what this run made.
RUN_ID=""
workDir=""
LOG_DIR=""
DIFF_FILE=""
BUILD_RUN_LABEL=""
BUILD_IMAGE_TAG=""

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

# A verdict left by an earlier run must never be mistaken for this run's.
rm -f "$RESULTS_FILE"

write_ftbfs() {
  cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  $1
EOF
  RESULTS_WRITTEN=1
  FINAL_VERDICT="ftbfs"
}

# Runs a long container command in the background and waits for it, so INT/TERM
# reach the traps at once instead of after the container finishes.
ctr_wait() {
  local rc=0
  "$@" &
  CTR_PID=$!
  wait "$CTR_PID" || rc=$?
  CTR_PID=""
  return "$rc"
}

# Removes only what this run created: its labeled containers and images, its image tag.
cleanup() {
  [ -n "$CONTAINER_CMD" ] || return 0
  local ids
  if [ -n "$BUILD_RUN_LABEL" ]; then
    ids=$($CONTAINER_CMD ps -aq --filter "label=${BUILD_RUN_LABEL}" 2>/dev/null || true)
    if [ -n "$ids" ]; then
      echo "$ids" | xargs -r $CONTAINER_CMD kill >/dev/null 2>&1 || true
      echo "$ids" | xargs -r $CONTAINER_CMD rm -f >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$CTR_PID" ] && kill -0 "$CTR_PID" 2>/dev/null; then
    kill "$CTR_PID" 2>/dev/null || true
    wait "$CTR_PID" 2>/dev/null || true
  fi
  if [ -n "$BUILD_RUN_LABEL" ]; then
    ids=$($CONTAINER_CMD images -q --filter "label=${BUILD_RUN_LABEL}" 2>/dev/null || true)
    [ -n "$ids" ] && { echo "$ids" | xargs -r $CONTAINER_CMD rmi -f >/dev/null 2>&1 || true; }
  fi
  [ -n "$BUILD_IMAGE_TAG" ] && { $CONTAINER_CMD rmi -f "$BUILD_IMAGE_TAG" >/dev/null 2>&1 || true; }
  return 0
}

# Hands the workspace back to the caller; never fails the script or changes the verdict.
# Rootless runtime: container root == caller, so chown 0:0 (a host uid would map into the subuid range).
hand_back_workspace() {
  [ -n "$workDir" ] && [ -d "$workDir" ] || return 0
  local own="${HOST_UID}:${HOST_GID}" stray
  [ "$ROOTLESS" -eq 1 ] && own="0:0"
  if [ "$CONTAINER_CMD" = podman ] && [ "$ROOTLESS" -eq 1 ]; then
    podman unshare chown -R 0:0 "$workDir" >/dev/null 2>&1 || true
  elif [ -n "$CONTAINER_CMD" ]; then
    $CONTAINER_CMD run --rm --user root --volume "$workDir:/w" $wsContainer \
      chown -R "$own" /w >/dev/null 2>&1 || true
  fi
  stray=$(find "$workDir" ! -uid "$HOST_UID" -print -quit 2>/dev/null || true)
  if [ -n "$stray" ]; then
    echo -e "${YELLOW}Warning: not caller-owned after hand-back: $stray${NC}"
  else
    echo "Workspace ownership: all files owned by uid ${HOST_UID} ($workDir)"
  fi
  return 0
}

# Runs on every exit (success, failure, interrupt): stops this run's containers,
# removes its image, hands the workspace back and guarantees a verdict.
on_exit() {
  local rc=$?
  trap - INT TERM
  set +e
  cleanup
  hand_back_workspace
  if [ "$RESULTS_WRITTEN" -eq 0 ]; then
    write_ftbfs "Run ended before a verdict was written (exit code $rc: build failure, invalid input or interruption). See terminal logs for the failing step."
    echo -e "${YELLOW}Fallback results written to: $RESULTS_FILE${NC}"
  fi
  echo
  if [ -n "$DIFF_FILE" ] && [ -f "$DIFF_FILE" ]; then
    echo "Full diff data can be found here: $DIFF_FILE"
    echo "Quick view command:"
    echo "  sed -n '1,120p' \"$DIFF_FILE\""
  else
    echo "Full diff data can be found here: (not generated in this run)"
  fi
  echo "Results YAML can be found here: $RESULTS_FILE"
  [ -n "$LOG_DIR" ] && echo "Build logs: $LOG_DIR/"
  case "$rc" in 0|1|2) ;; *) rc=1 ;; esac
  echo "Exit code: $rc"
  exit "$rc"
}

trap on_exit EXIT
trap 'echo; echo "Interrupted (SIGINT)."; exit 130' INT
trap 'echo; echo "Terminated (SIGTERM)."; exit 143' TERM

# Detect a container runtime that actually works (docker needs its daemon).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && ROOTLESS=1 || true
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ] && ROOTLESS=1 || true
else
  echo -e "${RED}Error: no working container runtime (docker info and podman info both failed).${NC}"
  write_ftbfs "No working container runtime: docker info and podman info both failed. Install or start docker or podman."
  exit 1
fi
echo "Using ${CONTAINER_CMD} for containerization (rootless=${ROOTLESS})"

# Electrum constants
repo="https://github.com/spesmilo/electrum"
appId="org.electrum.electrum"

# Neutral comparator image for the inner tar comparisons (digest-pinned,
# multi-arch manifest list; never referenced by tag alone)
PYTHON_IMAGE="docker.io/library/python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf"

# Verdict-note accumulators (populated in result(), consumed by write_results())
innerNotes=""
innerFailNotes=""
innerSummary=""

# Inner tar comparator for libpybundle.so (gzip tar) and assets/private.tar (plain
# tar). Exit 0 = proven acceptable (contents identical; at most regular-file
# group-write mode diffs 0644->0664 / 0755->0775, confirmed by a raw-block
# allowlist over the uncompressed tar streams). Exit 1 = verdict-affecting.
# Exit 2 = error.
read -r -d '' PY_INNER_COMPARE <<'PY_INNER_EOF' || true
import difflib, gzip, hashlib, json, os, sys, tarfile

TYPES = {b"0": "file", b"\x00": "file", b"1": "hardlink", b"2": "symlink",
         b"3": "char", b"4": "block", b"5": "dir", b"6": "fifo", b"7": "contiguous"}

# Only the group-write bit may be added, only on regular files. These are the two
# pairs a group-writable build directory (default ACL, or root extraction of
# archives that ship 0664) produces; anything else stays verdict-affecting.
ACCEPTED = {("0644", "0664"), ("0755", "0775")}
ACCEPTED_RAW = {(0o644, 0o664), (0o755, 0o775)}

def norm(n):
    return n[2:] if n.startswith("./") else n

def read_raw(path):
    with open(path, "rb") as f:
        data = f.read()
    return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data

def read_manifest(path):
    entries = []
    with tarfile.open(path, "r:*") as tf:
        for idx, m in enumerate(tf):
            sha = "-"
            if m.isreg():
                h = hashlib.sha256()
                f = tf.extractfile(m)
                if f is not None:
                    while True:
                        chunk = f.read(1048576)
                        if not chunk:
                            break
                        h.update(chunk)
                sha = h.hexdigest()
            entries.append({
                "index": idx, "name": m.name,
                "type": TYPES.get(m.type, "other"), "linkname": m.linkname,
                "mode": format(m.mode & 0o7777, "04o"),
                "uid": m.uid, "gid": m.gid, "uname": m.uname, "gname": m.gname,
                "mtime": m.mtime, "size": m.size, "sha256": sha})
    return entries

def cksum(block):
    return sum(block[:148]) + 256 + sum(block[156:])

def octfield(b):
    s = b.split(b"\0")[0].strip(b" \0")
    return int(s, 8) if s else 0

def main():
    offp, bltp, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    off = read_manifest(offp)
    blt = read_manifest(bltp)
    mlines = {}
    for tag, ents in (("official", off), ("built", blt)):
        mlines[tag] = [json.dumps(e, sort_keys=True) for e in ents]
        with open(os.path.join(outdir, "manifest-%s.jsonl" % tag), "w") as fh:
            for ln in mlines[tag]:
                fh.write(ln + "\n")
    print("  archive members: %d official / %d built" % (len(off), len(blt)))
    print("  regular files:   %d / %d" %
          (sum(1 for e in off if e["type"] == "file"),
           sum(1 for e in blt if e["type"] == "file")))
    problems = []
    allowed = []

    def finalize(status):
        rep = ["inner tar comparison full report", "status: " + status, ""]
        rep.append("== all problems (%d) ==" % len(problems))
        rep.extend("  - " + p for p in problems)
        rep.append("")
        rep.append("== all accepted mode changes (%d) ==" % len(allowed))
        rep.extend("  %s -> %s: %s" % (a, b, n) for n, a, b in allowed)
        rep.append("")
        mdiff = list(difflib.unified_diff(
            mlines["official"], mlines["built"],
            "manifest-official.jsonl", "manifest-built.jsonl", lineterm=""))
        with open(os.path.join(outdir, "manifest-diff.txt"), "w") as fh:
            for ln in mdiff:
                fh.write(ln + "\n")
        rep.append("== manifest diff, unified (%d lines; complete copy: manifest-diff.txt) ==" % len(mdiff))
        rep.extend(mdiff[:40])
        if len(mdiff) > 40:
            rep.append("  ... (%d more lines - see manifest-diff.txt)"
                       % (len(mdiff) - 40))
        with open(os.path.join(outdir, "inner-report.txt"), "w") as fh:
            fh.write("\n".join(rep) + "\n")
    if [e["name"] for e in off] != [e["name"] for e in blt]:
        problems.append("member name sequence differs (added/removed/reordered/renamed)")
    else:
        sha_diffs = 0
        for a, b in zip(off, blt):
            bad = [k for k in ("type", "linkname", "uid", "gid", "uname",
                               "gname", "mtime", "size", "sha256") if a[k] != b[k]]
            if bad:
                if "sha256" in bad:
                    sha_diffs += 1
                problems.append("%s: %s differ" % (a["name"], ",".join(bad)))
                continue
            if a["mode"] != b["mode"]:
                if a["type"] == "file" and (a["mode"], b["mode"]) in ACCEPTED:
                    allowed.append((norm(a["name"]), a["mode"], b["mode"]))
                else:
                    problems.append("%s: disallowed mode change %s -> %s (type %s)"
                                    % (a["name"], a["mode"], b["mode"], a["type"]))
        print("  contents:        %s" % ("IDENTICAL (per-occurrence SHA-256)"
              if sha_diffs == 0 else "%d member(s) DIFFER" % sha_diffs))
    if not problems:
        rawa = read_raw(offp)
        rawb = read_raw(bltp)
        if rawa == rawb:
            finalize("ACCEPTABLE - compression wrapper only (uncompressed streams byte-identical)")
            print("  header diffs:    0 (uncompressed tar streams byte-identical)")
            print("  verdict impact:  none (compression wrapper only)")
            sys.exit(0)
        if len(rawa) != len(rawb):
            problems.append("decompressed stream lengths differ (%d vs %d)"
                            % (len(rawa), len(rawb)))
        else:
            aset = {n: (int(a, 8), int(b, 8)) for n, a, b in allowed}
            nblocks = 0
            for pos in range(0, len(rawa), 512):
                ba = rawa[pos:pos + 512]
                bb = rawb[pos:pos + 512]
                if ba == bb:
                    continue
                nblocks += 1
                err = None
                if ba[257:262] != b"ustar" or bb[257:262] != b"ustar":
                    err = "non-header block differs"
                elif (ba[:100] + bytes(8) + ba[108:148] + bytes(8) + ba[156:]) != \
                     (bb[:100] + bytes(8) + bb[108:148] + bytes(8) + bb[156:]):
                    err = "header differs beyond mode/checksum fields"
                else:
                    try:
                        ma = octfield(ba[100:108]) & 0o7777
                        mb = octfield(bb[100:108]) & 0o7777
                        ck_ok = (octfield(ba[148:156]) == cksum(ba) and
                                 octfield(bb[148:156]) == cksum(bb))
                    except ValueError:
                        ma = mb = -1
                        ck_ok = False
                    nm = ba[:100].split(b"\0")[0].decode("utf-8", "replace")
                    pref = ba[345:500].split(b"\0")[0].decode("utf-8", "replace")
                    full = norm(pref + "/" + nm if pref else nm)
                    if (ma, mb) not in ACCEPTED_RAW:
                        err = "raw mode pair %s -> %s is not an accepted group-write pair" % (oct(ma), oct(mb))
                    elif not ck_ok:
                        err = "stored header checksum invalid"
                    elif full not in aset:
                        err = "mode change on unexpected entry %r" % full
                    elif aset[full] != (ma, mb):
                        err = "raw mode pair for %r does not match its manifest entry" % full
                if err:
                    problems.append("raw-block proof FAILED at offset %d: %s" % (pos, err))
                    break
            if not problems and nblocks != len(allowed):
                problems.append("differing raw blocks (%d) != accepted entries (%d)"
                                % (nblocks, len(allowed)))
    if problems:
        finalize("MISMATCH - verdict-affecting")
        print("  RESULT:          MISMATCH - verdict-affecting")
        for p in problems[:5]:
            print("    - %s" % p)
        if len(problems) > 5:
            print("    ... (%d more - see inner-report.txt)" % (len(problems) - 5))
        sys.exit(1)
    finalize("ACCEPTABLE - regular-file group-write mode fields only")
    pairs = {}
    for n, a, b in allowed:
        pairs[(a, b)] = pairs.get((a, b), 0) + 1
    print("  header diffs:    %d - all regular files, group-write mode bit only (%s)"
          % (len(allowed), ", ".join("%s -> %s: %d" % (a, b, c) for (a, b), c in sorted(pairs.items()))))
    for n, a, b in allowed[:5]:
        print("    %s -> %s: %s" % (a, b, n))
    if len(allowed) > 5:
        print("    ... (%d more - see inner-report.txt)" % (len(allowed) - 5))
    print("  raw-tar proof:   PASSED - every differing block is a valid header of an accepted entry, mode+checksum fields only")
    print("  verdict impact:  none (proven-acceptable case)")
    sys.exit(0)

try:
    main()
except SystemExit:
    raise
except Exception as e:
    print("  ERROR: inner comparison failed: %s" % e)
    sys.exit(2)
PY_INNER_EOF

# Helper functions
containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")

  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  echo "Running apktool with $CONTAINER_CMD..."
  if ! $CONTAINER_CMD run --rm \
    --volume "${targetFolderParent}:/tfp" \
    --volume "${appFolder}:/af:ro" \
    $wsContainer \
    sh -c "apktool d -f -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then
    echo -e "${RED}Container apktool failed${NC}"
    return 1
  fi
  return 0
}

getSigner() {
  DIR=$(dirname "$1")
  BASE=$(basename "$1")
  s=$(
    $CONTAINER_CMD run --rm \
      --volume "${DIR}:/mnt:ro" \
      --workdir /mnt \
      $wsContainer \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256" | awk '{print $6}' )
  echo "$s"
}

determine_architectures() {
  local apk="$1"
  local output
  local manifest_arch
  local lib_arch

  local apk_dir apk_name
  apk_dir="$(dirname "$apk")"
  apk_name="$(basename "$apk")"
  output=$($CONTAINER_CMD run --rm --volume "${apk_dir}:/apk:ro" $wsContainer \
    sh -c "/opt/android-sdk/build-tools/29.0.3/aapt dump badging /apk/$apk_name" 2>/dev/null || true)

  if [[ -n "$output" ]]; then
    manifest_arch=$(awk -F"'" '/native-code/ {for (i=2; i<=NF; i+=2) print $i}' <<<"$output" | head -1 || true)
    if [[ -n "$manifest_arch" ]]; then
      echo "$manifest_arch"
      return 0
    fi
  fi

  # Fallback: detect ABI from APK lib/ directories when native-code is absent
  lib_arch=$($CONTAINER_CMD run --rm --volume "${apk_dir}:/apk:ro" $wsContainer \
    sh -c "unzip -l /apk/$apk_name 2>/dev/null \
      | grep -oE 'lib/[^/]+/' \
      | cut -d/ -f2 \
      | sort -u \
      | head -1" || true)
  if [[ -n "$lib_arch" ]]; then
    echo "$lib_arch"
    return 0
  fi

  echo "armeabi-v7a"  # Default fallback
}

phase_header() {
  local num="$1" name="$2"
  echo -e "${CYAN}=====================================================${NC}"
  echo -e "${CYAN}  PHASE ${num}: ${name}${NC}"
  echo -e "${CYAN}=====================================================${NC}"
}

generate_filtered_build_log() {
  local full_log="$LOG_DIR/phase2-build-full.log"
  local filtered_log="$LOG_DIR/phase2-build.log"
  [ -f "$full_log" ] || return 0
  {
    echo "=== PHASE 2 BUILD LOG (FILTERED) — full log: $full_log ==="
    echo ""
    echo "--- Errors and Warnings ---"
    grep -iE "(error|warning|fatal|exception|traceback|failed|cannot|not found)" "$full_log" \
      | grep -v "^+" | head -50 || echo "(none)"
    echo ""
    echo "--- Key Events ---"
    grep -E "(Building Docker|Cloning|Checking out|Normalizing source permissions|chmod|Build completed|umask|make_apk|Starting containerized|pip install|Downloading|Successfully built)" "$full_log" \
      | head -30 || echo "(none)"
    echo ""
    echo "--- Last 30 lines ---"
    tail -30 "$full_log"
  } > "$filtered_log"
  echo -e "${CYAN}Phase 2 filtered log: $filtered_log${NC}"
}

usage() {
  echo 'NAME
       electrumandroid-v2.4.0_build.sh - verify Electrum wallet build

SYNOPSIS
       electrumandroid-v2.4.0_build.sh --binary APK_FILE [--version V] [--arch A] [--type T]

DESCRIPTION
       This command verifies builds of Electrum wallet.
       Version and architecture are extracted from the APK.

       --binary    The apk file to test (a directory holding base.apk is accepted)
       --apk       Alias for --binary
       --version, --arch, --type
                   Accepted for build server compatibility; values are taken from the APK
       Unknown parameters are ignored with a warning.

EXIT CODES
       0 reproducible, 1 not reproducible or build failure, 2 invalid input

EXAMPLES
       electrumandroid-v2.4.0_build.sh --binary /path/to/electrum.apk'
}

# Parse arguments
downloadedApk=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --apk|--binary)
      [ -n "${2:-}" ] || { echo "Error: $1 needs a value"; usage; exit 2; }
      downloadedApk="$2"; shift 2 ;;
    --help) trap - EXIT; usage; exit 0 ;;
    --*)
      # A value that does not look like a flag belongs to this parameter.
      opt="$1"; val=""
      case "${2:-}" in ""|--*) ;; *) val="$2"; shift ;; esac
      case $opt in
        --version|--arch|--type) echo "Note: $opt $val accepted as a hint; values are read from the APK" ;;
        *) echo "Warning: Ignoring unknown parameter: $opt $val" ;;
      esac
      shift ;;
    *) echo "Warning: Ignoring unknown parameter: $1"; shift ;;
  esac
done

# Validate inputs
if [ "$HOST_UID" -eq 0 ]; then
  echo "Do not run this script as root."
  exit 2
fi
if [ -z "$downloadedApk" ]; then
  echo "No APK given (--binary APK_FILE)."
  echo
  usage
  exit 2
fi
if [ -d "$downloadedApk" ] && [ -f "$downloadedApk/base.apk" ]; then
  downloadedApk="$downloadedApk/base.apk"
fi
if [ ! -f "$downloadedApk" ]; then
  echo "APK file not found: $downloadedApk"
  echo
  usage
  exit 2
fi

# Make path absolute
case $downloadedApk in /*) ;; *) downloadedApk="$(pwd -P)/$downloadedApk" ;; esac

# Verify app ID using aapt2 first — fail fast before costly apktool decompilation.
# The same line gives the versionName used to name the workspace.
badging=$($CONTAINER_CMD run --rm \
  --volume "$(dirname "$downloadedApk"):/apk:ro" \
  $wsContainer \
  sh -c "/opt/android-sdk/build-tools/29.0.3/aapt2 dump badging /apk/$(basename "$downloadedApk") 2>/dev/null | grep '^package:'" || true)
extractedAppId=$(echo "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
hintVersion=$(echo "$badging" | sed -n "s/.* versionName='\([^']*\)'.*/\1/p")

if [ -z "$extractedAppId" ]; then
  echo "appId could not be determined (not a readable APK?)"
  exit 2
fi

if [ "$extractedAppId" != "$appId" ]; then
  echo "This script is only for Electrum wallet (org.electrum.electrum)"
  echo "Detected appId: $extractedAppId"
  exit 2
fi

# Detect architecture
build_arch=$(determine_architectures "$downloadedApk")
echo "Detected architecture: $build_arch"

# Per-run workspace in the caller's directory, created exclusively; never deleted,
# renamed or reused. Every per-run resource name carries RUN_ID.
safe_version="$(printf '%s' "${hintVersion:-unknown}" | tr -c '[:alnum:]._-' '-')"
safe_arch="$(printf '%s' "$build_arch" | tr -c '[:alnum:]._-' '-')"
WORK_BASE="$(pwd -P)"
for _try in 1 2 3; do
  RUN_ID="$(date +%s)-$$"
  candidate="$WORK_BASE/electrum_verification_${safe_version}_${safe_arch}_${RUN_ID}"
  if mkdir "$candidate" 2>/dev/null; then
    workDir="$candidate"
    break
  fi
  echo "Workspace $candidate already exists; retrying with a new run id"
  sleep 1
done
if [ -z "$workDir" ]; then
  echo -e "${RED}Error: could not create a fresh workspace under $WORK_BASE${NC}"
  write_ftbfs "Could not create a fresh workspace under $WORK_BASE (exists or not writable)."
  exit 1
fi
LOG_DIR="$workDir/build-logs"
DIFF_FILE="$workDir/diff_full.txt"
BUILD_RUN_LABEL="walletscrutiny.run=${RUN_ID}"
mkdir "$LOG_DIR"
echo "Workspace: $workDir"

# Extract APK metadata
appHash=$($CONTAINER_CMD run --rm \
  --volume "$(dirname "$downloadedApk"):/apk:ro" \
  $wsContainer sha256sum "/apk/$(basename "$downloadedApk")" | awk '{print $1;}')
fromPlayFolder="$workDir/apktool-official"
signer=$(getSigner "$downloadedApk")
echo "Extracting APK content..."
containerApktool "$fromPlayFolder" "$downloadedApk" || exit 1

versionName=$(cat "$fromPlayFolder/apktool.yml" | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
versionCode=$(cat "$fromPlayFolder/apktool.yml" | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")

if [ -z "$versionName" ]; then
  echo "versionName could not be determined"
  exit 2
fi

if [ -z "$versionCode" ]; then
  echo "versionCode could not be determined"
  exit 2
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Use versionName directly as tag - don't strip anything
tag="$versionName"
echo "Will checkout tag: $tag"

builtApk="$workDir/app/dist/Electrum-$versionName-$build_arch-release-unsigned.apk"

normalize_source_permissions() {
  local target_dir="$1"
  echo "Normalizing source permissions under $target_dir (dirs 755, files 644)..."
  $CONTAINER_CMD run --rm \
    --user root \
    --volume "$target_dir":/workspace \
    --workdir /workspace \
    $wsContainer \
    sh -c "git config --global --add safe.directory '*' && \
           find . -type d -exec chmod 755 {} + && \
           find . -type f -exec chmod 644 {} + && \
           git ls-files -s | grep '^100755' | cut -f2 | while IFS= read -r path; do chmod 755 \"\$path\"; done && \
           git submodule foreach --recursive 'git ls-files -s | grep \"^100755\" | cut -f2 | while IFS= read -r path; do chmod 755 \"\$path\"; done'" || return 1
}

prepare() {
  echo "Cloning repository..."
  ctr_wait $CONTAINER_CMD run --rm \
    --label "$BUILD_RUN_LABEL" \
    --volume "$workDir":/workspace \
    $wsContainer \
    git clone --quiet --recurse-submodules "$repo" /workspace/app || return 1

  echo "Checking out version: $tag"
  ctr_wait $CONTAINER_CMD run --rm \
    --label "$BUILD_RUN_LABEL" \
    --volume "$workDir/app":/workspace \
    --workdir /workspace \
    $wsContainer \
    sh -c "git fetch --quiet --tags && \
           (git checkout --quiet 'refs/tags/$tag' || git checkout --quiet '$tag') && \
           git submodule update --init --recursive" || return 1

  commit=$($CONTAINER_CMD run --rm \
    --volume "$workDir/app":/workspace \
    --workdir /workspace \
    $wsContainer git rev-parse HEAD) || return 1

  normalize_source_permissions "$workDir/app" || return 1

  echo -e "${GREEN}Environment prepared${NC}"
}

build_electrum() {
  local app_hash_short uid gid

  app_hash_short="${appHash:0:12}"
  BUILD_IMAGE_TAG="electrum-android:${appId}-${safe_version}-${safe_arch}-${app_hash_short}-${RUN_ID}"

  echo "Building Electrum from source..."
  if [ ! -f "$workDir/app/contrib/android/Dockerfile" ]; then
    echo -e "${RED}Missing contrib/android/Dockerfile${NC}"
    return 1
  fi

  cp "$workDir/app/contrib/deterministic-build/requirements-build-android.txt" "$workDir/app/contrib/android/" || true

  # Always use UID 1000 for container to avoid conflicts
  uid=1000
  gid=1000

  echo "Building Docker image..."
  echo "Image tag for this run: $BUILD_IMAGE_TAG"
  if ! ctr_wait $CONTAINER_CMD build \
    --pull \
    --no-cache \
    --tag "$BUILD_IMAGE_TAG" \
    --label "$BUILD_RUN_LABEL" \
    --file "$workDir/app/contrib/android/Dockerfile" \
    --build-arg UID="$uid" \
    --build-arg GID="$gid" \
    "$workDir/app"; then
    echo -e "${RED}Docker build failed!${NC}"
    return 1
  fi

  mkdir -p "$workDir/app/.gradle"
  mkdir -p "$workDir/app/dist"
  chmod -R 777 "$workDir/app/dist" 2>/dev/null || true

  echo "Starting containerized build for architecture: $build_arch"
  echo "This may take 15-30 minutes..."

  if ! ctr_wait $CONTAINER_CMD run --rm \
    --name "electrum-build-${RUN_ID}" \
    --label "$BUILD_RUN_LABEL" \
    --user root \
    --env GIT_PAGER=cat \
    --env PAGER=cat \
    --env VIRTUAL_ENV=/opt/venv \
    --env PATH="/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --env BUILDOZER_WARN_ON_ROOT=0 \
    --volume "$workDir/app:/home/user/wspace/electrum" \
    --volume "$workDir/app/.gradle:/home/user/.gradle" \
    --workdir /home/user/wspace/electrum \
    "$BUILD_IMAGE_TAG" \
    bash -lc "umask 0022 && set -x && \
      source /opt/venv/bin/activate && \
      git config --global --add safe.directory /home/user/wspace/electrum && \
      mkdir -p dist && \
      find /home/user/wspace/electrum -type d -exec chmod 755 {} + && \
      find /home/user/wspace/electrum -type f -exec chmod 644 {} + && \
      git config --global --add safe.directory '*' && \
      git ls-files -s | grep '^100755' | cut -f2 | while IFS= read -r path; do chmod 755 \"\$path\"; done && \
      git submodule foreach --recursive 'git ls-files -s | grep \"^100755\" | cut -f2 | while IFS= read -r path; do chmod 755 \"\$path\"; done' && \
      ./contrib/android/make_apk.sh qml '$build_arch' release-unsigned"; then
    echo -e "${RED}Build failed!${NC}"
    return 1
  fi

  echo -e "${GREEN}Build completed successfully!${NC}"

  # Find built APK
  echo "Searching for built APK..."

  # First try the expected location
  if [ -f "$builtApk" ]; then
    echo "Found APK at expected location: $builtApk"
  else
    # Search in buildozer output directories
    builtApk=$(find "$workDir/app/.buildozer" -type f \( -name "*Electrum*${build_arch}*release*.apk" -o -name "*electrum*${build_arch}*release*.apk" \) 2>/dev/null | head -1)

    if [ -z "$builtApk" ]; then
      # Search more broadly for any arm64 APK
      builtApk=$(find "$workDir/app/.buildozer" -type f -name "*${build_arch}*.apk" 2>/dev/null | grep -i electrum | head -1)
    fi

    if [ -z "$builtApk" ]; then
      # Last resort: search for any APK in dist directories
      builtApk=$(find "$workDir/app/.buildozer/android/platform/build-${build_arch}/dists" -type f -name "*.apk" 2>/dev/null | head -1)
    fi

    if [ -z "$builtApk" ]; then
      # Ultimate fallback: any APK anywhere
      builtApk=$(find "$workDir/app" -type f -name "*.apk" 2>/dev/null | head -1)
    fi
  fi

  if [ -z "$builtApk" ] || [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found${NC}"
    echo "Checking build outputs:"
    find "$workDir/app" -name "*.apk" -type f 2>/dev/null || echo "No APK files found"
    return 1
  fi

  echo -e "${GREEN}Built APK found: $builtApk${NC}"
  echo "APK size: $(ls -lh "$builtApk" | awk '{print $5}')"
}

result() {
  echo "Running comparison inside container (isolated /tmp — no host extraction dirs)..."

  # Run extraction and diff entirely inside the container.
  # Container uses its own ephemeral /tmp — no host-side extraction dirs created,
  # no ownership cycle between runs.
  local diffResult
  diffResult=$($CONTAINER_CMD run --rm \
    --volume "${downloadedApk}:/play.apk:ro" \
    --volume "${builtApk}:/built.apk:ro" \
    $wsContainer \
    sh -c '
      mkdir -p /tmp/fromPlay /tmp/fromBuild
      unzip -d /tmp/fromPlay -qq /play.apk || exit 1
      unzip -d /tmp/fromBuild -qq /built.apk || exit 1
      diff --brief --recursive /tmp/fromPlay /tmp/fromBuild 2>/dev/null || true
    ' 2>&1) || {
      echo -e "${RED}Comparison container failed — writing ftbfs result${NC}"
      echo "===== Begin Results ====="
      echo "appId:          $appId"
      echo "signer:         $signer"
      echo "apkVersionName: $versionName"
      echo "apkVersionCode: $versionCode"
      echo "verdict:        ftbfs"
      echo "appHash:        $appHash"
      echo "commit:         $commit"
      echo "scriptVersion:  $SCRIPT_VERSION"
      echo "scriptHash:     $SCRIPT_SHA256"
      echo "===== End Results ====="
      write_results "ftbfs"
      return 0
    }

  # Write full diff to file for post-verification analysis
  echo "$diffResult" > "$DIFF_FILE"

  # Strict root-level META-INF filter (per Leo's guideline)
  local excludedDiffs nonExcludedDiffs
  excludedDiffs=$(echo "$diffResult" | grep -E "^(Files|Only in) /tmp/fromPlay/META-INF|^(Files|Only in) /tmp/fromBuild/META-INF" || true)
  nonExcludedDiffs=$(echo "$diffResult" | grep -vE "^(Files|Only in) /tmp/fromPlay/META-INF|^(Files|Only in) /tmp/fromBuild/META-INF|^$" || true)

  # Inner tar comparison (v2.2.0 libpybundle.so; v2.3.0 also assets/private.tar).
  # libpybundle.so is a gzip-compressed tar (Python bytecode, nested native libs,
  # stdlib); assets/private.tar is a plain tar (Electrum's own Python). Neither is
  # ever excluded by filename: a differing archive is lifted from the verdict only
  # when proven acceptable — stage 1: uncompressed tar streams byte-identical
  # (compression wrapper only); stage 2: per-occurrence manifest identical except
  # regular-file group-write mode fields (0644->0664, 0755->0775), plus a raw-block
  # allowlist proving no other tar byte changed. Any other difference, or any
  # comparator failure, stays verdict-affecting (fail closed).
  # Group-write modes appear when the build directory is group-writable, e.g. the
  # ABS default ACL on /opt/build-server-builds/ (GitLab #900), which overrides
  # the build's umask 0022.
  local innerLines pline member label safeMember cmpDir evidenceName evidenceFile stage1 pyOut pyRc noteText
  innerLines=$(echo "$nonExcludedDiffs" | grep -E '^Files .*/(libpybundle\.so|assets/private\.tar) and .* differ$' || true)
  while IFS= read -r pline; do
    [ -z "$pline" ] && continue
    member=${pline#Files /tmp/fromPlay/}
    member=${member%% and *}
    label=$(basename "$member")
    safeMember=$(echo "$member" | tr '/' '_')
    cmpDir="$workDir/inner-compare-$safeMember"
    evidenceName="diff_inner_${safeMember}.txt"
    evidenceFile="$workDir/$evidenceName"
    mkdir -p "$cmpDir/out"
    echo "$label differs — running inner comparison for $member ..."
    if ! stage1=$($CONTAINER_CMD run --rm \
      --env MEMBER="$member" \
      --volume "${downloadedApk}:/play.apk:ro" \
      --volume "${builtApk}:/built.apk:ro" \
      --volume "$cmpDir":/cmp \
      $wsContainer \
      sh -c 'set -e
        unzip -p /play.apk "$MEMBER" > /cmp/official.bin
        unzip -p /built.apk "$MEMBER" > /cmp/built.bin
        case "$MEMBER" in
          *.tar) cp /cmp/official.bin /cmp/official.tar; cp /cmp/built.bin /cmp/built.tar ;;
          *) zcat /cmp/official.bin > /cmp/official.tar; zcat /cmp/built.bin > /cmp/built.tar ;;
        esac
        if cmp -s /cmp/official.tar /cmp/built.tar; then echo WRAPPER_ONLY; else echo STREAMS_DIFFER; fi
        rm -f /cmp/official.tar /cmp/built.tar' 2>&1); then
      echo -e "${RED}  inner comparison stage 1 failed — $member stays verdict-affecting${NC}"
      echo "$stage1" | tail -3
      {
        echo "$label inner comparison ($member):"
        echo "  RESULT: stage 1 (extract/decompress) FAILED - verdict-affecting"
        echo ""
        echo "----- stage 1 output -----"
        echo "$stage1"
      } > "$evidenceFile"
      innerSummary+="$label inner comparison ($member):
  RESULT:          stage 1 (extract/decompress) FAILED - verdict-affecting
  evidence:        $evidenceName

"
      innerFailNotes+="${member}: inner comparison could not run (stage 1 failure) - treated as verdict-affecting. Evidence: $evidenceName
"
      continue
    fi
    if echo "$stage1" | grep -q '^WRAPPER_ONLY$'; then
      pyOut="  uncompressed tar streams: byte-identical
  difference confined to:   compression container metadata only
  verdict impact:           none"
      pyRc=0
      noteText="${member}: uncompressed tar streams byte-identical; difference confined to compression container metadata."
    else
      if pyOut=$($CONTAINER_CMD run --rm --network none \
        --volume "$cmpDir/official.bin":/in/official.bin:ro \
        --volume "$cmpDir/built.bin":/in/built.bin:ro \
        --volume "$cmpDir/out":/out \
        "$PYTHON_IMAGE" \
        python3 -c "$PY_INNER_COMPARE" /in/official.bin /in/built.bin /out 2>&1); then
        pyRc=0
      else
        pyRc=$?
      fi
      noteText="${member}: inner tar contents byte-identical per occurrence; remaining differences proven confined to accepted regular-file group-write mode fields (0644->0664, 0755->0775)."
    fi
    {
      echo "$label inner comparison ($member):"
      echo "$pyOut"
      echo ""
      if [ -f "$cmpDir/out/inner-report.txt" ]; then
        echo "----- full inner report -----"
        cat "$cmpDir/out/inner-report.txt" 2>/dev/null || echo "(inner-report.txt not readable)"
      fi
      if [ -f "$cmpDir/out/manifest-official.jsonl" ]; then
        echo ""
        echo "Manifests (JSON Lines, one object per entry in archive order) and full diff:"
        echo "  $cmpDir/out/manifest-official.jsonl"
        echo "  $cmpDir/out/manifest-built.jsonl"
        echo "  $cmpDir/out/manifest-diff.txt"
      fi
    } > "$evidenceFile"
    innerSummary+="$label inner comparison ($member):
$pyOut
  evidence:        $evidenceName

"
    if [ "$pyRc" -eq 0 ]; then
      nonExcludedDiffs=$(echo "$nonExcludedDiffs" | grep -vF "$pline" || true)
      excludedDiffs=$(printf '%s\n%s' "$excludedDiffs" "$pline" | sed '/^$/d')
      innerNotes+="$noteText Evidence: $evidenceName
"
      echo -e "${GREEN}  inner comparison: proven acceptable — lifted from verdict${NC}"
    else
      innerFailNotes+="${member}: inner comparison found verdict-affecting differences (exit $pyRc). Evidence: $evidenceName
"
      echo -e "${RED}  inner comparison: NOT acceptable (exit $pyRc) — stays verdict-affecting${NC}"
    fi
  done <<< "$innerLines"

  local diffCount=0
  [ -n "$nonExcludedDiffs" ] && diffCount=$(echo "$nonExcludedDiffs" | wc -l)

  local verdict="reproducible"
  [ "$diffCount" -gt 0 ] && verdict="not_reproducible"

  builtHash=$($CONTAINER_CMD run --rm \
    --volume "$(dirname "$builtApk"):/built:ro" \
    $wsContainer sha256sum "/built/$(basename "$builtApk")" | awk '{print $1}')

  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $versionName"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "builtHash:      $builtHash"
  echo "commit:         $commit"
  echo "architecture:   $build_arch"
  echo "scriptVersion:  $SCRIPT_VERSION"
  echo "scriptHash:     $SCRIPT_SHA256"
  echo ""

  if [ -n "$excludedDiffs" ]; then
    echo "Excluded from verdict (root META-INF signing files / proven-acceptable inner diffs):"
    echo "$excludedDiffs" \
      | sed 's|/tmp/fromPlay/||;s|/tmp/fromBuild/||' \
      | head -5
    local excludedCount
    excludedCount=$(echo "$excludedDiffs" | wc -l)
    [ "$excludedCount" -gt 5 ] && echo "  ... ($((excludedCount - 5)) more — see $DIFF_FILE)"
    echo ""
  fi

  if [ -n "$innerSummary" ]; then
    printf '%s' "$innerSummary"
  fi

  echo "Diff (non-excluded, max 5 lines — full diff: $DIFF_FILE):"
  if [ -n "$nonExcludedDiffs" ]; then
    echo "$nonExcludedDiffs" | head -5
    local totalNonExcluded
    totalNonExcluded=$(echo "$nonExcludedDiffs" | wc -l)
    [ "$totalNonExcluded" -gt 5 ] && echo "  ... ($((totalNonExcluded - 5)) more lines — see $DIFF_FILE)"
  else
    echo "(no differences)"
  fi
  echo ""
  echo "Differences found (root META-INF and proven-acceptable diffs excluded): $diffCount"
  echo "===== End Results ====="

  write_results "$verdict"
}

write_results() {
  local status=$1

  if [ "$status" = "ftbfs" ]; then
    write_ftbfs "Comparison stage failed before completing; see terminal logs."
  else
    {
      echo "script_version: ${SCRIPT_VERSION}"
      echo "verdict: ${status}"
      echo "notes: |"
      echo "  Root META-INF/* differences (Google Play signing files) are excluded from the verdict."
      if [ -n "$innerNotes" ]; then
        printf '%s' "$innerNotes" | sed 's/^/  Accepted: /'
      fi
      if [ -n "$innerFailNotes" ]; then
        printf '%s' "$innerFailNotes" | sed 's/^/  Verdict-affecting: /'
      fi
    } > "$RESULTS_FILE"
    RESULTS_WRITTEN=1
    FINAL_VERDICT="$status"
  fi

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
  cp "$RESULTS_FILE" "$LOG_DIR/phase4-results-yaml.log" 2>/dev/null || true
}

# Main execution
echo "Starting Electrum wallet verification..."
echo "This process may take 15-30 minutes depending on your system."
echo "Build logs: $LOG_DIR/"
echo

# Save original stdout/stderr so phase tee can write to both log and terminal
exec 5>&1 6>&2

# --- Phase 1: Prepare ---
exec > >(tee "$LOG_DIR/phase1-prepare.log" >&5) 2>&1
phase_header 1 "PREPARE"
prepare || { exec 1>&5 2>&6; echo -e "${RED}prepare() failed${NC}"; exit 1; }
exec 1>&5 2>&6
echo "Repository prepared. Starting build..."

# --- Phase 2: Build ---
exec > >(tee "$LOG_DIR/phase2-build-full.log" >&5) 2>&1
phase_header 2 "BUILD"
build_electrum || { exec 1>&5 2>&6; echo -e "${RED}build_electrum() failed${NC}"; exit 1; }
exec 1>&5 2>&6
generate_filtered_build_log
echo "Build completed. Running comparison..."

# --- Phase 3: Comparison ---
exec > >(tee "$LOG_DIR/phase3-result.log" >&5) 2>&1
phase_header 3 "COMPARISON"
result || { exec 1>&5 2>&6; echo -e "${RED}result() failed${NC}"; exit 1; }
exec 1>&5 2>&6

# Phase 4 log (copy of COMPARISON_RESULTS.yaml) is written by write_results()

echo
echo "Electrum verification finished!"
echo "COMPARISON_RESULTS.yaml: $RESULTS_FILE"
echo "Build logs: $LOG_DIR/"
# Exit codes: 0 reproducible, 1 not reproducible or build failure, 2 invalid input
case "$FINAL_VERDICT" in
  reproducible) exit 0 ;;
  *) exit 1 ;;
esac
