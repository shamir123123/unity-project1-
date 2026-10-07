--!nocheck
-- Prints a digest of every cell's road specs after a scripted edit sequence; run against the
-- baseline and the patched RoadPieces, the digests must match.
local H = require("./loader")
local terrainStub = { setGroundCap = function() end, markDirty = function() end, request = function() end }
H.boot({ server = false, overrides = { ["ReplicatedStorage.Terrain.TerrainMeshView"] = terrainStub } })
H.quietWarn = true
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local RoadPieces = H.require("StarterPlayer.StarterPlayerScripts.World.RoadPieces")
local N = 6
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
local notified = 0
RoadPieces.start(function(d) for _ in d do notified += 1 end end)
DataCache.SetSegments(City.records(net))
local function settle() H.task.wait(); while not RoadPieces.isIdle() do H.task.wait() end end
settle()
local function apply() DataCache.ApplySegmentsDelta(City.delta(net)); settle() end
local function add(a, b, t) local p0, p1, p2, p3 = City.straight(a, b); local s = net:addSegment(p0, p1, p2, p3, t or "CollectorRoad"); apply(); return s end
add(V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128))
add(V3.new(-256, 10, -256), V3.new(0, 10, 0))
local s3 = add(V3.new(N * 64 + 300, 10, 0), V3.new(N * 64 + 700, 10, 0), "AvenueConcrete")
add(V3.new(-N * 64, 10, 64), V3.new(-N * 64 - 300, 10, 64), "NarrowRoad")
net:removeSegment(s3.id); apply()
-- retype one in place, the way an upgrade does
for _, s in net:getSegments() do s.roadType = "AvenueConcrete"; net:touchSegment(s.id); break end
apply()

local function ser(v, out)
	local t = typeof(v)
	if t == "table" then
		local keys = {}
		for k in v do table.insert(keys, tostring(k)) end
		table.sort(keys)
		table.insert(out, "{")
		for _, k in keys do
			table.insert(out, k .. "=")
			local val = v[k]; if val == nil then val = v[tonumber(k)] end
			ser(val, out)
		end
		table.insert(out, "}")
	elseif t == "Vector3" then table.insert(out, string.format("%.4f,%.4f,%.4f", v.X, v.Y, v.Z))
	else table.insert(out, tostring(v)) end
end
local cells = {}
for x = -10, 10 do for z = -10, 10 do
	local key = x .. "," .. z
	local specs = RoadPieces.specsForCell(key)
	if #specs > 0 then
		local parts = {}
		for _, sp in specs do local o = {}; ser(sp, o); table.insert(parts, table.concat(o)) end
		table.sort(parts)
		cells[key] = table.concat(parts, "|")
	end
end end
local keys = {}
for k in cells do table.insert(keys, k) end
table.sort(keys)
local h = 0
for _, k in keys do
	local str = k .. cells[k]
	for i = 1, #str, 7 do h = (h * 31 + string.byte(str, i)) % 2147483647 end
end
print(string.format("cells=%d digest=%d notifiedCells=%d", #keys, h, notified))
