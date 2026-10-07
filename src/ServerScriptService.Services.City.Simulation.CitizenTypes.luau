--!strict
export type Person = { name: string, gender: string, age: number, pid: number }
export type Adult = {
	name: string, gender: string, age: number, pid: number,
	jobId: string?, joblessDays: number, eduLevel: number,
	-- Per-person activity FSM. `stage` is one of: atHome, transit, atWork. `tripId` is a
	-- monotonic token; a leg's async callback only acts while a.tripId still matches
	-- (late/superseded fires are ignored). `walkerId` is this adult's live commuter
	-- pedestrian, if any. `outKind`/`outDestId` describe the current trip (work / apply /
	-- shop) and its target. `usingCar` is true while this adult's own car is out with them.
	stage: string, tripId: number, walkerId: number?,
	outKind: string?, outDestId: string?, usingCar: boolean,
	-- Their OWN car (about nine adults in ten have one, TravelModeChoice.ownsCar) and where
	-- it stands: the plot's driveway if this adult holds it, else a bay / lot stall, plus how
	-- to leave that spot next trip (in-lot egress + the road hand-off point).
	nextCarAttemptAt: number?, ownsCar: boolean?, car: Model?, homeParkCF: CFrame?, parkSpotId: string?, parkStallKey: string?,
	departureParking: {parkSpotId: string?, parkStallKey: string?}?,
	-- On public transport: their place in TransitService's rider list, and while they are
	-- still standing at the stop, where (so the stop shows its crowd).
	riderId: number?, waitPos: Vector3?, waitRoad: Vector3?, -- waitRoad: the stop's lane point (which way the kerb runs)
	driveKey: string?, parkEgress: { Vector3 }?, parkGraphPoint: Vector3?,
	tripTargetId: string?, tripTargetHome: boolean,
	commutedWorkDay: number, commutedHomeDay: number, nextErrandAt: number,
	-- University (Trips.student): a high-school graduate of university age who chose to go
	-- on studying (`wantsStudy`, stable per person) and the university they attend, if a
	-- seat was found. Students go to classes instead of hunting for work.
	wantsStudy: boolean?, studyId: number?, studyPos: Vector3?, commutedStudyDay: number?,
	-- Inside a shop / restaurant (stage stays "transit": out on the errand) until this game
	-- day; doActivities then sends them home. Not saved: a reload re-runs the errand.
	dwellUntil: number?,
	-- Driving the children to school this morning (CitizenJourneys.schoolRun). Not saved.
	schoolRun: SchoolRun?,
}
-- One parent's drive to a school with the children in the car: siblings for the same school
-- climb in while it is still outbound.
export type SchoolRun = { schoolId: number, kids: { Kid }, outbound: boolean }
export type Kid = {
	name: string, gender: string, age: number, pid: number,
	-- School-run FSM (walking or public transport): atHome / transit / atSchool.
	stage: string, tripId: number, walkerId: number?, riderId: number?, waitPos: Vector3?, schoolPos: Vector3?, schoolId: number?,
	commutedSchoolDay: number, commutedHomeDay: number, bestTier: number, tripTargetHome: boolean?,
	-- Riding in a parent's car to school, and the game day by which that run must have got
	-- them there (a run lost to a household change frees the child). Not saved.
	escortRun: SchoolRun?, escortUntil: number?,
}
export type Household = {
	id: number, homeId: string, adults: { Adult }, kids: { Kid }, foundedDay: number, arriving: boolean,
	familyName: string,
	-- Set only while this family's house is gone: the moment they give up searching, and
	-- where the search has walked them to so far. `lastHomePos` is kept for every household
	-- (refreshed each sim step) because by the time we notice the home is gone, there is
	-- nothing left to ask where it stood.
	homelessUntil: number?, homelessPos: Vector3?, lastHomePos: Vector3?,
	-- Game-seconds this family's home has gone without power, water or a drain.
	unservedFor: number?,
	-- Set when the family decides to leave a home that lost its road: they go house-hunting
	-- (Homeless) while it still stands. Cleared when they move in somewhere.
	movingOut: boolean?,
	-- Game time (days) of this family's next shopping trip; set on first sight, not saved.
	nextShopAt: number?, -- legacy; goods inventory now drives shopping
	goodsStock: number?, goodsUpdatedAt: number?,
	nextLeisureAt: number?, -- game day of the family's next evening out (Trips.LEISURE_PER_WEEK)
}


export type ParkChoice = { cf: CFrame, spotId: string?, stallKey: string?, approach: { Vector3 }?, egress: { Vector3 }?, lotEntry: Vector3?, lotExit: Vector3?, pocket: boolean?, garage: boolean? }
return table.freeze({})
