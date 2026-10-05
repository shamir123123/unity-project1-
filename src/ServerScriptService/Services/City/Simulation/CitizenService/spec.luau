--!strict
return function()
	local PathFollower = require(game.ServerScriptService.Services.Util.PathFollower)
	local CitizenJourneys = require(script.Parent.Parent.CitizenJourneys)
	local source = (script.Parent :: ModuleScript).Source


	it("a failed hidden launch never exposes an unowned road car",function()
		local hidden=Instance.new("Folder");local visible=Instance.new("Folder")
		local car=Instance.new("Model");local root=Instance.new("Part");root.Parent=car;car.PrimaryPart=root;car.Parent=hidden
		local env=setmetatable({Cars={},_trips={},Garage={folder=hidden,fetch=function(m)m.Parent=visible end},
			NPCDriverService={IsPointClear=function()return true end,IsOnRoad=function()return false end},
			PathFollower={anyVehicleWithin=function()return false end}},{__index=getfenv()})
		local first=assert(source:find("function Cars.fetchWhenClear(",1,true))
		local last=assert(source:find("\nend",first,true))
		local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
		env.Cars.fetchWhenClear(car,function()end)
		local stayedHidden=car.Parent==hidden
		hidden:Destroy();visible:Destroy()
		expect(stayedHidden).to.equal(true)
	end)
	it("a gated parking arrival remains an obstacle before its first parking tick",function()
		local folder=Instance.new("Folder")
		local car=Instance.new("Model");local root=Instance.new("Part")
		root.Size=Vector3.new(4,3,8);root.Anchored=true;root.Parent=car
		car.PrimaryPart=root;car.Parent=folder;car:PivotTo(CFrame.new(0,2,0))
		local env:any=setmetatable({_trips={},_tripCount=0,Cars={},CAR_HEIGHT=2,PathFollower=PathFollower},{__index=getfenv()})
		local first=assert(source:find("local function lineFollow(",1,true))
		local last=assert(source:find("\nend",first,true))
		local fn=assert(loadstring(source:sub(first,last+4).."\nreturn lineFollow"))
		setfenv(fn,env)
		local follow=fn()
		follow(car,{Vector3.zero,Vector3.new(0,0,-20)},10,nil,2,function()return false end,true)
		local visible=PathFollower.anyVehicleWithin(Vector3.new(0,2,0),1,function(other)return other==car end)
		PathFollower.forget(car);folder:Destroy()
		expect(visible).to.equal(true)
	end)




	describe("JSON reload on a real road graph",function()
		it("seats duplicate saves on the lane and registers each only when its road space is free",function()
			local cache={}
			local fresh: (ModuleScript)->any
			fresh=function(module)
				if module==game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function()error("test network send")end}}end
				if cache[module] then return cache[module] end
				local world=if module.Name=="RoadRules" then {
					GetAttribute=function()return "Right" end,SetAttribute=function()end,
					GetAttributeChangedSignal=function()return {Connect=function()return {Disconnect=function()end}end}end,
				} else workspace
				local fn=assert(loadstring(module.Source));setfenv(fn,setmetatable({script=module,require=fresh,workspace=world},{__index=getfenv()}))
				local result=fn();cache[module]=result;return result
			end
			local net=fresh(game.ReplicatedStorage.Road.RoadNetwork).new()
			net:addSegment(Vector3.zero,Vector3.new(200,0,0),Vector3.new(400,0,0),Vector3.new(600,0,0),"NarrowRoad")
			local graph=fresh(game.ReplicatedStorage.Road.RoadNavigationGraph).new();graph:Rebuild(net,{})
			local lane
			for _,edge in graph:GetEdges() do
				if (edge.points[#edge.points]-edge.points[1]).X>0 then lane=edge;break end
			end
			assert(lane,"no eastbound lane in real graph")
			local f=fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)(graph,net,fresh)
			local garage=Instance.new("Folder")
			local visible=Instance.new("Folder")
			local p,dir=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),40)
			local goal=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),250)
			local adults={{pid=1,tripId=0,jobId="shop"},{pid=2,tripId=0,jobId="shop"}}
			local household={id=1,homeId="home",adults=adults}
			local pending={}
			local env:any=setmetatable({
				CitizenService={},NPCDriverService=f.d.api,PathFollower=f.follower,
				RoadRules={getLaneSideSign=function()return 1 end},
				DriverProfile={fromModel=function()return nil end},
				_households={[1]=household},_trips={},_tripCount=0,_directedCount=0,_carDriveTokens={},
				CAR_HEIGHT=0,CAR_SPEED=12,MAX_TRIP_CARS=12000,RESERVED_ARRIVAL_TRIPS=6,
				DRIVE_RETRY_DELAY=2,MAX_DRIVE_RETRY_DELAY=30,ROADSIDE_RADIUS=30,
				Cars={GAP_SECONDS=3,ROAD_GATE_SETBACK=16,roadTokens={},laneAsker={},MANEUVER_STALL_SECONDS=20,GATE_STALL_SECONDS=120,GAP_PATIENCE=2,LOT_STANDOFF_SECONDS=4,LOT_STANDOFF_CLEARANCE=.05,ACCESS_CLEAR_RADIUS=12},
				Garage={stow=function(car)car.Parent=garage end,fetch=function(car)car.Parent=visible end},
				nav=function()return graph end,releaseSpot=function()end,claimDriveway=function()return nil,nil end,
				resolveSavedKey=function(keys,i)return keys[i]end,
				carDataToCFrame=function(c)return CFrame.lookAt(Vector3.new(c[1],c[2],c[3]),Vector3.new(c[1],c[2],c[3])+dir)end,
				pickBuildingPark=function()return {cf=CFrame.lookAt(goal+Vector3.new(0,0,20),goal+Vector3.new(1,0,20)),lotEntry=goal}end,
				task={delay=function(_,fn)table.insert(pending,fn)end},
				newCar=function()
					local car=Instance.new("Model");local body=Instance.new("Part")
					body.Size=Vector3.new(4,3,8);body.Anchored=true;body.Parent=car;car.PrimaryPart=body;car.Parent=garage
					car:SetAttribute("NPCHeightOffset",0);return car
				end,
			},{__index=getfenv()})
			local a=assert(source:find("function Cars.releaseRoadSlot",1,true));local b=assert(source:find("\nend",a,true))
			local movement=assert(source:find("local function lineFollow(",1,true))
			local movementEnd=assert(source:find("-- == Building views",movement,true))
			local restore=assert(source:find("local function resumeRestoredCar(",1,true))
			local restoreEnd=assert(source:find("-- City restore: budget",restore,true))
			local fn=assert(loadstring(source:sub(a,b+4).."\n"..source:sub(movement,movementEnd-1).."\n"..source:sub(restore,restoreEnd-1).."\nreturn {resume=resumeRestoredCar,step=stepTrips}"))
			setfenv(fn,env);local api=fn()
			local Columns=fresh(script.Parent.Parent.CitizenSaveColumns)
			local oldPose=p+Vector3.new(0,0,5)
			local rows=Columns.fromColumns(game.HttpService:JSONDecode(game.HttpService:JSONEncode(Columns.toColumns({
				{h=1,a=2,k=0,e={2,0,0,0},j={},cv={
					{a=1,c={oldPose.X,oldPose.Y,oldPose.Z,0},d=2,k="work",ln=lane.id,ld=40},
					{a=2,c={oldPose.X,oldPose.Y,oldPose.Z,0},d=2,k="work",ln=lane.id,ld=40},
				}}
			}))))
			local ok,err=pcall(function()
				for _,record in rows[1].cv do api.resume(household,record,{"home","shop"},{shop={bpId="shop"}},{bpId="home"})end
				local first,second=adults[1].car,adults[2].car
				assert(f.d.api.IsDirected(first),"restored citizen is not owned by road driver")
				assert(f.follower.isRegistered(first),"restored citizen missing collision registration")
				local cf=assert(f.d.api.GetLivePose(first))
				local delta=cf.Position-p
				assert(Vector3.new(delta.X,0,delta.Z).Magnitude<.001,"restored car is outside lane centre")
				assert(math.abs(delta.Y-0.5)<.001,"restored car is not seated on the road surface")
				assert(cf.LookVector:Dot(dir)>.999,"restored car faces wrong way")
				assert(not f.d.api.IsDirected(second) and second.Parent==garage,"duplicate save overlapped a live car")
				assert(second:GetAttribute("RestorePending")==true)
				for tick=1,1200 do
					f.d.clock(.05);f.d.reindex()
					local states={};for _,state in f.d.drivers do table.insert(states,state)end
					for _,state in states do f.d.step(state,.05);f.d.reindex()end
					api.step(.05)
					if tick%40==0 then local callbacks=pending;pending={};for _,cb in callbacks do cb()end end
					if adults[1].stage=="atWork" and adults[2].stage=="atWork" then break end
				end
				assert(adults[1].stage=="atWork" and adults[2].stage=="atWork","restored cars failed to finish actual drive and parking")
			end)
			for _,adult in adults do if adult.car then f.follower.forget(adult.car)end end
			f.destroy();garage:Destroy();visible:Destroy();assert(ok,err)
		end)
	end)

	describe("Complete vehicle reset", function()
		it("clears parked, garage, driveway, retry and road cars while keeping homes and jobs", function()
			local folder=Instance.new("Folder")
			local cars={}
			for i=1,5 do
				local car=Instance.new("Model");local root=Instance.new("Part")
				root.Anchored=true;root.Parent=car;car.PrimaryPart=root;car.Parent=folder;cars[i]=car
			end
			local adults={}
			for i,car in cars do adults[i]={car=car,pid=i,tripId=3,jobId="factory",usingCar=i>=3,stage=if i>=3 then "transit" else "atWork"} end
			local household={id=1,homeId="home",adults=adults,arriving=false}
			local released,forgotten={},{}
			local env:any=setmetatable({
				CitizenService={},_households={[1]=household},_trips={[cars[3]]={}},_carDriveTokens={[cars[4]]=1},
				_carCount=5,_tripCount=1,_directedCount=1,Pipe={entries={{car=cars[5]}}},
				Cars={roadTokens={[cars[5]]=1}},PathFollower={forget=function(car)forgotten[car]=true end},
				NPCDriverService={ReleaseDirected=function(car)released[car]=true end},
				releaseSpot=function()end,releaseDriveway=function()end,
			},{__index=getfenv()})
			env.Cars.releaseRoadSlot=function(car)env.Cars.roadTokens[car]=nil end
			local destroyStart=assert(source:find("local function destroyCar(",1,true))
			local destroyEnd=assert(source:find("\nend",destroyStart,true))
			local dropStart=assert(source:find("function Cars.drop(",1,true))
			local dropEnd=assert(source:find("\nend",dropStart,true))
			local resetStart=assert(source:find("function CitizenService.ResetVehicles()",1,true))
			local resetEnd=assert(source:find("\nlocal function clearRuntimeHouseholds",resetStart,true))
			local fn=assert(loadstring(source:sub(destroyStart,destroyEnd+4).."\n"..source:sub(dropStart,dropEnd+4).."\n"..source:sub(resetStart,resetEnd-1)))
			setfenv(fn,env);fn()
			local ok,err=pcall(function()
				expect(env.CitizenService.ResetVehicles()).to.equal(5)
				for i,car in cars do
					assert(car.Parent==nil and released[car] and forgotten[car])
					assert(adults[i].car==nil and adults[i].jobId=="factory")
					assert(adults[i].stage==(if i>=3 then "atHome" else "atWork"))
				end
				assert(env._households[1]==household and household.homeId=="home")
				assert(next(env._trips)==nil and next(env.Cars.roadTokens)==nil and #env.Pipe.entries==0)
				expect(env.CitizenService.ResetVehicles()).to.equal(0)
			end)
			folder:Destroy();assert(ok,err)
		end)
		it("a destroyed garage car cannot launch through an old delayed callback",function()
			local folder=Instance.new("Folder");local car=Instance.new("Model");car.Parent=folder
			local fired=0;local pending
			local env=setmetatable({
				Cars={},Garage={folder=folder},NPCDriverService={IsPointClear=function()return false end},
				task={delay=function(_,fn)pending=fn end},
			},{__index=getfenv()})
			local first=assert(source:find("function Cars.fetchWhenClear(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			env.Cars.fetchWhenClear(car,function()fired+=1 end)
			assert(pending);car:Destroy();pending(car,function()fired+=1 end)
			expect(fired).to.equal(0);folder:Destroy()
		end)
	end)




	it("population groups count the real ages rather than assigning random demographic shares",function()
		local env=setmetatable({CitizenService={},_population=4,_carCount=0,_tripCount=0,_directedCount=0,
			_households={{adults={{age=40},{age=70}},kids={{age=8},{age=16}}}},
			TravelModeChoice=require(script.Parent.Parent.TravelModeChoice)},{__index=getfenv()})
		local first=assert(source:find("function CitizenService.getStats(",1,true));local last=assert(source:find("\nend",first,true))
		local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
		local stats=env.CitizenService.getStats()
		expect(stats.children).to.equal(1);expect(stats.teens).to.equal(1)
		expect(stats.workingAge).to.equal(1);expect(stats.seniors).to.equal(1)
	end)
	describe("Nearest legal destination parking",function()
		local function pick(publicDistance:number, stalls:any):any
			local env:any=setmetatable({Cars={},_stallTaken={},ROADSIDE_RADIUS=100,
				reverseRoute=function(r)return r end,
				_buildingService={getParkSpots=function()return {stalls=stalls}end,
					getKerb=function()return Vector3.zero end,getDoor=function()return Vector3.zero end},
				_parkingService={reserveNearest=function()return "public",CFrame.new(publicDistance,0,0)end,
					release=function()end}}, {__index=getfenv()})
			local first=assert(source:find("local function pickBuildingPark(",1,true));local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn pickBuildingPark"));setfenv(fn,env)
			return fn()({id=1},"shop")
		end
		it("parks in the building's own lot even when a public bay is closer",function()
			expect(pick(5,{{cf=CFrame.new(40,0,0),route={}}}).stallKey).to.equal("shop#1")
		end)
		it("falls back to the nearest public bay when the lot has no free stall",function()
			expect(pick(5,{}).spotId).to.equal("public")
		end)
		it("chooses the nearest building stall rather than the first free stall",function()
			expect(pick(50,{{cf=CFrame.new(40,0,0),route={}},{cf=CFrame.new(5,0,0),route={}}}).stallKey).to.equal("shop#2")
		end)
	end)
	describe("Garage admission",function()
		it("a canceled hidden departure stays hidden",function()
			local hidden=Instance.new("Folder");local car=Instance.new("Model");car.Parent=hidden
			local fetched=false
			local env=setmetatable({Cars={},Garage={folder=hidden,fetch=function()fetched=true end},
				NPCDriverService={IsOnRoad=function()return false end,IsPointClear=function()return true end},
				PathFollower={anyVehicleWithin=function()return false end}},
				{__index=getfenv()})
			local first=assert(source:find("function Cars.fetchWhenClear(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			env.Cars.fetchWhenClear(car,function()end,function()return false end)
			hidden:Destroy();assert(not fetched,"canceled trip exposed a stale car")
		end)

		it("two garage departures in one update cannot both appear in the same doorway",function()
			local hidden=Instance.new("Folder");local visible=Instance.new("Folder")
			local cars={}
			for _=1,2 do local m=Instance.new("Model");local r=Instance.new("Part");r.Size=Vector3.new(4,3,8);r.Parent=m;m.PrimaryPart=r;m.Parent=hidden;table.insert(cars,m)end
			local fired=0
			local env:any=setmetatable({Cars={},_trips={},Garage={folder=hidden,fetch=function(m)m.Parent=visible end},
				NPCDriverService={IsOnRoad=function()return false end,IsPointClear=function()return true end},PathFollower=PathFollower,
				task={delay=function()end}},{__index=getfenv()})
			local first=assert(source:find("function Cars.fetchWhenClear(",1,true));local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			for _,m in cars do env.Cars.fetchWhenClear(m,function()fired+=1;env._trips[m]={}end)end
			local ok,err=pcall(function()expect(fired).to.equal(1);expect(cars[2].Parent).to.equal(hidden)end)
			for _,m in cars do PathFollower.forget(m)end;hidden:Destroy();visible:Destroy();assert(ok,err)
		end)

		it("a car at the garage door blocks the next spawn even when it is not a road driver",function()
			local hidden=Instance.new("Folder");local visible=Instance.new("Folder")
			local car=Instance.new("Model");car.Parent=hidden
			local root=Instance.new("Part");root.Parent=car;car.PrimaryPart=root
			local fired=0;local pending;local occupied=true
			local env=setmetatable({Cars={},_trips={},Garage={folder=hidden,fetch=function(m)m.Parent=visible end},
				NPCDriverService={IsOnRoad=function()return fired>0 end,IsPointClear=function()return true end},
				PathFollower={anyVehicleWithin=function()return occupied end},
				task={delay=function(_,fn)pending=fn end}},{__index=getfenv()})
			local first=assert(source:find("function Cars.fetchWhenClear(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			env.Cars.fetchWhenClear(car,function()fired+=1 end)
			local ok,err=pcall(function()
				expect(fired).to.equal(0);expect(car.Parent).to.equal(hidden)
				occupied=false;assert(pending);pending(car,function()fired+=1 end)
				expect(fired).to.equal(1);expect(car.Parent).to.equal(visible)
			end)
			hidden:Destroy();visible:Destroy();assert(ok,err)
		end)
		it("full home parking returns a pocket destination rather than a visible roadside stall",function()
			local env=setmetatable({Garage={home=function()return nil end},
				_buildingService={getKerb=function()return Vector3.zero end},
				_parkingService={reserveNearest=function()return nil,nil end},
				ROADSIDE_RADIUS=100,Cars={roadStop=function()return {cf=CFrame.new(),pocket=true}end}},{__index=getfenv()})
			local first=assert(source:find("local function pickHomePark(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn pickHomePark"));setfenv(fn,env)
			expect(fn()({homeId="home"},{}).pocket).to.equal(true)
		end)
	end)

	describe("Off-road activity save pose",function()

		it("a physical road trip waiting to retry is saved as a journey rather than parked scenery",function()
			local folder=Instance.new("Folder");local car=Instance.new("Model");local root=Instance.new("Part")
			root.Anchored=true;root.Parent=car;car.PrimaryPart=root;car.Parent=folder
			car:SetAttribute("DriveRetryPending",true)
			local adult={car=car,stage="transit",usingCar=true,outDestId="shop",outKind="work"}
			local first=assert(source:find("local function activeCarState(",1,true))
			local last=assert(source:find("\nend",first,true))
			local env=setmetatable({
				Workspace=folder,_trips={},
				NPCDriverService={IsDirected=function()return false end,GetLivePose=function()return nil end,GetLaneAnchor=function()return nil end},
				buildingSaveKey=function(b)return b.bpId end,cframeToCarData=function(cf)return {cf.Position.X,cf.Position.Y,cf.Position.Z}end,
			},{__index=getfenv()})
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn activeCarState"));setfenv(fn,env)
			local ok,err=pcall(function()
				local result=fn()({adults={adult}},1,{shop={bpId="shop"}},function()return 2 end,1)
				assert(result and result.d==2 and result.k=="work","retry lost its active destination")
			end)
			folder:Destroy();assert(ok,err)
		end)

		it("saves the simulated driveway pose instead of the stale replicated model pivot",function()
			local folder=Instance.new("Folder")
			local car=Instance.new("Model");local root=Instance.new("Part");root.Anchored=true;root.Parent=car;car.PrimaryPart=root;car.Parent=folder
			car:PivotTo(CFrame.new(0,0,0))
			local adult: any={car=car,stage="transit",usingCar=true,outDestId="shop",outKind="shop"}
			local first=assert(source:find("local function activeCarState(",1,true))
			local last=assert(source:find("\nend",first,true))
			local env=setmetatable({
				Workspace=folder,_trips={[car]={smoothCFrame=CFrame.lookAt(Vector3.new(100,3,50),Vector3.new(101,3,50))}},
				NPCDriverService={IsDirected=function()return false end,GetLivePose=function()return nil end,GetLaneAnchor=function()return nil end},
				buildingSaveKey=function(b)return b.bpId end,
				cframeToCarData=function(cf)return {cf.Position.X,cf.Position.Y,cf.Position.Z}end,
			},{__index=getfenv()})
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn activeCarState"));setfenv(fn,env)
			local ok,err=pcall(function()
				local result=fn()({adults={adult}},1,{shop={bpId="shop"}},function()return 2 end,1)
				expect(result.c[1]).to.equal(100);expect(result.c[3]).to.equal(50)
			end)
			folder:Destroy();if not ok then error(err,0)end
		end)
	end)


	describe("Optional outdoor activities",function()
		it("a leisure stroll cannot start at night",function()
			local spawned=0
			local env:any=setmetatable({Trips={WALK_MIN=60,WALK_MAX=180,WALK_FROM_HOUR=9,WALK_TO_HOUR=18},
				_timeService={getDayFraction=function()return 23/24 end},
				_rng={NextNumber=function()return .5 end},door=function()return Vector3.zero end,
				_walkingService={getNearestPoint=function()return Vector3.new(100,0,0)end,
					spawnCommuter=function()spawned+=1;return 1 end},
				personLabel=function()return "Test"end,_households={[1]={}}},{__index=getfenv()})
			local first=assert(source:find("function Trips.walk(",1,true));local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			expect(env.Trips.walk({id=1,homeId="home"},{pid=1,tripId=0,gender="M"})).to.equal(false)
			expect(spawned).to.equal(0)
		end)
		it("full parking does not rerun a purchase search on every activity batch",function()
			local calls=0
			local env:any=setmetatable({Const=require(game.ServerScriptService.Services.City.CitySimConstants),
				Cars={give=function()calls+=1 end,drop=function()end}},{__index=getfenv()})
			local activity=assert(source:find("local function doActivities(",1,true))
			local first=assert(source:find("\t\tfor _, a in h.adults do\n\t\t\tif a.car",activity,true))
			local last=assert(source:find("\n\n\t\tfor _, k",first,true))
			local fn=assert(loadstring("return function(h,now)\n"..source:sub(first,last-1).."\nend"));setfenv(fn,env)
			local step=fn();local h={adults={{ownsCar=true,stage="atHome"}}}
			for _=1,100 do step(h,0)end
			expect(calls).to.equal(1)
			step(h,6);expect(calls).to.equal(2)
		end)
	end)
	describe("Activity scheduler cadence", function()
		local function runWorker(speed: number, restoring: boolean, failFirst: boolean): any
			local first=assert(source:find("function CitizenService.Start()",1,true))
			local last=assert(source:find("\nreturn CitizenService",first,true))
			local worker: (() -> ())?=nil
			local callbacks={};local activities=0;local errors=0;local life=0;local waits=0
			local env: any=setmetatable({
				CitizenService={},_running=false,_restoring=restoring,_accum=0,
				TRIP_TICK=.05,SIM_STEP=2,
				Pipe={activityViews={{bpId="home"}},activityById={home={bpId="home"}}},
				LOD={CONFIG={INTERVAL=.05}},
				RunService={Heartbeat={Connect=function(_,fn) table.insert(callbacks,fn);return {} end}},
				gameSpeed=function() return speed end,
				stepTrips=function() end,simStep=function() life+=1 end,
				doActivities=function(views,byId)
					assert(views[1].bpId=="home" and byId.home.bpId=="home")
					activities+=1
					if failFirst and activities==1 then error("injected activity failure") end
				end,
				warn=function(message) assert(tostring(message):find("injected activity failure",1,true));errors+=1 end,
			},{__index=getfenv()})
			env.task={
				spawn=function(fn) worker=fn;return {} end,
				wait=function(dt)
					assert(dt==.05,"scheduler must yield between bounded batches")
					waits+=1;if waits==8 then env._running=false end
				end,
			}
			local chunk=assert(loadstring(source:sub(first,last-1)))
			setfenv(chunk,env);chunk();env.CitizenService.Start();env.CitizenService.Start()
			assert(#callbacks==1,"Start must be idempotent")
			if worker then worker() end
			return {activities=activities,errors=errors,life=life,waits=waits}
		end
		it("activity progresses before the next census tick",function()
			local result=runWorker(6,false,false)
			expect(result.activities).to.equal(8);expect(result.life).to.equal(0);expect(result.waits).to.equal(8)
		end)
		it("paused cities schedule no new activities",function()
			local result=runWorker(0,false,false)
			expect(result.activities).to.equal(0);expect(result.waits).to.equal(8)
		end)
		it("restore suppresses activity until city state is ready",function()
			local result=runWorker(6,true,false)
			expect(result.activities).to.equal(0);expect(result.waits).to.equal(8)
		end)
		it("one household fault is logged and later batches still run",function()
			local result=runWorker(6,false,true)
			expect(result.activities).to.equal(8);expect(result.errors).to.equal(1)
		end)
	end)



	describe("Saved city trip arrival regression", function()
		local Columns = require(script.Parent.Parent.CitizenSaveColumns)
		local first = assert(source:find("local function resumeRestoredCar",1,true))
		local last = assert(source:find("-- City restore: budget",first,true))
		local restoreSource = source:sub(first,last-1)
		local function runSavedArrival(kind: string, broken: boolean): (boolean, string?)
			local folder=Instance.new("Folder")
			local model=Instance.new("Model");local root=Instance.new("Part")
			root.Anchored=true;root.Parent=model;model.PrimaryPart=root;model.Parent=folder
			local adult: any={pid=17,tripId=0,car=model,ownsCar=true}
			local household: any={id=1,homeId="home",adults={adult},kids={},goodsStock=0}
			local workers={};local income=0;local homeTrips=0;local arrival: (() -> ())?=nil
			local saved={h=1,a=1,k=0,e={1,0,0,0},j={},cv={{a=1,c={10,0,10,0},d=2,k=kind,ln="lane",ld=7}}}
			local encoded=game.HttpService:JSONEncode(Columns.toColumns({saved}))
			local rows=Columns.fromColumns(game.HttpService:JSONDecode(encoded))
			local actualJourneys=CitizenJourneys.new({
				workers=workers,driverJobs={},
				getBuildingService=function() return {getKerb=function() return Vector3.zero end} end,
				getSupplyService=function() return {consumeStock=function() return 2 end} end,
				getEconomyService=function() return {addRetailIncome=function(n: number) income+=n end} end,
			})
			local opts: any=nil
			local env: any=setmetatable({
				_households={[1]=household},ROADSIDE_RADIUS=30,CAR_HEIGHT=.6,
				journeys=actualJourneys,
				NPCDriverService={GetRestoreSeat=function(car,anchor) return car:GetPivot(),anchor.dist end},
				nav=function() return {NearestEdge=function() return {distance=0} end,GetEdge=function() return {} end} end,
				carDataToCFrame=function(c: any) return CFrame.new(c[1],c[2],c[3]) end,
				resolveSavedKey=function(keys: any,i: number) return keys[i] end,
				releaseSpot=function() end,
				Garage={fetch=function() end,stow=function() end},
				pickBuildingPark=function() return {cf=CFrame.new(50,0,50),lotEntry=Vector3.new(50,0,50)} end,
				isJobView=function(v: any) return v.zone=="Industrial" end,
				jobCapacity=function() return 1 end,
				returnHome=function() homeTrips+=1 end,
				driveTo=function(_,_,callback: () -> (),options: any) arrival=callback;opts=options end,
			},{__index=getfenv()})
			local body=restoreSource
			if broken then body=body:gsub("journeys%.applyForJob","applyForJob"):gsub("journeys%.doShopping","doShopping") end
			local fn=assert(loadstring(body.."\nreturn resumeRestoredCar"))
			setfenv(fn,env)
			local ok,err=pcall(function()
				fn()(household,rows[1].cv[1],{"homeKey","targetKey"},{targetKey={bpId="target",zone="Industrial",level=1}},{})
				assert(arrival and opts.onRoad==true and opts.startLane.edgeId=="lane" and opts.startLane.dist==7)
				local complete = assert(arrival)
				complete()
				assert(homeTrips==1,"arrival failed to schedule the return leg")
				if kind=="apply" then assert(adult.jobId=="target" and workers.target==1)
				else assert(income>0 and household.goodsStock==2) end
			end)
			folder:Destroy()
			return ok,if ok then nil else tostring(err)
		end
		for _,kind in {"apply","shop"} do
			it("JSON reload completes a "..kind.." arrival without a nil callback",function()
				local ok,err=runSavedArrival(kind,false)
				assert(ok,err)
			end)
			it("the regression fails when the original "..kind.." callback bug is reintroduced",function()
				local ok,err=runSavedArrival(kind,true)
				assert(not ok and err and err:find("attempt to call a nil value",1,true))
			end)
		end
	end)

	describe("Restored trip arrival operations", function()
		it("a restored job applicant can claim exactly one available job", function()
			local workers = {}
			local journeys = CitizenJourneys.new({
				workers = workers, driverJobs = {},
				getBuildingService = function() return {getKerb = function() return Vector3.zero end} end,
			})
			local adult: any = {joblessDays = 3}
			journeys.applyForJob({} :: any, adult, "factory", 1)
			expect(adult.jobId).to.equal("factory")
			expect(workers.factory).to.equal(1)
			journeys.applyForJob({} :: any, adult, "factory", 1)
			expect(workers.factory).to.equal(1)
		end)
		it("a restored shopping arrival buys available goods and credits retail once", function()
			local income = 0
			local stock = 2
			local journeys = CitizenJourneys.new({
				getBuildingService = function() return {getKerb = function() return Vector3.zero end} end,
				getSupplyService = function() return {consumeStock = function() local n=stock;stock=0;return n end} end,
				getEconomyService = function() return {addRetailIncome = function(n: number) income+=n end} end,
			})
			local household: any = {goods=0, adults={}, kids={}}
			journeys.doShopping(household, "shop")
			expect(income > 0).to.equal(true)
			local firstIncome = income
			journeys.doShopping(household, "shop")
			expect(income).to.equal(firstIncome)
		end)
	end)

	local first = assert(source:find("local function destroyCar", 1, true))
	local last = assert(source:find("\n-- == Building views", first, true))
	local accounting = ""
	local accountingStart = source:find("function Cars.releaseRoadSlot", 1, true)
	if accountingStart then
		local accountingEnd = assert(source:find("\nend", accountingStart, true))
		accounting = source:sub(accountingStart, accountingEnd + 4) .. "\n"
	end
	local resetStart = assert(source:find("local function clearRuntimeHouseholds", 1, true))
	local resetEnd = assert(source:find("\nfunction CitizenService.restore", resetStart, true))
	local trafficSource = accounting .. source:sub(first, last - 1) .. "\n" .. source:sub(resetStart, resetEnd - 1)
		.. "\nreturn {driveTo=driveTo, lineFollow=lineFollow, stepTrips=stepTrips, destroyCar=destroyCar, reset=clearRuntimeHouseholds}"
	local fixtures: {Model} = {}
	local folder: Folder

	local function harness(): any
		local env: any = setmetatable({
			CAR_HEIGHT = 0.6, CAR_SPEED = 12, MAX_TRIP_CARS = 1500, RESERVED_ARRIVAL_TRIPS = 6,
			DRIVE_RETRY_DELAY = 2, MAX_DRIVE_RETRIES = 30, MAX_ARRIVAL_RETRIES = 3,
			MAX_DRIVE_RETRY_DELAY = 30, TRIP_STALL_RESCUE = 12,
			Cars = {laneAsker = {}, MANEUVER_STALL_SECONDS = 20, GATE_STALL_SECONDS = 120, GAP_PATIENCE = 2, LOT_STANDOFF_SECONDS = 4, LOT_STANDOFF_CLEARANCE = .05, ACCESS_CLEAR_RADIUS = 12, GATE_MAX_WAIT = 15, ROAD_GATE_SETBACK = 16, GAP_SECONDS = 3, roadTokens = {}},
			_trips = {}, _tripCount = 0, _directedCount = 0, _carDriveTokens = {}, _carCount = 1,
			pending = {}, roads = {}, arrivalCount = 0, startCount = 0,
			_households = {}, _folder = folder, _stallTaken = {}, _travelDebugByPid = {}, _workers = {},
			_buildingService = {clearHouseholds = function() end}, Pipe = {entries = {}},
			Garage = {clear = function() end, stow = function(car) PathFollower.forget(car) end, fetch = function() end},
			gateClear = true, factor = 1, clearance = math.huge, hasPath = true,
			RoadRules={getLaneSideSign=function()return 1 end}, laneOrdinal=1, laneCount=1,
		}, {__index = getfenv()})
		env.PathFollower = {
			anyVehicleWithin = function() return false end,
			cumOf = PathFollower.cumOf, pointAtDist = PathFollower.pointAtDist,
			place = PathFollower.place, forget = PathFollower.forget, seedProximity = PathFollower.seedProximity,
			getSpeedFactor = function() return env.factor, nil end,
			getMotionLimits = function() return env.factor, env.clearance, nil, nil end,
		}
		env.task = {delay = function(delay: number, callback: () -> ())
			table.insert(env.pending, {delay = delay, callback = callback})
		end}
		env.DriverProfile = {fromModel = function() return {} end}
		local graph = {
			HasEdges = function() return true end,
			GetEdge = function()return {laneOrdinal=env.laneOrdinal,laneCountInDirection=env.laneCount}end,
			FindPath = function(_, from: Vector3, to: Vector3)
				if not env.hasPath then return nil end
				return {from, to}, {"A"}
			end,
		}
		env.nav = function() return graph end
		env.NPCDriverService = {
			GetLaneAnchor = function() return nil end,
			RequestRoadGap = function() end, ClearRoadGap = function() end,
			ReleaseDirected = function(model: Model)
				if not env.roads[model] then return false end
				env.roads[model] = nil
				return true
			end,
			LaneExitPoint = function(_, to: Vector3) return to end,
			LaneEntryPath = function(_, from: Vector3) return {from, from + Vector3.zAxis} end,
			RoadGapClear = function() return env.gateClear end,
			IsWaitingForVehicle = function() return false end,
			IsOnRoad = function() return false end,
			DriveDirected = function(model: Model, from: Vector3, to: Vector3, _route: {string}, arrive: () -> (), abort: () -> (), startDist: number?)
				env.startCount += 1
				env.roads[model] = {from = from, to = to, arrive = arrive, abort = abort, startDist=startDist}
				return true
			end,
		}
		local chunk = assert(loadstring(trafficSource, "CitizenTrafficFresh"))
		setfenv(chunk, env)
		env.api = chunk()
		local model = Instance.new("Model")
		model.Name = "CitizenTrafficFixture"
		model.Parent = folder
		local root = Instance.new("Part")
		root.Size = Vector3.new(2, 2, 5)
		root.Anchored = true
		root.Parent = model
		model.PrimaryPart = root
		table.insert(fixtures, model)
		env.car = model
		env.goal = CFrame.new(0, 0, 50)
		env.done = function() env.arrivalCount += 1 end
		env.retry = function()
			local item = table.remove(env.pending, 1)
			if item then item.callback() end
		end
		env.start = function(opts: any?)
			env.api.driveTo(model, env.goal, env.done, opts)
			env.api.stepTrips(0.2)
			assert(env.roads[model], "fixture did not reach its road leg")
		end
		return env
	end

	local function fixture(name: string, test: (any) -> ())
		it(name, function()
			folder = Instance.new("Folder")
			local h = harness()
			local ok, err = pcall(test, h)
			for _, model in fixtures do PathFollower.forget(model) end
			table.clear(fixtures)
			folder:Destroy()
			if not ok then error(err, 0) end
		end)
	end

	describe("Citizen traffic trip contract", function()
		fixture("separate parking entrances do not wait for the adjacent exit queue",function(h)
			h.PathFollower.anyVehicleWithin=function()return true end
			h.flatDist=function(a,b)return (a-b).Magnitude end
			h.start({toGraphPoint=Vector3.new(-20,0,30),exitGraphPoint=Vector3.new(-14,0,30)})
			h.roads[h.car].arrive()
			h.api.stepTrips(.1)
			assert(h._trips[h.car].dist>0,"separate entry waited on the exit lane")
		end)

		fixture("an arrival leaves the access clear for a garage departure",function(h)
			h.PathFollower.anyVehicleWithin=PathFollower.anyVehicleWithin
			h.goal=CFrame.new(-40,0,30);h.start({toGraphPoint=Vector3.new(-20,0,30)})
			h.car:PivotTo(CFrame.lookAt(Vector3.new(0,.6,30),Vector3.new(0,.6,31)))
			local exit=h.car:Clone();exit.Parent=folder;table.insert(fixtures,exit)
			local mouth=Vector3.new(-20,0,30)
			exit:PivotTo(CFrame.new(mouth))
			h.api.lineFollow(exit,{mouth,mouth+Vector3.new(0,0,40)},12,nil,0,nil,false)
			PathFollower.place({model=exit,heightOffset=0,replicateAccum=0},mouth,Vector3.zAxis)
			h.roads[h.car].arrive();h.api.stepTrips(.05)
			assert(h._trips[h.car].dist==0,"arrival entered the active garage exit")
			for _=1,400 do h.api.stepTrips(.05)end
			assert(h.arrivalCount==1,"arrival failed to resume after the exit cleared")
		end)

		fixture("a committed arrival clears the whole waiting exit queue",function(h)
			h.PathFollower.getMotionLimits=PathFollower.getMotionLimits
			for _,x in {10,20} do
				local exit=h.car:Clone();exit.Parent=folder;table.insert(fixtures,exit)
				exit:PivotTo(CFrame.lookAt(Vector3.new(x,0,0),Vector3.new(x-1,0,0)))
				h.api.lineFollow(exit,{Vector3.new(x,0,0),Vector3.new(-30,0,0)},12,nil,0,function()return false end,false,0)
				PathFollower.place({model=exit,heightOffset=0,replicateAccum=0},Vector3.new(x,0,0),-Vector3.xAxis)
			end
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,nil,true)
			for _=1,400 do h.api.stepTrips(.05) end
			assert(h.arrivalCount==1,"arrival remained locked across the exit queue")
		end)


		fixture("a departure from a raised parking pose never points vertically",function(h)
			h.car:PivotTo(CFrame.new(0,.6,0))
			h.api.driveTo(h.car,h.goal,h.done,{fromGraphPoint=Vector3.new(0,0,30),
				egress={Vector3.zero,Vector3.new(0,0,30)}})
			h.api.stepTrips(.01)
			assert(h._trips[h.car].smoothCFrame.UpVector.Y>.99,"departure pitched vertically at the bay")
			for _=1,400 do h.api.stepTrips(.05) end
			assert(h.startCount==1,"departure failed to reach the road")
		end)


		for _,third in {false,true} do
			fixture("real parking bodies clear a gate-waiting exit while retaining a third road blocker: "..tostring(third),function(h)
				h.PathFollower.getMotionLimits=PathFollower.getMotionLimits
				local exit=h.car:Clone();exit.Parent=folder;table.insert(fixtures,exit)
				h.api.lineFollow(exit,{Vector3.new(10,0,0),Vector3.new(-20,0,0)},12,h.done,0,function()return false end,false,0)
				PathFollower.place({model=exit,heightOffset=0,replicateAccum=0},Vector3.new(10,0,0),-Vector3.xAxis)
				PathFollower.place({model=h.car,heightOffset=0,replicateAccum=0},Vector3.zero,Vector3.xAxis)
				if third then
					local road=h.car:Clone();road.Parent=folder;table.insert(fixtures,road)
					PathFollower.place({model=road,heightOffset=0,replicateAccum=0},Vector3.new(30,0,0),-Vector3.xAxis)
				end
				h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,nil,true)
				for _=1,400 do h.api.stepTrips(.05)end
				expect(h.arrivalCount).to.equal(if third then 0 else 1)
				expect(h._trips[exit].dist).to.equal(0)
				if third then expect(h._trips[h.car].dist<25).to.equal(true)end
			end)
		end


		-- The car coming in off the road goes first (2026-10-05): it is the one holding up the
		-- street, and the departure it would wait for is itself waiting for a gap in that street.
		fixture("an arrival off the road has priority over a departure in an aisle standoff",function(h)
			local entry=h.car:Clone();entry.Parent=folder;table.insert(fixtures,entry)
			entry:PivotTo(CFrame.new(20,0,0))
			h.PathFollower.getMotionLimits=function(model,_,_,yielding,ignore)
				local blocker=if model==h.car then entry else h.car
				if yielding==blocker or (ignore and ignore(model,blocker)) then return 1,math.huge,nil,nil end
				return 0,0,-1,blocker
			end
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,nil,false)
			h.api.lineFollow(entry,{Vector3.new(20,0,0),Vector3.new(-20,0,0)},12,h.done,0,nil,true)
			h.api.stepTrips(.1)
			expect(h._trips[entry].dist>0).to.equal(true)
			expect(h._trips[h.car].dist).to.equal(0)
		end)
		fixture("a queued exit at its road gate cannot permanently block arriving lot traffic",function(h)
			local exit=h.car:Clone();exit.Parent=folder;table.insert(fixtures,exit)
			h.PathFollower.getMotionLimits=function(model,_,_,yielding,ignore)
				if model==exit or not h._trips[exit] or yielding==exit or (ignore and ignore(model,exit)) then return 1,math.huge,nil,nil end
				return 0,0,-1,exit
			end
			h.api.lineFollow(exit,{Vector3.new(10,0,0),Vector3.new(-20,0,0)},12,h.done,0,function()return false end,false,0)
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,nil,true)
			for _=1,200 do h.api.stepTrips(.1)end
			expect(h.arrivalCount).to.equal(1)
			expect(h._trips[exit].dist).to.equal(0)
		end)
		fixture("a lot departure waits at its mouth rather than inside the circulation aisle",function(h)
			h.gateClear=false
			h.api.driveTo(h.car,h.goal,h.done,{fromGraphPoint=Vector3.new(0,0,30),
				egress={Vector3.new(0,0,10),Vector3.new(0,0,30)}})
			for _=1,100 do h.api.stepTrips(.1)end
			expect((h._trips[h.car].smoothCFrame.Position-Vector3.new(0,.6,30)).Magnitude<.001).to.equal(true)
			expect(h.startCount).to.equal(0)
		end)

		fixture("a completed road trip pockets immediately without waiting for all traffic to clear",function(h)
			h.start({pocket=true})
			h.gateClear=false
			h.roads[h.car].arrive()
			expect(h.arrivalCount).to.equal(1);expect(h._tripCount).to.equal(0)
			expect(h._directedCount).to.equal(0)
		end)

		for _,case in {{side=1,x=-30,name="right-side"}, {side=-1,x=30,name="left-side"}} do
			fixture(case.name.." curb entry does not wait for unrelated road traffic",function(h)
				h.RoadRules={getLaneSideSign=function()return case.side end}
				h.goal=CFrame.new(case.x,0,30)
				h.start()
				h.car:PivotTo(CFrame.lookAt(Vector3.new(0,.6,30),Vector3.new(0,.6,31)))
				h.gateClear=false
				h.roads[h.car].arrive()
				for _=1,100 do h.api.stepTrips(.1) end
				expect(h.arrivalCount).to.equal(1)
			end)
		end
		fixture("a parking entry across opposing lanes still waits for a gap",function(h)
			h.goal=CFrame.new(30,0,30);h.start()
			h.car:PivotTo(CFrame.lookAt(Vector3.new(0,.6,30),Vector3.new(0,.6,31)))
			h.gateClear=false;h.roads[h.car].arrive()
			for _=1,100 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(0)
			h.gateClear=true
			for _=1,100 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(1)
		end)
		fixture("an inner-lane curb entry still yields to the outer lane",function(h)
			h.laneOrdinal=1;h.laneCount=2;h.goal=CFrame.new(-30,0,30);h.start()
			h.car:PivotTo(CFrame.lookAt(Vector3.new(0,.6,30),Vector3.new(0,.6,31)))
			h.gateClear=false;h.roads[h.car].arrive()
			for _=1,100 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(0)
		end)
		fixture("a curb entry still waits for a vehicle blocking its actual path",function(h)
			h.goal=CFrame.new(-30,0,30);h.start()
			h.car:PivotTo(CFrame.lookAt(Vector3.new(0,.6,30),Vector3.new(0,.6,31)))
			h.factor=0;h.clearance=0;h.roads[h.car].arrive()
			for _=1,100 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(0)
		end)
		fixture("a parking departure clears a road car that is waiting for that same departure",function(h)
			local blocker=h.car:Clone();blocker.Parent=folder;table.insert(fixtures,blocker)
			h.NPCDriverService.IsWaitingForVehicle=function(other,car) return other==blocker and car==h.car end
			h.PathFollower.getMotionLimits=function(_,_,_,ignored)
				if ignored==blocker then return 1,math.huge,nil,nil end
				return 0,0,0,blocker
			end
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(20,0,0)},12,h.done,0,nil,true)
			for _=1,200 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(1)
		end)
		fixture("a moving road car still blocks a parking departure",function(h)
			local blocker=h.car:Clone();blocker.Parent=folder;table.insert(fixtures,blocker)
			h.NPCDriverService.IsWaitingForVehicle=function() return false end
			h.PathFollower.getMotionLimits=function() return 0,0,0,blocker end
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(20,0,0)},12,h.done,0,nil,true)
			for _=1,200 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(0)
			expect(h._trips[h.car].dist).to.equal(0)
		end)
		fixture("a missing road route is hidden and unregistered while it waits for repair",function(h)
			h.hasPath=false
			local hidden=0
			h.Garage.stow=function(car) hidden+=1;PathFollower.forget(car) end
			PathFollower.place({model=h.car,heightOffset=0},Vector3.zero,Vector3.zAxis,0)
			h.api.driveTo(h.car,h.goal,h.done,{onRoad=true,startLane={edgeId="A",dist=0}})
			expect(hidden).to.equal(1)
			expect(PathFollower.isRegistered(h.car)).to.equal(false)
			expect(h.arrivalCount).to.equal(0)
		end)


		fixture("opposing parking maneuvers finish instead of permanently blocking each other",function(h)
			h.PathFollower.getMotionLimits=PathFollower.getMotionLimits
			local other=Instance.new("Model");local root=Instance.new("Part")
			root.Size=Vector3.new(2,2,5);root.Anchored=true;root.Parent=other;other.PrimaryPart=root;other.Parent=folder
			table.insert(fixtures,other)
			PathFollower.place({model=h.car,heightOffset=0,replicateAccum=0},Vector3.zero,Vector3.xAxis)
			PathFollower.place({model=other,heightOffset=0,replicateAccum=0},Vector3.new(20,0,0),-Vector3.xAxis)
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,nil,true)
			h.api.lineFollow(other,{Vector3.new(20,0,0),Vector3.new(-20,0,0)},12,h.done,0,nil,true)
			for _=1,400 do h.api.stepTrips(.05)end
			expect(h.arrivalCount).to.equal(2)
			expect(next(h._trips)).to.equal(nil)
		end)

		fixture("parking aisle opponents can pass before their future road-entry gates",function(h)
			h.PathFollower.getMotionLimits=PathFollower.getMotionLimits
			local other=Instance.new("Model");local root=Instance.new("Part")
			root.Size=Vector3.new(2,2,5);root.Anchored=true;root.Parent=other;other.PrimaryPart=root;other.Parent=folder
			table.insert(fixtures,other)
			PathFollower.place({model=h.car,heightOffset=0,replicateAccum=0},Vector3.zero,Vector3.xAxis)
			PathFollower.place({model=other,heightOffset=0,replicateAccum=0},Vector3.new(20,0,0),-Vector3.xAxis)
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,function() return true end,false,35)
			h.api.lineFollow(other,{Vector3.new(20,0,0),Vector3.new(-20,0,0)},12,h.done,0,function() return true end,false,35)
			for _=1,400 do h.api.stepTrips(.05)end
			expect(h.arrivalCount).to.equal(2)
			expect(next(h._trips)).to.equal(nil)
		end)



		fixture("parking queues never pass a same-direction leader after a timeout",function(h)
			local leader=h.car:Clone();leader.Parent=folder;table.insert(fixtures,leader)
			h.Cars.MANEUVER_STALL_SECONDS=20;h.Cars.LOT_STANDOFF_SECONDS=4
			h.api.lineFollow(leader,{Vector3.new(10,0,0),Vector3.new(40,0,0)},12,nil,0,nil,false)
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,nil,false)
			local first=assert(source:find("local function canPassLotManeuver(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn canPassLotManeuver"))
			setfenv(fn,h)
			expect(fn()(h.car,leader)).to.equal(false)
		end)

		fixture("three blocked lot manoeuvres clear a cyclic body-check dependency",function(h)
			local cars={h.car}
			for i=2,3 do
				local m=h.car:Clone();m.Parent=folder;table.insert(fixtures,m);table.insert(cars,m)
			end
			local blockers={[cars[1]]=cars[2],[cars[2]]=cars[3],[cars[3]]=cars[1]}
			h.Cars.MANEUVER_STALL_SECONDS=20;h.Cars.LOT_STANDOFF_SECONDS=4
			h.PathFollower.getMotionLimits=function(model,pos,dir,yielding,ignore)
				local blocker=blockers[model]
				if not h._trips[blocker] or (ignore and ignore(model,blocker)) then return 1,math.huge,nil,nil end
				return 0,0,0,blocker
			end
			for i,car in cars do
				local angle=(i-1)*math.pi*2/3
				local direction=Vector3.new(math.cos(angle),0,math.sin(angle))
				h.api.lineFollow(car,{-direction*10,direction*10},12,h.done,0,nil,true)
			end
			for _=1,200 do h.api.stepTrips(.1) end
			expect(h.arrivalCount).to.equal(3)
			expect(next(h._trips)).to.equal(nil)
		end)

		fixture("a hidden pocket car uses a safe lane seat without a driveway reversal",function(h)
			h.Garage.folder=h.car.Parent
			h.NPCDriverService.GetRestoreSeat=function()return CFrame.new(20,0,0),20 end
			h.api.driveTo(h.car,h.goal,h.done,{startLane={edgeId="lane",dist=100}})
			expect(h._tripCount).to.equal(0)
			expect(h.startCount).to.equal(1)
			expect(h.roads[h.car].startDist).to.equal(20)
		end)

		fixture("departure reservation releases only after road admission succeeds",function(h)
			local departed=0
			h.api.driveTo(h.car,h.goal,h.done,{onRoad=true,onDepart=function()departed+=1 end})
			expect(departed).to.equal(1)
			local road=h.roads[h.car]
			if road then road.arrive() end
			expect(departed).to.equal(1)
		end)

		fixture("a stranded gated maneuver leaves the road and retries without reporting arrival",function(h)
			h.Cars.MANEUVER_STALL_SECONDS=1;h.Cars.GATE_STALL_SECONDS=1
			local hidden,retried=0,0
			h.Garage.stow=function(car) hidden+=1;PathFollower.forget(car)end
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,function()return false end,true)
			h._trips[h.car].onBlocked=function()retried+=1 end
			for _=1,20 do h.api.stepTrips(.1)end
			expect(hidden).to.equal(1);expect(retried).to.equal(1)
			expect(h.arrivalCount).to.equal(0);expect(next(h._trips)).to.equal(nil)
		end)

		fixture("a car held at its road gate asks the traffic for a gap and withdraws it once in",function(h)
			local asked,cleared,open=0,0,false
			h.NPCDriverService.RequestRoadGap=function() asked+=1 end
			h.NPCDriverService.ClearRoadGap=function() cleared+=1 end
			h.api.lineFollow(h.car,{Vector3.zero,Vector3.new(40,0,0)},12,h.done,0,function()return open end,true)
			local trip=h._trips[h.car];trip.gapAt=Vector3.zero;trip.onBlocked=function()end
			for _=1,10 do h.api.stepTrips(.1)end
			expect(asked).to.equal(0) -- waits GAP_PATIENCE before asking
			for _=1,250 do h.api.stepTrips(.1)end
			expect(asked>0).to.equal(true)
			expect(h._trips[h.car]~=nil).to.equal(true) -- still queued at its gate past the old 20 s give-up
			open=true;h.api.stepTrips(.1)
			expect(cleared>0).to.equal(true)
		end)

		fixture("an aborted route does not grant destination arrival", function(h)
			h.start()
			local road = h.roads[h.car]
			local position = h.car:GetPivot().Position
			h.roads[h.car] = nil
			road.abort()
			expect(h.arrivalCount).to.equal(0)
			expect(h.car:GetPivot().Position).to.equal(position)
			expect(h._directedCount).to.equal(0)
			expect(#h.pending).to.equal(1)
		end)

		fixture("a missing route never completes a commute by timeout", function(h)
			h.hasPath = false
			h.api.driveTo(h.car, h.goal, h.done)
			for _ = 1, 40 do h.retry() end
			expect(h.arrivalCount).to.equal(0)
			expect(h.car:GetPivot().Position).to.equal(Vector3.zero)
			expect(#h.pending).to.equal(1)
		end)

		fixture("a missing move-in route also waits without teleporting", function(h)
			h.hasPath = false
			h.api.driveTo(h.car, h.goal, h.done, {isArrival = true})
			for _ = 1, 10 do h.retry() end
			expect(h.arrivalCount).to.equal(0)
			expect(h.car:GetPivot().Position).to.equal(Vector3.zero)
		end)

		fixture("a restored on-road car retains its lane distance and skips driveway admission", function(h)
			h.gateClear=false
			h.api.driveTo(h.car,h.goal,h.done,{onRoad=true,startLane={edgeId="lane",dist=7}})
			expect(h.startCount).to.equal(1)
			expect(h.roads[h.car].startDist).to.equal(7)
			expect(h._tripCount).to.equal(0)
		end)

		fixture("only one pocketed car per lane asks traffic for a gap, the next asks once it is in", function(h)
			local asks = {}
			h.NPCDriverService.RequestRoadGap = function(car) asks[car] = (asks[car] or 0) + 1 end
			h.gateClear = false
			local second = h.car:Clone(); second.Parent = h.car.Parent
			h.api.driveTo(h.car, h.goal, h.done, {onRoad=true, restorePending=true, startLane={edgeId="lane",dist=7}})
			h.api.driveTo(second, h.goal, h.done, {onRoad=true, restorePending=true, startLane={edgeId="lane",dist=30}})
			expect(asks[h.car]).to.equal(1); expect(asks[second]).to.equal(nil)
			h.gateClear = true; h.retry() -- the asker gets its gap and joins
			expect(h.startCount).to.equal(1)
			h.gateClear = false; h.retry() -- now the next one in line asks
			expect(asks[second]).to.equal(1)
		end)

		fixture("reload admission waits for an occupied saved road position without reporting arrival", function(h)
			h.gateClear=false
			h.Garage.fetch=function() h.fetched=(h.fetched or 0)+1 end
			h.api.driveTo(h.car,h.goal,h.done,{onRoad=true,restorePending=true,startLane={edgeId="lane",dist=7}})
			for _=1,8 do h.retry() end
			expect(h.startCount).to.equal(0); expect(h.arrivalCount).to.equal(0)
			h.gateClear=true; h.retry()
			expect(h.startCount).to.equal(1); expect(h.roads[h.car].startDist).to.equal(7)
			expect(h.fetched).to.equal(1)
		end)

		fixture("a driveway rechecks a lost road gap at the kerb", function(h)
			h.gateClear = true
			h.api.lineFollow(h.car, {Vector3.zero, Vector3.new(0,0,40)}, 12, h.done, 0,
				function() return h.gateClear end, false, 20)
			h.api.stepTrips(1)
			h.gateClear = false
			h.api.stepTrips(1)
			for _=1,10 do h.api.stepTrips(1) end
			expect(h.car:GetPivot().Position).to.equal(Vector3.new(0,0,20))
			expect(h.arrivalCount).to.equal(0)
			h.gateClear = true
			for _=1,10 do h.api.stepTrips(1) end
			expect(h.arrivalCount).to.equal(1)
		end)

		fixture("a driveway gate stays closed after its former timeout", function(h)
			h.gateClear = false
			h.api.lineFollow(h.car, {Vector3.zero, Vector3.new(0, 0, 20)}, 12, h.done, 0,
				function() return h.gateClear end)
			for _ = 1, 60 do h.api.stepTrips(0.5) end
			expect(h.arrivalCount).to.equal(0)
			expect(h.car:GetPivot().Position).to.equal(Vector3.zero)
		end)

		for _, leavesRoad in {true, false} do
			fixture("a blocked lot leg keeps its position: leavesRoad=" .. tostring(leavesRoad), function(h)
				h.factor = 0
				h.clearance = 0
				h.api.lineFollow(h.car, {Vector3.zero, Vector3.new(0, 0, 20)}, 12, h.done, 0, nil, leavesRoad)
				for _ = 1, 60 do h.api.stepTrips(0.5) end
				expect(h.arrivalCount).to.equal(0)
				expect(h.car:GetPivot().Position).to.equal(Vector3.zero)
			end)
		end

		fixture("a long tick cannot overshoot the safe bumper clearance", function(h)
			h.clearance = 1
			h.api.lineFollow(h.car, {Vector3.zero, Vector3.new(0, 0, 100)}, 12, nil, 0)
			h.api.stepTrips(1)
			expect(h.car:GetPivot().Position).to.equal(Vector3.new(0, 0, 1))
		end)

		fixture("normal road and parking arrival fires once and releases both counters", function(h)
			h.start()
			local road = h.roads[h.car]
			h.roads[h.car] = nil
			h.car:PivotTo(CFrame.new(road.to + Vector3.new(0, 0.6, 0)))
			road.arrive()
			for _ = 1, 10 do h.api.stepTrips(0.2) end
			expect(h.arrivalCount).to.equal(1)
			expect(h._directedCount).to.equal(0)
			expect(h._tripCount).to.equal(0)
			expect(h.car:GetPivot().Position).to.equal(h.goal.Position)
		end)

		fixture("a stale abort cannot steal the new road trip counter", function(h)
			h.start()
			local old = h.roads[h.car]
			h.start()
			old.abort()
			expect(h._directedCount).to.equal(1)
			expect(h.arrivalCount).to.equal(0)
			expect(#h.pending).to.equal(0)
		end)

		fixture("a completed driver with a pending old callback cannot leak a road slot", function(h)
			h.start()
			local old = h.roads[h.car]
			h.roads[h.car] = nil
			h.start()
			old.abort()
			expect(h._directedCount).to.equal(1)
			expect(h.arrivalCount).to.equal(0)
		end)

		fixture("destroying a car settles a pending road completion exactly once", function(h)
			h.start()
			local old = h.roads[h.car]
			h.roads[h.car] = nil
			h.api.destroyCar(h.car)
			old.arrive()
			expect(h._directedCount).to.equal(0)
			expect(h.arrivalCount).to.equal(0)
		end)

		fixture("an aborted car is removed from road occupancy while its real trip waits to retry", function(h)
			h.start()
			local old = h.roads[h.car]
			h.roads[h.car] = nil
			PathFollower.forget(h.car)
			old.abort()
			expect(PathFollower.isRegistered(h.car)).to.equal(false)
			expect(h.arrivalCount).to.equal(0)
		end)

		fixture("city reset prevents old completions changing the next city's road count", function(h)
			h.start()
			local old = h.roads[h.car]
			local replacement = h.car:Clone()
			table.insert(fixtures, replacement)
			h.api.reset()
			expect(next(h.Cars.roadTokens)).to.equal(nil)
			replacement.Parent = folder
			h.api.driveTo(replacement, h.goal, h.done)
			h.api.stepTrips(0.2)
			old.arrive()
			expect(h._directedCount).to.equal(1)
			expect(h.arrivalCount).to.equal(0)
		end)

		fixture("an invalidated road trip settles its ownership without retrying", function(h)
			local valid = true
			h.start({isValid = function() return valid end})
			local old = h.roads[h.car]
			h.roads[h.car] = nil
			valid = false
			old.abort()
			expect(h._directedCount).to.equal(0)
			expect(next(h.Cars.roadTokens)).to.equal(nil)
			expect(#h.pending).to.equal(0)
		end)

		fixture("an on-road retry waits outside road occupancy until the lane admission gate opens", function(h)
			h.start()
			local old = h.roads[h.car]
			h.roads[h.car] = nil
			PathFollower.forget(h.car)
			old.abort()
			h.gateClear = false
			h.retry()
			expect(h.startCount).to.equal(1)
			expect(PathFollower.isRegistered(h.car)).to.equal(false)
			expect(h.arrivalCount).to.equal(0)
			h.gateClear=true;h.retry()
			expect(h.startCount).to.equal(2)
		end)

		fixture("an invalidated retry does not restart a canceled trip", function(h)
			local valid = true
			h.hasPath = false
			h.api.driveTo(h.car, h.goal, h.done, {isValid = function() return valid end})
			valid = false
			h.hasPath = true
			h.retry()
			expect(h.startCount).to.equal(0)
			expect(h._tripCount).to.equal(0)
			expect(#h.pending).to.equal(0)
		end)

		fixture("a trip continues when its road becomes available", function(h)
			h.hasPath = false
			h.api.driveTo(h.car, h.goal, h.done)
			for _ = 1, 40 do h.retry() end
			h.hasPath = true
			h.retry()
			h.api.stepTrips(0.2)
			expect(h.startCount).to.equal(1)
			expect(h.arrivalCount).to.equal(0)
		end)

		fixture("a destroyed off-road vehicle releases its trip slot", function(h)
			h.api.lineFollow(h.car, {Vector3.zero, Vector3.new(0, 0, 20)}, 12, h.done, 0)
			h.car:Destroy()
			h.api.stepTrips(0.2)
			expect(h._tripCount).to.equal(0)
			expect(h.arrivalCount).to.equal(0)
		end)
	end)

	describe("Citizen pedestrian visibility", function()
		local function walkingHarness(): any
			local env: any = setmetatable({
				Cars = {}, spawned = 0, arrived = 0, callbacks = {},
				_households = {}, _folder = nil,
			}, {__index = getfenv()})
			env.Cars.rides = function(a: any) return a.pid % 2 ~= 0 end
			env._walkingService = {spawnCommuter = function(_from: any, _to: any, done: () -> ())
				env.spawned += 1
				table.insert(env.callbacks, done)
				return env.spawned
			end}
			env.personLabel = function() return "Test resident" end
			env.chooseTravelMode = function() return "walk", nil end
			local walkStart = assert(source:find("function Cars.walk(", 1, true))
			local walkEnd = assert(source:find("\nfunction Garage.stow", walkStart, true))
			local chunk = assert(loadstring(source:sub(walkStart, walkEnd - 1)))
			setfenv(chunk, env)
			chunk()
			env.journey = CitizenJourneys.new({
				getHouseholds = function() return env._households end,
				getWalkingService = function() return env._walkingService end,
				getTransitService = function() return nil end,
				getBuildingService = function() return nil end,
				getEducationService = function() return nil end,
				getSupplyService = function() return nil end,
				getEconomyService = function() return nil end,
				getFolder = function() return env._folder end,
				trips = {}, workers = {}, driverJobs = {}, cars = env.Cars, garage = {},
				personLabel = env.personLabel, kidLabel = env.personLabel,
				chooseTravelMode = env.chooseTravelMode,
				door = function() return nil end, flatDist = function() return 1 end,
				nav = function() return nil end, driveTo = function() end, releaseSpot = function() end,
				pickHomePark = function() return nil end, pickBuildingPark = function() return nil end,
				isSchoolAge = function() return true end, serviceKerb = function() return nil end,
			}).journey
			return env
		end

		it("every student gets a sidewalk trip irrespective of car group", function()
			local h = walkingHarness()
			for pid = 1, 8 do
				h.Cars.walk(pid, Vector3.zero, Vector3.zAxis, function() return false end,
					function() h.arrived += 1 end, "Student", {})
			end
			expect(h.spawned).to.equal(8)
			expect(h.arrived).to.equal(0)
			for _, done in h.callbacks do done() end
			expect(h.arrived).to.equal(8)
		end)

		it("a canceled school walk cannot complete its old trip", function()
			local h = walkingHarness()
			local stale = false
			h.Cars.walk(1, Vector3.zero, Vector3.zAxis, function() return stale end,
				function() h.arrived += 1 end, "Student", {})
			stale = true
			h.callbacks[1]()
			expect(h.arrived).to.equal(0)
		end)

		it("a car-sharing adult still gets a body when choosing to walk", function()
			local h = walkingHarness()
			local household = {id = 1}
			local adult = {pid = 1, age = 40, tripId = 1, gender = "M"}
			h._households[1] = household
			h.journey(household, adult, 1, Vector3.zero, Vector3.zAxis, false, nil,
				function() h.arrived += 1 end)
			expect(h.spawned).to.equal(1)
			expect(h.arrived).to.equal(0)
			h.callbacks[1]()
			expect(h.arrived).to.equal(1)
		end)
	end)


	describe("Resident commute persistence", function()
		local function restoreHarness(): any
			local env: any = setmetatable({
				Cars = {pinLane=function() return nil end}, ROADSIDE_RADIUS = 350, distance = 0, created = 0, driven = 0,
				_households = {}, _trips = {}, Workspace = workspace,
			}, {__index = getfenv()})
			env.carDataToCFrame = function(data: any) return CFrame.new(table.unpack(data)) end
			env.resolveSavedKey = function() return "work" end
			env.nav = function() return {NearestEdge = function() return {distance = env.distance} end} end
			env.newCar = function()
				env.created += 1
				local car = Instance.new("Model")
				local root = Instance.new("Part")
				root.Anchored = true
				root.Parent = car
				car.PrimaryPart = root
				env.car = car
				return car
			end
			env.claimDriveway = function() return nil, nil end
			env.releaseSpot = function() end
			env.Garage = {fetch = function() end, stow = function() end}
			env.pickHomePark = function() return {cf = CFrame.new(10, 0, 10)} end
			env.pickBuildingPark = env.pickHomePark
			env.driveTo = function() env.driven += 1 end
			env.warn = function() end
			local first = assert(source:find("local function resumeRestoredCar", 1, true))
			local last = assert(source:find("\n-- City restore", first, true))
			local chunk = assert(loadstring(source:sub(first, last - 1) .. "\nreturn resumeRestoredCar"))
			setfenv(chunk, env)
			env.resume = chunk()
			env.adult = {pid = 1, tripId = 1, stage = "transit", usingCar = true}
			env.home = {id = 1, homeId = "home", adults = {env.adult}}
			return env
		end
		it("an old origin trip far from roads restarts at home", function()
			local h = restoreHarness()
			h.distance = 2000
			h.resume(h.home, {a = 1, c = {0, 0, 0}, hm = true}, {}, {}, {})
			expect(h.adult.stage).to.equal("atHome")
			expect(h.adult.usingCar).to.equal(false)
			expect(h.created).to.equal(0)
			expect(h.driven).to.equal(0)
		end)
		it("a legitimate origin trip remains valid when the city is at the origin", function()
			local h = restoreHarness()
			h.resume(h.home, {a = 1, c = {0, 0, 0}, hm = true}, {}, {}, {})
			expect(h.driven).to.equal(1)
			expect(h.adult.stage).to.equal("transit")
			h.car:Destroy()
		end)
		it("a non-finite saved trip cannot reach routing", function()
			local h = restoreHarness()
			h.resume(h.home, {a = 1, c = {math.huge, 0, 0}, hm = true}, {}, {}, {})
			expect(h.driven).to.equal(0)
			expect(h.adult.stage).to.equal("atHome")
		end)
		it("a restore waiting for space survives serialization with its lane and distance", function()
			local car=Instance.new("Model");local root=Instance.new("Part")
			root.Parent=car;car.PrimaryPart=root
			local folder=Instance.new("Folder");car.Parent=folder
			car:PivotTo(CFrame.new(10,0,20))
			car:SetAttribute("RestorePending",true)
			car:SetAttribute("RestoreEdge","lane");car:SetAttribute("RestoreDist",7)
			local env: any=setmetatable({
				Workspace=workspace,_trips={},
				NPCDriverService={IsDirected=function() return false end,GetLivePose=function()return nil end,GetLaneAnchor=function()return nil end},
				cframeToCarData=function(cf) return {cf.Position.X,cf.Position.Y,cf.Position.Z,0} end,
			},{__index=getfenv()})
			local first=assert(source:find("local function activeCarState",1,true))
			local last=assert(source:find("\nfunction Pipe.activityPosition",first,true))
			local chunk=assert(loadstring(source:sub(first,last-1).."\nreturn activeCarState"));setfenv(chunk,env)
			local record=chunk()({homeId="home",adults={{car=car,stage="transit",usingCar=true,tripTargetHome=true}}},1,{},function()return 1 end,1)
			assert(record,"pending real trip was discarded")
			local Columns=require(script.Parent.Parent.CitizenSaveColumns)
			local rows=Columns.fromColumns(game.HttpService:JSONDecode(game.HttpService:JSONEncode(Columns.toColumns({
				{h=1,a=1,k=0,e={1,0,0,0},j={},cv={record}}
			}))))
			expect(rows[1].cv[1].ln).to.equal("lane");expect(rows[1].cv[1].ld).to.equal(7)
			expect(rows[1].cv[1].c[3]).to.equal(20)
			folder:Destroy()
		end)

		it("a hidden timer car is never saved as a real active commute", function()
			local car = Instance.new("Model")
			local folder = Instance.new("Folder")
			car.Parent = folder
			local env: any = setmetatable({
				Workspace = workspace, _trips = {},
				NPCDriverService = {IsDirected = function() return false end},
			}, {__index = getfenv()})
			local first = assert(source:find("local function activeCarState", 1, true))
			local last = assert(source:find("\nfunction Pipe.activityPosition", first, true))
			local chunk = assert(loadstring(source:sub(first, last - 1) .. "\nreturn activeCarState"))
			setfenv(chunk, env)
			local active = chunk()
			local result = active({adults = {{car = car, stage = "transit", usingCar = true}}}, 1, {}, function() return 1 end, 1)
			expect(result).to.equal(nil)
			folder:Destroy()
		end)
	end)


	describe("Industrial workforce coverage", function()
		it("factory schedules differ while day, evening and night crews stay stable across reload dates", function()
			local first = assert(source:find("local function idHash", 1, true))
			local last = assert(source:find("local function householdShiftOffsetHours", first, true))
			local chunk = assert(loadstring(source:sub(first, last - 1) .. "\nreturn shiftHours"))
			local shifts = chunk()
			local rotating, fixed = 0, 0
			for i = 1, 20 do
				local factory = {bpId = "factory" .. i, zone = "Industrial"}
				local a = shifts(factory, 1, 0)
				local b = shifts(factory, 1, 7)
				expect(b).to.equal(a)
				if a % 8 == 0 then fixed += 1 else rotating += 1 end
			end
			expect(rotating > 0 and fixed > 0).to.equal(true)
		end)
		it("three crews cover every hour without an empty night shift", function()
			local first = assert(source:find("local function idHash", 1, true))
			local last = assert(source:find("local function householdShiftOffsetHours", first, true))
			local chunk = assert(loadstring(source:sub(first, last - 1) .. "\nreturn shiftHours"))
			local shifts = chunk()
			for hour = 0, 23 do
				local working = 0
				for pid = 1, 3 do
					local startHour, endHour = shifts({bpId = "factory", zone = "Industrial"}, pid)
					if (hour - startHour) % 24 < endHour - startHour then working += 1 end
				end
				expect(working).to.equal(1)
			end
		end)
	end)

	describe("Restored parking", function()
		local function parkingHarness(): any
			local folder = Instance.new("Folder")
			local garage = Instance.new("Folder")
			local model = Instance.new("Model")
			local root = Instance.new("Part")
			root.Anchored = true
			root.Parent = model
			model.PrimaryPart = root
			model.Parent = garage
			local env: any = setmetatable({Cars = {}, home = nil, workplace = nil}, {__index = getfenv()})
			env.newCar = function() return model end
			env.Garage = {
				stow = function(car: Model) car.Parent = garage end,
				fetch = function(car: Model) car.Parent = folder end,
			}
			env.Cars.rides = function() return false end
			env.Cars.notePocket = function() end
			env.claimDriveway = function() return nil, nil end
			env._parkingService = {reserveNearest = function() return nil, nil end}
			env.pickHomePark = function() return env.home end
			env.pickBuildingPark = function() return env.workplace end
			local first = assert(source:find("function Cars.give(", 1, true))
			local last = assert(source:find("\nend", first, true))
			local chunk = assert(loadstring(source:sub(first, last + 4)))
			setfenv(chunk, env)
			chunk()
			env.car, env.visible = model, folder
			env.cleanup = function() folder:Destroy(); garage:Destroy() end
			return env
		end

		it("an unplaced car stays hidden instead of becoming a saved origin car", function()
			local h = parkingHarness()
			local ok, err = pcall(function()
				h.Cars.give({id = 1, homeId = "home"}, {}, nil, false)
				expect(h.car.Parent == h.visible).to.equal(false)
			end)
			h.cleanup()
			if not ok then error(err, 0) end
		end)

		it("an obsolete workplace pose resolves to a reserved current stall", function()
			local h = parkingHarness()
			local ok, err = pcall(function()
				h.workplace = {cf = CFrame.new(100, 2, 100), stallKey = "work#1"}
				local adult: any = {outDestId = "work"}
				h.Cars.give({id = 1, homeId = "home"}, adult, CFrame.new(), true)
				expect(h.car:GetPivot().Position).to.equal(h.workplace.cf.Position)
				expect(h.car.Parent).to.equal(h.visible)
				expect(adult.parkStallKey).to.equal("work#1")
			end)
			h.cleanup()
			if not ok then error(err, 0) end
		end)
	end)
	describe("Parked cars on bulldozed ground (2026-10-04)",function()
		it("pockets a car whose stall, bay or home is gone and keeps one still in its bay",function()
			local source=script.Parent.Source
			local first=assert(source:find("function Cars.sweepOrphans(",1,true))
			local last=assert(source:find("\nend\n",first,true))
			-- Model.Parent and attributes are routed through plain tables so no instance is touched.
			local chunk=source:sub(first,last+4):gsub("car%.Parent ~= _folder","parentOf(car) ~= _folder")
				:gsub('car:GetAttribute%("DriveRetryPending"%)',"false"):gsub("car:GetPivot%(%)%.Position","Vector3.zero")
			local folder,pocket,parent={},{},{}
			local cars={}
			for _,name in {"lot","bay","reissued","gone","home","homeless"} do
				cars[name]={Name=name};parent[cars[name]]=folder
			end
			local adults={
				{car=cars.lot,parkStallKey="bpGone#2"},
				{car=cars.bay,parkSpotId="bay-live"},
				{car=cars.reissued,parkSpotId="bay-old"},
				{car=cars.gone,parkSpotId="bay-removed"},
				{car=cars.home},
			}
			local homeless={car=cars.homeless,driveKey="homeGone#drive"}
			local nextClaim:string?="bay-new" -- the reissued bay is still under the first car that asks
			local env=setmetatable({
				Cars={},_folder=folder,_trips={},
				_households={{homeId="homeLive",adults=adults},{homeId="homeGone",adults={homeless}}},
				NPCDriverService={IsDirected=function()return false end},
				_parkingService={exists=function(id)return id=="bay-live" end,
					claimAt=function()local id=nextClaim;nextClaim=nil;return id end},
				releaseSpot=function(a)a.parkSpotId=nil;a.parkStallKey=nil end,
				releaseDriveway=function(a)a.driveKey=nil end,
				Garage={stow=function(m)pocket[m]=true;parent[m]=nil end},
				parentOf=function(m)return parent[m] end,
			},{__index=getfenv()})
			local fn=assert(loadstring(chunk));setfenv(fn,env);fn()
			env.Cars.sweepOrphans({bpLive=true,homeLive=true})
			expect(pocket[cars.lot]).to.equal(true)        -- its building was bulldozed
			expect(pocket[cars.bay]).to.equal(nil)         -- its bay still stands
			expect(pocket[cars.reissued]).to.equal(nil)    -- bay id reissued, re-claimed by position
			expect(adults[3].parkSpotId).to.equal("bay-new")
			expect(pocket[cars.gone]).to.equal(true)       -- its road/lot was bulldozed
			expect(pocket[cars.home]).to.equal(nil)        -- home driveway, home still there
			expect(pocket[cars.homeless]).to.equal(true)   -- driveway of a demolished home
			expect(homeless.driveKey).to.equal(nil)
		end)
	end)
	describe("No space near home, no car (2026-10-04)",function()
		local function give(choice:any):any
			local first=assert(source:find("function Cars.give(",1,true))
			local last=assert(source:find("\nend\n",first,true))
			local r={made=0,stowed=0,fetched=0,noted=0}
			local env=setmetatable({
				Cars={notePocket=function()r.noted+=1 end},
				claimDriveway=function()return nil,nil end,
				pickHomePark=function()return choice end,
				pickBuildingPark=function()return nil end,
				_parkingService={reserveNearest=function()return nil end,release=function()end},
				_stallTaken={},
				newCar=function()r.made+=1;return {PivotTo=function()end} end,
				Garage={stow=function()r.stowed+=1 end,fetch=function()r.fetched+=1 end},
			},{__index=getfenv()})
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			local a:any={}
			env.Cars.give({id=1,homeId="home"},a)
			r.hasCar=a.car~=nil
			return r
		end
		it("gets no car when the only place to leave it is the kerb-side pocket",function()
			local r=give({cf=CFrame.new(),pocket=true})
			expect(r.made).to.equal(0);expect(r.hasCar).to.equal(false);expect(r.noted).to.equal(1)
		end)
		it("still keeps a car in a block's own garage",function()
			local r=give({cf=CFrame.new(),pocket=true,garage=true})
			expect(r.hasCar).to.equal(true);expect(r.stowed).to.equal(1)
		end)
		it("keeps a car with a real space near home",function()
			local r=give({cf=CFrame.new(),spotId="bay"})
			expect(r.hasCar).to.equal(true);expect(r.fetched).to.equal(1)
		end)
	end)
	describe("Short parking sends drivers elsewhere (2026-10-04)",function()
		local function extract(name:string):string
			local first=assert(source:find(name,1,true),name)
			local last=assert(source:find("\nend\n",first,true))
			return source:sub(first,last+4)
		end
		it("a car owner redraws a shop with no space, a walker keeps the first draw",function()
			local draws={"noPark","park"}
			local env=setmetatable({
				Trips={PARK_REDRAWS=3,pickNear=function()return table.remove(draws,1) or "last" end},
				door=function(id)return Vector3.new(#id,0,0) end,
				Cars={parkWalk=function(_,_,id)return if id=="noPark" then nil else 5 end},
			},{__index=getfenv()})
			local fn=assert(loadstring(extract("function Trips.pickShop(")));setfenv(fn,env);fn()
			expect(env.Trips.pickShop({homeId="h"},{car={}},{},2)).to.equal("park")
			draws={"noPark","park"}
			expect(env.Trips.pickShop({homeId="h"},{},{},2)).to.equal("noPark")
		end)
		it("no space at a shop means no drive there, but home still counts its kerb",function()
			local env=setmetatable({
				Cars={roadStop=function()return {cf=CFrame.new(3,0,0),pocket=true} end},
				_parkingService={distanceToFree=function()return nil end},
				_buildingService={getParkSpots=function()return nil end,getKerb=function()return Vector3.zero end},
				_stallTaken={},Garage={home=function()return nil end},
				flatDist=function(p,q)return (Vector3.new(p.X,0,p.Z)-Vector3.new(q.X,0,q.Z)).Magnitude end,
				ROADSIDE_RADIUS=100,
			},{__index=getfenv()})
			local fn=assert(loadstring(extract("function Cars.parkWalk(")));setfenv(fn,env);fn()
			local h,a={homeId="home"},{}
			expect(env.Cars.parkWalk(h,a,"shop",Vector3.zero)).to.equal(nil)
			expect(env.Cars.parkWalk(h,a,"home",Vector3.zero)).to.equal(3)
		end)
	end)

	describe("No walk resumed on load (2026-10-05)",function()
		it("sends whoever was out on foot home and plans no walk, but keeps drivers on the road",function()
			local walks=0
			local env: any=setmetatable({
				Pipe={},door=function() return Vector3.zero end,Cars={give=function() end},
				CitizenActivityState={position=function() return nil end},
				journey=function() walks+=1 end,
				_walkingService={spawnCommuter=function() walks+=1;return 1 end},
			},{__index=getfenv()})
			local first=assert(source:find("function Pipe.resumeActivities(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			local walker: any={stage="transit",usingCar=false,outKind="work",outDestId="office",tripTargetId="office",tripTargetHome=false,tripId=4}
			local driver: any={stage="transit",usingCar=true,outKind="work",tripId=2}
			local kid: any={stage="transit",tripId=1}
			env.Pipe.resumeActivities({homeId="home",adults={walker,driver},kids={kid}},{rs={{},{}},ks={{}}})
			expect(walks).to.equal(0)
			expect(walker.stage).to.equal("atHome")
			expect(walker.outKind).to.equal(nil)
			expect(walker.outDestId).to.equal(nil)
			expect(driver.stage).to.equal("transit")
			expect(kid.stage).to.equal("atHome")
		end)
	end)
end
