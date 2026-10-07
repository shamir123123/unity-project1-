--!strict
-- Edit-time authoring tool (NOT runtime). Builds the water utilities' service templates
-- (ReplicatedStorage.City.ServiceTemplates.<Key>, what ServiceBuildingModel clones) from the PlantKit props
-- Authoring.PropKitSetup filed in ServerStorage.Templates.Asset.Props.PlantKit (blender/res_kit.py, 2026-10-06/07):
--   WaterTower <- WaterTower_Small, WaterPumpingStation <- PumpingStation_River, SewageOutlet <- SewageOutlet,
--   SewagePlant <- SewagePlant_Small, LargeSewagePlant <- SewagePlant_Big,
--   and the outfall's pieces SewageOutlet_Pipe / SewageOutlet_End (no ServiceTypes key: Civic.SewageOutfall lays
--   them from the outlet's PipeOut marker out to the water when one is built).
-- Each keeps its paving as DATA for LotDressingService (tag PavedGates: KitPave, GateSpans -- "" for the water
-- buildings, which need no road, user 2026-10-06 -- and LotDepth) and its kit props (lamps, roof plant, skips,
-- the gates) in KitProps. The plants also get:
--   * their water parts (<P>_Water*, flat colour) made Glass under two drifting ripple textures (tag SewageWater);
--   * each clarifier's bridge (<P>_Bridge<i> + its see-through grating _Alpha) as a sub-model pivoted on the
--     tank's axis (marker Spin<i>), tag ClarifierBridge: SewageWorksView turns it while the plant works;
--   * the manifest's effect areas (fx): "boil" = the aeration's bubbling over a lane, "stalls" = the car park's
--     stall lines (the game's own stall texture);
--   * the digesters' Flare marker a flame, the outfall end's Outfall marker the pour and a PlumeArea on the
--     water (SewageOutfall.lay drops it to the waterline).
-- Every effect is a ParticleEmitter tagged SewageFx with its full-load rate in FxRate, authored OFF:
-- SewageWorksView runs it at FxRate x the works' SewageLoad (WaterService) -- no sewage, no pour.
-- A Blender prop faces -Z once imported and a service building's front is +Z, so each turns 180. Only the LOD0
-- main part answers queries. What a template replaces goes to ServerStorage.PropsRetired.ServiceTemplates.
--
--   local get = function(f) return game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/" .. f) end
--   require(game.ServerStorage.Authoring.WaterTemplateSetup).run(get("kits_manifest.json"))

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local WaterTemplateSetup = {}

local TURN = CFrame.Angles(0, math.pi, 0)
local MAP: { [string]: string } = {
	WaterTower = "WaterTower_Small",
	WaterPumpingStation = "PumpingStation_River",
	SewageOutlet = "SewageOutlet",
	SewageOutlet_Pipe = "SewageOutlet_Pipe",
	SewageOutlet_End = "SewageOutlet_End",
	SewagePlant = "SewagePlant_Small",
	LargeSewagePlant = "SewagePlant_Big",
}
-- Water: the tank's own colour (the part, Glass) under two Creator Store ripple layers tinted to it, which
-- SewageWorksView drifts apart (user 2026-10-07: water that moves, in its own colour; terrain water has one
-- colour for the whole map and thin terrain water sinks out at distance, so tanks can't use it).
local RIPPLE = "rbxassetid://18868528435" -- "water" (rippled surface photo)
local SHIMMER = "rbxassetid://117680427244857" -- "Water Texture Colorable" (neutral caustics)
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local FIRE = "rbxasset://textures/particles/fire_main.dds"
local STALL_W = 3.75 -- studs: LotDressingService's stall (7.5 * WS), so the city's cars fit it

local function folderAt(parent: Instance, name: string): Instance
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f :: Instance
end

local function retire(templates: Instance, key: string)
	local old = templates:FindFirstChild(key)
	if not old then return end
	local bin = folderAt(folderAt(ServerStorage, "PropsRetired"), "ServiceTemplates")
	if bin:FindFirstChild(key) then old:Destroy() else old.Parent = bin end
end

local function lookOnly(p: BasePart)
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
end

local function area(m: Model, name: string, size: Vector3, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Transparency = 1
	p.CastShadow = false
	lookOnly(p)
	p.Parent = m
	return p
end

-- An effect, authored off: SewageWorksView sets Rate = FxRate x the works' SewageLoad.
local function emitter(parent: Instance, name: string, fxRate: number): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = name
	pe.Rate = 0
	pe.Enabled = false
	pe.LightInfluence = 1
	pe:SetAttribute("FxRate", fxRate)
	CollectionService:AddTag(pe, "SewageFx")
	pe.Parent = parent
	return pe
end

local function seq(...: number): NumberSequence
	local v, keys = { ... }, {}
	for i = 1, #v, 2 do table.insert(keys, NumberSequenceKeypoint.new(v[i], v[i + 1])) end
	return NumberSequence.new(keys)
end

-- Aeration: pale bubbles boiling up over the diffusers and bursting, over one lane (e = boil, x, y, z, sx, sz).
local function boil(m: Model, e: { any })
	local p = area(m, "Boil", Vector3.new(e[5], 0.2, e[6]), CFrame.new(e[2], e[3] + 0.15, e[4]))
	local pe = emitter(p, "Boil", math.clamp(e[5] * e[6] / 60, 3, 16))
	pe.Texture = SMOKE
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Color = ColorSequence.new(Color3.fromRGB(236, 230, 210))
	pe.Transparency = seq(0, 0.6, 0.4, 0.45, 1, 1)
	pe.Size = seq(0, 0.4, 1, 1.6)
	pe.Lifetime = NumberRange.new(1.2, 2.2)
	pe.Speed = NumberRange.new(0.4, 1.0)
	pe.SpreadAngle = Vector2.new(15, 15)
	pe.Drag = 1
end

-- The car park: a row of stall lines (e = stalls, x, y, z, length, depth, yaw), just over the lot paving.
local function stalls(m: Model, e: { any })
	local p = area(m, "StallLines", Vector3.new(e[5], 0.05, e[6]),
		CFrame.new(e[2], 0.12, e[4]) * CFrame.Angles(0, math.rad(e[7] or 0), 0))
	local tex = Instance.new("Texture")
	tex.Name = "StallStripeTexture"
	tex.Texture = RoadConstants.PARKING_STALL_TEXTURE
	tex.Face = Enum.NormalId.Top
	tex.Color3 = Color3.fromRGB(236, 236, 230)
	tex.StudsPerTileU = STALL_W
	tex.StudsPerTileV = e[6]
	tex.Parent = p
end

-- The digesters' flare burning their gas.
local function flare(att: Attachment)
	local pe = emitter(att, "Flare", 18)
	pe.Texture = FIRE
	pe.EmissionDirection = Enum.NormalId.Front -- the marker looks up
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 196, 92), Color3.fromRGB(255, 120, 40))
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Transparency = seq(0, 0.2, 1, 1)
	pe.Size = seq(0, 1.4, 1, 0.3)
	pe.Lifetime = NumberRange.new(0.5, 0.8)
	pe.Speed = NumberRange.new(4, 6)
	pe.SpreadAngle = Vector2.new(8, 8)
end

-- The outfall: brown sewage gushing out of the open mouth and falling to the water.
local function pour(att: Attachment)
	local pe = emitter(att, "Pour", 24)
	pe.Texture = SMOKE
	pe.EmissionDirection = Enum.NormalId.Front -- out of the mouth
	pe.Color = ColorSequence.new(Color3.fromRGB(112, 88, 56), Color3.fromRGB(150, 124, 86))
	pe.Transparency = seq(0, 0.1, 0.7, 0.35, 1, 1)
	pe.Size = seq(0, 2.2, 1, 3.4)
	pe.Lifetime = NumberRange.new(0.6, 0.9)
	pe.Speed = NumberRange.new(5, 7)
	pe.SpreadAngle = Vector2.new(6, 6)
	pe.Acceleration = Vector3.new(0, -30, 0)
end

-- ...and spreading over the water from where it lands: foamy, then a brown stain that grows and fades.
local function plume(m: Model, att: Attachment)
	local p = area(m, "PlumeArea", Vector3.new(10, 0.2, 10), CFrame.new(att.WorldPosition))
	local pe = emitter(p, "Plume", 3)
	pe.Texture = SMOKE
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Orientation = Enum.ParticleOrientation.VelocityPerpendicular -- lies flat on the water
	pe.Speed = NumberRange.new(0.05)
	pe.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(206, 190, 152)),
		ColorSequenceKeypoint.new(0.3, Color3.fromRGB(118, 94, 60)), ColorSequenceKeypoint.new(1, Color3.fromRGB(104, 84, 56)) })
	pe.Transparency = seq(0, 0.5, 0.3, 0.45, 1, 1)
	pe.Size = seq(0, 3, 1, 16)
	pe.Lifetime = NumberRange.new(8, 12)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-6, 6)
end

local function waterSkin(p: BasePart)
	p.Material = Enum.Material.Glass
	p.Reflectance = 0.15
	p.CastShadow = false
	local aerated = p.Name:find("_WaterAer", 1, true) ~= nil -- the boiling lanes churn faster
	for i, layer in { { RIPPLE, 0.35, 14 }, { SHIMMER, 0.7, 9 } } do
		local t = Instance.new("Texture")
		t.Name = "Ripple" .. i
		t.Texture = layer[1]
		t.Face = Enum.NormalId.Top
		t.Color3 = p.Color:Lerp(Color3.new(1, 1, 1), 0.3)
		t.Transparency = layer[2]
		t.StudsPerTileU, t.StudsPerTileV = layer[3], layer[3]
		t:SetAttribute("Drift", (if aerated then 1.2 else 0.35) * (if i == 1 then 1 else -0.7))
		CollectionService:AddTag(t, "SewageWater")
		t.Parent = p
	end
end

local function kitProp(props: Instance, name: string): Model?
	for _, k in props:GetChildren() do
		local p = k:FindFirstChild(name)
		if p and p:IsA("Model") then return p end
	end
	return nil
end

-- The manifest's kit props (lamps, roof plant, gates, skips) set in, as PowerTemplateSetup does.
local function dress(m: Model, props: Instance, entry: any): number
	if not entry.kitProps then return 0 end
	local folder = Instance.new("Folder")
	folder.Name = "KitProps"
	folder.Parent = m
	local placed = 0
	for _, e in entry.kitProps do
		local src = kitProp(props, e[1])
		if not src then
			warn("[WaterTemplateSetup] kit prop " .. tostring(e[1]) .. " is not filed")
			continue
		end
		local c = src:Clone()
		-- filed props face -Z (turned 180 from the Blender frame): +pi puts them as laid out
		c:PivotTo(CFrame.new(e[2], e[3], e[4]) * CFrame.Angles(0, math.rad(e[5]) + math.pi, 0))
		for _, p in c:GetDescendants() do
			if p:IsA("BasePart") then lookOnly(p) end
		end
		c.Parent = folder
		placed += 1
	end
	return placed
end

local function template(kit: Instance, props: Instance, key: string, source: string, entry: any): Model
	local src = kit:FindFirstChild(source)
	assert(src and src:IsA("Model"), "PlantKit." .. source .. " is not filed: run PropKitSetup for PlantKit first")
	local c = src:Clone()
	c:PivotTo(TURN)
	local m = Instance.new("Model")
	m.Name = key
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.67, 0.67, 0.67)
	root.Transparency = 1
	root.Anchored, root.CanCollide, root.CanQuery, root.CanTouch = true, false, false, false
	root.CFrame = CFrame.identity
	root.Parent = m
	m.PrimaryPart = root
	m:SetAttribute("StudsPerMetre", 2)
	m:SetAttribute("Source", "PlantKit." .. source)
	for _, p in c:GetChildren() do
		if not p:IsA("BasePart") then continue end
		p.Parent = m
		p.Anchored, p.CanCollide, p.CanTouch = true, false, false
		p.CanQuery = p.Name == source -- the LOD0 main part is the building's ground claim
		if p:IsA("MeshPart") then p.RenderFidelity = Enum.RenderFidelity.Precise end
		if p.Name:find("_Water", 1, true) then waterSkin(p) end -- flat colour from the kit
	end
	c:Destroy()
	for _, a in m:GetDescendants() do -- each clarifier's bridge turns about its tank's axis
		local i = if a:IsA("Attachment") then a.Name:match("^Spin(%d+)$") else nil
		if not i then continue end
		local br = Instance.new("Model")
		br.Name = "Bridge" .. i
		for _, sfx in { "", "_Alpha" } do
			local p = m:FindFirstChild(source .. "_Bridge" .. i .. sfx)
			if p then
				p.Parent = br
				p.CanQuery = false
			end
		end
		br.WorldPivot = CFrame.new((a :: Attachment).WorldPosition)
		CollectionService:AddTag(br, "ClarifierBridge")
		br.Parent = m
	end
	for _, e in entry.fx or {} do
		if e[1] == "boil" then boil(m, e) elseif e[1] == "stalls" then stalls(m, e) end
	end
	for _, a in m:GetDescendants() do
		if not a:IsA("Attachment") then continue end
		if a.Name == "Flare" then flare(a)
		elseif a.Name == "Outfall" then pour(a)
		elseif a.Name == "Plume" then plume(m, a) end
	end
	dress(m, props, entry)
	if entry.pave then
		m:SetAttribute("KitPave", HttpService:JSONEncode(entry.pave))
		m:SetAttribute("GateSpans", entry.gates or "")
		m:SetAttribute("LotDepth", entry.lotDepth)
		CollectionService:AddTag(m, "PavedGates")
	end
	return m
end

function WaterTemplateSetup.run(manifestJson: string): string
	local entries = HttpService:JSONDecode(manifestJson).kits.PlantKit
	local props = ServerStorage.Templates.Asset.Props
	local kit = props:FindFirstChild("PlantKit")
	assert(kit, "Templates.Asset.Props.PlantKit is missing: run PropKitSetup for PlantKit first")
	local templates = ReplicatedStorage.City.ServiceTemplates
	local report = {}
	for key, source in MAP do
		assert(entries[source], "kits_manifest has no PlantKit." .. source)
		local m = template(kit, props, key, source, entries[source])
		retire(templates, key)
		m.Parent = templates
		local bridges, fx = 0, 0
		for _, d in m:GetDescendants() do
			if CollectionService:HasTag(d, "ClarifierBridge") then bridges += 1 end
			if CollectionService:HasTag(d, "SewageFx") then fx += 1 end
		end
		local kp = m:FindFirstChild("KitProps")
		table.insert(report, ("%s <- %s (%d bridges, %d effects, %d kit props)"):format(key, source, bridges, fx,
			if kp then #kp:GetChildren() else 0))
	end
	table.sort(report)
	return table.concat(report, "\n")
end

return WaterTemplateSetup
