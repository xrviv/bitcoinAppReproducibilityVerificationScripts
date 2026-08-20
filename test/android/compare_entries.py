#!/usr/bin/env python3
"""Entry-by-entry APK comparison for the Bull Bitcoin v6.13.0 diagnostic.

Compares the raw content of every zip entry in two APKs. The ONLY entries
excluded are the legacy JAR signature files, which exist purely because the
official artifact is signed and a from-source build deliberately is not.
Everything else -- including META-INF/services/* -- is compared.

Exit 0 = no differences outside the exclusions. Exit 1 = differences found.
"""
import collections
import hashlib
import re
import sys
import zipfile

SIG_RE = re.compile(r'^META-INF/(MANIFEST\.MF|[^/]+\.(RSA|SF|EC|DSA))$', re.I)


def digest_map(path):
    """Map entry name -> (sha256 of decompressed content, size).

    Matches by NAME and hashes DECOMPRESSED content, so ZIP metadata (order,
    compression method, timestamps, attributes) is not compared, and the APK
    Signing Block -- which is not a ZIP entry -- is not seen at all. Duplicate
    entry names are reported rather than silently overwritten.
    """
    out = {}
    seen = collections.Counter()
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.is_dir() or SIG_RE.match(info.filename):
                continue
            h = hashlib.sha256()
            with z.open(info) as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b''):
                    h.update(chunk)
            seen[info.filename] += 1
            out[info.filename] = (h.hexdigest(), info.file_size)
    dupes = [n for n, c in seen.items() if c > 1]
    if dupes:
        print(f"  WARNING: duplicate entry names in {path}: {dupes}")
    return out


def main(official, built):
    a, b = digest_map(official), digest_map(built)
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    differ = sorted(n for n in set(a) & set(b) if a[n][0] != b[n][0])

    print(f"entries compared (official): {len(a)}")
    print(f"entries compared (built):    {len(b)}")
    print(f"only in official: {len(only_a)}   only in built: {len(only_b)}   differing: {len(differ)}")

    for name in only_a:
        print(f"  ONLY-OFFICIAL  {name}  ({a[name][1]} bytes)")
    for name in only_b:
        print(f"  ONLY-BUILT     {name}  ({b[name][1]} bytes)")
    for name in differ:
        print(f"  DIFFER         {name}  (official {a[name][1]} B / built {b[name][1]} B)")

    total = len(only_a) + len(only_b) + len(differ)
    print(f"\nTOTAL DIFFERENCES (excluding JAR signature files): {total}")
    return 0 if total == 0 else 1


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit("usage: compare_entries.py <official.apk> <built.apk>")
    sys.exit(main(sys.argv[1], sys.argv[2]))
