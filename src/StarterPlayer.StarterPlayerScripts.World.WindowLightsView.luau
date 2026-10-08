--!strict
-- WindowLightsView -- cosmetic night lights in building windows.
-- Watches the _City building folders for window parts: "Window" glass panes
-- (offices), "WinPlate" decal windows (houses/shops -- lit = decal hidden, plate
-- goes Neon), "Storefront" glass, and the GLAZING of the mesh-kit buildings (below).
-- Each window rolls its own schedule once: some never light, the rest switch ON at a
-- random time around dusk (17:30-20:30) and OFF at a random time in the night
-- (21:30-05:30), so blocks light up window by window instead of all at once.
-- A light needs someone there and power reaching the building: an empty, abandoned or
-- unpowered building stays dark (Occupants / Abandoned / NoPower, stamped by the sim).
-- Client-only and purely visual: the material/colour swap never replicates.

local Lighting = game:GetService("Lighting")

local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local WindowLightsView = {}

local FOLDERS = { "ZonedBuildings", "Schools", "EmergencyServices", "Transit" }
-- Deliberately dim: Neon bloom scales with colour brightness, and full-bright warm
-- neon reads like a floodlight wall at night.
local LIT_COLOR = Color3.fromRGB(168, 168, 162)
local DARK_SHARE = 0.65 -- share of windows that never light up
-- GLAZING: the house (RH_), mid-rise (RM_) and shop (C2_) kits keep every window's glass and
-- frames in one untinted "Fixed" MeshPart, recessed behind the wall face (shops: the storefront).
-- It has no per-window parts and no emissive mask, so the building lights all its windows at
-- once: the texture steps aside and the glazing goes Neon, in one of a few lamp tones.
-- Factories (IN_) stay dark: their Fixed reaches the ground and takes in the roller doors.
local GLAZING_PART = "Fixed"
local GLAZING_KITS: { [string]: boolean } = table.freeze({ RH_ = true, RM_ = true, C2_ = true })
local GLAZING_DARK_SHARE = 0.25 -- buildings that stay dark all evening
local GLAZING_COLORS: { Color3 } = table.freeze({
	Color3.fromRGB(176, 156, 120), -- warm bulb
	Color3.fromRGB(170, 160, 136),
	Color3.fromRGB(164, 166, 160), -- daylight LED
})
local SWEEP_SECONDS = 1 -- cosmetic; 1 Hz is plenty
local FOLDER_WAIT = 30

type Entry = {
	material: Enum.Material,
	color: Color3,
	glow: Color3,
	texture: string?, -- glazing: the TextureID that steps aside while lit
	building: Instance, -- whose Occupants / Abandoned / NoPower gate the light
	onHour: number, -- math.huge = stays dark
	offHour: number, -- on a 12..36 wrapped clock (see sweep)
	lit: boolean,
}

local _entries: { [BasePart]: Entry } = {}
-- The same parts as an array, so a sweep can be spread over frames (a big city has tens of
-- thousands of windows; walking them all in one frame every second was a 1 Hz hitch).
local _parts: { BasePart } = {}
local SLICE = 2000

-- The model directly under the watched folder: the building the part belongs to.
local function buildingOf(inst: Instance, folder: Instance): Instance
	local b = inst
	while b.Parent and b.Parent ~= folder do
		b = b.Parent
	end
	return b
end

local function isGlazing(inst: BasePart): boolean
	if inst.Name ~= GLAZING_PART or not inst:IsA("MeshPart") then return false end
	local model = inst.Parent
	local template = model and model:GetAttribute("TemplateName")
	return typeof(template) == "string" and GLAZING_KITS[template:sub(1, 3)] == true
end

local function track(inst: Instance, folder: Instance)
	if not inst:IsA("BasePart") or _entries[inst] then return end
	local n = inst.Name
	local glazing = isGlazing(inst)
	-- LOD_Windows is the mid-rise's far-away window sheet, drawn by AssetLODView.
	if not glazing and (n:sub(1, 4) == "LOD_"
		or not (n:find("Window") or n == "WinPlate" or n == "Storefront")) then return end
	local dark = math.random() < (if glazing then GLAZING_DARK_SHARE else DARK_SHARE)
	_entries[inst] = {
		material = inst.Material,
		color = inst.Color,
		glow = if glazing then GLAZING_COLORS[math.random(#GLAZING_COLORS)] else LIT_COLOR,
		texture = if glazing then (inst :: MeshPart).TextureID else nil,
		building = buildingOf(inst, folder),
		onHour = if dark then math.huge else 17.5 + math.random() * 3,
		offHour = 21.5 + math.random() * 8,
		lit = false,
	}
	table.insert(_parts, inst)
end

local function served(building: Instance): boolean
	if building:GetAttribute("NoPower") == true or building:GetAttribute("Abandoned") == true then
		return false
	end
	local occupants = building:GetAttribute("Occupants")
	return typeof(occupants) ~= "number" or occupants > 0
end

local function apply(part: BasePart, e: Entry, lit: boolean)
	if e.lit == lit then return end
	e.lit = lit
	if e.texture then
		(part :: MeshPart).TextureID = if lit then "" else e.texture
	end
	if lit then
		part.Material = Enum.Material.Neon
		part.Color = e.glow
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
-- ...except to drop windows whose buildings are gone (the walk below is also what lets go of
-- them): once a minute by day, so a demolished street is not held until evening.
local COMPACT_SECONDS = 60
local _compactedAt = 0

local function sweep()
	-- Wrap the clock so an evening-to-morning window is one contiguous range:
	-- 17:30 -> 17.5, midnight -> 24, 05:30 -> 29.5.
	local h = Lighting.ClockTime
	if h < 12 then h += 24 end
	local on = Settings.get("windowLights") ~= false
	local dark = not on or h < ON_EARLIEST or h >= OFF_LATEST
	if dark and _allDark and os.clock() - _compactedAt < COMPACT_SECONDS then return end
	_compactedAt = os.clock()
	-- One read of a building's state per pass, however many windows it has.
	local isServed: { [Instance]: boolean } = {}
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
			local want = on and h >= e.onHour and h < e.offHour
			if want then
				local ok = isServed[e.building]
				if ok == nil then
					ok = served(e.building)
					isServed[e.building] = ok
				end
				want = ok
			end
			apply(part, e, want)
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
			folder.DescendantAdded:Connect(function(d)
				track(d, folder)
			end)
			for _, d in folder:GetDescendants() do
				track(d, folder)
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
