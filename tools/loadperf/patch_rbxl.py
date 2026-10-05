"""Write a patched copy of a binary place: script Sources replaced from a source tree, and
ModuleScripts that exist in the tree but not in the place appended as new instances.

Every chunk that is not touched is copied byte-for-byte. Touched chunks: the PROP chunks of the
script classes whose Source changed, and (only when modules are added) the ModuleScript INST
chunk, every ModuleScript PROP chunk, the PRNT chunk and the header instance count.

usage: patch_rbxl.py <in.rbxl> <src_dir> <manifest.tsv> <out.rbxl>
"""
import os
import random
import struct
import sys

import lz4.block

sys.path.insert(0, os.path.dirname(__file__))
from rbxl import Place, _deinterleave_u32  # noqa: E402

src_in, src_dir, manifest, out_path = sys.argv[1:5]
p = Place(src_in)

# ---------------------------------------------------------------- helpers
def interleave(values, width):
    n = len(values)
    out = bytearray(n * width)
    for i, v in enumerate(values):
        for j in range(width):
            out[j * n + i] = v[j]
    return bytes(out)

def deinterleave(buf, n, width):
    return [bytes(buf[j * n + i] for j in range(width)) for i in range(n)]

def zz(v):
    return ((v << 1) ^ (v >> 31)) & 0xFFFFFFFF

def encode_refs(refs):
    vals = []
    prev = 0
    for r in refs:
        d = r - prev
        prev = r
        vals.append(zz(d).to_bytes(4, "big"))
    return interleave(vals, 4)

def decode_refs(buf, n):
    vals = _deinterleave_u32(buf, n)
    out, acc = [], 0
    for v in vals:
        acc += (v >> 1) ^ -(v & 1)
        out.append(acc)
    return out

def chunk_bytes(name, body):
    comp = lz4.block.compress(bytes(body), store_size=False)
    return name.encode("latin1") + struct.pack("<III", len(comp), len(body), 0) + comp

WIDTH = {0x1B: 8, 0x1C: 4, 0x1F: 16, 0x21: 8}

# ---------------------------------------------------------------- what changes
rows = [l.split("\t") for l in open(manifest).read().splitlines()]
by_ref = {}
known_rel = set()
for ref, cls, full, rel in rows:
    known_rel.add(rel)
    ref = int(ref)
    path = os.path.join(src_dir, rel)
    if not os.path.exists(path):
        continue
    new = open(path, "rb").read()
    old = p.props.get((ref, "Source"), b"")
    if new != old:
        by_ref[ref] = new

full_to_ref = {}
for r in p.class_of:
    full_to_ref.setdefault(p.full_name(r), r)

added = []  # (ref, parent_ref, name, source)
next_ref = max(p.class_of) + 1
for dp, dn, fn in os.walk(src_dir):
    for f in sorted(fn):
        if not f.endswith(".luau") or f.endswith(".client.luau") or f.endswith(".server.luau"):
            continue
        rel = os.path.relpath(os.path.join(dp, f), src_dir)
        if rel in known_rel:
            continue
        full = rel[:-5].replace(os.sep, ".")
        parent_full, name = full.rsplit(".", 1)
        parent = full_to_ref.get(parent_full)
        if parent is None:
            sys.exit("no parent instance for new module " + full)
        added.append((next_ref, parent, name, open(os.path.join(dp, f), "rb").read()))
        next_ref += 1

ms_cid = next(cid for cid, (c, _) in p.classes.items() if c == "ModuleScript")
ms_refs = p.classes[ms_cid][1]
template = ms_refs[0]  # an existing ModuleScript whose non-name properties new ones copy

print("changed sources:", len(by_ref), " new modules:", [(a[2], p.full_name(a[1])) for a in added])

# ---------------------------------------------------------------- rewrite
out = bytearray(p.header)
if added:
    struct.pack_into("<i", out, 20, p.inst_count + len(added))

for ch in p.chunks:
    d = ch.data
    if ch.name == "INST" and added:
        cid, = struct.unpack_from("<I", d, 0)
        if cid == ms_cid:
            ln, = struct.unpack_from("<I", d, 4)
            head = d[:8 + ln + 1]
            n, = struct.unpack_from("<I", d, 8 + ln + 1)
            refs = decode_refs(d[8 + ln + 5:8 + ln + 5 + 4 * n], n)
            assert refs == ms_refs
            refs = refs + [a[0] for a in added]
            body = bytearray(head) + struct.pack("<I", len(refs)) + encode_refs(refs)
            out += chunk_bytes("INST", body)
            continue
    if ch.name == "PROP":
        cid, = struct.unpack_from("<I", d, 0)
        ln, = struct.unpack_from("<I", d, 4)
        pname = d[8:8 + ln].decode("utf-8", "replace")
        tid = d[8 + ln]
        cname, refs = p.classes[cid]
        touch_src = pname == "Source" and tid == 0x01 and any(r in by_ref for r in refs)
        touch_add = cid == ms_cid and added
        if touch_src or touch_add:
            n = len(refs)
            vals_at = 8 + ln + 1
            body = bytearray(d[:vals_at])
            if tid in (0x01,):
                vals, o = [], vals_at
                for _ in range(n):
                    sl, = struct.unpack_from("<I", d, o)
                    vals.append(d[o + 4:o + 4 + sl])
                    o += 4 + sl
                vals = [by_ref.get(r, v) if pname == "Source" else v for r, v in zip(refs, vals)]
                if touch_add:
                    tv = vals[refs.index(template)]
                    for a in added:
                        if pname == "Name":
                            vals.append(a[2].encode("utf-8"))
                        elif pname == "Source":
                            vals.append(a[3])
                        elif pname == "ScriptGuid":
                            vals.append(b"")
                        else:
                            vals.append(tv)
                for v in vals:
                    body += struct.pack("<I", len(v)) + v
            elif tid == 0x02:
                vals = list(d[vals_at:vals_at + n])
                if touch_add:
                    vals += [vals[refs.index(template)]] * len(added)
                body += bytes(vals)
            elif tid in WIDTH:
                w = WIDTH[tid]
                vals = deinterleave(d[vals_at:vals_at + n * w], n, w)
                if touch_add:
                    tv = vals[refs.index(template)]
                    for _ in added:
                        if tid == 0x1F:  # UniqueId / HistoryId: keep it unique, randomise the tail
                            nv = bytearray(tv)
                            for j in range(8, 16):
                                nv[j] = random.randrange(256)
                            vals.append(bytes(nv))
                        else:
                            vals.append(tv)
                body += interleave(vals, w)
            else:
                sys.exit("unhandled property type 0x%x on %s.%s" % (tid, cname, pname))
            out += chunk_bytes("PROP", body)
            continue
    if ch.name == "PRNT" and added:
        n, = struct.unpack_from("<I", d, 1)
        kids = decode_refs(d[5:5 + 4 * n], n)
        pars = decode_refs(d[5 + 4 * n:5 + 8 * n], n)
        kids += [a[0] for a in added]
        pars += [a[1] for a in added]
        body = bytearray(d[:1]) + struct.pack("<I", len(kids)) + encode_refs(kids) + encode_refs(pars)
        out += chunk_bytes("PRNT", body)
        continue
    out += ch.raw

open(out_path, "wb").write(out)
print("wrote", out_path, len(out), "bytes")
