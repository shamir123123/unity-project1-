--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local settingsStub = { get = function(k) return nil end, onChanged = function() end }
local pressureStub = { lerpInt = function(a) return a end, lerp = function(a) return a end, detail = function() return 1 end, level = function() return 0 end }
H.patches["StarterPlayer.StarterPlayerScripts.World.StreetNameView"] = function(src)
	return (string.gsub(src, "\nreturn StreetNameView%s*$", "\nStreetNameView._rebuild = rebuild\nreturn StreetNameView\n"))
end
H.boot({ server = false, overrides = {
	["StarterPlayer.StarterPlayerScripts.Core.Settings"] = settingsStub,
	["StarterPlayer.StarterPlayerScripts.Core.RenderPressure"] = pressureStub,
} })
H.quietWarn = true
H.game:GetService("TextService")._props.GetTextBoundsAsync = function(_, params) return H.roblox.Vector2.new(58 * #params.Text, 100) end
H.game:GetService("TweenService")._props.Create = function() return { Play = function() end, Cancel = function() end } end
local V3 = H.roblox.Vector3
local DataCache = H.require("ReplicatedStorage.DataCache")
-- three separate straight streets, each one segment, each with a distinct name
local recs = {}
for i = 1, 3 do
	local a, b = V3.new(0, 10, i * 200), V3.new(400, 10, i * 200)
	table.insert(recs, { id = i, p0 = a, p1 = a:Lerp(b, 1/3), p2 = a:Lerp(b, 2/3), p3 = b, roadType = "CollectorRoad",
		startNode = i * 10, endNode = i * 10 + 1, name = "Road " .. i })
end
DataCache.SetSegments(recs)
local View = H.require("StarterPlayer.StarterPlayerScripts.World.StreetNameView")
View.Start()
H.task.wait(1)
local ws = H.game:GetService("Workspace")
local function zs()
	local out = {}
	for _, p in ws:FindFirstChild("_StreetNames"):GetChildren() do table.insert(out, math.round(p.Position.Z)) end
	table.sort(out)
	return table.concat(out, ",")
end
print("before:", zs())
-- move street 2 by +50 in Z (a new record, as a delta would deliver)
local a, b = V3.new(0, 10, 450), V3.new(400, 10, 450)
DataCache.ApplySegmentsDelta({ changed = { { id = 2, p0 = a, p1 = a:Lerp(b, 1/3), p2 = a:Lerp(b, 2/3), p3 = b, roadType = "CollectorRoad",
	startNode = 20, endNode = 21, name = "Road 2" } }, removed = {} })
H.task.wait(1)
print("after: ", zs())
process.exit(0)
