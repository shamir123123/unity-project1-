--!strict
local GameSpeed = require(game:GetService("ReplicatedStorage").GameSpeed)
-- CitizenService
-- The household life-sim. Citizens are not random NPCs: households arrive from
-- outside connections when there is housing + demand, move into homes (residents),
-- adults take jobs in commercial/industrial buildings, and commute by car to work
-- in the morning and home in the evening (real trips on the nav graph, capped +
-- proximity-culled). Families have children -- gated by healthcare coverage --
-- and leave the city if the adults stay jobless. Real occupancy drives building
-- fill (residents/jobs), which the stats + economy read.

local CollectionService   = game:GetService("CollectionService")
local RunService          = game:GetService("RunService")
local Workspace           = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local PathFollower = require(ServerScriptService.Services.Util.PathFollower)
local VehicleFactory = require(ServerScriptService.Services.NPC.VehicleFactory)
local NameGen = require(ServerScriptService.Services.City.NameGen)
local Const = require(ServerScriptService.Services.City.CitySimConstants)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local DriverProfile = require(ReplicatedStorage.Road.DriverProfile)
local NavCost = require(ReplicatedStorage.Road.NavCost)
local RoadRules = require(ReplicatedStorage.Road.RoadRules)
local TravelModeChoice = require(ServerScriptService.Services.City.Simulation.TravelModeChoice)
-- Half-size world: speeds and world-distance radii scale with the city.
local WS = RoadConstants.WORLD_SCALE

local CitizenTypes = require(script.Parent.CitizenTypes)
local HouseholdNeeds = require(script.Parent.HouseholdNeeds)
local CitizenActivityState = require(script.Parent.CitizenActivityState)
local CitizenSaveColumns = require(script.Parent.CitizenSaveColumns)
local CitizenJourneys = require(script.Parent.CitizenJourneys)
local CitizenQueries = require(script.Parent.CitizenQueries)
local CitizenService = {}

-- == Tuning ====================================================================
local FAMILY_MAX = Const.FAMILY_MAX -- people in ONE household; the BUILDING's ceiling is
                                    -- BuildingService.getResidentCap (households x this)
local function isResZone(z: any): boolean return z == "Residential" end
local JOB_CAP  = Const.JOB_CAP -- shared with PowerService, which bills these slots

local SIM_STEP          = 2.0   -- game-seconds between sim passes (GameSpeed-scaled)
local TRIP_TICK         = 1 / 20 -- local driveway/parking motion; clients see smoothed cars
local ARRIVE_BASE_CHANCE = 0.35 -- per-step arrival chance at zero R demand
local ARRIVE_MIN_CHANCE  = 0.02 -- floor: even negative demand trickles hopeful families in
local STARTER_HOUSEHOLDS = 4    -- seed real families so a loaded city is not visually empty
local HEALTH_RADIUS     = 220 * WS -- studs a clinic/hospital covers for births
local BIRTH_CHANCE      = 0.18  -- per eligible household per day (needs healthcare)
local MAX_KIDS          = 3
-- Every NPC carries an integer age in years. City days advance age (AGE_PER_DAY years
-- per day); a child promotes to a working adult at AGE_ADULT.
local AGE_ADULT          = 18
local AGE_PER_DAY        = 1
local PARENT_MIN_AGE     = 24   -- arriving couples are adults of child-rearing age
local PARENT_MAX_AGE     = 52
local KID_ARRIVE_MIN_AGE = 1
local KID_ARRIVE_MAX_AGE = 16
local SCHOOL_AGE_MIN     = 5    -- youngest child that walks to school
local SCHOOL_AGE_MAX     = 17   -- oldest child that attends (18 promotes to a working adult)
local SCHOOL_START_HOUR  = 8.0
local SCHOOL_END_HOUR    = 15.0
local MOTHER_FERTILE_MAX = 45   -- births only while the mother is under this age
local FAMILY_INFO_MIN_DT = 0.15 -- rate-limit (s) for the family-info panel request
local LEAVE_JOBLESS_DAYS = 5    -- adults jobless this long -> household leaves
local MAX_TRIP_CARS     = Const.NPC_MAX_ACTIVE  -- the one NPC budget, shared with walkers and other vehicles (Cars.activeNpcs);
                                -- past it -- or past the AI's frame budget -- a trip far from every
                                -- player drives unseen (driveTo)
local RESERVED_ARRIVAL_TRIPS = 6 -- of MAX_TRIP_CARS, only arrivals may claim: commuters
                                 -- can never fully starve the move-in drive-ins (they
                                 -- used to hold every slot in a busy city, so arrival
                                 -- cars never spawned). Arrival bursts are naturally
                                 -- small (MAX_ARRIVALS_PER_STEP), so commutes keep the rest.
local CAR_SPEED         = 24 * WS
local CAR_HEIGHT        = 0.6
local ROADSIDE_RADIUS   = 700 * WS -- how far a driver looks around the destination for a free bay
                                   -- (~175 m, a 2-3 minute walk); nearest first, car parks beyond
local ERRAND_COOLDOWN   = 15   -- real seconds between a household's errands (apply / shop)
local PRESENCE_RADIUS    = 1400 -- outer bound for people IN FRONT of the camera (the cap binds first)
local PRESENCE_CAP       = 140  -- max standing people returned per presence query (perf cap)
local PRESENCE_FRONT_COS = 0.17 -- only people within ~80 deg of the camera's look (in front) are rendered
local DRIVE_RETRY_DELAY  = 2.0  -- routing/cap failures wait in place instead of teleporting
local MAX_DRIVE_RETRY_DELAY = 30 -- disconnected trips wait with bounded routing work


-- == Dependencies / state ======================================================
local _roadService: any
local _buildingService: any
local _cityStatsService: any
local _timeService: any
local _parkingService: any
local _walkingService: any
local _economyService: any
local _supplyService: any
local _educationService: any
local _folder: Folder
local _heartbeat: RBXScriptConnection?
local _running = false
local _restoring = false
local _rng = Random.new()
local _accum = 0

-- Every citizen is a Person (name + gender "M"/"F" + age in years) with a stable person
-- id `pid` used to locate them in the UI. Adults additionally run their OWN activity
-- FSM: each working adult commutes to their own workplace (one drives the family car,
-- the rest walk), so two adults in one home can be at two different buildings. Kids age
-- up each day and promote to an Adult at AGE_ADULT.
type Person = CitizenTypes.Person
type Adult = CitizenTypes.Adult
type Kid = CitizenTypes.Kid
type Household = CitizenTypes.Household

local _households: { [number]: Household } = {}
local _nextHouseholdId = 0
local _nextPersonId = 0
local _workers: { [string]: number } = {}    -- bpId -> citizen workers assigned (filled jobs)
local _driverJobs: { [string]: number } = {} -- industrial bpId -> delivery-truck drivers currently out
local _population = 0
local _travelDebugByPid: { [number]: { [string]: any } } = {}
local _lastDayProcessed = 0
local _reconciledIds: { [string]: boolean } = {}
-- Simulation level-of-detail: scheduler cursor, pid index and the education histogram.
-- Packed into ONE table on purpose -- this module sits at Luau's 200-local-register limit
-- for its main chunk (`Pipe` below is packed for exactly the same reason), so new
-- module-level state has to be fields rather than locals.
--
-- Activity batches run in one yielding worker, independently of movement and census.
-- Each batch resumes a household-id cursor with a small wall-clock budget. The snapshot
-- holds ids, not tables, so a household removed mid-sweep just resolves to nil and is
-- skipped, and one created mid-sweep joins the next sweep -- no insertion or removal site
-- has to know this exists.
-- A slow sweep only makes people LATE now, never absent: trips are due from the state of
-- a person's day (Trips.status), not from a short window at its start that a sweep could
-- step over. debugSnapshot reports elapsed game seconds; warn after one game hour.
local LOD: any = {
	CONFIG = table.freeze({ INTERVAL = TRIP_TICK, FRAME_BUDGET = 0.002, MAX_SWEEP_SIM_SECONDS = SIM_STEP * 30 }),
	activityAt = {},
	sweepStartedAt = nil,
	lastSweepGameSeconds = 0,
	EDU_EVERY    = 4,     -- sim steps between school-demand recomputes

	step = 0,             -- sim steps since boot
	order = {},           -- snapshot of household ids for the sweep in progress
	cursor = 1,           -- resume point into `order`
	sweepSteps = 0,       -- activity batches spent on the sweep in progress
	lastSweepSteps = 0,   -- batches the last complete sweep took

	-- pid -> { h, person, kind }, so the roster "locate" poll is O(1) instead of a full
	-- household scan. Rebuilt at most once per sim step, and only when a lookup misses or a
	-- known mutation (birth / promotion / removal / restore) bumps `pidGen`.
	pidMap = {},
	pidGen = 0,
	pidBuiltGen = -1,
	pidBuiltStep = -1,

	-- Adult education histogram, refreshed by the fused workforce pass. CityEconomyService
	-- polls it at 1Hz and used to trigger a second full households-x-adults scan of its own.
	eduCounts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
	eduTotal = 0,
	eduFresh = false,
}

-- _trips is now ONLY the short off-graph lot pull-out / pull-in line-follows. The
-- on-road leg between two lots is driven by NPCDriverService.DriveDirected (real
-- lane / stop-line / yield / no-overlap AI). onDone fires at the last waypoint.
type Trip = PathFollower.FollowerState & {
	path: { Vector3 }, cum: { number }, dist: number, speed: number,
	onDone: (() -> ())?,
	-- Held until there is a safe gap to enter or cross the road.
	gate: (() -> boolean)?, leavesRoad: boolean?, gateDist: number?, order: number?, blockedTime: number?,
	-- Where (and onto which lane) this car joins or crosses the road at its gate: past
	-- Cars.GAP_PATIENCE there it asks the traffic for a gap (NPCDriverService.RequestRoadGap).
	gapAt: Vector3?, gapLane: string?, gateWait: number?,
}
local _trips: { [Model]: Trip } = {}
-- Every driveTo call owns one generation. Late arrival/abort callbacks from an older
-- generation cannot move a car after a newer trip has claimed it.
local _carDriveTokens: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _tripCount = 0       -- cars in an off-graph line-follow leg
local _directedCount = 0   -- cars on the NPCDriverService road leg
local _carCount = 0    -- total citizen cars (driving + parked)
-- One car per household; parked cars are anchored and cheap. The old cap of 90 silently
-- made every household past ~90 carless (newCar() returned nil), which read as "arrival
-- cars never spawn" once the city grew. ponytail: flat cap; despawn far parked cars if
-- model count ever becomes a perf problem.
local MAX_CARS_TOTAL = Const.TRAFFIC_SAFETY_MAX_CARS

local _transitService: any -- public transit; injected in Bootstrap after TransitService exists
-- How an adult travels (walk / transit / own car) is TravelModeChoice's call; this file
-- only gathers the facts of the trip. A transit rider leaves the car at home, so every
-- trip a bus line wins is a car that never enters traffic.

-- == Helpers ===================================================================
-- 0 = paused, otherwise the sim/car-movement multiplier.
local function gameSpeed(): number
	return GameSpeed.get()
end

local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Citizens")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Citizens"; f.Parent = city
	end
	return f :: Folder
end

local function buildCar(): Model
	return VehicleFactory.build("CitizenCar", _rng:NextInteger(1, 99))
end

local _outsideConnService: any = nil
-- Staffed service buildings (a solar farm's `jobs`) live in EmergencyService, not in the
-- plot-derived building records. This state hangs off the module table instead of module
-- locals on purpose: the outer scope here is at Luau's 200-local ceiling.
CitizenService._svcKerb = {}

-- Every building view the sim reasons about: BuildingService's plot records plus any
-- staffed service building. Service views carry zone "Service", so the residential and
-- store filters skip them untouched -- only the job tests look at `jobs`.
function CitizenService._svcViews(): { any }
	local views = _buildingService.listBuildings()
	local svc = CitizenService._svc
	if svc and svc.getWorkplaceViews then
		local ok, extra = pcall(svc.getWorkplaceViews)
		if ok and type(extra) == "table" then
			table.clear(CitizenService._svcKerb)
			for _, v in extra do
				table.insert(views, v)
				if typeof(v.kerb) == "Vector3" then CitizenService._svcKerb[v.bpId] = v.kerb end
			end
		end
	end
	return views
end

-- Injected after boot (OutsideConnectionService is created later). Lets arrivals spawn at
-- REAL outside connections (roads dragged to the map edge) instead of any dead-end.
function CitizenService.SetOutsideConnService(svc: any)
	_outsideConnService = svc
end

-- Service buildings (a solar farm, a hospital) that employ staff. Injected in Bootstrap
-- after EmergencyService exists, the same way TransitService is.
function CitizenService.SetEmergencyService(svc: any)
	CitizenService._svc = svc
end

local function roadTip(g: any): Vector3?
	for _, edge in g:GetEdges() do
		if #edge.out == 0 and edge.points and #edge.points > 0 then
			return edge.points[#edge.points]
		end
	end
	return g:RandomPoint()
end

-- How far BEYOND the road network a household spawns -- the length of the imaginary
-- off-map road it drives in on. Deliberately short: a full map-edge trek (thousands of
-- studs over empty grass) drove every arrival for ~80s, which saturated the driving-car
-- budget so every in-city commute/errand teleported instead of driving (empty roads).
local OUTSIDE_SPAWN_DIST = 160

-- An "outside connection": a real road ENTRY point on the graph plus a spawn point just
-- outside it. A newly-arriving household spawns there and drives a short imaginary road in
-- to the entry, then follows real roads to its home -- visibly arriving from outside the
-- city without the off-map trek.
-- Prefers a REAL outside connection (a road dragged to the map edge) picked at random so
-- arrivals spread across the city's entrances instead of all stacking on the one dead-end
-- roadTip() always returned first -- that pile-up gridlocked the cars and starved the
-- driving-car budget, so in-city commutes teleported instead of driving. A small lateral
-- jitter on the spawn keeps cars off each other's exact spot. Falls back to a dead-end
-- when no connection has been placed yet.
-- Spawn point for a new arrival: directly ON the road at a real outside connection (a
-- road dragged to the map edge), picked at random across eligible (in/both) connections.
-- No off-map staging -- the car appears on the connection road and drives straight to its
-- home. Falls back to a dead-end tip when no connection has been placed yet.
-- The ONLY way into the city: a real outside connection (a road dragged to the map edge),
-- picked at random across the eligible (in/both) ones. Returns nil when the map has no
-- connection -- then nobody moves in. There is NO dead-end fallback: this is a simulation,
-- so a household is never conjured onto a random road or into a home from thin air.
-- Rate-limited diagnostic so it's obvious in the output WHY no one is moving in.
local _lastArrivalDiag = 0
local function arrivalDiag(msg: string)
	if os.clock() - _lastArrivalDiag > 15 then
		_lastArrivalDiag = os.clock()
		warn("[CitizenService] move-in blocked: " .. msg)
	end
end

-- Entrance pipes, packed into ONE table: the main chunk sits near Luau's
-- 200-local-register limit, so no new module-scope locals.
-- Pipe rule: a car may spawn at a connection only after the previous car spawned
-- THERE has pulled CLEAR_DIST away (or despawned / stalled out). Different
-- connections admit cars independently, so several movers can enter at once
-- without ever stacking up at a single entrance.
local Pipe = {
	CLEAR_DIST = 60,        -- previous car must pull this far from its spawn point
	TIMEOUT = 30,           -- a stuck/despawned car frees its entrance after this
	REGISTER_TIMEOUT = 180, -- limbo watchdog: family moves in even if the drive dies
	MAX_ARRIVALS_PER_STEP = 4, -- full-demand move-in budget (free entrances self-limit)
	entries = {} :: { { car: Model, spawn: Vector3, at: number } },
	-- Per sim step (LOD.step): spawn points already found occupied -- nothing moves while a
	-- step runs, so one look is enough for every empty home it tries -- and the step in
	-- which every entrance was found busy (then no other home can be served either).
	blocked = {} :: { [Vector3]: boolean },
	blockedStep = -1,
	jammedStep = -1,
}
function Pipe.clearAt(pos: Vector3): boolean
	for i = #Pipe.entries, 1, -1 do
		local e = Pipe.entries[i]
		local cleared = not e.car.Parent or os.clock() - e.at > Pipe.TIMEOUT
		if not cleared then
			-- Same stale-instance trap: a car that is DRIVING reads at its spawn pose for
			-- ever, so the pipe never opened. Ask the sim whether the spawn is still occupied.
			cleared = NPCDriverService.IsPointClear(e.spawn, Pipe.CLEAR_DIST)
			if not cleared then
				local p = e.car:GetPivot().Position
				local dx, dz = p.X - e.spawn.X, p.Z - e.spawn.Z
				cleared = dx * dx + dz * dz > Pipe.CLEAR_DIST * Pipe.CLEAR_DIST
			end
		end
		if cleared then
			table.remove(Pipe.entries, i)
		else
			local dx, dz = pos.X - e.spawn.X, pos.Z - e.spawn.Z
			if dx * dx + dz * dz < Pipe.CLEAR_DIST * Pipe.CLEAR_DIST then return false end
		end
	end
	return true
end
function Pipe.add(car: Model, spawn: Vector3)
	table.insert(Pipe.entries, { car = car, spawn = spawn, at = os.clock() })
end

-- True if any vehicle (household car, through-car, truck, bus) is still sitting
-- within SPAWN_CLEAR_RADIUS of pos. Physical query, so cars owned by other services
-- (ThroughTrafficService) count too. Arrivals defer (retry next pass) rather than
-- spawn on top of a car that has not yet pulled away from the entrance.
local SPAWN_CLEAR_RADIUS = 16
local function spawnBlocked(pos: Vector3): boolean
	local city = Workspace:FindFirstChild("_City")
	if not city then return false end
	local include = {}
	for _, name in { "Citizens", "Trucks", "Buses" } do
		local f = city:FindFirstChild(name)
		if f then table.insert(include, f) end
	end
	if #include == 0 then return false end
	-- A DRIVING car's instance is frozen at its spawn pose (NPCDriverService.IsPointClear),
	-- so ask the sim about those and let the overlap query speak only for PARKED vehicles.
	-- Reading the world alone is what left every entrance "jammed with stalled cars".
	if not NPCDriverService.IsPointClear(pos, SPAWN_CLEAR_RADIUS) then return true end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	for _, part in Workspace:GetPartBoundsInRadius(pos, SPAWN_CLEAR_RADIUS, params) do
		local m = part:FindFirstAncestorOfClass("Model")
		if m and not NPCDriverService.IsDirected(m) then return true end
	end
	return false
end

-- ponytail: a car with nowhere legal to park does not stand in the road -- it goes in
-- the household's pocket (out of Workspace: no client renders it, no traffic or spawn
-- query hits it) and comes back at the kerb when someone actually drives. Packed as one
-- table so the main chunk gains a single local (see Pipe -- near Luau's 200-register cap).
local Garage = { folder = nil :: Folder? }
-- Every adult may own a car (TravelModeChoice.ownsCar); the per-car helpers hang off this
-- table further down. One table, not locals, for the same register-limit reason as Garage.
local Cars: any = {
	-- Everything on the full AI against Const.NPC_MAX_ACTIVE: this city's lot legs, every vehicle on
	-- the road AI (max() covers the driver count's sweep lag) and every walker body.
	activeNpcs = function(): number
		return _tripCount + math.max(_directedCount, NPCDriverService.ActiveCarCount())
			+ (if _walkingService and _walkingService.bodyCount then _walkingService.bodyCount() else 0)
	end,
	roadTokens = setmetatable({}, {__mode = "k"}) :: {[Model]: number},
	ROAD_GATE_SETBACK = 16,
	LOT_STANDOFF_SECONDS = 4,
	MANEUVER_STALL_SECONDS = 20,
	-- Held at its gate by road traffic is waiting, not wedged: it has asked for a gap and the
	-- queue makes one. Only a far longer hold there gives the maneuver up.
	GATE_STALL_SECONDS = 120,
	GAP_PATIENCE = 2,   -- s at the gate before asking the road to make room
	-- The one pocketed car per lane currently asking traffic for a gap to rejoin (see driveTo),
	-- and when it last asked: one that stopped asking (trip cancelled) is replaced.
	laneAsker = {} :: { [string]: { car: Model, at: number } },
	LOT_STANDOFF_CLEARANCE = 0.05,
	ACCESS_CLEAR_RADIUS = 12,
	GAP_SECONDS = 3,    -- s of clear road a driver wants before pulling out or turning in
}
function Cars.releaseRoadSlot(car: Model, token: number?): ()
	local owner = Cars.roadTokens[car]
	if not owner or (token and owner ~= token) then return end
	Cars.roadTokens[car] = nil
	_directedCount = math.max(0, _directedCount - 1)
end

-- Walkers use the sidewalk service's existing proximity/cap LOD; car sharing must
-- not hide students or people whose chosen mode is walking.
function Cars.walk(pid: number, from: Vector3, to: Vector3, stale: () -> boolean, done: () -> (),
	label: string, look: any): number?
	return _walkingService.spawnCommuter(from, to, function()
		if not stale() then done() end
	end, label, look)
end
function Garage.stow(car: Model?)
	if not car then return end
	local f = Garage.folder
	if not f then
		f = Instance.new("Folder")
		f.Name = "PocketedCars"
		f.Parent = game:GetService("ServerStorage")
		Garage.folder = f
	end
	PathFollower.forget(car)
	car.Parent = f
end
function Garage.fetch(car: Model?)
	if car and Garage.folder and car.Parent == Garage.folder then car.Parent = _folder end
end
function Garage.clear()
	if Garage.folder then Garage.folder:ClearAllChildren() end
end
-- A mid-rise block's underground garage (BuildingService.getParkSpots.garage). Every flat
-- owns a bay behind the door, so there is nothing to claim: the car drives the baked
-- route (kerb cut -> lot edge -> door), is stowed there like any pocketed car -- out of
-- Workspace, so a full block costs nothing to render or simulate -- and comes back AT
-- the door, facing out, to drive the route in reverse on its next trip. A ParkChoice.
function Garage.home(homeId: string): any
	local spots = _buildingService.getParkSpots(homeId)
	local route = spots and spots.garageRoute
	if not route or not spots.garage then return nil end
	return { cf = spots.garage, approach = route, egress = { route[2], route[1] },
		lotEntry = spots.lotEntry, pocket = true, garage = true }
end

local function newCar(): Model?
	if _carCount >= MAX_CARS_TOTAL then return nil end
	local car = buildCar()
	Garage.stow(car)
	_carCount += 1
	return car
end

local function destroyCar(car: Model?)
	if not car then return end
	_carDriveTokens[car] = (_carDriveTokens[car] or 0) + 1
	if _trips[car] then _trips[car] = nil; _tripCount -= 1 end
	NPCDriverService.ReleaseDirected(car)
	Cars.releaseRoadSlot(car)
	PathFollower.forget(car)
	if car.Parent then car:Destroy() end
	_carDriveTokens[car] = nil
	_carCount -= 1
end

-- A short off-graph line-follow: the in-lot pull-OUT / pull-IN legs (stall <-> lot
-- mouth). Follows the waypoints then fires onDone. The on-road leg BETWEEN two lots
-- is NOT this -- it goes through NPCDriverService.DriveDirected for the real traffic
-- AI (correct lane, stop lines, signals, yielding, no overlap).
-- `lift` overrides the ride height for this leg. A leg that hands the car to the road AI
-- passes the car's own NPCHeightOffset -- the height the AI will hold it at -- so the car does
-- not drop on hand-off; legs that end at a parking stall keep CAR_HEIGHT.
-- leavesRoad: the leg starts on the road and ends off it (pulling into a bay or a lot).
local function lineFollow(car: Model, waypoints: { Vector3 }, speed: number, onDone: (() -> ())?, lift: number?, gate: (() -> boolean)?, leavesRoad: boolean?, gateDist: number?)
	if #waypoints < 2 then if onDone then onDone() end return end
	local cum = PathFollower.cumOf(waypoints)
	if (cum[#cum] or 0) < 0.5 then if onDone then onDone() end return end
	if _trips[car] == nil then _tripCount += 1 end
	Cars.movementOrder = (Cars.movementOrder or 0) + 1
	_trips[car] = {
		order = Cars.movementOrder,
		model = car, heightOffset = lift or CAR_HEIGHT, smoothCFrame = nil, lastSentCFrame = nil, replicateAccum = 0,
		path = waypoints, cum = cum, dist = 0, speed = speed, onDone = onDone, gate = gate,
		leavesRoad = leavesRoad, gateDist = gateDist or 0,
	}
	if gate and not leavesRoad then
		-- Still in its bay or lot, waiting to pull out: not on the road, so the road does not
		-- queue behind it. (Registered, a car waiting in a kerb bay stopped the lane beside it,
		-- and then could not pull out into the cars it had stopped.)
		PathFollower.forget(car)
	else
		PathFollower.seedProximity(car, 0)
		-- A road arrival may wait at its gate before stepTrips can place it.
		-- Keep its body registered throughout the movement-owner handoff.
		local pose = car:GetPivot()
		PathFollower.place(_trips[car], waypoints[1], pose.LookVector, 0)
	end
end
-- (Kept beside the trip legs: the contract specs load this stretch of the file on its own.)
Cars.JOIN_RETRY = 0.25  -- s between tries of a car at the end of its pull-out to join the traffic
Cars.JOIN_TRIES = 60    -- ...before it gives up and is put away (only a real overlap keeps refusing it)
-- A lot leg standing at its gate, waiting to pull out: still off the road, and yielding.
function Cars.waitingToPullOut(trip: any): boolean
	return trip.leavesRoad == false and trip.gate ~= nil and trip.dist >= (trip.gateDist or 0) - 1e-3
end
-- A car turning in off the road has the driveway first, as the rules of the road give it: one
-- pulling out waits for it. The turning car used to wait instead -- in the lane, for the car
-- pulling out, which was waiting for a gap in that same lane -- and both stood there for good
-- while the street queued behind them (lab, 2026-10-05: one car park froze a whole avenue).
function Cars.turnInNear(pos: Vector3, car: Model): boolean
	local r2 = Cars.ACCESS_CLEAR_RADIUS * Cars.ACCESS_CLEAR_RADIUS
	for other, trip in _trips do
		if other ~= car and trip.leavesRoad == true then
			local cf = trip.smoothCFrame
			local p = if cf then cf.Position else other:GetPivot().Position
			local dx, dz = p.X - pos.X, p.Z - pos.Z
			if dx * dx + dz * dz <= r2 then return true end
		end
	end
	return false
end


-- Drive an existing car from its current spot to parkCF along the road graph; it
-- PARKS at parkCF on arrival (not destroyed) and is reused next trip. Unavailable
-- routes and occupied roads leave the trip waiting at its current position.
-- routeFrom (optional) is the position used to PATHFIND onto the graph; the car still
-- starts physically at its own pivot. For an outside-connection arrival this is the real
-- road entry, so the prepended pivot->entry leg becomes the imaginary off-map road.
-- isArrival trips use a lower cap so they can't consume the slots reserved for in-city trips.
-- opts let a trip drive the WHOLE way into / out of a lot, not just to the kerb:
--   fromGraphPoint : where the car re-enters the road graph (the lot it's leaving
--                    hands off here); defaults to the car's current position
--   egress         : in-lot waypoints from the car to fromGraphPoint (pull-out)
--   toGraphPoint   : where the car leaves the road graph (the destination lot mouth);
--                    defaults to parkCF
--   approach       : in-lot waypoints from toGraphPoint to the stall (drive-in)
type DriveOpts = {
	onDepart: (() -> ())?,
	pocket: boolean?,
	isArrival: boolean?,
	onRoad: boolean?,
	fromGraphPoint: Vector3?,
	toGraphPoint: Vector3?,
	exitGraphPoint: Vector3?,
	egress: { Vector3 }?,
	approach: { Vector3 }?,
	isValid: (() -> boolean)?,
	attempts: number?,
	startLane: {edgeId: string, dist: number}?,
	restorePending: boolean?,
	-- Coming back from a save onto the exact lane seat it was saved on: a saved queue did not
	-- overlap, so the car only needs its own seat free, not an empty road around it.
	exactSeat: boolean?,
}
function Cars.pinLane(g: any, pos: Vector3, heading: Vector3): {edgeId: string, dist: number}?
	if not g.NearestEdge or not g.GetEdgesForSegment then return nil end
	local nearest = g:NearestEdge(pos)
	if not nearest then return nil end
	local best, score = nil, math.huge
	for _, edge in g:GetEdgesForSegment(nearest.edge.segmentId) do
		local cum = PathFollower.getCum(edge)
		for i=1,#edge.points-1 do
			local a, delta = edge.points[i], edge.points[i+1]-edge.points[i]
			local length = delta.Magnitude
			if length<1e-6 then continue end
			local t=math.clamp((pos-a):Dot(delta)/(length*length),0,1)
			local cost=(pos-a-delta*t).Magnitude-0.01*heading:Dot(delta/length)
			if cost<score then score=cost;best={edgeId=edge.id,dist=cum[i]+length*t} end
		end
	end
	return best
end
local function driveTo(car: Model, parkCF: CFrame, onArrive: (() -> ())?, opts: DriveOpts?)
	local o = opts or {}
	local startLane = o.startLane or (if o.onRoad then NPCDriverService.GetLaneAnchor(car) else nil)
	local token = (_carDriveTokens[car] or 0) + 1
	_carDriveTokens[car] = token
	car:SetAttribute("DriveRetryPending", nil)

	-- Enforce a single movement owner even if two asynchronous state changes collide.
	if _trips[car] then
		_trips[car] = nil
		_tripCount = math.max(0, _tripCount - 1)
		PathFollower.forget(car)
	end
	NPCDriverService.ReleaseDirected(car)
	NPCDriverService.ClearRoadGap(car)
	Cars.releaseRoadSlot(car)

	local function active(): boolean
		if not car.Parent or _carDriveTokens[car] ~= token then return false end
		return o.isValid == nil or o.isValid() == true
	end

	-- Failed routes back off while keeping the trip at its actual position.
	local function retry(alreadyOnRoad: boolean, countAttempt: boolean?, quick: boolean?)
		car:SetAttribute("DriveRetryPending", true)
		local retryLane = startLane
		if alreadyOnRoad then
			local graph = nav()
			local cf = car:GetPivot()
			retryLane = NPCDriverService.GetLaneAnchor(car) or (if graph then Cars.pinLane(graph,cf.Position,cf.LookVector) else nil) or startLane
			car:SetAttribute("RestorePending",true)
			if retryLane then
				car:SetAttribute("RestoreEdge",retryLane.edgeId)
				car:SetAttribute("RestoreDist",retryLane.dist)
			end
			Garage.stow(car)
		end
		local delay = if quick then DRIVE_RETRY_DELAY * 0.5
			elseif countAttempt == false then DRIVE_RETRY_DELAY
			else math.min(MAX_DRIVE_RETRY_DELAY, DRIVE_RETRY_DELAY * (1 + (o.attempts or 0)))
		task.delay(delay, function()
			if not active() then return end
			local retryOpts: DriveOpts = table.clone(o)
			retryOpts.attempts = if countAttempt == false then o.attempts
				else math.min((o.attempts or 0) + 1, MAX_DRIVE_RETRY_DELAY / DRIVE_RETRY_DELAY)
			if alreadyOnRoad then
				retryOpts.onRoad = true
				retryOpts.restorePending = true
				retryOpts.startLane = retryLane
				retryOpts.fromGraphPoint = nil
				retryOpts.egress = nil
			end
			driveTo(car, parkCF, onArrive, retryOpts)
		end)
	end

	local g = nav()
	-- Pocketed cars have no driveway. Admit them directly to a safe lane seat,
	-- while still hidden, rather than inventing a pull-out through the junction.
	if Garage.folder and car.Parent == Garage.folder and not (o.egress and #o.egress > 0) then
		o.onRoad = true
		o.restorePending = true
		startLane = startLane or (if g then Cars.pinLane(g, car:GetPivot().Position, car:GetPivot().LookVector) else nil)
		if startLane then
			local seat, distance = NPCDriverService.GetRestoreSeat(car, startLane)
			if seat and distance then
				car:PivotTo(seat)
				startLane = {edgeId=startLane.edgeId,dist=distance}
			else retry(true); return end
		else retry(true); return end
	end
	local height = tonumber(car:GetAttribute("NPCHeightOffset")) or CAR_HEIGHT
	local from = car:GetPivot().Position - Vector3.new(0, height, 0)
	local graphStart = o.fromGraphPoint or from
	local graphEnd = o.toGraphPoint or parkCF.Position
	local cap = if o.isArrival then MAX_TRIP_CARS else (MAX_TRIP_CARS - RESERVED_ARRIVAL_TRIPS)
	local parkPos = parkCF.Position - Vector3.new(0, CAR_HEIGHT, 0)
	local function depart()
		local callback = o.onDepart
		o.onDepart = nil
		if callback then callback() end
	end
	local function parkAndArrive()
		if not active() then return end
		depart()
		car:SetAttribute("DriveRetryPending", nil)
		car:PivotTo(parkCF)
		if onArrive then onArrive() end
	end
	if not g or not g:HasEdges() then
		retry(o.onRoad == true)
		return
	end

	-- Every trip drives for real, on the traffic AI, near a player or not -- that is what
	-- builds the rush hour. When the road has no room for another car (the trip cap), this
	-- one waits at its door and tries again; it never drives hidden or appears at the far
	-- end. Checked before routing so a waiting car costs no pathfinding.
	if Cars.activeNpcs() >= cap then
		retry(o.onRoad == true, false)
		return
	end

	-- A trip may pull out of (or turn into) a driveway across the centre line, as US law
	-- allows over dashed and double-yellow lines alike (never a median -- NavRouter): both
	-- lot legs below hold at the kerb for a gap in traffic first. Route with THIS car's own
	-- mind, not a shared optimum: two neighbours driving to the same place get different
	-- roads, and each prices the traffic others have committed to by how much it cares.
	local profile = DriverProfile.fromModel(car)
	if o.onRoad and not startLane then startLane=Cars.pinLane(g,from,car:GetPivot().LookVector) end
	-- A pocketed car rejoins its own lane only into a gap. Checked BEFORE routing: ~1,200
	-- cars waiting on jammed lanes each ran a whole-city A* per retry, every 2 s -- most of the
	-- server's frame (measured 2026-10-03, 18 server fps). A busy street never offers a natural
	-- 3 s gap, so ONE waiting car per lane asks traffic to make one (RequestRoadGap) and pops in;
	-- the rest wait their turn (measured live: 138 commuters of one parking-less block queued at
	-- one kerb spot, ~2 a minute getting out; every one asking stopped the lane for nothing).
	local restoreLane = if startLane then startLane.edgeId else nil
	if o.restorePending and not o.exactSeat and not NPCDriverService.RoadGapClear(from, Cars.GAP_SECONDS, car, nil, restoreLane) then
		local asker = if restoreLane then Cars.laneAsker[restoreLane] else nil
		if restoreLane and (asker == nil or asker.car == car or os.clock() - asker.at > DRIVE_RETRY_DELAY * 2) then
			Cars.laneAsker[restoreLane] = { car = car, at = os.clock() }
			NPCDriverService.RequestRoadGap(car, from, restoreLane)
			retry(true, false, true)
		else
			retry(true, false)
		end
		return
	end
	local ok, road, edgeIds = pcall(function() return g:FindPath(graphStart, graphEnd, true, nil, profile, startLane) end)
	if not ok or not road or #road == 0 then
		retry(o.onRoad == true)
		return
	end

	if typeof(edgeIds) ~= "table" or #(edgeIds :: any) == 0 then
		-- No lane-edge route (very short / off-graph): plain line-follow the whole way.
		local path: { Vector3 } = { from }
		if o.egress then for _, p in o.egress do table.insert(path, p) end end
		for _, p in road do table.insert(path, p) end
		if o.approach then for _, p in o.approach do table.insert(path, p) end end
		table.insert(path, parkPos)
		lineFollow(car, path, CAR_SPEED, parkAndArrive)
		return
	end

	local edgeRoute = edgeIds :: { string }
	local roadGoal = if o.approach and #o.approach > 0 and not o.pocket
		then NPCDriverService.LaneExitPoint(edgeRoute[#edgeRoute],graphEnd,car) else graphEnd
	-- Where the off-graph pull-OUT ends and the road AI begins: the lot mouth we're
	-- leaving, or (no lot) the first road waypoint so the car drives out to the lane.
	local roadHandoff = o.fromGraphPoint or from
	-- Finish the pull-out ON the lane instead of letting the road leg reseat the car there:
	-- these points are the seat the road leg would have snapped to, then a short lead along
	-- the lane, so the car drives that last bit itself and arrives already facing down it.
	local laneEntry = NPCDriverService.LaneEntryPath(edgeRoute[1], roadHandoff, nil, car)
	local roadStart = if o.onRoad then from elseif laneEntry then laneEntry[#laneEntry] else roadHandoff

	-- Leg C: turn in from where the car stopped on the lane (across the oncoming lanes when
	-- the route ended on the far side), over the lot mouth, to the stall.
	local function startApproach()
		if not active() then return end
		if o.pocket then parkAndArrive(); return end
		local stoppedAt = car:GetPivot().Position - Vector3.new(0, CAR_HEIGHT, 0)
		local appPts: { Vector3 } = { stoppedAt, graphEnd }
		if o.approach then for _, p in o.approach do table.insert(appPts, p) end end
		table.insert(appPts, parkPos)
		local edge = g:GetEdge(edgeRoute[#edgeRoute])
		local curbEntry = edge ~= nil and edge.laneOrdinal == edge.laneCountInDirection
			and car:GetPivot().RightVector:Dot(graphEnd - stoppedAt) * RoadRules.getLaneSideSign() > 0
		local gate: (() -> boolean)? = function()
			if not curbEntry and not NPCDriverService.RoadGapClear(stoppedAt,Cars.GAP_SECONDS,car,true) then return false end
			if o.exitGraphPoint and flatDist(o.exitGraphPoint,graphEnd) > 1 then return true end
			-- Only a car actually driving out through the mouth holds us; one waiting at its gate
			-- gives way to us (Cars.turnInNear).
			return not PathFollower.anyVehicleWithin(graphEnd,Cars.ACCESS_CLEAR_RADIUS,function(other: Model): boolean
				local trip = _trips[other]
				return other ~= car and trip ~= nil and trip.leavesRoad == false and not Cars.waitingToPullOut(trip)
			end)
		end
		lineFollow(car, appPts, CAR_SPEED, parkAndArrive, nil, gate, true)
		local trip = _trips[car]
		if trip then
			trip.onBlocked = function() retry(true) end
			if not curbEntry then trip.gapAt = stoppedAt end
		end
	end

	-- Leg B: drive the ROAD on NPCDriverService's real traffic AI.
	local function startRoad()
		if not active() then return end
		if o.restorePending then
			if not o.exactSeat and not NPCDriverService.RoadGapClear(roadStart, Cars.GAP_SECONDS, car, nil, restoreLane) then
				retry(true, false)
				return
			end
			local asker = if restoreLane then Cars.laneAsker[restoreLane] else nil
			if asker and asker.car == car then Cars.laneAsker[restoreLane :: string] = nil end
			NPCDriverService.ClearRoadGap(car)
			Garage.fetch(car)
			o.restorePending = false
			car:SetAttribute("RestorePending", nil)
		end
		Cars.roadTokens[car] = token
		_directedCount += 1
		-- Straight off its own pull-out leg the car is already on the lane, seen by the traffic.
		local joining = (not o.onRoad and not o.restorePending) or o.exactSeat == true
		local started = NPCDriverService.DriveDirected(car, roadStart, roadGoal, edgeRoute,
			function()
				Cars.releaseRoadSlot(car, token)
				if active() then startApproach() end
			end,
			function()
				Cars.releaseRoadSlot(car, token)
				if active() then
					retry(true)
				end
			end, if startLane then startLane.dist else nil, joining)
		if started then
			NPCDriverService.ClearRoadGap(car)
			depart()
			return
		end
		Cars.releaseRoadSlot(car, token)
		if not active() then return end
		-- Only an actual overlap refuses a joining car: it waits where it stands, still seen by
		-- the traffic, and tries again -- it is not hidden out of the world to reappear later.
		o.joinTries = (o.joinTries or 0) + 1
		if joining and not o.exactSeat and o.joinTries <= Cars.JOIN_TRIES then
			task.delay(Cars.JOIN_RETRY, startRoad)
			return
		end
		-- A saved seat that is taken after all: back to the ordinary way in (gap, then the lane).
		o.exactSeat = nil
		retry(true)
	end

	if o.onRoad then startRoad() return end

	-- Leg A: pull OUT from the current stall across the lot to the road handoff.
	local egressPts: { Vector3 } = { from }
	if o.egress then for _, p in o.egress do table.insert(egressPts, p) end end
	table.insert(egressPts, roadHandoff)
	local handoffIndex = #egressPts
	if laneEntry then for _, p in laneEntry do table.insert(egressPts, p) end end
	lineFollow(car, egressPts, CAR_SPEED, startRoad, tonumber(car:GetAttribute("NPCHeightOffset")),
		function()
			return not Cars.turnInNear(roadHandoff, car)
				and NPCDriverService.RoadGapClear(roadHandoff, Cars.GAP_SECONDS, car, false, edgeRoute[1])
		end, false,
		math.max(0, PathFollower.cumOf(egressPts)[handoffIndex] - (if o.egress and #o.egress > 0 then 0 else Cars.ROAD_GATE_SETBACK)))
	local trip = _trips[car]
	if trip then
		trip.onBlocked = function() retry(true) end
		trip.gapAt, trip.gapLane = roadHandoff, edgeRoute[1]
	end
end

local function canPassLotManeuver(model: Model, other: Model): boolean
	local mine, trip = _trips[model], _trips[other]
	if not mine or not trip then return false end
	local _, mineDir = PathFollower.pointAtDist(mine.path, mine.cum, mine.dist)
	local _, otherDir = PathFollower.pointAtDist(trip.path, trip.cum, trip.dist)
	-- A queue is not a standoff: never pass a car travelling down the same aisle.
	if mineDir:Dot(otherDir) > 0.3 then return false end
	if trip.gate and trip.dist >= (trip.gateDist or 0)-1e-3 then
		return mine.leavesRoad ~= trip.leavesRoad
	end
	-- The car coming in off the road goes first (Cars.turnInNear): it is the one holding up the street.
	if mine.leavesRoad ~= trip.leavesRoad then return mine.leavesRoad == true end
	return (mine.order or 0) < (trip.order or 0)
end

local function stepTrips(dt: number)
	-- onDone callbacks may re-add the car to _trips (the next leg) or hand it to
	-- NPCDriverService, so defer them until after the iteration -- never mutate
	-- _trips while iterating it.
	local done: { () -> () } = {}
	for car, t in _trips do
		if not car.Parent then _trips[car] = nil; _tripCount -= 1; PathFollower.forget(car); continue end
		local atGate = t.gate ~= nil and t.dist >= (t.gateDist or 0) - 1e-3
		if t.onBlocked then
			if t.dist > (t.progressDist or 0) + 0.25 then
				t.progressDist, t.stallTime = t.dist, 0
			else
				t.stallTime = (t.stallTime or 0) + dt
			end
			if t.stallTime >= (if atGate then Cars.GATE_STALL_SECONDS else Cars.MANEUVER_STALL_SECONDS) then
				_trips[car] = nil
				_tripCount -= 1
				NPCDriverService.ClearRoadGap(car)
				Garage.stow(car)
				table.insert(done, t.onBlocked)
				continue
			end
		end
		if atGate and t.gate then
			if not t.gate() then
				t.gateWait = (t.gateWait or 0) + dt
				if t.gapAt and (t.gateWait or 0) >= Cars.GAP_PATIENCE then
					NPCDriverService.RequestRoadGap(car, t.gapAt, t.gapLane)
				end
				continue
			end
			-- A car turning in is off the road from here; one pulling out keeps its gap until it
			-- has joined the traffic (startRoad clears it), or the request lapses on its own.
			if t.gapAt and t.leavesRoad then NPCDriverService.ClearRoadGap(car) end
			if not t.leavesRoad then
				local here = if t.smoothCFrame then t.smoothCFrame.Position else car:GetPivot().Position
				local ahead = PathFollower.pointAtDist(t.path, t.cum, math.min(t.cum[#t.cum], t.dist + 4))
				local toward = ahead + Vector3.new(0, t.heightOffset, 0) - here
				if toward.Magnitude > 0.5 and PathFollower.getSpeedFactor(car, here, toward.Unit) <= 0 then continue end
			end
			t.gate = nil
			if not t.leavesRoad then PathFollower.seedProximity(car, 0) end
		end
		local total = t.cum[#t.cum]
		-- Look where the path GOES, not where the car faces: a car stopped in the lane to turn
		-- into its lot faces down the lane, and looking that way it waited for ever on the queue
		-- ahead -- a queue it never had to pass -- while the lane behind waited on it
		-- (2026-09-30: 31 cars frozen on lane centrelines this way).
		local here = if t.smoothCFrame then t.smoothCFrame.Position else car:GetPivot().Position
		local ahead = PathFollower.pointAtDist(t.path, t.cum, math.min(total, t.dist + 4))
		local toward = ahead + Vector3.new(0, t.heightOffset, 0) - here
		local dir = if toward.Magnitude > 0.5 then toward.Unit elseif t.smoothCFrame then t.smoothCFrame.LookVector else Vector3.zAxis
		local factor, clearance, _, blocker = PathFollower.getMotionLimits(car, here, dir)
		-- Two lot maneuvers can meet on the same narrow aisle. One yields; only the
		-- winner creeps past it. Road drivers and third vehicles still block normally.
		local other = if blocker then _trips[blocker] else nil
		if clearance <= Cars.LOT_STANDOFF_CLEARANCE and other
			and (not other.gate or other.dist < (other.gateDist or 0)-1e-3)
			and (not t.gate or t.dist < (t.gateDist or 0)-1e-3) then
			local otherHere = if other.smoothCFrame then other.smoothCFrame.Position else other.model:GetPivot().Position
			local otherAhead = PathFollower.pointAtDist(other.path, other.cum, math.min(other.cum[#other.cum], other.dist + 4))
			local otherToward = otherAhead + Vector3.new(0, other.heightOffset, 0) - otherHere
			if otherToward.Magnitude > 0.5 and dir:Dot(otherToward.Unit) < 0.3 then
				local otherFactor, _, _, otherBlocker = PathFollower.getMotionLimits(other.model, otherHere, otherToward.Unit)
				local hasPriority = if t.leavesRoad ~= other.leavesRoad then t.leavesRoad == true
					else (t.order or 0) < (other.order or 0)
				if otherFactor < 0.01 and otherBlocker == car and hasPriority then
					factor, clearance = PathFollower.getMotionLimits(car, here, dir, blocker)
					factor = math.min(factor, 0.25)
				end
			end
		end
		if clearance <= Cars.LOT_STANDOFF_CLEARANCE and blocker and not other
			and (not t.gate or t.dist < (t.gateDist or 0)-1e-3)
			and NPCDriverService.IsWaitingForVehicle(blocker, car) then
			t.blockedTime = (t.blockedTime or 0) + dt
			if t.blockedTime >= Cars.LOT_STANDOFF_SECONDS then
				factor, clearance = PathFollower.getMotionLimits(car, here, dir, blocker)
				factor = math.min(factor, 0.25)
			end
		elseif clearance <= Cars.LOT_STANDOFF_CLEARANCE and other and (not t.gate or t.dist < (t.gateDist or 0)-1e-3) then
			t.blockedTime = (t.blockedTime or 0) + dt
			if t.blockedTime >= Cars.LOT_STANDOFF_SECONDS then
				factor, clearance = PathFollower.getMotionLimits(car,here,dir,nil,canPassLotManeuver)
				factor = math.min(factor,0.25)
			end
		else
			t.blockedTime = 0
		end
		t.dist = math.min(total, t.dist + math.min(t.speed * dt * factor, clearance))
		if t.gate then t.dist = math.min(t.dist, t.gateDist or 0) end
		local pos, pdir = PathFollower.pointAtDist(t.path, t.cum, t.dist)
		PathFollower.place(t, pos, pdir, dt)
		if t.dist >= total - 1e-3 then
			_trips[car] = nil; _tripCount -= 1
			-- Parked in its bay or lot now: no longer anything the road must stop for.
			if t.leavesRoad then PathFollower.forget(car) end
			if t.onDone then table.insert(done, t.onDone) end
		end
	end
	for _, cb in done do cb() end
end

-- == Building views ============================================================
local function levelClamp(lvl: number): number
	return math.clamp(lvl or 1, 1, 3)
end

local function jobCapacity(zone: string, level: number): number
	local t = JOB_CAP[zone]
	return if t then t[levelClamp(level)] else 0
end

-- A workplace's slot count: a service building states its own (spec.jobs), a zoned one
-- reads the shared JOB_CAP table by zone and level.
function CitizenService._svcCapacity(b: any): number
	local j = tonumber(b.jobs)
	if j then return math.max(0, math.floor(j)) end
	return jobCapacity(b.zone, b.level)
end

local function isResidentialHomeView(b: any?): boolean
	return typeof(b) == "table" and isResZone(b.zone) and b.abandoned ~= true
end

local function isJobView(b: any?): boolean
	return typeof(b) == "table"
		and (b.zone == "Commercial" or b.zone == "Industrial" or (tonumber(b.jobs) or 0) > 0)
		and b.abandoned ~= true
end

local function homeFocusPosition(homeId: string): Vector3?
	local p = _buildingService.getKerb(homeId)
	if typeof(p) == "Vector3" then return p end
	if _buildingService.getDoor then
		p = _buildingService.getDoor(homeId)
		if typeof(p) == "Vector3" then return p end
	end
	if _buildingService.getBuildingPosition then
		p = _buildingService.getBuildingPosition(homeId)
		if typeof(p) == "Vector3" then return p end
	end
	return nil
end

-- Recompute building fill from real occupancy (residents / workers).
local function syncFill(b: any)
	if isResZone(b.zone) then
		local cap = _buildingService.getResidentCap(b.bpId)
		_buildingService.setOccupancy(b.bpId, b.residents, cap, "residents", b.level)
	elseif b.zone == "Commercial" or b.zone == "Industrial" then
		local cap = jobCapacity(b.zone, b.level)
		-- Citizens plus any delivery drivers currently out from this industrial building
		-- (each active truck occupies one job slot), capped at the building's capacity.
		local filled = (_workers[b.bpId] or 0) + (_driverJobs[b.bpId] or 0)
		_buildingService.setOccupancy(b.bpId, math.min(filled, cap), cap, "jobs", b.level)
	end
end

-- == Population accounting =====================================================
local function recountPopulation()
	local n = 0
	for _, h in _households do
		n += #h.adults + #h.kids -- movers on their way in count too (see tryArrival)
	end
	_population = n
end

function CitizenService.getPopulation(): number
	return _population
end

-- Debug-only live snapshot of the citizen sim (graph readiness, stage histogram,
-- employment, car/trip counts) for diagnosing why agents do or don't move.
-- Debug only: the off-road leg a car is on (nil when it is not on one), for live probes.
function CitizenService.DebugTrip(car: Model): any
	return _trips[car]
end

function CitizenService.getVehicleTripDebug(car: Model): { [string]: any }?
	local t = _trips[car]
	if not t then return nil end
	local here = if t.smoothCFrame then t.smoothCFrame.Position else car:GetPivot().Position
	local ahead = PathFollower.pointAtDist(t.path, t.cum, math.min(t.cum[#t.cum],t.dist+4))
	local toward = ahead + Vector3.new(0,t.heightOffset,0) - here
	local factor, clearance, _, blocker = PathFollower.getMotionLimits(car,here,if toward.Magnitude>.5 then toward.Unit else car:GetPivot().LookVector)
	return {kind="driveway or parking leg",name=car.Name,polyline=table.clone(t.path),
		position=here,heading=if t.smoothCFrame then t.smoothCFrame.LookVector else car:GetPivot().LookVector,
		distance=t.dist,total=t.cum[#t.cum],gateDist=t.gateDist,waitingForRoadGap=t.gate~=nil,
		leavesRoad=t.leavesRoad,speedFactor=factor,clearance=clearance,
		blockedBy=if blocker then blocker:GetAttribute("NpcId") else nil,
		blockerName=if blocker then blocker.Name else nil,
		blockerCitizenPid=if blocker then blocker:GetAttribute("CitizenPid") else nil,
		blockerIsLotTrip=blocker~=nil and _trips[blocker]~=nil}
end

function CitizenService.debugSnapshot(): { [string]: any }
	local stages: { [string]: number } = {}
	local withCar, employed, hh = 0, 0, 0
	for _, h in _households do
		hh += 1
		for _, a in h.adults do
			if a.car then withCar += 1 end
			stages[a.stage] = (stages[a.stage] or 0) + 1
			if a.walkerId then stages._walking = (stages._walking or 0) + 1 end
			if a.jobId then employed += 1 end
		end
	end
	local g = nav()
	return {
		households = hh, stages = stages, withCar = withCar, employed = employed,
		cars = _carCount, driving = _tripCount + _directedCount,
		-- A game hour is Const.DAY_SECONDS / 24. Keep activity latency below it.
		sweepSteps = LOD.lastSweepSteps, sweepPending = math.max(0, #LOD.order - LOD.cursor + 1),
		sweepGameSeconds = LOD.lastSweepGameSeconds,
		navEdges = (g ~= nil and g:HasEdges()) or false,
		sidewalkBuilt = (_walkingService ~= nil and _walkingService.isBuilt ~= nil and _walkingService.isBuilt()) or false,
	}
end

function CitizenService.getStats(): { [string]: number }
	local hh, adults, kids, employed = 0, 0, 0, 0
	local groups = {children=0,teens=0,adults=0,seniors=0}
	for _, h in _households do
		if h.arriving then continue end
		hh += 1; kids += #h.kids
		for _, k in h.kids do local group=TravelModeChoice.ageGroup(k.age);groups[group]+=1 end
		for _, a in h.adults do
			local group=TravelModeChoice.ageGroup(a.age);groups[group]+=1
			adults += 1
			if a.jobId then employed += 1 end
		end
	end
	return { children=groups.children,teens=groups.teens,workingAge=groups.adults,seniors=groups.seniors, households = hh, adults = adults, kids = kids, employed = employed, population = _population, cars = _carCount, driving = _tripCount + _directedCount }
end

-- A delivery truck launching from industrial building `bpId` puts its driver on the
-- clock: claim one of the building's job slots while the truck is out. SupplyService
-- (the fleet owner) calls these; CitizenService stays the sole authority on occupancy.
function CitizenService.reserveDriverJob(bpId: string)
	if typeof(bpId) ~= "string" then return end
	_driverJobs[bpId] = (_driverJobs[bpId] or 0) + 1
end

function CitizenService.releaseDriverJob(bpId: string)
	if typeof(bpId) ~= "string" then return end
	local n = (_driverJobs[bpId] or 0) - 1
	_driverJobs[bpId] = if n > 0 then n else nil
end

-- Healthcare coverage for births, against a clinic list the caller snapshots ONCE. This
-- used to run CollectionService:GetTagged plus a pcall'd GetPivot PER HOUSEHOLD inside a
-- single dailyTick frame -- O(households x clinics) pivot reads in one step. Clinic
-- positions only move when one is built or demolished, so dailyTick gathers them once and
-- every household tests the snapshot.
local function hasHealthcare(clinics: { Vector3 }, pos: Vector3): boolean
	for _, p in clinics do
		if (p - pos).Magnitude <= HEALTH_RADIUS then return true end
	end
	return false
end

-- == Household lifecycle =======================================================
-- Occupied building-lot stalls, keyed bpId.."#"..stallIndex. Without this, stalls were
-- assigned by household-id hash alone and two cars could park inside each other.
local _stallTaken: { [string]: boolean } = {}

-- Free the parking an adult's car currently occupies -- the on-street spot and/or the
-- building-lot stall (no-op if it's parked in a driveway or is driving). Called on
-- every departure and on removal.
local function releaseSpot(a: Adult)
	local departure = a.departureParking
	if departure then
		a.departureParking = nil
		releaseSpot(departure :: any)
	end
	if a.parkSpotId then
		_parkingService.release(a.parkSpotId)
		a.parkSpotId = nil
	end
	if a.parkStallKey then
		_stallTaken[a.parkStallKey] = nil
		a.parkStallKey = nil
	end
end

-- The driveway is ONE space. The first household on the plot claims it for as long as it
-- lives there -- not per trip, so it is never released by releaseSpot -- and every other
-- household in the building street-parks or uses a car park instead of stacking cars on the
-- same slab. Claims share _stallTaken with the building-lot stalls (one namespace, one
-- clear); "#drive" cannot collide with the numeric stall keys.
local function claimDriveway(homeId: string): (CFrame?, string?)
	local spots = _buildingService.getParkSpots(homeId)
	local cf = if spots then spots.home else nil
	if not cf then return nil, nil end
	local key = homeId .. "#drive"
	if _stallTaken[key] then return nil, nil end
	_stallTaken[key] = true
	return cf, key
end

local function releaseDriveway(a: Adult)
	if not a.driveKey then return end
	_stallTaken[a.driveKey] = nil
	a.driveKey = nil
	a.homeParkCF = nil
end


-- Give the car up entirely: its parking, the driveway it held, the model.
function Cars.drop(a: Adult)
	releaseSpot(a)
	releaseDriveway(a)
	destroyCar(a.car)
	a.car = nil
	a.usingCar = false
end

-- Resolve a pid to its household. A cached entry is trusted only while its household is
-- still the live one under that id. `rebuild` is nested rather than a sibling local so it
-- costs a register in THIS frame instead of the main chunk's (see LOD).
local function findPerson(pid: number): { h: any, person: any, kind: string }?
	local function rebuild()
		table.clear(LOD.pidMap)
		for _, h in _households do
			for _, a in h.adults do LOD.pidMap[a.pid] = { h = h, person = a, kind = "adult" } end
			for _, k in h.kids do LOD.pidMap[k.pid] = { h = h, person = k, kind = "kid" } end
		end
		LOD.pidBuiltGen = LOD.pidGen
	end
	if LOD.pidBuiltGen ~= LOD.pidGen then rebuild() end
	local e = LOD.pidMap[pid]
	if e and _households[e.h.id] == e.h then return e end
	-- Miss: the pid may belong to a citizen created by a path that does not bump the
	-- generation (arrival / restore). Rebuild at most once per sim step, so a UI polling a
	-- dead pid cannot spin a full scan on every request.
	if LOD.pidBuiltStep ~= LOD.step then
		LOD.pidBuiltStep = LOD.step
		rebuild()
		e = LOD.pidMap[pid]
		if e and _households[e.h.id] == e.h then return e end
	end
	return nil
end

local function removeHousehold(id: number, byId: { [string]: any })
	local h = _households[id]
	if not h then return end
	LOD.pidGen += 1
	-- Invalidate every adult's in-flight commute callback and pull its pedestrian, so a
	-- removed household leaves no orphan walker and no late async fire touches freed state.
	for _, a in h.adults do
		_travelDebugByPid[a.pid] = nil
		a.tripId += 1
		if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
		if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
		if a.jobId then
			_workers[a.jobId] = math.max(0, (_workers[a.jobId] or 1) - 1)
			a.jobId = nil
		end
	end
	for _, kid in h.kids do
		kid.tripId += 1
		if kid.riderId then _transitService.cancelRider(kid.riderId); kid.riderId=nil; kid.waitPos=nil end
		if kid.walkerId then _walkingService.despawnCommuter(kid.walkerId); kid.walkerId = nil end
		if kid.stage == "atSchool" and _educationService and _educationService.leaveSchool then
			_educationService.leaveSchool(kid.schoolId)
		end
	end
	if byId[h.homeId] then
		for _ = 1, #h.adults + #h.kids do
			_buildingService.removeResident(h.homeId)
		end
	end
	for _, a in h.adults do Cars.drop(a) end -- the next family to move in gets the drive
	_buildingService.removeHousehold(h.homeId)
	_buildingService.setFamilyName(h.homeId, nil)
	_households[id] = nil
end

-- People factories. Every citizen has a gender and an age; adults also hold a job + jobless
-- timer. Arriving kids are already a few years old; newborns (births) start at age 0.
local function nextPid(): number
	_nextPersonId += 1
	return _nextPersonId
end

local function makeAdult(gender: string, age: number): Adult
	local pid = nextPid()
	return {
		name = NameGen.firstName(_rng, gender), gender = gender, age = age, pid = pid, eduLevel = 0,
		jobId = nil, joblessDays = 0,
		stage = "atHome", tripId = 0, walkerId = nil,
		outKind = nil, outDestId = nil, usingCar = false, ownsCar = TravelModeChoice.ownsCar(pid),
		tripTargetId = nil, tripTargetHome = false,
		commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
	}
end

local function makeKid(): Kid
	local gender = if _rng:NextNumber() < 0.5 then "M" else "F"
	return {
		name = NameGen.firstName(_rng, gender), gender = gender,
		age = _rng:NextInteger(KID_ARRIVE_MIN_AGE, KID_ARRIVE_MAX_AGE), pid = nextPid(), bestTier = 0,
		stage = "atHome", tripId = 0, walkerId = nil, schoolPos = nil, schoolId = nil,
		commutedSchoolDay = 0, commutedHomeDay = 0,
	}
end

-- A kid's education level on reaching adulthood: the highest school tier they enrolled in.
-- A university degree (tier 3) is no longer handed out for living near one -- high-school
-- graduates now go and study there (Trips.student) and graduate at Trips.UNI_MAX_AGE.
local function graduateEduLevel(kid: Kid, _home: Vector3?): number
	return kid.bestTier
end

-- A household can have children only with both a mother and a father present.
local function hasCouple(h: Household): boolean
	local male, female = false, false
	for _, a in h.adults do
		if a.gender == "M" then male = true elseif a.gender == "F" then female = true end
	end
	return male and female
end

local function youngestFemaleAge(h: Household): number
	local best = math.huge
	for _, a in h.adults do
		if a.gender == "F" and a.age < best then best = a.age end
	end
	return best
end

-- A point a short way INTO the city on the connection's inbound lane (the lane heading
-- toward map centre). An arrival spawns HERE rather than on the degree-1 node at the very
-- edge: that tip is shared by the inbound lane and the exit-less outbound (dead-end) lane,
-- so a car that snaps to the latter never gets a route and just sits. 24 studs in removes
-- the ambiguity -- the car is unmistakably on the lane that drives into the city.
local INBOUND_SPAWN_MIN = 24    -- first spawn point in from the edge (clear of the shared dead-end tip)
local INBOUND_SPAWN_STEP = 32   -- step further in to clear a car stalled at the entrance
local INBOUND_SPAWN_TRIES = 5   -- inbound points to consider per connection
-- Spawn points for a connection, grouped BY INBOUND LANE: every lane leaving the map-edge
-- node -- read off the nav graph, not guessed from geometry -- sampled at INBOUND_SPAWN_MIN
-- in and then every STEP further. Several points per lane let an arrival spawn PAST a car
-- stalled at the mouth; several LANES matter because junction turns are assigned per lane,
-- so the single innermost lane the old geometric pick always returned can be a dead end for
-- a given home while the kerbside lane of the same road routes to it fine.
local function inboundLanePoints(g: any, c: any): { { Vector3 } }
	local lanes: { any } = {}
	if g.GetOutgoingEdgesFromNode and typeof(c.nodeId) == "number" then
		lanes = g:GetOutgoingEdgesFromNode(c.nodeId)
	end
	if #lanes == 0 and g.NearestEdgeToward then
		-- Fallback (node id gone stale between rescans): "inbound" = away from the map edge,
		-- opposite the connection's outward normal. Robust when the road meets the edge at an
		-- angle or near a corner, where "toward map centre" picks the outbound lane.
		local normal = c.normal
		local target = if typeof(normal) == "Vector3" and normal.Magnitude > 1e-3
			then c.outer - normal * 200 else Vector3.zero
		local res = g:NearestEdgeToward(c.outer, target)
		if res and res.edge then lanes = { res.edge } end
	end
	local out: { { Vector3 } } = {}
	for _, edge in lanes do
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then continue end
		local result: { Vector3 } = {}
		local acc, nextWanted = 0, INBOUND_SPAWN_MIN
		for i = 2, #pts do
			acc += (pts[i] - pts[i - 1]).Magnitude
			while acc >= nextWanted and #result < INBOUND_SPAWN_TRIES do
				-- Coarsely sampled lanes cross two thresholds on one point; taking it twice
				-- would spend a try on a spawn that is not actually further past the stall.
				if result[#result] ~= pts[i] then result[#result + 1] = pts[i] end
				nextWanted += INBOUND_SPAWN_STEP
			end
			if #result >= INBOUND_SPAWN_TRIES then break end
		end
		if #result == 0 then result[1] = pts[#pts] end
		out[#out + 1] = result
	end
	if #out == 0 then out[1] = { c.outer } end
	return out
end

-- A spawn point no car stands on (cached per sim step once found occupied: see Pipe).
function Pipe.free(pos: Vector3): boolean
	if Pipe.blockedStep ~= LOD.step then
		table.clear(Pipe.blocked)
		Pipe.blockedStep = LOD.step
	end
	if Pipe.blocked[pos] then return false end
	if not spawnBlocked(pos) and Pipe.clearAt(pos) then return true end
	Pipe.blocked[pos] = true
	return false
end

-- Choose an arrival spawn point: scan eligible outside connections (random start so arrivals
-- spread across entrances) and return the first inbound point that is clear of other cars AND
-- whose lane can actually route to the home. Scanning all connections and walking past a
-- stalled car means a single car stuck at one entrance no longer halts all move-ins.
-- Clearance is looked at BEFORE the route is searched: it is cheap and the same for every
-- home, while the search is an A* per lane. The old order searched every inbound lane for
-- every empty home first, so while the entrances were busy each sim step paid a full sweep
-- of searches per empty home only to find nowhere to spawn -- measured as over half of the
-- server's whole frame time in a small town with through traffic.
local function pickArrivalSpawn(g: any, homeKerb: Vector3): Vector3?
	if Pipe.jammedStep == LOD.step then return nil end
	if not _outsideConnService then
		arrivalDiag("no outside connection found -- drag a road to the map edge so traffic can enter")
		return nil
	end
	local eligible = {}
	for _, c in _outsideConnService.list() do
		if c.dir ~= "out" then eligible[#eligible + 1] = c end
	end
	if #eligible == 0 then
		arrivalDiag("no outside connection found -- drag a road to the map edge so traffic can enter")
		return nil
	end
	-- Every inbound LANE of every connection, in a random connection order so consecutive
	-- arrivals spread across entrances instead of stacking on one (a stack conga-lines and
	-- wedges at the entrance junction).
	local start = _rng:NextInteger(1, #eligible)
	local lanes: { { Vector3 } } = {}
	for k = 0, #eligible - 1 do
		local c = eligible[((start - 1 + k) % #eligible) + 1]
		for _, points in inboundLanePoints(g, c) do lanes[#lanes + 1] = points end
	end
	-- Can this lane reach the home? The same search the drive will use (driveTo:
	-- allowCrossing), so a home the car can reach is never reported unreachable: it may
	-- finish on EITHER side of the home's street, which is what failed for a house whose
	-- kerb-side lane only runs away from the entrance. Plain search as fallback. Asked at
	-- most once per lane.
	local reach: { [number]: boolean } = {}
	local tested = 0
	local function routable(li: number): boolean
		local r = reach[li]
		if r ~= nil then return r end
		tested += 1
		local from = lanes[li][1]
		local pathOk, road = pcall(function() return g:FindPath(from, homeKerb, true) end)
		if not (pathOk and typeof(road) == "table" and #road > 0) then
			pathOk, road = pcall(function() return g:FindPath(from, homeKerb) end)
		end
		r = pathOk and typeof(road) == "table" and #road > 0
		reach[li] = r
		return r
	end
	-- Prefer a clear entrance point (spreads arrivals across connections).
	local anyClear = false
	for li, points in lanes do
		if Pipe.free(points[1]) then
			anyClear = true
			if routable(li) then return points[1] end
		end
	end
	-- Every entrance is occupied: walk PAST the stalled car, further in on any connection.
	for li, points in lanes do
		for i = 2, #points do
			if Pipe.free(points[i]) then
				anyClear = true
				if routable(li) then return points[i] end
				break -- the lane cannot reach this home from any point on it
			end
		end
	end
	if not anyClear then
		Pipe.jammedStep = LOD.step
		arrivalDiag("every outside connection that can reach a home is jammed with stalled cars at the entrance")
		return nil
	end
	if tested < #lanes then
		-- Only the busy lanes were left untested: no search just to word the message.
		arrivalDiag("every outside connection that can reach a home is jammed with stalled cars at the entrance")
		return nil
	end
	-- No lane reaches the home. Name the exact home, the lane the home itself sits on, and
	-- every spawn lane tried, so a broken road join is findable on the map instead of a
	-- mystery (LANES overlay marks dead-end lanes). No home lane at all means the house is
	-- not on the network.
	local detail = {}
	for _, c in eligible do
		for _, pts in inboundLanePoints(g, c) do
			table.insert(detail, ("%s spawn=(%d,%d)"):format(tostring(c.id), pts[1].X, pts[1].Z))
		end
	end
	local nearOk, homeNear = pcall(function() return g:NearestEdge(homeKerb) end)
	if not nearOk then homeNear = nil end
	arrivalDiag(("can't route from any of %d inbound lane(s) to the empty home at (%d, %d) [home lane: %s] -- check that its street joins the network (LANES overlay shows dead-end lanes red). tried: %s")
		:format(#lanes, homeKerb.X, homeKerb.Z,
			tostring(homeNear and homeNear.edge and homeNear.edge.id or "NONE"),
			table.concat(detail, ", ")))
	return nil
end

-- A move-in is PHYSICAL: the family spawns in a car at an outside connection (any
-- routable one, picked at random), drives to the home, and only counts as resident
-- when the car actually gets there. No car, no route, no parking, no clear entrance
-- -> no move-in this step; the next step simply tries again. driveTo's bounded
-- retries guarantee onArrive eventually fires, and a watchdog registers the family
-- anyway if the drive somehow dies -- so a wedged car can't strand a family in
-- limbo (reserved home, zero residents), the failure that forced the old
-- register-instantly design.
local function tryArrival(home: any): boolean
	local homeKerb = _buildingService.getKerb(home.groupId)
	if not homeKerb then return false end

	local g = nav()
	if not g or not g:HasEdges() or Cars.activeNpcs() >= MAX_TRIP_CARS then return false end
	local src = pickArrivalSpawn(g, homeKerb)
	if not src then return false end

	-- Home parking, in order: this plot's driveway if no other household already holds it,
	-- else a free on-street bay near the door, else (inside reserveNearest) a car-park stall
	-- anywhere in reach -- they park there and walk the rest of the way home.
	-- A block with a garage houses every car; only a house has the one-car driveway.
	local garage = Garage.home(home.groupId)
	local homeParkCF, driveKey = nil, nil
	if not garage then homeParkCF, driveKey = claimDriveway(home.groupId) end
	local initialPark: CFrame? = if garage then garage.cf else homeParkCF
	local parkSpotId: any = nil
	local parkAccess: any = nil
	if not initialPark then
		local spotId, cf, access = _parkingService.reserveNearest(homeKerb, ROADSIDE_RADIUS)
		if cf then initialPark = cf; parkSpotId = spotId; parkAccess = access end
	end
	-- Driveway taken, no free bay AND no car park in reach: they pull over on the road outside,
	-- get out, and the car goes back like a hire car -- the family lives here without one until
	-- a space near home frees up (Cities: Skylines II: no parking, no car). Hard-failing here
	-- blocked move-ins outright on roads with no bays.
	if not initialPark then
		initialPark = Cars.roadStop(homeKerb).cf
	end

	local car = newCar()
	if not car then
		if parkSpotId then _parkingService.release(parkSpotId) end
		if driveKey then _stallTaken[driveKey] = nil end
		arrivalDiag("citizen car cap reached -- no car free for a mover")
		return false
	end

	-- The slot is claimed here, at the commit point: everything above can still bail.
	if not _buildingService.addHousehold(home.groupId) then
		destroyCar(car)
		if parkSpotId then _parkingService.release(parkSpotId) end
		if driveKey then _stallTaken[driveKey] = nil end
		return false
	end
	_nextHouseholdId += 1
	local id = _nextHouseholdId
	local hh: Household = {
		id = id, homeId = home.groupId, adults = {}, kids = {},
		foundedDay = _timeService.getDay(), arriving = true,
		familyName = NameGen.familyName(_rng),
	}
	-- A founding couple: one adult male, one adult female, both of child-rearing age,
	-- plus 0-2 children who arrive already a few years old.
	table.insert(hh.adults, makeAdult("M", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
	table.insert(hh.adults, makeAdult("F", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
	for _ = 1, _rng:NextInteger(0, 2) do
		table.insert(hh.kids, makeKid())
	end
	-- They arrive in one car, the first car owner's. A family with no car still arrives by
	-- road (a hire car); it goes back once they are in. The other owners' cars appear at
	-- home once the family has moved in (doActivities hands them out).
	local driver = hh.adults[1]
	for _, a in hh.adults do
		if a.ownsCar then driver = a; break end
	end
	driver.car, driver.homeParkCF, driver.parkSpotId, driver.driveKey = car, homeParkCF, parkSpotId, driveKey
	_households[id] = hh
	_buildingService.setFamilyName(home.groupId, hh.familyName)

	-- They count as residents from the moment the home is claimed (user, 2026-10-02): the
	-- building shows its people and they pay tax while the car is still on its way.
	-- `arriving` still keeps them out of commutes/errands until the car gets there.
	-- removeHousehold takes the residents back off if the move-in is abandoned.
	for _ = 1, #hh.adults + #hh.kids do
		if _buildingService.canAcceptResident(home.groupId) then
			_buildingService.addResident(home.groupId)
		end
	end
	local registered = false
	local function register()
		if registered or _households[id] ~= hh then return end
		registered = true
		hh.arriving = false
	end

	car:PivotTo(CFrame.new(src + Vector3.new(0, CAR_HEIGHT, 0)))
	Garage.fetch(car)
	Pipe.add(car, src)
	driveTo(car, initialPark, function()
		if garage then
			driver.parkEgress = garage.egress
			driver.parkGraphPoint = garage.lotEntry
			Garage.stow(car)
		elseif parkAccess then
			driver.parkEgress = parkAccess.egress
			driver.parkGraphPoint = parkAccess.lotExit
		elseif not homeParkCF and not parkSpotId then
			Cars.notePocket(id)
			Cars.drop(driver)
		end
		register()
		if driver.car and not driver.ownsCar then Cars.drop(driver) end
	end, {
		isArrival = true,
		fromGraphPoint = src,
		toGraphPoint = if garage then garage.lotEntry elseif parkAccess then parkAccess.lotEntry else nil,
		exitGraphPoint = if parkAccess then parkAccess.lotExit else nil,
		approach = if garage then garage.approach elseif parkAccess then parkAccess.approach else nil,
		isValid = function() return _households[id] == hh and driver.car == car end,
	})
	task.delay(Pipe.REGISTER_TIMEOUT, register)
	return true
end

local function seedStarterHouseholds()
	if next(_households) ~= nil then return end
	local launched = 0
	for _, home in _buildingService.getEmptyHomes() do
		if launched >= STARTER_HOUSEHOLDS then break end
		if tryArrival(home) then
			launched += 1
		end
	end
end

local function door(bpId: string): Vector3?
	return _buildingService.getDoor(bpId) or _buildingService.getKerb(bpId) or CitizenService._svcKerb[bpId]
end

-- Buildings with a job opening (commercial/industrial, served, not abandoned, below
-- capacity). A workplace without power, water or a drain hires NOBODY: nothing runs in there, so the shifts it would
-- have offered do not exist. That is the whole penalty -- the staff already on the books
-- keep their jobs, so the demand PowerService bills does not collapse the moment the lights
-- go out and start the grid flapping on and off. What it costs the player is growth: the
-- locals it would have employed stay jobless, and jobless locals are what stops new
-- families moving in (CityStatsService weights unemployment against residential demand).
local function openJobs(views: { any }): { string }
	local out: { string } = {}
	for _, b in views do
		if (b.zone == "Commercial" or b.zone == "Industrial" or (tonumber(b.jobs) or 0) > 0)
			and not b.abandoned and b.powered ~= false and b.watered ~= false and b.drained ~= false then
			-- Delivery drivers out from an industrial building hold real job slots, so a
			-- citizen can only take a slot they leave free.
			local filled = (_workers[b.bpId] or 0) + (_driverJobs[b.bpId] or 0)
			if filled < CitizenService._svcCapacity(b) then
				table.insert(out, b.bpId)
			end
		end
	end
	return out
end

-- Commercial stores a household can shop at.
local function stores(views: { any }, hour: number?): { string }
	local out: { string } = {}
	for _, b in views do
		if b.zone == "Commercial" and not b.abandoned then
			local shift = (tonumber(b.bpId:match("%d+")) or 0) % 6
			local open = hour == nil or shift == 0
				or (shift == 1 and (hour >= 18 or hour < 6))
				or (shift >= 2 and hour >= 6 and hour < 22)
			if open then table.insert(out, b.bpId) end
		end
	end
	return out
end

-- A chosen parking spot plus how to drive into and out of it. For a lot stall,
-- `approach` is the in-lot path from `lotEntry` to the stall and `egress` is its
-- reverse; both are nil for a roadside / driveway spot (straight drive). `spotId`
-- is set only for a reserved roadside apron spot. `pocket` means there was no legal
-- spot at ALL: the car is stowed out of the world rather than left standing in the road.
type ParkChoice = CitizenTypes.ParkChoice

local function reverseRoute(route: { Vector3 }): { Vector3 }
	local out: { Vector3 } = {}
	for i = #route, 1, -1 do table.insert(out, route[i]) end
	return out
end

-- Where a household's car parks at a destination building: its own lot first (drives the
-- baked in-lot route), else a free on-street apron spot near it, else pocketed at the kerb.
-- The lot used to lose to any street bay nearer the door, so shop and office car parks sat
-- empty while the street outside filled.
local function pickBuildingPark(h: Household, bpId: string): ParkChoice?
	local spots = _buildingService.getParkSpots(bpId)
	local kerb = _buildingService.getKerb(bpId)
	local target = (if _buildingService.getDoor then _buildingService.getDoor(bpId) else nil) or kerb
	local best: ParkChoice? = nil
	local bestDistance = math.huge
	if spots then
		for i, stall in spots.stalls do
			local key = bpId .. "#" .. tostring(i)
			if _stallTaken[key] then continue end
			local distance = if target then (stall.cf.Position-target).Magnitude else i
			if distance < bestDistance then
				bestDistance = distance
				best = {cf=stall.cf,stallKey=key,approach=stall.route,
					egress=stall.egress or reverseRoute(stall.route),lotEntry=spots.lotEntry,lotExit=spots.lotExit}
			end
		end
	end
	if best and best.stallKey then
		_stallTaken[best.stallKey] = true
		return best
	end
	local id, cf, access
	if target then id, cf, access = _parkingService.reserveNearest(target,ROADSIDE_RADIUS) end
	if cf then
		return {cf=cf,spotId=id,approach=access and access.approach,egress=access and access.egress,
			lotEntry=access and access.lotEntry,lotExit=access and access.lotExit}
	end
	return if kerb then Cars.roadStop(kerb) else nil
end

-- Where an adult's car parks at HOME: the driveway if THIS adult holds it (one per plot),
-- else a roadside apron spot near the door, else the nearest car-park stall in reach
-- (reserveNearest's own fallback) and the driver walks home from it, else pocketed.
local function pickHomePark(h: Household, a: Adult): ParkChoice?
	local private = Garage.home(h.homeId)
	if not private and a.homeParkCF then private = {cf=a.homeParkCF} end
	local kerb = _buildingService.getKerb(h.homeId)
	local target = (if _buildingService.getDoor then _buildingService.getDoor(h.homeId) else nil) or kerb
	if not target then return private end
	local id, cf, access = _parkingService.reserveNearest(target,ROADSIDE_RADIUS)
	if cf and (not private or (cf.Position-target).Magnitude < (private.cf.Position-target).Magnitude) then
		return {cf=cf,spotId=id,approach=access and access.approach,egress=access and access.egress,
			lotEntry=access and access.lotEntry,lotExit=access and access.lotExit}
	end
	if id then _parkingService.release(id) end
	return private or (if kerb then Cars.roadStop(kerb) else nil)
end

-- A car owner without a car gets one, parked at home: a new adult, a family that just
-- moved in or was re-housed, a car lost to a despawn. `parkedAt` (a restored save) puts it
-- back in the bay it stood in when that bay still exists; `away` means it was left away from
-- home (at work), so it goes back there even if its owner holds the driveway.
function Cars.give(h: Household, a: Adult, parkedAt: CFrame?, away: boolean?)
	if not a.driveKey then a.homeParkCF, a.driveKey = claimDriveway(h.homeId) end
	local park: ParkChoice? = nil
	if parkedAt and (away or not a.homeParkCF) then
		local id, cf, access = _parkingService.reserveNearest(parkedAt.Position, 6)
		if cf and (cf.Position - parkedAt.Position).Magnitude <= 6 then
			park = { cf = cf, spotId = id, approach = access and access.approach,
				egress = access and access.egress, lotEntry = access and access.lotEntry, lotExit = access and access.lotExit }
		elseif id then
			_parkingService.release(id)
		end
		-- Lot reservations are rebuilt on load. A saved pose alone is not a legal
		-- stall: roads/lots may have changed and old saves can contain origin poses.
		if not park and away and a.outDestId then park = pickBuildingPark(h, a.outDestId) end
	end
	park = park or pickHomePark(h, a)
	-- No space near home (a garage counts; the kerb-side pocket does not): no car for now.
	-- doActivities asks again later, so a car park built nearby brings the cars back.
	if not park or (park.pocket and not park.garage) then
		Cars.notePocket(h.id)
		return
	end
	local car = newCar()
	if not car then
		if park.spotId then _parkingService.release(park.spotId) end
		if park.stallKey then _stallTaken[park.stallKey] = nil end
		return
	end
	a.car = car
	car:PivotTo(park.cf)
	a.parkSpotId = park.spotId
	a.parkStallKey = park.stallKey
	a.parkEgress = park.egress
	a.parkGraphPoint = park.lotExit or park.lotEntry
	if park.pocket then
		Garage.stow(car)
		Cars.notePocket(h.id)
	else
		Garage.fetch(car)
	end
end

-- A parked car whose bay, car park or building has been bulldozed goes in the pocket at once
-- -- it is not left standing on bare ground or in the new road -- and drives off from the
-- nearest lane on its owner's next trip (driveTo's pocketed path). A car still standing in a
-- street bay whose id was reissued by a road rebuild re-claims it by position instead.
function Cars.sweepOrphans(byId: { [string]: any })
	for _, h in _households do
		local homeGone = byId[h.homeId] == nil
		for _, a in h.adults do
			if homeGone then releaseDriveway(a) end
			local car = a.car
			if not car or car.Parent ~= _folder or _trips[car] or NPCDriverService.IsDirected(car)
				or car:GetAttribute("DriveRetryPending") then continue end
			local standing: boolean
			if a.parkSpotId then
				standing = _parkingService.exists(a.parkSpotId)
				if not standing then
					a.parkSpotId = _parkingService.claimAt(car:GetPivot().Position, 3)
					standing = a.parkSpotId ~= nil
				end
			elseif a.parkStallKey then
				local bpId = string.match(a.parkStallKey, "^(.-)#")
				standing = bpId ~= nil and byId[bpId] ~= nil
			else
				standing = not homeGone
			end
			if standing then continue end
			releaseSpot(a)
			a.parkEgress, a.parkGraphPoint = nil, nil
			Garage.stow(car)
		end
	end
end

-- A street bay that vanished (its road bulldozed or rebuilt) or that a bus stop has taken: the
-- car standing in it re-claims the bay it still stands in (a rebuild reissues ids), else drives
-- off to the nearest free one at once -- or, with none, goes in the pocket. ParkingService calls
-- this the moment its spots change (onSpotsChanged).
function Cars.reparkLost()
	for _, h in _households do
		for _, a in h.adults do
			local car = a.car
			if not car or not a.parkSpotId or car.Parent ~= _folder or _trips[car] or NPCDriverService.IsDirected(car)
				or car:GetAttribute("DriveRetryPending") or _parkingService.usable(a.parkSpotId) then continue end
			local pos = car:GetPivot().Position
			if not _parkingService.exists(a.parkSpotId) then
				local again = _parkingService.claimAt(pos, 3)
				if again then a.parkSpotId = again; continue end
			end
			releaseSpot(a)
			a.parkEgress, a.parkGraphPoint = nil, nil
			local id, cf = _parkingService.reserveNearest(pos, 240)
			if id and cf then
				a.parkSpotId = id
				driveTo(car, cf)
			else
				Garage.stow(car)
			end
		end
	end
end

-- The last resort when there is nowhere legal to leave the car: pull over on the road
-- outside, the driver gets out and the car goes in the pocket (Garage) -- it stands nowhere
-- and blocks nothing, and comes back on the road right there when they drive off. Never on
-- the pavement. Costs happiness (notePocket -> CityStatsService).
function Cars.roadStop(kerb: Vector3): ParkChoice?
	local g = nav()
	local near = g and g:NearestEdge(kerb)
	if near and near.distance < ROADSIDE_RADIUS then
		local pts = near.edge.points
		local p = pts[near.index]
		local q = pts[math.min(near.index + 1, #pts)]
		if (q - p).Magnitude < 1e-3 then q = p + near.edge.toDir end
		local stop = p + Vector3.new(0, RoadConstants.ROAD_THICKNESS * 0.5, 0)
		return { cf = CFrame.lookAt(stop, stop + Vector3.new(q.X - p.X, 0, q.Z - p.Z)), pocket = true }
	end
	return nil
end

-- Households that had nowhere to park today (dailyTick turns it into a happiness stat).
Cars.pocketedToday = {} :: { [number]: boolean }
function Cars.notePocket(householdId: number)
	Cars.pocketedToday[householdId] = true
end

-- A pocketed car comes back on the road only when that bit of road is clear, so it never
-- appears inside another car; `go` runs once it is out (or straight away if it was parked).
-- A jam over the spot holds it as long as the jam lasts, like any car waiting to pull out.
function Cars.fetchWhenClear(car: Model, go: () -> (), isValid: (() -> boolean)?)
	if not car.Parent or (isValid and not isValid()) then return end
	if not (Garage.folder and car.Parent == Garage.folder) then go(); return end
	local pos = car:GetPivot().Position
	if NPCDriverService.IsPointClear(pos, 10)
		and not PathFollower.anyVehicleWithin(pos, 10, function(other: Model): boolean return other ~= car end) then
		go()
		-- Route failure or a canceled launch must never expose an ownerless road car.
		if _trips[car] or NPCDriverService.IsOnRoad(car) then Garage.fetch(car) end
		if _trips[car] then
			local cf=car:GetPivot()
			PathFollower.place({model=car,heightOffset=0},cf.Position,cf.LookVector,0)
		end
		return
	end
	task.delay(0.5, Cars.fetchWhenClear, car, go, isValid)
end

-- A street bay or car-park stall near `pos` (a place with no lot of its own, such as a campus).
function Cars.parkNear(pos: Vector3?): ParkChoice?
	if not pos then return nil end
	local id, cf, access = _parkingService.reserveNearest(pos, ROADSIDE_RADIUS)
	if not cf then return nil end
	return { cf = cf, spotId = id, approach = access and access.approach, egress = access and access.egress,
		lotEntry = access and access.lotEntry, lotExit = access and access.lotExit }
end

-- Studs from the nearest place this adult's car could be left to `toDoor`, as they would
-- judge it before setting off; nil when there is nowhere at all. Home with a driveway or a
-- garage is at the door; a destination with a free lot stall is too.
function Cars.parkWalk(h: Household, a: Adult, destId: string?, toDoor: Vector3): (number?, number)
	local best = _parkingService.distanceToFree(toDoor,ROADSIDE_RADIUS)
	-- A street bay or a car park is metered by how full the street is (ParkingService.priceAt);
	-- the driveway, the block's garage and the destination's own lot are free.
	local ownLot = false
	local function consider(cf: CFrame?)
		if not cf then return end
		local distance=flatDist(cf.Position,toDoor)
		if not best or distance<best then best=distance end
	end
	if destId == h.homeId then
		consider(a.homeParkCF)
		local garage=Garage.home(h.homeId)
		if garage then consider(garage.cf) end
	elseif destId then
		local spots=_buildingService.getParkSpots(destId)
		if spots then
			for i,stall in spots.stalls do
				if not _stallTaken[destId.."#"..tostring(i)] then consider(stall.cf); ownLot = true end
			end
		end
	end
	-- Home with no space still counts the kerb: they drive home and give the car up there
	-- (Cars.give). Anywhere else, no space in reach means no drive (Cities: Skylines II).
	if not best and destId == h.homeId then
		local kerb = _buildingService.getKerb(destId)
		local pocket = if kerb then Cars.roadStop(kerb) else nil
		if pocket then best = flatDist(pocket.cf.Position, toDoor) end
	end
	-- pickBuildingPark takes a free stall in the destination's own lot first, and that is free.
	local metered = best ~= nil and not ownLot and destId ~= h.homeId
	return best, if metered then Cars.parkingFee(toDoor) else 0
end

-- The weather people dress for (WeatherService publishes it on workspace).
function Cars.weather(): string
	local w = workspace:GetAttribute("Weather")
	return if typeof(w) == "string" then w else "Clear"
end

-- How the city travels: the modes chosen over roughly the last game day, for the stats panel
-- and the debug readout (GetTravelModeShare). The window halves every MODE_WINDOW choices, so
-- it follows the city as it changes without keeping a log.
Cars.modeCounts = { walk = 0, drive = 0, transit = 0, schoolRun = 0 }
Cars.MODE_WINDOW = 4000
function Cars.countMode(mode: string)
	local c = Cars.modeCounts
	c[mode] = (c[mode] or 0) + 1
	if c.walk + c.drive + c.transit + c.schoolRun > Cars.MODE_WINDOW then
		for k, v in c do c[k] = v * 0.5 end
	end
end

-- Game time in days (the unit dwellUntil and the activity clock use).
function Cars.gameNow(): number
	return if _timeService then _timeService.getDay() + _timeService.getDayFraction() else 0
end

-- The school run: a parent at home with their car drives a child whose walk (or bus) to
-- school is worse than the drive (TravelModeChoice.escorts) -- a far school, rain, the dark.
-- A brother or sister for the same school climbs into a run that has not left yet. Returns
-- the driving parent (nil: the child goes alone) and whether the child joined a run already
-- set up. US children: about one in ten walks to school, half are driven (NHTS 2017).
function Cars.schoolRunBy(h: Household, k: any, fromDoor: Vector3, schoolPos: Vector3, schoolId: number): (Adult?, boolean)
	for _, a in h.adults do
		local run = a.schoolRun
		if run and run.outbound and run.schoolId == schoolId and a.stage == "transit" then
			table.insert(run.kids, k)
			return a, true
		end
	end
	local driver: Adult? = nil
	for _, a in h.adults do
		if a.stage == "atHome" and a.car ~= nil and not a.usingCar and a.dwellUntil == nil and a.age >= AGE_ADULT then
			driver = a
			break
		end
	end
	if not driver then return nil, false end
	local parkWalk = Cars.parkWalk(h, driver, nil, schoolPos)
	local estimate = if _transitService then _transitService.estimateTrip(fromDoor, schoolPos) else nil
	local trip: TravelModeChoice.Trip = {
		pid = k.pid, age = k.age, purpose = "school",
		distance = flatDist(fromDoor, schoolPos),
		canDrive = false, parkWalk = parkWalk, parkPrice = 0, -- a drop at the gate, not a stay
		transit = if estimate and estimate.usable then estimate else nil,
		weather = Cars.weather(),
		dark = _timeService ~= nil and _timeService.isDaylight ~= nil and not _timeService.isDaylight(),
	}
	if not TravelModeChoice.escorts(trip, driver.age) then return nil, false end
	driver.schoolRun = { schoolId = schoolId, kids = { k }, outbound = true }
	return driver, false
end

-- City money to leave a car near `pos` right now (0 without metering in this build).
function Cars.parkingFee(pos: Vector3): number
	local priceAt = _parkingService and _parkingService.priceAt
	if not priceAt then return 0 end
	local ok, price = pcall(priceAt, pos)
	return if ok and typeof(price) == "number" then price else 0
end

-- How much slower than free-flow the roads between two points are right now: the BPR
-- slowdown averaged over a few lanes sampled along the way. Jams make the car dearer, so
-- when the roads fill up the people a bus line serves start taking it.
function Cars.congestion(g: any, from: Vector3, to: Vector3): number
	local sum, n = 0, 0
	for i = 1, 5 do
		local near = g:NearestEdge(from:Lerp(to, (i - 0.5) / 5))
		if near and near.distance < ROADSIDE_RADIUS then
			sum += NavCost.bprFactor(g:GetEdgeCongestion(near.edge.id))
			n += 1
		end
	end
	return if n > 0 then sum / n else 1
end

-- A citizen's display label for its pedestrian model: the person's name + family name.
local function personLabel(h: Household, a: Adult): string
	return a.name .. " " .. h.familyName
end

local function kidLabel(h: Household, k: Kid): string
	return k.name .. " " .. h.familyName
end

-- == Displaced families ========================================================
-- A house coming down does not delete the people inside it. They take to the street, walk
-- vacancy to vacancy for SECS looking for a room, move in if they find one, and leave the
-- city only if they don't. Packed into ONE table for the same reason as LOD/Pipe: this
-- chunk sits at Luau's 200-local-register limit, so new state goes in fields.
local Homeless: any = {
	SECS = 90, -- real seconds of house-hunting before a family gives up on the city
}

-- Take the vacancy they walked to, if it is still free when they get there.
function Homeless.moveIn(h: Household, bpId: string): boolean
	if not h.homelessUntil then return false end
	if not _buildingService.addHousehold(bpId) then return false end
	h.homeId = bpId
	h.homelessUntil = nil
	h.homelessPos = nil
	h.movingOut = nil
	for _ = 1, #h.adults + #h.kids do
		if _buildingService.canAcceptResident(bpId) then _buildingService.addResident(bpId) end
	end
	_buildingService.setFamilyName(bpId, h.familyName)
	return true
end

-- One step for a household whose home view is gone. Returns true when it is time to remove
-- them: the search ran out, or they were still moving in and never really arrived.
function Homeless.step(h: Household): boolean
	if h.arriving then return true end

	if not h.homelessUntil then
		h.homelessUntil = os.clock() + Homeless.SECS
		h.homelessPos = h.lastHomePos
		-- Give the old address back. A no-op when the house is rubble, but an ABANDONED home
		-- still holds their household slot and residents, and they do not live there now.
		for _ = 1, #h.adults + #h.kids do _buildingService.removeResident(h.homeId) end
		_buildingService.removeHousehold(h.homeId)
		_buildingService.setFamilyName(h.homeId, nil)
		-- The driveway went with the house; they search on foot.
		for _, a in h.adults do Cars.drop(a) end
		for _, a in h.adults do
			a.tripId += 1
			if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
			if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
			a.stage, a.outKind, a.outDestId, a.usingCar = "atHome", nil, nil, false
			a.tripTargetId, a.tripTargetHome = nil, false
		end
		for _, k in h.kids do
			k.tripId += 1
			if k.riderId then _transitService.cancelRider(k.riderId); k.riderId=nil; k.waitPos=nil end
			if k.walkerId then _walkingService.despawnCommuter(k.walkerId); k.walkerId = nil end
			k.stage = "atHome"
		end
	end
	if os.clock() >= h.homelessUntil then return true end

	-- ponytail: ONE walker represents the family on the hunt -- they knock on one vacancy at
	-- a time. Walk everybody if a crowd of movers ever needs to be visible.
	local a = h.adults[1]
	if not a or a.walkerId or not h.homelessPos then return false end
	local vacancies = _buildingService.getEmptyHomes()
	if #vacancies == 0 then return false end -- nowhere to knock: wait out the clock and leave
	local pick = vacancies[_rng:NextInteger(1, #vacancies)]
	if typeof(pick.doorPos) ~= "Vector3" then return false end

	a.tripId += 1
	local trip = a.tripId
	a.walkerId = _walkingService.spawnCommuter(h.homelessPos, pick.doorPos, function()
		if _households[h.id] ~= h or a.tripId ~= trip then return end
		a.walkerId = nil
		h.homelessPos = pick.doorPos
		Homeless.moveIn(h, pick.groupId)
	end, personLabel(h, a), { gender = a.gender, kind = "adult", seed = a.pid })
	return false
end

-- Walk, bus or own car for one adult's trip: TravelModeChoice decides from the facts
-- gathered here (distance, the car, where it could park, traffic on the way, the best bus).
local function chooseTravelMode(
	h: Household,
	a: Adult,
	fromDoor: Vector3?,
	toDoor: Vector3?,
	canDrive: boolean
): (string, any?)
	if not fromDoor or not toDoor then
		return if canDrive then "drive" else "walk", nil
	end

	-- A citizen who drove out must bring that same car back. Allowing a fresh choice here
	-- stranded cars at workplaces and stations.
	if a.usingCar and canDrive then
		Cars.countMode("drive")
		_travelDebugByPid[a.pid] = {
			chosen = "drive",
			reason = "Drove here, so this trip must bring the car home.",
			directDistance = flatDist(fromDoor, toDoor),
			forced = true,
		}
		return "drive", nil
	end

	local destId = if a.tripTargetHome then h.homeId else a.tripTargetId
	local g = nav()
	local transitEstimate = if _transitService then _transitService.estimateTrip(fromDoor, toDoor) else nil
	local parkWalk, parkPrice = nil, 0
	if canDrive then parkWalk, parkPrice = Cars.parkWalk(h, a, destId, toDoor) end
	local trip: TravelModeChoice.Trip = {
		pid = a.pid,
		age = a.age,
		purpose = if a.tripTargetHome then "home" else a.outKind or (if a.age < AGE_ADULT then "school" else "leisure"),
		distance = flatDist(fromDoor, toDoor),
		canDrive = canDrive,
		parkWalk = parkWalk,
		parkPrice = parkPrice,
		congestion = if canDrive and g then Cars.congestion(g, fromDoor, toDoor) else 1,
		transit = if transitEstimate and transitEstimate.usable then transitEstimate else nil,
		weather = Cars.weather(),
		dark = _timeService ~= nil and _timeService.isDaylight ~= nil and not _timeService.isDaylight(),
		carrying = a.tripTargetHome and a.outKind == "shop",
	}
	if canDrive and not trip.parkWalk then Cars.notePocket(h.id) end
	local chosen, costs = TravelModeChoice.choose(trip)
	Cars.countMode(chosen)
	_travelDebugByPid[a.pid] = {
		chosen = chosen,
		reason = if chosen == "transit" then "Public transport fits this resident’s travel time, fare and preferences."
			elseif chosen == "drive" then "Driving fits this resident’s travel time, parking, fuel cost and preferences."
			else "Walking fits this resident’s travel time, effort and preferences.",
		directDistance = trip.distance,
		walkScore = costs.walk,
		driveScore = costs.drive,
		transitScore = costs.transit,
		transitTime = if transitEstimate then transitEstimate.timeSeconds else nil,
		transitFare = if transitEstimate then transitEstimate.fare else nil,
		parkWalk = trip.parkWalk,
		parkPrice = trip.parkPrice,
		weather = trip.weather,
		congestion = trip.congestion,
		canDrive = canDrive,
	}
	return chosen, if chosen == "transit" then transitEstimate else nil
end

-- How the city travels lately: shares (0..1) of the trips walked, driven, ridden and of the
-- children driven to school, over roughly the last game day (Cars.countMode).
function CitizenService.GetTravelModeShare(): { [string]: number }
	local c = Cars.modeCounts
	local total = math.max(1, c.walk + c.drive + c.transit + c.schoolRun)
	return { walk = c.walk / total, drive = c.drive / total, transit = c.transit / total,
		schoolRun = c.schoolRun / total, trips = total }
end

function CitizenService.AdminAddPopulation(requested: number): { [string]: any }
	local remaining = math.clamp(math.floor(tonumber(requested) or 0), 1, 5000)
	local added = 0
	local householdsAdded = 0
	for _, home in _buildingService.getEmptyHomes() do
		if remaining <= 0 then break end
		local cap = FAMILY_MAX
		local take = math.min(remaining, cap)
		if take <= 0 then continue end
		if not _buildingService.addHousehold(home.groupId) then continue end

		_nextHouseholdId += 1
		local h: Household = {
			id = _nextHouseholdId,
			homeId = home.groupId,
			adults = {},
			kids = {},
			foundedDay = _timeService.getDay(),
			arriving = false,
			familyName = NameGen.familyName(_rng),
		}
		local adultCount = math.min(take, 2)
		for i = 1, adultCount do
			table.insert(h.adults, makeAdult(if i % 2 == 1 then "M" else "F", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
		end
		for _ = adultCount + 1, take do table.insert(h.kids, makeKid()) end

		for _, a in h.adults do
			if a.ownsCar then Cars.give(h, a) end
		end

		_households[h.id] = h
		_buildingService.setFamilyName(h.homeId, h.familyName)
		for _ = 1, take do
			if _buildingService.canAcceptResident(h.homeId) then _buildingService.addResident(h.homeId) end
		end
		_buildingService.setOccupancy(h.homeId, take, cap, "residents", home.level)
		added += take
		remaining -= take
		householdsAdded += 1
	end
	recountPopulation()
	return {
		ok = added > 0,
		added = added,
		population = _population,
		households = householdsAdded,
		error = if added > 0 then nil else "No empty residential capacity is available.",
	}
end

local function isSchoolAge(k: Kid): boolean
	return k.age >= SCHOOL_AGE_MIN and k.age <= SCHOOL_AGE_MAX
end

-- Inject the transit data owner (Bootstrap event-linking). Optional: commuters fall back
-- to driving / walking if it is never set.
function CitizenService.SetTransitService(ts: any)
	_transitService = ts
end

-- A real ride for one adult: walk to the board stop, wait there until a vehicle of the line
-- comes with a free seat, ride it to the alight stop, walk on to the door. If nothing with
-- room comes in their patience they walk the whole way from the stop instead.
local journeys = CitizenJourneys.new({
	getHouseholds = function() return _households end,
	getWalkingService = function() return _walkingService end,
	getTransitService = function() return _transitService end,
	getBuildingService = function() return _buildingService end,
	getEducationService = function() return _educationService end,
	getSupplyService = function() return _supplyService end,
	getEconomyService = function() return _economyService end,
	getFolder = function() return _folder end,
	trips = _trips, workers = _workers, driverJobs = _driverJobs,
	cars = Cars, garage = Garage,
	personLabel = personLabel, kidLabel = kidLabel, chooseTravelMode = chooseTravelMode,
	door = door, flatDist = flatDist, nav = nav, driveTo = driveTo, releaseSpot = releaseSpot,
	pickHomePark = pickHomePark, pickBuildingPark = pickBuildingPark,
	isSchoolAge = isSchoolAge,
	serviceKerb = function(id: string) return CitizenService._svcKerb[id] end,
	-- Game time (days) an errand ends: 20-45 game minutes shopping, 1-2 hours for an evening out.
	dwellUntil = function(kind: string): number
		local minutes = if kind == "leisure" then _rng:NextNumber(60, 120) else _rng:NextNumber(20, 45)
		return _timeService.getDay() + _timeService.getDayFraction() + minutes / 1440
	end,
})
local journey = journeys.journey
local returnHome = journeys.returnHome
local startWork = journeys.startWork
local startErrand = journeys.startErrand
local startSchool = journeys.startSchool
local returnFromSchool = journeys.returnFromSchool

-- Where people go and why. One table, not locals (register limit, see LOD).
--   Destinations follow the planners' gravity model: a place is chosen in proportion to
--   1 / (distance + D0)^BETA, so the corner shop wins most trips and a store across the
--   city only some. Shopping decays steeply (BETA 2), jobs gently (BETA 1): people commute
--   much further than they walk for milk. Before this every trip picked uniformly from the
--   whole city, which is where half the cross-town traffic came from.
--   Walks: an adult at home in the day now and then goes out for a stroll -- a real walk
--   to a spot a few blocks off and back, on the pavement, like any other trip.
local Trips: any = {
	SHOP_BETA = 2, JOB_BETA = 1, D0 = 100,
	WALK_CHANCE = Const.STROLL_CHANCE,          -- per idle sim step, while it is light out
	WALK_MIN = Const.STROLL_MIN, WALK_MAX = Const.STROLL_MAX, -- studs out from the door
	WALK_FROM_HOUR = Const.STROLL_FROM_HOUR, WALK_TO_HOUR = Const.STROLL_TO_HOUR,
}

function Trips.pickNear(ids: { string }, from: Vector3?, beta: number): string?
	if #ids == 0 then return nil end
	if not from then return ids[_rng:NextInteger(1, #ids)] end
	local weights, total = table.create(#ids), 0
	for i, id in ids do
		local p = door(id)
		local w = if p then 1 / (flatDist(from, p) + Trips.D0) ^ beta else 0
		weights[i] = w
		total += w
	end
	if total <= 0 then return ids[_rng:NextInteger(1, #ids)] end
	local roll = _rng:NextNumber() * total
	for i, w in weights do
		roll -= w
		if roll <= 0 then return ids[i] end
	end
	return ids[#ids]
end

-- A shop or night out for one adult. Like Cities: Skylines II, short parking sends drivers
-- elsewhere: a car owner redraws a place with no free space in walking reach, up to
-- PARK_REDRAWS times, then goes anyway (on foot or by bus -- no space, no drive there).
Trips.PARK_REDRAWS = 3
function Trips.pickShop(h: Household, a: Adult, ids: { string }, beta: number): string?
	local from = door(h.homeId)
	local destId = Trips.pickNear(ids, from, beta)
	if not a.car then return destId end
	for _ = 1, Trips.PARK_REDRAWS do
		local toDoor = if destId then door(destId) else nil
		if not toDoor or Cars.parkWalk(h, a, destId, toDoor) ~= nil then return destId end
		destId = Trips.pickNear(ids, from, beta)
	end
	return destId
end

-- == When people set out: from where their day says they should be ==================
-- A trip is due from the STATE of someone's day -- on shift, in school hours, in class --
-- not from a short window at its start. The window version (SHIFT_WINDOW_HOURS, 75 game-
-- seconds) sent a worker off only if the scheduler happened to look at them inside it and
-- found them at home: anyone hired mid-morning, back from the shops a little late, or
-- skipped by a slow sweep in a big city stayed home all day -- measured in the city lab,
-- a quarter of the workforce was at home in the middle of its shift -- and one who missed
-- the homeward window slept at work. Now a person at home during their shift goes (late, if
-- need be, unless too little of it is left), and anyone still at work after it goes home.
Trips.MIN_HOURS_LEFT = 2     -- not worth setting out for the last hours of a shift / school day
Trips.CLASS_START = 9.5      -- university lectures (plus a per-person offset, like shifts)
Trips.CLASS_END = 16.5
Trips.UNI_MAX_AGE = 22       -- SchoolTypes University ageMax: graduation after this
Trips.COLLEGE_SHARE = 0.7    -- of high-school graduates, the share who go on to university
Trips.LEISURE_PER_WEEK = 3   -- evenings out per household per week
Trips.LEISURE_FROM = 17.5    -- evening outings: restaurants, cinemas, the shops on the strip
Trips.LEISURE_TO = 21.5
Trips.LEISURE_BETA = 1.2     -- people go further for an evening out than for milk

-- On a daily timetable [startHour, endHour) (endHour may run past 24)? Also: hours of it
-- still to come, and the calendar day it started on (a night shift started yesterday).
function Trips.status(startHour: number, endHour: number, hour: number, day: number): (boolean, number, number)
	local s = startHour % 24
	local since = (hour - s) % 24
	local length = endHour - startHour
	if since < length then
		return true, length - since, if hour >= s then day else day - 1
	end
	return false, 0, day
end

-- Stable 0..1 per person and purpose (the same answer every time it is asked).
function Trips.roll(pid: number, salt: number): number
	return Random.new(pid * 32 + salt):NextNumber()
end

-- Studying at university right now (enrolled, and the university still takes them)? Finds a
-- seat for a graduate who wants one; nil when there is no university within reach of home.
function Trips.student(h: Household, a: Adult): boolean
	if a.jobId or not a.wantsStudy or a.age > Trips.UNI_MAX_AGE or not _educationService then return false end
	if a.studyId and _educationService.hasSchool and _educationService.hasSchool(a.studyId, a.age) then return true end
	local home = door(h.homeId)
	if not home or not _educationService.getNearestSchool then return false end
	local pos, id = _educationService.getNearestSchool(home, a.age, nil)
	if typeof(pos) ~= "Vector3" or typeof(id) ~= "number" then
		a.studyId, a.studyPos = nil, nil
		return false
	end
	a.studyId, a.studyPos = id, pos
	return true
end

-- To lectures and back, walked, ridden or driven like any other trip: a student who owns a car
-- weighs it like everyone else (they were barred from it, and walked across town to class).
function Trips.toClass(h: Household, a: Adult)
	a.tripId += 1
	local trip = a.tripId
	if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	a.stage = "transit"
	a.outKind = "study"
	a.outDestId = nil
	a.tripTargetId = nil
	a.tripTargetHome = false
	local studyId = a.studyId
	local studyPos = a.studyPos
	journey(h, a, trip, door(h.homeId), studyPos, true, function() return Cars.parkNear(studyPos) end, function()
		if _educationService and _educationService.enterSchool then _educationService.enterSchool(studyId) end
		a.stage = "atStudy"
	end)
end

function Trips.fromClass(h: Household, a: Adult)
	if _households[h.id] == nil then return end
	a.tripId += 1
	local trip = a.tripId
	if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	if a.stage == "atStudy" and _educationService and _educationService.leaveSchool then
		_educationService.leaveSchool(a.studyId)
	end
	a.stage = "transit"
	a.tripTargetId = h.homeId
	a.tripTargetHome = true
	journey(h, a, trip, a.studyPos, door(h.homeId), a.usingCar, function() return pickHomePark(h, a) end, function()
		a.stage = "atHome"
		a.outKind = nil
		a.tripTargetId = nil
		a.tripTargetHome = false
		a.usingCar = false
		-- Graduated (or the university went) while in class: no longer a student.
		if not a.wantsStudy then a.studyId, a.studyPos = nil, nil end
	end)
end

function Trips.walk(h: Household, a: Adult): boolean
	local hour = _timeService.getDayFraction() * 24
	if hour < Trips.WALK_FROM_HOUR or hour >= Trips.WALK_TO_HOUR then return false end
	local weather = Cars.weather()
	if weather == "Rain" or weather == "Snow" then return false end -- nobody strolls in the rain
	local home = door(h.homeId)
	if not home then return false end
	local angle = _rng:NextNumber() * math.pi * 2
	local reach = _rng:NextNumber(Trips.WALK_MIN, Trips.WALK_MAX)
	local spot = _walkingService.getNearestPoint(home + Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach, 60)
	if typeof(spot) ~= "Vector3" then return false end
	a.tripId += 1
	local trip = a.tripId
	a.stage = "transit"
	a.outKind = "walk"
	local label = personLabel(h, a)
	local look = { gender = a.gender, kind = "adult", seed = a.pid }
	local function stale(): boolean
		return _households[h.id] == nil or a.tripId ~= trip
	end
	a.walkerId = _walkingService.spawnCommuter(home, spot, function()
		if stale() then return end
		a.walkerId = _walkingService.spawnCommuter(spot, home, function()
			if stale() then return end
			a.walkerId = nil
			a.stage = "atHome"
			a.outKind = nil
		end, label, look)
	end, label, look)
	return true
end

local function idHash(text: string): number
	local n = 0
	for i = 1, #text do n = (n * 31 + string.byte(text, i)) % 9973 end
	return n
end

local function shiftHours(jobView: any, pid: number, day: number?): (number, number)
	local hash = idHash(tostring(jobView.bpId or ""))
	if jobView.zone == "Industrial" then
		local start = (pid % 3) * 8 + (hash % 3) * 2 -- factory-specific day, evening and night crews
		return start, start + 8
	elseif jobView.zone == "Commercial" then
		if hash % 11 == 0 then return 18, 26 end -- late shop / service shift
		if hash % 3 == 0 then return 11, 20 end -- lunch/evening retail overlap
		return 9, 18
	end
	return 7, 16
end

local function householdShiftOffsetHours(householdId: number): number
	return ((householdId * 17) % 50) / 60
end

local function schoolShiftOffsetHours(pid: number): number
	return ((pid * 13) % 45) / 60
end

-- Educated adults (well/highly) prefer commercial/office work; everyone falls back to any
-- opening. Soft preference -- they still take an industrial job if that's all there is, which
-- surfaces as the over-education pressure stat rather than a hard block.
local function pickJobFor(a: Adult, jobs: { string }, byId: { [string]: any }, home: Vector3?): string?
	if #jobs == 0 then return nil end
	if a.eduLevel >= 2 then
		local pref: { string } = {}
		for _, id in jobs do
			local b = byId[id]
			if b and b.zone == "Commercial" then table.insert(pref, id) end
		end
		if #pref > 0 then return Trips.pickNear(pref, home, Trips.JOB_BETA) end
	end
	return Trips.pickNear(jobs, home, Trips.JOB_BETA)
end

-- Per-step citizen scheduler. Each employed ADULT commutes to their OWN workplace on
-- that workplace's shift; an unemployed adult travels to an opening to APPLY; any idle
-- adult makes occasional SHOPPING trips. Adults act independently -- two in one home can
-- be at two different buildings -- so the family car is claimed first-come (others walk).
local function doActivities(views: { any }, byId: { [string]: any })
	local day = _timeService.getDay()
	local now = os.clock()
	local hour = _timeService.getDayFraction() * 24
	local gameNow = day + _timeService.getDayFraction() -- game days, for the shopping schedule

	local cachedJobs: { string }? = nil
	local cachedStores: { string }? = nil

	-- Resume the round-robin sweep; a finished sweep re-snapshots the household ids.
	if LOD.cursor > #LOD.order then
		table.clear(LOD.order)
		for id in _households do table.insert(LOD.order, id) end
		LOD.cursor = 1
		LOD.lastSweepSteps = LOD.sweepSteps
		LOD.lastSweepGameSeconds = if LOD.sweepStartedAt then math.max(0, (gameNow - LOD.sweepStartedAt) * Const.DAY_SECONDS) else 0
		if LOD.lastSweepGameSeconds > LOD.CONFIG.MAX_SWEEP_SIM_SECONDS then
			warn(string.format("[CitizenService] activity sweep took %.1f game seconds for %d households -- commutes run late", LOD.lastSweepGameSeconds, #LOD.order))
		end
		for id in LOD.activityAt do if not _households[id] then LOD.activityAt[id] = nil end end
		LOD.sweepStartedAt = gameNow
		LOD.sweepSteps = 0
	end
	LOD.sweepSteps += 1
	local deadline = os.clock() + LOD.CONFIG.FRAME_BUDGET

	while LOD.cursor <= #LOD.order do
		local h = _households[LOD.order[LOD.cursor]]
		LOD.cursor += 1
		-- A homeless family runs its own search loop (Homeless.step); every routine below
		-- reads h.homeId, which no longer resolves to anything.
		if h == nil or h.arriving or h.homelessUntil then continue end
		local elapsed = if LOD.activityAt[h.id] then math.max(0, (gameNow - LOD.activityAt[h.id]) * Const.DAY_SECONDS) else SIM_STEP
		LOD.activityAt[h.id] = gameNow
		local walkChance = 1 - (1 - Trips.WALK_CHANCE) ^ (elapsed / SIM_STEP)
		HouseholdNeeds.advance(h, #h.adults + #h.kids, gameNow, h.id)
		local shopping = false
		for _, a in h.adults do
			if a.stage == "transit" and a.outKind == "shop" then shopping = true; break end
		end
		-- Every car owner at home has their car: a new adult buys one, a family that just
		-- moved in or was re-housed gets theirs, and a car despawned out from under us (e.g.
		-- cleared while wedged at an outside connection) is replaced rather than used dead.
		for _, a in h.adults do
			if a.car and not a.car.Parent and not a.usingCar then Cars.drop(a) end
			if a.ownsCar and not a.car and a.stage == "atHome" and now >= (a.nextCarAttemptAt or 0) then
				a.nextCarAttemptAt = now + Const.CAR_PARKING_RETRY_SECONDS
				Cars.give(h, a)
			end
		end

		for _, k in h.kids do
			-- A school run that lost its driver (a household change mid-run) frees the child.
			if k.escortRun and k.stage == "transit" and gameNow > (k.escortUntil or 0) then
				k.escortRun, k.escortUntil = nil, nil
				k.stage = "atHome"
			end
			if not isSchoolAge(k) or k.stage == "transit" then continue end
			local hasSchool = k.schoolId ~= nil and _educationService and _educationService.hasSchool and _educationService.hasSchool(k.schoolId, k.age)
			if hasSchool and _educationService.getSchoolTier then k.bestTier = math.max(k.bestTier, _educationService.getSchoolTier(k.schoolId)) end
			if k.stage == "atSchool" and not hasSchool then
				returnFromSchool(h, k)
				continue
			end
			local soff = schoolShiftOffsetHours(k.pid)
			local inSchool, schoolLeft = Trips.status(SCHOOL_START_HOUR + soff, SCHOOL_END_HOUR + soff, hour, day)
			if k.stage == "atHome" and k.commutedSchoolDay ~= day and inSchool and schoolLeft >= Trips.MIN_HOURS_LEFT then
				if startSchool(h, k) then k.commutedSchoolDay = day end
				continue
			elseif k.stage == "atSchool" and not inSchool then
				if returnFromSchool(h, k) then k.commutedHomeDay = day end
				continue
			end
		end

		for _, a in h.adults do
			if a.stage == "transit" then
				if a.dwellUntil and gameNow >= a.dwellUntil then
					a.dwellUntil = nil
					returnHome(h, a)
				end
				continue
			end

			local jobId = a.jobId
			local jobView = if jobId then byId[jobId] else nil

			-- Self-heal: an adult stuck atWork whose workplace vanished (abandoned or
			-- removed) would dead-end there forever. Send them home so they re-seek work.
			if a.stage == "atWork" and not jobView then
				returnHome(h, a)
				continue
			end

			-- Daily work commute for an employed adult (Trips.status: from the state of the
			-- day, so a late start still goes and nobody sleeps at work).
			if jobId and jobView then
				local startHour, endHour = shiftHours(jobView, a.pid, day)
				local off = householdShiftOffsetHours(h.id)
				local onShift, left, shiftDay = Trips.status(startHour + off, endHour + off, hour, day)
				if onShift and a.stage == "atHome" and a.commutedWorkDay ~= shiftDay and left >= Trips.MIN_HOURS_LEFT then
					a.commutedWorkDay = shiftDay
					startWork(h, a, jobId)
					continue
				elseif not onShift and a.stage == "atWork" then
					a.commutedHomeDay = day
					returnHome(h, a)
					continue
				end
			end

			-- University: lectures on the same state rule, and no job hunting while enrolled.
			local student = Trips.student(h, a)
			if student then
				local off = schoolShiftOffsetHours(a.pid)
				local inClass, left = Trips.status(Trips.CLASS_START + off, Trips.CLASS_END + off, hour, day)
				if inClass and a.stage == "atHome" and a.commutedStudyDay ~= day and left >= Trips.MIN_HOURS_LEFT then
					a.commutedStudyDay = day
					Trips.toClass(h, a)
					continue
				elseif not inClass and a.stage == "atStudy" then
					Trips.fromClass(h, a)
					continue
				end
			elseif a.stage == "atStudy" then
				Trips.fromClass(h, a) -- the university closed (or they graduated) mid-lecture
				continue
			end

			-- Everything below acts only from home.
			if a.stage ~= "atHome" then continue end

			-- Job hunt: an unemployed adult heads to an opening to apply. A short randomised
			-- stagger keeps a wave of arrivals from flooding the roads on the same step; the
			-- transit state self-throttles each adult to one application trip at a time.
			if not jobId and not student and now >= a.nextErrandAt then
				cachedJobs = cachedJobs or openJobs(views)
				if #cachedJobs > 0 then
					local destId = pickJobFor(a, cachedJobs, byId, door(h.homeId))
					if not destId then continue end
					local b = byId[destId]
					a.nextErrandAt = now + _rng:NextNumber(2, 6)
					startErrand(h, a, "apply", destId, if b then jobCapacity(b.zone, b.level) else 0)
					continue
				end
			end

			-- A free adult replenishes actual household goods; one shopper per family.
			if now < a.nextErrandAt then continue end
			if not shopping and HouseholdNeeds.wantsShopping(h, #h.adults + #h.kids) then
				cachedStores = cachedStores or stores(views, hour)
				local destId = Trips.pickShop(h, a, cachedStores :: {string}, Trips.SHOP_BETA)
				if destId then
					shopping = true
					a.nextErrandAt = now + ERRAND_COOLDOWN
					startErrand(h, a, "shop", destId, 0)
					continue
				end
			end

			-- An evening out: a restaurant, a film, the shops on the strip -- a few evenings
			-- a week, whoever of the family is home and free, like the shopping schedule.
			if not h.nextLeisureAt then h.nextLeisureAt = gameNow + _rng:NextNumber() * (7 / Trips.LEISURE_PER_WEEK) end
			if hour >= Trips.LEISURE_FROM and hour < Trips.LEISURE_TO and gameNow >= (h.nextLeisureAt :: number) then
				cachedStores = cachedStores or stores(views)
				local destId = Trips.pickShop(h, a, cachedStores :: { string }, Trips.LEISURE_BETA)
				if destId then
					h.nextLeisureAt = gameNow + (7 / Trips.LEISURE_PER_WEEK) * _rng:NextNumber(0.5, 1.5)
					a.nextErrandAt = now + ERRAND_COOLDOWN
					startErrand(h, a, "leisure", destId, 0)
					continue
				end
			end

			-- A walk for its own sake, while it is light out.
			if hour >= Trips.WALK_FROM_HOUR and hour < Trips.WALK_TO_HOUR
				and _rng:NextNumber() < walkChance and Trips.walk(h, a) then
				a.nextErrandAt = now + ERRAND_COOLDOWN
				continue
			end
		end

		if os.clock() >= deadline then break end
	end
end

-- Families do not sit out a dark, dry or backed-up home forever. Past a grace period each
-- household rolls every sim step to pack up and leave the city -- likelier with each
-- utility missing -- so a street without water empties over minutes, one family at a
-- time, not all at once. Fixing it resets the clock. A table of fields, not locals: the
-- main chunk is at the register limit (see LOD).
local Utility: any = {
	GRACE        = 120,  -- game-seconds a home may go without before anyone thinks of leaving
	LEAVE_CHANCE = 0.03, -- per sim step, per missing utility, once past the grace
	-- A home whose road was deleted (PlotService stage "leaving"): each family rolls this per
	-- sim step to go house-hunting -- one at a time, into a free home if there is one.
	ROAD_LEAVE_CHANCE = 0.02,
}

-- Out on a trip right now. Removing a household mid-trip despawns the car and the citizen
-- the instant they meet -- the "parked roadside car vanishes as the person gets in" glitch
-- -- so a family that has decided to leave does it once everyone is home.
function Utility.midTrip(h: Household): boolean
	for _, a in h.adults do
		if a.stage == "transit" or a.walkerId ~= nil then return true end
		if a.car and (_trips[a.car] ~= nil or NPCDriverService.IsDirected(a.car)) then return true end
	end
	for _, kid in h.kids do
		if kid.stage == "transit" or kid.walkerId ~= nil then return true end
	end
	return false
end

function Utility.step(byId: { [string]: any })
	local leaving: { number } = {}
	for id, h in _households do
		if h.arriving then continue end
		local home = byId[h.homeId]
		if not home then continue end
		if home.roadless == "leaving" then
			if not h.movingOut and _rng:NextNumber() < Utility.ROAD_LEAVE_CHANCE and not Utility.midTrip(h) then
				h.movingOut = true -- the main pass sends them house-hunting (Homeless)
			end
			continue
		end
		local missing = (if home.powered == false then 1 else 0)
			+ (if home.watered == false then 1 else 0)
			+ (if home.drained == false then 1 else 0)
		if missing == 0 then h.unservedFor = nil; continue end
		h.unservedFor = (h.unservedFor or 0) + SIM_STEP
		if h.unservedFor >= Utility.GRACE and _rng:NextNumber() < Utility.LEAVE_CHANCE * missing
			and not Utility.midTrip(h) then
			leaving[#leaving + 1] = id
		end
	end
	for _, id in leaving do removeHousehold(id, byId) end
end

local function dailyTick(byId: { [string]: any })
	local toRemove: { number } = {}
	-- Snapshot clinic positions once for the whole daily pass (see hasHealthcare).
	local clinics: { Vector3 } = {}
	for _, inst in CollectionService:GetTagged("Healthcare") do
		if inst:IsA("Model") or inst:IsA("BasePart") then
			local ok, p = pcall(function() return inst:GetPivot().Position end)
			if ok then table.insert(clinics, p) end
		end
	end
	for id, h in _households do
		if h.arriving then continue end

		local anyJob = false
		local allJoblessLong = #h.adults > 0
		for _, a in h.adults do
			if a.jobId then anyJob = true; a.joblessDays = 0
			elseif a.studyId then a.joblessDays = 0 -- studying, not out of work
			else a.joblessDays += 1 end
			if a.joblessDays < LEAVE_JOBLESS_DAYS then allJoblessLong = false end
		end

		if allJoblessLong then
			-- They leave on a later tick once everyone is settled back home.
			if not Utility.midTrip(h) then
				table.insert(toRemove, id)
			end
			continue
		end

		-- Everyone ages one step. Kids who reach adulthood become job-seeking adults.
		for _, a in h.adults do
			a.age += AGE_PER_DAY
			-- Graduation: past university age, a student leaves with a degree and looks for work.
			if a.wantsStudy and a.age > Trips.UNI_MAX_AGE then
				if a.studyId then a.eduLevel = math.max(a.eduLevel, 3) end
				a.wantsStudy = nil
				if a.stage ~= "atStudy" then a.studyId, a.studyPos = nil, nil end
			end
		end
		for i = #h.kids, 1, -1 do
			local kid = h.kids[i]
			kid.age += AGE_PER_DAY
			if kid.age >= AGE_ADULT then
				if kid.riderId then _transitService.cancelRider(kid.riderId); kid.riderId=nil; kid.waitPos=nil end
			if kid.walkerId then _walkingService.despawnCommuter(kid.walkerId) end
				if kid.stage == "atSchool" and _educationService and _educationService.leaveSchool then
					_educationService.leaveSchool(kid.schoolId)
				end
				table.remove(h.kids, i)
				LOD.pidGen += 1
				local level = graduateEduLevel(kid, door(h.homeId))
				table.insert(h.adults, {
					name = kid.name, gender = kid.gender, age = kid.age, pid = kid.pid, eduLevel = level, tripTargetId = nil, tripTargetHome = false,
					wantsStudy = level >= 2 and Trips.roll(kid.pid, 3) < Trips.COLLEGE_SHARE,
					jobId = nil, joblessDays = 0,
					stage = "atHome", tripId = 0, walkerId = nil,
					outKind = nil, outDestId = nil, usingCar = false, ownsCar = TravelModeChoice.ownsCar(kid.pid),
					commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
				})
			end
		end

		-- Birth: a mother+father couple (mother still of child-bearing age), with healthcare
		-- coverage and room, occasionally has a baby (starts at age 0).
		if #h.kids < MAX_KIDS and anyJob and hasCouple(h) and youngestFemaleAge(h) <= MOTHER_FERTILE_MAX then
			local homeKerb = _buildingService.getKerb(h.homeId)
			if homeKerb and hasHealthcare(clinics, homeKerb) and _buildingService.canAcceptResident(h.homeId) then
				if _rng:NextNumber() < BIRTH_CHANCE then
					local baby = makeKid()
					baby.age = 0
					table.insert(h.kids, baby)
					LOD.pidGen += 1
					_buildingService.addResident(h.homeId)
				end
			end
		end
	end
	for _, id in toRemove do removeHousehold(id, byId) end
	-- Share of households that found nowhere to park today: a city without parking is an
	-- unhappy one (CityStatsService).
	local households, pocketed = 0, 0
	for id in _households do
		households += 1
		if Cars.pocketedToday[id] then pocketed += 1 end
	end
	table.clear(Cars.pocketedToday)
	if _cityStatsService.setParkingStats then
		_cityStatsService.setParkingStats({ pocketedFraction = if households > 0 then pocketed / households else 0 })
	end
end

local function syncEducationDemand()
	if not _educationService or not _educationService.setPupilDemand then return end
	local eligible = 0
	local assigned = 0
	for _, h in _households do
		if h.arriving then continue end
		local home = door(h.homeId)
		for _, k in h.kids do
			if not isSchoolAge(k) then continue end
			eligible += 1
			local schoolId = k.schoolId
			if schoolId and _educationService.hasSchool and _educationService.hasSchool(schoolId, k.age) then
				assigned += 1
			elseif typeof(home) == "Vector3" and _educationService.getNearestSchool then
				local _, candidateId = _educationService.getNearestSchool(home, k.age, nil)
				if typeof(candidateId) == "number" then assigned += 1 end
			end
		end
	end
	_educationService.setPupilDemand(eligible, assigned)
end

-- Summarise the adult workforce's education for the economy: the educated share, and the
-- share of EMPLOYED adults over-educated for their job (well/highly-educated stuck in basic
-- industry). CityStatsService turns over-education into commercial demand + lower happiness.
-- One traversal, two consumers: the workforce summary CityStatsService reads, and the
-- education histogram CityEconomyService taxes on. These were two separate full
-- households-x-adults scans per sim step.
local function pushWorkforceEducation(byId: { [string]: any })
	local total, employed, educated, over = 0, 0, 0, 0
	local c0, c1, c2, c3 = 0, 0, 0, 0
	for _, h in _households do
		if h.arriving then continue end
		for _, a in h.adults do
			-- Students are not in the labour force: they neither work nor count as jobless.
			if not a.studyId then total += 1 end
			local lvl = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3)
			if lvl == 0 then c0 += 1 elseif lvl == 1 then c1 += 1 elseif lvl == 2 then c2 += 1 else c3 += 1 end
			if a.eduLevel >= 2 then educated += 1 end
			if a.jobId then
				employed += 1
				local jv = byId[a.jobId]
				if a.eduLevel >= 2 and jv and jv.zone == "Industrial" then over += 1 end
			end
		end
	end
	LOD.eduCounts[0], LOD.eduCounts[1], LOD.eduCounts[2], LOD.eduCounts[3] = c0, c1, c2, c3
	LOD.eduTotal = total
	LOD.eduFresh = true
	if not _cityStatsService or not _cityStatsService.setWorkforce then return end
	_cityStatsService.setWorkforce({
		totalAdults = total,
		employed = employed,
		educatedFraction = if total > 0 then educated / total else 0,
		overeducatedFraction = if employed > 0 then over / employed else 0,
	})
	-- Ridership rides along on the same push: a used bus network lifts residential
	-- move-in demand (CityStatsService's `transit` factor).
	if _cityStatsService.setTransitStats and _transitService and _transitService.getMonthlyRiders then
		_cityStatsService.setTransitStats({ riders = _transitService.getMonthlyRiders() })
	end
end

-- Adult population split by education level (0 Uneducated, 1 Educated, 2 Well, 3 Highly).
-- The economy uses this to tax residents by income bracket. Served from the histogram the
-- workforce pass already built; the live scan below is the fallback for callers that ask
-- before the first sim step has run (or during a restore).
function CitizenService.getEducationBreakdown(): { counts: { [number]: number }, total: number }
	if LOD.eduFresh then
		return { counts = table.clone(LOD.eduCounts), total = LOD.eduTotal }
	end
	local counts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	local total = 0
	for _, h in _households do
		if h.arriving then continue end
		for _, a in h.adults do
			local lvl = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3)
			counts[lvl] += 1
			total += 1
		end
	end
	return { counts = counts, total = total }
end

local function simStep()
	if _restoring then return end
	LOD.step += 1
	local views = CitizenService._svcViews()
	local byId: { [string]: any } = {}
	for _, b in views do byId[b.bpId] = b end

	-- CitizenService is the sole authority on occupancy. Take over each building the
	-- first time we see it -- clearing the old abstract sim's baked residents/fill so
	-- real households become the only source of fill. This is per-building (not a
	-- one-shot flag) on purpose: the city slot loads its buildings AFTER this loop
	-- first runs at boot, and the old one-shot reconcile consumed itself over an empty
	-- building set, so every restored building kept its baked fill -- which
	-- CityStatsService read as a half-full city, driving residential demand negative so
	-- no household ever moved in and the city froze at the starter seed.
	for _, b in views do
		if not _reconciledIds[b.bpId] then
			_reconciledIds[b.bpId] = true
			if isResZone(b.zone) and b.residents then
				for _ = 1, b.residents do _buildingService.removeResident(b.bpId) end
			elseif b.zone == "Commercial" or b.zone == "Industrial" then
				_workers[b.bpId] = nil
			end
		end
	end

	-- Drop reconcile marks for buildings that no longer exist.
	for bpId in _reconciledIds do
		if not byId[bpId] then _reconciledIds[bpId] = nil end
	end

	-- Homes/jobs that no longer exist or no longer match their role. One traversal:
	-- a household whose home is gone goes on the removal list and skips job validation
	-- (removeHousehold releases its job slots anyway); everyone else is validated in place.
	-- This was two full passes, the second of them households-x-adults.
	local deadHomes: { number } = {}
	for id, h in _households do
		local homeView = byId[h.homeId]
		if not isResidentialHomeView(homeView) or h.movingOut then
			-- Not "delete the family": they go house-hunting, and only the ones who find
			-- nothing inside Homeless.SECS actually leave the city. A family moving out of
			-- a home with no road (Utility.step) hunts the same way while it still stands.
			if Homeless.step(h) then table.insert(deadHomes, id) end
			continue
		end
		-- Where the search starts from if this house ever comes down.
		h.lastHomePos = homeView.position or h.lastHomePos
		-- A home can come BACK (an abandoned one recovers). Clear the search state or the
		-- family stays skipped by doActivities forever, living in a house they never leave.
		h.homelessUntil = nil
		h.homelessPos = nil
		for _, a in h.adults do
			if a.jobId and not isJobView(byId[a.jobId]) then
				_workers[a.jobId] = math.max(0, (_workers[a.jobId] or 1) - 1)
				a.jobId = nil
			end
		end
	end
	for _, id in deadHomes do removeHousehold(id, byId) end
	Cars.sweepOrphans(byId)
	Utility.step(byId)

	local day = _timeService.getDay()
	if day > _lastDayProcessed then
		_lastDayProcessed = day
		dailyTick(byId)
	end

	pushWorkforceEducation(byId)
	seedStarterHouseholds()

	-- Demand scales the ARRIVAL RATE instead of hard-gating it: full demand fills the
	-- whole per-step budget, low demand is a slow trickle, and even a struggling city
	-- gets the odd hopeful family (who leave again via the jobless churn if it stays
	-- bad) -- so arrivals can never deadlock and the city always feels alive.
	-- Movers are pulled by jobs/reputation, not pushed away by the empty homes they
	-- move into -- vacancy only suppresses the construction-gating demand bar.
	local rDemand = if _cityStatsService.getMoveInDemand
		then tonumber(_cityStatsService.getMoveInDemand()) or 0
		else tonumber(_cityStatsService.getDemand().R) or 0
	local arriveChance = math.clamp(ARRIVE_BASE_CHANCE + rDemand, ARRIVE_MIN_CHANCE, 1)
	-- Several movers may enter at once -- one per free entrance (the per-connection
	-- spawn pipes keep them from stacking) -- scaled by how badly people want in.
	local budget = if _rng:NextNumber() < arriveChance
		then math.max(1, math.ceil(math.clamp(rDemand, 0, 1) * Pipe.MAX_ARRIVALS_PER_STEP))
		else 0
	if budget > 0 then
		local launched = 0
		for _, home in _buildingService.getEmptyHomes() do
			if launched >= budget then break end
			if tryArrival(home) then
				launched += 1
			end
		end
	end

	Pipe.activityViews, Pipe.activityById = views, byId
	-- School demand only feeds the education panel and coverage bar, so it does not need
	-- recomputing every step; the per-kid getNearestSchool probes are the expensive part.
	if LOD.step % LOD.EDU_EVERY == 0 then syncEducationDemand() end

	for _, b in views do syncFill(b) end
	recountPopulation()
end

local function cframeToData(cf: CFrame): { number }
	return { cf:GetComponents() }
end

local function dataToCFrame(data: any): CFrame?
	if typeof(data) ~= "table" then return nil end
	local c: { number } = table.create(12)
	for i = 1, 12 do
		local n = tonumber(data[i])
		if not n then return nil end
		c[i] = n
	end
	return CFrame.new(table.unpack(c))
end

local function roundCarNumber(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local function cframeToCarData(cf: CFrame): { number }
	local pos = cf.Position
	local look = cf.LookVector
	local yaw = math.deg(math.atan2(-look.X, -look.Z))
	return { roundCarNumber(pos.X), roundCarNumber(pos.Y), roundCarNumber(pos.Z), roundCarNumber(yaw) }
end

local function carDataToCFrame(data: any): CFrame?
	if typeof(data) ~= "table" then return nil end
	local x = tonumber(data[1])
	local y = tonumber(data[2])
	local z = tonumber(data[3])
	local yaw = tonumber(data[4])
	if not x or not y or not z or not yaw then return nil end
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0)
end

local function buildingSaveKey(view: any): string?
	return if typeof(view) == "table" and typeof(view.saveKey) == "string" and view.saveKey ~= "" then view.saveKey else nil
end

local function resolveSavedKey(keys: any, value: any): string?
	if typeof(value) == "number" and typeof(keys) == "table" then
		local key = keys[value]
		return if typeof(key) == "string" then key else nil
	end
	return if typeof(value) == "string" then value else nil
end

local function makeKeyIndexer(): ({ string }, (string?) -> number?)
	local keys: { string } = {}
	local byKey: { [string]: number } = {}
	local function intern(key: string?): number?
		if not key then return nil end
		local existing = byKey[key]
		if existing then return existing end
		local idx = #keys + 1
		keys[idx] = key
		byKey[key] = idx
		return idx
	end
	return keys, intern
end

local function activeCarState(h: Household, holderIdx: number, byId: { [string]: any }, intern: (string?) -> number?, homeKeyIdx: number): any?
	local holder = h.adults[holderIdx]
	local car = holder.car
	if not car or (not car:IsDescendantOf(Workspace) and car:GetAttribute("RestorePending") ~= true) or holder.stage ~= "transit" or holder.usingCar ~= true
		or (not _trips[car] and not NPCDriverService.IsDirected(car) and car:GetAttribute("RestorePending") ~= true
			and car:GetAttribute("DriveRetryPending") ~= true) then
		return nil
	end
	-- A car on the road AI still stands where it spawned; its live pose is the driver's.
	local trip = _trips[car]
	local pose = NPCDriverService.GetLivePose(car) or (if trip then trip.smoothCFrame else nil) or car:GetPivot()

	local homeTarget = holder.tripTargetHome == true
	local targetId = if homeTarget then h.homeId else (holder.tripTargetId or holder.outDestId)
	if typeof(targetId) ~= "string" then return nil end

	local targetKeyIdx = homeKeyIdx
	if not homeTarget then
		local targetView = byId[targetId]
		if not targetView then return nil end
		targetKeyIdx = intern(buildingSaveKey(targetView))
		if not targetKeyIdx then return nil end
	end

	local anchor = NPCDriverService.GetLaneAnchor(car)
	if not anchor and car:GetAttribute("RestorePending") == true then
		local edgeId, dist = car:GetAttribute("RestoreEdge"), car:GetAttribute("RestoreDist")
		if typeof(edgeId) == "string" and typeof(dist) == "number" then anchor = {edgeId=edgeId,dist=dist} end
	end
	return {
		ln = if anchor then anchor.edgeId else nil,
		ld = if anchor then anchor.dist else nil,
		c = cframeToCarData(pose),
		a = holderIdx,
		d = targetKeyIdx,
		hm = if homeTarget then true else nil,
		k = holder.outKind,
	}
end

function Pipe.activityPosition(person: any): Vector3?
	if person.walkerId then
		local pos = _walkingService.getCommuterPosition(person.walkerId)
		if pos then return pos end
	end
	if person.riderId and _transitService then
		local pos = _transitService.getRiderPosition(person.riderId)
		if pos then return pos end
	end
	return person.waitPos
end

function CitizenService.serialize(): { [string]: any }
	local views = CitizenService._svcViews()
	local byId: { [string]: any } = {}
	for _, b in views do
		byId[b.bpId] = b
	end

	local keys, intern = makeKeyIndexer()
	local homes: { any } = {}
	for _, h in _households do
		if h.arriving then continue end
		local homeView = byId[h.homeId]
		if not isResidentialHomeView(homeView) then continue end
		local homeKeyIdx = intern(buildingSaveKey(homeView))
		if not homeKeyIdx then continue end

		local edu = { 0, 0, 0, 0 }
		local jobsByKey: { [string]: number } = {}
		for _, a in h.adults do
			local level = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3)
			edu[level + 1] += 1
			local jobView = if a.jobId then byId[a.jobId] else nil
			local jobKey = buildingSaveKey(jobView)
			if jobKey then
				jobsByKey[jobKey] = (jobsByKey[jobKey] or 0) + 1
			end
		end

		local jobs: { any } = {}
		for jobKey, count in jobsByKey do
			local jobKeyIdx = intern(jobKey)
			if jobKeyIdx then
				table.insert(jobs, { jobKeyIdx, count })
			end
		end

		local row = {
			h = homeKeyIdx,
			a = #h.adults,
			k = #h.kids,
			e = edu,
			j = jobs,
			f = h.foundedDay,
			g = h.goodsStock,
		}
		-- Per adult (index into the restored adults): `o` who owns a car, `cv` cars out on a
		-- trip, `cp` parked cars saved where they stand -- one left in a car park belongs back
		-- in that stall on load, not at the kerb. A pocketed car (ServerStorage) stands
		-- nowhere, so it re-picks a spot on load. Pre-2026-09-25 saves carry one household
		-- car as `v` / `p` instead; restore reads both.
		-- `w`: adults at work at save time (they come back there, not at home). A parked car
		-- entry's 3rd field marks a car left at the workplace, which its driver takes home.
		local owners, driving, parked, atWork = {}, {}, {}, {}
		for i, a in h.adults do
			if a.ownsCar then table.insert(owners, i) end
			if a.stage == "atWork" and a.jobId then table.insert(atWork, i) end
			local vehicle = activeCarState(h, i, byId, intern, homeKeyIdx)
			if vehicle then
				table.insert(driving, vehicle)
			elseif a.car and not _trips[a.car] and a.car:IsDescendantOf(Workspace) and not NPCDriverService.IsDirected(a.car) then
				-- (A car out on the road that is not a trip we can resume is not parked: saving
				-- its pose put it back ON THE LANE on load, abandoned, and the queue behind it
				-- froze. Unsaved, its owner gets a car at home again -- see restoreCars.)
				table.insert(parked, { i, cframeToCarData(a.car:GetPivot()), if a.usingCar then true else nil })
			end
		end
		row.hh, row.fn = h.id, h.familyName
		row.rs, row.ks = {}, {}
		for _, a in h.adults do
			table.insert(row.rs, CitizenActivityState.pack(a,
				intern(buildingSaveKey(byId[a.jobId])), intern(buildingSaveKey(byId[a.outDestId])),
				Pipe.activityPosition(a)))
		end
		for _, k in h.kids do table.insert(row.ks, CitizenActivityState.pack(k,nil,nil,Pipe.activityPosition(k))) end
		row.o = if #owners > 0 then owners else nil
		row.cv = if #driving > 0 then driving else nil
		row.cp = if #parked > 0 then parked else nil
		row.w = if #atWork > 0 then atWork else nil
		table.insert(homes, row)
	end

	return {
		version = 3,
		nextHouseholdId = _nextHouseholdId,
		nextPersonId = _nextPersonId,
		keys = keys,
		columns = CitizenSaveColumns.toColumns(homes),
	}
end

local function makeRestoredHousehold(homeId: string, foundedDay: any): Household
	_nextHouseholdId += 1
	return {
		id = _nextHouseholdId,
		homeId = homeId,
		adults = {},
		kids = {},
		foundedDay = math.max(1, math.floor(tonumber(foundedDay) or _timeService.getDay())),
		arriving = false,
		familyName = NameGen.familyName(_rng),
	}
end

local function addRestoredPeople(h: Household, adultCount: number, kidCount: number, eduCounts: any)
	local eduRemaining = { 0, 0, 0, 0 }
	if typeof(eduCounts) == "table" then
		for i = 1, 4 do
			eduRemaining[i] = math.max(0, math.floor(tonumber(eduCounts[i]) or 0))
		end
	end

	for i = 1, adultCount do
		local gender = if i % 2 == 1 then "M" else "F"
		local adult = makeAdult(gender, _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE))
		for level = 3, 0, -1 do
			local idx = level + 1
			if eduRemaining[idx] > 0 then
				eduRemaining[idx] -= 1
				adult.eduLevel = level
				break
			end
		end
		table.insert(h.adults, adult)
	end

	for _ = 1, kidCount do
		table.insert(h.kids, makeKid())
	end
end

local function assignRestoredJobs(h: Household, jobs: any, keys: any, bySaveKey: { [string]: any })
	if typeof(jobs) ~= "table" then return end
	local adultIndex = 1
	for _, row in jobs do
		if adultIndex > #h.adults then break end
		if typeof(row) ~= "table" then continue end
		local jobKey = resolveSavedKey(keys, row[1] or row.j)
		local count = math.max(0, math.floor(tonumber(row[2] or row.n) or 0))
		local jobView = if jobKey then bySaveKey[jobKey] else nil
		if count <= 0 or not isJobView(jobView) then continue end

		local jobId = jobView.bpId
		local cap = jobCapacity(jobView.zone, jobView.level)
		local open = math.max(0, cap - (_workers[jobId] or 0) - (_driverJobs[jobId] or 0))
		local take = math.min(count, open, #h.adults - adultIndex + 1)
		for _ = 1, take do
			local adult = h.adults[adultIndex]
			adult.jobId = jobId
			adult.stage = "atHome"
			_workers[jobId] = (_workers[jobId] or 0) + 1
			adultIndex += 1
		end
	end
end

-- Cars as saved: who owns one, and the parked ones back where they stood (Cars.give reserves
-- that bay by position; a spot edited away since falls back to the normal home pick). A
-- car that was out driving is resumed by resumeRestoredCar; owners with neither get theirs
-- from doActivities. Legacy saves had ONE household car: it goes to the first owner.
local function restoreCars(h: Household, row: any)
	if typeof(row.o) == "table" then
		for _, a in h.adults do a.ownsCar = false end
		for _, i in row.o do
			local a = h.adults[tonumber(i) or 0]
			if a then a.ownsCar = true end
		end
	end
	if typeof(row.w) == "table" then
		for _, i in row.w do
			local a = h.adults[tonumber(i) or 0]
			if a and a.jobId then
				a.stage, a.outKind, a.outDestId = "atWork", "work", a.jobId
			end
		end
	end
	if typeof(row.cp) == "table" then
		for _, entry in row.cp do
			local a = if typeof(entry) == "table" then h.adults[tonumber(entry[1]) or 0] else nil
			if a and a.ownsCar and not a.car then
				local away = entry[3] == true and a.stage == "atWork"
				local at = carDataToCFrame(entry[2])
				-- A "parked" car standing on a lane is one that was out driving when an older
				-- build saved it. Put back there it is abandoned in the road and the queue
				-- behind it never moves; give it a normal spot instead.
				local g = nav()
				if at and g then
					local p = at.Position
					g:NearestEdge(p, function(edge: any): boolean
						local pts = edge.points
						for k = 1, #pts - 1 do
							local s, d = pts[k], pts[k + 1] - pts[k]
							local t = math.clamp((p - s):Dot(d) / math.max(d:Dot(d), 1e-6), 0, 1)
							if flatDist(p, s + d * t) < 2 then at = nil end
						end
						return true
					end)
				end
				Cars.give(h, a, at, away)
				a.usingCar = away and at ~= nil -- sent home instead: not left at work
			end
		end
	elseif row.p then
		for _, a in h.adults do
			if a.ownsCar then Cars.give(h, a, carDataToCFrame(row.p)); break end
		end
	end
end

local function finishRestoredHousehold(h: Household, homeView: any)
	local homeId = h.homeId
	_households[h.id] = h
	_buildingService.addHousehold(homeId)
	_buildingService.setFamilyName(homeId, h.familyName)

	local total = #h.adults + #h.kids
	for _ = 1, total do
		if _buildingService.canAcceptResident(homeId) then
			_buildingService.addResident(homeId)
		end
	end

	_buildingService.setOccupancy(homeId, total, _buildingService.getResidentCap(homeId), "residents", homeView.level)
end

local function resumeRestoredCar(h: Household, carState: any, keys: any, bySaveKey: { [string]: any }, homeView: any)
	if typeof(carState) ~= "table" then return end
	local cf = carDataToCFrame(carState.c)
	if not cf then return end

	local adultIndex = math.floor(tonumber(carState.a) or 0)
	local adult = h.adults[adultIndex]
	if not adult then return end

	local homeTarget = carState.hm == true
	local targetView = homeView
	if not homeTarget then
		local targetKey = resolveSavedKey(keys, carState.d)
		targetView = if targetKey then bySaveKey[targetKey] else nil
		if typeof(targetView) ~= "table" then return end
	end
	local targetId = if homeTarget then h.homeId else targetView.bpId
	if typeof(targetId) ~= "string" then return end

	local g = nav()
	local finite = cf.Position == cf.Position and cf.Position.Magnitude < math.huge
	local near = if finite and g then g:NearestEdge(cf.Position) else nil
	if not near or near.distance > ROADSIDE_RADIUS or cf.Position ~= cf.Position then
		-- Older saves wrote hidden, timer-driven cars at the origin as active trips.
		-- Rebuild their home parking instead of retrying an impossible commute forever.
		adult.stage, adult.usingCar = "atHome", false
		adult.outKind, adult.outDestId = nil, nil
		adult.tripTargetId, adult.tripTargetHome = nil, false
		warn(string.format("[CitizenService] restore: citizen %d has an invalid saved commute; restarting at home", adult.pid))
		return
	end

	-- The car is out with them, so it is theirs whatever the ownership roll says.
	adult.ownsCar = true
	if not adult.car then
		adult.car = newCar()
		if not adult.car then return end
		if not adult.driveKey then adult.homeParkCF, adult.driveKey = claimDriveway(h.homeId) end
	end
	local car = adult.car :: Model
	releaseSpot(adult)
	local restoredLane = if typeof(carState.ln)=="string" and typeof(carState.ld)=="number" and carState.ld==carState.ld and carState.ld>=0 and g:GetEdge(carState.ln)
		then {edgeId=carState.ln,dist=carState.ld} else Cars.pinLane(g,cf.Position,cf.LookVector)
	if restoredLane then
		local seat, dist = NPCDriverService.GetRestoreSeat(car, restoredLane)
		if seat and dist then cf=seat; restoredLane.dist=dist end
	end
	Garage.stow(car)
	car:PivotTo(cf)
	car:SetAttribute("RestorePending", true)
	car:SetAttribute("RestoreEdge", if restoredLane then restoredLane.edgeId else nil)
	car:SetAttribute("RestoreDist", if restoredLane then restoredLane.dist else nil)
	local choice = if homeTarget then pickHomePark(h, adult) else pickBuildingPark(h, targetId)
	-- Nowhere to park at the end: pocket it rather than leave it standing in the lane.
	if not choice or not choice.cf then car:SetAttribute("RestorePending", nil); Garage.stow(car) return end
	-- Stall is reserved at pick time: record it NOW so a household removed mid-drive
	-- still frees it through releaseSpot instead of leaking an occupied stall.
	adult.parkStallKey = choice.stallKey

	local kind = if typeof(carState.k) == "string" then carState.k else if adult.jobId == targetId then "work" else "shop"
	car:SetAttribute("RouteStyle", if kind == "shop" or kind == "leisure" then "leisure" else "commuter")
	adult.tripId += 1
	local trip = adult.tripId
	adult.stage = "transit"
	adult.walkerId = nil
	adult.usingCar = true
	adult.tripTargetId = targetId
	adult.tripTargetHome = homeTarget
	if not homeTarget then
		adult.outKind = kind
		adult.outDestId = targetId
	end

	driveTo(car, choice.cf, function()
		if _households[h.id] ~= h or adult.tripId ~= trip then return end
		adult.parkSpotId = choice.spotId
		adult.parkEgress = choice.egress
		adult.parkGraphPoint = choice.lotExit or choice.lotEntry
		adult.tripTargetId = nil
		adult.tripTargetHome = false
		if choice.pocket then Garage.stow(car); Cars.notePocket(h.id) end -- no legal spot: pocket it

		if homeTarget then
			adult.stage = "atHome"
			adult.outKind = nil
			adult.outDestId = nil
			adult.usingCar = false
		elseif kind == "work" then
			adult.stage = "atWork"
		elseif kind == "apply" and isJobView(targetView) then
			journeys.applyForJob(h, adult, targetId, jobCapacity(targetView.zone, targetView.level))
			returnHome(h, adult)
		elseif kind == "shop" then
			journeys.doShopping(h, targetId)
			returnHome(h, adult)
		else
			adult.stage = if adult.jobId == targetId then "atWork" else "atHome"
			if adult.stage == "atHome" then
				adult.outKind = nil
				adult.outDestId = nil
				adult.usingCar = false
			end
		end
	end, {
		pocket = choice.pocket,
		onRoad = true,
		restorePending = true,
		exactSeat = restoredLane ~= nil,
		startLane = restoredLane,
		fromGraphPoint = cf.Position,
		toGraphPoint = choice.lotEntry,
		exitGraphPoint = choice.lotExit,
		approach = choice.approach,
		isValid = function() return _households[h.id] == h and adult.tripId == trip end,
	})
end

-- City restore: budget the household loop -- each iteration clones a car model and
-- may kick off resume pathfinding, and doing all of them in one frame is part of the
-- post-load client freeze (see BuildingService.RESTORE_FRAME_BUDGET, same pattern).
local RESTORE_FRAME_BUDGET = 0.025 -- the player is behind the loading screen; 8 ms left the restore idle most of each frame (2026-10-01)

function Pipe.restoreActivities(h: Household, row: any, keys: any, bySaveKey: {[string]: any})
	if typeof(row.hh)=="number" and row.hh>0 and row.hh%1==0 and not _households[row.hh] then h.id=row.hh end
	if typeof(row.fn)=="string" and row.fn~="" then h.familyName=row.fn:sub(1,80) end
	for i,a in h.adults do
		local record=if typeof(row.rs)=="table" then row.rs[i] else nil
		if not CitizenActivityState.apply(a,record) then continue end
		_nextPersonId=math.max(_nextPersonId,a.pid)
		local jobKey=resolveSavedKey(keys,record[6])
		local job=if jobKey then bySaveKey[jobKey] else nil
		if isJobView(job) and (_workers[job.bpId] or 0)<jobCapacity(job.zone,job.level) then
			a.jobId=job.bpId;_workers[job.bpId]=(_workers[job.bpId] or 0)+1
		elseif a.stage=="atWork" then a.stage="atHome" end
		local destKey=resolveSavedKey(keys,record[10])
		local dest=if destKey then bySaveKey[destKey] else nil
		a.outDestId=if dest then dest.bpId else nil
		if a.stage=="atWork" then a.outDestId=a.jobId;a.outKind="work" end
		a.tripTargetId=if a.tripTargetHome then h.homeId else a.outDestId
		a.studyPos=CitizenActivityState.position(record[16])
		if record[14]~=0 and typeof(record[14])=="number" then a.studyId=record[14];a.wantsStudy=true end
	end
	for i,k in h.kids do
		local record=if typeof(row.ks)=="table" then row.ks[i] else nil
		if not CitizenActivityState.apply(k,record) then continue end
		_nextPersonId=math.max(_nextPersonId,k.pid)
		k.schoolPos=CitizenActivityState.position(record[16])
		local schoolId=tonumber(record[15])
		if schoolId and _educationService and _educationService.hasSchool(schoolId,k.age) then
			k.schoolId=schoolId
			if k.stage=="atSchool" and _educationService.enterSchool then _educationService.enterSchool(schoolId) end
		else k.stage="atHome";k.schoolPos=nil end
	end
end

function Pipe.resumeActivities(h: Household, row: any)
	for i,a in h.adults do
		local record=if typeof(row.rs)=="table" then row.rs[i] else nil
		if typeof(record)~="table" then continue end
		if a.stage=="atWork" and a.usingCar and not a.car then
			local p=door(a.jobId)
			if p then Cars.give(h,a,CFrame.new(p),true) end
		end
		-- NO WALK IS RESUMED ON LOAD (user decision 2026-10-05). Re-planning every walk that was in
		-- flight when the city was saved cost an A* search each: 17 s of a 5,000-person city's 30 s
		-- load. Whoever was out on foot or on transit starts again at home, and the activity
		-- scheduler sends them out again as the city runs. Drivers are restored as before.
		if a.stage=="transit" and not a.usingCar then
			a.stage="atHome";a.outKind=nil;a.outDestId=nil;a.tripTargetId=nil;a.tripTargetHome=false
		end
	end
	for i,k in h.kids do
		local record=if typeof(row.ks)=="table" then row.ks[i] else nil
		if record and k.stage=="transit" then k.stage="atHome" end
	end
end

local function restoreCompactHomes(data: any, bySaveKey: { [string]: any }): number
	local restored = 0
	local keys = data.keys
	local frameStart = os.clock()
	for _, row in data.homes do
		if os.clock() - frameStart > RESTORE_FRAME_BUDGET then
			task.wait()
			frameStart = os.clock()
		end
		if typeof(row) ~= "table" then continue end
		local homeKey = resolveSavedKey(keys, row.h)
		local homeView = if homeKey then bySaveKey[homeKey] else nil
		if not isResidentialHomeView(homeView) then continue end

		local adultCount = math.max(0, math.floor(tonumber(row.a) or 0))
		local kidCount = math.max(0, math.floor(tonumber(row.k) or 0))
		local total = math.min(adultCount + kidCount, FAMILY_MAX)
		if total <= 0 then continue end
		if adultCount > total then
			adultCount = total
			kidCount = 0
		else
			kidCount = math.min(kidCount, total - adultCount)
		end

		local h = makeRestoredHousehold(homeView.bpId, row.f)
		addRestoredPeople(h, adultCount, kidCount, row.e)
		h.goodsStock = HouseholdNeeds.restore(row.g, total)
		if typeof(row.rs)=="table" then Pipe.restoreActivities(h,row,keys,bySaveKey)
		else assignRestoredJobs(h, row.j, keys, bySaveKey) end
		finishRestoredHousehold(h, homeView)
		restoreCars(h, row)
		if typeof(row.cv) == "table" then
			for _, carState in row.cv do resumeRestoredCar(h, carState, keys, bySaveKey, homeView) end
		else
			resumeRestoredCar(h, row.v, keys, bySaveKey, homeView)
		end
		Pipe.resumeActivities(h,row)
		restored += 1
	end
	return restored
end

local function restoreBakedResidentHomes(bakedHomes: { any }, byId: { [string]: any }): number
	local restored = 0
	for _, row in bakedHomes do
		local homeView = byId[row.bpId]
		if not isResidentialHomeView(homeView) then continue end
		local total = math.min(math.max(0, math.floor(tonumber(row.residents) or 0)), FAMILY_MAX)
		if total <= 0 then continue end

		local adultCount = math.min(total, 2)
		local kidCount = total - adultCount
		local h = makeRestoredHousehold(homeView.bpId, _timeService.getDay())
		addRestoredPeople(h, adultCount, kidCount, nil)
		finishRestoredHousehold(h, homeView)
		restored += 1
	end
	return restored
end

-- Explicit staff reset: interrupt vehicle journeys without completing their destination.
function CitizenService.ResetVehicles(): number
	local cars: {[Model]: boolean} = {}
	for car in _trips do cars[car] = true end
	for car in _carDriveTokens do cars[car] = true end
	for _, e in Pipe.entries do cars[e.car] = true end
	for _, h in _households do
		local interruptedArrival = false
		for _, a in h.adults do
			if a.car then cars[a.car] = true end
			local interrupted = a.usingCar and a.stage == "transit"
			if interrupted then
				interruptedArrival = h.arriving == true
				a.tripId += 1
				if a.walkerId then _walkingService.despawnCommuter(a.walkerId); a.walkerId = nil end
				if a.riderId then _transitService.cancelRider(a.riderId); a.riderId = nil end
				a.stage = "atHome"
				a.outKind, a.outDestId = nil, nil
				a.tripTargetId, a.tripTargetHome = nil, false
				a.waitPos = nil
			end
			if a.car then
				local car = a.car
				Cars.drop(a)
				cars[car] = false
			end
		end
		if interruptedArrival then h.arriving = false end
	end
	local count = 0
	for car, remaining in cars do
		count += 1
		if remaining then destroyCar(car) end
	end
	table.clear(_trips)
	table.clear(_carDriveTokens)
	table.clear(Cars.roadTokens)
	table.clear(Pipe.entries)
	_carCount, _tripCount, _directedCount = 0, 0, 0
	return count
end

local function clearRuntimeHouseholds()
	Pipe.activityViews, Pipe.activityById = nil, nil
	Pipe.activityReset = true
	for _, h in _households do
		for _, a in h.adults do
			if a.walkerId then _walkingService.despawnCommuter(a.walkerId) end
			if a.riderId then _transitService.cancelRider(a.riderId) end
		end
		for _, kid in h.kids do
			if kid.walkerId then _walkingService.despawnCommuter(kid.walkerId) end
			if kid.stage == "atSchool" and _educationService and _educationService.leaveSchool then
				_educationService.leaveSchool(kid.schoolId)
			end
		end
	end
	for car in _trips do
		PathFollower.forget(car)
		if car.Parent then car:Destroy() end
	end
	table.clear(_trips)
	table.clear(_carDriveTokens)
	for _, child in _folder:GetChildren() do
		if child:IsA("Model") then
			PathFollower.forget(child)
			child:Destroy()
		end
	end
	Garage.clear()
	-- Free each household's reserved on-street spot before dropping them. removeHousehold
	-- does this per departure; the bulk clear must too, or reservations leak when the
	-- parking grid is not rebuilt under us.
	for _, h in _households do
		for _, a in h.adults do releaseSpot(a) end
	end
	table.clear(_households)
	table.clear(_stallTaken)
	table.clear(_travelDebugByPid)
	table.clear(_workers)
	_buildingService.clearHouseholds()
	table.clear(Pipe.entries)
	_tripCount = 0
	_directedCount = 0
	table.clear(Cars.roadTokens)
	_carCount = 0
	_population = 0
	if _educationService and _educationService.setPupilDemand then
		_educationService.setPupilDemand(0, 0)
	end
end

function CitizenService.restore(data: any)
	-- Clear FIRST, bail second. An absent citizens key means "this city has none" -- which is
	-- what a map template and an in-place city switch both send -- and returning early left
	-- the outgoing city's households, walkers and cars standing in the new one.
	_restoring = true
	clearRuntimeHouseholds()
	table.clear(_reconciledIds)
	recountPopulation()

	if typeof(data)=="table" and typeof(data.columns)=="table" then
		data=table.clone(data)
		data.homes=CitizenSaveColumns.fromColumns(data.columns)
	end
	local compact = typeof(data) == "table" and typeof(data.homes) == "table"
	if not compact and (typeof(data) ~= "table" or typeof(data.households) ~= "table") then
		_restoring = false
		return
	end

	local views = CitizenService._svcViews()
	local byId: { [string]: any } = {}
	local bySaveKey: { [string]: any } = {}
	local bakedHomes: { any } = {}
	for _, b in views do
		byId[b.bpId] = b
		local key = buildingSaveKey(b)
		if key then bySaveKey[key] = b end
		_reconciledIds[b.bpId] = true
		if b.zone == "Residential" then
			local bakedResidents = math.max(0, math.floor(tonumber(b.residents) or 0))
			if bakedResidents > 0 then
				table.insert(bakedHomes, { bpId = b.bpId, residents = bakedResidents })
			end
			for _ = 1, bakedResidents do
				_buildingService.removeResident(b.bpId)
			end
		end
	end

	_nextHouseholdId = math.max(0, math.floor(tonumber(data.nextHouseholdId) or 0))
	_nextPersonId = math.max(_nextPersonId, math.floor(tonumber(data.nextPersonId) or 0))

	if compact then
		local restoredCount = restoreCompactHomes(data, bySaveKey)
		if restoredCount == 0 and #bakedHomes > 0 then
			restoreBakedResidentHomes(bakedHomes, byId)
		end
		recountPopulation()
		_accum = 0
		_restoring = false
		return
	end

	local restoredCount = 0
	for _, row in data.households do
		if typeof(row) ~= "table" or typeof(row.homeId) ~= "string" then continue end
		local homeId = row.homeId :: string
		local home = byId[homeId]
		if not isResidentialHomeView(home) then continue end

		local id = math.floor(tonumber(row.id) or 0)
		if id <= 0 or _households[id] ~= nil then
			_nextHouseholdId += 1
			id = _nextHouseholdId
		end
		_nextHouseholdId = math.max(_nextHouseholdId, id)

		local h: Household = {
			id = id,
			homeId = homeId,
			adults = {},
			kids = {},
			foundedDay = math.max(1, math.floor(tonumber(row.foundedDay) or _timeService.getDay())),
			arriving = false,
			familyName = if typeof(row.familyName) == "string" then row.familyName else NameGen.familyName(_rng),
		}

		if typeof(row.adults) == "table" then
			for _, a in row.adults do
				if typeof(a) ~= "table" then continue end
				local savedJobId = if typeof(a.jobId) == "string" then a.jobId else nil
				local jobId = if savedJobId and isJobView(byId[savedJobId]) then savedJobId else nil
				-- Legacy saves predate gender/age: make the first two adults a couple and
				-- give every adult a plausible age so the family sim has something to grow.
				local gender = if a.gender == "M" or a.gender == "F" then a.gender
					elseif #h.adults == 0 then "M"
					elseif #h.adults == 1 then "F"
					elseif _rng:NextNumber() < 0.5 then "M" else "F"
				local atWork = a.atWork == true and jobId ~= nil
				local pid = nextPid()
				table.insert(h.adults, {
					name = if typeof(a.name) == "string" then a.name else NameGen.firstName(_rng, gender),
					gender = gender,
					age = math.max(AGE_ADULT, math.floor(tonumber(a.age) or _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE))),
					pid = pid,
					ownsCar = TravelModeChoice.ownsCar(pid),
					jobId = jobId,
					joblessDays = math.max(0, math.floor(tonumber(a.joblessDays) or 0)), eduLevel = math.clamp(math.floor(tonumber(a.eduLevel) or 0), 0, 3),
					stage = if atWork then "atWork" else "atHome",
					-- Not saved: re-decided the way a new graduate decides (Trips.student).
					wantsStudy = jobId == nil and (tonumber(a.eduLevel) or 0) == 2 and (tonumber(a.age) or 99) <= Trips.UNI_MAX_AGE
						and Trips.roll(pid, 3) < Trips.COLLEGE_SHARE,
					tripId = 0, walkerId = nil,
					outKind = if atWork then "work" else nil,
					outDestId = if atWork then jobId else nil,
					usingCar = false,
					tripTargetId = nil, tripTargetHome = false,
					commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
				})
				if jobId then _workers[jobId] = (_workers[jobId] or 0) + 1 end
			end
		end
		if #h.adults == 0 then
			table.insert(h.adults, makeAdult("M", _rng:NextInteger(PARENT_MIN_AGE, PARENT_MAX_AGE)))
		end

		-- Children. New saves store per-kid records; legacy saves stored a bare count.
		if typeof(row.kids) == "table" then
			for _, k in row.kids do
				if typeof(k) ~= "table" then continue end
				local gender = if k.gender == "M" or k.gender == "F" then k.gender
					elseif _rng:NextNumber() < 0.5 then "M" else "F"
				table.insert(h.kids, {
					name = if typeof(k.name) == "string" then k.name else NameGen.firstName(_rng, gender),
					gender = gender,
					age = math.clamp(math.floor(tonumber(k.age) or _rng:NextInteger(KID_ARRIVE_MIN_AGE, KID_ARRIVE_MAX_AGE)), 0, AGE_ADULT - 1),
					pid = nextPid(),
					stage = "atHome", tripId = 0, walkerId = nil, schoolPos = nil,
					schoolId = if typeof(k.schoolId) == "number" then math.floor(k.schoolId) else nil, bestTier = math.clamp(math.floor(tonumber(k.bestTier) or 0), 0, 2),
					commutedSchoolDay = 0, commutedHomeDay = 0,
				})
			end
		elseif typeof(row.kids) == "number" then
			for _ = 1, math.clamp(math.floor(row.kids), 0, MAX_KIDS) do
				table.insert(h.kids, makeKid())
			end
		end

		for _, a in h.adults do
			if a.ownsCar then Cars.give(h, a, dataToCFrame(row.car)); break end
		end

		_households[id] = h
		restoredCount += 1
		_buildingService.addHousehold(homeId)
		_buildingService.setFamilyName(homeId, h.familyName)
		for _ = 1, #h.adults + #h.kids do
			if _buildingService.canAcceptResident(homeId) then
				_buildingService.addResident(homeId)
			end
		end
	end

	if restoredCount == 0 and #bakedHomes > 0 then
		restoreBakedResidentHomes(bakedHomes, byId)
	end

	recountPopulation()
	-- A restore replaces the whole population: drop the cached education histogram and
	-- invalidate the pid index so nothing serves numbers from the pre-load city.
	LOD.eduFresh = false
	LOD.pidGen += 1
	_accum = 0
	_restoring = false
end

-- == Lifecycle =================================================================
function CitizenService.Init(roadService: any, buildingService: any, cityStatsService: any, timeService: any, parkingService: any, walkingService: any, economyService: any, supplyService: any, educationService: any?)
	assert(roadService and buildingService and cityStatsService and timeService and parkingService and walkingService and economyService and supplyService, "[CitizenService] missing dependency")
	_roadService = roadService
	_buildingService = buildingService
	_cityStatsService = cityStatsService
	_timeService = timeService
	_parkingService = parkingService
	if parkingService.onSpotsChanged then parkingService.onSpotsChanged(function() Cars.reparkLost() end) end
	_walkingService = walkingService
	_economyService = economyService
	_supplyService = supplyService
	_educationService = educationService
	_folder = ensureFolder()
end

-- Family roster for the building info panel: the resident household's surname plus
-- every member (adults first, oldest first, then children) with gender + age. Single-
-- family, so at most one household per home. Returns nil for a vacant/non-home lot.
local queries = CitizenQueries.new({
	getHouseholds = function() return _households end,
	getBuildingService = function() return _buildingService end,
	getWalkingService = function() return _walkingService end,
	getTimeService = function() return _timeService end,
	findPerson = findPerson, homeFocusPosition = homeFocusPosition,
	personLabel = personLabel, kidLabel = kidLabel, door = door,
	travelDecision = function(pid: number) return _travelDebugByPid[pid] end,
	presenceFrontCos = PRESENCE_FRONT_COS,
})
CitizenService.getFamilyInfo = queries.getFamilyInfo
CitizenService.getWorkforceInfo = queries.getWorkforceInfo
function CitizenService.getWorkerCount(workplaceId: string): number
	return _workers[workplaceId] or 0
end
CitizenService.getAdminPersonDebug = queries.getAdminPersonDebug
CitizenService.getPersonWhereabouts = queries.getPersonWhereabouts
CitizenService.getPresenceNear = queries.getPresenceNear

function CitizenService.Bind()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	NetMiddleware.RegisterServerRateLimit(Net.RequestFamilyInfo, FAMILY_INFO_MIN_DT)
	Net.RequestFamilyInfo.OnServerInvoke = function(player: Player, bpId: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestFamilyInfo, player) then return nil end
		if typeof(bpId) ~= "string" then return nil end
		return CitizenService.getFamilyInfo(bpId)
	end

	NetMiddleware.RegisterServerRateLimit(Net.RequestWorkforceInfo, FAMILY_INFO_MIN_DT)
	Net.RequestWorkforceInfo.OnServerInvoke = function(player: Player, bpId: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestWorkforceInfo, player) then return nil end
		if typeof(bpId) ~= "string" then return nil end
		return CitizenService.getWorkforceInfo(bpId)
	end

	NetMiddleware.RegisterServerRateLimit(Net.RequestCitizenPos, FAMILY_INFO_MIN_DT)
	Net.RequestCitizenPos.OnServerInvoke = function(player: Player, pid: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestCitizenPos, player) then return nil end
		if typeof(pid) ~= "number" then return nil end
		return CitizenService.getPersonWhereabouts(pid)
	end

	NetMiddleware.RegisterServerRateLimit(Net.RequestPresenceNear, 0.5)
	Net.RequestPresenceNear.OnServerInvoke = function(player: Player, camCF: any): any
		if not NetMiddleware.CheckServerRate(Net.RequestPresenceNear, player) then return nil end
		if typeof(camCF) ~= "CFrame" then return nil end
		return CitizenService.getPresenceNear(camCF, PRESENCE_RADIUS, PRESENCE_CAP)
	end
end

function CitizenService.Start()
	if _running then return end
	_running = true
	-- One service-owned worker; routing batches yield independently of movement.
	Pipe.activityThread = task.spawn(function()
		while _running do
			if Pipe.activityReset then
				table.clear(LOD.order)
				table.clear(LOD.activityAt)
				LOD.cursor, LOD.sweepSteps, LOD.lastSweepSteps = 1, 0, 0
				LOD.sweepStartedAt, LOD.lastSweepGameSeconds = nil, 0
				Pipe.activityReset = false
			end
			if not _restoring and gameSpeed() > 0 and Pipe.activityViews and Pipe.activityById then
				local ok, err = xpcall(doActivities, debug.traceback, Pipe.activityViews, Pipe.activityById)
				if not ok then warn("[CitizenService] activity batch failed: " .. tostring(err)) end
			end
			task.wait(LOD.CONFIG.INTERVAL)
		end
	end)
	local tripAccum = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		tripAccum += math.min(dt, 0.1)
		if tripAccum < TRIP_TICK then return end
		local simDt = math.min(tripAccum, 0.1) * gameSpeed()
		tripAccum = 0

		local ok, err = pcall(stepTrips, simDt)
		if not ok then warn("[CitizenService] trip step failed: " .. tostring(err)) end
		_accum += simDt
		if _accum >= SIM_STEP then
			_accum -= SIM_STEP
			local ok2, err2 = pcall(simStep)
			if not ok2 then warn("[CitizenService] sim step failed: " .. tostring(err2)) end
		end
	end)
end

return CitizenService
