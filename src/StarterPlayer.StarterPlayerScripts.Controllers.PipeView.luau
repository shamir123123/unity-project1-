--!strict
-- PipeView -- the water view's look (user 2026-10-07, after Cities: Skylines 2).
--
--   * The city in sepia, lit as at noon, the ground and the road surfaces see-through (UndergroundView --
--     the same view the road tool's tunnels use), and the mains drawn where they really are: UNDER the ground
--     (user: "it needs to be underground, there's no way around it").
--   * The mains are real lit parts -- shaded, with depth -- in their own colours, water teal and sewage yellow,
--     water riding above sewage. The sepia takes a part's own colour, so a Highlight per colour lays it back
--     over them, half see-through so the shading shows, no outline: no glow.
--   * Every turn is a bend, not two straight pipes crossing: inside a run, where chained runs meet and where
--     two roads meet at a corner (user: "when we do a turn it needs to smoothly bend").
--   * Every building a main reaches has its service lines: straight off the mains into the middle of the
--     building, a dot where they rise into it, drawn ON TOP so they read through the roof (user 2026-10-07,
--     after CS2). Each takes the lines it needs -- a sewage works gets a water line, its sewage goes in through
--     its tap. What a building is short of is its badge (NoPowerView); nothing is painted orange any more.
--
-- Drawn: the mains under the nearest ROAD_CAP roads (round joints where roads meet, an end drum at a dead
-- end), every hand-drawn run (re-traced from the server's pieces so its corners can bend, a drum where it
-- stops), and the standpipe under each tower or plant -- under a tower's CENTRE -- with its link to the road
-- main that feeds it. The server's own parts stay hidden (they still take the bulldozer's clicks). All of it
-- underground: water BURY (3 m) down, sewage RISE under that. Rebuilt once a second while open; nothing runs
-- while it is closed.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataCache = require(ReplicatedStorage:WaitForChild("DataCache"))
local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local PipeArt = require(ReplicatedStorage.City.PipeArt)
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)
local UndergroundView = require(script.Parent:WaitForChild("UndergroundView"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))

local PipeView = {}

export type Kind = "Water" | "Sewage" | "Bad" | "WaterLine" | "SewageLine"

local BAD = Color3.fromRGB(232, 96, 90)
local KIND_COLOR: { [Kind]: Color3 } = { Water = PipeArt.WATER, Sewage = PipeArt.SEWAGE, Bad = BAD }
-- The service lines' own colour folders: drawn on top of everything, so a line reads through the building it feeds.
local LINE_COLOR: { [Kind]: Color3 } = { WaterLine = PipeArt.WATER, SewageLine = PipeArt.SEWAGE }
local LINE: { [string]: Kind } = { Water = "WaterLine", Sewage = "SewageLine" }
-- What the parts themselves are painted: light, so their shading reads strongly under the colour.
local BODY = Color3.fromRGB(236, 236, 236)
local FILL = 0.5 -- the colour's transparency over the shaded part

local REACH = ServiceTypes.PipeReach
local BURY = ServiceTypes.PipeDepth
local THICK = PipeArt.ROAD_THICK
local LAT = PipeArt.ROAD_LAT
local RISE = PipeArt.WATER_RISE
-- Every water main lies BURY under the surface (3 m, user 2026-10-07: "needs to go down at least three
-- metres"), sewage RISE under that. A road's surface here is its stored height, itself 0.5-3 studs under the
-- drawn top (measured 2026-10-07), so a road main lies deeper than that, never shallower.
local ROAD_DEEP = BURY + RISE
local BEND_R = 6                  -- studs: the radius a main turns on
local BEND_STEP = math.rad(15)    -- one piece of bend per this much turn
local BEND_MIN = math.rad(10)     -- gentler than this, the pieces' own overlap already reads as a curve
local JOIN = 4                    -- run ends this close are one joint (a trench's two mains sit <= 3.4 apart across a corner)
local TIE = 12                    -- a run end this close to a road's main runs on into it
local BRANCH_THICK = 0.9
local BRANCH_GAP = 1.2   -- the water and sewage service lines run this far apart
local ROAD_CAP = 220      -- nearest roads whose mains are drawn
local ROAD_STEP = 24      -- studs between samples along a road
local BRANCH_CAP = 360    -- nearest buildings given service lines
local BRANCH_RANGE = 1400 -- ...within this of the camera's focus
local HASH = 64
-- When it redraws: the moment a pipe or a road changes (a run just laid shows at once -- it used to wait for
-- the 5 s timer, "the pipe placement is a little slow"), when the camera has moved far enough for other roads
-- to be the nearest, or now and then for the buildings' own water state. Nothing else re-checks anything.
local CHECK = 0.2        -- s between checks while open (a flag and a distance: cheap)
local MOVE_REDRAW = 48   -- the camera moved this far (studs)
local STALE_REDRAW = 10  -- s: new buildings, and which ones went dry, catch up

local _on = false
local _root: Folder? = nil
-- Models, not Folders: a Highlight adorns a Model or a part, and silently draws nothing on a Folder.
local _folders: { [Kind]: Model } = {}
local _pools: { [Kind]: { parts: { BasePart }, used: number } } = {}
local _conn: RBXScriptConnection? = nil
local _nextAt = 0
local _lastEye: Vector3? = nil
local _lastAt = 0
local _boxes: { [Model]: { pivot: CFrame, cf: CFrame, size: Vector3 } } = setmetatable({}, { __mode = "k" }) :: any
local _dirty = false              -- a pipe was laid or removed: redraw at the next check
local _roadRev: number? = nil     -- DataCache's road revision at the last redraw
local _watched: Instance? = nil   -- the WaterPipes folder being listened to
local _watchConns: { RBXScriptConnection } = {}

local function cityFolder(name: string): Instance?
	local city = Workspace:FindFirstChild("_City")
	return city and city:FindFirstChild(name)
end

local function up(kind: Kind): Vector3
	return if kind == "Water" then Vector3.new(0, RISE, 0) else Vector3.zero
end

-- == Pools =====================================================================
local function take(kind: Kind): BasePart
	local pool = _pools[kind]
	pool.used += 1
	local p = pool.parts[pool.used]
	if p then return p end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = _folders[kind]
	pool.parts[pool.used] = part
	return part
end

local function trimAll()
	for _, pool in _pools do
		for i = #pool.parts, pool.used + 1, -1 do
			pool.parts[i]:Destroy()
			pool.parts[i] = nil
		end
	end
end

local function pipe(kind: Kind, a: Vector3, b: Vector3, thick: number, offset: number)
	if not PipeArt.shapePipe(take(kind), a, b, BODY, thick, offset) then
		_pools[kind].used -= 1 -- zero length: hand the slot back
	end
end

local function ball(kind: Kind, at: Vector3, d: number)
	PipeArt.shapeBall(take(kind), at, BODY, d)
end

local function stand(kind: Kind, at: Vector3, d: number, h: number)
	PipeArt.shapeStand(take(kind), at, BODY, d, h)
end

-- A copy of one of the server's standpipes, in its colour's folder (the server lays each at its own main's depth).
local function mirror(kind: Kind, src: BasePart)
	local p = take(kind) :: Part
	p.Shape = if src:IsA("Part") then (src :: Part).Shape else Enum.PartType.Block
	p.Material = Enum.Material.SmoothPlastic
	p.Color = BODY
	p.Size = src.Size
	p.CFrame = src.CFrame
end

-- == Bends =====================================================================
local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else Vector3.xAxis
end

local function flatLen(v: Vector3): number
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

local function perpOf(t: Vector3): Vector3
	return Vector3.new(-t.Z, 0, t.X)
end

-- The polyline with every corner sharper than BEND_MIN replaced by a bend of radius BEND_R (less where a
-- leg is too short for it). The bend is a quadratic curve through the corner -- near enough a circle at
-- these angles, and it carries the height along with it.
local function rounded(pts: { Vector3 }): { Vector3 }
	if #pts < 3 then return pts end
	local out = { pts[1] }
	for i = 2, #pts - 1 do
		local a, b, c = pts[i - 1], pts[i], pts[i + 1]
		local la, lc = flatLen(a - b), flatLen(c - b)
		local turn = math.pi - math.acos(math.clamp(flatUnit(a - b):Dot(flatUnit(c - b)), -1, 1))
		if turn < BEND_MIN or la < 1e-3 or lc < 1e-3 then
			out[#out + 1] = b
			continue
		end
		local t = math.min(BEND_R * math.tan(turn * 0.5), la * 0.5, lc * 0.5)
		local t1, t2 = b + (a - b) * (t / la), b + (c - b) * (t / lc)
		local n = math.max(2, math.ceil(turn / BEND_STEP))
		for k = 0, n do
			local s = k / n
			out[#out + 1] = t1 * ((1 - s) * (1 - s)) + b * (2 * (1 - s) * s) + t2 * (s * s)
		end
	end
	out[#out + 1] = pts[#pts]
	return out
end

-- A main along `pts`, bent at every corner. Each piece is cut exactly to its two ends and a ball of the same
-- diameter sits on every joint, so a bend reads as one smooth pipe (PipeArt's half-diameter overlap stuck
-- out as a ridge on the outside of every bend).
local function path(kind: Kind, pts: { Vector3 }, thick: number)
	local r = rounded(pts)
	for k = 1, #r - 1 do
		local p = take(kind)
		if PipeArt.shapePipe(p, r[k], r[k + 1], BODY, thick, 0) then
			p.Size = Vector3.new((r[k + 1] - r[k]).Magnitude, thick, thick)
		else
			_pools[kind].used -= 1
		end
		if k > 1 then ball(kind, r[k], thick) end
	end
end

-- == Road mains ================================================================
type Sample = { pos: Vector3, dir: Vector3, side: number } -- a point on a road's centreline at sewage depth, its heading, its water side (roadSide)

local function endKey(p: Vector3): string
	return string.format("%d|%d", math.round(p.X / 2), math.round(p.Z / 2))
end

-- Which side of a road its water main runs. Fixed by the road's own heading -- not by which end it
-- was drawn from -- so a street laid in pieces from both ends keeps water on one side all the way
-- (by the segment's raw direction the mains swapped sides at every piece drawn the other way).
-- ponytail: a road that curls past north-south can still flip at a joint; key it by chain if that shows.
function PipeView.roadSide(seg: any): number
	local c = seg.p3 - seg.p0
	if math.abs(c.X) > 1e-3 then return if c.X > 0 then 1 else -1 end
	return if c.Z >= 0 then 1 else -1
end

-- Where line P + s*d meets line Q + u*e (flat); nil when they run parallel.
local function meet(P: Vector3, d: Vector3, Q: Vector3, e: Vector3): Vector3?
	local den = d.X * e.Z - d.Z * e.X
	if math.abs(den) < 0.15 then return nil end
	local sx = ((Q.X - P.X) * e.Z - (Q.Z - P.Z) * e.X) / den
	return Vector3.new(P.X + d.X * sx, P.Y, P.Z + d.Z * sx)
end

-- One road end at a node: its position (sewage depth), the way it leads out of the node, and where its
-- two mains cross the node line. Every road's ends go in, drawn or not: an undrawn neighbour still shapes
-- the joint and keeps a junction from reading as a dead end.
type End = { seg: any, tip: Vector3, out: Vector3, lat: { Water: Vector3, Sewage: Vector3 } }

local function endOf(seg: any, atStart: boolean): End
	local p = if atStart then seg.p0 else seg.p3
	local out = flatUnit(if atStart then seg.p1 - seg.p0 else seg.p2 - seg.p3)
	local travel = if atStart then out else -out -- the road's own direction there
	local side = PipeView.roadSide(seg)
	local tip = Vector3.new(p.X, p.Y - ROAD_DEEP, p.Z)
	local pp = perpOf(travel)
	return { seg = seg, tip = tip, out = out,
		lat = { Water = tip - pp * (LAT * side) + up("Water"), Sewage = tip + pp * (LAT * side) } }
end

-- Every road end at one node, joined the way CS2 joins them: a straight-through pair is the trunk and
-- everything else runs into the trunk's matching main with a round joint; a corner BENDS round from one
-- road to the other (the trunk end draws the whole bend). Water rides RISE above sewage, so a main
-- crossing the other one passes over or under it untouched.
local function drawNode(ends: { End }, drawn: { [any]: boolean })
	if #ends == 1 then
		local e = ends[1]
		if not drawn[e.seg] then return end
		for _, kind in { "Water", "Sewage" } :: { Kind } do
			stand(kind, e.lat[kind], THICK * PipeArt.STAND_SCALE, THICK * 1.1)
		end
		return
	end
	-- the trunk: the most nearly straight-through pair, else simply the first end
	local trunk, mate = ends[1], nil :: End?
	local best = -0.8
	for i = 1, #ends do
		for j = i + 1, #ends do
			local d = ends[i].out:Dot(ends[j].out)
			if d < best then best, trunk, mate = d, ends[i], ends[j] end
		end
	end
	-- with no straight pair the trunk bends round into the next end, which then draws nothing itself
	local partner = if mate then nil else (if ends[2] == trunk then ends[1] else ends[2])
	for _, e in ends do
		if not drawn[e.seg] then continue end
		if e == partner and drawn[trunk.seg] then continue end
		for _, kind in { "Water", "Sewage" } :: { Kind } do
			if e == trunk and mate then
				ball(kind, e.lat[kind], THICK * 1.15) -- straight through: a joint, the main runs on
			elseif e == mate then
				ball(kind, e.lat[kind], THICK * 1.15)
			elseif e == trunk and partner then
				local x = meet(e.lat[kind], e.out, partner.lat[kind], partner.out)
				if x then path(kind, { e.lat[kind], x, partner.lat[kind] }, THICK) end
			else
				local x = meet(e.lat[kind], e.out, trunk.lat[kind], trunk.out)
				if x then
					pipe(kind, e.lat[kind], x, THICK, 0)
					ball(kind, x, THICK * 1.25)
				else
					ball(kind, e.lat[kind], THICK * 1.15)
				end
			end
		end
	end
end

-- The mains under the nearest roads. Returns the centreline samples, hashed, for the service lines.
local function drawRoads(eye: Vector3): { [string]: { Sample } }
	local segs = DataCache.GetSegments()
	local nodes: { [string]: { End } } = {}
	local near: { { d: number, seg: any } } = {}
	for _, seg in segs do
		if typeof(seg.p0) ~= "Vector3" then continue end
		for _, atStart in { true, false } do
			local k = endKey(if atStart then seg.p0 else seg.p3)
			local list = nodes[k]
			if not list then list = {}; nodes[k] = list end
			list[#list + 1] = endOf(seg, atStart)
		end
		near[#near + 1] = { d = ((seg.p0 + seg.p3) * 0.5 - eye).Magnitude, seg = seg }
	end
	table.sort(near, function(a, b) return a.d < b.d end)

	local hash: { [string]: { Sample } } = {}
	local drawn: { [any]: boolean } = {}
	for k = 1, math.min(#near, ROAD_CAP) do
		local seg = near[k].seg
		drawn[seg] = true
		local side = PipeView.roadSide(seg)
		local chord = (seg.p3 - seg.p0).Magnitude
		local steps = math.clamp(math.ceil(chord / ROAD_STEP), 1, 16)
		local prev: Vector3? = nil
		for t = 0, steps do
			local q = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t / steps)
			q = Vector3.new(q.X, q.Y - ROAD_DEEP, q.Z)
			if prev then
				pipe("Water", prev + up("Water"), q + up("Water"), THICK, -LAT * side)
				pipe("Sewage", prev, q, THICK, LAT * side)
				local flat = Vector3.new(q.X - prev.X, 0, q.Z - prev.Z)
				if flat.Magnitude > 0.05 then
					local s: Sample = { pos = (prev + q) * 0.5, dir = flat.Unit, side = side }
					local hk = string.format("%d|%d", math.floor(s.pos.X / HASH), math.floor(s.pos.Z / HASH))
					local cell = hash[hk]
					if not cell then cell = {}; hash[hk] = cell end
					cell[#cell + 1] = s
					cell[#cell + 1] = { pos = q, dir = s.dir, side = side }
				end
			end
			prev = q
		end
	end
	for _, ends in nodes do drawNode(ends, drawn) end
	return hash
end

-- == Hand-drawn runs ===========================================================
-- The server lays a run as straight pieces between samples, and a chained run as one run per click, so
-- every corner arrives as two pieces meeting at an angle. Each run's centreline is re-traced per colour
-- from its pieces and laid at the view's own depth, following the ground up and down (user 2026-10-07:
-- "it should only go down or up depending on the terrain"; the server's pieces sink deeper under a road,
-- which drew as a dip and a quick rise). Runs that meet end to end (and only two of them) are joined into
-- one line, and the line is drawn bent at every corner. An end runs into the road main beside it, into the
-- standpipe it was drawn to, into the side of another run -- or, where the server put its loose-end drum,
-- stops at a drum down at the pipe's depth. Nothing climbs to the surface.
type Line = { kind: Kind, thick: number, pts: { Vector3 } }
type Tap = { pos: Vector3, kind: Kind }

local function kindOf(m: BasePart, owner: Instance?): Kind
	local tapKind = owner and owner:GetAttribute("TapKind")
	if tapKind == "Sewage" then return "Sewage" end
	if tapKind == "Water" then return "Water" end
	return if m.Color.R > m.Color.B then "Sewage" else "Water"
end

-- A piece's two ends: shapePipe stretched it half a diameter past them.
local function pieceEnds(p: BasePart): (Vector3, Vector3)
	local half = (p.Size.X - p.Size.Y * 0.5) * 0.5
	local axis = p.CFrame.RightVector * half
	return p.Position - axis, p.Position + axis
end

local function traceRun(run: Model, lines: { Line })
	local byKind: { [Kind]: { BasePart } } = {}
	for _, p in run:GetChildren() do
		if not p:IsA("BasePart") then continue end
		local k = kindOf(p, run)
		local list = byKind[k]
		if not list then list = {}; byKind[k] = list end
		list[#list + 1] = p
	end
	for kind, pieces in byKind do
		local a, b = pieceEnds(pieces[1])
		if pieces[2] and (a - pieces[2].Position).Magnitude < (b - pieces[2].Position).Magnitude then a, b = b, a end
		local flat = { a, b }
		for i = 2, #pieces do
			local c, d = pieceEnds(pieces[i])
			local last = flat[#flat]
			flat[#flat + 1] = if (c - last).Magnitude > (d - last).Magnitude then c else d
		end
		local pts = table.create(#flat)
		for i, q in flat do
			local ground = CursorRay.terrainY(q.X, q.Z) or (q.Y + BURY)
			pts[i] = Vector3.new(q.X, ground - ROAD_DEEP, q.Z) + up(kind)
		end
		lines[#lines + 1] = { kind = kind, thick = pieces[1].Size.Y, pts = pts }
	end
end

-- Join every pair of same-colour lines whose ends meet with no third end there, through the corner the
-- two would make (where their end pieces' lines cross). ponytail: O(n^2) per join -- a city has a
-- handful of hand-drawn runs (roads carry the rest); bucket the ends if that ever changes.
local function joinLines(lines: { Line })
	local function endsNear(p: Vector3, kind: Kind): { { line: number, atEnd: boolean } }
		local hits = {}
		for i, l in lines do
			if l.kind ~= kind then continue end
			if flatLen(l.pts[1] - p) <= JOIN then hits[#hits + 1] = { line = i, atEnd = false } end
			if flatLen(l.pts[#l.pts] - p) <= JOIN then hits[#hits + 1] = { line = i, atEnd = true } end
		end
		return hits
	end
	local function oriented(l: Line, atEnd: boolean): { Vector3 } -- the line running INTO that end
		if atEnd then return l.pts end
		local r = table.create(#l.pts)
		for i = #l.pts, 1, -1 do r[#r + 1] = l.pts[i] end
		return r
	end
	local merged = true
	while merged do
		merged = false
		for i, l in lines do
			for _, atEnd in { true, false } do
				local p = if atEnd then l.pts[#l.pts] else l.pts[1]
				local hits = endsNear(p, l.kind)
				if #hits ~= 2 then continue end
				local other = if hits[1].line == i and hits[1].atEnd == atEnd then hits[2] else hits[1]
				if other.line == i then continue end -- a loop closing on itself
				local a = oriented(l, atEnd)
				local o = lines[other.line]
				local b = oriented(o, other.atEnd) -- runs INTO the joint too; reversed below
				local pa, pb = a[#a], b[#b]
				local corner = meet(pa, flatUnit(pa - a[#a - 1]), pb, flatUnit(pb - b[#b - 1]))
				local joint = if corner and flatLen(corner - pa) <= JOIN * 3 then
					Vector3.new(corner.X, (pa.Y + pb.Y) * 0.5, corner.Z) else (pa + pb) * 0.5
				local pts = table.create(#a + #b)
				for k = 1, #a - 1 do pts[#pts + 1] = a[k] end
				pts[#pts + 1] = joint
				for k = #b - 1, 1, -1 do pts[#pts + 1] = b[k] end
				lines[i] = { kind = l.kind, thick = l.thick, pts = pts }
				table.remove(lines, other.line)
				merged = true
				break
			end
			if merged then break end
		end
	end
end

local nearestSample: (hash: { [string]: { Sample } }, p: Vector3) -> (Sample?, number)

-- The point on the drawn road main of `kind` beside `p`, when it lies within `reach`; nil otherwise.
local function tieOf(hash: { [string]: { Sample } }, kind: Kind, p: Vector3, reach: number): Vector3?
	local s, dist = nearestSample(hash, p)
	if not s or dist > reach + LAT then return nil end
	local lat = if kind == "Water" then -LAT else LAT
	local base = s.pos + perpOf(s.dir) * (lat * s.side) + up(kind)
	local onMain = base + s.dir * (p - base):Dot(s.dir)
	if flatLen(onMain - p) > reach then return nil end
	return onMain
end

-- The hand-drawn runs, bent, and the standpipes under the works with the link each takes to its road.
local function drawServerPipes(hash: { [string]: { Sample } })
	local f = cityFolder("WaterPipes")
	if not f then return end
	-- The server's own pieces never show here: this draws them. Hidden on every pass rather than trusted to
	-- WaterPipeController's watch -- through the see-through ground a missed piece is a second pipe.
	for _, d in f:GetDescendants() do
		if d:IsA("BasePart") and d.LocalTransparencyModifier < 1 then d.LocalTransparencyModifier = 1 end
	end
	local lines: { Line } = {}
	local drums: { Vector3 } = {} -- where the server put a loose-end drum
	local taps: { Tap } = {}
	for _, c in f:GetChildren() do
		if c:IsA("Model") and c.Name == "Pipe" then
			traceRun(c, lines)
		elseif c.Name == "PipeEnds" then
			for _, m in c:GetChildren() do
				if m:IsA("Model") then drums[#drums + 1] = (m:GetBoundingBox()).Position end
			end
		elseif c.Name == "Taps" then
			for _, m in c:GetChildren() do
				if not m:IsA("Model") then continue end
				local body = m.PrimaryPart
				local k = m:GetAttribute("TapKind")
				if body and (k == "Water" or k == "Sewage") then
					taps[#taps + 1] = { pos = Vector3.new(body.Position.X, 0, body.Position.Z), kind = k :: Kind }
				end
				for _, p in m:GetDescendants() do
					if p:IsA("BasePart") and p.Name ~= "Flange" and p.Name ~= "Collar" then mirror(kindOf(p, m), p) end
				end
			end
		end
	end

	joinLines(lines)
	for _, l in lines do
		for _, first in { true, false } do
			local p = if first then l.pts[1] else l.pts[#l.pts]
			local tie = tieOf(hash, l.kind, p, TIE)
			if tie then
				if first then table.insert(l.pts, 1, tie) else l.pts[#l.pts + 1] = tie end
				ball(l.kind, tie, THICK * 1.25)
				continue
			end
			local atTap = false
			for _, t in taps do
				if t.kind == l.kind and flatLen(t.pos - p) <= JOIN then atTap = true; break end
			end
			if atTap then continue end -- it runs into the standpipe's body
			local loose = false
			for _, d in drums do
				if flatLen(d - p) <= JOIN then loose = true; break end
			end
			if loose then
				stand(l.kind, p, l.thick * PipeArt.STAND_SCALE, l.thick * 1.1) -- the station where it stops
			else
				ball(l.kind, p, l.thick * 1.15) -- into the side of another run
			end
		end
		path(l.kind, l.pts, l.thick)
	end


end

-- == Service lines ==============================================================
local function boxOf(m: Model): (CFrame, Vector3)
	local pivot = m:GetPivot()
	local b = _boxes[m]
	if b and b.pivot == pivot then return b.cf, b.size end
	local cf, size = m:GetBoundingBox()
	_boxes[m] = { pivot = pivot, cf = cf, size = size }
	return cf, size
end

function nearestSample(hash: { [string]: { Sample } }, p: Vector3): (Sample?, number)
	local cx, cz = math.floor(p.X / HASH), math.floor(p.Z / HASH)
	local best: Sample? = nil
	local bestD = math.huge
	for dx = -1, 1 do
		for dz = -1, 1 do
			local cell = hash[string.format("%d|%d", cx + dx, cz + dz)]
			if not cell then continue end
			for _, s in cell do
				local ddx, ddz = s.pos.X - p.X, s.pos.Z - p.Z
				local d = ddx * ddx + ddz * ddz
				if d < bestD then best, bestD = s, d end
			end
		end
	end
	return best, math.sqrt(bestD)
end

-- Which lines a building takes: water, sewage -- what it draws, and for a works the main its own tap feeds or
-- drains (a tower's water, a plant's sewage). Both run the same way into the middle and end side by side
-- (user 2026-10-07: "they need to end on the same spot").
local function linesFor(m: Model, folder: string): (boolean, boolean)
	if folder == "EmergencyServices" then
		local spec = ServiceTypes.get(tostring(m:GetAttribute("ServiceType") or "")) :: any
		if not spec then return false, false end
		return ServiceTypes.usesUtility(spec, "Water") or (tonumber(spec.waterOutput) or 0) > 0,
			ServiceTypes.usesUtility(spec, "Sewage") or (tonumber(spec.sewageCapacity) or 0) > 0
	elseif folder == "Transit" then
		local spec = (TransitTypes.getDepot(m.Name) or TransitTypes.getStop(m.Name)) :: any
		local wet = spec ~= nil and (tonumber(spec.waterUse) or 0) > 0
		return wet, wet
	end
	return true, true
end

-- The road a building is connected to: the nearest road sample to its FOOTPRINT, not to its middle (user
-- 2026-10-07) -- a solar farm's middle is ~430 studs from the road at its gate. Returns that sample and the
-- point of the footprint nearest it.
local function roadOfBox(hash: { [string]: { Sample } }, cf: CFrame, size: Vector3): (Sample?, Vector3)
	local hx, hz = size.X * 0.5, size.Z * 0.5
	local r = math.max(hx, hz) + REACH
	local c = cf.Position
	local best: Sample? = nil
	local bestD, bestP = math.huge, c
	for cx = math.floor((c.X - r) / HASH), math.floor((c.X + r) / HASH) do
		for cz = math.floor((c.Z - r) / HASH), math.floor((c.Z + r) / HASH) do
			local cell = hash[string.format("%d|%d", cx, cz)]
			if not cell then continue end
			for _, smp in cell do
				local l = cf:PointToObjectSpace(smp.pos)
				local px, pz = math.clamp(l.X, -hx, hx), math.clamp(l.Z, -hz, hz)
				local d = math.sqrt((l.X - px) ^ 2 + (l.Z - pz) ^ 2)
				if d < bestD then best, bestD, bestP = smp, d, cf:PointToWorldSpace(Vector3.new(px, 0, pz)) end
			end
		end
	end
	if bestD > REACH then return nil, c end
	return best, bestP
end

-- Which way a works faces: the road it was placed against (ServiceTypes.hookOf's convention -- the front edge
-- is the pivot's +Z). nil for anything else: it takes the nearest road it squares onto.
local function frontOf(m: Model, folder: string): Vector3?
	if folder ~= "EmergencyServices" then return nil end
	if not ServiceTypes.get(tostring(m:GetAttribute("ServiceType") or "")) then return nil end
	local z = m:GetPivot().ZVector
	return flatUnit(Vector3.new(z.X, 0, z.Z))
end

-- Where the service lines leave the main: SQUARE off the road (user 2026-10-07: "only 90 degrees", from the road
-- it snapped to). The road sample whose stretch the building's middle meets at a right angle -- in front of a
-- works, else the nearest -- and that right-angle foot. nil when none does (a road that ends at the gate).
local function squareFoot(hash: { [string]: { Sample } }, c: Vector3, size: Vector3, front: Vector3?): (Sample?, Vector3?)
	local reach = REACH + math.max(size.X, size.Z) * 0.5
	local best: Sample?, bestFoot: Vector3? = nil, nil
	local bestD = math.huge
	for cx = math.floor((c.X - reach) / HASH), math.floor((c.X + reach) / HASH) do
		for cz = math.floor((c.Z - reach) / HASH), math.floor((c.Z + reach) / HASH) do
			for _, smp in hash[string.format("%d|%d", cx, cz)] or {} do
				local rel = Vector3.new(c.X - smp.pos.X, 0, c.Z - smp.pos.Z)
				local along = rel:Dot(smp.dir)
				if math.abs(along) > ROAD_STEP * 0.5 + 0.5 then continue end -- the right angle lands off this stretch
				local toRoad = smp.dir * along - rel -- from the middle, square onto the road
				local d = toRoad.Magnitude
				if d > reach or d >= bestD then continue end
				if front and d > 1e-3 and (toRoad / d):Dot(front) < 0.7 then continue end
				best, bestD, bestFoot = smp, d, smp.pos + smp.dir * along
			end
		end
	end
	return best, bestFoot
end

-- The service lines from the street into each building near the camera: off the mains of the road it is
-- connected to, square to that road, straight into its middle, a dot where they rise into it.
local function drawBuildings(hash: { [string]: { Sample } }, eye: Vector3)
	local list: { { m: Model, d: number, folder: string } } = {}
	for _, name in { "ZonedBuildings", "EmergencyServices", "Schools", "Transit" } do
		local f = cityFolder(name)
		if not f then continue end
		for _, m in f:GetChildren() do
			if not m:IsA("Model") then continue end
			local d = (m:GetPivot().Position - eye).Magnitude
			if d <= BRANCH_RANGE then list[#list + 1] = { m = m, d = d, folder = name } end
		end
	end
	table.sort(list, function(a, b) return a.d < b.d end)

	for i = 1, math.min(#list, BRANCH_CAP) do
		local m = list[i].m
		if m:GetAttribute("Abandoned") then continue end
		local wantWater, wantSewage = linesFor(m, list[i].folder)
		if not (wantWater or wantSewage) then continue end
		local cf, size = boxOf(m)
		local c = cf.Position
		local front = frontOf(m, list[i].folder)
		local s, foot = squareFoot(hash, c, size, front)
		if not s and front then s, foot = squareFoot(hash, c, size, nil) end -- nothing in front: any road it squares onto
		if not s then
			-- no road meets it square (one ends at its gate): straight on from the road's nearest point
			local near = roadOfBox(hash, cf, size)
			if not near then continue end
			s, foot = near, near.pos
		end
		local perp = perpOf((s :: Sample).dir)
		for _, e in { { kind = "Water" :: Kind, want = wantWater, lat = -LAT, gap = -BRANCH_GAP },
			{ kind = "Sewage" :: Kind, want = wantSewage, lat = LAT, gap = BRANCH_GAP } } do
			if not e.want then continue end
			local from = foot + perp * (e.lat * s.side) + s.dir * e.gap + up(e.kind)
			local to = Vector3.new(c.X, foot.Y, c.Z) + s.dir * e.gap + up(e.kind)
			if flatLen(to - from) <= 0.5 then continue end -- the building stands on the main
			pipe(LINE[e.kind], from, to, BRANCH_THICK, 0)
			ball(LINE[e.kind], to, BRANCH_THICK * 1.8)
		end
	end
end

local function refresh()
	for _, pool in _pools do pool.used = 0 end
	local cam = Workspace.CurrentCamera
	local eye = if cam then cam.Focus.Position else Vector3.zero
	_lastEye, _lastAt = eye, os.clock()
	_dirty = false
	_roadRev = DataCache.GetRoadRevision()
	local hash = drawRoads(eye)
	drawServerPipes(hash)
	drawBuildings(hash, eye)
	trimAll()
end

-- The server's WaterPipes folder is rebuilt on a city load, so the listener follows whichever one stands.
local function watchPipes()
	local f = cityFolder("WaterPipes")
	if f == _watched then return end
	for _, c in _watchConns do c:Disconnect() end
	table.clear(_watchConns)
	_watched = f
	if not f then return end
	local function changed() _dirty = true end
	_watchConns[1] = f.DescendantAdded:Connect(changed)
	_watchConns[2] = f.DescendantRemoving:Connect(changed)
end

local function unwatchPipes()
	for _, c in _watchConns do c:Disconnect() end
	table.clear(_watchConns)
	_watched = nil
end

-- == Public ====================================================================

-- The colour folder for a kind, for the pipe tool's drag ghost. nil while the view is closed.
function PipeView.folder(kind: Kind): Model?
	return _folders[kind]
end

function PipeView.isActive(): boolean
	return _on
end

function PipeView.refreshNow()
	if _on then refresh() end
end

function PipeView.setActive(on: boolean)
	if on == _on then return end
	_on = on
	if on then
		local root = Instance.new("Folder")
		root.Name = "PipeView"
		_root = root
		for kind, color in KIND_COLOR do
			local f = Instance.new("Model")
			f.Name = kind
			f.Parent = root
			local hl = Instance.new("Highlight")
			hl.Name = "Colour"
			hl.Adornee = f
			hl.FillColor = color
			hl.FillTransparency = FILL
			hl.OutlineTransparency = 1
			hl.DepthMode = Enum.HighlightDepthMode.Occluded
			hl.Parent = f
			_folders[kind] = f
			_pools[kind] = { parts = {}, used = 0 }
		end
		for kind, color in LINE_COLOR do
			local f = Instance.new("Model")
			f.Name = kind
			f.Parent = root
			local hl = Instance.new("Highlight")
			hl.Name = "Colour"
			hl.Adornee = f
			hl.FillColor = color
			hl.FillTransparency = 0.15
			hl.OutlineTransparency = 1
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.Parent = f
			_folders[kind] = f
			_pools[kind] = { parts = {}, used = 0 }
		end
		root.Parent = Workspace
		UndergroundView.setActive("pipes", true)
		watchPipes()
		refresh()
		_nextAt = os.clock() + CHECK
		_conn = RunService.Heartbeat:Connect(function()
			if os.clock() < _nextAt then return end
			_nextAt = os.clock() + CHECK
			watchPipes()
			local cam = Workspace.CurrentCamera
			local eye = if cam then cam.Focus.Position else Vector3.zero
			local moved = not _lastEye or (eye - (_lastEye :: Vector3)).Magnitude >= MOVE_REDRAW
			if _dirty or moved or DataCache.GetRoadRevision() ~= _roadRev or os.clock() - _lastAt >= STALE_REDRAW then
				refresh()
			end
		end)
	else
		if _conn then _conn:Disconnect(); _conn = nil end
		unwatchPipes()
		UndergroundView.setActive("pipes", false)
		if _root then _root:Destroy(); _root = nil end
		table.clear(_folders)
		table.clear(_pools)
	end
end

return PipeView
