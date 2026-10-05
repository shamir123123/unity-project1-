--!strict
-- TerrainPadService
-- "Terrain follows buildings": when a building is placed, flattens the terrain
-- under its footprint to the building's base height, keeps a small flat verge
-- around it, then blends a shoulder out to natural ground. Reversible per-building
-- (refcounted) so removing a building restores the terrain it flattened within the
-- session. Pure server; writes through the authoritative Heightmap owned by
-- TerrainDataService. Mirrors TerrainGradeService, which does the same for roads.
--
-- What it flattens is the caller's footprint: a house's own walls (its yard keeps the lie of the
-- land, softened by the shoulder), a shop's or works' whole yard with its FORECOURT held level out
-- to the road. The lot's paving is LotDressingService's mesh lying on this ground; nothing here
-- paints the terrain or grades the ground between lots (user, 2026-09-29).
--
-- Persistence saves the natural heightmap underneath these overlays, so buildings
-- can be deleted after a reload and still release terrain back to its pre-building shape.

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TerrainConstants   = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)

local TerrainPadService = {}

local FOOTPRINT_MARGIN = 0.75 -- enough overlap to avoid a voxel seam, not a broad platform
local FLAT_VERGE       = 1.5  -- keeps the building edge clean without widening the lot
-- A compact shoulder keeps a placed building grounded but does not turn every slope
-- into a large, circular terrace. The special case below joins any pad to an
-- already-near road bed, so every building category gets the same small-gap fill.
local SHOULDER_MIN     = 4.0
local SHOULDER_MAX     = 14.0
local MAX_GRADE        = 0.75 -- max rise/run of the ordinary lot edge (~37 deg)
local YARD_GRADE       = 0.35 -- a house's yard eases into the land at about 1 in 3: somewhat flat
local ROAD_JOIN_MAX    = 10.0 -- only bridge genuinely small road-to-lot gaps
-- TerrainDataService.getSurfaceY is the visible terrain height: raw height plus this
-- renderer offset. Writing the pad at baseY - RENDER_BULGE makes its visible surface
-- exactly meet the building base instead of leaving the former 0.5-stud air gap.
local PAVE_CLEARANCE   = TerrainConstants.RENDER_BULGE
-- The forecourt: how far past the lot's front the pad reaches toward the road. A lot is a
-- rectangle and a street bends, so on the inside of a curve a wedge opens between the lot's
-- straight front and the kerb; this strip is held flat with the lot, which is what joins a
-- straight yard to a bent street. Road-owned corners in it keep their height (the road's).
local FRONT_REACH      = 5.0

local FLAG_LOCKED      = TerrainConstants.Flag.LOCKED
local FLAG_PAD_GRADED  = TerrainConstants.Flag.PAD_GRADED
local MAX_CORNER       = TerrainConstants.CORNERS_PER_AXIS - 1
local cornerToWorld    = TerrainConstants.cornerToWorld
local worldToCorner    = TerrainConstants.worldToCorner
local rawToWorldY      = TerrainConstants.rawToWorldY
local worldYToRaw      = TerrainConstants.worldYToRaw

-- All corner bookkeeping (refcounts, original height/flags, overlap merging)
-- lives in the shared overlay ledger, so pads and road grades can claim the
-- same corners without clobbering each other.
local function ledger()
	return TerrainDataService.getOverlayLedger()
end

-- Finds an already-graded road beside a pad. Road corners remain owned by the road;
-- this only shapes the short unowned strip between the building and sidewalk.
local function nearestRoadY(led: any, gx: number, gz: number, wx: number, wz: number): (number?, number?)
	local cornerStep = math.abs(cornerToWorld(1) - cornerToWorld(0))
	local searchCells = math.max(1, math.ceil(ROAD_JOIN_MAX / math.max(cornerStep, 0.01)) + 1)
	local nearestDist = math.huge
	local nearestY: number? = nil

	for dz = -searchCells, searchCells do
		local rz = math.clamp(gz + dz, 0, MAX_CORNER)
		local roadZ = cornerToWorld(rz)
		for dx = -searchCells, searchCells do
			local rx = math.clamp(gx + dx, 0, MAX_CORNER)
			-- One prefix: segments and corner connectors both claim under "road:" now (see
			-- TerrainGradeService.ROAD_KIND -- splitting them was burying carriageways).
			-- Only the road's LOCKED bed is the road. Its soft bank runs 16 studs out at
			-- natural-ground height; joining to that on a hillside copied the bank's height
			-- into a locked strip that cut a trench through the next lot along.
			local raw = led:targetForOwnerKind(rx, rz, "road:", FLAG_LOCKED)
			if raw then
				local roadX = cornerToWorld(rx)
				local deltaX = roadX - wx
				local deltaZ = roadZ - wz
				local distance = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
				if distance < nearestDist then
					nearestDist = distance
					nearestY = rawToWorldY(raw)
				end
			end
		end
	end

	return nearestY, nearestDist
end

-- forecourt: the pad also holds FRONT_REACH in front of the footprint level (a paved yard).
type PadRec = { pivot: CFrame, w: number, d: number, baseY: number, stage: number, forecourt: boolean }
local _pads: { [string]: PadRec } = {}

-- Write one pad (release first if it is already down). `rec.stage` in 0..1 is how far the
-- earthworks have got: every corner sits that fraction of the way from the ground it found to
-- its finished height, so a construction site settles in a few steps instead of snapping.
local function applyPad(led: any, id: string, rec: PadRec)
	local owner = "pad:" .. id
	led:release(owner)
	led:beginOwner(owner)

	local pivot, worldWidth, worldDepth, baseY, stage = rec.pivot, rec.w, rec.d, rec.baseY, rec.stage
	local center = pivot.Position
	local right  = pivot.RightVector
	local fwd    = pivot.LookVector
	local halfW  = worldWidth * 0.5 + FOOTPRINT_MARGIN
	local halfD  = worldDepth * 0.5 + FOOTPRINT_MARGIN
	local plotHalfW, plotHalfD = worldWidth * 0.5, worldDepth * 0.5
	local reach  = math.max(FLAT_VERGE + SHOULDER_MAX, FRONT_REACH) -- widest a shoulder (or the forecourt) runs
	local rad    = math.max(halfW, halfD) + reach

	local gxMin = math.clamp(math.floor(worldToCorner(center.X - rad)), 0, MAX_CORNER)
	local gxMax = math.clamp(math.ceil(worldToCorner(center.X + rad)), 0, MAX_CORNER)
	local gzMin = math.clamp(math.floor(worldToCorner(center.Z - rad)), 0, MAX_CORNER)
	local gzMax = math.clamp(math.ceil(worldToCorner(center.Z + rad)), 0, MAX_CORNER)

	for gz = gzMin, gzMax do
		local wz = cornerToWorld(gz)
		for gx = gxMin, gxMax do
			local wx = cornerToWorld(gx)
			local dx = wx - center.X
			local dz = wz - center.Z
			local u = dx * right.X + dz * right.Z -- signed distance along width
			local v = dx * fwd.X + dz * fwd.Z     -- signed distance along depth
			local du = math.max(0, math.abs(u) - halfW)
			local dv = math.max(0, math.abs(v) - halfD)
			local d = math.sqrt(du * du + dv * dv) -- 0 inside the footprint
			if d > reach then continue end
			-- How deep this corner lies inside the footprint (negative outside it). Where two lots'
			-- locked claims meet, the ledger gives the corner to the lot it is deeper in, so a
			-- lot's own ground always wins over the next lot's verge.
			local pu, pv = math.abs(u) - plotHalfW, math.abs(v) - plotHalfD
			local depthIn = if pu <= 0 and pv <= 0 then math.min(-pu, -pv)
				else -math.sqrt(math.max(pu, 0) ^ 2 + math.max(pv, 0) ^ 2)
			-- v runs toward the road (LookVector), so the footprint's front is +halfD.
			local front = v - halfD
			local forecourt = rec.forecourt and front > 0 and front <= FRONT_REACH and math.abs(u) <= halfW

			-- A road's bed and footway are never touched. Its verge is shared: the lot claims
			-- it at the road's own rank, which merges by min -- down to the lot's level, so the
			-- ground never pushes up into the building, and never up over the pavement edge.
			local shared = led:otherKindLockRank(gx, gz, "pad:")
			if shared == math.huge then
				continue
			end

			-- Blend toward the CLOSER of original ground and the current heightmap (which
			-- already carries road beds and neighbouring pads). Blending only toward natural
			-- dug pits beside graded roads (the hanging-sidewalk gap) and tore steps between
			-- neighbouring lots padded at different heights.
			local naturalY = rawToWorldY(led:naturalRaw(gx, gz))
			local currentY = TerrainDataService.getHeightAt(wx, wz)
			local padY = baseY - PAVE_CLEARANCE
			local refY = if math.abs(currentY - padY) < math.abs(naturalY - padY) then currentY else naturalY
			local newY: number
			local flags: number
			local prio: number? = depthIn
			local joinedRoad = false

			if forecourt then
				-- Held level with the lot out to the road: no dip between the building
				-- and the kerb, however the street bends.
				newY = padY
				flags = FLAG_LOCKED + FLAG_PAD_GRADED
			elseif d > 0 and d <= ROAD_JOIN_MAX then
				local roadY, roadDistance = nearestRoadY(led, gx, gz, wx, wz)
				if roadY and roadDistance then
					local totalGap = d + roadDistance
					if totalGap <= ROAD_JOIN_MAX then
						-- A shallow, local join only for the small strip between a building
						-- and road. The road's locked corners are never overwritten.
						local t = d / math.max(totalGap, 0.01)
						local s = t * t * (3 - 2 * t)
						newY = padY + (roadY - padY) * s
						-- The infill owns its final shape so a later road regrade cannot
						-- pull this building-to-sidewalk transition back into a ditch.
						flags = FLAG_LOCKED + FLAG_PAD_GRADED
						joinedRoad = true
					end
				end
			end

			if not joinedRoad and not forecourt then
				if d <= FLAT_VERGE then
					-- Under the building + a narrow verge: dead flat just below the base, LOCKED.
					newY = padY
					flags = FLAG_LOCKED + FLAG_PAD_GRADED
				else
					-- Keep non-road edges compact. A building on a steep slope still blends,
					-- but it no longer creates the wide all-around terrace of the old pad.
					local grade = if rec.forecourt then MAX_GRADE else YARD_GRADE
					local shoulder = math.clamp(math.abs(refY - padY) / grade, SHOULDER_MIN, SHOULDER_MAX)
					if d > FLAT_VERGE + shoulder then continue end
					local t = (d - FLAT_VERGE) / shoulder
					local s = t * t * (3 - 2 * t)
					newY = padY + (refY - padY) * s
					flags = FLAG_PAD_GRADED
					prio = nil -- a plain slope: merges by min with the road banks, as before
				end
			end
			if stage < 1 then newY = currentY + (newY - currentY) * stage end
			if shared then
				if bit32.band(flags, FLAG_LOCKED) == 0 then continue end -- a soft slope never beats a lock
				prio = shared
			end
			led:write(owner, gx, gz, worldYToRaw(newY), flags, prio)
		end
	end
end

-- Flatten the terrain under one building footprint. pivot is the horizontal footprint
-- frame: RightVector spans worldWidth and LookVector spans worldDepth (LookVector faces
-- the road). baseY is the height the pad is flattened to. `stage` (default 1) is how far
-- the earthworks have got; calling again with a later stage moves the ground on.
-- `forecourt` (default on) also holds the strip in front of the footprint level out to the
-- road; a house passes false, its front yard keeps the lie of the land. Calling again with the
-- same arguments does nothing.
function TerrainPadService.padFootprint(id: string, pivot: CFrame, worldWidth: number, worldDepth: number, baseY: number, stage: number?, forecourt: boolean?)
	local led = ledger()
	if not led then return end
	local st = math.clamp(stage or 1, 0, 1)
	local fc = forecourt ~= false
	local cur = _pads[id]
	if cur and led:isOwned("pad:" .. id) and cur.stage == st and cur.baseY == baseY and cur.forecourt == fc
		and cur.w == worldWidth and cur.d == worldDepth
		and (cur.pivot.Position - pivot.Position).Magnitude < 1e-3
		and cur.pivot.LookVector:Dot(pivot.LookVector) > 0.99999 then
		return -- already padded exactly like this
	end
	local rec: PadRec = { pivot = pivot, w = worldWidth, d = worldDepth, baseY = baseY, stage = st, forecourt = fc }
	_pads[id] = rec
	applyPad(led, id, rec)
end

-- Release one building's pad. Corners drop back to their pre-pad height + flags once no
-- pad owns them.
function TerrainPadService.unpadFootprint(id: string)
	_pads[id] = nil
	local led = ledger()
	if not led then return end
	led:release("pad:" .. id)
end

-- The earthworks stage a pad was last written at (nil = no pad).
function TerrainPadService.getStage(id: string): number?
	local rec = _pads[id]
	return rec and rec.stage
end

return TerrainPadService
