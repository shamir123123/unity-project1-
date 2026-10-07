--!strict
-- RoadDeadEndService
-- Marks the road ends traffic gets stuck at, for the dead-end pin (NoPowerView). A road end
-- with nothing joined to it is fine on a street -- its bulb is a turnaround -- but on a
-- ONE-WAY road or ANY highway (no turning round on a motorway) it is a trap: cars drive in
-- and are stuck, or the road can never be driven onto at all. Each such end gets one
-- invisible marker in _City.RoadWarnings, attribute DeadEnd = true. Rebuilt off the road
-- graph on every topology change, so a road joined up later clears its own pin.
-- A road joined to others can be just as stuck: one drawn the wrong way (a one-way laid on a lane
-- running against it) is built like the right-way road but nothing can drive it -- its pin stands
-- on that road beside the node (RoadJunctionSolver.stuckArms; user, 2026-10-07).
--
-- Owns only those markers; the roads stay RoadService's.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadJunctionSolver = require(ReplicatedStorage.Road.RoadJunctionSolver)

local RoadDeadEndService = {}

local MARKER_HEIGHT = 8 -- studs; the pin stands on top of it, clear of the carriageway

local _roadService: any = nil
local _markers: { [string]: Model } = {} -- "node" / "node:segment" -> marker

local function folder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then
		city = Instance.new("Folder")
		city.Name = "_City"
		city.Parent = Workspace
	end
	local f = city:FindFirstChild("RoadWarnings")
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = "RoadWarnings"
		f.Parent = city
	end
	return f :: Folder
end

local function marker(pos: Vector3): Model
	local m = Instance.new("Model")
	m.Name = "DeadEnd"
	local p = Instance.new("Part")
	p.Name = "Anchor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(1, MARKER_HEIGHT, 1)
	p.Position = pos + Vector3.new(0, MARKER_HEIGHT * 0.5, 0)
	p.Parent = m
	m.PrimaryPart = p
	m:SetAttribute("DeadEnd", true)
	return m
end

-- The places that need a pin: a node with exactly one road, where that road is one-way or a
-- highway (rail is not traffic); and a one-way road stuck where it meets others.
local function stuckEnds(): { [string]: Vector3 }
	local out: { [string]: Vector3 } = {}
	local net = _roadService.getNetwork()
	local segs = net:getSegments()
	for nodeId, node in net:getNodes() do
		if #node.segments == 1 then
			local seg = segs[node.segments[1]]
			if not seg then continue end
			local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
			if (spec.oneWay or spec.isHighway) and not spec.isRail then out[tostring(nodeId)] = node.position end
			continue
		end
		local oneWay = false
		for _, sid in node.segments do
			local seg = segs[sid]
			if seg and RoadTypeCatalog.getOrDefault(seg.roadType).oneWay then oneWay = true end
		end
		if not oneWay then continue end
		for sid, pos in RoadJunctionSolver.stuckAt(net, nodeId) do
			out[nodeId .. ":" .. sid] = pos
		end
	end
	return out
end

function RoadDeadEndService.sync()
	local want = stuckEnds()
	for key, m in _markers do
		local pos = want[key]
		if not pos or not m.Parent then
			m:Destroy()
			_markers[key] = nil
		elseif (m:GetPivot().Position - pos).Magnitude > 0.5 then
			m:PivotTo(CFrame.new(pos + Vector3.new(0, MARKER_HEIGHT * 0.5, 0)))
		end
	end
	local f: Folder? = nil
	for key, pos in want do
		if _markers[key] then continue end
		f = f or folder()
		local m = marker(pos)
		m.Parent = f
		_markers[key] = m
	end
end

function RoadDeadEndService.Init(roadService: any)
	assert(roadService, "[RoadDeadEndService] missing roadService")
	_roadService = roadService
end

function RoadDeadEndService.Bind()
	_roadService.onTopologyChanged(function()
		RoadDeadEndService.sync()
	end)
end

return RoadDeadEndService
