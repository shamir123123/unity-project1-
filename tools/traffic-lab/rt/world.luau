--!nocheck
-- Boots the traffic stack (RoadNetwork, RoadNavigationGraph, PathFollower, NPCDriverService,
-- TrafficSignalService) on the headless engine and offers helpers to build test cities and
-- spawn directed cars. One World per process (modules are singletons).

local E = require("./engine")
local roblox = E.roblox
local V3 = roblox.Vector3
local CF = roblox.CFrame

local W = {}
W.E = E
W.V3 = V3
W.CF = CF

local process = require("@lune/process")
local SRC = process.env.LAB_SRC or "../src"
math.randomseed(tonumber(process.env.LAB_SEED) or 1)
E.mountSources(SRC)

-- Patched sources (our fixes) shadow the originals when LAB_PATCH points at a tree.
local PATCH = process.env.LAB_PATCH
if PATCH and PATCH ~= "" then
	local fs = require("@lune/fs")
	local function walk(dir, rel)
		for _, name in fs.readDir(dir) do
			local full = dir .. "/" .. name
			if fs.isDir(full) then
				walk(full, if rel == "" then name else rel .. "/" .. name)
			elseif name:sub(-5) == ".luau" then
				local base = name:gsub("%.server%.luau$", ""):gsub("%.client%.luau$", ""):gsub("%.luau$", "")
				local dotted = (if rel == "" then base else rel .. "/" .. base):gsub("/", ".")
				local ok = pcall(E.overrideSource, dotted, full)
				if not ok then
					-- New module: mount it.
					local parts = string.split(dotted, ".")
					local node = E.services[table.remove(parts, 1)]
					local leaf = table.remove(parts)
					for _, p in parts do
						local c = node:FindFirstChild(p)
						if not c then c = E.Instance.new("Folder"); c.Name = p; c.Parent = node end
						node = c
					end
					local m = E.Instance.new("ModuleScript"); m.Name = leaf; m.SourcePath = full; m.Parent = node
				end
			end
		end
	end
	walk(PATCH, "")
end

-- == Stubs ====================================================================
local function noop() end
local remoteStub = setmetatable({}, { __index = function(t, k)
	local r = { FireClient = noop, FireAllClients = noop, FireServer = noop,
		OnServerEvent = E.Signal.new(), OnClientEvent = E.Signal.new(), OnServerInvoke = nil }
	rawset(t, k, r)
	return r
end })
remoteStub.WaitForRemote = function(_, name) return remoteStub[name] end
E.stubs["ReplicatedStorage.Networker"] = remoteStub
E.stubs["ReplicatedStorage.NetMiddleware"] = {
	FireQueued = noop, FireQueuedClient = noop, WrapClientReceive = function(f) return f end,
	ThrottledFireServer = noop, RegisterServerRateLimit = noop, CheckServerRate = function() return true end,
	OnPlayerRemoving = noop, GetCachedAttribute = function(i, k) return i:GetAttribute(k) end,
	InvalidateCachedAttribute = noop,
}
local speed = 1
E.stubs["ReplicatedStorage.GameSpeed"] = {
	get = function() return speed end, steps = function() return speed end,
	scaled = function(dt) return dt * speed end, isPaused = function() return speed <= 0 end,
}
function W.setSpeed(s) speed = s end

-- Vehicles: a Model with a sized Hitbox primary part. Sizes from VehicleCatalog would need
-- the asset folders; the lab uses typical civilian dimensions (half-scale world).
local vehicleN = 0
local VehicleFactory = {}
function VehicleFactory.build(name, _variant, size)
	vehicleN += 1
	if typeof(size) == "string" then size = if size:find("Artic") then V3.new(5, 4, 36) elseif size:find("Bus") then V3.new(5, 4, 24) else nil end
	local m = E.Instance.new("Model")
	m.Name = name or "Car"
	local hb = E.Instance.new("Part")
	hb.Name = "Hitbox"
	hb.Size = size or V3.new(3.6, 3, 9)
	hb.Parent = m
	m.PrimaryPart = hb
	m:SetAttribute("NPCHeightOffset", 0.8)
	return m
end
VehicleFactory.RIDE_CLEARANCE = 0.05
E.stubs["ServerScriptService.Services.NPC.VehicleFactory"] = VehicleFactory
W.VehicleFactory = VehicleFactory

-- Workspace attributes the road rules read.
E.Workspace:SetAttribute("DrivingSide", "Right")
E.Workspace:SetAttribute("RandomTrafficEnabled", false)

-- == Load the stack ===========================================================
local RS = E.services.ReplicatedStorage
local SSS = E.services.ServerScriptService

function W.req(dotted)
	local inst = E.resolve(dotted)
	assert(inst, "no module " .. dotted)
	return E.require(inst)
end

W.RoadConstants = W.req("ReplicatedStorage.Road.RoadConstants")
W.RoadNetwork = W.req("ReplicatedStorage.Road.RoadNetwork")
W.Graph = W.req("ReplicatedStorage.Road.RoadNavigationGraph")
W.PathFollower = W.req("ServerScriptService.Services.Util.PathFollower")

-- NPCDriverService with its internals exposed for measurement.
local driverInst = E.resolve("ServerScriptService.Services.NPC.NPCDriverService")
W.Driver = E.requireWith(driverInst, function(src)
	if process.env.LAB_DIAG == "1" then
		src = src:gsub("\nlocal function canEnterIntersection%(", [[

NPCDriverService._diag = {}
do
	local function wrap(name, f)
		return function(...)
			local r = f(...)
			local key = name .. (if r then "+" else "-")
			NPCDriverService._diag[key] = (NPCDriverService._diag[key] or 0) + 1
			return r
		end
	end
	roundaboutClear = wrap("roundaboutClear", roundaboutClear)
	ringHasRoom = wrap("ringHasRoom", ringHasRoom)
	boxHasConflict = wrap("boxHasConflict", boxHasConflict)
	owesCourtesy = wrap("owesCourtesy", owesCourtesy)
	signalizedClear = wrap("signalizedClear", signalizedClear)
	unsignalizedClear = wrap("unsignalizedClear", unsignalizedClear)
end
local function canEnterIntersection(]], 1)
	end
	return (src:gsub("table%.freeze%(Tuning%)%s*return NPCDriverService%s*$", [[
NPCDriverService._lab = { drivers = function() return _drivers end, tuning = Tuning,
	nodeMeta = getNodeMeta, exitRoom = exitLaneHasRoom, queueLeader = getNearestQueueLeader,
	simClock = function() return _simClock end }
table.freeze(Tuning)
return NPCDriverService]]))
end)
W.Signals = W.req("ServerScriptService.Services.Traffic.TrafficSignalService")

-- CitizenService with its trip legs exposed (pull-out / road / pull-in), on stub services.
function W.loadCitizens()
	local inst = E.resolve("ServerScriptService.Services.City.Simulation.CitizenService")
	local C = E.requireWith(inst, function(src)
		return (src:gsub("return CitizenService%s*$", [[
CitizenService._lab = { driveTo = driveTo, stepTrips = stepTrips, trips = _trips, cars = Cars, garage = Garage }
return CitizenService]]))
	end)
	local stub = setmetatable({}, { __index = function() return function() return nil end end })
	local walking = { bodyCount = function() return 0 end, spawnCommuter = function(_, _, done) task.defer(done); return 1 end,
		despawnCommuter = function() end, isBuilt = function() return true end }
	C.Init(W.RoadService, stub, stub, stub, { onSpotsChanged = function() end }, walking, stub, stub)
	W.Citizens = C
	-- drive the off-graph legs like CitizenService.Start does
	local acc = 0
	E.RunService.Heartbeat:Connect(function(dt)
		acc += math.min(dt, 0.1)
		if acc < 1 / 20 then return end
		local sdt = math.min(acc, 0.1)
		acc = 0
		local ok, err = pcall(C._lab.stepTrips, sdt)
		if not ok then table.insert(E.errors, "stepTrips: " .. tostring(err)) end
	end)
	return C
end

-- == Road service facade ======================================================
local net, graph = nil, nil
local topoListeners = {}
local RoadService = {}
function RoadService.getNavigationGraph() return graph end
function RoadService.getNetwork() return net end
function RoadService.onTopologyChanged(fn)
	table.insert(topoListeners, fn)
	return function() local i = table.find(topoListeners, fn); if i then table.remove(topoListeners, i) end end
end
function RoadService.getTurnPermissions() return {} end
W.RoadService = RoadService

function W.newCity()
	net = W.RoadNetwork.new()
	graph = W.Graph.new(function(seg)
		local spec = W.req("ReplicatedStorage.Road.RoadTypeCatalog").getOrDefault(seg.roadType)
		return not spec.isRail
	end)
	W.net, W.graph = net, graph
	return net
end

function W.rebuild(perms)
	graph:Rebuild(net, perms or {})
	for _, fn in topoListeners do fn(nil) end
	return graph
end

-- Straight segment helper (cubic with thirds handles).
function W.road(a, b, kind)
	local d = b - a
	return net:addSegment(a, a + d / 3, a + d * 2 / 3, b, kind or "Road")
end

local booted = false
function W.boot(opts)
	opts = opts or {}
	if booted then return end
	booted = true
	W.Driver.Init(RoadService)
	if opts.signals ~= false then
		W.Signals.Init(RoadService)
		if W.Signals.SetQueueProvider then W.Signals.SetQueueProvider(W.Driver.GetSignalQueue) end
	end
	W.Driver.Bind()
	if opts.signals ~= false then pcall(W.Signals.Bind) end
	W.Driver.Start()
	if opts.signals ~= false then W.Signals.Start() end
	-- A viewer at the city centre so cars run full-rate AI (not the 2 Hz distant LOD).
	if opts.viewer ~= false then
		local p = E.addPlayer("Viewer")
		W.PathFollower.setCameraPos(p, opts.viewerPos or V3.new(0, 300, 0), opts.viewerPos or V3.zero)
	end
end

-- Directed car from A to B along the graph. Returns the model (or nil if it could not start).
local tripId = 0
W.trips = {}
function W.spawnTrip(fromPos, toPos, opts)
	opts = opts or {}
	local _, route = graph:FindPath(fromPos, toPos, opts.allowCrossing, opts.class, opts.profile)
	if not route or #route == 0 then return nil, "noroute" end
	tripId += 1
	local car = VehicleFactory.build("LabCar" .. tripId, nil, opts.size)
	local folder = E.Workspace:FindFirstChild("_City")
	if not folder then folder = E.Instance.new("Folder"); folder.Name = "_City"; folder.Parent = E.Workspace end
	local cars = folder:FindFirstChild("LabCars")
	if not cars then cars = E.Instance.new("Folder"); cars.Name = "LabCars"; cars.Parent = folder end
	car.Parent = cars
	if opts.class then E.CollectionService:AddTag(car, opts.class) end
	if opts.entrySpeed then car:SetAttribute("NPCEntrySpeed", opts.entrySpeed) end
	local rec = { id = tripId, car = car, from = fromPos, to = toPos, started = E.now, route = route }
	local ok = W.Driver.DriveDirected(car, fromPos, toPos, route, function()
		rec.arrived = E.now
		W.onArrive(rec)
	end, function()
		rec.aborted = E.now
		W.onAbort(rec)
	end)
	if not ok then car:Destroy(); return nil, "blocked" end
	W.trips[car] = rec
	return car, rec
end
W.arrivals, W.aborts = {}, {}
function W.onArrive(rec)
	table.insert(W.arrivals, rec)
	W.trips[rec.car] = nil
	rec.car:Destroy()
end
function W.onAbort(rec)
	table.insert(W.aborts, rec)
	W.trips[rec.car] = nil
	rec.car:Destroy()
end

-- Advance the world by `seconds` of game time at `fps` frames per second. Returns the real
-- (wall-clock) seconds spent inside the driver tick.
function W.run(seconds, fps, onFrame)
	fps = fps or 30
	local dt = 1 / fps
	local frames = math.floor(seconds * fps + 0.5)
	local real0 = E.realClock()
	for i = 1, frames do
		E.step(dt)
		if onFrame then onFrame(i, dt) end
	end
	return E.realClock() - real0
end

-- Collision census: pairs of driving cars whose bodies overlap (oriented rectangles,
-- shrunk by 10% so touching bumpers in a queue do not count). Counted once per pair per
-- second of overlap. Grid-bucketed so it stays cheap.
W.collisions = { events = 0, pairs = {}, samples = {} }
function W.checkCollisions()
	local drivers = W.Driver._lab.drivers()
	local cell = 24
	local grid = {}
	local list = {}
	for model, s in drivers do
		local cf = s.smoothCFrame
		if cf and model.Parent then
			local size = model:GetExtentsSize()
			local half = math.max(size.X, size.Z) * 0.45
			local width = math.min(size.X, size.Z) * 0.45
			local e = { m = model, p = cf.Position, f = cf.LookVector, half = half, width = width, s = s }
			table.insert(list, e)
			local k = math.floor(e.p.X / cell) .. "," .. math.floor(e.p.Z / cell)
			grid[k] = grid[k] or {}
			table.insert(grid[k], e)
		end
	end
	local function sepAxis(a, b, ax, az)
		local function proj(e)
			local fx, fz = e.f.X, e.f.Z
			local m = math.sqrt(fx * fx + fz * fz); if m < 1e-6 then fx, fz = 0, 1 else fx, fz = fx / m, fz / m end
			local rx, rz = -fz, fx
			local c = e.p.X * ax + e.p.Z * az
			local r = math.abs(fx * ax + fz * az) * e.half + math.abs(rx * ax + rz * az) * e.width
			return c - r, c + r
		end
		local a0, a1 = proj(a); local b0, b1 = proj(b)
		return a1 < b0 or b1 < a0
	end
	local function overlap(a, b)
		if math.abs(a.p.Y - b.p.Y) > 4 then return false end
		for _, e in { a, b } do
			local fx, fz = e.f.X, e.f.Z
			local m = math.sqrt(fx * fx + fz * fz); if m < 1e-6 then fx, fz = 0, 1 else fx, fz = fx / m, fz / m end
			if sepAxis(a, b, fx, fz) or sepAxis(a, b, -fz, fx) then return false end
		end
		return true
	end
	for _, a in list do
		local cx, cz = math.floor(a.p.X / cell), math.floor(a.p.Z / cell)
		for dx = -1, 1 do
			for dz = -1, 1 do
				for _, b in grid[(cx + dx) .. "," .. (cz + dz)] or {} do
					if b.m ~= a.m and tostring(a.m) < tostring(b.m) .. "" and overlap(a, b) then
						local key = a.m:GetAttribute("NpcId") and (tostring(a.m:GetAttribute("NpcId")) .. "-" .. tostring(b.m:GetAttribute("NpcId"))) or tostring(a.m) .. tostring(b.m)
						local last = W.collisions.pairs[key]
						if not last or E.now - last > 1 then
							W.collisions.events += 1
							if #W.collisions.samples < 8 then
								local function mv(st)
									local e = st.edgeId and W.graph:GetEdge(st.edgeId)
									local m = e and st.nextEdgeId and e.outMovement and e.outMovement[st.nextEdgeId]
									local sig = e and W.Signals.HasSignal and W.Signals.HasSignal(e.toNode)
									return string.format("%s>%s %s%s cd=%.1f", tostring(st.edgeId), tostring(st.nextEdgeId), tostring(m), if sig then " SIG" else "", st.connDist or -1)
								end
								table.insert(W.collisions.samples, string.format("t=%.0f %s(%s,%.1f) x %s(%s,%.1f) at (%.0f,%.0f) [%s | %s]", E.now,
									a.m.Name, tostring(a.s.stopReason), a.s.currentSpeed or 0, b.m.Name, tostring(b.s.stopReason), b.s.currentSpeed or 0, a.p.X, a.p.Z, mv(a.s), mv(b.s)))
							end
						end
						W.collisions.pairs[key] = E.now
					end
				end
			end
		end
	end
end

-- Census of live driver states.
function W.census()
	local drivers = W.Driver._lab.drivers()
	local n, stopped, stuck, speedSum = 0, 0, 0, 0
	local reasons = {}
	for model, s in drivers do
		if not model.Parent then continue end
		n += 1
		local v = s.currentSpeed or 0
		speedSum += v
		if v < 0.5 then stopped += 1 end
		if (s.noProgressTime or 0) > 20 then stuck += 1 end
		local r = s.stopReason or "?"
		reasons[r] = (reasons[r] or 0) + 1
	end
	return { n = n, stopped = stopped, stuck = stuck, avgSpeed = if n > 0 then speedSum / n else 0, reasons = reasons }
end

return W
