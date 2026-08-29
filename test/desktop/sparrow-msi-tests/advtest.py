#!/usr/bin/env python3
"""Adversarial regression suite for msicmp.py: every case tries to sneak a real
change past the normalization, or feeds malformed input."""
import os, shutil, struct, subprocess, sys, tempfile

BASE = os.path.dirname(os.path.abspath(__file__))
CMP = os.path.join(BASE, 'msicmp.py')

def run(a, b):
    p = subprocess.run([sys.executable, CMP, a, b], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def clone(src):
    d = tempfile.mkdtemp(prefix='adv-')
    for f in os.listdir(src): shutil.copy2(os.path.join(src, f), os.path.join(d, f))
    return d

def patch(d, name, fn):
    p = os.path.join(d, name)
    b = bytearray(open(p, 'rb').read()); fn(b)
    open(p, 'wb').write(bytes(b))

results = []
def check(name, got, want, out, needle=None):
    ok = (got == want) and (needle is None or needle in out)
    results.append((ok, name, f'exit={got} want={want}'))
    print(f'{"PASS" if ok else "FAIL"}  {name}  (exit={got}, want={want})')
    if not ok: print('    ' + out.strip().replace('\n', '\n    ')[:700])

OFF, B1, B3 = sys.argv[1], sys.argv[2], sys.argv[3]

rc, out = run(B1, B3);  check('T1 real positive: two of our own builds', rc, 0, out, 'DIFFERENCES: none')
rc, out = run(OFF, B1); check('T2 real negative: official vs our build', rc, 1, out, 'TABLE RemoveFile')

# T3 - flip one byte of compressed data, leaving every CFFILE field untouched
d = clone(B3)
def flip_cfdata(b):
    # CFHEADER: coffFiles@16, cFolders@26, cFiles@28. Target the first folder's
    # compressed data, which lives well past every CFFILE record.
    cfolders = struct.unpack_from('<H', b, 26)[0]
    coffCabStart = struct.unpack_from('<I', b, 36)[0]   # first CFFOLDER
    target = coffCabStart + 32                          # inside CFDATA payload
    assert target < len(b), 'target past end of cabinet'
    b[target] ^= 0xFF
patch(d, 'Data.cab', flip_cfdata)
rc, out = run(B1, d); check('T3 CFDATA byte flipped, CFFILE metadata intact', rc, 1, out, 'cabinet differs')
shutil.rmtree(d)

# T4 - change a summary property that is neither PackageCode nor a timestamp
d = clone(B3)
def touch_prop(b):
    off = struct.unpack_from('<I', b, 44)[0]
    cprop = struct.unpack_from('<I', b, off + 4)[0]
    for i in range(cprop):
        pid, poff = struct.unpack_from('<II', b, off + 8 + i * 8)
        if pid not in (9, 12, 13):
            a = off + poff + 8
            if a < len(b): b[a] ^= 0x20; return
    raise SystemExit('no eligible property found')
patch(d, '[5]SummaryInformation', touch_prop)
rc, out = run(B1, d); check('T4 non-timestamp summary property altered', rc, 1, out, 'summary-information differs')
shutil.rmtree(d)

# T5 - change string-pool metadata only; decoded rows are unaffected
d = clone(B3)
def bump_refcount(b):
    z, r = struct.unpack_from('<HH', b, 4)
    struct.pack_into('<H', b, 6, (r + 1) & 0xFFFF)
patch(d, '!_StringPool', bump_refcount)
rc, out = run(B1, d); check('T5 string-pool reference count altered', rc, 1, out, 'reference counts differ')
shutil.rmtree(d)

# T6 - truncated table stream must be a comparator error, not a verdict
d = clone(B3)
p = os.path.join(d, '!File'); b = open(p, 'rb').read(); open(p, 'wb').write(b[:-1])
rc, out = run(B1, d); check('T6 truncated table stream', rc, 2, out, 'COMPARATOR ERROR')
shutil.rmtree(d)

# T7 - cabinet carrying reserve fields is unsupported, not a verdict
d = clone(B3)
patch(d, 'Data.cab', lambda b: struct.pack_into('<H', b, 30, struct.unpack_from('<H', b, 30)[0] | 0x0004))
rc, out = run(B1, d); check('T7 cabinet with reserve fields', rc, 2, out, 'COMPARATOR ERROR')
shutil.rmtree(d)

# T8 - a table row value changed must fail even when row counts match
d = clone(B3)
def bend_registry(b): b[0] ^= 0x01
patch(d, '!Registry', bend_registry)
rc, out = run(B1, d); check('T8 Registry table byte altered', rc, 1, out)
shutil.rmtree(d)

# T9 - a byte inside the summary section but outside any normalizable property
d = clone(B3)
def touch_section_pad(b):
    off = struct.unpack_from('<I', b, 44)[0]
    cb, cprop = struct.unpack_from('<II', b, off)
    ends = sorted(off + struct.unpack_from('<II', b, off + 8 + i * 8)[1] for i in range(cprop))
    tgt = off + cb - 1                    # last byte of the section
    if tgt <= ends[-1]: tgt = ends[-1] + 1
    b[tgt] ^= 0x5A
patch(d, '[5]SummaryInformation', touch_section_pad)
rc, out = run(B1, d); check('T9 summary byte outside any normalized property', rc, 1, out, 'summary-information differs')
shutil.rmtree(d)

# T10 - bytes appended past the end of the summary stream
d = clone(B3)
p = os.path.join(d, '[5]SummaryInformation')
open(p, 'ab').write(b'\x00' * 8)
rc, out = run(B1, d); check('T10 trailing bytes appended to summary stream', rc, 1, out)
shutil.rmtree(d)

# T11 - two property sets is unsupported, not a verdict
d = clone(B3)
patch(d, '[5]SummaryInformation', lambda b: struct.pack_into('<I', b, 24, 2))
rc, out = run(B1, d); check('T11 multiple property sets', rc, 2, out, 'COMPARATOR ERROR')
shutil.rmtree(d)

print()
bad = [r for r in results if not r[0]]
print(f'{len(results) - len(bad)}/{len(results)} passed')
sys.exit(1 if bad else 0)
