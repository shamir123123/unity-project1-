--!nocheck
-- WindTurbineView: a rotor in view is posed, one behind the camera is not.
-- Usage (from tools/harness): lune run test_windturbines.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
local orig = process.args[1] == "orig"
H.patches["StarterPlayer.StarterPlayerScripts.World.WindTurbineView"] = function(src)
	if orig then
		src = process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.WindTurbineView.luau" }).stdout
	end
	return src
end
H.boot({ server = false })
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local rotors = {}
for i, x in { 600, -600 } do
	local t = I.new("Model"); t.Name = "Turbine" .. i
	local root = I.new("Part"); root.Name = "Root"; root.CFrame = CF.new(x, 0, 0); root.Parent = t
	t.PrimaryPart = root
	local r = I.new("Model"); r.Name = "Rotor"
	local hub = I.new("Part"); hub.Name = "Hub"; hub.CFrame = CF.new(x, 60, 0); hub.Parent = r
	r.PrimaryPart = hub
	r.Parent = t
	t.Parent = ws
	rotors[i] = r
	r:AddTag("WindTurbineRotor")
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.WindTurbineView")
-- camera at origin looking toward +X: rotor 1 in front, rotor 2 behind
ws.CurrentCamera.CFrame = CF.new(0, 50, 0) * CF.Angles(0, -math.pi / 2, 0)
View.Start()
H.task.wait(0.3)
local hb = H.game:GetService("RunService").Heartbeat
local function pos(r) return r:GetPivot() end
local before = { pos(rotors[1]), pos(rotors[2]) }
for _ = 1, 30 do hb:Fire(1 / 60) end
local moved1 = pos(rotors[1]) ~= before[1]
local moved2 = pos(rotors[2]) ~= before[2]
print("in view posed:", moved1, " behind posed:", moved2)
process.exit(0)
