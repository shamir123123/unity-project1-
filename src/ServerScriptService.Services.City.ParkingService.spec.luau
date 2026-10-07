--!strict
-- TestEZ-compatible contracts using real parking assets and isolated service state.
return function()
 local subject=script.Parent
 for _,name in {"ParkingLotSmall","ParkingLotMedium","ParkingLotLarge","ParkingLotSuper"} do
  it(name.." routes every stall through separate entrance and exit aisles after rotation",function()
   local lot=game.ReplicatedStorage.Nature[name]:Clone()
   lot:PivotTo(CFrame.new(200,0,300)*CFrame.Angles(0,math.rad(73),0))
   lot:SetAttribute("NatureKey",name);lot.Parent=workspace
   local tags={GetTagged=function(_,tag)return if tag=="NatureProp" then {lot} else {} end}
   local fakeGame={GetService=function(_,n)return if n=="CollectionService" then tags else game:GetService(n) end}
   local body=subject.Source:gsub("return ParkingService%s*$","return {api=ParkingService,cleanup=function() for m in _byLot do dropLot(m) end end}")
   local fn=assert(loadstring(body))
   setfenv(fn,setmetatable({script=subject,game=fakeGame,require=function(m)
    if m.Name=="NatureCatalog" then return {get=function()return {kind="Lot"}end} end
    return require(m)
   end},{__index=getfenv()}))
   local f=fn()
   local ok,err=pcall(function()
    f.api.Init({getNetwork=function()return {getSegments=function()return {}end}end})
    f.api.Start()
    local slab=lot.Slab
    local count=f.api.GetParkingStats().total
    for _=1,count do
     local id,cf,access=f.api.reserveNearest(lot:GetPivot().Position,1000)
     assert(id and cf and access,"a lot stall has no access route")
     assert(access.lotExit and (access.lotEntry-access.approach[1]).Magnitude<.01 and (access.lotExit-access.egress[#access.egress]).Magnitude<.01,"road entrance and exit connections share the wrong lane")
     local enter=slab.CFrame:PointToObjectSpace(access.approach[1])
     local exit=slab.CFrame:PointToObjectSpace(access.egress[#access.egress])
     assert(enter.X<0 and exit.X>0,"inbound and outbound share a centre aisle")
     assert((access.approach[#access.approach]-cf.Position).Magnitude<1.1,"arrival misses its stall")
     assert((access.egress[1]-cf.Position).Magnitude<1.1,"departure starts outside its stall")
     local departLength=0
     for i=2,#access.egress do departLength+=(access.egress[i]-access.egress[i-1]).Magnitude end
     local bay=slab.CFrame:PointToObjectSpace(cf.Position)
     local facing=slab.CFrame:VectorToObjectSpace(cf.LookVector)
     local aisleZ=bay.Z-facing.Z*11
     local direct=math.abs(bay.Z-aisleZ)+math.abs(bay.X-3)+math.abs(slab.Size.Z/2-aisleZ)+3
     assert(departLength<=direct+.1,"departure detours beside parked bays instead of using the exit aisle")
     for _,route in {access.approach,access.egress} do
      for i=2,#route-1 do
       local a,b=route[i]-route[i-1],route[i+1]-route[i]
       if a.Magnitude>.1 and b.Magnitude>.1 then assert(a.Unit:Dot(b.Unit)>-.5,"aisle route overshoots and reverses") end
      end
      for _,point in route do
       local p=slab.CFrame:PointToObjectSpace(point)
       assert(math.abs(p.X)<=slab.Size.X/2+.1 and math.abs(p.Z)<=slab.Size.Z/2+.1,"route crosses neighbouring bays or leaves the paving")
      end
     end
    end
    assert(f.api.reserveNearest(lot:GetPivot().Position,1000)==nil,"full lot admits another car")
   end)
   f.cleanup();lot:Destroy();assert(ok,err)
  end)
 end
end
