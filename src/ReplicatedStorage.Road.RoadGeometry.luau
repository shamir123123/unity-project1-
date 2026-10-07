--!strict
-- RoadGeometry -- the road as a mesh, straight from its cross-section and its nodes' plans.
-- Pure library: writes RoadMeshBuilder specs (surface strips, polygon fans, paint ribbons,
-- flat paint triangles, arrow-symbol plates) and nothing else -- the caller bakes them.
--
-- One rule makes the pieces meet: a node's patch and the road bodies around it are built from
-- the SAME arm frames (RoadJunctionSolver.at), so where a body stops at its trim and the patch
-- takes over, both emit identical vertices. No overlap, no gap, no seam.

local RoadConstants = require(script.Parent.RoadConstants)
local RoadJunctionSolver = require(script.Parent.RoadJunctionSolver)
local RoadProfile = require(script.Parent.RoadProfile)
local RoadSection = require(script.Parent.RoadSection)

local RoadGeometry = {}

local UP = Vector3.yAxis
local TOP = RoadConstants.ROAD_THICKNESS * 0.5 -- asphalt top above the curve (curve = slab centre)
-- Paint above the surface it lies on. A hair (0.02) fought the asphalt from a city camera --
-- the depth buffer coarsens with distance -- so far lines broke up until you zoomed in.
local LIFT = 0.06
local KERB_BAND = RoadConstants.KERB_TOP_WIDTH
local SKIRT = RoadConstants.GROUND_SKIRT + RoadConstants.SIDEWALK_HEIGHT
local GRASS = Color3.fromRGB(98, 126, 64)
local WHITE = RoadConstants.MARKING_WHITE
local YELLOW = RoadConstants.MARKING_YELLOW
local SURFACE: { [string]: Color3 } = {
	asphalt = RoadConstants.ROAD_COLOR,
	paint = RoadConstants.ROAD_COLOR,
	concrete = RoadConstants.SIDEWALK_COLOR,
	grass = GRASS,
	red = RoadConstants.BUS_LANE_COLOR,
	paving = RoadConstants.PEDESTRIAN_PAVING_COLOR,
	pavingLight = RoadConstants.PEDESTRIAN_PAVING_LIGHT,
}
local THICK = RoadConstants.ROAD_THICKNESS
-- Every painted line is this wide, whatever the road (a double centre line: two at 0.8x).
local LINE_W = 0.5
-- A double line's strands sit this many of their widths either side of its middle.
local DOUBLE_GAP = 0.75

local at = RoadJunctionSolver.at
local rightOf = RoadJunctionSolver.rightOf

-- == Paths ===========================================================================
-- A path is a centreline the cross-section is swept along: stations with position, flat
-- tangent and right vector. Bodies run along their arm; bends and tapers along their own.
type Station = { p: Vector3, t: Vector3, r: Vector3, d: number }

-- `step`: at least one station that often (a build-out's taper curves across the road between
-- the arm's own samples).
local function armStations(arm: any, d0: number, d1: number, step: number?): { Station }
	local ds: { number } = { d0 }
	for _, c in arm.cum do
		if c > d0 + 0.05 and c < d1 - 0.05 then table.insert(ds, c) end
	end
	if step then
		local d = d0 + step
		while d < d1 - 0.05 do
			table.insert(ds, d)
			d += step
		end
		table.sort(ds)
	end
	table.insert(ds, d1)
	local out: { Station } = {}
	local last = -math.huge
	for _, d in ds do
		if d - last < 0.05 and d ~= d1 then continue end
		last = d
		local p, t = at(arm, d)
		table.insert(out, { p = p, t = t, r = rightOf(t), d = d })
	end
	return out
end

-- A cubic swept from frame A to frame B (a bend's fillet). Tangents are the arms' directions.
local function cubicStations(pA: Vector3, tA: Vector3, pB: Vector3, tB: Vector3, n: number, kB: number?, kA: number?): { Station }
	local k = (pB - pA).Magnitude * 0.36
	local c1, c2 = pA + tA * (kA or k), pB - tB * (kB or k)
	local out: { Station } = {}
	local prev: Vector3? = nil
	local d = 0
	for i = 0, n do
		local u = i / n
		local a = 1 - u
		local p = pA * (a * a * a) + c1 * (3 * a * a * u) + c2 * (3 * a * u * u) + pB * (u * u * u)
		local dp = (c1 - pA) * (3 * a * a) + (c2 - c1) * (6 * a * u) + (pB - c2) * (3 * u * u)
		local t = RoadJunctionSolver.unit(RoadJunctionSolver.flat(dp))
		if prev then d += (p - prev).Magnitude end
		prev = p
		table.insert(out, { p = p, t = t, r = rightOf(t), d = d })
	end
	return out
end

local function lateral(s: Station, x: number, h: number): Vector3
	return s.p + s.r * x + UP * (TOP + h)
end

-- == Cross-section sweep =============================================================
-- `secAt(i)` gives the section at station i (a taper interpolates; a body is constant).
-- `plainUpTo` / `plainFrom`: distances along the path inside which the roadway is ONE plain
-- asphalt band (a junction approach: parking, verges and medians stop short of the crossing).
type SweepOpts = { plainUpTo: number?, plainFrom: number?, skirtLeft: boolean?, skirtRight: boolean? }

local function railOf(stations: { Station }, secs: { any }, pick: (any) -> (number?, number?)): ({ Vector3 }?)
	local rail: { Vector3 } = {}
	for i, s in stations do
		local x, h = pick(secs[i])
		if not x then return nil end
		rail[i] = lateral(s, x :: number, h :: number)
	end
	return rail
end

local function strip(b: any, left: { Vector3 }, right: { Vector3 }, color: Color3, thk: number)
	if #left >= 2 then b:addSurfaceStrip(left, right, color, thk) end
end

-- Sweep the bands of `secs` (one section per station, same band count) over `stations`.
local function sweepBands(b: any, stations: { Station }, secs: { any })
	local nb = #secs[1].bands
	local k = 0
	while k < nb do
		k += 1
		local band = secs[1].bands[k]
		local top = band.top
		if top == 0 then
			-- Flush bands of one surface are ONE strip: lanes and parking are a single sheet of
			-- asphalt (the baker shades a strip's edges as gutters, so per-lane strips would
			-- stripe every lane boundary).
			local last = k
			while last < nb and secs[1].bands[last + 1].top == 0 and secs[1].bands[last + 1].surf == band.surf do
				last += 1
			end
			local left = table.create(#stations)
			local right = table.create(#stations)
			local live = false
			for i, s in stations do
				local bds = secs[i].bands
				left[i] = lateral(s, bds[k].x0, 0)
				right[i] = lateral(s, bds[last].x1, 0)
				if bds[last].x1 - bds[k].x0 > 1e-3 then live = true end
			end
			if live then strip(b, left, right, SURFACE[band.surf] or SURFACE.asphalt, THICK) end
			k = last
			continue
		end
		local left = table.create(#stations)
		local right = table.create(#stations)
		local live = false
		for i, s in stations do
			local bd = secs[i].bands[k]
			left[i] = lateral(s, bd.x0, top)
			right[i] = lateral(s, bd.x1, top)
			if bd.x1 - bd.x0 > 1e-3 then live = true end
		end
		if not live then continue end
		if top > 0 then
			-- A raised band: kerb-coloured lip along any side that drops to a flush neighbour.
			local prevB = secs[1].bands[k - 1]
			local nextB = secs[1].bands[k + 1]
			local lipL = prevB ~= nil and prevB.top < top
			local lipR = nextB ~= nil and nextB.top < top
			local innerL, innerR = left, right
			if lipL then
				innerL = table.create(#stations)
				for i, s in stations do
					local bd = secs[i].bands[k]
					innerL[i] = lateral(s, math.min(bd.x0 + KERB_BAND, (bd.x0 + bd.x1) * 0.5), top)
				end
				strip(b, left, innerL, RoadConstants.KERB_COLOR, THICK)
			end
			if lipR then
				innerR = table.create(#stations)
				for i, s in stations do
					local bd = secs[i].bands[k]
					innerR[i] = lateral(s, math.max(bd.x1 - KERB_BAND, (bd.x0 + bd.x1) * 0.5), top)
				end
				strip(b, innerR, right, RoadConstants.KERB_COLOR, THICK)
			end
			strip(b, innerL, innerR, SURFACE[band.surf] or SURFACE.concrete, THICK)
		end
	end
	-- Kerb faces: a vertical strip wherever two neighbouring bands stand at different heights.
	for k = 1, nb - 1 do
		local lo, hi = secs[1].bands[k], secs[1].bands[k + 1]
		if lo.top == hi.top then continue end
		local low, high = table.create(#stations), table.create(#stations)
		for i, s in stations do
			local x = secs[i].bands[k].x1
			low[i] = lateral(s, x, math.min(lo.top, hi.top))
			high[i] = lateral(s, x, math.max(lo.top, hi.top))
		end
		strip(b, low, high, RoadConstants.KERB_COLOR, 0.05)
	end
end

-- Outer skirts: the cut edge of the road goes into the ground, never shows open.
local function sweepSkirts(b: any, stations: { Station }, secs: { any }, left: boolean, right: boolean)
	for _, side in { -1, 1 } do
		if (side < 0 and not left) or (side > 0 and not right) then continue end
		local top, bot = table.create(#stations), table.create(#stations)
		for i, s in stations do
			local bands = secs[i].bands
			local edge = if side < 0 then bands[1] else bands[#bands]
			local x = if side < 0 then edge.x0 else edge.x1
			top[i] = lateral(s, x, edge.top)
			bot[i] = lateral(s, x, edge.top - SKIRT)
		end
		strip(b, bot, top, SURFACE.concrete, 0.05)
	end
end

-- == Paint ===========================================================================
-- `grid`: the length of the road the line runs along (its stations' d count along that road).
-- `dense`: the short, close dashes beside a ramp's lane (DENSE_*).
type LineStyle = { color: Color3, width: number, dashed: boolean, double: boolean?, grid: number?, dense: boolean? }

-- Dashes are emitted as their own short solid lines, FITTED to the run: it starts and ends on
-- half a gap, so two runs meeting at a plain joint read as one unbroken dashed line.
-- With `along` (each point's distance along its road) and `grid` (that road's length) the dashes
-- sit on ONE pattern fitted to the whole road instead: every line of the road in the same rows,
-- the spacing never changing through a taper or a junction approach (user, 2026-10-06).
local DASH, PITCH = RoadConstants.DASH_LENGTH, RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP
-- The line between a ramp's lane and the lanes it joins or leaves: short dashes close together,
-- for a stretch from the fork, then the road's own (Cities: Skylines II; user, 2026-10-06).
local DENSE_DASH, DENSE_PITCH = DASH * 0.4, DASH * 0.8
RoadGeometry.DENSE_RUN = 2 * PITCH
local function emitDashed(b: any, pts: { Vector3 }, width: number, color: Color3, along: { number }?, grid: number?, dense: boolean?)
	local n = #pts
	local cum = table.create(n)
	cum[1] = 0
	for i = 2, n do cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude end
	local total = cum[n]
	local function pointAt(d: number): Vector3
		for i = 2, n do
			if cum[i] >= d then
				local u = (d - cum[i - 1]) / math.max(cum[i] - cum[i - 1], 1e-9)
				return pts[i - 1]:Lerp(pts[i], u)
			end
		end
		return pts[n]
	end
	local function dash(a: number, z: number)
		local line = { pointAt(a) }
		for i = 2, n - 1 do
			if cum[i] > a and cum[i] < z then table.insert(line, pts[i]) end
		end
		table.insert(line, pointAt(z))
		b:addMarkingLine(line, width, color, false)
	end
	if along and grid then
		local pitch = grid / math.max(1, math.round(grid / PITCH))
		local lo, hi = along[1], along[n]
		local function arcAt(s: number): number -- the line's own length at road distance s
			for i = 2, n do
				if s <= along[i] then
					local span = along[i] - along[i - 1]
					return cum[i - 1] + (if span > 1e-9 then (cum[i] - cum[i - 1]) * (s - along[i - 1]) / span else 0)
				end
			end
			return total
		end
		for k = math.max(0, math.floor(lo / pitch) - 1), math.floor(hi / pitch) + 1 do
			local c = (k + 0.5) * pitch
			local a, z = math.max(c - DASH * 0.5, lo), math.min(c + DASH * 0.5, hi)
			if z - a > 0.1 then dash(arcAt(a), arcAt(z)) end
		end
		return
	end
	local len, step = if dense then DENSE_DASH else DASH, if dense then DENSE_PITCH else PITCH
	if total < len then return end
	local count = math.max(1, math.round(total / step))
	local pitch = total / count
	for k = 1, count do
		local mid = (k - 0.5) * pitch
		dash(mid - len * 0.5, mid + len * 0.5)
	end
end

local function lineAlong(b: any, stations: { Station }, xs: { number }, h: number, style: LineStyle)
	local along: { number }? = nil
	if style.grid and not style.dense then
		along = table.create(#stations)
		for i, s in stations do (along :: { number })[i] = s.d end
	end
	local function one(offset: number)
		local pts = table.create(#stations)
		for i, s in stations do pts[i] = lateral(s, xs[i] + offset, h + LIFT) end
		if style.dashed then
			emitDashed(b, pts, style.width, style.color, along, style.grid, style.dense)
		else
			b:addMarkingLine(pts, style.width, style.color, false)
		end
	end
	if style.double then
		local gap = style.width * DOUBLE_GAP
		one(-gap)
		one(gap)
	else
		one(0)
	end
end

-- lineAlong over each stretch where ok[i] holds.
local function lineWhere(b: any, stations: { Station }, xs: { number }, ok: { boolean }, style: LineStyle)
	local i, n = 1, #stations
	while i <= n do
		if not ok[i] then
			i += 1
			continue
		end
		local j = i
		while j < n and ok[j + 1] do j += 1 end
		if j > i then lineAlong(b, table.move(stations, i, j, 1, {}), table.move(xs, i, j, 1, {}), 0, style) end
		i = j + 1
	end
end

-- A lane opening up or closing down carries no line until it is this wide (studs): its line
-- runs on nearly to where the lane is gone (user, 2026-10-06).
local MIN_MARKED_LANE = 1

-- The line between two neighbouring lanes, as the road's spec styles it.
local function boundaryStyle(spec: any, sameDir: boolean, solid: boolean): LineStyle
	if sameDir then
		return { color = WHITE, width = LINE_W, dashed = not solid and (spec.laneLineDashed ~= false) }
	end
	return {
		color = spec.centerLineColor or YELLOW,
		width = if spec.centerLineDouble then LINE_W * 0.8 else LINE_W,
		-- no overtaking on a junction approach: the centre line goes solid there
		dashed = spec.centerLineDashed == true and not spec.centerLineDouble and not solid,
		double = spec.centerLineDouble,
	}
end

-- An edge line is yellow on a lane's left (a one-way's or a median's side), white on its right.
-- `rightSide`: the line runs along the band's x1 edge. d > 0 travels with the section.
local function edgeColor(_band: any, _rightSide: boolean): Color3
	return WHITE -- user rule: edge lines are white on both sides (one-ways and ramps too)
end

-- Does a lane at the outside of the bands carry an edge line? Not along parking: that is just
-- more asphalt beside the driver, and the kerb marks it.
local function edgeBeside(neighbour: any?): boolean
	if not neighbour then return true end
	if neighbour.k == "park" then return neighbour.x1 - neighbour.x0 < 1e-3 end
	return neighbour.k ~= "lane"
end

-- The lines a section's lanes carry, decided by what sits on each side of each lane.
-- `skipEdge` ("left" / "right"): leave the edge line off that side's outermost lane (a fork
-- draws the gore side itself, shoulder or not).
-- `grid`: the length of the road the stations' d count along (dashes on one pattern per road).
-- `dense[k]`: the line after band k is a ramp lane's (short, close dashes); `open[k]`: not painted.
local function paintSection(b: any, stations: { Station }, secs: { any }, spec: any, solidLanes: boolean, skipEdge: string?, only: string?, grid: number?, dense: { [number]: boolean }?, open: { [number]: boolean }?)
	if spec.pedestrian then return end -- open paving: no lines
	local bands = secs[1].bands
	local n = #stations
	local firstLane, lastLane = math.huge, 0
	for k, band in bands do
		if band.k == "lane" then
			firstLane = math.min(firstLane, k)
			lastLane = k
		end
	end
	local function xsAt(k: number, side: string): { number }
		local xs = table.create(n)
		for i = 1, n do
			local bd = secs[i].bands[k]
			xs[i] = if side == "x0" then bd.x0 else bd.x1
		end
		return xs
	end
	for k, band in bands do
		if band.k ~= "lane" then continue end
		local nextB = bands[k + 1]
		-- no line where a lane turns round across it (open[k], or a lane marked `turn` beside oncoming)
		local turnsHere = (band.turn or nextB and nextB.turn) and nextB and nextB.d ~= band.d
		if nextB and nextB.k == "lane" and only ~= "edges" and not (open and open[k]) and not turnsHere then
			local ok = table.create(n)
			for i = 1, n do
				local a, c = secs[i].bands[k], secs[i].bands[k + 1]
				ok[i] = a.x1 - a.x0 >= MIN_MARKED_LANE and c.x1 - c.x0 >= MIN_MARKED_LANE
			end
			local style = boundaryStyle(spec, nextB.d == band.d, solidLanes)
			-- a double line reaches further across: it stops while the lane is still that much
			-- wider, so it never runs onto the edge line of a lane narrowing away beside it
			local extra = if style.double then style.width * (DOUBLE_GAP + 0.5) - LINE_W * 0.5 else 0
			if extra > 0 then
				for i = 1, n do
					local a, c = secs[i].bands[k], secs[i].bands[k + 1]
					ok[i] = ok[i] and a.x1 - a.x0 >= MIN_MARKED_LANE + extra and c.x1 - c.x0 >= MIN_MARKED_LANE + extra
				end
			end
			style.grid = grid
			style.dense = if dense and dense[k] and style.dashed then true else nil
			lineWhere(b, stations, xsAt(k, "x1"), ok, style)
		end
		if not spec.edgeLineColor or only == "lanes" then continue end
		local w = LINE_W
		local inset = w * 0.5 + 0.25
		local prevB = bands[k - 1]
		if not (k == firstLane and (skipEdge == "left" or skipEdge == "both")) then
			-- along the kerb: past a parking band to its outer edge (user: parking roads get
			-- edge lines too)
			local xs: { number }? = nil
			if prevB and prevB.k == "park" and edgeBeside(bands[k - 2]) then
				xs = xsAt(k - 1, "x0")
			elseif edgeBeside(prevB) then
				xs = xsAt(k, "x0")
			end
			if xs then
				-- a band between two sets of lanes (a median running out to a nose): the edge lines
				-- either side meet in its middle at the point, never crossing over each other first
				-- and a lane narrowing away has its edge lines meet in its own middle at its point
				local between = prevB and prevB.k ~= "park" and bands[k - 2] and bands[k - 2].k == "lane"
				for i in xs do
					local m, own = if between then secs[i].bands[k - 1] else nil, secs[i].bands[k]
					xs[i] += math.min(inset, (own.x1 - own.x0) * 0.5, if m then (m.x1 - m.x0) * 0.5 else inset)
				end
				lineAlong(b, stations, xs, 0, { color = edgeColor(band, false), width = w, dashed = false })
			end
		end
		if not (k == lastLane and (skipEdge == "right" or skipEdge == "both")) then
			local xs: { number }? = nil
			if nextB and nextB.k == "park" and edgeBeside(bands[k + 2]) then
				xs = xsAt(k + 1, "x1")
			elseif edgeBeside(nextB) then
				xs = xsAt(k, "x1")
			end
			if xs then
				local between = nextB and nextB.k ~= "park" and bands[k + 2] and bands[k + 2].k == "lane"
				for i in xs do
					local m, own = if between then secs[i].bands[k + 1] else nil, secs[i].bands[k]
					xs[i] -= math.min(inset, (own.x1 - own.x0) * 0.5, if m then (m.x1 - m.x0) * 0.5 else inset)
				end
				lineAlong(b, stations, xs, 0, { color = edgeColor(band, true), width = w, dashed = false })
			end
		end
	end
end

-- The arrow texture for a lane's movements (RoadConstants.ARROW_TEXTURE_*), as the old
-- renderer chose it.
local function arrowTexture(d: any): string
	if d.merge then
		return if d.merge == "right" then RoadConstants.ARROW_TEXTURE_MERGE_RIGHT else RoadConstants.ARROW_TEXTURE_MERGE_LEFT
	end
	if d.uturn then
		return if d.uturn == "right" then RoadConstants.ARROW_TEXTURE_UTURN_RIGHT else RoadConstants.ARROW_TEXTURE_UTURN_LEFT
	end
	local l, t, r = d.left == true, d.straight == true, d.right == true
	if l and t and r then return RoadConstants.ARROW_TEXTURE_ALL end
	if l and t then return RoadConstants.ARROW_TEXTURE_LEFT_THROUGH end
	if t and r then return RoadConstants.ARROW_TEXTURE_THROUGH_RIGHT end
	if l and r then return RoadConstants.ARROW_TEXTURE_LEFT_RIGHT end
	if l then return RoadConstants.ARROW_TEXTURE_LEFT end
	if r then return RoadConstants.ARROW_TEXTURE_RIGHT end
	return RoadConstants.ARROW_TEXTURE_THROUGH
end

-- Flat paint polygons (give-way teeth): triangles lying on the asphalt at station `s`.
local function paintTris(b: any, s: Station, tris: { { Vector2 } }, color: Color3, along: Vector3, across: Vector3, origin: Vector3)
	local pts: { Vector3 } = {}
	for _, tri in tris do
		for _, v in tri do
			table.insert(pts, origin + across * v.X + along * v.Y + UP * (TOP + LIFT * 1.5))
		end
	end
	if #pts >= 3 then b:addTris(pts, color) end
end

-- == Sections helpers =================================================================
-- The roadway as one plain asphalt band (junction approaches), roadsides kept.
local function plainSection(sec: any): any
	local bands = {}
	local roadAdded = false
	for _, bd in sec.bands do
		if bd.x1 <= sec.roadL + 1e-3 or bd.x0 >= sec.roadR - 1e-3 then
			table.insert(bands, bd)
		elseif not roadAdded then
			roadAdded = true
			table.insert(bands, { k = "road", x0 = sec.roadL, x1 = sec.roadR, top = 0, surf = "asphalt" })
		end
	end
	return { bands = bands, roadL = sec.roadL, roadR = sec.roadR, walkL = sec.walkL, walkR = sec.walkR,
		highway = sec.highway, oneWay = sec.oneWay }
end

-- Mirror a section (look from the other end).
function RoadGeometry.mirror(sec: any): any
	local bands = {}
	for i = #sec.bands, 1, -1 do
		local bd = sec.bands[i]
		table.insert(bands, { k = bd.k, x0 = -bd.x1, x1 = -bd.x0, top = bd.top, surf = bd.surf,
			d = if bd.d then -bd.d else nil, bus = bd.bus, ordinal = bd.ordinal, count = bd.count, angle = bd.angle })
	end
	return { bands = bands, roadL = -sec.roadR, roadR = -sec.roadL, walkL = sec.walkR, walkR = sec.walkL,
		highway = sec.highway, oneWay = sec.oneWay }
end

local function sweep(b: any, stations: { Station }, secs: { any }, spec: any, paint: boolean, solid: boolean?)
	if #stations < 2 then return end
	sweepBands(b, stations, secs)
	sweepSkirts(b, stations, secs, true, true)
	if paint then paintSection(b, stations, secs, spec, solid == true) end
end

local function constant(sec: any, n: number): { any }
	local out = table.create(n)
	for i = 1, n do out[i] = sec end
	return out
end

-- Split stations at distance d (inserting an exact station there). Returns (before, after).
local function splitAt(arm: any, stations: { Station }, d: number): ({ Station }, { Station })
	local before, after = {}, {}
	local p, t = at(arm, d)
	local cut = { p = p, t = t, r = rightOf(t), d = d }
	for _, s in stations do
		if s.d < d - 0.05 then table.insert(before, s) elseif s.d > d + 0.05 then table.insert(after, s) end
	end
	table.insert(before, cut)
	table.insert(after, 1, cut)
	return before, after
end

-- A raised median ends in a round nose where it stops short of a junction, never square.
-- `outward`: -1 the junction is behind station s (the body's start), +1 ahead (its end).
local function medianNoses(b: any, s: Station, sec: any, outward: number)
	for _, bd in sec.bands do
		if bd.k ~= "median" or bd.top <= 0 then continue end
		local r = (bd.x1 - bd.x0) * 0.5
		local c = s.p + s.r * ((bd.x0 + bd.x1) * 0.5)
		local rimK, rimS, low, high = {}, {}, {}, {}
		for i = 0, 10 do
			local a = math.pi * i / 10
			local dir = s.r * math.cos(a) + s.t * (outward * math.sin(a))
			table.insert(rimK, c + dir * r + UP * (TOP + bd.top))
			table.insert(rimS, c + dir * math.max(r - KERB_BAND, 0.05) + UP * (TOP + bd.top + 0.02))
			table.insert(low, c + dir * r + UP * TOP)
			table.insert(high, c + dir * r + UP * (TOP + bd.top))
		end
		b:addFan(c + UP * (TOP + bd.top), rimK, THICK, RoadConstants.KERB_COLOR)
		b:addFan(c + UP * (TOP + bd.top + 0.02), rimS, 0.05, SURFACE[bd.surf] or SURFACE.grass)
		b:addSurfaceStrip(low, high, RoadConstants.KERB_COLOR, 0.05)
	end
end

-- Painted hatching (a "zebra" area): diagonal stripes across any flat polygon, clipped to it,
-- with its outline. `poly` runs round the area at paint height; stripes lean `angle` radians off
-- the polygon's first edge, `gap` studs apart. One routine for every hatched area the roads paint.
function RoadGeometry.hatch(b: any, poly: { Vector3 }, gap: number, angle: number)
	local n = #poly
	if n < 3 then return end
	local e = RoadJunctionSolver.unit(RoadJunctionSolver.flat(poly[2] - poly[1]))
	local c, s = math.cos(angle), math.sin(angle)
	local along = e * c + rightOf(e) * s -- stripe direction
	local across = rightOf(along)
	local lo, hi = math.huge, -math.huge
	for _, p in poly do
		local v = p:Dot(across)
		lo, hi = math.min(lo, v), math.max(hi, v)
	end
	local k = lo + gap * 0.5
	while k < hi do
		-- where the line {x . across = k} crosses the polygon's edges, in order along it
		local hits: { number } = {}
		local origin: Vector3? = nil
		for i = 1, n do
			local a, q = poly[i], poly[i % n + 1]
			local va, vq = a:Dot(across) - k, q:Dot(across) - k
			if (va < 0) ~= (vq < 0) then
				local p = a:Lerp(q, va / (va - vq))
				origin = origin or p
				table.insert(hits, p:Dot(along))
			end
		end
		table.sort(hits)
		if origin then
			local base = (origin :: Vector3) - along * (origin :: Vector3):Dot(along)
			for i = 1, #hits - 1, 2 do
				b:addMarkingLine({ base + along * hits[i], base + along * hits[i + 1] }, LINE_W, WHITE, false)
			end
		end
		k += gap
	end
	local ring = table.clone(poly)
	table.insert(ring, poly[1])
	b:addMarkingLine(ring, LINE_W, WHITE, false)
end

-- Sharp bends park nobody (ParkingService agrees): the curve turns more than this between
-- two points a stall apart.
local PARK_MAX_TURN = math.rad(6)

-- Angled parking: a stall line every STALL_SPACING between `from` and `to` along the arm, from
-- the lane edge to the kerb's edge line, leaning the way the kerb lane drives (cars nose in with
-- traffic). Where the stalls give out -- a bend, or the end of the run -- the leftover triangle
-- against the kerb is hatched.
local function stallLines(b: any, arm: any, sec: any, from: number, to: number)
	local S = RoadProfile.STALL_SPACING
	local edgeIn = LINE_W + 0.25 -- the kerb edge line's inner side (paintSection's inset)
	for i, bd in sec.bands do
		if bd.k ~= "park" or not bd.angle then continue end
		local right = bd.x0 >= 0
		local inner = sec.bands[if right then i - 1 else i + 1]
		local lean = if inner and inner.d then inner.d else 1
		local xi = if right then bd.x0 else bd.x1
		local xo = if right then bd.x1 - edgeIn else bd.x0 + edgeIn
		local run = math.abs(xo - xi) / math.tan(math.rad(bd.angle))
		local function point(d: number, x: number): Vector3
			local p, t = at(arm, d)
			return p + rightOf(t) * x + UP * (TOP + LIFT)
		end
		local function straight(d: number): boolean
			local _, t0 = at(arm, d - S * 0.5)
			local _, t1 = at(arm, d + S * 0.5)
			return t0:Dot(t1) >= math.cos(PARK_MAX_TURN)
		end
		local first: number?, last: number? = nil, nil
		local d = math.ceil(from / S) * S
		while d <= to do
			local e = d + lean * run
			if e >= from and e <= to and straight((d + e) * 0.5) then
				b:addMarkingLine({ point(d, xi), point(e, xo) }, LINE_W, WHITE, false)
				first = first or d
				last = d
			end
			d += S
		end
		if not first then continue end
		-- the triangles each end: the last stall line, the kerb line and the run's end
		for _, endD in { { first :: number, -1 }, { last :: number, 1 } } do
			local d0, dir = endD[1], endD[2]
			local tip = d0 + lean * run
			local stop = if dir > 0 then math.max(d0, tip) + S * 0.5 else math.min(d0, tip) - S * 0.5
			if stop < from or stop > to then continue end
			-- the kerb side is the edge line itself (its middle), not a second line beside it
			local xc = if right then bd.x1 - LINE_W * 0.5 - 0.25 else bd.x0 + LINE_W * 0.5 + 0.25
			local a, k = point(d0, xi), point(tip, xc)
			local kerbEnd = point(stop, xc)
			local laneEnd = point(stop, xi)
			if (dir > 0) == (lean > 0) then
				RoadGeometry.hatch(b, { a, k, kerbEnd, laneEnd }, 1.6, math.rad(45))
			else
				RoadGeometry.hatch(b, { a, laneEnd, kerbEnd, k }, 1.6, math.rad(45))
			end
		end
	end
end

-- == Bodies ==========================================================================
export type EndDress = {
	trim: number,        -- where the body starts (from this end)
	plain: number?,      -- the roadway is plain asphalt out to here (junction approach)
	crosswalk: boolean?,
	stopAt: number?,     -- stop / give-way line (arriving lanes)
	control: string?,    -- "stop" | "yield" | "signal" | nil
	arrows: { [number]: { left: boolean?, straight: boolean?, right: boolean?, uturn: any?, merge: string? } }?, -- by lane band index
	shift: number?,      -- the road sits this far right of its curve here (the node's outward frame)
	bulb: boolean?,      -- the node built the kerb out over the parking (RoadSection.bulbed)
	cap: boolean?,       -- a dead end: the road turns round here
	mitre: Vector3?,     -- a joint with another body: this end lies square to this tangent (curve direction)
	arrowsAt: number?,   -- arrows (`arrows`) at this distance from the end, with no stop line
	uturnAll: string?,   -- every arriving lane may turn round here: "left" | "right" (the arrow's turn)
	dense: { k: number, len: number }?, -- the line after band k (curve frame) is a ramp lane's for `len` from this end
	open: { ks: { number }, len: number }?, -- the lines after these bands (curve frame) are left open for `len` from this end: a U-turn there
	bare: boolean?,      -- a short link inside a super node (JunctionGroups): no lane or centre lines
}


-- One segment's road between its two node trims. `armS` is the arm at the START node (looking
-- along the curve), `armE` the arm at the END node: the body is swept along armS, and the end
-- dressing at the far node is placed by distance from armS's far end.
-- `stops`: bus stops on this road, { d = along the curve, half = half their length, right = on
-- the curve's right }; the verge in front of each is paved.
export type Stop = { d: number, half: number, right: boolean, bay: number? }
local BAY_TAPER = 10 -- a bus bay's kerb steps back over this far either end
function RoadGeometry.body(b: any, armS: any, spec: any, startD: EndDress, endD: EndDress, stops: { Stop }?)
	local L = armS.len
	local d0, d1 = startD.trim, L - endD.trim
	if d1 - d0 < 0.5 then return end
	-- A joint with another road and nothing drawn between them: both bodies end on one mitre line,
	-- or each square end leaves a wedge of open ground on the outside of the turn (the green line).
	local function mitred(list: { Station }): { Station }
		local first, last = list[1], list[#list]
		if startD.mitre and first and math.abs(first.d - d0) < 0.01 then
			list[1] = { p = first.p, t = startD.mitre, r = rightOf(startD.mitre), d = first.d }
		end
		if endD.mitre and last and math.abs(last.d - d1) < 0.01 then
			list[#list] = { p = last.p, t = endD.mitre, r = rightOf(endD.mitre), d = last.d }
		end
		return list
	end
	local stations = mitred(armStations(armS, d0, d1))
	local sec = armS.sec
	-- A shifted end (a highway running straight on past an exit) eases back onto the curve over
	-- the whole body. The far end's shift is in its own outward frame: mirrored along the curve.
	local s0, s1 = startD.shift or 0, -(endD.shift or 0)
	local function secsFor(list: { Station }, base: any): { any }
		if s0 == 0 and s1 == 0 then return constant(base, #list) end
		local out = table.create(#list)
		for i, st in list do
			local u = math.clamp((st.d - d0) / (d1 - d0), 0, 1)
			u = u * u * (3 - 2 * u)
			out[i] = RoadSection.shifted(base, s0 + (s1 - s0) * u)
		end
		return out
	end

	-- Junction approaches: plain asphalt roadway (solid lane lines) up to `plain` from each end.
	local p0 = if startD.plain and not spec.pedestrian then math.min(startD.plain, (d0 + d1) * 0.5) else d0
	local p1 = if endD.plain and not spec.pedestrian then math.max(L - endD.plain, (d0 + d1) * 0.5) else d1
	local head, mid, tail = {}, stations, {}
	if p0 > d0 + 0.05 then head, mid = splitAt(armS, mid, p0) end
	if p1 < d1 - 0.05 then mid, tail = splitAt(armS, mid, p1) end
	-- Lines stop at the stop line (or short of the crossing), never run into the zebra.
	local function paintEdge(e: EndDress): number
		if e.stopAt and e.stopAt > 0 then return e.stopAt + RoadConstants.STOP_LINE_DEPTH * 0.5 end
		if e.crosswalk then return e.trim + RoadConstants.CROSSWALK_DEPTH + 0.5 end
		return e.trim
	end
	local pa, pb = math.max(d0, paintEdge(startD)), math.min(d1, L - paintEdge(endD))
	local function clip(list: { Station }): { Station }
		if #list < 2 or pa >= list[#list].d - 0.05 or pb <= list[1].d + 0.05 then return {} end
		local out = list
		if pa > out[1].d + 0.05 then
			local _, after = splitAt(armS, out, pa)
			out = after
		end
		if pb < out[#out].d - 0.05 then
			local before = splitAt(armS, out, pb)
			out = before
		end
		return out
	end
	-- Kerb build-outs at a junction end over parking: the approach keeps the kerb on the lane
	-- edge, then it tapers back out to the parking over three times the parking's width (3:1).
	local builtS = if startD.bulb then RoadSection.bulbed(sec, 1) else sec
	local builtE = if endD.bulb then RoadSection.bulbed(sec, 1) else sec
	local taperLen = RoadJunctionSolver.BUILD_OUT_TAPER * RoadSection.parkWidth(sec)
	local rest = mid
	local tapers: { { any } } = {} -- { stations, d where built out, d where the parking is back }
	local half = (p0 + p1) * 0.5
	local function dense(list: { Station }): { Station }
		return mitred(armStations(armS, list[1].d, list[#list].d, 1))
	end
	if builtS ~= sec and #rest >= 2 then
		local back = math.min(p0 + taperLen, half)
		if back < rest[#rest].d - 0.05 then
			local before, after = splitAt(armS, rest, back)
			table.insert(tapers, { dense(before), p0, back })
			rest = after
		else
			table.insert(tapers, { dense(rest), p0, back })
			rest = {}
		end
	end
	if builtE ~= sec and #rest >= 2 then
		local back = math.max(p1 - taperLen, half)
		if back > rest[1].d + 0.05 then
			local before, after = splitAt(armS, rest, back)
			table.insert(tapers, { dense(after), p1, back })
			rest = before
		else
			table.insert(tapers, { dense(rest), p1, back })
			rest = {}
		end
	end

	-- Bus bays (a stop on a road without parking): the kerb steps back into the footway beside
	-- the stop, so the bus stands out of the traffic. Every zone a bay reaches is swept densely,
	-- its sections stepped back (RoadSection.bayed) -- near a junction too.
	local bays: { Stop } = {}
	for _, st in stops or {} do
		if st.bay then table.insert(bays, st) end
	end
	local function withBays(list: { Station }, secsOf: ({ Station }) -> { any }): ({ Station }, { any })
		local hit = false
		for _, bay in bays do
			if #list >= 2 and bay.d + bay.half + BAY_TAPER > list[1].d and bay.d - bay.half - BAY_TAPER < list[#list].d then
				hit = true
			end
		end
		if not hit then return list, secsOf(list) end
		list = mitred(armStations(armS, list[1].d, list[#list].d, 1))
		local secs = secsOf(list)
		for i, st in list do
			local l, r = 0, 0
			for _, bay in bays do
				local a, c = bay.d - bay.half, bay.d + bay.half
				local u = math.clamp(if st.d < a then 1 - (a - st.d) / BAY_TAPER elseif st.d > c then 1 - (st.d - c) / BAY_TAPER else 1, 0, 1)
				u = u * u * (3 - 2 * u)
				if bay.right then r = math.max(r, (bay.bay :: number) * u) else l = math.max(l, (bay.bay :: number) * u) end
			end
			secs[i] = RoadSection.bayed(secs[i], l, r)
		end
		return list, secs
	end
	local headPlain, headPlainSecs = withBays(head, function(l) return secsFor(l, plainSection(builtS)) end)
	local headL, headSecs = withBays(head, function(l) return secsFor(l, builtS) end)
	local restL, restSecs = withBays(rest, function(l) return secsFor(l, sec) end)
	if #headPlain >= 2 then sweep(b, headPlain, headPlainSecs, spec, false) end
	sweep(b, restL, restSecs, spec, false)
	if #rest >= 2 then stallLines(b, armS, sec, rest[1].d, rest[#rest].d) end
	local function stationAt(d: number): Station
		local p, t = at(armS, d)
		return { p = p, t = t, r = rightOf(t), d = d }
	end
	if p0 > d0 + 0.05 then medianNoses(b, stationAt(p0), sec, -1) end
	if p1 < d1 - 0.05 then medianNoses(b, stationAt(p1), sec, 1) end
	-- a dead end: the median noses off where the road turns round, never stops square
	if startD.cap then medianNoses(b, stationAt(d0), sec, -1) end
	if endD.cap then medianNoses(b, stationAt(d1), sec, 1) end
	-- Edge lines run along the kerb, zone by zone: round a build-out and its taper, outside any
	-- parking, and on to the junction (and through it, along an open side).
	local edgeZones: { { any } } = { { headL, headSecs }, { restL, restSecs } }
	for _, t in tapers do
		local full, back = t[2], t[3]
		local list, secs = withBays(t[1], function(l)
			local out = table.create(#l)
			for i, st in l do
				local u = math.clamp((st.d - back) / (full - back), 0, 1)
				out[i] = RoadSection.bulbed(sec, u * u * (3 - 2 * u))
			end
			return out
		end)
		sweep(b, list, secs, spec, false)
		table.insert(edgeZones, { list, secs })
	end
	local tailPlain, tailPlainSecs = withBays(tail, function(l) return secsFor(l, plainSection(builtE)) end)
	local tailL, tailSecs = withBays(tail, function(l) return secsFor(l, builtE) end)
	if #tailPlain >= 2 then sweep(b, tailPlain, tailPlainSecs, spec, false) end
	table.insert(edgeZones, { tailL, tailSecs })
	-- A ramp's lane beside this road's lanes (EndDress.dense, at a fork): its line is dense for a
	-- stretch from that end, so the dashed run is cut where the stretch ends.
	local denseS = if startD.dense then d0 + startD.dense.len else nil
	local denseE = if endD.dense then d1 - endD.dense.len else nil
	-- and where a lane turns round, the line it crosses is left open (EndDress.open)
	local openS = if startD.open then d0 + startD.open.len else nil
	local openE = if endD.open then d1 - endD.open.len else nil
	local function paintLanes(list: { Station }, solid: boolean)
		if #list < 2 then return end
		for _, cut in { denseS, denseE, openS, openE } do
			if cut and cut > list[1].d + 0.5 and cut < list[#list].d - 0.5 then
				local before, after = splitAt(armS, list, cut)
				paintLanes(before, solid)
				paintLanes(after, solid)
				return
			end
		end
		local midD = (list[1].d + list[#list].d) * 0.5
		local dense: { [number]: boolean }? = nil
		if denseS and midD < denseS then dense = { [startD.dense.k] = true } end
		if denseE and midD > denseE then
			dense = dense or {}
			dense[endD.dense.k] = true
		end
		local open: { [number]: boolean } = {}
		if openS and midD < openS then for _, k in startD.open.ks do open[k] = true end end
		if openE and midD > openE then for _, k in endD.open.ks do open[k] = true end end
		paintSection(b, list, secsFor(list, sec), spec, solid, nil, "lanes", L, dense, open)
	end
	-- a link inside a super node is part of one junction: its kerbs keep their edge lines only
	if not (startD.bare or endD.bare) then
		for _, part in { { head, true }, { mid, false }, { tail, true } } do
			paintLanes(clip(part[1]), part[2])
		end
	end
	for _, z in edgeZones do
		if #z[1] >= 2 then paintSection(b, z[1], z[2], spec, false, nil, "edges") end
	end

	-- A bus stop: the verge in front of it is paved, so riders step from the path to the bus.
	for _, st in stops or {} do
		if st.bay then continue end -- a bay took the verge
		local a, c = math.max(st.d - st.half, d0), math.min(st.d + st.half, d1)
		if c - a < 0.5 then continue end
		local list = armStations(armS, a, c, 2)
		for i, bd in sec.bands do
			if bd.k ~= "verge" or not RoadProfile.isSide(sec.bands, i) then continue end
			local onRight = bd.x0 >= sec.roadR - 0.01
			if onRight ~= st.right then continue end
			local x0 = if onRight then bd.x0 + KERB_BAND else bd.x0
			local x1 = if onRight then bd.x1 else bd.x1 - KERB_BAND
			local left, right = table.create(#list), table.create(#list)
			for k, s in list do
				left[k] = lateral(s, x0, bd.top + LIFT)
				right[k] = lateral(s, x1, bd.top + LIFT)
			end
			b:addSurfaceStrip(left, right, SURFACE.concrete, 0.05)
		end
	end

	RoadGeometry.dressEnd(b, armS, builtS, spec, startD, false)
	RoadGeometry.dressEnd(b, armS, builtE, spec, endD, true)
end

-- Crosswalk, stop / give-way line and arrows at one end of a body. Everything is placed in the
-- curve's own frame (the section's x); only the symbols are turned to face INTO the node.
-- `fromEnd`: this is the end node, so distances count back from the arm's far end and the
-- arriving lanes are the ones travelling along the curve (d > 0).
function RoadGeometry.dressEnd(b: any, arm: any, sec: any, spec: any, e: EndDress, fromEnd: boolean)
	local L = arm.len
	local into = if fromEnd then 1 else -1
	local function station(dist: number): Station
		local d = if fromEnd then L - dist else dist
		local p, t = at(arm, d)
		return { p = p, t = t, r = rightOf(t), d = d }
	end
	if e.crosswalk then
		local depth = RoadConstants.CROSSWALK_DEPTH
		local margin = RoadConstants.CROSSWALK_EDGE_MARGIN
		local stripe = RoadConstants.CROSSWALK_STRIPE_WIDTH
		local pitch = stripe + RoadConstants.CROSSWALK_GAP
		local s0, s1 = station(e.trim), station(e.trim + depth)
		local span = (sec.roadR - sec.roadL) - 2 * margin
		local count = math.max(1, math.floor((span + RoadConstants.CROSSWALK_GAP) / pitch))
		local used = count * pitch - RoadConstants.CROSSWALK_GAP
		local start = sec.roadL + margin + (span - used) * 0.5 + stripe * 0.5
		for i = 0, count - 1 do
			local lx = start + i * pitch
			b:addMarkingLine({ lateral(s0, lx, LIFT), lateral(s1, lx, LIFT) }, stripe, WHITE, false)
		end
		-- A paved landing through a verge planted in the footway, so the crossing meets the path.
		for i, bd in sec.bands do
			if bd.k ~= "verge" or not RoadProfile.isSide(sec.bands, i) then continue end
			local x0, x1 = bd.x0, bd.x1
			if math.abs(x1 - sec.roadL) < 0.01 then
				x1 -= KERB_BAND -- the kerb lip stays
			elseif math.abs(x0 - sec.roadR) < 0.01 then
				x0 += KERB_BAND
			end
			local h = bd.top + LIFT
			b:addSurfaceStrip({ lateral(s0, x0, h), lateral(s1, x0, h) }, { lateral(s0, x1, h), lateral(s1, x1, h) },
				SURFACE.concrete, 0.05)
		end
	end
	local markAt = e.stopAt or e.arrowsAt
	if spec.pedestrian or not markAt or markAt <= 0 then return end
	local arriving: { any } = {}
	local idx: { number } = {}
	for k, bd in sec.bands do
		if bd.k == "lane" and (bd.d :: number) * into > 0 then
			table.insert(arriving, bd)
			table.insert(idx, k)
		end
	end
	if #arriving == 0 then return end
	local lo, hi = math.huge, -math.huge
	for _, bd in arriving do lo = math.min(lo, bd.x0); hi = math.max(hi, bd.x1) end
	local s = station(markAt)
	local along = s.t * into
	local across = rightOf(along)
	if e.control == "yield" then
		-- Give-way teeth: a row of triangles pointing at the arriving driver.
		local size = 1.1
		local n = math.max(1, math.floor((hi - lo) / (size * 1.6)))
		local step = (hi - lo) / n
		local tris: { { Vector2 } } = {}
		for i = 0, n - 1 do
			local c = (lo + (i + 0.5) * step) * into
			table.insert(tris, { Vector2.new(c - size * 0.5, 0), Vector2.new(c + size * 0.5, 0), Vector2.new(c, -size * 1.3) })
		end
		paintTris(b, s, tris, WHITE, along, across, s.p)
	elseif e.control ~= "none" and e.stopAt then
		b:addMarkingLine({ lateral(s, lo + 0.15, LIFT), lateral(s, hi - 0.15, LIFT) }, RoadConstants.STOP_LINE_DEPTH, WHITE, false)
	end
	if e.arrows or e.uturnAll then
		-- The game's own arrow textures on plates (RoadMeshView places them), one per lane, sized
		-- to it the way the old renderer sized them -- tilted to the road's slope under them: laid
		-- flat, a plate on a hill sank into the road at one end (user, 2026-10-06).
		for i, bd in arriving do
			local dirs = if e.uturnAll then { uturn = e.uturnAll } else e.arrows[idx[i]]
			if not dirs then continue end
			local size = math.clamp((bd.x1 - bd.x0) * 0.8, 6, 11)
			local D = markAt + RoadConstants.ARROW_GAP + size * 0.5 + 1
			local x = (bd.x0 + bd.x1) * 0.5
			local sa, near, far = station(D), station(D - size * 0.5), station(D + size * 0.5)
			local fwd = (near.p + near.r * x) - (far.p + far.r * x) -- into the node, up or down the slope
			local centre = sa.p + sa.r * x + UP * (TOP + LIFT)
			b:addSymbol(centre, if fwd.Magnitude > 1e-3 then fwd.Unit else sa.t * into, size, arrowTexture(dirs), WHITE)
		end
	end
end

-- Kerb (lip + face) and footway along a rim, at height y (or ys[i] per point: a junction's rim
-- meets each road at that road's own height, never a step). `verge`: a grass strip `w` wide
-- planted `a` back from the kerb at the rim's first point, easing to `b` back at its last (the
-- roads either side carry one; a build-out stands in front of it).
type Verge = { w: number, a: number, b: number }
local function footwayAlong(b: any, kerb: { Vector3 }, back: { Vector3 }, y: number, w: number, verge: Verge?, ys: { number }?)
	local kT, kL, kB, bT, bL, g0, g1 = {}, {}, {}, {}, {}, {}, {}
	local n = #kerb
	for i, k in kerb do
		local y = if ys then ys[i] else y
		local top = y + RoadConstants.SIDEWALK_HEIGHT
		kT[i] = Vector3.new(k.X, top, k.Z)
		kB[i] = Vector3.new(k.X, y, k.Z)
		bT[i] = Vector3.new(back[i].X, top, back[i].Z)
		bL[i] = bT[i] - UP * SKIRT
		local ww = math.max((bT[i] - kT[i]).Magnitude, 1e-3)
		kL[i] = kT[i]:Lerp(bT[i], math.min(KERB_BAND / ww, 0.5))
		if verge then
			local f = if n > 1 then (i - 1) / (n - 1) else 0
			local off = math.max(verge.a + (verge.b - verge.a) * (f * f * (3 - 2 * f)), KERB_BAND)
			g0[i] = kT[i]:Lerp(bT[i], math.clamp(off / ww, 0, 1))
			g1[i] = kT[i]:Lerp(bT[i], math.clamp((off + verge.w) / ww, 0, 1))
		end
	end
	b:addSurfaceStrip(kT, kL, RoadConstants.KERB_COLOR, THICK)
	if verge then
		if math.max(verge.a, verge.b) > KERB_BAND then b:addSurfaceStrip(kL, g0, SURFACE.concrete, THICK) end
		b:addSurfaceStrip(g0, g1, SURFACE.grass, THICK)
		b:addSurfaceStrip(g1, bT, SURFACE.concrete, THICK)
	else
		b:addSurfaceStrip(kL, bT, SURFACE.concrete, THICK)
	end
	b:addSurfaceStrip(kB, kT, RoadConstants.KERB_COLOR, 0.05)
	b:addSurfaceStrip(bL, bT, SURFACE.concrete, 0.05)
end

-- The verge planted in a section's footway on one side: its width and how far it stands back
-- from the kerb (a build-out in front of it), or nil.
local function sideVerge(sec: any, right: boolean): (number?, number)
	for i, bd in sec.bands do
		if bd.k ~= "verge" or not RoadProfile.isSide(sec.bands, i) then continue end
		if right and bd.x0 >= sec.roadR - 0.01 then return bd.x1 - bd.x0, bd.x0 - sec.roadR end
		if not right and bd.x1 <= sec.roadL + 0.01 then return bd.x1 - bd.x0, sec.roadL - bd.x1 end
	end
	return nil, 0
end

-- == Nodes ===========================================================================
-- Round end of a road: a half disc of roadway with the footway wrapped round it.
function RoadGeometry.cap(b: any, arm: any, spec: any)
	local sec = arm.sec
	local p, t = at(arm, 0)
	local back = -t
	local r = rightOf(t)
	-- round the road's own middle: it may be drawn off its curve (a shifted road)
	local mid = (sec.roadL + sec.roadR) * 0.5
	p += r * mid
	local e = (sec.roadR - sec.roadL) * 0.5
	local w = math.max(sec.walkL, sec.walkR)
	local n = 16
	local rim: { Vector3 } = {}
	local walkOut, walkInLo = {}, {}
	for i = 0, n do
		local a = math.pi * i / n -- from the right edge, round the front, to the left edge
		local dir = r * math.cos(a) + back * math.sin(a)
		table.insert(rim, p + dir * e + UP * TOP)
		if w > 0 then
			table.insert(walkInLo, p + dir * e + UP * TOP)
			table.insert(walkOut, p + dir * (e + w) + UP * (TOP + RoadConstants.SIDEWALK_HEIGHT))
		end
	end
	-- Half a disc: triangles from the node out to the rim (a closed fan would add a zero-area
	-- triangle across the road's end and hang a skirt under the body).
	local capTris: { Vector3 } = {}
	for i = 1, #rim - 1 do
		table.insert(capTris, p + UP * TOP)
		table.insert(capTris, rim[i])
		table.insert(capTris, rim[i + 1])
	end
	b:addTris(capTris, if spec.pedestrian then SURFACE.paving else SURFACE.asphalt)
	if w <= 0 then
		local lo = {}
		for i, v in rim do lo[i] = v - UP * SKIRT end
		b:addSurfaceStrip(lo, rim, SURFACE.concrete, 0.05)
	end
	if w > 0 then
		-- rim runs from the right kerb round to the left one
		local vR, offR = sideVerge(sec, true)
		local vL, offL = sideVerge(sec, false)
		local verge: Verge? = if vR and vL then { w = math.min(vR, vL), a = offR, b = offL } else nil
		footwayAlong(b, walkInLo, walkOut, p.Y + TOP, w, verge)
	end
	-- The edge lines run on round the end, each side's half meeting at the far point.
	if not spec.edgeLineColor then return end
	local bands = sec.bands
	local li, ri
	for i, bd in bands do
		if bd.k == "lane" then
			li = li or i
			ri = i
		end
	end
	if not li then return end
	local lw = LINE_W
	local inset = lw * 0.5 + 0.25
	-- at the kerb: past a parking band beside the outer lanes
	local outR = if bands[ri + 1] and bands[ri + 1].k == "park" then ri + 1 else ri
	local outL = if bands[li - 1] and bands[li - 1].k == "park" then li - 1 else li
	local xR, xL = bands[outR].x1 - inset - mid, -(bands[outL].x0 + inset - mid)
	local function half(fromI: number, toI: number, band: any, rightSide: boolean)
		local pts = {}
		for i = fromI, toI do
			local a = math.pi * i / n
			local dir = r * math.cos(a) + back * math.sin(a)
			table.insert(pts, p + dir * (xR + (xL - xR) * i / n) + UP * (TOP + LIFT))
		end
		b:addMarkingLine(pts, lw, edgeColor(band, rightSide), false)
	end
	if edgeBeside(bands[outR + 1]) then half(0, n // 2, bands[ri], true) end
	if edgeBeside(bands[outL - 1]) then half(n // 2, n, bands[li], false) end
end


-- A taper: one section eases into the other over `plan.taper.length` (the narrower road flares),
-- every band's edges easing across (smoothstep). Bands one side lacks shrink to nothing.
local function blendSections(A: any, B: any, u: number): any
	-- A and B: same band count and kinds (see matchSections).
	local s = u * u * (3 - 2 * u)
	local bands = {}
	for k, ba in A.bands do
		local bb = B.bands[k]
		table.insert(bands, { k = ba.k, x0 = ba.x0 + (bb.x0 - ba.x0) * s, x1 = ba.x1 + (bb.x1 - ba.x1) * s,
			top = ba.top, surf = ba.surf, d = ba.d or bb.d, bus = ba.bus })
	end
	-- Lanes that are there at one end only keep their place across the road, and the run of them
	-- grows / shrinks over them: their lines run straight until the edge meets them (Cities:
	-- Skylines II), never bending in (user, 2026-10-06).
	local function width(sec: any, k: number): number
		return sec.bands[k].x1 - sec.bands[k].x0
	end
	local k = 1
	while k <= #bands do
		local only = if width(B, k) < 1e-3 then A elseif width(A, k) < 1e-3 then B else nil
		if bands[k].k ~= "lane" or not only or width(only, k) < 1e-3 then
			k += 1
			continue
		end
		local j = k
		while j < #bands and bands[j + 1].k == "lane" and width(only, j + 1) > 1e-3
			and width(if only == A then B else A, j + 1) < 1e-3 do
			j += 1
		end
		local lo, hi = bands[k].x0, bands[j].x1 -- the run's span here
		for q = k, j do
			bands[q].x0 = math.clamp(only.bands[q].x0, lo, hi)
			bands[q].x1 = math.clamp(only.bands[q].x1, lo, hi)
		end
		k = j + 1
	end
	return { bands = bands, roadL = A.roadL + (B.roadL - A.roadL) * s, roadR = A.roadR + (B.roadR - A.roadR) * s,
		walkL = A.walkL, walkR = A.walkR, highway = A.highway, oneWay = A.oneWay }
end

-- Pad two sections to the same band list. Lanes match per direction from the CENTRE side, so a
-- lane that is added or dropped is the kerbside one: "right lane ends", and a road that widens
-- keeps its centre line where it was. Every other band matches by kind and side; a band one
-- section lacks gets zero width there (on the group's `anchor` when the group has no bands).
-- `byPosition`: when two lane lists differ in count, pair them from whichever side keeps the
-- lanes where they are (a road joined to one side of a wider one keeps its lines straight there).
function RoadGeometry.matchSections(A: any, B: any, byPosition: boolean?): (any, any)
	local function groups(sec: any)
		local g = { walkL = {}, sideL = {}, back = {}, median = {}, fwd = {}, sideR = {}, walkR = {} }
		local seenLane = sec.outer == "right" -- a lane-less group on a road's right-hand side
		local seenRoad = seenLane
		for i, bd in sec.bands do
			if RoadProfile.isSide(sec.bands, i) then -- a footway, or a verge planted in one
				table.insert(if seenRoad then g.walkR else g.walkL, bd)
				continue
			end
			seenRoad = true
			if bd.k == "lane" then
				seenLane = true
				table.insert(if (bd.d :: number) < 0 then g.back else g.fwd, bd)
			elseif bd.k == "median" and seenLane then
				table.insert(g.median, bd)
			else
				table.insert(if seenLane then g.sideR else g.sideL, bd)
			end
		end
		return g
	end
	local ga, gb = groups(A), groups(B)
	local outA, outB = {}, {}
	local function zeroLike(bd: any, xEdge: number): any
		return { k = bd.k, x0 = xEdge, x1 = xEdge, top = bd.top, surf = bd.surf, d = bd.d, bus = bd.bus }
	end
	-- Pair two lists; `anchorRight`: line them up from the right (pad on the left).
	local function pair(la: { any }, lb: { any }, anchorRight: boolean)
		local n = math.max(#la, #lb)
		if byPosition and #la ~= #lb and #la > 0 and #lb > 0 then
			local function cost(right: boolean): number
				local c = 0
				for i = 1, math.min(#la, #lb) do
					local x, y = la[if right then #la - i + 1 else i], lb[if right then #lb - i + 1 else i]
					c += math.abs((x.x0 + x.x1) - (y.x0 + y.x1))
				end
				return c
			end
			local l, r = cost(false), cost(true)
			if math.abs(l - r) > 1e-3 then anchorRight = r < l end
		end
		for i = 1, n do
			local ia = if anchorRight then #la - n + i else i
			local ib = if anchorRight then #lb - n + i else i
			local a, bb = la[ia], lb[ib]
			local ra = a or zeroLike(bb, if anchorRight then (la[1] and la[1].x0 or 0) else (la[#la] and la[#la].x1 or 0))
			local rb = bb or zeroLike(a, if anchorRight then (lb[1] and lb[1].x0 or 0) else (lb[#lb] and lb[#lb].x1 or 0))
			table.insert(outA, ra)
			table.insert(outB, rb)
		end
	end
	pair(ga.walkL, gb.walkL, false)
	pair(ga.sideL, gb.sideL, false)
	-- Which direction's lanes lie on the left: the back ones in right-hand traffic, the forward
	-- ones in left-hand traffic (RoadSection mirrors a two-way road's directions there). Taken
	-- off the bands themselves, so the order out is always left to right.
	local function backLeft(g: any): boolean?
		if #g.back == 0 or #g.fwd == 0 then return nil end
		return g.back[1].x0 < g.fwd[1].x0
	end
	local bl = backLeft(ga)
	if bl == nil then bl = backLeft(gb) end
	if bl == nil then bl = true end
	local leftA, rightA = if bl then ga.back else ga.fwd, if bl then ga.fwd else ga.back
	local leftB, rightB = if bl then gb.back else gb.fwd, if bl then gb.fwd else gb.back
	if (#ga.back > 0) ~= (#gb.back > 0) and (#ga.fwd > 0) ~= (#gb.fwd > 0) then
		-- The traffic turns round across this stretch (a lane that ends at a nose and U-turns,
		-- one-ways meeting a two-way the wrong way): the pavement is one run of lanes, matched
		-- in order, whichever way they are signed.
		local la, lb = table.clone(leftA), table.clone(leftB)
		for _, bd in rightA do table.insert(la, bd) end
		for _, bd in rightB do table.insert(lb, bd) end
		pair(la, lb, true)
		pair(ga.median, gb.median, false)
	else
		pair(leftA, leftB, true)   -- the left group: kerb on the left, so lanes come and go there
		pair(ga.median, gb.median, false)
		pair(rightA, rightB, false) -- the right group: kerb on the right
	end
	pair(ga.sideR, gb.sideR, true)
	pair(ga.walkR, gb.walkR, true)
	-- Real bands keep exactly where they are; a padded (zero-width) band sits on its
	-- neighbour's edge, so it grows out of / shrinks into that edge.
	local function place(list: { any }, sec: any)
		for i, bd in list do
			if bd.x1 - bd.x0 > 1e-6 then continue end
			local prev = list[i - 1]
			local x = if prev then prev.x1 else nil
			if not x then
				for j = i + 1, #list do
					if list[j].x1 - list[j].x0 > 1e-6 then x = list[j].x0 break end
				end
			end
			bd.x0 = x or sec.anchor or 0
			bd.x1 = bd.x0
		end
		return { bands = list, roadL = sec.roadL, roadR = sec.roadR, walkL = sec.walkL, walkR = sec.walkR,
			highway = sec.highway, oneWay = sec.oneWay }
	end
	return place(outA, A), place(outB, B)
end

-- A bend: the cross-section swept round a fillet between the two trimmed arms.
function RoadGeometry.bend(b: any, plan: any, spec: any)
	local a, c = plan.arms[1], plan.arms[2]
	local pA, tA = at(a, plan.trims[1])
	local pB, tB = at(c, plan.trims[2])
	-- Sweep from arm a's mouth into the node and out along arm c: looking along the sweep, the
	-- section is arm a's seen from its far side.
	local stations = cubicStations(pA, -tA, pB, tB, 12)
	-- Two different roads: the section eases from one to the other round the bend.
	local A, B = RoadGeometry.matchSections(RoadGeometry.mirror(a.sec), c.sec)
	local secs = table.create(#stations)
	for i in stations do secs[i] = blendSections(A, B, (i - 1) / (#stations - 1)) end
	sweep(b, stations, secs, spec, true)
end

function RoadGeometry.taper(b: any, plan: any, spec: any)
	local tp = plan.taper
	local on, other = plan.arms[tp.a], plan.arms[tp.b] -- swept along `on`, out of the node
	-- At the node `on` carries the OTHER road's section (seen from this side = mirrored), set
	-- where that road really sits across this one (laid off one of its lanes: to one side, and
	-- only that side's edge eases); at the mouth its own.
	local off = RoadJunctionSolver.flat(other.pts[1] - on.pts[1]):Dot(rightOf(on.dir))
	local atNode = RoadSection.shifted(RoadGeometry.mirror(other.sec), off)
	local A, B = RoadGeometry.matchSections(atNode, on.sec, math.abs(off) > 0.05)
	-- Dense stations so the ease reads smooth.
	local dense: { Station } = {}
	local steps = math.max(8, math.ceil(tp.length / 3))
	for i = 0, steps do
		local d = tp.length * i / steps
		local p, t = at(on, d)
		table.insert(dense, { p = p, t = t, r = rightOf(t), d = d })
	end
	local m = RoadJunctionSolver.unit(RoadJunctionSolver.flat(on.dir - other.dir))
	dense[1] = { p = dense[1].p, t = m, r = rightOf(m), d = 0 }
	local secs = table.create(#dense)
	for i, s in dense do secs[i] = blendSections(A, B, s.d / tp.length) end
	sweepBands(b, dense, secs)
	sweepSkirts(b, dense, secs, true, true)
	paintSection(b, dense, secs, spec, false, nil, nil, on.len) -- d along `on`: its body's dash pattern
end

-- == Forks ==========================================================================
-- Splits and merges: a highway exit or entry, a lane taken off by a ramp, a dual carriageway
-- closing up into a single road. The stem's cross-section is split at the node into two lane
-- groups -- the side the branch leaves on goes with the branch -- and each group is swept along
-- its own curve to its road's mouth, easing from where it sat in the stem to its own section
-- there. Both curves leave the node in the stem's direction, so they share the stem's end frame
-- exactly (no seam), and the sliver that opens between them is the gore.
local function groupOf(sec: any, from: number, to: number, anchor: number): any
	local bands = {}
	for i = from, to do table.insert(bands, sec.bands[i]) end
	return { bands = bands, roadL = sec.roadL, roadR = sec.roadR, walkL = 0, walkR = 0,
		highway = sec.highway, oneWay = sec.oneWay, anchor = anchor }
end

local function laneCount(sec: any): number
	local n = 0
	for _, bd in sec.bands do if bd.k == "lane" then n += 1 end end
	return n
end

-- Sweep one group along its OWN road's curve, from the node to that road's mouth. Every band
-- edge stays exactly where it was in the stem until the road's own section, carried out on its
-- curve, has moved past it (away from the other group): a ramp's lanes run on in the highway
-- lanes they came from and only peel off as the ramp really leaves, and an auxiliary lane opens
-- from the highway's edge as the ramp's outer edge swings clear. No band ever cuts back across
-- the other group. The first station is the stem's own end frame, so nothing seams there.
local FORK_STEPS = 24
local TAPER_SHARE = 0.4 -- of a fork's length, over which its lanes reach their own widths
-- `relative`: the main road's group -- following its own road, its lanes ease from where they sat
-- in the stem to their own places ACROSS THAT ROAD, so a main road that bends away at a kinked
-- joint takes its lanes with it (pinned across the stem's line they lagged: a wave). Returns
-- whether the group runs along its road's own curve (its d is then that road's distance).
-- `cutAt`: where the stem's body ends (its drawn end); every group starts on the line across t0
-- through it, so nothing seams there even when a road was laid a stud ahead of / behind the node.
-- `covAt`: across the stem, the middle of the stem lanes this road lies on (RoadJunctionSolver
-- mCov / bCov).
local function buildGroup(start: any, finish: any, node: Vector3, t0: Vector3,
	arm: any, mouth: number, goreSide: string, canHold: boolean, relative: boolean?, cutAt: Vector3?, covAt: number?): ({ Station }, { any }, boolean)
	local r0 = rightOf(t0)
	-- Every road's lanes are matched to the stem lanes it lies on, by where they lie (its section
	-- set there, across the stem): the stem lanes it does not carry on narrow out beside them.
	-- One rule for every fork (user, 2026-10-06).
	local at0 = if arm.anchored then RoadJunctionSolver.flat(arm.pts[1] - node):Dot(r0) else covAt
	local A, B
	if at0 then
		A, B = RoadGeometry.matchSections(start, RoadSection.shifted(finish, at0), true)
		B = RoadSection.shifted(B, -at0)
	else
		A, B = RoadGeometry.matchSections(start, finish)
	end
	local out = if goreSide == "left" then 1 else -1 -- away from the other group
	-- The lane the bands are laid out from: the one on the gore side, held beside the other
	-- group until the lanes have opened -- unless that lane ENDS in this fork (a lane drop into
	-- the gore), when the far side is held instead so the lanes that carry on keep their line.
	local gk: number? = nil
	local gRight = goreSide == "right"
	for k, bd in A.bands do
		if bd.k == "lane" and (gk == nil or gRight) then gk = k end
	end
	-- How long the held lane runs alongside first: all of the taper for a road that leaves the
	-- stem tangent (a lane-snapped exit), none for one drawn off it at 45 degrees or more.
	local steep = math.acos(math.clamp(arm.dir:Dot(t0), -1, 1))
	local hold = if canHold then TAPER_SHARE * math.clamp(1 - steep / math.rad(45), 0, 1) else 0
	local holdGore = true
	if gk and B.bands[gk].x1 - B.bands[gk].x0 < 0.5 then
		local far: number? = nil
		for k, bd in A.bands do
			if bd.k == "lane" and (far == nil or not gRight) then far = k end
		end
		gk, gRight, holdGore = far, not gRight, false
	end
	local lo = if #start.bands > 0 then start.bands[1].x0 else start.anchor
	local hi = if #start.bands > 0 then start.bands[#start.bands].x1 else start.anchor
	local pA = node + r0 * ((lo + hi) * 0.5) -- the middle of the group's lanes in the stem
	local pM, tM = at(arm, mouth)
	local follow = arm.anchored or math.acos(math.clamp(arm.dir:Dot(t0), -1, 1)) < math.rad(30)
	local across = relative and follow
	-- across its own road: measured from where that road starts (to one side of the node when
	-- laid off a lane)
	local base0 = RoadJunctionSolver.flat(arm.pts[1] - node):Dot(r0)
	local baseM, leanM = RoadJunctionSolver.flat(pM - node):Dot(r0), rightOf(tM):Dot(r0)
	if across then baseM, leanM = base0, 1 end
	-- The path: a curve from the middle of the group's lanes in the stem, leaving in the stem's
	-- direction, to the road's mouth on its own curve, turning ONE way (the solver put the mouth
	-- where that is possible). Otherwise its far handle is cut short so it never swings back
	-- toward the other group.
	local legA, legM = RoadJunctionSolver.forkTurn(pA, t0, pM, tM)
	local path
	if follow then
		-- drawn leaving along the stem, or laid off one of its lanes: the group follows exactly
		-- the road the player drew
		path = table.create(FORK_STEPS + 1)
		for i = 0, FORK_STEPS do
			local d = mouth * i / FORK_STEPS
			local p, t = at(arm, d)
			path[i + 1] = { p = p, t = t, r = rightOf(t), d = d }
		end
	elseif legA and legM and legA > 0 and legM > 0 then
		-- one turn: the quadratic through the corner where the two lines meet, as a cubic
		path = cubicStations(pA, t0, pM, tM, FORK_STEPS, legM * 2 / 3, legA * 2 / 3)
	else
		local kB = (pM - pA).Magnitude * 0.36
		local gain, lean0 = (pM - pA):Dot(r0) * out, tM:Dot(r0) * out
		if gain > 0 and lean0 > 1e-3 then kB = math.min(kB, gain / lean0) end
		path = cubicStations(pA, t0, pM, tM, FORK_STEPS, kB)
	end
	local stations: { Station } = {}
	local secs = {}
	for i = 0, FORK_STEPS do
		local d = mouth * i / FORK_STEPS
		local p = path[i + 1].p
		if i == 0 and cutAt then p -= t0 * RoadJunctionSolver.flat(p - cutAt):Dot(t0) end
		-- Leaves on the stem's cut (a branch laid off a lane at a real angle on its own heading) and
		-- turns onto the path over the first third: on a joint that kinks, turning it in one step
		-- folds the inside edge back on itself (a notch) and bulges the outside.
		local t = tM
		if i < FORK_STEPS then
			local own = path[i + 1].t
			local from = if not arm.anchored or arm.dir:Dot(t0) > math.cos(math.rad(12)) then t0 else own
			local w = math.clamp(i / FORK_STEPS / 0.35, 0, 1)
			t = RoadJunctionSolver.unit(from:Lerp(own, w * w * (3 - 2 * w)))
		end
		local r = rightOf(t)
		local base = if across then base0 else RoadJunctionSolver.flat(p - node):Dot(r0) -- this station's centre, across the stem
		local lean = if across then 1 else math.max(r:Dot(r0), 0.3)
		local f = i / FORK_STEPS
		local u = f * f * (3 - 2 * f)
		-- Widths reach the road's own over the first part (an exit lane opens to full width
		-- while still beside the stem's lanes), positions follow the gore-side lane edge.
		local tf = math.clamp(f / TAPER_SHARE, 0, 1)
		local tap = tf * tf * (3 - 2 * tf)
		-- An edge eases from its stem position to its own road's, never cutting back toward the
		-- other group on the way unless that is where it ends up.
		local function place(stemX: number, ownX: number, w: number?): number
			local x = stemX + (base + ownX * lean - stemX) * (w or u)
			if out * (baseM + ownX * leanM - stemX) >= 0 then
				x = if out > 0 then math.max(stemX, x) else math.min(stemX, x)
			end
			return (x - base) / lean
		end
		local bands = table.create(#A.bands)
		for k, ba in A.bands do
			local bb = B.bands[k]
			bands[k] = { k = ba.k, x0 = bb.x0, x1 = bb.x1, top = ba.top, surf = ba.surf, d = ba.d or bb.d, bus = ba.bus, turn = ba.turn }
		end
		-- A stem lane this road takes but does not carry on narrows out on its gore side as the
		-- roads part (a lane ending between two roads: each takes it and narrows it, so it ends
		-- in the gore's point).
		local function keep(k: number): number?
			local wa, wb = A.bands[k].x1 - A.bands[k].x0, B.bands[k].x1 - B.bands[k].x0
			if A.bands[k].k ~= "lane" or wa < 1e-3 or wb > 1e-3 then return nil end
			return wa * (1 - u) -- over the whole run (RoadJunctionSolver makes it 5x the lane's width at least)
		end
		if arm.anchored and i < FORK_STEPS then
			-- a road laid off lanes is its own road from them on: its own lanes stay where they are,
			-- and a lane it drops sits beside them on whichever side it was (pushing what lies
			-- beyond it out), narrowing away
			local anchor = 1
			for k, bd in B.bands do
				if bd.k == "lane" and bd.x1 - bd.x0 > 1e-3 then anchor = k break end
			end
			local x = B.bands[anchor].x0
			for k = anchor, #bands do
				local w = keep(k) or (B.bands[k].x1 - B.bands[k].x0)
				bands[k].x0, bands[k].x1 = x, x + w
				x += w
			end
			x = B.bands[anchor].x0
			for k = anchor - 1, 1, -1 do
				local w = keep(k) or (B.bands[k].x1 - B.bands[k].x0)
				bands[k].x1, bands[k].x0 = x, x - w
				x -= w
			end
		end
		if i < FORK_STEPS and not arm.anchored then
			local function width(k: number): number
				local held = keep(k)
				if held then return held end
				local wa, wb = A.bands[k].x1 - A.bands[k].x0, B.bands[k].x1 - B.bands[k].x0
				return wa + (wb - wa) * tap
			end
			if gk then
				-- Lay the bands out from the gore-side lane's edge: inward (away from the gore) the
				-- lanes and whatever lies beyond them, outward the gore-side shoulder (the fork pins
				-- that to the gap the two roads have opened).
				-- the gore-side edge holds still until the lanes have opened, then moves off
				local df = math.clamp((f - hold) / (1 - hold), 0, 1)
				local depart = if holdGore then df * df * (3 - 2 * df) else u
				local e = if gRight then place(A.bands[gk].x1, B.bands[gk].x1, depart)
					else place(A.bands[gk].x0, B.bands[gk].x0, depart)
				local x = e
				local from, to, step = gk, 1, -1
				if not gRight then from, to, step = gk, #bands, 1 end
				for k = from, to, step do
					local w = width(k)
					if gRight then bands[k].x1, bands[k].x0 = x, x - w; x -= w
					else bands[k].x0, bands[k].x1 = x, x + w; x += w end
				end
				x = e
				from, to, step = gk + 1, #bands, 1
				if not gRight then from, to, step = gk - 1, 1, -1 end
				for k = from, to, step do
					local w = width(k)
					if gRight then bands[k].x0, bands[k].x1 = x, x + w; x += w
					else bands[k].x1, bands[k].x0 = x, x - w; x -= w end
				end
			else
				for k, ba in A.bands do
					bands[k].x0 = place(ba.x0, B.bands[k].x0)
					bands[k].x1 = math.max(bands[k].x0, place(ba.x1, B.bands[k].x1))
				end
			end
		end
		table.insert(stations, { p = p, t = t, r = r, d = d })
		table.insert(secs, { bands = bands, roadL = bands[1].x0, roadR = bands[#bands].x1, walkL = 0, walkR = 0,
			highway = B.highway, oneWay = B.oneWay })
	end
	-- A group that starts on its own heading (laid off a lane at an angle) starts ON the stem's
	-- cut all the same: its first cross-section lies along the cut, stretched as a mitre is, or an
	-- open wedge was left between it and the stem's end (user, 2026-10-06).
	local c = stations[1].t:Dot(t0)
	if c < 0.9999 and c > 0.3 then stations[1].r = rightOf(t0) / c end
	return stations, secs, follow
end

-- One ramp's fork (`f`, one of plan.forks): its branch group, the gore and their lines. The
-- main road's group is built by the first fork running along it and painted once by
-- RoadGeometry.fork (`mains`, by arm), so a road with a ramp each side is ONE road.
local function drawFork(b: any, plan: any, f: any, node: Vector3, spec: any, mains: { [number]: any })
	local arms = plan.arms
	local stem, main, branch = arms[f.stem], arms[f.main], arms[f.branch]
	local branchRight = f.branchRight
	-- the stem, looking away from it into the fork, across the node (laid off a lane: drawn to one
	-- side of it)
	local start = RoadSection.shifted(RoadGeometry.mirror(stem.sec),
		RoadJunctionSolver.flat(stem.pts[1] - node):Dot(rightOf(f.t0 or -stem.dir)))
	-- a stem lane turning round at the split (RoadJunctionSolver laneEnds): the line between it and
	-- the oncoming lane it turns into stays open through the groups too (paintSection)
	local turning = plan.laneEnds and plan.laneEnds[f.stem]
	if turning then
		for m, bd in start.bands do
			if turning[#start.bands - m + 1] == "uturn" then bd.turn = true end
		end
	end
	local nS = laneCount(start)
	local take = f.take or 0 -- the stem lanes the branch takes (RoadJunctionSolver)
	-- Each road's group: the stem lanes it takes (RoadJunctionSolver mRun / bRun), with the
	-- stem's edge bands beside them when the run reaches that edge.
	local laneBands: { number } = {}
	for i, bd in start.bands do
		if bd.k == "lane" then table.insert(laneBands, i) end
	end
	local function runGroup(run: { number }): any
		local from = if run[1] <= 1 then 1 else laneBands[run[1]]
		local to = if run[2] >= #laneBands then #start.bands else laneBands[run[2]]
		return groupOf(start, from, to, (start.bands[from].x0 + start.bands[to].x1) * 0.5)
	end
	-- (no runs: a stem with no lanes) Split index: bands 1..k go left, k+1..n go right.
	local lanesSeen, k = 0, #start.bands
	if branchRight then
		local keep = nS - take
		for i, bd in start.bands do
			if bd.k == "lane" then
				lanesSeen += 1
				if lanesSeen == keep then k = i break end
			end
		end
	else
		for i, bd in start.bands do
			if bd.k == "lane" then
				lanesSeen += 1
				if lanesSeen == take then k = i break end
			end
		end
		if take == 0 then
			for i, bd in start.bands do
				if bd.k == "lane" then
					k = i - 1
					break
				end
			end
		end
	end
	local splitX = if k >= 1 then start.bands[k].x1 else start.bands[1].x0
	local left, right = groupOf(start, 1, k, splitX), groupOf(start, k + 1, #start.bands, splitX)
	if take == 0 then
		-- Nothing taken (the road runs on with every lane): the branch splits out of the stem's
		-- outside lane, which both roads share until they part -- no extra lane is made. (A
		-- player who wants a proper exit lane widens a stretch of the road before the exit.)
		if branchRight then
			right = groupOf(start, k, #start.bands, splitX)
		else
			left = groupOf(start, 1, k + 1, splitX)
		end
	end
	local mainStart, branchStart = if branchRight then left else right, if branchRight then right else left
	if f.mRun and f.bRun and #laneBands > 0 then
		mainStart, branchStart = runGroup(f.mRun), runGroup(f.bRun)
	end
	local t0 = f.t0 or -stem.dir
	local mainSec = RoadSection.shifted(main.sec, if plan.shift then plan.shift[f.main] else 0)
	local mainSide, branchSide = if branchRight then "right" else "left", if branchRight then "left" else "right"
	local function covAt(cov: { number }?): number?
		if not cov or #laneBands == 0 then return nil end
		return (start.bands[laneBands[cov[1]]].x0 + start.bands[laneBands[cov[2]]].x1) * 0.5
	end
	local mg = mains[f.main]
	if not mg then
		local ms0, msecs0, mFollow0 = buildGroup(mainStart, mainSec, node, t0, main, math.max(plan.trims[f.main], 1), mainSide, true, true, stem.pts[1], covAt(f.mCov))
		mg = { ms = ms0, secs = msecs0, follow = mFollow0, len = main.len, skip = {} }
		mains[f.main] = mg
	end
	local ms, msecs, mFollow = mg.ms, mg.secs, mg.follow
	local bs, bsecs, bFollow = buildGroup(branchStart, branch.sec, node, t0, branch, plan.trims[f.branch], branchSide, take > 0, nil, stem.pts[1], covAt(f.bCov))
	-- Side by side, the two roads are ONE surface: the branch sits at the main road's height
	-- beside it and eases onto its own by the end of its group (the main never dips for it). A
	-- ramp climbing or dropping away never floats above the highway or sinks into it beside the
	-- lanes, its kerb wall cutting the markings (user, 2026-10-06).
	local n = #bs
	for i, st in bs do
		local u = math.clamp(((i - 1) / math.max(n - 1, 1) - 0.4) / 0.6, 0, 1) -- held over the first 40%
		local w = u * u * (3 - 2 * u)
		-- past the end of a short main piece (the road runs on as another), carried on at its grade
		local mainY: number
		if st.d <= main.len then
			mainY = at(main, st.d).Y
		else
			local pEnd, pBack = at(main, main.len), at(main, math.max(main.len - 4, 0))
			local run = RoadJunctionSolver.flat(pEnd - pBack).Magnitude
			local grade = if run > 1e-3 then (pEnd.Y - pBack.Y) / run else 0
			mainY = pEnd.Y + grade * (st.d - main.len)
		end
		st.p = Vector3.new(st.p.X, mainY + (st.p.Y - mainY) * w, st.p.Z)
	end

	local n = #bs
	local function outerEdge(secs: { any }, i: number, rightSide: boolean): number
		local bands = secs[i].bands
		return if rightSide then bands[#bands].x1 else bands[1].x0
	end
	local function laneOf(bands: { any }, fromRight: boolean): number?
		if fromRight then
			for i = #bands, 1, -1 do
				if bands[i].k == "lane" then return i end
			end
		else
			for i, bd in bands do
				if bd.k == "lane" then return i end
			end
		end
		return nil
	end
	local mL, bL = laneOf(msecs[1].bands, branchRight), laneOf(bsecs[1].bands, not branchRight)
	local function laneEdge(secs: { any }, i: number, k: number?, rightSide: boolean): number
		if not k then return outerEdge(secs, i, rightSide) end
		local bd = secs[i].bands[k]
		return if rightSide then bd.x1 else bd.x0
	end
	local function nearest(line: { Vector3 }, q: Vector3): Vector3
		local best, bp = math.huge, line[1]
		for i = 1, #line - 1 do
			local a, c = line[i], line[i + 1]
			local seg = c - a
			local len2 = seg:Dot(seg)
			if len2 < 1e-9 then continue end
			local u = (q - a):Dot(seg) / len2
			u = if i < #line - 1 then math.clamp(u, 0, 1) else math.max(u, 0) -- runs on past its end
			local p = a + seg * u
			local dd = RoadJunctionSolver.flat(q - p).Magnitude
			if dd < best then best, bp = dd, p end
		end
		return bp
	end
	local function laneLine(stations: { Station }, secs: { any }, k: number?, rightSide: boolean): { Vector3 }
		local out = table.create(#stations)
		for i, st in stations do out[i] = lateral(st, laneEdge(secs, i, k, rightSide), 0) end
		return out
	end

	-- Until the two roads part, their lanes run side by side: each one's shoulder (verge, ...)
	-- on the gore side opens up only as the lanes come apart, taking half the gap. Grown from the
	-- start, an exit's own shoulder would push its lane off the highway's from the first metre,
	-- and the lines would close the exit off.
	local function pinGoreSide(stations: { Station }, secs: { any }, k: number?, rightSide: boolean, other: { Vector3 })
		if not k then return end
		for i, st in stations do
			local bands = secs[i].bands
			local x = laneEdge(secs, i, k, rightSide)
			local q = lateral(st, x, 0)
			-- toward the other road; overlapping lanes (a shared lane) have opened nothing yet
			local room = math.max(0, (nearest(other, q) - q):Dot(st.r) * (if rightSide then 1 else -1)) * 0.5
			local from, to, step = k + 1, #bands, 1
			if not rightSide then from, to, step = k - 1, 1, -1 end
			for j = from, to, step do
				local bd = bands[j]
				local w = math.min(bd.x1 - bd.x0, room)
				room -= w
				if rightSide then
					bd.x0, bd.x1 = x, x + w
					x += w
				else
					bd.x0, bd.x1 = x - w, x
					x -= w
				end
			end
		end
	end
	local mLaneLine = laneLine(ms, msecs, mL, branchRight)
	local bLaneLine = laneLine(bs, bsecs, bL, not branchRight)
	pinGoreSide(ms, msecs, mL, branchRight, bLaneLine)
	pinGoreSide(bs, bsecs, bL, not branchRight, mLaneLine)
	-- a group along its own road's curve: its dashes on that road's pattern, run on into its body
	-- Where the branch still lies on the main road's lanes (a ramp off an inner lane, lanes both
	-- share) the lines there are the main road's: the branch paints its own only off them, or the
	-- two sets lay side by side (a ramp's solid edge over the highway's dashes).
	-- Nothing a group paints lies behind the stem's cut: a group leaving at an angle starts its
	-- lines on the cut instead of crossing the stem's own edge line there (an X at the corner).
	local cut0 = stem.pts[1]
	local function behindCut(p: Vector3): boolean
		return RoadJunctionSolver.flat(p - cut0):Dot(t0) < -0.05
	end
	local function clipTo(drop: (Vector3) -> boolean): any
		return { addMarkingLine = function(_, pts: { Vector3 }, w: number, col: Color3, dashed: boolean)
			local run = {}
			for _, p in pts do
				if not drop(p) then
					table.insert(run, p)
					continue
				end
				if #run >= 2 then b:addMarkingLine(run, w, col, dashed) end
				run = {}
			end
			if #run >= 2 then b:addMarkingLine(run, w, col, dashed) end
		end }
	end
	local function onMain(p: Vector3): boolean
		local best, bi = math.huge, 1
		for i, st in ms do
			local d = RoadJunctionSolver.flat(p - st.p).Magnitude
			if d < best then best, bi = d, i end
		end
		local st, bands = ms[bi], msecs[bi].bands
		local x = RoadJunctionSolver.flat(p - st.p):Dot(st.r)
		local along = RoadJunctionSolver.flat(p - st.p):Dot(st.t)
		if (bi == 1 and along < 0) then return false end
		return x > bands[1].x0 + 1 and x < bands[#bands].x1 - 1
	end
	mg.paint = mg.paint or clipTo(behindCut)
	local branchPaint = clipTo(function(p: Vector3): boolean return behindCut(p) or onMain(p) end)
	-- the main road's gore side is the gore only where the branch takes its edge lanes: one leaving
	-- from an inner lane crosses the lanes beyond it, and the main keeps its edge line there
	if not (f.mRun and f.bRun and (if branchRight then f.bRun[2] < f.mRun[2] else f.bRun[1] > f.mRun[1])) then
		mg.skip[mainSide] = true
	end
	sweepBands(b, bs, bsecs)
	sweepSkirts(b, bs, bsecs, true, true)
	paintSection(branchPaint, bs, bsecs, spec, false, branchSide, nil, if bFollow then branch.len else nil)

	-- The gore: between the branch's inner edge and the main road's edge beside it, each branch
	-- station paired with the nearest point of the main edge (the two roads run different
	-- lengths, so stations do not pair by index). Its asphalt runs between the roads' outer
	-- edges (a shoulder, maybe); its lines run along the lanes' edges.
	local mRoad, mLane = table.create(#ms), table.create(#ms)
	for i, st in ms do
		mRoad[i] = lateral(st, outerEdge(msecs, i, branchRight), 0)
		mLane[i] = mLaneLine[i]
	end
	local P, Q = table.create(n), table.create(n)     -- road edges: the gore's asphalt
	local Pl, Ql = table.create(n), table.create(n)   -- lane edges: its lines
	local gap, touching = table.create(n), table.create(n)
	for i, st in bs do
		Q[i] = lateral(st, outerEdge(bsecs, i, not branchRight), 0)
		P[i] = nearest(mRoad, Q[i])
		Ql[i] = lateral(st, laneEdge(bsecs, i, bL, not branchRight), 0)
		Pl[i] = nearest(mLane, Ql[i])
		-- signed toward the branch: lanes still overlapping (a shared lane) have not parted
		local signed = (Ql[i] - Pl[i]):Dot(bs[i].r) * (if branchRight then 1 else -1)
		touching[i] = math.abs(signed) < 0.3
		gap[i] = math.max(signed, 0)
	end
	-- The gore is paved only until the two roadways part; past that it is grass to a point
	-- (the nose), never a square block of asphalt out to the mouths.
	local paveTo = n
	for i = 2, n do
		if (Q[i] - P[i]):Dot(bs[i].r) * (if branchRight then 1 else -1) > 0.5 then
			paveTo = i
			break
		end
	end
	local pP, pQ = table.move(P, 1, paveTo, 1, {}), table.move(Q, 1, paveTo, 1, {})
	if branchRight then strip(b, pP, pQ, SURFACE.asphalt, THICK) else strip(b, pQ, pP, SURFACE.asphalt, THICK) end
	-- where the two roads start to part: the point of the gore
	local split = n
	for i = 1, n do
		if gap[i] >= 0.3 then
			split = i
			break
		end
	end
	-- ponytail: no chevrons painted in the gore -- the user took them off every exit and fork
	-- (2026-10-06, "remove this for now"); the gore is its two edge lines.
	local _ = split

	if not mL or not bL then return end
	local mBand, bBand = msecs[1].bands[mL], bsecs[1].bands[bL]
	local sameDir = mBand.d == bBand.d
	local bx = table.create(n)
	for i = 1, n do bx[i] = laneEdge(bsecs, i, bL, not branchRight) end
	-- Until the point of the gore the lanes either side share ONE line, drawn like the line it
	-- continues from the stem (dashed stays dashed), once both lanes are wide enough to need it.
	local ok = table.create(n)
	for i = 1, n do
		local a = msecs[math.min(i, #msecs)].bands[mL]
		local c = bsecs[i].bands[bL]
		ok[i] = i <= split and touching[i] and a.x1 - a.x0 >= MIN_MARKED_LANE and c.x1 - c.x0 >= MIN_MARKED_LANE
	end
	local shared = boundaryStyle(spec, sameDir, false)
	shared.dense = if sameDir and shared.dashed then true else nil
	lineWhere(b, bs, bx, ok, shared)
	-- From the point, two lines open out along the gore's edges (white channelising lines, or a
	-- centre line splitting in two), easing into their lanes to meet each road's own edge line.
	if not spec.edgeLineColor then return end
	local w = LINE_W
	local inset = w * 0.5 + 0.25
	local from = math.max(split - 1, 1)
	local sign = if branchRight then 1 else -1 -- across, from the main road toward the branch
	-- Both leave ONE point, the nose (where the shared line ends), each on its own side, a double
	-- line's strands running straight on into them: started from the two lanes' edges there,
	-- which may still overlap, they pinched or crossed in an X (user, 2026-10-06).
	local strand = if shared.double then shared.width * DOUBLE_GAP else 0
	local nose, across0 = Ql[from], bs[from].r * sign
	local mainLine, branchLine = { nose - across0 * strand + UP * LIFT }, { nose + across0 * strand + UP * LIFT }
	local mEnd = ms[#ms]
	for i = from + 1, n do
		local u = (i - from) / (n - from)
		local ins = strand + (inset - strand) * u
		local across = bs[i].r * sign
		-- the main road's side stops where its group does (a branch dropping a lane runs on further;
		-- `nearest` would carry the main line on straight past it, over the grass)
		if (Pl[i] - mEnd.p):Dot(mEnd.t) < 0.05 then table.insert(mainLine, Pl[i] - across * ins + UP * LIFT) end
		table.insert(branchLine, Ql[i] + across * ins + UP * LIFT)
	end
	-- the main road's side runs on to where its own body takes over
	do
		local last = #ms
		local x = laneEdge(msecs, last, mL, branchRight)
		local tail = lateral(ms[last], if branchRight then x - inset else x + inset, LIFT)
		local prev = mainLine[#mainLine]
		if prev and (tail - prev):Dot(ms[last].t) > 0.05 then table.insert(mainLine, tail) end
	end
	local colour = if sameDir then WHITE else YELLOW -- a centre line splitting round a median
	if #mainLine >= 2 then b:addMarkingLine(mainLine, w, colour, false) end
	if #branchLine >= 2 then b:addMarkingLine(branchLine, w, colour, false) end
end

function RoadGeometry.fork(b: any, plan: any, node: Vector3, spec: any)
	local mains: { [number]: any } = {}
	for _, f in plan.forks or { plan.fork } do
		drawFork(b, plan, f, node, spec, mains)
	end
	for _, mg in mains do
		sweepBands(b, mg.ms, mg.secs)
		sweepSkirts(b, mg.ms, mg.secs, true, true)
		local skip = if mg.skip.left and mg.skip.right then "both" else (if mg.skip.left then "left" elseif mg.skip.right then "right" else nil)
		paintSection(mg.paint, mg.ms, mg.secs, spec, false, skip, nil, if mg.follow then mg.len else nil)
	end
end

-- == Junction box ====================================================================
-- Paved polygon between the arm mouths, its rim running along each arm's roadway edge and
-- round each corner's kerb return; footway corners wrapping those returns.
local function arcPoints(centre: Vector3, from: Vector3, to: Vector3, radius: number, n: number): { Vector3 }
	local a0 = math.atan2(from.Z - centre.Z, from.X - centre.X)
	local a1 = math.atan2(to.Z - centre.Z, to.X - centre.X)
	-- the short way round
	local da = a1 - a0
	while da > math.pi do da -= 2 * math.pi end
	while da < -math.pi do da += 2 * math.pi end
	local out = table.create(n + 1)
	for i = 0, n do
		local a = a0 + da * i / n
		out[i + 1] = Vector3.new(centre.X + math.cos(a) * radius, 0, centre.Z + math.sin(a) * radius)
	end
	return out
end

function RoadGeometry.junction(b: any, plan: any, node: Vector3, spec: any)
	local arms = plan.arms
	local y = node.Y + TOP
	local function edge(armI: number, d: number, side: number): Vector3
		local arm = arms[armI]
		local p, t = at(arm, d)
		local x = if side > 0 then arm.sec.roadR else arm.sec.roadL
		return p + rightOf(t) * x + UP * TOP
	end
	-- A corner with no kerb return (the open side of a T, or the outside of a wide Y): the kerb
	-- runs on from arm a's edge to arm b's, easing across where the two roads differ in width.
	local function openSide(c: any): { Vector3 }
		local A, B = arms[c.a], arms[c.b]
		local ma, mb = plan.trims[c.a], plan.trims[c.b]
		local pts: { Vector3 } = {}
		if c.reflex then
			for i = 0, 4 do table.insert(pts, edge(c.a, ma * (1 - i / 4), 1)) end
			for i = 0, 4 do table.insert(pts, edge(c.b, mb * i / 4, -1)) end
			return pts
		end
		-- A cubic from a's mouth (heading in, -A.dir) to b's (heading out, B.dir): tangent to both
		-- kerbs, so it eases across a width change and bends through an angle in one curve.
		local P0, P1 = edge(c.a, ma, 1), edge(c.b, mb, -1)
		local h = RoadJunctionSolver.flat(P1 - P0).Magnitude / 3
		local C0, C1 = P0 - A.dir * h, P1 - B.dir * h
		local steps = 16
		for i = 0, steps do
			local f = i / steps
			local g = 1 - f
			local p = P0 * (g * g * g) + C0 * (3 * g * g * f) + C1 * (3 * g * f * f) + P1 * (f * f * f)
			table.insert(pts, if i == 0 then P0 elseif i == steps then P1
				else Vector3.new(p.X, P0.Y + (P1.Y - P0.Y) * f, p.Z))
		end
		return pts
	end
	-- The rim, walked counter-clockwise: each corner contributes arm a's right edge from its
	-- mouth in to the kerb return, the return, then arm b's left edge out to ITS mouth.
	local rim: { Vector3 } = {}
	for _, c in plan.corners do
		local ma, mb = plan.trims[c.a], plan.trims[c.b]
		if c.centre then
			table.insert(rim, edge(c.a, ma, 1))
			local cy = node + c.centre
			local A = edge(c.a, c.ta, 1)
			local B = edge(c.b, c.tb, -1)
			table.insert(rim, A)
			-- on a hill the return climbs from one road's edge to the other's (at the node's own
			-- height it stepped at both ends and the box folded into a pyramid -- user, 2026-10-07)
			local arc = arcPoints(cy, A, B, c.radius, 8)
			for i = 2, #arc - 1 do
				local f = (i - 1) / (#arc - 1)
				table.insert(rim, Vector3.new(arc[i].X, A.Y + (B.Y - A.Y) * f, arc[i].Z))
			end
			table.insert(rim, B)
			table.insert(rim, edge(c.b, mb, -1))
		else
			for _, v in openSide(c) do table.insert(rim, v) end
		end
	end
	-- the middle at the rim's mean height: on a slope the box is one tilted surface, not a dent
	local mean = 0
	for _, v in rim do mean += v.Y end
	mean /= math.max(#rim, 1)
	b:addFan(Vector3.new(node.X, mean, node.Z), rim, THICK, SURFACE.asphalt)

	-- Footway along an open side: the kerb above, its back offset outward (mitred at a turn).
	-- A verge carries on along it when the roads either side both plant one there.
	for _, c in plan.corners do
		if c.centre then continue end
		local wA, wB = arms[c.a].sec.walkR, arms[c.b].sec.walkL
		local w = math.max(wA, wB)
		if wA <= 0 then wA = w end
		if wB <= 0 then wB = w end
		local vA, offA = sideVerge(arms[c.a].sec, true)
		local vB, offB = sideVerge(arms[c.b].sec, false)
		local verge: Verge? = if vA and vB then { w = math.min(vA, vB), a = offA, b = offB } else nil
		if w <= 0 then continue end
		local kerb: { Vector3 } = {}
		local ys: { number } = {}
		for i, v in openSide(c) do
			kerb[i] = Vector3.new(v.X, 0, v.Z)
			ys[i] = v.Y
		end
		local back = table.create(#kerb)
		for i = 1, #kerb do
			local n1 = if i > 1 then -rightOf(RoadJunctionSolver.unit(kerb[i] - kerb[i - 1])) else nil
			local n2 = if i < #kerb then -rightOf(RoadJunctionSolver.unit(kerb[i + 1] - kerb[i])) else nil
			local first = (n1 or n2) :: Vector3
			local nrm = RoadJunctionSolver.unit(first + (n2 or first))
			local f = (i - 1) / math.max(#kerb - 1, 1)
			local wi = wA + (wB - wA) * (f * f * (3 - 2 * f))
			back[i] = kerb[i] + nrm * (wi / math.max(nrm:Dot(first), 0.35))
		end
		footwayAlong(b, kerb, back, y, w, verge, ys)
	end
	-- The edge line carries on along an open side, joining the roads either side of it.
	if spec.edgeLineColor then
		local ins = LINE_W * 0.5 + 0.25
		for _, c in plan.corners do
			if c.centre then continue end
			local pts = openSide(c)
			local line = table.create(#pts)
			for i, v in pts do
				local a, d = pts[math.max(i - 1, 1)], pts[math.min(i + 1, #pts)]
				local t = RoadJunctionSolver.unit(RoadJunctionSolver.flat(d - a))
				line[i] = v + rightOf(t) * ins + UP * LIFT -- inward: the road lies right of the kerb
			end
			b:addMarkingLine(line, LINE_W, WHITE, false)
		end
	end

	-- Footway corners: where both arms bring a footway round this corner.
	for _, c in plan.corners do
		local A, B = arms[c.a], arms[c.b]
		local wA, wB = A.sec.walkR, B.sec.walkL
		if (wA <= 0 and wB <= 0) or not c.centre then continue end
		-- each side keeps its own roadside width (a built-out arm's is the wider); an arm with
		-- none takes the other's
		local w = math.max(wA, wB)
		local fA, fB = if wA > 0 then wA else w, if wB > 0 then wB else w
		local ma, mb = plan.trims[c.a], plan.trims[c.b]
		local cy = node + (c.centre :: Vector3)
		-- Kerb path: a's edge from its mouth in to ta, the return, b's edge out to its mouth.
		local kerb: { Vector3 } = {}
		local backP: { Vector3 } = {}
		local function pushArm(armI: number, d: number, side: number, ww: number)
			local arm = arms[armI]
			local p, t = at(arm, d)
			local xr = if side > 0 then arm.sec.roadR else arm.sec.roadL
			local r = rightOf(t)
			table.insert(kerb, p + r * xr)
			table.insert(backP, p + r * (xr + side * ww))
		end
		local steps = 4
		-- A road with no footway: the corner's footway tapers out along its kerb instead of
		-- stopping dead at the end of the return.
		local TAPER = 5
		if wA > 0 then
			for i = 0, steps do pushArm(c.a, ma + (c.ta - ma) * i / steps, 1, fA) end
		else
			pushArm(c.a, c.ta + TAPER, 1, 0)
			pushArm(c.a, c.ta, 1, fA)
		end
		local Ak, Bk = kerb[#kerb], nil :: Vector3?
		local endA = edge(c.b, c.tb, -1)
		local yA, yB = Ak.Y + TOP, endA.Y
		local arc = arcPoints(cy, Ak, endA, c.radius, 8)
		-- The back of the footway: concentric with the kerb return while the return is wider than
		-- the footway; tighter than that, the two back lines simply meet at a sharp corner Q
		-- (never an offset of the return, which cusps -- ROAD_OVERHAUL.md B2).
		local Q: Vector3? = nil
		if c.radius < w then
			local Da, Db = A.dir, B.dir
			local A0 = rightOf(Da) * (A.sec.roadR + fA)
			local B0 = -rightOf(Db) * (-B.sec.roadL + fB)
			local den = Da.X * Db.Z - Da.Z * Db.X
			if math.abs(den) > 1e-6 then
				local wv = B0 - A0
				local tq = (wv.X * Db.Z - wv.Z * Db.X) / den
				Q = node + A0 + Da * tq
			end
		end
		for i = 2, #arc do
			local v = arc[i]
			table.insert(kerb, Vector3.new(v.X, yA + (yB - yA) * (i - 1) / (#arc - 1) - TOP, v.Z))
			if Q then
				table.insert(backP, Vector3.new(Q.X, 0, Q.Z))
			else
				local dir = Vector3.new(cy.X - v.X, 0, cy.Z - v.Z)
				local m = dir.Magnitude
				local ww = fA + (fB - fA) * (i - 1) / (#arc - 1)
				table.insert(backP, Vector3.new(v.X, 0, v.Z) + (if m > 1e-6 then dir / m else Vector3.zero) * ww)
			end
		end
		Bk = endA
		local _ = Bk
		if wB > 0 then
			for i = 1, steps do pushArm(c.b, c.tb + (mb - c.tb) * i / steps, -1, fB) end
		else
			pushArm(c.b, c.tb + TAPER, -1, 0)
		end
		local kT, kL, kB, bT, bL = {}, {}, {}, {}, {}
		for i, v in kerb do
			local yi = v.Y + TOP
			local top = yi + RoadConstants.SIDEWALK_HEIGHT
			kT[i] = Vector3.new(v.X, top, v.Z)
			kB[i] = Vector3.new(v.X, yi, v.Z)
			bT[i] = Vector3.new(backP[i].X, top, backP[i].Z)
			bL[i] = bT[i] - UP * SKIRT
			kL[i] = kT[i]:Lerp(bT[i], math.min(KERB_BAND / math.max((bT[i] - kT[i]).Magnitude, 1e-3), 0.5))
		end
		b:addSurfaceStrip(kT, kL, RoadConstants.KERB_COLOR, THICK)
		b:addSurfaceStrip(kL, bT, SURFACE.concrete, THICK)
		b:addSurfaceStrip(kB, kT, RoadConstants.KERB_COLOR, 0.05)
		b:addSurfaceStrip(bL, bT, SURFACE.concrete, 0.05)
	end
end

-- == Circles: roundabout ring and cul-de-sac bulb ===================================
-- Arc points from `from` to `to` about `centre`, turning the way `ccw` says (increasing
-- atan2(z, x)), however far that is. arcPoints above always takes the short way.
local function arcTurning(centre: Vector3, from: Vector3, to: Vector3, radius: number, ccw: boolean, stepRad: number): { Vector3 }
	local a0 = math.atan2(from.Z - centre.Z, from.X - centre.X)
	local a1 = math.atan2(to.Z - centre.Z, to.X - centre.X)
	local da = a1 - a0
	if ccw then
		while da <= 0 do da += 2 * math.pi end
	else
		while da >= 0 do da -= 2 * math.pi end
	end
	local n = math.max(2, math.ceil(math.abs(da) / stepRad))
	local out = table.create(n + 1)
	for i = 0, n do
		local a = a0 + da * i / n
		out[i + 1] = Vector3.new(centre.X + math.cos(a) * radius, 0, centre.Z + math.sin(a) * radius)
	end
	return out
end

-- The rim from arm a's RIGHT edge to arm b's LEFT edge round the plan's circle: along a's edge
-- in from its mouth, a fillet onto the circle, round the circle, a fillet off it, out along b's
-- edge to ITS mouth. Kerb points and the footway's back points (w out from the kerb), flat.
local function circleRim(plan: any, node: Vector3, ia: number, ib: number, w: number): ({ Vector3 }, { Vector3 })
	local arms = plan.arms
	local A, B = arms[ia], arms[ib]
	local ring = plan.ring
	local c = plan.circleCentre
	local tA, FA, PA = RoadJunctionSolver.edgeToCircle(A, 1, c, ring.outer, ring.fillet)
	local tB, FB, PB = RoadJunctionSolver.edgeToCircle(B, -1, c, ring.outer, ring.fillet)
	local kerb, back = {}, {}
	local function push(k: Vector3, bk: Vector3)
		table.insert(kerb, Vector3.new(k.X, 0, k.Z))
		table.insert(back, Vector3.new(bk.X, 0, bk.Z))
	end
	local function armEdge(arm: any, d: number, side: number)
		local p, t = at(arm, d)
		local r = rightOf(t)
		local e = if side > 0 then arm.sec.roadR else arm.sec.roadL
		push(p + r * e, p + r * (e + side * w))
	end
	local mA, mB = plan.trims[ia], plan.trims[ib]
	for i = 0, 3 do armEdge(A, mA + (tA - mA) * i / 3, 1) end
	local fA = node + FA
	local cc = node + c
	-- fillet onto the circle (concave seen from the road: the footway lies toward its centre)
	local f1 = arcPoints(fA, node + rightOf(A.dir) * A.sec.roadR + A.dir * tA, node + PA, ring.fillet, 6)
	for i = 2, #f1 do
		local v = f1[i]
		push(v, v:Lerp(Vector3.new(fA.X, 0, fA.Z), math.min(w / ring.fillet, 1)))
	end
	-- round the circle, counter-clockwise (the road is inside, the footway outside)
	local arc = arcTurning(cc, node + PA, node + PB, ring.outer, true, math.rad(6))
	for i = 2, #arc do
		local v = arc[i]
		local out = Vector3.new(v.X - cc.X, 0, v.Z - cc.Z).Unit
		push(v, v + out * w)
	end
	local fB = node + FB
	local f2 = arcPoints(fB, node + PB, node - rightOf(B.dir) * (-B.sec.roadL) + B.dir * tB, ring.fillet, 6)
	for i = 2, #f2 do
		local v = f2[i]
		push(v, v:Lerp(Vector3.new(fB.X, 0, fB.Z), math.min(w / ring.fillet, 1)))
	end
	for i = 1, 3 do armEdge(B, tB + (mB - tB) * i / 3, -1) end
	return kerb, back
end


local function byAngle(arms: { any }): { number }
	local order = {}
	for i in arms do table.insert(order, i) end
	table.sort(order, function(x, y)
		return math.atan2(arms[x].dir.Z, arms[x].dir.X) < math.atan2(arms[y].dir.Z, arms[y].dir.X)
	end)
	return order
end

-- Raised island: kerb ring and a planted top.
local function island(b: any, centre: Vector3, r: number, y: number)
	if r <= 0 then return end
	local top = y + RoadConstants.SIDEWALK_HEIGHT
	local n = math.max(16, math.ceil(2 * math.pi * r / 2))
	local ringPts, lo, lip = {}, {}, {}
	for i = 0, n do
		local a = 2 * math.pi * i / n
		local d = Vector3.new(math.cos(a), 0, math.sin(a))
		ringPts[i + 1] = Vector3.new(centre.X, top, centre.Z) + d * r
		lo[i + 1] = Vector3.new(centre.X, y, centre.Z) + d * r
		lip[i + 1] = Vector3.new(centre.X, top, centre.Z) + d * math.max(r - KERB_BAND, 0)
	end
	b:addSurfaceStrip(lo, ringPts, RoadConstants.KERB_COLOR, 0.05)
	b:addSurfaceStrip(lip, ringPts, RoadConstants.KERB_COLOR, THICK)
	local tris = {}
	local c = Vector3.new(centre.X, top + 0.01, centre.Z)
	for i = 1, n do
		table.insert(tris, c)
		table.insert(tris, lip[i] + UP * 0.01)
		table.insert(tris, lip[i + 1] + UP * 0.01)
	end
	b:addTris(tris, GRASS)
end

-- A dashed line round part of a circle.
local function circleDashes(b: any, centre: Vector3, r: number, y: number, from: number, to: number, width: number)
	local pts = {}
	local n = math.max(8, math.ceil(math.abs(to - from) * r / 1.5))
	for i = 0, n do
		local a = from + (to - from) * i / n
		table.insert(pts, Vector3.new(centre.X + math.cos(a) * r, y + LIFT, centre.Z + math.sin(a) * r))
	end
	emitDashed(b, pts, width, WHITE)
end

-- A roundabout on a junction: a paved ring between flared kerbs, a planted island in the
-- middle, every entry giving way to the ring with a dashed line where it meets the circle.
function RoadGeometry.ring(b: any, plan: any, node: Vector3, spec: any)
	local arms = plan.arms
	local ring = plan.ring
	local y = node.Y + TOP
	local order = byAngle(arms)
	local rim: { Vector3 } = {}
	for k = 1, #order do
		local ia, ib = order[k], order[k % #order + 1]
		local w = math.max(arms[ia].sec.walkR, arms[ib].sec.walkL)
		local kerb, back = circleRim(plan, node, ia, ib, math.max(w, 1))
		for _, v in kerb do table.insert(rim, Vector3.new(v.X, y, v.Z)) end
		if w > 0 then footwayAlong(b, kerb, back, y, w) end
	end
	b:addFan(node + UP * TOP, rim, THICK, SURFACE.asphalt)
	island(b, node, ring.island, y)
	-- the ring's two lanes
	circleDashes(b, node, (ring.island + ring.outer) * 0.5, y, 0, 2 * math.pi, 0.4)
	-- entries give way where they meet the ring
	for _, arm in arms do
		local lanes = RoadSection.lanes(arm.sec, -1)
		if #lanes == 0 then continue end
		local lo, hi = math.huge, -math.huge
		for _, bd in lanes do lo = math.min(lo, bd.x0); hi = math.max(hi, bd.x1) end
		local R = ring.outer - 0.8
		local function angleAt(x: number): number
			local t = math.sqrt(math.max(R * R - x * x, 0))
			local p = rightOf(arm.dir) * x + arm.dir * t
			return math.atan2(p.Z, p.X)
		end
		local a0, a1 = angleAt(lo + 0.3), angleAt(hi - 0.3)
		if a1 < a0 - math.pi then a1 += 2 * math.pi elseif a1 > a0 + math.pi then a1 -= 2 * math.pi end
		-- give way: short heavy dashes along the circle across the entry
		local n = math.max(3, math.floor(math.abs(a1 - a0) * R / 1.2))
		for k = 0, n - 1, 2 do
			local u0, u1 = a0 + (a1 - a0) * k / n, a0 + (a1 - a0) * (k + 1) / n
			b:addMarkingLine({
				Vector3.new(node.X + math.cos(u0) * R, y + LIFT, node.Z + math.sin(u0) * R),
				Vector3.new(node.X + math.cos(u1) * R, y + LIFT, node.Z + math.sin(u1) * R),
			}, 0.6, WHITE, false)
		end
	end
end

-- A cul-de-sac: the road's end opens into a round turning bulb with the footway all round it.
function RoadGeometry.culdesac(b: any, plan: any, node: Vector3, spec: any)
	local arm = plan.arms[1]
	local y = node.Y + TOP
	local w = math.max(arm.sec.walkL, arm.sec.walkR)
	local kerb, back = circleRim(plan, node, 1, 1, math.max(w, 1))
	local rim: { Vector3 } = {}
	for _, v in kerb do table.insert(rim, Vector3.new(v.X, y, v.Z)) end
	b:addFan(node + plan.circleCentre + UP * TOP, rim, THICK, SURFACE.asphalt)
	if w > 0 then
		local vR, offR = sideVerge(arm.sec, true)
		local vL, offL = sideVerge(arm.sec, false)
		local verge: Verge? = if vR and vL then { w = math.min(vR, vL), a = offR, b = offL } else nil
		footwayAlong(b, kerb, back, y, w, verge)
	else
		local lo = {}
		for i, v in rim do lo[i] = v - UP * SKIRT end
		b:addSurfaceStrip(lo, rim, SURFACE.concrete, 0.05)
	end
	-- The edge lines run on round the bulb, just inside its kerb.
	local bands = arm.sec.bands
	local li, ri
	for i, bd in bands do
		if bd.k == "lane" then
			li = li or i
			ri = i
		end
	end
	if not spec.edgeLineColor or not li then return end
	local lw = LINE_W
	local inset = lw * 0.5 + 0.25
	local centre = node + plan.circleCentre
	local line = table.create(#kerb)
	for i, v in kerb do
		local a, c = kerb[math.max(i - 1, 1)], kerb[math.min(i + 1, #kerb)]
		local t = RoadJunctionSolver.unit(RoadJunctionSolver.flat(c - a))
		local nrm = rightOf(t)
		if nrm:Dot(RoadJunctionSolver.flat(centre - v)) < 0 then nrm = -nrm end -- toward the road
		line[i] = Vector3.new(v.X, y + LIFT, v.Z) + nrm * inset
	end
	b:addMarkingLine(line, lw, edgeColor(bands[ri], true), false)
end

return table.freeze(RoadGeometry)
