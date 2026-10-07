--!strict
return function()
	local source=script.Parent.Source
	local function harness(props: {any}): (any, any, any)
		local first=assert(string.find(source,"local function nearQuad(",1,true))
		local last=assert(string.find(source,"-- ----------------------------------------------------- roads over buildings",first,true))
		local text=string.sub(source,first,last-1)
		text=string.gsub(text,"local function nearQuad%((.-)%): boolean","local function nearQuad(%1): boolean\n _checks += 1",1)
		local env: any=setmetatable({_checks=0,PlacementFit={},NatureCatalog={get=function(key)
			if key=="tree" then return {kind="Tree",radius=6} end
			if key=="lot" then return {kind="Lot",radius=20} end
			return nil
		end}},{__index=getfenv()})
		local nature={GetChildren=function() return props end}
		env.PlacementFit.cityRoot=function() return {FindFirstChild=function() return nature end} end
		local fn=assert(loadstring(text.."\nreturn PlacementFit.propsInRects,nearQuad"))
		setfenv(fn,env)
		local query,exact=fn()
		return query,exact,env
	end
	local function prop(position: Vector3,scale: number?,key: string?): any
		local model: any={position=position,scale=scale,key=key or "tree"}
		model.IsA=function() return true end
		model.GetAttribute=function(_,name) return if name=="NatureKey" then model.key else model.scale end
		model.GetPivot=function() return CFrame.new(model.position) end
		return model
	end
	local function rect(frame: CFrame,w: number,d: number): {Vector3}
		return {frame*Vector3.new(-w,0,-d),frame*Vector3.new(w,0,-d),frame*Vector3.new(w,0,d),frame*Vector3.new(-w,0,d)}
	end
	it("matches exhaustive rotated-parcel tests including scaled props and wide bounds",function()
		local rng=Random.new(228)
		local rects,props={},{}
		for _=1,400 do
			local frame=CFrame.new(rng:NextNumber(-600,600),0,rng:NextNumber(-600,600))*CFrame.Angles(0,rng:NextNumber(-math.pi,math.pi),0)
			table.insert(rects,rect(frame,rng:NextNumber(5,40),rng:NextNumber(5,60)))
		end
		table.insert(rects,rect(CFrame.new(3000,0,3000),1000,1000))
		for i=1,600 do table.insert(props,prop(Vector3.new(rng:NextNumber(-800,800),0,rng:NextNumber(-800,800)),rng:NextNumber(.4,4),if i%17==0 then "lot" else "tree")) end
		table.insert(props,prop(Vector3.new(3000,0,3000)))
		table.insert(props,prop(Vector3.new(1500,0,1500),300))
		local query,exact=harness(props)
		local expected={}
		for _,m in props do
			if m.key~="tree" then continue end
			for _,c in rects do
				if exact(c,m.position.X,m.position.Z,6*(m.scale or 1)) then table.insert(expected,m);break end
			end
		end
		local actual=query(rects)
		assert(#actual==#expected,"indexed prop selection differs from exhaustive selection")
		for i,m in actual do assert(m==expected[i],"indexed selection changed membership/order") end
	end)
	it("does not retain stale prop positions or deleted instances between queries",function()
		local props={prop(Vector3.new(500,0,500))}
		local query=harness(props)
		local rects={rect(CFrame.identity,10,10)}
		assert(#query(rects)==0,"far prop unexpectedly selected")
		props[1].position=Vector3.zero
		assert(#query(rects)==1,"moved prop was missed")
		table.clear(props)
		assert(#query(rects)==0,"deleted prop survived in an index")
	end)
	it("prunes exact checks for 3000 parcels and 2200 props",function()
		local props,rects={},{}
		for z=0,49 do for x=0,59 do table.insert(rects,rect(CFrame.new(x*36,0,z*36),9,12)) end end
		local rng=Random.new(410)
		for _=1,2200 do table.insert(props,prop(Vector3.new(rng:NextNumber(-30,2190),0,rng:NextNumber(-30,1830)))) end
		local query,_,env=harness(props)
		query(rects)
		assert(env._checks<30000,"prop queries still scale as every prop times every parcel")
	end)
	it("allows a caller to yield while preparing a large preview",function()
		local props,rects={},{}
		for i=1,64 do table.insert(props,prop(Vector3.new(i*32,0,0)));table.insert(rects,rect(CFrame.new(i*32,0,0),8,8)) end
		local query=harness(props)
		local slices=0
		local actual=query(rects,function() slices+=1 end)
		assert(slices>=4,"large query did not offer bounded work checkpoints")
		assert(#actual==64,"yield checkpoints changed selection")
	end)
end
