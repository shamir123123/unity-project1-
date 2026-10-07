--!strict
-- SnapUtil
-- THE snap model. One resolve() answers "where does this cursor actually go" for road
-- drawing, and snapBuilding() answers the same question for every building tool. Order,
-- highest priority first:
--
--   0. no roads placed yet -> NOTHING snaps. The first road is drawn free, angle included.
--   1. existing geometry   -> node weld, then the centreline of the road under the cursor --
--      or, with Lane Snap on, the middle of the LANE under it (a plain joint in a road gives way
--      to the lane: only junctions and dead ends weld there)
--   2. junction centres
--   3. a building's road-access side -> its frontage line, so a road meets a building the
--      same way a building placed against a road does, only the other way round
--   4. ONE live guideline  -> a ray off a road node with rings every 100 m (see tryGuide)
--   5. angle magnet        -> free heading except within 10deg of a right angle
--
-- Every snap POINT holds inside SNAP_HOLD (5 m). Road BODIES capture across their own
-- footprint instead, because "the cursor is on the road" is a different question from
-- "the cursor is near a point".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants     = require(ReplicatedStorage.Road.RoadConstants)
local SnapConstants     = require(script.SnapConstants)
local RoadTypeCatalog   = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil        = require(ReplicatedStorage.Road.BezierUtil)
local RoadSection       = require(ReplicatedStorage.Road.RoadSection)
local RoadRules         = require(ReplicatedStorage.Road.RoadRules)
-- The game-wide placement grid: roads snap to the same lines buildings and props do.
local PlacementGrid     = require(ReplicatedStorage.Shared.PlacementGrid)

export type SegmentData = {
	id: number,
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	roadType: string,
	isRoundabout: boolean?,
	startLane: Vector3?, -- an end laid off a lane: drawn this far from its node (Segment.startLane)
	endLane: Vector3?,
}

-- The road-access side of a placed building: the centre of that side, the outward
-- normal off it, and how far the body reaches back and sideways from that centre.
export type BuildingFront = {
	pos: Vector3,
	dir: Vector3,
	halfDepth: number,
	halfWidth: number,
}

export type SnapType = "none" | "center" | "lane" | "building" | "guide" | "grid" | "intersection" | "angle"

-- A line to draw: where it starts, which way it runs, and the rings along it. A result
-- carries one of these normally and TWO when the cursor is sitting on their crossing.
export type GuideLine = {
	anchor: Vector3,
	dir:    Vector3,
	marks:  { Vector3 }?,
}

export type SnapResult = {
	position:          Vector3,
	snapType:          SnapType,
	ghostColor:        Color3,
	indicatorColor:    Color3,
	indicatorHeight:   number,
	indicatorDotScale: number,
	hostFoot:          Vector3?,
	guides:            { GuideLine }?,
	angleDeg:          number?,
	angleRelative:     boolean?,
}

local _segments:            { [number]: SegmentData } = {}
local _segCount:            number                    = 0
local _segBounds:           { [number]: { cx: number, cz: number, r: number } } = {}
local _intersectionCentres: { Vector3 }               = {}
local _buildingFronts:      { BuildingFront }         = {}
local _activeRoadType:      string                    = ""
local _activeRoadSpec:      any                       = nil
local _roadSnapOn:          boolean                   = true
local _laneSnapOn:          boolean                   = true
local _guideSnapOn:         boolean                   = true
local _intersectionSnapOn:  boolean                   = true
local _angleSnapOn:         boolean                   = true
local _angleSnapStart:      Vector3?                  = nil
local _angleSnapRefDir:     Vector3?                  = nil
local _angleFreeOverride:   boolean                   = false
local _cursorSpeed:         number                    = 0
-- The guideline the cursor is currently riding, if any. Declared HERE, with the rest of the
-- module state, because guideStrength() below reads it -- a local declared further down
-- would resolve to a nil global there instead, silently.
local _guideA:              Vector3?                  = nil
local _guideD:              Vector3?                  = nil
-- A snap point whose guidelines (and ring) are suppressed: the node the road being drawn is
-- already anchored to. Its rays would lie on top of the road you are drawing, and its square
-- one duplicates the right-angle magnet, which owns that gesture.
local _guideExclude:        Vector3?                  = nil

type GuideCacheEntry = {
	seg:      SegmentData,
	startDir: Vector3?,
	endDir:   Vector3?,
}
local _guideById: { [number]: GuideCacheEntry } = {}

-- Every direction a road LEAVES a node in, by node position. A guide ray pointing down one
-- of them would be drawn straight along an existing road (at a bend, the ray square to the
-- incoming arm is exactly the outgoing arm) -- so those rays are dropped.
local _nodeDirs: { [string]: { Vector3 } } = {}
local ALONG_ROAD_COS = math.cos(math.rad(20))

local function nodeKey(p: Vector3): string
	return tostring(math.round(p.X)) .. ":" .. tostring(math.round(p.Z))
end

local function addNodeDir(p: Vector3, d: Vector3?)
	if not d then return end
	local k = nodeKey(p)
	local list = _nodeDirs[k]
	if not list then list = {}; _nodeDirs[k] = list end
	list[#list + 1] = d :: Vector3
end

local function rayRunsAlongARoad(node: Vector3, dx: number, dz: number): boolean
	local dirs = _nodeDirs[nodeKey(node)]
	if not dirs then return false end
	for _, d in dirs do
		if d.X * dx + d.Z * dz > ALONG_ROAD_COS then return true end
	end
	return false
end

-- Spatial grid over segment bounding boxes so per-frame snapping visits only segments
-- near the cursor instead of the whole network. Rebuilt with the segment set; a long
-- segment registers in every cell its bbox spans.
local GRID_CELL = 64
local _segGrid: { [string]: { number } } = {}
local _maxRoadCapture = 0
local _queryToken = 0
local _segSeen: { [number]: number } = {}
local _candBuf: { number } = {}

local function gridCellKey(cxi: number, czi: number): string
	return tostring(cxi) .. ":" .. tostring(czi)
end

-- Segment ids whose bbox lies within `radius` of (x,z). Returns a SHARED buffer -- consume
-- it before the next call. This is a SUPERSET of the precise bound test each caller already
-- runs, so snap results are identical; only the candidate count drops.
local function nearbySegmentIds(x: number, z: number, radius: number): { number }
	_queryToken += 1
	table.clear(_candBuf)
	local c0x = math.floor((x - radius) / GRID_CELL)
	local c1x = math.floor((x + radius) / GRID_CELL)
	local c0z = math.floor((z - radius) / GRID_CELL)
	local c1z = math.floor((z + radius) / GRID_CELL)
	for cxi = c0x, c1x do
		for czi = c0z, c1z do
			local bucket = _segGrid[gridCellKey(cxi, czi)]
			if bucket then
				for _, id in bucket do
					if _segSeen[id] ~= _queryToken then
						_segSeen[id] = _queryToken
						_candBuf[#_candBuf + 1] = id
					end
				end
			end
		end
	end
	return _candBuf
end

local SnapUtil = {}

SnapUtil.Constants = SnapConstants

local function distFlatXZ(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Full footprint half-width of a road type: carriageway plus its sidewalks. This is the
-- extent a road actually occupies, and what both the capture radius and the building
-- setback are measured against.
local function footHalf(spec: any): number
	return RoadTypeCatalog.footprintHalf(spec)
end

function SnapUtil.setSegments(segmentById: { [number]: SegmentData })
	_segments = segmentById
	_segCount = 0
	table.clear(_segBounds)
	table.clear(_guideById)
	table.clear(_nodeDirs)
	table.clear(_segGrid)
	_maxRoadCapture = 0
	for id, seg in segmentById do
		_segCount += 1

		local cx = (seg.p0.X + seg.p1.X + seg.p2.X + seg.p3.X) * 0.25
		local cz = (seg.p0.Z + seg.p1.Z + seg.p2.Z + seg.p3.Z) * 0.25
		local r = 0
		for _, p in { seg.p0, seg.p1, seg.p2, seg.p3 } do
			local dx, dz = p.X - cx, p.Z - cz
			local d = math.sqrt(dx * dx + dz * dz)
			if d > r then r = d end
		end
		_segBounds[id] = { cx = cx, cz = cz, r = r }

		local function buildTangent(t: number): Vector3?
			local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local flat = Vector3.new(tan.X, 0, tan.Z)
			if flat.Magnitude < 1e-3 then
				flat = Vector3.new(seg.p3.X - seg.p0.X, 0, seg.p3.Z - seg.p0.Z)
			end
			if flat.Magnitude < 1e-3 then return nil end
			return flat.Unit
		end
		local startDir, endDir = buildTangent(0), buildTangent(1)
		_guideById[id] = { seg = seg, startDir = startDir, endDir = endDir }
		-- The road leaves p0 along +startDir and leaves p3 along -endDir.
		addNodeDir(seg.p0, startDir)
		addNodeDir(seg.p3, if endDir then -endDir else nil)

		local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
		local cap = footHalf(spec) + SnapConstants.SNAP_SIDE_MARGIN
		if cap > _maxRoadCapture then _maxRoadCapture = cap end
		local gc0x = math.floor((cx - r) / GRID_CELL)
		local gc1x = math.floor((cx + r) / GRID_CELL)
		local gc0z = math.floor((cz - r) / GRID_CELL)
		local gc1z = math.floor((cz + r) / GRID_CELL)
		for cxi = gc0x, gc1x do
			for czi = gc0z, gc1z do
				local key = gridCellKey(cxi, czi)
				local bucket = _segGrid[key]
				if not bucket then bucket = {}; _segGrid[key] = bucket end
				bucket[#bucket + 1] = id
			end
		end
	end
end

function SnapUtil.setIntersectionCentres(centres: { Vector3 })
	_intersectionCentres = centres
end

-- Road-access sides of the placed buildings near the player, refreshed by the client's
-- topology mirror. Empty is normal (no buildings, or nothing nearby) and simply skips
-- that snap tier.
function SnapUtil.setBuildingFronts(fronts: { BuildingFront })
	_buildingFronts = fronts
end

function SnapUtil.setActiveRoadType(id: string)
	_activeRoadType = id or ""
	_activeRoadSpec = RoadTypeCatalog.getOrDefault(_activeRoadType)
end
function SnapUtil.getActiveRoadType(): string return _activeRoadType end

function SnapUtil.setRoadSnapEnabled(on: boolean) _roadSnapOn = on end
function SnapUtil.isRoadSnapEnabled(): boolean return _roadSnapOn end

function SnapUtil.setLaneSnapEnabled(on: boolean) _laneSnapOn = on end
function SnapUtil.isLaneSnapEnabled(): boolean return _laneSnapOn end

function SnapUtil.setGuideEnabled(on: boolean) _guideSnapOn = on end
function SnapUtil.isGuideEnabled(): boolean return _guideSnapOn end

function SnapUtil.setIntersectionSnapEnabled(on: boolean) _intersectionSnapOn = on end
function SnapUtil.isIntersectionSnapEnabled(): boolean return _intersectionSnapOn end

function SnapUtil.setAngleSnapEnabled(on: boolean) _angleSnapOn = on end
function SnapUtil.isAngleSnapEnabled(): boolean return _angleSnapOn end

-- While true (Alt held) the angle magnet is bypassed for a fully free placement.
function SnapUtil.setAngleFreeOverride(on: boolean) _angleFreeOverride = on end
function SnapUtil.isAngleFreeOverride(): boolean return _angleFreeOverride end

-- Ground speed of the cursor in studs/second, fed by the tool that owns the frame loop.
-- Guides are for placing, not for panning: they hide while the cursor is being thrown
-- across the map and come back when it settles.
function SnapUtil.setCursorSpeed(studsPerSecond: number)
	_cursorSpeed = studsPerSecond
end

-- The node the in-progress road is anchored to, or nil when no draw is active.
function SnapUtil.setGuideExclusion(p: Vector3?)
	_guideExclude = p
end

local function isExcluded(p: Vector3): boolean
	local ex = _guideExclude
	if not ex then return false end
	local dx, dz = p.X - ex.X, p.Z - ex.Z
	local r = RoadConstants.NODE_WELD_RADIUS
	return dx * dx + dz * dz <= r * r
end

function SnapUtil.hasRoads(): boolean
	return _segCount > 0
end

-- Where a road of N lanes snaps across a road of H lanes (user, 2026-10-06 -- one table for every
-- road, on its body, at a joint and at a dead end; lane directions do not matter, a wrong-way pick
-- snaps back into an intersection on the server): "F" flush with either side -- its outer lane on
-- the other's outer lane, whichever is wider -- and "C" centred. A road with parking: both. Past
-- five lanes, as five; the same count: centred.
local SNAP_SPOTS = table.freeze({
	table.freeze({ "C", "C", "C", "F", "F" }),
	table.freeze({ "FC", "C", "C", "FC", "FC" }),
	table.freeze({ "F", "C", "C", "F", "F" }),
	table.freeze({ "F", "F", "F", "C", "FC" }),
	table.freeze({ "FC", "FC", "FC", "FC", "C" }),
})

-- The places across a road (`profile`, looked at from its end when `flip`) where the middle of a
-- road of profile `drawn` goes (SNAP_SPOTS); the one nearest the cursor is taken.
function SnapUtil.spotsAcross(profile: any, drawn: any?, flip: boolean?): { number }
	-- the first and last lanes' middles of a section, its lane count, and whether it parks
	local function span(sec: any): (number, number, number, boolean)
		local n, c0, c1, parked = 0, 0, 0, false
		for _, b in sec.bands do
			if b.k == "lane" then
				n += 1
				c1 = (b.x0 + b.x1) * 0.5
				if n == 1 then c0 = c1 end
			elseif b.k == "park" and b.x1 - b.x0 > 1e-3 then
				parked = true
			end
		end
		return n, c0, c1, parked
	end
	local side = RoadRules.getLaneSideSign()
	local h, hc0, hc1, parked = span(RoadSection.of(profile, flip == true, side))
	if h == 0 then return {} end
	local n, dc0, dc1 = 0, 0, 0
	if drawn then
		n, dc0, dc1 = span(RoadSection.of(drawn, false, side))
	end
	if n == 0 then n = 1 end -- nothing being drawn: as one lane
	local kind = if parked then "FC" elseif n == h then "C" else SNAP_SPOTS[math.min(h, 5)][math.min(n, 5)]
	local out: { number } = {}
	-- centred: the middles of the two roads' lanes together; flush: outer lane on outer lane
	if string.find(kind, "C", 1, true) then table.insert(out, (hc0 + hc1 - dc0 - dc1) * 0.5) end
	if string.find(kind, "F", 1, true) then
		table.insert(out, hc0 - dc0)
		table.insert(out, hc1 - dc1)
	end
	return out
end
local function laneSpots(profile: any, flip: boolean?): { number }
	return SnapUtil.spotsAcross(profile, _activeRoadSpec and _activeRoadSpec.profile, flip)
end

-- A road upgraded to `roadType` lands across the old one where the snap table puts it, the spot
-- nearest `cursor`: flush with either side or centred (user, 2026-10-07 -- it was always
-- centred). A copy of `seg` laid there: its ends carry the offset as lane offsets from their
-- nodes (startLane / endLane), so every road it meets stays joined. The server and the preview
-- both use this.
function SnapUtil.upgradeLanding(seg: SegmentData, roadType: string, cursor: Vector3): SegmentData
	local out = table.clone(seg)
	out.roadType = roadType
	local old, new = RoadTypeCatalog.getOrDefault(seg.roadType), RoadTypeCatalog.getOrDefault(roadType)
	if not old.profile or not new.profile or seg.isRoundabout then return out end
	local q0 = if seg.startLane then seg.p0 + seg.startLane else seg.p0
	local q3 = if seg.endLane then seg.p3 + seg.endLane else seg.p3
	local function rightAt(t: number): Vector3?
		local d = BezierUtil.tangent(q0, seg.p1, seg.p2, q3, t)
		local flat = Vector3.new(d.X, 0, d.Z)
		return if flat.Magnitude > 1e-4 then Vector3.new(-flat.Z, 0, flat.X).Unit else nil
	end
	local t = BezierUtil.closestParam(q0, seg.p1, seg.p2, q3, cursor, RoadConstants.SNAP_SEGMENT_SAMPLES)
	local r, r0, r3 = rightAt(t), rightAt(0), rightAt(1)
	if not r or not r0 or not r3 then return out end
	local lat = (cursor - BezierUtil.point(q0, seg.p1, seg.p2, q3, t)):Dot(r)
	local x, bestD = 0, math.huge
	for _, sx in SnapUtil.spotsAcross(old.profile, new.profile) do
		if math.abs(lat - sx) < bestD then x, bestD = sx, math.abs(lat - sx) end
	end
	if math.abs(x) < 0.05 then return out end
	local function lane(v: Vector3?, by: Vector3): Vector3?
		local w = (v or Vector3.zero) + by
		return if w.Magnitude > 0.05 then w else nil
	end
	out.startLane, out.endLane = lane(seg.startLane, r0 * x), lane(seg.endLane, r3 * x)
	out.p1, out.p2 = seg.p1 + r0 * x, seg.p2 + r3 * x
	return out
end

-- Every snap point ON a road near the cursor: both end nodes, plus one every
-- GUIDE_MARK_SPACING in between. Endpoints alone are not enough -- a long segment (anything
-- drawn before the auto-split, or a straight run) has its two nodes hundreds of studs apart,
-- and a guide system hanging off nodes only gives the player nothing to aim at along it.
-- These are the points the RINGS mark and the points the guide rays leave from: one list,
-- so a ring is always a promise the guides actually keep.
-- Calls fn(point, unitTangent) for each.
local ROAD_POINT_SAMPLES = 12
local function forEachRoadPoint(cursor: Vector3, radius: number, fn: (Vector3, Vector3, SegmentData, number) -> ())
	local spacing = SnapConstants.GUIDE_MARK_SPACING
	local vTol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local r2 = radius * radius
	for _, id in nearbySegmentIds(cursor.X, cursor.Z, radius) do
		local seg = _segments[id]
		-- A roundabout ring is eight arcs whose ends are tessellation points, not junctions.
		if not seg or seg.isRoundabout then continue end
		local total = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, ROAD_POINT_SAMPLES)
		-- ponytail: stepped evenly in t, not in arc length. Exact on a straight, which is
		-- what the auto-split produces, and close enough to place a marker on a bend.
		local steps = math.max(1, math.round(total / spacing))
		for i = 0, steps do
			local t = i / steps
			local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
			if math.abs(cursor.Y - p.Y) > vTol then continue end
			local dx, dz = cursor.X - p.X, cursor.Z - p.Z
			if dx * dx + dz * dz > r2 then continue end
			local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local flat = Vector3.new(tan.X, 0, tan.Z)
			if flat.Magnitude < 1e-3 then continue end
			fn(p, flat.Unit, seg, t)
		end
	end
end

-- How much the guide system is "on" right now, 0..1, straight off cursor speed. ONE number
-- drives both how hard a guide pulls and how visible its rings are, so the pull can never
-- outlive the thing that explains it.
function SnapUtil.guideStrength(): number
	local maxSpeed = SnapConstants.GUIDE_MAX_CURSOR_SPEED
	-- A guide that already has the cursor tolerates a faster one. Acquiring should take
	-- intent; keeping it should not, or riding a guide means creeping along it.
	if _guideA then maxSpeed *= SnapConstants.GUIDE_HELD_SPEED_MULT end
	return math.clamp(1 - _cursorSpeed / maxSpeed, 0, 1)
end

-- How visible the rings are, 0..1. Its own, much higher speed limit: seeing where the snap
-- points ARE is how the player finds one, and that should survive a cursor moving far too
-- fast to be snapped. Always >= guideStrength, so a pull can never happen without a ring.
function SnapUtil.ringStrength(): number
	return math.clamp(1 - _cursorSpeed / SnapConstants.ROAD_RING_MAX_CURSOR_SPEED, 0, 1)
end

-- Road nodes near the cursor, for the rings drawn ON the road. Returns a SHARED buffer --
-- consume it before the next call. Empty while the cursor is moving fast, which is what
-- makes the rings fade out with everything else.
local _ringBuf: { Vector3 } = {}
local _ringSeen: { [string]: boolean } = {}
function SnapUtil.nodeRings(cursor: Vector3): { Vector3 }
	-- Deliberately NOT gated on ringStrength. Hiding the rings is the ALPHA's job, and it does
	-- it as a tween; culling the list as well just means they blink out and back every time a
	-- flick of the mouse crosses the speed limit.
	table.clear(_ringBuf)
	table.clear(_ringSeen)
	-- The SAME reach the rays use, so every point that can pull gets a ring and no ring is
	-- drawn over a point that cannot.
	local r = SnapConstants.GUIDE_SOURCE_RADIUS
	local maxN = SnapConstants.ROAD_RING_MAX * (if _laneSnapOn then 4 else 1)
	local vTol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local function add(p: Vector3)
		if #_ringBuf >= maxN then return end
		-- No ray comes off this one, so no ring either: a ring is a promise of a snap.
		if isExcluded(p) then return end
		if math.abs(cursor.Y - p.Y) > vTol then return end
		local dx, dz = cursor.X - p.X, cursor.Z - p.Z
		if dx * dx + dz * dz > r * r then return end
		local k = nodeKey(p)
		if _ringSeen[k] then return end
		_ringSeen[k] = true
		if _laneSnapOn then
			for _, q in _ringBuf do -- the two pieces at a joint put a lane in nearly one place
				if distFlatXZ(p, q) < 1.5 then return end
			end
		end
		_ringBuf[#_ringBuf + 1] = p
	end
	forEachRoadPoint(cursor, r, function(p: Vector3, tan: Vector3, seg: SegmentData, t: number)
		if not _laneSnapOn then
			add(p)
			return
		end
		-- No lane rings on a fork or a junction (nothing snaps to its lanes), nor for a ramp's own
		-- end laid off a lane: the host's ring is already there, and the ramp only leaves the road
		-- further on (user, 2026-10-06: "way too many snap points").
		if t <= 0 or t >= 1 then
			local node = if t <= 0 then seg.p0 else seg.p3
			if #(_nodeDirs[nodeKey(node)] or {}) >= 3 then return end
			if (if t <= 0 then seg.startLane else seg.endLane) then return end
		end
		-- Lane Snap: the ring becomes one small ring on every lane (user, 2026-10-06); tryLane
		-- sticks to them.
		local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
		if not spec.profile then return end
		local right = Vector3.new(-tan.Z, 0, tan.X)
		for _, x in laneSpots(spec.profile) do add(p + right * x) end
	end)
	return _ringBuf
end

-- ------------------------------------------------------------------- tiers --

local function freeResult(rawCursor: Vector3): SnapResult
	return {
		position          = rawCursor,
		snapType          = "none",
		ghostColor        = SnapConstants.GHOST_COLOR_VALID,
		indicatorColor    = SnapConstants.INDICATOR_COLOR,
		indicatorHeight   = 0.12,
		indicatorDotScale = 1,
	}
end

local function snappedResult(pos: Vector3, kind: SnapType, color: Color3): SnapResult
	return {
		position          = pos,
		snapType          = kind,
		ghostColor        = SnapConstants.GHOST_COLOR_SNAP,
		indicatorColor    = color,
		indicatorHeight   = SnapConstants.INDICATOR_SNAP_HEIGHT,
		indicatorDotScale = SnapConstants.INDICATOR_SNAP_DOT_SCALE,
	}
end

-- Snap exactly onto the nearest road endpoint so a new road welds to it and lines up.
local function tryNode(rawCursor: Vector3): SnapResult?
	local radius = SnapConstants.SNAP_HOLD
	local vTol   = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	local best: Vector3? = nil
	local bestd = radius
	for _, id in nearbySegmentIds(rawCursor.X, rawCursor.Z, radius) do
		local seg = _segments[id]
		if not seg then continue end
		-- A roundabout ring is 8 octant arcs whose p0/p3 are tessellation nodes, not real
		-- junctions. Snapping to them locks every entry to a 45deg position; fall through
		-- to tryRoad so the entry lands on the true point on the ring.
		if seg.isRoundabout then continue end
		local b = _segBounds[id]
		if b then
			local dx, dz = rawCursor.X - b.cx, rawCursor.Z - b.cz
			if math.sqrt(dx * dx + dz * dz) - b.r > radius then continue end
		end
		for _, p in { seg.p0, seg.p3 } do
			if math.abs(rawCursor.Y - p.Y) > vTol then continue end
			local d = distFlatXZ(rawCursor, p)
			if d < bestd then
				bestd = d
				best = p
			end
		end
	end
	if not best then return nil end
	-- Weld at the host node's exact height so the join follows a sloped/elevated road
	-- instead of snapping in X/Z only and floating at the cursor's terrain height.
	local r = snappedResult(best :: Vector3, "center", SnapConstants.INDICATOR_SNAP_COLOR)
	r.hostFoot = r.position
	return r
end

-- Lane snapping at a DEAD END: a road carrying on from it lands flush with either side or centred
-- (laneSpots), the point nearest the cursor; the middle is the plain weld.
-- The server joins it at the end node, drawn from here (RoadService laneJoin): the wider road
-- then narrows on one side only. nil = centred (the plain node weld).
local function tryEndLane(seg: SegmentData, atEnd: boolean, rawCursor: Vector3): SnapResult?
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	if not spec.profile then return nil end
	local node = if atEnd then seg.p3 else seg.p0
	local tan = if atEnd then BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 1)
		else -BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 0)
	local ahead = Vector3.new(tan.X, 0, tan.Z)
	if ahead.Magnitude < 1e-4 then return nil end
	ahead = ahead.Unit -- the way a road carrying on from this end runs
	local right = Vector3.new(-ahead.Z, 0, ahead.X)
	local spots = laneSpots(spec.profile, not atEnd) -- looking out of the end
	local lat = Vector3.new(rawCursor.X - node.X, 0, rawCursor.Z - node.Z):Dot(right)
	local best, bestD = 0, math.huge
	for _, x in spots do
		if math.abs(lat - x) < bestD then best, bestD = x, math.abs(lat - x) end
	end
	if math.abs(best) < 0.5 then return nil end -- the middle: the plain weld
	local r = snappedResult(node + right * best, "lane", SnapConstants.INDICATOR_SNAP_COLOR)
	r.hostFoot = node
	return r
end

-- Lane snapping ON a joint (two roads meeting): the middle of every lane either road has at the
-- node, whichever is nearest the cursor -- so a second ramp, or the other half of a Y off a dead
-- end that already has one road on it, leaves from a lane of the joint itself, whichever road the
-- cursor happens to be over (user, 2026-10-06: drawing those was "really hard" and buggy).
-- `within`: only a lane point that close to the cursor (studs).
local function tryNodeLanes(node: Vector3, rawCursor: Vector3, within: number?): SnapResult?
	local best: Vector3?, bestD = nil, math.huge
	for _, id in nearbySegmentIds(node.X, node.Z, 1) do
		local seg = _segments[id]
		if not seg then continue end
		local atStart = distFlatXZ(seg.p0, node) < 0.1
		if not atStart and distFlatXZ(seg.p3, node) > 0.1 then continue end
		local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
		if not spec.profile then continue end
		local laid = (if atStart then seg.startLane else seg.endLane) or Vector3.zero
		local q0, q3 = seg.p0 + (seg.startLane or Vector3.zero), seg.p3 + (seg.endLane or Vector3.zero)
		local tan = BezierUtil.tangent(q0, seg.p1, seg.p2, q3, if atStart then 0 else 1)
		local right = Vector3.new(-tan.Z, 0, tan.X)
		if right.Magnitude < 1e-4 then continue end
		right = right.Unit
		for _, x in laneSpots(spec.profile) do
			local p = node + laid + right * x
			local d = distFlatXZ(rawCursor, p)
			if d < bestD then best, bestD = p, d end
		end
	end
	if not best or bestD > (within or math.huge) then return nil end
	local r = snappedResult(best :: Vector3, "lane", SnapConstants.INDICATOR_SNAP_COLOR)
	r.hostFoot = node
	return r
end

-- The dead end at `node`, if one is there: the segment ending at it and which end.
local function deadEndAt(node: Vector3): (SegmentData?, boolean)
	if #(_nodeDirs[nodeKey(node)] or {}) ~= 1 then return nil, false end
	for _, id in nearbySegmentIds(node.X, node.Z, 1) do
		local seg = _segments[id]
		if not seg then continue end
		if distFlatXZ(seg.p3, node) < 0.1 then return seg, true end
		if distFlatXZ(seg.p0, node) < 0.1 then return seg, false end
	end
	return nil, false
end

-- Do the two roads meeting at `node` differ in type (a lane drop, a road changing)?
local function changesType(node: Vector3): boolean
	local first: string? = nil
	for _, id in nearbySegmentIds(node.X, node.Z, 1) do
		local seg = _segments[id]
		if not seg or (distFlatXZ(seg.p0, node) > 0.1 and distFlatXZ(seg.p3, node) > 0.1) then continue end
		if first and seg.roadType ~= first then return true end
		first = seg.roadType
	end
	return false
end

-- Is `p` on a road -- a node, or within reach of a road's middle (where the server welds an end,
-- RoadService projectEndpointToHost)? Such an end leaves level (RoadVerticalProfile.conditionToSurface).
function SnapUtil.isOnRoad(p: Vector3): boolean
	local own = if _activeRoadSpec then (_activeRoadSpec.width or 0) * 0.5 else 0
	local vTol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	for _, id in nearbySegmentIds(p.X, p.Z, _maxRoadCapture) do
		local seg = _segments[id]
		if not seg then continue end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, p, SnapConstants.SNAP_SEGMENT_SAMPLES)
		local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local reach = (RoadTypeCatalog.getOrDefault(seg.roadType).width or 0) * 0.5 + own
		if math.abs(cp.Y - p.Y) <= vTol and distFlatXZ(cp, p) <= reach then return true end
	end
	return false
end

-- A draw started on a road and pulled on past that road's dead end carries on FROM the end
-- (user, 2026-10-06): as if it had been started there. Returns the end -- or, with Lane Snap,
-- the end's lane spot nearest the side the draw started on -- and whether it is a lane spot.
-- nil when the draw does not run off a dead end of the road it started on.
function SnapUtil.carryOnFrom(start: Vector3, toward: Vector3): (Vector3?, boolean)
	local drag = Vector3.new(toward.X - start.X, 0, toward.Z - start.Z)
	if drag.Magnitude < 1 then return nil, false end
	drag = drag.Unit
	for _, id in nearbySegmentIds(start.X, start.Z, _maxRoadCapture) do
		local seg = _segments[id]
		if not seg or seg.isRoundabout then continue end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, start, SnapConstants.SNAP_SEGMENT_SAMPLES)
		if t < 0.01 or t > 0.99 then continue end -- started on the end itself: nothing to carry
		local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if distFlatXZ(start, cp) > footHalf(RoadTypeCatalog.getOrDefault(seg.roadType)) then continue end
		local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local along = Vector3.new(tan.X, 0, tan.Z)
		if along.Magnitude < 1e-4 then continue end
		local cos = drag:Dot(along.Unit)
		if math.abs(cos) < 0.9 then continue end
		local atEnd = cos > 0
		local node = if atEnd then seg.p3 else seg.p0
		local dead, deadAtEnd = deadEndAt(node)
		if dead ~= seg or deadAtEnd ~= atEnd then continue end
		local endTan = if atEnd then BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 1) else -BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 0)
		local out = Vector3.new(endTan.X, 0, endTan.Z)
		if out.Magnitude < 1e-4 then continue end
		out = out.Unit
		if Vector3.new(toward.X - node.X, 0, toward.Z - node.Z):Dot(out) <= 0 then continue end -- not past the end yet
		if _laneSnapOn then
			local right = Vector3.new(-out.Z, 0, out.X)
			local lat = Vector3.new(start.X - cp.X, 0, start.Z - cp.Z):Dot(right)
			local lane = tryEndLane(seg, atEnd, node + right * lat)
			if lane then return lane.position, true end
		end
		return node, false
	end
	return nil, false
end

-- Lane snapping: the middle of the lane under the cursor, on any road with lanes (the
-- outermost lanes reach out over the shoulder, parking and footway). The server joins the road
-- there (RoadService laneJoin) and draws it from that lane.
local function tryLane(seg: SegmentData, t: number, cp: Vector3, rawCursor: Vector3): SnapResult?
	-- Near one of the road's rings (its nodes and 100 m marks, SnapUtil.nodeRings) the lane point
	-- sticks to the ring: a ramp drawn there leaves from the node itself. A node where the road
	-- changes type pulls from half the road's width -- a ramp started just short of a lane drop
	-- leaves from the drop (one fork taking the lane), not from a stub before it.
	local total = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, ROAD_POINT_SAMPLES)
	local steps = math.max(1, math.round(total / SnapConstants.GUIDE_MARK_SPACING))
	local tr = math.round(t * steps) / steps
	local stick = SnapConstants.GUIDE_MARK_RADIUS
	if tr <= 0 or tr >= 1 then
		local dirs = _nodeDirs[nodeKey(if tr <= 0 then seg.p0 else seg.p3)]
		if dirs and #dirs == 2 and changesType(if tr <= 0 then seg.p0 else seg.p3) then
			stick = math.max(stick, footHalf(RoadTypeCatalog.getOrDefault(seg.roadType)))
		end
	end
	if math.abs(t - tr) * total <= stick then
		t = tr
		cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	end
	if t <= 1e-3 or t >= 1 - 1e-3 then
		-- over a dead end's cap: its three points, not a lane of the body
		local deadEnd, atEnd = deadEndAt(if t > 0.5 then seg.p3 else seg.p0)
		if deadEnd then return tryEndLane(deadEnd, atEnd, rawCursor) end
	end
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	if not spec.profile then return nil end
	local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local along = Vector3.new(tan.X, 0, tan.Z)
	if along.Magnitude < 1e-4 then return nil end
	along = along.Unit
	local right = Vector3.new(-along.Z, 0, along.X)
	local lat = (rawCursor - cp):Dot(right)
	-- the spot nearest the cursor where the road being drawn fits on this road's lanes; none,
	-- or only the middle (a road as wide as this one's lanes): the plain centreline
	local x, bestD = nil, math.huge
	for _, sx in laneSpots(spec.profile) do
		if math.abs(lat - sx) < bestD then x, bestD = sx, math.abs(lat - sx) end
	end
	if not x or math.abs(x) < 0.5 then return nil end
	local r = snappedResult(cp + right * x, "lane", SnapConstants.INDICATOR_SNAP_SEG_COLOR)
	r.hostFoot = cp
	return r
end

-- The cursor is over a road: take the centreline. Capture spans the road's own footprint,
-- so this fires exactly when the cursor visually overlaps the road.
local function tryRoad(rawCursor: Vector3): SnapResult?
	local FINE = SnapConstants.SNAP_SEGMENT_SAMPLES
	local margin = SnapConstants.SNAP_SIDE_MARGIN
	local vTol = RoadConstants.VERTICAL_CONNECT_TOLERANCE

	local bestSeg: SegmentData? = nil
	local bestT: number = 0
	local bestPerp: number = math.huge
	for _, id in nearbySegmentIds(rawCursor.X, rawCursor.Z, _maxRoadCapture) do
		local seg = _segments[id]
		if not seg then continue end
		local captureMax = footHalf(RoadTypeCatalog.getOrDefault(seg.roadType)) + margin

		local b = _segBounds[id]
		if b then
			local dx, dz = rawCursor.X - b.cx, rawCursor.Z - b.cz
			if math.sqrt(dx * dx + dz * dz) - b.r > captureMax then continue end
		end
		local t  = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, rawCursor, FINE)
		local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if math.abs(rawCursor.Y - cp.Y) > vTol then continue end
		local perp = distFlatXZ(rawCursor, cp)
		if perp <= captureMax and perp < bestPerp then
			bestPerp = perp
			bestSeg  = seg
			bestT    = t
		end
	end
	if not bestSeg then return nil end

	local seg = bestSeg :: SegmentData
	-- Adopt the host road's height at this point, NOT the cursor's terrain-derived Y: on a
	-- sloped or elevated host the two differ, and keeping the cursor Y leaves the new road
	-- floating above or buried below the join instead of welding to it.
	local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, bestT)
	local lane = if _laneSnapOn then tryLane(seg, bestT, cp, rawCursor) else nil
	if lane then return lane end
	local r = snappedResult(cp, "center", SnapConstants.INDICATOR_SNAP_SEG_COLOR)
	r.hostFoot = cp
	return r
end

local function tryIntersection(rawCursor: Vector3): SnapResult?
	-- A junction is a disc, not a point: snap while the cursor is over it.
	local radius = math.max(SnapConstants.SNAP_HOLD, RoadConstants.INTERSECTION_DISC_RADIUS)
	local bestDist = radius
	local bestPos: Vector3? = nil
	for _, centre in _intersectionCentres do
		if math.abs(rawCursor.Y - centre.Y) > RoadConstants.VERTICAL_CONNECT_TOLERANCE then continue end
		local d = distFlatXZ(rawCursor, centre)
		if d < bestDist then
			bestDist = d
			bestPos  = centre
		end
	end
	if not bestPos then return nil end
	local c = bestPos :: Vector3
	return snappedResult(Vector3.new(c.X, rawCursor.Y, c.Z), "intersection", SnapConstants.INDICATOR_SNAP_INTER_COLOR)
end

-- The frontage line of a nearby building: the line a road has to run down for that
-- building's road-access side to end up against its kerb. Exactly the mirror of
-- snapBuilding, which pulls a building onto a road that is already there.
local function tryBuildingFront(rawCursor: Vector3): SnapResult?
	if #_buildingFronts == 0 then return nil end
	local hold = SnapConstants.SNAP_HOLD
	local roadHalf = footHalf(_activeRoadSpec or RoadTypeCatalog.getOrDefault(_activeRoadType))
	local vTol = RoadConstants.VERTICAL_CONNECT_TOLERANCE

	local bestPerp = hold
	local bestAx, bestAz, bestDx, bestDz, bestProj
	for _, b in _buildingFronts do
		if math.abs(rawCursor.Y - b.pos.Y) > vTol then continue end
		local off = b.halfDepth + SnapConstants.BUILDING_SETBACK + roadHalf
		local ax, az = b.pos.X + b.dir.X * off, b.pos.Z + b.dir.Z * off
		local dx, dz = -b.dir.Z, b.dir.X
		local wx, wz = rawCursor.X - ax, rawCursor.Z - az
		local proj = wx * dx + wz * dz
		-- Only in front of the building it belongs to, plus a little overrun.
		if math.abs(proj) > b.halfWidth + hold * 2 then continue end
		local perp = math.abs(wx * b.dir.X + wz * b.dir.Z)
		if perp < bestPerp then
			bestPerp = perp
			bestAx, bestAz, bestDx, bestDz, bestProj = ax, az, dx, dz, proj
		end
	end
	if not bestAx then return nil end

	local r = snappedResult(
		Vector3.new(bestAx + bestDx * bestProj, rawCursor.Y, bestAz + bestDz * bestProj),
		"building", SnapConstants.INDICATOR_SNAP_GUIDE_COLOR)
	-- Drawn centred on the frontage rather than running off one end of it.
	local back = SnapConstants.GUIDE_LENGTH * 0.5
	r.guides = { {
		anchor = Vector3.new(bestAx - bestDx * back, rawCursor.Y, bestAz - bestDz * back),
		dir    = Vector3.new(bestDx, 0, bestDz),
	} }
	return r
end

-- ------------------------------------------------------------- guidelines --

-- ONE live guideline at a time. Candidate rays are scored on perpendicular distance and
-- the closest inside SNAP_HOLD wins:
--   * the ray the cursor is already on, so sliding down a guide does not lose it
--   * the four rays off every road node within GUIDE_SOURCE_RADIUS -- along the road both
--     ways, and square to it both ways
--   * the two square branches off the 100 m mark the cursor is nearest on the LIVE ray.
--     That is the chain: step sideways at a mark and the guide turns the corner with you;
--     hold straight through it and the next mark appears ahead.
-- Nothing scores -> the guide is dropped, which is what keeps the screen to one line
-- instead of the whole fan.
local _candA: { Vector3 } = {}
local _candD: { Vector3 } = {}

local function pushRay(a: Vector3, dx: number, dz: number)
	local n = #_candA + 1
	_candA[n] = a
	_candD[n] = Vector3.new(dx, 0, dz)
end

-- SQUARE to the road only -- left and right. Not forward and back: a road drawn straight
-- on off its own end is what the 90deg angle magnet is for (0deg relative = dead straight),
-- and having a guide there too just fought the magnet for the same gesture.
local function pushNodeRays(node: Vector3, d: Vector3)
	if isExcluded(node) then return end
	if not rayRunsAlongARoad(node, -d.Z, d.X) then pushRay(node, -d.Z,  d.X) end
	if not rayRunsAlongARoad(node,  d.Z, -d.X) then pushRay(node,  d.Z, -d.X) end
end

-- The ring window for a ray: GUIDE_MARK_COUNT rings around where the cursor sits on it,
-- two behind and one ahead, so there is always somewhere to aim next without papering the
-- map in rings. Near the anchor the window starts at ring 0, which sits ON the node.
local function markWindow(a: Vector3, d: Vector3, proj: number, y: number): { Vector3 }
	local mark = SnapConstants.GUIDE_MARK_SPACING
	-- Never past the end of the drawn line. A ring out beyond the last dot is a snap the
	-- player can feel with nothing on screen to explain it.
	local kMax = math.floor(SnapConstants.GUIDE_LENGTH / mark)
	local out: { Vector3 } = {}
	local k0 = math.max(0, math.floor(proj / mark) - 2)
	for i = 1, SnapConstants.GUIDE_MARK_COUNT do
		local k = k0 + i - 1
		if k > kMax then break end
		out[#out + 1] = Vector3.new(a.X + d.X * k * mark, y, a.Z + d.Z * k * mark)
	end
	return out
end

local function tryGuide(rawCursor: Vector3): SnapResult?
	-- The faster the cursor, the weaker the pull -- to nothing at GUIDE_MAX_CURSOR_SPEED.
	-- A guide must never grab a cursor being flung past it, and the pull has to die with
	-- the visuals: an invisible guide that still snaps is the worst of both. Same 0..1
	-- strength the rings fade on.
	local hold = SnapConstants.GUIDE_HOLD * SnapUtil.guideStrength()
	-- The other half of the hysteresis: a held guide pulls further as well as surviving a
	-- faster cursor. This is about how far the LINE reaches; the per-ray bonus below is a
	-- different job -- preferring the ray you are on over one that merely crosses it.
	if _guideA then hold *= SnapConstants.GUIDE_HELD_PULL_MULT end
	if hold < 1 then
		_guideA, _guideD = nil, nil
		return nil
	end
	local reach = SnapConstants.GUIDE_LENGTH
	local mark = SnapConstants.GUIDE_MARK_SPACING
	local srcR = SnapConstants.GUIDE_SOURCE_RADIUS
	local vTol = RoadConstants.VERTICAL_CONNECT_TOLERANCE

	table.clear(_candA)
	table.clear(_candD)

	local live = _guideA
	local liveD = _guideD
	if live and liveD then
		local a, d = live :: Vector3, liveD :: Vector3
		pushRay(a, d.X, d.Z)
		local proj = (rawCursor.X - a.X) * d.X + (rawCursor.Z - a.Z) * d.Z
		local k = math.max(1, math.round(proj / mark))
		local m = Vector3.new(a.X + d.X * k * mark, a.Y, a.Z + d.Z * k * mark)
		pushRay(m, -d.Z,  d.X)
		pushRay(m,  d.Z, -d.X)
	end

	forEachRoadPoint(rawCursor, srcR, pushNodeRays)

	local bestI, bestScore = 0, hold
	for i = 1, #_candA do
		local a, d = _candA[i], _candD[i]
		local wx, wz = rawCursor.X - a.X, rawCursor.Z - a.Z
		local proj = wx * d.X + wz * d.Z
		-- Behind the anchor, on top of it, or past the end of the line that gets drawn.
		if proj < hold or proj > reach then continue end
		local score = math.abs(wx * -d.Z + wz * d.X)
		-- The live ray gets a small edge so sliding along it does not flicker onto a
		-- neighbouring ray every time the two cross.
		if live and i <= 3 then score -= hold * 0.2 end
		if score < bestScore then
			bestScore = score
			bestI = i
		end
	end
	if bestI == 0 then
		_guideA, _guideD = nil, nil
		return nil
	end

	local a, d = _candA[bestI], _candD[bestI]
	_guideA, _guideD = a, d

	local proj = (rawCursor.X - a.X) * d.X + (rawCursor.Z - a.Z) * d.Z

	-- A second ray that also holds and CROSSES this one right under the cursor: show both
	-- and put the cursor on the crossing. Two lines meeting is a PLACE; one line is only a
	-- direction. Near-parallel rays are not a crossing, they are the same guide twice.
	local second: GuideLine? = nil
	local crossI, crossScore = 0, hold
	for i = 1, #_candA do
		if i == bestI then continue end
		local a2, d2 = _candA[i], _candD[i]
		if math.abs(d2.X * d.X + d2.Z * d.Z) > 0.5 then continue end
		local wx, wz = rawCursor.X - a2.X, rawCursor.Z - a2.Z
		if wx * d2.X + wz * d2.Z < hold then continue end
		local s = math.abs(wx * -d2.Z + wz * d2.X)
		if s < crossScore then
			crossScore = s
			crossI = i
		end
	end
	if crossI ~= 0 then
		local a2, d2 = _candA[crossI], _candD[crossI]
		local denom = d.X * d2.Z - d.Z * d2.X
		if math.abs(denom) > 1e-6 then
			local t = ((a2.X - a.X) * d2.Z - (a2.Z - a.Z) * d2.X) / denom
			if math.abs(t - proj) <= hold then
				proj = t
				local px, pz = a.X + d.X * t, a.Z + d.Z * t
				local u = (px - a2.X) * d2.X + (pz - a2.Z) * d2.Z
				second = { anchor = Vector3.new(a2.X, rawCursor.Y, a2.Z), dir = d2, marks = markWindow(a2, d2, u, rawCursor.Y) }
			end
		end
	end

	-- No crossing to land on, so land ON a ring instead when the cursor is close to one:
	-- that click is what makes a 50 m step, and a branch, feel like a decision not a drag.
	if not second then
		local kNear = math.round(proj / mark)
		if kNear >= 1 and math.abs(proj - kNear * mark) <= hold then
			proj = kNear * mark
		end
	end

	local r = snappedResult(
		Vector3.new(a.X + d.X * proj, rawCursor.Y, a.Z + d.Z * proj),
		"guide", SnapConstants.INDICATOR_SNAP_GUIDE_COLOR)
	r.guides = { { anchor = Vector3.new(a.X, rawCursor.Y, a.Z), dir = d, marks = markWindow(a, d, proj, rawCursor.Y) } }
	if second then
		(r.guides :: { GuideLine })[2] = second
	end
	return r
end

-- ------------------------------------------------------------------ angle --

-- Free heading with a magnet on the right angles only: inside ANGLE_SNAP_TOL of a multiple
-- of 90deg the heading locks onto it, and everywhere else the cursor is obeyed exactly.
-- NOT a tier of resolve(): it needs the gesture's start point, and a locked right-angle turn
-- has to beat a guideline rather than queue behind it. The draw tool asks for it directly,
-- through SnapUtil.angleSnap below, and falls back to resolve()'s answer when it declines.
local function tryAngle(rawCursor: Vector3): SnapResult?
	if not _angleSnapStart or _angleFreeOverride then return nil end
	local s = _angleSnapStart :: Vector3
	local dx, dz = rawCursor.X - s.X, rawCursor.Z - s.Z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist < SnapConstants.ANGLE_SNAP_DEADZONE then return nil end

	local refAng = 0
	local relative = false
	if _angleSnapRefDir then
		local ref = _angleSnapRefDir :: Vector3
		if ref.X * ref.X + ref.Z * ref.Z > 1e-8 then
			refAng = math.atan2(ref.Z, ref.X)
			relative = true
		end
	end

	local step = SnapConstants.ANGLE_SNAP_STEP
	local rel = math.atan2(dz, dx) - refAng
	local snappedRel = math.round(rel / step) * step
	-- Signed shortest difference, in (-pi, pi].
	local diff = (rel - snappedRel + math.pi) % (2 * math.pi) - math.pi
	if math.abs(diff) > SnapConstants.ANGLE_SNAP_TOL then return nil end

	local finalAng = refAng + snappedRel
	local r = snappedResult(
		Vector3.new(s.X + math.cos(finalAng) * dist, rawCursor.Y, s.Z + math.sin(finalAng) * dist),
		"angle", SnapConstants.INDICATOR_SNAP_COLOR)
	r.ghostColor = SnapConstants.GHOST_COLOR_VALID

	-- Angle shown to the player: the turn off the host road when relative, else the
	-- absolute bearing. Normalised to (-180, 180].
	local shown = if relative then snappedRel else finalAng
	shown = (shown + math.pi) % (2 * math.pi) - math.pi
	r.angleDeg = math.deg(shown)
	r.angleRelative = relative
	return r
end

-- While a road is being drawn the grid snaps its LENGTH, not the world point: measured
-- from the draw's anchor (_guideExclude) along the cursor's own heading, so swinging the
-- road round sweeps a clean 10 / 20 / 30 m. A world lattice seen from its corner is
-- 36 m, 38 m, 41 m... -- the length hopped about as the road turned. Picking the START is
-- the world lattice itself, so axis-aligned roads still end on grid points.
local function tryGrid(rawCursor: Vector3): SnapResult
	local g = PlacementGrid.step()
	local s = _guideExclude
	if s then
		local dx, dz = rawCursor.X - s.X, rawCursor.Z - s.Z
		local d = math.sqrt(dx * dx + dz * dz)
		if d > 1e-3 then
			local k = math.max(1, math.round(d / g)) * g / d
			return snappedResult(Vector3.new(s.X + dx * k, rawCursor.Y, s.Z + dz * k),
				"grid", SnapConstants.INDICATOR_SNAP_GRID_COLOR)
		end
	end
	return snappedResult(
		Vector3.new(math.round(rawCursor.X / g) * g, rawCursor.Y, math.round(rawCursor.Z / g) * g),
		"grid", SnapConstants.INDICATOR_SNAP_GRID_COLOR)
end

-- ---------------------------------------------------------------- resolve --

function SnapUtil.resolve(rawCursor: Vector3): SnapResult
	-- The first road on an empty map is drawn completely free: no geometry to snap to, so
	-- no guides and no angle magnet either. Nothing to line up with yet.
	if _segCount == 0 then
		_guideA, _guideD = nil, nil
		-- The grid is the player's setting, not something on the map, so it holds here too.
		if PlacementGrid.isEnabled() and not _angleFreeOverride then return tryGrid(rawCursor) end
		return freeResult(rawCursor)
	end

	if _roadSnapOn then
		local rn = tryNode(rawCursor)
		-- a joint (two roads meeting) gives way to its lanes -- the ring on one right under the
		-- cursor, else the lane under the cursor, else the joint's nearest lane, never its middle;
		-- a dead end to the spots where the new road's lanes line up with its own
		if rn and _laneSnapOn and #(_nodeDirs[nodeKey(rn.position)] or {}) == 2 then
			local rl = tryNodeLanes(rn.position, rawCursor, SnapConstants.GUIDE_MARK_RADIUS)
			if rl then return rl end
			rl = tryRoad(rawCursor)
			if rl and rl.snapType == "lane" then return rl end
			rl = tryNodeLanes(rn.position, rawCursor)
			if rl then return rl end
		elseif rn and _laneSnapOn then
			local deadEnd, atEnd = deadEndAt(rn.position)
			local re = if deadEnd then tryEndLane(deadEnd, atEnd, rawCursor) else nil
			if re then return re end
		end
		if rn then return rn end
		local r = tryRoad(rawCursor)
		if r then return r end
		-- Junction snap is a road snap: there is no separate UI toggle for it, so it must
		-- die with the Road Snap toggle instead of surviving it.
		if _intersectionSnapOn then
			local ri = tryIntersection(rawCursor)
			if ri then return ri end
		end
		local rb = tryBuildingFront(rawCursor)
		if rb then return rb end
	end
	if _guideSnapOn then
		local r = tryGuide(rawCursor)
		if r then return r end
	end
	-- Alt frees the length along with the angle, grid included.
	if PlacementGrid.isEnabled() and not _angleFreeOverride then
		return tryGrid(rawCursor)
	end
	return freeResult(rawCursor)
end

-- The right-angle magnet for an in-progress draw. `refDir` is the direction a road would
-- continue straight off the existing road at `start`, so 0deg is a dead-straight
-- continuation and +/-90deg a square T. Returns nil when the heading is not near a right
-- angle, which is most of the time -- that is the point.
function SnapUtil.angleSnap(start: Vector3, refDir: Vector3?, rawCursor: Vector3): SnapResult?
	if not _angleSnapOn then return nil end
	-- Only when EXTENDING a road (user rule): a road started on open ground -- no refDir,
	-- empty map or not -- has nothing to be square to, so it is drawn at any angle. The
	-- world axes used to stand in as the reference, which read as the tool fighting you.
	if not refDir then return nil end
	_angleSnapStart, _angleSnapRefDir = start, refDir
	local r = tryAngle(rawCursor)
	_angleSnapStart, _angleSnapRefDir = nil, nil
	return r
end

function SnapUtil.resolvePosition(rawCursor: Vector3): Vector3
	return SnapUtil.resolve(rawCursor).position
end

-- --------------------------------------------------------------- buildings --

-- THE building snap, used by every building tool. A building may always be placed with no
-- road at all; when one of its sides is within BUILDING_SNAP_DIST of clear ground of a
-- road, it is pulled square onto that road instead. Returns the pivot position and the yaw
-- that faces the building's road-access side (its front, CFrame.LookVector) at the road,
-- or nil to leave the cursor position alone.
--
-- halfDepth is half the building's front-to-back size: the setback is measured off the
-- ACCESS SIDE, not the pivot, so a deep building does not end up straddling the kerb.
function SnapUtil.snapBuilding(pos: Vector3, halfDepth: number): (Vector3?, number?)
	if _segCount == 0 then return nil end
	local maxGap = SnapConstants.BUILDING_SNAP_DIST
	local reach = maxGap + halfDepth + _maxRoadCapture
	local FINE = SnapConstants.SNAP_SEGMENT_SAMPLES

	local bestFoot: Vector3? = nil
	local bestSetback = 0
	local bestGap = maxGap
	for _, id in nearbySegmentIds(pos.X, pos.Z, reach) do
		local seg = _segments[id]
		if not seg then continue end
		local roadHalf = footHalf(RoadTypeCatalog.getOrDefault(seg.roadType))
		local b = _segBounds[id]
		if b then
			local dx, dz = pos.X - b.cx, pos.Z - b.cz
			if math.sqrt(dx * dx + dz * dz) - b.r > reach then continue end
		end
		local t  = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, FINE)
		local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		-- Clear ground between the building's near side and the road's edge.
		local gap = distFlatXZ(pos, cp) - roadHalf - halfDepth
		if gap < bestGap then
			bestGap = gap
			bestFoot = cp
			bestSetback = roadHalf + halfDepth + SnapConstants.BUILDING_SETBACK
		end
	end
	if not bestFoot then return nil end

	local foot = bestFoot :: Vector3
	local nx, nz = pos.X - foot.X, pos.Z - foot.Z
	local n = math.sqrt(nx * nx + nz * nz)
	-- Cursor dead on the centreline: there is no side to pick, so leave it alone rather
	-- than guessing one and flipping the building every frame.
	if n < 1e-3 then return nil end
	nx, nz = nx / n, nz / n

	return Vector3.new(foot.X + nx * bestSetback, pos.Y, foot.Z + nz * bestSetback),
		math.atan2(nx, nz)
end

return SnapUtil
