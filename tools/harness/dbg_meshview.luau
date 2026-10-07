--!nocheck
local H = require("./loader")
local stdio = require("@lune/stdio")
local print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end stdio.ewrite(table.concat(t, " ") .. "\n") end
local terrainStub = { setGroundCap = function() end, markDirty = function() end, request = function() end }
local settingsStub = { get = function() return 1 end, onChanged = function() end }
H.patches["StarterPlayer.StarterPlayerScripts.World.RoadMeshView"] = function(src)
	return (string.gsub(src, "\nreturn RoadMeshView%s*$", "\nRoadMeshView._dbg = function() return _scheduled, _busyJobs, #_bakeQueue, _pumping end\nreturn RoadMeshView\n"))
end
H.boot({ server = false, overrides = {
	["ReplicatedStorage.Terrain.TerrainMeshView"] = terrainStub,
	["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub,
} })
local City = require("./city")
local ws = H.game:GetService("Workspace")
local city = H.rbx.Instance.new("Folder"); city.Name = "_City"; city.Parent = ws
local roads = H.rbx.Instance.new("Folder"); roads.Name = "Roads"; roads.Parent = city
ws:SetAttribute("RoadMeshV2", true)
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
print("requiring RoadMeshView")
local RoadMeshView = H.require("StarterPlayer.StarterPlayerScripts.World.RoadMeshView")
local RoadPieces = H.require("StarterPlayer.StarterPlayerScripts.World.RoadPieces")
print("required")
local net = RoadNetwork.new()
City.grid(net, 2, 128, "CollectorRoad")
net:consumeChanges()
DataCache.SetSegments(City.records(net))
print("start")
RoadMeshView.Start()
print("started")
for i = 1, 20 do
	H.task.wait(0.1)
	print(i, RoadMeshView._dbg(), RoadPieces.isIdle(), H.emStats.bakes, H.emStats.parts)
end
