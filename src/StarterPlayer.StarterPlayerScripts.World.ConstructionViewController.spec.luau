--!strict
return function()
	it("draws 1000 sites without cranes or per-site frame connections", function()
		local target = game.StarterPlayer.StarterPlayerScripts.World.ConstructionViewController
		local root = Instance.new("Folder")
		local receiver: ((any) -> ())? = nil
		local frameConnections = 0
		local remote = { OnClientEvent = { Connect = function(_self: any, fn: (any) -> ())
			receiver = fn
			return { Disconnect = function() receiver = nil end }
		end } }
		local rs = game:GetService("ReplicatedStorage")
		local env = setmetatable({
			game = { GetService = function(_self: any, name: string): any
				if name == "RunService" then
					return { Heartbeat = { Connect = function()
						frameConnections += 1
						return { Disconnect = function() frameConnections -= 1 end }
					end } }
				end
				return game:GetService(name)
			end },
			require = function(module: ModuleScript): any
				if module.Name == "UiScratch" then return { folder = function() return root end } end
				if module.Name == "Networker" then return { SyncConstructionSites = remote } end
				if module.Name == "GameSpeed" then return { scaled = function(dt: number) return dt end } end
				return require(module)
			end,
			script = target,
		}, { __index = getfenv() })
		local loader = assert(loadstring(target.Source))
		setfenv(loader, env)
		local view = loader()
		view.Start()
		local started = os.clock()
		local ok, err = pcall(function()
			for i = 1, 1000 do
				assert(receiver)({kind="nest", id=tostring(i), pivot=CFrame.new(i*40, 0, 0), width=2, depth=2})
			end
			assert(frameConnections == 0, "construction creates a frame connection for each site")
			assert(#root:GetDescendants() <= 2000, "construction still clones heavyweight site geometry")
			assert(receiver)({kind="start", id="1", pivot=CFrame.identity, width=2, depth=2})
			assert(receiver)({kind="finish", id="1"})
		end)
		print(string.format("[PerfConstruction] 1000 sites %.3fs; frame connections %d; instances %d", os.clock()-started, frameConnections, #root:GetDescendants()))
		view.Cleanup()
		root:Destroy()
		assert(ok, err)
	end)
end