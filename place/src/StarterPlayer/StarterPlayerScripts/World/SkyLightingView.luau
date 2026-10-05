--!strict
-- SkyLightingView -- the colour of the sky and its light, from three clocks:
--   * the HOUR (Lighting.ClockTime): golden dawn and dusk, white noon, and a blue moonlit
--     night dark enough to read as night but bright enough to build in
--   * the YEAR (workspace YearFraction, TimeService's calendar): pale cold winters, warm
--     summers, golden autumns, drifting a little every calendar day
--   * the WEATHER (workspace Weather, WeatherService): clouds build, the light greys and
--     dims under rain, and it all eases back as the sky clears
-- Client-only and purely visual, polled at 4 Hz and TWEENED between polls, so the light
-- never steps: each poll glides to its target over exactly one poll, and a jump (admin
-- time change, the day/night setting, a city load) fades over JUMP_FADE_SECONDS.
--
-- Owns ONLY sun/moon light, ambient, the sky's haze COLOUR and the clouds. Settings owns
-- exposure, the colour grade, bloom and haze density; TerritoryController borrows
-- Haze/Density while its overview is open. None of those are written here, so nothing fights.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CityCalendar = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CityCalendar"))

local SkyLightingView = {}

export type Key = {
	hour: number,
	brightness: number, -- Lighting.Brightness: the sun by day, the moon by night
	sun: Color3, -- ColorShift_Top: tint of the sun/moon light
	bounce: Color3, -- ColorShift_Bottom: light bounced back up onto faces turned away
	sky: Color3, -- OutdoorAmbient: shadow fill from the open sky
	indoor: Color3, -- Ambient: fill where the sky cannot reach
	haze: Color3, -- Atmosphere.Color
	decay: Color3, -- Atmosphere.Decay: haze colour away from the sun
	glare: number, -- Atmosphere.Glare: the glow around a low sun
	cloud: Color3, -- Clouds.Color
}

-- A season is a nudge on top of the hour: colours are MULTIPLIERS (white = unchanged).
type SeasonLook = { at: number, sun: Color3, sky: Color3, haze: Color3, brightness: number, cover: number }

-- What the weather does to the hour's light. `grey` desaturates towards the colour's own
-- brightness, so overcast greys the night as much as the noon without lightening it. `sky`
-- RAISES the fill under cloud: a black overcast sky gives no environment light, so the
-- ambient has to carry the soft, shadowless light a grey day really has.
type WeatherLook = { dim: number, grey: number, sky: number, haze: number, glare: number, cover: number, density: number, cloud: number }

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function key(hour: number, brightness: number, sun: Color3, bounce: Color3, sky: Color3, indoor: Color3, haze: Color3, decay: Color3, glare: number, cloud: Color3): Key
	return table.freeze({
		hour = hour, brightness = brightness, sun = sun, bounce = bounce, sky = sky,
		indoor = indoor, haze = haze, decay = decay, glare = glare, cloud = cloud,
	})
end

-- Sun elevation (latitude 41): 0 deg at 06:00 and 18:00, -10 deg at 05:18 / 18:42,
-- -19 deg (full dark) at 04:36 / 19:24. Keys are hour-sorted; 0 and 24 are the same
-- moment so the blend wraps through midnight. Twilight carries MORE sky fill than night:
-- the moon is only a few degrees up then, and its grazing light alone reads darker than
-- midnight.
local NIGHT = { 2, rgb(150, 178, 235), rgb(16, 20, 34), rgb(82, 96, 136), rgb(30, 34, 50), rgb(36, 48, 80), rgb(16, 22, 42), 0, rgb(70, 80, 104) }
local DAY = { 3.2, rgb(255, 240, 218), rgb(62, 56, 48), rgb(104, 112, 130), rgb(44, 46, 54), rgb(176, 200, 230), rgb(96, 116, 150), 0.4, rgb(250, 250, 252) }

local function from(hour: number, v: { any }): Key
	return key(hour, v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9])
end

local KEYS: { Key } = table.freeze({
	from(0, NIGHT),
	from(4.6, NIGHT),
	key(5.3, 2.2, rgb(170, 168, 214), rgb(30, 30, 46), rgb(118, 124, 162), rgb(36, 36, 52), rgb(122, 130, 172), rgb(58, 64, 104), 0.2, rgb(176, 164, 188)), -- dawn blue
	key(6.0, 2.2, rgb(255, 146, 80), rgb(64, 48, 40), rgb(116, 108, 124), rgb(38, 38, 46), rgb(252, 180, 136), rgb(142, 122, 160), 1.0, rgb(255, 194, 164)), -- sunrise
	key(6.8, 2.9, rgb(255, 200, 136), rgb(70, 58, 44), rgb(108, 112, 130), rgb(42, 44, 52), rgb(222, 208, 204), rgb(122, 128, 162), 0.6, rgb(255, 234, 214)), -- morning gold
	from(8.5, DAY),
	from(15.5, DAY),
	key(17.2, 3.0, rgb(255, 190, 120), rgb(74, 58, 42), rgb(112, 110, 126), rgb(44, 44, 52), rgb(232, 204, 180), rgb(128, 128, 164), 0.7, rgb(255, 230, 204)), -- afternoon gold
	key(18.0, 2.4, rgb(255, 128, 60), rgb(70, 46, 40), rgb(118, 100, 118), rgb(40, 36, 46), rgb(255, 168, 120), rgb(150, 116, 156), 1.2, rgb(255, 176, 146)), -- sunset
	key(18.7, 2.2, rgb(176, 160, 214), rgb(30, 30, 46), rgb(122, 122, 164), rgb(36, 36, 52), rgb(110, 120, 172), rgb(54, 60, 104), 0.2, rgb(168, 150, 180)), -- dusk blue
	from(19.4, NIGHT),
	from(24, NIGHT),
})

local function season(at: number, sun: Color3, sky: Color3, haze: Color3, brightness: number, cover: number): SeasonLook
	return table.freeze({ at = at, sun = sun, sky = sky, haze = haze, brightness = brightness, cover = cover })
end

local MID = CityCalendar.SEASON_MIDPOINT
local WINTER = { Color3.new(0.93, 0.97, 1.05), Color3.new(0.95, 0.99, 1.07), Color3.new(0.95, 0.98, 1.05), 0.86, 0.6 }
local SPRING = { Color3.new(1, 1, 0.98), Color3.new(0.98, 1.02, 1), Color3.new(1, 1, 1), 1, 0.5 }
local SUMMER = { Color3.new(1, 0.99, 0.95), Color3.new(1.02, 1.01, 0.98), Color3.new(1, 1, 0.99), 1.04, 0.38 }
local AUTUMN = { Color3.new(1, 0.92, 0.8), Color3.new(1.05, 1, 0.92), Color3.new(1.05, 0.98, 0.9), 0.94, 0.52 }

local function seasonAt(at: number, v: { any }): SeasonLook
	return season(at, v[1], v[2], v[3], v[4], v[5])
end

-- Year-sorted around the season midpoints, with autumn repeated before January and winter
-- after December so the blend wraps through New Year.
local SEASONS: { SeasonLook } = table.freeze({
	seasonAt(MID.Autumn - 1, AUTUMN),
	seasonAt(MID.Winter, WINTER),
	seasonAt(MID.Spring, SPRING),
	seasonAt(MID.Summer, SUMMER),
	seasonAt(MID.Autumn, AUTUMN),
	seasonAt(MID.Winter + 1, WINTER),
})

-- Clear's cloud cover is the season's own (breezy spring, big summer skies).
local WEATHER: { [string]: WeatherLook } = table.freeze({
	Clear = table.freeze({ dim = 1, grey = 0, sky = 1, haze = 1, glare = 1, cover = -1, density = 0.55, cloud = 1 }),
	Cloudy = table.freeze({ dim = 0.72, grey = 0.45, sky = 1.06, haze = 0.9, glare = 0.3, cover = 0.82, density = 0.72, cloud = 0.88 }),
	Rain = table.freeze({ dim = 0.58, grey = 0.7, sky = 1.15, haze = 0.72, glare = 0, cover = 0.97, density = 0.9, cloud = 0.66 }),
})
-- Snow is staff-only for now: it looks overcast.
local WEATHER_ALIAS: { [string]: string } = { Snow = "Cloudy" }

local UPDATE_SECONDS = 0.25
-- ~15 in-game seconds: below this the hour blend cannot visibly move.
local MIN_STEP_HOURS = 0.004
-- Real seconds for the sky to finish changing its mind; the rain itself follows the
-- clouds that WeatherService makes build up first.
local WEATHER_BLEND_SECONDS = 40
-- A step this big is a jump, not the clock ticking: fade to it instead of gliding one poll.
local JUMP_HOURS = 0.25
local JUMP_YEAR = 0.01
local JUMP_FADE_SECONDS = 4
-- Linear, so back-to-back poll tweens join into one steady line with no ease pulse.
local POLL_TWEEN = TweenInfo.new(UPDATE_SECONDS, Enum.EasingStyle.Linear)

local _mix: { [string]: number } = { Clear = 1, Cloudy = 0, Rain = 0 }

local function smooth(t: number): number
	return t * t * (3 - 2 * t) -- no visible kink when the blend passes a key
end

local function mul(a: Color3, b: Color3): Color3
	return Color3.new(math.min(a.R * b.R, 1), math.min(a.G * b.G, 1), math.min(a.B * b.B, 1))
end

local function scale(c: Color3, s: number): Color3
	return Color3.new(math.min(c.R * s, 1), math.min(c.G * s, 1), math.min(c.B * s, 1))
end

local function grey(c: Color3, amount: number): Color3
	local l = c.R * 0.3 + c.G * 0.59 + c.B * 0.11
	return c:Lerp(Color3.new(l, l, l), amount)
end

-- The blended hour look for an hour (any number; wrapped to 0..24).
function SkyLightingView.sample(hour: number): Key
	local h = hour % 24
	for i = 1, #KEYS - 1 do
		local a, b = KEYS[i], KEYS[i + 1]
		if h <= b.hour then
			local t = smooth((h - a.hour) / (b.hour - a.hour))
			return {
				hour = h,
				brightness = a.brightness + (b.brightness - a.brightness) * t,
				sun = a.sun:Lerp(b.sun, t),
				bounce = a.bounce:Lerp(b.bounce, t),
				sky = a.sky:Lerp(b.sky, t),
				indoor = a.indoor:Lerp(b.indoor, t),
				haze = a.haze:Lerp(b.haze, t),
				decay = a.decay:Lerp(b.decay, t),
				glare = a.glare + (b.glare - a.glare) * t,
				cloud = a.cloud:Lerp(b.cloud, t),
			}
		end
	end
	return KEYS[#KEYS]
end

-- The blended season look for a point in the year (0 = 1 Jan; wrapped).
function SkyLightingView.sampleSeason(year: number): SeasonLook
	local y = year % 1
	for i = 1, #SEASONS - 1 do
		local a, b = SEASONS[i], SEASONS[i + 1]
		if y <= b.at then
			local t = smooth((y - a.at) / (b.at - a.at))
			return {
				at = y,
				sun = a.sun:Lerp(b.sun, t),
				sky = a.sky:Lerp(b.sky, t),
				haze = a.haze:Lerp(b.haze, t),
				brightness = a.brightness + (b.brightness - a.brightness) * t,
				cover = a.cover + (b.cover - a.cover) * t,
			}
		end
	end
	return SEASONS[#SEASONS]
end

local function weatherGoal(): string
	local w = tostring(Workspace:GetAttribute("Weather"))
	w = WEATHER_ALIAS[w] or w
	return if WEATHER[w] then w else "Clear"
end

-- The weather look under the current mix, with clear skies wearing the season's cover.
local function blendWeather(seasonCover: number): WeatherLook
	local out: any = { dim = 0, grey = 0, sky = 0, haze = 0, glare = 0, cover = 0, density = 0, cloud = 0 }
	local total = 0
	for _, w in _mix do
		total += w
	end
	for name, w in _mix do
		local look: any = WEATHER[name]
		local share = w / total
		for field, v in look do
			local value = if field == "cover" and v < 0 then seasonCover else v
			out[field] += value * share
		end
	end
	return out
end

-- Move the weather mix toward the current weather. True while it is still moving.
local function easeWeather(dt: number): boolean
	local goal = weatherGoal()
	local step = dt / WEATHER_BLEND_SECONDS
	local moving = false
	for name, w in _mix do
		local target = if name == goal then 1 else 0
		if w ~= target then
			_mix[name] = if w < target then math.min(w + step, target) else math.max(w - step, target)
			moving = true
		end
	end
	return moving
end

local function yearNow(): number
	return tonumber(Workspace:GetAttribute("YearFraction")) or MID.Summer
end

-- Jump straight to the current weather: a player joining in the rain sees rain, not a
-- 40-second fade from a clear sky.
function SkyLightingView.snap()
	local goal = weatherGoal()
	for name in _mix do
		_mix[name] = if name == goal then 1 else 0
	end
end

-- Tween `goals` onto `target`, or write them now when there is no `info`.
local function write(target: Instance, goals: { [string]: any }, info: TweenInfo?)
	if not info then
		for prop, value in goals do
			(target :: any)[prop] = value
		end
		return
	end
	TweenService:Create(target, info, goals):Play()
end

-- The look for an hour, at the current point in the year and weather mix. Glides there
-- over `info`, or lands at once without it.
function SkyLightingView.apply(hour: number, info: TweenInfo?)
	local k = SkyLightingView.sample(hour)
	local s = SkyLightingView.sampleSeason(yearNow())
	local w = blendWeather(s.cover)
	-- Clouds steal most of a bright sun but only some of the moon: a rainy night must stay
	-- buildable. 0 at the night key's brightness, 1 at noon's.
	local daylight = math.clamp((k.brightness - NIGHT[1]) / (DAY[1] - NIGHT[1]), 0, 1)
	local dim = 1 - (1 - w.dim) * (0.4 + 0.6 * daylight)
	write(Lighting, {
		Brightness = k.brightness * s.brightness * dim,
		ColorShift_Top = grey(mul(k.sun, s.sun), w.grey),
		ColorShift_Bottom = grey(k.bounce, w.grey),
		OutdoorAmbient = grey(scale(mul(k.sky, s.sky), w.sky), w.grey * 0.5),
		Ambient = k.indoor,
	}, info)
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		write(atmosphere, {
			Color = grey(scale(mul(k.haze, s.haze), w.haze), w.grey),
			Decay = grey(scale(k.decay, w.haze), w.grey),
			Glare = k.glare * w.glare,
		}, info)
	end
	local clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	if clouds then
		write(clouds, { Color = scale(k.cloud, w.cloud), Cover = w.cover, Density = w.density }, info)
	end
end

-- Shortest distance between two readings of a clock that wraps at `period`.
local function gap(a: number, b: number, period: number): number
	local d = math.abs(a - b) % period
	return math.min(d, period - d)
end

function SkyLightingView.Start()
	SkyLightingView.snap()
	local lastHour = Lighting.ClockTime
	local lastYear = yearNow()
	local lastTick = os.clock()
	local fadeUntil = 0
	-- The first look lands at once: a player joining at night must not watch it fade in
	-- from the place's afternoon defaults.
	SkyLightingView.apply(lastHour)
	local function update()
		local now = os.clock()
		local blending = easeWeather(now - lastTick)
		lastTick = now
		local h = Lighting.ClockTime
		local y = yearNow()
		local hourStep, yearStep = gap(h, lastHour, 24), gap(y, lastYear, 1)
		if not blending and yearStep == 0 and hourStep < MIN_STEP_HOURS then
			return
		end
		if hourStep >= JUMP_HOURS or yearStep >= JUMP_YEAR then
			fadeUntil = now + JUMP_FADE_SECONDS
		end
		lastHour, lastYear = h, y
		-- Mid-fade, each poll re-aims the fade at the moving target with the time it has left.
		local left = fadeUntil - now
		SkyLightingView.apply(h, if left > UPDATE_SECONDS then TweenInfo.new(left, Enum.EasingStyle.Linear) else POLL_TWEEN)
	end
	-- ClockTime is rewritten every server heartbeat; polling at 4 Hz keeps this off the
	-- frame path, and TweenService fills the frames in between.
	task.spawn(function()
		while true do
			task.wait(UPDATE_SECONDS)
			local ok, err = pcall(update)
			if not ok then
				warn("[SkyLightingView] update failed: " .. tostring(err))
			end
		end
	end)
end

return SkyLightingView
