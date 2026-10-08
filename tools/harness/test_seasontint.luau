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
	p:AddTag("TreeLeaves")
end
local passes = 0
local getTagged = CS._props.GetTagged
CS._props.GetTagged = function(self, tag)
	if tag == "TreeLeaves" then passes += 1 end
	return getTagged(self, tag)
end
-- Tints: patched counter at the top of tint() (shared.tints).
H.patches["StarterPlayer.StarterPlayerScripts.SeasonTintClient"] = (function(prev)
	return function(src)
		if prev then src = prev(src) end
		return (string.gsub(src, "local function tint%(p: Instance%)\n", "local function tint(p: Instance)\n\tshared.tints = (shared.tints or 0) + 1\n", 1))
	end
end)(H.patches["StarterPlayer.StarterPlayerScripts.SeasonTintClient"])
local function tints() return H.envShared().tints or 0 end
H.run("StarterPlayer.StarterPlayerScripts.SeasonTintClient")
local hb = H.game:GetService("RunService").Heartbeat
local function frames(n) for _ = 1, n do hb:Fire(1 / 60); H.task.wait() end end
frames(120)
local function phase(label, weather, secs)
	local p0, t0 = passes, tints()
	ws:SetAttribute("Weather", weather)
	frames(60 * secs)
	print(string.format("%-34s %5d passes, %8d tree tints (%d frames, %d trees)", label, passes - p0, tints() - t0, 60 * secs, N))
end
phase("rain fade-in (42 s)", "Rain", 42)
phase("snow (frost 0 -> 1, 12 s)", "Snow", 12)
phase("clear again (melt + dry, 45 s)", "Clear", 45)
process.exit(0)
