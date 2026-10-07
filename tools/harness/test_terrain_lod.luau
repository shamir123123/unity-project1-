--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local presetId = process.args[1] or "green_valley"
H.patches["ReplicatedStorage.Terrain.TerrainMeshView"] = function(src)
	return (string.gsub(src, "\nreturn TerrainMeshView%s*$", [[

TerrainMeshView._dbg = function()
	local drawn, blocks = 0, 0
	for _, s in _supers do drawn += (s.tris or 0); blocks += 1 end
	local nv = 0
	for _, byBlock in _variants do for _ in byBlock do nv += 1 end end
	return drawn, _variantTris, nv, blocks
end
return TerrainMeshView
]]))
end
H.boot({ server = false })
H.quietWarn = true
local MapPresets = H.require("ReplicatedStorage.City.MapPresets")
local Heightmap = H.require("ReplicatedStorage.Terrain.Heightmap")
local TerrainGenerator = H.require("ReplicatedStorage.Terrain.TerrainGenerator")
local TMV = H.require("ReplicatedStorage.Terrain.TerrainMeshView")
local C = H.require("ReplicatedStorage.Terrain.TerrainConstants")
local params = MapPresets.genOf(MapPresets.get(presetId))
local hm = Heightmap.new()
TerrainGenerator.generate(hm, params)
local function sampleY(gx, gz)
	local cx, cz = gx // C.CHUNK_TILES, gz // C.CHUNK_TILES
	if cx >= 0 and cx < C.CHUNKS_PER_AXIS and cz >= 0 and cz < C.CHUNKS_PER_AXIS and hm:getChunk(cx, cz) then
		return C.rawToWorldY(hm:getCorner(gx, gz))
	end
	return TerrainGenerator.surfaceYAt(gx, gz, params)
end
local function heights(key) local cx, cz = Heightmap.decodeKey(key); local ch = hm:getChunk(cx, cz); return ch and ch.heights end
TMV.setSource(sampleY, function() return 0 end, function() return true end, heights, heights)
local hb = H.game:GetService("RunService").Heartbeat
local cam = H.game:GetService("Workspace").CurrentCamera
local maxBakesPerFrame, frameCount = 0, 0
local function frame()
	local b = H.emStats.bakes
	hb:Fire(1 / 60)
	H.task.wait(1 / 60)
	frameCount += 1
	maxBakesPerFrame = math.max(maxBakesPerFrame, H.emStats.bakes - b)
end
local function at(x, z) cam.CFrame = H.roblox.CFrame.new(x, 500, z) * H.roblox.CFrame.Angles(-0.9, 0, 0) end
local function report(label, b0, seconds)
	local drawn, parked, nv, blocks = TMV._dbg()
	print(string.format("%-28s bakes %3d over %.1fs (max %d/frame) | drawn %6d tris in %d blocks | parked %6d tris in %d variants",
		label, H.emStats.bakes - b0, seconds, maxBakesPerFrame, drawn, blocks, parked, nv))
	maxBakesPerFrame = 0
end
at(0, 0)
TMV.start()
local b0 = H.emStats.bakes
for key = 0, C.CHUNKS_PER_AXIS * C.CHUNKS_PER_AXIS - 1 do TMV.request(key) end
local t = os.clock()
while TMV.pending() > 0 and os.clock() - t < 900 do frame() end
report("load at centre", b0, os.clock() - t)
TMV.setLoading(false)
local function visit(label, x, z, seconds)
	at(x, z)
	local b = H.emStats.bakes
	local t1 = os.clock()
	while os.clock() - t1 < seconds do frame() end
	report(label, b, os.clock() - t1)
end
visit("rest at centre (no change)", 0, 0, 3)
visit("fly to NE corner, rest 25s", 3600, 3600, 25)
visit("back to centre, rest 10s", 0, 0, 10)
visit("NE corner again, rest 10s", 3600, 3600, 10)
TMV.setDetailScale(0.45)
visit("Low preset (0.45), rest 25s", 3600, 3600, 25)
process.exit(0)
