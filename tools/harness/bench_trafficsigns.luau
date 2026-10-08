--!nocheck
-- TrafficSignView: cost of a sweep after a camera move and of the replan after a road edit,
-- plus a digest of what ends up drawn (old and new must agree).
-- Usage (from tools/harness): lune run bench_trafficsigns.luau [orig] [gridN]
local H = require("./loader")
local process = require("@lune/process")
local orig = process.args[1] == "orig"
local N = tonumber(process.args[2]) or 24
H.patches["StarterPlayer.StarterPlayerScripts.World.TrafficSignView"] = function(src)
	if orig then
		src = process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.TrafficSignView.luau" }).stdout
	end
	src = string.gsub(src, "\nreturn TrafficSignView%s*$", "\nTrafficSignView._sweep = sweep\nTrafficSignView._replan = replan\nTrafficSignView._active = _active\nreturn TrafficSignView\n")
	-- count placements
	src = string.gsub(src, "(local function place%(model: Model, [^)]*%)[^\n]*\n)", "%1\tshared.places = (shared.places or 0) + 1\n", 1)
	return src
end
local settingsStub = { get = function(k) if k == "graphicsPreset" then return "High" end return nil end, onChanged = function() end }
local pressureStub = { lerpInt = function(a) return a end, lerp = function(a) return a end, detail = function() return 1 end, level = function() return 0 end }
H.boot({ server = false, overrides = {
	["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub,
	["StarterPlayer.StarterPlayerScripts.Core.RenderPressure"] = pressureStub,
} })
H.quietWarn = true
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local City = require("./city")
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local net = RoadNetwork.new()
local count = City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
local nodes = {}
for id, n in net:getNodes() do table.insert(nodes, { id = id, position = n.position }) end
table.sort(nodes, function(a, b) return a.id < b.id end)
DataCache.SetNodes(nodes)
DataCache.SetSegments(City.records(net))
-- Signals at every third node: four pole models each, named as TrafficLightPlacer names them.
local city = I.new("Folder"); city.Name = "_City"; city.Parent = ws
local lights = I.new("Folder"); lights.Name = "TrafficLights"; lights.Parent = city
local poles = 0
for i, n in nodes do
	if i % 3 == 0 then
		for arm = 1, 4 do
			local m = I.new("Model"); m.Name = "TrafficLight_" .. n.id .. "_" .. arm
			local p = I.new("Part"); p.Name = "Pole"; p.Size = V3.new(0.6, 14, 0.6)
			local off = ({ V3.new(9, 0, 9), V3.new(-9, 0, 9), V3.new(9, 0, -9), V3.new(-9, 0, -9) })[arm]
			p.CFrame = CF.new(n.position + off + V3.new(0, 7, 0)); p.Parent = m
			m.PrimaryPart = p
			m.Parent = lights
			poles += 1
		end
	end
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.TrafficSignView")
local cam = ws.CurrentCamera
cam.CFrame = CF.new(0, 180, 200) * CF.Angles(-0.9, 0, 0)
View.Start()
H.task.wait(0.1)
local S = H.envShared()
local function timed(label, fn)
	local p0 = S.places or 0
	local t = os.clock()
	fn()
	local n = 0
	for _ in View._active do n += 1 end
	print(string.format("%-34s %7.1f ms  placements %4d  active %3d", label, (os.clock() - t) * 1000, (S.places or 0) - p0, n))
end
timed("replan (city load)", View._replan)
timed("first sweep", View._sweep)
cam.CFrame = CF.new(500, 180, 300) * CF.Angles(-0.9, 0, 0)
timed("sweep after a 500-stud pan", View._sweep)
cam.CFrame = CF.new(520, 180, 330) * CF.Angles(-0.9, 0, 0)
timed("sweep after a 30-stud pan", View._sweep)
-- A road edit: one short link added, sent as the delta the server sends.
do
	local a = V3.new(64, 10, -N * 64)
	local p0, p1, p2, p3 = City.straight(a, a + V3.new(0, 0, 128))
	net:addSegment(p0, p1, p2, p3, "CollectorRoad")
	local nodes2 = {}
	for id, n in net:getNodes() do table.insert(nodes2, { id = id, position = n.position }) end
	DataCache.SetNodes(nodes2)
	DataCache.ApplySegmentsDelta(City.delta(net))
end
timed("replan after a road edit", View._replan)
timed("sweep after it", View._sweep)
local rows = {}
for key, a in View._active do
	local pv = a.model:GetPivot().Position
	local post = a.model:FindFirstChild("Post")
	local gui = false
	for _, d in a.model:GetDescendants() do if d:IsA("SurfaceGui") and d.Enabled then gui = true end end
	table.insert(rows, string.format("%s@%.1f,%.1f,%.1f p%s g%s", key, pv.X, pv.Y, pv.Z, tostring(post and post.LocalTransparencyModifier), tostring(gui)))
end
table.sort(rows)
local h = 0
for _, r in rows do for i = 1, #r do h = (h * 31 + string.byte(r, i)) % 2147483647 end end
print(string.format("%d segments, %d poles; drawn-state digest %d over %d signs", count, poles, h, #rows))
process.exit(0)
