--!strict
-- SewageWorksView -- the sewage works look like what they are doing. Pure cosmetic client view.
--   * Emitters tagged SewageFx (an outlet's pour and the plume it spreads on the water, a plant's aeration
--     boil, the digesters' flare; authored OFF by Authoring.WaterTemplateSetup with their full-load rate in
--     FxRate) run at FxRate x the works' SewageLoad -- WaterService's real share of the city's sewage, 0
--     without power. No sewage, no pour.
--   * Clarifier bridges (tag ClarifierBridge, a sub-model pivoted on the tank's axis) turn about one rev a
--     minute and a half while their plant works, each from where it stopped; far ones hold still.
--   * Water textures (tag SewageWater, attribute Drift = studs/s) drift and swirl so a tank never looks
--     frozen; only near the camera.
-- A ghost preview has no ServiceId above it: its effects stay off and its bridges still.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TURN = math.pi * 2 / 90 -- rad/s
local NEAR = 700              -- studs: past this a turn or a ripple drift is too small to see

local SewageWorksView = {}

type Spin = { root: BasePart, offset: CFrame, works: Model, angle: number }
type Ripple = { tex: Texture, part: BasePart, drift: number, phase: number }

local _fx: { [ParticleEmitter]: RBXScriptConnection } = {}
local _spin: { [Model]: Spin } = {}
local _ripples: { [Texture]: Ripple } = {}
local _conns: { RBXScriptConnection } = {}
local _clock = 0

-- The placed service building an effect belongs to (it carries ServiceId), or nil for a ghost.
local function worksOf(inst: Instance): Model?
	local m = inst:FindFirstAncestorWhichIsA("Model")
	while m do
		if m:GetAttribute("ServiceId") ~= nil then return m end
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

local function loadOf(works: Model): number
	return tonumber(works:GetAttribute("SewageLoad")) or 0
end

local function apply(pe: ParticleEmitter, works: Model)
	local rate = (tonumber(pe:GetAttribute("FxRate")) or 0) * loadOf(works)
	pe.Rate = rate
	pe.Enabled = rate > 0
end

local function trackFx(inst: Instance)
	if not inst:IsA("ParticleEmitter") or _fx[inst] then return end
	local works = worksOf(inst)
	if not works then return end
	apply(inst, works)
	_fx[inst] = works:GetAttributeChangedSignal("SewageLoad"):Connect(function() apply(inst, works) end)
end

local function untrackFx(inst: Instance)
	local c = _fx[inst :: ParticleEmitter]
	if c then
		c:Disconnect()
		_fx[inst :: ParticleEmitter] = nil
	end
end

local function trackBridge(inst: Instance)
	if not inst:IsA("Model") then return end
	local works = worksOf(inst)
	local root = works and works.PrimaryPart
	if not (works and root) then return end
	_spin[inst] = { root = root, offset = root.CFrame:ToObjectSpace(inst:GetPivot()), works = works,
		angle = math.random() * math.pi * 2 }
end

local function trackRipple(inst: Instance)
	if not inst:IsA("Texture") then return end
	local part = inst.Parent
	if not (part and part:IsA("BasePart")) then return end
	_ripples[inst] = { tex = inst, part = part, drift = tonumber(inst:GetAttribute("Drift")) or 0.4,
		phase = math.random() * 10 }
end

local function step(dt: number)
	_clock += dt
	local cam = Workspace.CurrentCamera
	local eye = if cam then cam.CFrame.Position else Vector3.zero
	for model, e in _spin do
		if not (model.Parent and e.root.Parent) then
			_spin[model] = nil
			continue
		end
		if loadOf(e.works) <= 0 or (e.root.Position - eye).Magnitude > NEAR then continue end
		e.angle += dt * TURN
		model:PivotTo(e.root.CFrame * e.offset * CFrame.Angles(0, e.angle, 0))
	end
	for tex, r in _ripples do
		if not (tex.Parent and r.part.Parent) then
			_ripples[tex] = nil
			continue
		end
		if (r.part.Position - eye).Magnitude > NEAR then continue end
		local t = _clock + r.phase
		tex.OffsetStudsU = t * r.drift + math.cos(t * 0.35) * 1.5
		tex.OffsetStudsV = t * r.drift * 0.6 + math.sin(t * 0.35) * 1.5
	end
end

function SewageWorksView.Start()
	for tag, add in { SewageFx = trackFx, ClarifierBridge = trackBridge, SewageWater = trackRipple } :: { [string]: (Instance) -> () } do
		for _, inst in CollectionService:GetTagged(tag) do add(inst) end
		table.insert(_conns, CollectionService:GetInstanceAddedSignal(tag):Connect(add))
	end
	table.insert(_conns, CollectionService:GetInstanceRemovedSignal("SewageFx"):Connect(untrackFx))
	table.insert(_conns, CollectionService:GetInstanceRemovedSignal("ClarifierBridge"):Connect(function(inst)
		_spin[inst :: Model] = nil
	end))
	table.insert(_conns, CollectionService:GetInstanceRemovedSignal("SewageWater"):Connect(function(inst)
		_ripples[inst :: Texture] = nil
	end))
	table.insert(_conns, RunService.Heartbeat:Connect(step))
end

function SewageWorksView.Stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	for pe in _fx do untrackFx(pe) end
	table.clear(_spin)
	table.clear(_ripples)
end

return SewageWorksView
