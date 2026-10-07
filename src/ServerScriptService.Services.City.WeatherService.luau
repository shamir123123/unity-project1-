--!strict
-- WeatherService
-- The city's weather, one spell at a time: Clear -> Cloudy -> Rain or Clear -> Cloudy ...
-- so rain always arrives under clouds that built up first, and clears the same way. Fog
-- forms on a clear night at first light, or as rain ends, and burns off to Clear. Each spell
-- lasts a random number of in-game hours from the current season's climate (short heavy
-- summer showers, long grey autumns, foggy autumn mornings). Runs on TimeService's clock, so
-- it pauses with the game and speeds up with it. Publishes for every client:
--   workspace "Weather"          Clear | Cloudy | Rain | Fog (Snow: staff only)
--   workspace "WeatherIntensity" 0..1, how hard this spell is (drizzle..downpour, mist..thick)
--   workspace "CloudDrift"       -1..1, slow wander of the cloud cover inside any weather
--   workspace "WindAngle"        degrees, the way the wind blows (rain leans with it)
-- Visual only: nothing in the sim reads the weather except TravelModeChoice (walk vs drive).

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local WeatherService = {}

type Spell = { number } -- { shortest, longest } in in-game hours, or { weakest, strongest }
type Climate = {
	Clear: Spell, Cloudy: Spell, Rain: Spell, Fog: Spell,
	rainChance: number, fogChance: number, rainStrength: Spell,
}

-- One in-game hour is one real minute at 1x.
local CLIMATE: { [string]: Climate } = table.freeze({
	Spring = { Clear = { 4, 12 }, Cloudy = { 1.5, 4 }, Rain = { 1.5, 4 }, Fog = { 1.5, 3.5 },
		rainChance = 0.55, fogChance = 0.3, rainStrength = { 0.3, 0.8 } },
	Summer = { Clear = { 8, 20 }, Cloudy = { 1, 3 }, Rain = { 0.75, 2 }, Fog = { 1, 2.5 },
		rainChance = 0.35, fogChance = 0.15, rainStrength = { 0.55, 1 } },
	Autumn = { Clear = { 3, 10 }, Cloudy = { 2, 6 }, Rain = { 2, 5 }, Fog = { 2, 4 },
		rainChance = 0.6, fogChance = 0.45, rainStrength = { 0.2, 0.75 } },
	Winter = { Clear = { 3, 10 }, Cloudy = { 3, 8 }, Rain = { 1.5, 4 }, Fog = { 2, 5 },
		rainChance = 0.4, fogChance = 0.35, rainStrength = { 0.2, 0.6 } },
})
local WEATHERS: { [string]: boolean } = table.freeze({ Clear = true, Cloudy = true, Rain = true, Fog = true, Snow = true })
local FOG_STRENGTH: Spell = { 0.6, 1 }
local POLL_SECONDS = 1
-- A clock jump this big (a city loading, a staff time change) starts a fresh clear spell.
local JUMP_HOURS = 3
-- Clear nights turn to fog at first light: 05:00 on the DISPLAYED clock (Lighting.ClockTime).
-- TimeService squeezes the night, so the linear hours below would put it near 07:00.
local DAWN_HOUR = 5
local CLOCK_JUMP_HOURS = 1 -- a bigger step on the clock is a time change, not dawn arriving
-- In-game hours for the cloud cover to wander from one shape of sky to the next.
local CLOUD_DRIFT_HOURS = 5
-- User 2026-10-06: rain always blows ONE way for now (it was a random 0..359 per spell).
local WIND_ANGLE = 30

local _timeService: any
local _rng = Random.new()
local _cloudSeed = _rng:NextNumber(0, 1000) + 0.37 -- off-integer: math.noise is 0 on the lattice
local _weather = "Clear"
local _endsAt = 0 -- in-game hours since day 1
local _lastHours: number? = nil
local _lastClock: number? = nil
local _drift: number? = nil
local _started = false

local function hoursNow(): number
	return (_timeService.getDay() - 1 + _timeService.getDayFraction()) * 24
end

local function climate(): Climate
	return CLIMATE[_timeService.getSeason()] or CLIMATE.Summer
end

local function strength(weather: string): number
	local range = if weather == "Rain" or weather == "Snow" then climate().rainStrength
		elseif weather == "Fog" then FOG_STRENGTH
		else nil
	if not range then
		return 0
	end
	return math.round(_rng:NextNumber(range[1], range[2]) * 100) / 100
end

local function begin(weather: string, now: number)
	_weather = weather
	-- Snow is staff-only for now; it borrows rain's length.
	local spell = climate()[if weather == "Snow" then "Rain" else weather] :: Spell
	_endsAt = now + _rng:NextNumber(spell[1], spell[2])
	-- Weather FIRST: a client that sees the new strength or wind while the old name still
	-- reads "Rain" would snap the fading shower to the next spell's look. Starting rain
	-- just reconfigures again as the strength and wind land, in the same frame.
	Workspace:SetAttribute("Weather", weather)
	Workspace:SetAttribute("WeatherIntensity", strength(weather))
	Workspace:SetAttribute("WindAngle", WIND_ANGLE)
end

local function nextWeather(): string
	if _weather == "Cloudy" then
		return if _rng:NextNumber() < climate().rainChance then "Rain" else "Clear"
	elseif _weather == "Rain" then
		return if _rng:NextNumber() < climate().fogChance then "Fog" else "Cloudy"
	elseif _weather == "Fog" then
		return "Clear"
	end
	return "Cloudy"
end

local function dawnArrived(): boolean
	local clock = Lighting.ClockTime
	local last = _lastClock
	_lastClock = clock
	return last ~= nil and last < DAWN_HOUR and clock >= DAWN_HOUR and clock - last < CLOCK_JUMP_HOURS
end

local function publishDrift(now: number)
	local drift = math.clamp(math.noise(now / CLOUD_DRIFT_HOURS, _cloudSeed) * 2, -1, 1)
	drift = math.round(drift * 100) / 100
	if drift ~= _drift then
		_drift = drift
		Workspace:SetAttribute("CloudDrift", drift)
	end
end

local function step()
	local now = hoursNow()
	local last = _lastHours
	_lastHours = now
	publishDrift(now)
	local dawn = dawnArrived()
	if not last or math.abs(now - last) > JUMP_HOURS then
		begin("Clear", now)
	elseif now >= _endsAt then
		begin(nextWeather(), now)
	elseif _weather == "Clear" and dawn and _rng:NextNumber() < climate().fogChance then
		begin("Fog", now)
	end
end

function WeatherService.getWeather(): string
	return _weather
end

-- Staff override: starts a spell of `weather` now; the cycle carries on from it.
function WeatherService.setWeather(weather: string)
	if not WEATHERS[weather] then
		error("[WeatherService] unknown weather: " .. tostring(weather))
	end
	begin(weather, hoursNow())
	_lastHours = hoursNow()
end

function WeatherService.Init(timeService: any)
	if not (timeService and timeService.getDay and timeService.getDayFraction and timeService.getSeason) then
		error("[WeatherService] Init needs TimeService (getDay, getDayFraction, getSeason)")
	end
	_timeService = timeService
end

function WeatherService.Start()
	if _started then
		return
	end
	_started = true
	-- 1 Hz is plenty: the shortest spell is 45 in-game minutes, 15 real seconds at 3x.
	task.spawn(function()
		while true do
			task.wait(POLL_SECONDS)
			local ok, err = pcall(step)
			if not ok then
				warn("[WeatherService] step failed: " .. tostring(err))
			end
		end
	end)
end

return WeatherService
