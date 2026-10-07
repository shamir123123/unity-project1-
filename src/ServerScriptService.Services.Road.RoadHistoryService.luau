--!strict
-- RoadHistoryService
-- Undo/redo history for user-initiated road edits (place / delete / replace).
-- Each entry is a full snapshot of every segment's geometry; one undo reverses
-- exactly one user action. Owns only the stacks: capturing reads segments via
-- the getter and restoring goes through the callback, both injected at init,
-- so this service knows nothing about topology internals.

local RoadHistoryService = {}

local MAX_HISTORY = 50

local _undoStack: { { any } } = {}
local _redoStack: { { any } } = {}
local _getSegments: () -> { [number]: any }
local _restore: (snapshot: { any }) -> ()
local _records: { [number]: any } = {}
local _snapshot: { any } = table.freeze({})
local _positions: { [number]: number } = {}

function RoadHistoryService.init(getSegments: () -> { [number]: any }, restore: (snapshot: { any }) -> ())
	assert(getSegments and restore, "[RoadHistoryService] requires getSegments + restore")
	_getSegments = getSegments
	_restore = restore
	_records = {}; _snapshot = table.freeze({}); _positions = {}
end

-- Canonical order for a snapshot: by start point, then end point, then id.
--
-- This is what makes NODE ids reproducible. Nodes are never saved -- they are rebuilt on
-- load by replaying segments through getOrCreateNodeWithin, so a node's id is just the
-- order its first segment happened to be replayed in. _getSegments() returns the network's
-- segment MAP, and Luau's iteration order over a hash part is unspecified, so that order
-- (and therefore every node id) came out different on each save. Same city, different
-- numbering -- which is what made node ids look random.
--
-- Sorting on GEOMETRY rather than on id makes the ordering a pure function of the city's
-- shape: the same roads always produce the same node ids, whatever order they were drawn
-- or replayed in. Segment ids are unaffected -- they travel in the snapshot and
-- applySnapshot honours them -- so nothing that references a segment id is disturbed.
local function beforeInOrder(a: any, b: any): boolean
	local ap, bp = a.p0, b.p0
	if ap.X ~= bp.X then return ap.X < bp.X end
	if ap.Z ~= bp.Z then return ap.Z < bp.Z end
	if ap.Y ~= bp.Y then return ap.Y < bp.Y end
	local aq, bq = a.p3, b.p3
	if aq.X ~= bq.X then return aq.X < bq.X end
	if aq.Z ~= bq.Z then return aq.Z < bq.Z end
	if aq.Y ~= bq.Y then return aq.Y < bq.Y end
	-- Ids are unique, so this is a total order -- table.sort needs one.
	return a.id < b.id
end

local function sameSnapshot(a: any, b: any): boolean
	return a.id == b.id
		and a.p0 == b.p0
		and a.p1 == b.p1
		and a.p2 == b.p2
		and a.p3 == b.p3
		and a.roadType == b.roadType
		and a.name == b.name
		and a.vMode == b.vMode
		and a.constSlope == b.constSlope
		and a.isRoundabout == b.isRoundabout
		and a.roundaboutId == b.roundaboutId
		and a.roundaboutCenter == b.roundaboutCenter
		and a.roundaboutRadius == b.roundaboutRadius
		and a.roundaboutPreset == b.roundaboutPreset
		and a.startCorner == b.startCorner
		and a.endCorner == b.endCorner
		and a.startOffset == b.startOffset
		and a.endOffset == b.endOffset
		and a.startFlat == b.startFlat
		and a.endFlat == b.endFlat
		and a.startLane == b.startLane
		and a.endLane == b.endLane
end

-- Frozen entries can be shared by consecutive undo snapshots. Captures never borrow live
-- mutable segment records, and only changed geometry participates in canonical sorting.
function RoadHistoryService.capture(): { any }
	local records: { [number]: any } = {}
	local changed: { [number]: any } = {}
	local reorder: { [number]: boolean } = {}
	local moved: { any } = {}
	local count = 0
	for _, seg in _getSegments() do
		count += 1
		local old = _records[seg.id]
		local record = old
		if not old or not sameSnapshot(old, seg) then
			record = table.freeze({
				id = seg.id,
				p0 = seg.p0,
				p1 = seg.p1,
				p2 = seg.p2,
				p3 = seg.p3,
				roadType = seg.roadType,
				name = seg.name,
				vMode = seg.vMode,
				constSlope = seg.constSlope,
				isRoundabout = seg.isRoundabout,
				roundaboutId = seg.roundaboutId,
				roundaboutCenter = seg.roundaboutCenter,
				roundaboutRadius = seg.roundaboutRadius,
				roundaboutPreset = seg.roundaboutPreset,
				startCorner = seg.startCorner,
				endCorner = seg.endCorner,
				startOffset = seg.startOffset,
				endOffset = seg.endOffset,
				startFlat = seg.startFlat,
				endFlat = seg.endFlat,
				startLane = seg.startLane,
				endLane = seg.endLane,
			})
			changed[seg.id] = record
			if not old or old.p0 ~= seg.p0 or old.p3 ~= seg.p3 then
				reorder[seg.id] = true
				table.insert(moved, record)
			end
		end
		records[seg.id] = record
	end
	local removed = false
	for id in _records do
		if not records[id] then removed = true; break end
	end
	if next(changed) == nil and not removed then return _snapshot end
	local snapshot: { any }
	if not removed and #moved == 0 then
		snapshot = table.clone(_snapshot)
		for id, record in changed do snapshot[_positions[id]] = record end
	else
		snapshot = {}
		if #moved > count / 4 then
			for _, record in records do table.insert(snapshot, record) end
			table.sort(snapshot, beforeInOrder)
		else
			table.sort(moved, beforeInOrder)
			local i = 1
			for _, old in _snapshot do
				local record = records[old.id]
				if not record or reorder[old.id] then continue end
				while moved[i] and beforeInOrder(moved[i], record) do
					table.insert(snapshot, moved[i]); i += 1
				end
				table.insert(snapshot, record)
			end
			while moved[i] do table.insert(snapshot, moved[i]); i += 1 end
		end
		_positions = {}
		for i, record in snapshot do _positions[record.id] = i end
	end
	_records = records
	_snapshot = table.freeze(snapshot)
	return _snapshot
end

-- Record the pre-edit state. Recorded only for user-initiated edits, never for
-- internal mutations. Any new edit invalidates the redo stack.
function RoadHistoryService.push(snapshot: { any })
	table.insert(_undoStack, snapshot)
	if #_undoStack > MAX_HISTORY then
		table.remove(_undoStack, 1)
	end
	table.clear(_redoStack)
end

-- Wipe both stacks. Called when a city is restored from a save: history entries
-- reference the pre-load network and undoing into them would resurrect it.
function RoadHistoryService.clear()
	table.clear(_undoStack)
	table.clear(_redoStack)
	_records = {}; _snapshot = table.freeze({}); _positions = {}
end

function RoadHistoryService.undo(): boolean
	if #_undoStack == 0 then
		return false
	end
	local current = RoadHistoryService.capture()
	local snap = table.remove(_undoStack) :: { any }
	table.insert(_redoStack, current)
	if #_redoStack > MAX_HISTORY then
		table.remove(_redoStack, 1)
	end
	_restore(snap)
	return true
end

function RoadHistoryService.redo(): boolean
	if #_redoStack == 0 then
		return false
	end
	local current = RoadHistoryService.capture()
	local snap = table.remove(_redoStack) :: { any }
	table.insert(_undoStack, current)
	if #_undoStack > MAX_HISTORY then
		table.remove(_undoStack, 1)
	end
	_restore(snap)
	return true
end

return RoadHistoryService
