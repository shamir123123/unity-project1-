--!strict
-- Household goods are consumed by residents and replenished only by real purchases.
local Const = require(script.Parent.Parent.CitySimConstants)
export type State = {goodsStock: number?, goodsUpdatedAt: number?}
local HouseholdNeeds = {}
function HouseholdNeeds.restore(stock: any, members: number): number?
	if typeof(stock) ~= "number" or stock ~= stock or math.abs(stock) == math.huge then return nil end
	return math.clamp(stock, 0, members * Const.HOUSEHOLD_GOODS_PER_PERSON * Const.HOUSEHOLD_GOODS_MAX_DAYS)
end
function HouseholdNeeds.advance(state: State, members: number, now: number, seed: number): ()
	local daily = members * Const.HOUSEHOLD_GOODS_PER_PERSON
	if state.goodsStock == nil then
		-- Legacy saves had no household inventory. Give a staggered starter supply.
		state.goodsStock = daily * (1 + (seed * 17 % 101) / 100)
	end
	local elapsed = if state.goodsUpdatedAt then math.max(0, now - state.goodsUpdatedAt) else 0
	state.goodsStock = math.max(0, (state.goodsStock :: number) - daily * elapsed)
	state.goodsUpdatedAt = now
end
function HouseholdNeeds.wantsShopping(state: State, members: number): boolean
	return (state.goodsStock or 0) <= members * Const.HOUSEHOLD_GOODS_PER_PERSON * Const.HOUSEHOLD_GOODS_REORDER_DAYS
end
function HouseholdNeeds.buy(state: State, amount: number): ()
	if amount <= 0 or amount ~= amount or amount == math.huge then return end
	state.goodsStock = (state.goodsStock or 0) + amount
end
return table.freeze(HouseholdNeeds)
