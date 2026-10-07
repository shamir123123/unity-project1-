--!strict
return function()
	it("schedules 3000 zoned lots with one worker", function()
		local source = script.Parent.Source
		local schedulerStart = source:find("local CONSTRUCTION_POLL_SECONDS", 1, true)
			or assert(source:find("local function waitGameSeconds", 1, true))
		local schedulerEnd = assert(source:find("local function newBlueprintId", schedulerStart, true))
		local first = assert(source:find("function BuildingService.developPlot(", 1, true))
		local last = assert(source:find("-- Placeable-building catalog", first, true))
		local spawns, nextId = 0, 0
		local template = Instance.new("Model")
		local env = setmetatable({
			BuildingService = {}, ConstructionQueue = require(script.Parent.ConstructionQueue),
			_bldgFolder = true, _activeConstruction = {}, _restoreState = {},
			LOT_SIZE = 6, RESTORE_OVERLAP_TOL = 0.01, FOOTPRINT_TOL = 0.01,
			CONSTRUCTION_POLL_SECONDS = 0.1,
			GameSpeed = { get = function() return 1 end },
			task = { defer = function(_fn: () -> ()) spawns += 1 end },
			houseLots = function(_zone: string, w: number, d: number) return w, d end,
			getTemplateFolder = function() return template end,
			plotFootprintBlocked = function() return false end,
			seatY = function(y: number) return y end,
			newBlueprintId = function() nextId += 1 return tostring(nextId) end,
			setFootprint = function() end, makeFootprint = function() return {} end,
			constructionSeconds = function() return 30 end,
			saveKeyForPivot = function() return "unused" end,
			pickTemplate = function() return template end,
			scriptedTemplate = function() return false end,
			addSiteMarker = function() end,
		}, { __index = getfenv() })
		local loader = assert(loadstring(source:sub(schedulerStart, schedulerEnd-1) .. "\n" .. source:sub(first, last-1)))
		setfenv(loader, env)
		loader()
		for i = 1, 3000 do
			assert(env.BuildingService.developPlot(CFrame.new(i*40,0,0), "Residential", 2, 2, "grow", 1))
		end
		template:Destroy()
		assert(spawns == 1, string.format("3000 lots created %d workers", spawns))
	end)
end

