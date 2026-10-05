--!strict
-- DriverProfile
-- How a driver prices the road. ONE shared profile for every car (user, 2026-10-01: no
-- per-driver minds -- traffic is simulated as groups, not as individuals). Cars spread
-- over alternative roads through the router's congestion and booked-load pricing, not
-- through per-car noise, and they all drive the posted limit.
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
}

-- The middle of every old trait range: the average driver the city always had.
DriverProfile.DEFAULT = table.freeze({
	seed = 0, jamAversion = 1.25, foresight = 0.85, turnAversion = 1.15, useHighways = 0.5,
	fuelSensitivity = 1.05, explore = 0, speedFactor = 1, patience = 1, detourTrigger = 0.3,
	extraReroutes = 0, label = "commuter",
}) :: Profile

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
	return DriverProfile.DEFAULT
end

-- A per-TRIP view of the shared profile: the token tells the router "this booking is mine".
function DriverProfile.withToken(profile: Profile?, token: number): Profile?
	if not profile then
		return nil
	end
	return (setmetatable({ token = token }, { __index = profile }) :: any) :: Profile
end

return DriverProfile
