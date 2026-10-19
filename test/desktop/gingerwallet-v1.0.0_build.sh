#!/bin/bash
# gingerwallet_build.sh - GingerWallet Desktop Reproducible Build Verifier (linux-x64 / win-x64 zip)
# Version: v1.0.0
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-16
# Upstream builds every release zip on Windows (WalletWasabi.Packager --onlybinaries, as in its
# Detbuild.ps1). This script does the same in a throw-away copy of a Windows Server 2022 VM
# (dockur/windows, KVM), with the .NET SDK and runtime named in the release's BUILDINFO.json
# (Microsoft zips, sha512-checked), then compares every file of the official zip.
# Needs /dev/kvm, the golden image and VM key (--windows-dir; runbook: GitLab #984).
# Organization: WalletScrutiny.com
# Project: https://github.com/GingerPrivacy/GingerWallet
# MIT License. Provided as-is for reproducible-build verification, without warranty.
set -euo pipefail

SCRIPT_VERSION="v1.0.0"
APP_ID="gingerwallet"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
RESOLVED_COMMIT="unknown"

HELPER_IMAGE="ginger-win-helper:1.1"
DOCKUR_IMAGE="docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea"
WIN_DIR="${WIN_DIR:-/var/lib/walletscrutiny-windows}"
VM_NAME=""
VM_PORT=""
BUILD_PID=""

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Trust anchor: the fingerprint is the pin; PGP.txt is fetched, never trusted.
GINGER_KEY_FPR="FA0B017A3E75CE65CBF7838FA8FF3767EDF5DCE9"
GINGER_REPO="https://github.com/GingerPrivacy/GingerWallet"
DOTNET_META="https://dotnetcli.blob.core.windows.net/dotnet/release-metadata"
DOCKER_CMD="${DOCKER_CMD:-}"

APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
TARGET=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
BINARY_PATH=""
SKIP_SIG_VERIFY=false
BINARY_SOURCE="operator-supplied"
SIG_STATUS="not checked"
NET_SDK=""
NET_RT=""
BI_COMMIT=""

# Never fatal: a hashing problem is not a build outcome.
sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}
# Parameter, environment and input-integrity problems: exit 2 and NO verdict
# (ABS publishes any YAML it finds).
die() {
  echo "ERROR: $1" >&2
  exit "${2:-$EXIT_BUILD_FAILED}"
}
warn() { echo "WARN: $1" >&2; }
detect_container_cmd() {
  [[ -z "$DOCKER_CMD" ]] || return 0
  if command -v podman >/dev/null 2>&1; then
    DOCKER_CMD="podman"
  elif command -v docker >/dev/null 2>&1; then
    DOCKER_CMD="docker"
  else
    die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
  fi
}
require_value() {
  [[ -n "${2:-}" && "${2:-}" != --* ]] || die "Missing value for parameter: $1" $EXIT_INVALID_PARAMS
}
sanitize_component() {
  local input
  input=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g')
  input="${input#-}"; input="${input%-}"
  echo "${input:-na}"
}
# Upstream target name for an --arch value (ABS uses x86_64-linux / x86_64-windows).
target_for_arch() {
  case "${1:-}" in
    x86_64-linux|x86_64-linux-gnu|linux-x64|linux64|linux) echo "linux-x64" ;;
    x86_64-windows|win-x64|win64|windows) echo "win-x64" ;;
    *) echo "" ;;
  esac
}
build_helper() {
  echo "[INFO] Building helper container..."
  "$DOCKER_CMD" build -t "${HELPER_IMAGE}" - << 'HEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
&& apt-get install -y --no-install-recommends curl ca-certificates gnupg unzip python3 openssh-client \
&& rm -rf /var/lib/apt/lists/*
HEOF
}
# Helper writes land under /work (= WORK_DIR); restore_host_owner hands them back.
helper_c() {
  "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/work" -w /work \
    --entrypoint "$1" "${HELPER_IMAGE}" "${@:2}"
}
fetch_url() { helper_c curl -fsSL -o "/work/$2" "$1" 2>/dev/null; }
fetch_release_asset() {
  fetch_url "${GINGER_REPO}/releases/download/v${APP_VERSION}/$1" "official/$1"
}

# The release's SHA256SUMS.asc (clearsigned) must carry a VALIDSIG for the pinned key,
# and the official zip must match its entry. Keyring is ephemeral in WORK_DIR.
verify_official_signature() {
  local art="$1" od="${WORK_DIR}/official"
  if [[ "$SKIP_SIG_VERIFY" == true ]]; then
    SIG_STATUS="SKIPPED (--no-verify-signature)"
    warn "Signature verification skipped."
    return 0
  fi
  echo "[INFO] Verifying ${art} against the signed SHA256SUMS..."
  [[ -f "${od}/SHA256SUMS.asc" ]] || fetch_release_asset "SHA256SUMS.asc" \
    || die "Could not download SHA256SUMS.asc" $EXIT_INVALID_PARAMS
  fetch_url "https://raw.githubusercontent.com/GingerPrivacy/GingerWallet/v${APP_VERSION}/PGP.txt" "official/PGP.txt" \
    || die "Could not download the signing key" $EXIT_INVALID_PARAMS
  helper_c bash -c "
    export GNUPGHOME=/work/gnupg
    mkdir -p \"\$GNUPGHOME\" && chmod 700 \"\$GNUPGHOME\"
    gpg --batch --no-tty -q --import /work/official/PGP.txt
    gpg --batch --no-tty --status-fd 1 --output /work/official/SHA256SUMS --decrypt /work/official/SHA256SUMS.asc
  " > "${WORK_DIR}/logs/gpg-verify.txt" 2>&1 || true

  if ! grep -qE "VALIDSIG .*${GINGER_KEY_FPR}" "${WORK_DIR}/logs/gpg-verify.txt"; then
    SIG_STATUS="FAILED (SHA256SUMS not signed by pinned key)"
    sed -n '1,20p' "${WORK_DIR}/logs/gpg-verify.txt" >&2
    die "Signature check FAILED for SHA256SUMS.asc" $EXIT_INVALID_PARAMS
  fi
  echo "[INFO]   SHA256SUMS signed by pin ${GINGER_KEY_FPR}"

  local want got
  want=$(awk -v n="$art" '{f=$2; sub(/^\*/,"",f)} f == n {print $1; exit}' "${od}/SHA256SUMS")
  [[ -n "$want" ]] || { SIG_STATUS="FAILED (${art} absent from SHA256SUMS)"
    die "${art} has no entry in SHA256SUMS" $EXIT_INVALID_PARAMS; }
  got=$(sha256_of "${od}/${art}")
  if [[ "$want" != "$got" ]]; then
    SIG_STATUS="FAILED (sha256 vs signed SHA256SUMS)"
    die "${art} sha256 ${got} != SHA256SUMS ${want}" $EXIT_INVALID_PARAMS
  fi
  SIG_STATUS="VERIFIED (pinned key; sha256 matches)"
  echo "[INFO]   sha256 matches SHA256SUMS entry"
}

# BUILDINFO.json names the SDK, the runtime the packager ran on (it is written into the
# output), and the commit. The SDK and runtime zips come from Microsoft's metadata.
read_buildinfo() {
  local art="$1" out
  out=$(helper_c bash -c "unzip -p '/work/official/${art}' BUILDINFO.json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d[\"NetSdkVersion\"], d[\"NetRuntimeVersion\"], d[\"GitCommitHash\"])'" 2>/dev/null) \
    || die "Could not read BUILDINFO.json from ${art}" $EXIT_INVALID_PARAMS
  read -r NET_SDK NET_RT BI_COMMIT <<< "$out"
  [[ "$NET_SDK" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$NET_RT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BI_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || die "Unexpected BUILDINFO.json values: '$out'" $EXIT_INVALID_PARAMS
  echo "[INFO] BUILDINFO.json: SDK ${NET_SDK}, runtime ${NET_RT}, commit ${BI_COMMIT}"
}
resolve_dotnet() {
  local chan="${NET_SDK%.*}" out
  fetch_url "${DOTNET_META}/${chan}/releases.json" "logs/dotnet-releases.json" \
    || die "Could not download .NET ${chan} release metadata" $EXIT_INVALID_PARAMS
  out=$(helper_c python3 -c '
import json,sys
d=json.load(open("/work/logs/dotnet-releases.json")); sdk,rt=sys.argv[1],sys.argv[2]; o={}
def z(fs): return [(f["url"],f["hash"]) for f in fs if f.get("rid")=="win-x64" and f["name"].endswith(".zip")][0]
for r in d["releases"]:
    for s in r.get("sdks",[]):
        if s["version"]==sdk: o["s"]=z(s["files"])
    if r["runtime"]["version"]==rt: o["r"]=z(r["runtime"]["files"])
print(*o["s"],*o["r"])' "$NET_SDK" "$NET_RT" 2>/dev/null) \
    || die "SDK ${NET_SDK} or runtime ${NET_RT} not in Microsoft's metadata" $EXIT_INVALID_PARAMS
  read -r SDK_URL SDK_SHA RT_URL RT_SHA <<< "$out"
  echo "[INFO] .NET SDK ${NET_SDK}: $(basename "$SDK_URL") sha512 ${SDK_SHA:0:16}..."
  echo "[INFO] .NET runtime ${NET_RT}: $(basename "$RT_URL") sha512 ${RT_SHA:0:16}..."
}

is_rootless() {
  local r=""
  case "$DOCKER_CMD" in
    *podman) r="$("$DOCKER_CMD" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" ;;
    *docker) if "$DOCKER_CMD" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
        then r="true"; else r="false"; fi ;;
  esac
  [[ "$r" == "true" ]]
}
# Hand the workspace back so the caller can delete it without sudo
# (non-sudo-directories-guideline.md). Rootless, the caller IS container UID 0.
restore_host_owner() {
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && -n "${DOCKER_CMD}" ]] || return 0
  "$DOCKER_CMD" image inspect "${HELPER_IMAGE}" >/dev/null 2>&1 || return 0
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  if is_rootless; then uid=0; gid=0; fi
  "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/w" --entrypoint chown "${HELPER_IMAGE}" \
    -R "${uid}:${gid}" /w >/dev/null 2>&1 \
    || warn "Could not restore ownership of ${WORK_DIR}; deleting it may need 'podman unshare rm -rf'"
}

# SSH into the VM from the helper container (host network reaches the 127.0.0.1-only port).
# The key is this run's private 0600 copy. Default remote shell: cmd.exe.
vm_ssh() {
  "$DOCKER_CMD" run --rm -i --network host -v "${WORK_DIR}/vm/key:/key:ro" --entrypoint ssh \
    "${HELPER_IMAGE}" -i /key -p "$VM_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR Docker@127.0.0.1 "$@"
}
# Multi-line PowerShell does not work through "-Command -": upload a .ps1, run it with -File.
vm_run() {
  vm_ssh "powershell -NoProfile -Command \"\$input | Out-File -Encoding utf8 C:\\dl\\$1\"" || return 1
  vm_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\dl\\$1"
}
# Streams one file out of the VM.
vm_get() {
  vm_ssh "powershell -NoProfile -Command \"\$s=[IO.File]::OpenRead('$1'); \$o=[Console]::OpenStandardOutput(); \$s.CopyTo(\$o); \$o.Flush()\""
}

# Missing KVM, golden image or key is an environment problem, not a build outcome.
check_vm_prereqs() {
  local g="${WIN_DIR}/golden-2022" f ends
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable by $(id -un) (kvm group?)" $EXIT_INVALID_PARAMS
  for f in storage/data.qcow2 storage/windows.boot storage2/data2.qcow2; do
    [[ -r "${g}/${f}" ]] || die "Golden image file missing: ${g}/${f} (see GitLab #984)" $EXIT_INVALID_PARAMS
  done
  [[ -r "${WIN_DIR}/vm-key/ws-windows-vm" ]] || die "VM key not readable: ${WIN_DIR}/vm-key/ws-windows-vm" $EXIT_INVALID_PARAMS
  ends=$(sed -n 's/.*evaluation ends ~\([0-9-]*\).*/\1/p' "${g}/GOLDEN-INFO.txt" 2>/dev/null | head -1)
  [[ -z "$ends" || ! "$(date -u +%F)" > "$ends" ]] || die "Golden image evaluation ended ${ends}; rebuild it" $EXIT_INVALID_PARAMS
  echo "[INFO] Golden image: ${g} (evaluation ends ${ends:-unknown})"
}

# Boots a throw-away copy of the golden image: qcow2 overlays in the workspace, backed by the
# read-only golden disks mounted at the same paths in every container.
start_vm() {
  local g="${WIN_DIR}/golden-2022" vm="${WORK_DIR}/vm" i u=() x=()
  mkdir -p "${vm}/storage" "${vm}/storage2"
  install -m 600 "${WIN_DIR}/vm-key/ws-windows-vm" "${vm}/key"
  cp "${g}"/storage/windows.* "${vm}/storage/" && chmod u+w "${vm}"/storage/windows.*
  is_rootless || u=(--user "$(id -u):$(id -g)")
  [[ "$DOCKER_CMD" != *podman ]] || x=(--group-add keep-groups)
  local mounts=(-v "${g}/storage:/golden:ro" -v "${g}/storage2:/golden2:ro")
  "$DOCKER_CMD" run --rm "${u[@]}" "${mounts[@]}" -v "${vm}:/w" --entrypoint sh "$DOCKUR_IMAGE" -c \
    'qemu-img create -q -f qcow2 -b /golden/data.qcow2 -F qcow2 /w/storage/data.qcow2 &&
    qemu-img create -q -f qcow2 -b /golden2/data2.qcow2 -F qcow2 /w/storage2/data2.qcow2' \
    || die "Could not create the per-run VM disks" $EXIT_INVALID_PARAMS

  VM_NAME="ws-ginger-${RUN_ID}"
  "$DOCKER_CMD" run -d --name "$VM_NAME" "${x[@]}" "${mounts[@]}" \
    -e VERSION=2022 -e RAM_SIZE=8G -e CPU_CORES=4 -e DISK_SIZE=64G -e DISK2_SIZE=32G -e DISK_FMT=qcow2 \
    -v "${vm}/storage:/storage" -v "${vm}/storage2:/storage2" -p 127.0.0.1::22 \
    --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN "$DOCKUR_IMAGE" >/dev/null \
    || die "Could not start the Windows VM container" $EXIT_INVALID_PARAMS
  VM_PORT=$("$DOCKER_CMD" port "$VM_NAME" 22/tcp | head -1 | sed 's/.*://')
  [[ "$VM_PORT" =~ ^[0-9]+$ ]] || die "No SSH port published for ${VM_NAME}" $EXIT_INVALID_PARAMS
  echo "[INFO] VM ${VM_NAME} booting; SSH on 127.0.0.1:${VM_PORT}"
  for i in $(seq 1 60); do
    if vm_ssh 'type C:\OEM\done.txt' 2>/dev/null | grep -q done; then
      echo "[INFO] Windows ready (attempt ${i})"
      vm_ssh 'cmd /c mkdir C:\dl' >/dev/null 2>&1 || true
      return 0
    fi
    sleep 10
  done
  die "Windows VM did not answer over SSH within 10 minutes" $EXIT_INVALID_PARAMS
}

# Upstream's own deterministic build (Detbuild.ps1): clone the tag, then the packager in
# --onlybinaries mode (restore --locked-mode, publish all four targets). Backgrounded so
# INT/TERM interrupt the wait at once.
build_in_vm() {
  local log="${WORK_DIR}/logs/vm-build.log" c
  echo "[INFO] Building GingerWallet ${APP_VERSION} inside the VM, ~15-20 min (log: logs/vm-build.log)..."
  local subst=(-e "s|@SDKURL@|${SDK_URL}|" -e "s|@SDKSHA@|${SDK_SHA}|" -e "s|@RTURL@|${RT_URL}|"
    -e "s|@RTSHA@|${RT_SHA}|" -e "s|@VER@|${APP_VERSION}|" -e "s|@TARGET@|${TARGET}|")
  sed "${subst[@]}" << 'PSEOF' | vm_run build.ps1 2>&1 | tee "$log" &
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force C:\dl,C:\dotnet | Out-Null
foreach ($p in @(@('@SDKURL@','@SDKSHA@','sdk'),@('@RTURL@','@RTSHA@','runtime'))) {
  curl.exe -sSfL -o "C:\dl\$($p[2]).zip" $p[0]
  if ($LASTEXITCODE) { throw "download failed: $($p[2])" }
  if ((Get-FileHash "C:\dl\$($p[2]).zip" -Algorithm SHA512).Hash -ne $p[1].ToUpper()) { throw "sha512 mismatch: $($p[2])" }
  'SHA512 OK ' + $p[2]
  Expand-Archive "C:\dl\$($p[2]).zip" C:\dotnet -Force
}
$env:DOTNET_ROOT='C:\dotnet'; $env:Path='C:\dotnet;'+$env:Path
$env:DOTNET_MULTILEVEL_LOOKUP='0'; $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'; $env:DOTNET_NOLOGO='1'
cmd /c "dotnet --list-sdks & dotnet --list-runtimes"
cmd /c "mkdir D:\a\GingerWallet 2>nul & git clone -q --depth 1 --branch v@VER@ https://github.com/GingerPrivacy/GingerWallet D:\a\GingerWallet\GingerWallet 2>&1"
if ($LASTEXITCODE) { throw 'clone failed' }
Set-Location D:\a\GingerWallet\GingerWallet
'COMMIT=' + (git rev-parse HEAD)
cmd /c "dotnet run --project WalletWasabi.Packager -- --onlybinaries 2>&1"
if ($LASTEXITCODE) { throw 'packager failed' }
Set-Location WalletWasabi.Fluent.Desktop\bin\dist
tar.exe -cf C:\dl\dist.tar @TARGET@
'HASH ' + (Get-FileHash C:\dl\dist.tar -Algorithm SHA256).Hash.ToLower() + ' dist.tar'
'BUILD-OK'
PSEOF
  BUILD_PID=$!
  wait "$BUILD_PID" || true
  BUILD_PID=""
  tr -d '\r' < "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
  grep -qx 'BUILD-OK' "$log" || ftbfs_die "The Windows build failed inside the VM; see logs/vm-build.log"
  c=$(sed -n 's/^COMMIT=//p' "$log" | head -1)
  [[ ! "$c" =~ ^[0-9a-f]{40}$ ]] || RESOLVED_COMMIT="$c"
}

# Streams the built folder out of the VM as a tar, checked against the hash Windows computed.
fetch_build() {
  local want got
  want=$(awk '$1 == "HASH" && $3 == "dist.tar" {print $2}' "${WORK_DIR}/logs/vm-build.log")
  vm_get 'C:\dl\dist.tar' > "${WORK_DIR}/built/dist.tar" || die "Could not copy the build out of the VM"
  got=$(sha256_of "${WORK_DIR}/built/dist.tar")
  [[ -n "$want" && "$got" == "$want" ]] || die "Build copied out of the VM is corrupt (${got} vs ${want:-none})"
  echo "[INFO] Build copied out of the VM; sha256 matches Windows' own hash"
  helper_c tar -xf /work/built/dist.tar -C /work/built
  rm -f "${WORK_DIR}/built/dist.tar"
}

# EXIT trap: stop the VM, hand the workspace back, delete the per-run disks and key copy.
cleanup() {
  [[ -z "$BUILD_PID" ]] || kill "$BUILD_PID" 2>/dev/null || true
  if [[ -n "$VM_NAME" ]]; then
    "$DOCKER_CMD" rm -f "$VM_NAME" >/dev/null 2>&1 || warn "Could not remove container ${VM_NAME}"
  fi
  restore_host_owner
  rm -rf "${WORK_DIR}/vm" 2>/dev/null || warn "Could not delete ${WORK_DIR}/vm"
}
ftbfs_die() {
  printf 'script_version: %s\nverdict: ftbfs\nnotes: "%s"\n' "$SCRIPT_VERSION" "$1" > "$results_file"
  cp "$results_file" "$execution_dir/" 2>/dev/null || true
  die "$1" $EXIT_BUILD_FAILED
}

# Every file of the official zip against the built folder (union of both sides). The zips
# themselves are made with timestamps, so the archive bytes are not compared.
compare_files() {
  local oroot="$1" broot="$2" list="${WORK_DIR}/logs/file-compare.txt" rel oh bh
  CMP_TOTAL=0; CMP_OK=0; CMP_BAD=0
  : > "$list"
  while IFS= read -r rel; do
    CMP_TOTAL=$((CMP_TOTAL + 1))
    oh="(missing)"; bh="(missing)"
    [[ -f "${oroot}/${rel}" ]] && oh=$(sha256_of "${oroot}/${rel}")
    [[ -f "${broot}/${rel}" ]] && bh=$(sha256_of "${broot}/${rel}")
    if [[ "$oh" == "$bh" ]]; then
      CMP_OK=$((CMP_OK + 1)); echo "MATCH  ${rel}  ${oh}" >> "$list"
    else
      CMP_BAD=$((CMP_BAD + 1)); echo "DIFFER ${rel}  official ${oh}  built ${bh}" >> "$list"
    fi
  done < <({ (cd "$oroot" && find . -type f); (cd "$broot" && find . -type f); } | sed 's|^\./||' | LC_ALL=C sort -u)
  echo "[INFO] Files compared: ${CMP_TOTAL} (union of both sides), identical: ${CMP_OK}, differing: ${CMP_BAD}"
  # Diff output rule: at most 5 lines on the terminal; the full list is in the log.
  if [[ "$CMP_BAD" -gt 0 ]]; then
    grep '^DIFFER' "$list" | head -5
    [[ "$CMP_BAD" -le 5 ]] || echo "    ... and $((CMP_BAD - 5)) more; full list: logs/file-compare.txt"
  fi
}

build_and_verify() {
  local version_component
  version_component=$(sanitize_component "$APP_VERSION")
  execution_dir="$(pwd -P)"
  RUN_ID="$(date +%s)-$$"

  # A new workspace per run in the caller's directory (per-run-workspace-guideline.md).
  if [[ -n "$CUSTOM_WORK_DIR" ]]; then
    WORK_DIR="$CUSTOM_WORK_DIR"
  else
    WORK_DIR="${execution_dir}/gingerwallet_verification_${version_component}_${TARGET}_${RUN_ID}"
    mkdir "$WORK_DIR" || die "Could not create ${WORK_DIR}" $EXIT_INVALID_PARAMS
  fi
  results_file="${WORK_DIR}/COMPARISON_RESULTS.yaml"
  mkdir -p "$WORK_DIR/logs" "$WORK_DIR/official" "$WORK_DIR/built" "$WORK_DIR/official-extracted"
  cd "$WORK_DIR"
  # Cleanup runs on every exit path. A stopped run (130) writes no verdict.
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  echo "======================================================"
  echo "GingerWallet v${APP_VERSION} — ${TARGET} zip Verification"
  echo "======================================================"
  if ! "$DOCKER_CMD" image inspect "${HELPER_IMAGE}" >/dev/null 2>&1; then
    build_helper
  fi

  OFFICIAL_NAME="Ginger-${APP_VERSION}-${TARGET}.zip"
  local otgt="${WORK_DIR}/official/${OFFICIAL_NAME}"
  if [[ -n "$BINARY_PATH" ]]; then
    echo "[INFO] Using provided zip: $(basename "$BINARY_PATH")"
    cp "$BINARY_PATH" "$otgt"
  else
    echo "[INFO] Downloading ${OFFICIAL_NAME}..."
    fetch_release_asset "$OFFICIAL_NAME" || die "Could not download ${OFFICIAL_NAME}" $EXIT_INVALID_PARAMS
    BINARY_SOURCE="downloaded from GingerPrivacy/GingerWallet releases"
  fi
  echo "[INFO] Official sha256: $(sha256_of "$otgt")"
  verify_official_signature "$OFFICIAL_NAME"
  read_buildinfo "$OFFICIAL_NAME"
  resolve_dotnet

  start_vm
  build_in_vm
  [[ "$RESOLVED_COMMIT" == "$BI_COMMIT" ]] \
    || ftbfs_die "Tag v${APP_VERSION} is commit ${RESOLVED_COMMIT}, but the release's BUILDINFO.json names ${BI_COMMIT}"
  echo "[INFO] Tag commit matches BUILDINFO.json"
  fetch_build
  "$DOCKER_CMD" rm -f "$VM_NAME" >/dev/null 2>&1 && VM_NAME=""

  helper_c unzip -q "/work/official/${OFFICIAL_NAME}" -d /work/official-extracted
  echo ""
  echo "[INFO] === File Comparison (official zip vs built ${TARGET}) ==="
  compare_files "${WORK_DIR}/official-extracted" "${WORK_DIR}/built/${TARGET}"

  local verdict note
  if [[ "$CMP_BAD" -eq 0 && "$CMP_TOTAL" -gt 0 ]]; then
    verdict="reproducible"
    note="All ${CMP_TOTAL} files of ${OFFICIAL_NAME} are identical to the build (upstream packager --onlybinaries, Windows Server 2022 VM, .NET SDK ${NET_SDK} + runtime ${NET_RT} from BUILDINFO.json). The zip archives themselves differ only as containers (file timestamps)."
  else
    verdict="not_reproducible"
    note="${CMP_BAD} of ${CMP_TOTAL} files differ between ${OFFICIAL_NAME} and the build; full list in logs/file-compare.txt."
  fi
  printf 'script_version: %s\nverdict: %s\nnotes: |\n  %s\n' "$SCRIPT_VERSION" "$verdict" "$note" > "$results_file"
  cp "$results_file" "$execution_dir/" 2>/dev/null || true
  display_results
}

# Hash legend, kept OUTSIDE the Begin/End markers (dannys-amendments.md, "Ambiguous Artifact Hashes").
print_hash_legend() {
  echo ""
  echo "HASH LEGEND"
  echo "  appHash     official ${OFFICIAL_NAME} as distributed - THIS is the hash to publish."
  echo "  builtHash   not applicable: the build is a folder, compared file by file."
  echo "  scriptHash  this script: which tooling produced these results."
}
emit_verification_summary() {
  local yaml_verdict official_sha match_flag=0 match_word="DOESN'T MATCH" matches=0 mismatches=1
  yaml_verdict=$(grep "^verdict:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)
  official_sha=$(sha256_of "${WORK_DIR}/official/${OFFICIAL_NAME}")
  if [[ "$yaml_verdict" == "reproducible" ]]; then
    match_flag=1; match_word="ALL ${CMP_TOTAL} FILES MATCH"; matches=1; mismatches=0
  fi
  print_hash_legend
  echo ""
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${APP_VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${yaml_verdict}"
  echo "appHash:        ${official_sha}"
  echo "commit:         ${RESOLVED_COMMIT}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
  echo ""
  echo "Diff:"
  echo "BUILDS MATCH BINARIES"
  echo "${OFFICIAL_NAME} - ${APP_ARCH} - ${CMP_OK}/${CMP_TOTAL} files identical - ${match_flag} (${match_word})"
  echo ""
  echo "SUMMARY"
  echo "total: 1"
  echo "matches: ${matches}"
  echo "mismatches: ${mismatches}"
  echo ""
  echo "Revision, tag (and its signature):"
  echo "tag:            v${APP_VERSION}"
  echo "commit:         ${RESOLVED_COMMIT}"
  echo "BUILDINFO.json: SDK ${NET_SDK}, runtime ${NET_RT}, commit ${BI_COMMIT}"
  echo ""
  echo "Signature Summary:"
  echo "official artifact: ${BINARY_SOURCE}"
  echo "SHA256SUMS signature: ${SIG_STATUS}"
  echo "pinned key: ${GINGER_KEY_FPR}"
  echo ""
  echo "===== End Results ====="
  echo ""
  echo "Run a full"
  echo "diff --recursive ${WORK_DIR}/official-extracted ${WORK_DIR}/built/${TARGET}"
  echo "meld ${WORK_DIR}/official-extracted ${WORK_DIR}/built/${TARGET}"
  echo "for more details."
}
display_results() {
  echo ""
  echo "======================================================"
  echo "RESULTS"
  echo "======================================================"
  cat COMPARISON_RESULTS.yaml
  echo ""
  echo "Workspace: ${WORK_DIR}"
  emit_verification_summary
  echo ""
  if grep -q '^verdict: reproducible' COMPARISON_RESULTS.yaml; then
    echo "✅ VERDICT: REPRODUCIBLE"
    echo "Exit code: $EXIT_SUCCESS"
    exit $EXIT_SUCCESS
  fi
  echo "❌ VERDICT: NOT REPRODUCIBLE"
  echo "Exit code: $EXIT_BUILD_FAILED"
  exit $EXIT_BUILD_FAILED
}

usage() {
  cat << EOF
Usage: $0 --version VERSION --arch ARCH [--type standalone] [--binary FILE]
  --arch    x86_64-linux (linux-x64) or x86_64-windows (win-x64); taken from --binary if omitted
  --type    standalone (the release zip); the MSI is not supported yet
  --binary  official Ginger-<version>-<linux-x64|win-x64>.zip; checked against the signed SHA256SUMS
  Optional: --windows-dir DIR (golden image + VM key, default /var/lib/walletscrutiny-windows)
            --work-dir DIR  --no-verify-signature
Example: $0 --version 2.0.26 --arch x86_64-windows
EOF
}
parse_arguments() {
  if [[ $# -eq 0 ]]; then usage; exit $EXIT_INVALID_PARAMS; fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --version) require_value "$1" "${2:-}"; APP_VERSION="${2#v}"; shift 2 ;;
      --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
      --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
      --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --work-dir) require_value "$1" "${2:-}"; CUSTOM_WORK_DIR="$2"; shift 2 ;;
      --windows-dir) require_value "$1" "${2:-}"; WIN_DIR="$2"; shift 2 ;;
      --apk)
        echo "[INFO] --apk is not used by desktop scripts; ignoring it"
        if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi ;;
      --no-verify-signature) SKIP_SIG_VERIFY=true; shift ;;
      -h|--help) usage; exit $EXIT_SUCCESS ;;
      *) warn "Ignoring unknown parameter: $1"; shift ;;
    esac
  done

  [[ -n "$APP_VERSION" ]] || die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
  [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid --version '$APP_VERSION'" $EXIT_INVALID_PARAMS
  case "${APP_TYPE:-standalone}" in
    standalone|zip) ;;
    msi) die "--type msi is not supported yet; only the release zip is verified" $EXIT_INVALID_PARAMS ;;
    *) die "Invalid --type '$APP_TYPE' (only standalone)" $EXIT_INVALID_PARAMS ;;
  esac
  if [[ -n "$BINARY_PATH" ]]; then
    [[ -f "$BINARY_PATH" ]] || die "--binary file does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
    local bname; bname=$(basename "$BINARY_PATH")
    case "$bname" in
      *.msi) die "The MSI is not supported yet; only the release zip is verified" $EXIT_INVALID_PARAMS ;;
      *-win-x64.zip)   [[ -n "$APP_ARCH" ]] || APP_ARCH="x86_64-windows" ;;
      *-linux-x64.zip) [[ -n "$APP_ARCH" ]] || APP_ARCH="x86_64-linux" ;;
      *) die "--binary '$bname' must be Ginger-<version>-<linux-x64|win-x64>.zip" $EXIT_INVALID_PARAMS ;;
    esac
  fi
  [[ -n "$APP_ARCH" ]] || die "Missing required parameter: --arch" $EXIT_INVALID_PARAMS
  TARGET=$(target_for_arch "$APP_ARCH")
  [[ -n "$TARGET" ]] || die "Unsupported --arch '$APP_ARCH' (x86_64-linux or x86_64-windows)" $EXIT_INVALID_PARAMS
  if [[ -n "$BINARY_PATH" && "$(basename "$BINARY_PATH")" != *"-${TARGET}.zip" ]]; then
    die "--binary does not match --arch ${APP_ARCH} (${TARGET})" $EXIT_INVALID_PARAMS
  fi
}

main() {
  # Runs as a normal user only; root runs break the ownership guarantees.
  if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: Do not run this script as root; run it as a normal user." >&2
    exit $EXIT_INVALID_PARAMS
  fi
  echo ""
  echo "======================================================"
  echo "GingerWallet Reproducible Build Verifier ${SCRIPT_VERSION}"
  echo "======================================================"
  # Self-identify before anything else (script-version-and-hash.md).
  SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
  echo "[INFO] Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
  echo "[INFO]         sha256: ${SCRIPT_SHA256}"

  parse_arguments "$@"
  check_vm_prereqs
  detect_container_cmd
  build_and_verify
}

main "$@"
