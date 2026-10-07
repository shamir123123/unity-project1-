--!strict
return function()
	local function fixture()
		local source = script.Parent.Source
		local start = assert(string.find(source, "local TAKES_SHIFT", 1, true))
		local finish = assert(string.find(source, "-- The shift a road end", start, true))
		local env = setmetatable({ RoadJunctionSolver = {} }, { __index = getfenv() })
		local fn = assert(loadstring(string.sub(source, start, finish - 1) .. "\nreturn RoadJunctionSolver.carryShifts"))
		setfenv(fn, env)
		local a = { id = 1, startNode = 1, endNode = 2 }
		local b = { id = 2, startNode = 2, endNode = 3 }
		local c = { id = 3, startNode = 3, endNode = 4 }
		local d = { id = 10, startNode = 10, endNode = 11 }
		local nodes = {
			[1] = { plan = { kind = "fork", shift = { [1] = 2 } }, ends = { { seg = a, atStart = true } } },
			[2] = { plan = { kind = "straight" }, ends = { { seg = a, atStart = false }, { seg = b, atStart = true } } },
			[3] = { plan = { kind = "straight" }, ends = { { seg = b, atStart = false }, { seg = c, atStart = true } } },
			[4] = { plan = { kind = "end" }, ends = { { seg = c, atStart = false } } },
			[10] = { plan = { kind = "fork", shift = { [1] = -3 } }, ends = { { seg = d, atStart = true } } },
			[11] = { plan = { kind = "end" }, ends = { { seg = d, atStart = false } } },
		}
		return fn(), nodes, { [1] = nodes[1], [10] = nodes[10] }
	end
	describe("indexed fork shifts", function()
		it("matches full-network shifts through every straight join and retains untouched forks", function()
			local carry, nodes, roots = fixture()
			local expected = carry(nodes)
			local actual = carry(nodes, roots)
			for id, value in expected do
				local got = actual[id]
				assert(got and got.shift == value.shift and got.from == value.from and got.to == value.to
					and got.fork == value.fork, "indexed shift differs from full topology")
			end
			assert(actual[3].to == 4 and actual[10].shift == -3, "downstream or untouched fork shift was lost")
			nodes[3].plan = { kind = "bend" }
			local updated = carry(nodes, roots)
			assert(updated[2] and updated[2].to == nil and not updated[3], "shift crossed a changed non-straight join")
		end)
		it("does not inspect unrelated nonfork nodes when roots are indexed", function()
			local carry, nodes, roots = fixture()
			nodes[99] = { plan = setmetatable({}, { __index = function() error("unrelated node scanned") end }) }
			local actual = carry(nodes, roots)
			assert(actual[3] and actual[10], "indexed traversal lost a fork chain")
		end)
	end)
	describe("two ramps at one point of a divided highway", function()
		it("is one merge per side: no junction box, no lights", function()
			-- user, 2026-10-07: two on-ramps joining at one place opened the median into a signalled box
			local Road = script.Parent.Parent
			local RoadNetwork = require(Road.RoadNetwork)
			local RoadRules = require(Road.RoadRules)
			local RoadSection = require(Road.RoadSection)
			local RoadTypeCatalog = require(Road.RoadTypeCatalog)
			local Solver = require(script.Parent)
			local o = 0 -- the outer lane's middle
			for _, bd in RoadSection.of(RoadTypeCatalog.get("Highway4").profile, false, 1).bands do
				if bd.k == "lane" then o = math.max(o, math.abs((bd.x0 + bd.x1) * 0.5)) end
			end
			local net = RoadNetwork.new()
			net:addSegment(Vector3.new(-300, 0, 0), Vector3.new(-100, 0, 0), Vector3.new(100, 0, 0), Vector3.new(300, 0, 0), "Highway4")
			net:addSegment(Vector3.new(-200, 0, 140), Vector3.new(-130, 0, 60), Vector3.new(-70, 0, o), Vector3.zero, "Highway1W", nil, nil, { endLane = Vector3.new(0, 0, o) })
			local ramp = net:addSegment(Vector3.new(200, 0, -140), Vector3.new(130, 0, -60), Vector3.new(70, 0, -o), Vector3.zero, "Highway1W", nil, nil, { endLane = Vector3.new(0, 0, -o) })
			local nodeId = ramp.endNode
			assert(#net:getNodes()[nodeId].segments == 4, "the ramps did not share the highway's node")
			assert(RoadRules.nodeControl(net, nodeId) == "priority", "a highway with a ramp each side got lights")
			assert(Solver.planAt(net, nodeId) == nil, "a highway with a ramp each side was drawn as a junction box")
		end)
	end)
end
