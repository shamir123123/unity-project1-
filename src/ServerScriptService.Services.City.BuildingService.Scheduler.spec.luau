--!strict
return function()
	local function fixture(): any
		local source = script.Parent.Source
		local first = assert(source:find("local CONSTRUCTION_POLL_SECONDS", 1, true))
		local last = assert(source:find("local function newBlueprintId", first, true))
		local now, speed, spawned = 0, 1, 0
		local worker: thread? = nil
		local env = setmetatable({
			ConstructionQueue = require(script.Parent.ConstructionQueue),
			GameSpeed = { get = function() return speed end },
			os = setmetatable({ clock = function() return now end }, { __index = os }),
			task = { defer = function(fn: () -> ())
				spawned += 1
				worker = coroutine.create(fn)
				local ok, err = coroutine.resume(worker :: thread)
				assert(ok, tostring(err))
			end, wait = function() coroutine.yield() end },
			warn = function() end,
		}, { __index = getfenv() })
		local loader = assert(loadstring(source:sub(first, last - 1) .. "\nreturn scheduleConstruction"))
		setfenv(loader, env)
		return {
			schedule = loader(),
			setSpeed = function(value: number) speed = value end,
			advance = function(seconds: number)
				now += seconds
				if worker and coroutine.status(worker) ~= "dead" then
					local ok, err = coroutine.resume(worker)
					assert(ok, tostring(err))
				end
			end,
			spawns = function() return spawned end,
		}
	end
	local valid = function(): boolean return true end
	local failed = function() error("unexpected construction failure") end

	it("holds deadlines while paused and advances them at simulation speed", function()
		local f = fixture()
		local complete = false
		f.schedule(10, valid, function() complete = true end, failed)
		f.setSpeed(0)
		f.advance(100)
		assert(not complete, "paused construction completed")
		f.setSpeed(2)
		f.advance(4)
		assert(not complete, "construction completed before its simulation deadline")
		f.advance(1)
		assert(complete)
	end)

	it("ignores cancelled work without stopping other sites", function()
		local f = fixture()
		local completed = 0
		f.schedule(1, function() return false end, function() error("cancelled site ran") end, failed)
		f.schedule(1, valid, function() completed += 1 end, failed)
		f.advance(1)
		assert(completed == 1 and f.spawns() == 1)
	end)

	it("cleans a failed step and continues the queue", function()
		local f = fixture()
		local cleaned, completed = false, false
		f.schedule(1, valid, function() error("fixture failure") end, function() cleaned = true end)
		f.schedule(1, valid, function() completed = true end, failed)
		f.advance(1)
		assert(cleaned and completed, "one failing site stranded the queue")
	end)

	it("does not charge idle wall time to a newly scheduled site", function()
		local f = fixture()
		local completed = 0
		f.schedule(1, valid, function() completed += 1 end, failed)
		f.advance(1)
		f.advance(100)
		f.schedule(2, valid, function() completed += 1 end, failed)
		assert(completed == 1 and f.spawns() == 2)
		f.advance(1)
		assert(completed == 1)
		f.advance(1)
		assert(completed == 2)
	end)
end


