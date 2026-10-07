--!strict
return function()
	it("matches exhaustive overlap decisions across rotated seats and cell boundaries",function()
		local geom=require(game.ReplicatedStorage.City.PlotGeometry)
		local index=require(script.Parent).new(64,.3,geom.rectPenetration)
		local accepted: {{Vector3}}={}
		local rng=Random.new(31415)
		for _=1,600 do
			local frame=CFrame.new(rng:NextNumber(-150,150),0,rng:NextNumber(-150,150))*CFrame.Angles(0,rng:NextNumber(-math.pi,math.pi),0)
			local w,d=rng:NextNumber(4,40),rng:NextNumber(4,40)
			local c={frame*Vector3.new(-w,0,-d),frame*Vector3.new(w,0,-d),frame*Vector3.new(w,0,d),frame*Vector3.new(-w,0,d)}
			local expected=true
			for _,other in accepted do if geom.rectPenetration(other,c)>.3 then expected=false;break end end
			assert(index.add(c)==expected,"indexed overlap differs from exact scan")
			if expected then table.insert(accepted,c) end
		end
		index.clear()
		assert(index.add(accepted[1]),"old preview seats survived clear")
	end)
end