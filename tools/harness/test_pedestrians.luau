--!nocheck
-- PedestrianView: walkers follow replicated poses identically with batched moves.
-- Usage (from tools/harness): lune run test_pedestrians.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
if process.args[1] == "orig" then
	H.patches["StarterPlayer.StarterPlayerScripts.World.PedestrianView"] = function()
		return process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.PedestrianView.luau" }).stdout
	end
end
local netStub = { SyncNpcPoses = { OnClientEvent = H.rbx.Signal.new() } }
H.boot({ server = false, overrides = { ["ReplicatedStorage.Networker"] = netStub } })
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local CS = H.game:GetService("CollectionService")
local bulk = 0
ws._props.BulkMoveTo = function(_, parts, cfs)
	bulk += 1
	for i, p in parts do p.CFrame = cfs[i] end
end
-- Facing +Z (LookVector of CFrame.Angles(0, pi, 0)); the walkers stand in front.
ws.CurrentCamera.CFrame = CF.new(0, 50, -100) * CF.Angles(0, math.pi, 0)
local walkers = {}
for i = 1, 30 do
	local m = I.new("Model"); m.Name = "W" .. i; m.Parent = ws
	local root = I.new("Part"); root.Name = "HumanoidRootPart"; root.CFrame = CF.new(i * 4 - 60, 3, 50 + i * 20); root.Parent = m
	local body = I.new("Part"); body.Name = "Torso"; body.Parent = m
	m.PrimaryPart = root
	m:SetAttribute("NpcId", i)
	m:AddTag("NPCWalker")
	walkers[i] = m
end
H.patches["StarterPlayer.StarterPlayerScripts.World.PedestrianView"] = (function(prev)
	return function(src)
		if prev then src = prev(src) end
		return (string.gsub(src, "local function step%(dt: number%)\n", "local function step(dt: number)\n\tshared.steps = (shared.steps or 0) + 1\n\tlocal __n = 0 for _ in _tracked do __n += 1 end shared.tracked = __n\n", 1))
	end
end)(H.patches["StarterPlayer.StarterPlayerScripts.World.PedestrianView"])
local View = H.require("StarterPlayer.StarterPlayerScripts.World.PedestrianView")
View.Start()
local rs = H.game:GetService("RunService").RenderStepped
local function frames(n) for _ = 1, n do rs:Fire(1 / 60); H.task.wait() end end
frames(5)
-- The server moves every walker 3 studs forward each 0.5 s (far keepalive path).
local digest = {}
for k = 1, 6 do
	for _, m in walkers do
		local r = m.PrimaryPart
		r.CFrame = r.CFrame + V3.new(0, 0, 3)
	end
	frames(6)
	local mid = 0
	for _, m in walkers do mid += m.PrimaryPart.CFrame.Position.Z end
	table.insert(digest, string.format("%.3f", mid))
	frames(24)
	local s = 0
	for _, m in walkers do s += m.PrimaryPart.CFrame.Position.Z end
	table.insert(digest, string.format("%.3f", s))
end
print("z-sum (mid, end) per step:", table.concat(digest, " "))
print("batched moves:", bulk, "steps", H.envShared().steps, "tracked", H.envShared().tracked)
process.exit(0)
