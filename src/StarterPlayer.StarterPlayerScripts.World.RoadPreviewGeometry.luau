--!strict
-- Small, temporary solid road strips while the authoritative cell mesh is baking.
local RS = game:GetService("ReplicatedStorage")
local Bezier = require(RS.Road.BezierUtil)
local Constants = require(RS.Road.RoadConstants)
local Catalog = require(RS.Road.RoadTypeCatalog)
local RoadPreviewGeometry = {}
local SAMPLE_LENGTH = 24
local MAX_SAMPLES = 64
local CELL_SIZE = 256

function RoadPreviewGeometry.draw(model: Model, req: any, cells: { [string]: boolean }?, allowance: number?): (boolean, number)
	local spec = Catalog.getOrDefault(req.roadType)
	local width = spec.width
	local walkLeft, walkRight = Catalog.footwaySides(spec)
	local samples = math.clamp(math.ceil(Bezier.length(req.p0,req.p1,req.p2,req.p3,16)/SAMPLE_LENGTH),1,MAX_SAMPLES)
	local count = 0
	for i=1,samples do
		local a = Bezier.point(req.p0,req.p1,req.p2,req.p3,(i-1)/samples)
		local b = Bezier.point(req.p0,req.p1,req.p2,req.p3,i/samples)
		local mid = (a+b)*.5
		local key = math.floor(mid.X/CELL_SIZE)..","..math.floor(mid.Z/CELL_SIZE)
		if cells and not cells[key] then continue end
		local length = (b-a).Magnitude
		if length<.001 then continue end
		local frame=CFrame.lookAt(mid,b)
		for _,side in {0,-1,1} do
			local walk = if side < 0 then walkLeft else walkRight
			if side~=0 and walk<=0 then continue end
			if allowance and count>=allowance then return false,count end
			local part=Instance.new("Part")
			part.Name="PendingRoad"
			part.Anchored=true;part.CanCollide=false;part.CanTouch=false;part.CanQuery=false;part.CastShadow=false
			part.Material=if side==0 then Enum.Material.Asphalt else Enum.Material.Concrete
			part.Color=if side==0 then Constants.ROAD_COLOR else Constants.SIDEWALK_COLOR
			part.Size=Vector3.new(if side==0 then width else walk,Constants.ROAD_THICKNESS,length+.03)
			part.CFrame=frame*CFrame.new(side*(width+walk)*.5,if side==0 then .02 else Constants.SIDEWALK_HEIGHT+.02,0)
			part.Parent=model
			count+=1
		end
	end
	return true,count
end
return table.freeze(RoadPreviewGeometry)
