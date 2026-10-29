"""Extract entries from a Godot 3 PCK (format 1) into a directory. Local recovery only.

Usage: python -I pck_extract.py <pck> <out_dir> [suffixes|*]
"""
import struct, sys, os
pck, outdir = sys.argv[1], sys.argv[2]
# Optional comma list of suffixes; '*' extracts everything.
exts = tuple(sys.argv[3].split(',')) if len(sys.argv) > 3 else ('.gdc', '.gd', '.remap', '.tscn', '.tres', '.binary', '.csv', '.json', '.cfg')
all_files = exts == ('*',)
with open(pck, 'rb') as f:
    assert f.read(4) == b'GDPC'
    f.read(16); f.read(64)
    n, = struct.unpack('<I', f.read(4))
    es = []
    for _ in range(n):
        ln, = struct.unpack('<I', f.read(4))
        p = f.read(ln).rstrip(b'\0').decode('utf-8')
        off, size = struct.unpack('<QQ', f.read(16)); f.read(16)
        es.append((p, off, size))
    cnt = 0
    for p, off, size in es:
        if not all_files and not p.endswith(exts): continue
        rel = p[len('res://'):]
        assert '..' not in rel.split('/') and not os.path.isabs(rel), p
        dst = os.path.join(outdir, *rel.split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        f.seek(off); data = f.read(size)
        with open(dst, 'wb') as o: o.write(data)
        cnt += 1
print('extracted', cnt)
