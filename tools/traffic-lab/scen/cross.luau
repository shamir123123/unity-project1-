-- 4-way junction of two-lane streets, demand from every arm to every other.
local W = require("../rt/world")
local V3 = W.V3
local process = require("@lune/process")
local kind = process.args[1] or "NarrowRoad"
local rate = tonumber(process.args[2]) or 0.25 -- cars per second per arm
local secs = tonumber(process.args[3]) or 300
local signal = process.args[4] == "signal"

local net = W.newCity()
local L = 400
local arms = { V3.new(L, 0, 0), V3.new(-L, 0, 0), V3.new(0, 0, L), V3.new(0, 0, -L) }
for _, a in arms do W.road(a, V3.zero, kind) end
W.rebuild()
W.boot({ viewerPos = V3.new(0, 200, 0) })
if signal then
	-- Force a signal at the centre node.
	for id, node in net:getNodes() do
		if #node.segments == 4 and W.Signals.ForceSignal then W.Signals.ForceSignal(id) end
	end
end
math.randomseed(1)
local acc = { 0, 0, 0, 0 }
local spawned, blocked = 0, 0
local function lanePoint(i, inbound)
	-- a point 30 studs in from the arm tip on the lane heading in (or out)
	local a = arms[i]
	local dir = (V3.zero - a).Unit
	local side = V3.new(-dir.Z, 0, dir.X) -- right of travel
	if inbound then return a + dir * 30 + side * 3 end
	return a + dir * 30 - side * 3
end
local t0 = os.clock()
W.run(secs, 30, function(i, dt)
	for k = 1, 4 do
		acc[k] += rate * dt
		if acc[k] >= 1 then
			local dest = math.random(1, 3)
			if dest >= k then dest += 1 end
			local car, why = W.spawnTrip(lanePoint(k, true), lanePoint(dest, false), { allowCrossing = false })
			if car then acc[k] -= 1; spawned += 1 else blocked += 1; acc[k] = math.min(acc[k], 1.5) end
		end
	end
	if i % (30 * 30) == 0 then
		local c = W.census()
		print(string.format("t=%4ds live=%3d stopped=%3d stuck=%2d avgV=%.1f arrived=%d aborted=%d", math.floor(W.E.now), c.n, c.stopped, c.stuck, c.avgSpeed, #W.arrivals, #W.aborts))
	end
end)
local c = W.census()
local tt = 0
for _, r in W.arrivals do tt += r.arrived - r.started end
print(string.format("RESULT kind=%s rate=%.2f spawned=%d blockedSpawns=%d arrived=%d aborted=%d live=%d stuck=%d meanTrip=%.1fs real=%.1fs",
	kind, rate, spawned, blocked, #W.arrivals, #W.aborts, c.n, c.stuck, if #W.arrivals > 0 then tt / #W.arrivals else 0, os.clock() - t0))
for r, n in c.reasons do print("  reason", r, n) end
local seen = {}
for _, w in W.E.warnings do if not seen[w] then seen[w] = true; print("WARN", w:sub(1, 200)) end end
for _, e in W.E.errors do print("ERR", e:sub(1, 600)) end
