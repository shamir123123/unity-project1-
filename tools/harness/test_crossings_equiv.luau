--!nocheck
-- RoadNetwork.resolveCrossings: the network after a seeded run of random placements (straight
-- and curved, long and short, through junctions and past dead-ends) must be identical to the
-- baseline's, id for id. Prints a digest and the time spent adding.
-- Usage (from tools/harness): lune run test_crossings_equiv.luau [orig] [seed] [count]
local H = require("./loader")
local process = require("@lune/process")
local orig = process.args[1] == "orig"
local seed = tonumber(process.args[2]) or 7
local count = tonumber(process.args[3]) or 60
if orig then
	H.patches["ReplicatedStorage.Road.RoadNetwork"] = function()
		return process.exec("git", { "show", "5858734:src/ReplicatedStorage.Road.RoadNetwork.luau" }).stdout
	end
end
H.boot({ server = true })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local net = RoadNetwork.new()
City.grid(net, 10, 128, "CollectorRoad")
net:consumeChanges()
-- Deterministic LCG (the same stream on both runs).
local state = seed
local rng = {}
function rng:NextNumber(lo, hi)
	state = (state * 1103515245 + 12345) % 2147483648
	return lo + (hi - lo) * (state / 2147483648)
end
local types = { "CollectorRoad", "AvenueConcrete", "NarrowRoad", "CollectorRoad" }
local spent = 0
local fails = 0
for i = 1, count do
	local a = V3.new(rng:NextNumber(-700, 700), 10, rng:NextNumber(-700, 700))
	local len = if i % 3 == 0 then rng:NextNumber(400, 1300) else rng:NextNumber(40, 300)
	local ang = rng:NextNumber(0, math.pi * 2)
	local b = a + V3.new(math.cos(ang) * len, 0, math.sin(ang) * len)
	local p1, p2
	if i % 4 == 0 then
		local n = V3.new(-(b - a).Z, 0, (b - a).X).Unit * len * 0.25
		p1, p2 = a:Lerp(b, 1 / 3) + n, a:Lerp(b, 2 / 3) - n
	else
		p1, p2 = a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3)
	end
	local t = os.clock()
	local ok = pcall(function() net:addSegment(a, p1, p2, b, types[(i % #types) + 1]) end)
	spent += os.clock() - t
	if not ok then fails += 1 end
	net:consumeChanges()
end
local rows = {}
local function v(p) return string.format("%.6f,%.6f,%.6f", p.X, p.Y, p.Z) end
for id, s in net:getSegments() do
	table.insert(rows, string.format("s%d|%s|%s|%s|%s|%d|%d|%s|%s", id, v(s.p0), v(s.p1), v(s.p2), v(s.p3), s.startNode, s.endNode, s.roadType, tostring(s.vMode)))
end
for id, n in net:getNodes() do
	local segs = table.clone(n.segments); table.sort(segs)
	table.insert(rows, string.format("n%d|%s|%s", id, v(n.position), table.concat(segs, ",")))
end
table.sort(rows)
local h = 0
for _, r in rows do for k = 1, #r do h = (h * 31 + string.byte(r, k)) % 2147483647 end end
local segs, nodes = 0, 0
for _ in net:getSegments() do segs += 1 end
for _ in net:getNodes() do nodes += 1 end
print(string.format("seed %d: %d placements (%d errors) -> %d segments, %d nodes; digest %d; adding took %.0f ms",
	seed, count, fails, segs, nodes, h, spent * 1000))
process.exit(0)
