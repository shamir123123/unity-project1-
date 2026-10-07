--!nocheck
-- Server render cost: RoadSceneRenderer.renderSegment / refreshNode for what one placement dirties,
-- plus the incremental nav rebuild, on the synthetic grid city.
local H = require("./loader")
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 12
local flat = function() return 10 end
local terrainData = setmetatable({ getSurfaceY = flat, getNaturalSurfaceY = flat, getHeightAt = flat }, { __index = function() return function() return 10 end end })
local terrainGrade = setmetatable({}, { __index = function() return function() end end })
H.boot({ server = true, overrides = {
	["ServerScriptService.Services.Terrain.TerrainDataService"] = terrainData,
	["ServerScriptService.Services.Terrain.TerrainGradeService"] = terrainGrade,
} })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local RoadNavigationGraph = H.require("ReplicatedStorage.Road.RoadNavigationGraph")
local RoadSceneRenderer = H.require("ReplicatedStorage.Road.RoadSceneRenderer")
local RoadTypeCatalog = H.require("ReplicatedStorage.Road.RoadTypeCatalog")
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
local nav = RoadNavigationGraph.new(function(seg) return RoadTypeCatalog.getOrDefault(seg.roadType).isRail ~= true end)
nav:Rebuild(net, {}, {})
RoadSceneRenderer.init(net, nav, { getSurfaceY = flat })
local t = os.clock()
local nSeg, nNode = 0, 0
for _, s in net:getSegments() do RoadSceneRenderer.renderSegment(s); nSeg += 1 end
for id in net:getNodes() do RoadSceneRenderer.refreshNode(id); nNode += 1 end
local full = os.clock() - t
print(string.format("full render: %d segs + %d nodes in %.0f ms (%.2f ms/item)", nSeg, nNode, full * 1000, full * 1000 / (nSeg + nNode)))
net:consumeChanges()

local a, b, c, d = City.straight(V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128))
local s = net:addSegment(a, b, c, d, "CollectorRoad")
local dirtySeg, dirtyNode, deadNode = net:consumeChanges()
local nodes = net:getNodes()
for nid in dirtyNode do local node = nodes[nid]; if node then for _, sid in node.segments do dirtySeg[sid] = true end end end
local segs, ns = {}, {}
for sid in dirtySeg do local sg = net:getSegment(sid); if sg then table.insert(segs, sg) end end
for nid in dirtyNode do table.insert(ns, nid) end
t = os.clock()
nav:RebuildSegments(net, dirtySeg, {}, {}, {})
local navT = os.clock() - t
t = os.clock()
for _, sg in segs do RoadSceneRenderer.renderSegment(sg) end
for _, nid in ns do if nodes[nid] then RoadSceneRenderer.refreshNode(nid) end end
local edit = os.clock() - t
print(string.format("one placement: nav rebuild %.0f ms; render %d segs + %d nodes in %.0f ms", navT * 1000, #segs, #ns, edit * 1000))
