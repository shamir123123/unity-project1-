--!strict
return function()
	local source = script.Parent.Source
	local first = assert(string.find(source, "local function previewInputs", 1, true))
	local last = assert(string.find(source, "local _beganConn", first, true))
	local helpers = string.sub(source, first, last - 1)
	local workerFirst = assert(string.find(source, "\ttask.spawn(function()\n\t\t_previewWorker = coroutine.running()", 1, true))
	local workerLast = assert(string.find(source, "\nend\n\nfunction PlotController.setEnabled", workerFirst, true))
	local worker = string.sub(source, workerFirst, workerLast - 1)
	local function helperEnv(): any
		local env: any = setmetatable({
			Workspace = { CurrentCamera = { CFrame = CFrame.identity, ViewportSize = Vector2.new(800,600), FieldOfView = 70 } },
			UserInputService = { GetMouseLocation = function() return Vector2.zero end },
			DataCache = { GetRoadRevision = function() return 1 end },
			_enabled=true, _bound=true, _mode="Single", _activeZone="Residential",
			_widthLots=3, _depthLots=4, _sizeMode="Mixed", _mirror=false, _density="Low",
			_worldRevision=0, _poly={}, _previewSlice=0, PREVIEW_BUDGET=.003,
			PREVIEW_CANCELLED="zoning preview superseded", os={clock=function() return 1 end},
		}, {__index=getfenv()})
		return env
	end
	local function checkCancellation(mutate: (any)->())
		local env=helperEnv()
		local fn=assert(loadstring(helpers.."\nreturn {inputs=previewInputs,breathe=breathePreview}"))
		setfenv(fn,env)
		local api=fn()
		env._renderPreviewInputs=api.inputs()
		env._previewWorker=coroutine.running()
		env.task={wait=function() mutate(env) end}
		local ok,err=pcall(api.breathe)
		assert(not ok and string.find(tostring(err),env.PREVIEW_CANCELLED,1,true),"stale preview continued after an input changed")
	end
	it("cancels a yielded preview when settings change without cursor motion",function()
		checkCancellation(function(env) env._activeZone="Industrial" end)
	end)
	it("cancels a yielded preview after a world update",function()
		checkCancellation(function(env) env._worldRevision+=1 end)
	end)
	it("cancels a yielded preview when its polygon changes",function()
		checkCancellation(function(env) table.insert(env._poly,Vector3.one) end)
	end)
	it("retains cleanup progress when a preview is cancelled",function()
		local first=assert(string.find(source,"local function clearPool(",1,true))
		local last=assert(string.find(source,"local function drawSeg(",first,true))
		local pool: {any}={}
		for _=1,3 do table.insert(pool,{Destroy=function() end}) end
		local env: any=setmetatable({breathePreview=function() error("cancel",0) end},{__index=getfenv()})
		local fn=assert(loadstring(string.sub(source,first,last-1).."\nreturn clearPool"))
		setfenv(fn,env)
		local clear=fn()
		assert(not pcall(clear,pool),"test did not interrupt cleanup")
		assert(#pool==2,"cancelled cleanup kept already-destroyed instances in its work list")
		env.breathePreview=function() end
		clear(pool)
		assert(#pool==0,"cleanup did not resume")
	end)
	it("invalidates stationary previews on placement and disconnects tool-scoped watches",function()
		local first=assert(string.find(source,"local PLANNING_FOLDERS",1,true))
		local last=assert(string.find(source,"-- ---------------------------------------------- public API",first,true))
		local connections: {any}={}
		local function signal(): any
			local listeners: {any}={}
			return {
				Connect=function(_,callback)
					local connection: any={callback=callback,disconnected=false}
					connection.Disconnect=function() connection.disconnected=true end
					table.insert(listeners,connection);table.insert(connections,connection);return connection
				end,
				fire=function(child)
					for _,connection in listeners do if not connection.disconnected then connection.callback(child) end end
				end,
			}
		end
		local folder={Name="Nature",ChildAdded=signal(),ChildRemoved=signal()}
		local city={Name="_City",ChildAdded=signal(),ChildRemoved=signal(),GetChildren=function() return {folder} end}
		local workspace={FindFirstChild=function() return city end,ChildAdded=signal(),ChildRemoved=signal()}
		local env: any=setmetatable({Workspace=workspace,_worldRevision=0,_polyKey="cached",_doomSig=123,_terrainYCache={},_terrainYCount=0},{__index=getfenv()})
		local fn=assert(loadstring(string.sub(source,first,last-1).."\nreturn {start=startPlacementWatch,stop=stopPlacementWatch}"))
		setfenv(fn,env)
		local watch=fn()
		watch.start()
		folder.ChildAdded.fire({IsA=function(_,class) return class=="Model" end})
		assert(env._worldRevision==1 and env._polyKey=="" and env._doomSig==-1,"stationary preview did not invalidate after placement")
		watch.stop()
		folder.ChildRemoved.fire({IsA=function(_,class) return class=="Model" end})
		assert(env._worldRevision==1,"disabled tool still observed placements")
		for _,connection in connections do assert(connection.disconnected,"tool placement connection leaked") end
	end)
	it("does not cache inputs that changed while drawing",function()
		local env=helperEnv()
		env.previewInputs=function() return {env._worldRevision} end
		env.samePreviewInputs=function(a,b) return b~=nil and a[1]==b[1] end
		env._doomRects={}
		env._frameSeats={clear=function() end}
		env.updateHoverStamp=function() env._worldRevision+=1 end
		env.refreshDoomed=function() end
		env.task={spawn=function(fn) fn() end,wait=function() env._bound=false end}
		local fn=assert(loadstring(worker.."\nreturn _lastPreviewInputs"))
		setfenv(fn,env)
		assert(fn()==nil,"stale drawing was cached as the new world revision")
	end)
end
