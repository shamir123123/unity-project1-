--!nocheck
-- TrafficSignPlanner with a cache must return exactly what it returns without one, edit after
-- edit; and the cached replan should re-solve only the nodes an edit touched.
local H = require("./loader")
local process = require("@lune/process")
H.boot({ server = false })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local Planner = H.require("ReplicatedStorage.Road.TrafficSignPlanner")
local N = tonumber(process.args[1]) or 24
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
local function syncNodes()
	local nodes = {}
	for id, n in net:getNodes() do table.insert(nodes, { id = id, position = n.position }) end
	DataCache.SetNodes(nodes)
end
syncNodes()
DataCache.SetSegments(City.records(net))
local signal: { [number]: boolean } = {}
local cache = Planner.newCache()
local function plan(withCache)
	local opts = Planner.defaultOptions(function(id) return signal[id] == true end)
	return Planner.plan(DataCache.GetSegments(), function(id) return DataCache.GetNodeById(id) end, opts, if withCache then cache else nil)
end
local function ser(list)
	local out = {}
	for _, s in list do
		table.insert(out, string.format("%s|%s|%.4f,%.4f,%.4f|%.4f,%.4f,%.4f|%s|%s|%d", s.key, s.kind, s.pos.X, s.pos.Y, s.pos.Z,
			s.face.X, s.face.Y, s.face.Z, tostring(s.text), tostring(s.arrowRight), s.nodeId))
	end
	return table.concat(out, "\n")
end
local fails = 0
local function check(label)
	local t = os.clock()
	local a = plan(true)
	local tc = os.clock() - t
	t = os.clock()
	local b = plan(false)
	local tu = os.clock() - t
	local same = ser(a) == ser(b)
	if not same then fails += 1 end
	print(string.format("%-34s cached %6.1f ms  full %6.1f ms  signs %4d  %s", label, tc * 1000, tu * 1000, #b, if same then "same" else "DIFFERENT"))
end
local function apply() DataCache.ApplySegmentsDelta(City.delta(net)); syncNodes() end
local function add(a, b, t) local p0, p1, p2, p3 = City.straight(a, b); local s = net:addSegment(p0, p1, p2, p3, t or "CollectorRoad"); apply(); return s end
check("load")
check("replan, nothing changed")
add(V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128))
check("short link across a block")
local s2 = add(V3.new(-N * 64 - 300, 10, 64), V3.new(N * 64 + 300, 10, 64), "AvenueConcrete")
check("avenue across the whole grid")
for id in net:getNodes() do if id % 5 == 0 then signal[id] = true end end
check("signals at every 5th node")
net:removeSegment(s2.id); apply()
check("avenue removed")
for _, s in net:getSegments() do s.roadType = "AvenueConcrete"; net:touchSegment(s.id); break end
apply()
check("one road upgraded in place")
for _, s in net:getSegments() do s.speedLimitOverride = 30; net:touchSegment(s.id); break end
apply()
check("speed override on one road")
DataCache.SetSegments(City.records(net))
check("full re-send (rejoin)")
print(if fails == 0 then "ALL SAME" else (fails .. " DIFFERENT"))
process.exit(0)
