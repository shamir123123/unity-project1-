--!nocheck
local H = require("./loader")
local process = require("@lune/process")
local N = tonumber(process.args[1]) or 20
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
local TextService = H.game:GetService("TextService")
TextService._props.GetTextBoundsAsync = function(_, params) return H.roblox.Vector2.new(58 * #params.Text, 100) end
H.game:GetService("TweenService")._props.Create = function() return { Play = function() end, Cancel = function() end } end
local City = require("./city")
local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local DataCache = H.require("ReplicatedStorage.DataCache")
local AddressBook = H.require("ReplicatedStorage.City.AddressBook")
local net = RoadNetwork.new()
local count = City.grid(net, N, 128, "CollectorRoad")
net:consumeChanges()
local recs = City.records(net)
for i, r in recs do r.name = "Street " .. ((i % 37) + 1) end
DataCache.SetSegments(recs)
local View = H.require("StarterPlayer.StarterPlayerScripts.World.StreetNameView")
View.Start()
H.task.wait(1)
local t = os.clock()
local idx = AddressBook.buildIndex(DataCache.GetSegments())
local tIndex = os.clock() - t
t = os.clock()
View._rebuild() -- nothing changed: this is the per-edit cost
local tRe = os.clock() - t
print(string.format("%d segments: AddressBook.buildIndex %.0f ms; rebuild with nothing changed %.0f ms", count, tIndex * 1000, tRe * 1000))
process.exit(0)
