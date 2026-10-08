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
	src = counted(src)
	if process.env.COMPACT then
		src = string.gsub(src, "local COMPACT_SECONDS = 60", "local COMPACT_SECONDS = " .. process.env.COMPACT)
		-- record how many windows each pass starts with
		src = string.gsub(src, "\tlocal i, n = 1, 0\n", "\tlocal i, n = 1, 0\n\tshared.sizes = shared.sizes or {}; table.insert(shared.sizes, #_parts)\n", 1)
	end
	return src
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
-- Mesh-kit glazing: houses (lit only when occupied and powered) and factories (never).
local houses, factories = {}, {}
if process.args[1] ~= "orig" then
	for b = 1, 100 do
		local m = I.new("Model"); m.Name = "Residential_" .. b
		m:SetAttribute("TemplateName", "RH_3x2_ColonialHip")
		m:SetAttribute("Occupants", if b <= 20 then 0 else 3)
		m:SetAttribute("NoPower", b > 20 and b <= 40)
		local f = I.new("MeshPart"); f.Name = "Fixed"; f.TextureID = "rbxassetid://7"; f.Parent = m
		m.Parent = zb
		houses[b] = f
	end
	for b = 1, 10 do
		local m = I.new("Model"); m.Name = "Industrial_" .. b
		m:SetAttribute("TemplateName", "IN_2x2_GoldenGrain")
		local f = I.new("MeshPart"); f.Name = "Fixed"; f.TextureID = "rbxassetid://8"; f.Parent = m
		m.Parent = zb
		factories[b] = f
	end
end
local function glazing(label)
	if #houses == 0 then return end
	local neon = H.roblox.Enum.Material.Neon
	local function count(from, to)
		local n, bare = 0, 0
		for i = from, to do
			if houses[i].Material == neon then n += 1 end
			if houses[i].TextureID == "" then bare += 1 end
		end
		return n, bare
	end
	local empty = count(1, 20)
	local dark = count(21, 40)
	local live, bare = count(41, 100)
	local fac = 0
	for _, f in factories do if f.Material == neon or f.TextureID == "" then fac += 1 end end
	log(string.format("%-28s houses lit: empty %d/20, unpowered %d/20, served %d/60 (texture off %d); factories %d/10",
		label, empty, dark, live, bare, fac))
end
local View = H.require("StarterPlayer.StarterPlayerScripts.World.WindowLightsView")
log("start"); View.Start(); log("started")
local function lit() local n = 0 for _, p in wins do if p.Material == H.roblox.Enum.Material.Neon then n += 1 end end return n end
local function settle(sec) H.task.wait(sec) end
settle(1.5)
local function timeSweeps(label)
	settle(3.2)
	log(string.format("%-28s lit %5d", label, lit()))
	glazing(label)
end
timeSweeps("noon")
Lighting.ClockTime = 22
timeSweeps("22:00")
if #houses > 0 then
	for i = 21, 40 do houses[i].Parent:SetAttribute("NoPower", false) end
	timeSweeps("22:00, power restored")
end
Lighting.ClockTime = 7
timeSweeps("07:00")
if #houses > 0 then
	local restored = 0
	for _, f in houses do if f.TextureID == "rbxassetid://7" then restored += 1 end end
	log(string.format("07:00: glazing textures back %d/100", restored))
end
-- Work done by daytime sweeps: windows visited over 5 s of idle.
Lighting.ClockTime = 13
settle(1.2)
local v0 = H.sharedVisits()
settle(5)
log(string.format("daytime, 5 s idle: %d window visits (%d windows)", H.sharedVisits() - v0, N))
if process.env.COMPACT then
	-- half the buildings go by day: a compaction pass must let their windows go
	local kids = zb:GetChildren()
	for i = 1, #kids // 2 do kids[i]:Destroy() end
	local v1 = H.sharedVisits()
	settle(tonumber(process.env.COMPACT) + 0.5)
	local v2 = H.sharedVisits()
	settle(tonumber(process.env.COMPACT) + 0.5)
	local sizes = H.envShared().sizes
	log(string.format("after removing half by day: windows tracked at the last passes: %s", table.concat(sizes, ",", math.max(1, #sizes - 3))))
end
process.exit(0)
