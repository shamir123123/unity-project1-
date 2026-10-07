--!strict
-- Static construction footprints until the crane is redesigned. The server owns the
-- construction clock and sends finish; waiting lots need no frame callbacks.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local ConstructionViewController = {}
local LOT_SIZE = 6
local MAX_LOTS = 8
local WAITING_COLOR = Color3.fromRGB(150, 120, 78)
local BUILDING_COLOR = Color3.fromRGB(216, 172, 72)
local _root: Folder? = nil
local _sites: { [string]: Part } = {}
local _connection: RBXScriptConnection? = nil

local function clearSite(id: string)
	local part = _sites[id]
	if part then part:Destroy() end
	_sites[id] = nil
end

local function onConstruction(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "string" then return end
	local id = payload.id
	if payload.kind == "finish" then
		clearSite(id)
		return
	end
	if payload.kind ~= "nest" and payload.kind ~= "start" then return end
	if typeof(payload.pivot) ~= "CFrame" then return end
	if not _root or not _root.Parent then _root = UiScratch.folder("LocalConstruction") end
	local part = _sites[id]
	if not part then
		part = Instance.new("Part")
		part.Name = "Construction_" .. id
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Concrete
		_sites[id] = part
	end
	local width = math.clamp(tonumber(payload.width) or 2, 1, MAX_LOTS)
	local depth = math.clamp(tonumber(payload.depth) or 2, 1, MAX_LOTS)
	local lot = tonumber(payload.lotSize) or LOT_SIZE
	part.Size = Vector3.new(width * lot * 0.95, 0.16, depth * lot * 0.95)
	part.CFrame = payload.pivot * CFrame.new(0, 0.08, 0)
	part.Color = if payload.kind == "start" then BUILDING_COLOR else WAITING_COLOR
	part.Parent = _root
end

function ConstructionViewController.Start(): ()
	if _connection then return end
	local Net = require(ReplicatedStorage:WaitForChild("Networker", 10))
	_connection = Net.SyncConstructionSites.OnClientEvent:Connect(onConstruction)
end

function ConstructionViewController.Cleanup(): ()
	if _connection then _connection:Disconnect() end
	_connection = nil
	for id in _sites do clearSite(id) end
	if _root then _root:Destroy() end
	_root = nil
end

return ConstructionViewController
