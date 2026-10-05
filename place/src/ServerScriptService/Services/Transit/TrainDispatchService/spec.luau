--!strict
-- The signalling contract, on the real rail nav graph: a single (Two-Way) track is held by
-- ONE train whichever way it runs, opposite directions share a Double Track, a passing loop
-- lets two trains leave opposite ends at once, and track frees behind a train's tail.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function()
	local RoadNetwork = require(ReplicatedStorage.Road.RoadNetwork) :: any
	local RoadNavigationGraph = require(ReplicatedStorage.Road.RoadNavigationGraph) :: any
	local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
	local TD = require(script.Parent) :: any
	local T = TD._test
	local Y = 600

	local function world(segs: { any }): any
		local net = RoadNetwork.new()
		for _, s in segs do
			local a, b = Vector3.new(s[1], Y, 0), Vector3.new(s[2], Y, 0)
			net:addSegment(a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b, s[3])
		end
		local g = RoadNavigationGraph.new(function(seg: any) return RoadTypeCatalog.getOrDefault(seg.roadType).isRail == true end)
		g:Rebuild(net)
		TD.Init({ getDepots = function() return {} end }, { getRailGraph = function() return g end, getNetwork = function() return net end }, nil)
		TD.clear()
		return g
	end

	-- A bare train record: all tryBook / releaseBehind read.
	local function train(g: any, x: number, dir: number, goalX: number): any
		local plan = T.plan(g, Vector3.new(x, Y, 0), Vector3.new(dir, 0, 0), Vector3.new(goalX, Y, 0))
		assert(plan, "no path from " .. x .. " to " .. goalX)
		return { blocks = table.clone(plan.blocks), booked = 0, held = {}, headD = 0, endD = plan.length,
			spec = { carLength = 72, carGap = 2, carCount = 3 } }
	end

	describe("TrainDispatchService signalling", function()
		it("lets one train at a time onto a single track", function()
			local g = world({ { 0, 800, "RailSingle" } })
			local east, west = train(g, 100, 1, 700), train(g, 700, -1, 100)
			expect(T.tryBook(east)).to.equal(true)
			expect(T.tryBook(west)).to.equal(false)
		end)

		it("runs opposite directions side by side on double track", function()
			local g = world({ { 0, 800, "Rail" } })
			expect(T.tryBook(train(g, 100, 1, 700))).to.equal(true)
			expect(T.tryBook(train(g, 700, -1, 100))).to.equal(true)
		end)

		it("books a single-track run whole and meets at a passing loop", function()
			local g = world({ { 0, 300, "RailSingle" }, { 300, 500, "Rail" }, { 500, 800, "RailSingle" } })
			local east, west = train(g, 100, 1, 700), train(g, 700, -1, 100)
			expect(T.tryBook(east)).to.equal(true)
			expect(east.booked).to.equal(2) -- its single run plus the loop track after it
			expect(T.tryBook(west)).to.equal(true)
			expect(T.tryBook(east)).to.equal(false) -- the far single track is the other train's
		end)

		it("frees track once the tail is past it", function()
			local g = world({ { 0, 300, "RailSingle" }, { 300, 500, "Rail" }, { 500, 800, "RailSingle" } })
			local east, west = train(g, 100, 1, 700), train(g, 700, -1, 100)
			expect(T.tryBook(east)).to.equal(true)
			east.headD = east.blocks[2].endD -- front at the end of the loop: tail long past the first single track
			T.releaseBehind(east)
			expect(T.tryBook(west)).to.equal(true)
			expect(T.tryBook(west)).to.equal(true) -- and on into the single track the other train left
		end)
	end)
end
