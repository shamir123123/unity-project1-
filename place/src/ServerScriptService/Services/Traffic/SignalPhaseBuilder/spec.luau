--!strict
return function()
	local Builder = require(script.Parent)
	local SignalSpec = require(game:GetService("ReplicatedStorage").Road.SignalSpec)
	local function fixture(): (any, any)
		local edges, arms = {}, {}
		for i, dir in { Vector3.zAxis, -Vector3.zAxis, Vector3.xAxis, -Vector3.xAxis } do
			local thru, turn = "through" .. i, "turn" .. i
			edges[thru] = { out = { "straight" .. i, "cross" .. i } }
			edges[turn] = { out = { "cross" .. i } }
			arms[i] = table.freeze({ segmentId = i, dir = dir, axis = if i <= 2 then "NS" else "EW",
				inEdges = { thru, turn }, throughEdges = { thru }, dedicatedLeftEdges = { turn } })
		end
		return { nodeId = 1, pos = Vector3.zero, arms = table.freeze(arms) }, { GetEdge = function(_self: any, id: string) return edges[id] end }
	end
	describe("signal phase contracts", function()
		it("builds from immutable geometry and serves every legal movement", function()
			local geometry, graph = fixture()
			local result = Builder.build(geometry, graph, nil)
			local seen = {}
			for _, phase in result.phases do
				for edge, exits in phase.allowedConnections do
					for outId in exits do seen[edge .. ":" .. outId] = true end
				end
			end
			for i = 1, 4 do
				expect(seen["through" .. i .. ":straight" .. i]).to.equal(true)
				expect(seen["through" .. i .. ":cross" .. i]).to.equal(true)
				expect(seen["turn" .. i .. ":cross" .. i]).to.equal(true)
			end
		end)
		it("never pairs crossing roads and keeps protected lanes out of through", function()
			local geometry, graph = fixture()
			for _, phase in Builder.build(geometry, graph, nil).phases do
				expect(phase.greenEdges.through1 == true and phase.greenEdges.through3 == true).to.equal(false)
				if phase.kind == "through" then
					for i = 1, 4 do expect(phase.greenEdges["turn" .. i] == true).to.equal(false) end
				end
			end
		end)
		it("maps an arm override correctly after removing a split arm", function()
			local geometry, graph = fixture()
			local plan = SignalSpec.defaultPlan()
			plan.custom = true; plan.pedMode = "none"
			plan.arms = { [1] = { leftMode = "split" }, [3] = { leftMode = "permissive" } }
			local splitSeen, permissiveSeen = false, false
			for _, phase in Builder.build(geometry, graph, plan).phases do
				if phase.greenEdges.through1 then
					splitSeen = true
					for i = 2, 4 do expect(phase.greenEdges["through" .. i] == true).to.equal(false) end
				elseif phase.greenEdges.through3 then
					permissiveSeen = phase.greenEdges.turn3 == true
				end
			end
			expect(splitSeen).to.equal(true); expect(permissiveSeen).to.equal(true)
		end)
	end)
end

