--!strict
return function()
	it("starts one road renderer when callers overlap while waiting for the city", function()
		local view = script.Parent
		local source = view.Source
		local first = assert(source:find("function RoadMeshView.Start()",1,true))
		local last = assert(source:find("\n-- True when no road rebuild",first,true))
		local root = Instance.new("Folder")
		root:SetAttribute("RoadMeshV2",false)
		local pumps, finished = 0, 0
		local signal = { Connect = function() return {} end }
		local env = setmetatable({
			workspace=root, RoadMeshView={}, FOLDER_WAIT=1, _started=false,
			_cells={}, track=function() end, untrack=function() end,
			RoadMeshBuilder={LOT_TAG="fixture"},
			CollectionService={GetInstanceAddedSignal=function() return signal end,
				GetInstanceRemovedSignal=function() return signal end,GetTagged=function() return {} end},
			task={spawn=function() pumps+=1 end},
		},{__index=getfenv()})
		local loader=assert(loadstring(source:sub(first,last-1).."\nreturn RoadMeshView"))
		setfenv(loader,env)
		local module=loader()
		for _=1,2 do
			task.spawn(function() module.Start();finished+=1 end)
		end
		task.wait()
		local city=Instance.new("Folder");city.Name="_City"
		local roads=Instance.new("Folder");roads.Name="Roads";roads.Parent=city
		city.Parent=root
		local deadline=os.clock()+1
		while finished<2 and os.clock()<deadline do task.wait() end
		local containers=0
		for _,child in root:GetChildren() do if child.Name=="_RoadMeshes" then containers+=1 end end
		root:Destroy()
		assert(finished==2,"road startup fixture timed out")
		assert(containers==1 and pumps==1,"overlapping starts duplicated road meshes and workers")
	end)
end
