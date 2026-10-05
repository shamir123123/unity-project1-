-- Where a frame goes: per-handler (module) heartbeat time on a busy grid.
local C = require("./common")
local W = C.W
local V3 = W.V3
local E = W.E
local process = require("@lune/process")
local N, B = 5, 240
local half = N * B / 2
local net = W.newCity()
for i = 0, N do
	local z = -half + i * B
	for j = 0, N - 1 do W.road(V3.new(-half + j * B, 0, z), V3.new(-half + (j + 1) * B, 0, z), "CollectorRoad") end
	local x = -half + i * B
	for j = 0, N - 1 do W.road(V3.new(x, 0, -half + j * B), V3.new(x, 0, -half + (j + 1) * B), "CollectorRoad") end
end
W.rebuild()
W.boot({ viewerPos = V3.new(0, 300, 0) })
local target = tonumber(process.args[1]) or 400
-- fill
for _ = 1, 60 do
	local need = target - W.census().n
	if need > 0 then W.Driver.SpawnTestCarsNear(V3.new(math.random(-half, half), 0, math.random(-half, half)), math.min(80, need), 400) end
	W.run(1, 30)
end
-- time every exported function of the modules the driver leans on
local fnTime, fnCalls = {}, {}
local function wrapAll(name, tbl, isObj)
	for k, v in tbl do
		if type(v) == "function" then
			local key = name .. "." .. k
			tbl[k] = function(...)
				local t = os.clock()
				local r = table.pack(v(...))
				fnTime[key] = (fnTime[key] or 0) + (os.clock() - t)
				fnCalls[key] = (fnCalls[key] or 0) + 1
				return table.unpack(r, 1, r.n)
			end
		end
	end
end
wrapAll("PathFollower", W.PathFollower)
local gmeta = getmetatable(W.graph)
local idx = gmeta and gmeta.__index
if type(idx) == "table" then wrapAll("Graph", idx) end
wrapAll("Signals", W.Signals)
E.profileHandlers = true
table.clear(E.handlerTime)
local t0 = os.clock()
local frames = 0
for _ = 1, 30 do
	local need = target - W.census().n
	if need > 0 then W.Driver.SpawnTestCarsNear(V3.new(math.random(-half, half), 0, math.random(-half, half)), math.min(80, need), 400) end
	W.run(1, 30); frames += 30
end
local total = os.clock() - t0
print(string.format("PROF cars=%d frames=%d total=%.2fs (%.2f ms/frame)", W.census().n, frames, total, total * 1000 / frames))
local list = {}
for k, v in E.handlerTime do table.insert(list, { k, v }) end
table.sort(list, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(8, #list) do print(string.format("  %6.2f ms/frame  %s", list[i][2] * 1000 / frames, list[i][1]:sub(-70))) end
local fl = {}
for k, v in fnTime do table.insert(fl, { k, v }) end
table.sort(fl, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(14, #fl) do print(string.format("  FN %6.3f ms/frame %8d calls/frame  %s", fl[i][2] * 1000 / frames, fnCalls[fl[i][1]] // frames, fl[i][1])) end
