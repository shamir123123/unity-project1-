local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Runtime = require("../tools/runtime")
pcall(roblox.implementMethod, "EncodingService", "CompressBuffer", function(_, b, _algo, level)
	return buffer.fromstring(serde.compress("zstd", buffer.tostring(b), level))
end)
pcall(roblox.implementMethod, "EncodingService", "DecompressBuffer", function(_, b, _algo)
	return buffer.fromstring(serde.decompress("zstd", buffer.tostring(b)))
end)
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = "../bundle_after" })
local T = rt.game:GetService("ReplicatedStorage"):FindFirstChild("Terrain")
local Codec = rt.require(T.TerrainStreamCodec)
local Heightmap = rt.require(T.Heightmap)
local TerrainGenerator = rt.require(T.TerrainGenerator)
print("supported:", Codec.supported())
local params = { seed = 5.5, heightRange = 1, algo = 3, shape = "coast" }
local hm = Heightmap.new()
local items = {}
local seed = 3
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
for k = 0, 299 do
	local key = 300 + k
	local cx, cz = Heightmap.decodeKey(key)
	TerrainGenerator.generateChunk(hm, cx, cz, params)
	local c = hm:getChunk(cx, cz)
	-- city edits: a graded road band (flat), building pads (flat squares), PAVED materials, flags
	local roadZ = math.floor(rnd() * 60)
	for x = 0, 64 do for dz = 0, 4 do
		local i = (math.min(roadZ + dz, 64)) * 65 + x
		buffer.writeu16(c.heights, i * 2, 300); buffer.writeu8(c.materials, i, 7); buffer.writeu8(c.flags, i, 3)
	end end
	for p = 1, 6 do
		local px, pz = math.floor(rnd() * 55), math.floor(rnd() * 55)
		local hgt = 280 + math.floor(rnd() * 40)
		for z = pz, pz + 8 do for x = px, px + 8 do
			local i = z * 65 + x
			buffer.writeu16(c.heights, i * 2, hgt); buffer.writeu8(c.materials, i, 8); buffer.writeu8(c.flags, i, 4)
		end end
	end
	items[#items + 1] = { key = key, h = c.heights, m = c.materials, f = c.flags }
end
local raw = #items * (8450 + 4225 + 4225)
local t0 = os.clock()
local packedBytes, batches = 0, {}
for i = 1, #items, 32 do
	local b = {}
	for j = i, math.min(i + 31, #items) do b[#b + 1] = items[j] end
	local p = Codec.pack(b)
	packedBytes += buffer.len(p)
	batches[#batches + 1] = { p = p, src = b }
end
local tPack = os.clock() - t0
t0 = os.clock()
local exact = true
for _, bt in batches do
	local out = Codec.unpack(bt.p)
	assert(out and #out == #bt.src, "decode failed")
	for i, it in out do
		local s = bt.src[i]
		if it.key ~= s.key or buffer.tostring(it.h) ~= buffer.tostring(s.h) or buffer.tostring(it.m) ~= buffer.tostring(s.m) or buffer.tostring(it.f) ~= buffer.tostring(s.f) then exact = false end
	end
end
local tUnpack = os.clock() - t0
print(string.format("300 edited chunks: raw %.0f KB -> packed %.0f KB (%.1fx)  pack %.3fs  unpack %.3fs  exact=%s",
	raw / 1024, packedBytes / 1024, raw / packedBytes, tPack, tUnpack, tostring(exact)))
print("garbage decodes to nil:", Codec.unpack(buffer.fromstring("not zstd")) == nil, Codec.unpack(123) == nil)
