--!strict
-- Edit-time authoring tool (NOT runtime). Builds the power utilities' service templates
-- (ReplicatedStorage.City.ServiceTemplates.<Key>, what ServiceBuildingModel clones) from the PowerKit
-- props Authoring.PropKitSetup filed in ServerStorage.Templates.Asset.Props.PowerKit:
--   WindTurbine, AdvancedWindTurbine <- WindTurbine_Small, WindTurbine_Big: a Root, the body, and a Rotor
--       sub-model pivoted on the RotorAxis marker (tag WindTurbineRotor: WindTurbineView spins it).
--   SolarFarm <- SolarFarm with one SolarTracker per Row## marker, each row a Model pivoted on its tube
--       axis (tag SolarTracker: SolarTrackerView turns it to the sun); the existing kit props the manifest
--       lists (kitProps: LightKit lamps, RoofKit roof plant); and its paving as DATA for LotDressingService (tag PavedGates:
--       KitPave inside the fence, GateSpans + LotDepth for the drive from the gate to the road).
--   PowerPlant <- CoalPlant (96 x 144 m station): the same kit props and paving data; its chimney's
--       Smoke marker gets a stack-sized plume and the cooling bank's Steam1..6 markers a vapour plume.
-- A Blender prop faces -Z once imported and a service building's road side is +Z, so each turns 180.
-- What a template replaces goes to ServerStorage.PropsRetired.ServiceTemplates (the first one kept).
-- Only the base LOD0 part answers queries (the placement box, poles, clicks); the rest is look.
--
--   local get = function(f) return game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/" .. f) end
--   require(game.ServerStorage.Authoring.PowerTemplateSetup).run(get("kits_manifest.json"))

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PowerTemplateSetup = {}

local TURN = CFrame.Angles(0, math.pi, 0)

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
	if bin:FindFirstChild(key) then
		old:Destroy() -- the original is already kept; this is an earlier run's output
	else
		old.Parent = bin
	end
end

local function newModel(name: string, source: string): Model
	local m = Instance.new("Model")
	m.Name = name
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.67, 0.67, 0.67)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CFrame = CFrame.identity
	root.Parent = m
	m.PrimaryPart = root
	m:SetAttribute("StudsPerMetre", 2)
	m:SetAttribute("Source", "PowerKit." .. source)
	return m
end

local function adopt(p: BasePart, into: Instance, queries: boolean)
	p.Parent = into
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = queries
end

local function turbine(kit: Instance, source: string, key: string): Model
	local src = kit:FindFirstChild(source)
	assert(src and src:IsA("Model"), "PowerKit." .. source .. " is not filed")
	local c = src:Clone()
	c:PivotTo(TURN)
	local m = newModel(key, source)
	local rotor = Instance.new("Model")
	rotor.Name = "Rotor"
	rotor.Parent = m
	local hub: Vector3? = nil
	for _, p in c:GetChildren() do
		if not p:IsA("BasePart") then continue end
		local att = p:FindFirstChild("RotorAxis")
		if att and att:IsA("Attachment") then hub = att.WorldPosition end
		local isRotor = string.find(p.Name, "_Rotor", 1, true) ~= nil
		-- the blades are spun every frame and kept apart by the blade ring: they answer nothing
		adopt(p, if isRotor then rotor else m, not isRotor and p:GetAttribute("LOD") == 0)
		if p:IsA("MeshPart") then p.RenderFidelity = Enum.RenderFidelity.Precise end
	end
	assert(hub, source .. " has no RotorAxis marker")
	rotor.WorldPivot = CFrame.new(hub :: Vector3)
	CollectionService:AddTag(rotor, "WindTurbineRotor")
	c:Destroy()
	return m
end

local function kitProp(props: Instance, name: string): Model?
	for _, k in props:GetChildren() do
		local p = k:FindFirstChild(name)
		if p and p:IsA("Model") then return p end
	end
	return nil
end

local dress: (Model, Instance, any) -> number

local function solarFarm(kit: Instance, props: Instance, entry: any): (Model, number, number)
	local src, tracker = kit:FindFirstChild("SolarFarm"), kit:FindFirstChild("SolarTracker")
	assert(src and tracker, "PowerKit.SolarFarm / SolarTracker are not filed")
	local c = src:Clone()
	c:PivotTo(TURN)
	local m = newModel("SolarFarm", "SolarFarm")
	local host = c:FindFirstChild("SolarFarm")
	assert(host, "SolarFarm has no main part")
	local marks = {}
	for _, a in host:GetChildren() do
		if a:IsA("Attachment") and a.Name:match("^Row%d+$") then table.insert(marks, a) end
	end
	table.sort(marks, function(a, b) return a.Name < b.Name end)
	local rows = 0
	for _, att in marks do
		local t = tracker:Clone()
		t:PivotTo(TURN)
		local axis = t:FindFirstChild("Axis", true)
		assert(axis and axis:IsA("Attachment"), "SolarTracker has no Axis marker")
		t:PivotTo(t:GetPivot() + (att.WorldPosition - axis.WorldPosition))
		local row = Instance.new("Model")
		row.Name = att.Name
		for _, p in t:GetChildren() do
			if p:IsA("BasePart") then adopt(p, row, false) end
		end
		row.WorldPivot = att.WorldCFrame -- LookVector along the tube, UpVector up
		CollectionService:AddTag(row, "SolarTracker")
		row.Parent = m
		t:Destroy()
		rows += 1
	end
	for _, p in c:GetChildren() do
		-- the main part's box spans the plot (cameras at all four corners): it is the farm's ground claim
		if p:IsA("BasePart") then adopt(p, m, p.Name == "SolarFarm") end
	end
	c:Destroy()
	return m, rows, dress(m, props, entry)
end

-- The manifest's kit props (existing kits' lamps, roof plant, tanks...) set in, and the site's paving
-- as data for LotDressingService. Returns how many props were placed.
function dress(m: Model, props: Instance, entry: any): number
	local dressing = Instance.new("Folder")
	dressing.Name = "KitProps"
	dressing.Parent = m
	local placed = 0
	for _, e in entry.kitProps or {} do
		local src = kitProp(props, e[1])
		if not src then
			warn("[PowerTemplateSetup] kit prop " .. tostring(e[1]) .. " is not filed")
			continue
		end
		local c = src:Clone()
		-- filed props face -Z (turned 180 from the farm's Blender frame): +pi puts them as laid out
		c:PivotTo(CFrame.new(e[2], e[3], e[4]) * CFrame.Angles(0, math.rad(e[5]) + math.pi, 0))
		for _, p in c:GetDescendants() do
			if p:IsA("BasePart") then adopt(p, p.Parent :: Instance, false) end
		end
		c.Parent = dressing
		placed += 1
	end
	m:SetAttribute("KitPave", HttpService:JSONEncode(entry.pave))
	m:SetAttribute("GateSpans", entry.gates)
	m:SetAttribute("LotDepth", entry.lotDepth)
	CollectionService:AddTag(m, "PavedGates")
	return placed
end

-- Plumes sized to the station: PropKitSetup's Smoke emitter is a chimney-pot's; a 90 m stack wants a
-- wide, slow, drifting one. Steam off the fan stacks is whiter and gone sooner. ~10 particles each alive.
local function plume(att: Attachment, steam: boolean)
	local pe = att:FindFirstChildOfClass("ParticleEmitter") or Instance.new("ParticleEmitter")
	pe.Name = if steam then "Steam" else "Smoke"
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color = if steam then ColorSequence.new(Color3.fromRGB(246, 246, 244))
		else ColorSequence.new(Color3.fromRGB(196, 194, 190), Color3.fromRGB(150, 150, 148))
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, if steam then 0.35 else 0.45),
		NumberSequenceKeypoint.new(1, 1) })
	pe.Size = if steam then NumberSequence.new(5, 18) else NumberSequence.new(7, 34)
	pe.Lifetime = if steam then NumberRange.new(3, 5) else NumberRange.new(9, 14)
	pe.Rate = if steam then 2 else 2.4 -- 2026-10-07: was 1.2 (user: more smog)
	pe.Speed = if steam then NumberRange.new(5, 7) else NumberRange.new(5, 7)
	pe.SpreadAngle = Vector2.new(6, 6)
	pe.Drag = 0.6
	pe.Acceleration = if steam then Vector3.new(0.8, 0.5, 0) else Vector3.new(1.6, 0.2, 0)
	pe.LightInfluence = 1
	pe.Parent = att
end

local function coalPlant(kit: Instance, props: Instance, entry: any): (Model, number)
	local src = kit:FindFirstChild("CoalPlant")
	assert(src and src:IsA("Model"), "PowerKit.CoalPlant is not filed")
	local c = src:Clone()
	c:PivotTo(TURN)
	local m = newModel("PowerPlant", "CoalPlant")
	for _, p in c:GetChildren() do
		-- the main part's box is the station's ground claim (buildings, chimney, cooling bank, yard)
		if p:IsA("BasePart") then adopt(p, m, p.Name == "CoalPlant") end
	end
	c:Destroy()
	for _, a in m:GetDescendants() do
		if a:IsA("Attachment") and (a.Name == "Smoke" or a.Name:match("^Steam%d+$")) then
			plume(a, a.Name ~= "Smoke")
		end
	end
	return m, dress(m, props, entry)
end

function PowerTemplateSetup.run(manifestJson: string): string
	local entries = HttpService:JSONDecode(manifestJson).kits.PowerKit
	local props = ServerStorage.Templates.Asset.Props
	local kit = props:FindFirstChild("PowerKit")
	assert(kit, "Templates.Asset.Props.PowerKit is missing: run PropKitSetup for PowerKit first")
	local templates = ReplicatedStorage.City.ServiceTemplates
	local report = {}
	for key, source in { WindTurbine = "WindTurbine_Small", AdvancedWindTurbine = "WindTurbine_Big" } do
		local m = turbine(kit, source, key)
		retire(templates, key)
		m.Parent = templates
		table.insert(report, key .. " <- " .. source)
	end
	local farm, rows, placed = solarFarm(kit, props, entries.SolarFarm)
	retire(templates, "SolarFarm")
	farm.Parent = templates
	table.insert(report, ("SolarFarm <- SolarFarm + %d tracker rows, %d kit props, %d paving patches"):format(
		rows, placed, #entries.SolarFarm.pave))
	if entries.CoalPlant then
		local plant, n = coalPlant(kit, props, entries.CoalPlant)
		retire(templates, "PowerPlant")
		plant.Parent = templates
		table.insert(report, ("PowerPlant <- CoalPlant + %d kit props, %d paving patches"):format(n, #entries.CoalPlant.pave))
	end
	return table.concat(report, "\n")
end

return PowerTemplateSetup
