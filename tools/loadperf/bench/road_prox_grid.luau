local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = "../bundle_after" })
local RS = rt.game:GetService("ReplicatedStorage")
local RP = rt.require(RS.Road.RoadProximity)
local RoadTypeCatalog = rt.require(RS.Road.RoadTypeCatalog)
local Vector3 = require("@lune/roblox").Vector3
local types = {}
for name in RoadTypeCatalog.Types do table.insert(types, name) end
local seed = 99
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
local NSEG = tonumber(process.args[1]) or 3000
local NPROP = tonumber(process.args[2]) or 6000
local segs = {}
for i = 1, NSEG do
	local x, z = (rnd() - 0.5) * 7000, (rnd() - 0.5) * 7000
	local ang = rnd() * math.pi * 2
	local len = 40 + rnd() * 200
	local dx, dz = math.cos(ang) * len, math.sin(ang) * len
	local y = rnd() * 6
	segs[i] = { p0 = Vector3.new(x, y, z), p1 = Vector3.new(x + dx / 3, y, z + dz / 3 + 20 * (rnd() - 0.5)),
		p2 = Vector3.new(x + 2 * dx / 3, y, z + 2 * dz / 3), p3 = Vector3.new(x + dx, y, z + dz), roadType = types[1 + math.floor(rnd() * #types)] }
end
local props = {}
for i = 1, NPROP do props[i] = { Vector3.new((rnd() - 0.5) * 7000, rnd() * 6, (rnd() - 0.5) * 7000), 1 + rnd() * 6, rnd() * 20 } end
local t0 = os.clock()
local brute = {}
for i, p in props do brute[i] = RP.isPointNearRoad(segs, p[1], p[2], p[3]) end
local tB = os.clock() - t0
t0 = os.clock()
local grid = RP._segmentGrid(segs)
local mism, hits = 0, 0
for i, p in props do
	local r = RP.isPointNearRoad(RP._segmentsNear(grid, p[1], p[2]), p[1], p[2], p[3])
	if r ~= brute[i] then mism += 1 end
	if r then hits += 1 end
end
local tG = os.clock() - t0
print(string.format("segments=%d props=%d hits=%d  brute %.2fs  grid %.3fs  mismatches %d", NSEG, NPROP, hits, tB, tG, mism))
