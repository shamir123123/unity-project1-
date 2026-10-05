# Traffic lab

Runs the game's real traffic modules on a fake engine, outside Studio:
- the road graph;
- NPCDriverService;
- PathFollower;
- signals;
- through traffic;
- buses;
- the citizen trip legs.

It builds test cities in code, drives cars for a few simulated minutes and reports throughput,
trip times, collisions and stuck cars. I used it for every change in `src/`.

Use it as a regression check. It is not a replacement for watching the game. Rendering,
replication and real Instances are faked, so frame times here mean nothing for Studio. Use
`TrafficBenchmark` for that.

## Setup

1. Install [lune](https://github.com/lune-org/lune), version 0.8 or later.
2. Install `pip install lz4 zstandard` for the script extractor.
3. Extract the place's scripts once (any `.rbxl` saved from Studio):

   ```
   python3 extract_scripts.py path/to/place.rbxl original-src
   ```

## Run

From this folder:
- `LAB_SRC` is the extracted original tree.
- `LAB_PATCH` is a tree whose files replace the originals, such as the repo's `src/`.

```
export LAB_SRC=original-src
LAB_PATCH=../../src lune run scen/roundabout.luau Roundabout1 NarrowRoad 0.12 300
LAB_PATCH=../../src lune run scen/grid.luau 5 0.03 300
./regress.sh ../../src              # the suite, one line per scenario
./regress_multi.sh out ../../src    # the suite on seeds 1-3, 4 runs in parallel
```

Leave `LAB_PATCH` empty to run the originals for comparison. `LAB_SEED` picks the random seed.

## Scenarios

| Script | What it measures |
|---|---|
| `scen/roundabout.luau <preset> <road> <rate> <secs>` | Roundabout throughput and trip time |
| `scen/grid.luau <N> <rate> <secs>` | An N×N signalised and priority grid; throughput, time-by-reason breakdown, collisions |
| `scen/lot.luau <through> <lot> <secs> <road> [single]` | Car parks on a busy street; lot trips, pocketed cars |
| `scen/satflow.luau <road> straight` | Queue discharge headway at a signal (saturation flow) |
| `scen/capacity.luau <road> [entrySpeed]` | Lane capacity on a long road fed above capacity |
| `scen/bus.luau <rate> <secs> <buses>` | Buses on a loop through traffic; stops served, collisions |
| `scen/through.luau <road> <secs>` | Through traffic ramp, then save and restore |
| `scen/scenery.luau` | Route choice by trip group (PASS/FAIL) |
| `scen/bench.luau` | Smoke test of TrafficBenchmark |
| `scen/prof.luau <cars>` | Where a driver frame goes (helper calls per frame) |
| `scen/sharedlane.luau` | A turner and a straight car from one lane through a box: do they stay apart? |
| `mode_table.luau` | Mode-choice shares by distance, parking, weather, price; school-run shares |
| `captured_restore.luau <bodyLength>` | The NPCDriverService spec's captured-city restore, with details on stuck cars |

`python3 summarize.py <origDir> <newDir>` turns two `regress_multi.sh` output folders into the
comparison table in APPLY.md.

## Specs

`t_spec.luau` runs a TestEZ-style spec module with a small shim:
- Studio's `loadstring`, `setfenv` and `script.Source` are emulated;
- `SPEC_PATCH=1` patches two stale harness tables in the CitizenService spec.

```
SPEC_PATCH=1 LAB_PATCH=../../src lune run t_spec.luau ServerScriptService.Services.NPC.NPCDriverService.spec
```
