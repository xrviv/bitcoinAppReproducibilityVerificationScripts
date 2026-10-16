#!/bin/bash
# sparrowwindows_build.sh - Sparrow Wallet Windows (MSI/ZIP) Reproducible Build Verifier
# Version: v0.4.1
# Last modified on: 2026-10-16 (v0.4.1)
# Builds Sparrow in a throw-away copy of a Windows Server 2022 VM (dockur/windows, KVM) at
# D:\a\sparrow\sparrow and compares the MSI/ZIP with the signed official release. Needs /dev/kvm,
# the golden image and VM key (--windows-dir; runbook: GitLab #984). Linux: sparrowdesktop_build.sh.
# The MSI comparator prints everything it sets aside, and its scope.
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#
set -euo pipefail

SCRIPT_VERSION="v0.4.1"
APP_ID="sparrow"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_SHA256=""
RESOLVED_COMMIT="unknown"

HELPER_IMAGE="sparrow-win-helper:0.4"
DOCKUR_IMAGE="docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea"
WIN_DIR="${WIN_DIR:-/var/lib/walletscrutiny-windows}"
VM_NAME=""
VM_PORT=""
BUILD_PID=""

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

# Trust anchor: the fingerprint is the pin, the vendored key only a convenience.
SPARROW_KEY_FPR="D4D0D3202FC06849A257B38DE94618334C674B40"
SPARROW_KEY_URL="https://keybase.io/craigraw/pgp_keys.asc"
SPARROW_RELEASE_BASE="https://github.com/sparrowwallet/sparrow/releases/download"

# JDK inside the golden image; a release needing another JDK needs a new golden image.
DEFAULT_JDK_VERSION="25.0.2+10"
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

# Never fatal: a hashing problem is not a build outcome.
sha256_of() {
  [[ -f "$1" ]] || { echo "N/A"; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

die() {
  echo "ERROR: $1" >&2
  exit "${2:-$EXIT_BUILD_FAILED}"
}
warn() {
  echo "WARN: $1" >&2
}
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
is_windows_arch() {
  case "${1:-}" in
    x86_64-windows|win-x64|win64|windows) return 0 ;;
    *) return 1 ;;
  esac
}
build_helper() {
  echo "[INFO] Building helper container..."
  "$DOCKER_CMD" build -t "${HELPER_IMAGE}" - << 'HEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
&& apt-get install -y --no-install-recommends curl ca-certificates gnupg unzip p7zip-full python3-minimal openssh-client \
&& rm -rf /var/lib/apt/lists/*
HEOF
}
# Helper writes land under /work (= WORK_DIR); restore_host_owner hands them back.
helper_c() {
  "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/work" -w /work \
    --entrypoint "$1" "${HELPER_IMAGE}" "${@:2}"
}
fetch_url() { helper_c curl -fsSL -o "/work/official/$2" "$1" 2>/dev/null; }

# The key is FETCHED, never trusted: VALIDSIG carries the primary fingerprint of whoever
# actually signed, asserted against SPARROW_KEY_FPR, so the download path need not be
# trusted. Keyring is ephemeral in WORK_DIR; ~/.gnupg would pass unreproducibly.
verify_official_signature() {
  local art="$1"
  if [[ "$SKIP_SIG_VERIFY" == true ]]; then
    SIG_STATUS="SKIPPED (--no-verify-signature)"
    warn "Signature verification skipped."
    return 0
  fi

  local man="sparrow-${APP_VERSION}-manifest.txt" od="${WORK_DIR}/official"
  echo "[INFO] Verifying ${art} against the signed manifest..."

  local f
  for f in "$man" "${man}.asc"; do
    [[ -f "${od}/${f}" ]] || fetch_release_asset "$f" \
      || die "Could not download ${f}" $EXIT_INVALID_PARAMS
  done
  fetch_url "$SPARROW_KEY_URL" "signing-key.asc" \
    || die "Could not download the signing key" $EXIT_INVALID_PARAMS

  helper_c bash -c "
    export GNUPGHOME=/work/gnupg
    mkdir -p \"\$GNUPGHOME\" && chmod 700 \"\$GNUPGHOME\"
    gpg --batch --no-tty -q --import /work/official/signing-key.asc
    gpg --batch --no-tty --status-fd 1 --verify \
      '/work/official/${man}.asc' '/work/official/${man}'
  " > "${WORK_DIR}/logs/gpg-verify.txt" 2>&1 || true

  if ! grep -q "VALIDSIG ${SPARROW_KEY_FPR}" "${WORK_DIR}/logs/gpg-verify.txt"; then
    SIG_STATUS="FAILED (manifest not signed by pinned key)"
    sed -n '1,20p' "${WORK_DIR}/logs/gpg-verify.txt" >&2
    die "Manifest signature check FAILED for ${man}" $EXIT_INVALID_PARAMS
  fi
  echo "[INFO]   manifest signed by pin ${SPARROW_KEY_FPR}"

  local want got
  want=$(awk -v n="*${art}" '$2 == n {print $1; exit}' "${od}/${man}")
  [[ -n "$want" ]] || { SIG_STATUS="FAILED (${art} absent from manifest)"
    die "${art} has no entry in ${man}" $EXIT_INVALID_PARAMS; }
  got=$(sha256_of "${od}/${art}")
  if [[ "$want" != "$got" ]]; then
    SIG_STATUS="FAILED (sha256 vs signed manifest)"
    die "${art} sha256 ${got} != manifest ${want}" $EXIT_INVALID_PARAMS
  fi
  SIG_STATUS="VERIFIED (pinned key; sha256 matches)"
  echo "[INFO]   sha256 matches manifest entry"
}

# One release asset into official/. Never fatal; callers decide.
fetch_release_asset() {
  fetch_url "${SPARROW_RELEASE_BASE}/${APP_VERSION}/$1" "$1"
}
compare_extracted() {
  local listing="$1" oroot="$2" broot="$3"
  local rel oh bh st idx=0
  CMP_TOTAL=$(wc -l < "$listing" | tr -d ' ')
  CMP_OK=0
  CMP_BAD=0
  while IFS= read -r rel; do
    idx=$((idx + 1))
    oh="(missing)"; bh="(missing)"
    [[ -f "${oroot}/${rel#./}" ]] && oh=$(sha256_of "${oroot}/${rel#./}")
    [[ -f "${broot}/${rel#./}" ]] && bh=$(sha256_of "${broot}/${rel#./}")
    if [[ "$oh" == "$bh" ]]; then
      st="✓ MATCH"; CMP_OK=$((CMP_OK + 1))
    else
      st="⚠ DIFFER"; CMP_BAD=$((CMP_BAD + 1))
    fi
    printf "  %3d/%-3d: %s\n" "$idx" "$CMP_TOTAL" "${rel#./}"
    echo "            Official: ${oh}"
    echo "            Built:    ${bh}"
    echo "            Status:   ${st}"
    echo ""
  done < "$listing"
}

# Writes the normalized MSI comparator into the work directory. Its allowlist is
# five classes wide and every item it removes is printed by name; anything else
# fails the run, and malformed input is an error rather than a verdict.
write_comparator() {
  cat > "${WORK_DIR}/msicmp.py" << 'MSICMP_END'
#!/usr/bin/env python3
"""Normalized comparison of two MSI installers: named streams, decoded database
tables, and - when the .msi paths are given - the OLE container itself.
Exit 0 equivalent, 1 differences remain, 2 comparator error (never a verdict).
"""
import sys, os, struct, re
from collections import Counter

NORM, DIFF = [], []
def norm(m): NORM.append(m)
def diff(m): DIFF.append(m)
class Bad(Exception):
  """Malformed or unsupported input. Never a verdict about the artifact."""

def rd(d, n):
  p = os.path.join(d, n)
  if not os.path.exists(p): return None
  with open(p, 'rb') as f: return f.read()

# -- cabinet
def cab_normalized(b, who):
  """Copy of the cabinet with only the per-file date/time fields zeroed; every
  other byte (header, folders, data, checksums, names, padding) left intact."""
  if len(b) < 36 or b[:4] != b'MSCF':
    raise Bad(f'{who}: not a cabinet')
  (_, r1, cbCab, r2, coffFiles, r3, vmin, vmaj,
  cFolders, cFiles, flags, setID, iCab) = struct.unpack_from('<4sIIIIIBBHHHHH', b, 0)
  if flags & 0x0004:
    raise Bad(f'{who}: cabinet reserve fields (flags=0x{flags:04x}) unsupported')
  if flags & 0x0003:
    raise Bad(f'{who}: multi-cabinet set (flags=0x{flags:04x}) unsupported')
  if cbCab != len(b):
    raise Bad(f'{who}: header size {cbCab} != actual {len(b)}')
  if coffFiles >= len(b):
    raise Bad(f'{who}: coffFiles {coffFiles} out of bounds')
  out = bytearray(b)
  o, names = coffFiles, []
  for i in range(cFiles):
    if o + 16 > len(b):
      raise Bad(f'{who}: CFFILE {i} truncated')
    z = b.find(b'\0', o + 16)
    if z < 0:
      raise Bad(f'{who}: CFFILE {i} name unterminated')
    names.append(b[o+16:z])
    # CFFILE: cbFile(4) uoffFolderStart(4) iFolder(2) date(2) time(2) attribs(2)
    out[o+10:o+14] = b'\0\0\0\0'      # date and time only; attribs left intact
    o = z + 1
  return bytes(out), cFiles, names

def compare_cabinet(x, y):
  nx, cx, names_x = cab_normalized(x, 'official cabinet')
  ny, cy, names_y = cab_normalized(y, 'built cabinet')
  if cx != cy:
    diff(f'cabinet file count differs: {cx} vs {cy}'); return
  if names_x != names_y:
    diff('cabinet entry names or their order differ'); return
  if nx == ny:
    norm(f'cabinet per-file date/time fields ({cx} entries); all other cabinet bytes identical')
  else:
    n = sum(1 for a, b in zip(nx, ny) if a != b) + abs(len(nx) - len(ny))
    diff(f'cabinet differs in {n} byte(s) beyond the per-file date/time fields')

# -- summary information
PID_REVNUMBER, PID_CREATE_DTM, PID_LASTSAVE_DTM = 9, 12, 13
VT_LPSTR, VT_FILETIME = 30, 64

def summary_normalized(b, who):
  """Zero exactly the PackageCode GUID and the two FILETIME payloads in a copy, with
  a note of what was blanked; every other byte of the stream is left alone."""
  if len(b) < 48: raise Bad(f'{who}: summary stream too short')
  bo, fmt, osv, clsid, nsets = struct.unpack_from('<HHI16sI', b, 0)
  if bo != 0xFFFE: raise Bad(f'{who}: bad property-set byte order 0x{bo:04x}')
  if nsets != 1:
    raise Bad(f'{who}: {nsets} property sets; exactly one supported')
  if 28 + 20 > len(b): raise Bad(f'{who}: section table out of bounds')
  fmtid, off = struct.unpack_from('<16sI', b, 28)
  if off + 8 > len(b): raise Bad(f'{who}: section offset out of bounds')
  cb, cprop = struct.unpack_from('<II', b, off)
  if cb < 8 or off + cb > len(b): raise Bad(f'{who}: section length out of bounds')
  out, blanked, seen = bytearray(b), [], set()
  for i in range(cprop):
    po = off + 8 + i * 8
    if po + 8 > off + cb: raise Bad(f'{who}: property index {i} out of bounds')
    pid, poff = struct.unpack_from('<II', b, po)
    if pid in seen: raise Bad(f'{who}: duplicate property id {pid}')
    seen.add(pid)
    a = off + poff
    if a + 4 > off + cb: raise Bad(f'{who}: property {pid} value out of bounds')
    vt = struct.unpack_from('<I', b, a)[0]
    if pid == PID_REVNUMBER:
      if vt != VT_LPSTR: raise Bad(f'{who}: PID_REVNUMBER type {vt}, expected VT_LPSTR')
      n = struct.unpack_from('<I', b, a + 4)[0]
      if a + 8 + n > off + cb: raise Bad(f'{who}: PackageCode string out of bounds')
      m = re.search(rb'\{[0-9A-Fa-f\-]{36}\}', b[a + 8:a + 8 + n])
      if not m: raise Bad(f'{who}: PID_REVNUMBER holds no GUID')
      s = a + 8 + m.start()
      out[s:s + 38] = b'\0' * 38
      blanked.append(('PackageCode (PID_REVNUMBER)', m.group().decode()))
    elif pid in (PID_CREATE_DTM, PID_LASTSAVE_DTM):
      if vt != VT_FILETIME: raise Bad(f'{who}: property {pid} type {vt}, expected VT_FILETIME')
      if a + 12 > off + cb: raise Bad(f'{who}: FILETIME {pid} out of bounds')
      out[a + 4:a + 12] = b'\0' * 8      # exactly the 8-byte FILETIME payload
      blanked.append((f'summary timestamp property {pid}', None))
  return bytes(out), blanked

def compare_summary(x, y):
  nx, bx = summary_normalized(x, 'official summary')
  ny, by = summary_normalized(y, 'built summary')
  if [k for k, _ in bx] != [k for k, _ in by]:
    diff('summary-information: different set of normalizable properties'); return
  if nx == ny:
    for (label, val), (_, val2) in zip(bx, by):
      norm(f'{label} {val} vs {val2}' if val else label)
  else:
    n = sum(1 for a, b in zip(nx, ny) if a != b) + abs(len(nx) - len(ny))
    diff(f'summary-information differs in {n} byte(s) outside the PackageCode GUID '
      f'and the two FILETIME payloads')

# -- string pool
def pool(d, who):
  sp, sd = rd(d, '!_StringPool'), rd(d, '!_StringData')
  if sp is None or sd is None: raise Bad(f'{who}: string pool or data stream missing')
  if len(sp) % 4: raise Bad(f'{who}: string pool length {len(sp)} not a multiple of 4')
  hdr = struct.unpack_from('<I', sp, 0)[0]
  width = 3 if hdr & 0x80000000 else 2
  codepage = hdr & 0x7FFFFFFF
  strings, refs, o, i, n = [b''], [0], 0, 1, len(sp) // 4
  while i < n:
    z, r = struct.unpack_from('<HH', sp, i * 4)
    if z == 0 and r:
      i += 1
      if i >= n: raise Bad(f'{who}: truncated long-string entry')
      z2, r2 = struct.unpack_from('<HH', sp, i * 4); z, r = z2 | (r << 16), r2
    if o + z > len(sd): raise Bad(f'{who}: string {i} runs past the string data')
    strings.append(sd[o:o + z]); refs.append(r); o += z; i += 1
  if o != len(sd):
    raise Bad(f'{who}: {len(sd) - o} unreferenced byte(s) at the end of the string data')
  return strings, refs, width, codepage

def compare_pools(a, b, raw_differs):
  """Compare pools as a multiset of (string bytes, that entry's own refcount).
  Summing refcounts per string would hide a redistribution across duplicate
  entries, so each entry is kept whole."""
  sa, ra, wa, ca = a; sb, rb, wb, cb = b
  bad = False
  if ca != cb: diff(f'string pool codepage differs: {ca} vs {cb}'); bad = True
  if wa != wb: diff(f'string reference width differs: {wa} vs {wb}'); bad = True
  if len(sa) != len(sb):
    diff(f'string pool entry count differs: {len(sa)-1} vs {len(sb)-1}'); bad = True
  ea, eb = Counter(zip(sa[1:], ra[1:])), Counter(zip(sb[1:], rb[1:]))
  if ea != eb:
    d = (ea - eb) + (eb - ea)
    diff(f'string pool entries/refcounts differ in {sum(d.values())}, e.g. {sorted(d)[:3]!r}')
    bad = True
  if not bad and raw_differs:
    norm('string pool storage order (same entries, same individual reference counts)')

# -- tables
def catalog(d, p, who):
  """!_Tables: one string reference per table name."""
  raw, w = rd(d, '!_Tables'), p[2]
  if raw is None or len(raw) % w: raise Bad(f'{who}: !_Tables missing or malformed')
  ids = [int.from_bytes(raw[i:i + w], 'little') for i in range(0, len(raw), w)]
  if not all(0 < i < len(p[0]) for i in ids): raise Bad(f'{who}: !_Tables string out of range')
  return [p[0][i] for i in ids]

def schema(d, strings, who):
  raw = rd(d, '!_Columns')
  if raw is None: raise Bad(f'{who}: !_Columns missing')
  if len(raw) % 8: raise Bad(f'{who}: !_Columns length {len(raw)} not a multiple of 8')
  n = len(raw) // 8
  g = lambda c, i: struct.unpack_from('<H', raw, c * n * 2 + i * 2)[0]
  sc = {}
  for i in range(n):
    ti, ni = g(0, i), g(2, i)
    if ti >= len(strings) or ni >= len(strings):
      raise Bad(f'{who}: !_Columns row {i} references a string out of range')
    tn = strings[ti]
    # the table name becomes a filesystem path; require a strict ASCII identifier
    if not tn or not re.fullmatch(rb'[A-Za-z0-9_.]+', tn):
      raise Bad(f'{who}: table identifier {tn!r} not a strict ASCII identifier')
    sc.setdefault(tn, []).append((g(1, i) - 0x8000, strings[ni], g(3, i) - 0x8000))
  for t in sc: sc[t].sort()
  return sc

def decode(d, tname, cols, strings, width, who):
  """tname is the table's name as a str; the stream is '!' + that name."""
  raw = rd(d, '!' + tname)
  if raw is None: return None
  w = [width if c[2] & 0x800 else (2 if (c[2] & 0xff) == 2 else 4) for c in cols]
  rs = sum(w)
  if rs == 0: raise Bad(f'{who}: table {tname!r} has zero row size')
  if len(raw) % rs:
    raise Bad(f'{who}: table {tname!r} length {len(raw)} not a multiple of row size {rs}')
  m, base, colvals = len(raw) // rs, 0, []
  for c, x in zip(cols, w):
    vals = []
    for k in range(m):
      o = base + k * x
      q = (struct.unpack_from('<H', raw, o)[0] if x == 2 else
        (raw[o] | raw[o+1] << 8 | raw[o+2] << 16) if x == 3 else
        struct.unpack_from('<I', raw, o)[0])
      if q == 0: vals.append(None)
      elif c[2] & 0x800:
        if q >= len(strings): raise Bad(f'{who}: {tname!r} string index {q} out of range')
        vals.append(strings[q])          # raw bytes, never decoded
      else: vals.append(q - 0x8000 if x == 2 else q ^ 0x80000000)
    colvals.append(vals); base += m * x
  return [tuple(colvals[c][k] for c in range(len(cols))) for k in range(m)]

# -- container
FREE = 0xFFFFFFFF

# CFBF v4 pads the 512-byte header out to a whole sector, so sector 0 starts at ss,
# not at 512. Getting this wrong reports a phantom tail and misreads every chain.
def _hdr(ss): return max(ss, 512)

def _fat(b, ss):
  per, nf, h = ss // 4, struct.unpack_from('<I', b, 44)[0], _hdr(ss)
  d = list(struct.unpack_from('<109I', b, 76))
  s, n = struct.unpack_from('<I', b, 68)[0], struct.unpack_from('<I', b, 72)[0]
  for _ in range(n):
    if s >= 0xFFFFFFFA: break
    o = h + s * ss
    d += list(struct.unpack_from('<%dI' % (per - 1), b, o))
    s = struct.unpack_from('<I', b, o + ss - 4)[0]
  f = []
  for x in d[:nf]:
    if x < 0xFFFFFFFA: f += list(struct.unpack_from('<%dI' % per, b, h + x * ss))
  return f

def ole_map(path, who):
  """(total, ss, nsec, tail, non-empty free sectors, dated dir entries, partial). Stream
  names and contents are not re-derived here; run() already compares them from the
  extracted trees, so this covers only what extraction cannot expose."""
  b = open(path, 'rb').read()
  if b[:8] != b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1': raise Bad(f'{who}: not a compound file')
  ss = 1 << struct.unpack_from('<H', b, 30)[0]
  if ss not in (512, 4096): raise Bad(f'{who}: unsupported sector size {ss}')
  h, f = _hdr(ss), _fat(b, ss)
  nsec, tail = divmod(len(b) - h, ss)
  # jpackage's MSI stops at the last byte its final stream needs (signtool's rewrite pads).
  # A partial sector the FAT allocates as end of chain is stream content, already compared.
  part = 0
  if tail and nsec < len(f) and f[nsec] == 0xFFFFFFFE:
    nsec, tail, part = nsec + 1, 0, tail
  nzfree = sum(1 for i in range(min(nsec, len(f)))
        if f[i] == FREE and any(b[h + i * ss:h + (i + 1) * ss]))
  dt, seen, s = 0, set(), struct.unpack_from('<I', b, 48)[0]
  while s < 0xFFFFFFFA:
    if s in seen or s >= len(f): raise Bad(f'{who}: bad directory chain')
    seen.add(s)
    for k in range(ss // 128):
      o = h + s * ss + k * 128
      if 4 <= struct.unpack_from('<H', b, o + 64)[0] <= 64 and b[o + 66] == 2 \
       and b[o + 100:o + 116] != b'\0' * 16: dt += 1
    s = f[s]
  return len(b), ss, nsec, tail, nzfree, dt, part

def compare_container(pa, pb):
  """Named streams are compared above; metadata sectors are structural. That leaves
  three hiding places, checked here: past the final sector, unallocated sectors, and
  extra streams - plus directory-entry timestamps, reported for the same reason."""
  ma, mb = ole_map(pa, 'official'), ole_map(pb, 'built')
  print('CONTAINER')
  for w, m in (('official', ma), ('built', mb)):
    print(f'  {w}: {m[0]} B = {_hdr(m[1])} hdr + {m[2]} x {m[1]} sectors + {m[3]} tail; '
       f'{m[4]} non-empty free sector(s); {m[5]} dated directory entries'
       + (f'; final sector partial ({m[6]} B written)' if m[6] else ''))
  if ma[1] != mb[1]: diff(f'sector size differs: {ma[1]} vs {mb[1]}')
  if ma[3] or mb[3]: diff(f'bytes past the final sector: official {ma[3]}, built {mb[3]}')
  if ma[4] or mb[4]: diff(f'unallocated sectors carry data: official {ma[4]}, built {mb[4]}')
  if ma[5] or mb[5]: diff(f'directory entries carry timestamps: official {ma[5]}, built {mb[5]}')
  pad = (mb[1] - mb[6]) % mb[1] - (ma[1] - ma[6]) % ma[1]
  print(f'  size difference {ma[0] - mb[0]} B = {ma[0] - mb[0] - pad} B in whole sectors '
     f'(the publisher signature) + {pad} B final-sector padding')

# -- main
def run(A, B):
  fa, fb = set(os.listdir(A)), set(os.listdir(B))
  for f in sorted(fa ^ fb):
    if f == '[5]DigitalSignature':
      norm('Authenticode signature stream present on one side only')
    else:
      diff(f'stream present on one side only: {f}')

  pa, pb = pool(A, 'official'), pool(B, 'built')
  pool_raw_differs = (rd(A, '!_StringPool') != rd(B, '!_StringPool')
            or rd(A, '!_StringData') != rd(B, '!_StringData'))
  compare_pools(pa, pb, pool_raw_differs)
  sa, sb = schema(A, pa[0], 'official'), schema(B, pb[0], 'built')
  if set(sa) != set(sb):
    diff(f'table set differs: {sorted(set(sa) ^ set(sb))!r}')
  for t in sorted(set(sa) & set(sb)):
    if sa[t] != sb[t]:
      diff(f'schema differs for table {t.decode("ascii", "replace")}')
  ca, cb = catalog(A, pa, 'official'), catalog(B, pb, 'built')
  if Counter(ca) != Counter(cb): diff(f'table catalog (!_Tables) differs: {sorted(set(ca) ^ set(cb))!r}')
  elif ca != cb: norm('row storage order in table _Tables')
  for who, c, s in (('official', ca, sa), ('built', cb, sb)):
    if set(c) != set(s): diff(f'{who}: !_Tables and !_Columns list different tables')

  # every ! stream must be explicitly accounted for; nothing is skipped by pattern
  accounted = {'!_StringPool', '!_StringData', '!_Columns', '!_Tables'}
  for t in sorted(set(sa) & set(sb)):
    name = t.decode('ascii', 'replace')
    accounted.add('!' + name)
    ra = decode(A, name, sa[t], pa[0], pa[2], 'official')
    rb = decode(B, name, sb[t], pb[0], pb[2], 'built')
    if (ra is None) != (rb is None):
      diff(f'table {name} present on one side only'); continue
    if ra is None: continue
    if Counter(ra) != Counter(rb):
      keyed = ''
      if len(ra) == len(rb) and sa[t]:
        ka = {r[0]: r for r in ra}; kb = {r[0]: r for r in rb}
        if len(ka) == len(ra) and set(ka) == set(kb):
          c = Counter()
          for k in ka:
            for i, cn in enumerate(sa[t]):
              if ka[k][i] != kb[k][i]: c[cn[1].decode('ascii', 'replace')] += 1
          if c: keyed = ' in ' + ', '.join(f'{k}({v})' for k, v in c.items())
      diff(f'TABLE {name} rows differ{keyed}')
    elif ra != rb:
      norm(f'row storage order in table {name}')

  for f in sorted(fa & fb):
    if f in accounted: continue
    x, y = rd(A, f), rd(B, f)
    if x == y: continue
    if f == '[5]SummaryInformation': compare_summary(x, y)
    elif f == 'Data.cab': compare_cabinet(x, y)
    elif f.startswith('!'): diff(f'undecoded database stream differs: {f}')
    else: diff(f'stream differs: {f}')

  unseen = sorted(f for f in (fa & fb) if f.startswith('!') and f not in accounted)
  if unseen: diff(f'database streams not covered by the schema: {unseen}')

if __name__ == '__main__':
  if len(sys.argv) not in (3, 5):
    print('usage: msicmp.py <official-extract> <built-extract> [official.msi built.msi]', file=sys.stderr)
    sys.exit(2)
  try:
    run(sys.argv[1], sys.argv[2])
    if len(sys.argv) == 5: compare_container(sys.argv[3], sys.argv[4])
  except Bad as e:
    print(f'COMPARATOR ERROR: {e}', file=sys.stderr); sys.exit(2)
  except Exception as e:
    print(f'COMPARATOR ERROR: {type(e).__name__}: {e}', file=sys.stderr); sys.exit(2)
  print('NORMALIZED AWAY (allowlist: Authenticode signature, PackageCode, build')
  print('timestamps, table row order, string-pool storage order).')
  for m in NORM: print('  ~ ' + m)
  if not NORM: print('  (nothing)')
  print('DIFFERENCES:' if DIFF else 'DIFFERENCES: none')
  for m in DIFF: print('  ! ' + m)
  print()
  print('SCOPE: named streams, decoded tables, and the container map above. Container')
  print('metadata sectors (header, FAT/DIFAT, directory) are structural, derived from')
  print('the layout rather than authored, and are not compared byte-for-byte.')
  sys.exit(1 if DIFF else 0)
MSICMP_END
}

# True when the container engine runs rootless, where container UID 0 already maps to
# the invoking user. Test how the engine actually runs, never its executable name.
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
# (non-sudo-directories-guideline.md). Helpers bind-mount WORK_DIR and write as container
# root; under a rootful engine those land root-owned and the build-server account cannot
# remove them. Rootless, the caller IS container UID 0, so chown 0:0 there, numeric uid
# otherwise. Runs on failure too via the EXIT trap. Never fatal: a verdict already
# reached must not be lost to a cleanup problem.
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

# SSH into the VM from the helper container (host network reaches the 127.0.0.1-only port),
# so the host needs no ssh client. The key is this run's private 0600 copy.
vm_ssh() {
  "$DOCKER_CMD" run --rm -i --network host -v "${WORK_DIR}/vm/key:/key:ro" --entrypoint ssh \
    "${HELPER_IMAGE}" -i /key -p "$VM_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    Docker@127.0.0.1 "$@"
}

# Missing KVM, golden image or key is an environment problem, not a build outcome:
# exit 2, no verdict.
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

  VM_NAME="ws-sparrow-${RUN_ID}"
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
      echo "[INFO] Windows ready (attempt ${i})"; return 0
    fi
    sleep 10
  done
  die "Windows VM did not answer over SSH within 10 minutes" $EXIT_INVALID_PARAMS
}

# The release workflow's steps, in D:\a\sparrow\sparrow: clone the tag with submodules,
# point the Gradle wrapper at services.gradle.org, jpackage, packageZipDistribution.
# Backgrounded so INT/TERM interrupt the wait at once.
build_in_vm() {
  local log="${WORK_DIR}/logs/vm-build.log" c
  echo "[INFO] Building Sparrow ${APP_VERSION} inside the VM (log: logs/vm-build.log)..."
  sed "s/@VER@/${APP_VERSION}/" << 'PSEOF' | vm_ssh 'powershell -NoProfile -Command -' 2>&1 | tee "$log" &
$ErrorActionPreference='Stop'
cmd /c "mkdir D:\a\sparrow 2>nul & git clone -q --depth 1 --branch @VER@ --recurse-submodules --shallow-submodules https://github.com/sparrowwallet/sparrow D:\a\sparrow\sparrow 2>&1"
if ($LASTEXITCODE) { throw 'clone failed' }
Set-Location D:\a\sparrow\sparrow
'COMMIT=' + (git rev-parse HEAD)
$props='gradle/wrapper/gradle-wrapper.properties'
$c=Get-Content $props -Raw
$v=[regex]::Match($c,'gradle-(\d+\.\d+(?:\.\d+)?)-bin').Groups[1].Value
$c=[regex]::Replace($c,'distributionUrl=.*',"distributionUrl=https\://services.gradle.org/distributions/gradle-$v-bin.zip")
Set-Content $props $c -NoNewline
Write-Host "Patched to gradle-$v-bin.zip"
cmd /c "gradlew.bat -v 2>&1 && gradlew.bat --no-daemon jpackage 2>&1 && gradlew.bat --no-daemon packageZipDistribution 2>&1"
if ($LASTEXITCODE) { throw 'build failed' }
Get-ChildItem build\jpackage\*.msi,build\jpackage\*.zip | ForEach-Object { 'HASH ' + (Get-FileHash $_ -Algorithm SHA256).Hash.ToLower() + ' ' + $_.Name }
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

# Streams one artifact out of the VM and checks it against the hash Windows computed.
# A bad copy is a tool error, not a verdict.
fetch_from_vm() {
  local name="$1" dest="$2" want got ps
  want=$(awk -v n="$name" '$1 == "HASH" && $3 == n {print $2}' "${WORK_DIR}/logs/vm-build.log")
  ps=$(printf '$s=[IO.File]::OpenRead(%sD:\\a\\sparrow\\sparrow\\build\\jpackage\\%s%s); $o=[Console]::OpenStandardOutput(); $s.CopyTo($o); $o.Flush()' "'" "$name" "'")
  vm_ssh "powershell -NoProfile -Command $ps" > "$dest" || die "Could not copy ${name} out of the VM"
  got=$(sha256_of "$dest")
  [[ -n "$want" && "$got" == "$want" ]] || die "${name} copied out of the VM is corrupt (${got} vs ${want:-none})"
  echo "[INFO] ${name} copied out of the VM; sha256 matches Windows' own hash"
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
build_and_verify_windows() {
  local version_component execution_dir
  version_component=$(sanitize_component "$APP_VERSION")
  execution_dir="$(pwd -P)"
  RUN_ID="$(date +%s)-$$"

  # A new workspace per run in the caller's directory (per-run-workspace-guideline.md).
  if [[ -n "$CUSTOM_WORK_DIR" ]]; then
    WORK_DIR="$CUSTOM_WORK_DIR"
  else
    WORK_DIR="${execution_dir}/sparrowwindows_verification_${version_component}_${APP_TYPE}_${RUN_ID}"
    mkdir "$WORK_DIR" || die "Could not create ${WORK_DIR}" $EXIT_INVALID_PARAMS
  fi

  local log_dir="${WORK_DIR}/logs"
  local official_dir="${WORK_DIR}/official"
  local built_dir="${WORK_DIR}/built"
  local results_file="${WORK_DIR}/COMPARISON_RESULTS.yaml"

  mkdir -p "$WORK_DIR" "$log_dir" "$official_dir" "$built_dir"
  cd "$WORK_DIR"
  # Cleanup runs on every exit path. A stopped run (130) writes no verdict: ABS would
  # publish any YAML it finds.
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  echo "======================================================"
  echo "Sparrow Desktop v${APP_VERSION} — Windows ${APP_TYPE^^} Verification"
  echo "======================================================"
  echo ""

  if ! "$DOCKER_CMD" image inspect "${HELPER_IMAGE}" >/dev/null 2>&1; then
    build_helper
  fi
  write_comparator

  local oname="Sparrow-${APP_VERSION}.${APP_TYPE}"
  local otgt="${official_dir}/${oname}"

  if [[ -n "$BINARY_PATH" ]]; then
    echo "[INFO] Using provided ${APP_TYPE^^}: $(basename "$BINARY_PATH")"
    cp "$BINARY_PATH" "$otgt"
  else
    echo "[INFO] Downloading ${oname}..."
    fetch_release_asset "$oname" \
      || die "Could not download ${oname}" $EXIT_INVALID_PARAMS
    BINARY_SOURCE="downloaded from sparrowwallet/sparrow releases"
    echo "[INFO] Downloaded $(sha256_of "$otgt")"
  fi

  # Input-integrity problem, not a build outcome: no verdict.
  verify_official_signature "$oname"

  echo "[INFO] JDK in the golden image: Temurin ${DEFAULT_JDK_VERSION}"
  start_vm
  build_in_vm
  local built_type_dir="${built_dir}/${APP_TYPE}"
  mkdir -p "$built_type_dir"
  fetch_from_vm "$oname" "${built_type_dir}/${oname}"
  "$DOCKER_CMD" rm -f "$VM_NAME" >/dev/null 2>&1 && VM_NAME=""

  echo ""
  local msi_match=0 whole_match=0

  if [[ "$APP_TYPE" == "zip" ]]; then
    echo "[INFO] === ZIP Comparison ==="
    local built_zip_file
    built_zip_file=$(find "$built_type_dir" -name "*.zip" | head -1)
    [[ -n "$built_zip_file" ]] || ftbfs_die "Built ZIP file not found in downloaded artifact"

    local ozs bzs
    ozs=$(sha256_of "$otgt")
    bzs=$(sha256_of "$built_zip_file")
    echo "[INFO] ZIP official SHA256: $ozs"
    echo "[INFO] ZIP built    SHA256: $bzs"
    [[ "$ozs" == "$bzs" ]] && whole_match=1

    local official_zip_extract="${WORK_DIR}/official-zip-extracted"
    local built_zip_extract="${WORK_DIR}/built-zip-extracted"
    mkdir -p "$official_zip_extract" "$built_zip_extract"
    unzip -q "$otgt" -d "$official_zip_extract"
    unzip -q "$built_zip_file" -d "$built_zip_extract"

    # union of both extractions
    local zip_union="${WORK_DIR}/zip-union-files.txt"
    { (cd "$official_zip_extract" && find . -type f); (cd "$built_zip_extract" && find . -type f); } \
      | sort -u > "$zip_union"
    echo "[INFO] $(wc -l < "$zip_union" | tr -d ' ') files to verify (union of both extractions)"
    echo ""
    compare_extracted "$zip_union" "$official_zip_extract" "$built_zip_extract"
    rm -f "$zip_union"

    echo "[INFO] ZIP: ${CMP_OK}/${CMP_TOTAL} files verified"
    if [[ "$CMP_BAD" -eq 0 ]]; then
      echo "[INFO] ZIP: ALL FILES MATCH"
    else
      echo "[INFO] ZIP: MISMATCH — ${CMP_BAD} difference(s)"
    fi

  elif [[ "$APP_TYPE" == "msi" ]]; then
    echo "[INFO] === MSI Comparison ==="
    local built_msi_file
    built_msi_file=$(find "$built_type_dir" -name "*.msi" | head -1)
    [[ -n "$built_msi_file" ]] || ftbfs_die "Built MSI file not found in downloaded artifact"

    local official_msi_sha built_msi_sha
    official_msi_sha=$(sha256_of "$otgt")
    built_msi_sha=$(sha256_of "$built_msi_file")
    echo "[INFO] MSI official SHA256: ${official_msi_sha}"
    echo "[INFO] MSI built    SHA256: ${built_msi_sha}"
    if [[ "$official_msi_sha" == "$built_msi_sha" ]]; then
      whole_match=1; msi_match=1
      echo "[INFO] MSI: SHA256 MATCH - installers are byte-identical"
    else
      echo "[INFO] MSI: SHA256 differs; running normalized full-database comparison"
      local bn; bn=$(basename "$built_msi_file")
      "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/work" "${HELPER_IMAGE}" bash -c "
        7z x -tCompound /work/official/${oname} -o/work/ex-official -y >/dev/null 2>&1 &&
        7z x -tCompound /work/built/msi/${bn} -o/work/ex-built -y >/dev/null 2>&1" \
        || ftbfs_die "Extraction of one or both MSIs failed"
      [[ -n "$(ls -A "${WORK_DIR}/ex-official" 2>/dev/null)" && -n "$(ls -A "${WORK_DIR}/ex-built" 2>/dev/null)" ]] \
        || ftbfs_die "MSI extraction produced no streams on one or both sides"

      echo ""
      local cmp_rc=0
      "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/work" "${HELPER_IMAGE}" \
        python3 /work/msicmp.py /work/ex-official /work/ex-built \
         "/work/official/${oname}" "/work/built/msi/${bn}" \
        > "${log_dir}/msi-compare.txt" 2>&1 || cmp_rc=$?
      # Diff output rule: at most 5 difference lines on the terminal; the
      # full comparator output stays in logs/msi-compare.txt.
      awk -v logfile="${log_dir}/msi-compare.txt" '
        /^  ! / { d++; if (d > 5) next }
        { print }
        END { if (d > 5) printf "    ... and %d more difference line(s); full output: %s\n", d - 5, logfile }
      ' "${log_dir}/msi-compare.txt"
      echo ""
      if [[ "$cmp_rc" -eq 0 ]]; then
        msi_match=1
        echo "[INFO] MSI: no differences beyond the allowlist in streams, tables or container."
      elif [[ "$cmp_rc" -eq 1 ]]; then
        echo "[INFO] MSI: DIFFERENCES REMAIN after normalization (listed above)."
      else
        ftbfs_die "MSI comparator failed (exit ${cmp_rc}); this is a tool error, not a verdict"
      fi
    fi
  fi

  echo ""
  local verdict note
  if [[ "$APP_TYPE" == "msi" ]]; then
    if [[ "$whole_match" -eq 1 ]]; then
      verdict="reproducible"
      note="The two installers are byte-identical."
    elif [[ "$msi_match" -eq 1 ]]; then
      verdict="reproducible"
      note="No differences beyond the declared allowlist (Authenticode signature, PackageCode, build timestamps, table row order, string-pool order). Every named stream and decoded table matches, the cabinet matches byte-for-byte after zeroing only its per-file date/time fields, and the container is accounted for: nothing past the final sector, no data in unallocated sectors, no dated directory entries, and the only one-sided stream is the publisher signature. Not byte-identical because ours is unsigned."
    else
      verdict="not_reproducible"
      note="Every named stream and decoded table was compared, the cabinet byte-for-byte after zeroing its per-file date/time fields. Differences remained after normalizing the allowlisted classes; they are listed in the recording."
    fi
  else
    if [[ "$whole_match" -eq 1 ]]; then
      verdict="reproducible"
      note="ZIP archives are byte-identical."
    else
      verdict="not_reproducible"
      note="ZIP archives are not byte-identical. Sparrow builds this archive with preserveFileTimestamps disabled on Windows, so byte equality is the intended outcome; extracted-file equality alone is not reproducibility."
    fi
  fi

  printf 'script_version: %s\nverdict: %s\nnotes: |\n  %s\n  artifact_identical=%s\n' \
    "$SCRIPT_VERSION" "$verdict" "$note" \
    "$([[ "$whole_match" -eq 1 ]] && echo true || echo false)" > "$results_file"
  cp "$results_file" "$execution_dir/" 2>/dev/null || true

  display_results "$execution_dir"
}
# Hash legend, kept OUTSIDE the Begin/End markers so that block stays a clean
# key: value list (dannys-amendments.md, "Ambiguous Artifact Hashes").
print_hash_legend() {
  echo ""
  echo "HASH LEGEND"
  echo "  appHash     official ${APP_TYPE^^} as distributed - THIS is the hash to publish."
  echo "  builtHash   our rebuild; localizes a failure, not a verdict. Never publish alone."
  echo "  scriptHash  this script: which tooling produced these results."
}

# Standardized summary (verification-result-summary-format.md). The machine verdict
# lives in COMPARISON_RESULTS.yaml; this block is the human/recording view.
emit_verification_summary() {
  local yaml_verdict summary_verdict
  yaml_verdict=$(grep "^verdict:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)
  case "$yaml_verdict" in
    reproducible)     summary_verdict="reproducible" ;;
    not_reproducible) summary_verdict="differences found" ;;
    *)                summary_verdict="$yaml_verdict" ;;
  esac

  local official_artifact built_artifact official_sha built_sha
  official_artifact="${WORK_DIR}/official/Sparrow-${APP_VERSION}.${APP_TYPE}"
  built_artifact=$(find "${WORK_DIR}/built/${APP_TYPE}" -name "*.${APP_TYPE}" 2>/dev/null | head -1)
  official_sha=$(sha256_of "$official_artifact")
  built_sha=$(sha256_of "${built_artifact:-/nonexistent}")

  print_hash_legend

  # appHash is the official artifact EXACTLY AS DISTRIBUTED. Only canonical fields
  # inside the markers; anything extra lives outside them.
  echo ""
  echo "===== Begin Results ====="
  echo "appId:          ${APP_ID}"
  echo "signer:         N/A"
  echo "apkVersionName: ${APP_VERSION}"
  echo "apkVersionCode: N/A"
  echo "verdict:        ${summary_verdict}"
  echo "appHash:        ${official_sha}"
  echo "commit:         ${RESOLVED_COMMIT}"
  echo "scriptVersion:  ${SCRIPT_VERSION}"
  echo "scriptHash:     ${SCRIPT_SHA256:-N/A}"
  echo ""

  # Desktop/binary workflow: Luis's machine-readable summary (format doc section 3).
  local match_flag=0 match_word="DOESN'T MATCH" matches=0 mismatches=1
  if [[ "$official_sha" == "$built_sha" && "$official_sha" != "N/A" ]]; then
    match_flag=1; match_word="MATCHES"; matches=1; mismatches=0
  fi
  echo "Diff:"
  echo "BUILDS MATCH BINARIES"
  echo "Sparrow-${APP_VERSION}.${APP_TYPE} - ${APP_ARCH} - ${built_sha} - ${match_flag} (${match_word})"
  echo ""
  echo "SUMMARY"
  echo "total: 1"
  echo "matches: ${matches}"
  echo "mismatches: ${mismatches}"
  echo ""
  echo "Revision, tag (and its signature):"
  echo "tag:            ${APP_VERSION}"
  echo "commit:         ${RESOLVED_COMMIT}"
  echo ""
  echo "Signature Summary:"
  echo "official artifact: ${BINARY_SOURCE}"
  echo "manifest signature: ${SIG_STATUS}"
  echo "pinned key: ${SPARROW_KEY_FPR} (Craig Raw)"

  # Canonical "Also" section for non-standard notes (format doc section 5).
  if [[ "$APP_TYPE" == "msi" && "$match_flag" -eq 0 ]]; then
    echo ""
    echo "===== Also ===="
    echo "MSI stream, table and container comparison, full output:"
    echo "${WORK_DIR}/logs/msi-compare.txt"
  fi
  echo ""
  echo "===== End Results ====="

  # Diff investigation commands, after the end marker (format doc section 7).
  local ex_official ex_built
  if [[ "$APP_TYPE" == "msi" ]]; then
    ex_official="${WORK_DIR}/ex-official"; ex_built="${WORK_DIR}/ex-built"
  else
    ex_official="${WORK_DIR}/official-zip-extracted"; ex_built="${WORK_DIR}/built-zip-extracted"
  fi
  echo ""
  echo "Run a full"
  if [[ -d "$ex_official" && -d "$ex_built" ]]; then
    echo "diff --recursive $ex_official $ex_built"
    echo "meld $ex_official $ex_built"
    echo "or"
  fi
  echo "diffoscope \"$official_artifact\" \"${built_artifact:-missing}\""
  echo "for more details."
}

display_results() {
  local exec_dir="$1"

  echo ""
  echo "======================================================"
  echo "RESULTS"
  echo "======================================================"
  cat COMPARISON_RESULTS.yaml
  echo ""
  echo "Workspace: $WORK_DIR/COMPARISON_RESULTS.yaml"
  if [[ "$exec_dir" != "$WORK_DIR" ]]; then
    echo "Build server location: $exec_dir/COMPARISON_RESULTS.yaml"
  fi

  emit_verification_summary
  echo ""

  local verdict
  verdict=$(grep "^verdict:" COMPARISON_RESULTS.yaml | cut -d' ' -f2)

  if [[ "$verdict" == "reproducible" ]]; then
    echo "✅ VERDICT: REPRODUCIBLE"
    echo "Exit code: $EXIT_SUCCESS"
    exit $EXIT_SUCCESS
  else
    echo "❌ VERDICT: NOT REPRODUCIBLE"
    echo "Exit code: $EXIT_BUILD_FAILED"
    exit $EXIT_BUILD_FAILED
  fi
}
parse_arguments() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 --version VERSION --arch x86_64-windows --type msi|zip [--binary FILE]"
    echo "  --binary FILE   official installer; if omitted it is downloaded and"
    echo "                  --type is required. Always checked against the signed"
    echo "                  release manifest first."
    echo "  --windows-dir DIR  golden image and VM key (default /var/lib/walletscrutiny-windows)"
    echo "  Optional: --work-dir DIR --quiet --no-verify-signature"
    exit $EXIT_INVALID_PARAMS
  fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --version) require_value "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
      --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
      --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
      --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
      --work-dir) require_value "$1" "${2:-}"; CUSTOM_WORK_DIR="$2"; shift 2 ;;
      --windows-dir) require_value "$1" "${2:-}"; WIN_DIR="$2"; shift 2 ;;
      --apk)
        if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi ;;
      --no-verify-signature) SKIP_SIG_VERIFY=true; shift ;;
      --keep-container|--quiet|--no-cache) shift ;;
      *) warn "Ignoring unknown parameter: $1"; shift ;;
    esac
  done

  [[ -n "$APP_VERSION" ]] || die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
  [[ "$APP_VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || die "Invalid --version '$APP_VERSION'" $EXIT_INVALID_PARAMS
  [[ -n "$APP_ARCH" ]] || die "Missing required parameter: --arch" $EXIT_INVALID_PARAMS
  is_windows_arch "$APP_ARCH" || die "--arch '$APP_ARCH' is not a Windows arch; Linux types are handled by sparrowdesktop_build.sh" $EXIT_INVALID_PARAMS
  # --binary optional since v0.2.0; with no file name --type must be explicit.
  if [[ -z "$BINARY_PATH" ]]; then
    case "$APP_TYPE" in
      msi|zip) ;;
      "") die "--type msi|zip is required when --binary is not given" $EXIT_INVALID_PARAMS ;;
      *) die "Invalid --type '$APP_TYPE' (must be msi or zip)" $EXIT_INVALID_PARAMS ;;
    esac
    return 0
  fi

  [[ -e "$BINARY_PATH" ]] || die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS

  local bname; bname=$(basename "$BINARY_PATH")
  if [[ -z "$APP_TYPE" ]]; then
    case "$bname" in
      *.msi) APP_TYPE="msi" ;;
      *.zip) APP_TYPE="zip" ;;
      *) die "--binary '$bname' must be .msi or .zip" $EXIT_INVALID_PARAMS ;;
    esac
  else
    case "$APP_TYPE" in
      msi) [[ "$bname" == *.msi ]] || die "--type msi but --binary '$bname' is not .msi" $EXIT_INVALID_PARAMS ;;
      zip) [[ "$bname" == *.zip ]] || die "--type zip but --binary '$bname' is not .zip" $EXIT_INVALID_PARAMS ;;
      *) die "Invalid --type '$APP_TYPE' (must be msi or zip)" $EXIT_INVALID_PARAMS ;;
    esac
  fi
}

main() {
  # Runs as a normal user only; root runs break the ownership guarantees below.
  if [[ "${EUID}" -eq 0 ]]; then
    echo "ERROR: Do not run this script as root; run it as a normal user." >&2
    exit $EXIT_INVALID_PARAMS
  fi

  echo ""
  echo "======================================================"
  echo "Sparrow Windows (MSI/ZIP) Reproducible Build Verifier ${SCRIPT_VERSION}"
  echo "======================================================"
  echo ""

  # Self-identify before doing anything else, so a recording of this run always shows
  # which bytes of tooling produced the result (script-version-and-hash.md, 2026-08-17).
  SCRIPT_SHA256="$(sha256_of "$SCRIPT_PATH")"
  echo "[INFO] Script:  $(basename "$SCRIPT_PATH") ${SCRIPT_VERSION}"
  echo "[INFO]         sha256: ${SCRIPT_SHA256}"

  parse_arguments "$@"
  check_vm_prereqs
  detect_container_cmd
  build_and_verify_windows
}

main "$@"
