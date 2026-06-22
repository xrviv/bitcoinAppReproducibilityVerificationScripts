#!/usr/bin/env bash
# ==============================================================================
# bisq1desktop_build.sh - Bisq 1 Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.7.1
# Organization:  WalletScrutiny.com
# Last Modified: 2026-06-22
# Project:       https://github.com/bisq-network/bisq
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/desktop/bisq1/changelog.md
# ==============================================================================
#
# SCRIPT SUMMARY (v0.7.1 - Bisq 1.10.0+ toolchain; deb/rpm self-build + Windows EXE via GH Actions):
#   Drives Bisq's first-party reproducible-build framework per docs/reproducible-builds/linux.md:
#     1. Clone the release tag TWICE on the host (clean A and B checkouts) + init submodules (required).
#     2. Build the pinned release-builder image FROM the cloned repo's own
#        docker/release-builder/linux/Dockerfile (azul/zulu-openjdk:21.0.6, JDK 21,
#        SOURCE_DATE_EPOCH=0, TZ=UTC, apt-snapshot pinned). No hand-copied Dockerfile -> no drift.
#     3. Run ./gradlew clean verifyReleaseBuild verifyInstallerEvidenceBundle in BOTH worktrees
#        (always-on A/B determinism check; mirrors upstream's Linux Release Builder workflow).
#     4. VERDICT IS MECHANICAL on the outer-file sha256 (WS policy is mechanical; see
#        review-notes/reproducibility-heuristics-packaged-artifacts.md). reproducible only if the
#        rebuilt installer is byte-identical to the official AND the two rebuilds (A,B) agree.
#     5. EVIDENCE for human classification (NOT a verdict input): extract official + rebuilt with
#        dpkg-deb -R (control fields, maintainer scripts, payload, modes, symlinks) and split the
#        diff into payload-vs-packaging so the report can apply reproducible_with_packaging_noise.
#   Rebuilt installers + upstream release/installer evidence bundles are copied to ./artifacts/.
#   Emits minimal COMPARISON_RESULTS.yaml (script_version, verdict, notes).
#
# SCOPE: 1.10.x toolchain only. The pre-1.10 JDK 11/17 script is retained for reference as
#   bisq1desktop_build.sh.v0.3.5.bak (legacy multi-field YAML + missing-`v` tag bug; not ABS-current).
#
# WINDOWS EXE (v0.7.1, --type exe --arch x86_64-windows): FULLY ISOLATED from deb/rpm. The Windows
#   installer is jpackage+WiX and CANNOT be built on this Linux host (no cross-build, no
#   docker/release-builder/windows/). By DEFAULT the script AUTO-TRIGGERS the GitHub Actions workflow
#   walletScrutinyCom/.github/workflows/bisq1-windows-build.yml (windows-2025, Zulu 21.0.6, pinned WiX
#   v3, A/B isolated worktrees, uploads both EXEs), polls/watches it (correlated by a unique request_id
#   echoed into the run-name), and downloads both built EXEs — same pattern as gingerwallet/sparrow.
#   It then applies the mechanical outer-sha256 verdict (A==B && A==official); extraction diff is
#   diagnostic-only. `--built <dir>` is an OPTIONAL offline override (skip CI, reuse downloaded EXEs).
#   Needs GITHUB_TOKEN/GH_TOKEN (perms TBD after first run) + docker for the gh helper, unless --built.
#   The exe branch returns before any docker/release-builder BUILD code, so deb/rpm logic is untouched.
#   Findings: ws-notes/build-notes/desktop/bisq/bisq1_v1.10.0-exe-findings-2026-06-22.md
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="v0.7.1"
SCRIPT_NAME="bisq1desktop_build.sh"
APP_NAME="Bisq 1"
APP_ID="bisq1"
REPO_URL="https://github.com/bisq-network/bisq"
DEFAULT_VERSION="1.10.0"

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

# ============================================================================
# WINDOWS EXE PATH (fully isolated; never enters the deb/rpm docker logic).
# The Windows installer (jpackage+WiX) cannot be built on Linux, so the build runs on a Windows
# GitHub Actions runner (bisq1-windows-build.yml on the fork). By DEFAULT this function TRIGGERS
# that workflow and DOWNLOADS both built EXEs (A and B) via the gh CLI in a helper container —
# the same end-to-end pattern as gingerwallet_build.sh / sparrowdesktop_build.sh. `--built <dir>`
# is an OFFLINE OVERRIDE that skips CI and reuses already-downloaded artifacts. Either way this
# function only COMPARES (mechanical A==B && A==official); it never builds on this host.
# Needs GITHUB_TOKEN/GH_TOKEN with permission to dispatch the workflow + read its artifacts
# (exact token type/permissions to be confirmed after the first real run) unless --built is used.
# The token is passed only via the container env (-e); it is never logged.
# ============================================================================
GH_REPO="${GH_REPO:-xrviv/WalletScrutinyCom}"
GH_WORKFLOW="bisq1-windows-build.yml"
GH_WORKFLOW_REF="${GH_WORKFLOW_REF:-master}"
GH_HELPER_IMAGE="bisq1-gh-helper"
GH_MOUNT_DIR=""

build_gh_helper() {
    log_info "Building gh helper container (debian:bookworm-slim + gh CLI)..."
    docker build -t "$GH_HELPER_IMAGE" - <<'GHEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq unzip \
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

# Run gh inside the helper container (GH_MOUNT_DIR mounted at /work).
# - GITHUB_TOKEN is exported and passed by NAME (`-e GITHUB_TOKEN`, no value) so it never enters argv.
#   (It still lives in the container's env; gh authenticates from it. Not logged by this script.)
# - Run as the host uid:gid so downloaded artifacts are user-owned (not root). HOME=/work gives gh a
#   writable config dir inside the mount.
gh_c() {
    docker run --rm -e GITHUB_TOKEN -e HOME=/work \
        --user "$(id -u):$(id -g)" \
        -v "${GH_MOUNT_DIR}:/work" -w /work "$GH_HELPER_IMAGE" gh "$@"
}

# Trigger bisq1-windows-build.yml, wait, download both EXE artifacts into <artdir>/A and /B.
acquire_built_exes_via_ci() {
    local ver="$1" artdir="$2" yaml="$3"
    export GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    # Missing token / docker = infrastructure unavailable -> ftbfs + exit 1 (EXIT_BUILD_FAILED), same
    # class as the deb/rpm 'docker not found' path (exit 2 is reserved for invalid CLI parameters).
    [[ -n "$GITHUB_TOKEN" ]] || { write_yaml "$yaml" ftbfs "GITHUB_TOKEN/GH_TOKEN required to dispatch CI + read artifacts; or pass --built <dir>."; die "GITHUB_TOKEN/GH_TOKEN (dispatch+artifact-read perms) required for --type exe (or use --built <dir>)" "$EXIT_BUILD_FAILED"; }
    command -v docker >/dev/null 2>&1 || { write_yaml "$yaml" ftbfs "docker required for the gh helper container."; die "docker not found" "$EXIT_BUILD_FAILED"; }
    docker info >/dev/null 2>&1 || { write_yaml "$yaml" ftbfs "docker daemon not running."; die "docker daemon not running" "$EXIT_BUILD_FAILED"; }
    GH_MOUNT_DIR="$artdir"; mkdir -p "$artdir"
    # gh helper image is a shared cached tooling image (debian base + apt pkgs unpinned; same shared
    # rationale as the release-builder image — rebuilt only when absent).
    if ! docker image inspect "$GH_HELPER_IMAGE" >/dev/null 2>&1; then
        build_gh_helper || { write_yaml "$yaml" ftbfs "gh helper image build failed (see output)."; die "gh helper image build failed" "$EXIT_BUILD_FAILED"; }
    fi

    # Unique correlation ID echoed into the workflow run-name so we attach to OUR run exactly,
    # not a concurrent one (timestamp/pre-ID heuristics can mis-select). Not a secret.
    local request_id; request_id="wsreq-${ver}-$(date -u +%Y%m%d%H%M%S)-${RANDOM}${RANDOM}"
    log_info "Triggering ${GH_WORKFLOW} on ${GH_REPO}@${GH_WORKFLOW_REF} (version=${ver}, request_id=${request_id})..."
    gh_c workflow run "$GH_WORKFLOW" --repo "$GH_REPO" --ref "$GH_WORKFLOW_REF" -f version="$ver" -f request_id="$request_id" \
        || { write_yaml "$yaml" ftbfs "Failed to trigger ${GH_WORKFLOW}."; die "workflow trigger failed" "$EXIT_BUILD_FAILED"; }

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
    [[ -n "$run_id" && "$run_id" != "null" ]] || { write_yaml "$yaml" ftbfs "Workflow run not found after polling."; die "workflow run not found" "$EXIT_BUILD_FAILED"; }
    log_info "Run ID ${run_id}; watching to completion (build ~20-30 min)..."
    gh_c run watch "$run_id" --repo "$GH_REPO" --exit-status \
        || { write_yaml "$yaml" ftbfs "GitHub Actions run ${run_id} failed."; die "workflow run ${run_id} failed" "$EXIT_BUILD_FAILED"; }
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
            || { write_yaml "$yaml" ftbfs "Failed to download bisq1-${ver}-win-exe-${label}."; die "artifact download failed (${label})" "$EXIT_BUILD_FAILED"; }
    done
    # Provenance artifact (workflow/runner/JDK+WiX versions, A/B hashes) — kept for the human report.
    rm -rf "${artdir:?}/provenance"; mkdir -p "${artdir}/provenance"
    gh_c run download "$run_id" --repo "$GH_REPO" --name "bisq1-${ver}-win-provenance" --dir "/work/provenance" 2>/dev/null \
        || log_warn "provenance artifact not downloaded (non-fatal)"
}

# Diagnostic-only extracted diff of two installer files -> outfile. VERDICT-NEUTRAL (never changes the
# verdict). Used for both A-vs-B (build non-determinism) and official-vs-built. Full diff retained.
diag_extract_diff() {
    local f1="$1" f2="$2" l1="$3" l2="$4" outfile="$5" detail="$6"
    rm -f "$outfile"
    if ! command -v 7z >/dev/null 2>&1; then
        echo "DIAGNOSTIC UNAVAILABLE: 7z not installed; $(basename "$outfile") skipped." >> "$detail"
        return 0
    fi
    local d1 d2 rc1=0 rc2=0; d1="$(mktemp -d)"; d2="$(mktemp -d)"
    7z x -y -o"$d1" "$f1" >/dev/null 2>&1 || rc1=$?
    7z x -y -o"$d2" "$f2" >/dev/null 2>&1 || rc2=$?
    if [[ "$rc1" -ne 0 || "$rc2" -ne 0 ]]; then
        echo "DIAGNOSTIC UNAVAILABLE: 7z extraction failed (${l1} rc=$rc1, ${l2} rc=$rc2); $(basename "$outfile") empty." \
            | tee "$outfile" >> "$detail"
    else
        echo "=== DIAGNOSTIC ONLY (verdict-neutral): diff -r ${l1} vs ${l2} ===" > "$outfile"
        local dstat=0
        diff -r "$d1" "$d2" >> "$outfile" 2>&1 || dstat=$?
        if [[ "$dstat" -le 1 ]]; then
            echo "Diagnostic FULL diff -> $(basename "$outfile") (diff status ${dstat}; preview below)" >> "$detail"
            head -5 "$outfile" >> "$detail"
        else
            echo "DIAGNOSTIC: diff errored (status ${dstat}); partial output in $(basename "$outfile")." >> "$detail"
        fi
    fi
    rm -rf "$d1" "$d2"
}

verify_windows_exe() {
    local execution_dir; execution_dir="$(pwd)"
    local yaml="${execution_dir}/COMPARISON_RESULTS.yaml"
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
            || { write_yaml "$yaml" "ftbfs" "Failed to download official ${official_name}."; die "download failed"; }
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

    # Diagnostics (VERDICT-NEUTRAL; never change the verdict above).
    #   A != B            -> diff build A vs build B (characterize the build non-determinism).
    #   A == B != official -> diff official vs build A (how the deterministic build differs from official).
    #   reproducible       -> nothing to diff.
    if [[ "$hA" != "$hB" ]]; then
        diag_extract_diff "${built[0]}" "${built[1]}" "build-A" "build-B" "${execution_dir}/diff_exe_AvsB.txt" "$detail"
    elif [[ "$hA" != "$hO" ]]; then
        diag_extract_diff "$official" "${built[0]}" "official" "build-A" "${execution_dir}/diff_exe.txt" "$detail"
    fi

    write_yaml "$yaml" "$verdict" "$notes"
    cat "$detail"
    log_info "Wrote ${yaml} (verdict: ${verdict})"
    [[ "$verdict" == "reproducible" ]] && return "$EXIT_SUCCESS" || return "$EXIT_BUILD_FAILED"
}

usage() {
    cat << EOF
Bisq 1 Desktop Reproducible Build Verification Script (${SCRIPT_VERSION}, Bisq 1.10.0+ toolchain)

Usage:
  $(basename "$0") --version <version> --arch <arch> --type <type> [--binary <file|dir>]

Parameters:
  --version <version>    Bisq version (e.g., 1.10.0). Default: ${DEFAULT_VERSION}
  --arch <arch>          x86_64-linux | x86_64-linux-gnu (deb/rpm) | x86_64-windows (exe)
  --type <type>          deb | rpm | exe
  --binary <file|dir>    Use this local official installer (file, or dir containing it).
  --apk <file|dir>       Alias for --binary.
  --built <dir>          (exe only, OPTIONAL) Offline override: dir with the two pre-downloaded built
                         EXEs (A and B). If omitted, the script triggers CI and downloads them itself.
  --no-cache             Force fresh Docker image build (deb/rpm only).
  --keep-container       Keep build/compare containers afterwards (deb/rpm only).
  --help                 Show this help.

ENV (exe only, unless --built): GITHUB_TOKEN or GH_TOKEN with permission to dispatch the workflow and
  read its artifacts (exact perms TBD after first run); docker is also required for the gh helper.

deb/rpm: builds the release tag TWICE on this host (A/B determinism, always-on) in the pinned
  release-builder container. Verdict is MECHANICAL on the outer-file sha256. Full dpkg-deb -R evidence
  (payload vs packaging split) is written for human classification.
exe (x86_64-windows): the Windows installer (jpackage+WiX) CANNOT be built on Linux. By default the
  script AUTO-TRIGGERS walletScrutinyCom/.github/workflows/bisq1-windows-build.yml (windows-2025, Zulu
  21.0.6, pinned WiX v3, A/B isolated), correlates the run by a unique request_id in the run-name,
  watches it, and downloads both built EXEs (same pattern as gingerwallet/sparrow). Verdict is mechanical
  (A==B && A==official by sha256); extracted diff is diagnostic. --built skips CI and reuses local EXEs.
  NOTE: installer embeds the build year (Year.now()), so verify v1.10.0 within 2026 (official=2026).

Output:
  - Exit 0: reproducible | Exit 1: differs/failed | Exit 2: invalid params
  - COMPARISON_RESULTS.yaml (script_version, verdict, notes)
  - artifacts/  (rebuilt installers A+B + upstream evidence bundles)
  - comparison-detail.txt (determinism + full extracted-tree evidence)

Organization: WalletScrutiny.com
EOF
}

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
execution_dir="$(pwd)"
SRC_A="${WORK_DIR}/src-a"
SRC_B="${WORK_DIR}/src-b"
ARTIFACTS_DIR="${execution_dir}/artifacts"; mkdir -p "$ARTIFACTS_DIR"

log_info "========================================================"
log_info "Bisq 1 Desktop Reproducible Build Verification (${SCRIPT_VERSION})"
log_info "========================================================"
log_info "Version: $BISQ_VERSION | Arch: $BISQ_ARCH | Type: $BISQ_TYPE"
log_info "Toolchain: pinned release-builder (azul/zulu-openjdk:21.0.6)"
log_info "Mode: A/B determinism (2 clean builds) + mechanical outer-hash verdict"
log_info "Work Dir: $WORK_DIR"
log_info ""

# ---- Docker preflight ----
command -v docker >/dev/null 2>&1 || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Docker not found on host."; die "Docker not found"; }
docker info >/dev/null 2>&1 || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Docker daemon not running."; die "Docker daemon not running"; }
log_success "Docker OK"

# ---- Stage official installer ----
if [[ -n "$OFFICIAL_BINARY" ]]; then
    log_info "Using provided official installer: $OFFICIAL_BINARY"
    cp "$OFFICIAL_BINARY" "${execution_dir}/${OFFICIAL_PKG_NAME}"
else
    log_info "Downloading official release: ${OFFICIAL_PKG_NAME}"
    curl -fL --progress-bar -o "${execution_dir}/${OFFICIAL_PKG_NAME}" \
        "https://github.com/bisq-network/bisq/releases/download/${BISQ_VERSION}/${OFFICIAL_PKG_NAME}" \
      || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Failed to download official ${OFFICIAL_PKG_NAME}."; die "download failed"; }
fi
OFFICIAL_HASH="$(sha256sum "${execution_dir}/${OFFICIAL_PKG_NAME}" | cut -d' ' -f1)"
log_success "Official staged: ${OFFICIAL_PKG_NAME} (sha256=${OFFICIAL_HASH})"

# ---- Two clean clones + submodules (REQUIRED) ----
clone_checkout() {  # dest label
    local dest="$1" label="$2"
    log_info "[$label] cloning + checkout ${BISQ_VERSION}..."
    git clone --quiet "$REPO_URL" "$dest" \
      || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "git clone failed ($label)."; die "git clone failed ($label)"; }
    git -C "$dest" checkout --quiet "$BISQ_VERSION" \
      || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "git checkout ${BISQ_VERSION} failed ($label)."; die "git checkout failed ($label)"; }
    git -C "$dest" submodule update --init --recursive --quiet \
      || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Submodule init failed ($label); upstream requires submodules."; die "submodule init failed ($label)"; }
    log_success "[$label] $(git -C "$dest" describe --tags 2>/dev/null || echo "$BISQ_VERSION") + submodules"
}
clone_checkout "$SRC_A" "A"
clone_checkout "$SRC_B" "B"

UPSTREAM_DOCKERDIR="${SRC_A}/docker/release-builder/linux"
if [[ ! -f "${UPSTREAM_DOCKERDIR}/Dockerfile" ]]; then
    write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "No docker/release-builder/linux/Dockerfile at ${BISQ_VERSION} (pre-1.10? use v0.3.5 script)."
    die "release-builder Dockerfile absent at ${BISQ_VERSION}"
fi

if [[ -f "${SRC_A}/gradle/wrapper/gradle-wrapper.sha256" ]]; then
    ( cd "$SRC_A" && sha256sum -c gradle/wrapper/gradle-wrapper.sha256 ) \
        && log_success "gradle-wrapper.sha256 verified" \
        || log_warn "gradle-wrapper.sha256 check reported issues (continuing; note for report)"
fi

# ---- Build pinned image from the cloned repo's own Dockerfile (no drift) ----
log_info "Building release-builder image from upstream Dockerfile..."
CACHE_FLAG=""; [[ "$NO_CACHE" == "true" ]] && CACHE_FLAG="--no-cache"
if ! docker build $CACHE_FLAG --pull=false --platform linux/amd64 \
        -t "$IMAGE_NAME" "$UPSTREAM_DOCKERDIR" 2>&1 | tee "${execution_dir}/build-image.log"; then
    write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "release-builder image build failed (see build-image.log)."
    die "image build failed"
fi
log_success "Image built: $IMAGE_NAME"

# ---- Run one clean build inside the image ----
gradle_build() {  # srcdir containername logfile label
    local src="$1" cname="$2" logf="$3" label="$4"
    local rmflag="--rm"; [[ "$KEEP_CONTAINER" == "true" ]] && rmflag=""
    log_info "[$label] building (clean verifyReleaseBuild verifyInstallerEvidenceBundle; 8-15 min)..."
    set +e
    docker run $rmflag --platform linux/amd64 --user "$(id -u):$(id -g)" \
        -v "${src}":/workspace -w /workspace \
        --name "$cname" \
        "$IMAGE_NAME" \
        ./gradlew --no-daemon clean verifyReleaseBuild verifyInstallerEvidenceBundle 2>&1 | tee "$logf"
    local rc=${PIPESTATUS[0]}
    set -e
    return $rc
}

if ! gradle_build "$SRC_A" "$CONTAINER_A" "${execution_dir}/build-a.log" "A"; then
    write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Build A failed (see build-a.log)."
    die "build A failed"
fi
log_success "Build A complete"
if ! gradle_build "$SRC_B" "$CONTAINER_B" "${execution_dir}/build-b.log" "B"; then
    write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Build B failed (see build-b.log)."
    die "build B failed"
fi
log_success "Build B complete"

# ---- Locate rebuilt installers (host side; volumes are host-owned) ----
find_pkg() {  # srcdir
    if [[ "$BISQ_TYPE" == "deb" ]]; then
        find "$1/desktop/build/packaging/jpackage/packages" -name "bisq_*_amd64.deb" 2>/dev/null | head -1
    else
        find "$1/desktop/build/packaging/jpackage/packages" -name "bisq-*.x86_64.rpm" 2>/dev/null | head -1
    fi
}
A_PKG="$(find_pkg "$SRC_A")"; B_PKG="$(find_pkg "$SRC_B")"
[[ -n "$A_PKG" && -n "$B_PKG" ]] || { write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "rebuilt .${BISQ_TYPE} not found in one or both builds."; die "rebuilt installer missing"; }

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

# ---- MECHANICAL verdict: outer hash only (WS policy). reproducible iff A==official AND A==B. ----
DET_NOTE="A/B determinism: $([[ "$DETERMINISTIC" == yes ]] && echo "build is deterministic (A==B)" || echo "BUILD IS NON-DETERMINISTIC (A!=B)")."
if [[ "$BISQ_TYPE" == deb ]]; then HINT_TOOL="dpkg-deb -R"; else HINT_TOOL="rpm2cpio"; fi
case "$PAYLOAD_DIFF" in
  none)    CLASS_HINT="CLASSIFICATION HINT: extracted payload + modes/symlinks are IDENTICAL to official ($HINT_TOOL); the only differences are ${BISQ_TYPE} packaging/compression metadata. Candidate for human label 'reproducible_with_packaging_noise' per review-notes/reproducibility-heuristics-packaged-artifacts.md." ;;
  present) CLASS_HINT="CLASSIFICATION HINT: real payload differences vs official exist (see comparison-detail.txt). Genuine non-reproducibility." ;;
  *)       CLASS_HINT="CLASSIFICATION HINT: payload classification unavailable (extraction failed); see comparison-detail.txt." ;;
esac

COMMON_NOTE="Bisq 1 ${BISQ_VERSION} ${BISQ_TYPE} built with the pinned 1.10.0 release-builder (azul/zulu-openjdk:21.0.6) via 'clean verifyReleaseBuild verifyInstallerEvidenceBundle'.
official_sha256=${OFF_H} build_a_sha256=${A_H} build_b_sha256=${B_H}.
${DET_NOTE}"

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
docker run $RM_FLAG --platform linux/amd64 --user "$(id -u):$(id -g)" \
    -e BISQ_VERSION="$BISQ_VERSION" -e BISQ_TYPE="$BISQ_TYPE" \
    -e SCRIPT_VERSION="$SCRIPT_VERSION" -e OFFICIAL_PKG_NAME="$OFFICIAL_PKG_NAME" \
    -v "${execution_dir}":/output \
    -v "${A_PKG}":/a:ro -v "${B_PKG}":/b:ro \
    -v "${VERIFY_SCRIPT}":/verify/verify-compare.sh:ro \
    --name "$CONTAINER_CMP" \
    "$IMAGE_NAME" bash /verify/verify-compare.sh 2>&1 | tee "${execution_dir}/container.log"
CMP_EXIT=${PIPESTATUS[0]}
set -e

# ---- Results ----
if [[ ! -f "${execution_dir}/COMPARISON_RESULTS.yaml" ]]; then
    write_yaml "${execution_dir}/COMPARISON_RESULTS.yaml" ftbfs "Comparison produced no COMPARISON_RESULTS.yaml."
    die "no YAML produced"
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
case "$VERDICT" in
    reproducible)     log_success "VERIFICATION COMPLETE: reproducible";     exit "$EXIT_SUCCESS" ;;
    not_reproducible) log_warn    "VERIFICATION COMPLETE: not_reproducible"; exit "$EXIT_BUILD_FAILED" ;;
    *)                log_warn    "VERIFICATION COMPLETE: ${VERDICT:-ftbfs}"; exit "$EXIT_BUILD_FAILED" ;;
esac
