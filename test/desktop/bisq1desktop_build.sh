#!/usr/bin/env bash
# ==============================================================================
# bisq1desktop_build.sh - Bisq 1 Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.10.0
# Organization:  WalletScrutiny.com
# Last Modified: 2026-09-12
# Project:       https://github.com/bisq-network/bisq
# ==============================================================================
# LICENSE: MIT License
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build
# verification purposes only. No warranty is provided regarding security,
# functionality, or fitness for any particular purpose. Users assume all
# risks associated with running this script and analyzing the software.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible
# build verification. Users are responsible for ensuring compliance with all
# applicable laws and regulations. The developers assume no liability for any
# misuse or legal consequences arising from use of this script.
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/desktop/bisq1/changelog.md
# ==============================================================================
#
# SCRIPT SUMMARY (v0.10.0 - bob): Bisq's own recipe (docs/reproducible-builds/linux.md), toolchain per tag.
#   deb/rpm: clone once (~1.8 GB), two local checkouts A/B + submodules; >=1.10.0 builds in the tag's own
#   docker/release-builder image (Zulu 21.0.6, SOURCE_DATE_EPOCH=0, apt snapshot): verifyReleaseBuild +
#   verifyInstallerEvidenceBundle (pre-1.10.4) or :desktop:<type> (1.10.4+: generateInstallers hard-fails for
#   DEB/RPM, and deb+rpm in ONE invocation loses the first via deleteExistingInstallerArtifacts). pre-1.10:
#   embedded Ubuntu 22.04 + Zulu 11/17 image. VERDICT is mechanical on the outer sha256: reproducible iff
#   rebuilt == official AND A==B. EVIDENCE only: dpkg-deb -R / rpm2cpio payload split, bundled JDK vs the
#   tag's Dockerfile pin (bisq#7930), gpg --verify vs desktop/package/*.asc. Engine: docker, or rootless
#   podman behind a `docker` shim (--userns=keep-id added when detected).
#   exe: jpackage+WiX cannot run on Linux; triggers bisq1-windows-build.yml on the WS fork (windows-2025,
#   Zulu 21.0.6, WiX v3, A/B), downloads both EXEs, same verdict; --built <dir> = offline. Needs GITHUB_TOKEN.
# ==============================================================================

set -euo pipefail
# Checkout files are packed into the Bisq jars with their on-disk mode. Upstream's release has 0644, an
# Ubuntu host with umask 002 gives 0664 and 5 jars differ for that reason alone (found at 1.10.7). Pin it.
umask 022

SCRIPT_VERSION="v0.10.0"
SCRIPT_NAME="bisq1desktop_build.sh"
APP_NAME="Bisq 1"
APP_ID="bisq"
REPO_URL="https://github.com/bisq-network/bisq"
DEFAULT_VERSION="1.10.7"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

BISQ_VERSION=""
BISQ_ARCH=""
BISQ_TYPE=""
OFFICIAL_BINARY=""
BUILT_DIR=""
NO_CACHE=false
KEEP_CONTAINER=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""

IMAGE_NAME=""
CONTAINER_A=""; CONTAINER_B=""; CONTAINER_CMP=""

NC="\033[0m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"; CYAN="\033[1;36m"
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { local m="$1"; local c="${2:-$EXIT_BUILD_FAILED}"; log_error "$m"; exit "$c"; }
YAML_OUT=""   # set by each path before use
ftbfs_die() { write_yaml "$YAML_OUT" ftbfs "$1"; die "$1"; }   # tool failure: ftbfs YAML + exit 1

VERIFY_SCRIPT=""
cleanup_on_exit() {
    if [[ "$KEEP_CONTAINER" != "true" ]]; then
        for c in "$CONTAINER_A" "$CONTAINER_B" "$CONTAINER_CMP"; do
            [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1 || true
        done
    fi
    [[ -n "${VERIFY_SCRIPT:-}" ]] && rm -f "$VERIFY_SCRIPT" 2>/dev/null || true
}
trap cleanup_on_exit EXIT INT TERM

sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input##-}"; input="${input%%-}"
    [[ -z "$input" ]] && input="na"
    echo "$input"
}

write_yaml() {  # out verdict notes
    local out="$1" verdict="$2" notes="${3:-}"
    if [[ -n "$notes" ]]; then
        { printf 'script_version: %s\n' "$SCRIPT_VERSION"
          printf 'verdict: %s\n' "$verdict"
          printf 'notes: |\n'
          printf '%s\n' "$notes" | sed 's/^/  /'; } > "$out"
    else
        printf 'script_version: %s\nverdict: %s\n' "$SCRIPT_VERSION" "$verdict" > "$out"
    fi
}

# --- Self-identification (2026-08-17 rule): hash THIS script, print name/version/sha256. ---
SCRIPT_PATH="$(readlink -f "$0")"
sha256_of() {  # never aborts under set -e; N/A on missing file
    [[ -f "$1" ]] || { echo "N/A"; return 0; }
    sha256sum "$1" | awk '{print $1}'
}
SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"

# Commit hash of the release tag without a local clone (exe path). Prefers the peeled
# annotated-tag commit; falls back to the tag ref itself (lightweight tags).
resolve_tag_commit() {
    local c
    c=$(git ls-remote "$REPO_URL" "refs/tags/${BISQ_VERSION}^{}" 2>/dev/null | awk '{print $1}')
    [[ -n "$c" ]] || c=$(git ls-remote "$REPO_URL" "refs/tags/${BISQ_VERSION}" 2>/dev/null | awk '{print $1}')
    echo "${c:-N/A}"
}

# Standardized WS verification summary (verification-result-summary-format.md). Stdout verdict
# wording differs from the YAML's on purpose: reproducible | differences found | BLANK (ftbfs).
emit_results_block() {  # yaml_verdict appHash commit
    local v
    case "$1" in
        reproducible)     v="reproducible" ;;
        not_reproducible) v="differences found" ;;
        *)                v="" ;;
    esac
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          ${APP_ID}"
    echo "signer:         N/A"
    echo "apkVersionName: ${BISQ_VERSION#v}"
    echo "apkVersionCode: N/A"
    echo "verdict:        ${v}"
    echo "appHash:        ${2:-N/A}"
    echo "commit:         ${3:-N/A}"
    echo "scriptVersion:  ${SCRIPT_VERSION}"
    echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
    echo "===== End Results ====="
}

# ---- WINDOWS EXE PATH (isolated from the deb/rpm logic; see header). Compares only, never builds here. ----
GH_REPO="${GH_REPO:-xrviv/WalletScrutinyCom}"
GH_WORKFLOW="bisq1-windows-build.yml"
GH_WORKFLOW_REF="${GH_WORKFLOW_REF:-master}"
# Tag is content-versioned: bump it whenever the Dockerfile changes so a stale cached image is never
# reused (:2 added p7zip-full + diffutils for the in-container A/B extraction diff — no host 7z needed).
GH_HELPER_IMAGE="bisq1-gh-helper:2"
GH_MOUNT_DIR=""

build_gh_helper() {
    log_info "Building gh helper container (debian:bookworm-slim + gh CLI + p7zip)..."
    docker build -t "$GH_HELPER_IMAGE" - <<'GHEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq unzip p7zip-full diffutils \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
GHEOF
}

# gh in the helper container: token passed by NAME (-e GITHUB_TOKEN, never in argv or logs); host uid:gid so
# downloads are user-owned; HOME=/work gives gh a writable config dir.
gh_c() {
    docker run --rm -e GITHUB_TOKEN -e HOME=/work \
        --user "$(id -u):$(id -g)" \
        -v "${GH_MOUNT_DIR}:/work" -w /work "$GH_HELPER_IMAGE" gh "$@"
}

# Trigger bisq1-windows-build.yml, wait, download both EXE artifacts into <artdir>/A and /B.
acquire_built_exes_via_ci() {
    local ver="$1" artdir="$2" yaml="$3"; YAML_OUT="$yaml"
    export GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    # Missing token / docker = infrastructure unavailable -> ftbfs + exit 1 (EXIT_BUILD_FAILED), same
    # class as the deb/rpm 'docker not found' path (exit 2 is reserved for invalid CLI parameters).
    [[ -n "$GITHUB_TOKEN" ]] || ftbfs_die "GITHUB_TOKEN/GH_TOKEN required to dispatch CI + read artifacts; or pass --built <dir>."
    command -v docker >/dev/null 2>&1 || ftbfs_die "docker required for the gh helper container."
    docker info >/dev/null 2>&1 || ftbfs_die "docker daemon not running."
    GH_MOUNT_DIR="$artdir"; mkdir -p "$artdir"
    # gh helper image is a shared cached tooling image (debian base + apt pkgs unpinned; same shared
    # rationale as the release-builder image — rebuilt only when absent).
    if ! docker image inspect "$GH_HELPER_IMAGE" >/dev/null 2>&1; then
        build_gh_helper || ftbfs_die "gh helper image build failed (see output)."
    fi

    # Unique correlation ID echoed into the workflow run-name so we attach to OUR run exactly,
    # not a concurrent one (timestamp/pre-ID heuristics can mis-select). Not a secret.
    local request_id; request_id="wsreq-${ver}-$(date -u +%Y%m%d%H%M%S)-${RANDOM}${RANDOM}"
    log_info "Triggering ${GH_WORKFLOW} on ${GH_REPO}@${GH_WORKFLOW_REF} (version=${ver}, request_id=${request_id})..."
    gh_c workflow run "$GH_WORKFLOW" --repo "$GH_REPO" --ref "$GH_WORKFLOW_REF" -f version="$ver" -f request_id="$request_id" \
        || ftbfs_die "Failed to trigger ${GH_WORKFLOW}."

    log_info "Waiting for the run (correlating by request_id)..."
    local run_id="" i c
    for i in $(seq 1 30); do
        sleep 10
        # Match strictly on our request_id in the run name (displayTitle) — race-proof.
        local cand; mapfile -t cand < <(gh_c run list --repo "$GH_REPO" --workflow "$GH_WORKFLOW" --limit 30 \
            --json databaseId,displayTitle --jq "[.[] | select(.displayTitle | contains(\"${request_id}\"))] | .[].databaseId" 2>/dev/null || true)
        for c in "${cand[@]:-}"; do
            [[ -z "$c" || "$c" == "null" ]] && continue
            run_id="$c"; break
        done
        [[ -n "$run_id" ]] && break
        log_info "poll ${i}/30..."
    done
    [[ -n "$run_id" && "$run_id" != "null" ]] || ftbfs_die "Workflow run not found after polling."
    log_info "Run ID ${run_id}; watching to completion (build ~20-30 min)..."
    gh_c run watch "$run_id" --repo "$GH_REPO" --exit-status \
        || ftbfs_die "GitHub Actions run ${run_id} failed."
    # Stream the full GH Actions build log to the terminal (and into the cast) as verification
    # evidence, while also saving it to a file. Large, but it is the Windows build output.
    log_info "===== GitHub Actions build log (run ${run_id}) ====="
    gh_c run view "$run_id" --repo "$GH_REPO" --log 2>/dev/null | tee "${artdir}/gh-run-${run_id}.log" || log_warn "could not fetch run log"
    log_info "===== end GitHub Actions build log ====="

    log_info "Downloading built EXE artifacts (A and B)..."
    local label
    for label in A B; do
        rm -rf "${artdir:?}/${label}"; mkdir -p "${artdir}/${label}"
        gh_c run download "$run_id" --repo "$GH_REPO" --name "bisq1-${ver}-win-exe-${label}" --dir "/work/${label}" \
            || ftbfs_die "Failed to download bisq1-${ver}-win-exe-${label}."
    done
    # Provenance artifact (workflow/runner/JDK+WiX versions, A/B hashes) — kept for the human report.
    rm -rf "${artdir:?}/provenance"; mkdir -p "${artdir}/provenance"
    gh_c run download "$run_id" --repo "$GH_REPO" --name "bisq1-${ver}-win-provenance" --dir "/work/provenance" 2>/dev/null \
        || log_warn "provenance artifact not downloaded (non-fatal)"
}

# Diagnostic-only extracted diff of two installers -> outfile (VERDICT-NEUTRAL). 7z + diff run inside the gh
# helper container, so no host 7z is needed. Full diff retained.
diag_extract_diff() {
    local f1="$1" f2="$2" l1="$3" l2="$4" outfile="$5" detail="$6"
    rm -f "$outfile"
    # docker -v mount sources MUST be absolute (find can return relative paths under --built).
    f1="$(realpath "$f1")"; f2="$(realpath "$f2")"
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "DIAGNOSTIC UNAVAILABLE: docker not available; $(basename "$outfile") skipped." >> "$detail"
        return 0
    fi
    docker image inspect "$GH_HELPER_IMAGE" >/dev/null 2>&1 || build_gh_helper \
        || { echo "DIAGNOSTIC UNAVAILABLE: helper image unavailable; $(basename "$outfile") skipped." >> "$detail"; return 0; }

    # Extract both files + diff inside the container; write full diff + a meta line to the mounted work dir.
    local wd; wd="$(mktemp -d)"
    local rc=0
    docker run --rm --user "$(id -u):$(id -g)" \
        -v "$f1":/in/f1:ro -v "$f2":/in/f2:ro -v "$wd":/work -w /work \
        "$GH_HELPER_IMAGE" bash -c '
            set +e
            mkdir -p e1 e2
            7z x -y -oe1 /in/f1 >/dev/null 2>&1; r1=$?
            7z x -y -oe2 /in/f2 >/dev/null 2>&1; r2=$?
            if [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ]; then
                echo "meta extract_failed r1=$r1 r2=$r2" > meta.txt; exit 0
            fi
            diff -r e1 e2 > diff.txt 2>&1; echo "meta diff_status=$?" > meta.txt
        ' >/dev/null 2>&1 || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        echo "DIAGNOSTIC UNAVAILABLE: container extraction errored (rc=$rc); $(basename "$outfile") skipped." >> "$detail"
    elif grep -q 'extract_failed' "$wd/meta.txt" 2>/dev/null; then
        echo "DIAGNOSTIC UNAVAILABLE: 7z extraction failed in container ($(cat "$wd/meta.txt" 2>/dev/null)); $(basename "$outfile") empty." \
            | tee "$outfile" >> "$detail"
    else
        local dstat; dstat=$(sed -n 's/^meta diff_status=//p' "$wd/meta.txt" 2>/dev/null); dstat="${dstat:-9}"
        { echo "=== DIAGNOSTIC ONLY (verdict-neutral): diff -r ${l1} vs ${l2} (diff status ${dstat}) ==="
          cat "$wd/diff.txt" 2>/dev/null; } > "$outfile"
        if [[ "$dstat" -le 1 ]]; then
            echo "Diagnostic FULL diff -> $(basename "$outfile") (diff status ${dstat}; preview below)" >> "$detail"
            head -5 "$outfile" >> "$detail"
        else
            echo "DIAGNOSTIC: diff errored (status ${dstat}); output in $(basename "$outfile")." >> "$detail"
        fi
    fi
    rm -rf "$wd"
}

verify_windows_exe() {
    local execution_dir; execution_dir="$(pwd)"
    local yaml="${execution_dir}/COMPARISON_RESULTS.yaml"; YAML_OUT="$yaml"
    local detail="${execution_dir}/comparison-detail.txt"
    local ver="${BISQ_VERSION#v}"
    local official_name="Bisq-64bit-${ver}.exe"

    # Remove stale diagnostics from a prior run so they can't be mistaken for current evidence.
    rm -f "${execution_dir}/diff_exe.txt" "${execution_dir}/diff_exe_AvsB.txt" "$detail"

    # Acquire the official EXE (use --binary if given, else download from the GitHub release).
    local official="$OFFICIAL_BINARY"
    if [[ -z "$official" ]]; then
        official="${execution_dir}/${official_name}"
        log_info "Downloading official ${official_name} ..."
        curl -fL --progress-bar -o "$official" \
            "${REPO_URL}/releases/download/${BISQ_VERSION}/${official_name}" \
            || ftbfs_die "Failed to download official ${official_name}."
    fi
    [[ -f "$official" ]] || die "official EXE not found: $official" "$EXIT_INVALID_PARAMS"

    # Acquire the two built EXEs: default = trigger CI + download; --built = offline override.
    local search_dir
    if [[ -n "$BUILT_DIR" ]]; then
        [[ -d "$BUILT_DIR" ]] || die "--built dir not found: $BUILT_DIR" "$EXIT_INVALID_PARAMS"
        log_info "Offline mode: using pre-downloaded artifacts under --built ${BUILT_DIR}"
        search_dir="$BUILT_DIR"
    else
        # Per-run unique work dir (arch/type + PID) so concurrent runs never collide (parallel-safe).
        local artdir="${execution_dir}/bisq1-${ver}-x86_64-windows-exe-$$"
        acquire_built_exes_via_ci "$ver" "$artdir" "$yaml"
        search_dir="$artdir"
    fi

    # Collect the two built EXEs. MUST be version-specific (Bisq-64bit-<ver>.exe) so a stale/wrong
    # version artifact can never be mistaken for this run (order-independent: we require A==B and A==official).
    mapfile -t built < <(find "$search_dir" -type f -name "${official_name}" | sort)
    if [[ "${#built[@]}" -ne 2 ]]; then
        write_yaml "$yaml" "ftbfs" \
"Expected exactly 2 '${official_name}' files (A and B), found ${#built[@]} under ${search_dir}.
Each must come from a DISTINCT artifact (bisq1-${ver}-win-exe-A and -B, version ${ver} only)."
        die "need exactly 2 '${official_name}' (found ${#built[@]})" "$EXIT_INVALID_PARAMS"
    fi
    # Reject the degenerate case of both entries being the SAME underlying file (no real A/B isolation).
    # Compare device:inode so hardlinks (distinct paths, distinct realpaths, same inode) are caught too.
    if [[ "$(stat -c '%d:%i' "${built[0]}")" == "$(stat -c '%d:%i' "${built[1]}")" ]]; then
        die "the two built EXEs are the same underlying file (same device:inode / hardlink); A and B must be distinct artifacts" "$EXIT_INVALID_PARAMS"
    fi

    local hO hA hB
    hO=$(sha256sum "$official"     | cut -d' ' -f1)
    hA=$(sha256sum "${built[0]}"   | cut -d' ' -f1)
    hB=$(sha256sum "${built[1]}"   | cut -d' ' -f1)

    {
        echo "=== Bisq 1 ${BISQ_VERSION} Windows EXE comparison (${SCRIPT_VERSION}) ==="
        echo "official : $official"
        echo "  sha256 : $hO"
        echo "built A  : ${built[0]}"
        echo "  sha256 : $hA"
        echo "built B  : ${built[1]}"
        echo "  sha256 : $hB"
        echo
        echo "Build: Windows runner via bisq1-windows-build.yml (jpackage+WiX). If a provenance/ dir is"
        echo "  present (auto-trigger mode), it has the runner image, JDK+WiX versions, upstream commit,"
        echo "  and A/B hashes; in --built offline mode provenance is whatever the operator supplied."
        echo "This script reports a MECHANICAL outer-sha256 verdict only. Interpreting any differences"
        echo "  (root cause, acceptability) is the human reviewer's job — see the diff_exe*.txt file(s)"
        echo "  and the WS report. Do not treat any narrative here as the script's conclusion."
    } > "$detail"

    local verdict notes
    if [[ "$hA" != "$hB" ]]; then
        verdict="not_reproducible"
        notes="Windows EXE NON-DETERMINISTIC: build A != build B from the same source+toolchain (A=$hA B=$hB). The build itself is not reproducible. See diff_exe_AvsB.txt (extracted A-vs-B diff)."
    elif [[ "$hA" != "$hO" ]]; then
        verdict="not_reproducible"
        notes="Windows EXE deterministic (A==B) but differs from official (built=$hA official=$hO). Outer-sha256 mechanical verdict; extracted diff diagnostic-only. See diff_exe.txt."
    else
        verdict="reproducible"
        notes="Windows EXE reproducible: A==B==official ($hO)."
    fi

    # Diagnostics (VERDICT-NEUTRAL): A != B -> diff A vs B; A == B != official -> diff official vs A.
    if [[ "$hA" != "$hB" ]]; then
        diag_extract_diff "${built[0]}" "${built[1]}" "build-A" "build-B" "${execution_dir}/diff_exe_AvsB.txt" "$detail"
    elif [[ "$hA" != "$hO" ]]; then
        diag_extract_diff "$official" "${built[0]}" "official" "build-A" "${execution_dir}/diff_exe.txt" "$detail"
    fi

    write_yaml "$yaml" "$verdict" "$notes"
    cat "$detail"
    emit_results_block "$verdict" "$hO" "$(resolve_tag_commit)"
    log_info "Wrote ${yaml} (verdict: ${verdict})"
    [[ "$verdict" == "reproducible" ]] && return "$EXIT_SUCCESS" || return "$EXIT_BUILD_FAILED"
}

usage() {
    cat << EOF
Bisq 1 Desktop Reproducible Build Verification Script (${SCRIPT_VERSION})

Usage: $(basename "$0") --version <version> --arch <arch> --type <type> [--binary <file|dir>]
  --version <version>    Bisq version, e.g. 1.10.7 (default ${DEFAULT_VERSION}; derived from a
                         Bisq-64bit-<ver>.<type> file name given to --binary when omitted)
  --arch <arch>          x86_64-linux | x86_64-linux-gnu (deb/rpm) | x86_64-windows (exe)
  --type <type>          deb | rpm | exe
  --binary <file|dir>    Local official installer (file, or dir containing it); --apk is an alias.
  --built <dir>          exe only: dir with the two pre-built EXEs (A and B) instead of triggering CI.
  --no-cache             Force fresh image build (deb/rpm).   --keep-container  Keep containers.
ENV (exe only, unless --built): GITHUB_TOKEN or GH_TOKEN (dispatch + artifact read); docker for the gh helper.
deb/rpm: two clean builds (A/B) in the tag's own release-builder container (legacy Zulu 11/17 image pre-1.10);
  verdict mechanical on the outer sha256; dpkg-deb -R / rpm evidence for the human report.
exe: Windows installer built twice on a GitHub windows-2025 runner (see header); verdict mechanical, diff diagnostic.
  NOTE: the installer embeds the build year (Year.now()), so verify a 2026 release within 2026.
Exit 0 reproducible | 1 differs or failed | 2 invalid params. Writes COMPARISON_RESULTS.yaml, comparison-detail.txt,
artifacts/. Organization: WalletScrutiny.com
EOF
}

# First action: self-identify (script name/version/sha256) before any parsing or network work.
log_info "Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
log_info "         sha256: ${SCRIPT_SHA256}"

# ---- Parse (unknown args non-fatal: warn + continue, Luis 2026-03-11) ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --version) [[ -z "${2:-}" ]] && die "--version requires an argument" "$EXIT_INVALID_PARAMS"; BISQ_VERSION="$2"; shift 2 ;;
        --arch)    [[ -z "${2:-}" ]] && die "--arch requires an argument" "$EXIT_INVALID_PARAMS"; BISQ_ARCH="$2"; shift 2 ;;
        --type)    [[ -z "${2:-}" ]] && die "--type requires an argument" "$EXIT_INVALID_PARAMS"; BISQ_TYPE="$2"; shift 2 ;;
        --binary|--apk) [[ -z "${2:-}" ]] && die "$1 requires a file/dir argument" "$EXIT_INVALID_PARAMS"; OFFICIAL_BINARY="$2"; shift 2 ;;
        --built) [[ -z "${2:-}" ]] && die "--built requires a dir argument" "$EXIT_INVALID_PARAMS"; BUILT_DIR="$2"; shift 2 ;;
        --no-cache) NO_CACHE=true; shift ;;
        --keep-container) KEEP_CONTAINER=true; shift ;;
        *) log_warn "ignoring unknown argument: $1"; shift ;;
    esac
done

# No --version: derive it from an official-style file name (Bisq-64bit-<ver>.<type>), else the default.
if [[ -z "$BISQ_VERSION" && -n "$OFFICIAL_BINARY" ]]; then
    BISQ_VERSION="$(basename "$OFFICIAL_BINARY" | sed -n 's/^Bisq-64bit-\([0-9][0-9.]*\)\.[a-z]*$/\1/p')"
fi
[[ -z "$BISQ_VERSION" ]] && BISQ_VERSION="$DEFAULT_VERSION"
[[ -z "$BISQ_TYPE" ]] && BISQ_TYPE="deb"
# Default arch depends on type: exe -> windows, deb/rpm -> linux.
if [[ -z "$BISQ_ARCH" ]]; then
    case "$BISQ_TYPE" in exe) BISQ_ARCH="x86_64-windows" ;; *) BISQ_ARCH="x86_64-linux-gnu" ;; esac
fi
case "$BISQ_ARCH" in
    x86_64-linux|x86_64-linux-gnu) BISQ_ARCH="x86_64-linux-gnu" ;;
    x86_64-windows|x86_64-win)     BISQ_ARCH="x86_64-windows" ;;
    *) die "Unsupported architecture: $BISQ_ARCH" "$EXIT_INVALID_PARAMS" ;;
esac
case "$BISQ_TYPE" in deb|rpm|exe) ;; *) die "Unsupported type: $BISQ_TYPE (deb|rpm|exe)" "$EXIT_INVALID_PARAMS" ;; esac
# Type/arch must be consistent (reject mismatched combinations).
case "$BISQ_TYPE" in
    deb|rpm) [[ "$BISQ_ARCH" == "x86_64-linux-gnu" ]] || die "--type $BISQ_TYPE requires --arch x86_64-linux (got $BISQ_ARCH)" "$EXIT_INVALID_PARAMS" ;;
    exe)     [[ "$BISQ_ARCH" == "x86_64-windows" ]]   || die "--type exe requires --arch x86_64-windows (got $BISQ_ARCH)" "$EXIT_INVALID_PARAMS" ;;
esac
[[ "$BISQ_VERSION" =~ ^v ]] || BISQ_VERSION="v$BISQ_VERSION"

OFFICIAL_PKG_NAME="Bisq-64bit-${BISQ_VERSION#v}.${BISQ_TYPE}"

if [[ -n "$OFFICIAL_BINARY" ]]; then
    if [[ -d "$OFFICIAL_BINARY" ]]; then
        cand="$OFFICIAL_BINARY/$OFFICIAL_PKG_NAME"
        [[ -f "$cand" ]] || cand="$(find "$OFFICIAL_BINARY" -maxdepth 1 -type f -name "*.${BISQ_TYPE}" | head -1)"
        [[ -n "$cand" && -f "$cand" ]] || die "--binary dir has no .${BISQ_TYPE} installer: $OFFICIAL_BINARY" "$EXIT_INVALID_PARAMS"
        OFFICIAL_BINARY="$cand"
    fi
    [[ -f "$OFFICIAL_BINARY" ]] || die "--binary file not found: $OFFICIAL_BINARY" "$EXIT_INVALID_PARAMS"
    OFFICIAL_BINARY="$(realpath "$OFFICIAL_BINARY")"
fi

# Must run as a normal user, never root (docker via the invoking user's own access).
[[ "$(id -u)" -ne 0 ]] || die "Run this script as a normal user, not root."

# Desktop runtime disclaimer (script-disclaimer.txt), bright yellow, 3 seconds.
echo -e "${YELLOW}DISCLAIMER:
Please examine this script yourself prior to running it.
This script is provided as-is without warranty and may contain bugs or
security vulnerabilities. Running this script will execute Docker containers,
download source code, and perform deterministic builds that may consume
significant system resources (CPU, memory, disk space).
Use at your own risk and ensure you understand what the script does before
execution.${NC}"
sleep 3

# ---- ISOLATION BOUNDARY: Windows EXE path returns here, before any docker/release-builder logic. ----
if [[ "$BISQ_TYPE" == "exe" ]]; then
    verify_windows_exe
    exit $?
fi

VC=$(sanitize_component "$BISQ_VERSION"); AC=$(sanitize_component "$BISQ_ARCH"); TC=$(sanitize_component "$BISQ_TYPE")
SUFFIX=$(sanitize_component "$(date +%s)-$$")
IMAGE_NAME="bisq-release-builder-linux:java-21.0.6"
CONTAINER_A="bisq1-build-a-${VC}-${TC}-${SUFFIX}"
CONTAINER_B="bisq1-build-b-${VC}-${TC}-${SUFFIX}"
CONTAINER_CMP="bisq1-cmp-${VC}-${TC}-${SUFFIX}"

WORK_DIR="${SCRIPT_DIR}/bisq1_desktop_${VC}_${AC}_${TC}_$$"
mkdir -p "$WORK_DIR"; cd "$WORK_DIR"; chmod 777 "$WORK_DIR" >/dev/null 2>&1 || true
execution_dir="$(pwd)"; YAML_OUT="${execution_dir}/COMPARISON_RESULTS.yaml"
SRC_A="${WORK_DIR}/src-a"
SRC_B="${WORK_DIR}/src-b"
ARTIFACTS_DIR="${execution_dir}/artifacts"; mkdir -p "$ARTIFACTS_DIR"

log_info "========================================================"
log_info "Bisq 1 Desktop Reproducible Build Verification (${SCRIPT_VERSION})"
log_info "========================================================"
log_info "Version: $BISQ_VERSION | Arch: $BISQ_ARCH | Type: $BISQ_TYPE"
log_info "Toolchain: auto-detected (release-builder >=1.10 / legacy Zulu 11+17 pre-1.10)"
log_info "Mode: A/B determinism (2 clean builds) + mechanical outer-hash verdict"
log_info "Work Dir: $WORK_DIR"
log_info ""

# ---- Docker preflight ----
command -v docker >/dev/null 2>&1 || ftbfs_die "Docker not found on host."
docker info >/dev/null 2>&1 || ftbfs_die "Docker daemon not running."
log_success "Docker OK"
# Rootless podman behind a `docker` shim needs --userns=keep-id for --user $(id -u) to keep write access to
# the bind mounts (real docker needs nothing). Detected, never assumed.
DOCKER_RUN_EXTRA=""
if docker --version 2>/dev/null | grep -qi podman; then
    DOCKER_RUN_EXTRA="--userns=keep-id"
    log_info "Container engine is podman: adding ${DOCKER_RUN_EXTRA} to docker run"
fi

# ---- Stage official installer ----
if [[ -n "$OFFICIAL_BINARY" ]]; then
    log_info "Using provided official installer: $OFFICIAL_BINARY"
    cp "$OFFICIAL_BINARY" "${execution_dir}/${OFFICIAL_PKG_NAME}"
else
    log_info "Downloading official release: ${OFFICIAL_PKG_NAME}"
    curl -fL --progress-bar -o "${execution_dir}/${OFFICIAL_PKG_NAME}" \
        "https://github.com/bisq-network/bisq/releases/download/${BISQ_VERSION}/${OFFICIAL_PKG_NAME}" \
      || ftbfs_die "Failed to download official ${OFFICIAL_PKG_NAME}."
fi
OFFICIAL_HASH="$(sha256sum "${execution_dir}/${OFFICIAL_PKG_NAME}" | cut -d' ' -f1)"
log_success "Official staged: ${OFFICIAL_PKG_NAME} (sha256=${OFFICIAL_HASH})"

# Official .asc: EVIDENCE ONLY (gpg --verify in the compare container, keys from the tag). Never fatal.
OFFICIAL_SIG="${execution_dir}/${OFFICIAL_PKG_NAME}.asc"
if [[ -n "$OFFICIAL_BINARY" && -f "${OFFICIAL_BINARY}.asc" ]]; then
    cp "${OFFICIAL_BINARY}.asc" "$OFFICIAL_SIG"
elif curl -fsSL -o "$OFFICIAL_SIG" \
        "https://github.com/bisq-network/bisq/releases/download/${BISQ_VERSION}/${OFFICIAL_PKG_NAME}.asc"; then
    log_info "Official detached signature staged: ${OFFICIAL_PKG_NAME}.asc (evidence only)"
else
    rm -f "$OFFICIAL_SIG"
    log_warn "No detached signature fetched for ${OFFICIAL_PKG_NAME} (evidence only; continuing)"
fi

# ---- One network clone, A/B = local clones of it (hardlinked objects, own .git, origin reset), submodules each ----
SRC_BASE="${WORK_DIR}/src-base"
log_info "cloning ${REPO_URL} once (full git output shown)..."
git clone "$REPO_URL" "$SRC_BASE" \
  || ftbfs_die "git clone failed (base)."
clone_checkout() {  # dest label
    local dest="$1" label="$2"
    log_info "[$label] local clone + checkout ${BISQ_VERSION} (full git output shown)..."
    git clone "$SRC_BASE" "$dest" \
      || ftbfs_die "git clone failed ($label)."
    git -C "$dest" remote set-url origin "$REPO_URL"
    git -C "$dest" checkout "$BISQ_VERSION" \
      || ftbfs_die "git checkout ${BISQ_VERSION} failed ($label)."
    git -C "$dest" submodule update --init --recursive \
      || ftbfs_die "Submodule init failed ($label); upstream requires submodules."
    log_success "[$label] $(git -C "$dest" describe --tags 2>/dev/null || echo "$BISQ_VERSION") + submodules"
}
clone_checkout "$SRC_A" "A"
clone_checkout "$SRC_B" "B"
rm -rf "$SRC_BASE"

# Pre-1.10 tags never shipped docker/release-builder/linux/Dockerfile; detect per tag, no hardcoded cutoff.
UPSTREAM_DOCKERDIR="${SRC_A}/docker/release-builder/linux"
LEGACY_TOOLCHAIN=false
if [[ ! -f "${UPSTREAM_DOCKERDIR}/Dockerfile" ]]; then
    LEGACY_TOOLCHAIN=true
    IMAGE_NAME="bisq1-legacy-builder:zulu-11-17-v1"
    log_warn "No release-builder Dockerfile at ${BISQ_VERSION} (pre-1.10) -- using legacy Zulu 11/17 toolchain."
fi

# v1.10.4+ packaging rewrite (:desktop:deb/:desktop:rpm, output in desktop/build/packaging): detect per tag.
NEW_PACKAGING=false
if [[ "$LEGACY_TOOLCHAIN" == "true" ]]; then
    log_info "Packaging: pre-1.10 layout (generateInstallers, JDK17 jpackage)"
elif grep -qs 'DebJpackageTask' "${SRC_A}/build-logic/packaging/src/main/kotlin/bisq/gradle/packaging/PackagingPlugin.kt"; then
    NEW_PACKAGING=true
    log_info "Packaging: v1.10.4+ layout (:desktop:${BISQ_TYPE} task; output desktop/build/packaging)"
else
    log_info "Packaging: pre-1.10.4 layout (generateInstallers via verifyInstallerEvidenceBundle)"
fi

# JDK the tag's own recipe pins (base image tag of docker/release-builder/linux/Dockerfile); evidence only.
RECIPE_JDK_PIN="n/a (legacy toolchain)"
if [[ "$LEGACY_TOOLCHAIN" != "true" ]]; then
    RECIPE_JDK_PIN="$(sed -n 's/^FROM .*azul\/zulu-openjdk:\([^@ ]*\).*/\1/p' "${UPSTREAM_DOCKERDIR}/Dockerfile" | head -1)"
    RECIPE_JDK_PIN="${RECIPE_JDK_PIN:-unknown}"
    log_info "Recipe JDK pin (Dockerfile FROM): ${RECIPE_JDK_PIN}"
fi

if [[ -f "${SRC_A}/gradle/wrapper/gradle-wrapper.sha256" ]]; then
    ( cd "$SRC_A" && sha256sum -c gradle/wrapper/gradle-wrapper.sha256 ) \
        && log_success "gradle-wrapper.sha256 verified" \
        || log_warn "gradle-wrapper.sha256 check reported issues (continuing; note for report)"
fi

build_legacy_image() {  # cached tooling image for pre-1.10 tags
    log_info "Building legacy pre-1.10 image (Ubuntu 22.04 + Zulu 11/17)..."
    docker build $CACHE_FLAG -t "$IMAGE_NAME" - <<'LEGACYEOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      git wget ca-certificates ca-certificates-java gnupg xz-utils zstd \
      binutils cpio fakeroot dpkg-dev rpm \
 && wget -q https://cdn.azul.com/zulu/bin/zulu-repo_1.0.0-3_all.deb \
 && dpkg -i zulu-repo_1.0.0-3_all.deb \
 && apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9 \
 && apt-get update -qq && apt-get install -y --no-install-recommends zulu11-jdk zulu17-jdk \
 && rm -rf /var/lib/apt/lists/* zulu-repo_1.0.0-3_all.deb && update-ca-certificates \
 && mkdir -p /usr/lib/jvm/zulu11/lib/security \
 && touch /usr/lib/jvm/zulu11/lib/security/blacklisted.certs
ENV GRADLE_OPTS="-Xmx4g -Dorg.gradle.daemon=false"
LEGACYEOF
}

# ---- Build image: upstream's own Dockerfile (>=1.10) or the cached legacy image (pre-1.10) ----
CACHE_FLAG=""; [[ "$NO_CACHE" == "true" ]] && CACHE_FLAG="--no-cache"
if [[ "$LEGACY_TOOLCHAIN" == "true" ]]; then
    if [[ "$NO_CACHE" == "true" ]] || ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        build_legacy_image || ftbfs_die "legacy image build failed."
    fi
else
    log_info "Building release-builder image from upstream Dockerfile..."
    if ! docker build $CACHE_FLAG --pull=false --platform linux/amd64 \
            -t "$IMAGE_NAME" "$UPSTREAM_DOCKERDIR" 2>&1 | tee "${execution_dir}/build-image.log"; then
        ftbfs_die "release-builder image build failed (see build-image.log)."
    fi
fi
log_success "Image ready: $IMAGE_NAME"

# ---- Run one clean build inside the image (1.10.4+: only :desktop:${BISQ_TYPE}, see header) ----
gradle_build() {  # srcdir containername logfile label
    local src="$1" cname="$2" logf="$3" label="$4"
    local rmflag="--rm"; [[ "$KEEP_CONTAINER" == "true" ]] && rmflag=""
    if [[ "$LEGACY_TOOLCHAIN" == "true" ]]; then
        # Pre-1.10: two-phase build, JDK 11 compile then JDK 17 jpackage (no single-JDK recipe existed).
        log_info "[$label] building legacy (JDK11 build + JDK17 jpackage; 20-40 min)..."
        set +e
        docker run $rmflag $DOCKER_RUN_EXTRA --platform linux/amd64 --user "$(id -u):$(id -g)" \
            -v "${src}":/workspace -w /workspace --name "$cname" "$IMAGE_NAME" bash -c '
                export JAVA_HOME=/usr/lib/jvm/zulu11 PATH="$JAVA_HOME/bin:$PATH"
                ./gradlew --no-daemon clean build -x test || exit $?
                export JAVA_HOME=/usr/lib/jvm/zulu17 PATH="$JAVA_HOME/bin:$PATH"
                ./gradlew --no-daemon desktop:generateInstallers --rerun-tasks
            ' 2>&1 | tee "$logf"
        local rc=${PIPESTATUS[0]}
        set -e
        return $rc
    fi
    local -a tasks
    if [[ "$NEW_PACKAGING" == "true" ]]; then
        tasks=(clean verifyReleaseBuild ":desktop:${BISQ_TYPE}")
    else
        tasks=(clean verifyReleaseBuild verifyInstallerEvidenceBundle)
    fi
    log_info "[$label] building (./gradlew ${tasks[*]}; 8-15 min)..."
    set +e
    docker run $rmflag $DOCKER_RUN_EXTRA --platform linux/amd64 --user "$(id -u):$(id -g)" \
        -v "${src}":/workspace -w /workspace \
        --name "$cname" \
        "$IMAGE_NAME" \
        ./gradlew --no-daemon "${tasks[@]}" 2>&1 | tee "$logf"
    local rc=${PIPESTATUS[0]}
    set -e
    return $rc
}

if ! gradle_build "$SRC_A" "$CONTAINER_A" "${execution_dir}/build-a.log" "A"; then
    ftbfs_die "Build A failed (see build-a.log)."
fi
log_success "Build A complete"
if ! gradle_build "$SRC_B" "$CONTAINER_B" "${execution_dir}/build-b.log" "B"; then
    ftbfs_die "Build B failed (see build-b.log)."
fi
log_success "Build B complete"

# ---- Locate rebuilt installers (host side; volumes are host-owned) ----
find_pkg() {  # srcdir
    # Output dir moved at v1.10.4: pre-1.10.4 = .../packaging/jpackage/packages; 1.10.4+ = .../packaging.
    local pkgdir="$1/desktop/build/packaging/jpackage/packages"
    [[ "$NEW_PACKAGING" == "true" ]] && pkgdir="$1/desktop/build/packaging"
    if [[ "$BISQ_TYPE" == "deb" ]]; then
        find "$pkgdir" -name "bisq_*_amd64.deb" 2>/dev/null | head -1
    else
        find "$pkgdir" -name "bisq-*.x86_64.rpm" 2>/dev/null | head -1
    fi
}
A_PKG="$(find_pkg "$SRC_A")"; B_PKG="$(find_pkg "$SRC_B")"
[[ -n "$A_PKG" && -n "$B_PKG" ]] || ftbfs_die "rebuilt .${BISQ_TYPE} not found in one or both builds."

# Preserve artifacts + upstream evidence bundles (for inspection + the report)
mkdir -p "$ARTIFACTS_DIR/build-a" "$ARTIFACTS_DIR/build-b"
cp -f "$A_PKG" "$ARTIFACTS_DIR/build-a/" 2>/dev/null || true
cp -f "$B_PKG" "$ARTIFACTS_DIR/build-b/" 2>/dev/null || true
for side in a b; do
    src="SRC_${side^^}"; srcdir="${!src}"
    for ev in release-evidence.zip installer-evidence.zip release-manifest.tsv installer-manifest.tsv \
              SHA256SUMS INSTALLER-SHA256SUMS build-info.json installer-build-info.json \
              installer-structure-report.tsv installer-structure-summary.txt; do
        f="${srcdir}/build/reports/release/${ev}"
        [[ -f "$f" ]] && cp -f "$f" "$ARTIFACTS_DIR/build-${side}/" 2>/dev/null || true
    done
done

# ---- Comparison + evidence (in-container: image has dpkg-deb/rpm/etc.) ----
VERIFY_SCRIPT="${WORK_DIR}/verify-compare.sh"
cat > "$VERIFY_SCRIPT" << 'COMPARE'
#!/bin/bash
set -uo pipefail
BISQ_TYPE="${BISQ_TYPE:-deb}"
BISQ_VERSION="${BISQ_VERSION:-}"
SCRIPT_VERSION="${SCRIPT_VERSION:-v0.5.0}"
OFFICIAL_PKG_NAME="${OFFICIAL_PKG_NAME:?}"
OUT="/output"
OFFICIAL="$OUT/$OFFICIAL_PKG_NAME"
A_PKG="/a"   # mounted file
B_PKG="/b"   # mounted file
DETAIL="$OUT/comparison-detail.txt"

emit_yaml() { local verdict="$1" notes="${2:-}"
    { printf 'script_version: %s\n' "$SCRIPT_VERSION"
      printf 'verdict: %s\n' "$verdict"
      if [[ -n "$notes" ]]; then printf 'notes: |\n'; printf '%s\n' "$notes" | sed 's/^/  /'; fi
    } > "$OUT/COMPARISON_RESULTS.yaml"; }
ftbfs() { echo "FTBFS: $1"; emit_yaml ftbfs "$1"; exit 1; }

for f in "$OFFICIAL" "$A_PKG" "$B_PKG"; do [[ -f "$f" ]] || ftbfs "missing input: $f"; done

OFF_H=$(sha256sum "$OFFICIAL" | cut -d' ' -f1)
A_H=$(sha256sum "$A_PKG" | cut -d' ' -f1)
B_H=$(sha256sum "$B_PKG" | cut -d' ' -f1)

# Determinism (A vs B) and reproducibility (A vs official), both on the OUTER file hash.
DETERMINISTIC=no; [[ "$A_H" == "$B_H" ]] && DETERMINISTIC=yes
MATCHES_OFFICIAL=no; [[ "$A_H" == "$OFF_H" ]] && MATCHES_OFFICIAL=yes

{
  echo "=== Bisq 1 ${BISQ_VERSION} ${BISQ_TYPE} comparison (${SCRIPT_VERSION}) ==="
  echo "official_sha256=$OFF_H"
  echo "build_a_sha256 =$A_H"
  echo "build_b_sha256 =$B_H"
  echo "deterministic (A==B): $DETERMINISTIC"
  echo "matches_official (A==official): $MATCHES_OFFICIAL"
  echo ""
} > "$DETAIL"

# ---- Evidence extraction (NOT a verdict input): full dpkg-deb -R / rpm payload+meta ----
PAYLOAD_DIFF=unknown
EXO=/tmp/ex/official; EXB=/tmp/ex/built
rm -rf /tmp/ex; mkdir -p "$EXO" "$EXB"

if [[ "$BISQ_TYPE" == "deb" ]]; then
    # dpkg-deb -R: DEBIAN/ holds control+md5sums+maintainer scripts; rest is payload tree.
    if dpkg-deb -R "$OFFICIAL" "$EXO" 2>>"$DETAIL" && dpkg-deb -R "$A_PKG" "$EXB" 2>>"$DETAIL"; then
        {
          echo "--- control/maintainer diff (DEBIAN/) ---"
          diff -ru "$EXO/DEBIAN" "$EXB/DEBIAN" 2>&1 || true
          echo ""
          echo "--- payload content diff (excluding DEBIAN/) ---"
          diff -ru -x DEBIAN "$EXO" "$EXB" 2>&1 || true
          echo ""
          echo "--- payload mode/type/symlink listing diff ---"
          ( cd "$EXO" && find . -path ./DEBIAN -prune -o \( -type f -o -type l -o -type d \) -printf '%y %M %p -> %l\n' | LC_ALL=C sort ) > /tmp/o.list
          ( cd "$EXB" && find . -path ./DEBIAN -prune -o \( -type f -o -type l -o -type d \) -printf '%y %M %p -> %l\n' | LC_ALL=C sort ) > /tmp/b.list
          diff /tmp/o.list /tmp/b.list 2>&1 || true
        } >> "$DETAIL"
        # Classification hint: any difference in the payload tree (content OR mode/type/symlink)?
        if diff -rq -x DEBIAN "$EXO" "$EXB" >/dev/null 2>&1 && diff -q /tmp/o.list /tmp/b.list >/dev/null 2>&1; then
            PAYLOAD_DIFF=none
        else
            PAYLOAD_DIFF=present
        fi
    else
        echo "WARN: dpkg-deb -R extraction failed; payload classification unavailable" >> "$DETAIL"
    fi
else
    # RPM: payload via rpm2cpio; metadata via rpm queries.
    if ( cd "$EXO" && rpm2cpio "$OFFICIAL" | cpio -idm 2>/dev/null ) && ( cd "$EXB" && rpm2cpio "$A_PKG" | cpio -idm 2>/dev/null ); then
        {
          echo "--- rpm metadata (official then built) ---"
          rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\nBUILDHOST=%{BUILDHOST}\nBUILDTIME=%{BUILDTIME}\n' "$OFFICIAL" 2>&1 || true
          rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\nBUILDHOST=%{BUILDHOST}\nBUILDTIME=%{BUILDTIME}\n' "$A_PKG" 2>&1 || true
          echo ""
          echo "--- payload content diff ---"
          diff -ru "$EXO" "$EXB" 2>&1 || true
          echo ""
          echo "--- payload mode/type/symlink listing diff ---"
          ( cd "$EXO" && find . \( -type f -o -type l -o -type d \) -printf '%y %M %p -> %l\n' | LC_ALL=C sort ) > /tmp/o.list
          ( cd "$EXB" && find . \( -type f -o -type l -o -type d \) -printf '%y %M %p -> %l\n' | LC_ALL=C sort ) > /tmp/b.list
          diff /tmp/o.list /tmp/b.list 2>&1 || true
        } >> "$DETAIL"
        if diff -rq "$EXO" "$EXB" >/dev/null 2>&1 && diff -q /tmp/o.list /tmp/b.list >/dev/null 2>&1; then
            PAYLOAD_DIFF=none
        else
            PAYLOAD_DIFF=present
        fi
    else
        echo "WARN: rpm payload extraction failed; payload classification unavailable" >> "$DETAIL"
    fi
fi

echo "" >> "$DETAIL"
echo "payload_diff_vs_official: $PAYLOAD_DIFF" >> "$DETAIL"

# ---- Evidence: bundled JDK (jlink runtime) vs the tag's recipe pin; root cause of every 1.10.x mismatch (bisq#7930) ----
runtime_release() {  # extracted-tree -> "JAVA_VERSION=.. JAVA_RUNTIME_VERSION=.. IMPLEMENTOR_VERSION=.."
    local f="$1/opt/bisq/lib/runtime/release"
    [[ -f "$f" ]] || { echo "unknown (no opt/bisq/lib/runtime/release)"; return 0; }
    grep -E '^(JAVA_VERSION|JAVA_RUNTIME_VERSION|IMPLEMENTOR_VERSION)=' "$f" | tr -d '"' | paste -sd' '
}
java_version_of() { sed -n 's/.*\bJAVA_VERSION=\([^ ]*\).*/\1/p' <<< "$1"; }
OFF_RT="$(runtime_release "$EXO")"; BLT_RT="$(runtime_release "$EXB")"
OFF_JV="$(java_version_of "$OFF_RT")"; BLT_JV="$(java_version_of "$BLT_RT")"
{
  echo ""
  echo "--- bundled JDK evidence (opt/bisq/lib/runtime/release) ---"
  echo "bundled_runtime_official: $OFF_RT"
  echo "bundled_runtime_built:    $BLT_RT"
  echo "recipe_jdk_pin (Dockerfile FROM at the tag): ${RECIPE_JDK_PIN:-unknown}"
} | tee -a "$DETAIL"
JDK_NOTE=""
if [[ -n "$OFF_JV" && -n "$BLT_JV" && "$OFF_JV" != "$BLT_JV" ]]; then
    JDK_NOTE="Bundled JDK differs: official ${OFF_JV} vs rebuilt ${BLT_JV} (tag's Dockerfile pins ${RECIPE_JDK_PIN:-unknown}); same pattern as bisq#7930."
fi

# ---- Evidence: official .asc vs keys shipped in desktop/package/ of the tag (NOT a verdict input) ----
SIG_STATUS="unchecked (no .asc staged)"
if [[ -f "$OFFICIAL.asc" ]]; then
    export GNUPGHOME=/tmp/gnupg; rm -rf "$GNUPGHOME"; mkdir -p -m 700 "$GNUPGHOME"
    gpg --batch --quiet --import /keys/*.asc >/dev/null 2>&1 || true
    if gpg --batch --verify "$OFFICIAL.asc" "$OFFICIAL" > /tmp/gpg-verify.txt 2>&1; then
        SIG_STATUS="good ($(sed -n 's/.*using [A-Z]* key \([0-9A-F]*\).*/\1/p' /tmp/gpg-verify.txt | head -1))"
        grep -q 'key has expired' /tmp/gpg-verify.txt && SIG_STATUS="${SIG_STATUS}, signing key EXPIRED"
    else
        SIG_STATUS="BAD or key not in desktop/package/*.asc (see comparison-detail.txt)"
    fi
    { echo ""; echo "--- official installer signature (gpg --verify, keys: desktop/package/*.asc from the tag) ---"; cat /tmp/gpg-verify.txt; } >> "$DETAIL"
fi
echo "official_signature: $SIG_STATUS" | tee -a "$DETAIL"

# ---- MECHANICAL verdict: outer hash only (WS policy). reproducible iff A==official AND A==B. ----
DET_NOTE="A/B determinism: $([[ "$DETERMINISTIC" == yes ]] && echo "build is deterministic (A==B)" || echo "BUILD IS NON-DETERMINISTIC (A!=B)")."
if [[ "$BISQ_TYPE" == deb ]]; then HINT_TOOL="dpkg-deb -R"; else HINT_TOOL="rpm2cpio"; fi
case "$PAYLOAD_DIFF" in
  none)    CLASS_HINT="CLASSIFICATION HINT: payload + modes/symlinks IDENTICAL to official ($HINT_TOOL); only ${BISQ_TYPE} packaging metadata differs. Candidate for 'reproducible_with_packaging_noise' (see reproducibility-heuristics-packaged-artifacts.md)." ;;
  present) CLASS_HINT="CLASSIFICATION HINT: real payload diffs vs official; genuine non-reproducibility (see comparison-detail.txt).${JDK_NOTE:+ ${JDK_NOTE}}" ;;
  *)       CLASS_HINT="CLASSIFICATION HINT: classification unavailable (extraction failed); see comparison-detail.txt." ;;
esac

TOOLCHAIN_NOTE="the pinned release-builder image (azul/zulu-openjdk:21.0.6, its own docker/release-builder Dockerfile)"
[[ "${LEGACY_TOOLCHAIN:-false}" == "true" ]] && TOOLCHAIN_NOTE="a legacy Ubuntu 22.04 + Zulu 11/17 image (JDK11 build, JDK17 jpackage; no release-builder Dockerfile pre-1.10)"
COMMON_NOTE="Bisq 1 ${BISQ_VERSION} ${BISQ_TYPE} built with ${TOOLCHAIN_NOTE}.
official_sha256=${OFF_H} build_a_sha256=${A_H} build_b_sha256=${B_H}.
${DET_NOTE}
Bundled JDK: official ${OFF_JV:-unknown}, rebuilt ${BLT_JV:-unknown}, recipe pin ${RECIPE_JDK_PIN:-unknown}. Official signature: ${SIG_STATUS}."

if [[ "$MATCHES_OFFICIAL" == yes && "$DETERMINISTIC" == yes ]]; then
    emit_yaml reproducible "${COMMON_NOTE}
Rebuilt installer is byte-for-byte identical to the official release."
    echo "VERDICT: reproducible"; exit 0
else
    emit_yaml not_reproducible "${COMMON_NOTE}
Outer-file sha256 differs from official (mechanical verdict: not_reproducible).
${CLASS_HINT}"
    echo "VERDICT: not_reproducible (payload_diff=${PAYLOAD_DIFF})"; exit 1
fi
COMPARE
chmod +x "$VERIFY_SCRIPT"

log_info "Comparing (A vs B determinism, A vs official + dpkg-deb -R evidence)..."
RM_FLAG="--rm"; [[ "$KEEP_CONTAINER" == "true" ]] && RM_FLAG=""
set +e
docker run $RM_FLAG $DOCKER_RUN_EXTRA --platform linux/amd64 --user "$(id -u):$(id -g)" \
    -e BISQ_VERSION="$BISQ_VERSION" -e BISQ_TYPE="$BISQ_TYPE" \
    -e SCRIPT_VERSION="$SCRIPT_VERSION" -e OFFICIAL_PKG_NAME="$OFFICIAL_PKG_NAME" \
    -e LEGACY_TOOLCHAIN="$LEGACY_TOOLCHAIN" -e RECIPE_JDK_PIN="$RECIPE_JDK_PIN" \
    -v "${execution_dir}":/output \
    -v "${SRC_A}/desktop/package":/keys:ro \
    -v "${A_PKG}":/a:ro -v "${B_PKG}":/b:ro \
    -v "${VERIFY_SCRIPT}":/verify/verify-compare.sh:ro \
    --name "$CONTAINER_CMP" \
    "$IMAGE_NAME" bash /verify/verify-compare.sh 2>&1 | tee "${execution_dir}/container.log"
CMP_EXIT=${PIPESTATUS[0]}
set -e

# ---- Results ----
if [[ ! -f "${execution_dir}/COMPARISON_RESULTS.yaml" ]]; then
    ftbfs_die "Comparison produced no COMPARISON_RESULTS.yaml."
fi
log_info ""
log_info "======================================================"
log_info "RESULTS (${execution_dir}/COMPARISON_RESULTS.yaml)"
log_info "======================================================"
cat "${execution_dir}/COMPARISON_RESULTS.yaml"
log_info ""
log_info "Evidence:  ${execution_dir}/comparison-detail.txt"
log_info "Artifacts: ${ARTIFACTS_DIR} (build-a/, build-b/)"

VERDICT=$(awk -F': ' '/^verdict:/{print $2; exit}' "${execution_dir}/COMPARISON_RESULTS.yaml")
emit_results_block "$VERDICT" "$OFFICIAL_HASH" "$(git -C "$SRC_A" rev-parse HEAD 2>/dev/null || echo N/A)"
case "$VERDICT" in
    reproducible)     log_success "VERIFICATION COMPLETE: reproducible";     exit "$EXIT_SUCCESS" ;;
    not_reproducible) log_warn    "VERIFICATION COMPLETE: not_reproducible"; exit "$EXIT_BUILD_FAILED" ;;
    *)                log_warn    "VERIFICATION COMPLETE: ${VERDICT:-ftbfs}"; exit "$EXIT_BUILD_FAILED" ;;
esac
