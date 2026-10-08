--!nocheck
-- WaterView foam: repaints per frame and per tile, old vs new schedule.
-- Usage (from tools/harness): lune run test_waterfoam.luau [orig]
local H = require("./loader")
local process = require("@lune/process")
local orig = process.args[1] == "orig"
H.patches["StarterPlayer.StarterPlayerScripts.World.WaterView"] = function(src)
	if orig then
		src = process.exec("git", { "show", "5858734:src/StarterPlayer.StarterPlayerScripts.World.WaterView.luau" }).stdout
	end
	return (string.gsub(src, "\nreturn WaterView%s*$", "\nWaterView._anim = animStep\nWaterView._tiles = function() return _tiles end\nreturn WaterView\n"))
end
local perFrame = 0
local perTile = {}
local imageStub = setmetatable({
	compose = function(img) perFrame += 1; perTile[img] = (perTile[img] or 0) + 1 end,
}, { __index = function() return function() end end })
H.boot({ server = false, overrides = { ["ReplicatedStorage.City.WaterImage"] = imageStub, ["ReplicatedStorage.Terrain.TerrainStreamCodec"] = {} } })
H.quietWarn = true
local WaterView = H.require("StarterPlayer.StarterPlayerScripts.World.WaterView")
local cam = H.game:GetService("Workspace").CurrentCamera
cam.CFrame = H.roblox.CFrame.new(MAPX or -2048, 300, 0) -- a tile corner: four tiles in range
local tiles = WaterView._tiles()
local MAPX = nil
-- What build() makes around the camera: a 4x4 map of 2048-stud tiles, phased (new code) by tile
-- parity exactly as build() does.
local n = 0
for i = 0, 3 do
	for j = 0, 3 do
		n += 1
		table.insert(tiles, { img = n, x0 = -4096 + i * 2048, z0 = -4096 + j * 2048, shore = true, foamN = 0,
			animIn = ((i % 2) + 2 * (j % 2)) / 4 * (1 / 12) })
	end
end
for _, fps in { 60, 240, 30 } do
	table.clear(perTile)
	local worst, frames, busy = 0, fps * 10, 0
	for _ = 1, frames do
		perFrame = 0
		WaterView._anim(1 / fps)
		worst = math.max(worst, perFrame)
		if perFrame > 0 then busy += 1 end
	end
	local lo, hi = math.huge, 0
	for _, n in perTile do lo = math.min(lo, n / 10); hi = math.max(hi, n / 10) end
	print(string.format("%3d fps: worst %d repaints in one frame; %4d of %d frames repaint; per tile %.1f-%.1f Hz (%d tiles in range)",
		fps, worst, busy, frames, lo, hi, (function() local c = 0 for _ in perTile do c += 1 end return c end)()))
end
process.exit(0)
