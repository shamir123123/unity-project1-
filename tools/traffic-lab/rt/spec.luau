-- Minimal TestEZ shim: runs a `return function() describe/it/expect end` spec module.
local E = require("./engine")
local S = {}
local results = { pass = 0, fail = 0, failures = {} }
local prefix = {}
local beforeEachFns = {}
local function makeExpect(v)
	local function fail(msg) error(msg, 3) end
	local api = {}
	api.to = api; api.be = api; api.never = nil
	function api.equal(x) if v ~= x then fail(("expected %s to equal %s"):format(tostring(v), tostring(x))) end end
	api.ok = nil
	setmetatable(api, { __index = function(_, k)
		if k == "ok" then if not v then fail("expected value to be ok") end return api end
		return nil
	end })
	function api.near(x, eps) if math.abs(v - x) > (eps or 1e-7) then fail(("expected %s near %s"):format(tostring(v), tostring(x))) end end
	function api.throw() local ok = pcall(v); if ok then fail("expected throw") end end
	return api
end
local env = {
	describe = function(name, fn) table.insert(prefix, name); fn(); table.remove(prefix) end,
	it = function(name, fn)
		if S.verbose then require("@lune/stdio").ewrite("RUN " .. table.concat(prefix, " / ") .. " / " .. name .. "\n") end
		for _, b in beforeEachFns do b() end
		local ok, err = xpcall(fn, function(e) return if S.trace then debug.traceback(tostring(e), 2) else e end)
		local full = table.concat(prefix, " / ") .. " / " .. name
		if ok then results.pass += 1 else results.fail += 1; table.insert(results.failures, full .. ": " .. tostring(err)) end
	end,
	expect = makeExpect,
	beforeEach = function(fn) table.insert(beforeEachFns, fn) end,
	FOCUS = function() end, SKIP = function() end,
}
function S.install()
	local orig = E.makeEnv
	E.makeEnv = function(s)
		local e = orig(s)
		for k, v in env do e[k] = v end
		return e
	end
end
function S.run(specFn)
	specFn()
	return results
end
return S
