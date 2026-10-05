--!strict
-- LocalScript -> StarterPlayerScripts
-- Foliage colour + seasonal weather skinning.
--  * Season ("Season"): tints "TreeLeaves". Spring/Summer green, Autumn/Fall warm MIX per tree,
--    Winter = dormant brown (deciduous) / green (evergreen) -- winter itself does NOT whiten
--    foliage; only snowfall does.
--    A new season turns the trees ONE BY ONE, in random order, over SEASON_TURN_SECONDS.
--  * Ground snow ("Weather"=="Snow" only -- winter itself is bare, not white): eases in -> terrain whitens, rock
--    snow-shells fade in, building roof-tops whiten. Melts back when neither holds.
--  * Snowfall frost ("Weather"=="Snow" only): leaves frost toward white (evergreens included).
--  * Rain ("Weather"=="Rain"): ground darkens + a colour-grade makes the scene read wet.
--  * Flowers ("SeasonFlower" parts): only shown in Spring/Summer.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local CS = CollectionService

local SEASON_COLORS = { Spring = Color3.fromRGB(132, 200, 96), Summer = Color3.fromRGB(72, 140, 56) }
local WINTER_DORMANT = Color3.fromRGB(128, 104, 66)
local AUTUMN_SEASONS = { Autumn = true, Fall = true }
local AUTUMN_PALETTE = {
	Color3.fromRGB(216, 116, 34), Color3.fromRGB(226, 190, 60), Color3.fromRGB(204, 150, 40),
	Color3.fromRGB(182, 90, 44), Color3.fromRGB(198, 168, 66), Color3.fromRGB(232, 158, 48),
}
local FLOWER_SEASONS = { Spring = true, Summer = true }
local FROST = Color3.fromRGB(244, 247, 252)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local LEAF_FROST = 0.6
local SNOW_GROUND = Color3.fromRGB(240, 244, 250)
local GROUND_FROST = 0.9
local WET_DARK = 0.42
local SHELL_MAX = 0.9
local ROOF_SNOW = 0.85
local ROOF_BAND = 0.34        -- top fraction of a building counted as "roof"
local ACCUM, MELT = 1 / 8, 1 / 5
-- 40 s, the same as SkyLightingView's weather blend, so the wet grade and the rain light
-- arrive (and clear) together instead of the grade snapping in ahead of the sky.
local WET_IN, WET_OUT = 1 / 40, 1 / 40
local BATCH_SIZE = 400
local TERRAIN_MATS = {
	Enum.Material.Grass, Enum.Material.LeafyGrass, Enum.Material.Ground,
	Enum.Material.Rock, Enum.Material.Mud, Enum.Material.Sand,
}
local CITY_FOLDERS = { "ZonedBuildings", "EmergencyServices", "Schools", "Transit" }

type Species = { shade: number, evergreen: boolean? }
local SPECIES: { [string]: Species } = {
	SpruceTree = { shade = 0.58, evergreen = true }, PineTree = { shade = 0.7, evergreen = true },
	RoyalPalm = { shade = 0.72, evergreen = true }, CoconutPalm = { shade = 0.85, evergreen = true },
	SylvesterPalm = { shade = 0.65, evergreen = true }, FloridaPalm = { shade = 0.8, evergreen = true },
	PalmMedium = { shade = 0.78, evergreen = true }, PalmYoung = { shade = 0.9, evergreen = true },
	OakTree = { shade = 0.95 }, ChestnutTree = { shade = 0.82 }, BroadleafTree = { shade = 0.88 },
	BirchTree = { shade = 1.12 }, PoplarTree = { shade = 1.05 }, ElderTree = { shade = 1.0 },
	BushRound = { shade = 0.92 }, BushLow = { shade = 1.0 }, BushTall = { shade = 1.05 },
	BushWild = { shade = 0.95 }, FlowerBush = { shade = 0.95 }, FlowerBushPink = { shade = 0.95 },
	FlowerBushYellow = { shade = 1.0 }, BerryBush = { shade = 0.9 }, HedgeSphere = { shade = 0.85 },
	HedgeBox = { shade = 0.8 }, HedgeCone = { shade = 0.75 },
}
local DEFAULT: Species = { shade = 1.0 }

local groundSnow, leafFrost, wetLevel = 0, 0, 0

local function shaded(c: Color3, m: number): Color3
	return Color3.new(math.clamp(c.R * m, 0, 1), math.clamp(c.G * m, 0, 1), math.clamp(c.B * m, 0, 1))
end
-- Stable per-tree colour variation so a stand of one species isn't a flat wall of green.
local function varyColor(part: BasePart, base: Color3): Color3
	local p: Instance = part:FindFirstAncestorOfClass("Model") or part
	local hv = p:GetAttribute("HueVar") :: number?
	if hv == nil then
		hv = (math.random() - 0.5) * 0.07
		p:SetAttribute("HueVar", hv)
		p:SetAttribute("SatVar", (math.random() - 0.5) * 0.32)
		p:SetAttribute("ValVar", (math.random() - 0.5) * 0.34)
	end
	local h, s, v = base:ToHSV()
	h = (h + (hv :: number)) % 1
	s = math.clamp(s + (p:GetAttribute("SatVar") :: number), 0, 1)
	v = math.clamp(v + (p:GetAttribute("ValVar") :: number), 0.08, 1)
	return Color3.fromHSV(h, s, v)
end
local function baseColor(part: BasePart, info: Species): Color3
	local p: Instance = part:FindFirstAncestorOfClass("Model") or part
	local season = workspace:GetAttribute("Season")
	if info.evergreen then return SEASON_COLORS.Summer end
	if season == "Winter" then return WINTER_DORMANT end
	if AUTUMN_SEASONS[season] then
		local idx = p:GetAttribute("AutumnHue") :: number?
		if not idx or idx < 1 or idx > #AUTUMN_PALETTE then idx = math.random(1, #AUTUMN_PALETTE) p:SetAttribute("AutumnHue", idx) end
		return AUTUMN_PALETTE[idx :: number]
	end
	return SEASON_COLORS[season] or SEASON_COLORS.Summer
end
local function tint(p: Instance)
	if not p:IsA("BasePart") then return end
	local sa = p:FindFirstChildOfClass("SurfaceAppearance")
	if not sa then return end
	local info = SPECIES[p:GetAttribute("Species")] or DEFAULT
	local col = shaded(varyColor(p, baseColor(p, info)), info.shade):Lerp(FROST, leafFrost * LEAF_FROST)
	sa.Color = col
	-- The far picture cards (LOD 2) aren't tagged TreeLeaves: give them the same colour.
	if p:GetAttribute("LOD") == 0 and p.Parent then
		for _, c in p.Parent:GetChildren() do
			if c:IsA("BasePart") and c:GetAttribute("LOD") == 2 then
				local csa = c:FindFirstChildOfClass("SurfaceAppearance")
				if csa then csa.Color = col end
			end
		end
	end
end
local retinting, retintPending = false, false
local function retintAll()
	if retinting then retintPending = true return end
	retinting = true
	task.spawn(function()
		repeat
			retintPending = false
			for i, p in CS:GetTagged("TreeLeaves") do
				tint(p)
				if i % BATCH_SIZE == 0 then task.wait() end
			end
		until not retintPending
		retinting = false
	end)
end

-- A new season turns the trees one at a time, in random order, so a street changes colour
-- tree by tree instead of all in one frame. A later turn cancels an unfinished one.
local SEASON_TURN_SECONDS = 45
local turnToken = 0
local function turnSeason()
	turnToken += 1
	local token = turnToken
	local trees: { [Instance]: { BasePart } } = {}
	local order: { Instance } = {}
	for i, p in CS:GetTagged("TreeLeaves") do
		if i % 2000 == 0 then
			task.wait() -- grouping a big forest in one frame was the season-change hitch
			if token ~= turnToken then return end
		end
		if p:IsA("BasePart") then
			local tree = p:FindFirstAncestorOfClass("Model") or p
			if not trees[tree] then
				trees[tree] = {}
				table.insert(order, tree)
			end
			table.insert(trees[tree], p)
		end
	end
	local rng = Random.new()
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	local perTick = math.max(1, math.ceil(#order / (SEASON_TURN_SECONDS * 10)))
	task.spawn(function()
		for i, tree in order do
			if token ~= turnToken then return end
			for _, p in trees[tree] do
				if p.Parent then tint(p) end
			end
			if i % perTick == 0 then task.wait(0.1) end
		end
	end)
end

-- ponytail: O(n) recolour/fade per weather step; fine for a city. A 10k+ world could switch
-- to MaterialVariants or a camera-radius working set if it ever bites.
local terrainBase: { [Enum.Material]: Color3 } = {}
local function applyGround(snow: number, wet: number)
	local terrain = Workspace.Terrain
	for _, m in TERRAIN_MATS do
		if not terrainBase[m] then
			local ok, c = pcall(function() return terrain:GetMaterialColor(m) end)
			terrainBase[m] = (ok and c) or Color3.fromRGB(128, 128, 128)
		end
		local col = terrainBase[m]:Lerp(SNOW_GROUND, snow * GROUND_FROST)
		col = col:Lerp(terrainBase[m]:Lerp(BLACK, WET_DARK), wet)
		pcall(function() terrain:SetMaterialColor(m, col) end)
	end
end
local function applyShells(snow: number)
	local t = 1 - snow * SHELL_MAX
	for _, s in CS:GetTagged("SnowShell") do
		if s:IsA("BasePart") then s.Transparency = t end
	end
end

local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "_WeatherGrade"
cc.Enabled = false
cc.Parent = Lighting
local function applyGrade(wet: number)
	-- No brightness cut: SkyLightingView already dims the light under rain, and a flat
	-- subtraction here crushed a rainy NIGHT to black.
	cc.Enabled = wet > 0.01
	cc.Brightness = 0
	cc.Contrast = 0.05 * wet
	cc.Saturation = -0.15 * wet
	cc.TintColor = WHITE:Lerp(Color3.fromRGB(150, 175, 205), wet * 0.35)
end

local function applyFlowers()
	local season = workspace:GetAttribute("Season")
	local show = season == nil or FLOWER_SEASONS[season] == true
	for _, f in CS:GetTagged("SeasonFlower") do
		if f:IsA("BasePart") then f.Transparency = if show then 0 else 1 end
	end
end

-- Building roofs: tag the top band of each building, remember its colour, whiten with snow.
local function processBuilding(model: Instance)
	if not model:IsA("Model") or model:GetAttribute("_snowRoofed") then return end
	local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
	if not ok or not cf then return end
	model:SetAttribute("_snowRoofed", true)
	local thresh = cf.Position.Y + size.Y / 2 - size.Y * ROOF_BAND
	for _, p in model:GetDescendants() do
		-- No shell on LOD2 / tree LOD1-2 parts: the clone would inherit the attribute, and
		-- AssetLODView forces those parts opaque when zoomed out -- a solid white slab.
		local lod = p:GetAttribute("LOD")
		if p:IsA("BasePart") and p.Name ~= "SnowLayer" and not p:GetAttribute("LOD2")
			and not (typeof(lod) == "number" and lod > 0)
			and (p.Position.Y + p.Size.Y / 2) >= thresh then
			local snow = p:Clone()
			for _, ch in snow:GetChildren() do ch:Destroy() end
			snow.Name = "SnowLayer"
			snow.Anchored = true snow.CanCollide = false snow.CanQuery = false snow.CanTouch = false snow.CastShadow = false
			snow.Material = Enum.Material.SmoothPlastic
			snow.Color = SNOW_GROUND
			snow.Transparency = 1
			local thick = math.min(p.Size.Y, 1.2)
			snow.Size = Vector3.new(p.Size.X + 0.1, thick, p.Size.Z + 0.1)
			snow.CFrame = p.CFrame * CFrame.new(0, p.Size.Y / 2 - thick / 2 + 0.3, 0)
			snow.Parent = p
			CS:AddTag(snow, "SnowShell")
		end
	end
end
-- Roof shells exist ONLY while snow lies (2026-10-01 perf pass). Cloning a third of every
-- building's parts up front, for a weather the city almost never gets, was tens of thousands
-- of extra instances in every city's memory and in every LOD walk. They are built when snow
-- starts and destroyed once it has melted, a batch per frame either way.
local SHELL_BATCH = 3 -- buildings per frame; snow takes 8 s to settle, so a 719-building city lands inside it
local shellsWanted = false
local shellJob = 0
local function cityBuildings(): { Instance }
	local out = {}
	local city = Workspace:FindFirstChild("_City")
	if not city then return out end
	for _, fname in CITY_FOLDERS do
		local f = city:FindFirstChild(fname)
		if f then
			for _, m in f:GetChildren() do table.insert(out, m) end
		end
	end
	return out
end
local function setShells(want: boolean)
	if shellsWanted == want then return end
	shellsWanted = want
	shellJob += 1
	local job = shellJob
	task.spawn(function()
		if want then
			for i, m in cityBuildings() do
				if job ~= shellJob then return end
				processBuilding(m)
				if i % SHELL_BATCH == 0 then task.wait() end
			end
		else
			for i, s in CS:GetTagged("SnowShell") do
				if job ~= shellJob then return end
				local m = s:FindFirstAncestorOfClass("Model")
				if m then m:SetAttribute("_snowRoofed", nil) end
				s:Destroy()
				if i % (SHELL_BATCH * 20) == 0 then task.wait() end
			end
		end
	end)
end
local function watchCity()
	local city = Workspace:FindFirstChild("_City")
	if not city then return end
	for _, fname in CITY_FOLDERS do
		local f = city:FindFirstChild(fname)
		if f and not f:GetAttribute("_snowWatched") then
			f:SetAttribute("_snowWatched", true)
			f.ChildAdded:Connect(function(m)
				if shellsWanted then processBuilding(m) end
			end)
		end
	end
end

local function moveToward(a: number, b: number, s: number): number
	if a < b then return math.min(a + s, b) else return math.max(a - s, b) end
end
local lastLeaf = 0
-- Terrain colours, the grade and every roof shell used to be rewritten EVERY frame for the
-- whole 40 s of a rain blend. A 1/50 step is under what anyone sees; ends always land exactly.
local STEP = 0.02
local shownSnow, shownWet = -1, -1
local function stepped(now: number, shown: number, target: number): boolean
	return math.abs(now - shown) >= STEP or (now == target and shown ~= target)
end
RunService.Heartbeat:Connect(function(dt)
	local w = Workspace:GetAttribute("Weather")
	local snowT = if w == "Snow" then 1 else 0
	local frostT = if w == "Snow" then 1 else 0
	local wetT = if w == "Rain" then 1 else 0
	local changed, snowChanged = false, false
	if groundSnow ~= snowT then groundSnow = moveToward(groundSnow, snowT, dt * (if snowT > groundSnow then ACCUM else MELT)) changed = true snowChanged = true end
	if leafFrost ~= frostT then leafFrost = moveToward(leafFrost, frostT, dt * (if frostT > leafFrost then ACCUM else MELT)) changed = true end
	if wetLevel ~= wetT then wetLevel = moveToward(wetLevel, wetT, dt * (if wetT > wetLevel then WET_IN else WET_OUT)) changed = true end
	if snowT > 0 then setShells(true) elseif groundSnow == 0 then setShells(false) end
	if not changed then return end
	local snowStep = stepped(groundSnow, shownSnow, snowT)
	local wetStep = stepped(wetLevel, shownWet, wetT)
	if snowStep or wetStep then
		applyGround(groundSnow, wetLevel)
	end
	if snowStep then
		shownSnow = groundSnow
		applyShells(groundSnow)
	end
	if wetStep then
		shownWet = wetLevel
		applyGrade(wetLevel)
	end
	if math.abs(leafFrost - lastLeaf) > 0.05 or leafFrost == 0 or leafFrost == 1 then
		lastLeaf = leafFrost
		retintAll()
	end
end)

CS:GetInstanceAddedSignal("TreeLeaves"):Connect(tint)
CS:GetInstanceAddedSignal("SnowShell"):Connect(function(s)
	if s:IsA("BasePart") then s.Transparency = 1 - groundSnow * SHELL_MAX end
end)
CS:GetInstanceAddedSignal("SeasonFlower"):Connect(function() applyFlowers() end)
workspace:GetAttributeChangedSignal("Season"):Connect(function()
	turnSeason()
	applyFlowers()
end)

local city = Workspace:FindFirstChild("_City")
if city then watchCity() end
Workspace.ChildAdded:Connect(function(c) if c.Name == "_City" then task.wait(0.1) watchCity() end end)
task.spawn(function() while true do watchCity() task.wait(3) end end) -- pick up folders created later

retintAll()
applyFlowers()
