--!strict
return function()
	local function harness(): any
		local source = script.Parent.Source
		local start = assert(string.find(source, "local function onPlaceResult", 1, true))
		local finish = assert(string.find(source, "local function onClick", start, true))
		local applied: { any } = {}
		local env = setmetatable({
			_inFlight = {}, _chainGen = 1, _phase = "Idle",
			applyState = function(state) table.insert(applied, state) end,
			notify = function() end, warn = function() end,
			NotificationController = { Notify = function() end },
		}, { __index = getfenv() })
		local fn = assert(loadstring(string.sub(source, start, finish - 1) .. "\nreturn onPlaceResult"))
		setfenv(fn, env)
		return { result = fn(), env = env, applied = applied }
	end
	describe("placement result correlation", function()
		it("ignores untagged results while only tagged placements are pending", function()
			local h = harness()
			h.env._inFlight = { { token = 17, gen = 1 } }
			h.result(false, "unrelated result", "place", nil)
			assert(#h.env._inFlight == 1, "untagged result consumed a tagged placement")
		end)
		it("matches out-of-order results to their own request", function()
			local h = harness()
			h.env._inFlight = { { token = 17, gen = 1 }, { token = 18, gen = 1 } }
			h.result(true, nil, "place", 18)
			assert(#h.env._inFlight == 1 and h.env._inFlight[1].token == 17, "wrong placement consumed")
		end)
		it("ignores edit results and retains untagged roundabout completion", function()
			local h = harness()
			local state = { phase = "Idle" }
			h.env._inFlight = { { token = nil, gen = 1, nextState = state } }
			h.result(false, nil, "edit", nil)
			assert(#h.env._inFlight == 1, "edit consumed roundabout flight")
			h.result(true, nil, "place", nil)
			assert(#h.env._inFlight == 0 and h.applied[1] == state, "roundabout result was lost")
		end)
	end)
end
