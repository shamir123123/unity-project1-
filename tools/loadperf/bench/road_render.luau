local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local Vector3 = require("@lune/roblox").Vector3
local N = tonumber(process.args[1]) or 12
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = process.args[2] or "../bundle_after", services = {
	RunService = { IsServer = function() return true end, IsClient = function() return false end, IsStudio = function() return true end,
		Heartbeat = { Connect = function() return { Disconnect = function() end } end, Wait = function() return 0 end } },
} })
local RS = rt.game:GetService("ReplicatedStorage")
local RoadNetwork = rt.require(RS.Road.RoadNetwork)
local RoadNavigationGraph = rt.require(RS.Road.RoadNavigationGraph)
local RSR = rt.require(RS.Road.RoadSceneRenderer)
local net = RoadNetwork.new()
local spacing = 112
local x0 = -N * spacing / 2
if net.beginBulkWeld then net:beginBulkWeld() end
for i = 0, N do
	for j = 0, N - 1 do
		for _, e in { { x0 + i * spacing, x0 + j * spacing, x0 + i * spacing, x0 + (j + 1) * spacing }, { x0 + j * spacing, x0 + i * spacing, x0 + (j + 1) * spacing, x0 + i * spacing } } do
			local p0, p3 = Vector3.new(e[1], 6, e[2]), Vector3.new(e[3], 6, e[4])
			net:_directAddSegment(p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3, if i % 5 == 0 then "CollectorRoad" else "NarrowRoad", { weld = 0.25 })
		end
	end
end
if net.endBulkWeld then net:endBulkWeld() end
net:consumeChanges()
local g = RoadNavigationGraph.new()
g:Rebuild(net, {}, {})
local ok, err = pcall(RSR.init, net, g, { getSurfaceY = function() return 6 end })
print("init", ok, ok and "" or tostring(err):sub(1, 200))
local segs, nodes = {}, {}
for _, s in net:getSegments() do table.insert(segs, s) end
for nid in net:getNodes() do table.insert(nodes, nid) end
local t0 = os.clock()
local fails = 0
local firstErr
for _, s in segs do local ok2, e2 = pcall(RSR.renderSegment, s); if not ok2 then fails += 1; firstErr = firstErr or e2 end end
local tSeg = os.clock() - t0
t0 = os.clock()
for _, nid in nodes do local ok2, e2 = pcall(RSR.refreshNode, nid); if not ok2 then fails += 1; firstErr = firstErr or e2 end end
local tNode = os.clock() - t0
print(string.format("N=%d: %d segments render %.2fs (%.2f ms each), %d nodes refresh %.2fs (%.2f ms each), fails=%d %s",
	N, #segs, tSeg, tSeg / #segs * 1000, #nodes, tNode, tNode / #nodes * 1000, fails, firstErr and tostring(firstErr):sub(1, 160) or ""))
