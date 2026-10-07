--!strict
-- The save/load contract for buildings: a city reloads where it was PLACED, not where the
-- planner would put it today. Guards the two failures that emptied loaded cities --
-- re-planning against a road network that had moved, and a pivot drifting by a rounding
-- step (which orphans BuildingService's position-derived saveKey, and with it every
-- building's level, occupancy and resident family).
return function()
	local PlotService = require(script.Parent.PlotService)
	local Workspace = game:GetService("Workspace")
	local PlotGeometry = require(game:GetService("ReplicatedStorage").City.PlotGeometry)
	local PlacementFit = require(game:GetService("ReplicatedStorage").Shared.PlacementFit)

	-- A CFrame stores float32, so a pivot never compares equal to the decimal that built
	-- it. What must hold is that it lands on the 0.1 grid the save is written to.
	local function onGrid(n: number): number
		return math.floor(n * 10 + 0.5) / 10
	end

	local calls: { any }
	local bldg: any
	-- Monotonic across the whole run, like BuildingService._nextBlueprintId. Recycled ids
	-- would let a fresh building inherit a dead one's "demolished" state, because restore()
	-- demolishes the previous test's buildings.
	local nextBp = 0

	-- ONE fake for the whole run: PlotService.Bind() registers its removal listener exactly
	-- once, so swapping the object per test would leave every later test unwired.
	local fakeBuilding: any
	fakeBuilding = {
		gone = {},
		relocated = {},
		listener = nil,
		-- A road nudged sideways slides its houses instead of losing them.
		relocate = function(bpId, pivot)
			table.insert(fakeBuilding.relocated, { bpId = bpId, pivot = pivot })
			return true
		end,
		developPlot = function(pivot, zone, w, d, mode, segId, building, fw, fd, density)
			nextBp += 1
			local bpId = "BP_" .. tostring(nextBp)
			table.insert(calls, { pivot = pivot, zone = zone, w = w, d = d, mode = mode,
				segId = segId, fw = fw, fd = fd, bpId = bpId, density = density })
			return bpId
		end,
		exists = function(bpId) return not fakeBuilding.gone[bpId] end,
		-- BuildingService.setRoadless: the stage PlotService last pushed for each building.
		stage = {},
		setRoadless = function(bpId, stage) fakeBuilding.stage[bpId] = stage end,
		onBuildingRemoving = function(fn)
			fakeBuilding.listener = fn
			return function() end
		end,
		-- Exactly what the bulldoze tool and demolishUnderPavement do: the building vanishes
		-- from BuildingService, and this signal is the only way PlotService hears about it.
		demolish = function(bpId)
			fakeBuilding.demolishAs(bpId, nil)
		end,
		-- demolishUnderPavement stamps a reason on the signal; the bulldoze tool does not.
		demolishAs = function(bpId, reason)
			if fakeBuilding.gone[bpId] then return end
			fakeBuilding.gone[bpId] = true
			if fakeBuilding.listener then fakeBuilding.listener(bpId, reason) end
		end,
	}

	-- Also ONE shared object: Bind() registers the topology listener exactly once, so a
	-- per-test road network would leave every later test's road edits unheard.
	local fakeRoads: any
	fakeRoads = {
		segments = {},
		topo = nil,
		getNetwork = function()
			return { getSegments = function() return fakeRoads.segments end }
		end,
		onTopologyChanged = function(fn)
			fakeRoads.topo = fn
			return function() end
		end,
	}

	local LOT = require(game:GetService("ReplicatedStorage").City.ZoneGrid).LOT_SIZE

	-- A straight 600-stud road along +X through the origin, id 1. Frontage side +1 is +Z.
	local function straightRoad(id: number, az: number): any
		local a, b = Vector3.new(0, 0, az), Vector3.new(600, 0, az)
		return { id = id, roadType = "NarrowRoad",
			p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
	end

	local function harness()
		calls = {}
		table.clear(fakeBuilding.gone)
		table.clear(fakeBuilding.relocated)
		table.clear(fakeBuilding.stage)
		bldg = fakeBuilding
		fakeRoads.segments = {}
		local fakeNet = {
			SyncPlots = { FireAllClients = function() end, FireClient = function() end },
			RequestPlacePlots = { OnServerEvent = { Connect = function() end } },
			RequestBuildingCatalog = {},
		}
		PlotService.Init(fakeRoads, fakeNet, fakeBuilding)
		-- luau: the fake stands in for RoadService
		local _ = fakeRoads
		PlotService.Bind() -- idempotent; the first call wires the removal listener
	end

	-- Two houses on segment 42, at deliberately awkward coordinates: fractional, negative,
	-- and a yaw that atan2 likes to return with the opposite sign.
	local function savedCity(): { any }
		return { {
			seg = 42, side = 1, t0 = 0.1, t1 = 0.9, depth = 48, width = 32, zone = "Residential",
			b = {
				{ 123.4, 56.7, -890.1, 37.5, 3, 2, 48.6, 47.2 },
				{ 155.4, 56.7, -890.1, 180,  2, 2, 32.4, 47.2 },
			},
		} }
	end

	local function zonedRow(): { any }
		return { {
			seg = 42, side = 1, t0 = 0.1, t1 = 0.9, depth = 48, width = 32, zone = "Residential", s = 1,
			b = {
				{ 0,   4, 0, 0, 3, 2, 32, 47.2, 0.1, 0.3 },
				{ 40,  4, 0, 0, 3, 2, 32, 47.2, 0.3, 0.5 },
				{ 80,  4, 0, 0, 3, 2, 32, 47.2, 0.5, 0.7 },
				{ 120, 4, 0, 0, 3, 2, 32, 47.2, 0.7, 0.9 },
			},
		} }
	end

	local function onlyGroup(): any
		for _, g in PlotService.getGroups() do return g end
		return nil
	end

	local function groupCount(): number
		local n = 0
		for _ in PlotService.getGroups() do n += 1 end
		return n
	end

	describe("demolishing a zoned building", function()
		it("gives back exactly that building's frontage", function()
			harness()
			PlotService.restore(zonedRow())
			expect(#calls).to.equal(4)
			-- Bulldoze the last house: the group must shrink to 0.1..0.7, not stay at 0.9.
			bldg.demolish(calls[4].bpId)
			expect(groupCount()).to.equal(1)
			expect(onlyGroup().t1).to.equal(0.7)
			expect(onlyGroup().t0).to.equal(0.1)
			expect(#onlyGroup().placed).to.equal(3)
		end)

		it("splits the run when a middle house goes, freeing the gap", function()
			harness()
			PlotService.restore(zonedRow())
			bldg.demolish(calls[2].bpId) -- the 0.3..0.5 house
			expect(groupCount()).to.equal(2)
			local spans = {}
			for _, g in PlotService.getGroups() do
				table.insert(spans, tostring(g.t0) .. ".." .. tostring(g.t1))
			end
			table.sort(spans)
			expect(spans[1]).to.equal("0.1..0.3")
			expect(spans[2]).to.equal("0.5..0.9")
		end)

		it("unzones the plot entirely once the last building is gone", function()
			harness()
			PlotService.restore(zonedRow())
			for i = 1, 4 do bldg.demolish(calls[i].bpId) end
			expect(groupCount()).to.equal(0)
		end)

		it("does not resurrect the demolished house on the next load", function()
			harness()
			PlotService.restore(zonedRow())
			bldg.demolish(calls[3].bpId)
			local blob = PlotService.serialize()
			local total = 0
			for _, e in blob do total += #e.b end
			expect(total).to.equal(3)

			harness()
			PlotService.restore(blob)
			expect(#calls).to.equal(3)
		end)

		it("leaves a pre-span save's zoning alone rather than shrinking it wrongly", function()
			harness()
			PlotService.restore(savedCity()) -- 8-number rows, no frontage slices
			expect(#calls).to.equal(2)
			bldg.demolish(calls[2].bpId)
			expect(groupCount()).to.equal(1)
			expect(onlyGroup().t1).to.equal(0.9)
			expect(#onlyGroup().placed).to.equal(1)
		end)
	end)

	describe("city load", function()
		-- A mid-rise street that reloads as houses loses every flat's family, so density
		-- is part of the save contract; saves written before it existed load as houses.
		it("keeps a mid-rise group mid-rise across a save cycle", function()
			harness()
			local blob = zonedRow()
			blob[1].den = "Medium"
			PlotService.restore(blob)
			expect(calls[1].density).to.equal("Medium")
			local again = PlotService.serialize()
			harness()
			PlotService.restore(again)
			expect(#calls).to.equal(4)
			expect(calls[4].density).to.equal("Medium")

			harness()
			PlotService.restore(zonedRow())
			expect(calls[1].density).to.equal(nil)
		end)

		it("puts every saved building back at its exact pivot", function()
			harness()
			PlotService.restore(savedCity())
			expect(#calls).to.equal(2)
			expect(onGrid(calls[1].pivot.Position.X)).to.equal(123.4)
			expect(onGrid(calls[1].pivot.Position.Y)).to.equal(56.7)
			expect(onGrid(calls[1].pivot.Position.Z)).to.equal(-890.1)
			expect(calls[1].w).to.equal(3)
			expect(calls[1].d).to.equal(2)
			expect(calls[1].fw).to.equal(48.6)
			expect(onGrid(calls[2].pivot.Position.X)).to.equal(155.4)
			-- Placed finished, and against the saved road id.
			expect(calls[1].mode).to.equal("instant")
			expect(calls[1].segId).to.equal(42)
		end)

		it("never re-plans a group that carries seats", function()
			-- The fake road network is EMPTY: a re-plan would find no segment 42 and build
			-- nothing. Two buildings means the seats were replayed, not re-derived.
			harness()
			PlotService.restore(savedCity())
			expect(#calls).to.equal(2)
		end)

		it("round-trips save -> load -> save unchanged", function()
			harness()
			local before = savedCity()
			PlotService.restore(before)
			local after = PlotService.serialize()
			expect(#after).to.equal(1)
			expect(#after[1].b).to.equal(2)
			for i = 1, 2 do
				for j = 1, 8 do
					expect(after[1].b[i][j]).to.equal(before[1].b[i][j])
				end
			end
			-- And again: a second cycle must not drift either.
			harness()
			PlotService.restore(after)
			local twice = PlotService.serialize()
			for i = 1, 2 do
				for j = 1, 8 do
					expect(twice[1].b[i][j]).to.equal(before[1].b[i][j])
				end
			end
		end)

		-- Everything that outlives a reload -- the building's level, its exact template
		-- variant (tn), its occupancy, and the family living in it -- hangs off
		-- BuildingService's saveKey, and CitizenService re-links households by that same
		-- string. It is derived from the pivot, so if the pivot moves the house comes back
		-- as a different random building with nobody in it.
		it("keeps every saveKey identical across a save cycle", function()
			-- Exactly BuildingService.saveKeyForPivot / roundedCoord.
			local function roundedCoord(n: number): number
				return if n >= 0 then math.floor(n + 0.5) else math.ceil(n - 0.5)
			end
			local function keysFromCalls(): { string }
				local out = {}
				for _, c in calls do
					table.insert(out, c.zone .. "|" .. tostring(c.w) .. "x" .. tostring(c.d) .. "|"
						.. tostring(roundedCoord(c.pivot.Position.X)) .. "," .. tostring(roundedCoord(c.pivot.Position.Z)))
				end
				return out
			end

			-- Coordinates sitting right on a .5 rounding boundary: the values most likely
			-- to flip to a different key if a pivot drifts by even one grid step.
			local city = { {
				seg = 42, side = 1, t0 = 0.1, t1 = 0.9, depth = 48, width = 32, zone = "Residential",
				b = {
					{ 12.5, 4, -7.5, 90, 3, 2, 48.6, 47.2 },
					{ 44.5, 4, -7.5, 90, 2, 2, 32.4, 47.2 },
				},
			} }

			harness()
			PlotService.restore(city)
			local first = keysFromCalls()
			expect(#first).to.equal(2)

			-- Save, load, save, load: the keys must not budge.
			local blob = PlotService.serialize()
			harness()
			PlotService.restore(blob)
			local second = keysFromCalls()
			blob = PlotService.serialize()
			harness()
			PlotService.restore(blob)
			local third = keysFromCalls()

			expect(#second).to.equal(2)
			expect(#third).to.equal(2)
			for i = 1, 2 do
				expect(second[i]).to.equal(first[i])
				expect(third[i]).to.equal(first[i])
			end
		end)

		it("builds nothing the save did not record", function()
			-- The fake road network is empty and the span covers t 0.1..0.9, which the old
			-- re-planning path would have filled with however many houses fit today.
			harness()
			PlotService.restore(savedCity())
			expect(#calls).to.equal(2)
			local groups = 0
			for _ in PlotService.getGroups() do groups += 1 end
			expect(groups).to.equal(1)
		end)

		it("does not rebuild a house the player bulldozed", function()
			harness()
			PlotService.restore(savedCity())
			expect(#calls).to.equal(2)
			-- Bulldoze the second one, then save.
			bldg.demolish(calls[2].bpId)
			local blob = PlotService.serialize()
			expect(#blob[1].b).to.equal(1)

			harness()
			PlotService.restore(blob)
			expect(#calls).to.equal(1)
			expect(onGrid(calls[1].pivot.Position.X)).to.equal(123.4)
		end)

		it("saves nothing for a plot whose buildings were all cleared", function()
			-- A road laid over the whole row demolishes every building, which unzones the
			-- plot -- so there is no group left to write.
			harness()
			PlotService.restore(savedCity())
			bldg.demolish(calls[1].bpId)
			bldg.demolish(calls[2].bpId)
			expect(#PlotService.serialize()).to.equal(0)
		end)

		it("treats an empty seated group as cleared, not as 'go re-plan me'", function()
			-- Defensive: s = 1 means b is the complete building list. Without the marker an
			-- empty list would fall through to the legacy re-planner and invent a street.
			harness()
			PlotService.restore({ {
				seg = 42, side = 1, t0 = 0.1, t1 = 0.9, depth = 48, width = 32,
				zone = "Residential", s = 1, b = {},
			} })
			expect(#calls).to.equal(0)
		end)

		it("releases frontage whose buildings vanished without a removal event", function()
			-- A group that kept its span with nothing standing on it locked that stretch
			-- against zoning for good: "I can't zone this block and there's nothing there".
			harness()
			PlotService.restore(savedCity())
			bldg.gone[calls[1].bpId] = true
			bldg.gone[calls[2].bpId] = true
			expect(#PlotService.serialize()).to.equal(0)
			local groups = 0
			for _ in PlotService.getGroups() do groups += 1 end
			expect(groups).to.equal(0)
		end)

		it("drops a corrupt seat row instead of building from it", function()
			harness()
			local blob = savedCity()
			blob[1].b[2][1] = 0 / 0 -- NaN smuggled into the blob
			PlotService.restore(blob)
			expect(#calls).to.equal(1)
			expect(onGrid(calls[1].pivot.Position.X)).to.equal(123.4)
		end)

		it("still re-plans a pre-seat save", function()
			harness()
			local blob = savedCity()
			blob[1].b = nil
			PlotService.restore(blob)
			-- No road network to plan against, so nothing builds -- but it must not error,
			-- and the group must not survive as an empty shell.
			expect(#calls).to.equal(0)
			local groups = 0
			for _ in PlotService.getGroups() do groups += 1 end
			expect(groups).to.equal(0)
		end)
	end)
	-- A deleted road leaves its buildings standing for a grace period (user, 2026-10-06):
	-- 7 minutes before families start leaving, 10 before the buildings come down, and a road
	-- built along their fronts in the meantime saves them.
	describe("a deleted road", function()
		local FAR = 7 -- an unrelated road, so the city is not being cleared

		local function deleteRow()
			PlotService.restore(zonedRow())
			fakeRoads.segments = { [FAR] = straightRoad(FAR, 5000) }
			fakeRoads.topo({ segmentIds = {}, removedSegmentIds = { 42 } })
		end

		it("keeps the buildings standing, flagged as having no road", function()
			harness()
			deleteRow()
			expect(groupCount()).to.equal(1)
			for i = 1, 4 do
				expect(bldg.gone[calls[i].bpId]).to.equal(nil)
				expect(bldg.stage[calls[i].bpId]).to.equal("grace")
			end
		end)

		it("starts families moving at 7 minutes and tears the buildings down at 10", function()
			harness()
			deleteRow()
			PlotService.advanceRoadless(419)
			expect(bldg.stage[calls[1].bpId]).to.equal("grace")
			PlotService.advanceRoadless(1)
			expect(bldg.stage[calls[1].bpId]).to.equal("leaving")
			PlotService.advanceRoadless(179)
			expect(bldg.gone[calls[1].bpId]).to.equal(nil)
			PlotService.advanceRoadless(1)
			for i = 1, 4 do expect(bldg.gone[calls[i].bpId]).to.equal(true) end
			expect(groupCount()).to.equal(0)
		end)

		it("re-attaches the buildings to a road built along their fronts", function()
			harness()
			deleteRow()
			PlotService.advanceRoadless(500)
			-- The row stands on side +1 (+Z) of a NarrowRoad: lot front at frontOffset, the
			-- 2-lot-deep house's centre half its depth further back.
			local az = -(PlotGeometry.frontOffset("NarrowRoad", 1) + LOT)
			local a, b = Vector3.new(-100, 0, az), Vector3.new(500, 0, az)
			fakeRoads.segments[9] = { id = 9, roadType = "NarrowRoad",
				p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
			fakeRoads.topo({ segmentIds = { 9 }, removedSegmentIds = {} })
			-- (This fixture's houses stand 8 studs apart, so they come back as separate runs.)
			local seats = 0
			for _, g in PlotService.getGroups() do
				expect(g.roadless).to.equal(nil)
				expect(g.segmentId).to.equal(9)
				expect(g.side).to.equal(1)
				seats += #g.placed
			end
			expect(seats).to.equal(4)
			for i = 1, 4 do expect(bldg.stage[calls[i].bpId]).to.equal(nil) end
			-- and the clock is gone: nothing comes down later
			PlotService.advanceRoadless(600)
			expect(bldg.gone[calls[1].bpId]).to.equal(nil)
		end)

		it("erases quietly when the whole city's roads are cleared (a load)", function()
			harness()
			PlotService.restore(zonedRow())
			fakeRoads.segments = {}
			fakeRoads.topo({ segmentIds = {}, removedSegmentIds = { 42 } })
			expect(groupCount()).to.equal(0)
		end)

		it("carries the clock across a save, so a rejoin is no reprieve", function()
			harness()
			deleteRow()
			PlotService.advanceRoadless(450)
			PlotService.restore(PlotService.serialize())
			local g = onlyGroup()
			expect(g.roadless).to.equal(450)
			for _, id in g.buildingIds do expect(bldg.stage[id]).to.equal("leaving") end
		end)
	end)

	describe("a road laid beside standing houses", function()
		-- Two houses 4 lots deep on a road at z = 0. Their fronts sit 12 studs off the
		-- centreline, so each covers z 12..54.7.
		local function row(): { any }
			local d4 = 4 * LOT
			return { {
				seg = 1, side = 1, t0 = 0.14, t1 = 0.2467, depth = d4, width = 3 * LOT,
				zone = "Residential", s = 1,
				b = {
					{ 100, 0, 12 + d4 * 0.5, 0, 3, 4, 3 * LOT, d4, 0.14, 0.19333 },
					{ 132, 0, 12 + d4 * 0.5, 0, 3, 4, 3 * LOT, d4, 0.19333, 0.24667 },
				},
			} }
		end

		local function loadRow()
			harness()
			fakeRoads.segments = { [1] = straightRoad(1, 0) }
			PlotService.restore(row())
		end

		it("demolishes the house the new road overlaps", function()
			loadRow()
			expect(#calls).to.equal(2)
			local before = { calls[1].bpId, calls[2].bpId }
			-- A back street 60 studs behind the row: both houses now reach into it.
			fakeRoads.segments[2] = straightRoad(2, 60)
			fakeRoads.topo({ segmentIds = { 2 }, removedSegmentIds = {} })
			expect(bldg.gone[before[1]]).to.equal(true)
			expect(bldg.gone[before[2]]).to.equal(true)
		end)

		it("puts a shallower house back in its place", function()
			loadRow()
			fakeRoads.segments[2] = straightRoad(2, 60)
			fakeRoads.topo({ segmentIds = { 2 }, removedSegmentIds = {} })
			-- Two replacements developed, and each is shallower than the 4 lots that no
			-- longer fit. The plot is rebuilt, not abandoned.
			-- 2 lots, not 3: a replacement is PLANNED, and planning keeps a building off a
			-- CROSS street's sidewalk (band.strict), not just its asphalt. 3 lots would back
			-- onto the new road's footway. Was asserted as 3 before that rule existed.
			expect(#calls).to.equal(4)
			expect(calls[3].d).to.equal(2)
			expect(calls[4].d).to.equal(2)
			expect(calls[3].d < 4).to.equal(true)
			expect(#onlyGroup().placed).to.equal(2)
		end)

		it("leaves houses the road does not reach alone", function()
			loadRow()
			-- Far enough back that a 4-lot house still clears it.
			fakeRoads.segments[2] = straightRoad(2, 400)
			fakeRoads.topo({ segmentIds = { 2 }, removedSegmentIds = {} })
			expect(#calls).to.equal(2)
			expect(#onlyGroup().placed).to.equal(2)
		end)

		-- The Move tool removes a leg and re-adds it under a NEW segment id. Nothing may
		-- read that as "my road was deleted" -- that is what bulldozed every zone on a
		-- street the player nudged a few studs sideways.
		local function movedRoad(shiftZ: number): any
			local old = straightRoad(1, 0)
			local new = straightRoad(7, shiftZ)
			fakeRoads.segments = { [7] = new }
			return { segmentIds = { 7 }, removedSegmentIds = { 1 },
				movedSegments = { [1] = { id = 7,
					from = { old.p0, old.p1, old.p2, old.p3 },
					to   = { new.p0, new.p1, new.p2, new.p3 } } } }
		end

		it("keeps the zoning when the road moves and re-points it at the new id", function()
			loadRow()
			fakeRoads.topo(movedRoad(4))
			expect(groupCount()).to.equal(1)
			expect(onlyGroup().segmentId).to.equal(7)
			expect(#onlyGroup().placed).to.equal(2)
		end)

		it("slides the houses along with a small move", function()
			loadRow()
			local z0 = onlyGroup().placed[1].pivot.Position.Z
			fakeRoads.topo(movedRoad(4))
			expect(#bldg.relocated).to.equal(2)
			expect(onGrid(onlyGroup().placed[1].pivot.Position.Z - z0)).to.equal(4)
		end)

		it("leaves the houses put when the road moved too far to follow", function()
			loadRow()
			local z0 = onlyGroup().placed[1].pivot.Position.Z
			fakeRoads.topo(movedRoad(200)) -- past MAX_SEAT_SHIFT
			expect(#bldg.relocated).to.equal(0)
			expect(onGrid(onlyGroup().placed[1].pivot.Position.Z)).to.equal(onGrid(z0))
		end)

		-- A one-way flipped IN PLACE keeps its segment id but runs the other way. The same
		-- kerb is now side -1 and the frontage counts from the other end; nothing may be
		-- demolished or re-planned (the old flip re-added the road and bulldozed the street).
		it("keeps every house when its one-way is flipped in place", function()
			loadRow()
			local s = straightRoad(1, 0)
			s.p0, s.p1, s.p2, s.p3 = s.p3, s.p2, s.p1, s.p0
			fakeRoads.segments = { [1] = s }
			fakeRoads.topo({ segmentIds = { 1 }, removedSegmentIds = {}, reversedSegments = { [1] = true } })
			expect(#calls).to.equal(2) -- nothing rebuilt
			local g = onlyGroup()
			expect(g.segmentId).to.equal(1)
			expect(g.side).to.equal(-1)
			expect(#g.placed).to.equal(2)
			expect(bldg.gone[calls[1].bpId]).to.equal(nil)
			expect(onGrid(g.t0)).to.equal(onGrid(1 - 0.2467))
		end)

		it("re-zones a plot a road edit took, instead of handing the ground back", function()
			loadRow()
			bldg.demolishAs(calls[1].bpId, "road")
			expect(#calls).to.equal(3) -- a replacement went straight up on the same frontage
			expect(#onlyGroup().placed).to.equal(2)
		end)

		it("still unzones the plot when the PLAYER bulldozes the house", function()
			loadRow()
			bldg.demolish(calls[1].bpId)
			expect(#calls).to.equal(2) -- nothing rebuilt
			expect(#onlyGroup().placed).to.equal(1)
		end)

		-- THE respawn bug: refitSeats asked PlotGeometry.buildingBlocked, whose road index
		-- carries an "is anything standing here?" predicate -- and a standing house occupies
		-- its own seat. So every house within reach of ANY road edit was demolished and
		-- rebuilt on the spot: the whole street visibly respawned when a road went down
		-- somewhere near it. The refit judges PAVEMENT and nothing else.
		it("does not bulldoze a house just because a building stands on its own seat", function()
			loadRow()
			local seat = onlyGroup().placed[1]
			local corners = PlotGeometry.seatCorners(seat.pivot, seat.w, seat.d)

			-- A real part on the seat, so the real occupancy predicate really answers "taken".
			local city = Workspace:FindFirstChild("_City")
			local madeCity = city == nil
			if not city then
				city = Instance.new("Folder")
				city.Name = "_City"
				city.Parent = Workspace
			end
			local holder = Instance.new("Folder")
			holder.Name = "SpecStandingHouse"
			holder.Parent = city
			local house = Instance.new("Part")
			house.Anchored = true
			house.Size = Vector3.new(seat.w * LOT - 6, 10, seat.d * LOT - 6)
			house.CFrame = seat.pivot + Vector3.new(0, 4, 0)
			house.Parent = holder

			local ok, err = pcall(function()
				-- Fixture guard: without this the test can pass by asserting nothing at all.
				expect(PlacementFit.seatOccupied(corners)).to.equal(true)
				local aId, bId = calls[1].bpId, calls[2].bpId
				-- Close enough to be inside the refit box (REFIT_REACH), far enough that no
				-- house comes near its pavement: the houses' backs are at z 54.7. This is the
				-- case the bug hit -- "a road went down NEAR my street".
				fakeRoads.segments[2] = straightRoad(2, 120)
				fakeRoads.topo({ segmentIds = { 2 }, removedSegmentIds = {} })
				expect(bldg.gone[aId]).to.equal(nil)
				expect(bldg.gone[bId]).to.equal(nil)
				expect(#calls).to.equal(2)
			end)

			holder:Destroy()
			if madeCity then city:Destroy() end
			if not ok then error(err) end
		end)

		it("ignores a bulk rebuild rather than churning the whole city", function()
			-- A city load replays every segment; the plots are replaced wholesale right
			-- after, so refitting against a half-restored network is pure churn.
			loadRow()
			fakeRoads.segments[2] = straightRoad(2, 60)
			local many = {}
			for i = 1, 40 do many[i] = 2 end
			fakeRoads.topo({ segmentIds = many, removedSegmentIds = {} })
			expect(#calls).to.equal(2)
		end)
	end)
end
