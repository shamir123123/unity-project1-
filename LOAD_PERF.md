# City load speed: fixes, and how to verify them in Studio

Branch `claude/vibrant-gauss-281evk`. The baseline is commit `4320344`, the scripts exactly as
they are in the uploaded `before_fix.rbxl`.

**What's here:**
- `place/after_fix.rbxl` is the uploaded place with the fixes applied. Only script sources
  changed, plus two new ModuleScripts. Every other byte is copied from the original.
- `place/src/` holds every script in the place, already patched. The changes are the diff
  `git diff 4320344..HEAD -- place/src`: 20 files changed, 2 new.
- `tools/loadperf/` is the offline test harness the numbers below came from.

> **Read this first: what was and was not measured.** Every number below comes from running
> the game's real Luau modules under Lune, outside Roblox, with engine calls stubbed. These
> numbers show **ratios and scaling** (O(n²) → O(n), seconds → milliseconds). They are **not**
> Studio wall-clock times. Nobody has timed a load in the real engine yet. That's step 3 of the
> checklist, and it decides whether the 15 s target is met.

---

## 1. Apply

Pick one:

- **A: open `place/after_fix.rbxl`** in Studio, then File → Save to Roblox over the game, or
  copy the scripts across. This is the easiest option, but only if the live place hasn't been
  edited since `before_fix.rbxl` was exported.
- **B: apply the diff by hand.** Use this if the place changed since the export. For each file
  in `git diff --stat 4320344..HEAD -- place/src`, open the matching script (its path mirrors
  the Explorer: `place/src/ServerScriptService/Services/City/BuildingService.luau` is
  `ServerScriptService.Services.City.BuildingService`) and apply the hunks. Create the two new
  ModuleScripts:
  - `ReplicatedStorage.Terrain.TerrainStreamCodec`
  - `ServerScriptService.Tests.LoadStressTest`

Then regenerate `CODE_INDEX.md` with the snippet at its bottom, since two modules were added
(CLAUDE.md rule).

## 2. Verify, in this order

1. **Script Analysis is clean.** Open the Script Analysis window. The changed files must show
   no new warnings compared with before. They are all `--!strict` except LoadStressTest, which
   is a `--!nonstrict` tool like SpecRunner.
2. **Specs.** In Play mode (server), run
   `print(require(game.ServerScriptService.Tests.SpecRunner)())` from the command bar. Results
   should match a run on the old place. The offline harness ran every spec before and after,
   and the results were identical.
3. **Normal load timing.** Play, then press CONTINUE on an existing city, and read:
   - **server:** `[CitySlotLoad] ...` and `[CityRestore] <phase> + <phase> ...`, which lists
     every restore phase over 50 ms;
   - **client:** `[CityLoad] ...` and
     `[TerrainBuild] Xs = stream + near + far + draw`.

   Note the totals. Do it once with the old place and once with the new one on the **same
   save**.
4. **Big-city stress test.** Load a **throwaway** slot. It gets overwritten. On the server
   command bar, run:
   ```lua
   require(game.ServerScriptService.Tests.LoadStressTest).run({ blocks = 24, population = 100000 })
   ```
   This prints phase times (build, save, pack, two reloads), building, people and car counts,
   instance count, memory, blob size, and terrain stream raw vs packed. If population ends
   under the target, there aren't enough homes, so raise `blocks` (max 60). Then save from the
   game menu, Stop, Play, and press CONTINUE to time the **client** half on that big city with
   the logs from step 3. Things to check:
   - the save blob stays well under 16 MB (it's printed);
   - no "Script timeout" or "exhausted allowed execution time" errors anywhere;
   - roads are all drawn after load (a killed render pass used to leave them missing);
   - the loading screen leaves on its own, and the far horizon fills in behind you within a
     few seconds.
5. **Deleted trees stay deleted.** This tests the bug fix:
   1. Start a **new** city.
   2. Box-select or bulldoze a big patch of trees, more than 64 at once so it goes out in
      several batches.
   3. Wait about 25 s. The debounced save fires 20 s after the first edit. A successful save
      logs nothing; a failure warns `[CitySlotService] edit save failed`.
   4. Stop, Play, and press CONTINUE.

   The trees must stay gone. Also try deleting, then leaving immediately (the leave-save covers
   it). Also try a fresh city with no edits, then rejoin: it must load the **saved** city, not
   regenerate.
6. **Visual pass.** Check that:
   - there are no cracks between terrain chunks (edge rows use the old sampling path);
   - water shows over edited terrain;
   - bus stops sit on their roads after load;
   - roads near bus stops still get their stop cut-outs when a stop is added or removed;
   - parked cars look right (paint varies per car).

If anything regresses, every fix is its own commit (`git log 4320344..HEAD`), so it can be
reverted alone.

---

## 3. What was slow, and what changed

Lune timings are before → after. "Identical" means the old and new code were run side by side
on the same input and the outputs compared.

### Server: restoring a city

| Problem | Fix | Measured (Lune) |
|---|---|---|
| `BuildingService.plotFootprintBlocked` checked **every lot in the city** for every building restored: O(n²), about 200M box tests at 20k buildings | 64-stud grid of footprints (`setFootprint`/`clearFootprint`) | 20k placements: **128 s → 0.47 s**, 0 mismatches |
| `RoadNetwork.getOrCreateNodeWithin` scanned every node for every road end during restore | node grid used only during `applySnapshot` (`beginBulkWeld`/`endBulkWeld`) | 3,291 roads: **5.5 s → 0.04 s** (7,320 roads was 38 s); identical topology hash |
| `RoadNetwork.audit` crossing check tested all n²/2 segment pairs | cell grid, same pair order | 3.3k roads: **2.7 s → 0.8 s**, same 22 crossings found |
| End-of-restore prop sweep (`RoadProximity.propsOnRoads`): every prop vs every road | 128-stud road grid, same broad-phase box | 3k roads × 6k props: **30 s → 0.68 s**, 0 mismatches |
| `LotDressingService.rebuildLotMesh` scanned every road mesh piece for every lot | 64-stud grid of pieces | O(n²) → near-linear |
| `VehicleFactory.build` re-did scale fit, hitbox, welds and attributes for **every** car (a load spawns up to 12,000 parked cars) | rig each template once, clone per car, paint per car | per-car setup → one clone |
| Save chunks read one DataStore round trip after another (big city = up to 4 keys) | chunks 2..N read in parallel (30 s backstop, same failure handling) | ~3 round trips saved on big saves |
| `TerrainGenerator` fill (full map generated on every load) | cached bilinear weights, inlined conversion, sea-level template copy | fill ~1.24 s → ~0.78 s, heights byte-identical |

### Server: things that could get stuck or be killed

- **Road render pass.** After a city load, RoadService re-rendered every segment (~5 ms each)
  and junction (~8 ms each) **in one unyielded pass**, plus the nav rebuild. On a big city
  that's tens of seconds of script time in one go. A live server kills threads at about 10 s,
  which left roads undrawn. Passes over 64 items now yield every 50 ms. `CitySerializer.restore`
  waits for the pass (`RoadService.waitForRender`) before placing buildings, so lots still meet
  finished road edges, same order as before.
- **City-switch teardown** (`BuildingService.restoreBuildings`) now yields every 100 ms.

### Client: joining and the loading screen

| Problem | Fix | Measured (Lune) |
|---|---|---|
| Terrain mesh build called a sampler function **per corner** (~9M calls a map) | `FillRow` reads rows straight off the chunk buffers | full map: strideErrors **3.8 s → 0.87 s**, coarse geometry **5.4 s → 2.3 s**; bit-identical over all 1,024 chunks |
| Edited terrain streamed raw: 16.9 KB a chunk, 12 a message, behind a 30 s timeout | new `TerrainStreamCodec` (zigzag delta + Zstd), 32 chunks a message; old clients still get raw | 300 edited chunks: **4,951 KB → 292 KB (16.9×)**, byte-exact round trip |
| Loading screen waited for the **whole map** to be meshed | auto-enter once every chunk has heights + water and the ground is drawn within 2,048 studs of the camera; the far horizon finishes behind the player | depends on map; removes the far-horizon wait |
| Fixed floors: 5 s minimum loading screen, 1.0 s logo hold | 1.5 s and 0.35 s (both only after the city is ready) | **−4.15 s** on every load, small cities most of all |
| `RoadPieces`: every bus stop arriving re-meshed every road within 400 studs (~100 roads a stop, for every stop during a load); `stopsOn` tested every stop against every road | stop grid; only roads whose control box (+100 studs) holds the stop are rebuilt | storm → a handful of roads a stop |
| `RoadPieces` topology rebuild for the whole network ran in one frame on load | passes over 64 nodes yield every 30 ms; small edits still finish immediately | no long freeze |

## 4. Bug fix: deleted trees came back on reload

There were two independent causes.

1. **The delete was silently dropped.** `RequestRemoveNature` (and Place/Move) ignored any call
   that arrived within 0.08 s of the previous one. The bulldozer sends big deletes as 64-prop
   batches 0.1 s apart, so network jitter regularly landed two closer than 0.08 s, and the
   server threw away a whole batch without saying anything. Those trees were never removed
   server-side, so they were saved and reloaded. Now the rate limit counts **items** with a
   token bucket: it refills at the old ceiling (64 per 0.08 s) with a burst of 256. Bunched
   batches pass. Sustained spam is held to the same rate, and that is now logged instead of
   silent (CLAUDE.md: reject and log).
2. **The delete was never saved.** A new slot had no saved blob until its first autosave
   (5 min) or a clean leave, and loading a slot with no blob re-ran map generation with the
   same seed and the same trees. Now:
   - a brand-new city is saved right after it's generated, so generation runs once per slot;
   - `CitySlotService.saveSoon()` saves 20 s after the first nature edit, never within 60 s
     of the last such save. `NaturePlaceService` calls it after a place, remove or move lands
     (wired in Bootstrap with `setEditListener`).

## 5. Behavior changes to know about

- **Auto-enter radius:** `AUTO_ENTER_RADIUS = 2048` in `MainMenuController`. Set it to
  `math.huge` to go back to waiting for the whole map.
- **Loading screen floors:** `MIN_LOADING_SCREEN_TIME` 5 → 1.5 s, `LOGO_HOLD` 1.0 → 0.35 s.
- **More DataStore writes:**
  - nature edits cause at most one extra save a minute (`SOON_SAVE_DELAY` / `SOON_SAVE_GAP`
    in CitySlotService);
  - a new city is saved once at creation. That save replaces the separate index write it
    used to do.
- **Rate-limit logging:** a client exceeding the nature rate limit is now warned in the log.
  Clients were never told before, and they still aren't.
- **Terrain stream:** a new `RequestTerrainBuild` payload `{ packed = true }`. The server falls
  back to the old raw stream for anything else.

## 6. Not done yet: the remaining load costs, biggest first

These were found but not changed. Each is a bigger design decision.

1. **Parked cars.** Up to 12,000 car Models of about 22 instances each are created and
   replicated on load: roughly 260k instances. Rigging is cheaper now, but the instance count
   is the same. This is most likely the largest remaining cost on a big city. Options:
   - spawn parked cars near the camera only;
   - build them over several seconds after the loading screen;
   - use one mesh per lot.
2. **Full-map terrain generation on every load** (~1–2 s server). The generated base could be
   cached, or only edited chunks applied on top of a lazily generated base.
3. **Nav graph rebuild** is still one unyielded call (~2 s at about 3k roads in Lune). It
   doesn't block the load, but it could be time-sliced like the render pass.
4. **Engine-side mesh work** (EditableMesh bake and fill) isn't visible to the offline harness.
   Parallel Luau (Actors) for the client terrain build is the next step if `[TerrainBuild]`
   still dominates.
5. **StreamingEnabled is off,** so every client receives the whole city before play. Turning it
   on is the biggest possible client win, but it touches everything that assumes instances
   exist.
6. **WorldReveal** hides and restores per instance. With hundreds of thousands of instances
   that's worth timing.

## 7. Test harness

`tools/loadperf/README.md` explains it: run the place's real ModuleScripts under Lune,
benchmark one subsystem with a synthetic big city, and compare old and new outputs.
`tools/loadperf/patch_rbxl.py` produced `place/after_fix.rbxl`.

---

*Process note: the project's CLAUDE.md says "Do not make commits". That rule is for the Studio
project. This repo was the agreed place to deliver the fixes, so the work is committed here on
a branch. Nothing has been changed in the live game.*
