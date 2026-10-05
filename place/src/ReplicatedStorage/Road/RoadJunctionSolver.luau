--!strict
-- RoadJunctionSolver -- what a NODE is, decided once, for everyone: the renderer draws it, the
-- nav graph drives it, the markings paint it. Pure library: numbers in, numbers out.
--
-- A node is looked at through its ARMS: one per road end meeting there, each seen OUTWARD
-- (from the node toward the road's far end) with its cross-section in that frame (RoadSection).
-- From the arms alone the solver decides the kind:
--   end         one arm: a cap (or a cul-de-sac bulb).
--   straight    two arms, in line, same cross-section: the bodies simply meet.
--   bend        two arms at an angle: the road turns on a fillet.
--   transition  two arms in line, different cross-sections: a taper.
--   fork        three arms, two leaving within FORK_ANGLE of each other: a split or merge.
--   junction    everything else: arms trimmed back to a paved box with kerb returns.
-- and returns where each arm's own road STOPS (its trim) plus the corner geometry between arms.

local RoadConstants = require(script.Parent.RoadConstants)
local BezierUtil = require(script.Parent.BezierUtil)
local RoadSection = require(script.Parent.RoadSection)
local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
local RoadRules = require(script.Parent.RoadRules)

local RoadJunctionSolver = {}

local ARM_SAMPLES = 48
local STRAIGHT_COS = math.cos(math.rad(RoadConstants.STRAIGHT_JOIN_TOLERANCE_DEG))
-- Two arms leaving within this angle of each other share a direction: a fork, not a corner.
local FORK_ANGLE = math.rad(30)
local NEAR_OPPOSITE_COS = math.cos(math.rad(25))
-- The painted gore between a fork's two roads ends where they are this far apart (studs).
local GORE_NOSE = 6
-- Highway ramps: the through road may bend this much at the node, and the ramp may leave it at
-- up to RAMP_ANGLE, and the node is still a diverge / merge.
local STRAIGHT_RAMP_COS = math.cos(math.rad(30))
local RAMP_COS = math.cos(math.rad(80))
-- A diverge / merge is never shorter than this (studs, 30 m) along the branch.
local DIVERGE_MIN = 60
-- Kerb return radius by the smaller road at the corner, studs (2 studs = 1 m).
local CORNER_RADIUS = table.freeze({ alley = 3, local_ = RoadConstants.JUNCTION_CORNER_RADIUS, highway = 10 })
-- How far a bend's centreline fillet may be tightened: the inner kerb must not fold.
local BEND_CLEAR = RoadConstants.CURVE_INNER_EDGE_CLEARANCE
-- Taper length per stud of lateral shift, and its bounds (studs).
local TAPER_PER_SHIFT = 6
local TAPER_MIN, TAPER_MAX = 24, 120

export type Arm = {
	segId: number,
	atStart: boolean,
	sec: RoadSection.Section,
	pts: { Vector3 }, -- centreline outward from the node, pts[1] at the node
	cum: { number },
	len: number,
	dir: Vector3,     -- flat unit, outward at the node
	corner: number?,  -- player's kerb radius at this end
	offset: number?,  -- player's push of the mouth outward
	spec: any,
	buildOut: number?, -- a junction built the kerb out this wide over the arm's parking (RoadSection.bulbed)
	pedestrian: boolean?, -- a pedestrian street: paving meets the footway, no kerb return
}

export type Corner = {
	a: number,        -- arm whose RIGHT edge forms this corner
	b: number,        -- arm whose LEFT edge forms it
	ta: number,       -- distance along a where the kerb return begins
	tb: number,       -- distance along b where it ends
	centre: Vector3?, -- fillet centre (flat); nil = the two edges run straight into each other
	radius: number,
	reflex: boolean,  -- the arms leave more than 180 degrees apart on this side
}

export type Plan = {
	kind: string,
	arms: { Arm },
	trims: { number },        -- per arm: where its own road body starts
	corners: { Corner },
	crosswalk: { boolean },   -- per arm
	stopAt: { number },       -- per arm: distance of its stop / give-way line (0 = none)
	taper: { a: number, b: number, length: number }?, -- transition: the wider arm tapers
	fork: { main: number, branch: number, stem: number, gore: number, branchRight: boolean, take: number? }?,
	shift: { number }?,       -- per arm: its road drawn this far right of its curve at the node (fades along the body)
	ring: { outer: number, island: number, fillet: number }?, -- roundabout / cul-de-sac circle
	circleCentre: Vector3?, -- flat offset from the node (a cul-de-sac's bulb sits past the end)
}

-- == Arms ===========================================================================
local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end
local function unit(v: Vector3): Vector3
	local m = v.Magnitude
	return if m > 1e-9 then v / m else Vector3.xAxis
end
RoadJunctionSolver.flat = flat
RoadJunctionSolver.unit = unit

-- Right of a flat direction (Roblox: D x Y).
function RoadJunctionSolver.rightOf(d: Vector3): Vector3
	return Vector3.new(-d.Z, 0, d.X)
end
local rightOf = RoadJunctionSolver.rightOf

-- `shift`: the road is drawn this far right of its curve here (carryShifts / armShift).
function RoadJunctionSolver.arm(seg: any, atStart: boolean, profile: any, laneSide: number?, shift: number?): Arm
	local p0, p1, p2, p3 = seg.p0, seg.p1, seg.p2, seg.p3
	if not atStart then p0, p1, p2, p3 = p3, p2, p1, p0 end
	local pts = table.create(ARM_SAMPLES + 1)
	local cum = table.create(ARM_SAMPLES + 1)
	local total = 0
	for i = 0, ARM_SAMPLES do
		local p = BezierUtil.point(p0, p1, p2, p3, i / ARM_SAMPLES)
		if i > 0 then total += (p - pts[i]).Magnitude end
		pts[i + 1] = p
		cum[i + 1] = total
	end
	return {
		segId = seg.id,
		atStart = atStart,
		sec = RoadSection.shifted(RoadSection.of(profile, not atStart, laneSide), shift or 0),
		pts = pts,
		cum = cum,
		len = total,
		dir = unit(flat(BezierUtil.tangent(p0, p1, p2, p3, 0))),
		corner = if atStart then seg.startCorner else seg.endCorner,
		offset = if atStart then seg.startOffset else seg.endOffset,
		spec = seg.spec,
		pedestrian = if profile.pedestrian then true else nil,
	}
end

-- Position on the arm's centreline `d` studs out from the node, with its flat tangent.
function RoadJunctionSolver.at(arm: Arm, d: number): (Vector3, Vector3)
	local pts, cum = arm.pts, arm.cum
	local n = #pts
	if d <= 0 then return pts[1], unit(flat(pts[2] - pts[1])) end
	if d >= cum[n] then return pts[n], unit(flat(pts[n] - pts[n - 1])) end
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] <= d then lo = mid else hi = mid end
	end
	local a, b = pts[lo], pts[hi]
	local t = (d - cum[lo]) / math.max(cum[hi] - cum[lo], 1e-9)
	return a:Lerp(b, t), unit(flat(b - a))
end

-- == Corners ========================================================================
local function cross2(a: Vector3, b: Vector3): number
	return a.X * b.Z - a.Z * b.X
end

local function radiusFor(a: Arm, b: Arm): number
	if a.corner or b.corner then return math.max(a.corner or 0, b.corner or 0) end
	-- a pedestrian street's paving runs flush into the footway: a hair of a corner, no swept return
	if a.pedestrian or b.pedestrian then return 0.5 end
	local function class(arm: Arm): string
		if arm.sec.highway then return "highway" end
		if arm.sec.walkL == 0 and arm.sec.walkR == 0 then return "alley" end
		return "local_"
	end
	local ca, cb = class(a), class(b)
	if ca == "alley" or cb == "alley" then return CORNER_RADIUS.alley end
	if ca == "highway" and cb == "highway" then return CORNER_RADIUS.highway end
	return CORNER_RADIUS.local_
end

-- The kerb return between arm a's RIGHT roadway edge and arm b's LEFT one: a fillet of
-- radius r tangent to both, found where the two edges offset r into the corner meet. The edges
-- are treated as straight from the node -- arms are short near a node and curve gently, and a
-- straight edge keeps the corner exactly tangent to what the arm body draws there.
local function corner(arms: { Arm }, ia: number, ib: number): Corner
	local a, b = arms[ia], arms[ib]
	local r = radiusFor(a, b)
	local ea, eb = a.sec.roadR, -b.sec.roadL
	local Da, Db = a.dir, b.dir
	local Ra, Rb = rightOf(Da), rightOf(Db)
	local turn = cross2(Da, Db) -- > 0: b lies counter-clockwise of a by less than 180
	local reflex = turn <= 1e-3 and Da:Dot(Db) > -STRAIGHT_COS
	if Da:Dot(Db) < -NEAR_OPPOSITE_COS then
		-- (Nearly) opposite arms: the kerb runs on past the node, easing between the two roads'
		-- edges (RoadGeometry openSide) -- never a step or a huge fillet.
		return { a = ia, b = ib, ta = 0, tb = 0, centre = nil, radius = r, reflex = false }
	end
	if reflex then
		return { a = ia, b = ib, ta = 0, tb = 0, centre = nil, radius = r, reflex = true }
	end
	local A0 = Ra * (ea + r)
	local B0 = -Rb * (eb + r)
	local den = cross2(Da, Db)
	local w = B0 - A0
	local t = cross2(w, Db) / den
	local s = cross2(w, Da) / den
	return {
		a = ia, b = ib,
		ta = math.max(t, 0), tb = math.max(s, 0),
		centre = A0 + Da * t, -- relative to the node, flat
		radius = r,
		reflex = false,
	}
end

-- One smooth turn from `pA` heading `tA` to `pB` heading `tB`: where their two lines meet,
-- as the leg lengths (along tA from pA, back along tB from pB). Both positive: a curve with
-- handles 2/3 of each leg turns one way only. nil, nil when the lines are parallel (a straight
-- run or a sideways step -- no turn to make); a negative leg means there is no single turn.
function RoadJunctionSolver.forkTurn(pA: Vector3, tA: Vector3, pB: Vector3, tB: Vector3): (number?, number?)
	local den = cross2(tA, tB)
	if math.abs(den) < 1e-3 then return nil, nil end
	local w = flat(pB - pA)
	return cross2(w, tB) / den, -cross2(w, tA) / den
end

-- == Classification =================================================================
local function sameProfile(a: Arm, b: Arm): boolean
	-- Looking out of the node both ways: a straight road's two arms mirror each other.
	local A, B = a.sec.bands, b.sec.bands
	if #A ~= #B then return false end
	for i = 1, #A do
		local x, y = A[i], B[#B - i + 1]
		if x.k ~= y.k or math.abs((x.x1 - x.x0) - (y.x1 - y.x0)) > 1e-3 or x.surf ~= y.surf then return false end
		if x.d and y.d and x.d ~= -(y.d :: number) then return false end
	end
	return true
end

local function angleOf(d: Vector3): number
	return math.atan2(d.Z, d.X)
end

-- == Circles: roundabouts and cul-de-sacs =========================================
-- Where an arm's roadway edge meets a circle of radius R about `c` (both flat, relative to the
-- node): a fillet of radius rf tangent to the edge line (lateral `e`, side `side` = +1 right /
-- -1 left) and to the circle from outside. Returns the distance along the arm where the fillet
-- leaves the edge, the fillet centre, and the point where it meets the circle.
function RoadJunctionSolver.edgeToCircle(arm: Arm, side: number, c: Vector3, R: number, rf: number): (number, Vector3, Vector3)
	local D = arm.dir
	local Rv = rightOf(D)
	local e = if side > 0 then arm.sec.roadR else -arm.sec.roadL
	-- centre of the fillet: (e + rf) out from the centreline, (R + rf) from the circle's centre
	local lat = side * (e + rf)
	local base = Rv * lat - c
	-- solve |base + D t| = R + rf for the larger t (the fillet ahead of the circle, on the arm)
	local bd = base:Dot(D)
	local cc = base:Dot(base) - (R + rf) ^ 2
	local disc = bd * bd - cc
	local t = -bd + math.sqrt(math.max(disc, 0))
	local F = Rv * lat + D * t
	local towards = unit(F - c)
	return t, F, c + towards * R
end

local function solveCircle(plan: Plan, arms: { Arm }, centre: Vector3, outer: number, island: number, fillet: number)
	plan.ring = { outer = outer, island = island, fillet = fillet }
	plan.circleCentre = centre
	for i, arm in arms do
		local tR = RoadJunctionSolver.edgeToCircle(arm, 1, centre, outer, fillet)
		local tL = RoadJunctionSolver.edgeToCircle(arm, -1, centre, outer, fillet)
		plan.trims[i] = math.max(tR, tL, 0) + (arm.offset or 0)
	end
end

-- Roundabout sizes (studs): the ring is two lanes wide round a small planted island.
RoadJunctionSolver.RING = table.freeze({ outer = 26, island = 7, fillet = 9 })
-- Cul-de-sac bulb: radius, and how far past the road's end its centre sits.
RoadJunctionSolver.BULB = table.freeze({ radius = 15, fillet = 8 })

-- A junction's approach: plain roadway (solid lane lines, no parking) this far past the stop line
-- (or the mouth, where there is none). Over parking the kerb is built out that far, then tapers
-- back out to the parking at BUILD_OUT_TAPER : 1 (RoadSection.bulbed). The road mesh draws it and
-- ParkingService keeps its bays out of it -- one number for both.
local APPROACH = 10
RoadJunctionSolver.BUILD_OUT_TAPER = 3
function RoadJunctionSolver.approachOf(plan: Plan, i: number): number
	return (if plan.stopAt[i] > 0 then plan.stopAt[i] else plan.trims[i]) + APPROACH
end

-- Where arm i's kerb is back out at its parking (bays may start here); nil when the plan built
-- nothing out over that arm.
function RoadJunctionSolver.buildOutEnd(plan: Plan, i: number): number?
	local w = plan.arms[i].buildOut
	if plan.kind ~= "junction" or not w then return nil end
	return RoadJunctionSolver.approachOf(plan, i) + RoadJunctionSolver.BUILD_OUT_TAPER * w
end

function RoadJunctionSolver.solve(node: { pos: Vector3, arms: { Arm }, upgrade: { kind: string }? }): Plan
	local arms = node.arms
	local n = #arms
	local plan: Plan = {
		kind = "end", arms = arms, trims = table.create(n, 0), corners = {},
		crosswalk = table.create(n, false), stopAt = table.create(n, 0),
	}
	local upgrade = node.upgrade
	if n == 1 and upgrade and upgrade.kind == "culdesac" then
		plan.kind = "culdesac"
		local arm = arms[1]
		local e = math.max(arm.sec.roadR, -arm.sec.roadL)
		local R = math.max(RoadJunctionSolver.BULB.radius, e + 4)
		-- the bulb's centre sits past the end so the road runs straight into it
		solveCircle(plan, arms, -arm.dir * (R * 0.55), R, 0, RoadJunctionSolver.BULB.fillet)
		return plan
	end
	if n >= 3 and upgrade and upgrade.kind == "roundabout" then
		plan.kind = "ring"
		local widest = 0
		for _, arm in arms do widest = math.max(widest, arm.sec.roadR, -arm.sec.roadL) end
		local R = math.max(RoadJunctionSolver.RING.outer, widest + 14)
		solveCircle(plan, arms, Vector3.zero, R, RoadJunctionSolver.RING.island, RoadJunctionSolver.RING.fillet)
		for i, arm in arms do
			local sec = arm.sec
			plan.crosswalk[i] = sec.walkL > 0 and sec.walkR > 0 and not sec.highway
			-- entries give way to the ring at the circle itself
			if #RoadSection.lanes(sec, -1) > 0 then plan.stopAt[i] = -1 end
		end
		return plan
	end
	if n <= 1 then return plan end

	if n == 2 then
		local a, b = arms[1], arms[2]
		local cosAB = a.dir:Dot(b.dir)
		local straight = cosAB < -STRAIGHT_COS
		if straight and sameProfile(a, b) then
			plan.kind = "straight"
			return plan
		end
		if cosAB < -math.cos(math.rad(15)) then
			-- In line but different: the WIDER arm tapers onto the narrower one.
			plan.kind = "transition"
			local wa = a.sec.roadR - a.sec.roadL + a.sec.walkL + a.sec.walkR
			local wb = b.sec.roadR - b.sec.roadL + b.sec.walkL + b.sec.walkR
			local wide, narrow = if wa >= wb then 1 else 2, if wa >= wb then 2 else 1
			local shift = 0
			do
				local W, N = arms[wide].sec, arms[narrow].sec
				-- Edges move by the larger of the two sides' changes (N is mirrored).
				shift = math.max(math.abs(W.roadR + N.roadL), math.abs(W.roadL + N.roadR))
			end
			local length = math.clamp(shift * TAPER_PER_SHIFT, TAPER_MIN, TAPER_MAX)
			length = math.min(length, arms[wide].len * 0.6)
			plan.taper = { a = wide, b = narrow, length = length }
			plan.trims[wide] = length
			return plan
		end
		-- A bend: the centreline turns on a fillet. Its radius keeps the inner kerb clear.
		plan.kind = "bend"
		local half = math.max(a.sec.roadR + a.sec.walkR, -a.sec.roadL + a.sec.walkL,
			b.sec.roadR + b.sec.walkR, -b.sec.roadL + b.sec.walkL)
		local radius = half + BEND_CLEAR
		local phi = math.acos(math.clamp(-cosAB, -1, 1)) -- how far the road turns
		local t = radius * math.tan(phi * 0.5)
		if not sameProfile(a, b) then
			-- two different roads: the bend is also the taper between them, so give it the room
			local shift = math.max(math.abs(a.sec.roadR + b.sec.roadL), math.abs(a.sec.roadL + b.sec.roadR))
			t = math.max(t, math.clamp(shift * TAPER_PER_SHIFT, TAPER_MIN, TAPER_MAX) * 0.5)
		end
		t = math.min(t, a.len * 0.45, b.len * 0.45)
		plan.trims[1], plan.trims[2] = t, t
		return plan
	end

	-- Order arms counter-clockwise (increasing angle): consecutive arms share a corner, and the
	-- corner always pairs the earlier arm's RIGHT edge with the later arm's LEFT edge.
	local order = table.create(n)
	for i = 1, n do order[i] = i end
	table.sort(order, function(x, y) return angleOf(arms[x].dir) < angleOf(arms[y].dir) end)

	if n == 3 then
		for k = 1, 3 do
			local i, j = order[k], order[k % 3 + 1]
			local gap = math.acos(math.clamp(arms[i].dir:Dot(arms[j].dir), -1, 1))
			if gap < FORK_ANGLE then
				local stem = order[(k + 1) % 3 + 1]
				-- Judged a little way out, not at the node: a ramp drawn tangent to the highway
				-- leaves in exactly its direction and only parts as it bends.
				local ahead = -arms[stem].dir
				local function probe(arm: Arm): Vector3
					local p = RoadJunctionSolver.at(arm, math.min(30, arm.len * 0.5))
					return unit(flat(p - node.pos))
				end
				local pi, pj = probe(arms[i]), probe(arms[j])
				-- The arm that best continues the stem's line is the main line.
				local main, branch = i, j
				if pj:Dot(ahead) > pi:Dot(ahead) then main, branch = j, i end
				local pb = if branch == i then pi else pj
				plan.kind = "fork"
				plan.fork = { main = main, branch = branch, stem = stem, gore = 0,
					branchRight = rightOf(ahead):Dot(pb) > 0 }
				break
			end
		end
	end

	if n == 3 and plan.kind ~= "fork" then
		-- Highways: a ramp drawn off (or onto) a road that runs straight through the node is a
		-- diverge / merge at any angle up to RAMP_ANGLE -- never an intersection box, which cuts
		-- the median and opens the far carriageway.
		local allHighway = true
		for _, arm in arms do
			if not arm.sec.highway then allHighway = false end
		end
		for a = 1, 3 do
			if not allHighway then break end
			local b = a % 3 + 1
			local c = 6 - a - b
			if arms[a].dir:Dot(arms[b].dir) > -STRAIGHT_RAMP_COS then continue end
			local da, db = arms[c].dir:Dot(arms[a].dir), arms[c].dir:Dot(arms[b].dir)
			if math.max(da, db) < RAMP_COS then continue end
			local main, stem = if da > db then a else b, if da > db then b else a
			local ahead = -arms[stem].dir
			local pb = RoadJunctionSolver.at(arms[c], math.min(30, arms[c].len * 0.5))
			plan.kind = "fork"
			plan.fork = { main = main, branch = c, stem = stem, gore = 0,
				branchRight = rightOf(ahead):Dot(unit(flat(pb - node.pos))) > 0 }
			break
		end
	end

	if plan.kind ~= "fork" then
		-- A junction: parking stops short of it and the footway builds out over the parking
		-- lane, so corners, crossings and the box all meet the lanes (the bodies taper back).
		for _, arm in arms do
			local built = RoadSection.bulbed(arm.sec, 1)
			if built ~= arm.sec then
				arm.buildOut = RoadSection.parkWidth(arm.sec)
				arm.sec = built
			end
		end
	end
	for k = 1, n do
		local i, j = order[k], order[k % n + 1]
		table.insert(plan.corners, corner(arms, i, j))
	end

	if plan.kind == "fork" then
		local f = plan.fork :: any
		local a, b = arms[f.main], arms[f.branch]
		local branchRight = f.branchRight
		-- The stem lanes the branch takes: the main line keeps what it needs first, so a ramp off
		-- a road that runs on at full width grows from nothing (an auxiliary lane) instead of
		-- stealing one; a stem that splits exactly (3 = 2 + 1) hands its edge lane over.
		local stem = arms[f.stem]
		local ahead: { { x0: number, x1: number } } = {} -- the stem's lanes, looking out along the fork
		for i = #stem.sec.bands, 1, -1 do
			local bd = stem.sec.bands[i]
			if bd.k == "lane" then table.insert(ahead, { x0 = -bd.x1, x1 = -bd.x0 }) end
		end
		local own = {}
		for _, bd in a.sec.bands do
			if bd.k == "lane" then table.insert(own, bd) end
		end
		local nS, nM = #ahead, #own
		local nB = #RoadSection.lanes(b.sec, 1) + #RoadSection.lanes(b.sec, -1)
		f.take = math.clamp(nS - nM, 0, math.min(nB, math.max(nS - 1, 0)))
		-- A main line that runs on in the stem's line keeps the stem's lanes exactly where they
		-- were: its road is drawn shifted across by the difference (carryShifts takes that on
		-- along the road), so a 3-lane highway that drops a lane into an exit carries straight on.
		plan.shift = table.create(n, 0)
		local pMain = RoadJunctionSolver.at(a, math.min(60, a.len * 0.5))
		local offLine = flat(pMain - node.pos):Dot(rightOf(-stem.dir))
		if nS > 0 and nM > 0 and math.abs(offLine) < 2 then
			local first = if branchRight then 1 else f.take + 1
			local last = first + (nS - f.take) - 1
			-- lined up on the gore side: lane widths may differ by type, and the difference is
			-- eased in on the outer side, where nothing else is
			plan.shift[f.main] = if branchRight then ahead[last].x1 - own[#own].x1 else ahead[first].x0 - own[1].x0
		end
		-- The gore ends (its nose) where the branch's inner edge has cleared the main road's edge
		-- by GORE_NOSE. Walked on the real curves: a ramp drawn tangent to the highway leaves at
		-- 0 degrees and only parts as it bends, which no angle formula sees.
		local shift = plan.shift[f.main]
		local eMain = if branchRight then a.sec.roadR + shift else -(a.sec.roadL + shift)
		local xBranch = if branchRight then b.sec.roadL else b.sec.roadR
		local gore = b.len * 0.8
		local d = 2
		while d < b.len * 0.8 do
			local pb, tb = RoadJunctionSolver.at(b, d)
			local inner = pb + rightOf(tb) * xBranch
			local best = math.huge
			for i = 1, #a.pts - 1 do
				local p0, p1 = a.pts[i], a.pts[i + 1]
				local seg = flat(p1 - p0)
				local len2 = seg:Dot(seg)
				local u = if len2 > 1e-9 then math.clamp(flat(inner - p0):Dot(seg) / len2, 0, 1) else 0
				best = math.min(best, flat(inner - (p0 + seg * u)).Magnitude)
			end
			if best >= eMain + GORE_NOSE then
				gore = d
				break
			end
			d += 2
		end
		-- The branch's lanes leave from where they sit in the stem, along it, and must run into
		-- the branch's own curve on ONE turn (never an S): the mouth goes where the stem lane's
		-- line and the branch's tangent meet ahead of the one and behind the other, the two legs
		-- of that turn in proportion (RoadJunctionSolver.forkTurn).
		local t0 = -stem.dir
		-- A branch drawn leaving along the stem splits exactly where the player's road leaves
		-- (the clearance above); only a steep one is stretched into a curve it can take.
		local steepBranch = math.acos(math.clamp(b.dir:Dot(t0), -1, 1)) >= math.rad(30)
		if steepBranch then gore = math.max(gore, math.min(DIVERGE_MIN, b.len * 0.6)) end
		local startX: number
		if f.take > 0 then
			local i0 = if branchRight then nS - f.take + 1 else 1
			local i1 = if branchRight then nS else f.take
			startX = (ahead[i0].x0 + ahead[i1].x1) * 0.5
		elseif nS > 0 then
			-- nothing taken: the branch splits out of the stem's outside lane
			local edge = if branchRight then ahead[nS] else ahead[1]
			startX = (edge.x0 + edge.x1) * 0.5
		else
			startX = 0
		end
		local pA = flat(node.pos) + rightOf(t0) * startX
		local limit = b.len * 0.8
		while steepBranch and gore < limit do
			local pM, tM = RoadJunctionSolver.at(b, gore)
			local legA, legM = RoadJunctionSolver.forkTurn(pA, t0, flat(pM), tM)
			if legA == nil or (legA > 0 and (legM :: number) > 0 and (legM :: number) >= 0.6 * legA) then break end
			gore += 4
		end
		f.gore = gore
		plan.trims[f.branch] = gore
		-- The main line runs alongside the gore to its nose.
		local gap = math.acos(math.clamp(a.dir:Dot(b.dir), -1, 1))
		plan.trims[f.main] = math.min(math.max(gore * math.cos(gap), TAPER_MIN), a.len * 0.8)
		plan.trims[f.stem] = 0
		return plan
	end

	plan.kind = "junction"
	for _, c in plan.corners do
		plan.trims[c.a] = math.max(plan.trims[c.a], c.ta)
		plan.trims[c.b] = math.max(plan.trims[c.b], c.tb)
	end
	for i, arm in arms do
		plan.trims[i] = math.max(plan.trims[i], 1) + RoadConstants.JUNCTION_MARGIN + (arm.offset or 0)
		local sec = arm.sec
		plan.crosswalk[i] = sec.walkL > 0 and sec.walkR > 0 and not sec.highway
		local arriving = #RoadSection.lanes(sec, -1) > 0
		if arriving then
			plan.stopAt[i] = plan.trims[i]
				+ (if plan.crosswalk[i] then RoadConstants.CROSSWALK_DEPTH + RoadConstants.CROSSWALK_GAP_FROM_STOP else 1)
				+ RoadConstants.STOP_LINE_DEPTH * 0.5
		end
	end
	return plan
end


-- == Shifted roads =================================================================
-- A fork whose main road runs on in the stem's line draws that road shifted across (plan.shift)
-- so its lanes carry straight on. The shift rides along the road -- through straight joins onto
-- the next segment -- to the first node that takes a shifted road as it is (a dead end, a
-- junction, a taper all work from the arm's own section). Anywhere else (a bend, another fork,
-- a roundabout) that last segment eases back onto its curve along its body.
-- `nodes[id] = { plan = Plan, ends = { { seg, atStart } } }`; segments carry startNode/endNode.
-- Per segment id: the shift in the curve's frame (right of p0 -> p3), the node it comes from
-- (`fork`: that node is the fork that made it) and the far node when that node takes it on.
export type Shift = { shift: number, from: any, fork: boolean, to: any? }
local TAKES_SHIFT = table.freeze({ ["end"] = true, junction = true, transition = true, straight = true })

function RoadJunctionSolver.carryShifts(nodes: { [any]: any }): { [number]: Shift }
	local out: { [number]: Shift } = {}
	for id, node in nodes do
		local plan = node.plan
		if not plan or plan.kind ~= "fork" or not plan.shift then continue end
		for i, s in plan.shift do
			if s == 0 then continue end
			local e = node.ends[i]
			local seg, atStart, armShift, from, fork = e.seg, e.atStart, s, id, true
			for _ = 1, 256 do
				if out[seg.id] then break end
				local curve = if atStart then armShift else -armShift
				local rec: Shift = { shift = curve, from = from, fork = fork }
				out[seg.id] = rec
				local farId = if atStart then seg.endNode else seg.startNode
				local far = nodes[farId]
				if not far or not far.plan or not TAKES_SHIFT[far.plan.kind] then break end
				rec.to = farId
				if far.plan.kind ~= "straight" then break end
				local other = nil
				for _, oe in far.ends do
					if oe.seg.id ~= seg.id then other = oe end
				end
				if not other then break end
				-- the same offset, seen out of the join along the other road: mirrored
				local farArm = if atStart then -curve else curve
				seg, atStart, armShift, from, fork = other.seg, other.atStart, -farArm, farId, false
			end
		end
	end
	return out
end

-- The shift a road end's arm carries at node `nodeId` (its outward frame), 0 if none. The fork
-- that made a shift draws it itself, so its own arm stays on the curve.
function RoadJunctionSolver.armShift(shifts: { [number]: Shift }, seg: any, atStart: boolean, nodeId: any): number
	local rec = shifts[seg.id]
	if not rec then return 0 end
	if rec.to ~= nodeId and (rec.from ~= nodeId or rec.fork) then return 0 end
	return if atStart then rec.shift else -rec.shift
end

-- The junction plan the road mesh draws at `nodeId` of a RoadNetwork, for the server systems that
-- must agree with it (signal poles, pedestrian crossings), and each segment's arm index. nil
-- where the mesh does not draw a junction there (a bridge, tunnel or roundabout meets it).
function RoadJunctionSolver.planAt(network: any, nodeId: number): (Plan?, { [number]: number }?)
	local node = network:getNodes()[nodeId]
	if not node or #node.segments < 3 then return nil, nil end
	local arms: { Arm } = {}
	local index: { [number]: number } = {}
	for _, sid in node.segments do
		local s = network:getSegment(sid)
		if not s or s.isRoundabout or s.vMode == "Elevated" or s.vMode == "Tunnel" then return nil, nil end
		local profile = RoadTypeCatalog.getOrDefault(s.roadType).profile
		if not profile then return nil, nil end
		table.insert(arms, RoadJunctionSolver.arm(s, s.startNode == nodeId, profile, RoadRules.getLaneSideSign()))
		index[sid] = #arms
	end
	local ok, plan = pcall(RoadJunctionSolver.solve, { pos = node.position, arms = arms })
	if not ok or plan.kind ~= "junction" then return nil, nil end
	return plan, index
end

return table.freeze(RoadJunctionSolver)
