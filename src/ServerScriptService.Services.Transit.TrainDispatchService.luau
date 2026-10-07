--!strict
local GameSpeed = require(game:GetService("ReplicatedStorage").GameSpeed)
-- TrainDispatchService
-- The passenger train fleet. A train line (a TransitService route with mode "train") is
-- run by trains that roll out of a Train Depot, call at the line's stations in order, go to
-- a Train Yard for a check-up once worn, and drive back into a depot when the line needs
-- fewer. Train Depots cap how many trains the city runs; the line's shortest platform
-- decides which train type runs it (TransitTypes.trainForPlatform).
--
-- Trains do NOT ride the car traffic AI. Each train plans its own path on the rail nav graph
-- (RoadService.getRailGraph), advances a scalar distance along that polyline, and every car
-- of the set is placed by arc length behind the head, so long trains bend through curves.
-- At a platform a train may reverse (cab at each end) instead of looping round.
--
-- SIGNALLING. Every lane edge of a path is a block, and a train only drives into blocks it
-- holds. A Two-Way (single) track is ONE block for both directions, and a train books a
-- whole run of single track at once, plus the block after it, so two trains never meet on
-- it. Junction nodes are blocks too, freed once the train's tail is through. Nothing is
-- faked: a train that cannot get track waits, and the line says why (setRouteTrainInfo).
--
-- ponytail: trains are invisible to the car AI -- cars don't yield at level crossings.
-- Ceiling: visual overlap at busy crossings. Upgrade: crossing gates that hold road edges
-- via TrafficSignalService when a train approaches.
-- ponytail: no headway control, so trains of one line can bunch up. Upgrade: hold a train
-- at a platform until the gap to the one ahead evens out.

local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TransitTypes    = require(ReplicatedStorage.Transit.TransitTypes)
local VehicleTypes    = require(ReplicatedStorage.Road.VehicleTypes)
local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)

local TrainDispatchService = {}

local WS = RoadConstants.WORLD_SCALE
local RECONCILE_INTERVAL = 1.5
local TRAIN_LIFT = 0.45        -- ride height above the rail polyline
local ACCEL = 12               -- studs/s^2, acceleration and braking
-- km/h -> studs/s, the same conversion RoadRules uses (rides the WORLD_SCALE knob).
local STUDS_PER_KMH = (1 / 3.6) / RoadConstants.STUD_TO_METER
local PORTAL_REACH = 60 * WS   -- a depot/yard/train further than this from any track is cut off
local STOP_MARGIN = 2          -- studs a train keeps short of a block it does not hold
local BOOK_AHEAD = 40          -- studs past braking distance a train books track ahead
local REVERSE_COST = 160 * WS  -- extra path length a reversal is worth avoiding
local STUCK_ALERT = 90         -- game-seconds held for track before the line says so
local EMERGE_RETRY = 1         -- game-seconds between tries to leave a building

local ALERT = table.freeze({
	track = "A station on this line can't be reached by track. Join all its stations with train track.",
	noDepot = "No trains yet: build a Train Depot right beside this line's track.",
	depotFull = "Your Train Depots are full. Build another Train Depot to run more trains.",
	stuck = "Trains are stuck waiting for each other on single track. Add a stretch of Double Track so they can pass, or run fewer trains.",
	worn = "Trains are wearing out and slowing down. Build a Train Yard beside the track.",
})
local ALERT_ORDER = { "track", "noDepot", "depotFull", "stuck", "worn" }

type Block = {
	edgeId: string,
	startD: number,     -- trail distance where the block begins (its junction connector, if any)
	edgeD: number,      -- trail distance where the lane itself begins
	endD: number,
	track: string?,     -- block key of the lane (nil for a reversal's footprint block)
	junction: string?,  -- block key of the junction node crossed to enter it
	extra: { string }?, -- footprint block: every key the train held when it reversed
}

type Plan = { pts: { Vector3 }, cum: { number }, blocks: { Block }, length: number }

type Start = { edgeId: string, at: number, pos: Vector3, cost: number, reverse: boolean }

type Train = {
	key: Model,          -- stable identity riders are keyed on (the first car built)
	cars: { Model },     -- [1] is the front car in the current direction
	spec: TransitTypes.TrainSpec,
	routeId: number,
	stopIndex: number,   -- route.stops index being driven to / dwelt at
	task: string,        -- "line" | "yard" | "depot": what the current path ends at
	phase: string,       -- "driving" | "dwelling" | "inside"
	timer: number,
	speed: number,
	headD: number,
	pts: { Vector3 }, cum: { number },
	blocks: { Block },
	booked: number,      -- blocks[1..booked] are held
	held: { [string]: boolean },
	endD: number,
	hideBefore: number?, -- cars behind this trail distance are still inside the building left
	hideAfter: number?,  -- cars past this are inside the building being entered
	baseId: number?,     -- depot / yard the train is in or driving to
	wear: number,        -- studs driven since the last check-up
	waited: number,      -- game-seconds held short of track
	issue: string?,      -- "track" | "worn": what this train reports to its line
	retire: boolean,
	leftAt: number,      -- headD when it last pulled away (a platform, or a building door)
	dead: boolean,
}

local _transit: any
local _road: any
local _net: any
local _folder: Folder
local _trains: { Train } = {}
local _holder: { [string]: Train } = {}
local _lastAlert: { [number]: string } = {}
local _seq = 0
local _reconcileAccum = 0
local _running = false

local function gameSpeed(): number
	return GameSpeed.get()
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Trains")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Trains"; f.Parent = city
	end
	return f :: Folder
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function carLen(spec: TransitTypes.TrainSpec): number return spec.carLength * WS end
local function carGap(spec: TransitTypes.TrainSpec): number return spec.carGap * WS end
local function consistLen(spec: TransitTypes.TrainSpec): number
	return spec.carCount * carLen(spec) + (spec.carCount - 1) * carGap(spec)
end

-- == Car models (procedural placeholders until the train kit lands) ===========
local M = Enum.Material
local C_WINDOW = Color3.fromRGB(18, 20, 24)
local C_SKIRT  = Color3.fromRGB(58, 60, 66)
local C_ROOF   = Color3.fromRGB(120, 122, 128)

local function carPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.CFrame = cf; p.Color = color; p.Material = mat
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- One car, authored at full scale with its nose on local +Z, then shrunk to WORLD_SCALE.
-- Root is an anchored bottom-centre part (VehicleFactory convention). Cab cars carry the
-- livery colour, a nose, windscreen and headlights; the rear cab is the same model placed
-- turned round (placeCars), which is what lets a train reverse.
local function buildCar(name: string, spec: TransitTypes.TrainSpec, cab: boolean): Model
	local L, W, H = spec.carLength, spec.width, spec.height
	local model = Instance.new("Model")
	model.Name = name
	local bodyH = H * 0.62
	local bodyY = H * 0.30 + bodyH * 0.5
	carPart(model, "Skirt", Vector3.new(W * 0.86, H * 0.30, L * 0.96), CFrame.new(0, H * 0.15, 0), C_SKIRT, M.Metal)
	local bodyL = if cab then L * 0.9 else L * 0.97
	carPart(model, "Body", Vector3.new(W, bodyH, bodyL), CFrame.new(0, bodyY, if cab then -L * 0.035 else 0), spec.body, M.SmoothPlastic)
	carPart(model, "Stripe", Vector3.new(W + 0.1, bodyH * 0.12, bodyL * 0.99), CFrame.new(0, bodyY - bodyH * 0.3, if cab then -L * 0.035 else 0), spec.loco, M.SmoothPlastic)
	carPart(model, "Windows", Vector3.new(W + 0.12, bodyH * 0.34, bodyL * 0.84), CFrame.new(0, bodyY + bodyH * 0.12, if cab then -L * 0.05 else 0), C_WINDOW, M.SmoothPlastic)
	if cab then
		carPart(model, "Nose", Vector3.new(W * 0.94, bodyH * 0.8, L * 0.08), CFrame.new(0, bodyY - bodyH * 0.1, L * 0.445), spec.loco, M.SmoothPlastic)
		carPart(model, "Windscreen", Vector3.new(W * 0.8, bodyH * 0.3, 0.3), CFrame.new(0, bodyY + bodyH * 0.2, L * 0.41), C_WINDOW, M.SmoothPlastic)
		for _, sx in { -1, 1 } do
			carPart(model, "Headlight" .. sx, Vector3.new(1.2, 0.8, 0.3), CFrame.new(sx * W * 0.3, H * 0.36, L * 0.487), Color3.fromRGB(255, 244, 214), M.Neon)
		end
	end
	carPart(model, "Roof", Vector3.new(W * 0.94, H * 0.08, L * 0.94), CFrame.new(0, H * 0.96, 0), C_ROOF, M.Metal)

	if WS ~= 1 then model:ScaleTo(WS) end

	local bboxCF, bboxSize = model:GetBoundingBox()
	local root = Instance.new("Part")
	root.Name = "Root"; root.Size = Vector3.new(0.2, 0.2, 0.2); root.Transparency = 1
	root.Anchored = true; root.CanCollide = false; root.CanTouch = false; root.CanQuery = false; root.CastShadow = false
	root.CFrame = bboxCF * CFrame.new(0, -bboxSize.Y * 0.5, 0)
	root.Parent = model
	model.PrimaryPart = root
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root; weld.Part1 = d; weld.Parent = root
			d.Anchored = false
		end
	end
	return model
end

-- == Rail graph helpers ========================================================
local function railGraph(): any?
	return _road and _road.getRailGraph and _road.getRailGraph()
end

local function network(): any?
	return _road and _road.getNetwork and _road.getNetwork()
end

local function edgeLen(e: any): number
	return e._cum[#e._cum] or e.length
end

-- Point and travel direction `d` studs along a lane.
local function onEdge(e: any, d: number): (Vector3, Vector3)
	local pts, cum = e.points, e._cum
	local n = #pts
	if n == 1 then return pts[1], e.fromDir end
	d = math.clamp(d, 0, cum[n])
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] <= d then lo = mid else hi = mid end
	end
	local span = cum[hi] - cum[lo]
	local f = if span > 1e-6 then (d - cum[lo]) / span else 0
	local dir = pts[hi] - pts[lo]
	return pts[lo]:Lerp(pts[hi], f), if dir.Magnitude > 1e-6 then dir.Unit else e.fromDir
end

-- Distance along a lane of its point nearest `pos` (flat).
local function nearestAt(e: any, pos: Vector3): number
	local pts, cum = e.points, e._cum
	local best, bestD = 0, math.huge
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local len2 = ab:Dot(ab)
		local t = if len2 > 1e-9 then math.clamp(Vector3.new(pos.X - a.X, 0, pos.Z - a.Z):Dot(ab) / len2, 0, 1) else 0
		local d = flatDist(a:Lerp(b, t), pos)
		if d < bestD then bestD = d; best = cum[i] + t * (cum[i + 1] - cum[i]) end
	end
	return best
end

-- A single track is one block for both directions; every other lane is its own block.
local function trackKey(e: any): string
	local net = network()
	local seg = net and net:getSegment(e.segmentId)
	if seg and RoadTypeCatalog.getOrDefault(seg.roadType).singleTrack then return "s" .. e.segmentId end
	return "e" .. e.id
end

local function junctionKey(nodeId: number): string?
	local net = network()
	local node = net and net:getNodes()[nodeId]
	if node and #node.segments >= 3 then return "n" .. nodeId end
	return nil
end

local function isSingle(b: Block): boolean
	return b.track ~= nil and string.sub(b.track, 1, 1) == "s"
end

-- The lane at `pos` running along `dir`, as a path start. Nil when no lane there runs that
-- way (a One-Way Track cannot be driven backwards).
local function laneStart(g: any, pos: Vector3, dir: Vector3, cost: number, reverse: boolean): Start?
	local ok, res = pcall(function() return g:NearestEdgeToward(pos, pos + dir * 50) end)
	if not ok or not res or not res.edge then return nil end
	local e = res.edge
	local at = nearestAt(e, pos)
	local p, laneDir = onEdge(e, at)
	if flatDist(p, pos) > PORTAL_REACH or laneDir:Dot(dir) < 0.3 then return nil end
	return { edgeId = e.id, at = at, pos = p, cost = cost, reverse = reverse }
end

-- Both ways along the track nearest `pos` (a depot or yard leaving onto it).
local function portalStarts(g: any, pos: Vector3): { Start }
	local out: { Start } = {}
	local ok, res = pcall(function() return g:NearestEdge(pos) end)
	if not ok or not res or not res.edge then return out end
	local _, dir = onEdge(res.edge, nearestAt(res.edge, pos))
	for _, d in { dir, -dir } do
		local s = laneStart(g, pos, d, 0, false)
		if s then table.insert(out, s) end
	end
	return out
end

-- Lane polyline + blocks for an edge route from `startAt` on the first lane to `goalAt` on
-- the last. Distances are from the path start. Nil for a route that U-turns: turning back is
-- a reversal at a platform, never a hairpin.
local function buildPlan(g: any, edgeIds: { string }, startAt: number, goalAt: number): Plan?
	local edges = {}
	for k, id in edgeIds do
		local e = g:GetEdge(id)
		if not e then return nil end
		edges[k] = e
	end
	for k = 1, #edges - 1 do
		if edges[k].segmentId == edges[k + 1].segmentId and edges[k].forward ~= edges[k + 1].forward then return nil end
	end
	local pts: { Vector3 } = {}
	local cum: { number } = {}
	local function add(p: Vector3)
		local n = #pts
		if n > 0 then
			local d = (p - pts[n]).Magnitude
			if d < 0.05 then return end
			table.insert(cum, cum[n] + d)
		else
			table.insert(cum, 0)
		end
		table.insert(pts, p)
	end
	local blocks: { Block } = {}
	local from = startAt
	for k, e in edges do
		local startD = cum[#cum] or 0
		local junction: string? = nil
		if k > 1 then
			local cpts, _, toSb = g:GetConnectionPoints(edgeIds[k - 1], edgeIds[k])
			for _, p in cpts do add(p) end
			from = toSb
			junction = junctionKey(e.fromNode)
		end
		local to = goalAt
		if k < #edges then
			local fromSb = g:GetConnectionSetbacks(edgeIds[k], edgeIds[k + 1])
			to = edgeLen(e) - fromSb
		end
		to = math.max(to, from + (if k == #edges then 0.1 else 0)) -- a path is never zero length
		add((onEdge(e, from)))
		local edgeD = cum[#cum]
		for i = 2, #e.points - 1 do
			local d = e._cum[i]
			if d > from + 0.05 and d < to - 0.05 then add(e.points[i]) end
		end
		add((onEdge(e, to)))
		if k > 1 then blocks[k - 1].endD = startD end
		blocks[k] = { edgeId = e.id, startD = startD, edgeD = edgeD, endD = 0, track = trackKey(e), junction = junction }
	end
	local length = cum[#cum] or 0
	blocks[#blocks].endD = length
	if #pts < 2 then return nil end
	return { pts = pts, cum = cum, blocks = blocks, length = length }
end

-- Plan from `start` to the lane point beside `goalPos`, running `ahead` studs past it (so a
-- train stops centred on a platform).
local function planFrom(g: any, start: Start, goalPos: Vector3, ahead: number): Plan?
	-- Further along the lane the train is on: no search (and no lap of a loop line because
	-- the goal sits a hair behind a vertex-snapped start).
	local e = g:GetEdge(start.edgeId)
	if e then
		local at = nearestAt(e, goalPos)
		if at >= start.at - 0.5 and flatDist((onEdge(e, at)), goalPos) < 8 then
			return buildPlan(g, { e.id }, start.at, math.min(math.max(at, start.at) + ahead, edgeLen(e)))
		end
	end
	local ok, _, edgeIds = pcall(function()
		return g:FindPath(start.pos, goalPos, true, VehicleTypes.Train, nil, { edgeId = start.edgeId, dist = start.at })
	end)
	if not ok or typeof(edgeIds) ~= "table" or #edgeIds == 0 then return nil end
	local last = g:GetEdge(edgeIds[#edgeIds])
	if not last then return nil end
	local goalAt = math.min(nearestAt(last, goalPos) + ahead, edgeLen(last))
	if #edgeIds == 1 and goalAt < start.at then return nil end
	return buildPlan(g, edgeIds, start.at, goalAt)
end

local function bestPlan(g: any, starts: { Start }, goalPos: Vector3, ahead: number): (Plan?, Start?)
	local best: Plan?, bestStart: Start?, bestCost = nil, nil, math.huge
	for _, s in starts do
		local plan = planFrom(g, s, goalPos, ahead)
		if plan and plan.length + s.cost < bestCost then
			best, bestStart, bestCost = plan, s, plan.length + s.cost
		end
	end
	return best, bestStart
end

-- == Trail =====================================================================
local function sampleTrail(t: Train, d: number): (Vector3, Vector3)
	local pts, cum = t.pts, t.cum
	local n = #pts
	if n == 0 then return Vector3.zero, Vector3.zAxis end
	if n == 1 then return pts[1], Vector3.zAxis end
	d = math.clamp(d, cum[1], cum[n])
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] <= d then lo = mid else hi = mid end
	end
	local span = cum[hi] - cum[lo]
	local f = if span > 1e-6 then (d - cum[lo]) / span else 0
	local dir = pts[hi] - pts[lo]
	return pts[lo]:Lerp(pts[hi], f), if dir.Magnitude > 1e-6 then dir.Unit else Vector3.zAxis
end

-- Where the train can start its next path: ahead from the front, or (reversing) back from
-- the rear on the lane running the other way.
local function trainStarts(g: any, t: Train): { Start }
	local out: { Start } = {}
	local headPos, headDir = sampleTrail(t, t.headD)
	local s = laneStart(g, headPos, headDir, 0, false)
	if s then table.insert(out, s) end
	local tailPos, tailDir = sampleTrail(t, t.headD - consistLen(t.spec))
	local r = laneStart(g, tailPos, -tailDir, REVERSE_COST, true)
	if r then table.insert(out, r) end
	return out
end

-- Append a plan at the trail's end; block distances shift onto the trail.
local function appendPlan(t: Train, plan: Plan)
	local keepFrom = t.headD - consistLen(t.spec) - 20
	while #t.pts > 2 and t.cum[2] < keepFrom do
		table.remove(t.pts, 1); table.remove(t.cum, 1)
	end
	local n = #t.pts
	local base = t.cum[n] + (plan.pts[1] - t.pts[n]).Magnitude
	for i, p in plan.pts do
		local d = base + plan.cum[i]
		if d > t.cum[#t.cum] + 0.05 then
			table.insert(t.pts, p); table.insert(t.cum, d)
		end
	end
	for _, b in plan.blocks do
		table.insert(t.blocks, {
			edgeId = b.edgeId, startD = b.startD + base, edgeD = b.edgeD + base, endD = b.endD + base,
			track = b.track, junction = b.junction,
		})
	end
	t.endD = base + plan.length
end

-- Turn the train round where it stands: the trail becomes its own footprint run backwards,
-- the rear cab leads, and every key it held rides a footprint block until the train is clear.
local function reverseInPlace(t: Train)
	local tailD = t.headD - consistLen(t.spec)
	local foot: { Vector3 } = { (sampleTrail(t, t.headD)) }
	for i = #t.pts, 1, -1 do
		local d = t.cum[i]
		if d < t.headD - 0.05 and d > tailD + 0.05 then table.insert(foot, t.pts[i]) end
	end
	table.insert(foot, (sampleTrail(t, tailD)))
	local cum: { number } = { 0 }
	for i = 2, #foot do cum[i] = cum[i - 1] + (foot[i] - foot[i - 1]).Magnitude end
	local extra: { string } = {}
	for key in t.held do table.insert(extra, key) end
	t.pts, t.cum = foot, cum
	t.headD = cum[#cum]
	t.blocks = { { edgeId = "", startD = 0, edgeD = 0, endD = t.headD, extra = extra } }
	t.booked = 1
	local n = #t.cars
	for i = 1, n // 2 do t.cars[i], t.cars[n - i + 1] = t.cars[n - i + 1], t.cars[i] end
end

-- == Signalling ================================================================
local function keyFree(t: Train, key: string?): boolean
	if not key then return true end
	local h = _holder[key]
	return h == nil or h == t
end

local function hold(t: Train, key: string?)
	if not key then return end
	_holder[key] = t
	t.held[key] = true
end

-- Book the next block -- a run of single track whole, plus the block after it so the train
-- never waits ON single track. All or nothing.
local function tryBook(t: Train): boolean
	local i, n = t.booked + 1, #t.blocks
	if i > n then return false end
	local j = i
	while j < n and isSingle(t.blocks[j]) do j += 1 end
	for k = i, j do
		local b = t.blocks[k]
		if not (keyFree(t, b.track) and keyFree(t, b.junction)) then return false end
	end
	for k = i, j do
		hold(t, t.blocks[k].track)
		hold(t, t.blocks[k].junction)
	end
	t.booked = j
	return true
end

-- Free what the train has left behind: a lane once its tail is past the lane's end, a
-- junction once its tail is past the junction.
local function releaseBehind(t: Train)
	local tail = t.headD - consistLen(t.spec)
	while t.booked > 0 and t.blocks[1].endD <= tail do
		table.remove(t.blocks, 1)
		t.booked -= 1
	end
	local need: { [string]: boolean } = {}
	for k = 1, t.booked do
		local b = t.blocks[k]
		if b.track then need[b.track] = true end
		if b.junction and tail < b.edgeD then need[b.junction] = true end
		if b.extra then for _, key in b.extra do need[key] = true end end
	end
	for key in t.held do
		if not need[key] then
			t.held[key] = nil
			if _holder[key] == t then _holder[key] = nil end
		end
	end
end

local function releaseAll(t: Train)
	for key in t.held do
		if _holder[key] == t then _holder[key] = nil end
	end
	table.clear(t.held)
	table.clear(t.blocks)
	t.booked = 0
end

-- How far the train may go: its path end, or just short of the first block it does not hold.
local function limitD(t: Train): number
	local nb = t.blocks[t.booked + 1]
	if nb then return math.min(t.endD, nb.startD - STOP_MARGIN) end
	return t.endD
end

-- == Cars ======================================================================
local function placeCars(t: Train)
	local cl, gap = carLen(t.spec), carGap(t.spec)
	local n = #t.cars
	for k, car in t.cars do
		local center = t.headD - (k - 1) * (cl + gap) - cl * 0.5
		if (t.hideBefore and center < t.hideBefore) or (t.hideAfter and center > t.hideAfter) or t.phase == "inside" then
			if car.Parent then car.Parent = nil end
			continue
		end
		if car.Parent ~= _folder then car.Parent = _folder end
		local half = cl * 0.45
		local pF = sampleTrail(t, center + half)
		local pB = sampleTrail(t, center - half)
		local mid = (pF + pB) * 0.5 + Vector3.new(0, TRAIN_LIFT, 0)
		local dir = pF - pB
		if dir.Magnitude < 1e-4 then
			local _, d2 = sampleTrail(t, center)
			dir = d2
		end
		-- Cars are authored nose-on-+Z; lookAt aims -Z, so aim it backwards. The rear car is
		-- the same cab turned round.
		local cf = CFrame.lookAt(mid, mid - dir.Unit)
		if k == n and n > 1 then cf *= CFrame.Angles(0, math.pi, 0) end
		car:PivotTo(cf)
	end
end

-- == Buildings =================================================================
type Base = { id: number, key: string, pos: Vector3 }

local function railBases(key: string): { Base }
	local out: { Base } = {}
	for _, d in _transit.getDepots() do
		if d.key == key then table.insert(out, { id = d.id, key = d.key, pos = d.entrance }) end
	end
	return out
end

local function trainAllowance(): number
	local n = 0
	for _, d in _transit.getDepots() do
		local spec = TransitTypes.getDepot(d.key)
		n += if spec and spec.trainCapacity then spec.trainCapacity else 0
	end
	return n
end

-- == Fleet =====================================================================
local function destroyTrain(t: Train)
	if t.dead then return end
	t.dead = true
	local pos = sampleTrail(t, t.headD)
	_transit.vehicleOutOfService(t.key, pos)
	releaseAll(t)
	local idx = table.find(_trains, t)
	if idx then table.remove(_trains, idx) end
	for _, car in t.cars do car:Destroy() end
end

local function lineRunnable(route: any): boolean
	return route ~= nil and route.mode == "train" and route.enabled and route.closed == true and #route.stops >= 2
end

-- The biggest train whose cars fit every platform on the line.
local function lineTrainSpec(route: any): TransitTypes.TrainSpec
	local cars = math.huge
	for _, sid in route.stops do
		local stop = _transit.getStop(sid)
		local spec = stop and TransitTypes.getStop(stop.key)
		cars = math.min(cars, if spec and spec.platformCars then spec.platformCars else 3)
	end
	return TransitTypes.trainForPlatform(if cars == math.huge then 3 else cars)
end

local function stationPos(route: any, index: number): Vector3?
	local sid = route.stops[index]
	local stop = sid and _transit.getStop(sid)
	return stop and stop.roadPos
end

-- Start the train on a fresh path out of a building (depot or yard). False while the track
-- by the door is held by another train; it stays inside and tries again.
local function tryEmerge(t: Train, from: Vector3): boolean
	local g = railGraph()
	local route = _transit.getRoute(t.routeId)
	local goal = route and stationPos(route, t.stopIndex)
	if not g or not goal then return false end
	local plan = bestPlan(g, portalStarts(g, from), goal, consistLen(t.spec) * 0.5)
	if not plan then t.issue = "track"; return false end
	t.pts, t.cum = table.clone(plan.pts), table.clone(plan.cum)
	t.blocks = table.clone(plan.blocks)
	t.booked = 0
	t.headD = 0
	t.endD = plan.length
	if not tryBook(t) then
		table.clear(t.blocks)
		return false
	end
	t.hideBefore, t.hideAfter = 0, nil
	t.task, t.phase, t.speed, t.waited, t.issue, t.leftAt = "line", "driving", 0, 0, nil, 0
	return true
end

-- Drive from where the train stands to `goal`, choosing between pulling ahead and
-- reversing. `enter` = the path ends at a building door the train disappears into.
local function driveTo(t: Train, goal: Vector3, ahead: number, enter: boolean): boolean
	local g = railGraph()
	if not g then return false end
	local plan, start = bestPlan(g, trainStarts(g, t), goal, ahead)
	if not plan or not start then return false end
	if start.reverse then reverseInPlace(t) end
	appendPlan(t, plan)
	t.hideBefore = nil
	t.hideAfter = if enter then t.endD else nil
	if enter then t.endD += consistLen(t.spec) end
	t.phase, t.speed, t.waited, t.leftAt = "driving", 0, 0, t.headD
	return true
end

-- The nearest building of `key` the train can drive into, or nil.
local function driveToBase(t: Train, bases: { Base }, task: string): boolean
	table.sort(bases, function(a, b)
		local p = sampleTrail(t, t.headD)
		return flatDist(a.pos, p) < flatDist(b.pos, p)
	end)
	for _, base in bases do
		if driveTo(t, base.pos, 0, true) then
			t.task, t.baseId = task, base.id
			return true
		end
	end
	return false
end

local function yardBaysFree(yard: Base): boolean
	local spec = TransitTypes.getDepot(yard.key)
	local used = 0
	for _, o in _trains do
		if o.task == "yard" and o.baseId == yard.id then used += 1 end
	end
	return used < (if spec and spec.serviceBays then spec.serviceBays else 1)
end

local function freeYards(): { Base }
	local free: { Base } = {}
	for _, y in railBases("TrainYard") do
		if yardBaysFree(y) then table.insert(free, y) end
	end
	return free
end

-- Does the train leave the line at the platform it stands at (back to a depot, or worn and
-- a yard bay is free)? Then nobody boards there.
local function leavesService(t: Train, route: any): boolean
	if t.retire or not lineRunnable(route) then return true end
	return t.wear >= TransitTypes.TRAIN_WEAR_DUE and #freeYards() > 0
end

local function depart(t: Train)
	local route = _transit.getRoute(t.routeId)
	local here = sampleTrail(t, t.headD)
	if t.retire or not lineRunnable(route) then
		if driveToBase(t, railBases("TrainDepot"), "depot") then
			_transit.vehicleOutOfService(t.key, here)
		else
			destroyTrain(t)
		end
		return
	end
	local n = #route.stops
	t.stopIndex = math.min(t.stopIndex, n)
	local nextIndex = (t.stopIndex % n) + 1
	if t.wear >= TransitTypes.TRAIN_WEAR_DUE then
		local free = freeYards()
		if #free > 0 and driveToBase(t, free, "yard") then
			-- Passengers finish on foot from here; the check-up takes the train off the line
			-- and it comes back to the next station.
			_transit.vehicleOutOfService(t.key, here)
			t.stopIndex, t.issue = nextIndex, nil
			return
		end
		if #free == 0 and #railBases("TrainYard") > 0 then
			t.issue = nil -- every bay is busy: carry on, try again at the next station
		else
			t.issue = "worn"
		end
	end
	local goal = stationPos(route, nextIndex)
	if goal and driveTo(t, goal, consistLen(t.spec) * 0.5, false) then
		t.stopIndex, t.task = nextIndex, "line"
		if t.issue == "track" then t.issue = nil end
	else
		t.issue = "track"
		t.timer = TransitTypes.TRAIN_STOP_DWELL -- hold at the platform and try again
	end
end

local function arrive(t: Train)
	t.speed = 0
	if t.task == "depot" then destroyTrain(t); return end
	if t.task == "yard" then
		releaseAll(t)
		t.phase, t.timer = "inside", TransitTypes.TRAIN_SERVICE_SECONDS
		t.wear = 0
		placeCars(t)
		return
	end
	local route = _transit.getRoute(t.routeId)
	local sid = route and route.stops[t.stopIndex]
	local seats = if leavesService(t, route) then 0 else t.spec.capacity
	local moved = if sid then _transit.vehicleAtStop(t.key, route.id, sid, seats) else 0
	t.phase = "dwelling"
	t.timer = TransitTypes.TRAIN_STOP_DWELL + moved * TransitTypes.BOARD_SECONDS
end

local function wearFactor(t: Train): number
	local due, max = TransitTypes.TRAIN_WEAR_DUE, TransitTypes.TRAIN_WEAR_MAX
	if t.wear <= due then return 1 end
	return 1 - math.clamp((t.wear - due) / (max - due), 0, 1) * (1 - TransitTypes.TRAIN_WORN_SPEED)
end

local function drive(t: Train, sdt: number)
	local lim = limitD(t)
	if t.booked < #t.blocks and lim - t.headD < t.speed * t.speed / (2 * ACCEL) + BOOK_AHEAD then
		if tryBook(t) then lim = limitD(t) end
	end
	local remaining = math.max(0, lim - t.headD)
	local top = t.spec.speedKmh * STUDS_PER_KMH * wearFactor(t)
	t.speed = math.min(t.speed + ACCEL * sdt, top, math.sqrt(2 * ACCEL * remaining))
	local move = math.min(t.speed * sdt, remaining)
	t.headD += move
	t.wear += move
	t.waited = if lim < t.endD - 0.5 and move < 0.01 then t.waited + sdt else 0
	if t.hideBefore and t.headD - consistLen(t.spec) > t.hideBefore then t.hideBefore = nil end
	if t.headD >= t.endD - 0.05 then
		t.headD = t.endD
		arrive(t)
	elseif t.retire and t.waited > STUCK_ALERT and t.headD - t.leftAt < 1 then
		-- A retiring train stuck at the platform it left, behind a deadlock, is taken out of
		-- service there: that is what the player asked for by running fewer trains.
		destroyTrain(t)
	end
end

local function stepTrain(t: Train, sdt: number)
	if t.phase == "inside" then
		t.timer -= sdt
		if t.timer > 0 then return end
		t.timer = EMERGE_RETRY
		local base = nil
		for _, d in _transit.getDepots() do if d.id == t.baseId then base = d end end
		if not base or t.retire then
			destroyTrain(t)
		elseif not tryEmerge(t, base.entrance) then
			t.waited += EMERGE_RETRY -- held inside: the track at the door is taken
		end
	elseif t.phase == "dwelling" then
		t.timer -= sdt
		if t.timer <= 0 then depart(t) end
	else
		drive(t, sdt)
	end
	if t.dead then return end
	releaseBehind(t)
	placeCars(t)
end

local function step(dt: number)
	local speed = gameSpeed()
	if speed <= 0 then return end
	local sdt = dt * speed
	for i = #_trains, 1, -1 do
		local t = _trains[i]
		-- One broken train must not stop the fleet: it is taken out of service instead.
		local ok, err = pcall(stepTrain, t, sdt)
		if not ok then
			warn("[TrainDispatchService] train on line " .. t.routeId .. " failed: " .. tostring(err))
			pcall(destroyTrain, t)
		end
	end
end

local function spawnTrain(route: any, spec: TransitTypes.TrainSpec, stopIndex: number): boolean
	local g = railGraph()
	local goal = stationPos(route, stopIndex)
	if not g or not goal then return false end
	-- The depot with the shortest track run to the line.
	local best: Base?, bestLen = nil, math.huge
	for _, d in railBases("TrainDepot") do
		local plan = bestPlan(g, portalStarts(g, d.pos), goal, 0)
		if plan and plan.length < bestLen then best, bestLen = d, plan.length end
	end
	if not best then return false end

	_seq += 1
	local cars: { Model } = {}
	for k = 1, spec.carCount do
		cars[k] = buildCar(("Train_%d_Car%d"):format(_seq, k), spec, k == 1 or k == spec.carCount)
	end
	CollectionService:AddTag(cars[1], VehicleTypes.Tag.Train)
	table.insert(_trains, {
		key = cars[1], cars = cars, spec = spec, routeId = route.id, stopIndex = stopIndex,
		task = "line", phase = "inside", timer = 0, speed = 0, headD = 0,
		pts = {}, cum = {}, blocks = {}, booked = 0, held = {}, endD = 0,
		hideBefore = nil, hideAfter = nil, baseId = best.id,
		wear = 0, waited = 0, issue = nil, retire = false, leftAt = 0, dead = false,
	})
	return true
end

-- Keep each runnable train line supplied from the depots, retire strays, and tell each line
-- what is wrong with it.
local function reconcile()
	for i = #_trains, 1, -1 do
		local t = _trains[i]
		local route = _transit.getRoute(t.routeId)
		if not lineRunnable(route) then
			t.retire = true
		elseif t.spec.key ~= lineTrainSpec(route).key then
			t.retire = true -- a platform changed: swap in the right train as this one leaves
		end
	end
	local allowance = trainAllowance()
	local ids = _transit.getRouteIds()
	table.sort(ids)
	for _, routeId in ids do
		local route = _transit.getRoute(routeId)
		if not route or route.mode ~= "train" then continue end
		local issues: { [string]: boolean } = {}
		local spec = lineTrainSpec(route)
		local desired = if lineRunnable(route) then route.busCount else 0
		local have, running = 0, 0
		for _, t in _trains do
			if t.routeId ~= routeId then continue end
			if not t.retire then have += 1 end
			if t.phase ~= "inside" then running += 1 end
			if t.issue then issues[t.issue] = true end
			if t.waited > STUCK_ALERT then issues.stuck = true end
		end
		if have < desired then
			if #_trains >= allowance then
				issues[if allowance > 0 then "depotFull" else "noDepot"] = true
			else
				local n = #route.stops
				local first = (have * math.max(1, n // math.max(1, desired))) % n + 1
				if not spawnTrain(route, spec, first) then issues.noDepot = true end
			end
		elseif have > desired then
			-- A train still in its depot goes first; otherwise the first one found.
			local pick: Train? = nil
			for _, t in _trains do
				if t.routeId == routeId and not t.retire and (not pick or t.phase == "inside") then pick = t end
			end
			if pick then pick.retire = true end
		end
		_transit.setRouteActiveBuses(routeId, running)
		local alert: string? = nil
		for _, k in ALERT_ORDER do
			if issues[k] then alert = ALERT[k]; break end
		end
		if alert and _lastAlert[routeId] ~= alert and _net then
			_net.Notify:FireAllClients({ text = route.name .. ": " .. alert, kind = "warning", duration = 6 })
		end
		_lastAlert[routeId] = alert :: any
		_transit.setRouteTrainInfo(routeId, spec.key, alert)
	end
end

-- == Public ====================================================================
-- Despawn the whole fleet (city unload / reload); lines refill from their depots.
function TrainDispatchService.clear()
	for i = #_trains, 1, -1 do
		destroyTrain(_trains[i])
	end
	table.clear(_trains)
	table.clear(_holder)
	table.clear(_lastAlert)
end

-- == Lifecycle =================================================================
function TrainDispatchService.Init(transitService: any, roadService: any, net: any)
	assert(transitService, "[TrainDispatchService] requires TransitService")
	assert(roadService, "[TrainDispatchService] requires RoadService")
	_transit = transitService
	_road = roadService
	_net = net
	_folder = ensureFolder()
end

function TrainDispatchService.Bind() end

function TrainDispatchService.Start()
	if _running then return end
	_running = true
	RunService.Heartbeat:Connect(function(dt: number)
		step(math.min(dt, 0.1))
		_reconcileAccum += dt
		if _reconcileAccum >= RECONCILE_INTERVAL then
			_reconcileAccum = 0
			local rok, rerr = pcall(reconcile)
			if not rok then warn("[TrainDispatchService] reconcile failed: " .. tostring(rerr)) end
		end
	end)
end

-- Test seam: the path/signalling pieces, for the spec.
TrainDispatchService._test = {
	tryBook = tryBook, releaseBehind = releaseBehind, holder = _holder, trains = _trains,
	-- A path from `pos` heading `dir` to the lane beside `goal`.
	plan = function(g: any, pos: Vector3, dir: Vector3, goal: Vector3): Plan?
		local s = laneStart(g, pos, dir, 0, false)
		return if s then planFrom(g, s, goal, 0) else nil
	end,
}

return TrainDispatchService
