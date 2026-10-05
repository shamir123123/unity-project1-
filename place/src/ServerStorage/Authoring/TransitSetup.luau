--!strict
-- Edit-time authoring tool (NOT runtime). Turns the 3D-Imported transit kit (Workspace.TR_<Key>, one
-- Model per site / stop, made by blender/transit.py export) into ServerStorage.Templates.Transit.<Key>:
-- the three bus depots, the hub, the station and the two kerbside stops. transit_manifest.json is
-- passed in:
--   local json = game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/transit_manifest.json")
--   <TransitSetup>.run(json [, onlyKey])
-- Run through a loadstring shim (SurfaceAppearance maps need Plugin capability).
--
-- A template is the building as placed: its pivot is the lot centre on the ground, the street on +Z
-- (BusDepot convention), world studs (StudsPerMetre = 2). Parts are sized from the manifest boxes, the
-- tinted roles get their colour maps back (the importer drops them behind Blender's tint node), kit props
-- are baked in (Props folder), and the plan -- gates, bays with their swept-path-checked drives in and
-- out, marks, stalls -- rides as JSON in a StringValue `TransitPlan`, already in the template frame.

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local TransitSetup = {}

-- Colour / normal / roughness of the tintable looks: combuild_pbr ids (CommercialLowSetup.PBR), plus
-- wall_trap (IndustrialSetup) and c2_metal (uploaded 2026-09-30). A missing normal keeps the importer's.
local PBR: { [string]: { string } } = table.freeze({
	wall_panel = { "rbxassetid://139289033576384", "rbxassetid://139750313932064", "rbxassetid://131377655544477" },
	wall_brick = { "rbxassetid://72150076658108", "rbxassetid://117426192866440", "rbxassetid://113582052910022" },
	wall_stone = { "rbxassetid://77903263304386", "rbxassetid://111891370213520", "rbxassetid://119754477363084" },
	wall_board = { "rbxassetid://89221031962562", "rbxassetid://123063505699775", "rbxassetid://125801632864690" },
	trim = { "rbxassetid://79524206353874", "rbxassetid://108362861905834", "rbxassetid://100480888530278" },
	trim_smooth = { "rbxassetid://134028487242206", "rbxassetid://137134616010950", "rbxassetid://72662390339338" },
	roof_membrane = { "rbxassetid://109808355491341", "rbxassetid://115728070212757", "rbxassetid://79791541565452" },
	wall_trap = { "rbxassetid://81441889690104" },
	c2_metal = { "rbxassetid://85442431904927" },
} :: any)
local PAINT_ROLE = table.freeze({ Walls = "Wall", Clad = "Wall", Brick = "Wall", Stone = "Wall", Base = "Base",
	Accent = "Accent", Trim = "Trim", Roof = "Roof", Metal = "Roof" })
local FLAT = table.freeze({ Ground = true, Pave = true, Pavers = true })
local TOLERANCE = 0.05 -- studs a part may sit off the manifest before we refuse it
local PROP_ROOTS = { "Templates.Asset.Props", "Nature" }

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = street, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> template (X, Y up, Z = street). The importer turns a kit 180 about Y (`turned`), which
-- leaves the street on +Z; `plain` is an un-turned import.
local function turned(x: number, y: number, z: number): Vector3 return Vector3.new(-x, z, y) end
local function plain(x: number, y: number, z: number): Vector3 return Vector3.new(x, z, -y) end

local function box(p: any): Box
	return { p.min[1], p.min[2], p.min[3], p.max[1], p.max[2], p.max[3] }
end

local function centre(b: Box, map: Map): Vector3
	return map((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2)
end

-- The mesh's own axes are the same under either map: X = x, Y = z, Z = y. A flat decal keeps a sliver.
local function span(b: Box): Vector3
	return Vector3.new(math.max(b[4] - b[1], 0.002), math.max(b[6] - b[3], 0.002), math.max(b[5] - b[2], 0.002))
end

-- How this import's parts came in: import scale, and which map lines their centres up.
local function detect(label: string, parts: { [string]: MeshPart }, boxes: { [string]: Box }): Map
	local s, n = 0, 0
	for name, p in parts do
		assert(p.Orientation.Magnitude < 0.01, p:GetFullName() .. " arrived rotated")
		local sp = span(boxes[name]).Magnitude
		if sp > 1 and math.max(p.Size.X, p.Size.Y, p.Size.Z) < 2047 then
			s += p.Size.Magnitude / sp
			n += 1
		end
	end
	s /= n
	-- Majority vote: an import can arrive with a stray part or two shifted (the parts are placed from
	-- the manifest anyway), so the map most parts agree on wins, measured from the Ground part.
	local ref = parts[label .. "_Ground"] and (label .. "_Ground") or next(parts)
	local best: Map, bestVotes, total = turned, -1, 0
	for _, map in { turned, plain } :: { Map } do
		local o0 = parts[ref].Position - centre(boxes[ref], map) * s
		local votes = 0
		total = 0
		for name, p in parts do
			if math.max(p.Size.X, p.Size.Y, p.Size.Z) >= 2047 then continue end -- clamped by the importer
			total += 1
			if ((p.Position - centre(boxes[name], map) * s) - o0).Magnitude / s < TOLERANCE then votes += 1 end
		end
		if votes > bestVotes then best, bestVotes = map, votes end
	end
	assert(bestVotes * 2 > total, ("%s: parts do not line up with the manifest (%d of %d agree)"):format(label, bestVotes, total))
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

local function skin(p: MeshPart): SurfaceAppearance
	local sa = p:FindFirstChildOfClass("SurfaceAppearance")
	if not sa then
		sa = Instance.new("SurfaceAppearance")
		;(sa :: SurfaceAppearance).Name = "Skin"
		;(sa :: SurfaceAppearance).ColorMap = p.TextureID
		sa.Parent = p
	end
	return sa :: SurfaceAppearance
end

local function dressPart(p: MeshPart, info: any, roles: any)
	local role: string = info.role
	local look = roles[role]
	local stem = look and look.texture and string.match(look.texture, "[^/]+$")
	if info.lod then
		-- untextured LOD2 shell, invisible until a LOD view swaps it in
		p.Color = Color3.fromRGB(info.colour[1], info.colour[2], info.colour[3])
		p:SetAttribute("LOD2", true)
		if info.transparency then p:SetAttribute("LODTransparency", info.transparency) end
		p.Transparency = 1
	elseif info.tint then
		local sa = skin(p)
		local maps = stem and PBR[stem]
		assert(maps, p:GetFullName() .. ": no colour map for " .. tostring(stem))
		sa.ColorMap = maps[1]
		if maps[2] then sa.NormalMap = maps[2] end
		if maps[3] then sa.RoughnessMap = maps[3] end
		sa.Color = Color3.fromRGB(info.tint[1], info.tint[2], info.tint[3])
		p.Color = Color3.new(1, 1, 1)
	elseif look and look.alpha then
		-- MeshPart.TextureID ignores the PNG alpha: it moves onto a Transparency SurfaceAppearance
		skin(p).AlphaMode = Enum.AlphaMode.Transparency
		p.TextureID = ""
		p.DoubleSided = look.doubleSided == true
		p.Color = Color3.new(1, 1, 1)
	else
		p.Color = Color3.new(1, 1, 1) -- the import arrives grey, and Color multiplies
	end
	if PAINT_ROLE[role] then p:SetAttribute("PaintRole", PAINT_ROLE[role]) end
	if info.detail then p:SetAttribute("LODDetail", true) end
	if info.layout then p:SetAttribute("Layout", info.layout + 1) end
	if FLAT[role] then p:SetAttribute("LODKeep", true) end -- the ground stays under the LOD2 shells
	p.CastShadow = not (FLAT[role] or info.lod or (look and look.alpha))
end

local _props: { [string]: Model } = {}
local function propModel(name: string): Model?
	if _props[name] then return _props[name] end
	for _, path in PROP_ROOTS do
		local root: Instance? = if path == "Nature" then ReplicatedStorage:FindFirstChild("Nature") else ServerStorage
		if root and path ~= "Nature" then
			for _, seg in string.split(path, ".") do root = root and root:FindFirstChild(seg) end
		end
		local m = root and root:FindFirstChild(name, true)
		if m and m:IsA("Model") then
			_props[name] = m
			return m
		end
	end
	return nil
end

-- Kit props baked in, seated like LotDressingService.seatKit: the importer gave the prop FBXs the same
-- turn, so a Blender yaw carries over unchanged.
local function bakeProps(items: any, model: Model, missing: { [string]: boolean })
	local folder = Instance.new("Folder")
	folder.Name = "Yard" -- AssetLODView drops a Yard's small props at LOD1 and all of them at LOD2
	folder.Parent = model
	for _, it in items do
		local src = propModel(it.prop)
		if not src then
			missing[it.prop] = true
			continue
		end
		local c = src:Clone()
		c:PivotTo(CFrame.new(turned(it.pos[1], it.pos[2], it.pos[3])) * CFrame.Angles(0, math.rad(it.rot), 0))
		for _, d in c:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		c.Parent = folder
	end
end

-- The plan in the template frame: points are { X, Z } studs, yaw stays Blender degrees (0 = nose to the
-- street); the runtime heading is CFrame.Angles(0, rad(yaw) + pi, 0) (vehicles face -Z).
local function xz(p: { number }): { number }
	return { -p[1], p[2] }
end

local function path(pts: any): { { number } }
	local out = {}
	for i, p in pts do out[i] = xz(p) end
	return out
end

local function planJson(m: any): string
	local gates = {}
	for name, g in m.gates or {} do gates[name] = { math.min(-g[1], -g[2]), math.max(-g[1], -g[2]) } end
	local marks = {}
	for name, mk in m.marks or {} do marks[name] = { -mk[1], mk[2], mk[3] } end
	local layouts = {}
	for i, L in m.layouts or {} do
		local bays = {}
		for j, b in L.bays do
			bays[j] = { id = b.id, kind = b.kind, inside = b.inside, yaw = b.yaw, pos = xz(b.pos),
				pathIn = path(b.pathIn), pathOut = path(b.pathOut), stop = b.stop }
		end
		layouts[i] = { name = L.name, label = L.label, artic = L.artic, bays = bays }
	end
	local stalls = {}
	for i, s in m.stalls or {} do stalls[i] = { -s[1], s[2], s[3] } end
	local fleet = {}
	for i, f in m.fleet or {} do fleet[i] = { vehicle = f.vehicle, pos = xz(f.pos), yaw = f.yaw } end
	return HttpService:JSONEncode({
		key = m.key, name = m.name, lots = m.lots, size = m.size, default = (m.default or 0) + 1,
		gates = gates, marks = marks, layouts = layouts, stalls = stalls, fleet = fleet,
	})
end

local function buildTemplate(key: string, m: any, roles: any, parts: { [string]: MeshPart }, map: Map, missing: { [string]: boolean }): Model
	local model = Instance.new("Model")
	model.Name = key
	local rot = if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for name, src in parts do
		local info = m.parts[name]
		local b = box(info)
		local p = src:Clone()
		p.Name = string.sub(name, #key + 2)
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
		dressPart(p, info, roles)
		p.Parent = model
		if not info.lod then
			lo = lo:Min(p.Position - p.Size / 2)
			hi = hi:Max(p.Position + p.Size / 2)
		end
	end

	local size: Vector3
	if m.size then
		size = Vector3.new(m.size[1], 0.2, m.size[2])
	else -- a kerbside stop: its own footprint
		size = Vector3.new(hi.X - lo.X, 0.2, hi.Z - lo.Z)
	end
	-- The lot marker: PrimaryPart, pivot on the ground at the lot centre (a stop: at its own origin).
	local anchor = invisiblePart("FootprintAnchor", size, CFrame.new(if m.size then 0 else (lo.X + hi.X) / 2, 0.1,
		if m.size then 0 else (lo.Z + hi.Z) / 2), model)
	model.PrimaryPart = anchor
	anchor.PivotOffset = anchor.CFrame:Inverse()
	-- What selection hits (clicks on a stop / depot): one box over everything built.
	local hit = invisiblePart("Hitbox", hi - lo, CFrame.new((lo + hi) / 2), model)
	hit.CanQuery = true

	bakeProps(m.items or {}, model, missing)
	if m.layouts then
		local plan = Instance.new("StringValue")
		plan.Name = "TransitPlan"
		plan.Value = planJson(m)
		plan.Parent = model
	end
	model:SetAttribute("TransitKey", key)
	model:SetAttribute("StudsPerMetre", 2)
	model:SetAttribute("LODTiers", true)
	if m.lots then
		model:SetAttribute("LotW", m.lots[1])
		model:SetAttribute("LotD", m.lots[2])
		model:SetAttribute("Layouts", #m.layouts)
		model:SetAttribute("DefaultLayout", (m.default or 0) + 1)
	end
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

-- The placement ghosts the client draws (it cannot see ServerStorage): ReplicatedStorage.Transit.Ghosts.<Key>
-- = the plot slab + the LOD2 shells + an IN / OUT arrow at each gate (TransitTypes.gates); a stop
-- ghost is the stop itself. Pivot on the ground at the lot centre, like the template.
function TransitSetup.ghosts(): string
	local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes) :: any
	local folder = folderAt(ReplicatedStorage.Transit, "Ghosts")
	local made = {}
	for _, t in (ServerStorage :: any).Templates.Transit:GetChildren() do
		local old = folder:FindFirstChild(t.Name)
		if old then old:Destroy() end
		local g = Instance.new("Model")
		g.Name = t.Name
		local spec = TransitTypes.getFreePlaced(t.Name)
		if spec and spec.footprint then
			local fp = spec.footprint :: Vector3
			local slab = invisiblePart("Slab", Vector3.new(fp.X, 0.4, fp.Z), CFrame.new(0, 0.2, 0), g)
			slab.Transparency = 0.55
			slab.PivotOffset = CFrame.new(0, -0.2, 0)
			g.PrimaryPart = slab
			for _, p in t:GetChildren() do
				if p:IsA("BasePart") and p:GetAttribute("LOD2") then
					local c = p:Clone()
					for _, a in c:GetAttributes() do c:SetAttribute(a, nil) end
					c.Transparency = 0.35
					c.Parent = g
				end
			end
			for i, x in spec.gates or {} do
				-- an arrow on the street edge (shaft + two barbs): IN points into the plot, OUT at the road
				local tip = Vector3.new(x, 0.5, fp.Z * 0.5 + (if i == 1 then -3 else 11))
				local back = if i == 1 then 1 else -1 -- +Z = away from the tip for IN
				local function bar(name: string, a: Vector3, b: Vector3)
					local p = Instance.new("Part")
					p.Name = name
					p.Size = Vector3.new(2.2, 0.6, (b - a).Magnitude + 2.2)
					p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
					p.Transparency = 0.1
					p.Parent = g
				end
				local gate = if i == 1 then "GateIn" else "GateOut"
				bar(gate, tip, tip + Vector3.new(0, 0, back * 14))
				bar(gate, tip, tip + Vector3.new(-5, 0, back * 5))
				bar(gate, tip, tip + Vector3.new(5, 0, back * 5))
			end
		else
			for _, p in t:GetChildren() do
				if p.Name ~= "Hitbox" and p.Name ~= "TransitPlan" then p:Clone().Parent = g end
			end
			g.PrimaryPart = g:FindFirstChild("FootprintAnchor") :: BasePart
			for _, d in g:GetDescendants() do
				if d:IsA("BasePart") and d.Name ~= "FootprintAnchor" then d.Transparency = 0.3 end
			end
		end
		for _, d in g:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
			end
		end
		g.Parent = folder
		table.insert(made, t.Name)
	end
	return "ghosts: " .. table.concat(made, ", ")
end

-- The drives LotDressingService paves from a site's gates to the road (tag PavedGates) wear the
-- site's own asphalt (user): MaterialService.LotGround.TransitDrive, made from the kit Ground's maps
-- at the texture's real size (ground_asphalt tiles every 2.5 m = 5 studs, world-projected like the
-- road), named on every site template as DriveMaterial / DriveVariant.
local DRIVE_VARIANT = "TransitDrive"
local DRIVE_STUDS_PER_TILE = 5
function TransitSetup.driveLook(): string
	local root = (ServerStorage :: any).Templates.Transit
	local ground: MeshPart? = nil
	for _, t in root:GetChildren() do
		local g = t:FindFirstChild("Ground")
		if g and g:IsA("MeshPart") and g:FindFirstChildOfClass("SurfaceAppearance") then ground = g; break end
	end
	assert(ground, "no transit template with a Ground SurfaceAppearance")
	local sa = (ground :: MeshPart):FindFirstChildOfClass("SurfaceAppearance") :: SurfaceAppearance
	local folder = folderAt(game:GetService("MaterialService"), "LotGround")
	local v = folder:FindFirstChild(DRIVE_VARIANT) :: MaterialVariant?
	if not v then
		v = Instance.new("MaterialVariant")
		;(v :: MaterialVariant).Name = DRIVE_VARIANT
	end
	local mv = v :: MaterialVariant
	mv.BaseMaterial = Enum.Material.Asphalt
	mv.ColorMap = sa.ColorMap
	mv.NormalMap = sa.NormalMap
	mv.RoughnessMap = sa.RoughnessMap
	mv.StudsPerTile = DRIVE_STUDS_PER_TILE
	mv.Parent = folder
	local n = 0
	for _, t in root:GetChildren() do
		if t:FindFirstChild("TransitPlan") then
			t:SetAttribute("DriveMaterial", "Asphalt")
			t:SetAttribute("DriveVariant", DRIVE_VARIANT)
			n += 1
		end
	end
	return ("drive look %s (%s) on %d site templates"):format(DRIVE_VARIANT, sa.ColorMap, n)
end

-- A site's Walk gate path wears that site's own Pavers (user, 2026-10-04: a walking entrance is not
-- road): MaterialService.LotGround.TransitWalk_<Key> from its Pavers maps at their real size
-- (c2_pavers tiles every 1.2 m = 2.4 studs), named on the template as WalkMaterial / WalkVariant.
local WALK_STUDS_PER_TILE = 2.4
function TransitSetup.walkLook(): string
	local folder = folderAt(game:GetService("MaterialService"), "LotGround")
	local made = {}
	for _, t in (ServerStorage :: any).Templates.Transit:GetChildren() do
		local pavers = t:FindFirstChild("Pavers")
		local sa = pavers and pavers:FindFirstChildOfClass("SurfaceAppearance")
		if not (t:FindFirstChild("TransitPlan") and sa) then continue end
		local name = "TransitWalk_" .. t.Name
		local mv = (folder:FindFirstChild(name) or Instance.new("MaterialVariant")) :: MaterialVariant
		mv.Name = name
		mv.BaseMaterial = Enum.Material.Pavement
		mv.ColorMap = sa.ColorMap
		mv.NormalMap = sa.NormalMap
		mv.RoughnessMap = sa.RoughnessMap
		mv.StudsPerTile = WALK_STUDS_PER_TILE
		mv.Parent = folder
		t:SetAttribute("WalkMaterial", "Pavement")
		t:SetAttribute("WalkVariant", name)
		table.insert(made, name)
	end
	return "walk looks: " .. table.concat(made, ", ")
end

function TransitSetup.run(manifestJson: string, onlyKey: string?): string
	local manifest = HttpService:JSONDecode(manifestJson)
	local root = folderAt(folderAt(ServerStorage, "Templates"), "Transit")
	local report: { string } = {}
	for key, m in manifest do
		if string.sub(key, 1, 1) == "_" or (onlyKey and key ~= onlyKey) then continue end
		local import = Workspace:FindFirstChild("TR_" .. key)
		if not import then
			table.insert(report, key .. ": not imported")
			continue
		end
		local parts: { [string]: MeshPart } = {}
		for _, p in import:GetDescendants() do
			if p:IsA("MeshPart") and m.parts[p.Name] then parts[p.Name] = p end
		end
		local miss = {}
		for name in m.parts do
			if not parts[name] then table.insert(miss, name) end
		end
		if #miss > 0 then
			table.insert(report, key .. ": missing " .. table.concat(miss, ",") .. " -- import KEPT")
			continue
		end
		local boxes = {}
		for name, info in m.parts do boxes[name] = box(info) end
		local map = detect(key, parts, boxes)
		local missing: { [string]: boolean } = {}
		local old = root:FindFirstChild(key)
		if old then old:Destroy() end
		local t = buildTemplate(key, m, manifest._roles, parts, map, missing)
		t.Parent = root
		local mp = {}
		for n in missing do table.insert(mp, n) end
		import:Destroy()
		table.insert(report, ("%s: template made (%d parts, %d props)%s, import removed"):format(key, #t:GetChildren() - 3,
			#(t :: any).Yard:GetChildren(), if #mp > 0 then ", MISSING PROPS " .. table.concat(mp, ",") else ""))
	end
	return table.concat(report, "\n")
end

return TransitSetup
