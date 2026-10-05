-- Two car parks on a busy two-way street (A at x=0 north side, B at x=-300 south side) plus a
-- side street. Lot cars pull out (left and right) into traffic and turn in at the other lot,
-- through CitizenService's real legs (driveTo: egress -> road -> approach).
local C = require("./common")
local W = C.W
local V3, CF = W.V3, W.CF
local E = W.E
local process = require("@lune/process")
local through = tonumber(process.args[1]) or 0.25 -- through cars/s per direction
local lotRate = tonumber(process.args[2]) or 0.1  -- departures/s per lot
local secs = tonumber(process.args[3]) or 400
local kind = process.args[4] or "NarrowRoad"
local single = process.args[5] == "single" -- one shared in/out throat
local net = W.newCity()
local L = 600
W.road(V3.new(-L, 0, 0), V3.new(L, 0, 0), kind)
W.road(V3.new(60, 0, 0), V3.new(60, 0, 300), kind)
W.rebuild()
W.boot({ viewerPos = V3.new(0, 200, 0) })
local Cit = W.loadCitizens()
local lab = Cit._lab
local pocketLog = {}
local origStow = lab.garage.stow
lab.garage.stow = function(car)
	if car and car.Parent and car.Parent ~= lab.garage.folder then
		local d = Cit.getVehicleTripDebug(car)
		local pose = W.Driver.GetLivePose(car) or car:GetPivot()
		table.insert(pocketLog, string.format("POCKET %s at (%.0f,%.0f) leg=%s dist=%s/%s gate=%s waitingGap=%s leaves=%s blockedBy=%s",
			car.Name, pose.Position.X, pose.Position.Z, tostring(d ~= nil), d and string.format("%.1f", d.distance) or "-",
			d and string.format("%.1f", d.total) or "-", d and tostring(d.gateDist) or "-", d and tostring(d.waitingForRoadGap) or "-",
			d and tostring(d.leavesRoad) or "-", d and tostring(d.blockerName) or "-")
			.. " via " .. (debug.traceback("", 2):gsub("\n", " | "):sub(1, 400)))
	end
	return origStow(car)
end
local spec = W.req("ReplicatedStorage.Road.RoadTypeCatalog").getOrDefault(kind)
local half = spec.width * 0.5
local folder = E.Instance.new("Folder"); folder.Name = "Citizens"; folder.Parent = E.Workspace:FindFirstChild("_City")
local function makeLot(cx, side) -- side -1 = north (z<0), +1 = south
	local lot = { cx = cx, side = side, stalls = {}, cars = {} }
	local mz = side * (half + 4)
	local dx = if single then 0 else 3
	lot.mouthOut = V3.new(cx + dx, 0, mz)
	lot.mouthIn = V3.new(cx - dx, 0, mz)
	for i = -6, 6 do table.insert(lot.stalls, { pos = V3.new(cx + i * 6, 0, mz + side * 26), free = true }) end
	function lot.egress(st) return { V3.new(st.pos.X, 0, mz + side * 18), V3.new(cx + dx, 0, mz + side * 12), lot.mouthOut } end
	function lot.approach(st) return { V3.new(cx - dx, 0, mz + side * 12), V3.new(st.pos.X, 0, mz + side * 18), st.pos } end
	function lot.freeStall() for _, s in lot.stalls do if s.free then return s end end return nil end
	return lot
end
local lots = { makeLot(0, -1), makeLot(-300, 1) }
local function park(lot, car, st)
	st.free = false
	car:PivotTo(CF.lookAt(st.pos + V3.new(0, 0.6, 0), st.pos + V3.new(0, 0.6, -lot.side)))
	lot.cars[car] = st
end
local n = 0
for _, lot in lots do
	for i, st in lot.stalls do
		if i % 2 == 0 then
			n += 1
			local car = W.VehicleFactory.build("LotCar" .. n)
			car.Parent = folder
			park(lot, car, st)
		end
	end
end
local stats = { left = 0, done = 0, maxTrip = 0, trips = {} }
local function depart(from, to)
	local list = {}
	for car in from.cars do table.insert(list, car) end
	if #list == 0 then return end
	local st2 = to.freeStall()
	if not st2 then return end
	local car = list[math.random(1, #list)]
	local st = from.cars[car]
	from.cars[car] = nil
	st2.free = false
	stats.left += 1
	local t0 = E.now
	lab.driveTo(car, CF.lookAt(st2.pos + V3.new(0, 0.6, 0), st2.pos + V3.new(0, 0.6, -to.side)), function()
		stats.done += 1
		local d = E.now - t0
		stats.maxTrip = math.max(stats.maxTrip, d)
		to.cars[car] = st2
	end, { fromGraphPoint = from.mouthOut, egress = from.egress(st), onDepart = function() st.free = true end,
		toGraphPoint = to.mouthIn, exitGraphPoint = if single then nil else to.mouthOut, approach = to.approach(st2) })
end
local ends = { C.armEnd(V3.new(-L, 0, 0), V3.zero), C.armEnd(V3.new(L, 0, 0), V3.zero), C.armEnd(V3.new(60, 0, 300), V3.new(60, 0, 0)) }
local accA, accB = 0, 0.5
local res = C.run({ ends = ends, rate = through, secs = secs, report = 60,
	onFrame = function(_, dt)
		accA += lotRate * dt
		if accA >= 1 then accA -= 1; depart(lots[1], lots[2]) end
		accB += lotRate * dt
		if accB >= 1 then accB -= 1; depart(lots[2], lots[1]) end
	end })
C.report(("lot through=%.2f lot=%.2f single=%s"):format(through, lotRate, tostring(single)), res)
local legs = 0
for _ in lab.trips do legs += 1 end
print(string.format("LOT departures=%d done=%d inLotLegs=%d maxLotTrip=%.0fs pocketed=%d",
	stats.left, stats.done, legs, stats.maxTrip, #(lab.garage.folder and lab.garage.folder:GetChildren() or {})))
for i = 1, math.min(10, #pocketLog) do print(pocketLog[i]) end
local jam = W.Driver.GetJamDebug(nil, nil)
for i = 1, math.min(6, #jam) do
	local j = jam[i]
	print(string.format("JAM #%s %s still=%.0f secs=%.0f pos=(%.0f,%.0f) why=%s", tostring(j.id), j.name, j.still, j.seconds, j.pos.X, j.pos.Z, j.why))
end
for car in lab.trips do
	local d = Cit.getVehicleTripDebug(car)
	print(string.format("LEG %s id=%s dist=%.1f/%.1f gate=%s waitingGap=%s leaves=%s blockedBy=%s(%s) clearance=%.2f pos=(%.0f,%.0f)",
		car.Name, tostring(car:GetAttribute("NpcId")), d.distance, d.total, tostring(d.gateDist), tostring(d.waitingForRoadGap), tostring(d.leavesRoad),
		tostring(d.blockedBy), tostring(d.blockerName), d.clearance, d.position.X, d.position.Z))
end
