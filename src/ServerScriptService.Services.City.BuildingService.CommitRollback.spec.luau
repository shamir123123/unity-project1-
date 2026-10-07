--!strict
return function()
	local source=script.Parent.Source
	local function fixture(kind: string): any
		local scheduler=assert(string.find(source,"local CONSTRUCTION_POLL_SECONDS",1,true))
		local schedulerEnd=assert(string.find(source,"local function newBlueprintId",scheduler,true))
		local cancel=assert(string.find(source,"local function cancelConstruction(",1,true))
		local cancelEnd=assert(string.find(source,"-- Fires as a building goes away",cancel,true))
		local place=assert(string.find(source,"local function placeBuilding(",1,true))
		local placeEnd=assert(string.find(source,"function finishConstructionVisual(",place,true))
		local develop=assert(string.find(source,"function BuildingService.developPlot(",1,true))
		local developEnd=assert(string.find(source,"-- Placeable-building catalog",develop,true))
		local folder=Instance.new("Folder")
		local template=Instance.new("Model")
		local body=Instance.new("Part");body.Size=Vector3.new(12,10,12);body.Parent=template;template.PrimaryPart=body
		local now,steps=0,0
		local env: any=setmetatable({
			BuildingService={},ConstructionQueue=require(script.Parent.ConstructionQueue),
			_bldgFolder=folder,_activeConstruction={},_buildings={},_restoreState={},_plotFootprints={},
			LOT_SIZE=6,RESTORE_OVERLAP_TOL=.01,FOOTPRINT_TOL=.01,
			EARTHWORK_STAGES={.25,.5,.75,1},EARTHWORK_STEP_SECS=.9,MIN_NEST_DWELL=2,
			GameSpeed={get=function() return 1 end},Quant={snapCF=function(cf) return cf end},
			removed=0,published=false,earlyRemoval=false,workers=0,
			warn=function() end,houseLots=function(_,w,d) return w,d end,
			getTemplateFolder=function() return template end,plotFootprintBlocked=function() return false end,
			seatY=function(y) return y end,newBlueprintId=function() return "probe" end,
			setFootprint=function() end,makeFootprint=function() return {} end,clearFootprint=function() end,
			constructionSeconds=function() return 30 end,saveKeyForPivot=function() return "key" end,
			pickTemplate=function() return template end,scriptedTemplate=function() return true end,
			plotCanBeFlat=function() if kind=="prepare" then error("preparation failure",0) end;return true end,
			addSiteMarker=function() end,removeSiteMarker=function() end,showNest=function() end,
			showConstruction=function() end,finishConstructionVisual=function() end,
			padGround=function() end,unpadGround=function() end,
		},{__index=getfenv()})
		env.os=setmetatable({clock=function()
			now+=10;steps+=1;assert(steps<10000,"diagnostic deadline");return now
		end},{__index=os})
		env.task={
			spawn=function(fn) env.workers+=1;fn() end,
			defer=function(fn) env.workers+=1;env.pending=fn end,
			wait=function() end,
		}
		env.fireBuildingRemoving=function()
			env.removed+=1
			if not env.published then env.earlyRemoval=true end
		end
		env._dressingService={
			dress=function()
				if kind=="dress" then error("dressing failure",0) end
				if kind=="epoch" or kind=="epochError" then
					env._activeConstruction.probe.cancelled=true
					env.replacement=Instance.new("Model");env.replacement.Parent=folder
					env.replacementRecord={model=env.replacement}
					env.replacementActive={siteId="replacement",cancelled=false}
					env._buildings.probe=env.replacementRecord
					env._activeConstruction.probe=env.replacementActive
					if kind=="epochError" then error("stale dressing failure",0) end
				end
			end,
			settleLot=function() end,
		}
		env.refreshIndustrialSource=function()
			if kind=="registered" then error("post-registration failure",0) end
			if kind=="recordEpoch" or kind=="recordModelEpoch" then
				env.replacement=Instance.new("Model");env.replacement.Parent=folder
				env.replacementRecord=if kind=="recordModelEpoch" then env._buildings.probe else {model=env.replacement}
				env.replacementRecord.model=env.replacement
				env.replacementActive={siteId="replacement",cancelled=false}
				env._buildings.probe=env.replacementRecord
				env._activeConstruction.probe=env.replacementActive
				error("stale record failure",0)
			end
		end
		local text=string.sub(source,scheduler,schedulerEnd-1)..string.sub(source,cancel,cancelEnd-1)
			..string.sub(source,place,placeEnd-1)..string.sub(source,develop,developEnd-1)
		local loader=assert(loadstring(text));setfenv(loader,env);loader()
		env.flush=function() local pending=env.pending;env.pending=nil;if pending then pending() end end
		env.folder=folder
		env.cleanup=function() folder:Destroy();template:Destroy() end
		return env
	end
	local function checked(kind: string,body: (any) -> ()): ()
		local env=fixture(kind)
		local ok,err=xpcall(function() body(env) end,debug.traceback)
		env.cleanup()
		assert(ok,err)
	end
	it("publishes the returned site before the first worker can cancel it",function()
		checked("prepare",function(env)
			local id=env.BuildingService.developPlot(CFrame.identity,"Residential",3,3,"stamp",1)
			assert(id=="probe" and env._activeConstruction[id] and not env.earlyRemoval,"returned a site already cancelled before its caller registered it")
			env.published=true;env.flush()
			assert(env.removed==1 and not env._activeConstruction[id] and env.workers==1,"deferred failure cleanup did not finish")
		end)
	end)
	it("removes a partially parented model when dressing fails",function()
		checked("dress",function(env)
			env.published=true
			env.BuildingService.developPlot(CFrame.identity,"Residential",3,3,"stamp",1);env.flush()
			assert(#env.folder:GetChildren()==0 and not env._buildings.probe and not env._activeConstruction.probe,"failed dressing left a model or record behind")
			assert(env.removed==1,"failed site did not release its plot")
		end)
	end)
	it("rolls back a registered model when a later commit step fails",function()
		checked("registered",function(env)
			env.published=true
			env.BuildingService.developPlot(CFrame.identity,"Residential",3,3,"stamp",1);env.flush()
			assert(#env.folder:GetChildren()==0 and not env._buildings.probe and not env._activeConstruction.probe,"failed commit left a model or record behind")
			assert(env.removed==1,"failed commit did not release its plot")
		end)
	end)
	it("keeps a replacement epoch when old dressing completes or fails",function()
		for _,kind in {"epoch","epochError","recordEpoch","recordModelEpoch"} do checked(kind,function(env)
			env.published=true
			env.BuildingService.developPlot(CFrame.identity,"Residential",3,3,"stamp",1);env.flush()
			assert(env._buildings.probe==env.replacementRecord and env._activeConstruction.probe==env.replacementActive,"old commit removed or replaced the new epoch")
			assert(#env.folder:GetChildren()==1 and env.replacement.Parent==env.folder,"old commit leaked its model or destroyed the replacement")
			assert(env.removed==0,"old failure cancelled the replacement site")
		end) end
	end)
	it("rolls back an instant restore commit before propagating failure",function()
		checked("registered",function(env)
			env.published=true
			local ok=pcall(env.BuildingService.developPlot,CFrame.identity,"Residential",3,3,"instant",1)
			assert(not ok,"instant restore swallowed its commit failure")
			assert(#env.folder:GetChildren()==0 and not env._buildings.probe and not env._activeConstruction.probe,"instant restore retained partial committed state")
		end)
	end)
end
