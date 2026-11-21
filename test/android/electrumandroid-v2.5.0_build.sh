#!/bin/bash
# electrumandroid-v2.5.0_build.sh - Electrum Android (org.electrum.electrum) reproducible build verification
# Version:          v2.5.0
# Organization:     WalletScrutiny.com
# Last modified by: Claude Code for Danny
# Last modified on: 2026-11-21
# Project:          https://github.com/spesmilo/electrum
# Scope: one Electrum APK (Google Play or download.electrum.org), one ABI. Version and ABI are read
#        from the APK. The build is upstream's own: contrib/android/Dockerfile, then
#        ./contrib/android/make_apk.sh qml <abi> release-unsigned (buildozer + python-for-android,
#        which runs Gradle). The unpacked APKs are compared; libpybundle.so and assets/private.tar
#        are lifted from the verdict only when an inner tar comparison proves them acceptable.
# Shared steps (engine pick, workspace, traps, YAML, results block, cleanup, Gradle failure check)
# come from the WalletScrutiny library ws-rb-core, pinned by sha256 below (GitLab #1023).
# Offline: WS_LIB_FILE=/path/to/ws-rb-core-1.1.0.sh.
# After the build, ws-buildlock.sh (WS repo, pinned commit + sha256; GitLab #1000) records what
# Gradle fetched in <workspace>/build-lock/build-lock.json. It never changes the verdict.
# Exit codes: 0 reproducible; 1 not reproducible, ftbfs or no verdict;
# 2 invalid parameters or library unavailable; 130 stopped.
# License: MIT. No warranty. For security research only. Use at your own risk.
set -euo pipefail
readonly SCRIPT_VERSION="v2.5.0"
readonly SCRIPT_NAME="electrumandroid-v2.5.0_build.sh"
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH

# ---- Self-identification (first action, before arguments or any network) -----
SCRIPT_SHA256="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1)" || true
SCRIPT_SHA256="${SCRIPT_SHA256:-N/A}"
echo "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
echo "         sha256: ${SCRIPT_SHA256}"
echo

# ---- WalletScrutiny library (GitLab #1023), pinned by sha256 ------------------
# Goes in each build script right after its self-hash line, before anything else.
# Source: WS_LIB_FILE (offline, must match), else the cache, else GitLab by
# commit. Nothing else. A wrong hash is rejected whichever source sent it.
# No matching copy, or a different version inside: no verdict, no YAML, exit 2.
# First, before anything can fail: no earlier verdict may survive this run. A run
# that holds this folder's lock is still writing its own; that one stays, and the
# library refuses this run when it takes the lock.
WS_LIB_DIR0="$(dirname "$(readlink -f "$0")")"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WS_LIB_DIR0/.comparison_results.lock" true 2>/dev/null && rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
else
  WS_LIB_P="$(cat "$WS_LIB_DIR0/.comparison_results.lock.d/pid" 2>/dev/null || true)"
  case "$WS_LIB_P" in ''|*[!0-9]*) WS_LIB_P="";; esac
  { [ -n "$WS_LIB_P" ] && kill -0 "$WS_LIB_P" 2>/dev/null; } || rm -f -- "$WS_LIB_DIR0/COMPARISON_RESULTS.yaml"
fi
WS_LIB=ws-rb-core WS_LIB_VERSION=1.1.0
WS_LIB_REV=3bafe3b5961f11bcf1fa4fbbe3f4f206d53a61d0 WS_LIB_SHA256=4f0920dc8edb1e07aefbb4748d72fd3cc011eb769aaa40de8b5a6a9026312c7e
ws_lib_load() {
  local c f u t=""
  ws_lib_ok() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$WS_LIB_SHA256" ]; }
  if [ -n "${WS_LIB_FILE:-}" ]; then
    f="$WS_LIB_FILE"
    ws_lib_ok "$f" || { echo "[FAIL] WS_LIB_FILE $f is not sha256 $WS_LIB_SHA256: no verdict" >&2; exit 2; }
  else
    # Cache in XDG_CACHE_HOME or HOME; with neither, or no way to create it, a
    # temporary folder for this run only. Every copy is hash-checked either way.
    c="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
    if [ -n "$c" ] && mkdir -p "$c/ws-rb-lib" 2>/dev/null; then c="$c/ws-rb-lib"
    else t="$(mktemp -d 2>/dev/null)" || { echo "[FAIL] no folder to fetch $WS_LIB into: no verdict" >&2; exit 2; }; c="$t"; fi
    f="$c/$WS_LIB_SHA256.sh"
    if ! ws_lib_ok "$f"; then
      u="https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/$WS_LIB_REV/scripts/rb/lib/$WS_LIB-$WS_LIB_VERSION.sh"
      curl -fsSL --max-time 60 -o "$f.$$" "$u" 2>/dev/null && ws_lib_ok "$f.$$" && mv -f "$f.$$" "$f"
      rm -f "$f.$$"
    fi
  fi
  ws_lib_ok "$f" || { [ -z "$t" ] || rm -rf -- "$t"; echo "[FAIL] $WS_LIB $WS_LIB_VERSION ($WS_LIB_SHA256) unavailable or altered: no verdict" >&2; exit 2; }
  # 1.1.0 and later mount this file into the build container (WS_LIB_PATH)
  # and remove a temporary folder on exit; for 1.0.0 it goes now.
  WS_LIB_PATH="$f" WS_LIB_TMP="$t"
  . "$f"
  [ -z "$t" ] || [ -n "${WS_LIB_MOUNT:-}" ] || rm -rf -- "$t"
  [ "${WS_LIB_LOADED_VERSION:-}" = "$WS_LIB_VERSION" ] || { echo "[FAIL] $f holds ${WS_LIB_LOADED_VERSION:-no version}, not $WS_LIB_VERSION: no verdict" >&2; exit 2; }
  echo "Library: $WS_LIB $WS_LIB_VERSION sha256: $WS_LIB_SHA256"
}
ws_lib_load

readonly APP_ID="org.electrum.electrum"
readonly REPO_URL="https://github.com/spesmilo/electrum"
readonly WS_CONTAINER="docker.io/walletscrutiny/android:5"
# The utility image (not removed at exit) hands docker-written files back to the caller.
WS_CHOWN_IMAGE="${WS_CONTAINER}"
# Neutral comparator image for the inner tar comparisons (digest-pinned, multi-arch).
readonly PYTHON_IMAGE="docker.io/library/python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf"
# Build record helper (#1000), pinned by commit and sha256.
readonly BUILDLOCK_REV="6eb3c49f860de9b6fbe152cb0c71dd9a4413a979"
readonly BUILDLOCK_SHA256="fc1d41a45cd1fb455edab9478078c827937761c85966272f4487930f718f8812"

BINARY=""; HINT_VERSION=""; HINT_ARCH=""
WORK_DIR=""; LOG_DIR=""; BUILD_LOG=""; DIFF_FILE=""; IMAGE_NAME=""
OFFICIAL_APK=""; APP_HASH=""; SIGNER=""; VERSION_NAME=""; VERSION_CODE=""; BUILD_ARCH=""
COMMIT=""; BUILT_APK=""; BUILT_HASH=""; BUILD_LOCK_FILE=""
INNER_NOTES=""; INNER_FAIL_NOTES=""; INNER_SUMMARY=""

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

# Every container is named electrum-<run id>-..., so the exit trap stops it if the run ends early.
# Containers started inside $(...) are not in the parent's list; ws_cleanup_hook finds them by name.
CN=0
crun() { local n="electrum-${WS_RUN_ID}-${BASHPID}-$((++CN))"; ws_track_container "$n"; ws_ctr run --rm --name "$n" "$@"; }
# Long steps (checkout, image build, make_apk) run in the background and are waited for, so a
# stop (INT/TERM) reaches the traps at once instead of after the step. Each step gets its own
# process group (set -m around the launch), so the exit hook stops the step and every process it
# started (the engine client included), waits until they are gone, and only then lets the library
# remove containers and images and hand the workspace back. Only this run's group is signalled.
BG_PID=""
bg_wait() {
  local rc=0
  # stdin from /dev/null: a step in its own group must never wait on the terminal.
  set -m; ( trap - ERR; set +e; "$@" ) < /dev/null & BG_PID=$!; set +m
  wait "$BG_PID" || rc=$?
  BG_PID=""
  return "$rc"
}
bg_stop() {
  local p="$BG_PID" i
  [[ -n "$p" ]] || return 0
  kill -TERM -- "-$p" 2>/dev/null || true
  for i in $(seq 1 30); do kill -0 -- "-$p" 2>/dev/null || break; sleep 1; done
  kill -KILL -- "-$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  BG_PID=""
}
ws_cleanup_hook() {
  bg_stop
  [[ -n "$WS_ENGINE" && "$WS_KEEP" != 1 ]] || return 0
  local id
  for id in $(ws_ctr ps -aq --filter "name=electrum-${WS_RUN_ID}-" 2>/dev/null); do
    ws_ctr rm -f "$id" &>/dev/null || true
  done
}

# The source failed to build: write the ftbfs YAML and leave with exit 1.
fail_ftbfs() {
  echo "[FAIL] $1"
  ws_write_yaml ftbfs "$1"
  exit "$WS_EXIT_FAIL"
}

usage() {
  cat <<EOF
NAME
       ${SCRIPT_NAME} - verify an Electrum Android APK against a build from source

SYNOPSIS
       ${SCRIPT_NAME} --binary APK_FILE [--version V] [--arch A] [--type T]

DESCRIPTION
       Builds the tag named by the APK's versionName with upstream's Android build
       (contrib/android/make_apk.sh, release-unsigned) for the APK's ABI, and compares
       the unpacked APKs. Root META-INF signing files are excluded; libpybundle.so and
       assets/private.tar only when an inner tar comparison proves the difference acceptable.

       --binary    the APK to test (a directory holding base.apk is accepted)
       --apk       alias for --binary
       --version, --arch, --type
                   accepted for build server compatibility; values come from the APK
       Unknown parameters are ignored with a warning.

EXIT CODES
       0 reproducible; 1 not reproducible, ftbfs or no verdict; 2 invalid input; 130 stopped

EXAMPLES
       ${SCRIPT_NAME} --binary /path/to/Electrum-4.8.4-arm64-v8a-release.apk
EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary|--apk) ws_require_value "$1" "${2:-}"; BINARY="$2"; shift 2 ;;
      --version) ws_require_value "$1" "${2:-}"; HINT_VERSION="$2"; shift 2 ;;
      --arch)    ws_require_value "$1" "${2:-}"; HINT_ARCH="$2"; shift 2 ;;
      --type)    ws_require_value "$1" "${2:-}"; shift 2 ;;
      --help|-h) trap - EXIT; usage; exit 0 ;;
      *) ws_unknown_arg "$@"; shift "${WS_SHIFT}" ;;
    esac
  done
  [[ -n "$BINARY" ]] || ws_invalid "Provide --binary <apk> (the Electrum APK to test). Run '${SCRIPT_NAME} --help' for usage."
  if [[ -d "$BINARY" && -f "$BINARY/base.apk" ]]; then BINARY="$BINARY/base.apk"; fi
  [[ -f "$BINARY" ]] || ws_invalid "--binary not found: $BINARY"
  OFFICIAL_APK="$(readlink -f "$BINARY")"
}

# Utility container with the official APK's folder mounted read-only at /apk.
apk_run() {
  crun -v "$(dirname "$OFFICIAL_APK"):/apk:ro" "$WS_CONTAINER" sh -c "$1"
}

# Package, version and ABI from the APK; the ABI comes from native-code, else lib/<abi>/.
inspect_apk() {
  local name badging arc=0
  name="$(basename "$OFFICIAL_APK")"
  badging="$(apk_run "/opt/android-sdk/build-tools/29.0.3/aapt dump badging \"/apk/${name}\" 2>/dev/null")" || arc=$?
  # 125-127: engine or tool could not run; 137/143: killed. Not the APK's fault.
  case "$arc" in 125|126|127|137|143) ws_no_verdict "Could not read the APK (container exit ${arc}): engine or host problem." ;; esac
  local pkg line
  line="$(grep -m1 '^package: ' <<< "$badging" || true)"
  pkg="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$line")"
  [[ -n "$pkg" ]] || ws_invalid "Package name unreadable: $name is not a readable APK."
  [[ "$pkg" == "$APP_ID" ]] || ws_invalid "Wrong APK: package is '$pkg', expected '$APP_ID'."
  VERSION_NAME="$(sed -n "s/.* versionName='\([^']*\)'.*/\1/p" <<< "$line")"
  VERSION_CODE="$(sed -n "s/.* versionCode='\([^']*\)'.*/\1/p" <<< "$line")"
  [[ "$VERSION_NAME" =~ ^[0-9A-Za-z._-]+$ ]] || ws_invalid "versionName unreadable from the APK."
  [[ -n "$VERSION_CODE" ]] || ws_invalid "versionCode unreadable from the APK."
  BUILD_ARCH="$(awk -F"'" '/^native-code/ {print $2; exit}' <<< "$badging")"
  if [[ -z "$BUILD_ARCH" ]]; then
    # unzip's own exit is kept (not the pipeline's), so an engine failure is told apart.
    arc=0
    BUILD_ARCH="$(apk_run "unzip -Z1 \"/apk/${name}\" 'lib/*' >/tmp/l 2>/dev/null; r=\$?; cut -d/ -f2 /tmp/l | sort -u | head -1; exit \$r")" || arc=$?
    case "$arc" in 125|126|127|137|143) ws_no_verdict "Could not list the APK's lib/ (container exit ${arc}): engine or host problem." ;; esac
  fi
  [[ "$BUILD_ARCH" =~ ^(arm64-v8a|armeabi-v7a|x86|x86_64)$ ]] || ws_invalid "Cannot tell the APK's ABI (got '${BUILD_ARCH}')."
  [[ -z "$HINT_VERSION" || "$HINT_VERSION" == "$VERSION_NAME" ]] || ws_warn "--version ${HINT_VERSION} ignored: the APK is ${VERSION_NAME}"
  [[ -z "$HINT_ARCH" || "$HINT_ARCH" == "$BUILD_ARCH" ]] || ws_warn "--arch ${HINT_ARCH} ignored: the APK is ${BUILD_ARCH}"
  echo "APK: ${APP_ID} ${VERSION_NAME} (${VERSION_CODE}), ABI ${BUILD_ARCH}"
}

# checkout_worker OUTFILE: clone the tag in a named container (run by bg_wait); prints
# "<commit> <tag object type>" to OUTFILE and exits 10-13 like ws_git_checkout.
checkout_worker() {
  crun $(ws_user_flags) -e HOME=/tmp -v "$WORK_DIR:/w" -w /w --entrypoint sh "$WS_CONTAINER" -c '
      git clone --quiet "$1" app || exit 10
      cd app || exit 13
      git rev-parse --verify --quiet "$2^{commit}" >/dev/null || exit 11
      git -c advice.detachedHead=false checkout --quiet "$2" || exit 13
      git submodule update --quiet --init --recursive || exit 12
      printf "%s " "$(git rev-parse HEAD)"
      git cat-file -t "refs/tags/$2" 2>/dev/null || echo none' sh "$REPO_URL" "$VERSION_NAME" > "$1"
}

prepare() {
  ws_section "PREPARE"
  inspect_apk
  ws_workspace electrum "$VERSION_NAME" "$BUILD_ARCH"
  WORK_DIR="$WS_WORKDIR"
  LOG_DIR="$WORK_DIR/build-logs"; BUILD_LOG="$LOG_DIR/build.log"; DIFF_FILE="$WORK_DIR/diff_full.txt"
  mkdir -p "$LOG_DIR" "$WORK_DIR/gradle-home" "$WORK_DIR/build-lock"
  APP_HASH="$(ws_sha256 "$OFFICIAL_APK")"
  SIGNER="$(apk_run "apksigner verify --print-certs \"/apk/$(basename "$OFFICIAL_APK")\" 2>/dev/null | grep -m1 'Signer #1 certificate SHA-256' | awk '{print \$6}'" || true)"
  echo "appHash: ${APP_HASH}"
  echo "signer:  ${SIGNER:-unknown}"

  # The tag is the versionName as is; a version without a tag is invalid input (exit 2).
  # Same steps and exit mapping as ws_git_checkout, in a named container the exit hook can stop.
  local out="" rc=0 of="$WORK_DIR/.checkout-out"
  bg_wait checkout_worker "$of" || rc=$?
  out="$(cat "$of" 2>/dev/null || true)"
  case "$rc" in
    0) ;;
    10) ws_no_verdict "git clone failed: $REPO_URL" ;;
    11) ws_invalid "No tag ${VERSION_NAME} in $REPO_URL" ;;
    12) ws_no_verdict "Submodule update failed at ${VERSION_NAME}" ;;
    *)  ws_no_verdict "Checkout of ${VERSION_NAME} failed (exit ${rc})" ;;
  esac
  rm -f "$of"
  COMMIT="${out%% *}"
  case "${out##* }" in tag) WS_TAG_TYPE=annotated ;; commit) WS_TAG_TYPE=lightweight ;; *) WS_TAG_TYPE=not-a-tag ;; esac
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || ws_no_verdict "Could not read the commit of ${VERSION_NAME}"
  echo "Checked out ${VERSION_NAME} at ${COMMIT} (${WS_TAG_TYPE})"
  # Upstream builds from a fresh clone: dirs 755, files 644, git's executable bits restored.
  crun --user 0:0 -v "$WORK_DIR/app:/workspace" -w /workspace "$WS_CONTAINER" sh -c "
    git config --global --add safe.directory '*' &&
    find . -type d -exec chmod 755 {} + &&
    find . -type f -exec chmod 644 {} + &&
    git ls-files -s | grep '^100755' | cut -f2 | while IFS= read -r p; do chmod 755 \"\$p\"; done &&
    git submodule foreach --recursive 'git ls-files -s | grep \"^100755\" | cut -f2 | while IFS= read -r p; do chmod 755 \"\$p\"; done'" \
    || ws_no_verdict "Could not normalise the checkout's permissions."
  [[ -f "$WORK_DIR/app/contrib/android/Dockerfile" ]] || fail_ftbfs "Tag ${VERSION_NAME} has no contrib/android/Dockerfile."
}

build() {
  ws_section "BUILD"
  IMAGE_NAME="localhost/electrum-android:$(ws_sanitize "$VERSION_NAME")-$(ws_sanitize "$BUILD_ARCH")-${WS_RUN_ID}"
  echo "Building upstream's image (no cache): ${IMAGE_NAME}"
  ws_track_image "$IMAGE_NAME"
  bg_wait image_build \
    || ws_no_verdict "Image build from contrib/android/Dockerfile failed (base image, apt, pip or SDK download)."

  # GRADLE_USER_HOME points Gradle at a fresh folder of this run (it would otherwise use
  # /root/.gradle inside the container), so ws-buildlock sees exactly what this build fetched.
  # Everything the container prints goes to the terminal and to BUILD_LOG.
  echo "Running make_apk.sh qml ${BUILD_ARCH} release-unsigned (15-30 minutes)"
  # The build and its tee run in a background subshell (so a stop is not held up); their two
  # exit codes come back through a file. No ERR trap in there: the codes are judged below.
  local sf="$LOG_DIR/.build-status" a="" b=""
  rm -f "$sf"
  bg_wait run_build "$sf" || true
  read -r a b 2>/dev/null < "$sf" || true
  [[ "$b" =~ ^[0-9]+$ && "$a" =~ ^[0-9]+$ ]] || ws_no_verdict "The build step left no exit status; its result is unknown."
  [[ "$b" -eq 0 ]] || ws_no_verdict "The build log could not be written (tee exit ${b}); the build's result is unknown."
  local rc="$a"
  if [[ "$rc" -ne 0 ]]; then
    # 125-127: the engine could not start the container; 137/143: killed (memory, stop).
    case "$rc" in
      125|126|127|137|143) ws_no_verdict "Build container failed (exit ${rc}): engine or host problem, not the source." ;;
    esac
    local kind; kind="$(ws_gradle_failure_kind "$BUILD_LOG")"
    case "$kind" in
      source) fail_ftbfs "Build of ${VERSION_NAME} (${BUILD_ARCH}) failed with a compiler or resource error, exit ${rc}. Log: build-logs/build.log." ;;
      infra*) ws_no_verdict "Build failed (exit ${rc}) on a host or network problem: ${kind#infra: }" ;;
      *)      ws_no_verdict "Build failed (exit ${rc}) with no recognised cause; check ${BUILD_LOG}." ;;
    esac
  fi

  BUILT_APK="$WORK_DIR/app/dist/Electrum-${VERSION_NAME}-${BUILD_ARCH}-release-unsigned.apk"
  if [[ ! -f "$BUILT_APK" ]]; then
    BUILT_APK="$(find "$WORK_DIR/app/dist" "$WORK_DIR/app/.buildozer/android/platform/build-${BUILD_ARCH}/dists" \
      -type f -name "*${BUILD_ARCH}*release*.apk" 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$BUILT_APK" && -f "$BUILT_APK" ]] || ws_no_verdict "make_apk.sh succeeded but no ${BUILD_ARCH} release APK was found under dist/ or .buildozer/."
  BUILT_HASH="$(ws_sha256 "$BUILT_APK")"
  ws_ok "Built APK: ${BUILT_APK} (sha256 ${BUILT_HASH})"
}

# image_build: upstream's Dockerfile, no cache; output to the terminal and build-logs/image-build.log
# (a pipe, so the engine never drives the terminal). Fails if the build or the log write fails.
image_build() {
  set -o pipefail
  ws_ctr build --pull --no-cache --build-arg UID=1000 \
    -t "$IMAGE_NAME" -f "$WORK_DIR/app/contrib/android/Dockerfile" "$WORK_DIR/app" 2>&1 | tee "$LOG_DIR/image-build.log"
}

# run_build STATUSFILE: upstream's make_apk.sh in the image, output to the terminal and BUILD_LOG.
# Writes "<container exit> <tee exit>" to STATUSFILE.
run_build() {
  trap - ERR; set +e
  crun --user 0:0 \
    -e GIT_PAGER=cat -e PAGER=cat -e VIRTUAL_ENV=/opt/venv \
    -e PATH="/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e BUILDOZER_WARN_ON_ROOT=0 -e GRADLE_USER_HOME=/home/user/.gradle \
    -v "$WORK_DIR/app:/home/user/wspace/electrum" \
    -v "$WORK_DIR/gradle-home:/home/user/.gradle" \
    -w /home/user/wspace/electrum \
    "$IMAGE_NAME" bash -lc "umask 0022 && set -x && \
      source /opt/venv/bin/activate && \
      git config --global --add safe.directory '*' && \
      mkdir -p dist && \
      ./contrib/android/make_apk.sh qml '${BUILD_ARCH}' release-unsigned" 2>&1 | tee "$BUILD_LOG"
  echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}" > "$1"
}

# Build record (#1000): the Gradle module cache this build filled and the checkout's committed
# binaries. Read-only on both; never changes the build output or the verdict.
build_lock() {
  ws_section "BUILD RECORD"
  local f="$WORK_DIR/ws-buildlock.sh" rc=0
  if ! curl -fsSL --max-time 60 -o "$f" \
      "https://gitlab.com/walletscrutiny/walletScrutinyCom/-/raw/${BUILDLOCK_REV}/scripts/rb/ws-buildlock.sh" < /dev/null \
     || [[ "$(ws_sha256 "$f")" != "$BUILDLOCK_SHA256" ]]; then
    ws_warn "build-lock skipped: could not fetch ws-buildlock.sh with the expected sha256"
    return 0
  fi
  crun -e HOME=/tmp -v "$f:/ws-buildlock.sh:ro" -v "$WORK_DIR/gradle-home:/gh:ro" \
    -v "$WORK_DIR/app:/src:ro" -v "$WORK_DIR/build-lock:/out" "$WS_CONTAINER" bash -c '
      git config --global --add safe.directory "*"
      bash /ws-buildlock.sh --out /out --gradle-home /gh --src /src \
        --app-id "$1" --version "$2" --platform android --commit "$3"' sh "$APP_ID" "$VERSION_NAME" "$COMMIT" || rc=$?
  if [[ "$rc" -eq 0 && -f "$WORK_DIR/build-lock/build-lock.json" ]]; then
    BUILD_LOCK_FILE="$WORK_DIR/build-lock/build-lock.json"
    ws_ok "build-lock.json: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
  else
    ws_warn "No build-lock.json produced (exit ${rc}); the verdict is unaffected."
  fi
}

# One APK member that differs: libpybundle.so or assets/private.tar. Lifted from the verdict only
# when proven acceptable: stage 1, uncompressed tar streams byte-identical (compression wrapper
# only); stage 2, per-occurrence manifest identical except regular-file group-write mode fields
# (0644->0664, 0755->0775), with a raw-block allowlist proving no other tar byte changed. Any
# other difference, or any comparator failure, stays verdict-affecting (fail closed).
# Group-write modes appear when the build directory is group-writable, e.g. the ABS default ACL
# on /opt/build-server-builds/ (GitLab #900), which overrides the build's umask 0022.
# Returns 0 when proven acceptable, 1 otherwise; appends to INNER_*.
inner_compare() {
  local member="$1" label safe dir ev evname stage1 out prc=0 note
  label="$(basename "$member")"; safe="${member//\//_}"
  dir="$WORK_DIR/inner-compare-$safe"; evname="diff_inner_${safe}.txt"; ev="$WORK_DIR/$evname"
  mkdir -p "$dir/out"
  echo "$label differs: inner comparison for $member"
  if ! stage1="$(crun -e MEMBER="$member" -v "${OFFICIAL_APK}:/play.apk:ro" -v "${BUILT_APK}:/built.apk:ro" \
      -v "$dir:/cmp" "$WS_CONTAINER" sh -c 'set -e
        unzip -p /play.apk "$MEMBER" > /cmp/official.bin
        unzip -p /built.apk "$MEMBER" > /cmp/built.bin
        case "$MEMBER" in
          *.tar) cp /cmp/official.bin /cmp/official.tar; cp /cmp/built.bin /cmp/built.tar ;;
          *) zcat /cmp/official.bin > /cmp/official.tar; zcat /cmp/built.bin > /cmp/built.tar ;;
        esac
        if cmp -s /cmp/official.tar /cmp/built.tar; then echo WRAPPER_ONLY; else echo STREAMS_DIFFER; fi
        rm -f /cmp/official.tar /cmp/built.tar' 2>&1)"; then
    # Kept fail-closed as in v2.4.0: an archive that cannot be extracted counts as a difference.
    printf '%s inner comparison (%s):\n  RESULT: stage 1 (extract/decompress) FAILED - verdict-affecting\n\n----- stage 1 output -----\n%s\n' \
      "$label" "$member" "$stage1" > "$ev"
    INNER_SUMMARY+="$label inner comparison ($member):"$'\n'"  RESULT:          stage 1 FAILED - verdict-affecting"$'\n'"  evidence:        $evname"$'\n\n'
    INNER_FAIL_NOTES+="${member}: inner comparison could not run (stage 1 failure); treated as verdict-affecting. Evidence: $evname"$'\n'
    echo "  stage 1 failed: $member stays verdict-affecting"
    return 1
  fi
  if grep -q '^WRAPPER_ONLY$' <<< "$stage1"; then
    out="  uncompressed tar streams: byte-identical"$'\n'"  difference confined to:   compression container metadata only"$'\n'"  verdict impact:           none"
    note="${member}: uncompressed tar streams byte-identical; difference confined to compression container metadata."
  else
    out="$(crun --network none -v "$dir/official.bin:/in/official.bin:ro" -v "$dir/built.bin:/in/built.bin:ro" \
      -v "$dir/out:/out" "$PYTHON_IMAGE" python3 -c "$PY_INNER_COMPARE" /in/official.bin /in/built.bin /out 2>&1)" || prc=$?
    note="${member}: inner tar contents byte-identical per occurrence; remaining differences proven confined to accepted regular-file group-write mode fields (0644->0664, 0755->0775)."
  fi
  {
    echo "$label inner comparison ($member):"
    echo "$out"
    echo
    if [[ -f "$dir/out/inner-report.txt" ]]; then echo "----- full inner report -----"; cat "$dir/out/inner-report.txt"; fi
    if [[ -f "$dir/out/manifest-official.jsonl" ]]; then
      printf '\nManifests (JSON Lines, archive order) and full diff:\n  %s\n  %s\n  %s\n' \
        "$dir/out/manifest-official.jsonl" "$dir/out/manifest-built.jsonl" "$dir/out/manifest-diff.txt"
    fi
  } > "$ev"
  INNER_SUMMARY+="$label inner comparison ($member):"$'\n'"$out"$'\n'"  evidence:        $evname"$'\n\n'
  if [[ "$prc" -eq 0 ]]; then
    INNER_NOTES+="$note Evidence: $evname"$'\n'
    ws_ok "inner comparison: proven acceptable, lifted from the verdict"
    return 0
  fi
  if [[ "$prc" -eq 1 ]]; then
    INNER_FAIL_NOTES+="${member}: inner comparison found verdict-affecting differences. Evidence: $evname"$'\n'
  else
    INNER_FAIL_NOTES+="${member}: inner comparator error (exit $prc); kept as verdict-affecting (fail-closed), not proven different. Evidence: $evname"$'\n'
  fi
  ws_warn "inner comparison: NOT acceptable (exit $prc), stays verdict-affecting"
  return 1
}

compare_and_result() {
  ws_section "COMPARISON"
  local all excluded counted line member verdict n=0 diff_text rc
  # Unzip and diff inside a container with its own /tmp: no extraction dirs on the host.
  # diff exits 0 (same) or 1 (differences); anything else is an error, never "no differences".
  local cerr="$WORK_DIR/compare-stderr.txt" crc=0
  all="$(crun -v "${OFFICIAL_APK}:/play.apk:ro" -v "${BUILT_APK}:/built.apk:ro" "$WS_CONTAINER" sh -c '
      mkdir -p /tmp/fromPlay /tmp/fromBuild || exit 3
      unzip -d /tmp/fromPlay -qq /play.apk || exit 4
      unzip -d /tmp/fromBuild -qq /built.apk || exit 4
      diff --brief --recursive /tmp/fromPlay /tmp/fromBuild; r=$?
      [ "$r" -le 1 ] || exit 5' 2>"$cerr")" || crc=$?
  [[ "$crc" -eq 0 ]] || ws_no_verdict "The comparison container failed (exit ${crc}: 3 setup, 4 unzip, 5 diff error); see $cerr."
  printf '%s\n' "$all" > "$DIFF_FILE"

  # Root-level META-INF signing files only (Leo's guideline): MANIFEST.MF, *.SF, *.RSA, *.DSA,
  # *.EC directly in META-INF/. Other META-INF files, and a whole one-sided META-INF directory,
  # are counted.
  local sig='(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))'
  local meta="^Only in /tmp/from(Play|Build)/META-INF: ${sig}\$|^Files /tmp/fromPlay/META-INF/${sig} and /tmp/fromBuild/META-INF/${sig} differ\$"
  excluded="$(grep -E "$meta" <<< "$all" || true)"
  counted="$(grep -vE "${meta}|^\$" <<< "$all" || true)"
  while IFS= read -r line; do
    [[ "$line" =~ ^Files\ /tmp/fromPlay/((.+/)?libpybundle\.so|assets/private\.tar)\ and\ .*\ differ$ ]] || continue
    member="${BASH_REMATCH[1]}"
    if inner_compare "$member"; then
      counted="$(grep -vxF "$line" <<< "$counted" || true)"
      excluded="$(printf '%s\n%s' "$excluded" "$line" | sed '/^$/d')"
    fi
  done <<< "$counted"

  [[ -z "$counted" ]] || n="$(wc -l <<< "$counted")"
  if [[ "$n" -eq 0 ]]; then verdict=reproducible; rc="$WS_EXIT_OK"; else verdict=not_reproducible; rc="$WS_EXIT_FAIL"; fi

  local notes="Excluded from the verdict: only the signing files directly in META-INF/ (MANIFEST.MF, *.SF, *.RSA, *.DSA, *.EC). Other META-INF entries, and a META-INF folder present on one side only, count as differences."
  [[ -z "$INNER_NOTES" ]] || notes+=$'\n'"$(sed 's/^/Accepted: /' <<< "${INNER_NOTES%$'\n'}")"
  [[ -z "$INNER_FAIL_NOTES" ]] || notes+=$'\n'"$(sed 's/^/Verdict-affecting: /' <<< "${INNER_FAIL_NOTES%$'\n'}")"
  ws_write_yaml "$verdict" "$notes"

  diff_text="$(
    if [[ -n "$excluded" ]]; then
      echo "Excluded from verdict (root META-INF signing files / proven-acceptable inner diffs):"
      sed -n '1,5{s|/tmp/fromPlay/||; s|/tmp/fromBuild/||; p}' <<< "$excluded"
      local k; k="$(wc -l <<< "$excluded")"
      [[ "$k" -le 5 ]] || echo "  ... ($((k - 5)) more, see $DIFF_FILE)"
      echo
    fi
    [[ -z "$INNER_SUMMARY" ]] || printf '%s' "$INNER_SUMMARY"
    echo "Diff (not excluded, at most 5 lines; full diff: $DIFF_FILE):"
    if [[ -n "$counted" ]]; then
      sed -n '1,5p' <<< "$counted"
      [[ "$n" -le 5 ]] || echo "  ... ($((n - 5)) more lines, see $DIFF_FILE)"
    else
      echo "(no differences)"
    fi
    echo
    echo "Differences found (root META-INF and proven-acceptable diffs excluded): $n"
  )"
  echo
  ws_results_block "$APP_ID" "${SIGNER:-N/A}" "$VERSION_NAME" "$VERSION_CODE" "$verdict" "$APP_HASH" "$COMMIT" "$diff_text"
  echo
  echo "builtHash:      ${BUILT_HASH} (unsigned build; appHash is the official APK as supplied)"
  echo "architecture:   ${BUILD_ARCH}"
  echo "tag:            ${VERSION_NAME} (${WS_TAG_TYPE})"
  echo "Build log:      ${BUILD_LOG}"
  echo "Workspace:      ${WORK_DIR}"
  if [[ -n "$BUILD_LOCK_FILE" ]]; then
    echo "Upload with the verification: ${BUILD_LOCK_FILE} (sha256 $(ws_sha256 "$BUILD_LOCK_FILE"))"
  fi
  exit "$rc"
}

main() {
  ws_warn "This script is provided as-is. Review before running. Use at your own risk."
  ws_refuse_root
  ws_install_traps
  parse_arguments "$@"
  ws_results_init        # one run per script folder; stale COMPARISON_RESULTS.yaml removed
  ws_engine
  prepare
  build
  build_lock
  compare_and_result
}
main "$@"
