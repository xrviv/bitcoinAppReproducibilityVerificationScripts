#!/bin/bash
# ==============================================================================
# stackwalletdesktop_build.sh - Stack Wallet Linux Desktop Reproducible Build
# ==============================================================================
# Version:       v0.1.0
# Organization:  WalletScrutiny.com
# Project:       https://github.com/cypherstack/stack_wallet
# ==============================================================================
# TECHNICAL DISCLAIMER: Provided for security research and reproducible build
# verification only. No warranty. Users assume all risks.
# LEGAL DISCLAIMER: For legitimate security research. Users are responsible for
# legal compliance. By using this script, you acknowledge these disclaimers.
#
# SCRIPT SUMMARY:
# x86_64-linux (default): container build (Ubuntu 24.04, Rust 1.89.0+1.85.1+1.71.0,
#   Go 1.24.4, Flutter 3.38.1); compares AppImage lib/ file-by-file
# x86_64-windows: triggers builds-branch GitHub Actions workflow on windows-2022
#   runner; downloads artifact and compares ZIP contents file-by-file
# Generates COMPARISON_RESULTS.yaml

set -uo pipefail

SCRIPT_VERSION="v0.2.0"
APP_ID="desk.stackwallet"
REPO_URL="https://github.com/cypherstack/stack_wallet.git"
GITHUB_REPO="cypherstack/stack_wallet"
BUILD_IMAGE_NAME="stackwalletdesktop_build_env"
GH_WORKFLOW="build.yaml"
GH_WORKFLOW_REF="builds"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"
build_timestamp="$(date -u +%Y%m%d%H%M%S)"
build_pid="$$"

requested_version=""
requested_arch="x86_64-linux"
requested_type="appimage"
binary_input=""
should_cleanup=false

version_name=""
git_tag=""
build_number=""
appimage_path=""
appimage_sha256=""
work_dir=""
yaml_status="not_reproducible"
additional_info=""
total_diff_count=0
extra_in_built=()
missing_from_built=()
differing_files=()
matching_files=()

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR] $*"; }

append_info() {
  [[ -n "${additional_info}" ]] && additional_info="${additional_info}
$1" || additional_info="$1"
}

write_yaml() {
  local v="$1" notes="$2"
  cat > "${execution_dir}/COMPARISON_RESULTS.yaml" <<YAML
script_version: ${SCRIPT_VERSION}
verdict: ${v}
notes: |
$(echo "${notes}" | sed 's/^/  /')
YAML
}

die_invalid() {
  log_error "$*"
  write_yaml "ftbfs" "Invalid parameters: $*"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  write_yaml "ftbfs" "Build failed: $*"
  exit "${EXIT_FAILED}"
}

on_error() {
  local code=$? line=$1
  set +e
  log_error "Script failed at line ${line} (exit ${code})"
  write_yaml "ftbfs" "Script error at line ${line} (exit ${code})"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

CONTAINER_CMD="" VOLUME_RO="" VOLUME_RW=""
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"; VOLUME_RO=":ro,Z"; VOLUME_RW=":Z"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"; VOLUME_RO=":ro"; VOLUME_RW=""
else
  die_failed "Neither podman nor docker found."
fi

usage() {
  cat <<EOF
NAME
    ${script_name} - Stack Wallet Linux Desktop reproducible build verification

SYNOPSIS
    ${script_name} --version <ver> [--type appimage] [OPTIONS]
    ${script_name} --binary <path/to/sw-v*.linux.AppImage> [OPTIONS]

OPTIONS
    --version <ver>   Version to verify, e.g. 2.4.4 (downloads from GitHub)
    --binary <file>   Path to official AppImage (skips download)
    --arch <arch>     x86_64-linux (default) or x86_64-windows; others warn+continue
    --type <type>     appimage (default, linux), zip (windows), flatpak (unsupported)
    --cleanup         Remove work directory after completion
    --script-version  Print version and exit
    --help            Show this help and exit

EXIT CODES
    0  All bundle files identical
    1  Differences found or build failed
    2  Invalid parameters
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)       [[ -z "${2:-}" || "${2}" == --* ]] && die_invalid "--version requires a value"
                     requested_version="$2"; shift ;;
    --binary)        [[ -z "${2:-}" || "${2}" == --* ]] && die_invalid "--binary requires a value"
                     binary_input="$2"; shift ;;
    --arch)          [[ -z "${2:-}" || "${2}" == --* ]] && die_invalid "--arch requires a value"
                     requested_arch="$2"; shift ;;
    --type)          [[ -z "${2:-}" || "${2}" == --* ]] && die_invalid "--type requires a value"
                     requested_type="$2"; shift ;;
    --cleanup)       should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; exit "${EXIT_SUCCESS}" ;;
    --help)          usage; exit "${EXIT_SUCCESS}" ;;
    *)               log_warn "Ignoring unknown parameter: $1" ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] && die_invalid "Do not run as root."
[[ -z "${requested_version}" && -z "${binary_input}" ]] && \
  die_invalid "Either --version or --binary is required."

if [[ "${requested_type}" == "flatpak" ]]; then
  log_warn "Flatpak verification is not supported (no flatpak-builder manifest in repo)."
  write_yaml "not_reproducible" \
    "Flatpak packaging is undocumented upstream; no flatpak-builder manifest exists in the repository."
  exit "${EXIT_FAILED}"
fi

if [[ "${requested_arch}" != "x86_64-linux" && "${requested_arch}" != "x86_64-windows" ]]; then
  log_warn "Arch '${requested_arch}' is not a supported target. Continuing."
  append_info "Unsupported arch: ${requested_arch}."
fi

# ------------------------------------------------------------------------------
# Resolve version and git tag from GitHub API
# ------------------------------------------------------------------------------
resolve_release() {
  local ver="$1" asset_name="$2"
  local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases"
  local curl_opts=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && curl_opts+=(-H "Authorization: token ${GITHUB_TOKEN}")
  local tag
  tag=$(curl -fsSL "${curl_opts[@]}" "${api_url}" 2>/dev/null | \
    python3 -c "
import sys, json
releases = json.load(sys.stdin)
target = '${asset_name}'
for r in releases:
    if any(a['name'] == target for a in r.get('assets', [])):
        print(r['tag_name']); sys.exit(0)
sys.exit(1)" 2>/dev/null) || true
  echo "${tag}"
}

download_appimage() {
  local ver="$1" tag="$2" dest="$3"
  local url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/sw-v${ver}-linux.AppImage"
  log_info "Downloading: ${url}"
  curl -fSL -o "${dest}" "${url}"
}

if [[ -n "${binary_input}" ]]; then
  [[ ! -f "${binary_input}" ]] && die_invalid "--binary path does not exist: ${binary_input}"
  appimage_path="$(realpath "${binary_input}")"
  fname="$(basename "${appimage_path}")"
  if [[ "${fname}" =~ sw-v([0-9]+\.[0-9]+\.[0-9]+)-linux\.AppImage ]]; then
    version_name="${BASH_REMATCH[1]}"
  fi
  [[ -n "${requested_version}" ]] && version_name="${requested_version}"
  [[ -z "${version_name}" ]] && die_invalid "Cannot detect version from filename. Pass --version."
else
  version_name="${requested_version}"
fi

log_info "Version: ${version_name}"

if [[ -z "${git_tag}" ]]; then
  log_info "Resolving release tag from GitHub API..."
  local_asset="sw-v${version_name}-linux.AppImage"
  [[ "${requested_arch}" == "x86_64-windows" ]] && local_asset="stack_wallet-v${version_name}-windows.zip"
  git_tag=$(resolve_release "${version_name}" "${local_asset}")
  [[ -z "${git_tag}" ]] && die_failed "Could not find GitHub release for ${local_asset}."
  log_info "Release tag: ${git_tag}"
fi

# Extract numeric build number from tag (build_301 → 301)
build_number="${git_tag#build_}"

work_dir="${execution_dir}/workdir_stackwalletdesktop_${version_name}_${requested_arch}_${build_timestamp}_${build_pid}"
mkdir -p "${work_dir}"
log_info "Work dir: ${work_dir}"

# ==============================================================================
# Windows path: trigger GitHub Actions workflow, compare ZIP contents
# ==============================================================================
if [[ "${requested_arch}" == "x86_64-windows" ]]; then
  command -v gh >/dev/null 2>&1 || die_failed "gh CLI required for Windows verification. Install from https://cli.github.com"

  official_zip="${work_dir}/stack_wallet-v${version_name}-windows.zip"
  win_url="https://github.com/${GITHUB_REPO}/releases/download/${git_tag}/stack_wallet-v${version_name}-windows.zip"
  log_info "Downloading official Windows ZIP..."
  curl -fSL -o "${official_zip}" "${win_url}" || die_failed "Failed to download official Windows ZIP."
  official_zip_sha256=$(sha256sum "${official_zip}" | awk '{print $1}')
  log_info "Official ZIP SHA256: ${official_zip_sha256}"

  log_info "Snapshotting existing workflow runs..."
  mapfile -t _PRE_IDS < <(gh run list --repo "${GITHUB_REPO}" --workflow "${GH_WORKFLOW}" \
    --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)
  TRIGGER_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  log_info "Triggering ${GH_WORKFLOW} on ${GH_WORKFLOW_REF} (version=${version_name} build_number=${build_number})..."
  gh workflow run "${GH_WORKFLOW}" --repo "${GITHUB_REPO}" --ref "${GH_WORKFLOW_REF}" \
    -f version="${version_name}" -f build_number="${build_number}" || \
    die_failed "Failed to trigger GitHub Actions workflow."

  log_info "Polling for workflow run ID..."
  RUN_ID=""
  for i in $(seq 1 30); do
    sleep 10
    mapfile -t _CANDS < <(gh run list --repo "${GITHUB_REPO}" --workflow "${GH_WORKFLOW}" \
      --limit 10 --json databaseId,createdAt \
      --jq "[.[] | select(.createdAt >= \"${TRIGGER_TIME}\")] | .[].databaseId" 2>/dev/null || true)
    for _cid in "${_CANDS[@]:-}"; do
      [[ -z "${_cid}" || "${_cid}" == "null" ]] && continue
      _new=true
      for _pid in "${_PRE_IDS[@]:-}"; do [[ "${_cid}" == "${_pid}" ]] && _new=false && break; done
      [[ "${_new}" == "true" ]] && RUN_ID="${_cid}" && break
    done
    [[ -n "${RUN_ID}" ]] && { log_info "Run ID: ${RUN_ID}"; break; }
    log_info "Poll ${i}/30..."
  done
  [[ -z "${RUN_ID}" || "${RUN_ID}" == "null" ]] && die_failed "Could not find workflow run."

  log_info "Waiting for workflow run ${RUN_ID} to complete..."
  gh run watch "${RUN_ID}" --repo "${GITHUB_REPO}" --exit-status || \
    die_failed "GitHub Actions workflow failed. Check: https://github.com/${GITHUB_REPO}/actions/runs/${RUN_ID}"

  ARTIFACT_NAME="stack_wallet-windows-x86_64-${version_name}"
  built_dir="${work_dir}/built-windows"
  mkdir -p "${built_dir}"
  log_info "Downloading artifact: ${ARTIFACT_NAME}..."
  gh run download "${RUN_ID}" --repo "${GITHUB_REPO}" \
    --name "${ARTIFACT_NAME}" --dir "${built_dir}" || \
    die_failed "Failed to download artifact ${ARTIFACT_NAME}."

  # Extract both ZIPs and compare file-by-file
  official_ext="${work_dir}/official-extracted"
  built_ext="${work_dir}/built-extracted"
  mkdir -p "${official_ext}" "${built_ext}"
  unzip -q "${official_zip}" -d "${official_ext}"

  # Built artifact may be a zip itself or the extracted files directly
  built_zip=$(find "${built_dir}" -name "*.zip" | head -1)
  if [[ -n "${built_zip}" ]]; then
    unzip -q "${built_zip}" -d "${built_ext}"
  else
    cp -r "${built_dir}/." "${built_ext}/"
  fi

  log_info "Comparing Windows ZIP contents..."
  diff_output_file="${work_dir}/diff_windows.txt"
  : > "${diff_output_file}"
  mapfile -t off_files < <(find "${official_ext}" -type f | sed "s|${official_ext}/||" | sort)
  mapfile -t blt_files < <(find "${built_ext}" -type f | sed "s|${built_ext}/||" | sort)
  declare -A _off_set _blt_set
  for f in "${off_files[@]}"; do _off_set["$f"]=1; done
  for f in "${blt_files[@]}"; do _blt_set["$f"]=1; done
  all_win_files=($(printf '%s\n' "${off_files[@]}" "${blt_files[@]}" | sort -u))
  for fname in "${all_win_files[@]}"; do
    if [[ -z "${_off_set[$fname]+x}" ]]; then
      extra_in_built+=("${fname}"); echo "EXTRA: ${fname}" >> "${diff_output_file}"
      total_diff_count=$((total_diff_count + 1))
    elif [[ -z "${_blt_set[$fname]+x}" ]]; then
      missing_from_built+=("${fname}"); echo "MISSING: ${fname}" >> "${diff_output_file}"
      total_diff_count=$((total_diff_count + 1))
    else
      oh=$(sha256sum "${official_ext}/${fname}" | awk '{print $1}')
      bh=$(sha256sum "${built_ext}/${fname}" | awk '{print $1}')
      if [[ "${oh}" == "${bh}" ]]; then
        matching_files+=("${fname}"); echo "MATCH: ${fname}  ${oh}" >> "${diff_output_file}"
      else
        differing_files+=("${fname}"); total_diff_count=$((total_diff_count + 1))
        echo "DIFF: ${fname}" >> "${diff_output_file}"
        echo "  official: ${oh}" >> "${diff_output_file}"
        echo "  built:    ${bh}" >> "${diff_output_file}"
      fi
    fi
  done

  [[ "${total_diff_count}" -eq 0 ]] && yaml_status="reproducible" || yaml_status="not_reproducible"
  mc="${#matching_files[@]}"; dc="${#differing_files[@]}"
  ec="${#extra_in_built[@]}"; mc2="${#missing_from_built[@]}"
  WIN_NOTES="Stack Wallet Windows ${version_name} (tag ${git_tag}) x86_64.
Official ZIP SHA256: ${official_zip_sha256}
Built via GitHub Actions workflow ${GH_WORKFLOW} on ${GH_WORKFLOW_REF} (run ${RUN_ID}).
Comparison: file-by-file SHA256 of ZIP contents.
Results: ${mc} match, ${dc} differ, ${ec} extra-in-built, ${mc2} missing-from-built."
  [[ "${dc}" -gt 0 ]] && WIN_NOTES+="
Differing: $(IFS=', '; echo "${differing_files[*]}")"
  [[ "${ec}" -gt 0 ]] && WIN_NOTES+="
Extra in built: $(IFS=', '; echo "${extra_in_built[*]}")"
  [[ "${mc2}" -gt 0 ]] && WIN_NOTES+="
Missing: $(IFS=', '; echo "${missing_from_built[*]}")"
  [[ -n "${additional_info}" ]] && WIN_NOTES+="
${additional_info}"
  write_yaml "${yaml_status}" "${WIN_NOTES}"
  echo ""
  echo "===== Begin Results ====="
  echo "appId:   ${APP_ID}"; echo "version: ${version_name}"; echo "arch:    x86_64-windows"
  echo "gitTag:  ${git_tag}"; echo "runId:   ${RUN_ID}"; echo "verdict: ${yaml_status}"
  echo "Files:   ${mc} match / ${dc} differ / ${ec} extra / ${mc2} missing"
  [[ "${dc}" -gt 0 ]] && { echo "Differing:"; for f in "${differing_files[@]}"; do echo "  ${f}"; done; }
  echo "Diff log: ${diff_output_file}"
  echo "===== End Results ====="
  [[ "${should_cleanup}" == "true" ]] && rm -rf "${work_dir}"
  [[ "${total_diff_count}" -eq 0 ]] && exit "${EXIT_SUCCESS}" || exit "${EXIT_FAILED}"
fi

# ==============================================================================
# Linux AppImage path (continues below)
# ==============================================================================
if [[ -z "${appimage_path}" ]]; then
  appimage_path="${work_dir}/sw-v${version_name}-linux.AppImage"
  download_appimage "${version_name}" "${git_tag}" "${appimage_path}"
fi

appimage_sha256=$(sha256sum "${appimage_path}" | awk '{print $1}')
log_info "AppImage SHA256: ${appimage_sha256}"

# ------------------------------------------------------------------------------
# Extract AppImage squashfs (Type 2 ELF: squashfs at shoff + shnum*shentsize)
# ------------------------------------------------------------------------------
log_info "Extracting AppImage squashfs..."
command -v unsquashfs >/dev/null 2>&1 || die_failed "unsquashfs not found. Install squashfs-tools."
SQUASHFS_OFFSET=$(python3 -c "
import struct
with open('${appimage_path}', 'rb') as f:
    f.seek(0x28); shoff = struct.unpack('<Q', f.read(8))[0]
    f.seek(0x3a); shentsize = struct.unpack('<H', f.read(2))[0]
    f.seek(0x3c); shnum = struct.unpack('<H', f.read(2))[0]
    off = shoff + shnum * shentsize
    f.seek(off)
    magic = f.read(4)
    if magic in (b'hsqs', b'sqsh'):
        print(off)
    else:
        raise ValueError(f'No squashfs magic at {off}: {magic.hex()}')
" 2>/dev/null) || die_failed "Could not detect squashfs offset in AppImage."

squashfs_dir="${work_dir}/official-squashfs"
unsquashfs -q -o "${SQUASHFS_OFFSET}" -d "${squashfs_dir}" "${appimage_path}" || \
  die_failed "unsquashfs extraction failed."
log_info "AppImage extracted to: ${squashfs_dir}"

official_lib="${squashfs_dir}/lib"
[[ -d "${official_lib}" ]] || die_failed "No lib/ directory found in AppImage squashfs."

# ------------------------------------------------------------------------------
# Build toolchain image (inline Dockerfile — proven in triage build 2026-06-03)
# ------------------------------------------------------------------------------
build_image="${BUILD_IMAGE_NAME}:${git_tag}"
log_info "Building container image: ${build_image}"
log_info "(First run: ~60-90 min for Rust/Go/Flutter download and compile)"

${CONTAINER_CMD} build -t "${build_image}" - <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ENV TAR_OPTIONS="--no-same-owner"
ENV PATH="/opt/python-build-tools/bin:/root/.cargo/bin:/usr/local/go/bin:/opt/flutter/bin:/root/.local/bin:${PATH}"

RUN apt-get update && apt-get install -y \
    git curl unzip wget file pkg-config rsync vim \
    build-essential automake libtool cmake ninja-build \
    clang g++ gcc llvm lld \
    libssl-dev zlib1g-dev \
    libncurses5-dev libncursesw5-dev \
    libgit2-dev libgcrypt20-dev libglib2.0-dev \
    libgirepository1.0-dev gobject-introspection valac xsltproc \
    libgtk-3-dev liblzma-dev libblkid-dev \
    libsecret-1-dev libgpgme-dev \
    gperf libopencv-dev python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/python-build-tools \
    && /opt/python-build-tools/bin/pip install --quiet \
    "meson==0.64.1" "markdown==3.4.1" "markupsafe==2.1.1" \
    "jinja2==3.1.2" "pygments==2.13.0" "toml==0.10.2" \
    "typogrify==2.0.7" "tomli==2.0.1" "setuptools"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain 1.89.0 --no-modify-path
RUN rustup install 1.85.1 1.71.0 && \
    for tc in stable 1.89.0 1.85.1 1.71.0; do \
      rustup component add clippy --toolchain "$tc" 2>/dev/null || true; \
    done

RUN curl -fsSL https://go.dev/dl/go1.24.4.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz

RUN git clone --depth 1 --branch 3.38.1 \
    https://github.com/flutter/flutter.git /opt/flutter && \
    flutter precache --linux && flutter doctor || true

WORKDIR /build
DOCKERFILE

# ------------------------------------------------------------------------------
# Build script (runs inside container)
# ------------------------------------------------------------------------------
output_dir="${work_dir}/build-output"
mkdir -p "${output_dir}"

cat > "${work_dir}/run_build.sh" <<'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail
GIT_TAG="$1"
APP_VERSION="$2"

echo "[BUILD] Cloning stack_wallet at ${GIT_TAG}..."
git clone --depth 1 --branch "${GIT_TAG}" \
    https://github.com/cypherstack/stack_wallet.git /build/src
cd /build/src
git submodule update --init --recursive

echo "[BUILD] Building secure storage deps (jsoncpp + libsecret)..."
cd scripts/linux && bash build_secure_storage_deps.sh
cd /build/src

echo "[BUILD] Building crypto plugins for Linux (~60 min first run)..."
cd scripts
echo "yes" | ./build_app.sh -v "${APP_VERSION}" -b "$(echo "${GIT_TAG}" | tr -dc '0-9')" \
    -p linux -a stack_wallet
cd /build/src

echo "[BUILD] Applying Riverpod 1.0.4 / Flutter 3.38.1 AOT patch..."
python3 -c "
open('lib/utilities/consumer_state_mixin_compat.dart','w').write(
\"import 'package:flutter_riverpod/flutter_riverpod.dart';\n\n\"
\"abstract class ConsumerStateWithMixinCompat<W extends ConsumerStatefulWidget>\n\"
\"    extends ConsumerState<W> {\n\"
\"  @override\n\"
\"  void activate() => super.activate();\n\"
\"}\n\")
"
sed -i "s|extends ConsumerState<DesktopMenuItem<T>>|extends ConsumerStateWithMixinCompat<DesktopMenuItem<T>>|" \
    lib/pages_desktop_specific/desktop_menu_item.dart
grep -q "consumer_state_mixin_compat" lib/pages_desktop_specific/desktop_menu_item.dart || \
    sed -i "1s|^|import 'package:stackwallet/utilities/consumer_state_mixin_compat.dart';\n|" \
        lib/pages_desktop_specific/desktop_menu_item.dart
sed -i "s|extends ConsumerState<DesktopTorStatusButton>|extends ConsumerStateWithMixinCompat<DesktopTorStatusButton>|" \
    lib/widgets/desktop/desktop_tor_status_button.dart
grep -q "consumer_state_mixin_compat" lib/widgets/desktop/desktop_tor_status_button.dart || \
    sed -i "1s|^|import 'package:stackwallet/utilities/consumer_state_mixin_compat.dart';\n|" \
        lib/widgets/desktop/desktop_tor_status_button.dart
sed -i "s|extends ConsumerState<_TorAnimatedButton>|extends ConsumerStateWithMixinCompat<_TorAnimatedButton>|" \
    lib/pages/settings_views/global_settings_view/tor_settings/tor_settings_view.dart
grep -q "consumer_state_mixin_compat" \
    lib/pages/settings_views/global_settings_view/tor_settings/tor_settings_view.dart || \
    sed -i "1s|^|import 'package:stackwallet/utilities/consumer_state_mixin_compat.dart';\n|" \
        lib/pages/settings_views/global_settings_view/tor_settings/tor_settings_view.dart

echo "[BUILD] Writing API key stubs..."
python3 -c "
open('lib/external_api_keys.dart','w').write(
'const kChangeNowApiKey = \"\";\n'
'const kSimpleSwapApiKey = \"\";\n'
'const kNanswapApiKey = \"\";\n'
'const kNanoSwapRpcApiKey = \"\";\n'
'const kWizSwapApiKey = \"\";\n'
'const kShopInBitAccessKey = \"\";\n'
'const kShopInBitPartnerSecret = \"\";\n'
'const kCakePayApiToken = \"\";\n'
'const kExolixApiKey = \"\";\n')
"

echo "[BUILD] flutter pub get..."
flutter pub get

echo "[BUILD] flutter build linux --release..."
flutter build linux --release 2>&1 | tee /output/flutter_build.log

bundle="build/linux/x64/release/bundle"
[[ -d "${bundle}" ]] || { echo "[ERROR] Bundle not found at ${bundle}"; exit 1; }
cp -r "${bundle}" /output/bundle
echo "[BUILD] Bundle copied to /output/bundle"
echo "[BUILD] Done."
BUILDSCRIPT
chmod +x "${work_dir}/run_build.sh"

log_info "Running container build (first run: 60-90+ min)..."
${CONTAINER_CMD} run --rm \
  --volume "${work_dir}/run_build.sh:/run_build.sh${VOLUME_RO}" \
  --volume "${output_dir}:/output${VOLUME_RW}" \
  ${GITHUB_TOKEN:+--env GITHUB_TOKEN="${GITHUB_TOKEN}"} \
  "${build_image}" \
  bash /run_build.sh "${git_tag}" "${version_name}"

built_lib="${output_dir}/bundle/lib"
[[ -d "${built_lib}" ]] || die_failed "Built bundle lib/ not found at ${built_lib}."

# ------------------------------------------------------------------------------
# File-by-file comparison: official AppImage lib/ vs built bundle lib/
# ------------------------------------------------------------------------------
log_info "Comparing bundle lib/ files..."

diff_output_file="${work_dir}/diff_lib_files.txt"
: > "${diff_output_file}"

mapfile -t official_files < <(find "${official_lib}" -maxdepth 1 -type f -o -type l | \
  xargs -I{} basename {} | sort -u)
mapfile -t built_files < <(find "${built_lib}" -maxdepth 1 -type f -o -type l | \
  xargs -I{} basename {} | sort -u)

declare -A official_set built_set
for f in "${official_files[@]}"; do official_set["$f"]=1; done
for f in "${built_files[@]}"; do built_set["$f"]=1; done

all_files=($(printf '%s\n' "${official_files[@]}" "${built_files[@]}" | sort -u))

for fname in "${all_files[@]}"; do
  off_f="${official_lib}/${fname}"
  blt_f="${built_lib}/${fname}"
  if [[ -z "${official_set[$fname]+x}" ]]; then
    extra_in_built+=("${fname}")
    echo "EXTRA_IN_BUILT: ${fname}" >> "${diff_output_file}"
    total_diff_count=$((total_diff_count + 1))
    continue
  fi
  if [[ -z "${built_set[$fname]+x}" ]]; then
    missing_from_built+=("${fname}")
    echo "MISSING_FROM_BUILT: ${fname}" >> "${diff_output_file}"
    total_diff_count=$((total_diff_count + 1))
    continue
  fi
  off_hash=$(sha256sum "${off_f}" | awk '{print $1}')
  blt_hash=$(sha256sum "${blt_f}" | awk '{print $1}')
  if [[ "${off_hash}" == "${blt_hash}" ]]; then
    matching_files+=("${fname}")
    echo "MATCH: ${fname}  ${off_hash}" >> "${diff_output_file}"
  else
    differing_files+=("${fname}")
    echo "DIFF:  ${fname}" >> "${diff_output_file}"
    echo "       official: ${off_hash}" >> "${diff_output_file}"
    echo "       built:    ${blt_hash}" >> "${diff_output_file}"
    total_diff_count=$((total_diff_count + 1))
  fi
done

also_compare_runner=false
off_runner="${squashfs_dir}/stack_wallet"
blt_runner="${output_dir}/bundle/stack_wallet"
if [[ -f "${off_runner}" && -f "${blt_runner}" ]]; then
  also_compare_runner=true
  off_run_hash=$(sha256sum "${off_runner}" | awk '{print $1}')
  blt_run_hash=$(sha256sum "${blt_runner}" | awk '{print $1}')
  if [[ "${off_run_hash}" == "${blt_run_hash}" ]]; then
    matching_files+=("stack_wallet (runner)")
    echo "MATCH: stack_wallet  ${off_run_hash}" >> "${diff_output_file}"
  else
    differing_files+=("stack_wallet (runner)")
    echo "DIFF:  stack_wallet" >> "${diff_output_file}"
    total_diff_count=$((total_diff_count + 1))
  fi
fi

# ------------------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------------------
if [[ "${total_diff_count}" -eq 0 ]]; then
  yaml_status="reproducible"
else
  yaml_status="not_reproducible"
fi

match_count="${#matching_files[@]}"
diff_count="${#differing_files[@]}"
extra_count="${#extra_in_built[@]}"
missing_count="${#missing_from_built[@]}"

NOTES="Stack Wallet Desktop ${version_name} (tag ${git_tag}) — x86_64 Linux AppImage.
AppImage SHA256: ${appimage_sha256}
Toolchain: Flutter 3.38.1 / Dart 3.10.0, Rust 1.89.0+1.85.1+1.71.0, Go 1.24.4,
meson 0.64.1. Comparison: file-by-file SHA256 of bundle lib/ contents.

Results: ${match_count} match, ${diff_count} differ, ${extra_count} extra-in-built, ${missing_count} missing-from-built."

if [[ "${match_count}" -gt 0 ]]; then
  NOTES+="
Matching files (${match_count}): $(IFS=', '; echo "${matching_files[*]}")"
fi
if [[ "${diff_count}" -gt 0 ]]; then
  NOTES+="
Differing files (${diff_count}): $(IFS=', '; echo "${differing_files[*]}")
Note: libapp.so expected to differ (API keys compiled in; stubs used here).
Note: C/C++/Rust/Go libs differ without SOURCE_DATE_EPOCH or deterministic flags."
fi
if [[ "${extra_count}" -gt 0 ]]; then
  NOTES+="
Extra in built bundle (${extra_count}): $(IFS=', '; echo "${extra_in_built[*]}")
Note: frostdart.so present in local build but absent from official AppImage.
Requires Cypherstack clarification (see github.com/cypherstack/stack_wallet/issues/1399)."
fi
if [[ "${missing_count}" -gt 0 ]]; then
  NOTES+="
Missing from built (${missing_count}): $(IFS=', '; echo "${missing_from_built[*]}")"
fi
[[ -n "${additional_info}" ]] && NOTES+="
${additional_info}"

write_yaml "${yaml_status}" "${NOTES}"
log_info "COMPARISON_RESULTS.yaml written."

# ------------------------------------------------------------------------------
# Results block
# ------------------------------------------------------------------------------
echo ""
echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "version:        ${version_name}"
echo "gitTag:         ${git_tag}"
echo "appImageSHA256: ${appimage_sha256}"
echo "verdict:        ${yaml_status}"
echo ""
echo "lib/ comparison:"
echo "  Matching:         ${match_count}"
echo "  Differing:        ${diff_count}"
echo "  Extra in built:   ${extra_count}"
echo "  Missing from built: ${missing_count}"
if [[ "${match_count}" -gt 0 ]]; then
  echo ""
  echo "Matching files:"
  for f in "${matching_files[@]}"; do echo "  ${f}"; done
fi
if [[ "${diff_count}" -gt 0 ]]; then
  echo ""
  echo "Differing files:"
  for f in "${differing_files[@]}"; do echo "  ${f}"; done
fi
if [[ "${extra_count}" -gt 0 ]]; then
  echo ""
  echo "Extra in built (not in official AppImage):"
  for f in "${extra_in_built[@]}"; do echo "  ${f}"; done
fi
if [[ "${missing_count}" -gt 0 ]]; then
  echo ""
  echo "Missing from built:"
  for f in "${missing_from_built[@]}"; do echo "  ${f}"; done
fi
echo ""
echo "Full diff log: ${diff_output_file}"
if [[ "${should_cleanup}" != "true" ]]; then
  echo "Bundle (official): ${squashfs_dir}/lib/"
  echo "Bundle (built):    ${built_lib}/"
fi
echo "===== End Results ====="

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
if [[ "${should_cleanup}" == "true" ]]; then
  log_info "Cleaning up: ${work_dir}"
  rm -rf "${work_dir}"
fi

if [[ "${total_diff_count}" -eq 0 ]]; then
  echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}"
else
  echo "Exit code: ${EXIT_FAILED}"; exit "${EXIT_FAILED}"
fi
