#!/usr/bin/env bash
# ==============================================================================
# gingerwallet_build.sh - GingerWallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.6.5
# Organization:  WalletScrutiny.com
# Last Modified: 2026-01-28
# Project:       https://github.com/GingerPrivacy/GingerWallet
# ==============================================================================

set -euo pipefail

APP_ID="gingerwallet"
APP_NAME="GingerWallet"
SCRIPT_VERSION="v0.6.5"
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
  $0 --version <version> [--arch <arch>] [--type <type>] [--apk <path>]

Required:
  --version <version>   Version without leading v (example: 2.0.23)

Optional:
  --arch <arch>         Architecture label from build server metadata
                        Supported values: linux-x64, linux64, x86_64-linux-gnu, x86_64-linux, win-x64
  --type <type>         Only "standalone" is supported for this script
  --apk <path>          Not supported for desktop builds (will exit 2)
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
  local arch_out="$1"
  local status="$2"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S+0000")"

  cat >"${RESULTS_FILE}" <<EOF
date: ${now}
script_version: ${SCRIPT_VERSION}
build_type: ${DEFAULT_BUILD_TYPE}
results:
  - architecture: ${arch_out}
    status: ${status}
    files:
      - filename: Ginger-${VERSION:-unknown}-${TARGET_ARCH:-linux-x64}.zip
        hash: 0000000000000000000000000000000000000000000000000000000000000000
        match: false
EOF
}

VERSION=""
ARCH_PARAM=""
TYPE_PARAM=""
APK_PATH=""

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
    --apk)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        err "--apk requires a value"
        echo "Exit code: ${EXIT_INVALID_PARAMS}"
        exit "${EXIT_INVALID_PARAMS}"
      fi
      APK_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      echo "Exit code: ${EXIT_SUCCESS}"
      exit "${EXIT_SUCCESS}"
      ;;
    *)
      err "Unknown argument: $1"
      usage
      echo "Exit code: ${EXIT_INVALID_PARAMS}"
      exit "${EXIT_INVALID_PARAMS}"
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  err "Missing required parameter: --version"
  usage
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
fi

if [[ -n "${APK_PATH}" ]]; then
  err "--apk is not supported for desktop builds"
  write_yaml_error "${ARCH_PARAM:-linux-x64}" "ftbfs" "\"--apk not supported\""
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
fi

if [[ -n "${TYPE_PARAM}" && "${TYPE_PARAM}" != "${DEFAULT_BUILD_TYPE}" ]]; then
  err "Unsupported --type: ${TYPE_PARAM}"
  write_yaml_error "${ARCH_PARAM:-linux-x64}" "ftbfs" "\"unsupported build type ${TYPE_PARAM}\""
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
fi

ARCH_OUT="${ARCH_PARAM:-linux-x64}"
TARGET_ARCH="linux-x64"
case "${ARCH_OUT}" in
  linux-x64|linux64|x86_64-linux-gnu|x86_64-linux)
    TARGET_ARCH="linux-x64"
    ;;
  win-x64)
    TARGET_ARCH="win-x64"
    ;;
  *)
    err "Unsupported --arch: ${ARCH_OUT}"
    write_yaml_error "${ARCH_OUT}" "ftbfs" "\"unsupported architecture ${ARCH_OUT}\""
    echo "Exit code: ${EXIT_INVALID_PARAMS}"
    exit "${EXIT_INVALID_PARAMS}"
    ;;
esac

# ==============================================================================
# Prerequisites: gh CLI
# ==============================================================================

if ! command -v gh >/dev/null 2>&1; then
  err "GitHub CLI (gh) is not installed. Install from https://cli.github.com/"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"gh CLI not installed\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

if ! gh auth status >/dev/null 2>&1; then
  err "GitHub CLI is not authenticated. Run: gh auth login"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"gh not authenticated\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

log "Using GitHub Actions on ${GH_REPO}"

# ==============================================================================
# Working directory setup
# ==============================================================================

NOW="$(date -u +"%Y-%m-%dT%H:%M:%S+0000")"
ART_DIR="${EXECUTION_DIR}/gingerwallet-${VERSION}-${ARCH_OUT}"
LOG_DIR="${ART_DIR}/logs"
mkdir -p "${ART_DIR}" "${LOG_DIR}"

cleanup() {
  : # Artifacts are kept for inspection
}
trap cleanup EXIT

# ==============================================================================
# Step 1: Download official release and extract SDK version from BUILDINFO.json
# ==============================================================================

OFFICIAL_DIR="${ART_DIR}/official-download"
mkdir -p "${OFFICIAL_DIR}"
OFFICIAL_ASSET_NAME=""
OFFICIAL_URL=""

log "Resolving official release asset for ${TARGET_ARCH}..."
OFFICIAL_ASSET_NAME="$(gh api "repos/GingerPrivacy/GingerWallet/releases/tags/v${VERSION}" \
  --jq ".assets[] | select(.name | contains(\"${TARGET_ARCH}\") and endswith(\".zip\")) | .name" \
  2>/dev/null | head -n 1 || true)"

if [[ -z "${OFFICIAL_ASSET_NAME}" ]]; then
  err "Could not find official .zip asset for ${TARGET_ARCH} in release v${VERSION}"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"official ${TARGET_ARCH} release asset not found\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

OFFICIAL_ZIP="${OFFICIAL_DIR}/${OFFICIAL_ASSET_NAME}"
OFFICIAL_URL="$(gh api "repos/GingerPrivacy/GingerWallet/releases/tags/v${VERSION}" \
  --jq ".assets[] | select(.name == \"${OFFICIAL_ASSET_NAME}\") | .browser_download_url" \
  2>/dev/null | head -n 1 || true)"

if [[ -z "${OFFICIAL_URL}" ]]; then
  err "Could not resolve download URL for ${OFFICIAL_ASSET_NAME}"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"official download URL not found\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

log "Downloading official release..."
if [[ ! -f "${OFFICIAL_ZIP}" ]]; then
  if ! curl -fL -o "${OFFICIAL_ZIP}" "${OFFICIAL_URL}"; then
    err "Failed to download official release from ${OFFICIAL_URL}"
    write_yaml_error "${ARCH_OUT}" "ftbfs" "\"failed to download official release\""
    echo "Exit code: ${EXIT_FAILURE}"
    exit "${EXIT_FAILURE}"
  fi
fi

SDK_VERSION="8.0.100"
RUNTIME_VERSION=""
BUILDINFO_TMP="$(mktemp -d "${ART_DIR}/buildinfo-XXXXXX")"
if unzip -q -o "${OFFICIAL_ZIP}" -d "${BUILDINFO_TMP}" >/dev/null 2>&1; then
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

log "Triggering GitHub Actions workflow on ${GH_REPO}..."
GH_WORKFLOW_REF="wallet-actions"
WORKFLOW_CMD=(gh workflow run "${GH_WORKFLOW}" --repo "${GH_REPO}" --ref "${GH_WORKFLOW_REF}" -f version="${VERSION}" -f sdk_version="${SDK_VERSION}")
if [[ -n "${RUNTIME_VERSION}" ]]; then
  WORKFLOW_CMD+=(-f runtime_version="${RUNTIME_VERSION}")
fi
if ! "${WORKFLOW_CMD[@]}"; then
  err "Failed to trigger workflow"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"failed to trigger GitHub Actions workflow\""
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
  RUN_ID="$(gh run list \
    --repo "${GH_REPO}" \
    --workflow "${GH_WORKFLOW}" \
    --limit 1 \
    --json databaseId,status,createdAt \
    --jq '.[0].databaseId' 2>/dev/null || true)"
  if [[ -n "${RUN_ID}" && "${RUN_ID}" != "null" ]]; then
    log "Found workflow run ID: ${RUN_ID}"
    break
  fi
  log "Poll attempt ${i}/${MAX_POLL}..."
done

if [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]]; then
  err "Could not find workflow run after ${MAX_POLL} attempts"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"workflow run not found\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

# ==============================================================================
# Step 4: Wait for workflow to complete
# ==============================================================================

log "Watching workflow run ${RUN_ID}..."
if ! gh run watch "${RUN_ID}" --repo "${GH_REPO}" --exit-status; then
  err "Workflow run ${RUN_ID} failed"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"GitHub Actions workflow failed\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

log "Workflow run ${RUN_ID} completed successfully."

# ==============================================================================
# Step 4b: Print workflow logs
# ==============================================================================

log "Fetching workflow logs..."
if ! gh run view "${RUN_ID}" --repo "${GH_REPO}" --log | tee "${LOG_DIR}/gh-run-${RUN_ID}.log"; then
  warn "Failed to fetch workflow logs"
fi

# ==============================================================================
# Step 5: Download build artifact
# ==============================================================================

ARTIFACT_NAME="gingerwallet-${VERSION}-${TARGET_ARCH}"
BUILT_DIR="${ART_DIR}/built"
mkdir -p "${BUILT_DIR}"

log "Downloading artifact: ${ARTIFACT_NAME}..."
if ! gh run download "${RUN_ID}" \
  --repo "${GH_REPO}" \
  --name "${ARTIFACT_NAME}" \
  --dir "${BUILT_DIR}"; then
  err "Failed to download artifact ${ARTIFACT_NAME}"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"failed to download build artifact\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

# ==============================================================================
# Step 6: Extract official release and compare
# ==============================================================================

OFFICIAL_EXT="${ART_DIR}/official-extracted"
rm -rf "${OFFICIAL_EXT}"
mkdir -p "${OFFICIAL_EXT}"
unzip -q "${OFFICIAL_ZIP}" -d "${OFFICIAL_EXT}"

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
  STATUS="reproducible"
  MATCH="true"
  MATCH_FLAG="1"
  VERDICT="reproducible"
else
  STATUS="not_reproducible"
  MATCH="false"
  MATCH_FLAG="0"
  VERDICT=""
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

cat >"${RESULTS_FILE}" <<YAML
date: ${NOW}
script_version: ${SCRIPT_VERSION}
build_type: ${DEFAULT_BUILD_TYPE}
results:
  - architecture: ${ARCH_OUT}
    status: ${STATUS}
    files:
      - filename: ${OFFICIAL_ASSET_NAME}
        hash: ${BUILT_HASH}
        match: ${MATCH}
YAML

# ==============================================================================
# Verification Result Summary
# ==============================================================================

COMMIT_HASH="$(gh api "repos/GingerPrivacy/GingerWallet/git/ref/tags/v${VERSION}" --jq '.object.sha' 2>/dev/null || echo "unknown")"

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
echo "Diff:"
if [[ -s "${HASH_DIFF}" ]]; then
  cat "${HASH_DIFF}"
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
