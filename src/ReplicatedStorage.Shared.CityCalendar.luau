--!strict
-- The city's calendar. ONE day/night cycle of TimeService is ONE calendar MONTH (the
-- Cities: Skylines 2 model): the sky keeps a slow, playable day while the date, the budget
-- and the seasons move a month per cycle. Cycle 1 is May 2026; within a cycle the date walks
-- the month, the 1st at midnight to its last day just before the next midnight. `frac` is
-- TimeService's linear day fraction (0 = midnight). Seasons are the meteorological ones of
-- the northern hemisphere: Mar-May spring, Jun-Aug summer, Sep-Nov autumn, Dec-Feb winter.

local CityCalendar = {}

export type Season = "Spring" | "Summer" | "Autumn" | "Winter"

local START_YEAR, START_MONTH = 2026, 5
local DAY_MS = 86400000

-- Where each season sits on the year (0 = 1 Jan): the middle of its three months.
CityCalendar.SEASON_MIDPOINT = table.freeze({
	Winter = 0.5 / 12,
	Spring = 3.5 / 12,
	Summer = 6.5 / 12,
	Autumn = 9.5 / 12,
}) :: { [Season]: number }

local SEASON_OF_MONTH: { Season } = table.freeze({
	"Winter", "Winter", "Spring", "Spring", "Spring", "Summer",
	"Summer", "Summer", "Autumn", "Autumn", "Autumn", "Winter",
})

-- Month (1-12) and year of cycle `day`.
local function monthOf(day: number): (number, number)
	local m = (START_MONTH - 1) + (math.max(1, math.floor(day)) - 1)
	return m % 12 + 1, START_YEAR + m // 12
end

-- The calendar date `frac` of the way through cycle `day`.
function CityCalendar.dateAt(day: number, frac: number): DateTime
	local month, year = monthOf(day)
	local first = DateTime.fromUniversalTime(year, month, 1).UnixTimestampMillis
	local nextFirst = if month == 12
		then DateTime.fromUniversalTime(year + 1, 1, 1).UnixTimestampMillis
		else DateTime.fromUniversalTime(year, month + 1, 1).UnixTimestampMillis
	local days = (nextFirst - first) // DAY_MS
	local dayOfMonth = math.clamp(math.floor(frac * days), 0, days - 1)
	return DateTime.fromUnixTimestampMillis(first + dayOfMonth * DAY_MS)
end

function CityCalendar.seasonForDay(day: number): Season
	return SEASON_OF_MONTH[(monthOf(day))]
end

-- How far through its year the moment is: 0 = 1 Jan, just under 1 = the end of December.
function CityCalendar.yearFraction(day: number, frac: number): number
	local month = monthOf(day)
	return ((month - 1) + math.clamp(frac, 0, 1)) / 12 % 1
end

return CityCalendar
