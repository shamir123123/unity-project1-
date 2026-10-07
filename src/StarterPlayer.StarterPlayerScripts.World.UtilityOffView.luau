--!strict
-- UtilityOffView -- a generator the player switched off (attribute Off, EmergencyService.setOff) goes quiet:
-- its chimney smoke and steam stop. Pure cosmetic client view. Turbines (WindTurbineView) and solar rows
-- (SolarTrackerView) read the same attribute themselves; the sewage works' effects already follow their
-- SewageLoad, which is 0 when off. Event-driven: nothing runs per frame.

local CollectionService = game:GetService("CollectionService")

local TAG = "PowerPlant" -- EmergencyService's tag for every Power-kind building

local UtilityOffView = {}

local _conns: { [Instance]: RBXScriptConnection } = {}
local _added: RBXScriptConnection? = nil
local _removed: RBXScriptConnection? = nil

local function apply(model: Instance)
	local on = not model:GetAttribute("Off")
	for _, d in model:GetDescendants() do
		if d:IsA("ParticleEmitter") and not CollectionService:HasTag(d, "SewageFx") then d.Enabled = on end
	end
end

local function track(model: Instance)
	if _conns[model] then return end
	_conns[model] = model:GetAttributeChangedSignal("Off"):Connect(function() apply(model) end)
	if model:GetAttribute("Off") then apply(model) end
end

local function untrack(model: Instance)
	local c = _conns[model]
	if c then c:Disconnect() end
	_conns[model] = nil
end

function UtilityOffView.Start()
	for _, m in CollectionService:GetTagged(TAG) do track(m) end
	_added = CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	_removed = CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
end

function UtilityOffView.Stop()
	for m in _conns do untrack(m) end
	if _added then _added:Disconnect(); _added = nil end
	if _removed then _removed:Disconnect(); _removed = nil end
end

return UtilityOffView
