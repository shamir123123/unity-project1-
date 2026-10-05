--!strict
-- Verified in Studio Edit against current source; see evidence/final-stress-results.json.
-- Models are actual Roblox instances; network transport and service lifecycle are mocked.
-- Isolated integration fixture: real graph, driver, PathFollower geometry and spatial
-- registry. Models live in an unparented Folder; network, tags, players and callbacks
-- use local test transport. No city boot, saves, timers or live vehicles are touched.
return function(graph: any, network: any, fresh: (ModuleScript) -> any): any
 local driverModule = script.Parent
 local folder = Instance.new("Folder")
 folder.Name = "TrafficIntegration"
 local tagsByModel: {[Instance]: {[string]: boolean}} = {}
 local tags: any = {}
 function tags:HasTag(model, tag) return tagsByModel[model] ~= nil and tagsByModel[model][tag] == true end
 function tags:AddTag(model, tag)
  tagsByModel[model] = tagsByModel[model] or {}; tagsByModel[model][tag] = true
 end
 function tags:RemoveTag(model, tag) if tagsByModel[model] then tagsByModel[model][tag] = nil end end
 local world: any = {}
 function world:GetAttribute(_key) return nil end
 function world:FindFirstChild(_name) return nil end
 local fakeGame: any = {}
 function fakeGame:GetService(name)
  if name == "CollectionService" then return tags end
  if name == "Workspace" then return world end
  if name == "Players" then return {GetPlayers = function() return {} end} end
  return game:GetService(name)
 end
 local signals = { enabled = false, green = true, yellow = false }
 local modules: any = {
  GameSpeed = {get=function()return 1 end,steps=function()return 1 end},
  NetMiddleware = {}, VehicleFactory = {},
  TrafficConfig = { PREEMPT_APPROACH_DIST = 40 },
  TrafficSignalService = {
   HasSignal = function() return signals.enabled end,
   CanGo = function(edgeId) return signals.green and (not signals.allow or signals.allow(edgeId)) end,
   IsApproachYellow = function() return signals.yellow end,
  },
  VehicleTypes = { Car = "Car", Truck = "Truck", Bus = "Bus", classOf = function() return "Car" end, canPreempt = function() return false end },
  DriverProfile = { fromModel = function() return nil end, withToken = function(profile) return profile end },
  Networker = {SyncNpcPoses = {FireClient = function() error("Integration attempted a network send") end}},
 }
 for _, name in {"RoadConstants", "RoadRules", "RoadTypeCatalog", "BezierUtil", "IntersectionRenderer", "VehicleTypes"} do
  modules[name] = fresh(game.ReplicatedStorage.Road[name])
 end
 local function isolatedRequire(module: ModuleScript): any
  assert(modules[module.Name], "Unstubbed dependency " .. module.Name)
  return modules[module.Name]
 end
 local followerModule = game.ServerScriptService.Services.Util.PathFollower
 local followerChunk = assert(loadstring(followerModule.Source, "=" .. followerModule:GetFullName()))
 setfenv(followerChunk, setmetatable({game=fakeGame, workspace=world, require=isolatedRequire, script=followerModule}, {__index=getfenv()}))
 local follower = followerChunk()
 modules.PathFollower = follower
 local source = driverModule.Source:gsub("return NPCDriverService%s*$", [[return {
  api=NPCDriverService, step=updateDriver, drivers=_drivers, reindex=rebuildDriverIndexes,
  clock=function(dt) _simClock += dt end,
 }]])
 local driverChunk = assert(loadstring(source, "=" .. driverModule:GetFullName()))
 setfenv(driverChunk, setmetatable({
  game=fakeGame, workspace=world, script=driverModule, require=isolatedRequire,
  task={spawn=function(fn) fn() end}, warn=function(...) end,
 }, {__index=getfenv()}))
 local driver = driverChunk()
 driver.api.Init({getNavigationGraph=function() return graph end, getNetwork=function() return network end})
 local fixture: any = {d=driver, g=graph, follower=follower, signals=signals}
 function fixture.car(id: string, lane: string, dist: number, speed: number): any
  local model=Instance.new("Model");model.Name=id
  local body=Instance.new("Part");body.Name="Hitbox";body.Size=Vector3.new(4,3,8)
  body.Anchored=true;body.CanCollide=false;body.Parent=model;model.PrimaryPart=body
  model:SetAttribute("NPCHeightOffset",0);model:SetAttribute("NPCDebugId",id);model.Parent=folder
  local state: any = {
   model=model,edgeId=lane,edgeDist=dist,vehicleClass="Car",graphVersion=graph:Version(),
   heightOffset=0,replicateAccum=0,connDist=0,nextEdgeDist=0,speed=20,currentSpeed=speed,
   halfLength=4,atDeadEnd=false,deadEndTimer=0,
  }
  local edge=graph:GetEdge(lane)
  local pos,dir=follower.pointAtDist(edge.points,edge._cum,dist)
  follower.place(state,pos,dir)
  driver.drivers[model]=state
  return state
 end
 function fixture.destroy()
  for model in driver.drivers do follower.forget(model) end
  folder:Destroy()
 end
 return fixture
end


