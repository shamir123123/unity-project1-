--!strict
return function()
	local TravelModeChoice = require(script.Parent)

	local function share(trip: any, mode: string): number
		local hits = 0
		for pid = 1, 400 do
			trip.pid = pid
			if (TravelModeChoice.choose(trip)) == mode then
				hits += 1
			end
		end
		return hits / 400
	end

	local goodBus = { timeSeconds = 0, fare = 2, walkSeconds = 80, waitSeconds = 80, rideSeconds = 260 }

	describe("mode choice", function()
		it("children and teens cannot select driving even if a car is supplied",function()
			for _,age in {8,16} do expect(share({age=age,distance=3000,canDrive=true,parkWalk=0},"drive")).to.equal(0) end
		end)
		it("teens react more strongly to the same fare increase than adults",function()
			local option=table.clone(goodBus)
			local trip={pid=20,age=16,distance=3000,canDrive=false,transit=option}
			local teen=TravelModeChoice.transitCost(trip);option.fare+=8
			local teenIncrease=TravelModeChoice.transitCost(trip)-teen
			trip.age=40;option.fare-=8
			local adult=TravelModeChoice.transitCost(trip);option.fare+=8
			expect(teenIncrease>TravelModeChoice.transitCost(trip)-adult).to.equal(true)
		end)
		it("a senior's leisure walk has less time pressure than the same work commute",function()
			local trip={pid=20,age=70,distance=150,canDrive=true,parkWalk=0,purpose="leisure"}
			local leisure=TravelModeChoice.walkCost(trip);trip.purpose="work"
			expect(leisure<TravelModeChoice.walkCost(trip)).to.equal(true)
		end)

		it("very short trips still favor walking", function()
			local s = share({ age = 40, distance = 60, canDrive = true, parkWalk = 10 }, "walk")
			expect(s > 0.6 and s < 0.95).to.equal(true)
		end)
		it("working adults usually drive a short commute with close parking",function()
			local s=share({age=40,distance=150,canDrive=true,parkWalk=10,purpose="work"},"drive")
			expect(s > .5 and s < .9).to.equal(true)
		end)
		it("farther parking reduces driving for the same short commute",function()
			local trip={age=40,distance=150,canDrive=true,parkWalk=10,purpose="work"}
			local close=share(trip,"drive");trip.parkWalk=100
			expect(share(trip,"drive") < close).to.equal(true)
		end)

		it("mostly drives a long trip when parking is easy and there is no bus", function()
			expect(share({ age = 40, distance = 3000, canDrive = true, parkWalk = 10 }, "drive") > 0.95).to.equal(true)
		end)

		it("poor parking gives a usable bus a substantial share", function()
			expect(share({ age = 40, distance = 3000, canDrive = true, parkWalk = nil, transit = goodBus }, "transit") > 0.3).to.equal(true)
		end)

		it("a good bus line wins a real share even against easy parking", function()
			local s = share({ age = 40, distance = 3000, canDrive = true, parkWalk = 10, transit = goodBus }, "transit")
			expect(s > 0.1 and s < 0.6).to.equal(true)
		end)

		it("an adult without a car never drives", function()
			expect(share({ age = 40, distance = 3000, canDrive = false, parkWalk = 10 }, "drive")).to.equal(0)
		end)

		it("seniors walk less far than younger adults", function()
			local young = share({ age = 30, distance = 450, canDrive = true, parkWalk = 10 }, "walk")
			local old = share({ age = 80, distance = 450, canDrive = true, parkWalk = 10 }, "walk")
			expect(old < young).to.equal(true)
		end)

		it("about nineteen adults in twenty own a car", function()
			local owners = 0
			for pid = 1, 2000 do
				if TravelModeChoice.ownsCar(pid) then owners += 1 end
			end
			expect(owners > 1840 and owners < 1960).to.equal(true)
		end)

		it("a person's choice for the same trip is stable (a habit)", function()
			local trip = { pid = 77, age = 40, distance = 600, canDrive = true, parkWalk = 30, transit = goodBus }
			local first = TravelModeChoice.choose(trip)
			for _ = 1, 10 do
				expect((TravelModeChoice.choose(trip))).to.equal(first)
			end
		end)

		it("rain puts more people in their cars", function()
			local trip = { age = 40, distance = 250, canDrive = true, parkWalk = 60, purpose = "leisure" }
			local dry = share(trip, "drive")
			trip.weather = "Rain"
			expect(share(trip, "drive") > dry + 0.05).to.equal(true)
		end)

		it("walking after dark is less popular than by day", function()
			local trip = { age = 40, distance = 250, canDrive = true, parkWalk = 60, purpose = "leisure" }
			local day = share(trip, "walk")
			trip.dark = true
			expect(share(trip, "walk") < day).to.equal(true)
		end)

		it("shoppers drive sooner than people out for the evening", function()
			local trip = { age = 40, distance = 220, canDrive = true, parkWalk = 60, purpose = "leisure" }
			local evening = share(trip, "drive")
			trip.purpose = "shop"
			expect(share(trip, "drive") > evening).to.equal(true)
		end)

		it("full, metered parking sends some drivers to the bus or on foot", function()
			local trip = { age = 40, distance = 1500, canDrive = true, parkWalk = 60, purpose = "work", transit = goodBus }
			local free = share(trip, "drive")
			trip.parkPrice = 6
			expect(share(trip, "drive") < free).to.equal(true)
		end)

		it("a far school is mostly driven to and a near one mostly walked", function()
			local function driven(distance: number): number
				local hits = 0
				for pid = 1, 400 do
					local trip = { pid = pid, age = 9, purpose = "school", distance = distance, canDrive = false, parkWalk = 40 }
					if TravelModeChoice.escorts(trip, 38) then hits += 1 end
				end
				return hits / 400
			end
			expect(driven(150) < 0.2).to.equal(true)
			expect(driven(1500) > 0.8).to.equal(true)
		end)
	end)
end
