--!strict
return function()
	local function harness(source: string): any
		local sent: { any } = {}
		local warnings: { any } = {}
		local env = setmetatable({
			_roads = {}, _topologyRevision = 23, MAX_EDGE_ID_LEN = 64, MAX_BATCH_REMOVE = 256,
			_placeRemote = {}, _roundaboutPresetRemote = {},
			_placeResultRemote = { FireClient = function(_, _, ...) table.insert(sent, { ... }) end },
			canPlayerEditRoads = function() return true end,
			placeCooldownActive = function() return false end,
			NetMiddleware = { CheckServerRate = function() return true end },
			warn = function(...) table.insert(warnings, { ... }) end,
		}, { __index = getfenv() })
		local start = assert(string.find(source, "local function clientToken", 1, true))
		local finish = assert(string.find(source, "local function onTurnPermissionRequest", start, true))
		local fn = assert(loadstring(string.sub(source, start, finish - 1)
			.. "\nreturn {place=onPlaceRequest,preset=onRoundaboutPresetRequest,remove=onRemoveSegmentRequest}"))
		setfenv(fn, env)
		return { api = fn(), env = env, sent = sent, warnings = warnings, player = { Name = "TestPlayer", Parent = true } }
	end

	describe("road request results", function()
		it("blocks road mutation during city core restore even with Studio edit override", function()
			local source = script.Parent.Source
			local start = assert(source:find("local function canPlayerEditRoads", 1, true))
			local finish = assert(source:find("local function canProcessEditNow", start, true))
			local attributes = { RoadEditOpen = true, CityCoreLoading = false }
			local owner = true
			local env = setmetatable({
				workspace = { GetAttribute = function(_, key) return attributes[key] end },
				NetMiddleware = { GetCachedAttribute = function() return owner end },
			}, { __index = getfenv() })
			local fn = assert(loadstring(source:sub(start, finish - 1) .. "\nreturn canPlayerEditRoads"))
			setfenv(fn, env);local canEdit = fn()
			assert(canEdit({}), "ordinary Studio edit permission changed")
			attributes.CityCoreLoading = true
			assert(not canEdit({}), "Studio override bypassed city core restore gate")
			attributes.CityCoreLoading = false;attributes.RoadEditOpen = false
			assert(canEdit({}), "owner edit permission did not recover")
			owner = false;assert(not canEdit({}), "nonowner gained road edit permission")
		end)
		it("rejects the matching prediction when primary placement throws", function()
			local h = harness(script.Parent.Source)
			h.env._roads.placeFromRequest = function() error("grading fixture failed") end
			h.api.place(h.player, { clientToken = 17 })
			assert(#h.sent == 1 and h.sent[1][1] == false, "failed primary got no rejection")
			assert(h.sent[1][3] == "place" and h.sent[1][4] == 17, "failed primary lost its token")
			assert(#h.warnings == 1, "primary failure was swallowed")
		end)

		it("keeps a committed primary accepted when its best-effort twin throws", function()
			local h = harness(script.Parent.Source)
			local calls = 0
			h.env._roads.placeFromRequest = function()
				calls += 1
				if calls == 2 then error("twin fixture failed") end
				return true
			end
			h.api.place(h.player, { clientToken = 18, twin = {} })
			assert(calls == 2 and #h.sent == 1 and h.sent[1][1] == true, "twin failure rejected committed primary")
			assert(h.sent[1][4] == 18 and #h.warnings == 1, "twin failure lost correlation or log")
		end)

		it("does not report preset rejection as an unrelated placement result", function()
			local h = harness(script.Parent.Source)
			h.env.canPlayerEditRoads = function() return false end
			h.api.preset(h.player, {})
			assert(#h.sent == 1 and h.sent[1][3] == "edit", "preset rejection consumes a placement flight")
		end)

		it("returns rejected edit tokens after an owning service failure", function()
			local h = harness(script.Parent.Source)
			h.env.validSmallString = function() return true end
			h.env._roads.removeSegmentFromRequest = function() error("delete fixture failed") end
			h.api.remove(h.player, 7, nil, 19)
			assert(#h.sent == 1 and h.sent[1][1] == false and h.sent[1][3] == "edit" and h.sent[1][4] == 19,
				"failed edit lost rejection or token")
		end)

		it("does not echo invalid client sequence tokens", function()
			local h = harness(script.Parent.Source)
			h.env._roads.placeFromRequest = function() return false, "invalid road" end
			h.api.place(h.player, { clientToken = 0 / 0 })
			assert(#h.sent == 1 and h.sent[1][4] == nil, "invalid token crossed the transport boundary")
		end)
	end)
	describe("accepted road request lifetime", function()
		local function fixture()
			local source = script.Parent.Source
			local start = assert(source:find("local _pendingEdits = 0", 1, true))
			local finish = assert(source:find("-- ---------------------------------------------------------------- helpers", start, true))
			local warnings = {}
			local env = setmetatable({ RoadReplicationService = {}, warn = function(message) table.insert(warnings, message) end },
				{ __index = getfenv() })
			local loader = assert(loadstring(source:sub(start, finish - 1) .. "\nreturn trackedRequest"))
			setfenv(loader, env)
			return loader(), env.RoadReplicationService, warnings
		end
		it("stays busy through a yielding accepted request and releases after success or error", function()
			local track, transport, warnings = fixture()
			local player = { Name = "Tester" }
			local received
			local handler = track(function(actor, ...)
				received = table.pack(...)
				assert(actor == player)
				coroutine.yield("accepted")
			end, "fixture edit")
			local thread = coroutine.create(function() handler(player, true, nil, 17) end)
			assert(coroutine.resume(thread) and not transport.isEditIdle(), "accepted request escaped the drain while yielding")
			assert(received.n == 3 and received[1] == true and received[2] == nil and received[3] == 17, "transport arguments changed")
			assert(coroutine.resume(thread) and transport.isEditIdle(), "completed request leaked its busy state")
			track(function() error("fixture failure") end, "fixture edit")(player)
			assert(transport.isEditIdle() and #warnings == 1, "failed request leaked its busy state or lost its log")
		end)
		it("tracks every mutating remote binding, including undo and redo", function()
			local track, transport = fixture()
			local source = script.Parent.Source
			local callbacks, env = {}, {}
			local signals = { Connect = function() end }
			env.RoadReplicationService = transport;env.trackedRequest = track
			env.NetMiddleware = { RegisterServerRateLimit = function() end }
			env.RoadConstants = { PLACE_COOLDOWN = .1 };env.CONNECTION_EDIT_COOLDOWN = .15
			env.Players = { PlayerAdded = signals, PlayerRemoving = signals, GetPlayers = function() return {} end }
			env._roadTrafficRemote = {};env._laneCurvesRemote = {}
			local names = {
				_placeRemote = "onPlaceRequest", _placeRoundaboutRemote = "onPlaceRoundaboutRequest",
				_turnPermRemote = "onTurnPermissionRequest", _laneTurnPermRemote = "onLaneTurnPermissionRequest",
				_connectionHandleRemote = "onConnectionHandleRequest", _connectionRemote = "onConnectionRequest",
				_resetConnectionsRemote = "onResetConnectionsRequest", _laneChangeConnRemote = "onLaneChangeConnectionRequest",
				_replaceSegRemote = "onReplaceSegmentRequest", _removeSegRemote = "onRemoveSegmentRequest",
				_removeSegsRemote = "onRemoveSegmentsRequest", _moveRemote = "onMoveRoadRequest",
				_setRoadNameRemote = "onSetRoadNameRequest", _roundaboutPresetRemote = "onRoundaboutPresetRequest",
				_undoRemote = "onUndoRequest", _redoRemote = "onRedoRequest",
			}
			for remote, name in names do
				env[remote] = { OnServerEvent = { Connect = function(_, callback) callbacks[name] = callback end } }
				env[name] = function() coroutine.yield("accepted") end
			end
			setmetatable(env, { __index = getfenv() })
			local start = assert(source:find("function RoadReplicationService.bind()", 1, true))
			local finish = assert(source:find("return RoadReplicationService", start, true))
			local loader = assert(loadstring(source:sub(start, finish - 1)))
			setfenv(loader, env);loader();transport.bind()
			local count = 0
			for name, callback in callbacks do
				count += 1
				local thread = coroutine.create(function() callback({ Name = "Tester" }) end)
				assert(coroutine.resume(thread) and not transport.isEditIdle(), name .. " bypassed the accepted edit drain")
				assert(coroutine.resume(thread) and transport.isEditIdle(), name .. " leaked accepted edit state")
			end
			assert(count == 16, "a mutating road remote was omitted")
		end)
	end)

	it("rejects dictionary and sparse delete batches before road work while accepting the cap",function()
		local source=script.Parent.Source
		local a=assert(source:find("local function onRemoveSegmentsRequest",1,true))
		local b=assert(source:find("local function onTurnPermissionRequest",a,true))
		local work,rejections=0,0
		local env=setmetatable({
			MAX_BATCH_REMOVE=256,clientToken=function(t) return t end,
			acceptEdit=function() return true end,
			sendEditResult=function(_player,_token,ok) if not ok then rejections+=1 end end,
			runEdit=function(_player,_token,fn) fn() end,
			_roads={removeSegmentsFromRequest=function() work+=1;return true end},
		},{__index=getfenv()})
		local loader=assert(loadstring(source:sub(a,b-1).."\nreturn onRemoveSegmentsRequest"));setfenv(loader,env)
		local remove=loader()
		local dictionary:any={ {id=1} }
		for i=1,257 do dictionary["extra"..i]={id=i} end
		remove({},dictionary,1)
		assert(work==0 and rejections==1,"dictionary entries bypassed the delete-work cap")
		remove({},{[1]={id=1},[256]={id=2}},2)
		assert(work==0 and rejections==2,"sparse batch reached road mutation")
		local valid={};for i=1,256 do valid[i]={id=i} end
		remove({},valid,3)
		assert(work==1 and rejections==2,"valid maximum delete batch was rejected")
	end)

end
