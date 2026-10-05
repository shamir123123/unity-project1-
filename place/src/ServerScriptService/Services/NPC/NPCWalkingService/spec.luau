--!strict
return function()
	local RoadNetwork = require(game.ReplicatedStorage.Road.RoadNetwork)
	local function graph(points: {Vector3}, reverse: boolean?): any
		local net = RoadNetwork.new()
		for _,p in points do
			local a, b = p, Vector3.zero
			if reverse then a, b = b, a end
			local d = b - a
			net:addSegment(a, a + d/3, a + d*2/3, b, "CollectorRoad")
		end
		local walking = script.Parent :: ModuleScript
		local source = walking.Source:gsub("return NPCWalkingService",
			"NPCWalkingService.testRebuild = rebuildGraph; NPCWalkingService.testNodes = function() return _nodes end; NPCWalkingService.testPath = findPath; return NPCWalkingService")
		local chunk = assert(loadstring(source, "SidewalkGraphTest"))
		local env = setmetatable({script = walking, require = function(module: ModuleScript): any
			if module.Name == "CitizenModel" or module.Name == "PathFollower" then return {} end
			return require(module)
		end}, {__index = getfenv()})
		setfenv(chunk, env)
		local sw = chunk()
		sw.SetRoadService({getNetwork = function() return net end})
		sw.testRebuild()
		return sw
	end
	local function components(sw: any): number
		local nodes, seen = sw.testNodes(), {}
		local count = 0
		for id in nodes do
			if seen[id] then continue end
			count += 1
			local queue, cursor = {id}, 1
			seen[id] = true
			while cursor <= #queue do
				local u = queue[cursor]
				cursor += 1
				for _,v in nodes[u].neighbours do
					if not seen[v] then seen[v] = true; table.insert(queue, v) end
				end
			end
		end
		return count
	end
	local arms = {Vector3.new(-150,0,0), Vector3.new(150,0,0), Vector3.new(0,0,-150), Vector3.new(0,0,150)}
	describe("Sidewalk intersection connectivity", function()
		it("four-way crosswalks connect all street sidewalks", function()
			expect(components(graph(arms))).to.equal(1)
		end)
		it("corner links survive reversed segment orientation", function()
			expect(components(graph(arms, true))).to.equal(1)
		end)
		it("all sixteen cross-street pedestrian pairs have routes", function()
			local sw = graph(arms)
			local points = {Vector3.new(-120,0,8), Vector3.new(120,0,-8), Vector3.new(8,0,-120), Vector3.new(-8,0,120)}
			for _,a in points do
				for _,b in points do expect(sw.testPath(a, b, 60) ~= nil).to.equal(true) end
			end
		end)
		it("a T junction remains connected", function()
			expect(components(graph({arms[1], arms[2], arms[3]}))).to.equal(1)
		end)
		it("a straight street does not gain an unpainted road crossing", function()
			expect(components(graph({arms[1], arms[2]}))).to.equal(2)
		end)
	end)
	it("a full pedestrian body pool keeps the trip as a real agent",function()
		local source=(script.Parent :: ModuleScript).Source
		local h={adopted=0,arrived=0}
		local env:any=setmetatable({NPCWalkingService={},Const=require(game.ServerScriptService.Services.City.CitySimConstants),
			_built=true,_walkers=table.create(400,{}),BODY_RANGE=500,_nextCommuterId=0,walkerCap=function()return 400 end,yieldFarthestBody=function()return false end,
			ensureFolder=function()return nil end,
			PathFollower={nearestPlayerDistSq=function()return 0 end},
			_agentService={adopt=function(_,_,cb)h.adopted+=1;h.callback=cb;return -17 end},
			makeModel=function()error("allocated body beyond its budget")end,
			task={defer=function()error("teleported overflow trip")end}},{__index=getfenv()})
		local cap=assert(source:match("local MAX_WALKERS[^\n]+"))
		local first=assert(source:find("function NPCWalkingService.spawnCommuter(",1,true));local last=assert(source:find("\nend",first,true))
		local fn=assert(loadstring(cap.."\n"..source:sub(first,last+4)));setfenv(fn,env);fn()
		local id=env.NPCWalkingService.spawnCommuter(Vector3.zero,Vector3.new(100,0,0),function()h.arrived+=1 end)
		expect(id).to.equal(-17);expect(h.adopted).to.equal(1);expect(h.arrived).to.equal(0)
		h.callback();expect(h.arrived).to.equal(1)
	end)
	describe("Pedestrian fast-forward movement",function()
		local function walker(points:any,flags:any?):any
			local source=(script.Parent :: ModuleScript).Source
			local first=assert(source:find("local function stepWalker(",1,true));local last=assert(source:find("\n-- ═",first,true))
			local h:any={sends=0,arrivals=0,blocked=false}
			local env:any=setmetatable({_version=1,STEP_DIST=.125,WALK_SPEED=2.5,CROSSWALK_SPEED=1.75,
				CROSS_WAIT_MAX=6,CROSS_CHECK_RADIUS=12,WALK_SEND_DT=1/12,COMMUTER_SNAP_RADIUS=60,
				PathFollower={anyCarApproaching=function()return h.blocked end,streamPose=function()h.sends+=1 end},
				finishCommuter=function(w)h.arrivals+=1;w.model:Destroy()end},
				{__index=getfenv()})
			local fn=assert(loadstring(source:sub(first,last-1).."\nreturn stepWalker"));setfenv(fn,env);h.step=fn()
			local model=Instance.new("Model");local root=Instance.new("Part");root.Parent=model;model.PrimaryPart=root
			h.w={model=model,directed=true,graphVer=1,waypoints=points,crossFlags=flags or {},wpIndex=1,
				pos=Vector3.zero,sendAccum=0,crossingCommitted=false,crossWait=0}
			h.destroy=function()model:Destroy()end
			return h
		end
		it("fast-forward consumes the full time across densely spaced waypoints",function()
			local h=walker({Vector3.new(.25,0,0),Vector3.new(.5,0,0),Vector3.new(2,0,0)})
			h.step(h.w,.3)
			local x=h.w.pos.X;local sends=h.sends;h.destroy()
			expect(math.abs(x-.75)<.001).to.equal(true);expect(sends).to.equal(1)
		end)
		it("fast-forward follows a corner without cutting it",function()
			local h=walker({Vector3.new(.5,0,0),Vector3.new(.5,0,3)})
			h.step(h.w,.3);local p=h.w.pos;h.destroy()
			expect((p-Vector3.new(.5,0,.25)).Magnitude<.001).to.equal(true)
		end)
		it("a crossing reached during the same update still waits at its kerb",function()
			local h=walker({Vector3.new(.25,0,0),Vector3.new(2,0,0)},{false,true})
			h.blocked=true;h.step(h.w,.3)
			local pos=h.w.pos;local waited=h.w.crossWait;h.destroy()
			expect(pos).to.equal(Vector3.new(.25,0,0));expect(waited>0).to.equal(true)
		end)
		it("completion does not need an extra update after reaching the destination",function()
			local h=walker({Vector3.new(.5,0,0)})
			h.step(h.w,.3);h.step(h.w,.3)
			expect(h.arrivals).to.equal(1);h.destroy()
		end)
	end)

end
