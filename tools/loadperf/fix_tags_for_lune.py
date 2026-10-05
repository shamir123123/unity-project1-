import sys, struct, os
sys.path.insert(0, os.path.dirname(__file__))
import lz4.block
from rbxl import Place, _deinterleave_u32
p = Place(sys.argv[1])
sstr = []
for ch in p.chunks:
    if ch.name == 'SSTR':
        d = ch.data
        ver, n = struct.unpack_from('<II', d, 0)
        o = 8
        for i in range(n):
            o += 16
            ln, = struct.unpack_from('<I', d, o); o += 4
            sstr.append(d[o:o+ln]); o += ln
out = bytearray(p.header)
fixed = 0
for ch in p.chunks:
    if ch.name == 'PROP':
        d = ch.data
        cid, = struct.unpack_from('<I', d, 0); ln, = struct.unpack_from('<I', d, 4)
        pn = d[8:8+ln].decode('utf-8', 'replace'); tid = d[8+ln]
        if pn == 'Tags' and tid == 0x1C:
            refs = p.classes[cid][1]
            idx = _deinterleave_u32(d[9+ln:9+ln+4*len(refs)], len(refs))
            body = bytearray(d[:8+ln]) + b'\x01'
            for i in idx:
                s = sstr[i] if i < len(sstr) else b''
                body += struct.pack('<I', len(s)) + s
            comp = lz4.block.compress(bytes(body), store_size=False)
            out += b'PROP' + struct.pack('<III', len(comp), len(body), 0) + comp
            fixed += 1
            continue
    out += ch.raw
open(sys.argv[2], 'wb').write(out)
print('fixed', fixed, 'sstr', len(sstr))
