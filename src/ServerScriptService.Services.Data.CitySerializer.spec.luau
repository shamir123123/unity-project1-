--!strict
return function()
	describe("CitySerializer deferred tail", function()
		it("fails a core load instead of accepting partially restored plots", function()
			local source = script.Parent.Source
			local first = assert(string.find(source, "\tif _plotService and _plotService.restore then", 1, true))
			local last = assert(string.find(source, '\tlap("plots")', first, true))
			local env = setmetatable({
				blob = {}, warn = function() end,
				_plotService = { restore = function() error("fixture plot failure") end },
			}, { __index = getfenv() })
			local chunk = assert(loadstring(string.sub(source, first, last - 1) .. "\nreturn true"))
			setfenv(chunk, env)
			local ok, err = chunk()
			assert(ok == false and string.find(tostring(err), "plot restore failed", 1, true), "partially restored plots were accepted")
		end)
		it("finishes isolated tail stages and reports any incomplete restore", function()
			local source = script.Parent.Source
			local first = assert(string.find(source, "\tlocal function tail()", 1, true))
			local last = assert(string.find(source, "\tif deferTail then", first, true))
			local ranCitizen, ranCreation = false, false
			local env = setmetatable({
				blob = {}, lap = function() end, warn = function() end,
				_natureService = { restore = function() error("fixture nature failure") end },
				_citizenService = { restore = function() ranCitizen = true end },
				_creationPlaceService = { restore = function() ranCreation = true end },
			}, { __index = getfenv() })
			local chunk = assert(loadstring(string.sub(source, first, last - 1) .. "\nreturn tail"))
			setfenv(chunk, env)
			local ok, err = pcall(chunk())
			assert(not ok and string.find(tostring(err), "nature", 1, true), "partial restore was reported as complete")
			assert(ranCitizen and ranCreation, "one failed tail stage prevented later restore stages")
		end)
	end)
end
