--!nocheck
-- RoadNetwork.resolveCrossings alone: a long diagonal across an N x N grid, timed in parts
-- (change scan at the top of each pass, the candidate scans, the resolution). Lune-relative.
-- Usage (from tools/harness): lune run bench_crossings.luau [N] [orig|head]
local H = require("./loader")
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 16
local which = process.args[2]
H.patches["ReplicatedStorage.Road.RoadNetwork"] = function(src)
	if which == "orig" then
		src = process.exec("git", { "show", "5858734:src/ReplicatedStorage.Road.RoadNetwork.luau" }).stdout
	elseif which == "prof" then
		src = require("@lune/fs").readFile(process.env.PROF_SRC)
	elseif which == "head" then
		src = process.exec("git", { "show", "HEAD:src/ReplicatedStorage.Road.RoadNetwork.luau" }).stdout
	end
	return src
end
H.boot({ server = true })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local function run(label, a, b)
	local net = RoadNetwork.new()
	City.grid(net, N, 128, "CollectorRoad")
	net:consumeChanges()
	if H.envShared().__prof then H.envShared().__prof = { detect = 0, scan = 0, phase2 = 0, hitCalls = 0, full = 0, clean = 0, fullT = 0, passes = 0, mark = 0, near = 0, resolve = 0, samples = 0 } end
	local segs = 0 for _ in net:getSegments() do segs += 1 end
	local t = os.clock()
	local orig = net.resolveCrossings
	local rc = 0
	net.resolveCrossings = function(self, ids)
		local t0 = os.clock()
		orig(self, ids)
		rc += os.clock() - t0
	end
	net:addSegment(a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b, "CollectorRoad")
	local total = os.clock() - t
	local after = 0 for _ in net:getSegments() do after += 1 end
	local P = H.envShared().__prof
	if P then
		print(string.format("   passes %d: change %.1f ms; scans %.1f ms (%d full: mark %.1f ms, %d near; %d clean; tests %.1f ms); resolve %.1f ms; phase2 %.1f ms; samplesHit %d, samplesOf %d",
			P.passes, P.detect * 1000, P.scan * 1000, P.full, P.mark * 1000, P.near, P.clean, P.fullT * 1000, P.resolve * 1000, P.phase2 * 1000, P.hitCalls, P.samples))
		H.envShared().__prof = { detect = 0, scan = 0, phase2 = 0, hitCalls = 0, full = 0, clean = 0, fullT = 0, passes = 0, mark = 0, near = 0, resolve = 0, samples = 0 }
	end
	print(string.format("%-26s %d roads: addSegment %.1f ms (resolveCrossings %.1f ms), roads after %d", label, segs, total * 1000, rc * 1000, after))
end
if which == "prof" then H.envShared().__prof = { detect = 0, scan = 0, phase2 = 0, hitCalls = 0, full = 0, clean = 0, fullT = 0, passes = 0, mark = 0, near = 0, resolve = 0, samples = 0 } end
local half = N * 64
for _ = 1, 2 do
	run("diagonal across the city", V3.new(-half + 10, 10, -half + 20), V3.new(half - 20, 10, half - 10))
	run("across 4 streets", V3.new(-half + 32, 10, -half + 64), V3.new(-half + 32 + 4 * 128, 10, -half + 64 + 10))
end
