--!strict
return function()
	it("keeps a published road snapshot stable while a renderer yields", function()
		local module=script.Parent:Clone()
		local cache=require(module)
		cache.SetSegments({{id=1,roadType="NarrowRoad"}})
		local first=cache.GetSegments()
		cache.ApplySegmentsDelta({changed={{id=2,roadType="CollectorRoad"}},removed={1}})
		assert(#first==1 and first[1].id==1, "a later delta overwrote the renderer's pending snapshot")
		assert(cache.GetSegments()[1].id==2)
		module:Destroy()
	end)
end