-- generated heights must be byte-identical before/after
local Runtime = require("../tools/runtime")
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local game = roblox.deserializePlace(fs.readFile("place_lune.rbxl"))
local out = {}
for _, b in { "../bundle_before", "../bundle_after" } do
	local rt = Runtime.load({ game = game, bundle = b })
	local T = rt.game:GetService("ReplicatedStorage"):FindFirstChild("Terrain")
	local Heightmap = rt.require(T.Heightmap)
	local TerrainGenerator = rt.require(T.TerrainGenerator)
	local acc = {}
	for _, params in { { seed = 5.5, heightRange = 1, algo = 3, shape = "coast" }, { seed = 2.25, heightRange = 0.6, shape = "island" } } do
		local hm = Heightmap.new()
		for key = 0, 1023, 7 do
			local cx, cz = Heightmap.decodeKey(key)
			TerrainGenerator.generateChunk(hm, cx, cz, params)
			acc[#acc + 1] = buffer.tostring(hm:getChunk(cx, cz).heights)
		end
	end
	out[#out + 1] = table.concat(acc)
end
print("heights identical:", out[1] == out[2], #out[1])
