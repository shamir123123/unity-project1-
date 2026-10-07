--!strict
return function()
	it("keeps future jobs pending and releases deadlines in order", function()
		local Q = require(script.Parent).new()
		local noop = function() end
		for _, at in { 9, 1, 7, 3, 0, 1 } do
			Q.push({at=at,run=noop,valid=function() return true end,failed=noop})
		end
		assert(Q.popDue(-1) == nil, "ran a future construction step")
		local actual = {}
		while Q.nextAt() do
			local job = assert(Q.popDue(10))
			table.insert(actual, job.at)
		end
		assert(table.concat(actual,",") == "0,1,1,3,7,9", "construction deadlines ran out of order")
		assert(Q.popDue(10) == nil)
	end)
	it("clears the outgoing city's pending work", function()
		local Q = require(script.Parent).new()
		Q.push({at=0,run=function() error("old city") end,valid=function() return true end,failed=function() end})
		Q.clear()
		assert(Q.nextAt() == nil and Q.popDue(100) == nil)
	end)
end