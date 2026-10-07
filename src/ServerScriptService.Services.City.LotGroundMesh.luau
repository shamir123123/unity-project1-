--!strict
-- LotGroundMesh -- a lot's paving as ONE mesh that lies on the ground and meets its road exactly: on
-- a hill, round a bend, at a cul-de-sac. Pure geometry. The road comes in as its DRAWN edges
-- (edgesFromSpecs reads a road piece's RoadMeshSpecs -- the very strips every client bakes, so the
-- join is exact), the ground as a height function, and the paving goes out as RoadMeshBuilder
-- strips in a LotMesh model, which the client's RoadMeshView bakes like a road piece.
--
-- Lot frame: +Z toward the road, origin on the lot's level. A patch spans x0..x1 from zBack to the
-- road. Every station across it looks toward the road; the first road edge it meets -- the back of
-- the footway, or the asphalt's edge where there is none -- is where the paving ends, tucked a hair
-- under it. Between the back and that edge it DRAPES: rows every STEP studs, each vertex LIFT over
-- the ground, so it follows the lot's graded terrain instead of standing on it as a slab. Near the
-- road it never falls faster than 1 in APRON_RUN below the road's edge, so a lot below its street
-- meets the pavement on a smooth apron, not a step. One smoothing pass rounds off the creases a
-- terrain cell leaves (user: "no bumps"). A free edge (`soft`, and a front that met no road) sinks
-- into the ground over its last station, so it melts into the terrain instead of showing a lip.
-- `trap` turns the sides to the road's normal at each front corner, so the lots round a bend tile
-- edge to edge instead of opening wedges between them. A road crossing the patch deeper in (an old
-- parcel reaching over a road built since) ends it short of that road instead.
-- A SIDE patch (`square`, short `reach`) faces out of a lot's side: it only exists where a road
-- runs along that side within reach. `floorY` holds a patch up over a dip (a gap fill between
-- two lots).

local RoadMeshBuilder = require(game:GetService("ReplicatedStorage").Road.RoadMeshBuilder)

local LotGroundMesh = {}

-- A road edge segment: a (x, y, z), b (x, y, z), then the edge's unit tangent at a and at b (x, z),
-- so the normal along a curved kerb is smooth and two neighbours asking at one corner agree.
export type Edge = { number }

-- The visible ground height at world (x, z) -- exactly the surface the client draws.
export type Ground = (number, number) -> number

export type Params = {
	frame: CFrame, -- +Z toward the road; origin on the lot's level
	x0: number,
	x1: number,
	zFront: number, -- the lot's front line
	zBack: number,
	yBack: number?, -- the back edge rises to this over the lot level (a drive meeting a garage floor)
	trap: boolean?,
	reach: number?, -- furthest a road edge may stand in front (default REACH)
	square: boolean?, -- only a road met head-on counts (a side patch: not a bend grazing past)
	maxRise: number?, -- a road further above or below than this is left to its bank (a side patch)
	floorY: number?, -- no vertex below this: a gap fill bridges a dip between two lots
	flat: boolean?, -- with floorY: level behind the lot's front line; no join or apron reaches in
	bank: number?, -- ground rising more than this over the lot's level is a bank reaching into a
	-- flat yard (another road's embankment): the yard ends at its foot, sunk. Never the slope that
	-- joins the lot to its own road, nor a vertex an apron or garage floor holds up.
	drop: number?, -- ...and ground falling more than this below it (default `bank`) is a drop-off
	soft: string?, -- free edges that melt into the ground: any of "b" (back), "l" (x0), "r" (x1)
	color: Color3,
}

local STATION = 2 -- studs between stations across a patch
local STEP = 2 -- studs between rows along a station
local REACH = 16 -- furthest a road edge may stand in front of the lot
local BACK_REACH = 8 -- how far a footway may cut into the lot (the inside of a bend)
local MAX_RISE = 5 -- an edge further above or below the lot than this is a bridge, not its kerb
local WALL = 2.5 -- a road edge further than this off the ground before it stands on a wall
local KERB_LEAD = 1.5 -- ...measured this far in front of the edge, on the lot's side
local TUCK = 0.3 -- the paving runs this far under the road's edge: no crack
local UNDER = 0.03 -- ...and this far below its top, so the road's surface always wins
local LIFT = 0.3 -- over the ground: clears the terrain mesh's own error (MESH_FLAT_TOLERANCE 0.25)
local MIN_LIFT = 0.15 -- the lowest the smoothing may pull a vertex toward the ground
local SINK = 0.12 -- a free edge runs this far into the ground...
local RIM = 0.5 -- ...over this last half stud
local CHECK = 1 -- the ground is checked this often along every edge of the mesh
local MAX_CREASE = 0.3 -- the most a crease may lift any vertex, all told
local SMOOTH_UP = 0.15 -- the most the smoothing may raise a vertex over its drape
local JOIN_TOL = 0.5 -- ground between the lot's level and its road's (+- this) is the join to it...
local JOIN_BELOW = 1.5 -- ...and so is a verge dipping this far under the lower of the two...
local JOIN_REACH = 10 -- ...this close to the road's edge (TerrainPadService.ROAD_JOIN_MAX)
local APRON_REACH = 6 -- the apron climbs to a kerb from at most this far (1.5 studs at 1 in 4)
local APRON_RUN = 4 -- near the road the paving falls at most 1 stud per this many below its edge
local BACK_RUN = 3 -- a raised back edge (garage floor) comes down to the ground at 1 in this
local MIN_SIDE_DOT = 0.8 -- a corner normal this far off the lot's own axis is a cross street's
local BACK_GAP = 0.3 -- a patch cut short by a road behind its front stops this far off that road
local SQUARE_SIN = 0.6 -- a `square` patch's ray must meet the edge at >= ~37 degrees
local MIN_THICK = 0.1 -- thinner strips are kerb faces, not surfaces
local THICK = 0.05 -- collision thickness the blob carries (nothing collides; see RoadMeshBuilder)

-- A patch's rim overlaps the one beside it by this (one station): a sunk edge under a neighbour's
-- surface never opens a groove between them.
LotGroundMesh.FEATHER = STATION
LotGroundMesh.LIFT = LIFT -- a drape's height over the ground (props on paving stand on it)

local function rail(out: { Edge }, pts: { Vector3 })
	local n = #pts
	for k = 1, n - 1 do
		local a, b = pts[k], pts[k + 1]
		local ta = pts[k + 1] - pts[math.max(k - 1, 1)]
		local tb = pts[math.min(k + 2, n)] - pts[k]
		ta = Vector3.new(ta.X, 0, ta.Z)
		tb = Vector3.new(tb.X, 0, tb.Z)
		ta = if ta.Magnitude > 1e-6 then ta.Unit else ta
		tb = if tb.Magnitude > 1e-6 then tb.Unit else tb
		table.insert(out, { a.X, a.Y, a.Z, b.X, b.Y, b.Z, ta.X, ta.Z, tb.X, tb.Z })
	end
end

local function level(a: Vector3, b: Vector3, c: Vector3): boolean
	local n = (b - a):Cross(c - a)
	local m = n.Magnitude
	return m > 1e-6 and math.abs(n.Y) > m * 0.7
end

-- The outline of everything walkable a road piece draws: both rails of every level strip (the
-- carriageway, a footway's top), junction plates' rims, and the tops of dead-end footway blocks.
-- A lot looks for the FIRST of them, so the inner ones never matter.
function LotGroundMesh.edgesFromSpecs(specs: { any }): { Edge }
	local out: { Edge } = {}
	for _, s in specs do
		local strip, fan = s.strip, s.fan
		if strip then
			local n = #strip // 2
			if (s.thickness or 0) < MIN_THICK or n < 2 then continue end
			local flat = false
			for k = 1, math.min(n - 1, 4) do
				if level(strip[k * 2 - 1], strip[k * 2], strip[k * 2 + 1]) then
					flat = true
					break
				end
			end
			if not flat then continue end
			local l, r = table.create(n), table.create(n)
			for k = 1, n do
				l[k] = strip[k * 2 - 1]
				r[k] = strip[k * 2]
			end
			rail(out, l)
			rail(out, r)
		elseif fan then
			if (s.thickness or 0) < MIN_THICK or #fan < 3 then continue end
			local loop = table.clone(fan)
			table.insert(loop, fan[1])
			rail(out, loop)
		elseif not s.mark and not s.wedge and s.size.Y <= 2.5 and s.cframe.UpVector.Y > 0.7 then
			local cf, h = s.cframe, s.size * 0.5
			local c = {}
			for i, sg in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } } do
				c[i] = cf:PointToWorldSpace(Vector3.new(sg[1] * h.X, h.Y, sg[2] * h.Z))
			end
			for i = 1, 4 do
				rail(out, { c[i], c[i + 1] })
			end
		end
	end
	return out
end

-- First edge a flat unit ray (ox, oz) + s (dx, dz) meets for s in [sMin, sMax], at a height within
-- MAX_RISE of yRef (and, `square`, at a real angle): its s and its height there.
local function firstHit(edges: { Edge }, ox: number, oz: number, dx: number, dz: number, sMin: number, sMax: number, yRef: number, square: boolean?): (number?, number?)
	local best: number?, bestY: number? = nil, nil
	for _, e in edges do
		local ex, ez = e[4] - e[1], e[6] - e[3]
		local den = dx * ez - dz * ex
		if math.abs(den) < 1e-9 then continue end
		if square and math.abs(den) < SQUARE_SIN * math.sqrt(ex * ex + ez * ez) then continue end
		local qx, qz = e[1] - ox, e[3] - oz
		local s = (qx * ez - qz * ex) / den
		if s < sMin or s > sMax or (best and s >= best) then continue end
		local u = (qx * dz - qz * dx) / den
		if u < 0 or u > 1 then continue end
		local y = e[2] + (e[5] - e[2]) * u
		if math.abs(y - yRef) > MAX_RISE then continue end
		best, bestY = s, y
	end
	return best, bestY
end

-- The road's normal at the edge point nearest `p`, turned into the lot; nil when no edge is
-- near, or when it runs another way (a cross street's kerb at a corner lot).
local function roadNormal(edges: { Edge }, p: Vector3, inward: Vector3, yRef: number): Vector3?
	local tx: number?, tz: number? = nil, nil
	local bestD = 6 * 6
	for _, e in edges do
		local ex, ez = e[4] - e[1], e[6] - e[3]
		local len2 = ex * ex + ez * ez
		local u = if len2 > 1e-9 then math.clamp(((p.X - e[1]) * ex + (p.Z - e[3]) * ez) / len2, 0, 1) else 0
		local dx, dz = p.X - (e[1] + ex * u), p.Z - (e[3] + ez * u)
		local d2 = dx * dx + dz * dz
		if d2 < bestD and math.abs(e[2] + (e[5] - e[2]) * u - yRef) <= MAX_RISE then
			bestD = d2
			tx, tz = e[7] + (e[9] - e[7]) * u, e[8] + (e[10] - e[8]) * u
		end
	end
	if not (tx and tz) then return nil end
	local nrm = Vector3.new(-tz, 0, tx)
	if nrm.Magnitude < 1e-6 then return nil end
	nrm = nrm.Unit
	if nrm:Dot(inward) < 0 then nrm = -nrm end
	return if nrm:Dot(inward) >= MIN_SIDE_DOT then nrm else nil
end

-- The world XZ box the patch and the road it may reach can cover: which road pieces to ask, and
-- which lots a changed road piece touches.
function LotGroundMesh.bounds(p: Params): (number, number, number, number)
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, c in { Vector3.new(p.x0, 0, p.zFront + REACH), Vector3.new(p.x1, 0, p.zFront + REACH), Vector3.new(p.x0, 0, p.zBack), Vector3.new(p.x1, 0, p.zBack) } do
		local w = p.frame:PointToWorldSpace(c)
		x0, x1 = math.min(x0, w.X), math.max(x1, w.X)
		z0, z1 = math.min(z0, w.Z), math.max(z1, w.Z)
	end
	local pad = REACH
	return x0 - pad, x1 + pad, z0 - pad, z1 + pad
end

-- The patch's strips against the road `edges`, draped on `ground` (nil when it has no area).
function LotGroundMesh.build(p: Params, edges: { Edge }, ground: Ground): RoadMeshBuilder.Builder?
	local F = p.frame
	local y0 = F.Position.Y
	local depth = p.zFront - p.zBack
	if depth <= 0.05 or p.x1 - p.x0 <= 0.05 then return nil end
	local toRoad = F:VectorToWorldSpace(Vector3.zAxis)
	local inward = -Vector3.new(toRoad.X, 0, toRoad.Z).Unit
	local cA = F:PointToWorldSpace(Vector3.new(p.x0, 0, p.zFront))
	local cB = F:PointToWorldSpace(Vector3.new(p.x1, 0, p.zFront))
	local sideA, sideB = inward, inward
	if p.trap then
		sideA = roadNormal(edges, cA, inward, y0) or inward
		sideB = roadNormal(edges, cB, inward, y0) or inward
	end
	local backA = cA + sideA * depth
	local backB = cB + sideB * depth
	local reach = p.reach or REACH
	local backY = if p.yBack and p.yBack > 0 then y0 + p.yBack else nil
	local soft = p.soft or ""
	local softBack = string.find(soft, "b", 1, true) ~= nil
	local softL = string.find(soft, "l", 1, true) ~= nil
	local softR = string.find(soft, "r", 1, true) ~= nil

	-- Stations across (0..1), plus one RIM in from each soft side: the edge sinks over that last
	-- half stud, so the line where it meets the grass is crisp, not a jagged cut through a slope.
	local nReg = math.max(2, math.ceil((p.x1 - p.x0) / STATION) + 1)
	local us: { number } = table.create(nReg + 2)
	for i = 1, nReg do us[i] = (i - 1) / (nReg - 1) end
	local rimU = RIM / math.max(p.x1 - p.x0, 4 * RIM)
	if softL then table.insert(us, 2, rimU) end
	if softR then table.insert(us, #us, 1 - rimU) end
	local n = #us

	-- Where each station starts (its back) and ends (the road's edge, or the lot's own front).
	local backs: { Vector3 } = table.create(n)
	local ends: { Vector3 } = table.create(n)
	local edgeYs: { number | false } = table.create(n)
	local anyHit, allHit, longest = false, true, 0
	for i = 1, n do
		local u = us[i]
		local o = cA:Lerp(cB, u)
		local bk = backA:Lerp(backB, u)
		local ray = Vector3.new(o.X - bk.X, 0, o.Z - bk.Z)
		local deep = ray.Magnitude
		ray = ray.Unit
		-- A road crossing the patch further in: the paving stops short of it.
		local behind = firstHit(edges, o.X, o.Z, -ray.X, -ray.Z, BACK_REACH, deep, y0)
		if behind then
			deep = math.max(BACK_REACH, behind - BACK_GAP)
			bk = o - ray * deep
		end
		local s, ey = firstHit(edges, o.X, o.Z, ray.X, ray.Z, -BACK_REACH, reach, y0, p.square)
		if ey and p.maxRise and math.abs(ey - y0) > p.maxRise then s, ey = nil, nil end
		local e = o
		edgeYs[i] = false
		allHit = allHit and s ~= nil
		if s and ey then
			-- An edge behind the patch's own back (a footway cutting right across a thin patch):
			-- nothing of the patch is left at this station.
			local at = math.max(s, 0.05 - deep - TUCK)
			e = o + ray * (at + TUCK)
			-- A kerb stands a little over the ground in front of it. A road edge standing on a wall
			-- or a deck -- or sunk in a cutting -- is not one the paving can meet: it stops under it.
			local lead = o + ray * (at - KERB_LEAD)
			if math.abs(ey - ground(lead.X, lead.Z)) <= WALL then
				anyHit = true
				edgeYs[i] = ey - UNDER
			else
				allHit = false
			end
		end
		backs[i] = Vector3.new(bk.X, 0, bk.Z)
		ends[i] = Vector3.new(e.X, 0, e.Z)
		longest = math.max(longest, (ends[i] - backs[i]).Magnitude)
	end
	if p.square and not anyHit then return nil end -- a side with no road along it

	-- Rows back to front (0..1) every STEP, plus a RIM row in from a soft back and from a front
	-- that met no road; the front row sits on the road's edge. `lows` is how low each vertex may
	-- go: over the ground, up an apron to the road, onto a garage floor, over a dip it bridges.
	local mReg = math.max(1, math.ceil(longest / STEP))
	local ts: { number } = table.create(mReg + 3)
	for j = 0, mReg do table.insert(ts, j / mReg) end
	local rimT = RIM / math.max(longest, 4 * RIM)
	if softBack then table.insert(ts, 2, rimT) end
	if not allHit then table.insert(ts, #ts, 1 - rimT) end
	local rowsN = #ts
	local rows: { { Vector3 } } = table.create(rowsN)
	local lows: { { number } } = table.create(rowsN)
	local grounds: { { number } } = table.create(rowsN)
	local sunk: { { boolean } } = table.create(rowsN)
	for j = 1, rowsN do
		local t = ts[j]
		local row, low, gr, sk = table.create(n), table.create(n), table.create(n), table.create(n)
		for i = 1, n do
			local a, e = backs[i], ends[i]
			local q = a:Lerp(e, t)
			local g = ground(q.X, q.Z)
			local lo = g + MIN_LIFT
			local ey = edgeYs[i]
			local front = j == rowsN
			local toEdge = (e - q).Magnitude
			-- The ground joining the lot to its own road (the pad's road join): near that road and
			-- between the two levels, or a verge a little under the kerb. The paving lies on it --
			-- never held level over it, never sunk as a bank. A cliff down to another road is not it.
			-- A flat lot (user: "the plot should always try to be flat if it can") keeps its level up
			-- to its own front line; the join to a road higher or lower is the stretch in front of it.
			local level = p.flat and p.floorY ~= nil and not front
				and F:PointToObjectSpace(Vector3.new(q.X, y0, q.Z)).Z < p.zFront - 0.05
			local joining = not level and ey and toEdge <= JOIN_REACH
				and g >= math.min(y0, ey) - JOIN_BELOW and g <= math.max(y0, ey) + JOIN_TOL
			-- The apron bridges the notch between a kerb and the verge under it, no further.
			if ey and not front and not level and toEdge <= APRON_REACH then lo = math.max(lo, ey - toEdge / APRON_RUN) end
			local held = false -- a garage floor holds the back of a drive up, whatever the ground
			if backY and not front then
				local by = backY - (q - a).Magnitude / BACK_RUN
				held = by > g + MIN_LIFT
				lo = math.max(lo, by)
			end
			if p.floorY and not joining then lo = math.max(lo, p.floorY) end
			local y = math.max(g + LIFT, lo)
			local banked = p.bank ~= nil and not held and not joining
				and (g - y0 > p.bank or y0 - g > (p.drop or p.bank))
			sk[i] = false
			if ey and front then
				y = ey -- on the road's edge
			elseif (j == 1 and softBack) or (i == 1 and softL) or (i == n and softR) or (front and not ey) or banked then
				y = g - SINK -- a free edge (or a bank) melts into the ground
				sk[i] = true
			end
			row[i] = Vector3.new(q.X, y, q.Z)
			low[i] = lo
			gr[i] = g
		end
		rows[j] = row
		lows[j] = low
		grounds[j] = gr
		sunk[j] = sk
	end

	-- One pass rounds the inside off: a crease in the ground (two pads meeting, a shoulder's foot)
	-- reads as a smooth roll instead of a bump. The rim and the vertices just inside a soft edge
	-- stay put: neighbours still meet, and the bevel stays half a stud wide.
	local fixedRow = { [2] = softBack, [rowsN - 1] = not allHit }
	local fixedCol = { [2] = softL, [n - 1] = softR }
	local smooth: { [number]: { [number]: number } } = {}
	for j = 2, rowsN - 1 do
		if fixedRow[j] then continue end
		local r, s = rows[j], {}
		for i = 2, n - 1 do
			if fixedCol[i] or sunk[j][i] then continue end
			-- A sunk neighbour (a rim, a bank) is under the ground on purpose: it does not pull.
			local here = r[i].Y
			local function at(jj: number, ii: number): number
				return if sunk[jj][ii] then here else rows[jj][ii].Y
			end
			local avg = (at(j - 1, i) + at(j + 1, i) + at(j, i - 1) + at(j, i + 1)) * 0.25
			-- It rounds a bump down freely, but fills a hollow (the toe of a slope) only a little.
			local cap = math.max(here, grounds[j][i] + LIFT + SMOOTH_UP)
			s[i] = math.max(math.min((here + avg) * 0.5, cap), lows[j][i])
		end
		smooth[j] = s
	end
	for j, s in smooth do
		for i, y in s do
			local v = rows[j][i]
			rows[j][i] = Vector3.new(v.X, y, v.Z)
		end
	end

	-- The paving clears the ground ALONG every edge of its mesh (the diagonal the bake splits on
	-- too), not only at its vertices: the terrain is 4-stud triangles, so a crease between two
	-- vertices (a pad's shoulder, a bank) would poke grass up through the middle -- that stretch's
	-- ends are lifted over it. A sunk rim is the other way round: it stays under the grass all
	-- along, or a grey sliver shows where the ground dips between two rim vertices.
	local function onRoad(j: number, i: number): boolean
		return j == rowsN and edgeYs[i] ~= false
	end
	local function isRim(j: number, i: number): boolean
		return sunk[j][i] and not onRoad(j, i)
	end
	-- A crease is a small thing: no vertex rises more than MAX_CREASE for them in all. A steep
	-- brink the paving lies over (a join down to a road) is not a crease, and lifting over it
	-- stacked up into slabs floating metres over the slope.
	local lifted: { [number]: number } = {}
	local function shift(j: number, i: number, dy: number)
		if dy > 0 then
			local k = j * (n + 1) + i
			local done = lifted[k] or 0
			dy = math.min(dy, MAX_CREASE - done)
			if dy <= 0 then return end
			lifted[k] = done + dy
		end
		local v = rows[j][i]
		rows[j][i] = Vector3.new(v.X, v.Y + dy, v.Z)
	end
	-- Worst gap along a -> b: `over` = how far the ground (+CLEAR) rises over the segment, else
	-- how far the segment rises over the ground (-SINK).
	local function worst(a: Vector3, b: Vector3, over: boolean): number
		local steps = math.max(2, math.ceil(math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2) / CHECK))
		local need = 0
		for k = 1, steps - 1 do
			local t = k / steps
			local g = ground(a.X + (b.X - a.X) * t, a.Z + (b.Z - a.Z) * t)
			-- A bank the yard ends at is meant to rise over it: no lifting over that.
			if over and p.bank and g - y0 > p.bank then continue end
			local y = a.Y + (b.Y - a.Y) * t
			need = math.max(need, if over then g + MIN_LIFT - y else y - (g - SINK))
		end
		return need
	end
	local function clearPair(j1: number, i1: number, j2: number, i2: number)
		local r1, r2 = isRim(j1, i1), isRim(j2, i2)
		if r1 and r2 then
			local need = worst(rows[j1][i1], rows[j2][i2], false)
			if need > 0 then
				shift(j1, i1, -need)
				shift(j2, i2, -need)
			end
			return
		end
		if r1 or r2 then return end -- a bevel: it runs into the ground on purpose
		local need = worst(rows[j1][i1], rows[j2][i2], true)
		if need <= 0 then return end
		-- A side column is the edge the next lot shares: only a check ALONG it (which the
		-- neighbour makes identically) may move it, or the two lift apart into a crack.
		local along = i1 == i2
		local function free(j: number, i: number): boolean
			return not onRoad(j, i) and (along or (i ~= 1 and i ~= n))
		end
		local f1, f2 = free(j1, i1), free(j2, i2)
		if f1 and f2 then
			shift(j1, i1, need)
			shift(j2, i2, need)
		elseif f1 then
			shift(j1, i1, math.min(need * 2, LIFT)) -- one end pinned (the road's edge): never a spike
		elseif f2 then
			shift(j2, i2, math.min(need * 2, LIFT))
		end
	end
	for j = 1, rowsN do
		for i = 1, n do
			if i < n then clearPair(j, i, j, i + 1) end
			if j < rowsN then clearPair(j, i, j + 1, i) end
			if i < n and j < rowsN then clearPair(j, i, j + 1, i + 1) end
		end
	end

	local b = RoadMeshBuilder.new()
	for j = 1, rowsN - 1 do
		b:addSurfaceStrip(rows[j], rows[j + 1], p.color, THICK)
	end
	return b
end

-- The params travel on the LotMesh model, so a road change can rebuild it on its own.
function LotGroundMesh.write(m: Model, p: Params)
	m:SetAttribute("Frame", p.frame)
	m:SetAttribute("X0", p.x0)
	m:SetAttribute("X1", p.x1)
	m:SetAttribute("ZFront", p.zFront)
	m:SetAttribute("ZBack", p.zBack)
	m:SetAttribute("YBack", p.yBack or 0)
	m:SetAttribute("Trap", p.trap == true)
	m:SetAttribute("Reach", p.reach)
	m:SetAttribute("Square", p.square == true)
	m:SetAttribute("MaxRise", p.maxRise)
	m:SetAttribute("Soft", p.soft)
	m:SetAttribute("Bank", p.bank)
	m:SetAttribute("Drop", p.drop)
	m:SetAttribute("Color", p.color)
end

function LotGroundMesh.read(m: Model): Params?
	local frame, color = m:GetAttribute("Frame"), m:GetAttribute("Color")
	local x0, x1 = m:GetAttribute("X0"), m:GetAttribute("X1")
	local zFront, zBack = m:GetAttribute("ZFront"), m:GetAttribute("ZBack")
	if typeof(frame) ~= "CFrame" or typeof(color) ~= "Color3" or typeof(x0) ~= "number" or typeof(x1) ~= "number"
		or typeof(zFront) ~= "number" or typeof(zBack) ~= "number" then
		return nil
	end
	local yBack, soft = m:GetAttribute("YBack"), m:GetAttribute("Soft")
	return {
		frame = frame, x0 = x0, x1 = x1, zFront = zFront, zBack = zBack,
		yBack = if typeof(yBack) == "number" then yBack else 0,
		trap = m:GetAttribute("Trap") == true,
		reach = if typeof(m:GetAttribute("Reach")) == "number" then m:GetAttribute("Reach") :: number else nil,
		square = m:GetAttribute("Square") == true,
		maxRise = if typeof(m:GetAttribute("MaxRise")) == "number" then m:GetAttribute("MaxRise") :: number else nil,
		soft = if typeof(soft) == "string" then soft else nil,
		bank = if typeof(m:GetAttribute("Bank")) == "number" then m:GetAttribute("Bank") :: number else nil,
		drop = if typeof(m:GetAttribute("Drop")) == "number" then m:GetAttribute("Drop") :: number else nil,
		color = color,
	}
end

return LotGroundMesh
