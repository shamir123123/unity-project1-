--!strict
-- LoadingView: what the loading screens look like. LoadingController (the join) and
-- MainMenuController (a city load) decide WHEN each part runs; this module only draws.
--
-- One centred mark over blurred stills of the city, cross-fading in turn. While loading it
-- is the loader: four dim blocks with an orange light running round them and the island
-- breathing in the middle; the bar under it only ever moves on the real gates. When everything is in,
-- playLogo turns the loader into the logo: the blocks land solid, the lit one goes orange,
-- the mark slides aside and the name slides out beside it.
--
-- Bottom right, once a screen has been up a moment, a SKIP pill (allowSkip). What a press
-- actually skips is the caller's decision; this only records it (skipped) and shows it heard.
--
-- The logo mark is built from Frames rather than one image so each block can animate on its
-- own. The roundabout cut is a disc in COLOR.bg laid over the blocks. Only the wordmark is an uploaded image (Archivo
-- Black is not a Roblox font).
--
-- No CanvasGroups: GroupTransparency is not honoured everywhere (it fell back to fully
-- visible in the Studio preview) and they cost texture memory on low-end phones, so every
-- fade tweens each element's own transparency through a Fade list.

local TweenService = game:GetService("TweenService")

local LoadingView = {}


export type View = {
	setProgress: (alpha: number) -> (),
	setStatus: (text: string) -> (),
	showProgress: () -> (),
	holdUntil: (isDone: () -> boolean, timeout: number) -> boolean,
	playLogo: () -> (),
	allowSkip: () -> (),
	skipped: () -> boolean,
	fadeOut: () -> (),
	destroy: () -> (),
}

-- Laid out on a 1280x720 design canvas; one UIScale fits it to the screen.
local DESIGN = Vector2.new(1280, 720)
local CENTER = Vector2.new(640, 330)
local SCALE_MIN, SCALE_MAX = 0.6, 2

local COLOR = table.freeze({
	bg = Color3.fromRGB(14, 16, 20),
	text = Color3.fromRGB(244, 246, 248),
	block = Color3.fromRGB(245, 246, 248),
	accent = Color3.fromRGB(240, 122, 47),
	-- The skip pill: Theme.Glass.Color and Theme.Color.StrokeSoft, the HUD's glass capsule.
	glass = Color3.fromRGB(38, 42, 46),
	stroke = Color3.fromRGB(104, 100, 92),
})

local WORDMARK_IMAGE = "rbxassetid://83104800487404" -- "CITY / DISTRICTS", white, 1024x290
-- Softly blurred stills of the trailer city, cross-fading behind the loader in turn.
local BACKDROPS = table.freeze({
	"rbxassetid://71178300066983", -- the isle from above
	"rbxassetid://111412169600163", -- golden hour over the towers
	"rbxassetid://114984278316446", -- the beach road
	"rbxassetid://93815178500630", -- sunrise over the bay
	"rbxassetid://140043809350976", -- the whole isle
	"rbxassetid://117766163053466", -- towers over the houses
})
local BACKDROP_TINT = Color3.fromRGB(176, 178, 182) -- just enough shade for the white mark
local BACKDROP_HOLD = 15

-- Fetched on the first loading screen (the join), so the city load's photo is already
-- there on its first frame instead of fading in over black.
local _preloaded = false
local function preloadBackdrops()
	if _preloaded then return end
	_preloaded = true
	task.spawn(function()
		local probes = {}
		for _, id in BACKDROPS do
			local probe = Instance.new("ImageLabel")
			probe.Image = id
			table.insert(probes, probe)
		end
		local ok, err = pcall(game:GetService("ContentProvider").PreloadAsync, game:GetService("ContentProvider"), probes)
		if not ok then warn("[LoadingView] backdrop preload failed: " .. tostring(err)) end
		for _, probe in probes do probe:Destroy() end
	end)
end
local WORDMARK_ASPECT = 1024 / 290
local FONT = "rbxasset://fonts/families/Montserrat.json"

local MARK_SIZE = 132
local MARK_GAP = 32
local WORD_H = MARK_SIZE * 0.86
local WORD_W = WORD_H * WORDMARK_ASPECT
local LOGO_W = MARK_SIZE + MARK_GAP + WORD_W
-- Where the mark sits once the name is out beside it: the pair is centred, not the mark.
local MARK_LOGO_X = CENTER.X - LOGO_W / 2 + MARK_SIZE / 2
local WORD_X = MARK_LOGO_X + MARK_SIZE / 2 + MARK_GAP

local BLOCK_DIM = 0.84 -- the loader's unlit blocks
local ORBIT_STEP = 0.16
local LOGO_HOLD = 0.35 -- was 1.0: the logo plays AFTER the city is ready, so every beat here is load time

-- The skip pill. Kit.Button's capsule, restated: Kit cannot be required from ReplicatedFirst.
-- It comes up SKIP_DELAY into a screen's life, so a load that is over that fast never shows it.
local SKIP_SIZE = Vector2.new(132, 38)
local SKIP_MARGIN = 32
local SKIP_DELAY = 1.5
-- Fitted to the screen's SHORT side, not cover-fitted like the canvas: it has to stay a
-- comfortable thumb target on a phone and not turn into a slab on a 4K monitor.
local SKIP_SCALE_MIN, SKIP_SCALE_MAX = 0.9, 1.6

local FADE_IN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local QUICK = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TRAIL = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE = TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local LIGHT_UP = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BREATHE = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BG_OUT = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BACKDROP_FADE = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local ORBIT_ORDER = { 1, 2, 3, 4 } -- clockwise from top-left
local POP_ORDER = { 1, 4, 3, 2 } -- TL, BL, BR land first; TR (the lit district) lands last

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst: any = Instance.new(className)
	for key, value in props do
		inst[key] = value
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function tween(inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, goal)
	t:Play()
	return t
end

type Fade = { inst: Instance, prop: string, shown: number }

-- Tweens every entry to its shown transparency, or to fully transparent.
local function fadeAll(list: { Fade }, visible: boolean, info: TweenInfo)
	for _, item in list do
		tween(item.inst, info, { [item.prop] = if visible then item.shown else 1 })
	end
end

local function spaced(s: string): string
	-- By character, not byte, so a multi-byte glyph is not split.
	return (s:gsub(utf8.charpattern, "%0 "):gsub(" $", ""))
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		TextColor3 = COLOR.text,
		TextTransparency = 1,
		FontFace = Font.new(FONT, props.Weight or Enum.FontWeight.Regular),
	}, parent)
	props.Weight = nil
	for key, value in props do
		(label :: any)[key] = value
	end
	return label
end

type Mark = {
	holder: Frame,
	cut: Frame,
	blocks: { Frame },
	scales: { UIScale },
	island: Frame,
	islandScale: UIScale,
}

-- Four blocks, clockwise from top-left (TL, TR, BR, BL), roads between them, a roundabout
-- disc cut out of the middle and an island on it. Proportions match Branding/logo_mark.svg.
local function buildMark(parent: Instance, size: number, zIndex: number): Mark
	local s = size * 60 / 141.6
	local road = s * 0.36
	local radius = s * 0.5
	local holder = make("Frame", {
		Name = "Mark",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
	}, parent)
	local blocks, scales = {}, {}
	for i, cell in { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } } do
		local block = make("Frame", {
			Name = "Block" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(cell[1] * (s + road) + s / 2, cell[2] * (s + road) + s / 2),
			Size = UDim2.fromOffset(s, s),
			BackgroundColor3 = COLOR.block,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = zIndex,
		}, holder)
		make("UICorner", { CornerRadius = UDim.new(0, s * 0.16) }, block)
		blocks[i] = block
		scales[i] = make("UIScale", {}, block)
	end
	local cut = make("Frame", {
		Name = "Roundabout",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(radius * 2, radius * 2),
		BackgroundColor3 = COLOR.bg,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = zIndex + 1,
	}, holder)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, cut)
	local island = make("Frame", {
		Name = "Island",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(radius * 0.62, radius * 0.62),
		BackgroundColor3 = COLOR.block,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = zIndex + 2,
	}, holder)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, island)
	return { holder = holder, cut = cut, blocks = blocks, scales = scales, island = island, islandScale = make("UIScale", {}, island) }
end

-- Builds on the LoadingScreen template's Background; hides the template's static Logo.
function LoadingView.new(bg: GuiObject): View
	local connections: { RBXScriptConnection } = {}
	local createdAt = os.clock()
	bg.BackgroundColor3 = COLOR.bg
	local staticLogo = bg:FindFirstChild("Logo")
	if staticLogo and staticLogo:IsA("GuiObject") then
		staticLogo.Visible = false
	end
	-- The template ships Global, where the photos below could not sit between the
	-- backdrop colour and the canvas.
	local screen = bg:FindFirstAncestorWhichIsA("ScreenGui")
	if screen then
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	end

	local shots: { ImageLabel } = {}
	for i = 1, 2 do
		shots[i] = make("ImageLabel", {
			Name = "Backdrop" .. i, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScaleType = Enum.ScaleType.Crop, ImageColor3 = BACKDROP_TINT, ImageTransparency = 1, ZIndex = i - 1,
		}, bg)
	end
	preloadBackdrops()
	local slideshow = task.spawn(function()
		local index, front = math.random(#BACKDROPS), 1
		shots[front].Image = BACKDROPS[index]
		shots[front].ImageTransparency = 0 -- up on the first frame: no black before it
		while true do
			task.wait(BACKDROP_HOLD)
			index = index % #BACKDROPS + 1
			local incoming = shots[3 - front]
			incoming.Image = BACKDROPS[index]
			incoming.ImageTransparency = 1
			incoming.ZIndex, shots[front].ZIndex = 1, 0
			tween(incoming, BACKDROP_FADE, { ImageTransparency = 0 })
			front = 3 - front
		end
	end)

	local canvas = make("Frame", {
		Name = "Canvas",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(DESIGN.X, DESIGN.Y),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, bg)
	local fit = make("UIScale", {}, canvas)
	local function refit()
		local abs = bg.AbsoluteSize
		if abs.X > 0 and abs.Y > 0 then
			fit.Scale = math.clamp(math.max(abs.X / DESIGN.X, abs.Y / DESIGN.Y), SCALE_MIN, SCALE_MAX)
		end
	end
	refit()
	table.insert(connections, bg:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit))

	local mark = buildMark(canvas, MARK_SIZE, 3)
	mark.holder.Position = UDim2.fromOffset(CENTER.X, CENTER.Y)
	local wordFinal = UDim2.fromOffset(WORD_X, CENTER.Y)
	local wordmark = make("ImageLabel", {
		Name = "Wordmark", Image = WORDMARK_IMAGE, ScaleType = Enum.ScaleType.Fit, BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5), Position = wordFinal - UDim2.fromOffset(36, 0),
		Size = UDim2.fromOffset(WORD_W, WORD_H), ImageTransparency = 1, ZIndex = 3,
	}, canvas)

	-- Status line and bar under the mark: what is loading on the left, how far on the right.
	local BAR_W, BAR_Y = 300, CENTER.Y + 150
	local status = text(canvas, {
		Name = "Status", Weight = Enum.FontWeight.SemiBold, TextSize = 11, Text = spaced("LOADING"),
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromOffset(CENTER.X - BAR_W / 2, BAR_Y - 10),
		Size = UDim2.fromOffset(BAR_W - 50, 14), TextXAlignment = Enum.TextXAlignment.Left,
	})
	local percent = text(canvas, {
		Name = "Percent", Weight = Enum.FontWeight.SemiBold, TextSize = 11, Text = "0%",
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromOffset(CENTER.X + BAR_W / 2, BAR_Y - 10),
		Size = UDim2.fromOffset(50, 14), TextXAlignment = Enum.TextXAlignment.Right,
	})
	local track = make("Frame", {
		Name = "ProgressTrack", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(CENTER.X, BAR_Y),
		Size = UDim2.fromOffset(BAR_W, 3), BackgroundColor3 = COLOR.text, BackgroundTransparency = 1, BorderSizePixel = 0,
	}, canvas)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
	local fill = make("Frame", {
		Name = "ProgressFill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = COLOR.accent,
		BackgroundTransparency = 1, BorderSizePixel = 0,
	}, track)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)

	local progressFade: { Fade } = {
		{ inst = status, prop = "TextTransparency", shown = 0.45 },
		{ inst = percent, prop = "TextTransparency", shown = 0.45 },
		{ inst = track, prop = "BackgroundTransparency", shown = 0.88 },
		{ inst = fill, prop = "BackgroundTransparency", shown = 0 },
	}
	local markFade: { Fade } = {
		{ inst = mark.cut, prop = "BackgroundTransparency", shown = 0 },
		{ inst = mark.island, prop = "BackgroundTransparency", shown = 0.35 },
	}
	for _, block in mark.blocks do
		table.insert(markFade, { inst = block, prop = "BackgroundTransparency", shown = BLOCK_DIM })
	end

	-- SKIP, bottom right. Parented to the backdrop rather than the canvas: the canvas is
	-- cover-fitted and crops at the edges of a narrow screen, and a corner button has to stay
	-- in the corner.
	local skipHolder = make("Frame", {
		Name = "Skip", AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(SKIP_SIZE.X, SKIP_SIZE.Y),
		BackgroundTransparency = 1, Visible = false, ZIndex = 4,
	}, bg)
	local skipFit = make("UIScale", {}, skipHolder)
	local skipButton = make("TextButton", {
		Name = "SkipButton", Text = "", AutoButtonColor = false, Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLOR.glass, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 4,
	}, skipHolder)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, skipButton)
	local skipPress = make("UIScale", {}, skipButton)
	-- Border, not the default Contextual: on a TextButton that would outline the label instead.
	local skipStroke = make("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = COLOR.stroke, Thickness = 1, Transparency = 1,
	}, skipButton)
	local skipLabel = text(skipButton, {
		Name = "Label", Weight = Enum.FontWeight.Medium, TextSize = 13, Text = spaced("SKIP") .. "   ›",
		Size = UDim2.fromScale(1, 1), ZIndex = 5,
	})
	local skipFade: { Fade } = {
		{ inst = skipButton, prop = "BackgroundTransparency", shown = 0.45 },
		{ inst = skipStroke, prop = "Transparency", shown = 0 },
		{ inst = skipLabel, prop = "TextTransparency", shown = 0.1 },
	}
	local function refitSkip()
		local abs = bg.AbsoluteSize
		if abs.X <= 0 or abs.Y <= 0 then return end
		local s = math.clamp(math.min(abs.X / DESIGN.X, abs.Y / DESIGN.Y), SKIP_SCALE_MIN, SKIP_SCALE_MAX)
		skipFit.Scale = s
		skipHolder.Position = UDim2.new(1, -SKIP_MARGIN * s, 1, -SKIP_MARGIN * s)
	end
	refitSkip()
	table.insert(connections, bg:GetPropertyChangedSignal("AbsoluteSize"):Connect(refitSkip))

	local skipAllowed, skippedFlag, skipHover = false, false, false
	local skipReveal: thread? = nil
	-- Accent hairline on hover, and kept once pressed: that is the whole of "it heard you".
	local function paintSkip()
		tween(skipStroke, QUICK, { Color = if skipHover or skippedFlag then COLOR.accent else COLOR.stroke })
	end
	table.insert(connections, skipButton.MouseEnter:Connect(function()
		skipHover = true
		paintSkip()
	end))
	table.insert(connections, skipButton.MouseLeave:Connect(function()
		skipHover = false
		tween(skipPress, QUICK, { Scale = 1 })
		paintSkip()
	end))
	table.insert(connections, skipButton.MouseButton1Down:Connect(function()
		tween(skipPress, QUICK, { Scale = 0.95 })
	end))
	table.insert(connections, skipButton.MouseButton1Up:Connect(function()
		tween(skipPress, QUICK, { Scale = 1 })
	end))
	table.insert(connections, skipButton.Activated:Connect(function()
		if skippedFlag or not skipAllowed then return end
		skippedFlag = true
		skipLabel.Text = spaced("SKIPPING")
		paintSkip()
	end))

	local shownProgress = 0
	local breathe: Tween? = nil
	local view = {} :: View

	-- Monotonic: the gates report their own fractions and a bar that slid backwards would
	-- read as something having gone wrong.
	function view.setProgress(alpha: number)
		alpha = math.clamp(alpha, 0, 1)
		if alpha <= shownProgress then
			return
		end
		shownProgress = alpha
		tween(fill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(alpha, 1) })
		percent.Text = string.format("%d%%", math.floor(alpha * 100 + 0.5))
	end

	function view.setStatus(newText: string)
		local label = spaced(string.upper(newText))
		if status.Text ~= label then
			status.Text = label
		end
	end

	-- Brings up the dim mark and the status bar.
	function view.showProgress()
		fadeAll(progressFade, true, FADE_IN)
		fadeAll(markFade, true, FADE_IN)
	end

	-- Runs the loader (a light circling the blocks, the island breathing) until isDone() or
	-- the timeout. Leaves the mark dim and in place, so playLogo can build straight out of it.
	-- Returns whether isDone() came true.
	function view.holdUntil(isDone: () -> boolean, timeout: number): boolean
		if isDone() then
			return true
		end
		mark.islandScale.Scale = 1
		breathe = tween(mark.islandScale, BREATHE, { Scale = 0.72 })
		-- The light is drawn from the clock every frame, not fired as tweens: a city load
		-- drops frames, and a dropped step used to leave the orbit dark or stuttering.
		local deadline = os.clock() + timeout
		local start = os.clock()
		local period = #ORBIT_ORDER * ORBIT_STEP
		while not isDone() and os.clock() < deadline do
			local t = os.clock() - start
			for k, index in ORBIT_ORDER do
				local since = (t - (k - 1) * ORBIT_STEP) % period -- seconds since this block lit
				local fade = math.clamp(since / TRAIL.Time, 0, 1)
				fade = 1 - (1 - fade) ^ 2 -- quad out, like the old trail tween
				local block = mark.blocks[index]
				block.BackgroundColor3 = COLOR.accent:Lerp(COLOR.block, fade)
				block.BackgroundTransparency = BLOCK_DIM * fade
			end
			task.wait()
		end
		for _, block in mark.blocks do
			block.BackgroundColor3 = COLOR.block
			block.BackgroundTransparency = BLOCK_DIM
		end
		if breathe then
			breathe:Cancel()
			breathe = nil
		end
		tween(mark.islandScale, QUICK, { Scale = 1 })
		return isDone()
	end

	-- Brings the skip pill up, SKIP_DELAY into the screen's life.
	function view.allowSkip()
		if skipAllowed then return end
		skipAllowed = true
		skipReveal = task.delay(math.max(SKIP_DELAY - (os.clock() - createdAt), 0), function()
			skipReveal = nil
			skipHolder.Visible = true
			fadeAll(skipFade, true, FADE_IN)
		end)
	end

	-- Whether the player has asked to skip. Latched: one press is the whole conversation.
	function view.skipped(): boolean
		return skippedFlag
	end

	-- The loader becomes the logo: the blocks land solid, the fourth lights orange (your
	-- district), the island drops in, then the mark slides aside for the name. Not played at
	-- all after a skip, and a skip in the middle of it drops the remaining beats -- the fade
	-- that follows takes whatever is half-built down with it.
	function view.playLogo()
		if skippedFlag then return end
		local function beat(seconds: number)
			if not skippedFlag then task.wait(seconds) end
		end
		fadeAll(progressFade, false, FADE_OUT)
		for i, block in mark.blocks do
			block.BackgroundColor3 = COLOR.block
			mark.scales[i].Scale = 0.55
		end
		mark.islandScale.Scale = 0
		for _, i in POP_ORDER do
			tween(mark.scales[i], POP, { Scale = 1 })
			tween(mark.blocks[i], QUICK, { BackgroundTransparency = 0 })
			beat(0.08)
		end
		beat(0.12)
		tween(mark.islandScale, POP, { Scale = 1 })
		tween(mark.island, QUICK, { BackgroundTransparency = 0 })
		tween(mark.blocks[2], LIGHT_UP, { BackgroundColor3 = COLOR.accent })
		beat(0.25)
		tween(mark.holder, SLIDE, { Position = UDim2.fromOffset(MARK_LOGO_X, CENTER.Y) })
		tween(wordmark, SLIDE, { ImageTransparency = 0, Position = wordFinal })
		beat(SLIDE.Time + LOGO_HOLD)
	end

	-- Fades everything, then the backdrop, uncovering whatever is underneath.
	function view.fadeOut()
		fadeAll(progressFade, false, FADE_OUT)
		fadeAll(skipFade, false, FADE_OUT)
		for _, block in mark.blocks do
			tween(block, FADE_OUT, { BackgroundTransparency = 1 })
		end
		tween(mark.cut, FADE_OUT, { BackgroundTransparency = 1 })
		tween(mark.island, FADE_OUT, { BackgroundTransparency = 1 })
		tween(wordmark, FADE_OUT, { ImageTransparency = 1 })
		task.wait(FADE_OUT.Time * 0.6)
		task.cancel(slideshow)
		for _, shot in shots do
			tween(shot, BG_OUT, { ImageTransparency = 1 })
		end
		tween(bg, BG_OUT, { BackgroundTransparency = 1 })
		task.wait(BG_OUT.Time)
	end

	function view.destroy()
		task.cancel(slideshow)
		if skipReveal then
			task.cancel(skipReveal)
			skipReveal = nil
		end
		if breathe then
			breathe:Cancel()
			breathe = nil
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end

	return view
end

return LoadingView
