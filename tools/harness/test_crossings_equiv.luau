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
-- VERIFY=1: every pass after the first also re-reads every segment and fails if one changed
-- without being marked dirty (what the dirty-only change scan relies on).
if process.env.VERIFY then
	H.patches["ReplicatedStorage.Road.RoadNetwork"] = function(src)
		local anchor = "\t\telse\n\t\t\tfor id in self._dirtySeg do\n"
		local i = string.find(src, anchor, 1, true)
		assert(i, "VERIFY: anchor not found")
		local check = "\t\telse\n\t\t\tfor id, S in self._segments do\n"
			.. "\t\t\t\tlocal o = seen[id]\n"
			.. "\t\t\t\tif (not o or o[1] ~= S.p0 or o[2] ~= S.p1 or o[3] ~= S.p2 or o[4] ~= S.p3 or o[5] ~= S.startNode or o[6] ~= S.endNode or o[7] ~= S.vMode) and not self._dirtySeg[id] then\n"
			.. "\t\t\t\t\terror(\"VERIFY: segment \" .. id .. \" changed without a dirty mark\")\n"
			.. "\t\t\t\tend\n\t\t\tend\n"
			.. "\t\t\tshared.verified = (shared.verified or 0) + 1\n"
			.. "\t\t\tfor id in self._dirtySeg do\n"
		return string.sub(src, 1, i - 1) .. check .. string.sub(src, i + #anchor)
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
if process.env.VERIFY then
	print(string.format("VERIFY: %d later passes re-read every segment; every change was dirty-marked unless errors > 0 above", H.envShared().verified or 0))
end
process.exit(0)
