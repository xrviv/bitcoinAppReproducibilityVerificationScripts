#!/usr/bin/env bash
# ==============================================================================
# gingerwallet_build.sh - GingerWallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.5.5
# Organization:  WalletScrutiny.com
# Last Modified: 2026-01-27
# Project:       https://github.com/GingerPrivacy/GingerWallet
# ==============================================================================

set -euo pipefail

APP_ID="gingerwallet"
APP_NAME="GingerWallet"
SCRIPT_VERSION="v0.5.6"
REPO_URL="https://github.com/GingerPrivacy/GingerWallet.git"
DEFAULT_BUILD_TYPE="standalone"

EXIT_SUCCESS=0
EXIT_FAILURE=1
EXIT_INVALID_PARAMS=2

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<EOF
${APP_NAME} reproducible build verification
Version: ${SCRIPT_VERSION}
Organization: WalletScrutiny.com

Usage:
  $0 --version <version> [--arch <arch>] [--type <type>] [--apk <path>]

Required:
  --version <version>   Version without leading v (example: 2.0.23)

Optional:
  --arch <arch>         Architecture label from build server metadata
                        Supported values: linux-x64, linux64, x86_64-linux-gnu, x86_64-linux
  --type <type>         Only "standalone" is supported for this script
  --apk <path>          Not supported for desktop builds (will exit 2)
  -h, --help            Show this message
EOF
}

EXECUTION_DIR="$(pwd)"
RESULTS_FILE="${EXECUTION_DIR}/COMPARISON_RESULTS.yaml"

write_yaml_error() {
  local arch_out="$1"
  local status="$2"
  local reason="$3"
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
      - filename: Ginger-${VERSION:-unknown}-linux-x64.zip
        hash: 0000000000000000000000000000000000000000000000000000000000000000
        match: false
    reason: ${reason}
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
  *)
    err "Unsupported --arch: ${ARCH_OUT}"
    write_yaml_error "${ARCH_OUT}" "ftbfs" "\"unsupported architecture ${ARCH_OUT}\""
    echo "Exit code: ${EXIT_INVALID_PARAMS}"
    exit "${EXIT_INVALID_PARAMS}"
    ;;
esac

# Prefer CONTAINER_CMD env var, then docker, then podman.
CONTAINER_CMD="${CONTAINER_CMD:-}"
if [[ -z "${CONTAINER_CMD}" ]]; then
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  else
    err "Neither docker nor podman is available."
    write_yaml_error "${ARCH_OUT}" "ftbfs" "\"docker/podman not available\""
    echo "Exit code: ${EXIT_FAILURE}"
    exit "${EXIT_FAILURE}"
  fi
fi

log "Using container command: ${CONTAINER_CMD}"

if ! command -v "${CONTAINER_CMD}" >/dev/null 2>&1; then
  err "Container command not found: ${CONTAINER_CMD}"
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"container command not found\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

if [[ "${CONTAINER_CMD}" == "docker" ]]; then
  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running or not accessible."
    write_yaml_error "${ARCH_OUT}" "ftbfs" "\"docker daemon not accessible\""
    echo "Exit code: ${EXIT_FAILURE}"
    exit "${EXIT_FAILURE}"
  fi
fi

WORK_DIR="$(mktemp -d "${EXECUTION_DIR}/.gingerwallet-${VERSION}-${ARCH_OUT}-XXXXXX")"
IMAGE_NAME="ws-${APP_ID}-${VERSION}-${ARCH_OUT}-${TYPE_PARAM:-${DEFAULT_BUILD_TYPE}}-$(date -u +%s)"
VOLUME_SUFFIX=""
if [[ "${CONTAINER_CMD}" == "podman" ]]; then
  VOLUME_SUFFIX=":Z"
fi

cleanup() {
  rm -rf "${WORK_DIR}" >/dev/null 2>&1 || true
  "${CONTAINER_CMD}" image rm -f "${IMAGE_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"${WORK_DIR}/run-verify.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

NOW="$(date -u +"%Y-%m-%dT%H:%M:%S+0000")"
OUT_DIR="/output"
ART_DIR="${OUT_DIR}/artifacts-${VERSION}-${ARCH_OUT}"
RESULT_FILE="${OUT_DIR}/COMPARISON_RESULTS.yaml"
LOG_DIR="${ART_DIR}/logs"

mkdir -p "${ART_DIR}"
mkdir -p "${LOG_DIR}"

# Force all dotnet/MSBuild invocations to use Release configuration.
export Configuration=Release

write_yaml() {
  local status="$1"
  local match="$2"
  local built_hash="$3"
  local official_hash="$4"
  local reason="${5:-}"
  cat >"${RESULT_FILE}" <<YAML
date: ${NOW}
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${ARCH_OUT}
    status: ${status}
    files:
      - filename: Ginger-${VERSION}-${TARGET_ARCH}.zip
        hash: ${built_hash}
        match: ${match}
    official_hash: ${official_hash}
    built_hash: ${built_hash}
    hash_diff: ${ART_DIR}/hash-diff-${VERSION}-${ARCH_OUT}.txt
    reason: ${reason}
YAML
}

fail_ftbfs() {
  local reason="$1"
  write_yaml "ftbfs" "false" "0000000000000000000000000000000000000000000000000000000000000000" "0000000000000000000000000000000000000000000000000000000000000000" "\"${reason}\""
  exit 1
}

if [[ "${TARGET_ARCH}" != "linux-x64" ]]; then
  write_yaml "ftbfs" "false" "0000000000000000000000000000000000000000000000000000000000000000" "0000000000000000000000000000000000000000000000000000000000000000" "\"unsupported TARGET_ARCH ${TARGET_ARCH}\""
  exit 2
fi

cd /work

# Download the official release early so we can read BUILDINFO.json.
OFFICIAL_DIR="/work/official"
mkdir -p "${OFFICIAL_DIR}"
OFFICIAL_ZIP="${OFFICIAL_DIR}/Ginger-${VERSION}-linux-x64.zip"
OFFICIAL_URL="https://github.com/GingerPrivacy/GingerWallet/releases/download/v${VERSION}/Ginger-${VERSION}-linux-x64.zip"
if [[ ! -f "${OFFICIAL_ZIP}" ]]; then
  if ! curl -fL -o "${OFFICIAL_ZIP}" "${OFFICIAL_URL}"; then
    fail_ftbfs "failed to download official release"
  fi
fi

# Prefer the SDK version from the official build if it is available.
SDK_VERSION="8.0.100"
BUILDINFO_PATH=""
OFFICIAL_BUILDINFO="$(mktemp -d /work/official-buildinfo-XXXXXX)"
if unzip -q -o "${OFFICIAL_ZIP}" -d "${OFFICIAL_BUILDINFO}" >/dev/null 2>&1; then
  BUILDINFO_PATH="$(find "${OFFICIAL_BUILDINFO}" -type f -iname "BUILDINFO.json" | head -n 1 || true)"
fi
if [[ -n "${BUILDINFO_PATH}" ]]; then
  sdk_from_buildinfo="$(jq -r '.NetSdkVersion // empty' "${BUILDINFO_PATH}" 2>/dev/null || true)"
  if [[ -n "${sdk_from_buildinfo}" && "${sdk_from_buildinfo}" != "null" ]]; then
    SDK_VERSION="${sdk_from_buildinfo}"
  fi
fi
echo "${SDK_VERSION}" >"${LOG_DIR}/dotnet-sdk-version.txt"
if [[ -n "${BUILDINFO_PATH}" ]]; then
  cp "${BUILDINFO_PATH}" "${LOG_DIR}/official-BUILDINFO.json" >/dev/null 2>&1 || true
fi
rm -rf "${OFFICIAL_BUILDINFO}" >/dev/null 2>&1 || true

# Install the chosen SDK locally and force dotnet to use it.
DOTNET_ROOT_LOCAL="/work/dotnet"
DOTNET_INSTALL_SCRIPT="/work/dotnet-install.sh"
if curl -fsSL https://dot.net/v1/dotnet-install.sh -o "${DOTNET_INSTALL_SCRIPT}"; then
  if bash "${DOTNET_INSTALL_SCRIPT}" --version "${SDK_VERSION}" --install-dir "${DOTNET_ROOT_LOCAL}" >/dev/null 2>&1; then
    export DOTNET_ROOT="${DOTNET_ROOT_LOCAL}"
    export PATH="${DOTNET_ROOT_LOCAL}:${PATH}"
    export DOTNET_MULTILEVEL_LOOKUP=0
  fi
fi
dotnet --info >"${LOG_DIR}/dotnet-info.log" 2>&1 || true

if ! git clone --depth 1 --branch "v${VERSION}" "${REPO_URL}" src; then
  write_yaml "nosource" "false" "0000000000000000000000000000000000000000000000000000000000000000" "0000000000000000000000000000000000000000000000000000000000000000" "\"failed to clone tag v${VERSION}\""
  exit 1
fi

COMMIT_HASH="$(git -C /work/src rev-parse HEAD 2>/dev/null || echo "unknown")"

# Packager prompts on uncommitted changes and crashes in non-interactive mode.
# The force-evaluate restore can dirty lock files, so skip the prompt safely.
PACKAGER_PROGRAM="/work/src/WalletWasabi.Packager/Program.cs"
if [[ -f "${PACKAGER_PROGRAM}" ]]; then
  export WS_SKIP_GIT_CHECK=1
  sed -i '/private static void CheckUncommittedGitChanges()/,/^[[:space:]]*}/ s/if (TryStartProcessAndWaitForExit/if ((Console.IsInputRedirected || Environment.GetEnvironmentVariable("WS_SKIP_GIT_CHECK") == "1") ? false : TryStartProcessAndWaitForExit/' "${PACKAGER_PROGRAM}" || true
fi

cd /work/src/WalletWasabi.Packager

dotnet nuget locals all --clear || true

RESTORE_NOTE=""
# GingerWallet lock files can differ between Debug and Release.
# Do the Release force-evaluate sequence recommended in build notes.
if ! dotnet restore /work/src/WalletWasabi.Fluent/WalletWasabi.Fluent.csproj -p:Configuration=Release --force-evaluate >"${LOG_DIR}/restore-fluent.log" 2>&1; then
  RESTORE_NOTE="force-evaluate failed for WalletWasabi.Fluent"
fi
if ! dotnet restore /work/src/WalletWasabi.Fluent.Desktop/WalletWasabi.Fluent.Desktop.csproj -p:Configuration=Release --force-evaluate >"${LOG_DIR}/restore-fluent-desktop.log" 2>&1; then
  RESTORE_NOTE="${RESTORE_NOTE}; force-evaluate failed for WalletWasabi.Fluent.Desktop"
fi
if ! dotnet restore /work/src/WalletWasabi.sln -p:Configuration=Release --locked-mode >"${LOG_DIR}/restore-sln-locked.log" 2>&1; then
  RESTORE_NOTE="${RESTORE_NOTE}; locked-mode restore failed for solution"
  dotnet restore /work/src/WalletWasabi.sln -p:Configuration=Release --force-evaluate >"${LOG_DIR}/restore-sln-force.log" 2>&1
fi

# Let the Packager handle the full build naturally.
# The source generator (WalletWasabi.Fluent.Generators) is already referenced
# as a ProjectReference with OutputItemType="Analyzer" in WalletWasabi.Fluent.csproj.
# MSBuild resolves this automatically during a normal build — no manual injection needed.
# Previous versions (v0.3.x–v0.4.0) tried to manually build and inject the generator DLL
# as an <Analyzer> element, but --no-restore meant the patched csproj was never re-evaluated,
# so Roslyn never loaded the generator and AutoNotify/AccessModifier symbols were missing.
if ! dotnet build -c Release >"${LOG_DIR}/build-packager.log" 2>&1; then
  fail_ftbfs "packager build failed; see ${LOG_DIR}/build-packager.log"
fi

# The Packager calls xdg-open at the end to open the output folder, which
# crashes in a headless container.  Ignore its exit code — we check for the
# output zip below instead.
dotnet run -- --onlybinaries >"${LOG_DIR}/packager-run.log" 2>&1 || true

# Capture generator diagnostic info for debugging.
find /work/src/WalletWasabi.Fluent/obj -type d -path "*GeneratedFiles" -exec find {} -maxdepth 5 -type f \( -name "*AutoNotify*" -o -name "*AccessModifier*" \) \; >"${LOG_DIR}/generated-files.txt" 2>&1 || true

# The Packager produces a directory, not a zip.
BUILT_DIR="/work/src/WalletWasabi.Fluent.Desktop/bin/dist/linux-x64"
if [[ ! -d "${BUILT_DIR}" ]]; then
  fail_ftbfs "built directory not found at ${BUILT_DIR}"
fi

# The official zip should already be present from the BUILDINFO step.
if [[ ! -f "${OFFICIAL_ZIP}" ]]; then
  if ! curl -fL -o "${OFFICIAL_ZIP}" "${OFFICIAL_URL}"; then
    fail_ftbfs "failed to download official release"
  fi
fi

OFFICIAL_HASH="$(sha256sum "${OFFICIAL_ZIP}" | awk '{print $1}')"

EXTRACT_BASE="/work/extracted"
OFFICIAL_EXT="${EXTRACT_BASE}/official"
BUILT_EXT="${BUILT_DIR}"
rm -rf "${EXTRACT_BASE}"
mkdir -p "${OFFICIAL_EXT}"

unzip -q "${OFFICIAL_ZIP}" -d "${OFFICIAL_EXT}"

# Hash the built directory contents for the YAML and summary output.
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

REASON="\"${RESTORE_NOTE}\""
write_yaml "${STATUS}" "${MATCH}" "${BUILT_HASH}" "${OFFICIAL_HASH}" "${REASON}"

# --- Verification Result Summary (see verification-result-summary-format.md) ---
ZIP_NAME="Ginger-${VERSION}-${TARGET_ARCH}.zip"

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
echo ""
echo "Revision, tag (and its signature):"
echo "Tag type: commit-only"
echo "[INFO] Signature verification not performed in container"
echo ""
echo "===== End Results ====="
echo ""
echo "Run a full"
echo "diff --recursive ${OFFICIAL_EXT} ${BUILT_EXT}"
echo "or"
echo "diffoscope ${OFFICIAL_EXT} ${BUILT_EXT}"
echo "for more details."

if [[ "${MATCH_FLAG}" = "1" ]]; then
  exit 0
else
  exit 1
fi
SCRIPT

cat >"${WORK_DIR}/Dockerfile" <<EOF
FROM mcr.microsoft.com/dotnet/sdk:8.0.100-jammy
SHELL ["/bin/bash", "-lc"]

ARG VERSION
ARG ARCH_OUT
ARG TARGET_ARCH
ARG SCRIPT_VERSION
ARG BUILD_TYPE
ARG REPO_URL

ENV VERSION="\${VERSION}"
ENV ARCH_OUT="\${ARCH_OUT}"
ENV TARGET_ARCH="\${TARGET_ARCH}"
ENV SCRIPT_VERSION="\${SCRIPT_VERSION}"
ENV BUILD_TYPE="\${BUILD_TYPE}"
ENV REPO_URL="\${REPO_URL}"
ENV HOME="/work/home"
ENV DOTNET_CLI_HOME="/work/home"
ENV NUGET_PACKAGES="/work/nuget-packages"
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1"
ENV DOTNET_CLI_TELEMETRY_OPTOUT="1"

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git \\
    curl \\
    unzip \\
    jq \\
    diffutils \\
    findutils \\
    ca-certificates \\
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /work /work/home /work/nuget-packages \\
  && chmod 0777 /work /work/home /work/nuget-packages

COPY run-verify.sh /usr/local/bin/run-verify.sh
RUN chmod +x /usr/local/bin/run-verify.sh

CMD ["/usr/local/bin/run-verify.sh"]
EOF

log "Building container image: ${IMAGE_NAME}"
if ! "${CONTAINER_CMD}" build \
  --no-cache \
  --build-arg VERSION="${VERSION}" \
  --build-arg ARCH_OUT="${ARCH_OUT}" \
  --build-arg TARGET_ARCH="${TARGET_ARCH}" \
  --build-arg SCRIPT_VERSION="${SCRIPT_VERSION}" \
  --build-arg BUILD_TYPE="${DEFAULT_BUILD_TYPE}" \
  --build-arg REPO_URL="${REPO_URL}" \
  -t "${IMAGE_NAME}" \
  "${WORK_DIR}"; then
  err "Container build failed."
  write_yaml_error "${ARCH_OUT}" "ftbfs" "\"container build failed\""
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi

log "Running verification inside container."
set +e
"${CONTAINER_CMD}" run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${EXECUTION_DIR}:/output${VOLUME_SUFFIX}" \
  "${IMAGE_NAME}"
container_rc=$?
set -e

if [[ -f "${RESULTS_FILE}" ]]; then
  # Make sure host files are readable by the current user.
  chown "$(id -u):$(id -g)" "${RESULTS_FILE}" >/dev/null 2>&1 || true
fi

if [[ ${container_rc} -eq 0 ]]; then
  log "Reproducible build."
  echo "Exit code: ${EXIT_SUCCESS}"
  exit "${EXIT_SUCCESS}"
elif [[ ${container_rc} -eq ${EXIT_INVALID_PARAMS} ]]; then
  err "Invalid parameters inside container."
  echo "Exit code: ${EXIT_INVALID_PARAMS}"
  exit "${EXIT_INVALID_PARAMS}"
else
  warn "Build completed but did not match, or failed."
  echo "Exit code: ${EXIT_FAILURE}"
  exit "${EXIT_FAILURE}"
fi
