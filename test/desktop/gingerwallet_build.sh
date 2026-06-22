#!/usr/bin/env bash
# ==============================================================================
# gingerwallet_build.sh - GingerWallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.7.7
# Organization:  WalletScrutiny.com
# Last Modified: 2026-05-09
# Project:       https://github.com/GingerPrivacy/GingerWallet
# ==============================================================================

set -euo pipefail

APP_ID="gingerwallet"
APP_NAME="GingerWallet"
SCRIPT_VERSION="v0.7.7"
REPO_URL="https://github.com/GingerPrivacy/GingerWallet.git"
DEFAULT_BUILD_TYPE="standalone"
GH_REPO="xrviv/WalletScrutinyCom"
GH_WORKFLOW="gingerwallet-build.yml"

EXIT_SUCCESS=0
EXIT_FAILURE=1
EXIT_INVALID_PARAMS=2

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<EOF
${APP_NAME} reproducible build verification (GitHub Actions)
Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com

Usage:
  $0 --version <version> [--arch <arch>] [--type <type>] [--binary <path>]

Required:
  --version <version>   Version without leading v (example: 2.0.23)

Optional:
  --arch <arch>         Architecture label from build server metadata
                        Supported values: linux-x64, linux64, x86_64-linux-gnu, x86_64-linux, win-x64
  --type <type>         Only "standalone" is supported for this script
  --binary <path>       Path to a pre-downloaded official release file (.zip or .tar.gz); skips the GitHub download step. MSI is not supported.
  --apk <path>          Alias for --binary (accepted for build-server compatibility)
  -h, --help            Show this message

Build is performed on a Windows GitHub Actions runner via ${GH_REPO}.

Examples:
  $0 --version 2.0.23 --arch linux-x64
  $0 --version 2.0.23 --arch win-x64
EOF
}

EXECUTION_DIR="$(pwd)"
RESULTS_FILE="${EXECUTION_DIR}/COMPARISON_RESULTS.yaml"

write_yaml_error() {
  local verdict="$1"
  local notes="${2:-}"

  if [[ -n "${notes}" ]]; then
    cat >"${RESULTS_FILE}" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: "${notes}"
EOF
  else
    cat >"${RESULTS_FILE}" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
EOF
  fi
}

VERSION=""
ARCH_PARAM=""
TYPE_PARAM=""
BINARY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        err "--version requires a value"
        echo "Exit code: ${EXIT_INVALID_PARAMS}"
        exit "${EXIT_INVALID_PARAMS}"
      fi
      VERSION="$2"
      shift 2
      ;;
    --arch)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        err "--arch requires a value"
        echo "Exit code: ${EXIT_INVALID_PARAMS}"
        exit "${EXIT_INVALID_PARAMS}"
      fi
      ARCH_PARAM="$2"
      shift 2
      ;;
    --type)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        err "--type requires a value"
        echo "Exit code: ${EXIT_INVALID_PARAMS}"
        exit "${EXIT_INVALID_PARAMS}"
      fi
      TYPE_PARAM="$2"
      shift 2
      ;;
    --apk|--binary)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        err "$1 requires a value"
        echo "Exit code: ${EXIT_INVALID_PARAMS}"
        exit "${EXIT_INVALID_PARAMS}"
      fi
      BINARY_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      echo "Exit code: ${EXIT_SUCCESS}"
      exit "${EXIT_SUCCESS}"
      ;;
    *)
      warn "Unknown argument: $1 — ignoring"
      shift
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  err "Missing required parameter: --version"
  usage
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
fi

if [[ -n "${BINARY_PATH}" && ! -f "${BINARY_PATH}" ]]; then
  err "--binary path does not exist: ${BINARY_PATH}"
  write_yaml_error "ftbfs" "--binary path does not exist: ${BINARY_PATH}"
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
fi

if [[ -n "${BINARY_PATH}" && "${BINARY_PATH}" == *.msi ]]; then
  err "MSI format is not supported — Windows verification requires a separate workflow"
  write_yaml_error "ftbfs" "MSI format not supported for extraction and comparison"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

if [[ -n "${TYPE_PARAM}" && "${TYPE_PARAM}" != "${DEFAULT_BUILD_TYPE}" ]]; then
  err "Unsupported --type: ${TYPE_PARAM}"
  write_yaml_error "ftbfs" "unsupported build type ${TYPE_PARAM}"
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
fi

ARCH_OUT="${ARCH_PARAM:-linux-x64}"
TARGET_ARCH="linux-x64"
case "${ARCH_OUT}" in
  linux-x64|linux64|x86_64-linux-gnu|x86_64-linux)
    TARGET_ARCH="linux-x64"
    ;;
  win-x64|x86_64-windows)
    TARGET_ARCH="win-x64"
    ;;
  *)
    err "Unsupported --arch: ${ARCH_OUT}"
    write_yaml_error "ftbfs" "unsupported architecture ${ARCH_OUT}"
    echo "Exit code: ${EXIT_INVALID_PARAMS}"
    exit "${EXIT_INVALID_PARAMS}"
    ;;
esac

# ==============================================================================
# Prerequisites: docker or podman
# ==============================================================================

CONTAINER_CMD=""
if command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
else
  err "docker or podman is required but neither is installed"
  write_yaml_error "ftbfs" "docker or podman not installed"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

GH_HELPER_IMAGE="gw-gh-helper"

build_gh_helper() {
  log "Building gh helper container (debian:bookworm-slim + gh CLI)..."
  "${CONTAINER_CMD}" build -t "${GH_HELPER_IMAGE}" - <<'GHEOF'
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

# Resolve token: GITHUB_TOKEN takes precedence; fall back to GH_TOKEN.
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# Run a gh command inside the helper container.
# ART_DIR is mounted at /work; use /work/... for any container-side file output.
gh_c() {
  "${CONTAINER_CMD}" run --rm \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    -v "${ART_DIR}:/work" \
    -w /work \
    "${GH_HELPER_IMAGE}" \
    gh "$@"
}

if ! "${CONTAINER_CMD}" image inspect "${GH_HELPER_IMAGE}" >/dev/null 2>&1; then
  build_gh_helper
fi

log "Using ${CONTAINER_CMD} + gh helper container for GitHub operations"
log "Triggering builds via GitHub Actions on ${GH_REPO}"

# ==============================================================================
# Working directory setup
# ==============================================================================

ART_DIR="${EXECUTION_DIR}/gingerwallet-${VERSION}-${ARCH_OUT}"
LOG_DIR="${ART_DIR}/logs"
mkdir -p "${ART_DIR}" "${LOG_DIR}"

cleanup() {
  : # Artifacts are kept for inspection
}
trap cleanup EXIT

# ==============================================================================
# Step 1: Obtain official release and extract SDK version from BUILDINFO.json
# ==============================================================================

OFFICIAL_DIR="${ART_DIR}/official-download"
mkdir -p "${OFFICIAL_DIR}"
OFFICIAL_ASSET_NAME=""
OFFICIAL_ZIP=""

if [[ -n "${BINARY_PATH}" ]]; then
  log "Using provided binary: ${BINARY_PATH}"
  OFFICIAL_ASSET_NAME="$(basename "${BINARY_PATH}")"
  OFFICIAL_ZIP="${OFFICIAL_DIR}/${OFFICIAL_ASSET_NAME}"
  cp "${BINARY_PATH}" "${OFFICIAL_ZIP}"
else
  log "Resolving official release asset for ${TARGET_ARCH}..."
  OFFICIAL_ASSET_NAME="$(gh_c api "repos/GingerPrivacy/GingerWallet/releases/tags/v${VERSION}" \
    --jq ".assets[] | select(.name | contains(\"${TARGET_ARCH}\") and endswith(\".zip\")) | .name" \
    2>/dev/null | head -n 1 || true)"

  # Fall back to generic tar.gz if no arch-specific zip is found.
  if [[ -z "${OFFICIAL_ASSET_NAME}" ]]; then
    log "No arch-specific zip found; trying generic tar.gz..."
    OFFICIAL_ASSET_NAME="$(gh_c api "repos/GingerPrivacy/GingerWallet/releases/tags/v${VERSION}" \
      --jq ".assets[] | select(.name == \"Ginger-${VERSION}.tar.gz\") | .name" \
      2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "${OFFICIAL_ASSET_NAME}" ]]; then
    err "Could not find official zip or tar.gz asset for ${TARGET_ARCH} in release v${VERSION}"
    write_yaml_error "ftbfs" "official ${TARGET_ARCH} release asset not found"
    echo "Exit code: ${EXIT_FAILURE}"
    exit "${EXIT_FAILURE}"
  fi

  OFFICIAL_ZIP="${OFFICIAL_DIR}/${OFFICIAL_ASSET_NAME}"
  OFFICIAL_URL="$(gh_c api "repos/GingerPrivacy/GingerWallet/releases/tags/v${VERSION}" \
    --jq ".assets[] | select(.name == \"${OFFICIAL_ASSET_NAME}\") | .browser_download_url" \
    2>/dev/null | head -n 1 || true)"

  if [[ -z "${OFFICIAL_URL}" ]]; then
    err "Could not resolve download URL for ${OFFICIAL_ASSET_NAME}"
    write_yaml_error "ftbfs" "official download URL not found"
    echo "Exit code: ${EXIT_FAILURE}"
    exit "${EXIT_FAILURE}"
  fi

  log "Downloading official release..."
  if [[ ! -f "${OFFICIAL_ZIP}" ]]; then
    if ! curl -fL -o "${OFFICIAL_ZIP}" "${OFFICIAL_URL}"; then
      err "Failed to download official release from ${OFFICIAL_URL}"
      write_yaml_error "ftbfs" "failed to download official release"
      echo "Exit code: ${EXIT_FAILURE}"
      exit "${EXIT_FAILURE}"
    fi
  fi
fi

SDK_VERSION="8.0.100"
RUNTIME_VERSION=""
BUILDINFO_TMP="$(mktemp -d "${ART_DIR}/buildinfo-XXXXXX")"
_extract_ok=true
if [[ "${OFFICIAL_ASSET_NAME}" == *.tar.gz ]]; then
  tar -xzf "${OFFICIAL_ZIP}" -C "${BUILDINFO_TMP}" >/dev/null 2>&1 || _extract_ok=false
else
  unzip -q -o "${OFFICIAL_ZIP}" -d "${BUILDINFO_TMP}" >/dev/null 2>&1 || _extract_ok=false
fi
if [[ "${_extract_ok}" == "false" ]]; then
  warn "Failed to extract ${OFFICIAL_ASSET_NAME} — archive may be corrupt. Falling back to default SDK ${SDK_VERSION}."
fi
BUILDINFO_PATH="$(find "${BUILDINFO_TMP}" -type f -iname "BUILDINFO.json" | head -n 1 || true)"
if [[ -n "${BUILDINFO_PATH}" ]]; then
  sdk_from_buildinfo="$(jq -r '.NetSdkVersion // empty' "${BUILDINFO_PATH}" 2>/dev/null || true)"
  runtime_from_buildinfo="$(jq -r '.NetRuntimeVersion // empty' "${BUILDINFO_PATH}" 2>/dev/null || true)"
  if [[ -n "${sdk_from_buildinfo}" && "${sdk_from_buildinfo}" != "null" ]]; then
    SDK_VERSION="${sdk_from_buildinfo}"
  fi
  if [[ -n "${runtime_from_buildinfo}" && "${runtime_from_buildinfo}" != "null" ]]; then
    RUNTIME_VERSION="${runtime_from_buildinfo}"
  fi
  cp "${BUILDINFO_PATH}" "${LOG_DIR}/official-BUILDINFO.json" 2>/dev/null || true
fi
rm -rf "${BUILDINFO_TMP}" >/dev/null 2>&1 || true

echo "${SDK_VERSION}" >"${LOG_DIR}/dotnet-sdk-version.txt"
if [[ -n "${RUNTIME_VERSION}" ]]; then
  echo "${RUNTIME_VERSION}" >"${LOG_DIR}/dotnet-runtime-version.txt"
fi
log "SDK version from BUILDINFO.json: ${SDK_VERSION}"
if [[ -n "${RUNTIME_VERSION}" ]]; then
  log "Runtime version from BUILDINFO.json: ${RUNTIME_VERSION}"
fi

# ==============================================================================
# Step 2: Trigger GitHub Actions workflow
# ==============================================================================

# Snapshot existing run IDs so the poll loop can exclude them and avoid attaching to a
# concurrent run that was already in flight before we triggered.
mapfile -t _PRE_TRIGGER_IDS < <(gh_c run list \
    --repo "${GH_REPO}" --workflow "${GH_WORKFLOW}" \
    --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)
TRIGGER_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log "Triggering GitHub Actions workflow on ${GH_REPO}..."
GH_WORKFLOW_REF="wallet-actions"
WORKFLOW_CMD=(gh_c workflow run "${GH_WORKFLOW}" --repo "${GH_REPO}" --ref "${GH_WORKFLOW_REF}" -f version="${VERSION}" -f sdk_version="${SDK_VERSION}")
if [[ -n "${RUNTIME_VERSION}" ]]; then
  WORKFLOW_CMD+=(-f runtime_version="${RUNTIME_VERSION}")
fi
if ! "${WORKFLOW_CMD[@]}"; then
  err "Failed to trigger workflow"
  write_yaml_error "ftbfs" "failed to trigger GitHub Actions workflow"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

# ==============================================================================
# Step 3: Poll for the workflow run ID
# ==============================================================================

log "Waiting for workflow run to appear..."
RUN_ID=""
MAX_POLL=30
POLL_INTERVAL=10
for i in $(seq 1 "${MAX_POLL}"); do
  sleep "${POLL_INTERVAL}"
  # Read all runs created at or after TRIGGER_TIME into an array, newest first.
  mapfile -t _CANDIDATES < <(gh_c run list \
    --repo "${GH_REPO}" \
    --workflow "${GH_WORKFLOW}" \
    --limit 10 \
    --json databaseId,createdAt \
    --jq "[.[] | select(.createdAt >= \"${TRIGGER_TIME}\")] | .[].databaseId" \
    2>/dev/null || true)
  # Known limitation: if two independent runs are triggered after TRIGGER_TIME and both
  # pass the pre-trigger snapshot check, the script attaches to whichever appears first.
  # Acceptable for single-user / single-concurrent-workflow use.
  for _cid in "${_CANDIDATES[@]:-}"; do
    [[ -z "${_cid}" || "${_cid}" == "null" ]] && continue
    _is_new=true
    for _pid in "${_PRE_TRIGGER_IDS[@]:-}"; do
      [[ "${_cid}" == "${_pid}" ]] && _is_new=false && break
    done
    if [[ "${_is_new}" == "true" ]]; then
      RUN_ID="${_cid}"
      break
    fi
  done
  if [[ -n "${RUN_ID}" ]]; then
    log "Found workflow run ID: ${RUN_ID}"
    break
  fi
  log "Poll attempt ${i}/${MAX_POLL}..."
done

if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
  err "Could not find workflow run after ${MAX_POLL} attempts"
  write_yaml_error "ftbfs" "workflow run not found"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

# ==============================================================================
# Step 4: Wait for workflow to complete
# ==============================================================================

log "Watching workflow run ${RUN_ID}..."
if ! gh_c run watch "${RUN_ID}" --repo "${GH_REPO}" --exit-status; then
  err "Workflow run ${RUN_ID} failed"
  write_yaml_error "ftbfs" "GitHub Actions workflow failed"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

log "Workflow run ${RUN_ID} completed successfully."

# ==============================================================================
# Step 4b: Print workflow logs
# ==============================================================================

log "Fetching workflow logs..."
if ! gh_c run view "${RUN_ID}" --repo "${GH_REPO}" --log | tee "${LOG_DIR}/gh-run-${RUN_ID}.log"; then
  warn "Failed to fetch workflow logs"
fi

# ==============================================================================
# Step 5: Download build artifact
# ==============================================================================

ARTIFACT_NAME="gingerwallet-${VERSION}-${TARGET_ARCH}"
BUILT_DIR="${ART_DIR}/built"
rm -rf "${BUILT_DIR}"
mkdir -p "${BUILT_DIR}"

log "Downloading artifact: ${ARTIFACT_NAME}..."
if ! gh_c run download "${RUN_ID}" \
  --repo "${GH_REPO}" \
  --name "${ARTIFACT_NAME}" \
  --dir /work/built; then
  err "Failed to download artifact ${ARTIFACT_NAME}"
  write_yaml_error "ftbfs" "failed to download build artifact"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

# ==============================================================================
# Step 6: Extract official release and compare
# ==============================================================================

OFFICIAL_EXT="${ART_DIR}/official-extracted"
rm -rf "${OFFICIAL_EXT}"
mkdir -p "${OFFICIAL_EXT}"
if [[ "${OFFICIAL_ASSET_NAME}" == *.tar.gz ]]; then
  _top_dirs="$(tar -tzf "${OFFICIAL_ZIP}" 2>/dev/null | awk -F/ '{print $1}' | sort -u | grep -v '^$' | wc -l)" || _top_dirs=0
  if [[ "${_top_dirs}" -eq 0 ]]; then
    err "Could not list contents of ${OFFICIAL_ASSET_NAME} — archive may be corrupt"
    write_yaml_error "ftbfs" "could not list tar.gz contents — archive may be corrupt"
    echo "Exit code: ${EXIT_FAILURE}"
    exit "${EXIT_FAILURE}"
  elif [[ "${_top_dirs}" -eq 1 ]]; then
    tar -xzf "${OFFICIAL_ZIP}" -C "${OFFICIAL_EXT}" --strip-components=1
  else
    warn "tar.gz has ${_top_dirs} top-level entries (expected 1); extracting without --strip-components"
    tar -xzf "${OFFICIAL_ZIP}" -C "${OFFICIAL_EXT}"
  fi
elif [[ "${OFFICIAL_ASSET_NAME}" == *.msi ]]; then
  err "MSI format is not supported for extraction — Windows verification requires a separate workflow"
  write_yaml_error "ftbfs" "MSI format not supported for extraction and comparison"
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
else
  unzip -q "${OFFICIAL_ZIP}" -d "${OFFICIAL_EXT}"
fi

BUILT_EXT="${BUILT_DIR}"

OFFICIAL_HASH="$(sha256sum "${OFFICIAL_ZIP}" | awk '{print $1}')"
BUILT_HASH="$(cd "${BUILT_EXT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

OFFICIAL_HASHES="${ART_DIR}/official-hashes-${VERSION}-${ARCH_OUT}.txt"
BUILT_HASHES="${ART_DIR}/built-hashes-${VERSION}-${ARCH_OUT}.txt"
HASH_DIFF="${ART_DIR}/hash-diff-${VERSION}-${ARCH_OUT}.txt"

(
  cd "${OFFICIAL_EXT}"
  find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's#  \\./#  #'
) >"${OFFICIAL_HASHES}"
(
  cd "${BUILT_EXT}"
  find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's#  \\./#  #'
) >"${BUILT_HASHES}"

if diff -u "${OFFICIAL_HASHES}" "${BUILT_HASHES}" >"${HASH_DIFF}"; then
  MATCH_FLAG="1"
  VERDICT="reproducible"
else
  MATCH_FLAG="0"
  VERDICT="not_reproducible"
fi

# ==============================================================================
# Per-file diffs for mismatched files
# ==============================================================================

DIFFS_DIR="${ART_DIR}/diffs"
if [[ "${MATCH_FLAG}" = "0" ]]; then
  mkdir -p "${DIFFS_DIR}"
  grep -E '^\+[^+]|^-[^-]' "${HASH_DIFF}" | awk '{print $2}' | sort -u | while read -r relpath; do
    official_file="${OFFICIAL_EXT}/${relpath}"
    built_file="${BUILT_EXT}/${relpath}"
    safe_name="$(echo "${relpath}" | sed 's#^\./##; s#/#_#g')"
    diff_out="${DIFFS_DIR}/${safe_name}.diff.txt"
    if [[ -f "${official_file}" && -f "${built_file}" ]]; then
      diff -u "${official_file}" "${built_file}" >"${diff_out}" 2>&1 || true
    elif [[ -f "${official_file}" ]]; then
      echo "File only in official release (not in built output)." >"${diff_out}"
    elif [[ -f "${built_file}" ]]; then
      echo "File only in built output (not in official release)." >"${diff_out}"
    fi
  done
  log "Per-file diffs written to ${DIFFS_DIR}/"
fi

# ==============================================================================
# Write COMPARISON_RESULTS.yaml
# ==============================================================================

if [[ "${MATCH_FLAG}" = "1" ]]; then
  cat >"${RESULTS_FILE}" <<YAML
script_version: ${SCRIPT_VERSION}
verdict: ${VERDICT}
YAML
else
  cat >"${RESULTS_FILE}" <<YAML
script_version: ${SCRIPT_VERSION}
verdict: not_reproducible
notes: "$(grep -c '' "${HASH_DIFF}" 2>/dev/null || echo "unknown") diff lines — see hash-diff-${VERSION}-${ARCH_OUT}.txt"
YAML
fi

# ==============================================================================
# Verification Result Summary
# ==============================================================================

COMMIT_HASH="$(gh_c api "repos/GingerPrivacy/GingerWallet/git/ref/tags/v${VERSION}" --jq '.object.sha' 2>/dev/null || echo "unknown")"

ZIP_NAME="${OFFICIAL_ASSET_NAME}"

echo ""
echo "===== Begin Results ====="
echo "appId:          gingerwallet"
echo "signer:         N/A"
echo "versionName:    ${VERSION}"
echo "versionCode:    ${VERSION}"
echo "verdict:        ${VERDICT}"
echo "appHash:        ${OFFICIAL_HASH}"
echo "commit:         ${COMMIT_HASH}"
echo ""
echo "BUILDS MATCH BINARIES"
echo "${ZIP_NAME} - ${ARCH_OUT} - ${BUILT_HASH} - ${MATCH_FLAG} ($([ "${MATCH_FLAG}" = "1" ] && echo "MATCHES" || echo "DOESN'T MATCH"))"
echo ""
echo "SUMMARY"
echo "total: 1"
echo "matches: ${MATCH_FLAG}"
echo "mismatches: $([ "${MATCH_FLAG}" = "1" ] && echo "0" || echo "1")"
echo ""
echo "Diff (first 5 lines — full diff at $(basename "${HASH_DIFF}")):"
if [[ -s "${HASH_DIFF}" ]]; then
  head -n 5 "${HASH_DIFF}"
  TOTAL_DIFF_LINES="$(grep -c '' "${HASH_DIFF}" 2>/dev/null || echo 0)"
  if [[ "${TOTAL_DIFF_LINES}" -gt 5 ]]; then
    echo "... (${TOTAL_DIFF_LINES} lines total)"
  fi
else
  echo "(no differences)"
fi
DIFF_FILES=0
if [[ -s "${HASH_DIFF}" ]]; then
  DIFF_FILES="$(grep -E '^\+[^+]|^-[^-]' "${HASH_DIFF}" | awk '{print $2}' | sort -u | wc -l)"
fi
echo ""
echo "Total number of files that differ: ${DIFF_FILES}"
echo ""
echo "Revision, tag (and its signature):"
echo "Tag type: commit-only"
echo "[INFO] Signature verification not performed"
echo ""
echo "===== End Results ====="
echo ""
echo "Run a full"
echo "diff --recursive ${OFFICIAL_EXT} ${BUILT_EXT}"
echo "or"
echo "diffoscope ${OFFICIAL_EXT} ${BUILT_EXT}"
echo "for more details."

if [[ "${MATCH_FLAG}" = "1" ]]; then
  echo "Exit code: ${EXIT_SUCCESS}"
  exit "${EXIT_SUCCESS}"
else
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi
