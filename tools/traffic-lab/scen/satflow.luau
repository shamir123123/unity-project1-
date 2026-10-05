-- Saturation flow at a signalised crossroads of two arterials: cars queue on red and the
-- discharge headway over the stop line during green is measured per movement.
local C = require("./common")
local W = C.W
local V3 = W.V3
local E = W.E
local process = require("@lune/process")
local kind = process.args[1] or "CollectorRoad"
local move = process.args[2] or "straight"
local net = W.newCity()
local L = 700
W.road(V3.new(-L, 0, 0), V3.zero, kind)
W.road(V3.zero, V3.new(L, 0, 0), kind)
W.road(V3.zero, V3.new(0, 0, L), kind)
W.road(V3.zero, V3.new(0, 0, -L), kind)
W.rebuild()
W.boot({ viewerPos = V3.new(0, 200, 0) })
W.run(1, 30)
local sig = 0
for id in net:getNodes() do if W.Signals.HasSignal(id) then sig += 1 end end
local goal = if move == "straight" then V3.new(L - 40, 0, 6)
	elseif move == "right" then V3.new(-6, 0, L - 40)
	else V3.new(6, 0, -(L - 40))
local crossings = {}
local watch = {}
local spawnPts = { V3.new(-L + 40, 0, 4), V3.new(-L + 40, 0, 9), V3.new(-L + 40, 0, 2) }
local k = 0
W.run(600, 30, function(i)
	if i % 3 == 0 then
		k = k % #spawnPts + 1
		local car, rec = W.spawnTrip(spawnPts[k], goal, { allowCrossing = false })
		if car then watch[car] = rec; rec.lane = rec.route[1] end
	end
	for car, rec in watch do
		local cf = car.Parent and W.Driver.GetLivePose(car)
		local st = W.Driver._lab.drivers()[car]
		if st and not st.connector then rec.lastLane = st.edgeId end
		if not rec.crossed and ((cf and cf.Position.X > -8) or not car.Parent) then
			rec.crossed = E.now
			table.insert(crossings, { t = E.now, lane = rec.lastLane or rec.lane })
		end
		if not car.Parent then watch[car] = nil end
	end
end)
-- headways per approach lane, only inside a green (gap < 5 s), skipping the first 3 of each platoon
local byLane = {}
for _, c in crossings do byLane[c.lane] = byLane[c.lane] or {}; table.insert(byLane[c.lane], c.t) end
for lane, ts in byLane do
	table.sort(ts)
	local sum, n, run = 0, 0, 0
	for i = 2, #ts do
		local h = ts[i] - ts[i - 1]
		if h < 5 then
			run += 1
			if run >= 3 then sum += h; n += 1 end
		else run = 0 end
	end
	if n > 0 then
		print(string.format("SATFLOW %s %s lane=%s signals=%d crossings=%d headway=%.2fs -> %.0f veh/h of green", kind, move, lane, sig, #ts, sum / n, 3600 / (sum / n)))
	end
end
