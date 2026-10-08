--!nocheck
-- Server time for one placement (RoadService.placeSegment, synchronous part) on growing grids,
-- with a per-function breakdown of where it goes. Terrain grading is stubbed out.
-- Usage (from tools/harness): lune run bench_server_place.luau [gridN]
local H = require("./loader")
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 16
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
RoadService.Init()
local hb = H.game:GetService("RunService").Heartbeat
local function frames(n) for _ = 1, n do hb:Fire(1 / 60); H.task.wait() end end

-- time spent per RoadNetwork method (and a few RoadService collaborators) during one placement
local spent = {}
local function wrap(tbl, name, label)
	local f = tbl[name]
	if type(f) ~= "function" then return end
	tbl[name] = function(...)
		local t = os.clock()
		local r = table.pack(f(...))
		spent[label] = (spent[label] or 0) + (os.clock() - t)
		return table.unpack(r, 1, r.n)
	end
end
for _, m in { "addSegment", "resolveCrossings", "dissolveSwallowedArms", "reflowDirtyRoundabouts", "consumeChanges", "dedupeParallel", "getOrCreateJunctionNode", "splitSegment" } do
	wrap(RoadNetwork, m, "net." .. m)
end
local Rep = H.require("ServerScriptService.Services.Road.RoadReplicationService")
for _, m in { "broadcastTopologyDeltas", "queueSegDelta" } do wrap(Rep, m, "rep." .. m) end
-- Everything else a placement sets off (mostly in the next frame): every function of these.
local function wrapAll(tbl, prefix, private)
	for k, v in tbl do
		if type(v) == "function" and type(k) == "string" and (private or k:sub(1, 1) ~= "_") then wrap(tbl, k, prefix .. k) end
	end
end
wrapAll(Rep, "rep.")
wrapAll(H.require("ReplicatedStorage.Road.RoadSceneRenderer"), "scene.")
wrapAll(H.require("ReplicatedStorage.Road.RoadNavigationGraph"), "nav.", true)
wrapAll(H.require("ServerScriptService.Services.Road.RoadTurnPermissionStore"), "perm.")

local function place(a, b, t)
	local p1, p2 = a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3)
	return RoadService.placeSegment(a, p1, p2, b, t or "CollectorRoad")
end
local half = N * 64
local t0 = os.clock()
for i = 0, N do
	place(V3.new(-half, 10, -half + i * 128), V3.new(half, 10, -half + i * 128))
	frames(1)
end
for i = 0, N do
	place(V3.new(-half + i * 128, 10, -half), V3.new(-half + i * 128, 10, half))
	frames(1)
end
frames(120)
local segs = 0 for _ in RoadService.getNetwork():getSegments() do segs += 1 end
print(string.format("grid %dx%d built: %d segments (%.1f s)", N, N, segs, os.clock() - t0))

local function measure(label, a, b, t)
	table.clear(spent)
	local t1 = os.clock()
	place(a, b, t)
	local sync = os.clock() - t1
	if process.env.SPLIT then
		local parts0 = {}
		for k, v in spent do table.insert(parts0, string.format("%s %.0f", k, v * 1000)) end
		table.sort(parts0)
		print("   sync: " .. table.concat(parts0, ", "))
		table.clear(spent)
	end
	local t2 = os.clock()
	frames(1) -- the deferred nav flush + first render slice
	local first = os.clock() - t2
	local parts = {}
	for k, v in spent do table.insert(parts, { k, v }) end
	table.sort(parts, function(x, y) return x[2] > y[2] end)
	local s = {}
	for i = 1, math.min(tonumber(process.env.TOP) or 5, #parts) do table.insert(s, string.format("%s %.0f", parts[i][1], parts[i][2] * 1000)) end
	print(string.format("%-30s placeSegment %6.1f ms; next frame %6.1f ms | %s", label, sync * 1000, first * 1000, table.concat(s, ", ")))
	frames(60)
end
measure("short link in a block", V3.new(64 - half, 10, -half + 32), V3.new(64 - half, 10, -half + 96))
measure("road across 4 streets", V3.new(-half + 32, 10, -half + 64), V3.new(-half + 32 + 4 * 128, 10, -half + 64 + 10))
measure("diagonal across the city", V3.new(-half + 10, 10, -half + 20), V3.new(half - 20, 10, half - 10))
process.exit(0)
