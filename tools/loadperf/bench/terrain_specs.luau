local process = require("@lune/process")
local Runtime = require("../tools/runtime")
local SH = {}
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = process.args[1] or "../bundle_after", shared = SH })
local T = rt.game:GetService("ReplicatedStorage"):FindFirstChild("Terrain")
-- mini TestEZ
local failures, passes = 0, 0
local function expect(v)
	local e = {}
	e.to = e; e.be = e
	e.ok = (function() if not v then error("expected truthy") end end)
	function e.equal(x) if v ~= x then error(("expected %s got %s"):format(tostring(x), tostring(v))) end end
	return setmetatable(e, { __index = function(_, k)
		if k == "ok" then if not v then error("expected truthy") end return true end
	end })
end
SH.expect = function(v)
	local o = {}
	o.to = { be = setmetatable({}, { __index = function(_, k) if k == "ok" then assert(v, "expected ok") return true end end }), equal = function(x) assert(v == x, "expected equal") end }
	return o
end
SH.describe = function(name, f) f() end
SH.it = function(name, f)
	local ok, err = pcall(f)
	if ok then passes += 1 else failures += 1; print("  FAIL it:", name, err) end
end
for _, name in { "Heightmap", "TerrainGenerator" } do
	local ok, err = pcall(function() rt.require(T[name].spec)() end)
	print(name .. ".spec", ok and "ran" or ("ERROR " .. tostring(err)))
end
for _, name in { "TerrainMesh", "TerrainSurfaceTexture", "TerrainBrush", "RoadCrossSection" } do
	local ok, res = pcall(function() return rt.require(T[name].spec).run() end)
	print(name .. ".spec", ok and tostring(res) or ("ERROR " .. tostring(res)))
end
local okP, resP = pcall(function()
	return rt.require(T.TerrainPainter.spec).run(rt.require(T.TerrainPainter), rt.require(T.Heightmap), rt.require(T.TerrainConstants))
end)
print("TerrainPainter.spec", okP and tostring(resP) or ("ERROR " .. tostring(resP)))
print(("TestEZ-style: %d passed, %d failed"):format(passes, failures))
