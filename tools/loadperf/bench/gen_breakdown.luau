local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = process.args[1] or "../bundle_before" })
local T = rt.game:GetService("ReplicatedStorage"):FindFirstChild("Terrain")
local Constants = rt.require(T.TerrainConstants)
local Heightmap = rt.require(T.Heightmap)
local TerrainGenerator = rt.require(T.TerrainGenerator)
local TerrainLandform = rt.require(T.TerrainLandform)
for _, algo in { 0, 3 } do
	local params = { seed = 5.5, heightRange = 1, algo = if algo == 3 then 3 else nil, shape = "coast" }
	if algo == 3 then TerrainLandform.field(params) end
	local hm = Heightmap.new()
	local t0 = os.clock()
	for key = 0, 1023 do local cx, cz = Heightmap.decodeKey(key); hm:ensureChunk(cx, cz) end
	local tAlloc = os.clock() - t0
	t0 = os.clock()
	for key = 0, 1023 do local cx, cz = Heightmap.decodeKey(key); TerrainGenerator.generateChunk(hm, cx, cz, params) end
	local tGen = os.clock() - t0
	-- coarse samples only
	local step = if algo == 3 then 4 else 2
	local n = 0
	t0 = os.clock()
	local f = if algo == 3 then TerrainLandform.field(params) else nil
	for cz = 0, 31 do for cx = 0, 31 do
		for lz = 0, 64, step do for lx = 0, 64, step do
			local gx, gz = cx * 64 + lx, cz * 64 + lz
			if f then TerrainLandform.sample(f, Constants.cornerToWorld(gx), Constants.cornerToWorld(gz)) else TerrainGenerator.surfaceYAt(gx, gz, params) end
			n += 1
		end end
	end end
	local tSamples = os.clock() - t0
	print(string.format("algo %d: ensureChunk alloc %.3fs | generateChunk total %.3fs | coarse samples alone %.3fs (%d) => fill ~%.3fs", algo, tAlloc, tGen, tSamples, n, tGen - tSamples))
end
