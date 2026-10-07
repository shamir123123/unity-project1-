--!strict
return function()
	local function fixture()
		local history = assert(loadstring(script.Parent.Source))()
		local segments: { [number]: any } = {}
		local function restore(snapshot)
			table.clear(segments)
			for _, entry in snapshot do segments[entry.id] = table.clone(entry) end
		end
		history.init(function() return segments end, restore)
		local function add(id: number, x: number)
			local p = Vector3.new(x, 0, 0)
			segments[id] = { id = id, p0 = p, p1 = p, p2 = p, p3 = p + Vector3.xAxis, roadType = "NarrowRoad" }
		end
		return history, segments, add
	end

	describe("road snapshot contracts", function()
		it("keeps immutable snapshots isolated from subsequent segment edits and consumers", function()
			local history, segments, add = fixture()
			add(1, 0)
			local before = history.capture()
			assert(not pcall(function() before[1].roadType = "consumer mutation" end), "shared undo record remained mutable")
			segments[1].roadType = "LocalRoad"
			local after = history.capture()
			assert(before[1].roadType == "NarrowRoad" and after[1].roadType == "LocalRoad", "old undo data changed")
		end)
		it("preserves canonical ordering across a small move, insertion and removal", function()
			local history, segments, add = fixture()
			for id = 1, 20 do add(id, id) end
			local original = history.capture()
			local p = Vector3.new(-1, 0, 0)
			segments[20].p0 = p;segments[20].p3 = p + Vector3.xAxis
			segments[5] = nil
			add(21, 5.5)
			local updated = history.capture()
			assert(#updated == 20 and updated[1].id == 20 and updated[6].id == 21, "canonical merge order changed")
			assert(original[20].id == 20 and original[20].p0.X == 20, "sorting corrupted older snapshot")
		end)
		it("captures source fields that change from nil, including lane and corner settings", function()
			local history, segments, add = fixture()
			add(1, 0)
			local values = {
				name = "Main Street", vMode = "Elevated", constSlope = true,
				isRoundabout = true, roundaboutId = 5, roundaboutCenter = Vector3.one,
				roundaboutRadius = 12, roundaboutPreset = "Default",
				startCorner = 3, endCorner = 4, startOffset = 2, endOffset = 5,
				startFlat = true, endFlat = true, startLane = Vector3.one, endLane = Vector3.zero,
			}
			for field, value in values do
				local old = history.capture()
				segments[1][field] = value
				local new = history.capture()
				assert(new[1][field] == value and old[1][field] == nil, "changed source field missing: " .. field)
			end
		end)
		it("preserves undo, redo and city reset after sharing unchanged records", function()
			local history, segments, add = fixture()
			add(1, 0);add(2, 10)
			history.push(history.capture())
			segments[1].roadType = "LocalRoad"
			assert(history.undo() and segments[1].roadType == "NarrowRoad", "undo failed")
			assert(history.redo() and segments[1].roadType == "LocalRoad", "redo failed")
			history.clear();table.clear(segments);add(3, -10)
			local snapshot = history.capture()
			assert(#snapshot == 1 and snapshot[1].id == 3 and not history.undo(), "old city remained in cache or history")
		end)
	end)
end
