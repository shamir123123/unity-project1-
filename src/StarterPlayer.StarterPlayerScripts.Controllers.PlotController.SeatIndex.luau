--!strict
-- Exact overlap checks restricted to neighbouring preview seats.
local SeatIndex = {}
type Corners = { Vector3 }
export type Index = { add: (Corners) -> boolean, clear: () -> () }
function SeatIndex.new(cellSize: number, tolerance: number, penetration: (Corners, Corners) -> number): Index
	local cells: { [string]: { Corners } } = {}
	local function bounds(corners: Corners): (number, number, number, number)
		local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
		for _, p in corners do
			minX, minZ = math.min(minX, p.X), math.min(minZ, p.Z)
			maxX, maxZ = math.max(maxX, p.X), math.max(maxZ, p.Z)
		end
		return math.floor(minX/cellSize), math.floor(minZ/cellSize), math.floor(maxX/cellSize), math.floor(maxZ/cellSize)
	end
	local function add(corners: Corners): boolean
		local x0,z0,x1,z1 = bounds(corners)
		local checked: { [Corners]: boolean } = {}
		for x=x0,x1 do for z=z0,z1 do
			for _, other in cells[x..":"..z] or {} do
				if not checked[other] then
					checked[other] = true
					if penetration(other, corners) > tolerance then return false end
				end
			end
		end end
		for x=x0,x1 do for z=z0,z1 do
			local key=x..":"..z
			local bucket=cells[key]
			if not bucket then bucket={}; cells[key]=bucket end
			table.insert(bucket,corners)
		end end
		return true
	end
	return { add=add, clear=function() table.clear(cells) end }
end
return table.freeze(SeatIndex)
