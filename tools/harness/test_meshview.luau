--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local terrainStub = { setGroundCap = function() end, markDirty = function() end, request = function() end }
local settingsStub = { get = function() return 1 end, onChanged = function() end }
H.patches["StarterPlayer.StarterPlayerScripts.World.RoadMeshView"] = function(src)
	src = string.gsub(src, "local SETTLE_QUIET = 4", "local SETTLE_QUIET = 0.3")
	return (string.gsub(src, "\nreturn RoadMeshView%s*$", "\nRoadMeshView._live = function() local n = 0 for _, st in _cells do n += st.liveTris end return _liveTris, n, _liveMeshes end\nreturn RoadMeshView\n"))
end
H.boot({ server = false, overrides = {
	["ReplicatedStorage.Terrain.TerrainMeshView"] = terrainStub,
	["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub,
} })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local ws = H.game:GetService("Workspace")
local city = H.rbx.Instance.new("Folder"); city.Name = "_City"; city.Parent = ws
local roads = H.rbx.Instance.new("Folder"); roads.Name = "Roads"; roads.Parent = city
ws:SetAttribute("RoadMeshV2", true)
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local RoadMeshView = H.require("StarterPlayer.StarterPlayerScripts.World.RoadMeshView")
local RoadPieces = H.require("StarterPlayer.StarterPlayerScripts.World.RoadPieces")
local st = H.emStats
local N = 8
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
DataCache.SetSegments(City.records(net))
RoadMeshView.Start()
local function idle(maxWait)
	local t = os.clock()
	H.task.wait()
	while not RoadMeshView.isIdle() and os.clock() - t < (maxWait or 30) do H.task.wait() end
end
idle()
print(string.format("LOAD: static bakes %d, live meshes %d, liveTris %s", st.bakes, st.fixed, tostring((RoadMeshView._live()))))
local b0, f0 = st.bakes, st.fixed
local function edit(label, a, b, t)
	local p0, p1, p2, p3 = City.straight(a, b)
	net:addSegment(p0, p1, p2, p3, t or "CollectorRoad")
	DataCache.ApplySegmentsDelta(City.delta(net))
	local t0 = os.clock()
	idle()
	local lt, sum = RoadMeshView._live()
	print(string.format("%s: +%d static bakes, +%d live meshes, liveTris=%d (cells sum %d), alive EMs=%d", label, st.bakes - b0, st.fixed - f0, lt, sum, st.fixedAlive))
	b0, f0 = st.bakes, st.fixed
end
edit("edit 1", V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128))
edit("edit 2", V3.new(-256, 10, -256), V3.new(0, 10, 0))
edit("edit 3", V3.new(-N * 64 - 10, 10, 64), V3.new(-N * 64 - 400, 10, 64), "AvenueConcrete")
edit("edit 4", V3.new(N * 64 + 10, 10, -64), V3.new(N * 64 + 400, 10, -64), "AvenueConcrete")
edit("edit 5", V3.new(-192, 10, 192), V3.new(-64, 10, 320))
for k = 1, 6 do
	edit("burst " .. k, V3.new(-N * 64 + k * 20, 10, N * 64 + 40), V3.new(-N * 64 + k * 20, 10, N * 64 + 300))
end
print("live meshes now", select(3, RoadMeshView._live()))
-- server models for covered pieces arriving: must not re-bake
local before = st.bakes + st.fixed
for _, s in net:getSegments() do
	local m = H.rbx.Instance.new("Model"); m.Name = "Segment_" .. s.id
	local sv = H.rbx.Instance.new("StringValue"); sv.Name = "RoadMeshSpecs"; sv.Value = ""; sv.Parent = m
	m.Parent = roads
end
idle()
print("server models for covered pieces arrived: bakes caused =", st.bakes + st.fixed - before)
-- settle: wait past SETTLE_QUIET (patched to 0.3 s)
local t = os.clock()
while os.clock() - t < 3 do H.task.wait(0.05) end
idle()
local lt, sum = RoadMeshView._live()
print(string.format("after settle: liveTris=%d (cells sum %d), alive EMs=%d, live meshes=%d, +%d static bakes", lt, sum, st.fixedAlive, select(3, RoadMeshView._live()), st.bakes - b0))
-- budget refusal falls back to static
H.refuseFixed = true
b0, f0 = st.bakes, st.fixed
edit("edit with budget refused", V3.new(320, 10, 192), V3.new(448, 10, 320))
H.refuseFixed = false
process.exit(0)
