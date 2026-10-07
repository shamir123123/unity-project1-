--!strict
return function()
	local function harness(source: string): any
		local env: any = {
			TerrainMeshView = {}, CHUNKS = 2, _epoch = 1,
			_startupDeferred = {}, _solo = {}, _supers = {}, _superOf = {}, _states = {}, _superVersion = {}, _heightBounds = {},
			queuedSupers = {}, queuedChunks = {}, geometries = 0, destroyed = 0,
			PLAY_SLICE = 0.001, TRI_BUDGET = 20000, _underground = true,
			_sampleY = function() return 0 end, _sampleMat = function() return 0 end,
			_ensureData = function() return true end,
			superMembers = function() return { 0, 1, 2, 3 } end,
			superKeyOf = function() return 0 end,
			chunkDist = function(key: number) return ({ [0] = 0, [1] = 10, [2] = 90, [3] = 110 })[key] end,
			bucketOf = function() return 1 end,
			breathe = function() end, dress = function() end,
   retire = function(part: any, mesh: any) if part then part:Destroy() end;if mesh then mesh:Destroy() end end,
			folder = function() return { ClearAllChildren = function() end } end,
			TerrainMesh = {
				addSkirt = function() end,
				mergeGeo = function() return { tri = {} } end,
			},
		}
		for _, name in { "_editChunks", "_editFine", "_liveOrder", "_pinned", "_queue", "_queued", "_shapeDirty", "_errs", "_drawn", "_caps", "_superQueue", "_superQueued" } do
			env[name] = {}
		end
		env.TerrainMeshView.stop = function() end
  env.startupPlanes = function() return nil end
  env.startupContains = function(key, _, radius) return env.chunkDist(key) <= radius end
		env.enqueueSuper = function(key: number) env.queuedSupers[key] = true end
		env.enqueueChunk = function(key: number) env.queuedChunks[key] = true end
		env.TerrainMesh.buildChunk = function()
			env.geometries += 1
			return { tri = {} }
		end
		env.bake = function()
			if env.onBake then env.onBake() end
			return {
				Parent = true, Size = Vector3.one,
				Destroy = function() env.destroyed += 1 end,
				ApplyMesh = function() end,
			}
		end
		setmetatable(env, { __index = getfenv() })
		local function compile(first: string, last: string, result: string): any
			local a = assert(string.find(source, first, 1, true), "missing " .. first)
			local b = assert(string.find(source, last, a + #first, true), "missing " .. last)
			local chunk = assert(loadstring(string.sub(source, a, b - 1) .. "\nreturn " .. result))
			setfenv(chunk, env)
			return chunk()
		end
		env.mergeMembers = compile("local function mergeMembers", "local function enqueueSuper", "mergeMembers")
		env.enqueue = compile("function enqueue(key:", "-- LOD RE-TIERS", "enqueue")
		env.TerrainMeshView.setStartupArea = compile("function TerrainMeshView.setStartupArea", "-- Is the ground drawn everywhere", "TerrainMeshView.setStartupArea")
		env.TerrainMeshView.reset = compile("function TerrainMeshView.reset()", "return TerrainMeshView", "TerrainMeshView.reset")
		env.buildSuper = compile("local function buildSuper", "-- Hand a block back to its chunks", "buildSuper")
		return env
	end

	describe("TerrainMeshView startup area", function()
		it("builds only visible member geometry while retaining normal merge coverage", function()
			local env = harness(script.Parent.Parent.Source)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 50)
			assert(env.buildSuper(0, Vector3.zero))
			assert(env.geometries == 2, "startup merged geometry outside the visible area")
			assert(env._superOf[0] == 0 and env._superOf[1] == 0, "visible members were not covered")
			assert(env._superOf[2] == nil and env._startupDeferred[2], "excluded member was lost")
		end)
		it("requeues missing merged and solo chunks when startup ends", function()
			local env = harness(script.Parent.Parent.Source)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 50)
			env._solo[3] = true
			env.enqueue(2)
			env.enqueue(3)
			assert(not env.queuedSupers[0] and not env.queuedChunks[3], "far geometry queued before entry")
			env.TerrainMeshView.setStartupArea(nil)
			assert(env.queuedSupers[0] and env.queuedChunks[3], "startup release lost deferred geometry")
			assert(env._startupKeys == nil and next(env._startupDeferred) == nil)
		end)
		it("requeues current membership if startup ends while a partial bake is suspended", function()
			local env = harness(script.Parent.Parent.Source)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 50)
			env.onBake = function()
				env.onBake = nil
				env.TerrainMeshView.setStartupArea(nil)
			end
			assert(not env.buildSuper(0, Vector3.zero), "obsolete partial membership was published")
			assert(env._supers[0] == nil and env.queuedSupers[0] and env.destroyed == 1, "in-flight partial block lost its expansion request or leaked its stale bake")
			assert(env.buildSuper(0, Vector3.zero))
			assert(#env._supers[0].members == 4 and env._superOf[2] == 0 and env._superOf[3] == 0, "expanded block did not recover every member")
		end)
		it("pulls newly visible deferred members forward if the startup area expands", function()
			local env = harness(script.Parent.Parent.Source)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 50)
			env.enqueue(2)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 100)
			assert(env._startupKeys[2] and env._startupDeferred[2] == nil and env.queuedSupers[0], "expanded startup area did not queue its new ground")
		end)
		it("clears startup state when another city resets the renderer", function()
			local env = harness(script.Parent.Parent.Source)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 50)
			env.enqueue(2)
			env.TerrainMeshView.reset()
			assert(env._epoch == 2 and env._startupKeys == nil and next(env._startupDeferred) == nil, "reset retained the outgoing city's startup state")
		end)
		it("discards a partial bake that crosses a city reset", function()
			local env = harness(script.Parent.Parent.Source)
			env.TerrainMeshView.setStartupArea(Vector3.zero, 50)
			env.onBake = function()
				env.onBake = nil
				env.TerrainMeshView.reset()
			end
			assert(env.buildSuper(0, Vector3.zero))
			assert(env.destroyed == 1 and next(env._supers) == nil and next(env._superOf) == nil, "stale partial bake survived city reset")
			assert(env._startupKeys == nil and next(env._startupDeferred) == nil)
		end)
	end)
end
