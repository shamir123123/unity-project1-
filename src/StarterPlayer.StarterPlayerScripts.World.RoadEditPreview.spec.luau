--!strict
return function()
	local function fixture()
		local world = script.Parent.Parent
		local callback: any
		local pump: any
		local revision, idle, now = 0, false, 0
		local overrides: { [number]: any } = {}
		local hidden: { [number]: boolean } = {}
		local hiddenCells: { [number]: { [string]: boolean } } = {}
		local projected = false
		local calls: { string } = {}
		local root = Instance.new("Folder")
		local modules: { [string]: any } = {
			DataCache = {
				GetSegmentById = function(id: number) return {id=id,roadType="NarrowRoad"} end,
				GetRoadRevision = function() return revision end,
			},
			RoadPieces = {
				setPrediction = function(token: number, value: any)
					overrides[token]=value;projected=value ~= nil;table.insert(calls,if value then "projection" else "rollback")
				end,
				affectedSegments = function(ids: { number }, limit: number)
					assert(limit == 64);local out=table.clone(ids);table.insert(out,9);return out
				end,
				cellsForSegments = function(ids: { number })
					table.insert(calls,"cells")
					local cells={ [if projected then "1,0" else "0,0"] = true }
					if table.find(ids,9) then cells[if projected then "neighbor-new" else "neighbor-old"]=true end
					return cells
				end,
			},
			RoadMeshView = {
				isPredictionReady = function() return idle end,
				hidePredictionCells = function(token: number, cells: { [string]: boolean }) hidden[token]=true;hiddenCells[token]=cells;table.insert(calls,"hidden");return true end,
				clearPredictionCells = function(token: number) hidden[token]=nil;table.insert(calls,"shown") end,
			},
			RoadPreviewGeometry = {draw=function() return true, 0 end},
			BezierUtil = {}, RoadConstants = {},
			RoadTypeCatalog = {get=function() return {} end},
			UiScratch = {root=function() return root end},
			Networker = {PlaceRoadResult={OnClientEvent={Connect=function(_self: any, fn: any)
				callback=fn
				return {Disconnect=function() callback=nil end}
			end}}},
		}
		local env = setmetatable({
			script=script.Parent, workspace={GetAttribute=function() return true end},
			require=function(module: Instance) return assert(modules[module.Name],module.Name) end,
			task={spawn=function(fn: any) pump=coroutine.create(fn) end,wait=function() coroutine.yield() end},
			os={clock=function() return now end}, warn=function() end,
		},{__index=getfenv()})
		local loader=assert(loadstring(script.Parent.Source));setfenv(loader,env)
		local preview=loader();preview.Start()
		local function tick()
			if pump and coroutine.status(pump) ~= "dead" then assert(coroutine.resume(pump)) end
		end
		return {
			preview=preview,overrides=overrides,hidden=hidden,hiddenCells=hiddenCells,calls=calls,result=function(ok: boolean,token: number,rev: number) callback(ok,nil,"edit",token,rev) end,
			tick=tick,ready=function(rev: number,drawn: boolean) revision=rev;idle=drawn end,
			expire=function() now=11 end,
			cleanup=function() preview.Cleanup();if pump and coroutine.status(pump)~="dead" then coroutine.close(pump) end;root:Destroy() end,
		}
	end
	it("swaps affected cells immediately and restores them after rejection",function()
		local f=fixture()
		local token=assert(f.preview.remove({{id=1}}))
		assert(f.hidden[token],"static road cell stayed visible after predicted deletion")
		assert(f.calls[1]=="cells" and f.calls[2]=="projection" and f.calls[3]=="cells" and f.calls[4]=="hidden",
			"old cells were captured after their road geometry disappeared")
		f.result(false,token,0)
		assert(f.overrides[token]==nil and f.hidden[token] and f.calls[5]=="rollback",
			"rejection exposed an already-baked deleted road before rollback drawing")
		f.tick();f.ready(0,false);f.tick();assert(f.hidden[token],"rollback proxy cleared before repaired geometry")
		f.ready(0,true);f.tick();assert(not f.hidden[token],"completed rollback leaked its proxy")
		f.cleanup()
	end)
	it("includes old and projected cells of upgraded roads and their direct neighbors",function()
		local f=fixture()
		local token=assert(f.preview.replace(1,"LocalRoad"))
		local cells=f.hiddenCells[token]
		assert(cells["0,0"] and cells["1,0"],"upgrade omitted one side of a crossed cell boundary")
		assert(cells["neighbor-old"] and cells["neighbor-new"],"junction neighbor moved outside the preview cells")
		f.cleanup()
	end)
	it("rolls back the rejected edit and preserves another pending edit",function()
		local f=fixture()
		local a=assert(f.preview.remove({{id=1}}))
		local b=assert(f.preview.remove({{id=2}}))
		assert(f.overrides[a][1] == false and f.overrides[b][2] == false)
		f.result(false,a,0)
		assert(f.overrides[a] == nil and f.overrides[b] ~= nil,"rejected edit did not roll back independently")
		f.cleanup()
	end)
	it("holds prediction until its revision is received AND the renderer has finished",function()
		local f=fixture()
		local token=assert(f.preview.replace(1,"LocalRoad"))
		f.tick()
		f.result(true,token,7)
		f.ready(6,true);f.tick();assert(f.overrides[token] ~= nil,"cleared before authoritative revision")
		f.ready(7,false);f.tick();assert(f.overrides[token] ~= nil,"cleared before road drawing")
		f.ready(7,true);f.tick();assert(f.overrides[token] == nil,"confirmed preview leaked")
		f.cleanup()
	end)
	it("bounds overlapping edits and preserves survivors after out-of-order rejection",function()
		local f=fixture()
		local tokens={}
		for i=1,32 do tokens[i]=assert(f.preview.remove({{id=i}})) end
		assert(f.preview.remove({{id=33}})==nil,"pending predictions exceeded their cap")
		f.result(false,tokens[16],0)
		assert(f.overrides[tokens[16]]==nil and f.overrides[tokens[1]] and f.overrides[tokens[32]],"rejection disturbed overlapping survivors")
		f.tick();f.ready(0,true);f.tick()
		assert(f.preview.remove({{id=33}})~=nil,"completed rollback did not release its pending slot")
		f.cleanup()
		assert(next(f.overrides)==nil and next(f.hidden)==nil,"cleanup leaked overlapping prediction state")
	end)
	it("restores authority after a missing acknowledgement and on cleanup",function()
		local f=fixture()
		local token=assert(f.preview.remove({{id=1}}))
		f.tick();f.expire();f.tick()
		assert(f.overrides[token] == nil,"timed out prediction leaked")
		local other=assert(f.preview.remove({{id=2}}))
		f.cleanup();assert(f.overrides[other] == nil)
	end)
end
