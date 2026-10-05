--!strict
-- CitizenAvatarView (client)
-- The near level of a citizen: a real Roblox R6 avatar in free catalog clothing (shirt,
-- pants and hair from CitizenWardrobe, baked into ReplicatedStorage.CitizenAvatars),
-- animated with Roblox's default R6 walk / idle. Every citizen body -- server walkers and
-- local presence people alike -- is CitizenModel's plain figure, already wearing the
-- outfit's colours; this view swaps the nearest ones for their avatar and back as they fall
-- away. An avatar is a local clone welded to the body's root, so whatever moves the body
-- (PedestrianView, CitizenPresenceView) moves the avatar too.
--
-- Near is the shared LOD pixel test: an avatar appears while a DETAIL_STUDS feature covers
-- a whole pixel and goes once it is under the pixel budget, so the swap lands where the
-- clothing detail is too small to see. One sweep every SWEEP_INTERVAL, never per frame;
-- at most SWAPS_PER_SWEEP new avatars a sweep and AVATAR_MAX in all. The Low graphics
-- preset keeps the avatars but stops animating them.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CitizenModel = require(ReplicatedStorage.City.CitizenModel)
local LOD = require(ReplicatedStorage.Shared.LOD)
local Settings = require(script.Parent.Parent.Core.Settings)

local CitizenAvatarView = {}

local SWEEP_INTERVAL = 0.4
local AVATAR_MAX = 60
local SWAPS_PER_SWEEP = 8
-- The finest clothing detail worth showing: stripes, logos, shoe soles.
local DETAIL_STUDS = 0.3
-- Bodies further behind the camera than this (cosine off the look vector) are not swapped.
local BEHIND_COS = -0.2
-- Roblox's own R6 animations (the stock Animate script's walk and idle).
local WALK_ANIM = "rbxassetid://180426354"
local IDLE_ANIM = "rbxassetid://180435571"
-- Speed (studs/s) the R6 walk cycle is authored for at full avatar size, and the playback
-- clamp: a citizen's 1.25 m/s stroll would otherwise read as slow motion.
local R6_WALK_SPEED = 14.5
local MIN_WALK_RATE = 0.55
local MAX_WALK_RATE = 1.6
local MOVING = 0.3 -- studs/s; slower than this is standing

type Avatar = {
	rig: Model,
	scale: number,
	walk: AnimationTrack,
	idle: AnimationTrack,
	lastPos: Vector3,
}
type Near = { body: Model, dist: number }

local _avatars: { [Model]: Avatar } = {}
local _conns: { RBXScriptConnection } = {}
local _animate = true
local _accum = 0
local _walkAnim: Animation? = nil
local _idleAnim: Animation? = nil

local function bodyHidden(body: Model, hidden: boolean)
	local t = if hidden then 1 else 0
	for _, child in body:GetChildren() do
		if child:IsA("BasePart") and child ~= body.PrimaryPart then
			child.Transparency = t
			local face = child:FindFirstChildOfClass("Decal")
			if face then face.Transparency = t end
		end
	end
end

local function setSkin(rig: Model, skin: Color3)
	local colors = rig:FindFirstChildOfClass("BodyColors")
	if not colors then return end
	colors.HeadColor3 = skin
	colors.TorsoColor3 = skin
	colors.LeftArmColor3 = skin
	colors.RightArmColor3 = skin
	colors.LeftLegColor3 = skin
	colors.RightLegColor3 = skin
end

-- The rig's own feet-to-head-top height and feet-to-root drop, at its stored size.
local function rigMeasure(rig: Model): (number, number)
	local hrp = rig.PrimaryPart :: BasePart
	local head = rig:FindFirstChild("Head") :: BasePart
	local leg = rig:FindFirstChild("Left Leg") :: BasePart
	local feetY = leg.Position.Y - leg.Size.Y / 2
	-- The Head mesh draws 1.25x the part's height, centred on it.
	return head.Position.Y + head.Size.Y * 0.625 - feetY, hrp.Position.Y - feetY
end

local function play(a: Avatar, moving: boolean, speed: number)
	if not _animate then return end
	if moving then
		if not a.walk.IsPlaying then a.walk:Play(0.2) end
		if a.idle.IsPlaying then a.idle:Stop(0.2) end
		a.walk:AdjustSpeed(math.clamp(speed / (R6_WALK_SPEED * a.scale), MIN_WALK_RATE, MAX_WALK_RATE))
	else
		if a.walk.IsPlaying then a.walk:Stop(0.2) end
		if not a.idle.IsPlaying then a.idle:Play(0.2) end
	end
end

local function swapIn(body: Model, folder: Instance)
	local root = body.PrimaryPart
	local look = CitizenModel.lookOfModel(body)
	if not root or not look then return end
	local template = folder:FindFirstChild("Hair_" .. look.hair.id)
	local shirts, pantsList = folder:FindFirstChild("Shirts"), folder:FindFirstChild("Pants")
	local shirt = shirts and shirts:FindFirstChild(tostring(look.shirt.id))
	local pants = pantsList and pantsList:FindFirstChild(tostring(look.pants.id))
	if not template or not shirt or not pants then return end

	local rig = template:Clone() :: Model
	rig.Name = "Avatar"
	local rigShirt = rig:FindFirstChildOfClass("Shirt")
	local rigPants = rig:FindFirstChildOfClass("Pants")
	if rigShirt then rigShirt.ShirtTemplate = (shirt :: Shirt).ShirtTemplate end
	if rigPants then rigPants.PantsTemplate = (pants :: Pants).PantsTemplate end
	setSkin(rig, look.skin)

	local height, drop = rigMeasure(rig)
	local scale = look.heightStuds / height
	rig:ScaleTo(scale)
	local hrp = rig.PrimaryPart :: BasePart
	rig:PivotTo(root.CFrame * CFrame.new(0, drop * scale, 0))
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = hrp
	weld.Parent = hrp
	rig.Parent = body
	bodyHidden(body, true)

	local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local a: Avatar = {
		rig = rig,
		scale = scale,
		walk = animator:LoadAnimation(_walkAnim :: Animation),
		idle = animator:LoadAnimation(_idleAnim :: Animation),
		lastPos = root.Position,
	}
	_avatars[body] = a
	play(a, false, 0)
end

local function swapOut(body: Model, a: Avatar)
	_avatars[body] = nil
	a.rig:Destroy()
	if body.Parent then bodyHidden(body, false) end
end

local function sweep(dt: number)
	local camera = Workspace.CurrentCamera
	local folder = ReplicatedStorage:FindFirstChild("CitizenAvatars")
	if not camera or not folder then return end
	local camCF = camera.CFrame
	local eye, look = camCF.Position, camCF.LookVector
	local pps1 = LOD.pixelsPerStud(1, camera)
	local showDist = DETAIL_STUDS * pps1 / (2 * LOD.PIXEL_BUDGET)
	local keepDist = DETAIL_STUDS * pps1 / LOD.PIXEL_BUDGET

	local near: { Near } = {}
	for _, inst in CollectionService:GetTagged(CitizenModel.TAG) do
		local root = if inst:IsA("Model") then inst.PrimaryPart else nil
		if not root then continue end
		local off = root.Position - eye
		local dist = off.Magnitude
		if dist > (if _avatars[inst :: Model] then keepDist else showDist) then continue end
		if dist > 1 and off:Dot(look) < BEHIND_COS * dist then continue end
		table.insert(near, { body = inst :: Model, dist = dist })
	end
	table.sort(near, function(p, q) return p.dist < q.dist end)

	local keep: { [Model]: boolean } = {}
	for i = 1, math.min(#near, AVATAR_MAX) do keep[near[i].body] = true end
	for body, a in _avatars do
		if not keep[body] or not a.rig.Parent then swapOut(body, a) end
	end
	local swaps = SWAPS_PER_SWEEP
	for i = 1, math.min(#near, AVATAR_MAX) do
		if swaps == 0 then break end
		local body = near[i].body
		if not _avatars[body] then
			swapIn(body, folder)
			swaps -= 1
		end
	end

	for body, a in _avatars do
		local root = body.PrimaryPart
		if not root then continue end
		local pos = root.Position
		local step = Vector3.new(pos.X - a.lastPos.X, 0, pos.Z - a.lastPos.Z).Magnitude
		a.lastPos = pos
		local speed = if dt > 0 then step / dt else 0
		play(a, speed > MOVING, speed)
	end
end

local function setAnimate(on: boolean)
	_animate = on
	if on then return end
	for _, a in _avatars do
		a.walk:Stop(0)
		a.idle:Stop(0)
	end
end

function CitizenAvatarView.Start()
	if #_conns > 0 then return end
	local walk = Instance.new("Animation")
	walk.AnimationId = WALK_ANIM
	local idle = Instance.new("Animation")
	idle.AnimationId = IDLE_ANIM
	_walkAnim, _idleAnim = walk, idle

	setAnimate(Settings.get("graphicsPreset") ~= "Low")
	Settings.onChanged("graphicsPreset", function(preset: any)
		setAnimate(preset ~= "Low")
	end)
	table.insert(_conns, RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < SWEEP_INTERVAL then return end
		local elapsed = _accum
		_accum = 0
		local ok, err = pcall(sweep, elapsed)
		if not ok then warn("[CitizenAvatarView] sweep failed: " .. tostring(err)) end
	end))
end

function CitizenAvatarView.Stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	for body, a in _avatars do swapOut(body, a) end
	_accum = 0
end

return CitizenAvatarView
