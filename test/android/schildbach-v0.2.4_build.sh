#!/usr/bin/env bash
# schildbach-v0.2.4_build.sh - reproducible-build check of Bitcoin Wallet APKs
# Version: v0.2.4
# Organization: WalletScrutiny.com
# Last modified by: Claude Code for Danny (from Carol's v0.2.0)
# Last modified on: 2026-10-14
# Project: https://gitlab.com/bitcoin-wallet/bitcoin-wallet
# App ID: de.schildbach.wallet
# License: MIT
#
# Steps: read the supplied APK(s) (or, with --version only, download the
# developer-signed APK that F-Droid hosts), identify the source by signer,
# clone the matching release tag, build the tag's own build.Containerfile
# build-stage unmodified, export Mainnet, compare each supplied APK entry by
# entry, and write COMPARISON_RESULTS.yaml beside this script.
# Host requirements: Bash, standard Unix utilities, and Podman or Docker.
# Android tools, Python, Git, and downloads run inside containers. No smartphone.
# Upstream (AGP 3.1.4) builds standalone APKs only, no AAB. Real split APKs
# produce ftbfs and are never compared against a standalone APK.
# Signature files unique to the official APK are allowlisted by basename.
# The build is then aligned like F-Droid's recipe (reproducible-apk-tools v0.3.0
# zipalign.py --page-size 4 --pad-like-apksigner --replace) and the official
# signature copied onto it (apksigcopier); it must
# verify and reproduce the official sha256, which also covers ZIP metadata.
# META-INF/MANIFEST.MF is accepted only if its main section equals the built
# manifest and every digest entry matches the built entry's bytes.
# resources.arsc differences require identical decoded res/ trees.
# All other payload differences remain counted. Full evidence stays on disk.
# Technical disclaimer: build verification only; no security audit or warranty.
# Legal disclaimer: use only where authorized and lawful.
# Exit codes: 0 matching payloads; 1 build failure/differences; 2 invalid input.

set -Eeuo pipefail
readonly SCRIPT_VERSION=v0.2.4
readonly APP_ID=de.schildbach.wallet
readonly TOOLS_BASE=docker.io/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
readonly REPRO_APK_COMMIT=dc069dc4cddf6ab5162f3ed3be1bc8a14711273f
readonly REPRO_APK_ZIPALIGN_SHA256=a47596d10395e099176c7b6624f1392c7f579e888310b0552ae25fe86c2565c9
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
SCRIPT_SHA256="$(sha256sum -- "$SCRIPT_PATH" 2>/dev/null || true)"
SCRIPT_SHA256="${SCRIPT_SHA256%% *}"
[[ "$SCRIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] || SCRIPT_SHA256=N/A
printf '%s %s sha256:%s\n' "${SCRIPT_PATH##*/}" "$SCRIPT_VERSION" "$SCRIPT_SHA256"
rm -f -- "$SCRIPT_DIR/COMPARISON_RESULTS.yaml"

WORK_DIR= RUNTIME= BINARY= VERSION= ARCH= SORT_MODE=auto CHILD=
VERDICT=ftbfs NOTE='Run did not finish.' SOURCE=unknown
COMMIT=unknown SIGNER=unknown APK_VERSION=unknown APK_CODE=unknown APP_HASH=unknown
RUN_ID="$(date +%s)-$$"
PREFIX="schildbach-$RUN_ID"
TOOLS_IMAGE="$PREFIX-tools"
BUILD_IMAGE="$PREFIX-build"
ROOTLESS=false
USER_ARGS=()
log() { printf '[INFO] %s\n' "$*"; }
fail() { NOTE="$2"; printf '[ERROR] %s\n' "$NOTE" >&2; exit "$1"; }
usage() {
    cat <<'USAGE'
Usage: schildbach-v0.2.4_build.sh --binary APK_OR_DIRECTORY [--version X.0|X.YY]
       schildbach-v0.2.4_build.sh --version X.0|X.YY
  --binary PATH    Supplied official APK or directory containing APKs.
  --apk PATH       Alias for --binary. Filenames need not identify versions.
  --version X.YY   Upstream style: 11.0, 11.01 ... 11.04. With --binary: consistency check. Alone: download the
                   developer-signed APK F-Droid hosts (else F-Droid's own).
  --arch VALUE     Checked against lib/ ABIs; Mainnet ships no native code.
  --type VALUE     Accepted for ABS; this script targets Mainnet release.
  --disorderfs auto|on|off
                   auto: sort directories with rootless Podman if /dev/fuse exists.
                   on: require rootless Podman/FUSE; off: upstream CI's unsorted build.
  --help           Show this help.
APK source is identified by signer: developer key 58dcd8a0... or F-Droid key
bcb4b936...; any other signer is compared but reported as unrecognized.
Evidence is retained in a unique directory beneath the caller's directory.
USAGE
}
need_value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail 2 "Missing value for $1."; }
# Long steps run as a waited background child so INT/TERM act at once.
run_logged() {
    local logfile="$1"; shift
    "$@" > >(tee -a "$logfile") 2>&1 &
    CHILD=$!
    wait "$CHILD"
    CHILD=
}

# EXIT covers failed builds and invalid inputs as well as successful comparisons.
# Restore ownership only within this run's workspace, then remove its images.
finish() {
    local status=$? owner temp note_line
    trap - EXIT ERR INT TERM
    set +e
    if [[ -n "$CHILD" ]]; then kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; fi
    if [[ -n "$WORK_DIR" && -n "$RUNTIME" ]]; then
        for suffix in fetch metadata source read-export export compare; do
            "$RUNTIME" rm -f "$PREFIX-$suffix" >/dev/null 2>&1
        done
        owner="$(id -u):$(id -g)"
        [[ "$ROOTLESS" == true ]] && owner=0:0
        if "$RUNTIME" image inspect "$TOOLS_IMAGE" >/dev/null 2>&1; then
            if ! "$RUNTIME" run --rm --user 0:0 --network none \
                --volume "$WORK_DIR:/work:rw" "$TOOLS_IMAGE" chown -R "$owner" /work; then
                printf '[WARNING] Workspace ownership restoration failed: %s\n' "$WORK_DIR" >&2
                status=1
            fi
        fi
        "$RUNTIME" image rm "$BUILD_IMAGE" "$TOOLS_IMAGE" >/dev/null 2>&1
    fi
    [[ "$status" -eq 0 || "$VERDICT" != reproducible ]] || VERDICT=ftbfs
    temp="$SCRIPT_DIR/.schildbach-results-$RUN_ID.tmp"
    {
        printf 'script_version: %s\nverdict: %s\nnotes: |\n' "$SCRIPT_VERSION" "$VERDICT"
        while IFS= read -r note_line; do printf '  %s\n' "$note_line"; done <<< "$NOTE"
        printf '  APK source: %s\n' "$SOURCE"
        if [[ -n "$WORK_DIR" && -f "$WORK_DIR/artifact-results.txt" ]]; then
            while IFS= read -r note_line; do printf '  %s\n' "$note_line"; done < "$WORK_DIR/artifact-results.txt"
        fi
    } > "$temp"
    if ! mv -f -- "$temp" "$SCRIPT_DIR/COMPARISON_RESULTS.yaml"; then
        printf '[ERROR] Cannot write COMPARISON_RESULTS.yaml beside script.\n' >&2
        status=1
    fi
    printf '\n===== Begin Results =====\n'
    printf 'appId:           %s\nsigner:          %s\n' "$APP_ID" "$SIGNER"
    printf 'apkVersionName:  %s\napkVersionCode:  %s\n' "$APK_VERSION" "$APK_CODE"
    printf 'verdict:         %s\nappHash:         %s\n' "$VERDICT" "$APP_HASH"
    printf 'commit:          %s\nscriptVersion:   %s\n' "$COMMIT" "$SCRIPT_VERSION"
    printf 'scriptHash:      %s\n===== End Results =====\n' "$SCRIPT_SHA256"
    printf 'APK source: %s\n' "$SOURCE"
    [[ -z "$WORK_DIR" ]] || printf 'Evidence: %s\n' "$WORK_DIR"
    # ABS publishes exit 1 only with a reportable YAML verdict; 2 is invalid input.
    [[ "$status" -eq 0 || "$status" -eq 2 ]] || status=1
    exit "$status"
}
trap finish EXIT
trap '[[ "$NOTE" == *"(Failure at"* ]] || NOTE="$NOTE (Failure at script line $LINENO.)"' ERR
trap 'NOTE="Interrupted."; exit 1' INT
trap 'NOTE="Terminated."; exit 1' TERM

while (($#)); do
    case "$1" in
        --binary|--apk) need_value "$@"; BINARY="$2"; shift 2 ;;
        --version) need_value "$@"; VERSION="${2#v}"; shift 2 ;;
        --arch) need_value "$@"; ARCH="$2"; shift 2 ;;
        --type) need_value "$@"; log "--type is accepted; using upstream Mainnet release."; shift 2 ;;
        --disorderfs) need_value "$@"; SORT_MODE="$2"; shift 2 ;;
        --help) usage; trap - EXIT; exit 0 ;;
        *) printf '[WARNING] Unknown argument ignored: %s\n' "$1" >&2; shift ;;
    esac
done
[[ "$SORT_MODE" =~ ^(auto|on|off)$ ]] || fail 2 'Invalid --disorderfs value.'
[[ -z "$VERSION" || "$VERSION" =~ ^[0-9]+\.(0|[0-9]{2})$ ]] || fail 2 'Invalid version format (expected X.0 or X.YY, e.g. 11.0, 11.04).'
[[ -n "$BINARY" || -n "$VERSION" ]] || fail 2 'Supply --binary (official APK or directory) or --version.'
[[ "$EUID" -ne 0 ]] || fail 2 'Run as a regular user, without sudo.'
if [[ -n "$BINARY" ]]; then
    [[ -f "$BINARY" || -d "$BINARY" ]] || fail 2 'The supplied binary path does not exist.'
    BINARY="$(readlink -f -- "$BINARY")"
    [[ "$BINARY" != *$'\n'* && "$BINARY" != *:* ]] || fail 2 'Input paths cannot contain newlines or colons.'
fi
# A runtime must actually work (`info` answers), podman first.
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then RUNTIME=podman
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then RUNTIME=docker
else fail 2 'No working Podman or Docker (podman info and docker info both failed).'; fi
if [[ "$RUNTIME" == podman ]]; then
    ROOTLESS="$(podman info --format '{{.Host.Security.Rootless}}')"
    USER_ARGS=(--userns=keep-id --user "$(id -u):$(id -g)")
else
    security="$(docker info --format '{{json .SecurityOptions}}')"
    [[ "$security" != *rootless* ]] || ROOTLESS=true
    if [[ "$ROOTLESS" == true ]]; then USER_ARGS=(--user 0:0)
    else USER_ARGS=(--user "$(id -u):$(id -g)"); fi
fi
WORK_DIR="$(pwd -P)/schildbach_verification_${VERSION:-auto}_$RUN_ID"
[[ "$WORK_DIR" != *:* && "$WORK_DIR" != *$'\n'* ]] || fail 2 'Working path contains unsupported characters.'
mkdir -- "$WORK_DIR"
mkdir -- "$WORK_DIR/tools" "$WORK_DIR/official" "$WORK_DIR/download" "$WORK_DIR/output" "$WORK_DIR/comparison"
log "Workspace: $WORK_DIR"

# Package installation is container-only. The analysis image base is pinned;
# the source build uses the selected tag's unmodified upstream Containerfile.
cat > "$WORK_DIR/tools/Dockerfile" <<EOF
FROM $TOOLS_BASE
RUN apt-get update && apt-get install -y --no-install-recommends \\
    ca-certificates git python3 aapt apksigcopier apksigner apktool diffutils unzip \\
    && rm -rf /var/lib/apt/lists/*
# F-Droid's recipe postbuild aligns with this tool; pinned by commit and file hash.
RUN git clone --quiet --branch v0.3.0 https://github.com/obfusk/reproducible-apk-tools.git /opt/repro-apk \\
    && test "\$(git -C /opt/repro-apk rev-parse HEAD)" = $REPRO_APK_COMMIT \\
    && echo "$REPRO_APK_ZIPALIGN_SHA256  /opt/repro-apk/zipalign.py" | sha256sum -c -
ENV LANG=C.UTF-8
EOF
NOTE='Could not build the metadata/comparison tools image.'
log 'Preparing container tools for package validation and comparison.'
run_logged "$WORK_DIR/tools-build.log" "$RUNTIME" build --platform linux/amd64 --tag "$TOOLS_IMAGE" "$WORK_DIR/tools"

# Embedded Python stays inside the tools container; the host needs no Python.
cat > "$WORK_DIR/worker.py" <<'PY'
import base64, hashlib, json, os, pathlib, re, shutil, subprocess, sys, urllib.request, zipfile
W = pathlib.Path('/work')
APP = 'de.schildbach.wallet'
DEV = '58dcd8a0edf2a590683ba022d22a8dca5659aabf4728741a5c07af738d53db38'
FDROID = 'bcb4b93636bb10c7ddaf61aa9604ff795dfdb05fad4d9412b335682f0b612e32'
SOURCES = {DEV: 'developer-signed (upstream release key; F-Droid hosts it as _58dcd8a.apk)',
           FDROID: 'F-Droid-signed (built and signed by F-Droid)'}
SIGNING = re.compile(r'META-INF/[^/]+\.(?:SF|RSA|DSA|EC)')

def run(args, **kw):
    return subprocess.run(args, check=True, text=True, **kw)

def output(args):
    return run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''): h.update(b)
    return h.hexdigest()

def fetch(version):
    major, minor = version.split('.')
    code = str(int(major) * 10000 + int(minor) * 100)  # 11.0 -> 110000, 11.04 -> 110400
    for name in (f'{APP}_{code}_58dcd8a.apk', f'{APP}_{code}.apk'):
        url = 'https://f-droid.org/repo/' + name
        try:
            with urllib.request.urlopen(url, timeout=120) as r, open(W / 'download' / name, 'wb') as f:
                shutil.copyfileobj(r, f)
        except OSError as e:
            print(f'Not available: {url} ({e})')
            (W / 'download' / name).unlink(missing_ok=True)
            continue
        print('Downloaded', url)
        (W / 'download.name').write_text(name + '\n')
        return
    raise ValueError(f'No official APK for {version} found on f-droid.org; supply --binary.')

def metadata(p):
    badging = output(['aapt', 'dump', 'badging', str(p)])
    package_line = next((x for x in badging.splitlines() if x.startswith('package: ')), '')
    fields = dict(re.findall(r"(\w+)='([^']*)'", package_line))
    if fields.get('name') != APP:
        raise ValueError(f'Wrong package in {p.name}: {fields.get("name")!r}; expected {APP}.')
    if not fields.get('versionCode', '').isdigit():
        raise ValueError(f'Missing versionCode in {p.name}.')
    tree = output(['aapt', 'dump', 'xmltree', str(p), 'AndroidManifest.xml'])
    # Config splits have split=; base splits and bundletool universal APKs carry
    # distribution metadata. Upstream never produces either form.
    split = bool(fields.get('split')) or any(x in tree for x in (
        'com.android.vending.splits', 'com.android.dynamic.apk.fused.modules',
        'isSplitRequired', 'E: uses-split'))
    signer_text = output(['apksigner', 'verify', '--print-certs', str(p)])
    signers = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$', signer_text, re.M)
    if not signers: raise ValueError(f'No verified signer in {p.name}.')
    with zipfile.ZipFile(p) as z:
        abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/') and n.count('/') >= 2})
    signer = ','.join(sorted(x.lower() for x in signers))
    return {'name': p.name, 'version': fields.get('versionName', ''),
            'code': fields['versionCode'], 'split': split, 'abis': abis, 'signer': signer,
            'source': SOURCES.get(signer, 'unrecognized signer ' + signer), 'hash': sha(p)}

def prepare(selected, requested, arch):
    src = pathlib.Path('/input')
    paths = [src / selected] if selected else sorted(src.glob('*.apk'))
    if not paths: raise ValueError('Input directory contains no .apk files.')
    items = []
    for n, p in enumerate(paths):
        if not p.is_file(): raise ValueError(f'Not a regular APK: {p.name}')
        if any(ord(c) < 32 for c in p.name): raise ValueError('Control character in filename.')
        # Snapshot selected bytes before inspection. Never modify supplied files.
        dest = W / 'official' / f'{n:04}.apk'
        shutil.copyfile(p, dest)
        item = metadata(dest)
        item.update(name=p.name, path=str(dest))
        items.append(item)
    codes = {x['code'] for x in items}
    signers = {x['signer'] for x in items}
    if len(codes) != 1 or len(signers) != 1:
        raise ValueError('Submitted APKs mix versions or signers.')
    versions = {x['version'] for x in items if x['version']}
    if len(versions) != 1: raise ValueError('Submitted APKs lack one consistent versionName.')
    version = versions.pop()
    if not re.fullmatch(r'\d+\.(0|\d{2})', version):
        raise ValueError('Unsupported version name: ' + version)
    if requested and version != requested: raise ValueError('--version disagrees with APK metadata.')
    abis = sorted({a for x in items for a in x['abis']})
    if arch and abis and arch not in abis:
        raise ValueError(f'--arch {arch} does not match APK ABIs {abis}.')
    first = items[0]
    info = {'version': version, 'code': first['code'], 'signer': first['signer'],
            'source': first['source'], 'hash': first['hash'],
            'has_splits': any(x['split'] for x in items), 'items': items}
    (W / 'metadata.json').write_text(json.dumps(info, indent=2) + '\n')
    (W / 'metadata.fields').write_text('\n'.join([version, first['code'], first['signer'],
        first['hash'], str(info['has_splits']), first['source']]) + '\n')
    for x in items: print(f"Official {x['name']}: sha256 {x['hash']} split={x['split']} ABIs={x['abis'] or 'none'}")
    print('APK source:', first['source'])

def checkout():
    info = json.loads((W / 'metadata.json').read_text())
    tag = 'v' + info['version']
    run(['git', 'clone', '--depth', '1', '--branch', tag,
         'https://gitlab.com/bitcoin-wallet/bitcoin-wallet.git', str(W / 'source')])
    source = W / 'source'
    commit = output(['git', '-C', str(source), 'rev-parse', 'HEAD']).strip()
    tag_commit = output(['git', '-C', str(source), 'rev-parse', f'refs/tags/{tag}^{{commit}}']).strip()
    if commit != tag_commit: raise ValueError('Checkout does not match the requested release tag.')
    (W / 'commit.txt').write_text(commit + '\n')
    recipe = source / 'build.Containerfile'
    if not recipe.is_file() or 'AS build-stage' not in recipe.read_text():
        raise ValueError('Release lacks the supported upstream build-stage recipe.')
    manifest = (source / 'wallet/AndroidManifest.xml').read_text()
    for key, expected in [('versionName', info['version']), ('versionCode', info['code'])]:
        match = re.search(r'android:' + key + r'="([^"]+)"', manifest)
        if not match or match[1] != expected:
            raise ValueError('Release source ' + key + ' disagrees with the official APK.')
    print('Source commit:', commit)
    print('Upstream Containerfile sha256:', sha(recipe))
    print('Building the release Containerfile without source patches.')

def apk_entries(p):
    with zipfile.ZipFile(p) as z:
        names = [x.filename for x in z.infolist() if not x.is_dir()]
        if len(names) != len(set(names)): raise ValueError('Duplicate ZIP entry in ' + str(p))
        return {name: z.read(name) for name in names}

def manifest_sections(data):
    text = data.decode('utf-8').replace('\r\n', '\n')
    sections, current = [], []
    for line in text.split('\n'):
        if line.startswith(' ') and current: current[-1] += line[1:]
        elif line: current.append(line)
        elif current: sections.append(current); current = []
    if current: sections.append(current)
    return [dict(x.split(': ', 1) for x in s) for s in sections]

def v1_manifest_matches(a, b, folder):
    # Official v1 manifest = built main section + one digest per built entry.
    off, built = manifest_sections(a['META-INF/MANIFEST.MF']), manifest_sections(b['META-INF/MANIFEST.MF'])
    report = []
    if len(built) != 1 or not off or off[0] != built[0]:
        report.append('main section differs from the built manifest')
    listed = {}
    for s in off[1:]:
        name = s.get('Name')
        if name is None or name in listed: report.append('malformed or duplicate entry: ' + repr(s)); continue
        listed[name] = s
    expected = {n for n in b if n != 'META-INF/MANIFEST.MF' and not SIGNING.fullmatch(n)}
    for name in sorted(expected - set(listed)): report.append('built entry not in official manifest: ' + name)
    for name in sorted(set(listed) - expected): report.append('official manifest lists unknown entry: ' + name)
    for name in sorted(expected & set(listed)):
        s = listed[name]
        algos = [(k, v) for k, v in s.items() if k in ('SHA-256-Digest', 'SHA1-Digest')]
        if not algos: report.append('no digest for ' + name)
        for k, v in algos:
            h = hashlib.sha256 if k.startswith('SHA-256') else hashlib.sha1
            if base64.b64encode(h(b[name]).digest()).decode() != v: report.append('digest mismatch: ' + name)
    (folder / 'manifest_check.txt').write_text(''.join(x + '\n' for x in report) or
        f'OK: main section identical; {len(listed)} digests match built entries.\n')
    return not report

def tree_hashes(p):
    return {str(x.relative_to(p)): sha(x) for x in sorted(p.rglob('*')) if x.is_file()}

def decoded_resources_match(off, built, folder):
    for label, apk in [('official', off), ('built', built)]:
        dest = folder / (label + '-decoded')
        with open(folder / (label + '-apktool.log'), 'w') as log:
            proc = subprocess.run(['apktool', 'd', '-f', '--no-src', '--no-debug-info',
                '--frame-path', '/tmp/apktool-framework', '-o', str(dest), str(apk)],
                stdout=log, stderr=subprocess.STDOUT)
        if proc.returncode:
            print('Resource decoding failed; resources.arsc remains counted.')
            return False
    left = folder / 'official-decoded/res'
    right = folder / 'built-decoded/res'
    if not left.is_dir() or not right.is_dir(): return False
    with open(folder / 'diff_resources_decoded.txt', 'w') as log:
        proc = subprocess.run(['diff', '-ru', str(left), str(right)], stdout=log, stderr=subprocess.STDOUT)
    if proc.returncode not in (0, 1): raise ValueError('Decoded resources comparison failed.')
    return proc.returncode == 0 and tree_hashes(left) == tree_hashes(right)

def compare():
    info = json.loads((W / 'metadata.json').read_text())
    candidates = []
    for p in (W / 'output').rglob('*.apk'):
        fields = output(['aapt', 'dump', 'badging', str(p)])
        line = next((x for x in fields.splitlines() if x.startswith('package: ')), '')
        attrs = dict(re.findall(r"(\w+)='([^']*)'", line))
        if attrs.get('name') == APP: candidates.append((p, attrs))
    if len(candidates) != 1: raise ValueError('Expected exactly one rebuilt Mainnet APK.')
    built, fields = candidates[0]
    if fields.get('versionName') != info['version'] or fields.get('versionCode') != info['code']:
        raise ValueError('Built APK metadata does not match the supplied APK.')
    if fields.get('split'): raise ValueError('Unexpected split APK build output.')
    b = apk_entries(built)
    print('Built APK:', built.name, 'sha256', sha(built))
    summaries, failed = [], False
    for n, item in enumerate(info['items']):
        off = pathlib.Path(item['path'])
        folder = W / 'comparison' / f'{n:04}'
        folder.mkdir()
        a = apk_entries(off)
        raw, remaining, excluded = [], [], []
        for name in sorted(set(a) | set(b)):
            if a.get(name) == b.get(name): continue
            label = 'built-only' if name not in a else 'official-only' if name not in b else 'differs'
            line = f'{label}: {name}'
            raw.append(line)
            if SIGNING.fullmatch(name) and name not in b:
                excluded.append(line + ' [official signature file]')
            elif name == 'META-INF/MANIFEST.MF' and name in b and v1_manifest_matches(a, b, folder):
                excluded.append(line + ' [v1 manifest: built main section + matching digests]')
            elif name == 'resources.arsc' and name in a and name in b and decoded_resources_match(off, built, folder):
                excluded.append(line + ' [decoded res/ trees identical]')
            else: remaining.append(line)
        # Align as F-Droid's recipe postbuild does, then copy the official signature onto the build:
        # only identical ZIP bytes verify and match the hash.
        aligned, signed = folder / 'aligned.apk', folder / 'signature-copied.apk'
        try:
            run(['python3', '/opt/repro-apk/zipalign.py', '--page-size', '4', '--pad-like-apksigner', '--replace',
                 str(built), str(aligned)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            run(['apksigcopier', 'copy', str(off), str(aligned), str(signed)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            run(['apksigner', 'verify', str(signed)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            copied = sha(signed)
        except subprocess.CalledProcessError as e:
            copied = None
            (folder / 'signature-copy-error.txt').write_text(e.stdout or '')
        if copied == item['hash']:
            print(f'Signature copy: verifies; sha256 {copied} = official')
        else:
            line = f'signature copy: {"failed to verify" if copied is None else "sha256 " + copied + " != official"}'
            raw.append(line)
            remaining.append(line)
            print('Signature copy:', line.split(': ', 1)[1])
        for name, lines in [('diff_full.txt', raw), ('diff_remaining.txt', remaining), ('exclusions.txt', excluded)]:
            (folder / name).write_text(''.join(x + '\n' for x in lines))
        verdict = 'not_reproducible' if remaining else 'reproducible'
        failed |= bool(remaining)
        summary = f"{item['name']}: {verdict}; sha256 {item['hash']}; raw={len(raw)}, excluded={len(excluded)}, remaining={len(remaining)}"
        summaries.append(summary)
        print(summary)
        print('Raw diff preview (maximum five lines):')
        for line in raw[:5]: print('  ' + line)
        for line in excluded: print('  excluded ' + line)
        print('Full evidence:', folder)
    (W / 'artifact-results.txt').write_text('\n'.join(summaries) + '\n')
    (W / 'verdict.txt').write_text('not_reproducible\n' if failed else 'reproducible\n')

try:
    op = sys.argv[1]
    if op == 'fetch': fetch(sys.argv[2])
    elif op == 'prepare': prepare(sys.argv[2], sys.argv[3], sys.argv[4])
    elif op == 'source': checkout()
    elif op == 'compare': compare()
    else: raise ValueError('Unknown worker operation.')
except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile, UnicodeDecodeError) as e:
    print('ERROR:', e, file=sys.stderr)
    sys.exit(2 if op == 'prepare' else 1)
PY

# Without --binary, fetch the official APK inside the container.
if [[ -z "$BINARY" ]]; then
    NOTE="Could not download an official APK for $VERSION."
    log "No --binary; downloading the official $VERSION APK from f-droid.org."
    run_logged "$WORK_DIR/download.log" "$RUNTIME" run --rm --name "$PREFIX-fetch" --platform linux/amd64 \
        "${USER_ARGS[@]}" -e HOME=/tmp --volume "$WORK_DIR:/work:rw" \
        "$TOOLS_IMAGE" python3 /work/worker.py fetch "$VERSION"
    IFS= read -r name < "$WORK_DIR/download.name"
    BINARY="$WORK_DIR/download/$name"
fi
if [[ -d "$BINARY" ]]; then INPUT_DIR="$BINARY"; SELECTED=
else INPUT_DIR="${BINARY%/*}"; SELECTED="${BINARY##*/}"; fi
NOTE='Invalid APK metadata, package, signature, ABI, or inconsistent input set.'
log 'Validating submitted APKs before building application source.'
if "$RUNTIME" run --rm --name "$PREFIX-metadata" --platform linux/amd64 \
    "${USER_ARGS[@]}" --network none -e HOME=/tmp \
    --volume "$INPUT_DIR:/input:ro" --volume "$WORK_DIR:/work:rw" \
    "$TOOLS_IMAGE" python3 /work/worker.py prepare "$SELECTED" "$VERSION" "$ARCH"; then :
else code=$?; [[ "$code" -eq 2 ]] && exit 2; exit 1; fi
mapfile -t metadata_fields < "$WORK_DIR/metadata.fields"
APK_VERSION="${metadata_fields[0]}"; APK_CODE="${metadata_fields[1]}"
SIGNER="${metadata_fields[2]}"; APP_HASH="${metadata_fields[3]}"; SOURCE="${metadata_fields[5]}"
log 'appHash identifies the selected APK, or the first directory APK.'
[[ "${metadata_fields[4]}" != True ]] || fail 1 \
    'Split or universal APKs cannot be rebuilt by the upstream AGP 3.1.4 recipe. No split was compared against a standalone APK.'

NOTE='Unable to fetch or validate the matching upstream release tag.'
log "Cloning release v$APK_VERSION inside the container."
run_logged "$WORK_DIR/source.log" "$RUNTIME" run --rm --name "$PREFIX-source" --platform linux/amd64 \
    "${USER_ARGS[@]}" -e HOME=/tmp --volume "$WORK_DIR:/work:rw" \
    "$TOOLS_IMAGE" python3 /work/worker.py source
IFS= read -r COMMIT < "$WORK_DIR/commit.txt"

# Upstream's build-stage installs its own JDK/Gradle/SDK inside its image.
# disorderfs needs FUSE + SYS_ADMIN in the build. Only under rootless Podman,
# where those capabilities stay inside the caller's user namespace; otherwise
# the documented unsorted path (as upstream CI).
BUILD_ARGS=()
SORT_NOTE='Directory sorting disabled, matching upstream CI. F-Droid uses disorderfs; ordering differences may remain.'
if [[ "$SORT_MODE" != off && "$RUNTIME" == podman && "$ROOTLESS" == true && -c /dev/fuse ]]; then
    BUILD_ARGS=(--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined)
    SORT_NOTE='Directory entries sorted with upstream disorderfs.'
elif [[ "$SORT_MODE" == on ]]; then
    fail 2 '--disorderfs on requires rootless Podman and an accessible /dev/fuse device.'
fi
log "$SORT_NOTE"
NOTE='Upstream container build failed; inspect upstream-build.log.'
log "Building the selected tag's own build-stage without source patches."
run_logged "$WORK_DIR/upstream-build.log" "$RUNTIME" build --platform linux/amd64 "${BUILD_ARGS[@]}" \
    --tag "$BUILD_IMAGE" --target build-stage --file "$WORK_DIR/source/build.Containerfile" "$WORK_DIR/source"

# The image's builder UID can differ from the caller. Read its private home
# as container root without a host mount; extract through caller mapping.
NOTE='Unable to export upstream APK build outputs.'
"$RUNTIME" run --rm --name "$PREFIX-read-export" --platform linux/amd64 \
    --user 0:0 --network none --entrypoint /bin/tar "$BUILD_IMAGE" \
    -C /home/builder/project/wallet/build/outputs/apk -cf - . |
    "$RUNTIME" run --rm -i --name "$PREFIX-export" --platform linux/amd64 \
        "${USER_ARGS[@]}" --network none --volume "$WORK_DIR/output:/output:rw" \
        "$TOOLS_IMAGE" tar --no-same-owner --no-same-permissions -xf - -C /output
NOTE='APK comparison failed; no complete result is available.'
log 'Comparing APK payloads, the v1 manifest, differing resource tables, and a signature copy.'
run_logged "$WORK_DIR/comparison.log" "$RUNTIME" run --rm --name "$PREFIX-compare" --platform linux/amd64 \
    "${USER_ARGS[@]}" --network none -e HOME=/tmp --volume "$WORK_DIR:/work:rw" \
    "$TOOLS_IMAGE" python3 /work/worker.py compare
IFS= read -r VERDICT < "$WORK_DIR/verdict.txt"
[[ "$VERDICT" == reproducible || "$VERDICT" == not_reproducible ]] || fail 1 'Invalid worker verdict.'
NOTE="Compared only submitted APKs against upstream Mainnet release at $COMMIT.
Official-only root META-INF signing files are allowlisted; no directory-wide exclusion.
META-INF/MANIFEST.MF is accepted only when its main section equals the built manifest
and every digest entry matches the built entry bytes.
resources.arsc is accepted only when decoded res/ trees match.
The build was aligned as in F-Droid's recipe (reproducible-apk-tools v0.3.0 zipalign.py)
and the official signature copied onto it (apksigcopier); it must verify and give the official sha256.
$SORT_NOTE
Upstream base tags and apt repositories remain unpinned, as in its Containerfile."
[[ "$VERDICT" == reproducible ]] && exit 0
exit 1
