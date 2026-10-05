--!strict
-- A road's cross-section decides where every car drives. The one promise that matters: every
-- road already in the catalog keeps its lanes exactly where they were -- same offsets, same
-- ids, same ordinals -- so the traffic AI cannot tell profiles were ever introduced. The only
-- lanes allowed to move are the ones that were WRONG: a one-sided parking apron or verge,
-- whose carriageway the renderer has always drawn off-centre while the cars drove centred.
return function()
	local RoadProfile = require(script.Parent.RoadProfile)
	local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
	local RoadConstants = require(script.Parent.RoadConstants)

	-- The plan RoadNavigationGraph built before profiles, kept verbatim as the reference.
	local function legacyLanes(spec: any, laneSide: number): { any }
		local plans = {}
		local laneCount = math.max(1, spec.laneCount or 2)
		local width = RoadTypeCatalog.carriagewayWidth(spec)
		if spec.oneWay then
			local laneW = width / laneCount
			for i = 1, laneCount do
				table.insert(plans, { offset = -width * 0.5 + (i - 0.5) * laneW, forward = true, laneIndex = i,
					laneOrdinal = if laneSide > 0 then i else laneCount - i + 1, laneCountInDirection = laneCount })
			end
			return plans
		end
		local perDir = math.max(1, math.floor(laneCount / 2))
		local medianW = if spec.median then (spec.medianWidth or 4) else 0
		local laneW = (width - medianW) / laneCount
		for i = 1, perDir do
			table.insert(plans, { offset = laneSide * (medianW * 0.5 + (i - 0.5) * laneW), forward = true,
				laneIndex = i, laneOrdinal = i, laneCountInDirection = perDir })
		end
		for i = 1, perDir do
			table.insert(plans, { offset = -laneSide * (medianW * 0.5 + (i - 0.5) * laneW), forward = false,
				laneIndex = perDir + i, laneOrdinal = i, laneCountInDirection = perDir })
		end
		return plans
	end

	local function byIndex(list: { any }): { [number]: any }
		local out = {}
		for _, l in list do out[l.laneIndex] = l end
		return out
	end

	local CONFIGS = { "", "|pk=b", "|md=c", "|md=b", "|sw=n", "|sw=l", "|pk=b;md=b" }
	local function eachRoad(fn: (string, any) -> ())
		local n = 0
		for id, base in RoadTypeCatalog.Types do
			if base.isRail then continue end
			for _, cfg in CONFIGS do
				local spec = RoadTypeCatalog.get(id .. cfg)
				if spec then
					n += 1
					fn(id .. cfg, spec)
				end
			end
		end
		assert(n > 100, "too few roads checked to mean anything: " .. n)
	end

	describe("highways", function()
		it("give every lane the same width, centred between equal paved shoulders", function()
			for id, spec in RoadTypeCatalog.Types do
				if not spec.isHighway then continue end
				local lanes = RoadProfile.lanes(spec.profile, 1)
				expect(#lanes).to.equal(math.max(1, spec.laneCount or 2))
				for _, l in lanes do
					assert(math.abs(l.width - 7) < 1e-6, id .. ": lane " .. l.laneIndex .. " is " .. l.width .. " wide")
				end
				local strips = spec.profile.strips
				expect(strips[1].k).to.equal("shoulder")
				expect(strips[#strips].k).to.equal("shoulder")
				assert(math.abs(strips[1].w - strips[#strips].w) < 1e-6, id .. ": uneven shoulders")
				local roadW = RoadProfile.widths(spec.profile)
				assert(math.abs(roadW - spec.width) < 1e-6, id .. ": profile is " .. roadW .. " wide, spec " .. spec.width)
			end
		end)
	end)

	describe("catalog roads", function()
		it("keeps every lane exactly where the old plan put it", function()
			eachRoad(function(id, spec)
				-- highways deliberately moved: fixed-width lanes inside paved shoulders (below); an
				-- uneven (2+1) road or angled parking is beyond what the old plan could lay out
				if spec.isHighway or spec.lanesBack or spec.parkingAngle or spec.pedestrian then return end
				for _, side in { 1, -1 } do
					local old = legacyLanes(spec, side)
					local new = byIndex(RoadProfile.lanes(spec.profile, side))
					expect(#RoadProfile.lanes(spec.profile, side)).to.equal(#old)
					for _, o in old do
						local n = new[o.laneIndex]
						assert(n, id .. ": lane " .. o.laneIndex .. " missing")
						assert(math.abs(n.offset - o.offset) < 1e-6,
							string.format("%s side %d lane %d: offset %.4f, was %.4f", id, side, o.laneIndex, n.offset, o.offset))
						expect(n.forward).to.equal(o.forward)
						expect(n.laneOrdinal).to.equal(o.laneOrdinal)
						expect(n.laneCountInDirection).to.equal(o.laneCountInDirection)
					end
				end
			end)
		end)

		it("moves a one-sided apron's lanes onto the carriageway the renderer draws", function()
			-- (a verge only carves the carriageway on a side with no footway to stand in)
			for _, cfg in { "|pk=r", "|pk=l", "|sw=r;md=l" } do
				local spec = RoadTypeCatalog.get("NarrowRoad" .. cfg) :: any
				local leftBand = if cfg == "|pk=l" then spec.parkingLaneWidth elseif cfg == "|sw=r;md=l" then spec.vergeWidth else 0
				local rightBand = if cfg == "|pk=r" then spec.parkingLaneWidth else 0
				local shift = (leftBand - rightBand) * 0.5
				assert(math.abs(shift) > 0.5, cfg .. ": no apron to test against")
				local old = legacyLanes(spec, 1)
				local new = byIndex(RoadProfile.lanes(spec.profile, 1))
				for _, o in old do
					assert(math.abs(new[o.laneIndex].offset - (o.offset + shift)) < 1e-6, cfg .. " lane " .. o.laneIndex)
				end
			end
		end)

		it("plants a verge in the footway: the road keeps its width and its lanes", function()
			local plain = RoadTypeCatalog.get("NarrowRoad") :: any
			local r0, wl0, wr0 = RoadProfile.widths(plain.profile)
			local lanes0 = RoadProfile.lanes(plain.profile, 1)
			for _, cfg in { "|md=l", "|md=b" } do
				local spec = RoadTypeCatalog.get("NarrowRoad" .. cfg) :: any
				expect(spec.width).to.equal(plain.width)
				local r1, wl1, wr1 = RoadProfile.widths(spec.profile)
				expect(r1).to.equal(r0)
				expect(wl1).to.equal(wl0)
				expect(wr1).to.equal(wr0)
				expect(#RoadProfile.offsets(spec.profile, "verge")).to.equal(0) -- in the roadsides, not the road
				for i, l in RoadProfile.lanes(spec.profile, 1) do
					expect(l.offset).to.equal(lanes0[i].offset)
				end
			end
		end)

		it("puts one-sided parking bays on the side that has the parking", function()
			local right = RoadProfile.offsets((RoadTypeCatalog.get("NarrowRoad|pk=r") :: any).profile, "park")
			local left = RoadProfile.offsets((RoadTypeCatalog.get("NarrowRoad|pk=l") :: any).profile, "park")
			expect(#right).to.equal(1)
			expect(#left).to.equal(1)
			expect(right[1] > 0).to.equal(true)
			expect(left[1] < 0).to.equal(true)
		end)

		-- Roads placed since 2026-10-04 carry rs=w: one roadside (footway + parking lane) on every
		-- paved kerb with the parking cut out of it, so parking never changes the footprint and a
		-- parked kerb keeps today's footway. Ids without the key -- every road already down -- keep
		-- SIDEWALK_WIDTH.
		it("cuts parking out of a wide roadside; older ids keep their footway", function()
			local SW = RoadConstants.SIDEWALK_WIDTH
			local function sides(id: string): (number, number, number)
				local road, l, r = RoadProfile.widths((RoadTypeCatalog.get(id) :: any).profile)
				return road + l + r, l, r
			end
			local park = (RoadTypeCatalog.get("NarrowRoad|pk=b;rs=w") :: any).parkingLaneWidth
			local bare, bareL, bareR = sides("NarrowRoad|rs=w")
			local parked, parkedL, parkedR = sides("NarrowRoad|pk=b;rs=w")
			local oneSide, oneL, oneR = sides("NarrowRoad|pk=r;rs=w")
			expect(bareL).to.be.near(SW + park, 1e-6)
			expect(bareR).to.be.near(SW + park, 1e-6)
			expect(parkedL).to.be.near(SW, 1e-6)
			expect(parkedR).to.be.near(SW, 1e-6)
			expect(oneL).to.be.near(SW + park, 1e-6)
			expect(oneR).to.be.near(SW, 1e-6)
			expect(parked).to.be.near(bare, 1e-6)
			expect(oneSide).to.be.near(bare, 1e-6)
			for _, id in { "NarrowRoad", "NarrowRoad|pk=b" } do
				local _, l, r = sides(id)
				expect(l).to.equal(SW)
				expect(r).to.equal(SW)
			end
			expect(RoadTypeCatalog.encodeConfig("NarrowRoad", { parking = "both", roadside = true })).to.equal("NarrowRoad|pk=b;rs=w")
			expect(RoadTypeCatalog.encodeConfig("NarrowRoad", { sidewalk = "none", roadside = true })).to.equal("NarrowRoad|sw=n")
			expect(RoadTypeCatalog.encodeConfig("Highway2W", { roadside = true })).to.equal("Highway2W")
		end)

		-- Catalog roads only: a config can build lanes no player road may have (an alley with a
		-- centre median leaves 1.25 m lanes), and decode is right to refuse those.
		it("round-trips its own encoding", function()
			for id, spec in RoadTypeCatalog.Types do
				-- a pedestrian street is paving, not a player-buildable cross-section
				if spec.isRail or spec.pedestrian then continue end
				local body = RoadProfile.encode(spec.profile)
				local back = RoadProfile.decode(body)
				assert(back, id .. " did not decode: " .. body)
				local a, b = RoadProfile.lanes(spec.profile, 1), RoadProfile.lanes(back :: any, 1)
				expect(#b).to.equal(#a)
				for i, l in a do
					-- widths are stored to a quarter stud, so a 22/3-stud lane lands a hair off
					assert(math.abs(b[i].offset - l.offset) < 0.5, id .. " lane " .. i)
				end
			end
		end)
	end)

	describe("player-built roads", function()
		it("refuses what it cannot vouch for", function()
			local bad = {
				"", "x12+", "l99+", "l36-", "l36+,l36-", "l36-,m8g,m8g,l36+", "w24,l36+,w24,w24",
				"l36+,p20,l36+", "l36+;Z", "l36*", "w24,w24,l36+", string.rep("l36+,", 30) .. "l36+",
				"l36-,p20,l36+", "m8g,l36+",
			}
			for _, body in bad do
				assert(RoadProfile.decode(body) == nil, "accepted: " .. body)
			end
		end)

		it("numbers an uneven two-way from the centre outward", function()
			local p = RoadProfile.decode("w24,l28-,l28+,l28+,w24") :: any
			assert(p, "valid profile refused")
			local lanes = RoadProfile.lanes(p, 1)
			expect(#lanes).to.equal(3)
			local fwd = 0
			for _, l in lanes do
				if l.forward then
					fwd += 1
					expect(l.laneCountInDirection).to.equal(2)
					-- the inner forward lane is ordinal 1 and sits nearer the centre line
					if l.laneOrdinal == 1 then expect(l.offset < 3).to.equal(true) end
				end
			end
			expect(fwd).to.equal(2)
		end)

		it("resolves a P: id to a road every old system can read", function()
			local spec = RoadTypeCatalog.get("P:w24,p20,l36-,l36+,p20,w24") :: any
			assert(spec, "P: id did not resolve")
			expect(spec.width).to.equal(28)
			expect(spec.laneCount).to.equal(2)
			expect(spec.oneWay).to.equal(nil)
			expect(spec.parkingSide).to.equal("both")
			expect(spec.sidewalkMode).to.equal("both")
			expect(RoadTypeCatalog.get("P:l36-")).to.equal(nil)
		end)
	end)
end
