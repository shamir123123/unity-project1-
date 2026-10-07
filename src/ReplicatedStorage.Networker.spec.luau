--!strict
return function()
	local function run(source: string, running: boolean, withFolder: boolean): (boolean, any, { number })
		local waits: { number } = {}
		local clock = 0
		local folder = {
			FindFirstChild = function() return nil end,
			WaitForChild = function(_self: any, _name: string, timeout: number?)
				waits[#waits + 1] = timeout or -1
				return { IsA = function() return true end }
			end,
			IsA = function(_self: any, name: string) return name == "Folder" end,
		}
		local storage = {
			WaitForChild = function(_self: any, _name: string, timeout: number?)
				waits[#waits + 1] = timeout or -1
				clock = 10
				return if withFolder then folder else nil
			end,
		}
		local env = setmetatable({
			game = { GetService = function(_self: any, name: string)
				if name == "ReplicatedStorage" then return storage end
				return { IsServer = function() return false end, IsRunning = function() return running end }
			end },
			os = { clock = function() return clock end },
		}, { __index = getfenv() })
		local chunk = assert(loadstring(source))
		setfenv(chunk, env)
		local ok, result = pcall(chunk)
		return ok, result, waits
	end

	describe("Networker startup", function()
		it("bounds the folder wait and reports the missing server bootstrap", function()
			local ok, err, waits = run(script.Parent.Source, true, false)
			assert(not ok, "missing server folder must fail")
			assert(waits[1] == 30, "client folder wait was unbounded")
			assert(string.find(tostring(err), "check server Bootstrap", 1, true), "missing startup diagnostic")
		end)
		it("does not wait for runtime networking in Edit-mode tests", function()
			local ok, _err, waits = run(script.Parent.Source, false, false)
			assert(not ok and #waits == 0, "Edit-mode require waited for remotes")
		end)
		it("waits for child replication within one startup deadline", function()
			local ok, err, waits = run(script.Parent.Source, true, true)
			assert(ok, tostring(err))
			assert(#waits > 1 and waits[2] == 20, "children did not share the remaining startup deadline")
			for _, timeout in waits do assert(timeout >= 0 and timeout <= 30) end
		end)
	end)
end
