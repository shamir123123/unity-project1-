-- Run every *.spec module the harness can load, before vs after; print one line per spec.
local process = require("@lune/process")
local fs = require("@lune/fs")
local task = require("@lune/task")
local Runtime = require("../tools/runtime")
local SH = {}
local fails = {}
local function mkExpect(v)
	local o = {}
	o.to = { be = setmetatable({}, { __index = function(_, k) if k == "ok" then assert(v, "expected ok") return true end end }), equal = function(x) assert(v == x, "expected equal") end }
	return o
end
local cur = ""
SH.expect = mkExpect
SH.describe = function(_, f) f() end
SH.it = function(name, f) local ok, err = pcall(f); if not ok then table.insert(fails, cur .. " :: " .. name .. " :: " .. tostring(err):sub(1, 120)) end end
local rt = Runtime.load({ place = "place_lune.rbxl", bundle = process.args[1], shared = SH })
local names = {}
for full in rt.loaders do if full:match("%.spec$") then table.insert(names, full) end end
table.sort(names)
local function find(path)
	local inst = rt.game
	for part in string.gmatch(path, "[^%.]+") do
		if part == "spec" and inst then inst = inst:FindFirstChild("spec") else inst = inst and inst:FindFirstChild(part) end
	end
	return inst
end
for _, full in names do
	cur = full
	local inst = find(full)
	local status
	if not inst then status = "NOINST" else
		local ok, mod = pcall(rt.require, inst)
		if not ok then status = "LOADERR " .. tostring(mod):gsub("\n.*", ""):sub(1, 100)
		elseif type(mod) == "function" then
			local before = #fails
			local ok2, err = pcall(mod)
			status = if ok2 then ("ran fails=" .. (#fails - before)) else ("ERR " .. tostring(err):gsub("\n.*", ""):sub(1, 100))
		elseif type(mod) == "table" and type(mod.run) == "function" then
			local ok2, res = pcall(mod.run)
			status = if ok2 then ("run=" .. tostring(res)) else ("ERR " .. tostring(res):gsub("\n.*", ""):sub(1, 100))
		else status = "SKIP" end
	end
	print(full, "|", status)
end
