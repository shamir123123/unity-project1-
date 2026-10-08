--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local settingsStub = { get = function(k) if k == "graphicsPreset" then return "Medium" end return nil end, onChanged = function() end }
H.boot({ server = false, overrides = { ["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub } })
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local Lighting = H.game:GetService("Lighting")
Lighting.ClockTime = 12
local city = I.new("Folder"); city.Name = "_City"; city.Parent = ws
local roads = I.new("Folder"); roads.Name = "Roads"; roads.Parent = city
local signals = I.new("Folder"); signals.Name = "TrafficLights"; signals.Parent = city
local function lamp(x, z)
	local seg = I.new("Model"); seg.Name = "Segment_" .. x .. "_" .. z; seg.Parent = roads
	local m = I.new("Model"); m.Name = "StreetLamp_1R"; m.Parent = seg
	local lens = I.new("Part"); lens.Name = "Lens"; lens.CFrame = CF.new(x, 12, z); lens.Material = H.roblox.Enum.Material.Neon; lens.Parent = m
	local l = I.new("SpotLight"); l.Enabled = true; l.Parent = lens
	return l
end
-- A bridge pole with two arms: the light hangs on Lamp, the glow is the LampLens under each.
local bridge = I.new("Model"); bridge.Name = "Bridge"; bridge.Parent = roads
local pole = I.new("Model"); pole.Name = "LampPole"; pole.Parent = bridge
local bridgeLens = {}
for k, dz in { -3, 3 } do
	local housing = I.new("Part"); housing.Name = "Lamp"; housing.CFrame = CF.new(30, 14, dz); housing.Material = H.roblox.Enum.Material.SmoothPlastic; housing.Parent = pole
	local ll = I.new("Part"); ll.Name = "LampLens"; ll.CFrame = CF.new(30, 13.8, dz); ll.Material = H.roblox.Enum.Material.Neon; ll.Parent = pole
	local b = I.new("SpotLight"); b.Parent = housing
	bridgeLens[k] = ll
end
local lights = {}
for i = 1, 60 do table.insert(lights, lamp(i * 20, 0)) end
local sig = I.new("Model"); sig.Name = "TrafficLight_1_1"; sig.Parent = signals
local red = I.new("Part"); red.Name = "Lens"; red.CFrame = CF.new(0, 10, 0); red.Parent = sig
local sl = I.new("PointLight"); sl.Enabled = true; sl.Parent = red
ws.CurrentCamera.CFrame = CF.new(0, 200, 0) * CF.Angles(-1.2, 0, 0)
local View = H.require("StarterPlayer.StarterPlayerScripts.World.StreetLightView")
View.Start()
local function count() local n = 0 for _, l in lights do if l.Enabled then n += 1 end end return n end
local function glowing()
	local neon = H.roblox.Enum.Material.Neon
	local n = 0
	for _, l in lights do if l.Parent.Material == neon then n += 1 end end
	local b = 0
	for _, ll in bridgeLens do if ll.Material == neon then b += 1 end end
	return string.format("lenses glowing %d/%d, bridge lenses %d/2, signal lens %s", n, #lights, b, tostring(red.Material))
end
H.task.wait(0.6)
print("noon: lamps lit", count(), "signal light still on:", sl.Enabled)
print("noon: " .. glowing())
Lighting.ClockTime = 22
H.task.wait(0.6)
print("night (Medium = 32): lamps lit", count(), "signal light still on:", sl.Enabled)
local nearest = lights[1].Enabled and not lights[60].Enabled
print("nearest lit, farthest dark:", nearest)
print("night: " .. glowing())
local late = lamp(5, 5)
H.task.wait(0.6)
print("lamp added at night near focus lit:", late.Enabled)
Lighting.ClockTime = 7
H.task.wait(0.6)
print("morning: lamps lit", count(), late.Enabled)
print("morning: " .. glowing())
process.exit(0)
