--!strict
return function()
 local source=script.Parent.Source
 local function fixture(): any
  local a=assert(source:find("local FADE_OUT =",1,true))
  local b=assert(source:find("local QUICK =",a,true))
  local x=assert(source:find("\tfunction view.fadeOut(",1,true))
  local y=assert(source:find("\n\treturn view",x,true))
  local events, cancelled, connections={},{},{}
  local time=0
  local function record(kind,inst,info,goal)
   events[#events+1]={kind=kind,at=time,inst=inst,duration=info.Time,goal=goal}
  end
  local env: any=setmetatable({
   TweenInfo={new=function(seconds) return {Time=seconds} end},
   BG_OUT={Time=.5},
   mark={blocks={{},{},{},{}},cut={},island={}},
   progressFade={},skipFade={},wordmark={},shots={{},{}},bg={},
   slideshow={},skipReveal={},breathe={Cancel=function() end},
   connections=connections,view={},
   task={
    wait=function(seconds) events[#events+1]={kind="wait",at=time,duration=seconds};time+=seconds end,
    cancel=function(thread) assert(not cancelled[thread],"double cancellation");cancelled[thread]=true end,
   },
   fadeAll=function(inst,_visible,info) record("fade",inst,info,{}) end,
   tween=function(inst,info,goal) record("tween",inst,info,goal);return {} end,
  },{__index=getfenv()})
  local connection={};connection.Disconnect=function() connection.disconnected=true end
  connections[1]=connection
  local loader=assert(loadstring(source:sub(a,b-1)..source:sub(x,y-1).."\nreturn view"))
  setfenv(loader,env)
  local view=loader()
  return {view=view,env=env,events=events,time=function() return time end,connection=connection}
 end
 describe("loading screen transition",function()
  it("quick exit yields for at most 0.2 seconds",function()
   local f=fixture();f.view.fadeOut(true)
   assert(f.time()<=.2,"quick transition still waits on staged fade")
  end)
  it("quick exit fades the backdrop with the foreground",function()
   local f=fixture();f.view.fadeOut(true)
   local bgAt,waitAt
   for _,event in f.events do
    if event.inst==f.env.bg then bgAt=event.at;assert(event.duration<=.2) end
    if event.kind=="wait" then waitAt=waitAt or event.at end
   end
   assert(bgAt==0 and waitAt==0,"backdrop waits on foreground")
  end)
  it("default exit keeps the staged transition",function()
   local f=fixture();f.view.fadeOut()
   assert(math.abs(f.time()-.71)<.0001,"default transition changed")
   local bgAt
   for _,event in f.events do if event.inst==f.env.bg then bgAt=event.at end end
   assert(math.abs(assert(bgAt)-.21)<.0001)
  end)
  it("cleanup after a fade is idempotent and disconnects handlers",function()
   local f=fixture();f.view.fadeOut(true);f.view.destroy();f.view.destroy()
   assert(f.connection.disconnected and #f.env.connections==0)
  end)
 end)
end
