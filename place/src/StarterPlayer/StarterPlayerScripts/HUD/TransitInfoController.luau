--!strict
-- TransitInfoController
-- Click a bus or a stop to see it. A bus shows what it is doing, its line, how full it is and the
-- depot that owns it (click the depot to fly there); a stop shows how many people wait there and
-- which lines call at it. Everything comes from what is already replicated -- the bus's attributes
-- (BusDispatchService stamps them) and the SyncTransit snapshot (TransitClient) -- so opening the
-- panel costs no network. Idle while a build tool owns the cursor, so it never steals a placement click.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)

local core = script.Parent.Parent:WaitForChild("Core")
local CursorRay = require(core:WaitForChild("CursorRay"))
local TransitClient = require(core:WaitForChild("TransitClient"))

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local IconButton = require(kit:WaitForChild("IconButton"))

local TransitInfoController = {}

local STOP_COLOR = Color3.fromRGB(20, 170, 176) -- TransitClient's stop pins
local IDLE_COLOR = Color3.fromRGB(120, 124, 116) -- a bus with no line
local WARN_COLOR = Color3.fromRGB(230, 170, 70)
local LINE_ROWS = 6 -- line rows a stop panel keeps ready; more show in the count only
local BUS_ATTRS = { BusStatus = true, LineId = true, DepotId = true, NextStopId = true, Passengers = true, Capacity = true }

local _started = false
local _open = false
local _kind: string? = nil -- "bus" | "stop"
local _model: Model? = nil
local _conns: { RBXScriptConnection } = {}
local _ownerPos: Vector3? = nil
local _hudGui: ScreenGui
local _bottomBar: any = nil
local _freeCam: any = nil
local _highlight: Highlight

local _panel: CanvasGroup
local _badge: Frame
local _title: TextLabel
local _subtitle: TextLabel
local _status: TextLabel
local _busBody: Frame
local _passValue: TextLabel
local _passFill: Frame
local _passNote: TextLabel
local _ridersValue: TextLabel
local _ownerBtn: TextButton
local _stopBody: Frame
local _waitValue: TextLabel
local _boardValue: TextLabel
local _linesHead: TextLabel
local _lineRows: { { row: Frame, bar: Frame, name: TextLabel, info: TextLabel } } = {}

local function commaInt(n: number): string
	local s = tostring(math.abs(math.floor(n + 0.5)))
	local out = ""
	while #s > 3 do out = "," .. s:sub(#s - 2) .. out; s = s:sub(1, #s - 3) end
	return s .. out
end

-- Monthly figures are rough by nature: two significant figures past 100 ("~1,200").
local function roughly(n: number): string
	n = math.max(0, math.floor(n + 0.5))
	if n < 100 then return tostring(n) end
	local mag = 10 ^ (math.floor(math.log10(n)) - 1)
	return "~" .. commaInt(math.floor(n / mag + 0.5) * mag)
end

local function byId(list: { any }?, id: any): any?
	if id == nil then return nil end
	for _, e in list or {} do
		if e.id == id then return e end
	end
	return nil
end

-- ---------------------------------------------------------------- build --
local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function vlist(parent: Instance, pad: number)
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, pad)
	list.Parent = parent
end

local function text(parent: Instance, order: number, size: number, font: Font, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = order
	l.Text = ""
	l.TextColor3 = color
	l.TextSize = size
	l.FontFace = font
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

-- "Label ........ value": returns its value label and the row.
local function infoRow(parent: Instance, order: number, labelText: string): (TextLabel, Frame)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = order
	row.Parent = parent
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0.55, 0, 1, 0)
	l.Text = labelText
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = row
	local v = Instance.new("TextLabel")
	v.Name = "Value"
	v.BackgroundTransparency = 1
	v.AnchorPoint = Vector2.new(1, 0)
	v.Position = UDim2.fromScale(1, 0)
	v.Size = UDim2.new(0.45, 0, 1, 0)
	v.Text = ""
	v.TextColor3 = Theme.Color.TextPrimary
	v.TextSize = Theme.TextSize.SM
	v.FontFace = Theme.Font.Header
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.TextTruncate = Enum.TextTruncate.AtEnd
	v.Parent = row
	return v, row
end

local function divider(parent: Instance, order: number)
	local d = Instance.new("Frame")
	d.BackgroundColor3 = Theme.Color.StrokeSoft
	d.BorderSizePixel = 0
	d.Size = UDim2.new(1, 0, 0, 1)
	d.LayoutOrder = order
	d.Parent = parent
end

local function section(parent: Instance, order: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder = order
	f.Parent = parent
	vlist(f, Theme.Pad.SM)
	return f
end

local function buildHeader(panel: Instance)
	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 34)
	header.LayoutOrder = 1
	header.Parent = panel

	local badge = Instance.new("Frame")
	badge.Size = UDim2.fromOffset(34, 34)
	badge.BackgroundColor3 = STOP_COLOR
	badge.BorderSizePixel = 0
	badge.Parent = header
	corner(badge, Theme.Radius.SM)
	_badge = badge
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromOffset(22, 22)
	icon.Image = Icons.BusSolid.image
	icon.Parent = badge

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(44, 0)
	title.Size = UDim2.new(1, -74, 0, 19)
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextSize = Theme.TextSize.MD
	title.FontFace = Theme.Font.Bold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Parent = header
	_title = title

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(44, 19)
	subtitle.Size = UDim2.new(1, -74, 0, 15)
	subtitle.TextColor3 = Theme.Color.TextSecondary
	subtitle.TextSize = Theme.TextSize.XS
	subtitle.FontFace = Theme.Font.Label
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextTruncate = Enum.TextTruncate.AtEnd
	subtitle.Parent = header
	_subtitle = subtitle

	local closeBtn = IconButton.new({
		icon = Icons.Close,
		name = "Close",
		size = 22,
		parent = header,
		onClick = function() TransitInfoController.Close() end,
	})
	closeBtn.Instance.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Instance.Position = UDim2.fromScale(1, 0)
end

local function buildBusBody(panel: Instance)
	local body = section(panel, 4)
	_busBody = body
	_passValue = infoRow(body, 1, "Passengers")
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.LayoutOrder = 2
	track.Parent = body
	corner(track, 3)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 3)
	_passFill = fill
	_passNote = text(body, 3, Theme.TextSize.XS, Theme.Font.Label, WARN_COLOR)
	_passNote.Text = "Full: it only lets people off until seats free up."
	_ridersValue = infoRow(body, 4, "Line riders / month")

	-- Owner: the depot, a link that flies the camera there.
	local value, ownerRow = infoRow(body, 5, "Owner")
	value.Visible = false
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.BackgroundTransparency = 1
	btn.AnchorPoint = Vector2.new(1, 0)
	btn.Position = UDim2.fromScale(1, 0)
	btn.Size = UDim2.new(0.7, 0, 1, 0) -- depot names are long; the "Owner" label is short
	btn.Text = ""
	btn.TextColor3 = Theme.Color.Accent
	btn.TextSize = Theme.TextSize.SM
	btn.FontFace = Theme.Font.Header
	btn.TextXAlignment = Enum.TextXAlignment.Right
	btn.TextTruncate = Enum.TextTruncate.AtEnd
	btn.Parent = ownerRow
	btn.Activated:Connect(function()
		if _ownerPos and _freeCam and _freeCam.focusOn then _freeCam.focusOn(_ownerPos) end
	end)
	_ownerBtn = btn
end

local function buildStopBody(panel: Instance)
	local body = section(panel, 5)
	_stopBody = body
	_waitValue = infoRow(body, 1, "Waiting")
	_boardValue = infoRow(body, 2, "Boardings / month")
	divider(body, 3)
	_linesHead = text(body, 4, Theme.TextSize.XS, Theme.Font.Header, Theme.Color.TextSecondary)
	for i = 1, LINE_ROWS do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 18)
		row.LayoutOrder = 4 + i
		row.Visible = false
		row.Parent = body
		local bar = Instance.new("Frame")
		bar.Position = UDim2.fromOffset(0, 2)
		bar.Size = UDim2.fromOffset(4, 14)
		bar.BorderSizePixel = 0
		bar.Parent = row
		corner(bar, 2)
		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(12, 0)
		name.Size = UDim2.new(0.6, -12, 1, 0)
		name.TextColor3 = Theme.Color.TextPrimary
		name.TextSize = Theme.TextSize.SM
		name.FontFace = Theme.Font.Header
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Parent = row
		local info = Instance.new("TextLabel")
		info.BackgroundTransparency = 1
		info.AnchorPoint = Vector2.new(1, 0)
		info.Position = UDim2.fromScale(1, 0)
		info.Size = UDim2.new(0.4, 0, 1, 0)
		info.TextColor3 = Theme.Color.TextSecondary
		info.TextSize = Theme.TextSize.XS
		info.FontFace = Theme.Font.Label
		info.TextXAlignment = Enum.TextXAlignment.Right
		info.Parent = row
		_lineRows[i] = { row = row, bar = bar, name = name, info = info }
	end
end

local function buildPanel(gui: ScreenGui)
	local panel = Instance.new("CanvasGroup")
	panel.Name = "TransitInfo"
	panel.Position = UDim2.fromOffset(12, 64) -- where the building panel opens: one info panel at a time
	panel.Size = UDim2.fromOffset(280, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.ZIndex = Theme.Z.Flyout
	Glass.apply(panel, Theme.Radius.LG)
	panel.Parent = gui
	_panel = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = panel
	vlist(panel, Theme.Pad.SM)

	buildHeader(panel)
	_status = text(panel, 2, Theme.TextSize.SM, Theme.Font.Header, Theme.Color.TextPrimary)
	divider(panel, 3)
	buildBusBody(panel)
	buildStopBody(panel)
end

-- ---------------------------------------------------------------- fill --
local function populateBus(model: Model)
	local snap = TransitClient.getSnapshot()
	local route = byId(snap.routes, model:GetAttribute("LineId"))
	local depot = byId(snap.depots, model:GetAttribute("DepotId"))
	local stop = byId(snap.stops, model:GetAttribute("NextStopId"))
	local cap = math.max(1, tonumber(model:GetAttribute("Capacity")) or TransitTypes.Bus.capacity)
	local aboard = math.clamp(tonumber(model:GetAttribute("Passengers")) or 0, 0, cap)
	local color = if route then route.color else IDLE_COLOR

	_badge.BackgroundColor3 = color
	_title.Text = if cap > TransitTypes.Bus.capacity then "Articulated bus" else "City bus"
	_subtitle.Text = if route then route.name else "Not on a line"
	local status = model:GetAttribute("BusStatus")
	local stopName = if stop then stop.name else "its next stop"
	_status.Visible = true
	_status.TextColor3 = Theme.Color.TextPrimary
	_status.Text = if status == "Driving" then "Driving to " .. stopName
		elseif status == "Boarding" then "Boarding at " .. stopName
		elseif status == "ToLine" then "Heading out to its line"
		elseif status == "Returning" then "Returning to the depot"
		else "Parked at the depot"
	_passValue.Text = aboard .. " / " .. cap
	_passFill.Size = UDim2.fromScale(aboard / cap, 1)
	_passFill.BackgroundColor3 = if aboard >= cap then WARN_COLOR else color
	_passNote.Visible = aboard >= cap
	_ridersValue.Text = if route then roughly(tonumber(route.passengers) or 0) else "-"
	_ownerBtn.Text = if depot then tostring(depot.name) else "-"
	_ownerPos = if depot then depot.pos else nil
end

local function populateStop(model: Model)
	local snap = TransitClient.getSnapshot()
	local id = model:GetAttribute("StopId")
	local stop = byId(snap.stops, id)
	_badge.BackgroundColor3 = STOP_COLOR
	_title.Text = if stop then stop.name else tostring(model:GetAttribute("StopName") or "Bus stop")
	_subtitle.Text = if stop and stop.mode == "train" then "Train station" else "Bus stop"
	local waiting = if stop then tonumber(stop.waiting) or 0 else 0
	_waitValue.Text = commaInt(waiting) .. (if waiting == 1 then " person" else " people")
	_boardValue.Text = roughly(if stop then tonumber(stop.boardings) or 0 else 0)

	local lines = {}
	local running = 0
	for _, r in snap.routes or {} do
		if table.find(r.stops or {}, id) then
			table.insert(lines, r)
			if (r.activeBuses or 0) > 0 then running += 1 end
		end
	end
	_linesHead.Text = "LINES  " .. #lines
	for i, rec in _lineRows do
		local r = lines[i]
		rec.row.Visible = r ~= nil
		if r then
			local n = r.activeBuses or 0
			rec.bar.BackgroundColor3 = r.color
			rec.name.Text = r.name
			rec.info.Text = if n > 0 then n .. (if n == 1 then " bus" else " buses") else "Not running"
		end
	end
	-- Warn before people give up waiting, and say what fixes it.
	_status.TextColor3 = WARN_COLOR
	_status.Visible = running == 0
	_status.Text = if #lines == 0 then "No line stops here yet. Add this stop to a line in the Transport tool."
		else "No bus is running on its lines, so nobody gets picked up."
end

local function refresh()
	local model = _model
	if not model then return end
	if _kind == "bus" then populateBus(model) else populateStop(model) end
	_highlight.OutlineColor = _badge.BackgroundColor3
end

-- ---------------------------------------------------------------- open --
local function disconnectAll()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
end

function TransitInfoController.Close()
	_open = false
	_kind = nil
	_model = nil
	disconnectAll()
	_highlight.Adornee = nil
	local tween = UITween.to(_panel, "Flyout", { GroupTransparency = 1 })
	tween.Completed:Once(function()
		if not _open then _panel.Visible = false end
	end)
end

local function open(kind: string, model: Model)
	disconnectAll()
	_kind, _model, _open = kind, model, true
	_busBody.Visible = kind == "bus"
	_stopBody.Visible = kind == "stop"
	refresh()
	_highlight.Adornee = model
	_panel.Visible = true
	UITween.to(_panel, "Flyout", { GroupTransparency = 0 })
	table.insert(_conns, model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then TransitInfoController.Close() end
	end))
	if kind == "bus" then
		table.insert(_conns, model.AttributeChanged:Connect(function(attr: string)
			if BUS_ATTRS[attr] then refresh() end
		end))
	end
end

-- The bus or stop under the cursor: a bus is any model in _City.Buses (its Hitbox takes the ray),
-- a stop any model carrying a StopId (its pick box).
local function transitAt(input: InputObject): (string?, Model?)
	local buses = CursorRay.cityFolder("Buses")
	local transit = CursorRay.cityFolder("Transit")
	local folders: { Instance } = {}
	if buses then table.insert(folders, buses) end
	if transit then table.insert(folders, transit) end
	local hit = CursorRay.hitIn(folders, input)
	local cursor: Instance? = if hit then hit.Instance else nil
	while cursor and cursor ~= Workspace do
		if cursor:IsA("Model") then
			if cursor.Parent == buses then return "bus", cursor end
			if cursor:GetAttribute("StopId") ~= nil then return "stop", cursor end
		end
		cursor = cursor.Parent
	end
	return nil, nil
end

-- Idle while ANY build tool owns the cursor (an open build section, or bulldoze).
local function sectionActive(): boolean
	if _bottomBar == nil then return false end
	if _bottomBar.GetActiveSection and _bottomBar.GetActiveSection() ~= nil then return true end
	if _bottomBar.IsBulldozeActive and _bottomBar.IsBulldozeActive() then return true end
	return false
end

-- A Kit.Modal owns the screen while its scrim under UIModalOverlay is visible.
local function modalOpen(): boolean
	local overlay = _hudGui.Parent and _hudGui.Parent:FindFirstChild("UIModalOverlay")
	if not overlay then return false end
	for _, child in overlay:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then return true end
	end
	return false
end

local function onClick(input: InputObject)
	if not _hudGui.Enabled or sectionActive() or modalOpen() then return end
	local kind, model = transitAt(input)
	if kind and model then
		open(kind, model)
	elseif _open then
		TransitInfoController.Close()
	end
end

function TransitInfoController.Start()
	if _started then return end
	_started = true

	local okFc, fc = pcall(function() return require(core:WaitForChild("FreeCamController")) end)
	_freeCam = if okFc then fc else nil

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[TransitInfoController] CityUI not found")
		_started = false
		return
	end
	_hudGui = gui
	buildPanel(gui)

	local hl = Instance.new("Highlight")
	hl.Name = "TransitSelect"
	hl.FillTransparency = 0.85
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = gui
	_highlight = hl

	local okBar, bar = pcall(function()
		return require(script.Parent.Parent:WaitForChild("Controllers"):WaitForChild("BottomBarController"))
	end)
	_bottomBar = if okBar then bar else nil

	TransitClient.onChanged(function()
		if _open then refresh() end
	end)
	require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")).SettingsOpened.Event:Connect(function()
		if _open then TransitInfoController.Close() end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			onClick(input)
		end
	end)
end

return TransitInfoController
