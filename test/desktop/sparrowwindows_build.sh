#!/bin/bash
#
# sparrowwindows_build.sh - Sparrow Wallet Windows (MSI/ZIP) Reproducible Build Verifier
# Version: v0.1.0
#
# Builds Sparrow for Windows via GitHub Actions, downloads the built installer and
# compares it against the official release artifact.
#
# For MSI the comparison covers every named OLE stream and every decoded MSI database
# table. Four classes are normalized away, and each one is printed by name: the
# Authenticode signature, the PackageCode, build timestamps (the two documented summary
# FILETIME properties and the cabinet's per-file date/time fields), and the storage
# order of rows within a table. The cabinet is compared byte-for-byte after zeroing
# exactly those date/time fields, so compressed payload, checksums and folder records
# are all covered. Any other difference fails the run.
#
# OUT OF SCOPE, and not claimed: the OLE container itself - its header, FAT/DIFAT,
# directory entries, sector padding and bytes past the final sector. Extraction exposes
# named streams only.
#
# Comparator exit codes are distinguished: 0 equivalent, 1 real differences,
# 2 or more a comparator/tool error, which is reported as ftbfs and never as a verdict.
#
# Linux artifacts (tarball/deb/rpm) are handled by sparrowdesktop_build.sh.
#
# Organization: WalletScrutiny.com
# Repository: https://gitlab.com/walletscrutiny/walletScrutinyCom
#

set -euo pipefail

SCRIPT_VERSION="v0.1.0"

GH_REPO="xrviv/WalletScrutinyCom"
GH_WORKFLOW="sparrow-build.yml"
GH_WORKFLOW_REF="master"
GH_HELPER_IMAGE="sparrow-win-helper"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

DEFAULT_JDK_VERSION="25.0.2+10"
DOCKER_CMD="${DOCKER_CMD:-}"

APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
WORK_DIR=""
CUSTOM_WORK_DIR=""
KEEP_CONTAINER=false
QUIET=false
BINARY_PATH=""

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}
warn() {
    echo "WARN: $1" >&2
}
detect_container_cmd() {
    if [[ -n "$DOCKER_CMD" ]]; then
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        DOCKER_CMD="podman"
    elif command -v docker >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    else
        die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
    fi
}
require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "Missing value for parameter: $flag" $EXIT_INVALID_PARAMS
    fi
}
sanitize_component() {
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    input=$(echo "$input" | sed -E 's/[^a-z0-9]+/-/g')
    input="${input#-}"
    input="${input%-}"
    if [[ -z "$input" ]]; then
        input="na"
    fi
    echo "$input"
}
is_windows_arch() {
    case "${1:-}" in
        x86_64-windows|win-x64|win64|windows) return 0 ;;
        *) return 1 ;;
    esac
}
build_gh_helper() {
    echo "[INFO] Building gh helper container..."
    "$DOCKER_CMD" build -t "${GH_HELPER_IMAGE}" - << 'GHEOF'
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg jq unzip p7zip-full python3-minimal \
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
    "$DOCKER_CMD" run --rm \
        -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
        -v "${WORK_DIR}:/work" \
        -w /work \
        "${GH_HELPER_IMAGE}" \
        gh "$@"
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
        [[ -f "${oroot}/${rel#./}" ]] && oh=$(sha256sum "${oroot}/${rel#./}" | cut -d' ' -f1)
        [[ -f "${broot}/${rel#./}" ]] && bh=$(sha256sum "${broot}/${rel#./}" | cut -d' ' -f1)
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
"""Normalized comparison of two extracted MSI installers.

Input: two directories produced by `7z x -tCompound <installer>.msi -o<dir>`,
each holding the installer's named OLE streams.

Exit codes
  0  equivalent under the allowlist below
  1  differences remain after normalization
  2  comparator error - malformed, truncated or unsupported input

The allowlist is deliberately small and every item it removes is printed:
  A. the Authenticode signature stream, present on one side only
  B. the PackageCode (PID_REVNUMBER) in the summary-information stream
  C. build timestamps - the two documented FILETIME summary properties, and the
     per-file date/time fields inside the cabinet
  D. the storage order of rows within a database table

OUT OF SCOPE, and not claimed: the OLE container itself - its header, FAT/DIFAT,
directory entries, sector padding and any bytes past the last sector. `-tCompound`
exposes named streams only. Container structure must be checked separately.
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

# ---------------------------------------------------------------- cabinet ----
def cab_normalized(b, who):
    """Return a copy of the cabinet with only the per-file date/time fields zeroed.

    Everything else - header, folder records, compressed data blocks, checksums,
    names, padding, trailing bytes - is left intact so the caller can compare the
    whole thing byte-for-byte."""
    if len(b) < 36 or b[:4] != b'MSCF':
        raise Bad(f'{who}: not a cabinet')
    (_, r1, cbCab, r2, coffFiles, r3, vmin, vmaj,
     cFolders, cFiles, flags, setID, iCab) = struct.unpack_from('<4sIIIIIBBHHHHH', b, 0)
    if flags & 0x0004:
        raise Bad(f'{who}: cabinet carries reserve fields (flags=0x{flags:04x}); unsupported')
    if flags & 0x0003:
        raise Bad(f'{who}: multi-cabinet set (flags=0x{flags:04x}); unsupported')
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
        diff(f'cabinet differs in {n} byte(s) beyond the per-file date/time fields '
             f'- this covers compressed data, checksums, folder records and header')

# ------------------------------------------------- summary information -------
PID_REVNUMBER, PID_CREATE_DTM, PID_LASTSAVE_DTM = 9, 12, 13
VT_LPSTR, VT_FILETIME = 30, 64

def summary_normalized(b, who):
    """Zero exactly the PackageCode GUID and the two FILETIME payloads, in place in a
    copy, and return it with a note of what was blanked. Everything else in the stream -
    header fields, section table, other properties, padding, trailing bytes - is left
    alone so the caller can compare the whole stream byte-for-byte."""
    if len(b) < 48: raise Bad(f'{who}: summary stream too short')
    bo, fmt, osv, clsid, nsets = struct.unpack_from('<HHI16sI', b, 0)
    if bo != 0xFFFE: raise Bad(f'{who}: bad property-set byte order 0x{bo:04x}')
    if nsets != 1:
        raise Bad(f'{who}: {nsets} property sets; this comparator handles exactly one')
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

# ----------------------------------------------------------- string pool -----
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
        diff(f'string pool entries or their individual reference counts differ in '
             f'{sum(d.values())} entry/entries, e.g. {sorted(d)[:3]!r}')
        bad = True
    if not bad and raw_differs:
        norm('string pool storage order (same entries, same individual reference counts)')

# ----------------------------------------------------------------- tables ----
def schema(d, strings, width, who):
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
            raise Bad(f'{who}: table identifier {tn!r} is not a strict ASCII identifier')
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

# ------------------------------------------------------------------ main -----
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
    sa, sb = schema(A, pa[0], pa[2], 'official'), schema(B, pb[0], pb[2], 'built')
    if set(sa) != set(sb):
        diff(f'table set differs: {sorted(set(sa) ^ set(sb))!r}')
    for t in sorted(set(sa) & set(sb)):
        if sa[t] != sb[t]:
            diff(f'schema differs for table {t.decode("ascii", "replace")}')

    # every ! stream must be explicitly accounted for; nothing is skipped by pattern
    accounted = {'!_StringPool', '!_StringData', '!_Columns', '!_Tables'}
    for t in set(sa) & set(sb):
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
    if len(sys.argv) != 3:
        print('usage: msicmp.py <official-extract-dir> <built-extract-dir>', file=sys.stderr)
        sys.exit(2)
    try:
        run(sys.argv[1], sys.argv[2])
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
    print('SCOPE: named OLE streams and decoded database tables only. The OLE container')
    print('itself - header, FAT/DIFAT, directory entries, sector padding and any bytes')
    print('past the final sector - was NOT examined. "no differences" here is therefore')
    print('a necessary condition for artifact reproducibility, not a sufficient one.')
    sys.exit(1 if DIFF else 0)
MSICMP_END
}

ftbfs_die() {
    printf 'script_version: %s\nverdict: ftbfs\nnotes: "%s"\n' "$SCRIPT_VERSION" "$1" > "$results_file"
    cp "$results_file" "$execution_dir/" 2>/dev/null || true
    die "$1" $EXIT_BUILD_FAILED
}
build_and_verify_windows() {
    local version_component arch_component execution_dir
    version_component=$(sanitize_component "$APP_VERSION")
    arch_component=$(sanitize_component "$APP_ARCH")
    execution_dir="$(pwd)"

    if [[ -n "$CUSTOM_WORK_DIR" ]]; then
        WORK_DIR="$CUSTOM_WORK_DIR"
    else
        WORK_DIR="${execution_dir}/sparrow_desktop_${version_component}_${arch_component}_${APP_TYPE}_$$"
    fi

    local log_dir="${WORK_DIR}/logs"
    local official_dir="${WORK_DIR}/official"
    local built_dir="${WORK_DIR}/built"
    local results_file="${WORK_DIR}/COMPARISON_RESULTS.yaml"

    mkdir -p "$WORK_DIR" "$log_dir" "$official_dir" "$built_dir"
    cd "$WORK_DIR"

    echo "======================================================"
    echo "Sparrow Desktop v${APP_VERSION} — Windows ${APP_TYPE^^} Verification"
    echo "======================================================"
    echo ""

    if ! "$DOCKER_CMD" image inspect "${GH_HELPER_IMAGE}" >/dev/null 2>&1; then
        build_gh_helper
    fi
    write_comparator

    local official_msi="${official_dir}/Sparrow-${APP_VERSION}.msi"
    local official_zip="${official_dir}/Sparrow-${APP_VERSION}.zip"

    if [[ "$APP_TYPE" == "msi" ]]; then
        echo "[INFO] Using provided MSI: $(basename "$BINARY_PATH")"
        cp "$BINARY_PATH" "$official_msi"
    else
        echo "[INFO] Using provided ZIP: $(basename "$BINARY_PATH")"
        cp "$BINARY_PATH" "$official_zip"
    fi

    local trigger_time
    trigger_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local -a _PRE_TRIGGER_IDS
    mapfile -t _PRE_TRIGGER_IDS < <(gh_c run list \
        --repo "${GH_REPO}" --workflow "${GH_WORKFLOW}" \
        --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)

    local jdk_workflow_version="${DEFAULT_JDK_VERSION%%+*}"
    echo "[INFO] Triggering GitHub Actions workflow on ${GH_REPO} (jdk_version=${jdk_workflow_version})..."
    if ! gh_c workflow run "${GH_WORKFLOW}" \
        --repo "${GH_REPO}" \
        --ref "${GH_WORKFLOW_REF}" \
        -f version="${APP_VERSION}" \
        -f jdk_version="${jdk_workflow_version}"; then
        ftbfs_die "Failed to trigger GitHub Actions workflow"
    fi

    echo "[INFO] Waiting for workflow run to appear..."
    local run_id=""
    local max_poll=30
    local poll_interval=10
    local -a _CANDIDATES
    local i cid is_new pid
    for i in $(seq 1 "$max_poll"); do
        sleep "$poll_interval"
        mapfile -t _CANDIDATES < <(gh_c run list \
            --repo "${GH_REPO}" \
            --workflow "${GH_WORKFLOW}" \
            --limit 10 \
            --json databaseId,createdAt \
            --jq "[.[] | select(.createdAt >= \"${trigger_time}\")] | .[].databaseId" \
            2>/dev/null || true)
        for cid in "${_CANDIDATES[@]:-}"; do
            [[ -z "$cid" || "$cid" == "null" ]] && continue
            is_new=true
            for pid in "${_PRE_TRIGGER_IDS[@]:-}"; do
                [[ "$cid" == "$pid" ]] && is_new=false && break
            done
            if [[ "$is_new" == "true" ]]; then
                run_id="$cid"
                break
            fi
        done
        [[ -n "$run_id" ]] && break
        echo "[INFO] Poll attempt ${i}/${max_poll}..."
    done

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        ftbfs_die "Could not find workflow run after ${max_poll} attempts"
    fi
    echo "[INFO] Found workflow run ID: ${run_id}"

    echo "[INFO] Watching workflow run ${run_id}..."
    if ! gh_c run watch "${run_id}" --repo "${GH_REPO}" --exit-status; then
        gh_c run view "${run_id}" --repo "${GH_REPO}" --log \
            > "${log_dir}/gh-run-${run_id}.log" 2>&1 || true
        ftbfs_die "Workflow run ${run_id} failed"
    fi
    echo "[INFO] Workflow run ${run_id} completed."
    gh_c run view "${run_id}" --repo "${GH_REPO}" --log \
        > "${log_dir}/gh-run-${run_id}.log" 2>&1 || true

    local built_msi_dir="${built_dir}/msi"
    local built_zip_dir="${built_dir}/zip"
    mkdir -p "$built_msi_dir" "$built_zip_dir"

    if [[ "$APP_TYPE" == "msi" ]]; then
        echo "[INFO] Downloading built MSI artifact..."
        if ! gh_c run download "${run_id}" \
            --repo "${GH_REPO}" \
            --name "sparrow-${APP_VERSION}-win-msi" \
            --dir /work/built/msi; then
            ftbfs_die "Failed to download built MSI artifact"
        fi
    else
        echo "[INFO] Downloading built ZIP artifact..."
        if ! gh_c run download "${run_id}" \
            --repo "${GH_REPO}" \
            --name "sparrow-${APP_VERSION}-win-zip" \
            --dir /work/built/zip; then
            ftbfs_die "Failed to download built ZIP artifact"
        fi
    fi

    echo ""
    local zip_match=0 msi_match=0 whole_match=0

    if [[ "$APP_TYPE" == "zip" ]]; then
        echo "[INFO] === ZIP Comparison ==="
        local built_zip_file
        built_zip_file=$(find "$built_zip_dir" -name "*.zip" | head -1)
        if [[ -z "$built_zip_file" ]]; then
            ftbfs_die "Built ZIP file not found in downloaded artifact"
        fi

        local ozs bzs
        ozs=$(sha256sum "$official_zip" | cut -d' ' -f1)
        bzs=$(sha256sum "$built_zip_file" | cut -d' ' -f1)
        echo "[INFO] ZIP official SHA256: $ozs"
        echo "[INFO] ZIP built    SHA256: $bzs"
        [[ "$ozs" == "$bzs" ]] && whole_match=1

        local official_zip_extract="${WORK_DIR}/official-zip-extracted"
        local built_zip_extract="${WORK_DIR}/built-zip-extracted"
        mkdir -p "$official_zip_extract" "$built_zip_extract"
        unzip -q "$official_zip" -d "$official_zip_extract"
        unzip -q "$built_zip_file" -d "$built_zip_extract"

        local official_list="${WORK_DIR}/official-zip-files.txt"
        local built_list="${WORK_DIR}/built-zip-files.txt"
        (cd "$official_zip_extract" && find . -type f | sort) > "$official_list"
        (cd "$built_zip_extract" && find . -type f | sort) > "$built_list"

        local total_files match_files diff_files
        local zip_union="${WORK_DIR}/zip-union-files.txt"
        sort -u "$official_list" "$built_list" > "$zip_union"
        total_files=$(wc -l < "$zip_union" | tr -d ' ')
        echo "[INFO] ${total_files} files to verify (union of both extractions)"
        echo ""
        compare_extracted "$zip_union" "$official_zip_extract" "$built_zip_extract"
        total_files=$CMP_TOTAL; match_files=$CMP_OK; diff_files=$CMP_BAD
        rm -f "$zip_union"

        rm -f "$official_list" "$built_list"

        echo "[INFO] ZIP: ${match_files}/${total_files} files verified"
        if [[ "$diff_files" -eq 0 ]]; then
            zip_match=1
            echo "[INFO] ZIP: ALL FILES MATCH"
        else
            echo "[INFO] ZIP: MISMATCH — ${diff_files} difference(s)"
        fi

    elif [[ "$APP_TYPE" == "msi" ]]; then
        echo "[INFO] === MSI Comparison ==="
        local built_msi_file
        built_msi_file=$(find "$built_msi_dir" -name "*.msi" | head -1)
        [[ -n "$built_msi_file" ]] || ftbfs_die "Built MSI file not found in downloaded artifact"

        local official_msi_sha built_msi_sha
        official_msi_sha=$(sha256sum "$official_msi" | awk '{print $1}')
        built_msi_sha=$(sha256sum "$built_msi_file" | awk '{print $1}')
        echo "[INFO] MSI official SHA256: ${official_msi_sha}"
        echo "[INFO] MSI built    SHA256: ${built_msi_sha}"
        if [[ "$official_msi_sha" == "$built_msi_sha" ]]; then
            whole_match=1; msi_match=1
            echo "[INFO] MSI: SHA256 MATCH - installers are byte-identical"
        else
            echo "[INFO] MSI: SHA256 differs; running normalized full-database comparison"
            local bn; bn=$(basename "$built_msi_file")
            "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/work" "${GH_HELPER_IMAGE}" bash -c "
                7z x -tCompound /work/official/Sparrow-${APP_VERSION}.msi -o/work/ex-official -y >/dev/null 2>&1 &&
                7z x -tCompound /work/built/msi/${bn} -o/work/ex-built -y >/dev/null 2>&1" \
                || ftbfs_die "Extraction of one or both MSIs failed"
            [[ -n "$(ls -A "${WORK_DIR}/ex-official" 2>/dev/null)" && -n "$(ls -A "${WORK_DIR}/ex-built" 2>/dev/null)" ]] \
                || ftbfs_die "MSI extraction produced no streams on one or both sides"

            echo ""
            local cmp_rc=0
            set +e
            "$DOCKER_CMD" run --rm -v "${WORK_DIR}:/work" "${GH_HELPER_IMAGE}" \
                python3 /work/msicmp.py /work/ex-official /work/ex-built 2>&1 | tee "${log_dir}/msi-compare.txt"
            cmp_rc=${PIPESTATUS[0]}
            set -e
            echo ""
            if [[ "$cmp_rc" -eq 0 ]]; then
                msi_match=1
                echo "[INFO] MSI: no differences beyond the allowlist in named streams or database tables."
                echo "[INFO] MSI: the OLE container was NOT compared, so this is necessary but not sufficient;"
                echo "[INFO] MSI: artifact reproducibility is not established by this script alone."
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
            # Necessary but not sufficient: the OLE container itself was not compared,
            # so this script must not promote stream equivalence to a verdict.
            verdict="not_reproducible"
            note="Named-stream and database comparison found NO differences beyond the allowlist (Authenticode signature, PackageCode, build timestamps, table row order, string-pool storage order); the cabinet was compared byte-for-byte after zeroing only its per-file date/time fields. That is a necessary but not a sufficient condition: the OLE container itself - header, FAT/DIFAT, directory entries, sector padding and bytes past the final sector - was NOT examined by this script, so artifact reproducibility is NOT established here. A separate, evidenced container analysis is required before any reproducible verdict."
        else
            verdict="not_reproducible"
            note="Every named OLE stream and every decoded MSI database table was compared; the cabinet byte-for-byte after zeroing its per-file date/time fields. Differences remained after normalizing the allowlisted classes; the surviving differences are listed in the recording."
        fi
    else
        if [[ "$whole_match" -eq 1 ]]; then
            verdict="reproducible"
            note="ZIP archives are byte-identical."
        else
            verdict="not_reproducible"
            note="ZIP archives are not byte-identical. Sparrow builds this archive with preserveFileTimestamps disabled on Windows, so byte equality is the intended outcome; extracted-file equality alone is not treated as reproducibility."
        fi
    fi

    printf 'script_version: %s\nverdict: %s\nnotes: |\n  %s\n  artifact_identical=%s\n' \
        "$SCRIPT_VERSION" "$verdict" "$note" \
        "$([[ "$whole_match" -eq 1 ]] && echo true || echo false)" > "$results_file"
    cp "$results_file" "$execution_dir/" 2>/dev/null || true

    display_results "$execution_dir"
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
        echo "Usage: $0 --version VERSION --arch x86_64-windows --type msi|zip --binary FILE"
        echo "  --binary FILE   the official installer to compare against (required)"
        echo "  Optional: --work-dir DIR --keep-container --quiet"
        exit $EXIT_INVALID_PARAMS
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) require_value "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
            --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --work-dir) require_value "$1" "${2:-}"; CUSTOM_WORK_DIR="$2"; shift 2 ;;
            --apk)
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi ;;
            --keep-container) KEEP_CONTAINER=true; shift ;;
            --quiet) QUIET=true; shift ;;
            --no-cache) shift ;;
            *) warn "Ignoring unknown parameter: $1"; shift ;;
        esac
    done

    [[ -n "$APP_VERSION" ]] || die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    [[ -n "$APP_ARCH" ]] || die "Missing required parameter: --arch" $EXIT_INVALID_PARAMS
    is_windows_arch "$APP_ARCH" || die "--arch '$APP_ARCH' is not a Windows arch; Linux types are handled by sparrowdesktop_build.sh" $EXIT_INVALID_PARAMS
    [[ -n "$BINARY_PATH" ]] || die "Missing required parameter: --binary (the official installer)" $EXIT_INVALID_PARAMS
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
    parse_arguments "$@"
    if [[ -z "${GITHUB_TOKEN}" ]]; then
        echo "[INFO] GITHUB_TOKEN/GH_TOKEN not set; Windows verification needs it to dispatch the build."
        echo "[INFO] Nothing to do - exiting without a verdict."
        exit $EXIT_SUCCESS
    fi
    detect_container_cmd
    build_and_verify_windows
}

main "$@"
