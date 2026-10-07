--!strict
return function()
	local module = script.Parent
	local chunk = assert(loadstring(module.Source))
	setfenv(chunk, setmetatable({ script = module }, { __index = getfenv() }))
	local Heightmap = chunk()
	local Constants = require(module.Parent.TerrainConstants)

	local function copies(hm: any, field: string, expected: number): ()
		for cz = 0, 1 do
			for cx = 0, 1 do
				local stored = assert(hm:getChunk(cx, cz), "missing corner owner")
				local lx = if cx == 0 then Constants.CHUNK_TILES else 0
				local lz = if cz == 0 then Constants.CHUNK_TILES else 0
				local index = lz * Constants.CHUNK_CORNERS + lx
				local actual = if field == "heights" then buffer.readu16(stored.heights, index * 2)
					else buffer.readu8(stored[field], index)
				assert(actual == expected, "shared corner diverged in " .. field)
			end
		end
	end

	it("writes height, flags and material to all four corner owners", function()
		local hm = Heightmap.new()
		hm:setCorner(64, 64, 1234)
		hm:setFlags(64, 64, Constants.Flag.LOCKED)
		hm:setMaterial(64, 64, Constants.Material.ROCK)
		copies(hm, "heights", 1234)
		copies(hm, "flags", Constants.Flag.LOCKED)
		copies(hm, "materials", Constants.Material.ROCK)
		assert(#hm:drainDirty() == 4)
		assert(#hm:drainRenderDirty() == 4)
	end)

	it("temporary heights and flags preserve dirty queues", function()
		local hm = Heightmap.new()
		hm:setCornerNoDirty(64, 64, 4567)
		hm:setFlags(64, 64, Constants.Flag.LOCKED)
		copies(hm, "heights", 4567)
		copies(hm, "flags", Constants.Flag.LOCKED)
		assert(#hm:drainDirty() == 0)
		assert(#hm:drainRenderDirty() == 0)
	end)

	it("clamps outer map coordinates and raw heights", function()
		local hm = Heightmap.new()
		hm:setCorner(-100, -100, -1)
		hm:setCorner(99999, 99999, Constants.RAW_MAX + 1)
		assert(hm:getCorner(0, 0) == 0)
		assert(hm:getCorner(Constants.CORNERS_PER_AXIS - 1, Constants.CORNERS_PER_AXIS - 1) == Constants.RAW_MAX)
		hm:setFlags(99999, 99999, Constants.Flag.LOCKED)
		hm:setMaterial(-100, -100, Constants.Material.ROCK)
		assert(hm:isLocked(Constants.CORNERS_PER_AXIS - 1, Constants.CORNERS_PER_AXIS - 1))
		assert(hm:getMaterial(0, 0) == Constants.Material.ROCK)
	end)
end
