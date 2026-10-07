--!strict
-- TrafficJamView
-- The badge over a traffic jam. Twin of NoPowerView in shape: a pulsing billboard, purely
-- cosmetic, no server traffic.
--
-- ponytail: the jam is DETECTED CLIENT-SIDE from the cars themselves rather than pushed from
-- NPCDriverService's congestion snapshot -- a stalled car is already replicated, so a badge
-- that reads the world needs no remote, no rate limit and no attribute plumbing. Ceiling:
-- it knows nothing the sim knows (which edge, how long). If the badge ever needs to say
-- "blocked 40 s" or open the road panel, move it onto a congestion push instead.

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))

local TrafficJamView = {}

local TAG = "NPCDriver"
local SCAN_PERIOD = 1.0   -- s between sweeps; a jam is not a per-frame event
local STALL_DIST = 3      -- studs moved between sweeps and under, the car is stopped
local CELL = 45           -- studs; jam grouping grid (roughly one block face)
local MIN_CARS = 6        -- stalled cars in one cell before the cell counts as jammed
-- A red light stops a queue for one light phase. A JAM is a queue that is still there well
-- after the phase ended, so a cell must come up jammed this many sweeps RUNNING before it
-- counts -- and must come up clear this many before it stops counting, so the icon does not
-- flicker on the one car that creeps forward.
local HOLD_ON = 30        -- sweeps (~30 s) jammed before the badge appears
local HOLD_OFF = 4        -- sweeps clear before it goes away
-- Touching jammed cells are ONE jam and get one badge; a jam longer than LONG_JAM gets one
-- near each end instead, END_INSET in from it. One badge per cell put twenty on a long queue.
local LONG_JAM = 160      -- studs, end to end
local END_INSET = 30      -- studs
local REUSE_DIST = 150    -- studs a badge may slide to follow its jam instead of being rebuilt
local BADGE = 34
local MAX_DISTANCE = 1200
local HEIGHT = 14         -- studs above the cars
local PULSE_MIN, PULSE_MAX = 0.85, 1.15
local PULSE_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

type Badge = { gui: BillboardGui, part: BasePart }
type Cell = { cx: number, cz: number, streak: number, pos: Vector3, shown: boolean }

local _started = false
local _acc = 0
local _lastPos: { [Model]: Vector3 } = {}
local _cells: { [string]: Cell } = {} -- cells with an opinion: jammed now, or cooling off
local _badges: { Badge } = {}
local _conn: RBXScriptConnection? = nil

local function makeBadge(pos: Vector3): Badge
	local part = Instance.new("Part")
	part.Name = "TrafficJamAnchor"
	part.Size = Vector3.one
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Anchored = true
	part.Position = pos
	part.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Name = "TrafficJamBadge"
	gui.Adornee = part
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(BADGE * PULSE_MIN, BADGE * PULSE_MIN)
	gui.MaxDistance = MAX_DISTANCE
	gui.ResetOnSpawn = false
	gui.Parent = part

	local disc = Instance.new("Frame")
	disc.Size = UDim2.fromScale(1, 1)
	disc.BackgroundColor3 = Theme.Color.Danger
	disc.BorderSizePixel = 0
	disc.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = disc
	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(24, 24, 26)
	edge.Thickness = 1.5
	edge.Transparency = 0.25
	edge.Parent = disc

	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Text = "\u{1F6A6}"
	glyph.TextColor3 = Color3.fromRGB(255, 250, 240)
	glyph.TextScaled = true
	glyph.FontFace = Theme.Font.Bold
	glyph.Parent = disc

	TweenService:Create(gui, PULSE_INFO, {
		Size = UDim2.fromOffset(BADGE * PULSE_MAX, BADGE * PULSE_MAX),
	}):Play()
	return { gui = gui, part = part }
end

local function rootOf(car: Instance): BasePart?
	if not car:IsA("Model") then return nil end
	return car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
end

local function cellKey(cx: number, cz: number): string
	return cx .. "_" .. cz
end

-- The cell centre nearest `p`: badges sit over cars, not on a line drawn between two ends.
local function nearestCell(members: { Cell }, p: Vector3): Vector3
	local best, bestD = members[1].pos, math.huge
	for _, c in members do
		local d = (c.pos - p).Magnitude
		if d < bestD then best, bestD = c.pos, d end
	end
	return best
end

-- Where the badges go for one jam (a set of touching cells): one over a short jam, one in
-- from each end of a long one. The ends are the two cells farthest apart.
local function badgeSpots(members: { Cell }, out: { Vector3 })
	local mean = Vector3.zero
	for _, c in members do mean += c.pos end
	mean /= #members
	local a = nearestCell(members, mean)
	for _, c in members do
		if (c.pos - mean).Magnitude > (a - mean).Magnitude then a = c.pos end
	end
	local b = a
	for _, c in members do
		if (c.pos - a).Magnitude > (b - a).Magnitude then b = c.pos end
	end
	local span = b - a
	if span.Magnitude < LONG_JAM then
		table.insert(out, nearestCell(members, mean))
		return
	end
	local dir = span.Unit
	table.insert(out, nearestCell(members, a + dir * END_INSET))
	table.insert(out, nearestCell(members, b - dir * END_INSET))
end

-- Move the badges onto this sweep's spots: each spot takes the nearest free badge within
-- REUSE_DIST (so a jam's badge follows it instead of blinking), else a new one.
local function placeBadges(spots: { Vector3 })
	local free = _badges
	_badges = {}
	for _, spot in spots do
		local pos = spot + Vector3.new(0, HEIGHT, 0)
		local bestI, bestD = nil, REUSE_DIST
		for i, b in free do
			local d = (b.part.Position - pos).Magnitude
			if d < bestD then bestI, bestD = i, d end
		end
		if bestI then
			local b = table.remove(free, bestI) :: Badge
			b.part.Position = pos
			table.insert(_badges, b)
		else
			table.insert(_badges, makeBadge(pos))
		end
	end
	for _, b in free do b.part:Destroy() end
end

-- One sweep: which grid cells hold enough stopped cars to be a jam, grouped into jams.
local function scan()
	local count: { [string]: number } = {}
	local sum: { [string]: Vector3 } = {}
	local live: { [Model]: boolean } = {}

	for _, car in CollectionService:GetTagged(TAG) do
		local root = rootOf(car)
		if not root then continue end
		local model = car :: Model
		live[model] = true
		local pos = root.Position
		local prev = _lastPos[model]
		_lastPos[model] = pos
		if not prev or (pos - prev).Magnitude > STALL_DIST then continue end
		local cx, cz = pos.X // CELL, pos.Z // CELL
		local key = cellKey(cx, cz)
		count[key] = (count[key] or 0) + 1
		sum[key] = (sum[key] or Vector3.zero) + pos
		if not _cells[key] then _cells[key] = { cx = cx, cz = cz, streak = 0, pos = pos, shown = false } end
	end
	for model in _lastPos do
		if not live[model] then _lastPos[model] = nil end
	end

	-- Age every cell we have an opinion about; a jammed cell remembers where its cars stand.
	local on: { [string]: Cell } = {}
	for key, cell in _cells do
		local n = count[key] or 0
		local s = cell.streak
		if n >= MIN_CARS then
			s = math.min(if s < 0 then 1 else s + 1, HOLD_ON)
			cell.pos = sum[key] / n
		else
			s = if s > 0 then -1 else math.max(s - 1, -HOLD_OFF)
		end
		cell.streak = s
		if s >= HOLD_ON or (s < 0 and s > -HOLD_OFF and cell.shown) then
			on[key] = cell -- jammed long enough, or holding its badge through a wobble
		end
		cell.shown = on[key] ~= nil
		if s <= -HOLD_OFF then _cells[key] = nil end
	end

	-- Touching jammed cells (8-neighbour) are one jam.
	local spots: { Vector3 } = {}
	local seen: { [string]: boolean } = {}
	for key, cell in on do
		if seen[key] then continue end
		seen[key] = true
		local members: { Cell } = {}
		local stack = { cell }
		while #stack > 0 do
			local c = table.remove(stack) :: Cell
			table.insert(members, c)
			for dx = -1, 1 do
				for dz = -1, 1 do
					local k = cellKey(c.cx + dx, c.cz + dz)
					local n = on[k]
					if n and not seen[k] then
						seen[k] = true
						table.insert(stack, n)
					end
				end
			end
		end
		badgeSpots(members, spots)
	end
	placeBadges(spots)
end

function TrafficJamView.Start()
	if _started then return end
	_started = true
	_conn = RunService.Heartbeat:Connect(function(dt)
		_acc += dt
		if _acc < SCAN_PERIOD then return end
		_acc = 0
		debug.profilebegin("TrafficJamView.scan")
		local ok, err = pcall(scan)
		debug.profileend()
		if not ok then warn("[TrafficJamView] scan failed: " .. tostring(err)) end
	end)
end

function TrafficJamView.Stop()
	if _conn then _conn:Disconnect(); _conn = nil end
	placeBadges({})
	table.clear(_lastPos)
	table.clear(_cells)
	_started = false
end

-- Pure part of the sweep, for the spec.
TrafficJamView._badgeSpots = badgeSpots

return TrafficJamView
