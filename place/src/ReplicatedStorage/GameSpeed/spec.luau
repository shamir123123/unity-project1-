--!strict
return function()
 local selection=1
 local world={GetAttribute=function()return selection end}
 local fn=assert(loadstring(script.Parent.Source))
 setfenv(fn,setmetatable({game={GetService=function()return world end}},{__index=getfenv()}))
 local Speed=fn()
 describe("Simulation pacing",function()
  it("pause freezes both accumulated time and fixed substeps",function()selection=0;assert(Speed.scaled(10)==0 and Speed.steps()==0)end)
  it("fast forward is exactly three times the new normal pace",function()
   selection=1;local normal=Speed.scaled(10)
   selection=3;assert(Speed.scaled(10)==normal*3 and Speed.steps()==6)
  end)
  it("normal and fast days take twelve and four real minutes",function()
   selection=1;assert(1440/Speed.get()==720)
   selection=3;assert(1440/Speed.get()==240)
  end)
  it("invalid out-of-range selections remain bounded",function()selection=999;assert(Speed.get()==6);selection=-1;assert(Speed.get()==0)end)
 end)
end