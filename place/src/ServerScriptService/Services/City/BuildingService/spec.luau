--!strict
return function()
	it("a two-throat front lot enters and leaves at opposite ends",function()
		local model=Instance.new("Model")
		model:SetAttribute("LotPlan","front");model:SetAttribute("StudsPerMetre",2)
		local anchor=Instance.new("Part");anchor.Name="FootprintAnchor";anchor.Size=Vector3.new(48,.2,60);anchor.Parent=model
		for name,pos in {LotEntry=Vector3.new(18,0,32),LotFront=Vector3.new(18,0,28),AisleHub=Vector3.new(18,0,24),S1=Vector3.new(0,0,15),S1_a=Vector3.new(0,0,24)} do
			local a=Instance.new("Attachment");a.Name=name;a.Position=pos;a.Parent=anchor
		end
		local source=script.Parent.Source
		local first=assert(source:find("function BuildingService.getParkSpots(",1,true))
		local last=assert(source:find("\nend",first,true))
		local env=setmetatable({BuildingService={},_buildings={lot={model=model}}},{__index=getfenv()})
		local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
		local result=env.BuildingService.getParkSpots("lot")
		model:Destroy()
		assert(result.lotExit and result.lotExit.X==-18,"exit reused the painted entrance")
		assert(result.stalls[1].route[1].X==18 and result.stalls[1].egress[#result.stalls[1].egress].X==-18)
	end)
end