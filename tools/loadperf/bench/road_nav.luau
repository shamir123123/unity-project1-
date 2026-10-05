-- Big street grid through the real RoadNetwork, then a full nav-graph rebuild (what the
-- deferred road render runs, unyielded, after a city restore).
local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local Vector3 = require("@lune/roblox").Vector3
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = process.args[2] or "../bundle_after" })
local RS = rt.game:GetService("ReplicatedStorage")
local RoadNetwork = rt.require(RS.Road.RoadNetwork)
local RoadNavigationGraph = rt.require(RS.Road.RoadNavigationGraph)
local N = tonumber(process.args[1]) or 20
local spacing = 112
local net = RoadNetwork.new()
local t0 = os.clock()
local count = 0
local function seg(x0, z0, x1, z1, major)
	local p0, p3 = Vector3.new(x0, 6, z0), Vector3.new(x1, 6, z1)
	local p1 = p0:Lerp(p3, 1 / 3)
	local p2 = p0:Lerp(p3, 2 / 3)
	net:_directAddSegment(p0, p1, p2, p3, if major then "CollectorRoad" else "NarrowRoad", { weld = 0.25 })
	count += 1
end
local x0 = -N * spacing / 2
for i = 0, N do
	for j = 0, N - 1 do
		seg(x0 + i * spacing, x0 + j * spacing, x0 + i * spacing, x0 + (j + 1) * spacing, i % 5 == 0)
		seg(x0 + j * spacing, x0 + i * spacing, x0 + (j + 1) * spacing, x0 + i * spacing, i % 5 == 0)
	end
end
local tAdd = os.clock() - t0
net:consumeChanges()
local nodes = 0
for _ in net:getNodes() do nodes += 1 end
local g = RoadNavigationGraph.new()
t0 = os.clock()
local ok, err = pcall(function() g:Rebuild(net, {}, {}) end)
local tNav = os.clock() - t0
local edges = 0
for _ in g:GetEdges() do edges += 1 end
print(string.format("grid %dx%d: %d segments, %d nodes | network add %.2fs | nav Rebuild %.2fs (%s) -> %d edges",
	N, N, count, nodes, tAdd, tNav, ok and "ok" or tostring(err):sub(1, 120), edges))
