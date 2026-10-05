--!strict
-- TrafficBenchmark
-- How many cars a city can run before it lags, measured instead of guessed. Raises the number
-- of driving cars in steps (NPCDriverService.SpawnTestCarsNear, around the first player so the
-- cars are on screen and on the full-rate AI -- the worst case), lets each step settle, then
-- samples the server's frame time and the frame rate of every client running
-- TrafficBenchClient. Prints a table and the largest car count each device held.
--
-- Studio: press Play, then in the SERVER command bar:
--   require(game.ServerScriptService.Services.Debug.TrafficBenchmark).Run()
--   require(game.ServerScriptService.Services.Debug.TrafficBenchmark).Run({ steps = { 200, 500, 1000 } })
-- A low-end device: publish, join the server from a phone (or a weak laptop), and run the same
-- line from the developer console (F9 > Server) -- the phone's FPS lands in the same table.
-- The test cars are removed at the end; nothing is saved.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local NPCDriverService = require(ServerScriptService.Services.NPC.NPCDriverService)
local Net = require(ReplicatedStorage:WaitForChild("Networker"))

local TrafficBenchmark = {}

export type Options = {
	steps: { number }?,  -- total driving cars to hold at each step
	settle: number?,     -- s at each step before sampling
	sample: number?,     -- s sampled at each step
	spread: number?,     -- studs around the player the test cars start within
	stopServerMs: number?, -- stop climbing once the server's p95 frame passes this
}

export type Row = {
	target: number, cars: number, serverMs: number, serverP95: number, sendKbps: number, memMb: number,
	clients: { [string]: { fps: number, p95: number, mobile: boolean } },
}

local DEFAULT_STEPS = table.freeze({ 100, 250, 500, 750, 1000, 1500, 2000, 3000, 4000 })
local SPAWN_PER_SECOND = 160  -- test cars started per second while topping up (each is an A* search)
local SPAWN_BATCH = 80        -- NPCDriverService.SpawnTestCarsNear's own cap per call
local SMOOTH_FPS = 55
local PLAYABLE_FPS = 30
local SERVER_BUDGET_MS = 1000 / 45 -- the server keeps 45+ steps a second
-- A low-end phone has roughly a third of a desktop's single-core speed; used only when no
-- low-end device reported in.
local LOW_END_FACTOR = 1 / 3

local _running = false
local _reports: { [Player]: { at: number, fps: { number }, p95: { number }, mobile: boolean } } = {}

local function percentile(values: { number }, p: number): number
	if #values == 0 then return 0 end
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.clamp(math.ceil(#sorted * p), 1, #sorted)]
end

local function mean(values: { number }): number
	if #values == 0 then return 0 end
	local sum = 0
	for _, v in values do sum += v end
	return sum / #values
end

local function finite(x: any, lo: number, hi: number): boolean
	return typeof(x) == "number" and x == x and x >= lo and x <= hi
end

local function onReport(player: Player, fps: any, p95: any, mobile: any)
	if not _running or not finite(fps, 0, 1000) or not finite(p95, 0, 10000) then return end
	local now = os.clock()
	local rec = _reports[player]
	if rec and now - rec.at < 0.5 then return end -- one report a second; extras are dropped
	if not rec then
		rec = { at = now, fps = {}, p95 = {}, mobile = mobile == true }
		_reports[player] = rec
	end
	rec.at = now
	table.insert(rec.fps, fps)
	table.insert(rec.p95, p95)
end

local function stat(name: string): number
	local ok, v = pcall(function() return (game:GetService("Stats") :: any)[name] end)
	return if ok and typeof(v) == "number" then v else 0
end

local function memoryMb(): number
	local ok, v = pcall(function() return game:GetService("Stats"):GetTotalMemoryUsageMb() end)
	return if ok and typeof(v) == "number" then v else 0
end

local function spawnCenter(spread: number): Vector3
	for _, p in Players:GetPlayers() do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local a = math.random() * math.pi * 2
			return root.Position + Vector3.new(math.cos(a), 0, math.sin(a)) * math.random() * spread
		end
	end
	local a = math.random() * math.pi * 2
	return Vector3.new(math.cos(a), 0, math.sin(a)) * math.random() * spread
end

-- Start test cars until `target` cars are driving, at most SPAWN_PER_SECOND this second.
-- (The driver's own count catches up on its next frame, so this call's starts are added in.)
local function topUp(target: number, spread: number)
	local budget = SPAWN_PER_SECOND
	local started, misses = 0, 0
	while budget > 0 and misses < 4 do
		local need = target - NPCDriverService.ActiveCarCount() - started
		if need <= 0 then return end
		local want = math.min(need, budget, SPAWN_BATCH)
		local result = NPCDriverService.SpawnTestCarsNear(spawnCenter(spread), want, math.max(200, spread * 0.5))
		local got = tonumber(result.spawned) or 0
		started += got
		budget -= want
		if got == 0 then misses += 1 end
	end
end

local function removeTestCars(): number
	local n = 0
	for _, d in workspace:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("AdminTestCar") == true then
			NPCDriverService.ReleaseDirected(d)
			d:Destroy()
			n += 1
		end
	end
	return n
end

local function report(rows: { Row })
	print("[TrafficBenchmark] target  cars  server ms (p95)  send kbps  mem MB  clients (fps / p95 frame ms)")
	for _, r in rows do
		local parts = {}
		for name, c in r.clients do
			table.insert(parts, string.format("%s%s %.0f/%.1f", name, if c.mobile then "(mobile)" else "", c.fps, c.p95))
		end
		print(string.format("[TrafficBenchmark] %6d %5d %7.1f (%5.1f) %9.0f %7.0f  %s",
			r.target, r.cars, r.serverMs, r.serverP95, r.sendKbps, r.memMb, table.concat(parts, "  ")))
	end
end

-- The largest step each budget held, from the table.
local function summarize(rows: { Row }): { [string]: any }
	local summary: { [string]: any } = { server = 0, clients = {} }
	for _, r in rows do
		if r.serverP95 <= SERVER_BUDGET_MS then summary.server = math.max(summary.server, r.cars) end
		for name, c in r.clients do
			local s = summary.clients[name] or { smooth = 0, playable = 0, mobile = c.mobile }
			if c.fps >= SMOOTH_FPS then s.smooth = math.max(s.smooth, r.cars) end
			if c.fps >= PLAYABLE_FPS then s.playable = math.max(s.playable, r.cars) end
			summary.clients[name] = s
		end
	end
	local best, lowEnd = 0, nil
	for _, s in summary.clients do
		best = math.max(best, s.smooth)
		if s.mobile then lowEnd = math.max(lowEnd or 0, s.playable) end
	end
	summary.highEnd = math.min(summary.server, if next(summary.clients) then best else summary.server)
	summary.lowEndMeasured = lowEnd ~= nil
	summary.lowEnd = math.min(summary.server, lowEnd or math.floor(summary.highEnd * LOW_END_FACTOR))
	return summary
end

function TrafficBenchmark.Run(opts: Options?): { [string]: any }
	assert(RunService:IsServer(), "[TrafficBenchmark] run this on the server")
	if _running then warn("[TrafficBenchmark] already running"); return {} end
	local o: Options = opts or {}
	local steps = o.steps or DEFAULT_STEPS
	local settle = o.settle or 8
	local sample = o.sample or 12
	local spread = o.spread or 600
	local stopMs = o.stopServerMs or 60

	_running = true
	table.clear(_reports)
	workspace:SetAttribute("TrafficBenchActive", true)
	local reportConn = Net.ReportBenchFrameStats.OnServerEvent:Connect(onReport)
	local frames: { number } = {}
	local sampling = false
	local beatConn = RunService.Heartbeat:Connect(function(dt: number)
		if sampling then table.insert(frames, dt * 1000) end
	end)

	local rows: { Row } = {}
	local ok, err = pcall(function()
		for _, target in steps do
			for _ = 1, settle do topUp(target, spread); task.wait(1) end
			table.clear(frames)
			for _, rec in _reports do table.clear(rec.fps); table.clear(rec.p95) end
			local cars: { number } = {}
			sampling = true
			for _ = 1, sample do
				topUp(target, spread)
				task.wait(1)
				table.insert(cars, NPCDriverService.ActiveCarCount())
			end
			sampling = false
			local row: Row = {
				target = target, cars = math.floor(mean(cars) + 0.5),
				serverMs = mean(frames), serverP95 = percentile(frames, 0.95),
				sendKbps = stat("DataSendKbps"), memMb = memoryMb(), clients = {},
			}
			for player, rec in _reports do
				if player.Parent and #rec.fps > 0 then
					row.clients[player.Name] = { fps = mean(rec.fps), p95 = mean(rec.p95), mobile = rec.mobile }
				end
			end
			table.insert(rows, row)
			print(string.format("[TrafficBenchmark] step %d: %d cars, server %.1f ms (p95 %.1f)", target, row.cars, row.serverMs, row.serverP95))
			if row.serverP95 > stopMs then break end
		end
	end)

	sampling = false
	beatConn:Disconnect()
	reportConn:Disconnect()
	workspace:SetAttribute("TrafficBenchActive", nil)
	_running = false
	local removed = removeTestCars()
	if not ok then warn("[TrafficBenchmark] stopped: " .. tostring(err)) end

	report(rows)
	local summary = summarize(rows)
	print(string.format("[TrafficBenchmark] server holds %d cars at %.0f ms p95; high-end (this machine, %d+ FPS): %d cars",
		summary.server, SERVER_BUDGET_MS, SMOOTH_FPS, summary.highEnd))
	print(string.format("[TrafficBenchmark] low-end (%d+ FPS): %d cars %s", PLAYABLE_FPS, summary.lowEnd,
		if summary.lowEndMeasured then "(measured on a mobile client)" else "(estimate: a third of this machine -- join from a phone to measure it)"))
	print(string.format("[TrafficBenchmark] removed %d test cars. Cap to set: CitySimConstants.NPC_MAX_ACTIVE = %d", removed, summary.highEnd))

	local result = { rows = rows, summary = summary }
	local okJson, json = pcall(HttpService.JSONEncode, HttpService, result)
	if okJson then
		local holder = (ServerStorage:FindFirstChild("TrafficBenchmarkResult") :: StringValue?) or Instance.new("StringValue")
		holder.Name = "TrafficBenchmarkResult"
		holder.Value = json
		holder.Parent = ServerStorage
	end
	return result
end

return TrafficBenchmark
