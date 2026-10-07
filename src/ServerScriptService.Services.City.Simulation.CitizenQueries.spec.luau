--!strict
return function()
	local CitizenQueries = require(script.Parent)
	local function fixture(): any
		local adult: any = {pid = 1, name = "Alex", gender = "M", age = 30, stage = "atHome"}
		local h: any = {id = 1, homeId = "home", familyName = "Example", adults = {adult}, kids = {}}
		local homes: any = {[1] = h}
		local api = CitizenQueries.new({
			getHouseholds = function() return homes end,
			getBuildingService = function() return {
				getBuildingZone = function(id: string) return if id == "home" then "Residential" else nil end,
				getKerb = function() return Vector3.new(100, 0, 100) end,
			} end,
			getWalkingService = function() return {getCommuterRoot = function() return nil end} end,
			getTimeService = function() return {getDayFraction = function() return 0.5 end} end,
			findPerson = function(pid: number) return if pid == 1 and homes[1] then {h = h, person = adult} else nil end,
			homeFocusPosition = function() return Vector3.new(100, 0, 100) end,
			personLabel = function() return "Alex Example" end,
			kidLabel = function() return "Child Example" end,
			door = function() return Vector3.new(100, 0, 100) end,
			travelDecision = function() return nil end,
			presenceFrontCos = 0.17,
		})
		return {api = api, adult = adult, homes = homes}
	end

	describe("Citizen queries across restores", function()
		it("reports family members without changing household state", function()
			local f = fixture()
			local family = f.api.getFamilyInfo("home")
			expect(family.members[1].pid).to.equal(1)
			expect(f.adult.stage).to.equal("atHome")
		end)
		it("stops returning people after the owning service clears the city", function()
			local f = fixture()
			table.clear(f.homes)
			expect(f.api.getFamilyInfo("home")).to.equal(nil)
			expect(f.api.getPersonWhereabouts(1)).to.equal(nil)
		end)
		it("never follows an invisible car held in the garage", function()
			local f = fixture()
			local garage = Instance.new("Folder")
			local car = Instance.new("Model")
			local root = Instance.new("Part")
			root.Parent = car
			car.PrimaryPart = root
			car.Parent = garage
			f.adult.stage, f.adult.usingCar, f.adult.car = "transit", true, car
			local ok, err = pcall(function()
				local where = f.api.getPersonWhereabouts(1)
				expect(where.follow).to.equal(nil)
				expect(where.pos).to.equal(Vector3.new(100, 0, 100))
			end)
			garage:Destroy()
			if not ok then error(err, 0) end
		end)
	end)
end
