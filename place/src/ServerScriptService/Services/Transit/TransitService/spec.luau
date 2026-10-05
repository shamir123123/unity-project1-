--!strict
return function()
 local source=script.Parent.Source
 local cache={}
 local first=assert(source:find("local function routeRideDistance",1,true))
 local last=assert(source:find("function TransitService.estimateTrip",first,true))
 local chunk=assert(loadstring(source:sub(first,last-1).."\nreturn routeRideDistance"))
 setfenv(chunk,setmetatable({_rideDistanceCache=cache},{__index=getfenv()}))
 local distance=chunk()
 local route={stops={1,2,3},legPaths={
  {Vector3.zero,Vector3.new(0,0,1000),Vector3.new(1000,0,1000)},
  {Vector3.new(1000,0,1000),Vector3.new(2000,0,1000)},
  {Vector3.new(2000,0,1000),Vector3.zero},
 }}
 describe("Bus ride estimates",function()
  it("prices the actual stop-to-stop road path rather than a straight-line shortcut",function()assert(distance(route,1,2)==2000)end)
  it("includes intermediate stops in the direction the bus runs",function()assert(distance(route,1,3)==3000)end)
  it("a reverse destination follows the loop instead of riding backwards",function()assert(distance(route,2,1)>3000)end)
  it("missing legs are unusable instead of inventing a ride",function()
   assert(distance({stops={1,2},legPaths={}},1,2)==nil)
  end)
  it("memoised distances can be invalidated after a road edit",function()
   assert(distance(route,1,2)==2000);cache[route]=nil
   route.legPaths[1]={Vector3.zero,Vector3.new(50,0,0)}
   assert(distance(route,1,2)==50)
  end)
 end)
end