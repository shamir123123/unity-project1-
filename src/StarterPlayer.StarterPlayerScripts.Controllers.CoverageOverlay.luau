--!strict
-- CoverageOverlay
-- ONE owner of the client-side coverage visuals.
-- Two styles:
--   "grey" -- placement tool: reach discs + uncovered buildings greyed out
--   "heat" -- heatmap view: no discs; buildings get a Citystate-style colour
--             wash (green = covered, red = not) that keeps each part's own
--             light/dark detail, and the baked road meshes are tinted to match.
-- Pure client-side recolour: server colours are untouched and restored on clear.
-- Shared by EmergencyPlacementController (grey) and HeatmapController (heat) so
-- the two can never fight over a building's saved colours.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local CoverageOverlay = {}

local REFRESH = 1.5
-- Repaint budget per frame: the city is tinted a slice at a time so toggling the
-- heatmap never stalls a frame, it sweeps in over a few frames instead.
local FRAME_BUDGET = 0.0015
-- Parts smaller than this (studs^3) are never tinted: trim, window frames, lane
-- markings. They carry most of the part count and almost none of the look.
local MIN_PART_VOLUME = 1.5
-- Short on purpose: a long crossfade leaves the map showing in-between colours
-- that aren't real data. Fade should read as polish, not as information.
local FADE_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local UNCOVERED_GREY = Color3.fromRGB(112, 114, 118)
local HEAT_COVERED   = Color3.fromRGB(150, 235, 190)
local HEAT_UNCOVERED = Color3.fromRGB(244, 96, 84)
local ROAD_NEUTRAL   = Color3.new(1, 1, 1) -- baked road meshes ship white

local RING_COLOR: { [string]: Color3 } = {
	Hospital  = Color3.fromRGB(214, 96, 92),
	Police    = Color3.fromRGB(86, 140, 210),
	Fire      = Color3.fromRGB(240, 150, 60),
	Deathcare = Color3.fromRGB(142, 168, 142),
	Education = Color3.fromRGB(170, 130, 220),
}
local RING_FALLBACK = Color3.fromRGB(120, 200, 140)

type Station = { pos: Vector3, radius: number }
type Style = "grey" | "heat"

local _kind: string? = nil
local _style: Style = "grey"
local _savedColors: { [Model]: { [BasePart]: Color3 } } = {}
local _origFlat: { [BasePart]: Color3 } = {} -- flat part->original for fast lookup
local _tintApplied: { [Model]: string } = {} -- model -> applied tint tag (skip redundant repaints)

type Job = { tag: string, color: Color3?, wash: boolean }
local _pending: { [Model]: Job } = {}
local _pendingCount = 0
local _pumpConn: RBXScriptConnection? = nil
local _rings: { BasePart } = {}
local _nextRefreshAt = 0

local function cityFolder(name: string): Folder?
	local city = Workspace:FindFirstChild("_City")
	local f = city and city:FindFirstChild(name)
	return if f and f:IsA("Folder") then f else nil
end

function CoverageOverlay.ringColor(kind: string): Color3
	return RING_COLOR[kind] or RING_FALLBACK
end

-- Flat translucent reach disc; caller positions it via CoverageOverlay.discTo.
function CoverageOverlay.makeDisc(radius: number, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.3, radius * 2, radius * 2)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Transparency = 0.8
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = UiScratch.folder("CoverageOverlay")
	return p
end

function CoverageOverlay.discTo(p: BasePart, pos: Vector3)
	p.CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

-- Placed same-kind service buildings, read off the replicated models' attributes.
-- "Education" reads the Schools folder; everything else EmergencyServices by kind.
-- ponytail: base radius only -- the server widens reach with funding, not mirrored here.
-- Where a model MEETS THE GROUND, not where its pivot is. A model's pivot sits at its
-- bounding-box centre, so a disc drawn off it floats at mid-wall.
local function groundOf(m: Model): Vector3
	local cf, size = m:GetBoundingBox()
	local p = cf.Position
	return Vector3.new(p.X, p.Y - size.Y * 0.5, p.Z)
end

local function stations(kind: string): { Station }
	local out: { Station } = {}
	local folder = if kind == "Education" then cityFolder("Schools") else cityFolder("EmergencyServices")
	if folder then
		for _, m in folder:GetChildren() do
			if not m:IsA("Model") then continue end
			if kind ~= "Education" and m:GetAttribute("ServiceKind") ~= kind then continue end
			local r = tonumber(m:GetAttribute("CoverageRadius")) or 0
			if r > 0 then table.insert(out, { pos = groundOf(m), radius = r }) end
		end
	end
	return out
end

local function fadeColor(p: BasePart, c: Color3)
	if p.Color == c then return end -- already correct: never re-fade
	TweenService:Create(p, FADE_INFO, { Color = c }):Play()
end

-- Citystate-style wash: keep the part's own light/dark detail, swap its hue.
local function washColor(tint: Color3, original: Color3): Color3
	local l = 0.45 + 0.55 * (0.299 * original.R + 0.587 * original.G + 0.114 * original.B)
	return Color3.new(tint.R * l, tint.G * l, tint.B * l)
end

local function coveredAt(list: { Station }, pos: Vector3): boolean
	for _, s in list do
		local dx, dz = s.pos.X - pos.X, s.pos.Z - pos.Z
		if dx * dx + dz * dz <= s.radius * s.radius then return true end
	end
	return false
end

-- RoadMeshView bakes each road piece to one white MeshPart with vertex colours,
-- so Color is a free whole-piece tint. nil list restores neutral.
local function tintRoads(list: { Station }?)
	local meshes = Workspace:FindFirstChild("_RoadMeshes")
	if not meshes then return end
	for _, mp in meshes:GetChildren() do
		if not mp:IsA("MeshPart") then continue end
		fadeColor(mp, if list then (if coveredAt(list, mp.Position) then HEAT_COVERED else HEAT_UNCOVERED) else ROAD_NEUTRAL)
	end
end

local function restoreModel(model: Model)
	local saved = _savedColors[model]
	_tintApplied[model] = nil
	if not saved then return end
	_savedColors[model] = nil
	for part, color in saved do
		_origFlat[part] = nil
		if part.Parent then fadeColor(part, color) end
	end
end

local function applyJob(model: Model, job: Job)
	local color = job.color
	if color == nil then
		restoreModel(model)
		return
	end
	local saved = _savedColors[model]
	if not saved then
		saved = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Size.X * d.Size.Y * d.Size.Z >= MIN_PART_VOLUME then
				saved[d] = d.Color
				_origFlat[d] = d.Color
			end
		end
		_savedColors[model] = saved
	end
	for part, orig in saved :: { [BasePart]: Color3 } do
		if part.Parent then
			fadeColor(part, if job.wash then washColor(color, orig) else color)
		end
	end
	_tintApplied[model] = job.tag
end

local function pump()
	local deadline = os.clock() + FRAME_BUDGET
	repeat
		local model, job = next(_pending)
		if model == nil or job == nil then break end
		_pending[model] = nil
		_pendingCount -= 1
		if model.Parent then applyJob(model, job) end
	until os.clock() >= deadline
	if next(_pending) == nil then
		_pendingCount = 0
		local conn = _pumpConn
		if conn then conn:Disconnect(); _pumpConn = nil end
	end
end

local function ensurePump()
	if not _pumpConn then
		_pumpConn = RunService.Heartbeat:Connect(pump)
	end
end

-- Latest desired state per model; overwriting a pending job is free, so the
-- queue always converges on the newest refresh even mid-sweep.
local function queueTint(model: Model, tag: string, color: Color3?, wash: boolean)
	local pending = _pending[model]
	if color == nil and not _savedColors[model] then
		-- Nothing painted, nothing to restore: cancel any stale pending tint.
		if pending then _pending[model] = nil; _pendingCount -= 1 end
		return
	end
	if _tintApplied[model] == tag then
		if pending then _pending[model] = nil; _pendingCount -= 1 end
		return
	end
	if pending and pending.tag == tag then return end
	if not pending then _pendingCount += 1 end
	_pending[model] = { tag = tag, color = color, wash = wash }
	ensurePump()
end

function CoverageOverlay.refresh()
	local kind = _kind
	if not kind then return end
	local list = stations(kind)
	local ringColor = CoverageOverlay.ringColor(kind)

	for _, r in _rings do r:Destroy() end
	table.clear(_rings)
	if _style == "grey" then
		for _, s in list do
			local disc = CoverageOverlay.makeDisc(s.radius, ringColor)
			CoverageOverlay.discTo(disc, s.pos)
			table.insert(_rings, disc)
		end
	end

	local folder = cityFolder("ZonedBuildings")
	if folder then
		for _, m in folder:GetChildren() do
			if not m:IsA("Model") then continue end
			local covered = coveredAt(list, m:GetPivot().Position)
			if _style == "grey" then
				queueTint(m, if covered then "none" else "grey", if covered then nil else UNCOVERED_GREY, false)
			else
				queueTint(m, if covered then "hot" else "cold", if covered then HEAT_COVERED else HEAT_UNCOVERED, true)
			end
		end
	end

	tintRoads(if _style == "heat" then list else nil)

	-- Pieces whose mesh bake failed stay part-rendered; tint the source models too.
	-- (For baked pieces the source parts are locally hidden, so this is invisible.)
	if _style == "heat" then
		local roads = cityFolder("Roads")
		if roads then
			local meshes = Workspace:FindFirstChild("_RoadMeshes")
			for _, m in roads:GetChildren() do
				if not m:IsA("Model") then continue end
				-- Baked pieces render via the mesh; their source parts are locally
				-- invisible, so tinting them would be pure wasted work.
				if meshes and meshes:FindFirstChild(m.Name .. "_Mesh") then continue end
				local covered = coveredAt(list, m:GetPivot().Position)
				queueTint(m, if covered then "hot" else "cold", if covered then HEAT_COVERED else HEAT_UNCOVERED, true)
			end
		end
	end

	-- Drop saved entries for buildings demolished while tinted.
	for model, saved in _savedColors do
		if not model.Parent then
			for part in saved do _origFlat[part] = nil end
			_savedColors[model] = nil
			_tintApplied[model] = nil
		end
	end
end

-- Cheap per-frame hook: re-scans on a slow timer while active.
function CoverageOverlay.maybeRefresh()
	if not _kind then return end
	if os.clock() < _nextRefreshAt then return end
	_nextRefreshAt = os.clock() + REFRESH
	CoverageOverlay.refresh()
end

function CoverageOverlay.show(kind: string, style: Style)
	if _kind == kind and _style == style then return end
	_kind = kind
	_style = style
	-- Queue a restore for everything painted; refresh() immediately overwrites the
	-- jobs for models the new mode still tints, so each part repaints at most once.
	for model in _savedColors do queueTint(model, "none", nil, false) end
	_nextRefreshAt = os.clock() + REFRESH
	CoverageOverlay.refresh()
end

function CoverageOverlay.clear()
	if not _kind then return end
	_kind = nil
	table.clear(_pending)
	_pendingCount = 0
	for model in _savedColors do queueTint(model, "none", nil, false) end
	for _, r in _rings do r:Destroy() end
	table.clear(_rings)
	tintRoads(nil)
end

-- True colour of a part while an overlay tint may be applied. RoadMeshView bakes
-- from this so a heat-tinted road never gets frozen into a mesh's vertex colours.
function CoverageOverlay.originalColor(p: BasePart): Color3
	return _origFlat[p] or p.Color
end

function CoverageOverlay.activeKind(): string?
	return _kind
end

function CoverageOverlay.activeStyle(): string
	return _style
end

return CoverageOverlay
