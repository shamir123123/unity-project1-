--!strict
-- RoadMeshBuilder.addFootway: the kerb band is KERB_TOP_WIDTH wide, on the ROAD side, in
-- KERB_COLOR (top band + road-facing face), and never wider than half a narrow footway.
-- No framework -- `require(...).run()` asserts.
local RoadConstants = require(script.Parent.RoadConstants)
local RoadMeshBuilder = require(script.Parent.RoadMeshBuilder)

local Spec = {}

local function footway(width: number)
	local b = RoadMeshBuilder.new()
	b:addFootway(
		{ Vector3.new(0, 1, 0), Vector3.new(0, 1, 10) },
		{ Vector3.new(width, 1, 0), Vector3.new(width, 1, 10) },
		{ Vector3.new(0, 0, 0), Vector3.new(0, 0, 10) },
		{ Vector3.new(width, 0, 0), Vector3.new(width, 0, 10) },
		RoadConstants.SIDEWALK_COLOR, 1
	)
	return RoadMeshBuilder.decodeSpecs(b:encode())
end

local function railX(spec, k: number): number
	return (spec.strip :: { Vector3 })[k].X
end

function Spec.run(): boolean
	local kerbW = RoadConstants.KERB_TOP_WIDTH
	local specs = footway(6)
	assert(#specs == 4, `expected 4 strips, got {#specs}`)
	local band, walk, face, back = specs[1], specs[2], specs[3], specs[4]
	assert(band.color == RoadConstants.KERB_COLOR and face.color == RoadConstants.KERB_COLOR, "kerb band and road face wear KERB_COLOR")
	assert(walk.color == RoadConstants.SIDEWALK_COLOR and back.color == RoadConstants.SIDEWALK_COLOR, "walk and back face wear the footway colour")
	assert(math.abs(railX(band, 1)) < 1e-4 and math.abs(railX(band, 2) - kerbW) < 1e-4, `band spans road edge to {kerbW}: {railX(band, 1)}..{railX(band, 2)}`)
	assert(math.abs(railX(walk, 1) - kerbW) < 1e-4 and math.abs(railX(walk, 2) - 6) < 1e-4, "walk runs from the band to the back edge")
	assert(math.abs(railX(face, 1)) < 1e-4 and math.abs(railX(face, 2)) < 1e-4, "kerb face stands on the road edge")
	local narrow = footway(kerbW)
	assert(math.abs(railX(narrow[1], 2) - kerbW * 0.5) < 1e-4, "band never wider than half the footway")
	return true
end

return Spec
