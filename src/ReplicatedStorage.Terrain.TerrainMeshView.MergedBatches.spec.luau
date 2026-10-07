--!strict
return function()
 local source=script.Parent.Source
 local function fixture():any
  local parts,calls,generated,skirted={}, {}, {}, {}
  local keys={};for key=0,11 do keys[#keys+1]=key end
  local supers,owners,solo,states,versions,queued,queue={},{},{},{},{},{},{}
  local env:any
  local f:any={parts=parts,calls=calls,generated=generated,skirted=skirted,keys=keys,supers=supers,owners=owners,solo=solo,states=states,versions=versions,queueValues=queue}
  local function part(geo:any):any
   local value:any={Parent=nil,Size=Vector3.one,geo=geo,destroyed=false}
   value.Destroy=function(self:any)self.destroyed=true;self.Parent=nil end
   value.ApplyMesh=function(self:any,fresh:any)self.geo=fresh.geo end
   parts[#parts+1]=value;return value
  end
  local tables={"_editChunks","_editFine","_liveOrder","_pinned","_queue","_queued","_shapeDirty","_errs","_drawn","_caps","_superOf","_supers","_superQueue","_superQueued","_superVersion","_startupDeferred","_heightBounds"}
  env=setmetatable({
   TerrainMeshView={stop=function()end},_sampleY=function()return 1 end,_sampleMat=function()return 2 end,
   _ensureData=function()return true end,_epoch=1,_underground=false,
   _superVersion=versions,_superQueued=queued,_superQueue=queue,_supers=supers,_superOf=owners,_solo=solo,_states=states,
   _building={},_buildingSuper={[0]=true},_shapeDirty={},_drawn={},CHUNKS=32,TRI_BUDGET=20000,
   _fillRow=function()return nil end,
   mergeMembers=function()
    local members={};for _,key in keys do if not solo[key] then members[#members+1]=key end end;return members
   end,
   bucketOf=function(key:number)return key%2 end,
   strideAt=function()return 1 end,skirtDepth=function(tier:number)return 10+tier end,
   breathe=function()end,
   enqueueChunk=function(key:number)f.soloQueued=key end,
   retire=function(value:any,em:any)if value then value:Destroy()end;if em then em:Destroy()end end,
   dress=function(value:any,geo:any,name:string)value.Parent=true;value.geo=geo;value.Name=name end,
   folder=function()return {ClearAllChildren=function()f.folderCleared=true end}end,
  },{__index=getfenv()})
  for _,name in tables do if env[name]==nil then env[name]={}end end
  env.TerrainMesh={
   buildChunk=function(cx:number,cz:number,sampleY:any,sampleMat:any,stride:any,fillRow:any)
    local key=cz*32+cx
    assert(sampleY==env._sampleY and sampleMat==env._sampleMat and fillRow==env._fillRow,"ground/cap sampling changed")
    generated[key]=(generated[key]or 0)+1
    return {tri=table.create(6000,1),members={key},origin=Vector3.zero}
   end,
   addSkirt=function(geo:any,depth:number)skirted[geo.members[1]]=depth end,
   mergeGeo=function(geos:any)
    local merged={tri={},members={},origin=Vector3.zero}
    local count=0
    for _,geo in geos do count+=#geo.tri;for _,key in geo.members do merged.members[#merged.members+1]=key end end
    merged.tri=table.create(count,1)
    return merged
   end,
  }
  env.bake=function(geo:any,live:boolean)
   assert(not live,"merged static ground became live")
   calls[#calls+1]=geo
   if f.onBake then f.onBake(#calls)end
   if f.failBake==#calls then return nil end
   return part(geo)
  end
  env.TerrainMeshView.buildChunk=function(key:number)
   generated[key]=(generated[key]or 0)+1
   calls[#calls+1]={members={key}}
   return true
  end
  local first=assert(source:find("local function buildSuper(",1,true))
  local last=assert(source:find("\n-- Hand a block back to its chunks",first,true))
  local qfirst=assert(source:find("local function enqueueSuper(",1,true))
  local qlast=assert(source:find("\nlocal function enqueueChunk(",qfirst,true))
  local sfirst=assert(source:find("local function soloise(",last,true))
  local slast=assert(source:find("\nfunction enqueue(",sfirst,true))
  local rfirst=assert(source:find("function TerrainMeshView.reset()",slast,true))
  local rlast=assert(source:find("\nend",rfirst,true))
  local loader=assert(loadstring(source:sub(qfirst,qlast-1).."\n"..source:sub(first,last-1).."\n"..source:sub(sfirst,slast-1).."\n"..source:sub(rfirst,rlast+3).."\nreturn {build=buildSuper,queue=enqueueSuper,soloise=soloise,reset=TerrainMeshView.reset}"))
  setfenv(loader,env)
  local api=loader()
  f.build,f.queue,f.soloise,f.reset=api.build,api.queue,api.soloise,api.reset
  f.env=env
  f.part=part
  f.installOld=function()
   local a,b=part({members={0,1,2,3,4,5}}),part({members={6,7,8,9,10,11}})
   a.Parent=true;b.Parent=true
   supers[0]={parts={a,b},members=table.clone(keys)}
   for _,key in keys do owners[key]=0 end
   return a,b
  end
  return f
 end
 it("batches dense geometry once within budget with exact member, cap, skirt and ownership coverage",function()
  local f=fixture()
  assert(f.build(0,Vector3.zero))
  assert(#f.calls==2,"dense super exploded into per-chunk bakes")
  local seen={}
  for _,geo in f.calls do
   assert(#geo.tri/3<=20000,"merged batch exceeded budget")
   for _,key in geo.members do assert(not seen[key],"member duplicated");seen[key]=true end
  end
  for _,key in f.keys do
   assert(seen[key] and f.generated[key]==1,"member omitted or regenerated")
   assert(f.skirted[key]==10+key%2,"member skirt/tier changed")
   assert(f.owners[key]==0 and not f.solo[key],"batched member lost super ownership")
  end
  assert(#f.supers[0].parts==2)
 end)
 it("keeps every old part and owner when a later batch cannot allocate",function()
  local f=fixture();local a,b=f.installOld()
  f.failBake=2
  assert(not f.build(0,Vector3.zero))
  assert(not a.destroyed and not b.destroyed and f.supers[0].parts[1]==a,"old coverage was retired before all batches succeeded")
  assert(f.parts[3].destroyed,"staged first batch leaked after second failed")
  for _,key in f.keys do assert(f.owners[key]==0,"failed build changed ownership")end
 end)
 it("discards all staged parts on reset epoch or a newer queued revision",function()
  for _,mode in {"epoch","version"}do
   local f=fixture();local a,b=f.installOld()
   f.onBake=function(index:number)
    if index==2 then
     if mode=="epoch" then f.env._epoch+=1 else f.queue(0)end
    end
   end
   local finished=f.build(0,Vector3.zero)
   assert(finished==(mode=="epoch"),"old epoch was requeued or new revision was accepted")
   assert(f.parts[3].destroyed and f.parts[4].destroyed,"stale staged parts leaked")
   assert(not a.destroyed and not b.destroyed,"stale build modified old coverage")
  end
 end)
 it("preserves soloised ownership during an in-flight batch and rebuilds without that member",function()
  local f=fixture();local a,b=f.installOld()
  f.onBake=function(index:number)if index==1 then f.soloise(0)end end
  assert(not f.build(0,Vector3.zero),"in-flight membership change was published")
  assert(f.solo[0] and f.owners[0]==nil and f.soloQueued==0,"soloise lost its independent chunk")
  assert(not a.destroyed and not b.destroyed,"soloise opened an old coverage hole")
  f.onBake=nil
  assert(f.build(0,Vector3.zero))
  assert(f.owners[0]==nil,"rebuild stole solo member ownership")
  for _,part in f.supers[0].parts do
   assert(not table.find(part.geo.members,0),"rebuilt super retained solo geometry")
  end
 end)
 it("reuses surviving part slots and retires every surplus part, state and empty block owner",function()
  local f=fixture();local a,b=f.installOld()
  f.keys[2]=nil;for i=3,12 do f.keys[i]=nil end
  local state=f.part({});state.Parent=true
  local em={destroyed=false,Destroy=function(self:any)self.destroyed=true end}
  f.states[0]={part=state,em=em}
  assert(f.build(0,Vector3.zero))
  assert(f.supers[0].parts[1]==a and not a.destroyed,"surviving slot was replaced")
  assert(b.destroyed and state.destroyed and em.destroyed,"surplus mesh or solo state leaked")
  assert(f.owners[1]==nil,"removed old member kept ownership")
  f.keys[1]=nil
  assert(f.build(0,Vector3.zero))
  assert(a.destroyed and f.supers[0]==nil and f.owners[0]==nil,"empty block retained parts or coverage")
 end)
 it("falls back to the already-baked part when an existing slot cannot ApplyMesh",function()
  local f=fixture();local a,b=f.installOld()
  a.ApplyMesh=function()error("engine reuse failed")end
  assert(f.build(0,Vector3.zero),"reuse failure lost a completed batch")
  assert(a.destroyed and not b.destroyed,"failed old slot or surviving slot cleanup changed")
  assert(f.supers[0].parts[1]==f.parts[3] and not f.parts[3].destroyed,"fresh fallback was discarded")
  assert(f.parts[4].destroyed,"reused second slot leaked its staging part")
 end)
 it("reset destroys every super part and clears batch revision ownership",function()
  local f=fixture();local a,b=f.installOld();f.versions[0]=4
  f.reset()
  assert(a.destroyed and b.destroyed,"reset leaked a batch part")
  assert(next(f.supers)==nil and next(f.owners)==nil and next(f.versions)==nil,"reset retained batch state")
  assert(f.folderCleared,"reset left untracked ground")
 end)
end
