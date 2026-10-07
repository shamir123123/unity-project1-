--!strict
-- What a zoned street must look like on the ground: houses that tile without gaps, and no
-- house with a wall in the road. Both were visible bugs -- a corner plot laid over the cross
-- street's asphalt, and rows of houses marooned in grass -- so both are pinned here.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local PlotGeometry = require(script.Parent.PlotGeometry)
	local BezierUtil    = require(ReplicatedStorage.Road.BezierUtil)
	local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
	local WALK = require(ReplicatedStorage.Road.RoadConstants).SIDEWALK_WIDTH
	local LOT = require(ReplicatedStorage.City.ZoneGrid).LOT_SIZE

	local function seg(id: number, ax: number, az: number, bx: number, bz: number): any
		local a, b = Vector3.new(ax, 0, az), Vector3.new(bx, 0, bz)
		return { id = id, roadType = "NarrowRoad",
			p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
	end

	-- Deliberately NOT PlotGeometry's own test: the flat distance from a point to a road
	-- centreline, against that road's own half-width. "Is there a wall in the asphalt."
	local function inAsphalt(segs: { any }, pt: Vector3): boolean
		for _, s in segs do
			local hw = RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5
			local q = BezierUtil.closestPoint(s.p0, s.p1, s.p2, s.p3, pt, 64)
			local dx, dz = q.X - pt.X, q.Z - pt.Z
			if dx * dx + dz * dz < hw * hw then return true end
		end
		return false
	end

	-- Every corner and edge midpoint of a placed building, so a rect that only clips a road
	-- with one corner still counts.
	local function rectInAsphalt(segs: { any }, c: { Vector3 }): boolean
		local pts = { c[1], c[2], c[3], c[4],
			(c[1] + c[2]) * 0.5, (c[2] + c[3]) * 0.5, (c[3] + c[4]) * 0.5, (c[4] + c[1]) * 0.5 }
		for _, p in pts do
			if inAsphalt(segs, p) then return true end
		end
		return false
	end

	-- Studs of ground between a seat's front edge and the asphalt it faces. A footway's
	-- worth of it on a road with no footway is the bug this pins.
	local function frontGap(s: any, c: { Vector3 }): number
		local hw = RoadTypeCatalog.getOrDefault(s.roadType).width * 0.5
		local g = math.huge
		for _, p in { c[1], c[2], (c[1] + c[2]) * 0.5 } do
			local q = BezierUtil.closestPoint(s.p0, s.p1, s.p2, s.p3, p, 64)
			local dx, dz = q.X - p.X, q.Z - p.Z
			g = math.min(g, math.sqrt(dx * dx + dz * dz) - hw)
		end
		return g
	end

	local function extentAlong(c: { Vector3 }, ax: Vector3): (number, number)
		local lo, hi = math.huge, -math.huge
		for _, p in c do
			local v = p.X * ax.X + p.Z * ax.Z
			lo = math.min(lo, v); hi = math.max(hi, v)
		end
		return lo, hi
	end

	-- SAT penetration of two XZ quads (0 = clear). Neighbours may share a fence line; a
	-- parcel sunk deep into another is a planner that double-booked the ground.
	local function rectPen(A: { Vector3 }, B: { Vector3 }): number
		local worst = math.huge
		for _, e in { A[2] - A[1], A[4] - A[1], B[2] - B[1], B[4] - B[1] } do
			local flat = Vector3.new(e.X, 0, e.Z)
			if flat.Magnitude >= 1e-4 then
				local ax = flat.Unit
				local aLo, aHi = extentAlong(A, ax)
				local bLo, bHi = extentAlong(B, ax)
				local pen = math.min(aHi, bHi) - math.max(aLo, bLo)
				if pen <= 0 then return 0 end
				worst = math.min(worst, pen)
			end
		end
		return worst
	end

	describe("a zoned street", function()
		it("gives every house the full width of its plot", function()
			-- Plots always tile the frontage, so the ONLY way a gap opens between two houses
			-- is a house narrower than the plot it sits on. That is what used to happen on
			-- the inside of every bend: neighbouring rects converge there, and the fix was to
			-- shave a lot off the width -- leaving a ragged row with grass between the houses.
			-- Depth is the thing to give up on a bend; frontage is what keeps the street solid.
			local bend = { id = 1, roadType = "NarrowRoad",
				p0 = Vector3.new(0, 0, 0), p1 = Vector3.new(200, 0, 0),
				p2 = Vector3.new(300, 0, 100), p3 = Vector3.new(300, 0, 300) }
			local idx = PlotGeometry.buildRoadIndex({ bend })
			local built, narrowed = 0, 0
			for _, side in { 1, -1 } do
				for _, pl in PlotGeometry.planSpan(idx, bend, side, 0, 1, 4 * LOT, 3 * LOT, false) do
					if not pl.blocked then
						built += 1
						if pl.w < pl.parcelLots then narrowed += 1 end
					end
				end
			end
			expect(built > 20).to.equal(true)
			expect(narrowed).to.equal(0)
		end)

		it("leaves no gap between neighbours on a straight road", function()
			local segs = { seg(1, 0, 0, 600, 0) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			local plans = PlotGeometry.planSpan(idx, segs[1], 1, 0, 1, 4 * LOT, 2 * LOT, false)
			local built = 0
			local worstGap, yards = 0, 0
			local prevHi: number? = nil
			for _, pl in plans do
				if not pl.blocked then
					built += 1
					local lo, hi = extentAlong(pl.corners, Vector3.xAxis)
					if prevHi then
						local gap = lo - prevHi
						worstGap = math.max(worstGap, gap)
						if gap >= 1 then yards += 1 end
					end
					prevHi = hi
				end
			end
			expect(built > 20).to.equal(true)
			-- Neighbouring lots share an edge; the one exception is the run's last plot, which
			-- holds the sub-lot leftover as side yard (its building centred). A missing lot
			-- would read ~21.
			expect(yards <= 1).to.equal(true)
			expect(worstGap < LOT * 0.5).to.equal(true)
		end)

		it("carries a run to the end of its road piece", function()
			-- A long road is auto-split into pieces and each packs from its own t = 0, so the
			-- sub-lot leftover used to be stranded at every join: a notch of bare grass every
			-- couple of hundred studs on a dead straight street.
			local segs = { seg(1, 0, 0, 400, 0), seg(2, 400, 0, 800, 0) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			local edges = {}
			for _, id in { 1, 2 } do
				for _, pl in PlotGeometry.planSpan(idx, segs[id], 1, 0, 1, 4 * LOT, 2 * LOT, false) do
					if not pl.blocked then
						local lo, hi = extentAlong({ pl.plot.frontA, pl.plot.frontB, pl.plot.backA, pl.plot.backB }, Vector3.xAxis)
						table.insert(edges, { lo, hi })
					end
				end
			end
			table.sort(edges, function(p, q) return p[1] < q[1] end)
			expect(#edges > 30).to.equal(true)
			local worst = 0
			for i = 2, #edges do
				worst = math.max(worst, edges[i][1] - edges[i - 1][2])
			end
			-- The two runs meet at x = 400 instead of leaving most of a lot bare.
			expect(worst < 1).to.equal(true)
		end)

		it("takes a drag across a join to be a drag through it", function()
			-- The tool samples the cursor once a frame, so crossing from one piece to the next
			-- records neither piece's shared end. Both pieces being in the drag means the
			-- player went straight past that node.
			local a1, b1 = seg(1, 0, 0, 400, 0), seg(2, 400, 0, 800, 0)
			local away = seg(3, 0, 900, 400, 900)
			local drag = {
				[1] = { seg = a1, tMin = 0.30, tMax = 0.90 },
				[2] = { seg = b1, tMin = 0.08, tMax = 0.60 },
				[3] = { seg = away, tMin = 0.40, tMax = 0.50 },
			}
			PlotGeometry.bridgeJoins(drag)
			-- The shared node at x = 400 is now covered from both sides...
			expect(drag[1].tMax).to.equal(1)
			expect(drag[2].tMin).to.equal(0)
			-- ...while the outer ends of the drag, and a segment that shares no node with
			-- the others, keep exactly what the player painted.
			expect(drag[1].tMin).to.equal(0.30)
			expect(drag[2].tMax).to.equal(0.60)
			expect(drag[3].tMin).to.equal(0.40)
			expect(drag[3].tMax).to.equal(0.50)
		end)

		it("stands a house on the kerb of a road that has no kerb", function()
			-- An alley carries no footway, but the frontage line added SIDEWALK_WIDTH anyway, so
			-- every house on one stood a pavement out in the grass fronting bare asphalt.
			local alley = seg(1, 0, 0, 600, 0)
			alley.roadType = "Alley"
			local idx = PlotGeometry.buildRoadIndex({ alley })
			local built, worst = 0, 0
			for _, side in { 1, -1 } do
				for _, pl in PlotGeometry.planSpan(idx, alley, side, 0, 1, 4 * LOT, 2 * LOT, false) do
					if not pl.blocked then
						built += 1
						expect(rectInAsphalt({ alley }, pl.corners)).to.equal(false)
						worst = math.max(worst, frontGap(alley, pl.corners))
					end
				end
			end
			expect(built > 20).to.equal(true)
			-- A phantom footway reads a full WALK here; the shoulder is a couple of studs.
			expect(worst < WALK * 0.5).to.equal(true)
		end)

		it("leaves the footway gap only on the side that has a footway", function()
			-- Same street, pavement switched to the right kerb only: the right side keeps its
			-- setback, the left fronts the asphalt.
			local street = seg(1, 0, 0, 600, 0)
			street.roadType = RoadTypeCatalog.encodeConfig("NarrowRoad", { sidewalk = "right" })
			local idx = PlotGeometry.buildRoadIndex({ street })
			local gaps = {}
			for _, side in { 1, -1 } do
				local worst, built = 0, 0
				for _, pl in PlotGeometry.planSpan(idx, street, side, 0, 1, 4 * LOT, 2 * LOT, false) do
					if not pl.blocked then
						built += 1
						worst = math.max(worst, frontGap(street, pl.corners))
					end
				end
				expect(built > 20).to.equal(true)
				gaps[side] = worst
			end
			expect(gaps[1] > WALK * 0.9).to.equal(true)  -- +side is the right kerb: full footway
			expect(gaps[-1] < WALK * 0.5).to.equal(true)
		end)

		it("never seats a house in the road", function()
			-- A cross street the frontage runs straight past: no shared node, so the junction
			-- clearances never fire and the road-overlap test is the only thing standing
			-- between a house and the asphalt.
			local segs = { seg(1, 0, 0, 600, 0), seg(2, 200, -150, 200, 300) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			local offenders = 0
			local built = 0
			for _, side in { 1, -1 } do
				for _, pl in PlotGeometry.planSpan(idx, segs[1], side, 0, 1, 4 * LOT, 3 * LOT, false) do
					if not pl.blocked then
						built += 1
						if rectInAsphalt(segs, pl.corners) then offenders += 1 end
					end
				end
			end
			expect(built > 0).to.equal(true)
			expect(offenders).to.equal(0)
		end)

		it("sees a street that crosses a big seat between its corners", function()
			-- The road test used to sample nine points ON the footprint (corners, edge
			-- midpoints, centre). Those sit half a footprint apart, so on a 5x5 seat an
			-- ordinary 18-stud street could run diagonally BETWEEN them and read as clear --
			-- which is how a picked 5x5 shop came to sit across a road. The test walks the
			-- ROAD now, so the size of the footprint cannot open a gap in it.
			local L = 5 * LOT * 0.5 -- half the seat, and the old sample spacing
			local seat = { Vector3.new(-L, 0, -L), Vector3.new(L, 0, -L),
				Vector3.new(L, 0, L), Vector3.new(-L, 0, L) }
			-- A 45 deg street through (L/4, -L/4) threads the widest gap between those nine.
			local dir = Vector3.new(1, 0, 1).Unit
			local on = Vector3.new(L * 0.25, 0, -L * 0.25)
			local a, b = on - dir * 150, on + dir * 150
			local street = { id = 1, roadType = "NarrowRoad",
				p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
			local idx = PlotGeometry.buildRoadIndex({ street })
			expect(PlotGeometry.buildingBlocked(idx, seat, nil)).to.equal(true)
		end)

		it("shrinks a house to fit rather than leaving the plot empty", function()
			-- A back street 60 studs behind the frontage: a full 4-lot-deep house would reach
			-- into it, so the row must come back shallower -- not missing.
			local segs = { seg(1, 0, 0, 600, 0), seg(2, 0, 60, 600, 60) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			local plans = PlotGeometry.planSpan(idx, segs[1], 1, 0, 1, 4 * LOT, 3 * LOT, false)
			local built, trimmed = 0, 0
			for _, pl in plans do
				if not pl.blocked then
					built += 1
					if pl.d < 4 then trimmed += 1 end
					expect(rectInAsphalt(segs, pl.corners)).to.equal(false)
				end
			end
			expect(built > 0).to.equal(true)
			expect(trimmed).to.equal(built)
		end)

		it("fills a block from its long sides, a building deep", function()
			-- Area zoning used to plan every frontage on its own and then fight the overlaps,
			-- so a block came out as stranded strips: rows crossing in from the ends into rows
			-- from the sides, most of them dropped, most of the ground left bare. Longest
			-- frontage first, and ground a row has claimed is gone, is what a planner draws.
			-- A parcel is as deep as the deepest building (5 lots): the zone is where the lot's
			-- fence is, so a block deeper than two buildings keeps a strip down its middle.
			local segs = { seg(1, -60, 0, 460, 0), seg(2, -60, 150, 460, 150),
				seg(3, 0, -60, 0, 210), seg(4, 400, -60, 400, 210) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			-- Drawn INSIDE the block, the way a player drags over the grass they want built
			-- on -- not along the kerb, which is where the offset frontage line actually sits.
			local poly = { Vector3.new(20, 0, 22), Vector3.new(380, 0, 22),
				Vector3.new(380, 0, 128), Vector3.new(20, 0, 128) }
			local built, full, area = 0, 0, 0
			local quads: { { Vector3 } } = {}
			for _, pl in PlotGeometry.planPolygon(segs, idx, poly, 3 * LOT, false) do
				if not pl.blocked then
					built += 1
					area += pl.plot.frontage * pl.plot.depth
					if pl.segId <= 2 and pl.plot.depth >= 5 * LOT - 0.01 then full += 1 end
					table.insert(quads, { pl.plot.frontA, pl.plot.frontB, pl.plot.backB, pl.plot.backA })
				end
			end
			expect(built > 20).to.equal(true)
			-- The long sides are built first, and a full building deep.
			expect(full >= 20).to.equal(true)
			-- ...and the ground they cover IS the selection, not a few strips across it.
			expect(area >= (380 - 20) * (128 - 22)).to.equal(true)
			local worst = 0
			for a = 1, #quads do
				for b = a + 1, #quads do
					worst = math.max(worst, rectPen(quads[a], quads[b]))
				end
			end
			-- Parcels touch; none stands in another's fence.
			expect(worst < 0.5).to.equal(true)
		end)

		it("gives a shop's parcel exactly its building's depth (a house keeps a backyard)", function()
			-- A block too deep for two rows: the fill pass hands each row the ground behind it.
			local segs = { seg(1, -60, 0, 460, 0), seg(2, -60, 150, 460, 150),
				seg(3, 0, -60, 0, 210), seg(4, 400, -60, 400, 210) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			local poly = { Vector3.new(20, 0, 22), Vector3.new(380, 0, 22),
				Vector3.new(380, 0, 128), Vector3.new(20, 0, 128) }
			local function mismatched(fit: boolean): (number, number)
				local bad, built = 0, 0
				for _, pl in PlotGeometry.planPolygon(segs, idx, poly, 3 * LOT, false, fit) do
					if pl.blocked then continue end
					built += 1
					if math.abs(pl.plot.depth - pl.d * LOT) > 0.01 then bad += 1 end
				end
				return bad, built
			end
			local bad, built = mismatched(true)
			expect(built > 20).to.equal(true)
			expect(bad).to.equal(0)
			expect((mismatched(false)) > 0).to.equal(true) -- houses: the backyard runs on past the house
		end)

		it("keeps a row round the inside of a bend out of each other's lots", function()
			-- A rect is the template's whole lot, fence and all. On the inside of a bend the
			-- rects converge toward their backs; they used to be allowed 8 studs into each other
			-- (industrial fences crossed at every bend). The row now spaces out instead.
			local a, b = Vector3.new(0, 0, 0), Vector3.new(200, 0, 200)
			local bend = { id = 1, roadType = "NarrowRoad", p0 = a, p1 = Vector3.new(110, 0, 0),
				p2 = Vector3.new(200, 0, 90), p3 = b }
			local idx = PlotGeometry.buildRoadIndex({ bend })
			for _, side in { 1, -1 } do
				local rects: { { Vector3 } } = {}
				for _, pl in PlotGeometry.planSpan(idx, bend, side, 0, 1, 4 * LOT, 3 * LOT, false) do
					if not pl.blocked then table.insert(rects, pl.corners) end
				end
				expect(#rects >= 4).to.equal(true)
				local worst = 0
				for i = 1, #rects do
					for j = i + 1, #rects do
						worst = math.max(worst, rectPen(rects[i], rects[j]))
					end
				end
				expect(worst < 0.5).to.equal(true)
			end
		end)

		it("reads back a seated house at the rect it was placed on", function()
			-- The refit pass re-tests SAVED seats from the pivot alone. If seatCorners and
			-- buildingRect ever disagreed, a road edit anywhere would start demolishing
			-- healthy houses (or miss the overlapping ones it exists to catch).
			local segs = { seg(1, 0, 0, 600, 0) }
			local idx = PlotGeometry.buildRoadIndex(segs)
			local worst = 0
			local checked = 0
			for _, pl in PlotGeometry.planSpan(idx, segs[1], 1, 0, 1, 4 * LOT, 3 * LOT, false) do
				if not pl.blocked then
					checked += 1
					local back = PlotGeometry.seatCorners(pl.pivot, pl.w, pl.d)
					for i = 1, 4 do
						worst = math.max(worst, (back[i] - pl.corners[i]).Magnitude)
					end
				end
			end
			expect(checked > 0).to.equal(true)
			expect(worst < 0.01).to.equal(true)
		end)
		it("never cuts a 2-lot plot into a row of houses", function()
			-- Houses are real size and none fits 2 lots, so a 3-lot row must absorb its
			-- remainder into a wider plot instead of ending on a 2-lot filler.
			local narrowest, built = math.huge, 0
			for len = 60, 160, 7 do
				local s = seg(1, 0, 0, len, 0)
				for _, pl in PlotGeometry.planSpan(PlotGeometry.buildRoadIndex({ s }), s, 1, 0, 1, 4 * LOT, 3 * LOT, false) do
					if not pl.blocked then
						built += 1
						narrowest = math.min(narrowest, pl.parcelLots)
					end
				end
			end
			expect(built > 10).to.equal(true)
			expect(narrowest >= PlotGeometry.MIN_HOUSE_LOTS).to.equal(true)
		end)
	end)
	-- A Line drag pulled BACKWARDS from where it was clicked packs from its far end, so the
	-- house the click showed stays put while the drag grows (PlotController anchors on it).
	it("packs a backwards drag from its far end, keeping that end's house still", function()
		local s = seg(1, 0, 0, 200, 0)
		local fwd = PlotGeometry.packPlots(s, 1, 0.2, 0.8, 3 * LOT, 3 * LOT, true)
		local rev = PlotGeometry.packPlots(s, 1, 0.2, 0.8, 3 * LOT, 3 * LOT, true, true)
		expect(#rev).to.equal(#fwd)
		expect(math.abs(fwd[1].t0 - 0.2) < 1e-6).to.equal(true)
		expect(math.abs(rev[#rev].t1 - 0.8) < 1e-6).to.equal(true)
		expect(rev[1].t0 > fwd[1].t0 + 1e-3).to.equal(true) -- the remainder went to the near end
		for i, p in rev do
			expect(p.t0 < p.t1).to.equal(true)
			if i > 1 then expect(p.t0 >= rev[i - 1].t1 - 1e-6).to.equal(true) end
			expect((p.frontB - p.frontA):Dot(Vector3.xAxis) > 0).to.equal(true)
		end
	end)
	local function road(id: number, roadType: string, a: Vector3, b: Vector3): any
		return { id = id, roadType = roadType, p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
	end

	-- Templates fill their lots, so buildings a lot apart stand wall to wall; the leftover
	-- frontage is side yard on the last plot (its building centred), which still reaches the
	-- segment end.
	it("lays a row shoulder to shoulder, the leftover as side yard at the end", function()
		local s = seg(1, 0, 0, 200, 0)
		local pls = PlotGeometry.planSpan(PlotGeometry.buildRoadIndex({ s }), s, 1, 0, 1, 3 * LOT, 3 * LOT)
		expect(#pls >= 3).to.equal(true)
		for i = 2, #pls do
			local a, b = pls[i - 1], pls[i]
			expect(a.blocked or b.blocked).to.equal(false)
			local gap = math.abs(b.pivot.Position.X - a.pivot.Position.X) - (a.w + b.w) * LOT * 0.5
			if i < #pls then
				expect(math.abs(gap) < 0.05).to.equal(true)
			else
				expect(gap > -0.05 and gap < LOT * 0.5).to.equal(true)
			end
		end
		expect(math.abs(pls[#pls].plot.t1 - 1) < 1e-3).to.equal(true)
	end)

	-- A corner lot keeps off the side street's own reach and its rounded kerb -- not off a
	-- footway an alley does not have, nor the whole fillet mouth.
	it("lets a corner lot reach an alley's corner, not a pavement's width short of it", function()
		local O = Vector3.zero
		local west = road(1, "NarrowRoad", Vector3.new(-100, 0, 0), O)
		local east = road(2, "NarrowRoad", O, Vector3.new(100, 0, 0))
		local alley = road(3, "Alley", O, Vector3.new(0, 0, 100))
		local idx = PlotGeometry.buildRoadIndex({ west, east, alley })
		local lo = PlotGeometry.clampSpan(idx, east, 0, 1, 1) -- the alley opens onto side +1
		expect(lo ~= nil).to.equal(true)
		expect((lo :: number) * 100 < 8.5).to.equal(true) -- 7 now; a footway's reach held it at 10, the fillet mouth at 17
		local pls = PlotGeometry.planSpan(idx, east, 1, 0, 0.5, 3 * LOT, 3 * LOT)
		expect(#pls > 0 and not pls[1].blocked).to.equal(true)
	end)

	-- The side road's centreline inside the junction is not road a lot across the street can
	-- touch; judging by it drew a reach circle over the main road and ate the plot opposite.
	it("does not block the plot straight across the road from a T", function()
		local O = Vector3.zero
		local west = road(1, "NarrowRoad", Vector3.new(-100, 0, 0), O)
		local east = road(2, "NarrowRoad", O, Vector3.new(100, 0, 0))
		local stem = road(3, "CollectorRoad", O, Vector3.new(0, 0, 100))
		local idx = PlotGeometry.buildRoadIndex({ west, east, stem })
		local pls = PlotGeometry.planSpan(idx, east, -1, 0, 0.4, 3 * LOT, 3 * LOT)
		expect(#pls > 0).to.equal(true)
		expect(pls[1].blocked).to.equal(false)
		expect(pls[1].w).to.equal(pls[1].parcelLots)
		expect(math.abs(pls[1].plot.t0) < 1e-3).to.equal(true) -- zonable right across the node
	end)
end
