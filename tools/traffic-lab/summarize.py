import re,sys,glob,os,statistics as st
def load(d):
    out={}
    for f in glob.glob(os.path.join(d,'*.txt')):
        name,seed,_=os.path.basename(f).split('.')
        t=open(f).read()
        m=re.search(r'arrived=(\d+) \((\d+)/h\).*?stuck=(\d+) meanTrip=([\d.]+)s',t)
        c=re.search(r'COLLISIONS (\d+)',t)
        p=re.search(r'pocketed=(\d+)',t)
        dn=re.search(r'done=(\d+)',t)
        if not m: continue
        out.setdefault(name,[]).append(dict(rate=int(m.group(2)),stuck=int(m.group(3)),trip=float(m.group(4)),coll=int(c.group(1)) if c else 0,pocket=int(p.group(1)) if p else None,done=int(dn.group(1)) if dn else None))
    return out
b=load(sys.argv[1]); n=load(sys.argv[2])
order=['cross4','ra2','grid03','grid06','lot','lotS']
desc={'cross4':'single-lane roundabout, 4 arms','ra2':'two-lane roundabout','grid03':'5x5 grid, moderate demand','grid06':'5x5 grid, heavy demand','lot':'street with car parks (2 exits)','lotS':'street with car parks (1 exit)'}
print('| Scenario | Throughput (cars/h) orig -> new | Mean trip (s) orig -> new | Collisions orig -> new | Pocketed (lot) orig -> new |')
print('|---|---|---|---|---|')
for k in order:
    if k not in b or k not in n: continue
    def avg(L,key):
        v=[x[key] for x in L if x[key] is not None]
        return st.mean(v) if v else None
    def tot(L,key):
        v=[x[key] for x in L if x[key] is not None]
        return sum(v) if v else None
    pb,pn=tot(b[k],'pocket'),tot(n[k],'pocket')
    print(f"| {desc[k]} | {avg(b[k],'rate'):.0f} -> {avg(n[k],'rate'):.0f} | {avg(b[k],'trip'):.0f} -> {avg(n[k],'trip'):.0f} | {tot(b[k],'coll')} -> {tot(n[k],'coll')} | " + (f"{pb} -> {pn}" if pb is not None else "-") + " |")
