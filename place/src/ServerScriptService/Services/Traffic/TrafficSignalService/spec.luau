--!strict
-- TestEZ contracts run in Edit through the fresh-source harness.
return function()
	local newFixture = require(script.Parent:FindFirstChild("TestFixture"))

	describe("traffic signal right of way", function()
		it("serves through and protected lanes without a queue provider", function()
			local f = newFixture()
			local seen = {}
			for _ = 1, 1600 do
				for _, id in { "north", "south", "left", "east" } do
					if f.service.CanGo(id, id .. "Out") then seen[id] = true end
				end
				f.step(0.1)
			end
			for _, id in { "north", "south", "left", "east" } do expect(seen[id]).to.equal(true) end
		end)

		it("uses protected-turn timing when queue data is unavailable", function()
			local f = newFixture()
			f.untilState("Left", "green")
			local row = f.service.GetDebugSnapshot()[1]
			expect(row.timer >= 4 and row.timer <= 9).to.equal(true)
		end)

		it("rejects illegal exits even during green", function()
			local f = newFixture()
			f.untilState("NS", "green")
			expect(f.service.CanGo("north", "eastOut")).to.equal(false)
			expect(f.service.CanGo("north", "northOut")).to.equal(true)
		end)

		it("never greens crossing roads together over repeated cycles", function()
			local f = newFixture()
			for _ = 1, 3000 do
				expect(f.service.CanGo("north") and f.service.CanGo("east")).to.equal(false)
				expect(f.service.CanGo("left") and f.service.CanGo("north")).to.equal(false)
				f.step(0.1)
			end
		end)

		it("keeps a red approach red during another approach's yellow", function()
			local f = newFixture()
			f.untilState("NS", "yellow")
			expect(f.service.IsApproachYellow("north")).to.equal(true)
			expect(f.service.IsApproachYellow("east")).to.equal(false)
			expect(f.service.CanGo("north")).to.equal(false)
			expect(f.service.CanGo("east")).to.equal(false)
		end)

		it("holds every approach at red during a pedestrian scramble", function()
			local f = newFixture()
			f.untilState("Ped", "green")
			expect(f.service.IsPedWalk(1)).to.equal(true)
			for _, id in { "north", "south", "left", "east" } do expect(f.service.CanGo(id)).to.equal(false) end
		end)

		it("preserves the running cycle when an unrelated road changes", function()
			local f = newFixture()
			f.untilState("NS", "green")
			f.step(0.5)
			local before = f.service.GetDebugSnapshot()[1]
			f.rebuild(false)
			local after = f.service.GetDebugSnapshot()[1]
			expect(after.currentPhase).to.equal(before.currentPhase)
			expect(after.state).to.equal(before.state)
			expect(after.timer).to.equal(before.timer)
		end)

		it("clears the junction before changed phase order releases another road", function()
			local f = newFixture()
			f.untilState("NS", "green")
			f.rebuild(true)
			expect(f.service.CanGo("east")).to.equal(false)
			for _ = 1, 40 do
				f.step(0.1)
				expect(f.service.CanGo("east")).to.equal(false)
			end
			f.untilState("EW", "green")
			expect(f.service.CanGo("east")).to.equal(true)
		end)

		it("keeps every corridor member on the largest required safe cycle", function()
			local f = newFixture(true)
			local first = f.service.GetNodeEditorSnapshot(1)
			local second = f.service.GetNodeEditorSnapshot(2)
			expect(first.cycle).to.equal(second.cycle)
			expect(first.cycle >= 56).to.equal(true)
		end)

		it("reinitializes without duplicate heartbeat or topology listeners", function()
			local f = newFixture()
			f.service.Init(f.road)
			f.service.Bind()
			f.service.Start()
			expect(f.listenerCount()).to.equal(1)
		end)
	end)
	describe("actual road graph signal integration", function()
		local roadModules = game:GetService("ReplicatedStorage").Road
		local Network = require(roadModules.RoadNetwork)
		local Graph = require(roadModules.RoadNavigationGraph)
		local Rules = require(roadModules.RoadRules)
		local Detector = require(script.Parent.Parent.IntersectionDetector)
		local Builder = require(script.Parent.Parent.SignalPhaseBuilder)
		local Config = require(script.Parent.Parent.TrafficConfig)

		for _, side in { "right", "left" } do
			for _, angle in { 0, math.rad(37) } do
				it(string.format("serves a %s-driving crossroads at %.0f degrees with safe clearance", side, math.deg(angle)), function()
					local restore = Rules.getDrivingSide()
					Rules.setDrivingSide(side)
					local ok, problem = xpcall(function()
						local network = Network.new()
						local rotation = CFrame.Angles(0, angle, 0)
						for _, axis in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis } do
							local far = rotation:VectorToWorldSpace(axis) * 180
							network:addSegment(Vector3.zero, far / 3, far * 2 / 3, far, "CollectorRoad")
						end
						local graph = Graph.new()
						graph:Rebuild(network, {})
						local f = newFixture(false, { network = network, graph = graph, detector = Detector, builder = Builder })
						local geometries = Detector.detect(f.road)
						local nodeId, geometry = next(geometries)
						assert(nodeId and geometry and #geometry.arms == 4, "missing real signal geometry")
						local seen: { [string]: boolean } = {}
						local state: string? = nil
						local stateStart, now = 0, 0
						local yellowCount, clearanceCount = 0, 0
						for _ = 1, 1600 do
							local row = f.service.GetDebugSnapshot()[1]
							if row.state ~= state then
								if state == "yellow" then
									expect(now - stateStart >= Config.YELLOW_TIME - 0.01).to.equal(true)
									yellowCount += 1
								elseif state == "allred" then
									expect(now - stateStart >= Config.ALL_RED_TIME - 0.01).to.equal(true)
									clearanceCount += 1
								end
								state, stateStart = row.state, now
							end
							local greenArms = {}
							for i, arm in geometry.arms do
								for _, id in arm.inEdges do
									if f.service.CanGo(id) then
										greenArms[i] = true
										for _, outId in graph:GetEdge(id).out do
											if f.service.CanGo(id, outId) then seen[id .. ":" .. outId] = true end
										end
									end
								end
							end
							for i in greenArms do
								for j in greenArms do
									if i ~= j then expect(geometry.arms[i].dir:Dot(geometry.arms[j].dir) < -0.65).to.equal(true) end
								end
							end
							if state ~= "green" then expect(next(greenArms)).to.equal(nil) end
							f.step(0.1)
							now += 0.1
						end
						for _, arm in geometry.arms do
							for _, id in arm.inEdges do
								for _, outId in graph:GetEdge(id).out do expect(seen[id .. ":" .. outId]).to.equal(true) end
							end
						end
						expect(yellowCount >= 2 and clearanceCount >= 2).to.equal(true)
						local fromId: string? = nil
						local outId: string? = nil
						local crossing = Rules.getCrossingTurn()
						for _, arm in geometry.arms do
							for _, id in arm.inEdges do
								for exitId, movement in graph:GetEdge(id).outMovement do
									if movement == crossing then fromId, outId = id, exitId end
								end
							end
						end
						assert(fromId and outId, "fixture has no crossing turn")
						f.untilState("NS", "green")
						graph:Rebuild(network, { [nodeId] = {
							left = crossing ~= "left", right = crossing ~= "right", straight = true, uturn = false,
						} })
						f.rebuild(false)
						expect(f.service.GetDebugSnapshot()[1].state).to.equal("allred")
						for _ = 1, 40 do
							for _, arm in geometry.arms do
								for _, id in arm.inEdges do expect(f.service.CanGo(id)).to.equal(false) end
							end
							f.step(0.1)
						end
						for _ = 1, 1000 do
							if f.service.CanGo(fromId) then break end
							f.step(0.1)
						end
						expect(f.service.CanGo(fromId)).to.equal(true)
						expect(f.service.CanGo(fromId, outId)).to.equal(false)

					end, debug.traceback)
					Rules.setDrivingSide(restore)
					assert(ok, problem)
				end)
			end
		end
	end)

end

