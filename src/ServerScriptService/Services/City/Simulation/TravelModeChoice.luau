--!strict
-- TravelModeChoice
-- How a citizen gets somewhere: on foot, by public transport, or in their own car. Pure
-- library: CitizenService gathers the facts of one trip and this turns them into a choice.
--
-- It is the model transport planners use (random-utility mode choice). Every mode gets a
-- GENERALISED COST in seconds: time, with the unpleasant parts weighted up, plus money
-- converted through the value of time. Lower costs attract a greater share. The randomness is
-- PERSONAL and stable -- each citizen carries a fixed taste per mode, seeded by their pid --
-- so the same person makes the same choice for the same trip day after day (a habit), while
-- two neighbours can differ. What changes a habit is the city: a bus line that arrives, a
-- street whose parking fills up, a fare the player raises.
--
-- Where the weights come from:
--   * Walking to a stop and waiting for it are felt at ~2-2.5x the same time spent riding
--     (TCRP Report 166 app. E; FTA mode-choice guidance).
--   * A car trip carries "terminal time" at each end -- getting to the car, parking it,
--     walking in -- on top of the drive, ~1-5 min per end (four-step model practice), plus
--     the search for a bay: seconds where bays are free, 3.5-14 min in a full downtown
--     (Shoup 2006; Millard-Ball 2020). Here it is the real distance to the nearest free bay.
--   * ~92% of US households own a car and there are ~1.9 per household (ACS 2022), so about
--     nine adults in ten have one of their own.
--   * The average US walk trip is under a mile (NHTS 2017); long walks fall off fast.
--   * Seniors weigh comfort ahead of time (the Cities: Skylines II agent model).
--   * Rain cuts walking trips by roughly a fifth and snow by more; people walk less after
--     dark; and nobody carries a week's shopping far (Boecker, Dijst & Prillwitz 2013 review
--     of weather and travel; NHTS trip-purpose splits). Waiting at a stop in the rain is worse.
--   * Paid parking is a money cost at the destination like any other (Shoup 2006). Bays are
--     priced by how full the street is (ParkingService.priceAt): free where there is room,
--     dearer where the kerb is packed -- so a busy downtown pushes people onto the bus while a
--     suburb with spare kerb stays car country. The player's city decides, not a constant.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local WS = RoadConstants.WORLD_SCALE
local Const = require(script.Parent.Parent.CitySimConstants)
local CHOICE_POWER = Const.TRAVEL_CHOICE_POWER

local TravelModeChoice = {}

-- Speeds the estimate assumes -- the SAME speeds the sim moves people at, or every choice
-- would be made on a lie.
local WALK_SPEED        = 5 * WS  -- studs/s, NPCWalkingService.WALK_SPEED (1.25 m/s)
local WALK_DETOUR       = 1.2     -- straight line -> pavement distance
local DRIVE_SPEED       = 13      -- studs/s door to door incl. junctions (~23 km/h urban)
local DRIVE_DETOUR      = 1.3     -- straight line -> road distance

local OUT_OF_VEHICLE    = 2.0     -- weight on walking to/from a vehicle
local WAIT_WEIGHT       = 2.5     -- weight on standing at a stop
local WALK_FATIGUE      = 600     -- s of walking after which it feels twice as long
local TERMINAL_SECONDS  = Const.TRAVEL_TERMINAL_SECONDS      -- per trip end: to the car, into and out of the bay
local BOARDING_SECONDS  = 60      -- the hassle of a bus itself: ticket, crowd, timetable
local NO_PARKING_SECONDS = Const.TRAVEL_NO_PARKING_SECONDS    -- nowhere legal to leave the car at all
local MONEY_SECONDS     = 7       -- seconds of travel one unit of city money is worth
local CAR_BASE_COST     = 3       -- per trip: fuel for the short hops, wear
local CAR_COST_PER_1K   = 2       -- per 1000 studs driven
local TASTE_SPREAD      = 0.35    -- personal taste: each mode's cost scaled by e^(+-0.35)
local SENIOR_AGE        = 60
local SENIOR_WALK_PER_YEAR = 0.04 -- extra weight on walking per year past SENIOR_AGE
local CAR_OWNERSHIP     = 0.9     -- share of adults with a car of their own
-- How much worse walking (and waiting at a stop) feels by the conditions of the trip.
local RAIN_WALK         = 1.5
local SNOW_WALK         = 2.0
local RAIN_WAIT         = 1.3
local DARK_WALK         = 1.3
local CARRY_WALK        = 1.3     -- a shopping trip: the bags come home too
local ESCORT_ROUND_TRIP = 1.6     -- a school run: out and back for the parent (no parking search home)

export type TransitOption = {
	timeSeconds: number, fare: number,
	walkSeconds: number, waitSeconds: number, rideSeconds: number,
}

export type Trip = {
	pid: number,
	age: number,
	purpose: string?,
	distance: number,          -- flat studs, door to door
	canDrive: boolean,         -- owns a car and it is free for this trip
	parkWalk: number?,         -- studs from the nearest free bay to the door; nil = none
	congestion: number?,       -- slowdown on the roads between (1 = free flow, BPR factor)
	transit: TransitOption?,   -- best public-transport option, if any line serves the trip
	parkPrice: number?,        -- city money to leave the car at the destination (nil/0 = free)
	weather: string?,          -- "Clear" | "Cloudy" | "Rain" | "Snow" (workspace "Weather")
	dark: boolean?,            -- the trip is made after dark
	carrying: boolean?,        -- coming home with the shopping
}

export type Costs = { walk: number, drive: number?, transit: number? }

-- Stable 0..1 per (person, salt). Same person, same answer, forever.
local function unit(pid: number, salt: number): number
	return Random.new(pid * 16 + salt):NextNumber()
end

local function taste(pid: number, salt: number): number
	return math.exp((unit(pid, salt) * 2 - 1) * TASTE_SPREAD)
end

function TravelModeChoice.ownsCar(pid: number): boolean
	return unit(pid, 7) < CAR_OWNERSHIP
end

function TravelModeChoice.ageGroup(age: number): string
	return if age < 13 then "children" elseif age < 18 then "teens"
		elseif age < SENIOR_AGE then "adults" else "seniors"
end

local function weights(trip: Trip): (number, number)
	local group = TravelModeChoice.ageGroup(trip.age)
	local profile = Const.TRAVEL_AGE_PROFILES[group]
	local time = profile.time
	if trip.purpose == "work" or trip.purpose == "school" then time *= Const.TRAVEL_WORK_TIME_WEIGHT
	elseif group == "seniors" and trip.purpose == "leisure" then time *= Const.TRAVEL_SENIOR_LEISURE_TIME_WEIGHT end
	return time, profile.money
end

-- How much worse a minute on foot feels on this trip: rain or snow, the dark.
local function outdoors(trip: Trip): number
	local w = if trip.weather == "Snow" then SNOW_WALK elseif trip.weather == "Rain" then RAIN_WALK else 1
	return w * (if trip.dark then DARK_WALK else 1)
end

function TravelModeChoice.walkCost(trip: Trip): number
	local seconds = trip.distance * WALK_DETOUR / WALK_SPEED
	local weight = 1 + math.max(0, trip.age - SENIOR_AGE) * SENIOR_WALK_PER_YEAR
	local time = weights(trip)
	local load = if trip.carrying or trip.purpose == "shop" then CARRY_WALK else 1
	return seconds * weight * (1 + seconds / WALK_FATIGUE) * time * outdoors(trip) * load * taste(trip.pid, 1)
end

function TravelModeChoice.driveCost(trip: Trip): number?
	if not trip.canDrive or trip.age < 18 or trip.parkWalk == nil then
		return nil
	end
	local road = trip.distance * DRIVE_DETOUR
	local driveSeconds = road / DRIVE_SPEED * (trip.congestion or 1)
	local terminal = TERMINAL_SECONDS * 2
	if trip.parkWalk then
		-- Walk from the bay (in whatever the weather is doing), plus cruising the block to find it.
		terminal += trip.parkWalk / WALK_SPEED * outdoors(trip) + trip.parkWalk / DRIVE_SPEED
	else
		terminal += NO_PARKING_SECONDS
	end
	local money = CAR_BASE_COST + CAR_COST_PER_1K * road / 1000 + math.max(0, trip.parkPrice or 0)
	local time, moneyWeight = weights(trip)
	return ((driveSeconds + terminal * OUT_OF_VEHICLE) * time + money * MONEY_SECONDS * moneyWeight) * taste(trip.pid, 2)
end

function TravelModeChoice.transitCost(trip: Trip): number?
	local t = trip.transit
	if not t then
		return nil
	end
	local comfort = 1 + math.max(0, trip.age - SENIOR_AGE) * SENIOR_WALK_PER_YEAR * 0.5
	local time, moneyWeight = weights(trip)
	local wet = if trip.weather == "Rain" or trip.weather == "Snow" then RAIN_WAIT else 1
	return ((t.rideSeconds + t.walkSeconds * OUT_OF_VEHICLE * comfort * outdoors(trip)
		+ t.waitSeconds * WAIT_WEIGHT * wet + BOARDING_SECONDS) * time
		+ t.fare * MONEY_SECONDS * moneyWeight) * taste(trip.pid, 3)
end

local function pull(cost: number?): number
	return if cost then 1 / math.max(1, cost) ^ CHOICE_POWER else 0
end

-- "walk" | "transit" | "drive", plus every cost it weighed (for the inspect panel).
function TravelModeChoice.choose(trip: Trip): (string, Costs)
	local costs: Costs = {
		walk = TravelModeChoice.walkCost(trip),
		drive = TravelModeChoice.driveCost(trip),
		transit = TravelModeChoice.transitCost(trip),
	}
	-- Stable random utility gives cheaper modes a majority, rather than making
	-- every resident below one distance threshold behave identically.
	local walkWeight = pull(costs.walk)
	local driveWeight = pull(costs.drive)
	local transitWeight = pull(costs.transit)
	local draw = unit(trip.pid, 4) * (walkWeight + driveWeight + transitWeight)
	if draw < walkWeight then return "walk", costs end
	if draw < walkWeight + driveWeight then return "drive", costs end
	return "transit", costs
end

-- The school run: whether a parent at home drives this child to school rather than the child
-- walking or taking the bus. The child's own walk and bus costs against the parent's drive
-- (`driverAge`, the parent's car and parking), on the child's stable taste -- so the same
-- family does the same thing every morning, a far school gets driven to, and rain fills the
-- school gates with cars.
function TravelModeChoice.escorts(trip: Trip, driverAge: number): boolean
	local driver = table.clone(trip)
	driver.age = driverAge
	driver.canDrive = true
	local drive = TravelModeChoice.driveCost(driver)
	if not drive then return false end
	local walkWeight = pull(TravelModeChoice.walkCost(trip))
	local transitWeight = pull(TravelModeChoice.transitCost(trip))
	-- The parent drives there AND back: the run costs them more than the child's one way.
	local driveWeight = pull(drive * ESCORT_ROUND_TRIP)
	return unit(trip.pid, 5) * (walkWeight + transitWeight + driveWeight) >= walkWeight + transitWeight
end

return TravelModeChoice
