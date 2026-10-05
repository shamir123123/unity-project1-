import sys, os, collections
sys.path.insert(0, os.path.dirname(__file__))
from rbxl import Place
p = Place(sys.argv[1])
out = sys.argv[2]
print("classes", p.class_count, "instances", p.inst_count, "parsed", len(p.class_of))
cnt = collections.Counter(p.class_of.values())
for k, v in cnt.most_common(40): print(f"  {k}: {v}")
scripts = p.scripts()
print("scripts", len(scripts))
seen = set()
manifest = []
for r, c, fn, src in sorted(scripts, key=lambda x: x[2]):
    ext = {"ModuleScript": ".luau", "LocalScript": ".client.luau", "Script": ".server.luau"}[c]
    rel = fn.replace(".", "/")
    path = rel + ext
    if path in seen:
        path = rel + f"__ref{r}" + ext
    seen.add(path)
    fp = os.path.join(out, path)
    os.makedirs(os.path.dirname(fp), exist_ok=True)
    with open(fp, "wb") as f: f.write(src if isinstance(src, bytes) else b"")
    manifest.append(f"{r}\t{c}\t{fn}\t{path}")
with open(os.path.join(out, "_manifest.tsv"), "w") as f: f.write("\n".join(manifest))
