--!strict
-- Client-only: the ground, as one MeshPart per heightmap chunk under workspace._Ground.
-- Geometry comes from TerrainMesh (pure); this owns the Instances, the LOD and the budget.
--
-- Why a mesh instead of workspace.Terrain voxels:
--   * UNDERGROUND EXISTS. The ground is a hollow shell, so everything below it is empty
--     space -- pipes, sewers, tunnels and metro boxes just go there, and UndergroundView
--     x-rays the shell so you can see them. Voxel terrain is solid and has no transparency.
--   * NO STAIR EDGES. A voxel column surfaces at the mean of its tile's four corners on a
--     4-stud lattice; a mesh interpolates the corners exactly.
--   * LOD IS OURS, and it answers to the SHAPE as much as to the distance. Every chunk is
--     drawn at the coarsest stride that is geometrically lossless (TerrainMesh.losslessStep),
--     so ground levelled flat is two triangles no matter how close the camera gets, and it
--     regains its detail the instant anything is sculpted there. Distance coarsens on top
--     of that, except on chunks the city has built on -- Roblox renders far terrain off a
--     coarser voxel grid, and that is what swallowed roads at distance (see
--     TerrainGradeService), so distance never takes detail away from a road. Flatness still
--     may: dropping detail the ground does not have cannot hurt anything standing on it.
--   * CHEAP ON LOW-END. These parts are Anchored, CanCollide/CanQuery/CanTouch false,
--     CastShadow false and carry Box collision only -- no collision geometry, no physics,
--     no per-frame work beyond a distance scan every MESH_LOD_REFRESH seconds.
--
-- Picking does NOT come back through these parts: a heightfield cannot be given real
-- collision (PreciseConvexDecomposition on one 64x64 chunk measured 5.8 SECONDS), so
-- CursorRay marches the heightmap analytically instead. That is also why they are cheap.
--
-- Far chunks ARE merged into 4x4 blocks now -- see THE BACKDROP below. That was written here
-- as a draw-call note; what actually forced it was LOAD TIME, because a chunk's cost turned
-- out to be its bake (~30 ms, flat, whatever the triangle count) rather than its geometry.
-- A full map is ~300 parts rather than 1,024, so the draw calls came down with it.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainMesh = require(ReplicatedStorage.Terrain.TerrainMesh)
local TerrainSurfaceTexture = require(ReplicatedStorage.Terrain.TerrainSurfaceTexture)
local LOD = require(ReplicatedStorage.Shared.LOD)

local TerrainMeshView = {}

local CHUNKS = Constants.CHUNKS_PER_AXIS
local CHUNK_STUDS = Constants.CHUNK_STUDS
local HALF = Constants.MAP_HALF_EXTENT
local STEPS = Constants.MESH_LOD_STEPS
local BUDGET = Constants.MESH_BUILD_BUDGET
local REFRESH = Constants.MESH_LOD_REFRESH
local FLAT_TOL = Constants.MESH_FLAT_TOLERANCE
local BLOCKS = Constants.CHUNK_TILES // Constants.MESH_BLOCK_TILES
-- How far from the camera the x-ray rebuilds the ground without its seam skirts. Past this the
-- curtains are too far off to read as boxes, and rebuilding them is a bake per frame for nothing.
local SKIRTLESS_RANGE = 2048

-- No part Material texture. A Material is projected onto a MeshPart from the part's own
-- GEOMETRY and ignores mesh UVs (measured: two plates whose UVs differed 8x rendered
-- identically), so it is anchored to the shape -- and sculpting changes the shape and the
-- bounding box on every tick, which drags the texture along with it. That is what "the
-- texture moves while I sculpt" was.
--
-- The grain comes from TextureContent instead, which DOES sample mesh UVs, and TerrainMesh
-- writes those straight from world x/z. The texture is therefore pinned to the world and
-- cannot move no matter what the heights do. SmoothPlastic so nothing projects underneath
-- it, and the vertex colours tint it green/sand/grey per material zone.
--
-- MATTE, not SmoothPlastic. TextureContent replaces what the material would have drawn, but
-- the material still decides how the surface RESPONDS to light, and SmoothPlastic is glossy
-- enough to put a sheet of sun glare across the whole map. Ground does not shine.
local GROUND_MATERIAL = Enum.Material.Concrete
local WHITE = Color3.new(1, 1, 1)

type State = { part: MeshPart?, step: number, em: EditableMesh? }

local _states: { [number]: State } = {}
local _pinned: { [number]: boolean } = {}
local _queue: { number } = {}
local _queued: { [number]: boolean } = {}
-- Queued because the ground itself CHANGED there, as opposed to queued because the chunk
-- needs redrawing at another stride. Only the first kind has to pull its neighbours along,
-- and telling them apart is what stops a rebuild from cascading (see buildChunk).
local _shapeDirty: { [number]: boolean } = {}
-- The shape change waiting on these came from the CITY (a road graded, a pad levelled, a patch from
-- the server), not from this player's brush. See markDirty.
local _cityShape: { [number]: boolean } = {}
-- Forward-declared: buildChunk requeues neighbours, and it is defined above the queue.
local enqueue: (key: number) -> ()
local _sampleY: ((number, number) -> number)? = nil
-- Roads drawn on this client (RoadPieces) hold the ground down where they cross it: cap(gx, gz)
-- is the highest the ground may stand at that corner, nil where no road is near. Visual only --
-- the heightmap (picking, the server's sim) keeps its own heights.
local _groundCap: ((number, number) -> number?)? = nil
local _sampleMat: ((number, number) -> number)? = nil
local _ensureData: ((number) -> boolean)? = nil
-- Per-chunk stride error bounds (TerrainMesh.strideErrors): per block for strides 2-8, per
-- chunk for the merged strides. Memoised because computing them reads the chunk's whole corner
-- grid; dropped whenever that chunk's ground changes.
type Errors = { blocks: { number }, chunk: { [number]: number } }
local _errs: { [number]: Errors } = {}
-- The distance bucket every drawn chunk was last BUILT at, whether it draws itself or sits in a
-- backdrop block. The hysteresis in bucketOf is measured against this.
local _drawn: { [number]: number } = {}
-- Per-block shore caps (TerrainMesh.shoreCaps), dropped with _errs. `false` = this chunk
-- never meets the waterline, which is the answer for most of the map.
local _caps: { [number]: { number } | false } = {}
local _heightsOf: ((number) -> buffer?)? = nil
-- The bulk sampler handed to TerrainMesh (see makeFillRow): rows straight off the chunk buffers.
-- nil until setSource is given chunkHeights; the per-corner path is then used as before.
local _fillRow: TerrainMesh.FillRow? = nil
local makeFillRow: (capped: (number, number) -> number, chunkHeights: (number) -> buffer?) -> TerrainMesh.FillRow
-- Per-chunk form of _groundCap: the memoised cap table for a chunk (0-based corner index
-- lz * 65 + lx), or nil where no road holds the ground down. Lets a row skip the per-corner call.
local _groundCapChunk: ((number) -> { [number]: number }?)? = nil
-- A sculpting stroke in progress: the chunks it has touched, and per chunk the blocks it
-- has touched. See editArea for why both are held for the whole stroke rather than per tick.
local _editChunks: { [number]: boolean } = {}
local _editFine: { [number]: { [number]: boolean } } = {}
local _editBusy = false
-- Chunks currently held by a live EditableMesh, least-recently-brushed first. A brush spans
-- at most four chunks at once, but a long drag crosses many, and each one it left behind
-- would otherwise keep its reservation until the stroke ended. Bounded, not unbounded.
local _liveOrder: { number } = {}
-- A brush over a chunk CORNER touches four chunks, and pinning a border block pulls their
-- neighbours in too, so four was low enough that an ordinary stroke near a seam evicted a
-- chunk every tick -- and every eviction is a full static re-bake.
local MAX_LIVE = 9
local BLOCK_TILES = Constants.MESH_BLOCK_TILES
local BLOCK_STUDS = BLOCK_TILES * Constants.SAMPLE_SPACING
local MAX_BLOCK = CHUNKS * BLOCKS - 1
local _folder: Folder? = nil
local _running = false
local _accum = 0
local _underground = false

-- ---------------------------------------------------------------------------
-- THE BACKDROP -- far ground drawn as ONE mesh per SUPER x SUPER block of chunks.
--
-- A chunk's cost is its BAKE and almost nothing else. Measured in this place:
-- CreateDataModelContentAsync + CreateMeshPartAsync is ~30 ms whether the mesh holds 8
-- triangles or 2,000, and the geometry that feeds it is 1-4 ms. So distance LOD -- which is
-- what makes the far map cheap to DRAW -- buys nothing whatsoever on LOAD: an 8-triangle
-- chunk five kilometres away pays the same 30 ms as a city chunk at 2,048 triangles, and
-- 1,024 of them is ~32 seconds of pure API overhead sitting in front of the player.
-- Merged, 49 far chunks bake in 34 ms against 1.5 s built one at a time.
--
-- NOTHING HERE CHANGES WHAT THE GROUND LOOKS LIKE. Every member chunk is still built by
-- TerrainMesh.buildChunk through the same global strideAt, so blocks stitch across a
-- super-chunk seam exactly as they stitch across a chunk seam -- there is no separate case
-- for it, the same way there is none for a chunk boundary. The merge itself is a pure
-- translation and TerrainMesh.spec pins it as one.
--
-- DISTANCE DOES NOT DECIDE THIS. Merging only the FAR map was the first version and it left
-- the near chunks loose, which is where the time actually was: measured on a full map, merging
-- past 1,800 studs took 12.4 s and merging everything took 5.3 s. Near ground merges too.
--
-- What is excluded is what the city has TOUCHED -- see _solo. Excluding it per MEMBER rather
-- than per block is the other half of the number: a block is 16 chunks, and disqualifying all
-- 16 because one was built on cost 7.0 s against 5.3 s on a map with a 36-chunk city.
--
-- 4 and not 8: 8x8 is faster still (2.8 ms per chunk against 4.0) but a MeshPart's extents cap
-- at 2,048 studs and 8 chunks is 2,048 exactly before the ground's own height is added, and a
-- 2,048-stud block re-tiers as one ~180 ms rebuild when the camera crosses an LOD ring.
-- 4x4 is the compromise -- ~65-220 ms of work per rebuild, which DID show up while panning
-- (240 -> 15 fps), so past the loading screen a rebuild is sliced across frames (see breathe).
local SUPER = 4
local SUPERS = CHUNKS // SUPER
-- One EditableMesh will not hold unlimited geometry: past a limit AddTriangle throws
-- "Triangle count above limit" outright rather than degrading, and a block that throws is
-- ground nobody draws. The exact cap is somewhere between 8,192 and 32,768 triangles and is
-- not worth pinning down, because this is checked BEFORE the bake -- the member geometry
-- already knows its triangle count -- and a block over budget simply hands its chunks back to
-- the per-chunk path, which costs speed and nothing else.
local TRI_BUDGET = 20000

-- sig: the member buckets (and underground flag) the parts were built at; nil = not reusable
-- (built before a shape or membership change it no longer matches). tris: what it draws.
type Super = { parts: { MeshPart }, members: { number }, sig: string?, buckets: { [number]: number }?, tris: number? }
local _supers: { [number]: Super } = {}

-- LOD FOLLOWS THE CAMERA (2026-10-07). The ladder was FROZEN at the load (see bucketOf) because
-- every re-tier was a block rebuild ending in a blocking bake, and a camera arriving somewhere
-- queued dozens of them (flying to the map edge sat at 20 fps for ~10 s). Three things make it
-- affordable to let it move again:
--   * VARIANTS. A block that re-tiers keeps the parts it had, parked (unparented), keyed by the
--     buckets they were built at. Coming back to a ring it has been drawn at before is a swap of
--     parents -- no geometry, no bake. Parked ground is capped at MAX_VARIANT_TRIS, least
--     recently used goes first, and anything that changes the shape or membership of a block
--     drops its variants (they would be stale).
--   * THROTTLE. A re-tier that does need a bake waits LOD_BAKE_GAP after the last one, so a
--     backlog lands as an occasional bake while the camera rests, not one every frame.
--     Shape changes (roads, pads, brushes) and the first fill are never throttled.
--   * RESTING. Unchanged: rings are only re-judged while the camera rests (sweepDue).
-- Draw distance (Settings.renderDistance, via setDetailScale) now reaches the ground too:
-- distance is divided by it, so Low judges every block as if further away (coarser) and Ultra
-- as if nearer. The city's own chunks stay at full detail (pinned) whatever the setting.
local LOD_LIVE = true
local LOD_BAKE_GAP = 0.4
local MAX_VARIANT_TRIS = 300_000
type Variant = { parts: { MeshPart }, buckets: { [number]: number }, tris: number, usedAt: number }
local _variants: { [number]: { [string]: Variant } } = {}
local _variantTris = 0
local _lastLodBakeAt = -math.huge
local _detailScale = 1
-- Chunk key -> the block currently drawing it. A chunk in here has no _states entry and no
-- mesh of its own; that is how every other path in this file knows to leave it alone.
local _superOf: { [number]: number } = {}
-- Chunks that draw THEMSELVES instead of joining their block: the ones the city has built on
-- and the ones under a brush. Everything else is scenery. One-way for the session -- a chunk
-- that has been built on does not become scenery again, and the one-way-ness is also what
-- stops the over-budget fallback below from oscillating back into the block it just left.
local _solo: { [number]: boolean } = {}
local _superQueue: { number } = {}
local _superQueued: { [number]: boolean } = {}
local _superVersion: { [number]: number } = {}
-- Blocks that must re-build WITHOUT a member that just went solo. Urgent like a shape change: until
-- it lands the block still draws that chunk's OLD ground under the new one, and where the ground
-- was cut that old surface stands up through the road. (The member's own rebuild runs first and
-- clears its _shapeDirty, which is what used to mark the block urgent.)
local _ejected: { [number]: boolean } = {}
-- Ground that has left the queue but does not exist yet. Baking YIELDS, so without this the
-- queues read empty for the whole of the last bake -- and `pending` is what the join gate
-- holds the loading screen on, so the player was let in during it. One part, but the promise
-- the gate makes is that there are no holes at all.
local _inFlight = 0
-- What a pump is baking RIGHT NOW. Two pumps run (see start), and the same block baked twice at
-- once would leave the loser's part standing on top of the winner's.
local _building: { [number]: boolean } = {}
local _buildingSuper: { [number]: boolean } = {}

-- ONE FRAME'S SHARE of rebuild work per pump, once the player is in. Rebuilding a 4x4 block
-- measured ~220 ms of blocking Luau in Studio (61 geometry + 32 merge + 127 mesh fill), and a
-- camera move re-buckets dozens of blocks at once: that took an empty map from 240 fps to 15
-- while panning. Sliced, the same work lands over several frames and the ground catches up a
-- beat later. Only the pumps slice, and never behind the loading screen -- a sculpt stroke and
-- the load gate both want the work done now, so any other thread runs straight through.
local PUMPS = 2 -- see start()
-- Per pump. Small on purpose: LOD changes are rare and far now (see BUCKET_NEAR), so there is
-- no hurry, and the frame rate must not move while they land.
local PLAY_SLICE = 0.001
-- Per frame while a SKIPPED load finishes behind the player (setCatchUp): the whole far map is
-- still queued, and at PLAY_SLICE it would take minutes to fill in. Enough to land it in
-- seconds, little enough that the game is playable while it does.
local CATCH_UP_SLICE = 0.005
local _playSlice = PLAY_SLICE
local _sliceEnd: { [thread]: number } = {}
local _loading = true
local _epoch = 0 -- bumped by reset(): a build that yielded across it throws its result away
local _startupKeys: { [number]: boolean }? = nil
local _startupDeferred: { [number]: boolean } = {}
local _startupVisible: { [number]: boolean }? = nil
local _startupRevision = 0
local _startupView: {
 eye: Vector3, radius: number, cframe: CFrame?, viewport: Vector2?,
 fov: number?, fovMode: Enum.FieldOfViewMode?, revision: number,
}? = nil

local function breathe()
	if _loading then return end
	local co = coroutine.running()
	local e = _sliceEnd[co]
	if not e or os.clock() < e then return end
	RunService.Heartbeat:Wait()
	_sliceEnd[co] = os.clock() + _playSlice
end

-- The incoming part is parented BEFORE these go, and a locally created MeshPart is in the
-- scene for the frame it is parented in, so there is no gap to cover. Holding the outgoing
-- one for an extra frame is worse, not better: the two surfaces are coincident everywhere
-- the brush did not reach, and where it did the stale one can sit ABOVE the new ground and
-- show the un-lowered shape for a frame.
local function retire(part: MeshPart?, em: EditableMesh?)
	if part then (part :: MeshPart):Destroy() end
	if em then (em :: EditableMesh):Destroy() end
end

local function folder(): Folder
	local f = _folder
	if f and f.Parent then return f end
	f = Workspace:FindFirstChild("_Ground") :: Folder?
	if not f then
		f = Instance.new("Folder")
		;(f :: Folder).Name = "_Ground"
		;(f :: Folder).Parent = Workspace
	end
	_folder = f
	return f :: Folder
end

local function centreX(cx: number): number return -HALF + (cx + 0.5) * CHUNK_STUDS end
local function centreZ(cz: number): number return -HALF + (cz + 0.5) * CHUNK_STUDS end

-- Edge neighbours in the order TerrainMesh stitches them: -Z, +X, +Z, -X.
local NEIGHBOUR_DXZ = table.freeze({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } })

local function neighbourKey(cx: number, cz: number, d: { number }): number?
	local nx, nz = cx + d[1], cz + d[2]
	if nx < 0 or nx >= CHUNKS or nz < 0 or nz >= CHUNKS then return nil end
	return nz * CHUNKS + nx
end

-- To the NEAREST point of the chunk, not its centre: a 256-stud chunk judged by its middle is
-- drawn too coarse along the edge facing the camera, and that edge is what is closest.
local function chunkDist(key: number, camPos: Vector3): number
	local cx = key % CHUNKS
	local cz = (key - cx) / CHUNKS
	local hx, hz = CHUNK_STUDS * 0.5, CHUNK_STUDS * 0.5
	local dx = math.max(math.abs(centreX(cx) - camPos.X) - hx, 0)
	local dy = camPos.Y
	local dz = math.max(math.abs(centreZ(cz) - camPos.Z) - hz, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- HOW MUCH ERROR IS INVISIBLE HERE. Detail is chosen by SCREEN-SPACE ERROR, not by rings: a
-- block is drawn at the coarsest stride whose worst height error covers less than
-- LOD.PIXEL_BUDGET (half a pixel) at this distance. A stride change is therefore never
-- visible by construction -- the geometry moves by less than a pixel -- which is what the old
-- fixed rings (stride 2 at point-blank range, jumps at 900/1800/3200/5200 studs) could not
-- promise: every ring crossing was a re-tessellation the player watched happen.
--
-- Distance is bucketed in steps of BUCKET_RATIO from BUCKET_NEAR, and a bucket is judged by its
-- NEAR edge, so everything inside it is at least as accurate as the budget asks. A chunk only
-- rebuilds when its bucket changes; hysteresis keeps a camera on the boundary from re-baking it
-- every refresh.
--
-- FEW BUCKETS, AND ONLY FAR (user call, 2026-09-23). Doublings from 256 studs meant six rings
-- sweeping past the camera, so panning an empty map re-tessellated something every few frames.
-- Now everything within BUCKET_NEAR is full detail and NEVER changes; past it there are two
-- coarser rings, 1,024 and 4,096 studs out, where a change is both rare and far away.
--
-- Pinned chunks -- the ones the city built on -- are always bucket 0: distance never coarsens
-- ground under a road (see TerrainGradeService). Their own flatness still may.
local LOD_HYSTERESIS = 0.25
local BUCKET_NEAR = 1024
local BUCKET_RATIO = 4
local MAX_BUCKET = 2
-- Past this bucket (4,096 studs) the waterline stops being held at a fixed stride and far
-- coastal chunks may merge like any other -- see strideAt.
local SHORE_FREE_BUCKET = 2

local function bucketFor(d: number): number
	if d < BUCKET_NEAR then return 0 end
	return math.min(math.floor(math.log(d / BUCKET_NEAR, BUCKET_RATIO)) + 1, MAX_BUCKET)
end

local function bucketNearEdge(b: number): number
	return if b <= 0 then 0 else BUCKET_NEAR * BUCKET_RATIO ^ (b - 1)
end

-- The bucket for a chunk drawn at `current` (nil: not drawn yet) seen from camPos.
local function bucketFrom(key: number, camPos: Vector3, current: number?): number
	if _pinned[key] then return 0 end
	local d = chunkDist(key, camPos) / _detailScale
	local b = bucketFor(d)
	-- REFINE-ONLY once the player is in (2026-10-01): ground drawn finer is never coarsened again
	-- as the camera leaves. Every re-tier is a blocking bake (~25-50 ms, unsliceable), and the
	-- coarsening half of them is pure cost -- it only trims triangles nobody is near. Flying
	-- around the city now bakes each chunk at most once per bucket for the whole session.
	-- FROZEN once the player is in (2026-10-01 perf pass): refining was still a blocking bake per
	-- block as the camera arrived -- flying to the map edge sat at 20 fps for ~10 s while the
	-- backdrop caught up. The load picks every chunk's detail and it holds. (MAX_BUCKET 1 was
	-- tried for finer far ground: blocks overran the bake cap, ~140 extra bakes on load.) Pinned and sculpted chunks
	-- still rebuild -- the player caused those.
	if current and not _loading and not LOD_LIVE then return current end
	if current and current ~= b then
		-- Stay put while within the stretched boundary of the bucket we are already drawn in.
		local lo = bucketNearEdge(current) * (1 - LOD_HYSTERESIS)
		local hi = if current >= MAX_BUCKET then math.huge else bucketNearEdge(current + 1) * (1 + LOD_HYSTERESIS)
		if d >= lo and d < hi then return current end
	end
	return b
end

local function bucketOf(key: number, camPos: Vector3): number
	return bucketFrom(key, camPos, _drawn[key])
end

-- The worst height error this bucket can hide. Never finer than one height quantum: detail
-- the heightmap cannot express is not detail.
local function toleranceOf(b: number): number
	return math.max(FLAT_TOL, LOD.toleranceStuds(bucketNearEdge(b)))
end

-- Deep enough to fill the widest crack two neighbours a bucket apart can open between them.
local function skirtDepth(b: number): number
	return 4 * toleranceOf(b) + 1
end

-- THE ROW READER. Heights for a run of corners along one row, read straight off the chunk
-- buffers -- identical numbers to `capped` (the per-corner sampler: heightmap where the chunk is
-- loaded, the seed's surface where it is not, held under any road cap), without a closure call,
-- a chunk lookup and a key decode per corner. Off the map's interior (the outer border rows, the
-- far edge corner the heightmap does not own) it simply asks `capped`, so every edge case keeps
-- whatever answer it had before.
local CT = Constants.CHUNK_TILES
local CC = Constants.CHUNK_CORNERS
local INTERIOR = CHUNKS * CT -- corners 0 .. INTERIOR - 1 sit inside a chunk the heightmap owns
local FLOOR_Y = Constants.FLOOR_Y
local HEIGHT_STEP = Constants.HEIGHT_STEP
function makeFillRow(capped: (number, number) -> number, chunkHeights: (number) -> buffer?): TerrainMesh.FillRow
	return function(gx0: number, gz: number, count: number, out: { number }, at: number)
		local last = gx0 + count - 1
		if gz < 0 or gz >= INTERIOR then
			for k = 0, count - 1 do out[at + k] = capped(gx0 + k, gz) end
			return
		end
		local capChunk = _groundCapChunk
		-- A cap with no per-chunk form: keep the exact per-corner semantics.
		if _groundCap and not capChunk then
			for k = 0, count - 1 do out[at + k] = capped(gx0 + k, gz) end
			return
		end
		local cz = gz // CT
		local rowOff = (gz - cz * CT) * CC
		local gx, o = gx0, at
		while gx <= last do
			if gx < 0 or gx >= INTERIOR then
				out[o] = capped(gx, gz)
				gx += 1
				o += 1
				continue
			end
			local cx = gx // CT
			local x0 = cx * CT
			local segEnd = math.min(last, x0 + CT - 1)
			local key = cz * CHUNKS + cx
			local heights = chunkHeights(key)
			if not heights then
				for x = gx, segEnd do
					out[o] = capped(x, gz)
					o += 1
				end
			else
				local caps = if capChunk then capChunk(key) else nil
				local li = rowOff + (gx - x0)
				local off = li * 2
				for _ = gx, segEnd do
					local y = FLOOR_Y + buffer.readu16(heights, off) * HEIGHT_STEP
					if caps then
						local c = caps[li]
						if c and c < y then y = c end
					end
					out[o] = y
					o += 1
					off += 2
					li += 1
				end
			end
			gx = segEnd + 1
		end
	end
end

-- How much error each stride would cost in each block of a chunk. Asking FORCES the chunk's
-- heights to exist, because a neighbour's strides have to be exact before this chunk can stitch
-- to them -- and generating it now is free in total, since the background fill was going to
-- generate it anyway, only later. Guessing instead leaves a crack nobody goes back to fix.
local function errorsFor(key: number): Errors?
	local cached = _errs[key]
	if cached then return cached end
	local sampleY, ensureData = _sampleY, _ensureData
	if not sampleY or not ensureData or not ensureData(key) then return nil end
	local cx = key % CHUNKS
	local blocks, chunk = TerrainMesh.strideErrors(cx, (key - cx) / CHUNKS, sampleY, _fillRow)
	local errs = { blocks = blocks, chunk = chunk }
	_errs[key] = errs
	return errs
end

local function shoreCapsFor(key: number): { number }?
	local memo = _caps[key]
	if memo ~= nil then return if memo then memo else nil end
	local heightsOf = _heightsOf
	local heights = if heightsOf then heightsOf(key) else nil
	local caps = if heights then TerrainMesh.shoreCaps(heights) else nil
	_caps[key] = caps or false
	return caps
end

-- The stride of ONE block anywhere on the map: the coarsest its own shape can take within the
-- error its distance hides.
--
-- The WATERLINE is the exception. Where ground meets engine water a vertical error is magnified
-- into a horizontal one -- a quarter stud on a 1:20 beach moves the coast five studs -- so a
-- shore block ignores distance and is drawn at a fixed stride decided by its shape alone (never
-- coarser than its cap). The coast then never changes as the camera moves. Only far out, past
-- SHORE_FREE_BUCKET, does the shore coarsen and merge with the rest of the chunk.
local function strideAt(gbx: number, gbz: number, eye: Vector3): number
	local cx = gbx // BLOCKS
	local cz = gbz // BLOCKS
	-- Off the map there is no neighbour to agree with, and the FINEST stride reads as "never
	-- stitch to me", which leaves the map edge sitting at its true heights.
	if cx < 0 or cx >= CHUNKS or cz < 0 or cz >= CHUNKS then return 1 end
	local key = cz * CHUNKS + cx
	local index = (gbz - cz * BLOCKS) * BLOCKS + (gbx - cx * BLOCKS) + 1
	-- A block the brush is working on is held at full resolution for the whole stroke, ahead
	-- of anything the shape or the distance would say.
	local fine = _editFine[key]
	if fine and fine[index] then return 1 end
	local errs = errorsFor(key)
	if not errs then return 1 end
	local b = bucketOf(key, eye)
	local tol = toleranceOf(b)
	local caps = if b < SHORE_FREE_BUCKET then shoreCapsFor(key) else nil
	-- The whole chunk as one patch, when even that is within tolerance. Never with a shore in
	-- it: the shore holds its own stride.
	if not caps then
		for i = #STEPS, 1, -1 do
			local m = STEPS[i]
			if m <= BLOCK_TILES then break end
			if (errs.chunk[m] or math.huge) <= tol then return m end
		end
	end
	local cap = if caps then caps[index] else 0
	if cap > 0 then
		return math.min(cap, TerrainMesh.blockStride(errs.blocks, index, FLAT_TOL))
	end
	return TerrainMesh.blockStride(errs.blocks, index, tol)
end

local function eyePos(): Vector3
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function superKeyOf(key: number): number
	local cx = key % CHUNKS
	local cz = (key - cx) / CHUNKS
	return (cz // SUPER) * SUPERS + (cx // SUPER)
end

local function superMembers(sk: number): { number }
	local sx = sk % SUPERS
	local sz = (sk - sx) / SUPERS
	local out = table.create(SUPER * SUPER)
	for dz = 0, SUPER - 1 do
		for dx = 0, SUPER - 1 do
			out[#out + 1] = (sz * SUPER + dz) * CHUNKS + (sx * SUPER + dx)
		end
	end
	return out
end

-- The members this block actually draws: everything that has not gone solo.
local function superDist(sk: number, camPos: Vector3): number
	local d = math.huge
	for _, key in superMembers(sk) do
		d = math.min(d, chunkDist(key, camPos))
	end
	return d
end

local function mergeMembers(sk: number): { number }
	local out = {}
	for _, key in superMembers(sk) do
		if not _solo[key] then
			if not _startupKeys or _startupKeys[key] then
				out[#out + 1] = key
			else
				_startupDeferred[key] = true
			end
		end
	end
	return out
end

local function enqueueSuper(sk: number)
	if _superQueued[sk] then return end
	_superVersion[sk] = (_superVersion[sk] or 0) + 1
	_superQueued[sk] = true
	_superQueue[#_superQueue + 1] = sk
end

local function enqueueChunk(key: number)
	if _queued[key] then return end
	_queued[key] = true
	_queue[#_queue + 1] = key
end

-- Returns nil when the client's shared Editable budget is momentarily exhausted, which is
-- a "try later", not a failure -- the caller puts the chunk back in the queue. It is a
-- SHARED budget: overrunning it does not just fail terrain, it fails every other
-- EditableMesh in the game (the glass UI was the first casualty).
local function bake(geo: TerrainMesh.Geo, live: boolean): (MeshPart?, EditableMesh?)
	local em = AssetService:CreateEditableMesh()
	if not em then return nil, nil end
	local kept: EditableMesh? = nil
	local ok, result = pcall(function(): MeshPart
		local pos, nrm, col, tri, uvs = geo.pos, geo.nrm, geo.col, geo.tri, geo.uv
		local n = #pos
		local vid, nid, cid, uid = table.create(n), table.create(n), table.create(n), table.create(n)
		for i = 1, n do
			if i % 256 == 0 then breathe() end
			vid[i] = em:AddVertex(pos[i])
			nid[i] = em:AddNormal(nrm[i])
			cid[i] = em:AddColor(col[i], 1)
			uid[i] = em:AddUV(uvs[i])
		end
		-- One scratch table per attribute, refilled per face: the engine copies the ids out, and
		-- three fresh tables a triangle cost 10-30% of the fill in garbage (measured).
		local fn, fc, fu = table.create(3), table.create(3), table.create(3)
		for i = 1, #tri, 3 do
			if i % 384 == 1 then breathe() end -- every 128 triangles
			local a, b, c = tri[i], tri[i + 1], tri[i + 2]
			local f = em:AddTriangle(vid[a], vid[b], vid[c])
			fn[1], fn[2], fn[3] = nid[a], nid[b], nid[c]
			fc[1], fc[2], fc[3] = cid[a], cid[b], cid[c]
			fu[1], fu[2], fu[3] = uid[a], uid[b], uid[c]
			em:SetFaceNormals(f, fn)
			em:SetFaceColors(f, fc)
			em:SetFaceUVs(f, fu)
		end
		if live then
			-- Skip the static bake: measured on a sculpted chunk, this path is ~6 ms against
			-- ~36 ms through CreateDataModelContentAsync, and 36 ms every stroke tick is what
			-- made the ground feel like it was chasing the cursor.
			--
			-- The MeshPart only keeps rendering while an EditableMesh backs it, and it MUST be
			-- the FixedSize snapshot, never this scratch one: a DYNAMIC EditableMesh reserves
			-- a fat slice of the client budget whatever it actually holds, so keeping even a
			-- couple alive exhausts it -- and that budget is shared, so what breaks first is
			-- the glass UI, not terrain. FixedSize reserves only its own size. The scratch dies
			-- in the caller either way.
			local fixed = AssetService:CreateEditableMeshAsync(Content.fromObject(em), { FixedSize = true })
			local ok2, part = pcall(function(): MeshPart
				return AssetService:CreateMeshPartAsync(Content.fromObject(fixed), {
					CollisionFidelity = Enum.CollisionFidelity.Box,
					RenderFidelity = Enum.RenderFidelity.Precise, -- see the static bake below
				})
			end)
			if not ok2 then
				fixed:Destroy()
				error(part)
			end
			kept = fixed
			return part :: MeshPart
		end
		-- Bake to STATIC content and let the EditableMesh die: the client Editable* budget is
		-- about eight live meshes, so a view that kept them alive would fail past chunk eight.
		local res, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		assert(res == Enum.CreateContentResult.Success, tostring(res))
		-- PRECISE: this file decides the detail. The default (Automatic) let the engine decimate
		-- every chunk on its own at distance, so neighbouring chunks stopped agreeing along their
		-- edges and thin gaps opened between terrain pieces as the engine swapped its LODs.
		-- ApplyMesh carries it onto the reshaped part (measured).
		return AssetService:CreateMeshPartAsync(content, {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	em:Destroy() -- the scratch always dies here; only the FixedSize snapshot may outlive it
	if not ok then
		if kept then (kept :: EditableMesh):Destroy() end
		warn("[TerrainMeshView] bake failed:", result)
		return nil, nil
	end
	return result :: MeshPart, kept
end

-- Everything a ground MeshPart is apart from its geometry. Shared by the per-chunk meshes and
-- the merged backdrop, so the two cannot drift apart in appearance -- a backdrop with a
-- different material or a missing grain would draw a visible seam around every chunk the city
-- has touched.
local function dress(mp: MeshPart, geo: TerrainMesh.Geo, name: string)
	mp.Name = name
	mp.Anchored = true
	mp.CanCollide = false
	mp.CanQuery = false
	mp.CanTouch = false
	mp.CastShadow = false
	mp.DoubleSided = false
	mp.Color = WHITE -- vertex colours do the tinting
	mp.Material = GROUND_MATERIAL
	local grain = TerrainSurfaceTexture.image()
	if grain then
		-- pcall: a MeshPart that will not take TextureContent should still be ground.
		pcall(function()
			mp.TextureContent = Content.fromObject(grain)
		end)
	end
	mp.Transparency = 0
	mp.CFrame = CFrame.new(geo.origin)
	mp.Parent = folder()
end

-- == LOD variants (see LOD FOLLOWS THE CAMERA) ===================================
local function sigOf(members: { number }, buckets: { [number]: number }): string
	local out = table.create(#members + 1)
	for i, key in members do out[i] = tostring(buckets[key] or -1) end
	out[#members + 1] = if _underground then "u" else "g"
	return table.concat(out, ",")
end

local function dropVariants(sk: number)
	local byBlock = _variants[sk]
	if not byBlock then return end
	_variants[sk] = nil
	for _, v in byBlock do
		for _, part in v.parts do retire(part, nil) end
		_variantTris -= v.tris
	end
end

local function dropAllVariants()
	local blocks = {}
	for sk in _variants do blocks[#blocks + 1] = sk end
	for _, sk in blocks do dropVariants(sk) end
	_variantTris = 0
end

-- The block's ground or membership changed: what it parked, and what it draws now, no longer
-- match any ring it could be shown at again.
local function invalidateBlock(sk: number)
	dropVariants(sk)
	local cur = _supers[sk]
	if cur then cur.sig = nil end
end

local function evictVariants()
	-- a Low device keeps proportionally less ground parked
	while _variantTris > MAX_VARIANT_TRIS * math.min(_detailScale, 1) do
		local bestSk: number? = nil
		local bestSig: string? = nil
		local bestAt = math.huge
		for sk, byBlock in _variants do
			for sig, v in byBlock do
				if v.usedAt < bestAt then bestSk, bestSig, bestAt = sk, sig, v.usedAt end
			end
		end
		if not bestSk or not bestSig then break end
		local byBlock = _variants[bestSk]
		local v = byBlock[bestSig]
		byBlock[bestSig] = nil
		if next(byBlock) == nil then _variants[bestSk] = nil end
		for _, part in v.parts do retire(part, nil) end
		_variantTris -= v.tris
	end
end

-- Keep what a block draws for when the camera brings it back to this ring. Its parts leave the
-- scene two frames on, once the parts replacing them are certainly drawing (a part swap has no
-- frame at which the engine promises both are drawn -- see buildChunk); the two surfaces agree
-- to within the ladder's sub-pixel tolerance, so the overlap does not show.
local function park(sk: number, cur: Super)
	local sig, buckets = cur.sig, cur.buckets
	if not sig or not buckets then
		for _, part in cur.parts do retire(part, nil) end
		return
	end
	local byBlock = _variants[sk]
	if not byBlock then
		byBlock = {}
		_variants[sk] = byBlock
	end
	local prior = byBlock[sig]
	if prior then
		for _, part in prior.parts do retire(part, nil) end
		_variantTris -= prior.tris
	end
	local v: Variant = { parts = cur.parts, buckets = buckets, tris = cur.tris or 0, usedAt = os.clock() }
	byBlock[sig] = v
	_variantTris += v.tris
	local frames = 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		frames += 1
		if frames < 2 then return end
		conn:Disconnect()
		local still = _variants[sk]
		if still and still[sig] == v then
			for _, part in v.parts do part.Parent = nil end
		end
	end)
	evictVariants()
end

-- Swap a block to a variant parked for the rings the camera puts it in now. No geometry and
-- no bake: two sets of parts change parents. False when there is no such variant.
local function showVariant(sk: number, camPos: Vector3): boolean
	local cur = _supers[sk]
	local byBlock = _variants[sk]
	if not cur or not cur.sig or not byBlock then return false end
	-- Any parked variant whose every member the ladder would KEEP where it is from here: the same
	-- test bucketOf applies to what is drawn, hysteresis included. An exact match on the buckets
	-- a rebuild would pick missed whenever a member sat inside a ring's hysteresis band.
	local sig: string? = nil
	local v: Variant? = nil
	for vsig, cand in byBlock do
		local fits = true
		for _, key in cur.members do
			local vb = cand.buckets[key]
			if vb == nil or bucketFrom(key, camPos, vb) ~= vb then
				fits = false
				break
			end
		end
		if fits then
			sig, v = vsig, cand
			break
		end
	end
	if not v or not sig or sig == cur.sig then return false end
	byBlock[sig] = nil
	if next(byBlock) == nil then _variants[sk] = nil end
	_variantTris -= v.tris
	local f = folder()
	for _, part in v.parts do part.Parent = f end
	park(sk, cur)
	_supers[sk] = { parts = v.parts, members = cur.members, sig = sig, buckets = v.buckets, tris = v.tris }
	for _, key in cur.members do _drawn[key] = v.buckets[key] end
	return true
end

-- Build (or rebuild) one chunk and swap it in. The old part is destroyed only after the new
-- one is parented, so the ground never flickers a hole. `eye` is the LOD reference; it
-- defaults to the camera and is passed explicitly during the first fill, when the camera is
-- not yet where the player will be.
function TerrainMeshView.buildChunk(key: number, eye: Vector3?, live: boolean?): boolean
	local sampleY, sampleMat = _sampleY, _sampleMat
	if not sampleY or not sampleMat then return false end
	local cx = key % CHUNKS
	local cz = (key - cx) / CHUNKS
	local at = eye or eyePos()

	-- Scenery is never drawn per chunk, on ANY path. The cold load's near pass calls straight in
	-- here rather than through the queue, and without this those chunks would each be baked
	-- individually and then again as part of a block -- the whole near map rebuilding itself for
	-- no reason. A live sculpt rebuild is exempt: editArea has already soloised its chunk.
	if not live and not _solo[key] then
		enqueue(key)
		return true
	end
	local shapeChanged = _shapeDirty[key] == true
	local cityChange = _cityShape[key] == true
	-- The chunk records only its distance BUCKET: its blocks' strides follow from that plus a
	-- shape that does not change on its own, so the bucket is the whole of what can go stale.
	local tier = bucketOf(key, at)
	local geo = TerrainMesh.buildChunk(cx, cz, sampleY, sampleMat, function(gbx: number, gbz: number): number
		return strideAt(gbx, gbz, at)
	end, _fillRow)
	if not _underground then TerrainMesh.addSkirt(geo, skirtDepth(tier)) end
	local epoch = _epoch
	local mp, em = bake(geo, live == true)
	if not mp then return false end
	if epoch ~= _epoch then -- the map was torn down while this baked
		retire(mp, em)
		return true
	end
	_shapeDirty[key] = nil -- cleared only once the work it asked for actually landed
	_cityShape[key] = nil

	-- RESHAPE the part that is already there instead of swapping in a new one. A swap is two
	-- instances changing places in the render scene, and that hand-off is the flicker the
	-- ground shows on every chunk a road grades -- the old part had to survive until the new
	-- one was parented, and there is no frame at which the engine promises both are drawn.
	-- ApplyMesh replaces the geometry ON the instance that is already drawing: same part, same
	-- draw call, only the mesh changes. Measured: it swaps MeshSize but leaves Size alone, so
	-- Size has to follow it or the new shape is scaled into the old part's extent.
	--
	-- STATIC bakes only. A live part renders only while its OWN EditableMesh is alive, and
	-- whether that content survives being handed to a second instance is not worth relying on.
	local st = _states[key]
	local reuse: MeshPart? = if em == nil and st then st.part else nil
	if reuse then
		local fresh = mp :: MeshPart
		local held = reuse :: MeshPart
		held:ApplyMesh(fresh)
		held.Size = fresh.Size
		fresh:Destroy()
		mp = held
	end

	dress(mp, geo, "G" .. key)

	if st then
		local oldPart, oldEm = st.part, st.em
		st.part = mp
		st.em = em
		st.step = tier
		-- Both together: a live part STOPS RENDERING the moment its EditableMesh dies, so
		-- freeing the mesh early would open the very hole the deferral exists to avoid.
		-- oldPart IS mp when it was reshaped in place; only a real swap has one to retire.
		retire(if oldPart ~= mp then oldPart else nil, oldEm)
	else
		_states[key] = { part = mp, step = tier, em = em }
	end
	_drawn[key] = tier

	-- Neighbouring blocks stitched their edges onto the lines our border blocks draw, so they
	-- are stale when the GROUND here changed shape -- a new height is off by any amount.
	--
	-- NOT when only our distance tier changed. Both sides of the seam are then within their own
	-- tolerance of the true edge, so they disagree by about a pixel at most, and the skirts
	-- fill that. Re-stitching anyway re-queued up to four neighbouring blocks per LOD change:
	-- measured on a camera sweep, 60 block rebuilds against 24 without, and the ground took
	-- 10.4 s to catch up against 0.6 s.
	if not shapeChanged then return true end
	-- A change the city made (markDirty) re-draws only this chunk. Re-stitching the neighbours is
	-- for a STRIDE change along the shared edge, and the crack a stale stitch opens is within the
	-- coarser side's tolerance -- what the skirts are sized to fill (skirtDepth). A height change
	-- ON the shared edge reaches the neighbour by its own patch (both chunks hold that corner). It
	-- used to re-draw up to four neighbours -- whole 4x4 blocks where they are scenery, each ending
	-- in a blocking bake -- after every road placed near a chunk border.
	if cityChange then return true end
	for _, d in NEIGHBOUR_DXZ do
		local nk = neighbourKey(cx, cz, d)
		if nk and (_states[nk] or _superOf[nk]) then enqueue(nk) end
	end
	return true
end

-- Build (or rebuild) one super-chunk: every member's geometry through the SAME strideAt the
-- per-chunk path uses, merged, and baked once. Yields (bake does), like buildChunk.
local function buildSuper(sk: number, eye: Vector3): boolean
 local sampleY, sampleMat, ensureData = _sampleY, _sampleMat, _ensureData
 if not sampleY or not sampleMat or not ensureData then return false end
 local old = _supers[sk]
 local epoch = _epoch
 local version = _superVersion[sk] or 0
 local underground = _underground
 local members = mergeMembers(sk)
 local function clearOldOwnership()
  if not old then return end
  for _,key in old.members do
   if _superOf[key] == sk then _superOf[key] = nil end
  end
 end
 if #members == 0 then
  if old then for _,part in old.parts do retire(part,nil) end end
  clearOldOwnership()
  dropVariants(sk)
  _supers[sk] = nil
  return true
 end
 local function current(): boolean
  if epoch ~= _epoch or version ~= (_superVersion[sk] or 0) or underground ~= _underground then return false end
  local latest = mergeMembers(sk)
  if #latest ~= #members then return false end
  for i,key in members do if latest[i] ~= key then return false end end
  return true
 end
 local buckets: { [number]: number } = {}
 for _,key in members do buckets[key] = bucketOf(key,eye) end
 local staged: { { part: MeshPart, geo: TerrainMesh.Geo } } = {}
 local function discard()
  for _,entry in staged do retire(entry.part,nil) end
  table.clear(staged)
 end
 -- A dense block needs several meshes, not a second geometry pass and one bake per chunk.
 -- Nothing is published until every batch has baked against the same epoch/membership.
 local ok, result = xpcall(function(): boolean
  local batches: { { TerrainMesh.Geo } } = {}
  local batch: { TerrainMesh.Geo } = {}
  local triangles = 0
  for _,key in members do
   ensureData(key)
   local cx = key % CHUNKS
   local geo = TerrainMesh.buildChunk(cx,(key-cx)/CHUNKS,sampleY,sampleMat,function(gbx:number,gbz:number):number
    return strideAt(gbx,gbz,eye)
   end,_fillRow)
   if not underground then TerrainMesh.addSkirt(geo,skirtDepth(buckets[key])) end
   local count = #geo.tri // 3
   assert(count <= TRI_BUDGET,"one terrain chunk exceeds the mesh triangle budget")
   if #batch > 0 and triangles + count > TRI_BUDGET then
    batches[#batches+1] = batch
    batch = {}
    triangles = 0
   end
   batch[#batch+1] = geo
   triangles += count
   breathe()
   if not current() then return false end
  end
  if #batch > 0 then batches[#batches+1] = batch end
  for _,geos in batches do
   local geo = TerrainMesh.mergeGeo(geos,breathe)
   local part = bake(geo,false)
   if not part then return false end
   staged[#staged+1] = {part=part,geo=geo}
   if not current() then return false end
  end
  return true
 end,debug.traceback)
 if not ok or not result then
  discard()
  if not ok then warn("[TerrainMeshView] block",sk,"batch bake failed:",result) end
  -- Reset owns the new queues; an old-city build must not enqueue itself into them.
  return epoch ~= _epoch
 end
 local newSig = sigOf(members,buckets)
 local newTris = 0
 for _,entry in staged do newTris += #entry.geo.tri // 3 end
 local sameMembers = old ~= nil and #old.members == #members
 if sameMembers and old then
  for i,key in members do
   if old.members[i] ~= key then
    sameMembers = false
    break
   end
  end
 end
 if not sameMembers then dropVariants(sk) end
 -- A pure re-tier keeps what it replaces (see LOD variants): park it rather than reshape it.
 if LOD_LIVE and old and sameMembers and old.sig and old.sig ~= newSig then
  local parts: { MeshPart } = {}
  for i,entry in staged do
   dress(entry.part,entry.geo,"S"..sk..(if i == 1 then "" else "_"..i))
   parts[i] = entry.part
  end
  park(sk,old)
  _supers[sk] = {parts=parts,members=members,sig=newSig,buckets=buckets,tris=newTris}
  for _,key in members do
   _drawn[key] = buckets[key]
   _shapeDirty[key] = nil
   _superOf[key] = sk
   local state = _states[key]
   if state then
    retire(state.part,state.em)
    _states[key] = nil
   end
  end
  return true
 end
 local parts: { MeshPart } = {}
 for i,entry in staged do
  local part = entry.part
  local held = if old then old.parts[i] else nil
  if held and held.Parent then
   local reused,cause = pcall(function()
    held:ApplyMesh(part)
    held.Size = part.Size
   end)
   if reused then
    retire(part,nil)
    part = held
   else
    warn("[TerrainMeshView] block",sk,"could not reuse batch",i,":",cause)
   end
  end
  dress(part,entry.geo,"S"..sk..(if i == 1 then "" else "_"..i))
  if held and held ~= part then retire(held,nil) end
  parts[i] = part
 end
 if old then
  for i = #parts+1,#old.parts do retire(old.parts[i],nil) end
 end
 clearOldOwnership()
 _supers[sk] = {parts=parts,members=members,sig=newSig,buckets=buckets,tris=newTris}
 for _,key in members do
  _drawn[key] = buckets[key]
  _shapeDirty[key] = nil
  _superOf[key] = sk
  local state = _states[key]
  if state then
   retire(state.part,state.em)
   _states[key] = nil
  end
 end
 return true
end

-- Hand a block back to its chunks: the camera has come close, or something was built out
-- This chunk is not scenery any more -- it has been built on, or a brush is on it. It leaves
-- its block, which rebuilds WITHOUT it, and draws itself from here on.
--
-- Ejecting ONE member rather than splitting the whole block is two bakes instead of sixteen,
-- which is what makes grading a road out in the backdrop cheap.
--
-- The block keeps drawing its old mesh -- this chunk's ground included -- until that rebuild
-- lands, so for a frame or two the ground here is drawn twice. Deliberate: dropping the block
-- first would open a 4x4-chunk hole instead, and a hole is far worse than an overlap nobody
-- can see.
--
-- A chunk with no owner is either already drawing itself or has not been drawn at all yet --
-- which is the case at load, where every edited chunk is pinned BEFORE anything is built.
-- Queueing it here would bake it once now and once more when the queue reached it.
local function soloise(key: number)
	if _solo[key] then return end
	_solo[key] = true
	local owner = _superOf[key]
	if not owner then return end
	_superOf[key] = nil
	_ejected[owner] = true
	invalidateBlock(owner)
	enqueueSuper(owner)
	enqueueChunk(key)
end

function enqueue(key: number)
	if _startupKeys and not _startupKeys[key] then
		_startupDeferred[key] = true
		return
	end
	-- Scenery is drawn by its block, never by itself. THIS REDIRECT IS THE WIN: a cold load asks
	-- for all 1,024 chunks and it becomes ~64 merged bakes.
	if not _solo[key] then
		enqueueSuper(superKeyOf(key))
		return
	end
	enqueueChunk(key)
end

-- LOD RE-TIERS ONLY ONCE THE CAMERA HAS SETTLED. Every rebuild ends in CreateMeshPartAsync,
-- which blocks ~21-27 ms whatever the mesh holds (measured: 256 triangles and 12,288 cost the
-- same) and cannot be sliced, so any LOD change while panning was a dropped frame. Held until the
-- camera rests, the far rings catch up while nothing moves. Behind the loading screen it never
-- waits.
local SETTLE_STUDS = 8 -- camera travel per REFRESH window that still counts as resting
local _sweepPos = Vector3.zero

local function sweepDue(dt: number, camPos: Vector3): boolean
	_accum += dt
	if _accum < REFRESH then return false end
	_accum = 0
	local moved = (camPos - _sweepPos).Magnitude
	_sweepPos = camPos
	return moved < SETTLE_STUDS or _loading
end

-- A re-tier: ground already drawn whose shape has not changed, rebuilt only because the camera
-- moved it to another ring. Those wait out LOD_BAKE_GAP (see LOD FOLLOWS THE CAMERA); nothing else
-- does -- not a shape change, not a block shedding a member, not the fill, not a catch-up.
local function lodHold(): boolean
	return LOD_LIVE and not _loading and _playSlice ~= CATCH_UP_SLICE
		and os.clock() - _lastLodBakeAt < LOD_BAKE_GAP
end
local function chunkRetier(key: number): boolean
	return _states[key] ~= nil and not _shapeDirty[key]
end
local function superRetier(sk: number): boolean
	if _ejected[sk] or not _supers[sk] then return false end
	for _, key in superMembers(sk) do
		if _shapeDirty[key] then return false end
	end
	return true
end
-- The first job that may run now: everything, or (holding) everything but re-tiers.
local function takeJob(queue: { number }, isRetier: (number) -> boolean): (number?, boolean)
	local hold = lodHold()
	for i, item in queue do
		local retier = isRetier(item)
		if not (hold and retier) then
			table.remove(queue, i)
			return item, retier
		end
	end
	return nil, false
end

local function tick(dt: number, sweeps: boolean)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	-- Past the loading screen one pump is plenty: throughput stops mattering, and two pumps
	-- resuming in the same frame stacked their hitches.
	if not sweeps and not _loading then return end
	local camPos = cam.CFrame.Position

	if sweeps and sweepDue(dt, camPos) then
		-- Not what is mid-build: its bucket updates when it lands, and queueing it again meanwhile
		-- rebuilt every sliced block twice.
		for key, st in _states do
			if not _queued[key] and not _building[key] and bucketOf(key, camPos) ~= st.step then
				enqueue(key)
			end
		end

		-- The backdrop re-tiers the same way a chunk does, off its nearest member. Blocks are
		-- never split by distance -- membership answers to what the city has touched, not to
		-- where the camera is -- so there is nothing to collect and split here.
		for sk, s in _supers do
			if not _superQueued[sk] and not _buildingSuper[sk] then
				for _, key in s.members do
					if bucketOf(key, camPos) ~= _drawn[key] then
						if not (LOD_LIVE and showVariant(sk, camPos)) then enqueueSuper(sk) end
						break
					end
				end
			end
		end

		-- Nearest first, whatever queued it: sliced rebuilds mean the queues can hold seconds of
		-- work, and the ground under the camera must not wait behind the horizon.
		local dist: { [number]: number } = {}
		for _, key in _queue do dist[key] = chunkDist(key, camPos) end
		table.sort(_queue, function(a, b) return dist[a] < dist[b] end)
		local sdist: { [number]: number } = {}
		for _, sk in _superQueue do sdist[sk] = superDist(sk, camPos) end
		table.sort(_superQueue, function(a, b) return sdist[a] < sdist[b] end)
	end

	if #_queue == 0 and #_superQueue == 0 then return end
	-- At least one item per frame whatever the budget says, or a big one would never start.
	-- Past the loading screen that item slices itself (see breathe) instead of dropping frames.
	-- ponytail: one chunk's TerrainMesh.buildChunk is still one unsliced step (2-15 ms); move
	-- the geometry into a parallel Actor if that ever shows up in the MicroProfiler.
	--
	-- Except where the GROUND ITSELF changed (a road graded, a pad levelled): that lands unsliced,
	-- as it always has, or the old surface pokes up through what was just built on it.
	local co = coroutine.running()
	local slice = if _loading then BUDGET else _playSlice
	local t0 = os.clock()
	repeat
		-- Chunks before blocks: the chunk queue is filled nearest-first, and what the player is
		-- about to look at matters more than the horizon behind it.
		local ckey: number?, chunkRetiering = nil, false
		if #_queue > 0 then ckey, chunkRetiering = takeJob(_queue, chunkRetier) end
		if ckey then
			local key = ckey
			_queued[key] = nil
			-- It was merged into the backdrop while it sat in the queue. Building it now would
			-- put a second surface over ground the block is already drawing.
			if _building[key] then
				enqueueChunk(key) -- the other pump is mid-bake on it
				return
			end
			if not _superOf[key] then
				local urgent = _shapeDirty[key] == true
				if urgent then _sliceEnd[co] = math.huge end
				_inFlight += 1
				_building[key] = true
				local ok, built = pcall(TerrainMeshView.buildChunk, key, camPos)
				_building[key] = nil
				if urgent then _sliceEnd[co] = t0 + slice end
				_inFlight = math.max(_inFlight - 1, 0)
				if chunkRetiering then _lastLodBakeAt = os.clock() end
				if not ok then
					warn("[TerrainMeshView] chunk", key, "failed:", built)
				elseif not built then
					-- Out of Editable budget this instant. Put it back and yield the frame rather
					-- than spinning: whatever is holding the budget needs a chance to let go.
					enqueue(key)
					return
				end
			end
		else
			local sk, retier = takeJob(_superQueue, superRetier)
			if not sk then return end -- all that is left is re-tiers waiting out LOD_BAKE_GAP
			_superQueued[sk] = nil
			if _buildingSuper[sk] then
				enqueueSuper(sk)
				return
			end
			if retier then
				-- The camera may have moved on while it waited: back into the ring it is drawn at
				-- (nothing to do), or into one it has a variant for (a swap, no bake).
				local stale = false
				for _, member in (_supers[sk] :: Super).members do
					if bucketOf(member, camPos) ~= _drawn[member] then
						stale = true
						break
					end
				end
				if not stale or (LOD_LIVE and showVariant(sk, camPos)) then continue end
			end
			local urgent = _ejected[sk] == true
			for _, key in superMembers(sk) do
				if _shapeDirty[key] then
					urgent = true
					break
				end
			end
			if urgent then _sliceEnd[co] = math.huge end
			_inFlight += 1
			_buildingSuper[sk] = true
			local ok, built = pcall(buildSuper, sk, camPos)
			_buildingSuper[sk] = nil
			if ok and built then _ejected[sk] = nil end
			if retier then _lastLodBakeAt = os.clock() end
			if urgent then _sliceEnd[co] = t0 + slice end
			_inFlight = math.max(_inFlight - 1, 0)
			if not ok then
				warn("[TerrainMeshView] backdrop block", sk, "failed:", built)
				-- A block nobody draws is a 4x4-chunk hole in the map -- measured, one block of
				-- sixteen lost out of a full-map build before this existed. Hand the ground back
				-- to its chunks and let them take the slow path. Marked solo on the way, or the
				-- next sweep merges them straight back into the block that just threw.
				for _, key in superMembers(sk) do
					if not _superOf[key] then
						_solo[key] = true
						enqueueChunk(key)
					end
				end
			elseif not built then
				-- Out of Editable budget, same as a chunk: put it back, yield the frame.
				enqueueSuper(sk)
				return
			end
		end
	until (#_queue == 0 and #_superQueue == 0) or (os.clock() - t0) >= slice
end

-- sampleY(gx, gz) -> heightmap worldY at a global corner; sampleMat(gx, gz) -> material id;
-- ensureData(chunkKey) -> load or generate that chunk's real heights if they are not there
-- yet, and report whether sampleY can now answer for it exactly.
-- heightsOf(chunkKey) -> that chunk's raw height buffer, ensured, for the shore caps; optional.
-- chunkHeights(chunkKey) -> that chunk's raw height buffer if it is ALREADY loaded, else nil
--   (never generates). Optional; when given, the mesh reads whole rows off the buffers instead
--   of calling sampleY per corner, and sampleY is only asked where this answers nil. It must
--   agree with sampleY: sampleY(gx, gz) == rawToWorldY(raw at that corner) wherever it answers.
function TerrainMeshView.setSource(
	sampleY: (number, number) -> number,
	sampleMat: (number, number) -> number,
	ensureData: (number) -> boolean,
	heightsOf: ((number) -> buffer?)?,
	chunkHeights: ((number) -> buffer?)?
)
	local capped = function(gx: number, gz: number): number
		local y = sampleY(gx, gz)
		local cap = _groundCap
		local c = if cap then cap(gx, gz) else nil
		return if c and c < y then c else y
	end
	_sampleY = capped
	_sampleMat = sampleMat
	_ensureData = ensureData
	_heightsOf = heightsOf
	_fillRow = if chunkHeights then makeFillRow(capped, chunkHeights) else nil
	table.clear(_errs)
	table.clear(_caps)
end

-- See _groundCap. The caller marks the chunks whose caps changed dirty (markDirty).
-- capChunk(key) is the same caps a chunk at a time (see _groundCapChunk); without it the rows
-- fall back to asking `cap` per corner.
function TerrainMeshView.setGroundCap(cap: ((number, number) -> number?)?, capChunk: ((number) -> { [number]: number }?)?)
 _startupRevision += 1
	_groundCap = cap
	_groundCapChunk = if cap then capChunk else nil
end

-- Chunks the city has built on. Distance never coarsens a pinned chunk (its own flatness
-- still may -- see losslessStep).
function TerrainMeshView.pin(key: number)
	-- Pinned means distance never coarsens this chunk. It does NOT mean it needs a mesh of its
	-- own: strideAt is answered per block of tiles, so a merged block already holds members at
	-- different strides, and graded city ground is flat enough to coarsen on shape anyway.
	--
	-- This used to soloise, on the reasoning that a block "has no way to hold one member finer
	-- than the rest" -- which is simply untrue, and cost a bake per city chunk on every load.
	-- The one real risk, a block carrying so much detail that it overruns an EditableMesh, is
	-- what TRI_BUDGET is for: such a block hands its members back to the per-chunk path.
	-- A chunk only leaves its block when a brush actually touches it -- see editArea.
	_pinned[key] = true
end

-- Draw this chunk when there is room in the frame. For the background fill, which has the
-- heights but no reason to stall on the mesh: one queue and ONE budget decide how much
-- terrain work a frame does, instead of two loops each spending their own.
function TerrainMeshView.request(key: number)
	enqueue(key)
end

-- How much ground is still waiting for geometry -- loose chunks and merged blocks alike. The
-- join gate holds the loading screen until this reaches zero, so the player never enters onto
-- a map with holes in it.
function TerrainMeshView.pending(): number
	return #_queue + #_superQueue + _inFlight
end

local function shapeDirty(key: number)
 _startupRevision += 1
	invalidateBlock(superKeyOf(key))
	_shapeDirty[key] = true
	_errs[key] = nil -- the shape decides the strides, so a new shape re-decides them
	_caps[key] = nil
end

-- The chunk's heights changed (a road grade, a building pad, a patch from the server): rebuild it.
--
-- Past the load, ground the CITY changes leaves its backdrop block and draws itself (soloise),
-- exactly as ground under a brush does. A block member's change re-builds the WHOLE 4x4 block --
-- sixteen chunks of geometry, the merge and the mesh fill, ~220 ms measured, and unsliced because
-- the ground changed (see tick) -- so every road placed out there was a frame-rate cliff. Solo,
-- it costs that once (the block re-builds without it) and one chunk per edit after. Behind the
-- loading screen nothing changes: the load decides membership as before.
function TerrainMeshView.markDirty(key: number)
	shapeDirty(key)
	if not _loading then
		_cityShape[key] = true
		soloise(key)
	end
	enqueue(key)
end

-- ONE loop in ONE coroutine -- deliberately NOT a Heartbeat connection.
--
-- Baking yields: CreateDataModelContentAsync and CreateMeshPartAsync are both async. A
-- yielding Heartbeat handler does not hold off the next frame's, so a connection starts a
-- FRESH build every frame while the previous ones are still parked mid-bake, each holding
-- a live EditableMesh. Within a second that exhausts the client's shared Editable budget
-- and every other EditableMesh in the game starts failing to allocate -- which is how this
-- first showed itself, as the glass UI breaking rather than as anything about terrain.
-- A fixed number of coroutines means a fixed number of EditableMeshes alive: PUMPS of them.
--
-- TWO, measured: the engine finishes one CreateDataModelContentAsync per frame however many
-- are waiting, so a third pump only queues behind it. What the second one buys is that the
-- next block's geometry is built while the first waits on its bake -- one pump alone spent a
-- frame on geometry, a frame on the bake and a frame waiting for the next Heartbeat, per
-- block, and at load-time frame rates that was most of the loading screen.
local _pumpGen = 0
function TerrainMeshView.start()
	if _running then return end
	_running = true
	_pumpGen += 1
	local gen = _pumpGen
	for p = 1, PUMPS do
		task.spawn(function()
			local co = coroutine.running()
			-- gen, not just _running: a stop() then start() inside one bake would otherwise leave
			-- the old pumps alive alongside the new ones.
			while _running and gen == _pumpGen do
				local dt = RunService.Heartbeat:Wait()
				_sliceEnd[co] = os.clock() + _playSlice
				local ok, err = pcall(tick, dt, p == 1)
				if not ok then warn("[TerrainMeshView] pump failed:", err) end
			end
			_sliceEnd[co] = nil
		end)
	end
end

function TerrainMeshView.stop()
	_running = false
end

-- The loading screen is down: from here rebuilds share the frame instead of taking it (see
-- breathe). reset() puts it back up for the next city.
function TerrainMeshView.setLoading(on: boolean)
	_loading = on
end

-- The player skipped the loading screen with ground still queued: drain it a CATCH_UP_SLICE at
-- a time until the build says it has landed.
function TerrainMeshView.setCatchUp(on: boolean)
	_playSlice = if on then CATCH_UP_SLICE else PLAY_SLICE
end

local function startupPlanes(camera: Camera?, eye: Vector3): { Vector3 }?
 if not camera or (camera.CFrame.Position - eye).Magnitude > 0.001 then return nil end
 local size = camera.ViewportSize
 if size.X <= 0 or size.Y <= 0 then return nil end
 local rays = {}
 for _, p in { Vector2.zero, Vector2.new(size.X, 0), size, Vector2.new(0, size.Y) } do
  rays[#rays + 1] = camera:ViewportPointToRay(p.X, p.Y).Direction
 end
 local look = camera.CFrame.LookVector
 local planes = { look }
 for i = 1, 4 do
  local normal = rays[i]:Cross(rays[i % 4 + 1])
  if normal:Dot(look) < 0 then normal = -normal end
  planes[#planes + 1] = normal.Unit
 end
 return planes
end

local function startupContains(key: number, eye: Vector3, radius: number, planes: { Vector3 }?): boolean
 if chunkDist(key, eye) > radius then return false end
 if not planes then return true end
 local capChunk = _groundCapChunk
 if _groundCap and not capChunk then return true end
 local low = Constants.FLOOR_Y + Constants.RENDER_BULGE
 local high = Constants.FLOOR_Y + Constants.RAW_MAX * Constants.HEIGHT_STEP + Constants.RENDER_BULGE
 if capChunk then
  local caps = capChunk(key)
  if caps then
   for _, height in caps do low = math.min(low, height + Constants.RENDER_BULGE) end
  end
 end
 if not _underground then low -= skirtDepth(bucketOf(key, eye)) end
 local cx = key % CHUNKS
 local cz = (key - cx) / CHUNKS
 local relative = Vector3.new(centreX(cx), (low + high) * 0.5, centreZ(cz)) - eye
 local half = CHUNK_STUDS * 0.5
 local halfY = (high - low) * 0.5
 for _, normal in planes do
  local support = normal:Dot(relative) + math.abs(normal.X) * half
   + math.abs(normal.Y) * halfY + math.abs(normal.Z) * half
  if support < -0.01 then return false end
 end
 return true
end

function TerrainMeshView.isStartupVisible(key: number): boolean
 return not _startupVisible or _startupVisible[key] == true
end

function TerrainMeshView.releaseStartupArea()
 _startupKeys = nil
 for key in _startupDeferred do enqueue(key) end
 table.clear(_startupDeferred)
end

function TerrainMeshView.setStartupArea(pos: Vector3?, radius: number?, camera: Camera?)
 if not pos then
  _startupKeys = nil
  _startupVisible = nil
  _startupView = nil
  for key in _startupDeferred do enqueue(key) end
  table.clear(_startupDeferred)
  return
 end
 assert(radius and radius >= 0 and radius < math.huge, "[TerrainMeshView] startup radius must be finite and non-negative")
 local cf = if camera then camera.CFrame else nil
 local viewport = if camera then camera.ViewportSize else nil
 local fov = if camera then camera.FieldOfView else nil
 local fovMode = if camera then camera.FieldOfViewMode else nil
 local prior = _startupView
 if prior and prior.eye == pos and prior.radius == radius and prior.cframe == cf
  and prior.viewport == viewport and prior.fov == fov and prior.fovMode == fovMode
  and prior.revision == _startupRevision then return end
 local planes = startupPlanes(camera, pos)
 local visible = {}
 local keys = _startupKeys or {}
 for key = 0, CHUNKS * CHUNKS - 1 do
  if startupContains(key, pos, radius, planes) then
   visible[key] = true
   keys[key] = true
  end
 end
 _startupKeys = keys
 _startupVisible = visible
 _startupView = { eye = pos, radius = radius, cframe = cf, viewport = viewport,
  fov = fov, fovMode = fovMode, revision = _startupRevision }
 for key in _startupDeferred do
  if visible[key] then
   _startupDeferred[key] = nil
   enqueue(key)
  end
 end
end

-- Is the ground drawn everywhere within `radius` of `pos`? Drawn = a block holds the chunk
-- (_superOf) or it draws itself (_states). What a skipped loading screen still waits for.
function TerrainMeshView.drawnAround(pos: Vector3, radius: number): boolean
 if _startupVisible then
  local restricted = _startupKeys ~= nil
  TerrainMeshView.setStartupArea(pos, radius, Workspace.CurrentCamera)
  if not restricted then TerrainMeshView.releaseStartupArea() end
  for key in _startupVisible :: { [number]: boolean } do
   if not _superOf[key] and not _states[key] then return false end
  end
  return true
 end
	for key = 0, CHUNKS * CHUNKS - 1 do
		if not _superOf[key] and not _states[key] and chunkDist(key, pos) <= radius then
			return false
		end
	end
	return true
end

-- One tick of a sculpting stroke, over the world-space square the brush just changed.
-- Three things here are deliberate, and each one answers a separate complaint:
--
--  * IMMEDIATE, and synchronous rather than queued -- the point is that the ground moves on
--    the frame you clicked. It rebuilds through the LIVE path (see bake), which is ~9 ms
--    for a sculpted chunk against ~44 ms for the static one.
--  * The touched blocks are pinned to stride 1 FOR THE WHOLE STROKE. A levelled block is
--    drawn as a single 32-stud quad, and a smooth falloff applied to one quad is not a
--    dome, it is a tilted plate -- which is what the bumps were.
--  * Every OTHER block keeps the stride it already had, because _errs is not invalidated
--    until editEnd. Recomputing strides mid-stroke re-tessellates ground the brush never
--    touched, and the whole 256-stud plate visibly reshuffles under the cursor.
function TerrainMeshView.editArea(minX: number, minZ: number, maxX: number, maxZ: number)
	if _editBusy then return end -- a rebuild is still in flight; the next tick catches up
	local cam = Workspace.CurrentCamera
	local at = if cam then cam.CFrame.Position else Vector3.zero

	local function blockIndexOf(world: number): number
		return math.clamp(math.floor((world + HALF) / BLOCK_STUDS), 0, MAX_BLOCK)
	end
	local touched: { number } = {}
	for gbz = blockIndexOf(minZ), blockIndexOf(maxZ) do
		for gbx = blockIndexOf(minX), blockIndexOf(maxX) do
			local cx, cz = gbx // BLOCKS, gbz // BLOCKS
			local key = cz * CHUNKS + cx
			-- Sculpting ground the backdrop is drawing: it leaves the block and draws itself, or
			-- the live rebuild below has no per-chunk mesh to reshape and the stroke does nothing.
			_editChunks[key] = true
			soloise(key)
			local fine = _editFine[key]
			if not fine then
				fine = {}
				_editFine[key] = fine
			end
			local bx, bz = gbx - cx * BLOCKS, gbz - cz * BLOCKS
			local index = bz * BLOCKS + bx + 1
			local newlyPinned = fine[index] == nil
			fine[index] = true
			if table.find(touched, key) == nil then touched[#touched + 1] = key end
			-- Pinning a BORDER block changes the line the chunk next door stitched itself to,
			-- and nothing else in the stroke would go back and tell it -- that side would keep
			-- drawing an edge against a stride we no longer use and the seam opens into a crack.
			--
			-- Only when the block is NEWLY pinned. Doing it on every tick the brush sat over a
			-- border rebuilt five chunks a tick instead of one, which overran the live cap and
			-- forced a full static re-bake every tick: that was the flicker, and re-tessellating
			-- the ground that often is also what kept the surface texture reprojecting.
			if newlyPinned and (bx == 0 or bx == BLOCKS - 1 or bz == 0 or bz == BLOCKS - 1) then
				for _, d in NEIGHBOUR_DXZ do
					local nk = neighbourKey(cx, cz, d)
					if nk and _states[nk] and table.find(touched, nk) == nil then
						touched[#touched + 1] = nk
					end
				end
			end
		end
	end

	_editBusy = true
	local ok, err = pcall(function()
		for _, key in touched do
			TerrainMeshView.buildChunk(key, at, true)
			-- Including the neighbours dragged in above: whatever went live has to be in the
			-- set editEnd bakes back down, or its EditableMesh outlives the stroke.
			_editChunks[key] = true
			local seen = table.find(_liveOrder, key)
			if seen then table.remove(_liveOrder, seen) end
			table.insert(_liveOrder, key)
		end
		-- Anything pushed past the cap goes back to static now. It keeps its pinned-fine
		-- blocks, so this costs a bake but changes nothing on screen.
		while #_liveOrder > MAX_LIVE do
			local old = table.remove(_liveOrder, 1) :: number
			local st = _states[old]
			if st and st.em then TerrainMeshView.buildChunk(old, at, false) end
		end
	end)
	_editBusy = false
	if not ok then warn("[TerrainMeshView] live edit failed:", err) end
end

-- The stroke finished. Let every chunk it touched re-decide its strides from its new shape,
-- and rebuild it through the normal queue -- which bakes it back to STATIC content and frees
-- the EditableMesh the live path had to keep alive.
function TerrainMeshView.editEnd()
	if next(_editChunks) == nil then return end
	for key in _editChunks do
		_errs[key] = nil
		_caps[key] = nil
		shapeDirty(key) -- already solo (editArea); a brush re-stitches its neighbours as before
		enqueue(key)
	end
	table.clear(_editChunks)
	table.clear(_editFine)
	table.clear(_liveOrder)
end

-- Is this chunk under an active stroke? The server's patch for it is already on screen --
-- the client predicted it -- so rebuilding on arrival would only re-tessellate the plate
-- mid-drag for no visible change.
function TerrainMeshView.isEditing(key: number): boolean
	return _editChunks[key] == true
end

-- X-ray the ground so what sits BELOW it -- water mains, sewers, tunnels, a metro box --
-- reads from a normal camera. Only possible because the ground is a hollow shell.
function TerrainMeshView.setUnderground(on: boolean)
	if _underground == on then return end
 _startupRevision += 1
	_underground = on
	-- Skirts differ, so nothing parked or drawn now is a variant of what comes next.
	dropAllVariants()
	for _, cur in _supers do cur.sig = nil end
	-- The x-ray look itself is UndergroundView's (see-through ground). What lives HERE is the
	-- skirts (TerrainMesh.addSkirt): curtains under every chunk border that hide sub-pixel seams
	-- between chunks drawn at different detail. Under an opaque ground nobody sees them; through
	-- the x-ray they were a grid of boxes, one per chunk. So the x-ray draws the ground near the
	-- camera WITHOUT them -- same shape, same strides, nothing re-stitches -- and turning it off
	-- puts them back. Nearest first, like every rebuild (tick sorts the queues).
	local cam = Workspace.CurrentCamera
	local at = if cam then cam.CFrame.Position else Vector3.zero
	for key in _states do
		if chunkDist(key, at) <= SKIRTLESS_RANGE then enqueue(key) end
	end
	for sk in _supers do
		if superDist(sk, at) <= SKIRTLESS_RANGE then enqueueSuper(sk) end
	end
end

-- Draw distance for the ground (Settings.renderDistance): distance is divided by it when a block
-- is judged, so below 1 the whole ladder pulls in (coarser, fewer triangles) and above 1 it
-- pushes out. Everything re-judges on the next resting sweep; parked variants were built for the
-- old ladder and go.
function TerrainMeshView.setDetailScale(scale: number)
	local s = math.clamp(if scale == scale then scale else 1, 0.25, 2)
	if s == _detailScale then return end
	_detailScale = s
	dropAllVariants()
	for _, cur in _supers do cur.sig = nil end
end

function TerrainMeshView.isUnderground(): boolean
	return _underground
end

-- Tear the whole ground down. Called before a new city loads, so a stale map is never left
-- standing under the new one.
function TerrainMeshView.reset()
	TerrainMeshView.stop()
	_epoch += 1
	_startupKeys = nil
 _startupVisible = nil
 _startupView = nil
	table.clear(_startupDeferred)
	_loading = true
	_playSlice = PLAY_SLICE
	for _, st in _states do
		if st.part then (st.part :: MeshPart):Destroy() end
		if st.em then (st.em :: EditableMesh):Destroy() end
	end
	table.clear(_states)
	table.clear(_editChunks)
	table.clear(_editFine)
	table.clear(_liveOrder)
	table.clear(_pinned)
	table.clear(_queue)
	table.clear(_queued)
	table.clear(_shapeDirty)
	table.clear(_cityShape)
	table.clear(_errs)
	table.clear(_drawn)
	table.clear(_caps)
	for _, s in _supers do
		for _,part in s.parts do retire(part,nil) end
	end
	table.clear(_supers)
	dropAllVariants()
	_lastLodBakeAt = -math.huge
	table.clear(_superOf)
	table.clear(_superQueue)
	table.clear(_superQueued)
	table.clear(_superVersion)
	table.clear(_ejected)
	table.clear(_solo)
	_accum = 0
	-- Clear through folder(), not the cached handle: a rejoin (or a reload in a test
	-- harness) starts with empty state but the previous _Ground still standing in Workspace,
	-- and iterating _states would walk straight past it and leave two grounds overlaid.
	folder():ClearAllChildren()
end

return TerrainMeshView
