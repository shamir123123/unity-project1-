--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local terrainStub = { setGroundCap = function() end, markDirty = function() end, request = function() end }
local settingsStub = { get = function() return 1 end, onChanged = function() end }
H.patches["StarterPlayer.StarterPlayerScripts.World.RoadMeshView"] = function(src)
	src = string.gsub(src, "local SETTLE_QUIET = 4", "local SETTLE_QUIET = 0.3")
	src = string.gsub(src, "local function rebuild%(key: string, live: boolean%?%)\n", "local function rebuild(key: string, live: boolean?)\n\tprint('rebuild', key, live, _cells[key] and _cells[key].liveTris)\n")
	return (string.gsub(src, "\nreturn RoadMeshView%s*$", "\nRoadMeshView._live = function() local n = 0 for k, st in _cells do if st.liveTris > 0 then print('  live cell', k, st.liveTris, os.clock() - st.editedAt) end n += st.liveTris end return _liveTris, n end\nreturn RoadMeshView\n"))
end
H.boot({ server = false, overrides = {
	["ReplicatedStorage.Terrain.TerrainMeshView"] = terrainStub,
	["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub,
} })
H.quietWarn = false
local City = require("./city")
local V3 = H.roblox.Vector3
local ws = H.game:GetService("Workspace")
local city = H.rbx.Instance.new("Folder"); city.Name = "_City"; city.Parent = ws
local roads = H.rbx.Instance.new("Folder"); roads.Name = "Roads"; roads.Parent = city
ws:SetAttribute("RoadMeshV2", true)
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local RoadMeshView = H.require("StarterPlayer.StarterPlayerScripts.World.RoadMeshView")
local N = 4
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
DataCache.SetSegments(City.records(net))
RoadMeshView.Start()
local function idle() local t = os.clock(); H.task.wait(); while not RoadMeshView.isIdle() and os.clock() - t < 30 do H.task.wait() end end
idle()
print("---- edits")
for i, pair in { { V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128) }, { V3.new(-128, 10, -128), V3.new(0, 10, 0) } } do
	local p0, p1, p2, p3 = City.straight(pair[1], pair[2])
	net:addSegment(p0, p1, p2, p3, "CollectorRoad")
	DataCache.ApplySegmentsDelta(City.delta(net))
	idle()
	print("after edit", i, RoadMeshView._live())
end
print("---- wait for settle")
local t = os.clock()
while os.clock() - t < 3 do H.task.wait(0.05) end
idle()
print("after settle", RoadMeshView._live())
process.exit(0)
