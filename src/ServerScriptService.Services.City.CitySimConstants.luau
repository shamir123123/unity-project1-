--!strict

-- Tuning constants for the land-value-driven zoning sim (Phase A).
-- First-pass numbers; expected to be tuned in playtest. Frozen.

local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)
local WS = RoadConstants.WORLD_SCALE -- world-distance dims below scale with the half-size world

local CitySimConstants = {}

-- Raster ------------------------------------------------------------------
-- ponytail: CELL_SIZE deliberately NOT scaled -- halving it 4x's the raster cell
-- count. At WS 0.5 a cell covers 2 lots instead of 1; overlays get slightly blockier.
CitySimConstants.CELL_SIZE       = 16
CitySimConstants.MAP_HALF_EXTENT = RoadConstants.MAP_HALF_EXTENT -- single source (TerrainConstants asserted against it at boot)

-- Tick --------------------------------------------------------------------
CitySimConstants.SIM_TICK = 1.0

-- Calendar ----------------------------------------------------------------
-- One day/night cycle = DAY_SECONDS real seconds at GameSpeed 1 (1 tick = 1 s at 1x), and
-- ONE CYCLE IS ONE CALENDAR MONTH (Shared.CityCalendar, the Cities: Skylines 2 model): a
-- month is 24 real minutes at 1x, 12 at 2x, 8 at 3x. The sky keeps a slow, playable day
-- (and a commute a real car can drive) while the date, the budget and the seasons move a
-- month per cycle. Every per-tick money figure below is derived from a per-month one, so
-- changing the cycle length never changes what a month earns or costs -- only how long a
-- month takes.
CitySimConstants.DAY_SECONDS = 1440
CitySimConstants.MONTH_TICKS = CitySimConstants.DAY_SECONDS

-- Industrial pollution / noise sources, indexed by building level ----------
CitySimConstants.INDUSTRIAL_POLLUTION        = table.freeze({ 0.5, 0.75, 1.0 })
CitySimConstants.INDUSTRIAL_POLLUTION_RADIUS = 44 * WS
CitySimConstants.INDUSTRIAL_NOISE            = table.freeze({ 0.3, 0.4, 0.5 })
CitySimConstants.INDUSTRIAL_NOISE_RADIUS     = 36 * WS

-- Traffic noise: MEASURED from the vehicles actually driving (CoverageService samples
-- NPCDriverService.GetNoiseSources), not assumed from road width. A cell's level is a running
-- average of the heavy vehicles passing it, so a truck route is loud and a quiet street quiet.
-- ~10 heavy trucks a minute past a cell reads ~0.5; a couple a minute ~0.1.
CitySimConstants.TRAFFIC_NOISE_UNIT      = 1.5      -- one full-size truck standing in a cell
CitySimConstants.TRAFFIC_NOISE_RADIUS    = 40 * WS  -- falloff to zero (~20 m)
CitySimConstants.TRAFFIC_NOISE_TICK      = 0.5      -- game-seconds between samples
CitySimConstants.TRAFFIC_NOISE_SMOOTHING = 0.03     -- per sample: ~16 s to settle

CitySimConstants.POLLUTION_CAP = 1.0
CitySimConstants.NOISE_CAP     = 1.0

-- Land value --------------------------------------------------------------
-- Hybrid: gates must pass, else LV = 0. Then LV = clamp(LV_BASE + bonus).
-- bonus = wServices*coverage + wRoad*roadAccess - wPollution*poll - wNoise*noise
CitySimConstants.LV_BASE = 0.3
CitySimConstants.LV_WEIGHTS = table.freeze({
	Residential = table.freeze({ services = 0.35, road = 0.15, pollution = 0.25, noise = 0.15 }),
	Commercial  = table.freeze({ services = 0.30, road = 0.25, pollution = 0.12, noise = 0.10 }),
	Industrial  = table.freeze({ services = 0.20, road = 0.30, pollution = 0.00, noise = 0.00 }),
})

-- ponytail: a switched-off utility counts every building as served and every plot as covered
-- for it (BuildingService, LandValueService, WaterService). The mirrors in BottomBarController hide
-- the cards of a switched-off utility -- change both together.
-- 2026-10-07 (user: "turn on all of your utilities"): power, water and sewage all ON.
CitySimConstants.POWER_OFF = false
CitySimConstants.WATER_OFF = false
CitySimConstants.SEWAGE_OFF = false

-- Upgrade -----------------------------------------------------------------
CitySimConstants.UPGRADE_FILL        = 0.95  -- every household slot but a rounding error must be let
CitySimConstants.UPGRADE_DEMAND      = -0.5  -- only a badly oversupplied zone holds a full building back
-- 2026-10-02: L2->L3 was 0.82, above what industry (0.80 max) or a home with no school
-- could ever reach, with schools and utilities both off for playtest -- nothing topped out.
CitySimConstants.UPGRADE_LV          = table.freeze({ 0.60, 0.72 }) -- [level] L1->L2, L2->L3
CitySimConstants.UPGRADE_COOLDOWN    = 300  -- game-seconds (GameSpeed-scaled) between a building's upgrades
CitySimConstants.MAX_CHANGES_PER_TICK = 1   -- upgrades city-wide per tick: growth crawls instead of sweeping the map
CitySimConstants.FILL_LERP           = 0.18
CitySimConstants.LOW_DEMAND_FILL_MUL = 0.5  -- fill target multiplier when demand < 0

-- Abandon / recover -------------------------------------------------------
CitySimConstants.HARD_FAIL_DWELL  = 30   -- game-seconds
CitySimConstants.SOFT_FAIL_DWELL  = 60
CitySimConstants.VACANCY_DWELL    = 120
CitySimConstants.RECOVER_DWELL    = 30
CitySimConstants.ABANDON_SCORE    = 0.50
CitySimConstants.RECOVER_SCORE    = 0.20
CitySimConstants.POLLUTION_CUTOFF = 0.60
CitySimConstants.LV_CUTOFF        = 0.20
CitySimConstants.VACANCY_FILL     = 0.10

-- abandonScore = clamp(Wp*pollTerm + Wlv*lvTerm + Wd*demandTerm)
CitySimConstants.ABANDON_W = table.freeze({ pollution = 0.38, lowLV = 0.35, lowDemand = 0.30 })

-- Job slots a workplace holds, by level. CitizenService fills them; PowerService bills
-- their electricity. One table, because two copies of it would drift.
CitySimConstants.JOB_CAP = table.freeze({
	-- 2026-10-02: a bigger step per level (was 3/7/14 and 5/11/20) so levelling up reads.
	Commercial = table.freeze({ 3, 9, 20 }),
	Industrial = table.freeze({ 5, 14, 30 }),
})

-- How many FAMILIES a home fits. The lot's FOOTPRINT (width * depth in lots) picks the
-- row and the building's LEVEL picks the column, so size sets the ceiling and levelling
-- walks up to it: a 2x4 shack is capped at one household however far it levels, a
-- medium home runs 2 -> 4, and a 4x5 / 5x5 starts at three and reaches five. Never
-- fewer than one, never more than five. FAMILY_MAX caps ONE family, so a full 5x5 is
-- five households of up to five people.
CitySimConstants.HOUSEHOLDS_MEDIUM_AREA = 9   -- lot area (w*d) at which a home counts as medium
CitySimConstants.HOUSEHOLDS_LARGE_AREA  = 20  -- ...and large (4x5, 5x4, 5x5)
CitySimConstants.HOUSEHOLDS_BY_LEVEL = table.freeze({
	table.freeze({ 1, 1, 1 }), -- small:  one family, levelling adds nothing
	table.freeze({ 2, 3, 4 }), -- medium
	table.freeze({ 3, 4, 5 }), -- large
})
CitySimConstants.FAMILY_MAX = 5

-- Economy ----------------------------------------------------------------
-- Industry produces goods; commerce consumes them. Local supply is profitable;
-- any shortfall is imported and costs the player (imports cost more than the
-- margin they earn). Money accrues per sim tick (game-second, GameSpeed-scaled).
CitySimConstants.ECON_START_TREASURY = 100000 -- 2026-10-02 "not too easy": 500k made money meaningless (was 50k before that playtest)
CitySimConstants.IND_OUTPUT_PER      = 1.0   -- goods/tick per filled industrial capacity
CitySimConstants.COMM_INPUT_PER      = 1.0   -- goods/tick needed per filled commercial capacity
CitySimConstants.IMPORT_UNIT_COST    = 7.0   -- money/tick per imported good (the penalty)
CitySimConstants.LOCAL_GOODS_MARGIN  = 2.5   -- money/tick per locally-supplied good (the reward)
-- NOTE: tuned PER MONTH, applied per TICK (1 tick = 1s at 1x): 540 per resident per month
-- is 540 / MONTH_TICKS a tick. They were ~50x too high once (a 160-pop town earned
-- millions a month); rebalanced so a small city runs on a tight, manageable budget. TUNE HERE.
-- 2026-10-02: yields cut (were 540 / 1080 / 756); C/I cut further because their job slots grew.
-- 2026-10-07 (user: "people don't give so much taxes, make the tax amount a little lower"): 10% under the
-- day's +7% (370/580/420), a little under the 10-02 numbers. Big cities keep their margin through a gentler
-- City services climb (UPKEEP_SERVICES_GROWTH), not through the tax.
CitySimConstants.RES_TAX             = 335 / CitySimConstants.MONTH_TICKS   -- per resident, at the default tax rate
CitySimConstants.COMM_TAX            = 520 / CitySimConstants.MONTH_TICKS  -- per filled commercial capacity, at the default rate
CitySimConstants.IND_TAX             = 380 / CitySimConstants.MONTH_TICKS   -- per filled industrial capacity, at the default rate

-- Budget: player-adjustable tax rates (percent). The RES/COMM/IND_TAX yields above
-- are the take at TAX_DEFAULT_RATE; actual income scales linearly with the chosen
-- rate. Raising a rate above TAX_COMFORT_RATE costs happiness and demand for that
-- zone; cutting below TAX_DEFAULT_RATE earns a small capped bonus (TAX_LOW_BONUS_MAX),
-- so taxes are a real trade-off rather than free money.
CitySimConstants.TAX_MIN_RATE          = -5   -- negative = the city PAYS that zone (subsidy)
CitySimConstants.TAX_MAX_RATE          = 29
CitySimConstants.TAX_DEFAULT_RATE      = 9
CitySimConstants.TAX_COMFORT_RATE      = 13
CitySimConstants.TAX_HAPPINESS_PER_PCT = 0.012  -- happiness lost per % above comfort (averaged over zones)
CitySimConstants.TAX_DEMAND_PER_PCT    = 0.010  -- demand lost per % above comfort (per zone)
CitySimConstants.TAX_LOW_BONUS_MAX     = 0.05   -- cap on happiness/demand gained from taxes below default

-- Upkeep: running costs, expressed per in-game MONTH (MONTH_TICKS above) and drained
-- per tick. Roads cost by the metre; service
-- buildings (emergency + schools) cost a fraction of their build price each month.
CitySimConstants.UPKEEP_ROAD_PER_METER   = 6.0   -- per metre of road, per month
CitySimConstants.UPKEEP_SERVICE_FRACTION = 0.60  -- service monthly upkeep = 60% of build cost (x funding)

-- Utilities (generators, water, sewage, deathcare) bill like the emergency services but
-- have NO funding slider: the way to cut this bill is to demolish, not to move a slider.
CitySimConstants.UPKEEP_UTILITY_FRACTION = 0.45  -- utility monthly upkeep = 45% of build cost
CitySimConstants.UPKEEP_POLE_EACH        = 15    -- per power pole, per month
-- Zoned buildings carry a small standing cost of their own, by level: a drag on a sprawling
-- city, never a reason not to build. (2026-10-02: was 6/14/26, which no budget could feel.)
-- 2026-10-07 (user): industry costs the city a little more than commerce, commerce a little more than homes
-- (bigger plots, heavier traffic, more for the city to look after).
CitySimConstants.UPKEEP_ZONED_BY_LEVEL   = table.freeze({
	Residential = table.freeze({ 40, 90, 180 }),
	Commercial  = table.freeze({ 50, 110, 215 }),
	Industrial  = table.freeze({ 60, 130, 250 }),
})
-- CITY SERVICES: what the sim does not model, billed per resident per month -- rubbish, street and
-- park upkeep, city staff, and water, power and sewage while those are switched off (below).
-- Per head it RISES with size (BASE at 0 -> BASE + GROWTH at FULL_POP),
-- so a small town has slack and a big city has to manage taxes (user, 2026-10-02: "not too
-- easy"). Modelled at default tax (second pass, same day): ~70% of income spent at 300 pop,
-- ~57% at 3k, ~76% at 12.6k, ~93% at 40k -- big cities have to raise taxes toward comfort.
-- A real utility, once switched on, bills its own buildings (ServiceTypes upkeep + runCost) and its share
-- comes off this per head (2026-10-07: about what each costs a resident when it runs).
CitySimConstants.UPKEEP_SERVICES_UTILITY  = table.freeze({ Power = 20, Water = 28, Sewage = 30 })
CitySimConstants.UPKEEP_SERVICES_BASE     = 220
CitySimConstants.UPKEEP_SERVICES_GROWTH   = 210 -- 2026-10-07: was 260, eased as the taxes came down
CitySimConstants.UPKEEP_SERVICES_FULL_POP = 20000

-- Per-service funding (percent). Raising a service's funding widens its coverage
-- radius / capacity / vehicle count AND scales its upkeep cost by the same factor.
CitySimConstants.FUNDING_MIN_PCT     = 50
CitySimConstants.FUNDING_MAX_PCT     = 150
CitySimConstants.FUNDING_DEFAULT_PCT = 100

-- Bankruptcy (hard game-over): once the treasury falls below the debt floor it
-- stays in the red for the grace period before the city is declared bankrupt.
CitySimConstants.BANKRUPTCY_DEBT_FLOOR   = -10000
CitySimConstants.BANKRUPTCY_GRACE_TICKS  = 120  -- game-seconds below the floor before game-over
CitySimConstants.BANKRUPTCY_WARN_EVERY   = 25   -- ticks between in-debt warnings

-- Loans: borrow against the city's future. Interest accrues monthly on the balance
-- and is paid out of the treasury (counts as an expense). The borrowing limit grows
-- with population so bigger cities can take bigger loans.
CitySimConstants.LOAN_BASE_LIMIT    = 50000
CitySimConstants.LOAN_LIMIT_PER_POP = 2000
CitySimConstants.LOAN_ANNUAL_RATE   = 0.08   -- 8% per year
CitySimConstants.LOAN_STEP          = 25000  -- borrow/repay increment used by the UI

-- Visible supply chain (SupplyService). One good, STOCK: every industrial building makes
-- it, every commercial building sells it, and any plant can supply any shop. One unit is
-- one household shopping trip's worth. Grounded in real retail replenishment:
--   * a shop reorders on an order-point / order-up-to rule: when stock on hand plus stock
--     already on its way falls to REORDER_DAYS of its own recent sales, it orders back up
--     to TARGET_DAYS. With these numbers a shop takes ~2 deliveries a week, the rhythm of
--     a small store (big stores get the same rhythm in bigger trucks).
--   * a plant holds about two weeks of its own output (make-to-stock plants target a few
--     weeks of finished goods); surplus past a few days' reserve leaves as export.
--   * truck sizes follow real pallet counts: van 4, box trucks 8 and 12, a 53 ft semi 26
--     (10 units to the pallet).
CitySimConstants.SUPPLY_STOCK_NAME          = "Stock"
-- 2026-10-02 (user: more trade traffic): output up ~30%, reserve 3 -> 1 day, fleet floor 20 -> 30.
CitySimConstants.SUPPLY_PRODUCE_PER_DAY     = table.freeze({ 40, 105, 260 }) -- units a plant makes per game day, by level
CitySimConstants.SUPPLY_YARD_DAYS           = 14    -- a plant's yard holds this many days of its own output
CitySimConstants.SUPPLY_EXPORT_MIN_FILL     = 0.5
CitySimConstants.SUPPLY_BORDER_QUEUE_RADIUS = 160 -- same gateway, despite an inward lane offset
CitySimConstants.SUPPLY_BORDER_QUEUE_COST   = 400 -- route-distance cost per truck already committed to a gateway
CitySimConstants.SUPPLY_ROUTE_BUDGET        = 24 -- maximum new freight route searches per dispatch pass
CitySimConstants.SUPPLY_HANDOFF_WAIT_SECONDS = 4
CitySimConstants.SUPPLY_FAILED_ROUTE_RETRY  = 10 -- game-seconds before retrying an unreachable supplier
CitySimConstants.SUPPLY_EXPORT_RESERVE_DAYS = 1     -- days of output a plant keeps back for the city's own shops
CitySimConstants.SUPPLY_SHOP_CAP            = table.freeze({ 40, 100, 260 }) -- units a shop can hold, by level
CitySimConstants.SUPPLY_SHOP_DEMAND_PRIOR   = table.freeze({ 5, 12, 30 })    -- units/day a new shop expects, by level, until it has sales of its own
CitySimConstants.SUPPLY_TARGET_DAYS         = 6     -- order-up-to level, in days of the shop's own sales
CitySimConstants.SUPPLY_REORDER_DAYS        = 2.5   -- order point: ~1 day of delivery lead time + 1.5 days of safety stock
CitySimConstants.SUPPLY_MIN_ORDER           = 10    -- nobody sends a truck for less than a pallet
CitySimConstants.SUPPLY_DEMAND_SMOOTHING    = 0.3   -- how much one day's sales move a shop's forecast
CitySimConstants.SUPPLY_TRUCK_TIER_CAPACITY = table.freeze({ 40, 80, 120, 260 }) -- units per truck tier: van, small box, box, semi
CitySimConstants.SUPPLY_MAX_TRUCKS          = 30    -- floor on concurrent LOADED deliveries (a truck running home empty holds no slot)
CitySimConstants.SUPPLY_MAX_TRUCKS_CEILING  = 60    -- ...and the ceiling. The live cap tracks how many shops are waiting, so a distant
                                                    -- industrial district (minutes per round trip) cannot starve the city out of a flat 20.
-- Delivery truck size by DEPOT footprint, in lot units (width * depth): <=6 vans, <=12
-- small box, <=20 medium/large box, bigger than that the linehaul rig. The load can only
-- pick a SMALLER truck than the building allows, never a larger one.
CitySimConstants.SUPPLY_TRUCK_TIER_LOTS     = table.freeze({ 6, 12, 20 })
CitySimConstants.SUPPLY_TRUCK_SPEED         = 32 * WS -- studs/sec; same blocks-per-second at any world scale
CitySimConstants.SUPPLY_TICK                = 1.0   -- production/dispatch pass seconds (GameSpeed-scaled)
CitySimConstants.SUPPLY_IMPORT_PRICE        = 3.5   -- landed wholesale cost; below retail, above domestic export value
CitySimConstants.SUPPLY_DIRECT_SALE_PRICE   = 2.5   -- treasury per unit sold out of the city (export; below retail)
CitySimConstants.TRAFFIC_SAFETY_MAX_CARS = 12000 -- emergency allocation guard, not a density target
-- ONE budget for everything on the full AI at once: cars, trucks and buses on the road AI plus
-- walker bodies, shared (user 2026-10-05). Past it a trip is never skipped: a car far from every
-- player drives its real route unseen, a walker walks it as a bodiless Tier-2 plan.
CitySimConstants.NPC_MAX_ACTIVE = 6000
CitySimConstants.CAR_PARKING_RETRY_SECONDS = 5
-- 0.003 until 2026-10-08 (user: fewer people walking): ~0.8 strolls per idle adult per game day -> ~0.3.
CitySimConstants.STROLL_CHANCE = 0.0012
CitySimConstants.STROLL_MIN = 60
CitySimConstants.STROLL_MAX = 180
CitySimConstants.STROLL_FROM_HOUR = 9
CitySimConstants.STROLL_TO_HOUR = 18
CitySimConstants.WALKER_MAX_BODIES = 400
CitySimConstants.WALKER_BODY_RANGE = 500
CitySimConstants.WALKER_DEMOTE_RANGE = 650
CitySimConstants.WALKER_PROMOTE_RANGE = 450
CitySimConstants.TRAVEL_TERMINAL_SECONDS = 8 -- game-time cost per trip end
CitySimConstants.TRAVEL_NO_PARKING_SECONDS = 120 -- parking inconvenience; never a universal walking switch
CitySimConstants.TRAVEL_CHOICE_POWER = 3 -- stronger preference for lower costs, retaining individual variation
CitySimConstants.TRAVEL_AGE_PROFILES = table.freeze({
	children = table.freeze({money=3, time=0.8}),
	teens = table.freeze({money=2.5, time=1}),
	adults = table.freeze({money=1, time=1.3}),
	seniors = table.freeze({money=0.7, time=0.8}),
})
CitySimConstants.TRAVEL_WORK_TIME_WEIGHT = 1.35
CitySimConstants.TRAVEL_SENIOR_LEISURE_TIME_WEIGHT = 0.75

CitySimConstants.HOUSEHOLD_GOODS_PER_PERSON = 1 / 6 -- stock units consumed per resident per simulation day
CitySimConstants.HOUSEHOLD_GOODS_REORDER_DAYS = 0.5
CitySimConstants.HOUSEHOLD_GOODS_MAX_DAYS = 14
CitySimConstants.SUPPLY_SHOP_BASKET         = 1     -- units a shopping trip buys (one unit IS one trip's worth)
CitySimConstants.SUPPLY_SHOP_PRICE          = 5     -- @deprecated (2026-10-07): shops keep their takings now -- BUSINESS.RETAIL

-- BUSINESSES keep their own books (BusinessService; user 2026-10-07: "they make their money from people
-- buying things ... so businesses can fail"). Prices per unit of goods, wages per FILLED job per month.
-- Calibrated so a city at the commercial demand's own target (CityStatsService C_PER_POP, 0.35 shop job
-- slots a resident, each resident buying 1/6 unit a month) keeps its shops a little in profit; zone more
-- shops than the people can keep busy and they lose money. A big shop's 20 staff cost ~3,000 a month.
-- Stock from outside the city costs a shop more than local stock, so local industry matters.
CitySimConstants.BUSINESS = table.freeze({
	RETAIL    = 450, -- a shop's takings per unit a household buys
	WHOLESALE = 130, -- what a shop pays a city factory per unit delivered
	IMPORT    = 200, -- ...and the outside world per unit trucked in
	EXPORT    = 80,  -- what a factory earns per unit sold out of the city
	WAGE      = table.freeze({ Commercial = 150, Industrial = 120 }),
	TAU_MONTHS    = 0.25, -- a business's profit is averaged over about a week of trade
	GRACE_MONTHS  = 1.0,  -- a new business is not judged in its first month
	WARN_MONTHS   = 0.25, -- losing money this long: it says so (attribute Losing)
	SHRINK_MONTHS = 0.75, -- ...this long: it cuts back a level (fewer staff); at level 1, it closes
	ACTION_GAP    = 120,  -- game-seconds between two cut-backs or closures anywhere in the city
})
-- Real households shop a few times a week, not whenever they are idle. Each household
-- makes SHOP_TRIPS_PER_WEEK trips on average, during shop hours.
CitySimConstants.SHOP_TRIPS_PER_WEEK        = 2.5
CitySimConstants.SHOP_OPEN_HOUR             = 8
CitySimConstants.SHOP_CLOSE_HOUR            = 20
-- The tax panel still groups commercial / industrial income by what a building deals in;
-- there is one good, so one group each.
CitySimConstants.SUPPLY_INDUSTRIAL_PRODUCTS = table.freeze({ CitySimConstants.SUPPLY_STOCK_NAME })
CitySimConstants.SUPPLY_COMMERCIAL_PRODUCTS = table.freeze({ CitySimConstants.SUPPLY_STOCK_NAME })

return table.freeze(CitySimConstants)
