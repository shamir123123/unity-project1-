--!strict
return function()
	local TrafficJamView = require(script.Parent)

	local function cellsAlong(from: Vector3, step: Vector3, n: number): { any }
		local out = {}
		for i = 0, n - 1 do
			table.insert(out, { cx = i, cz = 0, streak = 30, pos = from + step * i, shown = true })
		end
		return out
	end

	describe("jam badges", function()
		it("puts one badge on a short jam", function()
			local spots = {}
			TrafficJamView._badgeSpots(cellsAlong(Vector3.zero, Vector3.new(45, 0, 0), 3), spots)
			expect(#spots).to.equal(1)
		end)

		it("puts one badge in from each end of a long jam, not one per cell", function()
			local spots = {}
			TrafficJamView._badgeSpots(cellsAlong(Vector3.zero, Vector3.new(45, 0, 0), 20), spots)
			expect(#spots).to.equal(2)
			local lo = math.min(spots[1].X, spots[2].X)
			local hi = math.max(spots[1].X, spots[2].X)
			-- inside the jam, near its ends: not on the end cars, not in the middle
			expect(lo > 0 and lo < 100).to.equal(true)
			expect(hi < 45 * 19 and hi > 45 * 19 - 100).to.equal(true)
		end)
	end)
end
