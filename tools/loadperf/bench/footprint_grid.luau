-- Equivalence + scaling of BuildingService's footprint overlap test: brute force vs 64-stud grid.
local roblox = require("@lune/roblox")
local Vector3, CFrame = roblox.Vector3, roblox.CFrame
local function makeFootprint(pivot, wStuds, dStuds, segId)
	local a1 = pivot.RightVector; a1 = Vector3.new(a1.X, 0, a1.Z)
	a1 = if a1.Magnitude < 1e-4 then Vector3.xAxis else a1.Unit
	local a2 = pivot.LookVector; a2 = Vector3.new(a2.X, 0, a2.Z)
	a2 = if a2.Magnitude < 1e-4 then Vector3.zAxis else a2.Unit
	return { p = pivot.Position, a1 = a1, a2 = a2, hw = wStuds * 0.5, hd = dStuds * 0.5, seg = segId or -1 }
end
local function boxPenetration(A, B)
	local d = B.p - A.p
	d = Vector3.new(d.X, 0, d.Z)
	local minPen = math.huge
	for _, ax in { A.a1, A.a2, B.a1, B.a2 } do
		local rA = A.hw * math.abs(A.a1:Dot(ax)) + A.hd * math.abs(A.a2:Dot(ax))
		local rB = B.hw * math.abs(B.a1:Dot(ax)) + B.hd * math.abs(B.a2:Dot(ax))
		local pen = (rA + rB) - math.abs(d:Dot(ax))
		if pen <= 0 then return 0 end
		if pen < minPen then minPen = pen end
	end
	return minPen
end
local CELL = 64
local function cellsOf(box)
	local r = math.sqrt(box.hw * box.hw + box.hd * box.hd)
	local p = box.p
	local out = {}
	for cz = math.floor((p.Z - r) / CELL), math.floor((p.Z + r) / CELL) do
		for cx = math.floor((p.X - r) / CELL), math.floor((p.X + r) / CELL) do
			table.insert(out, cz * 65536 + cx)
		end
	end
	return out
end
local N = tonumber((...)) or 20000
local rng = Random and Random.new(7) or nil
local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
local placements = {}
for i = 1, N do
	-- dense city: lots on a 3000x3000 area so many touch/overlap
	local x, z = (rnd() - 0.5) * 6000, (rnd() - 0.5) * 6000
	local yaw = math.floor(rnd() * 4) * 90 + (if rnd() < 0.2 then rnd() * 30 else 0)
	placements[i] = { CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0), (2 + math.floor(rnd() * 4)) * 8, (2 + math.floor(rnd() * 4)) * 8 }
end
local TOL = 1
-- brute
local t0 = os.clock()
local brute, list = {}, {}
for i, pl in placements do
	local box = makeFootprint(pl[1], pl[2], pl[3], 1)
	local blocked = false
	for _, other in list do if boxPenetration(box, other) > TOL then blocked = true break end end
	brute[i] = blocked
	if not blocked then table.insert(list, box) end
end
local tBrute = os.clock() - t0
-- grid
t0 = os.clock()
local cells, grid, placed = {}, {}, 0
local mism = 0
for i, pl in placements do
	local box = makeFootprint(pl[1], pl[2], pl[3], 1)
	local blocked = false
	local seen = {}
	for _, k in cellsOf(box) do
		local c = cells[k]
		if c then
			for id, other in c do
				if not seen[id] then
					seen[id] = true
					if boxPenetration(box, other) > TOL then blocked = true break end
				end
			end
		end
		if blocked then break end
	end
	if blocked ~= brute[i] then mism += 1 end
	if not blocked then
		placed += 1
		local id = tostring(i)
		for _, k in cellsOf(box) do
			cells[k] = cells[k] or {}
			cells[k][id] = box
		end
	end
end
local tGrid = os.clock() - t0
print(string.format("N=%d placed=%d  brute %.2fs  grid %.3fs  mismatches %d", N, placed, tBrute, tGrid, mism))
