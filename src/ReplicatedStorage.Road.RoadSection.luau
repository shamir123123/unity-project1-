--!strict
-- RoadSection -- a profile laid out ACROSS the road in studs, as seen from one end: bands with
-- lateral extents and surface heights, the roadway edges, the footways. Pure library.
--
-- Every node looks at its arms OUTWARD (from the node toward the far end), so a section is
-- built either along the curve (the arm starts at this node) or flipped (it ends here):
-- flipped mirrors left and right and turns every lane round. In the outward frame a lane with
-- d = +1 LEAVES the node and d = -1 ARRIVES at it -- which is all a junction needs to know.
--
-- Heights are above the asphalt top. Footways, verges and raised medians stand SIDEWALK_HEIGHT
-- proud (the kerb); lanes, parking and painted medians lie flush.

local RoadConstants = require(script.Parent.RoadConstants)
local RoadProfile = require(script.Parent.RoadProfile)

local RoadSection = {}

local KERB = RoadConstants.SIDEWALK_HEIGHT

export type Band = {
	k: string,     -- "lane" | "park" | "median" | "verge" | "walk"
	x0: number,    -- left edge, studs (+ = right of the section's direction)
	x1: number,    -- right edge
	top: number,   -- surface height above the asphalt top
	surf: string,  -- "asphalt" | "concrete" | "grass" | "red" | "paint"
	d: number?,    -- lanes: +1 leaves the node / travels along the section, -1 arrives
	bus: boolean?,
	ordinal: number?, -- lanes: 1 = against the centre, count = kerbside (per direction)
	count: number?,   -- lanes: lanes in this direction
	angle: number?,   -- parking: angled stalls (degrees to the kerb)
}

export type Section = {
	bands: { Band },
	roadL: number, -- left roadway edge (everything but the roadsides: the kerb line), negative
	roadR: number, -- right roadway edge
	walkL: number, -- roadside width on each side: footway + any verge planted in it (0 = none)
	walkR: number,
	highway: boolean,
	oneWay: boolean,
}

local function surfaceOf(s: any): (number, string)
	if s.k == "walk" then return KERB, "concrete" end
	if s.k == "verge" then return KERB, "grass" end
	if s.k == "median" then
		if s.surf == "paint" then return 0, "asphalt" end -- a painted median is road with hatching
		return KERB, (if s.surf == "concrete" then "concrete" else "grass")
	end
	if s.k == "lane" and s.bus then return 0, "red" end
	if (s.k == "lane" or s.k == "shoulder") and s.surf then return 0, s.surf end -- a pedestrian street's paving
	return 0, "asphalt"
end

-- `profile` from RoadProfile; `flip` = look at it from the curve's END (outward from p3).
-- `laneSide` is RoadRules.getLaneSideSign() (+1 right-hand traffic): a two-way road's lane
-- directions mirror for left-hand traffic, exactly as RoadProfile.lanes does.
function RoadSection.of(profile: any, flip: boolean, laneSide: number?): Section
	local side = laneSide or 1
	local strips = profile.strips
	local roadW, walkL, walkR = RoadProfile.widths(profile)
	local oneWay = true
	for _, s in strips do
		if s.k == "lane" and (s.d or 1) < 0 then oneWay = false end
	end

	-- Lay the strips out along the curve first, then mirror if we look from the far end.
	local bands: { Band } = {}
	local x = -roadW * 0.5 - walkL
	for _, s in strips do
		local top, surf = surfaceOf(s)
		local d: number? = nil
		if s.k == "lane" then
			d = s.d or 1
			if not oneWay then d = (d :: number) * side end
		end
		table.insert(bands, { k = s.k, x0 = x, x1 = x + s.w, top = top, surf = surf, d = d, bus = s.bus, angle = s.angle })
		x += s.w
	end
	if flip then
		local mirrored: { Band } = {}
		for i = #bands, 1, -1 do
			local b = bands[i]
			table.insert(mirrored, {
				k = b.k, x0 = -b.x1, x1 = -b.x0, top = b.top, surf = b.surf,
				d = if b.d then -(b.d :: number) else nil, bus = b.bus, angle = b.angle,
			})
		end
		bands = mirrored
		walkL, walkR = walkR, walkL
	end

	-- Ordinals per direction, as RoadProfile.lanes numbers them: on a two-way road 1 is the
	-- lane against the divider between the directions; on a one-way, the lane on the crossing-
	-- turn side (left of travel for right-hand traffic).
	local fwd: { Band } = {}
	local back: { Band } = {}
	for _, b in bands do
		if b.k == "lane" then
			if (b.d :: number) > 0 then table.insert(fwd, b) else table.insert(back, b) end
		end
	end
	local function number(list: { Band }, key: (Band) -> number)
		table.sort(list, function(a, b) return key(a) < key(b) end)
		for i, b in list do
			b.ordinal = i
			b.count = #list
		end
	end
	if oneWay then
		-- a lane leaving the node has its left on the -x side, one arriving on the +x side
		local sign = if #fwd > 0 then side else -side
		number(if #fwd > 0 then fwd else back, function(b) return sign * (b.x0 + b.x1) end)
	else
		-- The divider is the gap between the two direction groups (a median's middle, or the
		-- line between the innermost lanes).
		local leftGroup, rightGroup = back, fwd
		if fwd[1].x0 < back[1].x0 then leftGroup, rightGroup = fwd, back end
		local hi, lo = -math.huge, math.huge
		for _, b in leftGroup do hi = math.max(hi, b.x1) end
		for _, b in rightGroup do lo = math.min(lo, b.x0) end
		local divider = (hi + lo) * 0.5
		local function dist(b: Band): number return math.abs((b.x0 + b.x1) * 0.5 - divider) end
		number(fwd, dist)
		number(back, dist)
	end

	return {
		bands = bands,
		roadL = -roadW * 0.5,
		roadR = roadW * 0.5,
		walkL = walkL,
		walkR = walkR,
		highway = profile.highway == true,
		oneWay = oneWay,
	}
end

-- The same section moved `dx` to the right (a road drawn off its curve: see
-- RoadJunctionSolver.carryShifts).
function RoadSection.shifted(sec: Section, dx: number): Section
	if dx == 0 then return sec end
	local bands = table.create(#sec.bands)
	for i, b in sec.bands do
		local c = table.clone(b)
		c.x0 += dx
		c.x1 += dx
		bands[i] = c
	end
	return { bands = bands, roadL = sec.roadL + dx, roadR = sec.roadR + dx, walkL = sec.walkL, walkR = sec.walkR,
		highway = sec.highway, oneWay = sec.oneWay }
end

-- Kerb build-outs (curb extensions): every parking band split into a raised footway build-out
-- on its kerb side, `u` of its width, and the parking left beside the lanes. u = 1 is the full
-- build-out at a junction (the kerb on the lane edge, the parking gone); 0 keeps the parking with
-- a zero-width build-out, so a taper sweeps one into the other band for band. A verge planted on
-- that kerb moves out with it (the build-out is path behind it). The roadway edges follow the
-- kerb; the roadsides grow by what they gain. No parking: `sec` itself.
function RoadSection.bulbed(sec: Section, u: number): Section
	local any = false
	for _, b in sec.bands do
		if b.k == "park" then any = true break end
	end
	if not any then return sec end
	local mid = (sec.roadL + sec.roadR) * 0.5
	local bands: { Band } = {}
	local roadL, roadR = sec.roadL, sec.roadR
	local src = sec.bands
	local i = 0
	while i < #src do
		i += 1
		local b = src[i]
		if b.k ~= "park" then
			table.insert(bands, b)
			continue
		end
		local w = (b.x1 - b.x0) * u
		local function moved(v: Band, dx: number): Band
			local c = table.clone(v)
			c.x0 += dx
			c.x1 += dx
			return c
		end
		if b.x1 <= mid then -- left kerb: build-out, (verge,) then the parking
			local verge = bands[#bands]
			if verge and verge.k == "verge" and math.abs(verge.x1 - b.x0) < 1e-3 then
				table.remove(bands)
				table.insert(bands, { k = "walk", x0 = verge.x0, x1 = verge.x0 + w, top = KERB, surf = "concrete" })
				table.insert(bands, moved(verge, w))
			else
				table.insert(bands, { k = "walk", x0 = b.x0, x1 = b.x0 + w, top = KERB, surf = "concrete" })
			end
			table.insert(bands, { k = "park", x0 = b.x0 + w, x1 = b.x1, top = 0, surf = b.surf })
			roadL = math.max(roadL, b.x0 + w)
		else -- right kerb: the parking, (verge,) then the build-out
			table.insert(bands, { k = "park", x0 = b.x0, x1 = b.x1 - w, top = 0, surf = b.surf })
			local verge = src[i + 1]
			if verge and verge.k == "verge" and math.abs(verge.x0 - b.x1) < 1e-3 then
				i += 1
				table.insert(bands, moved(verge, -w))
				table.insert(bands, { k = "walk", x0 = verge.x1 - w, x1 = verge.x1, top = KERB, surf = "concrete" })
			else
				table.insert(bands, { k = "walk", x0 = b.x1 - w, x1 = b.x1, top = KERB, surf = "concrete" })
			end
			roadR = math.min(roadR, b.x1 - w)
		end
	end
	return { bands = bands, roadL = roadL, roadR = roadR, walkL = sec.walkL + (roadL - sec.roadL),
		walkR = sec.walkR + (sec.roadR - roadR), highway = sec.highway, oneWay = sec.oneWay }
end

-- A bus bay: the kerb on each side stepped back `depthL` / `depthR` into the roadside, the
-- footway (and any verge) narrowing by as much. The bands are the same at any depth (0 = no
-- bay), so a taper sweeps from one depth to another.
function RoadSection.bayed(sec: Section, depthL: number, depthR: number): Section
	local roadL, roadR = sec.roadL - depthL, sec.roadR + depthR
	local bands: { Band } = {}
	local leftDone = false
	for _, b in sec.bands do
		if b.x1 <= sec.roadL + 1e-3 then
			local c = table.clone(b)
			c.x1 = math.min(c.x1, roadL)
			c.x0 = math.min(c.x0, c.x1)
			table.insert(bands, c)
			continue
		end
		if not leftDone then
			leftDone = true
			table.insert(bands, { k = "bay", x0 = roadL, x1 = sec.roadL, top = 0, surf = "asphalt" })
		end
		if b.x0 >= sec.roadR - 1e-3 then
			if bands[#bands].k ~= "bay" or bands[#bands].x0 < sec.roadR - 1e-3 then
				table.insert(bands, { k = "bay", x0 = sec.roadR, x1 = roadR, top = 0, surf = "asphalt" })
			end
			local c = table.clone(b)
			c.x0 = math.max(c.x0, roadR)
			c.x1 = math.max(c.x1, c.x0)
			table.insert(bands, c)
		else
			table.insert(bands, b)
		end
	end
	if bands[#bands].x1 <= sec.roadR + 1e-3 then -- no right roadside at all
		table.insert(bands, { k = "bay", x0 = sec.roadR, x1 = roadR, top = 0, surf = "asphalt" })
	end
	return { bands = bands, roadL = roadL, roadR = roadR, walkL = math.max(sec.walkL - depthL, 0),
		walkR = math.max(sec.walkR - depthR, 0), highway = sec.highway, oneWay = sec.oneWay }
end

-- The widest parking band (what a build-out covers), 0 if none.
function RoadSection.parkWidth(sec: Section): number
	local w = 0
	for _, b in sec.bands do
		if b.k == "park" then w = math.max(w, b.x1 - b.x0) end
	end
	return w
end

-- The bands arriving at / leaving the node, in left-to-right order.
function RoadSection.lanes(sec: Section, dir: number): { Band }
	local out: { Band } = {}
	for _, b in sec.bands do
		if b.k == "lane" and b.d == dir then table.insert(out, b) end
	end
	return out
end

return table.freeze(RoadSection)
