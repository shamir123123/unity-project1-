--!strict
return function()
	local function fixture(segments: {any}?, allowed: boolean?, cost: number?)
		local view=script.Parent
		local a=assert(view.Source:find("local MAX_PREDICTION_CELLS",1,true),"missing immediate road feedback")
		local b=assert(view.Source:find("local BOX_CORNERS",a,true))
		local root=Instance.new("Folder")
		local mesh=Instance.new("MeshPart")
		mesh.Parent=root
		local current=segments or {}
		local env=setmetatable({
			_cells={["0,0"]={meshes={mesh},details={},symbols={},models={},version=1,bakedVersion=0}},
			_started=true,_v2=true,RoadMeshView={},workspace=root,
			RoadPieces={isIdle=function() return true end,coversModel=function() return allowed~=false end,
				segmentsForCells=function() return current end},
			RoadPreviewGeometry={draw=function(model: Model,seg: any,_cells: any,allowance: number)
				local n=cost or 1
				if allowance<n then return false,0 end
				local part=Instance.new("Part");part.Name=tostring(seg.id);part.Parent=model
				return true,n
			end},
		},{__index=getfenv()})
		local loader=assert(loadstring(view.Source:sub(a,b-1)));setfenv(loader,env);loader()
		return {view=env.RoadMeshView,mesh=mesh,root=root,
			setSegments=function(value: {any}) current=value end, cells=env._cells}
	end
	it("holds a hidden cell until every overlapping prediction completes",function()
		local f=fixture({{id=1}})
		assert(f.view.hidePredictionCells(1,{["0,0"]=true}))
		assert(f.view.hidePredictionCells(2,{["0,0"]=true}))
		f.view.clearPredictionCells(1)
		assert(f.mesh.LocalTransparencyModifier==1,"another pending edit lost its cell override")
		f.view.clearPredictionCells(2)
		assert(f.mesh.LocalTransparencyModifier==0,"confirmed cell remained hidden")
		f.root:Destroy()
	end)
	it("replaces older proxies with the latest projected roads",function()
		local f=fixture({{id=1},{id=2}})
		assert(f.view.hidePredictionCells(1,{["0,0"]=true}))
		f.setSegments({{id=2}})
		assert(f.view.hidePredictionCells(2,{["0,0"]=true}))
		local model=f.root:FindFirstChild("_PendingRoadCells")
		assert(model and not model:FindFirstChild("1") and model:FindFirstChild("2"),"old prediction resurrected a deleted road")
		f.view.clearPredictionCells(1);f.view.clearPredictionCells(2)
		f.root:Destroy()
	end)
	it("keeps the authoritative view when temporary feedback exceeds its budget",function()
		local f=fixture({{id=1}},true,257)
		assert(not f.view.hidePredictionCells(1,{["0,0"]=true}))
		assert(f.mesh.LocalTransparencyModifier==0 and not f.root:FindFirstChild("_PendingRoadCells"),"oversized proxy hid the real road")
		f.root:Destroy()
	end)
	it("reconciles its own cells without waiting for unrelated city meshes", function()
		local f=fixture({{id=1}})
		f.cells["1,1"]={version=10,bakedVersion=0}
		assert(f.view.hidePredictionCells(1,{["0,0"]=true}))
		assert(not f.view.isPredictionReady(1),"unbaked edit was released")
		f.cells["0,0"].bakedVersion=1
		assert(f.view.isPredictionReady(1),"unrelated city bake blocked an accepted edit")
		f.view.clearPredictionCells(1)
		f.root:Destroy()
	end)
	it("keeps a prediction while a newer version of its cell is baking", function()
		local f=fixture({{id=1}})
		assert(f.view.hidePredictionCells(1,{["0,0"]=true}))
		f.cells["0,0"].bakedVersion=1
		f.cells["0,0"].version=2
		assert(not f.view.isPredictionReady(1),"stale mesh released prediction")
		f.cells["0,0"].bakedVersion=2
		assert(f.view.isPredictionReady(1))
		f.view.clearPredictionCells(1)
		f.root:Destroy()
	end)
end