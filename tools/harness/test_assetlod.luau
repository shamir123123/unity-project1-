--!nocheck
-- AssetLODView: hidden-part counts after camera moves (old vs new slicing must agree), and how
-- long the re-tier takes in sweeps.
-- Usage (from tools/harness): lune run test_assetlod.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
if process.args[1] == "orig" then
	H.patches["StarterPlayer.StarterPlayerScripts.World.AssetLODView"] = function()
		return process.exec("git", { "show", "HEAD:src/StarterPlayer.StarterPlayerScripts.World.AssetLODView.luau" }).stdout
	end
end
local settingsStub = { get = function(k) if k == "renderDistance" then return 1 end return nil end, onChanged = function() end }
H.boot({ server = false, overrides = { ["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub } })
H.quietWarn = true
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local city = I.new("Folder"); city.Name = "_City"; city.Parent = ws
local props = I.new("Folder"); props.Name = "Props"; props.Parent = city
local parts = {}
local n = 0
for x = -20, 20 do
	for z = -20, 20 do
		n += 1
		local m = I.new("Model"); m.Name = "Prop" .. n
		for k = 1, 4 do
			local p = I.new("Part"); p.Name = "P" .. k
			p.Size = V3.new(0.3 * k, 0.3 * k, 0.3 * k)
			p.CFrame = CF.new(x * 150, 2, z * 150)
			p.Parent = m
			table.insert(parts, p)
		end
		m.PrimaryPart = m:FindFirstChild("P4")
		m.Parent = props
	end
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.AssetLODView")
View.Start()
View.setCityLoaded(true)
local function hidden() local c = 0 for _, p in parts do if p.LocalTransparencyModifier == 1 then c += 1 end end return c end
local cam = ws.CurrentCamera
local function settle(label)
	local last, same, t = -1, 0, 0
	while same < 8 and t < 60 do
		H.task.wait(0.2); t += 0.2
		local h = hidden()
		if h == last then same += 1 else same = 0; last = h end
	end
	print(string.format("%-22s hidden parts %5d / %d", label, last, #parts))
end
cam.CFrame = CF.new(0, 120, 0)
settle("camera at centre")
cam.CFrame = CF.new(2800, 120, 2800)
settle("camera at a corner")
cam.CFrame = CF.new(-1500, 400, 600)
settle("camera elsewhere, high")
process.exit(0)
