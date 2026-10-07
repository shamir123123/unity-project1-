--!strict
return function()
	local Coordinator = require(script.Parent)
	local SignalSpec = require(game:GetService("ReplicatedStorage").Road.SignalSpec)
	local Config = require(script.Parent.Parent.TrafficConfig)
	describe("signal cycle timing", function()
		it("retains every minimum and clearance when a road edit outgrows its cycle", function()
			local phases = { { kind = "through" }, { kind = "left" }, { kind = "through" }, { kind = "left" }, { kind = "ped" } }
			local plan = SignalSpec.defaultPlan()
			local split = Coordinator.buildSplitPlan(phases, plan, 30)
			local total = 0
			for i, slot in split.slots do
				local minimum = if phases[i].kind == "ped" then Config.PED_WALK_TIME else Coordinator.minGreenFor(phases[i], plan)
				expect(slot.green + 1e-6 >= minimum).to.equal(true)
				expect(slot.allRed).to.equal(Config.ALL_RED_TIME)
				expect(slot.yellow).to.equal(if phases[i].kind == "ped" then 0 else Config.YELLOW_TIME)
				total += slot.green + slot.yellow + slot.allRed
			end
			expect(math.abs(total - split.cycle) < 1e-6).to.equal(true)
		end)
		it("preserves a feasible requested cycle exactly", function()
			local split = Coordinator.buildSplitPlan({ { kind = "through" }, { kind = "through" } }, SignalSpec.defaultPlan(), 90)
			local total = 0
			for _, slot in split.slots do total += slot.green + slot.yellow + slot.allRed end
			expect(math.abs(total - 90) < 1e-6).to.equal(true)
			expect(split.cycle).to.equal(90)
		end)
		it("samples yellow and clearance before the next green, including wrap", function()
			local split = Coordinator.buildSplitPlan({ { kind = "through" }, { kind = "through" } }, SignalSpec.defaultPlan(), 60)
			local first = split.slots[1]
			local phase, state = Coordinator.sampleAt(split, first.green)
			expect(phase).to.equal(1); expect(state).to.equal("yellow")
			phase, state = Coordinator.sampleAt(split, first.green + first.yellow)
			expect(phase).to.equal(1); expect(state).to.equal("allred")
			phase, state = Coordinator.sampleAt(split, split.slots[2].start)
			expect(phase).to.equal(2); expect(state).to.equal("green")
			phase, state = Coordinator.sampleAt(split, 60)
			expect(phase).to.equal(1); expect(state).to.equal("green")
		end)
	end)
end

