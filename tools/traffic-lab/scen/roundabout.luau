local C = require("./common")
local W = C.W
local V3 = W.V3
local process = require("@lune/process")
local ringType = process.args[1] or "Roundabout1"
local armType = process.args[2] or "NarrowRoad"
local rate = tonumber(process.args[3]) or 0.1
local secs = tonumber(process.args[4]) or 300
local net = W.newCity()
local R = tonumber(process.args[5]) or 40
net:addRoundabout(V3.zero, R, ringType, 8)
local L = 450
local tips = { V3.new(L, 0, 0), V3.new(-L, 0, 0), V3.new(0, 0, L), V3.new(0, 0, -L) }
local ends = {}
for _, t in tips do
	local dirIn = (V3.zero - t).Unit
	W.road(t, dirIn * -R, armType)
	table.insert(ends, C.armEnd(t, V3.zero))
end
W.rebuild()
-- describe ring nodes
local n3 = 0
for id, node in net:getNodes() do if #node.segments >= 3 then n3 += 1 end end
print("ring junction nodes:", n3, "edges:", #W.graph:GetEdges())
W.boot({ viewerPos = V3.new(0, 200, 0) })
local res = C.run({ ends = ends, rate = rate, secs = secs })
C.report(("roundabout %s/%s rate=%.2f"):format(ringType, armType, rate), res)
