--!strict
-- NoPowerView
-- The pins over anything the utilities have let down. The sim stamps an attribute each
-- pass and this is the only thing that reads it -- so a pin can never disagree with the
-- sim, and the server sends no extra traffic for it. What each attribute means, its pin and
-- its wording live in UtilityProblems (the info panel lists the same set).
--
-- EVERY problem a building has gets a pin, STACKED over the roof (user 2026-10-07, CS2's reference): the first
-- in UtilityProblems.ORDER in front, the rest peeking out behind it to the right -- a house with no power and
-- no water shows both. Each pin's point sits on the thing it is about. A new pin PULSES a few
-- times as it appears -- movement is what catches the eye -- then holds still: a city of
-- pins all breathing forever was hundreds of live tweens every frame (user: laggy).
--
-- The road pin is the exception: it stands on the ground at the building's ENTRANCE, where
-- the road has to go (FrontDir, stamped by the server with NoRoad), not in the roof row.
--
-- Construction sites carry the same attributes (BuildingService stamps a marker per site),
-- so a street that is off the grid says so while it is still going up.
--
-- Pins never fade with distance (user, 2026-10-06). Instead, pins of the same kind that
-- crowd together on screen fold into ONE bigger pin, with no count on it -- a dark suburb is
-- one bolt from high up -- and zooming in unfolds them again. Folded pins of different kinds
-- that land in one spot are spread side by side the same way a roof's pins are.
--
-- Purely cosmetic. Families leaving a home that goes without is CitizenService's call,
-- off the same flags, not anything here.

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Problems = require(script.Parent:WaitForChild("UtilityProblems"))
local ServiceTypes = require(game:GetService("ReplicatedStorage").City.ServiceTypes)

local NoPowerView = {}

local BADGE = 40
-- The arrival pulse: grows to PULSE_MAX and back, PULSE_REPEATS more times, then the tween
-- is done and the pin costs nothing per frame. Owned by the BillboardGui, so destroying the
-- pin mid-pulse ends it -- nothing to track.
local PULSE_MAX = 1.25
local PULSE_REPEATS = 2
local PULSE_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, PULSE_REPEATS, true)
-- The pin's point is at the bottom of its image: lift the gui by half its height so the
-- point, not the middle, sits on the anchor. It also makes the pulse grow up from the point.
local PIN_LIFT = 0.5
-- Folded cluster pins of different kinds that land in one spot sit this many pin-widths apart.
local SPREAD = 0.72
-- A roof stack: each pin behind the front one sits this far right and up (pin sizes), this much smaller and
-- dimmer, so it reads as behind. One BillboardGui holds the stack -- separate guis have no draw order.
local STACK_STEP, STACK_RISE, STACK_SHRINK = 0.3, 0.06, 0.9
local STACK_DIM = Color3.fromRGB(205, 205, 205)
local STACK = "@stack" -- the roof stack's slot in a model's pins (its State attribute is its front pin's key)

-- Clustering (see the header). Screen-space, so it follows the zoom by itself: the same two
-- houses are one badge from high up and two from street level.
local CLUSTER_PX = 40            -- badges of one kind closer than this on screen merge
local CLUSTER_MIN_DIST = 150     -- studs from the camera; nearer than this every badge stands alone
local CLUSTER_EVERY = 0.25       -- seconds between re-clusterings
local CLUSTER_BADGE = 52

local ORDER_OF: { [string]: number } = {}
for i, attr in Problems.ORDER do ORDER_OF[attr] = i end
local function orderOf(key: string): number
	if key == "StrandedPipe" or key == "StrandedSewer" then return ORDER_OF.Stranded end
	return ORDER_OF[key] or 99
end

-- Folder names under Workspace._City whose models carry these attributes. Matched by name
-- anywhere in the tree, because every one of them is destroyed and rebuilt on a city load.
local WATCH_NAMES: { [string]: boolean } = {
	ZonedBuildings = true, -- houses and workplaces: NoPower / NoWater / Abandoned / NoRoad
	PowerLines = true,     -- poles wired to no generator
	EmergencyServices = true, -- service buildings: NoPower / NoWater / NoSewage / NoRoad
	Schools = true,        -- schools and the library: NoPower / NoWater / NoSewage (PowerService, WaterService)
	Transit = true,        -- bus depots, hubs and stations: NoPower / NoWater / NoSewage (TransitService.utilityCustomers)
	PipeEnds = true,       -- mains that stop in the middle of nowhere
	ConstructionSites = true, -- buildings still going up: NoPower / NoWater / NoSewage / NoRoad
	RoadWarnings = true,   -- RoadDeadEndService's markers on one-way ends nothing can use
}

local _started = false
local _conns: { [Model]: { RBXScriptConnection } } = {}
local _badges: { [Model]: { [string]: BillboardGui } } = {}
local _folderConns: { RBXScriptConnection } = {}
local _watched: { [Instance]: boolean } = {}
local _hidden: { [BillboardGui]: boolean } = {} -- badges folded into a cluster right now
-- Re-clustering is only needed when the view or the set of pins changed: a still camera over
-- a still city re-projected every pin four times a second for nothing.
local _pinsDirty = true

-- Over the middle of the roof, as an offset from `anchor`: a model's PrimaryPart is not always
-- its centre (a solar farm's sits at the gate, 400 studs from the middle).
local function roofOffset(model: Model, anchor: BasePart): Vector3
	local ok, cf, size = pcall(model.GetBoundingBox, model)
	if not ok then return Vector3.new(0, 12, 0) end
	return cf.Position + Vector3.new(0, size.Y * 0.5 + 3, 0) - anchor.Position
end

local function pinImage(parent: Instance): ImageLabel
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = parent
	return img
end

local function makePin(model: Model, anchor: BasePart, key: string, height: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "NoPowerBadge"
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(BADGE, BADGE)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.ResetOnSpawn = false
	gui:SetAttribute("State", key)
	pinImage(gui).Image = Problems.IMAGE[key] or ""
	gui.Parent = model
	_pinsDirty = true
	TweenService:Create(gui, PULSE_INFO, {
		Size = UDim2.fromOffset(BADGE * PULSE_MAX, BADGE * PULSE_MAX),
	}):Play()
	return gui
end

-- Lay the roof stack out for `row` (in ORDER): images reused, front on top.
local function layStack(gui: BillboardGui, row: { string })
	local images: { ImageLabel } = {}
	for _, c in gui:GetChildren() do
		if c:IsA("ImageLabel") then table.insert(images, c) end
	end
	local grew = #row > #images
	for i, key in row do
		local img = images[i] or pinImage(gui)
		local back = i - 1
		local scale = STACK_SHRINK ^ back
		img.Image = Problems.IMAGE[key] or ""
		img.ZIndex = #row - back
		img.AnchorPoint = Vector2.new(0.5, 1)
		img.Position = UDim2.fromScale(0.5 + back * STACK_STEP, 1 - back * STACK_RISE)
		img.Size = UDim2.fromScale(scale, scale)
		img.ImageColor3 = if back == 0 then Color3.new(1, 1, 1) else STACK_DIM
	end
	for i = #row + 1, #images do images[i]:Destroy() end
	gui:SetAttribute("State", row[1])
	-- centred on the whole stack, not the front pin
	gui.SizeOffset = Vector2.new(-(#row - 1) * STACK_STEP * 0.5, PIN_LIFT)
	if grew and #images > 0 then -- a problem joined an existing stack: it pulses like a new pin
		gui.Size = UDim2.fromOffset(BADGE, BADGE)
		TweenService:Create(gui, PULSE_INFO, { Size = UDim2.fromOffset(BADGE * PULSE_MAX, BADGE * PULSE_MAX) }):Play()
	end
	_pinsDirty = true
end

local function dropPin(gui: BillboardGui)
	_hidden[gui] = nil
	gui:Destroy()
	_pinsDirty = true
end

local function hide(model: Model)
	local pins = _badges[model]
	if not pins then return end
	for _, gui in pins do dropPin(gui) end
	_badges[model] = nil
end

-- Studs in front of the building's face the road pin stands, and how high its point is.
local ENTRANCE_OUT, ENTRANCE_UP = 4, 2

-- Where the road pin goes, as an offset from `anchor`: on the ground just outside the face the
-- road belongs at. nil (no FrontDir) = it sits in the roof row like the rest.
local function entranceOffset(model: Model, anchor: BasePart): Vector3?
	local front = model:GetAttribute("FrontDir")
	if typeof(front) ~= "Vector3" then return nil end
	local dir = Vector3.new(front.X, 0, front.Z)
	if dir.Magnitude < 1e-3 then return nil end
	dir = dir.Unit
	local cf, size = model:GetBoundingBox()
	local half = 0.5 * (math.abs(dir:Dot(cf.RightVector)) * size.X + math.abs(dir:Dot(cf.LookVector)) * size.Z)
	local base = cf.Position.Y - size.Y * 0.5
	local spot = Vector3.new(cf.Position.X, base + ENTRANCE_UP, cf.Position.Z) + dir * (half + ENTRANCE_OUT)
	return spot - anchor.Position
end

-- "Power line not connected" stands on the spot the line has to reach: the plant's hook spot.
local function hookOffset(model: Model, anchor: BasePart): Vector3?
	local spot = ServiceTypes.hookOf(model)
	if not spot then return nil end
	return spot + Vector3.new(0, ENTRANCE_UP, 0) - anchor.Position
end

-- Bring the pins over `model` in line with its attributes: one stack over the roof -- except the road pin,
-- which stands at the entrance, and the line pin, which stands at the hook, when they know where.
local function refresh(model: Model)
	local keys = Problems.keysFor(model)
	if #keys == 0 then
		hide(model)
		return
	end
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then
		hide(model)
		return
	end
	local want: { [string]: boolean } = {}
	for _, key in keys do want[key] = true end
	local ground: { [string]: Vector3 } = {} -- pins that stand on the ground where the fix goes
	if want.NoRoad then ground.NoRoad = entranceOffset(model, anchor :: BasePart) end
	if want.Stranded then ground.Stranded = hookOffset(model, anchor :: BasePart) end
	local row: { string } = {}
	for _, key in keys do
		if not ground[key] then table.insert(row, key) end
	end

	local pins = _badges[model] or {}
	for key, gui in pins do
		if key ~= STACK and not ground[key] then
			dropPin(gui)
			pins[key] = nil
		end
	end
	for key, at in ground do
		local gui = pins[key] or makePin(model, anchor :: BasePart, key, 0)
		pins[key] = gui
		gui.StudsOffsetWorldSpace = at
		gui.SizeOffset = Vector2.new(0, PIN_LIFT)
	end
	local stack = pins[STACK]
	if #row == 0 then
		if stack then dropPin(stack) end
		pins[STACK] = nil
	else
		if not stack then
			stack = makePin(model, anchor :: BasePart, row[1], 0)
			pins[STACK] = stack
		end
		local gui = stack :: BillboardGui
		gui.StudsOffsetWorldSpace = roofOffset(model, anchor :: BasePart)
		layStack(gui, row)
	end
	_badges[model] = pins
	_pinsDirty = true -- offsets may have moved
end

-- ---- clustering ------------------------------------------------------------------------
type ClusterSlot = { part: Part, gui: BillboardGui, image: ImageLabel }
local _clusterFolder: Folder? = nil
local _clusterPool: { ClusterSlot } = {}
local _clusterConn: RBXScriptConnection? = nil

local function clusterFolder(): Folder
	local f = _clusterFolder
	if f and f.Parent then return f end
	local made = Instance.new("Folder")
	made.Name = "UtilityBadgeClusters"
	made.Parent = Workspace.CurrentCamera or Workspace
	_clusterFolder = made
	table.clear(_clusterPool)
	return made
end

local function clusterSlot(i: number): ClusterSlot
	local slot = _clusterPool[i]
	if slot and slot.part.Parent then return slot end
	-- An invisible anchor per cluster, local to this client (it lives under the camera).
	local part = Instance.new("Part")
	part.Name = "ClusterAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = clusterFolder()

	local gui = Instance.new("BillboardGui")
	gui.Name = "UtilityCluster"
	gui.Adornee = part
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(CLUSTER_BADGE, CLUSTER_BADGE)
	gui.SizeOffset = Vector2.new(0, PIN_LIFT)
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local image = pinImage(gui)

	gui.Parent = part
	local made: ClusterSlot = { part = part, gui = gui, image = image }
	_clusterPool[i] = made
	return made
end

local function reveal(gui: BillboardGui)
	if _hidden[gui] then
		_hidden[gui] = nil
		if gui.Parent then gui.Enabled = true end
	end
end

type Item = { gui: BillboardGui, pos: Vector3, x: number, y: number }
type Folded = { key: string, pos: Vector3, x: number, y: number }

local function recluster()
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position
	-- Candidates per pin kind; everything else stands alone.
	local byKey: { [string]: { Item } } = {}
	for _, pins in _badges do
		for slot, gui in pins do
			-- a roof stack folds with others of its FRONT pin's kind
			local key = if slot == STACK then tostring(gui:GetAttribute("State")) else slot
			local anchor = gui.Adornee
			if not (anchor and anchor:IsA("BasePart") and anchor.Parent) then
				reveal(gui)
				continue
			end
			local pos = (anchor :: BasePart).Position + gui.StudsOffsetWorldSpace
			local sp, onScreen = cam:WorldToViewportPoint(pos)
			if not onScreen or (pos - camPos).Magnitude < CLUSTER_MIN_DIST then
				reveal(gui)
				continue
			end
			local list = byKey[key]
			if not list then
				list = {}
				byKey[key] = list
			end
			table.insert(list, { gui = gui, pos = pos, x = sp.X, y = sp.Y })
		end
	end

	local folded: { Folded } = {}
	local stillHidden: { [BillboardGui]: boolean } = {}
	for key, list in byKey do
		-- Greedy: the next unclaimed badge gathers every unclaimed one within CLUSTER_PX of
		-- it. A screen-space hash keeps that local. Sorted so the result is stable frame to
		-- frame while the camera holds still.
		table.sort(list, function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end)
		local grid: { [number]: { number } } = {}
		for i, it in list do
			local k = math.floor(it.x / CLUSTER_PX) * 100003 + math.floor(it.y / CLUSTER_PX)
			local cell = grid[k]
			if not cell then
				cell = {}
				grid[k] = cell
			end
			table.insert(cell, i)
		end
		local taken: { [number]: boolean } = {}
		for i, seed in list do
			if taken[i] then continue end
			taken[i] = true
			local members = { seed }
			local cx, cy = math.floor(seed.x / CLUSTER_PX), math.floor(seed.y / CLUSTER_PX)
			for gx = cx - 1, cx + 1 do
				for gy = cy - 1, cy + 1 do
					for _, j in (grid[gx * 100003 + gy] or {}) do
						if not taken[j] then
							local o = list[j]
							local dx, dy = o.x - seed.x, o.y - seed.y
							if dx * dx + dy * dy <= CLUSTER_PX * CLUSTER_PX then
								taken[j] = true
								table.insert(members, o)
							end
						end
					end
				end
			end
			if #members < 2 then
				reveal(seed.gui)
				continue
			end
			local sum = Vector3.zero
			local sx, sy = 0, 0
			for _, m in members do
				sum += m.pos
				sx += m.x
				sy += m.y
				stillHidden[m.gui] = true
				_hidden[m.gui] = true
				m.gui.Enabled = false
			end
			table.insert(folded, { key = key, pos = sum / #members, x = sx / #members, y = sy / #members })
		end
	end

	-- Folded pins of different kinds landing in one screen cell sit side by side, in ORDER.
	local cells: { [number]: { Folded } } = {}
	for _, f in folded do
		local k = math.floor(f.x / CLUSTER_PX) * 100003 + math.floor(f.y / CLUSTER_PX)
		local cell = cells[k]
		if not cell then
			cell = {}
			cells[k] = cell
		end
		table.insert(cell, f)
	end
	local used = 0
	for _, cell in cells do
		table.sort(cell, function(a, b) return orderOf(a.key) < orderOf(b.key) end)
		for i, f in cell do
			used += 1
			local slot = clusterSlot(used)
			slot.part.CFrame = CFrame.new(f.pos)
			slot.image.Image = Problems.IMAGE[f.key] or ""
			slot.gui.SizeOffset = Vector2.new((i - (#cell + 1) * 0.5) * SPREAD, PIN_LIFT)
			slot.gui.Enabled = true
		end
	end
	-- Badges that were folded last pass but are not now come back on their own.
	for gui in _hidden do
		if not stillHidden[gui] then reveal(gui) end
	end
	for i = used + 1, #_clusterPool do
		_clusterPool[i].gui.Enabled = false
	end
end

local function startClustering()
	if _clusterConn then return end
	local acc = 0
	local lastView: CFrame? = nil
	_clusterConn = RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < CLUSTER_EVERY then return end
		acc = 0
		local cam = Workspace.CurrentCamera
		local view = cam and cam.CFrame
		if not _pinsDirty and view == lastView then return end
		_pinsDirty = false
		lastView = view
		recluster()
	end)
end

local function stopClustering()
	if _clusterConn then
		_clusterConn:Disconnect()
		_clusterConn = nil
	end
	for gui in _hidden do
		if gui.Parent then gui.Enabled = true end
	end
	table.clear(_hidden)
	if _clusterFolder then _clusterFolder:Destroy() end
	_clusterFolder = nil
	table.clear(_clusterPool)
end

local function untrack(model: Model)
	local conns = _conns[model]
	if conns then
		for _, c in conns do c:Disconnect() end
		_conns[model] = nil
	end
	hide(model)
end

local function track(model: Instance)
	if not model:IsA("Model") or _conns[model] then return end
	local conns: { RBXScriptConnection } = {}
	for _, attr in Problems.ORDER do
		conns[#conns + 1] = model:GetAttributeChangedSignal(attr):Connect(function()
			refresh(model :: Model)
		end)
	end
	conns[#conns + 1] = model:GetAttributeChangedSignal("FrontDir"):Connect(function()
		refresh(model :: Model)
	end)
	_conns[model] = conns
	refresh(model :: Model)
end

local function watchFolder(folder: Instance)
	if _watched[folder] then return end
	_watched[folder] = true
	for _, m in folder:GetChildren() do track(m) end
	table.insert(_folderConns, folder.ChildAdded:Connect(track))
	table.insert(_folderConns, folder.ChildRemoved:Connect(function(m)
		if m:IsA("Model") then untrack(m) end
	end))
	table.insert(_folderConns, folder.AncestryChanged:Connect(function()
		if not folder:IsDescendantOf(Workspace) then _watched[folder] = nil end
	end))
end

function NoPowerView.Start()
	if _started then return end
	_started = true
	startClustering()

	-- These folders only exist once a city is loaded, and they are destroyed and rebuilt on
	-- every load, so this matches by NAME anywhere under _City and re-attaches rather than
	-- binding once. PipeEnds sits a level deeper than the rest, which is why it is a
	-- descendant walk and not a child walk.
	local function consider(inst: Instance)
		if inst:IsA("Folder") and WATCH_NAMES[inst.Name] then watchFolder(inst) end
	end
	local function attach(city: Instance)
		for _, d in city:GetDescendants() do consider(d) end
		table.insert(_folderConns, city.DescendantAdded:Connect(consider))
	end
	local city = Workspace:FindFirstChild("_City")
	if city then attach(city) end
	table.insert(_folderConns, Workspace.ChildAdded:Connect(function(c)
		if c.Name == "_City" then attach(c) end
	end))
end

function NoPowerView.Stop()
	stopClustering()
	for _, c in _folderConns do c:Disconnect() end
	table.clear(_folderConns)
	table.clear(_watched)
	for model in _conns do untrack(model) end
	_started = false
end

return NoPowerView
