# Find static const char* arrays in a PE64 image by their first few strings.
import struct, sys, json
data = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', data, 0x3c)[0]
nsec = struct.unpack_from('<H', data, pe + 6)[0]
optsz = struct.unpack_from('<H', data, pe + 20)[0]
opt = pe + 24
image_base = struct.unpack_from('<Q', data, opt + 24)[0]
secs = []
for i in range(nsec):
    o = opt + optsz + i * 40
    name = data[o:o+8].rstrip(b'\0').decode()
    vsize, va, rsize, raw = struct.unpack_from('<IIII', data, o + 8)
    secs.append((name, va, vsize, raw, rsize))
def va2off(v):
    rva = v - image_base
    for name, va, vs, raw, rs in secs:
        if va <= rva < va + max(vs, rs):
            off = raw + rva - va
            return off if off < raw + rs else None
    return None
def off2va(off):
    for name, va, vs, raw, rs in secs:
        if raw <= off < raw + rs:
            return image_base + va + off - raw
    return None
def cstr(off):
    end = data.index(b'\0', off)
    return data[off:end]
def find_table(first, maxn=400):
    seqs = [s.encode() + b'\0' for s in first]
    # candidate VAs of the first string
    cands = []
    i = data.find(seqs[0])
    while i != -1:
        if i == 0 or data[i-1] == 0:
            v = off2va(i)
            if v: cands.append(v)
        i = data.find(seqs[0], i + 1)
    res = []
    for v in cands:
        needle = struct.pack('<Q', v)
        j = data.find(needle)
        while j != -1:
            ok = True
            for k, s in enumerate(seqs[1:], 1):
                pv = struct.unpack_from('<Q', data, j + 8*k)[0]
                po = va2off(pv)
                if po is None or data[po:po+len(s)] != s: ok = False; break
            if ok:
                names = []
                for k in range(maxn):
                    pv = struct.unpack_from('<Q', data, j + 8*k)[0]
                    po = va2off(pv)
                    if po is None: break
                    try: names.append(cstr(po).decode('utf-8'))
                    except Exception: break
                res.append(names)
            j = data.find(needle, j + 1)
    return res
out = {}
for key, first in [('token_names', ['Empty', 'Identifier', 'Constant', 'Self']),
                   ('builtin_funcs', ['sin', 'cos', 'tan', 'sinh']),]:
    t = find_table(first)
    out[key] = t
    print(key, 'tables found:', len(t), [len(x) for x in t])
json.dump(out, open(sys.argv[2], 'w'), indent=1)
