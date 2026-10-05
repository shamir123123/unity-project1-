-- Grid city: N x N blocks of local streets, two arterials (CollectorRoad) crossing in the
-- middle, endpoints on every boundary road end plus mid-block points. Random trips.
local C = require("./common")
local W = C.W
local V3 = W.V3
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 5
local rate = tonumber(process.args[2]) or 0.05
local secs = tonumber(process.args[3]) or 400
local B = tonumber(process.args[4]) or 220 -- block size (studs)
local net = W.newCity()
local half = N * B / 2
local mid = math.floor(N / 2)
-- streets along X (rows) and Z (cols)
for i = 0, N do
	local z = -half + i * B
	local kind = if i == mid then "CollectorRoad" else "NarrowRoad"
	for j = 0, N - 1 do
		W.road(V3.new(-half + j * B, 0, z), V3.new(-half + (j + 1) * B, 0, z), kind)
	end
end
for j = 0, N do
	local x = -half + j * B
	local kind = if j == mid then "CollectorRoad" else "NarrowRoad"
	for i = 0, N - 1 do
		W.road(V3.new(x, 0, -half + i * B), V3.new(x, 0, -half + (i + 1) * B), kind)
	end
end
W.rebuild()
local signals = 0
W.boot({ viewerPos = V3.new(0, 300, 0) })
W.run(1, 30)
for id in net:getNodes() do if W.Signals.HasSignal(id) then signals += 1 end end
print("nodes", #(function() local t = {} for k in net:getNodes() do table.insert(t, k) end return t end)(), "edges", #W.graph:GetEdges(), "signals", signals)
-- endpoints: middle of every block edge (both sides of the street)
local ends = {}
for i = 0, N do
	for j = 0, N - 1 do
		local z = -half + i * B
		local x0 = -half + j * B + B * 0.5
		table.insert(ends, { pos = V3.new(x0, 0, z + 3), out = V3.new(x0 + 20, 0, z - 3) })
		local x = -half + i * B
		local z0 = -half + j * B + B * 0.5
		table.insert(ends, { pos = V3.new(x - 3, 0, z0), out = V3.new(x + 3, 0, z0 + 20) })
	end
end
print("endpoints", #ends)
local res = C.run({ ends = ends, rate = rate, secs = secs, allowCrossing = true, report = 60 })
C.report(("grid N=%d rate=%.3f/pt (%.0f trips/h)"):format(N, rate, rate * #ends * 3600), res)
