--!strict
-- Signal poles stand on the kerb the driving side puts them on, and the mast arm
-- reaches from there out over the carriageway. Getting this backwards is the bug
-- players see as "stoplights on the wrong side of the road", and it is the one
-- thing in this module that flips with RoadRules.getLaneSideSign().
return function()
	local ReplicatedStorage    = game:GetService("ReplicatedStorage")
	local RoadNetwork          = require(ReplicatedStorage.Road.RoadNetwork)
	local RoadNavigationGraph  = require(ReplicatedStorage.Road.RoadNavigationGraph)
	local RoadRules            = require(ReplicatedStorage.Road.RoadRules)
	local IntersectionDetector = require(script.Parent)

	local function addStraight(network: any, from: Vector3, to: Vector3)
		local delta = to - from
		return network:addSegment(from, from + delta / 3, from + delta * 2 / 3, to, "CollectorRoad")
	end

	-- A signalised four-way (CollectorRoad is 4 lanes, which is what RoadRules
	-- signalises) behind the smallest roadService the detector actually reads.
	local function crossRoads(): any
		local net = RoadNetwork.new()
		local centre = Vector3.zero
		addStraight(net, centre, Vector3.new(0, 0, 100))
		addStraight(net, centre, Vector3.new(0, 0, -100))
		addStraight(net, centre, Vector3.new(-100, 0, 0))
		addStraight(net, centre, Vector3.new(100, 0, 0))
		local graph = RoadNavigationGraph.new()
		graph:Rebuild(net, {})
		return {
			getNetwork = function() return net end,
			getNavigationGraph = function() return graph end,
		}
	end

	-- Every arm of every signalised node, paired with the junction centre it belongs
	-- to, so the kerb test is a real offset from the node and not an accident of the
	-- fixture sitting on the origin.
	local function armsOn(side: string): { { arm: any, centre: Vector3 } }
		RoadRules.setDrivingSide(side)
		local rows = {}
		for _, plan in IntersectionDetector.detect(crossRoads()) do
			for _, arm in plan.arms do
				table.insert(rows, { arm = arm, centre = plan.pos })
			end
		end
		return rows
	end

	describe("signal pole placement", function()
		local restore = RoadRules.getDrivingSide()

		it("puts the pole on the driver's right kerb and the arm across the road", function()
			local rows = armsOn("right")
			expect(#rows > 0).to.equal(true)
			for _, row in rows do
				expect((row.arm.polePos - row.centre):Dot(row.arm.right) > 0).to.equal(true)
				expect(row.arm.armDir:Dot(row.arm.right) < 0).to.equal(true)
			end
			RoadRules.setDrivingSide(restore)
		end)

		it("mirrors both to the left kerb when the city drives on the left", function()
			local rows = armsOn("left")
			expect(#rows > 0).to.equal(true)
			for _, row in rows do
				expect((row.arm.polePos - row.centre):Dot(row.arm.right) < 0).to.equal(true)
				expect(row.arm.armDir:Dot(row.arm.right) > 0).to.equal(true)
			end
			RoadRules.setDrivingSide(restore)
		end)

		it("keeps the arm reaching across the road, never along it", function()
			for _, side in { "right", "left" } do
				for _, row in armsOn(side) do
					expect(math.abs(row.arm.armDir.Magnitude - 1) < 0.01).to.equal(true)
					expect(math.abs(row.arm.armDir:Dot(row.arm.dir)) < 0.01).to.equal(true)
				end
			end
			RoadRules.setDrivingSide(restore)
		end)
	end)
	describe("signal crossing-turn lane classification", function()
		local function classified(side: string, movement: string): any
			local restore = RoadRules.getDrivingSide()
			RoadRules.setDrivingSide(side)
			local edges, segments = {}, {}
			for i, direction in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis } do
				local far = direction * 100
				segments[i] = { startNode = 1, endNode = i + 1, roadType = "CollectorRoad",
					p0 = Vector3.zero, p1 = far / 3, p2 = far * 2 / 3, p3 = far }
				edges[i] = { id = "in" .. i, segmentId = i, toDir = -direction,
					out = { "out" .. i }, outMovement = { ["out" .. i] = movement } }
			end
			local network = {
				getNodes = function() return { [1] = { position = Vector3.zero, segments = { 1, 2, 3 } } } end,
				getNodeKind = function() return "intersection" end,
				getSegment = function(_self: any, id: number) return segments[id] end,
				getSegments = function() return segments end,
			}
			local graph = { HasEdges = function() return true end, _edgesByToNode = { [1] = edges } }
			local ok, plans = pcall(IntersectionDetector.detect, {
				getNavigationGraph = function() return graph end, getNetwork = function() return network end,
			})
			RoadRules.setDrivingSide(restore)
			assert(ok, plans)
			return plans[1]
		end
		it("protects right-only lanes when traffic drives on the left", function()
			local plan = classified("left", "right")
			expect(plan ~= nil).to.equal(true)
			for _, arm in plan.arms do
				expect(#arm.dedicatedLeftEdges).to.equal(1)
				expect(#arm.throughEdges).to.equal(0)
			end
		end)
		it("keeps left-side nearside turns in the through phase", function()
			for _, arm in classified("left", "left").arms do
				expect(#arm.dedicatedLeftEdges).to.equal(0)
				expect(#arm.throughEdges).to.equal(1)
			end
		end)
		it("protects left-only and U-turn lanes in right-hand traffic", function()
			for _, movement in { "left", "uturn" } do
				for _, arm in classified("right", movement).arms do
					expect(#arm.dedicatedLeftEdges).to.equal(1)
				end
			end
		end)
	end)

end
