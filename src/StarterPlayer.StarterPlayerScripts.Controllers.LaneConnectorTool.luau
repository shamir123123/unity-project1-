--!strict
-- LaneConnectorTool -- the Traffic tab's Lane Connector card.
--
-- Every node that takes lane edits is ringed on the road: a bold double ring at a junction, a
-- thin single ring at a plain joint (where the choice is whether cars may change lanes). Click
-- one to edit it; the other rings step aside until you are done. Click an arriving lane (a red
-- dot) to pick it, or press and drag: a strand follows the cursor. Click a leaving lane (a white
-- dot) -- or let a dragged strand go on one -- to connect it. Let go on one it already reaches
-- and that connection is cut -- the strand stays on the cursor, so a click on another white dot
-- places it and a click anywhere else drops it. Click a connected white dot to remove its
-- connection; hold it to pick the strand back up and drop it on another dot (moved) or
-- anywhere else (removed). Left click only ever acts on dots; RIGHT click steps back: the
-- strand in hand is let go (nothing changes), else the picked lane, else the node -- back to the
-- rings of every node. Reset puts the node back on automatic.
--
-- Client-only and decides nothing: the lanes and their connections are the server's nav graph
-- (RoadTurnPermissionStore), and every strand is drawn along the exact curve a car drives
-- (RequestLaneCurves). An edit is drawn at once as a prediction and the lane-path patch the
-- server sends back replaces it; that same rebuild re-routes the cars and repaints the arrows
-- on the road. Only the picked node's strands are drawn, and a frame costs nothing unless the
-- cursor or the camera moved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DataCache = require(ReplicatedStorage.DataCache)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local CursorRay = require(script.Parent.Parent.Core.CursorRay)
local UiScratch = require(script.Parent.Parent.Core.UiScratch)
local Button = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Kit"):WaitForChild("Button"))

local LaneConnectorTool = {}

local CYAN = Color3.fromRGB(38, 198, 218)
local RED = Color3.fromRGB(232, 72, 60)
local RED_DIM = Color3.fromRGB(140, 52, 46)
local WHITE = Color3.fromRGB(236, 238, 240)
local GREY = Color3.fromRGB(128, 134, 140)
-- Strands are opaque, one solid colour per state: see-through ones stacked into brighter
-- blotches wherever they crossed.
local SEQ = table.freeze({
	on = ColorSequence.new(CYAN),
	dim = ColorSequence.new(Color3.fromRGB(26, 110, 124)),
	hand = ColorSequence.new(Color3.fromRGB(150, 236, 246)),
	cut = ColorSequence.new(Color3.fromRGB(240, 96, 72)), -- in hand, over a connection a drop would cut
})
-- Lane points are slab centre: the road top is half a slab up, and the overlay rides just over
-- the paint on it. Beams are also pulled toward the camera, so the road can never draw over
-- them -- and in a fixed order, so crossing strands never flicker over each other.
local LIFT = RoadConstants.ROAD_THICKNESS * 0.5 + 0.3
local UP = Vector3.yAxis * LIFT
local Z_DIM, Z_ON, Z_HAND = 1.5, 1.6, 1.7
local LINE_W = 1.0
local DOT_IN = 3.0
local DOT_OUT = 2.6
local DOT_GROW = 1.25    -- the picked lane, and the dot under the cursor
local RING_PAD = 4       -- a node's ring sits this far outside its dots
local RING_W_JUNCTION = 1.2
local RING_W_INNER = 0.5
local RING_GAP = 1.4     -- between a junction's two rings
local RING_W_JOINT = 0.6
local RING_HOVER = 1.6   -- ring width multiplier under the cursor
local MARKER_RANGE = 700 -- studs from the camera that nodes are ringed within
local MARKER_MAX = 120
local MARKER_MOVE = 40   -- camera travel before the ringed set is re-picked
-- New ring pieces made per frame. Opening the tool over a big city made ~120 in one frame
-- (~9 ms); spread out, the rings fill in over a few frames and no frame notices.
local NEW_RINGS_PER_FRAME = 12
local PICK_PX = 16       -- screen tolerance around a dot, so it stays grabbable zoomed out
local CLICK_PX = 6       -- a press that moves less than this is a click, not a drag
local HAND_PAD = 4       -- a strand's loose end stays within this of the node's dots
-- The server drops a connection edit within 0.15 s of the previous one
-- (RoadReplicationService), so requests go out at this spacing; the drawing never waits.
local SEND_GAP = 0.25
-- How long an unanswered edit is drawn before the server's own state wins.
local PREDICT_TTL = 2
local CURVE_RETRY = 0.3

-- A strand: lead-in from the arriving dot to where the car starts turning, the turn's cubic
-- cut in half at its midpoint, and the run on to the leaving dot. One flat ribbon twists
-- edge-on through a sharp turn (a U-turn pinches to nothing); two halves never do.
type Strand = {
	aIn: Attachment, a0: Attachment, am: Attachment, a3: Attachment, aOut: Attachment,
	lead: Beam, b0: Beam, b1: Beam, tail: Beam,
}
type Pending = { node: number, from: string, to: string, on: boolean, sentAt: number? }
type Links = { set: { [string]: boolean }, pairs: { { string } } }
-- The strand being moved: from an arriving lane, maybe lifted off a leaving one. `carry` is a
-- strand left on the cursor after a cut; the next click places or drops it.
type Hand = { from: string, lifted: string?, carry: boolean, press: Vector2 }

local _enabled = false
local _conns: { RBXScriptConnection } = {}
local _subscribed = false
local _anchor: Part? = nil
local _dots: { CylinderHandleAdornment } = {}
local _rings: { CylinderHandleAdornment } = {}
local _strands: { Strand } = {}
local _handStrand: Strand? = nil
local _node: number? = nil -- the node picked
local _lane: string? = nil -- the arriving lane picked (edge id)
local _linked: { [string]: boolean } = {} -- leaving lanes the picked lane reaches
local _hand: Hand? = nil
local _handTarget: any = nil
local _hoverNode: number? = nil
local _hoverDot: any = nil
local _touch: Vector2? = nil
local _pending: { [string]: Pending } = {}
local _queue: { () -> () } = {}
local _pumping = false
local _lastSend = 0
local _dirty = true
local _rightPress: Vector2? = nil
local _newRings = 0
local _lastScreen = Vector2.zero
local _lastCam = CFrame.identity
local _markerNodes: { number } = {}
local _markerAt: Vector3? = nil
local _markersStale = true
-- The picked node's turn curves ("from>to" -> { p0, c1, c2, p3 }), and the dot layout they
-- were fetched for: a patch that moves the dots fetches them again.
local _curveNode: number? = nil
local _curveSig = ""
local _curves: { [string]: { Vector3 } } = {}
local _curveFetching: number? = nil
local _reach: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local _links: { [any]: Links } = setmetatable({}, { __mode = "k" }) :: any
local _sigs: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any
local _resetBtn: TextButton? = nil
local _net: any = nil

local function net(): any
	if not _net then _net = require(ReplicatedStorage:WaitForChild("Networker")) end
	return _net
end

local function keyOf(from: string, to: string): string
	return from .. ">" .. to
end

-- The node's connections as a set, and as from/to pairs. Lane data is replaced, never edited,
-- so this (like reachOf and sigOf) is cached per table.
local function linksOf(lane: any): Links
	local cached = _links[lane]
	if cached then return cached end
	local made: Links = { set = {}, pairs = {} }
	for _, key in lane.links or {} do
		local from, to = string.match(key, "^([^>]+)>([^>]+)$")
		if from and to then
			made.set[key] = true
			table.insert(made.pairs, { from, to })
		end
	end
	_links[lane] = made
	return made
end

local function serverAllowed(nodeId: number, from: string, to: string): boolean
	local lane = DataCache.GetLanePath(nodeId)
	return lane ~= nil and linksOf(lane).set[keyOf(from, to)] == true
end

-- What the player sees: the server's answer, unless an edit of theirs is still on its way.
local function isOn(nodeId: number, from: string, to: string): boolean
	local p = _pending[keyOf(from, to)]
	if p then return p.on end
	return serverAllowed(nodeId, from, to)
end

-- Requests leave one at a time, SEND_GAP apart, even after the tool is closed.
local function pump()
	if _pumping then return end
	_pumping = true
	task.spawn(function()
		while #_queue > 0 do
			local gap = SEND_GAP - (os.clock() - _lastSend)
			if gap > 0 then task.wait(gap) end
			local job = table.remove(_queue, 1) :: () -> ()
			local ok, err = pcall(job)
			if not ok then warn("[LaneConnectorTool] send failed: " .. tostring(err)) end
			_lastSend = os.clock()
		end
		_pumping = false
	end)
end

local function setConnection(nodeId: number, from: string, to: string, on: boolean)
	local key = keyOf(from, to)
	local p = _pending[key]
	if p and not p.sentAt then
		-- Still queued: the newest edit is the one that goes.
		p.on = on
		return
	end
	if isOn(nodeId, from, to) == on then return end
	local entry: Pending = { node = nodeId, from = from, to = to, on = on }
	_pending[key] = entry
	table.insert(_queue, function()
		if _pending[key] ~= entry then return end
		net().RequestSetIntersectionConnection:FireServer(nodeId, from, to, entry.on)
		entry.sentAt = os.clock()
	end)
	pump()
end

local function reset()
	local nodeId = _node
	if not nodeId then return end
	for key, p in _pending do
		if p.node == nodeId then _pending[key] = nil end
	end
	table.insert(_queue, function()
		net().RequestResetIntersectionConnections:FireServer(nodeId)
	end)
	pump()
	_lane, _hand = nil, nil
	_dirty = true
end

-- ---- geometry ------------------------------------------------------------------

local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else nil
end

-- How far the node's dots reach from its centre.
local function reachOf(lane: any): number
	local cached = _reach[lane]
	if cached then return cached end
	local c = lane.position :: Vector3
	local r = 0
	for _, d in lane.dots do
		r = math.max(r, Vector3.new(d.position.X - c.X, 0, d.position.Z - c.Z).Magnitude)
	end
	_reach[lane] = r
	return r
end

-- The dot layout, as a string: equal strings, equal curves.
local function sigOf(lane: any): string
	local cached = _sigs[lane]
	if cached then return cached end
	local parts: { string } = {}
	for _, d in lane.dots do
		local p = d.position
		table.insert(parts, string.format("%s%.1f,%.1f,%.1f", d.edgeId, p.X, p.Y, p.Z))
	end
	local made = table.concat(parts, "|")
	_sigs[lane] = made
	return made
end

local function inDot(lane: any, edgeId: string): any
	for _, d in lane.dots do
		if d.kind == "in" and d.edgeId == edgeId then return d end
	end
	return nil
end

-- The picked node's curves, fetched once per dot layout. Until they land its strands wait --
-- a guessed curve that then jumps is worse than a tenth of a second without one.
local function ensureCurves(nodeId: number, lane: any)
	local sig = sigOf(lane)
	if _curveNode == nodeId and _curveSig == sig then return end
	if _curveFetching == nodeId then return end
	_curveFetching = nodeId
	task.spawn(function()
		local ok, map = pcall(function()
			return net().RequestLaneCurves:InvokeServer(nodeId)
		end)
		if _curveFetching == nodeId then _curveFetching = nil end
		if ok and typeof(map) == "table" then
			_curveNode, _curveSig, _curves = nodeId, sig, map
			_dirty = true
		else
			-- Rate-limited, or the node changed under the request: ask again while still open.
			task.delay(CURVE_RETRY, function()
				if _node == nodeId then _dirty = true end
			end)
		end
	end)
end

local function curveFor(nodeId: number, from: string, to: string): { Vector3 }?
	if _curveNode ~= nodeId then return nil end
	return _curves[keyOf(from, to)]
end

-- ---- drawing -------------------------------------------------------------------

local function anchor(): Part
	local a = _anchor
	if a and a.Parent then return a end
	-- First draw, or the scratch folder was swept: every pooled piece went with it.
	table.clear(_dots)
	table.clear(_rings)
	table.clear(_strands)
	_handStrand = nil
	local p = Instance.new("Part")
	p.Name = "Anchor"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.identity
	p.Parent = UiScratch.folder("LaneConnector")
	_anchor = p
	return p
end

local function newStrand(): Strand
	local host = anchor()
	local function att(): Attachment
		local a = Instance.new("Attachment")
		a.Parent = host
		return a
	end
	local function piece(from: Attachment, to: Attachment): Beam
		local b = Instance.new("Beam")
		b.Attachment0 = from
		b.Attachment1 = to
		-- Flat on the road, not turned to the camera: the same width from every angle.
		b.FaceCamera = false
		b.Segments = 10
		b.Texture = ""
		b.Transparency = NumberSequence.new(0) -- a Beam defaults to half see-through
		b.LightEmission = 0
		b.LightInfluence = 0
		b.Enabled = false
		b.Parent = host
		return b
	end
	local aIn, a0, am, a3, aOut = att(), att(), att(), att(), att()
	return {
		aIn = aIn, a0 = a0, am = am, a3 = a3, aOut = aOut,
		lead = piece(aIn, a0), b0 = piece(a0, am), b1 = piece(am, a3), tail = piece(a3, aOut),
	}
end

local function strand(i: number): Strand
	local s = _strands[i]
	if not s then
		s = newStrand()
		_strands[i] = s
	end
	return s
end

local function hideStrand(s: Strand)
	s.lead.Enabled = false
	s.b0.Enabled = false
	s.b1.Enabled = false
	s.tail.Enabled = false
end

-- A beam's handles run along its attachment's X axis and its width along the Y axis, so Y is
-- kept level: the ribbon lies flat.
local function frame(p: Vector3, dir: Vector3): CFrame
	local side = Vector3.yAxis:Cross(dir)
	return CFrame.fromMatrix(p, dir, if side.Magnitude > 1e-4 then side.Unit else Vector3.xAxis)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function style(b: Beam, seq: ColorSequence, z: number, width: number)
	b.Width0 = width
	b.Width1 = width
	if b.Color ~= seq then b.Color = seq end
	b.ZOffset = z
	b.Enabled = true
end

-- Lay a strand along `cubic` ({ p0, c1, c2, p3 }, road height), led in from the arriving dot
-- and on to the leaving dot wherever the car drives a straight stretch first or after.
local function setStrand(s: Strand, dotIn: Vector3, cubic: { Vector3 }, dotOut: Vector3?, seq: ColorSequence, z: number, width: number): boolean
	local p0, c1, c2, p3 = cubic[1] + UP, cubic[2] + UP, cubic[3] + UP, cubic[4] + UP
	-- A lane change lands past its dot (or off to the side of it): bend the curve to end ON
	-- the dot, keeping both headings, so the strand always reaches the circle it names.
	if dotOut then
		local gap = (dotOut + UP) - p3
		local d3 = p3 - c2
		if gap.Magnitude > 0.3 and gap:Dot(d3) <= 0.95 * gap.Magnitude * d3.Magnitude then
			local d0 = c1 - p0
			p3 = dotOut + UP
			local h = (p3 - p0).Magnitude / 3
			c1 = p0 + (if d0.Magnitude > 1e-4 then d0.Unit else Vector3.zero) * h
			c2 = p3 - (if d3.Magnitude > 1e-4 then d3.Unit else Vector3.zero) * h
		end
	end
	local chord = p3 - p0
	if chord.Magnitude < 0.1 then
		hideStrand(s)
		return false
	end
	local along = chord.Unit
	-- The cubic cut at t = 0.5 (de Casteljau): its halves are the same curve.
	local q1 = (p0 + c1) * 0.5
	local q2 = (p0 + c1 * 2 + c2) * 0.25
	local r1 = (c1 + c2 * 2 + p3) * 0.25
	local r2 = (c2 + p3) * 0.5
	local m = (q2 + r1) * 0.5
	local d0 = unitOr(c1 - p0, along)
	local d3 = unitOr(p3 - c2, along)
	s.a0.WorldCFrame = frame(p0, d0)
	s.am.WorldCFrame = frame(m, unitOr(r1 - q2, along))
	s.a3.WorldCFrame = frame(p3, d3)
	s.b0.CurveSize0 = (q1 - p0).Magnitude
	s.b0.CurveSize1 = (m - q2).Magnitude
	s.b1.CurveSize0 = (r1 - m).Magnitude
	s.b1.CurveSize1 = (p3 - r2).Magnitude
	style(s.b0, seq, z, width)
	style(s.b1, seq, z, width)
	local lead = p0 - (dotIn + UP)
	if lead.Magnitude > 0.3 then
		s.aIn.WorldCFrame = frame(dotIn + UP, lead.Unit)
		style(s.lead, seq, z, width)
	else
		s.lead.Enabled = false
	end
	local tail = if dotOut then (dotOut + UP) - p3 else Vector3.zero
	if tail.Magnitude > 0.3 and tail:Dot(d3) > 0 then
		s.aOut.WorldCFrame = frame((dotOut :: Vector3) + UP, tail.Unit)
		style(s.tail, seq, z, width)
	else
		s.tail.Enabled = false
	end
	return true
end

-- The loose end of a strand in hand: the arc leaving the dot along its lane and reaching the
-- cursor point -- the same circular-sweep handle the nav graph fits a turn with.
local function looseCubic(from: Vector3, dirRaw: any, to: Vector3): { Vector3 }?
	local chord = to - from
	local gap = Vector3.new(chord.X, 0, chord.Z).Magnitude
	local d0 = (if typeof(dirRaw) == "Vector3" then flat(dirRaw) else nil) or flat(chord)
	local d1 = flat(chord)
	if gap < 0.1 or not d0 or not d1 then return nil end
	local theta = math.acos(math.clamp(d0:Dot(d1), -1, 1))
	local h = gap / 3
	if theta > 0.05 then
		h = math.min((4 / 3) * math.tan(theta * 0.25) * (gap / (2 * math.sin(theta * 0.5))), gap * 0.7)
	end
	return { from, from + d0 * h, to - d1 * h, to }
end

-- Dots, rings: flat, unlit adornments -- one solid colour by day and night, never a bloom --
-- drawn over everything, so no kerb, pavement, slope or building can cut one. Always level:
-- they never tilt with the road or the camera.
local function adornment(pool: { CylinderHandleAdornment }, i: number, name: string, zIndex: number): CylinderHandleAdornment
	local d = pool[i]
	if d then return d end
	local host = anchor()
	local a = Instance.new("CylinderHandleAdornment")
	a.Name = name
	a.Adornee = host
	a.Height = 0.1
	a.AlwaysOnTop = true
	a.ZIndex = zIndex
	a.Parent = host
	pool[i] = a
	return a
end

-- The adornee sits at the origin, so CFrames are world CFrames; a cylinder adornment's axis
-- is its Z, tipped up to lie flat on the road.
local FLAT = CFrame.Angles(math.pi / 2, 0, 0)

-- What each disc shows now: a redraw that changes nothing about it touches no property.
type Disc = { pos: Vector3, color: Color3, radius: number, inner: number, shown: boolean }
local _discs: { [CylinderHandleAdornment]: Disc } = setmetatable({}, { __mode = "k" }) :: any

local function setDisc(a: CylinderHandleAdornment, pos: Vector3, color: Color3, radius: number, inner: number)
	local was = _discs[a]
	if was and was.shown and was.pos == pos and was.color == color and was.radius == radius and was.inner == inner then
		return
	end
	a.Color3 = color
	a.Radius = radius
	a.InnerRadius = inner
	a.CFrame = CFrame.new(pos + UP - Vector3.yAxis * 0.05) * FLAT
	a.Visible = true
	_discs[a] = { pos = pos, color = color, radius = radius, inner = inner, shown = true }
end

local function hideDisc(a: CylinderHandleAdornment)
	local was = _discs[a]
	if was and not was.shown then return end
	a.Visible = false
	if was then was.shown = false end
end

local function hideHand()
	local s = _handStrand
	if s then hideStrand(s) end
	_handTarget = nil
end

-- Every ringed node bar the picked one. A junction gets a bold cyan double ring, a plain joint
-- a thin white one; the one under the cursor is drawn heavier.
-- The pooled ring piece i, or nil once this frame's budget of new ones is spent (the next
-- frame carries on).
local function ringPiece(i: number): CylinderHandleAdornment?
	if _rings[i] then return _rings[i] end
	if _newRings >= NEW_RINGS_PER_FRAME then
		_dirty = true
		return nil
	end
	_newRings += 1
	return adornment(_rings, i, "NodeRing", 1)
end

local function drawRings()
	_newRings = 0
	local n = 0
	-- While a node is being edited the other rings step aside; right click brings them back.
	for _, nodeId in (if _node then {} else _markerNodes) do
		local lane = DataCache.GetLanePath(nodeId)
		if not lane or typeof(lane.position) ~= "Vector3" then continue end
		local grow = if nodeId == _hoverNode then RING_HOVER else 1
		local r = reachOf(lane) + RING_PAD
		if (lane.arms or 0) >= 3 then
			local outer = RING_W_JUNCTION * grow
			local a, b = ringPiece(n + 1), ringPiece(n + 2)
			if not (a and b) then break end
			setDisc(a, lane.position, CYAN, r, r - outer)
			local ri = r - outer - RING_GAP
			setDisc(b, lane.position, CYAN, ri, ri - RING_W_INNER * grow)
			n += 2
		else
			local a = ringPiece(n + 1)
			if not a then break end
			setDisc(a, lane.position, WHITE, r, r - RING_W_JOINT * grow)
			n += 1
		end
	end
	for i = n + 1, #_rings do hideDisc(_rings[i]) end
end

local function draw()
	_dirty = false
	anchor()
	if _node and not DataCache.GetLanePath(_node) then
		-- The node was bulldozed or rebuilt under us.
		_node, _lane, _hand = nil, nil, nil
		hideHand()
	end
	drawRings()
	local nodeId = _node
	local lane = if nodeId then DataCache.GetLanePath(nodeId) else nil
	local nDots, nStrands = 0, 0
	table.clear(_linked)
	if nodeId and lane then
		ensureCurves(nodeId, lane)
		local ins: { [string]: any } = {}
		local outs: { [string]: any } = {}
		for _, d in lane.dots do
			if d.kind == "in" then ins[d.edgeId] = d else outs[d.edgeId] = d end
		end
		if _lane and not ins[_lane] then
			_lane, _hand = nil, nil
			hideHand()
		end
		local hover = _hoverDot
		local hand = _hand
		local focus = _lane or (if hover and hover.kind == "in" then hover.edgeId else nil)
		-- What is connected: the server's links, overruled by any edit still on its way.
		local shown: { { string } } = {}
		for _, pair in linksOf(lane).pairs do
			local p = _pending[keyOf(pair[1], pair[2])]
			if not p or p.on then table.insert(shown, pair) end
		end
		for _, p in _pending do
			if p.node == nodeId and p.on and not serverAllowed(nodeId, p.from, p.to) then
				table.insert(shown, { p.from, p.to })
			end
		end
		for _, pair in shown do
			local from, to = pair[1], pair[2]
			local a, z = ins[from], outs[to]
			if not a or not z then continue end
			if hand and from == hand.from and to == hand.lifted then continue end -- in hand
			if from == _lane then _linked[to] = true end
			local cubic = curveFor(nodeId, from, to)
			if not cubic then continue end
			local seq, z0, width = SEQ.on, Z_DIM, LINE_W
			if _lane then
				if from ~= _lane then continue end
				z0, width = Z_ON, LINE_W * 1.25
			elseif focus and from ~= focus then
				seq = SEQ.dim
			elseif focus then
				z0, width = Z_ON, LINE_W * 1.25
			end
			if setStrand(strand(nStrands + 1), a.position, cubic, z.position, seq, z0, width) then
				nStrands += 1
			end
		end
		local target = _handTarget
		for _, d in lane.dots do
			local isIn = d.kind == "in"
			local picked = isIn and d.edgeId == _lane
			local aimed = (hover ~= nil and hover.kind == d.kind and hover.edgeId == d.edgeId)
				or (target ~= nil and not isIn and target.edgeId == d.edgeId)
			local color: Color3
			if isIn then
				color = if picked or not _lane then RED else RED_DIM
			else
				color = if aimed or not _lane or _linked[d.edgeId] then WHITE else GREY
			end
			nDots += 1
			local size = (if isIn then DOT_IN else DOT_OUT) * (if picked or aimed then DOT_GROW else 1)
			setDisc(adornment(_dots, nDots, "LaneDot", 3), d.position, color, size * 0.5, 0)
		end
	end
	for i = nDots + 1, #_dots do hideDisc(_dots[i]) end
	for i = nStrands + 1, #_strands do hideStrand(_strands[i]) end
	local btn = _resetBtn
	if btn then
		local perms = if _node then DataCache.GetTurnPerms(_node) else nil
		btn.Visible = _enabled and perms ~= nil and perms.manual == true
	end
end

-- ---- picking -------------------------------------------------------------------

-- Nearest dot of the node under a screen point that `accept` lets through.
local function dotAt(nodeId: number?, screen: Vector2, accept: (any) -> boolean): any
	local lane = if nodeId then DataCache.GetLanePath(nodeId) else nil
	local cam = Workspace.CurrentCamera
	if not lane or not cam then return nil end
	local best: any = nil
	local bestPx = math.huge
	for _, d in lane.dots do
		if not accept(d) then continue end
		local v, onScreen = cam:WorldToViewportPoint(d.position + UP)
		if not onScreen then continue end
		local px = (Vector2.new(v.X, v.Y) - screen).Magnitude
		local radiusPx = (if d.kind == "in" then DOT_IN else DOT_OUT) * 0.5 / CursorRay.studsPerPixel(v.Z)
		if px <= math.max(PICK_PX, radiusPx + 4) and px < bestPx then
			best, bestPx = d, px
		end
	end
	return best
end

-- With nothing in hand: any arriving lane, and -- once one is picked -- any leaving lane (a
-- click there connects it, or removes the connection it already has).
local function grabbable(d: any): boolean
	return d.kind == "in" or _lane ~= nil
end

local function isTarget(d: any): boolean
	return d.kind == "out"
end

-- The ringed node the cursor is inside. Rings are drawn over everything, so this is what you
-- see, not what a ray into the world hits first: the cursor ray is met on each ring's own
-- level plane -- a few multiply-adds per ringed node, no raycast.
local function nodeAt(screen: Vector2): number?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local ray = cam:ViewportPointToRay(screen.X, screen.Y)
	local o, dir = ray.Origin, ray.Direction
	if dir.Y > -1e-3 then return nil end
	local best: number? = nil
	local bestFit = 1
	for _, nodeId in _markerNodes do
		local lane = DataCache.GetLanePath(nodeId)
		local c = if lane then lane.position else nil
		if typeof(c) ~= "Vector3" then continue end
		local t = (c.Y + LIFT - o.Y) / dir.Y
		local dx, dz = o.X + dir.X * t - c.X, o.Z + dir.Z * t - c.Z
		-- 0 at the centre, 1 on the ring: the most central wins where rings overlap.
		local fit = math.sqrt(dx * dx + dz * dz) / (reachOf(lane) + RING_PAD)
		if fit <= bestFit then
			best, bestFit = nodeId, fit
		end
	end
	return best
end

-- The nodes worth a ring: the nearest within reach of the camera.
local function pickMarkerNodes(eye: Vector3)
	local near: { { any } } = {}
	for nodeId, lane in DataCache.GetLanePaths() do
		local c = lane.position
		if typeof(c) ~= "Vector3" then continue end
		local d = (c - eye).Magnitude
		if d <= MARKER_RANGE then table.insert(near, { nodeId, d }) end
	end
	table.sort(near, function(a, b) return a[2] < b[2] end)
	table.clear(_markerNodes)
	for i = 1, math.min(#near, MARKER_MAX) do
		table.insert(_markerNodes, near[i][1])
	end
	_markerAt = eye
	_markersStale = false
end

-- The strand in hand follows the cursor: onto the white dot under it along the very curve a
-- car would take, otherwise on the road plane, never further out than the node's own dots.
local function updateHand(screen: Vector2)
	local hand = _hand :: Hand
	local nodeId = _node
	local lane = if nodeId then DataCache.GetLanePath(nodeId) else nil
	local from = if lane then inDot(lane, hand.from) else nil
	local cam = Workspace.CurrentCamera
	if not nodeId or not from or not cam then
		_hand = nil
		hideHand()
		_dirty = true
		return
	end
	local s = _handStrand or newStrand()
	_handStrand = s
	local target = dotAt(nodeId, screen, isTarget)
	if target ~= _handTarget then
		_handTarget = target
		_dirty = true
	end
	if target then
		local cuts = target.edgeId ~= hand.lifted and isOn(nodeId, hand.from, target.edgeId)
		local cubic = curveFor(nodeId, hand.from, target.edgeId) or looseCubic(from.position, from.dir, target.position)
		if cubic then
			setStrand(s, from.position, cubic, target.position, if cuts then SEQ.cut else SEQ.hand, Z_HAND, LINE_W * 1.4)
		end
		return
	end
	local ray = cam:ViewportPointToRay(screen.X, screen.Y)
	if ray.Direction.Y > -1e-3 then return end -- at or above the horizon: keep the last pose
	local planeY = from.position.Y
	local hit = ray.Origin + ray.Direction * ((planeY - ray.Origin.Y) / ray.Direction.Y)
	local centre = lane.position :: Vector3
	local off = Vector3.new(hit.X - centre.X, 0, hit.Z - centre.Z)
	local limit = reachOf(lane) + HAND_PAD
	if off.Magnitude > limit then off = off.Unit * limit end
	local cubic = looseCubic(from.position, from.dir, Vector3.new(centre.X + off.X, planeY, centre.Z + off.Z))
	if cubic then
		setStrand(s, from.position, cubic, nil, SEQ.hand, Z_HAND, LINE_W * 1.4)
	else
		hideStrand(s)
	end
end

-- Let go of (or, carrying, click with) the strand in hand over `target`, a white dot or nil.
local function drop(target: any)
	local hand = _hand
	local nodeId = _node
	_hand = nil
	hideHand()
	_dirty = true
	if not hand or not nodeId then return end
	if target and target.edgeId == hand.lifted then return end -- put back where it was
	if hand.lifted then setConnection(nodeId, hand.from, hand.lifted, false) end
	if not target then return end
	if isOn(nodeId, hand.from, target.edgeId) then
		-- Let go on a lane it already reaches: that connection is cut, and the strand stays on
		-- the cursor to go somewhere else.
		setConnection(nodeId, hand.from, target.edgeId, false)
		_hand = { from = hand.from, lifted = nil, carry = true, press = Vector2.zero }
	else
		setConnection(nodeId, hand.from, target.edgeId, true)
	end
end

local function onPress(input: InputObject)
	local screen = CursorRay.position(input)
	_lastScreen = Vector2.new(-1, -1) -- re-pick next frame against the new state
	_dirty = true
	if _hand then
		-- Carrying: this click places it on a white dot, or drops it anywhere else.
		drop(dotAt(_node, screen, isTarget))
		return
	end
	if not _node then
		_node, _lane = nodeAt(screen), nil
		return
	end
	-- Editing a node, a left click acts on its dots and nothing else: stepping back is the
	-- right click's job.
	local dot = dotAt(_node, screen, grabbable)
	if not dot then return end
	if dot.kind == "in" then
		_lane = dot.edgeId
		_hand = { from = dot.edgeId, lifted = nil, carry = false, press = screen }
	elseif _lane then
		-- A connected white dot: held, its strand is lifted; clicked, the connection goes. Any
		-- other white dot: clicked, it is connected -- the same as dragging a strand onto it.
		_hand = { from = _lane, lifted = if _linked[dot.edgeId] then dot.edgeId else nil, carry = false, press = screen }
	end
end

local function onRelease(input: InputObject, overGui: boolean)
	local hand = _hand
	if not hand or hand.carry then return end
	local screen = CursorRay.position(input)
	local clicked = (screen - hand.press).Magnitude < CLICK_PX
	if clicked and hand.lifted and _node then
		-- A click on a connected white dot, not a hold: that connection goes, nothing in hand.
		_hand = nil
		hideHand()
		setConnection(_node, hand.from, hand.lifted, false)
		_dirty = true
		return
	end
	local target = if overGui then nil else dotAt(_node, screen, isTarget)
	if clicked and not target and not hand.lifted then
		-- A click on a red dot, not a drag: the lane is picked, nothing in hand.
		_hand = nil
		hideHand()
		_dirty = true
		return
	end
	drop(target)
end

-- Right click steps back one level: a strand in hand is let go without changing anything (one
-- lifted off a white dot was never sent away, so it is simply still there); else the picked
-- lane is let go; else the node, back to the rings of every node.
local function onRightClick()
	if _hand then
		_hand = nil
		hideHand()
	elseif _lane then
		_lane = nil
	else
		_node = nil
	end
	_lastScreen = Vector2.new(-1, -1)
	_dirty = true
end

local function isPointer(input: InputObject): boolean
	local t = input.UserInputType
	return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
end

local function step()
	local now = os.clock()
	-- Drop predictions the server has answered -- or has left unanswered for too long.
	for key, p in _pending do
		local sent = p.sentAt
		if sent and (serverAllowed(p.node, p.from, p.to) == p.on or now - sent > PREDICT_TTL) then
			_pending[key] = nil
			_dirty = true
		end
	end
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local eye = cam.CFrame.Position
	local at = _markerAt
	if _markersStale or not at or (eye - at).Magnitude > MARKER_MOVE then
		pickMarkerNodes(eye)
		_dirty = true
	end
	local screen = _touch or CursorRay.position()
	-- Nothing below runs unless the cursor or the camera moved.
	if screen ~= _lastScreen or cam.CFrame ~= _lastCam then
		_lastScreen, _lastCam = screen, cam.CFrame
		if _hand then
			updateHand(screen)
			if _hoverNode then
				_hoverNode = nil
				_dirty = true
			end
		else
			local dot = dotAt(_node, screen, grabbable)
			local hovered = if dot or _node then nil else nodeAt(screen)
			if dot ~= _hoverDot or hovered ~= _hoverNode then
				_hoverDot, _hoverNode = dot, hovered
				_dirty = true
			end
		end
	end
	if _dirty then draw() end
end

-- ---- public ----------------------------------------------------------------------

function LaneConnectorTool.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	_node, _lane, _hand, _hoverNode, _hoverDot, _touch, _rightPress = nil, nil, nil, nil, nil, nil, nil
	if not on then
		UiScratch.clear("LaneConnector")
		_anchor, _handStrand, _handTarget = nil, nil, nil
		table.clear(_dots)
		table.clear(_rings)
		table.clear(_strands)
		if _resetBtn then _resetBtn.Visible = false end
		return
	end
	if not _subscribed then
		_subscribed = true
		DataCache.On("lanePaths", function()
			_markersStale = true
			_dirty = true
		end)
		DataCache.On("turnPerms", function() _dirty = true end)
	end
	_dirty = true
	_markersStale = true
	_lastScreen = Vector2.new(-1, -1)
	table.insert(_conns, RunService.RenderStepped:Connect(step))
	table.insert(_conns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- Not filtered on gameProcessed: the stock camera input binds the right button, so
			-- every right click arrives already "processed". Only a click (no drag) counts.
			_rightPress = CursorRay.position(input)
			return
		end
		if gameProcessed or not isPointer(input) then return end
		if input.UserInputType == Enum.UserInputType.Touch then _touch = CursorRay.position(input) end
		onPress(input)
	end))
	table.insert(_conns, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then _touch = CursorRay.position(input) end
	end))
	-- Not filtered on gameProcessed: a strand let go over the HUD still has to be let go.
	table.insert(_conns, UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			local pressed = _rightPress
			_rightPress = nil
			-- A click, not a drag: a right-drag may be moving the camera.
			if pressed and (CursorRay.position(input) - pressed).Magnitude < CLICK_PX then
				onRightClick()
			end
			return
		end
		if not isPointer(input) then return end
		onRelease(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.Touch then _touch = nil end
	end))
end

function LaneConnectorTool.isEnabled(): boolean
	return _enabled
end

-- The Reset button, in the dock strip the card lives on. Shown only while a hand-wired node is
-- picked.
function LaneConnectorTool.mountControls(parent: Instance)
	local btn = Button.new({ text = "Reset lanes", name = "ResetLanes", compact = true, parent = parent, onClick = reset })
	local inst = btn.Instance
	inst.AnchorPoint = Vector2.new(0, 0.5)
	inst.Position = UDim2.fromScale(0, 0.5)
	inst.Visible = false
	_resetBtn = inst
end

-- Card art: a crossroads, one arriving lane picked (red) and its three turns (cyan).
function LaneConnectorTool.drawCardArt(container: Frame)
	local function box(x: number, y: number, size: UDim2, color: Color3, rotation: number?, round: boolean?)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.new(0.5, x, 0.5, y - 12)
		f.Size = size
		f.Rotation = rotation or 0
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		f.Parent = container
		if round then
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(1, 0)
			c.Parent = f
		end
	end
	local grey = Color3.fromRGB(96, 100, 108)
	box(0, 0, UDim2.new(0, 16, 1, -34), grey)
	box(0, 0, UDim2.new(0.8, 0, 0, 16), grey)
	local from = Vector2.new(4, 16)
	for _, to in { Vector2.new(4, -16), Vector2.new(-34, -4), Vector2.new(34, 4) } do
		local d = to - from
		local mid = (from + to) * 0.5
		box(mid.X, mid.Y, UDim2.fromOffset(d.Magnitude, 2), CYAN, math.deg(math.atan2(d.Y, d.X)))
		box(to.X, to.Y, UDim2.fromOffset(5, 5), WHITE, nil, true)
	end
	box(from.X, from.Y, UDim2.fromOffset(7, 7), RED, nil, true)
end

return LaneConnectorTool
