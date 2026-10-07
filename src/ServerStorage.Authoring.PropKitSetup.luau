--!strict
-- Edit-time authoring tool (NOT runtime). Files the 3D-Imported prop kits -- a whole-kit bundle
-- (Workspace.<Kit>_ALL, from Models/kits/_bundles, made by blender/kit_catalog.py) or the kit folder's
-- single FBXs (Workspace.<Asset>, from Models/kits/Props/<Kit>) -- into
-- ServerStorage.Templates.Asset.Props.<Kit>.<Asset> -- every prop once, in the kit named for what it is
-- (KIT_OVERHAUL.md). A new kit or asset needs nothing here: the manifest lists them.
--
--   local get = function(f) return game:GetService("HttpService"):GetAsync("http://127.0.0.1:<port>/" .. f) end
--   local PropKitSetup = require(game.ServerStorage.Authoring.PropKitSetup)
--   PropKitSetup.run(get("kits_manifest.json"), get("kits_textures.json") [, kit])
--   PropKitSetup.retire() -- once every kit is in: the old zone prop folders and the part-built
--                            ReplicatedStorage.Props catalogue -> ServerStorage.PropsRetired
--
-- The FBXs carry no textures. Every part gets a SurfaceAppearance from the manifest's maps (uploaded
-- once, shared by every kit: kits_textures.json maps file -> asset id), its tint on
-- SurfaceAppearance.Color (attribute Paint; a prop with a palette carries Tints and LotDressingService
-- picks one per placement), see-through parts in Transparency mode. Parts are re-seated from their
-- manifest boxes, so the import scale and turn drop out: true size (2 studs per metre), pivot = the
-- Blender origin on the ground with an identity frame (how LotDressingService seats kit props).
-- Needs Plugin capability (SurfaceAppearance maps can't be written from a game thread).

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local PropKitSetup = {}

local TOLERANCE = 0.05 -- studs a part may sit off the manifest before the import is refused
local SHADOW_STUDS = 3 -- a prop part this tall casts a shadow
-- The zone prop folders the category kits replace (moved, not deleted).
local RETIRED = { "Residential", "Commercial", "Industrial", "MidRise", "BuildingProps", "Utilities" }

type Box = { number } -- minX, minY, minZ, maxX, maxY, maxZ in Blender axes (y = back to front, z = up)
type Map = (x: number, y: number, z: number) -> Vector3

-- Blender -> Roblox. The importer turns an FBX 180 about Y (`turned`); `plain` is an un-turned import.
local function turned(x: number, y: number, z: number): Vector3 return Vector3.new(-x, z, y) end
local function plain(x: number, y: number, z: number): Vector3 return Vector3.new(x, z, -y) end

local function box(p: any): Box
	return { p.min[1], p.min[2], p.min[3], p.max[1], p.max[2], p.max[3] }
end

local function centre(b: Box, map: Map): Vector3
	return map((b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2)
end

-- The mesh's own axes are the same under either map: X = x, Y = z, Z = y. A flat card keeps a sliver.
local function span(b: Box): Vector3
	return Vector3.new(math.max(b[4] - b[1], 0.002), math.max(b[6] - b[3], 0.002), math.max(b[5] - b[2], 0.002))
end

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

-- Which map lines the imported parts' centres up with the manifest boxes (the import scale drops out).
-- Parts the importer clamped to its 2048-stud cap are left out of the fit. Returns the map and its
-- worst misfit in studs (a lone part fits either way: the importer's usual turn wins).
local MAX_IMPORT = 2047
local function detect(parts: { [string]: MeshPart }, boxes: { [string]: Box }): (Map, number)
	local fit: { [string]: MeshPart } = {}
	local s, n = 0, 0
	for key, p in parts do
		local sp = span(boxes[key]).Magnitude
		if p.Orientation.Magnitude < 0.01 and math.max(p.Size.X, p.Size.Y, p.Size.Z) < MAX_IMPORT and sp > 0.5 then
			fit[key] = p
			s += p.Size.Magnitude / sp
			n += 1
		end
	end
	if n < 2 then return turned, 0 end
	s /= n
	local best: Map, bestErr = turned, math.huge
	for _, map in { turned, plain } :: { Map } do
		local o0: Vector3? = nil
		local err = 0
		for key, p in fit do
			local o = p.Position - centre(boxes[key], map) * s
			o0 = o0 or o
			err = math.max(err, (o - (o0 :: Vector3)).Magnitude / s)
		end
		if err < bestErr then best, bestErr = map, err end
	end
	return best, bestErr
end

-- An imported part's name under its asset, the way kit_catalog.py names bundle parts: an FBX filed as
-- Fence_ChainLink_Com holding Fence_ChainLink_Mesh -> Fence_ChainLink_Com_Mesh.
local function partName(name: string, base: string): string
	base = base:gsub("%.%d+$", "")
	if base:sub(1, #name) == name then return base end
	if name:sub(1, #base) == base then return name end
	local n = 0
	for i = 1, math.min(#name, #base) do
		local ch = name:sub(i, i)
		if ch ~= base:sub(i, i) then break end
		if ch == "_" then n = i end
	end
	return name .. "_" .. base:sub(n + 1)
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

local function propsRoot(): Instance
	return folderAt(folderAt(folderAt(ServerStorage, "Templates"), "Asset"), "Props")
end

local function skin(p: MeshPart, b: any, tex: { [string]: string })
	p.TextureID = ""
	if not b.color then
		p.Color = rgb(b.rgb or { 160, 164, 170 })
		return
	end
	local function id(file: string?): string
		if not file then return "" end
		assert(tex[file], "no uploaded id for " .. file)
		return tex[file]
	end
	local sa = Instance.new("SurfaceAppearance")
	sa.Name = "Skin"
	sa.ColorMap = id(b.color)
	sa.NormalMap = id(b.normal)
	sa.RoughnessMap = id(b.rough)
	sa.MetalnessMap = id(b.metal)
	if b.tint then
		sa.Color = rgb(b.tint)
		p:SetAttribute("Paint", true)
	end
	if b.alpha then sa.AlphaMode = Enum.AlphaMode.Transparency end
	sa.Parent = p
	p.Color = Color3.new(1, 1, 1) -- Color multiplies the map
end

-- Industry smokes (user 2026-10-07: "give industrial buildings more smog"): a denser, darker, longer plume
-- than the chimney-pot wisp it was (rate 2, 2 -> 9 studs, 5-8 s).
local function smoke(att: Attachment)
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "Smoke"
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color = ColorSequence.new(Color3.fromRGB(176, 174, 170), Color3.fromRGB(118, 116, 114))
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 15) })
	pe.Lifetime = NumberRange.new(7, 11)
	pe.Rate = 4.5
	pe.Speed = NumberRange.new(2, 3)
	pe.SpreadAngle = Vector2.new(8, 8)
	pe.Acceleration = Vector3.new(0.6, 0.4, 0)
	pe.LightInfluence = 1
	pe.Parent = att
end

local function buildAsset(kit: string, name: string, info: any, found: { [string]: MeshPart }, rot: CFrame,
	tex: { [string]: string }): (Model?, string?)
	local model = Instance.new("Model")
	model.Name = name
	local o = info.origin
	for pn, b in info.parts do
		local src = found[pn]
		if not src then
			model:Destroy()
			return nil, name .. " missing part " .. pn
		end
		local bx = box(b)
		local p = src:Clone()
		p:ClearAllChildren()
		p.Name = pn
		p.Size = span(bx)
		p.CFrame = CFrame.new(turned((bx[1] + bx[4]) / 2 - o[1], (bx[2] + bx[5]) / 2 - o[2], (bx[3] + bx[6]) / 2 - o[3])) * rot
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.DoubleSided = true -- the user: every kit prop double-sided (thin panels read from behind)
		p.CastShadow = not b.alpha and not b.plant and span(bx).Y > SHADOW_STUDS
		skin(p, b, tex)
		if b.plant then p:SetAttribute("Plant", true) end
		-- A part with a manifest `lod` is one level of AssetLODView's LOD 0/1/2 ladder; levels 1-2 arrive
		-- hidden (Transparency 1) and the view shows them past 512 / 1024 studs.
		if b.lod then
			p:SetAttribute("LOD", b.lod)
			if b.lod > 0 then
				p.Transparency = 1
			end
		end
		p.Parent = model
	end
	model.WorldPivot = CFrame.identity
	model:SetAttribute("Kit", kit)
	model:SetAttribute("StudsPerMetre", 2)
	if info.tints then model:SetAttribute("Tints", HttpService:JSONEncode(info.tints)) end
	local host = model:FindFirstChild(name) or model:FindFirstChildWhichIsA("BasePart")
	for mk, v in info.markers or {} do
		local att = Instance.new("Attachment")
		att.Name = mk
		att.Parent = host
		local at = turned(v.pos[1], v.pos[2], v.pos[3])
		local dir = v.dir and turned(v.dir[1], v.dir[2], v.dir[3]) or Vector3.zero
		att.WorldCFrame = if dir.Magnitude > 0.01 then CFrame.lookAt(at, at + dir) else CFrame.new(at)
		if mk:match("^Smoke") then smoke(att) end
	end
	return model, nil
end

-- One asset from its own FBX (Workspace.<Asset>): parts matched by name. A mesh the bundle split by
-- material arrives whole (one part for <P>_M0.._Mn: their joint box, the first one's maps); the plants a
-- planter holds exist only in the bundle, so they are reported and left out.
function PropKitSetup.fromSingle(m: Model, kit: string, name: string, info: any, tex: { [string]: string },
	problems: { string }): (Model?, string?)
	local found: { [string]: MeshPart } = {}
	local parts: { [string]: any } = {}
	for _, p in m:GetDescendants() do
		if not p:IsA("MeshPart") then continue end
		local pn = partName(name, p.Name)
		if info.parts[pn] then
			found[pn], parts[pn] = p, info.parts[pn]
		elseif info.parts[pn .. "_M0"] or info.parts[pn .. "_M1"] then
			local lo, hi, first = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }, nil
			for key, b in info.parts do
				local mi = key:match("^" .. pn:gsub("%p", "%%%0") .. "_M(%d+)$")
				if mi then
					for i = 1, 3 do lo[i], hi[i] = math.min(lo[i], b.min[i]), math.max(hi[i], b.max[i]) end
					if not first or tonumber(mi) < first[1] then first = { tonumber(mi), b } end
				end
			end
			local b = table.clone(first[2])
			b.min, b.max = lo, hi
			found[pn], parts[pn] = p, b
		elseif not p.Name:match("LOD%d") then
			table.insert(problems, name .. ": imported part " .. p.Name .. " is not in the manifest (left out)")
		end
	end
	local plants = 0
	for pn, b in info.parts do
		if b.plant then plants += 1 end
	end
	if plants > 0 then
		table.insert(problems, ("%s: its %d plants come only with %s_ALL.fbx"):format(name, plants, kit))
	end
	if not next(found) then return nil, name .. ": no part matched the manifest" end
	local boxes: { [string]: Box } = {}
	for pn in found do boxes[pn] = box(parts[pn]) end
	local map, misfit = detect(found, boxes)
	if misfit > TOLERANCE then return nil, ("%s: parts do not line up with the manifest (%.3f studs)"):format(name, misfit) end
	local one = table.clone(info)
	one.parts = parts
	return buildAsset(kit, name, one, found, if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0), tex)
end

-- Every imported kit (or just `onlyKit`) -> Props.<Kit>. An import is destroyed after a clean pass.
function PropKitSetup.run(manifestJson: string, texturesJson: string, onlyKit: string?): string
	local kits = HttpService:JSONDecode(manifestJson).kits
	local tex = HttpService:JSONDecode(texturesJson)
	local root = propsRoot()
	local report: { string } = {}
	for kit, assets in kits do
		if onlyKit and kit ~= onlyKit then continue end
		local import = Workspace:FindFirstChild(kit .. "_ALL")
		local dest = folderAt(root, kit)
		local problems, done = {}, 0
		local function file(model: Model?, err: string?)
			if not model then
				table.insert(problems, err :: string)
				return
			end
			local old = dest:FindFirstChild(model.Name)
			if old then old:Destroy() end
			model.Parent = dest
			done += 1
		end
		if import then
			local found: { [string]: MeshPart } = {}
			for _, p in import:GetDescendants() do
				local pn = p.Name:match("^X_(.+)$")
				if pn and p:IsA("MeshPart") then found[pn] = p end
			end
			local boxes: { [string]: Box } = {}
			for _, info in assets do
				for pn, b in info.parts do
					if found[pn] then boxes[pn] = box(b) end
				end
			end
			local map, misfit = detect(found, boxes)
			assert(misfit < TOLERANCE, ("%s_ALL: parts do not line up with the manifest (%.3f studs)"):format(kit, misfit))
			local rot = if map == turned then CFrame.identity else CFrame.Angles(0, math.pi, 0)
			for name, info in assets do file(buildAsset(kit, name, info, found, rot, tex)) end
			for _, m in Workspace:GetChildren() do -- single FBXs of a kit the bundle just filed
				if assets[m.Name] and m:IsA("Model") then m:Destroy() end
			end
		else
			local any = false
			for name, info in assets do
				local m = Workspace:FindFirstChild(name)
				if not (m and m:IsA("Model")) then
					table.insert(problems, name .. ": not imported")
					continue
				end
				any = true
				local model, err = PropKitSetup.fromSingle(m :: Model, kit, name, info, tex, problems)
				file(model, err)
				if model then m:Destroy() end
			end
			if not any then
				table.insert(report, kit .. ": not imported")
				continue
			end
		end
		for _, m in dest:GetChildren() do -- assets the kit no longer lists
			if not assets[m.Name] then
				m.Parent = folderAt(folderAt(ServerStorage, "PropsRetired"), kit)
				table.insert(problems, m.Name .. " no longer in the kit: moved to PropsRetired")
			end
		end
		if import and #problems == 0 then import:Destroy() end
		table.sort(problems)
		table.insert(report, ("%s: %d props (%s)%s"):format(kit, done, if import then "bundle" else "single FBXs",
			if #problems == 0 then "" else ", see below; what failed stays in Workspace"))
		for _, pr in problems do table.insert(report, "  " .. pr) end
	end
	return table.concat(report, "\n")
end

-- The zone prop folders the category kits replace -> ServerStorage.PropsRetired (not deleted), and
-- the part-built bin / seat catalogue in ReplicatedStorage.Props (nothing places it; BinKit and SeatKit
-- replace it). ReplicatedStorage.Props.PowerPoles stays: PowerService builds the power lines from it.
function PropKitSetup.retire(): string
	local root = propsRoot()
	local moved = {}
	local rsProps = game:GetService("ReplicatedStorage"):FindFirstChild("Props")
	if rsProps then
		local dest = folderAt(folderAt(ServerStorage, "PropsRetired"), "PropCatalog")
		local n = 0
		for _, c in rsProps:GetChildren() do
			if c.Name ~= "PowerPoles" and pcall(function() c.Parent = dest end) then n += 1 end
		end
		if n > 0 then table.insert(moved, ("ReplicatedStorage.Props catalogue (%d)"):format(n)) end
	end
	for _, name in RETIRED do
		local f = root:FindFirstChild(name)
		if f then
			local dest = folderAt(ServerStorage, "PropsRetired")
			if dest:FindFirstChild(name) then f.Name = name .. "_" .. os.date("!%Y%m%d%H%M") end
			f.Parent = dest
			table.insert(moved, name)
		end
	end
	return "retired: " .. (if #moved > 0 then table.concat(moved, ", ") else "nothing")
end

return PropKitSetup
