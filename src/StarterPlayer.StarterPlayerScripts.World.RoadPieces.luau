--!strict
-- RoadPieces -- the road network as mesh pieces, built on THIS client from the topology the
-- server already replicates (DataCache segments + nodes), with the shared geometry libraries
-- (RoadJunctionSolver plans every node, RoadGeometry draws). One piece per segment body and
-- one per node, each filed into RoadMeshView's 256-stud cells; RoadMeshView bakes them exactly
-- like the server's old blobs (same textures, batching and LOD).
--
-- Incremental: an edit rebuilds the nodes at the ends of the segments it touched and every
-- segment meeting those nodes (a node's plan sets its arms' trims), nothing else.
--
-- ROAD_OVERHAUL_V2 Phase 2. Only plain ground roads with a cross-section (RoadProfile) are drawn
-- here; rail, bridges, tunnels and roundabout rings keep the old path, and so does any node one
-- of them meets. RoadMeshView skips the server blobs this covers (coversModel).
--
-- Phase 4.1: the ground mesh (TerrainMeshView) asks groundCap how high the land may stand at
-- each lattice corner, so no ground pokes up through a road piece drawn here.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataCache = require(ReplicatedStorage:WaitForChild("DataCache"))
local Road = ReplicatedStorage:WaitForChild("Road")
local RoadTypeCatalog = require(Road:WaitForChild("RoadTypeCatalog"))
local RoadJunctionSolver = require(Road:WaitForChild("RoadJunctionSolver"))
local RoadGeometry = require(Road:WaitForChild("RoadGeometry"))
local JunctionGroups = require(Road:WaitForChild("JunctionGroups"))
local RoadMeshBuilder = require(Road:WaitForChild("RoadMeshBuilder"))
local RoadRules = require(Road:WaitForChild("RoadRules"))
local RoadConstants = require(Road:WaitForChild("RoadConstants"))
local RoadSection = require(Road:WaitForChild("RoadSection"))
local Terrain = ReplicatedStorage:WaitForChild("Terrain")
local TerrainConstants = require(Terrain:WaitForChild("TerrainConstants"))
local TerrainMeshView = require(Terrain:WaitForChild("TerrainMeshView"))

local RoadPieces = {}

local CELL = 256

-- ground: the piece's road surface as flat triangles, (x, z, top y) x 3 = nine numbers each;
-- chunks: the terrain chunks that surface reaches.
type Piece = { cell: string, specs: { any }, ground: { number }, chunks: { number } }
local _pieces: { [string]: Piece } = {}
local _byCell: { [string]: { [string]: boolean } } = {}
local _seen: { [number]: any } = {}        -- segment id -> the record last drawn
local _shiftNodes: { [number]: any } = {}
local _forkNodes: { [number]: any } = {}
local _plans: { [number]: any } = {}       -- node id -> its solved plan
local _ends: { [number]: { { seg: any, atStart: boolean } } } = {} -- node id -> road ends there
local _covered: { [string]: boolean } = {} -- "Segment_12" / "Junction_4" / "DeadEnd_4" drawn here
local _shifts: { [number]: any } = {}      -- segment id -> RoadJunctionSolver.Shift
local _signals: { [number]: boolean } = {} -- node ids with traffic lights

-- Signalised junctions: TrafficLightPlacer names each pole TrafficLight_<nodeId>_<arm>.
local function readSignals(): { [number]: boolean }
	local out: { [number]: boolean } = {}
	local city = workspace:FindFirstChild("_City")
	local lights = city and city:FindFirstChild("TrafficLights")
	if not lights then return out end
	for _, m in lights:GetChildren() do
		local id = tonumber(string.match(m.Name, "^TrafficLight_(%d+)_"))
		if id then out[id] = true end
	end
	return out
end
local _notify: ((dirty: { [string]: boolean }) -> ())? = nil
local _started = false
-- Bus stops (TransitService tags them BusStop): the verge in front of one is paved.
local STOP_LENGTH = 12 -- a kerbside stop with no bay: its shelter's stretch of kerb
local STOP_REACH = 12  -- how far beyond the roadway a stop may stand and still be on this road
local _stops: { [Instance]: { pos: Vector3, half: number, bay: number? } } = {}
-- The same stops in a 128-stud grid, so a road only measures the stops near it (stopsOn ran
-- every stop against every road: segments x stops on a city load).
local STOP_CELL = 128
local _stopCells: { [number]: { [Instance]: boolean } } = {}
-- A stop changes only the road it stands beside: within the roadway + footway + STOP_REACH of
-- its curve, and the curve never leaves its control points' box. No road is wider than this,
-- so a road whose control box is further than this from the stop cannot change.
local STOP_SCAN_MARGIN = 100

local function cellOf(p: Vector3): string
	return math.floor(p.X / CELL) .. "," .. math.floor(p.Z / CELL)
end

local function firstPoint(specs: { any }): Vector3?
	local s = specs[1]
	if not s then return nil end
	if s.strip then return s.strip[1] end
	if s.fan then return s.center end
	if s.mark then return s.mark[1] end
	if s.tris then return s.tris[1] end
	return nil
end

-- == Ground under the road (Phase 4.1) ==========================================
-- The ground mesh comes from the server's heightmap, graded under segment bodies only, so a
-- junction, gore or eased kerb drawn here could have land standing through it. Every lattice
-- corner under a piece's surface is held CLEAR below it, and every corner beside one no higher
-- than the highest surface next to it, so no ground triangle reaches over a road edge either.
-- Visual only: the heightmap (picking, the server's sim) keeps its own heights.
local SAMPLE = TerrainConstants.SAMPLE_SPACING
local TILES = TerrainConstants.CHUNK_TILES
local CHUNKS = TerrainConstants.CHUNKS_PER_AXIS
local HALF = TerrainConstants.MAP_HALF_EXTENT
local CHUNK_STUDS = TerrainConstants.CHUNK_STUDS
local CLEAR = 0.2
-- The ground mesh draws every corner RENDER_BULGE above its heightmap value, and the cap is in
-- heightmap units (it wraps the sampler), so the bulge comes off it.
local BULGE = TerrainConstants.RENDER_BULGE
local _groundAt: { [number]: { [string]: boolean } } = {} -- terrain chunk -> pieces over it
local _capOf: { [number]: { [number]: number } | false } = {} -- terrain chunk -> corner caps (memo)
local _groundDirty: { [number]: boolean } = {}

local function groundOf(specs: { any }): { number }
	local out: { number } = {}
	local function tri(a: Vector3, b: Vector3, c: Vector3)
		-- kerb faces and skirts stand on edge: nothing to hold down under them
		if math.abs((b.X - a.X) * (c.Z - a.Z) - (b.Z - a.Z) * (c.X - a.X)) < 1e-3 then return end
		for _, v in { a, b, c } do
			table.insert(out, v.X)
			table.insert(out, v.Z)
			table.insert(out, v.Y)
		end
	end
	for _, s in specs do
		if s.mark then continue end
		if s.strip then
			local q = s.strip -- left, right interleaved
			for i = 1, #q - 3, 2 do
				tri(q[i], q[i + 1], q[i + 2])
				tri(q[i + 1], q[i + 3], q[i + 2])
			end
		elseif s.fan then
			local r = s.fan
			for i = 1, #r do tri(s.center, r[i], r[i % #r + 1]) end
		elseif s.tris then
			for k = 1, #s.tris - 2, 3 do tri(s.tris[k], s.tris[k + 1], s.tris[k + 2]) end
		end
	end
	return out
end

-- Terrain chunks a surface reaches, one lattice step round it.
local function chunksOf(g: { number }): { number }
	if #g == 0 then return {} end
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, #g, 3 do
		x0, x1 = math.min(x0, g[i]), math.max(x1, g[i])
		z0, z1 = math.min(z0, g[i + 1]), math.max(z1, g[i + 1])
	end
	local function c(v: number): number
		return math.clamp(math.floor((v + HALF) / CHUNK_STUDS), 0, CHUNKS - 1)
	end
	local out = {}
	for cz = c(z0 - SAMPLE), c(z1 + SAMPLE) do
		for cx = c(x0 - SAMPLE), c(x1 + SAMPLE) do table.insert(out, cz * CHUNKS + cx) end
	end
	return out
end

local function sameGround(a: { number }, b: { number }): boolean
	if #a ~= #b then return false end
	for i, v in a do
		if math.abs(v - b[i]) > 1e-3 then return false end
	end
	return true
end

-- Caps for one terrain chunk's corners (local index j * (TILES + 1) + i), or false.
local function capsFor(key: number): { [number]: number } | false
	local set = _groundAt[key]
	if not set then return false end
	local cx = key % CHUNKS
	local cz = (key - cx) // CHUNKS
	-- Corners -1 .. TILES + 1: the ring past the edge feeds the edge corners' neighbours.
	local W = TILES + 3
	local ox = -HALF + cx * CHUNK_STUDS - SAMPLE
	local oz = -HALF + cz * CHUNK_STUDS - SAMPLE
	local under: { [number]: number } = {}
	for pk in set do
		local piece = _pieces[pk]
		if not piece then continue end
		local g = piece.ground
		for t = 1, #g, 9 do
			local ax, az, ay = g[t], g[t + 1], g[t + 2]
			local bx, bz, by = g[t + 3], g[t + 4], g[t + 5]
			local qx, qz, qy = g[t + 6], g[t + 7], g[t + 8]
			local i0 = math.max(math.ceil((math.min(ax, bx, qx) - ox) / SAMPLE), 0)
			local i1 = math.min(math.floor((math.max(ax, bx, qx) - ox) / SAMPLE), W - 1)
			local j0 = math.max(math.ceil((math.min(az, bz, qz) - oz) / SAMPLE), 0)
			local j1 = math.min(math.floor((math.max(az, bz, qz) - oz) / SAMPLE), W - 1)
			if i0 > i1 or j0 > j1 then continue end
			local den = (bz - qz) * (ax - qx) + (qx - bx) * (az - qz)
			for j = j0, j1 do
				local pz = oz + j * SAMPLE
				for i = i0, i1 do
					local px = ox + i * SAMPLE
					local u = ((bz - qz) * (px - qx) + (qx - bx) * (pz - qz)) / den
					local v = ((qz - az) * (px - qx) + (ax - qx) * (pz - qz)) / den
					if u < -1e-4 or v < -1e-4 or u + v > 1 + 1e-4 then continue end
					local y = u * ay + v * by + (1 - u - v) * qy - CLEAR - BULGE
					local idx = j * W + i
					local cur = under[idx]
					if not cur or y < cur then under[idx] = y end
				end
			end
		end
	end
	if next(under) == nil then return false end
	-- ponytail: one lattice step of margin. A ground triangle that clips a road edge with no
	-- corner under the road can still show a sliver; widen the ring if that turns up.
	local caps: { [number]: number } = {}
	for idx, y in under do
		local i, j = idx % W, idx // W
		-- two steps: a narrow road (an alley, 4.5 studs) can fall between lattice corners
		for dj = -2, 2 do
			for di = -2, 2 do
				local ni, nj = i + di, j + dj
				if ni < 1 or nj < 1 or ni > TILES + 1 or nj > TILES + 1 then continue end
				local out = (nj - 1) * (TILES + 1) + (ni - 1)
				local own = under[nj * W + ni]
				if own then
					caps[out] = own
				elseif not caps[out] or y > caps[out] then
					caps[out] = y -- beside the road: no higher than the highest surface it touches
				end
			end
		end
	end
	return caps
end

local function groundCap(gx: number, gz: number): number?
	local cx = math.min(gx // TILES, CHUNKS - 1)
	local cz = math.min(gz // TILES, CHUNKS - 1)
	local key = cz * CHUNKS + cx
	local caps = _capOf[key]
	if caps == nil then
		caps = capsFor(key)
		_capOf[key] = caps
	end
	if not caps then return nil end
	return caps[(gz - cz * TILES) * (TILES + 1) + (gx - cx * TILES)]
end

-- groundCap a chunk at a time: the same memoised table, for TerrainMeshView's row reader.
local function chunkCaps(key: number): { [number]: number }?
	local caps = _capOf[key]
	if caps == nil then
		caps = capsFor(key)
		_capOf[key] = caps
	end
	if caps then return caps :: { [number]: number } end
	return nil
end

local function flushGround()
	for key in _groundDirty do
		_capOf[key] = nil
		TerrainMeshView.markDirty(key)
	end
	table.clear(_groundDirty)
end

local function setGround(key: string, old: Piece?, new: Piece?)
	if old and new and sameGround(old.ground, new.ground) then
		new.chunks = old.chunks -- same surface: the ground under it is already right
		return
	end
	if old then
		for _, k in old.chunks do
			local set = _groundAt[k]
			if set then
				set[key] = nil
				if next(set) == nil then _groundAt[k] = nil end
			end
			_groundDirty[k] = true
		end
	end
	if new then
		for _, k in new.chunks do
			local set = _groundAt[k]
			if not set then
				set = {}
				_groundAt[k] = set
			end
			set[key] = true
			_groundDirty[k] = true
		end
	end
end

-- Value equality of two spec lists, all the way down (Vector3 / CFrame / Color3 / EnumItem
-- compare by value with ==).
local function sameValue(a: any, b: any): boolean
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in a do
		if not sameValue(v, b[k]) then return false end
	end
	for k in b do
		if a[k] == nil then return false end
	end
	return true
end

local function setPiece(key: string, specs: { any }?, dirty: { [string]: boolean })
	local old = _pieces[key]
	-- An edit rebuilds every road meeting a touched node, and most of them come back exactly as
	-- they were (measured on a grid: a short link between two streets rebuilt 20 pieces, 3 of
	-- them changed, and dirtied 7 cells where 3 had anything new). Every dirty cell is a full
	-- re-bake, several engine mesh bakes each, so an unchanged piece must not dirty its cell.
	-- Same specs means the same cell (it is keyed off the first point) and the same ground.
	if old and specs and #specs == #old.specs and sameValue(old.specs, specs) then
		return
	end
	if old then
		local set = _byCell[old.cell]
		if set then
			set[key] = nil
			if next(set) == nil then _byCell[old.cell] = nil end
		end
		dirty[old.cell] = true
		_pieces[key] = nil
	end
	local p = if specs and #specs > 0 then firstPoint(specs) else nil
	if not specs or not p then
		setGround(key, old, nil)
		return
	end
	local cell = cellOf(p)
	local ground = groundOf(specs)
	local piece: Piece = { cell = cell, specs = specs, ground = ground, chunks = chunksOf(ground) }
	_pieces[key] = piece
	setGround(key, old, piece)
	local set = _byCell[cell]
	if not set then
		set = {}
		_byCell[cell] = set
	end
	set[key] = true
	dirty[cell] = true
end

local function profileOf(seg: any): any
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	return spec.profile, spec
end

-- ponytail: Elevated / Tunnel stay on the server renderer until Phase 8 (bridges) draws them.
-- A fillet arc (isArc: RoadNetwork's corner rounding) is a plain road and is drawn here.
local function drawable(seg: any): boolean
	if seg.isRoundabout or seg.vMode == "Elevated" or seg.vMode == "Tunnel" then return false end
	return profileOf(seg) ~= nil
end

-- == Node control ================================================================
-- Who gives way: the heaviest road and its straight-across partner run through, every other arm
-- yields (RoadRules.priorityArms' rule: highway 2000 + arterial 1000 + width).
local function weightOf(spec: any): number
	local w = spec.width
	if spec.isHighway then w += 2000 end
	if RoadRules.roadClass(spec) == "arterial" then w += 1000 end
	return w
end

local function priorityOf(arms: { any }, specs: { any }): { [number]: boolean }
	local best, bestW = 0, -math.huge
	for i in arms do
		local w = weightOf(specs[i])
		if w > bestW or (w == bestW and arms[i].segId < arms[best].segId) then best, bestW = i, w end
	end
	local main: { [number]: boolean } = { [best] = true }
	local partner, partnerDot = nil, -0.5
	for i, a in arms do
		if i ~= best then
			local d = a.dir:Dot(arms[best].dir)
			if d < partnerDot then partner, partnerDot = i, d end
		end
	end
	if partner then main[partner] = true end
	return main
end

local function movementOf(inDir: Vector3, outDir: Vector3): string
	local cross = inDir.X * outDir.Z - inDir.Z * outDir.X
	local dot = inDir:Dot(outDir)
	if dot > 0.7 then return "straight" end
	if dot < -0.9 then return "uturn" end
	return if cross > 0 then "right" else "left"
end

-- == Solving ======================================================================
local function solveNode(nodeId: number): any?
	local ends = _ends[nodeId]
	local pos = DataCache.GetNodeById(nodeId)
	if not ends or not pos then return nil end
	local laneSide = RoadRules.getLaneSideSign()
	local arms = {}
	local specs = {}
	local armShift = {}
	for i, e in ends do
		if not drawable(e.seg) then return nil end -- the old path draws this node
		local profile, spec = profileOf(e.seg)
		armShift[i] = RoadJunctionSolver.armShift(_shifts, e.seg, e.atStart, nodeId)
		local arm = RoadJunctionSolver.arm(e.seg, e.atStart, profile, laneSide, armShift[i])
		arm.spec = spec
		table.insert(arms, arm)
		table.insert(specs, spec)
	end
	local ok, solved = pcall(RoadJunctionSolver.solve, { pos = pos, arms = arms })
	if not ok then
		warn(`[RoadPieces] node {nodeId}: {solved}`)
		return nil
	end
	local plan = solved
	plan.pos = pos
	plan.specs = specs
	plan.ends = ends
	plan.armShift = armShift
	plan.nodeId = nodeId
	if plan.kind == "junction" then
		plan.main = priorityOf(arms, specs)
	end
	return plan
end

local function updatePlan(nodeId: number)
	local plan = solveNode(nodeId)
	_plans[nodeId] = plan
	if not plan then
		_shiftNodes[nodeId] = nil
		_forkNodes[nodeId] = nil
		return
	end
	local node = { plan = plan, ends = plan.ends }
	_shiftNodes[nodeId] = node
	_forkNodes[nodeId] = if plan.kind == "fork" and plan.shift then node else nil
end

-- How one road end is dressed by the plan of the node it meets.
-- A lane turning round at this end: the line it crosses -- on its driver's crossing-turn side --
-- is left open from the end back past its arrow, or the U-turn arrow points into a solid line
-- (user, 2026-10-06). `k`: the lane's band in the arm's frame (outward); returns the line's band
-- in the curve's frame.
local function turnLine(k: number, nb: number, atStart: boolean): number
	-- a driver arriving faces into the node: their left is the arm's right (the next band up)
	local line = if RoadRules.getCrossingTurn() == "left" then k else k - 1
	return if atStart then line else nb - line
end
-- How far from the end the line stays open: to the far end of the arrow (RoadGeometry arrows run
-- up to 12 studs) and a little more.
local OPEN_PAST_ARROW = RoadConstants.ARROW_GAP + 14

-- A junction whose lanes the player set (Lane Connector: manual; or a turn switched off / U-turns
-- on): its arrows show the turns its connections really allow (user, 2026-10-07). Untouched
-- junctions keep the rule-of-thumb arrows below -- the same turns the default connections make.
local function customLanes(nodeId: number): boolean
	local perms = DataCache.GetTurnPerms(nodeId)
	if not perms then return false end
	return perms.manual or not perms.left or not perms.right or not perms.straight or perms.uturn
end

-- Per arriving band of arm i (arm frame): the turns its lane's connections take, from the lane
-- data the server sends for the Lane Connector (a dot per lane mouth, "from>to" links).
local function connectedTurns(plan: any, i: number): { [number]: any }?
	local data = DataCache.GetLanePath(plan.nodeId)
	if not data or not data.dots or not data.links then return nil end
	local dots: { [string]: any } = {}
	for _, dot in data.dots do dots[dot.edgeId] = dot end
	local arm, segId = plan.arms[i], plan.ends[i].seg.id
	local out: { [number]: any } = {}
	for _, link in data.links do
		local from, to = string.match(link, "^(.-)>(.+)$")
		local a, b = dots[from or ""], dots[to or ""]
		if not a or not b or a.kind ~= "in" or tonumber(string.match(from :: string, "^S(%d+):")) ~= segId then continue end
		-- the arriving band under this lane's mouth
		local off = RoadJunctionSolver.flat(a.position - plan.pos)
		local p, t = RoadJunctionSolver.at(arm, math.max(off:Dot(arm.dir), 0))
		local lat = RoadJunctionSolver.flat(a.position - p):Dot(RoadJunctionSolver.rightOf(t))
		local best, bestD = nil, math.huge
		for k, bd in arm.sec.bands do
			if bd.k == "lane" and bd.d == -1 and math.abs((bd.x0 + bd.x1) * 0.5 - lat) < bestD then
				best, bestD = k, math.abs((bd.x0 + bd.x1) * 0.5 - lat)
			end
		end
		if not best then continue end
		local dirs = out[best] or {}
		out[best] = dirs
		local move = movementOf(a.dir, b.dir)
		if move == "uturn" then dirs.uturn = RoadRules.getCrossingTurn() else dirs[move] = true end
	end
	return out
end

local function dressFor(plan: any, seg: any, atStart: boolean): any
	if not plan then return { trim = 0 } end
	local i = 0
	for k, e in plan.ends do
		if e.seg.id == seg.id and e.atStart == atStart then i = k break end
	end
	if i == 0 then return { trim = 0 } end
	local forkShift = if plan.shift then plan.shift[i] else 0
	local d: any = { trim = plan.trims[i], shift = if forkShift ~= 0 then forkShift else plan.armShift[i] }
	-- A joint with no piece between the two bodies (a straight run on, or a taper's narrow end):
	-- both end on the line bisecting the two roads' directions (RoadGeometry.body `mitre`).
	if (plan.kind == "straight" or plan.kind == "transition") and #plan.arms == 2 and plan.trims[i] < 0.01 then
		local m = RoadJunctionSolver.unit(RoadJunctionSolver.flat(plan.arms[i].dir - plan.arms[3 - i].dir))
		d.mitre = if atStart then m else -m
	end
	-- the arm a fork's stem ends on (and no other fork runs along it: a road with a ramp each side)
	local f = nil
	if plan.kind == "fork" then
		for _, g in plan.forks or { plan.fork } do
			if g.main == i then f = nil break end
			if g.stem == i then f = g end
		end
	end
	if f then
		-- the stem ends on the fork's cut (a joint that kinks: the mitre with the main road)
		if f.t0 then d.mitre = if atStart then -f.t0 else f.t0 end
		-- a ramp that takes lanes of its own: the line between them and the lanes carrying on is
		-- dense for a stretch from the fork (f.boundary: after that stem lane, looking out)
		if f.boundary then
			local bands = plan.arms[i].sec.bands
			local lanes = {}
			for k, bd in bands do
				if bd.k == "lane" then table.insert(lanes, k) end
			end
			local kArm = lanes[#lanes - f.boundary] -- the stem arm runs the other way
			if kArm then d.dense = { k = if atStart then kArm else #bands - kArm, len = RoadGeometry.DENSE_RUN } end
		end
	end
	-- Where a road narrows, the lanes that end there say so: a U-turn, or a merge arrow before the
	-- taper (RoadJunctionSolver plan.laneEnds).
	local ends = plan.laneEnds and plan.laneEnds[i]
	if ends then
		local nb = #plan.arms[i].sec.bands
		local arrows, open = {}, {}
		for k, how in ends do
			arrows[if atStart then k else (nb - k + 1)] = if how == "uturn" then { uturn = RoadRules.getCrossingTurn() } else { merge = how }
			if how == "uturn" then table.insert(open, turnLine(k, nb, atStart)) end
		end
		d.arrows = arrows
		d.arrowsAt = plan.trims[i] + 1
		if #open > 0 then d.open = { ks = open, len = d.arrowsAt + OPEN_PAST_ARROW } end
	end
	if plan.kind == "junction" then
		-- a short link between two junctions of a super node (JunctionGroups): no stop line, no
		-- crossing, no arrows -- the group is one junction (user, 2026-10-07)
		local link = false
		local far = _plans[if atStart then seg.endNode else seg.startNode]
		if far then
			for j, fe in far.ends do
				if fe.seg.id == seg.id and fe.atStart ~= atStart then link = JunctionGroups.isLink(plan, i, far, j) end
			end
		end
		d.crosswalk = plan.crosswalk[i] and not link
		d.stopAt = if link then 0 else plan.stopAt[i]
		d.control = if link then "none" elseif _signals[plan.nodeId] then "signal" elseif plan.main and plan.main[i] then "none" else "yield"
		d.plain = RoadJunctionSolver.approachOf(plan, i)
		d.bare = link or nil
		local arm = plan.arms[i]
		d.bulb = arm.buildOut ~= nil
		local moves: { [string]: boolean } = {}
		for j, other in plan.arms do
			-- no arrow into a road a car may not drive (a pedestrian street, a busway)
			local allowed = plan.specs[j] and plan.specs[j].allowedVehicles
			if j ~= i and not link and not (allowed and not allowed.Car) then moves[movementOf(-arm.dir, other.dir)] = true end
		end
		local arrows = {}
		local sec = arm.sec
		local set = if not link and customLanes(plan.nodeId) then connectedTurns(plan, i) else nil
		for k, bd in sec.bands do
			if bd.k ~= "lane" or bd.d ~= -1 then continue end
			local only = bd.count == 1
			local dirs: any = {}
			if set then
				dirs = set[k] or {}
			else
				if moves.straight then dirs.straight = true end
				if moves.left and (only or bd.ordinal == 1) then dirs.left = true end
				if moves.right and (only or bd.ordinal == bd.count) then dirs.right = true end
			end
			-- the body sees the bands in the CURVE's frame; this arm's frame is mirrored at the end
			arrows[if atStart then k else (#sec.bands - k + 1)] = dirs
		end
		d.arrows = arrows
	elseif plan.kind == "ring" then
		d.crosswalk = plan.crosswalk[i]
		d.plain = plan.trims[i] + 8
	elseif plan.kind == "end" or plan.kind == "culdesac" then
		-- A dead end is where cars turn round (not at the map edge, where they drive on out of the
		-- city): a U-turn arrow on every lane coming in, and the line between the two directions
		-- open before it. A cul-de-sac's bulb says it already: no arrow there (user, 2026-10-06).
		d.cap = true
		local p = plan.pos
		-- (and only where there is a lane to turn into: a one-way's dead end has none)
		local back = false
		for _, bd in plan.arms[1].sec.bands do
			if bd.k == "lane" and (bd.d :: number) > 0 then back = true end
		end
		if back and math.max(math.abs(p.X), math.abs(p.Z)) < HALF - 24 then
			if plan.kind == "end" then
				d.stopAt = 0.01
				d.control = "none"
				d.uturnAll = RoadRules.getCrossingTurn()
			end
			local bands = plan.arms[1].sec.bands
			local open = {}
			for k = 1, #bands - 1 do
				local a, c = bands[k], bands[k + 1]
				if a.k == "lane" and c.k == "lane" and a.d ~= c.d then table.insert(open, if atStart then k else #bands - k) end
			end
			if #open > 0 then d.open = { ks = open, len = (d.stopAt or 0) + OPEN_PAST_ARROW } end
		end
	end
	return d
end

-- A real junction (the server sent its position) that this file does not draw: a bridge,
-- tunnel or roundabout meets it, so the old path draws it -- and every road at it, or their
-- bodies would run on through it. ponytail: a plain JOINT onto a bridge (2 roads) stays here,
-- the body simply stops at the node where the old deck starts; and a road that falls back draws
-- its far end the old way too, so a v2 junction there may not meet it exactly (Phase 8 bridges).
local function oldPathNode(nodeId: number): boolean
	return _plans[nodeId] == nil and DataCache.GetNodeById(nodeId) ~= nil and #(_ends[nodeId] or {}) >= 3
end

local function stopCellKey(p: Vector3): number
	return math.floor(p.Z / STOP_CELL) * 65536 + math.floor(p.X / STOP_CELL)
end

local function indexStop(inst: Instance, pos: Vector3)
	local k = stopCellKey(pos)
	local cell = _stopCells[k]
	if not cell then
		cell = {}
		_stopCells[k] = cell
	end
	cell[inst] = true
end

local function unindexStop(inst: Instance, pos: Vector3)
	local k = stopCellKey(pos)
	local cell = _stopCells[k]
	if not cell then return end
	cell[inst] = nil
	if next(cell) == nil then _stopCells[k] = nil end
end

-- Bus stops beside this road, along its curve (RoadGeometry.Stop).
local function stopsOn(seg: any, armS: any): { any }?
	if next(_stops) == nil then return nil end
	local reach = math.max(armS.sec.roadR, -armS.sec.roadL) + math.max(armS.sec.walkL, armS.sec.walkR) + STOP_REACH
	-- Only stops whose cell the arm's box (grown by the reach) touches can be within reach of it.
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, q in armS.pts do
		if q.X < x0 then x0 = q.X end
		if q.X > x1 then x1 = q.X end
		if q.Z < z0 then z0 = q.Z end
		if q.Z > z1 then z1 = q.Z end
	end
	local near: { any } = {}
	for cz = math.floor((z0 - reach) / STOP_CELL), math.floor((z1 + reach) / STOP_CELL) do
		for cx = math.floor((x0 - reach) / STOP_CELL), math.floor((x1 + reach) / STOP_CELL) do
			local cell = _stopCells[cz * 65536 + cx]
			if not cell then continue end
			for inst in cell do
				local st = _stops[inst]
				if st then table.insert(near, st) end
			end
		end
	end
	if #near == 0 then return nil end
	local out = {}
	for _, st in near do
		local best, bestD, bestLat = math.huge, 0, 0
		for i = 1, #armS.pts - 1 do
			local a, c = armS.pts[i], armS.pts[i + 1]
			local ab = Vector3.new(c.X - a.X, 0, c.Z - a.Z)
			local len = ab.Magnitude
			if len < 1e-6 then continue end
			local dir = ab / len
			local rel = Vector3.new(st.pos.X - a.X, 0, st.pos.Z - a.Z)
			local along = math.clamp(rel:Dot(dir), 0, len)
			local off = rel - dir * along
			if off.Magnitude < best then
				best = off.Magnitude
				bestD = armS.cum[i] + along
				bestLat = rel:Dot(RoadJunctionSolver.rightOf(dir))
			end
		end
		-- a bay runs a little past its bus each end, so an articulated one fits whole between the tapers
		if best <= reach then
			table.insert(out, { d = bestD, half = st.half + (if st.bay then 4 else 0), right = bestLat > 0, bay = st.bay })
		end
	end
	return if #out > 0 then out else nil
end

local function buildSegment(seg: any, dirty: { [string]: boolean })
	local key = "s" .. seg.id
	local profile, spec = profileOf(seg)
	if not profile or not drawable(seg) or oldPathNode(seg.startNode) or oldPathNode(seg.endNode) then
		setPiece(key, nil, dirty)
		_covered["Segment_" .. seg.id] = nil
		return
	end
	local b = RoadMeshBuilder.new()
	local armS = RoadJunctionSolver.arm(seg, true, profile, RoadRules.getLaneSideSign())
	local ok, err = pcall(RoadGeometry.body, b, armS, spec,
		dressFor(_plans[seg.startNode], seg, true), dressFor(_plans[seg.endNode], seg, false), stopsOn(seg, armS))
	if not ok then warn(`[RoadPieces] segment {seg.id}: {err}`) end
	setPiece(key, RoadMeshBuilder.specsOf(b), dirty)
	_covered["Segment_" .. seg.id] = true
end

local function buildNode(nodeId: number, dirty: { [string]: boolean })
	local key = "n" .. nodeId
	local plan = _plans[nodeId]
	-- a dead end whose road the old path draws keeps the old end with it
	if plan and plan.kind == "end" and not _covered["Segment_" .. plan.ends[1].seg.id] then plan = nil end
	if not plan then
		setPiece(key, nil, dirty)
		-- Keep a removed node covered until its server model disappears; replication
		-- of the topology and of Instances can arrive in separate frames.
		if _ends[nodeId] then
			_covered["Junction_" .. nodeId] = nil
			_covered["DeadEnd_" .. nodeId] = nil
			_covered["Corner_" .. nodeId] = nil
		end
		return
	end
	local b = RoadMeshBuilder.new()
	local spec = plan.specs[1]
	local ok, err = pcall(function()
		if plan.kind == "end" then
			RoadGeometry.cap(b, plan.arms[1], spec)
		elseif plan.kind == "bend" then
			RoadGeometry.bend(b, plan, spec)
		elseif plan.kind == "transition" then
			RoadGeometry.taper(b, plan, plan.specs[plan.taper.b]) -- painted as the wider road
		elseif plan.kind == "junction" then
			RoadGeometry.junction(b, plan, plan.pos, spec)
		elseif plan.kind == "fork" then
			RoadGeometry.fork(b, plan, plan.pos, plan.specs[plan.fork.stem])
		elseif plan.kind == "ring" then
			RoadGeometry.ring(b, plan, plan.pos, spec)
		elseif plan.kind == "culdesac" then
			RoadGeometry.culdesac(b, plan, plan.pos, spec)
		end
	end)
	if not ok then warn(`[RoadPieces] node {nodeId} ({plan.kind}): {err}`) end
	setPiece(key, RoadMeshBuilder.specsOf(b), dirty)
	_covered["Junction_" .. nodeId] = true
	_covered["DeadEnd_" .. nodeId] = true
	_covered["Corner_" .. nodeId] = true
end

-- == Topology changes =============================================================
-- A pass this big is a city LOAD (the whole network arrives as one delta): it yields every
-- REBUILD_SLICE seconds instead of solving and building thousands of pieces in one frame --
-- several seconds of frozen client on a big city, and past the script budget a thread that is
-- killed with half the roads unbuilt. A normal edit stays well under it and lands at once.
local REBUILD_SLICE_MIN_ITEMS = 64
local REBUILD_SLICE = 0.004

-- Same segment record, field by field (Vector3s compare by value).
local function sameRecord(a: any, b: any): boolean
	for k, v in a do
		if b[k] ~= v then return false end
	end
	for k in b do
		if a[k] == nil then return false end
	end
	return true
end

local function rebuildFrom(list: { any })
	local now: { [number]: any } = {}
	-- The server re-sends every road meeting a node an edit touched (RoadService.applyChanges'
	-- cascade), each as a fresh table even when nothing about it changed. Identity is how this
	-- file tells a changed road from a standing one, so a re-sent but identical record keeps the
	-- table already drawn: its nodes are not re-solved and its pieces are not re-built.
	for _, s in list do
		local old = _seen[s.id]
		now[s.id] = if old and old ~= s and sameRecord(old, s) then old else s
	end
	local dirtyNodes: { [number]: boolean } = {}
	local removed: { number } = {}
	for id, s in now do
		local old = _seen[id]
		if old ~= s then
			dirtyNodes[s.startNode] = true
			dirtyNodes[s.endNode] = true
			if old then
				dirtyNodes[old.startNode] = true
				dirtyNodes[old.endNode] = true
			end
		end
	end
	for id, old in _seen do
		if not now[id] then
			table.insert(removed, id)
			dirtyNodes[old.startNode] = true
			dirtyNodes[old.endNode] = true
		end
	end
	-- Update only changed endpoints; an ordinary edit must not allocate two new
	-- adjacency records for every road already standing in the city.
	for nodeId in dirtyNodes do
		local ends: { { seg: any, atStart: boolean } } = {}
		for _, e in (_ends[nodeId] or {}) do
			if now[e.seg.id] == e.seg then table.insert(ends, e) end
		end
		_ends[nodeId] = if #ends > 0 then ends else nil
	end
	for id, s in now do
		if _seen[id] == s then continue end
		for _, e in { { s.startNode, true }, { s.endNode, false } } do
			local ends = _ends[e[1]]
			if not ends then ends = {}; _ends[e[1]] = ends end
			table.insert(ends, { seg = s, atStart = e[2] })
		end
	end
	_seen = now
	if next(dirtyNodes) == nil and #removed == 0 then return end

	local dirty: { [string]: boolean } = {}
	local dirtySegs: { [number]: any } = {}
	local count = 0
	for _ in dirtyNodes do count += 1 end
	local sliced = count > REBUILD_SLICE_MIN_ITEMS
	local t0 = os.clock()
	local function breathe()
		if sliced and os.clock() - t0 >= REBUILD_SLICE then
			task.wait()
			t0 = os.clock()
		end
	end
	for nodeId in dirtyNodes do
		updatePlan(nodeId)
		for _, e in (_ends[nodeId] or {}) do dirtySegs[e.seg.id] = e.seg end
		breathe()
	end
	-- Shifted roads (a highway running straight on past an exit): carry the forks' shifts along
	-- the network; every node at either end of a road whose shift changed solves again, until it
	-- settles (a fork downstream of another sees its stem shifted only on the next pass).
	for _ = 1, 4 do
		local now = RoadJunctionSolver.carryShifts(_shiftNodes, _forkNodes)
		local touched: { [number]: boolean } = {}
		local function differs(a: any?, b: any?): boolean
			if not a or not b then return a ~= b end
			return a.shift ~= b.shift or a.from ~= b.from or a.to ~= b.to or a.fork ~= b.fork
		end
		for id, rec in now do
			if differs(rec, _shifts[id]) then touched[id] = true end
		end
		for id in _shifts do
			if not now[id] then touched[id] = true end
		end
		_shifts = now
		if next(touched) == nil then break end
		for segId in touched do
			local seg = _seen[segId]
			if not seg then continue end
			for _, nodeId in { seg.startNode, seg.endNode } do
				dirtyNodes[nodeId] = true
				updatePlan(nodeId)
				for _, e in (_ends[nodeId] or {}) do dirtySegs[e.seg.id] = e.seg end
			end
		end
	end
	for _, id in removed do
		setPiece("s" .. id, nil, dirty)
		-- Its replicated model can still exist while this predicted/confirmed removal draws.
		-- releaseModel clears the coverage when that model leaves the renderer.
	end
	for _, seg in dirtySegs do
		-- the far end's plan may never have been solved (first sight of this road)
		for _, nodeId in { seg.startNode, seg.endNode } do
			if _plans[nodeId] == nil and not dirtyNodes[nodeId] then updatePlan(nodeId) end
		end
		buildSegment(seg, dirty)
		breathe()
	end
	-- a dead end follows its road onto (or off) the old path, wherever that was decided
	for _, seg in dirtySegs do
		for _, nodeId in { seg.startNode, seg.endNode } do
			local plan = _plans[nodeId]
			if plan and plan.kind == "end" then dirtyNodes[nodeId] = true end
		end
	end
	for nodeId in dirtyNodes do
		buildNode(nodeId, dirty)
		breathe()
	end
	if _notify and next(dirty) then (_notify :: any)(dirty) end
	flushGround()
end

-- One pass at a time. A sliced pass that is still running takes the newest list when it is
-- done (each pass diffs against what the last one drew, so nothing is lost by skipping the
-- lists in between). task.spawn runs straight through a pass that never yields, so an ordinary
-- edit is still drawn before this returns, exactly as before.
local _authoritative: { any } = {}
local _predictions: { [number]: { [number]: any } } = {}
local _predictionNodes: { [number]: { [number]: boolean } } = {}
local _predictionNodeCounts: { [number]: number } = {}
local function predictedSegments(list: { any }): { any }
	if next(_predictions) == nil then return list end
	local latest: { [number]: number } = {}
	local overrides: { [number]: any } = {}
	for token, entries in _predictions do
		for id, entry in entries do
			if not latest[id] or token > latest[id] then latest[id] = token; overrides[id] = entry end
		end
	end
	local out: { any } = {}
	for _, s in list do
		local replacement = overrides[s.id]
		if replacement == false then continue end
		table.insert(out, if replacement and replacement.roadType ~= s.roadType then replacement else s)
	end
	return out
end

local _rebuildBusy = false
local _rebuildNext: { any }? = nil
local function requestRebuild(list: { any })
	if _rebuildBusy then
		_rebuildNext = list
		return
	end
	_rebuildBusy = true
	task.spawn(function()
		local cur: { any }? = list
		while cur do
			local ok, err = pcall(rebuildFrom, cur)
			if not ok then warn("[RoadPieces] rebuild failed: " .. tostring(err)) end
			cur = _rebuildNext
			_rebuildNext = nil
		end
		_rebuildBusy = false
	end)
end

local function onSegments(list: { any })
	_authoritative = list
	requestRebuild(predictedSegments(list))
end

-- == Public =======================================================================
function RoadPieces.setPrediction(token: number, entries: { [number]: any }?): ()
	for nodeId in (_predictionNodes[token] or {}) do
		local count = _predictionNodeCounts[nodeId] - 1
		_predictionNodeCounts[nodeId] = if count > 0 then count else nil
	end
	_predictionNodes[token] = nil
	if entries then
		local nodes: { [number]: boolean } = {}
		for id, replacement in entries do
			if replacement ~= false then continue end
			local seg = DataCache.GetSegmentById(id)
			if seg then nodes[seg.startNode] = true; nodes[seg.endNode] = true end
		end
		for nodeId in nodes do _predictionNodeCounts[nodeId] = (_predictionNodeCounts[nodeId] or 0) + 1 end
		_predictionNodes[token] = nodes
	end
	_predictions[token] = entries
	requestRebuild(predictedSegments(_authoritative))
end

function RoadPieces.isIdle(): boolean
	return not _rebuildBusy
end

-- Return only the edited roads and roads sharing their endpoint junctions.
-- A finite cap keeps temporary preview work bounded on unusually large junctions.
function RoadPieces.affectedSegments(ids: { number }, limit: number): { number }?
	local out: { number } = {}
	local seen: { [number]: boolean } = {}
	local function add(id: number): boolean
		if seen[id] then return true end
		if #out >= limit then return false end
		seen[id] = true
		table.insert(out, id)
		return true
	end
	for _, id in ids do
		if not add(id) then return nil end
		local seg = _seen[id]
		if not seg then continue end
		for _, nodeId in { seg.startNode, seg.endNode } do
			for _, entry in (_ends[nodeId] or {}) do
				if not add(entry.seg.id) then return nil end
			end
		end
	end
	return out
end

-- Capture before an override removes a segment's old body and junction pieces.
function RoadPieces.cellsForSegments(ids: { number }): { [string]: boolean }
	local cells: { [string]: boolean } = {}
	for _, id in ids do
		local body = _pieces["s" .. id]
		if body then cells[body.cell] = true end
		local seg = _seen[id]
		if seg then
			for _, nodeId in { seg.startNode, seg.endNode } do
				local node = _pieces["n" .. nodeId]
				if node then cells[node.cell] = true end
			end
		end
	end
	return cells
end

-- Only visit pieces filed in the affected cells; reject oversized temporary views.
function RoadPieces.segmentsForCells(cells: { [string]: boolean }, limit: number): { any }?
	local segments: { any } = {}
	local seen: { [number]: boolean } = {}
	local function add(id: number): boolean
		if seen[id] then return true end
		seen[id] = true
		local seg = _seen[id]
		if not seg then return true end
		if not drawable(seg) or #segments >= limit then return false end
		table.insert(segments, seg)
		return true
	end
	for cell in cells do
		for key in (_byCell[cell] or {}) do
			local id = tonumber(string.sub(key, 2))
			if not id then continue end
			if string.sub(key, 1, 1) == "s" then
				if not add(id) then return nil end
			else
				for _, e in (_ends[id] or {}) do
					if not add(e.seg.id) then return nil end
				end
			end
		end
	end
	return segments
end

function RoadPieces.specsForCell(cell: string): { any }
	local out = {}
	local set = _byCell[cell]
	if not set then return out end
	for key in set do
		local piece = _pieces[key]
		if piece then
			for _, s in piece.specs do table.insert(out, s) end
		end
	end
	return out
end

function RoadPieces.hasCell(cell: string): boolean
	return _byCell[cell] ~= nil
end

-- Does this client already draw what the server's road model `name` holds?
function RoadPieces.coversModel(name: string): boolean
	local id = tonumber(string.match(name, "^Segment_(%d+)$"))
	if id then
		for _, entries in _predictions do
			if entries[id] == false then return true end
		end
	end
	local nodeId = tonumber(string.match(name, "^[%a]+_(%d+)$"))
	if nodeId and not _ends[nodeId] and _predictionNodeCounts[nodeId] then return true end
	return _covered[name] == true
end

function RoadPieces.releaseModel(name: string): ()
	local id = tonumber(string.match(name, "^Segment_(%d+)$"))
	if id then
		if not _seen[id] then _covered[name] = nil end
		return
	end
	local nodeId = tonumber(string.match(name, "^[%a]+_(%d+)$"))
	if nodeId and not _ends[nodeId] and not _predictionNodeCounts[nodeId] then _covered[name] = nil end
end

-- `notify(dirtyCells)` is called after every rebuild with the cells whose pieces changed.
function RoadPieces.start(notify: (dirty: { [string]: boolean }) -> ())
	_notify = notify
	if _started then
		local dirty: { [string]: boolean } = {}
		for key in _byCell do dirty[key] = true end
		if next(dirty) then notify(dirty) end
		return
	end
	_started = true
	TerrainMeshView.setGroundCap(groundCap, chunkCaps)
	_signals = readSignals()
	-- Lights placed or removed: a stop line instead of give-way teeth (or back) on that node's roads.
	local function watchLights(lights: Instance)
		local pending = false
		local function changed()
			if pending then return end
			pending = true
			task.delay(0.5, function()
				pending = false
				local now = readSignals()
				local touched: { [number]: boolean } = {}
				for id in now do
					if not _signals[id] then touched[id] = true end
				end
				for id in _signals do
					if not now[id] then touched[id] = true end
				end
				_signals = now
				local dirty: { [string]: boolean } = {}
				for id in touched do
					for _, e in (_ends[id] or {}) do buildSegment(e.seg, dirty) end
				end
				if _notify and next(dirty) then (_notify :: any)(dirty) end
				flushGround()
			end)
		end
		lights.ChildAdded:Connect(changed)
		lights.ChildRemoved:Connect(changed)
	end
	local city = workspace:FindFirstChild("_City")
	if city then
		local lights = city:FindFirstChild("TrafficLights")
		if lights then
			watchLights(lights)
		else
			city.ChildAdded:Connect(function(c)
				if c.Name == "TrafficLights" then watchLights(c) end
			end)
		end
	end
	-- The player rewired a junction's lanes or switched its turns: repaint the arrows on its roads,
	-- only where the connections a customised junction's arrows read have changed.
	local laneSig: { [number]: string } = {}
	local function lanesChanged()
		local nodes: { [number]: boolean } = {}
		for nodeId in DataCache.GetLanePaths() do nodes[nodeId] = true end
		for nodeId in laneSig do nodes[nodeId] = true end
		local dirty: { [string]: boolean } = {}
		for nodeId in nodes do
			local sig: string? = nil
			if customLanes(nodeId) then
				local data = DataCache.GetLanePath(nodeId)
				local links = if data and data.links then table.clone(data.links) else {}
				table.sort(links)
				sig = table.concat(links, ",")
			end
			if sig == laneSig[nodeId] then continue end
			laneSig[nodeId] = sig
			for _, e in (_ends[nodeId] or {}) do buildSegment(e.seg, dirty) end
		end
		if not next(dirty) then return end
		if _notify then (_notify :: any)(dirty) end
		flushGround()
	end
	DataCache.On("lanePaths", lanesChanged)
	DataCache.On("turnPerms", lanesChanged)
	local function stopsChanged(at: Vector3)
		local dirty: { [string]: boolean } = {}
		for _, seg in _seen do
			-- Rebuild only a road the stop can actually stand beside (see STOP_SCAN_MARGIN). The
			-- old test rebuilt every road with a control point within 400 studs -- ~100 roads per
			-- stop on a city grid, for every stop that replicated in during a load.
			local x0 = math.min(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) - STOP_SCAN_MARGIN
			local x1 = math.max(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) + STOP_SCAN_MARGIN
			local z0 = math.min(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) - STOP_SCAN_MARGIN
			local z1 = math.max(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) + STOP_SCAN_MARGIN
			if at.X >= x0 and at.X <= x1 and at.Z >= z0 and at.Z <= z1 then buildSegment(seg, dirty) end
		end
		if _notify and next(dirty) then (_notify :: any)(dirty) end
		flushGround()
	end
	local function addStop(inst: Instance)
		if not inst:IsA("Model") then return end
		local cf = inst:GetPivot()
		local bay = inst:GetAttribute("BusBayLength")
		local depth = inst:GetAttribute("BusBayDepth")
		local old = _stops[inst]
		if old then unindexStop(inst, old.pos) end
		_stops[inst] = { pos = cf.Position, half = (if typeof(bay) == "number" then bay else STOP_LENGTH) * 0.5,
			bay = if typeof(depth) == "number" then depth else nil }
		indexStop(inst, cf.Position)
		stopsChanged(cf.Position)
	end
	CollectionService:GetInstanceAddedSignal("BusStop"):Connect(addStop)
	CollectionService:GetInstanceRemovedSignal("BusStop"):Connect(function(inst: Instance)
		local st = _stops[inst]
		if not st then return end
		_stops[inst] = nil
		unindexStop(inst, st.pos)
		stopsChanged(st.pos)
	end)
	for _, inst in CollectionService:GetTagged("BusStop") do
		if inst:IsA("Model") then
			local bay = inst:GetAttribute("BusBayLength")
			local depth = inst:GetAttribute("BusBayDepth")
			local pos = inst:GetPivot().Position
			_stops[inst] = { pos = pos, half = (if typeof(bay) == "number" then bay else STOP_LENGTH) * 0.5,
				bay = if typeof(depth) == "number" then depth else nil }
			indexStop(inst, pos)
		end
	end
	DataCache.On("segments", onSegments)
	DataCache.On("nodes", function()
		-- node positions only move with their segments, which arrive in the same edit
	end)
	onSegments(DataCache.GetSegments())
end

return RoadPieces
