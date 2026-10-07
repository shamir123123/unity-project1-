--!strict
return function()
	local source=script.Parent.Source
	local originalClaim=[==[local function claimDist(claims: { Claim }, origin: Vector3, dir: Vector3, reach: number, skip: Claim?): number
	local eX, eZ = origin.X + dir.X * reach, origin.Z + dir.Z * reach
	local rMinX, rMaxX = math.min(origin.X, eX), math.max(origin.X, eX)
	local rMinZ, rMaxZ = math.min(origin.Z, eZ), math.max(origin.Z, eZ)
	local best = math.huge
	for _, q in claims do
		if q ~= skip and q.minX <= rMaxX and rMinX <= q.maxX and q.minZ <= rMaxZ and rMinZ <= q.maxZ then
			local a = q.pts[4]
			for i = 1, 4 do
				local b = q.pts[i]
				local t = rayEdgeHit(origin, dir, a, b)
				if t and t < best then best = t end
				a = b
			end
		end
	end
	return best
end]==]
	local originalOverlap=[==[local function resolveParcelOverlaps(out: { Placement })
	local n = #out
	if n < 2 then return end
	local box: { { number } } = table.create(n)
	local function refresh(i: number)
		local p = out[i].plot
		box[i] = {
			math.min(p.frontA.X, p.frontB.X, p.backA.X, p.backB.X),
			math.max(p.frontA.X, p.frontB.X, p.backA.X, p.backB.X),
			math.min(p.frontA.Z, p.frontB.Z, p.backA.Z, p.backB.Z),
			math.max(p.frontA.Z, p.frontB.Z, p.backA.Z, p.backB.Z),
		}
	end
	for i = 1, n do refresh(i) end
	-- Depth only ever decreases (or a parcel is blocked), so state strictly shrinks and the loop
	-- converges; the pass cap is a hard stop, not the expected exit.
	for _ = 1, 32 do
		local changed = false
		for i = 1, n do
			local A = out[i]
			if not A.blocked then
				local ba = box[i]
				for j = i + 1, n do
					local B = out[j]
					local bb = box[j]
					if not B.blocked
						and ba[1] <= bb[2] and bb[1] <= ba[2] and ba[3] <= bb[4] and bb[3] <= ba[4]
						and rectPenetration(parcelCorners(A), parcelCorners(B)) > NEIGHBOR_TOL then
						local ad, bd = parcelDepthLots(A), parcelDepthLots(B)
						local deep, deepI, deepD = A, i, ad
						if bd > ad then deep, deepI, deepD = B, j, bd end
						if deepD <= 2 then -- deeper one is already minimal: shrink the other instead
							if deep == A then deep, deepI, deepD = B, j, bd else deep, deepI, deepD = A, i, ad end
						end
						if deepD > 2 then
							setParcelDepth(deep, deepD - 1)
							refresh(deepI)
						elseif A.parcelLots <= B.parcelLots then
							A.blocked = true
						else
							B.blocked = true
						end
						changed = true
					end
				end
			end
		end
		if not changed then break end
	end
end]==]
	local function harness(oracle: boolean?): (any,any)
		local text=source
		if oracle then
			local claim=originalClaim
			if string.find(text,"claimCells: SpatialCells",1,true) then
				claim=string.gsub(claim,"claims: { Claim }, origin:","claims: { Claim }, claimCells: any, origin:",1)
			end
			text=string.gsub(text,"local function claimDist%([^\n]-\n.-\nend\n",function() return claim.."\n" end,1)
			text=string.gsub(text,"local function resolveParcelOverlaps%([^\n]-\n.-\nend\n",function() return originalOverlap.."\n" end,1)
		end
		text=string.gsub(text,"if q ~= skip and q.minX","_claimChecks += 1\n if q ~= skip and q.minX",1)
		text=string.gsub(text,"local B = out%[j%]","_overlapChecks += 1\n local B = out[j]",1)
		text=string.gsub(text,"\n([ \t]*)for ([^\n]-) do\n","\n%1for %2 do\n _guard()\n")
		text=string.gsub(text,"\n([ \t]*)while ([^\n]-) do\n","\n%1while %2 do\n _guard()\n")
		local env: any=setmetatable({_claimChecks=0,_overlapChecks=0,_deadline=os.clock()+3},{__index=getfenv()})
		local steps=0
		env._guard=function() steps+=1;if steps%1024==0 and os.clock()>env._deadline then error("diagnostic deadline",0) end end
		local fn=assert(loadstring(text));setfenv(fn,env)
		return fn(),env
	end
	local function road(id: number,a: Vector3,b: Vector3): any
		return {id=id,roadType="NarrowRoad",p0=a,p1=a:Lerp(b,1/3),p2=a:Lerp(b,2/3),p3=b}
	end
	local function equal(a: {any},b: {any}): ()
		assert(#a==#b,"polygon binning changed placement count")
		for i,p in a do
			local q=b[i]
			assert(p.segId==q.segId and p.side==q.side and p.blocked==q.blocked and p.w==q.w and p.d==q.d and p.pivot==q.pivot,"polygon binning changed a seat or shrinking decision")
			for _,key in {"frontA","frontB","backA","backB","depth","frontage","t0","t1"} do
				assert(p.plot[key]==q.plot[key],"polygon binning changed parcel "..key)
			end
		end
	end
	it("preserves exhaustive claim rays and pair order across rotated blocks and depth growth",function()
		local G,env=harness()
		local old,oldEnv=harness(true)
		local rng=Random.new(707)
		for iteration=1,24 do
			env._deadline=os.clock()+3;oldEnv._deadline=env._deadline
			local frame=CFrame.new(rng:NextNumber(-180,180),0,rng:NextNumber(-180,180))*CFrame.Angles(0,rng:NextNumber(-math.pi,math.pi),0)
			local function p(x: number,z: number): Vector3 return frame*Vector3.new(x,0,z) end
			local roads={road(1,p(-240,-80),p(240,-80)),road(2,p(-240,80),p(240,80)),
				road(3,p(-240,-80),p(-240,80)),road(4,p(240,-80),p(240,80))}
			if iteration%2==0 then
				roads[5]=road(5,p(-150,-80),p(180,80))
				roads[5].p1=p(-30,-120);roads[5].p2=p(20,110)
			end
			local poly={p(-235,-75),p(235,-75),p(235,75),p(-235,75)}
			local indexed=G.planPolygon(roads,G.buildRoadIndex(roads),poly,18,iteration%3==0,iteration%2==0)
			local exhaustive=old.planPolygon(roads,old.buildRoadIndex(roads),poly,18,iteration%3==0,iteration%2==0)
			equal(indexed,exhaustive)
		end
	end)
	it("bounds claim and overlap candidate work when an area contains thousands of parcels",function()
		local G,env=harness()
		local roads={}
		for row=0,29 do local z=(row-14.5)*64;roads[row+1]=road(row+1,Vector3.new(-540,0,z),Vector3.new(540,0,z)) end
		local poly={Vector3.new(-540,0,-960),Vector3.new(540,0,-960),Vector3.new(540,0,960),Vector3.new(-540,0,960)}
		local placements=G.planPolygon(roads,G.buildRoadIndex(roads),poly,18,true,false)
		assert(#placements>=1400,"fixture did not produce the intended parcels")
		assert(env._claimChecks<600000,"claim rays still scan every parcel")
		assert(env._overlapChecks<200000,"overlap resolution still scans every pair")
	end)
end
