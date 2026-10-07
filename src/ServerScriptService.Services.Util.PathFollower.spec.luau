--!strict
return function()
	it("a cached stream id is restored on the model before another pose is sent", function()
		local source=(script.Parent :: ModuleScript).Source
		local car=Instance.new("Model");car.Parent=script
		local env:any=setmetatable({_npcIds={[car]=42},_modelOfId={},_streamModels={},_streamPoses={},
			_streamKeep={},_streamIndex={},_poseOf={},_movedAt={},_flushScheduled=true}, {__index=getfenv()})
		local first=assert(source:find("function PathFollower.streamPose(",1,true))
		local last=assert(source:find("\nend",first,true))
		env.PathFollower={}
		local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
		env.PathFollower.streamPose(car,CFrame.new(10,0,0))
		local id=car:GetAttribute("NpcId");car:Destroy()
		expect(id).to.equal(42)
	end)
	it("a batch sends the latest pose rather than the first fast-forward substep",function()
		local source=(script.Parent :: ModuleScript).Source
		local model=Instance.new("Model")
		local env:any=setmetatable({_npcIds={[model]=42},_modelOfId={},_streamModels={},_streamPoses={},
			_streamKeep={},_streamIndex={},_poseOf={},_movedAt={},_flushScheduled=true,PathFollower={}},
			{__index=getfenv()})
		local first=assert(source:find("function PathFollower.streamPose(",1,true))
		local last=assert(source:find("\nend",first,true))
		local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
		for x=1,6 do env.PathFollower.streamPose(model,CFrame.new(x,0,0))end
		model:Destroy()
		expect(#env._streamModels).to.equal(1);expect(env._streamPoses[1].Position.X).to.equal(6)
	end)
	local PathFollower = require(script.Parent)
	local fixtures: {Model} = {}
	local fixtureFolder: Folder

	local function car(pos: Vector3, dir: Vector3?): (Model, any)
		local model = Instance.new("Model")
		model.Name = "TrafficFixture"
		model.Parent = fixtureFolder
		local root = Instance.new("Part")
		root.Size = Vector3.new(2, 2, 5)
		root.Anchored = true
		root.Parent = model
		model.PrimaryPart = root
		table.insert(fixtures, model)
		local state = {model = model, heightOffset = 0, replicateAccum = 0}
		PathFollower.place(state, pos, dir or Vector3.zAxis, 0.1)
		return model, state
	end

	local function fixture(name: string, test: () -> ())
		it(name, function()
			fixtureFolder = Instance.new("Folder")
			local ok, err = pcall(test)
			for _, model in fixtures do PathFollower.forget(model) end
			table.clear(fixtures)
			fixtureFolder:Destroy()
			if not ok then error(err, 0) end
		end)
	end


	describe("Vehicle orientation",function()
		fixture("a height-only waypoint keeps the vehicle upright",function()
			local model,state=car(Vector3.zero,Vector3.xAxis)
			PathFollower.place(state,Vector3.new(0,.6,0),-Vector3.yAxis,.05)
			assert(state.smoothCFrame.UpVector.Y>.99,"vertical waypoint tipped the car")
			assert(state.smoothCFrame.LookVector:Dot(Vector3.xAxis)>.99,"vertical waypoint changed heading")
		end)
		fixture("normal slopes retain their pitch",function()
			local _,state=car(Vector3.zero,Vector3.new(1,.2,0).Unit)
			assert(state.smoothCFrame.LookVector.Y>.15,"road grade was flattened")
		end)
	end)

	describe("PathFollower traffic clearance", function()
		fixture("a perpendicular car blocks the lane before its centre enters it", function()
			local model = car(Vector3.zero)
			local blocker = car(Vector3.new(2.5,0,3),Vector3.xAxis)
			local _,clearance,_,hit = PathFollower.getMotionLimits(model,Vector3.zero,Vector3.zAxis)
			expect(hit).to.equal(blocker)
			expect(clearance).to.equal(0)
		end)
		fixture("a long crossing truck is detected across its full body", function()
			local model = car(Vector3.zero)
			local blocker,state = car(Vector3.new(8,0,6),Vector3.xAxis)
			PathFollower.forget(blocker)
			local root = blocker.PrimaryPart :: BasePart
			root.Size = Vector3.new(2,2,20)
			PathFollower.place(state,Vector3.new(8,0,6),Vector3.xAxis,0.1)
			local _,_,_,hit = PathFollower.getMotionLimits(model,Vector3.zero,Vector3.zAxis)
			expect(hit).to.equal(blocker)
		end)
		fixture("holds a bumper gap behind a car on the same road", function()
			local model = car(Vector3.zero)
			local blocker = car(Vector3.new(0, 0, 6))
			local speed, clearance, _, hit = PathFollower.getMotionLimits(model, Vector3.zero, Vector3.zAxis)
			expect(speed).to.equal(0)
			expect(clearance).to.equal(0)
			expect(hit).to.equal(blocker)
		end)

		for _, height in {8, -8} do
			fixture("ignores traffic on a separate road deck at " .. tostring(height), function()
				local model = car(Vector3.zero)
				car(Vector3.new(0, height, 6))
				local speed, clearance, _, hit = PathFollower.getMotionLimits(model, Vector3.zero, Vector3.zAxis)
				expect(speed).to.equal(1)
				expect(clearance).to.equal(math.huge)
				expect(hit).to.equal(nil)
			end)
		end

		fixture("keeps following a car uphill across a large Y difference", function()
			local dir = Vector3.new(0, 0.5, 1).Unit
			local model = car(Vector3.zero, dir)
			local leader = car(Vector3.new(0, 6, 12), dir)
			local speed, _, _, hit = PathFollower.getMotionLimits(model, Vector3.zero, dir)
			expect(speed < 1).to.equal(true)
			expect(hit).to.equal(leader)
		end)

		fixture("ignores the neighboring lane", function()
			local model = car(Vector3.zero)
			car(Vector3.new(4, 0, 6))
			expect(PathFollower.getForwardClearance(model, Vector3.zero, Vector3.zAxis)).to.equal(math.huge)
		end)

		fixture("ignores a car behind", function()
			local model = car(Vector3.zero)
			car(Vector3.new(0, 0, -6))
			expect(PathFollower.getForwardClearance(model, Vector3.zero, Vector3.zAxis)).to.equal(math.huge)
		end)

		fixture("blocks a close head-on car", function()
			local model = car(Vector3.zero)
			car(Vector3.new(0, 0, 6), -Vector3.zAxis)
			expect(PathFollower.getForwardClearance(model, Vector3.zero, Vector3.zAxis)).to.equal(0)
		end)

		fixture("clears a removed leader immediately", function()
			local model = car(Vector3.zero)
			local leader = car(Vector3.new(0, 0, 6))
			PathFollower.forget(leader)
			expect(PathFollower.getForwardClearance(model, Vector3.zero, Vector3.zAxis)).to.equal(math.huge)
		end)

		fixture("ignores destroyed cars in the spatial bucket", function()
			local model = car(Vector3.zero)
			local leader = car(Vector3.new(0, 0, 6))
			leader:Destroy()
			expect(PathFollower.getForwardClearance(model, Vector3.zero, Vector3.zAxis)).to.equal(math.huge)
		end)

		fixture("a bridge vehicle does not block a pedestrian crossing below", function()
			car(Vector3.new(0, 8, -3))
			expect(PathFollower.anyCarApproaching(Vector3.zero, 10)).to.equal(false)
		end)

		fixture("a same-road vehicle blocks a pedestrian crossing", function()
			car(Vector3.new(0, 0, -3))
			expect(PathFollower.anyCarApproaching(Vector3.zero, 10)).to.equal(true)
		end)

		fixture("a bridge vehicle does not occupy a driveway below", function()
			car(Vector3.new(0, 8, 0))
			expect(PathFollower.anyVehicleWithin(Vector3.zero, 10, function() return true end)).to.equal(false)
		end)

		fixture("same-road driveway occupancy still honors its filter", function()
			car(Vector3.zero)
			expect(PathFollower.anyVehicleWithin(Vector3.zero, 10, function() return true end)).to.equal(true)
			expect(PathFollower.anyVehicleWithin(Vector3.zero, 10, function() return false end)).to.equal(false)
		end)

		fixture("a downhill car still blocks a crossing on its grade", function()
			car(Vector3.new(0, 6, -12), Vector3.new(0, -0.5, 1).Unit)
			expect(PathFollower.anyCarApproaching(Vector3.zero, 15)).to.equal(true)
		end)

		fixture("a sloping road still occupies its driveway approach", function()
			car(Vector3.new(0, 6, -12), Vector3.new(0, -0.5, 1).Unit)
			expect(PathFollower.anyVehicleWithin(Vector3.zero, 15, function() return true end)).to.equal(true)
		end)

		fixture("hands an untagged vehicle back to property movement", function()
			local model, state = car(Vector3.zero)
			local tags = game:GetService("CollectionService")
			tags:AddTag(model, "NPCDriver")
			PathFollower.place(state, Vector3.new(0, 0, 10), Vector3.zAxis, 0.1)
			tags:RemoveTag(model, "NPCDriver")
			PathFollower.forget(model)
			PathFollower.place(state, Vector3.new(0, 0, 20), Vector3.zAxis, 0.1)
			expect((model.PrimaryPart :: BasePart).Position).to.equal(Vector3.new(0, 0, 20))
		end)

		fixture("replicates a stationary half-turn", function()
			local model, state = car(Vector3.zero)
			PathFollower.place(state, Vector3.zero, -Vector3.zAxis, 0.1)
			expect((model.PrimaryPart :: BasePart).CFrame.LookVector:Dot(-Vector3.zAxis) > 0.999).to.equal(true)
		end)
	end)

	describe("PathFollower path distance", function()
		it("clamps travel to the endpoints", function()
			local points = {Vector3.zero, Vector3.new(0, 0, 10), Vector3.new(10, 0, 10)}
			local cum = PathFollower.cumOf(points)
			expect((PathFollower.pointAtDist(points, cum, -1))).to.equal(points[1])
			expect((PathFollower.pointAtDist(points, cum, 100))).to.equal(points[3])
		end)

		it("preserves leftover distance beyond a corner", function()
			local points = {Vector3.zero, Vector3.new(0, 0, 10), Vector3.new(10, 0, 10)}
			local pos, dir = PathFollower.pointAtDist(points, PathFollower.cumOf(points), 13)
			expect(pos).to.equal(Vector3.new(3, 0, 10))
			expect(dir).to.equal(Vector3.xAxis)
		end)
	end)
end
