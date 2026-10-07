local H = require("./loader")
H.boot({ server = true })
local ok = 0
local fail = {}
for _, p in { "ReplicatedStorage.Road.RoadConstants", "ReplicatedStorage.Road.BezierUtil", "ReplicatedStorage.Road.RoadTypeCatalog",
	"ReplicatedStorage.Road.RoadNetwork", "ReplicatedStorage.Road.RoadJunctionSolver", "ReplicatedStorage.Road.RoadGeometry",
	"ReplicatedStorage.Road.RoadMeshBuilder", "ReplicatedStorage.Terrain.TerrainMesh", "ReplicatedStorage.Road.RoadNavigationGraph" } do
	local s, e = pcall(H.require, p)
	if s then ok += 1 else table.insert(fail, p .. ": " .. tostring(e)) end
end
print("loaded", ok)
for _, f in fail do print(f) end
