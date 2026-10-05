# Load-time test harness (Lune)

Runs the place's real Luau modules outside Roblox, under [Lune](https://github.com/lune-org/lune)
(the same Luau VM as the Roblox client), to time and diff the pure-script parts of a city load.

```
pip install lz4 zstandard
tools/loadperf/setup.sh path/to/place.rbxl        # builds .loadperf/ (gitignored)
cd .loadperf && lune run bench/<name>.luau [args]
```

- `rbxl.py` / `dump.py` - read a binary place, dump every script to `Service/Folder/Name.luau`.
- `patch_rbxl.py` - write a copy of the place with script Sources replaced from a source tree
  and new ModuleScripts appended (everything else byte-for-byte). This is how
  `place/after_fix.rbxl` was produced.
- `bundle.py` + `runtime.luau` - wrap every ModuleScript into one Lune-loadable bundle;
  `require(instance)` resolves by full name against the place's real DOM. Engine APIs Lune
  lacks are stubbed (signals never fire, pivots are approximate, EncodingService = Lune zstd).
- `bench/` - each prints old-vs-new timings and an equivalence check where one applies.

Limits: Lune's Vector3/CFrame are userdata (~10-30x slower than Roblox's native vector), and
engine work (EditableMesh bakes, instance replication, DataStore) is stubbed. Use the numbers
for SCALING and before/after ratios; use `ServerScriptService.Tests.LoadStressTest` in Studio
for real engine timings.
