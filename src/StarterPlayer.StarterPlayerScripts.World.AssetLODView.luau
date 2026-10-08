--!strict
-- AssetLODView -- client LOD for everything under workspace._City except Roads (RoadMeshView
-- runs its own ladder there).
--
-- STATIC MODELS ARE ALWAYS THE REAL MODEL. No baked meshes, no impostor pictures, no merged
-- cells. Roblox already batches identical parts and meshes into instanced draws, which is the
-- Cities: Skylines 2 recipe (instanced real meshes) with nothing to bake.
--
-- HOW A REAL LOD SWITCHES (2026-10-01 perf pass). A level change is ONE property write per
-- part, made once, from part lists cached per model -- the way an engine flips a mesh index.
-- What this view must never do again, because each one tanked the frame rate on its own:
--   * tween a swap. A part mid-fade has 0 < Transparency < 1, which drops it out of the
--     instanced batch into the sorted transparent pass; a zoom that crossed a band faded
--     thousands of parts at once (the 240 -> 8 fps dive). Swaps SNAP, and only past
--     LOD1_BUCKET / TREE_LOD1_BUCKET where a level is a few pixels tall.
--   * re-walk GetDescendants per swap. Each model's lists are built once and dropped only
--     when its parts change.
--   * follow the frame rate. Core.RenderPressure used to scale the distance, so a slow frame
--     moved every band edge, the whole city re-tiered, the next frames were slower still --
--     a feedback loop. Distance follows the Draw distance setting and nothing else.
--   * walk every parked car each sweep. Moving sets are checked a slice per sweep.
--
-- Past LOD1_BUCKET the LODTiers kits drop small kit props and see-through decoration; past
-- LOD2_BUCKET only their own <500-tri LOD_* model shows (those parts arrive Transparency 1).
-- Trees (NatureKit, attribute LOD 0/1/2) show the thinned mesh past TREE_LOD1_BUCKET and the
-- picture cards past TREE_LOD2_BUCKET. A part too small to cover half a pixel
-- (LOD.PIXEL_BUDGET) is hidden -- invisible by construction.
--
-- MOVING SETS (citizens, cars, trucks, buses, trains) are drawn whole until the whole model is
-- about a pixel, then hidden.
--
-- Client-only and non-destructive: LocalTransparencyModifier is restored exactly, and a part
-- another system already holds translucent is never touched.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LOD = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LOD"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
-- A lot's ground: a part-less spec model RoadMeshView bakes into workspace._LotMeshes. Hiding or
-- dropping one unbakes the lot's cell, so it is never treated as a prop.
local LOT_TAG: string = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadMeshBuilder")).LOT_TAG

local AssetLODView = {}

-- Distance buckets double from BUCKET_NEAR; bucket 0 hides nothing. Leaving a bucket needs 8%
-- past its edge, so a model resting on a boundary never re-applies every sweep.
local BUCKET_NEAR = 256
local MAX_BUCKET = 7
local HYSTERESIS = 0.08
-- renderDistance DIVIDES distance; the Settings "Draw distance" slider's range.
local RENDER_SCALE_MIN = 0.4
local RENDER_SCALE_MAX = 2
-- A resting camera (under REST_STUDS moved) with nothing new to settle skips the scan.
local SWEEP_PERIOD = 0.15
local REST_STUDS = 2
-- A camera moving faster than this skips the static sweep and catches up once it slows: at
-- that speed nothing on screen holds still long enough to read its level, and the swaps were
-- work landing exactly when the frame is busiest (user, 2026-10-01: "skip some things").
local FAST_STUDS_PER_SEC = 300
-- A model registers on ChildAdded, before its parts replicate, so its pivot is re-read for a
-- few sweeps instead of trusting the first one.
local SETTLE_SWEEPS = 24
-- Per frame for applying level changes; stragglers catch up on the next frame.
local TRANSITION_BUDGET_SECS = 0.003
-- Per frame for the scan of every static model; the rest waits for the next frame.
local SCAN_BUDGET_SECS = 0.001
-- Both budgets are for a 60 fps frame. A faster frame gets a proportional share (240 fps: a
-- quarter) and never more, so the work per SECOND -- and the wall time a scan or a band of
-- swaps takes -- is unchanged, but a 4 ms frame no longer spends 3 of them here.
local SIXTY_FPS_DT = 1 / 60
local _frameDt = SIXTY_FPS_DT
local function slice(atSixty: number): number
	return atSixty * math.clamp(_frameDt / SIXTY_FPS_DT, 0.25, 1)
end
-- Moving models stop being drawn once the WHOLE model is under this many pixels.
local CULL_MODEL_PX = 1
-- Moving models checked per sweep (round robin): a 12k-car city is covered every ~3 s
-- instead of walking every parked car 7 times a second.
local DYN_PER_SWEEP = 600
-- 512 / 1024 since 2026-10-01 (user, for the ~1M-triangle target; swaps are single writes now,
-- so they keep up with a fly-in -- what pushed them out to 1024 / 2048 on 2026-09-30).
local LOD1_BUCKET = 2 -- 512 studs and out
local LOD2_BUCKET = 3 -- 1024 studs and out
local KEEP_PROP_STUDS = 6 -- a kit prop this tall (the plant: stacks, silos, tanks) stays at LOD1
-- Industrial Grime/Marking/Grate, commercial kit v2 Fence/Rail/Lines (see also Detail_Fence<i> below).
local LOD1_DROP: { [string]: boolean } = table.freeze({ Detail_Grime = true, Detail_Marking = true, Detail_Grate = true,
	Detail_Fence = true, Detail_Rail = true, Detail_Lines = true,
	-- transit kit ground paint (Layout<i>_Lines / _Paint are matched by pattern below)
	Detail_Paint = true, Detail_Paint2 = true })
local TREE_LOD1_BUCKET = 2 -- 512 studs and out: the thinned tree
local TREE_LOD2_BUCKET = 3 -- 1024 studs and out: the picture cards
-- Neon and lit parts glow well past their size: kept through this bucket (2048 studs).
local LIGHT_BUCKET = 3

local DYNAMIC: { [string]: boolean } = table.freeze({
	Citizens = true,
	NPCDrivers = true,
	NPCWalkers = true,
	Trucks = true,
	Buses = true,
	Trains = true,
})
local OWNED: { [string]: boolean } = table.freeze({
	Roads = true,
})

-- A model's parts sorted into what each level touches. Built once, dropped when parts change.
type Cache = {
	tree: { { BasePart } }, -- [1] LOD 0, [2] LOD 1, [3] LOD 2 tree parts
	shell: { BasePart }, -- LOD2 parts
	shellT: { number }, -- ...and the transparency each shows at
	t2hide: { BasePart }, -- everything tier 2 hides
	t1drop: { BasePart }, -- small props and decoration tier 1 hides
	trim: { BasePart }, -- every other part, smallest first
	trimSize: { number },
	trimLight: { boolean },
}
type Entry = {
	pos: Vector3,
	settle: number,
	bucket: number, -- -1 = nothing applied (held by the reveal)
	target: number, -- bucket queued by the last scan
	dirty: boolean, -- parts changed: re-apply even if the bucket did not
	cache: Cache?,
	conns: { RBXScriptConnection },
	hidden: { [BasePart]: boolean }, -- parts this entry holds at LocalTransparencyModifier 1
	shown: { [BasePart]: number }, -- level parts made visible -> their Transparency
}
local _entries: { [Model]: Entry } = {}
-- The same models as an array, so the sliced scan can walk them across frames while
-- register() appends (a dictionary cannot be resumed with next() once it rehashes).
local _list: { Model } = {}
-- Parts whose LocalTransparencyModifier this view has written.
local _ours: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local _dirtySweeps = 0 -- scans still owed even if the camera rests
local _lastEye = Vector3.zero
local _lastScale = 0
local _speedEye = Vector3.zero
local _speedAt = 0

-- YARD DECOR OFF (Settings.yardDecor, the Low / Medium presets): a lot's prop models --
-- fences, AC units, bins, garden trees -- leave this client's world. Not hidden: the engine
-- pays for a hidden part nearly as much as a drawn one (measured: LocalTransparencyModifier
-- on 13k props saved 0.5 ms of render CPU, removing 33k saved ~3 ms). The lot's own ground
-- (LOT_TAG) and plain lot parts stay. Client-only; the server's city is untouched.
local DECOR_BATCH = 40 -- models per frame when the setting flips
local _decorOn = true
local _stripped: { [Instance]: Instance } = {} -- prop -> the Yard it was taken from
local _decorJob = 0

local function isDecor(prop: Instance): boolean
	return prop:IsA("Model") and prop.Parent ~= nil and prop.Parent.Name == "Yard"
		and not CollectionService:HasTag(prop, LOT_TAG)
end

local function stripModel(model: Model)
	for _, yard in model:GetChildren() do
		if yard.Name ~= "Yard" then
			continue
		end
		for _, prop in yard:GetChildren() do
			if isDecor(prop) then
				_stripped[prop] = yard
				prop.Parent = nil
			end
		end
	end
end

local function setDecor(on: boolean)
	if on == _decorOn then
		return
	end
	_decorOn = on
	_decorJob += 1
	local job = _decorJob
	task.spawn(function()
		local n = 0
		if on then
			-- A snapshot: the loop yields, and the table must not be walked across a clear.
			local props: { Instance } = {}
			for prop in _stripped do
				table.insert(props, prop)
			end
			for _, prop in props do
				local yard = _stripped[prop]
				_stripped[prop] = nil
				if yard and yard.Parent then
					pcall(function() prop.Parent = yard end)
				end
				n += 1
				if n % (DECOR_BATCH * 4) == 0 then
					task.wait()
					if job ~= _decorJob then return end
				end
			end
		else
			for i = #_list, 1, -1 do
				local model = _list[i]
				if model and model.Parent then
					stripModel(model)
				end
				n += 1
				if n % DECOR_BATCH == 0 then
					task.wait()
					if job ~= _decorJob then return end
				end
			end
		end
	end)
end

local function register(child: Instance)
	if child:IsA("Folder") then
		child.ChildAdded:Connect(register)
		for _, c in child:GetChildren() do
			register(c)
		end
		return
	end
	if not child:IsA("Model") or _entries[child] then
		return
	end
	local e: Entry = {
		pos = child:GetPivot().Position,
		settle = SETTLE_SWEEPS,
		bucket = 0,
		target = 0,
		dirty = false,
		cache = nil,
		conns = {},
		hidden = {},
		shown = {},
	}
	local function changed(d: Instance?)
		if d and not _decorOn and isDecor(d) then
			-- dressing that arrives after the building: out on the next frame
			task.defer(function()
				if not _decorOn and isDecor(d) then
					_stripped[d] = d.Parent :: Instance
					d.Parent = nil
				end
			end)
		end
		e.cache = nil
		if e.bucket > 0 then
			e.dirty = true
			_dirtySweeps = math.max(_dirtySweeps, 1)
		end
	end
	table.insert(e.conns, child.DescendantAdded:Connect(changed))
	table.insert(e.conns, child.DescendantRemoving:Connect(changed))
	_entries[child] = e
	table.insert(_list, child)
	_dirtySweeps = SETTLE_SWEEPS
	if not _decorOn then
		stripModel(child)
	end
end

local function isLight(p: BasePart): boolean
	return p.Material == Enum.Material.Neon or p.Name:sub(1, 4) == "Lens" or p:FindFirstChildWhichIsA("Light") ~= nil
end

local function buildCache(model: Model): Cache
	local c: Cache = {
		tree = { {}, {}, {} }, shell = {}, shellT = {}, t2hide = {}, t1drop = {},
		trim = {}, trimSize = {}, trimLight = {},
	}
	local dropProp: { [Instance]: boolean } = {}
	if model:GetAttribute("LODTiers") then
		for _, yard in model:GetChildren() do
			if yard.Name ~= "Yard" then
				continue
			end
			for _, prop in yard:GetChildren() do
				if prop:IsA("Model") and not CollectionService:HasTag(prop, LOT_TAG)
					and prop:GetExtentsSize().Y < KEEP_PROP_STUDS then
					dropProp[prop] = true
				end
			end
		end
	end
	type Trim = { p: BasePart, s: number, l: boolean }
	local trims: { Trim } = {}
	for _, d in model:GetDescendants() do
		if not d:IsA("BasePart") then
			continue
		end
		local p = d :: BasePart
		local lod = p:GetAttribute("LOD")
		local isShell = p:GetAttribute("LOD2") == true
		if isShell then
			table.insert(c.shell, p)
			table.insert(c.shellT, (p:GetAttribute("LODTransparency") :: number?) or 0)
		elseif not p:GetAttribute("LODKeep") and not (p.Parent and (p.Parent.Name == "Yard"
			or CollectionService:HasTag(p.Parent, LOT_TAG))) then
			table.insert(c.t2hide, p)
		end
		if typeof(lod) == "number" and lod >= 0 and lod <= 2 then
			table.insert(c.tree[lod + 1], p)
			if lod > 0 then
				continue -- tree levels 1-2 are hidden until shown; never trimmed
			end
		end
		if isShell then
			continue
		end
		local owner = p:FindFirstAncestorOfClass("Model")
		if LOD1_DROP[p.Name] == true or p.Name:match("^Detail_Fence%d$") ~= nil
			or p.Name:match("^Layout%d+_") ~= nil or (owner ~= nil and dropProp[owner] == true) then
			table.insert(c.t1drop, p)
		end
		local s = p.Size
		table.insert(trims, { p = p, s = math.max(s.X, s.Y, s.Z), l = isLight(p) })
	end
	table.sort(trims, function(a, b) return a.s < b.s end)
	for i, t in trims do
		c.trim[i], c.trimSize[i], c.trimLight[i] = t.p, t.s, t.l
	end
	return c
end

local function restore(e: Entry)
	for p in e.hidden do
		if p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
	table.clear(e.hidden)
	for p in e.shown do
		if p.Parent then
			p.Transparency = 1
		end
	end
	table.clear(e.shown)
end

local function nearEdge(b: number): number
	return if b <= 0 then 0 else BUCKET_NEAR * 2 ^ (b - 1)
end

local function bucketAt(dist: number, current: number): number
	local b = if dist < BUCKET_NEAR then 0 else math.min(math.floor(math.log(dist / BUCKET_NEAR, 2)) + 1, MAX_BUCKET)
	if current >= 0 and b ~= current then
		local lo = nearEdge(current) * (1 - HYSTERESIS)
		local hi = if current >= MAX_BUCKET then math.huge else nearEdge(current + 1) * (1 + HYSTERESIS)
		if dist >= lo and dist < hi then
			return current
		end
	end
	return b
end

-- Works out what this bucket hides and which level parts it shows, then writes only the
-- difference from what the entry already has.
local function apply(model: Model, e: Entry, bucket: number)
	local wasHidden, wasShown = e.hidden, e.shown
	local hidden: { [BasePart]: boolean } = {}
	local shown: { [BasePart]: number } = {}
	e.bucket = bucket
	e.dirty = false
	local function free(p: BasePart): boolean
		return wasHidden[p] ~= nil or _ours[p] == true or p.LocalTransparencyModifier == 0
	end
	if bucket > 0 then
		local c = e.cache
		if not c then
			c = buildCache(model)
			e.cache = c
		end
		local treeLevel = if bucket >= TREE_LOD2_BUCKET then 2 elseif bucket >= TREE_LOD1_BUCKET then 1 else 0
		if treeLevel > 0 then
			for _, p in c.tree[treeLevel + 1] do
				shown[p] = 0
			end
			for _, p in c.tree[1] do
				if free(p) then
					hidden[p] = true
				end
			end
		end
		local tier = if not model:GetAttribute("LODTiers") then 0
			elseif bucket >= LOD2_BUCKET then 2
			elseif bucket >= LOD1_BUCKET then 1
			else 0
		if tier == 2 then
			-- Only the LOD_* model, plus the plain lot parts the dressing laid.
			for i, p in c.shell do
				shown[p] = c.shellT[i]
			end
			for _, p in c.t2hide do
				if free(p) then
					hidden[p] = true
					shown[p] = nil -- a yard tree's level: tier 2 is the LOD_* model alone
				end
			end
		else
			if tier == 1 then
				for _, p in c.t1drop do
					if hidden[p] == nil and shown[p] == nil and free(p) then
						hidden[p] = true
					end
				end
			end
			-- Judged at the bucket's near edge, where parts look biggest: anything under the
			-- budget there is under it everywhere the bucket reaches.
			local minStuds = LOD.PIXEL_BUDGET / LOD.pixelsPerStud(nearEdge(bucket))
			local keepLights = bucket <= LIGHT_BUCKET
			local sizes, lights = c.trimSize, c.trimLight
			for i, p in c.trim do
				if sizes[i] >= minStuds then
					break
				end
				if hidden[p] == nil and shown[p] == nil and not (keepLights and lights[i]) and free(p) then
					hidden[p] = true
				end
			end
		end
	end
	for p in wasHidden do
		if hidden[p] == nil and p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
	for p in hidden do
		if wasHidden[p] == nil then
			_ours[p] = true
			p.LocalTransparencyModifier = 1
		end
	end
	for p in wasShown do
		if shown[p] == nil and p.Parent then
			p.Transparency = 1
		end
	end
	for p, t in shown do
		if wasShown[p] ~= t then
			p.Transparency = t
		end
	end
	e.hidden, e.shown = hidden, shown
end

-- ---- moving things -----------------------------------------------------------------------

-- MESH-KIT VEHICLES (blender/vehicle_kit.py) ship a ~120-tri BodyLOD. NPCDriverView swaps it in
-- for cars that are DRIVING (tagged NPCDriver); a parked car is untagged and swaps here on
-- NPCDriverView's own rule, once the full mesh's difference from the LOD (LodError, studs) is
-- under half a pixel -- invisible by construction.
local KIT_LOD_ENTER_PX, KIT_LOD_EXIT_PX = 0.5, 0.65
local DRIVER_TAG = "NPCDriver"

type Dyn = {
	extent: number,
	settle: number,
	gone: boolean,
	hidden: { BasePart },
	root: BasePart?,
	kitErr: number, -- LodError; 0 = not a mesh-kit vehicle
	kitFull: { BasePart },
	kitLods: { BasePart },
	kitLod: boolean?, -- nil = not applied by this view yet
	isKit: boolean,
}
local _dyn: { [Model]: Dyn } = {}
local _dynCursor: Model? = nil

local function measureKit(model: Model, d: Dyn)
	local err = model:GetAttribute("LodError")
	if typeof(err) ~= "number" then
		return
	end
	local before = #d.kitFull + #d.kitLods
	table.clear(d.kitFull)
	table.clear(d.kitLods)
	for _, p in model:GetChildren() do
		if not p:IsA("BasePart") then
			continue
		end
		if p.Name == "BodyLOD" or p.Name == "TrailerLOD" then
			table.insert(d.kitLods, p)
		elseif p.Name == "Body" or p.Name == "Trailer" or p.Name == "Brake" or p:GetAttribute("Wheel") then
			table.insert(d.kitFull, p)
		end
	end
	d.kitErr = if #d.kitLods > 0 then err else 0
	if #d.kitFull + #d.kitLods ~= before then
		d.kitLod = nil -- parts arrived since: apply again
	end
end

local function measureDynamic(model: Model, d: Dyn)
	d.extent = model:GetExtentsSize().Magnitude
	d.root = model.PrimaryPart
	d.isKit = model:GetAttribute("MeshKit") == true
	if d.isKit then
		measureKit(model, d)
	end
end

local function setKitLod(d: Dyn, on: boolean)
	d.kitLod = on
	for _, p in d.kitFull do
		p.Transparency = if on then 1 else 0
	end
	for _, p in d.kitLods do
		p.Transparency = if on then 0 else 1
	end
end

local function registerDynamic(child: Instance)
	if not child:IsA("Model") or _dyn[child] then
		return
	end
	local d: Dyn = {
		extent = 0, settle = SETTLE_SWEEPS, gone = false, hidden = {}, root = nil,
		kitErr = 0, kitFull = {}, kitLods = {}, kitLod = nil, isKit = false,
	}
	measureDynamic(child, d)
	_dyn[child] = d
end

local function restoreDynamic(d: Dyn)
	for _, x in d.hidden do
		if x.Parent then
			x.LocalTransparencyModifier = 0
		end
	end
	table.clear(d.hidden)
end

-- Parts are hidden only once the whole model is under the cull.
local function applyDynamic(model: Model, d: Dyn, gone: boolean)
	restoreDynamic(d)
	d.gone = gone
	if not gone then
		return
	end
	for _, x in model:GetDescendants() do
		if x:IsA("BasePart") and x.LocalTransparencyModifier == 0 then
			x.LocalTransparencyModifier = 1
			table.insert(d.hidden, x)
		end
	end
end

local function checkDynamic(model: Model, d: Dyn, eye: Vector3, scale: number, pxPerStud: number)
	-- A car the server built in place reaches us in pieces, and a city restore can outlast the
	-- settle window: anything still unmeasured keeps being looked at.
	if d.settle > 0 or d.extent <= 0 then
		d.settle = math.max(d.settle - 1, 0)
		measureDynamic(model, d)
	elseif d.isKit and d.kitErr == 0 then
		measureKit(model, d)
	end
	if d.extent <= 0 then
		return
	end
	local root = d.root
	local dist = math.max((eye - (if root then root.Position else model:GetPivot().Position)).Magnitude, 1e-3)
	local gone = pxPerStud * scale / dist * d.extent < CULL_MODEL_PX
	if gone ~= d.gone then
		applyDynamic(model, d, gone)
	end
	if d.kitErr > 0 and not gone then
		if CollectionService:HasTag(model, DRIVER_TAG) then
			d.kitLod = nil -- NPCDriverView's while it drives; re-applied once it parks
		else
			local px = d.kitErr * pxPerStud / dist
			local lod = if d.kitLod then px < KIT_LOD_EXIT_PX else px < KIT_LOD_ENTER_PX
			if lod ~= d.kitLod then
				setKitLod(d, lod)
			end
		end
	end
end

-- pxPerStud: screen pixels per stud at 1 stud away, read off the camera once per sweep.
local function sweepDynamic(eye: Vector3, scale: number, pxPerStud: number)
	for _ = 1, DYN_PER_SWEEP do
		local model, d = next(_dyn, _dynCursor)
		if not model then
			_dynCursor = nil
			model, d = next(_dyn)
			if not model then
				return
			end
		end
		if not model.Parent then
			_dyn[model] = nil -- next() off a removed key is fine: the cursor moves past it below
			_dynCursor = nil
			continue
		end
		_dynCursor = model
		checkDynamic(model, d :: Dyn, eye, scale, pxPerStud)
	end
end

-- ---- binding -------------------------------------------------------------------------------

-- Street furniture rides INSIDE the road pieces: RoadSceneRenderer parents a segment's lamps,
-- street trees, name blades and yield signs to its Segment_/Junction_ model. RoadMeshView owns
-- the road surface, not these, so they used to get no ladder at all -- every street tree full
-- mesh and every lamp part drawn at any distance, avenue after avenue. Each furniture model is
-- taken here like any other prop (the pieces themselves stay RoadMeshView's).
local function adoptRoadPiece(piece: Instance)
	if not piece:IsA("Model") then
		return
	end
	piece.ChildAdded:Connect(register)
	for _, c in piece:GetChildren() do
		register(c)
	end
end

local function adopt(folder: Instance)
	if folder:IsA("Folder") and folder.Name == "Roads" then
		folder.ChildAdded:Connect(adoptRoadPiece)
		for _, c in folder:GetChildren() do
			adoptRoadPiece(c)
		end
		return
	end
	if not folder:IsA("Folder") or OWNED[folder.Name] then
		return
	end
	local reg = if DYNAMIC[folder.Name] then registerDynamic else register
	folder.ChildAdded:Connect(reg)
	for _, c in folder:GetChildren() do
		reg(c)
	end
end

-- Polled, not listened for: RoadSceneRenderer RENAMES an existing folder to "_City", and
-- ChildAdded never fires on a rename.
local _boundCity: Instance? = nil
local function pollCity()
	local city = Workspace:FindFirstChild("_City")
	if city == _boundCity or not (city and city:IsA("Folder")) then
		return
	end
	_boundCity = city
	city.ChildAdded:Connect(adopt)
	for _, f in city:GetChildren() do
		adopt(f)
	end
end

-- WorldRevealController suspends the ladder for the instant it hides the city, then installs a
-- hold predicate for the animation so held models are skipped.
local _suspended = false
local _cityLoaded = false
local _holdPredicate: ((Model) -> boolean)? = nil

local function drop(i: number)
	local model = _list[i]
	local e = _entries[model]
	if e then
		for _, c in e.conns do
			c:Disconnect()
		end
	end
	_entries[model] = nil
	_list[i] = _list[#_list]
	_list[#_list] = nil
end

local function sweepStatic(eye: Vector3, scale: number)
	if _dirtySweeps <= 0 and not _holdPredicate and scale == _lastScale
		and (eye - _lastEye).Magnitude < REST_STUDS then
		return
	end
	local now = os.clock()
	local speed = (eye - _speedEye).Magnitude / math.max(now - _speedAt, 1e-3)
	_speedEye, _speedAt = eye, now
	if speed > FAST_STUDS_PER_SEC and not _holdPredicate then
		_dirtySweeps = math.max(_dirtySweeps, 1) -- owed once the camera slows
		return
	end
	_dirtySweeps -= 1
	_lastEye = eye
	_lastScale = scale

	-- A model coming closer queues by the band it lands in, nearest band first; thinning a model
	-- going away waits behind all of them.
	local queue: { { Model } } = {}
	local scanEnd = os.clock() + slice(SCAN_BUDGET_SECS)
	local i = 1
	while i <= #_list do
		if i % 64 == 0 and os.clock() >= scanEnd then
			_frameDt = task.wait()
			if _suspended or not _cityLoaded then
				return
			end
			scanEnd = os.clock() + slice(SCAN_BUDGET_SECS)
		end
		local model = _list[i]
		local e = _entries[model]
		if not e or not model:IsDescendantOf(Workspace) then
			drop(i)
			continue
		end
		i += 1
		if _holdPredicate and _holdPredicate(model) then
			-- Left as is; -1 forces a clean apply once the hold lifts.
			e.bucket = -1
			continue
		end
		if e.settle > 0 then
			e.settle -= 1
			e.pos = model:GetPivot().Position
		end
		local bucket = bucketAt((eye - e.pos).Magnitude / scale, e.bucket)
		if bucket ~= e.bucket or e.dirty then
			e.target = bucket
			local slot = if bucket < e.bucket then bucket + 1 else MAX_BUCKET + 2
			local q = queue[slot]
			if not q then
				q = {}
				queue[slot] = q
			end
			table.insert(q, model)
		end
	end

	-- The swaps get a frame of their own, and spread over the next ones if there are many.
	_frameDt = task.wait()
	if _suspended or not _cityLoaded then
		return
	end
	local deadline = os.clock() + slice(TRANSITION_BUDGET_SECS)
	for slot = 1, MAX_BUCKET + 2 do
		for _, model in queue[slot] or {} do
			local e = _entries[model]
			if not e or (_holdPredicate and _holdPredicate(model)) then
				continue
			end
			if os.clock() >= deadline then
				_frameDt = task.wait()
				if _suspended or not _cityLoaded then
					return
				end
				deadline = os.clock() + slice(TRANSITION_BUDGET_SECS)
			end
			apply(model, e, e.target)
		end
	end
end

local function sweep()
	if _suspended or not _cityLoaded then
		return
	end
	pollCity()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local eye = cam.CFrame.Position
	local scale = math.clamp(tonumber(Settings.get("renderDistance")) or 1, RENDER_SCALE_MIN, RENDER_SCALE_MAX)
	local pxPerStud = cam.ViewportSize.Y * 0.5 / math.tan(math.rad(cam.FieldOfView) * 0.5)
	sweepDynamic(eye, scale, pxPerStud)
	sweepStatic(eye, scale)
end

local function releaseWorld()
	_dirtySweeps = math.max(_dirtySweeps, 1) -- whatever resumes the ladder re-applies it
	for _, e in _entries do
		restore(e)
		e.bucket = 0
	end
	for _, d in _dyn do
		restoreDynamic(d)
		d.gone = false
	end
end

function AssetLODView.setHoldPredicate(fn: ((Model) -> boolean)?)
	_holdPredicate = fn
	_dirtySweeps = math.max(_dirtySweeps, 1) -- held models are re-applied once it lifts
end

function AssetLODView.setSuspended(on: boolean)
	if _suspended == on then
		return
	end
	_suspended = on
	if on then
		releaseWorld()
	end
end

-- Open between UIEvents.GameEntered and ReturnToMainMenu; nothing is tiered behind the menu.
function AssetLODView.setCityLoaded(on: boolean)
	if _cityLoaded == on then
		return
	end
	_cityLoaded = on
	if not on then
		releaseWorld()
	end
end

local _started = false

function AssetLODView.Start()
	if _started then
		return
	end
	_started = true

	task.spawn(function()
		while true do
			task.wait(SWEEP_PERIOD)
			local ok, err = pcall(sweep)
			if not ok then
				warn("[AssetLODView] sweep failed: " .. tostring(err))
			end
		end
	end)

	local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")) :: any
	UIEvents.GameEntered.Event:Connect(function()
		AssetLODView.setCityLoaded(true)
	end)
	UIEvents.ReturnToMainMenu.Event:Connect(function()
		AssetLODView.setCityLoaded(false)
		table.clear(_stripped) -- that city is gone; nothing to hand back
	end)
	setDecor(Settings.get("yardDecor") ~= false)
	Settings.onChanged("yardDecor", function(v)
		setDecor(v ~= false)
	end)
end

return AssetLODView
