--!strict
return function()
 local function harness(source: string, generation: number): any
  local env: any = {
   TerrainBuildController = {}, MESH_GROUND = true, BACKGROUND_BUDGET = 0.004,
   _frameBudget = 0.25, _buildGen = 2, myGen = generation, _farDone = false,
   releases = 0, pendingCalls = 0, loading = true, catchUp = false,
  }
  env.TerrainMeshView = {
   setStartupArea = function(pos: Vector3?)
    assert(pos == nil); env.releases += 1
   end,
   releaseStartupArea = function() env.releases += 1 end,
   pending = function()
    assert(env.releases > 0 or generation ~= 2, "full queue drained before missing terrain was requeued")
    env.pendingCalls += 1
    return 0
   end,
   setLoading = function(value: boolean) env.loading = value end,
   setCatchUp = function(value: boolean) env.catchUp = value end,
  }
  setmetatable(env, { __index = getfenv() })
  env.run = function(first: string, last: string, result: string?)
   local a = assert(string.find(source, first, 1, true), "missing " .. first)
   local b = assert(string.find(source, last, a + #first, true), "missing " .. last)
   local chunk = assert(loadstring(string.sub(source, a, b - 1) .. (if result then "\nreturn " .. result else "")))
   setfenv(chunk, env)
   return chunk()
  end
  return env
 end
 describe("TerrainBuildController startup-area lifecycle", function()
  it("releases deferred geometry before waiting for the full map", function()
   local env = harness(script.Parent.Parent.Source, 2)
   env.run("\tlocal tFar = os.clock()", "\n\t-- The far pass queued geometry")
   assert(env._farDone and env.releases == 1 and env.pendingCalls == 1)
  end)
  it("keeps a cancelled far pass from releasing a newer city's area", function()
   local env = harness(script.Parent.Parent.Source, 1)
   local result=env.run("\tlocal tFar = os.clock()", "\n\t-- The far pass queued geometry")
   assert(result==false and not env._farDone and env.releases == 0, "cancelled build released the current startup gate or completed successfully")
  end)
  it("stops a superseded near pass after its heartbeat before painting another chunk",function()
   local env: any={
    myGen=1,_buildGen=1,priorityCount=3,order={1,2,3},_frameBudget=1,
    NEAR_FRAC=0.55,MESH_GROUND=true,_nearDone=false,clock=0,painted=0,started=0,
   }
   env.os={clock=function()return env.clock end}
   env.buildAndPaint=function()env.painted+=1;env.clock+=1 end
   env.report=function()end
   env.RunService={Heartbeat={Wait=function()env._buildGen=2 end}}
   env.TerrainMeshView={start=function()env.started+=1 end}
   setmetatable(env,{__index=getfenv()})
   local source=script.Parent.Parent.Source
   local a=assert(string.find(source,"\tlocal i = 1\n",1,true))
   local z=assert(string.find(source,"\n\t-- Far pass:",a,true))
   local f=assert(loadstring(string.sub(source,a,z-1)));setfenv(f,env)
   local result=f()
   assert(result==false and env.painted==1 and env.started==0 and not env._nearDone,"old near painter touched the next city or activated its queue")
  end)
  it("does not report completion after a newer build supersedes the draw drain",function()
   local env=harness(script.Parent.Parent.Source,1)
   env.FRAME_BUDGET=0.25;env.DRAW_TIMEOUT=45;env.BACKGROUND_DRAW_TIMEOUT=45
   env.os={clock=function()return 0 end}
   local reports=0;env.report=function()reports+=1 end
   local result=env.run("\t-- The far pass queued geometry","\n\t-- ONE line saying")
   assert(result==false and reports==0,"old draw drain reported successful entry")
  end)
  it("releases deferred geometry when the player enters early", function()
   local env = harness(script.Parent.Parent.Source, 2)
   local finish = env.run("function TerrainBuildController.finishInBackground()", "-- Has the build got far enough", "TerrainBuildController.finishInBackground")
   finish()
   assert(env.releases == 1 and env._frameBudget == 0.004 and not env.loading and env.catchUp)
  end)
 end)
end