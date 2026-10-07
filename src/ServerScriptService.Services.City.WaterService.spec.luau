--!strict
-- The water contract. One pooled network, rationed cheapest demand first; the PIPE is the
-- delivery and a tower with nothing plugged into it serves nobody; a home sends down the
-- drain only the water it was actually given; water is needed from the first house, a drain
-- only once sewage is unlocked; and a source without electricity delivers nothing.
return function()
	local ServiceTypes = require(game:GetService("ReplicatedStorage").City.ServiceTypes)
	local WaterService = require(script.Parent.WaterService)
	-- CitySimConstants.SEWAGE_OFF: with sewage switched off, nothing ever needs a drain and
	-- nothing backs up, unlocked or not. The sewage tests check whichever state ships.
	local SEWAGE_OFF = require(script.Parent.CitySimConstants).SEWAGE_OFF
	local WATER_OFF = require(script.Parent.CitySimConstants).WATER_OFF

	local PER_HEAD = 2.1 -- WaterService's
	local HOME_DRAIN = 0.9 -- WaterService's SEWAGE_SHARE.Residential: gardens never reach the sewer
	local TOWER = (ServiceTypes.get("WaterTower") :: any).waterOutput
	local PLANT = (ServiceTypes.get("SewagePlant") :: any).sewageCapacity

	local utilities: { any } = {}
	local buildings: { any } = {}
	local stats: any = nil

	local function reaches(b: any, pos: Vector3): boolean
		local dx, dz = pos.X - b.cf.Position.X, pos.Z - b.cf.Position.Z
		return dx * dx + dz * dz <= b.radius * b.radius
	end
	-- Stands in for WaterPipeService. Its geometry is deliberately the old tower radius:
	-- these tests are about the POOL, and a mock that reaches the same ground keeps them
	-- readable. `piped` is the one thing they vary -- a city with mains, or without.
	local piped = true
	local pipes = {
		rebuildNow = function() end,
		servedAt = function(pos: Vector3, kind: string): boolean
			if not piped then return false end
			for _, b in utilities do if b.kind == kind and reaches(b, pos) then return true end end
			return false
		end,
	}
	-- Stands in for PowerService: every source is on the grid unless a test cuts it off.
	local dark: { [number]: boolean } = {}
	local power = { isServicePowered = function(id: number): boolean return not dark[id] end }
	WaterService.Init({}, { listBuildings = function() return buildings end }, {
		list = function() return utilities end,
		hasKind = function(kind: string): boolean
			for _, b in utilities do if b.kind == kind then return true end end
			return false
		end,
	}, pipes, { setWaterStats = function(s: any) stats = s end }, power)
	local sewageUnlocked = false
	WaterService.setUnlockCheck(function(key: string): boolean
		return sewageUnlocked and key == "SewageOutlet"
	end)

	local function place(key: string, x: number): number
		local spec = ServiceTypes.get(key) :: any
		local id = #utilities + 1
		local attrs: { [string]: any } = {}
		utilities[#utilities + 1] = {
			id = id, key = key, kind = spec.kind, cf = CFrame.new(x, 0, 0), radius = 150,
			-- rebuild only counts a building still standing; a pumping station is a drain customer (its pins)
			model = { Parent = true, GetAttribute = function(_, k: string) return attrs[k] end,
				SetAttribute = function(_, k: string, v: any) attrs[k] = v end },
		}
		return id
	end
	-- Homes stand on one line in distinct 16-stud cells, so one's state never reads as another's.
	local function home(id: string, x: number, residents: number)
		buildings[#buildings + 1] = {
			bpId = id, zone = "Residential", level = 1, fill = 0, abandoned = false,
			residents = residents, position = Vector3.new(x, 0, 0),
		}
	end
	local function served(id: string, kind: string): boolean
		for _, b in buildings do
			if b.bpId == id then return WaterService.isServedAt(b.position, kind) end
		end
		error("no home " .. id)
	end
	local function reset()
		table.clear(utilities)
		table.clear(buildings)
		stats = nil
		piped = true
		table.clear(dark)
		sewageUnlocked = false
	end

	describe("WaterService", function()
		-- Service buildings are customers too (user, 2026-10-06): a hospital with no main to it
		-- is dry, and says so on its own model -- BuildingService does not own it.
		it("counts a service building as a customer: out of a main's reach, no water", function()
			reset()
			place("WaterTower", 0) -- this fake's tower reaches 150 studs
			local attrs: { [string]: any } = {}
			local model = {
				Parent = true,
				GetAttribute = function(_, k: string) return attrs[k] end,
				SetAttribute = function(_, k: string, v: any) attrs[k] = v end,
			}
			local spec = ServiceTypes.get("Hospital") :: any
			utilities[#utilities + 1] = { id = 99, key = "Hospital", kind = spec.kind,
				cf = CFrame.new(1000, 0, 0), radius = 20, model = model }
			WaterService.rebuildNow()
			expect(attrs.NoWater).to.equal(if WATER_OFF then nil else true) -- a switched-off utility serves everyone
			utilities[#utilities].cf = CFrame.new(40, 0, 0)
			WaterService.rebuildNow()
			expect(attrs.NoWater).to.equal(nil)
		end)

		it("needs water from the first house, but no drain until sewage is unlocked", function()
			reset()
			home("a", 8, 4)
			WaterService.rebuildNow()
			expect(served("a", "Water")).to.equal(false)
			expect(served("a", "Sewage")).to.equal(true)
			expect(stats.watered).to.equal(0)
			sewageUnlocked = true
			WaterService.rebuildNow()
			expect(served("a", "Sewage")).to.equal(SEWAGE_OFF)
			expect(stats.sewageNeeded).to.equal(if SEWAGE_OFF then 0 else 1)
		end)

		-- A tower runs on gravity (user 2026-10-07); a pumping station needs its electricity.
		it("pours from a tower with no power at all", function()
			reset()
			local id = place("WaterTower", 0)
			home("h", 8, 2)
			dark[id] = true
			WaterService.rebuildNow()
			expect(served("h", "Water")).to.equal(true)
		end)

		it("pumps nothing from a pumping station the grid does not reach", function()
			reset()
			local id = place("WaterPumpingStation", 0)
			home("h", 8, 2)
			dark[id] = true
			WaterService.rebuildNow()
			expect(served("h", "Water")).to.equal(false)
			expect(stats.waterCapacity).to.equal(0)
			dark[id] = nil
			WaterService.rebuildNow()
			expect(served("h", "Water")).to.equal(true)
		end)

		it("halves a pumping station drinking beside a sewage outlet", function()
			reset()
			place("WaterPumpingStation", 0)
			local rated = (ServiceTypes.get("WaterPumpingStation") :: any).waterOutput
			WaterService.rebuildNow()
			expect(stats.waterCapacity).to.equal(rated)
			place("SewageOutlet", 100)
			WaterService.rebuildNow()
			expect(stats.waterCapacity).to.equal(rated * 0.5)
		end)

		it("bills a works for the water it actually delivers, not for its size", function()
			reset()
			place("WaterTower", 0)
			home("h", 8, 10)
			WaterService.rebuildNow()
			local run = (ServiceTypes.get("WaterTower") :: any).runCost
			expect(math.abs(WaterService.getRunningMonthly() - 10 * PER_HEAD * run) < 1e-6).to.equal(true)
		end)

		it("pumps nothing from a tower the player switched off", function()
			reset()
			local id = place("WaterTower", 0)
			utilities[id].off = true -- EmergencyService.setOff's flag
			home("h", 8, 2)
			WaterService.rebuildNow()
			expect(stats.waterCapacity).to.equal(0)
			expect(WaterService.getRunningMonthly()).to.equal(0)
		end)

		it("serves nobody from a tower with no main plugged into it", function()
			reset()
			piped = false
			place("WaterTower", 0)
			home("next-door", 8, 2)
			WaterService.rebuildNow()
			expect(served("next-door", "Water")).to.equal(false)
			expect(stats.watered).to.equal(0)
		end)

		it("leaves a home outside every pipe's reach dry, however much water is spare", function()
			reset()
			place("WaterTower", 0)
			home("far", 1000, 1)
			WaterService.rebuildNow()
			expect(served("far", "Water")).to.equal(false)
		end)

		it("rations a short pool cheapest demand first", function()
			reset()
			place("WaterTower", 0)
			home("small", 24, 1)
			home("big", 56, TOWER / PER_HEAD) -- the whole tower on its own
			WaterService.rebuildNow()
			expect(served("small", "Water")).to.equal(true)
			expect(served("big", "Water")).to.equal(false)
			expect(stats.waterUse).to.equal(TOWER + PER_HEAD)
			expect(stats.watered).to.equal(0.5)
		end)

		it("pools every tower into one network, so a tower across town still helps", function()
			reset()
			place("WaterTower", 0)
			place("WaterTower", 2000)
			home("small", 24, 1)
			home("big", 56, TOWER / PER_HEAD)
			WaterService.rebuildNow()
			expect(served("big", "Water")).to.equal(true)
		end)

		it("sends down the drain only the water a home was given", function()
			reset()
			place("WaterPumpingStation", -100) -- reaches x <= 50, and outpumps the plant
			place("SewagePlant", 100) -- reaches x >= -50
			home("dry", 120, 100) -- plant only: wants water, gets none, so flushes none
			-- the station's own staff drain first (cheapest), so "full" takes exactly what is left
			local station = (ServiceTypes.get("WaterPumpingStation") :: any).waterUse
			home("full", 24, (PLANT - station) / (PER_HEAD * HOME_DRAIN)) -- exactly fills the plant
			WaterService.rebuildNow()
			expect(served("dry", "Water")).to.equal(false)
			expect(served("full", "Sewage")).to.equal(true)
			expect(math.abs(stats.sewage - PLANT) < 1e-6).to.equal(true)
		end)

		it("backs up the homes a full plant cannot take", function()
			reset()
			place("WaterPumpingStation", -100)
			place("SewagePlant", 100)
			home("first", 8, 1)
			home("full", 24, PLANT / (PER_HEAD * HOME_DRAIN))
			WaterService.rebuildNow()
			expect(served("first", "Sewage")).to.equal(true)
			expect(served("full", "Sewage")).to.equal(SEWAGE_OFF)
			if not SEWAGE_OFF then expect(stats.drained).to.equal(0.5) end
		end)
	end)
end
