--!strict
return function()
 local Journeys=require(script.Parent)
 local function harness(mode:string, destinationSpot:string):any
  local h:any={id=1,homeId="home",adults={},kids={}}
  local car=Instance.new("Model");local root=Instance.new("Part");root.Parent=car;car.PrimaryPart=root
  local a:any={pid=1,age=40,name="Test",gender="Male",tripId=1,parkSpotId="lot1#1",car=car,usingCar=true,tripTargetHome=false}
  local f:any={h=h,a=a,car=car,walks={},released={},drives=0,riders=0,arrivals=0}
  local walking={spawnCommuter=function(_,_,done)table.insert(f.walks,done);return #f.walks end,despawnCommuter=function()end}
  local transit={getStop=function(id)return {pos=Vector3.new(id,0,0)}end,cancelRider=function()end,
   waitForRide=function()f.riders+=1;return 9 end}
  local context:any={
   getHouseholds=function()return {[1]=h}end,getWalkingService=function()return walking end,getTransitService=function()return transit end,
   getEducationService=function()return {getNearestSchool=function()return Vector3.new(100,0,0),1 end}end,
   isSchoolAge=function()return true end,personLabel=function()return "Resident"end,kidLabel=function()return "Student"end,
   door=function()return Vector3.zero end,
   chooseTravelMode=function()return mode,{routeId=1,boardStopId=1,alightStopId=2}end,
   cars={notePocket=function()f.notes=(f.notes or 0)+1 end,fetchWhenClear=function(_,go)go()end,walk=function(_,_,_,_,done)table.insert(f.walks,done);return #f.walks end},
   garage={stow=function(m)m.Parent=nil;f.pocketed=true end},releaseSpot=function(person)
    table.insert(f.released,person.parkSpotId);person.parkSpotId=nil;person.parkStallKey=nil
   end,
   driveTo=function(_,_,done,opts)f.drives+=1;f.roadDone=done;f.options=opts end,
  }
  f.journeys=Journeys.new(context)
  f.start=function()
   f.journeys.journey(h,a,1,Vector3.zero,Vector3.new(20,0,0),true,
    function()return {spotId=destinationSpot,cf=CFrame.new(10,0,0),pocket=f.pocketChoice}end,function()f.arrivals+=1 end)
  end
  return f
 end
 it("an errand served by the same lot keeps the occupied bay and walks instead of driving out and back",function()
  local f=harness("drive","lot1#2");f.start();f.walks[1]()
  local ok,err=pcall(function()
   expect(f.drives).to.equal(0);expect(f.a.parkSpotId).to.equal("lot1#1")
   expect(f.released[1]).to.equal("lot1#2")
   f.walks[2]();expect(f.arrivals).to.equal(1)
  end)
  f.car:Destroy();assert(ok,err)
 end)
 it("a trip to a different lot still drives and releases its previous reservation",function()
  local f=harness("drive","lot2#1");f.start();f.walks[1]()
  local ok,err=pcall(function()
   expect(f.drives).to.equal(1);expect(#f.released).to.equal(0)
   assert(f.options.onDepart,"old bay must stay occupied until road departure")
   f.options.onDepart();expect(f.released[1]).to.equal("lot1#1")
   f.options.onDepart();expect(#f.released).to.equal(1)
  end)
  f.car:Destroy();assert(ok,err)
 end)
 it("full parking pockets the car after the real drive and preserves the walking arrival",function()
  local f=harness("drive",nil);f.pocketChoice=true;f.start();f.walks[1]()
  local ok,err=pcall(function()
   expect(f.options.pocket).to.equal(true);expect(f.arrivals).to.equal(0)
   expect(f.pocketed).to.equal(nil)
   f.roadDone()
   expect(f.pocketed).to.equal(true);expect(f.notes).to.equal(1)
   expect(f.arrivals).to.equal(0);f.walks[2]();expect(f.arrivals).to.equal(1)
  end)
  f.car:Destroy();assert(ok,err)
 end)
 it("a teen choosing a usable bus for school boards the real transit service",function()
  local f=harness("transit","lot1#1")
  local kid:any={pid=2,age=16,tripId=1,stage="atHome",gender="Male"}
  f.journeys.startSchool(f.h,kid);f.walks[1]()
  local ok,err=pcall(function()expect(f.riders).to.equal(1);expect(f.drives).to.equal(0);expect(kid.riderId).to.equal(9)end)
  f.car:Destroy();assert(ok,err)
 end)
end