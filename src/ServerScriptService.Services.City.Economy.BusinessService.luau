--!strict
-- BusinessService
-- Every shop and factory keeps its own books (user 2026-10-07: "they make their money from people buying
-- things ... so businesses can fail"). Takings: a shop's sales, a factory's deliveries to the city's shops
-- and its exports (SupplyService books each one). Costs: wages for the staff it actually has, and the stock
-- a shop buys in -- dearer from outside the city. Prices: CitySimConstants.BUSINESS.
--
-- A business that keeps losing money says so (attribute Losing, its info panel), then cuts back a level --
-- fewer staff, a smaller wage bill -- and one that is still losing at level 1 closes for good and its lot is
-- freed. One cut-back or closure at a time across the whole city, with a notice saying why: zone too many
-- shops for the people to keep busy, or build industry nobody buys from, and it shows -- gradually.
-- City tax is separate (CityEconomyService, per filled job slot): what fails a business is its own trade.
--
-- ponytail: the books are not saved -- a reload gives every business a fresh month of grace. Save them
-- (source data: profit, age, months losing) if players notice a rejoin reprieving a failing street.

local RunService          = game:GetService("RunService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameSpeed = require(ReplicatedStorage.GameSpeed)
local Const     = require(ServerScriptService.Services.City.CitySimConstants)

local BusinessService = {}

local B = Const.BUSINESS
local MONTH = Const.MONTH_TICKS -- game-seconds
local STEP = 1.0                -- game-seconds per pass

-- `model`: the building these books belong to. A different model under the same id (another city loaded,
-- the lot rebuilt) is a different business, so its books start fresh -- no clear() hook needed on a load.
type Book = { profit: number, age: number, losing: number, model: Instance? }

local _books: { [string]: Book } = {}
local _buildingService: any
local _supplyService: any
local _net: any
local _conn: RBXScriptConnection? = nil
local _acc = 0
local _sinceAction = 0

local HINT: { [string]: string } = {
	Commercial = "Too many shops for too few customers -- or their shelves are empty.",
	Industrial = "Its goods aren't selling -- the city's shops need them, or a road out of the map to export.",
}

local function notify(text: string)
	if _net and _net.Notify then _net.Notify:FireAllClients({ text = text, kind = "warning", duration = 6 }) end
end

-- The worst-off business that has lost money long enough: it cuts back, or at level 1 closes.
local function act(id: string)
	local zone = _buildingService.getBuildingZone(id) or "Commercial"
	local what = if zone == "Industrial" then "A factory" else "A shop"
	local book = _books[id]
	if _buildingService.downgradeGroup(id) then
		if book then book.losing = 0; book.age = 0 end -- a fresh start at its new size
		notify(what .. " is losing money and cut its staff. " .. (HINT[zone] or ""))
	elseif _buildingService.demolish(id) then
		_books[id] = nil
		notify(what .. " lost money for too long and closed for good. " .. (HINT[zone] or ""))
	end
end

local function step(dt: number)
	local flows = _supplyService.drainBusinessFlows()
	local views = _buildingService.getCommercialIndustrialFill()
	local k = math.min(1, dt / (B.TAU_MONTHS * MONTH))
	local seen: { [string]: boolean } = {}
	local worst: string? = nil
	local worstProfit = math.huge
	for _, v in views do
		local id = v.bpId
		seen[id] = true
		local model = _buildingService.getModel(id)
		local book = _books[id]
		if not book or book.model ~= model then
			book = { profit = 0, age = 0, losing = 0, model = model }
			_books[id] = book
		end
		book.age += dt
		local slots = Const.JOB_CAP[v.zone]
		local jobs = if slots then slots[math.clamp(math.floor(v.level), 1, #slots)] else 0
		local wages = math.clamp(v.fill or 0, 0, 1) * jobs * (B.WAGE[v.zone] or 0) * dt / MONTH
		-- the month's rate, averaged: one sale is a spike, a week of trade is the business
		book.profit += (((flows[id] or 0) - wages) * MONTH / dt - book.profit) * k
		if book.age >= B.GRACE_MONTHS * MONTH and book.profit < 0 then
			book.losing += dt
		else
			book.losing = math.max(0, book.losing - dt * 2) -- a good spell earns the trust back faster
		end
		if model then
			-- to the nearest 50: it replicates to every client, so it moves only when the money really does
			local p = math.floor(book.profit / 50 + 0.5) * 50
			if model:GetAttribute("Profit") ~= p then model:SetAttribute("Profit", p) end
			local losing = if book.losing >= B.WARN_MONTHS * MONTH then true else nil
			if model:GetAttribute("Losing") ~= losing then model:SetAttribute("Losing", losing) end
		end
		if book.losing >= B.SHRINK_MONTHS * MONTH and book.profit < worstProfit then
			worst, worstProfit = id, book.profit
		end
	end
	for id in _books do
		if not seen[id] then _books[id] = nil end -- demolished or rebuilt: its books go with it
	end
	_sinceAction += dt
	if worst and _sinceAction >= B.ACTION_GAP then
		_sinceAction = 0
		act(worst)
	end
end

-- One pass of `dt` game-seconds, for the spec (Start runs it off Heartbeat).
BusinessService._step = step

-- A business's average monthly profit right now (the info panel reads the model's Profit attribute).
function BusinessService.getProfit(bpId: string): number?
	local b = _books[bpId]
	return if b then b.profit else nil
end

function BusinessService.Init(net: any, buildingService: any, supplyService: any)
	assert(buildingService, "[BusinessService] missing buildingService")
	assert(supplyService, "[BusinessService] missing supplyService")
	_net = net
	_buildingService = buildingService
	_supplyService = supplyService
end

function BusinessService.Start()
	if _conn then return end
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_acc += GameSpeed.scaled(math.min(dt, 0.1))
		if _acc < STEP then return end
		local pass = _acc
		_acc = 0
		local ok, err = pcall(step, pass)
		if not ok then warn("[BusinessService] step failed: " .. tostring(err)) end
	end)
end

return BusinessService
