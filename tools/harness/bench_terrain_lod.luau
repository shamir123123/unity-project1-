--!nocheck
-- Ground triangles on a real preset map: what the load draws from a city camera, what each
-- distance bucket costs, and what "full detail everywhere" would cost.
local H = require("./loader")
local process = require("@lune/process")
local presetId = process.args[1] or "green_valley"
local mode = process.args[2] or "load" -- load | fine
H.boot({ server = false })
H.quietWarn = true
local MapPresets = H.require("ReplicatedStorage.City.MapPresets")
local Heightmap = H.require("ReplicatedStorage.Terrain.Heightmap")
local TerrainGenerator = H.require("ReplicatedStorage.Terrain.TerrainGenerator")
local TMV = H.require("ReplicatedStorage.Terrain.TerrainMeshView")
local C = H.require("ReplicatedStorage.Terrain.TerrainConstants")
local preset = MapPresets.get(presetId)
local params = MapPresets.genOf(preset)
local hm = Heightmap.new()
local t = os.clock()
TerrainGenerator.generate(hm, params)
print(string.format("generated %s in %.1f s", presetId, os.clock() - t))
local function sampleY(gx, gz)
	local cx, cz = gx // C.CHUNK_TILES, gz // C.CHUNK_TILES
	if cx >= 0 and cx < C.CHUNKS_PER_AXIS and cz >= 0 and cz < C.CHUNKS_PER_AXIS and hm:getChunk(cx, cz) then
		return C.rawToWorldY(hm:getCorner(gx, gz))
	end
	return TerrainGenerator.surfaceYAt(gx, gz, params)
end
TMV.setSource(sampleY, function() return 0 end, function() return true end,
	function(key) local cx, cz = Heightmap.decodeKey(key); local ch = hm:getChunk(cx, cz); return ch and ch.heights end,
	function(key) local cx, cz = Heightmap.decodeKey(key); local ch = hm:getChunk(cx, cz); return ch and ch.heights end)
local hb = H.game:GetService("RunService").Heartbeat
local function frames(n) for _ = 1, n do hb:Fire(1 / 60); H.task.wait() end end
local cam = H.game:GetService("Workspace").CurrentCamera
cam.CFrame = H.roblox.CFrame.new(0, 600, 0) * H.roblox.CFrame.Angles(-0.9, 0, 0)
if mode == "fine" then
	-- every chunk pinned: bucket 0 everywhere (what a refine-everywhere LOD converges to)
	for key = 0, C.CHUNKS_PER_AXIS * C.CHUNKS_PER_AXIS - 1 do TMV.pin(key) end
end
TMV.start()
local tris0 = H.emStats.tris
for key = 0, C.CHUNKS_PER_AXIS * C.CHUNKS_PER_AXIS - 1 do TMV.request(key) end
t = os.clock()
while TMV.pending() > 0 and os.clock() - t < 900 do frames(1) end
print(string.format("%s: %d ground triangles in %d bakes (%.1f s)", mode, H.emStats.tris - tris0, H.emStats.bakes, os.clock() - t))
process.exit(0)
