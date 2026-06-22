#!/usr/bin/env bash
# ==============================================================================
# bisq1desktop_build.sh - Bisq 1 Desktop Reproducible Build Verification
# ==============================================================================
# Version:       v0.5.0
# Organization:  WalletScrutiny.com
# Last Modified: 2026-06-20
# Project:       https://github.com/bisq-network/bisq
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: DO NOT include changelog in script header
# Maintain changelog in separate file: ~/work/ws-notes/script-notes/desktop/bisq1/changelog.md
# ==============================================================================
#
# SCRIPT SUMMARY (v0.5.0 - Bisq 1.10.0+ toolchain):
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
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="v0.5.0"
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

usage() {
    cat << EOF
Bisq 1 Desktop Reproducible Build Verification Script (${SCRIPT_VERSION}, Bisq 1.10.0+ toolchain)

Usage:
  $(basename "$0") --version <version> --arch <arch> --type <type> [--binary <file|dir>]

Parameters:
  --version <version>    Bisq version (e.g., 1.10.0). Default: ${DEFAULT_VERSION}
  --arch <arch>          x86_64-linux | x86_64-linux-gnu
  --type <type>          deb | rpm
  --binary <file|dir>    Use this local official installer (file, or dir containing it).
  --apk <file|dir>       Alias for --binary.
  --no-cache             Force fresh Docker image build.
  --keep-container       Keep build/compare containers afterwards (for inspection).
  --help                 Show this help.

Builds the release tag TWICE (A/B determinism, always-on). Verdict is MECHANICAL on the outer-file
sha256. Full dpkg-deb -R evidence (payload vs packaging split) is written for human classification.

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
        --no-cache) NO_CACHE=true; shift ;;
        --keep-container) KEEP_CONTAINER=true; shift ;;
        *) log_warn "ignoring unknown argument: $1"; shift ;;
    esac
done

[[ -z "$BISQ_VERSION" ]] && BISQ_VERSION="$DEFAULT_VERSION"
[[ -z "$BISQ_ARCH" ]] && BISQ_ARCH="x86_64-linux-gnu"
[[ -z "$BISQ_TYPE" ]] && BISQ_TYPE="deb"
case "$BISQ_ARCH" in
    x86_64-linux|x86_64-linux-gnu) BISQ_ARCH="x86_64-linux-gnu" ;;
    *) die "Unsupported architecture: $BISQ_ARCH" "$EXIT_INVALID_PARAMS" ;;
esac
case "$BISQ_TYPE" in deb|rpm) ;; *) die "Unsupported type: $BISQ_TYPE (deb|rpm)" "$EXIT_INVALID_PARAMS" ;; esac
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
