--!nocheck
-- Run a test file with chosen scripts swapped back to their baseline source.
-- usage: lune run run_orig.luau <test.luau> <Full.Path=file> ...
local process = require("@lune/process")
local fs = require("@lune/fs")
local H = require("./loader")
for i = 2, #process.args do
	local path, file = string.match(process.args[i], "^(.-)=(.+)$")
	local src = fs.readFile(file)
	H.patches[path] = function() return src end
end
local luau = require("@lune/luau")
local test = fs.readFile(process.args[1])
-- the test requires ./loader itself; it gets this same (patched) module table
luau.load(test, { debugName = process.args[1], environment = { require = function(p) if p == "./loader" then return H end return require(p) end }, injectGlobals = true })()
