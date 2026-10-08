--!nocheck
-- WindowLightsView: lit counts through a day, and the cost of a daytime sweep.
-- Usage (from tools/harness): lune run test_windowlights.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local function log(...) stdio.ewrite(table.concat({...}, " ") .. "\n") end
-- Count windows each sweep visits (patched into the module's loop).
local function counted(src)
	return (string.gsub(src, "local part = _parts%[i%]", "local part = _parts[i]; shared.visits = (shared.visits or 0) + 1"))
end
H.patches["StarterPlayer.StarterPlayerScripts.World.WindowLightsView"] = function(src)
	if process.args[1] == "orig" then
		src = process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.WindowLightsView.luau" }).stdout
	end
	return counted(src)
end
local settingsStub = { get = function() return nil end, onChanged = function() end }
H.boot({ server = false, overrides = { ["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub } })
local I = H.rbx.Instance
local ws = H.game:GetService("Workspace")
local Lighting = H.game:GetService("Lighting")
Lighting.ClockTime = 12
local city = I.new("Folder"); city.Name = "_City"; city.Parent = ws
local zb = I.new("Folder"); zb.Name = "ZonedBuildings"; zb.Parent = city
local N = tonumber(process.env.N) or 2000
local wins = {}
for b = 1, N / 20 do
	local m = I.new("Model"); m.Name = "B" .. b; m.Parent = zb
	for w = 1, 20 do
		local p = I.new("Part"); p.Name = "Window"; p.Parent = m
		table.insert(wins, p)
	end
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.WindowLightsView")
log("start"); View.Start(); log("started")
local function lit() local n = 0 for _, p in wins do if p.Material == H.roblox.Enum.Material.Neon then n += 1 end end return n end
local function settle(sec) H.task.wait(sec) end
settle(1.5)
local function timeSweeps(label)
	settle(3.2)
	log(string.format("%-28s lit %5d", label, lit()))
end
timeSweeps("noon")
Lighting.ClockTime = 22
timeSweeps("22:00")
Lighting.ClockTime = 7
timeSweeps("07:00")
-- Work done by daytime sweeps: windows visited over 5 s of idle.
Lighting.ClockTime = 13
settle(1.2)
local v0 = H.sharedVisits()
settle(5)
log(string.format("daytime, 5 s idle: %d window visits (%d windows)", H.sharedVisits() - v0, N))
process.exit(0)
