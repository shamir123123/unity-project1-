import struct, sys, os, lz4.block, zstandard, json

def read_chunks(data):
    assert data[:8] == b'<roblox!'
    pos = 32
    while pos < len(data):
        name = data[pos:pos+4]; clen, ulen, _ = struct.unpack('<III', data[pos+4:pos+16]); pos += 16
        if clen == 0:
            body = data[pos:pos+ulen]; pos += ulen
        else:
            raw = data[pos:pos+clen]; pos += clen
            if raw[:4] == b'\x28\xb5\x2f\xfd':
                body = zstandard.ZstdDecompressor().decompress(raw, max_output_size=ulen)
            else:
                body = lz4.block.decompress(raw, uncompressed_size=ulen)
        yield name, body
        if name == b'END\0': break

class R:
    def __init__(s, b): s.b=b; s.p=0
    def u8(s): v=s.b[s.p]; s.p+=1; return v
    def u32(s): v=struct.unpack_from('<I', s.b, s.p)[0]; s.p+=4; return v
    def string(s): n=s.u32(); v=s.b[s.p:s.p+n]; s.p+=n; return v
    def interleaved(s, n, width=4):
        raw = s.b[s.p:s.p+n*width]; s.p += n*width
        out=[]
        for i in range(n):
            v=0
            for j in range(width): v=(v<<8)|raw[j*n+i]
            out.append(v)
        return out
    def ints(s, n):
        return [ (v>>1) ^ -(v&1) for v in s.interleaved(n)]
    def refs(s, n):
        vals=s.ints(n); acc=0; out=[]
        for v in vals: acc+=v; out.append(acc)
        return out

def parse(path):
    data=open(path,'rb').read()
    classes={}; inst_class={}; props={}; parent={}; sstr=[]
    for name, body in read_chunks(data):
        r=R(body)
        if name==b'SSTR':
            r.u32(); n=r.u32()
            for _ in range(n): r.p+=16; sstr.append(r.string())
        elif name==b'INST':
            cid=r.u32(); cname=r.string().decode(); fmt=r.u8(); n=r.u32(); refs=r.refs(n)
            classes[cid]=(cname, refs)
            for x in refs: inst_class[x]=cname
        elif name==b'PROP':
            cid=r.u32(); pname=r.string().decode(); t=r.u8()
            cname, refs = classes[cid]
            if pname in ('Name','Source','AttributesSerialize','Tags','Disabled','Enabled','RunContext') or t==0x01:
                if t==0x01:
                    for x in refs: props.setdefault(x,{})[pname]=r.string()
                elif t==0x1C:
                    idx=r.interleaved(len(refs))
                    for x,i in zip(refs,idx): props.setdefault(x,{})[pname]=sstr[i]
                elif t==0x02:
                    for x in refs: props.setdefault(x,{})[pname]=r.u8()
                elif t==0x12:
                    vals=r.interleaved(len(refs))
                    for x,v in zip(refs,vals): props.setdefault(x,{})[pname]=v
        elif name==b'PRNT':
            r.u8(); n=r.u32(); ch=r.refs(n); pa=r.refs(n)
            for c,p in zip(ch,pa): parent[c]=p
    return inst_class, props, parent

if __name__=='__main__':
    inst_class, props, parent = parse(sys.argv[1])
    out=sys.argv[2]
    def name(x): return props.get(x,{}).get('Name',b'?').decode('utf-8','replace')
    def path(x):
        parts=[]
        while x is not None and x!=-1 and x in inst_class:
            parts.append(name(x)); x=parent.get(x)
        return list(reversed(parts))
    count=0; index=[]
    for x,c in inst_class.items():
        if c in ('Script','LocalScript','ModuleScript'):
            p=path(x); src=props.get(x,{}).get('Source',b'')
            ext={'Script':'.server.luau','LocalScript':'.client.luau','ModuleScript':'.luau'}[c]
            # nested scripts: store as dir/__self
            rel=os.path.join(out,*p)+ext
            os.makedirs(os.path.dirname(rel),exist_ok=True)
            if os.path.exists(rel): rel=rel.replace(ext, f'.dup{x}{ext}')
            open(rel,'wb').write(src); count+=1
            index.append({'path':'.'.join(p),'class':c,'file':os.path.relpath(rel,out),'lines':src.count(b'\n')+1})
    json.dump(index, open(os.path.join(out,'_index.json'),'w'), indent=1)
    print(count,'scripts', len(inst_class),'instances')
