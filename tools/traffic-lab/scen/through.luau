-- Through traffic: roads dragged to the map edge (real OutsideConnectionService), the real
-- ThroughTrafficService spawning and despawning, then a save + restore cycle.
local C = require("./common")
local W = C.W
local V3 = W.V3
local E = W.E
local process = require("@lune/process")
local kind = process.args[1] or "Highway4"
local secs = tonumber(process.args[2]) or 300
local H = 4096
local net = W.newCity()
-- E-W road across the map with a town grid in the middle, plus a N-S road to the south edge
local side = process.args[3] or "NarrowRoad"
W.road(V3.new(-H, 0, 0), V3.new(-600, 0, 0), kind)
W.road(V3.new(-600, 0, 0), V3.new(0, 0, 0), kind)
W.road(V3.new(0, 0, 0), V3.new(600, 0, 0), kind)
W.road(V3.new(600, 0, 0), V3.new(H, 0, 0), kind)
W.road(V3.new(0, 0, 0), V3.new(0, 0, 600), side)
W.road(V3.new(0, 0, 600), V3.new(0, 0, H), side)
W.rebuild()
W.boot({ viewerPos = V3.new(0, 300, 0) })
local OCS = W.req("ServerScriptService.Services.City.OutsideConnectionService")
OCS.Init(W.RoadService, {})
OCS.Bind()
OCS.Start()
W.run(1, 30)
local conns = OCS.list()
print("connections", #conns)
for _, c in conns do print("  ", c.id, c.dir, c.roadType, c.nodeId) end
W.Driver.SetOutsideConnService(OCS)
local DDCOUNT = { ok = 0, fail = 0 }
do
	local orig = W.Driver.DriveDirected
	W.Driver.DriveDirected = function(...)
		local r = orig(...)
		if r then DDCOUNT.ok += 1 else DDCOUNT.fail += 1 end
		return r
	end
end
local TTS = W.req("ServerScriptService.Services.City.Simulation.ThroughTrafficService")
local frac = tonumber(process.args[4]) or 0.74
TTS.Init(W.RoadService, OCS, { getDayFraction = function() return frac end, getDay = function() return 1 end })
TTS.Start()
for t = 1, math.floor(secs / 30) do
	W.run(30, 30, function(i) if i % 6 == 0 then W.checkCollisions() end end)
	local d = TTS.getDemand()
	local c = W.census()
	print(string.format("t=%4ds target=%d live=%d drivers=%d stopped=%d avgV=%.1f ddOk=%d ddFail=%d", math.floor(E.now), d.target, d.live, c.n, c.stopped, c.avgSpeed, DDCOUNT.ok, DDCOUNT.fail))
end
-- save and restore
local blob = TTS.serialize()
local saved = blob and #blob.cars or 0
TTS.ResetVehicles()
W.run(1, 30)
TTS.restore(blob)
local restored0 = TTS.getDemand().live
local driving0 = W.census().n
print(string.format("RESTORE saved=%d liveAfterRestore=%d drivingNow=%d", saved, restored0, driving0))
for t = 1, 4 do
	W.run(15, 30)
	print(string.format("  after %ds: live=%d driving=%d", t * 15, TTS.getDemand().live, W.census().n))
end
print(string.format("COLLISIONS %d", W.collisions.events))
local seen = {}
for _, w in E.warnings do local k = w:gsub("%d+", "#"):sub(1, 160); if not seen[k] then seen[k] = 0 end; seen[k] += 1 end
for k, v in seen do print("WARN x" .. v .. " " .. k) end
for _, e in E.errors do print("ERR " .. e:sub(1, 600)) end
