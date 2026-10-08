--!nocheck
-- SolarTrackerView: panel poses after a sun move, old (CFrame writes) vs new (BulkMoveTo).
-- Usage (from tools/harness): lune run test_solar.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
if process.args[1] == "orig" then
	H.patches["StarterPlayer.StarterPlayerScripts.World.SolarTrackerView"] = function()
		return process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.SolarTrackerView.luau" }).stdout
	end
end
H.boot({ server = false })
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local Lighting = H.game:GetService("Lighting")
local sun = V3.new(0.4, 0.6, 0.2).Unit
Lighting._props.GetSunDirection = function() return sun end
ws._props.BulkMoveTo = function(_, parts, cfs) for i, p in parts do p.CFrame = cfs[i] end end
local panels = {}
for f = 1, 3 do
	local farm = I.new("Model"); farm.Name = "SolarFarm" .. f
	local root = I.new("Part"); root.Name = "Root"; root.CFrame = CF.new(f * 300, 0, 0) * CF.Angles(0, f * 0.4, 0); root.Parent = farm
	farm.PrimaryPart = root
	for r = 1, 5 do
		local row = I.new("Model"); row.Name = "Row" .. r
		local axis = I.new("Part"); axis.Name = "Tube"; axis.CFrame = root.CFrame * CF.new(0, 3, r * 12); axis.Parent = row
		row.PrimaryPart = axis
		for k = 1, 3 do
			local p = I.new("Part"); p.Name = "Row_Panels" .. k; p.CFrame = axis.CFrame * CF.new(k * 4 - 8, 0.5, 0); p.Parent = row
			table.insert(panels, p)
		end
		row.Parent = farm
		row:AddTag("SolarTracker")
	end
	farm.Parent = ws
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.SolarTrackerView")
View.Start()
H.task.wait(0.3)
local hb = H.game:GetService("RunService").Heartbeat
local function run(sec) for _ = 1, math.floor(sec * 60) do hb:Fire(1 / 60) end end
run(1)
sun = V3.new(-0.3, 0.8, 0.1).Unit
run(1)
local h = 0
for _, p in panels do
	local c = { p.CFrame:GetComponents() }
	for _, v in c do h = (h * 31 + math.floor(v * 1000 + 0.5)) % 2147483647 end
end
print(string.format("%d panels, pose digest %d", #panels, h))
process.exit(0)
