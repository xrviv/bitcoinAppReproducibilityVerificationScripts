#!/bin/bash
# coinwallet_build.sh — Coin Wallet desktop (Linux Flatpak) reproducible build verification
# Version: v0.1.7
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-11-04
# Project: https://github.com/CoinSpace/CoinSpace
# Disclaimer: for reproducible-build verification and research only. No warranty; users assume all risk and are responsible for legal compliance; the developers assume no liability for misuse.
# Steps: take the official Coin.Wallet.flatpak (--binary or the GitHub release, checked against the
# release's published sha256), import it into an ostree repo and read from it the runtime, SDK and
# BaseApp commits it was built against and the build variables CI baked into the JS bundle. Clone the
# tag in a container, pack the @coinspace/* wallet modules from their public git tags (upstream installs
# them from GitHub Packages, which needs a login), build the web bundle and the Flatpak with upstream's
# npm scripts and electron-forge maker in an Ubuntu 24.04 container against the same Flathub commits,
# then compare both Flatpak trees file by file (content, mode, owner, link target), write
# COMPARISON_RESULTS.yaml next to the script.
# Supported: x86_64-linux, type flatpak. macOS dmg/zip are signed and notarized on macOS: not covered.
# Design notes: script-notes/desktop/coinwallet/changelog.md
# Exit codes: 0 = reproducible, 1 = not_reproducible or ftbfs, 2 = invalid parameters, 130 = stopped.
set -euo pipefail

SCRIPT_VERSION="v0.1.7"
APP_ID="coinwallet"
GH_REPO="CoinSpace/CoinSpace"
REPO_URL="https://github.com/${GH_REPO}.git"
ASSET_NAME="Coin.Wallet.flatpak"
FLATPAK_REF="app/space.coin.wallet/x86_64/stable"
FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"
# CI: ubuntu-24.04 runner, setup-node 22 (22.23.3 was current when v6.31.0 was built on 2026-10-19).
UBUNTU_IMAGE="docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852"
NODE_IMAGE="docker.io/library/node:22.23.3-bookworm@sha256:69a5713e7f4997e96d579aafd78734810e0dac0dd5ee4621d72c27a2891a4088"
GIT_IMAGE="docker.io/alpine/git:v2.54.0@sha256:ac6c828f15d82775d204d3d75112e1d34af8945da80ccf922713c9891ba68e7a"
# monero-core-js's CI uses emscripten/emsdk:2.0.20; pinned and fully qualified here.
EMSDK_IMAGE="docker.io/emscripten/emsdk:2.0.20@sha256:052d71743ca6d4be41b87a3b2fdff9622e4ab7cdfb6d1c3205385ddfc238c08a"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

DOCKER_CMD="${DOCKER_CMD:-}"
APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
BINARY_PATH=""
KEEP_IMAGE=false
EXEC_DIR="$(pwd -P)"
RESULTS_FILE="$(dirname "$(readlink -f "$0")")/COMPARISON_RESULTS.yaml"
WORK_DIR=""
SUFFIX=""
TOOL_IMAGE=""
MONERO_SRC=""
APP_HASH="N/A"
APP_COMMIT="N/A"
OFFICIAL_COMMIT="N/A"
OFFICIAL_SDE=""
SCRIPT_HASH="N/A"
JOB_PID=""
JOB_TEE=""
JOB_CTR=""
declare -a USER_FLAGS=()
# Source failures only. Network, memory and registry errors must never become ftbfs: ABS publishes any YAML.
COMPILE_ERRORS='error TS[0-9]+|error during build|\.(c|cc|cpp|h|hpp):[0-9]+(:[0-9]+)?: (fatal )?error:|wasm-ld: error:'
# Vite reports running out of file handles as a failed import, so these never count as a source failure.
ENV_ERRORS='failed to resolve import|heap out of memory|ENOMEM|ENOSPC|No space left|EMFILE|ENFILE|[Tt]oo many open files'

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

warn() {
    echo "WARN: $1" >&2
}

# True only for a source failure in this log; see COMPILE_ERRORS and ENV_ERRORS.
has_compile_error() {
    grep -qE "$ENV_ERRORS" "$1" && return 1
    grep -qE "$COMPILE_ERRORS" "$1"
}

# job LOG yes|no COMMAND...: long steps run as jobs, so a stop interrupts wait at once and the EXIT trap
# can end them. 'yes' also shows the output.
job() {
    local log="$1" show="$2" rc=0
    shift 2
    mkfifo "${WORK_DIR}/job.fifo"
    if [[ "$show" == yes ]]; then tee "$log" < "${WORK_DIR}/job.fifo" & else cat > "$log" < "${WORK_DIR}/job.fifo" & fi
    JOB_TEE=$!
    "$@" > "${WORK_DIR}/job.fifo" 2>&1 &
    JOB_PID=$!
    wait "$JOB_PID" || rc=$?
    JOB_PID=""
    wait "$JOB_TEE" || true
    JOB_TEE=""
    rm -f "${WORK_DIR}/job.fifo"
    return "$rc"
}

cleanup() {
    set +e
    # A stop during a long step: end its container, then its client, before touching the workspace.
    [[ -n "$JOB_CTR" && -n "$DOCKER_CMD" ]] && "$DOCKER_CMD" rm -f "$JOB_CTR" >/dev/null 2>&1
    if [[ -n "$JOB_PID" ]]; then
        kill -TERM "$JOB_PID" 2>/dev/null
        local i
        for i in {1..30}; do
            kill -0 "$JOB_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$JOB_PID" 2>/dev/null
    fi
    [[ -n "$JOB_TEE" ]] && kill "$JOB_TEE" 2>/dev/null
    restore_monero_owner
    # flatpak and ostree leave read-only directories; make the workspace deletable again.
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && chmod -R u+w "$WORK_DIR" 2>/dev/null
    [[ -n "$DOCKER_CMD" && "$KEEP_IMAGE" != true ]] || return 0
    [[ -n "$TOOL_IMAGE" ]] && "$DOCKER_CMD" rmi -f "$TOOL_IMAGE" >/dev/null 2>&1
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
    # Every container runs as the caller, so every file in the workspace stays the caller's.
    # monero-core-js is the exception: see build_monero_core and restore_monero_owner.
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
    echo "Usage: $0 --version X.Y.Z [--arch x86_64-linux] [--type flatpak] [--binary Coin.Wallet.flatpak|DIR]"
    echo "  --binary  the official ${ASSET_NAME}, or a directory holding exactly one .flatpak."
    echo "            Without it the file is downloaded from the GitHub release v<version>."
    echo "  GITHUB_TOKEN is used for the one GitHub API call when set; it is never required."
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
            --keep-image) KEEP_IMAGE=true; shift ;;
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
        x86_64-linux|x86_64-linux-gnu|x86_64|amd64|linux/amd64) APP_ARCH="x86_64-linux" ;;
        *) die "Unsupported --arch '$APP_ARCH' (the Flatpak is published for x86_64-linux only)" $EXIT_INVALID_PARAMS ;;
    esac

    if [[ -z "$APP_TYPE" ]]; then
        warn "No --type given; using flatpak"
        APP_TYPE="flatpak"
    fi
    case "$APP_TYPE" in
        flatpak) ;;
        dmg|zip|apk) die "--type $APP_TYPE is not covered: only the Linux Flatpak can be rebuilt here" $EXIT_INVALID_PARAMS ;;
        *) die "Invalid --type '$APP_TYPE' (must be flatpak)" $EXIT_INVALID_PARAMS ;;
    esac

    if [[ -n "$BINARY_PATH" ]]; then
        [[ -e "$BINARY_PATH" ]] || die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
        BINARY_PATH=$(realpath "$BINARY_PATH")
        if [[ -d "$BINARY_PATH" ]]; then
            local -a found=("$BINARY_PATH"/*.flatpak)
            [[ ${#found[@]} -eq 1 && -f "${found[0]}" ]] || die "--binary directory must hold exactly one .flatpak" $EXIT_INVALID_PARAMS
            BINARY_PATH="${found[0]}"
        fi
    fi
    [[ "$(uname -m)" == "x86_64" ]] || die "This script needs an x86_64 host (no emulation)" $EXIT_INVALID_PARAMS
}

# Node helper: release lookup, build variables, Flathub pins and the @coinspace packages.
write_helper() {
    cat > "${WORK_DIR}/helper.mjs" << 'HELPER_END'
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
const [cmd, ...args] = process.argv.slice(2);

// "<sha256> <url>" of one asset in the GitHub release JSON.
function asset(file, name) {
  const a = (JSON.parse(fs.readFileSync(file, 'utf8')).assets || []).find(x => x.name === name);
  if (!a) throw new Error(`release has no asset ${name}`);
  if (!/^sha256:[0-9a-f]{64}$/.test(a.digest || '')) throw new Error(`release lists no sha256 for ${name}`);
  console.log(`${a.digest.slice(7)} ${a.browser_download_url}`);
}

// Vite inlines the whole import.meta.env object into main-*.js; read every VITE_* value back.
function envobj(file) {
  const js = fs.readFileSync(file, 'utf8');
  const start = js.indexOf('{VITE_BUILD_TYPE:"');
  if (start < 0) throw new Error('no build variable object in the official bundle');
  const obj = js.slice(start, js.indexOf('}', start));
  const out = [];
  for (const m of obj.matchAll(/(VITE_[A-Z0-9_]+):"((?:[^"\\]|\\.)*)"/g)) {
    const v = JSON.parse(`"${m[2]}"`);
    if (/[\n\r]/.test(v)) throw new Error(`${m[1]} holds a newline`);
    out.push(`${m[1]}=${v}`);
  }
  if (!out.length) throw new Error('build variable object is empty');
  process.stdout.write(out.join('\n') + '\n');
}

// Runtime, SDK and BaseApp refs at the commits flatpak-builder recorded in /app/manifest.json.
function pins(file) {
  const m = JSON.parse(fs.readFileSync(file, 'utf8'));
  const rows = [[`runtime/${m.runtime}/x86_64/${m['runtime-version']}`, m['runtime-commit']],
    [`runtime/${m.sdk}/x86_64/${m['runtime-version']}`, m['sdk-commit']],
    [`app/${m.base}/x86_64/${m['base-version']}`, m['base-commit']]];
  for (const [ref, c] of rows) if (!/^[0-9a-f]{64}$/.test(c || '') || ref.includes('undefined')) throw new Error(`manifest lacks a pin for ${ref}`);
  process.stdout.write(rows.map(r => r.join(' ')).join('\n') + '\n');
}

// source-date-epoch recorded in /app/manifest.json.
function sde(file) {
  const v = JSON.parse(fs.readFileSync(file, 'utf8'))['source-date-epoch'];
  if (!/^[0-9]+$/.test(String(v))) throw new Error('manifest has no source-date-epoch');
  console.log(v);
}

// Lockfile entries served by npm.pkg.github.com (login required): 'clone' checks out each package's
// public git tag v<version>; 'pack' packs those checkouts and re-points the lockfile at the tarballs.
function pkgs(lockPath, outDir, phase) {
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  outDir = path.resolve(outDir);
  fs.mkdirSync(outDir, { recursive: true });
  for (const [key, e] of Object.entries(lock.packages || {})) {
    if (!/^https:\/\/npm\.pkg\.github\.com\//.test(e.resolved || '')) continue;
    const name = key.split('node_modules/').pop(), repo = name.split('/')[1];
    const dir = path.join(outDir, `src-${repo}`);
    if (phase === 'clone') {
      execFileSync('git', ['-c', 'advice.detachedHead=false', 'clone', '-q', '--depth', '1', '--branch', `v${e.version}`, `https://github.com/CoinSpace/${repo}.git`, dir], { stdio: 'inherit' });
      continue;
    }
    const commit = execFileSync('git', ['-C', dir, 'rev-parse', 'HEAD']).toString().trim();
    const pj = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
    if (pj.name.toLowerCase() !== name || pj.version !== e.version) throw new Error(`${repo} v${e.version} is ${pj.name}@${pj.version}`);
    const tgz = execFileSync('npm', ['pack', '--ignore-scripts', '--silent', '--pack-destination', outDir], { cwd: dir }).toString().trim().split('\n').pop();
    const file = path.join(outDir, tgz);
    const integrity = 'sha512-' + crypto.createHash('sha512').update(fs.readFileSync(file)).digest('base64');
    console.log(`${name}@${e.version} ${commit} ${integrity === e.integrity ? 'tarball-identical' : 'tarball-differs'}`);
    e.resolved = 'file:' + path.relative(path.dirname(lockPath), file);
    e.integrity = integrity;
  }
  if (phase === 'pack') fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n');
}

try {
  if (cmd === 'asset') asset(...args);
  else if (cmd === 'envobj') envobj(args[0]);
  else if (cmd === 'pins') pins(args[0]);
  else if (cmd === 'sde') sde(args[0]);
  else if (cmd === 'pkgs') pkgs(args[0], args[1], args[2]);
  else throw new Error(`unknown helper command ${cmd}`);
} catch (e) { console.error(`helper: ${e.message}`); process.exit(3); }
HELPER_END
}

# Ubuntu 24.04 like the CI runner, with flatpak tooling and Node from the pinned node image.
# librsvg2-common: flatpak build-export validates the SVG icon and needs this loader.
build_tool_image() {
    mkdir -p "${WORK_DIR}/toolctx"
    cat > "${WORK_DIR}/toolctx/Containerfile" << EOF
FROM ${NODE_IMAGE} AS node
FROM ${UBUNTU_IMAGE}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      flatpak flatpak-builder librsvg2-common ostree elfutils binutils git ca-certificates curl \\
      build-essential python3 patch unzip xz-utils bzip2 \\
    && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \\
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
EOF
    echo "Building the tool image (Ubuntu 24.04, flatpak-builder, Node 22.23.3)..."
    job "${WORK_DIR}/tool-image.log" no "$DOCKER_CMD" build -q -t "$TOOL_IMAGE" -f "${WORK_DIR}/toolctx/Containerfile" "${WORK_DIR}/toolctx" \
        || { tail -20 "${WORK_DIR}/tool-image.log"; die "Tool image build failed; no COMPARISON_RESULTS.yaml written"; }
}

# Run a bash snippet in the tool image as the caller: tool [run options --] snippet [args];
# the args become $1.. inside the snippet.
tool() {
    local -a extra=()
    local a
    for a in "$@"; do
        [[ "$a" == -- ]] || continue
        while [[ "$1" != -- ]]; do extra+=("$1"); shift; done
        shift; break
    done
    local snippet="$1"; shift
    "$DOCKER_CMD" run --rm "${extra[@]}" "${USER_FLAGS[@]}" -e HOME=/w/home -e TMPDIR=/w/tmp \
        -v "${WORK_DIR}:/w:z" -w /w "$TOOL_IMAGE" bash -c "mkdir -p /w/home /w/tmp; ${snippet}" bash "$@"
}

fetch_official() {
    local -a tok=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && tok=(-e GITHUB_TOKEN)
    tool "${tok[@]}" -- 'set -e
        h=(); [ -n "${GITHUB_TOKEN:-}" ] && h=(-H "Authorization: Bearer $GITHUB_TOKEN")
        curl -fsSL "${h[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$1/releases/tags/v$2" -o /w/release.json' \
        "$GH_REPO" "$APP_VERSION" || die "GitHub release v${APP_VERSION} lookup failed; no COMPARISON_RESULTS.yaml written"
    local info published url
    info=$(tool 'node /w/helper.mjs asset /w/release.json "$1"' "$ASSET_NAME") \
        || die "Release v${APP_VERSION} has no ${ASSET_NAME} with a published sha256; no COMPARISON_RESULTS.yaml written"
    published="${info%% *}"; url="${info#* }"
    mkdir -p "${WORK_DIR}/official"
    if [[ -n "$BINARY_PATH" ]]; then
        cp "$BINARY_PATH" "${WORK_DIR}/official/${ASSET_NAME}"
        echo "Official file: given with --binary (${BINARY_PATH})"
    else
        echo "Downloading ${url}..."
        tool 'curl -fsSL -o "/w/official/$2" "$1"' "$url" "$ASSET_NAME" \
            || die "Download of ${ASSET_NAME} failed; no COMPARISON_RESULTS.yaml written"
    fi
    APP_HASH=$(sha256sum "${WORK_DIR}/official/${ASSET_NAME}" | cut -d' ' -f1)
    echo "Official sha256:  ${APP_HASH}"
    echo "Published sha256: ${published}"
    [[ "$APP_HASH" == "$published" ]] \
        || die "Official file does not match the sha256 published on release v${APP_VERSION}; no COMPARISON_RESULTS.yaml written"
}

# Import a .flatpak into its own ostree repo and list every entry: path, type+mode, owner, size,
# content checksum or link target. Directories keep their metadata checksum, not their tree checksum,
# so one changed file is reported once.
import_bundle() {
    local side="$1" bundle="$2"
    tool 'set -e
        rm -rf "/w/$1-repo"; ostree init --repo="/w/$1-repo" --mode=archive
        flatpak build-import-bundle "/w/$1-repo" "$2" >/dev/null
        ref=$(ostree refs --repo="/w/$1-repo" | grep "^app/")
        [ "$ref" = "$3" ] || { echo "bundle holds ${ref:-no app}, expected $3" >&2; exit 4; }
        ostree show --repo="/w/$1-repo" "$ref" | sed -n "s/^ContentChecksum: *//p" > "/w/$1-content-checksum.txt"
        ostree cat --repo="/w/$1-repo" "$ref" /files/manifest.json > "/w/$1-manifest.json"
        ostree ls -R -C --repo="/w/$1-repo" "$ref" > "/w/$1-tree.raw"
        js=$(sed -nE "s#^-[0-7]+ .* (/files/lib/space\.coin\.wallet/resources/app/dist/assets/js/main-[0-9a-f]+\.js)\$#\1#p" "/w/$1-tree.raw")
        [ "$(printf "%s\n" "$js" | grep -c .)" = 1 ] || { echo "expected one main-*.js, found: $js" >&2; exit 5; }
        ostree cat --repo="/w/$1-repo" "$ref" "$js" > "/w/$1-main.js"' \
        "$side" "$bundle" "$FLATPAK_REF" || return 1
    sed -E -e 's/^(d[0-7]+ [0-9]+ [0-9]+) +[0-9]+ [0-9a-f]{64} ([0-9a-f]{64}) (.*)$/\3\t\1 meta:\2/' \
        -e 's/^([-l][0-7]+ [0-9]+ [0-9]+) +([0-9]+) ([0-9a-f]{64}) (.*)$/\4\t\1 \2 \3/' \
        "${WORK_DIR}/${side}-tree.raw" | LC_ALL=C sort > "${WORK_DIR}/${side}-tree.list"
}

read_official() {
    echo ""
    echo "Importing the official Flatpak..."
    import_bundle official "/w/official/${ASSET_NAME}" \
        || die "Could not import ${ASSET_NAME} as a ${FLATPAK_REF} Flatpak bundle; no COMPARISON_RESULTS.yaml written"
    tool 'node /w/helper.mjs pins /w/official-manifest.json > /w/pins.txt && node /w/helper.mjs envobj /w/official-main.js > /w/official-env.list && node /w/helper.mjs sde /w/official-manifest.json > /w/official-sde.txt' \
        || die "Could not read the Flathub pins, build variables or source-date-epoch from the official Flatpak; no COMPARISON_RESULTS.yaml written"
    OFFICIAL_SDE=$(cat "${WORK_DIR}/official-sde.txt")
    OFFICIAL_COMMIT=$(sed -n 's/^VITE_COMMIT=//p' "${WORK_DIR}/official-env.list")
    echo "Flathub pins from the official manifest.json:"
    sed 's/^/  /' "${WORK_DIR}/pins.txt"
    echo "Official bundle: VITE_COMMIT=${OFFICIAL_COMMIT}, $(grep -E '^VITE_(VERSION|DISTRIBUTION)=' "${WORK_DIR}/official-env.list" | tr '\n' ' ')"
    echo "Build variables recovered: $(grep -c . "${WORK_DIR}/official-env.list") (official-env.list; values are public in the shipped bundle)"
    grep -qx "VITE_VERSION=${APP_VERSION}" "${WORK_DIR}/official-env.list" \
        || die "Official Flatpak was not built as ${APP_VERSION} (VITE_VERSION differs); no COMPARISON_RESULTS.yaml written"
    grep -qx "VITE_DISTRIBUTION=flatpak" "${WORK_DIR}/official-env.list" \
        || die "Official file was not built for the flatpak distribution; no COMPARISON_RESULTS.yaml written"
}

clone_source() {
    echo ""
    echo "Cloning ${REPO_URL} at v${APP_VERSION} (in container)..."
    "$DOCKER_CMD" run --rm "${USER_FLAGS[@]}" -e HOME=/tmp -v "${WORK_DIR}:/w:z" --entrypoint sh "$GIT_IMAGE" -c '
        set -e
        git clone --quiet --depth 1 --branch "v$1" "$2" /w/src
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
    [[ "$OFFICIAL_COMMIT" == "$APP_COMMIT" ]] || warn "Official bundle says it was built from ${OFFICIAL_COMMIT}, the tag is ${APP_COMMIT}"
}

pack_coinspace_modules() {
    echo ""
    echo "Cloning the @coinspace/* modules at their public git tags..."
    tool 'node /w/helper.mjs pkgs /w/src/web/package-lock.json /w/coinspace-pkgs clone' > /dev/null \
        || die "Could not clone the @coinspace modules from GitHub; no COMPARISON_RESULTS.yaml written"
    build_monero_core
    tool 'node /w/helper.mjs pkgs /w/src/web/package-lock.json /w/coinspace-pkgs pack' > "${WORK_DIR}/coinspace-pkgs.txt" \
        || die "Could not pack the @coinspace modules; no COMPARISON_RESULTS.yaml written"
    echo "Packed (tarball-identical = same sha512 as upstream's lockfile):"
    sed 's/^/  /' "${WORK_DIR}/coinspace-pkgs.txt"
}

# Docker only: the monero-core-js containers run as root. Under rootless Podman, root is the caller.
restore_monero_owner() {
    [[ -n "$MONERO_SRC" && "$(basename "${DOCKER_CMD:-podman}")" != podman* ]] || return 0
    "$DOCKER_CMD" run --rm -v "${MONERO_SRC}:/src:z" --entrypoint chown "$EMSDK_IMAGE" -R "$(id -u):$(id -g)" /src >/dev/null 2>&1 \
        || warn "Could not restore ownership of ${MONERO_SRC}"
}

monero_run() {
    local log="$1" rc=0
    shift
    JOB_CTR="coinwallet-monero-${SUFFIX}"
    job "$log" no "$DOCKER_CMD" run --rm --name "$JOB_CTR" -e EMSCRIPTEN=/emsdk/upstream/emscripten "$@" || rc=$?
    JOB_CTR=""
    return "$rc"
}

# @coinspace/monero-core-js publishes build/MoneroCoreJS{.js,.wasm,.asm.js}, compiled with Emscripten
# and not in git. Same steps as its .github/workflows/ci.yml: one container per step, as root, source
# mounted at /src. Source paths are compiled into the wasm, so the mount point reaches the output.
build_monero_core() {
    local m="${WORK_DIR}/coinspace-pkgs/src-monero-core-js"
    [[ -d "$m" ]] || return 0
    echo ""
    echo "Compiling @coinspace/monero-core-js (wasm and asm.js) with Emscripten 2.0.20, source at /src as in its CI..."
    MONERO_SRC="$m"
    local -a at_src=(-v "${m}:/src:z" "$EMSDK_IMAGE")
    local rc=0
    monero_run "${WORK_DIR}/monero-boost-download.log" "${at_src[@]}" sh -c '
        wget --progress=dot:mega https://archives.boost.io/release/1.76.0/source/boost_1_76_0.tar.gz
        mkdir -p ./contrib/boost-sdk
        tar zxf boost_1_76_0.tar.gz -C ./contrib/boost-sdk --strip-components=1
    ' || { tail -20 "${WORK_DIR}/monero-boost-download.log"; restore_monero_owner; die "Boost download failed; no COMPARISON_RESULTS.yaml written"; }
    monero_run "${WORK_DIR}/monero-boost.log" "${at_src[@]}" ./bin/build-boost-emscripten.sh \
        || { tail -20 "${WORK_DIR}/monero-boost.log"; restore_monero_owner; die "Boost build failed; no COMPARISON_RESULTS.yaml written"; }
    monero_run "${WORK_DIR}/monero-core-js-wasm.log" -e BUILD=production -e WASM=1 "${at_src[@]}" ./bin/build-emcpp.sh || rc=$?
    local log="${WORK_DIR}/monero-core-js-wasm.log"
    if [[ "$rc" -eq 0 ]]; then
        log="${WORK_DIR}/monero-core-js-asm.log"
        monero_run "$log" -e BUILD=production -e WASM=0 "${at_src[@]}" ./bin/build-emcpp.sh || rc=$?
    fi
    restore_monero_owner
    if [[ "$rc" -ne 0 ]]; then
        tail -20 "$log"
        if has_compile_error "$log"; then
            write_ftbfs "@coinspace/monero-core-js failed to compile from source; see $(basename "$log")."
        fi
        die "monero-core-js build failed with no compile error (network, memory or tooling); no COMPARISON_RESULTS.yaml written"
    fi
    # emcc leaves the wasm executable; at 0644 npm pack gives the sha512 in upstream's lockfile. Mode only.
    chmod 644 "$m/build/MoneroCoreJS.wasm"
    sha256sum "$m"/build/MoneroCoreJS.{js,wasm,asm.js} | sed "s#${m}/##; s/^/  /"
}

write_ftbfs() {
    printf 'script_version: %s\nverdict: ftbfs\nnotes: "%s"\n' "$SCRIPT_VERSION" "$1" > "$RESULTS_FILE"
    display_results ftbfs
}

build_flatpak() {
    mkdir -p "${WORK_DIR}/shim"
    # flatpak-bundler runs 'flatpak update <ref>' before building, which would move the pinned
    # runtimes to Flathub's latest commit.
    printf '#!/bin/sh\n[ "$1" = update ] && { echo "shim: skipped flatpak $*" >&2; exit 0; }\nexec /usr/bin/flatpak "$@"\n' > "${WORK_DIR}/shim/flatpak"
    # rofiles-fuse needs /dev/fuse; it only guards the build dir and does not change the output.
    # source-date-epoch defaults to the mtime of the manifest the maker writes, so to each build's time
    # (CoinSpace #90). Copied from the official manifest.json, like the Flathub commits: proves nothing about it.
    printf '#!/bin/sh\n[ "$1" = --version ] && exec /usr/bin/flatpak-builder "$@"\nexec /usr/bin/flatpak-builder --disable-rofiles-fuse --override-source-date-epoch=%s "$@"\n' "$OFFICIAL_SDE" > "${WORK_DIR}/shim/flatpak-builder"
    chmod +x "${WORK_DIR}/shim/flatpak" "${WORK_DIR}/shim/flatpak-builder"

    echo ""
    echo "Building ${ASSET_NAME} ${APP_VERSION} (web bundle, then electron-forge make with maker-flatpak)..."
    local rc=0
    # --privileged: flatpak-builder sandboxes every build step with bubblewrap.
    # nofile: Vite gave false import errors at Podman's default of 1024 on ThunderHub, same stack.
    # VITE_COMMIT is the tag commit, as CI sets it from github.sha.
    grep -v '^VITE_COMMIT=' "${WORK_DIR}/official-env.list" > "${WORK_DIR}/build-env.list"
    JOB_CTR="coinwallet-build-${SUFFIX}"
    job "${WORK_DIR}/build.log" yes tool --name "$JOB_CTR" --privileged --ulimit nofile=65536:65536 --env-file "${WORK_DIR}/build-env.list" \
        -e VITE_COMMIT="$APP_COMMIT" -e SENTRY_RELEASE="$APP_COMMIT" -e FLATHUB_URL="$FLATHUB_URL" -- '
        set -euo pipefail
        export PATH=/w/shim:$PATH
        git config --global protocol.file.allow always
        /usr/bin/flatpak remote-add --user --if-not-exists flathub "$FLATHUB_URL"
        # The parental controls check in Flatpak for app/ refs needs a system bus; this container has none.
        # This variable is the skip built into Flatpak. Without it BaseApp fails with: Could not connect.
        while read -r ref commit; do
            FLATPAK_SYSTEM_HELPER_ON_SESSION=1 /usr/bin/flatpak install --user -y --noninteractive --no-deps flathub "$ref" < /dev/null
            FLATPAK_SYSTEM_HELPER_ON_SESSION=1 /usr/bin/flatpak update --user -y --noninteractive --no-deps --commit="$commit" "$ref" < /dev/null
            got=$(/usr/bin/flatpak info --user --show-commit "$ref")
            [ "$got" = "$commit" ] || { echo "PIN_FAILED $ref is $got, wanted $commit"; exit 3; }
        done < /w/pins.txt
        cd /w/src
        NODE_ENV=ci npm --prefix web ci
        NODE_ENV=ci npm --prefix electron ci
        # As in CI: the Sentry plugin runs (debug IDs and release are injected into every chunk); its
        # uploads go to a closed local port and fail without stopping the build.
        export NODE_ENV=production NODE_OPTIONS=--max-old-space-size=3575 VITE_BUILD_TYPE=electron \
            VITE_PLATFORM=linux VITE_DISTRIBUTION=flatpak SENTRY_AUTH_TOKEN=offline \
            SENTRY_URL=http://127.0.0.1:9/ SENTRY_ORG=offline SENTRY_PROJECT=linux
        unset CI GITHUB_ACTIONS
        npm --prefix web run build
        find electron/dist -name "*.map" -delete
        cd electron
        # The bundler sends flatpak and flatpak-builder output to debug only; without this a failure
        # shows just a status code. Logging only.
        DEBUG=@malept/flatpak-bundler npm run make -- --platform=linux --arch=x64
    ' || rc=$?
    JOB_CTR=""
    if [[ "$rc" -ne 0 ]]; then
        grep -q '^PIN_FAILED' "${WORK_DIR}/build.log" \
            && die "Flathub no longer serves a pinned runtime commit ($(grep '^PIN_FAILED' "${WORK_DIR}/build.log")); no COMPARISON_RESULTS.yaml written"
        if has_compile_error "${WORK_DIR}/build.log"; then
            write_ftbfs "Tag v${APP_VERSION} failed to compile (web bundle); see build.log."
        fi
        die "Build failed with no compile error (network, memory, disk or sandbox); no COMPARISON_RESULTS.yaml written"
    fi
    local -a out
    mapfile -t out < <(find "${WORK_DIR}/src/electron/out/make" -name '*.flatpak' -type f)
    if [[ ${#out[@]} -ne 1 ]]; then
        if has_compile_error "${WORK_DIR}/build.log"; then
            write_ftbfs "Build finished without exactly one .flatpak (found ${#out[@]}) after a compile error; see build.log."
        fi
        die "Build finished without exactly one .flatpak (found ${#out[@]}) and with no compile error; no COMPARISON_RESULTS.yaml written"
    fi
    BUILT_FLATPAK="${out[0]}"
    echo "Built: ${BUILT_FLATPAK} sha256 $(sha256sum "$BUILT_FLATPAK" | cut -d' ' -f1)"
}

compare_trees() {
    echo ""
    echo "Importing the built Flatpak and comparing both trees..."
    import_bundle built "/w/${BUILT_FLATPAK#"${WORK_DIR}"/}" || die "Could not import the built Flatpak"
    awk -F'\t' 'NR==FNR { a[$1]=$2; next } { b[$1]=$2 }
        END { for (k in a) if (!(k in b)) print "ONLY_OFFICIAL " k "\n  official: " a[k]
              for (k in b) if (!(k in a)) print "ONLY_BUILT " k "\n  built:    " b[k]
              for (k in a) if ((k in b) && a[k] != b[k]) print "DIFFER " k "\n  official: " a[k] "\n  built:    " b[k] }' \
        "${WORK_DIR}/official-tree.list" "${WORK_DIR}/built-tree.list" > "${WORK_DIR}/filesystem-diff.txt"
    FS_TOTAL=$(cut -f1 "${WORK_DIR}/official-tree.list" "${WORK_DIR}/built-tree.list" | sort -u | grep -c .)
    FS_DIFF=$(grep -cE '^(ONLY_OFFICIAL|ONLY_BUILT|DIFFER) ' "${WORK_DIR}/filesystem-diff.txt" || true)
    APP_DIFF=$(grep -cE '^[A-Z_]+ /files/lib/space\.coin\.wallet/' "${WORK_DIR}/filesystem-diff.txt" || true)
    FS_MATCH=true; [[ "$FS_DIFF" -eq 0 ]] || FS_MATCH=false

    tool 'node /w/helper.mjs sde /w/built-manifest.json > /w/built-sde.txt' \
        || die "Could not read source-date-epoch from the built manifest.json"
    MANIFEST_MATCH=true
    local drc=0
    tool 'diff /w/official-manifest.json /w/built-manifest.json > /w/manifest-diff.txt' || drc=$?
    case "$drc" in
        0) ;;
        1) MANIFEST_MATCH=false ;;
        *) die "Could not compare the two manifest.json files; no COMPARISON_RESULTS.yaml written" ;;
    esac
    SDE="official ${OFFICIAL_SDE}, built $(cat "${WORK_DIR}/built-sde.txt")"
    COMMIT_MATCH=true; [[ "$OFFICIAL_COMMIT" == "$APP_COMMIT" ]] || COMMIT_MATCH=false
    CC_OFF=$(cat "${WORK_DIR}/official-content-checksum.txt"); CC_BLD=$(cat "${WORK_DIR}/built-content-checksum.txt")
    CONTENT_MATCH=true; [[ -n "$CC_OFF" && "$CC_OFF" == "$CC_BLD" ]] || CONTENT_MATCH=false

    echo ""
    echo "Flatpak tree: ${FS_TOTAL} entries compared, ${FS_DIFF} differ (${APP_DIFF} under /files/lib/space.coin.wallet)"
    if [[ "$FS_DIFF" -gt 0 ]]; then
        echo "First differences (full list: ${WORK_DIR}/filesystem-diff.txt):"
        grep -E '^[A-Z_]+ ' "${WORK_DIR}/filesystem-diff.txt" | head -5 | sed 's/^/  /'
    fi
    echo "manifest.json, byte for byte: $([[ "$MANIFEST_MATCH" == true ]] && echo identical || echo "differs (${WORK_DIR}/manifest-diff.txt)")"
    echo "source-date-epoch (built value copied from the official manifest.json): ${SDE}"
    echo "ostree content checksum (includes manifest.json): official ${CC_OFF}, built ${CC_BLD}"

    local status=not_reproducible
    [[ "$FS_MATCH" == true && "$MANIFEST_MATCH" == true && "$COMMIT_MATCH" == true && "$CONTENT_MATCH" == true ]] && status=reproducible
    cat > "$RESULTS_FILE" << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  Built tag v${APP_VERSION} (${APP_COMMIT}) as ${ASSET_NAME} with upstream's npm scripts and
  electron-forge maker-flatpak in Ubuntu 24.04 with Node 22.23.3, against the Flathub runtime, SDK and
  BaseApp commits recorded in the official manifest.json, open-file limit raised to 65536. Build variables (API hosts, Sentry DSN, keys)
  were read from the official bundle, where they are public; the official bundle names commit ${OFFICIAL_COMMIT}.
  The @coinspace/* modules were packed from their public git tags (upstream installs them from GitHub
  Packages, which needs a login). Compared every entry of both Flatpak trees: path, type, mode, owner,
  content checksum, link target, and the ostree content checksum. The built source-date-epoch was copied from the
  official manifest.json with --override-source-date-epoch, so a match proves nothing about it (${SDE}).
  tree=${FS_MATCH} entries=${FS_TOTAL} differ=${FS_DIFF} app_differ=${APP_DIFF} manifest=${MANIFEST_MATCH} content_checksum=${CONTENT_MATCH} official_commit_is_tag=${COMMIT_MATCH}
YAML_END
    display_results "$status"
}

display_results() {
    local verdict="$1" flags
    flags=$(grep -E '^  tree=' "$RESULTS_FILE" | sed 's/^ *//' || true)
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
    echo "appHash = sha256 of the official ${ASSET_NAME} as downloaded (equal to the sha256 GitHub lists); publish this one."
    echo "The built .flatpak's own sha256 is not comparable: a bundle carries ostree commit dates."
    echo "Tag and signatures: $(grep -E '^(tag_type|tag_signed|commit_signed)=' "${WORK_DIR}/git-info.txt" 2>/dev/null | tr '\n' ' ')"
    echo "@coinspace modules: $(grep -c 'tarball-identical' "${WORK_DIR}/coinspace-pkgs.txt" 2>/dev/null; true) of $(grep -c . "${WORK_DIR}/coinspace-pkgs.txt" 2>/dev/null; true) packed tarballs equal the published ones (coinspace-pkgs.txt)"
    echo "Upstream skips in build log: $(grep -ci 'skip' "${WORK_DIR}/build.log" 2>/dev/null; true) line(s) mention 'skip'"
    echo "Workspace: ${WORK_DIR} (build.log, filesystem-diff.txt, manifest-diff.txt, official-env.list)"
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
    # A stale YAML must never reach ABS. An invalid call exits earlier and leaves it alone.
    rm -f "$RESULTS_FILE"

    SUFFIX="$(date +%s)-$$"
    WORK_DIR="${EXEC_DIR}/coinwallet_verification_${APP_VERSION}_${SUFFIX}"
    # Exclusive: never reuse or delete a workspace another run may own.
    mkdir "$WORK_DIR" || die "Cannot create a new workspace at $WORK_DIR" $EXIT_INVALID_PARAMS
    echo "Workspace: $WORK_DIR"
    TOOL_IMAGE="localhost/coinwallet-verify-tools:${SUFFIX}"

    write_helper
    build_tool_image
    fetch_official
    read_official
    clone_source
    pack_coinspace_modules
    build_flatpak
    compare_trees
}

main "$@"
