--!strict
-- Cycles land on the right month and season. No framework -- `require(script).run()` asserts.

local CityCalendar = require(script.Parent)

local spec = {}

local function date(day: number, frac: number)
	return CityCalendar.dateAt(day, frac):ToUniversalTime()
end

function spec.run()
	local t = date(1, 0)
	assert(t.Year == 2026 and t.Month == 5 and t.Day == 1, "cycle 1 opens on 1 May 2026")
	t = date(1, 0.5)
	assert(t.Month == 5 and t.Day == 16, "noon of cycle 1 is mid-May")
	t = date(1, 0.9999)
	assert(t.Month == 5 and t.Day == 31, "the end of cycle 1 is 31 May")
	t = date(10, 0.9999)
	assert(t.Year == 2027 and t.Month == 2 and t.Day == 28, "cycle 10 is February 2027, 28 days")
	assert(CityCalendar.seasonForDay(1) == "Spring", "May is spring")
	assert(CityCalendar.seasonForDay(2) == "Summer", "June is summer")
	assert(CityCalendar.seasonForDay(5) == "Autumn", "September is autumn")
	assert(CityCalendar.seasonForDay(8) == "Winter", "December is winter")
	assert(CityCalendar.seasonForDay(11) == "Spring", "March is spring")
	-- The year position moves smoothly through each cycle and carries on into the next,
	-- except once a year at New Year.
	local prev = CityCalendar.yearFraction(1, 0)
	local wraps = 0
	for step = 1, 30 * 24 * 10 do
		local day = 1 + step // 240
		local f = CityCalendar.yearFraction(day, (step % 240) / 240)
		assert(f >= 0 and f < 1, "yearFraction stays in [0, 1)")
		if f < prev then
			wraps += 1
		else
			assert(f - prev < 0.001, "yearFraction jumps at step " .. step)
		end
		prev = f
	end
	assert(wraps == 2, "30 cycles from May 2026 cross New Year twice, crossed " .. wraps)
end

return spec
