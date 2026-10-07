--!strict
return function()
	local source=script.Parent.Source
	local function cacheHarness(): any
		local first=assert(string.find(source,"local function roadIndex(",1,true))
		local last=assert(string.find(source,"local function uniformOn(",first,true))
		local env: any=setmetatable({_groups={{seg=1,side=1,t0=0,t1=1,depth=24,width=18}},
			_parcelsDirty=true,_roadIndex=nil,checks=0,calls=0,fail=false,
			DataCache={GetSegments=function() return {} end,GetSegmentById=function() return {} end},
			PlacementFit={seatOccupied=function() return false end}}, {__index=getfenv()})
		env.breathePreview=function() env.checks+=1;if env.fail then error("cancel preview",0) end end
		env.PlotGeometry={
			buildRoadIndex=function(_roads,_occupied,breathe)
				assert(breathe,"cold road index ignored the preview budget")
				breathe()
				return {parcels={"old"}}
			end,
			groupParcels=function(_seg,_side,_t0,_t1,_depth,_width,_uniform,breathe)
				env.calls+=1
				if env.fail then error("cancel parcels",0) end
				assert(breathe,"parcel rebuild ignored the preview budget")
				breathe()
				return {"new"}
			end,
		}
		local fn=assert(loadstring(string.sub(source,first,last-1).."\nreturn roadIndex"))
		setfenv(fn,env);env.index=fn()
		return env
	end
	it("forwards the preview budget through cold road and parcel index construction",function()
		local env=cacheHarness()
		assert(env.index().parcels[1]=="new" and env.checks>=2,"index builders never checked the preview budget")
	end)
	it("leaves cancelled parcel rebuilds dirty and retains the last complete parcel list",function()
		local env=cacheHarness()
		env._roadIndex={parcels={"old"}}
		env.fail=true
		local ok=pcall(env.index)
		assert(not ok,"fixture never cancelled")
		assert(env._parcelsDirty and env._roadIndex.parcels[1]=="old","cancelled parcel index was cached")
		env.fail=false
		assert(env.index().parcels[1]=="new" and not env._parcelsDirty,"cancelled parcel index did not rebuild")
	end)
	it("caches a polygon key only after its plan has completed",function()
		local first=assert(string.find(source,"local _polyPlan:",1,true))
		local last=assert(string.find(source,"local function drawNode(",first,true))
		local env: any=setmetatable({_poly={Vector3.zero,Vector3.xAxis,Vector3.zAxis},
			_activeZone="Residential",_density="Low",calls=0,fail=true,
			snapWidth=function() return 18 end,uniformOn=function() return true end,
			roadIndex=function() return {} end,DataCache={GetSegments=function() return {} end},
			breathePreview=function() end}, {__index=getfenv()})
		env.PlotGeometry={planPolygon=function()
			env.calls+=1
			if env.fail then error("cancel polygon",0) end
			return {"complete"}
		end}
		local fn=assert(loadstring(string.sub(source,first,last-1).."\nreturn polyPlan"))
		setfenv(fn,env);local plan=fn()
		assert(not pcall(plan),"fixture never cancelled")
		env.fail=false
		assert(plan()[1]=="complete" and env.calls==2,"cancelled polygon key suppressed the next plan")
	end)
end
