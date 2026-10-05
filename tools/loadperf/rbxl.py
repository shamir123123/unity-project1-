"""Minimal Roblox binary place (.rbxl) reader/writer.

Reads the instance tree with Name/Source, and can write back a place with
script Source properties replaced (all other chunks copied byte-for-byte).
"""
import struct
import lz4.block
import zstandard

MAGIC = b"<roblox!\x89\xff\r\n\x1a\n"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def _decompress(comp_len, uncomp_len, data):
    if comp_len == 0:
        return data
    if data[:4] == ZSTD_MAGIC:
        return zstandard.ZstdDecompressor().decompress(data, max_output_size=uncomp_len)
    return lz4.block.decompress(data, uncompressed_size=uncomp_len)


def _deinterleave_i32(buf, n):
    out = []
    for i in range(n):
        v = (buf[i] << 24) | (buf[n + i] << 16) | (buf[2 * n + i] << 8) | buf[3 * n + i]
        # untransform zigzag
        v = (v >> 1) ^ -(v & 1)
        out.append(v)
    return out


def _referents(buf, n):
    vals = _deinterleave_i32(buf, n)
    acc = 0
    out = []
    for v in vals:
        acc += v
        out.append(acc)
    return out


class Chunk:
    def __init__(self, name, raw, data):
        self.name = name
        self.raw = raw  # full bytes incl header
        self.data = data  # decompressed payload


class Place:
    def __init__(self, path):
        with open(path, "rb") as f:
            blob = f.read()
        assert blob[:14] == MAGIC, "not a binary place"
        self.header = blob[:32]
        self.class_count, self.inst_count = struct.unpack_from("<ii", blob, 16)
        self.chunks = []
        pos = 32
        while pos < len(blob):
            name = blob[pos:pos + 4].decode("latin1")
            comp, uncomp, _ = struct.unpack_from("<III", blob, pos + 4)
            body_len = comp if comp else uncomp
            body = blob[pos + 16:pos + 16 + body_len]
            raw = blob[pos:pos + 16 + body_len]
            self.chunks.append(Chunk(name, raw, _decompress(comp, uncomp, body)))
            pos += 16 + body_len
            if name == "END\x00":
                break
        self._parse()

    def _parse(self):
        self.classes = {}  # id -> (name, [refs])
        self.class_of = {}  # ref -> class name
        self.props = {}  # (ref, prop) -> value (only strings we care about)
        self.parent = {}
        self.sstr = []
        for ch in self.chunks:
            d = ch.data
            if ch.name == "INST":
                cid, = struct.unpack_from("<I", d, 0)
                ln, = struct.unpack_from("<I", d, 4)
                cname = d[8:8 + ln].decode("utf-8")
                p = 8 + ln
                p += 1  # object format
                n, = struct.unpack_from("<I", d, p)
                p += 4
                refs = _referents(d[p:p + 4 * n], n)
                self.classes[cid] = (cname, refs)
                for r in refs:
                    self.class_of[r] = cname
            elif ch.name == "PROP":
                cid, = struct.unpack_from("<I", d, 0)
                ln, = struct.unpack_from("<I", d, 4)
                pname = d[8:8 + ln].decode("utf-8", "replace")
                p = 8 + ln
                tid = d[p]
                p += 1
                if tid == 0x01 and pname in ("Name", "Source"):
                    cname, refs = self.classes[cid]
                    for r in refs:
                        sl, = struct.unpack_from("<I", d, p)
                        p += 4
                        self.props[(r, pname)] = d[p:p + sl]
                        p += sl
                elif tid == 0x1C and pname == "Source":
                    # SharedString-backed (rare): index into SSTR
                    cname, refs = self.classes[cid]
                    n = len(refs)
                    idx = _deinterleave_u32(d[p:p + 4 * n], n)
                    for r, i in zip(refs, idx):
                        self.props[(r, pname)] = ("sstr", i)
            elif ch.name == "PRNT":
                n, = struct.unpack_from("<I", d, 1)
                kids = _referents(d[5:5 + 4 * n], n)
                pars = _referents(d[5 + 4 * n:5 + 8 * n], n)
                for k, pa in zip(kids, pars):
                    self.parent[k] = pa
        self.children = {}
        for k, pa in self.parent.items():
            self.children.setdefault(pa, []).append(k)

    def name(self, r):
        v = self.props.get((r, "Name"))
        return v.decode("utf-8", "replace") if isinstance(v, bytes) else "?"

    def full_name(self, r):
        parts = []
        while r is not None and r != -1:
            parts.append(self.name(r))
            r = self.parent.get(r, -1)
        return ".".join(reversed(parts))

    def scripts(self):
        out = []
        for r, c in self.class_of.items():
            if c in ("Script", "LocalScript", "ModuleScript"):
                src = self.props.get((r, "Source"), b"")
                out.append((r, c, self.full_name(r), src))
        return out

    def write(self, path, new_sources):
        """new_sources: {ref: bytes}. Rewrites Source PROP chunks uncompressed."""
        out = bytearray(self.header)
        for ch in self.chunks:
            d = ch.data
            if ch.name == "PROP":
                cid, = struct.unpack_from("<I", d, 0)
                ln, = struct.unpack_from("<I", d, 4)
                pname = d[8:8 + ln].decode("utf-8", "replace")
                tid = d[8 + ln]
                cname, refs = self.classes[cid]
                if pname == "Source" and tid == 0x01 and any(r in new_sources for r in refs):
                    body = bytearray(d[:8 + ln + 1])
                    for r in refs:
                        s = new_sources.get(r, self.props[(r, "Source")])
                        body += struct.pack("<I", len(s)) + s
                    comp = lz4.block.compress(bytes(body), store_size=False)
                    out += b"PROP" + struct.pack("<III", len(comp), len(body), 0) + comp
                    continue
            out += ch.raw
        with open(path, "wb") as f:
            f.write(out)


def _deinterleave_u32(buf, n):
    out = []
    for i in range(n):
        out.append((buf[i] << 24) | (buf[n + i] << 16) | (buf[2 * n + i] << 8) | buf[3 * n + i])
    return out
