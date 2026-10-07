--!nonstrict
-- LoadStressTest -- builds a BIG city through the game's own restore path and times loading it.
-- Edit-time / play-test tool, NOT runtime: nothing requires it. Run it on the SERVER in a Play
-- session, after a city (any fresh one) has loaded:
--
--   require(game.ServerScriptService.Tests.LoadStressTest).run({ blocks = 24, population = 100000 })
--
-- What it does, all through the real services:
--   1. flattens a square of terrain under the test grid (so it is also a "lots of edited
--      terrain" test: every chunk under the city is an edited chunk the client must stream),
--   2. lays a blocks x blocks street grid (RoadService.restoreRoads, exact save format),
--   3. zones every frontage on both sides (PlotService.restore, pre-seat format -> instant build),
--   4. moves people in until `population` (CitizenService.AdminAddPopulation),
--   5. SAVES the city (CitySerializer.serialize + BlobCodec.pack) -- the DataStore blob size,
--   6. RELOADS it from that blob (CitySerializer.restore) -- the server half of a city load,
--   7. reloads it AGAIN over itself -- the unload-then-load of a city switch.
-- and prints a report: phase times, building / household / car / instance counts, blob size,
-- and the terrain stream a joining client would be sent (raw vs packed).
--
-- The CLIENT half of a load (terrain build, loading screen) is not measured here: save the
-- city from the in-game menu afterwards, rejoin, press CONTINUE, and read the [CityLoad],
-- [TerrainBuild] and [CitySlotLoad] lines in the output.
--
-- It REPLACES the loaded city's roads, plots, buildings and citizens. Use a throwaway slot.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local LoadStressTest = {}

local function svc(path: string): any
	local cur: Instance = ServerScriptService:WaitForChild("Services")
	for part in string.gmatch(path, "[^%.]+") do
		cur = cur:WaitForChild(part, 10) :: Instance
		assert(cur, "[LoadStressTest] missing service " .. path)
	end
	return require(cur :: ModuleScript)
end

local function countDescendants(inst: Instance?): number
	return if inst then #inst:GetDescendants() else 0
end

local function fmtBytes(n: number): string
	if n >= 1024 * 1024 then return string.format("%.2f MB", n / 1048576) end
	return string.format("%.1f KB", n / 1024)
end

export type Options = {
	blocks: number?, -- grid is blocks x blocks city blocks
	spacing: number?, -- studs between parallel streets
	population: number?, -- target residents (AdminAddPopulation, 5,000 a call)
	origin: Vector3?, -- grid centre (X/Z); Y is taken from the flattened ground
	groundY: number?, -- world Y the test square is flattened to
	reloads: number?, -- how many timed reloads after the save (>= 1)
}

function LoadStressTest.run(opts: Options?): { [string]: any }
	local o = opts or {}
	local blocks = math.clamp(math.floor(o.blocks or 20), 2, 60)
	local spacing = o.spacing or 112
	local target = o.population or 100000
	local origin = o.origin or Vector3.zero
	local reloads = math.max(1, math.floor(o.reloads or 2))

	local BuildingService = svc("City.BuildingService")
	local CitizenService = svc("City.Simulation.CitizenService")
	local CitySerializer = svc("Data.CitySerializer")
	local BlobCodec = svc("Data.BlobCodec")
	local TerrainDataService = svc("Terrain.TerrainDataService")
	local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
	local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
	local Codec = require(ReplicatedStorage.Terrain.TerrainStreamCodec)

	local report: { [string]: any } = { blocks = blocks, spacing = spacing, target = target }
	local function phase(name: string, fn: () -> ()): number
		local t0 = os.clock()
		local ok, err = pcall(fn)
		local dt = os.clock() - t0
		report[name] = dt
		print(string.format("[LoadStressTest] %-26s %7.2fs%s", name, dt, if ok then "" else ("  FAILED: " .. tostring(err))))
		return dt
	end

	workspace:SetAttribute("GameSpeed", 0) -- nothing simulates while we build

	-- 1. Flatten the square under the grid (and a margin for the lots).
	local half = blocks * spacing * 0.5 + 64
	local groundY = o.groundY or 6
	local raw = Constants.worldYToRaw(groundY - Constants.RENDER_BULGE)
	phase("flatten terrain", function()
		local g0x = math.max(0, math.floor(Constants.worldToCorner(origin.X - half)))
		local g1x = math.min(Constants.CORNERS_PER_AXIS - 1, math.ceil(Constants.worldToCorner(origin.X + half)))
		local g0z = math.max(0, math.floor(Constants.worldToCorner(origin.Z - half)))
		local g1z = math.min(Constants.CORNERS_PER_AXIS - 1, math.ceil(Constants.worldToCorner(origin.Z + half)))
		local n = 0
		for gz = g0z, g1z do
			for gx = g0x, g1x do
				TerrainDataService.setCorner(gx, gz, raw)
				n += 1
				if n % 50000 == 0 then task.wait() end
			end
		end
	end)

	-- 2 + 3. Roads and zoning, written in the save formats and restored through the normal path.
	local roads, plots = {}, {}
	local zones = { "Residential", "Residential", "Residential", "Commercial", "Residential", "Industrial" }
	local nextId = 0
	local function street(x0: number, z0: number, x1: number, z1: number, major: boolean)
		local y = TerrainDataService.getSurfaceY((x0 + x1) * 0.5, (z0 + z1) * 0.5)
		nextId += 1
		table.insert(roads, { p = { x0, y, z0, x1, y, z1, y, y }, t = if major then "CollectorRoad" else "NarrowRoad", i = nextId })
		for _, side in { 1, -1 } do
			local zone = zones[(nextId + (if side > 0 then 0 else 3)) % #zones + 1]
			table.insert(plots, {
				seg = nextId, side = side, t0 = 0, t1 = 1, zone = zone,
				depth = if zone == "Residential" then 24 else 32,
				den = if zone == "Residential" and nextId % 2 == 0 then "Medium" else nil,
			})
		end
	end
	local x0, z0 = origin.X - blocks * spacing * 0.5, origin.Z - blocks * spacing * 0.5
	for i = 0, blocks do
		for j = 0, blocks - 1 do
			local major = i % 5 == 0
			street(x0 + i * spacing, z0 + j * spacing, x0 + i * spacing, z0 + (j + 1) * spacing, major)
			street(x0 + j * spacing, z0 + i * spacing, x0 + (j + 1) * spacing, z0 + i * spacing, major)
		end
	end
	report.segments = #roads
	report.plotGroups = #plots

	phase("build city (restore)", function()
		local base = CitySerializer.serialize(nil, nil, nil)
		base.roads = roads
		base.lanes = nil
		base.plots = plots
		base.buildings = {}
		base.citizens = nil
		base.traffic = nil
		base.supply = nil
		base.buses = nil
		local ok, err = CitySerializer.restore(base)
		assert(ok, err)
	end)

	phase("move people in", function()
		local pop = 0
		for _ = 1, 200 do
			local res = CitizenService.AdminAddPopulation(math.min(5000, target - pop))
			local added = if typeof(res) == "table" then (res.added or res.residents or 0) else 0
			pop = CitizenService.getPopulation()
			if added <= 0 or pop >= target then break end
			task.wait()
		end
	end)

	local function census(tag: string)
		local city = workspace:FindFirstChild("_City")
		local buildings = 0
		for _ in BuildingService.listBuildings() do buildings += 1 end
		local cars = 0
		local citizens = city and city:FindFirstChild("Citizens")
		if citizens then
			for _, c in citizens:GetChildren() do if c:IsA("Model") then cars += 1 end end
		end
		local pocketed = game:GetService("ServerStorage"):FindFirstChild("PocketedCars")
		local stats = {
			buildings = buildings,
			population = CitizenService.getPopulation(),
			carsInWorld = cars,
			carsPocketed = if pocketed then #pocketed:GetChildren() else 0,
			cityInstances = countDescendants(city),
			workspaceInstances = countDescendants(workspace),
			memoryMb = math.floor(Stats:GetTotalMemoryUsageMb()),
		}
		report[tag] = stats
		print(string.format("[LoadStressTest] %s: %d buildings, %d people, %d cars (+%d pocketed), %d city instances, %d MB",
			tag, stats.buildings, stats.population, stats.carsInWorld, stats.carsPocketed, stats.cityInstances, stats.memoryMb))
	end
	census("after build")

	local blob, packed
	phase("save: serialize", function() blob = CitySerializer.serialize(nil, nil, nil) end)
	phase("save: pack (zstd 19)", function() packed = BlobCodec.pack(blob) end)
	if packed then
		report.blobBytes = buffer.len(packed)
		print(string.format("[LoadStressTest] save blob %s stored (~%s with DataStore overhead; cap 16 MB)",
			fmtBytes(buffer.len(packed)), fmtBytes(buffer.len(packed) * 1.25)))
	end

	-- What a joining client is streamed for its terrain.
	local keys = TerrainDataService.getClientEditedKeys()
	local rawBytes, packedBytes = 0, 0
	local hm = TerrainDataService.getHeightmap()
	local batch = {}
	local function flush()
		if #batch == 0 then return end
		local ok, p = pcall(Codec.pack, batch)
		if ok then packedBytes += buffer.len(p) end
		batch = {}
	end
	for _, key in keys do
		local c = hm:getChunk(Heightmap.decodeKey(key))
		if c then
			rawBytes += buffer.len(c.heights) + buffer.len(c.materials) + buffer.len(c.flags)
			table.insert(batch, { key = key, h = c.heights, m = c.materials, f = c.flags })
			if #batch >= 32 then flush() end
		end
	end
	flush()
	report.editedChunks = #keys
	report.terrainStreamRaw = rawBytes
	report.terrainStreamPacked = packedBytes
	print(string.format("[LoadStressTest] terrain stream: %d edited chunks, raw %s, packed %s",
		#keys, fmtBytes(rawBytes), fmtBytes(packedBytes)))

	for r = 1, reloads do
		local unpacked
		phase("load " .. r .. ": unpack", function() unpacked = BlobCodec.unpack(packed) end)
		phase("load " .. r .. ": restore", function()
			local ok, err = CitySerializer.restore(unpacked)
			assert(ok, err)
		end)
		census("after load " .. r)
	end

	print("[LoadStressTest] done. Save from the game menu, rejoin and CONTINUE to time the client side.")
	return report
end

return LoadStressTest
