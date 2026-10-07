--!strict
-- Panel chrome: flat dark translucent bg, hairline stroke, soft top sheen, and
-- a Kit.Frost pane that blurs the world behind the panel's screen rect. Every
-- glass surface in the game frosts through this one entry.
--
-- The panel fill stands on its own -- frost is a player setting and plenty of
-- machines can't render it -- so the fill must never depend on the blur.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local Theme = require(script.Parent.Parent.Theme)
local Frost = require(script.Parent.Frost)
local Settings = require(script.Parent.Parent.Parent.Core.Settings)

-- Over the main menu the backdrop is a gui (key art / video), which Kit.Frost's world
-- blur cannot reach. There every pane shows the matching rect of a pre-blurred copy of
-- the key art instead, cut with ImageRect so it lines up with the screen behind it.
-- ponytail: a still under the video reel; the heavy blur hides that it does not move.
local MENU_BACKDROP = "rbxassetid://86704789681523"
local MENU_BACKDROP_SIZE = Vector2.new(1024, 576)
local MENU_BACKDROP_INK = Color3.fromRGB(150, 154, 158) -- darkens it so white type reads
local MENU_GUI = "MainMenu"

local Glass = {}

-- Every applied pane, so the UI-transparency setting can repaint them all. Weak
-- keys: a destroyed panel drops out on its own, no cleanup call to forget.
local _panes: { [GuiObject]: true } = setmetatable({}, { __mode = "k" }) :: any
local _menuPanes: { [ImageLabel]: GuiObject } = setmetatable({}, { __mode = "k" }) :: any
local _extra = math.clamp(tonumber(Settings.get("uiTransparency")) or 0, 0, 0.5) -- 0 = the designed look; higher = more see-through

local function paint(frame: GuiObject)
	frame.BackgroundTransparency = math.clamp(Theme.Glass.Transparency + _extra, 0, 1)
end

-- 0..0.5 of extra transparency on top of the theme value.
function Glass.setUserTransparency(extra: number)
	_extra = math.clamp(tonumber(extra) or 0, 0, 0.5)
	for frame in _panes do
		if frame.Parent then
			paint(frame)
		end
	end
	for img in _menuPanes do
		img.ImageTransparency = _extra
	end
end

local _menuGui: ScreenGui? = nil

-- Cuts the pane's screen rect out of the backdrop, cropped to the viewport the way the
-- menu's key art is (ScaleType.Crop).
local function cutBackdrop(img: ImageLabel, frame: GuiObject)
	local camera = workspace.CurrentCamera
	local menu = _menuGui
	img.Visible = menu ~= nil and menu.Enabled and Settings.get("frostedGlass") ~= false
	if not camera or not img.Visible then return end
	local view = camera.ViewportSize
	local k = math.max(view.X / MENU_BACKDROP_SIZE.X, view.Y / MENU_BACKDROP_SIZE.Y)
	if k <= 0 then return end
	local screen = frame:FindFirstAncestorWhichIsA("ScreenGui")
	local at = frame.AbsolutePosition + (if screen and not screen.IgnoreGuiInset then GuiService:GetGuiInset() else Vector2.zero)
	local crop = (MENU_BACKDROP_SIZE * k - view) / 2
	img.ImageRectOffset = (at + crop) / k
	img.ImageRectSize = frame.AbsoluteSize / k
end

local function watchMenu()
	if _menuGui then return end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	local menu = pg and pg:FindFirstChild(MENU_GUI)
	if not (menu and menu:IsA("ScreenGui")) then return end
	_menuGui = menu
	local function recutAll()
		task.defer(function()
			for img, frame in _menuPanes do
				if img.Parent then cutBackdrop(img, frame) end
			end
		end)
	end
	menu:GetPropertyChangedSignal("Enabled"):Connect(recutAll)
	Settings.onChanged("frostedGlass", recutAll)
end

-- Deferred so the caller has finished building the pane. A pane that lays out or scrolls
-- its children keeps the plain fill: the image would become one of its list items.
-- ponytail: layout/scrolling panes get no menu frost; a sibling image would cover them.
local function addBackdrop(frame: GuiObject, radius: number)
	if frame:IsA("ScrollingFrame") or frame:FindFirstChildWhichIsA("UIGridStyleLayout") then return end
	-- Under Global layering a ZIndex-0 image lands beneath the gui's own veil.
	local screen = frame:FindFirstAncestorWhichIsA("ScreenGui")
	if screen and screen.ZIndexBehavior == Enum.ZIndexBehavior.Global then return end
	local img = Instance.new("ImageLabel")
	img.Name = "MenuBackdrop"
	img.ZIndex = 0 -- under the pane's own content
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.Image = MENU_BACKDROP
	img.ImageColor3 = MENU_BACKDROP_INK
	img.ImageTransparency = _extra -- the UI-transparency setting, as on the fill
	img.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = img
	img.Parent = frame
	_menuPanes[img] = frame
	local function cut()
		watchMenu()
		cutBackdrop(img, frame)
	end
	frame:GetPropertyChangedSignal("AbsolutePosition"):Connect(cut)
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(cut)
	frame.AncestryChanged:Connect(cut)
	task.defer(cut)
end

function Glass.apply(frame: GuiObject, radius: number?): UIStroke
	local r = radius or Theme.Radius.MD
	frame.BackgroundColor3 = Theme.Glass.Color
	_panes[frame] = true
	paint(frame)
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, r)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Glass.StrokeColor
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Transparency = Theme.Glass.StrokeTransparency
	stroke.Parent = frame

	-- A UIGradient on a CanvasGroup multiplies the whole composited content
	-- (children go black), so the sheen only goes on plain frames.
	if not frame:IsA("CanvasGroup") then
		local grad = Instance.new("UIGradient")
		grad.Rotation = 90
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Glass.SheenColor),
			ColorSequenceKeypoint.new(0.3, Theme.Glass.Color),
			ColorSequenceKeypoint.new(1, Theme.Glass.Color),
		})
		grad.Parent = frame
	end

	Frost.attach(frame, r)
	if not frame:IsA("CanvasGroup") then
		task.defer(addBackdrop, frame, r)
	end

	return stroke
end

return Glass
