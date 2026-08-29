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
