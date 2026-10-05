local S = require("./rt/spec")
S.install()
S.verbose = require("@lune/process").env.SPEC_VERBOSE == "1"
S.trace = require("@lune/process").env.SPEC_TRACE == "1"
local W = require("./rt/world")
-- Lab-only patches to stale spec harnesses (they predate helpers the module now calls).
if require("@lune/process").env.SPEC_PATCH == "1" then
	local prev = W.E.sourceFilter
	W.E.sourceFilter = function(full, source)
		if prev then source = prev(full, source) end
		if full:find("CitizenService.spec", 1, true) then
			source = source:gsub("Cars = {laneAsker = {}, ", "Cars = {activeNpcs = function() return 0 end, laneAsker = {}, ")
			source = source:gsub("Cars={GAP_SECONDS=3,", "Cars={activeNpcs=function() return 0 end,GAP_SECONDS=3,")
		end
		return source
	end
end
W.E.preloadSources()
local process = require("@lune/process")
local mod = process.args[1]
local spec = W.req(mod)
local r = S.run(spec)
print(string.format("SPEC %s pass=%d fail=%d", mod, r.pass, r.fail))
for _, f in r.failures do print("  FAIL " .. f) end
