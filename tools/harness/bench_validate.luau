--!nocheck
-- RoadPlacementSnapper.validate (the road tool's per-frame check while dragging): time per call on
-- a big grid, and every candidate's verdict (old and new must agree).
-- Usage (from tools/harness): lune run bench_validate.luau [orig] [gridN]
local H = require("./loader")
local process = require("@lune/process")
local orig = process.args[1] == "orig"
local N = tonumber(process.args[2]) or 30
if orig then
	H.patches["StarterPlayer.StarterPlayerScripts.Controllers.RoadPlacementSnapper"] = function()
		return process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.Controllers.RoadPlacementSnapper.luau" }).stdout
	end
	H.patches["ReplicatedStorage.Road.RoadNetwork"] = function()
		return process.exec("git", { "show", "5858734:src/ReplicatedStorage.Road.RoadNetwork.luau" }).stdout
	end
end
H.boot({ server = false })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local Snapper = H.require("StarterPlayer.StarterPlayerScripts.Controllers.RoadPlacementSnapper")
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
local nodes = {}
for id, n in net:getNodes() do table.insert(nodes, { id = id, position = n.position }) end
Snapper.setNodesFull(nodes)
Snapper.setSegmentsFull(City.records(net))
local state = 5
local function rnd(lo, hi) state = (state * 1103515245 + 12345) % 2147483648; return lo + (hi - lo) * (state / 2147483648) end
local half = N * 64
local verdicts = {}
local t = os.clock()
local calls = 0
for i = 1, 60 do
	local a = V3.new(rnd(-half, half), 10, rnd(-half, half))
	local ang = rnd(0, math.pi * 2)
	local len = rnd(40, 600)
	local b = a + V3.new(math.cos(ang) * len, 0, math.sin(ang) * len)
	local err = Snapper.validate(a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b)
	calls += 1
	table.insert(verdicts, tostring(err))
end
local dt = os.clock() - t
local h = 0
local all = table.concat(verdicts, "\n")
for k = 1, #all do h = (h * 31 + string.byte(all, k)) % 2147483647 end
local ok = 0 for _, v in verdicts do if v == "nil" then ok += 1 end end
print(string.format("%d segments: validate %.1f ms per call (%d calls, %d accepted); verdict digest %d", #City.records(net), dt * 1000 / calls, calls, ok, h))
process.exit(0)
