--!strict
return function()
	local module = script.Parent
	local C = require(game.ReplicatedStorage.Terrain.TerrainConstants)
	local R = require(game.ReplicatedStorage.Road.RoadConstants)
	local Cross = require(game.ReplicatedStorage.Terrain.RoadCrossSection)
	local function fixture(cancel: boolean?): any
		local data = module.Parent.TerrainDataService
		local clock = 0
		local service: any = nil
		local ledger = { beginOwner=function() return true end, release=function() end }
		local source = module.Source:gsub("local writes = 0", "if true then return bestDistanceSq,bestCenterY,bestIndex end\n\tlocal writes = 0",1)
		source = source:gsub("\nreturn TerrainGradeService", "\nTerrainGradeService.DebugRaster=gradeCenterline\nreturn TerrainGradeService",1)
		local loader = assert(loadstring(source))
		setfenv(loader,setmetatable({
			script=module, require=function(target: Instance): any
				return if target==data then { getOverlayLedger=function() return ledger end } else require(target)
			end,
			os=setmetatable({ clock=function()
				if cancel then clock+=0.01 end
				return clock
			end },{__index=os}),
			task=setmetatable({ wait=function()
				if cancel then service.ungradeSegmentId(1) end
			end },{__index=task}),
		},{__index=getfenv()}))
		service=loader()
		return service
	end

	local function oracle(pts: {Vector3}, width: number, walk: number): {any}
		local reach=Cross.footprintHalf(width,walk)+16
		local cut=math.max(width*.5+R.SIDEWALK_WIDTH+R.TUNNEL_WALL_THICKNESS,Cross.footprintHalf(width))
		local bed=math.min(reach,math.max(Cross.footprintHalf(width,walk),cut)+6)
		local minX,maxX,minZ,maxZ=math.huge,-math.huge,math.huge,-math.huge
		for _,p in pts do minX=math.min(minX,p.X);maxX=math.max(maxX,p.X);minZ=math.min(minZ,p.Z);maxZ=math.max(maxZ,p.Z) end
		local distances,heights,indices={},{},{}
		for gz=math.max(0,math.floor(C.worldToCorner(minZ-reach))),math.min(C.CORNERS_PER_AXIS-1,math.ceil(C.worldToCorner(maxZ+reach))) do
			for gx=math.max(0,math.floor(C.worldToCorner(minX-reach))),math.min(C.CORNERS_PER_AXIS-1,math.ceil(C.worldToCorner(maxX+reach))) do
				local key=gz*C.CORNERS_PER_AXIS+gx
				for i,p in pts do
					local dx,dz=p.X-C.cornerToWorld(gx),p.Z-C.cornerToWorld(gz)
					local d2=dx*dx+dz*dz
					local shoulder=(#pts<=16 or (i-1)%4==0 or i==#pts) and d2<=reach*reach
					if (d2<=bed*bed or shoulder) and (not distances[key] or d2<distances[key]) then
						distances[key],heights[key],indices[key]=d2,p.Y,i
					end
				end
			end
		end
		return {distances,heights,indices}
	end

	it("matches exhaustive nearest samples for curves, map edges and exact-radius corners", function()
		local service=fixture()
		for case=1,12 do
			local pts={}
			local count=if case%3==0 then 13 else 33
			local base=if case==11 then -C.MAP_HALF_EXTENT else if case==12 then C.MAP_HALF_EXTENT-40 else 0
			for i=0,count-1 do
				pts[i+1]=Vector3.new(base+i*2,20+math.sin(i*.4)*3,if case==1 then 0 else math.sin(i*.2+case)*18)
			end
			if case%2==0 then
				local reversed={}
				for i=#pts,1,-1 do reversed[#reversed+1]=pts[i] end
				pts=reversed
			end
			local width,walk=if case%2==0 then 64 else 16,4
			local expected=oracle(pts,width,walk)
			local actual={service.DebugRaster("road:seg:"..case,pts,0,0,0,0,width,false,nil,nil,walk,nil,walk)}
			for field=1,3 do
				for key,value in expected[field] do assert(actual[field][key]==value,"nearest-sample result changed") end
				for key,value in actual[field] do assert(expected[field][key]==value,"unexpected raster corner") end
			end
		end
	end)

	it("stops an old grade when its owner is removed across a budget yield", function()
		local service=fixture(true)
		local result=service.DebugRaster("road:seg:1",{Vector3.zero,Vector3.new(100,0,0)},0,0,0,0,64,false,nil,nil,4,nil,4)
		assert(result==nil,"cancelled grade continued rasterizing")
	end)
end
