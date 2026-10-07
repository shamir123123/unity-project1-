--!strict
return function()
 local function harness(source: string): any
  local constants = { FLOOR_Y=-64, RAW_MAX=65535, HEIGHT_STEP=0.25, RENDER_BULGE=2 }
  local env: any = {
   TerrainMeshView={}, Constants=constants, CHUNKS=32, CHUNK_STUDS=256, _underground=true,
   bucketOf=function() return 0 end, skirtDepth=function() return 1500 end,
   _startupDeferred={}, _startupRevision=0, _superOf={}, _states={}, queued={}, _heightBounds={},
   Workspace={},
   centreX=function(cx: number) return -4096+(cx+0.5)*256 end,
   centreZ=function(cz: number) return -4096+(cz+0.5)*256 end,
  }
  env.chunkDist=function(key: number,eye: Vector3)
   local dx=math.max(math.abs(env.centreX(key%32)-eye.X)-128,0)
   local dz=math.max(math.abs(env.centreZ(key//32)-eye.Z)-128,0)
   return math.sqrt(dx*dx+eye.Y*eye.Y+dz*dz)
  end
  env.enqueue=function(key: number) env.queued[key]=true end
  setmetatable(env,{__index=getfenv()})
  local function compile(first: string,last: string,result: string): any
   local a=assert(string.find(source,first,1,true),"missing "..first)
   local b=assert(string.find(source,last,a+#first,true),"missing "..last)
   local f=assert(loadstring(string.sub(source,a,b-1).."\nreturn "..result))
   setfenv(f,env)
   return f()
  end
  env.startupPlanes=compile("local function startupPlanes","local function startupContains","startupPlanes")
  env.startupContains=compile("local function startupContains","function TerrainMeshView.isStartupVisible","startupContains")
  env.TerrainMeshView.isStartupVisible=compile("function TerrainMeshView.isStartupVisible","function TerrainMeshView.setStartupArea","TerrainMeshView.isStartupVisible")
  env.TerrainMeshView.releaseStartupArea=compile("function TerrainMeshView.releaseStartupArea","function TerrainMeshView.setStartupArea","TerrainMeshView.releaseStartupArea")
  env.TerrainMeshView.setStartupArea=compile("function TerrainMeshView.setStartupArea","-- Is the ground drawn everywhere","TerrainMeshView.setStartupArea")
  env.TerrainMeshView.drawnAround=compile("function TerrainMeshView.drawnAround","-- One tick of a sculpting stroke","TerrainMeshView.drawnAround")
  return env
 end
 local function camera(eye: Vector3,yaw: number,pitch: number): any
  local cam: any={CFrame=CFrame.new(eye)*CFrame.Angles(0,math.rad(yaw),0)*CFrame.Angles(math.rad(pitch),0,0),ViewportSize=Vector2.new(1600,900),FieldOfView=70,FieldOfViewMode=Enum.FieldOfViewMode.Vertical}
  function cam:ViewportPointToRay(x: number,y: number): any
   local tv=math.tan(math.rad(self.FieldOfView)*0.5)
   local th=tv*self.ViewportSize.X/self.ViewportSize.Y
   local localDir=Vector3.new((x/self.ViewportSize.X*2-1)*th,(1-y/self.ViewportSize.Y*2)*tv,-1).Unit
   return {Direction=self.CFrame:VectorToWorldSpace(localDir)}
  end
  return cam
 end
 local function keyAt(x: number,z: number): number return math.floor((x+4096)/256)+math.floor((z+4096)/256)*32 end
 describe("TerrainMeshView conservative startup frustum",function()
  it("does not prepare the ground behind the entry camera",function()
   local e=harness(script.Parent.Parent.Source)
   local cam=camera(Vector3.new(0,120,80),180,-45)
   local planes=e.startupPlanes(cam,cam.CFrame.Position)
   assert(e.startupContains(keyAt(0,768),cam.CFrame.Position,1024,planes),"front ground was culled")
   assert(not e.startupContains(keyAt(0,-768),cam.CFrame.Position,1024,planes),"behind-camera terrain remained critical")
  end)
  it("matches an eight-corner AABB oracle at frustum boundaries",function()
   local e=harness(script.Parent.Parent.Source)
   local checked=0
   for _,yaw in {0,17,75,133,180,271} do
    for _,pitch in {-10,-45,-80} do
     local cam=camera(Vector3.new(400,120,-180),yaw,pitch)
     local eye=cam.CFrame.Position
     local planes=e.startupPlanes(cam,eye)
     for key=0,1023 do
      if e.chunkDist(key,eye)<=1024 then
       local visible=true
       for _,n in planes do
        local maximum=-math.huge
        for _,x in {-128,128} do for _,z in {-128,128} do for _,y in {-62,16321.75} do
         maximum=math.max(maximum,n:Dot(Vector3.new(e.centreX(key%32)+x,y,e.centreZ(key//32)+z)-eye))
        end end end
        if maximum < -0.01 then visible=false;break end
       end
       assert(e.startupContains(key,eye,1024,planes)==visible,"frustum support disagrees with corner oracle")
       checked+=1
      end
     end
    end
   end
   assert(checked>1000,"oracle did not cover enough boundary chunks")
  end)
  it("retains every sampled in-view terrain corner",function()
   local e=harness(script.Parent.Parent.Source)
   local cam=camera(Vector3.new(0,120,80),180,-45)
   local eye=cam.CFrame.Position
   local planes=e.startupPlanes(cam,eye)
   local covered=0
   for key=0,1023 do
    for _,x in {-128,0,128} do for _,z in {-128,0,128} do for _,y in {-62,0,80,300,16321.75} do
     local relative=Vector3.new(e.centreX(key%32)+x,y,e.centreZ(key//32)+z)-eye
     local inside=relative.Magnitude<=1024
     for _,n in planes do if n:Dot(relative)<0 then inside=false;break end end
     if inside then
      assert(e.startupContains(key,eye,1024,planes),"a visible ground corner was clipped")
      covered+=1
     end
    end end end
   end
   assert(covered>100,"no visible ground corners tested")
  end)
  it("includes road caps below the encoded heightmap floor",function()
   local e=harness(script.Parent.Parent.Source)
   local cam=camera(Vector3.new(0,120,80),180,-45)
   local eye=cam.CFrame.Position
   local planes=e.startupPlanes(cam,eye)
   local candidate=nil
   for key=0,1023 do
    if e.chunkDist(key,eye)<=1024 and not e.startupContains(key,eye,1024,planes) then
     e._groundCapChunk=function(k: number) return if k==key then {[1]=-2000} else nil end
     if e.startupContains(key,eye,1024,planes) then candidate=key;break end
     e._groundCapChunk=nil
    end
   end
   assert(candidate,"below-floor cap did not expand the visible bound")
  end)
  it("retains the visible skirt below a chunk's surface bounds",function()
   local e=harness(script.Parent.Parent.Source)
   local cam=camera(Vector3.new(0,120,80),180,-45)
   local eye=cam.CFrame.Position
   local planes=e.startupPlanes(cam,eye)
   local found=false
   for key=0,1023 do
    e._underground=true
    if e.chunkDist(key,eye)<=1024 and not e.startupContains(key,eye,1024,planes) then
     e._underground=false
     if e.startupContains(key,eye,1024,planes) then found=true;break end
    end
   end
   assert(found,"visible skirt was outside the startup chunk bound")
  end)
  it("falls back conservatively when bounds or camera rays are unavailable",function()
   local e=harness(script.Parent.Parent.Source)
   local cam=camera(Vector3.new(0,120,80),180,-45)
   local eye=cam.CFrame.Position
   local planes=e.startupPlanes(cam,eye)
   e._groundCap=function() return -2000 end
   assert(e.startupContains(keyAt(0,-768),eye,1024,planes),"unbounded cap was incorrectly culled")
   assert(e.startupPlanes(cam,eye+Vector3.xAxis)==nil,"misaligned camera was trusted")
   cam.ViewportSize=Vector2.zero
   assert(e.startupPlanes(cam,eye)==nil,"invalid viewport was trusted")
  end)
  it("updates readiness for moved cameras while retaining previous ground membership",function()
   local e=harness(script.Parent.Parent.Source)
   local eye=Vector3.new(0,120,80)
   local cam=camera(eye,180,-45)
   e.Workspace.CurrentCamera=cam
   for key=0,1023 do e._startupDeferred[key]=true end
   e.TerrainMeshView.setStartupArea(eye,1024,cam)
   local old=keyAt(0,768)
   assert(e._startupKeys[old] and not e._startupKeys[keyAt(0,-768)])
   for key in e._startupVisible do e._superOf[key]=0 end
   assert(e.TerrainMeshView.drawnAround(eye,1024))
   cam.CFrame=camera(eye,0,-45).CFrame
   assert(not e.TerrainMeshView.drawnAround(eye,1024),"moved camera entered without its ground")
   local added=keyAt(0,-768)
   assert(e._startupVisible[added] and e._startupKeys[added] and e.queued[added],"newly visible ground was not queued")
   assert(e._startupKeys[old],"camera movement dropped previously covered terrain members")
   for key in e._startupVisible do e._states[key]={} end
   assert(e.TerrainMeshView.drawnAround(eye,1024))
  end)
  it("keeps frustum readiness after the far pass releases deferred membership",function()
   local e=harness(script.Parent.Parent.Source)
   local eye=Vector3.new(0,120,80)
   local cam=camera(eye,180,-45)
   e.Workspace.CurrentCamera=cam
   e.TerrainMeshView.setStartupArea(eye,1024,cam)
   for key in e._startupVisible do e._states[key]={} end
   e.TerrainMeshView.releaseStartupArea()
   assert(e._startupKeys==nil and e._startupVisible,"far completion discarded the visible gate")
   assert(e.TerrainMeshView.drawnAround(eye,1024),"far completion made readiness wait on hidden ground")
   cam.CFrame=camera(eye,0,-45).CFrame
   assert(not e.TerrainMeshView.drawnAround(eye,1024),"released view ignored camera movement")
   assert(e._startupKeys==nil,"readiness re-enabled a released geometry restriction")
  end)
  it("invalidates a cached view when road cap bounds change",function()
   local e=harness(script.Parent.Parent.Source)
   local cam=camera(Vector3.new(0,120,80),180,-45)
   local reads=0
   e._groundCapChunk=function() reads+=1;return nil end
   e.TerrainMeshView.setStartupArea(cam.CFrame.Position,1024,cam)
   local first=reads
   e.TerrainMeshView.setStartupArea(cam.CFrame.Position,1024,cam)
   assert(first>0 and reads==first,"unchanged startup view was rebuilt")
   e._startupRevision+=1
   e.TerrainMeshView.setStartupArea(cam.CFrame.Position,1024,cam)
   assert(reads>first,"changed cap bounds retained the cached view")
  end)
 end)
end