--!strict
return function()
 local function harness(source: string, count: number?, hasCity: boolean?): any
  local e: any={now=100,jobs={},messages={},warnings={},jobErrors={},spawned=0,waitStep=nil,waits=0,sliceCpu=0,maxSliceCpu=0,packCost=0.016,copyCost=0.001}
  local keys, chunks={},{}
  for key=0,(count or 33)-1 do
   keys[#keys+1]=key
   chunks[key]={heights=buffer.create(4),materials=buffer.create(2),flags=buffer.create(2)}
  end
  local hm: any={}
  function hm:dirtyKeys() return keys end
  function hm:getChunk(cx: number,cz: number) return chunks[cz*32+cx] end
  local net: any={
   RequestTerrainBuild={OnServerEvent={Connect=function(_,fn)e.request=fn;return {}end}},
   TerrainBuildData={FireClient=function(_,player,message)if e.sendError then error("fixture transport failure")end;table.insert(e.messages,{player=player,message=message})end},
  }
  local removing={Connect=function(_,fn)e.removing=fn;return {}end}
  local storage: any={Terrain={TerrainConstants="constants",Heightmap="heightmap",TerrainGenerator="generator",WaterField="water",TerrainStreamCodec="codec"},Road={RoadConstants="road"}}
  function storage:WaitForChild(name: string) assert(name=="Networker");return "net" end
  local codec: any={pack=function(items: any)
   if e.onPack then e.onPack(items) end
   e.now+=e.packCost;e.sliceCpu+=e.packCost
   return buffer.create(8)
  end}
  local modules={
   constants={MAP_HALF_EXTENT=4096},road={MAP_HALF_EXTENT=4096},
   heightmap={new=function()return hm end,decodeKey=function(key: number)return key%32,key//32 end},
   generator={generate=function()end},persistence={},ledger={new=function()return {clear=function()end}end},
   water={reset=function()end,getDryKeys=function()return {}end},codec=codec,net=net,
  }
  local function resume(co: thread)
   local ok,err=coroutine.resume(co)
   if not ok then table.insert(e.jobErrors,tostring(err)) end
  end
  e.step=function()
   local snapshot=table.clone(e.jobs)
   for _,co in snapshot do if coroutine.status(co)=="suspended" then resume(co) end end
  end
  e.finish=function()
   for _=1,200 do
    local alive=false
    for _,co in e.jobs do if coroutine.status(co)~="dead" then alive=true;break end end
    if not alive then return end
    e.step()
   end
   error("stream worker never finished")
  end
  e.task={
   spawn=function(fn: (...any)->(),...)
    local args=table.pack(...)
    local co=coroutine.create(function()fn(table.unpack(args,1,args.n))end)
    e.spawned+=1;table.insert(e.jobs,co);resume(co)
    return co
   end,
   wait=function(duration: number?)
    e.maxSliceCpu=math.max(e.maxSliceCpu,e.sliceCpu);e.sliceCpu=0;e.waits+=1
    e.now+=e.waitStep or duration or 0.016;return coroutine.yield()
   end,
  }
  local env=setmetatable({
   script={Parent={TerrainPersistence="persistence",TerrainOverlayLedger="ledger"}},
   game={GetService=function(_,name: string)
    if name=="ReplicatedStorage" then return storage end
    if name=="Players" then return {PlayerRemoving=removing} end
    error("unexpected service "..name)
   end},
   require=function(module: any)return assert(modules[module],"unexpected dependency")end,
   task=e.task,os={clock=function()return e.now end},
   buffer=setmetatable({copy=function(...)
    e.now+=e.copyCost;e.sliceCpu+=e.copyCost;buffer.copy(...)
   end},{__index=buffer}),
   warn=function(message: string)table.insert(e.warnings,message)end,
  },{__index=getfenv()})
  local f=assert(loadstring(source));setfenv(f,env)
  e.service=f();e.service.Init();e.service.Bind();if hasCity~=false then e.service.generateNewCity({seed=1}) end
  e.player={Parent=true,UserId=123,Name="StreamSpec"}
  e.count=function(kind: string)
   local count=0
   for _,row in e.messages do if row.message.kind==kind then count+=1 end end
   return count
  end
  return e
 end
 describe("TerrainDataService build stream lifecycle",function()
  it("coalesces waiting requests into one worker and serves only the latest format",function()
   local e=harness(script.Parent.Parent.Source)
   e.service.beginCityLoad()
   e.request(e.player,{packed=false})
   e.now+=1.1;e.request(e.player,{packed=false})
   e.now+=1.1;e.request(e.player,{packed=true})
   assert(e.spawned==1,"duplicate requests spawned parallel terrain streams")
   e.service.endCityLoad();e.finish()
   assert(e.count("begin")==1 and e.count("done")==1 and e.count("chunks")==0 and e.count("packed")==2,"waiting streams were not coalesced")
  end)
  it("supersedes a stream between batches without completing the old response",function()
   local e=harness(script.Parent.Parent.Source)
   e.request(e.player,{packed=false})
   assert(e.count("chunks")==1)
   e.now+=1.1;e.request(e.player,{packed=true});e.finish()
   assert(e.count("begin")==2 and e.count("done")==1 and e.count("chunks")==1 and e.count("packed")==2,"old and replacement streams interleaved")
   assert(e.spawned==1,"replacement spawned a second active worker")
  end)
  it("drops an in-flight packed batch when a new city generation replaces it",function()
   local e=harness(script.Parent.Parent.Source)
   e.onPack=function()e.task.wait()end
   e.request(e.player,{packed=true})
   assert(e.count("begin")==1 and e.count("packed")==0)
   e.service.beginCityLoad();e.service.generateNewCity({seed=2})
   e.now+=1.1;e.request(e.player,{packed=true});e.service.endCityLoad()
   e.onPack=nil;e.finish()
   assert(e.count("begin")==2 and e.count("packed")==2 and e.count("done")==1,"cancelled city emitted another packed batch or done")
   local begins={}
   for _,row in e.messages do if row.message.kind=="begin" then table.insert(begins,row.message.seed) end end
   assert(begins[1]==1 and begins[2]==2,"latest city did not supply its own seed")
  end)
  it("cancels the old city even when no replacement request has arrived",function()
   local e=harness(script.Parent.Parent.Source)
   e.onPack=function()e.task.wait()end
   e.request(e.player,{packed=true})
   e.service.beginCityLoad();e.service.generateNewCity({seed=2});e.service.endCityLoad()
   e.onPack=nil;e.finish()
   assert(e.count("packed")==0 and e.count("done")==0,"old city continued after the terrain generation changed")
  end)
  it("preserves a waiter through same-core generation but cancels a standalone regeneration",function()
   local same=harness(script.Parent.Parent.Source)
   same.service.beginCityLoad()
   same.request(same.player,{packed=true,requestId="same-core"})
   same.service.generateNewCity({seed=2})
   same.service.endCityLoad();same.finish()
   assert(same.count("begin")==1 and same.count("done")==1,"same core generation cancelled its waiting client")
   assert(same.messages[1].message.seed==2,"same core waiter received an older seed")
   local changed=harness(script.Parent.Parent.Source)
   changed.onPack=function()changed.task.wait()end
   changed.request(changed.player,{packed=true,requestId="standalone-old"})
   changed.service.generateNewCity({seed=3})
   changed.onPack=nil;changed.finish()
   assert(changed.count("packed")==0 and changed.count("done")==0,"standalone generation completed an obsolete stream")
  end)
  it("stops streaming synchronously after the player leaves",function()
   local e=harness(script.Parent.Parent.Source)
   e.request(e.player,{packed=false})
   local sent=#e.messages
   e.player.Parent=nil;e.removing(e.player);e.finish()
   assert(#e.messages==sent and e.count("done")==0,"departed player received more terrain")
  end)
  it("releases worker ownership even when reporting a failed stream also fails",function()
   local e=harness(script.Parent.Parent.Source)
   e.onPack=function()error("codec fixture error")end
   e.sendError=true
   e.request(e.player,{packed=true,requestId="send-failure"})
   assert(#e.jobErrors==0 and #e.warnings>=1,"transport failure escaped the worker boundary")
   e.sendError=false;e.onPack=nil;e.now+=1.1
   e.request(e.player,{packed=true,requestId="retry"});e.finish()
   assert(e.spawned==2 and e.count("done")==1,"failed error report stranded worker ownership")
  end)
  it("releases worker ownership after a codec error so a retry can finish",function()
   local e=harness(script.Parent.Parent.Source)
   e.onPack=function()error("codec fixture error")end
   e.request(e.player,{packed=true})
   assert(#e.warnings==1 and #e.jobErrors==0,"stream failure escaped its service boundary")
   assert(e.count("failed")==1 and e.messages[#e.messages].message.reason=="StreamFailed","codec failure did not notify its waiting client")
   e.onPack=nil;e.now+=1.1;e.request(e.player,{packed=true});e.finish()
   assert(e.count("done")==1 and e.spawned==2,"failed stream retained worker ownership")
  end)
  it("does not stream unfinished or outgoing terrain after the load deadline",function()
   local e=harness(script.Parent.Parent.Source)
   e.service.beginCityLoad();e.waitStep=20
   e.request(e.player,{packed=true,requestId="timed-out-A"});e.finish()
   assert(#e.messages==1 and e.count("failed")==1 and #e.warnings==1,"timed-out load streamed another city's ground")
   assert(e.messages[1].message.requestId=="timed-out-A" and e.messages[1].message.reason=="LoadTimeout","load failure lacked scoped completion")
  end)
  it("echoes the request ID on every response and preserves untagged legacy clients",function()
   local e=harness(script.Parent.Parent.Source)
   e.request(e.player,{packed=true,requestId="build-A"});e.finish()
   assert(e.count("done")==1)
   for _,row in e.messages do assert(row.message.requestId=="build-A","stream omitted its request identity") end
   local none=harness(script.Parent.Parent.Source,0,false)
   none.request(none.player,{requestId="empty-A"});none.finish()
   assert(none.count("none")==1 and none.messages[1].message.requestId=="empty-A","empty-city response omitted its identity")
   local legacy=harness(script.Parent.Parent.Source)
   legacy.request(legacy.player,{packed=false});legacy.finish()
   assert(legacy.count("done")==1)
   for _,row in legacy.messages do assert(row.message.requestId==nil,"legacy request gained an unrelated ID") end
  end)
  it("rejects malformed request IDs before allocating a worker",function()
   for _,id in {false,0,{},string.rep("a",65),"", "contains space"} do
    local e=harness(script.Parent.Parent.Source)
    e.request(e.player,{requestId=id});e.finish()
    assert(e.spawned==0 and #e.messages==0 and #e.warnings==1,"malformed stream identity was accepted")
   end
  end)
  it("uses a loading CPU budget only for the same core generation's waiting request",function()
   local loading=harness(script.Parent.Parent.Source,135)
   loading.packCost=0.01;loading.service.beginCityLoad()
   loading.request(loading.player,{packed=true,requestId="loading-A"})
   loading.waits=0;loading.service.endCityLoad();loading.finish()
   local active=harness(script.Parent.Parent.Source,135)
   active.packCost=0.01;active.request(active.player,{packed=true,requestId="active-A"});active.finish()
   assert(loading.waits<active.waits,"loading budget did not reduce scheduler resumes")
   assert(math.max(loading.maxSliceCpu,loading.sliceCpu)<=0.040001,"loading stream exceeded budget plus one atomic pack")
   assert(math.max(active.maxSliceCpu,active.sliceCpu)<=0.014001,"active-city stream used the loading budget")
   assert(loading.count("done")==1 and active.count("done")==1)
  end)
  it("does not yield after the last packed batch",function()
   local e=harness(script.Parent.Parent.Source,32)
   e.packCost=0.001;e.request(e.player,{packed=true,requestId="single-A"});e.finish()
   assert(e.waits==0 and e.count("packed")==1 and e.count("done")==1,"completed stream waited for another frame")
  end)

 end)
end