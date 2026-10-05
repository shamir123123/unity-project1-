--!strict
-- Client terrain sculpting tool. Toggle with T. While enabled, hold LMB and drag
-- to apply the current brush. Keys: 1 Raise, 2 Lower, 3 Flatten, 4 Smooth, 5 Level,
-- 6 Paint; M cycles paint material; [ and ] change radius. Raycasts the cursor
-- against workspace.Terrain and sends throttled strokes to the server, which is
-- authoritative and renders the result back via Terrain replication (v1 has no
-- client voxel prediction). A neon ring previews the brush; a HUD shows tool state.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainBrush = require(ReplicatedStorage.Terrain.TerrainBrush)
local TerrainBuildController = require(ReplicatedStorage.Terrain.TerrainBuildController)
local TerrainMeshView = require(ReplicatedStorage.Terrain.TerrainMeshView)
local TerritoryGrid = require(ReplicatedStorage.City.TerritoryGrid)
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))

local TerrainEditController = {}

export type Op = "Raise" | "Lower" | "Flatten" | "Smooth" | "Level" | "SetMaterial"

-- Sculpt op per bind id. The keys themselves live in Settings (Input page).
local OP_ACTIONS: { { action: string, op: Op } } = {
	{ action = "TerrainRaise", op = "Raise" },
	{ action = "TerrainLower", op = "Lower" },
	{ action = "TerrainFlatten", op = "Flatten" },
	{ action = "TerrainSmooth", op = "Smooth" },
	{ action = "TerrainLevel", op = "Level" },
	{ action = "TerrainPaint", op = "SetMaterial" },
}

local OP_LABELS: { [string]: string } = {
	Raise = "Raise", Lower = "Lower", Flatten = "Flatten",
	Smooth = "Smooth", Level = "Level (pad)", SetMaterial = "Paint",
}

-- Materials the paint op cycles through (M key), with display names.
local MATERIALS = {
	{ id = Constants.Material.GRASS, name = "Grass" },
	{ id = Constants.Material.SAND, name = "Sand" },
	{ id = Constants.Material.ROCK, name = "Rock" },
	{ id = Constants.Material.SNOW, name = "Snow" },
	{ id = Constants.Material.GROUND, name = "Ground" },
	{ id = Constants.Material.MUD, name = "Mud" },
}

local RADIUS_STEP = 4
local MIN_RADIUS = Constants.SAMPLE_SPACING
local MAX_RADIUS = Constants.BRUSH_MAX_RADIUS

local _remote: RemoteEvent
local _territoryRemote: RemoteEvent
local _strokeListener: ((any, TerrainBrush.AllowedFn) -> ())? = nil
local _lastFire = 0
local _enabled = false
local _inited = false
local _bound = false
local _op: Op = "Raise"
local _radius = 20
local _strength = 1
local _isDown = false
local _rightDown = false
local _targetHeight: number? = nil -- worldY picked at gesture start, for Flatten/Level
local _materialIndex = 1
local _preview: CylinderHandleAdornment?
local _hudEnabled = true -- the themed Terrain panel sets this false and shows state itself
local _hud: ScreenGui?
local _hudLabel: TextLabel?
local _renderConn: RBXScriptConnection?
local _beganConn: RBXScriptConnection?
local _endedConn: RBXScriptConnection?
local _territoryConn: RBXScriptConnection?
-- Owned tiles, mirrored from SyncTerritory so the prediction clips exactly where the server
-- does. nil until the first snapshot: until then the prediction is unclipped and the server's
-- patch corrects it.
local _owned: { [number]: boolean }? = nil
local _sandbox = false

local function allowedCorner(x: number, z: number): boolean
	local owned = _owned
	return _sandbox or owned == nil or owned[TerritoryGrid.idAt(x, z)] == true
end

local function onTerritory(snap: any)
	if typeof(snap) ~= "table" or typeof(snap.owned) ~= "table" then return end
	local owned: { [number]: boolean } = {}
	for _, id in snap.owned do
		if TerritoryGrid.isValidId(id) then owned[tonumber(id) :: number] = true end
	end
	_owned = owned
	_sandbox = snap.sandbox == true
end

-- Terrain-only pick, from the one place that owns cursor picking.
local function groundPoint(): Vector3?
	return CursorRay.terrainPoint()
end

-- Brush preview: ONE hollow ring drawn on top. A flat Part disc sank into any slope (half
-- of it vanished under the ground) and showed as a solid blob, not a ring.
local RING_THICKNESS = 3  -- stud width of the ring band

local function ensurePreview(): CylinderHandleAdornment
	if _preview and _preview.Parent then return _preview end
	local a = Instance.new("CylinderHandleAdornment")
	a.Name = "TerrainBrushPreview"
	a.Adornee = Workspace.Terrain -- identity frame, so CFrame below is world space
	a.AlwaysOnTop = true
	a.ZIndex = 1
	a.Color3 = Color3.fromRGB(210, 170, 100)  -- warm sandy amber
	a.Transparency = 0.3
	a.Height = 0.4
	a.Parent = Workspace.Terrain
	_preview = a
	return a
end

local function updatePreview(point: Vector3?)
	if not point then
		if _preview then _preview:Destroy(); _preview = nil end
		return
	end
	local a = ensurePreview()
	a.Radius = _radius
	a.InnerRadius = math.max(0, _radius - RING_THICKNESS)
	-- The adornment's axis is Z; tip it flat.
	a.CFrame = CFrame.new(point) * CFrame.Angles(math.rad(90), 0, 0)
end

-- Which op this tick applies. The right button is the INVERSE of the left: with Raise
-- selected, right-drag lowers, and the other way round -- add with left, remove with right,
-- the way every sculpting tool anyone has already used behaves, so nobody has to go back to
-- the toolbar to take a bump down again. Only Raise and Lower swap; every other op leaves
-- the right button alone so it keeps driving the camera.
local function activeOp(): Op
	if _rightDown and _op == "Raise" then return "Lower" end
	if _rightDown and _op == "Lower" then return "Raise" end
	return _op
end

-- Does the right button sculpt right now, or belong to the camera?
local function rightSculpts(): boolean
	return _rightDown and (_op == "Raise" or _op == "Lower")
end

-- Right-drag is the DEFAULT camera's rotate, so sculpting with it has to take the button
-- away rather than merely listen for it -- bound above the camera and SINKING, or every
-- remove-terrain drag spins the view at the same time, which is exactly what it did.
-- Only Raise and Lower claim it; under any other op this passes the button straight back
-- to the camera, so right-drag still orbits everywhere it used to.
local SECONDARY_ACTION = "TerrainSculptSecondary"
local endGesture: () -> ()

local function onSecondary(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
	if _op ~= "Raise" and _op ~= "Lower" then
		_rightDown = false
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		_rightDown = true
		_lastFire = 0
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		_rightDown = false
		endGesture()
	end
	return Enum.ContextActionResult.Sink
end

-- One place both buttons finish through, so releasing one while the other is still held
-- does not end the stroke early.
function endGesture()
	if _isDown or _rightDown then return end
	_targetHeight = nil
	-- Hands the chunks back: strides re-decided from the new shape, and the live
	-- EditableMeshes the drag held on to baked back down to static content.
	TerrainMeshView.editEnd()
end

local function fireStroke(point: Vector3)
	-- Throttle locally so each accepted tick is both sent to the server and mirrored to
	-- the stroke listener (the water overlay) at the same cadence -- keeps the predicted
	-- coastline in step with the authoritative one.
	local now = os.clock()
	if now - _lastFire < Constants.BRUSH_RATE_INTERVAL then return end
	-- The brush moves ground per SECOND, so it needs this tick's own length. First tick of a
	-- gesture has no previous one to measure from, so it takes a nominal tick rather than
	-- however long the tool happened to be idle.
	local dt = if _lastFire > 0 then math.min(now - _lastFire, Constants.BRUSH_MAX_DT) else Constants.BRUSH_RATE_INTERVAL
	_lastFire = now
	local needsTarget = _op == "Flatten" or _op == "Level"
	local stroke = {
		op = activeOp(),
		dt = dt,
		centerX = point.X,
		centerZ = point.Z,
		radius = _radius,
		strength = _strength,
		target = if needsTarget then _targetHeight else nil,
		material = if _op == "SetMaterial" then MATERIALS[_materialIndex].id else nil,
	}
	_remote:FireServer(stroke)

	-- PREDICT IT LOCALLY, right now. The server is still authoritative -- its patch arrives
	-- a moment later and overwrites these same corners -- but waiting for it meant a round
	-- trip plus the 0.2 s patch flush before the ground moved, which is what made the brush
	-- feel detached from the cursor. This is safe precisely because TerrainBrush is pure and
	-- deterministic over the same heightmap: the server lands on the numbers already on
	-- screen, so reconciling is a no-op rather than a correction. The flags streamed with
	-- each chunk are what keep it that way near roads, where the server skips LOCKED corners.
	if Constants.MESH_GROUND then
		local hm = TerrainBuildController.getHeightmap()
		if hm then
			TerrainBrush.apply(hm, stroke, allowedCorner)
			local reach = stroke.radius + Constants.SAMPLE_SPACING
			TerrainMeshView.editArea(point.X - reach, point.Z - reach, point.X + reach, point.Z + reach)
		end
	end

	if _strokeListener then
		local ok, err = pcall(_strokeListener, stroke, allowedCorner)
		if not ok then warn("[TerrainEditController] stroke listener error:", err) end
	end
end

local function ensureHud()
	if _hud and _hud.Parent then return end
	local player = game:GetService("Players").LocalPlayer
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then return end
	local screen = Instance.new("ScreenGui")
	screen.Name = "TerrainToolHUD"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme")).Layer.Toast + 1
	-- Safe to scale: this controller's only cursor maths feeds a 3D ground raycast, not a
	-- GUI offset, so it is unaffected by the design-px/real-px split.
	require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("HudScale")).attach(screen)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -16)
	label.Size = UDim2.new(0, 560, 0, 30)
	label.BackgroundColor3 = Color3.fromRGB(20, 24, 28)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.fromRGB(235, 240, 235)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.Text = ""
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label
	label.Parent = screen
	screen.Parent = gui
	_hud = screen
	_hudLabel = label
end

local function updateHud()
	if not _enabled or not _hudEnabled then
		if _hud then _hud.Enabled = false end
		return
	end
	ensureHud()
	if not _hud or not _hudLabel then return end
	_hud.Enabled = true
	local matSuffix = if _op == "SetMaterial" then "  \u{00B7}  Material: " .. MATERIALS[_materialIndex].name else ""
	_hudLabel.Text = string.format(
		"TERRAIN  \u{00B7}  Op: %s%s  \u{00B7}  Radius: %d        [ T off \u{00B7} 1-6 op \u{00B7} M material \u{00B7} [ ] size ]",
		OP_LABELS[_op] or _op, matSuffix, _radius
	)
end

function TerrainEditController.setEnabled(enabled: boolean)
	_enabled = enabled
	if not enabled then
		_isDown = false
		_targetHeight = nil
		updatePreview(nil)
	end
	updateHud()
end

function TerrainEditController.isEnabled(): boolean
	return _enabled
end

function TerrainEditController.setOp(op: Op)
	_op = op
	updateHud()
end

function TerrainEditController.setRadius(radius: number)
	_radius = math.clamp(radius, MIN_RADIUS, MAX_RADIUS)
	updateHud()
end

function TerrainEditController.cycleMaterial()
	_materialIndex = (_materialIndex % #MATERIALS) + 1
	updateHud()
end

-- Read/drive accessors for the themed Terrain panel (TerrainPanelController).
function TerrainEditController.getOp(): Op return _op end
function TerrainEditController.getRadius(): number return _radius end
function TerrainEditController.getRadiusBounds(): (number, number) return MIN_RADIUS, MAX_RADIUS end
function TerrainEditController.getMaterialNames(): { string }
	local out: { string } = {}
	for _, m in MATERIALS do table.insert(out, m.name) end
	return out
end
function TerrainEditController.getMaterialIndex(): number return _materialIndex end
function TerrainEditController.setMaterialIndex(i: number)
	_materialIndex = math.clamp(math.floor(i), 1, #MATERIALS)
	updateHud()
end

-- Hide the legacy on-screen HUD (the panel drives the tool and shows its own state).
function TerrainEditController.setHudEnabled(on: boolean)
	_hudEnabled = on
	updateHud()
end

-- Register a listener invoked with each accepted (throttled) stroke and the territory clip
-- to apply it with. The water overlay uses this to mirror edits and repaint the coastline live.
function TerrainEditController.setStrokeListener(fn: ((any, TerrainBrush.AllowedFn) -> ())?)
	_strokeListener = fn
end

function TerrainEditController.Init()
	if _inited then return end
	_inited = true
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_remote = Net.RequestTerrainEdit
	_territoryRemote = Net.SyncTerritory
end

function TerrainEditController.Bind()
	if _bound then return end
	_bound = true

	_territoryConn = _territoryRemote.OnClientEvent:Connect(onTerritory)
	_renderConn = RunService.RenderStepped:Connect(function()
		if not _enabled then return end
		local point = groundPoint()
		updatePreview(point)
		if (_isDown or rightSculpts()) and point then
			fireStroke(point)
		end
	end)

	_beganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then return end

		-- Only without the panel: a key-toggled brush has no panel to close, so no other tool
		-- could put it away and it rode the cursor through every tool after.
		if _hudEnabled and Settings.pressed("TerrainToggle", input) then
			TerrainEditController.setEnabled(not _enabled)
			return
		end

		if not _enabled then return end

		for _, entry in OP_ACTIONS do
			if Settings.pressed(entry.action, input) then
				TerrainEditController.setOp(entry.op)
				return
			end
		end
		if Settings.pressed("TerrainMaterial", input) then
			TerrainEditController.cycleMaterial()
			return
		elseif Settings.pressed("BrushSmaller", input) then
			TerrainEditController.setRadius(_radius - RADIUS_STEP)
			return
		elseif Settings.pressed("BrushLarger", input) then
			TerrainEditController.setRadius(_radius + RADIUS_STEP)
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			_isDown = true
			-- A new gesture has no previous tick to measure against, so the next one takes a
			-- nominal dt instead of however long the tool sat idle.
			_lastFire = 0
			-- Flatten/Level: sample the height under the cursor now; the whole drag uses it.
			if _op == "Flatten" or _op == "Level" then
				local p = groundPoint()
				_targetHeight = if p then p.Y else nil
			end
		end
	end)

	ContextActionService:BindActionAtPriority(
		SECONDARY_ACTION, onSecondary, false,
		Enum.ContextActionPriority.High.Value,
		Enum.UserInputType.MouseButton2
	)

	_endedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		_isDown = false
		endGesture()
	end)
end

function TerrainEditController.Unbind()
	-- Putting the tool away mid-drag must still close the stroke, or its chunks keep their
	-- live EditableMeshes and their pinned-fine blocks for the rest of the session.
	_isDown = false
	_rightDown = false
	TerrainMeshView.editEnd()
	ContextActionService:UnbindAction(SECONDARY_ACTION)
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _beganConn then _beganConn:Disconnect(); _beganConn = nil end
	if _endedConn then _endedConn:Disconnect(); _endedConn = nil end
	if _territoryConn then _territoryConn:Disconnect(); _territoryConn = nil end
	updatePreview(nil)
	if _hud then _hud:Destroy(); _hud = nil; _hudLabel = nil end
	_bound = false
end

return TerrainEditController
