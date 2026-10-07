--!strict
-- Isolated test dependency: fresh controller source, deterministic clock, no live city writes.
return function(corridorEnabled: boolean?, actual: any?): any
	local controller = script.Parent
	local traffic = controller.Parent
	local now = 0
	local heartbeat: any = nil
	local topology: { any } = {}
	local delayed: { () -> () } = {}
	local reversed = false
	local version = 1
	local plan = { custom = false, coordPhase = 1, offset = 0 }
	local corridor = if corridorEnabled then { id = "test", cycle = 30, autoOffsets = false, nodeIds = { 1, 2 } } else nil
	local graph = {
		HasEdges = function() return true end,
		Version = function() return version end,
		GetEdgeCongestion = function() return 0 end,
		SetControlDelaySnapshot = function() end,
	}
	local network = {
		getSegments = function() return { [1] = {} } end,
		getNodes = function() return { [1] = { position = Vector3.zero }, [2] = { position = Vector3.xAxis * 100 } } end,
		getSegment = function() return nil end,
	}
	if actual then
		graph, network = actual.graph, actual.network
	end
	local function arm(id: number, edges: { string }, dedicated: { string }): any
		return { segmentId = id, inEdges = edges, throughEdges = edges, dedicatedLeftEdges = dedicated,
			dir = Vector3.xAxis, axis = "NS" }
	end
	local geometry = { nodeId = 1, pos = Vector3.zero, arms = {
		arm(1, { "north", "left" }, { "left" }), arm(2, { "south" }, {}), arm(3, { "east" }, {}),
	} }
	local function phase(kind: string, label: string, ids: { string }): any
		local edges, allowed = {}, {}
		for _, id in ids do edges[id] = true; allowed[id] = { [id .. "Out"] = true } end
		return { kind = kind, label = label, greenEdges = edges, allowedConnections = allowed, greenArms = {}, leftArms = {} }
	end
	local road = {
		getNavigationGraph = function() return graph end,
		getNetwork = function() return network end,
		onTopologyChanged = function(fn: any): () -> ()
			local entry = { fn = fn, active = true }
			table.insert(topology, entry)
			return function() entry.active = false end
		end,
	}
	local function compile(module: ModuleScript, overrides: any): any
		local chunk, err = loadstring(module.Source, module:GetFullName())
		assert(chunk, err)
		local env = setmetatable(overrides, { __index = getfenv() })
		env.script = module
		setfenv(chunk :: any, env)
		return (chunk :: any)()
	end
	local config = compile(traffic.TrafficConfig, {
		require = function() return { WORLD_SCALE = 0.5 } end,
	})
	local dependencies: { [string]: any } = {
		GameSpeed={get=function()return 1 end,steps=function()return 1 end},
		IntersectionDetector = { detect = function()
			local geometries = { [1] = geometry }
			if corridor then
				local second = table.clone(geometry)
				second.nodeId = 2
				geometries[2] = second
			end
			return geometries
		end },
		SignalPhaseBuilder = { build = function(input: any)
			local ns, ew = phase("through", "NS", { "north", "south" }), phase("through", "EW", { "east" })
			local phases = { if reversed then ew else ns, if reversed then ns else ew,
				phase("left", "Left", { "left" }), phase("ped", "Ped", {}) }
			if input.nodeId == 2 then
				table.insert(phases, phase("left", "ExtraLeft", { "extraLeft" }))
				table.insert(phases, phase("left", "OtherLeft", { "otherLeft" }))
			end
			return { phases = phases, hasPed = true, pedConcurrent = false }
		end },
		TrafficLightPlacer = { COLOR_RED = 0, COLOR_YELLOW = 1, COLOR_GREEN = 2,
			Init = function() end, SyncNode = function() end, SetArmColor = function() end,
			RemoveNode = function() end, Clear = function() end },
		TrafficConfig = config,
		SignalPlanStore = { Init = function() end, reconcile = function() end, allGroups = function() return if corridor then { test = corridor } else {} end,
			planFor = function() return plan end, groupOf = function() return corridor end,
			onChanged = function() return function() end end },
		SignalCoordinator = {}, SignalSpec = {},
		NavCost = { websterDelay = function() return 0 end },
		RoadRules = { setControlOverride = function() end, setPriorityOverride = function() end },
		RoadTypeCatalog = {},
	}
	if actual then
		dependencies.IntersectionDetector = actual.detector
		dependencies.SignalPhaseBuilder = actual.builder
	end
	dependencies.SignalCoordinator = compile(traffic.SignalCoordinator, {
		require = function(module: Instance) return dependencies[module.Name] end,
	})
	local mockRun = { Heartbeat = { Connect = function(_self: any, fn: any): any
		heartbeat = fn
		return { Disconnect = function() heartbeat = nil end }
	end } }
	local mockGame = { GetService = function(_self: any, name: string): any
		if name == "RunService" then return mockRun end
		return game:GetService(name)
	end }
	local service = compile(controller, {
		game = mockGame,
		workspace = { GetAttribute = function() return 1 end },
		os = { clock = function() return now end },
		task = {
			delay = function(_seconds: number, fn: () -> ()) table.insert(delayed, fn) end,
			spawn = function() error("unexpected async startup") end,
		},
		require = function(module: Instance): any
			local result = dependencies[module.Name]
			assert(result, "unexpected dependency " .. module:GetFullName())
			return result
		end,
	})
	service.Init(road)
	service.Bind()
	service.Start()
	local function step(dt: number)
		now += dt
		assert(heartbeat, "missing heartbeat")(dt)
	end
	return {
		service = service, road = road, step = step,
		untilState = function(label: string, state: string)
			for _ = 1, 3000 do
				local row = service.GetDebugSnapshot()[1]
				if row.phaseLabel == label and row.state == state then return end
				step(0.1)
			end
			error("phase never reached: " .. label .. "/" .. state)
		end,
		rebuild = function(changeOrder: boolean)
			reversed = changeOrder
			version += 1
			for _, entry in topology do if entry.active then entry.fn() end end
			local callbacks = delayed
			delayed = {}
			for _, fn in callbacks do fn() end
		end,
		listenerCount = function(): number
			local count = 0
			for _, entry in topology do if entry.active then count += 1 end end
			return count
		end,
	}
end

