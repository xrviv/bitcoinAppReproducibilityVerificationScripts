#!/bin/bash
# ==============================================================================
# zeus_build.sh - Zeus Lightning Wallet Reproducible Build Verification
# ==============================================================================
# Version:       v0.2.13
# Organization:  WalletScrutiny.com
# Last Modified: 2026-03-12
# Project:       https://github.com/ZeusLN/zeus
# ==============================================================================
# LICENSE: MIT License
#
# IMPORTANT: Changelog maintained separately at:
# ~/work/ws-notes/script-notes/android/app.zeusln.zeus/changelog.md
# ==============================================================================
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and APK comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# - Accepts official Zeus APK via --apk or auto-downloads from GitHub releases
# - Clones Zeus repository inside a container (no host git dependency)
# - Builds using Zeus' official build.sh (Docker)
# - Compares built APK against official release using unzip-based binary analysis and manifest/resource summaries
# - Treats Google Play distribution artifacts (GOOGPLAY.* / stamp-cert-sha256 / derived.apk.id) as acceptable by default
# - Supports multiple architectures (universal, arm64-v8a, armeabi-v7a, x86, x86_64)
# - Generates COMPARISON_RESULTS.yaml and standardized verification summary output

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="v0.2.13"
APP_ID="app.zeusln.zeus"
REPO_URL="https://github.com/ZeusLN/zeus.git"
WS_CONTAINER="docker.io/walletscrutiny/android:5"

# Zeus' official pinned Docker image for builds
ZEUS_DOCKER_IMAGE="docker.io/reactnativecommunity/react-native-android@sha256:c390bfb35a15ffdf52538bdd0e6c5a926469cefa8c8c6da54bfd501c122de25d"

EXIT_SUCCESS=0
EXIT_FAILED=1
EXIT_INVALID=2

execution_dir="$(pwd)"
script_name="$(basename "$0")"

should_cleanup=false
downloaded_apk=""
requested_version=""
requested_arch=""
requested_type=""
requested_tag=""

build_arch="universal"
version_name=""
version_code=""
app_hash=""
signer=""
commit_hash=""
additional_info=""

# Play artifact acceptance tracking
manifest_play_only="false"
res_diff_count=0
play_artifacts_present="false"
stamp_official_state="absent"
stamp_built_state="absent"

download_dir=""
work_dir=""

# ------------------------------------------------------------------------------
# Logging helpers (plain text; no ANSI in results)
# ------------------------------------------------------------------------------
log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARNING] $*"
}

log_error() {
  echo "[ERROR] $*"
}

append_additional_info() {
  local line="$1"
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n${line}"
  else
    additional_info="${line}"
  fi
}

die_invalid() {
  log_error "$*"
  echo "Exit code: ${EXIT_INVALID}"
  exit "${EXIT_INVALID}"
}

die_failed() {
  log_error "$*"
  generate_error_yaml "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}

on_error() {
  local exit_code=$?
  local line_no=$1
  set +e
  log_error "Script failed at line ${line_no} (exit code ${exit_code})"
  generate_error_yaml "ftbfs"
  echo "Exit code: ${EXIT_FAILED}"
  exit "${EXIT_FAILED}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Container runtime detection
# ------------------------------------------------------------------------------
CONTAINER_CMD=""
VOLUME_RO_SUFFIX=""
VOLUME_RW_SUFFIX=""
CONTAINER_RUN_USER_ARGS=""

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  VOLUME_RO_SUFFIX=":ro,Z"
  VOLUME_RW_SUFFIX=":Z"
  CONTAINER_RUN_USER_ARGS="--userns=keep-id"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  VOLUME_RO_SUFFIX=":ro"
  VOLUME_RW_SUFFIX=""
  CONTAINER_RUN_USER_ARGS="--user $(id -u):$(id -g)"
else
  die_failed "Neither podman nor docker is available. Install one to continue."
fi

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
NAME
       zeus_build.sh - Zeus Lightning Wallet reproducible build verification

SYNOPSIS
       ${script_name} --version <version> [OPTIONS]
       ${script_name} --apk <apk_file> --version <version> [OPTIONS]
       ${script_name} --help

DESCRIPTION
       Builds Zeus Lightning Wallet from source in a container and compares
       the built APK to an official APK. The official APK can be downloaded
       automatically by version or provided via --apk.

OPTIONS
       --version <version>     Version to verify (required)
                               Examples: 0.11.6, 0.12.0-alpha1
       --apk <file>            Path to local APK file (deprecated; use --binary)
       --binary <file>         Path to local APK file (optional; auto-downloads
                               from GitHub releases if not provided).
                               When provided, arch is auto-detected from APK.
       --arch <arch>           Architecture to build (default: universal).
                               Overrides auto-detection when --apk is provided.
                               Supported: universal, arm64-v8a, armeabi-v7a,
                               x86, x86_64
       --tag <ref>             Git tag or branch to clone (default: v<version>).
                               Use when the Play Store release has no matching tag.
                               Example: --tag v0.12.4-branch
       --type <type>           Build type (accepted for build server compatibility)
       --cleanup               Remove temporary files after completion
       --script-version        Print script version and exit
       --help                  Show this help and exit

EXIT CODES
       0    Reproducible (only META-INF signature differences)
       1    Differences found or build failure
       2    Invalid parameters or configuration

EXAMPLES
       ${script_name} --version 0.11.6
       ${script_name} --version 0.11.6 --arch arm64-v8a
       ${script_name} --version 0.11.6 --apk ~/Downloads/zeus-v0.11.6-universal.apk
       ${script_name} --version 0.12.4 --apk ~/Downloads/zeus.apk --tag v0.12.4-branch
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) requested_version="$2"; shift ;;
    --apk) downloaded_apk="$2"; shift ;;
    --binary) downloaded_apk="$2"; shift ;;
    --arch) requested_arch="$2"; shift ;;
    --type) requested_type="$2"; shift ;;
    --tag) requested_tag="$2"; shift ;;
    --cleanup) should_cleanup=true ;;
    --script-version) echo "${script_name} ${SCRIPT_VERSION}"; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    --help) usage; echo "Exit code: ${EXIT_SUCCESS}"; exit "${EXIT_SUCCESS}" ;;
    *) log_warn "Ignoring unknown argument: $1" ;;
  esac
  shift
done

if [[ -z "${requested_version}" && -z "${downloaded_apk}" ]]; then
  die_invalid "You must provide --version (or --binary to auto-detect version from APK)."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  die_invalid "Do not run this script as root."
fi

# Validate architecture
if [[ -n "${requested_arch}" ]]; then
  case "${requested_arch}" in
    universal|arm64-v8a|armeabi-v7a|x86|x86_64) ;;
    *) die_invalid "Unsupported --arch '${requested_arch}'. Supported: universal, arm64-v8a, armeabi-v7a, x86, x86_64." ;;
  esac
  build_arch="${requested_arch}"
fi

if [[ -n "${requested_type}" ]]; then
  if [[ -n "${additional_info}" ]]; then
    additional_info="${additional_info}\n"
  fi
  additional_info="${additional_info}Build type '${requested_type}' accepted for compatibility; Zeus has a single build type."
fi

version_name="${requested_version}"

# ------------------------------------------------------------------------------
# Helper functions (containerized)
# ------------------------------------------------------------------------------
container_sha256() {
  local file_path="$1"
  local file_dir file_name
  file_dir="$(dirname "$file_path")"
  file_name="$(basename "$file_path")"
  $CONTAINER_CMD run --rm \
    --volume "${file_dir}:/data${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "sha256sum /data/${file_name} | awk '{print \$1}'"
}

container_signer() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "apksigner verify --print-certs /apk/${apk_name} | grep 'Signer #1 certificate SHA-256' | awk '{print \$6}'"
}

container_aapt_arches() {
  local apk_path="$1"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c '
      arches=$(aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null | awk -F"'"'"'" "/native-code/ {for (i=2; i<=NF; i+=2) print \$i}")
      if [ -n "$arches" ]; then
        echo "$arches"
      else
        unzip -l "/apk/'"${apk_name}"'" 2>/dev/null | grep -oE "lib/(arm64-v8a|armeabi-v7a|x86_64|x86)/" | sed "s|lib/||;s|/||" | sort -u
      fi
    '
}

container_aapt_version() {
  local apk_path="$1"
  local field="$2"
  local apk_dir apk_name
  apk_dir="$(dirname "$apk_path")"
  apk_name="$(basename "$apk_path")"
  $CONTAINER_CMD run --rm \
    --volume "${apk_dir}:/apk${VOLUME_RO_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c '
      badging_output="$({ aapt dump badging "/apk/'"${apk_name}"'" 2>/dev/null || aapt2 dump badging "/apk/'"${apk_name}"'" 2>/dev/null; } || true)"
      if [ -n "$badging_output" ]; then
        printf "%s\n" "$badging_output" | sed -n "s/.*'"${field}"'='\''\([^'\'']*\)'\''.*/\1/p" | head -n1
        exit 0
      fi

      tmpdir=$(mktemp -d)
      if apktool d -f -s -o "$tmpdir/out" "/apk/'"${apk_name}"'" >/dev/null 2>&1; then
        case "'"${field}"'" in
          versionName)
            sed -n "s/^[[:space:]]*versionName:[[:space:]]*//p" "$tmpdir/out/apktool.yml" | head -n1
            ;;
          versionCode)
            sed -n "s/^[[:space:]]*versionCode:[[:space:]]*'\''\([^'\'']*\)'\''/\1/p" "$tmpdir/out/apktool.yml" | head -n1
            ;;
        esac
      fi
      rm -rf "$tmpdir"
    '
}

download_apk_from_url() {
  local url="$1"
  local output_file="$2"
  local output_dir
  output_dir="$(dirname "$output_file")"

  mkdir -p "$output_dir"
  $CONTAINER_CMD run --rm \
    --volume "${output_dir}:/download${VOLUME_RW_SUFFIX}" \
    "$WS_CONTAINER" \
    sh -c "curl -L -f -o /download/$(basename "$output_file") '${url}'"
}

git_in_container() {
  local cmd="$1"
  $CONTAINER_CMD run --rm \
    --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
    --workdir /workspace/app \
    "$WS_CONTAINER" \
    sh -c "${cmd}"
}

generate_error_yaml() {
  local status="$1"
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  cat > "$yaml_file" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
EOF
}

generate_comparison_yaml() {
  local yaml_file="${execution_dir}/COMPARISON_RESULTS.yaml"
  cat > "${yaml_file}" <<EOF
script_version: ${SCRIPT_VERSION}
verdict: ${yaml_status}
notes: |
  Uses Zeus upstream build.sh for reproducible builds.
  Expected differences (do not affect reproducibility verdict):
  - META-INF/*: Google Play signing files
  - stamp-cert-sha256: Certificate stamp from Google Play
  - AndroidManifest.xml: Modified by Google Play signing process
  - index.android.bundle: React Native Metro bundler non-determinism
EOF
}


generate_diff_summary() {
  local summary_dir="${work_dir}/summary"
  local official_dir="${summary_dir}/official"
  local built_dir="${summary_dir}/built"

  rm -rf "${summary_dir}"
  mkdir -p "${summary_dir}"

  if ! ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    --volume "${summary_dir}:/summary${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apktool d -f -o /summary/official /apk/$(basename "${downloaded_apk}")"; then
    append_additional_info "Diff summary: apktool decode failed for official APK."
    return 0
  fi

  if ! ${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${built_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    --volume "${summary_dir}:/summary${VOLUME_RW_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "apktool d -f -o /summary/built /apk/$(basename "${built_apk}")"; then
    append_additional_info "Diff summary: apktool decode failed for built APK."
    return 0
  fi

  local manifest_diff res_diff
  local manifest_lines=0
  local res_lines=0
  local manifest_snip res_snip
  local manifest_changes

  manifest_diff="$(diff -u "${official_dir}/AndroidManifest.xml" "${built_dir}/AndroidManifest.xml" || true)"
  manifest_changes="$(echo "${manifest_diff}" | grep -E '^[+-]' | grep -vE '^\+\+\+|^---|^@@' || true)"
  if [[ -z "${manifest_changes}" ]]; then
    manifest_play_only="true"
  elif echo "${manifest_changes}" | grep -v "com.android.vending.derived.apk.id" >/dev/null 2>&1; then
    manifest_play_only="false"
  else
    manifest_play_only="true"
  fi
  if [[ -n "${manifest_changes}" ]]; then
    manifest_lines="$(echo "${manifest_changes}" | wc -l | tr -d ' ')"
  fi

  append_additional_info "Manifest diff lines: ${manifest_lines}"
  if [[ -n "${manifest_diff}" ]]; then
    manifest_snip="$(echo "${manifest_diff}" | grep -E '^[+-]' | grep -vE '^\+\+\+|^---|^@@' | head -n 3)"
    if [[ -n "${manifest_snip}" ]]; then
      append_additional_info "Manifest diff sample:"
      append_additional_info "${manifest_snip}"
    fi
  fi

  res_diff="$(diff -r "${official_dir}/res" "${built_dir}/res" || true)"
  if [[ -n "${res_diff}" ]]; then
    res_lines="$(echo "${res_diff}" | wc -l | tr -d ' ')"
  fi

  res_diff_count=${res_lines}
  append_additional_info "Resource diffs (res/): ${res_lines}"
  if [[ -n "${res_diff}" ]]; then
    res_snip="$(echo "${res_diff}" | head -n 3)"
    append_additional_info "Resource diff sample:"
    append_additional_info "${res_snip}"
  fi

  local stamp_official=""
  local stamp_built=""
  stamp_official_state="absent"
  stamp_built_state="absent"

  stamp_official="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "zipinfo -1 /apk/$(basename "${downloaded_apk}") | grep -E '^stamp-cert-sha256$' || true")"

  stamp_built="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${built_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "zipinfo -1 /apk/$(basename "${built_apk}") | grep -E '^stamp-cert-sha256$' || true")"

  if [[ -n "${stamp_official}" ]]; then
    stamp_official_state="present"
  fi
  if [[ -n "${stamp_built}" ]]; then
    stamp_built_state="present"
  fi

  append_additional_info "stamp-cert-sha256: official ${stamp_official_state}, built ${stamp_built_state}"

  if [[ "${stamp_official_state}" == "present" ]]; then
    local stamp_hex_lines stamp_b64 stamp_len
    stamp_len="$(${CONTAINER_CMD} run --rm \
      --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
      "${WS_CONTAINER}" \
      sh -c "unzip -p /apk/$(basename "${downloaded_apk}") stamp-cert-sha256 2>/dev/null | wc -c | tr -d ' '")"

    stamp_hex_lines="$(${CONTAINER_CMD} run --rm \
      --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
      "${WS_CONTAINER}" \
      sh -c "unzip -p /apk/$(basename "${downloaded_apk}") stamp-cert-sha256 2>/dev/null | od -An -tx1 -w16 -v | head -n 5")"

    stamp_b64="$(${CONTAINER_CMD} run --rm \
      --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
      "${WS_CONTAINER}" \
      sh -c "unzip -p /apk/$(basename "${downloaded_apk}") stamp-cert-sha256 2>/dev/null | base64 -w 64 | head -n 1")"

    append_additional_info "stamp-cert-sha256 bytes: ${stamp_len}"
    if [[ -n "${stamp_hex_lines}" ]]; then
      append_additional_info "stamp-cert-sha256 hex (up to 5 lines):"
      while IFS= read -r line; do
        append_additional_info "${line}"
      done <<< "${stamp_hex_lines}"
    fi
    if [[ -n "${stamp_b64}" ]]; then
      append_additional_info "stamp-cert-sha256 base64 (first line): ${stamp_b64}"
    fi
  fi

  local play_sig=""
  play_sig="$(${CONTAINER_CMD} run --rm \
    --volume "$(dirname "${downloaded_apk}"):/apk${VOLUME_RO_SUFFIX}" \
    "${WS_CONTAINER}" \
    sh -c "zipinfo -1 /apk/$(basename "${downloaded_apk}") | grep -E '^META-INF/GOOGPLAY\\.' || true")"

  if [[ -n "${play_sig}" || "${stamp_official_state}" == "present" ]]; then
    play_artifacts_present="true"
    append_additional_info "Note: Google Play distribution artifacts detected (GOOGPLAY.* / stamp-cert-sha256)."
  else
    play_artifacts_present="false"
  fi
}


# ------------------------------------------------------------------------------
# Input preparation
# ------------------------------------------------------------------------------

# Derive architecture from Zeus versionCode last digit
# Zeus encodes: 1=armeabi-v7a, 2=x86, 3=arm64-v8a, 4=x86_64
# Universal APKs have short versionCodes (no arch suffix)
arch_from_versioncode() {
  local vc="$1"
  if [[ -z "${vc}" || "${vc}" == "unknown" ]]; then
    echo ""
    return
  fi
  local last_digit=$(( vc % 10 ))
  case "${last_digit}" in
    1) echo "armeabi-v7a" ;;
    2) echo "x86" ;;
    3) echo "arm64-v8a" ;;
    4) echo "x86_64" ;;
    *) echo "" ;;
  esac
}

if [[ -n "${downloaded_apk}" ]]; then
  # --------------------------------------------------------------------------
  # Path A: --apk provided — let the APK drive the arch
  # --------------------------------------------------------------------------
  if [[ "${downloaded_apk}" != /* ]]; then
    downloaded_apk="${execution_dir}/${downloaded_apk}"
  fi
  if [[ ! -f "${downloaded_apk}" ]]; then
    die_invalid "APK file not found: ${downloaded_apk}"
  fi

  app_hash="$(container_sha256 "${downloaded_apk}")"
  signer="$(container_signer "${downloaded_apk}" || echo "unknown")"
  version_name_from_apk="$(container_aapt_version "${downloaded_apk}" "versionName")"
  version_code="$(container_aapt_version "${downloaded_apk}" "versionCode")"

  if [[ -z "${version_name_from_apk}" ]]; then
    version_name_from_apk="${version_name}"
  fi
  if [[ -z "${version_code}" ]]; then
    version_code="unknown"
  fi

  if [[ -n "${requested_version}" && -n "${version_name_from_apk}" && "${requested_version}" != "${version_name_from_apk}" ]]; then
    if [[ -n "${additional_info}" ]]; then
      additional_info="${additional_info}\n"
    fi
    additional_info="${additional_info}Requested version ${requested_version} but APK reports ${version_name_from_apk}."
  fi

  # Derive version_name from APK if --version was not provided
  if [[ -z "${version_name}" ]]; then
    if [[ -n "${version_name_from_apk}" ]]; then
      version_name="${version_name_from_apk}"
      log_info "Version derived from APK: ${version_name}"
    else
      die_invalid "Could not determine version from APK. Provide --version explicitly."
    fi
  fi

  # Determine arch: --arch flag > versionCode > aapt native-code > default
  if [[ -z "${requested_arch}" ]]; then
    # Try versionCode-based detection first (Zeus-specific encoding)
    detected_arch="$(arch_from_versioncode "${version_code}")"

    if [[ -z "${detected_arch}" ]]; then
      # Fallback: check native-code ABIs in the APK
      mapfile -t apk_arches < <(container_aapt_arches "${downloaded_apk}" || true)
      if [[ "${#apk_arches[@]}" -eq 1 && -n "${apk_arches[0]}" ]]; then
        detected_arch="${apk_arches[0]}"
      elif [[ "${#apk_arches[@]}" -gt 1 ]]; then
        detected_arch="universal"
      fi
    fi

    if [[ -n "${detected_arch}" ]]; then
      build_arch="${detected_arch}"
      log_info "Detected architecture from APK: ${build_arch}"
    else
      log_warn "Could not detect architecture from APK. Defaulting to: ${build_arch}"
    fi
  fi

else
  # --------------------------------------------------------------------------
  # Path B: no --apk — download from GitHub releases using --version/--arch
  # --------------------------------------------------------------------------
  download_dir="${execution_dir}/official_apk_${version_name}_${build_arch}"
  downloaded_apk="${download_dir}/zeus-v${version_name}-${build_arch}.apk"

  download_url="https://github.com/ZeusLN/zeus/releases/download/v${version_name}/zeus-v${version_name}-${build_arch}.apk"
  log_info "Downloading official APK from GitHub releases..."
  log_info "URL: ${download_url}"
  if ! download_apk_from_url "${download_url}" "${downloaded_apk}"; then
    die_failed "Failed to download official APK from GitHub releases: ${download_url}"
  fi
  log_info "Downloaded APK to: ${downloaded_apk}"

  app_hash="$(container_sha256 "${downloaded_apk}")"
  signer="$(container_signer "${downloaded_apk}" || echo "unknown")"
  version_name_from_apk="$(container_aapt_version "${downloaded_apk}" "versionName")"
  version_code="$(container_aapt_version "${downloaded_apk}" "versionCode")"

  if [[ -z "${version_name_from_apk}" ]]; then
    version_name_from_apk="${version_name}"
  fi
  if [[ -z "${version_code}" ]]; then
    version_code="unknown"
  fi
fi

# Resolve git_ref now that version_name is known
if [[ -n "${requested_tag}" ]]; then
  log_info "Using git ref override: ${requested_tag} (instead of default v${version_name})"
  append_additional_info "Git ref override: --tag ${requested_tag} used instead of default v${version_name}."
fi
git_ref="${requested_tag:-v${version_name}}"

# ------------------------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------------------------
work_dir="${execution_dir}/workdir_${APP_ID}_${version_name}_${build_arch}"
if [[ -d "${work_dir}" ]]; then
  log_info "Removing existing workspace: ${work_dir}"
  rm -rf "${work_dir}"
fi

mkdir -p "${work_dir}"

# ------------------------------------------------------------------------------
# Source preparation (containerized git clone)
# ------------------------------------------------------------------------------
log_info "Cloning Zeus repository in container..."
$CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "git clone --depth 1 --branch '${git_ref}' '${REPO_URL}' app"

commit_hash="$(git_in_container "git rev-parse HEAD")"
log_info "Checked out ${git_ref} at commit ${commit_hash}"

# ------------------------------------------------------------------------------
# Build
# ------------------------------------------------------------------------------
log_info "Building Zeus APK using upstream build.sh..."
log_info "Build script: ${work_dir}/app/build.sh"
log_info "This may take 10-30 minutes depending on your system..."

# Zeus' build.sh expects Docker — create a shim for podman environments
docker_shim_dir=""
if [[ "${CONTAINER_CMD}" == "podman" ]] && ! command -v docker >/dev/null 2>&1; then
  docker_shim_dir="${work_dir}/docker-shim"
  mkdir -p "${docker_shim_dir}"
  cat > "${docker_shim_dir}/docker" <<'EOS'
#!/bin/sh
set -eu
IMAGE="docker.io/reactnativecommunity/react-native-android@sha256:c390bfb35a15ffdf52538bdd0e6c5a926469cefa8c8c6da54bfd501c122de25d"
case "${1:-}" in
  run)
    shift
    podman run "$@"
    ;;
  pull)
    shift
    podman pull "$IMAGE"
    ;;
  *)
    podman "$@"
    ;;
esac
EOS
  chmod +x "${docker_shim_dir}/docker"
  export PATH="${docker_shim_dir}:$PATH"
  log_info "Using podman docker shim for build compatibility"
fi

if [[ ! -f "${work_dir}/app/build.sh" ]]; then
  die_failed "build.sh not found in ${work_dir}/app"
fi

build_script_run="${work_dir}/app/build.ws.sh"
cp "${work_dir}/app/build.sh" "${build_script_run}"
chmod +x "${build_script_run}"

build_script_container_name="zeus_builder_container_${version_name}_${build_arch}_$$"
if grep -q '^[[:space:]]*CONTAINER_NAME=' "${build_script_run}"; then
  sed -i "s|^[[:space:]]*CONTAINER_NAME=.*|CONTAINER_NAME=\"${build_script_container_name}\"|" "${build_script_run}"
else
  echo "CONTAINER_NAME=\"${build_script_container_name}\"" >> "${build_script_run}"
fi
log_info "Using build.sh container name: ${build_script_container_name}"

if grep -q "docker run --rm" "${build_script_run}"; then
  sed -i "s/docker run --rm/docker run --rm --user $(id -u):$(id -g)/" "${build_script_run}"
  log_info "Patched build.sh to run Docker as user $(id -u):$(id -g)"

  user_spec="$(id -u):$(id -g)"
  if grep -q "docker run --rm --user ${user_spec}" "${build_script_run}" && ! grep -q "ANDROID_SDK_HOME" "${build_script_run}"; then
    sed -i "s/docker run --rm --user ${user_spec}/docker run --rm --user ${user_spec} -e HOME=\/tmp -e ANDROID_SDK_HOME=\/tmp -e ANDROID_PREFS_ROOT=\/tmp -e GRADLE_USER_HOME=\/tmp\/\.gradle/" "${build_script_run}"
    log_info "Patched build.sh to set HOME/ANDROID_SDK_HOME/ANDROID_PREFS_ROOT/GRADLE_USER_HOME"
  fi
fi

if ! (cd "${work_dir}/app" && bash "${build_script_run}" --no-tty); then
  die_failed "Zeus upstream build.sh failed"
fi

# Find built APK
built_apk_name="zeus-${build_arch}.apk"
built_apk="${work_dir}/app/android/app/build/outputs/apk/release/${built_apk_name}"

if [[ ! -f "${built_apk}" ]]; then
  log_warn "Expected APK not found at: ${built_apk}"
  log_info "Searching for built APKs..."
  found_apk="$(find "${work_dir}/app" -type f -name "zeus-${build_arch}.apk" -print -quit 2>/dev/null || true)"
  if [[ -n "${found_apk}" && -f "${found_apk}" ]]; then
    built_apk="${found_apk}"
    log_info "Found APK at: ${built_apk}"
  else
    die_failed "Built APK not found: ${built_apk_name}"
  fi
fi

log_info "APK built successfully: ${built_apk}"

# ------------------------------------------------------------------------------
# Comparison
# ------------------------------------------------------------------------------
from_play_unzipped="${work_dir}/fromPlay_${APP_ID}_${version_code}"
from_build_unzipped="${work_dir}/fromBuild_${APP_ID}_${version_code}"
rm -rf "${from_play_unzipped}" "${from_build_unzipped}"
mkdir -p "${from_play_unzipped}" "${from_build_unzipped}"

log_info "Unzipping APKs for comparison..."
$CONTAINER_CMD run --rm \
  --volume "$(dirname "${downloaded_apk}"):/official${VOLUME_RO_SUFFIX}" \
  --volume "${from_play_unzipped}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "unzip -qq /official/$(basename "${downloaded_apk}") -d /output"

$CONTAINER_CMD run --rm \
  --volume "$(dirname "${built_apk}"):/built${VOLUME_RO_SUFFIX}" \
  --volume "${from_build_unzipped}:/output${VOLUME_RW_SUFFIX}" \
  "$WS_CONTAINER" \
  sh -c "unzip -qq /built/$(basename "${built_apk}") -d /output"

log_info "Diffing extracted APKs..."
diff_brief="$($CONTAINER_CMD run --rm \
  --volume "${work_dir}:/workspace${VOLUME_RW_SUFFIX}" \
  --workdir /workspace \
  "$WS_CONTAINER" \
  sh -c "diff -qr '$(basename "${from_play_unzipped}")' '$(basename "${from_build_unzipped}")' || true")"

# Filter META-INF differences (Leo's regex)
filtered_diff="$(echo "${diff_brief}" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)"
filtered_diff_compact="$(echo "${filtered_diff}" | tr -d '\n\r')"
if [[ -z "${diff_brief}" || -z "${filtered_diff_compact}" ]]; then
  diff_count=0
else
  diff_count="$(echo "${filtered_diff}" | grep -c '^' || true)"
fi

diff_display="$(echo "${diff_brief}" | sed "s|$(basename "${from_play_unzipped}")|${from_play_unzipped}|g; s|$(basename "${from_build_unzipped}")|${from_build_unzipped}|g")"

generate_diff_summary

play_accept=false
if [[ "${play_artifacts_present}" == "true" && "${manifest_play_only}" == "true" && "${res_diff_count}" -eq 0 ]]; then
  allowed_play=true
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if echo "${line}" | grep -q "AndroidManifest.xml"; then
      continue
    fi
    if echo "${line}" | grep -q "stamp-cert-sha256"; then
      continue
    fi
    allowed_play=false
    break
  done <<< "${filtered_diff}"
  if [[ "${allowed_play}" == "true" ]]; then
    play_accept=true
  fi
fi

verdict=""
yaml_status="not_reproducible"
match_value="false"
exit_code="${EXIT_FAILED}"

if [[ "${diff_count}" -eq 0 ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
elif [[ "${play_accept}" == "true" ]]; then
  verdict="reproducible"
  yaml_status="reproducible"
  match_value="true"
  exit_code="${EXIT_SUCCESS}"
  append_additional_info "Play-only diffs accepted by default; verdict set to reproducible."
else
  verdict="differences found"
fi

built_hash="$(container_sha256 "${built_apk}")"

# ------------------------------------------------------------------------------
# Results files
# ------------------------------------------------------------------------------
generate_comparison_yaml

# ------------------------------------------------------------------------------
# Git signature verification (containerized)
# ------------------------------------------------------------------------------
tag_type="commit-only"
tag_signature_status="[INFO] No tag found"
commit_signature_status="[WARNING] No valid signature found on commit"
signature_keys=""
signature_warnings=""
tag_ref="${git_ref}"

if git_in_container "git rev-parse --verify 'refs/tags/${tag_ref}' >/dev/null 2>&1"; then
  if git_in_container "test \"\$(git cat-file -t 'refs/tags/${tag_ref}')\" = 'tag'"; then
    tag_type="annotated"
    tag_output="$(git_in_container "git tag -v '${tag_ref}' 2>&1 || true")"
    if echo "${tag_output}" | grep -q "Good signature"; then
      tag_signature_status="[OK] Good signature on annotated tag"
      tag_key="$(echo "${tag_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
      if [[ -n "${tag_key}" ]]; then
        signature_keys="Tag signed with: ${tag_key}"
      fi
    else
      tag_signature_status="[WARNING] No valid signature found on annotated tag"
      signature_warnings="${signature_warnings}\n- Annotated tag exists but is not signed"
    fi
  else
    tag_type="lightweight"
    tag_signature_status="[INFO] Tag is lightweight (cannot contain signature)"
  fi
fi

commit_output="$(git_in_container "git verify-commit '${commit_hash}' 2>&1 || true")"
if echo "${commit_output}" | grep -q "Good signature"; then
  commit_signature_status="[OK] Good signature on commit"
  commit_key="$(echo "${commit_output}" | grep 'using .* key' | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)"
  if [[ -n "${commit_key}" ]]; then
    if [[ -n "${signature_keys}" ]]; then
      signature_keys="${signature_keys}\nCommit signed with: ${commit_key}"
    else
      signature_keys="Commit signed with: ${commit_key}"
    fi
  fi
else
  commit_signature_status="[WARNING] No valid signature found on commit"
  if [[ -z "${signature_warnings}" ]]; then
    signature_warnings="- Commit is not signed"
  else
    signature_warnings="${signature_warnings}\n- Commit is not signed"
  fi
fi

# ------------------------------------------------------------------------------
# Standardized verification output
# ------------------------------------------------------------------------------
diff_guide="
Run a full
diff --recursive ${from_play_unzipped} ${from_build_unzipped}
meld ${from_play_unzipped} ${from_build_unzipped}
or
diffoscope \"${downloaded_apk}\" ${built_apk}
for more details."

if [[ "${should_cleanup}" == true ]]; then
  diff_guide=""
fi

echo "===== Begin Results ====="
echo "appId:          ${APP_ID}"
echo "signer:         ${signer}"
echo "apkVersionName: ${version_name_from_apk}"
echo "apkVersionCode: ${version_code}"
echo "verdict:        ${verdict}"
echo "appHash:        ${app_hash}"
echo "commit:         ${commit_hash}"
echo ""
echo "Diff:"
echo "${diff_display}"
echo ""
echo "Revision, tag (and its signature):"

if git_in_container "git rev-parse --verify 'refs/tags/${tag_ref}' >/dev/null 2>&1"; then
  if [[ "${tag_type}" == "annotated" ]]; then
    echo "${tag_output}"
  else
    echo "Tag: ${tag_ref} (lightweight, no signature possible)"
  fi
else
  echo "No tag (build from commit ${commit_hash})"
fi

echo ""
echo "${commit_output}"

echo ""
echo "Signature Summary:"
echo "Tag type: ${tag_type}"
echo "${tag_signature_status}"
echo "${commit_signature_status}"

if [[ -n "${signature_keys}" ]]; then
  echo ""
  echo "Keys used:"
  echo -e "${signature_keys}"
fi

if [[ -n "${signature_warnings}" ]]; then
  echo ""
  echo "Warnings:${signature_warnings}"
fi

if [[ -n "${additional_info}" ]]; then
  echo ""
  echo "===== Also ====="
  echo -e "${additional_info}"
fi

echo ""
echo "===== End Results ====="
echo "${diff_guide}"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
if [[ "${should_cleanup}" == true ]]; then
  rm -rf "${work_dir}"
  if [[ -n "${download_dir}" ]]; then
    rm -rf "${download_dir}"
  fi
else
  log_info "Workspace preserved: ${work_dir}"
fi

echo "Exit code: ${exit_code}"
exit "${exit_code}"
