#!/usr/bin/env bash
# bisq2_build.sh - Bisq2 Desktop Reproducible Build Verification
# Version:       v0.1.20
# Organization:  WalletScrutiny.com
# Last Modified: 2026-06-04
# Project:       https://github.com/bisq-network/bisq2
# License:       MIT
set -euo pipefail

SCRIPT_VERSION="v0.1.20"
REPO_URL="https://github.com/bisq-network/bisq2"
GH_REPO="xrviv/WalletScrutinyCom"
GH_WORKFLOW="bisq2-windows-build.yml"
GH_WORKFLOW_REF="master"
GH_HELPER_IMAGE="bisq2-gh-helper"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

EXIT_SUCCESS=0
EXIT_DIFFERENCES=1
EXIT_INVALID_PARAMS=2

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[OK] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }

VERSION=""
ARCH="x86_64-linux-gnu"
ARCH_PROVIDED=false
BUILD_TYPE="deb"
BINARY_FILE=""
NO_CACHE=false
KEEP_CONTAINER=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_EXECUTION_DIR="$SCRIPT_DIR"

IMAGE_NAME=""
CONTAINER_NAME=""
WORK_DIR=""

sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input##-}"
    input="${input%%-}"
    [[ -z "$input" ]] && input="na"
    echo "$input"
}

write_yaml() {
    local verdict="$1"
    local notes="${2:-}"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        if [[ -n "$notes" ]]; then
            echo "notes: |"
            echo "$notes" | sed 's/^/  /'
        fi
    } > "${ORIGINAL_EXECUTION_DIR}/COMPARISON_RESULTS.yaml"
}

die() {
    local msg="$1"
    local code="${2:-$EXIT_DIFFERENCES}"
    log_error "$msg"
    write_yaml "ftbfs" "$msg"
    exit "$code"
}

usage() {
    cat << EOF
bisq2_build.sh ${SCRIPT_VERSION} — WalletScrutiny.com

Usage: $(basename "$0") --version <version> [options]

  --version <version>  Bisq2 version, e.g. 2.1.11 [required]
  --arch <arch>        x86_64-linux-gnu (default), x86_64-windows
  --type <type>        deb (default), rpm, exe
                       NOTE: type is NOT auto-detected from --binary filename.
  --binary <file>      Path to official DEB/RPM/EXE; skips download
  --no-cache           Force fresh image build
  --keep-container     Keep container after build

Examples:
  $(basename "$0") --version 2.1.11
  $(basename "$0") --version 2.1.11 --type rpm
  $(basename "$0") --version 2.1.11 --type exe --arch x86_64-windows
EOF
}

require_arg() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" ]] || [[ "$value" == --* ]]; then
        log_error "Missing value for parameter: $option"
        write_yaml "ftbfs" "missing value for $option"
        exit "$EXIT_INVALID_PARAMS"
    fi
}


detect_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    else
        die "Neither podman nor docker found" "$EXIT_INVALID_PARAMS"
    fi
}

build_gh_helper() {
    log_info "Building gh helper container: $GH_HELPER_IMAGE"
    "$CONTAINER_RUNTIME" build -t "$GH_HELPER_IMAGE" - <<'GHEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq unzip p7zip-full \
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

gh_c() {
    "$CONTAINER_RUNTIME" run --rm \
        -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        -v "${WORK_DIR}:/work" \
        -w /work \
        "$GH_HELPER_IMAGE" \
        gh "$@"
}

run_helper() {
    "$CONTAINER_RUNTIME" run --rm \
        -v "${WORK_DIR}:/work" \
        -w /work \
        "$GH_HELPER_IMAGE" \
        "$@"
}

windows_finish() {
    local code="${1:-0}"
    log_info "--------"
    log_info "Output files in: $WORK_DIR"
    log_info "--------"
    for f in COMPARISON_RESULTS.yaml windows-hash-diff.txt windows-official-files.sha256 windows-built-files.sha256 gh-run.log official-7z.log built-7z.log; do
        [[ -f "$WORK_DIR/$f" ]] && log_info "  $f ($(wc -l < "$WORK_DIR/$f") lines)"
    done
    [[ -f "$WORK_DIR/COMPARISON_RESULTS.yaml" ]] && cp "$WORK_DIR/COMPARISON_RESULTS.yaml" "$ORIGINAL_EXECUTION_DIR/COMPARISON_RESULTS.yaml"
    echo "Exit code: 0"
    exit "$code"
}

windows_yaml() {
    local verdict="$1"
    local notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        echo "notes: |"
        echo "$notes" | sed 's/^/  /'
    } > "$WORK_DIR/COMPARISON_RESULTS.yaml"
}

run_windows_verification() {
    VERSION_SLUG=$(sanitize_component "$VERSION_CLEAN")
    ARCH_SLUG=$(sanitize_component "$ARCH")
    TYPE_SLUG=$(sanitize_component "$BUILD_TYPE")
    WORK_DIR="${SCRIPT_DIR}/bisq2_${VERSION_SLUG}_${ARCH_SLUG}_${TYPE_SLUG}_$$"
    mkdir -p "$WORK_DIR/official" "$WORK_DIR/built"

    detect_container_runtime
    log_info "Container runtime: $CONTAINER_RUNTIME"
    if ! "$CONTAINER_RUNTIME" image inspect "$GH_HELPER_IMAGE" >/dev/null 2>&1; then
        build_gh_helper || die "Failed to build gh helper container"
    fi

    log_info "--------"
    log_info "Bisq2 Windows Build Verification"
    log_info "--------"
    log_info "Version:   $VERSION_CLEAN"
    log_info "Git tag:   $GIT_TAG"
    log_info "Arch:      $ARCH"
    log_info "Type:      $BUILD_TYPE"
    log_info "Artifact:  $OFFICIAL_ARTIFACT"
    log_info "Scope:     single artifact"
    log_info "Work dir:  $WORK_DIR"
    log_info "Script:    $SCRIPT_VERSION"
    log_info "--------"

    OFFICIAL_EXE="$WORK_DIR/official/$OFFICIAL_ARTIFACT"
    if [[ -n "$BINARY_FILE" ]]; then
        cp "$BINARY_FILE" "$OFFICIAL_EXE"
        log_info "Using provided official binary: $(basename "$BINARY_FILE")"
    else
        log_info "Downloading official: $GITHUB_RELEASE_URL"
        run_helper curl -fL -o "/work/official/$OFFICIAL_ARTIFACT" "$GITHUB_RELEASE_URL" \
            || { windows_yaml "ftbfs" "Failed to download official Windows artifact: $GITHUB_RELEASE_URL"; windows_finish 0; }
    fi

    mapfile -t PRE_TRIGGER_IDS < <(gh_c run list \
        --repo "$GH_REPO" --workflow "$GH_WORKFLOW" \
        --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)
    TRIGGER_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log_info "Triggering GitHub Actions workflow on $GH_REPO..."
    if ! gh_c workflow run "$GH_WORKFLOW" \
        --repo "$GH_REPO" \
        --ref "$GH_WORKFLOW_REF" \
        -f version="$VERSION_CLEAN" \
        -f jdk_version="21.0.11"; then
        windows_yaml "ftbfs" "Failed to trigger GitHub Actions workflow ${GH_WORKFLOW} on ${GH_REPO}."
        windows_finish 0
    fi

    log_info "Waiting for workflow run to appear..."
    RUN_ID=""
    for i in $(seq 1 30); do
        sleep 10
        mapfile -t CANDIDATES < <(gh_c run list \
            --repo "$GH_REPO" \
            --workflow "$GH_WORKFLOW" \
            --limit 10 \
            --json databaseId,createdAt \
            --jq "[.[] | select(.createdAt >= \"${TRIGGER_TIME}\")] | .[].databaseId" \
            2>/dev/null || true)
        for cid in "${CANDIDATES[@]:-}"; do
            [[ -z "$cid" || "$cid" == "null" ]] && continue
            is_new=true
            for pid in "${PRE_TRIGGER_IDS[@]:-}"; do
                [[ "$cid" == "$pid" ]] && is_new=false && break
            done
            if [[ "$is_new" == "true" ]]; then
                RUN_ID="$cid"
                break
            fi
        done
        [[ -n "$RUN_ID" ]] && break
        log_info "Poll attempt ${i}/30..."
    done

    if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
        windows_yaml "ftbfs" "GitHub Actions workflow run was not found after polling."
        windows_finish 0
    fi

    log_info "Watching workflow run $RUN_ID..."
    if ! gh_c run watch "$RUN_ID" --repo "$GH_REPO" --exit-status; then
        gh_c run view "$RUN_ID" --repo "$GH_REPO" --log > "$WORK_DIR/gh-run.log" 2>&1 || true
        windows_yaml "ftbfs" "GitHub Actions workflow run ${RUN_ID} failed. See gh-run.log."
        windows_finish 0
    fi
    gh_c run view "$RUN_ID" --repo "$GH_REPO" --log > "$WORK_DIR/gh-run.log" 2>&1 || true

    log_info "Downloading built Windows EXE artifact..."
    if ! gh_c run download "$RUN_ID" \
        --repo "$GH_REPO" \
        --name "bisq2-${VERSION_CLEAN}-win-exe" \
        --dir /work/built; then
        windows_yaml "ftbfs" "Failed to download built Windows EXE artifact from workflow run ${RUN_ID}."
        windows_finish 0
    fi

    BUILT_EXE=$(find "$WORK_DIR/built" -type f -iname "*.exe" | sort | head -1)
    if [[ -z "$BUILT_EXE" ]]; then
        windows_yaml "ftbfs" "Workflow artifact did not contain a Windows .exe file."
        windows_finish 0
    fi

    OFFICIAL_HASH=$(sha256sum "$OFFICIAL_EXE" | cut -d' ' -f1)
    BUILT_HASH=$(sha256sum "$BUILT_EXE" | cut -d' ' -f1)
    OFFICIAL_SIZE=$(du -b "$OFFICIAL_EXE" | cut -f1)
    BUILT_SIZE=$(du -b "$BUILT_EXE" | cut -f1)

    echo ""
    echo "=== Hash Comparison ==="
    echo "Official: $OFFICIAL_HASH"
    echo "Built:    $BUILT_HASH"

    ARTIFACT_NOTES_BASE="Bisq2 ${VERSION_CLEAN} ${BUILD_TYPE} (${ARCH}).
Artifact verdict scope: ${OFFICIAL_ARTIFACT} only.
Built from tag: ${GIT_TAG} using GitHub Actions workflow ${GH_WORKFLOW} run ${RUN_ID}.
Verified artifact: ${OFFICIAL_ARTIFACT}
Official SHA256: ${OFFICIAL_HASH}
Built SHA256: ${BUILT_HASH}"

    if [[ "$OFFICIAL_HASH" == "$BUILT_HASH" ]]; then
        windows_yaml "reproducible" "${ARTIFACT_NOTES_BASE}
Hashes match: true.
Windows EXE is byte-for-byte reproducible."
        echo "===== Begin Results ====="
        echo "appId:          bisq2"
        echo "artifact:       $OFFICIAL_ARTIFACT"
        echo "artifactType:   $BUILD_TYPE"
        echo "artifactArch:   $ARCH"
        echo "verdictScope:   single artifact"
        echo "verdict:        reproducible"
        echo "appHash:        $OFFICIAL_HASH"
        echo "commit:         $GIT_TAG"
        echo "===== End Results ====="
        windows_finish 0
    fi

    log_warn "Hashes differ — attempting 7z content extraction"
    run_helper bash -lc "7z x '/work/official/$OFFICIAL_ARTIFACT' -o'/work/extracted-official' -y >/work/official-7z.log 2>&1 || true"
    BUILT_REL="${BUILT_EXE#$WORK_DIR/}"
    log_info "Built EXE path: $BUILT_REL"
    run_helper bash -lc "7z x '/work/$BUILT_REL' -o'/work/extracted-built' -y >/work/built-7z.log 2>&1 || true"

    if [[ ! -d "$WORK_DIR/extracted-official" ]] || [[ ! -d "$WORK_DIR/extracted-built" ]]; then
        windows_yaml "not_reproducible" "${ARTIFACT_NOTES_BASE}
Hashes match: false.
7z extraction did not produce comparable directories. See official-7z.log and built-7z.log."
        windows_finish 0
    fi

    (cd "$WORK_DIR/extracted-official" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's#  \\./#  #') > "$WORK_DIR/windows-official-files.sha256"
    (cd "$WORK_DIR/extracted-built" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's#  \\./#  #') > "$WORK_DIR/windows-built-files.sha256"
    log_info "Extracted files: official=$(wc -l < "$WORK_DIR/windows-official-files.sha256") built=$(wc -l < "$WORK_DIR/windows-built-files.sha256")"

    if diff -u "$WORK_DIR/windows-official-files.sha256" "$WORK_DIR/windows-built-files.sha256" > "$WORK_DIR/windows-hash-diff.txt"; then
        log_info "7z-extracted file hashes match"
        windows_yaml "reproducible" "${ARTIFACT_NOTES_BASE}
Hashes match: false.
Official size: ${OFFICIAL_SIZE} bytes. Built size: ${BUILT_SIZE} bytes.
The EXE wrapper hash differs, but 7z-extracted content matches. Installer-wrapper metadata is excluded from this artifact verdict."
        RESULT_LABEL="reproducible"
    else
        DIFF_LINES=$(wc -l < "$WORK_DIR/windows-hash-diff.txt")
        JAR_DIFF_LINES=$(grep -c '\.jar' "$WORK_DIR/windows-hash-diff.txt" 2>/dev/null || true)
        log_warn "7z-extracted hashes differ: ${DIFF_LINES} diff lines; ${JAR_DIFF_LINES} jar lines"
        windows_yaml "not_reproducible" "${ARTIFACT_NOTES_BASE}
Hashes match: false.
Official size: ${OFFICIAL_SIZE} bytes. Built size: ${BUILT_SIZE} bytes.
7z-extracted Windows EXE content differs. Diff lines: ${DIFF_LINES}. JAR-related diff lines: ${JAR_DIFF_LINES}. See windows-hash-diff.txt."
        RESULT_LABEL="differences found"
    fi

    echo "===== Begin Results ====="
    echo "appId:          bisq2"
    echo "artifact:       $OFFICIAL_ARTIFACT"
    echo "artifactType:   $BUILD_TYPE"
    echo "artifactArch:   $ARCH"
    echo "verdictScope:   single artifact"
    echo "verdict:        $RESULT_LABEL"
    echo "appHash:        $OFFICIAL_HASH"
    echo "commit:         $GIT_TAG"
    echo ""
    echo "Diff (first 5 lines):"
    head -5 "$WORK_DIR/windows-hash-diff.txt" 2>/dev/null || echo "(no differences)"
    echo "===== End Results ====="
    windows_finish 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        require_arg "$@"; VERSION="$2";     shift 2 ;;
        --arch)           require_arg "$@"; ARCH="$2"; ARCH_PROVIDED=true; shift 2 ;;
        --type)           require_arg "$@"; BUILD_TYPE="$2";  shift 2 ;;
        --binary)         require_arg "$@"; BINARY_FILE="$2"; shift 2 ;;
        --no-cache)       NO_CACHE=true;      shift ;;
        --keep-container) KEEP_CONTAINER=true; shift ;;
        --help|-h)        usage; exit 0 ;;
        --apk)
            log_warn "--apk is not applicable for desktop builds — ignoring"
            if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                shift 2
            else
                shift
            fi
            ;;
        *)
            log_warn "Unknown parameter: $1 — ignoring"
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    log_error "Missing required parameter: --version"
    write_yaml "ftbfs" "missing --version"
    usage
    exit "$EXIT_INVALID_PARAMS"
fi

VERSION_CLEAN="${VERSION#v}"
GIT_TAG="v${VERSION_CLEAN}"

case "$ARCH" in
    x86_64-linux|x86_64-linux-gnu) ARCH="x86_64-linux-gnu" ;;
    x86_64-windows|win-x64|win64|windows) ARCH="x86_64-windows" ;;
    *)
        log_warn "Unsupported arch: $ARCH — defaulting to x86_64-linux-gnu"
        ARCH="x86_64-linux-gnu"
        ;;
esac

case "$BUILD_TYPE" in
    deb|rpm) ;;
    exe)
        if [[ "$ARCH" != "x86_64-windows" ]]; then
            if [[ "$ARCH_PROVIDED" == "false" ]]; then
                ARCH="x86_64-windows"
            else
                log_error "--type exe requires --arch x86_64-windows"
                write_yaml "ftbfs" "--type exe requires --arch x86_64-windows"
                exit "$EXIT_INVALID_PARAMS"
            fi
        fi
        ;;
    *)
        log_error "unsupported --type: $BUILD_TYPE; valid: deb, rpm, exe"
        write_yaml "ftbfs" "unsupported --type ${BUILD_TYPE}; valid: deb, rpm, exe"
        exit "$EXIT_INVALID_PARAMS"
        ;;
esac

if [[ "$ARCH" == "x86_64-windows" && "$BUILD_TYPE" != "exe" ]]; then
    log_error "--arch $ARCH with --type $BUILD_TYPE: only --type exe supported for Windows"
    write_yaml "ftbfs" "--arch x86_64-windows supports only --type exe"
    exit "$EXIT_INVALID_PARAMS"
fi

if [[ "$BUILD_TYPE" == "deb" ]]; then
    BUILT_ARTIFACT="bisq2_${VERSION_CLEAN}-1_amd64.deb"
    OFFICIAL_ARTIFACT="Bisq-${VERSION_CLEAN}.deb"
elif [[ "$BUILD_TYPE" == "rpm" ]]; then
    BUILT_ARTIFACT="bisq2-${VERSION_CLEAN}-1.x86_64.rpm"
    OFFICIAL_ARTIFACT="Bisq-${VERSION_CLEAN}.rpm"
else
    BUILT_ARTIFACT="Bisq-${VERSION_CLEAN}.exe"
    OFFICIAL_ARTIFACT="Bisq-${VERSION_CLEAN}.exe"
fi

GITHUB_RELEASE_URL="${REPO_URL}/releases/download/${GIT_TAG}/${OFFICIAL_ARTIFACT}"

if [[ -n "$BINARY_FILE" ]]; then
    [[ ! -f "$BINARY_FILE" ]] && die "Binary file not found: $BINARY_FILE" "$EXIT_INVALID_PARAMS"
    EARLY_BINARY_FILENAME=$(basename "$BINARY_FILE")
    if [[ "$EARLY_BINARY_FILENAME" != "$OFFICIAL_ARTIFACT" ]]; then
        die "Binary filename mismatch for requested artifact: expected $OFFICIAL_ARTIFACT, got $EARLY_BINARY_FILENAME. Check --version and --type." "$EXIT_INVALID_PARAMS"
    fi
fi

if [[ "$BUILD_TYPE" == "exe" ]]; then
    run_windows_verification
fi

VERSION_SLUG=$(sanitize_component "$VERSION_CLEAN")
ARCH_SLUG=$(sanitize_component "$ARCH")
TYPE_SLUG=$(sanitize_component "$BUILD_TYPE")
SUFFIX=$(sanitize_component "$(date +%s)-$$")

IMAGE_NAME="ws-bisq2-image-${VERSION_SLUG}-${ARCH_SLUG}-${TYPE_SLUG}-${SUFFIX}"
CONTAINER_NAME="ws-bisq2-container-${VERSION_SLUG}-${ARCH_SLUG}-${TYPE_SLUG}-${SUFFIX}"
WORK_DIR="${SCRIPT_DIR}/bisq2_${VERSION_SLUG}_${ARCH_SLUG}_${TYPE_SLUG}_$$"
BUILD_CONTEXT=$(mktemp -d /tmp/ws-bisq2-context-XXXXXX)
mkdir -p "$WORK_DIR"

CONTAINER_RUNTIME=""
if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    die "Neither podman nor docker found"
fi
log_info "Container runtime: $CONTAINER_RUNTIME"

cleanup_on_exit() {
    if [[ "$KEEP_CONTAINER" == "false" ]] && [[ -n "${CONTAINER_NAME:-}" ]]; then
        $CONTAINER_RUNTIME stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        $CONTAINER_RUNTIME rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ "$KEEP_CONTAINER" == "false" ]] && [[ -n "${IMAGE_NAME:-}" ]]; then
        $CONTAINER_RUNTIME rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
    fi
    rm -rf "${BUILD_CONTEXT:-}" 2>/dev/null || true
}
trap cleanup_on_exit EXIT INT TERM

log_info "--------"
log_info "Bisq2 Desktop Build Verification"
log_info "--------"
log_info "Version:   $VERSION_CLEAN"
log_info "Git tag:   $GIT_TAG"
log_info "Arch:      $ARCH"
log_info "Type:      $BUILD_TYPE"
log_info "Artifact:  $OFFICIAL_ARTIFACT"
log_info "Scope:     single artifact"
log_info "Work dir:  $WORK_DIR"
log_info "Script:    $SCRIPT_VERSION"
log_info "--------"

DOCKERFILE="$BUILD_CONTEXT/Dockerfile"
cat > "$DOCKERFILE" << 'DOCKERFILE_EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y \
    git curl wget unzip fakeroot rpm dpkg cpio binutils procps \
    libasound2 libxi6 libxrender1 libxtst6 \
    apt-transport-https gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# fakeroot passthrough: jpackage calls "fakeroot dpkg-deb -b" internally;
# ptrace/preload breaks in rootless Podman even with --privileged.
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/fakeroot \
    && chmod 755 /usr/local/bin/fakeroot

RUN apt-get update && apt-get install -y tor && rm -rf /var/lib/apt/lists/*

ENV ZULU_JDK_ARCHIVE_SHA256=bc5e3383431cb7f1dce8c262dd474501ee9bd7569f1c59a8b6fe5c1589aa4a58

RUN wget -q https://cdn.azul.com/zulu/bin/zulu21.50.19-ca-jdk21.0.11-linux_x64.tar.gz \
        -O /tmp/zulu21.tar.gz \
    && echo "${ZULU_JDK_ARCHIVE_SHA256}  /tmp/zulu21.tar.gz" | sha256sum -c - \
    && mkdir -p /usr/lib/jvm \
    && tar -xzf /tmp/zulu21.tar.gz -C /usr/lib/jvm \
    && rm /tmp/zulu21.tar.gz

ENV JAVA_HOME=/usr/lib/jvm/zulu21.50.19-ca-jdk21.0.11-linux_x64
ENV PATH="${JAVA_HOME}/bin:${PATH}"
RUN java -version

COPY .bisq2-container-script.sh /bisq2-container-script.sh
RUN chmod +x /bisq2-container-script.sh
CMD ["/bisq2-container-script.sh"]
DOCKERFILE_EOF

CONTAINER_SCRIPT="$BUILD_CONTEXT/.bisq2-container-script.sh"
cat > "$CONTAINER_SCRIPT" << 'CONTAINER_EOF'
#!/bin/bash
set -uo pipefail

GIT_TAG="${GIT_TAG:-v2.1.11}"
VERSION_CLEAN="${VERSION_CLEAN:-2.1.11}"
BUILD_TYPE="${BUILD_TYPE:-deb}"
ARCH="${ARCH:-x86_64-linux-gnu}"
BUILT_ARTIFACT="${BUILT_ARTIFACT:-bisq2_2.1.11-1_amd64.deb}"
OFFICIAL_ARTIFACT="${OFFICIAL_ARTIFACT:-Bisq-2.1.11.deb}"
GITHUB_RELEASE_URL="${GITHUB_RELEASE_URL:-}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-false}"
BINARY_FILENAME="${BINARY_FILENAME:-}"
HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"

OUTPUT="/output"
mkdir -p "$OUTPUT"

fix_output_ownership() {
    if [[ -n "$HOST_UID" ]] && [[ -n "$HOST_GID" ]]; then
        chown -R "${HOST_UID}:${HOST_GID}" "$OUTPUT" 2>/dev/null || true
    fi
}
trap fix_output_ownership EXIT

export TZ=UTC
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

write_yaml() {
    local verdict="$1"
    local notes="$2"
    {
        echo "script_version: ${SCRIPT_VERSION}"
        echo "verdict: ${verdict}"
        if [[ -n "$notes" ]]; then
            echo "notes: |"
            echo "$notes" | sed 's/^/  /'
        fi
    } > "$OUTPUT/COMPARISON_RESULTS.yaml"
}

fail() {
    echo "[ERROR] $1"
    write_yaml "ftbfs" "$1"
    exit 1
}

script_fail() {
    echo "[ERROR] $1"
    exit 1
}

artifact_is_complete() {
    local artifact="$1"
    local size

    [[ -f "$artifact" ]] || return 1
    size=$(stat -c%s "$artifact" 2>/dev/null || echo 0)
    [[ "$size" -ge 1048576 ]] || return 1

    if [[ "$BUILD_TYPE" == "deb" ]]; then
        ar t "$artifact" 2>/dev/null | grep -Eq '^data\.tar(\..+)?$'
    else
        rpm -qpl "$artifact" >/dev/null 2>&1
    fi
}

record_packaging_diagnostics() {
    local artifact="$1"
    local package_dir
    package_dir=$(dirname "$artifact")

    cp "$artifact" "$OUTPUT/" 2>/dev/null || true
    {
        echo "=== Bisq2 Packaging Diagnostics ==="
        echo "Artifact: $artifact"
        echo "Type: $BUILD_TYPE"
        echo ""
        echo "=== Package directory ==="
        ls -lh "$package_dir" 2>&1 || true
        echo ""
        echo "=== Artifact members ==="
        if [[ "$BUILD_TYPE" == "deb" ]]; then
            ar t "$artifact" 2>&1 || true
        else
            rpm -qpl "$artifact" 2>&1 || true
        fi
        echo ""
        echo "=== Staging directories ==="
        find "$package_dir/.." -maxdepth 2 -type d -name 'temp_*' \
            -exec du -sh {} + 2>&1 || true
        echo ""
        echo "=== Remaining packaging processes ==="
        ps -ef 2>&1 | grep -E 'jpackage|dpkg-deb|rpmbuild|fakeroot' || true
    } > "$OUTPUT/packaging-diagnostics.txt"
}

wait_for_complete_artifact() {
    local artifact="$1"
    local timeout_seconds=900
    local poll_seconds=5
    local elapsed=0
    local size

    while ! artifact_is_complete "$artifact"; do
        if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
            record_packaging_diagnostics "$artifact"
            return 1
        fi

        size=$(stat -c%s "$artifact" 2>/dev/null || echo 0)
        echo "[INFO] Waiting for complete ${BUILD_TYPE} artifact (${elapsed}s elapsed, ${size} bytes)..."
        sleep "$poll_seconds"
        elapsed=$((elapsed + poll_seconds))
    done

    echo "[INFO] Complete ${BUILD_TYPE} artifact detected after ${elapsed}s"
}

print_results() {
    echo ""
    echo "===== Begin Results ====="
    echo "appId:          bisq2"
    echo "artifact:       $OFFICIAL_ARTIFACT"
    echo "artifactType:   $BUILD_TYPE"
    echo "artifactArch:   $ARCH"
    echo "verdictScope:   single artifact"
    echo "signer:         N/A"
    echo "apkVersionName: $VERSION_CLEAN"
    echo "apkVersionCode: N/A"
    echo "verdict:        $RESULT_LABEL"
    echo "appHash:        $OFFICIAL_HASH"
    echo "commit:         $GIT_TAG"
    echo ""
    echo "Revision: $GIT_TAG"
    echo ""
    echo "Diff (first 5 lines):"
    head -5 "$DIFF_BRIEF"
    echo "===== End Results ====="
    echo "Exit code: 0"
}

echo "=== Bisq2 Verification Container ==="
echo "Version:   $VERSION_CLEAN"
echo "Git tag:   $GIT_TAG"
echo "Type:      $BUILD_TYPE"
echo "Artifact:  $OFFICIAL_ARTIFACT"
echo "Scope:     single artifact"
echo "Java:      $(java -version 2>&1 | head -1)"
echo "JDK SHA256: $ZULU_JDK_ARCHIVE_SHA256"
echo ""

echo "[INFO] Cloning $GIT_TAG..."
git clone https://github.com/bisq-network/bisq2.git /build/bisq2 \
    || fail "git clone failed"

cd /build/bisq2
git fetch --tags --force || fail "git fetch --tags failed"
git checkout "$GIT_TAG" || fail "git checkout failed"
git describe --tags --exact-match >/dev/null 2>&1 || fail "checked out commit is not exactly $GIT_TAG"

# core.abbrev 10: pins short-hash to 10 chars to match the official release binary
git config core.abbrev 10

SOURCE_DATE_EPOCH=$(git log -1 --format=%ct "$GIT_TAG" 2>/dev/null || true)
[[ -n "$SOURCE_DATE_EPOCH" ]] && export SOURCE_DATE_EPOCH
if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
    export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS} -Duser.timezone=UTC -Dfile.encoding=UTF-8"
else
    export JAVA_TOOL_OPTIONS="-Duser.timezone=UTC -Dfile.encoding=UTF-8"
fi
echo "[INFO] SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH:-unset}"
echo "[INFO] JAVA_TOOL_OPTIONS: $JAVA_TOOL_OPTIONS"
SOURCE_COMMIT=$(git rev-parse HEAD)
echo "[INFO] Checked out commit: $SOURCE_COMMIT"

echo "[INFO] Building all modules (skip tests)..."
./gradlew clean build -x test \
    || fail "gradlew build failed"

echo "[INFO] Generating installer..."
./gradlew :apps:desktop:desktop-app-launcher:clean \
    || fail "gradlew clean failed"
./gradlew :apps:desktop:desktop-app-launcher:generateInstallers \
    || fail "gradlew generateInstallers failed"

BUILT_DEB="/build/bisq2/apps/desktop/desktop-app-launcher/build/packaging/jpackage/packages/$BUILT_ARTIFACT"
wait_for_complete_artifact "$BUILT_DEB" \
    || script_fail "Generated artifact did not become complete within 900 seconds. See packaging-diagnostics.txt."

cp "$BUILT_DEB" "$OUTPUT/$BUILT_ARTIFACT"
BUILT_DEB="$OUTPUT/$BUILT_ARTIFACT"

BI2P_JAR=$(find /build/bisq2/apps/desktop/bi2p/build/libs \
    -maxdepth 1 -type f -name 'bi2p-*-all.jar' 2>/dev/null | sort | head -1)
[[ -n "$BI2P_JAR" ]] && sha256sum "$BI2P_JAR" > "$OUTPUT/bi2p-jar.sha256"

cp /build/bisq2/apps/desktop/desktop-app-launcher/build/packaging/jpackage/packages/*.sha256 \
    "$OUTPUT/" 2>/dev/null || true

BUILT_SIZE=$(du -b "$BUILT_DEB" | cut -f1)
echo "[INFO] Built artifact: $(basename "$BUILT_DEB") (${BUILT_SIZE} bytes)"
[[ "$BUILT_SIZE" -lt 1048576 ]] \
    && fail "Built artifact is unexpectedly small (${BUILT_SIZE} bytes); jpackage likely failed"

# Stop Gradle daemon to free memory before analysis phases
./gradlew --stop >/dev/null 2>&1 || true

OFFICIAL_DEB="$OUTPUT/$OFFICIAL_ARTIFACT"
if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
    echo "[INFO] Official binary provided via --binary — skipping download"
    [[ -z "$BINARY_FILENAME" ]] && fail "BINARY_FILENAME not set for --binary input"
    [[ "$BINARY_FILENAME" != "$OFFICIAL_ARTIFACT" ]]         && fail "Provided binary filename mismatch: expected $OFFICIAL_ARTIFACT for version/type, got $BINARY_FILENAME"
    [[ ! -f "/input/$BINARY_FILENAME" ]]         && fail "Provided binary not found in /input/: $BINARY_FILENAME"
    cp "/input/$BINARY_FILENAME" "$OFFICIAL_DEB"
    echo "[INFO] Using provided official binary: $BINARY_FILENAME"
else
    echo "[INFO] Downloading official: $GITHUB_RELEASE_URL"
    wget -q --show-progress -O "$OFFICIAL_DEB" "$GITHUB_RELEASE_URL" \
        || fail "Failed to download official release"
fi

OFFICIAL_SIZE=$(du -b "$OFFICIAL_DEB" | cut -f1)
echo "[INFO] Official artifact: $OFFICIAL_ARTIFACT (${OFFICIAL_SIZE} bytes)"

BUILT_HASH=$(sha256sum "$BUILT_DEB" | cut -d' ' -f1)
OFFICIAL_HASH=$(sha256sum "$OFFICIAL_DEB" | cut -d' ' -f1)

echo ""
echo "=== Hash Comparison ==="
echo "Official: $OFFICIAL_HASH"
echo "Built:    $BUILT_HASH"

ARTIFACT_NOTES_BASE="Bisq2 ${VERSION_CLEAN} ${BUILD_TYPE} (${ARCH}).
Artifact verdict scope: ${OFFICIAL_ARTIFACT} only.
Built from tag: ${GIT_TAG} at commit ${SOURCE_COMMIT}.
Verified artifact: ${OFFICIAL_ARTIFACT}
Official SHA256: ${OFFICIAL_HASH}
Built SHA256: ${BUILT_HASH}"

if [[ "$OFFICIAL_HASH" == "$BUILT_HASH" ]]; then
    echo "[OK] Hashes MATCH"
    write_yaml "reproducible" \
        "${ARTIFACT_NOTES_BASE}
Hashes match: true.
Artifact and extracted content are reproducible: package files are byte-for-byte identical."

    echo ""
    echo "===== Begin Results ====="
    echo "appId:          bisq2"
    echo "artifact:       $OFFICIAL_ARTIFACT"
    echo "artifactType:   $BUILD_TYPE"
    echo "artifactArch:   $ARCH"
    echo "verdictScope:   single artifact"
    echo "signer:         N/A"
    echo "apkVersionName: $VERSION_CLEAN"
    echo "apkVersionCode: N/A"
    echo "verdict:        reproducible"
    echo "appHash:        $OFFICIAL_HASH"
    echo "commit:         $GIT_TAG"
    echo ""
    echo "Revision: $GIT_TAG"
    echo ""
    echo "Diff:"
    echo "BUILDS MATCH"
    echo "===== End Results ====="
    echo "Exit code: 0"
    exit 0
fi

echo "[WARN] Hashes differ — proceeding with diff analysis"
SIZE_DIFF=$((BUILT_SIZE - OFFICIAL_SIZE))
echo "[INFO] Compressed size delta: ${SIZE_DIFF} bytes (built - official)"

if [[ "$BUILD_TYPE" == "rpm" ]]; then
    EXTRACT_OFF="$OUTPUT/extracted-official"
    EXTRACT_BLT="$OUTPUT/extracted-built"
    mkdir -p "$EXTRACT_OFF" "$EXTRACT_BLT"

    echo "[INFO] Extracting RPMs..."
    (cd "$EXTRACT_OFF" && rpm2cpio "$OFFICIAL_DEB" | cpio -idm --quiet) \
        || fail "Failed to extract official RPM"
    (cd "$EXTRACT_BLT" && rpm2cpio "$BUILT_DEB"    | cpio -idm --quiet) \
        || fail "Failed to extract built RPM"

    EXTRACT_OFF_SIZE=$(du -sb "$EXTRACT_OFF" | cut -f1)
    EXTRACT_BLT_SIZE=$(du -sb "$EXTRACT_BLT" | cut -f1)
    EXTRACT_SIZE_DIFF=$((EXTRACT_BLT_SIZE - EXTRACT_OFF_SIZE))

    echo "[INFO] Extracted sizes:"
    echo "       Official: ${EXTRACT_OFF_SIZE} bytes"
    echo "       Built:    ${EXTRACT_BLT_SIZE} bytes"
    echo "       Delta:    ${EXTRACT_SIZE_DIFF} bytes"

    DIFF_BRIEF="$OUTPUT/diff_brief.txt"
    DIFF_FULL="$OUTPUT/diff_full.txt"

    echo "[INFO] Running diff -r --brief..."
    diff -r --brief "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_BRIEF" 2>&1 || true

    echo "[INFO] Running full diff (→ diff_full.txt)..."
    diff -r "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_FULL" 2>&1 || true

    DIFF_LINES=$(wc -l < "$DIFF_FULL")
    DIFF_BRIEF_COUNT=$(wc -l < "$DIFF_BRIEF")
    echo "[INFO] Full diff: ${DIFF_LINES} lines across ${DIFF_BRIEF_COUNT} entries"

    echo ""
    echo "=== Diff Categorization ==="

    APP_JAR_DIFF_BRIEF="$OUTPUT/diff_app_jars_brief.txt"
    diff -r --brief \
        "$EXTRACT_OFF/opt/bisq2/lib/app" \
        "$EXTRACT_BLT/opt/bisq2/lib/app" \
        > "$APP_JAR_DIFF_BRIEF" 2>&1 || true
    APP_JAR_DIFF_COUNT=$(grep -c "^Files" "$APP_JAR_DIFF_BRIEF" 2>/dev/null || true)
    APP_JAR_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/app" | cut -f1)
    APP_JAR_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/app" | cut -f1)
    echo "[INFO] App JARs differing: ${APP_JAR_DIFF_COUNT} (→ diff_app_jars_brief.txt)"
    echo "[INFO] App JAR dir sizes: official=${APP_JAR_SIZE_OFF}  built=${APP_JAR_SIZE_BLT}"

    JRE_DIFF_BRIEF="$OUTPUT/diff_jre_brief.txt"
    diff -r --brief \
        "$EXTRACT_OFF/opt/bisq2/lib/runtime" \
        "$EXTRACT_BLT/opt/bisq2/lib/runtime" \
        > "$JRE_DIFF_BRIEF" 2>&1 || true
    JRE_DIFF_COUNT=$(wc -l < "$JRE_DIFF_BRIEF")
    JRE_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/runtime" | cut -f1)
    JRE_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/runtime" | cut -f1)
    echo "[INFO] JRE entries differing: ${JRE_DIFF_COUNT} (→ diff_jre_brief.txt)"
    echo "[INFO] JRE sizes: official=${JRE_SIZE_OFF}  built=${JRE_SIZE_BLT}"

    echo ""
    echo "=== JAR Content Analysis ==="

    CLASS_DIFF_REPORT="$OUTPUT/diff_class_files.txt"
    CLASS_DIFF_TOTAL=0
    BYTECODE_DIFF_COUNT=0
    BYTECODE_DIFF_FILES=""

    while IFS= read -r brief_line; do
        [[ "$brief_line" != Files* ]] && continue
        jar_off=$(echo "$brief_line" | awk '{print $2}')
        jar_blt=$(echo "$brief_line" | awk '{print $4}')
        jar_name=$(basename "$jar_off")
        [[ "$jar_name" != *.jar ]] && continue

        JAR_EX_OFF="$OUTPUT/jar-extract/official/${jar_name%.jar}"
        JAR_EX_BLT="$OUTPUT/jar-extract/built/${jar_name%.jar}"
        mkdir -p "$JAR_EX_OFF" "$JAR_EX_BLT"

        unzip -q "$jar_off" -d "$JAR_EX_OFF" 2>/dev/null || continue
        unzip -q "$jar_blt" -d "$JAR_EX_BLT" 2>/dev/null || continue

        jar_class_diff=$(diff -r --brief "$JAR_EX_OFF" "$JAR_EX_BLT" 2>/dev/null \
            | grep "\.class" || true)
        [[ -z "$jar_class_diff" ]] && continue

        echo "=== $jar_name ===" >> "$CLASS_DIFF_REPORT"

        while IFS= read -r class_line; do
            [[ "$class_line" != Files* ]] && continue
            class_off=$(echo "$class_line" | awk '{print $2}')
            class_blt=$(echo "$class_line" | awk '{print $4}')
            [[ ! -f "$class_off" ]] || [[ ! -f "$class_blt" ]] && continue

            CLASS_DIFF_TOTAL=$((CLASS_DIFF_TOTAL + 1))
            javap_off=$(javap -c "$class_off" 2>/dev/null || true)
            javap_blt=$(javap -c "$class_blt" 2>/dev/null || true)

            if [[ "$javap_off" != "$javap_blt" ]]; then
                BYTECODE_DIFF_COUNT=$((BYTECODE_DIFF_COUNT + 1))
                BYTECODE_DIFF_FILES="${BYTECODE_DIFF_FILES} $(basename "$class_off")"
                echo "  [JAVAP -c DIFFERS] $(basename "$class_off")" \
                    >> "$CLASS_DIFF_REPORT"
                diff <(echo "$javap_off") <(echo "$javap_blt") \
                    >> "$CLASS_DIFF_REPORT" 2>/dev/null || true
            else
                echo "  [javap -c matched] $(basename "$class_off")" \
                    >> "$CLASS_DIFF_REPORT"
            fi
        done <<< "$jar_class_diff"
        rm -rf "$JAR_EX_OFF" "$JAR_EX_BLT"
    done < "$APP_JAR_DIFF_BRIEF"

    echo "[INFO] Class files with diffs examined: ${CLASS_DIFF_TOTAL}"
    echo "[INFO] Class disassembly differences:            ${BYTECODE_DIFF_COUNT}"
    [[ -f "$CLASS_DIFF_REPORT" ]] && echo "[INFO] Class diff report → diff_class_files.txt"

    echo ""
    echo "=== Summary ==="
    echo "[INFO] RPM hash match:            NO"
    echo "[INFO] Compressed size delta:     ${SIZE_DIFF} bytes"
    echo "[INFO] Extracted size delta:      ${EXTRACT_SIZE_DIFF} bytes"
    echo "[INFO] Full diff lines:           ${DIFF_LINES}"
    echo "[INFO] App JARs differing:        ${APP_JAR_DIFF_COUNT}"
    echo "[INFO] JRE entries differing:     ${JRE_DIFF_COUNT}"
    echo "[INFO] Class files examined:      ${CLASS_DIFF_TOTAL}"
    echo "[INFO] Class disassembly differences:      ${BYTECODE_DIFF_COUNT}"

    RPM_PAYLOAD_DIFF_COUNT="$DIFF_BRIEF_COUNT"
    echo "[INFO] Extracted RPM payload differences: ${RPM_PAYLOAD_DIFF_COUNT}"

    if [[ "$RPM_PAYLOAD_DIFF_COUNT" -eq 0 ]]; then
        RESULT_VERDICT="reproducible"
        RESULT_LABEL="reproducible"
        VERDICT_NOTES="${ARTIFACT_NOTES_BASE}
Hashes match: false.
Extracted RPM payload differences: 0.
RPM payload is reproducible. RPM header and package wrapper differences are excluded from the verdict."
    else
        RESULT_VERDICT="not_reproducible"
        RESULT_LABEL="differences found"
        VERDICT_NOTES="${ARTIFACT_NOTES_BASE}
Hashes match: false.
Extracted RPM payload differences: ${RPM_PAYLOAD_DIFF_COUNT}.
RPM payload differs. See diff files in work directory.
Class files examined: ${CLASS_DIFF_TOTAL}. Class disassembly differences: ${BYTECODE_DIFF_COUNT}."
    fi

    write_yaml "$RESULT_VERDICT" "$VERDICT_NOTES"
    print_results
    exit 0
fi

EXTRACT_OFF="$OUTPUT/extracted-official"
EXTRACT_BLT="$OUTPUT/extracted-built"
mkdir -p "$EXTRACT_OFF" "$EXTRACT_BLT"

echo "[INFO] Extracting DEBs..."
dpkg-deb -R "$OFFICIAL_DEB" "$EXTRACT_OFF" || fail "Failed to extract official DEB"
dpkg-deb -R "$BUILT_DEB"    "$EXTRACT_BLT" || fail "Failed to extract built DEB"

EXTRACT_OFF_SIZE=$(du -sb "$EXTRACT_OFF" | cut -f1)
EXTRACT_BLT_SIZE=$(du -sb "$EXTRACT_BLT" | cut -f1)
EXTRACT_SIZE_DIFF=$((EXTRACT_BLT_SIZE - EXTRACT_OFF_SIZE))

echo "[INFO] Extracted sizes:"
echo "       Official: ${EXTRACT_OFF_SIZE} bytes"
echo "       Built:    ${EXTRACT_BLT_SIZE} bytes"
echo "       Delta:    ${EXTRACT_SIZE_DIFF} bytes (note: opposite sign from compressed delta is normal)"

DIFF_BRIEF="$OUTPUT/diff_brief.txt"
DIFF_FULL="$OUTPUT/diff_full.txt"

echo "[INFO] Running diff -r --brief..."
diff -r --brief "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_BRIEF" 2>&1 || true

echo "[INFO] Running full diff (→ diff_full.txt)..."
diff -r "$EXTRACT_OFF" "$EXTRACT_BLT" > "$DIFF_FULL" 2>&1 || true

DIFF_LINES=$(wc -l < "$DIFF_FULL")
DIFF_BRIEF_COUNT=$(wc -l < "$DIFF_BRIEF")
echo "[INFO] Full diff: ${DIFF_LINES} lines across ${DIFF_BRIEF_COUNT} entries"

PAYLOAD_DIFF_BRIEF="$OUTPUT/diff_payload_brief.txt"
PACKAGING_DIFF_BRIEF="$OUTPUT/diff_packaging_brief.txt"
PACKAGING_UNREVIEWED_DIFF_BRIEF="$OUTPUT/diff_packaging_unreviewed_brief.txt"
CONTROL_SEMANTIC_DIFF="$OUTPUT/diff_control_semantic.txt"
CONTROL_NORMALIZED_OFF="/tmp/ws-bisq2-control-official.normalized"
CONTROL_NORMALIZED_BLT="/tmp/ws-bisq2-control-built.normalized"

diff -r --brief --exclude=DEBIAN "$EXTRACT_OFF" "$EXTRACT_BLT" \
    > "$PAYLOAD_DIFF_BRIEF" 2>&1 || true
diff -r --brief "$EXTRACT_OFF/DEBIAN" "$EXTRACT_BLT/DEBIAN" \
    > "$PACKAGING_DIFF_BRIEF" 2>&1 || true
diff -r --brief --exclude=md5sums --exclude=changelog --exclude=control \
    "$EXTRACT_OFF/DEBIAN" "$EXTRACT_BLT/DEBIAN" \
    > "$PACKAGING_UNREVIEWED_DIFF_BRIEF" 2>&1 || true

sed -E '/^(Build-Date|BuildDate):[[:space:]]*/d' "$EXTRACT_OFF/DEBIAN/control" \
    > "$CONTROL_NORMALIZED_OFF"
sed -E '/^(Build-Date|BuildDate):[[:space:]]*/d' "$EXTRACT_BLT/DEBIAN/control" \
    > "$CONTROL_NORMALIZED_BLT"
diff -u "$CONTROL_NORMALIZED_OFF" "$CONTROL_NORMALIZED_BLT" \
    > "$CONTROL_SEMANTIC_DIFF" 2>&1 || true

PAYLOAD_DIFF_COUNT=$(wc -l < "$PAYLOAD_DIFF_BRIEF")
PACKAGING_DIFF_COUNT=$(wc -l < "$PACKAGING_DIFF_BRIEF")
PACKAGING_UNREVIEWED_DIFF_COUNT=$(wc -l < "$PACKAGING_UNREVIEWED_DIFF_BRIEF")
if [[ -s "$CONTROL_SEMANTIC_DIFF" ]]; then
    PACKAGING_UNREVIEWED_DIFF_COUNT=$((PACKAGING_UNREVIEWED_DIFF_COUNT + 1))
fi

echo "[INFO] Installed payload differences:          ${PAYLOAD_DIFF_COUNT}"
echo "[INFO] DEBIAN metadata differences:            ${PACKAGING_DIFF_COUNT}"
echo "[INFO] Unreviewed DEBIAN metadata differences: ${PACKAGING_UNREVIEWED_DIFF_COUNT}"

echo ""
echo "=== Diff Categorization ==="

CONTROL_DIFF="$OUTPUT/diff_control.txt"
diff "$EXTRACT_OFF/DEBIAN/control" "$EXTRACT_BLT/DEBIAN/control" \
    > "$CONTROL_DIFF" 2>&1 || true
CONTROL_LINES=$(wc -l < "$CONTROL_DIFF" 2>/dev/null || echo 0)
echo "[INFO] DEBIAN/control diffs: ${CONTROL_LINES} lines (→ diff_control.txt)"
if [[ "$CONTROL_LINES" -gt 0 ]]; then
    head -5 "$CONTROL_DIFF"
fi

APP_JAR_DIFF_BRIEF="$OUTPUT/diff_app_jars_brief.txt"
diff -r --brief \
    "$EXTRACT_OFF/opt/bisq2/lib/app" \
    "$EXTRACT_BLT/opt/bisq2/lib/app" \
    > "$APP_JAR_DIFF_BRIEF" 2>&1 || true
APP_JAR_DIFF_COUNT=$(grep -c "^Files" "$APP_JAR_DIFF_BRIEF" 2>/dev/null || true)
APP_JAR_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/app" | cut -f1)
APP_JAR_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/app" | cut -f1)
echo "[INFO] App JARs differing: ${APP_JAR_DIFF_COUNT} (→ diff_app_jars_brief.txt)"
echo "[INFO] App JAR dir sizes: official=${APP_JAR_SIZE_OFF}  built=${APP_JAR_SIZE_BLT}"

JRE_DIFF_BRIEF="$OUTPUT/diff_jre_brief.txt"
diff -r --brief \
    "$EXTRACT_OFF/opt/bisq2/lib/runtime" \
    "$EXTRACT_BLT/opt/bisq2/lib/runtime" \
    > "$JRE_DIFF_BRIEF" 2>&1 || true
JRE_DIFF_COUNT=$(wc -l < "$JRE_DIFF_BRIEF")
JRE_SIZE_OFF=$(du -sb "$EXTRACT_OFF/opt/bisq2/lib/runtime" | cut -f1)
JRE_SIZE_BLT=$(du -sb "$EXTRACT_BLT/opt/bisq2/lib/runtime" | cut -f1)
echo "[INFO] JRE entries differing: ${JRE_DIFF_COUNT} (→ diff_jre_brief.txt)"
echo "[INFO] JRE sizes: official=${JRE_SIZE_OFF}  built=${JRE_SIZE_BLT}"

echo ""
echo "=== JAR Content Analysis ==="

CLASS_DIFF_REPORT="$OUTPUT/diff_class_files.txt"
CLASS_DIFF_TOTAL=0
BYTECODE_DIFF_COUNT=0
BYTECODE_DIFF_FILES=""

while IFS= read -r brief_line; do
    [[ "$brief_line" != Files* ]] && continue

    jar_off=$(echo "$brief_line" | awk '{print $2}')
    jar_blt=$(echo "$brief_line" | awk '{print $4}')
    jar_name=$(basename "$jar_off")
    [[ "$jar_name" != *.jar ]] && continue

    JAR_EX_OFF="$OUTPUT/jar-extract/official/${jar_name%.jar}"
    JAR_EX_BLT="$OUTPUT/jar-extract/built/${jar_name%.jar}"
    mkdir -p "$JAR_EX_OFF" "$JAR_EX_BLT"

    unzip -q "$jar_off" -d "$JAR_EX_OFF" 2>/dev/null || continue
    unzip -q "$jar_blt" -d "$JAR_EX_BLT" 2>/dev/null || continue

    jar_class_diff=$(diff -r --brief "$JAR_EX_OFF" "$JAR_EX_BLT" 2>/dev/null \
        | grep "\.class" || true)

    [[ -z "$jar_class_diff" ]] && continue

    echo "=== $jar_name ===" >> "$CLASS_DIFF_REPORT"

    while IFS= read -r class_line; do
        [[ "$class_line" != Files* ]] && continue

        class_off=$(echo "$class_line" | awk '{print $2}')
        class_blt=$(echo "$class_line" | awk '{print $4}')
        [[ ! -f "$class_off" ]] || [[ ! -f "$class_blt" ]] && continue

        CLASS_DIFF_TOTAL=$((CLASS_DIFF_TOTAL + 1))

        javap_off=$(javap -c "$class_off" 2>/dev/null || true)
        javap_blt=$(javap -c "$class_blt" 2>/dev/null || true)

        if [[ "$javap_off" != "$javap_blt" ]]; then
            BYTECODE_DIFF_COUNT=$((BYTECODE_DIFF_COUNT + 1))
            BYTECODE_DIFF_FILES="${BYTECODE_DIFF_FILES} $(basename "$class_off")"
            echo "  [JAVAP -c DIFFERS] $(basename "$class_off")" \
                >> "$CLASS_DIFF_REPORT"
            diff <(echo "$javap_off") <(echo "$javap_blt") \
                >> "$CLASS_DIFF_REPORT" 2>/dev/null || true
        else
            echo "  [javap -c matched] $(basename "$class_off")" \
                >> "$CLASS_DIFF_REPORT"
        fi
    done <<< "$jar_class_diff"
    rm -rf "$JAR_EX_OFF" "$JAR_EX_BLT"

done < "$APP_JAR_DIFF_BRIEF"

echo "[INFO] Class files with diffs examined: ${CLASS_DIFF_TOTAL}"
echo "[INFO] Class disassembly differences:            ${BYTECODE_DIFF_COUNT}"
if [[ -f "$CLASS_DIFF_REPORT" ]]; then
    echo "[INFO] Class diff report → diff_class_files.txt"
fi

echo ""
echo "=== Summary ==="
echo "[INFO] DEB hash match:            NO"
echo "[INFO] Compressed size delta:     ${SIZE_DIFF} bytes"
echo "[INFO] Extracted size delta:      ${EXTRACT_SIZE_DIFF} bytes"
echo "[INFO] Full diff lines:           ${DIFF_LINES}"
echo "[INFO] App JARs differing:        ${APP_JAR_DIFF_COUNT}"
echo "[INFO] JRE entries differing:     ${JRE_DIFF_COUNT}"
echo "[INFO] Class files examined:      ${CLASS_DIFF_TOTAL}"
echo "[INFO] Class disassembly differences:      ${BYTECODE_DIFF_COUNT}"

if [[ "$PAYLOAD_DIFF_COUNT" -eq 0 ]] && [[ "$PACKAGING_UNREVIEWED_DIFF_COUNT" -eq 0 ]]; then
    RESULT_VERDICT="reproducible"
    RESULT_LABEL="reproducible"
    VERDICT_NOTES="${ARTIFACT_NOTES_BASE}
Hashes match: false.
Installed payload differences: ${PAYLOAD_DIFF_COUNT}.
DEBIAN metadata differences: ${PACKAGING_DIFF_COUNT}.
Payload reproducible. Excluded diffs: DEBIAN/md5sums, changelog, Build-Date in control."
else
    RESULT_VERDICT="not_reproducible"
    RESULT_LABEL="differences found"
    VERDICT_NOTES="${ARTIFACT_NOTES_BASE}
Hashes match: false.
Installed payload differences: ${PAYLOAD_DIFF_COUNT}.
DEBIAN metadata differences: ${PACKAGING_DIFF_COUNT}. Unreviewed DEBIAN metadata differences: ${PACKAGING_UNREVIEWED_DIFF_COUNT}.
Payload or package-control content differs. See diff files in work directory.
Class files examined: ${CLASS_DIFF_TOTAL}. Class disassembly differences: ${BYTECODE_DIFF_COUNT}."
fi

write_yaml "$RESULT_VERDICT" "$VERDICT_NOTES"
print_results
exit 0
CONTAINER_EOF

chmod +x "$CONTAINER_SCRIPT"

log_info "Building container image: $IMAGE_NAME"
NO_CACHE_FLAG=""
[[ "$NO_CACHE" == "true" ]] && NO_CACHE_FLAG="--no-cache"

if ! $CONTAINER_RUNTIME build $NO_CACHE_FLAG \
        -f "$DOCKERFILE" \
        -t "$IMAGE_NAME" \
        "$BUILD_CONTEXT" 2>&1 | tee "$WORK_DIR/image-build.log"; then
    die "Container image build failed"
fi
log_success "Image built: $IMAGE_NAME"

SKIP_DOWNLOAD="false"
BINARY_FILENAME=""
VOLUME_ARGS=(-v "${WORK_DIR}:/output")

if [[ -n "$BINARY_FILE" ]]; then
    [[ ! -f "$BINARY_FILE" ]] && die "Binary file not found: $BINARY_FILE" "$EXIT_INVALID_PARAMS"
    SKIP_DOWNLOAD="true"
    BINARY_FILENAME=$(basename "$BINARY_FILE")
    if [[ "$BINARY_FILENAME" != "$OFFICIAL_ARTIFACT" ]]; then
        die "Binary filename mismatch for requested artifact: expected $OFFICIAL_ARTIFACT, got $BINARY_FILENAME. Check --version and --type." "$EXIT_INVALID_PARAMS"
    fi
    BINARY_DIR=$(dirname "$(realpath "$BINARY_FILE")")
    VOLUME_ARGS+=(-v "${BINARY_DIR}:/input:ro")
    log_info "Official binary provided — skipping download, will build from source"
fi

log_info "Starting container..."
set +e
$CONTAINER_RUNTIME run \
    --name "$CONTAINER_NAME" \
    --privileged \
    "${VOLUME_ARGS[@]}" \
    -e GIT_TAG="$GIT_TAG" \
    -e VERSION_CLEAN="$VERSION_CLEAN" \
    -e BUILD_TYPE="$BUILD_TYPE" \
    -e ARCH="$ARCH" \
    -e BUILT_ARTIFACT="$BUILT_ARTIFACT" \
    -e OFFICIAL_ARTIFACT="$OFFICIAL_ARTIFACT" \
    -e GITHUB_RELEASE_URL="$GITHUB_RELEASE_URL" \
    -e SKIP_DOWNLOAD="$SKIP_DOWNLOAD" \
    -e BINARY_FILENAME="$BINARY_FILENAME" \
    -e SCRIPT_VERSION="$SCRIPT_VERSION" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$IMAGE_NAME" 2>&1 | tee "$WORK_DIR/container.log"
CONTAINER_EXIT="${PIPESTATUS[0]}"
set -e

if [[ ! -f "${WORK_DIR}/COMPARISON_RESULTS.yaml" ]]; then
    log_error "Container produced no COMPARISON_RESULTS.yaml (container exit: $CONTAINER_EXIT)"
    log_error "This is a verifier or infrastructure failure, not an app ftbfs verdict."
    exit "$EXIT_DIFFERENCES"
fi

cp "${WORK_DIR}/COMPARISON_RESULTS.yaml" "${ORIGINAL_EXECUTION_DIR}/COMPARISON_RESULTS.yaml"

log_info "--------"
log_info "Output files in: $WORK_DIR"
log_info "--------"
for f in COMPARISON_RESULTS.yaml diff_brief.txt diff_full.txt \
         diff_payload_brief.txt diff_packaging_brief.txt \
         diff_packaging_unreviewed_brief.txt diff_control.txt \
         diff_control_semantic.txt diff_app_jars_brief.txt diff_jre_brief.txt \
         diff_class_files.txt bi2p-jar.sha256 packaging-diagnostics.txt; do
    [[ -f "$WORK_DIR/$f" ]] && log_info "  $f ($(wc -l < "$WORK_DIR/$f") lines)"
done

VERDICT=$(awk '/^verdict:[[:space:]]*/ { print $2; exit }' "${WORK_DIR}/COMPARISON_RESULTS.yaml")
case "$VERDICT" in
    reproducible)
        log_success "Verdict: REPRODUCIBLE"
        exit "$EXIT_SUCCESS"
        ;;
    not_reproducible)
        log_warn "Verdict: NOT REPRODUCIBLE — see diff files above"
        exit "$EXIT_SUCCESS"
        ;;
    ftbfs)
        log_error "Verdict: FTBFS — see container log above"
        exit "$EXIT_SUCCESS"
        ;;
    *)
        log_error "Container produced an unsupported verdict: ${VERDICT:-missing}"
        exit "$EXIT_DIFFERENCES"
        ;;
esac
