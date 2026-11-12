#!/bin/bash
# ==============================================================================
# stackwalletdesktop-v0.3.1_build.sh - Stack Wallet Desktop (Linux) Reproducible Build
# ==============================================================================
# Version:       v0.3.1
# Organization:  WalletScrutiny.com
# Project:       https://github.com/cypherstack/stack_wallet
# Last modified by: Carol (Buzz), Claude Code for Danny
# Last modified on: 2026-11-12
# ==============================================================================
# TECHNICAL DISCLAIMER: Provided for security research and reproducible build
# verification only. No warranty. Users assume all risks.
# LEGAL DISCLAIMER: For legitimate security research. Users are responsible for
# legal compliance. By using this script, you acknowledge these disclaimers.
#
# SCRIPT SUMMARY:
# 1. Takes the official sw-v<ver>-linux.AppImage or sw-v<ver>-linux.flatpak
#    (--binary), or downloads it from the GitHub release (--version).
# 2. Unpacks it in a container and reads version and build number from the
#    bundle's version.json; the source tag is build_<build number>.
# 3. Builds the Linux bundle in a container that mimics the maintainer's
#    workstation the official libraries were built on: Ubuntu 24.04,
#    HOME=/home/diego, source at /home/diego/Desktop/releases/stack_wallet,
#    Flutter 3.47.7 (engine hash in the official libflutter_linux_gtk.so),
#    Go 1.24.4 (official libmwebd.so), Rust 1.89.0/1.90.0/1.94.1 (pinned by
#    each plugin's rust-toolchain.toml), upstream build_app.sh without -d/-s.
# 4. Compares every file of the bundle (lib/, data/, stack_wallet) with the
#    official one, byte-exact only: any sha256 mismatch is a difference.
#    Flatpak: flatpak-builder strips ELF files in the official bundle; such a
#    file is still a difference. The diff file notes when its loaded sections
#    are identical, as information only.
# 5. Writes COMPARISON_RESULTS.yaml next to the script; full diff in the workspace.
# Only podman or docker is needed on the host. Windows and macOS releases are
# built on developer machines with MSVC/Xcode and cannot be built here.

SCRIPT_VERSION="v0.3.1"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_HASH="$(sha256sum "${SCRIPT_PATH}" 2>/dev/null | awk '{print $1}')"
[[ -n "${SCRIPT_HASH}" ]] || SCRIPT_HASH="N/A"
echo "$(basename "$0") ${SCRIPT_VERSION} sha256:${SCRIPT_HASH}"

set -uo pipefail

APP_ID="desk.stackwallet"
GITHUB_REPO="cypherstack/stack_wallet"
REPO_URL="https://github.com/${GITHUB_REPO}.git"
BASE_IMAGE="docker.io/library/ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3"
FLUTTER_VERSION="3.47.7"
FLUTTER_COMMIT="abaf9c523780a608bd46686fd5e53740a07077f8"
GO_VERSION="1.24.4"
GO_SHA256="77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717"
RUSTUP_SHA256="20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

script_dir="$(dirname "${SCRIPT_PATH}")"
results_file="${script_dir}/COMPARISON_RESULTS.yaml"
run_id="$(date +%s)-$$"

requested_version=""
requested_arch="x86_64-linux"
requested_type=""
binary_input=""
should_cleanup=false

work_dir=""
build_image=""
tools_image=""
version_name=""
build_number=""
git_tag=""
official_file=""
official_hash=""
built_commit="unknown"

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*"; }

# No YAML on these paths: ABS publishes any YAML verdict, so a missing runtime,
# bad input, network failure or stop must not leave one behind.
die_invalid() { log_error "$*"; exit "${EXIT_INVALID}"; }
die_failed()  { log_error "$*"; exit "${EXIT_FAILED}"; }

write_yaml() {
  local v="$1" notes="$2"
  {
    echo "script_version: ${SCRIPT_VERSION}"
    echo "verdict: ${v}"
    if [[ -n "${official_hash}" ]]; then
      echo "hashes:"
      echo "  - ${official_hash}"
    fi
    echo "notes: |"
    printf '%s\n' "${notes}" | sed 's/^/  /'
  } > "${results_file}"
  log_info "Wrote ${results_file}"
}

usage() {
  cat <<EOF
NAME
    $(basename "$0") - Stack Wallet Desktop (Linux) reproducible build verification

SYNOPSIS
    $(basename "$0") --version <ver> [--arch x86_64-linux] [--type appimage|flatpak]
    $(basename "$0") --binary <file|dir> [--version <ver>] [--arch ...] [--type ...]

OPTIONS
    --version <ver>   Version, e.g. 2.7.5. Without --binary the official file is
                      downloaded from the GitHub release.
    --binary <path>   Official sw-v<ver>-linux.AppImage or .flatpak, or a
                      directory holding exactly one of them.
    --arch <arch>     x86_64-linux (default; x86_64-linux-gnu accepted)
    --type <type>     appimage (default) or flatpak; inferred from --binary
    --cleanup         Remove the workspace at the end
    --script-version  Print version and exit
    --help            Show this help and exit

EXIT CODES
    0  reproducible   1  not reproducible, ftbfs or failure
    2  invalid parameters   130  stopped
EOF
}

require_arg() { [[ -n "${2:-}" && "${2}" != --* ]] || die_invalid "Option $1 requires a value."; }

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)  require_arg "$1" "${2:-}"; requested_version="${2#v}"; shift ;;
    --binary)   require_arg "$1" "${2:-}"; binary_input="$2"; shift ;;
    --arch)     require_arg "$1" "${2:-}"; requested_arch="$2"; shift ;;
    --type)     require_arg "$1" "${2:-}"; requested_type="${2,,}"; shift ;;
    --cleanup)  should_cleanup=true ;;
    --script-version) exit "${EXIT_SUCCESS}" ;;
    --help|-h)  usage; exit "${EXIT_SUCCESS}" ;;
    *)          log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] && die_invalid "Do not run as root."
[[ -z "${requested_version}" && -z "${binary_input}" ]] && die_invalid "Either --version or --binary is required."

case "${requested_arch}" in
  x86_64-linux|x86_64-linux-gnu|linux-x86_64|x86_64|amd64) requested_arch="x86_64-linux" ;;
  *windows*|win64|*macos*|*darwin*)
    die_invalid "Arch '${requested_arch}' is not supported: upstream builds Windows and macOS releases on developer machines (MSVC/Xcode), which cannot run in a Linux container." ;;
  *) die_invalid "Arch '${requested_arch}' is not supported (only x86_64-linux)." ;;
esac

# Resolve --binary (file, or directory with exactly one official Linux file).
if [[ -n "${binary_input}" ]]; then
  if [[ -d "${binary_input}" ]]; then
    pattern='*-linux.AppImage'
    [[ "${requested_type}" == "flatpak" ]] && pattern='*-linux.flatpak'
    mapfile -t _cands < <(find "${binary_input}" -maxdepth 1 -type f -name "${pattern}" | sort)
    if [[ "${#_cands[@]}" -eq 0 && -z "${requested_type}" ]]; then
      mapfile -t _cands < <(find "${binary_input}" -maxdepth 1 -type f -name '*-linux.flatpak' | sort)
    fi
    [[ "${#_cands[@]}" -eq 1 ]] || die_invalid "Directory ${binary_input} must hold exactly one ${pattern} (found ${#_cands[@]})."
    official_file="$(readlink -f "${_cands[0]}")"
  elif [[ -f "${binary_input}" ]]; then
    official_file="$(readlink -f "${binary_input}")"
  else
    die_invalid "--binary path does not exist: ${binary_input}"
  fi
  if [[ -z "${requested_type}" ]]; then
    case "${official_file,,}" in
      *.flatpak) requested_type="flatpak" ;;
      *) requested_type="appimage" ;;
    esac
  fi
fi
[[ -z "${requested_type}" ]] && requested_type="appimage"
case "${requested_type}" in
  appimage) asset_ext="AppImage" ;;
  flatpak)  asset_ext="flatpak" ;;
  *) die_invalid "Type '${requested_type}' is not supported (appimage or flatpak)." ;;
esac

CONTAINER_CMD="" VOLUME_RO="" VOLUME_RW=""
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"; VOLUME_RO=":ro,Z"; VOLUME_RW=":Z"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"; VOLUME_RO=":ro"; VOLUME_RW=""
else
  die_failed "Neither podman nor docker found (the only host requirement)."
fi

rm -f "${results_file}"

ws_version="${requested_version}"
if [[ -z "${ws_version}" && "$(basename "${official_file}")" =~ ^sw-v([0-9][0-9.]*)-linux ]]; then
  ws_version="${BASH_REMATCH[1]}"
fi
work_dir="$(pwd -P)/stackwalletdesktop_verification_${ws_version:-binary}_${requested_type}_${run_id}"
mkdir "${work_dir}" || die_failed "Cannot create workspace ${work_dir}"
mkdir -p "${work_dir}/official" "${work_dir}/build"
run_name="swd-${run_id}"
build_image="localhost/stackwalletdesktop_build_env:${SCRIPT_VERSION}-${run_id}"
tools_image="localhost/stackwalletdesktop_tools:${SCRIPT_VERSION}-${run_id}"
log_info "Workspace: ${work_dir}"

on_exit() {
  local code=$?
  set +e
  ${CONTAINER_CMD} rm -f "${run_name}-build" >/dev/null 2>&1
  if [[ -d "${work_dir}" ]]; then
    local owner="$(id -u):$(id -g)"; [[ "${CONTAINER_CMD}" == podman ]] && owner="0:0"
    ${CONTAINER_CMD} run --rm -v "${work_dir}:/w${VOLUME_RW}" "${BASE_IMAGE}" sh -c "chown -R ${owner} /w && chmod -R u+w /w" >/dev/null 2>&1
    [[ "${should_cleanup}" == true ]] && rm -rf "${work_dir}"
  fi
  ${CONTAINER_CMD} rmi "${build_image}" "${tools_image}" >/dev/null 2>&1
  exit "${code}"
}
trap on_exit EXIT
trap 'log_error "Stopped."; rm -f "${results_file}"; exit 130' INT TERM

# ------------------------------------------------------------------------------
# Tools image (download, unpack, compare) and helper
# ------------------------------------------------------------------------------
log_info "Building tools image..."
${CONTAINER_CMD} build --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t "${tools_image}" - <<'DOCKERFILE' || die_failed "Tools image build failed."
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates python3 squashfs-tools flatpak ostree \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

cat > "${work_dir}/swd_helper.py" <<'PYEOF'
import hashlib, json, os, re, struct, subprocess, sys, urllib.request

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()

def elf_info(p):
    """(sha256 of all SHF_ALLOC sections, has .symtab) or None if not ELF64 LE."""
    with open(p, 'rb') as f:
        d = f.read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        return None
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    stro = secs[shstrndx][4]
    h, symtab = hashlib.sha256(), False
    for name, typ, flags, addr, off, size, *_ in secs:
        symtab |= typ == 2
        if flags & 2:
            n = d[stro + name:d.index(b'\0', stro + name)]
            h.update(n + struct.pack('<IQQ', typ, addr, size))
            if typ != 8:
                h.update(d[off:off + size])
    return h.hexdigest(), symtab

def release(ver, ext, out):
    name = f'sw-v{ver}-linux.{ext}'
    hdr = {'Accept': 'application/vnd.github+json', 'User-Agent': 'walletscrutiny'}
    if os.environ.get('GITHUB_TOKEN'):
        hdr['Authorization'] = 'Bearer ' + os.environ['GITHUB_TOKEN']
    for page in range(1, 4):
        url = f'https://api.github.com/repos/cypherstack/stack_wallet/releases?per_page=100&page={page}'
        rels = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=60))
        for r in rels:
            for a in r.get('assets', []):
                if a['name'] == name:
                    dest = os.path.join(out, name)
                    req = urllib.request.Request(a['browser_download_url'], headers={'User-Agent': 'walletscrutiny'})
                    with urllib.request.urlopen(req, timeout=600) as s, open(dest, 'wb') as f:
                        while True:
                            b = s.read(1 << 20)
                            if not b:
                                break
                            f.write(b)
                    print(f"tag={r['tag_name']}\nfile={dest}\ndigest={(a.get('digest') or '').replace('sha256:', '')}")
                    return
        if not rels:
            break
    sys.exit(f'No GitHub release asset named {name}')

def unpack(path, typ, root):
    if typ == 'appimage':
        with open(path, 'rb') as f:
            f.seek(0x28); shoff, = struct.unpack('<Q', f.read(8))
            f.seek(0x3a); shentsize, shnum = struct.unpack('<HH', f.read(4))
            off = shoff + shnum * shentsize
            f.seek(off)
            if f.read(4) not in (b'hsqs', b'sqsh'):
                sys.exit('No squashfs found in the AppImage')
        subprocess.run(['unsquashfs', '-q', '-no-xattrs', '-o', str(off), '-d', root, path], check=True,
                       stdout=subprocess.DEVNULL)
        bundle = root
    else:
        repo = root + '.repo'
        subprocess.run(['ostree', 'init', '--repo=' + repo, '--mode=archive-z2'], check=True)
        subprocess.run(['flatpak', 'build-import-bundle', repo, path], check=True)
        ref = subprocess.run(['ostree', '--repo=' + repo, 'refs'], check=True, capture_output=True,
                             text=True).stdout.split()[0]
        subprocess.run(['ostree', '--repo=' + repo, 'checkout', '-U', ref, root], check=True)
        bundle = None
        for dp, dn, fn in os.walk(os.path.join(root, 'files')):
            if 'version.json' in fn and dp.endswith('data/flutter_assets'):
                bundle = os.path.dirname(os.path.dirname(dp))
                break
        if not bundle:
            sys.exit('No Flutter bundle found in the flatpak')
    v = json.load(open(os.path.join(bundle, 'data/flutter_assets/version.json')))
    with open(os.path.join(bundle, 'lib/libapp.so'), 'rb') as f:
        commits = sorted(set(m.decode() for m in re.findall(rb'(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])', f.read())))
    print(f"version={v.get('version', '')}\nbuild_number={v.get('build_number', '')}\nbundle={bundle}")
    print('commits=' + ' '.join(commits))

def tree(base):
    out = {}
    for sub in ('lib', 'data', 'stack_wallet'):
        p = os.path.join(base, sub)
        if os.path.islink(p) or os.path.isfile(p):
            out[sub] = p
        for dp, dn, fn in os.walk(p):
            for n in dn + fn:
                q = os.path.join(dp, n)
                if os.path.islink(q) or os.path.isfile(q):
                    out[os.path.relpath(q, base)] = q
    return out

def compare(off_base, blt_base, typ, root, diff_path):
    off, blt = tree(off_base), tree(blt_base)
    res = {'match': [], 'differ': [], 'missing': [], 'extra': []}
    sections_same = []
    lines = []
    for rel in sorted(set(off) | set(blt)):
        if rel not in blt:
            res['missing'].append(rel); lines.append(f'MISSING_FROM_BUILT {rel}'); continue
        if rel not in off:
            res['extra'].append(rel); lines.append(f'EXTRA_IN_BUILT {rel}'); continue
        o, b = off[rel], blt[rel]
        if os.path.islink(o) or os.path.islink(b):
            lo = os.readlink(o) if os.path.islink(o) else 'file'
            lb = os.readlink(b) if os.path.islink(b) else 'file'
            k = 'match' if lo == lb else 'differ'
            res[k].append(rel); lines.append(f'{k.upper()} {rel} -> {lo} | {lb}'); continue
        ho, hb = sha256(o), sha256(b)
        if ho == hb:
            res['match'].append(rel); lines.append(f'MATCH {rel} {ho}'); continue
        # Byte-exact only: every sha256 mismatch is a difference.
        res['differ'].append(rel)
        info = ''
        eo, eb = elf_info(o), elf_info(b)
        if eo and eb and eo[0] == eb[0]:
            sections_same.append(rel)
            info = f' [info: loaded sections identical {eo[0]}; official .symtab={eo[1]}, built .symtab={eb[1]}]'
        lines.append(f'DIFF {rel} official {ho} ({os.path.getsize(o)} B) built {hb} ({os.path.getsize(b)} B){info}')
    lines.append('')
    lines.append('PACKAGING (not produced by the Flutter build, not compared):')
    for dp, dn, fn in os.walk(root):
        for n in sorted(fn):
            q = os.path.join(dp, n)
            r = os.path.relpath(q, off_base)
            if not r.startswith('..') and r.split(os.sep)[0] in ('lib', 'data', 'stack_wallet'):
                continue
            if os.path.isfile(q) and not os.path.islink(q):
                lines.append(f'  {os.path.relpath(q, root)} {sha256(q)}')
    apprun = os.path.join(root, 'AppRun')
    if typ == 'appimage' and os.path.isfile(apprun):
        lines.append('AppRun content:')
        lines += ['  ' + l for l in open(apprun, errors='replace').read().splitlines()]
    open(diff_path, 'w').write('\n'.join(lines) + '\n')
    for k, v in res.items():
        print(f'{k}_count={len(v)}')
        print(f'{k}_files=' + ' '.join(v))
    print(f'sections_same_count={len(sections_same)}')
    print('sections_same_files=' + ' '.join(sections_same))

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'release':
        release(*sys.argv[2:5])
    elif cmd == 'unpack':
        unpack(*sys.argv[2:5])
    elif cmd == 'compare':
        compare(*sys.argv[2:7])
PYEOF

tools() {
  ${CONTAINER_CMD} run --rm ${GITHUB_TOKEN:+-e GITHUB_TOKEN} -v "${work_dir}:/w${VOLUME_RW}" -w /w "${tools_image}" "$@"
}
kv() { grep -m1 "^$1=" "$2" | cut -d= -f2-; }

# ------------------------------------------------------------------------------
# Official artifact
# ------------------------------------------------------------------------------
if [[ -z "${official_file}" ]]; then
  log_info "Downloading sw-v${requested_version}-linux.${asset_ext} from the GitHub release..."
  tools python3 /w/swd_helper.py release "${requested_version}" "${asset_ext}" /w/official > "${work_dir}/release.env" || \
    die_failed "Could not download sw-v${requested_version}-linux.${asset_ext} (network, rate limit or no such release)."
  official_file="${work_dir}/official/$(basename "$(kv file "${work_dir}/release.env")")"
  official_hash="$(sha256sum "${official_file}" | awk '{print $1}')"
  published="$(kv digest "${work_dir}/release.env")"
  if [[ -n "${published}" && "${published}" != "${official_hash}" ]]; then
    die_failed "Downloaded file sha256 ${official_hash} does not match GitHub's published ${published}."
  fi
  log_info "Release tag: $(kv tag "${work_dir}/release.env"); GitHub digest checked: ${published:-not published}"
else
  cp "${official_file}" "${work_dir}/official/" || die_failed "Cannot copy ${official_file}"
  official_file="${work_dir}/official/$(basename "${official_file}")"
  official_hash="$(sha256sum "${official_file}" | awk '{print $1}')"
fi
official_name="$(basename "${official_file}")"
log_info "Official ${official_name} sha256: ${official_hash}"

log_info "Unpacking the official ${requested_type}..."
tools python3 /w/swd_helper.py unpack "/w/official/${official_name}" "${requested_type}" /w/official/root \
  > "${work_dir}/official.env" || die_invalid "${official_name} is not a Stack Wallet Linux ${requested_type}."
version_name="$(kv version "${work_dir}/official.env")"
build_number="$(kv build_number "${work_dir}/official.env")"
official_bundle="$(kv bundle "${work_dir}/official.env")"; official_bundle="${work_dir}${official_bundle#/w}"
embedded_commits="$(kv commits "${work_dir}/official.env")"
[[ "${build_number}" =~ ^[0-9]+$ && -n "${version_name}" ]] || die_invalid "No version/build number in ${official_name}."
if [[ -n "${requested_version}" && "${requested_version}" != "${version_name}" ]]; then
  die_invalid "--version ${requested_version} but ${official_name} is version ${version_name}."
fi
git_tag="build_${build_number}"
log_info "Version ${version_name}, build ${build_number}, tag ${git_tag}"

# ------------------------------------------------------------------------------
# Toolchain image: the maintainer's workstation layout
# ------------------------------------------------------------------------------
log_info "Building toolchain image (first run: about 20 minutes)..."
${CONTAINER_CMD} build --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "FLUTTER_VERSION=${FLUTTER_VERSION}" --build-arg "FLUTTER_COMMIT=${FLUTTER_COMMIT}" \
  --build-arg "GO_VERSION=${GO_VERSION}" --build-arg "GO_SHA256=${GO_SHA256}" \
  --build-arg "RUSTUP_SHA256=${RUSTUP_SHA256}" \
  -t "${build_image}" - <<'DOCKERFILE' || die_failed "Toolchain image build failed (not a source build failure)."
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG FLUTTER_VERSION
ARG FLUTTER_COMMIT
ARG GO_VERSION
ARG GO_SHA256
ARG RUSTUP_SHA256
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    TAR_OPTIONS=--no-same-owner \
    HOME=/home/diego RUSTUP_HOME=/home/diego/.rustup CARGO_HOME=/home/diego/.cargo \
    GOPATH=/home/diego/go GOTOOLCHAIN=local \
    FLUTTER_SUPPRESS_ANALYTICS=true PUB_SUPPRESS_ANALYTICS=true
ENV PATH=/opt/flutter/bin:/home/diego/.cargo/bin:/usr/local/go/bin:${PATH}
RUN mkdir -p /home/diego/Desktop/releases
# Upstream Dockerfile "full" stage package list (Linux part), plus g-ir-scanner/xsltproc for libsecret
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl file git gnupg python3 unzip xz-utils \
      automake build-essential cmake debhelper libtool meson ninja-build pkg-config rsync \
      clang libclang-dev llvm \
      libgcrypt20-dev libgirepository1.0-dev libgit2-dev libglib2.0-dev libgtk-3-dev \
      libjsoncpp-dev liblzma-dev libncurses5-dev libncursesw5-dev libopencv-dev \
      libsecret-1-dev libssl-dev libtss2-dev \
      ocl-icd-opencl-dev opencl-headers valac zlib1g-dev \
      gobject-introspection xsltproc \
 && rm -rf /var/lib/apt/lists/*
# Rust toolchains pinned by the plugins' rust-toolchain.toml at build_325:
# epic 1.89.0, mwc/frostdart/tor 1.90.0, xelis 1.94.1 (all match the official .comment sections)
RUN curl -fsSL -o /tmp/rustup-init https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init \
 && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - && chmod +x /tmp/rustup-init \
 && /tmp/rustup-init -y --default-toolchain 1.89.0 --profile minimal --no-modify-path && rm /tmp/rustup-init \
 && rustup toolchain install 1.90.0 1.94.1 --profile minimal \
 && rustup component add clippy rustfmt --toolchain 1.94.1
RUN curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter \
 && test "$(git -C /opt/flutter rev-parse HEAD)" = "${FLUTTER_COMMIT}" \
 && git config --global --add safe.directory '*' \
 && flutter config --no-analytics && flutter precache --linux \
 && flutter --version && rustc --version && go version
WORKDIR /home/diego/Desktop/releases
DOCKERFILE

# ------------------------------------------------------------------------------
# Source build (inside the container)
# ------------------------------------------------------------------------------
cat > "${work_dir}/run_build.sh" <<'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail
TAG="$1"; VER="$2"; BN="$3"; REPO="$4"
SRC=/home/diego/Desktop/releases/stack_wallet
stage() { echo "$1" > /output/stage; echo "[BUILD] stage: $1"; }
stage clone
git clone --depth 1 --branch "${TAG}" "${REPO}" "${SRC}"
git -C "${SRC}" rev-parse HEAD > /output/commit
case "$(git -C "${SRC}" cat-file -t "refs/tags/${TAG}" 2>/dev/null)" in
  tag) echo annotated ;; commit) echo lightweight ;; *) echo unknown ;;
esac > /output/tag_type
stage configure
cd "${SRC}/scripts"
# Upstream release configuration: no -d (Rust plugins build from source, as the
# official libraries show) and no -s (jsoncpp/libsecret built from source and bundled).
echo yes | ./build_app.sh -v "${VER}" -b "${BN}" -p linux -a stack_wallet
# Upstream's empty API key template; the official build compiles real keys into libapp.so.
./prebuild.sh
cd "${SRC}"
stage pub-get
flutter pub get
stage build
flutter build linux --release
cp -a build/linux/x64/release/bundle /output/bundle
stage done
BUILDSCRIPT

log_info "Building Stack Wallet ${version_name} (${git_tag}) from source (60-90 minutes)..."
${CONTAINER_CMD} run --rm --name "${run_name}-build" \
  -v "${work_dir}/run_build.sh:/run_build.sh${VOLUME_RO}" \
  -v "${work_dir}/build:/output${VOLUME_RW}" \
  "${build_image}" bash /run_build.sh "${git_tag}" "${version_name}" "${build_number}" "${REPO_URL}" \
  2>&1 | tee "${work_dir}/build.log"
build_rc="${PIPESTATUS[0]}"
stage="$(cat "${work_dir}/build/stage" 2>/dev/null || echo image)"
[[ -s "${work_dir}/build/commit" ]] && built_commit="$(cat "${work_dir}/build/commit")"
tag_type="$(cat "${work_dir}/build/tag_type" 2>/dev/null || echo unknown)"

if [[ "${build_rc}" -ne 0 || "${stage}" != "done" ]]; then
  if [[ "${stage}" == "clone" || "${stage}" == "image" ]]; then
    die_failed "Could not clone ${REPO_URL} at ${git_tag} (exit ${build_rc}); no verdict. Log: ${work_dir}/build.log"
  fi
  # A download that fails mid-build (pub get, cargo, go modules, git submodules)
  # says nothing about the source: stop without a verdict so ABS publishes none.
  net_err="$(grep -m1 -i -E "Could not resolve host|Temporary failure in name resolution|Failed host lookup|Name or service not known|Network is unreachable|Connection (timed out|refused|reset)|Operation timed out|SocketException|TLS handshake|spurious network error|error sending request|failed to download|Got socket error|HTTP (error )?50[234]|The requested URL returned error: 5[0-9][0-9]|RPC failed|early EOF|unable to access 'https?://" "${work_dir}/build.log")"
  if [[ -n "${net_err}" ]]; then
    die_failed "Build stopped in stage ${stage} by a network failure; no verdict. First match: ${net_err:0:200}. Log: ${work_dir}/build.log"
  fi
  write_yaml "ftbfs" "Stack Wallet Desktop ${version_name} (${git_tag}, commit ${built_commit}), ${requested_type}.
Official ${official_name} sha256: ${official_hash}
The source build failed in stage '${stage}' (exit ${build_rc}). See build.log in the workspace.
Last lines:
$(grep -v '^\s*$' "${work_dir}/build.log" | tail -n 8)"
  die_failed "Build failed in stage ${stage}."
fi

# ------------------------------------------------------------------------------
# Comparison
# ------------------------------------------------------------------------------
log_info "Comparing the built bundle with the official one..."
diff_file="${work_dir}/diff_bundle.txt"
tools python3 /w/swd_helper.py compare "/w${official_bundle#${work_dir}}" /w/build/bundle "${requested_type}" \
  /w/official/root /w/diff_bundle.txt > "${work_dir}/compare.env" || die_failed "Comparison step failed."

c() { kv "$1_count" "${work_dir}/compare.env"; }
f() { kv "$1_files" "${work_dir}/compare.env"; }
n_match="$(c match)"; n_diff="$(c differ)"; n_miss="$(c missing)"; n_extra="$(c extra)"
n_sect="$(c sections_same)"
[[ "${n_match}" =~ ^[0-9]+$ && "${n_diff}" =~ ^[0-9]+$ && "${n_miss}" =~ ^[0-9]+$ && "${n_extra}" =~ ^[0-9]+$ ]] || \
  die_failed "Comparison output incomplete; no verdict."
total_diff=$(( n_diff + n_miss + n_extra ))
# Byte-exact only: reproducible needs every compared file to have the same sha256.
verdict="not_reproducible"; [[ "${total_diff}" -eq 0 && "${n_match}" -gt 0 ]] && verdict="reproducible"

commit_note="Embedded commit in the official libapp.so: not found"
if [[ " ${embedded_commits} " == *" ${built_commit} "* ]]; then
  commit_note="The official libapp.so embeds commit ${built_commit}, the tag's commit."
elif [[ -n "${embedded_commits}" ]]; then
  commit_note="The official libapp.so does not embed the tag commit ${built_commit}."
fi

notes="Stack Wallet Desktop ${version_name} (build ${build_number}), x86_64 Linux ${requested_type}.
Official ${official_name} sha256: ${official_hash}
Source: ${REPO_URL} tag ${git_tag} (${tag_type} tag), commit ${built_commit}. ${commit_note}
Build: Ubuntu 24.04 container laid out like the maintainer's workstation (HOME=/home/diego,
source /home/diego/Desktop/releases/stack_wallet), Flutter ${FLUTTER_VERSION}, Go ${GO_VERSION},
Rust 1.89.0/1.90.0/1.94.1, upstream scripts/build_app.sh -p linux -a stack_wallet.
Compared every file under lib/, data/ and stack_wallet of the Flutter bundle by sha256, byte-exact only.
Result: ${n_match} identical, ${n_diff} differ, ${n_miss} missing from build, ${n_extra} extra in build."
[[ "${n_diff}" -gt 0 ]] && notes+="
Differing: $(f differ)"
[[ "${n_miss}" -gt 0 ]] && notes+="
Missing from build: $(f missing)"
[[ "${n_extra}" -gt 0 ]] && notes+="
Extra in build: $(f extra)"
[[ " $(f differ) " == *" lib/libapp.so "* ]] && notes+="
lib/libapp.so is expected to differ: the release compiles 15 secret partner API keys
(lib/external_api_keys.dart) into it; this build uses upstream's empty template."
[[ "${n_sect:-0}" -gt 0 ]] && notes+="
Of the differing files, ${n_sect} have identical loaded sections (code, data, dynamic symbols)
but different file bytes, e.g. stripped in the official flatpak. They still count as differences
(byte-exact only): $(f sections_same)"
notes+="
Not compared (packaging, not built from source): the AppImage runtime and AppRun/.desktop/icon,
or the flatpak metadata, manifest.json, exports and icons; listed with sha256 in the diff file."

write_yaml "${verdict}" "${notes}"

echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         N/A"
echo "apkVersionName: ${version_name}"
echo "apkVersionCode: ${build_number}"
echo "verdict:        ${verdict}"
echo "appHash:        ${official_hash}"
echo "commit:         ${built_commit}"
echo "scriptVersion:  ${SCRIPT_VERSION}"
echo "scriptHash:     ${SCRIPT_HASH}"
echo ""
echo "Diff:"
grep -E '^(DIFF|MISSING_FROM_BUILT|EXTRA_IN_BUILT) ' "${diff_file}" | cut -c1-160 | head -n 5
echo "===== End Results ====="
echo ""
echo "Legend: appHash is the sha256 of the official ${official_name} as downloaded; publish that one."
echo "Files: ${n_match} identical, ${n_diff} differ (${n_sect:-0} of them with identical loaded sections), ${n_miss} missing, ${n_extra} extra"
[[ "${total_diff}" -gt 5 ]] && echo "(first 5 of ${total_diff} differences shown)"
echo "Full diff: ${diff_file}"
echo "Build log: ${work_dir}/build.log"

[[ "${verdict}" == "reproducible" ]] && exit "${EXIT_SUCCESS}"
exit "${EXIT_FAILED}"
