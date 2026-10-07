--!strict
-- EmergencyPlacementController
-- Places the service buildings (Hospital / Police / Fire + the utilities) from the
-- Civic and Utilities flyouts. The ghost rides the cursor and places FREE wherever it
-- fits (R rotates 45 degrees); the server re-validates with the same box check.
-- Coverage visuals come from the shared CoverageOverlay.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local ServiceBuildingModel = require(ReplicatedStorage.City.ServiceBuildingModel)
local CoverageOverlay = require(script.Parent:WaitForChild("CoverageOverlay"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local EmergencyPlacementController = {}

local _inited = false
local _bound = false
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _ghostRing: BasePart? = nil
local _keepOut: { BasePart } = {}
-- Amber: this is a "you cannot build here", not a coverage reading.
local KEEP_OUT_COLOR = Color3.fromRGB(232, 168, 64)

-- Ghost lifecycle, cursor tracking, the fit test, the tint and the cost readout are all
-- GhostPlacement's. What is genuinely this tool's own is the coverage ring below.
local _placer = GhostPlacement.new({
	folderName = "EmergencyPlacement",
	clearsNature = true, -- turbines, plants, every service building go up on top of trees; the server clears them
	build = function(key: string): Model?
		local ghost = ServiceBuildingModel.build(key, true)
		if not ghost then return nil end
		ghost.Name = "GhostEmergency_" .. key
		return ghost
	end,
	footprint = function(key: string): Vector3?
		local spec = ServiceTypes.get(key)
		return if spec then ServiceTypes.footprintStuds(spec) else nil
	end,
	cost = function(key: string): number?
		local spec = ServiceTypes.get(key)
		return if spec then spec.cost else nil
	end,
	place = function(key: string, pivot: CFrame)
		Net.RequestPlaceService:FireServer("Emergency", key, pivot)
	end,
	-- Turbines go where the cursor is: a field, not a frontage (ServiceTypes PLACEMENT).
	roadSnap = function(key: string): boolean
		local spec = ServiceTypes.get(key)
		return not (spec and spec.placement == "Free")
	end,
	-- Service buildings face the street on +Z (ServiceBuildingModel, entrance(), the coal plant's
	-- and solar farm's gates); the snap faces -Z at it. Without this they stood back to the road.
	frontYaw = math.pi,
	-- Two turbines' blade rings (amber) may not overlap; anything else is held off by its
	-- footprint alone. Same rule as PowerService.spacingBlockedAt, so a green ghost is never
	-- refused on arrival.
	veto = function(key: string, pivot: CFrame): string?
		local spec = ServiceTypes.get(key)
		local r = spec and spec.bladeRadius
		if not r then return nil end
		local here = pivot.Position
		for _, m in CollectionService:GetTagged("PowerPlant") do
			if not m:IsA("Model") or not m.Parent then continue end
			local other = ServiceTypes.get(m:GetAttribute("ServiceType") or "")
			local o = other and other.bladeRadius
			if not o then continue end
			local c = m:GetPivot().Position
			local dx, dz = c.X - here.X, c.Z - here.Z
			if math.sqrt(dx * dx + dz * dz) < r + o then
				return "its blades would hit another " .. other.name
			end
		end
		return nil
	end,

})
_placer:setKey("Hospital")

local function clearRing()
	if _ghostRing then _ghostRing:Destroy(); _ghostRing = nil end
end

local function clearKeepOut()
	for _, d in _keepOut do d:Destroy() end
	table.clear(_keepOut)
end

-- The amber blade rings: one round every standing turbine, sized to its own rotor, and one
-- under the ghost. Two may not overlap -- `veto` above refuses it. Nothing else has a ring.
local _ringAt: { Vector3 } = {}
local _ringR: { number } = {}
local function updateKeepOut()
	local spec = ServiceTypes.get(_placer:getKey())
	local ghost = _placer:visibleGhost()
	if not (spec and spec.bladeRadius) then
		if #_keepOut > 0 then clearKeepOut() end
		return
	end

	table.clear(_ringAt)
	table.clear(_ringR)
	for _, m in CollectionService:GetTagged("PowerPlant") do
		if not m:IsA("Model") then continue end
		local other = ServiceTypes.get(m:GetAttribute("ServiceType") or "")
		if other and other.bladeRadius then
			_ringAt[#_ringAt + 1] = m:GetPivot().Position
			_ringR[#_ringR + 1] = other.bladeRadius
		end
	end
	if ghost then
		_ringAt[#_ringAt + 1] = ghost:GetPivot().Position
		_ringR[#_ringR + 1] = spec.bladeRadius
	end

	-- Reuse the discs already made; the pool only changes when a turbine goes up or down.
	while #_keepOut > #_ringAt do
		_keepOut[#_keepOut]:Destroy()
		_keepOut[#_keepOut] = nil
	end
	while #_keepOut < #_ringAt do
		local d = CoverageOverlay.makeDisc(1, KEEP_OUT_COLOR)
		d.Transparency = 0.82
		d.Parent = UiScratch.folder("EmergencyPlacement")
		_keepOut[#_keepOut + 1] = d
	end
	for i, pos in _ringAt do
		local d = _keepOut[i]
		local w = _ringR[i] * 2
		if d.Size.Y ~= w then d.Size = Vector3.new(0.3, w, w) end
		CoverageOverlay.discTo(d, pos)
	end
end

-- Reach preview under the placement ghost, so the player sees what the new
-- building would cover before clicking. Discs come from the shared CoverageOverlay.
local function updateGhostRing()
	local spec = ServiceTypes.get(_placer:getKey())
	local ghost = _placer:visibleGhost()
	-- A utility's coverageRadius is its yard (where a line plugs in), not a reach: buildings
	-- claim their footprint only, and the turbines draw their blade ring instead.
	if not spec or not ghost or spec.category == "Utilities" then
		if _ghostRing then _ghostRing.Parent = nil end
		return
	end
	local ring = _ghostRing
	if not ring or ring.Size.Y ~= spec.coverageRadius * 2 then
		if ring then ring:Destroy() end
		ring = CoverageOverlay.makeDisc(spec.coverageRadius, CoverageOverlay.ringColor(spec.kind))
		ring.Transparency = 0.7
		_ghostRing = ring
	end
	if not ring.Parent then ring.Parent = UiScratch.folder("EmergencyPlacement") end
	CoverageOverlay.discTo(ring, ghost:GetPivot().Position)
end

local function showOverlayForSelection()
	local spec = ServiceTypes.get(_placer:getKey())
	-- Utilities have no reach to show (user 2026-10-07: the power/water views are gone); services keep their discs.
	if spec and spec.kind ~= "Power" and spec.kind ~= "Water" and spec.kind ~= "Sewage" then
		CoverageOverlay.show(spec.kind, "grey")
	end
end

function EmergencyPlacementController.setEnabled(enabled: boolean)
	if enabled == _placer:isEnabled() then return end
	_placer:setEnabled(enabled)
	if enabled then
		showOverlayForSelection()
	else
		CoverageOverlay.clear()
		clearRing()
		clearKeepOut()
	end
end

function EmergencyPlacementController.isEnabled(): boolean
	return _placer:isEnabled()
end

function EmergencyPlacementController.setServiceType(key: string)
	if not ServiceTypes.get(key) then return end
	_placer:setKey(key)
	clearRing() -- radius is per service kind, so the disc is rebuilt with the ghost
	clearKeepOut()
	if _placer:isEnabled() then showOverlayForSelection() end
end

function EmergencyPlacementController.getServiceType(): string
	return _placer:getKey()
end

function EmergencyPlacementController.Init()
	if _inited then return end
	_inited = true
end

function EmergencyPlacementController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(function()
		if not _placer:isEnabled() then return end
		_placer:update()
		updateGhostRing()
		updateKeepOut()
		CoverageOverlay.maybeRefresh()
	end)
	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _placer:isEnabled() or gameProcessed then return end
		if Settings.pressed("Back", input) then
			EmergencyPlacementController.setEnabled(false)
			return
		end
		if Settings.pressed("RotateObject", input) then
			_placer:rotate(45)
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		_placer:tryPlace()
	end)
end

function EmergencyPlacementController.Start() end

function EmergencyPlacementController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	_placer:destroy()
	CoverageOverlay.clear()
	clearRing()
	clearKeepOut()
	_bound = false
	_inited = false
end

return EmergencyPlacementController
