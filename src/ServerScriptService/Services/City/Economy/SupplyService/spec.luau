--!strict
-- Isolated freight lifecycle regressions; never starts the city or touches persistence.
return function()
 local subject = script.Parent
 local function fixture()
  local folder=Instance.new("Folder")
  local calls, registered={},{}
  local graph:any={available=true}
  function graph:HasEdges() return true end
  function graph:FindPath(a,b) if not self.available then return nil end return {a,b},{"lane"} end
  function graph:GetOutgoingEdgesFromNode() return {{points={Vector3.zero,Vector3.new(0,0,100)}}} end
  function graph:NearestEdgeToward() return {edge={points={Vector3.zero,Vector3.new(0,0,100)}}} end
  local driver:any={accept=true,gapClear=true}
  function driver.RoadGapClear() return driver.gapClear end
  function driver.DriveDirected(model,src,dst,route,arrive,abort)
   table.insert(calls,{model=model,src=src,dst=dst,arrive=arrive,abort=abort})
   return driver.accept
  end
  function driver.ReleaseDirected() return true end
  function driver.LaneEntryPath() return nil end
  function driver.GetLaneAnchor() return nil end
  local follower:any={clearance=math.huge}
  function follower.forget(m) registered[m]=nil end
  function follower.place(s,pos,dir) registered[s.model]=true end
  function follower.getMotionLimits() return 1,follower.clearance end
  local factory={RIDE_CLEARANCE=0,build=function(name)
   local m=Instance.new("Model");m.Name=name
   local p=Instance.new("Part");p.Anchored=true;p.Size=Vector3.new(4,3,8);p.Parent=m;m.PrimaryPart=p
   return m
  end}
  local function fresh(m)
   local fn=assert(loadstring(m.Source))
   setfenv(fn,setmetatable({script=m,require=fresh},{__index=getfenv()}))
   return fn()
  end
  local const=fresh(subject.Parent.Parent.CitySimConstants)
  local modules={GameSpeed={get=function()return 1 end,steps=function()return 1 end},PathFollower=follower,VehicleFactory=factory,CitySimConstants=const,
   NPCDriverService=driver,VehicleTypes={Truck="Truck"},
   VehicleCatalog={forClass=function()return {}end,roll=function()return .5 end}}
  local body=subject.Source:gsub("return SupplyService%s*$",[[return {
   api=SupplyService,dispatch=dispatch,import=dispatchImport,export=dispatchExport,step=stepTrucks,produce=produceAndDispatch,
   demand=function(id,n) _demand[id]=n end,
   setup=function(b,r,f,o) _buildingService=b;_roadService=r;_folder=f;_outsideConnService=o;_warehouse.plant=100 end,
   state=function()return {warehouse=_warehouse,shelf=_shelf,inbound=_inbound,trucks=_trucks,busy=_busyTrucks,count=_truckCount}end,
  }]])
  local fn=assert(loadstring(body))
  setfenv(fn,setmetatable({script=subject,require=function(m)return assert(modules[m.Name],m.Name)end},{__index=getfenv()}))
  local s=fn()
  s.api.SetCitizenService({getWorkerCount=function()return 30 end})
  local buildings={getKerb=function(id)return if id=="plant" then Vector3.zero else Vector3.new(0,0,100)end,
   listBuildings=function()return {}end,setSupplyInfo=function()end}
  s.setup(buildings,{getNavigationGraph=function()return graph end},folder,
   {list=function()return {{id=1,nodeId=1,dir="both",outer=Vector3.zero,normal=Vector3.zAxis}}end})
  return {folder=folder,s=s,calls=calls,driver=driver,graph=graph,registered=registered,follower=follower,buildings=buildings,
   clean=function()s.api.clear();folder:Destroy()end}
 end
 local function check(name,run)
  it(name,function()
   local f=fixture()
   local ok,err=pcall(run,f)
   f.clean()
   assert(ok,err)
  end)
 end


 describe("Failed road admission",function()
  check("a successful retry is not restarted on later supply ticks",function(f)
   f.driver.accept=false
   assert(f.s.dispatch("plant","shop",20))
   f.driver.accept=true;f.s.step(11)
   local count=#f.calls
   for _=1,20 do f.s.step(.1) end
   assert(#f.calls==count,"successful road trip was reset by the expired retry timer")
   f.calls[count].arrive();f.s.step(100)
   assert(f.s.state().shelf.shop==20,"recovered trip failed to deliver exactly once")
  end)

  check("a rejected launch keeps cargo but occupies neither the road nor its visual fleet",function(f)
   f.driver.accept=false
   assert(f.s.dispatch("plant","shop",20))
   local m=f.calls[1].model
   assert(not f.registered[m],"rejected truck became a permanent road blocker")
   assert(m.Parent~=f.folder,"rejected truck stayed visible on the road")
   assert(f.s.state().inbound.shop==20 and f.s.state().warehouse.plant==80)
   f.driver.accept=true;f.s.step(11)
   assert(m.Parent==f.folder,"successful retry did not return to the fleet")
   f.calls[#f.calls].arrive();f.s.step(100)
   assert(f.s.state().shelf.shop==20,"retry lost or duplicated cargo")
  end)
 end)

 describe("Freight pose persistence",function()
  check("saves the simulated truck position instead of its stationary server spawn pivot",function(f)
   f.buildings.listBuildings=function()return {{bpId="plant",saveKey="plant-key"},{bpId="shop",saveKey="shop-key"}}end
   assert(f.s.dispatch("plant","shop",20))
   f.driver.GetLivePose=function()return CFrame.new(41,8,73)end
   local saved=f.s.api.serialize()
   assert(saved and saved.trucks[1][1]==41 and saved.trucks[1][3]==73,"saved truck jumped back to its spawn point")
  end)
 end)

 describe("Vehicle reset cargo accounting",function()
  check("canceled domestic and export loads return to their factory without sales",function(f)
   assert(f.s.dispatch("plant","shop",20))
   assert(f.s.export("plant",20))
   assert(f.s.state().warehouse.plant==60)
   assert(f.s.api.ResetVehicles()==2)
   assert(f.s.state().warehouse.plant==100 and next(f.s.state().inbound)==nil)
   assert(f.s.state().count==0 and f.s.state().busy==0)
   for _,call in f.calls do call.arrive();call.abort() end
   assert(next(f.s.state().shelf)==nil,"stale callback delivered canceled cargo")
   assert(f.s.state().warehouse.plant==100)
   assert(f.s.api.ResetVehicles()==0)
  end)
  check("an undelivered import is refunded exactly once",function(f)
   assert(f.s.import("shop",20))
   local charged=f.s.api.drainGoodsRevenue()
   assert(charged<0,"import was not charged")
   assert(f.s.api.ResetVehicles()==1)
   local refund=f.s.api.drainGoodsRevenue()
   assert(refund==-charged,"canceled import did not refund its cost")
   assert(f.s.api.ResetVehicles()==0 and f.s.api.drainGoodsRevenue()==0)
   assert(next(f.s.state().shelf)==nil)
  end)
  check("resetting a delivered empty truck preserves shelf goods and grants no refund",function(f)
   assert(f.s.import("shop",20))
   assert(f.s.api.drainGoodsRevenue()<0)
   f.calls[1].arrive()
   f.s.step(100)
   local stock=f.s.state().shelf.shop
   assert(stock==20)
   f.s.api.ResetVehicles()
   assert(f.s.state().shelf.shop==stock and f.s.api.drainGoodsRevenue()==0)
  end)
 end)

 describe("Trade border reachability",function()
  local function border(inbound: boolean, available: boolean): any
   local env: any=setmetatable({
    VehicleTypes={Truck="Truck"}, calls=0,spendRoute=function() return true end,borderQueue=function()return 0 end,
    Const={SUPPLY_BORDER_QUEUE_COST=400},
    _outsideConnService={list=function() return {
     {id=1,dir="both",outer=Vector3.new(10,0,0)},
     {id=2,dir="both",outer=Vector3.new(100,0,0)},
    } end},
   },{__index=getfenv()})
   env.nav=function() return {FindPath=function(_,src,dst,_,class)
    assert(class=="Truck")
    env.calls+=1
    local point=if inbound then src else dst
    if available and point.X==100 then return {src,dst},{"reachable"} end
    return nil,nil
   end} end
   env.edgePoint=function(_,c) return c.outer end
   local source=subject.Source
   local a=assert(source:find("local function nearestConnection",1,true))
   local b=assert(source:find("-- One trade truck",a,true))
   local chunk=assert(loadstring(source:sub(a,b-1).."\nreturn nearestConnection"))
   setfenv(chunk,env)
   local conn,point,route=chunk()(Vector3.zero,inbound)
   return conn,point,route,env.calls
  end
  it("exports skip a closer disconnected border",function()
   local conn,point,route,calls=border(false,true)
   assert(conn.id==2 and point.X==100 and route[1]=="reachable" and calls==2)
  end)
  it("imports route inwards through the reachable border",function()
   local conn,point,route,calls=border(true,true)
   assert(conn.id==2 and point.X==100 and route[1]=="reachable" and calls==2)
  end)
  it("no reachable border produces no planned trade",function()
   local conn,point,route=border(false,false)
   assert(conn==nil and point==nil and route==nil)
  end)
 end)

 describe("Freight dispatch queues",function()
  check("production requires real employees and runs independently of the clock hour",function(f)
   f.buildings.listBuildings=function()return {{bpId="plant",zone="Industrial",level=1}}end
   f.graph.available=false
   f.s.api.SetCitizenService({getWorkerCount=function()return 0 end})
   f.s.produce(1440)
   assert(f.s.state().warehouse.plant==100,"unstaffed factory made goods")
   f.s.api.SetCitizenService({getWorkerCount=function()return 5 end})
   f.s.produce(1440)
   assert(f.s.state().warehouse.plant==140,"staffed factory did not make its daily output")
  end)
  check("committed border traffic sends later exports through another reachable gateway",function(f)
   f.s.setup(f.buildings,{getNavigationGraph=function()return f.graph end},f.folder,{
    list=function()return {
     {id=1,nodeId=1,dir="both",outer=Vector3.zero,normal=Vector3.zAxis},
     {id=2,nodeId=2,dir="both",outer=Vector3.new(1000,0,0),normal=Vector3.zAxis},
    }end})
   f.graph.GetOutgoingEdgesFromNode=function(_,node)
    local x=if node==2 then 1000 else 0
    return {{points={Vector3.new(x,0,0),Vector3.new(x,0,100)}}}
   end
   f.graph.NearestEdgeToward=function(_,outer) return {edge={points={outer,outer+Vector3.new(0,0,100)}}} end
   local borders={}
   for i=1,5 do f.s.state().warehouse.plant=100;assert(f.s.export("plant",20));borders[f.calls[i].dst.X]=true end
   assert(borders[0] and borders[1000],"all exports used one gateway")
  end)
  check("every surplus factory gets an export turn beyond the fleet cap",function(f)
   local views={}
   for i=1,66 do
    local id="plant"..i
    views[i]={bpId=id,zone="Industrial",level=3,position=Vector3.new(i,0,0)}
    f.s.state().warehouse[id]=1000
   end
   f.buildings.listBuildings=function() return views end
   local served={}
   for pass=1,6 do
    f.s.produce(1)
    for _,t in f.s.state().trucks do served[t.fromId]=true end
    for _,call in f.calls do call.arrive() end
    table.clear(f.calls)
   end
   local n=0;for _ in served do n+=1 end
   assert(n==66,"factories starved: "..n.."/66")
  end)
  check("planning work is capped even when every border is disconnected",function(f)
   local views={}
   for i=1,100 do local id="plant"..i;views[i]={bpId=id,zone="Industrial",level=3};f.s.state().warehouse[id]=1000 end
   f.buildings.listBuildings=function()return views end
   local searches=0
   f.graph.FindPath=function()searches+=1;return nil end
   f.s.produce(1)
   assert(searches<=24,"unbounded path searches")
   assert(f.s.state().count==0 and f.s.api.drainGoodsRevenue()==0)
  end)
  check("shop imports only after unreachable domestic suppliers are skipped",function(f)
   f.buildings.listBuildings=function()return {
    {bpId="plant",zone="Industrial",level=1,position=Vector3.zero},
    {bpId="shop",zone="Commercial",level=1,position=Vector3.new(0,0,100)},
   }end
   f.graph.FindPath=function(_,a,b) if a==Vector3.zero then return nil end;return {a,b},{"lane"} end
   f.s.produce(1)
   assert(f.s.state().inbound.shop>0,"unreachable local factory blocked imports")
   assert(f.s.state().warehouse.plant>=100,"failed local route removed goods")
   assert(f.s.api.drainGoodsRevenue()<0,"import not charged")
  end)
  check("a farther reachable factory replaces a disconnected nearest supplier",function(f)
   f.buildings.listBuildings=function()return {
    {bpId="plant",zone="Industrial",level=1,position=Vector3.new(0,0,99)},
    {bpId="farPlant",zone="Industrial",level=1,position=Vector3.new(200,0,0)},
    {bpId="shop",zone="Commercial",level=1,position=Vector3.new(0,0,100)},
   }end
   f.s.state().warehouse.farPlant=100
   f.buildings.getKerb=function(id) return if id=="plant" then Vector3.zero elseif id=="farPlant" then Vector3.new(200,0,0) else Vector3.new(0,0,100) end
   f.graph.FindPath=function(_,a,b) if a==Vector3.zero then return nil end;return {a,b},{"lane"} end
   f.s.produce(1)
   assert(f.s.state().inbound.shop==30,"reachable stock not sent")
   assert(f.s.state().warehouse.plant>=100,"disconnected stock removed")
   assert(f.s.state().warehouse.farPlant<100,"farther factory not used")
   assert(f.s.api.drainGoodsRevenue()==0,"imported despite reachable domestic goods")
  end)
  check("reachable domestic goods are preferred over imports",function(f)
   f.buildings.listBuildings=function()return {
    {bpId="plant",zone="Industrial",level=1,position=Vector3.zero},
    {bpId="shop",zone="Commercial",level=1,position=Vector3.new(0,0,100)},
   }end
   f.s.produce(1)
   assert(f.s.state().inbound.shop==30)
   assert(f.s.api.drainGoodsRevenue()==0,"domestic shipment charged import")
  end)
  check("zero forecast still replenishes an empty shop without filling its entire capacity",function(f)
   f.buildings.listBuildings=function()return {{bpId="shop",zone="Commercial",level=3}}end
   f.s.demand("shop",0)
   f.s.produce(1)
   assert(f.s.state().inbound.shop==10,"empty shop never reordered")
   f.s.produce(1)
   assert(f.s.state().inbound.shop==10,"duplicate inbound order")
  end)
 end)

 describe("Freight arrival accounting",function()
  check("a yard truck clears a road vehicle that is waiting for that same truck",function(f)
   f.buildings.getTruckOut=function()return CFrame.new(-10,0,0)end
   f.buildings.getParkSpots=function()return nil end
   local blocker=Instance.new("Model");blocker.Parent=f.folder
   f.driver.IsWaitingForVehicle=function()return true end
   f.follower.getMotionLimits=function(_,_,_,ignored)
    if ignored==blocker then return 1,math.huge,nil,nil end
    return 0,0,0,blocker
   end
   assert(f.s.dispatch("plant","shop",20))
   for _=1,200 do f.s.step(.1)end
   assert(#f.calls==1,"yard and road vehicles stayed in a circular wait")
  end)
  check("yard standoff recovery still holds for a third vehicle",function(f)
   f.buildings.getTruckOut=function()return CFrame.new(-10,0,0)end
   f.buildings.getParkSpots=function()return nil end
   local blocker=Instance.new("Model");blocker.Parent=f.folder
   f.driver.IsWaitingForVehicle=function()return true end
   f.follower.getMotionLimits=function()return 0,0,0,blocker end
   assert(f.s.dispatch("plant","shop",20))
   for _=1,200 do f.s.step(.1)end
   assert(#f.calls==0,"yard truck drove through an unrelated obstruction")
  end)

  check("yard departure cannot cross a blocked clearance even on a long tick",function(f)
   f.buildings.getTruckOut=function()return CFrame.new(-10,0,0)end
   f.buildings.getParkSpots=function()return nil end
   f.follower.clearance=0
   assert(f.s.dispatch("plant","shop",20))
   local truck=next(f.s.state().trucks)
   local before=truck:GetPivot().Position
   f.s.step(60)
   assert((truck:GetPivot().Position-before).Magnitude<.001,"yard truck crossed blocked clearance")
   assert(#f.calls==0,"blocked yard truck started road leg")
   assert(f.registered[truck],"yard truck invisible to other vehicles")
  end)
  check("local route abort cannot deliver goods",function(f)
   assert(f.s.dispatch("plant","shop",20));f.calls[1].abort();f.s.step(60)
   assert(f.s.api.getShelfStock("shop")==0,"aborted local delivery stocked shelf")
   assert(f.s.state().inbound.shop==20,"lost inbound reservation")
  end)
  check("import abort cannot deliver goods",function(f)
   assert(f.s.import("shop",20));f.calls[1].abort();f.s.step(60)
   assert(f.s.api.getShelfStock("shop")==0,"aborted import stocked shelf")
  end)
  check("export abort cannot earn revenue",function(f)
   assert(f.s.export("plant",20));f.calls[1].abort()
   assert(f.s.api.drainGoodsRevenue()==0,"aborted export paid income")
   assert(f.s.state().count==1,"aborted loaded truck disappeared")
  end)
  check("driver rejection holds load without granting arrival",function(f)
   f.driver.accept=false;assert(f.s.dispatch("plant","shop",20));f.s.step(60)
   assert(f.s.api.getShelfStock("shop")==0,"rejected delivery stocked shelf")
  end)
  check("blocked freight leaves the road and retries without duplicate charges",function(f)
   assert(f.s.import("shop",20));local cost=f.s.api.drainGoodsRevenue()
   local truck=f.calls[1].model
   f.calls[1].abort()
   assert(not f.registered[truck] and truck.Parent~=f.folder,"retry truck still obstructs traffic")
   f.graph.available=false;f.s.step(60)
   assert(f.s.state().count==1 and f.s.api.getShelfStock("shop")==0)
   f.graph.available=true;f.s.step(60)
   assert(#f.calls==2,"route was not retried")
   assert(f.s.api.drainGoodsRevenue()==0 and cost==-70,"import price or duplicate billing incorrect")
   f.calls[2].arrive();f.s.step(60)
   assert(f.s.api.getShelfStock("shop")==20)
  end)
  check("successful local unloading delivers exactly once",function(f)
   assert(f.s.dispatch("plant","shop",20));f.calls[1].arrive()
   assert(f.registered[f.calls[1].model],"unloading truck invisible to traffic")
   f.s.step(1);assert(f.s.api.getShelfStock("shop")==0)
   f.s.step(60);f.calls[1].arrive();f.s.step(60)
   assert(f.s.api.getShelfStock("shop")==20)
  end)
  check("successful export is paid once despite duplicate callbacks",function(f)
   assert(f.s.export("plant",20));local cb=f.calls[1].arrive;cb();cb()
   assert(f.s.api.drainGoodsRevenue()==20*2.5)
   assert(f.s.state().count==0 and f.s.state().busy==0)
  end)
  check("callbacks from a cleared city cannot recreate stock or revenue",function(f)
   assert(f.s.import("shop",20));local cb=f.calls[1].arrive
   f.s.api.clear();cb();f.s.step(60)
   assert(f.s.api.getShelfStock("shop")==0 and f.s.api.drainGoodsRevenue()==0)
  end)
  check("stale export completion after clear cannot pay next city",function(f)
   assert(f.s.export("plant",20));local cb=f.calls[1].arrive
   f.s.api.clear();cb()
   assert(f.s.api.drainGoodsRevenue()==0,"old city export paid new city")
  end)
  check("destroyed freight releases inbound and fleet slots",function(f)
   assert(f.s.dispatch("plant","shop",20));f.calls[1].model:Destroy();f.s.step(1)
   assert(f.s.state().inbound.shop==0 and f.s.state().count==0 and f.s.state().busy==0)
  end)
  check("unreachable routes never reserve stock or charge trade",function(f)
   f.graph.available=false
   assert(not f.s.dispatch("plant","shop",20));assert(not f.s.import("shop",20));assert(not f.s.export("plant",20))
   assert(f.s.state().warehouse.plant==100 and f.s.state().count==0 and f.s.api.drainGoodsRevenue()==0)
  end)
 end)
end