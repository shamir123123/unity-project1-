--!nocheck
-- RoadNavigationGraph lane-change gates: after every edit (and lane-change rule change) the
-- incremental rebuild must give the same gates and per-edge lane-change index as the baseline.
-- Usage (from tools/harness): lune run test_gates_equiv.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
if process.args[1] == "orig" then
	H.patches["ReplicatedStorage.Road.RoadNavigationGraph"] = function()
		return process.exec("git", { "show", "5858734:src/ReplicatedStorage.Road.RoadNavigationGraph.luau" }).stdout
	end
end
H.boot({ server = true })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local Nav = H.require("ReplicatedStorage.Road.RoadNavigationGraph")
local Catalog = H.require("ReplicatedStorage.Road.RoadTypeCatalog")
local net = RoadNetwork.new()
City.grid(net, 8, 128, "AvenueConcrete")
net:consumeChanges()
local nav = Nav.new(function(seg) return Catalog.getOrDefault(seg.roadType).isRail ~= true end)
local rules = {}
nav:Rebuild(net, {}, rules)
local state = 99
local function rnd(lo, hi) state = (state * 1103515245 + 12345) % 2147483648; return lo + (hi - lo) * (state / 2147483648) end
local function digest()
	local rows = {}
	for _, g in nav:GetLaneChangeGateData() do
		local c = {}
		for _, k in g.connections do table.insert(c, k.fromEdgeId .. ">" .. k.toEdgeId .. "=" .. tostring(k.allowed)) end
		local d = {}
		for _, k in g.dots do table.insert(d, string.format("%s:%s:%.4f,%.4f,%.4f", k.edgeId, k.kind, k.position.X, k.position.Y, k.position.Z)) end
		table.insert(rows, string.format("G%s|%d|%s|%d|%d|%.4f|%.4f|%s|%s", g.id, g.segmentId, g.direction, g.gateIndex, g.pairIndex, g.startDistance, g.endDistance, table.concat(d, ";"), table.concat(c, ";")))
	end
	for _, e in nav:GetEdges() do
		local b = {}
		for _, x in nav:GetLaneChangesForEdge(e.id) do
			local p = x.points[#x.points]
			table.insert(b, string.format("%s>%s@%.4f,%.4f", x.fromEdgeId, x.toEdgeId, p.X, p.Z))
		end
		if #b > 0 then table.insert(rows, "E" .. e.id .. "|" .. table.concat(b, ";")) end
	end
	-- the spatial index, cell by cell, in bucket order
	for key, bucket in nav._spatial do
		local b = {}
		for _, x in bucket do table.insert(b, x.edgeId .. "#" .. x.index) end
		table.insert(rows, "C" .. key .. "|" .. table.concat(b, ";"))
	end
	table.sort(rows)
	local h = 0
	for _, r in rows do for k = 1, #r do h = (h * 31 + string.byte(r, k)) % 2147483647 end end
	return h, #rows
end
local out = {}
local t = 0
for step = 1, 24 do
	if step % 6 == 0 then
		-- a lane-change rule edit: forbid one connection of some gate, re-allow an older one
		local gates = nav:GetLaneChangeGateData()
		if #gates > 0 then
			local g = gates[(step * 7) % #gates + 1]
			local c = g.connections[2]
			rules[nav:LaneChangeRuleKey(g.id, c.fromEdgeId, c.toEdgeId)] = false
		end
		-- applied through the incremental path with nothing else dirty: every road reuses its
		-- gates and must still pick the new rule up
		local t0 = os.clock()
		nav:RebuildSegments(net, {}, {}, {}, rules)
		t += os.clock() - t0
	else
		local a = V3.new(rnd(-500, 500), 10, rnd(-500, 500))
		local ang = rnd(0, math.pi * 2)
		local len = rnd(60, 500)
		local b = a + V3.new(math.cos(ang) * len, 0, math.sin(ang) * len)
		pcall(function() net:addSegment(a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b, if step % 2 == 0 then "AvenueConcrete" else "CollectorRoad") end)
		local dirtySeg, dirtyNode, deadNode = net:consumeChanges()
		local nodes = net:getNodes()
		for nid in dirtyNode do local n = nodes[nid]; if n then for _, sid in n.segments do dirtySeg[sid] = true end end end
		local removed = {}
		for sid in dirtySeg do if not net:getSegment(sid) then removed[sid] = true end end
		local t0 = os.clock()
		nav:RebuildSegments(net, dirtySeg, removed, {}, rules)
		t += os.clock() - t0
	end
	local h, n = digest()
	table.insert(out, tostring(h))
end
local h, n = digest()
print(string.format("24 steps, final %d rows; nav rebuild time %.0f ms; per-step digests %s", n, t * 1000, table.concat(out, ",")))
process.exit(0)
