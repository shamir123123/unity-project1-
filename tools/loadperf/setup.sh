#!/bin/bash
# Build a Lune workspace for the load-time benchmarks:
#   tools/loadperf/setup.sh <place.rbxl> [workdir]
# Needs python3 (+ pip install lz4 zstandard) and a Lune binary on PATH or in the workdir
# (https://github.com/lune-org/lune/releases, 0.10.x). Produces:
#   workdir/place_lune.rbxl   the place with Tags converted so Lune can read it
#   workdir/src_before/       scripts dumped from the place (the "before" code)
#   workdir/bundle_before.luau, bundle_after.luau   (after = this repo's place/src)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLACE="$1"; WORK="${2:-$REPO/.loadperf}"
mkdir -p "$WORK/tools" "$WORK/bench"
cp "$HERE"/*.py "$HERE"/runtime.luau "$WORK/tools/"
cp "$HERE"/bench/*.luau "$WORK/bench/"
python3 "$HERE/fix_tags_for_lune.py" "$PLACE" "$WORK/place_lune.rbxl"
python3 "$HERE/dump.py" "$PLACE" "$WORK/src_before" >/dev/null
python3 "$HERE/bundle.py" "$WORK/src_before" "$WORK/bundle_before.luau"
python3 "$HERE/bundle.py" "$REPO/place/src" "$WORK/bundle_after.luau"
# harness-only debug hooks the comparison benches read
python3 - "$WORK/bundle_after.luau" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
def inject(module, ret, code):
    global s
    i = s.index('__loaders["%s"]' % module)
    j = s.index('\nreturn %s' % ret, i)
    s = s[:j] + '\n' + code + s[j:]
inject("ReplicatedStorage.Terrain.TerrainMeshView", "TerrainMeshView", "TerrainMeshView._debugFillRow = function() return _fillRow end")
inject("ReplicatedStorage.Road.RoadProximity", "RoadProximity", "RoadProximity._segmentGrid = segmentGrid\nRoadProximity._segmentsNear = segmentsNear")
open(p, 'w').write(s)
PY
echo "ready: cd $WORK && lune run bench/terrain_mesh_cmp.luau ../bundle_after"
