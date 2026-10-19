#!/bin/bash
# wasabiwindows_build.sh - Wasabi Wallet Windows Reproducible Build Verifier (win-x64 zip / MSI)
# Version: v0.2.0
# Last modified by: Claude Code for Danny
# Last modified on: 2026-10-17
# Upstream builds the Windows zip and MSI on a GitHub Windows runner with Contrib/release.sh
# wininstaller (.github/workflows/release.yml). This script runs that same release.sh in a
# throw-away copy of a Windows Server 2022 VM (dockur/windows, KVM), with the .NET SDK that
# ships the runtime found in the official artifact, then compares every file (zip) or every
# stream, table and cabinet (MSI), printing each difference by name.
# Needs /dev/kvm, the golden image and VM key (--windows-dir; runbook: GitLab #984).
# Linux artifacts stay with wasabidesktop_build.sh (ABS picks scripts by appId + platform).
# Organization: WalletScrutiny.com
# Project: https://github.com/WalletWasabi/WalletWasabi
# MIT License. Provided as-is for reproducible-build verification, without warranty.
set -euo pipefail

SCRIPT_VERSION="v0.2.0"
APP_ID="wasabi"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
RESOLVED_COMMIT="unknown"

HELPER_IMAGE="wasabi-win-helper:0.1"
DOCKUR_IMAGE="docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea"
WIN_DIR="${WIN_DIR:-/var/lib/walletscrutiny-windows}"
VM_NAME=""
VM_PORT=""
BUILD_PID=""

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Trust anchor: the fingerprint is the pin; PGP.txt is fetched, never trusted.
WASABI_KEY_FPR="6FB3872B5D42292F59920797856348328949861E"
WASABI_REPO="https://github.com/WalletWasabi/WalletWasabi"
DOTNET_META="https://dotnetcli.blob.core.windows.net/dotnet/release-metadata"
# release.yml installs chocolatey's 7zip.commandline 16.02, a deprecated meta package that
# pulls the newest 7zip.portable, so upstream's 7-Zip version is not pinned. 7-Zip only packs
# the zip container, whose bytes are not compared; any version gives the same files.
SEVENZIP_URL="https://www.7-zip.org/a/7z2301-x64.msi"
SEVENZIP_SHA256="0ba639b6dacdf573d847c911bd147c6384381a54dac082b1e8c77bc73d58958b"
# Random per-build MSI IDs (ProductCode Id="*", heat -gg component GUIDs): "no" counts them
# against the verdict (upstream could pin them). Policy decision pending (Danny, Option A/B).
MSI_ACCEPT_RANDOM_IDS="no"
DOCKER_CMD="${DOCKER_CMD:-}"

APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
BINARY_PATH=""
SKIP_SIG_VERIFY=false
BINARY_SOURCE="operator-supplied"
SIG_STATUS="not checked"
NET_SDK=""
NET_RT=""
OFFICIAL_NAME=""
BUILT_SHA="N/A"
CMP_TOTAL=0; CMP_OK=0; CMP_BAD=0
MSI_RC=""

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
build_helper() {
  echo "[INFO] Building helper container..."
  "$DOCKER_CMD" build -t "${HELPER_IMAGE}" - << 'HEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
&& apt-get install -y --no-install-recommends curl ca-certificates gnupg unzip p7zip-full python3 openssh-client \
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
  fetch_url "${WASABI_REPO}/releases/download/v${APP_VERSION}/$1" "official/$1"
}

# The release's SHA256SUMS.asc (clearsigned) must carry a VALIDSIG for the pinned key,
# and the official artifact must match its entry. Keyring is ephemeral in WORK_DIR.
verify_official_signature() {
  local art="$1" od="${WORK_DIR}/official"
  if [[ "$SKIP_SIG_VERIFY" == true ]]; then
    SIG_STATUS="SKIPPED (--no-verify-signature)"
    warn "Signature verification skipped."
    return 0
  fi
  echo "[INFO] Verifying ${art} against the signed SHA256SUMS..."
  fetch_release_asset "SHA256SUMS.asc" || die "Could not download SHA256SUMS.asc" $EXIT_INVALID_PARAMS
  fetch_url "https://raw.githubusercontent.com/WalletWasabi/WalletWasabi/v${APP_VERSION}/PGP.txt" "official/PGP.txt" \
    || die "Could not download the signing key" $EXIT_INVALID_PARAMS
  helper_c bash -c "
    export GNUPGHOME=/work/gnupg
    mkdir -p \"\$GNUPGHOME\" && chmod 700 \"\$GNUPGHOME\"
    gpg --batch --no-tty -q --import /work/official/PGP.txt
    gpg --batch --no-tty --status-fd 1 --output /work/official/SHA256SUMS --decrypt /work/official/SHA256SUMS.asc
  " > "${WORK_DIR}/logs/gpg-verify.txt" 2>&1 || true

  if ! grep -qE "VALIDSIG .*${WASABI_KEY_FPR}" "${WORK_DIR}/logs/gpg-verify.txt"; then
    SIG_STATUS="FAILED (SHA256SUMS not signed by pinned key)"
    sed -n '1,20p' "${WORK_DIR}/logs/gpg-verify.txt" >&2
    die "Signature check FAILED for SHA256SUMS.asc" $EXIT_INVALID_PARAMS
  fi
  echo "[INFO]   SHA256SUMS signed by pin ${WASABI_KEY_FPR}"
  local want got
  want=$(awk -v n="$art" '{f=$2; sub(/^\*/,"",f); sub(/^\.\//,"",f)} f == n {print $1; exit}' "${od}/SHA256SUMS")
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

# The runtime the official build bundled (runtimeconfig.json "includedFrameworks"); from the
# zip directly, from the MSI's cabinets after extraction.
read_runtime() {
  local out
  if [[ "$APP_TYPE" == "zip" ]]; then
    out=$(helper_c bash -c "unzip -p '/work/official/${OFFICIAL_NAME}' WalletWasabi.Fluent.Desktop.runtimeconfig.json" 2>/dev/null) || true
  else
    out=$(helper_c bash -c "
      7z x -tCompound '/work/official/${OFFICIAL_NAME}' -o/work/ex-official -y >/dev/null &&
      for c in /work/ex-official/*.cab; do 7z x \"\$c\" -o/work/cab-official/\$(basename \"\$c\" .cab) -y >/dev/null; done &&
      grep -rl --include='fil*' -m1 includedFrameworks /work/cab-official | head -1 | xargs cat" 2>/dev/null) || true
  fi
  NET_RT=$(echo "$out" | grep -A3 'Microsoft.NETCore.App' | grep -oE '"version": *"[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
  [[ "$NET_RT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not read the bundled .NET runtime from ${OFFICIAL_NAME}" $EXIT_INVALID_PARAMS
  echo "[INFO] Official build bundles .NET runtime ${NET_RT}"
}
# The highest SDK that ships that runtime (as wasabidesktop_build.sh does), from Microsoft's metadata.
resolve_sdk() {
  local out
  fetch_url "${DOTNET_META}/${NET_RT%.*}/releases.json" "logs/dotnet-releases.json" \
    || die "Could not download .NET ${NET_RT%.*} release metadata" $EXIT_INVALID_PARAMS
  out=$(helper_c python3 -c '
import json,sys
d=json.load(open("/work/logs/dotnet-releases.json"))
for r in d["releases"]:
    if r["runtime"]["version"]!=sys.argv[1]: continue
    s=sorted(r.get("sdks",[]),key=lambda s:[int(x) for x in s["version"].split(".")])[-1]
    f=[f for f in s["files"] if f.get("rid")=="win-x64" and f["name"].endswith(".zip")][0]
    print(s["version"],f["url"],f["hash"]); break' "$NET_RT" 2>/dev/null) \
    || die "Runtime ${NET_RT} not in Microsoft's metadata" $EXIT_INVALID_PARAMS
  read -r NET_SDK SDK_URL SDK_SHA <<< "$out"
  [[ -n "${SDK_SHA:-}" ]] || die "No SDK found for runtime ${NET_RT}" $EXIT_INVALID_PARAMS
  echo "[INFO] .NET SDK ${NET_SDK}: $(basename "$SDK_URL") sha512 ${SDK_SHA:0:16}..."
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
# Streams one file out of the VM, checked against the hash Windows printed for it.
vm_fetch() {
  local src="$1" dst="$2" want got
  want=$(awk -v n="$(basename "$dst")" '$1 == "HASH" && $3 == n {print $2}' "${WORK_DIR}/logs/vm-build.log")
  vm_ssh "powershell -NoProfile -Command \"\$s=[IO.File]::OpenRead('$src'); \$o=[Console]::OpenStandardOutput(); \$s.CopyTo(\$o); \$o.Flush()\"" \
    > "$dst" || die "Could not copy $(basename "$dst") out of the VM"
  got=$(sha256_of "$dst")
  [[ -n "$want" && "$got" == "$want" ]] || die "$(basename "$dst") copied out of the VM is corrupt (${got} vs ${want:-none})"
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

  VM_NAME="ws-wasabi-${RUN_ID}"
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

# Upstream's own release step: clone the tag at the runner's path (the compiler embeds it:
# official DLLs carry D:\a\WalletWasabi\WalletWasabi\...), UTC like GitHub's runners (zip and
# cabinet entries store local times), then Contrib/release.sh wininstaller under Git Bash.
# Its last step signs the MSI with Wasabi's Azure key; a stand-in only logs that call.
build_in_vm() {
  local log="${WORK_DIR}/logs/vm-build.log"
  echo "[INFO] Running Contrib/release.sh wininstaller inside the VM, ~15-20 min (log: logs/vm-build.log)..."
  local subst=(-e "s|@SDKURL@|${SDK_URL}|" -e "s|@SDKSHA@|${SDK_SHA}|" -e "s|@ZURL@|${SEVENZIP_URL}|"
    -e "s|@ZSHA@|${SEVENZIP_SHA256}|" -e "s|@VER@|${APP_VERSION}|")
  sed "${subst[@]}" << 'PSEOF' | vm_run build.ps1 2>&1 | tr -d '\r' > "$log" &
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
tzutil /s UTC
'TZ=' + (tzutil /g)
New-Item -ItemType Directory -Force C:\dl,C:\dotnet,C:\shim,C:\wix | Out-Null
curl.exe -sSfL -o C:\dl\sdk.zip '@SDKURL@'
if ($LASTEXITCODE) { throw 'download failed: sdk' }
if ((Get-FileHash C:\dl\sdk.zip -Algorithm SHA512).Hash -ne '@SDKSHA@'.ToUpper()) { throw 'sha512 mismatch: sdk' }
'SHA512 OK sdk'
Expand-Archive C:\dl\sdk.zip C:\dotnet -Force
curl.exe -sSfL -o C:\dl\7z.msi '@ZURL@'
if ($LASTEXITCODE) { throw 'download failed: 7-Zip' }
if ((Get-FileHash C:\dl\7z.msi -Algorithm SHA256).Hash -ne '@ZSHA@'.ToUpper()) { throw 'sha256 mismatch: 7-Zip' }
'SHA256 OK 7-Zip'
Start-Process msiexec.exe -Wait -ArgumentList '/a','C:\dl\7z.msi','/qn','TARGETDIR=C:\7zip'
$sz=(Get-ChildItem C:\7zip -Recurse -Filter 7z.exe | Select-Object -First 1).DirectoryName
$wb=(Get-ChildItem C:\wix314 -Recurse -Filter candle.exe | Select-Object -First 1).DirectoryName
cmd /c "mklink /J C:\wix\bin $wb" | Out-Null
[IO.File]::WriteAllText('C:\shim\azuresigntool', "#!/usr/bin/env bash`necho `"[stand-in] azuresigntool not run (no Wasabi key): `${@: -1}`"`n")
$env:DOTNET_ROOT='C:\dotnet'; $env:Path="C:\dotnet;$sz;C:\shim;"+$env:Path
$env:DOTNET_MULTILEVEL_LOOKUP='0'; $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'; $env:DOTNET_NOLOGO='1'
$env:RUNNER_OS='Windows'; $env:WIX='C:\wix\'
cmd /c "dotnet --list-sdks"
cmd /c "mkdir D:\a\WalletWasabi 2>nul & git clone -q --depth 1 --branch v@VER@ https://github.com/WalletWasabi/WalletWasabi D:\a\WalletWasabi\WalletWasabi 2>&1"
if ($LASTEXITCODE) { throw 'clone failed' }
Set-Location D:\a\WalletWasabi\WalletWasabi
'COMMIT=' + (git rev-parse HEAD)
$ErrorActionPreference='Continue'
& 'C:\Program Files\Git\bin\bash.exe' -c './Contrib/release.sh wininstaller' 2>&1 | ForEach-Object { "$_" } | Out-File -Encoding utf8 C:\dl\release.log
$rc=$LASTEXITCODE
'RELEASE-EXIT=' + $rc
Select-String -Path C:\dl\release.log -Pattern 'stand-in|error' | Select-Object -Last 5 | ForEach-Object { 'LOG ' + $_.Line }
if ($rc) { throw 'release.sh failed' }
tar.exe -cf C:\dl\win-x64.tar -C build win-x64
foreach ($f in @('C:\dl\win-x64.tar',"packages\Wasabi-@VER@.msi")) {
  'HASH ' + (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() + ' ' + (Split-Path $f -Leaf)
}
'BUILD-OK'
PSEOF
  BUILD_PID=$!
  wait "$BUILD_PID" || true
  BUILD_PID=""
  grep -E '^(TZ=|SHA512 OK|SHA256 OK|COMMIT=|RELEASE-EXIT=|LOG )' "$log" | sed 's/^/  /' || true
  grep -qx 'BUILD-OK' "$log" || ftbfs_die "The Windows build failed inside the VM; see logs/vm-build.log"
  local c; c=$(sed -n 's/^COMMIT=//p' "$log" | head -1)
  [[ ! "$c" =~ ^[0-9a-f]{40}$ ]] || RESOLVED_COMMIT="$c"
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

# Every file of the official zip against the built folder (union of both sides).
compare_files() {
  local oroot="$1" broot="$2" list="${WORK_DIR}/logs/file-compare.txt" rel oh bh
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
}

# MSI comparator: streams, decoded tables, cabinets, container. Each difference is printed by
# name in one of three groups: SET ASIDE (signature, PackageCode, build timestamps, cabinet
# file dates, storage order), RANDOM PER-BUILD IDS, OTHER. Exit 0 none left, 3 random IDs
# only, 1 other differences, 2 comparator error (never a verdict).
write_comparator() {
  cat > "${WORK_DIR}/msicmp.py" << 'MSICMP_END'
import sys, os, struct, re
from collections import Counter
NORM, RAND, DIFF = [], [], []
GUID = re.compile(rb'^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$')
class Bad(Exception): pass
def rd(d, n):
  p = os.path.join(d, n)
  return open(p, 'rb').read() if os.path.exists(p) else None
def dos(d, t):
  return '%04d-%02d-%02d %02d:%02d:%02d' % (1980 + (d >> 9), d >> 5 & 15, d & 31, t >> 11, t >> 5 & 63, (t & 31) * 2)

def cab(b, who):
  """Copy with only the per-file date/time fields zeroed, plus the entries."""
  if len(b) < 36 or b[:4] != b'MSCF': raise Bad(f'{who}: not a cabinet')
  cb, coff = struct.unpack_from('<I', b, 8)[0], struct.unpack_from('<I', b, 16)[0]
  nfiles, flags = struct.unpack_from('<HH', b, 28)
  if flags & 7: raise Bad(f'{who}: cabinet flags 0x{flags:04x} unsupported')
  if cb != len(b) or coff >= len(b): raise Bad(f'{who}: bad cabinet header')
  out, o, ents = bytearray(b), coff, []
  for i in range(nfiles):
    z = b.find(b'\0', o + 16)
    if o + 16 > len(b) or z < 0: raise Bad(f'{who}: CFFILE {i} truncated')
    d, t = struct.unpack_from('<HH', b, o + 10)
    ents.append((b[o+16:z], dos(d, t)))
    out[o+10:o+14] = b'\0\0\0\0'
    o = z + 1
  return bytes(out), ents

def compare_cab(name, x, y):
  nx, ex = cab(x, 'official ' + name); ny, ey = cab(y, 'built ' + name)
  if [e[0] for e in ex] != [e[0] for e in ey]:
    DIFF.append(f'{name}: entry names or order differ'); return
  if nx != ny:
    n = sum(1 for a, b in zip(nx, ny) if a != b) + abs(len(nx) - len(ny))
    DIFF.append(f'{name}: {n} byte(s) differ beyond the per-file date/time fields'); return
  dd = [(e[0].decode(), e[1], f[1]) for e, f in zip(ex, ey) if e[1] != f[1]]
  NORM.append(f'{name}: {len(ex)} files, contents identical; file dates differ in {len(dd)}'
              + (f', e.g. {dd[0][0]} {dd[0][1]} vs {dd[0][2]}' if dd else ''))

def summary(b, who):
  bo, _, _, _, nsets = struct.unpack_from('<HHI16sI', b, 0)
  if bo != 0xFFFE or nsets != 1: raise Bad(f'{who}: unsupported summary stream')
  off = struct.unpack_from('<I', b, 44)[0]
  cb, cprop = struct.unpack_from('<II', b, off)
  out, got = bytearray(b), []
  for i in range(cprop):
    pid, poff = struct.unpack_from('<II', b, off + 8 + i * 8)
    a = off + poff
    if pid == 9:
      n = struct.unpack_from('<I', b, a + 4)[0]
      m = re.search(rb'\{[0-9A-Fa-f\-]{36}\}', b[a + 8:a + 8 + n])
      if not m: raise Bad(f'{who}: PID_REVNUMBER holds no GUID')
      s = a + 8 + m.start(); out[s:s + 38] = b'\0' * 38; got.append(('PackageCode', m.group().decode()))
    elif pid in (12, 13):
      out[a + 4:a + 12] = b'\0' * 8; got.append((f'summary timestamp {pid}', ''))
  return bytes(out), got

def pool(d, who):
  sp, sd = rd(d, '!_StringPool'), rd(d, '!_StringData')
  if sp is None or sd is None or len(sp) % 4: raise Bad(f'{who}: string pool missing or malformed')
  hdr = struct.unpack_from('<I', sp, 0)[0]
  strings, refs, o, i, n = [b''], [0], 0, 1, len(sp) // 4
  while i < n:
    z, r = struct.unpack_from('<HH', sp, i * 4)
    if z == 0 and r:
      i += 1
      if i >= n: raise Bad(f'{who}: truncated long string')
      z2, r2 = struct.unpack_from('<HH', sp, i * 4); z, r = z2 | (r << 16), r2
    if o + z > len(sd): raise Bad(f'{who}: string {i} past the data')
    strings.append(sd[o:o + z]); refs.append(r); o += z; i += 1
  if o != len(sd): raise Bad(f'{who}: unreferenced string data')
  return strings, refs, 3 if hdr & 0x80000000 else 2

def schema(d, s, who):
  raw = rd(d, '!_Columns')
  if raw is None or len(raw) % 8: raise Bad(f'{who}: !_Columns missing or malformed')
  n = len(raw) // 8; g = lambda c, i: struct.unpack_from('<H', raw, c * n * 2 + i * 2)[0]
  sc = {}
  for i in range(n):
    tn = s[g(0, i)]
    if not re.fullmatch(rb'[A-Za-z0-9_.]+', tn): raise Bad(f'{who}: bad table name {tn!r}')
    sc.setdefault(tn.decode(), []).append((g(1, i) - 0x8000, s[g(2, i)].decode(), g(3, i) - 0x8000))
  for t in sc: sc[t].sort()
  return sc

def catalog(d, p, who):
  """!_Tables: one string reference per table name."""
  raw, w = rd(d, '!_Tables'), p[2]
  if raw is None or len(raw) % w: raise Bad(f'{who}: !_Tables missing or malformed')
  ids = [int.from_bytes(raw[i:i + w], 'little') for i in range(0, len(raw), w)]
  if not all(0 < i < len(p[0]) for i in ids): raise Bad(f'{who}: !_Tables string out of range')
  return [p[0][i].decode('ascii', 'replace') for i in ids]

def decode(d, t, cols, s, width, who):
  raw = rd(d, '!' + t)
  if raw is None: return None
  w = [width if c[2] & 0x800 else (2 if (c[2] & 0xff) == 2 else 4) for c in cols]
  if not sum(w) or len(raw) % sum(w): raise Bad(f'{who}: table {t} has a bad length')
  m, base, cv = len(raw) // sum(w), 0, []
  for c, x in zip(cols, w):
    v = []
    for k in range(m):
      o = base + k * x
      q = struct.unpack_from('<H', raw, o)[0] if x == 2 else int.from_bytes(raw[o:o + x], 'little')
      v.append(None if q == 0 else s[q] if c[2] & 0x800 else (q - 0x8000 if x == 2 else q ^ 0x80000000))
    cv.append(v); base += m * x
  return [tuple(cv[c][k] for c in range(len(cols))) for k in range(m)]

def run(A, B):
  fa, fb = set(os.listdir(A)), set(os.listdir(B))
  for f in sorted(fa ^ fb):
    if f in ('[5]DigitalSignature', '[5]MsiDigitalSignatureEx'):
      NORM.append(f'publisher signature stream {f}: official only (Authenticode)')
    else: DIFF.append(f'stream on one side only: {f}')
  pa, pb = pool(A, 'official'), pool(B, 'built')
  sa, sb = schema(A, pa[0], 'official'), schema(B, pb[0], 'built')
  if set(sa) != set(sb): DIFF.append(f'table set differs: {sorted(set(sa) ^ set(sb))}')
  ca, cb = catalog(A, pa, 'official'), catalog(B, pb, 'built')
  bad = False
  if Counter(ca) != Counter(cb): DIFF.append(f'table catalog (!_Tables) differs: {sorted(set(ca) ^ set(cb))}'); bad = True
  for who, c, sc in (('official', ca, sa), ('built', cb, sb)):
    if set(c) != set(sc): DIFF.append(f'{who}: !_Tables and !_Columns list different tables'); bad = True
  if not bad:
    NORM.append(f'table catalog (!_Tables): {len(ca)} tables on both sides, same as !_Columns'
                + ('; storage order differs' if ca != cb else ''))
  ids = set(); acc = {'!_StringPool', '!_StringData', '!_Columns', '!_Tables'}
  for t in sorted(set(sa) & set(sb)):
    acc.add('!' + t)
    if sa[t] != sb[t]: DIFF.append(f'table {t}: schema differs'); continue
    ra, rb = decode(A, t, sa[t], pa[0], pa[2], 'official'), decode(B, t, sb[t], pb[0], pb[2], 'built')
    if (ra is None) != (rb is None): DIFF.append(f'table {t}: on one side only'); continue
    if ra is None or Counter(ra) == Counter(rb): continue
    ka, kb = {r[0]: r for r in ra}, {r[0]: r for r in rb}
    if len(ka) != len(ra) or set(ka) != set(kb):
      DIFF.append(f'table {t}: rows added/removed ({len(set(ka) ^ set(kb))} keys on one side only)'); continue
    cols = Counter(); rows = []
    for k in ka:
      dc = [i for i in range(len(sa[t])) if ka[k][i] != kb[k][i]]
      if dc: rows.append((k, dc)); cols.update(sa[t][i][1] for i in dc)
    rnd = all(len(dc) == 1 and all(v and GUID.match(v) for v in (ka[k][dc[0]], kb[k][dc[0]])) for k, dc in rows)
    if rnd and ((t == 'Component' and set(cols) == {'ComponentId'}) or (t == 'Property' and [k for k, _ in rows] == [b'ProductCode'])):
      for k, dc in rows: ids.update((ka[k][dc[0]], kb[k][dc[0]]))
      k, dc = rows[0]
      RAND.append(f'{t}.{sa[t][dc[0]][1]}: {len(rows)} of {len(ra)} rows, a new GUID each build, '
                  f'e.g. {k.decode()} {ka[k][dc[0]].decode()} vs {kb[k][dc[0]].decode()}')
    else:
      for k, dc in rows[:5]:
        DIFF.append(f'table {t} row {k!r}: ' + '; '.join(f'{sa[t][i][1]} {ka[k][i]!r} vs {kb[k][i]!r}' for i in dc))
      if len(rows) > 5: DIFF.append(f'table {t}: ... {len(rows) - 5} more differing rows (columns {dict(cols)})')
  ea, eb = Counter(zip(pa[0][1:], pa[1][1:])), Counter(zip(pb[0][1:], pb[1][1:]))
  dp = (ea - eb) + (eb - ea)
  if dp:
    other = [s for s, _ in dp if s not in ids]
    if other: DIFF.append(f'string pool: {len(other)} entries differ that no table difference explains, e.g. {other[:3]}')
    else: RAND.append(f'string pool: {sum(dp.values())} entries differ, all of them the GUIDs above')
  elif rd(A, '!_StringPool') != rd(B, '!_StringPool'): NORM.append('string pool storage order (same entries)')
  for f in sorted(fa & fb):
    if f in acc: continue
    x, y = rd(A, f), rd(B, f)
    if x == y: continue
    if f == '[5]SummaryInformation':
      nx, gx = summary(x, 'official'); ny, gy = summary(y, 'built')
      if nx != ny: DIFF.append('summary information differs beyond PackageCode and timestamps')
      else: NORM.extend(f'{a} {v} vs {w}' if v else a for (a, v), (_, w) in zip(gx, gy))
    elif f.endswith('.cab'): compare_cab(f, x, y)
    elif f.startswith('!'): DIFF.append(f'undecoded database stream differs: {f}')
    else: DIFF.append(f'stream differs: {f}')

def ole(path, who):
  """Places extraction cannot see: bytes past the last sector, data in free sectors."""
  b = open(path, 'rb').read()
  if b[:8] != b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1': raise Bad(f'{who}: not a compound file')
  ss = 1 << struct.unpack_from('<H', b, 30)[0]; h, per = max(ss, 512), ss // 4
  d = list(struct.unpack_from('<109I', b, 76)); s = struct.unpack_from('<I', b, 68)[0]
  for _ in range(struct.unpack_from('<I', b, 72)[0]):
    if s >= 0xFFFFFFFA: break
    o = h + s * ss; d += struct.unpack_from('<%dI' % (per - 1), b, o); s = struct.unpack_from('<I', b, o + ss - 4)[0]
  fat = []
  for x in d[:struct.unpack_from('<I', b, 44)[0]]:
    if x < 0xFFFFFFFA: fat += struct.unpack_from('<%dI' % per, b, h + x * ss)
  n, tail = divmod(len(b) - h, ss)
  if tail and n < len(fat) and fat[n] == 0xFFFFFFFE: n, tail = n + 1, 0
  free = sum(1 for i in range(min(n, len(fat))) if fat[i] == 0xFFFFFFFF and any(b[h + i * ss:h + (i + 1) * ss]))
  return len(b), tail, free

if __name__ == '__main__':
  try:
    run(sys.argv[1], sys.argv[2])
    for who, pth in (('official', sys.argv[3]), ('built', sys.argv[4])):
      size, tail, free = ole(pth, who)
      if tail or free: DIFF.append(f'{who} MSI container: {tail} B past the last sector, {free} free sector(s) holding data')
      else: NORM.append(f'{who} MSI container ({size} B): nothing past the last sector, no data in free sectors')
  except Exception as e: print(f'COMPARATOR ERROR: {type(e).__name__}: {e}', file=sys.stderr); sys.exit(2)
  for title, items in (('OTHER DIFFERENCES', DIFF), ('RANDOM PER-BUILD IDS', RAND),
                       ('SET ASIDE OR CHECKED (signature, PackageCode, timestamps, cabinet dates, container)', NORM)):
    print(f'  {title}:' + ('' if items else ' none'))
    for m in items: print('    - ' + m)
  sys.exit(1 if DIFF else 3 if RAND else 0)
MSICMP_END
}

compare_msi() {
  local bmsi="${WORK_DIR}/built/Wasabi-${APP_VERSION}.msi"
  write_comparator
  helper_c bash -c "7z x -tCompound '/work/built/Wasabi-${APP_VERSION}.msi' -o/work/ex-built -y >/dev/null" \
    || ftbfs_die "Could not extract the built MSI"
  echo ""
  echo "[INFO] === MSI Comparison (official vs built Wasabi-${APP_VERSION}.msi) ==="
  echo "[INFO] official sha256: $(sha256_of "${WORK_DIR}/official/${OFFICIAL_NAME}")  $(stat -c %s "${WORK_DIR}/official/${OFFICIAL_NAME}") B"
  echo "[INFO] built    sha256: ${BUILT_SHA}  $(stat -c %s "$bmsi") B"
  MSI_RC=0
  helper_c python3 /work/msicmp.py /work/ex-official /work/ex-built "/work/official/${OFFICIAL_NAME}" \
    "/work/built/Wasabi-${APP_VERSION}.msi" > "${WORK_DIR}/logs/msi-compare.txt" 2>&1 || MSI_RC=$?
  echo "[INFO] Comparator exit ${MSI_RC}; the full output is printed in full right before the results."
  [[ "$MSI_RC" -ne 2 ]] || ftbfs_die "MSI comparator failed; this is a tool error, not a verdict"
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
    WORK_DIR="${execution_dir}/wasabiwindows_verification_${version_component}_${APP_TYPE}_${RUN_ID}"
    mkdir "$WORK_DIR" || die "Could not create ${WORK_DIR}" $EXIT_INVALID_PARAMS
  fi
  results_file="${WORK_DIR}/COMPARISON_RESULTS.yaml"
  mkdir -p "$WORK_DIR/logs" "$WORK_DIR/official" "$WORK_DIR/built" "$WORK_DIR/official-extracted"
  cd "$WORK_DIR"
  # Cleanup runs on every exit path. A stopped run (130) writes no verdict.
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  echo "======================================================"
  echo "Wasabi Wallet v${APP_VERSION} — Windows ${APP_TYPE} Verification"
  echo "======================================================"
  "$DOCKER_CMD" image inspect "${HELPER_IMAGE}" >/dev/null 2>&1 || build_helper

  if [[ "$APP_TYPE" == "zip" ]]; then OFFICIAL_NAME="Wasabi-${APP_VERSION}-win-x64.zip"
  else OFFICIAL_NAME="Wasabi-${APP_VERSION}.msi"; fi
  local otgt="${WORK_DIR}/official/${OFFICIAL_NAME}"
  if [[ -n "$BINARY_PATH" ]]; then
    echo "[INFO] Using provided ${APP_TYPE}: $(basename "$BINARY_PATH")"
    cp "$BINARY_PATH" "$otgt"
  else
    echo "[INFO] Downloading ${OFFICIAL_NAME}..."
    fetch_release_asset "$OFFICIAL_NAME" || die "Could not download ${OFFICIAL_NAME}" $EXIT_INVALID_PARAMS
    BINARY_SOURCE="downloaded from WalletWasabi/WalletWasabi releases"
  fi
  echo "[INFO] Official sha256: $(sha256_of "$otgt")"
  verify_official_signature "$OFFICIAL_NAME"
  read_runtime
  resolve_sdk

  start_vm
  build_in_vm
  [[ "$RESOLVED_COMMIT" != "unknown" ]] || ftbfs_die "Could not read the commit the VM built"
  vm_fetch 'C:\dl\win-x64.tar' "${WORK_DIR}/built/win-x64.tar"
  [[ "$APP_TYPE" != "msi" ]] || vm_fetch "D:\\a\\WalletWasabi\\WalletWasabi\\packages\\Wasabi-${APP_VERSION}.msi" \
    "${WORK_DIR}/built/Wasabi-${APP_VERSION}.msi"
  echo "[INFO] Build copied out of the VM; sha256 matches Windows' own hash"
  "$DOCKER_CMD" rm -f "$VM_NAME" >/dev/null 2>&1 && VM_NAME=""
  helper_c tar -xf /work/built/win-x64.tar -C /work/built && rm -f "${WORK_DIR}/built/win-x64.tar"

  local verdict note
  if [[ "$APP_TYPE" == "zip" ]]; then
    helper_c unzip -q "/work/official/${OFFICIAL_NAME}" -d /work/official-extracted
    echo ""
    echo "[INFO] === File Comparison (official zip vs built win-x64 folder) ==="
    compare_files "${WORK_DIR}/official-extracted" "${WORK_DIR}/built/win-x64"
    echo "[INFO] Not compared: the zip container itself (entry dates = checkout/build time)."
    if [[ "$CMP_BAD" -eq 0 && "$CMP_TOTAL" -gt 0 ]]; then
      verdict="reproducible"
      note="All ${CMP_TOTAL} files of ${OFFICIAL_NAME} are identical to the build (release.sh wininstaller, Windows Server 2022 VM, .NET SDK ${NET_SDK}). The zip container was not compared."
    else
      verdict="not_reproducible"
      note="${CMP_BAD} of ${CMP_TOTAL} files differ between ${OFFICIAL_NAME} and the build; full list in logs/file-compare.txt."
    fi
  else
    BUILT_SHA=$(sha256_of "${WORK_DIR}/built/Wasabi-${APP_VERSION}.msi")
    compare_msi
    if [[ "$MSI_RC" -eq 0 || ( "$MSI_RC" -eq 3 && "$MSI_ACCEPT_RANDOM_IDS" == "yes" ) ]]; then
      verdict="reproducible"
      note="${OFFICIAL_NAME}: every table, stream and cabinet file matches the build once the publisher signature, PackageCode, build timestamps and cabinet file dates are set aside$([[ "$MSI_RC" -eq 3 ]] && echo ', and the random per-build IDs')."
    elif [[ "$MSI_RC" -eq 3 ]]; then
      verdict="not_reproducible"
      note="${OFFICIAL_NAME}: all cabinet files match, but the MSI carries random per-build IDs (ProductCode, component GUIDs) that a rebuild cannot reproduce; listed under RANDOM PER-BUILD IDS."
    else
      verdict="not_reproducible"
      note="${OFFICIAL_NAME}: differences remain beyond the set-aside items; listed under OTHER DIFFERENCES (logs/msi-compare.txt)."
    fi
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
  if [[ "$APP_TYPE" == "zip" ]]; then
    echo "  builtHash   not applicable: the build is a folder, compared file by file."
  else
    echo "  builtHash   our unsigned MSI; it can never equal the signed official one."
  fi
  echo "  scriptHash  this script: which tooling produced these results."
}
emit_verification_summary() {
  local yaml_verdict official_sha match_flag=0 match_word="DOESN'T MATCH" matches=0 mismatches=1 line
  yaml_verdict=$(grep "^verdict:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)
  official_sha=$(sha256_of "${WORK_DIR}/official/${OFFICIAL_NAME}")
  if [[ "$yaml_verdict" == "reproducible" ]]; then
    match_flag=1; matches=1; mismatches=0
    match_word=$([[ "$APP_TYPE" == "zip" ]] && echo "ALL ${CMP_TOTAL} FILES MATCH" || echo "MATCHES AFTER SET-ASIDE ITEMS")
  fi
  if [[ "$APP_TYPE" == "zip" ]]; then line="${CMP_OK}/${CMP_TOTAL} files identical"; else line="${BUILT_SHA}"; fi
  print_hash_legend
  # Full diff output, never truncated, right before the results block (Danny, 2026-10-17).
  echo ""
  echo "FULL DIFF OUTPUT"
  if [[ "$APP_TYPE" == "msi" ]]; then
    cat "${WORK_DIR}/logs/msi-compare.txt"
  else
    echo "  Files compared: ${CMP_TOTAL} (union of both sides), identical: ${CMP_OK}, differing: ${CMP_BAD}"
    grep '^DIFFER' "${WORK_DIR}/logs/file-compare.txt" | sed 's/^/    - /' || echo "    (no differing files)"
  fi
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
  echo "${OFFICIAL_NAME} - ${APP_ARCH} - ${line} - ${match_flag} (${match_word})"
  echo ""
  echo "SUMMARY"
  echo "total: 1"
  echo "matches: ${matches}"
  echo "mismatches: ${mismatches}"
  echo ""
  echo "Revision, tag (and its signature):"
  echo "tag:            v${APP_VERSION}"
  echo "commit:         ${RESOLVED_COMMIT}"
  echo ".NET:           runtime ${NET_RT} (from the official artifact), SDK ${NET_SDK}"
  echo ""
  echo "Signature Summary:"
  echo "official artifact: ${BINARY_SOURCE}"
  echo "SHA256SUMS signature: ${SIG_STATUS}"
  echo "pinned key: ${WASABI_KEY_FPR}"
  echo ""
  echo "===== End Results ====="
  local full="${WORK_DIR}/logs/msi-compare.txt"
  [[ "$APP_TYPE" == "msi" ]] || full="${WORK_DIR}/logs/file-compare.txt"
  echo ""
  echo "To copy the diff file locally:"
  echo "scp <user>@<build-host>:${full} ."
  if [[ "$APP_TYPE" == "zip" ]]; then
    echo ""
    echo "To compare the folders yourself:"
    echo "diff --recursive ${WORK_DIR}/official-extracted ${WORK_DIR}/built/win-x64"
  fi
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
Usage: $0 --version VERSION [--arch win64] [--type msi|zip] [--binary FILE]
  --arch    win64 (also x86_64-windows, win-x64); the only architecture
  --type    msi (Wasabi-<version>.msi) or zip (Wasabi-<version>-win-x64.zip); taken from --binary if omitted
  --binary  official MSI or win-x64 zip; checked against the signed SHA256SUMS
  Optional: --windows-dir DIR (golden image + VM key, default /var/lib/walletscrutiny-windows)
            --work-dir DIR  --no-verify-signature
Example: $0 --version 2.8.4 --arch win64 --type msi
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
  case "${APP_ARCH:-win64}" in
    win64|x86_64-windows|win-x64|windows) APP_ARCH="${APP_ARCH:-win64}" ;;
    *) die "Unsupported --arch '$APP_ARCH' (Windows only: win64); Linux is wasabidesktop_build.sh" $EXIT_INVALID_PARAMS ;;
  esac
  local inferred="" t
  # ABS passes a directory when the asset bundle holds several files: take the one for --type.
  if [[ -d "$BINARY_PATH" ]]; then
    for t in ${APP_TYPE:-msi zip}; do
      case "$t" in
        msi) [[ -f "${BINARY_PATH}/Wasabi-${APP_VERSION}.msi" ]] && { BINARY_PATH="${BINARY_PATH}/Wasabi-${APP_VERSION}.msi"; break; } ;;
        zip) [[ -f "${BINARY_PATH}/Wasabi-${APP_VERSION}-win-x64.zip" ]] && { BINARY_PATH="${BINARY_PATH}/Wasabi-${APP_VERSION}-win-x64.zip"; break; } ;;
      esac
    done
    [[ -f "$BINARY_PATH" ]] || die "--binary directory holds no Wasabi-${APP_VERSION} ${APP_TYPE:-msi or zip}" $EXIT_INVALID_PARAMS
    echo "[INFO] --binary is a directory; using $(basename "$BINARY_PATH")"
  fi
  if [[ -n "$BINARY_PATH" ]]; then
    [[ -f "$BINARY_PATH" ]] || die "--binary file does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
    case "$(basename "$BINARY_PATH")" in
      "Wasabi-${APP_VERSION}.msi") inferred="msi" ;;
      "Wasabi-${APP_VERSION}-win-x64.zip") inferred="zip" ;;
      *) die "--binary must be Wasabi-${APP_VERSION}.msi or Wasabi-${APP_VERSION}-win-x64.zip" $EXIT_INVALID_PARAMS ;;
    esac
  fi
  case "${APP_TYPE:-$inferred}" in
    msi|zip) APP_TYPE="${APP_TYPE:-$inferred}" ;;
    "") die "Missing --type (msi or zip)" $EXIT_INVALID_PARAMS ;;
    *) die "Unsupported --type '$APP_TYPE' (msi or zip)" $EXIT_INVALID_PARAMS ;;
  esac
  [[ -z "$inferred" || "$inferred" == "$APP_TYPE" ]] || die "--binary is a ${inferred}, but --type is ${APP_TYPE}" $EXIT_INVALID_PARAMS
}

main() {
  # Runs as a normal user only; root runs break the ownership guarantees.
  if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: Do not run this script as root; run it as a normal user." >&2
    exit $EXIT_INVALID_PARAMS
  fi
  echo ""
  echo "======================================================"
  echo "Wasabi Wallet Windows Reproducible Build Verifier ${SCRIPT_VERSION}"
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
