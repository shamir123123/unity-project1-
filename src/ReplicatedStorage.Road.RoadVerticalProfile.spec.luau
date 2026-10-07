--!strict
-- RoadVerticalProfile: how a road's height runs between its two ends.
return function()
	local RoadVerticalProfile = require(script.Parent)
	local BezierUtil = require(script.Parent.Parent.BezierUtil)

	describe("conditionToSurface", function()
		-- A ramp off a highway 50 studs up, ending on flat ground at 0.
		local p0, p3 = Vector3.new(0, 50, 0), Vector3.new(90, 0, 0)
		local p1, p2 = Vector3.new(30, 0, 0), Vector3.new(60, 0, 0)
		local function ground(_x: number, _z: number): number? return 0 end

		it("leaves an end welded to a road level, and still meets the ground further on", function()
			local q1, q2 = RoadVerticalProfile.conditionToSurface(p0, p1, p2, p3, ground, true, false)
			expect(q1.Y).to.be.near(50, 1e-6)
			expect(BezierUtil.point(p0, q1, q2, p3, 2 / 3).Y).to.be.near(0, 1e-6)
		end)

		it("fits a free end to the ground from its first third", function()
			local q1, q2 = RoadVerticalProfile.conditionToSurface(p0, p1, p2, p3, ground)
			expect(BezierUtil.point(p0, q1, q2, p3, 1 / 3).Y).to.be.near(0, 1e-6)
		end)
	end)
end
