--!strict
-- The road grid: a drawn road snaps its LENGTH along its own heading, so swinging it round
-- keeps one length instead of hopping between world grid points (36 m, 38 m, 41 m...).
return function()
	local SnapUtil = require(script.Parent)
	local PlacementGrid = require(game:GetService("ReplicatedStorage").Shared.PlacementGrid)

	describe("grid", function()
		it("holds on an empty map and puts the start on a grid point", function()
			PlacementGrid.setSize(10)
			SnapUtil.setSegments({})
			SnapUtil.setGuideExclusion(nil)
			local r = SnapUtil.resolve(Vector3.new(13, 0, 27))
			expect(r.snapType).to.equal("grid")
			expect(r.position.X).to.equal(20)
			expect(r.position.Z).to.equal(20)
		end)

		it("keeps one length while the road swings round its start", function()
			PlacementGrid.setSize(10)
			SnapUtil.setSegments({})
			local start = Vector3.new(20, 0, 20)
			SnapUtil.setGuideExclusion(start)
			-- 37 m out (74 studs) on a 10 m grid is 40 m at EVERY heading.
			for deg = 0, 359, 15 do
				local a = math.rad(deg)
				local p = SnapUtil.resolve(start + Vector3.new(math.cos(a), 0, math.sin(a)) * 74).position
				expect((Vector3.new(p.X, 0, p.Z) - start).Magnitude).to.be.near(80, 1e-3)
			end
			SnapUtil.setGuideExclusion(nil)
			PlacementGrid.setEnabled(false)
		end)
	end)

	describe("angle magnet", function()
		it("squares up a road extended off another road, never one started on open ground", function()
			-- A road exists elsewhere on the map, so this is NOT the empty-map case.
			local RoadTypeCatalog = require(game:GetService("ReplicatedStorage").Road.RoadTypeCatalog)
			SnapUtil.setSegments({ [1] = { id = 1, p0 = Vector3.new(5000, 0, 0), p1 = Vector3.new(5010, 0, 0),
				p2 = Vector3.new(5020, 0, 0), p3 = Vector3.new(5030, 0, 0), roadType = RoadTypeCatalog.DEFAULT_ID } })
			SnapUtil.setAngleSnapEnabled(true)
			SnapUtil.setAngleFreeOverride(false)
			local start = Vector3.new(0, 0, 0)
			local nearlySquare = Vector3.new(3, 0, 100) -- ~88 degrees off +X
			-- Open ground: no road at the start, so no reference and no pull.
			expect(SnapUtil.angleSnap(start, nil, nearlySquare)).to.equal(nil)
			-- Extending a road running along +X: the same drag locks to a square T.
			local r = SnapUtil.angleSnap(start, Vector3.xAxis, nearlySquare)
			expect(r).to.be.ok()
			expect(math.abs((r :: any).angleDeg)).to.be.near(90, 1e-3)
		end)
	end)

	-- Lane snapping (user, 2026-10-06): one table for every road -- a road of N lanes lands on a
	-- road of H lanes flush with either side (outer lane on outer lane) and/or centred.
	describe("lanes", function()
		local RoadSection = require(game:GetService("ReplicatedStorage").Road.RoadSection)
		local RoadTypeCatalog = require(game:GetService("ReplicatedStorage").Road.RoadTypeCatalog)
		local function laneSpan(roadType: string): (number, number)
			local lo, hi = math.huge, -math.huge
			for _, b in RoadSection.of(RoadTypeCatalog.get(roadType).profile, false, 1).bands do
				if b.k == "lane" then lo = math.min(lo, b.x0); hi = math.max(hi, b.x1) end
			end
			return lo, hi
		end
		local function oneRoad()
			-- a two-lane street along +X, its dead end at (100, 0, 0); +Z is right of +X
			SnapUtil.setSegments({ [1] = { id = 1, p0 = Vector3.new(0, 0, 0), p1 = Vector3.new(33, 0, 0),
				p2 = Vector3.new(66, 0, 0), p3 = Vector3.new(100, 0, 0), roadType = "NarrowRoad" } })
			SnapUtil.setRoadSnapEnabled(true)
			SnapUtil.setLaneSnapEnabled(true)
			SnapUtil.setGuideExclusion(nil)
		end

		it("puts a one-lane road on the lane under the cursor", function()
			oneRoad()
			SnapUtil.setActiveRoadType("Highway1W")
			local r = SnapUtil.resolve(Vector3.new(50, 0, 6))
			local _, hi = laneSpan("NarrowRoad")
			expect(r.snapType).to.equal("lane")
			expect(r.position.Z).to.be.near(hi * 0.5, 1e-3)
		end)

		it("gives a one-lane road a two-lane dead end's two lanes and its middle", function()
			oneRoad()
			SnapUtil.setActiveRoadType("Highway1W")
			local _, hi = laneSpan("NarrowRoad")
			expect(SnapUtil.resolve(Vector3.new(100, 0, 0.3)).snapType).to.equal("center")
			local r = SnapUtil.resolve(Vector3.new(100, 0, hi * 0.5 + 1)) -- over the right lane
			expect(r.snapType).to.equal("lane")
			expect(r.position.X).to.be.near(100, 1e-3)
			expect(r.position.Z).to.be.near(hi * 0.5, 1e-3)
		end)

		it("welds plainly where the lanes line up in the middle, and with Lane Snap off", function()
			oneRoad()
			SnapUtil.setActiveRoadType("NarrowRoad") -- two lanes on two: the one place is the middle
			expect(SnapUtil.resolve(Vector3.new(100, 0, 3)).snapType).to.equal("center")
			SnapUtil.setLaneSnapEnabled(false)
			expect(SnapUtil.resolve(Vector3.new(50, 0, 6)).snapType).to.equal("center")
			SnapUtil.setLaneSnapEnabled(true)
		end)

		it("leaves from the node where the road changes type when started just short of it", function()
			local a, b, c = Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(200, 0, 0)
			SnapUtil.setSegments({
				[1] = { id = 1, p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b, roadType = "NarrowRoad" },
				[2] = { id = 2, p0 = b, p1 = b:Lerp(c, 1 / 3), p2 = b:Lerp(c, 2 / 3), p3 = c, roadType = "CollectorRoad" },
			})
			SnapUtil.setActiveRoadType("Highway1W")
			local _, hi = laneSpan("NarrowRoad")
			local r = SnapUtil.resolve(Vector3.new(92, 0, hi * 0.5))
			expect(r.snapType).to.equal("lane")
			expect(r.position.X).to.be.near(100, 1e-3)
			-- the same spot on one road (a plain joint at 100) stays where it is
			oneRoad()
			expect(SnapUtil.resolve(Vector3.new(60, 0, hi * 0.5)).position.X).to.be.near(60, 0.5)
		end)

		it("carries a draw on from a dead end once it is pulled past it", function()
			oneRoad()
			SnapUtil.setActiveRoadType("NarrowRoad")
			SnapUtil.setLaneSnapEnabled(false)
			local from = SnapUtil.carryOnFrom(Vector3.new(60, 0, 0), Vector3.new(140, 0, 2))
			expect(from).to.be.ok()
			expect((from :: Vector3).X).to.be.near(100, 1e-3)
			expect(SnapUtil.carryOnFrom(Vector3.new(60, 0, 0), Vector3.new(95, 0, 0))).to.equal(nil) -- still on it
			expect(SnapUtil.carryOnFrom(Vector3.new(60, 0, 0), Vector3.new(60, 0, 80))).to.equal(nil) -- across it
			SnapUtil.setLaneSnapEnabled(true)
		end)

		it("offers the other lane of a dead end that already has a road laid off one lane (a Y)", function()
			local a, n = Vector3.new(0, 0, 0), Vector3.new(100, 0, 0)
			local e = Vector3.new(200, 0, 60)
			SnapUtil.setSegments({
				[1] = { id = 1, p0 = a, p1 = a:Lerp(n, 1 / 3), p2 = a:Lerp(n, 2 / 3), p3 = n, roadType = "Highway2" },
				[2] = { id = 2, p0 = n, p1 = Vector3.new(140, 0, 3.5), p2 = Vector3.new(170, 0, 30), p3 = e,
					roadType = "Highway1W", startLane = Vector3.new(0, 0, 3.5) },
			})
			SnapUtil.setActiveRoadType("Highway1W")
			local r = SnapUtil.resolve(Vector3.new(103, 0, -3)) -- over the end, by its free lane
			expect(r.snapType).to.equal("lane")
			expect(r.position.X).to.be.near(100, 1e-3)
			expect(r.position.Z).to.be.near(-3.5, 1e-3)
		end)

		it("lays a 2-lane one-way road on two lanes, never on the outer lane alone", function()
			local a, e = Vector3.new(0, 0, 0), Vector3.new(200, 0, 0)
			SnapUtil.setSegments({ [1] = { id = 1, p0 = a, p1 = a:Lerp(e, 1 / 3), p2 = a:Lerp(e, 2 / 3), p3 = e, roadType = "Highway4W" } })
			SnapUtil.setActiveRoadType("Highway2W")
			local lo, hi = laneSpan("Highway4W")
			local lane = (hi - lo) / 4
			local r = SnapUtil.resolve(Vector3.new(60, 0, hi - lane * 0.5)) -- over the outer lane
			expect(r.snapType).to.equal("lane")
			expect(r.position.Z).to.be.near(hi - lane, 1e-3) -- the middle of the outer two
			-- wider than the road (5 on 4): centred, or its outer lane on either outer lane
			SnapUtil.setActiveRoadType("Highway5W")
			local wlo = laneSpan("Highway5W")
			local w = SnapUtil.resolve(Vector3.new(60, 0, hi - lane * 0.5))
			expect(w.snapType).to.equal("lane")
			expect(w.position.Z).to.be.near((lo + lane * 0.5) - (wlo + lane * 0.5), 1e-3)
		end)

		it("follows the table: a 3-lane end takes a one-lane road only on its outer lanes", function()
			local a, e = Vector3.new(0, 0, 0), Vector3.new(100, 0, 0)
			SnapUtil.setSegments({ [1] = { id = 1, p0 = a, p1 = a:Lerp(e, 1 / 3), p2 = a:Lerp(e, 2 / 3), p3 = e, roadType = "Highway3W" } })
			SnapUtil.setGuideExclusion(nil)
			SnapUtil.setActiveRoadType("Highway1W")
			local lo, hi = laneSpan("Highway3W")
			local lane = (hi - lo) / 3
			local r = SnapUtil.resolve(Vector3.new(100, 0, 1)) -- by the middle: still an outer lane
			expect(r.snapType).to.equal("lane")
			expect(r.position.Z).to.be.near(hi - lane * 0.5, 1e-3)
			-- and a 2-lane road only centred: the plain weld
			SnapUtil.setActiveRoadType("Highway2W")
			expect(SnapUtil.resolve(Vector3.new(100, 0, hi - lane * 0.5)).snapType).to.equal("center")
		end)

		it("lands an upgrade by the table on the side clicked: flush, or centred", function()
			local seg = { id = 1, p0 = Vector3.zero, p1 = Vector3.new(60, 0, 0), p2 = Vector3.new(120, 0, 0), p3 = Vector3.new(180, 0, 0), roadType = "Highway3W" }
			-- 3 lanes -> 4: flush with either side only, the outer lanes on the old ones
			local right = SnapUtil.upgradeLanding(seg :: any, "Highway4W", Vector3.new(90, 0, 9))
			local left = SnapUtil.upgradeLanding(seg :: any, "Highway4W", Vector3.new(90, 0, -1))
			expect((right.startLane :: Vector3).Z).to.be.near(3.5, 1e-3)
			expect((right.endLane :: Vector3).Z).to.be.near(3.5, 1e-3)
			expect(right.p1.Z).to.be.near(3.5, 1e-3)
			expect((left.startLane :: Vector3).Z).to.be.near(-3.5, 1e-3)
			-- 3 lanes -> 2: centred only, the road stays on its curve
			local narrow = SnapUtil.upgradeLanding(seg :: any, "Highway2W", Vector3.new(90, 0, 9))
			expect(narrow.startLane).to.equal(nil)
			expect(narrow.p1.Z).to.be.near(0, 1e-3)
			expect(narrow.roadType).to.equal("Highway2W")
		end)
	end)
end
