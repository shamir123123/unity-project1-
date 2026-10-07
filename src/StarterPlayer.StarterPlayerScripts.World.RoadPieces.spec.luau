--!strict
return function()
	local function harness(source: string): any
		local env = setmetatable({
			RoadPieces = {},
			_covered = { Segment_7 = true, Junction_8 = true, DeadEnd_8 = true, Corner_8 = true },
			_seen = {}, _ends = {}, _plans = {}, _predictions = {},
			_predictionNodes = {}, _predictionNodeCounts = {},
			DataCache = {GetSegmentById=function() return {id=7,startNode=8,endNode=10} end},
			requestRebuild = function() end,predictedSegments=function(list) return list end,_authoritative={},
			setPiece = function() end,
		}, { __index = getfenv() })
		local predictionStart=assert(source:find("function RoadPieces.setPrediction",1,true))
		local predictionEnd=assert(source:find("function RoadPieces.isIdle",predictionStart,true))
		local predictionApi=assert(loadstring(source:sub(predictionStart,predictionEnd-1)))
		setfenv(predictionApi,env)()
		local start = assert(string.find(source, "function RoadPieces.coversModel", 1, true))
		local finish = assert(string.find(source, "-- `notify(dirtyCells)`", start, true))
		local api = assert(loadstring(string.sub(source, start, finish - 1)))
		setfenv(api, env)()
		local removeStart = assert(string.find(source, "\tfor _, id in removed do", 1, true))
		local removeEnd = assert(string.find(source, "\tfor _, seg in dirtySegs do", removeStart, true))
		local remove = assert(loadstring("local removed = {7}; local dirty = {};\n" .. string.sub(source, removeStart, removeEnd - 1)))
		setfenv(remove, env)
		local nodeStart = assert(string.find(source, "local function buildNode", 1, true))
		local nodeEnd = assert(string.find(source, "-- == Topology changes", nodeStart, true))
		local node = assert(loadstring(string.sub(source, nodeStart, nodeEnd - 1) .. "\nreturn buildNode"))
		setfenv(node, env)
		local cellsStart = assert(string.find(source, "function RoadPieces.affectedSegments", 1, true))
		local cellsEnd = assert(string.find(source, "function RoadPieces.specsForCell", cellsStart, true))
		local cellsApi = assert(loadstring(string.sub(source, cellsStart, cellsEnd - 1)))
		env._pieces = { s7 = { cell = "body" }, n8 = { cell = "junction" }, s9 = { cell = "body" } }
		env._byCell = { body = { s7 = true, s9 = true }, junction = { n8 = true } }
		env.drawable = function(seg) return seg.vMode ~= "Elevated" end
		setfenv(cellsApi, env)()
		env.remove = remove
		env.node = node()
		return env
	end

	describe("road prediction coverage", function()
		it("keeps deleted server road geometry hidden until its model leaves", function()
			local env = harness(script.Parent.Source)
			env.remove()
			assert(env.RoadPieces.coversModel("Segment_7"), "deleted server road reappears during replication")
			env.RoadPieces.releaseModel("Segment_7")
			assert(not env.RoadPieces.coversModel("Segment_7"), "removed model coverage leaks")
		end)

		it("keeps a removed node hidden, but returns unsupported nodes to their server renderer", function()
			local env = harness(script.Parent.Source)
			env.node(8, {})
			assert(env.RoadPieces.coversModel("Junction_8"), "removed server junction reappears")
			env._ends[8] = { {} }
			env.node(8, {})
			assert(not env.RoadPieces.coversModel("Junction_8"), "unsupported junction lost its renderer")
		end)

		it("keeps a predicted removal hidden across server model stream out and in", function()
			local env = harness(script.Parent.Source)
			env._predictions[1] = { [7] = false }
			env.remove()
			env.RoadPieces.releaseModel("Segment_7")
			assert(env.RoadPieces.coversModel("Segment_7"), "streamed server model bypasses predicted removal")
			env._predictions[1] = nil
			assert(not env.RoadPieces.coversModel("Segment_7"), "rejected prediction remains hidden")
		end)

		it("keeps removed-node predictions hidden across stream-out and releases overlapping references",function()
			local env=harness(script.Parent.Source)
			env.RoadPieces.setPrediction(1,{[7]=false})
			env.RoadPieces.setPrediction(2,{[7]=false})
			env.RoadPieces.releaseModel("Junction_8")
			assert(env.RoadPieces.coversModel("Junction_8"),"streamed junction bypassed predicted removal")
			env.RoadPieces.setPrediction(1,nil)
			assert(env.RoadPieces.coversModel("Junction_8"),"one rejection released another edit's removed-node coverage")
			env.RoadPieces.setPrediction(2,nil)
			env.RoadPieces.releaseModel("Junction_8")
			assert(not env.RoadPieces.coversModel("Junction_8"),"finished removed-node coverage leaked")
			env.RoadPieces.setPrediction(3,{[7]=false})
			env._ends[8]={{}}
			assert(not env.RoadPieces.coversModel("Junction_8"),"prediction hid a live unsupported junction")
		end)
		it("collects direct junction neighbors once and rejects oversized previews", function()
			local env = harness(script.Parent.Source)
			env._seen[7] = { id=7,startNode=8,endNode=10 }
			env._seen[9] = { id=9,startNode=8,endNode=11 }
			env._seen[12] = { id=12,startNode=11,endNode=13 }
			env._ends[8] = { {seg=env._seen[7]}, {seg=env._seen[9]} }
			env._ends[10] = { {seg=env._seen[7]} }
			env._ends[11] = { {seg=env._seen[9]}, {seg=env._seen[12]} }
			local ids=env.RoadPieces.affectedSegments({7},2)
			assert(ids and #ids==2 and table.find(ids,7) and table.find(ids,9),"direct changed junction neighbor missing")
			assert(not table.find(ids,12),"preview traversal spread beyond adjacent roads")
			assert(env.RoadPieces.affectedSegments({7},1)==nil,"preview neighbor collection exceeded its bound")
		end)
		it("captures a road body and junction cells without unrelated cells", function()
			local env = harness(script.Parent.Source)
			env._seen[7] = { id = 7, startNode = 8, endNode = 10 }
			local cells = env.RoadPieces.cellsForSegments({ 7 })
			assert(cells.body and cells.junction, "affected road or junction cell missed")
			assert(not cells.unrelated, "unrelated cell included")
		end)

		it("deduplicates temporary road views and rejects their capacity overflow", function()
			local env = harness(script.Parent.Source)
			env._seen[7] = { id = 7, startNode = 8, endNode = 10 }
			env._seen[9] = { id = 9, startNode = 8, endNode = 11 }
			env._ends[8] = { { seg = env._seen[7] }, { seg = env._seen[9] } }
			local cells = { body = true, junction = true }
			local segments = env.RoadPieces.segmentsForCells(cells, 2)
			assert(segments and #segments == 2, "temporary view repeated a road at its junction")
			assert(env.RoadPieces.segmentsForCells(cells, 1) == nil, "temporary view exceeded its capacity")
			env._seen[9].vMode = "Elevated"
			assert(env.RoadPieces.segmentsForCells(cells, 2) == nil, "temporary view claimed unsupported geometry")
		end)

		it("does not release coverage for a replacement model of a live road", function()
			local env = harness(script.Parent.Source)
			env._seen[7] = {}
			env.RoadPieces.releaseModel("Segment_7")
			assert(env.RoadPieces.coversModel("Segment_7"), "live replacement model duplicates client geometry")
		end)
	end)
	describe("fork shift indexes", function()

		it("refreshes fork indexes through the actual topology rebuild path", function()
			local source = script.Parent.Source
			local env = setmetatable({
				_seen = {}, _ends = {}, _plans = {}, _shiftNodes = {}, _forkNodes = {},
				_shifts = {}, _covered = {}, REBUILD_SLICE_MIN_ITEMS = 64, REBUILD_SLICE = .004,
				buildSegment = function() end, buildNode = function() end,
				setPiece = function() end, flushGround = function() end,
			}, { __index = getfenv() })
			env.solveNode = function(id)
				local ends = env._ends[id]
				if not ends then return nil end
				return { kind = if id == 1 then "fork" else "end", ends = ends, shift = if id == 1 then { 2 } else nil }
			end
			local carried = false
			env.RoadJunctionSolver = { carryShifts = function(nodes, roots)
				assert(roots[1] and nodes[2], "topology rebuild did not refresh cached fork/node indexes")
				carried = true
				return {}
			end }
			local helperStart = assert(source:find("local function updatePlan", 1, true))
			local helperEnd = assert(source:find("-- How one road end", helperStart, true))
			local helper = assert(loadstring(source:sub(helperStart, helperEnd - 1) .. "\nreturn updatePlan"))
			setfenv(helper, env);env.updatePlan = helper()
			local start = assert(source:find("local function rebuildFrom", 1, true))
			local finish = assert(source:find("-- One pass at a time.", start, true))
			local loader = assert(loadstring(source:sub(start, finish - 1) .. "\nreturn rebuildFrom"))
			setfenv(loader, env);local rebuild = loader()
			rebuild({ { id = 7, startNode = 1, endNode = 2 } })
			assert(carried, "topology rebuild skipped shift propagation")
		end)
		local function fixture()
			local source = script.Parent.Source
			local start = assert(string.find(source, "local function updatePlan", 1, true))
			local finish = assert(string.find(source, "-- How one road end", start, true))
			local plans = {}
			local env = setmetatable({
				_plans = {}, _shiftNodes = {}, _forkNodes = {},
				solveNode = function(id) return plans[id] end,
			}, { __index = getfenv() })
			local fn = assert(loadstring(string.sub(source, start, finish - 1) .. "\nreturn updatePlan"))
			setfenv(fn, env)
			return { update = fn(), env = env, plans = plans }
		end
		it("retains every fork when another node changes and removes obsolete fork roots", function()
			local f = fixture()
			f.plans[1] = { kind = "fork", shift = { [1] = 2 }, ends = {} }
			f.plans[2] = { kind = "straight", ends = {} }
			f.update(1);f.update(2)
			assert(f.env._forkNodes[1] and not f.env._forkNodes[2], "shift roots include unrelated nodes or omit a fork")
			f.plans[2] = { kind = "end", ends = {} };f.update(2)
			assert(f.env._forkNodes[1], "neighbor edit lost an untouched fork")
			f.plans[1] = { kind = "straight", ends = {} };f.update(1)
			assert(not f.env._forkNodes[1] and f.env._shiftNodes[1], "former fork remains a shift root")
			f.plans[1] = nil;f.update(1)
			assert(not f.env._shiftNodes[1] and not f.env._plans[1], "deleted node remains in shift traversal")
		end)
	end)

end
