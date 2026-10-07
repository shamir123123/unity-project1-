--!strict
-- The day and the year blends wrap and never jump. No framework -- `require(script).run()`
-- asserts. A key typed out of order, or a typo'd hour or midpoint, shows up here as a step:
-- sample() walks the keys in order, so a misplaced one makes the light snap instead of fade.

local SkyLightingView = require(script.Parent)

local spec = {}

local function level(c: Color3): number
	return c.R + c.G + c.B
end

function spec.run()
	local sample = SkyLightingView.sample
	assert(math.abs(sample(0).brightness - sample(24).brightness) < 1e-6, "midnight must wrap")
	assert(math.abs(sample(-1).brightness - sample(23).brightness) < 1e-6, "negative hours wrap")
	assert(sample(0).brightness < sample(12).brightness, "night must be darker than noon")
	assert(level(sample(0).sky) < level(sample(12).sky), "night sky fill must be darker than noon")

	-- One in-game minute apart, nothing may move by more than a small fraction of its range.
	local prev = sample(0)
	for minute = 1, 24 * 60 do
		local k = sample(minute / 60)
		assert(math.abs(k.brightness - prev.brightness) < 0.05, "brightness jumps at minute " .. minute)
		assert(math.abs(level(k.sky) - level(prev.sky)) < 0.03, "sky fill jumps at minute " .. minute)
		prev = k
	end

	-- The year: New Year wraps, winter is dimmer than summer, and no calendar day jumps.
	local season = SkyLightingView.sampleSeason
	assert(math.abs(season(0).brightness - season(0.99999).brightness) < 1e-3, "New Year must wrap")
	assert(season(0.04).brightness < season(0.54).brightness, "winter must be dimmer than summer")
	local last = season(0)
	for day = 1, 360 do
		local s = season(day / 360)
		assert(math.abs(s.brightness - last.brightness) < 0.01, "season brightness jumps at day " .. day)
		assert(math.abs(s.cover - last.cover) < 0.01, "season cloud cover jumps at day " .. day)
		last = s
	end
end

return spec
