--!strict
return function()
	local function fixture()
		local source = script.Parent.Source
		local start = assert(source:find("function RoadService.waitForPendingEdits", 1, true))
		local finish = assert(source:find("function RoadService.restoreRoads", start, true))
		local now, idle, renders, waits = 0, false, 0, 0
		local env = setmetatable({
			RoadService = { waitForRender = function(remaining) renders += 1;return remaining >= 0 end },
			RoadReplicationService = { isEditIdle = function() return idle end },
			os = { clock = function() return now end },
			task = { wait = function() waits += 1;now += .1 end },
		}, { __index = getfenv() })
		local loader = assert(loadstring(source:sub(start, finish - 1)))
		setfenv(loader, env);loader()
		return {
			wait = env.RoadService.waitForPendingEdits,
			releaseAfterWait = function()
				env.task.wait = function() waits += 1;now += .1;idle = true end
			end,
			state = function() return now, renders, waits end,
		}
	end
	it("waits for accepted edits before draining their deferred render passes", function()
		local f = fixture()
		f.releaseAfterWait()
		assert(f.wait(1), "completed edit drain failed")
		local now, renders, waits = f.state()
		assert(now > 0 and waits == 1 and renders == 1, "edit lifetime was skipped or render drain was omitted")
	end)
	it("fails within the deadline without proceeding to render or teardown", function()
		local f = fixture()
		assert(not f.wait(.2), "hung edit did not reject city teardown")
		local now, renders, waits = f.state()
		assert(now >= .2 and now < .4 and renders == 0 and waits <= 3, "edit drain ignored its bound")
	end)
end
