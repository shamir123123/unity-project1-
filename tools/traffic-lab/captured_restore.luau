local W = require("./rt/world")
local E = W.E
E.preloadSources()
local fs = require("@lune/fs")
local process = require("@lune/process")
local specInst = E.resolve("ServerScriptService.Services.NPC.NPCDriverService.spec")
local src = specInst.Source
local a = src:find('describe("captured city restore admission"', 1, true)
local s0 = src:find("loadstring([====[", a, true) + #"loadstring([====["
local s1 = src:find("]====], \"CapturedCityRestore\"", s0, true) - 1
local chunk = src:sub(s0, s1)
chunk = chunk:gsub("table%.insert%(remaining,%{car=s%.model%.Name", function(m)
	return [[print("DETAIL", s.model.Name, s.edgeId, s.edgeDist, "ri", s.routeIndex, "route", table.concat(s.route or {}, ">", s.routeIndex or 1, math.min(#(s.route or {}), (s.routeIndex or 1) + 3)), "pend", s.pendingNextEdgeId, "conn", s.connector ~= nil, "lcw", s.laneChangeWait, "hold", s.mergeHoldAt, "missed", s.laneChangeMissed, "blockedBy", s.blockedBy and s.blockedBy.Name, "ex", s.exitWait)
]] .. m
end)
local env = E.makeEnv(specInst)
local fn = env.loadstring(chunk, "CapturedCityRestore")
local size = tonumber(process.args[1]) or 18
local result = fn(W.V3.new(6, 3, size))
print(string.format("RESTORE size=%d cars=%d arrived=%d aborted=%d elapsed=%.1f collisions=%d longestOverlap=%.2f",
	size, result.cars, result.arrived, result.aborted, result.elapsed, result.collisions, result.longestOverlap))
for _, r in result.remaining do print("  left", r.car, r.edge, string.format("%.1f", r.dist or -1), r.why, string.format("%.2f", r.speed or 0)) end
if result.firstCollision then for k, v in result.firstCollision do print("  coll", k, v) end end
