--!strict
return function()
	it("warms restored road history after integrity repair without creating an undo entry", function()
		local source = script.Parent.Source
		local start = assert(source:find("function RoadService.restoreRoads", 1, true))
		local finish = assert(source:find("-- Audit the road network", start, true))
		local history = assert(loadstring(script.Parent.Parent.RoadHistoryService.Source))()
		local segments: { [number]: any } = {}
		local restored, verified, cleared, captured = false, false, false, 0
		history.init(function() return segments end, function() error("restore created a synthetic undo entry") end)
		local originalClear, originalCapture = history.clear, history.capture
		local env = setmetatable({
			RoadService = { verifyIntegrity = function()
				assert(restored and cleared, "history warmed before restore state was final")
				segments[1].name = "Repaired street";verified = true
			end },
			_network = { getSegments = function() return segments end },
			RoadSerializer = { deserialize = function(entries) return entries end },
			RoadHistoryService = {
				clear = function() originalClear();cleared = true end,
				capture = function()
					assert(verified, "history warmed before integrity repair")
					captured += 1;return originalCapture()
				end,
			},
			applySnapshot = function(entries)
				table.clear(segments)
				for _, entry in entries do segments[entry.id] = entry end
				restored = true
			end,
		}, { __index = getfenv() })
		local loader = assert(loadstring(source:sub(start, finish - 1)))
		setfenv(loader, env);loader()
		local p = Vector3.zero
		env.RoadService.restoreRoads({ { id = 1, p0 = p, p1 = p, p2 = p, p3 = Vector3.xAxis, roadType = "NarrowRoad" } })
		assert(captured == 1, "restored road cache remained cold at city entry")
		assert(not history.undo(), "warming history created an undo step")
		local snapshot = history.capture()
		assert(snapshot[1].name == "Repaired street", "warm cache missed the final integrity repair")
	end)
end
