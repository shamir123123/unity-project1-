--!strict
-- TransitClient
-- The client's mirror of the public-transit state. Receives the SyncTransit snapshot
-- (depots / stops / routes + live line stats), draws each route as a ribbon along the lanes its
-- buses drive, the stops as pins, and the route tool's hints; hands the snapshot to the placement
-- tool and the Transportation Overview panel. Buses themselves are smoothed for free by
-- NPCDriverView (they carry the "NPCDriver" tag), so this is lines + data only.
--
-- Lines are drawn the way the road tool draws its preview (RoadGhostPreviewController bm*): flat
-- Beams, each piece bounded by the averaged normal at its two ends so pieces share their corner
-- points -- no gap or overlap at a bend. Nothing moves per frame: a line is rebuilt only when it
-- changes.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local UiScratch = require(script.Parent:WaitForChild("UiScratch"))

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local Icons = require(uiFolder:WaitForChild("Icons"))

local TransitClient = {}

local LINE_LIFT = 0.9            -- over the lane points (the road slab's middle): clears the asphalt + paint
local LINE_WIDTH = 3.2
local LINE_WIDTH_ACTIVE = 4.0
local LINE_TRANS = 0.12
local LINE_SIMPLIFY = 0.2        -- studs a simplified line may stray from the lane polyline
local PREVIEW_TRANS = 0.3
local TRANSIT_COLOR = Color3.fromRGB(20, 170, 176) -- the stop pins and the tool's accents
local CHIP_BG = Color3.fromRGB(22, 26, 34)
local WHITE = Color3.fromRGB(255, 255, 255)
local UP = Vector3.yAxis

local _snapshot: any = { depots = {}, stops = {}, routes = {}, allowance = 0, assigned = 0 }
local _listeners: { (any) -> () } = {}
local _started = false
local _activeRouteId: number? = nil
local _lineFolders: { [number]: Folder } = {}
local _lineSig: { [number]: string } = {}
-- Route lines + stop markers only show while transit mode is active (the tools are open
-- or the overview panel is open). Ref-counted so either reason keeps them visible.
local _modeRefs: { [string]: boolean } = {}
local _active = false
local _markers: { [number]: Instance } = {}
local _markerSig = "" -- what the current markers were built from; skips no-op rebuilds
local _routeStopRings: { [number]: Part } = {}
-- The selected line's own road points (drag to move, right-click to remove) and the preview
-- ribbon the route tool draws (a line being drawn out to the cursor, a drag reshaping a leg).
local _pointHandles: { Instance } = {}
local _preview: Part? = nil
local _previewSig = ""
local _hintAnchor: Part? = nil
local _hintBillboard: BillboardGui? = nil
local _hintDot: Part? = nil
local _hintStopId: number? = nil
local _hintPos: Vector3? = nil
local _hintPrimary: string? = nil
local _hintAction: string? = nil
local _hintSecondary: string? = nil
local _hintSig = "" -- what the hint chips say: the tool asks every frame, only a change rebuilds them
local _stopClickHandler: ((number) -> ())? = nil
local _statusGui: ScreenGui? = nil
local _statusFrame: Frame? = nil
local _statusPrimary: TextLabel? = nil
local _statusSecondary: TextLabel? = nil
local _statusStroke: UIStroke? = nil

local function lineRoot(): Folder
	return UiScratch.folder("TransitLines")
end

local function hintRoot(): Folder
	return UiScratch.folder("TransitRouteHints")
end

-- == Ribbons (flat Beams) =======================================================
-- Fewer, longer pieces where the lane runs straight (Douglas-Peucker, in 3D so a hill keeps its
-- shape).
local function simplify(pts: { Vector3 }, tol: number): { Vector3 }
	local n = #pts
	if n <= 2 then return pts end
	local keep: { boolean } = table.create(n, false)
	keep[1], keep[n] = true, true
	local stack = { 1, n }
	while #stack > 0 do
		local j = table.remove(stack) :: number
		local i = table.remove(stack) :: number
		local a, b = pts[i], pts[j]
		local ab = b - a
		local len2 = ab:Dot(ab)
		local worst, at = 0, 0
		for k = i + 1, j - 1 do
			local ap = pts[k] - a
			local d = if len2 < 1e-9 then ap.Magnitude else (ap - ab * math.clamp(ap:Dot(ab) / len2, 0, 1)).Magnitude
			if d > worst then worst, at = d, k end
		end
		if worst > tol then
			keep[at] = true
			table.insert(stack, i); table.insert(stack, at)
			table.insert(stack, at); table.insert(stack, j)
		end
	end
	local out = {}
	for k = 1, n do
		if keep[k] then table.insert(out, pts[k]) end
	end
	return out
end

-- A ribbon of flat beams through `pts` on `anchor` (attachments are relative to it).
local function ribbon(anchor: BasePart, pts: { Vector3 }, color: Color3, width: number, trans: number)
	local n = #pts
	if n < 2 then return end
	local nrm: { Vector3 } = table.create(n)
	for i = 1, n do
		local a, b = pts[math.max(i - 1, 1)], pts[math.min(i + 1, n)]
		local d = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		nrm[i] = if d.Magnitude > 1e-4 then Vector3.new(-d.Z, 0, d.X).Unit else (nrm[i - 1] or Vector3.xAxis)
	end
	local seq, tr = ColorSequence.new(color), NumberSequence.new(trans)
	for i = 1, n - 1 do
		local A, B = pts[i], pts[i + 1]
		if (B - A).Magnitude < 0.05 then continue end
		local a0 = Instance.new("Attachment")
		a0.CFrame = CFrame.fromMatrix(A, UP:Cross(nrm[i]).Unit, nrm[i])
		a0.Parent = anchor
		local a1 = Instance.new("Attachment")
		a1.CFrame = CFrame.fromMatrix(B, UP:Cross(nrm[i + 1]).Unit, nrm[i + 1])
		a1.Parent = anchor
		local bm = Instance.new("Beam")
		bm.Attachment0 = a0
		bm.Attachment1 = a1
		bm.FaceCamera = false
		bm.Segments = 1
		bm.CurveSize0 = 0
		bm.CurveSize1 = 0
		bm.Width0 = width
		bm.Width1 = width
		bm.Color = seq
		bm.Transparency = tr
		bm.LightInfluence = 0
		bm.LightEmission = 0.2
		bm.Texture = ""
		bm.Parent = anchor
	end
end

local function beamAnchor(name: string, lift: number, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.new(0.05, 0.05, 0.05)
	p.Transparency = 1
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
	p.CFrame = CFrame.new(0, lift, 0)
	p.Parent = parent
	return p
end

-- == Route lines ================================================================
local function routeSig(route: any): string
	local path = route.path or {}
	local first = path[1]
	local last = path[#path]
	local color = route.color or TRANSIT_COLOR
	return string.format("%d|%d|%s|%s|%d|%s", #path,
		math.floor((route.length or 0) + 0.5),
		if first then string.format("%.0f,%.0f", first.X, first.Z) else "-",
		if last then string.format("%.0f,%.0f", last.X, last.Z) else "-",
		if _activeRouteId == route.id then 1 else 0, color:ToHex())
end

-- Each line on the lanes its buses drive (both directions of a street show as their own band); the
-- selected one wider, opaque and a hair higher so it draws over the rest.
local function buildRouteLine(route: any)
	local folder = _lineFolders[route.id]
	if folder then
		folder:ClearAllChildren()
	else
		folder = Instance.new("Folder"); folder.Name = "Route_" .. route.id; folder.Parent = lineRoot()
		_lineFolders[route.id] = folder
	end
	local path = route.path or {}
	if #path < 2 then return end
	local active = _activeRouteId == route.id
	local anchor = beamAnchor("Line", LINE_LIFT + (if active then 0.06 else 0), folder :: Folder)
	ribbon(anchor, simplify(path, LINE_SIMPLIFY), route.color or TRANSIT_COLOR,
		if active then LINE_WIDTH_ACTIVE else LINE_WIDTH, if active then 0 else LINE_TRANS)
end

local function rebuildLines()
	local seen: { [number]: boolean } = {}
	for _, route in _snapshot.routes do
		seen[route.id] = true
		local sig = routeSig(route)
		if _lineSig[route.id] ~= sig then
			_lineSig[route.id] = sig
			buildRouteLine(route)
		end
	end
	for id, folder in _lineFolders do
		if not seen[id] then
			folder:Destroy(); _lineFolders[id] = nil; _lineSig[id] = nil
		end
	end
end

-- == Route status bar ===========================================================
local function ensureStatusGui(): Frame?
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	if _statusFrame and _statusFrame.Parent then return _statusFrame end

	local gui = playerGui:FindFirstChild("TransitRouteStatus")
	if not gui or not gui:IsA("ScreenGui") then
		if gui then gui:Destroy() end
		gui = Instance.new("ScreenGui")
		gui.Name = "TransitRouteStatus"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = Theme.Layer.CostTag + 4
		gui.Parent = playerGui
	end
	HudScale.attach(gui)
	_statusGui = gui

	local frame = Instance.new("Frame")
	frame.Name = "Status"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 68)
	frame.Size = UDim2.fromOffset(340, 44)
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui
	local stroke = Glass.apply(frame, Theme.Radius.MD)
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Transparency = Theme.Glass.StrokeTransparency
	stroke.Thickness = Theme.StrokeWidth.Thin

	local primary = Instance.new("TextLabel")
	primary.BackgroundTransparency = 1
	primary.Position = UDim2.fromOffset(14, 6)
	primary.Size = UDim2.new(1, -28, 0, 18)
	primary.TextColor3 = Theme.Color.TextPrimary
	primary.TextSize = Theme.TextSize.SM
	primary.TextXAlignment = Enum.TextXAlignment.Left
	primary.TextTruncate = Enum.TextTruncate.AtEnd
	primary.FontFace = Theme.Font.Bold
	primary.Parent = frame

	local secondary = Instance.new("TextLabel")
	secondary.BackgroundTransparency = 1
	secondary.Position = UDim2.fromOffset(14, 24)
	secondary.Size = UDim2.new(1, -28, 0, 14)
	secondary.TextColor3 = Theme.Color.TextSecondary
	secondary.TextSize = Theme.TextSize.XS
	secondary.TextXAlignment = Enum.TextXAlignment.Left
	secondary.TextTruncate = Enum.TextTruncate.AtEnd
	secondary.FontFace = Theme.Font.Label
	secondary.Parent = frame

	_statusFrame = frame
	_statusPrimary = primary
	_statusSecondary = secondary
	_statusStroke = stroke
	return frame
end

local function hideStatusGui()
	if _statusFrame then _statusFrame.Visible = false end
end

-- == Stop pins ==================================================================
local function markerRoot(): Folder
	return UiScratch.folder("TransitStopMarkers")
end

local function iconImage(parent: Instance, name: string, size: number, pos: UDim2?): ImageLabel
	local ic = Icons.get(name)
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = pos or UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromOffset(size, size)
	img.Image = if ic then ic.image else ""
	img.ImageColor3 = WHITE
	img.Parent = parent
	return img
end

-- A screen-sized round dot at a world point (waypoints, the cursor on the road).
local function dotAt(parent: Instance, pos: Vector3, fill: Color3, size: number, ring: boolean): Part
	local p = Instance.new("Part")
	p.Name = "Dot"
	p.Size = Vector3.new(0.05, 0.05, 0.05)
	p.Transparency = 1
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
	p.CFrame = CFrame.new(pos + Vector3.new(0, LINE_LIFT + 0.2, 0))
	p.Parent = parent
	local g = Instance.new("BillboardGui")
	g.Size = UDim2.fromOffset(size, size)
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.MaxDistance = 900
	g.Adornee = p
	g.Parent = p
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = fill
	f.BorderSizePixel = 0
	f.Parent = g
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = f
	if ring then
		local s = Instance.new("UIStroke")
		s.Color = WHITE
		s.Thickness = 2
		s.Parent = f
	end
	return p
end

-- A stop: a teal map pin with the bus sign, its point on the stop (the name shows on hover).
local PIN_W, PIN_H = 38, 45
local function makeMarker(stop: any): Instance
	local anchor = Instance.new("Part")
	anchor.Name = "StopMarkerAnchor_" .. tostring(stop.id)
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false; anchor.CanTouch = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(stop.pos + Vector3.new(0, 1.5, 0))
	anchor.Parent = markerRoot()

	local bb = Instance.new("BillboardGui")
	bb.Adornee = anchor
	bb.Size = UDim2.fromOffset(PIN_W, PIN_H)
	bb.SizeOffset = Vector2.new(0, 0.5) -- the pin's point on the stop, not its middle
	bb.AlwaysOnTop = true
	bb.Active = true
	bb.LightInfluence = 0
	bb.MaxDistance = 850
	bb.Parent = anchor

	local pin = Instance.new("ImageLabel")
	pin.BackgroundTransparency = 1
	pin.Size = UDim2.fromScale(1, 1)
	local pinIcon = Icons.get("StopPin")
	pin.Image = if pinIcon then pinIcon.image else ""
	pin.ImageColor3 = TRANSIT_COLOR
	pin.Parent = bb
	iconImage(pin, "BusSolid", 20, UDim2.new(0.5, 0, 0, PIN_W * 0.5))

	local click = Instance.new("TextButton")
	click.Name = "StopMarkerClickTarget"
	click.BackgroundTransparency = 1
	click.BorderSizePixel = 0
	click.Text = ""
	click.AutoButtonColor = false
	click.Active = true
	click.Size = UDim2.fromScale(1, 1)
	click.ZIndex = 50
	click.Parent = bb
	click.Activated:Connect(function()
		if _stopClickHandler then
			_stopClickHandler(stop.id)
		end
	end)

	return anchor
end

local function clearMarkers()
	UiScratch.clear("TransitStopMarkers")
	table.clear(_markers)
	_markerSig = ""
end

-- Markers only actually change when a stop is added/removed/moved, but snapshots arrive every
-- ~1.5s while routes exist: skip when nothing marker-visible changed.
local function rebuildMarkers()
	local parts = table.create(#_snapshot.stops)
	for _, stop in _snapshot.stops do
		parts[#parts + 1] = string.format("%d:%.0f,%.0f", stop.id, stop.pos.X, stop.pos.Z)
	end
	local sig = table.concat(parts, "|")
	if sig == _markerSig then return end
	clearMarkers()
	_markerSig = sig
	for _, stop in _snapshot.stops do
		_markers[stop.id] = makeMarker(stop)
	end
end

local function stopById(id: number?): any?
	if not id then return nil end
	for _, stop in _snapshot.stops do
		if stop.id == id then return stop end
	end
	return nil
end

local function activeRoute(): any?
	if not _activeRouteId then return nil end
	for _, route in _snapshot.routes do
		if route.id == _activeRouteId then return route end
	end
	return nil
end

-- == The selected line: its stops ringed, its road points as dots ==============
local function clearRouteStopRings()
	for id, ring in _routeStopRings do
		if ring.Parent then ring:Destroy() end
		_routeStopRings[id] = nil
	end
	for _, h in _pointHandles do h:Destroy() end
	table.clear(_pointHandles)
end

local function makeRouteStopRing(stop: any, color: Color3, isFirst: boolean): Part
	local ring = Instance.new("Part")
	ring.Name = "SelectedRouteStop_" .. tostring(stop.id)
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Material = Enum.Material.SmoothPlastic
	ring.Color = if isFirst then WHITE else color
	ring.Transparency = 0.25
	ring.Size = Vector3.new(0.12, 7, 7)
	ring.CFrame = CFrame.new(stop.pos.X, stop.pos.Y + 0.22, stop.pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = hintRoot()
	return ring
end

local function rebuildRouteStopRings()
	clearRouteStopRings()
	if not _active or _modeRefs.tools ~= true then return end
	local route = activeRoute()
	if not route or typeof(route.stops) ~= "table" then return end
	local color = route.color or TRANSIT_COLOR
	local seen: { [number]: boolean } = {}
	for i, stopId in route.stops do
		if typeof(stopId) == "number" and not seen[stopId] then
			local stop = stopById(stopId)
			if stop then
				_routeStopRings[stopId] = makeRouteStopRing(stop, color, i == 1)
				seen[stopId] = true
			end
		end
	end
	for _, pt in route.points or {} do
		table.insert(_pointHandles, dotAt(hintRoot(), pt.pos, color, 15, true))
	end
end

-- == Hover hints: dark chips over the cursor, a white dot where it meets the road ==
local function clearHint()
	_hintSig = ""
	if _hintAnchor then _hintAnchor:Destroy(); _hintAnchor = nil end
	_hintBillboard = nil
	if _hintDot then _hintDot:Destroy(); _hintDot = nil end
end

local function makePromptCard(parent: Instance, order: number, iconName: string, text: string)
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(0, 24)
	card.AutomaticSize = Enum.AutomaticSize.X
	card.BackgroundColor3 = CHIP_BG
	card.BackgroundTransparency = 0.06
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = card
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 9)
	pad.Parent = card
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 6)
	row.Parent = card
	local iconBox = Instance.new("Frame")
	iconBox.BackgroundTransparency = 1
	iconBox.Size = UDim2.fromOffset(16, 16)
	iconBox.LayoutOrder = 1
	iconBox.Parent = card
	local img = iconImage(iconBox, iconName, 14)
	if iconName == "BusSolid" then img.ImageColor3 = TRANSIT_COLOR end
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(0, 24)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.LayoutOrder = 2
	label.Text = text
	label.TextColor3 = WHITE
	label.TextSize = 13
	label.FontFace = Theme.Font.Bold
	label.Parent = card
end

local function rebuildRouteHint()
	clearHint()
	if not _active or (not _hintStopId and not _hintPos) then return end
	local stop = stopById(_hintStopId)
	local pos = if stop then stop.pos else _hintPos
	if not pos then return end
	-- "" = no title chip (a plain road point: just the actions)
	local primary = _hintPrimary
	if primary == nil then
		primary = if stop then tostring(stop.name or "Bus Stop") else ""
	end
	local action = _hintAction
	local secondary = _hintSecondary

	if not stop then _hintDot = dotAt(hintRoot(), pos, WHITE, 14, false) end

	local anchor = Instance.new("Part")
	anchor.Name = "RouteHintAnchor"
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanTouch = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(pos + Vector3.new(0, LINE_LIFT, 0))
	anchor.Parent = hintRoot()
	_hintAnchor = anchor

	local rows = (if primary ~= "" then 1 else 0) + (if action then 1 else 0) + (if secondary then 1 else 0)
	local bb = Instance.new("BillboardGui")
	bb.Adornee = anchor
	bb.Size = UDim2.fromOffset(260, math.max(1, rows) * 28)
	-- down and to the right of the point, like a cursor tooltip
	bb.SizeOffset = Vector2.new(0.5 + 16 / 260, -0.5 - 10 / (math.max(1, rows) * 28))
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 900
	bb.Parent = anchor
	_hintBillboard = bb

	local stack = Instance.new("Frame")
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.fromScale(1, 1)
	stack.Parent = bb
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = stack

	if primary ~= "" then
		makePromptCard(stack, 1, if stop then "BusSolid" else "Drag", primary)
	end
	if action then
		makePromptCard(stack, 2, if string.find(action, "^Drag") or string.find(action, "^Move") then "Drag" else "MouseLeft", action)
	end
	if secondary then
		makePromptCard(stack, 3, "MouseRight", secondary)
	end
end

local function clearLines()
	for id, folder in _lineFolders do
		folder:Destroy(); _lineFolders[id] = nil; _lineSig[id] = nil
	end
end

local function clearPreview()
	if _preview then _preview:Destroy(); _preview = nil end
	_previewSig = ""
end

local function shouldShowLines(): boolean
	return _modeRefs.tools == true or _modeRefs.overview == true
end

local function refreshVisibility()
	if _active then
		if shouldShowLines() then
			rebuildLines()
		else
			clearLines()
		end
		rebuildMarkers()
		rebuildRouteStopRings()
		if _modeRefs.tools == true then
			rebuildRouteHint()
		else
			clearHint()
			clearPreview()
		end
	else
		clearLines()
		clearMarkers()
		clearRouteStopRings()
		clearHint()
		clearPreview()
		hideStatusGui()
	end
end

local function routeStatusColor(tone: string?): Color3
	if tone == "danger" then
		return Theme.Color.Danger
	elseif tone == "attention" then
		return Theme.Color.Brand
	end
	return Theme.Color.StrokeSoft
end

-- == Public ====================================================================
function TransitClient.getSnapshot(): any
	return _snapshot
end

function TransitClient.getActiveRouteData(): any?
	return activeRoute()
end

function TransitClient.setRouteStatus(primary: string?, secondary: string?, tone: string?)
	if not primary then
		hideStatusGui()
		return
	end
	local frame = ensureStatusGui()
	if not frame then return end
	frame.Visible = true
	if _statusPrimary then _statusPrimary.Text = primary end
	if _statusSecondary then _statusSecondary.Text = secondary or "" end
	if _statusStroke then _statusStroke.Color = routeStatusColor(tone) end
end

function TransitClient.onChanged(fn: (any) -> ()): () -> ()
	table.insert(_listeners, fn)
	return function()
		local i = table.find(_listeners, fn)
		if i then table.remove(_listeners, i) end
	end
end

-- The route currently being built / selected: its line draws wider and opaque.
function TransitClient.setActiveRoute(id: number?)
	if _activeRouteId == id then return end
	_activeRouteId = id
	if _active then refreshVisibility() end
end

-- Turn route overlays/stop markers on/off. Ref-counted: "tools" and "overview"
-- show full route lines; "bulldoze" shows markers only so stops can be targeted.
function TransitClient.setMode(reason: string, on: boolean)
	if on then _modeRefs[reason] = true else _modeRefs[reason] = nil end
	local active = next(_modeRefs) ~= nil
	if active ~= _active then
		_active = active
		refreshVisibility()
	elseif _active then
		refreshVisibility()
	end
end

function TransitClient.setStopClickHandler(fn: ((number) -> ())?)
	_stopClickHandler = fn
end

-- primaryText "" = no title chip; nil = the stop's name (or none on a road point).
function TransitClient.setRouteHint(stopId: number?, roadPos: Vector3?, primaryText: string?, actionText: string?, secondaryText: string?)
	_hintStopId = stopId
	_hintPos = roadPos
	_hintPrimary = primaryText
	_hintAction = actionText
	_hintSecondary = secondaryText
	if not (_active and _modeRefs.tools == true) then
		clearHint()
		_hintSig = ""
		return
	end
	-- The tool calls this every frame: same words -> just follow the cursor (no rebuild, no flicker).
	local sig = table.concat({ tostring(stopId), tostring(primaryText), tostring(actionText), tostring(secondaryText),
		if roadPos then "p" else "-" }, "|")
	if sig == _hintSig and _hintAnchor and _hintAnchor.Parent then
		local stop = stopById(stopId)
		local pos = if stop then stop.pos else roadPos
		if pos then
			_hintAnchor.CFrame = CFrame.new(pos + Vector3.new(0, LINE_LIFT, 0))
			if _hintDot then _hintDot.CFrame = CFrame.new(pos + Vector3.new(0, LINE_LIFT + 0.2, 0)) end
		end
		return
	end
	rebuildRouteHint() -- (clears the old one, signature included)
	_hintSig = sig
end

function TransitClient.getActiveRoute(): number?
	return _activeRouteId
end

-- Where a stop stands (its kerb point), or nil.
function TransitClient.getStopPos(stopId: number): Vector3?
	local s = stopById(stopId)
	return if s then s.pos else nil
end

-- The route tool's preview ribbon (a line being drawn out to the cursor, a leg being reshaped),
-- along the roads; nil hides it. Rebuilt only when the path itself changes.
function TransitClient.setDragPreview(points: { Vector3 }?, color: Color3?)
	if not points or #points < 2 then
		clearPreview()
		return
	end
	local first, last = points[1], points[#points]
	local sig = string.format("%d|%.1f,%.1f|%.1f,%.1f|%s", #points, first.X, first.Z, last.X, last.Z,
		(color or TRANSIT_COLOR):ToHex())
	if sig == _previewSig and _preview and _preview.Parent then return end
	clearPreview()
	_previewSig = sig
	local anchor = beamAnchor("RoutePreview", LINE_LIFT + 0.12, hintRoot())
	_preview = anchor
	ribbon(anchor, simplify(points, LINE_SIMPLIFY), color or TRANSIT_COLOR, LINE_WIDTH_ACTIVE, PREVIEW_TRANS)
end

-- Find the stop nearest to a world position (for the route tool's click test fallback).
function TransitClient.nearestStopId(pos: Vector3, maxDist: number): number?
	local best, bestD = nil, maxDist
	for _, s in _snapshot.stops do
		local d = (s.pos - pos).Magnitude
		if d < bestD then bestD = d; best = s.id end
	end
	return best
end

-- The stop whose pin is under a viewport point (the pin stands on its stop, head up).
function TransitClient.stopIdAtScreen(screenPos: Vector2, maxPixels: number?): number?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local limit = maxPixels or 72
	local best, bestD = nil, limit
	for _, s in _snapshot.stops do
		local vp, visible = cam:WorldToViewportPoint(s.pos + Vector3.new(0, 1.5, 0))
		if visible and vp.Z > 0 then
			local dx = math.abs(vp.X - screenPos.X)
			local dy = vp.Y - screenPos.Y -- the pin is above its point
			if dx <= PIN_W * 0.6 and dy >= -6 and dy <= PIN_H + 6 then
				local d = math.sqrt(dx * dx + (dy - PIN_H * 0.5) ^ 2)
				if d < bestD then bestD = d; best = s.id end
			end
		end
	end
	return best
end

function TransitClient.Start()
	if _started then return end
	_started = true
	Net.SyncTransit.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then return end
		_snapshot = snap
		if _active then pcall(refreshVisibility) end
		for _, fn in _listeners do task.spawn(fn, snap) end
	end)
end

return TransitClient
