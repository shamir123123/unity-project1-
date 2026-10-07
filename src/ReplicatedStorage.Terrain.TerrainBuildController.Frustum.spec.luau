--!strict
return function()
 describe("TerrainBuildController frustum priority",function()
  it("uses the same startup mask for near work and merge membership",function()
   local source=script.Parent.Parent.Source
   local first=assert(string.find(source,"\t-- Centroid of the edited chunks",1,true))
   local last=assert(string.find(source,"\tlocal function report",first,true))
   local cam={CFrame=CFrame.new(0,120,80)}
   local visible={ [16*32+16]=true,[17*32+16]=true,[18*32+16]=true }
   local registrations=0
   local env=setmetatable({
    edited={},workspace={CurrentCamera=cam},MESH_GROUND=true,priorityRadius=1024,
    CHUNKS_PER_AXIS=32,CHUNK_STUDS=256,PRIORITY_RADIUS=1024,
    chunkCentreX=function(cx: number)return -4096+(cx+0.5)*256 end,
    chunkCentreZ=function(cz: number)return -4096+(cz+0.5)*256 end,
    TerrainMeshView={
     setStartupArea=function(pos: Vector3,radius: number,camera: any)
      assert(pos==cam.CFrame.Position and radius==1024 and camera==cam,"startup mask registered another view")
      registrations+=1
     end,
     isStartupVisible=function(key: number)return visible[key]==true end,
    },
   },{__index=getfenv()})
   local f=assert(loadstring(string.sub(source,first,last-1).."\nreturn order,priorityCount"))
   setfenv(f,env)
   local order,count=f()
   assert(registrations==1 and count==3,"near work ignored the registered visibility mask")
   for i=1,count do assert(visible[order[i]],"invisible chunk displaced visible near work") end
  end)
 end)
end