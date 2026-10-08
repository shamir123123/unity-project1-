--!nocheck
-- RoadSceneRenderer kerbside cabinets: the street kit's UtilityBox_Large/Medium/Small, found in
-- their own folder (not a same-named copy elsewhere), facing the road at the back of the footway,
-- painted from the kit palette -- and a re-render puts the same ones in the same places.
-- Usage (from tools/harness): lune run test_utilityboxes.luau
local H = require("./loader")
local flat = function() return 10 end
local terrainData = setmetatable({ getSurfaceY = flat, getNaturalSurfaceY = flat, getHeightAt = flat }, { __index = function() return function() return 10 end end })
local terrainGrade = setmetatable({}, { __index = function() return function() end end })
H.boot({ server = true, overrides = {
	["ServerScriptService.Services.Terrain.TerrainDataService"] = terrainData,
	["ServerScriptService.Services.Terrain.TerrainGradeService"] = terrainGrade,
} })
H.quietWarn = true
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local C3 = H.roblox.Color3
local SS = H.game:GetService("ServerStorage")
local function folder(name, parent) local f = I.new("Folder"); f.Name = name; f.Parent = parent; return f end
-- A decoy first: a same-named cabinet in a service yard must not be the one used.
local decoyYard = folder("Yard", folder("BusDepot", folder("AAA_Transit", SS)))
local kit = folder("StreetKit", folder("Props", folder("Asset", folder("Templates", SS))))
local SIZES = { UtilityBox_Large = V3.new(3.52, 3.64, 1.52), UtilityBox_Medium = V3.new(2.32, 2.56, 1.22), UtilityBox_Small = V3.new(1.52, 1.96, 1.02) }
local function box(name, parent)
	local m = I.new("Model"); m.Name = name
	m:SetAttribute("Tints", "[[200,202,196],[70,96,74],[206,196,168]]")
	local body = I.new("MeshPart"); body.Name = name; body.Size = SIZES[name]; body.CFrame = CF.new(0, SIZES[name].Y / 2, 0); body.Parent = m
	local paint = I.new("MeshPart"); paint.Name = name .. "_Paint"; paint:SetAttribute("Paint", true)
	paint.Size = SIZES[name]; paint.CFrame = body.CFrame; paint.Parent = m
	local sa = I.new("SurfaceAppearance"); sa.Color = C3.new(1, 1, 1); sa.Parent = paint
	m.PrimaryPart = body
	m.Parent = parent
	return m
end
box("UtilityBox_Large", decoyYard):SetAttribute("Decoy", true)
for name in SIZES do box(name, kit) end

local City = require("./city")
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local RoadNavigationGraph = H.require("ReplicatedStorage.Road.RoadNavigationGraph")
local RoadSceneRenderer = H.require("ReplicatedStorage.Road.RoadSceneRenderer")
local RoadTypeCatalog = H.require("ReplicatedStorage.Road.RoadTypeCatalog")
local RoadConstants = H.require("ReplicatedStorage.Road.RoadConstants")
local net = RoadNetwork.new()
local a, b, c, d = City.straight(V3.new(0, 10, 0), V3.new(0, 10, 1400))
net:addSegment(a, b, c, d, "CollectorRoad")
local nav = RoadNavigationGraph.new(function(seg) return RoadTypeCatalog.getOrDefault(seg.roadType).isRail ~= true end)
nav:Rebuild(net, {}, {})
RoadSceneRenderer.init(net, nav, { getSurfaceY = flat })
local spec = RoadTypeCatalog.getOrDefault("CollectorRoad")
local ws = H.game:GetService("Workspace")
local function render()
	for _, s in net:getSegments() do RoadSceneRenderer.renderSegment(s) end
	local out = {}
	for _, inst in ws:GetDescendants() do
		if inst.ClassName == "Model" and string.sub(inst.Name, 1, 11) == "UtilityBox_" then table.insert(out, inst) end
	end
	table.sort(out, function(x, y) return x:GetPivot().Position.Z < y:GetPivot().Position.Z end)
	return out
end
local boxes = render()
print(string.format("cabinets on a 1400-stud CollectorRoad: %d", #boxes))
local okFace, okLat, painted, decoy, kinds = 0, 0, 0, 0, {}
local maxLat = spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH
local sig = {}
for _, m in boxes do
	local cf = m:GetPivot()
	local p = cf.Position
	-- the road runs along Z at x = 0: the look vector must point back across to it
	if cf.LookVector.X * -math.sign(p.X) > 0.99 then okFace += 1 end
	local body = m:FindFirstChildWhichIsA("MeshPart")
	local depth = body.Size.Z
	if math.abs(p.X) + depth / 2 <= maxLat and math.abs(p.X) > spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH * 0.5 then okLat += 1 end
	local sa
	for _, dd in m:GetDescendants() do if dd.ClassName == "SurfaceAppearance" then sa = dd end end
	local col = sa.Color
	local r, g, bb = math.floor(col.R * 255 + 0.5), math.floor(col.G * 255 + 0.5), math.floor(col.B * 255 + 0.5)
	if (r == 200 and g == 202 and bb == 196) or (r == 70 and g == 96 and bb == 74) or (r == 206 and g == 196 and bb == 168) then painted += 1 end
	if m:GetAttribute("Decoy") then decoy += 1 end
	kinds[body.Name] = (kinds[body.Name] or 0) + 1
	table.insert(sig, string.format("%s@%.2f,%.2f/%d,%d,%d", body.Name, p.X, p.Z, r, g, bb))
end
print(string.format("facing the road %d/%d, inside the footway's back half %d/%d, painted from the palette %d/%d, decoys used %d",
	okFace, #boxes, okLat, #boxes, painted, #boxes, decoy))
local kl = {}
for k, n in kinds do table.insert(kl, k .. "=" .. n) end
table.sort(kl)
print("kinds: " .. table.concat(kl, ", "))
local again = render()
local sig2 = {}
for _, m in again do
	local p = m:GetPivot().Position
	local body = m:FindFirstChildWhichIsA("MeshPart")
	local sa
	for _, dd in m:GetDescendants() do if dd.ClassName == "SurfaceAppearance" then sa = dd end end
	local col = sa.Color
	table.insert(sig2, string.format("%s@%.2f,%.2f/%d,%d,%d", body.Name, p.X, p.Z, math.floor(col.R * 255 + 0.5), math.floor(col.G * 255 + 0.5), math.floor(col.B * 255 + 0.5)))
end
print("re-render identical:", table.concat(sig, ";") == table.concat(sig2, ";"), #again)
