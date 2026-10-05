--!strict
local GameSpeed = require(game:GetService("ReplicatedStorage").GameSpeed)
-- BusDispatchService
-- The visible bus fleet, modelled as depot-owned pools. Every Bus Depot keeps its full
-- fleet PARKED in the bays of its layout (TransitKitModel) the moment it is placed; buses drive
-- the bays' baked paths out through the OUT gate and back in through the IN gate, and at a hub /
-- station they pull onto a platform. When a
-- route is runnable, idle buses roll OUT of the nearest depot and drive it as a continuous
-- loop -- stop to stop on the real traffic AI (NPCDriverService.DriveDirected), pausing to
-- "board" -- and when the route closes, shrinks or is deleted they drive BACK and re-park.
-- A bus is destroyed only when its home depot is removed (or no depot can take it back).
--
-- It owns exactly the runtime fleet: bus models + their per-bus state. Ridership itself is
-- abstract -- CitizenService decides who rides and tells TransitService; this service just
-- makes the buses visible and moving. Reads routes / stops / depots from TransitService.

local RunService          = game:GetService("RunService")
local Workspace           = game:GetService("Workspace")
local CollectionService   = game:GetService("CollectionService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local VehicleFactory   = require(ServerScriptService.Services.NPC.VehicleFactory)
local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local PathFollower     = require(ServerScriptService.Services.Util.PathFollower)
local TransitTypes     = require(ReplicatedStorage.Transit.TransitTypes)
local VehicleTypes     = require(ReplicatedStorage.Road.VehicleTypes)
local DriverProfile    = require(ReplicatedStorage.Road.DriverProfile)
local TransitKitModel  = require(ServerScriptService.Services.Transit.TransitKitModel)

local BusDispatchService = {}

local RECONCILE_INTERVAL = 1.5 -- seconds between reconciles (also staggers spawns + dispatch)
local SPAWN_PER_PASS = 4       -- parked buses created per depot per reconcile (staggers the fill)
local BUS_LIFT = 0.6           -- ride lift while pathing; the driver corrects ride height
local YARD_SPEED = 7           -- studs/s (~12 km/h) along a depot / platform drive
local YARD_LIFT = VehicleFactory.RIDE_CLEARANCE
local GATE_LEAD = 4            -- studs short of the gate a bus stops on the lane before turning in
-- A bus pulls away the moment the last rider is through the door (user, 2026-10-05: no holding
-- at stops): this short pause, then it waits only while TransitService.isBoarding -- never longer
-- than BOARDING_CAP, so one lost walker cannot strand a bus.
local STOP_PAUSE = 0.6         -- game-seconds
local BOARDING_CAP = 25        -- game-seconds
local PULL_OUT_RETRY = 2       -- game-seconds between tries when traffic blocks a bus pulling out
local PULL_OUT_REPLAN = 10     -- ...after this many tries in a row it re-plans the leg from where it stands
local GATE_REACH = 24          -- studs: only this close to its depot's gate may a bus turn in without a road leg
local MAX_BEND = math.rad(75)  -- an articulated bus's hinge limit (as NPCDriverView.articulate)
local REJOIN_REACH = 12        -- studs: a bus handed back this close to a lane of its leg (facing its way) rejoins it

-- A drive off the road graph: the FRONT AXLE follows `pts` (TransitKitModel.yardPose), then onDone.
type Yard = { pts: { Vector3 }, cum: { number }, s: number, back: Vector3, onDone: () -> () }

-- A bus is always owned by a home depot. It is either PARKED in one of the depot's bays, rolling
-- OUT to a route (toRoute), looping a route (onRoute) or heading BACK to re-park (toDepot). Bays and
-- platforms are held from the moment a bus heads for them until it has driven clear of them.
type Bus = {
	model: Model,
	homeDepotId: number,
	state: string,        -- "parked" | "toRoute" | "onRoute" | "toDepot"
	slotIndex: number?,   -- the depot bay it is parked in, heading for, or pulling out of
	routeId: number?,     -- the route it serves (toRoute / onRoute)
	legIndex: number,
	phase: string,        -- onRoute sub-state: "driving" | "dwelling" | "yard"
	dwellTimer: number,
	retire: boolean,      -- return to the depot at the next stop
	capacity: number,     -- riders: 60 standard, 100 articulated
	articulated: boolean,
	yard: Yard?,          -- set while it drives a depot / platform path
	platform: { stopId: number, index: number }?, -- the interchange platform it holds
	retry: (() -> ())?,   -- a pull-out traffic blocked, tried again when retryTimer runs out
	retryTimer: number,
	blocked: number,      -- pull-outs blocked in a row
	-- an articulated bus's hinge (VehicleFactory HitchWeld), swung along its yard drives (see articulate)
	hitch: Weld?,
	hitchAt: Vector3,      -- the hinge in the root's space
	axleLen: number,       -- hinge -> rear unit's axle, studs
	axle: Vector3?,        -- the rear axle's world position last step
}

local _transit: any
local _roadService: any
local _folder: Folder
local _buses: { [Model]: Bus } = {}
local _busSeq = 0
local _reconcileAccum = 0
local _running = false
-- Buses from a save, waiting for their route to finish re-pathing after the load (see
-- restore / adoptSaved). Dropped if their line never comes back.
local _pending: { any } = {}
local _pendingUntil = 0
-- Each depot's bays as last seen: a new table means the depot was rebuilt in another layout.
local _seenBays: { [number]: any } = {}
local PENDING_GRACE = 30

local function gameSpeed(): number
	return GameSpeed.get()
end

local function nav(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Buses")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Buses"; f.Parent = city
	end
	return f :: Folder
end

local function destroyBus(model: Model)
	local pose = NPCDriverService.GetLivePose(model) or model:GetPivot()
	_transit.vehicleOutOfService(model, pose.Position)
	_buses[model] = nil
	NPCDriverService.ReleaseDirected(model)
	PathFollower.forget(model)
	if model.Parent then model:Destroy() end
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function depotById(id: number): any?
	for _, d in _transit.getDepots() do
		if d.id == id then return d end
	end
	return nil
end

local function depotCapacity(depot: any): number
	if depot.bays then return #depot.bays end
	local spec = TransitTypes.getDepot(depot.key)
	return if spec then spec.busCapacity else TransitTypes.BUSES_PER_DEPOT
end

-- First bay of `depot` nobody holds; `articulated` (when given) must match the bay's kind -- the
-- bay kind decides which bus parks there.
local function freeSlot(depot: any, articulated: boolean?): number?
	local held: { [number]: boolean } = {}
	for _, b in _buses do
		if b.homeDepotId == depot.id and b.slotIndex then held[b.slotIndex] = true end
	end
	for i, bay in depot.bays or {} do
		if not held[i] and (articulated == nil or (bay.kind == "artic") == articulated) then return i end
	end
	return nil
end

-- A free platform of an interchange stop, or nil (full: the bus boards at the gate instead).
local function freePlatform(stop: any): number?
	local held: { [number]: boolean } = {}
	for _, b in _buses do
		if b.platform and b.platform.stopId == stop.id then held[b.platform.index] = true end
	end
	for i in stop.bays do
		if not held[i] then return i end
	end
	return nil
end

-- Start a yard drive. `pts` begins wherever the front axle is; `back` is the heading the bus has now.
local function yardDrive(bus: Bus, pts: { Vector3 }, back: Vector3, onDone: () -> ())
	NPCDriverService.ReleaseDirected(bus.model)
	PathFollower.forget(bus.model)
	if bus.model.PrimaryPart then bus.model.PrimaryPart.Anchored = true end
	local flat = Vector3.new(back.X, 0, back.Z)
	bus.yard = { pts = pts, cum = TransitKitModel.arc(pts), s = 0, back = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis, onDone = onDone }
	bus.axle = nil -- the rear unit starts in line behind
end

-- On a yard drive the server moves the bus, so it swings the rear unit too: its axle is dragged
-- toward the hinge (a tractrix), the way NPCDriverView bends it on the road -- a long bus turns
-- in from the back instead of swinging round as one stiff piece.
local function articulate(bus: Bus, cf: CFrame)
	local hinge = bus.hitch
	if not hinge then return end
	local h = cf * bus.hitchAt
	local d = if bus.axle then h - bus.axle else Vector3.zero
	if d.Magnitude < bus.axleLen * 0.5 or d.Magnitude > bus.axleLen * 1.5 then d = cf.LookVector end
	local dl = cf:VectorToObjectSpace(d)
	local yaw = math.clamp(math.atan2(-dl.X, -dl.Z), -MAX_BEND, MAX_BEND)
	bus.axle = h - cf:VectorToWorldSpace(Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))) * bus.axleLen
	hinge.C0 = CFrame.new(bus.hitchAt) * CFrame.Angles(0, yaw, 0)
end

local function frontAxle(bus: Bus): Vector3
	local cf = bus.model:GetPivot()
	return cf.Position + cf.LookVector * TransitKitModel.axles(bus.articulated).centre
end

-- A drive INTO a bay / platform from where the bus stands on the lane: its front axle, then the
-- baked path from the road hand-off on.
local function entryPath(bus: Bus, pathIn: { Vector3 }): { Vector3 }
	local pts = { frontAxle(bus) }
	for _, p in pathIn do table.insert(pts, p) end
	return pts
end

-- A drive OUT of a bay / platform onto the first lane of `edges` (the road leg that follows).
local function exitPath(pathOut: { Vector3 }, edges: { string }?): { Vector3 }
	local pts = table.clone(pathOut)
	local lead = if edges and #edges > 0 then NPCDriverService.LaneEntryPath(edges[1], pts[#pts]) else nil
	if lead then for _, p in lead do table.insert(pts, Vector3.new(p.X, pts[#pts].Y, p.Z)) end end
	return pts
end

-- Where to stop on the lane so the bus can turn in at `gate`: GATE_LEAD short of it along the last
-- lane of `edges` (the pivot stops at the goal; the front axle is ahead of it).
local function approachGoal(bus: Bus, edges: { string }, gate: Vector3): Vector3
	local g = nav()
	local edge = g and g:GetEdge(edges[#edges])
	local pts = edge and edge.points
	if not pts or #pts < 2 then return gate end
	local best, bestD = 1, math.huge
	for i, p in pts do
		local d = flatDist(p, gate)
		if d < bestD then best, bestD = i, d end
	end
	local t = pts[math.min(best + 1, #pts)] - pts[math.max(best - 1, 1)]
	t = Vector3.new(t.X, 0, t.Z)
	if t.Magnitude < 1e-3 then return gate end
	return pts[best] - t.Unit * (TransitKitModel.axles(bus.articulated).centre + GATE_LEAD)
end

-- The bus's shortest road path from `from` to `to`, or nil when no road joins them.
local function pathFrom(from: Vector3, to: Vector3): { string }?
	local g = nav()
	if not g then return nil end
	-- a direct pcall: `g and g:FindPath(...)` kept only the first return (the points), so edges was always nil
	local ok, _, edges = pcall(g.FindPath, g, from, to, nil, VehicleTypes.Bus, DriverProfile.SHORTEST)
	return if ok and typeof(edges) == "table" and #edges > 0 then edges else nil
end

-- Start a road drive. With traffic right at the bus's nose or tail it cannot pull out yet: it asks
-- the lane for a gap and runs `again` shortly, like a bus waiting to leave a stop. It never gives up
-- its line for that (it used to drive home while a fresh bus rolled out: the "shift change").
local function pullOut(bus: Bus, from: Vector3, goal: Vector3, edges: { string }, onArrive: () -> (), onFail: () -> (), again: () -> ())
	if NPCDriverService.DriveDirected(bus.model, from, goal, edges, onArrive, onFail) then
		NPCDriverService.ClearRoadGap(bus.model)
		bus.blocked = 0
		return
	end
	NPCDriverService.RequestRoadGap(bus.model, bus.model:GetPivot().Position, edges[1])
	bus.blocked += 1
	bus.retry = again
	bus.retryTimer = PULL_OUT_RETRY
end

-- forward declares (callbacks reference each other)
local driveLeg: (Bus) -> ()
local arrive: (Bus) -> ()

-- Stand a bus idle in bay `idx` of `depot`.
local function parkBus(bus: Bus, depot: any, idx: number)
	NPCDriverService.ReleaseDirected(bus.model)
	PathFollower.forget(bus.model)
	bus.homeDepotId = depot.id
	bus.state = "parked"
	bus.slotIndex = idx
	bus.routeId = nil
	bus.retire = false
	bus.yard = nil
	bus.retry = nil
	if bus.model.PrimaryPart then bus.model.PrimaryPart.Anchored = true end
	bus.model:PivotTo(depot.bays[idx].cf + Vector3.new(0, YARD_LIFT, 0))
	if bus.hitch then bus.hitch.C0 = CFrame.new(bus.hitchAt) end -- parked in line
end

-- Send a bus back to re-park: its home depot if it has a bay of its kind free, else the nearest
-- depot that does. It drives to the depot's IN gate, then its bay's drive in. Destroyed only if no
-- depot can take it.
local function returnToDepot(bus: Bus)
	bus.retry = nil
	bus.state = "toDepot"
	bus.routeId = nil
	bus.slotIndex = nil
	bus.platform = nil
	local pos = bus.model:GetPivot().Position
	_transit.vehicleOutOfService(bus.model, pos)
	local depot = depotById(bus.homeDepotId)
	if not (depot and freeSlot(depot, bus.articulated)) then
		local best, bestD = nil, math.huge
		for _, d in _transit.getDepots() do
			if freeSlot(d, bus.articulated) then
				local dist = flatDist(d.entrance, pos)
				if dist < bestD then bestD = dist; best = d end
			end
		end
		depot = best
	end
	if not depot then destroyBus(bus.model); return end
	local idx = freeSlot(depot, bus.articulated) :: number
	bus.homeDepotId = depot.id
	bus.slotIndex = idx -- held from now, so no other bus heads for it
	local target = depot
	local function turnIn()
		local d = depotById(target.id)
		-- the bay held now (the depot may have been re-laid out while the bus drove here)
		local i = if d then (bus.slotIndex or freeSlot(d, bus.articulated)) else nil
		if not (d and d.bays and i and d.bays[i]) then destroyBus(bus.model); return end
		bus.slotIndex = i
		yardDrive(bus, entryPath(bus, d.bays[i].pathIn), bus.model:GetPivot().LookVector, function()
			parkBus(bus, d, i)
		end)
	end
	local edges = pathFrom(pos, target.entrance)
	local function again() returnToDepot(bus) end
	if not edges then
		-- Already at the gate: turn in. Anywhere else it waits for a road -- it never cuts across
		-- the city to its bay (the "shift change" that ignored every road rule).
		-- ponytail: waits forever if its road is gone for good; despawn after N tries if that shows up
		if flatDist(pos, target.entrance) <= GATE_REACH then turnIn() else bus.retry = again; bus.retryTimer = PULL_OUT_RETRY end
		return
	end
	pullOut(bus, pos, approachGoal(bus, edges, target.entrance), edges, turnIn, again, again)
end

local function boardAt(bus: Bus, routeId: number)
	bus.phase = "dwelling"
	local route = _transit.getRoute(routeId)
	_transit.vehicleAtStop(bus.model, routeId, route.stops[bus.legIndex], bus.capacity)
	bus.dwellTimer = STOP_PAUSE
end

-- The bus reached the stop at the end of its leg. At a hub / station it drives onto a free platform
-- first (boarding at the gate when every platform is taken).
function arrive(bus: Bus)
	local route = bus.routeId and _transit.getRoute(bus.routeId)
	if not route or #route.stops < 2 then returnToDepot(bus); return end
	if bus.retire then returnToDepot(bus); return end
	bus.state = "onRoute" -- a bus rolling out to its line is on it from its first stop
	bus.legIndex = (bus.legIndex % #route.stops) + 1
	local routeId = route.id
	local stop = _transit.getStop(route.stops[bus.legIndex])
	local idx = if stop and stop.bays then freePlatform(stop) else nil
	if stop and idx then
		bus.platform = { stopId = stop.id, index = idx }
		bus.phase = "yard"
		yardDrive(bus, entryPath(bus, stop.bays[idx].pathIn), bus.model:GetPivot().LookVector, function()
			if _transit.getRoute(routeId) then boardAt(bus, routeId) else returnToDepot(bus) end
		end)
		return
	end
	boardAt(bus, routeId)
end

-- Where a leg's road drive should end: at an interchange, short of its IN gate so the bus can turn in.
local function legGoal(bus: Bus, stop: any, edges: { string }): Vector3
	return if stop.bays then approachGoal(bus, edges, stop.roadPos) else stop.roadPos
end

-- The rest of leg `edges` from where the bus stands: from the leg lane it is on (heading its way),
-- so a re-plan never leaves its line. nil when it is off the leg (the road changed under it).
local function restOfLeg(edges: { string }, pose: CFrame): { string }?
	local g = nav()
	if not g then return nil end
	local pos, look = pose.Position, pose.LookVector
	local best, bestD = nil, REJOIN_REACH
	for i, id in edges do
		local e = g:GetEdge(id)
		local pts = e and e.points
		if not pts then return nil end
		for j = 1, #pts - 1 do
			local a, b = pts[j], pts[j + 1]
			local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
			local len2 = ab:Dot(ab)
			if len2 < 1e-6 or ab:Dot(look) <= 0 then continue end
			local t = math.clamp(Vector3.new(pos.X - a.X, 0, pos.Z - a.Z):Dot(ab) / len2, 0, 1)
			local d = flatDist(a + ab * t, pos)
			if d < bestD then best, bestD = i, d end
		end
	end
	return if best then table.move(edges, best, #edges, 1, {}) else nil
end

-- The traffic AI handed a bus back mid-leg (the road changed, or it was wedged): it carries on along
-- the rest of its leg from where it really is, or the shortest way to that stop once it is off the
-- leg. With no road there it waits for one; it never skips to the stop.
local function onAbort(bus: Bus)
	if not bus.model.Parent then destroyBus(bus.model); return end
	local route = bus.routeId and _transit.getRoute(bus.routeId)
	local n = if route then #route.stops else 0
	local target = if route and n >= 2 then _transit.getStop(route.stops[(bus.legIndex % n) + 1]) else nil
	if not target or bus.retire then returnToDepot(bus); return end
	local pose = bus.model:GetPivot()
	local pos = pose.Position
	local leg = if route then route.legEdges[bus.legIndex] else nil
	local edges = (if typeof(leg) == "table" then restOfLeg(leg, pose) else nil) or pathFrom(pos, target.roadPos)
	local function again() onAbort(bus) end
	-- No road from here yet: stay on the line and re-plan shortly. Going home here, then being
	-- rolled straight back out by reconcile, was the loop round the depot.
	if not edges then bus.retry = again; bus.retryTimer = PULL_OUT_RETRY; return end
	pullOut(bus, pos, legGoal(bus, target, edges), edges, function() arrive(bus) end, again, again)
end

function driveLeg(bus: Bus)
	local route = bus.routeId and _transit.getRoute(bus.routeId)
	if not route or #route.stops < 2 or bus.retire then returnToDepot(bus); return end
	local n = #route.stops
	local i = bus.legIndex
	local fromStop = _transit.getStop(route.stops[i])
	local toStop = _transit.getStop(route.stops[(i % n) + 1])
	if not fromStop or not toStop then returnToDepot(bus); return end
	local edges = route.legEdges[i]
	bus.phase = "driving"
	local function roadLeg()
		-- No drivable leg: the bus never jumps the gap -- it goes home, and the line's alert
		-- (TransitService) tells the player which road is missing.
		if typeof(edges) ~= "table" or #edges == 0 then returnToDepot(bus); return end
		local from = if fromStop.exitPos == nil then fromStop.roadPos else bus.model:GetPivot().Position
		pullOut(bus, from, legGoal(bus, toStop, edges), edges, function() arrive(bus) end, function() onAbort(bus) end,
			function() if bus.blocked >= PULL_OUT_REPLAN then onAbort(bus) else driveLeg(bus) end end)
	end
	local plat = bus.platform
	local stop = plat and _transit.getStop(plat.stopId)
	local bay = if plat and stop and stop.bays then stop.bays[plat.index] else nil
	if bay then
		-- leave the platform by its drive out, onto the leg's first lane; the platform frees behind it
		yardDrive(bus, exitPath(bay.pathOut, edges), bay.cf.LookVector, function()
			bus.platform = nil
			roadLeg()
		end)
		return
	end
	bus.platform = nil
	roadLeg()
end

-- Roll a bus out to serve `routeId`, entering at stop `startIndex`: a parked one drives its bay's
-- path out through the OUT gate first.
local function dispatchBus(bus: Bus, routeId: number, startIndex: number): boolean
	local route = _transit.getRoute(routeId)
	if not route or #route.stops < 2 then return false end
	if not nav() then return false end
	local n = #route.stops
	startIndex = ((startIndex - 1) % n) + 1
	local startStop = _transit.getStop(route.stops[startIndex])
	if not startStop then return false end

	local depot = depotById(bus.homeDepotId)
	local bay = if bus.state == "parked" and bus.slotIndex and depot and depot.bays then depot.bays[bus.slotIndex] else nil
	local from = if bay then bay.pathOut[#bay.pathOut] else bus.model:GetPivot().Position
	local first = pathFrom(from, startStop.roadPos)
	-- no road from the gate to the line: the bus stays parked instead of driving out and back
	if bay and not first then return false end
	bus.state = "toRoute"
	bus.routeId = routeId
	bus.retire = false
	-- arrive() steps legIndex on to startIndex (and takes a platform there if it is a hub / station)
	bus.legIndex = if startIndex == 1 then n else startIndex - 1
	local function reachedFirst()
		bus.state = "onRoute"
		arrive(bus)
	end
	local function roadLeg()
		bus.slotIndex = nil -- clear of the bay
		if bus.retire or not _transit.getRoute(routeId) then returnToDepot(bus); return end
		local pos = bus.model:GetPivot().Position
		local edges = first or pathFrom(pos, startStop.roadPos)
		first = nil -- a retry re-plans from where the bus stands
		-- no road to the line from here yet: wait and re-plan (never appear at the stop)
		if not edges then bus.retry = roadLeg; bus.retryTimer = PULL_OUT_RETRY; return end
		pullOut(bus, pos, legGoal(bus, startStop, edges), edges, reachedFirst, function() onAbort(bus) end, roadLeg)
	end
	if bay then
		yardDrive(bus, exitPath(bay.pathOut, first), bay.cf.LookVector, roadLeg)
	else
		roadLeg()
	end
	return true
end

-- A new bus of depot `depotId` and its record (not parented yet: the caller places it first).
local function makeBus(depotId: number, articulated: boolean): Bus
	_busSeq += 1
	local spec = if articulated then TransitTypes.BusArticulated else TransitTypes.Bus
	local model = VehicleFactory.build("Bus_" .. tostring(_busSeq), nil, if articulated then "BusArticulated" else "BusCityRigid")
	CollectionService:AddTag(model, VehicleTypes.Tag.Bus)
	-- no persona: always the shortest way, and never off its route (DriverProfile.SHORTEST)
	model:SetAttribute("ShortestRoute", true)
	model:SetAttribute("Capacity", spec.capacity)
	model:SetAttribute("Passengers", 0)
	local tr = model:FindFirstChild("TrailerRoot")
	local hinge = tr and tr:FindFirstChild("HitchWeld")
	local hitch = if hinge and hinge:IsA("Weld") then hinge else nil
	local bus: Bus = {
		model = model, homeDepotId = depotId, state = "parked", slotIndex = nil,
		routeId = nil, legIndex = 1, phase = "dwelling", dwellTimer = 0, retire = false,
		capacity = spec.capacity, articulated = articulated, retryTimer = 0, blocked = 0,
		hitch = hitch, hitchAt = if hitch then hitch.C0.Position else Vector3.zero,
		axleLen = math.max(tonumber(model:GetAttribute("TrailerAxle")) or 0, 1),
	}
	_buses[model] = bus
	return bus
end

-- Create one parked bus in a free bay of `depot`; the bay's kind decides city or articulated.
local function spawnParked(depot: any): boolean
	local idx = freeSlot(depot, nil)
	if not idx then return false end
	local bus = makeBus(depot.id, depot.bays[idx].kind == "artic")
	bus.model.Parent = _folder
	parkBus(bus, depot, idx)
	return true
end

-- The parked bus nearest `pos` (idle and available to dispatch), of the size the line
-- wants if one is free: articulated for a busy line, standard otherwise.
local function nearestParkedBus(pos: Vector3, wantBig: boolean): Bus?
	local best, bestD = nil, math.huge
	for _, b in _buses do
		if b.state == "parked" then
			local d = flatDist(b.model:GetPivot().Position, pos)
			if (b.capacity > TransitTypes.Bus.capacity) ~= wantBig then d += 1e6 end
			if d < bestD then bestD = d; best = b end
		end
	end
	return best
end

-- A saved bus back on the street where it was: dwelling at its stop, mid-leg, rolling out to
-- its route or back to the depot. Needs its route's legs re-pathed first; false = not yet.
local function adoptSaved(row: any): boolean
	local depot = depotById(row.d)
	if not depot then return true end -- its depot is gone: nothing to come back to
	local route = if row.r then _transit.getRoute(row.r) else nil
	if row.s ~= "toDepot" and not (route and #route.stops >= 2 and #route.legEdges > 0) then
		return false
	end
	local g = nav()
	local edge = if g and row.e then g:GetEdge(row.e) else nil
	local pos: Vector3? = nil
	local dir: Vector3? = nil
	if edge and edge.points and #edge.points > 0 then
		pos, dir = PathFollower.pointAtDist(edge.points, PathFollower.getCum(edge), tonumber(row.x) or 0)
	elseif route then
		local stop = _transit.getStop(route.stops[math.clamp(tonumber(row.l) or 1, 1, #route.stops)])
		pos = if stop then stop.roadPos else nil
		-- heading: the lane it stands on
		local near = if pos and g then g:NearestEdge(pos) else nil
		local pts = near and near.edge.points
		if pts and #pts >= 2 then
			local i = math.clamp(near.index, 1, #pts - 1)
			dir = pts[i + 1] - pts[i]
		end
	end
	if not pos then return true end
	-- A saved bus stands along its lane, never square across the road (CFrame.new(pos) has no heading).
	local flat = if dir then Vector3.new(dir.X, 0, dir.Z) else Vector3.zero
	local at = pos + Vector3.new(0, BUS_LIFT, 0)
	local pose = if flat.Magnitude > 1e-3 then CFrame.lookAt(at, at + flat.Unit) else CFrame.new(at)

	local bus = makeBus(depot.id, row.big == true)
	bus.state = row.s
	bus.routeId = row.r
	bus.legIndex = math.max(1, math.floor(tonumber(row.l) or 1))
	bus.phase = if row.p == "dwelling" then "dwelling" else "driving"
	bus.dwellTimer = tonumber(row.w) or TransitTypes.STOP_DWELL
	bus.model:PivotTo(pose)
	bus.model.Parent = _folder
	if row.s == "toDepot" or not route then
		returnToDepot(bus)
	elseif row.s == "toRoute" then
		dispatchBus(bus, route.id, bus.legIndex)
	elseif bus.phase == "driving" then
		onAbort(bus) -- finish the leg it was on: from here to the leg's end stop
	end
	return true
end

-- A depot rebuilt in another bay layout: its parked buses move into the new bays (a bus whose kind
-- has no bay left drives off to another depot's, or leaves the fleet if none has room); a bus on its
-- way in is given a new bay of its kind.
local function repark(d: any)
	local parked, arriving = {}, {}
	for _, b in _buses do
		if b.homeDepotId ~= d.id or not b.slotIndex then continue end
		if b.state == "parked" then table.insert(parked, b) elseif b.state == "toDepot" then table.insert(arriving, b) end
		b.slotIndex = nil
	end
	for _, b in parked do
		local idx = freeSlot(d, b.articulated)
		if idx then parkBus(b, d, idx) else returnToDepot(b) end
	end
	for _, b in arriving do
		b.slotIndex = freeSlot(d, b.articulated)
	end
end

-- What the bus panel shows (TransitInfoController): what the bus is doing, its line, its depot and the
-- stop it stands at or drives to. Replicated attributes, stamped each reconcile (unchanged values cost nothing).
local function stampBus(bus: Bus)
	local route = if bus.routeId then _transit.getRoute(bus.routeId) else nil
	local n = if route then #route.stops else 0
	local boarding = bus.state == "onRoute" and bus.phase == "dwelling"
	local m = bus.model
	m:SetAttribute("BusStatus", if bus.state == "parked" then "Parked"
		elseif bus.state == "toDepot" or bus.retire then "Returning"
		elseif bus.state == "toRoute" then "ToLine"
		elseif boarding then "Boarding"
		else "Driving")
	m:SetAttribute("LineId", if route then route.id else nil)
	m:SetAttribute("DepotId", bus.homeDepotId)
	m:SetAttribute("NextStopId", if route and n > 0 then route.stops[if boarding then bus.legIndex else (bus.legIndex % n) + 1] else nil)
end

-- Keep every depot stocked with its parked fleet, and keep each runnable route supplied with
-- buses drawn from the nearest depot. One spawn + one dispatch step per pass staggers the work
-- and spreads buses around each loop instead of bunching them at the depot.
local function reconcile()
	-- prune destroyed buses
	for model in _buses do if not model.Parent then _buses[model] = nil end end

	-- Saved buses first, so the depot restock below counts them as out on the road.
	for i = #_pending, 1, -1 do
		if adoptSaved(_pending[i]) then table.remove(_pending, i) end
	end
	if #_pending > 0 and os.clock() > _pendingUntil then table.clear(_pending) end

	local depots = _transit.getDepots()
	local present: { [number]: boolean } = {}
	for _, d in depots do
		present[d.id] = true
		if _seenBays[d.id] ~= nil and _seenBays[d.id] ~= d.bays then repark(d) end
		_seenBays[d.id] = d.bays
	end
	for id in _seenBays do
		if not present[id] then _seenBays[id] = nil end
	end

	-- Buses whose home depot is gone: parked ones vanish with it; en-route ones finish their
	-- leg and retire to whatever depot remains (or are destroyed if none do).
	for model, bus in _buses do
		if not present[bus.homeDepotId] then
			if bus.state == "parked" then
				destroyBus(model)
			else
				bus.retire = true
				local alt = depots[1]
				if alt then bus.homeDepotId = alt.id end
			end
		end
	end

	-- Stock each depot up to its capacity (parked + the buses it has out on routes).
	for _, d in depots do
		local owned = 0
		for _, b in _buses do if b.homeDepotId == d.id then owned += 1 end end
		local toSpawn = math.min(depotCapacity(d) - owned, SPAWN_PER_PASS)
		for _ = 1, toSpawn do
			if not spawnParked(d) then break end
		end
	end

	-- Match each route's live bus count to its assignment.
	for _, routeId in _transit.getRouteIds() do
		local route = _transit.getRoute(routeId)
		if not route then continue end
		-- a line with a leg no road connects does not run (TransitService shows the alert)
		-- ...nor does a day-only line at night: its buses finish at their next stop and go home
		local runnable = _transit.isRunningNow(routeId) and route.closed == true and #route.stops >= 2 and #route.legEdges > 0
			and route.broken ~= true
		local desired = if runnable then route.busCount else 0
		local have = 0
		for _, b in _buses do
			if b.routeId == routeId and not b.retire and (b.state == "toRoute" or b.state == "onRoute") then
				have += 1
			end
		end
		if have < desired then
			local startStop = _transit.getStop(route.stops[1])
			local bus = if startStop then nearestParkedBus(startStop.roadPos, route.usage >= TransitTypes.BUSY_LINE_USAGE) else nil
			-- Even shares of the WHOLE loop (the old integer step bunched them on its first part).
			if bus and dispatchBus(bus, routeId, math.floor(have * #route.stops / math.max(1, desired)) + 1) then
				have += 1
			end
		elseif have > desired then
			for _, b in _buses do
				if b.routeId == routeId and not b.retire and (b.state == "toRoute" or b.state == "onRoute") then
					b.retire = true; have -= 1; break
				end
			end
		end
		_transit.setRouteActiveBuses(routeId, have)
	end

	-- Buses whose route vanished out from under them: retire to the depot.
	for _, bus in _buses do
		if (bus.state == "toRoute" or bus.state == "onRoute") and not bus.retire then
			if not bus.routeId or not _transit.getRoute(bus.routeId) then bus.retire = true end
		end
	end
	for _, bus in _buses do stampBus(bus) end
end

local function step(dt: number)
	local speed = gameSpeed()
	for model, bus in _buses do
		if not model.Parent then _buses[model] = nil; continue end
		local yard = bus.yard
		if yard then
			if speed <= 0 then continue end
			yard.s += YARD_SPEED * dt * speed
			local total = yard.cum[#yard.cum]
			local pose = TransitKitModel.yardPose(yard.pts, yard.cum, math.min(yard.s, total), yard.back, bus.articulated, YARD_LIFT)
			model:PivotTo(pose)
			articulate(bus, pose)
			if yard.s >= total then
				bus.yard = nil
				yard.onDone()
			end
			continue
		end
		local retry = bus.retry
		if retry then
			bus.retryTimer -= dt * speed
			if speed > 0 and bus.retryTimer <= 0 then bus.retry = nil; retry() end
			continue
		end
		if bus.state == "onRoute" and bus.phase == "dwelling" then
			bus.dwellTimer -= dt * speed
			if speed > 0 and bus.dwellTimer <= 0
				and (bus.dwellTimer < -BOARDING_CAP or not _transit.isBoarding(bus.model)) then
				driveLeg(bus)
			end
		end
	end
	_reconcileAccum += dt
	if _reconcileAccum >= RECONCILE_INTERVAL then
		_reconcileAccum = 0
		local ok, err = pcall(reconcile)
		if not ok then warn("[BusDispatchService] reconcile failed: " .. tostring(err)) end
	end
end

-- == Public ====================================================================
-- Despawn the whole fleet (city unload / reload). TransitService.restore rebuilds routes;
-- buses respawn on the next reconcile.
function BusDispatchService.ResetVehicles(): number
	local count = 0
	for model in _buses do destroyBus(model); count += 1 end
	table.clear(_buses)
	table.clear(_pending)
	return count
end

function BusDispatchService.clear()
	BusDispatchService.ResetVehicles()
end

-- Every bus out on the streets, for the city save; parked ones are simply re-stocked.
function BusDispatchService.serialize(): { any }?
	local rows = {}
	for model, bus in _buses do
		if bus.state == "parked" or not model.Parent then continue end
		local anchor = NPCDriverService.GetLaneAnchor(model)
		table.insert(rows, {
			d = bus.homeDepotId, r = bus.routeId, s = bus.state, l = bus.legIndex, p = bus.phase,
			w = math.floor(bus.dwellTimer * 100 + 0.5) / 100,
			big = if bus.capacity > TransitTypes.Bus.capacity then true else nil,
			e = if anchor then anchor.edgeId else nil,
			x = if anchor then math.floor(anchor.dist * 100 + 0.5) / 100 else nil,
		})
	end
	return if #rows > 0 then rows else nil
end

-- Saved buses come back once TransitService has restored their routes (reconcile adopts
-- them as each route's legs finish re-pathing).
function BusDispatchService.restore(rows: any)
	table.clear(_pending)
	if typeof(rows) ~= "table" then return end
	for _, row in rows do
		local state = if typeof(row) == "table" then row.s else nil
		if (state == "onRoute" or state == "toRoute" or state == "toDepot") and typeof(row.d) == "number" then
			table.insert(_pending, row)
		end
	end
	_pendingUntil = os.clock() + PENDING_GRACE
end

-- == Lifecycle =================================================================
function BusDispatchService.Init(transitService: any, roadService: any)
	assert(transitService and roadService, "[BusDispatchService] requires TransitService + RoadService")
	_transit = transitService
	_roadService = roadService
	_folder = ensureFolder()
end

function BusDispatchService.Bind() end

function BusDispatchService.Start()
	if _running then return end
	_running = true
	RunService.Heartbeat:Connect(function(dt: number)
		local sdt = math.min(dt, 0.1)
		local ok, err = pcall(step, sdt)
		if not ok then warn("[BusDispatchService] step failed: " .. tostring(err)) end
	end)
end

return BusDispatchService
