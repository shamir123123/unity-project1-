--!strict
return function()
	local module=script.Parent
	local source=module.Source
	local function geometry(): any
		local text=string.gsub(source,"\n([ \t]*)for ([^\n]-) do\n","\n%1for %2 do\n _guard()\n")
		text=string.gsub(text,"\n([ \t]*)while ([^\n]-) do\n","\n%1while %2 do\n _guard()\n")
		local deadline=os.clock()+3
		local steps=0
		local fn=assert(loadstring(text))
		setfenv(fn,setmetatable({script=module,_guard=function()
			steps+=1
			if steps%1024==0 then assert(os.clock()<deadline,"diagnostic deadline") end
		end},{__index=getfenv()}))
		return fn()
	end
	local function road(id: number,a: Vector3,b: Vector3): any
		return {id=id,roadType="NarrowRoad",p0=a,p1=a:Lerp(b,1/3),p2=a:Lerp(b,2/3),p3=b}
	end
	local function fixture(): (any,{any},{Vector3})
		local G=geometry()
		local roads={}
		for i=1,12 do
			local z=(i-6.5)*64
			roads[i]=road(i,Vector3.new(-360,0,z),Vector3.new(360,0,z))
		end
		return G,roads,{Vector3.new(-360,0,-384),Vector3.new(360,0,-384),Vector3.new(360,0,384),Vector3.new(-360,0,384)}
	end
	local function equal(a: {any},b: {any}): ()
		assert(#a==#b,"checkpoint changed plan size")
		for i,p in a do
			local q=b[i]
			assert(p.segId==q.segId and p.side==q.side and p.w==q.w and p.d==q.d and p.blocked==q.blocked and p.pivot==q.pivot,"checkpoint changed fitted seat")
			for _,key in {"frontA","frontB","backA","backB","t0","t1","depth","frontage"} do
				assert(p.plot[key]==q.plot[key],"checkpoint changed parcel "..key)
			end
		end
	end
	it("can cancel index construction before publishing a partial index",function()
		local G,roads=fixture()
		local checks=0
		local ok,err=pcall(function() G.buildRoadIndex(roads,nil,function()
			checks+=1
			if checks==8 then error("cancel index",0) end
		end) end)
		assert(not ok and err=="cancel index","index construction ignored cancellation")
	end)
	it("supports checkpoints throughout frontage and cap planning without changing seats",function()
		local G,roads=fixture()
		local index=G.buildRoadIndex(roads)
		local calls=0
		local function breathe() calls+=1 end
		equal(G.planSpan(index,roads[1],1,0,1,24,18,true,true,breathe),G.planSpan(index,roads[1],1,0,1,24,18,true,true))
		assert(calls>20,"frontage planning never checked its work budget")
		local before=calls
		G.packPlots(roads[1],1,0,1,24,18,true,nil,breathe)
		G.groupParcels(roads[1],1,0,1,24,18,true,breathe)
		assert(calls>before,"parcel rebuild ignored its checkpoint")
		before=calls
		equal(G.planCapRing(index,roads[1],true,0,1,24,18,true,breathe),G.planCapRing(index,roads[1],true,0,1,24,18,true))
		assert(calls>before,"cap planning ignored its checkpoint")
	end)
	it("preserves polygon output when checkpoints yield and query the same road index",function()
		local G,roads,poly=fixture()
		local index=G.buildRoadIndex(roads)
		local expected=G.planPolygon(roads,index,poly,18,true,false)
		local checks,yields=0,0
		local actual: {any}?=nil
		local worker=coroutine.create(function()
			actual=G.planPolygon(roads,index,poly,18,true,false,function()
				checks+=1
				if checks%32==0 then
					G.planSpan(index,roads[1],-1,.1,.2,18,18,true)
					yields+=1
					coroutine.yield()
				end
			end)
		end)
		repeat local ok,err=coroutine.resume(worker);assert(ok,err) until coroutine.status(worker)=="dead"
		assert(yields>0,"polygon planning never yielded")
		equal(assert(actual),expected)
	end)
	it("propagates cancellation during polygon planning instead of returning a partial plan",function()
		local G,roads,poly=fixture()
		local index=G.buildRoadIndex(roads)
		local checks=0
		local result: {any}?=nil
		local ok,err=pcall(function()
			result=G.planPolygon(roads,index,poly,18,true,false,function()
				checks+=1
				if checks==64 then error("cancel polygon",0) end
			end)
		end)
		assert(not ok and err=="cancel polygon" and not result,"polygon returned after cancellation")
	end)
end
