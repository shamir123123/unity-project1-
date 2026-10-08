--!nocheck
-- RoadReplicationService.broadcastLaneChanges: the messages every client gets after each edit.
-- Records each SyncLaneChangeGates broadcast through a run of placements on a grid and prints a
-- digest of all of them (ids, order and gate fields), to compare against the code at a commit.
-- Usage (from tools/harness): lune run test_lanechange_broadcast.luau [rev]
local H = require("./loader")
local process = require("@lune/process")
local rev = process.args[1]
if rev then
	for _, path in { "ServerScriptService.Services.Road.RoadReplicationService", "ReplicatedStorage.Road.RoadNavigationGraph" } do
		H.patches[path] = function()
			return process.exec("git", { "show", rev .. ":src/" .. path .. ".luau" }).stdout
		end
	end
end
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
RoadService.Init()
local Net = H.require("ReplicatedStorage.Networker")
local log = {}
local remote = Net.SyncLaneChangeGates
remote.FireAllClients = function(_, msg)
	local parts = { "full=" .. tostring(msg.full) }
	for _, g in msg.changed or msg.gates or {} do
		local conns = {}
		for _, c in g.connections do table.insert(conns, c.fromEdgeId .. ">" .. c.toEdgeId .. "=" .. tostring(c.allowed)) end
		local dots = {}
		for _, d in g.dots do table.insert(dots, string.format("%s/%s/%.4f,%.4f,%.4f", d.edgeId, d.kind, d.position.X, d.position.Y, d.position.Z)) end
		table.insert(parts, string.format("%s|%d|%s|%d|%d|%.4f|%.4f|%s|%s", g.id, g.segmentId, g.direction, g.gateIndex, g.pairIndex,
			g.startDistance, g.endDistance, table.concat(dots, ";"), table.concat(conns, ";")))
	end
	table.insert(parts, "removed=" .. table.concat(msg.removed or {}, ","))
	table.insert(log, table.concat(parts, "\n"))
end
local hb = H.game:GetService("RunService").Heartbeat
local function frames(n) for _ = 1, n do hb:Fire(1 / 60); H.task.wait() end end
local function place(a, b, t)
	return RoadService.placeSegment(a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b, t or "CollectorRoad")
end
local N, half = 5, 5 * 64
for i = 0, N do
	place(V3.new(-half, 10, -half + i * 128), V3.new(half, 10, -half + i * 128)); frames(2)
	place(V3.new(-half + i * 128, 10, -half), V3.new(-half + i * 128, 10, half)); frames(2)
end
frames(30)
-- edits: a diagonal, a short link, an avenue across two streets
place(V3.new(-half + 10, 10, -half + 20), V3.new(half - 20, 10, half - 10)); frames(30)
place(V3.new(64 - half, 10, -half + 32), V3.new(64 - half, 10, -half + 96)); frames(30)
place(V3.new(-half + 32, 10, -half + 64), V3.new(-half + 32 + 2 * 128, 10, -half + 64 + 10), "AvenueConcrete"); frames(30)
local h = 0
local all = table.concat(log, "\n#\n")
for k = 1, #all do h = (h * 31 + string.byte(all, k)) % 2147483647 end
print(string.format("%d broadcasts, %d bytes; digest %d", #log, #all, h))
process.exit(0)
