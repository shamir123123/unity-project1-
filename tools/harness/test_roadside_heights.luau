--!nocheck
-- Roadside props stand ON the ground beside the road: every lamp, tree, cabinet, hydrant, name
-- blade, yield sign, traffic sign and signal pole is measured against the road's curve (the
-- slab's centre, flat at y = 10 here). The footway top is half the slab plus the kerb above it
-- (RoadGeometry: TOP + SIDEWALK_HEIGHT); beside a kerbless road it is the asphalt top.
-- Usage (from tools/harness): lune run test_roadside_heights.luau [rev]   (rev: old renderer code)
local H = require("./loader")
local process = require("@lune/process")
local rev = process.args[1]
if rev then
	for _, path in { "ReplicatedStorage.Road.RoadSceneRenderer", "ReplicatedStorage.Road.TrafficSignPlanner",
		"ServerScriptService.Services.Traffic.IntersectionDetector" } do
		H.patches[path] = function()
			return process.exec("git", { "show", rev .. ":src/" .. path .. ".luau" }).stdout
		end
	end
end
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
local SS = H.game:GetService("ServerStorage")
local RS = H.game:GetService("ReplicatedStorage")
local function folder(name, parent) local f = I.new("Folder"); f.Name = name; f.Parent = parent; return f end
-- Templates, each pivoted at its base like the real ones.
local function prop(name, parent, h)
	local m = I.new("Model"); m.Name = name
	local p = I.new("Part"); p.Name = "Body"; p.Size = V3.new(1, h, 1); p.CFrame = CF.new(0, h / 2, 0); p.Parent = m
	m.WorldPivot = CF.new(0, 0, 0)
	m.Parent = parent
	return m
end
local road = folder("Road", folder("Props", folder("Asset", folder("Templates", SS))))
for _, n in { "StreetLamp", "StreetLampTwin", "FireHydrantProp", "StreetNameSign", "ManholeCover" } do prop(n, road, 3) end
local kit = folder("StreetKit", road.Parent)
for _, n in { "UtilityBox_Large", "UtilityBox_Medium", "UtilityBox_Small" } do prop(n, kit, 2) end
local nature = RS:FindFirstChild("Nature") or folder("Nature", RS)
prop("TestTree", nature, 8)

local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local RoadNavigationGraph = H.require("ReplicatedStorage.Road.RoadNavigationGraph")
local RoadSceneRenderer = H.require("ReplicatedStorage.Road.RoadSceneRenderer")
local RoadTypeCatalog = H.require("ReplicatedStorage.Road.RoadTypeCatalog")
local RoadConstants = H.require("ReplicatedStorage.Road.RoadConstants")
local City = require("./city")
local FOOT = RoadConstants.ROAD_THICKNESS * 0.5 + RoadConstants.SIDEWALK_HEIGHT
local ASPHALT = RoadConstants.ROAD_THICKNESS * 0.5
local ws = H.game:GetService("Workspace")

local function kindOf(inst)
	local n = inst.Name
	for _, k in { "StreetLamp", "UtilityBox", "FireHydrant", "Manhole", "StreetNameSign", "StreetTree" } do
		if string.sub(n, 1, #k) == k and inst.ClassName == "Model" then return k end
	end
	if n == "YieldSignPole" then return "YieldSign" end
	return nil
end
local function baseY(inst)
	if inst.ClassName == "Model" then return inst:GetPivot().Position.Y end
	return inst.CFrame.Position.Y - inst.Size.X * 0.5 -- the pole is a cylinder stood up on end
end

local function run(label, roadType, x)
	local net = RoadNetwork.new()
	-- a long street along Z with a side street T-ing into it: name blades and yield signs
	local a, b, c, d = City.straight(V3.new(x, 10, -300), V3.new(x, 10, 300))
	net:addSegment(a, b, c, d, roadType)
	local e, f, g, h = City.straight(V3.new(x + 300, 10, 0), V3.new(x, 10, 0))
	net:addSegment(e, f, g, h, roadType)
	local nav = RoadNavigationGraph.new(function(seg) return RoadTypeCatalog.getOrDefault(seg.roadType).isRail ~= true end)
	nav:Rebuild(net, {}, {})
	RoadSceneRenderer.init(net, nav, { getSurfaceY = flat })
	for _, s in net:getSegments() do RoadSceneRenderer.renderSegment(s) end
	for id in net:getNodes() do RoadSceneRenderer.refreshNode(id) end
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local seen = {}
	for _, inst in ws:GetDescendants() do
		local k = kindOf(inst)
		if not k then continue end
		local p = baseY(inst) - 10
		local at = inst.ClassName == "Model" and inst:GetPivot().Position or inst.CFrame.Position
		if math.abs(at.X - x) > 400 then continue end
		local r = seen[k] or {}
		seen[k] = r
		r[string.format("%.2f", p)] = (r[string.format("%.2f", p)] or 0) + 1
	end
	local kinds = {}
	for k in seen do table.insert(kinds, k) end
	table.sort(kinds)
	local parts = {}
	for _, k in kinds do
		local hs = {}
		for hgt, n in seen[k] do table.insert(hs, hgt .. "x" .. n) end
		table.sort(hs)
		table.insert(parts, k .. " " .. table.concat(hs, ","))
	end
	print(string.format("%-34s (footway top %.2f, asphalt top %.2f) base above curve: %s", label, FOOT, ASPHALT, table.concat(parts, "; ")))
end
run("footways both sides, street trees", RoadTypeCatalog.encodeConfig("CollectorRoad", { trees = "TestTree" }), 0)
run("footway on the left only", RoadTypeCatalog.encodeConfig("CollectorRoad", { sidewalk = "left" }), 2000)
run("no footway", RoadTypeCatalog.encodeConfig("CollectorRoad", { sidewalk = "none", trees = "TestTree" }), 4000)

-- Traffic signs (drawn by the client off TrafficSignPlanner) on a small grid of the same roads.
local Planner = H.require("ReplicatedStorage.Road.TrafficSignPlanner")
local function signs(label, roadType)
	local net = RoadNetwork.new()
	City.grid(net, 3, 128, roadType, V3.new(9000, 10, 0))
	local recs = City.records(net)
	local nodes = net:getNodes()
	local list = Planner.plan(recs, function(id) local n = nodes[id] return n and n.position end, Planner.defaultOptions(function() return false end))
	local hs = {}
	for _, sgn in list do
		local k = string.format("%.2f", sgn.pos.Y - 10)
		hs[k] = (hs[k] or 0) + 1
	end
	local out = {}
	for k, n in hs do table.insert(out, k .. "x" .. n) end
	table.sort(out)
	print(string.format("%-34s traffic sign posts above curve: %s", label, table.concat(out, ",")))
end
signs("signs, footways both sides", "CollectorRoad")
signs("signs, no footway", RoadTypeCatalog.encodeConfig("CollectorRoad", { sidewalk = "none" }))

-- Signal poles (IntersectionDetector -> TrafficLightPlacer) at a signalised four-way.
local Detector = H.require("ServerScriptService.Services.Traffic.IntersectionDetector")
local function poles(label, roadType)
	local net = RoadNetwork.new()
	local c = V3.new(12000, 10, 0)
	for _, d in { V3.new(0, 0, 100), V3.new(0, 0, -100), V3.new(-100, 0, 0), V3.new(100, 0, 0) } do
		local a, b, cc, dd = City.straight(c, c + d)
		net:addSegment(a, b, cc, dd, roadType)
	end
	local graph = RoadNavigationGraph.new()
	graph:Rebuild(net, {})
	local hs, n = {}, 0
	for _, plan in Detector.detect({ getNetwork = function() return net end, getNavigationGraph = function() return graph end }) do
		for _, arm in plan.arms do
			local k = string.format("%.2f", arm.polePos.Y - 10)
			hs[k] = (hs[k] or 0) + 1
			n += 1
		end
	end
	local out = {}
	for k, m in hs do table.insert(out, k .. "x" .. m) end
	table.sort(out)
	print(string.format("%-34s signal poles above curve: %s (%d)", label, table.concat(out, ","), n))
end
poles("poles, footways both sides", "CollectorRoad")
poles("poles, no footway", RoadTypeCatalog.encodeConfig("CollectorRoad", { sidewalk = "none" }))
process.exit(0)
