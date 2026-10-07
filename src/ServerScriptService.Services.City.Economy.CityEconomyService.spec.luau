--!strict
return function()
 local source=(script.Parent :: ModuleScript).Source
 local drained=0
 local function settle(exports: number, imports: number): number
  local first=assert(source:find("local exportIncome, importCost =",1,true))
  local last=assert(source:find("_treasury += net",first,true))
  local env:any=setmetatable({
   _supplyService={drainGoodsTrade=function()drained+=1;return exports,imports end,getStats=function()return {supplyRatio=1}end},
   MONTHLY_TICKS=1,_loanPrincipal=0,Const={LOAN_ANNUAL_RATE=0},
   taxRevenue=0,retailIncome=0,_treasury=100,monthlyUpkeep=function()return {total=0}end,
  },{__index=getfenv()})
  local fn=assert(loadstring(source:sub(first,last+#"_treasury += net"-1).."\nreturn _treasury"));setfenv(fn,env);return fn()
 end
 -- Since 2026-10-07 freight belongs to the businesses (SupplyService books it, BusinessService keeps the
 -- books); the city earns taxes, fares and power sales only.
 describe("Freight treasury settlement",function()
  it("an import cost stays off the treasury",function()expect(settle(0,50)).to.equal(100)end)
  it("an export sale stays off the treasury",function()expect(settle(50,0)).to.equal(100)end)
  it("a canceled import refund stays off the treasury",function()expect(settle(0,-50)).to.equal(100)end)
  it("the trade counters are still drained every tick so nothing piles up",function()
   drained=0;settle(10,10);expect(drained).to.equal(1)
  end)
 end)
end
