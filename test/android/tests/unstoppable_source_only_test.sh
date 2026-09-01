#!/usr/bin/env bash
# Regression checks for unstoppablewallet_build.sh v0.5.0 source-only workflow.

set -uo pipefail
SCRIPT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/unstoppablewallet_build.sh}"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { grep -qE "$1" "$SCRIPT"; }
lacks() { ! grep -qE "$1" "$SCRIPT"; }

[[ -f "$SCRIPT" ]] || { echo "Missing script: $SCRIPT"; exit 2; }

has '^SCRIPT_VERSION="v0\.5\.0"$' && ok "version is v0.5.0" || bad "wrong version"
size=$(wc -c < "$SCRIPT")
[[ "$size" -le 48235 ]] && ok "size $size <= 48235" || bad "size $size exceeds 48235"

has 'SCRIPT_PATH="\$\(readlink -f "\$0"\)"' \
    && has 'sha256:%s' \
    && has '^echo "scriptVersion:  \$\{SCRIPT_VERSION\}"$' \
    && has '^echo "scriptHash:     \$\{SCRIPT_SHA256\}"$' \
    && ok "script self-identifies by version and runtime SHA-256" \
    || bad "script self-identification is incomplete"

has '"platforms;android-37\.0"' \
    && has 'Compile SDK \$\{compile_sdk\} present:' \
    && ok "Android Platform 37 is installed and compileSdk is preflighted" \
    || bad "Android Platform 37 support/preflight missing"

has 'device-sdk' && has '-e "WS_DEVICE_SDK=\$\{DEVICE_SDK\}"' \
    && ok "device SDK is explicit and propagated into bundletool generation" \
    || bad "device SDK is not propagated to the source-build container"

has 'THORCHAIN_VER=\$\(extract_wallet_hs_version "thorchain-kit-android"' \
    && has 'clone_at_commit "\$GH/thorchain-kit-android\.git"' \
    && has ':thorchainkit:publishToMavenLocal' \
    && has "artifactId = 'thorchain-kit-android'" \
    && ok "v0.50.x thorchain-kit is cloned and published locally" \
    || bad "thorchain-kit source-build path missing"

has "thorchainkit/build\.gradle" && has 'mavenLocal\(\)' \
    && has 'hd-wallet-kit-android:' \
    && ok "thorchain-kit resolves the locally published HD wallet kit" \
    || bad "thorchain-kit can fall back to JitPack for HD wallet kit"

grep -qF '/^Signer( #[0-9]+| \(minSdkVersion=[^)]*\)) certificate SHA-256 digest:/' "$SCRIPT" \
    && grep -qF 'excluding SourceStamp' "$SCRIPT" \
    && ok "signer extraction supports rotated SDK-range certificates and excludes SourceStamp" \
    || bad "signer extraction still assumes only legacy Signer #1 output"

lacks 'IMG_P2|CTR_P2|P2_DIR|P4_DIR|jitpack_outage|jitpack-aars|PHASE 4|DEP ARTIFACT EVIDENCE' \
    && ok "JitPack baseline and artifact comparison removed" \
    || bad "obsolete baseline/comparison code remains"

builds=$(grep -cF '$CRUN build -t "$IMG_P3"' "$SCRIPT")
[[ "$builds" -eq 1 ]] && ok "one shared source-build image" || bad "expected one image build, got $builds"

metadata_block=$(sed -n '/banner "PHASE 0:/,/^fi$/p' "$SCRIPT")
grep -q '"$IMG_P3"' <<<"$metadata_block" \
    && ok "metadata extraction reuses source-build image" \
    || bad "metadata extraction does not use source-build image"

has 'if \[\[ "\$HS_LOCAL" -eq 0 \|\| "\$HS_JITPACK" -gt 0 \]\]' \
    && ok "dependency guard requires local HS packages and zero JitPack fallback" \
    || bad "dependency source guard missing or weak"

has 'MISSING official=.*built=' && has 'P5_VERDICT="not_reproducible"' \
    && ok "missing split remains not_reproducible" \
    || bad "missing-split verdict guard missing"

has 'stamp-cert-sha256' && has 'diff_non_metainf_count' \
    && ok "comparison still excludes SourceStamp and judges non-signature diffs" \
    || bad "split comparison safeguards missing"

for kit in stellarkit zanokit monerokit; do
    has "grep -qF \"maven-publish\" $kit/build\.gradle \\|\\| sed -i" \
        && ok "$kit maven-publish insertion is guarded" \
        || bad "$kit maven-publish insertion can duplicate the plugin"

    has "grep -qF \"release\\(MavenPublication\\)\" $kit/build\.gradle" \
        && ok "$kit publication append is guarded" \
        || bad "$kit appends a publication without checking for an existing one"
done

for kit in zanokit monerokit; do
    has "grep -qF \"singleVariant\\('release'\\)\" $kit/build\.gradle \\|\\| sed -i" \
        && ok "$kit declares the AGP release-variant publishing opt-in" \
        || bad "$kit missing singleVariant opt-in (AGP 8.11.1 has no components.release without it)"
done

for pair in "stellar-kit-android:STELLAR_VER" "zano-kit-android:ZANO_VER" "monero-kit-android:MONERO_VER"; do
    art="${pair%%:*}"; var="${pair##*:}"
    has "artifactId = '$art'/\{n;s/version = '\[\^'\]\*'/version = '\\\$$var'" \
        && ok "$art version rewrite targets the publication's own version line" \
        || bad "$art version rewrite missing or not anchored to artifactId"

    has "grep -qF \"version = '\\\$$var'\" .*build\.gradle \\|\\|" \
        && ok "$art version rewrite is asserted before publishing" \
        || bad "$art can publish under the wrong version without failing"
done

has 'ADD https://github.com/iBotPeaches/Apktool/releases/download/v3\.0\.3/apktool_3\.0\.3\.jar /opt/apktool\.jar' \
    && ok "apktool is installed in the build image at a pinned version" \
    || bad "apktool missing or unpinned — decode cannot run"

has 'dec=1' && has '\$APKTOOL d -f --no-src --no-debug-info "\$o" -o /tmp/do >/dev/null 2>&1 \|\| dec=0' \
    && ok "decode failure is detected" \
    || bad "decode failure not detected — an empty diff could read as identical"

has '\[\[ "\$dec" -eq 1 \]\] && printf .* grep -q .resources' \
    && has '\[\[ "\$dec" -eq 1 \]\] && printf .* grep -q .AndroidManifest' \
    && ok "no classification is attempted without a verified decode" \
    || bad "classification can run on a failed decode"

has 'diff_resources_decoded_\$\{cfg\}\.txt' && has 'diff_manifest_\$\{cfg\}\.txt' \
    && ok "full decoded diffs are written per config" \
    || bad "decoded diffs not persisted per config"

hd=$(grep -c 'head -5' "$SCRIPT")
[[ "$hd" -ge 2 ]] && ok "terminal preview capped at 5 diff lines ($hd sites)" \
    || bad "diff preview not capped (found $hd sites)"

has 'sole decoded changes are Google Play distribution metadata .* acceptable' \
    && ok "manifest classifier accepts the narrow Google Play metadata set" \
    || bad "Google Play manifest metadata acceptance missing"

for key in 'com\.android\.vending\.derived\.apk\.id' 'com\.android\.stamp\.source' 'com\.android\.stamp\.type'; do
    grep -qF "$key" "$SCRIPT" && ok "manifest allowlist contains $key" || bad "manifest allowlist missing $key"
done

has 'issues/574' && ok "acceptable-diffs policy issue 574 is cited in output" \
    || bad "WS #574 not referenced"

has 'material_count=\$\(\(diff_non_metainf_count - accepted_count\)\)' \
    && has '"\$material_count" -eq 0' \
    && ok "verdict is judged on material (non-acceptable) diffs" \
    || bad "verdict does not account for acceptable diffs"

has 'files compared: ' && has 'native \$st \$rel' \
    && ok "per-split file counts and native-library hash pairs are printed" \
    || bad "positive comparison evidence missing"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 - "$SCRIPT" "$tmp" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
specs = [
    ("meta.sh", r"<<'META_SCRIPT'\n(.*?)\nMETA_SCRIPT\n"),
    ("build.sh", r"<<'BUILD_SCRIPT_END'\n(.*?)\nBUILD_SCRIPT_END\n"),
    ("compare.sh", r"<<'P5_SPLIT_END'\n(.*?)\nP5_SPLIT_END\n"),
]
for name, pattern in specs:
    match = re.search(pattern, src, re.S)
    if not match:
        raise SystemExit(f"missing heredoc: {name}")
    body = match.group(1).replace("__WALLET_VERSION__", "0.50.1")
    (out / name).write_text(body)
PY

for inner in meta.sh build.sh compare.sh; do
    if bash -n "$tmp/$inner"; then ok "$inner syntax"; else bad "$inner syntax"; fi
done

sed -n '/^generate_yaml()/,/^}/p' "$SCRIPT" > "$tmp/generate_yaml.sh"
(
    SCRIPT_VERSION="v0.5.0"
    execution_dir="$tmp"
    log_info() { :; }
    source "$tmp/generate_yaml.sh"
    generate_yaml reproducible "source-only test"
)
keys=$(sed -n 's/^\([a-z_]*\):.*/\1/p' "$tmp/COMPARISON_RESULTS.yaml" | tr '\n' ' ')
[[ "$keys" == "script_version verdict notes " ]] \
    && ok "YAML contains only script_version, verdict, notes" \
    || bad "unexpected YAML keys: $keys"

# Behavioural: run the LIVE resources.arsc classifier against fixtures. A text-grep would pass
# against a broken classifier — the v0.3.4 bug-#3 lesson.
python3 - "$SCRIPT" "$tmp" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next(i for i, l in enumerate(src) if l.strip().startswith('ch=$(printf'))
anchor = next(i for i, l in enumerate(src) if i > start and 'head -5' in l)
end = next(i for i, l in enumerate(src) if i > anchor and l.strip() == 'fi')
body = "\n".join(src[start:end + 1])
pathlib.Path(sys.argv[2], "classify.sh").write_text(body + "\n")
PY

classify() {
    # NOT $( ) — the classifier increments acc, and a subshell would discard it.
    local rd="$1" acc=0 cfg=t
    source "$tmp/classify.sh" > "$tmp/classify.out" 2>&1
    printf '%s|%s' "$acc" "$(cat "$tmp/classify.out")"
}

res=$(classify "")
[[ "${res%%|*}" == "1" && "${res#*|}" == *"IDENTICAL"* ]] \
    && ok "classifier: empty decoded diff => acceptable" \
    || bad "classifier: empty decoded diff mishandled ($res)"

res=$(classify "$(printf '2c2\n< com.google.firebase.crashlytics.mapping_file_id=abc\n> com.google.firebase.crashlytics.mapping_file_id=def')")
[[ "${res%%|*}" == "1" && "${res#*|}" == *"crashlytics"* ]] \
    && ok "classifier: crashlytics-only change => acceptable" \
    || bad "classifier: crashlytics-only change mishandled ($res)"

res=$(classify "$(printf '2c2\n< android:label="Wallet"\n> android:label="Evil"')")
[[ "${res%%|*}" == "0" && "${res#*|}" == *"DIFFERS"* ]] \
    && ok "classifier: genuine resource change => NOT acceptable" \
    || bad "classifier: genuine resource change wrongly accepted ($res)"

res=$(classify "$(printf '2c2\n< com.google.firebase.crashlytics.mapping_file_id=abc\n> com.google.firebase.crashlytics.mapping_file_id=def\n5c5\n< android:label="Wallet"\n> android:label="Evil"')")
[[ "${res%%|*}" == "0" && "${res#*|}" == *"DIFFERS"* ]] \
    && ok "classifier: crashlytics PLUS a real change => NOT acceptable" \
    || bad "classifier: real change hidden behind crashlytics line ($res)"

# Behavioural: execute the live decoded-manifest classifier. It must accept the exact
# Google Play metadata shape from the 0.49.4 run and reject that shape plus any real change.
sed -n '/^classify_manifest_diff()/,/^}/p' "$tmp/compare.sh" > "$tmp/classify_manifest.sh"
classify_manifest() {
    local md="$1" acc=0 cfg=t
    source "$tmp/classify_manifest.sh" > /dev/null
    classify_manifest_diff "$md" t > "$tmp/classify_manifest.out" 2>&1
    printf '%s|%s' "$acc" "$(cat "$tmp/classify_manifest.out")"
}

play_md=$(printf '%s\n' \
    '--- official' '+++ built' \
    '-    <application android:extractNativeLibs="true" android:hasCode="false">' \
    '-        <meta-data android:name="com.android.vending.derived.apk.id" android:value="4"/>' \
    '-    </application>' \
    '+    <application android:extractNativeLibs="true" android:hasCode="false"/>')
res=$(classify_manifest "$play_md")
[[ "${res%%|*}" == "1" && "${res#*|}" == *"Google Play"* ]] \
    && ok "manifest classifier: Google Play-only metadata => acceptable" \
    || bad "manifest classifier: Google Play-only metadata mishandled ($res)"

play_base_md=$(printf '%s\n' \
    '--- official' '+++ built' \
    '-        <meta-data android:name="com.android.stamp.source" android:value="https://play.google.com/store"/>' \
    '-        <meta-data android:name="com.android.stamp.type" android:value="STAMP_TYPE_DISTRIBUTION_APK"/>' \
    '-        <meta-data android:name="com.android.vending.derived.apk.id" android:value="4"/>')
res=$(classify_manifest "$play_base_md")
[[ "${res%%|*}" == "1" && "${res#*|}" == *"Google Play"* ]] \
    && ok "manifest classifier: all three observed Google Play metadata names => acceptable" \
    || bad "manifest classifier: observed base-manifest metadata mishandled ($res)"

mixed_md=$(printf '%s\n' "$play_md" \
    '-    <uses-permission android:name="android.permission.CAMERA"/>' \
    '+    <uses-permission android:name="android.permission.RECORD_AUDIO"/>')
res=$(classify_manifest "$mixed_md")
[[ "${res%%|*}" == "0" && "${res#*|}" == *"DIFFERS"* ]] \
    && ok "manifest classifier: Google Play metadata PLUS real change => NOT acceptable" \
    || bad "manifest classifier: real manifest change wrongly accepted ($res)"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
