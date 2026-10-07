--!strict
-- The business contract: a business that keeps losing money cuts back a level, and at level 1 closes;
-- one whose takings cover its wages is left alone. Fakes stand in for BuildingService and SupplyService.
return function()
	local BusinessService = require(script.Parent)
	local Const = require(game:GetService("ServerScriptService").Services.City.CitySimConstants)
	local MONTH = Const.MONTH_TICKS

	local function fakeModel(): any
		local attrs: { [string]: any } = {}
		return {
			GetAttribute = function(_, k: string) return attrs[k] end,
			SetAttribute = function(_, k: string, v: any) attrs[k] = v end,
		}
	end

	local function run(level0: number, takingsPerStep: number): (number, number, any)
		local level, downs, gone = level0, 0, 0
		local model = fakeModel()
		local buildings = {
			getCommercialIndustrialFill = function()
				if gone > 0 then return {} end
				return { { bpId = "shop", zone = "Commercial", level = level, fill = 1 } }
			end,
			getModel = function() return model end,
			getBuildingZone = function() return "Commercial" end,
			downgradeGroup = function()
				if level <= 1 then return false end
				level -= 1; downs += 1; return true
			end,
			demolish = function() gone += 1; return true end,
		}
		local supply = { drainBusinessFlows = function() return { shop = takingsPerStep } end }
		BusinessService.Init(nil, buildings, supply)
		for _ = 1, math.floor(MONTH * 5 / 10) do BusinessService._step(10) end
		return downs, gone, model
	end

	describe("BusinessService", function()
		it("cuts back a shop that sells nothing, then closes it at level 1", function()
			local downs, gone = run(2, 0)
			expect(downs).to.equal(1)
			expect(gone).to.equal(1)
		end)

		it("leaves a shop alone whose takings cover its wages", function()
			-- level 2: 9 staff; its month's wages over 10-second passes, with room to spare
			local wagesPerStep = Const.JOB_CAP.Commercial[2] * Const.BUSINESS.WAGE.Commercial * 10 / MONTH
			local downs, gone, model = run(2, wagesPerStep * 3)
			expect(downs).to.equal(0)
			expect(gone).to.equal(0)
			expect(model:GetAttribute("Losing")).to.equal(nil)
			expect((model:GetAttribute("Profit") or 0) > 0).to.equal(true)
		end)
	end)
end
