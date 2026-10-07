--!strict
return function()
 local function listener(source: string,id: string): any
  local e: any={
   requestId=id,params={},edited={},began=false,done=false,noCity=false,lastMsgAt=1,
   os={clock=function()return 100 end},dryCalls=0,unpackCalls=0,
  }
  e.num=function(value: any,fallback: number)return if type(value)=="number" then value else fallback end
  e.net={TerrainBuildData={OnClientEvent={Connect=function(_,fn)e.receive=fn;return {}end}}}
  e.WaterField={setDryKeys=function()e.dryCalls+=1 end}
  e.TerrainStreamCodec={unpack=function()
   e.unpackCalls+=1
   return {{key=2,h=buffer.create(2),m=buffer.create(1),f=buffer.create(1)}}
  end}
  setmetatable(e,{__index=getfenv()})
  local a=assert(string.find(source,"\tlocal conn\n",1,true))
  local b=assert(string.find(source,"\n\tlocal tStart = os.clock()",a,true))
  local f=assert(loadstring(string.sub(source,a,b-1)));setfenv(f,e);f()
  return e
 end
 local function finish(source: string,e: any): any
  e.myGen=1;e._buildGen=1;e.BEGIN_TIMEOUT=120;e.STREAM_TIMEOUT=30
  e.conn={Disconnect=function()e.disconnected=true end}
  e.net.RequestTerrainBuild={FireServer=function()end}
  e.TerrainStreamCodec.supported=function()return false end
  e.RunService={Heartbeat={Wait=function()
   if e.cancel then e._buildGen+=1 end
   e.os={clock=function()return 1000 end}
  end}}
  local a=assert(string.find(source,"\tlocal tStart = os.clock()",1,true))
  local b=assert(string.find(source,"\tlocal priorityRadius = PRIORITY_RADIUS",a,true))
  local f=assert(loadstring(string.sub(source,a,b-1)));setfenv(f,e)
  return f()
 end
 describe("TerrainBuildController stream identity",function()
  it("ignores delayed packets from an old build including its completion",function()
   local e=listener(script.Parent.Parent.Source,"new-build")
   for _,kind in {"begin","chunks","packed","dry","done","none","failed"} do
    e.receive({kind=kind,requestId="old-build",seed=99,items={{key=1,h=buffer.create(2),m=buffer.create(1)}},keys={1},data=buffer.create(1)})
   end
   assert(not e.began and not e.done and not e.noCity and not e.failed and next(e.edited)==nil,"delayed response changed the new build")
   assert(e.lastMsgAt==1 and e.dryCalls==0 and e.unpackCalls==0,"old packets kept another build alive")
  end)
  it("accepts its tagged stream and authoritative live patches",function()
   local e=listener(script.Parent.Parent.Source,"new-build")
   e.receive({kind="begin",requestId="new-build",seed=5})
   e.receive({kind="packed",requestId="new-build",data=buffer.create(1)})
   e.receive({kind="dry",requestId="new-build",keys={7}})
   e.receive({kind="done",requestId="new-build"})
   e.receive({kind="patch",items={{key=3,h=buffer.create(2),m=buffer.create(1)}}})
   e.receive({kind="dry",keys={8}})
   assert(e.began and e.done and e.params.seed==5 and e.edited[2] and e.edited[3],"valid stream or live patch was rejected")
   assert(e.dryCalls==2 and e.unpackCalls==1)
  end)
  it("fails its own build promptly before drawing incomplete terrain",function()
   local e=listener(script.Parent.Parent.Source,"new-build")
   e.receive({kind="failed",requestId="new-build",reason="LoadTimeout"})
   assert(e.done and e.failed=="LoadTimeout","server failure left the build waiting")
   local source=script.Parent.Parent.Source
   local a=assert(string.find(source,"\tif failed then\n",1,true))
   local b=assert(string.find(source,"\tif noCity then\n",a,true))
   local f=assert(loadstring(string.sub(source,a,b-1)));setfenv(f,e)
   local ok,err=pcall(f)
   assert(not ok and string.find(tostring(err),"LoadTimeout",1,true),"failed stream continued into terrain generation")
  end)
  it("refuses a corrupt packed batch instead of replacing edits with seed terrain",function()
   local e=listener(script.Parent.Parent.Source,"new-build")
   e.TerrainStreamCodec.unpack=function()return nil end
   e.receive({kind="begin",requestId="new-build",seed=5})
   e.receive({kind="packed",requestId="new-build",data=buffer.create(1)})
   assert(e.done and e.failed=="InvalidPackedTerrain","corrupt edited terrain was accepted")
   local ok,err=pcall(finish,script.Parent.Parent.Source,e)
   assert(not ok and string.find(tostring(err),"InvalidPackedTerrain",1,true) and e.disconnected,"corrupt stream continued into drawing or retained its listener")
  end)
  it("refuses a stalled stream after disconnecting its listener",function()
   local e=listener(script.Parent.Parent.Source,"new-build")
   e.receive({kind="begin",requestId="new-build",seed=5})
   local ok,err=pcall(finish,script.Parent.Parent.Source,e)
   assert(not ok and string.find(tostring(err),"stream stalled",1,true) and e.disconnected,"stalled stream silently drew incomplete terrain")
  end)
  it("cancels an older build promptly when a newer build starts",function()
   local e=listener(script.Parent.Parent.Source,"new-build")
   e.receive({kind="begin",requestId="new-build",seed=5})
   e.cancel=true
   local ok,result=pcall(finish,script.Parent.Parent.Source,e)
   assert(ok and result==false and e.disconnected,"obsolete stream kept waiting or drew into a newer build")
  end)
  it("generates a new request identity for every build",function()
   local source=script.Parent.Parent.Source
   local a=assert(string.find(source,"function TerrainBuildController.build(",1,true))
   local b=assert(string.find(source,"\tlocal terrain = workspace:FindFirstChildOfClass",a,true))
   local text=string.sub(source,a,b-1).."\nreturn requestId\nend\nreturn TerrainBuildController.build"
   local generated=0
   local env=setmetatable({TerrainBuildController={},_buildGen=0,HttpService={GenerateGUID=function()generated+=1;return "GUID-"..generated end}},{__index=getfenv()})
   local f=assert(loadstring(text));setfenv(f,env)
   local build=f()
   assert(build(nil)~=build(nil) and generated==2,"build reused a previous response identity")
  end)
 end)
end