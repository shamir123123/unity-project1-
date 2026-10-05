--!strict
local GameSpeed = require(game:GetService("ReplicatedStorage").GameSpeed)
-- NPCDriverService
-- Spawns NPC cars and drives them along the nav graph.
-- Dead ends: NPCs stop, wait briefly, then U-turn back.
-- Normal edges: NPCs follow outgoing connections and roam indefinitely.
-- Replication, smoothing, proximity culling, and edge geometry live in the
-- shared PathFollower module.

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local NetMiddleware     = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local RoadConstants     = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog   = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadRules         = require(ReplicatedStorage.Road.RoadRules)
local BezierUtil        = require(ReplicatedStorage.Road.BezierUtil)
local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer)
local PathFollower      = require(ServerScriptService.Services.Util.PathFollower)
local TrafficSignalService = require(ServerScriptService.Services.Traffic.TrafficSignalService)
local TrafficConfig     = require(ServerScriptService.Services.Traffic.TrafficConfig)
local VehicleTypes      = require(ReplicatedStorage.Road.VehicleTypes)
local VehicleFactory    = require(ServerScriptService.Services.NPC.VehicleFactory)
local DriverProfile     = require(ReplicatedStorage.Road.DriverProfile)

local NPCDriverService = {}

-- == Config ====================================================================
local TAG            = "NPCDriver"
-- Ambient traffic keeps the world moving while the household sim ramps up.
-- Set Workspace.AmbientTrafficCount to tune it, or set RandomTrafficEnabled=false
-- to disable the background cruisers entirely.
-- Half-size world (RoadConstants.WORLD_SCALE): speeds, accels and stud distances below
-- scale together, so traffic covers the same city blocks per second as at full size.
local WS = RoadConstants.WORLD_SCALE
-- The turn that cuts the oncoming carriageway, and so has to accept a gap unless it holds
-- a protected phase. "left" on a right-hand-drive map, "right" on a left-hand one.
-- Yielding is written against this rather than a literal so the rules hold whichever side
-- the player picked. A FUNCTION, not a cached string: the side can change at runtime, and
-- this service is long-lived, so a module-level copy would go stale the moment it did.
local function crossingTurn(): string
	return RoadRules.getCrossingTurn()
end
local Tuning: any = {} -- packed constants: this module sits at Luau's 200-local limit
Tuning.NPC_COUNT = 12
Tuning.MAX_AMBIENT_TRAFFIC = 32
Tuning.DEAD_END_WAIT = 0
Tuning.MAX_STEPS = 8
Tuning.MAX_SIM_DT = 0.1
Tuning.DRIVER_MAX_STEP = 0.3
Tuning.DRIVER_TICK = 1 / 20 -- nearby server AI rate
-- Simulation level of detail. A car further than FAR_LOD_DIST from every player's camera
-- (and its ground look-at point) still drives the full traffic AI -- queues, signals, lane
-- changes, jams all real -- but thinks FAR_TICK times less often; nobody is close enough to
-- see the steps, and the client draws only a sample out there (PathFollower / NPCDriverView).
local FAR_LOD_DIST     = 1000   -- studs (500 m)
Tuning.FAR_LOD_DIST_SQ = FAR_LOD_DIST * FAR_LOD_DIST
local FAR_TICK         = 1 / 4  -- s between far-car updates
Tuning.FAR_MAX_DT = 0.3    -- longest step a far car integrates in one go
Tuning.LOD_RECHECK = 1      -- s between a car's near/far re-evaluations
-- Past every viewer's pose stream (PathFollower.STREAM_REACH) a car is seen by nobody at all:
-- it thinks twice a second. Big steps are safe -- every move is clamped to the gap to the car
-- ahead, the clearance in front and the stop line, and a step that would cross a line asks
-- for right of way first -- so a distant queue, signal or jam still runs for real, just
-- coarser. With thousands of cars most of them are here, and this is what they cost. The
-- price: a queued car only sees its leader pull away on its own next step, so every place in
-- a queue starts up to one step late -- measured, a junction nobody can see lets through
-- about a fifth fewer cars at 2 Hz (a third fewer at 1 Hz, which is why it is not slower).
Tuning.DISTANT_LOD_DIST_SQ = PathFollower.STREAM_REACH * PathFollower.STREAM_REACH
-- Between the full-rate stream band (PathFollower.FULL_RATE_DIST) and FAR_LOD_DIST a viewer
-- is sent a car's pose 4 times a second at most, so thinking 20 times a second there bought
-- nothing anyone sees: 10 Hz, still well above what the stream shows.
Tuning.NEAR_LOD_DIST_SQ = PathFollower.FULL_RATE_DIST * PathFollower.FULL_RATE_DIST
local MID_TICK         = 0.1
Tuning.MID_MAX_DT = 0.15
local DISTANT_TICK     = 0.5    -- s between distant-car updates
Tuning.DISTANT_MAX_DT = 0.5    -- longest step a distant car integrates in one go
-- No cap on how many far cars one tick may update: a cap that binds leaves the cars it
-- defers standing wherever they are -- inside junction boxes too -- and the cross traffic
-- piles up behind them (measured at 3000 cars: ~30% more cars stopped, about half the trips done).
-- The load is spread by the random first phase below instead.
Tuning.SWEEP_EVERY_TICKS = 5 -- destroyed-car sweep (see the tick loop)
Tuning.STOP_DECEL_DISTANCE = 5 * WS
local STOP_LINE_CAR_BUFFER = 3 * WS
local FOLLOW_MIN_GAP    = 16 * WS   -- centre-to-centre FLOOR (~one car length); followGap sizes the rest
local FOLLOW_BUMPER     = 2 * WS    -- clear air left between two stopped vehicles' bumpers
Tuning.FOLLOW_LOOKAHEAD = 42 * WS
local QUEUE_TIE_EPSILON = 0.05
Tuning.UNSTUCK_BACKUP_RATE = 18 * WS
Tuning.ACCEL_RATE = 28 * WS
Tuning.BRAKE_RATE = 60 * WS
-- Traffic is never cleared by a timer. A queue, a full exit, a red or a gridlocked box holds
-- every car in it until the road clears -- or until the player rebuilds the road. Only a
-- car the traffic rules cannot explain (see waitingInTraffic) counts as bugged, and only a
-- bugged car is pushed through or removed.
-- A car further than this from its stop line is not asked for right of way yet: whichever
-- is longer, a fixed distance or this many seconds at its current speed.
Tuning.JUNCTION_LOOKAHEAD_MIN = 12 -- studs
Tuning.JUNCTION_LOOKAHEAD_TIME = 1.5 -- s, the same horizon the yellow-light commit uses
Tuning.EXIT_QUEUE_STOPPED_SPEED = 0.5
Tuning.EXIT_STOPPED_SPEED = 4 -- studs/s (~7 km/h): a car on an exit slower than this is where its queue ends (stop-and-go counts)
local AT_LINE_DIST      = 2    -- studs short of its stop line a car counts as waiting at it
-- Turn-taking at junctions WITHOUT signals: how long a car waits at its line before it may
-- take its turn (and approaching cross traffic lets it in). Roads of equal priority take turns
-- like an all-way stop; a side road meeting a main road waits longer, but always gets in.
Tuning.TURN_WAIT_EQUAL = 1
Tuning.TURN_WAIT_MINOR = 3
-- Gridlock: a car at its line whose exit has stayed full this long takes another exit with
-- room and re-plans from there, like a driver who gives up on a blocked street. A circle of
-- full streets (each head waiting on the next) always has a car that can turn away.
Tuning.EXIT_DETOUR_TIME = 12
Tuning.EXIT_DETOUR_RETRY = 10
-- A car waiting to pull out of (or turn into) a driveway asks the lanes it crosses to leave
-- it a gap; the request lapses unless its gate keeps asking (see RequestRoadGap).
Tuning.GAP_REQUEST_TTL = 3
Tuning.GAP_REQUEST_ROOM = 2 -- studs of clear air the yielding car leaves beyond the merge
Tuning.CONNECTOR_STANDOFF_ESCAPE = 4  -- s two cars blocking EACH OTHER wait before one of them creeps through
Tuning.RESCUE_CLEAR_DIST = 30 * WS    -- studs a rescued (bugged) car must cover before it obeys traffic again
Tuning.STANDOFF_CHAIN_HOPS = 6         -- cars followed round a box lock looking for a cycle (inMutualStandoff)
local TURN_SLOW_ZONE    = 20 * WS   -- studs before the stop line over which cars ease down to turn entry speed
Tuning.CONNECTOR_LAT_ACCEL = 14 * WS -- studs/s^2 comfortable lateral accel through a turn
Tuning.MIN_TURN_SPEED = 6 * WS    -- studs/s floor so tight U-turns never crawl to a stop
Tuning.TURN_ENTRY_SPEED = table.freeze({ left = 12 * WS, right = 10 * WS, uturn = 7 * WS })
local STALL_RESCUE_TIME  = 60   -- s of zero movement before the watchdog re-seats a car (legit waits are bounded far below)
Tuning.STALL_MOVE_EPSILON = 0.25 * WS -- studs of movement that count as progress for the watchdog
Tuning.ROUNDABOUT_YIELD_DIST = RoadConstants.ROUNDABOUT_YIELD_DIST or 30 * WS -- studs a circulating car blocks an entry
Tuning.ADMIN_TEST_CAR_MAX_COUNT = 80
Tuning.ADMIN_TEST_CAR_DEFAULT_COUNT = 12
Tuning.ADMIN_TEST_CAR_DEFAULT_RADIUS = 260 * WS
Tuning.TEST_SPAWN_FRACTIONS = table.freeze({ 0.18, 0.42, 0.66, 0.86 })
Tuning.CONGESTION_UPDATE_INTERVAL = RoadConstants.NAV_CONGESTION_UPDATE_INTERVAL or 0.75
Tuning.CONGESTION_SMOOTHING = RoadConstants.NAV_CONGESTION_SMOOTHING or 0.35
Tuning.CONGESTION_JAM_SPEED_RATIO = RoadConstants.NAV_CONGESTION_JAM_SPEED_RATIO or 0.35
Tuning.CONGESTION_MIN_QUEUE = RoadConstants.NAV_CONGESTION_MIN_QUEUE or 3
Tuning.TRAFFIC_REROUTE_JAM_TIME = RoadConstants.NAV_REROUTE_JAM_TIME or 7
local TRAFFIC_REROUTE_COOLDOWN = RoadConstants.NAV_REROUTE_COOLDOWN or 30
-- Traffic-reroute searches the whole fleet may run: RATE per sim second, at most BURST
-- saved up, so never more than one search in a single driver tick.
local RerouteBudget = { RATE = 3, BURST = 1, tokens = 1 }
Tuning.TRAFFIC_REROUTE_MIN_IMPROVEMENT = RoadConstants.NAV_REROUTE_MIN_IMPROVEMENT or 0.3
Tuning.TRAFFIC_REROUTE_MAX_PER_TRIP = RoadConstants.NAV_REROUTE_MAX_PER_TRIP or 2
Tuning.TRAFFIC_REROUTE_REVERSAL_LOCK = RoadConstants.NAV_REROUTE_REVERSAL_LOCK or 60
Tuning.LANE_MOVE_MIN_SAVING = 3 -- s a same-roads plan on another lane must save, beyond the move itself
Tuning.ROAMER_LANE_KEEP = 2.5   -- extra cars an ambient roamer accepts in its own lane before moving over at a junction

-- Camera-pos rate limiting is handled entirely by NetMiddleware.RegisterServerRateLimit.
Tuning.CAM_REPORT_MIN_DT = 1 / 15  -- 15 Hz max, passed to NetMiddleware

-- == State =====================================================================
local _roadService: any = nil
local _heartbeat: RBXScriptConnection? = nil
local _spawnedOnce = false
local _bound = false

local _nodeMetaById: { [number]: any } = {}
local _edgeDriverIndex: { [string]: { any } } = {}
local _connectorByNextEdgeIndex: { [string]: { any } } = {}
-- Lane-change occupants by lane: cars mid-move (under BOTH lanes) and cars waiting to merge
-- (under the lane they want). Rebuilt with the other indexes every tick.
local _laneChangeIndex: { [string]: { any } } = {}
-- Cars crossing a junction (or a join), by the lane they left: see getNearestQueueLeader.
local _connectorByFromEdgeIndex: { [string]: { any } } = {}
-- Gridlock breakers (one table: register limit). gapLanes[laneId][vehicle] = the lane
-- distance a driveway car asked that lane to keep clear; gapReqs[vehicle] = its request;
-- crossAsker[segmentId] = the one car asking that road to let it cross every lane.
local Gridlock: any = { gapLanes = {}, gapReqs = {}, crossAsker = {} }
-- Cars on a connector, by the node their landing lane starts at and by the node the lane
-- they left ends at. The right-of-way checks ask "who is crossing THIS junction"; they used
-- to walk every driver in the city for it, per waiting car, per tick -- quadratic in the
-- fleet, and most of the server's traffic cost in a big city. A car that starts a connector
-- mid-tick is added at once (startConnector), because two cars entering one box in the same
-- tick must see each other; entries left stale by a car landing mid-tick are filtered out by
-- the live checks each caller already makes.
local EMPTY = table.freeze({})
local _connByLandingNode: { [number]: { any } } = {}
local _connByLeavingNode: { [number]: { any } } = {}
local _edgeCongestion: { [string]: number } = {}
local _lastCongestionUpdate = 0

-- == Types =====================================================================
-- A mid-block lane change in progress: its ribbon, both lanes, and where on them it starts/lands.
type LaneChange = { pts: { Vector3 }, from: string, to: string, d0: number, d1: number }

type DriverState = PathFollower.FollowerState & {
	ix:            any?, -- where this car is filed in the lane indexes (see reindexDriver)
	edgeId:        string,
	edgeDist:      number,
	graphVersion: number,
	connector:    { Vector3 }?,
	connCum:      { number }?,
	connDist:     number,
	nextEdgeId:   string?,
	nextEdgeDist: number,
	pendingNextEdgeId: string?,
	atDeadEnd:    boolean,
	deadEndTimer: number,
	speed:        number,
	currentSpeed: number?, -- Keeps track of smoothed speed for fluid acceleration/deceleration
	vehicleClass: VehicleTypes.VehicleClass,
	blockedTime:  number?, -- seconds spent yielding at the current junction (drives impatience)
	waitSince:    number?, -- _simClock when this wait at the line began (orders turns at the junction)
	stuckTime:    number?, -- seconds stopped at a junction for ANY reason (jam readouts)
	redTime:      number?, -- seconds of the current unbroken red (drives SIGNAL_FAULT_TIME)
	connSpeedCap: number?, -- max speed through the current connector (set from its tightest bend)
	connBlockedTime: number?, -- seconds wedged in a standoff (drives the push-through escape)
	blockedBy:    Model?,  -- the car right in front with no room left to it (nil when clear)
	rescueFrom:   Vector3?, -- set by the stall watchdog: a bugged car pushes through until it has left here
	lastProgressPos: Vector3?, -- watchdog: where the car last made real progress
	noProgressTime: number?,   -- watchdog: seconds without real movement
	rescueCount: number?,      -- watchdog: consecutive rescues without progress between them
	stopReason: string?,       -- debug: WHY the car is at its current speed (in-memory; read by GetSpeedDebug, never replicated)
	debugTagAdded: boolean?,   -- directed trips temporarily opt into NPCDriver client/debug tracking
	-- Directed-trip mode (nil on ambient roamers): follow a fixed edge route to a
	-- destination, then stop and hand back instead of roaming forever.
	route:        { string }?,  -- ordered lane-edge ids (FindPath's 2nd return)
	routeIndex:   number?,      -- index in `route` of the current edgeId
	goalPos:      Vector3?,     -- trip destination, kept so a directed car can re-route if its road is replaced
	finalDist:    number?,      -- distance along the LAST route edge to stop at (the lot entry)
	onArrive:     (() -> ())?,  -- fired once on reaching the destination
	onAbort:      (() -> ())?,  -- fired if the route can't be followed (road changed / wedged)
	arrived:      boolean?,     -- latch so onArrive fires exactly once
	halfLength:   number?,      -- vehicle half-length (centre->nose) for stop-line placement
	trafficJamTime: number?,    -- sustained queue time before considering a new route
	nextTrafficRerouteAt: number?, -- os.clock cooldown; prevents route oscillation
	trafficReroutes: number?,   -- debug counter
	lastTrafficRerouteAt: number?,
	lastTrafficAbandonedNextEdgeId: string?, -- blocks an immediate flip back to the old branch
	-- This driver's own mind (DriverProfile): how it prices roads, how fast it likes to
	-- go, how long it tolerates a queue. Stable for the vehicle's whole life, so a car
	-- does not change personality mid-trip. Carries a per-trip booking token.
	profile:      DriverProfile.Profile?,
	bookingToken: number?,      -- identifies this trip's route reservation on the graph
	laneChangeWait: number?,    -- seconds held at the end of a lane-change window with no gap
	laneChangeMissed: string?,  -- lane edge whose window this car overran at speed and re-planned from
	lodFar: boolean?,           -- far from every player: thinks at FAR_TICK (see FAR_LOD_DIST)
	lodDistant: boolean?,       -- past every viewer's pose stream: thinks at DISTANT_TICK
	lodMid: boolean?,           -- inside FAR_LOD_DIST but past the full-rate stream band: MID_TICK
	lodAccum: number?,          -- sim time banked since this car last thought
	lodCheckAt: number?,        -- os.clock of the next near/far re-evaluation
	blockerDot: number?,        -- heading agreement with whatever blocks us (1 = queued behind it)
	laneChange: LaneChange?,    -- the move in progress; only valid while `connector` is its ribbon
	mergeInto: string?,         -- lane this car has waited LaneChange.MERGE_COURTESY_WAIT+ to move into (zipper)
	mergeHoldAt: number?,       -- swap tie-break winner: hold point pulled up past the other car
	nextLaneLook: number?,      -- _simClock of this car's next lane-discipline look (highways)
	laneDisciplineMoves: number?, -- debug: overtakes and returns taken
	heldUpSince: number?,       -- _simClock since a slower car ahead has been holding this one up
	laneMoveKinds: { [string]: number }?, -- debug: discipline moves by kind (yield / pass / back)
	exitWait: number?,          -- s at the line with a full exit (drives Gridlock.detour)
	nextDetourAt: number?,      -- _simClock of this car's next detour look
}

-- Route bookings are keyed by an integer that must be unique across LIVE trips, so a
-- released token is never reused by an overlapping one.
local _nextBookingToken = 0

-- Drivers not yet placed in PathFollower's spatial grid (see IsPointClear).
local _unseated: { [Model]: any } = setmetatable({}, { __mode = "k" }) :: any

-- MEMORY LEAK FIX: We make _drivers a WEAK-KEYED table so that when an NPC model is 
-- destroyed, its driver state is auto-garbage-collected, preventing a slow memory leak.
local _drivers: { [Model]: DriverState } = setmetatable({}, { __mode = "k" }) :: any
-- Cars that joined the pool since the last tick, filed into the lane indexes at its start.
local _joined: { any } = {}
-- Simulated seconds since the service started (advances once per driver tick, times game speed).
local _simClock = 0
local _nextDebugId = 0

local function ensureDebugId(model: Model): string
	local existing = model:GetAttribute("NPCDebugId")
	if typeof(existing) == "string" and existing ~= "" then
		return existing
	end
	_nextDebugId += 1
	local id = string.format("%s#%d", model.Name, _nextDebugId)
	model:SetAttribute("NPCDebugId", id)
	return id
end

-- Who goes first when two cars are exactly level. Model names are not unique (every through
-- car is an "IntercityCar"), so a name tie-break let neither go; the debug id is unique.
local function goesFirst(a: DriverState, b: DriverState): boolean
	return ensureDebugId(a.model) < ensureDebugId(b.model)
end

local function clearDirectedDebugTag(state: DriverState)
	local model = state.model
	if state.debugTagAdded and model and model.Parent and CollectionService:HasTag(model, TAG) then
		CollectionService:RemoveTag(model, TAG)
	end
	state.debugTagAdded = nil
	if model and model.Parent then
		model:SetAttribute("NPCStatus", nil)
		model:SetAttribute("NPCDestX", nil)
		model:SetAttribute("NPCDestZ", nil)
	end
end

-- Version of the nav graph that was current when we last flushed the cum cache.
-- Used to ensure flushCache() fires exactly once per rebuild, not once per NPC.
local _lastFlushedVersion = -1

-- == Helpers ===================================================================
local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

-- Tags the car model with its current routing info so clients can read it.
-- Avoids redundant attribute updates to save network traffic.
local function tagCarInfo(state: DriverState, status: string, targetEdgeId: string?)
	local model = state.model
	if not model or not model.Parent then return end
	ensureDebugId(model)
	-- These attributes replicate to every client regardless of distance, so skip
	-- them for cars no player can see -- cuts bandwidth as the city grows.
	if not PathFollower.isInRange(model) then return end

	if model:GetAttribute("NPCStatus") ~= status then
		model:SetAttribute("NPCStatus", status)
	end

	if targetEdgeId then
		local g = nav()
		if g then
			local edge = g:GetEdge(targetEdgeId)
			if edge and edge.points and #edge.points > 0 then
				local ep = edge.points[#edge.points]
				local destX = math.round(ep.X)
				local destZ = math.round(ep.Z)
				if model:GetAttribute("NPCDestX") ~= destX then
					model:SetAttribute("NPCDestX", destX)
				end
				if model:GetAttribute("NPCDestZ") ~= destZ then
					model:SetAttribute("NPCDestZ", destZ)
				end
			end
		end
	else
		if model:GetAttribute("NPCDestX") ~= nil then
			model:SetAttribute("NPCDestX", nil)
		end
		if model:GetAttribute("NPCDestZ") ~= nil then
			model:SetAttribute("NPCDestZ", nil)
		end
	end
end

local function getStatePosition(state: DriverState): Vector3
	return if state.smoothCFrame then state.smoothCFrame.Position else state.model:GetPivot().Position
end

-- A car mid lane change straddles both lanes: still in the way on the one it is leaving,
-- already in the way on the one it is joining. Its distance along either lane is how far
-- through the move it is (the lanes of one road share a distance scale).
local function laneChangeOf(state: DriverState): LaneChange?
	local lc = state.laneChange
	if lc and state.connector == lc.pts then return lc end
	return nil
end

-- Where `state` stands along `laneId`: its own distance on its lane; mid lane change, how
-- far through the move it is (it straddles both lanes); on a connector INTO `laneId` (a
-- junction turn or a join between road pieces) the landing distance less what is left of the
-- connector -- negative while still short of the lane, so a queue carries straight across.
local function lanePos(state: DriverState, laneId: string): number
	if not state.connector then return state.edgeDist end
	local cum = state.connCum
	local total = if cum then cum[#cum] else 0
	local lc = laneChangeOf(state)
	if lc then
		local f = if total > 0 then math.clamp(state.connDist / total, 0, 1) else 1
		return lc.d0 + (lc.d1 - lc.d0) * f
	end
	if state.nextEdgeId == laneId then
		return state.nextEdgeDist - math.max(0, total - state.connDist)
	end
	return state.edgeDist
end

-- Centre-to-centre spacing this car has to keep behind `lead`. FOLLOW_MIN_GAP on its own is
-- one CAR length, so a queue holding anything longer -- a box truck, an artic -- packed its
-- followers into the trailer. Both half-lengths plus a bumper is the real minimum.
local function followGap(state: DriverState, lead: DriverState?): number
	if not lead then return FOLLOW_MIN_GAP end
	return math.max(FOLLOW_MIN_GAP, (state.halfLength or 0) + (lead.halfLength or 0) + FOLLOW_BUMPER)
end

-- Buckets are emptied in place and reused: rebuilt every tick, fresh tables for every lane
-- were most of the traffic sim's garbage. A graph rebuild drops them all (edge ids change).
local _indexGraphVersion = -1
local ALL_INDEXES = { _edgeDriverIndex, _connectorByNextEdgeIndex, _laneChangeIndex, _connectorByFromEdgeIndex,
	_connByLandingNode, _connByLeavingNode }

local function clearDriverIndexes(graphVersion: number)
	local drop = graphVersion ~= _indexGraphVersion
	_indexGraphVersion = graphVersion
	for _, index in ALL_INDEXES do
		if drop then
			table.clear(index)
		else
			for _, bucket in index :: { [any]: { any } } do table.clear(bucket) end
		end
	end
end

local function addToIndex(index: { [any]: { any } }, key: any, state: DriverState)
	local bucket = index[key]
	if not bucket then
		bucket = {}
		index[key] = bucket
	end
	if index == _edgeDriverIndex then
		local lo, hi = 1, #bucket + 1
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if bucket[mid].edgeDist < state.edgeDist then lo = mid + 1 else hi = mid end
		end
		table.insert(bucket, lo, state)
	else
		table.insert(bucket, state)
	end
end

-- The lane indexes are kept up to date car by car instead of being rebuilt from every car
-- every tick. A car's filing only changes when the car itself moves on -- onto a connector,
-- a new lane, a lane change -- and that only happens in its own update, so it is re-filed
-- right after that update (and when it joins or leaves the pool). A far car thinking at 4 Hz
-- now costs the index nothing on the ticks it sits out; the full rebuild, every car on
-- every tick, was the largest cost that grew with the car count and ignored the LOD.
local function unindexDriver(state: DriverState)
	local ix = state.ix
	if not ix then return end
	state.ix = nil
	if ix.v ~= _indexGraphVersion then return end -- the indexes were dropped since
	local list = ix.list
	for i = 1, #list, 2 do
		local bucket = list[i][list[i + 1]]
		if bucket then
			local at = table.find(bucket, state)
			if at then table.remove(bucket, at) end
		end
	end
end

local function reindexDriver(state: DriverState)
	local conn = state.connector ~= nil and state.nextEdgeId ~= nil
	local lc = if conn then laneChangeOf(state) else nil
	local lcFrom = if lc then lc.from else nil
	local lcTo = if lc then lc.to else nil
	local nextId = if conn then state.nextEdgeId else nil
	local merge = if conn then nil else state.mergeInto
	local ix = state.ix
	if ix and ix.v == _indexGraphVersion and ix.conn == conn and ix.e == state.edgeId and ix.n == nextId
		and ix.f == lcFrom and ix.t == lcTo and ix.m == merge then
		return
	end
	unindexDriver(state)
	if not state.model.Parent then return end
	local list = {}
	local function add(index: { [any]: { any } }, key: any)
		if key == nil then return end
		addToIndex(index, key, state)
		list[#list + 1] = index
		list[#list + 1] = key
	end
	if conn then
		add(_connectorByNextEdgeIndex, nextId)
		local g = nav()
		if g then
			local nextEdge = g:GetEdge(nextId)
			if nextEdge then add(_connByLandingNode, nextEdge.fromNode) end
			local fromEdge = g:GetEdge(state.edgeId)
			if fromEdge then add(_connByLeavingNode, fromEdge.toNode) end
		end
		if lc then
			add(_laneChangeIndex, lcFrom)
			add(_laneChangeIndex, lcTo)
		else
			add(_connectorByFromEdgeIndex, state.edgeId)
		end
	else
		add(_edgeDriverIndex, state.edgeId)
		add(_laneChangeIndex, merge)
	end
	state.ix = { v = _indexGraphVersion, conn = conn, e = state.edgeId, n = nextId, f = lcFrom, t = lcTo, m = merge, list = list }
end

-- Full rebuild: only when the road graph changed (edge ids may have), and at start-up.
local function rebuildDriverIndexes()
	local g = nav()
	clearDriverIndexes(if g then g:Version() else -1)
	for _, other in pairs(_drivers) do
		other.ix = nil
		reindexDriver(other)
	end
end

local function edgeHasOutgoing(edge: any, targetEdgeId: string): boolean
	for _, outId in ipairs(edge.out) do
		if outId == targetEdgeId then
			return true
		end
	end
	return false
end

-- The lane edge carries its speed limit (studs/s), baked at graph-build time from
-- the segment's road type + any per-segment override. Fallback covers a stale
-- edge from before the field existed.
local function edgeSpeed(edge: any): number
	return edge.speedLimit or 56
end

-- Cruise speed for THIS driver on this lane. Personas sit either side of the posted
-- limit, so traffic is never a column of identically-paced cars: a slow driver ahead
-- is a real reason for the one behind to bunch up, and that bunching is what feeds
-- the congestion signal the router reacts to.
local function driverSpeed(edge: any, state: DriverState): number
	local limit = edgeSpeed(edge)
	local profile = state.profile
	return if profile then limit * profile.speedFactor else limit
end

-- Publish a sparse, smoothed pressure map to the nav graph. This reuses the
-- per-edge driver census already built for car-following, so congestion tracking
-- adds no world scans and does not rebuild road geometry.
local function publishCongestionSnapshot(g: any)
	local now = os.clock()
	if now - _lastCongestionUpdate < Tuning.CONGESTION_UPDATE_INTERVAL then
		return
	end
	_lastCongestionUpdate = now

	local target: { [string]: number } = {}
	for edgeId, bucket in _edgeDriverIndex do
		local edge = g:GetEdge(edgeId)
		if not edge then continue end

		local entering = #(_connectorByNextEdgeIndex[edgeId] or {})
		local vehicleCount = #bucket + entering * 0.5
		if vehicleCount < Tuning.CONGESTION_MIN_QUEUE then continue end

		local slowCount = 0
		local slowLimit = edgeSpeed(edge) * Tuning.CONGESTION_JAM_SPEED_RATIO
		for _, state in bucket do
			if (state.currentSpeed or state.speed or 0) <= slowLimit then
				slowCount += 1
			end
		end

		local capacity = math.max(Tuning.CONGESTION_MIN_QUEUE, edge.length / FOLLOW_MIN_GAP)
		local densityPressure = math.clamp((vehicleCount - 1) / capacity, 0, 1)
		local queuePressure = math.clamp((slowCount - 1) / capacity, 0, 1)
		target[edgeId] = math.clamp(densityPressure * 0.55 + queuePressure * 0.85, 0, 1)
	end

	local snapshot: { [string]: number } = {}
	for edgeId, pressure in target do
		local previous = _edgeCongestion[edgeId] or 0
		local blended = previous + (pressure - previous) * Tuning.CONGESTION_SMOOTHING
		if blended > 0.01 then snapshot[edgeId] = blended end
	end
	for edgeId, previous in _edgeCongestion do
		if target[edgeId] == nil and g:GetEdge(edgeId) then
			local faded = previous * (1 - Tuning.CONGESTION_SMOOTHING)
			if faded > 0.01 then snapshot[edgeId] = faded end
		end
	end

	_edgeCongestion = snapshot
	g:SetCongestionSnapshot(snapshot)

	-- Same cadence, same reason: bookings whose owner vanished without releasing (a
	-- car destroyed mid-trip) must not keep a road looking busy forever.
	g:PruneBookings()
end

-- Whether this vehicle's class is permitted on the given lane edge. A nil set
-- means no restriction.
local function edgeAllows(edge: any, class: string): boolean
	local allowed = edge.allowedVehicles
	return allowed == nil or allowed[class] == true
end

local function getPendingNextEdgeId(g: any, state: DriverState, edge: any): string?
	-- A directed trip never falls through to roaming. updateDriver repairs an invalid
	-- route before moving; the final edge is handled by the arrival branch.
	if state.route then
		local nextRouteId = state.route[(state.routeIndex or 1) + 1]
		if not nextRouteId then
			state.pendingNextEdgeId = nil
			return nil
		end
		local nextEdge = g:GetEdge(nextRouteId)
		if nextEdge and edgeAllows(nextEdge, state.vehicleClass) and edgeHasOutgoing(edge, nextRouteId) then
			state.pendingNextEdgeId = nextRouteId
			return nextRouteId
		end
		-- A mid-block lane change comes first; no junction exit is pending on this lane.
		state.pendingNextEdgeId = nil
		return nil
	end
	local pending = state.pendingNextEdgeId
	local pendingEdge = if pending then g:GetEdge(pending) else nil
	if pending and pendingEdge and edgeAllows(pendingEdge, state.vehicleClass) and edgeHasOutgoing(edge, pending) then
		return pending
	end
	-- Clear stale pending only if the edge truly has no outgoing that matches;
	-- always re-use a valid pending choice so the car waits for the SAME exit it
	-- originally picked rather than re-rolling every frame and deadlocking.
	state.pendingNextEdgeId = nil
	if #edge.out == 0 then
		return nil
	end
	-- Pick and retain a legal exit. A vehicle restriction also holds when every exit
	-- is forbidden; waiting does not grant permission to use one.
	local allowed: { string } = {}
	for _, outId in ipairs(edge.out) do
		local outEdge = g:GetEdge(outId)
		if outEdge and edgeAllows(outEdge, state.vehicleClass) then
			table.insert(allowed, outId)
		end
	end
	if #allowed == 0 then return nil end
	local pool = allowed
	-- Pick a ROAD, then a lane on it. A uniform pick over LANE EDGES gave a multi-lane
	-- onward road one vote per lane: at a ROUNDABOUT node the outs are {ring lane 1, ring
	-- lane 2, the exit}, so the ring outvoted the exit 2:1 at every arm and a roamer lapped
	-- it ~1.1 times on a 3-arm ring (worst measured: 7 laps) instead of ~0.7 -- and it
	-- re-rolled between the ring's OWN two lanes on the way round, which is the weaving.
	local lanesBySegment: { [number]: { string } } = {}
	local segmentIds: { number } = {}
	for _, outId in ipairs(pool) do
		local outEdge = g:GetEdge(outId)
		local segmentId = if outEdge then outEdge.segmentId else 0
		local lanes = lanesBySegment[segmentId]
		if not lanes then
			lanes = {}
			lanesBySegment[segmentId] = lanes
			table.insert(segmentIds, segmentId)
		end
		table.insert(lanes, outId)
	end
	local lanes = lanesBySegment[segmentIds[math.random(1, #segmentIds)]]
	-- Of the lanes this exit allows, take the emptiest, staying in lane unless another is
	-- clearly emptier: ambient cars spread over a wide road instead of stacking in one lane,
	-- but a one-car difference is not worth a swerve across the box at every road join.
	local nextId, fewest = lanes[1], math.huge
	for _, id in lanes do
		local outEdge = g:GetEdge(id)
		local load = #(_edgeDriverIndex[id] or {})
			+ (if outEdge and outEdge.laneOrdinal == edge.laneOrdinal then 0 else Tuning.ROAMER_LANE_KEEP)
		if load < fewest then
			fewest = load
			nextId = id
		end
	end
	state.pendingNextEdgeId = nextId
	return nextId
end

local flatUnit: (Vector3?) -> Vector3

local _ringByEdge: { [string]: any } = {} -- roundabout rings, see ringOf
local function clearGraphCaches()
	table.clear(_nodeMetaById)
	table.clear(_ringByEdge)
end

local function getNodeMeta(g: any, nodeId: number): any
	local cached = _nodeMetaById[nodeId]
	if cached then return cached end

	local network = _roadService and _roadService.getNetwork and _roadService.getNetwork()
	local node = network and network:getNodes()[nodeId]
	local armCount = if node and node.segments then #node.segments else 0
	local incomingEdges = g._edgesByToNode[nodeId] or {}
	local outgoingEdges = g._edgesByFromNode[nodeId] or {}

	local isRoundabout = network ~= nil and network.isRoundaboutNode ~= nil and network:isRoundaboutNode(nodeId)
	local meta = {
		isIntersection = armCount >= 3,
		isRoundabout = isRoundabout,
		stopLineGap = if armCount >= 3 then 20.0 else 1.5,
		stopLineGapBySegment = {},
		uTurnByLane = {},
		uTurnFallback = nil,
	}

	if node and armCount >= 3 then
		local renderArms: { IntersectionRenderer.Arm } = {}
		local renderSegIds: { number } = {}
		for _, sid in node.segments do
			local seg = network and network:getSegment(sid)
			if not seg or seg.isArc then continue end

			local raw: Vector3
			if seg.startNode == nodeId then
				raw = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 0)
			else
				raw = -BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 1)
			end
			if raw.Magnitude < 1e-6 then
				raw = if seg.startNode == nodeId then (seg.p3 - seg.p0) else (seg.p0 - seg.p3)
			end
			if raw.Magnitude > 1e-6 then
				local corner, offset = IntersectionRenderer.armOverrides(seg, nodeId)
				local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
				local swR, swL = IntersectionRenderer.armSidewalks(spec, seg.startNode == nodeId)
				table.insert(renderArms, {
					dir = raw.Unit,
					width = spec.width,
					corner = corner,
					offset = offset,
					swRight = swR,
					swLeft = swL,
				})
				table.insert(renderSegIds, sid)
			end
		end

		local boundaryDistances = IntersectionRenderer.armBoundaryDistances(node.position, renderArms)
		for i, sid in renderSegIds do
			local boundary = boundaryDistances[i] or 0
			-- Match the renderer: steep approaches get an extended junction apron and the
			-- visual stop line moves out with it, so cars must hold at the same distance.
			if _roadService and _roadService.armJunctionBoundary then
				boundary = _roadService.armJunctionBoundary(nodeId, sid) or boundary
			end
			meta.stopLineGapBySegment[sid] = boundary
				+ RoadConstants.CROSSWALK_SETBACK
				+ RoadConstants.CROSSWALK_DEPTH
				+ RoadConstants.CROSSWALK_GAP_FROM_STOP
				+ RoadConstants.STOP_LINE_DEPTH * 0.5
				+ STOP_LINE_CAR_BUFFER
		end
	end

	-- An OUTSIDE CONNECTION (a degree-1 node at the map edge) is an open exit, not a
	-- dead-end -- it gets NO U-turn fallback, so a car never turns around there.
	local h = RoadConstants.MAP_HALF_EXTENT
	local p = node and node.position
	local isConnection = node ~= nil and p ~= nil and #node.segments <= 1
		and (math.abs(math.abs(p.X) - h) <= 30 or math.abs(math.abs(p.Z) - h) <= 30)
	meta.isConnection = isConnection
	if not isConnection then
		for _, edge in ipairs(outgoingEdges) do
			if not meta.uTurnFallback then
				meta.uTurnFallback = edge
			end
			if not meta.uTurnByLane[edge.laneOrdinal] then
				meta.uTurnByLane[edge.laneOrdinal] = edge
			end
		end
	end

	-- A ramp or street joining a divided highway from one side (right-in/right-out, see
	-- RoadRules.highwayJunction): the median separates the far carriageway from everything
	-- that happens here, so cars on opposite sides of it never wait for each other.
	-- farSide[laneId] is true for the lanes arriving on the far side of the median.
	meta.farSide = {}
	if node and network then
		local kind, divided = RoadRules.highwayJunction(network, nodeId)
		if kind == "onesided" and divided then
			local function dividedHighway(segId: number): boolean
				local seg = network:getSegment(segId)
				local spec = RoadTypeCatalog.getOrDefault(seg and seg.roadType)
				return spec.isHighway == true and spec.median == true and not spec.oneWay
			end
			-- The side the ramp / street comes from.
			local sideDir: Vector3? = nil
			for _, sid in node.segments do
				local seg = network:getSegment(sid)
				if seg and not dividedHighway(sid) then
					local far = if seg.startNode == nodeId then seg.p3 else seg.p0
					local d = Vector3.new(far.X - node.position.X, 0, far.Z - node.position.Z)
					if d.Magnitude > 1e-3 then sideDir = d.Unit end
				end
			end
			if sideDir then
				for _, e in incomingEdges do
					local last = e.points[#e.points]
					if dividedHighway(e.segmentId) and last and (last - node.position):Dot(sideDir) < 0 then
						meta.farSide[e.id] = true
					end
				end
			end
		end
	end
	_nodeMetaById[nodeId] = meta
	return meta
end

local function isIntersectionNode(g: any, nodeId: number): boolean
	return getNodeMeta(g, nodeId).isIntersection == true
end

local function isSignalizedIntersection(nodeId: number): boolean
	return TrafficSignalService.HasSignal ~= nil and TrafficSignalService.HasSignal(nodeId) == true
end

-- Returns how far back from the target node a car center should stop.
-- The gap matches the painted stop line/crosswalk setback, plus a front-bumper buffer
-- so the car nose stays behind the stripe instead of its center landing on it.
local function getStopLineGap(g: any, nodeId: number, edge: any?): number
	local meta = getNodeMeta(g, nodeId)
	if edge and edge.segmentId then
		return meta.stopLineGapBySegment[edge.segmentId] or meta.stopLineGap
	end
	return meta.stopLineGap
end

function flatUnit(v: Vector3?): Vector3
	if not v then return Vector3.zAxis end
	local flatX = v.X
	local flatZ = v.Z
	local mag = math.sqrt(flatX * flatX + flatZ * flatZ)
	if mag < 1e-6 then return Vector3.zAxis end
	return Vector3.new(flatX / mag, 0, flatZ / mag)
end

local function isOpposite(dirA: Vector3?, dirB: Vector3?): boolean
	local a = flatUnit(dirA)
	local b = flatUnit(dirB)
	return a:Dot(b) < -0.7
end

-- An approach arm at a junction without lights: "major" on the main road (RoadRules.priorityArms,
-- the rule the give-way markings are painted from), "minor" on every arm that gives way. The
-- player can move the main road at any time, so it is re-read whenever their choice changes.
local function getArmPriority(g: any, nodeId: number, edgeId: string): string
	local meta = getNodeMeta(g, nodeId)
	local key = RoadRules.priorityOverride(nodeId) or false
	if meta.priorityKey ~= key or not meta.mainSegs then
		local network = _roadService and _roadService.getNetwork and _roadService.getNetwork()
		meta.mainSegs = if network then RoadRules.priorityArms(network, nodeId) else {}
		meta.priorityKey = key
	end
	local edge = g:GetEdge(edgeId)
	return if edge and meta.mainSegs[edge.segmentId] then "major" else "minor"
end

local function getUTurnEdge(g: any, edge: any, vehicleClass: string): any?
	for _, id in edge.out do
		local candidate = g:GetEdge(id)
		if candidate and candidate.segmentId == edge.segmentId
			and candidate.forward ~= edge.forward and edgeAllows(candidate, vehicleClass) then
			return candidate
		end
	end
	return nil
end

-- Don't block the box: a car goes only when it can stop with its whole body PAST THE JUNCTION
-- MOUTH on the exit lane, behind where the exit's queue is going to end -- the nearest car on
-- it (or crossing into it) that is stopped or crawling, less one following gap for every car
-- still rolling up behind that one. Faster cars with nothing stopped ahead are flowing traffic
-- and never hold the line (the car ahead of us crossing into the same exit is our queue leader,
-- not a full exit -- counting it stopped every platoon at the line of an empty junction).
-- The exit lane starts at the NODE CENTRE and the box ends where the turn lands on it
-- (GetConnectionSetbacks, ~20 studs in): measuring room from the lane start let a car in that
-- then stopped at lane position 11 -- the middle of the intersection -- behind a queue whose
-- tail sat at the mouth. That, repeated at every junction, was the city-wide gridlock
-- (measured 2026-09-30: all 68 cars frozen in boxes stood between -14 and 21, tails at 22-32).
-- A short exit piece ending in a join shares its queue with the piece after it.
local function exitLaneHasRoom(g: any, state: DriverState, nextEdgeId: string): boolean
	local exit = g:GetEdge(nextEdgeId)
	if not exit then return false end
	local _, boxDepth = g:GetConnectionSetbacks(state.edgeId, nextEdgeId)
	local myHalf = state.halfLength or STOP_LINE_CAR_BUFFER
	local need = boxDepth + myHalf -- my centre has to reach this to be out of the box

	local wall = math.huge
	local wallCar: DriverState? = nil
	local function scanWalls(laneId: string, offset: number)
		for i = 1, 3 do
			local bucket = if i == 1 then _edgeDriverIndex[laneId]
				elseif i == 2 then _connectorByNextEdgeIndex[laneId]
				else _laneChangeIndex[laneId]
			for _, other in bucket or EMPTY do
				-- The target side of a lane change is already in the connector bucket.
				-- A courtesy request has not entered this lane at all.
				local lc = if i == 3 then laneChangeOf(other) else nil
				if i == 3 and (not lc or lc.from ~= laneId) then continue end
				if other == state or not other.model.Parent or (other.currentSpeed or 0) >= Tuning.EXIT_STOPPED_SPEED then continue end
				local p = lanePos(other, laneId) + offset
				if p < wall then wall, wallCar = p, other end
			end
		end
	end
	scanWalls(nextEdgeId, 0)
	local exitLen = exit.length or 0
	-- (A ring lane never stops at its nodes: circulating traffic has priority.)
	local endsAtJunction = isIntersectionNode(g, exit.toNode) and not exit.isRoundabout
	if not wallCar and exitLen < need + FOLLOW_MIN_GAP * 2 and not endsAtJunction then
		for _, outId in exit.out do scanWalls(outId, exitLen) end
	end
	-- An exit ending at another junction may have to queue at THAT stop line, every car on it
	-- included, however fast they are moving now: a short link between two junctions takes only
	-- the cars it can hold. Counting moving cars as always flowing filled whole boxes behind a
	-- link that then stopped (2026-09-30: five cars queued on one 58-stud turn).
	if endsAtJunction then
		local line = exitLen - getStopLineGap(g, exit.toNode, exit)
		if line < wall then wall, wallCar = line, nil end
	end
	if wall == math.huge then return true end

	-- The first car stops AT a stop line, one gap behind a stopped car; every car still short
	-- of the wall takes its OWN length of queue (followGap against itself -- the bare
	-- FOLLOW_MIN_GAP undercounted a real queue, ~12 studs a car, by a third: two cars too many
	-- let into every box behind a long link).
	local tail = if wallCar then wall else wall + followGap(state, state)
	local others = 0
	for i = 1, 3 do
		local bucket = if i == 1 then _edgeDriverIndex[nextEdgeId]
			elseif i == 2 then _connectorByNextEdgeIndex[nextEdgeId]
			else _laneChangeIndex[nextEdgeId]
		for _, other in bucket or EMPTY do
			local lc = if i == 3 then laneChangeOf(other) else nil
			if i == 3 and (not lc or lc.from ~= nextEdgeId) then continue end
			if other == state or other == wallCar or not other.model.Parent then continue end
			others += 1
			if lanePos(other, nextEdgeId) < wall then tail -= followGap(other, wallCar or other) end
		end
	end
	-- A link between two junctions shorter than one car never had "room" by the sum above,
	-- so every car wanting it waited for ever (measured live: eight cars, 40 s, an empty
	-- 23-stud link). Empty, it takes one car at a time; its tail waits in the box behind it.
	if not wallCar and others == 0 then return true end
	return tail - followGap(state, wallCar or state) >= need
end

-- A crossing car only holds us while it is still near enough to conflict with
-- our first stretch into the box. Beyond that, a fresh green goes immediately
-- -- mouth-to-mouth connectors are long, and waiting for the FULL crossing to
-- clear held green-light cars hostage. The proximity hard clamp still guards
-- genuine close calls inside the box.
local CROSS_CLEAR_RADIUS = 22

-- A car STOPPED in the box holds us only while its body stands on our path through it.
-- Whether two movements cross decides who goes first while they move; once one has stopped
-- part-way, where it stands is what matters. Every conflicting box car used to hold the line,
-- so a car stuck at the far kerb waiting for its exit held a whole main road that could drive
-- past it (2026-09-30: four lanes giving way for two minutes to a car 52 of 58 studs across).
Tuning.BOX_PATH_CLEAR = 4.5 -- studs between a stopped car's body and our path that still lets us by
local function blocksMyPath(g: any, other: DriverState, edge: any, nextEdgeId: string?): boolean
	if (other.currentSpeed or 0) >= 0.5 or not nextEdgeId then return true end
	local cf = other.smoothCFrame
	local pts = g:GetConnectionPoints(edge.id, nextEdgeId)
	if not cf or #pts < 2 then return true end
	local half = other.halfLength or STOP_LINE_CAR_BUFFER
	local clearSq = Tuning.BOX_PATH_CLEAR * Tuning.BOX_PATH_CLEAR
	for probe = -1, 1 do
		local q = cf.Position + cf.LookVector * (half * probe)
		for k = 1, #pts - 1 do
			local s, d = pts[k], pts[k + 1] - pts[k]
			local t = math.clamp((q - s):Dot(d) / math.max(d:Dot(d), 1e-6), 0, 1)
			local dx, dz = q.X - (s.X + d.X * t), q.Z - (s.Z + d.Z * t)
			if dx * dx + dz * dz < clearSq then return true end
		end
	end
	return false
end

-- Connector geometry is cached per graph version; destination lane IDs alone do not
-- establish compatibility because two curves can cross before reaching separate lanes.
Tuning.MOVEMENT_PATH_CLEAR = 4.5
local function pointSegmentDistanceSq(p: Vector3, a: Vector3, b: Vector3): number
	local dx, dz = b.X - a.X, b.Z - a.Z
	local t = math.clamp(((p.X-a.X)*dx+(p.Z-a.Z)*dz)/math.max(dx*dx+dz*dz,1e-9),0,1)
	local x, z = p.X-a.X-t*dx, p.Z-a.Z-t*dz
	return x*x+z*z
end

local function segmentsNear(a: Vector3, b: Vector3, c: Vector3, d: Vector3): boolean
	local ax, az, bx, bz = b.X-a.X, b.Z-a.Z, d.X-c.X, d.Z-c.Z
	local denominator = ax*bz-az*bx
	if math.abs(denominator)>1e-9 then
		local cx, cz = c.X-a.X, c.Z-a.Z
		local t, u = (cx*bz-cz*bx)/denominator, (cx*az-cz*ax)/denominator
		if t>=0 and t<=1 and u>=0 and u<=1 then return true end
	end
	local clearanceSq = Tuning.MOVEMENT_PATH_CLEAR*Tuning.MOVEMENT_PATH_CLEAR
	return math.min(pointSegmentDistanceSq(a,c,d),pointSegmentDistanceSq(b,c,d),
		pointSegmentDistanceSq(c,a,b),pointSegmentDistanceSq(d,a,b))<clearanceSq
end

local function movementPathsConflict(g: any, edge: any, nextId: string?, otherEdge: any, otherNextId: string?): boolean
	if not nextId or not otherNextId or nextId==otherNextId or edge.id==otherEdge.id then return true end
	local meta = getNodeMeta(g,edge.toNode)
	local version = g:Version()
	if meta.movementVersion~=version then
		meta.movementVersion=version
		meta.movementConflicts={}
	end
	local key, otherKey = edge.id..">"..nextId, otherEdge.id..">"..otherNextId
	local cache = meta.movementConflicts
	local row = cache[key]
	if row and row[otherKey]~=nil then return row[otherKey] end
	local mine = g:GetConnectionPoints(edge.id,nextId)
	local theirs = g:GetConnectionPoints(otherEdge.id,otherNextId)
	local conflict = #mine<2 or #theirs<2
	for i=1,#mine-1 do
		for j=1,#theirs-1 do
			if segmentsNear(mine[i],mine[i+1],theirs[j],theirs[j+1]) then conflict=true;break end
		end
		if conflict then break end
	end
	row=row or {};cache[key]=row;row[otherKey]=conflict
	cache[otherKey]=cache[otherKey] or {};cache[otherKey][key]=conflict
	return conflict
end

-- How far along the OTHER car's connector it still crosses or brushes our path; past that
-- (its tail beyond it) it has cleared us. A moving car used to hold the line until it left
-- the whole box, so every crossing car cost the side road its full trip through it.
-- Cached per graph version like movementPathsConflict.
function Gridlock.conflictEnd(g: any, edge: any, nextId: string, other: DriverState): number
	local meta = getNodeMeta(g, edge.toNode)
	if meta.conflictEndVersion ~= g:Version() then
		meta.conflictEndVersion = g:Version()
		meta.conflictEnds = {}
	end
	local key = edge.id .. ">" .. nextId .. "|" .. other.edgeId .. ">" .. tostring(other.nextEdgeId)
	local cached = meta.conflictEnds[key]
	if cached then return cached end
	local mine = g:GetConnectionPoints(edge.id, nextId)
	local theirs, cum = other.connector, other.connCum
	local last = math.huge -- unknown geometry: in the way until it lands
	if #mine >= 2 and theirs and cum and #theirs >= 2 then
		last = -math.huge
		for j = 1, #theirs - 1 do
			for i = 1, #mine - 1 do
				if segmentsNear(mine[i], mine[i + 1], theirs[j], theirs[j + 1]) then
					last = cum[j + 1]
					break
				end
			end
		end
	end
	meta.conflictEnds[key] = last
	return last
end

-- A MOVING car in the box whose tail is already past the stretch that crosses our path.
function Gridlock.hasCleared(g: any, edge: any, nextId: string?, other: DriverState): boolean
	if not nextId or (other.currentSpeed or 0) < 0.5 or not other.connector or laneChangeOf(other) then return false end
	local tail = (other.connDist or 0) - (other.halfLength or STOP_LINE_CAR_BUFFER)
	return tail > Gridlock.conflictEnd(g, edge, nextId, other)
end

-- Cars yield rules at a GREEN signal: nearby cross traffic still clearing the
-- box is yielded to; a permissive crossing turn yields to oncoming through/nearside.
local function signalizedClear(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local myPos = getStatePosition(state)
	-- Other cars actively crossing this node right now (connector phase).
	for _, other in _connByLandingNode[nodeId] or EMPTY do
		if other == state or not other.model.Parent or not (other.connector and other.nextEdgeId) then continue end
		local otherNextEdge = g:GetEdge(other.nextEdgeId)
		if not otherNextEdge or otherNextEdge.fromNode ~= nodeId or other.edgeId == edge.id then continue end
		local otherEdge = g:GetEdge(other.edgeId)
		-- The lane beside ours on the same approach runs parallel through the box: it is not
		-- cross traffic. Counting it stopped every car level with a neighbour at the line.
		if not otherEdge or not movementPathsConflict(g,edge,state.pendingNextEdgeId,otherEdge,other.nextEdgeId) then continue end
		if Gridlock.hasCleared(g, edge, state.pendingNextEdgeId, other) then continue end
		if isOpposite(myDir, otherEdge.toDir) then
			-- Oncoming: only our crossing turn conflicts with their straight/nearside.
			local otherMove = otherEdge.outMovement and otherEdge.outMovement[other.nextEdgeId] or "straight"
			if myMove == crossingTurn() and otherMove ~= crossingTurn() and blocksMyPath(g, other, edge, state.pendingNextEdgeId) then
				return false
			end
		elseif (getStatePosition(other) - myPos).Magnitude < CROSS_CLEAR_RADIUS and blocksMyPath(g, other, edge, state.pendingNextEdgeId) then
			-- Perpendicular cross traffic clearing right in front of us: yield. A car
			-- exiting the far side of a big box does not hold our green.
			return false
		end
	end

	-- Permissive crossing turn: give way to oncoming through/nearside traffic on green that
	-- is close enough to actually conflict (within 40 studs of its stop line). Only while
	-- the oncoming car is still approaching: one already committed inside the box is above.
	if myMove ~= crossingTurn() then return true end
	for _, otherEdge in g._edgesByToNode[nodeId] or EMPTY do
		if not isOpposite(myDir, otherEdge.toDir) then continue end
		-- Rear through traffic cannot reach the box before its turning leader.
		-- Letting it claim priority made opposite left-turn heads wait on each other's queues.
		local head: DriverState? = nil
		for _, candidate in _edgeDriverIndex[otherEdge.id] or EMPTY do
			if candidate.connector or candidate.edgeId~=otherEdge.id or not candidate.model.Parent then continue end
			if not head or candidate.edgeDist>head.edgeDist then head=candidate end
		end
		for _, other in _edgeDriverIndex[otherEdge.id] or EMPTY do
			if other~=head or other == state or other.connector or other.edgeId ~= otherEdge.id or not other.model.Parent then continue end
			local otherNext = other.pendingNextEdgeId
			local otherMove = "straight"
			if otherNext then
				otherMove = otherEdge.outMovement and otherEdge.outMovement[otherNext] or "straight"
			end
			local waitingForExit = otherNext ~= nil and (other.currentSpeed or 0) < 0.5
				and not exitLaneHasRoom(g, other, otherNext)
			if not waitingForExit and otherMove ~= crossingTurn() and TrafficSignalService.CanGo(other.edgeId, otherNext)
				and movementPathsConflict(g,edge,state.pendingNextEdgeId,otherEdge,otherNext) then
				local cum = PathFollower.getCum(otherEdge)
				local total = cum and cum[#cum] or 0
				local distToStop = total - getStopLineGap(g, nodeId, otherEdge) - other.edgeDist
				if distToStop > 0 and distToStop < 40 then
					return false
				end
			end
		end
	end
	return true
end

-- Gap acceptance at a give-way junction: yield only to cross traffic that will
-- actually REACH the line within this many seconds.
local CROSS_GAP_TIME = 2.5

-- Seconds until `other` reaches this node's stop line; math.huge when it is not
-- moving. A stationary car is queued or yielding to us, never a conflict -- waiting
-- on one is what made an unsignalised crossing behave like a red light: four cars
-- stopped at the line, each holding the next, until the impatience timer let them
-- trickle through one at a time.
-- Extra centre setback so the NOSE halts ~1 stud before the painted stop line, whatever
-- the vehicle length. getStopLineGap already bakes a car-sized buffer into the gap;
-- this adds the difference for anything longer than that (the truck-overruns-line fix).
local function noseSetback(state: DriverState): number
	return math.max(0, (state.halfLength or STOP_LINE_CAR_BUFFER) - STOP_LINE_CAR_BUFFER) + 1
end

local function etaToStopLine(g: any, other: DriverState, otherEdge: any, nodeId: number): number
	local speed = other.currentSpeed or 0
	if speed < 1 then return math.huge end
	local cum = PathFollower.getCum(otherEdge)
	local total = cum and cum[#cum] or 0
	local dist = total - getStopLineGap(g, nodeId, otherEdge) - other.edgeDist
	if dist <= 0 then return 0 end
	return dist / speed
end

-- Whether a movement from another arm crosses ours. Compatible pairs: the same approach arm
-- (parallel lanes, excluded by the callers), oncoming traffic when neither or both of the pair
-- cut across it, two nearside turns, and a nearside turn against any perpendicular movement but
-- the one driving straight into its exit lane (from its crossing-turn side): a nearside turn
-- keeps to its own corner. Treating every perpendicular pair as crossing made a car turning
-- nearside stop for traffic in the far lane.
local function movesConflict(myDir: Vector3, myMove: string, otherEdge: any, otherMove: string): boolean
	if myMove == "uturn" or otherMove == "uturn" then return true end
	local cross = crossingTurn()
	local myCross = myMove == cross
	if isOpposite(myDir, otherEdge.toDir) then
		return myCross ~= (otherMove == cross)
	end
	local myNear = myMove ~= "straight" and myMove ~= "uturn" and not myCross
	local otherNear = otherMove ~= "straight" and otherMove ~= "uturn" and otherMove ~= cross
	if myNear and otherNear then return false end
	-- The other arm approaches from our crossing-turn side (our left on a right-hand map).
	local o = otherEdge.toDir
	local fromCross = (myDir.X * o.Z - myDir.Z * o.X > 0) == (cross == "left")
	if myNear then return otherMove == "uturn" or (otherMove == "straight" and fromCross) end
	if otherNear then return myMove ~= "straight" or not fromCross end
	return true
end

-- Right-of-way at a junction without lights -- most junctions: RoadRules signals only where two
-- major roads cross. Minor arms yield to major; equal-priority cross traffic yields to whoever
-- approaches from the left. Only a car whose path really crosses ours counts (movesConflict).
-- Cars already in the box are boxHasConflict's, which canEnterIntersection asks first.
local function unsignalizedClear(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local myPriority = getArmPriority(g, nodeId, edge.id)
	local farSide = getNodeMeta(g, nodeId).farSide
	local myFar = farSide[edge.id] == true

	for _, otherEdge in g._edgesByToNode[nodeId] or EMPTY do
		if otherEdge.segmentId == edge.segmentId or (farSide[otherEdge.id] == true) ~= myFar then continue end
		for _, other in _edgeDriverIndex[otherEdge.id] or EMPTY do
			if other == state or other.connector or other.edgeId ~= otherEdge.id or not other.model.Parent then continue end
			if etaToStopLine(g, other, otherEdge, nodeId) >= CROSS_GAP_TIME then continue end
			local otherNext = other.pendingNextEdgeId
			local otherMove = otherNext and otherEdge.outMovement and otherEdge.outMovement[otherNext] or "straight"
			if not movementPathsConflict(g,edge,state.pendingNextEdgeId,otherEdge,otherNext)
				or not movesConflict(myDir, myMove, otherEdge, otherMove) then continue end
			if isOpposite(myDir, otherEdge.toDir) then
				-- Oncoming: of a crossing pair, the crossing turn gives way.
				if myMove == crossingTurn() then return false end
			else
				local otherPriority = getArmPriority(g, nodeId, otherEdge.id)
				if myPriority == "minor" and otherPriority == "major" then
					return false
				elseif myPriority == otherPriority then
					-- Left-before-right: anti-symmetric, so exactly one of a pair yields (the
					-- turn-wait escape in canEnterIntersection breaks a 4-way circular wait).
					local leftX, leftZ = myDir.Z, -myDir.X
					if (-otherEdge.toDir.X) * leftX + (-otherEdge.toDir.Z) * leftZ > 0 then
						return false
					end
				end
			end
		end
	end
	return true
end

-- Roundabout give-way. A car entering the ring from an approach yields to traffic
-- already circulating that is about to pass its entry node; a car already on the
-- ring has priority. Circulating conflicts: a car on the ring arc whose toNode is
-- our entry (within Tuning.ROUNDABOUT_YIELD_DIST), or one mid-crossing onto a ring arc
-- leaving our node.
local function roundaboutClear(g: any, state: DriverState, nodeId: number, nodePos: Vector3): boolean
	-- A car crossing our node onto the ring, or one that has just reached our node on a ring
	-- arc, is circulating through -- give way.
	for _, other in _connByLandingNode[nodeId] or EMPTY do
		if other == state or not other.connector or not other.model.Parent then continue end
		local nextE = other.nextEdgeId and g:GetEdge(other.nextEdgeId)
		if nextE and nextE.isRoundabout and nextE.fromNode == nodeId and g:GetEdge(other.edgeId) then
			return false
		end
	end
	for _, other in _connByLeavingNode[nodeId] or EMPTY do
		if other == state or not other.connector or not other.model.Parent then continue end
		local otherEdge = g:GetEdge(other.edgeId)
		if otherEdge and otherEdge.isRoundabout and otherEdge.toNode == nodeId then
			return false
		end
	end
	-- An inner-lane entry crosses the outer circulating lane. Reserve enough time
	-- to clear the entry, including cars approaching on the preceding ring arcs.
	local entryLength = 0
	local nextId = state.pendingNextEdgeId
	if nextId then
		local points = g:GetConnectionPoints(state.edgeId, nextId)
		for i = 2, #points do entryLength += (points[i] - points[i - 1]).Magnitude end
	end
	local approach = g:GetEdge(state.edgeId)
	local movement = if approach and nextId then approach.outMovement[nextId] else nil
	local entrySpeed = (if movement then Tuning.TURN_ENTRY_SPEED[movement] else nil) or Tuning.MIN_TURN_SPEED
	local crossingTime = math.max(Tuning.JUNCTION_LOOKAHEAD_TIME,
		(entryLength + 2 * (state.halfLength or STOP_LINE_CAR_BUFFER)) / entrySpeed
			+ entrySpeed / Tuning.ACCEL_RATE)
	local pending = {}
	local seen: { [string]: boolean } = {}
	for _, e in g._edgesByToNode[nodeId] or EMPTY do
		if e.isRoundabout then table.insert(pending, { edge = e, distance = 0 }) end
	end
	while #pending > 0 do
		local item = table.remove(pending)
		local e, distance = item.edge, item.distance
		if seen[e.id] then continue end
		seen[e.id] = true
		local length = e.length or 0
		local function conflicts(other: DriverState, position: number): boolean
			if other == state or not other.model.Parent then return false end
			local remaining = distance + math.max(0, length - position)
			local reach = math.max(Tuning.ROUNDABOUT_YIELD_DIST,
				math.max(other.currentSpeed or 0, edgeSpeed(e)) * crossingTime
					+ (other.halfLength or STOP_LINE_CAR_BUFFER))
			return remaining <= reach
		end
		for _, other in _edgeDriverIndex[e.id] or EMPTY do
			if not other.connector and other.edgeId == e.id and conflicts(other, other.edgeDist) then return false end
		end
		for _, other in _connectorByNextEdgeIndex[e.id] or EMPTY do
			if other.connector and other.nextEdgeId == e.id and conflicts(other, lanePos(other, e.id)) then return false end
		end
		local lookback = math.max(Tuning.ROUNDABOUT_YIELD_DIST, edgeSpeed(e) * crossingTime + FOLLOW_MIN_GAP)
		if distance + length <= lookback then
			for _, previous in g._edgesByToNode[e.fromNode] or EMPTY do
				if previous.isRoundabout and not seen[previous.id] then
					table.insert(pending, { edge = previous, distance = distance + length })
				end
			end
		end
	end
	return true
end

-- A ring's lanes and how many queued cars they hold. Built per ring on first use; a graph
-- rebuild drops them (clearGraphCaches).
type Ring = { edges: { string }, capacity: number }
local RING_SLOT = 22 * WS   -- studs of ring lane one queued car takes (measured ~10.5 centre to centre)
local RING_RESERVE = 1      -- slots entering traffic always leaves free

local function ringOf(g: any, edge: any): Ring
	local ring = _ringByEdge[edge.id]
	if ring then return ring end
	local edges: { string } = {}
	local seen: { [string]: boolean } = { [edge.id] = true }
	local stack = { edge }
	local length = 0
	while #stack > 0 do
		local e = table.remove(stack) :: any
		table.insert(edges, e.id)
		length += e.length or 0
		for _, outId in e.out or EMPTY do
			local o = g:GetEdge(outId)
			if o and o.isRoundabout and not seen[outId] then
				seen[outId] = true
				table.insert(stack, o)
			end
		end
	end
	ring = { edges = edges, capacity = math.max(2, math.floor(length / RING_SLOT)) }
	for _, id in edges do _ringByEdge[id] = ring end
	return ring
end

-- Room on the ring for one more car. A ring packed full is a circle of cars each waiting
-- for the one ahead -- none can move, and a car that wants to leave is stuck behind the
-- car in front of it just the same. That deadlock was reachable: an entry that waited its
-- IMPATIENCE_TIME noses in regardless of circulating traffic, and a busy ring filled up.
-- Entries therefore always leave RING_RESERVE slots free, so the circle keeps moving.
local function ringHasRoom(g: any, ringEdge: any): boolean
	local ring = ringOf(g, ringEdge)
	local limit = ring.capacity - RING_RESERVE
	local count = 0
	-- Connector cars are indexed by the lane they are heading into, lane cars by their lane:
	-- counting both covers every car on the ring, every car already committed onto it, and
	-- (from the exits' side) every car still turning off it.
	for _, id in ring.edges do
		for _, other in _edgeDriverIndex[id] or EMPTY do
			if other.edgeId == id and other.model.Parent then count += 1 end
		end
		for _, other in _connectorByNextEdgeIndex[id] or EMPTY do
			if other.model.Parent then count += 1 end
		end
		for _, other in _connectorByFromEdgeIndex[id] or EMPTY do
			local nextE = other.model.Parent and other.nextEdgeId and g:GetEdge(other.nextEdgeId)
			if nextE and not nextE.isRoundabout then count += 1 end
		end
		if count >= limit then return false end
	end
	return true
end

-- True while a car on a CONFLICTING path is physically inside this junction (on its connector
-- through the node). The impatience escape exists to break standoffs between cars WAITING at
-- the lines; it must never send a car into one that is already crossing -- that is how
-- traffic drove straight through itself. A car held in the box by the queue on its exit is
-- traffic, and the cars behind it wait for it like any other jam.

-- How far a car's nose is from its stop line at `nodeId` (negative once it is over it).
local function distToStopLine(g: any, other: DriverState, otherEdge: any, nodeId: number): number
	local cum = PathFollower.getCum(otherEdge)
	return cum[#cum] - getStopLineGap(g, nodeId, otherEdge) - noseSetback(other) - other.edgeDist
end

local function boxHasConflict(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local farSide = getNodeMeta(g, nodeId).farSide
	local myFar = farSide[edge.id] == true
	for _, other in _connByLandingNode[nodeId] or EMPTY do
		if other == state or not other.connector or not other.nextEdgeId or not other.model.Parent then continue end
		if (farSide[other.edgeId] == true) ~= myFar then continue end
		local otherNext = g:GetEdge(other.nextEdgeId)
		if not otherNext or otherNext.fromNode ~= nodeId then continue end
		local otherEdge = g:GetEdge(other.edgeId)
		if not otherEdge then continue end
		-- Diverging turns from one lane still share the junction mouth; a long
		-- turning vehicle must clear it before the following movement enters.
		if other.edgeId == edge.id then
			if other.nextEdgeId ~= state.pendingNextEdgeId
				and (other.connDist or 0) <= (other.halfLength or STOP_LINE_CAR_BUFFER)+1 then return true end
			-- A platoon shares its connector. Following distance, not box exclusion,
			-- keeps its cars apart; a diverging leader holds only until its tail clears.
			continue
		end
		if not movementPathsConflict(g,edge,state.pendingNextEdgeId,otherEdge,other.nextEdgeId) then continue end
		if Gridlock.hasCleared(g, edge, state.pendingNextEdgeId, other) then continue end
		if blocksMyPath(g, other, edge, state.pendingNextEdgeId) then return true end
	end
	-- A car over its stop line has committed and will not stop, but its path through the box
	-- only starts at the junction mouth a few studs on: until then it is in the box all the same.
	for _, inEdge in g._edgesByToNode[nodeId] or {} do
		if inEdge.segmentId == edge.segmentId or (farSide[inEdge.id] == true) ~= myFar then continue end
		for _, other in _edgeDriverIndex[inEdge.id] or {} do
			local otherNextId = other.pendingNextEdgeId
			if other == state or other.connector or not otherNextId or not other.model.Parent then continue end
			if distToStopLine(g, other, inEdge, nodeId) >= -0.1 then continue end
			if movementPathsConflict(g,edge,state.pendingNextEdgeId,inEdge,otherNextId)
				and blocksMyPath(g, other, edge, state.pendingNextEdgeId) then return true end
		end
	end
	return false
end

-- How long a car on `edge` waits at a junction without signals before it takes its turn.
local function turnWait(g: any, nodeId: number, edge: any): number
	if getArmPriority(g, nodeId, edge.id) == "minor" then return Tuning.TURN_WAIT_MINOR end
	return Tuning.TURN_WAIT_EQUAL
end

-- Courtesy at a junction without signals. The car that has waited longest at its line (its
-- turn wait plus CLAIM_EXTRA, with room on its exit) is let in: every car whose path crosses
-- its path holds at the line until it is through. One such car per junction at a time --
-- when every stopped car could claim, each car held for one became a claimant in turn and
-- the junction ran as an all-way stop. Without it a steady stream on one road, or the queue
-- behind one car waiting to turn across it, starved the other approaches for minutes.
-- Turns go by when the wait BEGAN (waitSince), never by blockedTime: that grows during each
-- car's own update, so two cars compared mid-tick could each see the other as the longer
-- waiter and both hold for good.
local CLAIM_EXTRA = 3 -- s past its turn wait before the others stop to let a car in
local function junctionClaimant(g: any, nodeId: number): (DriverState?, any)
	local best, bestEdge, bestSince = nil, nil, 0
	for _, inEdge in g._edgesByToNode[nodeId] or {} do
		local threshold = turnWait(g, nodeId, inEdge) + CLAIM_EXTRA
		for _, other in _edgeDriverIndex[inEdge.id] or {} do
			if other.connector or not other.model.Parent then continue end
			local wait = other.blockedTime or 0
			if wait < threshold then continue end
			local since = other.waitSince or (_simClock - wait)
			if best and (since > bestSince or (since == bestSince and goesFirst(best, other))) then continue end
			local nextId = other.pendingNextEdgeId
			if not nextId or not exitLaneHasRoom(g, other, nextId) then continue end
			if distToStopLine(g, other, inEdge, nodeId) > AT_LINE_DIST then continue end
			best, bestEdge, bestSince = other, inEdge, since
		end
	end
	return best, bestEdge
end

local function owesCourtesy(g: any, state: DriverState, edge: any, nodeId: number, myDir: Vector3, myMove: string): boolean
	local claimant, claimEdge = junctionClaimant(g, nodeId)
	if not claimant or claimant == state or claimEdge.segmentId == edge.segmentId then return false end
	local farSide = getNodeMeta(g, nodeId).farSide
	if (farSide[claimEdge.id] == true) ~= (farSide[edge.id] == true) then return false end
	local claimMove = claimEdge.outMovement and claimEdge.outMovement[claimant.pendingNextEdgeId] or "straight"
	return movementPathsConflict(g,edge,state.pendingNextEdgeId,claimEdge,claimant.pendingNextEdgeId)
		and movesConflict(myDir, myMove, claimEdge, claimMove)
end

local function canEnterIntersection(g: any, state: DriverState, edge: any, nextEdgeId: string): boolean
	local nodeId = edge.toNode
	if not isIntersectionNode(g, nodeId) then
		-- A dead-end U-turn back onto the same road needs the same one-at-a-time
		-- gating an intersection gets. Without it, cars commit U-turns into a full
		-- return lane and clump at the cul-de-sac mouth until the road gridlocks.
		-- A jammed return lane is traffic: wait until it has room.
		local myMove = edge.outMovement and edge.outMovement[nextEdgeId]
		if myMove == "uturn" then
			-- Same-segment only: a sharp bend onto ANOTHER road classifies as a
			-- U-turn by angle but is ordinary through-traffic around the corner --
			-- gating it made cars queue at (and creep past) the bend apex.
			local nextEdge = g:GetEdge(nextEdgeId)
			if not nextEdge or nextEdge.segmentId ~= edge.segmentId then
				return true
			end
			return exitLaneHasRoom(g, state, nextEdgeId)
		end
		return true
	end

	-- Roundabout right-of-way -- decided on the lane flags (not node meta), so it can
	-- never silently fall back to ordinary junction logic. A circulating car has
	-- absolute priority and never yields at a ring node (the follower clearance keeps
	-- it off the car ahead, so no node-by-node stutter). An entering car always gives
	-- way to circulating traffic and reserves enough space to leave the box.
	if edge.isRoundabout then
		return true
	end
	do
		local nextEdge = g:GetEdge(nextEdgeId)
		if nextEdge and nextEdge.isRoundabout then
			if not exitLaneHasRoom(g, state, nextEdgeId) or not ringHasRoom(g, nextEdge) then
				return false
			end
			local nodePos = if edge.points and #edge.points > 0 then edge.points[#edge.points] else getStatePosition(state)
			return roundaboutClear(g, state, nodeId, nodePos)
		end
	end

	local signalized = isSignalizedIntersection(nodeId)
	local myMove = edge.outMovement and edge.outMovement[nextEdgeId] or "straight"
	local myDir  = edge.toDir
	-- Only the signal controller grants right of way, including long edited cycles.
	if signalized and not TrafficSignalService.CanGo(edge.id, nextEdgeId) then
		return false
	end

	-- Don't enter unless the exit lane has room. However long it has been full, a full exit
	-- is a jam: a gridlocked box stays gridlocked until the queue ahead moves or the player
	-- changes the roads.
	if not exitLaneHasRoom(g, state, nextEdgeId) then
		return false
	end

	if boxHasConflict(g, state, edge, nodeId, myDir, myMove) then
		return false
	end

	if not signalized and owesCourtesy(g, state, edge, nodeId, myDir, myMove) then
		return false
	end

	if signalized then
		return signalizedClear(g, state, edge, nodeId, myDir, myMove)
	end
	return unsignalizedClear(g, state, edge, nodeId, myDir, myMove)
end

local function chooseEnterableNextEdgeId(g: any, state: DriverState, edge: any, currentNextId: string?): (string?, boolean)
	if not currentNextId then
		return nil, false
	end
	if canEnterIntersection(g, state, edge, currentNextId) then
		return currentNextId, true
	end

	-- If the approach itself is red/yellow/all-red, changing turns will not help.
	if isSignalizedIntersection(edge.toNode) and not TrafficSignalService.CanGo(edge.id, currentNextId) then
		return currentNextId, false
	end

	-- ponytail: never re-roll the turn while blocked. getPendingNextEdgeId locks the exit
	-- in on purpose; re-rolling it every tick made a yielding pair flip their decision
	-- against each other (livelock), and could shove a DIRECTED car off its route.
	return currentNextId, false
end

-- Max comfortable speed through a connector polyline, from its tightest bend:
-- v = sqrt(a_lat * r). Stops cars taking 90-deg turns and U-turns at the full
-- road speed limit, which read as snapping at the wheel.
local function connectorSpeedCap(pts: { Vector3 }): number?
	if #pts < 3 then return nil end
	local minRadius = math.huge
	for i = 2, #pts - 1 do
		local a = pts[i] - pts[i - 1]
		local b = pts[i + 1] - pts[i]
		local la, lb = a.Magnitude, b.Magnitude
		if la > 1e-4 and lb > 1e-4 then
			local angle = math.acos(math.clamp(a:Dot(b) / (la * lb), -1, 1))
			if angle > 1e-3 then
				minRadius = math.min(minRadius, ((la + lb) * 0.5) / angle)
			end
		end
	end
	if minRadius == math.huge then return nil end
	return math.max(math.sqrt(Tuning.CONNECTOR_LAT_ACCEL * minRadius), Tuning.MIN_TURN_SPEED)
end

-- Connector Y interpolates mouth-to-mouth, but a graded junction's interior is
-- a blended surface that can bow away from that line -- cars sank into the
-- slab mid-box. Ground each interior point on the real rendered junction
-- surface (junction surface parts are CanQuery for exactly this). Points with
-- no junction surface under them (corners, dead-end bulbs) keep their Y.
local GROUND_RAY_UP   = Vector3.new(0, 4, 0)
local GROUND_RAY_DOWN = Vector3.new(0, -16, 0)
local GROUND_MAX_SNAP = 3
local _groundParams: RaycastParams? = nil

local function groundParams(): RaycastParams?
	-- ONLY the road geometry folder. Filtering all of _City snapped connector
	-- points onto NPC click-hitboxes and zoning lots -- cars climbed each other.
	-- Inside Roads, junction surfaces are the only CanQuery parts.
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	if not roads then
		return nil
	end
	local p = _groundParams
	if not p or p.FilterDescendantsInstances[1] ~= roads then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Include
		p.FilterDescendantsInstances = { roads }
		_groundParams = p
	end
	return p
end

-- Lane points (RoadNavigationGraph) run down the MIDDLE of the road slab -- the road renderer's
-- convention -- while the asphalt is half a slab higher. NPCHeightOffset is a vehicle's clearance
-- above what it drives on, so every road placement adds this. Without it every car rode half a
-- slab (a quarter metre) sunk into the road, and dropped into it leaving a driveway.
local LANE_SURFACE = RoadConstants.ROAD_THICKNESS * 0.5

local function groundConnectorPoints(pts: { Vector3 })
	if #pts < 3 then
		return
	end
	local params = groundParams()
	if not params then
		return
	end
	local halfThick = RoadConstants.ROAD_THICKNESS * 0.5
	for i = 2, #pts - 1 do
		local p = pts[i]
		local hit = Workspace:Raycast(p + GROUND_RAY_UP, GROUND_RAY_DOWN, params)
		-- Pillars are queryable for placement checks; never a driving surface.
		if hit and hit.Instance.Name ~= "ElevationPillar" then
			local y = hit.Position.Y - halfThick
			if math.abs(y - p.Y) <= GROUND_MAX_SNAP then
				pts[i] = Vector3.new(p.X, y, p.Z)
			end
		end
	end
end

local function startConnector(
	state:        DriverState,
	pts:          { Vector3 },
	nextId:       string,
	resumeDist:   number
)
	groundConnectorPoints(pts)
	-- Pre-compute and cache the cum-distances for the connector arc once.
	local cum = PathFollower.cumOf(pts)
	if #pts < 2 or (cum[#cum] or 0) < 0.5 then
		state.connector    = nil
		state.connCum      = nil
		state.connDist     = 0
		state.connSpeedCap = nil
		state.connBlockedTime = 0
		state.nextEdgeId   = nil
		state.nextEdgeDist = 0
		state.pendingNextEdgeId = nil
		state.edgeId       = nextId
		state.edgeDist     = resumeDist
		if state.route and state.routeIndex and state.route[state.routeIndex + 1] == nextId then
			state.routeIndex += 1
		end
		reindexDriver(state)
		return
	end
	state.connector    = pts
	state.connCum      = cum
	state.connDist     = 0
	state.connSpeedCap = connectorSpeedCap(pts)
	state.connBlockedTime = 0
	state.nextEdgeId   = nextId
	state.nextEdgeDist = resumeDist
	state.pendingNextEdgeId = nil
	-- Filed under its junction straight away (tracked, see reindexDriver), so the cars
	-- updating after it this tick already see it in the box.
	reindexDriver(state)
end

local function buildUTurnArc(fromEdge: any, toEdge: any): { Vector3 }
	local pts = fromEdge.points
	local p0  = pts[#pts]
	local tp  = toEdge.points
	local p3  = tp[1]

	-- Tangent-continuous teardrop: both bezier handles push forward into the
	-- dead end, so the car leaves its lane straight, loops around, and lands
	-- straight on the return lane. The old constant-radius arc put its centre
	-- FORWARD of the lane tips, so p0/p3 sat sqrt(2)x off the circle and the
	-- car snapped sideways at both ends of the turn.
	local fwd    = flatUnit(fromEdge.toDir)
	local outDir = flatUnit(toEdge.fromDir)

	local gap    = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z).Magnitude
	local handle = math.max(gap * 0.9, 4)
	local p1 = p0 + fwd * handle
	local p2 = p3 - outDir * handle

	local SAMPLES = 20
	local out: { Vector3 } = table.create(SAMPLES + 1)
	for i = 0, SAMPLES do
		table.insert(out, BezierUtil.point(p0, p1, p2, p3, i / SAMPLES))
	end
	return out
end

-- Max distance to the nearest surviving lane before a stranded car despawns
-- instead of re-anchoring. Snapping survivors onto a random distant edge read
-- as cars teleporting across the map when the road was deleted under them.
local REANCHOR_MAX_DIST = 80

-- == Route bookings ============================================================
-- The nav-app effect. A driver that commits to a route reserves capacity along it,
-- so the NEXT driver to plan already prices that corridor as filling and peels off
-- onto an alternative. Without this, a wave of cars leaving at the same moment all
-- see the same empty road, all choose it, and build the jam together -- the exact
-- behaviour real drivers avoid by being told where everyone else is going.
--
-- Booked -> released as a pair: every path that drops a driver from _drivers must
-- release, or the road stays permanently "busy". The graph also expires bookings on
-- a TTL as a backstop for cars destroyed out from under us.
local function bookRoute(state: DriverState)
	local g = nav()
	local route = state.route
	if not g or not route then return end
	local token = state.bookingToken
	if not token then
		_nextBookingToken += 1
		token = _nextBookingToken
		state.bookingToken = token
		state.profile = DriverProfile.withToken(state.profile, token)
	end
	g:BookRoute(token, route, state.routeIndex or 1)
end

local function releaseBooking(state: DriverState)
	local token = state.bookingToken
	if not token then return end
	state.bookingToken = nil
	local g = nav()
	if g then g:ReleaseBooking(token) end
end

-- A car leaving the traffic AI stands where it really is, on the server too. Driving, it moves
-- only on the pose stream, so its instance still sits where it SPAWNED; handed back like that
-- (untagged, so the client stops moving it) the player kept seeing it at its last streamed pose
-- while the server had it elsewhere -- a ghost the traffic drove through -- and the owner's next
-- leg started from the spawn point. Write it BEFORE the tag comes off.
local function leaveWhereItStands(state: DriverState)
	local stopped = state.smoothCFrame
	if not stopped or not state.model.Parent then return end
	state.model:SetAttribute("NPCStoppedPose", stopped)
	local root = state.model.PrimaryPart
	if root then root.CFrame = stopped else state.model:PivotTo(stopped) end
end

local function despawnDriver(state: DriverState)
	local model = state.model
	releaseBooking(state)
	unindexDriver(state)
	_drivers[model] = nil
	PathFollower.forget(model)
	model:Destroy()
end

-- End a directed trip WITHOUT destroying the car: drop it from the driver pool and
-- hand control back to the caller (onAbort), which parks the citizen/delivery car
-- where it is. Used when the road changes under a routed car or it wedges for good.
local function abortDirected(state: DriverState)
	local cb = state.onAbort
	releaseBooking(state)
	leaveWhereItStands(state)
	clearDirectedDebugTag(state)
	state.route = nil
	state.onArrive = nil
	state.onAbort = nil
	unindexDriver(state)
	_drivers[state.model] = nil
	PathFollower.forget(state.model)
	if cb then task.spawn(cb) end
end

local function anchorToNearest(state: DriverState): boolean
	if not state.model.Parent then return false end
	local g = nav()
	if not g or not g:HasEdges() then
		-- No roads left at all.
		despawnDriver(state)
		return false
	end
	local result = g:NearestEdge(getStatePosition(state))
	if not result or result.distance > REANCHOR_MAX_DIST then
		-- Road under us was deleted with no lane nearby: despawn rather than
		-- teleport to a random edge.
		despawnDriver(state)
		return false
	end
	state.edgeId       = result.edge.id
	local d = 0
	for i = 2, math.clamp(result.index, 1, #result.edge.points) do
		d += (result.edge.points[i] - result.edge.points[i-1]).Magnitude
	end
	state.edgeDist     = d
	state.graphVersion = g:Version()
	state.connector    = nil
	state.connCum      = nil
	state.connDist     = 0
	state.nextEdgeId   = nil
	state.nextEdgeDist = 0
	state.pendingNextEdgeId = nil
	state.atDeadEnd    = false
	state.deadEndTimer = 0
	return true
end

-- Distance along an edge to the point on it nearest a world position.
-- Distance along a lane of the point on it closest to `pos`.
--
-- This projects onto each CHORD, not onto the sample points. Snapping to the nearest
-- vertex (which this used to do) quantised every answer to the lane's sampling, and a
-- straight lane is sampled at NAV_WAYPOINT_SPACING = 56 studs -- so a car could be placed
-- up to 28 studs from where it actually was, and a whole queue spaced FOLLOW_MIN_GAP
-- (8 studs) apart collapsed onto one or two vertices. Every caller wants the real nearest
-- point: DriveDirected uses it to seat a car at the start of a trip, anchorToNearest to
-- rejoin a car whose road was edited, and the save/restore path to put a jam back exactly
-- where it stood.
local function distAlongEdgeNearest(edge: any, pos: Vector3): number
	local cum = PathFollower.getCum(edge)
	local pts = edge.points
	if #pts == 0 then return 0 end
	if #pts == 1 then return cum[1] or 0 end
	local best, bestSq = 0, math.huge
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local abx, abz = b.X - a.X, b.Z - a.Z
		local len2 = abx * abx + abz * abz
		local t = 0
		if len2 > 1e-9 then
			t = math.clamp(((pos.X - a.X) * abx + (pos.Z - a.Z) * abz) / len2, 0, 1)
		end
		local dx = (a.X + abx * t) - pos.X
		local dz = (a.Z + abz * t) - pos.Z
		local sq = dx * dx + dz * dz
		if sq < bestSq then
			bestSq = sq
			best = (cum[i] or 0) + ((cum[i + 1] or 0) - (cum[i] or 0)) * t
		end
	end
	return best
end

-- A directed car whose current edge was deleted (road replaced/upgraded under it)
-- tries to rejoin the network: snap to the nearest surviving lane and re-plan a
-- fresh route from there to the same destination, so the trip continues on the new
-- road instead of being aborted. Returns false if there is no lane in range or no
-- path to the goal -- the caller then falls back to abortDirected.
local function tryReroute(state: DriverState): boolean
	local g = nav()
	if not g or not g:HasEdges() then return false end
	local goal = state.goalPos
	if not goal then return false end
	if not state.model.Parent then return false end

	local pos = getStatePosition(state)
	local nearest = g:NearestEdge(pos)
	if not nearest or nearest.distance > REANCHOR_MAX_DIST then return false end

	-- From the lane the car is on while it still exists. A plan from the bare position could
	-- start on the lane beside it, and the car was put there in one tick: the sideways hop at
	-- a missed merge, straight into the gap it had just been refused. Only a car whose lane
	-- is gone (road edited under it) or leads nowhere is re-seated on the nearest one.
	local own = if not state.connector and g:GetEdge(state.edgeId) then state.edgeId else nil
	local route: any = nil
	-- A line bus (DriverProfile keepRoute) never improvises: from its own lane it carries on along
	-- the rest of the route it was given, as long as every piece of it is still drivable.
	local kept = state.route
	local keepAt = if own and kept and state.profile and state.profile.keepRoute then table.find(kept, own, state.routeIndex or 1) else nil
	if keepAt and kept then
		route = table.move(kept, keepAt, #kept, 1, {})
		for i, id in route do
			local e = g:GetEdge(id)
			local nextId = route[i + 1]
			if not e or not edgeAllows(e, state.vehicleClass)
				or (nextId and not edgeHasOutgoing(e, nextId) and not g:GetLaneChangeWindow(id, nextId)) then
				route = nil -- the road changed under it: plan afresh below
				break
			end
		end
	end
	if own and not route then
		local ok, _, r = pcall(g.FindPath, g, pos, goal, nil, state.vehicleClass, state.profile,
			{ edgeId = own, dist = state.edgeDist })
		if ok and typeof(r) == "table" and r[1] == own then route = r end
	end
	if own and not route then return false end
	if not route then
		local _, r = g:FindPath(pos, goal, nil, state.vehicleClass, state.profile)
		route = r
	end
	if typeof(route) ~= "table" or #route == 0 then return false end
	local firstEdge = g:GetEdge(route[1])
	local lastEdge = g:GetEdge(route[#route])
	if not firstEdge or not lastEdge then return false end

	state.route        = route
	state.routeIndex   = 1
	if route[1] ~= own then
		state.edgeDist = distAlongEdgeNearest(firstEdge, pos)
	end
	state.edgeId       = route[1]
	state.finalDist    = distAlongEdgeNearest(lastEdge, goal)
	state.graphVersion = g:Version()
	state.connector    = nil
	state.connCum      = nil
	state.connDist     = 0
	state.connSpeedCap = nil
	state.nextEdgeId   = nil
	state.nextEdgeDist = 0
	state.pendingNextEdgeId = nil
	state.atDeadEnd    = false
	state.deadEndTimer = 0
	state.arrived      = false
	state.trafficJamTime = 0
	state.nextTrafficRerouteAt = os.clock() + TRAFFIC_REROUTE_COOLDOWN
	bookRoute(state)
	return true
end

local function sameRemainingRoute(oldRoute: { string }, oldIndex: number, newRoute: { string }): boolean
	local remaining = #oldRoute - oldIndex + 1
	if remaining ~= #newRoute then return false end
	for i = 1, #newRoute do
		if oldRoute[oldIndex + i - 1] ~= newRoute[i] then
			return false
		end
	end
	return true
end

local function firstRouteDivergence(oldRoute: { string }, oldIndex: number, newRoute: { string }): (string?, string?)
	local remaining = #oldRoute - oldIndex + 1
	for offset = 2, math.max(remaining, #newRoute) do
		local oldEdgeId = oldRoute[oldIndex + offset - 1]
		local newEdgeId = newRoute[offset]
		if oldEdgeId ~= newEdgeId then
			return oldEdgeId, newEdgeId
		end
	end
	return nil, nil
end

-- The same roads in the same order, only on other lanes: a move over, not a detour.
local function sameRoads(g: any, oldRoute: { string }, oldIndex: number, newRoute: { string }): boolean
	local function roads(route: { string }, from: number): { number }
		local out: { number } = {}
		for i = from, #route do
			local edge = g:GetEdge(route[i])
			local segmentId = if edge then edge.segmentId else -1
			if out[#out] ~= segmentId then table.insert(out, segmentId) end
		end
		return out
	end
	local a, b = roads(oldRoute, oldIndex), roads(newRoute, 1)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Traffic reroutes never snap the car to another lane. They only replace the
-- untravelled route tail when A* finds a meaningfully cheaper path that begins on
-- the exact edge the car is already following. A plan that keeps every road and only
-- moves over a lane (out of a queue into the empty lane beside it) is a lane change, not a
-- detour: it needs to beat the old plan by seconds, not by a share of the whole trip, and
-- it spends none of the driver's detour budget.
local function tryTrafficReroute(state: DriverState): boolean
	local g = nav()
	local route = state.route
	local goal = state.goalPos
	if not g or not route or not goal or state.connector or not state.model.Parent then return false end
	local profile = state.profile
	local rerouteCount = state.trafficReroutes or 0
	-- A jam-averse driver gives itself more chances to change its mind than a
	-- fatalistic one, who commits and sits in it.
	local rerouteBudget = Tuning.TRAFFIC_REROUTE_MAX_PER_TRIP + (if profile then profile.extraReroutes else 0)
	local routeIndex = state.routeIndex or 1
	if routeIndex >= #route then return false end

	local pos = getStatePosition(state)
	local _, candidate = g:FindPath(pos, goal, nil, state.vehicleClass, profile,
		{ edgeId = state.edgeId, dist = state.edgeDist })
	if typeof(candidate) ~= "table" or #candidate == 0 or candidate[1] ~= state.edgeId then
		return false
	end
	if sameRemainingRoute(route, routeIndex, candidate) then
		return false
	end

	-- Hysteresis: once a car abandons a branch, do not let small traffic-score
	-- fluctuations send it straight back toward that same branch.
	local now = os.clock()
	local abandonedBranch, candidateBranch = firstRouteDivergence(route, routeIndex, candidate)
	if candidateBranch
		and candidateBranch == state.lastTrafficAbandonedNextEdgeId
		and now - (state.lastTrafficRerouteAt or 0) < Tuning.TRAFFIC_REROUTE_REVERSAL_LOCK then
		return false
	end

	-- Both routes are priced with the SAME mind (this driver's), or every reroute
	-- would look like an improvement purely from the change of scorer.
	local oldCost = g:EstimatePathCost(route, routeIndex, profile)
	local newCost = g:EstimatePathCost(candidate, 1, profile)
	if oldCost == math.huge then return false end
	local laneMove = sameRoads(g, route, routeIndex, candidate)
	if laneMove then
		if newCost > oldCost - Tuning.LANE_MOVE_MIN_SAVING then return false end
	else
		if rerouteCount >= rerouteBudget then return false end
		-- How much better the alternative must be before this driver commits to it.
		-- Persona sets the baseline (twitchy re-router vs "I've started, I'll finish");
		-- each reroute already taken raises the bar further, so nobody oscillates.
		local baseImprovement = if profile then profile.detourTrigger else Tuning.TRAFFIC_REROUTE_MIN_IMPROVEMENT
		local requiredImprovement = math.min(0.6, baseImprovement + rerouteCount * 0.1)
		if newCost >= oldCost * (1 - requiredImprovement) then
			return false
		end
	end

	local lastEdge = g:GetEdge(candidate[#candidate])
	if not lastEdge then return false end
	state.lastTrafficAbandonedNextEdgeId = abandonedBranch
	state.lastTrafficRerouteAt = now
	state.route = candidate
	state.routeIndex = 1
	state.finalDist = distAlongEdgeNearest(lastEdge, goal)
	state.pendingNextEdgeId = nil
	state.trafficJamTime = 0
	if not laneMove then state.trafficReroutes = rerouteCount + 1 end
	-- Re-reserve: free the abandoned corridor for everyone else and stake a claim on
	-- the new one, so the next planner sees where this car actually went.
	bookRoute(state)
	tagCarInfo(state, "Rerouting", candidateBranch or candidate[2] or candidate[1])
	return true
end

-- Gridlock breaker. A car at its line whose exit has stayed full EXIT_DETOUR_TIME takes the
-- cheapest other legal exit that has room and re-plans to its goal from there, whatever the
-- detour costs. A ring of full streets, each head waiting on the next, is the gridlock this
-- breaks: the price-based reroute never fired for those heads (no queue leader = not "in a
-- jam") and a 30% saving is never on offer when every street is full.
function Gridlock.detour(g: any, state: DriverState, edge: any, blockedId: string): boolean
	state.nextDetourAt = _simClock + Tuning.EXIT_DETOUR_RETRY
	if state.profile and state.profile.keepRoute then return false end -- a line bus waits its turn, it never takes another exit
	local goal = state.goalPos
	if not goal or not state.route then return false end
	local best, bestCost = nil, math.huge
	for _, altId in edge.out do
		if altId == blockedId or (edge.outMovement and edge.outMovement[altId]) == "uturn" then continue end
		local alt = g:GetEdge(altId)
		if not alt or not edgeAllows(alt, state.vehicleClass) or not exitLaneHasRoom(g, state, altId) then continue end
		local ok, _, tail = pcall(g.FindPath, g, alt.points[1], goal, nil, state.vehicleClass, state.profile,
			{ edgeId = altId, dist = 0 })
		if not ok or typeof(tail) ~= "table" or tail[1] ~= altId then continue end
		local cost = g:EstimatePathCost(tail, 1, state.profile)
		if cost < bestCost then best, bestCost = tail, cost end
	end
	if not best then return false end
	local lastEdge = g:GetEdge(best[#best])
	if not lastEdge then return false end
	local route = { state.edgeId }
	for _, id in best do table.insert(route, id) end
	state.lastTrafficAbandonedNextEdgeId = blockedId
	state.lastTrafficRerouteAt = os.clock()
	state.route = route
	state.routeIndex = 1
	state.finalDist = distAlongEdgeNearest(lastEdge, goal)
	state.pendingNextEdgeId = nil
	state.trafficJamTime = 0
	state.exitWait = 0
	bookRoute(state)
	tagCarInfo(state, "Rerouting", best[1])
	return true
end

-- == Stall watchdog ============================================================
-- Last-resort safety net for BUGGED cars only. A car held by traffic (see
-- waitingInTraffic) waits as long as the traffic does -- a gridlock is part of the
-- simulation and the player's to fix. Zero movement for STALL_RESCUE_TIME with no
-- traffic reason means something is truly wedged: dump the full state for diagnosis,
-- then re-seat the car and let it push through. If it stalls again with no progress
-- in between, respawn it on a random edge.
local function dumpStall(state: DriverState)
	warn(`[NPCDriverService] {state.model.Name} stalled {STALL_RESCUE_TIME}s -- rescuing.`
		.. ` edge={state.edgeId}@{string.format("%.1f", state.edgeDist)}`
		.. ` conn={state.connector ~= nil}@{string.format("%.1f", state.connDist)}`
		.. ` next={state.nextEdgeId or "-"} pending={state.pendingNextEdgeId or "-"}`
		.. ` deadEnd={state.atDeadEnd} speed={string.format("%.1f", state.currentSpeed or 0)}`
		.. ` blocked={string.format("%.1f", state.blockedTime or 0)}`
		.. ` stuck={string.format("%.1f", state.stuckTime or 0)}`
		.. ` standoff={string.format("%.1f", state.connBlockedTime or 0)}`
		.. ` rescues={state.rescueCount or 0}`)
end

-- One index bucket's nearest car ahead of `myPos` on `laneId`. Equal positions break by
-- name so exactly one of a pair waits.
local function queueScan(bucket: { any }?, state: DriverState, laneId: string, myPos: number,
	onlyConnectors: boolean, nearest: DriverState?, nearestGap: number): (DriverState?, number)
	local first = 1
	local sorted = bucket ~= nil and bucket == _edgeDriverIndex[laneId] and not onlyConnectors
	if sorted then
		local lo, hi = 1, #(bucket :: {any}) + 1
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if (bucket :: {any})[mid].edgeDist < myPos - QUEUE_TIE_EPSILON then lo = mid + 1 else hi = mid end
		end
		first = lo
	end
	for i = first, #(bucket or EMPTY) do
		local other = (bucket :: {any})[i]
		if sorted and other.edgeDist - myPos >= nearestGap then break end
		if other == state then continue end
		if onlyConnectors then
			if not other.connector then continue end
		elseif other.connector and not laneChangeOf(other) then
			continue -- turned off this lane since the index was built
		end
		local rawGap = lanePos(other, laneId) - myPos
		if rawGap < -QUEUE_TIE_EPSILON or math.max(0, rawGap) >= nearestGap then continue end
		local tied = math.abs(rawGap) <= QUEUE_TIE_EPSILON and goesFirst(other, state)
		if rawGap > QUEUE_TIE_EPSILON or tied then
			local gap = math.max(0, rawGap)
			-- The engine read last, only for a car that would become the nearest.
			if gap < nearestGap and other.model.Parent then
				nearestGap = gap
				nearest = other
			end
		end
	end
	return nearest, nearestGap
end

-- Nearest car ahead in this car's lane, and the gap to it. On a connector "this lane" is the
-- one it lands on, so a queue runs unbroken through joins, turns and lane changes: cars
-- crossing into the lane and cars mid lane change out of it are in the way at their lanePos.
local findQueueLeader: (state: DriverState) -> (DriverState?, number?)

-- One car's update asks this up to five times (reroute, lane change, spacing, speed, the
-- watchdog) and nothing else moves in between, so the answer is kept for as long as the
-- asking car has not moved or changed lane. _queueEpoch changes before every car's update.
local _queueEpoch = 0
type QueueMemo = { epoch: number, edgeId: string, edgeDist: number, connDist: number, conn: boolean, lead: DriverState?, gap: number? }
local _queueMemo: { [DriverState]: QueueMemo } = setmetatable({}, { __mode = "k" }) :: any
local function getNearestQueueLeader(state: DriverState): (DriverState?, number?)
	local memo = _queueMemo[state]
	local onConn = state.connector ~= nil
	if memo and memo.epoch == _queueEpoch and memo.edgeId == state.edgeId and memo.edgeDist == state.edgeDist
		and memo.conn == onConn and memo.connDist == state.connDist then
		return memo.lead, memo.gap
	end
	local lead, gap = findQueueLeader(state)
	if not memo then
		memo = {} :: any
		_queueMemo[state] = memo :: QueueMemo
	end
	local m = memo :: QueueMemo
	m.epoch, m.edgeId, m.edgeDist, m.connDist, m.conn, m.lead, m.gap =
		_queueEpoch, state.edgeId, state.edgeDist, state.connDist, onConn, lead, gap
	return lead, gap
end

function findQueueLeader(state: DriverState): (DriverState?, number?)
	local laneId = if state.connector then state.nextEdgeId else state.edgeId
	if not laneId then return nil, nil end
	local myPos = lanePos(state, laneId)
	local nearest, nearestGap = queueScan(_edgeDriverIndex[laneId], state, laneId, myPos, false, nil, math.huge)
	nearest, nearestGap = queueScan(_connectorByNextEdgeIndex[laneId], state, laneId, myPos, true, nearest, nearestGap)
	nearest, nearestGap = queueScan(_laneChangeIndex[laneId], state, laneId, myPos, true, nearest, nearestGap)
	-- Inside the box, a car that left OUR lane ahead of us is still in front of us: all the way
	-- through when it takes our exit, until its tail clears when it takes another (below).
	-- Both measure from the same lane mouth, so distance along the connector compares.
	if state.connector and not laneChangeOf(state) then
		-- The paths out of one lane part within a car length: one car going on, the other
		-- turning off. So one heading for another exit is in the way only until its tail
		-- clears; after that the proximity clamp stops us if its body really is across our
		-- path. Waiting for the whole of its turn locked a busy ring solid, and at a junction
		-- it froze a car going straight in the middle of the box behind a turner stuck on a
		-- full exit -- with open road ahead, and read as "traffic", so never rescued.
		for _, other in _connectorByFromEdgeIndex[state.edgeId] or {} do
			if other == state or not other.model.Parent then continue end
			if other.nextEdgeId ~= state.nextEdgeId
				and other.connDist - state.connDist > (other.halfLength or STOP_LINE_CAR_BUFFER) + 1 then
				continue
			end
			local gap = other.connDist - state.connDist
			local tied = math.abs(gap) <= QUEUE_TIE_EPSILON and goesFirst(other, state)
			if (gap > QUEUE_TIE_EPSILON or tied) and gap < nearestGap then
				nearestGap = math.max(0, gap)
				nearest = other
			end
		end
	end
	-- The same holds for a car that has already left our lane (the one we are on, or landing
	-- on) into the junction ahead: it is in front of us until it is through. The gap runs to
	-- where it left the lane plus how far along its connector it has got. Without this, a car
	-- coming to the end of a lane where nothing makes it stop -- a join, a bend, a short arc
	-- of a roundabout ring between two entries -- found the slow car ahead only by the late
	-- proximity check, and drove into it.
	-- One heading somewhere else is in the way only until its tail has cleared the lane
	-- mouth: past that its path has left ours. Holding on for it longer locked a busy
	-- roundabout solid -- a car leaving the ring waited on one carrying on round it, which
	-- waited on the car ahead of it, all the way round.
	local myNext: string? = if state.connector
		then (if state.route then state.route[(state.routeIndex or 1) + 2] else nil)
		else state.pendingNextEdgeId
	for _, other in _connectorByFromEdgeIndex[laneId] or {} do
		if other == state or not other.model.Parent then continue end
		if other.nextEdgeId ~= myNext and (other.connDist or 0) > (other.halfLength or STOP_LINE_CAR_BUFFER) + 1 then continue end
		local gap = (other.edgeDist - myPos) + (other.connDist or 0)
		if gap > QUEUE_TIE_EPSILON and gap < nearestGap then
			nearestGap = gap
			nearest = other
		end
	end

	-- A narrowing road squeezes its lanes together before the join. Order cars by
	-- distance to their shared exit while they still have room to form one queue.
	if not state.connector then
		local g = nav()
		local edge = g and g:GetEdge(laneId)
		local nextId = if state.route then state.route[(state.routeIndex or 1) + 1] else state.pendingNextEdgeId
		local exit = nextId and g and g:GetEdge(nextId)
		if edge and exit and edge.segmentId ~= exit.segmentId and not edge.isRoundabout
			and (edge.laneCountInDirection or 1) > (exit.laneCountInDirection or 1)
			and not isIntersectionNode(g, edge.toNode) then
			local remaining = edge.length - myPos
			local lookahead = RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH
				+ math.max(FOLLOW_MIN_GAP * 2, (state.currentSpeed or 0) * 2)
			if remaining <= lookahead then
				local mergePos = -remaining
				nearest, nearestGap = queueScan(_edgeDriverIndex[nextId], state, nextId, mergePos, false, nearest, nearestGap)
				nearest, nearestGap = queueScan(_connectorByNextEdgeIndex[nextId], state, nextId, mergePos, true, nearest, nearestGap)
				for _, incoming in g._edgesByToNode[edge.toNode] or EMPTY do
					if incoming.id == laneId or incoming.segmentId ~= edge.segmentId then continue end
					for _, other in _edgeDriverIndex[incoming.id] or EMPTY do
						if other == state or other.connector or not other.model.Parent then continue end
						local otherNext = if other.route then other.route[(other.routeIndex or 1) + 1] else other.pendingNextEdgeId
						if otherNext ~= nextId then continue end
						local gap = remaining - (incoming.length - other.edgeDist)
						local tied = math.abs(gap) <= QUEUE_TIE_EPSILON and goesFirst(other, state)
						if (gap > QUEUE_TIE_EPSILON or tied) and math.max(0, gap) < nearestGap then
							nearest, nearestGap = other, math.max(0, gap)
						end
					end
				end
			end
		end
	end
	return nearest, if nearest then nearestGap else nil
end

-- Two cars each other's blocker: nose to nose or locked across each other in a box. No
-- traffic can ever clear that, so it is a fault, not a jam. Same for a box locked three or
-- four ways round, each car across the next one's path: follow who holds whom and see if it
-- comes back to us.
local function inMutualStandoff(state: DriverState): boolean
	local blocker = state.blockedBy
	local other = if blocker then _drivers[blocker] else nil
	if other == nil then return false end
	if other.blockedBy == state.model
		or ((other.currentSpeed or 0)<0.5 and getNearestQueueLeader(other)==state) then
		return true
	end
	for _ = 1, Tuning.STANDOFF_CHAIN_HOPS do
		local nextBlocker = other.blockedBy
		local nextState = if nextBlocker then _drivers[nextBlocker]
			elseif (other.currentSpeed or 0) < 0.5 then getNearestQueueLeader(other)
			else nil
		if nextState == nil then return false end
		if nextState == state then return true end
		other = nextState
	end
	return false
end

-- Which of two cars locked into each other creeps through. Never the one whose blocker is
-- its own queue leader (it is behind that car, not across it), and never one still behind
-- its line against one already in the box (the line holds it anyway): the bare name
-- tie-break picked those, and the pair sat there until the stall watchdog, again and again.
local function winsStandoff(state: DriverState, other: DriverState): boolean
	if getNearestQueueLeader(state) == other then return false end
	if getNearestQueueLeader(other) == state then return true end
	if (state.connector == nil) ~= (other.connector == nil) then return state.connector ~= nil end
	return goesFirst(state, other)
end

-- Standing still for a reason a driver would recognise: in a queue behind another car, at a
-- red, waiting for a gap or a merge, held by a full exit, or blocked by a car that is itself
-- held up. A jam is traffic, not a fault -- it stays until the player fixes the road, so
-- none of these ever counts toward a rescue. A blocker with no driver behind it is not
-- traffic: nothing will ever move it out of the way.
local function waitingInTraffic(state: DriverState): boolean
	local blocker = state.blockedBy
	if blocker then
		-- Parking manoeuvres and a trip waiting to replan still occupy the road.
		if not _drivers[blocker] then
			return blocker.Parent ~= nil and PathFollower.isRegistered(blocker)
		end
		return not inMutualStandoff(state)
	end
	local reason = state.stopReason
	if reason == "carAhead" or reason == "redLight" or reason == "laneChange" or reason == "merge"
		or reason == "yield" or reason == "blocked" or reason == "noExit" then
		return true
	end
	return getNearestQueueLeader(state) ~= nil
end

local function stallWatchdog(state: DriverState, dt: number)
	local pos = getStatePosition(state)
	local from = state.rescueFrom
	if from and (pos - from).Magnitude > Tuning.RESCUE_CLEAR_DIST then
		state.rescueFrom = nil
	end
	local last = state.lastProgressPos
	if not last or (pos - last).Magnitude > Tuning.STALL_MOVE_EPSILON or waitingInTraffic(state) then
		state.lastProgressPos = pos
		state.noProgressTime = 0
		state.rescueCount = 0
		return
	end
	state.noProgressTime = (state.noProgressTime or 0) + dt
	if (state.noProgressTime or 0) < STALL_RESCUE_TIME then
		return
	end
	dumpStall(state)
	if state.route then
		-- A routed car truly wedged (not queued -- see waitingInTraffic): re-plan the same
		-- trip from the lane it is on and creep past whatever gated it. Only a car with no
		-- lane or no path left is handed back.
		state.noProgressTime = 0
		state.lastProgressPos = nil
		if tryReroute(state) then
			state.rescueFrom = getStatePosition(state)
		else
			abortDirected(state)
		end
		return
	end
	state.noProgressTime = 0
	state.lastProgressPos = nil
	state.rescueCount = (state.rescueCount or 0) + 1

	local g = nav()
	if not g or not g:HasEdges() then return end

	if state.rescueCount >= 2 then
		-- Re-seating did not free it: move the car to a random edge, away from
		-- whatever it is wedged into.
		local edges = g:GetEdges()
		local e = edges[math.random(1, #edges)]
		state.edgeId       = e.id
		state.edgeDist     = 0
		state.graphVersion = g:Version()
		state.connector    = nil
		state.connCum      = nil
		state.connDist     = 0
		state.connSpeedCap = nil
		state.connBlockedTime = 0
		state.nextEdgeId   = nil
		state.nextEdgeDist = 0
		state.pendingNextEdgeId = nil
		state.atDeadEnd    = false
		state.deadEndTimer = 0
		state.blockedTime  = 0
		state.stuckTime    = 0
		state.currentSpeed = 0
		local cum = PathFollower.getCum(e)
		local p, d = PathFollower.pointAtDist(e.points, cum, 0)
		state.smoothCFrame = nil
		PathFollower.place(state, p, d)
		return
	end

	-- First rescue: clear every bit of maneuver state, re-seat on the nearest
	-- lane, and let it push past whatever gated it.
	state.connector = nil
	state.connCum = nil
	state.connDist = 0
	state.connSpeedCap = nil
	state.atDeadEnd = false
	state.deadEndTimer = 0
	anchorToNearest(state)
	if state.model.Parent then
		state.rescueFrom = getStatePosition(state)
	end
end

local function getNearestQueueGap(state: DriverState): number?
	local _, gap = getNearestQueueLeader(state)
	return gap
end


local function updateTrafficReroute(state: DriverState, dt: number)
	local route = state.route
	-- A line bus (keepRoute) sits in the queue like a real bus: no traffic reroute.
	if not route or state.connector or (state.routeIndex or 1) >= #route or (state.profile and state.profile.keepRoute) then
		state.trafficJamTime = 0
		return
	end

	local g = nav()
	local edge = g and g:GetEdge(state.edgeId)
	local speedLimit = if edge then edgeSpeed(edge) else state.speed
	local slowEnough = (state.currentSpeed or 0) <= math.max(2, speedLimit * Tuning.CONGESTION_JAM_SPEED_RATIO)
	local reason = state.stopReason
	-- The queue scan only when it decides anything: a slow car held for "blocked".
	local trafficBlocked = slowEnough
		and (reason == "carAhead" or (reason == "blocked" and getNearestQueueGap(state) ~= nil))

	if trafficBlocked then
		state.trafficJamTime = (state.trafficJamTime or 0) + dt
	else
		state.trafficJamTime = math.max(0, (state.trafficJamTime or 0) - dt * 2)
		return
	end

	-- Patience is personal: some drivers reach for an alternative after a few seconds
	-- in a queue, others sit through it. Same jam, different reactions -- which is what
	-- keeps a blocked road from emptying all at once into the same side street.
	local profile = state.profile
	local jamThreshold = Tuning.TRAFFIC_REROUTE_JAM_TIME * (if profile then profile.patience else 1)
	local now = os.clock()
	if (state.trafficJamTime or 0) < jamThreshold
		or now < (state.nextTrafficRerouteAt or 0) then
		return
	end
	-- Each search is a whole A* (~7 ms measured in the lab). A jam makes many drivers impatient
	-- in the same second; without a shared budget their searches landed in one frame. Over
	-- budget, the driver simply asks again on a later tick -- its patience is already spent.
	if RerouteBudget.tokens < 1 then return end
	RerouteBudget.tokens -= 1

	-- Cool down failed attempts too. A dense queue may have no alternate road, and
	-- repeated A* searches every driver tick would turn the cure into its own spike.
	state.nextTrafficRerouteAt = now + TRAFFIC_REROUTE_COOLDOWN
	state.trafficJamTime = 0
	tryTrafficReroute(state)
end

-- Distance to the closest car BEHIND us on the same edge (nil if none). Used to
-- ensure the unstuck back-up never reverses into a trailing car, which was
-- producing locked, overlapping pairs.
local function getNearestTrailing(state: DriverState): (DriverState?, number?)
	if state.connector then return nil, nil end
	local nearest = math.huge
	local driver: DriverState? = nil
	for _, other in ipairs(_edgeDriverIndex[state.edgeId] or {}) do
		if other ~= state and other.model.Parent and not other.connector then
			local gap = state.edgeDist - other.edgeDist
			if gap > QUEUE_TIE_EPSILON and gap < nearest then
				nearest = gap
				driver = other
			end
		end
	end
	return driver, if driver then nearest else nil
end

local function resolveQueueSpacing(state: DriverState, edge: any, cum: { number }, dt: number)
	-- Backing up moves a car along its lane; mid lane change it is on neither centreline.
	if state.connector then return end
	local lead, gap = getNearestQueueLeader(state)
	local minGap = followGap(state, lead)
	if not gap or gap >= minGap then
		return
	end

	local backup = math.min(minGap - gap, Tuning.UNSTUCK_BACKUP_RATE * dt)
	-- Never reverse into the car behind us -- and its own length decides how close that is.
	local trailer, trailing = getNearestTrailing(state)
	if trailer and trailing then
		backup = math.min(backup, math.max(0, trailing - followGap(trailer, state)))
	end
	if backup <= 1e-4 then
		return
	end

	local oldDist = state.edgeDist
	state.edgeDist = math.max(0, state.edgeDist - backup)
	if state.edgeDist < oldDist - 1e-4 then
		state.currentSpeed = 0
		local pos, dir = PathFollower.pointAtDist(edge.points, cum, state.edgeDist)
		PathFollower.place(state, pos, dir, dt)
	end
end

local function getQueueSpeedFactor(nearestGap: number?, currentSpeed: number, minGap: number): number
	if not nearestGap then
		return 1
	end
	if nearestGap <= minGap then
		return 0
	end

	local lookahead = math.max(Tuning.FOLLOW_LOOKAHEAD, currentSpeed * 0.8)
	if nearestGap >= lookahead then
		return 1
	end

	local t = (nearestGap - minGap) / math.max(lookahead - minGap, 1)
	return math.clamp(t * t, 0, 1)
end

-- Vehicle half-length (centre to nose), read from its Hitbox so long trucks stop the
-- same distance before the line as short cars instead of overrunning it.
local function vehicleHalfLength(model: Model): number
	local sz = model:GetExtentsSize()
	return math.max(sz.X, sz.Z) * 0.5
end

-- A DIRECTED car that leaves at the map edge did not arrive -- it lost its route on the
-- way (getPendingNextEdgeId falls through to the roamer pick when the route's next edge
-- is not an exit of the lane the car is on). Letting it leave is right; being NOISY about
-- it is how the desync itself stays visible. Silence is the normal state.
local _lostRouteExits = 0
local _lastLostRouteWarn = 0
local LOST_ROUTE_WARN_INTERVAL = 60

-- == Mid-block lane changes ====================================================
-- NavRouter plans a step onto a neighbouring lane of the same road wherever the lane line
-- is dashed. The driver makes it as soon as the window opens (just past the last junction)
-- and the target lane has room, so it is lined up for its turn long before the stop line
-- instead of swerving across at the last second. With no gap it holds at the end of the
-- window. Room is never faked: waiting trims only the speed margin a car leaves, never the
-- car length it needs. The target lane makes the room instead -- the first car behind a
-- waiting merger that can still stop does, and lets it in (a zipper).
-- One table, not eight locals: this chunk sits at Luau's 200-local limit (see CitizenService).
local LaneChange = table.freeze({
	TIME = 2.2,            -- s a move-over takes at cruise speed (sets its length)
	KEEP_SPEED = 0.9,      -- a move whose bend cap is below this share of the car's speed is too short to start
	HOLD_SPEED = 16 * WS,  -- studs/s: on a highway, faster than this a car out of window re-plans instead of stopping
	HOLD_DECEL = 28 * WS,  -- studs/s^2 a car brakes at into the hold point of a lane change it has no gap for
	PATIENCE = 8,          -- s of waiting over which the speed margin shrinks to its floor
	REPLAN = 10,           -- s trying with no gap at all before re-planning from this lane
	MERGE_COURTESY_WAIT = 1, -- s a merger waits before the lane beside it makes room
	MERGE_ROOM = 1,        -- studs past a follow gap a yielding car leaves, so the merger's check passes
	SWAP_PULL_UP_MAX = 14, -- studs past the window end a swap winner may pull up (lands <= 7 into the solid zone)
	-- The steepest a car's heading may swing off its lane while moving over: gentle at speed,
	-- as a real lane change is (a few degrees on a motorway), steeper only at a crawl. The
	-- ribbon is a smoothstep, whose steepest point is 1.5x its average slope, so a move of
	-- `lateral` studs needs at least 1.5 * lateral / tan(angle) of road. Before this a slow or
	-- held car got 7-14 studs to cross a whole lane -- a sideways hop at ~60-90 degrees.
	MAX_ANGLE_SLOW = math.rad(24), -- at a standstill
	MAX_ANGLE_FAST = math.rad(6),  -- at FAST_SPEED and above
	FAST_SPEED = 50 * WS,          -- studs/s (~90 km/h)
})

-- Shortest stretch of road a move of `lateral` studs sideways may take at `speed`.
local function laneChangeMinLength(lateral: number, speed: number): number
	local t = math.clamp(speed / LaneChange.FAST_SPEED, 0, 1)
	local angle = LaneChange.MAX_ANGLE_SLOW + (LaneChange.MAX_ANGLE_FAST - LaneChange.MAX_ANGLE_SLOW) * t
	return 1.5 * lateral / math.tan(angle)
end

-- How much earlier than the window's end a car waiting to move over stops, so that the gentle
-- move it makes from a standstill lands where the old 7-stud hop did -- short of the stop line.
local function laneChangeHoldBack(g: any, edge: any, targetId: string): number
	local target = g:GetEdge(targetId)
	if not target then return 0 end
	local lateral = math.abs((edge.offset or 0) - (target.offset or 0))
	return math.max(0, laneChangeMinLength(lateral, 0) - (g.LANE_CHANGE_MIN_LENGTH or 14) * 0.5)
end

-- The route's next step when it is a lane change on this road: target lane plus the stretch
-- of this lane over which the move may start. nil when the next step is a junction.
local function routeLaneChange(g: any, state: DriverState, edge: any): (string?, number, number)
	local route = state.route
	if not route then return nil, 0, 0 end
	local nextId = route[(state.routeIndex or 1) + 1]
	if not nextId then return nil, 0, 0 end
	local earliest, latest = g:GetLaneChangeWindow(edge.id, nextId)
	if not earliest or not latest then return nil, 0, 0 end
	return nextId, earliest, latest
end

-- Room on the target lane between [d0, d1] (our start and landing distances): nobody from a
-- follow gap plus a speed margin behind us to a follow gap past where we land, nobody mid-move
-- through that stretch, nobody turning into it. Second return: a blocker that is itself
-- waiting for OUR lane -- a swap, which only the tie-break in waitForMerge can undo.
local function laneChangeGapClear(state: DriverState, targetId: string, d0: number, d1: number): (boolean, DriverState?)
	local squeeze = math.max(0.35, 1 - (state.laneChangeWait or 0) / LaneChange.PATIENCE)
	local clear = true
	for _, other in _edgeDriverIndex[targetId] or {} do
		if other ~= state and other.model.Parent then
			local p = lanePos(other, targetId)
			local behind = followGap(other, state) + (other.currentSpeed or 0) * 1.2 * squeeze
			-- A car STANDING behind our start only needs its bumper kept clear: we pull off
			-- ahead of it and it is not coming at us. Without this two stopped cars side by
			-- side, each waiting for the other's lane, could never untangle -- the one in
			-- front was always "too close" to the one behind.
			if p <= d0 and (other.currentSpeed or 0) < 0.5 then
				behind = (other.halfLength or 0) + (state.halfLength or 0) + FOLLOW_BUMPER
			end
			if p > d0 - behind and p < d1 + followGap(state, other) then
				if other.mergeInto == state.edgeId then return false, other end
				clear = false
			end
		end
	end
	if not clear then return false, nil end
	for _, other in _laneChangeIndex[targetId] or {} do
		if other ~= state and other.model.Parent and laneChangeOf(other) then
			local p = lanePos(other, targetId)
			if p > d0 - followGap(other, state) and p < d1 + followGap(state, other) then
				return false, nil
			end
		end
	end
	for _, other in _connectorByNextEdgeIndex[targetId] or {} do
		if other ~= state and other.model.Parent
			and math.abs(other.nextEdgeDist - d1) < (d1 - d0) + followGap(state, other) then
			return false, nil
		end
	end
	return true, nil
end

-- Third return: true when what is left of this road piece is too short to move over at the
-- car's speed -- the squeezed ribbon's bend cap would brake it across both lanes. That is a
-- geometry refusal, not a missing gap, so the lane beside is not asked to make room.
local function tryStartLaneChange(g: any, state: DriverState, edge: any, targetId: string, latest: number): (boolean, DriverState?, boolean)
	local target = g:GetEdge(targetId)
	if not target then return false, nil, false end
	local minLength = g.LANE_CHANGE_MIN_LENGTH or 14
	local fromCum = PathFollower.getCum(edge)
	local toCum = PathFollower.getCum(target)
	-- Land no nearer the junction than the window's own shortest move would.
	local margin = math.max(0, fromCum[#fromCum] - latest - minLength)
	local d0 = state.edgeDist
	local speed = state.currentSpeed or 0
	local lateral = math.abs((edge.offset or 0) - (target.offset or 0))
	local gentle = laneChangeMinLength(lateral, speed)
	local length = math.max(minLength, gentle, speed * LaneChange.TIME)
	-- A car held past the window end (swap winner, re-plan) still gets a move it can make
	-- without swerving: never shorter than the gentle length at a crawl.
	local shortest = d0 + math.max(minLength * 0.5, laneChangeMinLength(lateral, 0))
	local d1 = math.clamp(d0 + length, shortest, math.max(shortest, toCum[#toCum] - margin))
	-- The first half of the move still runs forward in THIS lane. Started with a car stopped
	-- close in front, it stalled half across -- blocking both lanes until that queue moved.
	-- Queued like that it is simply in traffic, not waiting to merge: no courtesy request yet.
	local lead, leadGap = getNearestQueueLeader(state)
	if lead and leadGap and leadGap < followGap(state, lead) + (d1 - d0) * 0.5 then
		state.laneChangeWait = 0
		return false, nil, false
	end
	local pts = g:GetLaneChangeRibbon(edge.id, targetId, d0, d1)
	local cap = connectorSpeedCap(pts)
	if cap and cap < (state.currentSpeed or 0) * LaneChange.KEEP_SPEED then
		return false, nil, true
	end
	local clear, swapWith = laneChangeGapClear(state, targetId, d0, d1)
	if not clear then return false, swapWith, false end
	startConnector(state, pts, targetId, d1)
	state.laneChange = if state.connector == pts
		then { pts = pts, from = edge.id, to = targetId, d0 = d0, d1 = d1 }
		else nil
	state.laneChangeWait = 0
	state.mergeInto = nil
	state.mergeHoldAt = nil
	tagCarInfo(state, "ChangingLane", targetId)
	return true, nil, false
end

-- Too little of this piece left to move over at speed: make the move on the next piece of
-- the road instead, from the start of its window, the way a driver who missed the gap tries
-- again further on. Only when the route carries on along the target lane onto a next piece
-- this lane also feeds, and that piece allows the same move. The route is copied, never
-- edited in place: a caller may hold the table it passed to DriveDirected.
local function deferLaneChange(g: any, state: DriverState, edge: any, targetId: string): boolean
	local route = state.route
	local i = state.routeIndex or 1
	if not route or route[i + 1] ~= targetId then return false end
	local afterId = route[i + 2]
	local after = if afterId then g:GetEdge(afterId) else nil
	if not after or after.segmentId == edge.segmentId then return false end
	for _, outId in edge.out do
		local stay = g:GetEdge(outId)
		if stay and stay.segmentId == after.segmentId and stay.forward == after.forward
			and edgeAllows(stay, state.vehicleClass) and g:GetLaneChangeWindow(outId, afterId) then
			local deferred = table.clone(route)
			deferred[i + 1] = outId
			state.route = deferred
			state.pendingNextEdgeId = nil
			bookRoute(state)
			return true
		end
	end
	return false
end

-- Which of two cars each waiting for the other's lane goes first: the one further along --
-- it merges in front of the other without having to pull past it (which it may have no road
-- left to do, at the end of the window). Level, the unique id decides.
local function swapGoesFirst(a: DriverState, b: DriverState): boolean
	local da, db = a.edgeDist or 0, b.edgeDist or 0
	if math.abs(da - db) > 1 then return da > db end
	return goesFirst(a, b)
end

-- A move refused this tick: count the wait, ask the lane beside to make room, and settle a
-- swap. Two cars side by side each waiting for the other's lane can never both go; the
-- tie-break winner pulls up past the other and merges in front of it, freeing the loser's gap.
local function waitForMerge(state: DriverState, targetId: string, latest: number, swapWith: DriverState?, dt: number)
	state.laneChangeWait = (state.laneChangeWait or 0) + dt
	if (state.laneChangeWait or 0) >= LaneChange.MERGE_COURTESY_WAIT then
		state.mergeInto = targetId
	end
	if swapWith and not swapWith.connector and swapGoesFirst(state, swapWith) then
		local g = nav()
		local edge = g and g:GetEdge(state.edgeId)
		local holdBack = if g and edge then laneChangeHoldBack(g, edge, targetId) else 0
		state.mergeHoldAt = math.min(lanePos(swapWith, targetId) + followGap(state, swapWith) + LaneChange.MERGE_ROOM,
			latest - holdBack + LaneChange.SWAP_PULL_UP_MAX)
	end
end

-- Zipper: the nearest car waiting to merge into this lane that we can still stop behind (a
-- follow gap or more ahead), as a stand-in leader held LaneChange.MERGE_ROOM short of it. One nearer
-- than that is passed; the car behind us lets it in.
local function getMergeCourtesy(state: DriverState): (DriverState?, number?)
	if state.connector then return nil, nil end
	local merger: DriverState? = nil
	local best = math.huge
	for _, other in _laneChangeIndex[state.edgeId] or {} do
		if other ~= state and other.mergeInto == state.edgeId and not other.connector and other.model.Parent then
			local ahead = other.edgeDist - state.edgeDist
			if ahead >= followGap(state, other) and ahead < best then
				best = ahead
				merger = other
			end
		end
	end
	local gap = if merger then best - LaneChange.MERGE_ROOM else nil
	-- A driveway car's gap request (RequestRoadGap): hold with our centre at `stop`, as if a
	-- car stood one FOLLOW_MIN_GAP beyond it. Only while we can still pull up short of it.
	local byCar = Gridlock.gapLanes[state.edgeId]
	if byCar then
		local now = os.clock()
		local speed = state.currentSpeed or 0
		local brake = speed * speed / (2 * Tuning.BRAKE_RATE)
		for vehicle, req in byCar do
			if now - req.at > Tuning.GAP_REQUEST_TTL then
				NPCDriverService.ClearRoadGap(vehicle) -- its owner stopped asking
				continue
			end
			local stop = req.lanes[state.edgeId] - req.room - (state.halfLength or STOP_LINE_CAR_BUFFER)
			local ahead = stop - state.edgeDist
			if ahead < brake - 0.5 or vehicle == state.model or not vehicle.Parent then continue end
			if not gap or ahead + FOLLOW_MIN_GAP < gap then
				gap = ahead + FOLLOW_MIN_GAP
				merger = nil
			end
		end
	end
	return merger, gap
end

-- == Lane discipline (highways) ================================================
-- The rule, as the player set it:
--   * A car may stay in its lane -- the kerbside (right) lane included -- for as long as the
--     car behind it is no faster than it is.
--   * When a FASTER car closes on it from behind, it moves over so the faster car can keep
--     going straight: out of the kerbside lane that is to the left; from any other lane it is
--     back toward the kerb when that lane is free (keep right), otherwise further left.
--   * Once it has been passed it may go back: to the kerbside lane, or to a middle lane for a
--     quicker driver on a road of 3+ lanes (the middle lanes are for cruising) -- and only
--     into a lane where nothing faster is closing from behind, so it never cuts one off.
--   * A car held behind a slower one that could NOT step aside (the lane beside was full)
--     passes it on the left itself after OVERTAKE_PATIENCE.
-- The route decides lanes, so every move is a re-plan from the lane beside -- taken only when
-- it costs next to nothing, which is also what keeps a car that needs the next exit in the
-- lane it needs.
local Discipline = table.freeze({
	LOOK_EVERY = 2,            -- s between a car's looks at its lane
	YIELD_BEHIND = 100 * WS,   -- studs behind a car it watches for faster traffic...
	YIELD_TIME = 3,            -- ...or this many seconds of road at its speed, whichever is more
	YIELD_MARGIN = 0.05,       -- a car behind counts as faster when it wants to go this much quicker
	OVERTAKE_AHEAD = 70 * WS,  -- studs: a slower car this close ahead is holding us up...
	OVERTAKE_MARGIN = 0.08,    -- ...when it is at least this much slower than we want to go
	OVERTAKE_PATIENCE = 4,     -- s held up before we pass it ourselves (it could not move over)
	RETURN_CLEAR = 90 * WS,    -- studs of the lane we move back into that must hold nobody slower...
	RETURN_TIME = 4,           -- ...or this many seconds of it at our speed, whichever is more
	SETTLE = 5,                -- s after a move before the car considers another
	FAST_DRIVER = 0.99,        -- speedFactor above which a car cruises in a middle lane (about half)
	EXIT_CLEAR = 400 * WS,     -- studs before the car leaves the highway (or ends its trip) with no moves
	KEEP_LANE = 300 * WS,      -- a move whose plan changes lane again sooner than this is not taken
	MAX_EXTRA_SECONDS = 6,     -- the plan from the lane beside may cost this much more than ours
})

-- The slowest car in `laneId` between `from` and `to` (distances along it), or nil.
local function slowestIn(laneId: string, from: number, to: number, except: DriverState): number?
	local slowest: number? = nil
	for _, bucket in { _edgeDriverIndex[laneId], _connectorByNextEdgeIndex[laneId] } do
		for _, other in bucket or EMPTY do
			if other == except or not other.model.Parent then continue end
			local p = lanePos(other, laneId)
			if p > from and p < to then
				local v = other.currentSpeed or 0
				if not slowest or v < slowest then slowest = v end
			end
		end
	end
	return slowest
end

-- True when a car that wants to go faster than `mySpeed` (desired, studs/s) is in `lane`
-- between `range` studs behind `pos` and `pos`, and is not falling back. Looks back onto the
-- lane that runs straight into this one too: the highway is a chain of pieces.
local function fasterBehind(g: any, lane: any, pos: number, range: number, mySpeed: number, except: DriverState): boolean
	local function check(laneId: string, laneEdge: any, from: number, to: number): boolean
		for _, bucket in { _edgeDriverIndex[laneId], _connectorByNextEdgeIndex[laneId] } do
			for _, other in bucket or EMPTY do
				if other == except or not other.model.Parent then continue end
				local p = lanePos(other, laneId)
				if p > from and p < to
					and driverSpeed(laneEdge, other) > mySpeed * (1 + Discipline.YIELD_MARGIN)
					and (other.currentSpeed or 0) >= (except.currentSpeed or 0) * 0.95 then
					return true
				end
			end
		end
		return false
	end
	if check(lane.id, lane, pos - range, pos) then return true end
	local short = range - pos
	if short > 0 then
		for _, inE in g._edgesByToNode[lane.fromNode] or EMPTY do
			if inE.outMovement and inE.outMovement[lane.id] == "straight" and inE.length
				and check(inE.id, inE, inE.length - short, inE.length + 1) then
				return true
			end
		end
	end
	return false
end

-- Studs of highway ahead on the route before it leaves the highway or ends. Lane-change steps
-- (two lanes of one road piece in a row) are counted once.
local function highwayLeft(g: any, route: { string }, index: number, edgeDist: number): number
	local total = -edgeDist
	local prevSeg: any = nil
	for i = index, #route do
		local e = g:GetEdge(route[i])
		if not e or e.roadClass ~= "highway" then break end
		if e.segmentId ~= prevSeg then
			total += e.length or 0
			prevSeg = e.segmentId
		end
		if total >= Discipline.EXIT_CLEAR then break end
	end
	return total
end

local function tryLaneDiscipline(g: any, state: DriverState, edge: any)
	local route = state.route
	if not route or not state.goalPos or edge.roadClass ~= "highway" or not edge.laneChangeOk
		or (edge.laneCountInDirection or 1) < 2 then
		return
	end
	if _simClock < (state.nextLaneLook or 0) then return end
	state.nextLaneLook = _simClock + Discipline.LOOK_EVERY * (0.75 + math.random() * 0.5)
	-- Near the exit (or the end of the trip) a driver gets in lane and stays there.
	if highwayLeft(g, route, state.routeIndex or 1, state.edgeDist) < Discipline.EXIT_CLEAR then return end

	local desired = driverSpeed(edge, state)
	local speed = state.currentSpeed or 0
	local ord = edge.laneOrdinal
	local count = edge.laneCountInDirection
	local myPos = state.edgeDist
	local lookBack = math.max(Discipline.YIELD_BEHIND, speed * Discipline.YIELD_TIME)
	local clearAhead = math.max(Discipline.RETURN_CLEAR, speed * Discipline.RETURN_TIME)

	local lanes: { [number]: any } = {}
	for _, id in g:GetLaneChangeTargets(edge.id) do
		local e = g:GetEdge(id)
		if e and edgeAllows(e, state.vehicleClass) then lanes[e.laneOrdinal] = e end
	end
	-- A lane we could move into here, with nothing faster coming up behind us in it.
	local function open(o: number): any?
		local e = lanes[o]
		if not e then return nil end
		local earliest, latest = g:GetLaneChangeWindow(edge.id, e.id)
		if not earliest or not latest or myPos > latest then return nil end
		if fasterBehind(g, e, myPos, lookBack, desired, state) then return nil end
		return e
	end

	local lead, gap = getNearestQueueLeader(state)
	local leadSpeed = if lead then (lead.currentSpeed or 0) else math.huge
	local heldUp = lead ~= nil and gap ~= nil and gap < Discipline.OVERTAKE_AHEAD
		and leadSpeed < desired * (1 - Discipline.OVERTAKE_MARGIN)
	if heldUp then
		state.heldUpSince = state.heldUpSince or _simClock
	else
		state.heldUpSince = nil
	end

	local target: any? = nil
	local kind = "back"
	if fasterBehind(g, edge, myPos, lookBack, desired, state) then
		kind = "yield"
		-- Let it through: out of the kerbside lane to the left; from any other lane back
		-- toward the kerb if that is free, else on to the left.
		if ord == count then
			target = open(ord - 1)
		else
			target = open(ord + 1) or (if ord > 1 then open(ord - 1) else nil)
		end
		-- Never into a lane where we would sit right behind something slower.
		if target and (slowestIn(target.id, myPos - followGap(state, nil), myPos + Discipline.OVERTAKE_AHEAD, state) or math.huge)
			< speed * 0.9 then
			target = nil
		end
	elseif heldUp and ord > 1 and _simClock - (state.heldUpSince or _simClock) >= Discipline.OVERTAKE_PATIENCE then
		-- The car ahead could not move over: pass it on the left, into a lane moving better.
		kind = "pass"
		local e = open(ord - 1)
		local there = e and slowestIn(e.id, myPos - followGap(state, nil), myPos + Discipline.OVERTAKE_AHEAD * 1.5, state)
		if e and not (there and there <= leadSpeed * 1.05) then target = e end
	else
		-- Passed (or nobody behind): back toward the lane this driver cruises in, when it is
		-- free a good way ahead.
		local fast = (if state.profile then state.profile.speedFactor else 1) > Discipline.FAST_DRIVER
		local home = if fast and count >= 3 then count - 1 else count
		if ord < home then
			local e = open(ord + 1)
			local there = e and slowestIn(e.id, myPos - followGap(state, nil), myPos + clearAhead, state)
			if e and not (there and there < desired * 0.95) then target = e end
		end
	end
	if not target then return end

	local lateral = math.abs((edge.offset or 0) - (target.offset or 0))
	local earliest = g:GetLaneChangeWindow(edge.id, target.id)
	local landAt = math.max(myPos, earliest or myPos) + laneChangeMinLength(lateral, speed)
	local ok, _, tail = pcall(function()
		return g:FindPath(getStatePosition(state), state.goalPos, nil, state.vehicleClass, state.profile,
			{ edgeId = target.id, dist = landAt })
	end)
	if not ok or typeof(tail) ~= "table" or tail[1] ~= target.id then return end
	-- Not a move that has to be undone straight away (the plan from there changes lane again).
	do
		local run = -landAt
		for i = 1, #tail - 1 do
			local a, b = g:GetEdge(tail[i]), g:GetEdge(tail[i + 1])
			if not a or not b then break end
			run += a.length or 0
			if run >= Discipline.KEEP_LANE then break end
			if a.segmentId == b.segmentId then return end
		end
	end
	local index = state.routeIndex or 1
	local oldCost = g:EstimatePathCost(route, index, state.profile)
	local newCost = g:EstimatePathCost(tail, 1, state.profile)
	if oldCost == math.huge or newCost > oldCost + Discipline.MAX_EXTRA_SECONDS then return end

	local newRoute = table.move(route, 1, index, 1, {})
	table.move(tail, 1, #tail, index + 1, newRoute)
	state.route = newRoute
	state.pendingNextEdgeId = nil
	state.heldUpSince = nil
	state.laneDisciplineMoves = (state.laneDisciplineMoves or 0) + 1
	local kinds = state.laneMoveKinds or {}
	kinds[kind] = (kinds[kind] or 0) + 1
	state.laneMoveKinds = kinds
	state.nextLaneLook = _simClock + Discipline.SETTLE
	local lastEdge = g:GetEdge(newRoute[#newRoute])
	if lastEdge then state.finalDist = distAlongEdgeNearest(lastEdge, state.goalPos :: Vector3) end
	bookRoute(state)
end

-- == Per-vehicle tick ==========================================================
local function finishDirected(state: DriverState)
	state.arrived = true
	state.currentSpeed = 0
	local cb = state.onArrive
	state.onArrive = nil
	releaseBooking(state)
	leaveWhereItStands(state)
	clearDirectedDebugTag(state)
	unindexDriver(state)
	_drivers[state.model] = nil
	PathFollower.forget(state.model)
	if cb then task.spawn(cb) end
end

-- Road drivers use lane queues and junction admission for spacing. A second body-strip
-- check made waiting turns brake priority traffic and created cyclic physical blockers.
local function isRoadDrivenVehicle(model: Model, otherModel: Model): boolean
	local mine, other = _drivers[model], _drivers[otherModel]
	return mine ~= nil and other ~= nil and (mine.edgeId ~= other.edgeId or other.connector ~= nil)
end

local function updateDriver(state: DriverState, dt: number)
	local g = nav()
	if not g or not state.model.Parent then return end
	-- Everything else stands still while this car updates (see getNearestQueueLeader).
	_queueEpoch += 1

	local currentVersion = g:Version()
	if state.graphVersion ~= currentVersion then
		if _lastFlushedVersion ~= currentVersion then
			_lastFlushedVersion = currentVersion
			PathFollower.flushCache()
			clearGraphCaches()
		end
		-- ANY road edit bumps the GLOBAL graph version, even a road placed far away (the
		-- rebuild is incremental, so unrelated edges keep their ids). React only if THIS
		-- car's own road actually changed, so an unrelated placement doesn't disturb every
		-- car on the map.
		if state.connector and state.nextEdgeId and g:GetEdge(state.nextEdgeId) then
			-- Mid-turn and the landing edge survived: keep the arc.
			state.graphVersion = currentVersion
		elseif not state.connector and state.edgeId and g:GetEdge(state.edgeId) then
			-- Our current edge survived the edit: keep driving on it, just adopt the new
			-- version. Onward edges are re-derived as the car goes. Covers ambient AND
			-- directed cars whose own road was untouched, so an unrelated placement no
			-- longer resets every car on the map (the brief mid-road hitch on each edit).
			state.graphVersion = currentVersion
		elseif state.route then
			-- Directed car whose current edge (or mid-turn landing) vanished -- typically
			-- its road was replaced/upgraded under it. Re-plan from the nearest surviving
			-- lane to the same goal so it rejoins the new road instead of despawning the
			-- trip. Only abort if there is no lane in range or no path.
			if not tryReroute(state) then
				abortDirected(state)
				return
			end
		elseif not anchorToNearest(state) then
			-- Ambient roamer stranded by a deleted road: snap to the nearest lane, or
			-- despawn if nothing survived within range.
			return
		end
	end

	-- The current lane can survive a road edit while its next turn disappears.
	-- Revalidate the route before moving, including changes to vehicle restrictions.
	if state.route and not state.connector then
		local current = g:GetEdge(state.edgeId)
		local nextId = state.route[(state.routeIndex or 1) + 1]
		local nextEdge = if nextId then g:GetEdge(nextId) else nil
		if state.route[state.routeIndex or 1] ~= state.edgeId or not current
			or not edgeAllows(current, state.vehicleClass)
			or (nextId and (not nextEdge or not edgeAllows(nextEdge, state.vehicleClass)
				or (not edgeHasOutgoing(current, nextId) and not g:GetLaneChangeWindow(current.id, nextId)))) then
			if not tryReroute(state) then abortDirected(state) end
			return
		end
	end

	-- Arrival is a position condition, including a restored trip already at its goal.
	-- Zero clearance or speed must not prevent its owner receiving completion.
	if state.route and not state.connector and not state.arrived and (state.routeIndex or 1) >= #state.route then
		local current = g:GetEdge(state.edgeId)
		local cum = PathFollower.getCum(current)
		local goalDist = math.clamp(state.finalDist or cum[#cum], 0, cum[#cum])
		if state.edgeDist >= goalDist - 0.5 then
			finishDirected(state)
			return
		end
	end

	-- Jam rerouting stays (2026-10-01): with it off a queue at a city entrance never cleared
	-- and blocked every move-in. It is capped by the shared RerouteBudget, not per car.
	updateTrafficReroute(state, dt)

	-- Waiting at dead end
	if state.atDeadEnd then
		state.deadEndTimer -= dt
		if state.deadEndTimer > 0 then return end
		local edge = g:GetEdge(state.edgeId)
		if not edge then
			state.atDeadEnd = false
			return
		end
		if getPendingNextEdgeId(g, state, edge) then
			state.atDeadEnd = false
			state.deadEndTimer = 0
			return
		end
		local uEdge = getUTurnEdge(g, edge, state.vehicleClass)
		if uEdge then
			-- Wait until the exit is clear so cars turn one at a time instead of
			-- piling on top of each other at the dead end. A jammed return lane is
			-- traffic: the dead end waits as long as it does.
			if not canEnterIntersection(g, state, edge, uEdge.id) then
				state.blockedTime = (state.blockedTime or 0) + 0.25
				state.deadEndTimer = 0.25
				-- This branch skips the tick that records why the car is stopped; say it
				-- here, or the stall watchdog would take a jam for a fault.
				state.stopReason = "blocked"
				state.blockedBy = nil
				return
			end
			state.blockedTime = 0
			local connPts = buildUTurnArc(edge, uEdge)
			startConnector(state, connPts, uEdge.id, 0)
			tagCarInfo(state, "TurningAround", uEdge.id)
		elseif getNodeMeta(g, edge.toNode).isConnection then
			-- An outside connection is an EXIT, not a turnaround -- for every car, not just an
			-- ambient one. A directed car only reaches here having lost its route (it never hit
			-- its final edge), and this branch used to skip it: the `else` below snapped it to
			-- edgeDist 0, so it drove the same lane back out at the map edge, again, forever --
			-- the "cars teleport to the intersection and try to leave again" loop. Hand it back
			-- instead (through traffic despawns, a citizen's car parks where it stands).
			if state.route then
				_lostRouteExits += 1
				if os.clock() - _lastLostRouteWarn > LOST_ROUTE_WARN_INTERVAL then
					_lastLostRouteWarn = os.clock()
					warn(string.format("[NPCDriverService] %d directed cars left at the map edge without finishing their route -- route desync", _lostRouteExits))
					_lostRouteExits = 0
				end
				abortDirected(state)
			else
				despawnDriver(state)
			end
			return
		else
			-- A closed/restricted exit is not a cul-de-sac. Hold in place until a legal
			-- connection exists; never jump back to the start of the same road.
			if not getPendingNextEdgeId(g, state, edge) then
				state.currentSpeed = 0
				state.stopReason = "noExit"
				state.deadEndTimer = 0.25
				return
			end
		end
		state.atDeadEnd    = false
		state.deadEndTimer = 0
		return
	end

	local carPos = getStatePosition(state)
	local carDir = if state.smoothCFrame then state.smoothCFrame.LookVector else Vector3.zAxis
	local currentSpeed = state.currentSpeed or state.speed
	local proximitySpeedFactor, forwardClearance, blockerDot, blocker =
		PathFollower.getMotionLimits(state.model, carPos, carDir, nil, isRoadDrivenVehicle)
	state.blockerDot = blockerDot
	state.blockedBy = if forwardClearance <= 0.5 then blocker else nil

	-- Check stopping requirements on the current edge ahead of execution
	local edge = g:GetEdge(state.edgeId)
	if edge and not state.connector then
		state.speed = driverSpeed(edge, state)
	end
	local mustStop = false
	local interReason: string? = nil
	local distToStop = 0
	local stopDist = 0

	if edge then
		local cum = PathFollower.getCum(edge)
		local total = cum[#cum]
		local nextId = if #edge.out > 0 then getPendingNextEdgeId(g, state, edge) else nil
		local gap = getStopLineGap(g, edge.toNode, edge)
		stopDist = math.max(0, total - gap - noseSetback(state))
		distToStop = stopDist - state.edgeDist

		-- Emergency preemption: an approaching emergency vehicle leases the signal
		-- green for its own arm. Refreshed every frame; lapses once it clears the box.
		if VehicleTypes.canPreempt(state.vehicleClass)
			and distToStop < TrafficConfig.PREEMPT_APPROACH_DIST
			and distToStop > -5
			and isSignalizedIntersection(edge.toNode) then
			TrafficSignalService.RequestEmergencyPreemption(edge.toNode, edge.id)
		end

		-- Only OUR approach being yellow lets us commit; a red arm must not move when
		-- the crossing group goes yellow.
		local isYellow = TrafficSignalService.IsApproachYellow(edge.id)
		local safeStoppingDistance = currentSpeed * 1.5
		local committed = (state.edgeDist > stopDist + 0.1) or (isYellow and distToStop < safeStoppingDistance)

		-- Right of way is asked only of a car that could reach its line soon. Every car on
		-- every lane used to ask every tick, however far back in the block it was, and each
		-- ask walks the junction -- the answer is only ever used near the line.
		if nextId and not committed and distToStop <= math.max(Tuning.JUNCTION_LOOKAHEAD_MIN, currentSpeed * Tuning.JUNCTION_LOOKAHEAD_TIME) then
			local chosenNextId, canEnter = chooseEnterableNextEdgeId(g, state, edge, nextId)
			nextId = chosenNextId
			if not canEnter then
				mustStop = true
				-- blockedTime counts only time yielding (NOT at a red -- the light will
				-- change) so impatience can take a gap; stuckTime counts ALL waiting for the
				-- jam readouts; redTime counts one unbroken red, so only a broken signal
				-- (SIGNAL_FAULT_TIME) ever lets a car past a red.
				local atRed = isSignalizedIntersection(edge.toNode)
					and not TrafficSignalService.CanGo(edge.id, nextId)
				-- Only waiting AT the line counts: slowing for a car far ahead, or queueing
				-- behind the car at the line, is not a turn waited for.
				if distToStop > AT_LINE_DIST then
					state.blockedTime = 0
				elseif not atRed then
					if (state.blockedTime or 0) == 0 then state.waitSince = _simClock end
					state.blockedTime = (state.blockedTime or 0) + dt
				end
				state.stuckTime   = (state.stuckTime or 0) + dt
				state.redTime     = if atRed then (state.redTime or 0) + dt else 0
				interReason = if atRed then "redLight"
					elseif nextId and not exitLaneHasRoom(g, state, nextId) then "blocked"
					else "yield"
				if interReason == "blocked" and distToStop <= AT_LINE_DIST and state.route and nextId then
					state.exitWait = (state.exitWait or 0) + dt
					if (state.exitWait or 0) >= Tuning.EXIT_DETOUR_TIME and _simClock >= (state.nextDetourAt or 0)
						and Gridlock.detour(g, state, edge, nextId) then
						return
					end
				else
					state.exitWait = 0
				end
			else
				-- Allowed in. blockedTime is kept until the car is over the line (the branch
				-- below): zeroing it here, with the car still behind the line, took the turn
				-- straight back -- the move step asked again with no wait on the clock and
				-- the car stayed put, so a car whose turn had come never actually went.
				if distToStop > AT_LINE_DIST then state.blockedTime = 0 end
				state.stuckTime   = 0
				state.redTime     = 0
				state.exitWait    = 0
			end
		else
			state.blockedTime = 0
			state.stuckTime   = 0
			state.redTime     = 0
			state.exitWait    = 0
		end

		resolveQueueSpacing(state, edge, cum, dt)
		currentSpeed = state.currentSpeed or currentSpeed
	end

	-- A lane change the route wants next is tried every tick from the moment its window
	-- opens, moving or queued: a car stuck in its old lane still looks across for a gap.
	state.mergeInto = nil
	if edge and not state.connector then
		local lcTarget, lcEarliest, lcLatest = routeLaneChange(g, state, edge)
		if not lcTarget then
			state.laneChangeWait = 0
			state.mergeHoldAt = nil
			tryLaneDiscipline(g, state, edge)
		elseif state.edgeDist >= lcEarliest then
			local started, swapWith, tooShort = tryStartLaneChange(g, state, edge, lcTarget, lcLatest)
			if tooShort then
				-- Keep cruising in lane: move over on the next piece, or (if this was the
				-- last chance) re-plan at the window end -- see the hold in the move loop.
				deferLaneChange(g, state, edge, lcTarget)
			elseif not started then
				waitForMerge(state, lcTarget, lcLatest, swapWith, dt)
				if (state.laneChangeWait or 0) > LaneChange.REPLAN then
					state.laneChangeWait = 0
					state.mergeHoldAt = nil
					tryReroute(state)
					return
				end
			end
		end
	end

	-- Brake into a pending lane change's hold point: the move loop pins the car there, and it
	-- used to arrive at cruise speed and stop dead in one tick. On a highway a car still at
	-- speed re-plans where it would have to start braking, like a driver who missed the exit.
	local lcHoldDist: number? = nil
	if edge and not state.connector then
		local lcTarget, lcEarliest, lcLatest = routeLaneChange(g, state, edge)
		if lcTarget then
			local holdAt = math.max(lcLatest - laneChangeHoldBack(g, edge, lcTarget), lcEarliest, state.mergeHoldAt or 0)
			local holdDist = math.max(0, holdAt - state.edgeDist)
			local brakeDist = currentSpeed * currentSpeed / (2 * LaneChange.HOLD_DECEL) + currentSpeed * dt
			if edge.roadClass == "highway" and currentSpeed > LaneChange.HOLD_SPEED
				and state.laneChangeMissed ~= edge.id and holdDist <= brakeDist then
				state.laneChangeMissed = edge.id
				if tryReroute(state) then return end
			end
			lcHoldDist = holdDist
		end
	end

	local queueLead, queueGap = getNearestQueueLeader(state)
	local merger, mergeGap = getMergeCourtesy(state)
	if mergeGap and (not queueGap or mergeGap < queueGap) then
		queueLead, queueGap = merger, mergeGap
	end
	local queueMinGap = followGap(state, queueLead)
	local queueSpeedFactor = getQueueSpeedFactor(queueGap, currentSpeed, queueMinGap)
	local speedFactor = math.min(proximitySpeedFactor, queueSpeedFactor)

	-- debug: classify WHY this car is at its current speed (in-memory only, read
	-- by GetSpeedDebug -- never a replicated attribute, no per-frame allocation).
	if queueSpeedFactor < 0.5 and queueSpeedFactor <= proximitySpeedFactor then
		-- No leader: the hold is a driveway car's gap request (getMergeCourtesy).
		state.stopReason = if queueLead then "carAhead" else "roadGap"
	elseif interReason then
		state.stopReason = interReason
	elseif state.connector then
		state.stopReason = "turn"
	elseif proximitySpeedFactor < 0.6 then
		state.stopReason = "blocked"
	elseif edge and distToStop > -1 and distToStop < TURN_SLOW_ZONE and state.pendingNextEdgeId then
		state.stopReason = "turn"
	elseif speedFactor < 0.85 then
		state.stopReason = "slow"
	else
		state.stopReason = "cruise"
	end

	-- == Smoothed Target Speed Calculation (Processed ONCE per frame) ==
	local targetSpeed = state.speed * speedFactor
	if lcHoldDist then
		targetSpeed = math.min(targetSpeed, math.sqrt(2 * LaneChange.HOLD_DECEL * lcHoldDist))
	end
	if mustStop then
		-- FIX: Guard distToStop so that an NPC that is already past the stop
		-- line (distToStop < 0) is never forced to slow down. The old code let
		-- a negative distToStop feed into the quadratic, producing a small
		-- positive t² and an artificially low targetSpeed that stalled the car
		-- well in front of the line -- exactly the "stops way before the red
		-- light" bug.
		if distToStop > 0 then
			-- Only feather speed right at the stop line; cars should keep cruising
			-- until they are close enough to actually stop for the light.
			if distToStop <= Tuning.STOP_DECEL_DISTANCE then
				local t = distToStop / Tuning.STOP_DECEL_DISTANCE
				targetSpeed = targetSpeed * (t * t)
			end
		else
			-- Already at or past the stop line; committed -- don't impose any
			-- additional braking here (committed flag handles re-entry above).
			-- Setting targetSpeed = 0 here would cause jitter when mustStop flips.
			mustStop = false
		end
	end

	-- Slow into turns: a connector is capped by its tightest bend, and the
	-- approach eases down so the car arrives at a speed it can actually hold
	-- through the arc instead of whipping around the corner at road speed.
	if state.connector then
		-- A lane change is not a turn: its ribbon is laid out long enough for the car's speed
		-- (laneChangeMinLength), so the car drifts over at the speed it had. Only the traffic
		-- ahead may slow it.
		if state.connSpeedCap and not laneChangeOf(state) then
			targetSpeed = math.min(targetSpeed, state.connSpeedCap)
		end
	elseif edge and distToStop > -1 and distToStop < TURN_SLOW_ZONE then
		local pendingId = state.pendingNextEdgeId
		local movement = if pendingId and edge.outMovement then edge.outMovement[pendingId] else nil
		local entrySpeed = if movement then Tuning.TURN_ENTRY_SPEED[movement] else nil
		if entrySpeed and entrySpeed < targetSpeed then
			local t = math.clamp(distToStop / TURN_SLOW_ZONE, 0, 1)
			targetSpeed = entrySpeed + (targetSpeed - entrySpeed) * t
		end
	end

	-- Smoothly interpolate currentSpeed towards targetSpeed
	if currentSpeed < targetSpeed then
		currentSpeed = math.min(currentSpeed + Tuning.ACCEL_RATE * dt, targetSpeed)
	else
		currentSpeed = math.max(currentSpeed - Tuning.BRAKE_RATE * dt, targetSpeed)
	end
	state.currentSpeed = currentSpeed

	-- Calculate frame travel remaining (calculated ONCE per frame update to avoid speed compounding bug)
	local queueTravelLimit = if queueGap then math.max(0, queueGap - queueMinGap) else math.huge
	-- Hard spacing clamp against ALL nearby cars (other edges, mid-turn connectors,
	-- and the intersection box) -- not just same-edge queue mates. This is what
	-- stops cars clipping through each other while turning or crossing a junction.
	-- forwardClearance and blockerDot were produced with proximitySpeedFactor
	-- above, so the nearby-car buckets are queried only once per driver tick.

	-- Two cars blocking EACH OTHER (nose to nose at a dead-end U-turn bulb, or locked
	-- across each other in a box) can never clear by themselves, so after a short wait
	-- the tie-break winner creeps through and the other waits for it. Anything else in
	-- the way is traffic and holds us as long as it stands -- a car stuck in a jam in the
	-- box included. A rescued (bugged) car pushes through at once. Stop lines stay
	-- respected: this only lifts the proximity clamp, never the red-light/yield limit.
	local blockerState = if state.blockedBy then _drivers[state.blockedBy] else nil
	local standoffWinner = blockerState ~= nil
		and inMutualStandoff(state) and winsStandoff(state, blockerState)
	if state.blockedBy and (standoffWinner or state.rescueFrom) then
		state.connBlockedTime = (state.connBlockedTime or 0) + dt
		if state.rescueFrom or state.connBlockedTime >= Tuning.CONNECTOR_STANDOFF_ESCAPE then
			local _, clearPastBlocker = PathFollower.getMotionLimits(state.model,carPos,carDir,state.blockedBy)
			forwardClearance = clearPastBlocker
			currentSpeed = math.max(currentSpeed, Tuning.MIN_TURN_SPEED * 0.5)
			state.currentSpeed = currentSpeed
		end
	else
		state.connBlockedTime = 0
	end

	local remaining = math.min(currentSpeed * dt, queueTravelLimit, forwardClearance)

	local remainingSteps = Tuning.MAX_STEPS
	for _ = 1, remainingSteps do
		if remaining <= 1e-4 then break end

		-- Travelling a connector arc
		if state.connector then
			local pts = state.connector :: { Vector3 }
			local connCum: { number } = state.connCum or (function()
				local c: { number } = table.create(#pts, 0)
				c[1] = 0
				for i = 2, #pts do c[i] = c[i-1] + (pts[i] - pts[i-1]).Magnitude end
				state.connCum = c
				return c
			end)()
			local totalConn = connCum[#connCum] or 0

			if #pts < 2 or totalConn < 1e-4 then
				local landed0 = state.nextEdgeId :: string
				state.connector    = nil
				state.connCum      = nil
				state.connDist     = 0
				state.connSpeedCap = nil
				state.connBlockedTime = 0
				state.edgeId       = landed0
				state.edgeDist     = state.nextEdgeDist
				state.nextEdgeId   = nil
				state.nextEdgeDist = 0
				if state.route and state.routeIndex and state.route[state.routeIndex + 1] == landed0 then
					state.routeIndex += 1
				end
				continue
			end

			local move = math.min(remaining, totalConn - state.connDist)
			state.connDist += move
			remaining -= move

			local pos, dir = PathFollower.pointAtDist(pts, connCum, state.connDist)
			PathFollower.place(state, pos, dir, dt)

			if state.connDist >= totalConn - 1e-4 then
				-- Connector done -- land on the next edge
				local landedEdge    = state.nextEdgeId :: string
				state.connector     = nil
				state.connCum       = nil
				state.connDist      = 0
				state.connSpeedCap  = nil
				state.connBlockedTime = 0
				state.edgeId        = landedEdge
				state.edgeDist      = state.nextEdgeDist
				state.nextEdgeId    = nil
				state.nextEdgeDist  = 0
				if state.route and state.routeIndex and state.route[state.routeIndex + 1] == landedEdge then
					state.routeIndex += 1
				end
				tagCarInfo(state, "Cruising", landedEdge)
				break
			end
			continue
		end

		-- Normal edge travel
		local currentEdge = g:GetEdge(state.edgeId)
		if not currentEdge then
			-- Edge under us vanished: a directed car hands back (keeps the trip contract);
			-- an ambient roamer re-anchors to the nearest lane or despawns.
			if state.route then abortDirected(state) else anchorToNearest(state) end
			break
		end

		local cum    = PathFollower.getCum(currentEdge)
		local total  = cum[#cum]

		-- Directed arrival: on the LAST route edge, ease to the lot-entry distance,
		-- stop, hand the car back (onArrive), and leave the driver pool so the caller
		-- runs the off-graph pull-in. Done before any junction logic.
		if state.route and not state.arrived and (state.routeIndex or 1) >= #state.route then
			local arriveDist = math.clamp(state.finalDist or total, 0, total)
			local astep = math.min(remaining, math.max(0, arriveDist - state.edgeDist))
			state.edgeDist += astep
			remaining = 0
			local apos, adir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, apos, adir, dt)
			if state.edgeDist >= arriveDist - 0.5 then
				finishDirected(state)
			end
			break
		end

		-- Lane change pending (tried before the move, above): drive on and hold at the end of
		-- the window until it starts, braked into (lcHoldDist), as a driver waiting to get
		-- into a turn lane does. A highway car at speed already re-planned before braking.
		local lcTarget, lcEarliest, lcLatest = routeLaneChange(g, state, currentEdge)
		if lcTarget then
			-- Never before the window opens: a car held there would never be allowed to start.
			local holdAt = math.max(lcLatest - laneChangeHoldBack(g, currentEdge, lcTarget), lcEarliest,
				state.mergeHoldAt or 0, state.edgeDist)
			local lcMove = math.min(remaining, holdAt - state.edgeDist)
			state.edgeDist += lcMove
			remaining -= lcMove
			local lcPos, lcDir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, lcPos, lcDir, dt)
			if state.edgeDist >= holdAt - 1e-4 then
				state.currentSpeed = 0
				state.stopReason = "laneChange"
				break
			end
			if lcMove <= 1e-4 then break end
			continue
		end

		local nextId = if #currentEdge.out > 0 then getPendingNextEdgeId(g, state, currentEdge) else nil
		local gap = getStopLineGap(g, currentEdge.toNode, currentEdge)
		local stopDistVal = math.max(0, total - gap - noseSetback(state))

		-- No legal exit at a live junction: wait outside its box for a road/rule edit.
		if not nextId and isIntersectionNode(g, currentEdge.toNode) then
			state.edgeDist += math.min(remaining, math.max(0, stopDistVal - state.edgeDist))
			if state.edgeDist >= stopDistVal - 1e-4 then
				state.atDeadEnd = true
				state.deadEndTimer = 0.25
				state.currentSpeed = 0
				state.stopReason = "noExit"
			end
			local holdPos, holdDir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, holdPos, holdDir, dt)
			break
		end

		-- Recheck stopping on current step
		local isYellow = TrafficSignalService.IsApproachYellow(currentEdge.id)
		local distToStopVal = stopDistVal - state.edgeDist
		local safeStoppingDistance = currentSpeed * 1.5
		local committed = (state.edgeDist > stopDistVal + 0.1) or (isYellow and distToStopVal < safeStoppingDistance)

		local loopMustStop = false
		-- Only a step that would carry the car over its line needs the answer (see above).
		if nextId and not committed and distToStopVal <= remaining + 1 then
			local chosenNextId, canEnter = chooseEnterableNextEdgeId(g, state, currentEdge, nextId)
			nextId = chosenNextId
			if not canEnter then
				loopMustStop = true
			end
		end

		if loopMustStop then
			if distToStopVal <= 1e-4 then
				state.edgeDist = stopDistVal
				state.currentSpeed = 0
			else
				local stepRemaining = math.min(remaining, distToStopVal)
				state.edgeDist += stepRemaining
				if stepRemaining >= distToStopVal - 1e-4 then
					state.edgeDist = stopDistVal
					state.currentSpeed = 0
				end
			end
			remaining = 0

			local pos, dir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
			PathFollower.place(state, pos, dir, dt)
			break
		end

		-- Normal forward travel. With an exit chosen, the edge effectively ends
		-- at the junction mouth: the connector takes over there, so cars turn on
		-- the junction surface instead of driving to the node centre first.
		local edgeEnd = total
		if nextId then
			local fromSetback = g:GetConnectionSetbacks(currentEdge.id, nextId)
			edgeEnd = math.max(0, total - fromSetback)
		end
		local move = math.min(remaining, math.max(0, edgeEnd - state.edgeDist))
		state.edgeDist += move
		remaining -= move

		local pos, dir = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
		PathFollower.place(state, pos, dir, dt)

		if state.edgeDist >= edgeEnd - 1e-4 then
			if nextId then
				local nextEdge = g:GetEdge(nextId)
				if nextEdge and (committed or canEnterIntersection(g, state, currentEdge, nextId)) then
					local connPts, _, resumeDist = g:GetConnectionPoints(currentEdge.id, nextId)
					startConnector(state, connPts, nextId, resumeDist)
					tagCarInfo(state, "Cruising", nextId)
					break
				else
					-- Keep stopped cleanly behind the stop line (never snap forward
					-- past the mouth if the stop line sits beyond it).
					state.edgeDist = math.min(stopDistVal, state.edgeDist)
					state.currentSpeed = 0
					local pos2, dir2 = PathFollower.pointAtDist(currentEdge.points, cum, state.edgeDist)
					PathFollower.place(state, pos2, dir2, dt)
					break
				end
			else
				-- DEAD END
				state.atDeadEnd    = true
				state.deadEndTimer = Tuning.DEAD_END_WAIT
				state.pendingNextEdgeId = nil
				state.currentSpeed = 0
				tagCarInfo(state, "Stopped", nil)
				break
			end
		end

		if move <= 1e-4 then break end
	end
end

-- == Car builder ===============================================================
-- VehicleFactory is the ONE place a vehicle is cloned, sized and welded. This was a
-- second copy of that assembly which never scaled at all, so ambient traffic spawned
-- at raw authored scale -- ~2x every other vehicle in the half-scale world, and wider
-- than the lane it drove in. Keep the delegation: a car built anywhere else drifts.
local function buildCar(name: string, colorIdx: number): Model
	return VehicleFactory.build(name, colorIdx)
end

-- == Spawning ==================================================================
local function ensureFolder(): Folder
	local cityFolder = Workspace:FindFirstChild("_City")
	if not cityFolder then
		cityFolder = Instance.new("Folder")
		cityFolder.Name = "_City"
		cityFolder.Parent = Workspace
	end
	local f = cityFolder:FindFirstChild("NPCDrivers")
	if not f then
		f = Instance.new("Folder")
		f.Name   = "NPCDrivers"
		f.Parent = cityFolder
	end
	return f :: Folder
end

local function clearOld(folder: Folder)
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and CollectionService:HasTag(child, TAG) then
			PathFollower.forget(child :: Model)
			child:Destroy()
		end
	end
end

local function placeOnEdge(model: Model, edge: any, frac: number)
	local pts = edge.points
	if #pts < 2 then return end
	local totalLen = 0
	for i = 2, #pts do totalLen += (pts[i] - pts[i-1]).Magnitude end
	local target = totalLen * frac
	local dist = 0
	for i = 2, #pts do
		local seg = (pts[i] - pts[i-1]).Magnitude
		if dist + seg >= target then
			local alpha = if seg > 1e-6 then (target - dist) / seg else 0
			local pos   = pts[i-1]:Lerp(pts[i], alpha)
			local dir   = (pts[i] - pts[i-1])
			local flat  = Vector3.new(dir.X, 0, dir.Z)
			if flat.Magnitude < 1e-6 then flat = Vector3.zAxis end
			local up = pos + Vector3.new(0, 0.6, 0)
			model:PivotTo(CFrame.lookAt(up, up + flat.Unit))
			return
		end
		dist += seg
	end
end

local function trySpawn(): boolean
	if Workspace:GetAttribute("RandomTrafficEnabled") == false then return true end

	local configuredCount = Workspace:GetAttribute("AmbientTrafficCount")
	local targetCount = Tuning.NPC_COUNT
	if typeof(configuredCount) == "number" then
		targetCount = math.clamp(math.floor(configuredCount), 0, Tuning.MAX_AMBIENT_TRAFFIC)
	end
	if targetCount <= 0 then return true end

	local g = nav()
	if not g or not g:HasEdges() then return false end
	local edges = g:GetEdges()
	if #edges == 0 then return false end

	local folder = ensureFolder()
	clearOld(folder)
	-- Drop only AMBIENT driver states here. Directed (citizen/delivery) cars live in a
	-- separate folder and must keep their state so their onArrive/onAbort contract holds
	-- (a bare table.clear froze them mid-trip and leaked the directed-car count).
	for model, state in pairs(_drivers) do
		if not state.route then
			unindexDriver(state)
			_drivers[model] = nil
		end
	end
	PathFollower.flushCache()

	-- Minimum studs between any two cars on the same edge at spawn.
	local MIN_SPAWN_GAP = 12

	type Slot = { edgeId: string, dist: number, edge: any }
	local slots: { Slot } = {}

	for _, edge in ipairs(edges) do
		if not edgeAllows(edge, VehicleTypes.Car) then continue end
		local pts = edge.points
		local totalLen = 0
		for i = 2, #pts do totalLen += (pts[i] - pts[i-1]).Magnitude end
		if totalLen < MIN_SPAWN_GAP then continue end

		local d = MIN_SPAWN_GAP * 0.5
		while d + MIN_SPAWN_GAP * 0.5 <= totalLen do
			table.insert(slots, { edgeId = edge.id, dist = d, edge = edge })
			d += MIN_SPAWN_GAP
		end
	end

	if #slots == 0 then
		for _, edge in ipairs(edges) do
			if not edgeAllows(edge, VehicleTypes.Car) then continue end
			local pts = edge.points
			local totalLen = 0
			for i = 2, #pts do totalLen += (pts[i] - pts[i-1]).Magnitude end
			table.insert(slots, { edgeId = edge.id, dist = totalLen * 0.5, edge = edge })
		end
	end

	-- Shuffle slots
	for i = #slots, 2, -1 do
		local j = math.random(1, i)
		slots[i], slots[j] = slots[j], slots[i]
	end

	-- Spawn up to the requested ambient count.
	local count = math.min(targetCount, #slots)
	for i = 1, count do
		local slot = slots[i]
		local edge = slot.edge

		local car = buildCar("NPCDriver_" .. i, i)
		car.Parent = folder
		CollectionService:AddTag(car, TAG)
		CollectionService:AddTag(car, VehicleTypes.tagFor(VehicleTypes.Car))

		-- Ambient roamers get a mind too: they are the background traffic the routed
		-- cars have to share the road with, so they must not all drive identically.
		local profile = DriverProfile.fromModel(car)
		local spd = edgeSpeed(edge) * (if profile then profile.speedFactor else 1)
		local hgt = car:GetAttribute("NPCHeightOffset") or 0.6
		car:SetAttribute("NPCSpeed", math.round(spd))  -- debug readout (DebugService)

		local pts = edge.points
		local totalLen = 0
		for j = 2, #pts do totalLen += (pts[j] - pts[j-1]).Magnitude end
		local frac = math.clamp(slot.dist / math.max(totalLen, 1), 0, 1)
		placeOnEdge(car, edge, frac)

		local state = {
			model          = car,
			vehicleClass   = VehicleTypes.Car,
			profile        = profile,
			edgeId         = slot.edgeId,
			edgeDist       = slot.dist,
			graphVersion   = g:Version(),
			connector      = nil,
			connCum        = nil,
			connDist       = 0,
			nextEdgeId     = nil,
			nextEdgeDist   = 0,
			pendingNextEdgeId = nil,
			atDeadEnd      = false,
			deadEndTimer   = 0,
			speed          = spd,
			currentSpeed   = spd, -- Start spawned cars smoothly matching their target cruising speed
			blockedTime    = 0,
			stuckTime      = 0,
			connBlockedTime = 0,
			heightOffset   = hgt + LANE_SURFACE,
			halfLength     = vehicleHalfLength(car),
			smoothCFrame   = nil,
			lastSentCFrame = nil,
			replicateAccum = 0,
		}
		_drivers[car] = state
		_unseated[car] = state
		table.insert(_joined, state)

		local cum: { number } = table.create(#pts, 0)
		cum[1] = 0
		for j = 2, #pts do cum[j] = cum[j-1] + (pts[j] - pts[j-1]).Magnitude end
		local spawnPos, spawnDir = PathFollower.pointAtDist(pts, cum, slot.dist)
		local flat = Vector3.new(spawnDir.X, 0, spawnDir.Z)
		if flat.Magnitude < 1e-6 then flat = Vector3.zAxis end
		local cf = CFrame.lookAt(spawnPos + Vector3.new(0, hgt, 0), spawnPos + Vector3.new(0, hgt, 0) + flat.Unit)
		state.smoothCFrame   = cf
		state.lastSentCFrame = cf

		tagCarInfo(state, "Cruising", slot.edgeId)
		PathFollower.seedProximity(car, (i - 1) * (PathFollower.PROXIMITY_CHECK_DT / math.max(count, 1)))
	end

	return true
end

-- == Public API ================================================================

-- Directed trip: drive `model` along `route` (ordered lane-edge ids -- the 2nd
-- return of RoadNavigationGraph:FindPath) using the FULL traffic AI (correct lane,
-- stop lines, signals, yielding, no overlap). Seats the car at the point on the
-- first edge nearest `startPos`; stops at the point on the last edge nearest
-- `goalPos`, fires `onArrive`, then leaves the driver pool so the caller can run
-- the off-graph lot pull-in. Fires `onAbort` if the route can't be followed.
-- Returns true if the trip started.
-- `exactStartDist` seats the car at a KNOWN distance along route[1] instead of projecting
-- startPos onto it. Only a caller restoring a saved vehicle has that number (it saved the
-- car's own edgeDist), and using it keeps a reloaded queue in exactly the order and
-- spacing it was saved in rather than one re-derived from rounded world positions.
function NPCDriverService.DriveDirected(model: Model, startPos: Vector3, goalPos: Vector3, route: { string }, onArrive: (() -> ())?, onAbort: (() -> ())?, exactStartDist: number?): boolean
	local g = nav()
	if not g or not g:HasEdges() or typeof(route) ~= "table" or #route == 0 then return false end
	local firstEdge = g:GetEdge(route[1])
	local lastEdge = g:GetEdge(route[#route])
	if not firstEdge or not lastEdge then return false end
	local vehicleClass = VehicleTypes.classOf(model)
	for i, id in route do
		local edge = g:GetEdge(id)
		if not edge or not edgeAllows(edge, vehicleClass) then return false end
		local nextId = route[i + 1]
		if nextId and not edgeHasOutgoing(edge, nextId) and not g:GetLaneChangeWindow(id, nextId) then
			return false
		end
	end

	local startDist
	if typeof(exactStartDist) == "number" and exactStartDist == exactStartDist then
		startDist = math.clamp(exactStartDist, 0, firstEdge.length or exactStartDist)
	else
		startDist = distAlongEdgeNearest(firstEdge, startPos)
	end

	-- A new driveway/yard launch projected onto the node is not committed traffic.
	-- Seat behind the painted line, or let its owner retry if that seat is occupied.
	if not _drivers[model] and #route>1 and isIntersectionNode(g,firstEdge.toNode) then
		local stopAt=math.max(0,(firstEdge.length or 0)-getStopLineGap(g,firstEdge.toNode,firstEdge)
			-noseSetback({halfLength=vehicleHalfLength(model)} :: any))
		if startDist>stopAt then
			local seat=PathFollower.pointAtDist(firstEdge.points,PathFollower.getCum(firstEdge),stopAt)
			if not NPCDriverService.RoadGapClear(seat,0,model) then return false end
			startDist=stopAt
		end
	end
	if not _drivers[model] then
		local seat, direction = PathFollower.pointAtDist(firstEdge.points,PathFollower.getCum(firstEdge),startDist)
		if not NPCDriverService.RoadGapClear(seat,0,model) then return false end
		-- Parking handoffs still occupy road space after leaving the driver registry.
		if PathFollower.anyVehicleWithin(seat, FOLLOW_BUMPER, function(other: Model): boolean
			return other ~= model
		end) then return false end
		local ahead = PathFollower.getClearAhead(model, seat, direction)
		local behind = PathFollower.getClearAhead(model, seat, -direction)
		if ahead < 0 or behind < 0 then return false end
	end
	local finalDist = distAlongEdgeNearest(lastEdge, goalPos)
	if #route == 1 and finalDist < startDist then finalDist = startDist end

	model:SetAttribute("NPCStoppedPose", nil)
	local hgt = model:GetAttribute("NPCHeightOffset")
	local addedDebugTag = false
	if not CollectionService:HasTag(model, TAG) then
		CollectionService:AddTag(model, TAG)
		addedDebugTag = true
	end
	ensureDebugId(model)
	if typeof(hgt) ~= "number" then
		local _, sz = model:GetBoundingBox()
		hgt = sz.Y * 0.5 + 0.05
		model:SetAttribute("NPCHeightOffset", hgt)
	end

	-- A car given a new trip while it is still driving: retire the old record first. Left
	-- in place it stayed filed in its lane at its last position -- never updated, never
	-- swept, never seen by the client -- and every car behind it queued on it for good
	-- (the server-only jams, measured 2026-09-30: queues "behind #? (not driving)").
	local previous = _drivers[model]
	if previous then
		releaseBooking(previous)
		unindexDriver(previous)
	end

	-- The vehicle's own mind, stamped on the model so it survives the hand-offs
	-- between CitizenService and this service and stays the same car's personality.
	_nextBookingToken += 1
	local bookingToken = _nextBookingToken
	local profile = DriverProfile.withToken(DriverProfile.fromModel(model), bookingToken)

	local state: DriverState = {
		model          = model,
		-- Tagged by whoever built it (bus / emergency / train); untagged models read as Car.
		vehicleClass   = vehicleClass,
		profile        = profile,
		bookingToken   = bookingToken,
		edgeId         = route[1],
		edgeDist       = startDist,
		graphVersion   = g:Version(),
		connector      = nil,
		connCum        = nil,
		connDist       = 0,
		nextEdgeId     = nil,
		nextEdgeDist   = 0,
		pendingNextEdgeId = nil,
		atDeadEnd      = false,
		deadEndTimer   = 0,
		speed          = edgeSpeed(firstEdge) * (if profile then profile.speedFactor else 1),
		currentSpeed   = 0,
		blockedTime    = 0,
		stuckTime      = 0,
		connBlockedTime = 0,
		heightOffset   = (hgt :: number) + LANE_SURFACE,
		halfLength     = vehicleHalfLength(model),
		smoothCFrame   = nil,
		lastSentCFrame = nil,
		replicateAccum = 0,
		debugTagAdded  = addedDebugTag,
		route          = route,
		routeIndex     = 1,
		goalPos        = goalPos,
		finalDist      = finalDist,
		onArrive       = onArrive,
		onAbort        = onAbort,
		arrived        = false,
		trafficJamTime = 0,
		nextTrafficRerouteAt = os.clock() + TRAFFIC_REROUTE_COOLDOWN,
		trafficReroutes = 0,
		lastTrafficRerouteAt = nil,
		lastTrafficAbandonedNextEdgeId = nil,
	}
	_drivers[model] = state
	_unseated[model] = state
	local seat, heading = PathFollower.pointAtDist(firstEdge.points, PathFollower.getCum(firstEdge), startDist)
	PathFollower.place(state, seat, heading, 0)
	table.insert(_joined, state)
	-- Stake this route out so every driver planning after us can see it is taken.
	bookRoute(state)
	tagCarInfo(state, "Directed", route[1])
	PathFollower.seedProximity(model, 0)
	return true
end

local function flatDistSq(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return dx * dx + dz * dz
end

local function pointOnEdge(edge: any, frac: number): Vector3?
	local pts = edge.points
	if typeof(pts) ~= "table" or #pts < 2 then
		return nil
	end
	local cum = PathFollower.getCum(edge)
	local total = cum[#cum] or 0
	if total <= 0 then
		return pts[1]
	end
	local pos = PathFollower.pointAtDist(pts, cum, math.clamp(total * frac, 0, total))
	return pos
end

function NPCDriverService.SpawnTestCarsNear(center: Vector3?, count: number?, radius: number?): { [string]: any }
	local g = nav()
	if not g or not g:HasEdges() then
		return { ok = false, error = "No roads are loaded." }
	end

	local requested = math.clamp(math.floor((tonumber(count) or Tuning.ADMIN_TEST_CAR_DEFAULT_COUNT) + 0.5), 1, Tuning.ADMIN_TEST_CAR_MAX_COUNT)
	local r = math.clamp(math.floor((tonumber(radius) or Tuning.ADMIN_TEST_CAR_DEFAULT_RADIUS) + 0.5), 40, 1500)
	local radiusSq = r * r

	type TestSlot = { edge: any, frac: number, pos: Vector3, score: number }
	local nearSlots: { TestSlot } = {}
	local fallbackSlots: { TestSlot } = {}
	local goalEdges: { any } = {}

	for _, edge in ipairs(g:GetEdges()) do
		if not edge or not edgeAllows(edge, VehicleTypes.Car) then
			continue
		end
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then
			continue
		end
		table.insert(goalEdges, edge)
		for _, frac in ipairs(Tuning.TEST_SPAWN_FRACTIONS) do
			local pos = pointOnEdge(edge, frac)
			if not pos then
				continue
			end
			local score = if center then flatDistSq(pos, center) else #nearSlots
			local slot = { edge = edge, frac = frac, pos = pos, score = score }
			if center and score > radiusSq then
				table.insert(fallbackSlots, slot)
			else
				table.insert(nearSlots, slot)
			end
		end
	end

	local slots = nearSlots
	if #slots == 0 then
		slots = fallbackSlots
	end
	table.sort(slots, function(a: TestSlot, b: TestSlot)
		return a.score < b.score
	end)

	if #slots == 0 or #goalEdges == 0 then
		return { ok = false, error = "No usable car lanes were found.", spawned = 0, requested = requested }
	end

	local function findGoal(startPos: Vector3, ordinal: number): (Vector3?, { string }?)
		local edgeCount = #goalEdges
		local attempts = math.min(edgeCount, 10)
		for attempt = 1, attempts do
			local goalEdge = goalEdges[((ordinal * 17 + attempt * 31) % edgeCount) + 1]
			local goal = pointOnEdge(goalEdge, 0.82)
			if goal and flatDistSq(startPos, goal) >= 1600 then
				local ok, _, route = pcall(function()
					return g:FindPath(startPos, goal)
				end)
				if ok and typeof(route) == "table" and #route > 0 then
					return goal, route :: { string }
				end
			end
		end
		return nil, nil
	end

	local folder = ensureFolder()
	local spawned = 0
	for i, slot in ipairs(slots) do
		if spawned >= requested then
			break
		end
		local goal, route = findGoal(slot.pos, i + spawned)
		if not goal or not route then
			continue
		end

		local car = buildCar("AdminTestCar_" .. tostring(math.floor(os.clock() * 1000)) .. "_" .. tostring(i), i)
		car:SetAttribute("AdminTestCar", true)
		placeOnEdge(car, slot.edge, slot.frac)
		car.Parent = folder
		CollectionService:AddTag(car, TAG)
		CollectionService:AddTag(car, VehicleTypes.tagFor(VehicleTypes.Car))

		local function cleanup()
			if car.Parent then
				car:Destroy()
			end
		end

		if NPCDriverService.DriveDirected(car, slot.pos, goal, route, cleanup, cleanup) then
			spawned += 1
		else
			car:Destroy()
		end
	end

	return {
		ok = spawned > 0,
		spawned = spawned,
		requested = requested,
		candidates = #slots,
		radius = r,
		fallback = #nearSlots == 0,
	}
end

-- Silently drop a directed car from the driver pool WITHOUT firing onArrive/onAbort
-- (the caller is destroying it / taking it over). Returns true if it was directed.
function NPCDriverService.ReleaseDirected(model: Model): boolean
	local state = _drivers[model]
	if state and state.route then
		releaseBooking(state)
		leaveWhereItStands(state)
		clearDirectedDebugTag(state)
		unindexDriver(state)
		_drivers[model] = nil
		PathFollower.forget(model)
		return true
	end
	return false
end

-- Admin reset: every car out of the traffic sim at once, so traffic starts fresh. Directed
-- trips end through their own onAbort (a citizen parks at its destination, through traffic
-- despawns and its spawner refills from the map edges); anything else is removed.
function NPCDriverService.ResetAll(): number
	local all: { DriverState } = {}
	for _, state in _drivers do table.insert(all, state) end
	for _, state in all do
		if state.route then abortDirected(state) else despawnDriver(state) end
	end
	return #all
end

function NPCDriverService.IsDirected(model: Model): boolean
	local state = _drivers[model]
	return state ~= nil and state.route ~= nil
end

-- Whether `model` is driving on the traffic AI right now (any trip, or an ambient roamer).
function NPCDriverService.IsOnRoad(model: Model): boolean
	return _drivers[model] ~= nil
end

function NPCDriverService.IsWaitingForVehicle(model: Model, blocker: Model): boolean
	local state = _drivers[model]
	return state ~= nil and state.blockedBy == blocker and (state.currentSpeed or 0) <= 1.5
end

-- Is any vehicle within `radius` studs of `pos`? PathFollower streams a near car's pose to
-- the clients and STOPS writing its instance CFrame, so a workspace overlap query sees the
-- car parked on the spawn point it left minutes ago -- which is why every outside connection
-- read as jammed with stalled cars while those cars were visibly driving. Driver state is
-- the only live position the server has, so spawn gates must ask here, not the world.
-- ponytail: linear scan of active drivers; called a few times a second at spawn gates, not
-- per frame. Bucket by nav cell if the fleet ever makes it show up in a profile.
-- Moving heavy vehicles and how loud each one is, for CoverageService's traffic-noise layer.
-- A full-size truck is the loudest thing on the road (one heavy truck ~ 10-30 cars in the
-- FHWA Traffic Noise Model), a van a fraction of that, a bus in between. Cars are left out:
-- stamping thousands of them would cost far more than their faint share tells.
local NOISE_CLASS_WEIGHT = table.freeze({ [VehicleTypes.Truck] = 1, [VehicleTypes.Bus] = 0.6 })
local NOISE_FULL_HALF_LENGTH = 12 -- studs: a vehicle this long or longer is full-size

function NPCDriverService.GetNoiseSources(): { { pos: Vector3, weight: number } }
	local out = {}
	for model, state in _drivers do
		local w = NOISE_CLASS_WEIGHT[state.vehicleClass]
		if w and model.Parent and (state.currentSpeed or 0) > 1 then
			local size = math.clamp((state.halfLength or NOISE_FULL_HALF_LENGTH) / NOISE_FULL_HALF_LENGTH, 0.25, 1)
			table.insert(out, { pos = getStatePosition(state), weight = w * size })
		end
	end
	return out
end

-- City vehicles (not intercity through traffic) on motorway lanes right now: the share of
-- the motorway ThroughTrafficService gives up to the people who live here.
function NPCDriverService.CountCityCarsOnHighways(): number
	local g = nav()
	if not g then return 0 end
	local n = 0
	for model, state in _drivers do
		if model.Parent and not state.connector and model:GetAttribute("Through") ~= true then
			local edge = g:GetEdge(state.edgeId)
			if edge and edge.roadClass == "highway" then n += 1 end
		end
	end
	return n
end

function NPCDriverService.IsPointClear(pos: Vector3, radius: number): boolean
	-- A driving vehicle is in PathFollower's spatial grid at its live pose from its first
	-- step, so only the cells around `pos` are looked at (this was a scan of the whole fleet
	-- per spawn try). One handed over since then is still where it was put down.
	local r2 = radius * radius
	for model, state in _unseated do
		if not model.Parent or _drivers[model] ~= state or PathFollower.isRegistered(model) then
			_unseated[model] = nil
			continue
		end
		local p = getStatePosition(state)
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		local cf = state.smoothCFrame
		local dir = if cf then cf.LookVector else Vector3.zAxis
		if dx * dx + dz * dz < r2 and PathFollower.sameRoadLevel(p, dir, pos) then return false end
	end
	return not PathFollower.anyVehicleWithin(pos, radius, function(model: Model): boolean
		return _drivers[model] ~= nil
	end)
end

-- Whether a car joining the road at `pos` only has to mind ONE lane: it is already on that
-- lane (a pocketed car coming back where it stood), or it pulls out of the kerb into the
-- kerbside lane. Otherwise its move crosses every lane of the road.
function Gridlock.ownLaneOnly(g: any, pos: Vector3, targetEdgeId: string?): boolean
	local target = if targetEdgeId then g:GetEdge(targetEdgeId) else nil
	if not target then return false end
	local at = distAlongEdgeNearest(target, pos)
	local seat, direction = PathFollower.pointAtDist(target.points, PathFollower.getCum(target), at)
	local dx, dz = pos.X - seat.X, pos.Z - seat.Z
	if dx * dx + dz * dz < 2.25 then return true end
	if target.laneOrdinal ~= target.laneCountInDirection then return false end
	local right = Vector3.new(-direction.Z, 0, direction.X)
	return (pos - seat):Dot(right) * RoadRules.getLaneSideSign() > 0
end

-- A car that has waited at a driveway (or to turn into one, or a pocketed car to rejoin) asks the
-- lanes it must cross to leave it a gap, like a driver in a queue waving someone out: on
-- each lane the first car that can still stop holds back, nose `room` short of the spot,
-- and the cars behind queue behind it. The gap opens as the queue ahead moves on, then
-- RoadGapClear lets the car go. Without this a busy street never offered the 3 s gap, the
-- car gave up after MANEUVER_STALL_SECONDS and was pocketed -- the "abandoned" cars. The
-- caller re-asks while it waits; an unrefreshed request lapses after GAP_REQUEST_TTL.
function NPCDriverService.RequestRoadGap(vehicle: Model, pos: Vector3, targetEdgeId: string?)
	local req = Gridlock.gapReqs[vehicle]
	if req and (req.pos - pos).Magnitude < 0.5 then
		req.at = os.clock()
		return
	end
	NPCDriverService.ClearRoadGap(vehicle)
	local g = nav()
	if not g then return end
	local lanes: { [string]: number } = {}
	local crossing: string? = nil
	if targetEdgeId and Gridlock.ownLaneOnly(g, pos, targetEdgeId) then
		lanes[targetEdgeId] = distAlongEdgeNearest(g:GetEdge(targetEdgeId), pos)
	else
		local nearest = g:NearestEdge(pos)
		if not nearest or nearest.distance > REANCHOR_MAX_DIST then return end
		-- One car at a time crosses a road on a request. Two crossing a car length or so apart
		-- each held the other's lanes right over the other's spot: the whole road stood still
		-- with nothing ahead of anyone until both gave up (GATE_STALL_SECONDS, 2026-10-05).
		crossing = nearest.edge.segmentId
		local asker = Gridlock.crossAsker[crossing]
		local held = if asker and asker ~= vehicle then Gridlock.gapReqs[asker] else nil
		if held and held.crossing == crossing and os.clock() - held.at <= Tuning.GAP_REQUEST_TTL and asker.Parent then return end
		Gridlock.crossAsker[crossing] = vehicle
		for _, e in g:GetEdgesForSegment(crossing) do lanes[e.id] = distAlongEdgeNearest(e, pos) end
	end
	local room = vehicleHalfLength(vehicle) + FOLLOW_MIN_GAP + FOLLOW_BUMPER * 2 + Tuning.GAP_REQUEST_ROOM
	local new = { pos = pos, lanes = lanes, room = room, at = os.clock(), crossing = crossing }
	Gridlock.gapReqs[vehicle] = new
	for laneId in lanes do
		local byCar = Gridlock.gapLanes[laneId]
		if not byCar then
			byCar = {}
			Gridlock.gapLanes[laneId] = byCar
		end
		byCar[vehicle] = new
	end
end

function NPCDriverService.ClearRoadGap(vehicle: Model)
	local req = Gridlock.gapReqs[vehicle]
	if not req then return end
	Gridlock.gapReqs[vehicle] = nil
	if req.crossing and Gridlock.crossAsker[req.crossing] == vehicle then Gridlock.crossAsker[req.crossing] = nil end
	for laneId in req.lanes do
		local byCar = Gridlock.gapLanes[laneId]
		if byCar then
			byCar[vehicle] = nil
			if next(byCar) == nil then Gridlock.gapLanes[laneId] = nil end
		end
	end
end

-- The gap a driver waits for before pulling out of a driveway or turning across the
-- oncoming lanes into one: no vehicle on ANY lane of the road beside `pos` is alongside it or
-- will reach it within `seconds` at its current speed (cars still turning onto the road
-- count too). Both directions are checked, because the move may cross both.
function NPCDriverService.RoadGapClear(pos: Vector3, seconds: number, vehicle: Model?, leavingRoad: boolean?, targetEdgeId: string?): boolean
	local myHalf = if vehicle then vehicleHalfLength(vehicle) else FOLLOW_MIN_GAP
	local cf = if vehicle then vehicle:GetPivot() else CFrame.identity
	local size = if vehicle then vehicle:GetExtentsSize() else Vector3.zero
	local myWidth = math.min(size.X,size.Z) * 0.5
	local function followingQueue(other: DriverState): boolean
		if not leavingRoad or not vehicle or other.connector or (other.currentSpeed or 0) >= Tuning.EXIT_QUEUE_STOPPED_SPEED then return false end
		local otherCF = other.smoothCFrame
		if not otherCF or otherCF.LookVector:Dot(cf.LookVector) < 0.9 then return false end
		local offset = getStatePosition(other) - pos
		local behind = -offset:Dot(cf.LookVector)
		return behind >= myHalf + (other.halfLength or STOP_LINE_CAR_BUFFER) + FOLLOW_BUMPER - 1e-3
			and math.abs(offset:Dot(cf.RightVector)) < myWidth
	end
	local g = nav()
	local curbMerge = g ~= nil and Gridlock.ownLaneOnly(g, pos, targetEdgeId)
	local function conflicts(other: DriverState): boolean
		return not curbMerge or other.edgeId == targetEdgeId or other.nextEdgeId == targetEdgeId
	end
	local radius = myHalf + FOLLOW_MIN_GAP + FOLLOW_BUMPER * 2
	if (leavingRoad or curbMerge) and vehicle then
		if PathFollower.anyVehicleWithin(pos,radius,function(model: Model): boolean
			local other = _drivers[model]
			return other ~= nil and model ~= vehicle and conflicts(other) and not followingQueue(other)
		end) then return false end
	else
		if not NPCDriverService.IsPointClear(pos,radius) then return false end
	end
	if not g then return true end
	local nearest = g:NearestEdge(pos)
	if not nearest or nearest.distance > REANCHOR_MAX_DIST then return true end
	for _, edge in g:GetEdgesForSegment(nearest.edge.segmentId) do
		if curbMerge and edge.id ~= targetEdgeId then continue end
		local at = distAlongEdgeNearest(edge, pos)
		for _, other in _edgeDriverIndex[edge.id] or {} do
			if other.model == vehicle or followingQueue(other) then continue end
			local body = (other.halfLength or FOLLOW_MIN_GAP * 0.5) + myHalf + FOLLOW_BUMPER * 2
			local ahead = at - other.edgeDist
			if ahead > -body and ahead < (other.currentSpeed or 0) * seconds + body then
				return false
			end
		end
		for _, other in _connectorByFromEdgeIndex[edge.id] or {} do
			local clearance = (other.halfLength or STOP_LINE_CAR_BUFFER) + myHalf + FOLLOW_BUMPER * 2
			if other.model.Parent and (getStatePosition(other) - pos).Magnitude < clearance then return false end
		end
		for _, other in _connectorByNextEdgeIndex[edge.id] or {} do
			local ahead = at - other.nextEdgeDist
			if ahead > -FOLLOW_MIN_GAP and ahead < (other.currentSpeed or 0) * seconds + Tuning.FOLLOW_LOOKAHEAD then
				return false
			end
		end
	end
	return true
end

-- Queue census for TrafficSignalService's adaptive timing. Bootstrap injects
-- this as the signal service's queue provider (the signal service must not
-- require this module back -- NPCDriverService already requires it, so the
-- injection avoids a require cycle). Counts cars that are slow and near the
-- stop line on the given approach edges; the second return is how many of
-- those are waiting to turn left (or U-turn).
local SPEED_DEBUG_CAP = 250

-- Read-only: derives WHY each in-range car is at its current speed, from state
-- the driver already keeps. Called at debug-poll cadence (never per frame), so
-- it never perturbs the sim or adds replicated attributes.
local function classifySpeedReason(state: DriverState, g: any, spd: number): (string, number?)
	local limit: number? = nil
	if g and state.edgeId then
		local e = g:GetEdge(state.edgeId)
		if e then limit = e.speedLimit end
	end
	if state.connector then
		return "turn", state.connSpeedCap or limit
	end
	if spd < 0.5 then
		if (state.connBlockedTime or 0) > 0.1 then return "standoff", limit end
		if (state.blockedTime or 0) > 0.1 then return "yield", limit end
		return "stopped", limit
	end
	if (state.blockedTime or 0) > 0.1 or (state.stuckTime or 0) > 0.1 then
		return "follow", limit
	end
	if limit and spd < limit - 1 then
		return "slow", limit
	end
	return "cruise", limit
end

-- Where this vehicle is ON THE LANE GRAPH: the lane edge it occupies and how far along
-- it. This is the anchor a save needs -- edge ids are "S<segmentId>:L<laneIndex>:<F|R>",
-- built entirely from a segment id (which RoadSerializer preserves verbatim) and geometry
-- (which does not renumber), so they survive a save/load for any road left unedited.
-- A world position does NOT survive as well: it has to be re-projected onto a lane on the
-- way back in, which is where a queue loses its spacing.
--
-- A car mid-turn (on a junction connector) reports the lane it is LEAVING, at that lane's
-- end -- restoring it there simply has it make the turn again.
-- How far along the lane the entry path leads before the traffic AI takes over. Long enough
-- that the last movement of the off-graph leg is unmistakably ALONG the lane (so the vehicle
-- ends up facing down it), short enough to stay inside a normal first edge.
local LANE_ENTRY_LEAD = 6

-- Where a road leg would seat a vehicle, plus a short lead along the lane after it.
--
-- DriveDirected seats a vehicle at the point of route[1] nearest the position it is given.
-- An off-graph leg (a driveway pull-out, a depot yard, an arrival at the map edge) ends at a
-- lot mouth or a kerb, which is metres to the SIDE of the lane centreline and usually facing
-- across it -- so the vehicle jumped sideways onto the lane and span to the lane heading in a
-- single frame. That is the "teleport" coming out of a driveway.
--
-- Finish the off-graph leg on the points this returns and the road leg starts exactly where
-- the vehicle already stands, pointing the way it is already pointing. Returns nil when the
-- edge is unknown, so a caller can fall back to the old behaviour rather than fail the trip.
function NPCDriverService.LaneExitPoint(edgeId: string, destination: Vector3, vehicle: Model): Vector3
	local g = nav()
	local edge = g and g:GetEdge(edgeId)
	if not edge then return destination end
	local at = distAlongEdgeNearest(edge,destination)
	local distance = math.max(0,at-vehicleHalfLength(vehicle)-FOLLOW_BUMPER*2)
	return (PathFollower.pointAtDist(edge.points,PathFollower.getCum(edge),distance))
end

function NPCDriverService.LaneEntryPath(edgeId: string, fromPos: Vector3, lead: number?, vehicle: Model?): { Vector3 }?
	local g = nav()
	if not g or typeof(edgeId) ~= "string" then return nil end
	local edge = g:GetEdge(edgeId)
	if not edge or not edge.points or #edge.points < 2 then return nil end
	local cum = PathFollower.getCum(edge)
	local total = cum[#cum] or 0
	if total <= 0 then return nil end
	local limit = total
	if vehicle and isIntersectionNode(g,edge.toNode) then
		limit = math.max(0,total-getStopLineGap(g,edge.toNode,edge)-noseSetback({halfLength=vehicleHalfLength(vehicle)} :: any))
	end
	local d0 = math.clamp(distAlongEdgeNearest(edge, fromPos), 0, limit)
	local entry = PathFollower.pointAtDist(edge.points, cum, d0)
	-- Never lead so far that the vehicle is seated at the very end of the first edge: capped
	-- to a fraction of it, a short edge simply gets a shorter lead.
	local step = math.min(lead or LANE_ENTRY_LEAD, total * 0.4)
	local d1 = math.min(limit, d0 + step)
	-- On the asphalt, not the slab middle: the off-graph leg follows these at the vehicle's
	-- plain clearance (see LANE_SURFACE), so the road leg it hands over to starts level.
	local lift = Vector3.new(0, LANE_SURFACE, 0)
	if d1 - d0 < 0.05 then return { entry + lift } end
	-- Parenthesised: pointAtDist returns (position, tangent), and a bare call in the LAST
	-- slot of a table constructor expands BOTH -- which appended the tangent as a third
	-- "waypoint" near the world origin for the vehicle to drive to.
	return { entry + lift, (PathFollower.pointAtDist(edge.points, cum, d1)) + lift }
end

function NPCDriverService.GetRestoreSeat(model: Model, anchor: {edgeId: string, dist: number}): (CFrame?, number?)
	local g = nav()
	local edge = g and g:GetEdge(anchor.edgeId)
	if not edge or typeof(anchor.dist) ~= "number" or anchor.dist ~= anchor.dist then return nil, nil end
	local size = model:GetExtentsSize()
	local half = math.max(size.X, size.Z) * 0.5
	local cum = PathFollower.getCum(edge)
	local stopAt = (cum[#cum] or 0) - getStopLineGap(g, edge.toNode, edge)
		- noseSetback({halfLength=half} :: any) - 0.1
	local dist = math.clamp(anchor.dist, 0, math.max(0, stopAt))
	local pos, direction = PathFollower.pointAtDist(edge.points, cum, dist)
	local height = model:GetAttribute("NPCHeightOffset")
	local lift = if typeof(height) == "number" then height else size.Y * 0.5 + 0.05
	pos += Vector3.new(0, lift + LANE_SURFACE, 0)
	return CFrame.lookAt(pos, pos + direction), dist
end

function NPCDriverService.GetLaneAnchor(model: Model): { edgeId: string, dist: number }?
	local state = _drivers[model]
	if not state or not model.Parent then return nil end
	if typeof(state.edgeId) ~= "string" then return nil end
	return { edgeId = state.edgeId, dist = state.edgeDist or 0 }
end

function NPCDriverService.GetDriverRouteDebug(model: Model): { [string]: any }?
	local state = _drivers[model]
	local g = nav()
	if not state or not g or not model.Parent then return nil end

	local points: { Vector3 } = {}
	local function appendPoint(point: Vector3)
		local last = points[#points]
		if #points < 600 and (not last or (last - point).Magnitude > 0.05) then
			table.insert(points, point)
		end
	end
	local function appendEdge(edge: any, fromDist: number, toDist: number)
		local cum = PathFollower.getCum(edge)
		local total = cum[#cum] or edge.length or 0
		local first = math.clamp(fromDist, 0, total)
		local last = math.clamp(toDist, first, total)
		local startPos = PathFollower.pointAtDist(edge.points, cum, first)
		appendPoint(startPos)
		for i, distance in cum do
			if distance > first and distance < last then appendPoint(edge.points[i]) end
		end
		local endPos = PathFollower.pointAtDist(edge.points, cum, last)
		appendPoint(endPos)
	end

	appendPoint(getStatePosition(state))
	local route = state.route
	local routeIndex = state.routeIndex or 1
	if state.connector and state.connCum then
		local connectorTotal = state.connCum[#state.connCum] or 0
		local startPos = PathFollower.pointAtDist(state.connector, state.connCum, state.connDist)
		appendPoint(startPos)
		for i, distance in state.connCum do
			if distance > state.connDist then appendPoint(state.connector[i]) end
		end
		if connectorTotal > state.connDist then
			local endPos = PathFollower.pointAtDist(state.connector, state.connCum, connectorTotal)
			appendPoint(endPos)
		end
	end

	if route then
		local firstIndex = if state.connector then routeIndex + 1 else routeIndex
		for i = firstIndex, #route do
			local edge = g:GetEdge(route[i])
			if edge then
				local fromDist = if i == routeIndex then state.edgeDist
					elseif i == firstIndex and state.connector then state.nextEdgeDist
					else 0
				local toDist = if i == #route then (state.finalDist or edge.length) else edge.length
				appendEdge(edge, fromDist, toDist)
				local nextId = route[i + 1]
				if nextId then
					for _, p in g:GetConnectionPoints(edge.id, nextId) do appendPoint(p) end
				end
			end
		end
	else
		local edge = g:GetEdge(state.edgeId)
		if edge and not state.connector then appendEdge(edge, state.edgeDist, edge.length) end
		local nextId = state.nextEdgeId or state.pendingNextEdgeId
		local nextEdge = nextId and g:GetEdge(nextId)
		if edge and nextEdge then
			for _, p in g:GetConnectionPoints(edge.id, nextEdge.id) do appendPoint(p) end
			appendEdge(nextEdge, state.nextEdgeDist or 0, nextEdge.length)
		end
	end

	local congestion = if state.edgeId then g:GetEdgeCongestion(state.edgeId) else 0
	local edge = g:GetEdge(state.edgeId)
	local nextId = if route then route[routeIndex+1] else state.pendingNextEdgeId
	local junction: {any} = {}
	local exitQueue: {any} = {}
	local exit = nextId and g:GetEdge(nextId)
	if nextId then
		for _, bucket in {_edgeDriverIndex[nextId] or EMPTY, _connectorByNextEdgeIndex[nextId] or EMPTY} do
			for _, other in bucket do
				table.insert(exitQueue, {id=other.model:GetAttribute("NpcId"),name=other.model.Name,
					dist=lanePos(other,nextId),speed=other.currentSpeed,halfLength=other.halfLength,
					connector=other.connector~=nil})
			end
		end
	end
	local block = nil
	if edge and nextId then
		local move = edge.outMovement and edge.outMovement[nextId] or "straight"
		if boxHasConflict(g,state,edge,edge.toNode,edge.toDir,move) then block="occupiedBox"
		elseif not signalizedClear(g,state,edge,edge.toNode,edge.toDir,move) then block="oncoming" end
		for _,incoming in g._edgesByToNode[edge.toNode] or {} do
			for _,other in _edgeDriverIndex[incoming.id] or EMPTY do
				local distance=distToStopLine(g,other,incoming,edge.toNode)
				if distance<50 then table.insert(junction,{id=other.model:GetAttribute("NpcId"),edge=incoming.id,
					distance=distance,speed=other.currentSpeed,connector=other.connector~=nil,
					nextEdge=other.pendingNextEdgeId,canGo=TrafficSignalService.CanGo(incoming.id,other.pendingNextEdgeId)}) end
			end
		end
	end
	return {
		kind = if route then "directed vehicle" else "ambient vehicle",
		name = model.Name,
		polyline = points,
		destination = state.goalPos,
		routeIndex = state.routeIndex,
		routeLength = if route then #route else nil,
		speed = state.currentSpeed or state.speed or 0,
		stopReason = state.stopReason or "moving",
		congestion = congestion,
		junctionBlock = block, junction = junction, exitQueue = exitQueue,
		exitLength = if exit then exit.length else nil,
		exitBoxDepth = if nextId then select(2,g:GetConnectionSetbacks(state.edgeId,nextId)) else nil,
		trafficReroutes = state.trafficReroutes or 0,
		edgeId = state.edgeId,
		edgeDist = state.edgeDist,
		blockedBy = if state.blockedBy then state.blockedBy:GetAttribute("NpcId") else nil,
		canGo = TrafficSignalService.CanGo(state.edgeId,if route then route[routeIndex+1] else state.pendingNextEdgeId),
		exitHasRoom = if route and route[routeIndex+1] then exitLaneHasRoom(g,state,route[routeIndex+1]) else nil,
		nextEdgeId = if route then route[(state.routeIndex or 1)+1] else state.pendingNextEdgeId,
		signal = if state.edgeId and g:GetEdge(state.edgeId) then TrafficSignalService.GetNodeEditorSnapshot(g:GetEdge(state.edgeId).toNode) else nil,
		reason = if route
			then "A* chose the lowest distance plus live-congestion cost. The car only reroutes after a sustained jam and a meaningful improvement."
			else "Ambient traffic follows its lane and locks one legal outgoing road before entering each junction.",
	}
end

function NPCDriverService.GetSpeedDebug(): { any }
	local out: { any } = {}
	local g = nav()
	local n = 0
	for model, state in _drivers do
		if n >= SPEED_DEBUG_CAP then break end
		if model and model.Parent then
			local spd = state.currentSpeed or state.speed or 0
			local reason, limit = classifySpeedReason(state, g, spd)
			if state.stopReason then reason = state.stopReason end
			n += 1
			table.insert(out, {
				id = ensureDebugId(model),
				model = model,
				name = model.Name,
				kind = if state.route then "directed" else "ambient",
				speed = math.round(spd),
				limit = limit,
				reason = reason,
				routeIndex = state.routeIndex,
				routeLength = if state.route then #state.route else nil,
				congestion = if g and state.edgeId then g:GetEdgeCongestion(state.edgeId) else 0,
				trafficReroutes = state.trafficReroutes or 0,
			})
		end
	end
	return out
end

-- ----------------------------------------------------------- dev panel --
-- Read-only feeds for the Developer panel (DeveloperService aggregates them).
-- Never mutate sim state, never add replicated attributes; called at poll cadence.

local DEV = table.freeze({ STOPLINE_CAP = 3500, STOPLINE_WIDTH = 7, STUCK_SECONDS = 3 })

local function devWithinRadius(camPos: Vector3?, radiusSq: number, p: Vector3): boolean
	if not camPos then return true end
	local dx = p.X - camPos.X
	local dz = p.Z - camPos.Z
	return (dx * dx + dz * dz) <= radiusSq
end

-- Live driver census: counts, average speed, reroute total, and a histogram of the
-- WHY-stopped reasons. Cheap (walks _drivers only), so the report polls it directly.
-- Vehicles on the road AI as of the last sweep (a few times a second), for the shared
-- Const.NPC_MAX_ACTIVE budget. ponytail: lags spawns by up to SWEEP_EVERY_TICKS ticks.
function NPCDriverService.ActiveCarCount(): number
	return NPCDriverService._activeCars or 0
end

function NPCDriverService.GetTrafficStats(): { [string]: any }
	local g = nav()
	local active, moving, stopped, stuck, directed, ambient, reroutes = 0, 0, 0, 0, 0, 0, 0
	local speedSum = 0
	local reasons: { [string]: number } = {}
	for model, state in _drivers do
		if not model.Parent then continue end
		active += 1
		local spd = state.currentSpeed or state.speed or 0
		speedSum += spd
		if state.route then directed += 1 else ambient += 1 end
		reroutes += state.trafficReroutes or 0
		if (state.stuckTime or 0) > DEV.STUCK_SECONDS then stuck += 1 end
		if spd < 0.5 then stopped += 1 else moving += 1 end
		local reason = classifySpeedReason(state, g, spd)
		if state.stopReason then reason = state.stopReason end
		reasons[reason] = (reasons[reason] or 0) + 1
	end
	return {
		active = active, moving = moving, stopped = stopped, stuck = stuck,
		directed = directed, ambient = ambient, reroutes = reroutes,
		avgSpeed = if active > 0 then speedSum / active else 0,
		reasons = reasons,
	}
end

-- Stop-line geometry: for every intersection-approach lane within radius, WHERE a car
-- should stop (the painted stop line / setback the AI actually uses) plus the live
-- right-of-way state -- signal go/stop, or unsignalized priority/yield. The Developer
-- panel draws these so "where they should stop" can be compared against where they do.
function NPCDriverService.GetTrafficDebug(camPos: Vector3?, radius: number?): { [string]: any }
	local g = nav()
	if not g or not g:HasEdges() then
		return { stopLines = {}, stats = NPCDriverService.GetTrafficStats(), truncated = false }
	end

	local r = if typeof(radius) == "number" and radius == radius then radius else 1e9
	local radiusSq = r * r
	local stopLines: { any } = {}
	local truncated = false

	for _, edge in g:GetEdges() do
		if #stopLines >= DEV.STOPLINE_CAP then
			truncated = true
			break
		end
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then continue end
		if not devWithinRadius(camPos, radiusSq, pts[#pts]) then continue end
		if not isIntersectionNode(g, edge.toNode) then continue end

		local cum = PathFollower.getCum(edge)
		local total = cum[#cum] or edge.length or 0
		local stopDist = math.max(0, total - getStopLineGap(g, edge.toNode, edge))
		local pos = PathFollower.pointAtDist(pts, cum, stopDist)
		local dir = flatUnit(edge.toDir)

		local state: string
		if isSignalizedIntersection(edge.toNode) then
			state = if TrafficSignalService.CanGo(edge.id) then "go" else "stop"
		else
			state = if getArmPriority(g, edge.toNode, edge.id) == "major" then "priority" else "yield"
		end

		table.insert(stopLines, { pos = pos, dir = dir, w = DEV.STOPLINE_WIDTH, state = state })
	end

	return { stopLines = stopLines, stats = NPCDriverService.GetTrafficStats(), truncated = truncated }
end

-- Drivable lane network within radius: each lane's centreline + its live congestion
-- (0 clear .. 1 jammed) for colour-coding, and the end-points of dead-end lanes (no
-- legal non-U-turn exit) -- a direct "broken road graph" signal for the Developer panel.
function NPCDriverService.GetLaneDebug(camPos: Vector3?, radius: number?): { [string]: any }
	local g = nav()
	if not g or not g:HasEdges() then
		return { lanes = {}, deadEnds = {}, truncated = false }
	end

	local r = if typeof(radius) == "number" and radius == radius then radius else 1e9
	local radiusSq = r * r
	local lanes: { any } = {}
	local deadEnds: { Vector3 } = {}
	local truncated = false

	for _, edge in g:GetEdges() do
		if #lanes >= DEV.STOPLINE_CAP then
			truncated = true
			break
		end
		local pts = edge.points
		if typeof(pts) ~= "table" or #pts < 2 then continue end
		if not devWithinRadius(camPos, radiusSq, pts[1]) then continue end

		table.insert(lanes, { p = pts, c = g:GetEdgeCongestion(edge.id) or 0 })

		local hasExit = false
		for _, toId in edge.out do
			if edge.outMovement[toId] ~= "uturn" then
				hasExit = true
				break
			end
		end
		if not hasExit then
			table.insert(deadEnds, pts[#pts])
		end
	end

	return { lanes = lanes, deadEnds = deadEnds, truncated = truncated }
end

-- Hotspot feed for the Developer panel's jam heatmap. It reuses the same driver state
-- and stop-reason classifier as the speed debugger, but returns only compact positions
-- so the overlay can draw local-only heat pillars without touching replicated state.
function NPCDriverService.GetJamDebug(camPos: Vector3?, radius: number?): { any }
	local g = nav()
	local r = if typeof(radius) == "number" and radius == radius then radius else 1e9
	local radiusSq = r * r
	local out: { any } = {}
	-- Plain words for the overlay label (DeveloperController's jam layer).
	local words = { carAhead = "queued", blocked = "blocked", redLight = "red light", yield = "giving way",
		laneChange = "waiting for a gap to change lane", roadGap = "letting a car out", turn = "turning", slow = "slow", cruise = "moving" }

	for model, state in _drivers do
		if #out >= SPEED_DEBUG_CAP then break end
		if not model.Parent then continue end
		local pos = getStatePosition(state)
		if not devWithinRadius(camPos, radiusSq, pos) then continue end

		local spd = state.currentSpeed or state.speed or 0
		local reason = classifySpeedReason(state, g, spd)
		if state.stopReason then reason = state.stopReason end
		local stuckSeconds = math.max(state.stuckTime or 0, state.blockedTime or 0, state.connBlockedTime or 0)
		local congestion = if g and state.edgeId then (g:GetEdgeCongestion(state.edgeId) or 0) else 0
		if stuckSeconds >= 0.4 or congestion >= 0.35 or spd < 2 then
			-- Who it waits on: the car right in front with no room to it, else (queued) its
			-- queue leader -- which may be mid-turn, or mid lane change in the next lane.
			local by: Model? = state.blockedBy
			if not by and reason == "carAhead" then
				local lead = getNearestQueueLeader(state)
				by = if lead then lead.model else nil
			end
			local why = if laneChangeOf(state) then "mid lane-change" else (words[reason] or tostring(reason))
			if by then
				local byState = _drivers[by]
				why ..= " behind #" .. tostring(by:GetAttribute("NpcId") or "?")
					.. (if not byState then " (not driving)" elseif (byState.currentSpeed or 0) < 0.5 then " (stopped)" else "")
			end
			table.insert(out, {
				id = model:GetAttribute("NpcId"),
				why = why,
				still = state.noProgressTime or 0,
				pos = pos,
				seconds = stuckSeconds,
				speed = spd,
				reason = reason,
				congestion = congestion,
				name = model.Name,
				kind = if state.route then "directed" else "ambient",
			})
		end
	end

	table.sort(out, function(a, b)
		local aw = (tonumber(a.seconds) or 0) + (tonumber(a.congestion) or 0) * 8
		local bw = (tonumber(b.seconds) or 0) + (tonumber(b.congestion) or 0) * 8
		return aw > bw
	end)
	return out
end

-- Where a car on the road AI really is. Its model's pivot is NOT that while it drives (the pose
-- is streamed; the instance still stands where the car spawned), so a save must ask here.
function NPCDriverService.GetLivePose(model: Model): CFrame?
	local state = _drivers[model]
	return if state then state.smoothCFrame else nil
end

-- Debug only: the live driver records, for server-side probes of a running city. Read, never
-- write -- every field belongs to this service.
function NPCDriverService.DebugDriverStates(): { [Model]: any }
	return _drivers
end

function NPCDriverService.GetSignalQueue(edgeIds: { string }): (number, number)
	local g = nav()
	if not g then return 0, 0 end

	local total, left = 0, 0
	for _, edgeId in ipairs(edgeIds) do
		local bucket = _edgeDriverIndex[edgeId]
		if not bucket then continue end
		local edge = g:GetEdge(edgeId)
		if not edge then continue end

		local cum = PathFollower.getCum(edge)
		local stopDist = (cum[#cum] or 0) - getStopLineGap(g, edge.toNode, edge)
		for _, other in ipairs(bucket) do
			if not other.model.Parent then continue end
			local distToStop = stopDist - other.edgeDist
			if distToStop > -2 and distToStop <= TrafficConfig.QUEUE_ZONE
				and (other.currentSpeed or 0) <= TrafficConfig.QUEUE_MAX_SPEED then
				total += 1
				local nextId = other.pendingNextEdgeId
				local movement = if nextId and edge.outMovement then edge.outMovement[nextId] else nil
				if movement == crossingTurn() or movement == "uturn" then
					left += 1
				end
			end
		end
	end
	return total, left
end

function NPCDriverService.Init(roadService: any)
	_roadService = roadService
end

function NPCDriverService.Bind()
	if _bound then return end
	_bound = true

	local RS  = game:GetService("ReplicatedStorage")
	local Net = require(RS:WaitForChild("Networker"))

	NetMiddleware.RegisterServerRateLimit(Net.ReportCameraPos, Tuning.CAM_REPORT_MIN_DT)

	Net.ReportCameraPos.OnServerEvent:Connect(function(player: Player, camPos: any)
		if not NetMiddleware.CheckServerRate(Net.ReportCameraPos, player) then return end
		local pos: Vector3? = nil
		local focus: Vector3? = nil
		if typeof(camPos) == "Vector3" then
			pos = camPos
		elseif typeof(camPos) == "table" and typeof(camPos.pos) == "Vector3" then
			pos = camPos.pos
			-- Ground look-at from {pos, yaw, pitch}, as Bootstrap's streaming focus does.
			local yaw, pitch = tonumber(camPos.yaw), tonumber(camPos.pitch)
			if yaw and pitch and yaw == yaw and pitch == pitch then
				local cosP = math.cos(math.rad(pitch))
				local dir = Vector3.new(-math.sin(math.rad(yaw)) * cosP, math.sin(math.rad(pitch)), -math.cos(math.rad(yaw)) * cosP)
				if dir.Y < -0.05 then
					local hit = camPos.pos + dir * ((RoadConstants.getGroundY() - camPos.pos.Y) / dir.Y)
					local h = RoadConstants.MAP_HALF_EXTENT
					focus = Vector3.new(math.clamp(hit.X, -h, h), hit.Y, math.clamp(hit.Z, -h, h))
				end
			end
		end
		if pos then
			PathFollower.setCameraPos(player, pos, focus)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		PathFollower.clearPlayer(player)
		NetMiddleware.OnPlayerRemoving(player)
	end)
end

-- A car that reaches an outside connection heading OUTWARD has left the city: despawn it
-- so it vanishes cleanly at the edge instead of driving off the map into the void. Arrivals
-- head INWARD here (look.Dot(normal) < 0), so they are never caught. Injected after boot.
local _outsideConnService: any = nil
function NPCDriverService.SetOutsideConnService(svc: any)
	_outsideConnService = svc
end

local ConnDespawn = table.freeze({
	RADIUS = 12,      -- studs from a connection: heading OUT here = left the city
	NEAR_RADIUS = 40, -- studs from a connection: counts as "at the entrance"
	-- Counted on the watchdog's no-progress clock, which a car waiting in traffic never runs, so
	-- a queue at the entrance is never culled. Real wedges still clear well before the watchdog.
	STUCK_TIME = 15,  -- s stalled (bugged) at the entrance, either direction, before we clear it
})
local _lastConnDespawnWarn = 0
-- True if this car should be cleared at an outside connection: it is either heading OUT
-- (left the city) or it has been wedged at the entrance too long (the recurring jam). Logs
-- why, rate-limited, so a stuck car at a connection is self-explaining in the output.
local function despawnAtConnection(model: Model, state: DriverState): boolean
	if not _outsideConnService then return false end
	-- Where the car really is. Its model's CFrame is where it SPAWNED: the server streams
	-- poses and never writes it, so for a car that came in here it sat at this entrance for
	-- life -- and any such car stuck for STUCK_TIME anywhere on the map was "wedged at the
	-- connection" and deleted.
	local cf = state.smoothCFrame
	if not cf then return false end
	local pos, look = cf.Position, cf.LookVector
	for _, c in _outsideConnService.list() do
		local dx, dz = pos.X - c.outer.X, pos.Z - c.outer.Z
		local dist2 = dx * dx + dz * dz
		local outward = look:Dot(c.normal) > 0.3
		-- Waiting in traffic is not wedged, however long the jam. Culling the head of the
		-- queue there ate a busy entrance one car at a time, and the queue behind simply fed
		-- the next victim forward -- which is most of what "cars keep despawning" looks like
		-- on a packed road. noProgressTime only runs while no traffic reason explains the
		-- stop (waitingInTraffic), so only a bugged car is cleared here.
		local wedged = (state.noProgressTime or 0) >= ConnDespawn.STUCK_TIME
		if (dist2 < ConnDespawn.RADIUS * ConnDespawn.RADIUS and outward)
			or (dist2 < ConnDespawn.NEAR_RADIUS * ConnDespawn.NEAR_RADIUS and wedged) then
			-- Only the wedged case is worth a line. A car pointing outward at a connection is
			-- simply leaving the map -- the single commonest event in the whole sim -- and
			-- logging it buried everything else in the Output. Being WEDGED means it had to be
			-- force-cleared, which is a fault and still reports itself.
			if not outward and os.clock() - _lastConnDespawnWarn > 10 then
				_lastConnDespawnWarn = os.clock()
				warn(("[NPCDriverService] cleared WEDGED car at outside connection %s (stuck %.1fs, %.0f studs, reason=%s)")
					:format(tostring(c.id), state.noProgressTime or 0, math.sqrt(dist2), tostring(state.stopReason)))
			end
			return true
		end
	end
	return false
end

local function updateAndIndexDriver(state: DriverState, dt: number)
	updateDriver(state,dt)
	if state.model.Parent then stallWatchdog(state,dt) end
	if _drivers[state.model]==state then reindexDriver(state) end
end

local function safeUpdateDriver(state: DriverState, dt: number): boolean
	local ok, cause = xpcall(updateAndIndexDriver,debug.traceback,state,dt)
	if ok then return true end
	warn(("[NPCDriverService] update failed for %s on %s: %s"):format(state.model.Name,state.edgeId,tostring(cause)))
	-- Settle the owner's trip and remove its indexes before processing the next car.
	if state.route then abortDirected(state) else despawnDriver(state) end
	return false
end

function NPCDriverService.Start()
	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end

	_spawnedOnce = trySpawn()

	local tickAccum = 0
	local sweepIn = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		tickAccum += math.min(dt, Tuning.MAX_SIM_DT)
		if tickAccum < Tuning.DRIVER_TICK then return end
		local simDt = math.min(tickAccum, Tuning.MAX_SIM_DT)
		tickAccum = 0
		PathFollower.keepalive()

		if not _spawnedOnce then
			if trySpawn() then
				_spawnedOnce = true
			end
			return
		end

		-- Level of detail by distance to the nearest viewer (see FAR_LOD_DIST and below):
		-- within the full-rate stream band every tick (Tuning.DRIVER_TICK), out to FAR_LOD_DIST at
		-- MID_TICK, out to the stream's reach at FAR_TICK, and past it at DISTANT_TICK.
		local speed = GameSpeed.steps()

		-- Cars destroyed from outside (not through despawn/abort, which clean up at once) are
		-- swept out a few times a second, not every tick: at ten thousand cars the sweep's
		-- engine reads (model.Parent) were a cost of their own. A car updating checks its
		-- own model anyway, and every scan re-checks the one car it picks.
		sweepIn -= 1
		if sweepIn <= 0 then
			sweepIn = Tuning.SWEEP_EVERY_TICKS
			local live = 0
			for model, state in pairs(_drivers) do
				if not model.Parent then
					releaseBooking(state)
					unindexDriver(state)
					_drivers[model] = nil
					PathFollower.forget(model)
				else
					live += 1
				end
			end
			NPCDriverService._activeCars = live
			-- A lane-index entry that is not a live driver is a ghost: an invisible car the
			-- queue behind it waits on for ever, read as traffic so never rescued. Whatever
			-- path leaves one, it goes here -- and says so, so the path can be found.
			local ghosts = 0
			for _, index in ALL_INDEXES do
				for _, bucket in index :: { [any]: { any } } do
					for i = #bucket, 1, -1 do
						local s = bucket[i]
						if _drivers[s.model] ~= s then
							table.remove(bucket, i)
							ghosts += 1
						end
					end
				end
			end
			if ghosts > 0 then
				warn(`[NPCDriverService] dropped {ghosts} lane-index entries of cars no longer driving`)
			end
		end
		for _, state in _joined do
			if _drivers[state.model] == state and not state.ix then reindexDriver(state) end
		end
		table.clear(_joined)
		-- Road edits change edge ids: file every car afresh. Otherwise the indexes are kept
		-- up to date car by car (reindexDriver).
		do
			local g0 = nav()
			if (if g0 then g0:Version() else -1) ~= _indexGraphVersion then rebuildDriverIndexes() end
		end

		local tickStart = os.clock()
		if speed <= 0 then return end
		local scaledDt = simDt * speed
		local substeps = math.max(1, math.ceil(scaledDt / Tuning.DRIVER_MAX_STEP - 1e-6))
		simDt = scaledDt / substeps
		for _ = 1, substeps do
			_simClock += simDt
			RerouteBudget.tokens = math.min(RerouteBudget.BURST, RerouteBudget.tokens + simDt * RerouteBudget.RATE)
			local g = nav()
			if g then publishCongestionSnapshot(g) end
			for model, state in pairs(_drivers) do
				if tickStart >= (state.lodCheckAt or 0) then
					state.lodCheckAt = tickStart + Tuning.LOD_RECHECK * (0.75 + math.random() * 0.5)
					local d2 = PathFollower.nearestPlayerDistSq(getStatePosition(state))
					state.lodFar = d2 > Tuning.FAR_LOD_DIST_SQ
					state.lodDistant = d2 > Tuning.DISTANT_LOD_DIST_SQ
					state.lodMid = not state.lodFar and d2 > Tuning.NEAR_LOD_DIST_SQ
				end
				-- A random first phase, so cars spawned together (a load, a road edit) do not
				-- all take their far/distant steps on the same tick.
				state.lodAccum = (state.lodAccum or math.random() * DISTANT_TICK) + simDt
				local maxDt = Tuning.FAR_MAX_DT
				if state.lodFar then
					local every = if state.lodDistant then DISTANT_TICK else FAR_TICK
					if state.lodAccum < every then continue end
					if state.lodDistant then maxDt = Tuning.DISTANT_MAX_DT end
				elseif state.lodMid then
					if state.lodAccum < MID_TICK - 1e-6 then continue end
					maxDt = Tuning.MID_MAX_DT
				end
				-- Only a car about to think pays the engine read (the sweep catches the rest).
				if not model.Parent then continue end
				local stepDt = math.min(state.lodAccum, math.max(maxDt, simDt))
				state.lodAccum -= stepDt

				if despawnAtConnection(model, state) then
					-- A DIRECTED car belongs to its service (citizen/delivery) and its
					-- onArrive/onAbort contract must hold. despawnDriver() destroyed the
					-- model with neither fired, so the caller's directed-trip and car
					-- counters leaked +1 per kill until every budget read full -- then
					-- move-in drive-ins silently stopped and arrivals sat at entrances
					-- in retry loops (the recurring entrance jam). Abort instead: the
					-- owner parks the car at its destination and the books stay right.
					if state.route then
						abortDirected(state)
					else
						despawnDriver(state)
					end
				else
					safeUpdateDriver(state, stepDt)
				end
			end
		end
	end)
end

table.freeze(Tuning)
return NPCDriverService