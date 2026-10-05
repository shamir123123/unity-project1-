-- Smoke test: the benchmark module loads and runs a short ramp in the lab.
local C = require("./common")
local W = C.W
local V3 = W.V3
local E = W.E
local net = W.newCity()
local N, B = 4, 240
local half = N * B / 2
for i = 0, N do
	local z = -half + i * B
	for j = 0, N - 1 do W.road(V3.new(-half + j * B, 0, z), V3.new(-half + (j + 1) * B, 0, z), "CollectorRoad") end
	local x = -half + i * B
	for j = 0, N - 1 do W.road(V3.new(x, 0, -half + j * B), V3.new(x, 0, -half + (j + 1) * B), "CollectorRoad") end
end
W.rebuild()
W.boot({ viewerPos = V3.new(0, 300, 0) })
local Bench = W.req("ServerScriptService.Services.Debug.TrafficBenchmark")
local done = false
E.task.spawn(function()
	local r = Bench.Run({ steps = { 50, 150, 300 }, settle = 3, sample = 4, spread = 400 })
	print("BENCH summary server=" .. tostring(r.summary and r.summary.server) .. " highEnd=" .. tostring(r.summary and r.summary.highEnd))
	done = true
end)
local t = 0
while not done and t < 200 do W.run(1, 30); t += 1 end
for _, e in E.errors do print("ERR " .. e:sub(1, 300)) end
