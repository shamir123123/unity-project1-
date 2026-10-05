--!strict
-- Lot ground: a building stands on flat ground, a house's yard keeps the lie of the land, a
-- shop's yard is held level out to the road, the terrain is never painted, and a bulldozed lot
-- gives the ground back. No framework: call run() from the Studio command bar and it asserts.
-- It runs the real TerrainPadService against a fresh Heightmap + overlay ledger
-- (TerrainDataService is stubbed, so it never touches a live map), loading modules with
-- loadstring so every edit is picked up.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local function run()
	local tdsInst = SSS.Services.Terrain.TerrainDataService
	local cache: { [Instance]: any } = {}
	local shimRequire: (Instance) -> any
	local function load(inst: Instance): any
		if cache[inst] ~= nil then return cache[inst] end
		local f = assert((loadstring :: any)((inst :: any).Source, inst:GetFullName()))
		setfenv(f, setmetatable({ script = inst, require = shimRequire }, { __index = getfenv(0) }))
		local r = f()
		cache[inst] = r
		return r
	end
	shimRequire = load

	local C = load(RS.Terrain.TerrainConstants)
	local hm = load(RS.Terrain.Heightmap).new()
	local led = load(SSS.Services.Terrain.TerrainOverlayLedger).new(hm)
	cache[tdsInst] = {
		getOverlayLedger = function() return led end,
		getHeightmap = function() return hm end,
		getHeightAt = function(x: number, z: number) return hm:getHeightAt(x, z) end,
	}
	local Pad = load(SSS.Services.Terrain.TerrainPadService)

	local function key(v: number): number return math.floor(C.worldToCorner(v) + 0.5) end
	local function mat(x: number, z: number): number return hm:getMaterial(key(x), key(z)) end
	local function height(x: number, z: number): number return C.rawToWorldY(hm:getCorner(key(x), key(z))) end
	-- A lot whose road is toward -Z (LookVector faces the road).
	local function lot(x: number, z: number): CFrame
		return CFrame.lookAt(Vector3.new(x, 0, z), Vector3.new(x, 0, z - 10))
	end
	local BASE = 10
	local padY = BASE - C.RENDER_BULGE
	-- Natural ground falling toward the road, 1 in 4, around (cx, cz).
	local function slope(cx: number, cz: number)
		for gz = key(cz - 60), key(cz + 60) do
			for gx = key(cx - 60), key(cx + 60) do
				hm:setCorner(gx, gz, C.worldYToRaw(padY + (C.cornerToWorld(gz) - cz) * 0.25))
			end
		end
	end

	-- A shop: the whole plot flat, and the forecourt in front of it held level too.
	slope(100, 100)
	hm:setMaterial(key(100), key(100), C.Material.SAND) -- a player's paint under the lot
	Pad.padFootprint("A", lot(100, 100), 32, 32, BASE) -- front at z = 84
	assert(math.abs(height(100, 100) - padY) < 0.05 and math.abs(height(88, 112) - padY) < 0.05, "a shop's plot is flat")
	assert(math.abs(height(100, 80) - padY) < 0.05, "a shop's forecourt is held level out to the road")
	assert(mat(100, 100) == C.Material.SAND, "a pad never paints the ground")

	-- A house: flat under itself, its front yard on the lie of the land.
	slope(100, 300)
	Pad.padFootprint("H", lot(100, 300), 16, 12, BASE, 1, false) -- front at z = 294
	assert(math.abs(height(100, 300) - padY) < 0.05, "a house stands on flat ground")
	-- 5 studs in front of it, past the flat verge: eased toward the house, still sloping.
	local natural = padY + (288 - 300) * 0.25
	local yard = height(100, 288)
	assert(yard < padY - 0.5 and yard > natural + 0.5, "a house's front yard is softened, not flattened: " .. yard)
	assert(math.abs(height(100, 252) - (padY + (252 - 300) * 0.25)) < 0.05, "far ground keeps its own height")

	Pad.unpadFootprint("A")
	assert(math.abs(height(100, 100) - padY) < 0.05, "natural ground comes back where the lot was") -- it was padY there
	assert(math.abs(height(100, 80) - (padY - 5)) < 0.05, "the forecourt goes back to the slope")

	-- A road's verge reaching into a lot (a slope, a corner lot) is claimed at a shared rank:
	-- the lot pulls it DOWN to its level, never up, and a road's hard bed is never touched.
	local LOCKED = C.Flag.LOCKED + C.Flag.ROAD_GRADED
	local VERGE = 1e9
	led:beginOwner("road:seg:1")
	led:write("road:seg:1", key(500), key(484), C.worldYToRaw(BASE + 3), LOCKED, VERGE) -- above the lot
	led:write("road:seg:1", key(508), key(484), C.worldYToRaw(BASE - 5), LOCKED, VERGE) -- below it
	led:write("road:seg:1", key(492), key(484), C.worldYToRaw(BASE + 3), LOCKED)        -- a hard bed
	Pad.padFootprint("V", lot(500, 500), 32, 32, BASE) -- front at z = 484
	assert(math.abs(height(500, 484) - padY) < 0.05, "a road verge above the lot is pulled down to it")
	assert(math.abs(height(508, 484) - (BASE - 5)) < 0.05, "a road verge below the lot stays where it is")
	assert(math.abs(height(492, 484) - (BASE + 3)) < 0.05, "a road's hard bed is never touched")

	-- Earthworks settle in steps.
	slope(300, 300)
	local was = height(300, 300 + 24) -- a corner under the lot, off its natural level
	Pad.padFootprint("S", lot(300, 300), 64, 64, BASE, 0.5)
	local mid = height(300, 324)
	assert(math.abs(mid - (was + (padY - was) * 0.5)) < 0.3, "half way through the earthworks, half way there")
	Pad.padFootprint("S", lot(300, 300), 64, 64, BASE, 1)
	assert(math.abs(height(300, 324) - padY) < 0.05, "finished, flat")
	return "TerrainPadService.spec: ok"
end

return { run = run }
