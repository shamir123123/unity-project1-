--!strict
local GameSpeed = require(game:GetService("ReplicatedStorage").GameSpeed)
-- TransitService
-- Owns the public-transit domain: player-placed Bus Depots and Bus Stops, and the bus
-- ROUTES drawn between stops. It is the single source of truth for that data -- it
-- validates the placement/route remotes, snaps stops to the kerb, names them, auto-paths
-- each route along the road network, persists everything, answers "is transit a good
-- option for this trip?" for CitizenService, and feeds the economy fares + upkeep.
--
-- It does NOT drive the buses -- BusDispatchService owns the runtime fleet and reads
-- routes/stops/depots from here. Mirrors EmergencyService for placement + persistence
-- and exposes a small wire snapshot via SyncTransit for the route overlay + overview UI.

local CollectionService   = game:GetService("CollectionService")
local Workspace           = game:GetService("Workspace")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local TransitTypes     = require(ReplicatedStorage.Transit.TransitTypes)
local RoadTypeCatalog  = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants    = require(ReplicatedStorage.Road.RoadConstants)
local BezierUtil       = require(ReplicatedStorage.Road.BezierUtil)
local VehicleTypes     = require(ReplicatedStorage.Road.VehicleTypes)
local DriverProfile    = require(ReplicatedStorage.Road.DriverProfile)
local Quant            = require(ReplicatedStorage.Shared.Quant)
local NetMiddleware    = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local TerrainPadService = require(ServerScriptService.Services.Terrain.TerrainPadService)
local TransitKitModel = require(ServerScriptService.Services.Transit.TransitKitModel)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local TrainBuildingModel = require(ServerScriptService.Services.Transit.TrainBuildingModel)
local ServicePlacement = require(ServerScriptService.Services.City.ServicePlacement)
local AddressBook      = require(ReplicatedStorage.City.AddressBook)
local CitySimConstants = require(ServerScriptService.Services.City.CitySimConstants)

local TransitService = {}
local _rideDistanceCache: {[any]: {[string]: number}} = setmetatable({}, {__mode="k"}) :: any

-- == Tuning ====================================================================
local CMD_COOLDOWN     = 0.05  -- per-player min gap between transit commands
local PLACE_COOLDOWN   = 0.15
local STOP_MAX_ROAD_DIST = 36 * RoadConstants.WORLD_SCALE  -- a stop guess further than this from any lane is rejected
local STOP_SEGMENT_LINK_TOLERANCE = 18 * RoadConstants.WORLD_SCALE -- handles segment ids changed by splits/reforms
local SYNC_INTERVAL    = 1.5   -- seconds between live-stat broadcasts
local ROUTE_REBUILD_DEBOUNCE = 0.15
local WALK_SPEED       = 5 * RoadConstants.WORLD_SCALE -- studs/s, NPCWalkingService.WALK_SPEED: the estimate uses the pace people really walk
local BUS_SPEED_EST    = 24 * RoadConstants.WORLD_SCALE -- studs/s, effective bus speed incl. stops (for the estimate)
local TRAIN_SPEED_EST  = 55 * RoadConstants.WORLD_SCALE -- studs/s, effective train speed incl. station dwells
local RIDE_DETOUR      = 1.25  -- straight-line distance -> ride distance fudge
local TRACK_REACH      = 40 * RoadConstants.WORLD_SCALE -- a rail building's gap to its track, beyond its half-size
local MONTH_TICKS      = CitySimConstants.MONTH_TICKS -- economy ticks (fare drains) in one month
local USAGE_SMOOTHING  = 0.1   -- share of each departure's load folded into a line's usage %

-- == Stop naming ===============================================================
-- A stop is named for the landmark it serves when there is one within sight, and
-- for its street address otherwise -- the convention every real transit map uses.
-- Street names themselves come from AddressBook (the city-wide source of truth),
-- not from anything transit owns.
local LANDMARK_RADIUS = 90 * RoadConstants.WORLD_SCALE
-- ServiceName is the display name EmergencyService + EducationService already
-- stamp on their models, so no new data is needed to name a stop after one.
local LANDMARK_FOLDERS = { "EmergencyServices", "Schools" }

-- addressIndex + landmarkNear live further down, next to placeStop: they read
-- _roadService, which is not declared until the state section below.


-- == State =====================================================================
type Depot = {
	id: number, key: string, cf: CFrame, entrance: Vector3, model: Model,
	layout: number?, bays: { TransitKitModel.Bay }?, -- kit depots: the chosen layout + its bays in the world
}
type Stop = {
	id: number, key: string, pos: Vector3, roadPos: Vector3, facing: CFrame,
	segmentId: number, edgeId: string?, name: string, model: Model,
	mode: string, -- "bus" | "train": which nav graph the stop boards from
	-- interchanges (bus hub / station): where buses rejoin the road after a platform, and the platforms
	exitPos: Vector3?, bays: { TransitKitModel.Bay }?,
	kerbBay: boolean?, -- a kerb stop whose `bays` is the parking lane beside it (not an interchange)
	-- live ridership stat (boardings this economy-month; runtime only, not persisted)
	boardings: number, displayBoardings: number,
}
type Route = {
	id: number, name: string, color: Color3, colorIndex: number, enabled: boolean,
	mode: string, -- "bus" | "train"; busCount counts vehicles of that mode
	fare: number, busCount: number, closed: boolean,
	stops: { number },                 -- ordered stop ids
	waypoints: { [number]: { Vector3 } }, -- leg index -> shaping points
	pending: { Vector3 },              -- waypoints accumulating for the next leg
	-- derived
	path: { Vector3 },
	legEdges: { { string } },
	legPaths: { { Vector3 } }, -- per-leg polylines (TrainDispatchService rides these; server-only)
	tailPath: { Vector3 }?,    -- a line being drawn: last stop -> the road points clicked since (preview only)
	lengthStuds: number,
	-- live (set by BusDispatchService)
	activeBuses: number, passengers: number, displayPassengers: number, usage: number,
	-- live fare income this economy-month (runtime only, not persisted)
	revenue: number, displayRevenue: number,
	-- train lines, set by TrainDispatchService: the train type running it and what, if
	-- anything, is wrong with it (shown on the line; runtime only)
	trainType: string?, alert: string?,
	broken: boolean?, -- a bus line with a leg no road connects: it does not run (alert says which)
	dayOnly: boolean?, -- runs 06:00-18:00 only; its buses rest in the depot at night
}

local _net: any
local _roadService: any
local _buildingService: any
local _economyService: any
local _folder: Folder
-- True once Start() has run (CitySlotService calls this only after a city has
-- actually loaded). Gates the PlayerAdded join-sync below so a player sitting in
-- the main menu (no city loaded yet) doesn't get a SyncTransit fire for nothing.
local _started = false

local _depots: { [number]: Depot } = {}
local _stops: { [number]: Stop } = {}
local _routes: { [number]: Route } = {}
local _depotId, _stopId, _routeId, _routeColorSeq = 0, 0, 0, 0
local _fareRevenue = 0

-- == Riders ======================================================================
-- Ridership is REAL. A citizen who chose transit stands at the board stop until a bus or
-- train of their line pulls in with a free seat, rides it, and gets off when it reaches
-- their stop; the fare is paid on boarding. A full vehicle leaves them waiting for the next
-- one, and a line with nothing running leaves them waiting until they give up and walk.
type Rider = {
	id: number, routeId: number, boardStopId: number, alightStopId: number,
	waited: number, patience: number,
	onBoard: (() -> ())?, onAlight: (Vector3) -> (), onGiveUp: () -> (),
	-- walk a waiting rider to the vehicle's door, then call the given function to step on
	onCall: ((Vector3, () -> ()) -> ())?,
	vehicle: any?,
}
-- Vehicles still taking people on or off: how many are yet to pass through the door.
local _boarding: { [any]: number } = {}
local _riders: { [number]: Rider } = {}
local _riderSeq = 0
local _epoch = 0 -- bumped by clear(): people still queued at a bus door belong to the old city
local RIDER_PATIENCE_MIN = 90   -- game-seconds a rider waits at minimum before walking instead
local RIDER_PATIENCE_HEADWAYS = 2.5 -- ...or this many expected headways, whichever is longer
local _lastCmdAt: { [Player]: number } = {}
local _lastPlaceAt: { [Player]: number } = {}
local _lastPreviewAt: { [Player]: number } = {}
local PREVIEW_COOLDOWN = 0.08 -- the route tool asks ~6x a second while the cursor moves
-- Bus and train lines take the SHORTEST way along the roads (user), not the fastest in the traffic
-- of the moment: a line is drawn once and kept, and its buses drive exactly its legs.
local LINE_PROFILE = DriverProfile.SHORTEST
local _dirty = false
local _routeRebuildQueued = false
local _routeRebuildVersion = 0
local _fleetClearer: (() -> ())? = nil -- BusDispatchService.clear, injected in Bootstrap
local _isDaylight: () -> boolean = function() return true end -- TimeService.isDaylight, injected in Bootstrap
local _monthTicks = 0 -- fare drains since the line stats last rolled over

-- == Helpers ===================================================================
local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function railNav(): any?
	return _roadService and _roadService.getRailGraph and _roadService.getRailGraph()
end

local function graphFor(mode: string?): any?
	return if mode == "train" then railNav() else nav()
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function flatDistSq(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return dx * dx + dz * dz
end

local function nearestPointOnEdge(edge: any, pos: Vector3): (number, Vector3, number)
	local points = edge and edge.points
	if typeof(points) ~= "table" or #points == 0 then
		return 1, pos, math.huge
	end
	local bestIndex = 1
	local bestPoint = points[1]
	local bestD = math.huge
	for i, p in points do
		local d = flatDistSq(p, pos)
		if d < bestD then
			bestD = d
			bestIndex = i
			bestPoint = p
		end
	end
	return bestIndex, bestPoint, bestD
end

local function nearestBoardingEdge(g: any, segmentId: number?, curbPos: Vector3, fallbackEdge: any?): (any?, number?, Vector3?)
	local bestEdge = nil
	local bestIndex = nil
	local bestPoint = nil
	local bestD = math.huge
	for _, edge in g:GetEdges() do
		if not segmentId or edge.segmentId == segmentId then
			local idx, point, d = nearestPointOnEdge(edge, curbPos)
			if d < bestD then
				bestD = d
				bestEdge = edge
				bestIndex = idx
				bestPoint = point
			end
		end
	end
	if bestEdge then
		return bestEdge, bestIndex, bestPoint
	end
	if fallbackEdge then
		local idx, point = nearestPointOnEdge(fallbackEdge, curbPos)
		return fallbackEdge, idx, point
	end
	return nil, nil, nil
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Transit")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Transit"; f.Parent = city
	end
	return f :: Folder
end

local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

-- == Model builders ============================================================
local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.CFrame = cf; p.Color = color
	p.Material = mat or Enum.Material.SmoothPlastic
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Bus buildings are the Blender kit (TransitKitModel, templates in ServerStorage.Templates.Transit);
-- the rail ones are still procedural placeholders (TrainBuildingModel).
local function buildDepotModel(spec: TransitTypes.DepotSpec, footprint: Vector3): Model
	if spec.key == "TrainYard" then return TrainBuildingModel.buildYard(spec, footprint) end
	return TrainBuildingModel.buildDepot(spec, footprint)
end

local function buildStopModel(spec: TransitTypes.StopSpec): Model
	if spec.mode == "train" then
		return TrainBuildingModel.buildStation(spec)
	end
	local m = TransitKitModel.spawn(spec.template or "", CFrame.identity, nil)
	assert(m, "[TransitService] no template ServerStorage.Templates.Transit." .. tostring(spec.template) .. " (run Authoring.TransitSetup)")
	return m
end

-- Development Tree gate (ProgressionService.isPlaceableAllowed), injected by Bootstrap.
-- The client hiding a locked card is presentation; THIS is the rule.
local _isPlaceableAllowed: ((string) -> boolean)? = nil

function TransitService.setUnlockCheck(fn: ((string) -> boolean)?)
	_isPlaceableAllowed = fn
end

local function isUnlocked(key: string): boolean
	local check = _isPlaceableAllowed
	return check == nil or check(key) == true
end

-- Territory gate (TerritoryService.isBoxAllowed), injected by Bootstrap. The unlock check
-- above answers "is this building available"; this answers "is this GROUND yours". Asked of
-- the whole FOOTPRINT, not the pivot: half a building over the border is not a building you
-- are allowed to put up. No check injected (tests, tooling) means nothing is gated.
local _territoryCheck: ((Vector3, number, number) -> boolean)? = nil

local function isOnOwnedLand(pos: Vector3, hx: number, hz: number): boolean
	local check = _territoryCheck
	return check == nil or check(pos, hx, hz) == true
end
function TransitService.setTerritoryCheck(fn: ((Vector3, number, number) -> boolean)?)
	_territoryCheck = fn
end

-- == Kit sites (depots, hub, station): seated like a zoned lot ===================
-- In front of a road a kit site stands on that road's footway plane (BuildingService.seatY: lane
-- points are the carriageway slab's middle); away from roads it keeps the ground it stands on. Its
-- terrain pad lies KIT_GROUND_SINK under the lot (the kit's own ground is on top, so grass never
-- pokes through) and levels the forecourt out to the road; LotDressingService paves a drive from
-- every gate to the road (tag PavedGates). A site never needs a road to be placed (user).
local KIT_GROUND_SINK = 0.35
local SEAT_REACH = 40 -- studs in front of the street edge a road still sets the site's height

local function seatOnRoad(pivot: CFrame, fp: Vector3): CFrame
	local g = nav()
	if not g then return pivot end
	local front = (pivot * CFrame.new(0, 0, fp.Z * 0.5 + TransitTypes.GATE_REACH)).Position
	local edge, _, lanePoint = nearestBoardingEdge(g, nil, front, nil)
	if not edge or not lanePoint or flatDist(lanePoint, front) > SEAT_REACH then return pivot end
	local net = _roadService.getNetwork and _roadService.getNetwork()
	local seg = net and net:getSegment(edge.segmentId)
	local road = if seg then RoadTypeCatalog.getOrDefault(seg.roadType) else nil
	local walk = not (road and (road.noSidewalk or road.sidewalkMode == "none"))
	local y = lanePoint.Y + RoadConstants.ROAD_THICKNESS * 0.5 + (if walk then RoadConstants.SIDEWALK_HEIGHT else 0)
	return pivot.Rotation + Vector3.new(pivot.Position.X, y, pivot.Position.Z)
end

-- Trees and planted props never block a kit site: it goes up on top of them and they are cleared
-- (Bootstrap injects NaturePlaceService.clearInRects -- the zoning clearance, no refund), the plot
-- plus the apron in front of its gates.
local _clearNature: ((rects: { { Vector3 } }) -> number)? = nil
function TransitService.setNatureClearance(fn: ((rects: { { Vector3 } }) -> number)?)
	_clearNature = fn
end

local function natureFolder(): Instance?
	local city = Workspace:FindFirstChild("_City")
	return city and city:FindFirstChild("Nature")
end

local function clearSite(pivot: CFrame, fp: Vector3)
	local clear = _clearNature
	if not clear then return end
	local hx, back, front = fp.X * 0.5, -fp.Z * 0.5, fp.Z * 0.5 + TransitTypes.GATE_REACH
	local rect = {
		(pivot * CFrame.new(-hx, 0, back)).Position, (pivot * CFrame.new(hx, 0, back)).Position,
		(pivot * CFrame.new(hx, 0, front)).Position, (pivot * CFrame.new(-hx, 0, front)).Position,
	}
	local ok, err = pcall(clear, { rect })
	if not ok then warn("[TransitService] nature clearance failed: " .. tostring(err)) end
end

-- TerrainPadService's frame faces the road with its LookVector; the kit's street side is +Z.
local function padKitSite(padId: string, pivot: CFrame, fp: Vector3)
	pcall(TerrainPadService.padFootprint, padId, pivot * CFrame.Angles(0, math.pi, 0), fp.X, fp.Z,
		pivot.Position.Y - KIT_GROUND_SINK)
end

-- Before the model enters the city: LotDressingService reads these when the tag arrives.
local function paveGates(model: Model, template: string, fp: Vector3)
	local spans = TransitKitModel.gateSpans(template)
	if not spans then return end
	model:SetAttribute("GateSpans", spans)
	model:SetAttribute("LotDepth", fp.Z)
	CollectionService:AddTag(model, "PavedGates")
end

-- == Depot placement (free placement; ServicePlacement.prepareFree) ============
local function spawnDepot(id: number, key: string, pivot: CFrame, entrance: Vector3, layout: number?): Depot?
	local spec = TransitTypes.getDepot(key)
	if not spec then return nil end
	local model: Model
	local bays: { TransitKitModel.Bay }? = nil
	if spec.template then
		-- The kit depot: buses enter at the IN gate (the drives all start on the road there).
		layout = math.clamp(layout or TransitKitModel.defaultLayout(spec.template), 1, math.max(1, TransitKitModel.layoutCount(spec.template)))
		local m = TransitKitModel.spawn(spec.template, pivot, layout)
		if not m then
			warn("[TransitService] no template ServerStorage.Templates.Transit." .. spec.template .. " (run Authoring.TransitSetup)")
			return nil
		end
		model = m
		bays = TransitKitModel.bays(spec.template, pivot, layout :: number)
		if bays and #bays > 0 then entrance = bays[1].pathIn[1] end
	else
		model = buildDepotModel(spec, TransitTypes.depotFootprintStuds(spec))
		model:PivotTo(pivot)
	end
	model:SetAttribute("DepotId", id)
	model:SetAttribute("TransitKind", "Depot")
	CollectionService:AddTag(model, if spec.mode == "train" then key else "BusDepot")
	local ground = TransitTypes.depotGroundFootprint(spec)
	if spec.template then paveGates(model, spec.template, ground) end
	model.Parent = _folder
	if spec.template then
		padKitSite("transit:" .. id, pivot, ground)
	else
		pcall(TerrainPadService.padFootprint, "transit:" .. id, pivot, ground.X, ground.Z, pivot.Position.Y)
	end
	local depot: Depot = { id = id, key = key, cf = pivot, entrance = entrance, model = model, layout = layout, bays = bays }
	_depots[id] = depot
	return depot
end

-- A rail building's point on the track beside it (where its trains leave and enter), or
-- nil when no track runs alongside.
local function trackPointBeside(pivot: CFrame, fp: Vector3): Vector3?
	local g = railNav()
	if not g then return nil end
	local ok, res = pcall(function() return g:NearestEdge(pivot.Position) end)
	if not ok or not res or not res.edge then return nil end
	local pts = res.edge.points
	local p = pts[math.clamp(res.index or 1, 1, #pts)]
	if flatDist(p, pivot.Position) > math.max(fp.X, fp.Z) * 0.5 + TRACK_REACH then return nil end
	return p
end

local placeInterchange: (string, CFrame, Player?) -> (boolean, string?)


-- `actor` only decides who gets the cost tag and the build sound back; the depot is city
-- state and replicates to everyone either way.
function TransitService.placeDepot(key: string, pivotIn: CFrame, actor: Player?): (boolean, string?)
	local spec = TransitTypes.getDepot(key)
	if not spec then
		-- the free-placement tool also places the interchanges (bus hub / station)
		local stopSpec = TransitTypes.getStop(key)
		if stopSpec and stopSpec.interchange then return placeInterchange(key, pivotIn, actor) end
		return false, "unknown depot"
	end
	if not isUnlocked(key) then return false, "that depot is not unlocked yet" end

	local fp = TransitTypes.depotGroundFootprint(spec)
	-- a kit site stands on trees (they are cleared below); a rail building does not
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn, if spec.template then natureFolder() :: any else nil)
	if not pivot then return false, reason end

	-- After prepareFree, so the land test sees where the depot actually lands. STOPS are
	-- deliberately not gated here: a stop must sit on a road, and a road can only have been
	-- built on land the city owns.
	if not isOnOwnedLand(pivot.Position, fp.X * 0.5, fp.Z * 0.5) then
		return false, "you do not own this land"
	end
	if spec.template then pivot = seatOnRoad(pivot, fp) end

	local railPoint: Vector3? = nil
	if spec.mode == "train" then
		railPoint = trackPointBeside(pivot, fp)
		if not railPoint then return false, "build it right beside a train track" end
		-- +Z is the track side of every rail building; turn it round when the track is behind.
		if pivot:PointToObjectSpace(railPoint :: Vector3).Z < 0 then pivot *= CFrame.Angles(0, math.pi, 0) end
	end

	if _economyService and _economyService.trySpend then
		if not _economyService.trySpend(spec.cost) then return false, "can't afford" end
	end

	local entrance = railPoint or (pivot * CFrame.new(0, 0, fp.Z * 0.5 + 4)).Position

	_depotId += 1
	if not spawnDepot(_depotId, key, pivot, entrance) then
		if _economyService and _economyService.credit then _economyService.credit(spec.cost) end
		return false, "build failed"
	end
	if spec.template then clearSite(pivot, fp) end
	if _net and _economyService and actor then _net.PlacementCharged:FireClient(actor, pivot.Position, spec.cost, "Building") end
	_dirty = true
	return true
end

local function releaseDepot(d: Depot)
	pcall(TerrainPadService.unpadFootprint, "transit:" .. d.id)
	if d.model and d.model.Parent then d.model:Destroy() end
end

-- The player picks another bay layout for a kit depot (more small buses <-> more long ones): the
-- depot is rebuilt in place in that layout; BusDispatchService re-parks its fleet into the new bays
-- and the bus allowance follows the new bay count.
function TransitService.setDepotLayout(id: number, layout: number): boolean
	local d = _depots[id]
	local spec = d and TransitTypes.getDepot(d.key)
	if not d or not spec or not spec.template then return false end
	if layout ~= layout or layout ~= math.floor(layout) or layout < 1 or layout > TransitKitModel.layoutCount(spec.template) then
		return false
	end
	if layout == d.layout then return false end
	releaseDepot(d)
	if not spawnDepot(id, d.key, d.cf, d.entrance, layout) then
		warn("[TransitService] setDepotLayout: depot " .. id .. " could not be rebuilt")
		_depots[id] = nil
	end
	TransitService._clampBusAssignments()
	_dirty = true
	return true
end

function TransitService.removeDepot(id: number)
	local d = _depots[id]
	if not d then return end
	releaseDepot(d)
	_depots[id] = nil
	-- Buses are allowed again only up to the remaining depot capacity; clamp route assignments.
	TransitService._clampBusAssignments()
	_dirty = true
end

local function addressIndex(): AddressBook.Index
	local net = _roadService and _roadService.getNetwork and _roadService.getNetwork()
	return AddressBook.buildIndex(if net then net:getSegments() else {})
end

-- Nearest civic building worth naming a stop after.
local function landmarkNear(pos: Vector3): string?
	local city = Workspace:FindFirstChild("_City")
	if not city then return nil end
	local best: string? = nil
	local bestD = LANDMARK_RADIUS
	for _, folderName in LANDMARK_FOLDERS do
		local folder = city:FindFirstChild(folderName)
		if not folder then continue end
		for _, model in folder:GetChildren() do
			local name = model:GetAttribute("ServiceName")
			if typeof(name) ~= "string" or not model:IsA("Model") then continue end
			local p = model:GetPivot().Position
			local dx, dz = p.X - pos.X, p.Z - pos.Z
			local d = math.sqrt(dx * dx + dz * dz)
			if d < bestD then
				best, bestD = name, d
			end
		end
	end
	return best
end

-- == Kerb bus bays ================================================================
-- On a street that parks, a kerb stop turns the parking lane beside it into its bus bay: the bus
-- leaves the lane behind the stop, boards in the bay (traffic passes) and pulls out ahead of it.
-- ParkingService keeps cars out (the stop model's BusBayLength attribute); the bay is painted.
local BAY_LEN = 36   -- studs: an articulated bus, whole
local BAY_PULL = 16  -- studs of lane after the bay the bus pulls out over
-- A street with no parking: the bay is cut this deep into the footway, and the stop stands back
-- by as much (RoadPieces draws the kerb stepping back round it from the BusBayDepth attribute).
local SIDEWALK_BAY_DEPTH = 3.5
local SHELTER_ROOM = 2.5 -- footway the shelter needs behind its pivot; no room, no footway bay
local BAY_YELLOW = Color3.fromRGB(226, 186, 60)
type KerbBay = { bays: { TransitKitModel.Bay }, roadPos: Vector3, exitPos: Vector3, width: number, depth: number }

-- `stopPivot`: the stop model's pivot (its +Z faces the road, curbOffset studs behind the kerb);
-- `lane`/`lanePos`: the kerb-side lane it boards from. nil when the street has no parking lane.
local function kerbBay(stopPivot: CFrame, seg: any, lane: any, lanePos: Vector3, curbOffset: number): KerbBay?
	if not seg or not lane or typeof(lane.points) ~= "table" or #lane.points < 2 then return nil end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	local depth = if spec.parkingLane then 0 else SIDEWALK_BAY_DEPTH
	if depth > 0 and (spec.noSidewalk or spec.pedestrian or spec.isHighway) then return nil end
	-- Only where the footway can give it up: on a narrow one the shelter would stand back in the
	-- lots behind it, so the bus stops in the lane as before.
	if depth > 0 and RoadTypeCatalog.footwayWidth(spec) < curbOffset + depth + SHELTER_ROOM then return nil end
	local pts = lane.points
	local best, bestD = 1, math.huge
	for i, p in pts do
		local d = flatDist(p, lanePos)
		if d < bestD then best, bestD = i, d end
	end
	local t = pts[math.min(best + 1, #pts)] - pts[math.max(best - 1, 1)]
	t = Vector3.new(t.X, 0, t.Z)
	if t.Magnitude < 1e-3 then return nil end
	t = t.Unit
	local z = stopPivot.ZVector
	local toRoad = Vector3.new(z.X, 0, z.Z).Unit
	local width = if depth > 0 then depth else spec.parkingLaneWidth or 5
	local surfaceY = lanePos.Y + RoadConstants.ROAD_THICKNESS * 0.5
	-- the parking lane out from the kerb, or the bay cut in behind it
	local c = stopPivot.Position + toRoad * (if depth > 0 then curbOffset - width * 0.5 else curbOffset + width * 0.5)
	c = Vector3.new(c.X, surfaceY, c.Z)
	local onLane = Vector3.new(lanePos.X, surfaceY, lanePos.Z)
	local half = BAY_LEN * 0.5
	local roadPos = lanePos - t * (half + 4)
	-- front-axle paths (TransitKitModel.yardPose): swing in behind the stop, stand beside it, pull out
	local bay: TransitKitModel.Bay = {
		id = 1, kind = "artic", stop = nil, cf = CFrame.lookAt(c, c + t),
		pathIn = { Vector3.new(roadPos.X, surfaceY, roadPos.Z), c - t * (half - 10), c + t * (half - 4) },
		pathOut = { c + t * (half - 4), onLane + t * (half + BAY_PULL) },
	}
	return { bays = { bay }, roadPos = roadPos, exitPos = lanePos + t * (half + BAY_PULL), width = width, depth = depth }
end

-- The bay's paint, carried by the stop model: BUS on the parking lane.
local function paintBay(model: Model, kb: KerbBay)
	local folder = Instance.new("Folder")
	folder.Name = "BusBay"
	folder.Parent = model
	local cf = kb.bays[1].cf * CFrame.new(0, 0.04, 0) -- -Z = the way traffic runs
	local w, l = kb.width - 0.6, BAY_LEN
	local function line(size: Vector3, at: CFrame)
		local p = Instance.new("Part")
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = BAY_YELLOW
		p.Size = size
		p.CFrame = at
		p.Parent = folder
		return p
	end
	-- just the word on the parking lane (user: no box)
	local plate = line(Vector3.new(w * 0.8, 0.05, math.min(9, l)), cf)
	plate.Transparency = 1
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 24
	sg.LightInfluence = 1
	sg.MaxDistance = 600
	sg.Parent = plate
	local txt = Instance.new("TextLabel")
	txt.BackgroundTransparency = 1
	txt.Size = UDim2.fromScale(1, 1)
	txt.Text = "BUS"
	txt.TextColor3 = BAY_YELLOW
	txt.TextScaled = true
	txt.Font = Enum.Font.GothamBold
	txt.Parent = sg
end

-- == Stop placement (curbside, faces the road) =================================
-- `guess` is the client's cursor hit near a road. The server snaps to the nearest lane,
-- rejects if there is no road close by, and offsets the shelter out to the kerb on the
-- side the cursor is on so it faces the carriageway.
-- `info` is either a bare cursor Vector3 (legacy) or { pos = cursor, road = centreline,
-- seg = segmentId } sent by the client. The bus BOARDS at the nearest lane point; the
-- shelter sits just outside the carriageway on the side the cursor is on (the sidewalk),
-- facing the road.
-- `actor` as in placeDepot: the cost tag and build sound are theirs alone.
function TransitService.placeStop(key: string, info: any, actor: Player?): (boolean, any)
	local spec = TransitTypes.getStop(key)
	if not spec then return false, "unknown stop" end
	if not isUnlocked(key) then return false, "that stop is not unlocked yet" end
	local mode = spec.mode or "bus"
	local g = graphFor(mode)
	local nearMsg = if mode == "train" then "not near a track" else "not near a road"
	if not g then return false, if mode == "train" then "no track" else "no roads" end

	local cursor: Vector3, center: Vector3?, segId: number?
	if typeof(info) == "Vector3" then
		cursor = info
	elseif typeof(info) == "table" then
		cursor = info.pos
		center = if typeof(info.road) == "Vector3" then info.road else nil
		segId = if typeof(info.seg) == "number" then info.seg else nil
	end
	if typeof(cursor) ~= "Vector3" or cursor ~= cursor then return false, "bad position" end

	local ref = center or cursor
	local ok, res = pcall(function() return g:NearestEdge(ref) end)
	if not ok or not res or not res.edge then return false, nearMsg end
	local pts = res.edge.points
	local idx = math.clamp(res.index or 1, 1, #pts)
	local nearestLanePoint = pts[idx]
	if flatDist(nearestLanePoint, cursor) > STOP_MAX_ROAD_DIST then return false, nearMsg end

	local net = _roadService.getNetwork and _roadService.getNetwork()
	local seg = net and ((segId and net:getSegment(segId)) or net:getSegment(res.edge.segmentId))
	local segmentId = (seg and seg.id) or res.edge.segmentId
	local halfW = 8
	if seg then halfW = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.5 end

	local cp = center or nearestLanePoint
	local outward = Vector3.new(cursor.X - cp.X, 0, cursor.Z - cp.Z)
	if outward.Magnitude < 0.5 then
		local nextP = pts[math.min(idx + 1, #pts)]
		local prevP = pts[math.max(idx - 1, 1)]
		local tangent = Vector3.new(nextP.X - prevP.X, 0, nextP.Z - prevP.Z)
		if tangent.Magnitude < 1e-3 then tangent = Vector3.xAxis end
		tangent = tangent.Unit
		outward = Vector3.new(-tangent.Z, 0, tangent.X)
	end

	local curbGuess = cp + outward.Unit * (halfW + spec.curbOffset * RoadConstants.WORLD_SCALE)
	local boardEdge, _, boardPos = nearestBoardingEdge(g, segmentId, curbGuess, res.edge)
	if not boardEdge or not boardPos then return false, nearMsg end
	if flatDist(boardPos, cursor) > STOP_MAX_ROAD_DIST then return false, nearMsg end

	-- Spacing only applies to stops on the same side of the same road segment, so a
	-- stop can be placed directly opposite another one across the carriageway --
	-- that's the normal one-stop-per-direction pattern, not crowding.
	for _, s in _stops do
		if s.mode == mode and s.segmentId == segmentId then
			local sOutward = Vector3.new(s.pos.X - s.roadPos.X, 0, s.pos.Z - s.roadPos.Z)
			local sameSide = sOutward:Dot(outward) > 0
			-- a bus bay needs its own stretch of kerb, and the one before and after it
			local spacing = if mode == "bus" and s.kerbBay then math.max(TransitTypes.STOP_MIN_SPACING, BAY_LEN + BAY_PULL)
				else TransitTypes.STOP_MIN_SPACING
			if mode == "train" then
				-- Platforms may not overlap: half of each one's length apart.
				local other = TransitTypes.getStop(s.key)
				spacing = (spec.shelterSize.X + (if other then other.shelterSize.X else 0)) * 0.5 * RoadConstants.WORLD_SCALE
			end
			if sameSide and flatDist(s.roadPos, boardPos) < spacing then
				return false, "too close to another stop"
			end
		end
	end

	local y = boardPos.Y
	if spec.template then
		-- lane points are the slab's middle: a kit stop stands on the road surface, up on the sidewalk
		local segSpec = if seg then RoadTypeCatalog.getOrDefault(seg.roadType) else nil
		local walk = segSpec and not segSpec.noSidewalk and segSpec.sidewalkMode ~= "none"
		y += RoadConstants.ROAD_THICKNESS * 0.5 + (if walk then RoadConstants.SIDEWALK_HEIGHT else 0)
	end
	local curbPos = Vector3.new(curbGuess.X, y, curbGuess.Z)
	-- The Pole (PrimaryPart) is poleHeight studs tall; PivotTo places its centre.
	-- Lift the pivot by half the pole height so the base sits on the ground.
	local poleHalfH = if spec.template then 0 else spec.poleHeight * 0.5 * RoadConstants.WORLD_SCALE -- kit stops pivot on the ground
	local pivotPos = Vector3.new(curbPos.X, y + poleHalfH, curbPos.Z)
	-- The shelter open/sign side must face the road; the template's sign is on +Z,
	-- BackGlass on -Z. CFrame.lookAt makes +Z point at the road centre, so we
	-- rotate 180 degrees around Y to flip the shelter so its open side faces the road.
	-- curbOffset keeps the pad on the sidewalk, just outside the carriageway edge.
	local baseCF = CFrame.lookAt(pivotPos, Vector3.new(cp.X, pivotPos.Y, cp.Z))
	local facing = baseCF * CFrame.Angles(0, math.pi, 0)

	if _economyService and _economyService.trySpend then
		if not _economyService.trySpend(spec.cost) then return false, "can't afford" end
	end

	local kb = if mode == "bus" then kerbBay(facing, seg, boardEdge, boardPos, spec.curbOffset * RoadConstants.WORLD_SCALE) else nil

	_stopId += 1
	local model = buildStopModel(spec)
	-- a footway bay: the shelter stands back behind it (`facing` stays the kerb's, for the save)
	model:PivotTo(if kb and kb.depth > 0 then facing * CFrame.new(0, 0, -kb.depth) else facing)
	if kb then
		model:SetAttribute("BusBayLength", BAY_LEN) -- before it enters the city: ParkingService reads it then
		if kb.depth > 0 then model:SetAttribute("BusBayDepth", kb.depth) end
		paintBay(model, kb)
	end
	model:SetAttribute("StopId", _stopId)
	model:SetAttribute("RoadSegmentId", segmentId)
	model:SetAttribute("TransitKind", "Stop")
	CollectionService:AddTag(model, if mode == "train" then "TrainStation" else "BusStop")
	model.Parent = _folder

	local index = addressIndex()
	local street = AddressBook.nameOf(index, segmentId)
	local landmark = landmarkNear(curbPos)
	local name: string
	if mode == "train" then
		-- Stations take a single word: "Riverside Station", not "14 Riverside Road Station".
		name = (landmark or (street and string.match(street, "^%S+")) or "Central") .. " Station"
	elseif landmark then
		name = landmark .. " Stop"
	elseif street then
		name = tostring(AddressBook.numberAt(index, segmentId, curbPos)) .. " " .. street
	else
		name = "Bus Stop " .. tostring(_stopId)
	end
	model:SetAttribute("StopName", name)
	local stop: Stop = {
		id = _stopId, key = key, pos = curbPos, roadPos = if kb then kb.roadPos else boardPos, facing = facing,
		segmentId = segmentId, edgeId = boardEdge.id, name = name, model = model, mode = mode,
		boardings = 0, displayBoardings = 0,
		bays = if kb then kb.bays else nil, exitPos = if kb then kb.exitPos else nil, kerbBay = if kb then true else nil,
	}
	_stops[_stopId] = stop
	if _net and _economyService and actor then _net.PlacementCharged:FireClient(actor, curbPos, spec.cost, "Building") end
	_dirty = true
	return true, _stopId
end

-- == Interchanges (bus hub / station) ============================================
-- Placed like a depot, boarded like a stop: a bus's leg ends on the lane at the IN gate, it drives a
-- platform's baked path in, dwells there, and leaves by the OUT gate, where its next leg starts
-- (exitPos). Both gates must be on a road.
local function spawnInterchange(id: number, key: string, pivot: CFrame, name: string?): (Stop?, string?)
	local spec = TransitTypes.getStop(key)
	if not (spec and spec.template and spec.footprint) then return nil, "build failed" end
	local bays = TransitKitModel.bays(spec.template, pivot, 1)
	if #bays == 0 then return nil, "build failed" end
	-- Its buses join the nearest lane at each gate; a site away from roads still stands (a line to
	-- it shows "No road ..." until a road reaches it).
	local g = nav()
	local gateIn, gateOut = bays[1].pathIn[1], bays[1].pathOut[#bays[1].pathOut]
	local inEdge, inPos, outPos = nil, nil, nil
	if g then
		local e, _, p = nearestBoardingEdge(g, nil, gateIn, nil)
		inEdge, inPos = e, p
		local _, _, q = nearestBoardingEdge(g, nil, gateOut, nil)
		outPos = q
	end
	local segmentId = if inEdge then inEdge.segmentId else 0
	local model = TransitKitModel.spawn(spec.template, pivot, 1)
	if not model then return nil, "build failed" end
	if not name or name == "" then
		local street = if inEdge then AddressBook.nameOf(addressIndex(), segmentId) else nil
		name = (landmarkNear(pivot.Position) or (street and string.match(street, "^%S+")) or "Central") .. " " .. spec.name
	end
	model:SetAttribute("StopId", id)
	model:SetAttribute("RoadSegmentId", segmentId)
	model:SetAttribute("TransitKind", "Stop")
	model:SetAttribute("StopName", name)
	CollectionService:AddTag(model, "BusStop")
	local fp = spec.footprint :: Vector3
	paveGates(model, spec.template, fp)
	model.Parent = _folder
	padKitSite("transit:stop:" .. id, pivot, fp)
	local stop: Stop = {
		id = id, key = key, pos = pivot.Position, roadPos = inPos or gateIn, facing = pivot,
		segmentId = segmentId, edgeId = if inEdge then inEdge.id else nil, name = name :: string, model = model, mode = "bus",
		boardings = 0, displayBoardings = 0, exitPos = outPos or gateOut, bays = bays,
	}
	_stops[id] = stop
	return stop
end

placeInterchange = function(key: string, pivotIn: CFrame, actor: Player?): (boolean, string?)
	local spec = TransitTypes.getStop(key) :: TransitTypes.StopSpec
	if not isUnlocked(key) then return false, "that is not unlocked yet" end
	local fp = spec.footprint :: Vector3
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn, natureFolder() :: any)
	if not pivot then return false, reason end
	if not isOnOwnedLand(pivot.Position, fp.X * 0.5, fp.Z * 0.5) then return false, "you do not own this land" end
	pivot = seatOnRoad(pivot, fp)
	if _economyService and _economyService.trySpend and not _economyService.trySpend(spec.cost) then
		return false, "can't afford"
	end
	local stop, why = spawnInterchange(_stopId + 1, key, pivot, nil)
	if not stop then
		if _economyService and _economyService.credit then _economyService.credit(spec.cost) end
		return false, why
	end
	_stopId += 1
	clearSite(pivot, fp)
	if _net and _economyService and actor then _net.PlacementCharged:FireClient(actor, pivot.Position, spec.cost, "Building") end
	_dirty = true
	return true
end

-- Removing the stop at `index` merges legs index-1 and index into one; their shaping
-- waypoints no longer apply, and every later leg's waypoints shift down one slot.
-- Without this, waypoints stay keyed to the OLD leg indices and attach to the wrong
-- legs after any mid-route stop removal. `oldCount` is the stop count before removal
-- (the closing leg, index oldCount, touches stop 1).
local function shiftWaypointsForRemoval(route: Route, index: number, oldCount: number)
	local out: { [number]: { Vector3 } } = {}
	for leg, list in route.waypoints do
		local touches = leg == index or leg == index - 1 or (index == 1 and leg == oldCount)
		if not touches then
			out[if leg > index then leg - 1 else leg] = list
		end
	end
	route.waypoints = out
end

local function detachStopFromRoutes(stopId: number)
	for _, route in _routes do
		local changed = false
		for i = #route.stops, 1, -1 do
			if route.stops[i] == stopId then
				local oldCount = #route.stops
				table.remove(route.stops, i)
				shiftWaypointsForRemoval(route, i, oldCount)
				changed = true
			end
		end
		if changed then
			if #route.stops < 2 then route.closed = false end
			TransitService._recomputeRoute(route)
		end
	end
end

function TransitService.removeStop(id: number)
	local s = _stops[id]
	if not s then return end
	if s.model and s.model.Parent then s.model:Destroy() end
	if s.bays and not s.kerbBay then pcall(TerrainPadService.unpadFootprint, "transit:stop:" .. id) end
	_stops[id] = nil
	detachStopFromRoutes(id)
	_dirty = true
end

function TransitService.removeStopsForSegment(segmentId: number)
	local segment = nil
	if _roadService and _roadService.getNetwork then
		local network = _roadService.getNetwork()
		segment = network and network:getSegment(segmentId) or nil
	end

	local ids: { number } = {}
	for id, stop in _stops do
		if stop.bays and not stop.kerbBay then continue end -- an interchange is a building: it stays, its gates re-snap on reload
		local attached = stop.segmentId == segmentId
		if not attached and segment then
			-- A crossing split or road re-form can replace segment ids after the stop was
			-- placed. Its boarding point remains on the owning curve, so use that as a
			-- robust fallback while the segment still exists (the callback runs pre-remove).
			local t = BezierUtil.closestParam(segment.p0, segment.p1, segment.p2, segment.p3, stop.roadPos, 16)
			local point = BezierUtil.point(segment.p0, segment.p1, segment.p2, segment.p3, t)
			attached = flatDist(point, stop.roadPos) <= STOP_SEGMENT_LINK_TOLERANCE
		end
		if attached then table.insert(ids, id) end
	end
	for _, id in ids do
		TransitService.removeStop(id)
	end
end

-- == Routes ====================================================================
-- Re-path route legs along the road network. While the player is still building,
-- only draw stop1->stop2->...->lastStop. Once closed, add lastStop->stop1 so buses loop.
-- A line's path through `pts` along the lanes, each piece going on from the lane the one before
-- ended on, so a line never jumps across the road at a road point. The first point and (when
-- `lastIsStop`) the last are stops: left and reached on their own kerb lane. The road points in
-- between were clicked on the centreline, so they are passed in whichever direction is shorter.
-- Trains keep their rule (a station boards from either track). Returns the path, its lane ids,
-- and whether every piece found a road.
local function busAllows(edge: any): boolean
	local set = edge.allowedVehicles
	return set == nil or set[VehicleTypes.Bus] == true
end

local function distAlong(edge: any, pos: Vector3): number
	local pts = edge.points
	local best, bestD = 1, math.huge
	for i, p in pts do
		local d = flatDistSq(p, pos)
		if d < bestD then best, bestD = i, d end
	end
	local s = 0
	for i = 2, best do s += (pts[i] - pts[i - 1]).Magnitude end
	return s
end

local function lineThrough(g: any, pts: { Vector3 }, isTrain: boolean, lastIsStop: boolean): ({ Vector3 }, { string }, boolean)
	local class = if isTrain then VehicleTypes.Train else VehicleTypes.Bus
	local path: { Vector3 } = {}
	local ids: { string } = {}
	local whole = true
	local pin: any = nil
	if not isTrain then
		local ok, res = pcall(function() return g:NearestEdge(pts[1], busAllows) end)
		if ok and res and res.edge then pin = { edgeId = res.edge.id, dist = distAlong(res.edge, pts[1]) } end
	end
	for k = 1, #pts - 1 do
		local toRoadPoint = not (lastIsStop and k + 1 == #pts)
		local ok, poly, legIds = pcall(function()
			return g:FindPath(pts[k], pts[k + 1], isTrain or toRoadPoint, class, LINE_PROFILE, pin)
		end)
		if ok and typeof(poly) == "table" and #poly > 0 and typeof(legIds) == "table" and #legIds > 0 then
			for i, p in poly do
				if not (i == 1 and #path > 0) then table.insert(path, p) end
			end
			for i, id in legIds do
				if not (i == 1 and ids[#ids] == id) then table.insert(ids, id) end
			end
			local lastEdge = if isTrain then nil else g:GetEdge(legIds[#legIds])
			pin = if lastEdge then { edgeId = lastEdge.id, dist = distAlong(lastEdge, poly[#poly]) } else nil
		else
			whole = false
			if #path == 0 then table.insert(path, pts[k]) end
			table.insert(path, pts[k + 1])
			pin = nil
		end
	end
	return path, ids, whole
end

-- A line being drawn shows where it goes: last stop -> each road point clicked since, on the roads.
function TransitService._recomputeTail(route: Route, g: any)
	route.tailPath = nil
	local last = _stops[route.stops[#route.stops]]
	if route.closed or #route.pending == 0 or not last then return end
	local pts: { Vector3 } = { last.exitPos or last.roadPos }
	for _, w in route.pending do table.insert(pts, w) end
	local tail = lineThrough(g, pts, route.mode == "train", false)
	route.tailPath = tail
end

function TransitService._recomputeRoute(route: Route)
	_rideDistanceCache[route] = nil
	route.path = {}
	route.legEdges = {}
	route.legPaths = {}
	route.lengthStuds = 0
	if route.mode ~= "train" then route.broken = nil; route.alert = nil end
	local g = graphFor(route.mode)
	if not g then return end
	TransitService._recomputeTail(route, g)
	local n = #route.stops
	if n < 2 then return end
	local legCount = if route.closed then n else n - 1
	local brokenMsg: string? = nil
	for i = 1, legCount do
		local a = _stops[route.stops[i]]
		local nextIndex = if i == n then 1 else i + 1
		local b = _stops[route.stops[nextIndex]]
		if not a or not b then continue end
		local pts: { Vector3 } = { a.exitPos or a.roadPos } -- an interchange's buses leave by its OUT gate
		local wps = route.waypoints[i]
		if wps then for _, w in wps do table.insert(pts, w) end end
		table.insert(pts, b.roadPos)
		-- One continuous path on the lanes, stop to stop through the leg's road points. A piece no
		-- road connects is drawn straight so the loop still closes, and the line says so (alert).
		local legPath, legEdgeIds, whole = lineThrough(g, pts, route.mode == "train", true)
		if not whole then brokenMsg = brokenMsg or ("No road from " .. a.name .. " to " .. b.name) end
		for pi, p in legPath do
			if not (pi == 1 and #route.path > 0) then table.insert(route.path, p) end
		end
		route.legEdges[i] = legEdgeIds
		route.legPaths[i] = legPath
	end
	for i = 2, #route.path do
		route.lengthStuds += (route.path[i] - route.path[i - 1]).Magnitude
	end
	-- Train lines' alerts belong to TrainDispatchService; a bus line's is this: a leg no road
	-- connects. Its buses stay in the depot until it is fixed, never jump the gap.
	if route.mode ~= "train" then
		route.broken = brokenMsg ~= nil
		route.alert = brokenMsg
	end
end

function TransitService.getBusAllowance(): number
	local total = 0
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		total += if d.bays then #d.bays elseif spec then spec.busCapacity else 0
	end
	return total
end

function TransitService.getBusesAssigned(): number
	local n = 0
	for _, r in _routes do
		if r.closed and r.mode ~= "train" then n += r.busCount end
	end
	return n
end

function TransitService.getTrainsAssigned(): number
	local n = 0
	for _, r in _routes do
		if r.closed and r.mode == "train" then n += r.busCount end
	end
	return n
end

-- Trains actually out on the track (TrainDispatchService reports them per line).
function TransitService.getTrainsRunning(): number
	local n = 0
	for _, r in _routes do
		if r.mode == "train" then n += r.activeBuses end
	end
	return n
end

-- Trains the city's Train Depots can run between them.
function TransitService.getTrainAllowance(): number
	local total = 0
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		total += if spec and spec.trainCapacity then spec.trainCapacity else 0
	end
	return total
end

-- Trim route bus counts so the total never exceeds the depot allowance (after a depot
-- is removed). Trims in descending route-id order so the newest routes give up buses first.
function TransitService._clampBusAssignments()
	local allowance = TransitService.getBusAllowance()
	local ids: { number } = {}
	for id in _routes do table.insert(ids, id) end
	table.sort(ids)
	local running = 0
	for _, id in ids do
		local r = _routes[id]
		if not r.closed or r.mode == "train" then continue end -- trains need no depot allowance
		local allowed = math.max(0, allowance - running)
		if r.busCount > allowed then r.busCount = allowed end
		running += r.busCount
	end
end

function TransitService.createRoute(firstStopId: number): number?
	local first = _stops[firstStopId]
	if not first then return nil end
	local mode = first.mode
	_routeId += 1
	_routeColorSeq += 1
	-- Trains need no depot: a line gets its default trains outright. Buses draw on the depot allowance.
	local count: number
	if mode == "train" then
		count = TransitTypes.DEFAULT_TRAINS_PER_ROUTE
	else
		local allowance = TransitService.getBusAllowance()
		count = math.min(TransitTypes.DEFAULT_BUSES_PER_ROUTE, math.max(0, allowance - TransitService.getBusesAssigned()))
	end
	local route: Route = {
		id = _routeId, name = (if mode == "train" then "Train Line " else "Bus Line ") .. _routeId, mode = mode,
		color = TransitTypes.routeColor(_routeColorSeq), colorIndex = _routeColorSeq,
		enabled = true, fare = TransitTypes.DEFAULT_FARE,
		busCount = count, closed = false,
		stops = { firstStopId }, waypoints = {}, pending = {},
		path = {}, legEdges = {}, legPaths = {}, lengthStuds = 0,
		activeBuses = 0, passengers = 0, displayPassengers = 0, usage = 0,
		revenue = 0, displayRevenue = 0,
	}
	_routes[_routeId] = route
	_dirty = true
	return _routeId
end

function TransitService.addStop(routeId: number, stopId: number): boolean
	local route = _routes[routeId]
	local stop = _stops[stopId]
	if not route or not stop then return false end
	if stop.mode ~= route.mode then return false end -- bus stops on bus lines, stations on train lines
	-- Click the first stop again (>=2 stops, open route) closes the loop.
	if not route.closed and #route.stops >= 2 and stopId == route.stops[1] then
		local legIndex = #route.stops -- close the loop from current last stop back to the first
		if #route.pending > 0 then
			route.waypoints[legIndex] = route.pending
			route.pending = {}
		end
		route.closed = true
		TransitService._clampBusAssignments()
		TransitService._recomputeRoute(route)
		_dirty = true
		return true
	end
	-- Adding a stop to a closed line reopens it so the new stop joins the loop; the
	-- player clicks the first stop again to re-close it.
	if route.closed then route.closed = false end
	if #route.stops >= TransitTypes.MAX_STOPS_PER_ROUTE then return false end
	if route.stops[#route.stops] == stopId then return false end -- no immediate repeat
	table.insert(route.stops, stopId)
	local legIndex = #route.stops - 1
	if #route.pending > 0 then
		route.waypoints[legIndex] = route.pending
		route.pending = {}
	end
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

-- Remove ONE stop from a line (Overview stop-chip click). Dropping below 2 stops reopens it.
function TransitService.removeRouteStop(routeId: number, stopId: number)
	local route = _routes[routeId]
	if not route then return end
	local removed = false
	for i = #route.stops, 1, -1 do
		if route.stops[i] == stopId then
			local oldCount = #route.stops
			table.remove(route.stops, i)
			shiftWaypointsForRemoval(route, i, oldCount)
			removed = true
			break
		end
	end
	if not removed then return end
	if #route.stops < 2 then route.closed = false end
	TransitService._clampBusAssignments()
	TransitService._recomputeRoute(route)
	_dirty = true
end

-- == Shaping a line by hand ====================================================
-- Road points the player clicks or drags a line onto. Legs are numbered from 1 (stop i -> stop i+1;
-- a closed line's last leg runs back to stop 1); leg 0 is the tail of a line still being drawn
-- (route.pending). Every point must be on a road the line's vehicles use.
local function onRoute(route: Route, pos: any): boolean
	if typeof(pos) ~= "Vector3" or pos ~= pos or pos.Magnitude > 1e6 then return false end
	local g = graphFor(route.mode)
	local ok, res = pcall(function() return g and g:NearestEdge(pos) end)
	if not ok or not res or not res.edge then return false end
	local _, lanePoint = nearestPointOnEdge(res.edge, pos)
	return flatDist(lanePoint, pos) <= STOP_MAX_ROAD_DIST
end

-- The legs a line has, and a leg's two ends (where its buses start and stop).
local function legInfo(route: Route, leg: number): (Vector3?, Vector3?)
	local n = #route.stops
	local count = if route.closed then n else n - 1
	if leg ~= leg or leg < 1 or leg > count or leg ~= math.floor(leg) then return nil, nil end
	local a = _stops[route.stops[leg]]
	local b = _stops[route.stops[if leg == n then 1 else leg + 1]]
	if not a or not b then return nil, nil end
	return a.exitPos or a.roadPos, b.roadPos
end

-- Where `pos` goes in a leg's ordered points (between a and b): the slot adding the least detour.
local function detourSlot(a: Vector3, list: { Vector3 }, b: Vector3, pos: Vector3): number
	local best, bestCost = 1, math.huge
	for j = 1, #list + 1 do
		local p = if j == 1 then a else list[j - 1]
		local q = if j == #list + 1 then b else list[j]
		local cost = flatDist(p, pos) + flatDist(pos, q) - flatDist(p, q)
		if cost < bestCost then best, bestCost = j, cost end
	end
	return best
end

function TransitService.addWaypoint(routeId: number, pos: Vector3): boolean
	local route = _routes[routeId]
	if not route or route.closed or not onRoute(route, pos) then return false end
	if #route.pending >= TransitTypes.MAX_WAYPOINTS_PER_LEG then return false end
	table.insert(route.pending, pos)
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

-- A line dragged onto a stop: that stop joins the line between the leg's two stops; the leg's own
-- road points stay on whichever half they were on.
function TransitService.insertStop(routeId: number, leg: number, stopId: number): boolean
	local route = _routes[routeId]
	local stop = _stops[stopId]
	if not route or not stop or stop.mode ~= route.mode then return false end
	if #route.stops >= TransitTypes.MAX_STOPS_PER_ROUTE then return false end
	local a, b = legInfo(route, leg)
	if not a or not b then return false end
	local n = #route.stops
	if route.stops[leg] == stopId or route.stops[if leg == n then 1 else leg + 1] == stopId then return false end
	local list = route.waypoints[leg] or {}
	local slot = detourSlot(a, list, b, stop.roadPos)
	local shifted: { [number]: { Vector3 } } = {}
	for l, pts in route.waypoints do
		if l < leg then shifted[l] = pts elseif l > leg then shifted[l + 1] = pts end
	end
	local before, after = {}, {}
	for j, w in list do table.insert(if j < slot then before else after, w) end
	if #before > 0 then shifted[leg] = before end
	if #after > 0 then shifted[leg + 1] = after end
	route.waypoints = shifted
	table.insert(route.stops, leg + 1, stopId)
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

-- A line dragged onto a road: a new point on that leg, so the buses go that way.
function TransitService.addLegPoint(routeId: number, leg: number, pos: Vector3): boolean
	local route = _routes[routeId]
	if not route then return false end
	if leg == 0 then return TransitService.addWaypoint(routeId, pos) end
	local a, b = legInfo(route, leg)
	if not a or not b or not onRoute(route, pos) then return false end
	local list = route.waypoints[leg] or {}
	if #list >= TransitTypes.MAX_WAYPOINTS_PER_LEG then return false end
	table.insert(list, detourSlot(a, list, b, pos), pos)
	route.waypoints[leg] = list
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

local function pointList(route: Route, leg: number): { Vector3 }?
	if leg == 0 then return route.pending end
	local a = legInfo(route, leg)
	return if a then route.waypoints[leg] else nil
end

-- A road point dragged somewhere else.
function TransitService.moveWaypoint(routeId: number, leg: number, index: number, pos: Vector3): boolean
	local route = _routes[routeId]
	local list = route and pointList(route, leg)
	if not route or not list or not list[index] or not onRoute(route, pos) then return false end
	list[index] = pos
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

-- The route tool's live preview, along the roads (changes nothing): the tail of a line being drawn
-- from its last stop through the points clicked since out to `target` (leg nil); a leg reshaped
-- through `target` where a drag would put it (leg, no point); or with road point `point` of `leg`
-- moved to `target` (leg 0 = the tail's points).
local PREVIEW_MAX_POINTS = 240
function TransitService.previewPath(routeId: number, target: Vector3, leg: number?, point: number?): { Vector3 }?
	local route = _routes[routeId]
	local g = route and graphFor(route.mode)
	if not route or not g then return nil end
	local chain: { Vector3 } = {}
	if leg == nil or leg == 0 then
		local last = _stops[route.stops[#route.stops]]
		if not last then return nil end
		chain[1] = last.exitPos or last.roadPos
		for _, w in route.pending do table.insert(chain, w) end
		if leg == 0 and point and chain[point + 1] then chain[point + 1] = target else table.insert(chain, target) end
	else
		local a, b = legInfo(route, leg)
		if not a or not b then return nil end
		local list = table.clone(route.waypoints[leg] or {})
		if point and list[point] then list[point] = target else table.insert(list, detourSlot(a, list, b, target), target) end
		chain[1] = a
		for _, w in list do table.insert(chain, w) end
		table.insert(chain, b)
	end
	-- a reshaped leg ends at its stop; the line being drawn ends at the cursor
	local path = lineThrough(g, chain, route.mode == "train", leg ~= nil and leg ~= 0)
	if #path <= PREVIEW_MAX_POINTS then return path end
	local out, step = {}, math.ceil(#path / PREVIEW_MAX_POINTS)
	for i = 1, #path, step do table.insert(out, path[i]) end
	if out[#out] ~= path[#path] then table.insert(out, path[#path]) end
	return out
end

function TransitService.removeWaypoint(routeId: number, leg: number, index: number): boolean
	local route = _routes[routeId]
	local list = route and pointList(route, leg)
	if not route or not list or not list[index] then return false end
	table.remove(list, index)
	if leg ~= 0 and #list == 0 then route.waypoints[leg] = nil end
	TransitService._recomputeRoute(route)
	_dirty = true
	return true
end

function TransitService.undoRoute(routeId: number)
	local route = _routes[routeId]
	if not route then return end
	if route.closed then
		route.closed = false
		route.waypoints[#route.stops] = nil
		TransitService._recomputeRoute(route)
		_dirty = true
		return
	end
	if #route.pending > 0 then
		table.remove(route.pending)
		TransitService._recomputeRoute(route)
	elseif #route.stops > 0 then
		local legIndex = #route.stops - 1
		route.waypoints[legIndex] = nil
		table.remove(route.stops)
		if #route.stops == 0 then
			_routes[routeId] = nil
		else
			TransitService._recomputeRoute(route)
		end
	end
	_dirty = true
end

function TransitService.deleteRoute(routeId: number)
	if _routes[routeId] then _routes[routeId] = nil; _dirty = true end
end

function TransitService.setRouteBuses(routeId: number, n: number)
	local route = _routes[routeId]
	if not route or typeof(n) ~= "number" or n ~= n then return end
	if route.mode == "train" then
		route.busCount = math.clamp(math.floor(n), 0, TransitTypes.MAX_TRAINS_PER_ROUTE)
	else
		local allowance = TransitService.getBusAllowance()
		local others = TransitService.getBusesAssigned() - route.busCount
		local maxForRoute = math.min(math.max(0, allowance - others),
			TransitTypes.maxBusesFor(route.lengthStuds, #route.stops))
		route.busCount = math.clamp(math.floor(n), 0, maxForRoute)
	end
	_dirty = true
end

function TransitService.setRouteFare(routeId: number, fare: number)
	local route = _routes[routeId]
	if not route or typeof(fare) ~= "number" or fare ~= fare then return end
	route.fare = math.clamp(math.floor(fare), TransitTypes.MIN_FARE, TransitTypes.MAX_FARE)
	_dirty = true
end

function TransitService.setRouteColor(routeId: number, index: number)
	local route = _routes[routeId]
	if not route or typeof(index) ~= "number" then return end
	route.colorIndex = math.floor(index)
	route.color = TransitTypes.routeColor(route.colorIndex)
	_dirty = true
end

function TransitService.toggleRoute(routeId: number, enabled: boolean)
	local route = _routes[routeId]
	if not route then return end
	route.enabled = enabled == true
	_dirty = true
end

function TransitService.setRouteDayOnly(routeId: number, dayOnly: boolean)
	local route = _routes[routeId]
	if not route then return end
	route.dayOnly = if dayOnly == true then true else nil
	_dirty = true
end

function TransitService.setDaylightCheck(fn: () -> boolean)
	_isDaylight = fn
end

-- Whether the line should have buses out right now: switched on, and inside its hours.
local function inService(route: Route): boolean
	return route.enabled and (not route.dayOnly or _isDaylight())
end

function TransitService.isRunningNow(routeId: number): boolean
	local route = _routes[routeId]
	return route ~= nil and inService(route)
end

function TransitService.renameRoute(routeId: number, name: string)
	local route = _routes[routeId]
	if not route or typeof(name) ~= "string" then return end
	local clean = string.sub(name:gsub("[%c]", ""), 1, 28)
	if #clean > 0 then route.name = clean; _dirty = true end
end

-- == Ridership + live stats ====================================================
-- A citizen committed to riding `routeId` for one trip (CitizenService, abstract riders).
function TransitService.recordRider(routeId: number, boardStopId: number?)
	local route = _routes[routeId]
	if not route then return end
	route.passengers += 1
	route.revenue += route.fare
	_fareRevenue += route.fare
	if boardStopId then
		local stop = _stops[boardStopId]
		if stop then stop.boardings += 1 end
	end
end

-- A citizen at `boardStopId` waiting for `routeId` to take them to `alightStopId`. The
-- callbacks fire at most once each: onBoard when they get on, then onAlight(stopPos) where
-- they get off -- or onGiveUp if nothing with room comes. Returns a rider id for cancelRider.
function TransitService.waitForRide(routeId: number, boardStopId: number, alightStopId: number,
	onBoard: (() -> ())?, onAlight: (Vector3) -> (), onGiveUp: () -> (),
	onCall: ((Vector3, () -> ()) -> ())?): number
	local route = _routes[routeId]
	local speedEst = if route and route.mode == "train" then TRAIN_SPEED_EST else BUS_SPEED_EST
	local headway = if route then route.lengthStuds / (speedEst * math.max(1, route.busCount)) else 0
	_riderSeq += 1
	_riders[_riderSeq] = {
		id = _riderSeq, routeId = routeId, boardStopId = boardStopId, alightStopId = alightStopId,
		waited = 0, patience = math.max(RIDER_PATIENCE_MIN, headway * RIDER_PATIENCE_HEADWAYS),
		onBoard = onBoard, onAlight = onAlight, onGiveUp = onGiveUp, onCall = onCall, vehicle = nil,
	}
	return _riderSeq
end

-- Drop a rider without firing anything (their household left, or their trip was replaced).
function TransitService.getRiderPosition(id: number?): Vector3?
	local rider = if id then _riders[id] else nil
	if not rider then return nil end
	local vehicle = rider.vehicle
	if typeof(vehicle) == "Instance" and vehicle:IsA("Model") and vehicle.Parent then
		-- a driving bus's model stays where it set off; its live pose is the traffic AI's
		return (NPCDriverService.GetLivePose(vehicle) or vehicle:GetPivot()).Position
	end
	local stop = _stops[rider.boardStopId]
	return if stop then stop.pos else nil
end

function TransitService.cancelRider(id: number?)
	if id then _riders[id] = nil end
end

-- Where a rider steps on or off: the vehicle's front door, on the stop's side.
local function doorOf(vehicle: any, stop: Stop): Vector3
	if typeof(vehicle) ~= "Instance" or not vehicle:IsA("Model") then return stop.pos end
	local pose = NPCDriverService.GetLivePose(vehicle) or vehicle:GetPivot()
	local _, size = vehicle:GetBoundingBox()
	local side = if (stop.pos - pose.Position):Dot(pose.RightVector) >= 0 then 1 else -1
	local p = pose.Position + pose.LookVector * (size.Z * 0.5 - 3) + pose.RightVector * (side * (size.X * 0.5 + 0.8))
	return Vector3.new(p.X, stop.pos.Y, p.Z)
end

-- A vehicle of `routeId` standing at `stopId`: riders for this stop get off, then riders
-- waiting here for this line get on while there are seats. Returns how many moved, which the
-- dispatcher turns into dwell time (boarding takes time).
function TransitService.vehicleAtStop(vehicle: any, routeId: number, stopId: number, capacity: number): number
	local stop = _stops[stopId]
	if not stop then return 0 end
	local moved, aboard = 0, 0
	local leaving: { Rider } = {}
	for _, r in _riders do
		if r.vehicle == vehicle then
			if r.alightStopId == stopId then
				table.insert(leaving, r)
			else
				aboard += 1
			end
		end
	end
	-- One person through the door every BOARD_SECONDS, everyone getting off first, then the
	-- waiting walking up to the door and stepping on: a full bus empties as a stream of people.
	-- Seats change hands now; the vehicle waits (isBoarding) until the last one is through.
	local gap = TransitTypes.BOARD_SECONDS / math.max(GameSpeed.get(), 1)
	local epoch = _epoch
	local door = doorOf(vehicle, stop)
	local pending = 0
	local function through()
		pending -= 1
		_boarding[vehicle] = if pending > 0 then pending else nil
	end
	for _, r in leaving do
		_riders[r.id] = nil
		local onAlight = r.onAlight
		pending += 1
		task.delay(moved * gap, function()
			if epoch == _epoch then onAlight(door) end
			through()
		end)
		moved += 1
	end
	for _, r in _riders do
		if aboard >= capacity then break end
		if not r.vehicle and r.routeId == routeId and r.boardStopId == stopId then
			r.vehicle = vehicle
			aboard += 1
			TransitService.recordRider(routeId, stopId)
			local onBoard, onCall = r.onBoard, r.onCall
			pending += 1
			task.delay(moved * gap, function()
				local function stepOn()
					if epoch == _epoch and onBoard then onBoard() end
					through()
				end
				if epoch == _epoch and onCall then onCall(door, stepOn) else stepOn() end
			end)
			moved += 1
		end
	end
	if pending > 0 and vehicle ~= nil then _boarding[vehicle] = pending end
	local route = _routes[routeId]
	if route and capacity > 0 then
		route.usage += (math.min(aboard / capacity, 1) * 100 - route.usage) * USAGE_SMOOTHING
	end
	if vehicle and typeof(vehicle) == "Instance" then vehicle:SetAttribute("Passengers", aboard) end
	return moved
end

-- Still people to come through this vehicle's door (vehicleAtStop): it waits for them.
function TransitService.isBoarding(vehicle: any): boolean
	return _boarding[vehicle] ~= nil
end

-- A vehicle leaving service (back to the depot, retired, destroyed): everyone aboard gets
-- off where it stands and finishes on foot.
function TransitService.vehicleOutOfService(vehicle: any, pos: Vector3)
	for id, r in _riders do
		if r.vehicle == vehicle then
			_riders[id] = nil
			task.spawn(r.onAlight, pos)
		end
	end
	if typeof(vehicle) == "Instance" then vehicle:SetAttribute("Passengers", 0) end
end

-- Riders standing at a stop, for the stop's own crowd (and its board count in the UI).
function TransitService.getWaitingCount(stopId: number): number
	local n = 0
	for _, r in _riders do
		if not r.vehicle and r.boardStopId == stopId then n += 1 end
	end
	return n
end

local function stepRiders(dt: number)
	for id, r in _riders do
		if r.vehicle then continue end
		r.waited += dt
		if r.waited >= r.patience then
			_riders[id] = nil
			task.spawn(r.onGiveUp)
		end
	end
end

-- BusDispatchService reports how many buses are live on a route (for the overview).
function TransitService.setRouteActiveBuses(routeId: number, n: number)
	local route = _routes[routeId]
	if route then route.activeBuses = n end
end

-- TrainDispatchService reports a train line's train type and its alert (nil = all well).
function TransitService.setRouteTrainInfo(routeId: number, trainType: string?, alert: string?)
	local route = _routes[routeId]
	if not route then return end
	if route.trainType ~= trainType or route.alert ~= alert then _dirty = true end
	route.trainType = trainType
	route.alert = alert
end

-- == Trip estimate (CitizenService mode choice) ================================
type StopCandidate = { id: number, stop: Stop, distance: number }

local function nearbyStops(pos: Vector3, reach: number): { StopCandidate }
	local out: { StopCandidate } = {}
	for id, stop in _stops do
		local distance = flatDist(stop.pos, pos)
		if distance <= reach then
			table.insert(out, { id = id, stop = stop, distance = distance })
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	while #out > 6 do table.remove(out) end
	return out
end

local function routeServes(route: Route, boardId: number, alightId: number): boolean
	if not inService(route) or route.broken or route.closed ~= true or route.busCount <= 0 or route.activeBuses <= 0 or #route.stops < 2 then return false end
	local hasBoard, hasAlight = false, false
	for _, sid in route.stops do
		if sid == boardId then hasBoard = true end
		if sid == alightId then hasAlight = true end
	end
	return hasBoard and hasAlight
end

-- Best transit option for a home->job trip, or nil if none is viable. The result is the
-- estimated door-to-door time + the fare so CitizenService can weigh it against driving.
export type TripEstimate = {
	usable: boolean, timeSeconds: number, fare: number,
	routeId: number, boardStopId: number, alightStopId: number,
	walkSeconds: number, waitSeconds: number, rideSeconds: number,
}
local function routeRideDistance(route: Route, boardId: number, alightId: number): number?
	local key=tostring(boardId)..":"..tostring(alightId)
	local cache=_rideDistanceCache[route]
	if cache and cache[key] then return cache[key] end
	local start=table.find(route.stops,boardId)
	if not start then return nil end
	local distance=0
	for offset=0,#route.stops-1 do
		local index=(start+offset-1)%#route.stops+1
		local points=route.legPaths[index]
		if not points or #points<2 then return nil end
		for i=2,#points do distance+=(points[i]-points[i-1]).Magnitude end
		local nextIndex=index%#route.stops+1
		if route.stops[nextIndex]==alightId then
			if not cache then cache={};_rideDistanceCache[route]=cache end
			cache[key]=distance
			return distance
		end
	end
	return nil
end

function TransitService.estimateTrip(homePos: Vector3, jobPos: Vector3): TripEstimate?
	if typeof(homePos) ~= "Vector3" or typeof(jobPos) ~= "Vector3" then return nil end
	local reach = TransitTypes.STOP_WALK_REACH
	local boards = nearbyStops(homePos, reach)
	local alights = nearbyStops(jobPos, reach)
	if #boards == 0 or #alights == 0 then return nil end

	local best: TripEstimate? = nil
	for _, boardCandidate in boards do
		for _, alightCandidate in alights do
			if boardCandidate.id == alightCandidate.id then continue end
			for _, route in _routes do
				if not routeServes(route, boardCandidate.id, alightCandidate.id) then continue end
				local walkIn = boardCandidate.distance / WALK_SPEED
				local walkOut = alightCandidate.distance / WALK_SPEED
				local rideSpeed = if route.mode == "train" then TRAIN_SPEED_EST else BUS_SPEED_EST
				local rideDist = routeRideDistance(route, boardCandidate.id, alightCandidate.id)
				if not rideDist then continue end
				local ride = rideDist / rideSpeed
				local loopLen = math.max(1, route.lengthStuds)
				local dwell = if route.mode == "train" then TransitTypes.TRAIN_STOP_DWELL else TransitTypes.STOP_DWELL
				local headway = (loopLen / rideSpeed + #route.stops * dwell) / math.max(1, route.activeBuses)
				local wait = headway * 0.5
				local total = walkIn + wait + ride + walkOut
				if not best or total < best.timeSeconds then
					best = {
						usable = true,
						timeSeconds = total,
						fare = route.fare,
						routeId = route.id,
						boardStopId = boardCandidate.id,
						alightStopId = alightCandidate.id,
						walkSeconds = walkIn + walkOut,
						waitSeconds = wait,
						rideSeconds = ride,
					}
				end
			end
		end
	end
	return best
end

-- == Economy ===================================================================
function TransitService.drainFareRevenue(): number
	local r = _fareRevenue
	_fareRevenue = 0
	-- The economy drains fares every tick, but riders / revenue / boardings are MONTHLY stats: they
	-- roll over once a month of ticks has passed (rolled every tick, they always read 0).
	_monthTicks += 1
	if _monthTicks < MONTH_TICKS then return r end
	_monthTicks = 0
	for _, route in _routes do
		route.displayPassengers = route.passengers
		route.passengers = 0
		route.displayRevenue = route.revenue
		route.revenue = 0
	end
	for _, stop in _stops do
		stop.displayBoardings = stop.boardings
		stop.boardings = 0
	end
	return r
end

-- Total boardings across all lines this economy-month (live count, or last month's
-- snapshot right after a drain -- whichever is larger). CitizenService pushes this to
-- CityStatsService so a used bus network pulls new residents in.
function TransitService.getMonthlyRiders(): number
	local riders = 0
	for _, r in _routes do
		riders += math.max(r.displayPassengers, r.passengers)
	end
	return riders
end

function TransitService.getMonthlyUpkeep(): number
	local upkeep = 0
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		upkeep += if spec then spec.upkeep else 0
	end
	for _, st in _stops do
		local spec = TransitTypes.getStop(st.key)
		upkeep += if spec then (spec.upkeep or 0) else 0
	end
	upkeep += TransitService.getBusesAssigned() * TransitTypes.BUS_UPKEEP
	upkeep += TransitService.getTrainsRunning() * TransitTypes.TRAIN_UPKEEP
	return upkeep
end

-- == Utilities ===================================================================
-- Depots, hubs and stations draw power, water and sewage like any building (user 2026-10-07), at their specs'
-- figures, and pick them up from the road like any building: a depot is reached at its gates, an interchange
-- where its buses come in, a rail station at its platform. PowerService / WaterService read this list through
-- setCustomers (Bootstrap); the NoPower / NoWater / NoSewage badges land on the models.
export type UtilityCustomer = { id: string, model: Model, pos: Vector3, kw: number, m3: number, drain: number }

function TransitService.utilityCustomers(): { UtilityCustomer }
	local out: { UtilityCustomer } = {}
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		if not (spec and d.model and d.model.Parent) then continue end
		local gates = TransitTypes.gatePoints(spec, d.cf)
		local pos = if #gates > 0 then (gates[1] + gates[#gates]) * 0.5 else d.entrance
		out[#out + 1] = { id = "depot:" .. d.id, model = d.model, pos = pos,
			kw = spec.powerUse or 0, m3 = spec.waterUse or 0, drain = spec.sewageShare or 1 }
	end
	for _, st in _stops do
		local spec = TransitTypes.getStop(st.key)
		if not (spec and (spec.powerUse or spec.waterUse) and st.model and st.model.Parent) then continue end
		out[#out + 1] = { id = "stop:" .. st.id, model = st.model, pos = if spec.interchange then st.roadPos else st.pos,
			kw = spec.powerUse or 0, m3 = spec.waterUse or 0, drain = spec.sewageShare or 1 }
	end
	return out
end

-- A depot short of power, water or its drain sends no bus out (BusDispatchService); the buses it has on lines
-- keep running. Its badge says which one is missing.
function TransitService.depotWorks(id: number): boolean
	local m = _depots[id] and _depots[id].model
	if not m then return false end
	return not (m:GetAttribute("NoPower") or m:GetAttribute("NoWater") or m:GetAttribute("NoSewage"))
end

local DEPOT_WARN_EVERY = 180 -- s between "a depot is down" notices
local _depotWarnedAt = -math.huge
-- A line wants a bus and only a depot without its utilities has one: say so, once in a while.
function TransitService.warnDepotDown()
	if not _net or os.clock() - _depotWarnedAt < DEPOT_WARN_EVERY then return end
	_depotWarnedAt = os.clock()
	_net.Notify:FireAllClients({
		text = "A bus depot has no electricity or water, so its buses stay parked. Connect it to the grid.",
		kind = "danger", duration = 6,
	})
end

-- == Getters for BusDispatchService ============================================
function TransitService.getDepots(): { Depot } local o = {}; for _, d in _depots do table.insert(o, d) end; return o end
function TransitService.getRoute(routeId: number): Route? return _routes[routeId] end
function TransitService.getStop(stopId: number): Stop? return _stops[stopId] end
function TransitService.getRouteIds(): { number } local o = {}; for id in _routes do table.insert(o, id) end; return o end

-- Nearest depot entrance to a position (where a bus spawns/returns), or nil if no depot.
function TransitService.nearestDepotEntrance(pos: Vector3): Vector3?
	local best, bestD = nil, math.huge
	for _, d in _depots do
		local dist = flatDist(d.entrance, pos)
		if dist < bestD then bestD = dist; best = d.entrance end
	end
	return best
end

-- The runtime fleet lives in BusDispatchService; let it wipe its buses when the whole
-- transit domain is cleared (city unload / reload) instead of waiting for a reconcile.
function TransitService.setFleetClearer(fn: () -> ())
	_fleetClearer = fn
end

function TransitService.clear()
	if _fleetClearer then pcall(_fleetClearer) end
	for id, d in _depots do releaseDepot(d); _depots[id] = nil end
	for id, s in _stops do if s.model and s.model.Parent then s.model:Destroy() end; _stops[id] = nil end
	table.clear(_routes)
	_depotId, _stopId, _routeId, _routeColorSeq, _fareRevenue = 0, 0, 0, 0, 0
	table.clear(_riders)
	_epoch += 1
	_dirty = true
end

-- == Wire snapshot + broadcast =================================================
local function snapshot(): any
	local depots = {}
	for _, d in _depots do
		local spec = TransitTypes.getDepot(d.key)
		table.insert(depots, { id = d.id, key = d.key, mode = spec and spec.mode or "bus", pos = d.cf.Position, cap = if d.bays then #d.bays elseif spec then spec.busCapacity else 0,
			name = if spec then spec.name else d.key, layout = d.layout,
			layouts = if spec and spec.template then TransitKitModel.layoutInfo(spec.template) else nil })
	end
	-- people standing at each stop (riders not aboard yet), for the stop panel
	local waiting: { [number]: number } = {}
	for _, r in _riders do
		if not r.vehicle then waiting[r.boardStopId] = (waiting[r.boardStopId] or 0) + 1 end
	end
	local stops = {}
	for _, s in _stops do
		table.insert(stops, { id = s.id, pos = s.pos, name = s.name, mode = s.mode, boardings = math.max(s.displayBoardings, s.boardings),
			waiting = waiting[s.id] or 0 })
	end
	local routes = {}
	local totalRevenue = 0
	for _, r in _routes do
		-- The line leg by leg (legStarts: where each leg begins in `path`), then the tail of a line
		-- being drawn (tailStart), and the road points the player placed (leg 0 = the tail's).
		local outPath, legStarts = {}, {}
		local stepN = math.max(1, math.floor(#r.path / 160))
		local function addPts(pts: { Vector3 })
			for i = 1, #pts, stepN do table.insert(outPath, pts[i]) end
			if #pts > 0 and outPath[#outPath] ~= pts[#pts] then table.insert(outPath, pts[#pts]) end
		end
		for i = 1, (if r.closed then #r.stops else #r.stops - 1) do
			legStarts[i] = #outPath + 1
			addPts(r.legPaths[i] or {})
		end
		local tailStart: number? = nil
		if r.tailPath and #r.tailPath > 1 then
			tailStart = #outPath + 1
			addPts(r.tailPath)
		end
		local points = {}
		for leg, list in r.waypoints do
			for j, w in list do table.insert(points, { leg = leg, index = j, pos = w }) end
		end
		for j, w in r.pending do table.insert(points, { leg = 0, index = j, pos = w }) end
		-- this month so far, or last month's right after the roll-over (as getMonthlyRiders)
		local revenue = math.max(r.displayRevenue, r.revenue)
		totalRevenue += revenue
		table.insert(routes, {
			id = r.id, name = r.name, color = r.color, enabled = r.enabled, fare = r.fare, mode = r.mode,
			busCount = r.busCount, closed = r.closed, stops = table.clone(r.stops), path = outPath,
			legStarts = legStarts, tailStart = tailStart, points = points,
			length = r.lengthStuds, passengers = math.max(r.displayPassengers, r.passengers), usage = r.usage, activeBuses = r.activeBuses,
			revenue = revenue, trainType = r.trainType, alert = r.alert,
			dayOnly = r.dayOnly, resting = r.enabled and r.dayOnly == true and not _isDaylight(),
		})
	end
	return {
		depots = depots, stops = stops, routes = routes,
		allowance = TransitService.getBusAllowance(), assigned = TransitService.getBusesAssigned(),
		trainAllowance = TransitService.getTrainAllowance(), trainsRunning = TransitService.getTrainsRunning(),
		upkeep = TransitService.getMonthlyUpkeep(), revenue = totalRevenue,
	}
end

function TransitService.broadcast()
	if _net then _net.SyncTransit:FireAllClients(snapshot()) end
	_dirty = false
end

-- == Persistence ===============================================================
local function v3arr(v: Vector3): { number } return { v.X, v.Y, v.Z } end
local function arrV3(t: any): Vector3?
	if typeof(t) ~= "table" or #t ~= 3 then return nil end
	return Vector3.new(tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0)
end

function TransitService.serialize(): any
	local depots = {}
	for _, d in _depots do
		table.insert(depots, { id = d.id, key = d.key, pivot = Quant.packPivot(d.cf), ent = v3arr(d.entrance), layout = d.layout })
	end
	local stops = {}
	for _, s in _stops do
		table.insert(stops, {
			id = s.id, key = s.key, pos = v3arr(s.pos), road = v3arr(s.roadPos),
			facing = Quant.packPivot(s.facing), seg = s.segmentId, edge = s.edgeId, name = s.name,
		})
	end
	local routes = {}
	for _, r in _routes do
		local wps = {}
		for leg, list in r.waypoints do
			local arr = {}
			for _, w in list do table.insert(arr, v3arr(w)) end
			wps[tostring(leg)] = arr
		end
		table.insert(routes, {
			id = r.id, name = r.name, colorIndex = r.colorIndex, enabled = r.enabled, mode = r.mode,
			fare = r.fare, busCount = r.busCount, closed = r.closed, stops = table.clone(r.stops), wps = wps,
			dayOnly = r.dayOnly,
		})
	end
	return { version = 1, depotId = _depotId, stopId = _stopId, routeId = _routeId, colorSeq = _routeColorSeq,
		depots = depots, stops = stops, routes = routes }
end

function TransitService.restore(data: any)
	TransitService.clear()
	if typeof(data) ~= "table" then return end
	_depotId = math.max(0, math.floor(tonumber(data.depotId) or 0))
	_stopId  = math.max(0, math.floor(tonumber(data.stopId) or 0))
	_routeId = math.max(0, math.floor(tonumber(data.routeId) or 0))
	_routeColorSeq = math.max(0, math.floor(tonumber(data.colorSeq) or 0))

	if typeof(data.depots) == "table" then
		for _, row in data.depots do
			if typeof(row) ~= "table" or typeof(row.key) ~= "string" or not TransitTypes.getDepot(row.key) then continue end
			local pivot = Quant.unpackPivot(row.pivot)
			if not pivot then continue end
			local entrance = arrV3(row.ent) or pivot.Position
			local id = math.floor(tonumber(row.id) or 0)
			if id <= 0 then _depotId += 1; id = _depotId end
			_depotId = math.max(_depotId, id)
			spawnDepot(id, row.key, pivot, entrance, tonumber(row.layout))
		end
	end

	if typeof(data.stops) == "table" then
		for _, row in data.stops do
			if typeof(row) ~= "table" or typeof(row.key) ~= "string" or not TransitTypes.getStop(row.key) then continue end
			if (TransitTypes.getStop(row.key) :: TransitTypes.StopSpec).interchange then
				local pivot = Quant.unpackPivot(row.facing)
				local iid = math.floor(tonumber(row.id) or 0)
				if pivot and iid > 0 then
					_stopId = math.max(_stopId, iid)
					local _, why = spawnInterchange(iid, row.key, pivot, tostring(row.name or ""))
					if why then warn("[TransitService] interchange " .. iid .. " not restored: " .. why) end
				end
				continue
			end
			local pos = arrV3(row.pos); local road = arrV3(row.road)
			if not pos or not road then continue end
			local facing = Quant.unpackPivot(row.facing) or CFrame.new(pos)
			local segmentId = math.floor(tonumber(row.seg) or 0)
			local edgeId = if typeof(row.edge) == "string" then row.edge else nil
			local stopSpec = TransitTypes.getStop(row.key) :: TransitTypes.StopSpec
			local mode = stopSpec.mode or "bus"
			local g = graphFor(mode)
			if g then
				local edge = if edgeId then g:GetEdge(edgeId) else nil
				if edge then
					local _, snapped = nearestPointOnEdge(edge, pos)
					road = snapped
				else
					local pickedEdge, _, snapped = nearestBoardingEdge(g, if segmentId > 0 then segmentId else nil, pos, nil)
					if pickedEdge and snapped then
						edgeId = pickedEdge.id
						road = snapped
					end
				end
			end
			local model = buildStopModel(stopSpec)
			model:PivotTo(facing)
			local net = _roadService and _roadService.getNetwork and _roadService.getNetwork()
			local laneEdge = if g and edgeId then g:GetEdge(edgeId) else nil
			local kb = if mode == "bus" and net and laneEdge then
				kerbBay(facing, net:getSegment(segmentId), laneEdge, road, stopSpec.curbOffset * RoadConstants.WORLD_SCALE) else nil
			if kb then
				model:SetAttribute("BusBayLength", BAY_LEN)
				if kb.depth > 0 then
					model:PivotTo(facing * CFrame.new(0, 0, -kb.depth))
					model:SetAttribute("BusBayDepth", kb.depth)
				end
				paintBay(model, kb)
			end
			local id = math.floor(tonumber(row.id) or 0)
			if id <= 0 then _stopId += 1; id = _stopId end
			_stopId = math.max(_stopId, id)
			model:SetAttribute("StopId", id)
			model:SetAttribute("RoadSegmentId", segmentId)
			model:SetAttribute("TransitKind", "Stop")
			model:SetAttribute("StopName", tostring(row.name or ""))
			CollectionService:AddTag(model, if mode == "train" then "TrainStation" else "BusStop")
			model.Parent = _folder
			_stops[id] = {
				id = id, key = row.key, pos = pos, roadPos = if kb then kb.roadPos else road, facing = facing,
				segmentId = segmentId, edgeId = edgeId, name = tostring(row.name or ""), model = model, mode = mode,
				boardings = 0, displayBoardings = 0,
				bays = if kb then kb.bays else nil, exitPos = if kb then kb.exitPos else nil, kerbBay = if kb then true else nil,
			}
		end
	end

	if typeof(data.routes) == "table" then
		for _, row in data.routes do
			if typeof(row) ~= "table" then continue end
			local stops = {}
			if typeof(row.stops) == "table" then
				for _, sid in row.stops do local n = math.floor(tonumber(sid) or 0); if _stops[n] then table.insert(stops, n) end end
			end
			if #stops == 0 then continue end
			local wps = {}
			if typeof(row.wps) == "table" then
				for legKey, arr in row.wps do
					local leg = math.floor(tonumber(legKey) or 0)
					if leg > 0 and typeof(arr) == "table" then
						local list = {}
						for _, w in arr do local v = arrV3(w); if v then table.insert(list, v) end end
						if #list > 0 then wps[leg] = list end
					end
				end
			end
			local id = math.floor(tonumber(row.id) or 0)
			if id <= 0 then _routeId += 1; id = _routeId end
			_routeId = math.max(_routeId, id)
			local ci = math.floor(tonumber(row.colorIndex) or id)
			local mode = if typeof(row.mode) == "string" then row.mode else ((_stops[stops[1]] and _stops[stops[1]].mode) or "bus")
			local route: Route = {
				id = id, name = tostring(row.name or ((if mode == "train" then "Train Line " else "Bus Line ") .. id)), mode = mode,
				color = TransitTypes.routeColor(ci), colorIndex = ci,
				enabled = row.enabled ~= false,
				dayOnly = if row.dayOnly == true then true else nil,
				fare = math.clamp(math.floor(tonumber(row.fare) or TransitTypes.DEFAULT_FARE), TransitTypes.MIN_FARE, TransitTypes.MAX_FARE),
				busCount = math.max(0, math.floor(tonumber(row.busCount) or 0)),
				closed = row.closed ~= false,
				stops = stops, waypoints = wps, pending = {},
				path = {}, legEdges = {}, legPaths = {}, lengthStuds = 0,
				activeBuses = 0, passengers = 0, displayPassengers = 0, usage = 0,
				revenue = 0, displayRevenue = 0,
			}
			_routes[id] = route
			TransitService._recomputeRoute(route)
		end
		TransitService._clampBusAssignments()
	end
	_dirty = true
end

-- == Remote command dispatch ===================================================
local function handleCommand(player: Player, action: any, payload: any)
	if not canEdit(player) then return end
	if typeof(action) ~= "string" then return end
	local now = os.clock()
	if now - (_lastCmdAt[player] or 0) < CMD_COOLDOWN then return end
	_lastCmdAt[player] = now
	local p = if typeof(payload) == "table" then payload else {}

	if action == "placeStop" then
		local want = if typeof(p.key) == "string" then TransitTypes.getStop(p.key) else nil
		local key = if want and not want.interchange then p.key else "BusStopShelter"
		local ok, res = TransitService.placeStop(key, p, player)
		if not ok and typeof(res) == "string" then
			_net.Notify:FireClient(player, { text = "Can't place: " .. res, kind = "danger", duration = 3 })
		end
	elseif action == "removeStop" then
		if typeof(p.id) == "number" then TransitService.removeStop(p.id) end
	elseif action == "createRoute" then
		if typeof(p.stopId) == "number" then TransitService.createRoute(p.stopId) end
	elseif action == "addStop" then
		if typeof(p.routeId) == "number" and typeof(p.stopId) == "number" then TransitService.addStop(p.routeId, p.stopId) end
	elseif action == "removeRouteStop" then
		if typeof(p.routeId) == "number" and typeof(p.stopId) == "number" then TransitService.removeRouteStop(p.routeId, p.stopId) end
	elseif action == "addWaypoint" then
		if typeof(p.routeId) == "number" then TransitService.addWaypoint(p.routeId, p.pos) end
	elseif action == "setDepotLayout" then
		if typeof(p.id) == "number" and typeof(p.layout) == "number" then TransitService.setDepotLayout(p.id, p.layout) end
	elseif action == "insertStop" then
		if typeof(p.routeId) == "number" and typeof(p.leg) == "number" and typeof(p.stopId) == "number" then
			TransitService.insertStop(p.routeId, p.leg, p.stopId)
		end
	elseif action == "addLegPoint" then
		if typeof(p.routeId) == "number" and typeof(p.leg) == "number" then TransitService.addLegPoint(p.routeId, p.leg, p.pos) end
	elseif action == "moveWaypoint" then
		if typeof(p.routeId) == "number" and typeof(p.leg) == "number" and typeof(p.index) == "number" then
			TransitService.moveWaypoint(p.routeId, p.leg, p.index, p.pos)
		end
	elseif action == "removeWaypoint" then
		if typeof(p.routeId) == "number" and typeof(p.leg) == "number" and typeof(p.index) == "number" then
			TransitService.removeWaypoint(p.routeId, p.leg, p.index)
		end
	elseif action == "undo" then
		if typeof(p.routeId) == "number" then TransitService.undoRoute(p.routeId) end
	elseif action == "delete" then
		if typeof(p.routeId) == "number" then TransitService.deleteRoute(p.routeId) end
	elseif action == "setBuses" then
		if typeof(p.routeId) == "number" and typeof(p.n) == "number" then TransitService.setRouteBuses(p.routeId, p.n) end
	elseif action == "setFare" then
		if typeof(p.routeId) == "number" and typeof(p.fare) == "number" then TransitService.setRouteFare(p.routeId, p.fare) end
	elseif action == "setColor" then
		if typeof(p.routeId) == "number" and typeof(p.index) == "number" then TransitService.setRouteColor(p.routeId, p.index) end
	elseif action == "toggle" then
		if typeof(p.routeId) == "number" then TransitService.toggleRoute(p.routeId, p.enabled == true) end
	elseif action == "setDayOnly" then
		if typeof(p.routeId) == "number" then TransitService.setRouteDayOnly(p.routeId, p.dayOnly == true) end
	elseif action == "rename" then
		if typeof(p.routeId) == "number" and typeof(p.name) == "string" then TransitService.renameRoute(p.routeId, p.name) end
	end
	TransitService.broadcast()
end

-- == Lifecycle =================================================================
function TransitService.Init(net: any, roadService: any, buildingService: any, economyService: any)
	assert(net and roadService and buildingService, "[TransitService] missing dependencies")
	_net = net
	_roadService = roadService
	_buildingService = buildingService
	_economyService = economyService
	_folder = ensureFolder()
end

function TransitService.Bind()
	_net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, pivot: any)
		if kind ~= "Transit" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(key) ~= "string" or typeof(pivot) ~= "CFrame" then return end
		local ok, reason = TransitService.placeDepot(key, pivot, player)
		if not ok and typeof(reason) == "string" then
			_net.Notify:FireClient(player, { text = "Can't place: " .. reason, kind = "danger", duration = 3 })
		end
		TransitService.broadcast()
	end)
	_net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Transit" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		TransitService.removeDepot(id)
		TransitService.broadcast()
	end)
	_net.RequestTransitCommand.OnServerEvent:Connect(handleCommand)
	-- Live route preview: validated + throttled here, answered by previewPath (read-only).
	_net.RequestRoutePreview.OnServerInvoke = function(player: Player, routeId: any, target: any, leg: any, point: any): any
		if not canEdit(player) then return nil end
		local now = os.clock()
		if now - (_lastPreviewAt[player] or 0) < PREVIEW_COOLDOWN then return nil end
		_lastPreviewAt[player] = now
		if typeof(routeId) ~= "number" or typeof(target) ~= "Vector3" or target ~= target or target.Magnitude > 1e6 then return nil end
		if leg ~= nil and (typeof(leg) ~= "number" or leg ~= leg or leg < 0 or leg ~= math.floor(leg)) then return nil end
		if point ~= nil and (typeof(point) ~= "number" or point ~= point or point < 1 or point ~= math.floor(point)) then return nil end
		local ok, res = pcall(TransitService.previewPath, routeId, target, leg, point)
		if not ok then warn("[TransitService] previewPath failed: " .. tostring(res)); return nil end
		return res
	end
	Players.PlayerRemoving:Connect(function(pl)
		_lastCmdAt[pl] = nil; _lastPlaceAt[pl] = nil; _lastPreviewAt[pl] = nil
	end)
	Players.PlayerAdded:Connect(function(pl)
		task.delay(2, function()
			if pl.Parent and _net and _started then _net.SyncTransit:FireClient(pl, snapshot()) end
		end)
	end)
	-- Road edits can arrive in bursts (especially undo/redo and intersection splits).
	-- Re-route after the navigation graph's deferred rebuild, and spread larger route sets
	-- across frames so transit never blocks the road-edit frame.
	local function queueRouteRebuild()
		_routeRebuildVersion += 1
		if _routeRebuildQueued then return end
		_routeRebuildQueued = true
		task.delay(ROUTE_REBUILD_DEBOUNCE, function()
			local version = _routeRebuildVersion
			local processed = 0
			for _, route in _routes do
				pcall(TransitService._recomputeRoute, route)
				processed += 1
				if processed % 4 == 0 then
					task.wait()
				end
			end
			_dirty = true
			_routeRebuildQueued = false
			if version ~= _routeRebuildVersion then
				queueRouteRebuild()
			end
		end)
	end
	if _roadService.onSegmentRemoving then
		_roadService.onSegmentRemoving(TransitService.removeStopsForSegment)
	end
	if _roadService.onTopologyChanged then
		_roadService.onTopologyChanged(queueRouteRebuild)
	end
end

function TransitService.Start()
	_started = true
	local accum = 0
	local riderAccum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accum += dt
		riderAccum += dt
		if riderAccum >= 1 then
			stepRiders(riderAccum * GameSpeed.get())
			riderAccum = 0
		end
		-- Interval broadcasts only matter while routes exist (live line stats);
		-- otherwise only broadcast on _dirty so an empty/no-transit city costs nothing.
		if _dirty or (accum >= SYNC_INTERVAL and next(_routes) ~= nil) then
			accum = 0
			pcall(TransitService.broadcast)
		end
	end)
end

return TransitService
