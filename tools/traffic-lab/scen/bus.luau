-- Buses on a loop through a busy grid: a fake TransitService (one depot, 4 kerb stops) feeds
-- the real BusDispatchService. Counts legs driven, stuck pull-outs, collisions with buses.
local C = require("./common")
local W = C.W
local V3, CF = W.V3, W.CF
local E = W.E
local process = require("@lune/process")
local rate = tonumber(process.args[1]) or 0.02
local secs = tonumber(process.args[2]) or 400
local nBus = tonumber(process.args[3]) or 3
local N, B = 4, 240
local net = W.newCity()
local half = N * B / 2
for i = 0, N do
	local z = -half + i * B
	for j = 0, N - 1 do W.road(V3.new(-half + j * B, 0, z), V3.new(-half + (j + 1) * B, 0, z), "NarrowRoad") end
	local x = -half + i * B
	for j = 0, N - 1 do W.road(V3.new(x, 0, -half + j * B), V3.new(x, 0, -half + (j + 1) * B), "NarrowRoad") end
end
local g = W.rebuild()
W.boot({ viewerPos = V3.new(0, 300, 0) })
local VehicleTypes = W.req("ReplicatedStorage.Road.VehicleTypes")
local DriverProfile = W.req("ReplicatedStorage.Road.DriverProfile")
-- stops on the kerb lanes of a loop around the centre block (counter-clockwise for right-hand traffic)
local function kerbPoint(a, b, frac)
	local dir = (b - a).Unit
	local right = V3.new(-dir.Z, 0, dir.X)
	return a + (b - a) * frac + right * 4
end
local q = B / 2
local corners = { V3.new(-q, 0, -q), V3.new(q, 0, -q), V3.new(q, 0, q), V3.new(-q, 0, q) }
local stops = {}
for i = 1, 4 do
	local a, b = corners[i], corners[i % 4 + 1]
	table.insert(stops, { id = i, name = "Stop" .. i, roadPos = kerbPoint(a, b, 0.5) })
end
local function leg(a, b)
	local _, edges = g:FindPath(a.roadPos, b.roadPos, false, VehicleTypes.Bus, DriverProfile.SHORTEST)
	return edges
end
local route = { id = 1, stops = { 1, 2, 3, 4 }, legEdges = {}, closed = true, busCount = nBus, usage = 0 }
for i = 1, 4 do route.legEdges[i] = leg(stops[i], stops[i % 4 + 1]) end
-- depot: a bay just off the north-west corner street, its path out onto the kerb
local depotRoad = V3.new(-half + 20, 0, -half)
local depot = { id = 1, key = "BusDepot", entrance = depotRoad + V3.new(0, 0, -6), bays = {} }
for k = 1, nBus + 1 do
	local bay = V3.new(-half + 20 + k * 8, 0, -half - 40)
	table.insert(depot.bays, { kind = "rigid", cf = CF.lookAt(bay, bay + V3.new(0, 0, 1)),
		pathOut = { bay, bay + V3.new(0, 0, 20), depotRoad + V3.new(0, 0, -8) },
		pathIn = { depotRoad + V3.new(0, 0, -8), bay + V3.new(0, 0, 20), bay } })
end
local stats = { atStop = 0, legs = 0, boards = {}, outOfService = 0 }
local Transit = {}
function Transit.getDepots() return { depot } end
function Transit.getRoute(id) return if id == 1 then route else nil end
function Transit.getStop(id) return stops[id] end
function Transit.getRouteIds() return { 1 } end
function Transit.isRunningNow() return true end
function Transit.vehicleAtStop(model, rid, sid) stats.atStop += 1; stats.boards[model] = (stats.boards[model] or 0) + 1 end
function Transit.isBoarding() return false end
function Transit.vehicleOutOfService() stats.outOfService += 1 end
function Transit.setRouteActiveBuses() end
local DDSTAT = { ok = 0, fail = 0, arrive = 0, legT = {} }
do
	local orig = W.Driver.DriveDirected
	W.Driver.DriveDirected = function(model, a, b, route, onArrive, ...)
		local t0 = E.now
		local wrapped = function(...)
			DDSTAT.arrive += 1
			table.insert(DDSTAT.legT, E.now - t0)
			return onArrive(...)
		end
		local r = orig(model, a, b, route, wrapped, ...)
		if string.find(model.Name, "Bus") then
			if r then DDSTAT.ok += 1 else DDSTAT.fail += 1 end
		end
		return r
	end
end
local Bus = W.req("ServerScriptService.Services.Transit.BusDispatchService")
Bus.Init(Transit, W.RoadService)
Bus.Start()
-- background traffic between grid points
local ends = {}
for i = 0, N do
	for j = 0, N - 1 do
		local z = -half + i * B
		local x0 = -half + j * B + B * 0.5
		table.insert(ends, { pos = V3.new(x0 + 10, 0, z + 3), out = V3.new(x0 + 30, 0, z - 3) })
	end
end
local res = C.run({ ends = ends, rate = rate, secs = secs, allowCrossing = true, report = 100 })
C.report(("bus rate=%.3f buses=%d"):format(rate, nBus), res)
local per = {}
for m, n in stats.boards do table.insert(per, m.Name .. "=" .. n) end
do
	local sum = 0
	for _, t in DDSTAT.legT do sum += t end
	print(string.format("BUSDD ok=%d fail=%d arrive=%d meanLeg=%.1fs", DDSTAT.ok, DDSTAT.fail, DDSTAT.arrive, sum / math.max(1, #DDSTAT.legT)))
end
print(string.format("BUS stopsServed=%d perBus={%s} outOfService=%d", stats.atStop, table.concat(per, ","), stats.outOfService))
for _, m in E.Workspace._City.Buses:GetChildren() do
	print("  BUS", m.Name, m:GetAttribute("BusStatus"), "next", m:GetAttribute("NextStopId"))
end
