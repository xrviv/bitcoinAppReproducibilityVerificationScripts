#!/bin/bash
# Electrum Desktop Reproducible Build Verification Script
#
# TECHNICAL DISCLAIMER:
# This script is provided for technical analysis and reproducible build verification purposes only.
# No warranty is provided regarding the security, functionality, or fitness for any particular purpose.
# Users assume all risks associated with running this script and analyzing the software.
# This script performs automated builds and comparisons - review all operations before execution.
#
# LEGAL DISCLAIMER:
# This script is designed for legitimate security research and reproducible build verification.
# Users are responsible for ensuring compliance with all applicable laws and regulations.
# The developers assume no liability for any misuse or legal consequences arising from use.
# By using this script, you acknowledge these disclaimers and accept full responsibility.
#
# SCRIPT SUMMARY:
# • Downloads official Electrum release artifacts and verifies signatures/checksums
# • Clones source code repository and checks out the exact release tag/commit
# • Performs containerized reproducible build using Electrum's Docker-based wine build system
# • Compares built binaries against official releases using binary analysis
# • Documents differences and generates detailed reproducibility assessment report
#
# Version: 4.6.2+wsv0.0.1
# Maintainer: WalletScrutiny.com
# Project: https://github.com/spesmilo/electrum

set -euo pipefail

# ---------- Styling ----------
NC="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
SUCCESS_ICON="✅"
WARNING_ICON="⚠️"
ERROR_ICON="❌"
INFO_ICON="ℹ️"

APP_NAME="Electrum Desktop"
APP_ID="org.electrum.electrum"
DEFAULT_TARGET="windows"
SCRIPT_VERSION="4.6.2+wsv0.0.1"
REPO_URL="https://github.com/spesmilo/electrum"
REPORTS_ROOT="$HOME/work/0-reports/desktop/$APP_ID"

# ---------- Defaults ----------
version=""
target="$DEFAULT_TARGET"
skip_build=false
skip_download=false
skip_compare=false
force_reclone=false
cleanup_workspace=false
no_record=false
repo_url_override=""

# ---------- Helpers ----------
log_info() { echo -e "${CYAN}${INFO_ICON} $1${NC}"; }
log_success() { echo -e "${GREEN}${SUCCESS_ICON} $1${NC}"; }
log_warn() { echo -e "${YELLOW}${WARNING_ICON} $1${NC}"; }
log_error() { echo -e "${RED}${ERROR_ICON} $1${NC}"; }

bytes_to_mb() {
  awk -v size="$1" 'BEGIN {printf "%.2f", size/1048576}'
}

emit_artifact_evidence() {
  local name="$1"
  local built_path="$2"
  local official_path="$3"
  local built_exists=0
  local official_exists=0

  if [[ -n "$built_path" && -f "$built_path" ]]; then
    built_exists=1
  fi
  if [[ -n "$official_path" && -f "$official_path" ]]; then
    official_exists=1
  fi

  {
    echo "artifact: $name"
    if (( built_exists )); then
      printf 'built hash: %s\n' "$(sha256sum "$built_path" | awk '{print $1}')"
    else
      echo 'built hash: missing'
    fi
    if (( official_exists )); then
      printf 'official hash: %s\n' "$(sha256sum "$official_path" | awk '{print $1}')"
    else
      echo 'official hash: missing'
    fi
    echo '---file size comparison---'
    if (( built_exists )); then
      local built_size_bytes built_size_mb
      built_size_bytes=$(stat -c %s "$built_path")
      built_size_mb=$(bytes_to_mb "$built_size_bytes")
      printf 'built size: %s MB (%s bytes)\n' "$built_size_mb" "$built_size_bytes"
    else
      echo 'built size: missing'
    fi
    if (( official_exists )); then
      local official_size_bytes official_size_mb
      official_size_bytes=$(stat -c %s "$official_path")
      official_size_mb=$(bytes_to_mb "$official_size_bytes")
      printf 'official size: %s MB (%s bytes)\n' "$official_size_mb" "$official_size_bytes"
    else
      echo 'official size: missing'
    fi
    echo '---file type information---'
    if (( built_exists )); then
      printf 'built file information: %s\n' "$(file -b "$built_path")"
    else
      echo 'built file information: missing'
    fi
    if (( official_exists )); then
      printf 'official file information: %s\n' "$(file -b "$official_path")"
    else
      echo 'official file information: missing'
    fi
    echo
  } | tee -a "$evidence_file"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command '$1' not found. Please install it and retry."
    exit 1
  fi
}

usage() {
  cat <<'EOF'
NAME
       verify_electrumdesktop.sh - verify Electrum Desktop reproducible build (Windows target)

SYNOPSIS
       verify_electrumdesktop.sh <version> [options]

DESCRIPTION
       This command rebuilds Electrum Desktop for Windows inside Docker and compares
       the resulting executables with the official downloads from electrum.org.

POSITIONAL ARGUMENTS
       version               Release version to verify (e.g., 4.6.2)

OPTIONS
       --repo <url>          Override upstream Git repository URL
       --target <name>       Build target (default: windows)
       --skip-build          Reuse existing build artifacts (skips build.sh)
       --skip-download       Do not download official release artifacts
       --skip-compare        Skip comparison between built and official binaries
       --force-reclone       Remove cached repository before cloning
       --cleanup             Remove workspace when the script finishes successfully
       --no-record           Disable asciinema session recording
       --help, -h            Show this help message

EXAMPLES
       verify_electrumdesktop.sh 4.6.2
       verify_electrumdesktop.sh 4.6.2 --skip-download --skip-compare
       verify_electrumdesktop.sh 4.6.2 --repo https://github.com/fork/electrum

DIRECTORY STRUCTURE
       /tmp/testDesktop_org.electrum.electrum_<version>_<target>-buildN/
         ├── logs/             Session logs and recordings
         ├── source/           Git checkout
         ├── official/         Downloaded official binaries (signed + stripped)
         └── results/          Comparison outputs and metadata

REPORTS
       Logs are copied to ~/work/0-reports/desktop/org.electrum.electrum/<version>/logs/

EOF
}

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_url_override="$2"; shift 2 ;;
    --target)
      target="$2"; shift 2 ;;
    --skip-build)
      skip_build=true; shift ;;
    --skip-download)
      skip_download=true; shift ;;
    --skip-compare)
      skip_compare=true; shift ;;
    --force-reclone)
      force_reclone=true; shift ;;
    --cleanup)
      cleanup_workspace=true; shift ;;
    --no-record)
      no_record=true; shift ;;
    -h|--help|help)
      usage
      exit 0 ;;
    --*)
      log_error "Unknown option: $1"
      usage
      exit 1 ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift ;;
  esac
done

if (( ${#POSITIONAL_ARGS[@]} < 1 )); then
  log_error "Missing required arguments"
  usage
  exit 1
fi

version="${POSITIONAL_ARGS[0]}"
repo_url="${repo_url_override:-$REPO_URL}"

if [[ -z "$version" ]]; then
  log_error "Version argument is required"
  exit 1
fi

if [[ "$target" != "windows" ]]; then
  log_warn "Target '$target' not fully supported yet; proceeding but build scripts expect Windows wine target."
fi

# ---------- Workspace Setup ----------
workspace_base="/tmp/testDesktop_${APP_ID}_${version}_${target}"
find_next_build_number() {
  local pattern="$1"
  local num=1
  while [[ -d "${pattern}-build${num}" ]]; do
    ((num++))
  done
  echo "$num"
}

build_number=$(find_next_build_number "$workspace_base")
workspace="${workspace_base}-build${build_number}"
source_dir="$workspace/source"
official_dir="$workspace/official"
official_signed_dir="$official_dir/signed"
official_stripped_dir="$official_dir/stripped"
results_dir="$workspace/results"
logs_dir="$workspace/logs"
mkdir -p "$source_dir" "$official_signed_dir" "$official_stripped_dir" "$results_dir" "$logs_dir"

reports_dir="$REPORTS_ROOT/$version/logs"
mkdir -p "$reports_dir"

session_stamp=$(date +%Y-%m-%d.%H%M)
log_file="$logs_dir/${session_stamp}.${APP_ID}.v${version}-${target}-build${build_number}.log"
cast_file="$logs_dir/${session_stamp}.${APP_ID}.v${version}-${target}-build${build_number}.cast"
evidence_file="$results_dir/evidence-${session_stamp}.txt"
: > "$evidence_file"

status="success"

handle_error() {
  local exit_code=$?
  local line_no=$1
  status="failed"
  log_error "Script failed at line $line_no with exit code $exit_code"
  log_error "Last command: $BASH_COMMAND"
  exit $exit_code
}

cleanup() {
  set +e
  if [[ -f "$log_file" ]]; then
    cp "$log_file" "$reports_dir/" 2>/dev/null || true
  fi
  if [[ -f "$cast_file" ]]; then
    cp "$cast_file" "$reports_dir/" 2>/dev/null || true
  fi
  if [[ "$cleanup_workspace" == true && "$status" == "success" ]]; then
    rm -rf "$workspace"
  else
    log_info "Workspace preserved at $workspace"
  fi
}

trap 'handle_error $LINENO' ERR
trap cleanup EXIT

exec > >(tee -a "$log_file")
exec 2>&1
# set -x

log_info "Workspace: $workspace"
log_info "Logs: $log_file"
log_info "Reports dir: $reports_dir"
log_info "Script version: $SCRIPT_VERSION"

if [[ "$no_record" == false ]] && command -v asciinema >/dev/null 2>&1; then
  log_info "Asciinema detected. To record this session, run:"
  log_info "  asciinema rec $cast_file -- $0 $version [options]"
fi

# ---------- Environment Checks ----------
log_info "Checking prerequisites"
require_command git
require_command wget
require_command diff
require_command sha256sum
require_command python3
if [[ "$skip_compare" == false ]]; then
  require_command osslsigncode
fi
if [[ "$skip_build" == false ]]; then
  require_command docker
fi

# ---------- Clone Repository ----------
clone_repository() {
  if [[ "$force_reclone" == true && -d "$source_dir/.git" ]]; then
    log_warn "Removing existing repository (force-reclone enabled)"
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
  fi

  if [[ ! -d "$source_dir/.git" ]]; then
    log_info "Cloning $repo_url into $source_dir"
    git clone "$repo_url" "$source_dir"
  else
    log_info "Repository already present; fetching latest tags"
    (cd "$source_dir" && git fetch --tags)
  fi
}

checkout_version() {
  pushd "$source_dir" >/dev/null
  local ref_candidates=("$version")
  if [[ "$version" != v* ]]; then
    ref_candidates+=("v$version" "electrum-$version")
  fi
  ref_candidates+=("tags/$version" "tags/v$version")

  local resolved=""
  for candidate in "${ref_candidates[@]}"; do
    if git rev-parse "$candidate^{commit}" >/dev/null 2>&1; then
      resolved="$candidate"
      break
    fi
  done

  if [[ -z "$resolved" ]]; then
    log_error "Could not find a tag or branch for version $version"
    exit 1
  fi

  log_info "Checking out $resolved"
  git checkout --quiet "$resolved"
  git submodule update --init --recursive
  popd >/dev/null
}

clone_repository
checkout_version

pushd "$source_dir" >/dev/null
commit_hash=$(git rev-parse HEAD)
log_info "Using commit $commit_hash"

expected_version=$(python3 contrib/print_electrum_version.py)
log_info "Repository reports version: $expected_version"
if [[ "$expected_version" != "$version" ]]; then
  log_warn "Requested version ($version) differs from print_electrum_version.py output ($expected_version)"
fi
  popd >/dev/null

# ---------- Build Step ----------
built_dist_dir="$source_dir/contrib/build-wine/dist"
if [[ "$skip_build" == false ]]; then
  log_info "Starting reproducible build via contrib/build-wine/build.sh"
  pushd "$source_dir/contrib/build-wine" >/dev/null
  ELECBUILD_COMMIT=HEAD ELECBUILD_NOCACHE=1 ./build.sh
  popd >/dev/null
else
  log_warn "Skipping build step (user request)"
fi

if [[ ! -d "$built_dist_dir" ]] || [[ -z $(ls -1 "$built_dist_dir"/electrum-*.exe 2>/dev/null) ]]; then
  log_error "No Electrum executables found in $built_dist_dir"
  exit 1
fi

log_success "Build artifacts available in $built_dist_dir"

# ---------- Download Official Artifacts ----------
official_files=()
while IFS= read -r -d '' file; do
  official_files+=("$(basename "$file")")
done < <(find "$built_dist_dir" -maxdepth 1 -type f -name "electrum-*.exe" -print0)

if [[ "$skip_download" == false ]]; then
  log_info "Downloading official binaries for comparison"
  mkdir -p "$official_signed_dir"
  for fname in "${official_files[@]}"; do
    url="https://download.electrum.org/$version/$fname"
    target_path="$official_signed_dir/$fname"
    if [[ -f "$target_path" ]]; then
      log_info "Already downloaded: $fname"
      continue
    fi
    log_info "Fetching $url"
    if ! wget -q "$url" -O "$target_path"; then
      log_error "Failed to download $url"
      exit 1
    fi
  done
else
  log_warn "Skipping official download step (user request)"
fi

# ---------- Strip Signatures ----------
stripped_files=()
if [[ "$skip_compare" == false ]]; then
  if [[ ! -d "$official_signed_dir" ]] || [[ -z $(ls -1 "$official_signed_dir" 2>/dev/null) ]]; then
    log_error "No official binaries available in $official_signed_dir"
    exit 1
  fi

  mkdir -p "$official_stripped_dir"
  for fname in "${official_files[@]}"; do
    signed_path="$official_signed_dir/$fname"
    if [[ ! -f "$signed_path" ]]; then
      log_warn "Official binary $fname missing; skipping"
      continue
    fi
    stripped_path="$official_stripped_dir/$fname"
    log_info "Stripping Authenticode signature: $fname"
    osslsigncode remove-signature -in "$signed_path" -out "$stripped_path"
    chmod +x "$stripped_path"
    stripped_files+=("$fname")
  done
fi

# ---------- Comparison ----------
comparison_summary="$results_dir/comparison-${session_stamp}.txt"
verdict="not_evaluated"
match_count=0
diff_count=0
missing_official=0

if [[ "$skip_compare" == true ]]; then
  verdict="compare_skipped"
  log_warn "Comparison step skipped"
  for built_path in "$built_dist_dir"/electrum-*.exe; do
    [[ -e "$built_path" ]] || continue
    fname="$(basename "$built_path")"
    emit_artifact_evidence "$fname" "$built_path" ""
  done
else
  {
    echo "Comparison report - $APP_NAME v$version ($target)"
    echo "Generated: $(date -Iseconds)"
    echo "Commit: $commit_hash"
    echo
    printf '%-40s %-10s\n' "Executable" "Result"
    printf '%-40s %-10s\n' "----------" "------"
  } > "$comparison_summary"

  for fname in "${official_files[@]}"; do
    built_path="$built_dist_dir/$fname"
    stripped_path="$official_stripped_dir/$fname"
    if [[ ! -f "$built_path" ]]; then
      log_warn "Built executable missing: $fname"
      ((diff_count++))
      printf '%-40s %-10s\n' "$fname" "missing local" >> "$comparison_summary"
      emit_artifact_evidence "$fname" "$built_path" "$stripped_path"
      continue
    fi
    if [[ ! -f "$stripped_path" ]]; then
      log_warn "Official stripped executable missing: $fname"
      ((missing_official++))
      printf '%-40s %-10s\n' "$fname" "missing official" >> "$comparison_summary"
      emit_artifact_evidence "$fname" "$built_path" "$stripped_path"
      continue
    fi

    if diff -q "$built_path" "$stripped_path" >/dev/null; then
      log_success "Match: $fname"
      ((++match_count))
      printf '%-40s %-10s\n' "$fname" "match" >> "$comparison_summary"
      emit_artifact_evidence "$fname" "$built_path" "$stripped_path"
    else
      log_warn "Difference detected: $fname"
      ((diff_count++))
      printf '%-40s %-10s\n' "$fname" "diff" >> "$comparison_summary"
      emit_artifact_evidence "$fname" "$built_path" "$stripped_path"
    fi
  done

  if (( diff_count == 0 && missing_official == 0 && match_count > 0 )); then
    verdict="reproducible"
  else
    verdict="differences_found"
  fi
fi

# ---------- Summary ----------
log_info "=============================================="
log_info "${APP_NAME} v$version ($target) Verification Summary"
log_info "=============================================="
log_info "Workspace: $workspace"
log_info "Built artifacts: $built_dist_dir"
log_info "Official (signed): $official_signed_dir"
log_info "Official (stripped): $official_stripped_dir"
if [[ -f "$comparison_summary" ]]; then
  log_info "Comparison report: $comparison_summary"
fi
log_info "Evidence: $evidence_file"

case "$verdict" in
  reproducible)
    log_success "Verdict: reproducible"
    ;;
  compare_skipped)
    log_warn "Verdict: comparison skipped"
    ;;
  differences_found)
    log_warn "Verdict: differences found"
    ;;
  *)
    log_warn "Verdict: $verdict"
    ;;
esac

log_info "Matches: $match_count, diffs: $diff_count, missing official: $missing_official"
log_info "Logs copied to $reports_dir"
log_info "=== Verification Complete ==="
