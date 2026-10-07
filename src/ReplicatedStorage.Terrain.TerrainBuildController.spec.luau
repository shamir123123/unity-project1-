--!strict
return function()
	describe("TerrainBuildController initial view", function()
		it("yields far terrain work without consuming the near-load frame budget", function()
			local source = script.Parent.Source
			local first = assert(string.find(source, "\tlocal farCount =", 1, true))
			local last = assert(string.find(source, "\tlocal tFar =", first, true))
			local clock, current, maximum, slices = 0, 0, 0, 0
			local order = {}
			for i = 1, 20 do order[i] = i end
			local env = setmetatable({
				order = order, priorityCount = 0,
				myGen = 1, _buildGen = 1, MESH_GROUND = true,
				_frameBudget = 250, BACKGROUND_BUDGET = 4,
				NEAR_FRAC = 0.55, FAR_FRAC = 0.9,
				os = { clock = function() return clock end },
				buildAndPaint = function()
					clock += 1
					current += 1
				end,
				report = function() end,
				RunService = { Heartbeat = { Wait = function()
					maximum = math.max(maximum, current)
					current = 0
					slices += 1
				end } },
			}, { __index = getfenv() })
			local chunk = assert(loadstring(string.sub(source, first, last - 1)))
			setfenv(chunk, env)
			chunk()
			assert(maximum <= 4 and slices >= 5, "far terrain monopolized the loading frame budget")
		end)
		it("meshes only the visible camera neighborhood before entering", function()
			local source = script.Parent.Source
			local first = assert(string.find(source, "\t-- Centroid of the edited chunks", 1, true))
			local last = assert(string.find(source, "\tlocal function report", first, true))
			local eye = Vector3.new(-2800, 135, 100)
			local radius = 500
			local chunk = assert(loadstring(string.sub(source, first, last - 1) .. "\nreturn order, priorityCount, lodEye"))
			local env = setmetatable({
				edited = {},
				workspace = { CurrentCamera = { CFrame = CFrame.new(eye) } },
				Vector3 = Vector3,
				CHUNKS_PER_AXIS = 32, CHUNK_STUDS = 256,
				PRIORITY_RADIUS = 2200, priorityRadius = radius,
				chunkCentreX = function(cx: number) return -4096 + (cx + 0.5) * 256 end,
				chunkCentreZ = function(cz: number) return -4096 + (cz + 0.5) * 256 end,
			}, { __index = getfenv() })
			setfenv(chunk, env)
			local order, count, lodEye = chunk()
			local expected = 0
			for cz = 0, 31 do
				for cx = 0, 31 do
					local dx = math.max(math.abs(-4096 + (cx + 0.5) * 256 - eye.X) - 128, 0)
					local dz = math.max(math.abs(-4096 + (cz + 0.5) * 256 - eye.Z) - 128, 0)
					if dx * dx + eye.Y * eye.Y + dz * dz <= radius * radius then expected += 1 end
				end
			end
			assert(count == expected, "inline terrain work extends beyond the visible camera neighborhood")
			assert(order[1] == 16 * 32 + 5, "terrain was prioritized around the road centroid")
			assert(lodEye == eye, "first terrain LOD used a guessed camera")
		end)
	end)
end
