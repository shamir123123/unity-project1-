--!strict
return function()
	local root = game.ServerScriptService.Services.Terrain
	local constants = require(game.ReplicatedStorage.Terrain.TerrainConstants)
	local source = script.Parent.Source
	local function nearest(text: string): any
		local fn = assert(loadstring(string.gsub(text, "return TerrainPadService%s*$", "return nearestRoadY")))
		setfenv(fn, setmetatable({script=script.Parent, require=function(target: Instance): any
			return if target==root.TerrainDataService then {} else require(target)
		end}, {__index=getfenv()}))
		local query=fn()
		return function(led: any,gx: number,gz: number,wx: number,wz: number,rows: any): (number?,number?)
			return query(led,gx,gz,wx,wz,rows,math.max(0,gx-32),math.min(2048,gx+32))
		end
	end
	local function exhaustive(led: any, gx: number, gz: number): (number?, number)
		local nearestY, nearestDistance = nil, math.huge
		for dz=-4,4 do for dx=-4,4 do
			local rx,rz=math.clamp(gx+dx,0,2048),math.clamp(gz+dz,0,2048)
			local raw=led:targetForOwnerKind(rx,rz,"road:",constants.Flag.LOCKED)
			if not raw then continue end
			local distance=math.sqrt((rx-gx)^2+(rz-gz)^2)*4
			if distance<nearestDistance then nearestY=constants.rawToWorldY(raw);nearestDistance=distance end
		end end
		return nearestY,nearestDistance
	end
	it("keeps exhaustive nearest-corner selection and row-column ties at map boundaries",function()
		local query=nearest(source)
		local rng=Random.new(239)
		for _,center in {{1024,1024},{0,0},{2048,2048},{0,2048},{2048,0}} do
			local claims={}
			for dz=-12,12 do for dx=-12,12 do
				local x,z=math.clamp(center[1]+dx,0,2048),math.clamp(center[2]+dz,0,2048)
				if rng:NextNumber()<.2 then claims[z*2049+x]=rng:NextInteger(0,1000) end
			end end
			local led={targetForOwnerKind=function(_,x,z) return claims[z*2049+x] end}
			local cache={}
			for dz=-4,4 do for dx=-4,4 do
				local x,z=math.clamp(center[1]+dx,0,2048),math.clamp(center[2]+dz,0,2048)
				local y,d=query(led,x,z,constants.cornerToWorld(x),constants.cornerToWorld(z),cache)
				local expectedY,expectedD=exhaustive(led,x,z)
				assert(y==expectedY and math.abs(d-expectedD)<1e-10,"nearest road or equal-distance tie changed")
			end end
		end
		local led={targetForOwnerKind=function(_,x,z) return if x==1024 and z==1023 then 50 elseif x==1023 and z==1024 then 80 else nil end}
		local y=query(led,1024,1024,0,0,{})
		assert(y==constants.rawToWorldY(50),"equal distance must retain earlier row")
	end)
	it("shares absent-corner work across one pad while retaining live road targets",function()
		local query=nearest(source)
		local calls=0
		local claims={}
		local led={targetForOwnerKind=function(_,x,z) calls+=1;return claims[z*2049+x] end}
		local cache={}
		for z=1000,1020 do for x=1000,1020 do
			query(led,x,z,constants.cornerToWorld(x),constants.cornerToWorld(z),cache)
		end end
		assert(calls<=65*29,"empty road corners are re-read for every pad corner")
		claims[1000*2049+1000]=100
		local y=query(led,1000,1000,constants.cornerToWorld(1000),constants.cornerToWorld(1000),{})
		assert(y==constants.rawToWorldY(100),"next application kept a stale absent road claim")
		local liveCache={}
		claims[1000*2049+1000]=120
		y=query(led,1000,1000,constants.cornerToWorld(1000),constants.cornerToWorld(1000),liveCache)
		assert(y==constants.rawToWorldY(120))
		claims[1000*2049+1000]=140
		y=query(led,1000,1000,constants.cornerToWorld(1000),constants.cornerToWorld(1000),liveCache)
		assert(y==constants.rawToWorldY(140),"present road target must stay authoritative")
	end)
	it("preserves pad earthworks, overlapping ownership, and natural-ground release",function()
		local originalRequire=require
		local reference=string.gsub(source,"local function nearestRoadY.-\nend\n",[==[local function nearestRoadY(led: any, gx: number, gz: number, wx: number, wz: number): (number?, number?)
	local cornerStep = math.abs(cornerToWorld(1) - cornerToWorld(0))
	local searchCells = math.max(1, math.ceil(ROAD_JOIN_MAX / math.max(cornerStep, 0.01)) + 1)
	local nearestDist = math.huge
	local nearestY: number? = nil

	for dz = -searchCells, searchCells do
		local rz = math.clamp(gz + dz, 0, MAX_CORNER)
		local roadZ = cornerToWorld(rz)
		for dx = -searchCells, searchCells do
			local rx = math.clamp(gx + dx, 0, MAX_CORNER)
			-- One prefix: segments and corner connectors both claim under "road:" now (see
			-- TerrainGradeService.ROAD_KIND -- splitting them was burying carriageways).
			-- Only the road's LOCKED bed is the road. Its soft bank runs 16 studs out at
			-- natural-ground height; joining to that on a hillside copied the bank's height
			-- into a locked strip that cut a trench through the next lot along.
			local raw = led:targetForOwnerKind(rx, rz, "road:", FLAG_LOCKED)
			if raw then
				local roadX = cornerToWorld(rx)
				local deltaX = roadX - wx
				local deltaZ = roadZ - wz
				local distance = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
				if distance < nearestDist then
					nearestDist = distance
					nearestY = rawToWorldY(raw)
				end
			end
		end
	end

	return nearestY, nearestDist
end
]==],1)
		local function fixture(text: string): (any,any,any)
			local hm=originalRequire(game.ReplicatedStorage.Terrain.Heightmap).new()
			local led=originalRequire(root.TerrainOverlayLedger).new(hm)
			local fake={getOverlayLedger=function() return led end,getHeightAt=function(x,z) return hm:getHeightAt(x,z) end}
			local fn=assert(loadstring(text))
			setfenv(fn,setmetatable({script=script.Parent,require=function(target)
				return if target==root.TerrainDataService then fake else originalRequire(target)
			end},{__index=getfenv()}))
			return fn(),hm,led
		end
		local pad,hm,led=fixture(source)
		local baseline,expected,referenceLedger=fixture(reference)
		local flags=constants.Flag.LOCKED+constants.Flag.ROAD_GRADED
		local function road(ledger: any,y: number,z: number?)
			ledger:release("road:test");ledger:beginOwner("road:test")
			for x=1018,1030 do ledger:write("road:test",x,z or 1019,constants.worldYToRaw(y),flags) end
		end
		local pivot=CFrame.new(0,20,0)
		local natural={}
		for z=1000,1048 do for x=1000,1048 do
			local raw=constants.worldYToRaw((x-1024)*.25+(z-1024)*.5)
			hm:setCorner(x,z,raw);expected:setCorner(x,z,raw);natural[z*2049+x]=raw
		end end
		road(led,15);road(referenceLedger,15)
		for _,stage in {.25,.5,.75,1} do
			pad.padFootprint("a",pivot,18,24,20,stage,false)
			pad.padFootprint("b",CFrame.new(12,22,4),18,24,22,stage,true)
			baseline.padFootprint("a",pivot,18,24,20,stage,false)
			baseline.padFootprint("b",CFrame.new(12,22,4),18,24,22,stage,true)
			for z=1000,1048 do for x=1000,1048 do
				assert(hm:getCorner(x,z)==expected:getCorner(x,z),"earthwork differs from exhaustive road lookup")
				assert(hm:getFlags(x,z)==expected:getFlags(x,z),"earthwork ownership flags changed")
				assert(led:naturalRaw(x,z)==referenceLedger:naturalRaw(x,z),"natural terrain changed")
			end end
			if stage==.5 then road(led,17,1029);road(referenceLedger,17,1029) end
		end
		assert(hm:getCorner(1024,1024)==constants.worldYToRaw(18),"finished footprint changed")
		assert(hm:getCorner(1024,1029)==constants.worldYToRaw(17),"hard road bed was overwritten")
		pad.unpadFootprint("a");pad.unpadFootprint("b");led:release("road:test")
		for z=1000,1048 do for x=1000,1048 do
			assert(hm:getCorner(x,z)==natural[z*2049+x],"releasing pads did not restore natural ground")
			assert(hm:getFlags(x,z)==0,"released pad retained flags")
		end end
	end)
end
