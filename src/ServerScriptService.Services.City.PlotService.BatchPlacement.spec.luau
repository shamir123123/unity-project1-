--!strict
return function()
	local source=script.Parent.Source
	local function harness(count: number, polygon: boolean?): (any, any)
		local first=string.find(source,"local function placePlots(",1,true) or assert(string.find(source,"local function place(",1,true))
		local last=assert(string.find(source,"-- Placements for one seat",first,true))
		local groupFirst=assert(string.find(source,"local function developGroup(",1,true))
		local groupLast=assert(string.find(source,"-- Rebuild a group from its SAVED seats",groupFirst,true))
		local plans={}
		for i=1,count do plans[i]={segId=1,side=1,blocked=false,w=3,d=3,parcelLots=3,pivot=CFrame.identity,
			plot={t0=(i-1)/count,t1=i/count,frontage=18,depth=18}} end
		local env: any=setmetatable({
			MAX_PER_PLACE=tonumber(string.match(source,"local MAX_PER_PLACE%s*=%s*(%d+)")),
			MAX_GROUP_SEATS=32,MAX_INPUT_CELLS=4096,PLACE_WORK_BUDGET=.003,PLACEMENT_CANCELLED="zoning placement superseded",
			MIN_DEPTH=12,MAX_DEPTH=120,DEFAULT_DEPTH=18,MAX_WIDTH=45,LOT=6,PLACE_COOLDOWN=.05,
			_cityRevision=0,_topologyRevision=0,_planningRevision=0,_placementBusy=false,_groups={},_nextId=0,_lastPlaceAt={},
			clock=1,built=0,yields=0,published=0,maxGroup=0,notices=0,
			ZoneTypes={isValid=function() return true end},_parcelsDirty=false,
			PlotGeometry={DEFAULT_PLOT_WIDTH=18,MIN_PLOT_WIDTH=12,MIN_HOUSE_LOTS=3,
				planSpan=function() return plans end,planPolygon=function() return plans end,
				clampSpan=function() return 0,1 end},
			canEdit=function() return true end,isFinite=function(n) return typeof(n)=="number" end,
			segmentById=function() return {id=1} end,roadIndex=function() return {} end,
			occupiedFor=function() return {} end,freeIntervals=function() return {{0,1}} end,
			kerblessFor=function() return false end,seatPivot=function(p) return p end,r1=function(n) return n end,
			parcelRect=function() return {} end,developCorner=function() end,
			PlotService={broadcastFull=function() end},
		}, {__index=getfenv()})
		env.os={clock=function() return env.clock end}
		env._building={developPlot=function()
			env.built+=1;env.clock+=.001;return "BP_"..env.built
		end}
		env._roadService={getNetwork=function() return {getSegments=function() return {} end} end}
		env.toWire=function(g) env.maxGroup=math.max(env.maxGroup,#g.buildingIds);return {id=g.id} end
		env._net={
			SyncPlots={FireAllClients=function(_,payload) env.published+=#payload.groups end},
			Notify={FireClient=function() env.notices+=1 end},
		}
		env.task={wait=function()
			env.yields+=1
			local registered=0
			local groups=0
			for _,g in env._groups do registered+=#g.buildingIds;groups+=1 end
			assert(registered==env.built,"yield exposed buildings outside their owning group")
			assert(groups==env.published,"completed groups were not published before yielding")
			if env.onYield then env.onYield() end
		end}
		local fn=assert(loadstring(string.sub(source,groupFirst,groupLast-1)..string.sub(source,first,last-1).."\nreturn place"))
		setfenv(fn,env)
		env.place=fn()
		local data=if polygon then {poly={Vector3.zero,Vector3.new(10,0,0),Vector3.new(0,0,10)},zone="Residential"}
			else {cells={{seg=1,side=1,t0=0,t1=1}},zone="Residential"}
		return env,data
	end
	it("places thousands of seats in bounded published groups",function()
		local env,data=harness(3000)
		env.place({Name="test",Parent=true},data)
		assert(env.built==3000,"long run lost buildings")
		assert(env.maxGroup<=32,"one synchronous group contains too many seats")
		assert(env.yields>0,"large zoning never yielded")
	end)
	it("does not truncate polygon zoning at 240 parcels",function()
		local env,data=harness(3000,true)
		env.place({Name="test",Parent=true},data)
		assert(env.built==3000,"polygon silently truncated before 3000 parcels")
	end)
	it("stops remaining work after topology changes and releases the busy flag",function()
		local env,data=harness(100)
		env.onYield=function() env._topologyRevision+=1 end
		env.place({Name="test",Parent=true},data)
		assert(env.built>0 and env.built<100,"stale topology was still used for the remaining plots")
		assert(not env._placementBusy,"cancelled zoning left placement locked")
		assert(env.notices==1,"cancelled zoning did not explain how to finish")
	end)
	it("rejects overlapping placement requests while one batch yields",function()
		local env,data=harness(100)
		local nested=false
		env.onYield=function()
			if nested then return end
			nested=true
			local before=env.built
			env.place({Name="other",Parent=true},data)
			assert(env.built==before,"a second zoning batch interleaved with the first")
		end
		env.place({Name="test",Parent=true},data)
		assert(nested,"test never exercised concurrent placement")
		assert(env.built==100,"concurrent batch changed the final seat count")
	end)
	it("rejects oversized input arrays before planning",function()
		local env,data=harness(10)
		local cells={}
		for i=1,4097 do cells[i]={seg=1,side=1,t0=0,t1=1} end
		data.cells=cells
		env.place({Name="test",Parent=true},data)
		assert(env.built==0,"oversized request reached the planner")
	end)
	it("cancels stale planning before developing any seats and releases placement ownership",function()
		local env,data=harness(100)
		env.PlotGeometry.planSpan=function(_index,_seg,_side,_t0,_t1,_depth,_width,_uniform,_rev,breathe)
			if breathe then env.clock+=.004;breathe() end
			return {{segId=1,side=1,blocked=false,w=3,d=3,parcelLots=3,pivot=CFrame.identity,
				plot={t0=0,t1=1,frontage=18,depth=18}}}
		end
		env.onYield=function() env._planningRevision+=1 end
		env.place({Name="test",Parent=true},data)
		assert(env.yields==1 and env.built==0,"planning developed seats after occupancy changed")
		assert(not env._placementBusy and env.notices==1,"planning cancellation leaked ownership or notice")
	end)
	it("cancels planning if edit permission is revoked or its player leaves during the yield",function()
		for _,leave in {false,true} do
			local env,data=harness(100)
			local player={Name="test",Parent=true}
			env.PlotGeometry.planSpan=function(_index,_seg,_side,_t0,_t1,_depth,_width,_uniform,_rev,breathe)
				if breathe then env.clock+=.004;breathe() end
				return {{segId=1,side=1,blocked=false,w=3,d=3,parcelLots=3,pivot=CFrame.identity,
					plot={t0=0,t1=1,frontage=18,depth=18}}}
			end
			env.onYield=function()
				if leave then player.Parent=nil else env.canEdit=function() return false end end
			end
			env.place(player,data)
			assert(env.yields==1 and env.built==0 and not env._placementBusy,"planning survived permission or player cancellation")
		end
	end)
	it("invalidates suspended plans when an existing plot is erased or loses a building",function()
		local first=assert(string.find(source,"local function eraseGroup(",1,true))
		local last=assert(string.find(source,"-- After seats left a group",first,true))
		local removeFirst=assert(string.find(source,"local function onBuildingRemoving(",1,true))
		local removeLast=assert(string.find(source,"-- One second of running game time",removeFirst,true))
		local env: any=setmetatable({_planningRevision=0,_pruning=false,
			_groups={[1]={placed={{bpId="x"}},buildingIds={"x"}}},resplit=function() end},
			{__index=getfenv()})
		local fn=assert(loadstring(string.sub(source,first,last-1)..string.sub(source,removeFirst,removeLast-1).."\nreturn eraseGroup,onBuildingRemoving"))
		setfenv(fn,env);local erase,remove=fn()
		remove("x")
		assert(env._planningRevision==1,"building removal did not invalidate suspended plans")
		erase(1)
		assert(env._planningRevision==2,"group erasure did not invalidate suspended plans")
	end)
end
