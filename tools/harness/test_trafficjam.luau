--!nocheck
-- TrafficJamView: same badges as before, and the most cars read in any one frame.
-- Usage (from tools/harness): lune run test_trafficjam.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
local orig = process.args[1] == "orig"
H.patches["StarterPlayer.StarterPlayerScripts.World.TrafficJamView"] = function(src)
	if orig then
		src = process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.TrafficJamView.luau" }).stdout
	end
	-- count car reads per frame
	return (string.gsub(src, "local function rootOf%(car: Instance%): BasePart%?\n", "local function rootOf(car: Instance): BasePart?\n\tshared.reads = (shared.reads or 0) + 1\n", 1))
end
H.boot({ server = false })
H.quietWarn = true
H.game:GetService("TweenService")._props.Create = function() return { Play = function() end, Cancel = function() end } end
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
local N = 3000
local movers = {}
for i = 1, N do
	local m = I.new("Model"); m.Name = "Car" .. i
	local p = I.new("Part"); p.Name = "Body"; p.Parent = m
	m.PrimaryPart = p
	if i <= 40 then
		-- a queue: 40 cars stopped along X, 8 studs apart
		p.CFrame = CF.new(1000 + i * 8, 2, 500)
	else
		p.CFrame = CF.new((i * 37) % 4000 - 2000, 2, (i * 91) % 4000 - 2000)
		table.insert(movers, p)
	end
	m.Parent = ws
	m:AddTag("NPCDriver")
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.TrafficJamView")
View.Start()
local hb = H.game:GetService("RunService").Heartbeat
local S = H.envShared()
local worst = 0
for f = 1, 60 * 40 do
	if f % 6 == 0 then
		for _, p in movers do p.CFrame = p.CFrame + V3.new(1.5, 0, 0) end -- 15 studs/s
	end
	S.reads = 0
	hb:Fire(1 / 60)
	H.task.wait()
	worst = math.max(worst, S.reads)
end
local badges = {}
for _, d in ws:GetChildren() do
	if d.Name == "TrafficJamAnchor" then table.insert(badges, string.format("(%.0f,%.0f,%.0f)", d.Position.X, d.Position.Y, d.Position.Z)) end
end
table.sort(badges)
print(string.format("%d cars: most read in one frame %d; badges after 40 s: %s", N, worst, table.concat(badges, " ")))
process.exit(0)
