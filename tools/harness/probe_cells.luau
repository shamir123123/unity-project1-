--!nocheck
-- Which pieces does one placement rebuild, and how many of them actually change?
local H = require("./loader")
local terrainStub = { setGroundCap = function() end, markDirty = function() end, request = function() end }
H.patches["StarterPlayer.StarterPlayerScripts.World.RoadPieces"] = function(src)
	return (string.gsub(src, "\nreturn RoadPieces%s*$", "\nRoadPieces._debugPieces = function() return _pieces end\nRoadPieces._debugCells = function() return _byCell end\nreturn RoadPieces\n"))
end
H.boot({ server = false, overrides = { ["ReplicatedStorage.Terrain.TerrainMeshView"] = terrainStub } })
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local RoadPieces = H.require("StarterPlayer.StarterPlayerScripts.World.RoadPieces")
local RoadMeshBuilder = H.require("ReplicatedStorage.Road.RoadMeshBuilder")
local N = 12
local net = RoadNetwork.new()
City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
local last
RoadPieces.start(function(d) last = d end)
DataCache.SetSegments(City.records(net))
while not RoadPieces.isIdle() do H.task.wait() end

local function snapshot()
	local cells = {}
	for k in RoadPieces._debugCells() do cells[k] = RoadPieces.specsForCell(k) end
	return cells
end
local function deepEq(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in a do if not deepEq(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end
local before = {}
for k in last do end
-- per-cell spec multiset comparison
local function cellSig(specs)
	local sigs = {}
	for _, s in specs do table.insert(sigs, RoadMeshBuilder.encode and #specs or 0) end
	return #specs
end
local mk = {}
for k, v in RoadPieces._debugPieces() do mk[k] = v end
local a, b, c, d = City.straight(V3.new(64, 10, -N * 64), V3.new(64, 10, -N * 64 + 128))
net:addSegment(a, b, c, d, "CollectorRoad")
local delta = City.delta(net)
DataCache.ApplySegmentsDelta(delta)
H.task.wait()
while not RoadPieces.isIdle() do H.task.wait() end
local nDirty = 0
for k in last do nDirty += 1 end
print("dirty cells", nDirty)
local after = RoadPieces._debugPieces()
local changedCells, sameCells = {}, {}
for key, p in after do
	local o = mk[key]
	if not o then print("new piece", key, p.cell) changedCells[p.cell] = true
	elseif o ~= p then
		if o.cell == p.cell and deepEq(o.specs, p.specs) then print("rebuilt but IDENTICAL", key, p.cell) sameCells[p.cell] = true
		else print("rebuilt and changed", key, o.cell, p.cell) changedCells[p.cell] = true changedCells[o.cell] = true end
	end
end
for key, o in mk do if not after[key] then print("removed piece", key, o.cell) changedCells[o.cell] = true end end
local nc = 0 for _ in changedCells do nc += 1 end
print("cells that really changed:", nc)
