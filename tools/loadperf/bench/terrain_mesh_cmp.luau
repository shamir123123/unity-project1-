-- Old (per-corner sampleY) vs new (row reader) through the real TerrainMeshView-style sampler stack.
local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = process.args[1] or "../bundle_after" })
local T = rt.game:GetService("ReplicatedStorage"):FindFirstChild("Terrain")
local Constants = rt.require(T.TerrainConstants)
local Heightmap = rt.require(T.Heightmap)
local TerrainGenerator = rt.require(T.TerrainGenerator)
local TerrainMesh = rt.require(T.TerrainMesh)

local params = { seed = 5.5, heightRange = 1, algo = 3, shape = "coast" }
local hm = Heightmap.new()
for key = 0, 1023 do
	local cx, cz = Heightmap.decodeKey(key)
	if key ~= 517 then TerrainGenerator.generateChunk(hm, cx, cz, params) end -- one unloaded chunk keeps the fallback path covered
end
local CT, CHUNKS = Constants.CHUNK_TILES, Constants.CHUNKS_PER_AXIS
-- TerrainBuildController.cornerY
local function cornerY(gx, gz)
	local cx = math.floor(gx / CT)
	local cz = math.floor(gz / CT)
	if cx >= 0 and cx < CHUNKS and cz >= 0 and cz < CHUNKS and hm:getChunk(cx, cz) then
		return Constants.rawToWorldY(hm:getCorner(gx, gz))
	end
	return TerrainGenerator.surfaceYAt(gx, gz, params)
end
-- a sparse fake road cap on a few chunks, both as per-corner and per-chunk
local capTables = {}
for _, key in { 5, 6, 37, 38, 500 } do
	local t = {}
	for i = 0, 64 * 65, 7 do t[i] = -3 end
	capTables[key] = t
end
local function groundCap(gx, gz)
	local cx = math.min(gx // CT, CHUNKS - 1)
	local cz = math.min(gz // CT, CHUNKS - 1)
	local caps = capTables[cz * CHUNKS + cx]
	if not caps then return nil end
	return caps[(gz - cz * CT) * (CT + 1) + (gx - cx * CT)]
end
local function capped(gx, gz)
	local y = cornerY(gx, gz)
	local c = groundCap(gx, gz)
	return if c and c < y then c else y
end
local function sampleMat() return 0 end
local function stride() return 2 end

-- Build the new row reader the same way TerrainMeshView does (copy of makeFillRow semantics via the module):
local TMV = rt.require(T.TerrainMeshView)
TMV.setGroundCap(groundCap, function(key) return capTables[key] end)
TMV.setSource(cornerY, sampleMat, function() return true end, nil, function(key)
	local cx, cz = Heightmap.decodeKey(key)
	local c = hm:getChunk(cx, cz)
	return c and c.heights or nil
end)
-- reach the private _fillRow through a tiny probe: buildChunk path is engine-bound, so rebuild one locally
local fillRow = (TMV :: any)._debugFillRow and (TMV :: any)._debugFillRow() or nil
assert(fillRow, "expose _debugFillRow for the bench")

local maxDiff, mism = 0, 0
local t0 = os.clock()
local errsOld = {}
for key = 0, 1023 do
	local cx = key % 32
	local b, c = TerrainMesh.strideErrors(cx, (key - cx) / 32, capped)
	errsOld[key] = { b, c }
end
local tOldErr = os.clock() - t0
t0 = os.clock()
for key = 0, 1023 do
	local cx = key % 32
	local b, c = TerrainMesh.strideErrors(cx, (key - cx) / 32, capped, fillRow)
	local ob = errsOld[key][1]
	for i = 1, #ob do if ob[i] ~= b[i] then mism += 1 end end
	for k, v in errsOld[key][2] do if c[k] ~= v then mism += 1 end end
end
local tNewErr = os.clock() - t0
print(string.format("strideErrors x1024: old %.3fs  new %.3fs  mismatches %d", tOldErr, tNewErr, mism))

local tOld, tNew = 0, 0
for _, s in { 2, 8 } do
	local st = function() return s end
	t0 = os.clock()
	local geosOld = {}
	for key = 0, 1023 do
		local cx = key % 32
		geosOld[key] = TerrainMesh.buildChunk(cx, (key - cx) / 32, capped, sampleMat, st)
	end
	tOld = os.clock() - t0
	t0 = os.clock()
	local diffs = 0
	for key = 0, 1023 do
		local cx = key % 32
		local g = TerrainMesh.buildChunk(cx, (key - cx) / 32, capped, sampleMat, st, fillRow)
		local o = geosOld[key]
		if #g.pos ~= #o.pos or #g.tri ~= #o.tri or g.origin ~= o.origin then diffs += 1 else
			for i = 1, #g.pos do if g.pos[i] ~= o.pos[i] or g.nrm[i] ~= o.nrm[i] then diffs += 1 break end end
		end
	end
	tNew = os.clock() - t0
	print(string.format("buildChunk stride %d x1024: old %.3fs  new %.3fs  chunks differing %d", s, tOld, tNew, diffs))
end
