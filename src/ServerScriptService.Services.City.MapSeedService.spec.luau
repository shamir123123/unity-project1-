--!strict
return function()
	it("defers nature without losing the starting junction", function()
		local source = game.ServerScriptService.Services.City.MapSeedService.Source
		local first = assert(source:find("function MapSeedService.seed(gen:", 1, true))
		local last = assert(source:find("\nreturn MapSeedService", first, true))
		local calls = 0
		local service: any = {
			seedHighways = function() return {} end,
			seedStartJunction = function() return Vector3.new(1, 2, 3) end,
			seedNature = function() calls += 1 end,
		}
		local fn = assert(loadstring(source:sub(first, last - 1)))
		setfenv(fn, setmetatable({ MapSeedService = service }, { __index = getfenv() }))
		fn()
		local startAt, tail = service.seed({ seed = 5.5 }, 2, true)
		assert(startAt == Vector3.new(1, 2, 3))
		assert(calls == 0, "nature still blocks city entry")
		assert(type(tail) == "function", "deferred nature was discarded")
		tail()
		assert(calls == 1)
		service.seed({ seed = 5.5 }, 0)
		assert(calls == 2, "ordinary callers must still receive the whole map")
	end)
end