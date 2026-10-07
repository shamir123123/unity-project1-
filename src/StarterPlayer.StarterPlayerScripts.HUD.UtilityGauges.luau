--!strict
-- UtilityGauges
-- The column under the top-left cluster (user 2026-10-07, CS2's info column as the reference): an info
-- button, then one round gauge per utility -- power, water, sewage. Each ring is how much of what the city
-- makes is still spare: full = plenty, empty = running out. Read off SyncCityStats (the same figures the
-- Electricity and Water panels show), so a ring can never disagree with the sim. Each gauge is a capsule that
-- opens to the right to show its figures: while hovered, or pinned open by a click until the next click.
-- The info button folds the gauges away; the CS2-style grid of info views goes behind it later.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerScripts = script.Parent.Parent
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Format = require(uiFolder:WaitForChild("Format"))
local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
local TopbarDock = require(uiFolder:WaitForChild("TopbarDock"))
local kit = uiFolder:WaitForChild("Kit")
local Tooltip = require(kit:WaitForChild("Tooltip"))

local UtilityGauges = {}

local SIZE = 40
local RING = 3
local GAP = 6
local PILL_PAD = 6 -- TopLeftCluster's: its capsule rings out this far past the chips
local CHIP_LEFT = 8 + PILL_PAD -- TopLeftCluster's capsule edge (8) + PILL_PAD: the Roblox button's left edge
local LOW = 0.2 -- spare share under this reads amber: build more before it runs out
local GOOD = Color3.fromRGB(96, 208, 120)
local WARN = Color3.fromRGB(240, 180, 60)
local OUT = Color3.fromRGB(232, 84, 76)
-- Drawn white icons (Branding/badges/make_hud_icons.py: the warning pins' own bolt and drop, and a sewer outfall).
-- Never emoji or font glyphs (user rule): those draw differently on every device.
local ICON = table.freeze({
	Power = "rbxassetid://131749972687667",
	Water = "rbxassetid://103030605194542",
	Sewage = "rbxassetid://110322533437273",
})
local DISC = Color3.fromRGB(38, 42, 50)
local TEXT_GAP = 4  -- between the disc and the figures in an open capsule
local OPEN_PAD = 14 -- after the figures, before the capsule's round end

-- Opaque on the gradient's first half, clear on the second: rotated, it shows a half-plane through the centre.
local HALF = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.499, 0),
	NumberSequenceKeypoint.new(0.5, 1), NumberSequenceKeypoint.new(1, 1),
})

type Gauge = { set: (spare: number, colour: Color3, title: string, detail: string) -> (), close: () -> (), pinned: () -> boolean }

local _started = false
local _gauges: { [string]: Gauge } = {}
local _folded = false

-- The open capsules share the left of the screen with the building info panel (user 2026-10-07): both hold
-- PanelSlots "leftPanel". A click on a gauge claims it, closing the panel; the panel opening closes every capsule.
local SLOT = "leftPanel"
local function closeAll()
	for _, g in _gauges do g.close() end
end
local function panelUp(): boolean
	return table.find(PanelSlots.holders(SLOT), "BuildingInfo") ~= nil
end
local function syncSlot()
	for _, g in _gauges do
		if g.pinned() then PanelSlots.claim(SLOT, "Gauges", closeAll); return end
	end
	PanelSlots.release(SLOT, "Gauges")
end

local function corner(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = parent
end

local function ringIn(parent: GuiObject, colour: Color3): UIStroke
	-- The stroke draws outside its frame: inset by one ring width, it lands exactly on the disc's edge.
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, -RING * 2, 1, -RING * 2)
	f.Position = UDim2.fromOffset(RING, RING)
	f.Parent = parent
	corner(f)
	local s = Instance.new("UIStroke")
	s.Thickness = RING
	s.Color = colour
	s.Parent = f
	return s
end

-- One half of the progress ring: a full ring clipped to the left or right half, its gradient turned so the
-- visible arc runs clockwise from 12 o'clock. Right half covers 0..0.5, left 0.5..1.
local function half(parent: GuiObject, right: boolean): (UIGradient, UIStroke)
	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Size = UDim2.fromScale(0.5, 1)
	clip.Position = UDim2.fromScale(if right then 0.5 else 0, 0)
	clip.Parent = parent
	local full = Instance.new("Frame")
	full.BackgroundTransparency = 1
	full.Size = UDim2.fromScale(2, 1)
	full.Position = UDim2.fromScale(if right then -1 else 0, 0)
	full.Parent = clip
	local stroke = ringIn(full, GOOD)
	local g = Instance.new("UIGradient")
	g.Transparency = HALF
	g.Parent = stroke
	return g, stroke
end

-- A dark disc, its ring running round the very edge (a dim track under the coloured arc), a white icon in it.
local function disc(parent: Instance, order: number, name: string, colour: Color3): ImageButton
	local btn = Instance.new("ImageButton")
	btn.Name = name
	btn.Size = UDim2.fromOffset(SIZE, SIZE)
	btn.LayoutOrder = order
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = colour
	btn.BackgroundTransparency = 0.08
	corner(btn)
	btn.Parent = parent
	return btn
end

local function iconIn(parent: GuiObject, image: string)
	local icon = Instance.new("ImageLabel")
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.5, 0.5)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = image
	icon.Parent = parent
end

-- A gauge is a CAPSULE that is just its disc when closed (user 2026-10-07): the disc -- ring and icon -- stays
-- at the left end and the capsule stretches right over the figures. Open while hovered; a click pins it open.
local function gauge(parent: Instance, order: number, image: string): Gauge
	local pill = Instance.new("TextButton")
	pill.Name = "Gauge"
	pill.Text = ""
	pill.AutoButtonColor = false
	pill.Size = UDim2.fromOffset(SIZE, SIZE)
	pill.LayoutOrder = order
	pill.BackgroundColor3 = DISC
	pill.BackgroundTransparency = 0.08
	pill.ClipsDescendants = true -- the figures sit past the closed width, hidden until it opens
	corner(pill)
	pill.Parent = parent
	local face = Instance.new("Frame")
	face.Name = "Disc"
	face.BackgroundTransparency = 1
	face.Size = UDim2.fromOffset(SIZE, SIZE)
	face.Parent = pill
	local track = ringIn(face, Color3.fromRGB(70, 76, 88))
	track.Transparency = 0.2
	local right, rs = half(face, true)
	local left, ls = half(face, false)
	iconIn(face, image)
	local label = Instance.new("TextLabel")
	label.Name = "Figures"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(SIZE + TEXT_GAP, 0)
	label.Size = UDim2.fromOffset(280, SIZE)
	label.RichText = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextSize = Theme.TextSize.XS
	label.FontFace = Theme.Font.Label
	label.Parent = pill

	local hovered, pinned = false, false
	local function fit()
		-- hovering does not open over the info panel; a click does, and closes the panel
		local open = pinned or (hovered and not panelUp())
		local w = if open then SIZE + TEXT_GAP + label.TextBounds.X + OPEN_PAD else SIZE
		UITween.to(pill, "Popover", { Size = UDim2.fromOffset(math.ceil(w), SIZE) })
	end
	pill.MouseEnter:Connect(function() hovered = true; fit() end)
	pill.MouseLeave:Connect(function() hovered = false; fit() end)
	pill.Activated:Connect(function()
		pinned = not pinned
		syncSlot()
		fit()
	end)
	-- the figures change under an open capsule: it follows their width
	label:GetPropertyChangedSignal("TextBounds"):Connect(function() if hovered or pinned then fit() end end)

	return {
		close = function()
			pinned, hovered = false, false
			fit()
		end,
		pinned = function() return pinned end,
		set = function(spare: number, colour: Color3, title: string, detail: string)
			local f = math.clamp(spare, 0, 1)
			right.Rotation = math.clamp(f * 360, 0, 180)
			left.Rotation = math.clamp(f * 360, 180, 360)
			rs.Color, ls.Color = colour, colour
			label.Text = string.format('<b>%s</b>  <font color="#%s">%d%% spare</font>\n%s',
				title, colour:ToHex(), math.floor(math.max(spare, 0) * 100 + 0.5), detail)
		end,
	}
end

local function MW(kw: number): string
	return string.format("%.1f MW", kw / 1000)
end
local function m3(v: number): string
	return Format.int(math.floor(v + 0.5)) .. " m\u{00B3}"
end

-- How much of `made` is still spare once `used` is taken, and the ring's colour for it.
local function spareOf(made: number, used: number): (number, Color3)
	if made <= 0 then return 0, OUT end
	local spare = (made - used) / made
	return spare, if spare <= 0 then OUT elseif spare < LOW then WARN else GOOD
end

local function apply(payload: any)
	local power = typeof(payload) == "table" and payload.power or nil
	local water = typeof(payload) == "table" and payload.water or nil
	local p = _gauges.Power
	if p then
		local made = math.max(0, tonumber(power and power.production) or 0)
		local used = math.max(0, tonumber(power and power.consumption) or 0)
		local spare, c = spareOf(made, used)
		p.set(spare, c, "Electricity", if made > 0 then string.format("%s used of %s made", MW(used), MW(made))
			else "No power made yet")
	end
	local w = _gauges.Water
	if w then
		local made = math.max(0, tonumber(water and water.waterCapacity) or 0)
		local used = math.max(0, tonumber(water and water.waterUse) or 0)
		local spare, c = spareOf(made, used)
		w.set(spare, c, "Water", if made > 0 then string.format("%s used of %s a week", m3(used), m3(made))
			else "No water pumped yet")
	end
	local s = _gauges.Sewage
	if s then
		local cap = math.max(0, tonumber(water and water.sewageCapacity) or 0)
		local flow = math.max(0, tonumber(water and water.sewage) or 0)
		local spare, c = spareOf(cap, flow)
		s.set(spare, c, "Sewage", if cap > 0 then string.format("%s of %s a week treated", m3(flow), m3(cap))
			else "Nothing treats sewage yet")
	end
end

function UtilityGauges.Start()
	if _started then return end
	_started = true

	local gui = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[UtilityGauges] CityUI not found")
		_started = false
		return
	end
	HudScale.attach(gui)

	local column = Instance.new("Frame")
	column.Name = "UtilityGauges"
	column.BackgroundTransparency = 1
	column.AutomaticSize = Enum.AutomaticSize.XY
	column.ZIndex = Theme.Z.HUD
	column.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, GAP)
	list.Parent = column

	-- The info button heads the column in the accent, as the one that opens things.
	local info = disc(column, 0, "Info", Theme.Color.Accent)
	iconIn(info, Icons.Info.image or "")
	Tooltip.attach(info, "City info")

	_gauges.Power = gauge(column, 1, ICON.Power)
	_gauges.Water = gauge(column, 2, ICON.Water)
	_gauges.Sewage = gauge(column, 3, ICON.Sewage)
	apply(nil)

	-- ponytail: the info button only folds the gauges for now; the info-view grid opens here later.
	info.Activated:Connect(function()
		_folded = not _folded
		for _, c in column:GetChildren() do
			if c:IsA("GuiObject") and c ~= info then c.Visible = not _folded end
		end
	end)

	-- Under the top-left capsule, centred on the Roblox button: that chip starts at CHIP_LEFT and is `h` wide.
	TopbarDock.bind(gui, function(_x0, top, h)
		column.Position = UDim2.fromOffset(math.round(CHIP_LEFT + (h - SIZE) / 2), top + h + PILL_PAD + GAP)
	end)

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	Net.SyncCityStats.OnClientEvent:Connect(apply)
end

return UtilityGauges
