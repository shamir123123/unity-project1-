--!strict
-- Edit-time authoring tool (NOT runtime). Turns the 3D-Imported house kit v2 (Workspace.RH_W3..RH_W5,
-- one Model per lot width, from Models/kits/Buildings/HouseKit/, made by blender/res_house.py export)
-- into ServerStorage.Templates.Buildings.Residential.<WxD>[.Level2|.Level3].<Design>: the same design
-- name at every level, so BuildingService swaps a house to its own grown self (an add-on per level).
-- The v1 houses it replaces move (not deleted) to ServerStorage.ResidentialV1; an import is DESTROYED
-- after a clean pass. reshouse_manifest.json is passed in:
--   local json = game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/reshouse_manifest.json")
--   loadstring(game.ServerStorage.Authoring.HouseV2Setup.Source)().run(json [, w [, key]])
--
-- Parts (BUILDING_PIPELINE.md): Walls/Accent/Base/Trim/Roof/Deck/Doors/Garage carry the player's colour on
-- the importer's SurfaceAppearance; Detail_Rail is the alpha rail LOD1 drops (LODDetail); LOD_* are the
-- <500-tri LOD2 model, shipped invisible (LOD2) until AssetLODView shows them. Kit props ride as JSON
-- attributes (KitProps, KitRoof[3], KitSite[3]) and so does the lot's PAVING (KitPave, KitPaveSite[3]):
-- the kit bakes no ground -- LotDressingService.dressHouseKit drapes each rect as a LotMesh patch.

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local HouseV2Setup = {}

local TINT_KEY = table.freeze({
	Walls = "wallTint", Accent = "accentTint", Base = "baseTint", Trim = "trimTint", Roof = "roofTint",
	Deck = "deckTint", Doors = "doorTint", Garage = "garageTint", Detail_Rail = "trimTint",
	LOD_Walls = "wallTint", LOD_Base = "baseTint", LOD_Roof = "roofTint",
})
local AVG_KEY = table.freeze({ LOD_Walls = "wallAvg", LOD_Base = "baseAvg", LOD_Roof = "roofAvg" })
local PAINT_ROLE = table.freeze({
	Walls = "Wall", Accent = "Accent", Base = "Base", Trim = "Trim", Roof = "Roof", Doors = "Door", Garage = "Door",
	LOD_Walls = "Wall", LOD_Base = "Base", LOD_Roof = "Roof",
})
-- MeshPart.TextureID ignores the PNG alpha: these move onto a Transparency SurfaceAppearance.
local ALPHA = table.freeze({ Detail_Rail = true }) -- value: double-sided
local TOLERANCE = 0.05 -- studs a part may sit off the manifest before we refuse it

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = street, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> template (X, Y up, Z = street). The importer turns the kit 180 about Y (`turned`),
-- which leaves the street on +Z where BuildingService wants it; `plain` is an un-turned import.
local function turned(x: number, y: number, z: number): Vector3 return Vector3.new(-x, z, y) end
local function plain(x: number, y: number, z: number): Vector3 return Vector3.new(x, z, -y) end

local function box(p: any): Box
	return { p.min[1], p.min[2], p.min[3], p.max[1], p.max[2], p.max[3] }
end

local function centre(b: Box, map: Map): Vector3
	return map((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2)
end

-- The mesh's own axes are the same under either map: X = x, Y = z, Z = y. A flat piece keeps a sliver.
local function span(b: Box): Vector3
	return Vector3.new(math.max(b[4] - b[1], 0.002), math.max(b[6] - b[3], 0.002), math.max(b[5] - b[2], 0.002))
end

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

-- How this house's parts came in: import scale, and which map lines their centres up.
local function detect(label: string, parts: { [string]: MeshPart }, boxes: { [string]: Box }): Map
	local s, n = 0, 0
	for role, p in parts do
		assert(p.Orientation.Magnitude < 0.01, p:GetFullName() .. " arrived rotated")
		local sp = span(boxes[role]).Magnitude
		if sp > 1 and math.max(p.Size.X, p.Size.Y, p.Size.Z) < 2047 then
			s += p.Size.Magnitude / sp
			n += 1
		end
	end
	s /= n
	local best: Map, bestErr = turned, math.huge
	for _, map in { turned, plain } :: { Map } do
		local o0: Vector3? = nil
		local err = 0
		for role, p in parts do
			if math.max(p.Size.X, p.Size.Y, p.Size.Z) >= 2047 then continue end -- clamped by the importer
			local o = p.Position - centre(boxes[role], map) * s
			o0 = o0 or o
			err = math.max(err, (o - (o0 :: Vector3)).Magnitude / s)
		end
		if err < bestErr then best, bestErr = map, err end
	end
	assert(bestErr < TOLERANCE, ("%s: parts do not line up with the manifest (%.3f studs)"):format(label, bestErr))
	return best
end

local function invisiblePart(name: string, size: Vector3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function alphaSkin(p: MeshPart, doubleSided: boolean)
	local sa = p:FindFirstChildOfClass("SurfaceAppearance")
	if not sa then
		sa = Instance.new("SurfaceAppearance")
		sa.Name = "Skin"
		sa.ColorMap = p.TextureID
		sa.Parent = p
	end
	(sa :: SurfaceAppearance).AlphaMode = Enum.AlphaMode.Transparency
	p.TextureID = ""
	p.DoubleSided = doubleSided
end

local function dressPart(p: MeshPart, role: string, look: any)
	if ALPHA[role] ~= nil then alphaSkin(p, ALPHA[role]) end
	local sa = p:FindFirstChildOfClass("SurfaceAppearance")
	if TINT_KEY[role] and not AVG_KEY[role] then
		assert(sa, p:GetFullName() .. " has no SurfaceAppearance from the importer")
		sa.Color = rgb(look[TINT_KEY[role]])
	end
	if AVG_KEY[role] then -- untextured LOD2 shell: the player's colour x the texture's average tone
		local t, a = look[TINT_KEY[role]], look[AVG_KEY[role]]
		p.Color = Color3.fromRGB(t[1] * a[1] / 255, t[2] * a[2] / 255, t[3] * a[3] / 255)
	else
		p.Color = Color3.new(1, 1, 1) -- the import arrives grey, and Color multiplies
	end
	if PAINT_ROLE[role] then p:SetAttribute("PaintRole", PAINT_ROLE[role]) end
	if role:sub(1, 7) == "Detail_" then p:SetAttribute("LODDetail", true) end
	if role:sub(1, 4) == "LOD_" then
		p:SetAttribute("LOD2", true)
		p.Transparency = 1 -- until AssetLODView swaps it in
	end
	p.CastShadow = not (role:sub(1, 4) == "LOD_" or ALPHA[role] ~= nil)
end

-- Kit-prop placements in template studs, yaw in degrees: { {prop, x, y, z, yaw [, tilt]}, ... }. The prop
-- FBXs get the same importer turn, so a Blender yaw carries over unchanged; a roof prop lying on a slope
-- keeps its tilt (seatKit turns it about the prop's own X after the yaw).
local function props(list: any): { any }
	local out = {}
	for _, e in list do
		local v = turned(e.pos[1], e.pos[2], e.pos[3])
		local row = { e.prop, v.X, v.Y, v.Z, e.rot % 360 }
		if e.tilt and e.tilt ~= 0 then row[6] = e.tilt end
		table.insert(out, row)
	end
	return out
end

local function layouts(ls: any): string
	local out = {}
	for i, l in ls do out[i] = props(l) end
	return HttpService:JSONEncode(out)
end

-- Paving rects in the template frame: { {x0, x1, zBack, zFront, street, lift, kind}, ... } -- x turned
-- (Blender x0..x1 becomes -x1..-x0), z = Blender y (+Z to the road).
local function paving(list: any): { any }
	local out = {}
	for _, e in list or {} do
		local r = e.rect
		table.insert(out, { -r[2], -r[1], r[3], r[4], e.street == true, e.lift or 0, e.kind })
	end
	return out
end

local function buildTemplate(name: string, design: any, lv: string, parts: { [string]: MeshPart }, map: Map): Model
	local lvInfo = design.levels[lv]
	local model = Instance.new("Model")
	model.Name = name
	local rot = if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge

	for role, src in parts do
		local b = box(lvInfo.parts[role])
		local p = src:Clone()
		p.Name = role
		for _, c in p:GetChildren() do
			if not c:IsA("SurfaceAppearance") then c:Destroy() end
		end
		p.Size = span(b)
		p.CFrame = CFrame.new(centre(b, turned)) * rot
		p.Transparency = 0
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		dressPart(p, role, design.look)
		p.Parent = model
		if role == "Walls" or role == "Base" or role == "Roof" then
			lo = lo:Min(p.Position - p.Size / 2)
			hi = hi:Max(p.Position + p.Size / 2)
		end
	end

	local lotW, lotD = design.lotStuds[1], design.lotStuds[2]
	-- Lot-sized marker so the model's bounding box IS the lot (BuildingService centres on it),
	-- and the frame LotDressingService seats the kit props and lays the paving in.
	invisiblePart("FootprintAnchor", Vector3.new(lotW, 0.2, lotD), CFrame.new(0, 0.1, 0), model)
	-- One box over the house is what selection hits; the door / garage / lot-entry markers ride on it.
	local body = invisiblePart("Body", hi - lo, CFrame.new((lo + hi) / 2), model)
	model.PrimaryPart = body
	for markName, mk in lvInfo.marks do
		local att = Instance.new("Attachment")
		att.Name = markName
		local at = turned(mk.pos[1], mk.pos[2], mk.pos[3])
		local cf = if mk.dir then CFrame.lookAt(at, at + turned(mk.dir[1], mk.dir[2], mk.dir[3])) else CFrame.new(at)
		att.CFrame = body.CFrame:ToObjectSpace(cf)
		att.Parent = body
		if mk.width then att:SetAttribute("Width", mk.width) end
	end

	for k, v in lvInfo.attrs do model:SetAttribute(k, v) end
	model:SetAttribute("KitYard", true)
	model:SetAttribute("LODTiers", true) -- AssetLODView: LOD1 drops Detail_ + small props, LOD2 shows LOD_ only
	model:SetAttribute("StudsPerMetre", 2)
	model:SetAttribute("Level", tonumber(lv))
	model:SetAttribute("LotW", design.w)
	model:SetAttribute("LotD", design.d)
	model:SetAttribute("HasParking", true) -- every v2 lot has a drive (garage, carport or pad)
	local fixed = {}
	for _, e in lvInfo.entry do table.insert(fixed, e) end
	for _, e in lvInfo.siteFixed do table.insert(fixed, e) end
	model:SetAttribute("KitProps", HttpService:JSONEncode(props(fixed)))
	model:SetAttribute("KitRoof", layouts(lvInfo.roof)) -- BuildingService keeps one: PlantLayout
	model:SetAttribute("KitSite", layouts(lvInfo.site))
	model:SetAttribute("KitPave", HttpService:JSONEncode(paving(lvInfo.pave)))
	local site = {}
	for i, l in lvInfo.paveSite or {} do site[i] = paving(l) end
	model:SetAttribute("KitPaveSite", HttpService:JSONEncode(site)) -- goes with KitSite[i]
	return model
end

local function folderAt(parent: Instance, name: string): Instance
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f :: Instance
end

-- The v1 houses move aside (not deleted) the first time a size gets new templates.
local function retireOld(sizeFolder: Instance, sizeName: string)
	local old = folderAt(ServerStorage, "ResidentialV1")
	for _, c in sizeFolder:GetDescendants() do
		if c:IsA("Model") and not c.Name:match("^RH_") and c.Parent and c.Parent:IsA("Folder") then
			local dest = folderAt(folderAt(old, sizeName), c.Parent.Name == sizeName and "Level1" or c.Parent.Name)
			c.Parent = dest
		end
	end
end

function HouseV2Setup.run(manifestJson: string, onlyW: number?, onlyKey: string?): string
	local manifest = HttpService:JSONDecode(manifestJson)
	local root = folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Buildings"), "Residential")
	local report: { string } = {}

	for w = 3, 5 do
		if onlyW and w ~= onlyW then continue end
		local import = Workspace:FindFirstChild("RH_W" .. w)
		if not import then
			table.insert(report, ("RH_W%d: not imported"):format(w))
			continue
		end
		-- design -> level -> part name -> part
		local found: { [string]: { [string]: { [string]: MeshPart } } } = {}
		for _, p in import:GetDescendants() do
			local design, lv, role = p.Name:match("^(RH_%d+x%d+_%w+)_L(%d)_([%w_]+)$")
			if design and p:IsA("MeshPart") then
				found[design] = found[design] or {}
				found[design][lv] = found[design][lv] or {}
				found[design][lv][role] = p
			end
		end

		local clean, made, total = true, 0, 0
		for name, design in manifest do
			if name:sub(1, 1) == "_" or design.w ~= w then continue end
			total += 3
			if onlyKey and design.key ~= onlyKey then continue end
			local sizeName = ("%dx%d"):format(design.w, design.d)
			local sizeFolder = folderAt(root, sizeName)
			retireOld(sizeFolder, sizeName)
			for lv, info in design.levels do
				local parts = found[name] and found[name][lv]
				local missing = {}
				for role in info.parts do
					if not (parts and parts[role]) then table.insert(missing, role) end
				end
				if #missing > 0 then
					clean = false
					table.insert(report, ("%s L%s missing %s"):format(name, lv, table.concat(missing, ",")))
					continue
				end
				local boxes = {}
				for role, p in info.parts do boxes[role] = box(p) end
				local map = detect(name .. " L" .. lv, parts :: any, boxes)
				local dest = if lv == "1" then sizeFolder else folderAt(sizeFolder, "Level" .. lv)
				local old = dest:FindFirstChild(name)
				if old then old:Destroy() end
				buildTemplate(name, design, lv, parts :: any, map).Parent = dest
				made += 1
			end
		end
		-- The import goes once every design of the width has its templates (a key-by-key run keeps it).
		local have = 0
		for name, design in manifest do
			if name:sub(1, 1) == "_" or design.w ~= w then continue end
			local sizeFolder = root:FindFirstChild(("%dx%d"):format(design.w, design.d))
			for lv in design.levels do
				local dest = sizeFolder and (if lv == "1" then sizeFolder else sizeFolder:FindFirstChild("Level" .. lv))
				if dest and dest:FindFirstChild(name) then have += 1 end
			end
		end
		if clean and have == total then
			import:Destroy()
			table.insert(report, ("RH_W%d: %d templates made, all %d in, import removed"):format(w, made, total))
		else
			table.insert(report, ("RH_W%d: %d templates made, %d/%d in, import KEPT"):format(w, made, have, total))
		end
	end
	return table.concat(report, "\n")
end

return HouseV2Setup
