--!strict
-- RoadSceneryService
-- What a street is LIKE to drive down, published for the router (NavRouter reads
-- graph._scenery[segmentId]). Two numbers per road, both read off the city the player built:
--
--   scenic       -1..1  trees and bushes lining it and open water beside it lift it;
--                       pollution, noise and factory frontage drag it down. Leisure trips
--                       lean toward the nice streets (DriverProfile.LEISURE).
--   residential   0..1  share of the buildings fronting it that are homes. Trucks and
--                       through traffic keep off local streets lined with houses, the way
--                       real drivers keep to the main roads (DriverProfile.FREIGHT/VISITOR).
--
-- A scan scores a slice of roads per frame and swaps the finished table in whole, so the
-- router never sees a half-scored city. It re-runs when the roads, the trees, the buildings
-- or the pollution have changed since the last one, checked every RESCAN_INTERVAL.

local RunService = game:GetService("RunService")

local RoadSceneryService = {}

export type Look = { scenic: number, residential: number }

local SAMPLE_STEP = 24        -- studs between samples along a road
local GREEN_RADIUS = 28       -- props this close to a sample line the street
local GREEN_FULL = 6          -- props near one sample that read as a fully green street
local WATER_REACH = 30        -- studs to either side a sample looks for open water
local FRONTAGE_RADIUS = 48    -- buildings this close to a sample front the street
local SEGMENTS_PER_STEP = 24  -- roads scored per frame while a scan runs
local RESCAN_INTERVAL = 30    -- s between checks for a change worth a re-scan
local CELL = 32               -- spatial hash cell (studs)

-- How each thing moves the look (scenic is clamped to -1..1 afterwards).
local W_GREEN = 0.6
local W_WATER = 0.4
local W_POLLUTION = 0.6
local W_NOISE = 0.3
local W_INDUSTRY = 0.3

local _road: any = nil
local _buildings: any = nil
local _coverage: any = nil
local _terrain: any = nil -- TerrainDataService (optional: absent in headless tests)
local _seaY = 0

local _published: { [number]: Look } = {}
local _signature = ""
local _sinceCheck = math.huge
local _conn: RBXScriptConnection? = nil

type Hash = { [number]: { Vector3 } }
type Frontage = { pos: Vector3, zone: string, id: string }
type Scan = {
	queue: { number },
	at: number,
	fresh: { [number]: Look },
	green: Hash,
	fronts: { [number]: { Frontage } },
	signature: string,
}
local _scan: Scan? = nil

local function cellKey(x: number, z: number): number
	return math.floor(x / CELL) * 65536 + math.floor(z / CELL)
end

local function natureFolder(): Instance?
	local city = workspace:FindFirstChild("_City")
	return city and city:FindFirstChild("Nature")
end

local function propCount(): number
	local f = natureFolder()
	return if f then #f:GetChildren() else 0
end

local function buildingList(): { any }
	if not _buildings or not _buildings.listBuildings then return {} end
	local ok, list = pcall(_buildings.listBuildings)
	return if ok and typeof(list) == "table" then list else {}
end

-- What changes the scores. Traffic noise moves the coverage version on every sample, so the
-- coverage part only counts at the scan interval -- never more than one scan per interval.
local function currentSignature(graph: any, nBuildings: number): string
	local cov = if _coverage and _coverage.getVersion then _coverage.getVersion() else 0
	return `{graph._version or 0}:{propCount()}:{nBuildings}:{cov}`
end

local function snapshotGreen(): Hash
	local hash: Hash = {}
	local f = natureFolder()
	if not f then return hash end
	for _, prop in f:GetChildren() do
		local pos: Vector3? = nil
		if prop:IsA("Model") then
			pos = prop:GetPivot().Position
		elseif prop:IsA("BasePart") then
			pos = prop.Position
		end
		if pos then
			local k = cellKey(pos.X, pos.Z)
			local bucket = hash[k]
			if not bucket then bucket = {}; hash[k] = bucket end
			table.insert(bucket, pos)
		end
	end
	return hash
end

local function snapshotFrontage(list: { any }): { [number]: { Frontage } }
	local hash: { [number]: { Frontage } } = {}
	for _, b in list do
		local pos = b.position
		if typeof(pos) == "Vector3" and not b.abandoned and typeof(b.zone) == "string" then
			local k = cellKey(pos.X, pos.Z)
			local bucket = hash[k]
			if not bucket then bucket = {}; hash[k] = bucket end
			table.insert(bucket, { pos = pos, zone = b.zone, id = tostring(b.bpId) })
		end
	end
	return hash
end

local function countNear(hash: Hash, p: Vector3, radius: number): number
	local r2 = radius * radius
	local n = 0
	local reach = math.ceil(radius / CELL)
	local cx, cz = math.floor(p.X / CELL), math.floor(p.Z / CELL)
	for x = cx - reach, cx + reach do
		for z = cz - reach, cz + reach do
			local bucket = hash[x * 65536 + z]
			if bucket then
				for _, q in bucket do
					local dx, dz = q.X - p.X, q.Z - p.Z
					if dx * dx + dz * dz <= r2 then n += 1 end
				end
			end
		end
	end
	return n
end

local function isWater(x: number, z: number): boolean
	local t = _terrain
	if not t then return false end
	local ok, h = pcall(t.getHeightAt, x, z)
	if not ok or typeof(h) ~= "number" or h >= _seaY then return false end
	local okDry, dry = pcall(t.isDryAt, x, z)
	return not (okDry and dry == true)
end

-- Sample points every SAMPLE_STEP along one lane of the road, with the road's direction.
local function samplesOf(points: { Vector3 }): { { p: Vector3, d: Vector3 } }
	local out = {}
	local carry = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local len = ab.Magnitude
		if len > 1e-3 then
			local d = ab / len
			local s = carry
			while s < len do
				table.insert(out, { p = a + d * s, d = d })
				s += SAMPLE_STEP
			end
			carry = s - len
		end
	end
	if #out == 0 and #points > 0 then
		table.insert(out, { p = points[1], d = Vector3.new(1, 0, 0) })
	end
	return out
end

local function scoreSegment(graph: any, segId: number, scan: Scan): Look?
	local ids = graph._edgesBySegment and graph._edgesBySegment[segId]
	local edge = ids and ids[1] and graph._edges[ids[1]]
	local pts = edge and edge.points
	if not pts or #pts < 2 then return nil end
	local samples = samplesOf(pts)
	local green, water, pollution, noise = 0, 0, 0, 0
	local seen: { [string]: boolean } = {}
	local homes, industry, total = 0, 0, 0
	local fr2 = FRONTAGE_RADIUS * FRONTAGE_RADIUS
	local reach = math.ceil(FRONTAGE_RADIUS / CELL)
	for _, s in samples do
		local p = s.p
		green += math.min(1, countNear(scan.green, p, GREEN_RADIUS) / GREEN_FULL)
		local side = Vector3.new(-s.d.Z, 0, s.d.X) * WATER_REACH
		if isWater(p.X + side.X, p.Z + side.Z) or isWater(p.X - side.X, p.Z - side.Z) then
			water += 1
		end
		if _coverage then
			if _coverage.getPollutionAt then pollution += math.clamp(_coverage.getPollutionAt(p) or 0, 0, 1) end
			if _coverage.getNoiseAt then noise += math.clamp(_coverage.getNoiseAt(p) or 0, 0, 1) end
		end
		local cx, cz = math.floor(p.X / CELL), math.floor(p.Z / CELL)
		for x = cx - reach, cx + reach do
			for z = cz - reach, cz + reach do
				local bucket = scan.fronts[x * 65536 + z]
				if bucket then
					for _, b in bucket do
						if not seen[b.id] then
							local dx, dz = b.pos.X - p.X, b.pos.Z - p.Z
							if dx * dx + dz * dz <= fr2 then
								seen[b.id] = true
								total += 1
								if b.zone == "Residential" then homes += 1
								elseif b.zone == "Industrial" then industry += 1 end
							end
						end
					end
				end
			end
		end
	end
	local n = #samples
	local scenic = W_GREEN * green / n + W_WATER * water / n
		- W_POLLUTION * pollution / n - W_NOISE * noise / n
		- (if total > 0 then W_INDUSTRY * industry / total else 0)
	return {
		scenic = math.clamp(scenic, -1, 1),
		residential = if total > 0 then homes / total else 0,
	}
end

local function beginScan(graph: any, list: { any }, signature: string)
	local queue = {}
	for segId in graph._edgesBySegment or {} do
		table.insert(queue, segId)
	end
	_scan = {
		queue = queue, at = 1, fresh = {},
		green = snapshotGreen(), fronts = snapshotFrontage(list),
		signature = signature,
	}
end

local function stepScan(graph: any, budget: number)
	local scan = _scan
	if not scan then return end
	local last = math.min(#scan.queue, scan.at + budget - 1)
	for i = scan.at, last do
		local segId = scan.queue[i]
		local ok, look = pcall(scoreSegment, graph, segId, scan)
		if ok and look then scan.fresh[segId] = look end
	end
	scan.at = last + 1
	if scan.at > #scan.queue then
		_published = scan.fresh
		graph._scenery = _published
		_signature = scan.signature
		_scan = nil
	end
end

local function graphOf(): any?
	return _road and _road.getNavigationGraph and _road.getNavigationGraph()
end

-- One frame of work: continue a running scan, or (every RESCAN_INTERVAL) start one when the
-- city has changed. Public so tests can drive it without a Heartbeat.
function RoadSceneryService.Step(dt: number)
	local graph = graphOf()
	if not graph then return end
	if _scan then
		stepScan(graph, SEGMENTS_PER_STEP)
		return
	end
	-- A rebuilt graph object (never today, but cheap to survive) gets the last scores back.
	if graph._scenery ~= _published then graph._scenery = _published end
	_sinceCheck += dt
	if _sinceCheck < RESCAN_INTERVAL then return end
	_sinceCheck = 0
	local list = buildingList()
	local signature = currentSignature(graph, #list)
	if signature ~= _signature then
		beginScan(graph, list, signature)
	end
end

-- Score every road now, in one go (tests, or a forced refresh after a city load).
function RoadSceneryService.ScanNow()
	local graph = graphOf()
	if not graph then return end
	local list = buildingList()
	beginScan(graph, list, currentSignature(graph, #list))
	stepScan(graph, math.huge)
end

-- The look of one road, or nil before it has been scored.
function RoadSceneryService.GetLook(segmentId: number): Look?
	return _published[segmentId]
end

function RoadSceneryService.Init(roadService: any, buildingService: any?, coverageService: any?)
	_road = roadService
	_buildings = buildingService
	_coverage = coverageService
	-- TerrainDataService is an infra singleton: required directly, never injected. Optional so
	-- the service still runs (without water) where terrain is not loaded.
	local okT, terrain = pcall(function()
		return require(game:GetService("ServerScriptService").Services.Terrain.TerrainDataService) :: any
	end)
	_terrain = if okT then terrain else nil
	local okC, consts = pcall(function()
		return require(game:GetService("ReplicatedStorage").Terrain.TerrainConstants) :: any
	end)
	_seaY = if okC and typeof(consts.SEA_Y) == "number" then consts.SEA_Y else 0
end

function RoadSceneryService.Bind() end

function RoadSceneryService.Start()
	if _conn then return end
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(RoadSceneryService.Step, dt)
		if not ok then warn("[RoadSceneryService] step failed: " .. tostring(err)) end
	end)
end

return RoadSceneryService
