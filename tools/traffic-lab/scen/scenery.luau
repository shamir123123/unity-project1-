-- Route choice by trip group: two ways from S to G, the east one 8% longer. Trees line the east
-- street and homes line the west one. Commuters take the short west way; leisure takes the
-- green east one; freight keeps off the west housing street.
local C = require("./common")
local W = C.W
local V3 = W.V3
local E = W.E
local net = W.newCity()
local xw, xe = -100, 116
W.road(V3.new(0, 0, -320), V3.new(0, 0, -200), "Road")
W.road(V3.new(0, 0, -200), V3.new(xw, 0, -200), "Road")
W.road(V3.new(0, 0, -200), V3.new(xe, 0, -200), "Road")
W.road(V3.new(xw, 0, -200), V3.new(xw, 0, 200), "Road")
W.road(V3.new(xe, 0, -200), V3.new(xe, 0, 200), "Road")
W.road(V3.new(xw, 0, 200), V3.new(0, 0, 200), "Road")
W.road(V3.new(xe, 0, 200), V3.new(0, 0, 200), "Road")
W.road(V3.new(0, 0, 200), V3.new(0, 0, 320), "Road")
local g = W.rebuild()
local Scenery = W.req("ServerScriptService.Services.Road.RoadSceneryService")
local DriverProfile = W.req("ReplicatedStorage.Road.DriverProfile")
local city = E.Workspace:FindFirstChild("_City") or E.Instance.new("Folder")
city.Name = "_City"; city.Parent = E.Workspace
local nature = E.Instance.new("Folder"); nature.Name = "Nature"; nature.Parent = city
for z = -190, 190, 12 do
	for _, dx in { -14, 14 } do
		local p = E.Instance.new("Part"); p.Name = "Tree"; p.Position = V3.new(xe + dx, 0, z); p.Parent = nature
	end
end
local homes = {}
for z = -180, 180, 30 do
	table.insert(homes, { bpId = "h" .. z, zone = "Residential", position = V3.new(xw - 30, 0, z) })
end
local fakeBuildings = { listBuildings = function() return homes end }
local fakeCoverage = { getPollutionAt = function() return 0 end, getNoiseAt = function() return 0 end, getVersion = function() return 1 end }
Scenery.Init(W.RoadService, fakeBuildings, fakeCoverage)
Scenery.ScanNow()
for segId in g._edgesBySegment do
	local look = Scenery.GetLook(segId)
	if look and (math.abs(look.scenic) > 0.01 or look.residential > 0) then
		print(string.format("LOOK seg=%s scenic=%.2f residential=%.2f", tostring(segId), look.scenic, look.residential))
	end
end
local S, G = V3.new(0, 0, -300), V3.new(0, 0, 300)
local function side(profile)
	local pts, route = g:FindPath(S, G, false, nil, profile)
	if not route then return "none" end
	local sumX, n = 0, 0
	for _, p in pts do sumX += p.X; n += 1 end
	return if sumX / n < 0 then "west" else "east"
end
local res = {
	commuter = side(DriverProfile.DEFAULT), leisure = side(DriverProfile.LEISURE),
	freight = side(DriverProfile.FREIGHT), visitor = side(DriverProfile.VISITOR), none = side(nil),
}
print(string.format("SCENERY commuter=%s leisure=%s freight=%s visitor=%s objective=%s",
	res.commuter, res.leisure, res.freight, res.visitor, res.none))
local ok = res.commuter == "west" and res.leisure == "east" and res.freight == "east" and res.none == "west"
print(if ok then "SCENERY PASS" else "SCENERY FAIL")
