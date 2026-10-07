--!strict
return function()
	local module = script.Parent
	local terrainData = module.Parent.TerrainDataService
	local TerrainConstants = require(game.ReplicatedStorage.Terrain.TerrainConstants)
	local Heightmap = require(game.ReplicatedStorage.Terrain.Heightmap)
	local Ledger = require(module.Parent.TerrainOverlayLedger)
	local function fixture(): (any, () -> number)
		local hm = Heightmap.new()
		local led = Ledger.new(hm)
		local yields, clock = 0, 0
		local mock = {
			getHeightmap = function() return hm end,
			getOverlayLedger = function() return led end,
			markDryCornerKeys = function() end,
		}
		local loader = assert(loadstring(module.Source))
		setfenv(loader, setmetatable({
			script = module,
			require = function(target: Instance): any
				return if target == terrainData then mock else require(target)
			end,
			os = setmetatable({ clock = function(): number clock += 0.001 return clock end }, { __index = os }),
			task = setmetatable({ wait = function(): number yields += 1 return 0 end }, { __index = task }),
		}, { __index = getfenv() }))
		return loader(), function() return yields end
	end
	local function grade(service: any, id: number): ()
		local p0 = Vector3.new(0, 30, 0)
		local p3 = Vector3.new(300, 30, 200)
		service.gradeSegment({ id = id, roadType = "Highway", vMode = "Ground", startNode = 1, endNode = 2,
			p0 = p0, p1 = p0:Lerp(p3, 1/3), p2 = p0:Lerp(p3, 2/3), p3 = p3 })
	end

	it("reduces frame waits during city loading without removing them", function()
		local normal, normalYields = fixture()
		grade(normal, 1)
		local loading, loadYields = fixture()
		loading.setLoading(true)
		grade(loading, 1)
		assert(loadYields() > 0, "load work must still yield")
		assert(loadYields() < normalYields() * 0.6, "loading budget never reached grading loop")
	end)

	it("restores the interactive work budget after loading", function()
		local normal, normalYields = fixture()
		grade(normal, 1)
		local restored, restoredYields = fixture()
		restored.setLoading(true)
		restored.setLoading(false)
		grade(restored, 1)
		assert(restoredYields() == normalYields(), "interactive budget not restored")
	end)
end
