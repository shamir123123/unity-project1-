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
local RoadMeshBuilder = require(Road:WaitForChild("RoadMeshBuilder"))
local RoadRules = require(Road:WaitForChild("RoadRules"))
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
-- Bus stops (TransitService tags them BusStop): the verge in front of one is paved.
local STOP_LENGTH = 12 -- a kerbside stop with no bay: its shelter's stretch of kerb
local STOP_REACH = 12  -- how far beyond the roadway a stop may stand and still be on this road
local _stops: { [Instance]: { pos: Vector3, half: number, bay: number? } } = {}

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
	return if caps then caps else nil
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

local function setPiece(key: string, specs: { any }?, dirty: { [string]: boolean })
	local old = _pieces[key]
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

-- How one road end is dressed by the plan of the node it meets.
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
	if plan.kind == "junction" then
		d.crosswalk = plan.crosswalk[i]
		d.stopAt = plan.stopAt[i]
		d.control = if _signals[plan.nodeId] then "signal" elseif plan.main and plan.main[i] then "none" else "yield"
		d.plain = RoadJunctionSolver.approachOf(plan, i)
		local arm = plan.arms[i]
		d.bulb = arm.buildOut ~= nil
		local moves: { [string]: boolean } = {}
		for j, other in plan.arms do
			-- no arrow into a road a car may not drive (a pedestrian street, a busway)
			local allowed = plan.specs[j] and plan.specs[j].allowedVehicles
			if j ~= i and not (allowed and not allowed.Car) then moves[movementOf(-arm.dir, other.dir)] = true end
		end
		local arrows = {}
		local sec = arm.sec
		for k, bd in sec.bands do
			if bd.k ~= "lane" or bd.d ~= -1 then continue end
			local only = bd.count == 1
			local dirs: any = {}
			if moves.straight then dirs.straight = true end
			if moves.left and (only or bd.ordinal == 1) then dirs.left = true end
			if moves.right and (only or bd.ordinal == bd.count) then dirs.right = true end
			-- the body sees the bands in the CURVE's frame; this arm's frame is mirrored at the end
			arrows[if atStart then k else (#sec.bands - k + 1)] = dirs
		end
		d.arrows = arrows
	elseif plan.kind == "ring" then
		d.crosswalk = plan.crosswalk[i]
		d.plain = plan.trims[i] + 8
	elseif plan.kind == "end" or plan.kind == "culdesac" then
		-- A dead end is where cars turn round: a U-turn arrow on every lane coming in (not at the
		-- map edge, where they drive on out of the city).
		d.cap = true
		local p = plan.pos
		if math.max(math.abs(p.X), math.abs(p.Z)) < HALF - 24 then
			d.stopAt = 0.01
			d.control = "none"
			d.uturnAll = RoadRules.getCrossingTurn()
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

-- Bus stops beside this road, along its curve (RoadGeometry.Stop).
local function stopsOn(seg: any, armS: any): { any }?
	if next(_stops) == nil then return nil end
	local reach = math.max(armS.sec.roadR, -armS.sec.roadL) + math.max(armS.sec.walkL, armS.sec.walkR) + STOP_REACH
	local out = {}
	for _, st in _stops do
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
		_covered["Junction_" .. nodeId] = nil
		_covered["DeadEnd_" .. nodeId] = nil
		_covered["Corner_" .. nodeId] = nil
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
			RoadGeometry.taper(b, plan, plan.specs[plan.taper.a])
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
local function onSegments(list: { any })
	local now: { [number]: any } = {}
	for _, s in list do now[s.id] = s end
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
	_seen = now
	if next(dirtyNodes) == nil and #removed == 0 then return end

	-- Road ends per node, rebuilt whole: cheap, and never stale. Every road, drawable or not: a
	-- node is only drawn here when ALL its roads are (solveNode).
	table.clear(_ends)
	for _, s in list do
		for _, e in { { s.startNode, true }, { s.endNode, false } } do
			local list2 = _ends[e[1]]
			if not list2 then
				list2 = {}
				_ends[e[1]] = list2
			end
			table.insert(list2, { seg = s, atStart = e[2] })
		end
	end

	local dirty: { [string]: boolean } = {}
	local dirtySegs: { [number]: any } = {}
	for nodeId in dirtyNodes do
		_plans[nodeId] = solveNode(nodeId)
		for _, e in (_ends[nodeId] or {}) do dirtySegs[e.seg.id] = e.seg end
	end
	-- Shifted roads (a highway running straight on past an exit): carry the forks' shifts along
	-- the network; every node at either end of a road whose shift changed solves again, until it
	-- settles (a fork downstream of another sees its stem shifted only on the next pass).
	for _ = 1, 4 do
		local nodes = {}
		for id, plan in _plans do nodes[id] = { plan = plan, ends = plan.ends } end
		local now = RoadJunctionSolver.carryShifts(nodes)
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
				_plans[nodeId] = solveNode(nodeId)
				for _, e in (_ends[nodeId] or {}) do dirtySegs[e.seg.id] = e.seg end
			end
		end
	end
	for _, id in removed do
		setPiece("s" .. id, nil, dirty)
		_covered["Segment_" .. id] = nil
	end
	for _, seg in dirtySegs do
		-- the far end's plan may never have been solved (first sight of this road)
		for _, nodeId in { seg.startNode, seg.endNode } do
			if _plans[nodeId] == nil and not dirtyNodes[nodeId] then _plans[nodeId] = solveNode(nodeId) end
		end
		buildSegment(seg, dirty)
	end
	-- a dead end follows its road onto (or off) the old path, wherever that was decided
	for _, seg in dirtySegs do
		for _, nodeId in { seg.startNode, seg.endNode } do
			local plan = _plans[nodeId]
			if plan and plan.kind == "end" then dirtyNodes[nodeId] = true end
		end
	end
	for nodeId in dirtyNodes do buildNode(nodeId, dirty) end
	if _notify and next(dirty) then (_notify :: any)(dirty) end
	flushGround()
end

-- == Public =======================================================================
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
	return _covered[name] == true
end

-- `notify(dirtyCells)` is called after every rebuild with the cells whose pieces changed.
function RoadPieces.start(notify: (dirty: { [string]: boolean }) -> ())
	_notify = notify
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
	local function stopsChanged(at: Vector3)
		local dirty: { [string]: boolean } = {}
		for _, seg in _seen do
			local near = false
			for _, q in { seg.p0, seg.p1, seg.p2, seg.p3 } do
				if (Vector3.new(q.X - at.X, 0, q.Z - at.Z)).Magnitude < 400 then near = true break end
			end
			if near then buildSegment(seg, dirty) end
		end
		if _notify and next(dirty) then (_notify :: any)(dirty) end
		flushGround()
	end
	local function addStop(inst: Instance)
		if not inst:IsA("Model") then return end
		local cf = inst:GetPivot()
		local bay = inst:GetAttribute("BusBayLength")
		local depth = inst:GetAttribute("BusBayDepth")
		_stops[inst] = { pos = cf.Position, half = (if typeof(bay) == "number" then bay else STOP_LENGTH) * 0.5,
			bay = if typeof(depth) == "number" then depth else nil }
		stopsChanged(cf.Position)
	end
	CollectionService:GetInstanceAddedSignal("BusStop"):Connect(addStop)
	CollectionService:GetInstanceRemovedSignal("BusStop"):Connect(function(inst: Instance)
		local st = _stops[inst]
		if not st then return end
		_stops[inst] = nil
		stopsChanged(st.pos)
	end)
	for _, inst in CollectionService:GetTagged("BusStop") do
		if inst:IsA("Model") then
			local bay = inst:GetAttribute("BusBayLength")
			local depth = inst:GetAttribute("BusBayDepth")
			_stops[inst] = { pos = inst:GetPivot().Position, half = (if typeof(bay) == "number" then bay else STOP_LENGTH) * 0.5,
				bay = if typeof(depth) == "number" then depth else nil }
		end
	end
	DataCache.On("segments", onSegments)
	DataCache.On("nodes", function()
		-- node positions only move with their segments, which arrive in the same edit
	end)
	onSegments(DataCache.GetSegments())
end

return RoadPieces
