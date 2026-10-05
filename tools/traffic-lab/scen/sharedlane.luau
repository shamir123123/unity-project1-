-- One approach lane, a left-turner then a straight car right behind it through an unsignalised
-- crossroads (CollectorRoad): does the follower stay off the turner inside the box?
local W = require("../rt/world")
local V3 = W.V3
local E = W.E
local process = require("@lune/process")
local kind = process.args[1] or "CollectorRoad"
local gapStuds = tonumber(process.args[2]) or 16
local net = W.newCity()
local L = 400
for _, a in { V3.new(L, 0, 0), V3.new(-L, 0, 0), V3.new(0, 0, L), V3.new(0, 0, -L) } do W.road(a, V3.zero, kind) end
W.rebuild()
W.boot({ viewerPos = V3.new(0, 200, 0), signals = false })
W.run(1, 30)
-- eastbound approach from x=-400 (right-hand traffic: lane at z>0? pick the inner lane by trying offsets)
local worst = math.huge
local results = {}
for trial = 1, 6 do
	local z = ({ 2, 4, 6, 8, 10, 12 })[trial]
	local a, ra = W.spawnTrip(V3.new(-300, 0, z), V3.new(6, 0, -300), { allowCrossing = false, entrySpeed = 18 })   -- left (north = -z?) 
	W.run(gapStuds / 18, 30)
	local b, rb = W.spawnTrip(V3.new(-300, 0, z), V3.new(300, 0, z), { allowCrossing = false, entrySpeed = 18 })   -- straight
	if a and b then
		local minD = math.huge
		for _ = 1, 30 * 30 do
			W.run(1 / 30, 30, function() W.checkCollisions() end)
			local pa = a.Parent and W.Driver.GetLivePose(a)
			local pb = b.Parent and W.Driver.GetLivePose(b)
			if pa and pb then minD = math.min(minD, (pa.Position - pb.Position).Magnitude) end
			if not a.Parent and not b.Parent then break end
		end
		table.insert(results, string.format("z=%d lanes %s / %s minDist=%.1f", z, tostring(ra.route[1]), tostring(rb.route[1]), minD))
		worst = math.min(worst, minD)
	else
		table.insert(results, string.format("z=%d spawn failed", z))
	end
	W.run(20, 30)
end
for _, r in results do print(r) end
print(string.format("SHARED worstMinDist=%.1f collisions=%d", worst, W.collisions.events))
for _, s in W.collisions.samples do print("  " .. s) end
