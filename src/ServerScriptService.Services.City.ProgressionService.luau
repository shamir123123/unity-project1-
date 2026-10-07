--!strict
local GameSpeed = require(game:GetService("ReplicatedStorage").GameSpeed)
-- ProgressionService
-- The reward loop (CS2-style): XP -> 20 MILESTONES (cash + Development Points + map tile
-- permits + free unlocks) -> the Development Tree (DevelopmentTree nodes bought with DP via
-- RequestDevUnlock). Reads other domains through their public getters only, credits rewards
-- through CityEconomyService, toasts via Notify, and replicates a snapshot
-- (SyncProgression) for the client panel.
-- Placement gating: Road/Emergency/Education/Transit services call isRoadAllowed /
-- isPlaceableAllowed through callbacks injected in Bootstrap.
-- State persists with the city save (CitySerializer key "progression").
--
-- XP comes from what the player PLACES, never from the clock (user, 2026-10-02): every zoned
-- building per LEVEL it reaches, every prop (trees, bushes, rocks, shapes, car parks), road
-- length, service buildings and transit routes each have an XP amount.
--   * Paid on NEW PEAKS only -- bulldozing and rebuilding re-earns nothing.
--   * Props, roads, services and routes only count up to what the POPULATION justifies, so
--     an empty map covered in trees or asphalt is worth what a village's is worth.
-- Earned XP lands in a BANK that pays into the bar at no more than
-- MilestoneUnlocks.XP_RATE_CAP_PER_MIN in REAL time: the whole ladder takes ~6 h even
-- placing flat out, and a normal pace of play takes days.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Telemetry = require(script.Parent.Parent.Util.Telemetry)
local DevelopmentTree = require(ReplicatedStorage.City.DevelopmentTree)
local MilestoneUnlocks = require(ReplicatedStorage.City.MilestoneUnlocks)
local TerritoryGrid = require(ReplicatedStorage.City.TerritoryGrid)

local ProgressionService = {}

local TICK = 2.0
-- Where in each period this sim runs, as a share of it (1.25 s at 1x speed). Staggered across
-- the city sims (see their Start loops) so no two land in the same frame.
local TICK_PHASE = 0.625
local GROWTH_EVERY_N_TICKS = 5 -- growth XP is a few full-domain scans; ~every 10 s, not every tick
local XP_SYNC_MIN_GAP = 3.0 -- min seconds between XP-only snapshot broadcasts
local UNLOCK_COOLDOWN = 0.2 -- per-player RequestDevUnlock rate limit

-- 2026-10-02 second pass (user: "you level up too fast"): an empty map used to earn ~350 XP
-- (Large Village) before anyone moved in. Now ~3.5 XP per resident, Tiny Town ~300 pop.
local XP_PER_BUILDING_LEVEL = 3 -- a level-3 tower has paid 9 by the time it tops out
local XP_PER_PROP = 1
local PROPS_FREE = 20            -- props that earn before anyone lives here
local PROPS_PER_RESIDENT = 0.5   -- and the further props each resident justifies
local XP_PER_ROAD_METER = 0.5
local ROAD_M_FREE = 100          -- road that earns XP before anyone lives here
local ROAD_M_PER_RESIDENT = 3    -- and the further road each resident justifies
local XP_PER_SERVICE_BUILDING = 25
local SERVICES_FREE = 1
local RESIDENTS_PER_SERVICE = 80
local XP_PER_TRANSIT_ROUTE = 50
local ROUTES_FREE = 1
local RESIDENTS_PER_ROUTE = 300

local XP_CAP_PER_SEC = MilestoneUnlocks.XP_RATE_CAP_PER_MIN / 60
-- Real seconds one tick may credit. A server hitch or a long pause must not pay out the
-- whole gap at once -- that time is simply lost to the cap, never gained.
local MAX_TICK_DT = TICK * 1.5

-- Grace window after boot / city load: anything the loaded city already satisfies
-- (template roads, restored population, pre-progression saves) is adopted SILENTLY as the
-- starting peaks -- otherwise loading a big save showers the player with XP for things
-- they did long ago.
-- ponytail: fixed-delay baseline; swap to a "restore finished" signal if city
-- restores ever get slow enough to outlast it.
local BASELINE_GRACE = 8.0

local MILESTONES = MilestoneUnlocks.Ladder

type Peaks = { bld: number, props: number, road: number, svc: number, routes: number }

local _net: any
local _stats: any
local _economy: any
local _roads: any
local _education: any
local _emergency: any
local _transit: any
local _syncRemote: RemoteEvent

local _tier = 1 -- highest MILESTONES index ever reached this city (never drops)
local _xp = 0   -- credited XP (fractional; the client sees it floored)
local _bank = 0 -- earned but not yet credited (drains at XP_CAP_PER_SEC)
local _peak: Peaks = { bld = 0, props = 0, road = 0, svc = 0, routes = 0 }
local _buildingService: any = nil
local _natureService: any = nil
local _lastTickAt = os.clock()
local _ratePerMin = 0 -- smoothed credit rate, for the panel
local _buildingCount = 0 -- for the panel
local _unlocked: { [string]: boolean } = {} -- bought DevelopmentTree node ids (cost-0 nodes are implicit)
local _baselineAt: number? = nil
local _running = false
local _growthTick = 0
local _lastSyncAt = 0
local _lastSyncedXp = -1
local _lastUnlockAt: { [Player]: number } = {}

local function currentPop(): number
	return math.max(0, tonumber(_stats.getPopulation()) or 0)
end

-- What the city has now, capped by what its population justifies.
local function measure(): Peaks
	local pop = currentPop()
	local services = #_emergency.list() + #_education.list() + #_transit.getDepots()
	local levels, count = 0, 0
	if _buildingService then
		for _, byLevel in _buildingService.getBuildingCounts() do
			for lvl, n in byLevel do
				levels += lvl * n
				count += n
			end
		end
	end
	_buildingCount = count
	local props = if _natureService then _natureService.countProps() else 0
	return {
		bld = levels,
		props = math.min(props, PROPS_FREE + pop * PROPS_PER_RESIDENT),
		road = math.min(tonumber(_roads.getTotalRoadLengthMeters()) or 0, ROAD_M_FREE + pop * ROAD_M_PER_RESIDENT),
		svc = math.min(services, SERVICES_FREE + pop // RESIDENTS_PER_SERVICE),
		routes = math.min(#_transit.getRouteIds(), ROUTES_FREE + pop // RESIDENTS_PER_ROUTE),
	}
end

-- XP for every new high the city just set. Moves the peaks.
local function growthXp(): number
	local now = measure()
	local gained = 0
	local function ratchet(key: string, xpEach: number)
		local was = (_peak :: any)[key] :: number
		local v = (now :: any)[key] :: number
		if v > was then
			gained += (v - was) * xpEach;
			(_peak :: any)[key] = v
		end
	end
	ratchet("bld", XP_PER_BUILDING_LEVEL)
	ratchet("props", XP_PER_PROP)
	ratchet("road", XP_PER_ROAD_METER)
	ratchet("svc", XP_PER_SERVICE_BUILDING)
	ratchet("routes", XP_PER_TRANSIT_ROUTE)
	return gained
end

local function adoptPeaks()
	local now = measure()
	for key, v in now :: any do
		(_peak :: any)[key] = math.max((_peak :: any)[key], v)
	end
end

-- == Development Points ========================================================
local function dpEarned(): number
	local sum = 0
	for i = 1, _tier do sum += MILESTONES[i].dp end
	return sum
end

local function dpSpent(): number
	local sum = 0
	for id in _unlocked do
		local node = DevelopmentTree.ById[id]
		if node then sum += node.cost end
	end
	return sum
end

-- Sandbox cities (chosen at creation, replicated on workspace) skip the Development
-- Point economy entirely: every node is available from the first minute.
local function isSandbox(): boolean
	return workspace:GetAttribute("Sandbox") == true
end

local function isNodeUnlocked(id: string): boolean
	local node = DevelopmentTree.ById[id]
	if not node then return false end
	if isSandbox() then return true end
	if node.milestone and _tier < node.milestone then return false end
	return node.cost == 0 or _unlocked[id] == true
end

-- Funding-effect multipliers from the unlocked EXTRAS, by funding category. Cached:
-- getFunding is called per building per coverage pass, so this must not walk the tree
-- on every call. Recomputed whenever the unlock set or the tier changes.
local _boostByCategory: { [string]: number } = {}

local function rebuildBoosts()
	table.clear(_boostByCategory)
	for _, node in DevelopmentTree.Nodes do
		local boost = node.boost
		if boost and isNodeUnlocked(node.id) then
			_boostByCategory[boost.category] = (_boostByCategory[boost.category] or 1) * boost.mult
		end
	end
end

-- Injected into CityEconomyService (setFundingBoost) by Bootstrap. Multiplies what a
-- funding level DOES, never what it costs.
function ProgressionService.getFundingBoost(category: string): number
	return _boostByCategory[category] or 1
end

-- The milestone tier this city has reached, 1 (Founding) to 20 (Megalopolis). Read by
-- TerritoryService, which turns it into how much land the city may hold.
function ProgressionService.getTier(): number
	return _tier
end

-- Placement gates. Bootstrap injects these into Road/Emergency/Education/Transit via
-- their setUnlockCheck, so the SERVER refuses a locked placement -- the client panel
-- hiding the card is presentation, not enforcement.
-- Two sources, checked in order: a MILESTONE grant (reaching the tier IS the unlock),
-- then a DevelopmentTree node (bought with DP). Anything neither claims is ungated.
function ProgressionService.isRoadAllowed(roadType: string): boolean
	if isSandbox() then return true end
	local baseId = DevelopmentTree.baseRoadId(roadType)
	local grantedAt = MilestoneUnlocks.roadMilestone(baseId)
	if grantedAt then return _tier >= grantedAt end
	local nodeId = DevelopmentTree.RoadNode[baseId]
	return nodeId == nil or isNodeUnlocked(nodeId)
end

function ProgressionService.isPlaceableAllowed(key: string): boolean
	if isSandbox() then return true end
	local grantedAt = MilestoneUnlocks.placeableMilestone(key)
	if grantedAt then return _tier >= grantedAt end
	local nodeId = DevelopmentTree.PlaceableNode[key]
	return nodeId == nil or isNodeUnlocked(nodeId)
end

-- Zoning density ("Medium" / "High" / "Mixed"). Only milestones grant these; Low and
-- anything the ladder does not name is ungated. Injected into PlotService by Bootstrap.
function ProgressionService.isDensityAllowed(density: string): boolean
	if isSandbox() then return true end
	local grantedAt = MilestoneUnlocks.zoneMilestone(density)
	return grantedAt == nil or _tier >= grantedAt
end

local function tryUnlock(nodeId: string): (boolean, string?)
	local node = DevelopmentTree.ById[nodeId]
	if not node then return false, "unknown node" end
	-- Checked before the cost-0 shortcut: a free node still behind its milestone is
	-- "not yet", not "already unlocked".
	if node.milestone and _tier < node.milestone then
		return false, ("%s (milestone %d)"):format(MILESTONES[node.milestone].name, node.milestone)
	end
	if node.cost == 0 or _unlocked[nodeId] then return false, "already unlocked" end
	for _, reqId in node.requires do
		if not isNodeUnlocked(reqId) then
			local req = DevelopmentTree.ById[reqId]
			return false, ("requires %s"):format(if req then req.name else reqId)
		end
	end
	if node.cost > dpEarned() - dpSpent() then return false, "not enough Development Points" end
	_unlocked[nodeId] = true
	rebuildBoosts()
	return true
end

local function formatMoney(n: number): string
	local s = tostring(math.floor(math.max(0, n)))
	while true do
		local replaced: number
		s, replaced = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then break end
	end
	return "$" .. s
end

-- event rides only the broadcast for a LIVE milestone crossing, so the client can
-- tell a celebration apart from join/load/baseline snapshots.
local function snapshot(event: { [string]: any }?): { [string]: any }
	local sandbox = isSandbox()
	local unlocked = {}
	if sandbox then
		-- Report the whole tree as bought so the client panel draws it unlocked without
		-- needing its own copy of the sandbox rule.
		for id in DevelopmentTree.ById do table.insert(unlocked, id) end
	else
		for id in _unlocked do table.insert(unlocked, id) end
	end
	local earned = dpEarned()
	local spent = dpSpent()
	return {
		tier = _tier, xp = math.floor(_xp), milestones = MILESTONES, event = event,
		buildings = _buildingCount, rate = math.floor(_ratePerMin + 0.5), cap = MilestoneUnlocks.XP_RATE_CAP_PER_MIN,
		dp = { earned = earned, spent = spent, available = if sandbox then 0 else earned - spent },
		unlocked = unlocked,
	}
end

-- Injected by Bootstrap. A milestone is what raises how much LAND the city may hold, so
-- the tile panel has to hear about one landing here rather than on the next unrelated
-- territory change. Optional: a missing one must never stop a milestone paying out.
local _territoryService: any = nil

function ProgressionService.setTerritoryService(svc: any)
	_territoryService = svc
end

-- Injected by Bootstrap: the buildings XP is counted from (getBuildingCounts).
function ProgressionService.setBuildingService(svc: any)
	_buildingService = svc
end

-- Injected by Bootstrap: the props XP is counted from (countProps).
function ProgressionService.setNatureService(svc: any)
	_natureService = svc
end

local function broadcast(event: { [string]: any }?)
	_syncRemote:FireAllClients(snapshot(event))
	if _territoryService then
		pcall(_territoryService.onProgressionChanged)
	end
	_lastSyncAt = os.clock()
	_lastSyncedXp = math.floor(_xp)
end

local function toast(text: string)
	_net.Notify:FireAllClients({ text = text, kind = "success", duration = 6 })
end

local function payOut(fromTier: number, toTier: number): { [string]: any }
	local moneySum, dpSum = 0, 0
	for i = fromTier + 1, toTier do
		moneySum += MILESTONES[i].money
		dpSum += MILESTONES[i].dp
	end
	local tiles = TerritoryGrid.allowanceFor(toTier) - TerritoryGrid.allowanceFor(fromTier)
	if moneySum > 0 then _economy.credit(moneySum) end
	local name = MILESTONES[toTier].name
	toast(("Milestone reached: %s!  +%s  +%d DP  +%d map tiles"):format(name, formatMoney(moneySum), dpSum, tiles))
	Telemetry.milestone(toTier, name)
	return { type = "milestone", tier = toTier, name = name, reward = moneySum, dp = dpSum, tiles = tiles }
end

function ProgressionService.tick()
	local now = os.clock()
	local dt = math.min(now - _lastTickAt, MAX_TICK_DT)
	_lastTickAt = now

	if _baselineAt then
		if now < _baselineAt then return end
		-- Silent sweep: adopt what the loaded city already has as the starting peaks.
		_baselineAt = nil
		adoptPeaks()
		_tier = math.max(_tier, MilestoneUnlocks.tierFor(_xp))
		rebuildBoosts()
		broadcast()
		return
	end

	_growthTick += 1
	if _growthTick >= GROWTH_EVERY_N_TICKS then
		_growthTick = 0
		_bank += growthXp()
	end

	local credit = math.min(_bank, XP_CAP_PER_SEC * dt)
	_bank -= credit
	_xp += credit
	_ratePerMin += (credit / math.max(dt, 1e-3) * 60 - _ratePerMin) * 0.2

	local event: { [string]: any }? = nil
	local newTier = MilestoneUnlocks.tierFor(_xp)
	if newTier > _tier then
		event = payOut(_tier, newTier)
		_tier = newTier
		-- New tier can grant NEEDS outright and make EXTRAS available: both change what
		-- counts as unlocked, so the boost cache has to follow the tier.
		rebuildBoosts()
	end

	if event then
		broadcast(event)
	elseif math.floor(_xp) ~= _lastSyncedXp and now - _lastSyncAt >= XP_SYNC_MIN_GAP then
		broadcast() -- keep the client XP bar moving between milestones
	end
end

function ProgressionService.serialize(): { [string]: any }
	local unlocked = {}
	for id in _unlocked do
		table.insert(unlocked, id)
	end
	return {
		tier = _tier, xp = _xp, bank = _bank, unlocked = unlocked,
		peak = { bld = _peak.bld, props = _peak.props, road = _peak.road, svc = _peak.svc, routes = _peak.routes },
	}
end

local function num(v: any): number
	local n = tonumber(v)
	return if n and n == n and n >= 0 and n < 1e12 then n else 0
end

-- nil / invalid blob = fresh city or pre-progression save: reset and re-baseline.
function ProgressionService.restore(blob: any)
	_tier = 1
	_xp = 0
	_bank = 0
	_growthTick = 0
	_ratePerMin = 0
	_peak = { bld = 0, props = 0, road = 0, svc = 0, routes = 0 }
	table.clear(_unlocked)
	_baselineAt = os.clock() + BASELINE_GRACE
	if typeof(blob) == "table" and typeof(blob.tier) == "number" then
		-- The tier ratchets: a save from before the ladder was re-paced keeps its milestone,
		-- and the bar starts at that milestone's threshold.
		_tier = math.clamp(math.floor(blob.tier), 1, #MILESTONES)
		_xp = math.max(num(blob.xp), MILESTONES[_tier].xp)
		_bank = num(blob.bank)
		if typeof(blob.unlocked) == "table" then
			for _, id in blob.unlocked do
				local node = if typeof(id) == "string" then DevelopmentTree.ById[id] else nil
				if node and node.cost > 0 then _unlocked[id] = true end
			end
		end
		-- A save whose unlock spend exceeds its earned DP is corrupt; wipe the unlocks
		-- rather than let available DP sit negative forever.
		if dpSpent() > dpEarned() then table.clear(_unlocked) end
		-- Saves with peaks resume exactly; older ones adopt the loaded city at baseline.
		if typeof(blob.peak) == "table" then
			_peak = { bld = num(blob.peak.bld), props = num(blob.peak.props), road = num(blob.peak.road), svc = num(blob.peak.svc), routes = num(blob.peak.routes) }
			-- A save from before building/prop XP lacks those peaks: adopt the city it already
			-- has at baseline instead of paying out for everything in it.
			if blob.peak.bld ~= nil and blob.peak.props ~= nil then _baselineAt = nil end
		end
	end
	_lastTickAt = os.clock()
	rebuildBoosts()
	broadcast()
end

function ProgressionService.Init(net: any, cityStatsService: any, economyService: any, roadService: any, educationService: any, emergencyService: any, transitService: any)
	assert(net and cityStatsService and economyService and roadService and educationService and emergencyService and transitService,
		"[ProgressionService] Init requires Net, CityStatsService, CityEconomyService, RoadService, EducationService, EmergencyService and TransitService")
	_net = net
	_stats = cityStatsService
	_economy = economyService
	_roads = roadService
	_education = educationService
	_emergency = emergencyService
	_transit = transitService
	_syncRemote = net.SyncProgression
	_baselineAt = os.clock() + BASELINE_GRACE
end

function ProgressionService.Bind()
	Players.PlayerAdded:Connect(function(player: Player)
		_syncRemote:FireClient(player, snapshot())
	end)
	for _, player in Players:GetPlayers() do
		_syncRemote:FireClient(player, snapshot())
	end

	_net.RequestDevUnlock.OnServerEvent:Connect(function(player: Player, nodeId: any)
		local now = os.clock()
		if now - (_lastUnlockAt[player] or 0) < UNLOCK_COOLDOWN then return end
		_lastUnlockAt[player] = now
		if typeof(nodeId) ~= "string" or #nodeId > 64 then return end
		local ok, reason = tryUnlock(nodeId)
		if ok then
			local node = DevelopmentTree.ById[nodeId] :: DevelopmentTree.Node
			toast(("Unlocked: %s  (-%d DP)"):format(node.name, node.cost))
			broadcast()
		elseif reason then
			_net.Notify:FireClient(player, { text = "Can't unlock: " .. reason, kind = "danger", duration = 3 })
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player) _lastUnlockAt[p] = nil end)
end

function ProgressionService.Start()
	if _running then return end
	_running = true

	task.spawn(function()
		while _running do
			local speed = GameSpeed.get()
			local period = TICK / math.max(1, speed)
			-- On this sim's own slot within the period (TICK_PHASE). The sims all started in the boot
			-- frame on 1-4 s periods and drifted freely, so any number of them could share one frame.
			task.wait(period - (os.clock() - TICK_PHASE * period) % period)
			if speed <= 0 then
				_lastTickAt = os.clock() -- paused time never earns cap
				continue
			end

			debug.profilebegin("ProgressionService.tick")
			local ok, err = pcall(ProgressionService.tick)
			debug.profileend()
			if not ok then
				warn("[ProgressionService] tick failed: " .. tostring(err))
			end
		end
	end)
end

return ProgressionService
