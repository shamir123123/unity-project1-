--!strict
-- LocalScript -> StarterPlayerScripts
-- Camera-following rain / snow particles, driven by workspace:GetAttribute("Weather")
-- (Clear / Cloudy / Rain / Fog / Snow) and "WeatherIntensity" (drizzle..downpour).
-- LockedToPart = true simulates particles in the emitter's moving frame, so panning the
-- camera never leaves the volume behind. The rate RAMPS, so a shower starts as a drizzle
-- and tails off instead of switching.
-- Rain is drawn as STREAKS: VelocityParallel stretches each drop along its fall. The whole
-- volume is tilted into the spell's wind (workspace "WindAngle", WeatherService), so every
-- streak is a straight line leaning ONE way in the world: turn the camera and the rain
-- comes at you from a different side. The harder it rains the further it leans, so even
-- from the high build camera (where straight-down rain is a dot) a downpour reads as lines.
-- The volume sits out along the view, not around the camera: from the high build camera
-- rain around the lens is almost all off screen.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Settings = require(script.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local part = Instance.new("Part")
part.Name = "_WeatherEmitter"
part.Anchored = true
part.CanCollide = false
part.CanQuery = false
part.CanTouch = false
part.Transparency = 1
part.CastShadow = false
part.Size = Vector3.new(150, 1, 150)
part.Parent = Workspace

local emitter = Instance.new("ParticleEmitter")
emitter.Enabled = false
emitter.EmissionDirection = Enum.NormalId.Bottom
emitter.LockedToPart = true -- move particles with the camera-tracking part; no gap when moving
emitter.Parent = part

local RAIN_RATE, SNOW_RATE = 4500, 400
local DRIZZLE_SHARE = 0.3 -- the lightest rain still falls at this share of RAIN_RATE
-- Degrees from vertical, drizzle .. downpour. Under ~30 the slant did not read as coming
-- from any side (user playtest 2026-10-06); 42 does.
local LEAN_MIN, LEAN_MAX = 18, 42
local RAMP = 750 -- particles/s gained or lost per second: rain fades in over ~6 s
-- The volume sits AHEAD along the view, ABOVE it, and upwind by its lean, so the drops
-- fall through the middle of the screen at any camera height.
local ABOVE, AHEAD = 45, 60
local _targetRate = 0
local _tilt = CFrame.identity
local _upwind = Vector3.zero

local function fade(mid: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, mid),
		NumberSequenceKeypoint.new(0.85, mid),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function configureRain(intensity: number)
	local angle = math.rad(tonumber(Workspace:GetAttribute("WindAngle")) or 0)
	local wind = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local lean = math.rad(LEAN_MIN + (LEAN_MAX - LEAN_MIN) * intensity)
	-- Rotating about up x wind swings the emitter's -Y (its fall) toward the wind.
	_tilt = CFrame.fromAxisAngle(Vector3.yAxis:Cross(wind), -lean)
	_upwind = -wind * ABOVE * math.tan(lean)
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Squash = NumberSequence.new(3)
	emitter.Color = ColorSequence.new(Color3.fromRGB(215, 225, 240))
	emitter.Transparency = fade(0.35 - 0.15 * intensity)
	emitter.Size = NumberSequence.new(0.3 + 0.15 * intensity)
	emitter.Lifetime = NumberRange.new(0.55, 0.7)
	emitter.Speed = NumberRange.new(170, 190)
	emitter.SpreadAngle = Vector2.new(1, 1)
	emitter.Acceleration = Vector3.zero -- straight lines: all the slant is in the tilt
	emitter.LightEmission = 0.6
	emitter.Brightness = 2.5
end

local function configureSnow()
	_tilt, _upwind = CFrame.identity, Vector3.zero
	emitter.Orientation = Enum.ParticleOrientation.FacingCamera
	emitter.Squash = NumberSequence.new(0)
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	emitter.Transparency = NumberSequence.new(0.1)
	emitter.Size = NumberSequence.new(0.4)
	emitter.Lifetime = NumberRange.new(3, 5)
	emitter.Speed = NumberRange.new(7, 13)
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.Acceleration = Vector3.new(3, -7, 1)
	emitter.LightEmission = 0.4
	emitter.Brightness = 1
end

local function apply()
	local w = Workspace:GetAttribute("Weather")
	local fx = math.clamp(tonumber(Settings.get("weatherFx")) or 1, 0, 1)
	local intensity = math.clamp(tonumber(Workspace:GetAttribute("WeatherIntensity")) or 0.5, 0, 1)
	if w == "Rain" then
		configureRain(intensity)
		_targetRate = RAIN_RATE * (DRIZZLE_SHARE + (1 - DRIZZLE_SHARE) * intensity) * fx
	elseif w == "Snow" then
		configureSnow()
		_targetRate = SNOW_RATE * fx
	else
		_targetRate = 0 -- keeps the last look while it tapers off
	end
end

RunService.RenderStepped:Connect(function(dt: number)
	local cam = Workspace.CurrentCamera
	if cam then
		local cf = cam.CFrame
		part.CFrame = CFrame.new(cf.Position + cf.LookVector * AHEAD + _upwind + Vector3.new(0, ABOVE, 0)) * _tilt
	end
	local rate = emitter.Rate
	if rate ~= _targetRate then
		rate = if rate < _targetRate then math.min(rate + RAMP * dt, _targetRate) else math.max(rate - RAMP * dt, _targetRate)
		emitter.Rate = rate
		emitter.Enabled = rate > 0
	end
end)

Workspace:GetAttributeChangedSignal("Weather"):Connect(apply)
Workspace:GetAttributeChangedSignal("WeatherIntensity"):Connect(apply)
Workspace:GetAttributeChangedSignal("WindAngle"):Connect(apply)
Settings.onChanged("weatherFx", apply)
apply()
