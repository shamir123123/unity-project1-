--!strict
-- WeatherService
-- The city's weather, one spell at a time: Clear -> Cloudy -> Rain or Clear -> Cloudy ...
-- so rain always arrives under clouds that built up first, and clears the same way. Each
-- spell lasts a random number of in-game hours from the current season's climate (short
-- summer showers, long grey autumns). Runs on TimeService's clock, so it pauses with the
-- game and speeds up with it. Publishes workspace "Weather" (Clear | Cloudy | Rain) for
-- every client. No snow in the cycle yet; staff can still preview it.
-- Visual only: nothing in the sim reads the weather.

local Workspace = game:GetService("Workspace")

local WeatherService = {}

type Spell = { number } -- { shortest, longest } in in-game hours
type Climate = { Clear: Spell, Cloudy: Spell, Rain: Spell, rainChance: number }

-- One in-game hour is one real minute at 1x.
local CLIMATE: { [string]: Climate } = table.freeze({
	Spring = { Clear = { 4, 12 }, Cloudy = { 1.5, 4 }, Rain = { 1.5, 4 }, rainChance = 0.55 },
	Summer = { Clear = { 8, 20 }, Cloudy = { 1, 3 }, Rain = { 0.75, 2 }, rainChance = 0.35 },
	Autumn = { Clear = { 3, 10 }, Cloudy = { 2, 6 }, Rain = { 2, 5 }, rainChance = 0.6 },
	Winter = { Clear = { 3, 10 }, Cloudy = { 3, 8 }, Rain = { 1.5, 4 }, rainChance = 0.4 },
})
local WEATHERS: { [string]: boolean } = table.freeze({ Clear = true, Cloudy = true, Rain = true, Snow = true })
local POLL_SECONDS = 1
-- A clock jump this big (a city loading, a staff time change) starts a fresh clear spell.
local JUMP_HOURS = 3

local _timeService: any
local _rng = Random.new()
local _weather = "Clear"
local _endsAt = 0 -- in-game hours since day 1
local _lastHours: number? = nil
local _started = false

local function hoursNow(): number
	return (_timeService.getDay() - 1 + _timeService.getDayFraction()) * 24
end

local function climate(): Climate
	return CLIMATE[_timeService.getSeason()] or CLIMATE.Summer
end

local function begin(weather: string, now: number)
	_weather = weather
	-- Snow is staff-only for now; it borrows rain's length.
	local spell = climate()[if weather == "Snow" then "Rain" else weather] :: Spell
	_endsAt = now + _rng:NextNumber(spell[1], spell[2])
	Workspace:SetAttribute("Weather", weather)
end

local function nextWeather(): string
	if _weather == "Cloudy" then
		return if _rng:NextNumber() < climate().rainChance then "Rain" else "Clear"
	end
	return "Cloudy"
end

local function step()
	local now = hoursNow()
	local last = _lastHours
	_lastHours = now
	if not last or math.abs(now - last) > JUMP_HOURS then
		begin("Clear", now)
	elseif now >= _endsAt then
		begin(nextWeather(), now)
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
