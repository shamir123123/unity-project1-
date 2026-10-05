--!strict
-- TransitTypes
-- Shared, immutable catalog for the public-transit (bus) system: the Bus Depot and
-- Bus Stop placeables, the Bus vehicle, and every tunable the feature reads. Pure
-- data -- no lifecycle, no side effects on require. Mirrors ServiceTypes / SchoolTypes
-- so the placement UI and renderers can treat it the same way.
--
-- Read by: TransitService (placement / validation / sim), BusDispatchService (spawn /
-- drive), the placement + overview controllers, and the Bus model template builder.

local LOT_SIZE = 16 -- must match ZoneService.LOT_SIZE (the depot snaps to the zone grid)
local WORLD_SCALE = require(script.Parent.Parent.Road.RoadConstants).WORLD_SCALE
-- The Blender transit kit (templates in ServerStorage.Templates.Transit) is authored on the zone lot,
-- ZoneGrid.LOT_SIZE = 16 * 2/3 studs = 16/3 m, at 2 studs per metre; its footprints are world studs.
local KIT_LOT = 32 / 3
local function kitFootprint(w: number, d: number, h: number): Vector3
	return Vector3.new(w * KIT_LOT, h, d * KIT_LOT)
end

local TransitTypes = {}

-- ============================================================================
-- Depot -- a garage; each one raises the city-wide bus allowance by busCapacity.
-- ============================================================================
export type DepotSpec = {
	key: string,
	name: string,
	desc: string,
	category: string,        -- UI grouping ("Transit")
	widthLots: number,       -- footprint along the road, in lots
	depthLots: number,       -- footprint back from the road, in lots
	height: number,          -- body height, studs
	cost: number,            -- treasury cost to place
	busCapacity: number,     -- buses this depot lets the city run (the per-depot limit)
	upkeep: number,          -- monthly upkeep while it stands
	mode: string?,           -- nil = bus; "train" = a rail building that must stand beside track
	trainCapacity: number?,  -- Train Depot: trains the city may run per depot
	serviceBays: number?,    -- Train Yard: trains serviced at once
	footprint: Vector3,      -- derived X*Z ground size (studs), Y body height
	template: string?,       -- ServerStorage.Templates.Transit.<template> (the Blender kit); nil = procedural
	gates: { number }?,      -- kit: X (template studs) of the IN and OUT road hand-offs, GATE_REACH past the street edge
	wall: Color3,
	roof: Color3,
	accent: Color3,
}

local BLUE = Color3.fromRGB(46, 84, 140) -- CITY TRANSIT brand blue

-- Bus depots: buses drive in and out through the gates on the street side (+Z) along drives the plan
-- checked, and park in the bays of the depot's layout. busCapacity = the default layout's bay count.
local DEPOTS: { [string]: DepotSpec } = {
	BusDepotSmall = {
		key = "BusDepotSmall", name = "Small Bus Depot", template = "BusDepotSmall",
		desc = "A small garage for 5 buses, with an office and staff parking. Put the gates on a road.",
		category = "Transit", widthLots = 11, depthLots = 6, height = 28,
		cost = 9000, busCapacity = 5, upkeep = 220,
		footprint = kitFootprint(11, 6, 28), gates = { -50.9, 14.9 },
		wall = Color3.fromRGB(222, 222, 216), roof = Color3.fromRGB(150, 152, 154), accent = BLUE,
	},
	BusDepotMedium = {
		key = "BusDepotMedium", name = "Bus Depot", template = "BusDepotMedium",
		desc = "A bus garage for 10 buses, 2 of them long articulated ones for busy lines. Put the gates on a road.",
		category = "Transit", widthLots = 15, depthLots = 7, height = 40,
		cost = 16000, busCapacity = 10, upkeep = 400,
		footprint = kitFootprint(15, 7, 40), gates = { -71.8, 34.4 },
		wall = Color3.fromRGB(222, 222, 216), roof = Color3.fromRGB(150, 152, 154), accent = BLUE,
	},
	BusDepotLarge = {
		key = "BusDepotLarge", name = "Transit Headquarters", template = "BusDepotLarge",
		desc = "The city's bus headquarters: 23 buses (5 articulated), a workshop and the transit offices.",
		category = "Transit", widthLots = 22, depthLots = 12, height = 45,
		cost = 32000, busCapacity = 23, upkeep = 750,
		footprint = kitFootprint(22, 12, 45), gates = { -109.1, 18.7 },
		wall = Color3.fromRGB(222, 222, 216), roof = Color3.fromRGB(150, 152, 154), accent = BLUE,
	},
	-- The pre-kit depot. Kept so saved cities load (as the medium depot); not offered in the build menu.
	BusDepot = {
		key = "BusDepot", name = "Bus Depot", template = "BusDepotMedium",
		desc = "A bus garage for 10 buses, 2 of them long articulated ones for busy lines. Put the gates on a road.",
		category = "Transit", widthLots = 15, depthLots = 7, height = 40,
		cost = 16000, busCapacity = 10, upkeep = 400,
		footprint = kitFootprint(15, 7, 40), gates = { -71.8, 34.4 },
		wall = Color3.fromRGB(222, 222, 216), roof = Color3.fromRGB(150, 152, 154), accent = BLUE,
	},
	-- Rail buildings stand BESIDE a track (TransitService refuses them anywhere else); the
	-- trains leave and enter through the building's point on that track.
	TrainDepot = {
		key = "TrainDepot", name = "Train Depot", mode = "train",
		desc = "Home of your trains. Build it beside a track: trains roll out onto your lines and go back in when a line needs fewer.",
		category = "Transit", widthLots = 14, depthLots = 6, height = 22,
		cost = 24000, busCapacity = 0, trainCapacity = 6, upkeep = 600,
		footprint = Vector3.new(14 * LOT_SIZE, 22, 6 * LOT_SIZE),
		wall = Color3.fromRGB(176, 104, 84), roof = Color3.fromRGB(78, 82, 88), accent = Color3.fromRGB(140, 62, 54),
	},
	TrainYard = {
		key = "TrainYard", name = "Train Yard", mode = "train",
		desc = "Keeps trains running well. Build it beside a track: after a long run a train drives in for a check-up. Without one, trains wear out and slow down.",
		category = "Transit", widthLots = 16, depthLots = 8, height = 14,
		cost = 18000, busCapacity = 0, serviceBays = 2, upkeep = 450,
		footprint = Vector3.new(16 * LOT_SIZE, 14, 8 * LOT_SIZE),
		wall = Color3.fromRGB(150, 146, 138), roof = Color3.fromRGB(70, 74, 80), accent = Color3.fromRGB(140, 62, 54),
	},
}

-- ============================================================================
-- Stop -- a roadside pole/shelter citizens board at. Snaps to the kerb, faces road.
-- ============================================================================
export type StopSpec = {
	key: string,
	name: string,
	desc: string,
	category: string,
	cost: number,
	poleHeight: number,      -- sign pole height, studs
	shelterSize: Vector3,    -- shelter footprint: X along the curb, Y, Z out from the curb
	curbOffset: number,      -- studs from the road edge out to the shelter centre
	accent: Color3,
	mode: string?,           -- "bus" (nil) | "train": which network the stop boards from
	platformCars: number?,   -- train stations: the longest train (in cars) the platform fits
	template: string?,       -- ServerStorage.Templates.Transit.<template>; pivot on the ground, road on +Z
	-- An interchange (bus hub / station) is placed like a depot (free, R rotates) and buses drive
	-- through it: in at its gate, onto a platform, out at the other gate.
	interchange: boolean?,
	widthLots: number?, depthLots: number?, height: number?,
	footprint: Vector3?,
	gates: { number }?,      -- as DepotSpec.gates
}

-- Kit bus stops: the pivot is on the sidewalk 1.3 m behind the kerb (curbOffset is a full-size
-- literal, halved by WORLD_SCALE like the rest), the sign at the kerb end. No benches (user).
local STOPS: { [string]: StopSpec } = {
	BusStopPole = {
		key = "BusStopPole", name = "Bus Stop Sign", template = "BusStopPole",
		desc = "Just the sign and a timetable. Place it along a road, on either side -- it faces the road.",
		category = "Transit", cost = 150,
		poleHeight = 6.2, shelterSize = Vector3.new(1.3, 6.2, 0.7), curbOffset = 5.2,
		accent = BLUE,
	},
	BusStopShelter = {
		key = "BusStopShelter", name = "Bus Shelter", template = "BusStopShelter",
		desc = "A glass shelter with a roof, the timetable and a line map. Place it along a road -- it faces the road.",
		category = "Transit", cost = 400,
		poleHeight = 6.2, shelterSize = Vector3.new(11.7, 6.2, 4), curbOffset = 5.2,
		accent = BLUE,
	},
	-- The pre-kit stop. Kept so saved cities load (as the shelter); not offered in the build menu.
	BusStop = {
		key = "BusStop", name = "Bus Shelter", template = "BusStopShelter",
		desc = "A glass shelter with a roof, the timetable and a line map. Place it along a road -- it faces the road.",
		category = "Transit", cost = 400,
		poleHeight = 6.2, shelterSize = Vector3.new(11.7, 6.2, 4), curbOffset = 5.2,
		accent = BLUE,
	},
	BusHub = {
		key = "BusHub", name = "Bus Hub", template = "BusHub", interchange = true,
		desc = "Three covered platforms where lines meet. Put its gates on a road; buses pull in, stop and leave.",
		category = "Transit", cost = 12000, widthLots = 8, depthLots = 5, height = 14,
		footprint = kitFootprint(8, 5, 14), gates = { -33.3, 33.3 },
		poleHeight = 0, shelterSize = Vector3.zero, curbOffset = 0, accent = BLUE,
	},
	BusStation = {
		key = "BusStation", name = "Bus Station", template = "BusStation", interchange = true,
		desc = "The big bus station: a terminal hall and four covered platforms. Put its gates on a road.",
		category = "Transit", cost = 26000, widthLots = 12, depthLots = 9, height = 28,
		footprint = kitFootprint(12, 9, 28), gates = { -54.6, 54.6 },
		poleHeight = 0, shelterSize = Vector3.zero, curbOffset = 0, accent = BLUE,
	},
	-- Stations: shelterSize doubles as the platform -- X along the track, Y canopy height,
	-- Z platform depth. The platform is sized to the longest train it takes (platformCars);
	-- a line runs the biggest train that fits EVERY station on it.
	TrainStationSmall = {
		key = "TrainStationSmall", name = "Small Station",
		desc = "A halt with one short platform beside the track. Fits 3-car commuter trains.",
		category = "Transit", cost = 4000, poleHeight = 14,
		shelterSize = Vector3.new(240, 9, 12), curbOffset = 5,
		accent = Color3.fromRGB(140, 62, 54), mode = "train", platformCars = 3,
	},
	TrainStationMedium = {
		key = "TrainStationMedium", name = "Medium Station",
		desc = "A longer platform with a ticket hall. Fits 5-car regional trains.",
		category = "Transit", cost = 9000, poleHeight = 14,
		shelterSize = Vector3.new(400, 10, 16), curbOffset = 6,
		accent = Color3.fromRGB(140, 62, 54), mode = "train", platformCars = 5,
	},
	TrainStationLarge = {
		key = "TrainStationLarge", name = "Train Station",
		desc = "The city's main station: a long covered platform and a big hall. Fits 7-car intercity trains.",
		category = "Transit", cost = 18000, poleHeight = 14,
		shelterSize = Vector3.new(560, 12, 20), curbOffset = 7,
		accent = Color3.fromRGB(140, 62, 54), mode = "train", platformCars = 7,
	},
	-- The pre-overhaul station. Kept so saved cities load; not offered in the build menu.
	TrainStation = {
		key = "TrainStation", name = "Small Station",
		desc = "A halt with one short platform beside the track. Fits 3-car commuter trains.",
		category = "Transit", cost = 4000, poleHeight = 14,
		shelterSize = Vector3.new(240, 9, 12), curbOffset = 5,
		accent = Color3.fromRGB(140, 62, 54), mode = "train", platformCars = 3,
	},
}

-- ============================================================================
-- Bus -- the vehicle. Dimensions are authored to the world scale used by the car
-- templates in ServerStorage.Vehicles (cars are ~7.5 wide x ~10 long; a bus reads
-- as longer). The Bus template model is built to these dims; VehicleFactory clones it.
-- ============================================================================
export type BusSpec = {
	length: number, width: number, height: number,
	capacity: number,  -- nominal passenger capacity (the usage % basis)
	speedKmh: number,  -- cruise speed; NPCDriverService still obeys the lane limit
	body: Color3,
}

TransitTypes.Bus = table.freeze({
	length = 46, width = 9.6, height = 10,
	capacity = 60, speedKmh = 50,
	body = Color3.fromRGB(228, 228, 222),
}) :: BusSpec

-- The articulated ("bendy") bus: same route, 100 riders against the standard bus's 60. A depot keeps a
-- share of these and sends them where a line is busy (BusDispatchService).
TransitTypes.BusArticulated = table.freeze({
	length = 72, width = 9.6, height = 10,
	capacity = 100, speedKmh = 50,
	body = Color3.fromRGB(228, 228, 222),
}) :: BusSpec
TransitTypes.ARTICULATED_EVERY = 3      -- every 3rd depot slot parks an articulated bus
TransitTypes.BUSY_LINE_USAGE = 60       -- % full at which a line is sent articulated buses

-- ============================================================================
-- Trains -- push-pull sets with a cab at each end (they reverse at a terminus without
-- running round). carLength/width/height are per-car dims authored at the same scale as
-- the Bus above; capacity is the WHOLE train (usage % basis). Placeholder models are
-- built from these dims by TrainDispatchService until the real kit lands.
-- ============================================================================
export type TrainSpec = {
	key: string, name: string,
	carLength: number, width: number, height: number,
	carCount: number,   -- cars per train, both cabs included
	carGap: number,     -- coupling gap between cars, studs
	capacity: number,   -- passengers per whole train
	speedKmh: number,   -- cruise speed on open track
	body: Color3,       -- coach body
	loco: Color3,       -- cab ends + livery stripe
}

TransitTypes.Trains = table.freeze({
	Commuter = table.freeze({
		key = "Commuter", name = "Commuter", carLength = 72, width = 10, height = 12,
		carCount = 3, carGap = 2, capacity = 180, speedKmh = 100,
		body = Color3.fromRGB(230, 230, 224), loco = Color3.fromRGB(176, 58, 50),
	}),
	Regional = table.freeze({
		key = "Regional", name = "Regional", carLength = 72, width = 10, height = 12.5,
		carCount = 5, carGap = 2, capacity = 320, speedKmh = 120,
		body = Color3.fromRGB(222, 226, 232), loco = Color3.fromRGB(46, 84, 140),
	}),
	Intercity = table.freeze({
		key = "Intercity", name = "Intercity", carLength = 72, width = 10, height = 13,
		carCount = 7, carGap = 2, capacity = 480, speedKmh = 150,
		body = Color3.fromRGB(196, 200, 206), loco = Color3.fromRGB(56, 112, 84),
	}),
}) :: { [string]: TrainSpec }
TransitTypes.TrainOrder = table.freeze({ "Commuter", "Regional", "Intercity" })
-- The smallest set; also what readers that predate train types get.
TransitTypes.Train = TransitTypes.Trains.Commuter

-- The biggest train whose cars all fit a platform of `cars` cars (never smaller than Commuter).
function TransitTypes.trainForPlatform(cars: number): TrainSpec
	local best = TransitTypes.Trains.Commuter
	for _, key in TransitTypes.TrainOrder do
		local spec = TransitTypes.Trains[key]
		if spec.carCount <= cars then best = spec end
	end
	return best
end

-- ============================================================================
-- Tunables
-- ============================================================================
TransitTypes.LOT_SIZE = LOT_SIZE
TransitTypes.BUSES_PER_DEPOT = 20         -- mirrors DepotSpec.busCapacity; the always-parked fleet each depot owns
TransitTypes.DEFAULT_BUSES_PER_ROUTE = 2
TransitTypes.DEFAULT_TRAINS_PER_ROUTE = 1
TransitTypes.MAX_TRAINS_PER_ROUTE = 8    -- per line; Train Depots cap the city-wide total
TransitTypes.TRAIN_UPKEEP = 400          -- monthly upkeep per running train
TransitTypes.TRAIN_STOP_DWELL = 5        -- seconds a train holds at a station
-- Wear is distance driven. Past DUE a train goes to a Train Yard for a check-up; with no
-- yard it keeps running but slows, down to WORN_SPEED of its top speed at MAX.
TransitTypes.TRAIN_WEAR_DUE = 60000      -- studs (30 km)
TransitTypes.TRAIN_WEAR_MAX = 120000     -- studs (60 km)
TransitTypes.TRAIN_WORN_SPEED = 0.6
TransitTypes.TRAIN_SERVICE_SECONDS = 25  -- game-seconds a check-up takes
TransitTypes.DEFAULT_FARE = 2             -- cents per boarding
TransitTypes.MIN_FARE = 0
TransitTypes.MAX_FARE = 12
TransitTypes.STOP_MIN_SPACING = 24        -- min studs between two stops
TransitTypes.STOP_BOARD_RADIUS = 12       -- a bus within this of a stop's road point is "at" it
TransitTypes.STOP_DWELL = 1.5             -- seconds a bus pauses at a stop
TransitTypes.BOARD_SECONDS = 0.4          -- ...plus this per passenger getting on or off
TransitTypes.MAX_STOPS_PER_ROUTE = 24
TransitTypes.MAX_WAYPOINTS_PER_LEG = 8
TransitTypes.BUS_UPKEEP = 1500            -- monthly upkeep per running bus (was 120: a third of one resident's tax)
-- A line's bus limit grows with its length and its stops (user, 2026-10-02): about 1.5 buses
-- per km of loop plus one per four stops, so a short shuttle cannot be flooded with buses.
TransitTypes.STUDS_PER_KM = 4000 -- the overview's own km conversion
TransitTypes.MAX_BUSES_PER_ROUTE = 20
function TransitTypes.maxBusesFor(lengthStuds: number, stops: number): number
	local byLength = math.ceil(math.max(0, lengthStuds) / TransitTypes.STUDS_PER_KM * 1.5)
	return math.clamp(byLength + stops // 4, 1, TransitTypes.MAX_BUSES_PER_ROUTE)
end
-- Walking reach a citizen will use to get to/from a stop (studs). Beyond this, a stop
-- is too far and transit is not an option for that trip.
TransitTypes.STOP_WALK_REACH = 800           -- studs (~400 m): the standard bus catchment -- a
                                             -- 5-minute walk; the mode choice prices the walk itself
-- Line colours cycled as routes are created. Vivid transit-map hues (user, 2026-09-30: the muted
-- set read badly on the map), distinct from each other; the first is the transit teal.
TransitTypes.ROUTE_COLORS = table.freeze({
	Color3.fromRGB(0, 190, 196), Color3.fromRGB(48, 128, 255), Color3.fromRGB(70, 200, 90),
	Color3.fromRGB(255, 150, 40), Color3.fromRGB(165, 100, 255), Color3.fromRGB(245, 80, 150),
	Color3.fromRGB(240, 205, 45), Color3.fromRGB(235, 70, 60),
})

-- ============================================================================
-- Accessors
-- ============================================================================
function TransitTypes.getDepot(key: string): DepotSpec?
	return DEPOTS[key]
end

function TransitTypes.getStop(key: string): StopSpec?
	return STOPS[key]
end

-- Depot footprint ground size in studs: X = width along the road, Z = depth back from it.
function TransitTypes.depotFootprintStuds(spec: DepotSpec): Vector3
	if spec.template then return spec.footprint end
	return Vector3.new(spec.widthLots * LOT_SIZE, spec.height, spec.depthLots * LOT_SIZE)
end

-- The ground a depot really covers: its model is built at the authored footprint and
-- scaled by WORLD_SCALE. Rail buildings place, snap and overlap-test by this. Bus depots
-- keep the authored size until their templates replace the procedural model.
function TransitTypes.depotGroundFootprint(spec: DepotSpec): Vector3
	local fp = TransitTypes.depotFootprintStuds(spec)
	if spec.template or spec.mode ~= "train" then return fp end
	return Vector3.new(fp.X * WORLD_SCALE, fp.Y, fp.Z * WORLD_SCALE)
end

-- A deterministic line colour for the Nth route created (wraps the palette).
function TransitTypes.routeColor(index: number): Color3
	local n = #TransitTypes.ROUTE_COLORS
	return TransitTypes.ROUTE_COLORS[((index - 1) % n) + 1]
end

for _, spec in DEPOTS do table.freeze(spec) end
for _, spec in STOPS do table.freeze(spec) end
table.freeze(DEPOTS)
table.freeze(STOPS)

TransitTypes.Depots = DEPOTS
TransitTypes.Stops = STOPS
TransitTypes.DepotOrder = table.freeze({ "BusDepotSmall", "BusDepotMedium", "BusDepotLarge", "TrainDepot", "TrainYard" })
TransitTypes.StopOrder = table.freeze({ "BusStopPole", "BusStopShelter", "BusHub", "BusStation",
	"TrainStationSmall", "TrainStationMedium", "TrainStationLarge" })

-- Where a kit building's buses leave and join the road (world points), for a building pivoted at
-- `pivot`: the placement tool and the server both refuse a spot where these are not on a road.
TransitTypes.GATE_REACH = 8 -- studs past the street edge (transit_plan: the road hand-off, 4 m)
function TransitTypes.gatePoints(spec: any, pivot: CFrame): { Vector3 }
	local out = {}
	if not (spec.gates and spec.footprint) then return out end
	for i, x in spec.gates do
		out[i] = (pivot * CFrame.new(x, 0, spec.footprint.Z * 0.5 + TransitTypes.GATE_REACH)).Position
	end
	return out
end

-- What the free-placement tool places: a depot, or an interchange stop (hub / station). Both carry
-- footprint (studs, Y = height) and cost.
function TransitTypes.getFreePlaced(key: string): (DepotSpec | StopSpec)?
	local d = DEPOTS[key]
	if d then return d end
	local s = STOPS[key]
	return if s and s.interchange then s else nil
end

return TransitTypes
