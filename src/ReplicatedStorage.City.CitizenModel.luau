--!strict
-- CitizenModel
-- Pure builder for the people that populate the city: commuter pedestrians
-- (NPCWalkingService) and the residents standing about outdoors (CitizenPresenceView).
-- No lifecycle, no state, no side effects on require -- just `build(opts)` -> a fresh Model
-- whose PrimaryPart is an anchored root at the FEET that every part welds to, so moving the
-- root (or PivotTo) moves the whole person, and placing the root on the ground stands them
-- on it.
--
-- Two levels so thousands stay cheap. Every citizen is this plain R6 figure: no Humanoid,
-- 6 parts (7 with long hair), the two legs one block. CitizenAvatarView swaps the ones near
-- the camera for a real Roblox avatar in free catalog clothing (CitizenWardrobe). lookOf()
-- is the one place an outfit is chosen, and the plain body wears that outfit's colours, so
-- the two levels always agree. Height comes from the citizen's AGE on a real growth curve,
-- and a child's head is big for their size, so a toddler reads as a toddler.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local Wardrobe = require(ReplicatedStorage.City.CitizenWardrobe)

local CitizenModel = {}

-- Every body carries this tag, so the client can find the people it may swap for avatars.
CitizenModel.TAG = "CitizenBody"

export type Appearance = {
	gender: string,
	kind: string,
	seed: number?,
	age: number?,
}

export type Look = {
	shirt: Wardrobe.Shirt,
	pants: Wardrobe.Pants,
	hair: Wardrobe.Hair,
	skin: Color3,
	heightStuds: number, -- feet to the top of the head
}

local SKIN_TONES = table.freeze({
	Color3.fromRGB(244, 213, 184),
	Color3.fromRGB(225, 184, 147),
	Color3.fromRGB(188, 137, 99),
	Color3.fromRGB(126, 82, 58),
	Color3.fromRGB(82, 53, 42),
})
local FACE_TEXTURE = "rbxasset://textures/face.png"

-- Median height (m) for ages 0..17, mid-year, boys and girls averaged (WHO/CDC charts).
-- Indexed by age + 1; anyone past the table is an adult.
local CHILD_HEIGHT_M = table.freeze({
	0.66, 0.82, 0.91, 0.99, 1.06, 1.13, 1.19, 1.25, 1.30,
	1.36, 1.41, 1.47, 1.54, 1.60, 1.65, 1.69, 1.71, 1.73,
})
local ADULT_HEIGHT_M = 1.75
local ADULT_AGE = 18
local DEFAULT_KID_AGE = 9

-- R6 in rig units: legs and torso stack 4 tall; the stock head (2x1x1 part, Head mesh at
-- 1.25) sits on the torso and tops out HEAD_TOP above it.
local BODY_H = 4
local HEAD_TOP = 1.125
local HEAD_MESH_SCALE = 1.25
-- Heads grow slower than bodies: head size ~ height^0.75, the body takes the rest.
local HEAD_GROWTH = 0.75
-- Studs per rig unit for an average adult.
local ADULT_UNIT = ADULT_HEIGHT_M / RoadConstants.STUD_TO_METER / (BODY_H + HEAD_TOP)

local TWO32 = 4294967296

-- a * b mod 2^32 without leaving the doubles' exact-integer range.
local function mul32(a: number, b: number): number
	return ((a % 65536) * b + (((a // 65536) * b) % 65536) * 65536) % TWO32
end

-- Deterministic 0..1 from (seed, salt): the server's plain body and the client's avatar
-- must pick the same outfit for the same person. lowbias32 integer hash, so neighbouring
-- pids get unrelated outfits.
local function roll(seed: number, salt: number): number
	local x = (seed + salt * 2654435769) % TWO32
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x7feb352d)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = mul32(x, 0x846ca68b)
	x = bit32.bxor(x, bit32.rshift(x, 16))
	return x / TWO32
end

local function pick<T>(items: { T }, seed: number, salt: number): T
	return items[math.floor(roll(seed, salt) * #items) + 1]
end

local function ageOf(opts: Appearance): number
	local age = tonumber(opts.age)
	if age then return math.max(0, math.floor(age)) end
	return if opts.kind == "kid" then DEFAULT_KID_AGE else ADULT_AGE
end

function CitizenModel.lookOf(seed: number, age: number, gender: string): Look
	local heightVariation = 0.94 + ((seed * 17) % 13) / 100
	return {
		shirt = pick(Wardrobe.shirts, seed, 1),
		pants = pick(Wardrobe.pants, seed, 2),
		hair = pick(if gender == "F" then Wardrobe.femaleHair else Wardrobe.maleHair, seed, 3),
		skin = pick(SKIN_TONES, seed, 4),
		heightStuds = (CHILD_HEIGHT_M[age + 1] or ADULT_HEIGHT_M) * heightVariation / RoadConstants.STUD_TO_METER,
	}
end

-- The look of a body made by build, from the attributes build stamped on it.
function CitizenModel.lookOfModel(model: Model): Look?
	local seed, age, gender = model:GetAttribute("AppearanceSeed"), model:GetAttribute("AppearanceAge"), model:GetAttribute("AppearanceGender")
	if typeof(seed) ~= "number" or typeof(age) ~= "number" or typeof(gender) ~= "string" then return nil end
	return CitizenModel.lookOf(seed, age, gender)
end

local function bodyPart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = false
	p.Massless = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function headMesh(part: Part)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.one * HEAD_MESH_SCALE
	mesh.Parent = part
end

local function attach(model: Model, root: BasePart, part: BasePart, cf: CFrame)
	part.CFrame = cf
	part.Parent = model
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = part
	w.Parent = root
end

function CitizenModel.build(opts: Appearance): Model
	local seed = math.max(1, math.floor(tonumber(opts.seed) or 1))
	local age = ageOf(opts)
	local gender = if opts.gender == "F" then "F" else "M"
	local look = CitizenModel.lookOf(seed, age, gender)
	local r = look.heightStuds / (ADULT_UNIT * (BODY_H + HEAD_TOP))
	local h = ADULT_UNIT * r ^ HEAD_GROWTH
	local u = (look.heightStuds - HEAD_TOP * h) / BODY_H

	local model = Instance.new("Model")
	model.Name = "Citizen"
	model:SetAttribute("AppearanceSeed", seed)
	model:SetAttribute("AppearanceAge", age)
	model:SetAttribute("AppearanceGender", gender)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(0.7, 0.7, 0.7)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Parent = model
	model.PrimaryPart = root
	local base = root.CFrame

	attach(model, root, bodyPart("Legs", Vector3.new(2, 2, 1) * u, look.pants.legs), base * CFrame.new(0, u, 0))
	attach(model, root, bodyPart("Torso", Vector3.new(2, 2, 1) * u, look.shirt.torso), base * CFrame.new(0, 3 * u, 0))
	for _, side in { -1, 1 } do
		attach(model, root, bodyPart(if side < 0 then "Left Arm" else "Right Arm", Vector3.new(1, 2, 1) * u, look.shirt.arms),
			base * CFrame.new(side * 1.5 * u, 3 * u, 0))
	end

	local headCF = base * CFrame.new(0, 4 * u + 0.5 * h, 0)
	local head = bodyPart("Head", Vector3.new(2, 1, 1) * h, look.skin)
	headMesh(head)
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = FACE_TEXTURE
	face.Parent = head
	attach(model, root, head, headCF)

	-- Hair is a slightly bigger head shape pushed up and back: it caps the crown, not the face.
	local hair = bodyPart("Hair", Vector3.new(2, 1, 1) * h * 1.08, look.hair.color)
	headMesh(hair)
	attach(model, root, hair, headCF * CFrame.new(0, 0.12 * h, 0.1 * h))
	if look.hair.long then
		attach(model, root, bodyPart("LongHair", Vector3.new(1.2, 1.2, 0.3) * h, look.hair.color),
			headCF * CFrame.new(0, -0.2 * h, 0.5 * h))
	end

	CollectionService:AddTag(model, CitizenModel.TAG)
	return model
end

return CitizenModel
