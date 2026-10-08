# Performance pass — 2026-10-07 (overnight)

Branch `claude/compassionate-davinci-9q190n`. Every script in the place was extracted
verbatim from `before_fix.rbxl` into `src/` (commit `5858734`); every later commit is a fix
on top of that baseline, so `git diff 5858734 -- src/` is exactly what changed.

**Nothing here was run in Roblox Studio.** This session had the place file but no Studio.
Each change was type-checked against Roblox's API (luau-lsp, strict, new diagnostics only)
and the logic was run offline against the game's own modules (Lune harness in
`tools/harness/`, engine APIs mocked). Timings from the harness are relative only — Lune's
Vector3 is ~20–50× slower than Roblox's native vectors. See "Verify in Studio" below.

## How to apply

`tools/changed_scripts.sh` prints every changed (M) or new (A) script as
`status  Studio path  ClassName  file`. For each row, replace the script's Source in Studio
with the file's contents. For `A` rows, first create a script of that class at that path.

Current list (run the script for the up-to-date one):

| | Studio path | Class |
|---|---|---|
| M | ServerScriptService.Services.City.CityStatsService | ModuleScript |
| M | ServerScriptService.Services.City.Civic.CrimeService | ModuleScript |
| M | ServerScriptService.Services.City.Civic.DeathcareService | ModuleScript |
| M | ServerScriptService.Services.City.Civic.SicknessService | ModuleScript |
| M | ServerScriptService.Services.City.Economy.CityEconomyService | ModuleScript |
| M | ServerScriptService.Services.City.PowerService | ModuleScript |
| M | ServerScriptService.Services.City.ProgressionService | ModuleScript |
| M | ServerScriptService.Services.City.Simulation.FireService | ModuleScript |
| M | ServerScriptService.Services.City.WaterService | ModuleScript |
| M | ServerScriptService.Services.Road.RoadService | ModuleScript |
| M | ReplicatedStorage.Road.TrafficSignPlanner | ModuleScript |
| M | ReplicatedStorage.Terrain.TerrainMeshView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.Bootstrap.Bootstrap | LocalScript |
| M | StarterPlayer.StarterPlayerScripts.Core.SettingsClient | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.HUD.BuildingInfoController | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.SeasonTintClient | LocalScript |
| M | StarterPlayer.StarterPlayerScripts.World.AmbienceController | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.AmbientCityView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.AssetLODView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.NodeToolView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.PedestrianView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.RoadEditPreview | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.RoadMeshView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.RoadPieces | ModuleScript |
| **A** | StarterPlayer.StarterPlayerScripts.World.**StreetLightView** | ModuleScript (new) |
| M | StarterPlayer.StarterPlayerScripts.World.StreetNameView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.TrafficJamView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.TrafficSignView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.WaterView | ModuleScript |
| M | StarterPlayer.StarterPlayerScripts.World.WindowLightsView | ModuleScript |

After applying, regenerate `CODE_INDEX.md` (one new module: StreetLightView).

## What changed, and why

### 1. Placing a road — instant

The road you place is drawn by the client (RoadPieces → RoadMeshView) from the topology
delta the server sends. Four things stood between the click and the real road:

- **Server render in the same frame as the edit** (`RoadService`). After every edit the
  server re-rendered every touched segment and junction (street furniture + mesh blobs,
  ~5–8 ms each per the code's own notes) *in the frame that carries the delta to clients*,
  and many pieces twice (the nav flush re-rendered approach arms, then the pass rendered
  them again). Now one worker renders a de-duplicated queue starting two Heartbeats after
  the edit, ~6 ms per frame; a city load still renders in 50 ms slices exactly as before,
  and `waitForRender` still waits for it. The nav-graph flush stays in the edit's frame
  (traffic-signal discovery reads it on the next Heartbeat). Offline: 8 placements in one
  frame — old code drew 28 of 40 pieces more than once; new code draws each once.
- **Re-baking cells that did not change** (`RoadPieces`). An edit rebuilds every road at a
  touched node and most come back identical; each one still dirtied its 256-stud cell (a
  full re-bake). A piece rebuilt to identical specs no longer dirties anything.
  Offline, a short link between two streets: **7 cells → 3** re-baked.
- **Re-solving roads the server only re-sent** (`RoadPieces`). The server's delta carries
  every road at a touched node as a fresh table; RoadPieces judged "changed" by table
  identity. Equal records now keep the drawn table. Client rebuild per placement:
  **170 → 52 ms / 199 → 48 ms** (Lune-relative). Output digest identical to the old code.
- **Replicated server models re-baking cells** (`RoadMeshView`). When the server's
  Segment_/Junction_ models for pieces RoadPieces already draws replicate in, each one
  re-baked its cell (and threw away the bake in flight). Their blobs are never baked, so
  they no longer trigger anything.
- **Static bakes** (`RoadMeshView`, *LIVE BAKES*). A static mesh bake is ~25–35 ms of
  blocking engine work per mesh and roughly one completes per frame; a cell is 3–5 meshes.
  Cells re-baked by an **edit** now bake *live* — the same FixedSize-EditableMesh path
  TerrainMeshView already uses for the sculpt brush (measured there ~6 ms vs ~36 ms).
  Capped (32k triangles / 24 meshes); past 16k / 12 the longest-quiet cells settle back to
  static in the background. City loads, lot ground and anything over budget stay static.
  Offline: load = all static; each edit = live, 0 static bakes; settle trims back under
  the watermark; a refused snapshot falls back to static.

### 2. Upgrading a road — instant

- Upgrade/delete used to hide the affected cells and stand **crude flat Parts** in for every
  road in them until the server answered (a full round trip), because the predicted mesh
  took that long to bake. The prediction now bakes live a frame or two after the click and
  replaces the old road in place; the flat stand-ins are off (`STAND_IN_CELLS = false` in
  `RoadEditPreview`).
- The server re-sent **every junction's lane data in the city** after each in-place
  upgrade/reversal (`commitInPlace` → full lane-path broadcast). It now re-sends only the
  touched junctions (the incremental path the nav flush already has).

- **Per-edit work for tools that are closed**: on every road edit NodeToolView rebuilt arm
  data for every node in the city (twice: on the segment and the node update) and
  AmbientCityView re-indexed every segment — even with the node tool closed and full city
  sim on (the ambient view is only used when it is off). Both now just mark themselves
  stale and rebuild when they are actually opened/used.

### 3. Ground under road edits (`TerrainMeshView`)

- A road grade marked its chunk dirty, and a chunk inside a 4×4 *backdrop block* rebuilt
  the **whole block** — 16 chunks of geometry, merge and fill (~220 ms measured in the
  file's notes), unsliced — on every edit. Now, after the load, a chunk the city changes
  leaves its block once (block rebuilt urgently without it, so old ground never shows
  through) and redraws alone after that. Offline: old = 16 chunk builds per edit, every
  edit; new = 16 once, then **1 per edit**.
- That one chunk now redraws **live** (no blocking bake on the frame the road goes down)
  and settles to static after 3 s quiet. Offline: 0 static bakes at edit time.
- A city-made change no longer re-stitches its four neighbours (each could be a whole
  block rebuild ending in a blocking bake). Stride cracks are within the skirt depth.

### 4. Terrain LOD (`TerrainMeshView`, `SettingsClient`)

Your read was right: the LOD ladder was **frozen at load** (`bucketOf`: "FROZEN once the
player is in") because re-tiering had caused 20 fps stretches. It now follows the camera:

- **Variants**: a block that re-tiers keeps its old parts parked; returning to a ring it
  was drawn at is a parent swap — no geometry, no bake (matched with the same hysteresis
  `bucketOf` uses). Capped at 300k parked triangles (less on Low), LRU.
- **Throttle**: a re-tier that needs a bake waits 0.4 s after the previous one, and only
  while the camera rests (existing rule). Edits, ejections, the fill and catch-up are
  never held.
- **Draw distance now reaches the ground**: `Settings.renderDistance` scales the ladder
  (`TerrainMeshView.setDetailScale`). City chunks stay full detail.

Offline on Green Valley (real generator + preset): load unchanged (64 bakes, 397k
triangles); fly to a corner and rest → 29 bakes over 25 s, never more than one a frame;
fly back → **0 bakes** (all swaps). **Low preset: 191k ground triangles instead of 397k.**

### 5. Moving the camera around the city

- **Lamp lights** (new `StreetLightView`): every street lamp head, car-park lamp and bridge
  lamp has a SpotLight that was **always on — at noon, at any distance, unlimited**. Now
  lamps cast light only from dusk to dawn, and only the nearest N around the camera focus
  (Low 0 / Medium 32 / High 96 / Ultra 192). Neon lens parts still glow. Signal heads
  (server-switched, under `_City.TrafficLights`) are never touched.
- **Street furniture LOD** (`AssetLODView`): lamps, street trees, name blades and yield
  signs live *inside* road pieces under `_City.Roads`, which AssetLODView skipped
  wholesale — street trees never swapped to their thinned/card LODs. Each furniture model
  is now laddered like any other prop.
- **Traffic signs** (`TrafficSignView`, `TrafficSignPlanner`): signs are pooled models placed
  near the camera. Placing one scanned **every signal pole in the city** to see if it should
  go up on a pole; and 0.6 s after **every road edit** the whole city was re-planned and every
  drawn sign handed back to the pool and placed again. Now: poles are looked up in a grid;
  a replan re-solves only the junctions whose roads changed (the rest reuse last plan — the
  client keeps an unchanged road's record across edits) and signs that did not change stay
  where they are. Also fixed: a sign taken back from the pool kept the previous sign's
  text and could keep its text GUI switched on far away. Offline (1,200 roads, 832 poles):
  per road edit **195 → 14 ms**; sweep after a 500-stud pan **37 → 1.1 ms**; the drawn
  signs are identical; cached and full plans identical across 8 kinds of edit.
- **Shoreline foam** (`WaterView`): every shoreline water tile within ~2,000 studs (up to
  four 256×256 images) was repainted and re-uploaded **on the same frame**, 12 times a
  second — a regular spike anywhere near a coast. Each tile now keeps its own clock, phased
  a quarter interval apart. Offline: worst repaints in one frame **4 → 1** at 60 and 240 fps;
  every tile still 12 Hz.
- **Prop LOD at high frame rates** (`AssetLODView`): while the camera moves, the prop ladder
  scans and swaps in fixed slices of 1 ms + 3 ms per frame — fine at 60 fps, but most of a
  240 fps frame (4.2 ms). The slices now shrink with the frame time (a 240 fps frame gets a
  quarter) and never grow past the old values, so the work per second and the time a re-tier
  takes are unchanged. Offline: same hidden-part counts after three camera moves.
- **Hover** (`BuildingInfoController`): a full-length pick ray ran on *every* mouse-move
  event (several per frame) and re-marshalled the ray filter each time. Now once per
  frame, filter written only when it changes.
- **Rain and fog fades** (`SeasonTintClient`): while the weather faded in or out (40 s for
  rain, 12 s for fog) the client re-tinted **every tree in the city, back to back, for the
  whole fade** — 400 trees a frame — though leaf colour does not depend on wetness. It now
  re-tints only when the frost on the leaves moves. Offline, 2,000 trees, tree re-tints:
  rain fade-in (42 s) **962,000 → 0**; snow 134,000 → 40,000; clearing up 594,000 → 40,000.
  Same colours.
- **Window lights** (`WindowLightsView`): walked every window in the city once a second,
  all day, though no window can be lit between 05:30 and 17:30. After one pass puts them
  all out it now waits for evening. Offline, 2,000 windows: daytime 10,000 window visits
  per 5 s → 0; same lit counts at night.
- **Walkers** (`PedestrianView`): one CFrame write per walker per frame; now one
  `workspace:BulkMoveTo` per frame, as the car view already does. Same positions offline.
- **Hover tooltip** (`BuildingInfoController`): every frame the cursor was over a road or
  the ground, the (already hidden) tooltip started a new fade tween. Now a no-op.
- **Ambience** (`AmbienceController`): counted nearby cars by walking the whole fleet every
  0.8 s; now a radius query on the cars' hitboxes.
- **Street names** (`StreetNameView`): every name was one Part + SurfaceGui + TextLabel
  *per letter* (so names can bend), up to 3,000 plates. A name on a straight span is now
  **one plate** laid on the chord and pitched with the road; curves keep per-letter
  plates. Offline grid: **574 → 106 plates**, identical offsets/heights. And the rebuild
  that runs ~0.35 s after every road edit re-sampled every street in the city; unchanged
  streets now reuse their polyline: **46 → 12 ms** on an 840-segment grid (offline).

### 6. Server sims share the second instead of colliding

Nine city sims (stats, economy, power, water, progression, fire, crime, sickness, deathcare)
each ran `task.wait(period)` in a loop started in the same boot frame, on 1–10 s periods,
and drifted freely — so several of them regularly ran in one server frame (power and water
rebuilds are full-network passes). A long server frame holds back everything else sent that
frame — road deltas, car positions.
Each now waits for its own slot within its period; at 1× speed the slots are:

| Sim | Period | Runs at (s into period) |
|---|---|---|
| CityStats | 1 | 0.0 |
| Economy | 1 | 0.5 |
| Power | 2 | 0.25 |
| Water | 2 | 0.75 |
| Progression | 2 | 1.25 |
| Fire | 4 | 1.75 |
| Crime | 6 | 0.875 |
| Sickness | 8 | 1.375 |
| Deathcare | 10 | 1.625 |

No two share a slot (at any game speed — slots scale with the period). Tick rates are
unchanged. Each tick now has a MicroProfiler label (`PowerService.rebuild`, `FireService.tick`, …).

## Toggles (to A/B in Studio)

| Where | Constant | Off = old behaviour |
|---|---|---|
| RoadMeshView | `LIVE_BAKES` | static bakes for edits |
| RoadEditPreview | `STAND_IN_CELLS` | `true` = old flat-part stand-ins on upgrade/delete |
| TerrainMeshView | `LOD_LIVE` | frozen ladder |
| TerrainMeshView | `LIVE_CITY_EDITS` | static chunk bakes for road edits |
| RoadService | `RENDER_LEAD_FRAMES` / `RENDER_EDIT_BUDGET` | (no flag; 0 lead + large budget ≈ old timing) |

## Verify in Studio (not done here)

MicroProfiler labels added: `RoadMeshView.lod`, `StreetNameView.poll`,
`AmbienceController.sample`, `BuildingInfo.hover`, `TrafficJamView.scan`,
`StreetLightView.sweep`; server: `<Sim>.tick` / `PowerService.rebuild` /
`WaterService.rebuild` for each city sim.

1. Place roads (straight, crossing 5+ streets, T-junction, open ground) and upgrade a few:
   real road should appear within a couple of frames of the delta; no flat stand-ins on
   upgrade; no hitch on placement. Check the Output for `[RoadMeshView]` /
   `[RoadService] render worker` warnings.
2. Place ~20 roads quickly; wait 5 s: no growing memory (Developer Console → Memory →
   GraphicsMeshParts / "EditableMesh"), live cells settle.
3. Load a big city (fresh server), rejoin it, switch cities: roads, junction fills and
   street furniture all present; terrain cut under every road.
4. Fly to a map corner, rest 20 s, fly back: terrain refines near you, no frame spikes
   above one bake every ~0.4 s; flying back is instant.
5. Settings → Low / Medium / Ultra: terrain detail and lamp count follow.
6. Night: nearest lamps lit, signal heads still switch phases.

## Paths checked (per CLAUDE.md 0c)

Offline only: fresh load (bakes static), edits after load (live), many edits in one frame,
budget refusal, settle, removal of the last piece in a cell, server models replicating
after the client drew the piece, city load through the render worker (`waitForRender`).
**Not checked**: Studio Play, live servers, multiplayer (another player's edits take the
same client path as yours), teleport arrival, rejoin into a standing city, a load that
fails halfway.
