#!/usr/bin/env bash
# TEMPORARY diagnostic script — Bull Bitcoin Mobile v6.13.0, GitHub fat-APK mode.
# NOT a WalletScrutiny verification script. Not for the build server. Not in
# ~/work/scripts. The canonical WS verdict for this app is the Google Play
# split set, which is still on 6.12.2 and cannot be verified from this run.
#
# What it does: builds v6.13.0 through UPSTREAM'S OWN documented path
# (`make android release FORMAT=apk`, the same target CI and their
# reproducibility/verify_build.sh call), then compares the result against the
# official GitHub release artifact using OUR OWN comparison, not theirs.
#
# Purpose (two questions):
#   Q1  does our from-source build match their published unsigned APK hash?
#   Q2  do libapp.so / libdartjni.so still differ — the FVM-install-path
#       hypothesis we have carried unproven since v6.10.1?
SCRIPT_VERSION="v0.1.0-tmp"
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO="${REPO:-$HOME/builds/android/com.bullbitcoin.mobile/v6.13.0-repro}"
TAG="v6.13.0"
OFFICIAL_APK="$SCRIPT_DIR/bullbitcoin-6.13.0+214.apk"
EXPECTED_SIGNED="33791c805cf4ffc15bf73c96de709ecf651224bea88f5df3c2ff5a0bf3d0ef8f"
EXPECTED_UNSIGNED="56ad3c6dabf80465c4a2628a61216a02ba6fe797741c82cefca6c07e98cfec0f"
CONTAINER="${CONTAINER:-podman}"
GRADLE_HEAP="${GRADLE_HEAP:-4g}"
BUILT_APK="$REPO/BULL-release.apk"
RESULTS="$SCRIPT_DIR/RESULTS-6.13.0.txt"

say() { echo; echo "=============================================================="; echo "$*"; echo "=============================================================="; }

# Convention: the script identifies itself before doing anything, so a reader
# of the log knows exactly which bytes produced the result below.
say "Bull Bitcoin v6.13.0 temporary diagnostic — ${SCRIPT_VERSION}"
echo "script:     $SCRIPT_PATH"
echo "scriptHash: $(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
echo "started:    $(date -Is)"

say "PHASE 1/5 — preflight"
cd "$REPO"
head_commit="$(git rev-parse HEAD)"
tag_commit="$(git rev-parse "${TAG}^{commit}")"
[ "$head_commit" = "$tag_commit" ] || { echo "FAIL: HEAD $head_commit != $TAG $tag_commit"; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "FAIL: working tree is dirty — would build modified sources"; exit 2; }
echo "repo:       $REPO"
echo "HEAD:       $head_commit ($TAG, clean)"
[ -f "$OFFICIAL_APK" ] || { echo "FAIL: official APK missing: $OFFICIAL_APK"; exit 2; }
official_hash="$(sha256sum "$OFFICIAL_APK" | awk '{print $1}')"
[ "$official_hash" = "$EXPECTED_SIGNED" ] || { echo "FAIL: official APK hash mismatch"; exit 2; }
echo "official:   $official_hash (matches published HASHSUMS256)"
echo "container:  $($CONTAINER --version)"
echo "heap:       $GRADLE_HEAP"
free -g | awk '/^Mem:/ {print "memory:     " $7 "GB available / " $2 "GB total"}'
df -h --output=avail "$REPO" | tail -1 | awk '{print "disk:       " $1 " available"}'

say "PHASE 2/5 — build from source via upstream's own make target"
echo "Command: GRADLE_HEAP=$GRADLE_HEAP FORMAT=apk CONTAINER=$CONTAINER make android release"
echo "This builds bull-tools + bull-app images, then runs flutter build apk."
echo "Expect a long run (image build pulls Flutter, Android SDK/NDK, Rust)."
rm -f "$BUILT_APK"
build_start=$(date +%s)
GRADLE_HEAP="$GRADLE_HEAP" FORMAT=apk CONTAINER="$CONTAINER" make android release
build_end=$(date +%s)
echo "build wall time: $(( (build_end - build_start) / 60 )) minutes"
[ -f "$BUILT_APK" ] || { echo "FAIL: expected output missing: $BUILT_APK"; exit 1; }

say "PHASE 3/5 — Q1: hash equality against upstream's published unsigned APK"
built_hash="$(sha256sum "$BUILT_APK" | awk '{print $1}')"
echo "built (unsigned):     $built_hash"
echo "upstream published:   $EXPECTED_UNSIGNED"
if [ "$built_hash" = "$EXPECTED_UNSIGNED" ]; then
  echo "RESULT: MATCH — byte-for-byte identical to upstream's published unsigned APK."
  hash_verdict="MATCH"
else
  echo "RESULT: MISMATCH — differs from upstream's published unsigned APK."
  hash_verdict="MISMATCH"
fi

say "PHASE 4/5 — entry-by-entry comparison vs the official signed APK"
echo "Only legacy JAR signature files are excluded (the official APK is signed,"
echo "this build deliberately is not). Everything else is compared."
set +e
python3 "$SCRIPT_DIR/compare_entries.py" "$OFFICIAL_APK" "$BUILT_APK" | tee "$SCRIPT_DIR/entry_diff.txt"
entry_rc=${PIPESTATUS[0]}
set -e
echo "entry comparison exit code: $entry_rc"

say "PHASE 5/5 — Q2: native library detail (rustc pins + the Dart engine libs)"
rm -rf "$SCRIPT_DIR/built-libs"
unzip -q -o "$BUILT_APK" 'lib/arm64-v8a/*' -d "$SCRIPT_DIR/built-libs"
printf '%-34s %-22s %-22s %s\n' "LIBRARY" "OFFICIAL sha256(12)" "BUILT sha256(12)" "MATCH / rustc"
for so in "$SCRIPT_DIR/apk-libs/lib/arm64-v8a/"*.so; do
  name="$(basename "$so")"
  mine="$SCRIPT_DIR/built-libs/lib/arm64-v8a/$name"
  if [ ! -f "$mine" ]; then
    printf '%-34s %-22s %-22s %s\n' "$name" "$(sha256sum "$so" | cut -c1-12)" "-" "ABSENT-IN-BUILD"
    continue
  fi
  oh="$(sha256sum "$so"   | awk '{print $1}')"
  bh="$(sha256sum "$mine" | awk '{print $1}')"
  rustc_o="$(strings -n 8 "$so"   | grep -m1 -oE 'rustc version [0-9.]+' | awk '{print $3}')"
  rustc_b="$(strings -n 8 "$mine" | grep -m1 -oE 'rustc version [0-9.]+' | awk '{print $3}')"
  if [ "$oh" = "$bh" ]; then flag="SAME"; else flag="DIFFER"; fi
  [ -n "${rustc_o:-}${rustc_b:-}" ] && flag="$flag  rustc ${rustc_o:--}/${rustc_b:--}"
  printf '%-34s %-22s %-22s %s\n' "$name" "$(echo "$oh" | cut -c1-12)" "$(echo "$bh" | cut -c1-12)" "$flag"
done

say "SUMMARY"
{
  echo "Bull Bitcoin Mobile v6.13.0 — temporary GitHub fat-APK diagnostic"
  echo "run:            $(date -Is)"
  echo "script:         $(basename "$SCRIPT_PATH") $SCRIPT_VERSION"
  echo "scriptHash:     $(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
  echo "commit built:   $head_commit ($TAG)"
  echo "official APK:   $official_hash"
  echo "built APK:      $built_hash"
  echo "upstream unsigned target: $EXPECTED_UNSIGNED"
  echo "Q1 hash equality vs published unsigned APK: $hash_verdict"
  echo "Q2 entry comparison exit code (0 = identical): $entry_rc"
  echo "artifacts:      $SCRIPT_DIR/{entry_diff.txt,build.log}"
  echo "NOTE: this is NOT the WalletScrutiny verdict. Canonical = Play split set (still 6.12.2)."
} | tee "$RESULTS"
