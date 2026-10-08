--!strict
-- RoadProfile -- a road's CROSS-SECTION: an ordered list of strips, LEFT to RIGHT looking along
-- the drawn curve (p0 -> p3). Lanes, parking, medians, verges and footways are all strips, so
-- what a road is across its width -- where cars drive, where paint goes, where parking and
-- footways are -- comes from one list. Pure library: no state, no Instances.
--
-- The drawn curve runs down the middle of the ROADWAY (every strip except the roadsides); the
-- roadsides hang outside it. A roadside is a footway, or a verge planted in one between kerb and
-- path (isSide). That is where the catalog has always put the centreline, so zoning, grading
-- and parking, which measure from spec.width, read a profile exactly as before.
--
-- Lane directions are authored for RIGHT-hand traffic (+1 = travels p0 -> p3). lanes() mirrors
-- a two-way road for left-hand traffic; a one-way keeps its direction either way.
--
-- Two sources:
--   fromSpec(spec)  every catalog road and "Base|k=v" config, laid out where the old fields put
--                   things (RoadProfile.spec proves it lane by lane).
--   decode(body)    a player-built road carried IN its roadType id as "P:<body>" -- the trick the
--                   config codes already use: the id persists, replicates, saves and undoes for
--                   free. decode IS the security boundary: it rebuilds every value it keeps.

local RoadConstants = require(script.Parent.RoadConstants)

local RoadProfile = {}

export type Strip = {
	k: string,     -- "lane" | "park" | "median" | "verge" | "shoulder" | "walk"
	w: number,     -- studs
	d: number?,    -- lanes: +1 travels p0 -> p3, -1 travels back (right-hand authoring)
	bus: boolean?, -- lanes: buses / emergency / service only
	surf: string?, -- median / verge: "grass" | "concrete" | "paint"
	angle: number?, -- parking: stalls at this many degrees to the kerb (nil = parallel)
}

export type Profile = {
	strips: { Strip },
	busKerb: boolean?, -- the kerbside lane of every direction with 2+ lanes is bus-only
	highway: boolean?, -- highway family: no crosswalks, signal-free junctions
	speed: number?,    -- km/h; nil = the class default
}

-- Same shape RoadNavigationGraph has always built its edges from. `offset` is studs to the
-- RIGHT of the curve's own direction (p0 -> p3), whichever way the lane travels.
export type Lane = {
	offset: number,
	forward: boolean,
	laneIndex: number,
	laneOrdinal: number, -- 1 = against the centre / median, laneCountInDirection = kerbside
	laneCountInDirection: number,
	width: number,
	bus: boolean,
}

-- Every highway lane is this wide (3.5 m), whatever the road: the rest of its width is paved
-- shoulder outside the edge lines. Lanes of different highway types then line up exactly where
-- one runs into another (a 3-lane highway dropping a lane into an exit carries straight on).
local HIGHWAY_LANE = 7

-- Strip i stands outside the roadway: a footway, or a verge planted in one.
function RoadProfile.isSide(strips: { Strip }, i: number): boolean
	local s = strips[i]
	if s.k == "walk" then return true end
	if s.k ~= "verge" then return false end
	local a, b = strips[i - 1], strips[i + 1]
	return (a ~= nil and a.k == "walk") or (b ~= nil and b.k == "walk")
end

local function lane(w: number, d: number): Strip
	return { k = "lane", w = w, d = d }
end

-- Which kerbs park at an angle (spec.parkingAngle on spec.angledSide; the right by default).
function RoadProfile.angledSides(spec: any): (boolean, boolean)
	if not spec.parkingAngle then return false, false end
	local s = spec.angledSide or "right"
	return s == "left" or s == "both", s == "right" or s == "both"
end

-- Parking width on each kerb (left, right): a kerb that parks at an angle takes a strip
-- angledParkingWidth wide.
function RoadProfile.parkingWidths(spec: any): (number, number)
	if not spec.parkingLane then return 0, 0 end
	local w = spec.parkingLaneWidth or 0
	local side = spec.parkingSide or (if (spec.parkingSides or 2) >= 2 then "both" else "right")
	local angL, angR = RoadProfile.angledSides(spec)
	local aw = spec.angledParkingWidth or w
	return (if side == "left" or side == "both" then (if angL then aw else w) else 0),
		(if side == "right" or side == "both" then (if angR then aw else w) else 0)
end
local parkingOf = RoadProfile.parkingWidths

-- Angled stalls: one every STALL_SPACING studs along the kerb. ParkingService and the paint
-- share it.
RoadProfile.STALL_SPACING = 8

-- Footway on each kerb (left, right), 0 where there is none. A road with a roadsideWidth keeps
-- that much beside every paved kerb and cuts its parking out of it; any other road has
-- SIDEWALK_WIDTH whatever its parking.
function RoadProfile.footways(spec: any): (number, number)
	local mode = spec.sidewalkMode or (if spec.noSidewalk then "none" else "both")
	local l = if mode == "both" or mode == "left" then RoadConstants.SIDEWALK_WIDTH else 0
	local r = if mode == "both" or mode == "right" then RoadConstants.SIDEWALK_WIDTH else 0
	local side = spec.roadsideWidth
	if not side then return l, r end
	local parkL, parkR = parkingOf(spec)
	-- a strip of angled stalls is wider than the roadside: the footway keeps its own width then
	return (if l > 0 then math.max(side - parkL, l) else 0), (if r > 0 then math.max(side - parkR, r) else 0)
end

-- Height above a road's curve (the asphalt slab's CENTRE) of the ground beside it on `side`
-- (-1 left, +1 right of the curve's direction): the footway top where that kerb is paved, the
-- asphalt top where it is not. Roadside props pivot at their base and stand on this; adding only
-- SIDEWALK_HEIGHT left every lamp, sign and cabinet a stud down inside the pavement.
function RoadProfile.roadsideLift(spec: any, side: number): number
	local l, r = RoadProfile.footways(spec)
	local paved = (if side < 0 then l else r) > 0
	return RoadConstants.ROAD_THICKNESS * 0.5 + (if paved then RoadConstants.SIDEWALK_HEIGHT else 0)
end

-- == From the catalog ===========================================================
-- The old fields describe the same road in pieces: a carriageway (width minus aprons) split
-- into equal lanes about an optional median, parking aprons and planted verges stacked
-- outside it (verge outermost), footways outside that. Rail is not a road and has no profile.
function RoadProfile.fromSpec(spec: any): Profile?
	if spec.isRail or spec.terrainPath then return nil end
	if spec.pedestrian then
		-- Paved wall to wall: a service lane each way down the middle (deliveries, services),
		-- the rest open paving either side of it.
		local lane = 7
		local side = math.max((spec.width - 2 * lane) * 0.5, 0)
		return {
			pedestrian = true,
			strips = {
				{ k = "shoulder", w = side, surf = "paving" },
				{ k = "lane", w = lane, d = -1, surf = "pavingLight" },
				{ k = "lane", w = lane, d = 1, surf = "pavingLight" },
				{ k = "shoulder", w = side, surf = "paving" },
			},
		}
	end
	local parkL, parkR = parkingOf(spec)
	local angL, angR = RoadProfile.angledSides(spec)
	local vergeL, vergeR = 0, 0
	if spec.vergeMode then
		vergeL = spec.vergeWidth or 0
		if spec.vergeMode == "both" then vergeR = vergeL end
	end
	local walkL, walkR = RoadProfile.footways(spec)
	-- A verge beside a footway is planted IN it (the path narrows, the road keeps its width);
	-- only on a side with no footway does it come off the roadway (RoadTypeCatalog.vergeCarve).
	local carveL = if walkL > 0 then 0 else vergeL
	local carveR = if walkR > 0 then 0 else vergeR

	local n = math.max(1, spec.laneCount or 2)
	-- The catalog's floor: a road whose aprons would eat more than 60% of it keeps 40% to drive on
	-- (RoadTypeCatalog.carriagewayWidth), even if that overlaps the aprons a little.
	local carriage = math.max(spec.width - parkL - parkR - carveL - carveR, spec.width * 0.4)
	local shoulder = 0
	if spec.isHighway then
		local medianW = if spec.median then (spec.medianWidth or 4) else 0
		shoulder = math.max(0, (carriage - medianW - n * HIGHWAY_LANE) * 0.5)
		carriage -= 2 * shoulder
	end
	local strips: { Strip } = {}
	local function add(s: Strip?)
		if s and s.w > 0 then table.insert(strips, s) end
	end

	add({ k = "walk", w = walkL - (vergeL - carveL) })
	add({ k = "verge", w = vergeL, surf = "grass" })
	add({ k = "park", w = parkL, angle = if angL and parkL > 0 then spec.parkingAngle else nil })
	add({ k = "shoulder", w = shoulder })
	if spec.oneWay then
		for _ = 1, n do add(lane(carriage / n, 1)) end
	else
		local medianW = if spec.median then (spec.medianWidth or 4) else 0
		local laneW = (carriage - medianW) / n
		-- lanesBack: an uneven road (2 + 1); otherwise the lanes split evenly
		local back = spec.lanesBack or math.max(1, n // 2)
		local fwd = if spec.lanesBack then n - back else back
		for _ = 1, back do add(lane(laneW, -1)) end
		add({ k = "median", w = medianW, surf = spec.medianSurface or "grass" })
		for _ = 1, fwd do add(lane(laneW, 1)) end
	end
	add({ k = "shoulder", w = shoulder })
	add({ k = "park", w = parkR, angle = if angR and parkR > 0 then spec.parkingAngle else nil })
	add({ k = "verge", w = vergeR, surf = "grass" })
	add({ k = "walk", w = walkR - (vergeR - carveR) })

	return {
		strips = strips,
		busKerb = if spec.busLane then true else nil,
		highway = if spec.isHighway then true else nil,
	}
end

-- == Lanes ======================================================================
-- `laneSide` is RoadRules.getLaneSideSign(): +1 drives on the right. Numbering keeps the old
-- edge ids: a one-way counts its lanes left to right; a two-way numbers the forward lanes from
-- the centre outward, then the backward ones the same way.
function RoadProfile.lanes(p: Profile, laneSide: number): { Lane }
	local roadW = RoadProfile.widths(p)
	type Raw = { c: number, d: number, w: number, bus: boolean, l: number, r: number }
	local raw: { Raw } = {}
	local oneWay = true
	local x = -roadW * 0.5
	for i, s in p.strips do
		if RoadProfile.isSide(p.strips, i) then continue end
		if s.k == "lane" then
			local d = s.d or 1
			if d < 0 then oneWay = false end
			table.insert(raw, { c = x + s.w * 0.5, d = d, w = s.w, bus = s.bus == true, l = x, r = x + s.w })
		end
		x += s.w
	end

	local out: { Lane } = {}
	if oneWay then
		local count = #raw
		for i, r in raw do
			local ordinal = if laneSide >= 0 then i else count - i + 1
			table.insert(out, {
				offset = r.c, forward = true, laneIndex = i, laneOrdinal = ordinal,
				laneCountInDirection = count, width = r.w,
				bus = r.bus or (p.busKerb == true and count >= 2 and ordinal == count),
			})
		end
		return out
	end

	-- The divider is the gap between the two direction groups (a median's centre, or the line
	-- between the innermost lanes), measured in the authoring layout.
	local lastBack, firstFwd = -math.huge, math.huge
	for _, r in raw do
		if r.d < 0 then lastBack = math.max(lastBack, r.r) else firstFwd = math.min(firstFwd, r.l) end
	end
	local divider = (lastBack + firstFwd) * 0.5
	local fwd: { Raw } = {}
	local back: { Raw } = {}
	for _, r in raw do
		-- Left-hand traffic mirrors who travels where; the strips stay put.
		if r.d * laneSide > 0 then table.insert(fwd, r) else table.insert(back, r) end
	end
	local function byCentre(a: Raw, b: Raw): boolean
		return math.abs(a.c - divider) < math.abs(b.c - divider)
	end
	table.sort(fwd, byCentre)
	table.sort(back, byCentre)
	for i, r in fwd do
		table.insert(out, {
			offset = r.c, forward = true, laneIndex = i, laneOrdinal = i,
			laneCountInDirection = #fwd, width = r.w,
			bus = r.bus or (p.busKerb == true and #fwd >= 2 and i == #fwd),
		})
	end
	for i, r in back do
		table.insert(out, {
			offset = r.c, forward = false, laneIndex = #fwd + i, laneOrdinal = i,
			laneCountInDirection = #back, width = r.w,
			bus = r.bus or (p.busKerb == true and #back >= 2 and i == #back),
		})
	end
	return out
end

-- Centre of every strip of one kind, studs right of the curve, left to right. Parking bays,
-- medians and verges stand where these say -- the same numbers the lanes come from.
function RoadProfile.offsets(p: Profile, kind: string): { number }
	local roadW = RoadProfile.widths(p)
	local out: { number } = {}
	local x = -roadW * 0.5
	for i, s in p.strips do
		if RoadProfile.isSide(p.strips, i) then continue end
		if s.k == kind then table.insert(out, x + s.w * 0.5) end
		x += s.w
	end
	return out
end

-- Every parking strip: its centre (studs right of the curve), width, stall angle (nil =
-- parallel) and lean: +1 when the lane beside it travels along the curve, -1 against.
function RoadProfile.parkRows(p: Profile, laneSide: number?): { { x: number, w: number, angle: number?, lean: number } }
	local roadW = RoadProfile.widths(p)
	local twoWay = false
	for _, s in p.strips do
		if s.k == "lane" and (s.d or 1) < 0 then twoWay = true end
	end
	local out = {}
	local x = -roadW * 0.5
	for i, s in p.strips do
		if RoadProfile.isSide(p.strips, i) then continue end
		if s.k == "park" then
			local c = x + s.w * 0.5
			local step = if c < 0 then 1 else -1
			local j = i + step
			while p.strips[j] and p.strips[j].k ~= "lane" do j += step end
			local beside = p.strips[j]
			local lean = if beside then (beside.d or 1) * (if twoWay then (laneSide or 1) else 1) else 1
			table.insert(out, { x = c, w = s.w, angle = s.angle, lean = lean })
		end
		x += s.w
	end
	return out
end

-- Roadway width (everything but the roadsides) and each roadside (footway + its verge), in studs.
function RoadProfile.widths(p: Profile): (number, number, number)
	local roadW, walkL, walkR = 0, 0, 0
	for i, s in p.strips do
		if not RoadProfile.isSide(p.strips, i) then
			roadW += s.w
		elseif roadW == 0 then
			walkL += s.w
		else
			walkR += s.w
		end
	end
	return roadW, walkL, walkR
end

-- == Encoding ===================================================================
-- body = strips joined by ","; then optional ";" flags. A strip is a kind letter, its width in
-- QUARTER studs, then modifiers: lanes "+"/"-" (direction) and "B" (bus); medians/verges a
-- surface letter. Flags: "K" bus kerb lanes, "H" highway, "S<kmh>" speed.
-- e.g. "w24,p20,l36-,l36+,p20,w24" is a two-lane street with parking both sides.
local KIND_CODE = table.freeze({ lane = "l", park = "p", median = "m", verge = "v", shoulder = "s", walk = "w" })
local CODE_KIND = table.freeze({ l = "lane", p = "park", m = "median", v = "verge", s = "shoulder", w = "walk" })
local SURF_CODE = table.freeze({ grass = "g", concrete = "c", paint = "p" })
local CODE_SURF = table.freeze({ g = "grass", c = "concrete", p = "paint" })

-- Allowed width per kind, in quarter studs (2 studs = 1 m): lane 2-5 m, parking 2-3 m,
-- median 0.5-10 m, verge 1-6 m, paved shoulder 0.5-3 m, footway 1.5-6 m.
local WIDTH_Q = table.freeze({
	lane = { 16, 40 }, park = { 16, 24 }, median = { 4, 80 }, verge = { 8, 48 }, shoulder = { 4, 24 }, walk = { 12, 48 },
})
local MAX_STRIPS = 16
local MAX_LANES = 10
local MAX_ROADWAY = 64 -- studs = 32 m
local MAX_BODY = 120   -- RoadTypeCatalog.get bounds the whole id at 128
RoadProfile.PREFIX = "P:"

function RoadProfile.encode(p: Profile): string
	local parts: { string } = {}
	for _, s in p.strips do
		local t = KIND_CODE[s.k] .. tostring(math.round(s.w * 4))
		if s.k == "lane" then
			t ..= if (s.d or 1) < 0 then "-" else "+"
			if s.bus then t ..= "B" end
		elseif s.surf and SURF_CODE[s.surf] then
			t ..= SURF_CODE[s.surf]
		end
		table.insert(parts, t)
	end
	local flags = ""
	if p.busKerb then flags ..= "K" end
	if p.highway then flags ..= "H" end
	if p.speed then flags ..= "S" .. tostring(p.speed) end
	local body = table.concat(parts, ",")
	return if flags ~= "" then body .. ";" .. flags else body
end

-- Rebuilds a profile from untrusted text, or returns nil. Layout rules, left to right:
-- [footway] [verge|parking|shoulder]* lanes [verge|parking|shoulder]* [footway]; lanes are one backward group
-- then one forward group (right-hand authoring), at most one median, and only between the
-- groups; at least one forward lane. Anything else is refused, not repaired.
function RoadProfile.decode(body: string): Profile?
	if #body == 0 or #body > MAX_BODY then return nil end
	local stripPart, flagPart = string.match(body, "^([^;]*);?(.*)$")
	if not stripPart then return nil end

	local strips: { Strip } = {}
	for token in string.gmatch(stripPart, "[^,]+") do
		if #strips >= MAX_STRIPS then return nil end
		local code, q, mods = string.match(token, "^(%l)(%d+)(%p?%u?%l?)$")
		local kind = code and CODE_KIND[code]
		local quarters = tonumber(q)
		if not kind or not quarters then return nil end
		local range = WIDTH_Q[kind]
		if quarters < range[1] or quarters > range[2] then return nil end
		local s: Strip = { k = kind, w = quarters / 4 }
		if kind == "lane" then
			local dir, bus = string.match(mods :: string, "^([%+%-])(B?)$")
			if not dir then return nil end
			s.d = if dir == "-" then -1 else 1
			if bus == "B" then s.bus = true end
		elseif kind == "median" or kind == "verge" then
			if mods == "" then
				s.surf = "grass"
			else
				s.surf = CODE_SURF[mods :: string]
				if not s.surf then return nil end
			end
		elseif mods ~= "" then
			return nil
		end
		table.insert(strips, s)
	end

	-- Layout. phase: 0 before lanes, 1 backward lanes, 2 median taken, 3 forward lanes, 4 after.
	local phase, lanes, fwd, roadW = 0, 0, 0, 0
	for i, s in strips do
		if s.k == "walk" then
			if i ~= 1 and i ~= #strips then return nil end
			continue
		end
		roadW += s.w
		if s.k == "lane" then
			lanes += 1
			if s.d == 1 then
				if phase == 4 then return nil end
				phase = 3
				fwd += 1
			else
				if phase > 1 then return nil end
				phase = 1
			end
		elseif s.k == "median" then
			if phase ~= 1 then return nil end -- one median, between the direction groups
			phase = 2
		elseif phase == 1 or phase == 2 then
			return nil -- parking / verge / shoulder between the lanes
		elseif phase == 3 then
			phase = 4
		end
	end
	if lanes > MAX_LANES or fwd < 1 or phase < 3 or roadW > MAX_ROADWAY then return nil end

	local p: Profile = { strips = strips }
	if #flagPart > 0 then
		local k, h, speed, rest = string.match(flagPart, "^(K?)(H?)S?(%d*)(.*)$")
		if rest ~= "" then return nil end
		if k == "K" then p.busKerb = true end
		if h == "H" then p.highway = true end
		if speed and speed ~= "" then
			local v = tonumber(speed)
			if not v then return nil end
			p.speed = math.clamp(math.round(v), 10, 130)
		end
	end
	return p
end

return table.freeze(RoadProfile)
