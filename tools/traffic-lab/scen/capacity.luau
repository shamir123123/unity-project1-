-- Lane capacity: a long two-lane road (one each way) fed far above capacity at one end. Counts
-- cars crossing the middle once the queue has formed: the road's real throughput per lane.
local C = require("./common")
local W = C.W
local V3 = W.V3
local E = W.E
local process = require("@lune/process")
local kind = process.args[1] or "NarrowRoad"
local net = W.newCity()
W.road(V3.new(-1600, 0, 0), V3.new(-800, 0, 0), kind)
W.road(V3.new(-800, 0, 0), V3.new(0, 0, 0), kind)
W.road(V3.new(0, 0, 0), V3.new(800, 0, 0), kind)
W.road(V3.new(800, 0, 0), V3.new(1600, 0, 0), kind)
W.rebuild()
W.boot({ viewerPos = V3.new(0, 200, 0), signals = false })
W.run(1, 30)
local crossings = {}
local watch = {}
local spawnPts = { V3.new(-1550, 0, 4), V3.new(-1550, 0, 9) }
local k = 0
W.run(360, 30, function(i)
	if i % 6 == 0 then
		k = k % #spawnPts + 1
		local car, rec = W.spawnTrip(spawnPts[k], V3.new(1550, 0, 6), { allowCrossing = false, entrySpeed = tonumber(process.args[2]) })
		if car then watch[car] = rec end
	end
	for car, rec in watch do
		local cf = car.Parent and W.Driver.GetLivePose(car)
		if not rec.crossed and cf and cf.Position.X > 0 then
			rec.crossed = E.now
			table.insert(crossings, E.now)
		end
		if not car.Parent then watch[car] = nil end
	end
end)
local n = 0
for _, t in crossings do if t > 120 then n += 1 end end
local lanes = 0
for _, e in W.graph:GetEdges() do if e.points[1].X < -1000 and e.points[#e.points].X > e.points[1].X then lanes += 1 end end
print(string.format("CAPACITY %s lanesEastbound=%d crossings(120-360s)=%d -> %.0f veh/h total, %.0f veh/h/lane", kind, lanes, n, n * 3600 / 240, n * 3600 / 240 / math.max(1, lanes)))
