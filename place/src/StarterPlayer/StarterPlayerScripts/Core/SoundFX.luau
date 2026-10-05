--!strict
-- SoundFX
-- One-shot UI/build sounds. SoundFX.play(name) fires and forgets.
-- The UI family is Roblox's own RBLX UI set (select/hover/swipe/back/purchase), so
-- every interaction shares one sonic identity while each action keeps its own voice.
-- Build sounds are Pro Sound Effects foley; the milestone is an APM pop sting.

local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent:WaitForChild("Settings"))

type Spec = { id: number, volume: number? }

local SPEC: { [string]: Spec } = {
	Road      = { id = 9113805612 },                     -- cinder block onto dirt (road plop)
	Building  = { id = 9120871246, volume = 0.45 },      -- timber dropped on pavement
	Nature    = { id = 9114576499, volume = 0.45 },      -- crunchy leaf rustle
	Bulldoze  = { id = 9118770617, volume = 0.6 },       -- soft crumble, clumps falling
	Click     = { id = 10128760939, volume = 0.6 },      -- RBLX UI Select 01
	Hover     = { id = 10066931761, volume = 0.25 },     -- RBLX UI Hover 01
	Open      = { id = 10128766965, volume = 0.5 },      -- RBLX UI Swipe
	Close     = { id = 10066914500, volume = 0.45 },     -- RBLX UI Back
	Tab       = { id = 10066968815, volume = 0.5 },      -- RBLX UI Select 02
	Error     = { id = 83600603085349, volume = 0.45 },  -- soft error pop
	Success   = { id = 10066947742, volume = 0.6 },      -- RBLX UI Purchase (territory bought)
	Milestone = { id = 1848281810, volume = 0.6 },       -- APM "Everything Works Out" sting
}

local VOLUME = 0.5
local MIN_GAP = 0.2 -- batch demolishes fire per item; don't machine-gun the same sound
-- A button that voices itself (Open, Tab, Success...) keeps its own sound: the generic
-- click is dropped when any other UI sound went off this close to it.
local CLICK_SHADOW = 0.1
-- Full-screen scrims and catchers are buttons too; hovering onto one is not a hover.
local HOVER_MAX_SCREEN_SHARE = 0.25

local _cache: { [string]: Sound } = {}
local _lastPlay: { [string]: number } = {}
local _lastVoiced = 0 -- any one-shot but Hover

local SoundFX = {}

function SoundFX.play(name: string)
	local spec = SPEC[name]
	if not spec then return end
	local now = os.clock()
	if now - (_lastPlay[name] or 0) < MIN_GAP then return end
	_lastPlay[name] = now
	if name ~= "Hover" then
		_lastVoiced = now
	end
	local s = _cache[name]
	if not s then
		s = Instance.new("Sound")
		s.Name = "FX_" .. name
		s.SoundId = "rbxassetid://" .. spec.id
		s.Parent = SoundService
		_cache[name] = s
	end
	s.Volume = (spec.volume or VOLUME)
		* (tonumber(Settings.get("sfxVolume")) or 1)
		* (tonumber(Settings.get("masterVolume")) or 1)
	s:Play()
end

local function wireButton(b: Instance)
	if not b:IsA("GuiButton") then return end
	b.MouseEnter:Connect(function()
		if UserInputService:GetLastInputType() == Enum.UserInputType.Touch then return end
		local camera = workspace.CurrentCamera
		local view = if camera then camera.ViewportSize else Vector2.one
		local size = b.AbsoluteSize
		if size.X * size.Y > view.X * view.Y * HOVER_MAX_SCREEN_SHARE then return end
		SoundFX.play("Hover")
	end)
	b.Activated:Connect(function()
		-- Deferred so the button's own handlers have voiced it first.
		task.defer(function()
			if os.clock() - _lastVoiced > CLICK_SHADOW then
				SoundFX.play("Click")
			end
		end)
	end)
end

-- Hover and click for every button under `root`, now and later: one sound family
-- across the whole game without each screen wiring its own.
function SoundFX.wireButtons(root: Instance)
	root.DescendantAdded:Connect(wireButton)
	for _, d in root:GetDescendants() do
		wireButton(d)
	end
end

return SoundFX
