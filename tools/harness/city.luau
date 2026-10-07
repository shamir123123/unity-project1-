--!nocheck
-- Synthetic city: a grid of plain two-lane streets laid through the real RoadNetwork, the way
-- RoadService lays them (one addSegment per block edge, welded at the nodes).
local H = require("./loader")
local V3 = H.roblox.Vector3
local City = {}

local function straight(a, b)
	return a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b
end
City.straight = straight

-- n x n blocks of `spacing` studs, centred on `origin`; avenues every `avenueEvery` lines.
function City.grid(network, n: number, spacing: number, roadType: string, origin)
	origin = origin or V3.new(0, 10, 0)
	local half = n * spacing * 0.5
	local count = 0
	for i = 0, n do
		for j = 0, n - 1 do
			-- along X
			local a = origin + V3.new(-half + j * spacing, 0, -half + i * spacing)
			local b = a + V3.new(spacing, 0, 0)
			network:addSegment(a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b, roadType)
			-- along Z
			local c = origin + V3.new(-half + i * spacing, 0, -half + j * spacing)
			local d = c + V3.new(0, 0, spacing)
			network:addSegment(c, c:Lerp(d, 1 / 3), c:Lerp(d, 2 / 3), d, roadType)
			count += 2
		end
	end
	return count
end

-- The client record RoadService.applyChanges ships for a segment.
function City.record(s)
	return {
		id = s.id, p0 = s.p0, p1 = s.p1, p2 = s.p2, p3 = s.p3, roadType = s.roadType, name = s.name,
		startNode = s.startNode, endNode = s.endNode, isRoundabout = s.isRoundabout, isArc = s.isArc,
		vMode = s.vMode, roundaboutId = s.roundaboutId, roundaboutCenter = s.roundaboutCenter,
		roundaboutRadius = s.roundaboutRadius, startCorner = s.startCorner, endCorner = s.endCorner,
		startOffset = s.startOffset, endOffset = s.endOffset, startFlat = s.startFlat, endFlat = s.endFlat,
		startLane = s.startLane, endLane = s.endLane,
	}
end

function City.records(network)
	local out = {}
	for _, s in network:getSegments() do table.insert(out, City.record(s)) end
	return out
end

-- What applyChanges would send for the edit just made: every dirty segment plus every segment
-- at a dirty node (the cascade), and the removed ids.
function City.delta(network)
	local dirtySeg, dirtyNode = network:consumeChanges()
	local nodes = network:getNodes()
	for nid in dirtyNode do
		local node = nodes[nid]
		if node then for _, sid in node.segments do dirtySeg[sid] = true end end
	end
	local changed, removed = {}, {}
	for sid in dirtySeg do
		local s = network:getSegment(sid)
		if s then table.insert(changed, City.record(s)) else table.insert(removed, sid) end
	end
	return { changed = changed, removed = removed }
end

return City
