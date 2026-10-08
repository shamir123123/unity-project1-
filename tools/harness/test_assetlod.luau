--!nocheck
-- AssetLODView: hidden-part counts after camera moves (old vs new slicing must agree), and how
-- long the re-tier takes in sweeps.
-- Usage (from tools/harness): lune run test_assetlod.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
if process.args[1] == "orig" then
	H.patches["StarterPlayer.StarterPlayerScripts.World.AssetLODView"] = function()
		return process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.AssetLODView.luau" }).stdout
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

if View.setForceLod then
	-- Simplest objects: a tiered building and a tree right under the camera show their far levels.
	local bld = I.new("Model"); bld.Name = "Bld"; bld:SetAttribute("LODTiers", true)
	local full = {}
	for k = 1, 3 do
		local p = I.new("Part"); p.Name = "Wall" .. k; p.Size = V3.new(20, 20, 20); p.CFrame = CF.new(-1500, 10, 600 + k)
		p.Parent = bld; table.insert(full, p)
	end
	local shell = I.new("Part"); shell.Name = "LOD_Shell"; shell:SetAttribute("LOD2", true); shell.Transparency = 1
	shell.Size = V3.new(20, 20, 20); shell.CFrame = CF.new(-1500, 10, 600); shell.Parent = bld
	bld.PrimaryPart = shell
	bld.Parent = props
	local tree = I.new("Model"); tree.Name = "Tree"
	local lv = {}
	for l = 0, 2 do
		local p = I.new("Part"); p.Name = "L" .. l; p:SetAttribute("LOD", l); p.Size = V3.new(4, 12, 4)
		p.Transparency = if l == 0 then 0 else 1; p.CFrame = CF.new(-1490, 6, 600); p.Parent = tree; lv[l] = p
	end
	tree.PrimaryPart = lv[0]
	tree.Parent = props
	local function state()
		local fh = 0
		for _, p in full do if p.LocalTransparencyModifier == 1 then fh += 1 end end
		return string.format("walls hidden %d/3, shell T=%s, tree L0 hidden=%s L2 T=%s", fh, tostring(shell.Transparency),
			tostring(lv[0].LocalTransparencyModifier == 1), tostring(lv[2].Transparency))
	end
	local function wait2() for _ = 1, 30 do H.task.wait(0.2) end end
	wait2()
	print("near, normal:        " .. state())
	View.setForceLod(true)
	wait2()
	print("near, forceLod:      " .. state())
	View.setForceLod(false)
	wait2()
	print("near, forceLod off:  " .. state())
end
process.exit(0)
