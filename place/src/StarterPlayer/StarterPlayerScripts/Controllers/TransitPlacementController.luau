--!strict
-- TransitPlacementController
-- The Transit build tools: Depot (free placement), Bus Stop (snaps to the kerb on
-- either side, faces the road) and Route (drop stops, connect them, add waypoints). While
-- the Transit section is open every road tints BLUE -- the route-mode affordance. Depot
-- placement reuses RequestPlaceService(kind="Transit"); stops + routes go through
-- RequestTransitCommand. Reads the live snapshot from TransitClient.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local SnapUtil = require(ReplicatedStorage.Road.SnapUtil)
local Snapper = require(script.Parent:WaitForChild("RoadPlacementSnapper"))
local PlacementCostHud = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("PlacementCostHud"))
local TransitClient = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("TransitClient"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local TransitPlacementController = {}

-- Valid/invalid ghost tinting lives in GhostPlacement now; the Stop ghost is tinted with
-- its own accent colour, not green/red.
local STOP_MAX_ROAD_DIST = 40

local _enabled = false
local _inited = false
local _bound = false
local _tool = "DepotMedium" -- a DEPOT_TOOLS or STOP_TOOLS key, or "Route"
-- Tool -> the TransitTypes key it places. Depot tools are free placement (a rail building
-- snaps beside the track like any building snaps to a road) -- the bus hub and station too,
-- which are stops you place like a building; stop tools snap to a lane.
local DEPOT_TOOLS: { [string]: string } = {
	DepotSmall = "BusDepotSmall", DepotMedium = "BusDepotMedium", DepotLarge = "BusDepotLarge",
	Depot = "BusDepotMedium", BusHub = "BusHub", BusStation = "BusStation",
	TrainDepot = "TrainDepot", TrainYard = "TrainYard",
}
local STOP_TOOLS: { [string]: string } = {
	StopPole = "BusStopPole", StopShelter = "BusStopShelter", Stop = "BusStopShelter", Station = "TrainStationMedium",
	StationSmall = "TrainStationSmall", StationMedium = "TrainStationMedium", StationLarge = "TrainStationLarge",
}
local _ghost: Model? = nil
local _ghostFolder: Folder? = nil
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _unsub: (() -> ())? = nil
-- stop tool: { pos = cursor hit, road = centreline point, seg = segmentId }
local _stopSend: any = nil
-- route tool
local _pendingFirstStop: number? = nil
local _maxKnownRouteId = 0
-- Route tool: pressing on a line or one of its road points grabs it; dragging it onto a stop adds
-- that stop to the line there, onto a road adds (or moves) a point the buses go through.
local GRAB_PX = 14      -- how near (pixels) the cursor must be to a line / point to grab it
local DRAG_START_PX = 6 -- movement that turns a press into a drag
type Grab = { routeId: number, leg: number, point: number?, chain: { Vector3 }, color: Color3,
	from: Vector2, dragging: boolean }
local _grab: Grab? = nil
local _inputEndConn: RBXScriptConnection? = nil

-- Cursor picking lives in Core.CursorRay; the Depot tool's whole ghost/fit/cost/place loop
-- is Controllers.GhostPlacement (see _depotPlacer below). Only the Stop and Route tools,
-- which snap to road geometry rather than free ground, are hand-written here.

local function ensureGhostFolder(): Folder
	local folder = UiScratch.folder("TransitPlacement")
	_ghostFolder = folder
	return folder
end

local function destroyGhost()
	if _ghost then _ghost:Destroy(); _ghost = nil end
end

local function tintGhost(color: Color3)
	if not _ghost then return end
	for _, d in _ghost:GetDescendants() do
		if d:IsA("BasePart") then d.Color = color end
	end
end

-- The kit's placement ghosts (Authoring.TransitSetup.ghosts): the building's real mass, the plot
-- and its IN / OUT gate arrows; a stop ghost is the stop itself.
local function kitGhost(template: string?): Model?
	local folder = ReplicatedStorage:FindFirstChild("Transit")
	local ghosts = folder and folder:FindFirstChild("Ghosts")
	local g = template and ghosts and ghosts:FindFirstChild(template)
	return if g and g:IsA("Model") then g:Clone() else nil
end

-- The kit's street side is +Z, and SnapUtil turns a building's -Z to the road -- so the kit snaps
-- here: hover by the road and the site's street edge lines up with the footway (like a zoned lot),
-- else it snaps centred on the cursor like any building. Snapped, it faces the road on its own and
-- stands at the road's height, on the footway plane (the server seats it the same way). Off-road it
-- goes where it is put: a site never needs a road (user).
local SEAT_REACH = 60 -- a road this close in front of the street edge sets the site's height
local function kitSnap(key: string, pos: Vector3): CFrame?
	local spec = TransitTypes.getFreePlaced(key)
	if not (spec and spec.template and spec.footprint) then return nil end
	local half = spec.footprint.Z * 0.5
	local p, yaw = SnapUtil.snapBuilding(pos, 1) -- the cursor on the frontage
	local centre: Vector3
	if p and yaw then
		centre = p + CFrame.Angles(0, yaw, 0).ZVector * (half - 1)
	else
		p, yaw = SnapUtil.snapBuilding(pos, half)
		if not (p and yaw) then return nil end
		centre = p
	end
	local away = CFrame.Angles(0, yaw, 0).ZVector -- road -> site
	local front = centre - away * (half + TransitTypes.GATE_REACH)
	local y = centre.Y
	local road = Snapper.nearestRoadPoint(front)
	if road and Vector3.new(road.X - front.X, 0, road.Z - front.Z).Magnitude <= SEAT_REACH then
		local segId = Snapper.nearestSegmentId(front)
		local info = if segId then Snapper.getSegmentInfo(segId) else nil
		local spec2 = if info and typeof(info.roadType) == "string" then RoadTypeCatalog.getOrDefault(info.roadType) else nil
		local walk = not (spec2 and (spec2.noSidewalk or spec2.sidewalkMode == "none"))
		y = road.Y + RoadConstants.ROAD_THICKNESS * 0.5 + (if walk then RoadConstants.SIDEWALK_HEIGHT else 0)
	end
	return CFrame.new(centre.X, y, centre.Z) * CFrame.Angles(0, yaw + math.pi, 0)
end

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3): Part
	local p = Instance.new("Part")
	p.Size = size; p.CFrame = cf; p.Color = color; p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.Transparency = 0.35
	p.Parent = parent
	return p
end

-- The Depot tool IS the shared free-placement tool: one model, on the ground, where the
-- cursor is. It supplies a spec and nothing else.
local _depotPlacer = GhostPlacement.new({
	folderName = "TransitPlacement",
	build = function(key: string): Model?
		local kit = TransitTypes.getFreePlaced(key)
		local ghost = kitGhost(kit and kit.template)
		if ghost then return ghost end
		if kit and kit.template and kit.footprint then
			-- fallback (no ghost baked yet): the lot, world size, with its street side marked in blue
			local fp = kit.footprint :: Vector3
			local m = Instance.new("Model"); m.Name = "GhostDepot"
			local base = part(m, Vector3.new(fp.X, 0.6, fp.Z), CFrame.new(0, 0.3, 0), Color3.fromRGB(200, 204, 210))
			part(m, Vector3.new(fp.X * 0.5, fp.Y * 0.5, fp.Z * 0.4), CFrame.new(0, fp.Y * 0.25, -fp.Z * 0.2), Color3.fromRGB(222, 222, 216))
			part(m, Vector3.new(fp.X, 0.8, 2), CFrame.new(0, 0.4, fp.Z * 0.5 - 1), kit.accent)
			m.PrimaryPart = base
			return m
		end
		local spec = TransitTypes.getDepot(key)
		if not spec then return nil end
		local fp = TransitTypes.depotFootprintStuds(spec)
		local m = Instance.new("Model"); m.Name = "GhostDepot"
		local base = part(m, Vector3.new(fp.X, spec.height, fp.Z), CFrame.new(0, spec.height * 0.5, 0), spec.wall)
		part(m, Vector3.new(fp.X + 1, 1, fp.Z + 1), CFrame.new(0, spec.height + 0.5, 0), spec.roof)
		m.PrimaryPart = base
		if RoadConstants.WORLD_SCALE ~= 1 then m:ScaleTo(RoadConstants.WORLD_SCALE) end
		return m
	end,
	footprint = function(key: string): Vector3?
		local kit = TransitTypes.getFreePlaced(key)
		if kit and kit.template and kit.footprint then return kit.footprint end
		local spec = TransitTypes.getDepot(key)
		if not spec then return nil end
		local fp = TransitTypes.depotGroundFootprint(spec)
		-- Y is the overlap box's height, which for a depot is the wall height, not fp.Y.
		return Vector3.new(fp.X, spec.height, fp.Z)
	end,
	cost = function(key: string): number?
		local spec = TransitTypes.getFreePlaced(key)
		return if spec then spec.cost else nil
	end,
	place = function(key: string, pivot: CFrame)
		Net.RequestPlaceService:FireServer("Transit", key, pivot)
	end,
	snap = kitSnap,
	clearsNature = true, -- a site goes up on top of trees; the server clears them
})
_depotPlacer:setKey("BusDepotMedium")

-- Bus stops snap to a road, stations to a track.
local function stopKeyForTool(): string
	return STOP_TOOLS[_tool] or "BusStopShelter"
end

local function buildStopGhost(): Model
	local spec = TransitTypes.getStop(stopKeyForTool()) :: TransitTypes.StopSpec
	local m = Instance.new("Model"); m.Name = "GhostStop"
	local real = kitGhost(spec.template)
	if real then
		real.Parent = ensureGhostFolder()
		return real
	end
	if spec.template then
		-- kit stop: world size, pivot on the ground, the sign (road side) on +Z
		local sh = spec.shelterSize
		local body = part(m, sh, CFrame.new(0, sh.Y * 0.5, 0), spec.accent)
		body.PivotOffset = CFrame.new(0, -sh.Y * 0.5, 0) -- the PrimaryPart owns the pivot: put it on the ground
		m.PrimaryPart = body
		m.Parent = ensureGhostFolder()
		return m
	end
	local pole = part(m, Vector3.new(0.5, spec.poleHeight, 0.5), CFrame.new(0, spec.poleHeight * 0.5, 0), Color3.fromRGB(60, 64, 70))
	part(m, Vector3.new(2.6, 1.4, 0.2), CFrame.new(0, spec.poleHeight - 0.6, 0.15), spec.accent)
	local sh = spec.shelterSize
	part(m, Vector3.new(sh.X, 0.3, sh.Z), CFrame.new(0, sh.Y, -sh.Z * 0.5 - 0.4), Color3.fromRGB(120, 170, 190))
	m.PrimaryPart = pole
	if RoadConstants.WORLD_SCALE ~= 1 then m:ScaleTo(RoadConstants.WORLD_SCALE) end
	m.Parent = ensureGhostFolder()
	return m
end

-- == Cursor raycast ===========================================================
-- The ghost folder lives under _UI, which CursorRay already excludes for every tool.
local function mouseRay(): (Vector3?, Instance?)
	local hit = CursorRay.groundHit({ ignoreWater = true })
	if hit then return hit.Position, hit.Instance end
	return nil, nil
end

local function stopIdFromInstance(inst: Instance?): number?
	local node = inst
	while node and node ~= Workspace do
		if node:GetAttribute("StopId") ~= nil then return node:GetAttribute("StopId") :: number end
		node = node.Parent
	end
	return nil
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function stopIdAt(hit: Vector3?, inst: Instance?): number?
	local direct = stopIdFromInstance(inst)
	if direct then return direct end
	-- Already a screen-pixel radius, so it needs the cursor in viewport space.
	local screenStop = TransitClient.stopIdAtScreen(CursorRay.position(), 76)
	if screenStop then return screenStop end
	if hit then
		return TransitClient.nearestStopId(hit, 18)
	end
	return nil
end

local function roadPointAt(hit: Vector3?): Vector3?
	if not hit then return nil end
	local roadPoint = Snapper.nearestRoadPoint(hit)
	if roadPoint and flatDist(roadPoint, hit) <= STOP_MAX_ROAD_DIST then
		return roadPoint
	end
	return nil
end

local function stopName(stopId: number?): string
	if not stopId then return "Stop" end
	for _, stop in TransitClient.getSnapshot().stops do
		if stop.id == stopId then return tostring(stop.name or "Stop") end
	end
	return "Stop"
end

local function routeStopCount(route: any): number
	return if route and typeof(route.stops) == "table" then #route.stops else 0
end

local function updateRouteStatus(hoverStopId: number?)
	local route = TransitClient.getActiveRouteData()
	if not route then
		TransitClient.setRouteStatus("Create Route", "Click a stop or station marker to choose the first stop.")
		return
	end
	local count = routeStopCount(route)
	local firstStopId = route.stops and route.stops[1]
	if route.closed then
		TransitClient.setRouteStatus("Route closed", "Press Esc to finish, or press U to reopen the last loop.", "attention")
	elseif count <= 1 then
		TransitClient.setRouteStatus("Creating route", "Start: " .. stopName(firstStopId) .. ". Click another stop to extend it.")
	elseif hoverStopId and hoverStopId == firstStopId then
		TransitClient.setRouteStatus("Close route", "Click the first stop again to complete the loop.", "attention")
	else
		TransitClient.setRouteStatus("Creating route", tostring(count) .. " stops selected. Click more stops, or click the first stop to close.")
	end
end

-- == Route line drag ==========================================================
local function screenOf(p: Vector3?): Vector2?
	local cam = Workspace.CurrentCamera
	if not cam or typeof(p) ~= "Vector3" then return nil end
	local v = cam:WorldToViewportPoint(p)
	if v.Z <= 0 then return nil end
	return Vector2.new(v.X, v.Y)
end

local function distToSeg(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = if len2 < 1e-6 then 0 else math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (a + ab * t - p).Magnitude
end

local function stopPos(id: number?): Vector3?
	for _, s in TransitClient.getSnapshot().stops do
		if s.id == id then return s.pos end
	end
	return nil
end

-- A leg as the player sees it: its first stop, its road points in order, its last stop. Leg 0 is
-- the tail of a line still being drawn (last stop -> the points clicked since).
local function legChain(route: any, leg: number): { Vector3 }
	local n = #route.stops
	local chain: { Vector3 } = {}
	local a = stopPos(if leg == 0 then route.stops[n] else route.stops[leg])
	if a then table.insert(chain, a) end
	local pts = {}
	for _, pt in route.points or {} do
		if pt.leg == leg then pts[pt.index] = pt.pos end
	end
	for i = 1, #pts do table.insert(chain, pts[i]) end
	if leg ~= 0 then
		local b = stopPos(route.stops[if leg == n then 1 else leg + 1])
		if b then table.insert(chain, b) end
	end
	return chain
end

-- The line (or road point) under the cursor. With a line selected only that one is grabbable, so
-- lines sharing a road never steal each other's drags.
local function grabAt(screen: Vector2): Grab?
	local active = TransitClient.getActiveRoute()
	local best: Grab? = nil
	local bestD = GRAB_PX
	for _, route in TransitClient.getSnapshot().routes do
		if active and route.id ~= active then continue end
		for _, pt in route.points or {} do
			local s = screenOf(pt.pos)
			if s and (s - screen).Magnitude < bestD then
				bestD = (s - screen).Magnitude
				best = { routeId = route.id, leg = pt.leg, point = pt.index, chain = {}, color = route.color, from = screen, dragging = false }
			end
		end
	end
	if best then return best end
	for _, route in TransitClient.getSnapshot().routes do
		if active and route.id ~= active then continue end
		local path, starts = route.path, route.legStarts
		-- a line with one stop has no path yet
		if typeof(path) ~= "table" or typeof(starts) ~= "table" or #path < 2 then continue end
		local prev = screenOf(path[1])
		for i = 2, #path do
			local s = screenOf(path[i])
			if s and prev then
				local d = distToSeg(screen, prev, s)
				if d < bestD then
					local leg = 0
					if not (route.tailStart and i > route.tailStart) then
						for k, first in starts do if first < i then leg = k end end
					end
					bestD = d
					best = { routeId = route.id, leg = leg, point = nil, chain = {}, color = route.color, from = screen, dragging = false }
				end
			end
			prev = s
		end
	end
	return best
end

local function routeById(id: number): any?
	for _, r in TransitClient.getSnapshot().routes do
		if r.id == id then return r end
	end
	return nil
end

-- Where the drag is aimed: a stop under the cursor, else the road under it (nil = nowhere valid).
local function dragTarget(): (number?, Vector3?)
	local hit, inst = mouseRay()
	local stopId = stopIdAt(hit, inst)
	if stopId then return stopId, stopPos(stopId) end
	return nil, roadPointAt(hit)
end

-- == Live preview along the roads =================================================
-- The server routes it (RequestRoutePreview, read-only): the line being drawn out to the cursor, or
-- the leg a drag is reshaping. Asked at most every PREVIEW_EVERY while the target moves; only the
-- latest answer is drawn.
local PREVIEW_EVERY = 0.12
local PREVIEW_STEP = 2 -- studs the target moves before a new question
local _pv = { seq = 0, lastAt = 0, key = "" }

local function askPreview(routeId: number, target: Vector3, leg: number?, point: number?, color: Color3?)
	local key = string.format("%d|%s|%s|%d,%d", routeId, tostring(leg), tostring(point),
		math.floor(target.X / PREVIEW_STEP), math.floor(target.Z / PREVIEW_STEP))
	if key == _pv.key then return end
	local now = os.clock()
	if now - _pv.lastAt < PREVIEW_EVERY then return end
	_pv.key, _pv.lastAt = key, now
	_pv.seq += 1
	local seq = _pv.seq
	task.spawn(function()
		local ok, path = pcall(function()
			return Net.RequestRoutePreview:InvokeServer(routeId, target, leg, point)
		end)
		if seq ~= _pv.seq then return end -- a newer question went out, or the preview was put away
		if ok and typeof(path) == "table" and #path >= 2 then TransitClient.setDragPreview(path, color) end
	end)
end

local function stopPreview()
	_pv.seq += 1
	_pv.key = ""
	TransitClient.setDragPreview(nil)
end

-- A drag: the leg reshaped through the cursor (or its point moved there), along the roads.
local function updateDrag(g: Grab)
	local stopId, at = dragTarget()
	if not at then
		local hit = mouseRay()
		at = hit
	end
	if not at then stopPreview(); return end
	askPreview(g.routeId, at :: Vector3, g.leg, g.point, g.color)
	if stopId then
		TransitClient.setRouteHint(stopId, nil, nil, "Add Stop Here", nil)
	elseif roadPointAt(mouseRay()) then
		TransitClient.setRouteHint(nil, at, "", if g.point then "Move Waypoint Here" else "Insert Waypoint Here", nil)
	else
		TransitClient.setRouteHint(nil, nil, nil, nil, nil)
	end
end

local function endDrag()
	_grab = nil
	stopPreview()
end

-- Release: onto a stop inserts it into the leg (a line still being drawn simply goes on to it);
-- onto a road adds / moves a point.
local function dropGrab(g: Grab)
	local stopId, at = dragTarget()
	if stopId then
		if g.leg == 0 then
			Net.RequestTransitCommand:FireServer("addStop", { routeId = g.routeId, stopId = stopId })
		else
			Net.RequestTransitCommand:FireServer("insertStop", { routeId = g.routeId, leg = g.leg, stopId = stopId })
			TransitClient.setRouteStatus("Stop added", "Added " .. stopName(stopId) .. " to the line.")
		end
	elseif at then
		if g.point then
			Net.RequestTransitCommand:FireServer("moveWaypoint", { routeId = g.routeId, leg = g.leg, index = g.point, pos = at })
		else
			Net.RequestTransitCommand:FireServer("addLegPoint", { routeId = g.routeId, leg = g.leg, pos = at })
		end
	end
end

-- == Stop recompute (curbside preview) ========================================
local function recomputeStop()
	_stopSend = nil
	if not _ghost then _ghost = buildStopGhost() end
	local ghost = _ghost
	local hit = mouseRay()
	if not hit then if ghost then ghost.Parent = nil end return end
	local center = Snapper.nearestRoadPoint(hit)
	local segId = Snapper.nearestSegmentId(hit)
	if not center or (Vector3.new(center.X, 0, center.Z) - Vector3.new(hit.X, 0, hit.Z)).Magnitude > STOP_MAX_ROAD_DIST then
		if ghost then ghost.Parent = nil end
		return
	end
	if not ghost.Parent then ghost.Parent = ensureGhostFolder() end
	-- The side is whichever side of the centreline the cursor is on; sit the stop just
	-- off the carriageway (on the sidewalk) facing the road.
	local stopSpec = TransitTypes.getStop(stopKeyForTool()) :: TransitTypes.StopSpec
	local wantRail = stopSpec.mode == "train"
	local roadWidth = 16
	local segInfo = if segId then Snapper.getSegmentInfo(segId) else nil
	if segInfo and typeof(segInfo.roadType) == "string" then
		local segSpec = RoadTypeCatalog.getOrDefault(segInfo.roadType)
		-- Stations snap only to track; bus stops only to roads.
		if (segSpec.isRail == true) ~= wantRail then
			if ghost then ghost.Parent = nil end
			return
		end
		roadWidth = segSpec.width
	end
	local outward = Vector3.new(hit.X - center.X, 0, hit.Z - center.Z)
	if outward.Magnitude < 0.5 then outward = Vector3.new(0, 0, 1) end
	-- Push the pivot (Pole centre) out to the sidewalk edge.
	local flatPos = center + outward.Unit * (roadWidth * 0.5 + stopSpec.curbOffset * RoadConstants.WORLD_SCALE)
	-- Y: the Pole is 12 studs tall; PivotTo places its centre, so lift by half (6 studs)
	-- so the pole base sits flush with the ground (road/sidewalk level = center.Y).
	-- a kit stop stands up on the sidewalk (the server lifts it the same way off the lane point)
	local walkUp = if segInfo and typeof(segInfo.roadType) == "string" and RoadTypeCatalog.getOrDefault(segInfo.roadType).noSidewalk
		then 0 else RoadConstants.SIDEWALK_HEIGHT
	local poleHalfH = if stopSpec.template then RoadConstants.ROAD_THICKNESS * 0.5 + walkUp
		else stopSpec.poleHeight * 0.5 * RoadConstants.WORLD_SCALE
	local ghostPos = Vector3.new(flatPos.X, center.Y + poleHalfH, flatPos.Z)
	-- The shelter's open/sign side must face the road.
	-- CFrame.lookAt(pos, target) makes +Z point at target (the road centre).
	-- The template sign is on the +Z side, BackGlass on -Z, so the un-rotated
	-- orientation already has the sign facing the road; we rotate 180 degrees around Y
	-- to flip the shelter so its open/sign side faces the road instead of away from it.
	local baseCF = CFrame.lookAt(ghostPos, Vector3.new(center.X, ghostPos.Y, center.Z))
	ghost:PivotTo(baseCF * CFrame.Angles(0, math.pi, 0))
	tintGhost(stopSpec.accent)
	_stopSend = { pos = hit, road = center, seg = segId, key = stopSpec.key }
end

local function onRender()
	if not _enabled then return end
	if DEPOT_TOOLS[_tool] then
		_depotPlacer:update()
	elseif STOP_TOOLS[_tool] then
		recomputeStop()
		PlacementCostHud.showCost(TransitTypes.getStop(stopKeyForTool()).cost)
	else -- Route
		PlacementCostHud.hide()
		local g = _grab
		if g then
			if not g.dragging and (CursorRay.position() - g.from).Magnitude >= DRAG_START_PX then
				g.dragging = true
				local route = routeById(g.routeId)
				if not route then endDrag(); return end
				g.chain = legChain(route, g.leg)
				TransitClient.setActiveRoute(g.routeId)
			end
			if g.dragging then
				updateDrag(g)
				return
			end
		end
		local hit, inst = mouseRay()
		local active = TransitClient.getActiveRoute()
		local activeRoute = TransitClient.getActiveRouteData()
		local stopId = stopIdAt(hit, inst)
		updateRouteStatus(stopId)
		-- a line being drawn: its preview runs from the last stop along the roads to the cursor
		local drawing = activeRoute ~= nil and not activeRoute.closed and routeStopCount(activeRoute) >= 1
		local roadPoint = if stopId then nil else roadPointAt(hit)
		local over = if stopId then nil else grabAt(CursorRay.position())
		if drawing and active then
			local target = if stopId then TransitClient.getStopPos(stopId) else roadPoint
			if target then askPreview(active, target, nil, nil, activeRoute.color) else stopPreview() end
		else
			stopPreview()
		end
		if stopId then
			local actionText = if not active then "Start Line"
				elseif drawing and routeStopCount(activeRoute) >= 2 and activeRoute.stops[1] == stopId then "Close Line"
				else "Add Stop"
			TransitClient.setRouteHint(stopId, nil, nil, actionText, if drawing then "Undo" else nil)
		elseif over and not (drawing and not over.point) then
			local route = routeById(over.routeId)
			if over.point then
				TransitClient.setRouteHint(nil, hit, "Waypoint", "Drag to Move", "Remove")
			else
				TransitClient.setRouteHint(nil, hit, tostring(route and route.name or "Line"), "Drag to Insert Waypoint", nil)
			end
		elseif drawing and roadPoint then
			TransitClient.setRouteHint(nil, roadPoint, "", "Add Waypoint", "Undo")
		else
			TransitClient.setRouteHint(nil, nil, nil, nil, nil)
		end
	end
end

local function clearToolState()
	destroyGhost()
	-- The Depot ghost is the placer's, not _ghost: it owns its own lifecycle, so switching
	-- away from Depot has to stand it down or it keeps riding the cursor under the next tool.
	_depotPlacer:setEnabled(false)
	_stopSend = nil
	endDrag()
	stopPreview()
	PlacementCostHud.hide()
	TransitClient.setRouteHint(nil, nil, nil, nil, nil)
	TransitClient.setRouteStatus(nil, nil, nil)
end

-- == Tool / enable ============================================================
function TransitPlacementController.setTool(tool: string)
	if not DEPOT_TOOLS[tool] and not STOP_TOOLS[tool] and tool ~= "Route" then return end
	if tool == _tool then return end
	_tool = tool
	clearToolState()
	if DEPOT_TOOLS[tool] then _depotPlacer:setKey(DEPOT_TOOLS[tool]) end
	_depotPlacer:setEnabled(_enabled and DEPOT_TOOLS[tool] ~= nil)
	if tool ~= "Route" then TransitClient.setActiveRoute(nil); TransitClient.setRouteHint(nil, nil, nil, nil, nil); _pendingFirstStop = nil end
end

function TransitPlacementController.getTool(): string
	return _tool
end

function TransitPlacementController.setEnabled(enabled: boolean)
	if enabled == _enabled then return end
	_enabled = enabled
	_depotPlacer:setEnabled(enabled and DEPOT_TOOLS[_tool] ~= nil)
	if enabled then
		TransitClient.setMode("tools", true)
	else
		clearToolState()
		TransitClient.setMode("tools", false)
		TransitClient.setActiveRoute(nil)
		_pendingFirstStop = nil
	end
end

function TransitPlacementController.isEnabled(): boolean
	return _enabled
end

-- == Route building ===========================================================
local function selectRouteStop(stopId: number)
	local active = TransitClient.getActiveRoute()
	local route = TransitClient.getActiveRouteData()
	if active then
		local firstStopId = route and route.stops and route.stops[1]
		if route and not route.closed and routeStopCount(route) >= 2 and stopId == firstStopId then
			TransitClient.setRouteStatus("Closing route", "Completing the loop back to " .. stopName(stopId) .. ".", "attention")
		elseif route and route.closed then
			TransitClient.setRouteStatus("Editing line", "Reopened to add " .. stopName(stopId) .. " -- click the first stop to close it again.", "attention")
		else
			TransitClient.setRouteStatus("Stop selected", "Added " .. stopName(stopId) .. " to the route.")
		end
		Net.RequestTransitCommand:FireServer("addStop", { routeId = active, stopId = stopId })
	else
		_pendingFirstStop = stopId
		TransitClient.setRouteStatus("Starting route", "Selected " .. stopName(stopId) .. ". Click the next stop.")
		Net.RequestTransitCommand:FireServer("createRoute", { stopId = stopId })
	end
end

local function onRouteClick()
	local hit, inst = mouseRay()
	if not hit then return end
	local stopId = stopIdAt(hit, inst)
	if stopId then
		selectRouteStop(stopId)
	else
		-- clicked the road, not a stop: shape the current leg with a waypoint
		local active = TransitClient.getActiveRoute()
		local route = TransitClient.getActiveRouteData()
		local roadPoint = roadPointAt(hit)
		if active and roadPoint and not (route and route.closed) then
			Net.RequestTransitCommand:FireServer("addWaypoint", { routeId = active, pos = roadPoint })
		end
	end
end

-- Adopt the freshly-created route as active once it arrives in the snapshot.
local function onSnapshot(snap: any)
	for _, route in snap.routes do
		if route.id > _maxKnownRouteId then _maxKnownRouteId = route.id end
	end
	if _pendingFirstStop then
		local want = _pendingFirstStop
		local found: number? = nil
		for _, route in snap.routes do
			if route.stops and route.stops[1] == want then
				if not found or route.id > found then found = route.id end
			end
		end
		if found then
			_pendingFirstStop = nil
			TransitClient.setActiveRoute(found)
		end
	end
end

-- == Lifecycle ================================================================
function TransitPlacementController.Init()
	if _inited then return end
	_inited = true
	ensureGhostFolder()
end

function TransitPlacementController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(onRender)
	_unsub = TransitClient.onChanged(onSnapshot)
	TransitClient.setStopClickHandler(function(stopId: number)
		if _enabled and _tool == "Route" then
			selectRouteStop(stopId)
		end
	end)
	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _enabled or gameProcessed then return end
		if Settings.pressed("Back", input) then
			if _tool == "Route" and TransitClient.getActiveRoute() then
				TransitClient.setActiveRoute(nil); _pendingFirstStop = nil
			else
				TransitPlacementController.setEnabled(false)
			end
			return
		end
		if DEPOT_TOOLS[_tool] and Settings.pressed("RotateObject", input) then
			_depotPlacer:rotate(45)
			return
		end
		if _tool == "Route" and (Settings.pressed("RemoveLastStop", input) or Settings.pressed("RemoveLastPoint", input)) then
			local active = TransitClient.getActiveRoute()
			if active then Net.RequestTransitCommand:FireServer("undo", { routeId = active }) end
			return
		end
		-- Right-click a stop while a line is selected removes that stop from the line; a road
		-- point, that point.
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			local over = if _tool == "Route" then grabAt(CursorRay.position()) else nil
			if over and over.point then
				Net.RequestTransitCommand:FireServer("removeWaypoint", { routeId = over.routeId, leg = over.leg, index = over.point })
				return
			end
			-- drawing a line and not on a stop: right-click undoes the last point / stop
			local drawingRoute = if _tool == "Route" then TransitClient.getActiveRouteData() else nil
			if drawingRoute and not drawingRoute.closed then
				local hitR, instR = mouseRay()
				if not stopIdAt(hitR, instR) then
					Net.RequestTransitCommand:FireServer("undo", { routeId = drawingRoute.id })
					return
				end
			end
			if _tool == "Route" then
				local active = TransitClient.getActiveRoute()
				if active then
					local hit, inst = mouseRay()
					local stopId = stopIdAt(hit, inst)
					if stopId then
						Net.RequestTransitCommand:FireServer("removeRouteStop", { routeId = active, stopId = stopId })
						TransitClient.setRouteStatus("Stop removed", "Removed " .. stopName(stopId) .. " from the line.", "attention")
					end
				end
			end
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if DEPOT_TOOLS[_tool] then
			_depotPlacer:tryPlace()
		elseif STOP_TOOLS[_tool] then
			if _stopSend then Net.RequestTransitCommand:FireServer("placeStop", _stopSend) end
		else
			-- on a line / point: decide on release (drag = reshape, still = an ordinary click)
			local hit, inst = mouseRay()
			if not stopIdAt(hit, inst) then _grab = grabAt(CursorRay.position()) end
			if not _grab then onRouteClick() end
		end
	end)
	_inputEndConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local g = _grab
		if not g then return end
		endDrag()
		TransitClient.setRouteHint(nil, nil, nil, nil, nil)
		if not _enabled or _tool ~= "Route" then return end
		if g.dragging then
			dropGrab(g)
		elseif not g.point then
			onRouteClick() -- a click on a line is still a click (a road point / the stop there)
		end
	end)
end

function TransitPlacementController.Start() end

function TransitPlacementController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	if _inputEndConn then _inputEndConn:Disconnect(); _inputEndConn = nil end
	if _unsub then _unsub(); _unsub = nil end
	TransitClient.setStopClickHandler(nil)
	_depotPlacer:destroy()
	clearToolState()
	TransitClient.setMode("tools", false)
	_enabled = false; _bound = false; _inited = false
end

return TransitPlacementController
