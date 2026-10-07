--!strict
return function()
	it("draws only the footway sides belonging to the predicted road type", function()
		local module = script.Parent
		local catalog = game.ReplicatedStorage.Road.RoadTypeCatalog
		local loader = assert(loadstring(module.Source))
		setfenv(loader, setmetatable({ script = module, require = function(target: Instance): any
			if target == catalog then
				return { getOrDefault = function() return { width = 20 } end,
					footwaySides = function() return 0, 4 end, footwayWidth = function() return 4 end }
			end
			return require(target)
		end }, { __index = getfenv() }))
		local geometry = loader()
		local model = Instance.new("Model")
		local ok, count = geometry.draw(model, { roadType = "one-sided", p0 = Vector3.zero,
			p1 = Vector3.new(0,0,-6), p2 = Vector3.new(0,0,-12), p3 = Vector3.new(0,0,-18) }, nil, 5)
		assert(ok and count == 2, "predicted road gained a second footway")
		local sidewalk: BasePart? = nil
		for _,part in model:GetChildren() do
			if (part :: BasePart).Size.X == 4 then sidewalk = part :: BasePart end
		end
		assert(sidewalk and sidewalk.Position.X == 12, "footway moved to the wrong kerb")
		model:Destroy()
	end)
end
