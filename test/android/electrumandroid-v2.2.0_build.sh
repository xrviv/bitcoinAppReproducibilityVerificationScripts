#!/bin/bash
# ==============================================================================
# electrumandroid_build.sh - Electrum Android Reproducible Build Verification
# ==============================================================================
# Version:          v2.2.0
# Organization:     WalletScrutiny.com
# Last modified by: Danny Garcia
# Last modified on: 2026-07-14
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

SCRIPT_VERSION="v2.2.0"
echo "Starting electrumandroid_build.sh script version ${SCRIPT_VERSION}"

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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
workDir="$SCRIPT_DIR/electrum-work"
DIFF_FILE="$workDir/diff_full.txt"
RESULTS_FILE="$SCRIPT_DIR/COMPARISON_RESULTS.yaml"
LOG_DIR="$SCRIPT_DIR/build-logs"
wsContainer="docker.io/walletscrutiny/android:5"
RESULTS_WRITTEN=0
BUILD_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BUILD_RUN_LABEL="walletscrutiny.run=${BUILD_RUN_ID}"
BUILD_TARGET_LABEL=""
BUILD_IMAGE_TAG=""

cleanup() {
  if [ -n "${CONTAINER_CMD:-}" ]; then
    echo "Cleaning up Docker resources..."
    local run_containers run_images
    run_containers=$($CONTAINER_CMD ps -aq --filter "label=${BUILD_RUN_LABEL}" 2>/dev/null || true)
    run_images=$($CONTAINER_CMD images -q --filter "label=${BUILD_RUN_LABEL}" 2>/dev/null || true)

    if [ -n "$run_containers" ]; then
      echo "$run_containers" | xargs -r $CONTAINER_CMD rm -f >/dev/null 2>&1 || true
    fi
    if [ -n "$run_images" ]; then
      echo "$run_images" | xargs -r $CONTAINER_CMD rmi -f >/dev/null 2>&1 || true
    fi

    if [ -n "${BUILD_IMAGE_TAG:-}" ]; then
      $CONTAINER_CMD rmi "$BUILD_IMAGE_TAG" -f 2>/dev/null || true
    fi
    $CONTAINER_CMD rmi electrum-android:local -f 2>/dev/null || true
    $CONTAINER_CMD image prune -f 2>/dev/null || true
  fi
}

on_exit() {
  local exit_code=$?
  local yellow="${YELLOW:-}"
  local nc="${NC:-}"
  cleanup

  if [ "$exit_code" -ne 0 ] && [ "$RESULTS_WRITTEN" -eq 0 ]; then
    cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  Script failed before completing verification summary output.
  See terminal logs for the failing step.
EOF
    echo -e "${yellow}Fallback results written to: $RESULTS_FILE${nc}"
  fi

  echo
  if [ -f "$DIFF_FILE" ]; then
    echo "Full diff data can be found here: $DIFF_FILE"
    echo "Quick view command:"
    echo "  sed -n '1,120p' \"$DIFF_FILE\""
  else
    echo "Full diff data can be found here: (not generated in this run)"
  fi
  echo "Results YAML can be found here: $RESULTS_FILE"
  echo "Build logs: $LOG_DIR/"
  echo "Exit code: $exit_code"
}

trap on_exit EXIT

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo "Error: Neither podman nor docker found. Please install Docker or Podman."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

# Electrum constants
repo="https://github.com/spesmilo/electrum"
appId="org.electrum.electrum"

# Neutral comparator image for the libpybundle.so inner comparison (digest-pinned,
# multi-arch manifest list; never referenced by tag alone)
PYTHON_IMAGE="docker.io/library/python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf"

# Verdict-note accumulators (populated in result(), consumed by write_results())
privateTarNote=""
libpybundleNotes=""
libpybundleFailNotes=""
pybundleSummary=""

# libpybundle.so inner comparator. Exit 0 = proven acceptable (contents identical;
# at most regular-file 0644->0664 mode diffs, confirmed by a raw-block allowlist
# over the decompressed tar streams). Exit 1 = verdict-affecting. Exit 2 = error.
read -r -d '' PY_INNER_COMPARE <<'PY_INNER_EOF' || true
import difflib, gzip, hashlib, json, os, sys, tarfile

TYPES = {b"0": "file", b"\x00": "file", b"1": "hardlink", b"2": "symlink",
         b"3": "char", b"4": "block", b"5": "dir", b"6": "fifo", b"7": "contiguous"}

def norm(n):
    return n[2:] if n.startswith("./") else n

def read_manifest(path):
    entries = []
    with tarfile.open(path, "r:gz") as tf:
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
        rep = ["libpybundle.so inner comparison full report", "status: " + status, ""]
        rep.append("== all problems (%d) ==" % len(problems))
        rep.extend("  - " + p for p in problems)
        rep.append("")
        rep.append("== all accepted mode changes (%d) ==" % len(allowed))
        rep.extend("  0644 -> 0664: " + n for n in allowed)
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
                if a["type"] == "file" and a["mode"] == "0644" and b["mode"] == "0664":
                    allowed.append(norm(a["name"]))
                else:
                    problems.append("%s: disallowed mode change %s -> %s (type %s)"
                                    % (a["name"], a["mode"], b["mode"], a["type"]))
        print("  contents:        %s" % ("IDENTICAL (per-occurrence SHA-256)"
              if sha_diffs == 0 else "%d member(s) DIFFER" % sha_diffs))
    if not problems:
        with gzip.open(offp, "rb") as f:
            rawa = f.read()
        with gzip.open(bltp, "rb") as f:
            rawb = f.read()
        if rawa == rawb:
            finalize("ACCEPTABLE - gzip wrapper only (decompressed streams byte-identical)")
            print("  header diffs:    0 (decompressed tar streams byte-identical)")
            print("  verdict impact:  none (gzip wrapper only)")
            sys.exit(0)
        if len(rawa) != len(rawb):
            problems.append("decompressed stream lengths differ (%d vs %d)"
                            % (len(rawa), len(rawb)))
        else:
            aset = set(allowed)
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
                    if (ma, mb) != (0o644, 0o664):
                        err = "raw mode pair %s -> %s is not the accepted 0644 -> 0664" % (oct(ma), oct(mb))
                    elif not ck_ok:
                        err = "stored header checksum invalid"
                    elif full not in aset:
                        err = "mode change on unexpected entry %r" % full
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
    finalize("ACCEPTABLE - regular-file 0644->0664 mode fields only")
    print("  header diffs:    %d - all regular files, mode 0644 -> 0664 only" % len(allowed))
    for n in allowed[:5]:
        print("    0644 -> 0664: %s" % n)
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
       electrumandroid_build.sh - verify Electrum wallet build

SYNOPSIS
       electrumandroid_build.sh --apk APK_FILE
       electrumandroid_build.sh --binary APK_FILE

DESCRIPTION
       This command verifies builds of Electrum wallet.
       Version is automatically extracted from the APK.

       --apk       The apk file to test
       --binary    Alias for --apk (accepted for build server compatibility)

EXAMPLES
       electrumandroid_build.sh --apk electrum.apk
       electrumandroid_build.sh --binary /path/to/electrum.apk'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --apk|--binary) downloadedApk="$2"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Warning: Ignoring unknown parameter: $1" ;;
  esac
  shift
done

# Validate inputs
if [ ! -f "$downloadedApk" ]; then
  echo "APK file not found!"
  echo
  usage
  exit 1
fi

# Make path absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Verify app ID using aapt2 first — fail fast before costly apktool decompilation
extractedAppId=$($CONTAINER_CMD run --rm \
  --volume "$(dirname "$downloadedApk"):/apk:ro" \
  $wsContainer \
  sh -c "/opt/android-sdk/build-tools/29.0.3/aapt2 dump badging /apk/$(basename "$downloadedApk") 2>/dev/null | grep '^package:' | sed \"s/^package: name='//;s/'.*//\"")

if [ -z "$extractedAppId" ]; then
  echo "appId could not be determined"
  exit 1
fi

if [ "$extractedAppId" != "$appId" ]; then
  echo "This script is only for Electrum wallet (org.electrum.electrum)"
  echo "Detected appId: $extractedAppId"
  exit 1
fi

# Extract APK metadata
appHash=$($CONTAINER_CMD run --rm \
  --volume "$(dirname "$downloadedApk"):/apk:ro" \
  $wsContainer sha256sum "/apk/$(basename "$downloadedApk")" | awk '{print $1;}')
# Use a unique extraction folder every run to avoid collisions with stale root-owned paths.
fromPlayFolder=$(mktemp -d "/tmp/fromPlay${appHash}.XXXXXX")
signer=$(getSigner "$downloadedApk")
echo "Extracting APK content..."
containerApktool "$fromPlayFolder" "$downloadedApk" || exit 1

versionName=$(cat "$fromPlayFolder/apktool.yml" | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
versionCode=$(cat "$fromPlayFolder/apktool.yml" | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")

# Best-effort cleanup of apktool extraction folder.
$CONTAINER_CMD run --rm \
  --user root \
  --volume /tmp:/tmp \
  $wsContainer rm -rf "$fromPlayFolder" >/dev/null 2>&1 || true

if [ -z "$versionName" ]; then
  echo "versionName could not be determined"
  exit 1
fi

if [ -z "$versionCode" ]; then
  echo "versionCode could not be determined"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Detect architecture
build_arch=$(determine_architectures "$downloadedApk")
echo "Detected architecture: $build_arch"

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
  echo "Setting up workspace..."
  # Use container as root to remove workDir — build artifacts may be root-owned from previous runs
  if [ -d "$workDir" ]; then
    $CONTAINER_CMD run --rm \
      --user root \
      --volume "$(dirname "$workDir")":/parent \
      $wsContainer \
      rm -rf "/parent/$(basename "$workDir")" || true
  fi
  mkdir -p "$workDir"

  echo "Cloning repository..."
  $CONTAINER_CMD run --rm \
    --volume "$workDir":/workspace \
    $wsContainer \
    git clone --quiet --recurse-submodules "$repo" /workspace/app

  echo "Checking out version: $tag"
  $CONTAINER_CMD run --rm \
    --volume "$workDir/app":/workspace \
    --workdir /workspace \
    $wsContainer \
    sh -c "git fetch --quiet --tags && \
           (git checkout --quiet 'refs/tags/$tag' || git checkout --quiet '$tag') && \
           git submodule update --init --recursive"

  commit=$($CONTAINER_CMD run --rm \
    --volume "$workDir/app":/workspace \
    --workdir /workspace \
    $wsContainer git rev-parse HEAD)

  normalize_source_permissions "$workDir/app"

  echo -e "${GREEN}Environment prepared${NC}"
}

build_electrum() {
  local app_hash_short safe_version safe_arch target_slug
  local existing_target_containers existing_target_images

  app_hash_short="${appHash:0:12}"
  safe_version="$(echo "$versionName" | tr -c '[:alnum:]._-' '-')"
  safe_arch="$(echo "$build_arch" | tr -c '[:alnum:]._-' '-')"
  target_slug="${appId}-${safe_version}-${safe_arch}-${app_hash_short}"
  BUILD_TARGET_LABEL="walletscrutiny.target=${target_slug}"
  BUILD_IMAGE_TAG="electrum-android:${target_slug}-${BUILD_RUN_ID}"

  existing_target_containers=$($CONTAINER_CMD ps -aq --filter "label=${BUILD_TARGET_LABEL}" 2>/dev/null || true)
  existing_target_images=$($CONTAINER_CMD images -q --filter "label=${BUILD_TARGET_LABEL}" 2>/dev/null || true)
  if [ -n "$existing_target_containers" ] || [ -n "$existing_target_images" ]; then
    echo -e "${RED}Stale container/image artifacts detected for this target.${NC}"
    echo "Target label: ${BUILD_TARGET_LABEL}"
    echo "Please clean stale artifacts first, then rerun."
    return 1
  fi

  echo "Building Electrum from source..."
  (
    cd "$workDir/app" || exit 1
    
    if [ ! -f contrib/android/Dockerfile ]; then
      echo -e "${RED}Missing contrib/android/Dockerfile${NC}"
      exit 1
    fi
    
    cp contrib/deterministic-build/requirements-build-android.txt contrib/android/ || true
    
    # Always use UID 1000 for container to avoid conflicts
    uid=1000
    gid=1000
    
    echo "Building Docker image..."
    echo "Image tag for this run: $BUILD_IMAGE_TAG"
    if ! $CONTAINER_CMD build \
      --pull \
      --no-cache \
      --tag "$BUILD_IMAGE_TAG" \
      --label "$BUILD_RUN_LABEL" \
      --label "$BUILD_TARGET_LABEL" \
      --file contrib/android/Dockerfile \
      --build-arg UID="$uid" \
      --build-arg GID="$gid" \
      .; then
      echo -e "${RED}Docker build failed!${NC}"
      exit 1
    fi
    
    mkdir -p "$workDir/app/.gradle"
    mkdir -p "$workDir/app/dist"
    chmod -R 777 "$workDir/app/dist" 2>/dev/null || true
    
    echo "Starting containerized build for architecture: $build_arch"
    echo "This may take 15-30 minutes..."
    
    if ! $CONTAINER_CMD run --rm \
      --label "$BUILD_RUN_LABEL" \
      --label "$BUILD_TARGET_LABEL" \
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
      exit 1
    fi
    
    echo -e "${GREEN}Build completed successfully!${NC}"
  ) || return 1

  # Find built APK in parent shell so updated builtApk value persists for result()
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
  mkdir -p "$workDir"

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

  # libpybundle.so inner comparison (v2.2.0). The bundle is a gzip-compressed tar
  # (Python bytecode, nested native libs, stdlib). It is never excluded by
  # filename: a differing bundle is lifted from the verdict only when proven
  # acceptable — stage 1: decompressed tar streams byte-identical (gzip wrapper
  # only); stage 2: per-occurrence manifest identical except regular-file
  # 0644->0664 mode fields, plus a raw-block allowlist proving no other tar byte
  # changed. Any other difference, or any comparator failure, stays
  # verdict-affecting (fail closed).
  local pybundleLines pline member safeMember cmpDir evidenceFile stage1 pyOut pyRc noteText
  pybundleLines=$(echo "$nonExcludedDiffs" | grep -E '^Files .*/libpybundle\.so and .*/libpybundle\.so differ$' || true)
  while IFS= read -r pline; do
    [ -z "$pline" ] && continue
    member=${pline#Files /tmp/fromPlay/}
    member=${member%% and *}
    safeMember=$(echo "$member" | tr '/' '_')
    cmpDir="$workDir/pybundle-compare-$safeMember"
    evidenceFile="$workDir/diff_libpybundle_${safeMember}.txt"
    mkdir -p "$cmpDir/out"
    echo "libpybundle.so differs — running inner comparison for $member ..."
    if ! stage1=$($CONTAINER_CMD run --rm \
      --env MEMBER="$member" \
      --volume "${downloadedApk}:/play.apk:ro" \
      --volume "${builtApk}:/built.apk:ro" \
      --volume "$cmpDir":/cmp \
      $wsContainer \
      sh -c 'set -e
        unzip -p /play.apk "$MEMBER" > /cmp/official.so
        unzip -p /built.apk "$MEMBER" > /cmp/built.so
        zcat /cmp/official.so > /cmp/official.tar
        zcat /cmp/built.so > /cmp/built.tar
        if cmp -s /cmp/official.tar /cmp/built.tar; then echo WRAPPER_ONLY; else echo STREAMS_DIFFER; fi
        rm -f /cmp/official.tar /cmp/built.tar' 2>&1); then
      echo -e "${RED}  inner comparison stage 1 failed — $member stays verdict-affecting${NC}"
      echo "$stage1" | tail -3
      {
        echo "libpybundle.so inner comparison ($member):"
        echo "  RESULT: stage 1 (extract/decompress) FAILED - verdict-affecting"
        echo ""
        echo "----- stage 1 output -----"
        echo "$stage1"
      } > "$evidenceFile"
      pybundleSummary+="libpybundle.so inner comparison ($member):
  RESULT:          stage 1 (extract/decompress) FAILED - verdict-affecting
  evidence:        diff_libpybundle_${safeMember}.txt

"
      libpybundleFailNotes+="${member}: inner comparison could not run (stage 1 failure) - treated as verdict-affecting. Evidence: diff_libpybundle_${safeMember}.txt
"
      continue
    fi
    if echo "$stage1" | grep -q '^WRAPPER_ONLY$'; then
      pyOut="  decompressed tar streams: byte-identical
  difference confined to:   gzip container metadata only
  verdict impact:           none"
      pyRc=0
      noteText="${member}: decompressed tar streams byte-identical; difference confined to gzip container metadata."
    else
      if pyOut=$($CONTAINER_CMD run --rm --network none \
        --volume "$cmpDir/official.so":/in/official.so:ro \
        --volume "$cmpDir/built.so":/in/built.so:ro \
        --volume "$cmpDir/out":/out \
        "$PYTHON_IMAGE" \
        python3 -c "$PY_INNER_COMPARE" /in/official.so /in/built.so /out 2>&1); then
        pyRc=0
      else
        pyRc=$?
      fi
      noteText="${member}: inner tar contents byte-identical per occurrence; remaining differences proven confined to accepted regular-file 0644->0664 mode fields."
    fi
    {
      echo "libpybundle.so inner comparison ($member):"
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
    pybundleSummary+="libpybundle.so inner comparison ($member):
$pyOut
  evidence:        diff_libpybundle_${safeMember}.txt

"
    if [ "$pyRc" -eq 0 ]; then
      nonExcludedDiffs=$(echo "$nonExcludedDiffs" | grep -vF "$pline" || true)
      excludedDiffs=$(printf '%s\n%s' "$excludedDiffs" "$pline" | sed '/^$/d')
      libpybundleNotes+="$noteText Evidence: diff_libpybundle_${safeMember}.txt
"
      echo -e "${GREEN}  inner comparison: proven acceptable — lifted from verdict${NC}"
    else
      libpybundleFailNotes+="${member}: inner comparison found verdict-affecting differences (exit $pyRc). Evidence: diff_libpybundle_${safeMember}.txt
"
      echo -e "${RED}  inner comparison: NOT acceptable (exit $pyRc) — stays verdict-affecting${NC}"
    fi
  done <<< "$pybundleLines"

  local diffCount=0
  [ -n "$nonExcludedDiffs" ] && diffCount=$(echo "$nonExcludedDiffs" | wc -l)

  local verdict="reproducible"
  [ "$diffCount" -gt 0 ] && verdict="not_reproducible"

  # Option D: if assets/private.tar is the only non-excluded diff, compare its
  # contents (not mode bits). The ABS host has a default ACL on /opt/build-server-builds/
  # that forces 0664 on all new files, which python-for-android records verbatim into
  # private.tar headers. File contents are identical; only tar entry mode bits differ.
  # Root cause is infrastructure-level (setfacl on ABS host), not a build source issue.
  privateTarNote=""
  if [ "$diffCount" -eq 1 ] && echo "$nonExcludedDiffs" | grep -q "assets/private\.tar"; then
    local tarContentDiff
    tarContentDiff=$($CONTAINER_CMD run --rm \
      --volume "${downloadedApk}:/play.apk:ro" \
      --volume "${builtApk}:/built.apk:ro" \
      $wsContainer \
      sh -c '
        mkdir -p /tmp/fromPlay /tmp/fromBuild /tmp/play-tar /tmp/build-tar
        unzip -d /tmp/fromPlay -qq /play.apk assets/private.tar
        unzip -d /tmp/fromBuild -qq /built.apk assets/private.tar
        tar xf /tmp/fromPlay/assets/private.tar -C /tmp/play-tar
        tar xf /tmp/fromBuild/assets/private.tar -C /tmp/build-tar
        diff --brief --recursive /tmp/play-tar /tmp/build-tar 2>/dev/null || true
      ' 2>&1)
    if [ -z "$tarContentDiff" ]; then
      verdict="reproducible"
      diffCount=0
      nonExcludedDiffs=""
      privateTarNote="assets/private.tar: tar entry mode bits differ (0664 ABS vs 0644 official) but all file contents are identical. Root cause: default ACL on /opt/build-server-builds/ forces group-write inheritance. Infrastructure fix needed (setfacl). GitLab #900."
    fi
  fi

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

  if [ -n "$privateTarNote" ]; then
    echo "Note (private.tar mode-only diff ignored):"
    echo "  $privateTarNote"
    echo ""
  fi

  if [ -n "$pybundleSummary" ]; then
    printf '%s' "$pybundleSummary"
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
    cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ftbfs
notes: |
  Comparison stage failed before completing; see terminal logs.
EOF
  else
    {
      echo "script_version: ${SCRIPT_VERSION}"
      echo "verdict: ${status}"
      echo "notes: |"
      echo "  Root META-INF/* differences (Google Play signing files) are excluded from the verdict."
      if [ -n "$libpybundleNotes" ]; then
        printf '%s' "$libpybundleNotes" | sed 's/^/  Accepted: /'
      fi
      if [ -n "$privateTarNote" ]; then
        echo "  Accepted: $privateTarNote"
      fi
      if [ -n "$libpybundleFailNotes" ]; then
        printf '%s' "$libpybundleFailNotes" | sed 's/^/  Verdict-affecting: /'
      fi
    } > "$RESULTS_FILE"
  fi

  RESULTS_WRITTEN=1
  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
  cp "$RESULTS_FILE" "$LOG_DIR/phase4-results-yaml.log" 2>/dev/null || true
}

# Main execution
mkdir -p "$LOG_DIR"
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
exit 0
