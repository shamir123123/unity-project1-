--!strict
-- LotDressingService
-- Per-placed-building cosmetic dressing. Owns the SCRIPTED lot details the user
-- wants generated (not pre-made): per-placement colour variation, the perimeter
-- fence, scattered pre-made backyard props, and the lot's paved ground -- a works,
-- shop or mid-rise lot's whole parcel, a house's drive and path -- as LotMesh models
-- (LotGroundMesh) that run out to the road's drawn edge on a hill or round a bend.
-- Everything it creates is parented under the building Model, so BuildingService
-- destroying the model cleans it all up -- no separate lifecycle or leak surface.
--
-- Geometry note: TerrainPadService flattens a house's own footprint (a shop's or
-- works' whole yard); a house's yard keeps the lie of the land, so everything
-- planted in it is seated on the ground where it stands.

local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local Config             = require(script.Parent.LotDressingConfig)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)
local RoadConstants      = require(game:GetService("ReplicatedStorage").Road.RoadConstants)
local BuildingTextures   = require(game:GetService("ReplicatedStorage").City.BuildingTextures)

local LotDressingService = {}

local MaterialService = game:GetService("MaterialService")
local CollectionService = game:GetService("CollectionService")
local RoadMeshBuilder = require(game:GetService("ReplicatedStorage").Road.RoadMeshBuilder)
local LotGroundMesh = require(script.Parent.LotGroundMesh)
local TerrainConstants = require(game:GetService("ReplicatedStorage").Terrain.TerrainConstants)

local ZoneGrid = require(game:GetService("ReplicatedStorage").City.ZoneGrid)

-- Live scaled grid values (the old hardcoded 16/3/6 doubled every yard in the half-size
-- world). WS scales the full-size stud literals authored in this file. Template
-- attributes (DoorX, FrontFaceZ, ...) are already WORLD studs: a template is stored at
-- exactly the size it is built, so they are read as-is.
local LOT  = ZoneGrid.LOT_SIZE
local SW   = RoadConstants.SIDEWALK_WIDTH
local WS   = ZoneGrid.BUILDING_SCALE

-- Subtle per-house glass tints so windows don't read identical on every house.
local GLASS_TINTS = {
	Color3.fromRGB(255, 255, 255), Color3.fromRGB(214, 228, 238), Color3.fromRGB(236, 228, 210),
	Color3.fromRGB(208, 222, 212), Color3.fromRGB(226, 232, 240),
}
-- Trim (fascia, corner boards, window casing) is the third colour on a house
-- and the cheapest way to make two houses in one wall colour read apart. White
-- dominates because that is what real stock does.
local TRIM_COLORS = {
	Color3.fromRGB(248, 246, 242), Color3.fromRGB(248, 246, 242), Color3.fromRGB(234, 230, 220),
	Color3.fromRGB(216, 212, 202), Color3.fromRGB(70, 74, 80), Color3.fromRGB(96, 82, 66),
}
-- Every private paved surface -- pad, apron, path, drive -- is the SAME slab as
-- the public footway, because a drive that runs onto the pavement in a different
-- grey draws a seam exactly where there should not be one.
--
-- The height works out for free: developPlot seats the building pivot on the
-- FOOTWAY plane (road half-thickness + SIDEWALK_HEIGHT), so baseY already IS the
-- pavement top. Sinking each slab by half its own thickness lands its top there.
local PAVE_COLOR    = RoadConstants.SIDEWALK_COLOR
local PAVE_MATERIAL = Enum.Material.Concrete

-- The category prop kits (Props.<Kit>) and Nature, by name, less PROP_EXCLUDE: what the house
-- yards pick from. Authored FULL SIZE like the house templates (see propAt); pivot on the ground.
local _kit: { [string]: Model } = {}
-- Every prop a site layout or a kit-prop list can name (the same kits, nothing excluded, plus the
-- RENAMED old names). First kit to hold a name wins.
local _siteKit: { [string]: Model } = {}
local _missingSiteProp: { [string]: boolean } = {}

-- Names templates and older lists still use for props the kit overhaul (KIT_OVERHAUL.md) renamed or
-- replaced: the ResKit renames (Models/kits/_manifests/reskit_renames.json), then the user's swaps.
-- A lookup of the old name gets the new prop, so no template has to be rebuilt.
local RENAMED: { [string]: string } = table.freeze({
	Res_Playset_Fort = "Playset_Fort", Res_Swing_AFrame = "Swing_AFrame", Res_Swing_Nest = "Swing_Nest",
	Res_Sandbox_Octagon = "Sandbox", Res_Slide = "Slide", Res_Trampoline = "Trampoline", Res_Bike = "Bike",
	Res_Wheelbarrow = "Wheelbarrow", Res_LawnMower = "LawnMower", Res_HoseReel = "HoseReel",
	Res_Planter_Wood = "Planter_Wood", Res_Planter_Round = "Planter_Round", Res_Planter_Stone = "Planter_Stone",
	Res_Chair_Folding = "Chair_Teak", Res_PatioSet_Octagon = "PatioSet_Octagon", Res_Parasol = "Parasol_Market",
	Res_Lounger = "Lounger", Res_Rocker = "Chair_Rocker", Res_Adirondack = "Chair_Adirondack",
	Res_TrashCans = "Bin_TrashCans", Res_BollardLamp = "Light_BollardMushroom", Res_PathLight = "PathLight_Lantern",
	Res_ParkLamp = "Light_ParkLamp", Res_Fence_Iron = "Fence_IronRail", Res_Gate_Iron = "Gate_Iron",
	Res_Fence_Hoop = "Fence_Hoop", Res_Wall_Pier = "Wall_Pier", Res_TreeGuard = "Fence_TreeGuard",
	Res_Barrier_Fence = "Fence_Temporary", Res_Barrier_Construction = "Barrier_Construction",
	Bin_Wheelie = "Bin_Recycle", Fence_ChainLink = "Fence_ChainLink_Res", Swingset = "Swing_AFrame",
	Planter_Trough = "Planter_Wood", PlanterPot_Terracotta = "Planter_Round", PlanterBox_Wood = "Planter_Wood",
	GardenBed_Raised = "Planter_Wood", SatelliteDish = "Roof_SatelliteDish",
	Ind_Container_20 = "Container_20", Ind_Container_40 = "Container_40",
})

-- A kit prop with a palette (Tints: umbrellas, bin lids, containers, cabinets) takes one colour per
-- placement, fixed by where it stands; its Paint parts carry it on SurfaceAppearance.Color.
local function tintPlaced(c: Model)
	local json = c:GetAttribute("Tints")
	if typeof(json) ~= "string" then return end
	local tints = HttpService:JSONDecode(json)
	local at = c:GetPivot().Position
	local t = tints[Random.new(math.floor(at.X * 3.1 + at.Z * 5.7)):NextInteger(1, #tints)]
	for _, d in c:GetDescendants() do
		local host = d.Parent
		if d:IsA("SurfaceAppearance") and host and host:GetAttribute("Paint") then
			d.Color = Color3.fromRGB(t[1], t[2], t[3])
		end
	end
end

-- Props the design does not want on a lot. They stay in the folder rather than
-- being deleted -- the kit is the user's asset, this list is the editorial call.
local PROP_EXCLUDE: { [string]: boolean } = {
	Mailbox_Post = true,
	Mailbox_BrickColumn = true,
	LawnMower_Push = true,
	Wheelbarrow = true,
	CompostBin = true,
	Greenhouse_Small = true,
	Chimney_Brick = true,
	Chimney_Boxed = true,
	Steps_Porch = true,
}

-- Yard vocabulary. Each list is rolled ONCE per slot, so a lot gets at most one
-- patio centre, one shed, one utility piece -- scatter with a shape to it.
-- Slot vocabulary. Which list a prop is in IS its placement rule: a shed belongs
-- in a back corner, a fire pit in the middle of the lawn, a barbecue against the
-- house. Picking a name and a spot independently is what put a swing set across
-- the back door.
local BACK_PATIO  = { "PatioTable_Umbrella", "PatioSet_Octagon" }
local BACK_COOK   = { "BBQ_GrillGas", "BBQ_GrillKettle" }
local BACK_CENTRE = { "FirePit" }
local BACK_PLAY   = { "Swing_AFrame", "Trampoline", "Sandbox", "Playset_Fort" }
local BACK_CORNER = { "Shed_Garden", "ClothesLine_Rotary", "RainBarrel" }
local BACK_EDGE   = { "Planter_Wood", "Planter_Stone", "Planter_Round" }
local FRONT_POT   = { "Planter_Round", "Planter_Stone" }
local ROOF_VENT   = { "RoofVent_Box", "RoofVent_Turbine", "PlumbingStack" }
local ROOF_EXTRA  = { "Skylight_Roof" } -- solar comes only with the upgrade (user rule)

-- Fence kinds built from kit PANELS. Hedge is not in the kit and stays a solid
-- part (Config.FENCE) -- a hedge is a green mass, which is the one thing a box
-- actually does well.
local FENCE_KIT = {
	-- `lap` is one END POST in AUTHORED studs: how far each panel is pushed into
	-- its neighbour so the two posts coincide. Measured off each mesh's own post.
	{ weight = 0.26, panel = "Fence_PrivacyWood", lap = 0.80, gate = nil },
	{ weight = 0.22, panel = "Fence_PicketWhite", lap = 0.62, gate = "Gate_PicketWhite" },
	{ weight = 0.16, panel = "Wall_BrickLow",     lap = 0.90, gate = nil },
	{ weight = 0.14, panel = "Fence_SplitRail",   lap = 0.62, gate = nil },
	{ weight = 0.12, panel = "Fence_WroughtIron", lap = 0.55, gate = nil },
	{ weight = 0.10, panel = "Fence_ChainLink_Res", lap = 0.55, gate = nil },
}

local function terrainY(x: number, z: number, fallback: number): number
	local ok, h = pcall(TerrainDataService.getSurfaceY, x, z)
	if ok and typeof(h) == "number" then return h end
	return fallback
end

-- True when a rendered road part (slab / sidewalk / junction) is directly below --
-- used to drop fence pieces where a lot rectangle clips a curved road corner.
local _roadParams = RaycastParams.new()
_roadParams.FilterType = Enum.RaycastFilterType.Include
_roadParams.IgnoreWater = true
local function roadModelAt(pos: Vector3, y0: number): Model?
	local city = workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	if not roads then return nil end
	_roadParams.FilterDescendantsInstances = { roads }
	local hit = workspace:Raycast(Vector3.new(pos.X, y0 + 30, pos.Z), Vector3.new(0, -80, 0), _roadParams)
	if not hit then return nil end

	local inst: Instance? = hit.Instance
	while inst and inst ~= roads do
		if inst:IsA("Model") and inst.Parent == roads then
			return inst
		end
		inst = inst.Parent
	end
	return nil
end

local function onRoad(x: number, y0: number, z: number): boolean
	return roadModelAt(Vector3.new(x, y0, z), y0) ~= nil
end

-- footHalfD IS the property line. PlotGeometry seats a building half its depth behind its
-- frontage line, so footHalfD lands on the outer edge of whatever separates plot from asphalt:
-- the footway where the side has one, a shoulder where it does not (an alley, or a street
-- carrying its pavement on the far kerb only).
--
-- ponytail: roadEnd still measures a full SW from there, so on a kerbless frontage it lands a
-- few studs into the carriageway. It positions the LotEntry attachment only -- the road-graph
-- hand-off point, nothing drawn -- and the paving all works off sidewalkEnd. Ceiling: thread
-- PlotGeometry's real front gap down through developPlot -> dress if that marker ever has to
-- sit exactly on the kerb.
--
-- The old + LOT_GAP came from the deleted tile grid, where footHalfD was the BUILDING edge
-- and the kerb sat a gap beyond it. Against a burgage plot it ran every path and drive 2
-- studs onto the sidewalk and every kerb-cut apron 2 studs onto the asphalt.
local ACCESS_MARGIN = 0.25 -- keeps a lot's edge slab a hair off the kerb
local function accessEnds(_pivot: CFrame, footHalfD: number, _baseY: number): (number, number)
	return footHalfD - ACCESS_MARGIN, footHalfD + SW - ACCESS_MARGIN
end

local function pick<T>(arr: { T }, rng: Random): T
	return arr[rng:NextInteger(1, #arr)]
end

local function jitter(c: Color3, rng: Random): Color3
	local amt = (rng:NextNumber() * 2 - 1) * Config.COLOR_JITTER
	local toward = if amt >= 0 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
	return c:Lerp(toward, math.abs(amt))
end

local function pickFence(rng: Random)
	local total = 0
	for _, f in Config.FENCE do total += f.weight end
	local r = rng:NextNumber() * total
	for _, f in Config.FENCE do
		r -= f.weight
		if r <= 0 then return f end
	end
	return Config.FENCE[1]
end

-- Residential boundary kind. A hedge stays a solid part -- there is no hedge in
-- the imported kit, and a green mass is the one thing a box does well. Anything
-- else comes from the kit panels (FENCE_KIT carries the `panel` key fenceWall
-- branches on).
local function pickFenceKind(rng: Random): any
	if rng:NextNumber() < 0.34 then
		for _, f in Config.FENCE do
			if f.name == "Hedge" then return f end
		end
	end
	local total = 0
	for _, k in FENCE_KIT do total += k.weight end
	local r = rng:NextNumber() * total
	for _, k in FENCE_KIT do
		r -= k.weight
		if r <= 0 then return k end
	end
	return FENCE_KIT[1]
end

local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Color = color
	p.Material = material
	if material == Enum.Material.Asphalt then
		-- Lot asphalt (car parks, forecourts, drive-thru lanes) wears the roads' own.
		p.MaterialVariant = RoadConstants.ASPHALT_VARIANT
		p.Color = RoadConstants.asphaltPartColor(color)
	end
	p.Parent = parent
	return p
end

-- ---- lot ground and road access -----------------------------------------------------------

-- The road's drawn edges, per road piece blob, decoded once per blob: what a LotMesh runs out
-- to. _blobs is every RoadMeshSpecs under _City.Roads, kept by the watcher below.
type PieceEdges = { value: string, edges: { LotGroundMesh.Edge }, x0: number, x1: number, z0: number, z1: number }
local _pieceEdges: { [StringValue]: PieceEdges } = {}
local _blobs: { [StringValue]: boolean } = {}
-- The same road pieces in a 64-stud grid by their edges' bounding box, so a lot's paving reads the
-- pieces near it instead of every piece in the city. A load rebuilds every lot's mesh, and the
-- full scan made that lots x pieces: ~75M box tests for a 15,000-lot city. Pieces are baked once
-- and replaced, never edited in place, so indexing on arrival is exact.
local BLOB_CELL = 64
local _blobCells: { [number]: { [StringValue]: boolean } } = {}
local _blobCellKeys: { [StringValue]: { number } } = {}
local _roads: Instance? = nil
local _roadConns: { RBXScriptConnection } = {}
type Box = { x0: number, x1: number, z0: number, z1: number }
local _dirty: Box? = nil
local SETTLE = 0.5 -- seconds a burst of road, ground or lot changes settles before lots re-meet it
local REBUILD_SLICE = 0.004 -- seconds of lot rebuilding per frame while a burst re-meets

-- ponytail: ONE neutral look for every lot's paving in every zone (user, 2026-09-29: "a neutral
-- sidewalk texture ... we will change the texture later"). World-projected, so neighbouring lots
-- and their gap fills read as one surface. Same look as the footways (RoadMeshView PAVEMENT_LOOK):
-- the RoadConstants.PAVE_VARIANT concrete tinted SIDEWALK_COLOR -- so a lot meets its sidewalk
-- with no seam. Swap the look in RoadConstants.
local PAVE_LOOK = Enum.Material.Concrete
local PAVE_VARIANT = RoadConstants.PAVE_VARIANT
local PAVE_TINT = RoadConstants.SIDEWALK_COLOR
-- A lot cars drive on (its template has its own car park or yard: ParkingStyle "baked"/"small")
-- wears the road's asphalt instead, in the lanes' shade (user, 2026-10-04).
local PARK_LOOK = Enum.Material.Asphalt
local PARK_TINT = RoadConstants.asphaltPartColor(RoadConstants.ROAD_COLOR)
-- Gap fill (user, 2026-09-29: 8 studs): a lot's paving runs out of its side all the way to a road
-- this close, and halfway to another lot this close, so the two halves meet. A building going up
-- in the gap pulls its neighbours' fills back to their own edges; bulldozed, they grow back.
local FILL_MAX = 8
local FILL_SEAM = 0.05 -- two halves overlap by this: same look, no crack
local FILL_RISE = 2 -- a lot further up or down than this is across a bank, not a gap: no fill
local FEATHER = LotGroundMesh.FEATHER -- a patch overlaps the paving it joins by this
local SIDE_MAX_RISE = 1.5 -- a road along the side further up or down than this keeps its own bank
local YARD_BANK = 2.5 -- a gap fill ends where the ground stands this far off its level (a bank)
-- A flat yard ends at the foot of ground rising this far over it (another road's embankment),
-- stays level over a dip this shallow, and melts down into anything deeper.
local YARD_RISE = 0.6
local YARD_DROP = 1.5
-- A slab yard's paving frame sits this far under its base (the paving lands on the terrain pad,
-- GROUND_SINK below, plus LotGroundMesh's LIFT).
local LOT_GROUND_Y = -0.05

local function edgesOf(sv: StringValue): PieceEdges
	local c = _pieceEdges[sv]
	if c and c.value == sv.Value then return c end
	local ok, specs = pcall(RoadMeshBuilder.decodeSpecs, sv.Value)
	local edges = if ok then LotGroundMesh.edgesFromSpecs(specs) else {}
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, e in edges do
		x0, x1 = math.min(x0, e[1], e[4]), math.max(x1, e[1], e[4])
		z0, z1 = math.min(z0, e[3], e[6]), math.max(z1, e[3], e[6])
	end
	local fresh: PieceEdges = { value = sv.Value, edges = edges, x0 = x0, x1 = x1, z0 = z0, z1 = z1 }
	_pieceEdges[sv] = fresh
	return fresh
end

local function isBlob(d: Instance): boolean
	return d.Name == "RoadMeshSpecs" and d:IsA("StringValue")
end

local function unindexBlob(sv: StringValue)
	local keys = _blobCellKeys[sv]
	if not keys then return end
	_blobCellKeys[sv] = nil
	for _, k in keys do
		local cell = _blobCells[k]
		if cell then
			cell[sv] = nil
			if next(cell) == nil then _blobCells[k] = nil end
		end
	end
end

local function indexBlob(sv: StringValue)
	unindexBlob(sv)
	local c = edgesOf(sv)
	if c.x0 > c.x1 or c.z0 > c.z1 then return end -- no edges: it can never meet a lot
	local keys = {}
	for cz = math.floor(c.z0 / BLOB_CELL), math.floor(c.z1 / BLOB_CELL) do
		for cx = math.floor(c.x0 / BLOB_CELL), math.floor(c.x1 / BLOB_CELL) do
			local k = cz * 65536 + cx
			table.insert(keys, k)
			local cell = _blobCells[k]
			if not cell then
				cell = {}
				_blobCells[k] = cell
			end
			cell[sv] = true
		end
	end
	_blobCellKeys[sv] = keys
end

-- ---- the lots standing, for the gap fill ----
-- Every dressed building's parcel in its road-facing frame (+Z to the road, origin on its base),
-- in a 64-stud hash. `fills`: its paving runs to its sides (so it fills toward this one too).
type LotRect = { frame: CFrame, halfW: number, z0: number, z1: number, fills: boolean, cells: { number } }
local _lots: { [Model]: LotRect } = {}
local _lotCells: { [number]: { [Model]: boolean } } = {}
local LOT_CELL = 64

local function rectBox(r: LotRect, grow: number): Box
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, c in { Vector3.new(-r.halfW, 0, r.z0), Vector3.new(r.halfW, 0, r.z0), Vector3.new(-r.halfW, 0, r.z1), Vector3.new(r.halfW, 0, r.z1) } do
		local w = r.frame:PointToWorldSpace(c)
		x0, x1 = math.min(x0, w.X), math.max(x1, w.X)
		z0, z1 = math.min(z0, w.Z), math.max(z1, w.Z)
	end
	return { x0 = x0 - grow, x1 = x1 + grow, z0 = z0 - grow, z1 = z1 + grow }
end

local function cellsOf(b: Box): { number }
	local out = {}
	for cz = math.floor(b.z0 / LOT_CELL), math.floor(b.z1 / LOT_CELL) do
		for cx = math.floor(b.x0 / LOT_CELL), math.floor(b.x1 / LOT_CELL) do
			table.insert(out, cz * 65536 + cx)
		end
	end
	return out
end

local function unregisterLot(model: Model)
	local r = _lots[model]
	if not r then return end
	_lots[model] = nil
	for _, k in r.cells do
		local c = _lotCells[k]
		if c then
			c[model] = nil
			if next(c) == nil then _lotCells[k] = nil end
		end
	end
end

local function registerLot(model: Model, r: LotRect)
	unregisterLot(model)
	r.cells = cellsOf(rectBox(r, 0))
	_lots[model] = r
	for _, k in r.cells do
		local c = _lotCells[k]
		if not c then
			c = {}
			_lotCells[k] = c
		end
		c[model] = true
	end
end

-- How far along the flat ray o + t * dir (t >= 0) it enters lot r; nil when it misses.
local function rayIntoLot(o: Vector3, dir: Vector3, r: LotRect): number?
	local lo = r.frame:PointToObjectSpace(o)
	local ld = r.frame:VectorToObjectSpace(dir)
	local tIn, tOut = 0, math.huge
	for _, ax in { { lo.X, ld.X, -r.halfW, r.halfW }, { lo.Z, ld.Z, r.z0, r.z1 } } do
		local p, d, a, b = ax[1], ax[2], ax[3], ax[4]
		if math.abs(d) < 1e-9 then
			if p < a or p > b then return nil end
		else
			local t1, t2 = (a - p) / d, (b - p) / d
			if t1 > t2 then t1, t2 = t2, t1 end
			tIn, tOut = math.max(tIn, t1), math.min(tOut, t2)
			if tIn > tOut then return nil end
		end
	end
	return tIn
end

-- The nearest other lot straight out from `origins` along `dir`, within FILL_MAX: how far, and it.
local function nearestLot(own: Instance?, origins: { Vector3 }, dir: Vector3): (number?, LotRect?)
	local best, bestLot = math.huge, nil
	for _, o in origins do
		local seen: { [Model]: boolean } = {}
		for _, k in cellsOf({ x0 = o.X - FILL_MAX, x1 = o.X + FILL_MAX, z0 = o.Z - FILL_MAX, z1 = o.Z + FILL_MAX }) do
			for other in _lotCells[k] or {} do
				if other == own or seen[other] then continue end
				seen[other] = true
				local r = _lots[other]
				local t = rayIntoLot(o, dir, r)
				if t and t < best then best, bestLot = t, r end
			end
		end
	end
	if best > FILL_MAX then return nil, nil end
	return best, bestLot
end

-- Points along one edge of a patch (lot frame), where the gap beyond it is measured.
local function edgeOrigins(F: CFrame, a: Vector3, b: Vector3): { Vector3 }
	local out = {}
	for _, t in { 0.1, 0.5, 0.9 } do table.insert(out, F:PointToWorldSpace(a:Lerp(b, t))) end
	return out
end

-- The paving out of one side of a lot (`side` +1 = its +X): halfway across the gap to the next lot
-- at its level (front-facing, run out to the road like the parcel, sides on the road's normal so
-- the two halves meet, lying on the gap's ground); out to a road along that side when there is no
-- lot; nothing across a bank. It overlaps the paving it grows from by FEATHER.
local function sidePatch(own: Instance?, p: LotGroundMesh.Params, side: number, base: number): LotGroundMesh.Params?
	local F = p.frame
	local dir = F:VectorToWorldSpace(Vector3.xAxis * side)
	dir = Vector3.new(dir.X, 0, dir.Z).Unit
	local gap, r = nearestLot(own, edgeOrigins(F, Vector3.new(side * base, 0, p.zBack), Vector3.new(side * base, 0, p.zFront)), dir)
	if gap and r then
		local level = r.frame.Position.Y
		if math.abs(level - F.Position.Y) > FILL_RISE then return nil end
		local fill = gap * 0.5 + FILL_SEAM
		local q = table.clone(p)
		if side > 0 then q.x0, q.x1 = base - FEATHER, base + fill else q.x0, q.x1 = -base - fill, -base + FEATHER end
		q.trap = true -- it lies on the gap's own ground, like the paint a lot leaves in Cities: Skylines
		-- Its outer edge meets the neighbour's own fill, or melts into the neighbour's lawn.
		q.soft = "b" .. (if r.fills then "" elseif side > 0 then "r" else "l")
		return q
	end
	-- Turned a quarter, the side is the patch's front; lot z runs along its x (-z on the +X side).
	return {
		frame = F * CFrame.Angles(0, side * math.pi * 0.5, 0),
		x0 = if side < 0 then p.zBack else -p.zFront, x1 = if side < 0 then p.zFront else -p.zBack,
		zFront = base, zBack = base - FEATHER, reach = FILL_MAX, square = true, maxRise = SIDE_MAX_RISE,
		soft = "lr", color = p.color,
	}
end

-- The ground exactly as the client draws it: 4-stud cells, each two triangles split along
-- (x0, z0)-(x1, z1) (TerrainMesh), at the visible surface. Bilinear heights sat inside a creased
-- cell, so paving following them met the grass in a sawtooth. Corners are cached per build.
local MAX_CORNER = TerrainConstants.CORNERS_PER_AXIS - 1
local function groundSampler(fallback: number): LotGroundMesh.Ground
	local corners: { [number]: number } = {}
	local function corner(gx: number, gz: number): number
		local k = gz * TerrainConstants.CORNERS_PER_AXIS + gx
		local h = corners[k]
		if not h then
			local ok, raw = pcall(TerrainDataService.getCorner, gx, gz)
			h = if ok and typeof(raw) == "number" then TerrainConstants.rawToWorldY(raw) + TerrainConstants.RENDER_BULGE else fallback
			corners[k] = h
		end
		return h :: number
	end
	return function(x: number, z: number): number
		local fx = math.clamp(TerrainConstants.worldToCorner(x), 0, MAX_CORNER)
		local fz = math.clamp(TerrainConstants.worldToCorner(z), 0, MAX_CORNER)
		local gx, gz = math.min(math.floor(fx), MAX_CORNER - 1), math.min(math.floor(fz), MAX_CORNER - 1)
		local sx, sz = fx - gx, fz - gz
		local h00, h11 = corner(gx, gz), corner(gx + 1, gz + 1)
		if sz >= sx then
			local h01 = corner(gx, gz + 1)
			return h00 + sx * (h11 - h01) + sz * (h01 - h00)
		end
		local h10 = corner(gx + 1, gz)
		return h00 + sx * (h10 - h00) + sz * (h11 - h10)
	end
end

local function rebuildLotMesh(m: Model)
	local p: LotGroundMesh.Params? = LotGroundMesh.read(m)
	if not p then return end
	local own = m:FindFirstAncestorWhichIsA("Model")
	local side, base = m:GetAttribute("Side"), m:GetAttribute("SideBase")
	if typeof(side) == "number" and typeof(base) == "number" then
		p = sidePatch(own, p, side, base)
	elseif m:GetAttribute("Parcel") then
		-- A parcel melts into the land on every free edge; its sides are overlapped by its fills
		-- when it has any, and its back is shared with a lot at its level backing onto it.
		local F = p.frame
		local back = Vector3.new(F.LookVector.X, 0, F.LookVector.Z).Unit -- -Z: away from the road
		local t, r = nearestLot(own, edgeOrigins(F, Vector3.new(p.x0, 0, p.zBack), Vector3.new(p.x1, 0, p.zBack)), back)
		local shared = t and r and t < 1 and math.abs(r.frame.Position.Y - F.Position.Y) <= FILL_RISE
		p.soft = if shared then "lr" else "blr"
		p.floorY = F.Position.Y - 0.02 -- level over a shallow dip, like the yard it is
		p.flat = true -- and dead level inside the lot: only what lies in front of it meets the road
	end
	local sv = m:FindFirstChild("RoadMeshSpecs")
	if not p then
		if sv then sv:Destroy() end
		return
	end
	local x0, x1, z0, z1 = LotGroundMesh.bounds(p)
	local edges: { LotGroundMesh.Edge } = {}
	local seen: { [StringValue]: boolean } = {}
	for cz = math.floor(z0 / BLOB_CELL), math.floor(z1 / BLOB_CELL) do
		for cx = math.floor(x0 / BLOB_CELL), math.floor(x1 / BLOB_CELL) do
			local cell = _blobCells[cz * 65536 + cx]
			if not cell then continue end
			for blobSv in cell do
				if seen[blobSv] or not _blobs[blobSv] then continue end
				seen[blobSv] = true
				local c = edgesOf(blobSv)
				if c.x1 >= x0 and c.x0 <= x1 and c.z1 >= z0 and c.z0 <= z1 then
					table.move(c.edges, 1, #c.edges, #edges + 1, edges)
				end
			end
		end
	end
	local b = LotGroundMesh.build(p, edges, groundSampler(p.frame.Position.Y))
	local blob = if b and not b:isEmpty() then b:encode() else nil
	if not blob then
		if sv then sv:Destroy() end
		return
	end
	if not (sv and sv:IsA("StringValue")) then
		local fresh = Instance.new("StringValue")
		fresh.Name = "RoadMeshSpecs"
		fresh.Value = blob
		fresh.Parent = m
	elseif sv.Value ~= blob then
		sv.Value = blob
	end
end

-- A house's yard keeps the lie of the land (only the house's own footprint is flat), so each kit
-- prop stood on the kit's floor (OnGround) drops onto the ground under it -- or the paving, LIFT
-- over it -- at the lowest point of its footprint: no corner floats. Repeatable as the ground moves.
-- ponytail: a long prop (a 4.8-stud fence panel) buries its uphill end on a steep shoulder; pitch
-- it along the slope if that shows.
local FOOT = { Vector3.zero, Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, 1) }
local function seatOnGround(yard: Instance, baseY: number)
	local ground = groundSampler(baseY)
	local paves: { LotGroundMesh.Params } = {}
	for _, m in yard:GetChildren() do
		local p = if m:IsA("Model") and CollectionService:HasTag(m, RoadMeshBuilder.LOT_TAG) then LotGroundMesh.read(m) else nil
		if p then table.insert(paves, p) end
	end
	for _, c in yard:GetChildren() do
		if not (c:IsA("Model") and c:GetAttribute("OnGround")) then continue end
		local box, size = c:GetBoundingBox()
		local low = math.huge
		for _, k in FOOT do
			local w = box:PointToWorldSpace(size * 0.5 * k)
			local y = ground(w.X, w.Z)
			for _, p in paves do
				local l = p.frame:PointToObjectSpace(w)
				if l.X >= p.x0 and l.X <= p.x1 and l.Z >= p.zBack and l.Z <= p.zFront then
					y += LotGroundMesh.LIFT
					break
				end
			end
			low = math.min(low, y)
		end
		local piv = c:GetPivot()
		c:PivotTo(piv + Vector3.new(0, low - piv.Y, 0))
	end
end

-- Lots whose paving could reach something that just changed -- a road piece, the ground, a lot
-- beside them -- re-meet it. Sliced across frames: a city loading re-meets every lot at once.
local function flushDirty()
	local r = _dirty
	_dirty = nil
	if not r then return end
	local t0 = os.clock()
	for _, m in CollectionService:GetTagged(RoadMeshBuilder.LOT_TAG) do
		if os.clock() - t0 > REBUILD_SLICE then
			task.wait()
			t0 = os.clock()
		end
		if not (m:IsA("Model") and m:IsDescendantOf(workspace)) then continue end
		local p = LotGroundMesh.read(m)
		if not p then continue end
		local x0, x1, z0, z1 = LotGroundMesh.bounds(p)
		if x1 >= r.x0 and x0 <= r.x1 and z1 >= r.z0 and z0 <= r.z1 then
			local ok, err = pcall(rebuildLotMesh, m)
			if not ok then warn("[LotDressingService] lot mesh rebuild failed: " .. tostring(err)) end
		end
	end
	local yards: { [Instance]: number } = {}
	for model, lot in _lots do
		local yard = model:FindFirstChild("Yard")
		local b = rectBox(lot, 0)
		if yard and yard:GetAttribute("Draped") and b.x1 >= r.x0 and b.x0 <= r.x1 and b.z1 >= r.z0 and b.z0 <= r.z1 then
			yards[yard] = lot.frame.Position.Y
		end
	end
	for yard, baseY in yards do
		if os.clock() - t0 > REBUILD_SLICE then
			task.wait()
			t0 = os.clock()
		end
		if not yard:IsDescendantOf(workspace) then continue end
		local ok, err = pcall(seatOnGround, yard, baseY)
		if not ok then warn("[LotDressingService] seatOnGround failed: " .. tostring(err)) end
	end
end

local function markDirty(c: Box)
	if c.x0 > c.x1 then return end
	local r = _dirty
	if r then
		r.x0, r.x1 = math.min(r.x0, c.x0), math.max(r.x1, c.x1)
		r.z0, r.z1 = math.min(r.z0, c.z0), math.max(r.z1, c.z1)
		return
	end
	_dirty = { x0 = c.x0, x1 = c.x1, z0 = c.z0, z1 = c.z1 }
	task.delay(SETTLE, flushDirty)
end

-- Lazily, on the first lot: every blob under _City.Roads, and every one that comes or goes after.
-- A new map builds a new _City, so a watch on a folder that has left the world starts over.
local function watchRoads()
	if _roads and _roads:IsDescendantOf(workspace) then return end
	for _, c in _roadConns do c:Disconnect() end
	table.clear(_roadConns)
	table.clear(_blobs)
	table.clear(_pieceEdges)
	table.clear(_blobCells)
	table.clear(_blobCellKeys)
	local city = workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	_roads = roads
	if not roads then return end
	for _, d in roads:GetDescendants() do
		if isBlob(d) then
			_blobs[d :: StringValue] = true
			indexBlob(d :: StringValue)
		end
	end
	table.insert(_roadConns, roads.DescendantAdded:Connect(function(d)
		if not isBlob(d) then return end
		_blobs[d :: StringValue] = true
		indexBlob(d :: StringValue)
		markDirty(edgesOf(d :: StringValue))
	end))
	table.insert(_roadConns, roads.DescendantRemoving:Connect(function(d)
		if not _blobs[d :: any] then return end
		_blobs[d :: any] = nil
		unindexBlob(d :: any)
		local c = _pieceEdges[d :: any]
		_pieceEdges[d :: any] = nil
		if c then markDirty(c) end
	end))
end

-- One patch of paving (LotGroundMesh.Params) as a LotMesh model under `parent`, in the one look.
-- Built once the building has settled where it stands (settleLot).
local function lotMesh(parent: Instance, p: LotGroundMesh.Params): Model
	local m = Instance.new("Model")
	m.Name = "LotMesh"
	LotGroundMesh.write(m, p)
	m:SetAttribute("Material", PAVE_LOOK.Name)
	m:SetAttribute("Variant", PAVE_VARIANT)
	CollectionService:AddTag(m, RoadMeshBuilder.LOT_TAG)
	m.Parent = parent
	return m
end

-- The gap fill out of each side of paving that spans a lot's width (halfW), zBack..zFront in the
-- lot frame: sidePatch decides at every rebuild what, if anything, each one is.
local function sidePatches(parent: Instance, frame: CFrame, halfW: number, zBack: number, zFront: number, bank: number?, green: string?)
	for _, side in { -1, 1 } do
		if green and green:find(if side < 0 then "l" else "r") then continue end
		local m = lotMesh(parent, { frame = frame, x0 = 0, x1 = 0, zFront = zFront, zBack = zBack, bank = bank, color = PAVE_TINT })
		m:SetAttribute("Side", side)
		m:SetAttribute("SideBase", halfW)
	end
end

-- A works, shop or mid-rise lot is hard-standing: ONE paving over the whole parcel -- not only the
-- template's own footprint -- out to the road's drawn edge (a footway's back, or the asphalt), so
-- the lots in a row meet edge to edge, the wedge a bend opens in front of a straight lot is
-- filled, and a sloping street meets it with no step or gap (LotGroundMesh). The kits' own flat
-- ground plates are dropped at placement (BuildingService): this is the yard's ground now. The yard
-- is padded GROUND_SINK below the base, so the paving -- LIFT over that -- lands a hair under the
-- details a template bakes into its yard (stall lines, pavers).
--
-- A template's `GreenSides` (any of "l", "r", "b": the lot frame's x0, x1 and back -- left and
-- right as seen from the street) keeps that side lawn: the paving stops at the building's Body
-- there, and no gap fill runs beside it.
local function lotGround(model: Model, pivot: CFrame, footHalfD: number, plotW: number, plotD: number)
	local folder = Instance.new("Folder")
	folder.Name = "Yard" -- lot dressing, not structure (PlacementFit.poleBlockedBy)
	folder.Parent = model
	-- The paving's top lands on the kit's own Ground height (the parcel holds 0.02 under its frame).
	local groundTop = model:GetAttribute("GroundTop")
	local frame = pivot * CFrame.new(0, if typeof(groundTop) == "number" then groundTop + 0.02 else LOT_GROUND_Y, 0)
	local halfW, back = plotW * 0.5, footHalfD - plotD
	local x0, x1, zBack = -halfW, halfW, back
	local green = model:GetAttribute("GreenSides")
	local body = model:FindFirstChild("Body")
	if typeof(green) == "string" and body and body:IsA("BasePart") then
		local bx0, bx1, bz0 = math.huge, -math.huge, math.huge
		for _, k in FOOT do
			local l = pivot:PointToObjectSpace(body.CFrame:PointToWorldSpace(body.Size * 0.5 * k))
			bx0, bx1, bz0 = math.min(bx0, l.X), math.max(bx1, l.X), math.min(bz0, l.Z)
		end
		if green:find("l") then x0 = math.max(x0, bx0) end
		if green:find("r") then x1 = math.min(x1, bx1) end
		if green:find("b") then zBack = math.max(zBack, bz0) end
	end
	local style = model:GetAttribute("ParkingStyle")
	local carPark = style == "baked" or style == "small"
	local parcel = lotMesh(folder, { frame = frame, x0 = x0, x1 = x1, zFront = footHalfD, zBack = zBack, trap = true,
		bank = YARD_RISE, drop = YARD_DROP, color = if carPark then PARK_TINT else PAVE_TINT })
	parcel:SetAttribute("Parcel", true)
	if carPark then
		parcel:SetAttribute("Material", PARK_LOOK.Name)
		parcel:SetAttribute("Variant", RoadConstants.ASPHALT_VARIANT)
	end
	sidePatches(folder, frame, halfW, zBack, footHalfD, YARD_BANK, if typeof(green) == "string" then green else nil)
end

local DRIVE_LIFT = 0.03 -- over the lawn (the terrain pad sits exactly on the lot plane)

-- One kit prop, seated on the ground at `cf` (its pivot IS its ground centre).
--
-- The kit is authored at world size (2 studs per metre, like the building
-- templates), so it goes in at exactly the size it was imported at.
local function propAt(parent: Instance, name: string, cf: CFrame): Model?
	local src = _kit[name]
	if not src then return nil end
	local c = src:Clone()
	c:PivotTo(cf)
	tintPlaced(c)
	for _, p in c:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			-- Yard props repeat on every residential lot: their shadows are
			-- invisible at city view but re-cost on every camera turn.
			p.CastShadow = false
		end
	end
	c.Parent = parent
	return c
end

-- Placed footprint half-extents, for the yard packer.
local function propHalf(name: string): (number, number)
	local m = _kit[name]
	if not m then return 0, 0 end
	local e = m:GetExtentsSize()
	return e.X * 0.5, e.Z * 0.5
end

local function pickKit(list: { string }, rng: Random): string?
	local live: { string } = {}
	for _, n in list do
		if _kit[n] then table.insert(live, n) end
	end
	if #live == 0 then return nil end
	return live[rng:NextInteger(1, #live)]
end

-- Lot-local (lx, lz) + yaw -> a world CFrame standing on the ground at `gy`.
-- Built off the pivot rather than by pulling a yaw back out of it, because
-- ToEulerAnglesYXZ returns X first and that is an easy one to get wrong.
local function seatCF(pivot: CFrame, lx: number, lz: number, yaw: number, gy: number): CFrame
	local cf = pivot * CFrame.new(lx, 0, lz) * CFrame.Angles(0, yaw, 0)
	local pos = cf.Position
	return CFrame.new(pos.X, gy, pos.Z) * (cf - pos)
end

type Rect = { cx: number, cz: number, hx: number, hz: number }
local function rectsOverlap(a: Rect, b: Rect): boolean
	return math.abs(a.cx - b.cx) < (a.hx + b.hx) and math.abs(a.cz - b.cz) < (a.hz + b.hz)
end

-- ============================================================================
-- Roof props. A vent or a skylight has to lie ON the slope, so the surface is
-- found by raycast instead of guessed off the bounding box. Every part of a
-- placed building is CanQuery=false except the body (BuildingService sets
-- that), so the flags are flipped for the cast and put straight back.
-- ============================================================================
local _roofParams = RaycastParams.new()
_roofParams.FilterType = Enum.RaycastFilterType.Include
_roofParams.IgnoreWater = true

local function roofHit(model: Model, pivot: CFrame, lx: number, lz: number, topY: number): RaycastResult?
	local restore: { BasePart } = {}
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and not p.CanQuery then
			table.insert(restore, p)
			p.CanQuery = true
		end
	end
	_roofParams.FilterDescendantsInstances = { model }
	local from = (pivot * CFrame.new(lx, topY + 8, lz)).Position
	local hit = workspace:Raycast(from, Vector3.new(0, -(topY + 16), 0), _roofParams)
	for _, p in restore do
		p.CanQuery = false
	end
	return hit
end

-- Flat on the slope: the prop's +Y is laid along the surface normal.
local function onSlope(hit: RaycastResult, yaw: number): CFrame
	local p = hit.Position
	return CFrame.lookAt(p, p + hit.Normal) * CFrame.Angles(math.pi / 2, 0, yaw)
end

local function dressRoof(parent: Instance, model: Model, pivot: CFrame, houseHalfW: number, ridgeY: number, rng: Random)
	local reach = math.max(1.5, houseHalfW * 0.55)

	-- No chimneys: the kit has two and the design does not want either.
	for _ = 1, rng:NextInteger(0, 2) do
		local name = pickKit(ROOF_VENT, rng)
		local hit = roofHit(model, pivot, rng:NextNumber(-reach, reach), rng:NextNumber(-reach, reach), ridgeY)
		if name and hit then propAt(parent, name, onSlope(hit, 0)) end
	end

	if rng:NextNumber() < 0.3 then
		local name = pickKit(ROOF_EXTRA, rng)
		local hit = roofHit(model, pivot, rng:NextNumber(-reach * 0.7, reach * 0.7), rng:NextNumber(-reach * 0.7, reach * 0.7), ridgeY)
		if name and hit then propAt(parent, name, onSlope(hit, 0)) end
	end

	if rng:NextNumber() < 0.12 and _kit.WeatherVane then
		local hit = roofHit(model, pivot, 0, 0, ridgeY)
		if hit then
			propAt(parent, "WeatherVane", seatCF(pivot, 0, 0, rng:NextNumber() * math.pi * 2, hit.Position.Y - 0.2))
		end
	end
end

-- Fill only the small property-side seam before a sidewalk. The public sidewalk
-- stays clear, so no private driveway or entrance overlaps it.
local function fillFrontPaving(parent: Instance, pivot: CFrame, halfW: number, z0: number, z1: number, baseY: number, cfg: any, name: string, centerX: number?)
	local depth = z1 - z0
	if depth <= 0.1 or halfW <= 0.1 then return end
	newPart(
		parent,
		name,
		Vector3.new(halfW * 2, cfg.thickness, depth),
		pivot * CFrame.new(centerX or 0, baseY - pivot.Position.Y + cfg.lift, (z0 + z1) * 0.5),
		cfg.color,
		cfg.material
	)
end

-- A MeshPart with a TextureID ignores Part.Color completely, so tint its
-- SurfaceAppearance instead. Legacy untextured parts have no SurfaceAppearance
-- and still take Part.Color, so both stocks paint through one call.
-- A MeshPart with a TextureID ignores Part.Color completely, so tint its
-- SurfaceAppearance instead. Legacy untextured parts have no SurfaceAppearance
-- and still take Part.Color, so both stocks paint through one call.
--
-- Tinting only. SurfaceAppearance.ColorMap is PLUGIN-CAPABILITY ONLY and throws
-- "cannot write 'ColorMap'" from a game thread, so material variety is assigned
-- to the TEMPLATES at authoring time, not per placement here.
local function paint(p: BasePart, c: Color3)
	local sa = p:FindFirstChildWhichIsA("SurfaceAppearance")
	if sa then
		sa.Color = c
	else
		p.Color = c
	end
end

local function recolor(model: Model, rng: Random)
	local wall = jitter(pick(Config.WALL_COLORS, rng), rng)
	local roof = jitter(pick(Config.ROOF_COLORS, rng), rng)
	local door = pick(Config.DOOR_COLORS, rng)
	local trim = pick(TRIM_COLORS, rng)
	local glass = GLASS_TINTS[rng:NextInteger(1, #GLASS_TINTS)]

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("PaintRole")
			if role == "Wall" then
				paint(d, wall)
			elseif role == "Roof" then
				paint(d, roof)
			elseif role == "Door" then
				paint(d, door)
			elseif role == "Trim" then
				paint(d, trim)
			end
		elseif d:IsA("Decal") and d.Texture == BuildingTextures.WINDOW_SINGLE then
			d.Color3 = glass
		end
	end
end

-- A fence run built from KIT PANELS rather than one long box. This is what the
-- imported fence assets are for: a picket run has to read as pickets, and a
-- stretched box never will.
-- ponytail: one MeshPart per ~3 studs of run, so a fully fenced lot costs about
-- 30 parts. Ceiling -- if part count ever bites, bake a whole side into one
-- mesh at authoring time; the placement maths here does not change.
local function fencePanelRun(parent: Instance, pivot: CFrame, baseY: number, x0: number, z0: number, x1: number, z1: number, cfg: any)
	local pw = select(1, propHalf(cfg.panel)) * 2
	if pw < 0.2 then return end
	local wp0 = (pivot * CFrame.new(x0, 0, z0)).Position
	local wp1 = (pivot * CFrame.new(x1, 0, z1)).Position
	-- Push both ends out by half a panel thickness so perpendicular runs meet
	-- INSIDE each other at a corner instead of leaving a notch of grass.
	local corner = select(2, propHalf(cfg.panel))
	if (wp1 - wp0).Magnitude > 1e-3 then
		local ext = (wp1 - wp0).Unit * corner
		wp0, wp1 = wp0 - ext, wp1 + ext
	end
	local dir = wp1 - wp0
	local len = dir.Magnitude
	if len < pw * 0.45 then return end
	local u = dir.Unit
	-- Panels are authored with their WIDTH on local X, so aim RightVector along
	-- the run: RightVector of a yaw-only CFrame is (cos y, 0, -sin y).
	local yaw = math.atan2(-u.Z, u.X)
	-- Panels overlap by a WHOLE end post (cfg.lap, authored studs), so the two
	-- posts at a join occupy the same space and the run reads as one fence. A
	-- partial lap just stands them side by side, which is the doubled post.
	local lap = (cfg.lap or 0.5) * WS
	local step = math.max(pw * 0.4, pw - lap)
	local n = math.max(1, math.ceil(len / step))
	for i = 1, n do
		local p = wp0:Lerp(wp1, (i - 0.5) / n)
		local gy = terrainY(p.X, p.Z, baseY)
		if math.abs(gy - baseY) <= 4.5 and not onRoad(p.X, gy, p.Z) then
			propAt(parent, cfg.panel, CFrame.new(p.X, gy, p.Z) * CFrame.Angles(0, yaw, 0))
		end
	end
end

-- One fence RUN, sliced so each piece sits on the local GROUND (pad, shoulder or
-- natural slope) instead of one slab floating at the lot base. Slices at similar
-- height merge back into single parts, so a flat pad still emits one part per run --
-- only the pad shoulder steps. Slices over a sharp drop/berm (> 4.5 studs off the
-- lot base) are skipped entirely: a natural break instead of a floating fence.
local function fenceWall(parent: Instance, pivot: CFrame, baseY: number, x0: number, z0: number, x1: number, z1: number, cfg: any)
	if cfg.panel then
		fencePanelRun(parent, pivot, baseY, x0, z0, x1, z1, cfg)
		return
	end
	-- Grow a solid run by half its thickness at each end, so two perpendicular
	-- runs overlap at the corner rather than leaving a square notch of grass.
	local lenAxis0 = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
	if lenAxis0 > 1e-3 then
		local ex = (x1 - x0) / lenAxis0 * cfg.thickness * 0.5
		local ez = (z1 - z0) / lenAxis0 * cfg.thickness * 0.5
		x0, z0, x1, z1 = x0 - ex, z0 - ez, x1 + ex, z1 + ez
	end
	local lenAxis = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
	if lenAxis < 0.3 then return end
	local wp0 = (pivot * CFrame.new(x0, 0, z0)).Position
	local wp1 = (pivot * CFrame.new(x1, 0, z1)).Position
	local n = math.max(1, math.ceil(lenAxis / 7))

	local ys: { [number]: number } = {}
	for i = 1, n do
		local m = wp0:Lerp(wp1, (i - 0.5) / n)
		local a = wp0:Lerp(wp1, (i - 1) / n)
		local b = wp0:Lerp(wp1, i / n)
		local gy = terrainY(m.X, m.Z, baseY)
		if math.abs(gy - baseY) <= 4.5
			and not onRoad(m.X, gy, m.Z)
			and not onRoad(a.X, gy, a.Z)
			and not onRoad(b.X, gy, b.Z) then
			ys[i] = gy
		end
	end

	local i = 1
	while i <= n do
		local gy = ys[i]
		if not gy then i += 1; continue end
		local j, sum, cnt = i, 0, 0
		while j <= n do
			local y2 = ys[j]
			if not y2 or math.abs(y2 - gy) > 0.35 then break end
			sum += y2; cnt += 1; j += 1
		end
		local y = sum / cnt
		local a = wp0:Lerp(wp1, (i - 1) / n)
		local b = wp0:Lerp(wp1, (j - 1) / n)
		local segLen = (b - a).Magnitude + 0.15
		-- part extends 0.8 below ground so steps between slices show no gaps
		local cy = y + cfg.height / 2 - 0.4
		local mid = a:Lerp(b, 0.5)
		newPart(parent, "Fence", Vector3.new(cfg.thickness, cfg.height + 0.8, segLen), CFrame.lookAt(Vector3.new(mid.X, cy, mid.Z), Vector3.new(b.X, cy, b.Z)), cfg.color, cfg.material)
		if cfg.rail then
			local ry = y + cfg.height - 0.15
			newPart(parent, "FenceRail", Vector3.new(cfg.thickness + 0.16, 0.22, segLen), CFrame.lookAt(Vector3.new(mid.X, ry, mid.Z), Vector3.new(b.X, ry, b.Z)), cfg.color, cfg.material)
		end
		i = j
	end

	if cfg.post then
		local h = cfg.height + 0.3
		for _, p in { wp0, wp1 } do
			local gy = terrainY(p.X, p.Z, baseY)
			if math.abs(gy - baseY) <= 4.5 and not onRoad(p.X, gy, p.Z) then
				newPart(parent, "FencePost", Vector3.new(cfg.postSize, h + 0.6, cfg.postSize), CFrame.new(p.X, gy + h / 2 - 0.3, p.Z), cfg.postColor, cfg.material)
			end
		end
	end
end

-- Front fence run along X at fixed z, skipping the path + driveway gates.
local function fenceFront(parent: Instance, pivot: CFrame, baseY: number, x0: number, x1: number, z: number, gaps: { { number } }, cfg: any)
	table.sort(gaps, function(a, b) return a[1] < b[1] end)
	local cursor = x0
	for _, g in gaps do
		local gs = math.max(x0, g[1])
		local ge = math.min(x1, g[2])
		if gs > cursor then fenceWall(parent, pivot, baseY, cursor, z, gs, z, cfg) end
		if ge > cursor then cursor = ge end
	end
	if cursor < x1 then fenceWall(parent, pivot, baseY, cursor, z, x1, z, cfg) end
end

local function buildFence(parent: Instance, pivot: CFrame, footHalfW: number, footHalfD: number, baseY: number, cfg: any, driveX: number, driveHalf: number?, doorX: number?, layout: string?, houseHalfD: number?)
	local fw = footHalfW - Config.FENCE_INSET
	local fz = footHalfD - Config.FENCE_INSET
	local gates = Config.GATE_HALF
	local dHalf = driveHalf or gates.drive
	local dx = doorX or 0
	local mode = layout or "full"
	if mode == "none" then return end
	local hhd = houseHalfD or 0
	-- Back fence always encloses the rear.
	fenceWall(parent, pivot, baseY, -fw, -fz, fw, -fz, cfg)
	if mode == "backyard" then
		-- Only the backyard is fenced; the front yard is open to the street.
		local zStop = -hhd
		fenceWall(parent, pivot, baseY, -fw, -fz, -fw, zStop, cfg)
		fenceWall(parent, pivot, baseY, fw, -fz, fw, zStop, cfg)
	elseif mode == "shortSides" then
		-- Sides stop just past mid-lot; the whole front half stays open.
		local zStop = fz * 0.1
		fenceWall(parent, pivot, baseY, -fw, -fz, -fw, zStop, cfg)
		fenceWall(parent, pivot, baseY, fw, -fz, fw, zStop, cfg)
	elseif mode == "notch" then
		-- One side steps inward partway back so the plan isn't a pure rectangle.
		-- The notch goes on the side away from the driveway so it never eats the drive.
		local ns = if driveX >= 0 then -1 else 1
		local inset = math.min(4.5 * WS, fw * 0.4)
		local jogZ = fz * 0.2
		local xs = ns * fw
		local xi = ns * (fw - inset)
		fenceWall(parent, pivot, baseY, -ns * fw, -fz, -ns * fw, fz, cfg)
		fenceWall(parent, pivot, baseY, xs, -fz, xs, jogZ, cfg)
		fenceWall(parent, pivot, baseY, xs, jogZ, xi, jogZ, cfg)
		fenceWall(parent, pivot, baseY, xi, jogZ, xi, fz, cfg)
		local gaps = { { dx - gates.path, dx + gates.path }, { driveX - dHalf, driveX + dHalf } }
		local xL = if ns < 0 then xi else -fw
		local xR = if ns > 0 then xi else fw
		fenceFront(parent, pivot, baseY, math.min(xL, xR), math.max(xL, xR), fz, gaps, cfg)
	else
		fenceWall(parent, pivot, baseY, -fw, -fz, -fw, fz, cfg)
		fenceWall(parent, pivot, baseY, fw, -fz, fw, fz, cfg)
		if mode == "full" then
			local gaps = { { dx - gates.path, dx + gates.path }, { driveX - dHalf, driveX + dHalf } }
			fenceFront(parent, pivot, baseY, -fw, fw, fz, gaps, cfg)
		end
	end
end

local function addFoundationSkirt(parent: Instance, pivot: CFrame, model: Model, baseY: number)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local any = false
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local role = p:GetAttribute("PaintRole")
			if role == "Wall" or p.Name == "Foundation" then
				any = true
				local lp = pivot:PointToObjectSpace(p.Position)
				local hx, hz = p.Size.X * 0.5, p.Size.Z * 0.5
				minX = math.min(minX, lp.X - hx); maxX = math.max(maxX, lp.X + hx)
				minZ = math.min(minZ, lp.Z - hz); maxZ = math.max(maxZ, lp.Z + hz)
			end
		end
	end
	if not any then return end
	local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
	local sx, sz = (maxX - minX) - 0.4, (maxZ - minZ) - 0.4
	if sx < 1 or sz < 1 then return end
	local h = 10 -- deep enough to reach ground on a pad-shoulder downhill side
	-- The skirt is UNDERGROUND fill for a downhill shoulder, so its top sits just
	-- below the footway plane. At +0.1 it stood proud of the paving as a dark
	-- slab across the back of every house. Paving colour for the same reason:
	-- where a slope does expose it, it should read as more of the same concrete.
	local skirt = newPart(parent, "FoundationSkirt", Vector3.new(sx, h, sz), pivot * CFrame.new(cx, -h / 2 - 0.05, cz), PAVE_COLOR, PAVE_MATERIAL)
	skirt.MaterialVariant = RoadConstants.PAVE_VARIANT
end

-- ============================================================================
-- Greenery from the Nature kit (low part count, no shadow casters). Placed by
-- placeGarden into PRESET slots, each weighing a few options (a plant, or
-- something else, or nothing) so gardens read deliberate, not scattered.
-- ============================================================================
local function jitr(rng: Random, a: number): number
	return (rng:NextNumber() * 2 - 1) * a
end

-- Real vegetation from the ReplicatedStorage.Nature kit: MeshPart trees and shrubs that
-- already carry their leaf colour on a SurfaceAppearance, so a plain clone looks right.
-- Dressing runs in PLACED world space, so they go in at their AUTHORED scale -- no
-- BUILDING_SCALE correction (CommercialBuilder needs one only because it authors
-- full-size templates that are ScaleTo()d later).
--
-- The whole broadleaf/conifer kit, not the three small species. Authored crowns run 8.7
-- (Elder) to 30 (Chestnut) studs. They go in at that AUTHORED size: a lot tree has to read
-- as exactly the tree a player plants beside it, and shrinking them to fit the frontage is
-- what made the old streets look like a model village. maxSpread still exists for a caller
-- that needs a ceiling -- residential no longer passes one.
local NATURE_TREES = {
	"ElderTree", "BirchTree", "BroadleafTree", "PoplarTree",
	"OakTree", "ChestnutTree", "PineTree", "SpruceTree",
}
local NATURE_SHRUBS = {
	"BushRound", "BushLow", "BushWild", "BerryBush",
	"FlowerBush", "FlowerBushPink", "FlowerBushYellow", "HedgeSphere",
}

local _natureRoot: Folder? = nil
local function natureFolder(): Folder?
	if _natureRoot then return _natureRoot end
	local f = game:GetService("ReplicatedStorage"):FindFirstChild("Nature")
	if f and f:IsA("Folder") then _natureRoot = f :: Folder end
	return _natureRoot
end

-- One kit plant seated on the ground at local (lx, lz). Silent no-op when the kit is
-- missing -- a lot with no shrub beats a boot-time hard failure in cosmetic dressing.
local function naturePlant(parent: Instance, pivot: CFrame, lx: number, lz: number, y: number, names: { string }, rng: Random, maxSpread: number?)
	local root = natureFolder()
	local src = root and root:FindFirstChild(names[rng:NextInteger(1, #names)])
	if not src or not src:IsA("Model") then return end
	local c = (src :: Model):Clone()
	-- ScaleTo is ABSOLUTE, so multiply the authored scale rather than replacing it.
	c:ScaleTo(c:GetScale() * (0.85 + rng:NextNumber() * 0.3))
	local box, sz = c:GetBoundingBox()
	-- Size the plant to the LOT, not to whatever the artist authored: crowns in this kit run
	-- 8.7 to 30 studs and a house frontage is 21-53, so an oak at its authored scale swallowed
	-- the house behind it. Shrink to fit, never grow -- an elder stays an elder.
	if maxSpread and maxSpread > 0 then
		local spread = math.max(sz.X, sz.Z)
		if spread > maxSpread then
			c:ScaleTo(c:GetScale() * (maxSpread / spread))
			box, sz = c:GetBoundingBox()
		end
	end
	local dy = (box.Position.Y - sz.Y * 0.5) - c:GetPivot().Position.Y
	c:PivotTo(pivot * CFrame.new(lx, y - dy, lz) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0))
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			-- Same reason as propAt: yard greenery repeats on every lot and its shadows
			-- re-cost on every camera turn for nothing visible at city view.
			d.CastShadow = false
		end
	end
	c.Parent = parent
end

local function makeTree(parent: Instance, pivot: CFrame, lx: number, lz: number, y: number, rng: Random, spread: number?)
	naturePlant(parent, pivot, lx, lz, y, NATURE_TREES, rng, spread)
end

local function makeBush(parent: Instance, pivot: CFrame, lx: number, lz: number, y: number, rng: Random, spread: number?)
	-- Shrubs read as underplanting, so they take a third of whatever a tree gets here.
	local bushSpread = if spread then math.max(2, spread * 0.34) else nil
	naturePlant(parent, pivot, lx, lz, y, NATURE_SHRUBS, rng, bushSpread)
	if rng:NextNumber() < 0.5 then
		naturePlant(parent, pivot, lx + 2.6 * WS, lz + jitr(rng, 1.2 * WS), y, NATURE_SHRUBS, rng, bushSpread)
	end
end

type GardenOption = { w: number, fn: ((Instance, CFrame, number, number, number, Random, number?) -> ())? }
local function pickWeighted(rng: Random, options: { GardenOption }): GardenOption
	local total = 0
	for _, o in options do total += o.w end
	local r = rng:NextNumber() * total
	for _, o in options do
		r -= o.w
		if r <= 0 then return o end
	end
	return options[#options]
end

-- ============================================================================
-- The back garden, from the imported kit. SLOTS, not scatter: one patio centre,
-- one cooking piece beside it, a shed in a back corner, then a short packed
-- list of extras -- so two neighbours share a vocabulary without ever landing
-- on the same arrangement.
-- ============================================================================
-- The back garden is laid out by SLOT, not scattered: a strip against the house
-- for the patio and the barbecue, the middle of the lawn for a fire pit, the two
-- rear corners for a shed or a washing line, and the side edges for beds. A
-- keep-out rect in front of the back door is reserved before anything is placed,
-- so nothing ever blocks the way out.
type Yard = { placed: { Rect }, xMin: number, xMax: number, zMin: number, zMax: number }

-- How far inside the lot line props must stay: past the fence, whatever kind it
-- is. A hedge is two studs thick and a picket panel a fraction of that, so this
-- is measured off the boundary actually chosen rather than a fixed literal.
local function boundaryMargin(cfg: any): number
	local t = if cfg.panel then select(2, propHalf(cfg.panel)) * 2 else (cfg.thickness or 0)
	return Config.FENCE_INSET + t * 0.5 + 0.6 * WS
end

local function yardFor(footHalfW: number, footHalfD: number, backDist: number, margin: number): Yard?
	local xMin, xMax = -(footHalfW - margin), footHalfW - margin
	-- zMin is the rear lot edge, zMax the back wall of the house.
	local zMin, zMax = -(footHalfD - margin), -(backDist + 0.6)
	if xMax - xMin < 3 or zMax - zMin < 3 then return nil end
	return { placed = {}, xMin = xMin, xMax = xMax, zMin = zMin, zMax = zMax }
end

local function reserve(y: Yard, cx: number, cz: number, hx: number, hz: number)
	table.insert(y.placed, { cx = cx, cz = cz, hx = hx, hz = hz })
end

-- Try to stand `name` at (cx, cz). Returns false when it will not fit clear of
-- what is already down, so a caller can fall through to its next choice.
local function placeAt(parent: Instance, y: Yard, pivot: CFrame, baseY: number, name: string, cx: number, cz: number, yaw: number): boolean
	local hx, hz = propHalf(name)
	if hx <= 0 then return false end
	if yaw ~= 0 then hx, hz = hz, hx end
	-- Pull the spot inside the yard rather than rejecting it outright: a slot
	-- aimed at a corner should still land when the prop is big for the garden.
	if hx * 2 > y.xMax - y.xMin or hz * 2 > y.zMax - y.zMin then return false end
	cx = math.clamp(cx, y.xMin + hx, y.xMax - hx)
	cz = math.clamp(cz, y.zMin + hz, y.zMax - hz)

	local rect: Rect = { cx = cx, cz = cz, hx = hx + 0.3, hz = hz + 0.3 }
	for _, q in y.placed do
		if rectsOverlap(rect, q) then return false end
	end

	local wp = (pivot * CFrame.new(cx, 0, cz)).Position
	local gy = terrainY(wp.X, wp.Z, baseY)
	if math.abs(gy - baseY) > 3 then return false end
	propAt(parent, name, seatCF(pivot, cx, cz, yaw, gy))
	table.insert(y.placed, rect)
	return true
end

-- Roll a list, then try each slot in order until one takes it.
local function trySlots(parent: Instance, y: Yard, pivot: CFrame, baseY: number, list: { string }, rng: Random, slots: { { number } }): boolean
	local name = pickKit(list, rng)
	if not name then return false end
	for _, sl in slots do
		if placeAt(parent, y, pivot, baseY, name, sl[1], sl[2], sl[3]) then return true end
	end
	return false
end

local function dressBackGarden(parent: Instance, pivot: CFrame, footHalfW: number, footHalfD: number, backDist: number, baseY: number, rng: Random, margin: number): Yard?
	local y = yardFor(footHalfW, footHalfD, backDist, margin)
	if not y then return nil end

	local midZ = (y.zMin + y.zMax) * 0.5
	local nearZ = y.zMax -- against the house
	local farZ = y.zMin  -- rear lot edge

	-- The way out of the back door stays clear, always.
	reserve(y, 0, nearZ - 2.2 * WS, 2.6 * WS, 2.4 * WS)

	-- Patio against the house, to one side of the door; barbecue beside it.
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local patioX = side * (y.xMax * 0.52)
	if rng:NextNumber() < 0.8 then
		trySlots(parent, y, pivot, baseY, BACK_PATIO, rng, {
			{ patioX, nearZ - 2.6 * WS, 0 },
			{ -patioX, nearZ - 2.6 * WS, 0 },
		})
	end
	if rng:NextNumber() < 0.6 then
		trySlots(parent, y, pivot, baseY, BACK_COOK, rng, {
			{ side * (y.xMax * 0.88), nearZ - 2.2 * WS, 0 },
			{ -side * (y.xMax * 0.88), nearZ - 2.2 * WS, 0 },
		})
	end

	-- A fire pit belongs in the MIDDLE of the lawn, nowhere else.
	if rng:NextNumber() < 0.35 then
		trySlots(parent, y, pivot, baseY, BACK_CENTRE, rng, { { 0, midZ, 0 } })
	end

	-- Rear corners: shed, washing line, water butt.
	local corners = {
		{ y.xMin, farZ, 0 },
		{ y.xMax, farZ, 0 },
	}
	if rng:NextNumber() < 0.5 then
		trySlots(parent, y, pivot, baseY, BACK_CORNER, rng, corners)
	end
	if rng:NextNumber() < 0.3 then
		trySlots(parent, y, pivot, baseY, BACK_CORNER, rng, { corners[2], corners[1] })
	end

	-- Play gear goes down the far end, clear of the door corridor.
	if rng:NextNumber() < 0.42 then
		trySlots(parent, y, pivot, baseY, BACK_PLAY, rng, {
			{ -side * (y.xMax * 0.5), farZ + 2.5 * WS, 0 },
			{ side * (y.xMax * 0.5), farZ + 2.5 * WS, 0 },
			{ 0, farZ + 2.5 * WS, 0 },
		})
	end

	-- Beds and pots line the side edges.
	for i = 1, rng:NextInteger(1, 3) do
		local sx = if i % 2 == 1 then -1 else 1
		trySlots(parent, y, pivot, baseY, BACK_EDGE, rng, {
			{ sx * y.xMax, midZ + rng:NextNumber(-0.3, 0.3) * (y.zMax - y.zMin), math.pi / 2 },
			{ -sx * y.xMax, midZ + rng:NextNumber(-0.3, 0.3) * (y.zMax - y.zMin), math.pi / 2 },
		})
	end
	return y
end

-- Front-of-house kit dressing: path lights, pots by the door, a number plate on
-- the front wall, and the odd flagpole or hoop. All keyed off the door and the
-- drive, so nothing lands in the way of either.
--
-- `grassX` answers "is this spot lawn?" -- a garden light staked through a
-- concrete drive looks like a bug, because it is one.
local function dressFront(parent: Instance, pivot: CFrame, footHalfW: number, frontFaceZ: number, sidewalkEnd: number, doorX: number, driveX: number, driveHalf: number, hasDrive: boolean, paved: boolean, baseY: number, rng: Random)
	local function seatAt(name: string, lx: number, lz: number, yaw: number)
		local wp = (pivot * CFrame.new(lx, 0, lz)).Position
		propAt(parent, name, seatCF(pivot, lx, lz, yaw, terrainY(wp.X, wp.Z, baseY)))
	end

	-- Lawn test: off the path, off the drive, inside the lot. `paved` kills it
	-- outright -- those lots have concrete kerb to house, so there is no lawn.
	local pathHalf = Config.PATH.width * 0.5
	local function grassX(lx: number): boolean
		if paved then return false end
		if math.abs(lx - doorX) < pathHalf + 0.5 then return false end
		if hasDrive and math.abs(lx - driveX) < driveHalf + 0.5 then return false end
		return math.abs(lx) <= footHalfW - 1
	end

	local pathLen = sidewalkEnd - frontFaceZ
	if pathLen > 4 * WS and rng:NextNumber() < 0.5 and _kit.PathLight_Garden then
		for _, sx in { -1, 1 } do
			local lx = doorX + sx * (pathHalf + 1.1 * WS)
			if grassX(lx) then
				seatAt("PathLight_Garden", lx, frontFaceZ + pathLen * 0.55, 0)
			end
		end
	end

	-- Pots are GARDEN furniture: on the lawn beside the door, never parked on the
	-- walkway itself, where one reads as a bollard someone left in the doorway.
	if rng:NextNumber() < 0.55 then
		local pot = pickKit(FRONT_POT, rng)
		if pot then
			for _, sx in { -1, 1 } do
				local lx = doorX + sx * (pathHalf + 1.0 * WS)
				if grassX(lx) then
					seatAt(pot, lx, frontFaceZ + 1.1 * WS, 0)
					break
				end
			end
		end
	end

	-- The number plate belongs ON the front of the house, beside the door and
	-- facing the street -- not staked out in the middle of the front garden.
	if rng:NextNumber() < 0.5 and _kit.HouseNumber_Plaque then
		local sx = if doorX <= 0 then 1 else -1
		local px = math.clamp(doorX + sx * 1.9 * WS, -(footHalfW - 1), footHalfW - 1)
		seatAt("HouseNumber_Plaque", px, frontFaceZ + 0.12, 0)
	end

	if hasDrive and rng:NextNumber() < 0.18 and _kit.Driveway_BasketballHoop then
		local hx = math.clamp(driveX + driveHalf + 0.8 * WS, -(footHalfW - 1.5), footHalfW - 1.5)
		seatAt("Driveway_BasketballHoop", hx, frontFaceZ + 2.5 * WS, math.pi)
	end

	if rng:NextNumber() < 0.07 and _kit.Flagpole then
		local fx = (if driveX < 0 then 1 else -1) * (footHalfW - 2 * WS)
		if grassX(fx) then seatAt("Flagpole", fx, (frontFaceZ + sidewalkEnd) * 0.5, 0) end
	end
end

-- Downpipes at the front corners of the house. Gutters are deliberately NOT
-- run: a continuous eave needs the eave line, and a lot cannot afford ~20 more
-- parts for a detail nobody reads at city view.
-- ponytail: corners only. Ceiling -- if an eave line ever gets baked as an
-- attribute, Gutter_Section is already in the kit and tiles at 4.8 studs.
local function dressDownpipes(parent: Instance, pivot: CFrame, houseHalfW: number, frontFaceZ: number, baseY: number, rng: Random)
	if rng:NextNumber() > 0.5 or not _kit.Downpipe then return end
	for _, sx in { -1, 1 } do
		if rng:NextNumber() < 0.8 then
			local lx, lz = sx * (houseHalfW - 0.15), frontFaceZ - 0.3
			local wp = (pivot * CFrame.new(lx, 0, lz)).Position
			propAt(parent, "Downpipe", seatCF(pivot, lx, lz, 0, terrainY(wp.X, wp.Z, baseY)))
		end
	end
end

-- Preset garden slots for the NATURE kit: back-corner + front-yard slots that
-- each weigh tree / bush / nothing, so the city stays green while staying lean.
-- Plants go in at their AUTHORED size -- a tree on a lot should read exactly as
-- the one a player plants beside it, which is why no maxSpread is passed.
--
-- The back slots book their footprint in the SAME occupancy the kit props use,
-- so a tree stops landing on top of the swing set. The reserved radius is the
-- planting space, not the canopy: crowns are allowed to overhang a shed, they
-- are just not allowed to grow through one.
local PLANT_HALF = { tree = 5.5, bush = 2.2 }

local function plantFree(y: Yard?, cx: number, cz: number, half: number): boolean
	if not y then return true end
	local rect: Rect = { cx = cx, cz = cz, hx = half, hz = half }
	for _, q in y.placed do
		if rectsOverlap(rect, q) then return false end
	end
	table.insert(y.placed, rect)
	return true
end

local function placeGarden(parent: Instance, pivot: CFrame, footHalfW: number, footHalfD: number, frontFaceZ: number, backDist: number, doorX: number, driveX: number, driveHalf: number, baseY: number, rng: Random, y: Yard?)
	local backEdge = -(footHalfD - 2.5 * WS)
	for _, sx in { -1, 1 } do
		local opt = pickWeighted(rng, { { w = 3, fn = makeTree }, { w = 3, fn = makeBush }, { w = 2, fn = nil } })
		if opt.fn then
			local lx, lz = sx * (footHalfW - 3 * WS), backEdge + 2 * WS
			local half = (if opt.fn == makeTree then PLANT_HALF.tree else PLANT_HALF.bush) * WS
			if plantFree(y, lx, lz, half) then
				-- On the ground where it stands: a house's yard keeps the lie of the land.
				local wp = (pivot * CFrame.new(lx, 0, lz)).Position
				opt.fn(parent, pivot, lx, lz, terrainY(wp.X, wp.Z, baseY) - pivot.Position.Y, rng, nil)
			end
		end
	end
end

-- ============================================================================
-- LOW residential (level 1). Medium density, high density and row houses will
-- each want their own pass: this one assumes a detached house on its own plot
-- with a back garden, which is all the level-1 stock contains.
-- ============================================================================

local function dressResidential(model: Model, pivot: CFrame, w: number, d: number, plotW: number?)
	local seed = math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1)
	local rng = Random.new(seed)

	recolor(model, rng)

	-- fitLots ROUNDS a plot frontage to lot units, so w * LOT can claim up to half
	-- a lot unit of the neighbour's ground. Everything here measures the narrower
	-- of the two, which is why paving stopped spilling over the property line.
	local footHalfW = math.min(w * LOT, plotW or math.huge) * 0.5
	local footHalfD = d * LOT * 0.5
	local baseY = pivot.Position.Y

	local yard = Instance.new("Folder")
	yard.Name = "Yard"
	yard.Parent = model

	local attrHalfW = tonumber(model:GetAttribute("HouseHalfWidth"))
	local houseHalfW = if attrHalfW then attrHalfW else (footHalfW - 2 * WS)
	local attrHalfD = tonumber(model:GetAttribute("HouseHalfDepth"))
	local houseHalfD = if attrHalfD then attrHalfD else (footHalfD - 5 * WS)
	-- Real front + back faces (footprint-centre coords) so the dressing follows an
	-- off-centre house; fall back to the symmetric half-depth.
	local attrFrontZ = tonumber(model:GetAttribute("HouseFrontZ"))
	local frontFaceZ = if attrFrontZ then attrFrontZ else houseHalfD
	local attrBackZ = tonumber(model:GetAttribute("HouseBackZ"))
	local backDist = -(if attrBackZ then attrBackZ else -houseHalfD)
	local ridgeY = tonumber(model:GetAttribute("RidgeY")) or 12 * WS

	local sidewalkEnd = accessEnds(pivot, footHalfD, baseY)

	-- HasParking gates off-street parking: garages/carports and baked side pads get
	-- a drive; other new stock street-parks. Old templates (nil) keep one.
	local hasParkingAttr = model:GetAttribute("HasParking")
	local hasParking = if hasParkingAttr == nil then true else hasParkingAttr == true
	local doorX = tonumber(model:GetAttribute("DoorX")) or 0

	-- Paving style. A real low-density street runs from a plot with nothing but
	-- grass to one concreted kerb to kerb, and that spread is most of what stops a
	-- row reading as one house stamped N times. A garage always gets its drive.
	local pr = rng:NextNumber()
	local pave = if pr < 0.14 then "none"
		elseif pr < 0.38 then "path"
		elseif pr < 0.72 then "drive"
		elseif pr < 0.90 then "front"
		else "full"
	if hasParking and (pave == "none" or pave == "path") then pave = "drive" end
	local hasDrive = pave == "drive" or pave == "front" or pave == "full"

	local attrGarageX = tonumber(model:GetAttribute("GarageDriveX"))
	local garageDriveX = if attrGarageX then attrGarageX else nil
	local attrGarageW = tonumber(model:GetAttribute("GarageWidth"))
	local garageWidth = if attrGarageW then attrGarageW else Config.DRIVE.width
	local attrGarageZ = tonumber(model:GetAttribute("GarageFrontZ"))
	local garageFrontZ = if attrGarageZ then attrGarageZ else nil
	local driveX, driveW, driveEndZ
	-- Parking pads bake the same Garage* attrs a garage would, so any template
	-- carrying GarageDriveX routes its drive to the real pad, never a random strip.
	if garageDriveX then
		driveX = garageDriveX
		driveW = garageWidth + 0.8
		driveEndZ = (garageFrontZ or frontFaceZ) + 0.6
	else
		local driveSide = if rng:NextNumber() < 0.5 then -1 else 1
		driveX = driveSide * (footHalfW - Config.DRIVE.width * 0.5 - 0.6)
		driveW = Config.DRIVE.width
		driveEndZ = frontFaceZ + 0.4
	end
	if not hasDrive then driveX = doorX end

	local padY = baseY - pivot.Position.Y

	-- Paving, each piece ONE mesh lying on the yard and running out to the road's drawn edge -- the
	-- footway's back, or the asphalt where there is none -- with no step on a hill or round a bend
	-- (LotGroundMesh): a drive from the garage (or parking pad), rising to the garage floor, and a
	-- path from the door. A "front" lot paves its whole front yard, a "full" one the sides of the
	-- house too; both fill out of their sides toward a road or the next lot (sidePatches).
	local lotFrame = pivot * CFrame.new(0, DRIVE_LIFT, 0)
	local paveBack = if pave == "full" then -backDist elseif pave == "front" then frontFaceZ - 0.3 else nil
	if paveBack then
		lotMesh(yard, { frame = lotFrame, x0 = -footHalfW, x1 = footHalfW, zFront = footHalfD, zBack = paveBack, trap = true,
			soft = if pave == "full" then "blr" else "lr", color = PAVE_TINT })
		sidePatches(yard, lotFrame, footHalfW, paveBack, footHalfD)
		local r = _lots[model]
		if r then r.fills = true end
	end
	if hasDrive then
		local floorY = if model:GetAttribute("HasGarage") == true
			then (tonumber(model:GetAttribute("FloorStep")) or 0.6 * WS) - 0.08
			else DRIVE_LIFT
		lotMesh(yard, {
			frame = lotFrame, x0 = driveX - driveW * 0.5, x1 = driveX + driveW * 0.5, zFront = footHalfD, zBack = driveEndZ,
			yBack = math.max(floorY, DRIVE_LIFT) - DRIVE_LIFT, soft = "lr", color = PAVE_TINT,
		})
	end
	local pathW = Config.PATH.width
	if not paveBack and (not hasDrive or math.abs(doorX - driveX) > (driveW + pathW) * 0.5) then
		lotMesh(yard, { frame = lotFrame, x0 = doorX - pathW * 0.5, x1 = doorX + pathW * 0.5, zFront = footHalfD, zBack = frontFaceZ - 0.3, soft = "lr", color = PAVE_TINT })
	end

	-- Home parking spot (the household car parks here, facing the road). Centred on
	-- the usable drive, so a car's rear never ends up inside the house wall.
	if hasDrive and model.PrimaryPart then
		local parkZ = (driveEndZ + sidewalkEnd) * 0.5
		local sPos = (pivot * CFrame.new(driveX, padY + 0.6 * WS, parkZ)).Position
		local sAhead = (pivot * CFrame.new(driveX, padY + 0.6 * WS, parkZ + 3.4 * WS)).Position
		local att = Instance.new("Attachment")
		att.Name = "HomePark"
		att.Parent = model.PrimaryPart
		att.WorldCFrame = CFrame.lookAt(sPos, sAhead)
	end

	-- Most lots carry NO boundary: a suburban street reads as one continuous lawn,
	-- and a fence on every plot turns the row into a run of pens.
	local fr = rng:NextNumber()
	local fenceLayout = if fr < 0.46 then "none"
		elseif fr < 0.80 then "backyard"
		elseif fr < 0.93 then "open"
		else "full"
	local fenceCfg = pickFenceKind(rng)
	buildFence(yard, pivot, footHalfW, footHalfD, baseY, fenceCfg, driveX,
		if hasDrive then driveW * 0.5 + 0.4 else Config.GATE_HALF.path, doorX, fenceLayout, backDist)
	-- Props stay inside whatever boundary was just built; a hedge is two studs
	-- thick and a picket panel a fraction of that, so the clearance is measured
	-- off the real one instead of a literal.
	local yardMargin = if fenceLayout == "none" then 1.2 * WS else boundaryMargin(fenceCfg)

	addFoundationSkirt(yard, pivot, model, baseY)
	dressRoof(yard, model, pivot, houseHalfW, ridgeY, rng)
	dressDownpipes(yard, pivot, houseHalfW, frontFaceZ, baseY, rng)
	-- A paved front yard gets no lawn dressing.
	dressFront(yard, pivot, footHalfW, frontFaceZ, sidewalkEnd, doorX, driveX, driveW * 0.5, hasDrive, paveBack ~= nil, baseY, rng)
	-- The yard comes back carrying what it already stood up, so the greenery below plants
	-- AROUND the shed and the swing set instead of through them.
	local yardRects = dressBackGarden(yard, pivot, footHalfW, footHalfD, backDist, baseY, rng, yardMargin)
	local gardenClear = if hasDrive then driveW * 0.5 else Config.PATH.width * 0.5
	placeGarden(yard, pivot, footHalfW, footHalfD, frontFaceZ, backDist, doorX, driveX, gardenClear, baseY, rng, yardRects)
end

local function recolorCommercial(model: Model, rng: Random)
	-- Builders author each business type's brand colours; only nudge the wall hue a
	-- touch per placement so two of the same type next door aren't pixel-identical.
	-- A mesh template carries its colour on the SurfaceAppearance, where paint() writes.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("PaintRole") == "Wall" then
			local sa = d:FindFirstChildWhichIsA("SurfaceAppearance")
			paint(d, jitter(if sa then sa.Color else d.Color, rng))
		end
	end
end

-- Low-commercial templates carry three authored prop layouts (lamps, bollards, benches, bins,
-- trees, the hedge line) as SiteLayouts JSON: { {prop, x, y, z, yawDeg} } in template studs.
-- Each lot shows one, fixed by its position. The template origin is FootprintAnchor's base.
local function dressSite(model: Model, parent: Instance, seed: number)
	local json = model:GetAttribute("SiteLayouts")
	local anchor = model:FindFirstChild("FootprintAnchor")
	if typeof(json) ~= "string" or not (anchor and anchor:IsA("BasePart")) then return end
	local layouts = HttpService:JSONDecode(json)
	local origin = anchor.CFrame * CFrame.new(0, -anchor.Size.Y * 0.5, 0)
	for _, e in layouts[Random.new(seed):NextInteger(1, #layouts)] do
		local src = _siteKit[e[1]]
		if not src then
			if not _missingSiteProp[e[1]] then
				_missingSiteProp[e[1]] = true
				warn("[LotDressingService] site prop missing from the kits: " .. tostring(e[1]))
			end
			continue
		end
		local c = src:Clone()
		c:PivotTo(origin * CFrame.new(e[2], e[3], e[4]) * CFrame.Angles(0, math.rad(e[5]), 0))
		tintPlaced(c)
		for _, p in c:GetDescendants() do
			if p:IsA("BasePart") then
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
			end
		end
		c.Parent = parent
	end
end

local function parkedCar(parent: Instance, pivot: CFrame, lx: number, lz: number, baseY: number, color: Color3)
	local cf = pivot * CFrame.new(lx, baseY - pivot.Position.Y + 0.6 * WS, lz)
	local body = newPart(parent, "ParkedCar", Vector3.new(2.2, 1.0, 4.4) * WS, cf, color, Enum.Material.SmoothPlastic)
	newPart(parent, "ParkedCarTop", Vector3.new(1.8, 0.7, 2.1) * WS, cf * CFrame.new(0, 0.85 * WS, -0.2 * WS), color:Lerp(Color3.fromRGB(20, 20, 25), 0.35), Enum.Material.SmoothPlastic)
end

-- ============================================================================
-- Parking lots with baked drive-in / drive-out routes.
-- Routing markers (Attachments on an invisible ParkMarkers part, so they move
-- with the placed model) define WORLD-space points:
--   LotEntry : road-side driveway mouth -- the road-graph hand-off point
--   LotFront : just inside the lot front edge
--   AisleHub : centre of the drive aisle
--   S<i>     : stall i's park CFrame (faces the aisle, ready to pull out)
--   S<i>_a   : the aisle waypoint in front of stall i
-- BuildingService.getParkSpots reads these into per-stall in-lot routes;
-- CitizenService stitches them onto the road path so a car drives the whole way
-- in, parks, and reverses the route back out on departure.
-- ============================================================================
local STALL_W, STALL_D, AISLE_W, ENTRY_HALF = 7.5 * WS, 13 * WS, 11 * WS, 4.5 * WS

local function makeMarkers(parent: Instance, pivot: CFrame): BasePart
	local m = Instance.new("Part")
	m.Name = "ParkMarkers"; m.Size = Vector3.new(0.4, 0.4, 0.4); m.CFrame = pivot
	m.Anchored = true; m.CanCollide = false; m.CanTouch = false; m.CanQuery = false
	m.Transparency = 1; m.Parent = parent
	return m
end

local function marker(host: BasePart, pivot: CFrame, name: string, lx: number, lz: number, faceLx: number?, faceLz: number?)
	local att = Instance.new("Attachment")
	att.Name = name; att.Parent = host
	local wp = (pivot * CFrame.new(lx, 0.6, lz)).Position
	if faceLx then
		local fp = (pivot * CFrame.new(faceLx, 0.6, faceLz :: number)).Position
		att.WorldCFrame = CFrame.lookAt(wp, fp)
	else
		att.WorldCFrame = CFrame.new(wp)
	end
end

-- Perpendicular-stall lot between backZ (building side) and frontZ (road side),
-- centred in X with a clear central entry lane. Bakes routing markers. Returns
-- the stall count.
local function buildLot(parent: Instance, host: BasePart, pivot: CFrame, halfW: number, backZ: number, frontZ: number, footHalfD: number, baseY: number, slabColor: Color3, drawCorrals: boolean): number
	local P = Config.PARKING
	local y = baseY - pivot.Position.Y
	local depth = frontZ - backZ
	if depth < 10 * WS or halfW < ENTRY_HALF + STALL_W then return 0 end

	newPart(parent, "ParkingLot", Vector3.new(halfW * 2, 0.2, depth), pivot * CFrame.new(0, y + P.lift, (backZ + frontZ) / 2), slabColor, P.slabMaterial)

	local twoRows = depth >= 2 * STALL_D + AISLE_W
	local stallD = if twoRows then STALL_D else math.clamp(depth - 2 * WS, 8 * WS, STALL_D)
	local aisleZ: number
	local rows: { { z: number, face: number } } = {}
	if twoRows then
		aisleZ = (backZ + frontZ) / 2
		table.insert(rows, { z = aisleZ - AISLE_W / 2 - stallD / 2, face = 1 })
		table.insert(rows, { z = aisleZ + AISLE_W / 2 + stallD / 2, face = -1 })
	else
		local zRow = backZ + stallD / 2
		aisleZ = math.min(frontZ - 1, zRow + stallD / 2 + AISLE_W / 2)
		table.insert(rows, { z = zRow, face = 1 })
	end

	local sidewalkEnd, roadEnd = accessEnds(pivot, footHalfD, baseY)
	fillFrontPaving(parent, pivot, halfW, frontZ, sidewalkEnd, baseY, {
		thickness = 0.2, lift = P.lift, color = slabColor, material = P.slabMaterial,
	}, "ForecourtFill")
	marker(host, pivot, "LotEntry", 0, roadEnd, 0, frontZ)
	marker(host, pivot, "LotFront", 0, frontZ - 0.6, 0, aisleZ)
	marker(host, pivot, "AisleHub", 0, aisleZ, 0, backZ)

	local count = 0
	for _, row in rows do
		for _, side in { -1, 1 } do
			local cx = side * (ENTRY_HALF + STALL_W / 2)
			local minLineX, maxLineX = math.huge, -math.huge
			local rowCount = 0
			while math.abs(cx) <= halfW - STALL_W / 2 do
				count += 1
				rowCount += 1
				marker(host, pivot, "S" .. count, cx, row.z, cx, aisleZ)
				marker(host, pivot, "S" .. count .. "_a", cx, aisleZ)
				local lineX = cx - side * STALL_W / 2
				minLineX = math.min(minLineX, lineX)
				maxLineX = math.max(maxLineX, lineX)
				cx += side * STALL_W
			end

			if rowCount > 0 then
				local width = math.abs(maxLineX - minLineX) + 0.2
				local centerX = (minLineX + maxLineX) * 0.5
				local plate = newPart(
					parent,
					"StallLineTexture",
					Vector3.new(width, 0.05, stallD),
					pivot * CFrame.new(centerX, y + P.lift + 0.04, row.z),
					P.lineColor,
					Enum.Material.SmoothPlastic
				)
				plate.Transparency = 1
				plate.CanCollide = false
				plate.CanTouch = false
				plate.CanQuery = false
				plate.CastShadow = false

				local texture = Instance.new("Texture")
				texture.Name = "StallStripeTexture"
				texture.Texture = RoadConstants.PARKING_STALL_TEXTURE
				texture.Face = Enum.NormalId.Top
				texture.Color3 = P.lineColor
				texture.StudsPerTileU = STALL_W
				texture.StudsPerTileV = stallD
				texture.OffsetStudsU = -(minLineX % STALL_W)
				texture.Parent = plate
			end
		end
	end

	if drawCorrals then
		for _, sx in { -1, 1 } do
			newPart(parent, "CartCorral", Vector3.new(2.2, 1.4, 5) * WS, pivot * CFrame.new(sx * (halfW - 1.6 * WS), y + 0.7 * WS, aisleZ), Color3.fromRGB(150, 152, 158), Enum.Material.Metal)
		end
	end
	return count
end

local function dressGas(model: Model, parent: Instance, host: BasePart, pivot: CFrame, footHalfW: number, footHalfD: number, frontFaceZ: number, baseY: number)
	local frontZ = footHalfD - 0.8
	local sidewalkEnd, roadEnd = accessEnds(pivot, footHalfD, baseY)
	local apron = { width = 7 * WS, thickness = 0.25, lift = Config.PARKING.lift, color = Color3.fromRGB(82, 82, 86), material = Enum.Material.Asphalt }
	fillFrontPaving(parent, pivot, footHalfW - 0.8, frontZ, sidewalkEnd, baseY, apron, "ForecourtFill")
	marker(host, pivot, "LotEntry", 0, roadEnd, 0, frontZ)
	marker(host, pivot, "LotFront", 0, frontZ - 1, 0, frontFaceZ)
	marker(host, pivot, "AisleHub", 0, (frontFaceZ + frontZ) / 2, 0, frontFaceZ)
	local i = 0
	for _, att in model:GetDescendants() do
		if att:IsA("Attachment") and att.Name == "Pump" then
			i += 1
			local lp = pivot:PointToObjectSpace(att.WorldPosition)
			marker(host, pivot, "S" .. i, lp.X, lp.Z, lp.X, lp.Z + 5 * WS)
			marker(host, pivot, "S" .. i .. "_a", lp.X, lp.Z + 6 * WS)
		end
	end
end

local function dressDriveThru(model: Model, parent: Instance, pivot: CFrame, footHalfW: number, footHalfD: number)
	local side = tonumber(model:GetAttribute("DriveThruSide")) or 1
	local laneX = side * (footHalfW - 4 * WS)
	newPart(parent, "DriveThruLane", Vector3.new(5 * WS, 0.2, footHalfD * 0.85), pivot * CFrame.new(laneX, 0.07, -footHalfD * 0.05), Color3.fromRGB(66, 66, 70), Enum.Material.Asphalt)
	newPart(parent, "DriveThruArrow", Vector3.new(0.4 * WS, 0.22, footHalfD * 0.8), pivot * CFrame.new(laneX, 0.13, -footHalfD * 0.05), Color3.fromRGB(224, 218, 120), Enum.Material.SmoothPlastic)
end

-- Medium-density residential: a footprint-scaled parking lot in the forecourt (more
-- stalls on bigger lots) plus street trees. Uses the commercial parking machinery since
-- apartments bake the same FrontFaceZ/ParkingStyle contract.

local function dressCommercial(model: Model, pivot: CFrame, w: number, d: number)
	local seed = math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1)
	local rng = Random.new(seed)
	recolorCommercial(model, rng)

	local lot = Instance.new("Folder")
	lot.Name = "Lot"
	lot.Parent = model
	local host = makeMarkers(lot, pivot)
	dressSite(model, lot, seed + 1)

	local footHalfW = w * LOT * 0.5
	local footHalfD = d * LOT * 0.5
	local attrFrontZ = tonumber(model:GetAttribute("FrontFaceZ"))
	local frontFaceZ = if attrFrontZ then attrFrontZ else (footHalfD - 9 * WS)
	local baseY = pivot.Position.Y
	local style = tostring(model:GetAttribute("ParkingStyle") or "lot")
	local P = Config.PARKING
	local halfW = footHalfW - P.margin
	local backZ = frontFaceZ + 2.5 * WS
	local frontZ = footHalfD - 0.8
	-- Main-street shops and restaurants have no lot: their guests park on the street.
	if style == "street" then return end
	if style == "baked" then
		-- Template already baked its lot slab and stalls; the lot ground (lotGround) runs on to
		-- the road. Only the car hand-off marker at the entrance is left to place.
		local _, roadEnd = accessEnds(pivot, footHalfD, baseY)
		local ex = math.clamp((tonumber(model:GetAttribute("LotEntryX")) or 0), -footHalfW + 4 * WS, footHalfW - 4 * WS)
		marker(host, pivot, "LotEntry", ex, roadEnd, ex, footHalfD - 1)
		return
	end


	if style == "gas" then
		dressGas(model, lot, host, pivot, footHalfW, footHalfD, frontFaceZ, baseY)
	elseif style == "small" then
		buildLot(lot, host, pivot, math.min(halfW, footHalfW - 3 * WS), backZ, frontZ, footHalfD, baseY, P.slabColor, false)
	elseif style == "bigBox" then
		buildLot(lot, host, pivot, halfW, backZ, frontZ, footHalfD, baseY, P.slabColor, true)
	elseif style == "driveThru" then
		buildLot(lot, host, pivot, halfW, backZ, frontZ, baseY, P.slabColor, false)
		dressDriveThru(model, lot, pivot, footHalfW, footHalfD)
	else
		buildLot(lot, host, pivot, halfW, backZ, frontZ, baseY, P.slabColor, false)
	end
end

local function recolorIndustrial(model: Model, rng: Random)
	-- ONE nudge per placement, the same on the textured walls (SurfaceAppearance.Color) and the
	-- LOD2 walls (plain Color), so a works never changes shade when its LOD swaps.
	local amt = (rng:NextNumber() * 2 - 1) * Config.COLOR_JITTER
	local toward = if amt >= 0 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("PaintRole") == "Wall" then
			local sa = d:FindFirstChildWhichIsA("SurfaceAppearance")
			paint(d, (if sa then sa.Color else d.Color):Lerp(toward, math.abs(amt)))
		end
	end
end

-- Kit-yard industrial templates (blender/ind.py via IndustrialSetup) carry their kit props as
-- JSON { {prop, x, y, z, yawDeg, kit?} } in template studs from FootprintAnchor's base:
-- KitProps (the plant and the fixtures, always), KitRoof (the roof layout that goes with the
-- Detail_Plant BuildingService kept, PlantLayout), KitSite (one yard layout, by the lot) and
-- KitFence (the gate items of the kept fence, FenceLayout).
local function seatKit(list: { any }?, origin: CFrame, parent: Instance)
	for _, e in list or {} do
		local src = _siteKit[e[1]]
		if not src then
			if not _missingSiteProp[e[1]] then
				_missingSiteProp[e[1]] = true
				warn("[LotDressingService] kit prop missing: " .. tostring(e[1]))
			end
			continue
		end
		local c = src:Clone()
		-- e[6]: a roof prop lying on its slope (house kit v2) -- tilted about its own X after the yaw
		c:PivotTo(origin * CFrame.new(e[2], e[3], e[4]) * CFrame.Angles(0, math.rad(e[5]), 0)
			* CFrame.Angles(-math.rad(e[6] or 0), 0, 0))
		if math.abs(e[3]) < 0.05 then c:SetAttribute("OnGround", true) end
		tintPlaced(c)
		for _, p in c:GetDescendants() do
			if p:IsA("BasePart") then
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
			end
		end
		c.Parent = parent
	end
end

local function kitOrigin(model: Model): CFrame?
	local anchor = model:FindFirstChild("FootprintAnchor")
	if not (anchor and anchor:IsA("BasePart")) then return nil end
	return anchor.CFrame * CFrame.new(0, -anchor.Size.Y * 0.5, 0)
end

local function kitProps(model: Model, parent: Instance, seed: number)
	local origin = kitOrigin(model)
	if not origin then return end
	local function decode(attr: string): { any }?
		local json = model:GetAttribute(attr)
		if typeof(json) ~= "string" then return nil end
		return HttpService:JSONDecode(json)
	end
	local function seat(list: { any }?)
		seatKit(list, origin :: CFrame, parent)
	end
	local function pick(layouts: { any }?, i: number): { any }?
		if not layouts or #layouts == 0 then return nil end
		return layouts[math.clamp(i, 1, #layouts)]
	end
	seat(decode("KitProps"))
	seat(pick(decode("KitRoof"), tonumber(model:GetAttribute("PlantLayout")) or 1))
	local site = decode("KitSite")
	seat(pick(site, Random.new(seed):NextInteger(1, math.max(1, if site then #site else 1))))
	seat(pick(decode("KitFence"), tonumber(model:GetAttribute("FenceLayout")) or 1))
end

local function metalFenceCfg(): any
	for _, f in Config.FENCE do
		if f.name == "Metal" then return f end
	end
	return Config.FENCE[#Config.FENCE]
end

local function shippingContainer(parent: Instance, pivot: CFrame, lx: number, lz: number, baseY: number, yaw: number, color: Color3)
	local cf = pivot * CFrame.new(lx, baseY - pivot.Position.Y + 1.3 * WS, lz) * CFrame.Angles(0, yaw, 0)
	newPart(parent, "Container", Vector3.new(2.6, 2.6, 6.0) * WS, cf, color, Enum.Material.CorrodedMetal)
	newPart(parent, "ContainerTop", Vector3.new(2.7, 0.2, 6.1) * WS, cf * CFrame.new(0, 1.35 * WS, 0), color:Lerp(Color3.fromRGB(20, 20, 20), 0.25), Enum.Material.CorrodedMetal)
end

-- Per-placement yard clutter for baked industrial templates. Rects come from the
-- template's YardScatter attribute (full-size local coords, authored clear of the
-- garage lane, parking and baked props). rng is position-seeded, so the SAME
-- template on the SAME plot size dresses differently on every placement.
local SCATTER_CRATE_COLORS = { Color3.fromRGB(188, 158, 108), Color3.fromRGB(120, 130, 140), Color3.fromRGB(96, 118, 140) }
local SCATTER_DRUM_COLORS = { Color3.fromRGB(48, 88, 148), Color3.fromRGB(168, 52, 44), Color3.fromRGB(140, 142, 146), Color3.fromRGB(70, 110, 70) }
local SCATTER_CONTAINER_COLORS = { Color3.fromRGB(150, 60, 50), Color3.fromRGB(48, 88, 148), Color3.fromRGB(196, 120, 40), Color3.fromRGB(70, 110, 70) }

local function scatterCyl(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material)
	local p = newPart(parent, name, size, cf, color, mat)
	p.Shape = Enum.PartType.Cylinder
end

local function scatterOne(parent: Instance, pivot: CFrame, lx: number, lz: number, yb: number, yaw: number, rng: Random, roomy: boolean)
	local r = rng:NextNumber()
	local spin = CFrame.Angles(0, yaw, 0)
	if r < 0.26 then -- pallet stack
		local n = rng:NextInteger(1, 3)
		for i = 1, n do
			newPart(parent, "Pallet", Vector3.new(3.4, 0.5, 3.4) * WS, pivot * CFrame.new(lx, yb + (i - 0.5) * 0.55 * WS + 0.15, lz) * CFrame.Angles(0, yaw + rng:NextNumber(-0.15, 0.15), 0), Color3.fromRGB(150, 116, 78), Enum.Material.WoodPlanks)
		end
	elseif r < 0.5 then -- crate cluster
		for _ = 1, rng:NextInteger(2, 3) do
			local s = rng:NextNumber(2.0, 3.2) * WS
			newPart(parent, "Crate", Vector3.new(s, s * 0.9, s), pivot * CFrame.new(lx + rng:NextNumber(-1.4, 1.4) * WS, yb + s * 0.45 + 0.15, lz + rng:NextNumber(-1.4, 1.4) * WS) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0), pick(SCATTER_CRATE_COLORS, rng), Enum.Material.WoodPlanks)
		end
	elseif r < 0.68 then -- drum row
		for i = 1, rng:NextInteger(2, 4) do
			scatterCyl(parent, "Drum", Vector3.new(2.4, 1.6, 1.6) * WS, pivot * CFrame.new(lx + (i - 1) * 1.9 * WS, yb + 1.2 * WS + 0.15, lz + rng:NextNumber(-0.5, 0.5) * WS) * spin * CFrame.Angles(0, 0, math.rad(90)), pick(SCATTER_DRUM_COLORS, rng), Enum.Material.Metal)
		end
	elseif r < 0.8 then -- cable spool on its side
		for _, off in { -1.1, 1.1 } do
			scatterCyl(parent, "SpoolDisc", Vector3.new(0.5, 4.0, 4.0) * WS, pivot * CFrame.new(lx, yb + 2.0 * WS + 0.15, lz) * spin * CFrame.new(off * WS, 0, 0), Color3.fromRGB(150, 116, 78), Enum.Material.WoodPlanks)
		end
		scatterCyl(parent, "SpoolCore", Vector3.new(2.2, 2.2, 2.2) * WS, pivot * CFrame.new(lx, yb + 2.0 * WS + 0.15, lz) * spin, Color3.fromRGB(128, 84, 56), Enum.Material.Wood)
	elseif roomy and r < 0.92 then -- lone shipping container
		shippingContainer(parent, pivot, lx, lz, pivot.Position.Y, yaw, pick(SCATTER_CONTAINER_COLORS, rng))
	else -- dumpster
		local cf = pivot * CFrame.new(lx, yb + 1.3 * WS + 0.15, lz) * spin
		newPart(parent, "Dumpster", Vector3.new(5.2, 2.6, 2.8) * WS, cf, Color3.fromRGB(58, 94, 66), Enum.Material.Metal)
		newPart(parent, "DumpsterLid", Vector3.new(5.3, 0.3, 2.9) * WS, cf * CFrame.new(0, 1.45 * WS, 0) * CFrame.Angles(math.rad(-6), 0, 0), Color3.fromRGB(44, 72, 50), Enum.Material.Metal)
	end
end

local function scatterYardProps(model: Model, parent: Instance, pivot: CFrame, baseY: number, rng: Random)
	local spec = model:GetAttribute("YardScatter")
	if typeof(spec) ~= "string" or spec == "" then return end
	local yb = baseY - pivot.Position.Y
	for rectStr in string.gmatch(spec, "[^;]+") do
		local nums = {}
		for n in string.gmatch(rectStr, "[^,]+") do table.insert(nums, tonumber(n)) end
		if #nums ~= 4 then continue end
		local x0, z0, x1, z1 = nums[1] :: number, nums[2] :: number, nums[3] :: number, nums[4] :: number
		local w, d = x1 - x0, z1 - z0
		if w < 4 * WS or d < 4 * WS then continue end
		local roomy = w >= 9 * WS and d >= 15 * WS
		local count = math.clamp(math.floor(w * d / (110 * WS * WS)), 1, 5)
		for _ = 1, count do
			local lx = rng:NextNumber(x0 + 2.2 * WS, x1 - 2.2 * WS)
			local lz = rng:NextNumber(z0 + 2.2 * WS, z1 - 2.2 * WS)
			scatterOne(parent, pivot, lx, lz, yb, rng:NextNumber(0, math.pi * 2), rng, roomy)
		end
	end
end

local function dressIndustrial(model: Model, pivot: CFrame, w: number, d: number)
	local seed = math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1)
	local rng = Random.new(seed)
	recolorIndustrial(model, rng)

	local yard = Instance.new("Folder")
	yard.Name = "Yard"
	yard.Parent = model
	local host = makeMarkers(yard, pivot)
	if model:GetAttribute("KitYard") then kitProps(model, yard, seed + 1) end

	local footHalfW = w * LOT * 0.5
	local footHalfD = d * LOT * 0.5
	local attrFrontZ = tonumber(model:GetAttribute("FrontFaceZ"))
	local frontFaceZ = if attrFrontZ then attrFrontZ else (footHalfD - 11 * WS)
	local baseY = pivot.Position.Y
	local style = tostring(model:GetAttribute("ParkingStyle") or "dock")
	local Y = Config.YARD
	local frontZ = footHalfD - 0.8
	local halfW = footHalfW - Y.margin
	local slab = Color3.fromRGB(78, 78, 82)

	if style == "baked" then
		-- Template baked its own yard; the lot ground (lotGround) runs on to the road.
		local _, roadEnd = accessEnds(pivot, footHalfD, baseY)
		local ex = math.clamp((tonumber(model:GetAttribute("LotEntryX")) or 0), -footHalfW + 4 * WS, footHalfW - 4 * WS)
		marker(host, pivot, "LotEntry", ex, roadEnd, ex, footHalfD - 1)
		local mode = tostring(model:GetAttribute("FenceMode") or "full")
		if mode ~= "none" then
			local doorX = math.clamp((tonumber(model:GetAttribute("EntranceX")) or 0), -footHalfW + 2 * WS, footHalfW - 2 * WS)
			buildFence(yard, pivot, footHalfW, footHalfD, baseY, metalFenceCfg(), ex, 5 * WS, doorX, mode)
		end
		scatterYardProps(model, yard, pivot, baseY, rng)
		return
	end

	if style == "dock" then
		-- Loading apron right in front of the docks, then an employee lot in the
		-- remaining strip out to the road.
		local apronFront = math.min(frontFaceZ + 9 * WS, footHalfD - 2 * WS)
		if apronFront > frontFaceZ + 2 * WS then
			newPart(yard, "Apron", Vector3.new(halfW * 2, 0.2, apronFront - (frontFaceZ + 1)), pivot * CFrame.new(0, Y.lift, (frontFaceZ + 1 + apronFront) / 2), Y.apronColor, Y.apronMaterial)
		end
		buildLot(yard, host, pivot, halfW, apronFront + 1, frontZ, footHalfD, baseY, slab, false)
	elseif style == "small" then
		buildLot(yard, host, pivot, halfW, frontFaceZ + 1, frontZ, footHalfD, baseY, slab, false)
	else -- tank / yard: building props fill the yard, so park employees in a shallow row by the road
		buildLot(yard, host, pivot, halfW, frontZ - (STALL_D + AISLE_W), frontZ, footHalfD, baseY, slab, false)
	end

	-- Chain-link (metal) perimeter fence; the gate aligns with the central entry lane.
	buildFence(yard, pivot, footHalfW, footHalfD, baseY, metalFenceCfg(), 0)
end

-- `plotW` is the plot's REAL frontage in studs where the caller knows it
-- (BuildingService has it from PlotService). w * LOT alone overstates a plot by
-- up to half a lot unit, because PlotGeometry.fitLots rounds.
-- A mid-rise block is not a house on a lawn: no fence, no garden, no backyard props.
-- Tint it like a house, pave the forecourt kerb to front wall, and skirt the base so a
-- downhill shoulder never shows daylight under the block.
--
-- A block with a GARAGE (GarageX/GarageZ, baked from the Blender door) gets an asphalt
-- drive from a kerb cut straight to the garage door, and the same routing markers a car
-- park uses: LotEntry (road hand-off), LotFront (inside the lot edge) and GaragePark
-- (the door, facing out). Every flat has a bay inside, so CitizenService drives each
-- household's car up this drive and stows it at the door -- nothing parks on the forecourt.
-- A block without one leaves its households to street-park.
-- Window ACs on a v2 mid-rise (KitAC: every window that can take one, {x, y, z, yaw, wall}; wall
-- 1 = front, 2 = side, 3 = back / court). The user wants every placement different, so each lot
-- draws its own share per wall and its own units: mostly the sides, a few on the front.
local AC_SHARE_FRONT = table.freeze({ 0.06, 0.1, 0.14 })
local AC_SHARE_SIDE = table.freeze({ 0.3, 0.4, 0.5 })
local AC_BACK_OF_SIDE = 0.6
local AC_UNIT_A_ODDS = 2 / 3
-- Window ACs were a third of every part in the city (24k in a 719-building city) and the
-- engine pays per part drawn, hidden or not (2026-10-01 perf pass). Each lot still draws its
-- own random set; it just stops at this many.
local AC_MAX_PER_LOT = 10

local function windowACs(model: Model, parent: Instance, rng: Random)
	local json = model:GetAttribute("KitAC")
	local origin = kitOrigin(model)
	if typeof(json) ~= "string" or not origin then return end
	local side = pick(AC_SHARE_SIDE, rng)
	local share = { pick(AC_SHARE_FRONT, rng), side, side * AC_BACK_OF_SIDE }
	local list = {}
	for _, s in HttpService:JSONDecode(json) do
		if rng:NextNumber() < share[s[5]] then
			local unit = if rng:NextNumber() < AC_UNIT_A_ODDS then "Res_WindowAC_A" else "Res_WindowAC_B"
			table.insert(list, { unit, s[1], s[2], s[3], s[4] })
		end
	end
	-- Keep a random AC_MAX_PER_LOT of the picks (shuffle, trim), so the cap does not always
	-- favour the first wall listed.
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	for i = #list, AC_MAX_PER_LOT + 1, -1 do
		list[i] = nil
	end
	seatKit(list, origin, parent)
end

-- Mid-rise v2 (blender/res_mid.py via MidRiseV2Setup) bakes its own lot: the Ground paving runs the
-- walks and the drive to the lot edge, and the gardens, fences, lamps and roof gear are kit props.
-- So it gets one colour nudge, its kit props (one roof and one site layout per lot), window ACs,
-- and for a garage the kerb cut plus the routing markers CitizenService drives by (see below).
-- Commercial kit v2 templates (blender/com.py via CommercialV2Setup, KitYard): the kit props
-- (KitProps + KitRoof[PlantLayout] + one KitSite), one colour nudge per placement shared with the
-- LOD2 walls, and -- when the lot has baked bays -- the car hand-off marker at LotEntryX. The lot's
-- own paving, bays and markings are in the model; the ground to the road is terrain paint.
local function dressCommercialKit(model: Model, pivot: CFrame, d: number)
	local seed = math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1)
	recolorIndustrial(model, Random.new(seed))
	local yard = Instance.new("Folder")
	yard.Name = "Yard"
	yard.Parent = model
	kitProps(model, yard, seed + 1)
	if model:GetAttribute("ParkingStyle") ~= "baked" then return end
	local footHalfD = d * LOT * 0.5
	local _, roadEnd = accessEnds(pivot, footHalfD, pivot.Position.Y)
	local ex = tonumber(model:GetAttribute("LotEntryX")) or 0
	marker(makeMarkers(yard, pivot), pivot, "LotEntry", ex, roadEnd, ex, footHalfD - 1)
end

-- A kit's paving shipped as DATA -- {x0, x1, zBack, zFront, street, lift, kind[, material, variant]} rects in
-- the lot frame -- draped as LotMesh patches (own material: untinted, e.g. the sewage plants' roads/walks/yards). A street piece runs on to the road's drawn edge; the rest are free patches
-- that melt into the lawn on every side. Returns the drive that meets the street, if any.
local function pavePieces(yard: Instance, pivot: CFrame, footHalfD: number, pieces: { any }): { any }?
	local frame = pivot * CFrame.new(0, DRIVE_LIFT, 0)
	local drive = nil
	for _, e in pieces do
		local street, lift = e[5] == true, tonumber(e[6]) or 0
		local own = typeof(e[8]) == "string"
		local m = lotMesh(yard, {
			frame = frame, x0 = e[1], x1 = e[2], zBack = e[3],
			zFront = if street then footHalfD else e[4],
			reach = if street then nil else 0.01, -- a free patch meets no road: its front melts in too
			yBack = if lift > DRIVE_LIFT then lift - DRIVE_LIFT else nil, -- a drive up to the garage floor
			soft = if street then "lr" else "blr", color = if own then Color3.new(1, 1, 1) else PAVE_TINT,
		})
		if own then
			m:SetAttribute("Material", e[8])
			m:SetAttribute("Variant", if typeof(e[9]) == "string" then e[9] else nil)
		end
		if e[7] == "drive" and street then drive = e end
	end
	return drive
end

local function dressMidRiseKit(model: Model, pivot: CFrame, d: number)
	local seed = math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1)
	recolorIndustrial(model, Random.new(seed))
	local yard = Instance.new("Folder")
	yard.Name = "Yard"
	yard.Parent = model
	kitProps(model, yard, seed + 1)
	windowACs(model, yard, Random.new(seed + 2))

	local footHalfD = d * LOT * 0.5
	-- Kit v3 (gardens): only its paths are paved, the rest is lawn its floor props stand on.
	local pave = model:GetAttribute("KitPave")
	if typeof(pave) == "string" then
		pavePieces(yard, pivot, footHalfD, HttpService:JSONDecode(pave))
		yard:SetAttribute("Draped", true)
		seatOnGround(yard, pivot.Position.Y)
	end
	local gx = tonumber(model:GetAttribute("GarageX"))
	local gz = tonumber(model:GetAttribute("GarageZ"))
	if gx and gz then
		-- The lot ground (lotGround) runs on to the road.
		local _, roadEnd = accessEnds(pivot, footHalfD, pivot.Position.Y)
		local host = makeMarkers(yard, pivot)
		marker(host, pivot, "LotEntry", gx, roadEnd, gx, gz)
		marker(host, pivot, "LotFront", gx, footHalfD - 1, gx, gz)
		marker(host, pivot, "GaragePark", gx, gz + 3 * WS, gx, footHalfD)
	end
	addFoundationSkirt(yard, pivot, model, pivot.Position.Y)
end

-- House kit v2 (blender/res_house.py via HouseV2Setup, KitYard) bakes NO ground: one colour nudge, its kit
-- props (KitProps + one KitRoof + one KitSite), and the lot's PAVING as draped LotMesh patches -- KitPave
-- (drive, walks, patio) plus the KitPaveSite that goes with the chosen site layout (a front court, a band
-- along the house), rects {x0, x1, zBack, zFront, street, lift, kind} in the lot frame. A street piece runs
-- on to the road's drawn edge; the rest are free patches that melt into the lawn on every side. Then the
-- household car's HomePark on the drive, and the foundation skirt.
local function dressHouseKit(model: Model, pivot: CFrame, d: number)
	local seed = math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1)
	recolorIndustrial(model, Random.new(seed))
	local yard = Instance.new("Folder")
	yard.Name = "Yard"
	yard.Parent = model
	kitProps(model, yard, seed + 1)
	local function decode(attr: string): any
		local json = model:GetAttribute(attr)
		return if typeof(json) == "string" then HttpService:JSONDecode(json) else nil
	end
	local site = decode("KitSite")
	local layout = Random.new(seed + 1):NextInteger(1, math.max(1, if site then #site else 1)) -- kitProps's pick
	local pieces = table.clone(decode("KitPave") or {})
	local extra = decode("KitPaveSite")
	for _, e in (extra and extra[layout]) or {} do table.insert(pieces, e) end
	local footHalfD = d * LOT * 0.5
	local drive = pavePieces(yard, pivot, footHalfD, pieces)
	if drive and model.PrimaryPart then
		local x, parkZ = (drive[1] + drive[2]) * 0.5, (drive[3] + footHalfD) * 0.5
		local att = Instance.new("Attachment")
		att.Name = "HomePark"
		att.Parent = model.PrimaryPart
		att.WorldCFrame = CFrame.lookAt((pivot * CFrame.new(x, 0.6 * WS, parkZ)).Position,
			(pivot * CFrame.new(x, 0.6 * WS, parkZ + 3.4 * WS)).Position)
	end
	yard:SetAttribute("Draped", true)
	seatOnGround(yard, pivot.Position.Y)
	addFoundationSkirt(yard, pivot, model, pivot.Position.Y)
end

local function dressMidRise(model: Model, pivot: CFrame, w: number, d: number, plotW: number?)
	if model:GetAttribute("KitYard") then
		dressMidRiseKit(model, pivot, d)
		return
	end
	local rng = Random.new(math.floor(pivot.Position.X * 7.3 + pivot.Position.Z * 13.1))
	recolor(model, rng)

	local footHalfW = math.min(w * LOT, plotW or math.huge) * 0.5
	local footHalfD = d * LOT * 0.5
	local baseY = pivot.Position.Y
	local yard = Instance.new("Folder")
	yard.Name = "Yard"
	yard.Parent = model

	local gx = tonumber(model:GetAttribute("GarageX"))
	local gz = tonumber(model:GetAttribute("GarageZ"))

	-- No forecourt slabs: the lot slab (lotGround) paves it kerb to back fence.
	if gx and gz then
		local ex = math.clamp(gx, -footHalfW + 2.35, footHalfW - 2.35)
		local doorZ = gz
		local _, roadEnd = accessEnds(pivot, footHalfD, baseY)

		local host = makeMarkers(yard, pivot)
		marker(host, pivot, "LotEntry", ex, roadEnd, ex, doorZ)
		marker(host, pivot, "LotFront", ex, footHalfD - 1, ex, doorZ)
		-- Just outside the door, facing the street: where a stowed car reappears to leave.
		marker(host, pivot, "GaragePark", ex, doorZ + 3 * WS, ex, footHalfD)
	end
	addFoundationSkirt(yard, pivot, model, baseY)
end

-- plotW / plotD: the parcel (frontage x depth) the building stands centred at the front of.
function LotDressingService.dress(model: Model, pivot: CFrame, zone: string, w: number, d: number, plotW: number?, plotD: number?)
	local footHalfD = d * LOT * 0.5
	local lotW, lotD = plotW or w * LOT, math.max(plotD or 0, d * LOT)
	-- Its parcel joins the lots a gap fill measures to; gone, the lots beside it fill back in.
	-- Hard-standing unless the kit paves only its own paths (KitPave): then the rest is lawn.
	local slab = (zone ~= "Residential" or model:GetAttribute("Density") == "Medium") and not model:GetAttribute("KitPave")
	registerLot(model, { frame = pivot, halfW = lotW * 0.5, z0 = footHalfD - lotD, z1 = footHalfD,
		fills = slab, cells = {} })
	model.Destroying:Connect(function()
		local r = _lots[model]
		if not r then return end
		unregisterLot(model)
		markDirty(rectBox(r, FILL_MAX))
	end)
	if slab then
		local ok, err = pcall(lotGround, model, pivot, footHalfD, lotW, lotD)
		if not ok then warn("[LotDressingService] lotGround failed: " .. tostring(err)) end
	end
	if zone == "Residential" and model:GetAttribute("Density") == "Medium" then
		local ok, err = pcall(dressMidRise, model, pivot, w, d, plotW)
		if not ok then warn("[LotDressingService] dressMidRise failed: " .. tostring(err)) end
	elseif zone == "Residential" and model:GetAttribute("KitYard") then
		local ok, err = pcall(dressHouseKit, model, pivot, d)
		if not ok then warn("[LotDressingService] dressHouseKit failed: " .. tostring(err)) end
	elseif zone == "Residential" then
		local ok, err = pcall(dressResidential, model, pivot, w, d, plotW)
		if not ok then warn("[LotDressingService] dressResidential failed: " .. tostring(err)) end
	elseif zone == "Commercial" and model:GetAttribute("KitYard") then
		local ok, err = pcall(dressCommercialKit, model, pivot, d)
		if not ok then warn("[LotDressingService] dressCommercialKit failed: " .. tostring(err)) end
	elseif zone == "Commercial" then
		local ok, err = pcall(dressCommercial, model, pivot, w, d)
		if not ok then warn("[LotDressingService] dressCommercial failed: " .. tostring(err)) end
	elseif zone == "Industrial" then
		local ok, err = pcall(dressIndustrial, model, pivot, w, d)
		if not ok then warn("[LotDressingService] dressIndustrial failed: " .. tostring(err)) end
	end
end

-- A dressed building has settled (snapped to the save grid, or slid along by a road refit): its
-- paving -- data, not parts, so PivotTo left it behind -- moves by `moved` and meets the road from
-- where it now stands, and the lots it left and joined re-measure their gap fills.
function LotDressingService.settleLot(model: Model, moved: CFrame)
	watchRoads()
	local r = _lots[model]
	if r then
		markDirty(rectBox(r, FILL_MAX))
		r.frame = moved * r.frame
		registerLot(model, r)
		markDirty(rectBox(r, FILL_MAX))
	end
	for _, m in model:GetDescendants() do
		if not (m:IsA("Model") and CollectionService:HasTag(m, RoadMeshBuilder.LOT_TAG)) then continue end
		local f = m:GetAttribute("Frame")
		if typeof(f) == "CFrame" then m:SetAttribute("Frame", moved * f) end
		local ok, err = pcall(rebuildLotMesh, m)
		if not ok then warn("[LotDressingService] lot mesh build failed: " .. tostring(err)) end
	end
end

-- The ground under a box was regraded (a building's pad went down, moved or came up): the paving
-- there re-drapes on it once the burst settles.
function LotDressingService.groundChanged(x0: number, x1: number, z0: number, z1: number)
	watchRoads()
	markDirty({ x0 = x0, x1 = x1, z0 = z0, z1 = z1 })
end

-- A placed site that is not a zoned lot (the transit kit, the solar farm: tag PavedGates) paves a drive
-- from each of its gates out to the road in the lot paving, so its entrances and exits meet the street
-- across whatever verge lies between, and lays its own KitPave inside. The model's pivot is its lot centre on the ground, +Z toward the
-- road; GateSpans = "x0,x1,Kind;..." along its street edge, LotDepth = the lot's depth (studs).
-- A Walk gate's path wears the site's footpath (WalkMaterial / WalkVariant), every other gate its
-- driveway (DriveMaterial / DriveVariant): the ground runs on to the road in what it is inside.
local GATE_DRIVE_REACH = 40 -- furthest a road may stand in front of a gate and still get a drive
local function paveGates(inst: Instance)
	if not (inst:IsA("Model") and inst:IsDescendantOf(workspace)) then return end
	local spans, depth = inst:GetAttribute("GateSpans"), inst:GetAttribute("LotDepth")
	if typeof(spans) ~= "string" or typeof(depth) ~= "number" then return end
	watchRoads()
	local old = inst:FindFirstChild("GateDrives")
	if old then old:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "GateDrives"
	folder.Parent = inst
	local top = inst:GetAttribute("GroundTop")
	local pivot = inst:GetPivot()
	local frame = pivot * CFrame.new(0, (if typeof(top) == "number" then top else 0.06) + 0.02, 0)
	local half = depth * 0.5
	for span in string.gmatch(spans, "[^;]+") do
		local a, b, kind = string.match(span, "^(%-?[%d%.]+),(%-?[%d%.]+),?(%a*)$")
		local x0, x1 = tonumber(a), tonumber(b)
		if not (x0 and x1) then continue end
		-- the site's own surface for this gate (user, 2026-10-04), else the lot paving
		local use = if kind == "Walk" then "Walk" else "Drive"
		local mat, variant = inst:GetAttribute(use .. "Material"), inst:GetAttribute(use .. "Variant")
		local own = typeof(mat) == "string"
		local m = lotMesh(folder, { frame = frame, x0 = x0, x1 = x1, zFront = half, zBack = half - FEATHER,
			reach = GATE_DRIVE_REACH, square = true, soft = "lr",
			color = if own then Color3.new(1, 1, 1) else PAVE_TINT })
		if own then
			m:SetAttribute("Material", mat)
			m:SetAttribute("Variant", if typeof(variant) == "string" then variant else nil)
		end
		local ok, err = pcall(rebuildLotMesh, m)
		if not ok then warn("[LotDressingService] gate drive failed: " .. tostring(err)) end
	end
	-- The site's own paving inside its fence (KitPave, the house kit's rects {x0, x1, zBack, zFront, ...}
	-- in its frame): free patches that melt into the grass -- the solar farm's roads and yards.
	local pave = inst:GetAttribute("KitPave")
	if typeof(pave) == "string" then
		local before = #folder:GetChildren()
		pavePieces(folder, pivot, half, HttpService:JSONDecode(pave))
		for i, m in folder:GetChildren() do
			if i <= before then continue end
			local ok, err = pcall(rebuildLotMesh, m)
			if not ok then warn("[LotDressingService] site paving failed: " .. tostring(err)) end
		end
	end
	-- the lots around it re-measure their fills against it, now and when it goes
	local r = math.max(depth, inst:GetExtentsSize().X) * 0.5 + FILL_MAX
	local p = pivot.Position
	markDirty({ x0 = p.X - r, x1 = p.X + r, z0 = p.Z - r, z1 = p.Z + r })
	inst.Destroying:Once(function()
		markDirty({ x0 = p.X - r, x1 = p.X + r, z0 = p.Z - r, z1 = p.Z + r })
	end)
end

function LotDressingService.Init()
	_kit = {}
	_siteKit = {}
	local ServerStorage = game:GetService("ServerStorage")
	local props = ServerStorage:FindFirstChild("Templates")
		and ServerStorage.Templates:FindFirstChild("Asset")
		and ServerStorage.Templates.Asset:FindFirstChild("Props")
	-- Every category kit (Props.<Kit>, filed by Authoring.PropKitSetup) and the Nature trees and
	-- hedges, by name: a bench is a bench whichever zone it stands in. First kit to hold a name wins.
	local kits: { Instance } = {}
	for _, f in (if props then props:GetChildren() else {}) do
		if f:IsA("Folder") and f.Name:match("Kit$") then table.insert(kits, f) end
	end
	local nature = game:GetService("ReplicatedStorage"):FindFirstChild("Nature")
	if nature then table.insert(kits, nature) end
	for _, kit in kits do
		for _, m in kit:GetChildren() do
			if m:IsA("Model") and not _siteKit[m.Name] then _siteKit[m.Name] = m end
		end
	end
	for old, new in RENAMED do
		if not _siteKit[old] then _siteKit[old] = _siteKit[new] end
	end
	for name, m in _siteKit do
		if not PROP_EXCLUDE[name] then _kit[name] = m end
	end
	if not next(_kit) then warn("[LotDressingService] no prop kits under Templates.Asset.Props; lot props disabled") end
end

function LotDressingService.Bind()
	CollectionService:GetInstanceAddedSignal("PavedGates"):Connect(function(inst: Instance)
		-- deferred a frame: the site's terrain pad goes down right after it enters the city
		task.defer(function()
			local ok, err = pcall(paveGates, inst)
			if not ok then warn("[LotDressingService] paveGates failed: " .. tostring(err)) end
		end)
	end)
	for _, inst in CollectionService:GetTagged("PavedGates") do
		local ok, err = pcall(paveGates, inst)
		if not ok then warn("[LotDressingService] paveGates failed: " .. tostring(err)) end
	end
end
function LotDressingService.Start() end

return LotDressingService
