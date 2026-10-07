--!strict
return function()
	local source=script.Parent.Source
	local function harness(count: number): any
		local first=assert(string.find(source,"local function developSeats(",1,true))
		local last=assert(string.find(source,"-- Decode persisted seats.",first,true))
		local restoreFirst=assert(string.find(source,"function PlotService.restore(",1,true))
		local restoreLast=assert(string.find(source,"-- Server-side density gate",restoreFirst,true))
		local seats={}
		for _=1,count do table.insert(seats,{pivot=CFrame.identity,w=3,d=3,fw=18,fd=18}) end
		local env: any=setmetatable({
			PlotService={},_groups={},_nextId=0,_cityRevision=0,_topologyRevision=0,
			RESTORE_SLICE_SECONDS=tonumber(string.match(source,"local RESTORE_SLICE_SECONDS%s*=%s*([%d%.]+)")),
			clock=1,built=0,step=0,maxStep=0,yields=0,
			MIN_DEPTH=12,MAX_DEPTH=120,DEFAULT_DEPTH=18,ROAD_GRACE=600,ROAD_LEAVE_AT=420,
			ZoneTypes={isValid=function() return true end},PlotGeometry={DEFAULT_PLOT_WIDTH=18},
			isFinite=function(n) return typeof(n)=="number" end,readSeats=function(raw) return raw end,
			kerblessFor=function() return false end,eraseGroup=function() end,
		},{__index=getfenv()})
		env.PlotService.broadcastFull=function() end
		env.os={clock=function() return env.clock end}
		env._building={developPlot=function()
			env.built+=1;env.step+=1;env.clock+=.0005;return "BP_"..env.built
		end}
		env.task={wait=function()
			env.yields+=1;env.maxStep=math.max(env.maxStep,env.step);env.step=0
			local registered=0
			for _,g in env._groups do registered+=#g.buildingIds end
			assert(registered==env.built,"restore yielded before registering completed seats")
			if env.onYield then env.onYield() end
		end}
		local fn=assert(loadstring(string.sub(source,first,last-1)..string.sub(source,restoreFirst,restoreLast-1).."\nreturn PlotService.restore"))
		setfenv(fn,env);env.restore=fn()
		env.data={{seg=1,side=1,t0=0,t1=1,zone="Residential",s=1,b=seats}}
		return env
	end
	it("slices a saved group containing thousands of seats without losing ownership",function()
		local env=harness(3000)
		env.restore(env.data)
		env.maxStep=math.max(env.maxStep,env.step)
		assert(env.built==3000,"saved seats were lost")
		assert(env.yields>0 and env.maxStep<=12,"one restored group monopolized the server frame")
	end)
	it("stops restoring when the road generation changes",function()
		local env=harness(100)
		env.onYield=function() env._topologyRevision+=1 end
		local ok=pcall(env.restore,env.data)
		assert(not ok and env.built>0 and env.built<100,"restore continued against replaced roads")
	end)
	it("stops restoring when the city generation changes",function()
		local env=harness(100)
		env.onYield=function() env._cityRevision+=1 end
		local ok=pcall(env.restore,env.data)
		assert(not ok and env.built>0 and env.built<100,"outgoing restore populated a different city")
	end)
	it("rejects plot edits during core loading even when Studio editing is open",function()
		local first=assert(string.find(source,"local function canEdit(",1,true))
		local last=assert(string.find(source,"local function segmentById(",first,true))
		local fn=assert(loadstring(string.sub(source,first,last-1).."\nreturn canEdit"))
		setfenv(fn,setmetatable({
			Workspace={GetAttribute=function(_,name) return name=="CityCoreLoading" or name=="RoadEditOpen" end},
			NetMiddleware={GetCachedAttribute=function() return true end},
		},{__index=getfenv()}))
		assert(not fn()({}),"core loading allowed a new plot edit")
	end)
end
