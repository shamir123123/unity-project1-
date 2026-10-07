--!nocheck
-- Ground work per city edit: chunk geometry builds and bakes after markDirty on a loaded map.
local H = require("./loader")
local process = require("@lune/process")
H.boot({ server = false })
H.quietWarn = true
local TerrainMesh = H.require("ReplicatedStorage.Terrain.TerrainMesh")
local TMV = H.require("ReplicatedStorage.Terrain.TerrainMeshView")
local C = H.require("ReplicatedStorage.Terrain.TerrainConstants")
local builds = 0
local orig = TerrainMesh.buildChunk
TerrainMesh.buildChunk = function(...) builds += 1; return orig(...) end
local bump = {} -- chunk key -> extra height (a "road grade")
local function sampleY(gx, gz)
	local cx, cz = gx // C.CHUNK_TILES, gz // C.CHUNK_TILES
	local key = cz * C.CHUNKS_PER_AXIS + cx
	local y = 20 + math.sin(gx * 0.05) * 6 + math.cos(gz * 0.07) * 5
	if bump[key] then y -= bump[key] * (((gx % 64) > 20 and (gx % 64) < 40) and 1 or 0) end
	return y
end
TMV.setSource(sampleY, function() return 1 end, function() return true end)
local hb = H.game:GetService("RunService").Heartbeat
local function frames(n) for _ = 1, n do hb:Fire(1 / 60); H.task.wait() end end
TMV.start()
local cam = H.game:GetService("Workspace").CurrentCamera
cam.CFrame = H.roblox.CFrame.new(0, 400, 0)
for key = 0, C.CHUNKS_PER_AXIS * C.CHUNKS_PER_AXIS - 1 do TMV.request(key) end
local t = os.clock()
while TMV.pending() > 0 and os.clock() - t < 600 do frames(1) end
print(string.format("load: %d chunk builds, %d bakes, %.1f s", builds, H.emStats.bakes, os.clock() - t))
TMV.setLoading(false)
local function edit(label, key)
	local b0, k0 = builds, H.emStats.bakes
	bump[key] = (bump[key] or 0) + 3
	TMV.markDirty(key)
	local t0 = os.clock()
	frames(2)
	while TMV.pending() > 0 and os.clock() - t0 < 600 do frames(1) end
	frames(5)
	print(string.format("%s: %d chunk builds, %d static bakes, %d live snapshots alive", label, builds - b0, H.emStats.bakes - k0, H.emStats.fixedAlive))
end
local key = 16 * 32 + 16
edit("first road in a chunk", key)
edit("second road, same chunk", key)
edit("third road, same chunk", key)
edit("road in the next chunk", key + 1)
edit("again in the next chunk", key + 1)
local k0 = H.emStats.bakes
local t = os.clock()
while os.clock() - t < 9 do hb:Fire(1 / 60); H.task.wait(1 / 60) end
print(string.format("after 9 s quiet: %d static bakes (settle), %d live snapshots alive", H.emStats.bakes - k0, H.emStats.fixedAlive))
process.exit(0)
