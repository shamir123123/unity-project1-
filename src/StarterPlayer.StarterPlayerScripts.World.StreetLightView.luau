--!strict
-- StreetLightView -- the light that lamps cast, on this client.
--
-- Every street lamp (RoadSceneRenderer, one SpotLight per head -- two on a twin mast), car park
-- lamp (the ParkingLot* lot kits) and bridge lamp (BridgeBuilder) carries a SpotLight, and they
-- all shipped Enabled: at noon as much as at midnight, a kilometre away as much as underfoot,
-- however many the city had. Every one of them is a light the renderer has to account for.
--
-- Here a lamp casts light only at NIGHT, and only the nearest MAX_LIT of them (by graphics
-- preset) around the point the camera is looking at. The lamp heads glow (Neon) at night, so a
-- far lamp still shines -- what goes is the pool of light it throws onto the pavement, which
-- past a few hundred studs is a handful of pixels. By day the heads are plain unlit glass
-- (user, 2026-10-08: lamps "only put light when it's night"). Client-only: nothing written here
-- replicates, and the server never writes these lights or lenses after building them.
--
-- Signal heads are NOT lamps: TrafficLightPlacer switches their lights by phase on the server,
-- so nothing under _City.TrafficLights is ever touched, and only lights hung on a lamp head
-- (LAMP_PARTS) are taken at all.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local StreetLightView = {}

-- The parts a lamp light hangs on, across the three lamp kits.
local LAMP_PARTS: { [string]: boolean } = table.freeze({
	Lens = true, LensLong = true, LensShort = true, -- StreetLamp / StreetLampTwin
	Bulb = true, -- car park lamps
	Lamp = true, -- bridge deck lamps
})
-- Lamps burn from dusk to dawn (Lighting.ClockTime, hours). Window lights start a little
-- earlier (WindowLightsView); street lights come on as the sky goes.
local ON_HOUR = 17.75
local OFF_HOUR = 6.5
local MAX_LIT_BY_PRESET: { [string]: number } = { Lowest = 0, Low = 0, Medium = 32, High = 96, Ultra = 192 }
local MAX_LIT_DEFAULT = 96
local SWEEP_SECONDS = 0.5
-- Past this from the focus a lamp's pool is a few pixels: not lit whatever the budget.
local MAX_RANGE = 900

-- By day a lens is this instead of Neon: its own colour, not lit.
local DAY_LENS = Enum.Material.SmoothPlastic
local LENS_BATCH = 1500 -- lenses switched per frame at dusk and dawn

-- glow: the Neon part that shines -- the light's own part (Lens, Bulb), or the bridge lamp's
-- LampLens beside it.
type Lamp = { light: Light, part: BasePart, glow: BasePart? }

local _lamps: { [Light]: Lamp } = {}
local _lit: { [Light]: boolean? } = {}
local _litCount = 0
local _lensNight: boolean? = nil -- what the lenses show; nil until the first switch
local _started = false
local _city: Instance? = nil

local function isNight(): boolean
	local h = Lighting.ClockTime
	return h >= ON_HOUR or h < OFF_HOUR
end

local function maxLit(): number
	return MAX_LIT_BY_PRESET[tostring(Settings.get("graphicsPreset"))] or MAX_LIT_DEFAULT
end

local function setLit(lamp: Lamp, on: boolean)
	if (_lit[lamp.light] == true) == on then return end
	_lit[lamp.light] = if on then true else nil
	_litCount += if on then 1 else -1
	lamp.light.Enabled = on
end

local function glowPartOf(part: BasePart): BasePart?
	if part.Material == Enum.Material.Neon then return part end
	-- A bridge pole can carry two Lamp / LampLens pairs: the lens is the one under its lamp.
	local holder = part.Parent
	if not holder then return nil end
	local best: BasePart?, bestD = nil, math.huge
	for _, c in holder:GetChildren() do
		if c.Name == part.Name .. "Lens" and c:IsA("BasePart") and c.Material == Enum.Material.Neon then
			local d = (c.Position - part.Position).Magnitude
			if d < bestD then best, bestD = c, d end
		end
	end
	return best
end

local function setLens(glow: BasePart, night: boolean)
	glow.Material = if night then Enum.Material.Neon else DAY_LENS
end

local function track(d: Instance)
	if not d:IsA("Light") or _lamps[d] then return end
	local part = d.Parent
	if not part or not part:IsA("BasePart") or not LAMP_PARTS[part.Name] then return end
	local city = _city
	local signals = city and city:FindFirstChild("TrafficLights")
	if signals and d:IsDescendantOf(signals) then return end
	local lamp: Lamp = { light = d, part = part, glow = glowPartOf(part) }
	_lamps[d] = lamp
	-- Off until a sweep decides otherwise: a lamp that arrives in daylight never switches on.
	d.Enabled = false
	local glow = lamp.glow
	if glow and _lensNight ~= nil then setLens(glow, _lensNight) end
end

local function untrack(d: Instance)
	if not d:IsA("Light") then return end
	if _lit[d] then _litCount -= 1 end
	_lamps[d] = nil
	_lit[d] = nil
end

-- Where the camera is looking on the ground: lamps light what the player is looking at.
local function focus(): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local cf = cam.CFrame
	local look = cf.LookVector
	if look.Y < -0.05 then
		local t = math.min(-cf.Position.Y / look.Y, 4000)
		return cf.Position + look * t
	end
	return cf.Position
end

-- At dusk and dawn every lens in the city switches, a batch a frame. Lamps tracked meanwhile
-- take the new state as they arrive (track reads _lensNight, set before the walk).
local function switchLenses(night: boolean)
	_lensNight = night
	local glows: { BasePart } = {}
	for _, lamp in _lamps do
		if lamp.glow then table.insert(glows, lamp.glow) end
	end
	for i, glow in glows do
		if glow.Parent then setLens(glow, night) end
		if i % LENS_BATCH == 0 then
			task.wait()
			if _lensNight ~= night then return end
		end
	end
end

local function sweep(): ()
	local budget = if isNight() then maxLit() else 0
	local at = focus()
	if budget <= 0 or not at then
		-- By day every lamp is already out (they arrive dark): nothing to walk.
		if _litCount > 0 then
			for _, lamp in _lamps do setLit(lamp, false) end
		end
		return
	end
	-- Nearest `budget` lamps within MAX_RANGE of the focus, flat distance.
	local near: { { lamp: Lamp, d: number } } = {}
	local r2 = MAX_RANGE * MAX_RANGE
	for light, lamp in _lamps do
		if not light.Parent then
			if _lit[light] then _litCount -= 1 end
			_lamps[light] = nil
			_lit[light] = nil
			continue
		end
		local p = lamp.part.Position
		local dx, dz = p.X - at.X, p.Z - at.Z
		local d2 = dx * dx + dz * dz
		if d2 <= r2 then
			table.insert(near, { lamp = lamp, d = d2 })
		else
			setLit(lamp, false)
		end
	end
	if #near > budget then
		table.sort(near, function(a, b) return a.d < b.d end)
	end
	for i, entry in near do
		setLit(entry.lamp, i <= budget)
	end
end

local function bindCity(city: Instance)
	if _city == city then return end
	_city = city
	city.DescendantAdded:Connect(track)
	city.DescendantRemoving:Connect(untrack)
	for _, d in city:GetDescendants() do track(d) end
end

function StreetLightView.Start()
	if _started then return end
	_started = true
	task.spawn(function()
		while true do
			-- Polled like AssetLODView: the city folder can be renamed into place, which fires
			-- no ChildAdded.
			local city = Workspace:FindFirstChild("_City")
			if city and city ~= _city then bindCity(city) end
			local night = isNight()
			if night ~= _lensNight then
				local ok, err = pcall(switchLenses :: any, night)
				if not ok then warn("[StreetLightView] lens switch failed: " .. tostring(err)) end
			end
			debug.profilebegin("StreetLightView.sweep")
			local ok, err = pcall(sweep :: any)
			debug.profileend()
			if not ok then warn("[StreetLightView] sweep failed: " .. tostring(err)) end
			task.wait(SWEEP_SECONDS)
		end
	end)
end

return StreetLightView
