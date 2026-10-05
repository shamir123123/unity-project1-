local Runtime = require("../tools/runtime")
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = "../bundle_after" })
local RS = rt.game:GetService("ReplicatedStorage")
local Cat = rt.require(RS.Road.RoadTypeCatalog)
local RoadSection = rt.require(RS.Road.RoadSection)
local worst, worstName = 0, ""
for name, spec in Cat.Types do
	local w = spec.width or 0
	local reach = w * 0.5
	local ok, sec = pcall(function() return RoadSection.of(spec.profile or spec, 1) end)
	if ok and sec and sec.roadR then
		reach = math.max(sec.roadR, -sec.roadL) + math.max(sec.walkL or 0, sec.walkR or 0)
	end
	if reach > worst then worst, worstName = reach, name end
	print(string.format("%-18s width %6.1f  half+walk %6.1f", name, w, reach))
end
print("widest:", worstName, worst, "+ STOP_REACH 12 =", worst + 12)
