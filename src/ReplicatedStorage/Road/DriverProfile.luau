--!strict
-- DriverProfile
-- How a driver prices the road. No per-driver minds (user, 2026-10-01: traffic is simulated
-- as groups, not as individuals): every car on the same KIND of trip shares one profile.
-- Cars spread over alternative roads through the router's congestion and booked-load
-- pricing, not through per-car noise, and they all drive the posted limit.
--
-- The groups (user, 2026-10-05: drivers weigh more than time -- what is cheaper, what is
-- nicer -- and that should come from how the city is built):
--   commuter  work, school, job hunting: time first, keeps to the main roads a little
--   leisure   shopping and evenings out: not in a hurry, minds fuel more, and takes the
--             green / waterside street over the smoky one (RoadSceneryService)
--   freight   delivery and through trucks: big roads, few turns, off residential streets
--   visitor   through traffic: sticks to the roads a stranger would find, off side streets
-- A car's group is its "RouteStyle" attribute, set by whoever starts the trip.
--
-- Read by NavRouter (route costs) and NPCDriverService (speed, patience, reroute appetite).
-- Pure data; safe on both sides of the network boundary.

local DriverProfile = {}

export type Profile = {
	seed: number,
	jamAversion: number,
	foresight: number,
	turnAversion: number,
	useHighways: number,
	fuelSensitivity: number,
	explore: number,
	speedFactor: number,
	patience: number,
	detourTrigger: number,
	extraReroutes: number,
	label: string,
	-- Set only on a withToken view: identifies THIS trip's route booking so the router
	-- can discount the driver's own reservation when pricing a road.
	token: number?,
	-- Transit lines only: route by pure distance (NavRouter), not by time in traffic.
	shortest: boolean?,
	-- Transit lines only: drive the route as given -- no traffic reroutes, no gridlock detours.
	keepRoute: boolean?,
	-- 0..0.3: how far a street's look (RoadSceneryService, -1 ugly .. 1 lovely) moves its
	-- price. 0.3 makes a lovely street feel 30% shorter and a smoky one 30% longer.
	scenery: number?,
	-- 0..1: extra price, as a share of the time, on a local street lined only with homes.
	residentialAversion: number?,
}

-- The middle of every old trait range: the average driver the city always had.
DriverProfile.DEFAULT = table.freeze({
	seed = 0, jamAversion = 1.25, foresight = 0.85, turnAversion = 1.15, useHighways = 0.5,
	fuelSensitivity = 1.05, explore = 0, speedFactor = 1, patience = 1, detourTrigger = 0.3,
	extraReroutes = 0, label = "commuter", scenery = 0, residentialAversion = 0.05,
}) :: Profile

-- Shopping and evenings out. Every field not set here is the commuter's.
DriverProfile.LEISURE = table.freeze({
	seed = 0, jamAversion = 1.0, foresight = 0.85, turnAversion = 1.0, useHighways = 0.4,
	fuelSensitivity = 1.35, explore = 0, speedFactor = 1, patience = 1, detourTrigger = 0.3,
	extraReroutes = 0, label = "leisure", scenery = 0.3, residentialAversion = 0,
}) :: Profile

-- Trucks: a big vehicle avoids tight turns and housing streets, and fuel is the firm's money.
DriverProfile.FREIGHT = table.freeze({
	seed = 0, jamAversion = 1.1, foresight = 0.85, turnAversion = 1.8, useHighways = 0.85,
	fuelSensitivity = 1.5, explore = 0, speedFactor = 1, patience = 1, detourTrigger = 0.3,
	extraReroutes = 0, label = "freight", scenery = 0, residentialAversion = 0.8,
}) :: Profile

-- Through traffic: a stranger reads the city's traffic less well (foresight) and follows the
-- signs along the main roads rather than cutting through side streets.
DriverProfile.VISITOR = table.freeze({
	seed = 0, jamAversion = 1.0, foresight = 0.5, turnAversion = 1.3, useHighways = 0.8,
	fuelSensitivity = 1.0, explore = 0, speedFactor = 1, patience = 1, detourTrigger = 0.3,
	extraReroutes = 0, label = "visitor", scenery = 0, residentialAversion = 0.5,
}) :: Profile

local BY_STYLE: { [string]: Profile } = {
	commuter = DriverProfile.DEFAULT,
	leisure = DriverProfile.LEISURE,
	freight = DriverProfile.FREIGHT,
	visitor = DriverProfile.VISITOR,
}

-- Buses (and trains) take the SHORTEST way (user), line legs and depot runs alike.
DriverProfile.SHORTEST = table.freeze({
	seed = 0, jamAversion = 0, foresight = 0, turnAversion = 0, useHighways = 1, fuelSensitivity = 0,
	explore = 0, speedFactor = 1, patience = 1, detourTrigger = 1, extraReroutes = 0, label = "shortest",
	shortest = true, keepRoute = true,
}) :: Profile

-- explore is 0 for both profiles: no per-edge bias.
function DriverProfile.edgeBias(_profile: Profile?, _edgeId: string): number
	return 1
end

-- @deprecated: per-driver seeds are gone; every seed is DEFAULT.
function DriverProfile.forSeed(_seed: number): Profile
	return DriverProfile.DEFAULT
end

function DriverProfile.fromModel(model: Instance?): Profile?
	if not model then
		return nil
	end
	if model:GetAttribute("ShortestRoute") == true then
		return DriverProfile.SHORTEST
	end
	local style = model:GetAttribute("RouteStyle")
	return (if typeof(style) == "string" then BY_STYLE[style] else nil) or DriverProfile.DEFAULT
end

-- The group profile for a RouteStyle name ("commuter", "leisure", "freight", "visitor").
function DriverProfile.forStyle(style: string?): Profile
	return (if style then BY_STYLE[style] else nil) or DriverProfile.DEFAULT
end

-- A per-TRIP view of the shared profile: the token tells the router "this booking is mine".
function DriverProfile.withToken(profile: Profile?, token: number): Profile?
	if not profile then
		return nil
	end
	return (setmetatable({ token = token }, { __index = profile }) :: any) :: Profile
end

return DriverProfile
