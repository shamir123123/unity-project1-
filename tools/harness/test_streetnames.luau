--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local settingsStub = { get = function(k) return nil end, onChanged = function() end }
local pressureStub = { lerpInt = function(a) return a end, lerp = function(a) return a end, detail = function() return 1 end, level = function() return 0 end }
H.boot({ server = false, overrides = {
	["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub,
	["StarterPlayer.StarterPlayerScripts.Core.RenderPressure"] = pressureStub,
} })
H.quietWarn = true
local TextService = H.game:GetService("TextService")
TextService._props.GetTextBoundsAsync = function(_, params) return H.roblox.Vector2.new(58 * #params.Text, 100) end
local TweenService = H.game:GetService("TweenService")
TweenService._props.Create = function() return { Play = function() end, Cancel = function() end } end
local City = require("./city")
local V3 = H.roblox.Vector3
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local net = RoadNetwork.new()
City.grid(net, 6, 160, "AvenueConcrete")
-- one curved road
net:addSegment(V3.new(600, 10, 0), V3.new(700, 10, 300), V3.new(900, 10, 300), V3.new(1000, 10, 0), "AvenueConcrete")
net:consumeChanges()
local recs = City.records(net)
for i, r in recs do r.name = "Street " .. ((i % 7) + 1) end
DataCache.SetSegments(recs)
local ws = H.game:GetService("Workspace")
ws.CurrentCamera.CFrame = H.roblox.CFrame.new(0, 300, 0) * H.roblox.CFrame.Angles(-1.2, 0, 0)
local View = H.require("StarterPlayer.StarterPlayerScripts.World.StreetNameView")
View.Start()
H.task.wait(1.5)
local folder = ws:FindFirstChild("_StreetNames")
local plates, whole, maxLen = 0, 0, 0
for _, p in folder:GetChildren() do
	plates += 1
	local label = p:FindFirstChildOfClass("SurfaceGui"):FindFirstChildOfClass("TextLabel")
	if #label.Text > 1 then whole += 1 end
	maxLen = math.max(maxLen, p.Size.Z)
end
print(string.format("plates %d (whole-word %d), longest plate %.1f studs", plates, whole, maxLen))
-- distance of every plate centre from the nearest road centreline, and its height above it
local BezierUtil = H.require("ReplicatedStorage.Road.BezierUtil")
local lo, hi, ylo, yhi = math.huge, 0, math.huge, -math.huge
for _, p in folder:GetChildren() do
	local best, by = math.huge, 0
	for _, sg in net:getSegments() do
		local t = BezierUtil.closestParam(sg.p0, sg.p1, sg.p2, sg.p3, p.Position, 16)
		local q = BezierUtil.point(sg.p0, sg.p1, sg.p2, sg.p3, t)
		local d = (V3.new(q.X, 0, q.Z) - V3.new(p.Position.X, 0, p.Position.Z)).Magnitude
		if d < best then best, by = d, p.Position.Y - q.Y end
	end
	lo, hi = math.min(lo, best), math.max(hi, best)
	ylo, yhi = math.min(ylo, by), math.max(yhi, by)
end
print(string.format("plate offset from centreline: %.2f..%.2f studs; height above it: %.2f..%.2f", lo, hi, ylo, yhi))
process.exit(0)
