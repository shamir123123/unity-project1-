--!strict
-- ServiceTypes
-- Shared, immutable catalog of the service buildings: Hospital, Police Station, Fire
-- Station, Cemetery, plus the utilities (Wind Turbine, Power Plant, Water Tower, Sewage Plant). Read by the
-- server (EmergencyService places them + answers coverage),
-- the placement UI (cards + footprint ghost) and ServiceBuildingModel (placeholder geometry).
-- Pure data -- no lifecycle, no side effects on require. Mirrors SchoolTypes so the Services
-- flyout and ServiceFootprint can treat both catalogs the same way.
--
-- Footprints are measured in LOTS (16-stud zone tiles), so a placed building occupies a block
-- of the very grid the player zones on. `coverageRadius` is the service reach in studs. `kind`
-- is the coverage domain the building provides: "Hospital" (healthcare), "Police" or "Fire".
--
-- PLACEMENT -- the user's categories (2026-10-05). Everything can go anywhere on the map;
-- what differs is what helps it and what stops it:
--   * a building (the default): snaps to a road and faces it when the cursor is near one,
--     and only its footprint blocks. No ring round it -- a coal plant claims its plot, not
--     a circle.
--   * placement = "Free": no road snap, it stands where the cursor is. The turbines: their
--     footprint is the base, so `bladeRadius` keeps two rotors from crossing.
--   * a line (PowerPole, the pipes): drawn, not placed -- routed to its tool by `kind`.
--   * shore = true: a building that must touch open water.

local LOT_SIZE = 16 -- full-size lot unit; ServiceBuildingModel ScaleTo()s the finished building
-- Half-size world: coverage/pollution reach scales so a station serves the same houses.
local WORLD_SCALE = require(game:GetService("ReplicatedStorage").Road.RoadConstants).WORLD_SCALE

local ServiceTypes = {}

export type Spec = {
	key: string,
	name: string,
	desc: string,
	kind: string,            -- "Hospital" | "Police" | "Fire" | "Deathcare" | "Power" | "Water" | "Sewage" | "Pipe" (coverage domain)
	category: string,        -- UI grouping label ("Emergency" | "Utilities")
	widthLots: number,       -- footprint along the road, in lots
	depthLots: number,       -- footprint back from the road, in lots
	height: number,          -- body height, studs
	coverageRadius: number,  -- service reach, studs
	cost: number,            -- treasury cost to place
	pollution: number?,      -- point-source pollution strength (dirty utilities)
	pollutionRadius: number?,-- pollution falloff radius, studs
	capacity: number?,       -- graves (Deathcare): burials this building holds
	powerOutput: number?,    -- kW this building generates (CS1 counts electricity in kW)
	solar: boolean?,         -- output follows the sun: powerOutput is the NOON PEAK, not a flat rate
	jobs: number?,           -- staff slots this building employs (CitizenService fills them)
	waterOutput: number?,    -- m3/week a water source pours into the network (WaterService)
	sewageCapacity: number?, -- m3/week of wastewater a plant treats (WaterService)
	powerUse: number?,       -- kW a facility draws; without it, it makes nothing (WaterService)
	waterUse: number?,       -- m3/week a facility takes from the mains
	sewageShare: number?,    -- of that, the part that goes down the drain (default 1; if it needs Sewage)
	needs: { string }?,      -- the utilities it takes ("Power" | "Water" | "Sewage"); nil = usesUtility's default
	upkeep: number?,         -- $ a month to keep it standing; nil = UPKEEP_UTILITY_FRACTION of `cost`
	runCost: number?,        -- $ a month per unit it actually makes or handles: kW for a generator (PowerService:
	                         -- fuel, wear), m3/week for a water or sewage works (WaterService: chemicals, sludge)
	shore: boolean?,         -- must stand with its edge in open water (pumps, outlets)
	placement: string?,      -- "Free": no road snap (see PLACEMENT); nil = a building
	bladeRadius: number?,    -- turbines: the rotor's reach, studs; two rings may not overlap
	ambulances: number?,     -- healthcare: ambulances this building stations (also the
	                         -- number of marked bays on its apron)
	footprint: Vector3,      -- derived X*Z ground size (studs), Y body height
	wall: Color3,
	roof: Color3,
	accent: Color3,
}

-- Healthcare comes in four tiers: Clinic -> Small Hospital -> Hospital -> General
-- Hospital. Each is its OWN building on its OWN floor plan -- L, T, U and H -- with
-- parking reached by a driveway off the road. The authored meshes in
-- Templates.Asset.Building.Services are the real art; ServiceBuildingModel's four
-- procedural builders are the fallback, and both read the footprints below. Bigger tiers reach further, station more
-- ambulances and cost more to run; upkeep is a fraction of `cost`
-- (CityEconomyService.monthlyUpkeep), so the ladder balances itself.
local MED_WALL   = Color3.fromRGB(238, 240, 242)
local MED_ROOF   = Color3.fromRGB(176, 186, 196)
local MED_ACCENT = Color3.fromRGB(206, 70, 66)

local DEFS: { [string]: Spec } = {
	Clinic = {
		key = "Clinic", name = "Clinic", desc = "Basic care for one neighbourhood. Cheap to build, cheap to run, short reach.",
		kind = "Hospital", category = "Emergency", widthLots = 3, depthLots = 3, height = 10,
		coverageRadius = 120 * WORLD_SCALE, cost = 2500, ambulances = 3,
		jobs = 12, powerUse = 40, waterUse = 30,
		footprint = Vector3.new(3 * LOT_SIZE, 10, 3 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	SmallHospital = {
		key = "SmallHospital", name = "Small Hospital", desc = "A T-plan brick ward wing under a glazed barrel atrium, with five ambulances on call.",
		kind = "Hospital", category = "Emergency", widthLots = 4, depthLots = 4, height = 15,
		coverageRadius = 170 * WORLD_SCALE, cost = 6500, ambulances = 5,
		jobs = 35, powerUse = 150, waterUse = 120,
		footprint = Vector3.new(4 * LOT_SIZE, 15, 4 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	Hospital = {
		key = "Hospital", name = "Hospital", desc = "Keeps citizens healthy. Without one, people fall ill and die.",
		kind = "Hospital", category = "Emergency", widthLots = 5, depthLots = 4, height = 24,
		coverageRadius = 240 * WORLD_SCALE, cost = 15000, ambulances = 6,
		jobs = 80, powerUse = 400, waterUse = 300,
		footprint = Vector3.new(5 * LOT_SIZE, 24, 4 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	GeneralHospital = {
		key = "GeneralHospital", name = "General Hospital", desc = "City-scale care: an H-plan of ward slabs around a ten-bay ambulance yard, with a rooftop helipad.",
		kind = "Hospital", category = "Emergency", widthLots = 6, depthLots = 5, height = 38,
		coverageRadius = 380 * WORLD_SCALE, cost = 32000, ambulances = 10,
		jobs = 160, powerUse = 900, waterUse = 700,
		footprint = Vector3.new(6 * LOT_SIZE, 38, 5 * LOT_SIZE),
		wall = MED_WALL, roof = MED_ROOF, accent = MED_ACCENT,
	},
	PoliceStation = {
		key = "PoliceStation", name = "Police Station", desc = "Cuts crime nearby. Without one, robberies rise and happiness falls.",
		kind = "Police", category = "Emergency", widthLots = 3, depthLots = 2, height = 15,
		coverageRadius = 210 * WORLD_SCALE, cost = 8000,
		jobs = 25, powerUse = 50, waterUse = 25,
		footprint = Vector3.new(3 * LOT_SIZE, 15, 2 * LOT_SIZE),
		wall = Color3.fromRGB(70, 82, 104), roof = Color3.fromRGB(40, 48, 64), accent = Color3.fromRGB(86, 140, 210),
	},
	FireStation = {
		key = "FireStation", name = "Fire Station", desc = "Puts out fires in range. Without one, fires spread house to house.",
		kind = "Fire", category = "Emergency", widthLots = 3, depthLots = 2, height = 15,
		coverageRadius = 210 * WORLD_SCALE, cost = 8000,
		jobs = 20, powerUse = 40, waterUse = 60, sewageShare = 0.6, -- drills and engine washdowns soak away
		footprint = Vector3.new(3 * LOT_SIZE, 15, 2 * LOT_SIZE),
		wall = Color3.fromRGB(150, 46, 40), roof = Color3.fromRGB(96, 30, 26), accent = Color3.fromRGB(244, 206, 96),
	},
	Cemetery = {
		key = "Cemetery", name = "Cemetery", desc = "Buries the deceased in range. Without one, bodies pile up and families leave.",
		kind = "Deathcare", category = "Emergency", widthLots = 3, depthLots = 3, height = 8,
		coverageRadius = 280 * WORLD_SCALE, cost = 7000, capacity = 60,
		jobs = 4, powerUse = 5, waterUse = 15, sewageShare = 0.2, -- mostly the lawns' watering
		footprint = Vector3.new(3 * LOT_SIZE, 8, 3 * LOT_SIZE),
		wall = Color3.fromRGB(206, 210, 214), roof = Color3.fromRGB(96, 104, 112), accent = Color3.fromRGB(142, 168, 142),
	},
	-- UTILITY NUMBERS (user 2026-10-07: "2,000 people needed five coal plants -- not realistic"). Real per-head
	-- demand (PowerService: 0.5 kW a resident, 1-4 kW a job; WaterService: 2.1 m3/week a head = 300 L/day) and
	-- outputs sized so a small town runs on a couple of turbines and a coal plant carries a city of 50,000+.
	-- MONEY (user 2026-10-07): build prices never change. Upkeep and running costs are sized against the tax
	-- take (~556 a resident a month at the default rate) so a city's utilities cost about a seventh of its
	-- income, as a real city's do: a standing `upkeep` plus a `runCost` per unit actually made or handled, so a
	-- small town pays for what it uses rather than for a half-empty plant (power ~20, water ~28, sewage ~30 a
	-- resident a month). CityEconomyService takes the same share back off its City services stand-in.
	-- A budget slider (CS-style: more money, more output) comes later -- it would scale both here.
	-- What each needs is the user's list: turbines water, solar and coal water + sewage (they make their own
	-- power), water works power, the sewage plants power + water for their staff, the pumping station's staff a
	-- drain. Civic buildings: jobs, kW and m3 from real staffing and use (a hospital ~ 1 kW and 1 m3/week a bed).
	-- A land wind turbine: 2.5 MW (a real 2-3 MW machine), flat rather than riding
	-- the weather. Real size (PowerKit WindTurbine_Small: 60 m hub, 33 m blades). The
	-- footprint is the base -- plinth, stair, transformer; the blades are `bladeRadius`.
	-- `coverageRadius` is the yard a line or a road has to reach to take its power.
	WindTurbine = {
		key = "WindTurbine", name = "Wind Turbine", desc = "Clean power for a small area. Cheap to run, gentle on the air.",
		kind = "Power", category = "Utilities", placement = "Free", widthLots = 2, depthLots = 2, height = 186,
		coverageRadius = 20, cost = 3500, upkeep = 8000, runCost = 8,
		powerOutput = 2500, bladeRadius = 66, needs = {}, -- no water, no sewage (user 2026-10-07): a turbine takes nothing
		footprint = Vector3.new(2 * LOT_SIZE, 186, 2 * LOT_SIZE),
		wall = Color3.fromRGB(240, 242, 244), roof = Color3.fromRGB(126, 132, 140), accent = Color3.fromRGB(96, 180, 235),
	},
	-- The bigger tower: 6 MW against the standard 2.5 (a modern 100 m-hub machine). Its own
	-- model (PowerKit WindTurbine_Big: 100 m hub, 54 m blades, box nacelle, switchgear).
	AdvancedWindTurbine = {
		key = "AdvancedWindTurbine", name = "Advanced Wind Turbine",
		desc = "A far bigger tower on the same clean power. 6 MW, more than twice the output, and it needs the room to match.",
		kind = "Power", category = "Utilities", placement = "Free", widthLots = 3, depthLots = 2, height = 308,
		coverageRadius = 32, cost = 12000, upkeep = 16000, runCost = 8,
		powerOutput = 6000, bladeRadius = 108, needs = {},
		footprint = Vector3.new(3 * LOT_SIZE, 308, 2 * LOT_SIZE),
		wall = Color3.fromRGB(240, 242, 244), roof = Color3.fromRGB(126, 132, 140), accent = Color3.fromRGB(96, 180, 235),
	},
	-- The one generator whose output MOVES. `powerOutput` is its noon peak; PowerService
	-- scales it by the sun's altitude AND the sky (cloud, fog, rain, snow -- WeatherService), so it
	-- makes 100 MW at a clear midday, less morning and evening and under cloud, and nothing between
	-- dusk and dawn. The ENDGAME source (user 2026-10-07: "there is no big or small, only big"; 20 lots
	-- wide, 50 deep): PowerKit SolarFarm, 160 x 400 m -- four blocks of 22 single-axis tracker rows
	-- (SolarTrackerView turns them with the sun), an inverter station each side of every block, the
	-- substation, control building and O&M workshop by the gate; its roads are the lot paving (KitPave).
	-- The yard reach covers the plot's half-diagonal (431) and the road in front of it.
	SolarFarm = {
		key = "SolarFarm", name = "Solar Farm",
		desc = "Up to 100 MW on a clear noon and nothing at night; clouds and rain cut it. Clean and silent, 30 jobs, but huge and dear to run -- keep something else awake after dark.",
		kind = "Power", category = "Utilities", widthLots = 20, depthLots = 50, height = 20,
		coverageRadius = 438, cost = 60000, upkeep = 900000, -- no fuel: the panels' upkeep is all of it
		powerOutput = 100000, solar = true, jobs = 30, needs = { "Water", "Sewage" }, waterUse = 800,
		sewageShare = 0.1, -- panel washing soaks away; the staff's share drains
		footprint = Vector3.new(20 * LOT_SIZE, 20, 50 * LOT_SIZE),
		wall = Color3.fromRGB(46, 52, 66), roof = Color3.fromRGB(74, 74, 70), accent = Color3.fromRGB(246, 190, 74),
	},
	-- Not a building: a relay. PowerService owns these, not EmergencyService -- it is in
	-- this catalog so it rides the same Utilities card, ghost and placement remote as
	-- everything else on the page. `coverageRadius` is the reach PowerService wires with.
	PowerPole = {
		key = "PowerPole", name = "Power Line", desc = "Carries electricity to buildings a generator cannot reach. Run one to the map edge to buy and sell power.",
		kind = "PowerLine", category = "Utilities", widthLots = 1, depthLots = 1, height = 21,
		coverageRadius = 0, cost = 120,
		footprint = Vector3.new(1 * LOT_SIZE, 21, 1 * LOT_SIZE),
		wall = Color3.fromRGB(150, 140, 126), roof = Color3.fromRGB(96, 90, 82), accent = Color3.fromRGB(240, 206, 80),
	},
	-- The big dirty one: 40 MW day and night for a lot of smoke. `coverageRadius` is its
	-- YARD (what a line or a road has to touch), not a service area.
	-- 2026-10-06 the station model (PowerKit.CoalPlant, 96 x 144 m, user: 10-15 lots wide and longer
	-- deep): 12 x 18 lots, 90 m chimney. The yard covers the half-diagonal (173 studs) so a line at the
	-- fence reaches it. pollutionRadius was 80 from the centre -- inside the new plant -- so it keeps its
	-- old reach past the front and back fences (144 + 80); the user's call, change here.
	PowerPlant = {
		key = "PowerPlant", name = "Coal Power Plant", desc = "150 MW day and night and 65 jobs. Cheap per kilowatt, but it burns fuel for every one, drinks a lot of water, and the smoke lowers land value around it.",
		kind = "Power", category = "Utilities", widthLots = 12, depthLots = 18, height = 182,
		coverageRadius = 180, cost = 20000, upkeep = 300000,
		runCost = 12, -- coal burnt for every kW it makes
		powerOutput = 150000, jobs = 65, needs = { "Water", "Sewage" }, waterUse = 2000, -- cooling and boiler make-up
		sewageShare = 0.15, -- the cooling towers evaporate most of it; blowdown and the staff drain
		pollution = 0.8, pollutionRadius = 224,
		footprint = Vector3.new(12 * LOT_SIZE, 182, 18 * LOT_SIZE),
		wall = Color3.fromRGB(88, 90, 96), roof = Color3.fromRGB(56, 58, 64), accent = Color3.fromRGB(240, 206, 80),
	},
	-- Water is counted in heads at WaterService's 2.1 m3/week a head: a tower serves about 1,500, a
	-- pumping station 7,500. The tower runs on gravity and needs nothing (user 2026-10-07); the pumps and
	-- plants run on electricity -- no power, no pressure. `coverageRadius` is only the yard; the PIPES are
	-- the delivery.
	WaterTower = {
		key = "WaterTower", name = "Water Tower", desc = "3,200 m\u{00B3} of clean water a week, about 1,500 people. Build it by a road -- every road carries water.",
		kind = "Water", category = "Utilities", widthLots = 2, depthLots = 2, height = 65,
		coverageRadius = 24, cost = 6000,
		waterOutput = 3200, needs = {}, upkeep = 6000, runCost = 10,
		footprint = Vector3.new(2 * LOT_SIZE, 65, 2 * LOT_SIZE),
		wall = Color3.fromRGB(196, 208, 220), roof = Color3.fromRGB(120, 136, 152), accent = Color3.fromRGB(80, 170, 235),
	},
	WaterPumpingStation = {
		key = "WaterPumpingStation", name = "Water Pumping Station",
		desc = "16,000 m\u{00B3} a week, about 7,500 people. Must stand on the shore and needs power. Keep sewage outlets away from it.",
		kind = "Water", category = "Utilities", widthLots = 2, depthLots = 2, height = 24, -- 2x2: user 2026-10-06
		coverageRadius = 32, cost = 14000,
		waterOutput = 16000, powerUse = 100, shore = true, jobs = 8, needs = { "Power", "Sewage" }, waterUse = 40,
		upkeep = 20000, runCost = 8, -- bigger works, cheaper water
		footprint = Vector3.new(2 * LOT_SIZE, 24, 2 * LOT_SIZE),
		wall = Color3.fromRGB(200, 214, 226), roof = Color3.fromRGB(70, 110, 150), accent = Color3.fromRGB(80, 170, 235),
	},
	-- A buried main. Three cards, one trench: water only, sewage only, or both laid
	-- together. `cost` is PER SPAN of pipe (ServiceTypes.PipeSpan studs), not per run.
	-- WaterPipeService owns these -- they ride this catalog only so they get a Utilities
	-- card like everything else. `kind = "Pipe"` is what routes the card to the drag tool.
	WaterPipe = {
		key = "WaterPipe", name = "Water Pipe", desc = "A buried water main. Anything within reach of a pipe fed by a tower gets water.",
		kind = "Pipe", category = "Utilities", widthLots = 1, depthLots = 1, height = 3,
		coverageRadius = 0, cost = 60,
		footprint = Vector3.new(1 * LOT_SIZE, 3, 1 * LOT_SIZE),
		wall = Color3.fromRGB(64, 176, 212), roof = Color3.fromRGB(38, 120, 150), accent = Color3.fromRGB(64, 176, 212),
	},
	SewagePipe = {
		key = "SewagePipe", name = "Sewage Pipe", desc = "A buried drain. Nothing treats what it carries yet -- lay it now, plug a plant into it later.",
		kind = "Pipe", category = "Utilities", widthLots = 1, depthLots = 1, height = 3,
		coverageRadius = 0, cost = 60,
		footprint = Vector3.new(1 * LOT_SIZE, 3, 1 * LOT_SIZE),
		wall = Color3.fromRGB(206, 170, 104), roof = Color3.fromRGB(140, 112, 64), accent = Color3.fromRGB(206, 170, 104),
	},
	UtilityPipe = {
		key = "UtilityPipe", name = "Water & Sewage", desc = "Both mains in one trench. Costs the two of them, saves digging twice.",
		kind = "Pipe", category = "Utilities", widthLots = 1, depthLots = 1, height = 3,
		coverageRadius = 0, cost = 110,
		footprint = Vector3.new(1 * LOT_SIZE, 3, 1 * LOT_SIZE),
		wall = Color3.fromRGB(64, 176, 212), roof = Color3.fromRGB(140, 112, 64), accent = Color3.fromRGB(120, 172, 172),
	},
	SewagePlant = {
		kind = "Sewage", key = "SewagePlant", name = "Sewage Treatment Plant", desc = "Cleans 4,200 m\u{00B3} of wastewater a week, about 2,000 people, with 20 jobs. Needs power, water and a road.",
		category = "Utilities", widthLots = 4, depthLots = 4, height = 15,
		coverageRadius = 32, cost = 9000,
		sewageCapacity = 4200, powerUse = 80, jobs = 20, needs = { "Power", "Water" }, waterUse = 60, -- staff + washdown; its drain is its own inlet
		upkeep = 10000, runCost = 11,
		pollution = 0.45, pollutionRadius = 52 * WORLD_SCALE,
		-- PlantKit SewagePlant_Small is 32 m square (2026-10-07): 4 x 4 lots, was 3 x 3 for the code boxes
		footprint = Vector3.new(4 * LOT_SIZE, 15, 4 * LOT_SIZE),
		wall = Color3.fromRGB(122, 118, 96), roof = Color3.fromRGB(84, 82, 66), accent = Color3.fromRGB(150, 190, 90),
	},
	-- The city-sized works (user 2026-10-07: "one small and one big"; PlantKit SewagePlant_Big, 64 m: clarifiers,
	-- aeration lanes, egg digesters): five small plants' wastewater on four plants' ground and power.
	LargeSewagePlant = {
		kind = "Sewage", key = "LargeSewagePlant", name = "Large Sewage Treatment Plant",
		desc = "Cleans 21,000 m\u{00B3} of wastewater a week, about 10,000 people, with 60 jobs. Needs a lot of power, water and a road.",
		category = "Utilities", widthLots = 8, depthLots = 8, height = 37,
		coverageRadius = 64, cost = 32000, upkeep = 40000,
		sewageCapacity = 21000, powerUse = 350, jobs = 60, needs = { "Power", "Water" }, waterUse = 150, runCost = 9,
		pollution = 0.6, pollutionRadius = 96 * WORLD_SCALE,
		footprint = Vector3.new(8 * LOT_SIZE, 37, 8 * LOT_SIZE),
		wall = Color3.fromRGB(122, 118, 96), roof = Color3.fromRGB(84, 82, 66), accent = Color3.fromRGB(150, 190, 90),
	},
	-- The cheap answer: dump it in the water. Takes a lot, needs a little power for its pumps (user
	-- 2026-10-07), pollutes the ground around it -- and a pumping station drinking near it pumps half.
	SewageOutlet = {
		key = "SewageOutlet", name = "Sewage Outlet",
		desc = "Dumps 10,000 m\u{00B3} of sewage a week into the water, about 4,700 people. Cheap and needs only a little power, but it pollutes and spoils pumps nearby.",
		kind = "Sewage", category = "Utilities", widthLots = 2, depthLots = 2, height = 6,
		coverageRadius = 24, cost = 3000,
		sewageCapacity = 10000, powerUse = 15, shore = true, needs = { "Power" }, upkeep = 3000, runCost = 2, -- cheap: it treats nothing
		pollution = 1.0, pollutionRadius = 96,
		footprint = Vector3.new(2 * LOT_SIZE, 6, 2 * LOT_SIZE),
		wall = Color3.fromRGB(120, 112, 96), roof = Color3.fromRGB(80, 74, 62), accent = Color3.fromRGB(170, 130, 70),
	},
}
for _, spec in DEFS do table.freeze(spec) end
table.freeze(DEFS)

-- The electricity grid's shared numbers, here rather than inside PowerService so the client's
-- line tool lays out exactly what the server wires.
--   * A building takes power from any pole standing inside this radius of it, and two
--     overlapping areas merge into one grid.
--   * A single span of wire may not exceed PowerMaxSpan, so a drawn run drops poles often
--     enough to stay under it.
-- Measured, not guessed. A deep house's pivot already sits ~29 studs from its kerb
-- (half of a 53-stud footprint plus the setback), the road adds up to another 17, and poles
-- land every PowerSpan studs so a house can be half a span off the nearest one. 26 left
-- most of a street dark with a line running right past it.
ServiceTypes.PowerBuildingReach = 64
ServiceTypes.PowerMaxSpan = 88
-- How a drawn run is laid out. Shared so the client's drag preview shows exactly the poles
-- the server will build, and snaps to the same pole the server will join.
ServiceTypes.PowerSpan = 64      -- poles dropped this far apart along a run
ServiceTypes.PowerSnapDist = 24  -- end a drag this close to a standing pole and it joins it

-- A generator that takes the grid ONLY through a drawn line (user 2026-10-07: the coal plant and the solar
-- farm -- each has a LineIn marker on its line gantry): no road and no neighbour picks its power up. Where
-- that line's last pole stands -- just outside the front edge, in line with the gantry -- and the gantry's
-- three string tops the wires run up to. A pole within HookReach of the spot is hooked on. Shared so the
-- client's drag snaps to exactly the spot the server hooks. nil for a generator without a gantry.
ServiceTypes.HookReach = 16
ServiceTypes.HookOut = 8 -- studs past the front edge
function ServiceTypes.hookOf(model: Instance): (Vector3?, { Vector3 })
	local phases: { Vector3 } = {}
	if not model:IsA("Model") then return nil, phases end
	local att = model:FindFirstChild("LineIn", true)
	local spec = DEFS[tostring(model:GetAttribute("ServiceType") or "")]
	if not (att and att:IsA("Attachment") and spec) then return nil, phases end
	local cf = model:GetPivot()
	local l = cf:PointToObjectSpace(att.WorldPosition)
	local spot = (cf * CFrame.new(l.X, 0, spec.footprint.Z * 0.5 + ServiceTypes.HookOut)).Position
	for _, k in { "A", "B", "C" } do
		local a = model:FindFirstChild("LineIn_" .. k, true)
		if a and a:IsA("Attachment") then phases[#phases + 1] = a.WorldPosition end
	end
	return spot, phases
end

-- The pipe network's shared numbers, same deal: the client's drag preview and the water
-- view have to use the ones WaterPipeService actually uses.
--   * PipeReach is how far EITHER SIDE of a pipe the service carries -- the pipe is the
--     delivery, the tower is only the source, so a tower with no pipe serves nobody.
--   * PipeSourceReach is how close a pipe END has to be to a tower or plant to tap it.
--     A tower is 32 studs across, so this is "touching the base", not "somewhere nearby".
ServiceTypes.PipeReach = 64
ServiceTypes.PipeSpan = 64       -- one card cost buys this much pipe
ServiceTypes.PipeSnapDist = 20   -- end a drag this close to a pipe joint and it joins it
ServiceTypes.PipeSourceReach = 40
ServiceTypes.PipeMaxRun = 2048
ServiceTypes.PipeDepth = 6       -- the WATER main lies this far under the surface (3 m, user 2026-10-07); sewage PipeArt.WATER_RISE deeper

ServiceTypes.LOT_SIZE = LOT_SIZE
ServiceTypes.Order = table.freeze({
	"Clinic", "SmallHospital", "Hospital", "GeneralHospital", "PoliceStation", "FireStation", "Cemetery",
	"WindTurbine", "AdvancedWindTurbine", "SolarFarm", "PowerPlant", "PowerPole",
	"WaterTower", "WaterPumpingStation", "UtilityPipe", "WaterPipe", "SewagePipe", "SewagePlant", "LargeSewagePlant", "SewageOutlet",
})
-- Every utility is ON (2026-09-22). A key out of `Order` gets no card and nothing can place
-- one; old saves keep what they already have.

-- Service buildings use the city's utilities like any other building (user, 2026-10-06):
-- Power -- everything but the generators; Water (and its sewage) -- everything but the
-- turbines out in a field and the water and sewage works themselves. Lines and pipes are not
-- buildings. A spec's own powerUse / waterUse sets how much; these are the defaults.
ServiceTypes.SERVICE_POWER_KW = 30   -- a civic building's draw, like a few shops
ServiceTypes.SERVICE_WATER_M3 = 42   -- m3/week, about twenty people's worth
function ServiceTypes.usesUtility(spec: Spec, utility: string): boolean
	local s = spec :: any
	if s.kind == "PowerLine" or s.kind == "Pipe" then return false end
	if s.needs then return table.find(s.needs, utility) ~= nil end
	if utility == "Power" then return (tonumber(s.powerOutput) or 0) <= 0 end
	return s.placement ~= "Free" and s.kind ~= "Water" and s.kind ~= "Sewage"
end

function ServiceTypes.get(key: string): Spec?
	return DEFS[key]
end

function ServiceTypes.all(): { [string]: Spec }
	return DEFS
end

-- Footprint ground size in studs: X = width along the road, Z = depth back from it.
function ServiceTypes.footprintStuds(spec: Spec): Vector3
	return Vector3.new(spec.widthLots * LOT_SIZE, spec.height, spec.depthLots * LOT_SIZE)
end

return ServiceTypes
