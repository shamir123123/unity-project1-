--!strict
-- RoadMeshView -- mesh blocks per map CELL of road pieces (a dense cell splits into
-- several MeshParts to stay under the engine triangle cap), built from DATA. The server ships each
-- segment / junction / corner / dead-end as a Model holding a "RoadMeshSpecs" blob (boxes,
-- wedges, welded surface strips, AND painted marking lines -- see RoadMeshBuilder) plus one
-- invisible collision MeshPart. This view watches workspace._City.Roads, decodes the blob,
-- and bakes the whole piece into a single vertex-coloured EditableMesh MeshPart: markings
-- are thin ribbons baked in (solid = continuous, dashed = one short quad per dash with bare
-- gaps that reveal the asphalt) -- lane paint is IN the mesh, no beams and no separate mesh.
-- (Roblox does not honour EditableImage alpha on a MeshPart texture, so dashes are geometry
-- gaps, not a tiling texture.) Decal symbol plates (turn arrows, speed numerals) stay live.
--
-- EditableMesh lifetime: geometry is built in ONE scratch dynamic EM per batch, baked to
-- STATIC content via AssetService:CreateDataModelContentAsync (full release May 2026;
-- static content does NOT count against the tiny client Editable* memory budget -- roughly
-- 8 dynamic EMs' worth), and the scratch is destroyed immediately. Bakes run one at a
-- time, so at most ONE EditableMesh ever exists regardless of city size.
--
-- Lots bake here too: a lot's paved ground (LotGroundMesh on the server) is the same blob in a
-- Model tagged RoadMeshBuilder.LOT_TAG, naming the look it wears (Material / Variant attrs). Those
-- go in their own cells ("lot:" keys) and their own container, _LotMeshes, so a new building never
-- rebakes the road beside it and nothing that walks the road meshes mistakes a lot for a road.
--
-- Road mesh v2 (ROAD_OVERHAUL_V2 Phase 2): RoadPieces builds the roads on this client from the
-- replicated topology; their specs bake into the same cells with the same looks, and the server
-- blob of every piece RoadPieces draws is skipped. On in Studio, or wherever workspace attribute
-- RoadMeshV2 is true (false turns it off in Studio).

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RoadPieces = require(script.Parent:WaitForChild("RoadPieces"))

local RoadMeshBuilder = require(
	ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadMeshBuilder")
)
local RoadConstants = require(
	ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants")
)
local Quant = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Quant"))
local LOD = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LOD"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local UP = Vector3.yAxis
local DASH_LENGTH = RoadConstants.DASH_LENGTH
local DASH_PITCH = RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP

local RoadPreviewGeometry = require(script.Parent.RoadPreviewGeometry)
local RoadMeshView = {}
local _started = false

local _roadScheduled: { [string]: boolean } = {}
-- Lot ground waits longer: a growing city sets down buildings every few seconds, and each
-- cell rebake is a blocking mesh bake (~25 ms, unsliceable). Coalescing a block's new
-- buildings into one bake turns a stream of hitches into an occasional one.
local LOT_REBUILD_QUIET = 3
local LOT_MAX_WAIT = 8
local _lotPendingSince: { [string]: number } = {}
local FOLDER_WAIT = 30

-- Chunked baking: road pieces bake per map cell, not per piece -- fewer MeshParts and
-- draw calls, and placing a road only rebakes its own 256-stud neighbourhood.
local CELL_SIZE = 256
local MAX_BATCH_SPAN = 1500 -- engine mesh extent cap is 2048; margin for the pieces' own size

-- The engine rejects a bake past ~20k triangles ("Triangle count above limit"), so a
-- cell's specs are batched into as many MeshParts as needed, each under this budget.
-- With the static bake there is no memory-budget ceiling on total road geometry.
local MAX_TRIS_PER_MESH = 19_000

-- LIVE BAKES -- how an EDIT gets on screen at once. A static bake (CreateDataModelContentAsync +
-- CreateMeshPartAsync) is ~25-35 ms of blocking engine work per mesh whatever it holds, and the
-- engine finishes about one a frame, so an edit re-baking two or three cells of ~4 meshes each
-- kept the new road off screen for a dozen long frames. A road cell an edit re-bakes now goes
-- the way the terrain brush does (TerrainMeshView.bake, live): the scratch mesh is snapshotted
-- into a FixedSize EditableMesh and the part is drawn straight from it -- measured there at ~6 ms
-- against ~36 ms. The snapshot has to outlive its part and counts against the client's SHARED
-- Editable budget (its own size only -- not the fat reservation of a dynamic one), so live road
-- geometry is capped at MAX_LIVE_TRIS; past SETTLE_WATERMARK the cells quiet for SETTLE_QUIET are
-- baked back to static in the background, oldest first, which keeps room for the next edit.
-- A batch that does not fit, or that the budget refuses, takes the static path exactly as before.
local LIVE_BAKES = true
local MAX_LIVE_TRIS = 48_000
local SETTLE_WATERMARK = 24_000
-- ...and by COUNT: an edit's meshes are small (measured on a grid: ~700-1,000 triangles over ~6
-- meshes), so the triangle cap alone would let hundreds of snapshots pile up, and each one may
-- carry a fixed cost in the shared budget whatever it holds.
local MAX_LIVE_MESHES = 40
local SETTLE_MESHES = 20
local SETTLE_QUIET = 4
-- An edit queues a few road cells; a city load queues every one at once. A longer backlog than
-- this means a load (or a huge paste), and that bakes static like it always did.
local LIVE_MAX_BACKLOG = 8
local _liveTris = 0
local _liveMeshes = 0

-- Distance LOD: the levels of Shared.LOD, applied per CELL, ~tens of cells per tick.
--   NEAR/MID  full
--   FAR       lane paint hidden -- a 0.3-stud ribbon is under the pixel budget by here
--   CULL      same as FAR: paint stays hidden (no longer destroyed -- see applyLevel)
-- Paint is one quad per dash and per zebra stripe, so it is a big slice of the triangle
-- count. The base slabs are never touched -- they ARE the far view of the city.
--
-- Do NOT strip their MaterialVariant/TextureID to save texture sampling: vertex colours here
-- are pre-boosted by `gain` precisely BECAUSE they multiply the colour map, so with the map
-- gone there is nothing to multiply and mid-grey asphalt clamps out to white. Not worth
-- compensating for either -- the maps are shared assets that stay resident for the near cells
-- regardless, so dropping them on far cells frees nothing.
-- The engine offers no cheaper option here: RenderFidelity=Automatic is a no-op for runtime
-- meshes (LOD chains are precomputed at asset upload; EM bakes have none), Model.LevelOfDetail
-- needs StreamingEnabled which this place runs without, and there is no runtime
-- render-to-texture, so a far cell cannot be flattened into a real imposter image.
-- ponytail: next rung if still heavy -- split kerb side/bottom faces out of the base bake.
local LOD_PERIOD = 0.3

-- The shared ladder drops a 0.3-stud ribbon at ~460 studs (1080p, 70 fov), which reads as too
-- eager from a city camera. Stretch the ladder for ROADS only -- the shared bands stay put for
-- buildings and tools -- so paint starts fading out around 1200 studs instead. Still
-- screen-space: a taller viewport or a narrower fov pushes the real cut-off further out.
-- Raising this also pushes CULL out (~1540 -> ~4000 studs), so far paint geometry stays
-- resident longer -- that is the cost of the wider view.
local PAINT_RANGE_SCALE = 2.6

-- Textured surfaces: the bake splits specs by colour family and each family's meshes get a
-- material (a MaterialVariant for asphalt). Base-material projection is world-space on
-- MeshParts, so no UVs in the bake, and a texture runs straight on across every piece, cell
-- and lot it touches. `gain` pre-boosts vertex colours: they MULTIPLY the colour map, so the
-- tint is scaled to land the final shade near the old flat colour (clamped at white) while
-- per-road custom colours keep working.
-- Asphalt is darker where the cars drive (user reference, 2026-09-29): every asphalt vertex
-- takes `shade` except a surface strip's own edges, which take `edge`, and the strip blends
-- between them over `gutter` studs -- the lighter gutter by each kerb. Junction fans take
-- `shade`, the same as a lane.
type Look = { material: Enum.Material?, variant: string?, gain: number, shade: number?, edge: number?, gutter: number? }
local ASPHALT_LOOK: Look = {
	material = Enum.Material.Asphalt, variant = RoadConstants.ASPHALT_VARIANT, gain = RoadConstants.ASPHALT_GAIN,
	shade = RoadConstants.ASPHALT_SHADE, edge = RoadConstants.ASPHALT_EDGE, gutter = 3.5,
}
-- Footways wear what every lot's paving wears (LotDressingService PAVE_LOOK/PAVE_TINT): the
-- RoadConstants.PAVE_VARIANT concrete tinted SIDEWALK_COLOR, so a yard meets its sidewalk with no seam.
local PAVEMENT_LOOK: Look = { material = Enum.Material.Concrete, variant = RoadConstants.PAVE_VARIANT, gain = 1 }
-- A pedestrian street is laid in paving stones, not footway concrete.
local PAVER_LOOK: Look = { material = Enum.Material.Pavement, gain = 1 }
local PAVER_HEX = {
	[RoadConstants.PEDESTRIAN_PAVING_COLOR:ToHex():lower()] = true,
	[RoadConstants.PEDESTRIAN_PAVING_LIGHT:ToHex():lower()] = true,
}
-- Pavement colour family: footway, kerb and roundabout kerb, plus the brick truck apron and
-- splitter islands (brick-tinted concrete).
local PAVE_HEX = {
	[RoadConstants.SIDEWALK_COLOR:ToHex():lower()] = true,
	[RoadConstants.KERB_COLOR:ToHex():lower()] = true,
	[RoadConstants.ROUNDABOUT_ISLAND_CURB_COLOR:ToHex():lower()] = true,
	[RoadConstants.ROUNDABOUT_APRON_COLOR:ToHex():lower()] = true,
}
-- Paint colours: a v2 triangle list in one of these is a marking (arrows, give-way teeth), so it
-- bakes with the paint; any other colour is a surface and goes by its colour family.
local MARK_HEX = {
	[RoadConstants.MARKING_WHITE:ToHex():lower()] = true,
	[RoadConstants.MARKING_YELLOW:ToHex():lower()] = true,
}
local _v2 = false -- RoadPieces draws the roads it can (Start decides)
local _hidden: { [Model]: boolean } = {} -- server pieces RoadPieces draws instead

-- A server piece RoadPieces draws instead: its blob is skipped at bake, and its own arrow
-- plates (Decals the old renderer laid where ITS stop lines were) are hidden on this client.
local function setHidden(model: Model, hide: boolean)
	_hidden[model] = if hide then true else nil
	for _, d in model:GetDescendants() do
		if d:IsA("Decal") then d.LocalTransparencyModifier = if hide then 1 else 0 end
	end
end

-- One arrow plate, laid exactly as the old renderer laid its own (RoadRenderer.markingDecal).
local function symbolPlate(s: any): BasePart
	local plate = Instance.new("Part")
	plate.Name = "RoadMarkingSymbol"
	plate.Anchored = true
	plate.CanCollide = false
	plate.CanTouch = false
	plate.CanQuery = false
	plate.CastShadow = false
	plate.Transparency = 1
	plate.Size = Vector3.new(s.width, 0.05, s.width)
	local pos = s.center - Vector3.yAxis * 0.025
	plate.CFrame = CFrame.lookAt(pos, pos - s.fwd, Vector3.yAxis)
	local decal = Instance.new("Decal")
	decal.Texture = s.symbol
	decal.Face = Enum.NormalId.Top
	decal.Color3 = s.color
	decal.Parent = plate
	return plate
end

type CellState = {
	version: number,
	bakedVersion: number,
	meshes: { MeshPart },
	details: { MeshPart },
	models: { [Model]: boolean },
	center: Vector3,
	-- Paint geometry was DESTROYED to hand its memory back; rebake it on approach.
	detailsDropped: boolean,
	-- World AABB of the baked base slabs -- the cell's REAL extent, which is not its grid
	-- square. Nil until the first bake lands; see nearestPointIn.
	boundsMin: Vector3?,
	boundsMax: Vector3?,
	-- Level currently applied; 0 means "nothing yet", so the next tick always acts.
	tier: number,	-- Arrow plates: the game's arrow textures on flat Parts (RoadPieces' symbol specs).
	symbols: { BasePart },
	-- FixedSize EditableMeshes the live meshes draw from (see LIVE BAKES), and their triangles.
	-- Destroyed only after the parts drawing from them are gone.
	liveEms: { EditableMesh },
	liveTris: number,
	-- os.clock() of the last change to this cell's content; settling waits SETTLE_QUIET past it.
	editedAt: number,
	-- The change waiting to bake is an EDIT (see LIVE BAKES), not a load. Cleared by the bake.
	wantLive: boolean,
}

local _cells: { [string]: CellState } = {}
local _cellOf: { [Model]: string } = {}
local _conns: { [Model]: { RBXScriptConnection } } = {}
local _meshFolder: Model? = nil
local _lotFolder: Model? = nil

-- Cell key comes from the blob's first vertex, NOT the pivot: live pieces are Models
-- with no BaseParts, so GetPivot() is (0,0,0) -- keying on it funneled every plain
-- segment into one mega-cell "0,0" whose bake blew the engine's per-mesh caps (triangle
-- count, then 2048-stud extents). Pivot is only the pre-replication fallback; the piece
-- migrates to its real cell when the blob arrives (DescendantAdded -> remap).
local LOT_PREFIX = "lot:"
local function isLot(model: Model): boolean
	return CollectionService:HasTag(model, RoadMeshBuilder.LOT_TAG)
end
local function isLotKey(key: string): boolean
	return string.sub(key, 1, #LOT_PREFIX) == LOT_PREFIX
end

local function cellKeyFor(model: Model): string
	local p: Vector3? = nil
	local sv = model:FindFirstChild("RoadMeshSpecs", true)
	if sv and sv:IsA("StringValue") then
		p = RoadMeshBuilder.peekFirstPosition(sv.Value)
	end
	local pos = p or model:GetPivot().Position
	local key = math.floor(pos.X / CELL_SIZE) .. "," .. math.floor(pos.Z / CELL_SIZE)
	return if isLot(model) then LOT_PREFIX .. key else key
end

-- The key IS the grid coordinate, so a cell knows where it is before any geometry exists.
-- Y stays 0: camera altitude is part of how far away a road is, and in this game it is
-- most of it -- zooming out is exactly when the flat slabs should take over.
local function centreOf(key: string): Vector3
	local gx, gz = string.match(key, "(-?%d+),(-?%d+)$")
	if not (gx and gz) then return Vector3.zero end
	return Vector3.new((tonumber(gx) + 0.5) * CELL_SIZE, 0, (tonumber(gz) + 0.5) * CELL_SIZE)
end

local function cellState(key: string): CellState
	local st = _cells[key]
	if not st then
		st = { version = 0, bakedVersion = 0, meshes = {}, details = {}, models = {}, center = centreOf(key), tier = 0, detailsDropped = false, symbols = {},
			liveEms = {}, liveTris = 0, editedAt = 0, wantLive = false }
		_cells[key] = st
	end
	return st
end

local function releaseLive(ems: { EditableMesh }, tris: number)
	for _, em in ems do em:Destroy() end
	_liveTris = math.max(_liveTris - tris, 0)
	_liveMeshes = math.max(_liveMeshes - #ems, 0)
end

local MAX_PREDICTION_CELLS = 8
local MAX_PREDICTION_SEGMENTS = 64
local MAX_PREDICTION_PARTS = 256
local _predictionTokens: { [number]: { [string]: boolean } } = {}
local _predictionHidden: { [string]: boolean } = {}
local _predictionModel: Model? = nil

local function hideCell(key: string, hidden: boolean)
	local state = _cells[key]
	if not state then return end
	local transparency = if hidden then 1 else 0
	for _, mesh in state.meshes do mesh.LocalTransparencyModifier = transparency end
	for _, mesh in state.details do mesh.LocalTransparencyModifier = transparency end
	for _, plate in state.symbols do
		for _, decal in plate:GetChildren() do
			if decal:IsA("Decal") then decal.LocalTransparencyModifier = transparency end
		end
	end
end

local function showAuthoritativeCells()
	for key in _predictionHidden do hideCell(key, false) end
	table.clear(_predictionHidden)
	if _predictionModel then _predictionModel:Destroy(); _predictionModel = nil end
end

local function refreshPredictionCells(): boolean
	local cells: { [string]: boolean } = {}
	local count = 0
	for _, keys in _predictionTokens do
		for key in keys do
			if not cells[key] then count += 1; cells[key] = true end
		end
	end
	if count == 0 then showAuthoritativeCells(); return true end
	if count > MAX_PREDICTION_CELLS then showAuthoritativeCells(); return false end
	for key in cells do
		local state = _cells[key]
		if state then
			for model in state.models do
				if model.Parent and not RoadPieces.coversModel(model.Name) then
					showAuthoritativeCells()
					return false
				end
			end
		end
	end
	local segments = RoadPieces.segmentsForCells(cells, MAX_PREDICTION_SEGMENTS)
	if not segments then showAuthoritativeCells(); return false end
	local model = Instance.new("Model")
	model.Name = "_PendingRoadCells"
	local parts = 0
	for _, segment in segments do
		local ok, used = RoadPreviewGeometry.draw(model, segment, nil, MAX_PREDICTION_PARTS - parts)
		if not ok then
			model:Destroy()
			showAuthoritativeCells()
			return false
		end
		parts += used
	end
	showAuthoritativeCells()
	_predictionHidden = cells
	for key in cells do hideCell(key, true) end
	model.Parent = workspace
	_predictionModel = model
	return true
end

function RoadMeshView.hidePredictionCells(token: number, cells: { [string]: boolean }): boolean
	if not _started or not _v2 or not RoadPieces.isIdle() then return false end
	_predictionTokens[token] = cells
	if refreshPredictionCells() then return true end
	_predictionTokens[token] = nil
	refreshPredictionCells()
	return false
end

function RoadMeshView.isPredictionReady(token: number): boolean
	if not RoadPieces.isIdle() then return false end
	local cells = _predictionTokens[token]
	if not cells then return RoadMeshView.isIdle() end
	for key in cells do
		local state = _cells[key]
		if state and state.bakedVersion ~= state.version then return false end
	end
	return true
end

function RoadMeshView.clearPredictionCells(token: number): ()
	if not _predictionTokens[token] then return end
	_predictionTokens[token] = nil
	refreshPredictionCells()
end

local BOX_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
}
local BOX_FACES = {
	{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
	{ n = Vector3.new(0, 1, 0), tris = { { 5, 6, 7 }, { 5, 7, 8 } } },
	{ n = Vector3.new(0, 0, -1), tris = { { 1, 2, 6 }, { 1, 6, 5 } } },
	{ n = Vector3.new(0, 0, 1), tris = { { 4, 3, 7 }, { 4, 7, 8 } } },
	{ n = Vector3.new(-1, 0, 0), tris = { { 1, 5, 8 }, { 1, 8, 4 } } },
	{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 7 }, { 2, 7, 6 } } },
}
local WEDGE_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, 1), Vector3.new(1, 1, 1),
}

-- Upper-bound triangle estimate per spec (dashed markings emit fewer), used to split
-- a cell into batches that stay under the engine's per-mesh cap.
local function triCount(s, rails: number): number
	if s.strip then
		return math.max(#s.strip // 2 - 1, 0) * 2 * (rails - 1)
	elseif s.mark then
		return math.max(#s.mark - 1, 0) * 2
	elseif s.fan then
		return #s.fan * 4
	elseif s.tris then
		return #s.tris // 3
	elseif s.wedge then
		return 8
	else
		return 12
	end
end

-- live: may this batch bake live (see LIVE BAKES)? Returns the part, and for a live bake the
-- snapshot it draws from plus the triangles it holds against MAX_LIVE_TRIS.
local function bakeBatch(cellKey: string, specs: { any }, look: Look?, live: boolean?): (MeshPart, EditableMesh?, number)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, s in specs do
		if s.strip then
			for _, v in s.strip do minV = minV:Min(v); maxV = maxV:Max(v) end
		elseif s.mark then
			for _, v in s.mark do minV = minV:Min(v); maxV = maxV:Max(v) end
		elseif s.fan then
			for _, v in s.fan do minV = minV:Min(v); maxV = maxV:Max(v) end
			minV = minV:Min(s.center); maxV = maxV:Max(s.center)
		elseif s.tris then
			for _, v in s.tris do minV = minV:Min(v); maxV = maxV:Max(v) end
		else
			local cf, half = s.cframe, s.size * 0.5
			for _, c in BOX_CORNERS do
				local w = cf:PointToWorldSpace(half * c)
				minV = minV:Min(w); maxV = maxV:Max(w)
			end
		end
	end
	-- Round the batch origin to the codec grid so the baked MeshPart's CFrame reads one
	-- decimal. Vertices are emitted relative to this same origin (p - center), so rounding
	-- it shifts nothing -- the geometry still lands exactly where it did.
	local center = Quant.vec((minV + maxV) * 0.5)

	local em = AssetService:CreateEditableMesh()
	assert(em, "EditableMesh memory budget exhausted")

	local colorIds = {}
	local gain = if look then look.gain else 1
	local shade = if look and look.shade then look.shade else 1
	local edgeShade = if look and look.edge then look.edge else shade
	local gutter = if look then look.gutter else nil
	-- `edge` = a surface strip's edge vertex (the lighter gutter).
	local function colorId(c, edge: boolean?)
		local k = if edge then edgeShade else shade
		if gain ~= 1 or k ~= 1 then
			c = Color3.new(math.min(c.R * gain, 1) * k, math.min(c.G * gain, 1) * k, math.min(c.B * gain, 1) * k)
		end
		local key = c:ToHex()
		local id = colorIds[key]
		if not id then
			id = em:AddColor(c, 1)
			colorIds[key] = id
		end
		return id
	end

	local posOf = {}
	local function vtx(p)
		local id = em:AddVertex(p)
		posOf[id] = p
		return id
	end
	-- Consistent winding: DoubleSided lights a mis-wound face as a backface (flipped
	-- normal), which read as alternating dark slices on the junction fan. Every triangle
	-- is emitted through here and swapped to agree with its shading normal.
	-- c2/c3 give corners 2 and 3 their own colour (a gradient across the face); default cid.
	local triangles = 0
	local function emitTri(v1, v2, v3, n1, n2, n3, worldN, cid, c2, c3)
		triangles += 1
		c2 = c2 or cid
		c3 = c3 or cid
		local g = (posOf[v2] - posOf[v1]):Cross(posOf[v3] - posOf[v1])
		if g:Dot(worldN) < 0 then
			v2, v3 = v3, v2
			n2, n3 = n3, n2
			c2, c3 = c3, c2
		end
		local fid = em:AddTriangle(v1, v2, v3)
		em:SetFaceColors(fid, { cid, c2, c3 })
		em:SetFaceNormals(fid, { n1, n2, n3 })
	end

	local function addFace(vertIds, cf, localN, tris, cid)
		local worldN = cf:VectorToWorldSpace(localN)
		local nid = em:AddNormal(worldN)
		for _, t in tris do
			emitTri(vertIds[t[1]], vertIds[t[2]], vertIds[t[3]], nid, nid, nid, worldN, cid)
		end
	end

	-- |normal . UP| below this and the strip is a WALL, not a surface -- see the two-sided
	-- emission in addStrip. Slabs sit near 1 (even at MAX_ROAD_GRADE a road slab is ~0.98),
	-- kerb faces near 0, so there is nothing near the threshold to misclassify.
	local WALL_FACING_DOT = 0.35

	-- Welded surface ribbon: shared vertices + per-station smooth normals (curves read smooth
	-- instead of per-facet boxes that overlapped and z-fought).
	local function addStrip(s)
		local strip = s.strip
		local n = #strip // 2
		if n < 2 then return end
		-- Thin out stations that carry no shape. The sampler emits one every few studs and
		-- each costs two triangles, so a straight run is almost entirely redundant. RDP on
		-- BOTH rails, unioned: a one-sided taper bends only one of them, and a station either
		-- rail still needs has to survive. LOSSLESS_STUDS is under the pixel budget with the
		-- camera on the tarmac, so this changes nothing anyone can see at any distance.
		if n > 2 then
			local left = table.create(n)
			local right = table.create(n)
			for k = 1, n do
				left[k] = strip[k * 2 - 1]
				right[k] = strip[k * 2]
			end

			local keep: { [number]: boolean } = {}
			for _, k in LOD.simplifyIndices(left, LOD.LOSSLESS_STUDS) do keep[k] = true end
			for _, k in LOD.simplifyIndices(right, LOD.LOSSLESS_STUDS) do keep[k] = true end

			local thinned = {}
			for k = 1, n do
				if keep[k] then
					table.insert(thinned, left[k])
					table.insert(thinned, right[k])
				end
			end

			strip = thinned
			n = #strip // 2
		end
		local nrm = table.create(n)
		local ups = table.create(n)
		local facing = 0
		for k = 1, n do
			local l, r = strip[k * 2 - 1], strip[k * 2]
			local tangent = strip[math.min(k + 1, n) * 2 - 1] - strip[math.max(k - 1, 1) * 2 - 1]
			local up = (r - l):Cross(tangent)
			up = if up.Magnitude > 1e-6 then up.Unit else UP
			if up:Dot(UP) < 0 then up = -up end
			ups[k] = up
			nrm[k] = em:AddNormal(up)
			facing += math.abs(up:Dot(UP))
		end
		-- A near-VERTICAL strip is a wall (the kerb faces), and a wall has no back: emit it both
		-- ways. It cannot be left one-sided, because this mesh is DoubleSided = false and the
		-- facing is decided by `up`. For a wall, up:Dot(UP) is 0 (measured: exactly 0.000 on the
		-- kerb faces, against 0.98-1.00 on every slab), so the skyward flip above is a no-op and
		-- `up` keeps whatever (r-l):Cross(tangent) gave. Both rails of a road are built in the
		-- same t order, so that is the SAME world direction for the left and right kerb -- which
		-- means one of them faces out of the kerb and the other faces into it, and the second is
		-- invisible from the road. That is the see-through kerb, and it is one whole side of
		-- every road, not a flicker. It hid while the kerb was 0.15 studs tall.
		-- The reversed copy is the same triangles wound the other way, so backface culling shows
		-- exactly one of the pair from any camera -- no z-fighting and no extra drawn pixels,
		-- only the triangles. Walls are a small share of a piece's mesh, but this does count
		-- against the engine's ~21.8k bake limit.
		local isWall = facing / n < WALL_FACING_DOT
		local backNrm: { number }? = nil
		if isWall then
			local back = table.create(n)
			for k = 1, n do back[k] = em:AddNormal(-ups[k]) end
			backNrm = back
		end
		-- Rails across the strip, each with its colour: its two edges, plus (shaded asphalt) a rail
		-- `gutter` in from each edge, so the edges stay light and the middle takes the full shade.
		local g = if gutter and not isWall then gutter else nil
		local cDrive = colorId(s.color)
		local cEdge = if g then colorId(s.color, true) else cDrive
		local railCids = if g then { cEdge, cDrive, cDrive, cEdge } else { cDrive, cDrive }
		local nRails = #railCids
		local rails = table.create(nRails)
		for c = 1, nRails do rails[c] = table.create(n) end
		for k = 1, n do
			local l, r = strip[k * 2 - 1], strip[k * 2]
			rails[1][k] = vtx(l - center)
			rails[nRails][k] = vtx(r - center)
			if g then
				local w = (r - l).Magnitude
				local inset = (r - l) * (math.min(g, w * 0.25) / math.max(w, 1e-6))
				rails[2][k] = vtx(l + inset - center)
				rails[3][k] = vtx(r - inset - center)
			end
		end
		for c = 1, nRails - 1 do
			local A, B, ca, cb = rails[c], rails[c + 1], railCids[c], railCids[c + 1]
			for k = 1, n - 1 do
				local wn = ups[k] + ups[k + 1]
				emitTri(A[k], B[k], B[k + 1], nrm[k], nrm[k], nrm[k + 1], wn, ca, cb, cb)
				emitTri(A[k], B[k + 1], A[k + 1], nrm[k], nrm[k + 1], nrm[k + 1], wn, ca, cb, ca)
				if backNrm then
					emitTri(A[k], B[k], B[k + 1], backNrm[k], backNrm[k], backNrm[k + 1], -wn, ca, cb, cb)
					emitTri(A[k], B[k + 1], A[k + 1], backNrm[k], backNrm[k + 1], backNrm[k + 1], -wn, ca, cb, ca)
				end
			end
		end
	end

	-- A painted line baked as a thin ribbon along its centreline. Solid -> continuous;
	-- dashed -> a quad only where the arc length falls inside a dash, bare gaps show asphalt.
	local nUp = em:AddNormal(UP)
	local function addMarking(s)
		local pts = s.mark
		local n = #pts
		if n < 2 then return end
		local hw = (s.width or 0.3) * 0.5
		local cid = colorId(s.color)
		local dashed = s.dashed == true
		-- Solid lines thin like the strips do. Dashed ones must NOT: the dash phase is
		-- decided per segment from arc length, so collapsing a straight run into one long
		-- segment would emit a single dash across the whole span.
		if not dashed and n > 2 then
			pts = LOD.simplify(pts, LOD.LOSSLESS_STUDS)
			n = #pts
		end
		local side = table.create(n)
		local cum = table.create(n)
		cum[1] = 0
		for k = 1, n do
			local tangent = pts[math.min(k + 1, n)] - pts[math.max(k - 1, 1)]
			local sd = tangent:Cross(UP)
			side[k] = if sd.Magnitude > 1e-6 then sd.Unit else Vector3.xAxis
			if k > 1 then
				cum[k] = cum[k - 1] + (pts[k] - pts[k - 1]).Magnitude
			end
		end
		for k = 1, n - 1 do
			if dashed and ((cum[k] + cum[k + 1]) * 0.5) % DASH_PITCH >= DASH_LENGTH then
				continue
			end
			local lA = vtx(pts[k] - side[k] * hw - center)
			local rA = vtx(pts[k] + side[k] * hw - center)
			local rB = vtx(pts[k + 1] + side[k + 1] * hw - center)
			local lB = vtx(pts[k + 1] - side[k + 1] * hw - center)
			emitTri(lA, rA, rB, nUp, nUp, nUp, UP, cid)
			emitTri(lA, rB, lB, nUp, nUp, nUp, UP, cid)
		end
	end

	-- Flat triangle list (v2 paint symbols, a road end's half disc): faces up, one colour.
	local function addTris(s)
		local pts = s.tris
		local cid = colorId(s.color)
		for k = 1, #pts - 2, 3 do
			local a, b, c = pts[k], pts[k + 1], pts[k + 2]
			local fn = (b - a):Cross(c - a)
			if fn.Magnitude < 1e-9 then continue end
			fn = fn.Unit
			if fn.Y < 0 then fn = -fn end
			local nid = if fn.Y > 0.999 then nUp else em:AddNormal(fn)
			emitTri(vtx(a - center), vtx(b - center), vtx(c - center), nid, nid, nid, fn, cid)
		end
	end

	-- Solid polygon slab: centre->rim top fan + bottom fan + rim skirt, straight into the mesh.
	-- Replaces the junction surface's 2-wedge prisms (16 tris/slice) with 4 tris/slice.
	local function addFan(s)
		local rim = s.fan
		local n = #rim
		if n < 3 then return end
		local c = s.center
		local cid = colorId(s.color)
		local drop = UP * (s.thickness or 0.5)
		local cTop = vtx(c - center)
		local cBot = vtx(c - drop - center)
		local topIds = table.create(n)
		local botIds = table.create(n)
		for k = 1, n do
			topIds[k] = vtx(rim[k] - center)
			botIds[k] = vtx(rim[k] - drop - center)
		end
		local downId = em:AddNormal(-UP)
		-- top: ONE normal for the whole surface (the slices' area-weighted mean). Per-slice
		-- normals creased a junction whose arms sit at different heights into dark wedges.
		local sum = Vector3.zero
		for k = 1, n do
			local fn = (rim[k] - c):Cross(rim[(k % n) + 1] - c)
			sum += if fn:Dot(UP) < 0 then -fn else fn
		end
		local wn = if sum.Magnitude > 1e-6 then sum.Unit else UP
		local tnid = em:AddNormal(wn)
		for k = 1, n do
			local k2 = (k % n) + 1
			emitTri(cTop, topIds[k], topIds[k2], tnid, tnid, tnid, wn, cid)
			-- bottom (downward)
			emitTri(cBot, botIds[k], botIds[k2], downId, downId, downId, -UP, cid)
			-- skirt (outward from centre)
			local mid = (rim[k] + rim[k2]) * 0.5
			local ow = Vector3.new(mid.X - c.X, 0, mid.Z - c.Z)
			local own = if ow.Magnitude > 1e-6 then ow.Unit else Vector3.xAxis
			local onid = em:AddNormal(own)
			emitTri(topIds[k], botIds[k], botIds[k2], onid, onid, onid, own, cid)
			emitTri(topIds[k], botIds[k2], topIds[k2], onid, onid, onid, own, cid)
		end
	end

	local okBake, meshOrErr, liveEm, liveTris = pcall(function(): (MeshPart, EditableMesh?, number)
		for si, s in specs do
			if si % 400 == 0 then
				task.wait() -- spread a big batch build across frames instead of one long hitch
			end
			if s.mark then
				addMarking(s)
			elseif s.tris then
				addTris(s)
			elseif s.fan then
				addFan(s)
			elseif s.strip then
				addStrip(s)
			elseif s.wedge then
				local cf, half = s.cframe, s.size * 0.5
				local cid = colorId(s.color)
				local ids = table.create(6)
				for i, c in WEDGE_CORNERS do
					ids[i] = vtx(cf:PointToWorldSpace(half * c) - center)
				end
				addFace(ids, cf, Vector3.new(0, -1, 0), { { 1, 2, 3 }, { 1, 3, 4 } }, cid)
				addFace(ids, cf, Vector3.new(0, 0, 1), { { 4, 3, 6 }, { 4, 6, 5 } }, cid)
				addFace(ids, cf, Vector3.new(0, s.size.Z, -s.size.Y).Unit, { { 1, 2, 6 }, { 1, 6, 5 } }, cid)
				addFace(ids, cf, Vector3.new(-1, 0, 0), { { 1, 4, 5 } }, cid)
				addFace(ids, cf, Vector3.new(1, 0, 0), { { 2, 3, 6 } }, cid)
			else
				local cf, half = s.cframe, s.size * 0.5
				local cid = colorId(s.color)
				local ids = table.create(8)
				for i, c in BOX_CORNERS do
					ids[i] = vtx(cf:PointToWorldSpace(half * c) - center)
				end
				for _, face in BOX_FACES do
					addFace(ids, cf, face.n, face.tris, cid)
				end
			end
		end
		if live and _liveTris + triangles <= MAX_LIVE_TRIS and _liveMeshes < MAX_LIVE_MESHES then
			-- LIVE (see LIVE BAKES): a FixedSize snapshot, the part drawn straight from it. The
			-- scratch dies below either way; only the snapshot outlives this call. Reserved before
			-- the async calls -- they yield, and the next batch must see this one's share.
			_liveTris += triangles
			_liveMeshes += 1
			local okFixed, fixed = pcall(function(): EditableMesh
				return AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
			end)
			if okFixed and fixed then
				local okPart, part = pcall(function(): MeshPart
					return AssetService:CreateMeshPartAsync(Content.fromObject(fixed), {
						CollisionFidelity = Enum.CollisionFidelity.Box,
					})
				end)
				if okPart and part then return part, fixed, triangles end
				fixed:Destroy()
			end
			_liveTris -= triangles
			_liveMeshes -= 1
			-- Refused (the shared budget is full this instant): fall through to the static bake.
		end
		-- Bake to STATIC content: the MeshPart owns a static copy of the geometry, so the
		-- EditableMesh can die right away instead of being kept alive per mesh (the old
		-- keep-alive pattern is what exhausted the client's Editable* memory budget).
		local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		if result ~= Enum.CreateContentResult.Success then
			error(`CreateDataModelContentAsync failed: {tostring(result)}`)
		end
		return AssetService:CreateMeshPartAsync(content, {
			-- ponytail: mesh never collides or gets queried -- Box skips the precise collision
			-- decomposition CreateMeshPartAsync would otherwise compute per road piece.
			CollisionFidelity = Enum.CollisionFidelity.Box,
		}), nil, 0
	end)
	em:Destroy()
	if not okBake then
		error(meshOrErr)
	end
	local mesh = meshOrErr
	mesh.Name = if isLotKey(cellKey) then "LotCell_" .. string.sub(cellKey, #LOT_PREFIX + 1) else "RoadCell_" .. cellKey
	mesh.Anchored = true
	mesh.CanCollide = false -- ponytail: nothing walks/drives the city by physics; keep roads out of the collision broadphase
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.CastShadow = false
	-- Single-sided: emitTri winds every face to agree with its shading normal, so backface
	-- culling is safe and halves the pixel cost (roads are never seen from below).
	mesh.DoubleSided = false
	mesh.Color = Color3.new(1, 1, 1)
	mesh.Material = Enum.Material.SmoothPlastic
	if look and look.material then
		mesh.Material = look.material
		if look.variant then mesh.MaterialVariant = look.variant end
	end
	mesh.CFrame = CFrame.new(center)
	return mesh, liveEm, liveTris
end

-- detailsOnly bakes the paint and nothing else: that is the LOD re-entry path, and the base
-- slabs it would otherwise redo are the expensive half.
local function bake(cellKey: string, models: { Model }, detailsOnly: boolean?, live: boolean?): ({ MeshPart }, { MeshPart }, { any }, { EditableMesh }, number)
	local symbolSpecs = {} -- arrow plates: placed, not baked
	local baseSpecs = {}
	local paveSpecs = {}
	local paverSpecs = {}
	local plainSpecs = {}
	local markSpecs = {}
	-- A lot's ground wears the look its model names, one list per look.
	local lotLooks: { [string]: { look: Look, specs: { any } } } = {}
	-- Colour family -> texture family: sidewalks/kerbs read as paver blocks, coloured trim
	-- (grass islands etc.) stays flat, everything grey is asphalt.
	local function listFor(s): { any }
		if s.symbol then return symbolSpecs end
		if s.mark then return markSpecs end
		local c = s.color
		if s.tris and MARK_HEX[c:ToHex():lower()] then return markSpecs end
		if PAVE_HEX[c:ToHex():lower()] then return paveSpecs end
		if PAVER_HEX[c:ToHex():lower()] then return paverSpecs end
		if math.max(c.R, c.G, c.B) - math.min(c.R, c.G, c.B) > 0.07 then return plainSpecs end
		return baseSpecs
	end
	for _, model in models do
		if _hidden[model] then continue end -- RoadPieces draws this piece
		local list: { any }? = nil
		local mat = model:GetAttribute("Material")
		if typeof(mat) == "string" then
			local variant = model:GetAttribute("Variant")
			local v = if typeof(variant) == "string" and variant ~= "" then variant else nil
			local key = mat .. "/" .. (v or "")
			local entry = lotLooks[key]
			if not entry then
				local ok, material = pcall(function() return (Enum.Material :: any)[mat] end)
				entry = { look = { material = if ok then material else Enum.Material.Concrete, variant = v, gain = 1 }, specs = {} }
				lotLooks[key] = entry
			end
			list = entry.specs
		end
		for _, d in model:GetDescendants() do
			if d:IsA("StringValue") and d.Name == "RoadMeshSpecs" and d.Value ~= "" then
				for _, s in RoadMeshBuilder.decodeSpecs(d.Value) do
					table.insert(list or listFor(s), s)
				end
			end
		end
	end
	if _v2 and not isLotKey(cellKey) then
		for _, s in RoadPieces.specsForCell(cellKey) do
			table.insert(listFor(s), s)
		end
	end
	local liveEms: { EditableMesh } = {}
	local liveTotal = 0
	local function bakeList(specs, out: { MeshPart }, look: Look?)
		local batch = {}
		local batchTris = 0
		local lo: Vector3?, hi: Vector3? = nil, nil
		local function flush()
			if #batch == 0 then return end
			local okBatch, mesh, liveEm, liveTris = pcall(bakeBatch, cellKey, batch, look, live)
			if not okBatch then error(mesh, 0) end
			if liveEm then
				table.insert(liveEms, liveEm)
				liveTotal += liveTris
			end
			table.insert(out, mesh)
			batch = {}
			batchTris = 0
			lo, hi = nil, nil
		end
		for _, s in specs do
			local t = triCount(s, if look and look.gutter then 4 else 2)
			-- Mesh extents cap at 2048. A lot filed under its pre-replication pivot (see
			-- cellKeyFor) can share a cell with lots across the whole map, so split on span too.
			local p: Vector3? = if s.cframe then s.cframe.Position elseif s.center then s.center elseif s.pts then s.pts[1] else nil
			local nlo = if p and lo then lo:Min(p) else p
			local nhi = if p and hi then hi:Max(p) else p
			local wide = nlo ~= nil and nhi ~= nil and ((nhi :: Vector3) - (nlo :: Vector3)).Magnitude > MAX_BATCH_SPAN
			if (batchTris + t > MAX_TRIS_PER_MESH or wide) and #batch > 0 then
				flush()
				nlo, nhi = p, p
			end
			lo, hi = nlo, nhi
			table.insert(batch, s)
			batchTris += t
		end
		flush()
	end
	local meshes: { MeshPart } = {}
	local details: { MeshPart } = {}
	local ok, err = pcall(function()
		if not detailsOnly then
			bakeList(baseSpecs, meshes, ASPHALT_LOOK)
			bakeList(paveSpecs, meshes, PAVEMENT_LOOK)
			bakeList(paverSpecs, meshes, PAVER_LOOK)
			bakeList(plainSpecs, meshes, nil)
			for _, entry in lotLooks do
				bakeList(entry.specs, meshes, entry.look)
			end
		end
		bakeList(markSpecs, details, nil)
	end)
	if not ok then
		-- Don't leak the batches that DID bake before the failure.
		for _, m in meshes do m:Destroy() end
		for _, m in details do m:Destroy() end
		releaseLive(liveEms, liveTotal)
		error(err)
	end
	for _, m in details do
		m.Name = "RoadDetail_" .. cellKey
	end
	return meshes, details, symbolSpecs, liveEms, liveTotal
end

-- The cell's real world extent, from the base slabs just baked. Bakes are rare, so this is
-- done once here rather than every LOD tick.
local function refreshBounds(st: CellState)
	local lo: Vector3? = nil
	local hi: Vector3? = nil
	for _, m in st.meshes do
		local half = m.Size * 0.5
		local a, b = m.Position - half, m.Position + half
		lo = if lo then lo:Min(a) else a
		hi = if hi then hi:Max(b) else b
	end
	st.boundsMin = lo
	st.boundsMax = hi
end

local armSettle: () -> ()

local function rebuild(key: string, live: boolean?)
	local st = _cells[key]
	if not st then return end
	local models: { Model } = {}
	for m in st.models do
		if m.Parent then table.insert(models, m) end
	end
	local version = st.version
	st.wantLive = false
	local ok, meshesOrErr, newDetails, newSymbols, newLive, newLiveTris = pcall(bake, key, models, nil, live)
	if not ok then
		warn(`[RoadMeshView] bake failed for cell {key}: {meshesOrErr}`)
		-- Same retry hook as the detail path: if the paint was dropped, a failed rebuild
		-- leaves it dropped and nothing asks again until the tier moves.
		st.tier = 0
		return
	end
	if _cells[key] ~= st or st.version ~= version then
		for _, m in meshesOrErr do m:Destroy() end
		for _, m in newDetails do m:Destroy() end
		releaseLive(newLive, newLiveTris)
		return
	end
	local oldMeshes, oldDetails = st.meshes, st.details
	local oldLive, oldLiveTris = st.liveEms, st.liveTris
	st.liveEms, st.liveTris = newLive, newLiveTris
	st.meshes = meshesOrErr
	st.bakedVersion = version
	refreshBounds(st)
	st.details = newDetails
	-- Fresh meshes come back wearing their baked (NEAR) look; make the next tick re-apply.
	st.tier = 0
	st.detailsDropped = false
	local folder = if isLotKey(key) then _lotFolder else _meshFolder
	for _, m in st.meshes do
		m.Parent = folder
	end
	for _, m in st.details do
		m.Parent = folder
	end
	for _, m in oldMeshes do m:Destroy() end
	for _, m in oldDetails do m:Destroy() end
	-- after the parts that drew from them: a live part stops rendering when its mesh dies
	releaseLive(oldLive, oldLiveTris)
	for _, p in st.symbols do p:Destroy() end
	st.symbols = {}
	for _, s in newSymbols or {} do
		local plate = symbolPlate(s)
		plate.Parent = folder
		table.insert(st.symbols, plate)
	end
	if _predictionHidden[key] then hideCell(key, true) end
	if next(st.models) == nil and not (_v2 and RoadPieces.hasCell(key)) then
		-- The last piece left this cell WHILE the bake was running, so what we just baked is
		-- geometry that no longer exists. Dropping the cell state without destroying it left a
		-- deleted road on screen forever -- the rebuild queued by its removal finds no cell
		-- state and no-ops. Bake yields (task.wait, CreateDataModelContentAsync), so this race
		-- is ordinary, not exotic.
		for _, m in st.meshes do m:Destroy() end
		for _, m in st.details do m:Destroy() end
		for _, p in st.symbols do p:Destroy() end
		releaseLive(st.liveEms, st.liveTris)
		st.liveEms, st.liveTris = {}, 0
		_cells[key] = nil
		return
	end
	if st.liveTris > 0 then armSettle() end
end

-- Re-bake ONLY the paint a far cell gave back. Runs through the same one-at-a-time queue,
-- so the "at most one EditableMesh alive" guarantee still holds.
local function rebuildDetails(key: string)
	local st = _cells[key]
	if not st or not st.detailsDropped then return end

	local models: { Model } = {}
	for m in st.models do
		if m.Parent then table.insert(models, m) end
	end

	local ok, _meshes, newDetails = pcall(bake :: any, key, models, true, false)
	if not ok then
		warn(`[RoadMeshView] detail rebake failed for cell {key}: {_meshes}`)
		-- The paint is still dropped and applyLevel only re-enqueues on a tier CHANGE, so
		-- without this the cell stays unpainted until you fly out past CULL and back --
		-- one transient bake failure = markings gone for the session.
		-- ponytail: retries at LOD_PERIOD; add a backoff if a cell ever fails forever.
		st.tier = 0
		return
	end

	-- The bake yields, so the cell can have been rebuilt, dropped, or flown away from in
	-- the meantime. Anything but the exact state we started on means throw this away.
	if _cells[key] ~= st or not st.detailsDropped then
		for _, m in newDetails do m:Destroy() end
		return
	end

	st.details = newDetails
	st.detailsDropped = false
	for _, m in st.details do
		m.Parent = _meshFolder
	end
	-- Paint bakes visible, but the bake yields and the camera may have moved out to FAR
	-- meanwhile. Tier is unchanged, so applyLevel would early-return and never dress it.
	-- Reset to "nothing applied" and let the next tick be the single reconciler.
	st.tier = 0
end

-- settle: a background static re-bake of a live cell (see LIVE BAKES). Lowest priority, and
-- invisible to isIdle -- nothing the player is waiting on.
type BakeJob = { key: string, detailsOnly: boolean, settle: boolean? }

local _bakeQueue: { BakeJob } = {}
local _queuedSet: { [string]: boolean } = {}
local _pumping = false
-- Jobs queued or running that are NOT settles: what isIdle answers for.
local _busyJobs = 0
-- isIdle / lastBakeAt: rebuilds waiting out REBUILD_QUIET, and when a bake last finished --
-- together they say when a road that just replicated is on screen (for the road tool's
-- frozen mesh ghost, ROAD_OVERHAUL_V2 Phase 2).
local _scheduled = 0
local _lastBakeAt = -math.huge

local function popBakeJob(): BakeJob
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	local best, bestKind, bestDistance = 1, math.huge, math.huge
	for i, job in _bakeQueue do
		local kind = if job.settle then 4 elseif job.detailsOnly then 3 elseif _predictionHidden[job.key] then 0 elseif isLotKey(job.key) then 2 else 1
		local state = _cells[job.key]
		local center = if state then state.center else centreOf(job.key)
		local dx,dz = eye.X-center.X,eye.Z-center.Z
		local distance = dx*dx+dz*dz
		if kind < bestKind or (kind == bestKind and distance < bestDistance) then
			best,bestKind,bestDistance=i,kind,distance
		end
	end
	return table.remove(_bakeQueue,best)
end

local function jobTag(job: BakeJob): string
	return if job.settle then "s:" .. job.key elseif job.detailsOnly then "d:" .. job.key else job.key
end

local function enqueue(key: string, detailsOnly: boolean?, settle: boolean?)
	local only = detailsOnly == true
	local job: BakeJob = { key = key, detailsOnly = only, settle = settle == true }
	local tag = jobTag(job)
	if _queuedSet[tag] then return end
	_queuedSet[tag] = true
	if not job.settle then _busyJobs += 1 end
	if only or job.settle then
		table.insert(_bakeQueue, job)
	else
		-- A road that was just built or changed (by anyone on the server) goes ahead of the
		-- paint-only rebakes that flying the camera around queues up, so another player's
		-- new road appears as soon as it replicates instead of after that backlog.
		local at = #_bakeQueue + 1
		for i, queued in _bakeQueue do
			if queued.detailsOnly then at = i break end
		end
		table.insert(_bakeQueue, at, job)
	end
	if _pumping then return end
	_pumping = true
	task.spawn(function()
		while #_bakeQueue > 0 do
			-- Road cells still waiting, counted before the pop: a short backlog is an edit.
			local backlog = 0
			for _, queued in _bakeQueue do
				if not (queued.settle or queued.detailsOnly or isLotKey(queued.key)) then backlog += 1 end
			end
			local job = popBakeJob()
			_queuedSet[jobTag(job)] = nil
			-- Error boundary. An error escaping a job used to kill this thread with
			-- _pumping still true, so every later enqueue appended to a queue nobody
			-- pumped: road paint (and every rebuild) silently stopped for the session.
			local ok, err = pcall(function()
				if job.detailsOnly then
					rebuildDetails(job.key)
				elseif job.settle then
					local st = _cells[job.key]
					-- Touched again since it was picked: not quiet, it waits for a later check.
					if st and st.liveTris > 0 and os.clock() - st.editedAt >= SETTLE_QUIET then
						rebuild(job.key, false)
					end
					armSettle() -- the next one, if the total is still past the watermark
				else
					local st = _cells[job.key]
					rebuild(job.key, LIVE_BAKES and st ~= nil and st.wantLive and not isLotKey(job.key)
						and backlog <= LIVE_MAX_BACKLOG)
				end
			end)
			if not job.settle then _busyJobs -= 1 end
			if not (job.detailsOnly or job.settle) then _lastBakeAt = os.clock() end
			if not ok then
				warn(`[RoadMeshView] bake job failed for cell {job.key}: {err}`)
			end
		end
		_pumping = false
	end)
end

-- Past either watermark, bake the longest-quiet live cell back to static (one at a time: each settle
-- re-arms the check when it lands). Below it live cells simply stay live -- a static bake costs
-- the same blocking frames whenever it runs, so it is only paid when the room is needed.
local _settleArmed = false
local function settleCheck()
	_settleArmed = false
	if _liveTris <= SETTLE_WATERMARK and _liveMeshes <= SETTLE_MESHES then return end
	local now = os.clock()
	local bestKey: string? = nil
	local bestAt = math.huge
	local waiting = false
	for key, st in _cells do
		if st.liveTris > 0 then
			if now - st.editedAt >= SETTLE_QUIET then
				if st.editedAt < bestAt then bestKey, bestAt = key, st.editedAt end
			else
				waiting = true
			end
		end
	end
	if bestKey then
		enqueue(bestKey, false, true)
	elseif waiting then
		armSettle()
	end
end
function armSettle()
	if _settleArmed then return end
	_settleArmed = true
	task.delay(SETTLE_QUIET, settleCheck)
end

-- live: this change is an edit to be drawn at once (see LIVE BAKES). A city load is not: it
-- arrives as one big notify, or as models replicating into cells never baked before.
local function schedule(key: string, live: boolean?)
	local st = _cells[key]
	if not st then return end
	st.version += 1
	st.editedAt = os.clock()
	if live then st.wantLive = true end
	local v = st.version
	if isLotKey(key) and #st.meshes > 0 then -- a first bake (the city loading) goes straight through
		-- Never starved: a block that keeps growing still rebakes every LOT_MAX_WAIT.
		_lotPendingSince[key] = _lotPendingSince[key] or os.clock()
		task.delay(LOT_REBUILD_QUIET, function()
			local cur = _cells[key]
			local since = _lotPendingSince[key]
			-- nil: an earlier wake already queued the bake, which reads the cell when it runs
			if not cur or not since then return end
			if cur.version == v or os.clock() - since >= LOT_MAX_WAIT then
				_lotPendingSince[key] = nil
				enqueue(key)
			end
		end)
		return
	end
	if _roadScheduled[key] then return end
	_roadScheduled[key] = true
	_scheduled += 1
	task.defer(function()
		_roadScheduled[key] = nil
		_scheduled -= 1
		if _cells[key] then enqueue(key) end
	end)
end

-- (Re)assign a road piece to its cell by pivot -- pieces can arrive before their
-- geometry replicates, so the cell is re-derived on every content change and the
-- piece migrates (rebaking both cells) if it landed somewhere new.
-- A piece RoadPieces draws (hidden) puts nothing in the bake: its blob is skipped and its plates
-- are hidden. So its arriving, its blob landing or changing, and its leaving change nothing on
-- screen, and must not re-bake the cell. They used to: every edit's server models replicate in
-- a beat after RoadPieces has drawn the new road, and each one re-baked the cell it landed in --
-- throwing away the bake already in flight for that cell (its version moved) and baking it
-- again. Coverage changing either way still re-bakes (RoadPieces.start's notify, below).
local function remap(child: Model)
	local key = cellKeyFor(child)
	local old = _cellOf[child]
	local wasBaked = old ~= nil and not _hidden[child]
	if _v2 and RoadPieces.coversModel(child.Name) and not _hidden[child] then setHidden(child, true) end
	local baked = not _hidden[child]
	if old == key then
		if wasBaked or baked then schedule(key, cellState(key).bakedVersion > 0) end
		return
	end
	if old then
		local ost = _cells[old]
		if ost then ost.models[child] = nil end
		if wasBaked then schedule(old, ost ~= nil and ost.bakedVersion > 0) end
	end
	_cellOf[child] = key
	local st = cellState(key)
	st.models[child] = true
	if baked then schedule(key, st.bakedVersion > 0) end
end

local function track(child)
	if not child:IsA("Model") or _conns[child] then return end
	local conns = {}
	_conns[child] = conns
	-- A lot's ground rewrites its blob in place when a road beside it changes.
	local function watchBlob(d: Instance)
		if d.Name == "RoadMeshSpecs" and d:IsA("StringValue") then
			table.insert(conns, d:GetPropertyChangedSignal("Value"):Connect(function() remap(child) end))
		end
	end
	for _, d in child:GetDescendants() do watchBlob(d) end
	-- The bake reads nothing but RoadMeshSpecs blobs -- anything else the sim parents
	-- under a piece at runtime (decal plates, sounds) must not trigger a cell rebake.
	table.insert(conns, child.DescendantAdded:Connect(function(d)
		if d.Name == "RoadMeshSpecs" then
			watchBlob(d)
			remap(child)
		elseif _hidden[child] and d:IsA("Decal") then
			d.LocalTransparencyModifier = 1
		end
	end))
	table.insert(conns, child.DescendantRemoving:Connect(function(d)
		if d.Name == "RoadMeshSpecs" then remap(child) end
	end))
	remap(child)
end

local function untrack(child)
	if _v2 then RoadPieces.releaseModel(child.Name) end
	local wasBaked = not _hidden[child]
	_hidden[child] = nil
	local conns = _conns[child]
	if conns then
		for _, c in conns do c:Disconnect() end
		_conns[child] = nil
	end
	local key = _cellOf[child]
	if key then
		_cellOf[child] = nil
		local st = _cells[key]
		if st then
			st.models[child] = nil
			if wasBaked then schedule(key, st.bakedVersion > 0) end
		end
	end
end

-- A cell is 256 studs across, so its half-diagonal is 181 -- judging it by its centre puts
-- the road directly under the camera a whole level too coarse. Tier on the cell's NEAREST
-- point instead: clamp the eye into the cell footprint.
local CELL_HALF = CELL_SIZE * 0.5

-- ...and the square is not where the cell's geometry actually IS. A piece is filed under the
-- cell of its blob's FIRST vertex (see cellKeyFor), so a long segment's far end -- which is
-- exactly where its crosswalk sits -- can lie hundreds of studs outside that square. Judged by
-- the square, such a cell flipped to FAR while the cell you were looking at was still MID, so
-- a crossing vanished with the dashes beside it still painted. Clamp into the cell's real
-- baked extent instead. Base slabs are never destroyed by the ladder, so their union is a
-- stable stand-in that does not move when the paint is dropped.
local function nearestPointIn(st: CellState, eye: Vector3): Vector3
	local lo, hi = st.boundsMin, st.boundsMax
	if not (lo and hi) then
		local c = st.center
		lo = Vector3.new(c.X - CELL_HALF, 0, c.Z - CELL_HALF)
		hi = Vector3.new(c.X + CELL_HALF, 0, c.Z + CELL_HALF)
	end
	-- Y stays 0 for the reason centreOf gives: altitude is most of how far away a road is.
	return Vector3.new(
		math.clamp(eye.X, lo.X, hi.X),
		0,
		math.clamp(eye.Z, lo.Z, hi.Z)
	)
end

-- One level per cell, not per mesh: half a cell changing look would read as a seam.
local function applyLevel(key: string, st: CellState, tier: number)
	if st.tier == tier then return end
	st.tier = tier

	local paint = if tier >= LOD.FAR then 1 else 0
	for _, m in st.details do
		if m.Transparency ~= paint then
			m.Transparency = paint
		end
	end
	for _, p in st.symbols do
		local d = p:FindFirstChildOfClass("Decal")
		if d then d.Transparency = paint end
	end

	-- Paint is only ever HIDDEN, never dropped (2026-10-01). Destroying it past CULL handed its
	-- memory back but cost a re-bake -- Luau triangle build plus a blocking mesh bake -- for every
	-- cell flown back inside MID: a hitch per 256-stud cell, the stutter of flying at boost. The
	-- load already bakes every cell's paint, so keeping it costs no more than the city had then.
	-- ponytail: detailsDropped/rebuildDetails/detailsOnly jobs are now unreachable; delete them
	-- once nobody wants the drop back on low-memory devices.
end

function RoadMeshView.Start()
	if _started then return end
	local city = workspace:WaitForChild("_City", FOLDER_WAIT)
	local roads = city and city:WaitForChild("Roads", FOLDER_WAIT)
	if not roads then
		warn("[RoadMeshView] workspace._City.Roads never appeared -- roads stay part-rendered")
		return
	end
	if _started then return end
	_started = true
	-- A Model (not a bare Folder) so the baked road pieces group like every other
	-- placeable. Pivot pinned to the origin -- a clean 1-decimal reference frame that
	-- doesn't drift (an unset Model pivot is the live bounding-box centre, 3 decimals).
	local container = Instance.new("Model")
	container.Name = "_RoadMeshes"
	container.Parent = workspace
	container.WorldPivot = CFrame.new(0, 0, 0)
	_meshFolder = container
	local lots = Instance.new("Model")
	lots.Name = "_LotMeshes"
	lots.Parent = workspace
	lots.WorldPivot = CFrame.new(0, 0, 0)
	_lotFolder = lots
	local flag = workspace:GetAttribute("RoadMeshV2")
	_v2 = if typeof(flag) == "boolean" then flag else RunService:IsStudio()
	if _v2 then
		-- Pieces RoadPieces rebuilt: rebake their cells, and the cells of any server piece it now
		-- draws (or no longer draws). Topology edits are rare; the scan is a flag per piece.
		RoadPieces.start(function(dirty)
			if next(_predictionTokens) then refreshPredictionCells() end
			-- A handful of cells is an edit and bakes live; the whole city at once is a load.
			local count = 0
			for _ in dirty do count += 1 end
			local live = count <= LIVE_MAX_BACKLOG
			for key in dirty do
				cellState(key)
				schedule(key, live)
			end
			for model, key in _cellOf do
				local hide = RoadPieces.coversModel(model.Name)
				if (_hidden[model] == true) ~= hide then
					setHidden(model, hide)
					schedule(key, live)
				end
			end
		end)
	end
	roads.ChildAdded:Connect(track)
	roads.ChildRemoved:Connect(untrack)
	for _, child in roads:GetChildren() do
		track(child)
	end
	-- Lot ground lives under its building (streamed in and out with it), found by tag.
	CollectionService:GetInstanceAddedSignal(RoadMeshBuilder.LOT_TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(RoadMeshBuilder.LOT_TAG):Connect(untrack)
	for _, m in CollectionService:GetTagged(RoadMeshBuilder.LOT_TAG) do
		track(m)
	end
	task.spawn(function()
		while true do
			task.wait(LOD_PERIOD)
			local cam = workspace.CurrentCamera
			if cam then
				local eye = cam.CFrame.Position
				-- Draw distance setting stretches the ladder for roads too.
				local scale = (tonumber(Settings.get("renderDistance")) or 1) * PAINT_RANGE_SCALE
				for key, st in _cells do
					applyLevel(key, st, LOD.tierAt(nearestPointIn(st, eye), eye, nil, scale))
				end
			end
		end
	end)
end

-- True when no road rebuild is waiting or baking on this client.
function RoadMeshView.isIdle(): boolean
	return _scheduled == 0 and _busyJobs == 0 and (not _v2 or RoadPieces.isIdle())
end

-- os.clock() of the last finished road (not paint-only) bake.
function RoadMeshView.lastBakeAt(): number
	return _lastBakeAt
end

return RoadMeshView
