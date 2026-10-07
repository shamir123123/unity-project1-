--!strict
-- AmbientCityView (client)
-- "Full city simulation" OFF (Settings.fullCitySim) is for devices that cannot take the real
-- traffic. The server keeps simulating every car and citizen exactly as before; THIS client
-- takes the real vehicles and walkers out of its world and fills the streets near the camera
-- with a small local pool of cars and people wandering the road network, so the city does not
-- look empty. Decorative on purpose (user, 2026-10-05) and local only: nothing here reaches the
-- server or the sim. Switching back on restores the real ones.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DataCache = require(ReplicatedStorage:WaitForChild("DataCache"))
local GameSpeed = require(ReplicatedStorage:WaitForChild("GameSpeed"))
local Road = ReplicatedStorage:WaitForChild("Road")
local BezierUtil = require(Road:WaitForChild("BezierUtil"))
local RoadConstants = require(Road:WaitForChild("RoadConstants"))
local RoadProfile = require(Road:WaitForChild("RoadProfile"))
local RoadRules = require(Road:WaitForChild("RoadRules"))
local RoadTypeCatalog = require(Road:WaitForChild("RoadTypeCatalog"))
local CitizenModel = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("CitizenModel"))
local Settings = require(script.Parent.Parent.Core.Settings)

local AmbientCityView = {}

-- The real NPC folders under workspace._City, taken out of this client's world while off. The
-- buses stay (user, 2026-10-05): a city's few buses cost little, they are the transit the player
-- built, and their panels show the real riders (and the fares those riders pay).
local REAL_FOLDERS: { [string]: true } = { NPCDrivers = true, Citizens = true, Trucks = true, NPCWalkers = true }
local POOL_LOW = 25 -- cars and people each, on the Low preset
local POOL = 50
local TEMPLATE_MAX = 8
local TICK = 1 / 20
local REFRESH = 1 -- s between nearby-road scans / recycling
local SPAWN_RADIUS = 450 -- studs around the camera's ground point
local RECYCLE_RADIUS = 650
local WS = RoadConstants.WORLD_SCALE
local CAR_SPEED = 24 * WS -- CitizenService.CAR_SPEED
local WALK_SPEED = 5 * WS -- NPCWalkingService.WALK_SPEED
local NODE_KEY = 2 -- studs: segment ends closer than this meet at one node
local UP = Vector3.yAxis
local FALLBACK_CAR = Vector3.new(2, 1.6, 4.5)

type Seg = { id: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, len: number,
	fwd: { number }, back: { number }, walk: number?, tunnel: boolean, oneWay: boolean }
-- off: the car's lane, as a lateral offset in the segment's p0 -> p3 frame (+ = right of p0 -> p3)
type Agent = { model: Model, root: BasePart, car: boolean, seg: Seg?, t: number, dir: number,
	side: number, off: number, speed: number, dy: number }

local _segs: { [number]: Seg } = {}
local _nodes: { [string]: { Seg } } = {}
local _near: { Seg } = {}
local _agents: { Agent } = {}
local _templates: { Model } = {}
local _detached: { Instance } = {}
local _folder: Folder? = nil
local _conns: { RBXScriptConnection } = {}
local _cityConn: RBXScriptConnection? = nil
local _rng = Random.new()
local _accum, _refreshIn = 0, 0
local _off = false

local function keyOf(p: Vector3): string
	return math.round(p.X / NODE_KEY) .. "," .. math.round(p.Z / NODE_KEY)
end

local function indexSegments(list: { any })
	table.clear(_segs)
	table.clear(_nodes)
	for _, s in list do
		local spec = RoadTypeCatalog.getOrDefault(s.roadType)
		local hasWalk = not spec.isHighway and spec.sidewalkMode ~= "none"
		-- The lanes the real cars drive (RoadNavigationGraph lanePlans reads the same profile).
		local fwd, back = {}, {}
		if spec.profile then
			for _, l in RoadProfile.lanes(spec.profile, RoadRules.getLaneSideSign()) do
				table.insert(if l.forward then fwd else back, l.offset)
			end
		end
		if #fwd == 0 then
			fwd, back = { spec.width * 0.25 }, { -spec.width * 0.25 }
		end
		local seg: Seg = {
			id = s.id, p0 = s.p0, p1 = s.p1, p2 = s.p2, p3 = s.p3,
			len = math.max(1, BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 8)),
			fwd = fwd, back = back,
			walk = if hasWalk then spec.width * 0.5 + RoadTypeCatalog.footwayWidth(spec) * 0.5 else nil,
			tunnel = s.vMode == "Tunnel",
			oneWay = #back == 0,
		}
		_segs[seg.id] = seg
		for _, p in { seg.p0, seg.p3 } do
			local k = keyOf(p)
			local at = _nodes[k]
			if not at then at = {}; _nodes[k] = at end
			table.insert(at, seg)
		end
	end
end

local function groundFocus(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then return nil end
	local cf = camera.CFrame
	local look = cf.LookVector
	if look.Y >= -0.05 then return cf.Position end
	return cf.Position + look * ((RoadConstants.getGroundY() - cf.Position.Y) / look.Y)
end

local function poseOf(a: Agent): (Vector3, Vector3)
	local s = a.seg :: Seg
	local p = BezierUtil.point(s.p0, s.p1, s.p2, s.p3, a.t)
	local fwd = BezierUtil.tangent(s.p0, s.p1, s.p2, s.p3, a.t) * a.dir
	fwd = Vector3.new(fwd.X, 0, fwd.Z)
	fwd = if fwd.Magnitude > 1e-4 then fwd.Unit else Vector3.zAxis
	local off = if a.car then a.off * a.dir else (s.walk or 0) * a.side
	return p + fwd:Cross(UP) * off + Vector3.new(0, a.dy, 0), fwd
end

-- Surface height under the agent's line on this segment, measured once per segment.
local function measureDy(a: Agent)
	a.dy = RoadConstants.ROAD_THICKNESS * 0.5
	local pos = poseOf(a)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { _folder :: Folder }
	local hit = Workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), params)
	if hit then a.dy += hit.Position.Y - pos.Y end
end

-- rightOf: the lane to stay nearest, as metres right of travel; nil picks a lane at random.
local function place(a: Agent, seg: Seg, t: number, dir: number, rightOf: number?)
	a.seg, a.t, a.dir = seg, t, dir
	a.side = if _rng:NextNumber() < 0.5 then 1 else -1
	local lanes = if dir > 0 then seg.fwd else seg.back
	a.off = lanes[_rng:NextInteger(1, #lanes)] or 0
	if rightOf then
		for _, o in lanes do
			if math.abs(o * dir - rightOf) < math.abs(a.off * dir - rightOf) then a.off = o end
		end
	end
	measureDy(a)
	local pos, fwd = poseOf(a)
	a.root.CFrame = CFrame.lookAt(pos, pos + fwd)
end

local function usable(a: Agent, seg: Seg): boolean
	return not seg.tunnel and (a.car or seg.walk ~= nil)
end

local function spawnNear(a: Agent)
	for _ = 1, 8 do
		local seg = _near[_rng:NextInteger(1, math.max(1, #_near))]
		if seg and usable(a, seg) then
			local dir = if seg.oneWay and a.car then 1 elseif _rng:NextNumber() < 0.5 then 1 else -1
			place(a, seg, _rng:NextNumber(), dir)
			a.model.Parent = _folder
			return
		end
	end
	a.seg = nil
	a.model.Parent = nil -- no road near the camera: wait off-world
end

local function startsAt(s: Seg, p: Vector3): boolean
	return (s.p0 - p).Magnitude <= (s.p3 - p).Magnitude
end

-- End of the segment: carry on along a random road from that node, U-turn at a dead end.
-- Cars only enter a one-way road at its start; with no legal way on they respawn elsewhere.
local function hop(a: Agent)
	local seg = a.seg :: Seg
	local endP = if a.dir > 0 then seg.p3 else seg.p0
	local choices: { Seg } = {}
	for _, s in _nodes[keyOf(endP)] or {} do
		if s ~= seg and usable(a, s) and not (a.car and s.oneWay and not startsAt(s, endP)) then
			table.insert(choices, s)
		end
	end
	if #choices == 0 then
		if a.car and seg.oneWay then spawnNear(a) else a.dir = -a.dir end
		return
	end
	local nextSeg = choices[_rng:NextInteger(1, #choices)]
	local fromStart = startsAt(nextSeg, endP)
	place(a, nextSeg, if fromStart then 0 else 1, if fromStart then 1 else -1, a.off * a.dir)
end

local function strip(model: Model)
	for _, inst in model:GetDescendants() do
		for _, tag in CollectionService:GetTags(inst) do CollectionService:RemoveTag(inst, tag) end
		if inst:IsA("BasePart") then
			inst.LocalTransparencyModifier = 0
			inst.CanQuery = false
			inst.CanTouch = false
		elseif inst:IsA("LuaSourceContainer") then
			inst:Destroy()
		end
	end
	for _, tag in CollectionService:GetTags(model) do CollectionService:RemoveTag(model, tag) end
	for name in model:GetAttributes() do model:SetAttribute(name, nil) end
end

local function newCar(): Model
	local template = _templates[_rng:NextInteger(1, math.max(1, #_templates))]
	if template then return template:Clone() end
	local model = Instance.new("Model")
	local body = Instance.new("Part")
	body.Size = FALLBACK_CAR
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.Color = Color3.fromHSV(_rng:NextNumber(), 0.5, 0.8)
	body.PivotOffset = CFrame.new(0, -FALLBACK_CAR.Y / 2, 0)
	body.Parent = model
	model.PrimaryPart = body
	return model
end

local function newAgent(car: boolean): Agent?
	local model = if car then newCar()
		else CitizenModel.build({ gender = if _rng:NextNumber() < 0.5 then "F" else "M", kind = "Adult",
			seed = _rng:NextInteger(1, 2 ^ 30) })
	if not car then strip(model) end
	local root = model.PrimaryPart
	if not root then model:Destroy() return nil end
	return { model = model, root = root, car = car, seg = nil, t = 0, dir = 1, side = 1, off = 0,
		speed = (if car then CAR_SPEED else WALK_SPEED) * _rng:NextNumber(0.8, 1.15), dy = 0 }
end

-- A few real car models, copied before the real fleet leaves this client's world.
local function harvest(folder: Instance)
	for _, m in folder:GetChildren() do
		if #_templates >= TEMPLATE_MAX then return end
		if m:IsA("Model") and (m :: Model).PrimaryPart and #m:GetChildren() > 1 then
			local copy = (m :: Model):Clone()
			strip(copy)
			table.insert(_templates, copy)
		end
	end
end

local function detach(child: Instance)
	if not REAL_FOLDERS[child.Name] then return end
	if child.Name == "NPCDrivers" or child.Name == "Citizens" then harvest(child) end
	table.insert(_detached, child)
	child.Parent = nil
end

local function refresh()
	local focus = groundFocus()
	if not focus then return end
	table.clear(_near)
	for _, seg in _segs do
		local mid = (seg.p0 + seg.p3) * 0.5
		if (mid - focus).Magnitude <= SPAWN_RADIUS then table.insert(_near, seg) end
	end
	local want = if Settings.get("graphicsPreset") == "Low" then POOL_LOW else POOL
	local cars, people = 0, 0
	for i = #_agents, 1, -1 do
		local a = _agents[i]
		local n = if a.car then cars else people
		if n >= want then
			a.model:Destroy()
			table.remove(_agents, i)
			continue
		end
		if a.car then cars += 1 else people += 1 end
		local s = a.seg
		if not s or not _segs[s.id] or (a.root.Position - focus).Magnitude > RECYCLE_RADIUS then spawnNear(a) end
	end
	for _ = cars + 1, want do
		local a = newAgent(true)
		if a then table.insert(_agents, a); spawnNear(a) end
	end
	for _ = people + 1, want do
		local a = newAgent(false)
		if a then table.insert(_agents, a); spawnNear(a) end
	end
end

local function step(dt: number)
	for _, a in _agents do
		local seg = a.seg
		if not seg then continue end
		a.t += a.dir * a.speed * dt / seg.len
		if a.t > 1 or a.t < 0 then
			a.t = math.clamp(a.t, 0, 1)
			hop(a)
			if not a.seg then continue end
		end
		local pos, fwd = poseOf(a)
		a.root.CFrame = CFrame.lookAt(pos, pos + fwd)
	end
end

-- The road index is only read while this view is on (full city sim OFF). Rebuilding it on every
-- road edit for the players who never use it -- every segment's lanes and length, the whole city
-- -- was a per-edit cost paid for nothing; it is now built when the view turns on, and kept
-- current only while it is on.
local _indexStale = true

local function turnOff()
	if _off then return end
	_off = true
	if _indexStale then
		_indexStale = false
		indexSegments(DataCache.GetSegments())
	end
	local folder = Instance.new("Folder")
	folder.Name = "AmbientCity"
	folder.Parent = Workspace
	_folder = folder
	local city = Workspace:FindFirstChild("_City")
	local function watch(c: Instance)
		for _, child in c:GetChildren() do detach(child) end
		_cityConn = c.ChildAdded:Connect(detach)
	end
	if city then
		watch(city)
	else
		_cityConn = Workspace.ChildAdded:Connect(function(c)
			if c.Name ~= "_City" then return end
			if _cityConn then _cityConn:Disconnect() end
			watch(c)
		end)
	end
	_refreshIn = 0
	table.insert(_conns, RunService.Heartbeat:Connect(function(dt: number)
		_refreshIn -= dt
		if _refreshIn <= 0 then
			_refreshIn = REFRESH
			local ok, err = pcall(refresh)
			if not ok then warn("[AmbientCityView] refresh failed: " .. tostring(err)) end
		end
		_accum += dt
		if _accum < TICK then return end
		local elapsed = math.min(_accum, 0.25) * GameSpeed.get()
		_accum = 0
		if elapsed <= 0 then return end
		local ok, err = pcall(step, elapsed)
		if not ok then warn("[AmbientCityView] step failed: " .. tostring(err)) end
	end))
end

local function turnOn()
	if not _off then return end
	_off = false
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	if _cityConn then _cityConn:Disconnect(); _cityConn = nil end
	local city = Workspace:FindFirstChild("_City")
	for _, f in _detached do
		if city then f.Parent = city else f:Destroy() end
	end
	table.clear(_detached)
	for _, a in _agents do a.model:Destroy() end
	table.clear(_agents)
	for _, m in _templates do m:Destroy() end
	table.clear(_templates)
	if _folder then _folder:Destroy(); _folder = nil end
end

local function apply(v: any)
	if v == false then turnOff() else turnOn() end
end

function AmbientCityView.Start()
	DataCache.On("segments", function(list: { any })
		if _off then indexSegments(list) else _indexStale = true end
	end)
	Settings.onChanged("fullCitySim", apply)
	apply(Settings.get("fullCitySim"))
end

return AmbientCityView
