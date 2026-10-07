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
local LANES_SAMPLES = 8 -- an arm only read for its direction and lanes (stuckAt)
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
-- Highways: a lane drop is quick, like a lane change -- 5:1, ~18 m for one lane, and never more
-- than 48 studs however many lanes go (user, 2026-10-06, after Cities: Skylines II: the old road
-- is pushed back only a little).
local TAPER_PER_SHIFT_HIGHWAY, TAPER_MAX_HIGHWAY = 5, 48
-- A street narrows quickly, over about as far as its outer edge (footway included) steps in.
local TAPER_PER_SHIFT_STREET, TAPER_MIN_STREET, TAPER_MAX_STREET = 1.2, 8, 48
-- An unusable road's pin stands this far along it from the node (studs).
local STUCK_PIN_AT = 30

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
	anchored: boolean?,   -- drawn from a lane of the road it joins (Segment.startLane / endLane)
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
	taper: { a: number, b: number, length: number }?, -- transition: arm a (the narrower) flares out to arm b's section at the node, over `length`
	laneEnds: { [number]: { [number]: string } }?, -- transition: per arm, its arriving lanes (band index) that end: "uturn" | "left" | "right" (merge)
	fork: { main: number, branch: number, stem: number, gore: number, branchRight: boolean, take: number?, t0: Vector3?,
		mRun: { number }?, bRun: { number }?, mCov: { number }?, bCov: { number }?, boundary: number?,
		against: { [number]: boolean }? }?, -- t0: the frame the stem ends on and both groups leave on; runs: see the fork plan
	forks: { any }?,          -- a road straight through with a ramp each side: one fork per side (plan.fork = forks[1])
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

-- The curve a segment is DRAWN on: a road laid off a lane of the road it joins (lane snapping)
-- starts / ends on that lane, `startLane` / `endLane` from its node, with its own handles.
-- Everything that draws or follows the road (mesh, nav lanes, ground grading) uses this.
function RoadJunctionSolver.drawnCurve(seg: any): (Vector3, Vector3, Vector3, Vector3)
	return if seg.startLane then seg.p0 + seg.startLane else seg.p0, seg.p1, seg.p2,
		if seg.endLane then seg.p3 + seg.endLane else seg.p3
end

-- `shift`: the road is drawn this far right of its curve here (carryShifts / armShift).
-- `samples`: fewer points along it where only its lanes matter (stuckAt).
function RoadJunctionSolver.arm(seg: any, atStart: boolean, profile: any, laneSide: number?, shift: number?, samples: number?): Arm
	local p0, p1, p2, p3 = RoadJunctionSolver.drawnCurve(seg)
	if not atStart then p0, p1, p2, p3 = p3, p2, p1, p0 end
	local count = samples or ARM_SAMPLES
	local pts = table.create(count + 1)
	local cum = table.create(count + 1)
	local total = 0
	for i = 0, count do
		local p = BezierUtil.point(p0, p1, p2, p3, i / count)
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
		anchored = if (if atStart then seg.startLane else seg.endLane) then true else nil,
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
	local ea, eb = a.sec.roadR, -b.sec.roadL
	local Da, Db = a.dir, b.dir
	-- An acute corner (the roads 30-60 degrees apart) takes a tighter kerb: the full radius sat
	-- tens of studs down both roads (a road joined on the wrong side at a Y), pushing them back.
	local apart = math.acos(math.clamp(Da:Dot(Db), -1, 1))
	local r = radiusFor(a, b) * math.clamp((apart - FORK_ANGLE) / FORK_ANGLE, 0.15, 1)
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
	if Da:Dot(Db) > math.cos(FORK_ANGLE) then
		-- Two roads leaving side by side (more than a fork's two, say): their kerbs would only
		-- meet far out, and a fillet there stretched the box into a spike (user, 2026-10-06).
		-- The edges just join at the mouths.
		return { a = ia, b = ib, ta = 0, tb = 0, centre = nil, radius = r, reflex = false }
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
-- `anyDirs`: lanes may run either way (two roads of one shape meet edge to edge whatever their
-- lanes' directions -- a 2 + 1 running on as a 3-lane one-way needs no taper, it only repaints).
local function sameProfile(a: Arm, b: Arm, anyDirs: boolean?): boolean
	-- Looking out of the node both ways: a straight road's two arms mirror each other.
	local A, B = a.sec.bands, b.sec.bands
	if #A ~= #B then return false end
	for i = 1, #A do
		local x, y = A[i], B[#B - i + 1]
		if x.k ~= y.k or math.abs((x.x1 - x.x0) - (y.x1 - y.x0)) > 1e-3 or x.surf ~= y.surf then return false end
		if not anyDirs and x.d and y.d and x.d ~= -(y.d :: number) then return false end
	end
	return true
end

-- Whether an arm has lanes leaving the node / arriving at it.
local function ways(sec: RoadSection.Section): (boolean, boolean)
	local out, inn = false, false
	for _, bd in sec.bands do
		if bd.k == "lane" then
			if (bd.d :: number) > 0 then out = true else inn = true end
		end
	end
	return out, inn
end

-- Where a road narrows, which of the wider road's arriving lanes END, and how. They are paired
-- with the narrower road's lanes the way the taper pairs them (RoadGeometry.matchSections): a
-- road laid to one side keeps the lanes in line with it, a centred one drops the kerbside lanes.
-- An ending lane merges over toward the lanes that carry on ("left" / "right", the driver's side):
-- one in its own direction always does here (user, 2026-10-06: a merge arrow, never a U-turn, on
-- both sides of a 2 + 1 meeting a 1 + 2). Per wide-arm band index; nil when nothing ends.
local function laneEnds(W: RoadSection.Section, N: RoadSection.Section, lat: number): { [number]: string }?
	local arriving: { number } = {} -- band indices
	for k, bd in W.bands do
		if bd.k == "lane" and (bd.d :: number) < 0 then table.insert(arriving, k) end
	end
	local on, onAt = 0, 0 -- the narrow road's lanes carrying them on, and where (across the wide arm)
	for _, bd in N.bands do
		if bd.k == "lane" and (bd.d :: number) > 0 then
			on += 1
			onAt += lat - (bd.x0 + bd.x1) * 0.5
		end
	end
	local drop = #arriving - on
	if drop <= 0 or on == 0 then return nil end
	local function centre(k: number): number
		return (W.bands[k].x0 + W.bands[k].x1) * 0.5
	end
	-- The ending lanes: the kerbside ones (highest ordinal, whichever side traffic keeps to), unless
	-- the narrow road sits to one side -- then the ones on the far side from it.
	if math.abs(lat) > 0.05 then
		local mid = onAt / on
		table.sort(arriving, function(x, y) return math.abs(centre(x) - mid) < math.abs(centre(y) - mid) end)
	else
		table.sort(arriving, function(x, y) return (W.bands[x].ordinal or 0) < (W.bands[y].ordinal or 0) end)
	end
	local ending = table.move(arriving, #arriving - drop + 1, #arriving, 1, {})
	local keepAt, endAt = 0, 0
	for i = 1, #arriving - drop do keepAt += centre(arriving[i]) end
	for _, k in ending do endAt += centre(k) end
	keepAt /= (#arriving - drop)
	endAt /= drop
	local out: { [number]: string } = {}
	for _, k in ending do
		-- +x is the arriving driver's LEFT (they face back along the arm)
		out[k] = if keepAt > endAt then "left" else "right"
	end
	return out
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

-- `lanesOnly`: just the kind and a fork's lane runs (stuckArms), no shapes -- the nav graph asks.
function RoadJunctionSolver.solve(node: { pos: Vector3, arms: { Arm }, upgrade: { kind: string }?, lanesOnly: boolean? }): Plan
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
		-- An end laid off a lane of the other road (Segment.startLane / endLane) sits across from it.
		local across = flat(b.pts[1] - a.pts[1]):Dot(rightOf(a.dir))
		-- Two two-way roads whose directions meet out of line (a 2 + 1 met head-on by a 1 + 2) switch
		-- the centre line over a short transition, the lane ending on each side merging (user,
		-- 2026-10-06); a one-way of the same shape only repaints.
		local function twoWay(arm: Arm): boolean
			local out, inn = ways(arm.sec)
			return out and inn
		end
		if straight and sameProfile(a, b, not (twoWay(a) and twoWay(b))) and math.abs(across) < 0.05 then
			plan.kind = "straight"
			return plan
		end
		if cosAB < -math.cos(math.rad(15)) then
			-- In line but different: the NARROWER road flares out to meet the wider one at the node,
			-- so the wide road keeps its full width right up to its node, where a road can join it
			-- (user, 2026-10-06: tapered back from the node it was "pushed back").
			plan.kind = "transition"
			local wa = a.sec.roadR - a.sec.roadL + a.sec.walkL + a.sec.walkR
			local wb = b.sec.roadR - b.sec.roadL + b.sec.walkL + b.sec.walkR
			local wide, narrow = if wa >= wb then 1 else 2, if wa >= wb then 2 else 1
			local W, N = arms[wide].sec, arms[narrow].sec
			-- where the narrow road really sits across the wide one (laid off a lane: to one side)
			local lat = flat(arms[narrow].pts[1] - arms[wide].pts[1]):Dot(rightOf(arms[wide].dir))
			-- Edges move by the larger of the two sides' changes (N is mirrored).
			local shift = math.max(math.abs(W.roadR + N.roadL - lat), math.abs(W.roadL + N.roadR - lat))
			-- a street: how far its OUTER edges (footway included) step in, either side
			local outer = math.max(math.abs(W.roadR + W.walkR + N.roadL - N.walkL - lat),
				math.abs(W.roadL - W.walkL + N.roadR + N.walkR - lat))
			-- the line between the two directions moves across too (N mirrored)
			local function centreLine(sec: RoadSection.Section): number?
				for k = 1, #sec.bands - 1 do
					local x, y = sec.bands[k], sec.bands[k + 1]
					if x.k == "lane" and y.k == "lane" and x.d ~= y.d then return x.x1 end
				end
				return nil
			end
			local cW, cN = centreLine(W), centreLine(N)
			if cW and cN then
				local moves = math.abs(cW - (lat - cN))
				shift, outer = math.max(shift, moves), math.max(outer, moves)
			end
			local length = if W.highway
				then math.clamp(shift * TAPER_PER_SHIFT_HIGHWAY, TAPER_MIN, TAPER_MAX_HIGHWAY)
				else math.clamp(outer * TAPER_PER_SHIFT_STREET, TAPER_MIN_STREET, TAPER_MAX_STREET)
			length = math.min(length, arms[narrow].len * 0.5) -- the other end may hold a fork's run
			plan.taper = { a = narrow, b = wide, length = length }
			plan.trims[narrow] = length
			-- lanes end on either side: each road's arriving lanes the other cannot carry on
			local endsW = laneEnds(W, N, lat)
			local endsN = laneEnds(N, W, flat(arms[wide].pts[1] - arms[narrow].pts[1]):Dot(rightOf(arms[narrow].dir)))
			if endsW or endsN then plan.laneEnds = { [wide] = endsW, [narrow] = endsN } end
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
				-- The main line is the road that carries more of the stem's lanes on, however its
				-- first metres run: drawn along a lane, a ramp can carry the stem's line on better
				-- than the road's own next piece where that bends away (user, 2026-10-06: the
				-- highway between two ramps was built as the ramp, "bucking out"). The line decides
				-- only between equals. (Not "a lane-laid road is the ramp": a narrower highway laid
				-- flush to one side of the stem is laid off a lane too.)
				local function laneCount(arm: Arm): number
					local c = 0
					for _, bd in arm.sec.bands do
						if bd.k == "lane" then c += 1 end
					end
					return c
				end
				local ci, cj = laneCount(arms[i]), laneCount(arms[j])
				if ci ~= cj then main, branch = if ci > cj then i else j, if ci > cj then j else i end
				local pb = if branch == i then pi else pj
				local right = rightOf(ahead):Dot(pb) > 0
				-- Lane directions never change the shape: a road drawn the wrong way is built like
				-- the right-way one and flagged unusable (stuckArms) -- user, 2026-10-07
				plan.kind = "fork"
				plan.fork = { main = main, branch = branch, stem = stem, gore = 0, branchRight = right }
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
			local right = rightOf(ahead):Dot(unit(flat(pb - node.pos))) > 0
			-- a two-way road leaving at an angle meets it in an intersection (a T or Y, CS2): as a
			-- ramp its oncoming lanes would cross the main road's
			local cOut, cIn = ways(arms[c].sec)
			if cOut and cIn and not arms[c].anchored then continue end
			plan.kind = "fork"
			plan.fork = { main = main, branch = c, stem = stem, gore = 0, branchRight = right }
			break
		end
	end

	if n == 4 then
		-- A road running straight through with a ramp (a highway's, at up to RAMP_ANGLE; any other
		-- road's, within FORK_ANGLE) leaving or joining on EACH side at one node: one split / merge
		-- per side, never a crossing -- two ramps joining a divided highway at one place opened its
		-- median into a signalled box (user, 2026-10-07). Each side's fork has its own main: the
		-- through arm its ramp runs along.
		for a = 1, 3 do
			for b = a + 1, 4 do
				if plan.kind == "fork" or arms[a].dir:Dot(arms[b].dir) > -STRAIGHT_RAMP_COS then continue end
				local forks, sides = {}, {}
				for c = 1, 4 do
					if c == a or c == b then continue end
					local da, db = arms[c].dir:Dot(arms[a].dir), arms[c].dir:Dot(arms[b].dir)
					local main, stem = if da > db then a else b, if da > db then b else a
					local ramp = arms[c].sec.highway and arms[main].sec.highway
					-- a ramp: one-way and narrower than the road (two roads crossing at a skew are not)
					local cOut, cIn = ways(arms[c].sec)
					local function lanes(arm: Arm): number
						local k = 0
						for _, bd in arm.sec.bands do
							if bd.k == "lane" then k += 1 end
						end
						return k
					end
					if math.max(da, db) < (if ramp then RAMP_COS else math.cos(FORK_ANGLE)) or cOut == cIn
						or lanes(arms[c]) >= lanes(arms[main]) then break end
					local away = unit(flat(RoadJunctionSolver.at(arms[c], math.min(30, arms[c].len * 0.5)) - node.pos))
					table.insert(sides, rightOf(arms[a].dir):Dot(away) > 0)
					table.insert(forks, { main = main, branch = c, stem = stem, gore = 0, branchRight = rightOf(-arms[stem].dir):Dot(away) > 0 })
				end
				if #forks == 2 and sides[1] ~= sides[2] then
					plan.kind = "fork"
					plan.forks, plan.fork = forks, forks[1]
				end
			end
		end
	end

	if node.lanesOnly and plan.kind ~= "fork" then return plan end
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
	for k = 1, if node.lanesOnly then 0 else n do
		local i, j = order[k], order[k % n + 1]
		table.insert(plan.corners, corner(arms, i, j))
	end

	-- One fork: the stem lanes `f.branch` and `f.main` take, the gore, and their trims.
	local function planFork(f: any)
		local a, b = arms[f.main], arms[f.branch]
		local branchRight = f.branchRight
		-- The stem lanes the branch takes: the main line keeps what it needs first, so a ramp off
		-- a road that runs on at full width grows from nothing (an auxiliary lane) instead of
		-- stealing one; a stem that splits exactly (3 = 2 + 1) hands its edge lane over.
		local stem = arms[f.stem]
		-- Lanes are counted across the node, from where each road is DRAWN: one laid off a lane
		-- (Segment.startLane / endLane) sits to one side of it (user, 2026-10-06: a 4-lane piece
		-- laid flush off a 3-lane highway, merged into, had the 3-lane one pushed across "all the
		-- way" -- read from the node, the two looked out of line by the offset).
		local across = rightOf(-stem.dir)
		local stemOff = flat(stem.pts[1] - node.pos):Dot(across)
		local mainOff = flat(a.pts[1] - node.pos):Dot(across)
		local ahead: { { x0: number, x1: number, k: number, arriving: boolean } } = {} -- the stem's lanes, looking out along the fork (k: band index in the stem arm)
		for i = #stem.sec.bands, 1, -1 do
			local bd = stem.sec.bands[i]
			if bd.k == "lane" then
				table.insert(ahead, { x0 = stemOff - bd.x1, x1 = stemOff - bd.x0, k = i, arriving = (bd.d :: number) < 0 })
			end
		end
		local own = {}
		for _, bd in a.sec.bands do
			if bd.k == "lane" then table.insert(own, bd) end
		end
		local nS, nM = #ahead, #own
		local nB = #RoadSection.lanes(b.sec, 1) + #RoadSection.lanes(b.sec, -1)
		f.take = math.clamp(nS - nM, 0, math.min(nB, math.max(nS - 1, 0)))
		-- Which stem lanes each road takes ({ first, last } `ahead` indices), by ONE rule for every
		-- fork -- exit, entry, lane drop, dead end split (user, 2026-10-06: "everything runs on one
		-- system"):
		--  1. a road laid off lanes lies on the stem lanes its own lanes lie on; any other road lies
		--     on as many stem lanes as it has, from its own side;
		--  2. a lane no road lies on goes to the nearer road, a tie to the road placed last (the
		--     higher segment id): it ends in that road, narrowing out on its gore side from the
		--     split on, its traffic merging over (a merge arrow on the stem) -- four lanes into two
		--     one-lane roads split evenly, two each;
		--  3. a lane both lie on is shared (a road carrying on at full width beside its ramp).
		-- Directions: a stem lane ARRIVING at the node carries on into a road's lanes LEAVING it, and
		-- the other way round; a road only takes stem lanes it can carry on (user, 2026-10-06: a
		-- one-way road never takes a lane coming the other way).
		local function dirs(arm: Arm): (number, number) -- its lanes leaving / arriving at the node
			local out, inn = 0, 0
			for _, bd in arm.sec.bands do
				if bd.k == "lane" then
					if (bd.d :: number) > 0 then out += 1 else inn += 1 end
				end
			end
			return out, inn
		end
		-- The stem lanes a road lies on (a set): laid off lanes, the ones its own lanes lie on and
		-- run the same way as; otherwise as many as it has each way, from its own side.
		-- Also whether it was laid on stem lanes that all run the other way (`wrongWay`).
		local function covered(arm: Arm, isB: boolean, fromRight: boolean, useDirs: boolean): ({ [number]: boolean }, boolean)
			local set: { [number]: boolean } = {}
			local wrongWay = false
			local lean = rightOf(arm.dir):Dot(across)
			if arm.anchored and lean >= 0.5 then -- laid off steeply: by count, an ordinary diverge
				local off = flat(arm.pts[1] - node.pos):Dot(across)
				for _, bd in arm.sec.bands do
					if bd.k ~= "lane" then continue end
					local c = off + (bd.x0 + bd.x1) * 0.5 * lean
					for i, l in ahead do
						if c > l.x0 + 0.5 and c < l.x1 - 0.5 then
							if not useDirs or ahead[i].arriving == ((bd.d :: number) > 0) then set[i] = true else wrongWay = true end
						end
					end
				end
				if next(set) then return set, false end
			end
			local out, inn = dirs(arm)
			-- a one-way road whose own side of the stem runs against it lies where the right-way
			-- road would, never across the oncoming lanes (it is stuck)
			if useDirs and (out == 0) ~= (inn == 0) and ahead[if fromRight then nS else 1].arriving ~= (out > 0) then
				out, inn = inn, out
			end
			local left = out + inn
			for q = 1, nS do
				if left <= 0 then break end
				local i = if fromRight then nS - q + 1 else q
				if useDirs then
					if ahead[i].arriving and out > 0 then out -= 1; left -= 1; set[i] = true
					elseif not ahead[i].arriving and inn > 0 then inn -= 1; left -= 1; set[i] = true end
				else
					left -= 1
					set[i] = true
				end
			end
			if not next(set) then set[if fromRight then nS else 1] = true end
			return set, wrongWay
		end
		local function span(set: { [number]: boolean }): (number, number)
			local lo, hi = nS, 1
			for i in set do lo, hi = math.min(lo, i), math.max(hi, i) end
			return lo, hi
		end
		if nS > 0 then
			-- Laid crossed over (the main starting past the branch, on its side: the lanes would have
			-- to cross), or laid on lanes running the other way: placement refuses both now, and an
			-- older road is drawn where it lies, else by count from its side.
			local function lay(useDirs: boolean, byPlace: boolean): ({ [number]: boolean }, { [number]: boolean }, boolean)
				local ma = if byPlace then a else { anchored = false, dir = a.dir, sec = a.sec } :: any
				local mb = if byPlace then b else { anchored = false, dir = b.dir, sec = b.sec } :: any
				local mSet, mWrong = covered(ma, false, not branchRight, useDirs)
				local bSet, bWrong = covered(mb, true, branchRight, useDirs)
				local mLo, mHi = span(mSet)
				local bLo, bHi = span(bSet)
				return mSet, bSet, mWrong or bWrong or (branchRight and mLo > bLo) or (not branchRight and mHi < bHi)
			end
			local useDirs = true
			local mSet, bSet, bad = lay(true, true)
			if bad then
				useDirs = false
				mSet, bSet, bad = lay(false, true)
				if bad then mSet, bSet = lay(false, false) end
			end
			local mLo, mHi = span(mSet)
			local bLo, bHi = span(bSet)
			-- A lane no road lies on goes to the nearer road lying on stem lanes that run its way, else
			-- the nearer one, a tie to the road placed last; it ends in that road, narrowing out on its
			-- gore side (user, 2026-10-06: the last placed road takes it only if it goes the lane's
			-- way -- a lane going out follows the lanes going out).
			-- An arriving lane says how: a merge arrow toward the road carrying it on, or -- nothing
			-- carries it on -- a U-turn arrow (a two-way road) before the split.
			local inM, inB = table.create(nS, false), table.create(nS, false)
			local ends: { [number]: string } = {}
			local lastIsBranch = b.segId > a.segId
			local stemTwoWay = false
			for _, l in ahead do
				if not l.arriving then stemTwoWay = true end
			end
			local function sameWay(set: { [number]: boolean }, i: number): boolean
				for j in set do
					if ahead[j].arriving == ahead[i].arriving then return true end
				end
				return false
			end
			for i = 1, nS do
				if mSet[i] then inM[i] = true end
				if bSet[i] then inB[i] = true end
				if inM[i] or inB[i] then continue end
				local dm = if i < mLo then mLo - i elseif i > mHi then i - mHi else 0
				local db = if i < bLo then bLo - i elseif i > bHi then i - bHi else 0
				local fm, fb = sameWay(mSet, i), sameWay(bSet, i)
				local toB = if fb ~= fm then fb else (db < dm or (db == dm and lastIsBranch))
				if toB then inB[i] = true else inM[i] = true end
				if ahead[i].arriving then
					local carried = if toB then fb else fm
					-- an arriving driver faces out along the fork: a higher `ahead` index is their right
					ends[ahead[i].k] = if not carried and stemTwoWay then "uturn"
						elseif (if toB then bLo else mLo) > i then "right" else "left"
				end
			end
			local function run(isIn: { boolean }): { number }
				local lo, hi = nS, 1
				for i = 1, nS do
					if isIn[i] then lo, hi = math.min(lo, i), math.max(hi, i) end
				end
				return { lo, hi }
			end
			local mRun, bRun = run(inM), run(inB)
			if next(ends) then
				plan.laneEnds = plan.laneEnds or {}
				local had = (plan.laneEnds :: any)[f.stem] or {}
				for k, how in ends do had[k] = how end
				(plan.laneEnds :: any)[f.stem] = had
			end
			-- lanes only the branch has: its exclusive take; the line between is a ramp lane's
			local excl = 0
			for i = 1, nS do
				if inB[i] and not inM[i] then excl += 1 end
			end
			f.take, f.mRun, f.bRun, f.mCov, f.bCov = excl, mRun, bRun, { mLo, mHi }, { bLo, bHi }
			f.crossed = not useDirs or nil -- the roads' lanes would cross: drawn by position and count
			-- a one-way road fed only by stem lanes running against it has no way on (stuckArms)
			local function against(arm: Arm, r: { number }): boolean
				local out, inn = ways(arm.sec)
				if out == inn then return false end
				for i = r[1], r[2] do
					if ahead[i].arriving == out then return false end
				end
				return true
			end
			f.against = { [f.main] = against(a, mRun), [f.branch] = against(b, bRun) }
			f.boundary = if excl > 0 and (if branchRight then mRun[2] + 1 == bRun[1] else bRun[2] + 1 == mRun[1])
				then (if branchRight then mRun[2] else bRun[2]) else nil
		end
		if node.lanesOnly then return end
		-- A main line that runs on in the stem's line keeps the stem's lanes exactly where they
		-- were: its road is drawn shifted across by the difference (carryShifts takes that on
		-- along the road), so a 3-lane highway that drops a lane into an exit carries straight on.
		plan.shift = plan.shift or table.create(n, 0)
		-- A main road laid off lanes is already where the player laid it: never shifted (user,
		-- 2026-10-06: the mesh sat two lanes over from the road they had drawn and could click).
		local pMain = RoadJunctionSolver.at(a, math.min(60, a.len * 0.5))
		local offLine = flat(pMain - a.pts[1]):Dot(across)
		if nS > 0 and nM > 0 and math.abs(offLine) < 2 and not a.anchored and (plan.shift :: any)[f.main] == 0 then
			local first, last = f.mRun[1], f.mRun[2]
			-- lined up on the gore side: lane widths may differ by type, and the difference is
			-- eased in on the outer side, where nothing else is
			plan.shift[f.main] = if branchRight then ahead[last].x1 - (own[#own].x1 + mainOff) else ahead[first].x0 - (own[1].x0 + mainOff)
		end
		-- The gore ends (its nose) where the branch's inner edge has cleared the main road's edge
		-- by GORE_NOSE. Walked on the real curves: a ramp drawn tangent to the highway leaves at
		-- 0 degrees and only parts as it bends, which no angle formula sees.
		local shift = (plan.shift :: any)[f.main]
		-- Stem lanes a laid road takes beyond its own (studs across): it narrows them out over 5x
		-- that from the split, so its part of the fork is at least that long.
		local function extraWidth(run: { number }?, lo: number?, hi: number?): number
			if not run or not lo or not hi then return 0 end
			local w = 0
			for i = run[1], run[2] do
				if i < lo or i > hi then w += ahead[i].x1 - ahead[i].x0 end
			end
			return w
		end
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
		-- A branch laid off a lane already leaves where and how the player drew it: never stretched.
		local steepBranch = not b.anchored and math.acos(math.clamp(b.dir:Dot(t0), -1, 1)) >= math.rad(30)
		if steepBranch then gore = math.max(gore, math.min(DIVERGE_MIN, b.len * 0.6)) end
		-- the branch leaves from the middle of the stem lanes it takes (nothing taken: the
		-- stem's outside lane, which both roads share until they part)
		local startX = if f.bRun then (ahead[f.bRun[1]].x0 + ahead[f.bRun[2]].x1) * 0.5 else 0
		local pA = flat(node.pos) + rightOf(t0) * startX
		local limit = b.len * 0.8
		while steepBranch and gore < limit do
			local pM, tM = RoadJunctionSolver.at(b, gore)
			local legA, legM = RoadJunctionSolver.forkTurn(pA, t0, flat(pM), tM)
			if legA == nil or (legA > 0 and (legM :: number) > 0 and (legM :: number) >= 0.6 * legA) then break end
			gore += 4
		end
		f.gore = gore
		-- A joint that kinks (two pieces drawn at a slight angle): the stem ends, and both groups
		-- leave, on the mitre between the stem and the main road -- one cut, no wedge either side
		-- (user, 2026-10-06: the road "bucking out" between two ramps on a bent highway).
		local into, md = -stem.dir, a.dir
		f.t0 = if into:Dot(md) > math.cos(math.rad(20)) then unit(into + md) else into
		local bCov, mCov = f.bCov or {}, f.mCov or {}
		plan.trims[f.branch] = math.min(math.max(gore, TAPER_PER_SHIFT_HIGHWAY * extraWidth(f.bRun, bCov[1], bCov[2])), b.len * 0.8)
		-- The main line runs alongside the gore to its nose (the stem ends on the node: trim 0).
		local gap = math.acos(math.clamp(a.dir:Dot(b.dir), -1, 1))
		plan.trims[f.main] = math.max(plan.trims[f.main],
			math.min(math.max(gore * math.cos(gap), TAPER_MIN, TAPER_PER_SHIFT_HIGHWAY * extraWidth(f.mRun, mCov[1], mCov[2])), a.len * 0.5))
	end
	if plan.kind == "fork" then
		for _, f in plan.forks or { plan.fork } do planFork(f) end
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

function RoadJunctionSolver.carryShifts(nodes: { [any]: any }, roots: { [any]: any }?): { [number]: Shift }
	local out: { [number]: Shift } = {}
	for id, node in roots or nodes do
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
local function solveAt(network: any, nodeId: number, fewest: number, lanesOnly: boolean?): (Plan?, { [number]: number }?)
	local node = network:getNodes()[nodeId]
	if not node or #node.segments < fewest then return nil, nil end
	local arms: { Arm } = {}
	local index: { [number]: number } = {}
	for _, sid in node.segments do
		local s = network:getSegment(sid)
		if not s or s.isRoundabout or s.vMode == "Elevated" or s.vMode == "Tunnel" then return nil, nil end
		local profile = RoadTypeCatalog.getOrDefault(s.roadType).profile
		if not profile then return nil, nil end
		table.insert(arms, RoadJunctionSolver.arm(s, s.startNode == nodeId, profile, RoadRules.getLaneSideSign(), nil, if lanesOnly then LANES_SAMPLES else nil))
		index[sid] = #arms
	end
	local ok, plan = pcall(RoadJunctionSolver.solve, { pos = node.position, arms = arms, lanesOnly = lanesOnly })
	if not ok then return nil, nil end
	return plan, index
end

function RoadJunctionSolver.planAt(network: any, nodeId: number): (Plan?, { [number]: number }?)
	local plan, index = solveAt(network, nodeId, 3)
	if not plan or plan.kind ~= "junction" then return nil, nil end
	return plan, index
end

-- The roads at a node whose traffic has no way on there, as built (user, 2026-10-07: a road
-- drawn the wrong way is placed like the right-way one, but nothing can use it -- it gets the
-- dead-end pin): a one-way road arriving where no other road leaves, or leaving where none
-- arrives; at a split, one fed only by lanes running against it. By arm index.
function RoadJunctionSolver.stuckArms(plan: Plan): { [number]: boolean }
	local out: { [number]: boolean } = {}
	local against: { [number]: boolean } = {}
	for _, f in plan.forks or { plan.fork } do
		for i, x in (f :: any).against or {} do against[i] = against[i] or x end
	end
	for i, arm in plan.arms do
		local o, n = ways(arm.sec)
		if o == n then continue end
		local fed = false
		for j, other in plan.arms do
			local o2, n2 = ways(other.sec)
			if j ~= i and ((o and n2) or (n and o2)) then fed = true end
		end
		if not fed or against[i] then out[i] = true end
	end
	return out
end

-- stuckArms at `nodeId` of a RoadNetwork (two or more roads): segment id -> a point on that road
-- just off the node, where its pin stands.
function RoadJunctionSolver.stuckAt(network: any, nodeId: number): { [number]: Vector3 }
	local out: { [number]: Vector3 } = {}
	local plan, index = solveAt(network, nodeId, 2, true)
	if not plan or not index then return out end
	local stuck = RoadJunctionSolver.stuckArms(plan)
	for sid, i in index do
		if stuck[i] then
			local arm = plan.arms[i]
			out[sid] = (RoadJunctionSolver.at(arm, math.min(STUCK_PIN_AT, arm.len * 0.5)))
		end
	end
	return out
end

return table.freeze(RoadJunctionSolver)
