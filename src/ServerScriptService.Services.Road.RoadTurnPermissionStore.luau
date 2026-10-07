--!strict
-- RoadTurnPermissionStore
-- Single source of truth for per-intersection turn/connection permissions and the
-- lane-change gate rules. Owns the two permission tables AND the editing API: each
-- edit validates against the live network + nav graph, mutates the stored config,
-- then triggers a nav rebuild + turn-permission broadcast. Collaborators (network,
-- nav graph, the rebuild scheduler, the broadcast fn) are injected by RoadService at
-- init, so this module never requires RoadService -- require direction stays
-- RoadService -> here, matching RoadReplicationService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Road.RoadTypes)

local RoadTurnPermissionStore = {}

local TURN_KEYS = {
	left = true,
	right = true,
	straight = true,
	uturn = true,
}

-- Injected at init (see RoadService.Init). Never required directly.
local _network: any = nil
local _navGraph: any = nil
local _scheduleNavRebuild: any = nil
local _broadcastTurnPermissions: any = nil

-- The owned tables -- the single source of truth for intersection config.
local _turnPermissions: { [Types.NodeId]: any } = {}
local _laneChangeRules: { [string]: boolean } = {}

export type Deps = {
	network: any,
	navGraph: any,
	scheduleNavRebuild: (Types.NodeId?, boolean?, boolean?) -> (),
	broadcastTurnPermissions: (any?, Types.NodeId?) -> (),
}

function RoadTurnPermissionStore.init(deps: Deps)
	_network = deps.network
	_navGraph = deps.navGraph
	_scheduleNavRebuild = deps.scheduleNavRebuild
	_broadcastTurnPermissions = deps.broadcastTurnPermissions
end

local function defaultTurnPermissions(): any
	return {
		left = true,
		right = true,
		straight = true,
		uturn = false,
		laneRules = {},
		customConnections = {},
	}
end

-- ---- Accessors used by RoadService's topology + nav-rebuild machinery ---------

-- The node's permissions, creating defaults on first access.
function RoadTurnPermissionStore.getOrInit(nodeId: Types.NodeId): any
	local perms = _turnPermissions[nodeId]
	if not perms then
		perms = defaultTurnPermissions()
		_turnPermissions[nodeId] = perms
	end
	return perms
end

-- Drop a node's stored permissions (its arm count / topology changed).
function RoadTurnPermissionStore.invalidate(nodeId: Types.NodeId)
	_turnPermissions[nodeId] = nil
end

-- Whole tables, handed to the nav graph on (re)build.
function RoadTurnPermissionStore.permissions(): { [Types.NodeId]: any }
	return _turnPermissions
end

function RoadTurnPermissionStore.laneChangeRules(): { [string]: boolean }
	return _laneChangeRules
end

-- Drop lane-change rules keyed to a removed segment (keys are "<segmentId>|...").
function RoadTurnPermissionStore.clearLaneRulesForSegment(segmentId: Types.SegmentId)
	local prefix = tostring(segmentId) .. "|"
	for ruleKey in _laneChangeRules do
		if string.sub(ruleKey, 1, #prefix) == prefix then
			_laneChangeRules[ruleKey] = nil
		end
	end
end

-- Where the lane connector works: every node two or more roads meet at -- a plain joint
-- (whether cars may change lanes across it) as much as a junction. Not a dead end, not a
-- roundabout (its ring keeps each car in its own lane), not a node on a curve fillet (an arc
-- carries no lanes). Network-only, so it holds while the nav graph is still being rebuilt.
function RoadTurnPermissionStore.isLaneEditable(nodeId: Types.NodeId): boolean
	local node = _network:getNodes()[nodeId]
	if not node or #node.segments < 2 then
		return false
	end
	if _network.isRoundaboutNode and _network:isRoundaboutNode(nodeId) then
		return false
	end
	for _, sid in node.segments do
		local seg = _network:getSegment(sid)
		if not seg or seg.isArc then
			return false
		end
	end
	return true
end

-- A hand-wired node's rules name lanes by id. An edit that renumbers a node's lanes without
-- going through invalidate() would leave rules matching no lane -- and a hand-wired node with
-- no matching rule lets nobody through. Any such node goes back to automatic. Run after a nav
-- rebuild, against the graph just built; returns the nodes it reset.
function RoadTurnPermissionStore.dropStale(): { [Types.NodeId]: boolean }
	local reset: { [Types.NodeId]: boolean } = {}
	for nodeId, perms in _turnPermissions do
		if not perms.manual then
			continue
		end
		local fits = RoadTurnPermissionStore.isLaneEditable(nodeId) and _navGraph ~= nil
		if fits then
			for key in perms.connectionRules or {} do
				local from, to = string.match(key, "^([^>]+)>([^>]+)$")
				local a = from and _navGraph:GetEdge(from)
				local b = to and _navGraph:GetEdge(to)
				if not a or not b or a.toNode ~= nodeId or b.fromNode ~= nodeId then
					fits = false
					break
				end
			end
		end
		if not fits then
			_turnPermissions[nodeId] = nil
			reset[nodeId] = true
		end
	end
	return reset
end

-- ---- Editing API (moved verbatim from RoadService) ---------------------------

function RoadTurnPermissionStore.setTurnPermission(nodeId: Types.NodeId, movement: string, enabled: boolean): boolean
	if not TURN_KEYS[movement] then
		return false
	end
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" then
		return false
	end
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms[movement] = enabled
	_scheduleNavRebuild(nodeId, nil, true)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.setLaneTurnPermission(nodeId: Types.NodeId, incomingEdgeId: string, movement: string, enabled: boolean): boolean
	if not TURN_KEYS[movement] then
		return false
	end
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" or not _navGraph then
		return false
	end
	local edge = _navGraph:GetEdge(incomingEdgeId)
	if not edge or edge.toNode ~= nodeId then
		return false
	end
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.laneRules = perms.laneRules or {}
	local rule = perms.laneRules[incomingEdgeId]
	if not rule then
		rule = {}
		perms.laneRules[incomingEdgeId] = rule
	end
	rule[movement] = enabled
	_scheduleNavRebuild(nodeId)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.setConnectionHandle(nodeId: Types.NodeId, fromEdgeId: string, toEdgeId: string, handle: Vector3): boolean
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" or not _navGraph then
		return false
	end
	local fromEdge = _navGraph:GetEdge(fromEdgeId)
	local toEdge = _navGraph:GetEdge(toEdgeId)
	if not fromEdge or not toEdge or fromEdge.toNode ~= nodeId or toEdge.fromNode ~= nodeId then
		return false
	end
	local flatHandle = Vector3.new(handle.X, node.position.Y, handle.Z)
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.customConnections = perms.customConnections or {}
	perms.customConnections[`{fromEdgeId}>{toEdgeId}`] = { handles = { flatHandle } }
	_scheduleNavRebuild(nodeId)
	return true
end

local function ensureManual(nodeId: Types.NodeId)
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	if perms.manual then
		return
	end
	perms.connectionRules = perms.connectionRules or {}
	if _navGraph then
		for _, conn in _navGraph:GetIntersectionConnectionData(nodeId) do
			if conn.allowed then
				perms.connectionRules[conn.key] = true
			end
		end
	end
	perms.manual = true
end

function RoadTurnPermissionStore.setConnection(nodeId: Types.NodeId, fromEdgeId: string, toEdgeId: string, connected: boolean): boolean
	if not RoadTurnPermissionStore.isLaneEditable(nodeId) or not _navGraph then
		return false
	end
	local fromEdge = _navGraph:GetEdge(fromEdgeId)
	local toEdge = _navGraph:GetEdge(toEdgeId)
	if not fromEdge or not toEdge or fromEdge.toNode ~= nodeId or toEdge.fromNode ~= nodeId then
		return false
	end
	ensureManual(nodeId)
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.connectionRules = perms.connectionRules or {}
	perms.connectionRules[`{fromEdgeId}>{toEdgeId}`] = if connected then true else nil
	_scheduleNavRebuild(nodeId)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.resetConnections(nodeId: Types.NodeId): boolean
	if not _network:getNodes()[nodeId] then
		return false
	end
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.manual = nil
	perms.connectionRules = {}
	perms.customConnections = {}
	_scheduleNavRebuild(nodeId)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.setLaneChangeConnection(gateId: string, fromEdgeId: string, toEdgeId: string, connected: boolean)
	if not _navGraph or not _navGraph:HasLaneChangeConnection(gateId, fromEdgeId, toEdgeId) then
		return
	end
	local ruleKey = _navGraph:LaneChangeRuleKey(gateId, fromEdgeId, toEdgeId)
	_laneChangeRules[ruleKey] = connected
	_scheduleNavRebuild()
end

-- ---- Persistence --------------------------------------------------------------
-- Hand-wired junctions are player-authored, so they ride the city save. Node ids regenerate
-- on load, so a junction is anchored by POSITION (as signal plans are); its rules stay keyed
-- by lane edge id ("S<seg>:L<lane>:<F|R>"), which survives because segment ids do.
local MAX_SAVED_JUNCTIONS = 4096
local MAX_RULES_PER_JUNCTION = 512
local ANCHOR_TOLERANCE = 2

function RoadTurnPermissionStore.serialize(): { any }
	local out: { any } = {}
	for nodeId, perms in _turnPermissions do
		local node = _network:getNodes()[nodeId]
		if not perms.manual or not node then continue end
		local keys: { string } = {}
		for key, on in perms.connectionRules or {} do
			if on == true then table.insert(keys, key) end
		end
		table.sort(keys)
		local p = node.position
		table.insert(out, { p = { p.X, p.Y, p.Z }, k = keys })
	end
	return out
end

-- The nodes an edge id leaves and arrives at: F runs the segment start->end, R end->start.
local function edgeEnds(edgeId: string): (Types.NodeId?, Types.NodeId?)
	local sid, dir = string.match(edgeId, "^S(%d+):L%d+:([FR])$")
	local seg = if sid then _network:getSegment(tonumber(sid) :: number) else nil
	if not seg then return nil, nil end
	if dir == "F" then return seg.startNode, seg.endNode end
	return seg.endNode, seg.startNode
end

local function editableNodeAt(pos: Vector3): Types.NodeId?
	local best: Types.NodeId? = nil
	local bestDist = ANCHOR_TOLERANCE
	for nodeId, node in _network:getNodes() do
		local d = (node.position - pos).Magnitude
		if d < bestDist and RoadTurnPermissionStore.isLaneEditable(nodeId) then
			best, bestDist = nodeId, d
		end
	end
	return best
end

-- Untrusted blob: every rule must name a lane that really arrives at, and one that really
-- leaves, the junction it was saved against. One rule that does not fit means the junction
-- is not the one that was saved, so it stays automatic -- half a rule set could leave a
-- lane with no way out.
function RoadTurnPermissionStore.restore(entries: any)
	if typeof(entries) ~= "table" then return end
	for i, e in entries do
		if i > MAX_SAVED_JUNCTIONS then break end
		local p = if typeof(e) == "table" then e.p else nil
		if typeof(p) ~= "table" or typeof(p[1]) ~= "number" or typeof(p[2]) ~= "number" or typeof(p[3]) ~= "number" then continue end
		local pos = Vector3.new(p[1], p[2], p[3])
		if pos ~= pos then continue end
		local nodeId = editableNodeAt(pos)
		if not nodeId then continue end
		local keys = if typeof(e.k) == "table" then e.k else {}
		if #keys > MAX_RULES_PER_JUNCTION then continue end
		local rules: { [string]: boolean } = {}
		local fits = true
		for _, key in keys do
			local from, to = string.match(if typeof(key) == "string" then key else "", "^([^>]+)>([^>]+)$")
			local _, arrives = edgeEnds(from or "")
			local leaves = edgeEnds(to or "")
			if arrives ~= nodeId or leaves ~= nodeId then
				fits = false
				break
			end
			rules[key] = true
		end
		if not fits then continue end
		local perms = RoadTurnPermissionStore.getOrInit(nodeId)
		perms.manual = true
		perms.connectionRules = rules
		-- Per node, so the rebuild repaints this junction's lane arrows too.
		_scheduleNavRebuild(nodeId, nil, true)
		_broadcastTurnPermissions(nil, nodeId)
	end
end

return RoadTurnPermissionStore
