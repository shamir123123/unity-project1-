--!strict
-- WindowLightsView -- cosmetic night lights in building windows.
-- Watches the _City building folders for window parts: "Window" glass panes
-- (offices), "WinPlate" decal windows (houses/shops -- lit = decal hidden, plate
-- goes Neon) and "Storefront" glass. Each window rolls
-- its own schedule once: ~30% never light, the rest switch ON at a random time
-- around dusk (17:30-20:30) and OFF at a random time in the night (21:30-05:30),
-- so blocks light up window by window instead of all at once.
-- Client-only and purely visual: the material/colour swap never replicates.

local Lighting = game:GetService("Lighting")

local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local WindowLightsView = {}

local FOLDERS = { "ZonedBuildings", "Schools", "EmergencyServices", "Transit" }
-- Deliberately dim: Neon bloom scales with colour brightness, and full-bright warm
-- neon reads like a floodlight wall at night.
local LIT_COLOR = Color3.fromRGB(168, 168, 162)
local DARK_SHARE = 0.65 -- share of windows that never light up
local SWEEP_SECONDS = 1 -- cosmetic; 1 Hz is plenty
local FOLDER_WAIT = 30

type Entry = {
	material: Enum.Material,
	color: Color3,
	onHour: number, -- math.huge = stays dark
	offHour: number, -- on a 12..36 wrapped clock (see sweep)
	lit: boolean,
}

local _entries: { [BasePart]: Entry } = {}
-- The same parts as an array, so a sweep can be spread over frames (a big city has tens of
-- thousands of windows; walking them all in one frame every second was a 1 Hz hitch).
local _parts: { BasePart } = {}
local SLICE = 2000

local function track(inst: Instance)
	if not inst:IsA("BasePart") or _entries[inst] then return end
	local n = inst.Name
	if not (n:find("Window") or n == "WinPlate" or n == "Storefront") then return end
	local dark = math.random() < DARK_SHARE
	_entries[inst] = {
		material = inst.Material,
		color = inst.Color,
		onHour = if dark then math.huge else 17.5 + math.random() * 3,
		offHour = 21.5 + math.random() * 8,
		lit = false,
	}
	table.insert(_parts, inst)
end

local function apply(part: BasePart, e: Entry, lit: boolean)
	if e.lit == lit then return end
	e.lit = lit
	if lit then
		part.Material = Enum.Material.Neon
		part.Color = LIT_COLOR
	else
		part.Material = e.material
		part.Color = e.color
	end
	-- Decal windows (WinPlate/Storefront): the painted frame hides the glow, so the
	-- decal steps aside while the window is lit. Authored decals are always opaque.
	for _, d in part:GetChildren() do
		if d:IsA("Decal") then
			d.Transparency = if lit then 1 else 0
		end
	end
end

-- Every window's schedule lies inside [ON_EARLIEST, OFF_LATEST) on the wrapped clock (see
-- track): outside it no window can be lit, so once a pass has put them all out the sweep
-- has nothing to do until evening -- it walked every window in the city each second all day.
local ON_EARLIEST, OFF_LATEST = 17.5, 29.5
local _allDark = false

local function sweep()
	-- Wrap the clock so an evening-to-morning window is one contiguous range:
	-- 17:30 -> 17.5, midnight -> 24, 05:30 -> 29.5.
	local h = Lighting.ClockTime
	if h < 12 then h += 24 end
	local on = Settings.get("windowLights") ~= false
	local dark = not on or h < ON_EARLIEST or h >= OFF_LATEST
	if dark and _allDark then return end
	local i, n = 1, 0
	while i <= #_parts do
		n += 1
		if n % SLICE == 0 then task.wait() end
		local part = _parts[i]
		local e = _entries[part]
		if not e or part.Parent == nil then
			_entries[part] = nil
			_parts[i] = _parts[#_parts]
			_parts[#_parts] = nil
		else
			apply(part, e, on and h >= e.onHour and h < e.offHour)
			i += 1
		end
	end
	-- A window tracked later starts dark (lit = false), so it cannot break this.
	_allDark = dark
end

function WindowLightsView.Start()
	local city = workspace:WaitForChild("_City", FOLDER_WAIT)
	if not city then
		warn("[WindowLightsView] workspace._City never appeared -- windows stay dark")
		return
	end
	for _, name in FOLDERS do
		task.spawn(function()
			local folder = city:WaitForChild(name, FOLDER_WAIT)
			if not folder then return end
			folder.DescendantAdded:Connect(track)
			for _, d in folder:GetDescendants() do
				track(d)
			end
		end)
	end
	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			local ok, err = pcall(sweep)
			if not ok then
				warn("[WindowLightsView] sweep failed: " .. tostring(err))
			end
		end
	end)
end

return WindowLightsView
