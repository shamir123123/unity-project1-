--!strict
-- RoadRules
-- Single query layer for the rules that hang off a road/lane: speed limit, which
-- vehicle classes may use it, its functional class (for intersection priority +
-- truck route preference) and whether it carries on-street parking. Pure library
-- -- no state, no lifecycle, no side effects on require. Per-segment overrides
-- always win over the road type's defaults.

local RunService      = game:GetService("RunService")

local RoadConstants   = require(script.Parent.RoadConstants)
local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
local RoadTypes       = require(script.Parent.RoadTypes)
local VehicleTypes    = require(script.Parent.VehicleTypes)

type RoadTypeSpec = RoadTypeCatalog.RoadTypeSpec
type Segment      = RoadTypes.Segment

local RoadRules = {}

export type RoadClass = "local" | "arterial"
export type DrivingSide = "left" | "right"

-- == Driving side ===========================================================
-- The side traffic drives on is PURELY A PLAYER CHOICE. No world theme owns it and no
-- region implies it -- a US city with left-hand traffic is a perfectly legitimate thing
-- for a player to build, so nothing in the theme or region catalogs may set it. This
-- module is its one and only owner. CitySlotService persists the choice per city; the
-- server applies it on load.
--
-- DEFAULT_DRIVING_SIDE below is only what an unconfigured world starts on. It is not a
-- "correct" side, and no theme feeds it.
--
-- It lives here and not in RoadConstants because RoadConstants is frozen and evaluated
-- once at load, while this changes at runtime. Everything that cares must call these
-- getters ON EVERY USE -- never copy one into a module-level local, or it will hold
-- whatever the value was when that module happened to load.
--
-- Replication rides a Workspace attribute rather than a remote: the server sets it,
-- Roblox replicates it, and every client's copy of this module adopts it through the
-- listener at the bottom. A player joining a city mid-session reads the current value
-- straight off the attribute.
local DRIVING_SIDE_ATTRIBUTE = "DrivingSide"

local DEFAULT_DRIVING_SIDE: DrivingSide = "right"

-- Seeded from the default and immediately re-derived from it at the bottom of this
-- section, so these four can never drift out of step with each other.
local _drivingSide: DrivingSide = DEFAULT_DRIVING_SIDE
local _laneSideSign: number = 1
local _nearsideTurn: string = "right"
local _crossingTurn: string = "left"
local _sideListeners: { (DrivingSide) -> () } = {}

-- Accepts "Left"/"left"/"Right"/"right" -- the save format is capitalised, the road code
-- is not. Anything else is nil, so a forged or corrupt value can never set a side.
local function normalizeSide(value: any): DrivingSide?
	if type(value) ~= "string" then return nil end
	local lower = string.lower(value)
	if lower == "left" or lower == "right" then
		return lower :: DrivingSide
	end
	return nil
end

local function applySide(side: DrivingSide)
	_drivingSide = side
	local right = side == "right"
	_laneSideSign = if right then 1 else -1
	_nearsideTurn = if right then "right" else "left"
	_crossingTurn = if right then "left" else "right"
end

RoadRules.DEFAULT_DRIVING_SIDE = DEFAULT_DRIVING_SIDE

function RoadRules.getDrivingSide(): DrivingSide
	return _drivingSide
end

-- Which side of the centreline a direction's own lanes sit on: +1 = right of travel.
-- The single sign that puts the whole map on one side of the road.
function RoadRules.getLaneSideSign(): number
	return _laneSideSign
end

-- Turns named by what they do, not by compass direction.
-- A crossing turn cuts the oncoming carriageway (US left, UK right), so it yields unless
-- it holds a protected phase, and it is made from the lane next to the centreline.
-- A nearside turn hugs the kerb, conflicts with nothing, and is the one allowed on red.
function RoadRules.getNearsideTurn(): string
	return _nearsideTurn
end

function RoadRules.getCrossingTurn(): string
	return _crossingTurn
end

function RoadRules.isCrossingTurn(movement: string): boolean
	return movement == _crossingTurn
end

function RoadRules.isNearsideTurn(movement: string): boolean
	return movement == _nearsideTurn
end

-- Set the side. Returns true only when the value actually CHANGED, because that is the
-- signal the caller needs: flipping the side moves every lane to the other side of the
-- centreline, so the nav graph must be rebuilt and the roads re-rendered. Nothing baked
-- from the old value is still correct. A no-op change must not trigger that work.
function RoadRules.setDrivingSide(value: any): boolean
	local side = normalizeSide(value)
	if not side or side == _drivingSide then
		return false
	end
	applySide(side)
	-- Server writes the attribute so clients follow. On the server this also fires the
	-- listener below, which then sees no change and does nothing -- no double dispatch.
	if RunService:IsServer() then
		workspace:SetAttribute(DRIVING_SIDE_ATTRIBUTE, if side == "right" then "Right" else "Left")
	end
	for _, fn in _sideListeners do
		task.spawn(fn, side)
	end
	return true
end

-- Notified after the side changes. The road renderer and the nav graph hang off this.
function RoadRules.onDrivingSideChanged(fn: (DrivingSide) -> ()): () -> ()
	table.insert(_sideListeners, fn)
	return function()
		local i = table.find(_sideListeners, fn)
		if i then table.remove(_sideListeners, i) end
	end
end

-- Adopt whatever the world already says, then follow later changes. This is what makes a
-- client correct without any handshake, and what makes a server module that loads late
-- still see the side the city was restored with.
do
	-- Derive the four values from the default rather than trusting the literals above to
	-- stay in step with it, then let the world override.
	applySide(DEFAULT_DRIVING_SIDE)
	local existing = normalizeSide(workspace:GetAttribute(DRIVING_SIDE_ATTRIBUTE))
	if existing then
		applySide(existing)
	end
	workspace:GetAttributeChangedSignal(DRIVING_SIDE_ATTRIBUTE):Connect(function()
		local side = normalizeSide(workspace:GetAttribute(DRIVING_SIDE_ATTRIBUTE))
		if side and side ~= _drivingSide then
			applySide(side)
			for _, fn in _sideListeners do
				task.spawn(fn, side)
			end
		end
	end)
end

-- studs/s = (km/h / 3.6 m/s) / STUD_TO_METER. Rides the WORLD_SCALE knob: shown
-- km/h limits never change, cars cover the same city blocks per second at any scale.
local STUDS_PER_KMH = (1 / 3.6) / RoadConstants.STUD_TO_METER

function RoadRules.getSpeedLimitKmh(seg: Segment?, spec: RoadTypeSpec): number
	if seg and seg.speedLimitOverride then
		return seg.speedLimitOverride
	end
	return spec.speedLimit
end

function RoadRules.getSpeedLimitStuds(seg: Segment?, spec: RoadTypeSpec): number
	return RoadRules.getSpeedLimitKmh(seg, spec) * STUDS_PER_KMH
end

function RoadRules.allowedVehicleSet(seg: Segment?, spec: RoadTypeSpec): { [string]: boolean }?
	if seg and seg.allowedVehiclesOverride then
		return seg.allowedVehiclesOverride
	end
	return spec.allowedVehicles
end

RoadRules.BUS_LANE_CLASSES = VehicleTypes.BusLaneClasses

-- Allowed set for ONE lane of a segment. Same as allowedVehicleSet, except the kerbside
-- lane (highest ordinal, DRIVING_SIDE-agnostic by construction) of a bus-lane road.
-- A direction with only one lane keeps it open: restricting it would block all traffic.
function RoadRules.laneAllowedVehicleSet(seg: Segment?, spec: RoadTypeSpec, laneOrdinal: number, laneCountInDirection: number): { [string]: boolean }?
	if spec.busLane and laneCountInDirection >= 2 and laneOrdinal == laneCountInDirection then
		return RoadRules.BUS_LANE_CLASSES
	end
	return RoadRules.allowedVehicleSet(seg, spec)
end

-- A nil allowed-set means "no restriction": every vehicle class may use the lane.
function RoadRules.allowsVehicle(seg: Segment?, spec: RoadTypeSpec, class: string): boolean
	local set = RoadRules.allowedVehicleSet(seg, spec)
	if not set then return true end
	return set[class] == true
end

-- Functional class. Drives which intersections get signals vs priority rules,
-- and how strongly trucks prefer a road. Avenues/boulevards and wider are
-- arterial; ordinary streets and alleys are local. Strictly WIDER than a two-lane
-- street (36 authored): at ">=" the plain street itself counted as arterial, so every
-- street junction read as two major roads meeting.
local ARTERIAL_MIN_WIDTH = 36 * RoadConstants.WORLD_SCALE
function RoadRules.roadClass(spec: RoadTypeSpec): RoadClass
	-- The carriageway, not the parking beside it: a street parked both sides (every new one) or
	-- with angled stalls is still a local street, and gets no traffic lights for its parking.
	if spec.laneCount >= 3 or RoadTypeCatalog.carriagewayWidth(spec) > ARTERIAL_MIN_WIDTH + 1e-3 then
		return "arterial"
	end
	return "local"
end

function RoadRules.hasParking(seg: Segment?, spec: RoadTypeSpec): boolean
	return spec.parkingLane == true
end

export type NodeControl = "none" | "priority" | "signal"

-- Flat unit direction a segment leaves `nodeId` in, from its control points.
local function armDirAt(seg: any, nodeId: number): Vector3?
	local raw: Vector3
	if seg.startNode == nodeId then
		raw = seg.p1 - seg.p0
		if raw.Magnitude < 1e-3 then raw = seg.p3 - seg.p0 end
	else
		raw = seg.p2 - seg.p3
		if raw.Magnitude < 1e-3 then raw = seg.p0 - seg.p3 end
	end
	local flat = Vector3.new(raw.X, 0, raw.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else nil
end

-- Two arms this close to opposite run straight through the node (the renderer's own test).
local THROUGH_DOT = -0.866
-- A one-way road leaving or joining a through road within this angle of it is a ramp / slip
-- road on its own side (RoadJunctionSolver: RAMP_ANGLE for highways, FORK_ANGLE otherwise).
local RAMP_COS, FORK_COS = math.cos(math.rad(80)), math.cos(math.rad(30))

export type HighwayJunction = "onesided" | "crossing"

-- How a junction sits on a highway that runs straight through it:
--   "onesided" -- every other arm joins from ONE side: an on/off ramp, a slip road, a street
--                 T-ing into it. Traffic merges and diverges; nothing crosses the highway.
--                 No lights, and on a divided highway the median runs straight past
--                 (right-in/right-out: nobody turns across it).
--   "crossing" -- arms on BOTH sides: a road drawn right across the highway. The median
--                 opens there and the junction is signalised.
--   nil        -- no highway runs straight through this node.
-- Second return: whether that highway is DIVIDED (a two-way road with a median).
function RoadRules.highwayJunction(network: any, nodeId: number): (HighwayJunction?, boolean)
	local node = network:getNodes()[nodeId]
	local segIds = if node then node.segments else nil
	if not segIds or #segIds < 3 then return nil, false end
	local dirs: { Vector3 } = {}
	local specs: { any } = {}
	for i, sid in segIds do
		local seg = network:getSegment(sid)
		local dir = seg and armDirAt(seg, nodeId)
		if not dir then return nil, false end
		dirs[i] = dir
		specs[i] = RoadTypeCatalog.getOrDefault(seg.roadType)
	end
	-- The highway running through: the widest pair of highway arms in line (two ramps on
	-- opposite sides are in line with each other too, but they are not the road).
	local ta, tb, widest = 0, 0, -1
	for a = 1, #dirs do
		for b = a + 1, #dirs do
			if not (specs[a].isHighway and specs[b].isHighway) or dirs[a]:Dot(dirs[b]) >= THROUGH_DOT then continue end
			if specs[a].width + specs[b].width > widest then ta, tb, widest = a, b, specs[a].width + specs[b].width end
		end
	end
	if widest < 0 then return nil, false end
	local left, right = false, false
	for k = 1, #dirs do
		if k == ta or k == tb then continue end
		-- ramps on both sides at one node only merge / diverge, each on its own side: not a
		-- crossing (user, 2026-10-07: it opened the median and signalled the highway)
		local along = math.max(dirs[k]:Dot(dirs[ta]), dirs[k]:Dot(dirs[tb]))
		local ramp = specs[k].oneWay and specs[k].width < math.max(specs[ta].width, specs[tb].width)
		if ramp and along >= (if specs[k].isHighway then RAMP_COS else FORK_COS) then continue end
		-- a road across it on both sides, or two highways meeting at grade, cross
		local side = dirs[ta]:Cross(dirs[k]).Y
		if side > 0 then left = true else right = true end
	end
	local found: HighwayJunction = if left and right then "crossing" else "onesided"
	return found, specs[ta].median == true and not specs[ta].oneWay
end

-- The player's per-junction choice (lights on / off), installed by the server's signal
-- service; nil everywhere else, which leaves every junction on the automatic rule.
local _controlOverride: ((nodeId: number) -> NodeControl?)? = nil
function RoadRules.setControlOverride(fn: ((nodeId: number) -> NodeControl?)?)
	_controlOverride = fn
end

-- The player's main-road choice per junction: the bearing (radians, atan2(x, z)) of one arm
-- of the road that goes first. Installed by the server's signal service; nil = automatic.
local _priorityOverride: ((nodeId: number) -> number?)? = nil
function RoadRules.setPriorityOverride(fn: ((nodeId: number) -> number?)?)
	_priorityOverride = fn
end

function RoadRules.priorityOverride(nodeId: number): number?
	return if _priorityOverride then _priorityOverride(nodeId) else nil
end

-- Bearing of an arm as leaving `nodeId`, in the form priorityOverride stores.
function RoadRules.armBearing(network: any, nodeId: number, segId: number): number?
	local seg = network:getSegment(segId)
	local dir = seg and armDirAt(seg, nodeId)
	return if dir then math.atan2(dir.X, dir.Z) else nil
end

-- How an intersection node is controlled. Not every junction gets lights:
--   * < 3 arms                         -> "none"     (a continuation / dead end)
--   * a roundabout node                -> "none"     (entering traffic gives way)
--   * a highway ramp / slip / side road -> "priority" (see highwayJunction)
--   * a road drawn across a highway    -> "signal"
--   * two different major roads meet   -> "signal"
--   * anything else                    -> "priority" (one main road goes first, every other
--                                                     arm gives way -- see priorityArms)
-- `network` is the live RoadNetwork (typed loosely since it crosses the module
-- boundary as an injected runtime object).
function RoadRules.nodeControl(network: any, nodeId: number): NodeControl
	local node = network:getNodes()[nodeId]
	local arms = if node and node.segments then #node.segments else 0
	if arms < 3 then
		return "none"
	end
	-- A roundabout entry/exit is yield-controlled, never signalised: circulating
	-- traffic has priority and entering traffic gives way (handled by the driver).
	if network.isRoundaboutNode ~= nil and network:isRoundaboutNode(nodeId) then
		return "none"
	end
	local forced = if _controlOverride then _controlOverride(nodeId) else nil
	if forced == "signal" or forced == "priority" then
		return forced
	end
	return RoadRules.autoNodeControl(network, nodeId)
end

-- The automatic rule alone, ignoring the player's override. Only for junctions nodeControl
-- has already found to be one (3+ arms, not a roundabout).
function RoadRules.autoNodeControl(network: any, nodeId: number): NodeControl
	local node = network:getNodes()[nodeId]
	-- A highway running through: lights only where a road crosses it. A ramp, a slip road or
	-- a street joining from one side merges under give-way, whatever its lane count.
	local hwKind = RoadRules.highwayJunction(network, nodeId)
	if hwKind == "onesided" then
		return "priority"
	elseif hwKind == "crossing" then
		return "signal"
	end
	local segs = if node then node.segments else nil
	if not segs then
		return "priority"
	end
	-- A junction where ONLY highways meet never signals: ramps merge and highways fork
	-- under give-way priority, like a motorway interchange.
	local allHighway = #segs > 0
	for _, sid in segs :: { number } do
		local s = network:getSegments()[sid]
		if not (s and RoadTypeCatalog.getOrDefault(s.roadType).isHighway) then
			allHighway = false
			break
		end
	end
	if allHighway then
		return "priority"
	end
	-- Road hierarchy. Lights only where two DIFFERENT major roads meet (arterial class: 3+
	-- lanes or a wide carriageway -- the same test the drivers' give-way priority uses). A
	-- major road that simply runs through, with smaller roads joining it from either side,
	-- gets no lights: the smaller roads give way to it. A car that has waited long enough
	-- takes its turn and the main road lets it in (NPCDriverService), then the next one does
	-- the same -- so a side road that cannot cope queues visibly, and the fix is the player's:
	-- lights (a per-junction override), a roundabout, or another way round. This used to
	-- signalise any junction with a 4-lane arm, so a one-way lane joining an avenue got a full
	-- set of lights.
	local majorDirs: { Vector3 } = {}
	for _, sid in segs :: { number } do
		local s = network:getSegment(sid)
		if s and RoadRules.roadClass(RoadTypeCatalog.getOrDefault(s.roadType)) == "arterial" then
			local dir = armDirAt(s, nodeId)
			if dir then table.insert(majorDirs, dir) end
		end
	end
	if #majorDirs <= 1 then
		return "priority"
	end
	if #majorDirs == 2 and majorDirs[1]:Dot(majorDirs[2]) < THROUGH_DOT then
		return "priority" -- one major road running straight through
	end
	return "signal"
end

-- Two arms at least this close to opposite can be one main road through a junction.
local MAIN_ROAD_DOT = -0.5

-- How much right of way a road carries: highways, then major roads, then width.
local function roadWeight(spec: RoadTypeSpec): number
	return (if spec.isHighway then 2000 else 0)
		+ (if RoadRules.roadClass(spec) == "arterial" then 1000 else 0)
		+ spec.width
end

-- The arms (segment ids) with right of way at a junction without lights: ONE main road --
-- an arm plus the arm carrying on across from it, or that arm alone when nothing does.
-- Every other arm gives way. Automatic pick: the heaviest road, so the bigger road goes
-- first; a tie goes to the lower segment id so the answer never flickers. The player's
-- choice (priorityOverride) names the arm nearest its bearing instead, unless `autoOnly`.
-- Exactly one main road is what stops a crossroads of equal streets locking up with a car
-- waiting on every arm, each giving way to the next.
function RoadRules.priorityArms(network: any, nodeId: number, autoOnly: boolean?): { [number]: boolean }
	local main: { [number]: boolean } = {}
	local node = network:getNodes()[nodeId]
	if not node or not node.segments then return main end
	local ids: { number } = {}
	local dirs: { Vector3 } = {}
	local weights: { number } = {}
	for _, sid in node.segments :: { number } do
		local seg = network:getSegment(sid)
		local dir = seg and armDirAt(seg, nodeId)
		if dir then
			table.insert(ids, sid)
			table.insert(dirs, dir)
			table.insert(weights, roadWeight(RoadTypeCatalog.getOrDefault(seg.roadType)))
		end
	end
	local function partnerOf(i: number): number?
		local best: number? = nil
		local bestDot = MAIN_ROAD_DOT
		for j, d in dirs do
			if j ~= i and dirs[i]:Dot(d) < bestDot then
				best, bestDot = j, dirs[i]:Dot(d)
			end
		end
		return best
	end
	local pickI: number? = nil
	local override = if autoOnly then nil else RoadRules.priorityOverride(nodeId)
	if override then
		local want = Vector3.new(math.sin(override), 0, math.cos(override))
		local bestDot = -math.huge
		for i, d in dirs do
			if d:Dot(want) > bestDot then pickI, bestDot = i, d:Dot(want) end
		end
	else
		local bestW, bestId = -math.huge, math.huge
		for i in dirs do
			local j = partnerOf(i)
			local w = weights[i] + (if j then weights[j] else 0)
			local id = math.min(ids[i], if j then ids[j] else math.huge)
			if w > bestW or (w == bestW and id < bestId) then
				pickI, bestW, bestId = i, w, id
			end
		end
	end
	if pickI then
		main[ids[pickI]] = true
		local j = partnerOf(pickI)
		if j then main[ids[j]] = true end
	end
	return main
end

-- Roundabout right-of-way. No roundabout geometry exists yet -- this records the
-- rule so the driver is ready when they're added: vehicles already circulating
-- on the ring have priority; entering vehicles yield to circulating traffic.
RoadRules.ROUNDABOUT_CIRCULATING_HAS_PRIORITY = true

return RoadRules
