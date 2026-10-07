--!nocheck
-- SeasonTintClient: how many full tree re-tint passes a 40 s rain fade-in costs.
-- Usage (from tools/harness): lune run test_seasontint.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
local useOrig = process.args[1] == "orig"
if useOrig then
	H.patches["StarterPlayer.StarterPlayerScripts.SeasonTintClient"] = function()
		return process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.SeasonTintClient.client.luau" }).stdout
	end
end
H.boot({ server = false })
H.quietWarn = true
local I = H.rbx.Instance
local ws = H.game:GetService("Workspace")
local CS = H.game:GetService("CollectionService")
local Lighting = H.game:GetService("Lighting")
Lighting.ClockTime = 12
ws:SetAttribute("Season", "Summer")
local N = 2000
for i = 1, N do
	local m = I.new("Model"); m.Name = "Tree" .. i; m.Parent = ws
	local p = I.new("Part"); p.Name = "Leaves"; p:SetAttribute("Species", "OakTree"); p:SetAttribute("LOD", 0); p.Parent = m
	I.new("SurfaceAppearance").Parent = p
	CS:AddTag(p, "TreeLeaves")
end
local passes = 0
local getTagged = CS._props.GetTagged
CS._props.GetTagged = function(self, tag)
	if tag == "TreeLeaves" then passes += 1 end
	return getTagged(self, tag)
end
H.run("StarterPlayer.StarterPlayerScripts.SeasonTintClient")
local hb = H.game:GetService("RunService").Heartbeat
local function frames(n) for _ = 1, n do hb:Fire(1 / 60); H.task.wait() end end
frames(120)
local p0 = passes
ws:SetAttribute("Weather", "Rain")
frames(60 * 42)
print(string.format("rain fade-in (42 s, %d trees): %d full re-tint passes = %d tree tints", N, passes - p0, (passes - p0) * N))
p0 = passes
ws:SetAttribute("Weather", "Snow")
frames(60 * 12)
print(string.format("snow (frost 0 -> 1, 12 s): %d passes", passes - p0))
p0 = passes
ws:SetAttribute("Weather", "Clear")
frames(60 * 45)
print(string.format("clear again (melt + dry, 45 s): %d passes", passes - p0))
process.exit(0)
