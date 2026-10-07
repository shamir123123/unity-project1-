--!strict
-- Executes resident journey legs; CitizenService remains the household state owner.
local CitizenTypes = require(script.Parent.CitizenTypes)
local HouseholdNeeds = require(script.Parent.HouseholdNeeds)
local Const = require(script.Parent.Parent.CitySimConstants)
local NPCDriverService = require(game.ServerScriptService.Services.NPC.NPCDriverService)
type Household = CitizenTypes.Household
type Adult = CitizenTypes.Adult
type Kid = CitizenTypes.Kid
type ParkChoice = CitizenTypes.ParkChoice
export type Context = {
	getHouseholds: () -> {[number]: Household},
	getWalkingService: () -> any, getTransitService: () -> any,
	getBuildingService: () -> any, getEducationService: () -> any,
	getSupplyService: () -> any, getEconomyService: () -> any,
	getFolder: () -> Folder,
	trips: {[Model]: any}, workers: {[string]: number}, driverJobs: {[string]: number},
	cars: any, garage: any,
	personLabel: (Household, Adult) -> string, kidLabel: (Household, Kid) -> string,
	chooseTravelMode: (Household, Adult, Vector3?, Vector3?, boolean) -> (string, any),
	door: (string) -> Vector3?, flatDist: (Vector3, Vector3) -> number,
	nav: () -> any?,
	driveTo: (Model, CFrame, (() -> ())?, any?) -> (),
	releaseSpot: (Adult) -> (),
	pickHomePark: (Household, Adult) -> ParkChoice?,
	pickBuildingPark: (Household, string) -> ParkChoice?,
	isSchoolAge: (Kid) -> boolean,
	serviceKerb: (string) -> Vector3?,
	dwellUntil: (string) -> number,
}
export type Journeys = {
	journey: (Household, Adult, number, Vector3?, Vector3?, boolean, (() -> ParkChoice?)?, () -> ()) -> (),
	returnHome: (Household, Adult) -> (),
	startWork: (Household, Adult, string) -> (),
	startErrand: (Household, Adult, string, string, number) -> (),
	startSchool: (Household, Kid) -> boolean,
	returnFromSchool: (Household, Kid) -> boolean,
}
local CitizenJourneys = {}
function CitizenJourneys.new(context: Context): Journeys
	local Cars, Garage = context.cars, context.garage
local function rideTransit(h: Household, a: Adult, trip: number, fromDoor: Vector3, toDoor: Vector3,
	estimate: any, board: any, label: string, look: any, onArrive: () -> ())
	local function stale(): boolean
		return context.getHouseholds()[h.id] == nil or a.tripId ~= trip
	end
	local function walkOn(from: Vector3)
		if stale() then return end
		a.riderId = nil
		a.waitPos = nil
		a.walkerId = context.getWalkingService().spawnCommuter(from, toDoor, function()
			if stale() then return end
			a.walkerId = nil
			onArrive()
		end, label, look)
	end
	a.walkerId = context.getWalkingService().spawnCommuter(fromDoor, board.pos, function()
		if stale() then return end
		a.walkerId = nil
		a.waitPos = board.pos
		a.waitRoad = board.roadPos
		a.riderId = context.getTransitService().waitForRide(estimate.routeId, estimate.boardStopId, estimate.alightStopId,
			function() if not stale() then a.waitPos = nil end end,
			walkOn,
			function() walkOn(board.pos) end,
			-- the bus is in: walk up to its door, then step on (the bus waits for `stepOn`)
			function(door: Vector3, stepOn: () -> ())
				local from = a.waitPos
				if stale() or not from then stepOn(); return end
				a.waitPos = nil
				a.walkerId = context.getWalkingService().spawnCommuter(from, door, function()
					a.walkerId = nil
					stepOn()
				end, label, look)
			end)
	end, label, look)
end

-- Generic one-way journey for one adult, fully simulated: walked, ridden or driven in their
-- own car, as chooseTravelMode decides. `parkPicker` is called only on the drive path.
-- onArrive fires once at the destination. Every callback is tripId-guarded on the adult,
-- so a superseded / restarted trip can't desync the legs.
local function journey(h: Household, a: Adult, trip: number, fromDoor: Vector3?, toDoor: Vector3?,
	wantCar: boolean, parkPicker: (() -> ParkChoice?)?, onArrive: () -> ())
	local label = context.personLabel(h, a)
	local look = { gender = a.gender, kind = if a.age < 18 then "kid" else "adult", seed = a.pid, age = a.age }
	local function stale(): boolean
		return context.getHouseholds()[h.id] == nil or a.tripId ~= trip
	end
	local canDrive = wantCar and a.car ~= nil and parkPicker ~= nil
	local mode, transitEstimate = context.chooseTravelMode(h, a, fromDoor, toDoor, canDrive)

	if mode == "transit" and transitEstimate and fromDoor and toDoor and context.getTransitService() then
		local board = context.getTransitService().getStop(transitEstimate.boardStopId)
		local alight = context.getTransitService().getStop(transitEstimate.alightStopId)
		if board and alight then
			rideTransit(h, a, trip, fromDoor, toDoor, transitEstimate, board, label, look, onArrive)
			return
		end
		mode = "walk"
	end


	if mode ~= "drive" then
		a.walkerId = context.getWalkingService().spawnCommuter(fromDoor, toDoor, function()
			if stale() then return end
			a.walkerId = nil
			onArrive()
		end, label, look)
		return
	end

	a.usingCar = true
	local car = a.car :: Model
	car:SetAttribute("CitizenPid", a.pid)
	car:SetAttribute("TripPurpose", if a.tripTargetHome then "Returning home"
		elseif a.outKind == "work" then "Commuting to assigned workplace"
		elseif a.outKind == "shop" then "Shopping errand"
		elseif a.outKind == "leisure" then "Evening out"
		elseif a.outKind == "apply" then "Travelling to a job application"
		elseif a.outKind == "schoolrun" then "Driving the children to school"
		else "Citizen trip")
	-- Which group's mind prices the roads (DriverProfile): shopping and evenings out are not
	-- in a hurry and take the nicer street; work, school and job hunting go the quick way.
	car:SetAttribute("RouteStyle", if a.outKind == "shop" or a.outKind == "leisure" or a.outKind == "walk"
		then "leisure" else "commuter")
	-- Leg 1: walk from the door to the parked car.
	a.walkerId = context.getWalkingService().spawnCommuter(fromDoor, car:GetPivot().Position, function()
		if stale() then return end
		a.walkerId = nil
		local choice = (parkPicker :: any)() :: ParkChoice?
		if not choice or not choice.cf then
			-- Parking disappeared while the citizen was walking to the car. Leave the car
			-- where it is and finish this leg on foot instead of moving it invisibly.
			a.usingCar = false
			if toDoor then
				a.walkerId = context.getWalkingService().spawnCommuter(car:GetPivot().Position, toDoor, function()
					if stale() then return end
					a.walkerId = nil
					onArrive()
				end, label, look)
			else
				onArrive()
			end
			return
		end
		local oldLot = if a.parkSpotId then a.parkSpotId:match("^(lot%d+)#") else nil
		local newLot = if choice.spotId then choice.spotId:match("^(lot%d+)#") else nil
		local oldBuilding = if a.parkStallKey then a.parkStallKey:match("^(.-)#") else nil
		local newBuilding = if choice.stallKey then choice.stallKey:match("^(.-)#") else nil
		if (oldLot and oldLot == newLot) or (oldBuilding and oldBuilding == newBuilding) then
			context.releaseSpot({parkSpotId=choice.spotId,parkStallKey=choice.stallKey} :: any)
			a.walkerId = context.getWalkingService().spawnCommuter(car:GetPivot().Position,toDoor,function()
				if stale() then return end
				a.walkerId=nil
				onArrive()
			end,label,look)
			return
		end
		local departureParking = {parkSpotId=a.parkSpotId,parkStallKey=a.parkStallKey}
		a.departureParking = departureParking
		local function releaseDeparture()
			if a.departureParking ~= departureParking then return end
			context.releaseSpot(departureParking :: any)
			a.departureParking = nil
		end
		a.parkSpotId = choice.spotId
		a.parkStallKey = choice.stallKey
		-- How to LEAVE the spot the car is in right now (stored when it last parked).
		local prevEgress = a.parkEgress
		local prevGraph = a.parkGraphPoint
		-- Leg 2: pull out of the old spot, drive the road, drive INTO the new stall. A car
		-- that was pocketed reappears on the road where it was left, once that is clear.
		Cars.fetchWhenClear(car, function()
		if stale() then return end
		context.driveTo(car, choice.cf, function()
			if stale() then return end
			-- Remember how to leave THIS spot on the next trip.
			a.parkEgress = choice.egress
			a.parkGraphPoint = choice.lotExit or choice.lotEntry
			-- A metered street bay or car park away from home: the city collects the fee
			-- (ParkingService.priceAt -- free while the street has room). A school drop is not a stay.
			if choice.spotId and not a.tripTargetHome and a.outKind ~= "schoolrun" then
				local fee = context.cars.parkingFee(choice.cf.Position)
				local economy = context.getEconomyService()
				if fee > 0 and economy and economy.credit then economy.credit(fee) end
			end
			-- Into the block's own garage: the car is gone and its driver is already indoors.
			if choice.garage then
				Garage.stow(car)
				onArrive()
				return
			end
			-- No legal spot: they got out on the road. At home the family gives the car up
			-- (no space near home, no car -- Cities: Skylines II); it is bought back once a
			-- space frees up. Away it waits in the pocket for the trip home.
			if choice.pocket then
				Cars.notePocket(h.id)
				if a.tripTargetHome then Cars.drop(a) else Garage.stow(car) end
			end
			-- Leg 3: walk from the parked car to the destination door, then enter.
			a.walkerId = context.getWalkingService().spawnCommuter(choice.cf.Position, toDoor, function()
				if stale() then return end
				a.walkerId = nil
				onArrive()
			end, label, look)
		end, {
			pocket = choice.pocket,
			onDepart = releaseDeparture,
			fromGraphPoint = prevGraph,
			egress = prevEgress,
			toGraphPoint = choice.lotEntry,
			exitGraphPoint = choice.lotExit,
			approach = choice.approach,
			isValid = function() return not stale() end,
		})
		end, function() return not stale() end)
	end, label, look)
end

-- Walk/drive one adult home and settle them to "atHome". If they took the family car out,
-- they bring it back and release it here.
local function returnHome(h: Household, a: Adult)
	if context.getHouseholds()[h.id] == nil then return end
	a.tripId += 1
	a.dwellUntil = nil
	local trip = a.tripId
	if a.walkerId then context.getWalkingService().despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then context.getTransitService().cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	local fromDoor = if a.outDestId then context.door(a.outDestId) else nil
	a.stage = "transit"
	a.tripTargetId = h.homeId
	a.tripTargetHome = true
	journey(h, a, trip, fromDoor, context.door(h.homeId), a.usingCar, function() return context.pickHomePark(h, a) end, function()
		a.stage = "atHome"
		a.outKind = nil
		a.outDestId = nil
		a.tripTargetId = nil
		a.tripTargetHome = false
		a.usingCar = false
	end)
end

-- On arrival at a workplace to APPLY: this adult takes a still-open job if one remains.
-- Delivery drivers out from the building also hold slots, so count them against capacity.
local function applyForJob(h: Household, a: Adult, destId: string, cap: number)
	if a.jobId then return end
	if ((context.workers[destId] or 0) + (context.driverJobs[destId] or 0)) >= cap then return end
	if not (context.getBuildingService().getKerb(destId) or context.serviceKerb(destId)) then return end -- gone while travelling
	context.workers[destId] = (context.workers[destId] or 0) + 1
	a.jobId = destId
	a.joblessDays = 0
end

-- On arrival at a store to SHOP: spend money, crediting the store's revenue to the city.
local function doShopping(h: Household, destId: string)
	if not context.getBuildingService().getKerb(destId) then return end
	-- Buy real goods off the store's shelf. An empty shelf earns nothing -- the
	-- supply-chain penalty for an understocked shop -- which keeps commercial demand
	-- up until the player builds the industry + roads to keep it stocked.
	local bought = context.getSupplyService().consumeStock(destId, Const.SUPPLY_SHOP_BASKET)
	if bought <= 0 then return end
	HouseholdNeeds.buy(h, bought)
	-- Retail income is tracked (drained by the economy tick) so the budget panel can
	-- show it as its own line, instead of silently appearing in the treasury.
	if context.getEconomyService().addRetailIncome then
		context.getEconomyService().addRetailIncome(bought * Const.SUPPLY_SHOP_PRICE)
	else
		context.getEconomyService().credit(bought * Const.SUPPLY_SHOP_PRICE)
	end
end

-- One adult's daily WORK trip out; they stay at work until their own homebound window.
local function startWork(h: Household, a: Adult, jobId: string)
	a.tripId += 1
	a.dwellUntil = nil
	local trip = a.tripId
	if a.walkerId then context.getWalkingService().despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then context.getTransitService().cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	a.stage = "transit"
	a.outKind = "work"
	a.outDestId = jobId
	a.tripTargetId = jobId
	a.tripTargetHome = false
	journey(h, a, trip, context.door(h.homeId), context.door(jobId), true, function() return context.pickBuildingPark(h, jobId) end, function()
		a.stage = "atWork"
		a.tripTargetId = nil
		a.tripTargetHome = false
	end)
end

-- An errand round-trip for one adult: go to a workplace/store, do the action (apply /
-- shop) on arrival, return home.
local function startErrand(h: Household, a: Adult, kind: string, destId: string, cap: number)
	a.tripId += 1
	a.dwellUntil = nil
	local trip = a.tripId
	if a.walkerId then context.getWalkingService().despawnCommuter(a.walkerId); a.walkerId = nil end
	if a.riderId then context.getTransitService().cancelRider(a.riderId); a.riderId = nil; a.waitPos = nil end
	a.stage = "transit"
	a.outKind = kind
	a.outDestId = destId
	a.tripTargetId = destId
	a.tripTargetHome = false
	journey(h, a, trip, context.door(h.homeId), context.door(destId), true, function() return context.pickBuildingPark(h, destId) end, function()
		if kind == "shop" or kind == "leisure" then
			doShopping(h, destId)
			-- They stay inside a while, the car in the shop's lot; doActivities sends them home.
			-- Turning straight round at the door read as people wandering, and lots stood empty.
			a.dwellUntil = context.dwellUntil(kind)
			return
		end
		if kind == "apply" then applyForJob(h, a, destId, cap) end
		returnHome(h, a)
	end)
end

-- A child at the school gate goes in (or, if the school closed meanwhile, back to being home).
local function enterSchool(k: Kid, schoolId: number)
	k.walkerId = nil
	k.escortRun, k.escortUntil = nil, nil
	local edu = context.getEducationService()
	if edu and edu.hasSchool and not edu.hasSchool(schoolId, k.age) then
		k.stage = "atHome"
		k.schoolId = nil
		k.schoolPos = nil
		return
	end
	if edu and edu.enterSchool then edu.enterSchool(schoolId) end
	k.stage = "atSchool"
end

-- The school run: the parent drives the children in `run` to the school gate, sees them in,
-- and drives home again. The children ride along -- no walker of their own -- and go in when
-- the car gets there. A run that cannot find a bay near the school becomes a walk (journey's
-- own fallback) and the children walk in with the parent.
local SCHOOL_RUN_DEADLINE_DAYS = 3 / 24 -- game days a run may take before its children are freed
local function schoolRun(h: Household, p: Adult, run: any, fromDoor: Vector3, schoolPos: Vector3)
	p.tripId += 1
	p.dwellUntil = nil
	local trip = p.tripId
	if p.walkerId then context.getWalkingService().despawnCommuter(p.walkerId); p.walkerId = nil end
	if p.riderId then context.getTransitService().cancelRider(p.riderId); p.riderId = nil; p.waitPos = nil end
	p.stage = "transit"
	p.outKind = "schoolrun"
	p.outDestId = nil
	p.tripTargetId = nil
	p.tripTargetHome = false
	p.usingCar = true -- the children are in the car: this leg is driven (chooseTravelMode)
	journey(h, p, trip, fromDoor, schoolPos, true, function() return context.cars.parkNear(schoolPos) end, function()
		run.outbound = false
		for _, kid in run.kids do
			if kid.escortRun == run and kid.stage == "transit" then enterSchool(kid, run.schoolId) end
		end
		if context.getHouseholds()[h.id] ~= h or p.tripId ~= trip then return end
		p.tripId += 1
		local back = p.tripId
		p.tripTargetId = h.homeId
		p.tripTargetHome = true
		journey(h, p, back, schoolPos, context.door(h.homeId), p.usingCar, function() return context.pickHomePark(h, p) end, function()
			p.stage = "atHome"
			p.outKind = nil
			p.tripTargetId = nil
			p.tripTargetHome = false
			p.usingCar = false
			p.schoolRun = nil
		end)
	end)
end

local function startSchool(h: Household, k: Kid): boolean
	if not context.getEducationService() or not context.getEducationService().getNearestSchool or not context.isSchoolAge(k) then return false end
	local fromDoor = context.door(h.homeId)
	if not fromDoor then return false end
	local schoolPos, schoolId = context.getEducationService().getNearestSchool(fromDoor, k.age, k.schoolId)
	if typeof(schoolPos) ~= "Vector3" or typeof(schoolId) ~= "number" then
		k.schoolId = nil
		k.schoolPos = nil
		return false
	end
	k.tripId += 1
	local trip = k.tripId
	if k.walkerId then context.getWalkingService().despawnCommuter(k.walkerId); k.walkerId = nil end
	if k.riderId then context.getTransitService().cancelRider(k.riderId); k.riderId=nil; k.waitPos=nil end
	k.stage = "transit"
	k.tripTargetHome = false
	k.schoolPos = schoolPos
	k.schoolId = schoolId
	local function stale(): boolean
		return context.getHouseholds()[h.id] == nil or k.tripId ~= trip
	end
	-- Driven by a parent, or riding along with a brother or sister already going.
	local runBy = context.cars and context.cars.schoolRunBy
	local parent, joined = nil, false
	if runBy then parent, joined = runBy(h, k, fromDoor, schoolPos, schoolId) end
	if parent and parent.schoolRun then
		local run = parent.schoolRun
		k.escortRun = run
		k.escortUntil = context.cars.gameNow() + SCHOOL_RUN_DEADLINE_DAYS
		context.cars.countMode("schoolRun")
		if not joined then schoolRun(h, parent, run, fromDoor, schoolPos) end
		return true
	end
	journey(h, k :: any, trip, fromDoor, schoolPos, false, nil, function()
		if stale() then return end
		enterSchool(k, schoolId)
	end)
	return true
end

local function returnFromSchool(h: Household, k: Kid): boolean
	if context.getHouseholds()[h.id] == nil then return false end
	local toDoor = context.door(h.homeId)
	local fromDoor = k.schoolPos
	if typeof(toDoor) ~= "Vector3" then return false end
	if typeof(fromDoor) ~= "Vector3" then
		k.stage = "atHome"
		k.schoolPos = nil
		return true
	end
	k.tripId += 1
	local trip = k.tripId
	if k.walkerId then context.getWalkingService().despawnCommuter(k.walkerId); k.walkerId = nil end
	if k.riderId then context.getTransitService().cancelRider(k.riderId); k.riderId=nil; k.waitPos=nil end
	if k.stage == "atSchool" and context.getEducationService() and context.getEducationService().leaveSchool then
		context.getEducationService().leaveSchool(k.schoolId)
	end
	k.stage = "transit"
	k.tripTargetHome = true
	local function stale(): boolean
		return context.getHouseholds()[h.id] == nil or k.tripId ~= trip
	end
	journey(h, k :: any, trip, fromDoor, toDoor, false, nil, function()
		if stale() then return end
		k.walkerId = nil
		k.stage = "atHome"
		k.schoolPos = nil
		if k.schoolId and context.getEducationService() and context.getEducationService().hasSchool and not context.getEducationService().hasSchool(k.schoolId, k.age) then
			k.schoolId = nil
		end
	end)
	return true
end


return table.freeze({
	applyForJob = applyForJob, doShopping = doShopping,
	journey = journey, returnHome = returnHome, startWork = startWork,
	startErrand = startErrand, startSchool = startSchool, returnFromSchool = returnFromSchool,
})
end
return CitizenJourneys
