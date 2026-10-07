--!strict
-- Temporary local road feedback. DataCache remains the server's topology; edits
-- are visual overrides until their own acknowledged revision has finished drawing.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataCache = require(ReplicatedStorage.DataCache)
local Road = ReplicatedStorage.Road
local RoadTypeCatalog = require(Road.RoadTypeCatalog)
local SnapUtil = require(Road.SnapUtil)
local RoadPieces = require(script.Parent.RoadPieces)
local RoadMeshView = require(script.Parent.RoadMeshView)
local RoadPreviewGeometry = require(script.Parent.RoadPreviewGeometry)
local UiScratch = require(script.Parent.Parent.Core.UiScratch)

local RoadEditPreview = {}
local TIMEOUT = 10
local POLL = 0.03
local MAX_PENDING = 32
local MAX_AFFECTED_SEGMENTS = 64
-- Upgrade / delete used to hide the affected cells and stand crude flat Parts in for every road
-- in them until the server acknowledged the edit -- a round trip at the very least -- because the
-- predicted mesh then took that long to bake. It now bakes live (RoadMeshView, LIVE BAKES) a frame
-- or two after the click, so the real predicted road simply replaces the old one in place, and
-- the flat stand-ins (a visible flash of the whole cell) are no longer shown.
local STAND_IN_CELLS = false
type Pending = { at: number, revision: number?, model: Model?, predicted: boolean, rollingBack: boolean? }
local _pending: { [number]: Pending } = {}
local _nextToken = 0
local _count = 0
local _pumping = false
local _connection: RBXScriptConnection? = nil

local function clear(token: number)
	local pending = _pending[token]
	if not pending then return end
	_pending[token] = nil
	_count -= 1
	if pending.model then pending.model:Destroy() end
	if pending.predicted then
		RoadPieces.setPrediction(token, nil)
	end
	if pending.predicted or pending.rollingBack then RoadMeshView.clearPredictionCells(token) end
end

local function rollback(token: number)
	local pending = _pending[token]
	if not pending then return end
	if not pending.predicted then clear(token); return end
	-- Keep the cell proxy showing restored geometry until its static rollback bake lands.
	pending.predicted = false
	pending.rollingBack = true
	pending.revision = nil
	pending.at = os.clock()
	RoadPieces.setPrediction(token, nil)
	if RoadMeshView.isPredictionReady(token) then clear(token) end
end

local function begin(model: Model?, predicted: boolean): number?
	if _count >= MAX_PENDING then
		if model then model:Destroy() end
		return nil
	end
	_nextToken += 1
	local token = _nextToken
	_pending[token] = { at = os.clock(), model = model, predicted = predicted }
	_count += 1
	if not _pumping then
		_pumping = true
		task.spawn(function()
			while _count > 0 do
				task.wait(POLL)
				for id, pending in _pending do
					local revision = pending.revision
					if os.clock() - pending.at >= TIMEOUT then
						if pending.rollingBack then clear(id) else rollback(id) end
						warn("[RoadEditPreview] acknowledgement or rollback timed out; restored authoritative road view")
					elseif pending.rollingBack and RoadMeshView.isPredictionReady(id) then
						clear(id)
					elseif revision and DataCache.GetRoadRevision() >= revision and RoadMeshView.isPredictionReady(id) then
						clear(id)
					end
				end
			end
			_pumping = false
		end)
	end
	return token
end

function RoadEditPreview.Start(): ()
	if _connection then return end
	local Net = require(ReplicatedStorage.Networker)
	_connection = Net.PlaceRoadResult.OnClientEvent:Connect(function(ok: any, _reason: any, _kind: any, token: any, revision: any)
		local pending = if typeof(token) == "number" then _pending[token] else nil
		if not pending or pending.rollingBack then return end
		if ok ~= true or typeof(revision) ~= "number" then rollback(token); return end
		pending.revision = revision
	end)
end

function RoadEditPreview.place(req: any): number?
	if _count >= MAX_PENDING then return nil end
	local model = Instance.new("Model")
	model.Name = "PendingRoad"
	RoadPreviewGeometry.draw(model, req)
	if typeof(req.twin) == "table" then
		local twin = table.clone(req.twin)
		twin.roadType = req.roadType
		RoadPreviewGeometry.draw(model, twin)
	end
	model.Parent = UiScratch.root()
	return begin(model, false)
end

function RoadEditPreview.remove(entries: { any }): number?
	if workspace:GetAttribute("RoadMeshV2") ~= true then return nil end
	local overrides: { [number]: any } = {}
	for _, entry in entries do
		local seg = DataCache.GetSegmentById(entry.id)
		if seg and not seg.isRoundabout and (not seg.vMode or seg.vMode == "Ground") then
			overrides[seg.id] = false
		end
	end
	if next(overrides) == nil then return nil end
	local ids: { number } = {}
	for id in overrides do table.insert(ids, id) end
	local affected = RoadPieces.affectedSegments(ids, MAX_AFFECTED_SEGMENTS)
	if not affected then return nil end
	local cells = RoadPieces.cellsForSegments(affected)
	local token = begin(nil, true)
	if token then
		RoadPieces.setPrediction(token, overrides)
		if STAND_IN_CELLS then
			for cell in RoadPieces.cellsForSegments(affected) do cells[cell] = true end
			RoadMeshView.hidePredictionCells(token, cells)
		end
	end
	return token
end

function RoadEditPreview.replace(id: number, roadType: string, cursor: Vector3?): number?
	if workspace:GetAttribute("RoadMeshV2") ~= true then return nil end
	local seg = DataCache.GetSegmentById(id)
	if not seg or seg.isRoundabout or (seg.vMode and seg.vMode ~= "Ground") then return nil end
	if roadType == "" or roadType == seg.roadType or not RoadTypeCatalog.get(roadType) then return nil end
	-- landing where the server lays it (SnapUtil.upgradeLanding)
	local replacement = if cursor then SnapUtil.upgradeLanding(seg :: any, roadType, cursor) :: any else table.clone(seg)
	replacement.roadType = roadType
	local affected = RoadPieces.affectedSegments({ id }, MAX_AFFECTED_SEGMENTS)
	if not affected then return nil end
	local cells = RoadPieces.cellsForSegments(affected)
	local token = begin(nil, true)
	if token then
		RoadPieces.setPrediction(token, { [id] = replacement })
		if STAND_IN_CELLS then
			for cell in RoadPieces.cellsForSegments(affected) do cells[cell] = true end
			RoadMeshView.hidePredictionCells(token, cells)
		end
	end
	return token
end

function RoadEditPreview.Cleanup(): ()
	if _connection then _connection:Disconnect() end
	_connection = nil
	for token in _pending do clear(token) end
end

return RoadEditPreview
