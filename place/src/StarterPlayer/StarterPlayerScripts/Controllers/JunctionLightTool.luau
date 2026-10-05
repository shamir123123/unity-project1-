--!strict
-- JunctionLightTool -- the Roads panel's Traffic Light card. While it is armed, the junction
-- under the cursor is ringed on the ground (green: a click puts lights up, red: a click takes
-- them down) and a click sends that ground point to the server, which flips the junction and
-- saves the choice with the city (SignalReplicationService.onToggleLights).
--
-- Main Road mode (the Main Road card): at a junction without lights, the road under the cursor
-- and the road carrying on across from it light up; a click makes that the main road -- it
-- goes first and every other arm gives way (SignalReplicationService.onSetMainRoad).
--
-- Client-only and decides nothing: which junction a click means, and what it does, is the
-- server's answer. The ring only mirrors the signalised list the signal editor already reads.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DataCache = require(ReplicatedStorage.DataCache)
local CursorRay = require(script.Parent.Parent.Core.CursorRay)

local JunctionLightTool = {}

local PICK_RADIUS = 40        -- studs; matches the server's TOGGLE_PICK_RADIUS
local RING_RADIUS = 22
local LIT_REFRESH = 2         -- s between refreshes of which junctions have lights
local AFTER_CLICK_REFRESH = 0.6
local COL_ADD = Color3.fromRGB(90, 220, 120)
local COL_REMOVE = Color3.fromRGB(235, 80, 70)
local MAIN_ROAD_DOT = -0.5    -- matches RoadRules: arms this close to opposite are one road
local BAR_LENGTH = 26
local BAR_WIDTH = 5

type Mode = "lights" | "mainRoad"

local _enabled = false
local _conns: { RBXScriptConnection } = {}
local _ring: Part? = nil
local _hover: Vector3? = nil
local _lit: { Vector3 } = {}
local _nextRefresh = 0
local _net: any = nil
local _mode: Mode = "lights"
local _bars: { Part } = {}
local _armsAt: Vector3? = nil
local _arms: { Vector3 } = {}

local function net(): any
	if not _net then _net = require(ReplicatedStorage:WaitForChild("Networker")) end
	return _net
end

local function refreshLit()
	task.spawn(function()
		local ok, reply = pcall(function()
			return net().RequestSignalData:InvokeServer({ nodes = true })
		end)
		if not ok or typeof(reply) ~= "table" or typeof(reply.nodes) ~= "table" then return end
		local lit: { Vector3 } = {}
		for _, n in reply.nodes do
			if typeof(n.x) == "number" and typeof(n.z) == "number" then
				table.insert(lit, Vector3.new(n.x, n.y or 0, n.z))
			end
		end
		_lit = lit
		_armsAt = nil -- roads may have changed too
	end)
end

local function isLit(pos: Vector3): boolean
	for _, p in _lit do
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		if dx * dx + dz * dz < 4 then return true end
	end
	return false
end

local function nearestJunction(at: Vector3): Vector3?
	local best: Vector3? = nil
	local bestSq = PICK_RADIUS * PICK_RADIUS
	for _, p in DataCache.GetIntersections() do
		local dx, dz = p.X - at.X, p.Z - at.Z
		local d2 = dx * dx + dz * dz
		if d2 < bestSq then
			bestSq = d2
			best = p
		end
	end
	return best
end

local function ring(): Part
	local r = _ring
	if r and r.Parent then return r end
	local p = Instance.new("Part")
	p.Name = "JunctionLightRing"
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.3, RING_RADIUS * 2, RING_RADIUS * 2)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Transparency = 0.55
	p.Parent = Workspace.CurrentCamera
	_ring = p
	return p
end

-- Directions the roads leave a junction in, from the replicated segments. Walked once per
-- hovered junction, never per frame.
local function armsAt(junction: Vector3): { Vector3 }
	if _armsAt == junction then return _arms end
	local arms: { Vector3 } = {}
	for _, seg in DataCache.GetSegments() do
		if typeof(seg.p0) ~= "Vector3" then continue end
		local raw: Vector3? = nil
		local d0 = Vector3.new(seg.p0.X - junction.X, 0, seg.p0.Z - junction.Z)
		local d3 = Vector3.new(seg.p3.X - junction.X, 0, seg.p3.Z - junction.Z)
		if d0.Magnitude < 1 then
			raw = if (seg.p1 - seg.p0).Magnitude > 1e-3 then seg.p1 - seg.p0 else seg.p3 - seg.p0
		elseif d3.Magnitude < 1 then
			raw = if (seg.p2 - seg.p3).Magnitude > 1e-3 then seg.p2 - seg.p3 else seg.p0 - seg.p3
		end
		local flat = if raw then Vector3.new(raw.X, 0, raw.Z) else Vector3.zero
		if flat.Magnitude > 1e-3 then table.insert(arms, flat.Unit) end
	end
	_armsAt, _arms = junction, arms
	return arms
end

local function bar(i: number): Part
	local b = _bars[i]
	if b and b.Parent then return b end
	local p = Instance.new("Part")
	p.Name = "MainRoadBar"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = COL_ADD
	p.Transparency = 1
	p.Parent = Workspace.CurrentCamera
	_bars[i] = p
	return p
end

local function hideBars()
	for _, b in _bars do b.Transparency = 1 end
end

local function placeBar(i: number, junction: Vector3, dir: Vector3)
	local b = bar(i)
	local lift = Vector3.new(0, 0.6, 0)
	b.Size = Vector3.new(BAR_WIDTH, 0.3, BAR_LENGTH)
	b.CFrame = CFrame.lookAt(junction + dir * (BAR_LENGTH * 0.5) + lift, junction + dir * BAR_LENGTH + lift)
	b.Transparency = 0.35
end

-- The road the cursor points along from the junction, and the one carrying on across from it.
local function stepMainRoad(ground: Vector3?, junction: Vector3?)
	_hover = nil
	if not ground or not junction or isLit(junction) then hideBars() return end
	local arms = armsAt(junction)
	local to = Vector3.new(ground.X - junction.X, 0, ground.Z - junction.Z)
	if #arms < 3 or to.Magnitude < 1e-3 then hideBars() return end
	to = to.Unit
	local pick, best = 1, -math.huge
	for i, d in arms do
		if d:Dot(to) > best then pick, best = i, d:Dot(to) end
	end
	local partner: number? = nil
	local pbest = MAIN_ROAD_DOT
	for j, d in arms do
		if j ~= pick and d:Dot(arms[pick]) < pbest then partner, pbest = j, d:Dot(arms[pick]) end
	end
	placeBar(1, junction, arms[pick])
	if partner then placeBar(2, junction, arms[partner]) else bar(2).Transparency = 1 end
	_hover = ground
end

local function step()
	local now = os.clock()
	if now >= _nextRefresh then
		_nextRefresh = now + LIT_REFRESH
		refreshLit()
	end
	local ground = CursorRay.ground()
	local junction = if ground then nearestJunction(ground) else nil
	if _mode == "mainRoad" then
		stepMainRoad(ground, junction)
		return
	end
	_hover = junction
	local r = ring()
	if not junction then
		r.Transparency = 1
		return
	end
	r.Transparency = 0.55
	r.Color = if isLit(junction) then COL_REMOVE else COL_ADD
	-- A cylinder's axis is its X: stand it on end so it lies flat on the junction.
	r.CFrame = CFrame.new(junction + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

local function onInput(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not _enabled then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local target = _hover
	if not target then return end
	if _mode == "mainRoad" then
		net().RequestSetMainRoad:FireServer(target)
	else
		net().RequestToggleJunctionLights:FireServer(target)
	end
	-- Show the result as soon as the server has had a moment to rebuild the junction.
	_nextRefresh = os.clock() + AFTER_CLICK_REFRESH
end

-- mode: "lights" (the Traffic Light card, the default) or "mainRoad" (the Main Road card).
function JunctionLightTool.setEnabled(on: boolean, mode: Mode?)
	local m: Mode = mode or "lights"
	if on == _enabled and (not on or m == _mode) then return end
	_enabled = on
	_mode = m
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	_hover = nil
	local r = _ring
	if r then
		r:Destroy()
		_ring = nil
	end
	for _, b in _bars do b:Destroy() end
	table.clear(_bars)
	if on then
		_nextRefresh = 0
		table.insert(_conns, RunService.RenderStepped:Connect(step))
		table.insert(_conns, UserInputService.InputBegan:Connect(onInput))
	end
end

function JunctionLightTool.isEnabled(): boolean
	return _enabled
end

return JunctionLightTool
