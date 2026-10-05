--!strict
return function()
 local source=(script.Parent :: ModuleScript).Source
 local function settle(exports: number, imports: number): number
  local first=assert(source:find("local exportIncome, importCost =",1,true))
  local last=assert(source:find("_treasury += net",first,true))
  local env:any=setmetatable({
   _supplyService={drainGoodsTrade=function()return exports,imports end,getStats=function()return {supplyRatio=1}end},
   MONTHLY_TICKS=1,_loanPrincipal=0,Const={LOAN_ANNUAL_RATE=0},
   taxRevenue=0,retailIncome=0,_treasury=100,monthlyUpkeep=function()return {total=0}end,
  },{__index=getfenv()})
  local fn=assert(loadstring(source:sub(first,last+#"_treasury += net"-1).."\nreturn _treasury"));setfenv(fn,env);return fn()
 end
 describe("Freight treasury settlement",function()
  it("an import cost is actually deducted from the treasury",function()expect(settle(0,50)).to.equal(50)end)
  it("an export sale is actually credited to the treasury",function()expect(settle(50,0)).to.equal(150)end)
  it("a canceled import refund reaches the treasury instead of being clamped away",function()expect(settle(0,-50)).to.equal(150)end)
 end)
end
