#!/bin/bash
# thunderhub_build.sh — ThunderHub (self-hosted LND manager, Docker image) reproducible build verification
# Version: v0.1.2
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-11-03
# Project: https://github.com/apotdevin/thunderhub
# Disclaimer: for reproducible-build verification and research only. No warranty; users assume all risk and are responsible for legal compliance; the developers assume no liability for misuse.
# Steps: clone the tag in a container, pin the Dockerfile's base image to the digest it resolves to, build the
# image with upstream's Dockerfile, take the official image (--binary or docker.io/apotdevin/thunderhub by
# digest), export both root filesystems and compare every entry (content, type, mode, owner, link target;
# not mtimes) plus the image config, write COMPARISON_RESULTS.yaml next to the caller.
# Supported: x86_64 (linux/amd64), types standard and base (BASE_PATH=/thub). Design notes:
# script-notes/desktop/thunderhub.lnd/changelog.md
# ABS starts only from a registered asset, so it reaches this script through --binary (an image archive).
# Exit codes: 0 = reproducible, 1 = not_reproducible or ftbfs, 2 = invalid parameters, 130 = stopped.
set -euo pipefail

SCRIPT_VERSION="v0.1.2"
APP_ID="thunderhub.lnd"
REPO_URL="https://github.com/apotdevin/thunderhub.git"
IMAGE_REPO="apotdevin/thunderhub"
# Tool image for the clone only; it never touches the compared files.
GIT_IMAGE="docker.io/alpine/git:v2.54.0@sha256:ac6c828f15d82775d204d3d75112e1d34af8945da80ccf922713c9891ba68e7a"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

DOCKER_CMD="${DOCKER_CMD:-}"
APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
BINARY_PATH=""
KEEP_CONTAINER=false
EXEC_DIR="$(pwd -P)"
RESULTS_FILE="${EXEC_DIR}/COMPARISON_RESULTS.yaml"
WORK_DIR=""
SUFFIX=""
BUILT_IMAGE=""
OFF_CTR=""
BLD_CTR=""
BUILD_PID=""
TEE_PID=""
APP_HASH="N/A"
APP_COMMIT="N/A"
IMAGE_ID="N/A"
INDEX_DIGEST="N/A"
NODE_REF=""
SCRIPT_HASH="N/A"
declare -a USER_FLAGS=()
# Source failures only. Network, memory and registry errors must never become ftbfs: ABS publishes any YAML.
COMPILE_ERRORS='error TS[0-9]+|error during build|Found [0-9]+ errors?'
# Vite reports running out of file handles as a failed import, so that message never counts as a source failure.
FILE_LIMIT_ERROR='failed to resolve import'

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

warn() {
    echo "WARN: $1" >&2
}

cleanup() {
    set +e
    # A stop during the build: end it before touching its image. Runs even with --keep-container.
    if [[ -n "$BUILD_PID" ]]; then
        kill -TERM "$BUILD_PID" 2>/dev/null
        local i
        for i in {1..30}; do
            kill -0 "$BUILD_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$BUILD_PID" 2>/dev/null
    fi
    [[ -n "$TEE_PID" ]] && kill "$TEE_PID" 2>/dev/null
    [[ -n "$DOCKER_CMD" && "$KEEP_CONTAINER" != true ]] || return 0
    [[ -n "$OFF_CTR" ]] && "$DOCKER_CMD" rm -f "$OFF_CTR" >/dev/null 2>&1
    [[ -n "$BLD_CTR" ]] && "$DOCKER_CMD" rm -f "$BLD_CTR" >/dev/null 2>&1
    [[ -n "$BUILT_IMAGE" ]] && "$DOCKER_CMD" rmi -f "$BUILT_IMAGE" >/dev/null 2>&1
    return 0
}

detect_container_cmd() {
    if [[ -z "$DOCKER_CMD" ]]; then
        if command -v podman >/dev/null 2>&1; then
            DOCKER_CMD="podman"
        elif command -v docker >/dev/null 2>&1; then
            DOCKER_CMD="docker"
        else
            die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
        fi
    fi
    # Containers that write into the workspace run as the caller, so every file stays deletable.
    if [[ "$(basename "$DOCKER_CMD")" == podman* ]]; then
        USER_FLAGS=(--userns=keep-id)
    else
        USER_FLAGS=(--user "$(id -u):$(id -g)")
    fi
}

require_value() {
    if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        die "Missing value for parameter: $1" $EXIT_INVALID_PARAMS
    fi
}

usage() {
    echo "Usage: $0 --version X.Y.Z [--arch x86_64-linux] [--type standard|base] [--binary IMAGE.tar|DIR]"
    echo "  --binary  docker/oci archive from 'podman save' or 'docker save', an OCI layout directory,"
    echo "            or a directory holding exactly one such archive. Without it the official image is"
    echo "            pulled from docker.io/${IMAGE_REPO} by digest. Given an image, its layers must equal the"
    echo "            image published for --version and --type, or the script exits 2 with no verdict."
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        usage
        exit $EXIT_INVALID_PARAMS
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) require_value "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
            --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --keep-container) KEEP_CONTAINER=true; shift ;;
            -h|--help) usage; exit $EXIT_INVALID_PARAMS ;;
            *)
                warn "Ignoring unknown parameter: $1"
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi
                ;;
        esac
    done

    [[ -n "$APP_VERSION" ]] || die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    APP_VERSION="${APP_VERSION#v}"
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid --version '$APP_VERSION' (expected X.Y.Z)" $EXIT_INVALID_PARAMS

    case "${APP_ARCH:-x86_64-linux}" in
        x86_64-linux|x86_64-linux-musl|x86_64-linux-gnu|x86_64|amd64|linux/amd64) APP_ARCH="x86_64-linux" ;;
        aarch64*|arm64*|linux/arm64)
            die "arm64 is not supported: upstream builds it under QEMU and compiles secp256k1 there; this script builds linux/amd64 only" $EXIT_INVALID_PARAMS ;;
        *) die "Unsupported --arch '$APP_ARCH' (this script builds x86_64-linux)" $EXIT_INVALID_PARAMS ;;
    esac

    if [[ -z "$APP_TYPE" ]]; then
        warn "No --type given; using standard"
        APP_TYPE="standard"
    fi
    case "$APP_TYPE" in
        standard|base) ;;
        *) die "Invalid --type '$APP_TYPE' (must be standard or base)" $EXIT_INVALID_PARAMS ;;
    esac

    if [[ -n "$BINARY_PATH" ]]; then
        [[ -e "$BINARY_PATH" ]] || die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
        BINARY_PATH=$(realpath "$BINARY_PATH")
    fi
    [[ "$(uname -m)" == "x86_64" ]] || die "This script needs an x86_64 host (no emulation)" $EXIT_INVALID_PARAMS
}

# Node helper: registry lookup, tar listing and comparison. Runs inside the pinned node base image.
write_helper() {
    cat > "${WORK_DIR}/helper.mjs" << 'HELPER_END'
import fs from 'node:fs';
import crypto from 'node:crypto';
const [cmd, ...args] = process.argv.slice(2);

const token = async repo => (await (await fetch(`https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull`)).json()).token;

async function registry(repo, tag, arch) {
  const tok = await token(repo);
  const accept = ['application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'].join(',');
  const r = await fetch(`https://registry-1.docker.io/v2/${repo}/manifests/${tag}`, { headers: { Authorization: `Bearer ${tok}`, Accept: accept } });
  if (!r.ok) throw new Error(`registry ${repo}:${tag}: HTTP ${r.status}`);
  const body = Buffer.from(await r.arrayBuffer());
  const top = 'sha256:' + crypto.createHash('sha256').update(body).digest('hex');
  const m = JSON.parse(body);
  if (!m.manifests) return console.log(`${top} ${top}`);
  const hit = m.manifests.find(x => x.platform?.os === 'linux' && x.platform?.architecture === arch);
  if (!hit) throw new Error(`no linux/${arch} manifest in ${repo}:${tag}`);
  console.log(`${top} ${hit.digest}`);
}

// Runtime files podman/docker add to a created container; they are not part of the image.
const RUNTIME = /^(\.dockerenv|\.containerenv|run\/\.containerenv|etc\/(hostname|hosts|resolv\.conf|mtab)|(dev|proc|sys)\/.+)$/;

// Layer diff IDs of a published image, from its config blob; they do not depend on the archive format.
async function imagelayers(repo, digest) {
  const tok = await token(repo), headers = { Authorization: `Bearer ${tok}` };
  const accept = 'application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json';
  const r = await fetch(`https://registry-1.docker.io/v2/${repo}/manifests/${digest}`, { headers: { ...headers, Accept: accept } });
  if (!r.ok) throw new Error(`manifest ${digest}: HTTP ${r.status}`);
  const want = (await r.json()).config.digest;
  const c = await fetch(`https://registry-1.docker.io/v2/${repo}/blobs/${want}`, { headers });
  if (!c.ok) throw new Error(`config ${want}: HTTP ${c.status}`);
  const blob = Buffer.from(await c.arrayBuffer());
  if ('sha256:' + crypto.createHash('sha256').update(blob).digest('hex') !== want) throw new Error(`config ${want}: digest mismatch`);
  process.stdout.write(JSON.parse(blob).rootfs.diff_ids.join('\n') + '\n');
}

function tarlist(file) {
  const fd = fs.openSync(file, 'r');
  const hdr = Buffer.alloc(512), chunk = Buffer.alloc(1 << 20);
  const seen = new Map(), out = [];
  let pos = 0, longName = null, longLink = null, pax = {};
  const str = (b, o, n) => { const s = b.subarray(o, o + n); const z = s.indexOf(0); return (z < 0 ? s : s.subarray(0, z)).toString('utf8'); };
  const num = (b, o, n) => {
    if (b[o] & 0x80) { let v = 0; for (let i = o + 1; i < o + n; i++) v = v * 256 + b[i]; return v; }
    return parseInt(str(b, o, n).trim() || '0', 8);
  };
  const body = (size, keep) => {
    const h = crypto.createHash('sha256'), parts = [];
    let left = size;
    while (left > 0) {
      const n = fs.readSync(fd, chunk, 0, Math.min(left, chunk.length), pos);
      if (n <= 0) throw new Error('truncated tar');
      h.update(chunk.subarray(0, n)); if (keep) parts.push(Buffer.from(chunk.subarray(0, n)));
      pos += n; left -= n;
    }
    pos += (512 - (size % 512)) % 512;
    return keep ? Buffer.concat(parts) : h.digest('hex');
  };
  for (;;) {
    if (fs.readSync(fd, hdr, 0, 512, pos) < 512) break;
    pos += 512;
    if (hdr.every(b => b === 0)) break;
    const type = String.fromCharCode(hdr[156] || 48);
    let size = num(hdr, 124, 12);
    if (type === 'x' || type === 'g') {
      const rec = body(size, true).toString('utf8');
      if (type === 'x') for (const line of rec.split('\n')) { const m = line.match(/^\d+ ([^=]+)=(.*)$/s); if (m) pax[m[1]] = m[2]; }
      continue;
    }
    if (type === 'L') { longName = body(size, true).toString('utf8').replace(/\0+$/, ''); continue; }
    if (type === 'K') { longLink = body(size, true).toString('utf8').replace(/\0+$/, ''); continue; }
    const prefix = str(hdr, 345, 155);
    let name = pax.path ?? longName ?? (prefix ? prefix + '/' : '') + str(hdr, 0, 100);
    const link = pax.linkpath ?? longLink ?? str(hdr, 157, 100);
    if (pax.size) size = Number(pax.size);
    const uid = pax.uid ?? num(hdr, 108, 8), gid = pax.gid ?? num(hdr, 116, 8);
    const mode = (num(hdr, 100, 8) & 0o7777).toString(8).padStart(4, '0');
    pax = {}; longName = null; longLink = null;
    name = name.replace(/^\.?\/+/, '').replace(/\/+$/, '');
    let kind, what;
    if (type === '0' || type === '7' || type === '\0') { kind = 'file'; what = body(size, false); seen.set(name, what); }
    else { if (size > 0) body(size, false);
      if (type === '1') { kind = 'file'; what = seen.get(link.replace(/^\.?\/+/, '')) ?? `hardlink:${link}`; }
      else if (type === '2') { kind = 'symlink'; what = link; }
      else if (type === '5') { kind = 'dir'; what = '-'; }
      else { kind = `type${type}`; what = `${num(hdr, 329, 8)},${num(hdr, 337, 8)}`; } }
    if (!name || RUNTIME.test(name)) continue;
    out.push(`${name}\t${kind}\t${mode}\t${uid}:${gid}\t${what}`);
  }
  out.sort();
  process.stdout.write(out.join('\n') + '\n');
}

// Fields of 'image inspect' that decide what the container runs; labels the builder adds are dropped.
function config(file) {
  let j = JSON.parse(fs.readFileSync(file, 'utf8')); if (Array.isArray(j)) j = j[0];
  const c = j.Config || {}, labels = { ...(c.Labels || {}) };
  delete labels['io.buildah.version'];
  const v = x => JSON.stringify(x && (typeof x !== 'object' || Object.keys(x).length) ? x : null);
  const lines = [`Architecture=${j.Architecture}`, `Os=${j.Os}`, `Env=${v(c.Env)}`, `Entrypoint=${v(c.Entrypoint)}`, `Cmd=${v(c.Cmd)}`,
    `User=${c.User || ''}`, `WorkingDir=${c.WorkingDir || ''}`, `ExposedPorts=${v(c.ExposedPorts)}`, `Volumes=${v(c.Volumes)}`,
    `StopSignal=${c.StopSignal || ''}`, `Labels=${v(labels)}`];
  process.stdout.write(lines.join('\n') + '\n');
}

function layers(file) {
  let j = JSON.parse(fs.readFileSync(file, 'utf8')); if (Array.isArray(j)) j = j[0];
  process.stdout.write((j.RootFS?.Layers || []).join('\n') + '\n');
}

function compare(off, bld) {
  const load = f => new Map(fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => { const i = l.indexOf('\t'); return [l.slice(0, i), l.slice(i + 1)]; }));
  const a = load(off), b = load(bld), keys = [...new Set([...a.keys(), ...b.keys()])].sort();
  let n = 0;
  for (const k of keys) {
    if (a.get(k) === b.get(k)) continue;
    n++;
    console.log(`${!a.has(k) ? 'ONLY_BUILT' : !b.has(k) ? 'ONLY_OFFICIAL' : 'DIFFER'} ${k}\n  official: ${a.get(k) ?? '(missing)'}\n  built:    ${b.get(k) ?? '(missing)'}`);
  }
  console.error(`${keys.length} ${n}`);
}

try {
  if (cmd === 'registry') await registry(...args);
  else if (cmd === 'imagelayers') await imagelayers(...args);
  else if (cmd === 'tarlist') tarlist(args[0]);
  else if (cmd === 'config') config(args[0]);
  else if (cmd === 'layers') layers(args[0]);
  else if (cmd === 'compare') compare(args[0], args[1]);
  else throw new Error(`unknown helper command ${cmd}`);
} catch (e) { console.error(`helper: ${e.message}`); process.exit(3); }
HELPER_END
}

# Run the helper in the pinned node image; extra args go to helper.mjs.
helper() {
    local -a net=()
    [[ "$1" == none ]] && net=(--network none)
    shift
    "$DOCKER_CMD" run --rm "${net[@]}" "${USER_FLAGS[@]}" -v "${WORK_DIR}:/w:z" -w /w \
        --entrypoint node "$NODE_REF" /w/helper.mjs "$@"
}

clone_source() {
    echo "Cloning ${REPO_URL} at v${APP_VERSION} (in container)..."
    "$DOCKER_CMD" run --rm "${USER_FLAGS[@]}" -e HOME=/tmp -v "${WORK_DIR}:/w:z" --entrypoint sh "$GIT_IMAGE" -c '
        set -e
        umask 022
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$1" "$2" /w/src
        # COPY . . carries these modes into the image; a default ACL on the workspace must not change them.
        chmod -R go-w /w/src
        cd /w/src
        echo "commit=$(git rev-parse HEAD)"
        t=$(git cat-file -t "refs/tags/v$1")
        if [ "$t" = tag ]; then
            echo "tag_type=annotated"
            git cat-file -p "refs/tags/v$1" | grep -q "BEGIN [A-Z]* *SIGNATURE" && echo "tag_signed=yes" || echo "tag_signed=no"
        else
            echo "tag_type=lightweight"; echo "tag_signed=n/a"
        fi
        git cat-file -p HEAD | grep -q "^gpgsig" && echo "commit_signed=yes" || echo "commit_signed=no"
    ' sh "$APP_VERSION" "$REPO_URL" > "${WORK_DIR}/git-info.txt" \
        || die "git clone of tag v${APP_VERSION} failed; no COMPARISON_RESULTS.yaml written"
    APP_COMMIT=$(sed -n 's/^commit=//p' "${WORK_DIR}/git-info.txt")
    echo "Commit: ${APP_COMMIT}"
}

# Pin the Dockerfile's one external base image to the digest it resolves to now (and use the
# fully qualified name, since podman refuses short names without a prompt).
pin_base_image() {
    local df="${WORK_DIR}/src/Dockerfile" base tag
    [[ -f "$df" ]] || die "No Dockerfile at tag v${APP_VERSION}; update this script"
    cp "$df" "${WORK_DIR}/Dockerfile.upstream"
    base=$(awk 'toupper($1)=="FROM"{img=$2; for(i=2;i<=NF;i++) if($i!~/^--/){img=$i;break}
        if(!(img in st)) print img; for(i=1;i<=NF;i++) if(toupper($i)=="AS") st[$(i+1)]=1}' "$df")
    [[ $(printf '%s\n' "$base" | grep -c .) -eq 1 ]] || die "Expected one external FROM image, found: ${base//$'\n'/ }; update this script"
    [[ "$base" =~ ^(docker\.io/)?(library/)?node:([A-Za-z0-9._-]+)$ ]] || die "Base image '$base' is not node:<tag>; update this script"
    tag="${BASH_REMATCH[3]}"
    echo "Upstream base image: ${base}"
    "$DOCKER_CMD" pull -q --platform linux/amd64 "docker.io/library/node:${tag}" >/dev/null \
        || die "Could not pull docker.io/library/node:${tag}; no COMPARISON_RESULTS.yaml written"
    NODE_REF="docker.io/library/node:${tag}"
    local d
    d=$(helper online registry library/node "$tag" amd64) || die "Registry lookup for node:${tag} failed; no COMPARISON_RESULTS.yaml written"
    NODE_REF="docker.io/library/node@${d#* }"
    "$DOCKER_CMD" pull -q --platform linux/amd64 "$NODE_REF" >/dev/null || die "Could not pull ${NODE_REF}"
    sed -i -E "s#^([Ff][Rr][Oo][Mm][[:space:]]+(--[^[:space:]]+[[:space:]]+)*)${base//./\\.}([[:space:]]|\$)#\\1${NODE_REF}\\3#" "$df"
    grep -q "$NODE_REF" "$df" || die "Could not pin the base image in the Dockerfile"
    echo "Pinned base image: ${NODE_REF}"
}

# A --binary image must be the one published for this version and type, or any verdict on it is false.
check_binary_is_official() {
    local d
    d=$(helper online registry "$IMAGE_REPO" "$1" amd64) \
        || die "Registry lookup for ${IMAGE_REPO}:${1} failed; no COMPARISON_RESULTS.yaml written"
    INDEX_DIGEST="${d% *}"
    helper online imagelayers "$IMAGE_REPO" "${d#* }" > "${WORK_DIR}/published-layers.txt" \
        || die "Could not read the layers of ${IMAGE_REPO}:${1}; no COMPARISON_RESULTS.yaml written"
    helper none layers /w/official-inspect.json > "${WORK_DIR}/given-layers.txt" || die "Could not read the layers of the --binary image"
    cmp -s "${WORK_DIR}/published-layers.txt" "${WORK_DIR}/given-layers.txt" \
        || die "--binary is not docker.io/${IMAGE_REPO}:${1} linux/amd64 (${d#* }); check --version and --type" $EXIT_INVALID_PARAMS
    echo "--binary has the layers of docker.io/${IMAGE_REPO}:${1} linux/amd64 (${d#* })"
}

fetch_official() {
    local ref="" tagname
    [[ "$APP_TYPE" == base ]] && tagname="base-${APP_VERSION}" || tagname="${APP_VERSION}"
    if [[ -z "$BINARY_PATH" ]]; then
        local d
        d=$(helper online registry "$IMAGE_REPO" "$tagname" amd64) \
            || die "Registry lookup for ${IMAGE_REPO}:${tagname} failed; no COMPARISON_RESULTS.yaml written"
        INDEX_DIGEST="${d% *}"
        APP_HASH="${d#* }"
        ref="docker.io/${IMAGE_REPO}@${APP_HASH}"
        echo "Official image: docker.io/${IMAGE_REPO}:${tagname} (index ${INDEX_DIGEST}, linux/amd64 ${APP_HASH})"
        # Pulling by digest makes the runtime check the content against the published digest.
        "$DOCKER_CMD" pull -q --platform linux/amd64 "$ref" >/dev/null \
            || die "Could not pull ${ref}; no COMPARISON_RESULTS.yaml written"
    else
        local src="$BINARY_PATH" out
        if [[ -d "$src" && -f "$src/index.json" && -f "$src/oci-layout" ]]; then
            [[ "$(basename "$DOCKER_CMD")" == podman* ]] || die "An OCI layout directory needs podman; pass a 'docker save' archive instead" $EXIT_INVALID_PARAMS
            APP_HASH=$(grep -oE '"digest" *: *"sha256:[0-9a-f]{64}"' "$src/index.json" | head -1 | grep -oE 'sha256:[0-9a-f]{64}')
            out=$("$DOCKER_CMD" pull -q "oci:${src}") || die "Could not load OCI layout ${src}" $EXIT_INVALID_PARAMS
            ref=$(printf '%s\n' "$out" | tail -1)
        else
            if [[ -d "$src" ]]; then
                local -a tars=("$src"/*.tar)
                [[ ${#tars[@]} -eq 1 && -f "${tars[0]}" ]] || die "--binary directory must hold one image .tar or an OCI layout" $EXIT_INVALID_PARAMS
                src="${tars[0]}"
            fi
            APP_HASH="sha256:$(sha256sum "$src" | cut -d' ' -f1)"
            out=$("$DOCKER_CMD" load -i "$src") || die "Could not load image archive ${src}" $EXIT_INVALID_PARAMS
            ref=$(printf '%s\n' "$out" | sed -n 's/^Loaded image[^:]*: *//p' | tail -1)
            [[ $(printf '%s\n' "$out" | grep -c '^Loaded image') -eq 1 ]] || die "Image archive must hold exactly one image" $EXIT_INVALID_PARAMS
        fi
        [[ -n "$ref" ]] || die "Could not tell which image --binary loaded" $EXIT_INVALID_PARAMS
        echo "Official image: given with --binary (${src}), loaded as ${ref}"
    fi
    "$DOCKER_CMD" image inspect "$ref" > "${WORK_DIR}/official-inspect.json" || die "Could not inspect the official image ${ref}"
    local arch
    arch=$("$DOCKER_CMD" image inspect --format '{{.Architecture}}' "$ref") || die "Could not read the official image's architecture"
    [[ "$arch" == amd64 ]] || die "Official image is ${arch}, not amd64" $EXIT_INVALID_PARAMS
    [[ -z "$BINARY_PATH" ]] || check_binary_is_official "$tagname"
    IMAGE_ID=$("$DOCKER_CMD" image inspect --format '{{.Id}}' "$ref") || die "Could not read the official image's ID"
    IMAGE_ID="sha256:${IMAGE_ID#sha256:}"
    OFF_CTR="thunderhub-official-${SUFFIX}"
    "$DOCKER_CMD" create --name "$OFF_CTR" "$ref" >/dev/null || die "Could not create a container from the official image"
}

write_ftbfs() {
    printf 'script_version: %s\nverdict: ftbfs\nnotes: "%s"\n' "$SCRIPT_VERSION" "$1" > "$RESULTS_FILE"
    display_results ftbfs
}

# True only for a source failure; see COMPILE_ERRORS and FILE_LIMIT_ERROR.
has_compile_error() {
    grep -q "$FILE_LIMIT_ERROR" "${WORK_DIR}/build.log" && return 1
    grep -qE "$COMPILE_ERRORS" "${WORK_DIR}/build.log"
}

build_image() {
    # nofile: at podman's default of 1024, Vite failed 5 of 6 attempts with a false import error; at 65536, 0 of 6.
    local -a args=(build --platform linux/amd64 --no-cache --ulimit nofile=65536:65536 -f "${WORK_DIR}/src/Dockerfile" -t "$BUILT_IMAGE")
    [[ "$APP_TYPE" == base ]] && args+=(--build-arg BASE_PATH=/thub)
    # --layers=false: podman would otherwise leave each stage behind as untagged images.
    if [[ "$(basename "$DOCKER_CMD")" == podman* ]]; then args+=(--layers=false); else args+=(--progress=plain); fi
    echo ""
    echo "Building ${IMAGE_REPO} ${APP_VERSION} (${APP_TYPE}) for linux/amd64..."
    # Build and tee run as jobs, so a stop interrupts wait at once and the EXIT trap can end the build.
    mkfifo "${WORK_DIR}/build.fifo"
    tee "${WORK_DIR}/build.log" < "${WORK_DIR}/build.fifo" &
    TEE_PID=$!
    "$DOCKER_CMD" "${args[@]}" "${WORK_DIR}/src" > "${WORK_DIR}/build.fifo" 2>&1 &
    BUILD_PID=$!
    local rc=0
    wait "$BUILD_PID" || rc=$?
    BUILD_PID=""
    wait "$TEE_PID" || true
    TEE_PID=""
    rm -f "${WORK_DIR}/build.fifo"
    if [[ "$rc" -ne 0 ]]; then
        if has_compile_error; then
            write_ftbfs "Upstream source failed to compile at tag v${APP_VERSION} (${APP_TYPE}); see build.log."
        fi
        die "Image build failed with no compile error (network, memory or tooling); no COMPARISON_RESULTS.yaml written"
    fi
    "$DOCKER_CMD" image inspect "$BUILT_IMAGE" > "${WORK_DIR}/built-inspect.json" || die "Could not inspect the built image"
    BLD_CTR="thunderhub-built-${SUFFIX}"
    "$DOCKER_CMD" create --name "$BLD_CTR" "$BUILT_IMAGE" >/dev/null || die "Could not create a container from the built image"
}

compare_images() {
    echo ""
    echo "Exporting and listing both root filesystems..."
    local side ctr
    for side in official built; do
        [[ "$side" == official ]] && ctr="$OFF_CTR" || ctr="$BLD_CTR"
        "$DOCKER_CMD" export "$ctr" > "${WORK_DIR}/${side}-rootfs.tar" || die "export of the ${side} container failed"
        helper none tarlist "/w/${side}-rootfs.tar" > "${WORK_DIR}/${side}-rootfs.list" || die "listing the ${side} root filesystem failed"
        helper none config "/w/${side}-inspect.json" > "${WORK_DIR}/${side}-config.txt" || die "reading the ${side} image config failed"
        helper none layers "/w/${side}-inspect.json" > "${WORK_DIR}/${side}-layers.txt" || die "reading the ${side} layers failed"
        rm -f "${WORK_DIR}/${side}-rootfs.tar"
    done
    "$DOCKER_CMD" image inspect "$NODE_REF" > "${WORK_DIR}/node-inspect.json" || die "Could not inspect ${NODE_REF}"
    helper none layers /w/node-inspect.json > "${WORK_DIR}/node-layers.txt" || die "Could not read the layers of ${NODE_REF}"

    # The two outputs upstream's 'build:nest & build:client & wait' must leave; wait hides a failed half.
    local f
    for f in app/dist/main.js app/src/client/dist/index.html; do
        grep -q "^${f}"$'\t' "${WORK_DIR}/built-rootfs.list" && continue
        if has_compile_error; then
            write_ftbfs "Build finished without ${f} after a compile error; upstream's 'wait' ignores its exit status."
        fi
        die "Build finished without ${f} and with no compile error; no COMPARISON_RESULTS.yaml written"
    done

    local counts total ndiff
    counts=$(helper none compare /w/official-rootfs.list /w/built-rootfs.list 2>&1 >"${WORK_DIR}/filesystem-diff.txt" | tail -1) || true
    total="${counts% *}"; ndiff="${counts#* }"
    [[ "$total" =~ ^[0-9]+$ && "$ndiff" =~ ^[0-9]+$ ]] || die "Comparison failed: ${counts}"
    FS_TOTAL="$total"; FS_DIFF="$ndiff"
    FS_MATCH=true; [[ "$ndiff" -eq 0 ]] || FS_MATCH=false
    APP_DIFF=$(grep -cE '^[A-Z_]+ app(/|$)' "${WORK_DIR}/filesystem-diff.txt" || true)

    CONFIG_MATCH=true
    diff "${WORK_DIR}/official-config.txt" "${WORK_DIR}/built-config.txt" > "${WORK_DIR}/config-diff.txt" || CONFIG_MATCH=false
    local nbase
    nbase=$(grep -c . "${WORK_DIR}/node-layers.txt")
    BASE_MATCH=false
    head -n "$nbase" "${WORK_DIR}/official-layers.txt" | cmp -s - "${WORK_DIR}/node-layers.txt" && BASE_MATCH=true
    [[ "$BASE_MATCH" == true ]] || warn "The node tag no longer points at the official image's base; differences outside /app may come from that"
    LAYERS_MATCH=false
    cmp -s "${WORK_DIR}/official-layers.txt" "${WORK_DIR}/built-layers.txt" && LAYERS_MATCH=true

    echo ""
    echo "Root filesystem: ${FS_TOTAL} entries compared, ${FS_DIFF} differ (${APP_DIFF} under /app)"
    if [[ "$FS_DIFF" -gt 0 ]]; then
        echo "First differences (full list: ${WORK_DIR}/filesystem-diff.txt):"
        grep -E '^[A-Z_]+ ' "${WORK_DIR}/filesystem-diff.txt" | head -5 | sed 's/^/  /'
    fi
    echo "Image config: $([[ "$CONFIG_MATCH" == true ]] && echo identical || echo "differs (${WORK_DIR}/config-diff.txt)")"
    echo "Official base layers equal ${NODE_REF}: ${BASE_MATCH}"
    echo "Layer digests identical (not gated; mtimes differ per build): ${LAYERS_MATCH}"

    local status
    if [[ "$FS_MATCH" == true && "$CONFIG_MATCH" == true ]]; then status=reproducible; else status=not_reproducible; fi
    cat > "$RESULTS_FILE" << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  Built tag v${APP_VERSION} (${APP_COMMIT}) with upstream's Dockerfile for linux/amd64, type ${APP_TYPE},
  base pinned to ${NODE_REF}, open-file limit raised to 65536. Compared the exported root filesystem of the official image
  (appHash ${APP_HASH}) with the rebuilt one: every entry's path, type, content hash, mode, owner and
  link target; not mtimes, not runtime paths (etc/hosts, etc/hostname, etc/resolv.conf, etc/mtab, .dockerenv,
  .containerenv, run/.containerenv, contents of dev, proc and sys). Image config
  compared on Env, Entrypoint, Cmd, User, WorkingDir, ports, volumes, labels (builder label dropped).
  Layer digests are reported, not gated: BuildKit keeps build-time mtimes in every layer.
  filesystem=${FS_MATCH} entries=${FS_TOTAL} differ=${FS_DIFF} app_differ=${APP_DIFF} config=${CONFIG_MATCH} base_layers_match=${BASE_MATCH} layers_identical=${LAYERS_MATCH}
YAML_END
    display_results "$status"
}

display_results() {
    local verdict="$1" flags
    flags=$(grep -E '^  filesystem=' "$RESULTS_FILE" | sed 's/^ *//' || true)
    echo ""
    echo "======================================================"
    echo "RESULTS"
    echo "======================================================"
    cat "$RESULTS_FILE"
    echo ""
    echo "===== Begin Results ====="
    echo "appId: ${APP_ID}"
    echo "signer: N/A"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict: ${verdict}"
    echo "appHash: ${APP_HASH}"
    echo "commit: ${APP_COMMIT}"
    echo "scriptVersion: ${SCRIPT_VERSION}"
    echo "scriptHash: ${SCRIPT_HASH}"
    echo ""
    echo "Diff:"
    if [[ -s "${WORK_DIR}/filesystem-diff.txt" ]]; then
        grep -E '^[A-Z_]+ ' "${WORK_DIR}/filesystem-diff.txt" | head -5
    else
        echo "${flags:-$verdict}"
    fi
    echo ""
    echo "===== End Results ====="
    echo "appHash = linux/amd64 manifest digest on Docker Hub (or sha256 of the --binary archive, or the"
    echo "  manifest digest in its OCI index.json); publish this one."
    echo "imageId (config digest, same in every format): ${IMAGE_ID}"
    echo "indexDigest (multi-arch list, not compared): ${INDEX_DIGEST}"
    echo "Tag and signatures: $(grep -E '^(tag_type|tag_signed|commit_signed)=' "${WORK_DIR}/git-info.txt" 2>/dev/null | tr '\n' ' ')"
    echo "Upstream skips in build log: $(grep -ci 'skip' "${WORK_DIR}/build.log" 2>/dev/null; true) line(s) mention 'skip'"
    echo "Workspace: ${WORK_DIR} (build.log, filesystem-diff.txt, config-diff.txt)"
    echo "YAML: ${RESULTS_FILE}"
    echo ""
    if [[ "$verdict" == "reproducible" ]]; then
        echo "✅ VERDICT: REPRODUCIBLE"
        exit $EXIT_SUCCESS
    fi
    echo "❌ VERDICT: ${verdict^^}"
    exit $EXIT_BUILD_FAILED
}

main() {
    SCRIPT_HASH=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1) || true
    SCRIPT_HASH="${SCRIPT_HASH:-N/A}"
    echo "$(basename "$0") ${SCRIPT_VERSION} sha256: ${SCRIPT_HASH}"
    echo ""

    [[ "$(id -u)" -ne 0 ]] || die "Refusing to run as root; run as a normal user" $EXIT_INVALID_PARAMS
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    parse_arguments "$@"
    detect_container_cmd
    rm -f "$RESULTS_FILE"

    SUFFIX="$(date +%s)-$$"
    WORK_DIR="${EXEC_DIR}/thunderhub_verification_${APP_VERSION}_${APP_TYPE}_${SUFFIX}"
    # Exclusive: never reuse or delete a workspace another run may own.
    mkdir "$WORK_DIR" || die "Cannot create a new workspace at $WORK_DIR" $EXIT_INVALID_PARAMS
    echo "Workspace: $WORK_DIR"
    BUILT_IMAGE="localhost/thunderhub-verify:${APP_VERSION}-${APP_TYPE}-${SUFFIX}"

    write_helper
    clone_source
    pin_base_image
    fetch_official
    build_image
    compare_images
}

main "$@"
