--!strict
-- A lot's paving must END where the road's drawn edge is -- at its height, a hair under it --
-- whatever the slope and the bend, and in between LIE ON THE GROUND, melting into it at its free
-- edges: that seam and that drape are the whole feature. Two lots side by side must share their
-- edge exactly (no crack).
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LotGroundMesh = require(script.Parent)
	local RoadMeshBuilder = require(ReplicatedStorage.Road.RoadMeshBuilder)

	local LIFT = 0.3
	local SINK = 0.12
	local FLAT = function(): number return 0 end

	-- A footway's top as the renderer ships it: one strip, inner rail (kerb) then outer (back
	-- edge) at each station. `yAt(x)` is the road's height along it; the back edge is at z.
	local function footway(z: number, yAt: (number) -> number, width: number?): { any }
		local pts = {}
		for x = -60, 60, 4 do
			table.insert(pts, Vector3.new(x, yAt(x), z + (width or 6)))
			table.insert(pts, Vector3.new(x, yAt(x), z))
		end
		return { { strip = pts, thickness = 1.7, color = Color3.new(1, 1, 1) } }
	end

	-- The lot: 20 wide, front at z = 10, looking toward +Z, its level at y = 0.
	local function lot(x0: number?, x1: number?): LotGroundMesh.Params
		return { frame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1)), x0 = x0 or -10, x1 = x1 or 10,
			zFront = 10, zBack = -10, color = Color3.new(1, 1, 1) }
	end

	-- The baked bands, back to front.
	local function strips(p: LotGroundMesh.Params, specs: { any }, ground: LotGroundMesh.Ground?): { { Vector3 } }
		local b = LotGroundMesh.build(p, LotGroundMesh.edgesFromSpecs(specs), ground or FLAT)
		assert(b, "no mesh")
		local out = {}
		for _, s in RoadMeshBuilder.decodeSpecs(b:encode()) do table.insert(out, s.strip) end
		return out
	end

	local function rail(st: { Vector3 }, right: boolean): { Vector3 }
		local out = {}
		for k = if right then 2 else 1, #st, 2 do table.insert(out, st[k]) end
		return out
	end

	-- The front row: the right rail of the last band.
	local function frontRow(st: { { Vector3 } }): { Vector3 }
		return rail(st[#st], true)
	end

	describe("LotGroundMesh", function()
		it("frames the lot so +Z is the road", function()
			local p = lot()
			expect((p.frame:PointToWorldSpace(Vector3.new(0, 0, 10)) - Vector3.new(0, 0, 10)).Magnitude < 1e-4).to.equal(true)
		end)

		it("runs out to a road two studs off, tucked under its edge at its height", function()
			for _, v in frontRow(strips(lot(), footway(12, FLAT))) do
				expect(math.abs(v.Z - 12.3) < 1e-3).to.equal(true)
				expect(math.abs(v.Y + 0.03) < 1e-3).to.equal(true)
			end
		end)

		it("lies on sloping ground, a lift over it, not level with the lot", function()
			local slope = function(_x: number, z: number): number return z * 0.2 end
			local s = strips(lot(), footway(40, FLAT), slope) -- the road is out of reach
			local n = 0
			for bi, band in s do
				for k, v in band do
					local g = v.Z * 0.2
					expect(v.Y >= g - SINK - 1e-3).to.equal(true)
					if bi < #s and k > 2 and k < #band - 1 then -- inside the rim (its unmet front sinks)
						n += 1
						expect(math.abs(v.Y - (g + LIFT)) < 0.1).to.equal(true)
					end
				end
			end
			expect(n > 40).to.equal(true) -- rows along the depth, not one slab
		end)

		it("melts its free edges into the ground instead of standing a lip on it", function()
			local p = lot()
			p.soft = "blr"
			local s = strips(p, footway(12, FLAT))
			for _, v in rail(s[1], false) do
				expect(math.abs(v.Y + SINK) < 1e-3).to.equal(true) -- the back
			end
			for _, band in s do
				expect(math.abs(band[1].Y + SINK) < 1e-3).to.equal(true) -- the x0 side
				expect(math.abs(band[#band - 1].Y + SINK) < 1e-3).to.equal(true) -- the x1 side
			end
			for _, v in frontRow(s) do
				expect(math.abs(v.Y + 0.03) < 1e-3).to.equal(true) -- still ON the road's edge
			end
		end)

		it("rides a rise in the ground (two pads meeting) with no step and never under it", function()
			-- The ground climbs a stud over one 4-stud terrain cell, z = 0 .. 4.
			local rise = function(_x: number, z: number): number return math.clamp(z / 4, 0, 1) end
			local s = strips(lot(), footway(40, FLAT), rise)
			local jump = 0
			for bi, band in s do
				for k = 3, #band - 2, 2 do -- inner stations: back rail k, front rail k + 1
					local a, b = band[k], band[k + 1]
					expect(a.Y >= rise(a.X, a.Z) + 0.15 - 1e-3).to.equal(true)
					if bi < #s then jump = math.max(jump, math.abs(b.Y - a.Y) / (b.Z - a.Z)) end
				end
			end
			expect(jump <= 0.3).to.equal(true) -- no steeper than the ground itself (1 in 4) + a hair
		end)

		it("ends a flat yard at a bank reaching into it, instead of climbing it", function()
			-- Another road's embankment: the ground stands 6 studs up past x = 6.
			local bank = function(x: number, _z: number): number return if x >= 6 then 6 elseif x > 4 then (x - 4) * 3 else 0 end
			local p = lot()
			p.bank = 2.5
			for _, band in strips(p, footway(12, FLAT), bank) do
				for _, v in band do
					if v.X >= 6 then expect(v.Y <= bank(v.X, v.Z) - SINK + 1e-3).to.equal(true) end
					if v.X <= 2 and math.abs(v.Z - 12.3) > 1e-3 then expect(math.abs(v.Y - LIFT) < 0.2).to.equal(true) end
				end
			end
		end)

		it("clears a ridge in the ground BETWEEN its vertices: no grass poking through", function()
			-- A crease running along the lot at x = 1, midway between two stations.
			local ridge = function(x: number, _z: number): number return math.max(0, 0.4 - math.abs(x - 1) * 0.8) end
			local s = strips(lot(), footway(40, FLAT), ridge)
			for _, band in s do
				for k = 1, #band - 2, 2 do -- each station and the next along the back rail
					local a, b = band[k], band[k + 2]
					local mx, mz = (a.X + b.X) * 0.5, (a.Z + b.Z) * 0.5
					expect((a.Y + b.Y) * 0.5 >= ridge(mx, mz) + 0.15 - 1e-3).to.equal(true)
				end
			end
		end)

		it("keeps a sunk edge under the grass between its vertices: no sliver showing", function()
			-- A dip under the back rim at x = 1, midway between two rim vertices.
			local dip = function(x: number, _z: number): number return -math.max(0, 1 - math.abs(x - 1) * 2) end
			local p = lot()
			p.soft = "b"
			local back = rail(strips(p, footway(12, FLAT), dip)[1], false)
			for k = 1, #back - 1 do
				local a, b = back[k], back[k + 1]
				local mx, mz = (a.X + b.X) * 0.5, (a.Z + b.Z) * 0.5
				expect((a.Y + b.Y) * 0.5 <= dip(mx, mz) - SINK + 1e-3).to.equal(true)
			end
		end)

		it("comes up to a road above the lot on a smooth apron, never a step", function()
			local s = strips(lot(), footway(10, function() return 1 end))
			for _, band in s do
				for k = 1, #band, 2 do
					local a, b = band[k], band[k + 1] -- back and front of one band at one station
					expect(b.Y >= a.Y - 1e-3).to.equal(true) -- climbs toward the road
					expect((b.Y - a.Y) / (b.Z - a.Z) <= 0.25 + 1e-3).to.equal(true) -- at 1 in 4 at most
					expect(a.Y >= LIFT - 1e-3).to.equal(true) -- never under the ground
				end
			end
			for _, v in frontRow(s) do
				expect(math.abs(v.Y - 0.97) < 1e-3).to.equal(true)
			end
		end)

		it("follows a sloping street along the frontage", function()
			for _, v in frontRow(strips(lot(), footway(10, function(x) return x * 0.1 end))) do
				expect(math.abs(v.Y - (v.X * 0.1 - 0.03)) < 1e-3).to.equal(true)
			end
		end)

		it("shares its side edge exactly with the lot next door", function()
			local slope = function(x: number, z: number): number return x * 0.05 + z * 0.07 - 0.9 end
			local road = footway(12, function(x) return x * 0.05 end)
			local a = strips(lot(-10, 10), road, slope)
			local b = strips(lot(10, 30), road, slope)
			expect(#a).to.equal(#b)
			for j = 1, #a do
				local ra, lb = a[j], b[j]
				-- A's last station and B's first, back and front of each band.
				for _, pair in { { ra[#ra - 1], lb[1] }, { ra[#ra], lb[2] } } do
					expect((pair[1] - pair[2]).Magnitude < 1e-4).to.equal(true)
				end
			end
		end)

		it("keeps a yard flat over a small dip and ends it at the foot of a bank, no shards up it", function()
			-- A 1-stud dip past x = -4, an embankment climbing from x = 5 behind the join to the
			-- yard's own road ahead (z > 4 is graded to it).
			-- Past x = -8 the land falls away 5 studs (a retaining wall down to another road); the dip
			-- is in the yard, behind the join to its own road.
			local ground = function(x: number, z: number): number
				return if x < -8 then -5 elseif x < -4 and z < 0 then -1 elseif x > 5 and z < 4 then (x - 5) * 1.5 else 0
			end
			local p = lot()
			p.bank, p.drop, p.floorY = 0.6, 1.5, -0.02
			for _, band in strips(p, footway(12, FLAT), ground) do
				for _, v in band do
					if math.abs(v.Z - 12.3) < 1e-3 then continue end -- the road's edge row
					local g = ground(v.X, v.Z)
					if g > 0.6 or g < -1.5 then
						expect(v.Y <= g - SINK + 1e-3).to.equal(true) -- up the bank / down the cliff: under the grass
					else
						expect(v.Y <= 1).to.equal(true) -- no higher than the bank's foot: never a shard up it
						if g < -0.5 then expect(v.Y >= -0.02 - 1e-3).to.equal(true) end -- over the dip: level
					end
				end
			end
		end)

		it("lies on the slope down to its road below, never held level over it", function()
			-- The yard at 0, its footway 4 studs down; the pad grades the last 10 studs down to it.
			local ground = function(_x: number, z: number): number return if z < 2 then 0 else -(z - 2) * 0.45 end
			local p = lot()
			p.bank, p.drop, p.floorY = 0.6, 1.5, -0.02
			for _, band in strips(p, footway(12, function() return -4 end), ground) do
				for _, v in band do
					if v.Z > 3 and math.abs(v.Z - 12.3) > 1e-3 then
						expect(math.abs(v.Y - (ground(v.X, v.Z) + LIFT)) < 0.35).to.equal(true)
					end
				end
			end
		end)

		it("never floats over a steep brink down to its road", function()
			-- The yard at 0 breaks over a steep slope 5 studs down to its road.
			local ground = function(_x: number, z: number): number
				return if z < 2 then 0 elseif z < 6 then -(z - 2) * 1.25 else -5
			end
			local p = lot()
			p.bank, p.drop, p.floorY = 0.6, 1.5, -0.02
			for _, band in strips(p, footway(12, function() return -5 end), ground) do
				for _, v in band do
					if math.abs(v.Z - 12.3) > 1e-3 then
						expect(v.Y - ground(v.X, v.Z) <= LIFT + 0.15 + 0.3 + 1e-3).to.equal(true) -- drape + smoothing + crease, at most
					end
				end
			end
		end)

		it("bridges a dip between two lots at its floor, not down into it", function()
			local p = lot()
			p.floorY = 0.25
			local dip = function(x: number, _z: number): number return -math.max(0, 4 - math.abs(x)) end
			for _, band in strips(p, footway(12, FLAT), dip) do
				for _, v in band do
					if math.abs(v.Z - 12.3) > 1e-3 then expect(v.Y >= 0.25 - 1e-3).to.equal(true) end
				end
			end
		end)

		it("stops under a road on a wall instead of climbing up to it", function()
			-- A road 4.5 studs up on a retaining wall, its edge 2 studs off the lot; flat ground.
			local s = strips(lot(), footway(12, function() return 4.5 end))
			for _, band in s do
				for _, v in band do expect(v.Y <= LIFT + 0.3).to.equal(true) end
			end
			for _, v in frontRow(s) do
				expect(math.abs(v.Y + SINK) < 1e-3).to.equal(true) -- a free edge under it, not pinned up
				expect(v.Z <= 12.3 + 1e-3).to.equal(true) -- and no further than the wall
			end
		end)

		it("ignores a deck passing over the lot and meets the footway", function()
			local specs = footway(12, FLAT)
			for _, sp in footway(4, function() return 7.5 end) do table.insert(specs, sp) end
			for _, v in frontRow(strips(lot(), specs)) do
				expect(math.abs(v.Z - 12.3) < 1e-3).to.equal(true)
			end
		end)

		it("stops where a footway cuts into the lot on the inside of a bend", function()
			for _, v in frontRow(strips(lot(), footway(7, FLAT))) do
				expect(math.abs(v.Z - 7.3) < 1e-3).to.equal(true)
			end
		end)

		it("turns its sides to the road's normal round a bend", function()
			-- A footway curving round a centre across the road: the lot is on the OUTSIDE of the
			-- bend, its front on the footway's back edge, so its sides fan out along the radii.
			local pts = {}
			local c = Vector3.new(0, 0, 64)
			for a = -40, 40, 5 do
				local r = math.rad(a)
				local dir = Vector3.new(math.sin(r), 0, -math.cos(r))
				table.insert(pts, c + dir * 48) -- kerb
				table.insert(pts, c + dir * 54) -- back edge
			end
			local p = lot()
			p.trap = true
			local back = rail(strips(p, { { strip = pts, thickness = 1.7, color = Color3.new(1, 1, 1) } })[1], false)
			expect(back[#back].X - back[1].X > 20 + 1).to.equal(true)
		end)

		it("stops short of a road crossing the lot further in", function()
			local p = lot()
			p.zBack = -40
			local specs = footway(12, FLAT)
			for _, sp in footway(-31, FLAT) do table.insert(specs, sp) end
			for _, v in rail(strips(p, specs)[1], false) do
				expect(math.abs(v.Z + 24.7) < 1e-3).to.equal(true)
			end
		end)

		it("fills out of a lot's side to an alley along it, and only there", function()
			-- An alley's asphalt running along the lot's right flank (x = 14 .. 20).
			local pts = {}
			for z = -60, 60, 4 do
				table.insert(pts, Vector3.new(14, 0, z))
				table.insert(pts, Vector3.new(20, 0, z))
			end
			local alley = { { strip = pts, thickness = 1, color = Color3.new(0.3, 0.3, 0.3) } }
			local side: LotGroundMesh.Params = {
				frame = lot().frame * CFrame.Angles(0, math.pi * 0.5, 0), x0 = -10, x1 = 10,
				zFront = 10, zBack = 8, reach = 8, square = true, color = Color3.new(1, 1, 1),
			}
			for _, v in frontRow(strips(side, alley)) do
				expect(math.abs(v.X - 14.3) < 1e-3).to.equal(true)
			end
			local far = {}
			for z = -60, 60, 4 do
				table.insert(far, Vector3.new(30, 0, z))
				table.insert(far, Vector3.new(36, 0, z))
			end
			expect(LotGroundMesh.build(side, LotGroundMesh.edgesFromSpecs({ { strip = far, thickness = 1, color = Color3.new(0.3, 0.3, 0.3) } }), FLAT)).to.equal(nil)
		end)

		it("skips kerb faces and keeps both rails of a surface", function()
			local specs = footway(12, FLAT)
			table.insert(specs, { strip = specs[1].strip, thickness = 0.05, color = Color3.new(1, 1, 1) })
			local n = #specs[1].strip // 2
			expect(#LotGroundMesh.edgesFromSpecs(specs)).to.equal((n - 1) * 2)
		end)

		it("holds a flat lot level up to its front line; only its last row meets a lower road", function()
			-- A slab yard padded 0.35 under its paving; the pad's road join falls to the road in its last 2 studs.
			local pad = function(_x: number, z: number): number return if z < 8 then -0.35 else -0.35 - (z - 8) * 0.5 end
			local road = footway(10, function(): number return -1 end)
			local function interior(flat: boolean): (number, number)
				local p = lot()
				p.floorY, p.flat = 0.06, flat
				local s = strips(p, road, pad)
				local lo, hi = math.huge, -math.huge
				for bi, band in s do
					for k, v in band do
						if not (bi == #s and k % 2 == 0) then lo, hi = math.min(lo, v.Y), math.max(hi, v.Y) end
					end
				end
				return lo, hi
			end
			local lo, hi = interior(true)
			expect(math.abs(lo - 0.06) < 1e-3).to.equal(true)
			expect(math.abs(hi - 0.06) < 1e-3).to.equal(true)
			for _, v in frontRow(strips(lot(), road, pad)) do
				expect(math.abs(v.Y + 1.03) < 1e-3).to.equal(true) -- still ON the road's edge
			end
			expect((interior(false)) < 0.01).to.equal(true) -- without `flat` the join tilts the lot's front
		end)
	end)
end
