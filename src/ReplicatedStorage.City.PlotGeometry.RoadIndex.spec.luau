--!strict
return function()
	local module=script.Parent
	local source=module.Source
	local originalRequire=require
	local function loadGeometry(): (any,any)
		local first=assert(string.find(source,"local function distToRect(",1,true))
		local text=string.sub(source,1,first-1)..string.gsub(string.sub(source,first),"local function distToRect%((.-)%): number","local function distToRect(%1): number\n _checks += 1\n if _checks %% 1024 == 0 and os.clock() > _deadline then error('diagnostic deadline',0) end",1)
		text=string.gsub(text,"\n([ \t]*)for ([^\n]-) do\n","\n%1for %2 do\n _guard()\n")
		text=string.gsub(text,"\n([ \t]*)while ([^\n]-) do\n","\n%1while %2 do\n _guard()\n")
		local env: any=setmetatable({script=module,require=originalRequire,_checks=0,_deadline=os.clock()+3},{__index=getfenv()})
		local steps=0
		env._guard=function()
			steps+=1
			if steps%1024==0 and os.clock()>env._deadline then error("diagnostic deadline",0) end
		end
		local fn=assert(loadstring(text));setfenv(fn,env)
		return fn(),env
	end
	local function road(id: number,a: Vector3,b: Vector3): any
		return {id=id,roadType="NarrowRoad",p0=a,p1=a:Lerp(b,1/3),p2=a:Lerp(b,2/3),p3=b}
	end
	local function exhaustive(index: any): any
		local copy=table.clone(index);copy.roadCells=nil;return copy
	end
	local function comparePlans(a: {any},b: {any}): ()
		assert(#a==#b,"road broadphase changed the placement count")
		for i,p in a do
			local q=b[i]
			assert(p.segId==q.segId and p.side==q.side and p.w==q.w and p.d==q.d and p.blocked==q.blocked and p.pivot==q.pivot,"road broadphase changed a fitted placement")
			for _,key in {"frontA","frontB","backA","backB","t0","t1","depth","frontage"} do
				assert(p.plot[key]==q.plot[key],"road broadphase changed parcel "..key)
			end
		end
	end
	it("matches exhaustive road tests for curved roads, dead-end discs, junctions and wide bounds",function()
		local G=loadGeometry()
		local rng=Random.new(411)
		local roads={}
		for i=1,120 do
			local a=Vector3.new(rng:NextNumber(-1200,1200),0,rng:NextNumber(-1200,1200))
			local b=a+Vector3.new(rng:NextNumber(30,200),0,rng:NextNumber(-100,100))
			local r=road(i,a,b);r.p1+=Vector3.new(0,0,35);r.p2-=Vector3.new(15,0,25);roads[i]=r
		end
		for i,p in {Vector3.new(200,0,0),Vector3.new(0,0,200),Vector3.new(-200,0,0),Vector3.new(0,0,-200)} do roads[120+i]=road(120+i,Vector3.zero,p) end
		roads[125]=road(125,Vector3.new(-4000,0,-4000),Vector3.new(4000,0,4000))
		local index=G.buildRoadIndex(roads)
		local old=exhaustive(index)
		for _=1,300 do
			local frame=CFrame.new(rng:NextNumber(-1400,1400),0,rng:NextNumber(-1400,1400))*CFrame.Angles(0,rng:NextNumber(-math.pi,math.pi),0)
			local w,d=rng:NextNumber(3,55),rng:NextNumber(3,55)
			local corners={frame*Vector3.new(-w,0,-d),frame*Vector3.new(w,0,-d),frame*Vector3.new(w,0,d),frame*Vector3.new(-w,0,d)}
			local own=rng:NextInteger(1,125)
			assert(G.rectOnRoad(index,corners,own)==G.rectOnRoad(old,corners,own),"indexed rect-road decision differs")
			assert(G.rectBlocked(index,corners,own)==G.rectBlocked(old,corners,own),"indexed point-road decision differs")
		end
		local corners={Vector3.new(-4000,0,-4000),Vector3.new(4000,0,-4000),Vector3.new(4000,0,4000),Vector3.new(-4000,0,4000)}
		assert(G.rectOnRoad(index,corners)==G.rectOnRoad(old,corners),"wide-query fallback differs")
	end)
	it("preserves complete span and polygon placements and rebuilds fresh after a road edit",function()
		local G=loadGeometry()
		local roads={road(1,Vector3.new(-180,0,-70),Vector3.new(180,0,-70)),road(2,Vector3.new(-180,0,70),Vector3.new(180,0,70)),
			road(3,Vector3.new(180,0,-70),Vector3.new(180,0,70))}
		local poly={Vector3.new(-180,0,-65),Vector3.new(175,0,-65),Vector3.new(175,0,65),Vector3.new(-180,0,65)}
		for _=1,2 do
			local index=G.buildRoadIndex(roads)
			local old=exhaustive(index)
			comparePlans(G.planSpan(index,roads[1],1,0,1,28,18,true),G.planSpan(old,roads[1],1,0,1,28,18,true))
			comparePlans(G.planPolygon(roads,index,poly,18,true,false),G.planPolygon(roads,old,poly,18,true,false))
			roads[3]=road(3,Vector3.new(120,0,-70),Vector3.new(120,0,70))
		end
	end)
	it("limits exact disc tests to the frontage neighbourhood in a large road network",function()
		local G,env=loadGeometry()
		local roads={}
		for i=1,1000 do
			local a=Vector3.new((i%100)*24-4000,0,math.floor(i/100)*48-4000)
			roads[i]=road(i,a,a+Vector3.new(12,0,0))
		end
		roads[1001]=road(1001,Vector3.new(0,0,100),Vector3.new(960,0,100))
		local index=G.buildRoadIndex(roads)
		env._checks=0
		local plans=G.planSpan(index,roads[1001],1,0,1,24,18,true)
		assert(#plans>40,"performance fixture did not plan the intended frontage")
		assert(env._checks<1000,"planning still checks every distant dead-end disc per seat")
	end)
end
