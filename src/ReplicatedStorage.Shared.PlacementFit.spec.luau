--!strict
-- A building may not stand in the road. Roads carry NO queryable geometry, so the box query
-- cannot answer this -- onRoad does, off the segment list each side hands over. Pinned here
-- because the veto is invisible: nothing breaks loudly when it silently stops working.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local PlacementFit    = require(script.Parent.PlacementFit)
	local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)

	local WIDTH = RoadTypeCatalog.getOrDefault("NarrowRoad").width
	local FOOT  = Vector3.new(8, 20, 8)

	-- One straight road along +X through the origin.
	local function road(): any
		local a, b = Vector3.new(-100, 0, 0), Vector3.new(100, 0, 0)
		return { id = 1, roadType = "NarrowRoad",
			p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
	end

	local function at(z: number): CFrame
		return CFrame.new(0, 0, z)
	end

	describe("onRoad", function()
		it("passes everything when no road is known", function()
			PlacementFit.setRoadSegments({})
			expect(PlacementFit.onRoad(at(0), FOOT)).to.equal(false)
		end)

		it("refuses a footprint sitting on the carriageway", function()
			PlacementFit.setRoadSegments({ road() })
			expect(PlacementFit.onRoad(at(0), FOOT)).to.equal(true)
		end)

		it("refuses one that only clips the asphalt with its near edge", function()
			PlacementFit.setRoadSegments({ road() })
			expect(PlacementFit.onRoad(at(WIDTH * 0.5 + FOOT.Z * 0.5 - 2), FOOT)).to.equal(true)
		end)

		it("allows one set back clear of the kerb", function()
			PlacementFit.setRoadSegments({ road() })
			expect(PlacementFit.onRoad(at(WIDTH * 0.5 + FOOT.Z * 0.5 + 8), FOOT)).to.equal(false)
		end)

		it("forgets the road when the network empties", function()
			PlacementFit.setRoadSegments({ road() })
			PlacementFit.setRoadSegments({})
			expect(PlacementFit.onRoad(at(0), FOOT)).to.equal(false)
		end)
	end)

	-- The other direction: a road laid over a standing house takes it. The road ghost
	-- highlights that house in white off this exact function before the click, so if the
	-- two reaches ever drift the tool promises one demolition and performs another.
	describe("seatUnderPavement", function()
		-- Numbers chosen so the two reaches are distinguishable: the SEAT is half a lot
		-- deep, so a house can have its centre clear of the corridor and a wall inside it.
		local CLEAR = 40   -- to the seat CENTRE: carriageway + sidewalks + margin
		local RECT  = 8    -- to the footprint RECTANGLE: bare carriageway
		local HALF  = 40   -- the seat's own half-width / half-depth

		-- A straight road along +X through the origin, sampled the way RoadService does.
		local PTS = { Vector3.new(-100, 0, 0), Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) }

		local function seat(z: number): CFrame
			return CFrame.new(0, 0, z)
		end

		it("takes a house sitting under the new pavement", function()
			expect(PlacementFit.seatUnderPavement(seat(0), HALF, HALF, PTS, CLEAR, RECT)).to.equal(true)
		end)

		it("leaves the neighbour a lot back from the kerb", function()
			local z = CLEAR + HALF + RECT + 5
			expect(PlacementFit.seatUnderPavement(seat(z), HALF, HALF, PTS, CLEAR, RECT)).to.equal(false)
		end)

		it("takes a house whose CENTRE is clear but whose wall is in the asphalt", function()
			local z = CLEAR + 5 -- centre outside CLEAR, rectangle only 5 studs out
			expect(PlacementFit.seatUnderPavement(seat(z), HALF, HALF, PTS, CLEAR, RECT)).to.equal(true)
		end)

		it("without a rect reach, judges the centre alone", function()
			local z = CLEAR + 5
			expect(PlacementFit.seatUnderPavement(seat(z), HALF, HALF, PTS, CLEAR)).to.equal(false)
		end)
	end)

	-- A car park is road infrastructure: a zone seat over it is TAKEN, the way a road
	-- would be, and the zone never clears it. Its slab here only half-covers the seat, the
	-- case the old clear-by-centre test missed (catalogue radius 3, lot 40 wide).
	describe("car parks block zoning", function()
		local Workspace = game:GetService("Workspace")
		local FAR = Vector3.new(40000, 0, 40000) -- clear of anything really built

		local function seatCorners(dx: number?): { Vector3 }
			local c = FAR + Vector3.new(dx or 0, 0, 0)
			return { c + Vector3.new(-16, 0, -16), c + Vector3.new(16, 0, -16),
				c + Vector3.new(16, 0, 16), c + Vector3.new(-16, 0, 16) }
		end

		local function withProp(key: string, fn: () -> ())
			local city = Workspace:FindFirstChild("_City")
			local madeCity = city == nil
			if not city then
				city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace
			end
			local nature = (city :: Instance):FindFirstChild("Nature")
			local madeNature = nature == nil
			if not nature then
				nature = Instance.new("Folder"); nature.Name = "Nature"; nature.Parent = city
			end
			local m = Instance.new("Model")
			m:SetAttribute("NatureKey", key)
			local slab = Instance.new("Part")
			slab.Anchored = true
			slab.Size = Vector3.new(40, 0.6, 40)
			slab.CFrame = CFrame.new(FAR + Vector3.new(30, 0.3, 0)) -- centre OFF the seat
			slab.Parent = m
			m.PrimaryPart = slab
			m.Parent = nature
			local ok, err = pcall(fn)
			m:Destroy()
			if madeNature then (nature :: Instance):Destroy() end
			if madeCity then (city :: Instance):Destroy() end
			if not ok then error(err, 0) end
		end

		it("refuses a seat that half-covers a car park", function()
			withProp("ParkingLotMedium", function()
				expect(PlacementFit.seatOccupied(seatCorners())).to.equal(true)
			end)
		end)

		it("never lists a car park for clearing", function()
			withProp("ParkingLotMedium", function()
				-- Parcel right over the lot's centre: the old rule took exactly this one.
				expect(#PlacementFit.propsInRects({ seatCorners(30) })).to.equal(0)
			end)
		end)

		it("still lets a zone take a tree", function()
			withProp("RoyalPalm", function()
				expect(PlacementFit.seatOccupied(seatCorners())).to.equal(false)
			end)
		end)
	end)
end
