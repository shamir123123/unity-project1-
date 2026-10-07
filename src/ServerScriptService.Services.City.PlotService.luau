--!strict
-- PlotService
-- Server-authoritative owner of Manor Lords burgage plots. The client sends dragged frontage
-- spans (seg, side, t0..t1); the server CLIPS each against already-occupied frontage AND the
-- shared road index (junction mouths, dead-end caps, road-overlap), packs the free runs into
-- lot-multiple plots, and asks BuildingService to develop one building per plot. A group
-- persists BOTH its span (the intent) and the seats it produced (the result) -- a load
-- replays the seats verbatim and never re-plans, so a city comes back exactly as it stood.
--
-- Owns the plot domain. Reads roads through RoadService (segment lookup); drives BuildingService.
--
-- A deleted road does not take its houses with it at once (user, 2026-10-06). Its groups go
-- ROADLESS (segmentId 0): the buildings stand with a road-required pin for ROAD_GRACE seconds
-- of running game time; from ROAD_LEAVE_AT families start moving out one at a time
-- (CitizenService, off BuildingService's `roadless` stage); at ROAD_GRACE the buildings come
-- down. A road laid along their fronts in the meantime re-attaches them and stops the clock.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local GameSpeed     = require(ReplicatedStorage.GameSpeed)
local ZoneTypes     = require(ReplicatedStorage.City.ZoneTypes)
local BezierUtil    = require(ReplicatedStorage.Road.BezierUtil)
local PlotGeometry  = require(ReplicatedStorage.City.PlotGeometry)
local ZoneGrid      = require(ReplicatedStorage.City.ZoneGrid)
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local PlacementFit  = require(ReplicatedStorage.Shared.PlacementFit)

local PlotService = {}

-- One seated building: the pivot it was placed at, its template size in lots, and the
-- plot footprint the terrain pad covers. This is what a save stores and a load replays.
-- bpId is runtime-only (never persisted -- a load mints fresh ids): it is how serialize
-- tells a seat whose building still stands from one the player has since bulldozed.
-- t0/t1 are this ONE building's slice of the road frontage: the group's claimed span is
-- the union of its seats, so demolishing a house gives back exactly the stretch it sat on.
-- (Absent on seats from a save written before spans were stored.)
export type Seat = { pivot: CFrame, w: number, d: number, fw: number, fd: number, bpId: string?, t0: number?, t1: number? }

export type PlotGroup = {
	id          : number,
	segmentId   : number,
	side        : number,
	t0          : number,
	t1          : number,
	depth       : number,
	width       : number,
	uniform     : boolean?,  -- only exact-width plots (player's size-mode choice)
	bw          : number?,   -- building width lots (polygon parcels persist their curve-trim)
	zone        : string,
	building    : string?,   -- a specific template name (single-building picker); nil = random variant
	density     : string?,   -- "Medium" = mid-rise blocks (Residential only); nil = low (houses)
	buildingIds : { string },
	-- Where the buildings ACTUALLY stand. The span (t0/t1) is the intent; this is the
	-- result, and only the result reloads exactly.
	placed      : { Seat }?,
	-- Seconds of running game time since its road was deleted; nil = it has a road.
	roadless    : number?,
}

local LOT            = ZoneGrid.LOT_SIZE -- plots are measured in lots, like the buildings on them
local MIN_DEPTH      = 2 * LOT -- the smallest building depth, so the house fits its plot
local MAX_DEPTH      = PlotGeometry.MAX_PARCEL_DEPTH
local MAX_WIDTH      = 7.5 * LOT
local DEFAULT_DEPTH  = 3 * LOT
local PLACE_COOLDOWN = 0.05
-- Refit reach: studs past a changed road's control points a standing house could still
-- overlap it from (widest road half-width + sidewalk, plus the deepest building's half
-- diagonal). Only seats inside that box are re-tested after an edit.
local REFIT_REACH    = 96
-- More segments than this in one change is a bulk rebuild -- a city load, an undo, a
-- snapshot restore -- not a player edit. Those replace the plots wholesale straight after,
-- so refitting against them is churn at best and demolishes the outgoing city at worst.
local MAX_REFIT_SEGS = 24
local MAX_PER_PLACE = 4096
local MAX_INPUT_CELLS = 4096
local MAX_GROUP_SEATS = 32
local PLACE_WORK_BUDGET = 0.003
local PLACEMENT_CANCELLED = "zoning placement superseded"
-- Roadless lots (see the header). Real seconds while the game runs, not game hours: the
-- player is told "ten minutes" and that has to hold at any game speed. Paused, it waits.
local ROAD_GRACE     = 600
local ROAD_LEAVE_AT  = 420
local ROAD_LAST_CALL = 540
-- A reconnecting road counts for a building whose front it runs along: the building square
-- to it, standing where a lot on that road would stand, give or take this much.
local REHOME_TOL     = 0.75 * LOT
local REHOME_REACH   = 160 -- studs; segments farther than this from a building are not tried

local _roadService : any
local _building    : any
local _net         : any
local _groups      : { [number]: PlotGroup } = {}
local _nextId      = 0
local _bound       = false
local _lastPlaceAt : { [Player]: number } = {}
local _placementBusy = false
local _cityRevision = 0
local _topologyRevision = 0
local _planningRevision = 0
local _topoDisc    : (() -> ())? = nil
local _bldgDisc    : (() -> ())? = nil
local _densityAllowed : ((density: string) -> boolean)? = nil
local _clearNature    : ((rects: { { Vector3 } }) -> number)? = nil

local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("CityCoreLoading") == true then return false end
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

local function segmentById(id: number): any
	if not _roadService then return nil end
	return _roadService.getNetwork():getSegments()[id]
end

local function isFinite(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- A side with no footway (an alley, a one-sided street's bare kerb) seats its lots at the
-- asphalt, not a kerb's height above it -- that kerb was the step every alley house floated on.
local function kerblessFor(g: PlotGroup): boolean
	local seg = segmentById(g.segmentId)
	return seg ~= nil and not PlotGeometry.sideHasWalk(seg.roadType, g.side)
end

-- A parcel's ground, for clearing the trees on it.
local function parcelRect(plot: PlotGeometry.Plot): { Vector3 }
	return { plot.frontA, plot.frontB, plot.backB, plot.backA }
end

-- The save grid. Seats are quantised HERE, before the building is placed, so the pivot held
-- in memory is bit-identical to the one persisted. BuildingService derives its saveKey (the
-- handle for level / occupancy / residents / the resident family) from this position, and a
-- pivot that shifted by one rounding step on reload would orphan all of it.
local function r1(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

-- Plot edges are 0..1 curve parameters, so r1 would move them up to a stud on a long road.
-- Six decimals is <= 0.002 stud on a 2,000-stud road, far inside the 1e-3 run-adjacency
-- tolerance, and saves ~30% of the plot section over raw 17-digit floats.
local function r6(n: number): number
	return math.round(n * 1e6) / 1e6
end

-- Plot pivots are pure yaw: PlotGeometry.buildingRect flattens the look vector to XZ.
-- Normalised to [0, 360) so a save -> load -> save cycle is a fixed point: without it
-- atan2 returns -180 for the same facing it wrote as 180, and the blob never settles.
local function yawDegOf(cf: CFrame): number
	return r1(math.deg(math.atan2(-cf.LookVector.X, -cf.LookVector.Z))) % 360
end

local function seatPivot(cf: CFrame): CFrame
	local p = cf.Position
	return CFrame.new(r1(p.X), r1(p.Y), r1(p.Z)) * CFrame.Angles(0, math.rad(yawDegOf(cf)), 0)
end

local function toWire(g: PlotGroup): any
	return { id = g.id, seg = g.segmentId, side = g.side, t0 = g.t0, t1 = g.t1,
		depth = g.depth, width = g.width, zone = g.zone, uniform = g.uniform == true }
end

-- A roadless group has no frontage to draw: clients never get it until it re-attaches.
local function addWire(changed: { any }, g: PlotGroup)
	if not g.roadless then table.insert(changed, toWire(g)) end
end

local function notifyAll(text: string, kind: string)
	if _net and _net.Notify then
		_net.Notify:FireAllClients({ text = text, kind = kind, duration = 8 })
	end
end

-- Road index (bands / caps / junction clearances) rebuilt lazily after topology changes.
local _roadIndexCache: PlotGeometry.RoadIndex? = nil
-- Zoned parcels the index judges new seats against (PlotGeometry.RoadIndex.parcels): the same
-- re-plan of each group the clients make from the synced list. Marked stale by whatever is
-- about to plan (place, a road refit, a re-zone), rebuilt on the next roadIndex().
local _parcelsDirty = true
local function roadIndex(breathe: (() -> ())?): PlotGeometry.RoadIndex
	local idx = _roadIndexCache
	if not idx then
		idx = PlotGeometry.buildRoadIndex(
			if _roadService then _roadService.getNetwork():getSegments() else {},
			PlacementFit.seatOccupied,
			breathe
		)
		_roadIndexCache = idx
		_parcelsDirty = true
	end
	if _parcelsDirty then
		local parcels: { PlotGeometry.ParcelEntry } = {}
		for _, g in _groups do
			if breathe then breathe() end
			local seg = segmentById(g.segmentId)
			if seg then
				for _, e in PlotGeometry.groupParcels(seg, g.side, g.t0, g.t1, g.depth, g.width, g.uniform == true, breathe) do
					table.insert(parcels, e)
				end
			end
		end
		idx.parcels = parcels
		_parcelsDirty = false
	end
	return idx
end

-- Placements of a group: re-plan its span through the SAME pipeline the client previews
-- with. Deterministic, so a restore rebuilds exactly what was placed.
local function groupPlacements(g: PlotGroup): { PlotGeometry.Placement }
	local seg = segmentById(g.segmentId)
	if not seg then return {} end
	if g.side == 2 or g.side == -2 then -- dead-end cap ring (its own occupancy lane)
		return PlotGeometry.planCapRing(roadIndex(), seg, g.side == 2, g.t0, g.t1, g.depth, g.width, g.uniform)
	end
	return PlotGeometry.planSpan(roadIndex(), seg, g.side, g.t0, g.t1, g.depth, g.width, g.uniform)
end

-- Develop one building per placement. Blocked placements never build. A polygon parcel
-- persists its trimmed building width (bw); the terrain pad covers the WHOLE parcel.
local function developGroup(g: PlotGroup, mode: string, placements: { PlotGeometry.Placement }?, breathe: (() -> ())?): number
	if not _building then return 0 end
	local ids: { string } = {}
	local seats: { Seat } = {}
	local rects: { { Vector3 } } = {}
	g.buildingIds, g.placed = ids, seats
	local kerbless = kerblessFor(g)
	for _, pl in (placements or groupPlacements(g)) do
		if not pl.blocked then
			local w = g.bw or pl.w
			local pivot = pl.pivot
			if w ~= pl.w then
				pivot = PlotGeometry.buildingRect(pl.plot, w, pl.d)
			end
			pivot = seatPivot(pivot)
			local fw, fd = r1(pl.plot.frontage), r1(pl.plot.depth)
			local bpId = _building.developPlot(pivot, g.zone, w, pl.d, mode, g.segmentId, g.building, fw, fd, g.density, kerbless)
			if bpId then
				table.insert(ids, bpId)
				table.insert(seats, { pivot = pivot, w = w, d = pl.d, fw = fw, fd = fd, bpId = bpId,
					t0 = pl.plot.t0, t1 = pl.plot.t1 })
				table.insert(rects, parcelRect(pl.plot))
			end
		end
		if breathe then breathe() end
	end
	g.buildingIds = ids
	g.placed = seats
	-- A player laying out a zone clears what stands on it; a load never clears its own trees.
	if mode ~= "instant" and _clearNature and #rects > 0 then _clearNature(rects) end
	return #ids
end

-- Rebuild a group from its SAVED seats: no re-planning, no road index, no blocking test.
-- Every building goes back exactly where it stood. A load must not re-derive the city --
-- planSpan reads the whole road network, so any road added, moved or repaired since the
-- save would silently move, drop, or invent houses.
local function developSeats(g: PlotGroup, seats: { Seat }, breathe: (() -> ())?): number
	local ids: { string } = {}
	g.buildingIds, g.placed = ids, seats
	if _building then
		local kerbless = kerblessFor(g)
		for _, s in seats do
			s.bpId = _building.developPlot(s.pivot, g.zone, s.w, s.d, "instant", g.segmentId, g.building, s.fw, s.fd, g.density, kerbless)
			if s.bpId then table.insert(ids, s.bpId) end
			if breathe then breathe() end
		end
	end
	g.buildingIds = ids
	g.placed = seats
	return #ids
end

-- Decode persisted seats. A save blob is untrusted input, so a row only survives as a full
-- set of finite, on-map numbers; anything else is dropped rather than fed into a CFrame.
local function readSeats(raw: any): { Seat }?
	if typeof(raw) ~= "table" or #raw == 0 then return nil end
	local out: { Seat } = {}
	for _, r in raw do
		if typeof(r) == "table" and (#r == 8 or #r == 10) then
			local ok = true
			for i = 1, #r do
				if not isFinite(r[i]) or math.abs(r[i]) > 1e6 then ok = false break end
			end
			if ok then
				table.insert(out, {
					pivot = CFrame.new(r[1], r[2], r[3]) * CFrame.Angles(0, math.rad(r[4]), 0),
					w = math.clamp(math.floor(r[5]), 2, 5),
					d = math.clamp(math.floor(r[6]), 2, 5),
					fw = math.max(0, r[7]),
					fd = math.max(0, r[8]),
					t0 = if #r == 10 then math.clamp(r[9], 0, 1) else nil,
					t1 = if #r == 10 then math.clamp(r[10], 0, 1) else nil,
				})
			end
		end
	end
	return if #out > 0 then out else nil
end

-- Set while this service is tearing groups down itself. Demolishing a building fires
-- BuildingService's removal signal straight back at us, and reacting to it mid-teardown
-- would mutate _groups while restore/clear are iterating it -- inserting a split group
-- during a `for id in _groups` loop is undefined behaviour, not just wasted work.
local _pruning = false

-- Contiguous runs of seats, in frontage order. Bulldozing a house out of the MIDDLE of a
-- run splits it in two, so the gap it leaves becomes buildable again instead of staying
-- locked behind the old span.
local function seatRuns(seats: { Seat }): { { Seat } }
	table.sort(seats, function(a, b) return (a.t0 :: number) < (b.t0 :: number) end)
	local runs: { { Seat } } = {}
	local cur: { Seat } = {}
	for _, s in seats do
		if #cur > 0 and (s.t0 :: number) - (cur[#cur].t1 :: number) > 1e-3 then
			table.insert(runs, cur)
			cur = {}
		end
		table.insert(cur, s)
	end
	if #cur > 0 then table.insert(runs, cur) end
	return runs
end

local function eraseGroup(id: number)
	local g = _groups[id]
	if not g then return end
	_planningRevision += 1
	local wasPruning = _pruning
	_pruning = true
	if _building then
		for _, bpId in g.buildingIds do
			_building.demolish(bpId)
		end
	end
	_pruning = wasPruning
	_groups[id] = nil
end

-- After seats left a group, shrink its claimed frontage to what still stands: nothing left
-- erases the group, a hole splits it into one group per contiguous run. The freed frontage
-- is zonable again straight away. Appends the wire deltas to `removed` / `changed`. Never
-- call it while iterating _groups: a split inserts groups.
local function resplit(g: PlotGroup, removed: { number }, changed: { any })
	local seats = g.placed or {}
	if #seats == 0 then
		eraseGroup(g.id)
		table.insert(removed, g.id)
		return
	end
	-- Seats saved before spans existed cannot say which stretch to give back, so those
	-- groups keep their original span rather than shrink to a wrong one.
	for _, s in seats do
		if not (s.t0 and s.t1) then
			addWire(changed, g)
			return
		end
	end
	for i, run in seatRuns(seats) do
		local target = g
		if i > 1 then
			_nextId += 1
			target = table.clone(g)
			target.id = _nextId
			_groups[target.id] = target
		end
		local ids: { string } = {}
		for _, s in run do
			if s.bpId then table.insert(ids, s.bpId) end
		end
		target.placed = run
		target.buildingIds = ids
		target.t0 = run[1].t0 :: number
		target.t1 = run[#run].t1 :: number
		addWire(changed, target)
	end
end

-- Occupied frontage intervals on (segId, side): every existing group there, plus any `extra`
-- intervals created earlier in the same batch (so two cells in one drag can't both take a spot).
local function occupiedFor(segId: number, side: number, extra: { { number } }?): { { number } }
	local occ: { { number } } = {}
	for _, g in _groups do
		if g.segmentId == segId and g.side == side then
			occ[#occ + 1] = { g.t0, g.t1 }
		end
	end
	if extra then
		for _, iv in extra do occ[#occ + 1] = iv end
	end
	return occ
end

-- Parts of [a,b] not covered by any interval in `occ` -- so a placement fills only free frontage.
local function freeIntervals(a: number, b: number, occ: { { number } }): { { number } }
	table.sort(occ, function(x, y) return x[1] < y[1] end)
	local free: { { number } } = {}
	local cur = a
	for _, o in occ do
		if o[2] <= cur or o[1] >= b then continue end
		if o[1] > cur then free[#free + 1] = { cur, math.min(o[1], b) } end
		cur = math.max(cur, o[2])
		if cur >= b then break end
	end
	if cur < b - 1e-4 then free[#free + 1] = { cur, b } end
	return free
end

-- ---- corner lots -------------------------------------------------------------------------
-- Cities: Skylines puts a building on the outside corner of a bend. The rows here stopped at
-- the node and left that whole corner as bare grass. When a zoned row runs right up to a bend
-- that turns AWAY from it, one more parcel carries the row on past the node: the row's depth,
-- as wide as the parcel beside it (narrower if that is all that fits), its front facing the
-- end of the road and the bend. TerrainPadService's gap fill grades the strip left between it
-- and the row on the other road. The seat is stored with the group like any other (a zero-
-- length slice at the row's end), so saves, loads and the bulldozer treat it the same.
local CORNER_TURN_DOT = -0.5 -- the other road must turn at least ~30 deg away from the row

local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude < 1e-4 then Vector3.xAxis else f.Unit
end

-- The corner parcels past the row's node end, widest first (nil when this end is not the
-- outside of a bend). `edge` is the row's parcel at that end.
local function cornerCandidates(seg: any, side: number, atEnd: boolean, edge: PlotGeometry.Placement, minLots: number): { PlotGeometry.Placement }
	local out: { PlotGeometry.Placement } = {}
	if not _roadService or (side ~= 1 and side ~= -1) then return out end
	local net = _roadService.getNetwork()
	local nodeId = if atEnd then seg.endNode else seg.startNode
	local node = nodeId and net:getNodes()[nodeId]
	if not node or #node.segments ~= 2 then return out end -- a junction or a dead end
	if net.getRoundaboutForNode and net:getRoundaboutForNode(nodeId) then return out end
	local other = segmentById(if node.segments[1] == seg.id then node.segments[2] else node.segments[1])
	if not other or other.id == seg.id then return out end
	local otherAtEnd = other.endNode == nodeId

	local tanHere = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, if atEnd then 1 else 0)
	local along = flatUnit(if atEnd then tanHere else -tanHere) -- carries the row on past the node
	local tanOther = BezierUtil.tangent(other.p0, other.p1, other.p2, other.p3, if otherAtEnd then 1 else 0)
	local away = flatUnit(if otherAtEnd then -tanOther else tanOther) -- the other road leaving the node
	local inward = flatUnit(Vector3.new(-tanHere.Z, 0, tanHere.X) * side) -- toward the row's backyards
	if inward:Dot(away) > CORNER_TURN_DOT then return out end -- the inside of the bend, or barely one

	local plot = edge.plot
	local front = if (plot.frontB - plot.frontA):Dot(along) >= 0 then plot.frontB else plot.frontA
	local depth = plot.depth
	local t = if atEnd then plot.t1 else plot.t0
	local dLots = PlotGeometry.fitDepthLots(depth)
	local idx = roadIndex()

	-- Widest first: a parcel whose yard runs right out to where the other road's row ends
	-- (its back line, at the same depth), so the corner is one lot rather than a lot and a
	-- leftover strip. The building on it is as wide as a template gets and sits centred.
	local sizes: { { number } } = {}
	local otherIn = flatUnit(Vector3.new(-tanOther.Z, 0, tanOther.X))
	if otherIn:Dot(along) < 0 then otherIn = -otherIn end -- the other road's outside: the corner
	local reachOut = otherIn:Dot(along)
	if reachOut > 0.2 then
		local otherSide = if (Vector3.new(-tanOther.Z, 0, tanOther.X)):Dot(otherIn) > 0 then 1 else -1
		local backLine = PlotGeometry.frontOffset(other.roadType, otherSide) + depth
		local nodePos = if atEnd then seg.p3 else seg.p0
		local W = (backLine - Vector3.new(front.X - nodePos.X, 0, front.Z - nodePos.Z):Dot(otherIn)) / reachOut
		local lots = math.min(5, math.floor(W / LOT + 1e-3))
		if lots >= minLots and W <= 7 * LOT then table.insert(sizes, { W, lots }) end
	end
	for lots = math.max(edge.parcelLots, minLots), minLots, -1 do
		table.insert(sizes, { lots * LOT, lots })
	end

	for _, size in sizes do
		local W, lots = size[1], size[2]
		local fA, fB = front, front + along * W
		local cp: PlotGeometry.Plot = {
			frontA = fA, frontB = fB, backB = fB + inward * depth, backA = fA + inward * depth,
			center = fA + along * (W * 0.5) + inward * (depth * 0.5),
			frontage = W, depth = depth, angleDeg = math.deg(math.atan2(along.X, along.Z)),
			t0 = t, t1 = t,
		}
		local pivot, corners = PlotGeometry.buildingRect(cp, lots, dLots)
		if not PlotGeometry.buildingBlocked(idx, corners, seg.id)
			and not PlotGeometry.rectOnRoad(idx, { cp.frontA, cp.frontB, cp.backB, cp.backA }, seg.id) then
			table.insert(out, { plot = cp, segId = seg.id, side = side, parcelLots = lots, w = lots, d = dLots,
				pivot = pivot, corners = corners, blocked = false } :: any)
		end
	end
	return out
end

-- Try the corner lot at one end of a freshly developed row; adds its seat to the group.
local function developCorner(g: PlotGroup, seg: any, atEnd: boolean, edge: PlotGeometry.Placement, mode: string)
	if not _building or not g.placed then return end
	local minLots = if g.zone == "Residential" and not g.density then PlotGeometry.MIN_HOUSE_LOTS else 2
	for _, pl in cornerCandidates(seg, g.side, atEnd, edge, minLots) do
		local pivot = seatPivot(pl.pivot)
		local fw, fd = r1(pl.plot.frontage), r1(pl.plot.depth)
		local bpId = _building.developPlot(pivot, g.zone, pl.w, pl.d, mode, g.segmentId, g.building, fw, fd, g.density, kerblessFor(g))
		if bpId then
			table.insert(g.buildingIds, bpId)
			table.insert(g.placed, { pivot = pivot, w = pl.w, d = pl.d, fw = fw, fd = fd, bpId = bpId,
				t0 = pl.plot.t0, t1 = pl.plot.t1 })
			if _clearNature then _clearNature({ parcelRect(pl.plot) }) end
			return
		end
	end
end

-- Full snapshot to a joining player (or everyone after a restore).
function PlotService.broadcastFull(target: Player?)
	if not _net then return end
	local list: { any } = {}
	for _, g in _groups do addWire(list, g) end
	local payload = { full = true, groups = list }
	if target then
		_net.SyncPlots:FireClient(target, payload)
	else
		_net.SyncPlots:FireAllClients(payload)
	end
end

local function placePlots(player: Player, data: any)
	if not canEdit(player) then return end
	if typeof(data) ~= "table" then return end
	_parcelsDirty = true

	local now = os.clock()
	local last = _lastPlaceAt[player]
	if last and now - last < PLACE_COOLDOWN then return end
	_lastPlaceAt[player] = now

	-- Erase: remove the group by id (the client picks it under the cursor).
	if isFinite(data.erase) then
		local id = data.erase
		if _groups[id] then
			eraseGroup(id)
			_net.SyncPlots:FireAllClients({ removed = { id } })
		end
		return
	end

	if not (ZoneTypes.isValid(data.zone) and data.zone ~= "None") then return end
	local zone = data.zone
	local depth = math.clamp(if isFinite(data.depth) then data.depth else DEFAULT_DEPTH, MIN_DEPTH, MAX_DEPTH)
	local width = math.clamp(if isFinite(data.width) then data.width else PlotGeometry.DEFAULT_PLOT_WIDTH,
		PlotGeometry.MIN_PLOT_WIDTH, MAX_WIDTH)
	local mode = if data.immediate == true then "stamp" else "grow"
	local building = if typeof(data.building) == "string" then data.building else nil
	local uniform = data.uniform == true
	-- The dock's density card. Only Medium has its own stock so far, so High and Mixed build
	-- the densest stock there is instead of quietly falling back to houses. A picked building
	-- names its own template, so it ignores the card.
	-- ponytail: give High/Mixed their own folders here once their templates exist.
	local wanted = if zone == "Residential" and not building and typeof(data.density) == "string" then data.density else nil
	if wanted and _densityAllowed and not _densityAllowed(wanted) then
		warn(("[PlotService] place: %s asked for locked density %s"):format(player.Name, wanted))
		return
	end
	local density = if wanted == "Medium" or wanted == "High" or wanted == "Mixed" then "Medium" else nil
	if zone == "Residential" and not density then
		width = math.max(width, PlotGeometry.MIN_HOUSE_LOTS * LOT)
	end

	local created: { any } = {}
	local totalCreated = 0
	local cityRevision, topologyRevision, planningRevision = _cityRevision, _topologyRevision, _planningRevision
	local slice = os.clock()
	local function flushCreated()
		if #created == 0 then return end
		_net.SyncPlots:FireAllClients({ groups = created })
		created = {}
	end
	local function breathe()
		if os.clock() - slice < PLACE_WORK_BUDGET then return end
		flushCreated()
		task.wait()
		if not player.Parent or not canEdit(player) or cityRevision ~= _cityRevision or topologyRevision ~= _topologyRevision or planningRevision ~= _planningRevision then
			if player.Parent and _net.Notify then
				_net.Notify:FireClient(player, { text = "Zoning stopped because the city or roads changed. Completed plots were kept; zone the remaining area again.", kind = "info", duration = 8 })
			end
			error(PLACEMENT_CANCELLED, 0)
		end
		slice = os.clock()
	end
	local batchExtra: { [string]: { { number } } } = {}

	local function spanFree(segId: number, side: number, t0: number, t1: number): boolean
		local key = tostring(segId) .. ":" .. tostring(side)
		batchExtra[key] = batchExtra[key] or {}
		for _, o in occupiedFor(segId, side, batchExtra[key]) do
			if t0 < o[2] - 1e-4 and t1 > o[1] + 1e-4 then return false end
		end
		return true
	end

	-- Manor Lords area zoning: a node-polygon. Planned through the SAME pipeline the client
	-- previewed; every buildable parcel becomes its own group (own span, own depth).
	if typeof(data.poly) == "table" then
		local poly: { Vector3 } = {}
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, p in data.poly do
			if typeof(p) ~= "Vector3" or not (isFinite(p.X) and isFinite(p.Y) and isFinite(p.Z)) then return end
			poly[#poly + 1] = p
			minX = math.min(minX, p.X); maxX = math.max(maxX, p.X)
			minZ = math.min(minZ, p.Z); maxZ = math.max(maxZ, p.Z)
		end
		if #poly < 3 or #poly > 10 then return end
		if maxX - minX > 2048 or maxZ - minZ > 2048 then return end
		local segsAll = if _roadService then _roadService.getNetwork():getSegments() else {}
		local fitBuilding = not (zone == "Residential" and not density)
		for _, pl in PlotGeometry.planPolygon(segsAll, roadIndex(breathe), poly, width, uniform, fitBuilding, breathe) do
			if totalCreated >= MAX_PER_PLACE then break end
			if not pl.blocked and spanFree(pl.segId, pl.side, pl.plot.t0, pl.plot.t1) then
				_nextId += 1
				local g: PlotGroup = {
					id = _nextId, segmentId = pl.segId, side = pl.side,
					t0 = pl.plot.t0, t1 = pl.plot.t1,
					-- width is STUDS everywhere: the group re-plans from it on reload.
					depth = pl.plot.depth, width = pl.parcelLots * LOT, uniform = true, bw = pl.w,
					zone = zone, building = building, density = density, buildingIds = {},
				}
				if developGroup(g, mode, { pl }) > 0 then
					_groups[g.id] = g
					created[#created + 1] = toWire(g)
				totalCreated += 1
					table.insert(batchExtra[tostring(pl.segId) .. ":" .. tostring(pl.side)], { g.t0, g.t1 })
				else
					_nextId -= 1
				end
			end
			breathe()
		end
		flushCreated()
		return
	end

	-- Accept a batch of cells (a drag) or a single cell (a click).
	local list: { any }
	if typeof(data.cells) == "table" then
		list = data.cells
	elseif isFinite(data.t0) then
		list = { { seg = data.seg, side = data.side, t0 = data.t0, t1 = data.t1 } }
	else
		return
	end

	for _, c in list do
		if totalCreated >= MAX_PER_PLACE then break end
		if typeof(c) ~= "table" then continue end
		local segId = c.seg
		local side = c.side
		if not (isFinite(segId) and isFinite(c.t0) and isFinite(c.t1)) then continue end
		local isCap = side == 2 or side == -2 -- dead-end cap ring lane
		local rev = c.rev == true -- a drag pulled backwards packs from its far end (PlotController)
		if not isCap and side ~= 1 and side ~= -1 then continue end
		if not segmentById(segId) then continue end

		local t0 = math.clamp(math.min(c.t0, c.t1), 0, 1)
		local t1 = math.clamp(math.max(c.t0, c.t1), 0, 1)
		if t1 - t0 < 1e-3 then continue end

		local key = tostring(segId) .. ":" .. tostring(side)
		batchExtra[key] = batchExtra[key] or {}
		local occ = occupiedFor(segId, side, batchExtra[key])
		local seg = segmentById(segId)
		local idx = roadIndex(breathe)

		-- Contiguous groups keep blocked frontage free; long runs split into bounded chunks
		-- so completed groups can publish and yield without exposing partial state.
		local run: { PlotGeometry.Placement } = {}
		-- Where this side's zonable frontage starts and ends: a row reaching either is at the
		-- node, and may carry on round the outside of a bend (developCorner).
		local loT: number?, hiT: number? = nil, nil
		if not isCap then loT, hiT = PlotGeometry.clampSpan(idx, seg, 0, 1, side) end
		local function flushRun()
			if #run == 0 then return end
			_nextId += 1
			local g: PlotGroup = {
				id = _nextId, segmentId = segId, side = side,
				t0 = run[1].plot.t0, t1 = run[#run].plot.t1,
				depth = depth, width = width, uniform = if uniform then true else nil,
				zone = zone, building = building, density = density, buildingIds = {},
			}
			if developGroup(g, mode, run) > 0 then
				if loT and hiT and not uniform and not building then
					if run[#run].plot.t1 >= hiT - 1e-3 then developCorner(g, seg, true, run[#run], mode) end
					if run[1].plot.t0 <= loT + 1e-3 then developCorner(g, seg, false, run[1], mode) end
				end
				_groups[g.id] = g
				created[#created + 1] = toWire(g)
					totalCreated += 1
				table.insert(batchExtra[key], { g.t0, g.t1 })
			else
				_nextId -= 1
			end
			run = {}
			breathe()
		end

		for _, iv in freeIntervals(t0, t1, occ) do
			local plans = if isCap
				then PlotGeometry.planCapRing(idx, seg, side == 2, iv[1], iv[2], depth, width, uniform, breathe)
				else PlotGeometry.planSpan(idx, seg, side, iv[1], iv[2], depth, width, uniform, rev, breathe)
			for _, pl in plans do
				if totalCreated >= MAX_PER_PLACE then break end
				if pl.blocked then
					flushRun()
				elseif #run > 0 and pl.plot.t0 - run[#run].plot.t1 > 1e-3 then
					flushRun()
					table.insert(run, pl)
				else
					table.insert(run, pl)
				end
				if #run >= MAX_GROUP_SEATS then flushRun() end
			end
			flushRun()
			if totalCreated >= MAX_PER_PLACE then break end
		end
		breathe()
	end

	flushCreated()
end

local function boundedArray(value: any, maximum: number): boolean
	if typeof(value) ~= "table" or #value > maximum then return false end
	local count = 0
	for key in value do
		count += 1
		if count > maximum or typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
	end
	return count == #value
end

local function place(player: Player, data: any)
	if not canEdit(player) or typeof(data) ~= "table" then return end
	if data.poly ~= nil and not boundedArray(data.poly, 10) then return end
	if data.cells ~= nil and not boundedArray(data.cells, MAX_INPUT_CELLS) then return end
	if _placementBusy then
		if _net.Notify then
			_net.Notify:FireClient(player, { text = "Finishing your previous zoning. Try again in a moment.", kind = "info", duration = 4 })
		end
		return
	end
	_placementBusy = true
	local ok, err = xpcall(function() placePlots(player, data) end, debug.traceback)
	_placementBusy = false
	if not ok and not string.find(tostring(err), PLACEMENT_CANCELLED, 1, true) then
		warn("[PlotService] zoning failed for " .. player.Name .. ": " .. tostring(err))
		PlotService.broadcastFull()
	end
end

-- Placements for one seat's own stretch of frontage, through the same pipeline that planned
-- it originally -- so a replacement is whatever the planner would put there today.
local function planSub(g: PlotGroup, seg: any, t0: number, t1: number): { PlotGeometry.Placement }
	if g.side == 2 or g.side == -2 then
		return PlotGeometry.planCapRing(roadIndex(), seg, g.side == 2, t0, t1, g.depth, g.width, g.uniform)
	end
	return PlotGeometry.planSpan(roadIndex(), seg, g.side, t0, t1, g.depth, g.width, g.uniform)
end

-- Rebuild whatever still fits on one stretch of a group's frontage after the house that
-- held it came down. Appends to `seats` / g.buildingIds; returns how many went up (0 means
-- the road genuinely took the plot). Callers own the _pruning guard.
local function replanStretch(g: PlotGroup, seg: any, t0: number, t1: number, seats: { Seat }): number
	local built = 0
	for _, pl in planSub(g, seg, t0, t1) do
		if pl.blocked then continue end
		local pivot = seatPivot(pl.pivot)
		local fw, fd = r1(pl.plot.frontage), r1(pl.plot.depth)
		local bpId = _building.developPlot(pivot, g.zone, pl.w, pl.d, "instant", g.segmentId, g.building, fw, fd, g.density, kerblessFor(g))
		if bpId then
			table.insert(g.buildingIds, bpId)
			table.insert(seats, { pivot = pivot, w = pl.w, d = pl.d, fw = fw, fd = fd,
				bpId = bpId, t0 = pl.plot.t0, t1 = pl.plot.t1 })
			built += 1
		end
	end
	return built
end

-- Put a bulldozed seat back somewhere it fits: its own stretch first, then whatever frontage
-- the group still has free. A road edit RE-ZONES the plot -- it never quietly costs the city a
-- building -- so a house the new pavement swallowed comes back beside it if there is room.
-- Only a deliberate bulldoze unzones. Callers own the _pruning guard.
local function rehouse(g: PlotGroup, seg: any, t0: number, t1: number, seats: { Seat }): number
	local built = replanStretch(g, seg, t0, t1, seats)
	if built > 0 then return built end
	local occ: { { number } } = {}
	for _, s in seats do
		if s.t0 and s.t1 then table.insert(occ, { s.t0, s.t1 }) end
	end
	for _, iv in freeIntervals(g.t0, g.t1, occ) do
		built = replanStretch(g, seg, iv[1], iv[2], seats)
		if built > 0 then return built end
	end
	return 0
end

-- XZ box around the segments a change touched, or nil when the change is a bulk rebuild
-- (or carries no usable segment list) and should be skipped.
local function refitBounds(change: any): { number }?
	if typeof(change) ~= "table" then return nil end
	local ids = change.segmentIds
	if typeof(ids) ~= "table" or #ids == 0 then return nil end
	local removedCount = if typeof(change.removedSegmentIds) == "table" then #change.removedSegmentIds else 0
	if #ids + removedCount > MAX_REFIT_SEGS then return nil end
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, id in ids do
		local seg = segmentById(id)
		if seg then
			for _, p in { seg.p0, seg.p1, seg.p2, seg.p3 } do
				minX = math.min(minX, p.X); maxX = math.max(maxX, p.X)
				minZ = math.min(minZ, p.Z); maxZ = math.max(maxZ, p.Z)
			end
		end
	end
	if minX > maxX then return nil end
	return { minX - REFIT_REACH, maxX + REFIT_REACH, minZ - REFIT_REACH, maxZ + REFIT_REACH }
end

-- A road drawn, moved or widened beside standing houses leaves some of them lapping over the
-- new pavement: RoadService only clears buildings whose CENTRE the road covers, so a corner
-- house keeps a wall in the carriageway. Re-test every seat near the edit against the rebuilt
-- road index; one that now overlaps is demolished and its own frontage re-planned, so a
-- smaller house that fits takes its place. Nothing that fits means the plot simply goes.
local function refitSeats(change: any)
	if not _building then return end
	_parcelsDirty = true
	local box = refitBounds(change)
	if not box then return end
	local idx = roadIndex()
	local removed: { number } = {}
	local changed: { any } = {}
	local touched: { PlotGroup } = {}

	-- Nothing inside this loop inserts or erases a group; resplit runs after it.
	for _, g in _groups do
		local seg = segmentById(g.segmentId)
		local seats = g.placed
		if seg and seats then
			local bad: { number } = {}
			for i, s in seats do
				local p = s.pivot.Position
				if p.X >= box[1] and p.X <= box[2] and p.Z >= box[3] and p.Z <= box[4]
					-- ponytail: nil, not g.segmentId. Connecting a road SPLITS the one it meets, and the far
				-- half gets a NEW segment id -- so every standing house on it stopped being "on its
				-- own road" and failed the stricter cross-street sidewalk test, which bulldozed and
				-- replanned a whole zoned street. Refit only judges real overlap with pavement
				-- (the lenient reach for every segment); sidewalk strictness stays a PLANNING rule.
				-- rectOnRoad, NOT buildingBlocked: the index carries an "is anything standing
				-- here?" predicate and a standing house occupies its own seat, so every house
				-- near any road edit read as blocked and was demolished + rebuilt on the spot --
				-- the houses-respawn-when-I-place-a-road churn. Only pavement counts here.
				and PlotGeometry.rectOnRoad(idx, PlotGeometry.seatCorners(s.pivot, s.w, s.d), nil) then
					table.insert(bad, i)
				end
			end
			if #bad > 0 then
				-- We do the seat bookkeeping right here, so the removal signal must not also
				-- run its own split/erase pass over the group we are editing.
				local wasPruning = _pruning
				_pruning = true
				for i = #bad, 1, -1 do
					local s = table.remove(seats, bad[i]) :: Seat
					if s.bpId then
						_building.demolish(s.bpId)
						local at = table.find(g.buildingIds, s.bpId)
						if at then table.remove(g.buildingIds, at) end
					end
					-- Seats saved before spans existed cannot say which stretch to re-plan.
					if s.t0 and s.t1 then
						rehouse(g, seg, s.t0, s.t1, seats)
					end
				end
				_pruning = wasPruning
				-- A seat the new road took and nothing replaced gives its stretch back;
				-- a group that kept its old span there locked the hole against rezoning.
				table.insert(touched, g)
			end
		end
	end
	for _, g in touched do resplit(g, removed, changed) end

	if _net and (#removed > 0 or #changed > 0) then
		_net.SyncPlots:FireAllClients({
			removed = if #removed > 0 then removed else nil,
			groups = if #changed > 0 then changed else nil,
		})
	end
end

-- Studs of road movement a standing house is carried along by. Past this the street has
-- changed shape rather than just shifted, so the houses stay where they are and refitSeats
-- judges them like any other edit.
local MAX_SEAT_SHIFT = 32

-- The Move tool takes a leg OUT and puts it back under a NEW segment id. Without this every
-- group on it reads as "my road was deleted", so nudging a road one stud bulldozed every
-- zone on it. Re-point the groups at the new id, and slide each house by however far the
-- road actually moved under its own stretch of frontage. Returns true if anything moved.
local function followMovedRoads(moved: any): boolean
	if typeof(moved) ~= "table" or not _building then return false end
	local any = false
	for _, g in _groups do
		local mv = moved[g.segmentId]
		if typeof(mv) ~= "table" or not isFinite(mv.id) then continue end
		g.segmentId = mv.id
		any = true
		local a, b = mv.from, mv.to
		for _, s in (g.placed or {}) do
			local t = if s.t0 and s.t1 then (s.t0 + s.t1) * 0.5 else 0.5
			local shift = BezierUtil.point(b[1], b[2], b[3], b[4], t)
				- BezierUtil.point(a[1], a[2], a[3], a[4], t)
			local d = shift.Magnitude
			if s.bpId and d > 0.05 and d <= MAX_SEAT_SHIFT then
				local pivot = seatPivot(s.pivot + shift)
				if _building.relocate(s.bpId, pivot) then s.pivot = pivot end
			end
		end
	end
	return any
end

-- A one-way flipped IN PLACE keeps its id, but its curve now runs the other way: the same kerb
-- is the opposite side sign, and every frontage parameter t mirrors to 1 - t. The houses stay
-- exactly where they stand; only the bookkeeping turns round. A dead-end cap ring keeps its
-- arc (measured outward from the node, which has not moved) and swaps end for start.
local function followReversedRoads(reversed: any): boolean
	if typeof(reversed) ~= "table" then return false end
	local any = false
	for _, g in _groups do
		if not reversed[g.segmentId] then continue end
		any = true
		g.side = -g.side
		if math.abs(g.side) == 1 then
			g.t0, g.t1 = 1 - g.t1, 1 - g.t0
			for _, s in (g.placed or {}) do
				if s.t0 and s.t1 then s.t0, s.t1 = 1 - s.t1, 1 - s.t0 end
			end
		end
	end
	if any then _parcelsDirty = true end
	return any
end

-- Which road a roadless building could re-attach to: the segment it stands square to, at the
-- distance a lot on that road's side would stand. Returns the segment, side and the seat's
-- frontage span on it, or nil.
local function seatRoad(s: Seat, segs: { [number]: any }): (number?, number?, number?, number?)
	local p = s.pivot.Position
	local look = s.pivot.LookVector
	local face = Vector3.new(look.X, 0, look.Z)
	if face.Magnitude < 1e-3 then return nil end
	face = face.Unit
	local bestId, bestSide, bestT, bestErr = nil, 0, 0, REHOME_TOL
	for id, seg in segs do
		local near = false
		for _, c in { seg.p0, seg.p1, seg.p2, seg.p3 } do
			if math.abs(c.X - p.X) < REHOME_REACH and math.abs(c.Z - p.Z) < REHOME_REACH then near = true; break end
		end
		if not near then
			local mid = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0.5)
			if math.abs(mid.X - p.X) >= REHOME_REACH or math.abs(mid.Z - p.Z) >= REHOME_REACH then continue end
		end
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, p, 24)
		if t <= 0 or t >= 1 then continue end -- off the end of the road, not along it
		local cp = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local off = Vector3.new(p.X - cp.X, 0, p.Z - cp.Z)
		local d = off.Magnitude
		if d < 1e-3 or math.abs(off.Unit:Dot(face)) < 0.9 then continue end -- not square to it
		local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local side = if off:Dot(Vector3.new(-tan.Z, 0, tan.X)) >= 0 then 1 else -1
		local want = PlotGeometry.frontOffset(seg.roadType, side) + s.d * LOT * 0.5
		local err = math.abs(d - want)
		if err < bestErr then bestId, bestSide, bestT, bestErr = id, side, t, err end
	end
	if not bestId then return nil end
	local t0, t1 = PlotGeometry.spanForWidth(segs[bestId], bestT, s.fw)
	return bestId, bestSide, t0, t1
end

-- Re-attach the roadless buildings a new road runs along. Seats on one road and side form
-- one group; what nothing reaches stays roadless in the original group.
local function rehomeRoadless(changed: { any }, removed: { number }): number
	local segs = if _roadService then _roadService.getNetwork():getSegments() else {}
	local list: { PlotGroup } = {}
	for _, g in _groups do
		if g.roadless then table.insert(list, g) end
	end
	local adopted = 0
	for _, g in list do
		local buckets: { [string]: { seg: number, side: number, seats: { Seat } } } = {}
		local rest: { Seat } = {}
		for _, seat in (g.placed or {}) do
			local segId, side, t0, t1 = seatRoad(seat, segs)
			if segId and side and t0 and t1 then
				seat.t0, seat.t1 = t0, t1
				local key = tostring(segId) .. ":" .. tostring(side)
				local b = buckets[key]
				if not b then
					b = { seg = segId, side = side, seats = {} }
					buckets[key] = b
				end
				table.insert(b.seats, seat)
			else
				table.insert(rest, seat)
			end
		end
		local reuse = #rest == 0
		for _, b in buckets do
			local target = g
			if not reuse then
				_nextId += 1
				target = table.clone(g)
				target.id = _nextId
				_groups[target.id] = target
			end
			reuse = false
			target.segmentId, target.side, target.roadless = b.seg, b.side, nil
			target.placed = b.seats
			target.buildingIds = {}
			for _, seat in b.seats do
				if seat.bpId then
					table.insert(target.buildingIds, seat.bpId)
					_building.setRoadless(seat.bpId, nil)
					adopted += 1
				end
			end
			resplit(target, removed, changed)
		end
		if g.roadless then
			g.placed = rest
			local ids: { string } = {}
			for _, seat in rest do
				if seat.bpId then table.insert(ids, seat.bpId) end
			end
			g.buildingIds = ids
		end
	end
	return adopted
end

-- Follow the roads that MOVED, put groups whose road was deleted on the roadless clock,
-- re-attach roadless ones a new road reaches, then re-fit the houses the edit left
-- overlapping pavement.
local function onTopology(change: any?)
	_topologyRevision += 1
	_roadIndexCache = nil
	local remapped = followMovedRoads(if typeof(change) == "table" then change.movedSegments else nil)
	if followReversedRoads(if typeof(change) == "table" then change.reversedSegments else nil) then
		remapped = true
	end
	local removed: { number } = {}
	local changed: { any } = {}
	-- No road left at all is a city being cleared or switched (restoreRoads clears before it
	-- replays a save): those plots are replaced straight after, so they go quietly as before.
	local clearing = next(_roadService.getNetwork():getSegments()) == nil
	local stranded = 0
	for id, g in _groups do
		if g.roadless or segmentById(g.segmentId) then continue end
		if clearing then
			eraseGroup(id)
		else
			g.roadless = 0
			g.segmentId = 0
			for _, bpId in g.buildingIds do _building.setRoadless(bpId, "grace") end
			stranded += #g.buildingIds
		end
		table.insert(removed, id)
	end
	local adopted = rehomeRoadless(changed, removed)
	if #removed > 0 or #changed > 0 then
		-- A group stranded and re-attached in one edit is only an update to the client.
		local live: { [number]: boolean } = {}
		for _, w in changed do live[w.id] = true end
		local gone: { number } = {}
		for _, id in removed do
			if not live[id] then table.insert(gone, id) end
		end
		_parcelsDirty = true
		_net.SyncPlots:FireAllClients({
			removed = if #gone > 0 then gone else nil,
			groups = if #changed > 0 then changed else nil,
		})
	end
	if stranded > adopted then
		notifyAll("Some buildings lost their road! Build a road to their front within 10 minutes, or they will be torn down.", "danger")
	elseif adopted > 0 and stranded == 0 then
		notifyAll("Road reconnected -- those buildings are safe.", "success")
	end
	refitSeats(change)
	-- ponytail: a move re-syncs the whole plot list rather than carrying its own delta --
	-- every group on the leg changed segment id, and a move is a rare interactive edit.
	if remapped then PlotService.broadcastFull() end
end

-- A demolished building unzones the plot it stood on. Bulldozing and road-clearing both
-- live in BuildingService and never touch this service, so without this the frontage stays
-- claimed: the player cannot rebuild there, and the ghost preview still reads it as taken.
local function onBuildingRemoving(bpId: string, reason: string?)
	if _pruning then return end
	_parcelsDirty = true

	local owner: PlotGroup? = nil
	local seatIdx = 0
	for _, g in _groups do
		for i, s in (g.placed or {}) do
			if s.bpId == bpId then
				owner, seatIdx = g, i
				break
			end
		end
		if owner then break end
	end
	if not owner then return end
	_planningRevision += 1

	local g = owner :: PlotGroup
	local seats = g.placed :: { Seat }
	local gone = table.remove(seats, seatIdx) :: Seat
	local at = table.find(g.buildingIds, bpId)
	if at then table.remove(g.buildingIds, at) end

	-- A road edit took this house, so the plot is RE-ZONED rather than handed back: whatever
	-- still fits beside the new pavement goes straight up. Nothing fits -> the span shrinks
	-- below, exactly as a bulldoze would. Only a deliberate demolition unzones.
	if reason == "road" and gone.t0 and gone.t1 then
		local seg = segmentById(g.segmentId)
		if seg then
			local wasPruning = _pruning
			_pruning = true
			rehouse(g, seg, gone.t0 :: number, gone.t1 :: number, seats)
			_pruning = wasPruning
		end
	end

	local removed: { number } = {}
	local changed: { any } = {}
	resplit(g, removed, changed)

	if _net then
		_net.SyncPlots:FireAllClients({
			removed = if #removed > 0 then removed else nil,
			groups = if #changed > 0 then changed else nil,
		})
	end
end

-- One second of running game time for every roadless group: families start moving out at
-- ROAD_LEAVE_AT, and at ROAD_GRACE the buildings come down. One notice per step, not per lot.
local function tickRoadless(dt: number)
	local leaving, lastCall, doomed = 0, 0, {}
	for id, g in _groups do
		local before = g.roadless
		if not before then continue end
		local now = before + dt
		g.roadless = now
		if before < ROAD_LEAVE_AT and now >= ROAD_LEAVE_AT then
			for _, bpId in g.buildingIds do _building.setRoadless(bpId, "leaving") end
			leaving += #g.buildingIds
		end
		if before < ROAD_LAST_CALL and now >= ROAD_LAST_CALL then lastCall += #g.buildingIds end
		if now >= ROAD_GRACE then table.insert(doomed, id) end
	end
	if #doomed > 0 then
		for _, id in doomed do eraseGroup(id) end -- already off the clients' plot list
		notifyAll("Buildings with no road were torn down.", "danger")
	elseif lastCall > 0 then
		notifyAll("1 minute left! Buildings with no road will be torn down -- connect a road to them.", "danger")
	elseif leaving > 0 then
		notifyAll("Families are moving out of buildings with no road. Connect a road to keep them.", "danger")
	end
end

-- Advance the roadless clock by `dt` seconds of running game time. Start() calls it every
-- second while the game is not paused.
function PlotService.advanceRoadless(dt: number)
	tickRoadless(dt)
end

-- Exposed for future queries.
function PlotService.getGroups(): { [number]: PlotGroup }
	return _groups
end

function PlotService.clear()
	_cityRevision += 1
	for id in _groups do eraseGroup(id) end
	_groups = {}
	_nextId = 0
	PlotService.broadcastFull()
end

-- Persistence: groups are the source; buildings rebuild on restore (mode "instant" = no crane).
function PlotService.serialize(): { any }
	local out: { any } = {}
	-- Groups that lost a building no removal event reported: shrink them to what stands
	-- BEFORE writing, so a save never persists a claim on frontage with nothing on it.
	local stale: { PlotGroup } = {}
	for _, g in _groups do
		for _, s in (g.placed or {}) do
			if s.bpId and _building and not _building.exists(s.bpId) then
				table.insert(stale, g)
				break
			end
		end
	end
	if #stale > 0 then
		local removed: { number } = {}
		local changed: { any } = {}
		for _, g in stale do
			local live: { Seat } = {}
			for _, s in (g.placed or {}) do
				if not s.bpId or _building.exists(s.bpId) then table.insert(live, s) end
			end
			g.placed = live
			resplit(g, removed, changed)
		end
		if _net then
			_net.SyncPlots:FireAllClients({
				removed = if #removed > 0 then removed else nil,
				groups = if #changed > 0 then changed else nil,
			})
		end
	end
	for _, g in _groups do
		-- b: the seated buildings as flat numbers {x, y, z, yawDeg, w, d, frontage, depth}.
		-- Re-snapped to the save grid on the way out: a CFrame holds float32, so reading a
		-- pivot back yields 123.4000015 for the 123.4 that went in. Left alone that noise
		-- would ride into the blob (longer numbers, and the first save after a load would
		-- differ from the one before it for no reason).
		-- Drop seats whose building is gone -- bulldozed, or cleared by a road laid over it.
		-- Neither of those paths goes through this service, so g.placed is stale by the time
		-- a save runs; without this the next load rebuilds a house the player demolished.
		-- A seat that never produced a building (no template for its size) is KEPT: dropping
		-- it would erase the plot from the save for good.
		local live: { Seat } = {}
		for _, s in (g.placed or {}) do
			if not s.bpId or not _building or _building.exists(s.bpId) then
				table.insert(live, s)
			end
		end
		g.placed = live

		local rows: { any } = {}
		for _, s in live do
			local p = s.pivot.Position
			if s.t0 and s.t1 then
				table.insert(rows, { r1(p.X), r1(p.Y), r1(p.Z), yawDegOf(s.pivot), s.w, s.d, r1(s.fw), r1(s.fd), r6(s.t0), r6(s.t1) })
			else
				table.insert(rows, { r1(p.X), r1(p.Y), r1(p.Z), yawDegOf(s.pivot), s.w, s.d, r1(s.fw), r1(s.fd) })
			end
		end
		-- s = 1 marks the seated format: b is the COMPLETE list of buildings on this frontage,
		-- so an empty b means "the player cleared them all", not "re-plan me". Without the
		-- marker a fully bulldozed group would come back fully rebuilt on the next load.
		table.insert(out, { seg = g.segmentId, side = g.side, t0 = r6(g.t0), t1 = r6(g.t1),
			depth = r6(g.depth), width = g.width, zone = g.zone, building = g.building,
			uniform = if g.uniform then true else nil, bw = g.bw, b = rows, s = 1, den = g.density,
			rl = if g.roadless then math.floor(g.roadless) else nil })
	end
	return out
end

local RESTORE_SLICE_SECONDS = 0.004

function PlotService.restore(list: any)
	_cityRevision += 1
	local cityRevision, topologyRevision = _cityRevision, _topologyRevision
	local slice = os.clock()
	local function breathe()
		if os.clock() - slice < RESTORE_SLICE_SECONDS then return end
		task.wait()
		if cityRevision ~= _cityRevision or topologyRevision ~= _topologyRevision then
			error("[PlotService] restore interrupted by a city or road change")
		end
		slice = os.clock()
	end
	_roadIndexCache = nil -- roads were just restored; rebuild against the new network
	for id in _groups do eraseGroup(id); breathe() end
	_groups = {}
	_nextId = 0
	-- CityCoreLoading blocks edits and CitySlotService blocks saves until every saved seat
	-- is restored. Keep each live group registered before a seat-level yield.
	if typeof(list) == "table" then
		for _, e in list do
			breathe()
			if typeof(e) == "table" and isFinite(e.seg) and (e.side == 1 or e.side == -1 or e.side == 2 or e.side == -2)
				and isFinite(e.t0) and isFinite(e.t1) and ZoneTypes.isValid(e.zone) and e.zone ~= "None" then
				_nextId += 1
				local g: PlotGroup = {
					id = _nextId, segmentId = e.seg, side = e.side,
					t0 = math.clamp(e.t0, 0, 1), t1 = math.clamp(e.t1, 0, 1),
					depth = math.clamp(if isFinite(e.depth) then e.depth else DEFAULT_DEPTH, MIN_DEPTH, MAX_DEPTH),
					width = if isFinite(e.width) then e.width else PlotGeometry.DEFAULT_PLOT_WIDTH,
					uniform = if e.uniform == true then true else nil,
					bw = if isFinite(e.bw) then math.clamp(e.bw, 2, 5) else nil,
					zone = e.zone, building = if typeof(e.building) == "string" then e.building else nil, buildingIds = {},
					-- Saves from before density existed carry no `den` and load as houses.
					density = if e.den == "Medium" and e.zone == "Residential" then "Medium" else nil,
					-- Saved roadless: the clock carries on where it stood, so a rejoin is no reprieve.
					roadless = if isFinite(e.rl) then math.clamp(e.rl, 0, ROAD_GRACE) else nil,
				}
				-- Saved seats replay verbatim; only a pre-seat save re-plans from the roads.
				local seats = if e.s == 1 then (readSeats(e.b) or {}) else readSeats(e.b)
				if seats and #seats == 0 then
					-- Saved with every building cleared: restoring it would only lock that
					-- frontage against zoning forever.
					_nextId -= 1
				elseif seats then
					if g.roadless then g.segmentId = 0 end
					_groups[g.id] = g
					local built = developSeats(g, seats, breathe)
					if g.roadless then
						local stage = if (g.roadless :: number) >= ROAD_LEAVE_AT then "leaving" else "grace"
						for _, bpId in g.buildingIds do _building.setRoadless(bpId, stage) end
					end
					if built < #seats then
						warn(string.format("[PlotService] segment %d: restored %d of %d saved buildings",
							g.segmentId, built, #seats))
					end
					-- Kept even when nothing built (a missing template folder, say). Dropping
					-- the group here would erase those plots from the next save for good --
					-- the seats are the only remaining record of them.
					_groups[g.id] = g
				else
					_groups[g.id] = g
					if developGroup(g, "instant", nil, breathe) == 0 then
						_groups[g.id] = nil
						_nextId -= 1
					end
				end
			end
		end
	end
	PlotService.broadcastFull()
end

-- Server-side density gate (ProgressionService.isDensityAllowed via Bootstrap). The
-- client greys a locked density card; this is what actually refuses it.
function PlotService.setUnlockCheck(fn: (density: string) -> boolean)
	_densityAllowed = fn
end

-- Injected by Bootstrap (NaturePlaceService.clearInRects): a zone clears the trees and props
-- standing on the parcels it lays out -- the set the zoning preview lights up.
function PlotService.setNatureClearance(fn: (rects: { { Vector3 } }) -> number)
	_clearNature = fn
end

function PlotService.Init(roadService: any, net: any, buildingService: any)
	_roadService = roadService
	_net = net
	_building = buildingService
end

function PlotService.Bind()
	if _bound then return end
	_bound = true

	_net.RequestPlacePlots.OnServerEvent:Connect(place)

	_net.RequestBuildingCatalog.OnServerInvoke = function(_player: Player): any
		return if _building then _building.getCatalog() else {}
	end

	if _roadService.onTopologyChanged then
		_topoDisc = _roadService.onTopologyChanged(onTopology)
	end

	if _building and _building.onBuildingRemoving then
		_bldgDisc = _building.onBuildingRemoving(onBuildingRemoving)
	end

	Players.PlayerAdded:Connect(function(p: Player)
		PlotService.broadcastFull(p)
	end)
	for _, p in Players:GetPlayers() do
		PlotService.broadcastFull(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		_lastPlaceAt[p] = nil
	end)
end

function PlotService.Start()
	-- The roadless clock: 1 s steps of RUNNING time (paused, it waits). Errors are logged
	-- and the loop carries on -- one bad group must not freeze every other lot's clock.
	task.spawn(function()
		while true do
			task.wait(1)
			if GameSpeed.get() > 0 then
				local ok, err = pcall(PlotService.advanceRoadless, 1)
				if not ok then warn("[PlotService] roadless tick failed: " .. tostring(err)) end
			end
		end
	end)
end

return PlotService
