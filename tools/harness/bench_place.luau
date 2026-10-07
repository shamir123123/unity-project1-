--!nocheck
-- Server: what one interactive placement costs in the request handler, by stage.
local H = require("./loader")
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 10
local flat = function() return 10 end
local terrainData = setmetatable({ getSurfaceY = flat, getNaturalSurfaceY = flat, getHeightAt = flat }, { __index = function() return function() return 10 end end })
local terrainGrade = setmetatable({ setNodeInfo = function() end }, { __index = function() return function() end end })
H.boot({ server = true, overrides = {
	["ServerScriptService.Services.Terrain.TerrainDataService"] = terrainData,
	["ServerScriptService.Services.Terrain.TerrainGradeService"] = terrainGrade,
} })
H.quietWarn = true
local V3 = H.roblox.Vector3
local RoadService = H.require("ServerScriptService.Services.Road.RoadService")
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local RoadReplicationService = H.require("ServerScriptService.Services.Road.RoadReplicationService")
RoadService.Init()
-- time a few internals by wrapping module functions
local timers = {}
local function wrap(tbl, name, label)
	local f = tbl[name]
	tbl[name] = function(...)
		local t = os.clock()
		local r = table.pack(f(...))
		timers[label] = (timers[label] or 0) + (os.clock() - t)
		return table.unpack(r, 1, r.n)
	end
end
local net = RoadService.getNetwork()
wrap(RoadNetwork, "addSegment", "network.addSegment")
wrap(RoadReplicationService, "broadcastTopologyDeltas", "broadcastTopologyDeltas")
local hb = H.game:GetService("RunService").Heartbeat
local function settle() for _ = 1, 400 do hb:Fire(1/60); H.task.wait() end end
local half = N * 64
for i = 0, N do
	RoadService.placeSegment(V3.new(-half + i * 128, 10, -half), V3.new(-half + i * 128, 10, -half / 3), V3.new(-half + i * 128, 10, half / 3), V3.new(-half + i * 128, 10, half), "CollectorRoad")
end
settle()
local function place(label, a, b)
	table.clear(timers)
	local t = os.clock()
	local ok, why = RoadService.placeFromRequest({ p0 = a, p1 = a:Lerp(b, 1/3), p2 = a:Lerp(b, 2/3), p3 = b, roadType = "CollectorRoad" }, nil)
	local sync = os.clock() - t
	local parts = {}
	for k, v in timers do table.insert(parts, string.format("%s %.0f", k, v * 1000)) end
	print(string.format("%s: ok=%s handler %.0f ms [%s]", label, tostring(ok), sync * 1000, table.concat(parts, ", ")))
	settle()
end
place("cross street (splits " .. (N + 1) .. " roads)", V3.new(-half - 50, 10, 0), V3.new(half + 50, 10, 0))
place("short link", V3.new(-half + 64, 10, 200), V3.new(-half + 64 + 128, 10, 200))
place("open ground", V3.new(half + 300, 10, 0), V3.new(half + 700, 10, 0))
process.exit(0)
