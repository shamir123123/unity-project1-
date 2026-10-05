--!strict
-- LocalScript -> StarterPlayerScripts
-- Camera-following rain / snow particles, driven by workspace:GetAttribute("Weather")
-- (Clear / Cloudy / Rain / Snow). LockedToPart = true simulates particles in the emitter's
-- moving frame, so panning the camera no longer leaves the volume behind (the old bug).
-- The rate RAMPS, so a shower starts as a drizzle and tails off instead of switching.

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
part.Size = Vector3.new(90, 1, 90)
part.Parent = Workspace

local emitter = Instance.new("ParticleEmitter")
emitter.Enabled = false
emitter.EmissionDirection = Enum.NormalId.Bottom
emitter.LockedToPart = true -- move particles with the camera-tracking part; no gap when moving
emitter.Parent = part

local RAIN_RATE, SNOW_RATE = 1400, 400
local RAMP = 240 -- particles/s gained or lost per second: rain fades in over ~6 s
local _targetRate = 0

local function configureRain()
	emitter.Color = ColorSequence.new(Color3.fromRGB(175, 195, 225))
	emitter.Transparency = NumberSequence.new(0.35)
	emitter.Size = NumberSequence.new(0.18)
	emitter.Lifetime = NumberRange.new(0.7, 1.0)
	emitter.Speed = NumberRange.new(110, 130)
	emitter.SpreadAngle = Vector2.new(4, 4)
	emitter.Acceleration = Vector3.new(0, -60, 0)
	emitter.LightEmission = 0.2
end

local function configureSnow()
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	emitter.Transparency = NumberSequence.new(0.1)
	emitter.Size = NumberSequence.new(0.4)
	emitter.Lifetime = NumberRange.new(3, 5)
	emitter.Speed = NumberRange.new(7, 13)
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.Acceleration = Vector3.new(3, -7, 1)
	emitter.LightEmission = 0.4
end

local function apply()
	local w = Workspace:GetAttribute("Weather")
	local fx = math.clamp(tonumber(Settings.get("weatherFx")) or 1, 0, 1)
	if w == "Rain" then
		configureRain()
		_targetRate = RAIN_RATE * fx
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
		part.CFrame = CFrame.new(cam.CFrame.Position + Vector3.new(0, 45, 0))
	end
	local rate = emitter.Rate
	if rate ~= _targetRate then
		rate = if rate < _targetRate then math.min(rate + RAMP * dt, _targetRate) else math.max(rate - RAMP * dt, _targetRate)
		emitter.Rate = rate
		emitter.Enabled = rate > 0
	end
end)

Workspace:GetAttributeChangedSignal("Weather"):Connect(apply)
Settings.onChanged("weatherFx", apply)
apply()
