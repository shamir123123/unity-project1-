--!strict
-- CinematicCamera -- CS2-style keyframed camera for trailers and showcase shots.
--
-- A SHOT is a flight through keyframes. Each key is an eye point `p`, a look-at point `l` and a
-- field of view. Eye and look-at each follow a centripetal Catmull-Rom spline (no overshoot
-- loops on uneven key spacing), and the shot is flown at CONSTANT SPEED along the eye path via
-- an arc-length table (CameraSpline) -- trailer shots are cut mid-motion, so most are linear; `ease` is for the
-- hero moves that start or land on screen.
--
-- A REEL plays shots back to back with a black SLATE between them. The slate covers the sky's
-- 4 s fade when a shot pins a new time of day, lets the ground LOD settle at the first pose
-- (the camera is already parked there behind the black), and gives the editor a clean cut to
-- find every shot in one OBS recording.
--
-- While anything plays: every ScreenGui, the core GUI, the cursor and the painted street names are
-- hidden, FreeCamController is suspended and AssetLODView's ladder is off, so every building,
-- tree and car shows its full model at any distance. A reel waits on the black for the content
-- that reveals to finish loading before the first shot. Stop restores all of it, wherever it is
-- called from.
--
-- Staff-only: ships in the StaffTools bundle (StaffBoot starts it). Home plays the reel in
-- TrailerShots (Home again or Esc stops). An authoring session drives it through the bundle
-- folder's `CineCmd` attribute, a JSON command:
--   {"cmd":"play","shots":[...]}   play these shots (omit shots = the TrailerShots reel)
--   {"cmd":"pose","shot":{...},"t":0.5}   hold the frame at fraction t of a shot (UI hidden)
--   {"cmd":"stop"}
--   {"cmd":"spot","i":1}   glide the player's own camera to build spot i (HUD stays on): the
--                          gameplay shots, where the player draws a road and zones it on camera
-- Shot JSON: {"name","dur","ease"?,"clock"?,"speed"?,"dof"?,"slate"?,"haze"?:[density,haze],
--             "follow"?:{"tag"|"folder","near":[x,y,z]},"cars"?:n,"carRadius"?:studs,
--             "keys":[{"p":[x,y,z],"l":[x,y,z],"fov"?}]}
-- A FOLLOW shot's keys are in the frame of the model nearest `near` (tagged `tag`, or a child of
-- workspace._City[folder]), re-read every frame -- a camera riding a turbine rotor or a bus.
-- `cars` spawns that many routed cars (the admin Spawn-near tool) round the first look-at point
-- behind the slate, so a street shot has traffic in it.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui       = game:GetService("StarterGui")
local Lighting         = game:GetService("Lighting")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ContentProvider  = game:GetService("ContentProvider")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
-- Resolved by NAME: this bundle is delivered into PlayerGui at runtime (see StaffBoot).
local PlayerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local FreeCamController = require(PlayerScripts:WaitForChild("Core"):WaitForChild("FreeCamController"))
local worldFolder = PlayerScripts:WaitForChild("World", 10)
local lodModule = worldFolder and worldFolder:WaitForChild("AssetLODView", 10)
local AssetLODView = if lodModule then require(lodModule) :: any else nil
local CameraSpline = require(script.Parent:WaitForChild("CameraSpline"))

local CinematicCamera = {}

type Key = CameraSpline.Key
export type Shot = {
	name: string,
	dur: number,
	ease: string?,   -- "linear" (default) | "in" | "out" | "inOut"
	clock: number?,  -- hour to pin before the shot (admin time; the slate covers the fade)
	speed: number?,  -- GameSpeed during the shot (0-3); the reel restores the original
	dof: boolean?,   -- focus on the look-at point
	slate: number?,  -- seconds of black before the shot
	haze: { number }?, -- Atmosphere {Density, Haze} for the shot (hides the map edge in wide shots)
	follow: { tag: string?, folder: string?, near: Vector3 }?,
	cars: number?,
	carRadius: number?,
	keys: { Key },
}
type Spot = { name: string, p: Vector3, l: Vector3, cars: number? }
type Track = { shot: Shot, path: CameraSpline.Track, anchor: Model? }

local DEFAULT_FOV = 50
local DEFAULT_SLATE = 1.0
local CLOCK_FADE_SLATE = 6 -- SkyLightingView fades a >= 0.25 h jump over 4 s; the haze colour lags it
local LEAD_IN = 2.0          -- black before the first shot, so OBS has a clean head
local TAIL = 1.5
local ADMIN_GAP = 0.45       -- AdminService rate-limits its tools to one per 0.4 s
local DEFAULT_SPEED = 1      -- traffic moves in every shot unless one says otherwise
local REEL_SEASON = "Summer" -- the only season the trailer shows (the others are unfinished)
local DETAIL_WAIT = 30       -- longest the reel waits for revealed content before it starts anyway
local CAR_RADIUS = 260       -- the admin tool's default spawn radius
local SPOT_GLIDE = 2.5       -- seconds to fly to a build spot

local _bundle: Instance? = nil
local _overlay: ScreenGui? = nil
local _black: Frame? = nil
local _renderBound = false
local _track: Track? = nil
local _elapsed = 0
local _holdT: number? = nil -- pose mode: frozen fraction
local _token = 0
local _active = false
local _hidden: { ScreenGui } = {}
local _coreSaved: { [Enum.CoreGuiType]: boolean } = {}
local _dofSaved: { [string]: any }? = nil
local _speedSaved: number? = nil
local _lastAdminAt = 0
local _fovSaved = 70
local _hazeSaved: { number }? = nil
local _namesHidden: { LayerCollector } = {}
local _status: TextLabel? = nil
local _conns: { RBXScriptConnection } = {}

-- ------------------------------------------------------------- JSON input --

local function vec(v: any): Vector3?
	if typeof(v) ~= "table" then return nil end
	local x, y, z = tonumber(v[1]), tonumber(v[2]), tonumber(v[3])
	if not x or not y or not z then return nil end
	return Vector3.new(x, y, z)
end

local function parseShot(raw: any): Shot?
	if typeof(raw) ~= "table" or typeof(raw.keys) ~= "table" or #raw.keys == 0 then return nil end
	local keys: { Key } = {}
	for _, k in raw.keys do
		local p, l = vec(k.p), vec(k.l)
		if not p or not l then return nil end
		table.insert(keys, { p = p, l = l, fov = math.clamp(tonumber(k.fov) or DEFAULT_FOV, 5, 110) })
	end
	local follow = nil
	if typeof(raw.follow) == "table" then
		local near = vec(raw.follow.near)
		if not near then return nil end
		follow = {
			tag = if typeof(raw.follow.tag) == "string" then raw.follow.tag else nil,
			folder = if typeof(raw.follow.folder) == "string" then raw.follow.folder else nil,
			near = near,
		}
	end
	local haze = nil
	if typeof(raw.haze) == "table" and tonumber(raw.haze[1]) and tonumber(raw.haze[2]) then
		haze = { math.clamp(tonumber(raw.haze[1]) :: number, 0, 1), math.clamp(tonumber(raw.haze[2]) :: number, 0, 10) }
	end
	return {
		name = tostring(raw.name or "shot"),
		dur = math.clamp(tonumber(raw.dur) or 4, 0.1, 120),
		ease = if typeof(raw.ease) == "string" then raw.ease else nil,
		clock = tonumber(raw.clock),
		speed = tonumber(raw.speed),
		dof = raw.dof == true,
		slate = tonumber(raw.slate),
		haze = haze,
		follow = follow,
		cars = tonumber(raw.cars),
		carRadius = tonumber(raw.carRadius),
		keys = keys,
	}
end

-- TrailerShots holds { reel = { shot... }, spots = { {name, p, l, cars?}... } } in the same JSON
-- shape (a Lua table literal).
local function trailerData(): { [string]: any }
	local bundle = _bundle
	local mod = bundle and bundle:FindFirstChild("TrailerShots")
	if not mod or not mod:IsA("ModuleScript") then return {} end
	local ok, data = pcall(require, mod)
	if not ok or typeof(data) ~= "table" then
		warn("[CinematicCamera] TrailerShots failed to load: " .. tostring(data))
		return {}
	end
	return data
end

local function reelShots(): { Shot }
	local shots: { Shot } = {}
	local list = trailerData().reel
	if typeof(list) ~= "table" then return shots end
	for _, raw in list do
		local shot = parseShot(raw)
		if shot then table.insert(shots, shot) end
	end
	return shots
end

local function buildSpot(i: number): Spot?
	local list = trailerData().spots
	local raw = if typeof(list) == "table" then list[i] else nil
	if typeof(raw) ~= "table" then return nil end
	local p, l = vec(raw.p), vec(raw.l)
	if not p or not l then return nil end
	return { name = tostring(raw.name or ("spot " .. i)), p = p, l = l, cars = tonumber(raw.cars) }
end

-- ---------------------------------------------------------- stage control --

local function ensureOverlay(): Frame
	if _black and _overlay and _overlay.Parent then return _black end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CinematicOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1e6
	gui.Enabled = false
	local black = Instance.new("Frame")
	black.Name = "Slate"
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BorderSizePixel = 0
	black.Parent = gui
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Size = UDim2.fromScale(1, 1)
	status.Font = Enum.Font.GothamMedium
	status.TextSize = 18
	status.TextColor3 = Color3.fromRGB(150, 150, 150)
	status.Text = ""
	status.Parent = black
	_status = status
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	_overlay = gui
	_black = black
	return black
end

local function setBlack(on: boolean)
	ensureOverlay().Visible = on
end

local function setStatus(text: string)
	ensureOverlay()
	if _status then _status.Text = text end
end

-- World UI reads as UI in a trailer: painted street names and every BillboardGui icon (traffic
-- jams, no power, transit, building info). Their views own them, so only Enabled flips, and icons
-- that appear mid-reel are caught as they arrive.
local _iconConns: { RBXScriptConnection } = {}

local function hideIcon(d: Instance)
	if (d:IsA("BillboardGui") or (d:IsA("SurfaceGui") and d:FindFirstAncestor("_StreetNames"))) and d.Enabled then
		d.Enabled = false
		table.insert(_namesHidden, d :: any)
	end
end

local function hideStreetNames()
	for _, root in { Workspace, Players.LocalPlayer.PlayerGui } do
		for _, d in root:GetDescendants() do hideIcon(d) end
		table.insert(_iconConns, root.DescendantAdded:Connect(function(d)
			task.defer(hideIcon, d) -- after its creator finishes setting it up
		end))
	end
end

local function showStreetNames()
	for _, c in _iconConns do c:Disconnect() end
	table.clear(_iconConns)
	for _, g in _namesHidden do
		if g.Parent then g.Enabled = true end
	end
	table.clear(_namesHidden)
end

local function atmosphere(): Atmosphere?
	return Lighting:FindFirstChildOfClass("Atmosphere")
end

local function applyHaze(haze: { number }?)
	local a = atmosphere()
	if not a then return end
	if not _hazeSaved then _hazeSaved = { a.Density, a.Haze } end
	local h = haze or _hazeSaved :: { number }
	a.Density, a.Haze = h[1], h[2]
end

local function returnHaze()
	local saved, a = _hazeSaved, atmosphere()
	_hazeSaved = nil
	if saved and a then a.Density, a.Haze = saved[1], saved[2] end
end

-- The model a follow shot rides: the nearest live one to `near`, picked once per shot.
local function findAnchor(shot: Shot): Model?
	local f = shot.follow
	if not f then return nil end
	local pool: { Instance } = {}
	if f.tag then
		pool = CollectionService:GetTagged(f.tag)
	elseif f.folder then
		local city = Workspace:FindFirstChild("_City")
		local folder = city and city:FindFirstChild(f.folder)
		pool = if folder then folder:GetChildren() else {}
	end
	local best: Model?, bestD = nil, math.huge
	for _, m in pool do
		if m:IsA("Model") and m:IsDescendantOf(Workspace) then
			local d = (m:GetPivot().Position - f.near).Magnitude
			if d < bestD then best, bestD = m, d end
		end
	end
	if not best then warn("[CinematicCamera] no follow target for " .. shot.name) end
	return best
end

local function newTrack(shot: Shot): Track
	return { shot = shot, path = CameraSpline.build(shot.keys, shot.ease), anchor = findAnchor(shot) }
end

local function hideInterface()
	local overlay = _overlay
	for _, g in Players.LocalPlayer.PlayerGui:GetChildren() do
		if g:IsA("ScreenGui") and g.Enabled and g ~= overlay then
			g.Enabled = false
			table.insert(_hidden, g)
		end
	end
	for _, t in Enum.CoreGuiType:GetEnumItems() do
		if t ~= Enum.CoreGuiType.All then
			_coreSaved[t] = StarterGui:GetCoreGuiEnabled(t)
		end
	end
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)
	UserInputService.MouseIconEnabled = false
end

local function showInterface()
	for _, g in _hidden do
		if g.Parent then g.Enabled = true end
	end
	table.clear(_hidden)
	for t, on in _coreSaved do
		StarterGui:SetCoreGuiEnabled(t, on)
	end
	table.clear(_coreSaved)
	pcall(function() StarterGui:SetCore("TopbarEnabled", true) end)
	UserInputService.MouseIconEnabled = true
end

-- Only one DepthOfFieldEffect renders (the engine picks), so the city's own one is borrowed and
-- every other is switched off for the duration.
local function dofEffect(): DepthOfFieldEffect?
	return Lighting:FindFirstChild("CityBuild_DistantDepth") :: DepthOfFieldEffect?
end

local function borrowDof()
	if _dofSaved then return end
	local saved: { [string]: any } = { others = {} }
	for _, e in Lighting:GetChildren() do
		if e:IsA("DepthOfFieldEffect") then
			saved.others[e] = e.Enabled
			e.Enabled = false
		end
	end
	local d = dofEffect()
	if d then
		saved.FocusDistance = d.FocusDistance
		saved.InFocusRadius = d.InFocusRadius
		saved.FarIntensity = d.FarIntensity
		saved.NearIntensity = d.NearIntensity
	end
	_dofSaved = saved
end

local function returnDof()
	local saved = _dofSaved
	if not saved then return end
	_dofSaved = nil
	local d = dofEffect()
	if d then
		d.FocusDistance = saved.FocusDistance
		d.InFocusRadius = saved.InFocusRadius
		d.FarIntensity = saved.FarIntensity
		d.NearIntensity = saved.NearIntensity
	end
	for e, on in saved.others do
		if e.Parent then e.Enabled = on end
	end
end

-- Focus rides the look-at point, so a shot stays sharp on its subject while it moves.
local function applyDof(on: boolean, focus: number)
	local d = dofEffect()
	if not d then return end
	if not on then
		d.Enabled = false
		return
	end
	d.Enabled = true
	d.FocusDistance = focus
	d.InFocusRadius = focus * 0.35
	d.FarIntensity = 0.35
	d.NearIntensity = 0.6
end

-- One retry: another tool (or the admin panel) may have used the shared rate-limit window just
-- before. Every admin remote shares that window, so they all go through here.
local function adminInvoke(remote: RemoteFunction, payload: any)
	local ok, res
	for _ = 1, 2 do
		local wait = ADMIN_GAP - (os.clock() - _lastAdminAt)
		if wait > 0 then task.wait(wait) end
		_lastAdminAt = os.clock()
		ok, res = pcall(function()
			return remote:InvokeServer(payload)
		end)
		if ok and not (typeof(res) == "table" and res.ok == false) then return end
	end
	warn("[CinematicCamera] admin action failed: " .. tostring(if ok and typeof(res) == "table" then res.error else res))
end

local function adminCall(payload: any)
	adminInvoke(Net.RequestAdminCityAction, payload)
end

local function spawnCars(near: Vector3, count: number, radius: number?)
	adminInvoke(Net.RequestAdminSpawnTraffic, {
		count = math.clamp(math.floor(count), 1, 80),
		near = near,
		radius = radius or CAR_RADIUS,
	})
end

-- Returns how long the slate must hold for this shot's setup to settle.
local function setupShot(shot: Shot): number
	local slate = shot.slate or DEFAULT_SLATE
	if shot.clock then
		local jump = math.abs(Lighting.ClockTime - shot.clock)
		adminCall({ action = "setTimeOfDay", hour = shot.clock })
		if math.min(jump, 24 - jump) >= 0.25 then slate = math.max(slate, CLOCK_FADE_SLATE) end
	end
	if Workspace:GetAttribute("Weather") ~= "Clear" then
		adminCall({ action = "setWeather", weather = "Clear" })
	end
	if Workspace:GetAttribute("Season") ~= REEL_SEASON then
		adminCall({ action = "setSeason", season = REEL_SEASON })
	end
	if _speedSaved == nil then
		_speedSaved = tonumber(Workspace:GetAttribute("GameSpeed")) or 1
	end
	Net.RequestGameSpeed:FireServer(math.clamp(shot.speed or DEFAULT_SPEED, 0, 3))
	applyHaze(shot.haze)
	if shot.cars and not shot.follow then
		spawnCars(shot.keys[1].l, shot.cars, shot.carRadius)
	end
	return slate
end

local function onRender(dt: number)
	local track = _track
	if not track then return end
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local u: number
	if _holdT then
		u = _holdT
	else
		_elapsed += dt
		u = math.clamp(_elapsed / track.shot.dur, 0, 1)
	end
	local cf, fov, focus = CameraSpline.sample(track.path, u)
	local anchor = track.anchor
	if anchor and anchor.Parent then
		cf = anchor:GetPivot() * cf
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cf
	cam.FieldOfView = fov
	applyDof(track.shot.dof == true, focus)
end

local function begin()
	if _active then return end
	_active = true
	ensureOverlay()
	if _overlay then _overlay.Enabled = true end
	hideInterface()
	borrowDof()
	local cam = Workspace.CurrentCamera
	if cam then _fovSaved = cam.FieldOfView end
	FreeCamController.setSuspended(true)
	if AssetLODView then AssetLODView.setSuspended(true) end
	hideStreetNames()
	if not _renderBound then
		_renderBound = true
		RunService:BindToRenderStep("CinematicCamera", Enum.RenderPriority.Camera.Value + 10, onRender)
	end
end

function CinematicCamera.Stop()
	_token += 1
	_track = nil
	_holdT = nil
	if _renderBound then
		_renderBound = false
		RunService:UnbindFromRenderStep("CinematicCamera")
	end
	if not _active then return end
	_active = false
	local cam = Workspace.CurrentCamera
	if cam then cam.FieldOfView = _fovSaved end
	returnDof()
	returnHaze()
	showStreetNames()
	if AssetLODView then AssetLODView.setSuspended(false) end
	if _speedSaved ~= nil then
		Net.RequestGameSpeed:FireServer(_speedSaved)
		_speedSaved = nil
	end
	FreeCamController.setSuspended(false)
	-- Hand the free camera the pose we stopped at, so the player is not snapped back across
	-- the map to wherever they were before the reel.
	if cam then
		local look = cam.CFrame.LookVector
		FreeCamController.setCameraState({
			pos = cam.CFrame.Position,
			yaw = math.deg(math.atan2(-look.X, -look.Z)),
			pitch = math.deg(math.asin(math.clamp(look.Y, -1, 1))),
		})
	end
	showInterface()
	if _overlay then _overlay.Enabled = false end
	setBlack(false)
	setStatus("")
end

function CinematicCamera.IsPlaying(): boolean
	return _active
end

function CinematicCamera.Play(shots: { Shot })
	CinematicCamera.Stop()
	if #shots == 0 then
		warn("[CinematicCamera] no shots to play")
		return
	end
	_token += 1
	local token = _token
	begin()
	setBlack(true)
	task.spawn(function()
		local ok, err = pcall(function()
			-- The LOD ladder let go in begin(); what it was hiding now loads its meshes and
			-- textures. Wait on the black until that is done (bounded), so no shot pops in.
			setStatus("Loading full detail...")
			local deadline = os.clock() + DETAIL_WAIT
			task.wait(LEAD_IN)
			while ContentProvider.RequestQueueSize > 0 and os.clock() < deadline do
				if token ~= _token then return end
				task.wait(0.25)
			end
			setStatus("")
			for _, shot in shots do
				if token ~= _token then return end
				setBlack(true)
				local track = newTrack(shot)
				_holdT = 0
				_track = track -- park on the first frame behind the black so the ground settles there
				task.wait(setupShot(shot))
				if token ~= _token then return end
				_elapsed = 0
				_holdT = nil
				setBlack(false)
				task.wait(shot.dur)
			end
			if token ~= _token then return end
			setBlack(true)
			task.wait(TAIL)
		end)
		if not ok then warn("[CinematicCamera] reel failed: " .. tostring(err)) end
		if token == _token then CinematicCamera.Stop() end
	end)
end

-- Freeze one frame of a shot (for reviewing framing with a screenshot).
function CinematicCamera.Pose(shot: Shot, t: number)
	if not _active then begin() end
	_token += 1
	setBlack(false)
	_track = newTrack(shot)
	_holdT = math.clamp(t, 0, 1)
	applyHaze(shot.haze)
	if shot.clock and math.abs(Lighting.ClockTime - shot.clock) > 0.05 then
		task.spawn(adminCall, { action = "setTimeOfDay", hour = shot.clock })
	end
end

-- Gameplay shots: the player's own camera, HUD and tools stay live; only the pose is authored.
function CinematicCamera.GoToSpot(i: number)
	local spot = buildSpot(i)
	if not spot then
		warn("[CinematicCamera] no build spot " .. i)
		return
	end
	CinematicCamera.Stop()
	local look = (spot.l - spot.p).Unit
	FreeCamController.glideTo({
		pos = spot.p,
		yaw = math.deg(math.atan2(-look.X, -look.Z)),
		pitch = math.deg(math.asin(math.clamp(look.Y, -1, 1))),
	}, SPOT_GLIDE)
	if spot.cars then
		task.spawn(spawnCars, spot.l, spot.cars, nil)
	end
end

local function onCommand()
	local bundle = _bundle
	if not bundle then return end
	local raw = bundle:GetAttribute("CineCmd")
	if typeof(raw) ~= "string" or raw == "" then return end
	bundle:SetAttribute("CineCmd", nil)
	local ok, cmd = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(cmd) ~= "table" then
		warn("[CinematicCamera] bad CineCmd JSON")
		return
	end
	if cmd.cmd == "stop" then
		CinematicCamera.Stop()
	elseif cmd.cmd == "pose" then
		local shot = parseShot(cmd.shot)
		if shot then CinematicCamera.Pose(shot, tonumber(cmd.t) or 0) end
	elseif cmd.cmd == "play" then
		local shots: { Shot } = {}
		if typeof(cmd.shots) == "table" then
			for _, raw in cmd.shots do
				local shot = parseShot(raw)
				if shot then table.insert(shots, shot) end
			end
		else
			shots = reelShots()
		end
		CinematicCamera.Play(shots)
	elseif cmd.cmd == "spot" then
		CinematicCamera.GoToSpot(tonumber(cmd.i) or 1)
	end
end

function CinematicCamera.Start(bundle: Instance)
	_bundle = bundle
	table.insert(_conns, bundle:GetAttributeChangedSignal("CineCmd"):Connect(onCommand))
	-- `processed` ignored on purpose, like BadAppleShow: Escape is normally eaten by the
	-- Roblox menu, and it is the one key that must always give the camera back.
	table.insert(_conns, UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Escape then
			if _active then CinematicCamera.Stop() end
		elseif input.KeyCode == Enum.KeyCode.Home then
			if _active then CinematicCamera.Stop() else CinematicCamera.Play(reelShots()) end
		end
	end))
end

function CinematicCamera.Cleanup()
	CinematicCamera.Stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	if _overlay then _overlay:Destroy() end
	_overlay = nil
	_black = nil
end

return CinematicCamera
