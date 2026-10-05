# Traffic fixes: how to apply them in Studio

Everything under `src/` is a **full script**. The folder path is the script's place in the
Studio Explorer. Paste each file over the script with the same name (or create it). Nothing else
in the place changes.

- `Foo.luau` is a **ModuleScript** named `Foo`.
- `Foo.server.luau` is a **Script** named `Foo`.
- `Foo.client.luau` is a **LocalScript** named `Foo`.
- `Foo/spec.luau` is a **ModuleScript** named `spec`, parented under the `Foo` ModuleScript
  (the project's TestEZ layout).

## 1. Files to paste

Changed scripts (paste over the existing one):

| Studio path | What changed |
|---|---|
| `ServerScriptService/Services/NPC/NPCDriverService` | Car following, braking, roundabouts, junction asks, lot and bus behaviour, detours (details below) |
| `ServerScriptService/Services/City/Simulation/CitizenService` | Parking-lot deadlock, joining traffic, mode-choice inputs, school runs, parking fees, mode share |
| `ServerScriptService/Services/City/Simulation/CitizenJourneys` | School run, trip route style, parking fee collection |
| `ServerScriptService/Services/City/Simulation/CitizenTypes` | Two school-run fields |
| `ServerScriptService/Services/City/Simulation/TravelModeChoice` | Weather, dark, shopping bags, parking price, school-run choice |
| `ServerScriptService/Services/City/Simulation/ThroughTrafficService` | Restores that cannot get stuck, visitor routing, cars enter moving |
| `ServerScriptService/Services/City/ParkingService` | `priceAt`: street parking priced by how full it is |
| `ServerScriptService/Services/City/Economy/SupplyService` | Freight routing profile, shop delivery hours |
| `ServerScriptService/Services/Transit/BusDispatchService` | A bus whose leg is no longer drivable replans instead of blocking |
| `ServerScriptService/Bootstrap/Bootstrap` (Script) | Wires the new `RoadSceneryService` (4 lines, see section 2) |
| `ReplicatedStorage/Road/RoadNavigationGraph` | Cached connector geometry, dead-end U-turn cost |
| `ReplicatedStorage/Road/NavRouter` | Prices a street's scenery and homes for the profiles that care |
| `ReplicatedStorage/Road/NavCost` | Comment only (heuristic floor still holds) |
| `ReplicatedStorage/Road/DriverProfile` | Trip groups: commuter, leisure, freight, visitor |
| `ReplicatedStorage/Networker` | One new remote: `ReportBenchFrameStats` (benchmark only) |

New scripts (create them):

| Studio path | Type |
|---|---|
| `ServerScriptService/Services/Road/RoadSceneryService` | ModuleScript |
| `ServerScriptService/Services/Debug/TrafficBenchmark` | ModuleScript (dev tool, not wired in Bootstrap) |
| `StarterPlayer/StarterPlayerScripts/Debug/TrafficBenchClient` | LocalScript |

Updated specs (paste over the existing `spec` ModuleScripts):

- `ServerScriptService/Services/City/Simulation/TravelModeChoice/spec`: 5 new cases.
- `ServerScriptService/Services/City/Simulation/CitizenService/spec`: one contract flipped on
  purpose (see "Behaviour changes").
- `ServerScriptService/Services/City/Economy/SupplyService/spec`: stubs `DriverProfile` in its module map.

## 2. Bootstrap

The shipped `Bootstrap.server.luau` already has these lines. If your Bootstrap has changed since
the copy I worked from, add them by hand instead of pasting the whole file:

```lua
-- after: local RoadService = require(roadFolder:WaitForChild("RoadService"))
local RoadSceneryService   = require(roadFolder:WaitForChild("RoadSceneryService"))
-- after: NPCDriverService.Init(RoadService)
RoadSceneryService.Init(RoadService, BuildingService, CoverageService)
-- after: NPCDriverService.Bind()
RoadSceneryService.Bind()
-- after: NPCDriverService.Start()
RoadSceneryService.Start()
```

## 3. Check it

1. Run the TestEZ specs. In my headless runner they matched or beat the originals:
   NPCDriverService 73/75 (original 72/75), CitizenService 91/94 (original 91/94),
   ThroughTrafficService 4/4, TravelModeChoice 18/18, SupplyService 31/31,
   RoadNavigationGraph 29/29, CitizenJourneys 4/4. The failures left are the same in the original
   and come from my runner, not Studio. They need vehicle templates, or the spec harness predates
   `Cars.activeNpcs`.
2. Play a city and watch a roundabout, a busy signalised junction and a shop car park.
3. Run the benchmark (section 5).

## 4. What changed, by the problems you listed

**Intersections and road rules**
- Cars follow at a time gap and brake early and smoothly (Gipps model). Stopped cars move off
  after a short reaction, so a queue clears as a wave. A lane discharges about 1,900–2,300 cars
  an hour of green, which is real-world saturation flow. The old cars launched at 7 m/s² and
  stopped dead at the line.
- Roundabout entries accept a gap by time-to-arrival of ring traffic. A car whose exit is full
  laps the ring instead of stopping across it. Lab throughput: single-lane roundabout +35%,
  two-lane +105%, no collisions.
- A car can now change lanes behind a moving leader on a fast road. Before, the following gap
  blocked the move, the car stalled at the end of its lane and a queue grew behind it.
- Yellow uses firm braking distance. Junction permission is asked from braking distance, not
  at the last moment.
- Fixes for each collision pattern the lab logged in junction boxes:
  - A car accepts a gap only if it can really cross in it, from its current speed.
  - A permissive left turn at lights checks how soon the oncoming car arrives, not only a
    fixed distance.
  - A straight car never drives into an oncoming turner already in the box.
  - A car going on through the yellow brakes for a turner still clearing the box.
  - A car standing anywhere on our path in the box holds our green.
  - A car that left our lane ahead of us stays in front of us until its tail is clear.
- A main road gives way to a side-road car that has waited about 6 s, as before, but only when
  it can stop comfortably. It no longer slams on the brakes.

**Parking lots and getting out of buildings (the mutual wait)**
- A car turning in off the road goes first. A car pulling out waits for it, then takes a gap and
  joins at its exact seat. Before, the turning car waited in the lane for the pull-out, which
  waited for a gap in that same lane, and the street froze. Lab: cars pocketed (vanished) went
  from about 10 per run to about 1.

**Jams that build too easily**
- No more lot deadlocks or ring blockages. No lane-end stalls, and no two mergers locked
  around each other. Gridlock detours must actually be better than waiting.
- Measured lane capacity is about 2,200 cars/h. The old rigid train ran about 2,900, which is
  not physically possible. Door-to-door trips in the dense lab grids take 17–31% longer because
  cars now accelerate, brake and leave gaps like cars. Collisions in the heavy grid went from 40
  to 10. See section 6.

**Route choice, and no pointless U-turns**
- U-turning in a dead end costs 45 s in the router. A gridlock detour may not loop back through
  the same junction and may not cost much more than waiting.
- Trips are priced by group, not by per-car randomness (which you had ruled out):
  - **commuters**: time first;
  - **leisure** (shopping, evenings out): mind fuel more and prefer green or waterside streets;
  - **freight** (all trucks): big roads, few turns, off housing streets;
  - **visitors** (through traffic): main roads.
- `RoadSceneryService` scores every street from the city. Trees and bushes along it and water
  beside it count for it. Pollution, noise and factory frontage count against it, and it records
  the share of homes. It re-scans when roads, trees, buildings or pollution change.

**Too many people walk (now depends on the city)**
- Rain and snow make walking and waiting worse, and so does the dark. Shoppers carry bags.
  No strolls in the rain.
- Street parking has a price that rises as bays fill: free below 65% full, up to 6 at 95%.
  The city collects it when a car parks. A packed downtown pushes people onto buses; a suburb
  with spare kerb stays free.
- The school run: a parent at home drives the kids when the walk or bus is worse (far school,
  rain). Siblings for the same school ride together, and the kids walk home. Driven share:
  about 8% at 100 m, 33% at 200 m, 71% at 400 m, 92% at 750 m. Rain adds 10–20 points.
- Bus fares were already in the choice, and still are.
- `CitizenService.GetTravelModeShare()` returns the walk / drive / transit / school-run shares.

**Buses**
- A bus at a kerb stop holds in its lane, without leaving and re-entering traffic. A bus whose
  leg the roads no longer carry replans from where it stands (or waits) instead of asking the
  lane for a gap forever. Buses accelerate like buses, so stops served per hour went down
  about 30% in the lab.
- Junction checks give buses and long trucks room for their swept path in turns. Before, a
  turning bus clipped cars turning in from the cross street.

**Through traffic not loading**
- A restored car that could never find the 3 s empty-lane gap stayed hidden but counted as
  live, so no new traffic spawned. Now it waits for the gap for 8 s at most, then joins as soon
  as its own seat is free. After 45 s it is dropped.
- A wide entrance admitted one car per step. Its staggered spawn points snapped to the same
  polyline vertex, so every extra car was refused. Spawns now use the exact point, the spawn
  step is 1 s instead of 2, and cars enter moving (20 studs/s), not from a standstill. Lab: a
  map-wide highway carried about 430 through cars after 5 minutes instead of about 200.

**Commercial / industrial**
- Audit: production depends on workers and power. Shop orders follow customer demand. Imports
  happen only where local plants cannot supply, and exports only from surplus. Both need a road
  to the map edge, so the flows already depend on the city. The volume is the one you raised on
  2026-10-02, so I left it alone.
- Shops are restocked from 05:00 to 19:00 (a morning delivery round), not at 3 am. Outside trade
  runs around the clock. Trucks route as freight.

## 5. Benchmark: the real car limit

Press Play, then in the **server** command bar:

```lua
require(game.ServerScriptService.Services.Debug.TrafficBenchmark).Run()
```

It adds test cars around your character in steps (100, 250, 500 … 4000). Each step settles for
8 s, then it samples for 12 s. It prints a table of server frame time and each device's FPS, then
the largest car count that held:

- 55+ FPS on this machine (high-end);
- 30+ FPS on a low-end device. To measure this, publish, join the same server from a phone, and
  run the line from the F9 console (Server). Otherwise it prints an estimate of a third of this
  machine.

The test cars are removed at the end. The result JSON is in `ServerStorage.TrafficBenchmarkResult`.
Set `CitySimConstants.NPC_MAX_ACTIVE` from the printed high-end number.

Headless estimate of the server-side AI cost: about 30 µs per car per frame on the full-rate AI
(about 12 ms a frame for 400 on-screen cars). Distant cars run at the low-rate LOD, so the real
limit is usually rendering and replication on the client. The benchmark measures that.

## 6. Lab regression (headless, 3 seeds each)

Same scenarios, original scripts vs these, averaged over seeds 1–3, 300 simulated seconds each
(`tools/traffic-lab/regress_multi.sh`). Throughput counts cars that finished inside the window,
so slower, more realistic trips also lower it a little.

| Scenario | Throughput (cars/h) orig → new | Mean trip (s) orig → new | Collisions orig → new | Cars pocketed (vanished) orig → new |
|---|---|---|---|---|
| Single-lane roundabout, 4 arms | 848 → 1144 | 85 → 69 | 0 → 0 | – |
| Two-lane roundabout | 672 → 1380 | 120 → 87 | 0 → 0 | – |
| 5×5 grid, moderate demand | 5400 → 4908 | 42 → 55 | 2 → 0 | – |
| 5×5 grid, heavy demand | 7648 → 6368 | 59 → 69 | 40 → 10 | – |
| Street with two car parks, separate in/out | 1468 → 1396 | 88 → 79 | 1 → 0 | 31 → 4 |
| Street with two car parks, one shared throat | 1388 → 1056 | 96 → 97 | 2 → 0 | 19 → 1 |

Other lab checks:
- **Lane capacity:** about 2,200 cars/h per lane with moving entry. Queue discharge at a signal
  is 1,950–2,300 cars per hour of green.
- **Through traffic** on a map-wide highway: about 430 live cars at 300 s, up from about 200
  (target 600). After a save and reload, every restored car is driving or dropped within 45 s.
- **Route groups:** commuters take the shorter street, leisure the tree-lined one, freight and
  visitors avoid the housing street (`scen/scenery.luau` PASS).
- **Buses:** 1 bus-vs-car touch in four 400 s runs, where the original had several per run.
  About 30% fewer stops served per hour, because buses now accelerate like buses.

The grids are slower door to door because cars accelerate, brake and leave gaps like real cars,
and wait for gaps they can actually make. Most of the original's grid speed came from cars that
overlapped in the box: 40 collisions in the heavy grid against 10 now.

## 6b. Known limits

- Buses and long trucks plan their turns with a 6-stud wider path than cars, because the body
  sweeps outside the centre line. A bus's tail can still brush a car that starts its turn just
  as the bus finishes (about once in four lab runs).
- A side road joining a busy main road without lights queues, as it would in life. The main road
  lets a car in after it has waited about 6 s, but only when it can stop comfortably. The fix is
  the player's: lights, a roundabout, or another route.

## 7. Behaviour changes to know about

- **Lot aisle standoff:** an arrival off the road now goes before a departure. The CitizenService
  spec case was renamed and flipped to match.
- **Delivery hours:** shops receive trucks from 05:00 to 19:00 (Lighting.ClockTime). This
  applies only while the city clock runs (`CityDay` set), so the specs are unaffected.
- **Parking fees** credit the treasury through `CityEconomyService.credit`.
- **New car attributes:**
  - `RouteStyle` (commuter / leisure / freight / visitor) on cars and trucks;
  - `NPCEntrySpeed` on through cars.
- **Local count:** NPCDriverService is at about 195 top-level locals (the limit is 200). Put new
  state into the existing tables (`Tuning`, `Gridlock`, `RingRules`), not new locals.

## 8. Testing it yourself (optional)

`tools/traffic-lab/` is the headless runner I used. It loads your real modules on a fake engine
under [lune](https://github.com/lune-org/lune). See its README.

## 9. Reviewing the changes

Each script was first committed unmodified, then changed in later commits. One commit labelled
as a baseline (`77e9b13`) also carries the first routing changes. To see one file's whole
change, diff it against the commit that first added it:

```
f=src/ServerScriptService/Services/NPC/NPCDriverService.luau
git diff $(git log --diff-filter=A --format=%h -- "$f" | tail -1) HEAD -- "$f"
```
