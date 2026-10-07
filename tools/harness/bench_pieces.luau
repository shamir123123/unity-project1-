--!nocheck
-- Client road rebuild cost: full city build, then one placement's incremental rebuild.
local H = require("./loader")
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 12
local terrainStub = {
	setGroundCap = function() end, markDirty = function() end, request = function() end,
}
H.boot({ server = false, overrides = { ["ReplicatedStorage.Terrain.TerrainMeshView"] = terrainStub } })
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local RoadPieces = H.require("StarterPlayer.StarterPlayerScripts.World.RoadPieces")

local net = RoadNetwork.new()
local t0 = os.clock()
local count = City.grid(net, N, 128, "CollectorRoad")
print(string.format("network: %d segments laid in %.1f ms", count, (os.clock() - t0) * 1000))
net:consumeChanges()

local dirtyLog = {}
local done = false
local t1
local function notify(dirty)
	local n = 0
	for _ in dirty do n += 1 end
	table.insert(dirtyLog, n)
	done = true
end
DataCache.SetSegments(City.records(net))
t1 = os.clock()
RoadPieces.start(notify)
while not RoadPieces.isIdle() do H.task.wait() end
print(string.format("RoadPieces full build: %.1f ms, %d dirty cells", (os.clock() - t1) * 1000, dirtyLog[#dirtyLog] or 0))

-- one placement: a road across the middle of a block, joining two existing streets (T-junctions both ends)
local function placeAndRebuild(label, p0, p3, roadType)
	local a, b, c, d = City.straight(p0, p3)
	net:addSegment(a, b, c, d, roadType or "CollectorRoad")
	local delta = City.delta(net)
	local t = os.clock()
	DataCache.ApplySegmentsDelta(delta)
	H.task.wait()
	while not RoadPieces.isIdle() do H.task.wait() end
	print(string.format("%s: delta %d changed/%d removed, rebuild %.1f ms, %d dirty cells",
		label, #delta.changed, #delta.removed, (os.clock() - t) * 1000, dirtyLog[#dirtyLog] or 0))
end
placeAndRebuild("mid-block link", V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128))
placeAndRebuild("open-ground road", V3.new(N * 64 + 300, 10, 0), V3.new(N * 64 + 700, 10, 0))
placeAndRebuild("diagonal across 2 blocks", V3.new(-256, 10, -256), V3.new(0, 10, 0))
