--!strict
return function()
 local subject=script.Parent
 local function sample(output,need,pop,adults,employed,industrial,filledI,sandbox)
  local payload
  local function fresh(m)
   local fn=assert(loadstring(m.Source));setfenv(fn,setmetatable({script=m,require=fresh},{__index=getfenv()}));return fn()
  end
  local const=fresh(subject.Parent.CitySimConstants)
  local fn=assert(loadstring(subject.Source))
  setfenv(fn,setmetatable({script=subject,
   workspace={GetAttribute=function(_,k)return k=="Sandbox" and sandbox==true end},
   require=function(m)
    if m.Name=="CitySimConstants" then return const end
    if m.Name=="Networker" then return {SyncCityStats={FireAllClients=function(_,p)payload=p end}}end
    error(m.Name)
   end},{__index=getfenv()}))
  local s=fn()
  s.Init({
   getFilledByLevel=function()return {Residential={pop/4},Commercial={100},Industrial={filledI}}end,
   getBuildingCounts=function()return {Residential={pop/4},Commercial={100},Industrial={industrial}}end,
   getResidentCount=function()return pop end,
   getHomeCensus=function()return {total=pop/4,occupied=pop/4}end,
  },nil,{getStats=function()return {output=output,need=need}end})
  s.setWorkforce({totalAdults=adults,employed=employed})
  s.tick()
  return s.getDemand(),payload.demandFactors
 end
 describe("Industrial demand follows goods and available jobs",function()
  it("surplus factories do not demand more factories just because staffed",function()
   local d=sample(400,100,1000,500,500,40,40);assert(d.I<=0,tostring(d.I))
  end)
  it("young city does not receive industrial bootstrap pressure despite surplus",function()
   local _,f=sample(400,100,100,50,50,10,10);assert(f.I.boost==0)
  end)
  it("existing vacancies absorb unemployed labor before new factories",function()
   local _,f=sample(400,100,1000,600,500,100,40);assert(f.I.labor==0,tostring(f.I.labor))
  end)
  it("genuine unmet goods needs increase industrial demand",function()
   local a=sample(400,100,1000,500,500,40,40)
   local b=sample(100,400,1000,500,500,40,40)
   assert(b.I>a.I)
  end)
  it("a shortage supports expansion of fully staffed industry",function()
   local _,f=sample(100,400,1000,500,500,40,40);assert(f.I.shortage>0)
  end)
  it("residential and commercial remain independent of industry staffing correction",function()
   local d=sample(400,100,1000,500,500,40,40);assert(d.R>0 and d.C>0)
  end)
  it("empty new city still permits first industry",function()
   local d=sample(0,0,0,0,0,0,0);assert(d.I>0)
  end)
  it("sandbox keeps full RCI demand",function()
   local d=sample(400,100,1000,500,500,40,40,true);assert(d.R==1 and d.C==1 and d.I==1)
  end)
 end)
end