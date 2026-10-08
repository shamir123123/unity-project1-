--!nocheck
-- Run the game's own TestEZ specs offline: a minimal TestEZ (describe / it / expect, the
-- beforeEach/afterEach/beforeAll/afterAll hooks, FOCUS/SKIP no-ops) over the harness loader.
-- Usage (from tools/harness): lune run specs.luau [--client] <Studio.Path.Of.Module.spec> ...
local H = require("./loader")
local process = require("@lune/process")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local args = table.clone(process.args)
local server = true
if args[1] == "--client" then server = false; table.remove(args, 1) end
H.boot({ server = server })
H.quietWarn = true

local function fmt(v) return if type(v) == "string" then string.format("%q", v) else tostring(v) end

local function newExpect(value, negated)
	local e = {}
	local function check(pass, msg)
		if negated then pass = not pass end
		if not pass then error((if negated then "Expected NOT: " else "Expected: ") .. msg, 3) end
	end
	e.equal = function(other) check(value == other, fmt(value) .. " to equal " .. fmt(other)) end
	e.ok = function() check(value ~= nil and value ~= false, fmt(value) .. " to be ok") end
	e.a = function(t) check(typeof(value) == t or H.rbx.typeof(value) == t, fmt(value) .. " to be a " .. t) end
	e.an = e.a
	e.near = function(other, limit)
		limit = limit or 1e-7
		check(type(value) == "number" and math.abs(value - other) <= limit, fmt(value) .. " to be near " .. fmt(other) .. " (" .. limit .. ")")
	end
	e.throw = function(sub)
		local ok, err = pcall(value)
		local pass = not ok and (sub == nil or string.find(tostring(err), sub, 1, true) ~= nil)
		check(pass, "function to throw" .. (if sub then " containing " .. sub else ""))
	end
	return setmetatable(e, { __index = function(self, k)
		if k == "to" or k == "be" or k == "been" or k == "have" or k == "was" or k == "at" then return self end
		if k == "never" then return newExpect(value, not negated) end
		return nil
	end })
end

local total, passed, failures = 0, 0, {}
for _, path in args do
	local inst = H.path(path)
	assert(inst, "no such spec: " .. path)
	local root = { name = path, children = {}, before = {}, after = {}, beforeAll = {}, afterAll = {} }
	local current = root
	local env = {}
	env.describe = function(name, fn)
		local node = { name = name, children = {}, before = {}, after = {}, beforeAll = {}, afterAll = {}, parent = current }
		table.insert(current.children, node)
		local prev = current
		current = node
		fn()
		current = prev
	end
	env.it = function(name, fn) table.insert(current.children, { name = name, fn = fn, parent = current }) end
	env.itFOCUS, env.fit, env.itSKIP, env.xit = env.it, env.it, function() end, function() end
	env.describeFOCUS, env.fdescribe = env.describe, env.describe
	env.describeSKIP, env.xdescribe = function() end, function() end
	env.FOCUS, env.SKIP = function() end, function() end
	env.beforeEach = function(fn) table.insert(current.before, fn) end
	env.afterEach = function(fn) table.insert(current.after, fn) end
	env.beforeAll = function(fn) table.insert(current.beforeAll, fn) end
	env.afterAll = function(fn) table.insert(current.afterAll, fn) end
	env.expect = function(v) return newExpect(v, false) end
	-- load the spec with these globals added to the module env
	H.patches[path] = function(src)
		return "local describe, it, expect, beforeEach, afterEach, beforeAll, afterAll, FOCUS, SKIP, fit, xit, fdescribe, xdescribe, itFOCUS, itSKIP, describeFOCUS, describeSKIP = ...\n"
			.. "return (function(...)\n" .. src .. "\nend)()"
	end
	-- H.require cannot pass varargs, so load directly with the same env the loader builds
	local mod = H.requireWith(path, env.describe, env.it, env.expect, env.beforeEach, env.afterEach, env.beforeAll, env.afterAll,
		env.FOCUS, env.SKIP, env.fit, env.xit, env.fdescribe, env.xdescribe, env.itFOCUS, env.itSKIP, env.describeFOCUS, env.describeSKIP)
	if type(mod) == "function" then mod() end
	local function run(node, prefix)
		for _, f in node.beforeAll do f() end
		for _, c in node.children do
			if c.fn then
				total += 1
				local chain = {}
				local n = c.parent
				while n do table.insert(chain, 1, n); n = n.parent end
				local ok, err = pcall(function()
					for _, nn in chain do for _, f in nn.before do f() end end
					c.fn()
				end)
				for i = #chain, 1, -1 do for _, f in chain[i].after do pcall(f) end end
				if ok then passed += 1 else table.insert(failures, prefix .. " > " .. c.name .. "\n      " .. tostring(err)) end
			else
				run(c, prefix .. " > " .. c.name)
			end
		end
		for _, f in node.afterAll do pcall(f) end
	end
	run(root, path)
end
print(string.format("%d/%d passed", passed, total))
for _, f in failures do print("FAIL " .. f) end
process.exit(if #failures == 0 then 0 else 1)
