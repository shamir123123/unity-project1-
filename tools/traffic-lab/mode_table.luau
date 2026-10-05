local W = require("./rt/world")
local TMC = W.req("ServerScriptService.Services.City.Simulation.TravelModeChoice")
local function share(t)
	local n, c = 0, { drive = 0, walk = 0, transit = 0 }
	for pid = 1, 2000 do
		local trip = table.clone(t); trip.pid = pid; trip.age = trip.age or 35; trip.canDrive = true; trip.congestion = 1
		local m = TMC.choose(trip)
		n += 1; c[m] += 1
	end
	return string.format("D%3d W%3d T%3d", 100*c.drive//n, 100*c.walk//n, 100*c.transit//n)
end
local bus = { timeSeconds = 0, fare = 2, walkSeconds = 80, waitSeconds = 120, rideSeconds = 200 }
print("dist  | work pw20 | work pw80 | shop pw80 | shop pw80 rain | work pw80 price6 | work pw80 bus | work pw80 bus rain")
for _, d in { 100, 200, 300, 500, 800, 1200 } do
	print(string.format("%5d | %s | %s | %s | %s | %s | %s | %s", d,
		share({ distance = d, parkWalk = 20, purpose = "work" }),
		share({ distance = d, parkWalk = 80, purpose = "work" }),
		share({ distance = d, parkWalk = 80, purpose = "shop" }),
		share({ distance = d, parkWalk = 80, purpose = "shop", weather = "Rain" }),
		share({ distance = d, parkWalk = 80, purpose = "work", parkPrice = 6 }),
		share({ distance = d, parkWalk = 80, purpose = "work", transit = bus }),
		share({ distance = d, parkWalk = 80, purpose = "work", transit = bus, weather = "Rain" })))
end
if TMC.escorts then
	print("school run share by distance (kid age 9, parent 38, parkWalk 40):")
	for _, d in { 200, 400, 800, 1500 } do
		local n, k, kr = 0, 0, 0
		for pid = 1, 2000 do
			local t = { pid = pid, age = 9, purpose = "school", distance = d, canDrive = false, parkWalk = 40, parkPrice = 0 }
			if TMC.escorts(t, 38) then k += 1 end
			t.weather = "Rain"
			if TMC.escorts(t, 38) then kr += 1 end
			n += 1
		end
		print(string.format("  dist=%4d driven=%3d%%  rain=%3d%%", d, 100*k//n, 100*kr//n))
	end
end
