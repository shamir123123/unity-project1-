--!nocheck
-- RoadService render worker: an edit's pieces are drawn after the edit's frame, every one of them,
-- and waitForRender returns once they are.
local H = require("./loader")
local flat = function() return 10 end
local terrainData = setmetatable({ getSurfaceY = flat, getNaturalSurfaceY = flat, getHeightAt = flat }, { __index = function() return function() return 10 end end })
local terrainGrade = setmetatable({ setNodeInfo = function() end }, { __index = function() return function() end end })
H.boot({ server = true, overrides = {
	["ServerScriptService.Services.Terrain.TerrainDataService"] = terrainData,
	["ServerScriptService.Services.Terrain.TerrainGradeService"] = terrainGrade,
} })
H.quietWarn = true
local V3 = H.roblox.Vector3
-- remotes the replication service binds
local Net = H.require("ReplicatedStorage.Networker")
local RoadService = H.require("ServerScriptService.Services.Road.RoadService")
local RoadSceneRenderer = H.require("ReplicatedStorage.Road.RoadSceneRenderer")
RoadService.Init()
local rendered = {}
local origSeg, origNode = RoadSceneRenderer.renderSegment, RoadSceneRenderer.refreshNode
RoadSceneRenderer.renderSegment = function(s) rendered["s" .. s.id] = (rendered["s" .. s.id] or 0) + 1; return origSeg(s) end
RoadSceneRenderer.refreshNode = function(id) rendered["n" .. id] = (rendered["n" .. id] or 0) + 1; return origNode(id) end
local hb = H.game:GetService("RunService").Heartbeat
local frames = 0
local function frame() frames += 1; hb:Fire(1 / 60); H.task.wait() end

local function place(a, b)
	local p1, p2 = a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3)
	return RoadService.placeSegment(a, p1, p2, b, "CollectorRoad")
end
-- a small grid, frame by frame
for i = 0, 3 do
	place(V3.new(i * 128, 10, 0), V3.new(i * 128, 10, 384))
end
for j = 0, 3 do
	place(V3.new(0, 10, j * 128), V3.new(384, 10, j * 128))
end
local n0 = 0 for _ in rendered do n0 += 1 end
print("pieces drawn in the edit frames:", n0)
local done = false
H.task.spawn(function() RoadService.waitForRender(5); done = true end)
for _ = 1, 30 do frame() if done then break end end
local n1 = 0 for _ in rendered do n1 += 1 end
local segs = 0 for _ in RoadService.getNetwork():getSegments() do segs += 1 end
local nodes = 0 for _ in RoadService.getNetwork():getNodes() do nodes += 1 end
local missingS, missingN = 0, 0
for id in RoadService.getNetwork():getSegments() do if not rendered["s" .. id] then missingS += 1 end end
for id in RoadService.getNetwork():getNodes() do if not rendered["n" .. id] then missingN += 1 end end
print(string.format("after %d frames: drawn %d pieces; network %d segs / %d nodes; never drawn: %d segs, %d nodes; waitForRender done=%s",
	frames, n1, segs, nodes, missingS, missingN, tostring(done)))
local multi = 0 for _, c in rendered do if c > 1 then multi += 1 end end
print("pieces drawn more than once:", multi)
