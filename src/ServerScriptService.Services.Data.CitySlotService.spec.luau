--!strict
return function()
	local function compileSection(source: string, first: string, last: string, result: string, env: any): any
		local a = assert(string.find(source, first, 1, true))
		local b = assert(string.find(source, last, a + #first, true))
		local chunk = assert(loadstring(string.sub(source, a, b - 1) .. "\nreturn " .. result))
		setfenv(chunk, setmetatable(env, { __index = getfenv() }))
		return chunk()
	end

	describe("CitySlotService startup", function()
		it("injects the road edit drain through the real city bootstrap", function()
			local source = script.Parent.Source
			local first = assert(source:find("function CitySlotService.Init(", 1, true))
			local last = assert(source:find("local ok, err = pcall", first, true))
			local env: any = { CitySlotService = {} }
			local drainCalls = 0
			env.RoadService = { waitForPendingEdits = function() drainCalls += 1 return true end }
			setmetatable(env, { __index = function(_, key) return getfenv()[key] or {} end })
			local init = assert(loadstring(source:sub(first, last - 1) .. "\nend\nreturn function() return _roadService.waitForPendingEdits(10) end"))
			setfenv(init, env)
			local drain = init()
			local bootstrap = game.ServerScriptService.Bootstrap.Bootstrap.Source
			local call = assert(bootstrap:match("CitySlotService.Init%([^\n]+"))
			local wire = assert(loadstring(call))
			setfenv(wire, env)
			wire()
			assert(drain() == true and drainCalls == 1, "city loader did not receive the road edit drain")
		end)

		it("only lets the loading player release the restore tail", function()
			local owner, guest = {}, {}
			local env = { _entryHold = { player = owner }, _restoreTailActive = true, releaseEntryHold = function() end }
			local report = compileSection(script.Parent.Source, "local function onReportCityEntered", "-- THE RESTORE TAIL", "onReportCityEntered", env)
			report(guest, false)
			assert(env._tailGo == nil, "guest released the owner's restore tail")
			report(owner, false)
			assert(env._tailGo == owner and env._tailRelease == false, "owner could not release the restore tail")
		end)
		it("keeps failed tail restores frozen and blocks saving incomplete data", function()
			local released = false
			local env = {
				_tailRelease = false,
				warn = function() end,
				Players = { GetPlayerByUserId = function() return nil end },
				releaseEntryHold = function() released = true end,
			}
			local tail = compileSection(script.Parent.Source, "local function runRestoreTail", "local function fireLoadResult", "runRestoreTail", env)
			tail(function() error("fixture restore failure") end)
			assert(type(env._restoreTailError) == "string", "failed tail did not inhibit city saving")
			assert(not released and env._tailRelease == nil, "failed tail resumed the simulation")
			env._sessions = { [5] = { activeSlot = 1, index = {} } }
			env._cityOwnerUserId = 5
			env._releaseRequested = {}
			env.RESTORE_TAIL_SAVE_WAIT = 0
			env._restoreTailActive = false
			local writes = 0
			env.writeIndex = function() writes += 1 end
			local save = compileSection(script.Parent.Source, "local function saveActiveSlot", "-- SAVE SOON.", "saveActiveSlot", env)
			assert(save(5, true) == false, "incomplete city was saved")
			assert(writes == 1, "failed city did not release its index lock")
		end)
		it("cannot save while the incoming city's core is restoring", function()
			local env = { _loadInProgress = true, warn = function() end }
			local save = compileSection(script.Parent.Source, "local function saveActiveSlot", "-- SAVE SOON.", "saveActiveSlot", env)
			local ok, result = pcall(save, 5, false)
			assert(ok and result == false, "save attempted to read or serialize a restoring city")
		end)
		it("keeps a failed-tail save guard when the next save read fails", function()
			local player = { UserId = 5, Parent = true }
			local env = {
				_sessions = { [5] = { persistent = true, index = { slots = { ["1"] = {} } } } },
				_restoreTailError = "previous tail failed",
				holdForEntry = function() end,
				RoadRules = { setDrivingSide = function() end },
				workspace = { SetAttribute = function() end },
				readSlotBlob = function() return nil, false end,
				fireLoadResult = function() end,
			}
			local coreName = if string.find(script.Parent.Source, "local function performLoadCore", 1, true) then "performLoadCore" else "performLoad"
			local core = compileSection(script.Parent.Source, "local function " .. coreName .. "(", "-- ---------- friends' cities", coreName, env)
			core(player, 1)
			assert(env._restoreTailError == "previous tail failed", "failed reload enabled saving an incomplete city")
		end)
		it("does not release another player's loading hold on request rejection", function()
			local owner = { Parent = true }
			local guest = { Parent = true }
			local released = false
			local env = {
				_entryHold = { player = owner }, _loadInProgress = true,
				releaseEntryHold = function() released = true end,
				releaseExpiredEntryHold = function() end,
				_loadResultRemote = { FireClient = function() end },
			}
			local result = compileSection(script.Parent.Source, "local function fireLoadResult", "local function startCitySimIfNeeded", "fireLoadResult", env)
			result(guest, false, {})
			result(owner, false, {})
			assert(not released, "a rejected request resumed a loading city")
		end)
		it("lets the owner reload a city whose deferred restore failed", function()
			local player = { UserId = 5, Parent = true }
			local resumed, reloaded = 0, 0
			local env = {
				_sessions = { [5] = { activeSlot = 1, index = { slots = { ["1"] = {} } } } },
				_cityOwnerUserId = 5, _cityLoaded = true, _restoreTailError = "failed tail",
				MAX_SLOTS = 5,
				PlacesConfig = { isLobby = function() return false end, menuIsElsewhere = function() return false end },
				guestOwnerId = function() return nil end,
				fireLoadResult = function() resumed += 1 end,
				performLoad = function() end,
				task = { spawn = function() reloaded += 1 end },
			}
			local request = compileSection(script.Parent.Source, "local function onRequestLoadSlot(", "local function onRequestDeleteSlot", "onRequestLoadSlot", env)
			request(player, 1)
			assert(reloaded == 1 and resumed == 0, "failed city was re-entered without restoring the previous save")
			env._loadInProgress = false
			env._restoreTailError = nil
			request(player, 1)
			assert(reloaded == 1 and resumed == 1, "healthy city lost idempotent re-entry")
		end)
		it("releases an expired hold only after deferred work completes", function()
			local released = false
			local env = {
				_entryHold = { player = { Parent = true }, deadline = -1 },
				_restoreTailActive = true,
				releaseEntryHold = function() released = true end,
			}
			local release = compileSection(script.Parent.Source, "local function releaseExpiredEntryHold", "local function holdForEntry", "releaseExpiredEntryHold", env)
			release()
			assert(not released, "tail work resumed during an expired entry hold")
			env._restoreTailActive = false
			release()
			assert(released, "completed tail left an expired hold frozen")
		end)
		it("resets the grading budget and terrain gate if a load throws", function()
			local loading, coreLoading, duringLoad = false, false, false
			local terrainEnded = false
			local participant = { canEdit = true, SetAttribute = function(self: any, name: string, value: boolean)
				if name == "CanEditRoads" then self.canEdit = value end
			end }
			local env = {
				TerrainGradeService = { setLoading = function(value: boolean) loading = value end },
				_roadService = { waitForPendingEdits = function() return true end },
				workspace = { SetAttribute = function(_self: any, name: string, value: boolean)
					if name == "CityCoreLoading" then coreLoading = value end
				end },
				Players = { GetPlayers = function() return { participant } end },
				NetMiddleware = { InvalidateCachedAttribute = function() end },
				performLoadCore = function()
					duringLoad = coreLoading and not participant.canEdit
					error("fixture load failure")
				end,
				_terrainDataService = { endCityLoad = function() terrainEnded = true end },
				warn = function() end,
				fireLoadResult = function() end,
			}
			local load = compileSection(script.Parent.Source, "local function performLoad(player:", "-- ---------- friends' cities", "performLoad", env)
			load({ UserId = 5, Parent = true }, 1)
			assert(duringLoad, "core loading did not revoke authoritative edit permissions")
			assert(not loading and not coreLoading and terrainEnded and env._loadInProgress == false, "failed load kept a loading budget or terrain gate active")
		end)
		it("keeps the standing city and its permissions if accepted road edits do not drain", function()
			local coreLoading, coreCalled, failed = false, false, false
			local env = {
				_cityLoaded = true, _loadInProgress = true,
				_roadService = { waitForPendingEdits = function(timeout: number) assert(timeout == 10) return false end },
				TerrainGradeService = { setLoading = function() end },
				workspace = { SetAttribute = function(_self: any, _name: string, value: boolean) coreLoading = value end },
				Players = { GetPlayers = function() error("permissions revoked before road edits drained") end },
				performLoadCore = function() coreCalled = true end,
				fireLoadResult = function(_player: any, ok: boolean) failed = not ok end,
			}
			local load = compileSection(script.Parent.Source, "local function performLoad(player:", "-- ---------- friends' cities", "performLoad", env)
			load({ UserId = 5, Parent = true }, 1)
			assert(failed and not coreCalled and not coreLoading and env._loadInProgress == false, "undrained edits entered core restoration")
			assert(env._cityLoaded == true, "failed drain discarded the standing city")
		end)
		it("rechecks the core save gate after waiting for a restore tail", function()
			local env: any = { _restoreTailActive = true, RESTORE_TAIL_SAVE_WAIT = 30, warn = function() end }
			env.task = { wait = function()
				env._restoreTailActive = false
				env._loadInProgress = true
			end }
			local save = compileSection(script.Parent.Source, "local function saveActiveSlot", "-- SAVE SOON.", "saveActiveSlot", env)
			local ok, result = pcall(save, 5, false)
			assert(ok and result == false, "tail waiter saved after a new core load started")
		end)
		it("announces fresh terrain loading before map generation", function()
			local messages = {}
			local env = {
				blob = nil, player = {},
				sanitizeCameraState = function(value: any) return value end,
				_loadStartedRemote = { FireClient = function(_self: any, _player: any, payload: any) messages[#messages + 1] = payload end },
			}
			local announce = compileSection(script.Parent.Source, "\tlocal cameraState = if typeof(blob)", "\n\tlocal preset =", "nil", env)
			assert(announce == nil and #messages == 1 and messages[1].cameraPending == true, "fresh city did not start the client terrain request")
		end)
	end)
end
