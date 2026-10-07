--!strict
-- UtilityProblems
-- What can be wrong with a building, in the order it matters: the attribute the server
-- stamps, the pin it draws (Branding/badges/make_badges.py) and the line the info panel
-- says. NoPowerView and BuildingInfoController both read THIS table, so the pins over a
-- roof and the panel's list can never disagree. Pure data + one read helper.

local UtilityProblems = {}

-- Attributes in the order they are listed (and laid out left to right over a roof).
UtilityProblems.ORDER = table.freeze({ "Abandoned", "NoRoad", "NoPower", "Stranded", "NoWater", "NoSewage", "DeadEnd" })

UtilityProblems.IMAGE = table.freeze({
	Abandoned     = "rbxassetid://81908265016044",
	NoRoad        = "rbxassetid://105083309569734",
	NoPower       = "rbxassetid://102173562454284",
	Stranded      = "rbxassetid://124649643345626",
	StrandedPipe  = "rbxassetid://111820971217203",
	StrandedSewer = "rbxassetid://82803270909976",
	NoWater       = "rbxassetid://117040749936425",
	NoSewage      = "rbxassetid://113455261946341",
	DeadEnd       = "rbxassetid://133187265661949",
} :: { [string]: string })

UtilityProblems.TEXT = table.freeze({
	Abandoned     = "Abandoned -- nobody lives here",
	NoRoad        = "Road required",
	NoPower       = "Not enough electricity",
	Stranded      = "Power line not connected",
	StrandedPipe  = "Water pipe not connected",
	StrandedSewer = "Sewer pipe not connected",
	NoWater       = "Not enough water",
	NoSewage      = "Backed up sewer",
	DeadEnd       = "Dead end -- traffic can't get through",
} :: { [string]: string })

-- Which pin an attribute draws on this model. Only a stranded pipe end has a choice:
-- WaterPipeService stamps Water / Sewage on each cap; a run carrying both shows water.
local function keyFor(model: Instance, attr: string): string
	if attr ~= "Stranded" then return attr end
	local folder = model.Parent
	if not (folder and folder.Name == "PipeEnds") then return attr end
	if model:GetAttribute("Sewage") == true and model:GetAttribute("Water") ~= true then
		return "StrandedSewer"
	end
	return "StrandedPipe"
end

-- Every problem set on `model`, as pin keys in ORDER. An abandoned building is only that:
-- the family has gone, so its power and water are no longer the news.
function UtilityProblems.keysFor(model: Instance): { string }
	local out: { string } = {}
	for _, attr in UtilityProblems.ORDER do
		if model:GetAttribute(attr) == true then
			if attr == "Abandoned" then return { attr } end
			table.insert(out, keyFor(model, attr))
		end
	end
	return out
end

return UtilityProblems
