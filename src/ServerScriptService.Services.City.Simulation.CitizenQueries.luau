--!strict
-- Read-only household rosters, location and outdoor presence. State remains owned by
-- CitizenService; queries use current dependency/state getters across city restores.
export type Context = {
	getHouseholds: () -> {[number]: any},
	getBuildingService: () -> any,
	getWalkingService: () -> any,
	getTimeService: () -> any,
	findPerson: (number) -> any?,
	homeFocusPosition: (string) -> Vector3?,
	personLabel: (any, any) -> string,
	kidLabel: (any, any) -> string,
	door: (string) -> Vector3?,
	travelDecision: (number) -> any?,
	presenceFrontCos: number,
}
export type Queries = {
	getFamilyInfo: (string) -> any?,
	getWorkforceInfo: (string) -> any?,
	getAdminPersonDebug: (number) -> {[string]: any}?,
	getPersonWhereabouts: (number) -> {pos: Vector3, status: string, follow: BasePart?}?,
	getPresenceNear: (CFrame, number, number) -> {any},
}
local CitizenQueries = {}
function CitizenQueries.new(context: Context): Queries
	local queries = {} :: Queries
function queries.getFamilyInfo(homeId: string): { familyName: string, members: { { name: string, gender: string, age: number, role: string, employed: boolean, pid: number } } }?
	local homeZone = if context.getBuildingService().getBuildingZone then context.getBuildingService().getBuildingZone(homeId) else nil
	if homeZone ~= "Residential" then return nil end

	local here: { any } = {}
	for _, h in context.getHouseholds() do
		if h.homeId == homeId then table.insert(here, h) end
	end
	if #here == 0 then return nil end
	table.sort(here, function(a, b) return a.id < b.id end)

	-- A big home holds several families, so the roster is every household's people in
	-- turn. Surnames are only worth spelling out once there is more than one family.
	local showSurname = #here > 1
	local members: { any } = {}
	for _, h in here do
		local adults = table.clone(h.adults)
		table.sort(adults, function(a, b) return a.age > b.age end)
		local kids = table.clone(h.kids)
		table.sort(kids, function(a, b) return a.age > b.age end)
		local function label(name: string): string
			return if showSurname then name .. " " .. h.familyName else name
		end
		for _, a in adults do
			table.insert(members, { name = label(a.name), gender = a.gender, age = a.age, role = "Adult", employed = a.jobId ~= nil, pid = a.pid })
		end
		for _, k in kids do
			table.insert(members, { name = label(k.name), gender = k.gender, age = k.age, role = "Child", employed = false, pid = k.pid })
		end
	end

	return { familyName = here[1].familyName, households = #here, members = members }
end

-- Workforce roster for a commercial/industrial building's info panel: everyone whose
-- job is here, with their family name + age + gender + a safe focus point for the
-- residential home they live in. Oldest first.
function queries.getWorkforceInfo(workplaceId: string): { workers: { { name: string, familyName: string, age: number, gender: string, homeId: string, homePos: Vector3?, pid: number } } }?
	local workers: { any } = {}
	for _, h in context.getHouseholds() do
		local homeZone = if context.getBuildingService().getBuildingZone then context.getBuildingService().getBuildingZone(h.homeId) else nil
		if homeZone ~= "Residential" then continue end
		for _, a in h.adults do
			if a.jobId == workplaceId then
				local homePos = context.homeFocusPosition(h.homeId)
				table.insert(workers, {
					name = a.name, familyName = h.familyName, age = a.age, gender = a.gender,
					homeId = h.homeId, homePos = homePos,
					pid = a.pid,
				})
			end
		end
	end
	table.sort(workers, function(a, b) return a.age > b.age end)
	return { workers = workers }
end

-- Where a person is RIGHT NOW, for the "locate" dot on a roster row, keyed by their
-- stable pid. A MOVING citizen (driving the family car, or walking a leg) returns the
-- live part to FOLLOW so the camera tracks them continuously; a settled one (at work / at
-- home / a child) returns a static point to fly to once.
function queries.getAdminPersonDebug(pid: number): { [string]: any }?
	local found = context.findPerson(pid)
	if not found then return nil end
	local h = found.h
	do
		for _, a in h.adults do
			if a.pid == pid then
				local targetId = a.tripTargetId or a.outDestId
				return {
					kind = "adult",
					pid = pid,
					name = context.personLabel(h, a),
					age = a.age,
					stage = a.stage,
					homeId = h.homeId,
					jobId = a.jobId,
					destinationId = targetId,
					destinationPos = if targetId then context.door(targetId) else nil,
					purpose = if a.tripTargetHome then "Returning home"
						elseif a.outKind == "work" then "Commuting to assigned workplace"
						elseif a.outKind == "shop" then "Shopping errand"
						elseif a.outKind == "apply" then "Travelling to a job application"
						elseif a.outKind == "walk" then "Out for a walk"
						elseif a.outKind == "study" then "Going to university"
						elseif a.outKind == "leisure" then "Evening out"
						elseif a.stage == "atStudy" then "At university"
						else "No active destination",
					walkerId = a.walkerId,
					car = if a.usingCar then a.car else nil,
					ownsCar = a.ownsCar == true,
					usingCar = a.usingCar,
					modeDecision = context.travelDecision(pid),
				}
			end
		end
		for _, k in h.kids do
			if k.pid == pid then
				return {
					kind = "kid",
					pid = pid,
					name = context.kidLabel(h, k),
					age = k.age,
					stage = k.stage,
					homeId = h.homeId,
					destinationPos = k.schoolPos,
					purpose = if k.stage == "atSchool" then "Attending school" elseif k.stage == "transit" then "School commute" else "At home",
					walkerId = k.walkerId,
					modeDecision = {
						chosen = "walk",
						reason = "School pupils currently use the protected sidewalk and crosswalk network.",
					},
				}
			end
		end
	end
	return nil
end

function queries.getPersonWhereabouts(pid: number): { pos: Vector3, status: string, follow: BasePart? }?
	local found = context.findPerson(pid)
	if not found then return nil end
	local h = found.h
	do
		for _, a in h.adults do
			if a.pid == pid then
				if a.stage == "transit" then
					-- Driving their car: follow the car.
					if a.usingCar and a.car and a.car:IsDescendantOf(workspace) then
						local root = a.car.PrimaryPart or a.car:FindFirstChildWhichIsA("BasePart")
						local verb = if a.outKind == "shop" then "Driving to the shops"
							elseif a.outKind == "apply" then "Driving to a job interview"
							elseif a.outKind == "leisure" then "Driving out for the evening"
							else "Driving to work"
						if root then return { pos = root.Position, status = verb, follow = root } end
					end
					-- Walking a leg: follow the pedestrian.
					if a.walkerId then
						local root = context.getWalkingService().getCommuterRoot(a.walkerId)
						local verb = if a.outKind == "shop" then "Walking to the shops"
							elseif a.outKind == "apply" then "Walking to a job interview"
							elseif a.outKind == "walk" then "Out for a walk"
							elseif a.outKind == "study" then "Walking to university"
							elseif a.outKind == "leisure" then "Out for the evening"
							else "Walking to work"
						if root then return { pos = root.Position, status = verb, follow = root } end
					end
					-- Between legs (parked, no live part yet): fall back to a static point.
					local k = if a.outDestId then context.getBuildingService().getKerb(a.outDestId) else nil
					if k then return { pos = k, status = "On the way" } end
				end
				if a.stage == "atWork" and a.outDestId then
					local k = context.getBuildingService().getKerb(a.outDestId)
					if k then return { pos = k, status = "At work" } end
				end
				if a.stage == "atStudy" and typeof(a.studyPos) == "Vector3" then
					return { pos = a.studyPos, status = "At university" }
				end
				local hk = context.homeFocusPosition(h.homeId)
				if hk then return { pos = hk, status = "At home" } end
				return nil
			end
		end
		-- A child: they stay home, so locate flies to the family home.
		for _, k in h.kids do
			if k.pid == pid then
				if k.stage == "transit" and k.walkerId then
					local root = context.getWalkingService().getCommuterRoot(k.walkerId)
					if root then return { pos = root.Position, status = "Walking to/from school", follow = root } end
				end
				if k.stage == "atSchool" and typeof(k.schoolPos) == "Vector3" then
					return { pos = k.schoolPos, status = "At school" }
				end
				local hk = context.homeFocusPosition(h.homeId)
				if hk then return { pos = hk, status = "At home" } end
				return nil
			end
		end
	end
	return nil
end

-- Outdoor background presence near `center`, for the client's local-only renderer.
-- Settled adults at home/work and children at school are inside buildings, so they are
-- not rendered. At-home children can appear as daytime yard play in the background;
-- transit citizens are omitted because walkers/cars already represent them.
function queries.getPresenceNear(camCF: CFrame, radius: number, cap: number): { any }
	if typeof(camCF) ~= "CFrame" then return {} end
	local center = camCF.Position
	local look = camCF.LookVector
	local bySpot: { [string]: { id: string, pos: Vector3, road: Vector3?, dist: number, people: { any } } } = {}
	local order: { any } = {}
	local dayFrac = if context.getTimeService() and context.getTimeService().getDayFraction then context.getTimeService().getDayFraction() else 0.5
	local kidsCanPlayOutside = dayFrac >= 0.34 and dayFrac <= 0.72
	local function addAt(id: string, pos: Vector3, gender: string, kind: string, pid: number, road: Vector3?, age: number?)
		local e = bySpot[id]
		if not e then
			local off = pos - center
			local d = off.Magnitude
			if d > radius then return end
			-- Only spots IN FRONT of the camera (any distance up to radius); behind it the
			-- player can't see them, so they are never rendered.
			if d > 1 and off.Unit:Dot(look) < context.presenceFrontCos then return end
			e = { id = id, pos = pos, road = road, dist = d, people = {} }
			bySpot[id] = e
			table.insert(order, e)
		end
		table.insert(e.people, { g = gender, k = kind, p = pid, a = age })
	end
	for _, h in context.getHouseholds() do
		if h.arriving then continue end
		for _, a in h.adults do
			if a.waitPos then addAt(`stop:{a.waitPos}`, a.waitPos, a.gender, "adult", a.pid, a.waitRoad) end
		end
		if kidsCanPlayOutside and context.getBuildingService().getOutdoorPlaySpot then
			local playSpot = context.getBuildingService().getOutdoorPlaySpot(h.homeId)
			if typeof(playSpot) == "Vector3" then
				for _, kid in h.kids do
					if kid.stage == nil or kid.stage == "atHome" then
						addAt(h.homeId .. ":play", playSpot, kid.gender, "kid", kid.pid, nil, kid.age)
					end
				end
			end
		end
	end
	table.sort(order, function(p, q) return p.dist < q.dist end)
	local out: { any } = {}
	local total = 0
	for _, e in order do
		if total >= cap then break end
		-- Stable order within a building so a person keeps the same stand spot between polls.
		table.sort(e.people, function(p, q)
			if p.k ~= q.k then return p.k < q.k end
			return p.g < q.g
		end)
		table.insert(out, { id = e.id, pos = e.pos, road = e.road, people = e.people })
		total += #e.people
	end
	return out
end

	return queries
end
return CitizenQueries
