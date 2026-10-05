--!strict
-- TestEZ contract scenarios. The fresh-source fixture never starts the city or writes a save.
return function()
	local driverModule = script.Parent

	it("saved-city admissions keep approaching traffic, body space and intersection setbacks",function()
		local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end

local Serializer=fresh(game.ServerScriptService.Services.Road.RoadSerializer)
local rows=game.HttpService:JSONDecode([==[[{"i":108,"p":[-4096,15.300000190734863,-213.1999969482422,-3900,14.100000381469727,-204.3000030517578,14.800000190734863,14.5],"t":"Highway4"},{"i":109,"p":[-3900,14.100000381469727,-204.3000030517578,-3704.10009765625,13.399999618530273,-195.5,13.800000190734863,13.600000381469727],"t":"Highway4"},{"i":110,"p":[-3704.10009765625,13.399999618530273,-195.5,-3508.10009765625,13.100000381469727,-186.60000610351562,13.300000190734863,13.100000381469727],"t":"Highway4"},{"i":111,"p":[-3508.10009765625,13.100000381469727,-186.60000610351562,-3312.10009765625,12.899999618530273,-177.6999969482422,13,12.899999618530273],"t":"Highway4"},{"i":112,"p":[-3312.10009765625,12.899999618530273,-177.6999969482422,-3116.10009765625,13,-168.8000030517578,12.899999618530273,12.899999618530273],"t":"Highway4"},{"i":113,"p":[-3116.10009765625,13,-168.8000030517578,-2920.10009765625,13,-159.89999389648438,13,13],"t":"Highway4"},{"i":114,"p":[-2920.10009765625,13,-159.89999389648438,-2724.10009765625,13.100000381469727,-151,13.100000381469727,13.100000381469727],"t":"Highway4"},{"i":115,"p":[-2724.10009765625,13.100000381469727,-151,-2528.199951171875,13.100000381469727,-142.1999969482422,13.100000381469727,13.100000381469727],"t":"Highway4"},{"i":43,"p":[-2706.199951171875,14.600000381469727,599.7999877929688,-2545.39990234375,13.300000190734863,610.2000122070312,14.199999809265137,13.800000190734863],"t":"NarrowRoad"},{"i":42,"p":[-2696.60009765625,14.600000381469727,450.79998779296875,-2706.199951171875,14.600000381469727,599.7999877929688,14.300000190734863,14.100000381469727],"t":"NarrowRoad"},{"i":41,"p":[-2687,15.100000381469727,301.70001220703125,-2696.60009765625,14.600000381469727,450.79998779296875,15.199999809265137,14.899999618530273],"t":"NarrowRoad"},{"i":40,"p":[-2677.5,13.899999618530273,152.6999969482422,-2687,15.100000381469727,301.70001220703125,14.300000190734863,14.699999809265137],"t":"NarrowRoad"},{"i":44,"p":[-2545.39990234375,13.300000190734863,610.2000122070312,-2466.199951171875,14.5,615.2999877929688,13.699999809265137,14.100000381469727],"t":"NarrowRoad"},{"i":54,"p":[-2537.5,16.200000762939453,461.1000061035156,-2696.60009765625,14.600000381469727,450.79998779296875,15.699999809265137,15.100000381469727],"t":"NarrowRoad"},{"i":51,"p":[-2529.60009765625,15.5,311.79998779296875,-2687,15.100000381469727,301.70001220703125,15.399999618530273,15.199999809265137],"t":"NarrowRoad"},{"i":116,"p":[-2528.199951171875,13.100000381469727,-142.1999969482422,-2332.199951171875,12.800000190734863,-133.3000030517578,13,12.899999618530273],"t":"Highway4"},{"i":39,"p":[-2521.699951171875,14.899999618530273,162.6999969482422,-2677.5,13.899999618530273,152.6999969482422,14.699999809265137,14.399999618530273],"t":"NarrowRoad"},{"i":60,"p":[-2466.199951171875,14.5,615.2999877929688,-2384.699951171875,15.800000190734863,620.5999755859375,15,15.399999618530273],"t":"NarrowRoad"},{"i":58,"p":[-2456.60009765625,16.600000381469727,466.29998779296875,-2537.5,16.200000762939453,461.1000061035156,16.600000381469727,16.399999618530273],"t":"NarrowRoad"},{"i":61,"p":[-2456.60009765625,16.600000381469727,466.29998779296875,-2466.199951171875,14.5,615.2999877929688,15.899999618530273,15.199999809265137],"t":"NarrowRoad"},{"i":56,"p":[-2447,16.100000381469727,317.20001220703125,-2529.60009765625,15.5,311.79998779296875,16,15.800000190734863],"t":"NarrowRoad"},{"i":59,"p":[-2447,16.100000381469727,317.20001220703125,-2456.60009765625,16.600000381469727,466.29998779296875,16.299999237060547,16.5],"t":"NarrowRoad"},{"i":55,"p":[-2437.39990234375,15,168.1999969482422,-2521.699951171875,14.899999618530273,162.6999969482422,15,14.899999618530273],"t":"NarrowRoad"},{"i":57,"p":[-2437.39990234375,15,168.1999969482422,-2447,16.100000381469727,317.20001220703125,15.399999618530273,15.800000190734863],"t":"NarrowRoad"},{"i":148,"p":[-2426.89990234375,12.800000190734863,7.300000190734863,-2437.39990234375,15,168.1999969482422,13.5,14.300000190734863],"t":"NarrowRoad"},{"i":155,"p":[-2402.10009765625,14,-498.3999938964844,-2389.199951171875,15.100000381469727,-633.5999755859375,14.399999618530273,14.800000190734863],"t":"NarrowRoad"},{"i":156,"p":[-2389.199951171875,15.100000381469727,-633.5999755859375,-2376.300048828125,15.300000190734863,-768.7999877929688,15.899999618530273,16.299999237060547],"t":"NarrowRoad"},{"i":45,"p":[-2384.699951171875,15.800000190734863,620.5999755859375,-2223.89990234375,16.100000381469727,630.9000244140625,16.5,16.899999618530273],"t":"NarrowRoad"},{"i":53,"p":[-2378.39990234375,16.600000381469727,471.29998779296875,-2456.60009765625,16.600000381469727,466.29998779296875,16.600000381469727,16.600000381469727],"t":"NarrowRoad"},{"i":157,"p":[-2376.300048828125,15.300000190734863,-768.7999877929688,-2239.800048828125,15.399999618530273,-755.7999877929688,15.300000190734863,15.300000190734863],"t":"NarrowRoad"},{"i":50,"p":[-2372.10009765625,16.600000381469727,322,-2447,16.100000381469727,317.20001220703125,16.399999618530273,16.299999237060547],"t":"NarrowRoad"},{"i":38,"p":[-2365.89990234375,15.100000381469727,172.8000030517578,-2437.39990234375,15,168.1999969482422,15.100000381469727,15.100000381469727],"t":"NarrowRoad"},{"i":147,"p":[-2313.60009765625,13.300000190734863,19.5,-2426.89990234375,12.800000190734863,7.300000190734863,12.600000381469727,11.699999809265137],"t":"NarrowRoad"},{"i":154,"p":[-2276.199951171875,13.199999809265137,-486.5,-2402.10009765625,14,-498.3999938964844,13.5,13.600000381469727],"t":"NarrowRoad"},{"i":158,"p":[-2239.800048828125,15.399999618530273,-755.7999877929688,-2103.199951171875,13.899999618530273,-742.7000122070312,14.100000381469727,12.399999618530273],"t":"NarrowRoad"},{"i":46,"p":[-2223.89990234375,16.100000381469727,630.9000244140625,-2219.300048828125,17.5,481.5,16.600000381469727,17.100000381469727],"t":"NarrowRoad"},{"i":52,"p":[-2219.300048828125,17.5,481.5,-2378.39990234375,16.600000381469727,471.29998779296875,17.200000762939453,16.899999618530273],"t":"NarrowRoad"},{"i":47,"p":[-2219.300048828125,17.5,481.5,-2214.699951171875,18.299999237060547,332.20001220703125,18.200000762939453,18.600000381469727],"t":"NarrowRoad"},{"i":49,"p":[-2214.699951171875,18.299999237060547,332.20001220703125,-2372.10009765625,16.600000381469727,322,17.700000762939453,17.100000381469727],"t":"NarrowRoad"},{"i":48,"p":[-2214.699951171875,18.299999237060547,332.20001220703125,-2210.10009765625,16.899999618530273,182.8000030517578,17.899999618530273,17.399999618530273],"t":"NarrowRoad"},{"i":37,"p":[-2210.10009765625,16.899999618530273,182.8000030517578,-2365.89990234375,15.100000381469727,172.8000030517578,16.299999237060547,15.699999809265137],"t":"NarrowRoad"},{"i":146,"p":[-2200.39990234375,13.899999618530273,31.600000381469727,-2313.60009765625,13.300000190734863,19.5,13.699999809265137,13.5],"t":"NarrowRoad"},{"i":35,"p":[-2200.39990234375,13.899999618530273,31.600000381469727,-2210.10009765625,16.899999618530273,182.8000030517578,14.699999809265137,16.200000762939453],"t":"NarrowRoad"},{"i":145,"p":[-2200.39990234375,13.899999618530273,31.600000381469727,-2184.199951171875,15.199999809265137,-119.19999694824219,14.300000190734863,14.800000190734863],"t":"NarrowRoad"},{"i":130,"p":[-2184.199951171875,15.199999809265137,-119.19999694824219,-2332.199951171875,12.800000190734863,-133.3000030517578,14.399999618530273,13.600000381469727],"t":"Highway4"},{"i":131,"p":[-2184.199951171875,15.199999809265137,-119.19999694824219,-2172,15.199999809265137,-247,15.199999809265137,15.199999809265137],"t":"NarrowRoad"},{"i":127,"p":[-2184.199951171875,15.199999809265137,-119.19999694824219,-2044,16.299999237060547,-108.30000305175781,15.600000381469727,15.899999618530273],"t":"Highway4"},{"i":149,"p":[-2172,15.199999809265137,-247,-2161.10009765625,13.199999809265137,-360.70001220703125,14.5,13.899999618530273],"t":"NarrowRoad"},{"i":150,"p":[-2161.10009765625,13.199999809265137,-360.70001220703125,-2150.300048828125,13.100000381469727,-474.5,12.699999809265137,12.199999809265137],"t":"NarrowRoad"},{"i":153,"p":[-2150.300048828125,13.100000381469727,-474.5,-2276.199951171875,13.199999809265137,-486.5,13.100000381469727,13.199999809265137],"t":"NarrowRoad"},{"i":160,"p":[-2126.800048828125,12.5,-608.5999755859375,-2150.300048828125,13.100000381469727,-474.5,12.699999809265137,12.899999618530273],"t":"NarrowRoad"},{"i":159,"p":[-2103.199951171875,13.899999618530273,-742.7000122070312,-2126.800048828125,12.5,-608.5999755859375,13.399999618530273,13],"t":"NarrowRoad"},{"i":9,"p":[-2044,16.299999237060547,-108.30000305175781,-1958.800048828125,16.899999618530273,-100.80000305175781,-1873.699951171875,17.700000762939453,-90.69999694824219,-1788.5,18.299999237060547,-80.5],"t":"Highway4"},{"i":10,"p":[-1788.5,18.299999237060547,-80.5,-1703.300048828125,18.899999618530273,-70.30000305175781,-1618.199951171875,19.399999618530273,-58.400001525878906,-1533,19.899999618530273,-47.29999923706055],"t":"Highway4"},{"i":11,"p":[-1533,19.899999618530273,-47.29999923706055,-1447.800048828125,20.399999618530273,-36.20000076293945,-1362.699951171875,21.100000381469727,-24.399999618530273,-1277.5,21.399999618530273,-13.800000190734863],"t":"Highway4"},{"i":12,"p":[-1277.5,21.399999618530273,-13.800000190734863,-1192.300048828125,21.600000381469727,-3.299999952316284,-1107.199951171875,21.799999237060547,6.900000095367432,-1022,21.700000762939453,16.100000381469727],"t":"Highway4"},{"i":13,"p":[-1022,21.700000762939453,16.100000381469727,-936.7999877929688,21.5,25.299999237060547,-851.7000122070312,20.899999618530273,33.5,-766.5,20.600000381469727,41.20000076293945],"t":"Highway4"},{"i":14,"p":[-766.5,20.600000381469727,41.20000076293945,-681.2999877929688,20.399999618530273,49,-596.2000122070312,20.299999237060547,55.70000076293945,-511,20.200000762939453,62.5],"t":"Highway4"},{"i":15,"p":[-511,20.200000762939453,62.5,-425.79998779296875,20.100000381469727,69.4000015258789,-340.70001220703125,20.399999618530273,75.69999694824219,-255.5,20.100000381469727,82.19999694824219],"t":"Highway4"},{"i":16,"p":[-255.5,20.100000381469727,82.19999694824219,-170.3000030517578,19.799999237060547,88.69999694824219,-85.19999694824219,19,95.5999984741211,0,18.399999618530273,101.69999694824219],"t":"Highway4"},{"i":17,"p":[0,18.399999618530273,101.69999694824219,85.19999694824219,17.899999618530273,107.80000305175781,170.3000030517578,16.899999618530273,114.0999984741211,255.5,16.700000762939453,118.5999984741211],"t":"Highway4"},{"i":18,"p":[255.5,16.700000762939453,118.5999984741211,340.70001220703125,16.399999618530273,123.0999984741211,425.79998779296875,16.600000381469727,126.19999694824219,511,16.899999618530273,128.8000030517578],"t":"Highway4"},{"i":19,"p":[511,16.899999618530273,128.8000030517578,596.2000122070312,17.100000381469727,131.3000030517578,681.2999877929688,18,132.1999969482422,766.5,18.399999618530273,133.89999389648438],"t":"Highway4"},{"i":20,"p":[766.5,18.399999618530273,133.89999389648438,851.7000122070312,18.799999237060547,135.5,936.7999877929688,19.100000381469727,136.5,1022,19.200000762939453,138.8000030517578],"t":"Highway4"},{"i":21,"p":[1022,19.200000762939453,138.8000030517578,1107.199951171875,19.399999618530273,141.10000610351562,1192.300048828125,19.200000762939453,143.8000030517578,1277.5,19.299999237060547,147.60000610351562],"t":"Highway4"},{"i":22,"p":[1277.5,19.299999237060547,147.60000610351562,1362.699951171875,19.399999618530273,151.5,1447.800048828125,19.600000381469727,156.60000610351562,1533,19.799999237060547,162],"t":"Highway4"},{"i":23,"p":[1533,19.799999237060547,162,1618.199951171875,19.899999618530273,167.39999389648438,1703.300048828125,20.200000762939453,174.10000610351562,1788.5,20.200000762939453,179.8000030517578],"t":"Highway4"},{"i":24,"p":[1788.5,20.200000762939453,179.8000030517578,1873.699951171875,20.200000762939453,185.39999389648438,1958.800048828125,19.799999237060547,191.8000030517578,2044,19.5,196],"t":"Highway4"},{"i":25,"p":[2044,19.5,196,2129.199951171875,19.299999237060547,200.10000610351562,2214.300048828125,18.899999618530273,203.5,2299.5,18.700000762939453,204.5],"t":"Highway4"},{"i":26,"p":[2299.5,18.700000762939453,204.5,2384.699951171875,18.5,205.5,2469.800048828125,18.399999618530273,204.1999969482422,2555,18.399999618530273,201.89999389648438],"t":"Highway4"},{"i":27,"p":[2555,18.399999618530273,201.89999389648438,2640.199951171875,18.399999618530273,199.5,2725.300048828125,18.299999237060547,195.5,2810.5,18.600000381469727,190.3000030517578],"t":"Highway4"},{"i":28,"p":[2810.5,18.600000381469727,190.3000030517578,2895.699951171875,18.899999618530273,185,2980.800048828125,19.600000381469727,179,3066,20.299999237060547,170.60000610351562],"t":"Highway4"},{"i":29,"p":[3066,20.299999237060547,170.60000610351562,3151.199951171875,21,162.3000030517578,3236.300048828125,22.200000762939453,152.60000610351562,3321.5,22.700000762939453,140.3000030517578],"t":"Highway4"},{"i":30,"p":[3321.5,22.700000762939453,140.3000030517578,3406.699951171875,23.100000381469727,128.10000610351562,3491.800048828125,23.100000381469727,113.5999984741211,3577,22.799999237060547,97],"t":"Highway4"},{"i":31,"p":[3577,22.799999237060547,97,3662.199951171875,22.600000381469727,80.30000305175781,3747.300048828125,21.5,61,3832.5,20.899999618530273,40.29999923706055],"t":"Highway4"},{"i":32,"p":[3832.5,20.899999618530273,40.29999923706055,3917.699951171875,20.399999618530273,19.600000381469727,4045.39990234375,19.700000762939453,-15.899999618530273,4088,19.5,-27.100000381469727],"t":"Highway4"}]]==])
local net=RoadNetwork.new()
for _,s in Serializer.deserialize(rows) do
 net:_directAddSegment(s.p0,s.p1,s.p2,s.p3,s.roadType,{id=s.id,weld=.25,startCorner=s.startCorner,endCorner=s.endCorner,startOffset=s.startOffset,endOffset=s.endOffset,startFlat=s.startFlat,endFlat=s.endFlat,vMode=s.vMode,constSlope=s.constSlope})
end
local graph=Graph.new();graph:Rebuild(net,{})

local fixture=fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local f=fixture(graph,net,fresh)

local lane=graph:GetEdge("S153:L2:R")
local opposite=graph:GetEdge("S153:L1:F")
local leader=f.car("existing","S153:L2:R",50,15)
local other=leader.model:Clone();other.Parent=leader.model.Parent
local pos=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),50)
local goal=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),90)
local accepted=f.d.api.DriveDirected(other,pos,goal,{lane.id},function()end,function()end)
assert(not accepted,"new driver spawned inside an occupied lane seat")
local ending=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),lane.length)
local path=f.d.api.LaneEntryPath(lane.id,ending,nil,other)
local seat=path[#path]
assert((seat-ending).Magnitude>5,"driveway lead ended inside the intersection")
local seatedPath=f.d.api.LaneEntryPath(lane.id,seat,nil,other)
assert(seatedPath and #seatedPath==1,"a departure already at the stop-line seat must not drive upstream and reverse")

leader.route={lane.id};f.d.api.ReleaseDirected(leader.model)
f.follower.place({model=leader.model,heightOffset=0},pos,select(2,f.follower.pointAtDist(lane.points,f.follower.getCum(lane),50)),0)
assert(not f.d.api.DriveDirected(other,pos,goal,{lane.id},function()end,function()end),"new driver spawned inside a waiting parking arrival")
f.follower.forget(leader.model)
local _,dir=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),50)
local curb=pos+Vector3.new(-dir.Z,0,dir.X)*18
local oppDist=(function()
 local cum=f.follower.getCum(opposite);local best,dist=math.huge,0
 for i=1,#opposite.points-1 do
 local a,b=opposite.points[i],opposite.points[i+1];local delta=b-a
 local t=math.clamp((pos-a):Dot(delta)/delta:Dot(delta),0,1)
 local d=(pos-a-delta*t).Magnitude;if d<best then best=d;dist=cum[i]+delta.Magnitude*t end
 end return dist
end)()
local approaching=f.car("opposite",opposite.id,oppDist,15);f.d.reindex()
assert(f.d.api.RoadGapClear(curb,3,other,false,lane.id),"curbside merge yielded to a lane it never crosses")
assert(not f.d.api.RoadGapClear(curb,3,other,false,opposite.id),"cross-road merge ignored approaching traffic")
approaching.route={opposite.id};f.d.api.ReleaseDirected(approaching.model);f.follower.forget(approaching.model)
local same=f.car("same",lane.id,40,15);f.d.reindex()
assert(not f.d.api.RoadGapClear(curb,3,other,false,lane.id),"curbside merge ignored approaching target-lane traffic")
f.follower.forget(other);other:Destroy();f.destroy()
return true
]====]))
		assert(run())
	end)




	describe("Fast-forward driver scheduling",function()
		local function run(speed:number, distanceSq:number?):any
			local source=driverModule.Source
			local first=assert(source:find("function NPCDriverService.Start()",1,true))
			local last=assert(source:find("\ntable.freeze(Tuning)",first,true))
			local result={calls=0,total=0,max=0}
			local model={Parent=true};local state={model=model,lodAccum=0,ix=true}
			local heartbeat
			local graph={Version=function()return 1 end}
			local env:any=setmetatable({NPCDriverService={},_drivers={[model]=state},_joined={},ALL_INDEXES={},
				_simClock=0,_indexGraphVersion=1,RerouteBudget={tokens=0,BURST=2,RATE=1},
				Tuning={MAX_SIM_DT=.1,DRIVER_TICK=.05,SWEEP_EVERY_TICKS=20,LOD_RECHECK=1,
					FAR_LOD_DIST_SQ=1000000,DISTANT_LOD_DIST_SQ=9000000,NEAR_LOD_DIST_SQ=90000,
					DRIVER_MAX_STEP=.3,FAR_MAX_DT=.3,MID_MAX_DT=.15,DISTANT_MAX_DT=.5},
				DISTANT_TICK=.4,FAR_TICK=.2,MID_TICK=.1,
				GameSpeed={steps=function()return speed end},trySpawn=function()return true end,
				RunService={Heartbeat={Connect=function(_,fn)heartbeat=fn;return {Disconnect=function()end}end}},
				PathFollower={keepalive=function()end,nearestPlayerDistSq=function()return distanceSq or 0 end},
				nav=function()return graph end,publishCongestionSnapshot=function()end,
				getStatePosition=function()return Vector3.zero end,despawnAtConnection=function()return false end,
				safeUpdateDriver=function(_,dt)result.calls+=1;result.total+=dt;result.max=math.max(result.max,dt)end},
				{__index=getfenv()})
			local fn=assert(loadstring(source:sub(first,last-1)));setfenv(fn,env);fn();env.NPCDriverService.Start();heartbeat(.05)
			return result
		end
		it("3x speed preserves elapsed time in one fleet scan",function()
			local r=run(6)
			expect(r.calls==1).to.equal(true);expect(math.abs(r.total-.3)<1e-6).to.equal(true)
			expect(r.max<=.3+1e-6).to.equal(true)
		end)
		it("mid-distance cars retain the full fast-forward time",function()
			local r=run(6,400*400)
			expect(math.abs(r.total-.3)<1e-6).to.equal(true)
		end)
		it("pause produces no driver movement",function()
			local r=run(0);expect(r.calls).to.equal(0);expect(r.total).to.equal(0)
		end)
	end)
	describe("Crossing turn past an immobile oncoming queue",function()
		local function clear(speed: number, exitBlocked: boolean): boolean
			local source=driverModule.Source
			local first=assert(source:find("local function signalizedClear(",1,true))
			local last=assert(source:find("\nend",first,true))
			local incoming={id="opposite",toDir=-Vector3.xAxis,outMovement={exit="straight"},points={Vector3.zero,Vector3.new(100,0,0)}}
			local other={edgeId="opposite",edgeDist=88,currentSpeed=speed,pendingNextEdgeId="exit",model={Parent=true}}
			local env=setmetatable({
				_connByLandingNode={},EMPTY={},_edgeDriverIndex={opposite={other}},
				getStatePosition=function()return Vector3.zero end,
				isOpposite=function(a,b)return a:Dot(b)<-.9 end,crossingTurn=function()return "left" end,
				TrafficSignalService={CanGo=function()return true end},
				PathFollower={getCum=function()return {0,100}end},
				getStopLineGap=function()return 1.5 end,
				exitLaneHasRoom=function()return not exitBlocked end,
				movementPathsConflict=function()return true end,
			},{__index=getfenv()})
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn signalizedClear"));setfenv(fn,env)
			return fn()({_edgesByToNode={[2]={incoming}}},{},{id="mine"},2,Vector3.xAxis,"left")
		end
		it("a stationary oncoming car with no exit space does not freeze a green crossing turn",function()
			expect(clear(0,true)).to.equal(true)
		end)
		it("a stationary oncoming car with a usable exit retains priority",function()
			expect(clear(0,false)).to.equal(false)
		end)
		it("moving oncoming traffic retains priority even when its exit is filling",function()
			expect(clear(10,true)).to.equal(false)
		end)
	end)

	describe("Parking turn with a following queue",function()
		it("leaves a safe stationary queue without admitting pull-outs or opposing traffic",function()
			local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end


local net=RoadNetwork.new()
add(net,Vector3.new(0,0,0),Vector3.new(200,0,0),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local lane=graph:GetEdges()[1]
local f=fixture(graph,net,fresh)
local lead=f.car("turning-into-lot",lane.id,60,0)
local rear=f.car("queue-follower",lane.id,48,0)
lead.model:PivotTo(lead.smoothCFrame)
f.d.drivers[lead.model]=nil;f.d.reindex()
local position=lead.smoothCFrame.Position
local exiting=f.d.api.RoadGapClear(position,3,lead.model,true)
local entering=f.d.api.RoadGapClear(position,3,lead.model,false)
rear.smoothCFrame=CFrame.lookAt(rear.smoothCFrame.Position,rear.smoothCFrame.Position-rear.smoothCFrame.LookVector)
f.follower.place(rear,rear.smoothCFrame.Position,rear.smoothCFrame.LookVector,0)
local opposing=f.d.api.RoadGapClear(position,3,lead.model,true)
rear.smoothCFrame=lead.smoothCFrame + (-lead.smoothCFrame.LookVector*8)
f.follower.place(rear,rear.smoothCFrame.Position,rear.smoothCFrame.LookVector,0)
local touching=f.d.api.RoadGapClear(position,3,lead.model,true)
f.destroy()
assert(not touching,"a rear body without safe bumper clearance still blocks")
assert(exiting,"a stationary following queue must not prevent its leader leaving the road")
assert(not entering,"pull-out still requires a gap behind")
assert(not opposing,"an opposing vehicle still blocks a turn across traffic")
return {exiting=exiting,entering=entering,opposing=opposing}
]====],"ParkingQueueRegression"))
			local result=run()
			expect(result.exiting).to.equal(true)
		end)
	end)

	local function fixture()
		local edges: any = {}
		local signals: any = { enabled = false, green = true, yellow = false }
		local graph: any = { _edgesByToNode = {}, _edgesByFromNode = {}, version = 1, searches = 0 }
		function graph:GetEdge(id) return edges[id] end
		function graph:GetEdges() local out = {}; for _, e in edges do table.insert(out, e) end; return out end
		function graph:HasEdges() return next(edges) ~= nil end
		function graph:GetEdgesForSegment(id) local out={} for _,e in edges do if e.segmentId==id then table.insert(out,e)end end return out end
		function graph:Version() return self.version end
		function graph:GetLaneChangeWindow(a, b) if self.window and self.window[1] == a and self.window[2] == b then return 5, 60 end; return nil end
		function graph:GetConnectionSetbacks(a, b) return self.setback or 0, self.landing or 0 end
		function graph:GetConnectionPoints(a, b)
			if self.connector then return self.connector, 0, self.landing or 0 end
			return { edges[a].points[#edges[a].points], edges[b].points[1] }, 0, self.landing or 0
		end
		function graph:NearestEdge(pos) return { edge = edges.a, distance = 0, index = 1 } end
		function graph:FindPath(_, _, _, _, _, anchor)
			self.searches += 1; self.lastAnchor = anchor
			return {}, if anchor then self.replanned else self.unanchored
		end
		function graph:BookRoute(...) end
		function graph:ReleaseBooking(...) end
		function graph:EstimatePathCost(route) return if route == self.replanned then 1 else 100 end
		local follower: any = { STREAM_REACH = 4000, FULL_RATE_DIST = 1000, PROXIMITY_CHECK_DT = 0.1 }
		function follower.cumOf(pts)
			local c = { 0 }; for i = 2, #pts do c[i] = c[i - 1] + (pts[i] - pts[i - 1]).Magnitude end; return c
		end
		function follower.getCum(e) return follower.cumOf(e.points) end
		function follower.pointAtDist(pts, cum, dist)
			for i = 2, #pts do
				if dist <= cum[i] or i == #pts then
					local d = pts[i] - pts[i - 1]
					return pts[i - 1]:Lerp(pts[i], math.clamp((dist - cum[i - 1]) / math.max(d.Magnitude, 1e-9), 0, 1)), if d.Magnitude > 0 then d.Unit else Vector3.xAxis
				end
			end
			return pts[1], Vector3.xAxis
		end
		function follower.place(s, p, d) s.smoothCFrame = CFrame.lookAt(p, p + d); s.model.pose = s.smoothCFrame end
		function follower.getMotionLimits(...) return 1, math.huge, 1, nil end
		function follower.isInRange(...) return false end
		function follower.seedProximity(...) end
		function follower.forget(...) end
		function follower.flushCache(...) end
		function follower.isRegistered(...) return false end
		function follower.anyVehicleWithin(...) return false end
		function follower.getClearAhead(...) return math.huge end
		function follower.sameRoadLevel(...) return true end
		local tags: any = {}
		function tags:HasTag(m, t) return m.tags[t] == true end
		function tags:AddTag(m, t) m.tags[t] = true end
		function tags:RemoveTag(m, t) m.tags[t] = nil end
		local world: any = {}
		function world:GetAttribute(...) return nil end
		function world:FindFirstChild(...) return nil end
		local modules: any = {
			GameSpeed = {get=function() return 1 end,steps=function()return 1 end},
			NetMiddleware = {}, RoadTypeCatalog = {}, BezierUtil = {}, IntersectionRenderer = {}, VehicleFactory = {},
			RoadConstants = { WORLD_SCALE = 0.5, ROAD_THICKNESS = 1, MAP_HALF_EXTENT = 5000 },
			RoadRules = { getCrossingTurn = function() return signals.crossing or "left" end, priorityOverride = function() return nil end },
			PathFollower = follower, TrafficConfig = { PREEMPT_APPROACH_DIST = 40 },
			TrafficSignalService = {
				HasSignal = function() return signals.enabled end, CanGo = function() return signals.green end,
				IsApproachYellow = function() return signals.yellow end,
			},
			VehicleTypes = { Car = "Car", Truck = "Truck", Bus = "Bus", classOf = function(m) return m.class end, canPreempt = function() return false end },
			DriverProfile = { fromModel = function() return nil end, withToken = function(profile) return profile end },
		}
		local fakeGame: any = {}
		function fakeGame:GetService(name)
			if name == "CollectionService" then return tags end
			if name == "Workspace" then return world end
			return game:GetService(name)
		end
		local source = driverModule.Source:gsub("return NPCDriverService%s*$", [[return {
			api = NPCDriverService, step = updateDriver, metadata = _nodeMetaById, drivers = _drivers,
			reindex = rebuildDriverIndexes, exitRoom = exitLaneHasRoom, enter = canEnterIntersection,
			pending = getPendingNextEdgeId, connect = startConnector, reroute = tryReroute,
			trafficReroute = tryTrafficReroute, project = distAlongEdgeNearest, watchdog = stallWatchdog,
			uturn = getUTurnEdge, conflict = movesConflict, safeStep = safeUpdateDriver,
		}]])
		local chunk = assert(loadstring(source, "NPCDriverService.contract"))
		setfenv(chunk, setmetatable({
			game = fakeGame, workspace = world, script = driverModule,
			require = function(m) assert(modules[m.Name], "unstubbed dependency " .. m.Name); return modules[m.Name] end,
			task = { spawn = function(fn) fn() end }, warn = function(...) end,
		}, { __index = getfenv() }))
		local driver = chunk()
		driver.api.Init({ getNavigationGraph = function() return graph end })
		local f: any = { g = graph, signals = signals, d = driver, edges = edges, follower = follower }
		function f.edge(id, start, finish, fromNode, toNode, segment)
			local e: any = { id = id, points = { start, finish }, length = (finish - start).Magnitude,
				fromNode = fromNode, toNode = toNode, segmentId = segment or fromNode,
				toDir = (finish - start).Unit, fromDir = (finish - start).Unit, forward = true,
				out = {}, outMovement = {}, speedLimit = 20, laneOrdinal = 1, roadClass = "local" }
			edges[id] = e
			graph._edgesByToNode[toNode] = graph._edgesByToNode[toNode] or {}
			table.insert(graph._edgesByToNode[toNode], e)
			graph._edgesByFromNode[fromNode] = graph._edgesByFromNode[fromNode] or {}
			table.insert(graph._edgesByFromNode[fromNode], e)
			for _, n in { fromNode, toNode } do
				driver.metadata[n] = driver.metadata[n] or { isIntersection = false, stopLineGap = 1.5,
					stopLineGapBySegment = {}, farSide = {}, mainSegs = {}, priorityKey = false, uTurnByLane = {} }
			end
			return e
		end
		function f.link(a, b, move) table.insert(edges[a].out, b); edges[a].outMovement[b] = move or "straight" end
		function f.car(id, lane, dist, speed)
			local m: any = { Name = id, Parent = true, tags = {}, attrs = { NPCHeightOffset = 1, NPCDebugId = id }, class = "Car", PrimaryPart = {} }
			function m:GetAttribute(k) return self.attrs[k] end
			function m:SetAttribute(k, v) self.attrs[k] = v end
			function m:GetExtentsSize() return Vector3.new(4, 3, 8) end
			function m:GetBoundingBox() return self.pose, self:GetExtentsSize() end
			function m:FindFirstChild(...) return nil end
			function m:GetPivot() return self.pose end
			function m:PivotTo(cf) self.pose = cf end
			function m:Destroy() self.Parent = nil end
			local s: any = { model = m, edgeId = lane, edgeDist = dist or 0, vehicleClass = "Car", graphVersion = 1,
				connDist = 0, nextEdgeDist = 0, speed = 20, currentSpeed = speed or 0, halfLength = 4,
				atDeadEnd = false, deadEndTimer = 0 }
			local p, dir = follower.pointAtDist(edges[lane].points, follower.getCum(edges[lane]), s.edgeDist)
			follower.place(s, p, dir)
			driver.drivers[m] = s
			return s
		end
		f.edge("a", Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), 1, 2)
		f.edge("b", Vector3.new(100, 0, 0), Vector3.new(200, 0, 0), 2, 3)
		f.link("a", "b")
		return f
	end




	describe("Road ownership of spacing",function()
		it("straight traffic is not slowed by a waiting road vehicle in the proximity strip",function()
			local f=fixture()
			local straight=f.car("straight","a",30,20)
			local waiting=f.car("waiting","b",0,0)
			function f.follower.getMotionLimits(model,pos,dir,yielding,ignore)
				if ignore and ignore(model,waiting.model) then return 1,math.huge,nil,nil end
				return 0,0,0,waiting.model
			end
			f.d.reindex();f.d.step(straight,.1)
			expect(straight.currentSpeed>=20).to.equal(true)
			expect(straight.edgeDist>30).to.equal(true)
		end)
		it("a same-lane queue remains stopped even when proximity permits overlap",function()
			local f=fixture()
			local head=f.car("head","a",45,0)
			local rear=f.car("rear","a",35,0)
			f.d.reindex();f.d.step(rear,.1)
			expect(rear.edgeDist<35.1).to.equal(true)
		end)
		it("an off-road parking manoeuvre still holds an approaching road vehicle",function()
			local f=fixture()
			local car=f.car("road","a",30,20)
			local parking={Parent=true}
			function f.follower.getMotionLimits(model,pos,dir,yielding,ignore)
				assert(not ignore or not ignore(model,parking),"off-road vehicle was ignored")
				return 0,0,0,parking
			end
			f.d.reindex();f.d.step(car,.1)
			expect(car.edgeDist).to.equal(30)
		end)
	end)

	describe("Road priority past a blocked parking gate",function()
		it("keeps queued road traffic behind a waiting parking arrival",function()
			local f=fixture()
			local road=f.car("priority-road","a",30,20)
			local parking={Parent=true}
			function f.follower.getMotionLimits(model,pos,dir,yielding)
				if yielding==parking then return 1,math.huge,nil,nil end
				return 0,0,0,parking
			end
			f.d.reindex();f.d.step(road,.1)
			expect(road.edgeDist).to.equal(30)
			for _=1,60 do f.d.step(road,.1) end
			expect(road.edgeDist).to.equal(30)
		end)
		it("a second obstacle remains respected while bypassing the parking gate blocker",function()
			local f=fixture()
			local road=f.car("priority-road","a",30,20)
			local parking={Parent=true}
			function f.follower.getMotionLimits(model,pos,dir,yielding)
				if yielding==parking then return 0,0,0,{Parent=true} end
				return 0,0,0,parking
			end
			f.d.reindex()
			for _=1,60 do f.d.step(road,.1) end
			expect(road.edgeDist).to.equal(30)
		end)
	end)

	describe("Driver fault isolation",function()
		it("one failed update aborts its owner once and leaves healthy cars able to move",function()
			local f=fixture()
			local broken=f.car("bad-route","a",20,10)
			broken.route={"a","b"};broken.routeIndex=1
			local aborts=0;broken.onAbort=function()aborts+=1 end
			local healthy=f.car("healthy","a",50,10)
			f.d.reindex()
			local oldMotion=f.follower.getMotionLimits
			function f.follower.getMotionLimits(model,...)
				if model==broken.model then error("injected vehicle update fault") end
				return oldMotion(model,...)
			end
			expect(f.d.safeStep(broken,.1)).to.equal(false)
			expect(aborts).to.equal(1)
			expect(f.d.drivers[broken.model]).to.equal(nil)
			expect(f.d.safeStep(healthy,.1)).to.equal(true)
			expect(healthy.edgeDist>50).to.equal(true)
		end)
	end)

	describe("Opposing turns on real generated road geometry",function()
		it("both left turns finish while sharing the junction, and the same run fails under red",function()
			local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end



local forceRed: boolean? = ...
local net=RoadNetwork.new()
add(net,Vector3.new(-250,0,0),Vector3.zero,"Highway4")
add(net,Vector3.zero,Vector3.new(250,0,0),"Highway4")
add(net,Vector3.new(0,0,-250),Vector3.zero,"NarrowRoad")
add(net,Vector3.zero,Vector3.new(0,0,250),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local f=fixture(graph,net,fresh);f.signals.enabled=true;f.signals.green=not forceRed
local arrivals,aborts=0,0
local starts={}
for _,e in graph:GetEdges() do
 if math.abs(e.toDir.X)>.9 and math.abs(e.points[#e.points].X)<50 then
  for _,id in e.out do
   if e.outMovement[id]=="left" then
    if not starts[if e.toDir.X>0 then "west" else "east"] then starts[if e.toDir.X>0 then "west" else "east"]={e=e,next=id} end
   end
  end
 end
end
assert(starts.west and starts.east,"both legal opposing left turns must exist")
local cars={}
for name,v in starts do
 local c=f.car(name,v.e.id,v.e.length-45,0)
 c.route={v.e.id,v.next};c.routeIndex=1;c.pendingNextEdgeId=v.next
 c.onArrive=function()arrivals+=1 end;c.onAbort=function()aborts+=1 end
 cars[#cars+1]=c
end
for name,v in starts do
 local straight
 for _,id in v.e.out do if v.e.outMovement[id]=="straight" then straight=id;break end end
 assert(straight,"the shared turn lane must also permit through traffic")
 local c=f.car(name.."-rear-through",v.e.id,v.e.length-61,0)
 c.route={v.e.id,straight};c.routeIndex=1;c.pendingNextEdgeId=straight
 c.onArrive=function()arrivals+=1 end;c.onAbort=function()aborts+=1 end
 cars[#cars+1]=c
end
f.d.reindex()
local together=false
for step=1,1200 do
 f.d.clock(.05)
 for _,c in cars do if f.d.drivers[c.model] then f.d.step(c,.05);f.d.reindex() end end
 if cars[1].connector and cars[2].connector then together=true end
 if arrivals==4 then break end
end
local result={arrivals=arrivals,aborts=aborts,simultaneouslyTurning=together}
f.destroy()
assert(arrivals==4,"both opposite left turns must finish along with their through queues, got "..arrivals)
assert(aborts==0,"no turn may silently abort")
assert(together,"two compatible opposing left turns must be able to share the intersection")
return result]====],"OpposingLeftIntegration"))
			local result=run(false)
			expect(result.arrivals).to.equal(4)
			expect(result.simultaneouslyTurning).to.equal(true)
			local ok,cause=pcall(run,true)
			expect(ok).to.equal(false)
			expect(tostring(cause):find("both opposite left turns must finish",1,true)~=nil).to.equal(true)
		end)
	end)

	describe("Green light rolling platoon",function()
		it("six real road trips roll through green, and a red signal makes the rolling assertion fail",function()
			local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end



local forceRed: boolean?, stepDt:number? = ...
stepDt=stepDt or .05
local net=RoadNetwork.new()
add(net,Vector3.new(-350,0,0),Vector3.zero,"Highway4")
add(net,Vector3.zero,Vector3.new(350,0,0),"Highway4")
add(net,Vector3.new(0,0,-250),Vector3.zero,"NarrowRoad")
add(net,Vector3.zero,Vector3.new(0,0,250),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local f=fixture(graph,net,fresh);f.signals.enabled=true;f.signals.green=not forceRed
local incoming,nextId
for _,e in graph:GetEdges() do
 if e.toDir.X>.9 and math.abs(e.points[#e.points].X)<50 then
  for _,id in e.out do if e.outMovement[id]=="straight" then incoming,nextId=e,id;break end end
  if incoming then break end
 end
end
assert(incoming and nextId,"legal straight movement must exist")
local cars={};local arrivals,aborts,stops=0,0,0
local minSpeed=math.huge
for i=1,6 do
 local c=f.car("platoon-"..i,incoming.id,incoming.length-60-(i-1)*25,20)
 c.route={incoming.id,nextId};c.routeIndex=1;c.pendingNextEdgeId=nextId
 c.onArrive=function()arrivals+=1 end;c.onAbort=function()aborts+=1 end
 cars[#cars+1]=c
end
f.d.reindex()
for step=1,1600 do
 f.d.clock(stepDt)
 for _,c in cars do
  if f.d.drivers[c.model] then
   f.d.step(c,stepDt);f.d.reindex()
   if not c.connector and c.edgeId==incoming.id and incoming.length-c.edgeDist<60 then
    minSpeed=math.min(minSpeed,c.currentSpeed)
    if c.currentSpeed<.1 then stops+=1 end
   end
  end
 end
 if arrivals==6 then break end
end
f.destroy()
assert(stops==0 and minSpeed>1,"green platoon must roll through without stop-line stops; stops="..stops.." minSpeed="..minSpeed)
assert(arrivals==6 and aborts==0,"all six green trips must finish")
return {arrivals=arrivals,stops=stops,minApproachSpeed=minSpeed,aborts=aborts}]====],"GreenConvoyIntegration"))
			local result=run(false,.3)
			expect(run(false,.05).arrivals).to.equal(6)
			expect(result.arrivals).to.equal(6)
			expect(result.stops).to.equal(0)
			local ok,cause=pcall(run,true,.3)
			expect(ok).to.equal(false)
			expect(tostring(cause):find("green platoon must roll through",1,true)~=nil).to.equal(true)
		end)
	end)

	describe("Signal change during a committed truck crossing",function()
		it("conflicting new green waits while a committed truck keeps clearing its new red",function()
			local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end



local stepDt:number?=...
stepDt=stepDt or .05
local net=RoadNetwork.new()
add(net,Vector3.new(-300,0,0),Vector3.zero,"Highway4")
add(net,Vector3.zero,Vector3.new(300,0,0),"Highway4")
add(net,Vector3.new(0,0,-300),Vector3.zero,"NarrowRoad")
add(net,Vector3.zero,Vector3.new(0,0,300),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local incoming,turnExit,crossing
for _,e in graph:GetEdges() do
 if e.toDir.X>.9 and math.abs(e.points[#e.points].X)<50 then
  for _,id in e.out do if e.outMovement[id]=="left" then incoming,turnExit=e,id;break end end
  if incoming then break end
 end
end
assert(incoming and turnExit,"left turn must exist")
for _,e in graph:GetEdges() do
 for _,id in e.out do if id==turnExit and e.outMovement[id]=="straight" then crossing=e;break end end
 if crossing then break end
end
assert(crossing,"conflicting straight movement into the same exit must exist")
local f=fixture(graph,net,fresh);f.signals.enabled=true
local phase=1
f.signals.allow=function(id)return id==(if phase==1 then incoming.id else crossing.id)end
local truck=f.car("old-green-long-truck",incoming.id,incoming.length-45,8)
truck.model.PrimaryPart.Size=Vector3.new(6,3,18);truck.halfLength=9
f.follower.forget(truck.model);f.follower.place(truck,truck.smoothCFrame.Position,truck.smoothCFrame.LookVector,0)
truck.route={incoming.id,turnExit};truck.routeIndex=1;truck.pendingNextEdgeId=turnExit
local straight=f.car("new-green-straight",crossing.id,crossing.length-45,20)
straight.route={crossing.id,turnExit};straight.routeIndex=1;straight.pendingNextEdgeId=turnExit
local arrivals,aborts=0,0
for _,c in {truck,straight} do c.onArrive=function()arrivals+=1 end;c.onAbort=function()aborts+=1 end end
f.d.reindex()
local flipped=false;local blockedNewGreen=false;local unsafeEntry=false;local minClearingSpeed=math.huge
for step=1,1600 do
 f.d.clock(stepDt)
 if not flipped and truck.connector and truck.connDist>5 then phase=2;flipped=true end
 for _,c in {truck,straight} do if f.d.drivers[c.model] then f.d.step(c,stepDt);f.d.reindex() end end
 if flipped and truck.connector then
  minClearingSpeed=math.min(minClearingSpeed,truck.currentSpeed)
  if straight.connector then unsafeEntry=true end
  if not straight.connector and straight.currentSpeed<1 then blockedNewGreen=true end
 end
 if arrivals==2 then break end
end
f.destroy()
assert(flipped,"the phase must change during the truck crossing")
assert(blockedNewGreen,"a conflicting new green must wait for the committed truck")
assert(not unsafeEntry,"conflicting straight traffic must not enter while the old green truck crosses")
assert(minClearingSpeed>1,"the committed truck must keep clearing despite its new red")
assert(arrivals==2 and aborts==0,"both real trips must complete after clearance")
return {arrivals=arrivals,aborts=aborts,blockedNewGreen=blockedNewGreen,unsafeEntry=unsafeEntry,minClearingSpeed=minClearingSpeed}]====],"PhaseClearanceIntegration"))
			local result=run(.3)
			expect(run(.05).arrivals).to.equal(2)
			expect(result.arrivals).to.equal(2)
			expect(result.unsafeEntry).to.equal(false)
		end)
	end)


	describe("Truck overlap recovery",function()
		local function jam(thirdVehicle: boolean)
			local f=fixture()
			f.g.connector={Vector3.new(100,0,0),Vector3.new(150,0,0)};f.g.landing=50
			local front=f.car("front-truck","a",100,0)
			local rear=f.car("rear-truck","a",100,0)
			for _,c in {front,rear} do
				c.route={"a","b"};c.routeIndex=1;c.finalDist=95
				c.halfLength=9;c.speed=20
				f.d.connect(c,f.g.connector,"b",50)
			end
			front.connDist=15;rear.connDist=10
			f.follower.place(front,Vector3.new(115,0,0),Vector3.xAxis)
			f.follower.place(rear,Vector3.new(110,0,0),Vector3.xAxis)
			function f.follower.getMotionLimits(model,pos,dir,yielding)
				if model==front.model and pos.X<125 then
					if yielding==rear.model then return if thirdVehicle then 0 else 1,if thirdVehicle then 0 else math.huge,1,nil end
					return 0,0,1,rear.model
				end
				return 1,math.huge,1,nil
			end
			f.d.reindex()
			local arrived=0
			for _,c in {front,rear} do c.onArrive=function()arrived+=1 end end
			for i=1,1200 do
				for _,c in {front,rear} do if f.d.drivers[c.model] then f.d.step(c,.05);f.d.reindex() end end
				if arrived==2 then break end
			end
			return arrived,front.connDist
		end
		it("a leader blocked by its own queued follower frees both trucks",function()
			local arrived=jam(false)
			expect(arrived).to.equal(2)
		end)
		it("recovery must still stop for a third blocking vehicle",function()
			local arrived,dist=jam(true)
			expect(arrived).to.equal(0)
			expect(dist).to.equal(15)
		end)
	end)


	describe("New truck junction entry",function()
		local function entry(blocked: boolean)
			local f=fixture();f.d.metadata[2].isIntersection=true
			function f.follower.anyVehicleWithin(...) return false end
			function f.g:GetEdgesForSegment(segment) return {f.edges.a} end
			local car=f.car("new-truck","a",100,0)
			f.d.drivers[car.model]=nil
			if blocked then f.car("stop-line-queue","a",97.5,0) end
			f.d.reindex()
			local ok=f.d.api.DriveDirected(car.model,Vector3.new(100,0,0),Vector3.new(195,0,0),{"a","b"})
			local pose=f.d.api.GetLivePose(car.model)
			return ok,pose
		end
		it("an unregistered launch at the node starts behind its stop line",function()
			local ok,pose=entry(false)
			expect(ok).to.equal(true)
			expect(pose.Position.X<=97.5).to.equal(true)
		end)
		it("an occupied safe seat rejects the launch rather than piling onto the queue",function()
			local ok=entry(true)
			expect(ok).to.equal(false)
		end)
	end)

	describe("Lane-specific junction admission", function()
		local function turningPair(overlap: boolean, sameExit: boolean, crossing: boolean?)
			local f=fixture()
			f.signals.enabled=true
			f.d.metadata[2].isIntersection=true
			f.edge("opposite",Vector3.new(200,0,0),Vector3.new(100,0,0),7,2,7)
			f.edge("northInner",Vector3.new(94,0,50),Vector3.new(94,0,180),2,8,8)
			f.edge("northOuter",Vector3.new(102,0,50),Vector3.new(102,0,180),2,8,8)
			f.link("a","northInner","left")
			local nextId=if sameExit then "northInner" else "northOuter"
			f.link("opposite",nextId,"right")
			local mine={Vector3.new(90,0,0),Vector3.new(94,0,8),Vector3.new(94,0,50)}
			local theirs=if overlap then {Vector3.new(110,0,0),Vector3.new(94,0,8),Vector3.new(94,0,50)}
				else {Vector3.new(110,0,0),Vector3.new(102,0,8),Vector3.new(102,0,50)}
			function f.g:GetConnectionPoints(a,b) return if a=="a" then mine else theirs end
			local a=f.car("left-turn","a",88,0)
			a.pendingNextEdgeId="northInner"
			local b=f.car("right-turn","opposite",88,20)
			b.pendingNextEdgeId=nextId
			if crossing then b.connector=theirs;b.nextEdgeId=nextId end
			f.d.reindex()
			return f,a,b
		end
		it("a left and opposing right turn can use distinct noncrossing destination lanes together",function()
			local f,a,b=turningPair(false,false)
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(true)
			expect(f.d.enter(f.g,b,f.edges.opposite,"northOuter")).to.equal(true)
		end)
		it("a compatible vehicle already turning does not reserve the whole box",function()
			local f,a=turningPair(false,false,true)
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(true)
		end)
		it("different destination lane IDs do not permit paths that physically cross",function()
			local f,a=turningPair(true,false)
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(false)
		end)
		it("turns merging into the same destination lane still yield",function()
			local f,a=turningPair(false,true)
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(false)
		end)
		it("opposing left-turn heads do not yield to straight traffic trapped behind each other",function()
			local f=fixture();f.signals.enabled=true;f.d.metadata[2].isIntersection=true
			f.edge("opposite",Vector3.new(200,0,0),Vector3.new(100,0,0),7,2,7)
			f.edge("north",Vector3.new(100,0,-40),Vector3.new(100,0,-160),2,8,8)
			f.edge("south",Vector3.new(100,0,40),Vector3.new(100,0,160),2,9,9)
			f.edge("westOut",Vector3.new(100,0,0),Vector3.new(0,0,0),2,10,10)
			f.link("a","north","left");f.link("opposite","south","left")
			f.link("opposite","westOut","straight")
			local mine=f.car("west-turn","a",95,0);mine.pendingNextEdgeId="north"
			local other=f.car("east-turn","opposite",95,0);other.pendingNextEdgeId="south"
			local rear=f.car("trapped-straight","opposite",82,0);rear.pendingNextEdgeId="westOut"
			f.d.reindex()
			expect(f.d.enter(f.g,mine,f.edges.a,"north")).to.equal(true)
			expect(f.d.enter(f.g,other,f.edges.opposite,"south")).to.equal(true)
		end)

		it("a crossing connector cannot be dismissed merely because its turn label says compatible",function()
			local f=fixture();f.signals.enabled=true;f.d.metadata[2].isIntersection=true
			f.edge("side",Vector3.new(100,0,-100),Vector3.new(100,0,0),7,2,7)
			f.edge("exit",Vector3.new(100,0,0),Vector3.new(200,0,0),2,8,8)
			f.link("side","exit","right")
			f.link("a","b","straight")
			local mine=f.car("new-green","a",98,20);mine.pendingNextEdgeId="b"
			local other=f.car("old-green-truck","side",60,3)
			other.connector={Vector3.new(100,0,-40),Vector3.new(100,0,40)}
			other.nextEdgeId="exit";other.connDist=5
			function f.g:GetConnectionPoints(from,to)
				return if from=="a" then {Vector3.new(90,0,0),Vector3.new(110,0,0)} else other.connector
			end
			f.d.reindex()
			expect(f.d.enter(f.g,mine,f.edges.a,"b")).to.equal(false)
			f.d.drivers[other.model]=nil;f.d.reindex()
			expect(f.d.enter(f.g,mine,f.edges.a,"b")).to.equal(true)
		end)

		for _,cross in {"left","right"} do
			for _,turnsAcross in {true,false} do
				it("oncoming priority follows crossing side "..cross.." for across="..tostring(turnsAcross),function()
					local f=fixture();f.signals.enabled=true;f.signals.crossing=cross
					f.d.metadata[2].isIntersection=true
					f.edge("opposite",Vector3.new(200,0,0),Vector3.new(100,0,0),7,2,7)
					f.edge("westOut",Vector3.new(100,0,0),Vector3.new(0,0,0),2,9,9)
					f.link("opposite","westOut","straight")
					f.link("a","b",if turnsAcross then cross else (if cross=="left" then "right" else "left"))
					local mine=f.car("turning","a",95,0);mine.pendingNextEdgeId="b"
					local other=f.car("through","opposite",95,20);other.pendingNextEdgeId="westOut"
					f.d.reindex()
					expect(f.d.enter(f.g,mine,f.edges.a,"b")).to.equal(not turnsAcross)
				end)
			end
		end
		it("road edits invalidate previously compatible connector geometry",function()
			local f,a=turningPair(false,false)
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(true)
			function f.g:GetConnectionPoints(from,to)
				return {Vector3.new(90,0,0),Vector3.new(94,0,8),Vector3.new(94,0,50)}
			end
			f.g.version+=1
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(false)
		end)
		it("a red light still blocks a geometrically compatible turn",function()
			local f,a=turningPair(false,false)
			f.signals.green=false
			expect(f.d.enter(f.g,a,f.edges.a,"northInner")).to.equal(false)
		end)
	end)

	describe("captured city restore admission", function()
		for _, bodySize in {Vector3.new(4,3,8),Vector3.new(6,3,18)} do
		it("separates duplicate saved positions for body length "..bodySize.Z.." without sustained overlaps", function()
			local run = assert(loadstring([====[
-- Verified Studio Edit runner. Uses fresh live module sources.
local bodySize: Vector3 = ...
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end

local Serializer=fresh(game.ServerScriptService.Services.Road.RoadSerializer)
local rows=game.HttpService:JSONDecode([==[[{"i":108,"p":[-4096,15.300000190734863,-213.1999969482422,-3900,14.100000381469727,-204.3000030517578,14.800000190734863,14.5],"t":"Highway4"},{"i":109,"p":[-3900,14.100000381469727,-204.3000030517578,-3704.10009765625,13.399999618530273,-195.5,13.800000190734863,13.600000381469727],"t":"Highway4"},{"i":110,"p":[-3704.10009765625,13.399999618530273,-195.5,-3508.10009765625,13.100000381469727,-186.60000610351562,13.300000190734863,13.100000381469727],"t":"Highway4"},{"i":111,"p":[-3508.10009765625,13.100000381469727,-186.60000610351562,-3312.10009765625,12.899999618530273,-177.6999969482422,13,12.899999618530273],"t":"Highway4"},{"i":112,"p":[-3312.10009765625,12.899999618530273,-177.6999969482422,-3116.10009765625,13,-168.8000030517578,12.899999618530273,12.899999618530273],"t":"Highway4"},{"i":113,"p":[-3116.10009765625,13,-168.8000030517578,-2920.10009765625,13,-159.89999389648438,13,13],"t":"Highway4"},{"i":114,"p":[-2920.10009765625,13,-159.89999389648438,-2724.10009765625,13.100000381469727,-151,13.100000381469727,13.100000381469727],"t":"Highway4"},{"i":115,"p":[-2724.10009765625,13.100000381469727,-151,-2528.199951171875,13.100000381469727,-142.1999969482422,13.100000381469727,13.100000381469727],"t":"Highway4"},{"i":43,"p":[-2706.199951171875,14.600000381469727,599.7999877929688,-2545.39990234375,13.300000190734863,610.2000122070312,14.199999809265137,13.800000190734863],"t":"NarrowRoad"},{"i":42,"p":[-2696.60009765625,14.600000381469727,450.79998779296875,-2706.199951171875,14.600000381469727,599.7999877929688,14.300000190734863,14.100000381469727],"t":"NarrowRoad"},{"i":41,"p":[-2687,15.100000381469727,301.70001220703125,-2696.60009765625,14.600000381469727,450.79998779296875,15.199999809265137,14.899999618530273],"t":"NarrowRoad"},{"i":40,"p":[-2677.5,13.899999618530273,152.6999969482422,-2687,15.100000381469727,301.70001220703125,14.300000190734863,14.699999809265137],"t":"NarrowRoad"},{"i":44,"p":[-2545.39990234375,13.300000190734863,610.2000122070312,-2466.199951171875,14.5,615.2999877929688,13.699999809265137,14.100000381469727],"t":"NarrowRoad"},{"i":54,"p":[-2537.5,16.200000762939453,461.1000061035156,-2696.60009765625,14.600000381469727,450.79998779296875,15.699999809265137,15.100000381469727],"t":"NarrowRoad"},{"i":51,"p":[-2529.60009765625,15.5,311.79998779296875,-2687,15.100000381469727,301.70001220703125,15.399999618530273,15.199999809265137],"t":"NarrowRoad"},{"i":116,"p":[-2528.199951171875,13.100000381469727,-142.1999969482422,-2332.199951171875,12.800000190734863,-133.3000030517578,13,12.899999618530273],"t":"Highway4"},{"i":39,"p":[-2521.699951171875,14.899999618530273,162.6999969482422,-2677.5,13.899999618530273,152.6999969482422,14.699999809265137,14.399999618530273],"t":"NarrowRoad"},{"i":60,"p":[-2466.199951171875,14.5,615.2999877929688,-2384.699951171875,15.800000190734863,620.5999755859375,15,15.399999618530273],"t":"NarrowRoad"},{"i":58,"p":[-2456.60009765625,16.600000381469727,466.29998779296875,-2537.5,16.200000762939453,461.1000061035156,16.600000381469727,16.399999618530273],"t":"NarrowRoad"},{"i":61,"p":[-2456.60009765625,16.600000381469727,466.29998779296875,-2466.199951171875,14.5,615.2999877929688,15.899999618530273,15.199999809265137],"t":"NarrowRoad"},{"i":56,"p":[-2447,16.100000381469727,317.20001220703125,-2529.60009765625,15.5,311.79998779296875,16,15.800000190734863],"t":"NarrowRoad"},{"i":59,"p":[-2447,16.100000381469727,317.20001220703125,-2456.60009765625,16.600000381469727,466.29998779296875,16.299999237060547,16.5],"t":"NarrowRoad"},{"i":55,"p":[-2437.39990234375,15,168.1999969482422,-2521.699951171875,14.899999618530273,162.6999969482422,15,14.899999618530273],"t":"NarrowRoad"},{"i":57,"p":[-2437.39990234375,15,168.1999969482422,-2447,16.100000381469727,317.20001220703125,15.399999618530273,15.800000190734863],"t":"NarrowRoad"},{"i":148,"p":[-2426.89990234375,12.800000190734863,7.300000190734863,-2437.39990234375,15,168.1999969482422,13.5,14.300000190734863],"t":"NarrowRoad"},{"i":155,"p":[-2402.10009765625,14,-498.3999938964844,-2389.199951171875,15.100000381469727,-633.5999755859375,14.399999618530273,14.800000190734863],"t":"NarrowRoad"},{"i":156,"p":[-2389.199951171875,15.100000381469727,-633.5999755859375,-2376.300048828125,15.300000190734863,-768.7999877929688,15.899999618530273,16.299999237060547],"t":"NarrowRoad"},{"i":45,"p":[-2384.699951171875,15.800000190734863,620.5999755859375,-2223.89990234375,16.100000381469727,630.9000244140625,16.5,16.899999618530273],"t":"NarrowRoad"},{"i":53,"p":[-2378.39990234375,16.600000381469727,471.29998779296875,-2456.60009765625,16.600000381469727,466.29998779296875,16.600000381469727,16.600000381469727],"t":"NarrowRoad"},{"i":157,"p":[-2376.300048828125,15.300000190734863,-768.7999877929688,-2239.800048828125,15.399999618530273,-755.7999877929688,15.300000190734863,15.300000190734863],"t":"NarrowRoad"},{"i":50,"p":[-2372.10009765625,16.600000381469727,322,-2447,16.100000381469727,317.20001220703125,16.399999618530273,16.299999237060547],"t":"NarrowRoad"},{"i":38,"p":[-2365.89990234375,15.100000381469727,172.8000030517578,-2437.39990234375,15,168.1999969482422,15.100000381469727,15.100000381469727],"t":"NarrowRoad"},{"i":147,"p":[-2313.60009765625,13.300000190734863,19.5,-2426.89990234375,12.800000190734863,7.300000190734863,12.600000381469727,11.699999809265137],"t":"NarrowRoad"},{"i":154,"p":[-2276.199951171875,13.199999809265137,-486.5,-2402.10009765625,14,-498.3999938964844,13.5,13.600000381469727],"t":"NarrowRoad"},{"i":158,"p":[-2239.800048828125,15.399999618530273,-755.7999877929688,-2103.199951171875,13.899999618530273,-742.7000122070312,14.100000381469727,12.399999618530273],"t":"NarrowRoad"},{"i":46,"p":[-2223.89990234375,16.100000381469727,630.9000244140625,-2219.300048828125,17.5,481.5,16.600000381469727,17.100000381469727],"t":"NarrowRoad"},{"i":52,"p":[-2219.300048828125,17.5,481.5,-2378.39990234375,16.600000381469727,471.29998779296875,17.200000762939453,16.899999618530273],"t":"NarrowRoad"},{"i":47,"p":[-2219.300048828125,17.5,481.5,-2214.699951171875,18.299999237060547,332.20001220703125,18.200000762939453,18.600000381469727],"t":"NarrowRoad"},{"i":49,"p":[-2214.699951171875,18.299999237060547,332.20001220703125,-2372.10009765625,16.600000381469727,322,17.700000762939453,17.100000381469727],"t":"NarrowRoad"},{"i":48,"p":[-2214.699951171875,18.299999237060547,332.20001220703125,-2210.10009765625,16.899999618530273,182.8000030517578,17.899999618530273,17.399999618530273],"t":"NarrowRoad"},{"i":37,"p":[-2210.10009765625,16.899999618530273,182.8000030517578,-2365.89990234375,15.100000381469727,172.8000030517578,16.299999237060547,15.699999809265137],"t":"NarrowRoad"},{"i":146,"p":[-2200.39990234375,13.899999618530273,31.600000381469727,-2313.60009765625,13.300000190734863,19.5,13.699999809265137,13.5],"t":"NarrowRoad"},{"i":35,"p":[-2200.39990234375,13.899999618530273,31.600000381469727,-2210.10009765625,16.899999618530273,182.8000030517578,14.699999809265137,16.200000762939453],"t":"NarrowRoad"},{"i":145,"p":[-2200.39990234375,13.899999618530273,31.600000381469727,-2184.199951171875,15.199999809265137,-119.19999694824219,14.300000190734863,14.800000190734863],"t":"NarrowRoad"},{"i":130,"p":[-2184.199951171875,15.199999809265137,-119.19999694824219,-2332.199951171875,12.800000190734863,-133.3000030517578,14.399999618530273,13.600000381469727],"t":"Highway4"},{"i":131,"p":[-2184.199951171875,15.199999809265137,-119.19999694824219,-2172,15.199999809265137,-247,15.199999809265137,15.199999809265137],"t":"NarrowRoad"},{"i":127,"p":[-2184.199951171875,15.199999809265137,-119.19999694824219,-2044,16.299999237060547,-108.30000305175781,15.600000381469727,15.899999618530273],"t":"Highway4"},{"i":149,"p":[-2172,15.199999809265137,-247,-2161.10009765625,13.199999809265137,-360.70001220703125,14.5,13.899999618530273],"t":"NarrowRoad"},{"i":150,"p":[-2161.10009765625,13.199999809265137,-360.70001220703125,-2150.300048828125,13.100000381469727,-474.5,12.699999809265137,12.199999809265137],"t":"NarrowRoad"},{"i":153,"p":[-2150.300048828125,13.100000381469727,-474.5,-2276.199951171875,13.199999809265137,-486.5,13.100000381469727,13.199999809265137],"t":"NarrowRoad"},{"i":160,"p":[-2126.800048828125,12.5,-608.5999755859375,-2150.300048828125,13.100000381469727,-474.5,12.699999809265137,12.899999618530273],"t":"NarrowRoad"},{"i":159,"p":[-2103.199951171875,13.899999618530273,-742.7000122070312,-2126.800048828125,12.5,-608.5999755859375,13.399999618530273,13],"t":"NarrowRoad"},{"i":9,"p":[-2044,16.299999237060547,-108.30000305175781,-1958.800048828125,16.899999618530273,-100.80000305175781,-1873.699951171875,17.700000762939453,-90.69999694824219,-1788.5,18.299999237060547,-80.5],"t":"Highway4"},{"i":10,"p":[-1788.5,18.299999237060547,-80.5,-1703.300048828125,18.899999618530273,-70.30000305175781,-1618.199951171875,19.399999618530273,-58.400001525878906,-1533,19.899999618530273,-47.29999923706055],"t":"Highway4"},{"i":11,"p":[-1533,19.899999618530273,-47.29999923706055,-1447.800048828125,20.399999618530273,-36.20000076293945,-1362.699951171875,21.100000381469727,-24.399999618530273,-1277.5,21.399999618530273,-13.800000190734863],"t":"Highway4"},{"i":12,"p":[-1277.5,21.399999618530273,-13.800000190734863,-1192.300048828125,21.600000381469727,-3.299999952316284,-1107.199951171875,21.799999237060547,6.900000095367432,-1022,21.700000762939453,16.100000381469727],"t":"Highway4"},{"i":13,"p":[-1022,21.700000762939453,16.100000381469727,-936.7999877929688,21.5,25.299999237060547,-851.7000122070312,20.899999618530273,33.5,-766.5,20.600000381469727,41.20000076293945],"t":"Highway4"},{"i":14,"p":[-766.5,20.600000381469727,41.20000076293945,-681.2999877929688,20.399999618530273,49,-596.2000122070312,20.299999237060547,55.70000076293945,-511,20.200000762939453,62.5],"t":"Highway4"},{"i":15,"p":[-511,20.200000762939453,62.5,-425.79998779296875,20.100000381469727,69.4000015258789,-340.70001220703125,20.399999618530273,75.69999694824219,-255.5,20.100000381469727,82.19999694824219],"t":"Highway4"},{"i":16,"p":[-255.5,20.100000381469727,82.19999694824219,-170.3000030517578,19.799999237060547,88.69999694824219,-85.19999694824219,19,95.5999984741211,0,18.399999618530273,101.69999694824219],"t":"Highway4"},{"i":17,"p":[0,18.399999618530273,101.69999694824219,85.19999694824219,17.899999618530273,107.80000305175781,170.3000030517578,16.899999618530273,114.0999984741211,255.5,16.700000762939453,118.5999984741211],"t":"Highway4"},{"i":18,"p":[255.5,16.700000762939453,118.5999984741211,340.70001220703125,16.399999618530273,123.0999984741211,425.79998779296875,16.600000381469727,126.19999694824219,511,16.899999618530273,128.8000030517578],"t":"Highway4"},{"i":19,"p":[511,16.899999618530273,128.8000030517578,596.2000122070312,17.100000381469727,131.3000030517578,681.2999877929688,18,132.1999969482422,766.5,18.399999618530273,133.89999389648438],"t":"Highway4"},{"i":20,"p":[766.5,18.399999618530273,133.89999389648438,851.7000122070312,18.799999237060547,135.5,936.7999877929688,19.100000381469727,136.5,1022,19.200000762939453,138.8000030517578],"t":"Highway4"},{"i":21,"p":[1022,19.200000762939453,138.8000030517578,1107.199951171875,19.399999618530273,141.10000610351562,1192.300048828125,19.200000762939453,143.8000030517578,1277.5,19.299999237060547,147.60000610351562],"t":"Highway4"},{"i":22,"p":[1277.5,19.299999237060547,147.60000610351562,1362.699951171875,19.399999618530273,151.5,1447.800048828125,19.600000381469727,156.60000610351562,1533,19.799999237060547,162],"t":"Highway4"},{"i":23,"p":[1533,19.799999237060547,162,1618.199951171875,19.899999618530273,167.39999389648438,1703.300048828125,20.200000762939453,174.10000610351562,1788.5,20.200000762939453,179.8000030517578],"t":"Highway4"},{"i":24,"p":[1788.5,20.200000762939453,179.8000030517578,1873.699951171875,20.200000762939453,185.39999389648438,1958.800048828125,19.799999237060547,191.8000030517578,2044,19.5,196],"t":"Highway4"},{"i":25,"p":[2044,19.5,196,2129.199951171875,19.299999237060547,200.10000610351562,2214.300048828125,18.899999618530273,203.5,2299.5,18.700000762939453,204.5],"t":"Highway4"},{"i":26,"p":[2299.5,18.700000762939453,204.5,2384.699951171875,18.5,205.5,2469.800048828125,18.399999618530273,204.1999969482422,2555,18.399999618530273,201.89999389648438],"t":"Highway4"},{"i":27,"p":[2555,18.399999618530273,201.89999389648438,2640.199951171875,18.399999618530273,199.5,2725.300048828125,18.299999237060547,195.5,2810.5,18.600000381469727,190.3000030517578],"t":"Highway4"},{"i":28,"p":[2810.5,18.600000381469727,190.3000030517578,2895.699951171875,18.899999618530273,185,2980.800048828125,19.600000381469727,179,3066,20.299999237060547,170.60000610351562],"t":"Highway4"},{"i":29,"p":[3066,20.299999237060547,170.60000610351562,3151.199951171875,21,162.3000030517578,3236.300048828125,22.200000762939453,152.60000610351562,3321.5,22.700000762939453,140.3000030517578],"t":"Highway4"},{"i":30,"p":[3321.5,22.700000762939453,140.3000030517578,3406.699951171875,23.100000381469727,128.10000610351562,3491.800048828125,23.100000381469727,113.5999984741211,3577,22.799999237060547,97],"t":"Highway4"},{"i":31,"p":[3577,22.799999237060547,97,3662.199951171875,22.600000381469727,80.30000305175781,3747.300048828125,21.5,61,3832.5,20.899999618530273,40.29999923706055],"t":"Highway4"},{"i":32,"p":[3832.5,20.899999618530273,40.29999923706055,3917.699951171875,20.399999618530273,19.600000381469727,4045.39990234375,19.700000762939453,-15.899999618530273,4088,19.5,-27.100000381469727],"t":"Highway4"}]]==])
local net=RoadNetwork.new()
for _,s in Serializer.deserialize(rows) do
 net:_directAddSegment(s.p0,s.p1,s.p2,s.p3,s.roadType,{id=s.id,weld=.25,startCorner=s.startCorner,endCorner=s.endCorner,startOffset=s.startOffset,endOffset=s.endOffset,startFlat=s.startFlat,endFlat=s.endFlat,vMode=s.vMode,constSlope=s.constSlope})
end
local graph=Graph.new();graph:Rebuild(net,{})

local fixture=fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local f=fixture(graph,net,fresh)
local lanes={}
for _,edge in graph:GetEdges() do
 if edge.length>60 and edge.points[1].X < -2000 and edge.points[1].Z>-800 and edge.points[1].Z<800 then table.insert(lanes,edge) end
end
table.sort(lanes,function(a,b)return a.id<b.id end)
local cars={};local arrived,aborted=0,0
for i,edge in lanes do
 if #cars>=20 then break end
 local dist=math.min(25,edge.length*.3)
 local pos=f.follower.pointAtDist(edge.points,edge._cum,dist)
 if not f.d.api.IsPointClear(pos,12) then continue end
 local target=lanes[(i+math.floor(#lanes*.45)-1)%#lanes+1]
 local finish=target.length-20
 local goal=f.follower.pointAtDist(target.points,target._cum,finish)
 local _,route=graph:FindPath(pos,goal,false,"Car",nil,{edgeId=edge.id,dist=dist})
 if not route or #route<2 then continue end
 for copy=1,2 do
 local s=f.car("saved-city-"..i.."-"..copy,edge.id,dist,0)
 s.model.PrimaryPart.Size=bodySize
 f.d.drivers[s.model]=nil; f.follower.forget(s.model)
 local seat,restoredDist=f.d.api.GetRestoreSeat(s.model,{edgeId=edge.id,dist=dist})
 assert(seat and restoredDist)
 s.model:PivotTo(seat)
 s.restoreDist=restoredDist;s.restorePos=seat.Position
 s.pendingRestore=true
 s.route=route;s.routeIndex=1;s.goalPos=goal;s.finalDist=finish
 s.onArrive=function()arrived+=1 end;s.onAbort=function()aborted+=1 end
 table.insert(cars,s)
 end
end
 local closest=math.huge
 local collisions=0
 local overlapSeconds={}
 local longestOverlap=0
 local firstCollision=nil
 local elapsed=0
 for tick=1,9600 do
  elapsed=tick*.05
  for _,s in cars do
   if s.pendingRestore and f.d.api.RoadGapClear(s.restorePos,3,s.model) then
    local started=f.d.api.DriveDirected(s.model,s.restorePos,s.goalPos,s.route,s.onArrive,s.onAbort,s.restoreDist)
    assert(started,"restored route rejected")
    s.pendingRestore=false
    local live=f.d.drivers[s.model]
    live.pendingRestore=false
    for key,value in live do s[key]=value end
    f.d.drivers[s.model]=s
    f.d.reindex()
   end
  end
  f.d.clock(.05);f.d.reindex()
  for _,s in cars do
   if f.d.drivers[s.model] then f.d.step(s,.05);f.d.reindex() end
  end
  for i=1,#cars do for j=i+1,#cars do
   local a,b=cars[i],cars[j]
   if f.d.drivers[a.model] and f.d.drivers[b.model] then
    local pa,pb=a.smoothCFrame,b.smoothCFrame
    local change=pb.Position-pa.Position
    closest=math.min(closest,change.Magnitude)
    local overlap=true
    for _,axis in {pa.RightVector,pa.LookVector,pb.RightVector,pb.LookVector} do
     local extent=2*math.abs(pa.RightVector:Dot(axis))+a.halfLength*math.abs(pa.LookVector:Dot(axis))
      +2*math.abs(pb.RightVector:Dot(axis))+b.halfLength*math.abs(pb.LookVector:Dot(axis))
     if math.abs(change:Dot(axis)) >= extent-.05 then overlap=false;break end
    end
    local pair=tostring(i)..":"..tostring(j)
    overlapSeconds[pair]=if overlap then (overlapSeconds[pair] or 0)+.05 else 0
    longestOverlap=math.max(longestOverlap,overlapSeconds[pair])
    if overlap then
     collisions+=1
     firstCollision=firstCollision or {time=elapsed,a=a.model.Name,b=b.model.Name,ae=a.edgeId,be=b.edgeId,
      ad=a.edgeDist,bd=b.edgeDist,ac=a.connector~=nil,bc=b.connector~=nil,an=a.nextEdgeId,bn=b.nextEdgeId,
      ap=tostring(pa.Position),bp=tostring(pb.Position)}
    end
   end
  end end
  if arrived+aborted==#cars then break end
 end
 local remaining={}
 for _,s in cars do
  if f.d.drivers[s.model] then
   table.insert(remaining,{car=s.model.Name,edge=s.edgeId,dist=s.edgeDist,why=s.stopReason,speed=s.currentSpeed})
  end
  f.follower.forget(s.model)
  s.model:Destroy()
 end
 f.destroy()
 return {name="captured city duplicate saved-position admission",cars=#cars,arrived=arrived,aborted=aborted,elapsed=elapsed,closest=closest,
  collisions=collisions,longestOverlap=longestOverlap,firstCollision=firstCollision,remaining=remaining,
  passed=arrived==#cars and aborted==0 and longestOverlap<4}
]====], "CapturedCityRestore"))
			local result = run(bodySize)
			expect(result.cars).to.equal(20)
			expect(result.arrived).to.equal(20)
			expect(result.aborted).to.equal(0)
			expect(result.longestOverlap<4).to.equal(true)
		end)
		end
	end)

	describe("Parking movement integration",function()
		it("parks the leader and clears the following car without body overlap",function()
			local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end


local net=RoadNetwork.new()
add(net,Vector3.zero,Vector3.new(200,0,0),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local lane=graph:GetEdges()[1]
local f=fixture(graph,net,fresh)
local lead=f.car("parking",lane.id,60,0)
local rear=f.car("following",lane.id,48,0)
lead.model:PivotTo(lead.smoothCFrame)
f.d.drivers[lead.model]=nil;f.d.reindex()
local citizenSource=game.ServerScriptService.Services.City.Simulation.CitizenService.Source
local function section(name)
 local first=assert(citizenSource:find("local function "..name.."(",1,true))
 local last=assert(citizenSource:find("\nend",first,true))
 return citizenSource:sub(first,last+4)
end
local env=setmetatable({PathFollower=f.follower,Cars={movementOrder=0,LOT_STANDOFF_CLEARANCE=.05,LOT_STANDOFF_SECONDS=4},_trips={},_tripCount=0,CAR_HEIGHT=0},{__index=getfenv()})
local body=assert(loadstring(section("lineFollow").."\n"..section("stepTrips").."\nreturn {follow=lineFollow,step=stepTrips}"))
setfenv(body,env);local citizen=body()
local parked,arrived,aborted=0,0,0
local pos=lead.smoothCFrame.Position
local goal=f.follower.pointAtDist(lane.points,lane._cum,160)
f.d.api.ReleaseDirected(rear.model)
assert(f.d.api.DriveDirected(rear.model,rear.smoothCFrame.Position,goal,{lane.id},function()arrived+=1 end,function()aborted+=1 end,48))
citizen.follow(lead.model,{pos,pos+Vector3.new(0,0,30)},12,function()parked+=1 end,0,
 function()return f.d.api.RoadGapClear(pos,3,lead.model,true)end,true)
local overlaps=0
for tick=1,600 do
 citizen.step(.05)
 f.d.clock(.05);f.d.reindex()
 local road=f.d.drivers[rear.model]
 if road then f.d.step(road,.05);f.d.reindex() end
 local localTrip=env._trips[lead.model]
 road=f.d.drivers[rear.model]
 if localTrip and localTrip.smoothCFrame and road and road.smoothCFrame then
  local a,b=localTrip.smoothCFrame,road.smoothCFrame
  local delta=b.Position-a.Position;local touching=true
  for _,axis in {a.RightVector,a.LookVector,b.RightVector,b.LookVector} do
   local extent=2*math.abs(a.RightVector:Dot(axis))+4*math.abs(a.LookVector:Dot(axis))
    +2*math.abs(b.RightVector:Dot(axis))+4*math.abs(b.LookVector:Dot(axis))
   if math.abs(delta:Dot(axis))>=extent-.01 then touching=false;break end
  end
  if touching then overlaps+=1 end
 end
 if parked==1 and arrived==1 then break end
end
f.follower.forget(lead.model);f.destroy()
assert(parked==1,"the leader never reached its parking destination")
assert(arrived==1 and aborted==0,"the queue behind never cleared")
assert(overlaps==0,"the parking turn crossed the following car's body")
return {parked=parked,arrived=arrived,aborted=aborted,overlaps=overlaps}
]====],"ParkingMovementRegression"))
			run()
		end)
	end)

	describe("Production vehicle parking integration",function()
		it("parks and clears traffic using actual VehicleFactory templates",function()
			local run=assert(loadstring([====[-- Verified Studio Edit runner. Uses fresh live module sources.
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end

local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local function add(net, a, b, kind)
 local d=b-a; return net:addSegment(a,a+d/3,a+d*2/3,b,kind)
end


local net=RoadNetwork.new()
add(net,Vector3.zero,Vector3.new(200,0,0),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local lane=graph:GetEdges()[1]
local f=fixture(graph,net,fresh)
local lead=f.car("parking",lane.id,60,0)
local rear=f.car("following",lane.id,48,0)
lead.model:PivotTo(lead.smoothCFrame)
f.d.drivers[lead.model]=nil;f.d.reindex()
local Factory=fresh(game.ServerScriptService.Services.NPC.VehicleFactory)
for i,state in {lead,rear} do
 local old=state.model
 local parent=old.Parent
 f.d.drivers[old]=nil;f.follower.forget(old)
 local vehicle=Factory.build(state.model.Name,i)
 vehicle.Parent=parent
 vehicle:PivotTo(state.smoothCFrame)
 state.model=vehicle
 state.halfLength=math.max(vehicle:GetExtentsSize().X,vehicle:GetExtentsSize().Z)*.5
 f.follower.place(state,state.smoothCFrame.Position,state.smoothCFrame.LookVector,0)
 old:Destroy()
end
f.d.reindex()
local citizenSource=game.ServerScriptService.Services.City.Simulation.CitizenService.Source
local function section(name)
 local first=assert(citizenSource:find("local function "..name.."(",1,true))
 local last=assert(citizenSource:find("\nend",first,true))
 return citizenSource:sub(first,last+4)
end
local env=setmetatable({PathFollower=f.follower,Cars={movementOrder=0,LOT_STANDOFF_CLEARANCE=.05,LOT_STANDOFF_SECONDS=4},_trips={},_tripCount=0,CAR_HEIGHT=0},{__index=getfenv()})
local body=assert(loadstring(section("lineFollow").."\n"..section("stepTrips").."\nreturn {follow=lineFollow,step=stepTrips}"))
setfenv(body,env);local citizen=body()
local parked,arrived,aborted=0,0,0
local pos=lead.smoothCFrame.Position
local goal=f.follower.pointAtDist(lane.points,lane._cum,160)
f.d.api.ReleaseDirected(rear.model)
assert(f.d.api.DriveDirected(rear.model,rear.smoothCFrame.Position,goal,{lane.id},function()arrived+=1 end,function()aborted+=1 end,48))
citizen.follow(lead.model,{pos,pos+Vector3.new(0,0,30)},12,function()parked+=1 end,0,
 function()return f.d.api.RoadGapClear(pos,3,lead.model,true)end,true)
local overlaps=0
for tick=1,600 do
 citizen.step(.05)
 f.d.clock(.05);f.d.reindex()
 local road=f.d.drivers[rear.model]
 if road then f.d.step(road,.05);f.d.reindex() end
 local localTrip=env._trips[lead.model]
 road=f.d.drivers[rear.model]
 if localTrip and localTrip.smoothCFrame and road and road.smoothCFrame then
  local a,b=localTrip.smoothCFrame,road.smoothCFrame
  local delta=b.Position-a.Position;local touching=true
  for _,axis in {a.RightVector,a.LookVector,b.RightVector,b.LookVector} do
   local as=lead.model:GetExtentsSize();local bs=rear.model:GetExtentsSize()
   local aw=math.min(as.X,as.Z)*.5;local bw=math.min(bs.X,bs.Z)*.5
   local extent=aw*math.abs(a.RightVector:Dot(axis))+lead.halfLength*math.abs(a.LookVector:Dot(axis))
    +bw*math.abs(b.RightVector:Dot(axis))+road.halfLength*math.abs(b.LookVector:Dot(axis))
   if math.abs(delta:Dot(axis))>=extent-.01 then touching=false;break end
  end
  if touching then overlaps+=1 end
 end
 if parked==1 and arrived==1 then break end
end
f.follower.forget(lead.model);f.destroy()
assert(parked==1,"the leader never reached its parking destination")
assert(arrived==1 and aborted==0,"the queue behind never cleared")
assert(overlaps==0,"the parking turn crossed the following car's body")
return {parked=parked,arrived=arrived,aborted=aborted,overlaps=overlaps}
]====],"RealVehicleParkingRegression"))
			run()
		end)
	end)

	describe("driver route integrity", function()
		it("reserves the visible body length even when the hitbox is smaller", function()
			local f=fixture();local s=f.car("truck","a",30)
			function s.model:GetExtentsSize() return Vector3.new(6,3,18) end
			function s.model:FindFirstChild(name)
				if name=="Hitbox" then return {Size=Vector3.new(4,3,8),IsA=function(_,kind)return kind=="BasePart" end} end
				return nil
			end
			f.d.drivers[s.model]=nil
			expect(f.d.api.DriveDirected(s.model,Vector3.new(30,0,0),Vector3.new(190,0,0),{"a","b"},nil,nil,30)).to.equal(true)
			expect(f.d.drivers[s.model].halfLength).to.equal(9)
		end)

		it("seats a genuinely new reverse-lane driver before its first collision check", function()
			local f=fixture()
			f.edge("reverse",Vector3.new(0,0,100),Vector3.zero,6,7)
			local s=f.car("new","reverse",30)
			f.d.drivers[s.model]=nil
			s.model:PivotTo(CFrame.new(999,0,999))
			expect(f.d.api.DriveDirected(s.model,Vector3.new(0,0,70),Vector3.new(0,0,10),{"reverse"},nil,nil,30)).to.equal(true)
			local pose=f.d.api.GetLivePose(s.model)
			assert(pose,"new driver has no pose before its first tick")
			expect(pose.LookVector:Dot(-Vector3.zAxis)>0.99).to.equal(true)
			expect(math.abs(pose.Position.Z-70)<0.001).to.equal(true)
		end)

		it("restores a car before the stop line with the lane's direction", function()
			local f=fixture(); local s=f.car("reload","a",100)
			local seat,dist=f.d.api.GetRestoreSeat(s.model,{edgeId="a",dist=100})
			assert(seat and dist and dist<98.5)
			expect(seat.LookVector:Dot(Vector3.xAxis)>0.99).to.equal(true)
		end)
		it("preserves a valid mid-lane restored position", function()
			local f=fixture(); local s=f.car("reload","a",30)
			local seat,dist=f.d.api.GetRestoreSeat(s.model,{edgeId="a",dist=30})
			expect(dist).to.equal(30); expect(math.abs(seat.Position.X-30)<0.001).to.equal(true)
		end)

		it("advances the route over a zero-length connector", function()
			local f = fixture(); local s = f.car("one", "a", 100)
			s.route = { "a", "b" }; s.routeIndex = 1
			f.d.connect(s, { Vector3.new(100, 0, 0), Vector3.new(100, 0, 0) }, "b", 7)
			expect(s.edgeId).to.equal("b"); expect(s.edgeDist).to.equal(7); expect(s.routeIndex).to.equal(2)
		end)
		it("never turns a broken directed route into random driving", function()
			local f = fixture(); local s = f.car("one", "a", 90)
			s.route = { "a", "missing" }; s.routeIndex = 1
			expect(f.d.pending(f.g, s, f.edges.a)).to.equal(nil)
		end)
		it("rejects disconnected directed routes before registering a trip", function()
			local f = fixture(); local s = f.car("one", "a", 0); f.edges.a.out = {}
			f.d.drivers[s.model] = nil
			expect(f.d.api.DriveDirected(s.model, Vector3.zero, Vector3.new(190, 0, 0), { "a", "b" })).to.equal(false)
			expect(f.d.api.IsDirected(s.model)).to.equal(false)
		end)
		it("rejects vehicle-restricted routes", function()
			local f = fixture(); local s = f.car("one", "a", 0); f.edges.b.allowedVehicles = { Bus = true }
			expect(f.d.api.DriveDirected(s.model, Vector3.zero, Vector3.new(190, 0, 0), { "a", "b" })).to.equal(false)
		end)
		it("does not let ambient or cached choices bypass vehicle restrictions", function()
			local f = fixture(); local s = f.car("one", "a", 90); f.edges.b.allowedVehicles = { Bus = true }
			s.pendingNextEdgeId = "b"; expect(f.d.pending(f.g, s, f.edges.a)).to.equal(nil)
			s.pendingNextEdgeId = nil; expect(f.d.pending(f.g, s, f.edges.a)).to.equal(nil)
		end)
		it("cannot U-turn onto a connection absent from the legal graph", function()
			local f = fixture(); local s = f.car("one", "a", 100)
			f.d.metadata[2].uTurnFallback = f.edges.b; f.d.metadata[2].uTurnByLane = { f.edges.b }
			f.edges.a.out = {}
			expect(f.d.uturn(f.g, f.edges.a, s.vehicleClass)).to.equal(nil)
		end)
		it("keeps a closed road at its endpoint without looping to its start", function()
			local f = fixture(); local s = f.car("one", "a", 100); f.edges.a.out = {}
			f.d.metadata[2].uTurnByLane = {}; s.atDeadEnd = true
			f.d.step(s, 0.1); expect(s.edgeDist).to.equal(100); expect(s.atDeadEnd).to.equal(true)
		end)
		it("does not re-seat a failed reroute onto a neighbouring lane", function()
			local f = fixture(); local s = f.car("one", "a", 30)
			s.goalPos = Vector3.new(190, 0, 0); f.g.unanchored = { "b" }
			expect(f.d.reroute(s)).to.equal(false); expect(s.edgeId).to.equal("a"); expect(s.edgeDist).to.equal(30)
		end)
		it("replans a removed next turn before the current lane moves", function()
			local f = fixture(); local s = f.car("one", "a", 30)
			s.route = { "a", "missing" }; s.routeIndex = 1; s.goalPos = Vector3.new(190, 0, 0)
			f.g.replanned = { "a", "b" }; f.d.step(s, 0.1)
			expect(s.route[2]).to.equal("b"); expect(s.edgeDist).to.equal(30); expect(f.g.lastAnchor.edgeId).to.equal("a")
		end)
		it("aborts an unroutable changed trip once without reporting arrival", function()
			local f = fixture(); local s = f.car("one", "a", 30); local aborted, arrived = 0, 0
			s.route = { "a", "missing" }; s.routeIndex = 1; s.goalPos = Vector3.new(190, 0, 0)
			s.onAbort = function() aborted += 1 end; s.onArrive = function() arrived += 1 end
			f.d.step(s, 0.1); expect(aborted).to.equal(1); expect(arrived).to.equal(0); expect(f.d.drivers[s.model]).to.equal(nil)
		end)
		it("projects graded lanes using their full path distance", function()
			local f = fixture(); local e = f.edge("hill", Vector3.zero, Vector3.new(80, 60, 0), 4, 5)
			expect(math.abs(f.d.project(e, Vector3.new(40, 30, 0)) - 50) < 1e-6).to.equal(true)
		end)
	end)

	describe("junction permission and real occupancy", function()
		it("does not reserve the whole junction for a stopped car beyond a different stop line", function()
			local f = fixture()
			f.edge("cross", Vector3.new(110, 0, -50), Vector3.new(110, 0, 50), 4, 2, 4)
			f.edge("crossOut", Vector3.new(110, 0, 50), Vector3.new(110, 0, 150), 2, 5, 5)
			f.link("cross", "crossOut")
			f.g.connector = { Vector3.new(100, 0, 0), Vector3.new(120, 0, 0) }
			local mine = f.car("mine", "a", 90); mine.pendingNextEdgeId = "b"
			local other = f.car("other", "cross", 100); other.pendingNextEdgeId = "crossOut"
			f.d.metadata[2].isIntersection = true; f.signals.enabled = true
			f.d.reindex()
			expect(f.d.enter(f.g, mine, f.edges.a, "b")).to.equal(true)
		end)
		it("still blocks a stopped crossing body on the intended junction path", function()
			local f = fixture()
			f.edge("cross", Vector3.new(110, 0, -100), Vector3.new(110, 0, 0), 4, 2, 4)
			f.edge("crossOut", Vector3.new(110, 0, 0), Vector3.new(110, 0, 100), 2, 5, 5)
			f.link("cross", "crossOut")
			f.g.connector = { Vector3.new(100, 0, 0), Vector3.new(120, 0, 0) }
			local mine = f.car("mine", "a", 90); mine.pendingNextEdgeId = "b"
			local other = f.car("other", "cross", 100); other.pendingNextEdgeId = "crossOut"
			f.d.metadata[2].isIntersection = true; f.signals.enabled = true
			f.d.reindex()
			expect(f.d.enter(f.g, mine, f.edges.a, "b")).to.equal(false)
		end)

		it("never runs a long red or lets watchdog recovery bypass it", function()
			local f = fixture(); local s = f.car("one", "a", 90)
			f.d.metadata[2].isIntersection = true; f.signals.enabled = true; f.signals.green = false
			s.redTime = 1000; expect(f.d.enter(f.g, s, f.edges.a, "b")).to.equal(false)
			s.rescueFrom = Vector3.zero; expect(f.d.enter(f.g, s, f.edges.a, "b")).to.equal(false)
		end)
		it("yields to circulating traffic regardless of waiting time", function()
			local f = fixture(); local s = f.car("one", "a", 90); s.blockedTime = 100
			f.d.metadata[2].isIntersection = true; f.edges.b.isRoundabout = true
			local e = f.edge("ring", Vector3.new(100, 0, -100), Vector3.new(100, 0, 0), 4, 2, 4); e.isRoundabout = true
			f.car("ringcar", "ring", 95, 10); f.d.reindex()
			expect(f.d.enter(f.g, s, f.edges.a, "b")).to.equal(false)
		end)
		it("a long wait does not pull a minor road in front of moving major traffic", function()
			local f = fixture(); local s = f.car("one", "a", 90); s.blockedTime = 100
			f.d.metadata[2].isIntersection = true; f.d.metadata[2].mainSegs = { [4] = true }
			f.edge("cross", Vector3.new(100, 0, -100), Vector3.new(100, 0, 0), 4, 2, 4)
			f.car("crosscar", "cross", 90, 20); f.d.reindex()
			expect(f.d.enter(f.g, s, f.edges.a, "b")).to.equal(false)
		end)
		it("U-turns conflict with approaching oncoming through traffic", function()
			local f = fixture()
			expect(f.d.conflict(Vector3.xAxis, "uturn", { toDir = -Vector3.xAxis }, "straight")).to.equal(true)
		end)
		it("a car requesting a merge is not already occupying the exit", function()
			local f = fixture(); local s = f.car("one", "a", 90)
			f.edge("side", Vector3.new(100, 0, 8), Vector3.new(200, 0, 8), 2, 3, 2)
			local other = f.car("merger", "side", 0); other.mergeInto = "b"; f.d.reindex()
			expect(f.d.exitRoom(f.g, s, "b")).to.equal(true)
		end)
		it("counts a lane-changing car once when reserving downstream queue space", function()
			local f = fixture(); local s = f.car("one", "a", 90); f.g.landing = 8
			f.car("wall", "b", 30, 0)
			f.edge("side", Vector3.new(100, 0, 8), Vector3.new(200, 0, 8), 2, 3, 2)
			local other = f.car("merger", "side", 20, 10)
			other.connector = { Vector3.new(100, 0, 8), Vector3.new(130, 0, 0) }; other.connCum = { 0, 30 }
			other.nextEdgeId = "b"; other.nextEdgeDist = 30; other.connDist = 15
			other.laneChange = { pts = other.connector, from = "side", to = "b", d0 = 10, d1 = 30 }
			f.d.reindex(); expect(f.d.exitRoom(f.g, s, "b")).to.equal(true)
		end)
		it("still holds for a full exit and includes long vehicle bodies", function()
			local f = fixture(); local s = f.car("one", "a", 90); s.halfLength = 12
			local wall = f.car("bus", "b", 25, 0); wall.halfLength = 12
			f.g.landing = 5; f.d.reindex(); expect(f.d.exitRoom(f.g, s, "b")).to.equal(false)
		end)
		it("allows a free intersection immediately", function()
			local f = fixture(); local s = f.car("one", "a", 90)
			f.d.metadata[2].isIntersection = true; expect(f.d.enter(f.g, s, f.edges.a, "b")).to.equal(true)
		end)
	end)

	describe("stepped traffic scenarios", function()
		it("never rescues a queue through a registered parking vehicle", function()
			local f = fixture(); local s = f.car("one", "a", 20); local parked = f.car("parked", "a", 29)
			f.d.drivers[parked.model] = nil; f.follower.isRegistered = function(m) return m == parked.model end
			s.blockedBy = parked.model; s.noProgressTime = 59; s.lastProgressPos = s.smoothCFrame.Position
			f.d.watchdog(s, 2); expect(s.rescueFrom).to.equal(nil); expect(s.noProgressTime).to.equal(0)
		end)
		it("finishes a trip already at its destination even with zero clearance", function()
			local f = fixture(); local s = f.car("one", "b", 80); local arrived = 0
			s.route = { "b" }; s.routeIndex = 1; s.finalDist = 80; s.onArrive = function() arrived += 1 end
			f.follower.getMotionLimits = function() return 0, 0, 1, nil end
			f.d.step(s, 0.1); expect(arrived).to.equal(1); expect(f.d.drivers[s.model]).to.equal(nil)
		end)
		it("holds a banned-exit vehicle before the junction and resumes after reopening", function()
			local f = fixture(); local s = f.car("one", "a", 30)
			f.d.metadata[2].isIntersection = true; f.edges.a.out = {}; f.d.reindex()
			for _ = 1, 400 do f.d.step(s, 0.1); f.d.reindex() end
			expect(s.edgeId).to.equal("a"); expect(s.edgeDist <= 95).to.equal(true)
			f.link("a", "b")
			for _ = 1, 60 do f.d.step(s, 0.1); f.d.reindex() end
			expect(s.edgeId).to.equal("b")
		end)
		for _, dt in { 0.05, 0.25, 0.5 } do
			it("holds a red and resumes to exactly one arrival at dt=" .. dt, function()
				local f = fixture(); local seed = f.car("one", "a", 30); f.d.drivers[seed.model] = nil
				local arrived, aborted = 0, 0
				expect(f.d.api.DriveDirected(seed.model, Vector3.new(30, 0, 0), Vector3.new(190, 0, 0), { "a", "b" },
					function() arrived += 1 end, function() aborted += 1 end)).to.equal(true)
				local s = f.d.drivers[seed.model]; s.smoothCFrame = seed.smoothCFrame
				f.d.metadata[2].isIntersection = true; f.signals.enabled = true; f.signals.green = false; f.d.reindex()
				for _ = 1, math.ceil(210 / dt) do f.d.step(s, dt); f.d.reindex() end
				expect(s.edgeId).to.equal("a"); expect(s.edgeDist <= 95).to.equal(true); expect(arrived).to.equal(0)
				f.signals.green = true
				for _ = 1, math.ceil(40 / dt) do if f.d.drivers[s.model] then f.d.step(s, dt); f.d.reindex() end end
				expect(arrived).to.equal(1); expect(aborted).to.equal(0)
			end)
			it("preserves a real queue for minutes and releases it at dt=" .. dt, function()
				local f = fixture(); local s = f.car("one", "a", 20); local lead = f.car("lead", "a", 50)
				f.d.reindex()
				for _ = 1, math.ceil(180 / dt) do f.d.step(s, dt); f.d.watchdog(s, dt); f.d.reindex() end
				expect(s.edgeDist <= lead.edgeDist - 9 + 1e-4).to.equal(true)
				expect(f.d.drivers[s.model]).to.equal(s); expect(s.rescueFrom).to.equal(nil)
				f.d.drivers[lead.model] = nil; lead.model.Parent = nil; f.d.reindex()
				for _ = 1, math.ceil(2 / dt) do f.d.step(s, dt); f.d.reindex() end
				expect(s.edgeDist > 45).to.equal(true)
			end)
		end
	end)
	describe("Gridlock breakers (2026-10-04)",function()
		local function extract(name: string, extra: string?): string
			local source=driverModule.Source
			local first=assert(source:find(name,1,true),name)
			local last=assert(source:find("\nend\n",first,true))
			return source:sub(first,last+4)..(extra or "")
		end
		it("an empty link shorter than one car still takes one car at a time",function()
			local chunk=extract("local function exitLaneHasRoom(","\nreturn exitLaneHasRoom")
			local link={id="link",length=23,toNode=2,out={},isRoundabout=false}
			local index:any={}
			local env=setmetatable({
				_edgeDriverIndex=index,_connectorByNextEdgeIndex={},_laneChangeIndex={},EMPTY={},
				laneChangeOf=function()return nil end,lanePos=function(o)return o.edgeDist end,
				followGap=function()return 9 end,FOLLOW_MIN_GAP=8,STOP_LINE_CAR_BUFFER=1.5,
				Tuning={EXIT_STOPPED_SPEED=4},isIntersectionNode=function(_,node)return node==2 end,
				getStopLineGap=function()return 10 end,
			},{__index=getfenv()})
			local fn=assert(loadstring(chunk));setfenv(fn,env)
			local exitLaneHasRoom=fn()
			local g={GetEdge=function(_,id)return if id=="link" then link else nil end,GetConnectionSetbacks=function()return 0,11 end}
			local me={edgeId="in",halfLength=4,model={Parent=true}}
			expect(exitLaneHasRoom(g,me,"link")).to.equal(true)
			index.link={{edgeDist=5,currentSpeed=10,halfLength=4,model={Parent=true}}}
			expect(exitLaneHasRoom(g,me,"link")).to.equal(false)
			index.link={{edgeDist=8,currentSpeed=0,halfLength=4,model={Parent=true}}}
			expect(exitLaneHasRoom(g,me,"link")).to.equal(false)
		end)
		it("a moving box car stops holding the line once its tail has passed our path",function()
			local segs=extract("local function pointSegmentDistanceSq(")..extract("local function segmentsNear(")
			local chunk=segs..extract("function Gridlock.conflictEnd(")..extract("function Gridlock.hasCleared(","\nreturn Gridlock")
			local meta={}
			local env=setmetatable({Gridlock={},Tuning={MOVEMENT_PATH_CLEAR=4.5},STOP_LINE_CAR_BUFFER=1.5,
				getNodeMeta=function()return meta end,laneChangeOf=function()return nil end},{__index=getfenv()})
			local fn=assert(loadstring(chunk));setfenv(fn,env)
			local Gridlock=fn()
			local g={Version=function()return 1 end,GetConnectionPoints=function()return {Vector3.new(0,0,-10),Vector3.new(0,0,30)} end}
			local edge={id="mine",toNode=1}
			local other={edgeId="cross",nextEdgeId="away",halfLength=4,currentSpeed=10,
				connector={Vector3.new(-10,0,10),Vector3.new(10,0,10),Vector3.new(30,0,10)},connCum={0,20,40},connDist=22}
			expect(Gridlock.hasCleared(g,edge,"out",other)).to.equal(false) -- tail at 18, crossing ends at 20
			other.connDist=26
			expect(Gridlock.hasCleared(g,edge,"out",other)).to.equal(true)
			other.currentSpeed=0
			expect(Gridlock.hasCleared(g,edge,"out",other)).to.equal(false) -- a stopped car is blocksMyPath's
		end)
		it("a driveway gap request holds the first car that can stop and lets the driveway car in",function()
			local run=assert(loadstring([====[
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end
local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local net=RoadNetwork.new()
net:addSegment(Vector3.new(0,0,0),Vector3.new(100,0,0),Vector3.new(200,0,0),Vector3.new(300,0,0),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local lane=graph:GetEdges()[1]
local f=fixture(graph,net,fresh)
local car=f.car("approaching",lane.id,10,15)
local drive=Instance.new("Model");drive.Name="driveway"
local hb=Instance.new("Part");hb.Name="Hitbox";hb.Size=Vector3.new(4,3,8);hb.Anchored=true;hb.Parent=drive
drive.PrimaryPart=hb;drive.Parent=car.model.Parent
local spot=f.follower.pointAtDist(lane.points,f.follower.getCum(lane),150)
f.d.reindex()
for _=1,200 do
 f.d.api.RequestRoadGap(drive,spot,lane.id)
 f.d.clock(.05);f.d.step(car,.05);f.d.reindex()
end
local held=car.edgeDist
local clear=f.d.api.RoadGapClear(spot,3,drive,nil,lane.id)
f.d.api.ClearRoadGap(drive)
for _=1,100 do f.d.clock(.05);f.d.step(car,.05);f.d.reindex() end
local after=car.edgeDist
f.destroy()
return {held=held,clear=clear,after=after}
]====],"DrivewayGapRegression"))
			local r=run()
			expect(r.held<150-14).to.equal(true) -- did not drive into the gap
			expect(r.held>100).to.equal(true)    -- held near it, not far back
			expect(r.clear).to.equal(true)       -- and the gap it left lets the driveway car in
			expect(r.after>r.held+20).to.equal(true) -- drives on once the request is withdrawn
		end)
		it("two cars crossing the road from neighbouring spots both get out",function()
			local run=assert(loadstring([====[
local cache = {}
local function fresh(module)
 if module == game.ReplicatedStorage.Networker then return {SyncNpcPoses={FireClient=function() error('Unexpected network send in isolated test') end}} end
 if cache[module] ~= nil then return cache[module] end
 local fn, why = loadstring(module.Source, "=" .. module:GetFullName())
 assert(fn, why)
 local isolatedWorkspace = if module.Name == "RoadRules" then {
 GetAttribute = function() return "Right" end,
 GetAttributeChangedSignal = function() return {Connect = function() return {Disconnect = function() end} end} end,
 SetAttribute = function() end,
} else workspace
 local env = setmetatable({script = module, require = fresh, workspace = isolatedWorkspace}, {__index = getfenv()})
 setfenv(fn, env)
 local result = fn()
 cache[module] = result
 return result
end
local RoadNetwork = fresh(game.ReplicatedStorage.Road.RoadNetwork)
local Graph = fresh(game.ReplicatedStorage.Road.RoadNavigationGraph)
local fixture = fresh(game.ServerScriptService.Services.NPC.NPCDriverService.IntegrationFixture)
local net=RoadNetwork.new()
net:addSegment(Vector3.new(0,0,0),Vector3.new(100,0,0),Vector3.new(200,0,0),Vector3.new(300,0,0),"NarrowRoad")
local graph=Graph.new();graph:Rebuild(net,{})
local L=graph:GetEdges()[1]
local M
for _,e in graph:GetEdges() do if e.forward~=L.forward then M=e end end
local f=fixture(graph,net,fresh)
local function driveway(name)
 local m=Instance.new("Model");m.Name=name
 local hb=Instance.new("Part");hb.Name="Hitbox";hb.Size=Vector3.new(4,3,8);hb.Anchored=true;hb.Parent=m
 m.PrimaryPart=hb;return m
end
local function step(cars,asks)
 for _,a in asks do f.d.api.RequestRoadGap(a[1],a[2],nil) end
 f.d.clock(.05)
 for _,c in cars do f.d.step(c,.05) end
 f.d.reindex()
end
-- Two cars about to cross the whole road from neighbouring spots.
local carL=f.car("onL",L.id,10,15)
local A=driveway("crossA");A.Parent=carL.model.Parent
local spotA=f.follower.pointAtDist(L.points,f.follower.getCum(L),150)
f.d.reindex()
for _=1,200 do step({carL},{{A,spotA}}) end
local stopL=carL.edgeDist -- where A's request holds lane L
f.d.api.ClearRoadGap(A)
-- B stands right where A's lane-L holder stands; a lane-M car is held by B's request.
local B=driveway("crossB");B.Parent=carL.model.Parent
local spotB=f.follower.pointAtDist(L.points,f.follower.getCum(L),stopL)
local carM=f.car("onM",M.id,10,15)
f.d.reindex()
for _=1,200 do step({carM},{{B,spotB}}) end
local mX=f.follower.pointAtDist(M.points,f.follower.getCum(M),carM.edgeDist).X
-- Both ask at once, A first (as it would have, having waited longer).
local clearA,clearB=false,false
local tA,tB
for i=1,800 do
 local asks={}
 if not clearA then table.insert(asks,{A,spotA}) end
 if not clearB then table.insert(asks,{B,spotB}) end
 step({carL,carM},asks)
 -- a car whose gap opened pulls out and stops asking
 if not clearA and f.d.api.RoadGapClear(spotA,3,A) then clearA=true;tA=i*.05;f.d.api.ClearRoadGap(A) end
 if not clearB and f.d.api.RoadGapClear(spotB,3,B) then clearB=true;tB=i*.05;f.d.api.ClearRoadGap(B) end
 if clearA and clearB then break end
end
local res={tA=tA,tB=tB,stopL=stopL,spotAX=spotA.X,spotBX=spotB.X,carMX=mX,clearA=clearA,clearB=clearB,
 carLspeed=carL.currentSpeed,carMspeed=carM.currentSpeed,carLreason=carL.stopReason,carMreason=carM.stopReason}
f.destroy()
return res
]====],"CrossingGapDeadlock"))
			local r=run()
			-- each request used to hold a car right over the other spot: neither ever cleared
			expect(r.clearA).to.equal(true)
			expect(r.clearB).to.equal(true)
		end)
	end)
end

