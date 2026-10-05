--!strict
return function()
 local subject=script.Parent
 local source=subject.Source
 local function fixture(mutation: boolean): any
  local folder=Instance.new("Folder");local visible=Instance.new("Folder");visible.Parent=folder
  local calls={};local registered={};local forgotten={}
  local driver:any={gap=false}
  function driver.GetRestoreSeat(_,anchor)return CFrame.lookAt(Vector3.new(80,1.5,4.5),Vector3.new(81,1.5,4.5)),anchor.dist end
  function driver.RoadGapClear()return driver.gap end
  function driver.DriveDirected(car,src,dst,route,arrive,abort,dist)
   assert(car.Parent==visible)
   registered[car]=CFrame.lookAt(src,src+Vector3.xAxis)
   table.insert(calls,{car=car,arrive=arrive,dist=dist});return true
  end
  function driver.GetLivePose(car)return registered[car]end
  function driver.GetLaneAnchor(car)return if registered[car]then {edgeId="lane",dist=80}else nil end
  function driver.ReleaseDirected(car)registered[car]=nil end
  local env:any=setmetatable({
   ThroughTrafficService={},_cars={},_pendingRestores={},_restoreQueue={},_restoreCursor=1,_restoreGarage=nil,RESTORE_GAP_SECONDS=3,
   NPCDriverService=driver,PathFollower={pointAtDist=function()return Vector3.new(80,0,4.5)end,getCum=function()return {0,600}end,forget=function(car)forgotten[car]=true end},
   DriverProfile={forSeed=function()return {}end},CAR_NAME="IntercityCar",SAVE_VERSION=1,
   VehicleFactory={build=function()
    local car=Instance.new("Model");local root=Instance.new("Part");root.Anchored=true;root.Parent=car;car.PrimaryPart=root;return car
   end},
   carFolder=function()return visible end,exitPoint=function()return Vector3.new(500,0,4.5)end,
   tryPath=function()return {"lane"}end,edgeLeadsTo=function()return false end,
   game={GetService=function()return folder end},
   r2=function(n)return math.floor(n*100+.5)/100 end,
  },{__index=getfenv()})
  local body=source
  if mutation then body=body:gsub('if not NPCDriverService%.RoadGapClear%(src, RESTORE_GAP_SECONDS, car%) then return false end','if false then return false end')end
  local a=assert(body:find("local function launch(",1,true));local b=assert(body:find("local function listEnds",a,true))
  local c=assert(body:find("function ThroughTrafficService.serialize()",1,true));local d=assert(body:find("-- Each restored car",c,true))
  local e=assert(body:find("function ThroughTrafficService.ResetVehicles()",1,true));local z=assert(body:find("\nfunction ThroughTrafficService.restore",e,true))
  local fn=assert(loadstring(body:sub(a,b-1).."\n"..body:sub(c,d-1).."\n"..body:sub(e,z-1).."\nreturn launch"))
  setfenv(fn,env);local launch=fn()
  local graph={GetEdge=function()return {points={Vector3.zero,Vector3.new(600,0,0)}}end}
  local api:any={env=env,driver=driver,calls=calls,visible=visible,registered=registered,forgotten=forgotten,
   launch=function()return launch(graph,{id="border"},CFrame.new(0,0,0),123,1,{edgeId="lane",dist=80})end,
   clean=function()env.ThroughTrafficService.ResetVehicles();folder:Destroy()end}
  return api
 end
 local function check(name,run)
  it(name,function()local f=fixture(false);local ok,err=pcall(run,f);f.clean();assert(ok,err)end)
 end
 describe("Through traffic reload and reset",function()
  check("an occupied saved lane holds the car out of the world until actual admission",function(f)
   assert(f.launch())
   assert(#f.calls==0,"blocked restore registered inside existing traffic")
   local car=next(f.env._cars)
   assert(car and car.Parent~=f.visible and f.env._pendingRestores[car])
   f.driver.gap=true;f.env._pendingRestores[car]()
   assert(#f.calls==1 and car.Parent==f.visible and f.registered[car])
   assert(f.calls[1].dist==80 and f.registered[car].LookVector:Dot(Vector3.xAxis)>.999)
  end)
  check("a pending restore survives JSON and a moving car saves its live pose",function(f)
   assert(f.launch());local car=next(f.env._cars)
   local saved=game.HttpService:JSONDecode(game.HttpService:JSONEncode(f.env.ThroughTrafficService.serialize()))
   assert(saved.cars[1][1]==80 and saved.cars[1][9]==80,"pending restore lost its position or lane")
   f.driver.gap=true;f.env._pendingRestores[car]()
   f.registered[car]=CFrame.new(250,1.5,4.5)
   saved=f.env.ThroughTrafficService.serialize()
   assert(saved.cars[1][1]==250,"moving car saved the stale model pivot")
  end)
  check("reset destroys hidden restores and active cars and forgets their collision entries",function(f)
   assert(f.launch());local waiting=next(f.env._cars)
   f.driver.gap=true;assert(f.launch())
   assert(f.env.ThroughTrafficService.ResetVehicles()==2)
   assert(waiting.Parent==nil and f.forgotten[waiting])
   assert(next(f.env._cars)==nil and next(f.env._pendingRestores)==nil and #f.env._restoreQueue==0)
   for _,call in f.calls do call.arrive()end
   assert(f.env.ThroughTrafficService.ResetVehicles()==0)
  end)
  it("removing the admission guard makes the blocked reload test fail",function()
   local f=fixture(true)
   local ok=pcall(function()assert(f.launch());assert(#f.calls==0,"blocked restore registered inside existing traffic")end)
   f.clean();assert(not ok,"test could not detect a disabled admission guard")
  end)
 end)
end
