--!strict
-- Citizens stand on their root, are the right height for their age, wear the outfit lookOf
-- picks, and stay cheap to draw by the thousand. No framework -- `require(script).run()` asserts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CitizenModel = require(script.Parent)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local Wardrobe = require(ReplicatedStorage.City.CitizenWardrobe)

local spec = {}

-- Seed 8 has no height variation: 0.94 + (8 * 17 % 13) / 100 = 1.
local SEED = 8

type Measure = { height: number, feet: number, visible: number, headShare: number }

local function measure(kind: string, age: number?, gender: string?): Measure
	local m = CitizenModel.build({ gender = gender or "M", kind = kind, seed = SEED, age = age })
	local root = m.PrimaryPart :: BasePart
	local head = m:FindFirstChild("Head") :: BasePart
	local legs = m:FindFirstChild("Legs") :: BasePart
	-- The Head mesh draws 1.25x the part's height, centred on it.
	local headH = head.Size.Y * 1.25
	local top = head.Position.Y - root.Position.Y + headH / 2
	local visible = 0
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then visible += 1 end
	end
	m:Destroy()
	return {
		height = top * RoadConstants.STUD_TO_METER,
		feet = legs.Position.Y - legs.Size.Y / 2 - root.Position.Y,
		visible = visible,
		headShare = headH / top,
	}
end

local function same(a: Color3, b: Color3): boolean
	return a:ToHex() == b:ToHex()
end

function spec.run()
	local adult = measure("adult")
	assert(math.abs(adult.height - 1.75) < 0.01, "an adult stands 1.75 m, got " .. adult.height)
	assert(math.abs(adult.feet) < 1e-4, "the root sits at the feet")
	assert(adult.visible <= 7, "a plain body is at most 7 visible parts, got " .. adult.visible)
	assert(measure("adult", nil, "F").visible <= 7, "a woman is at most 7 visible parts")

	local baby = measure("kid", 0)
	assert(math.abs(baby.height - 0.66) < 0.01, "a baby is 0.66 m, got " .. baby.height)
	assert(math.abs(baby.feet) < 1e-4, "a baby's root sits at the feet too")
	assert(baby.headShare > adult.headShare + 0.05, "a baby's head is big for their size")

	local prev = 0
	for age = 0, 17 do
		local h = measure("kid", age).height
		assert(h > prev, "children grow every year, not at age " .. age)
		prev = h
	end
	assert(prev < adult.height, "a 17-year-old is still a little shorter than an adult")
	assert(measure("kid").height == measure("kid", 9).height, "a kid of unknown age is drawn as a 9-year-old")
	assert(measure("adult", 40).height == adult.height, "adults stop growing")

	-- The plain body wears the outfit the avatar will wear.
	local body = CitizenModel.build({ gender = "F", kind = "adult", seed = 77, age = 30 })
	local look = CitizenModel.lookOfModel(body)
	assert(look, "a built body knows its look")
	assert(look.shirt == CitizenModel.lookOf(77, 30, "F").shirt, "the look is the same every time")
	assert(same((body:FindFirstChild("Torso") :: BasePart).Color, look.shirt.torso), "the torso wears the shirt's colour")
	assert(same((body:FindFirstChild("Left Arm") :: BasePart).Color, look.shirt.arms), "the arms wear the sleeves' colour")
	assert(same((body:FindFirstChild("Legs") :: BasePart).Color, look.pants.legs), "the legs wear the pants' colour")
	assert((body:FindFirstChild("LongHair") ~= nil) == look.hair.long, "long hair shows only for long styles")
	assert(table.find(Wardrobe.femaleHair, look.hair), "women wear women's or unisex hair")
	body:Destroy()
	for pid = 1, 200 do
		assert(table.find(Wardrobe.maleHair, CitizenModel.lookOf(pid, 30, "M").hair), "men wear men's or unisex hair")
	end

	local outfits: { [string]: boolean } = {}
	local count = 0
	for pid = 1, 500 do
		local l = CitizenModel.lookOf(pid, 30, if pid % 2 == 0 then "F" else "M")
		local key = `{l.shirt.id}/{l.pants.id}/{l.hair.id}`
		if not outfits[key] then outfits[key] = true; count += 1 end
	end
	assert(count >= 250, "500 neighbours wear at least 250 different outfits, got " .. count)
end

return spec
