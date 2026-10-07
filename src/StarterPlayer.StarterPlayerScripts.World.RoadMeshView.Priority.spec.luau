--!strict
return function()
	local view = script.Parent
	local function pop(queue: {any}, hidden: {[string]: boolean}?): any
		local first = assert(view.Source:find("local function popBakeJob()", 1, true))
		local last = assert(view.Source:find("\nlocal function enqueue(", first, true))
		local loader = assert(loadstring(view.Source:sub(first, last - 1) .. "\nreturn popBakeJob()"))
		local cells = {
			near = { center = Vector3.zero },
			far = { center = Vector3.new(1000, 0, 0) },
			lot = { center = Vector3.zero },
			detail = { center = Vector3.zero },
		}
		setfenv(loader, setmetatable({
			_bakeQueue = queue, _cells = cells, _predictionHidden = hidden or {},
			workspace = { CurrentCamera = { CFrame = CFrame.new() } },
			isLotKey = function(key: string): boolean return key == "lot" end,
			centreOf = function(): Vector3 return Vector3.zero end,
		}, { __index = getfenv() }))
		return loader()
	end
	it("bakes camera-near roads before distant roads and lot decoration", function()
		local selected = pop({ { key = "lot" }, { key = "far" }, { key = "detail", detailsOnly = true }, { key = "near" } })
		assert(selected.key == "near", "visible road waited behind distant geometry")
	end)
	it("finishes a pending road edit before unrelated initial city bakes", function()
		local selected = pop({ { key = "near" }, { key = "far" } }, { far = true })
		assert(selected.key == "far", "accepted edit waited behind initial city geometry")
	end)
end
