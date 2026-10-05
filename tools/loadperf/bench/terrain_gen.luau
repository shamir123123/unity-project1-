local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local bundleName = process.args[1] or "../bundle_before"
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = bundleName })
local RS = rt.game:GetService("ReplicatedStorage")
local T = RS:FindFirstChild("Terrain")
local Constants = rt.require(T.TerrainConstants)
local Heightmap = rt.require(T.Heightmap)
local TerrainGenerator = rt.require(T.TerrainGenerator)
local TerrainLandform = rt.require(T.TerrainLandform)
local TerrainMesh = rt.require(T.TerrainMesh)

local function bench(name, f)
	local t0 = os.clock()
	local r = f()
	print(string.format("%-40s %8.3fs", name, os.clock() - t0))
	return r
end

for _, algo in { 0, 3 } do
	local params = { seed = 5.5, heightRange = 1, algo = if algo == 3 then 3 else nil, shape = "coast" }
	if algo == 3 then bench("landform field build", function() return TerrainLandform.field(params) end) end
	local hm = Heightmap.new()
	bench("generate full map algo=" .. algo, function()
		for cz = 0, Constants.CHUNKS_PER_AXIS - 1 do
			for cx = 0, Constants.CHUNKS_PER_AXIS - 1 do
				TerrainGenerator.generateChunk(hm, cx, cz, params)
			end
		end
	end)
	local function sampleY(gx, gz)
		local CT = Constants.CHUNK_TILES
		local cx, cz = math.floor(gx / CT), math.floor(gz / CT)
		if cx < 0 or cz < 0 or cx >= 32 or cz >= 32 then return TerrainGenerator.surfaceYAt(gx, gz, params) end
		return Constants.rawToWorldY(hm:getCorner(gx, gz))
	end
	local function sampleMat(gx, gz) return 0 end
	local errs = {}
	bench("strideErrors all chunks", function()
		for key = 0, 1023 do
			local cx = key % 32
			local b, c = TerrainMesh.strideErrors(cx, (key - cx) / 32, sampleY)
			errs[key] = { blocks = b, chunk = c }
		end
	end)
	local tris = 0
	bench("buildChunk all chunks (stride 2 everywhere)", function()
		for key = 0, 1023 do
			local cx = key % 32
			local g = TerrainMesh.buildChunk(cx, (key - cx) / 32, sampleY, sampleMat, function() return 2 end)
			tris += #g.tri // 3
		end
	end)
	print("  tris at stride 2:", tris)
	tris = 0
	bench("buildChunk all chunks (stride 8)", function()
		for key = 0, 1023 do
			local cx = key % 32
			local g = TerrainMesh.buildChunk(cx, (key - cx) / 32, sampleY, sampleMat, function() return 8 end)
			tris += #g.tri // 3
		end
	end)
	print("  tris at stride 8:", tris)
end
