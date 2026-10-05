local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local Vector3 = require("@lune/roblox").Vector3
local N = tonumber(process.args[1]) or 40
local bundle = process.args[2] or "../bundle_after"
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = bundle })
local RS = rt.game:GetService("ReplicatedStorage")
local RoadNetwork = rt.require(RS.Road.RoadNetwork)
local RoadNavigationGraph = rt.require(RS.Road.RoadNavigationGraph)
local spacing = 112
local entries = {}
local function seg(x0, z0, x1, z1, t)
	local p0, p3 = Vector3.new(x0, 6, z0), Vector3.new(x1, 6, z1)
	table.insert(entries, { p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3, t })
end
local x0 = -N * spacing / 2
for i = 0, N do
	for j = 0, N - 1 do
		seg(x0 + i * spacing, x0 + j * spacing, x0 + i * spacing, x0 + (j + 1) * spacing, if i % 5 == 0 then "CollectorRoad" else "NarrowRoad")
		seg(x0 + j * spacing, x0 + i * spacing, x0 + (j + 1) * spacing, x0 + i * spacing, if i % 5 == 0 then "CollectorRoad" else "NarrowRoad")
	end
end
-- a few diagonal roads crossing blocks with no junction (legacy damage the audit must find)
for k = 0, math.floor(N / 4) do
	local a = x0 + 13 + k * spacing * 3
	seg(a, x0 + 17, a + spacing * 1.7, x0 + 17 + spacing * 1.3, "NarrowRoad")
end
local net = RoadNetwork.new()
local t0 = os.clock()
if net.beginBulkWeld then net:beginBulkWeld() end
for _, e in entries do pcall(function() net:_directAddSegment(e[1], e[2], e[3], e[4], e[5], { weld = 0.25 }) end) end
if net.endBulkWeld then net:endBulkWeld() end
local tAdd = os.clock() - t0
net:consumeChanges()
local nodes, sig = 0, {}
for _ in net:getNodes() do nodes += 1 end
local ids = {}
for id in net:getSegments() do table.insert(ids, id) end
table.sort(ids)
for _, id in ids do
	local s = net:getSegments()[id]
	local a, b = net:getNodes()[s.startNode].position, net:getNodes()[s.endNode].position
	table.insert(sig, string.format("%d:%.2f,%.2f>%.2f,%.2f", id, a.X, a.Z, b.X, b.Z))
end
t0 = os.clock()
local rep = net:audit(false)
local tAudit = os.clock() - t0
local g = RoadNavigationGraph.new()
t0 = os.clock()
g:Rebuild(net, {}, {})
local tNav = os.clock() - t0
-- fingerprint of topology
local h = 0
for _, s in sig do for c = 1, #s, 7 do h = (h * 31 + string.byte(s, c)) % 2147483647 end end
print(string.format("%s N=%d segs=%d nodes=%d | add %.2fs | audit %.2fs (crossings=%d dup=%d pins=%d) | nav %.2fs | topo=%d",
	bundle:match("bundle_(%w+)"), N, #ids, nodes, tAdd, tAudit, rep.crossingsResolved, rep.duplicates, rep.endpointPins, tNav, h))
