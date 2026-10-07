--!strict
return function()
	describe("MainMenuController terrain entry", function()
		it("waits for the final camera before choosing the visible terrain radius", function()
			local source = script.Parent.Source
			local first = assert(string.find(source, "local function buildTerrain(", 1, true))
			local last = assert(string.find(source, "-- Forward-declared:", first, true))
			local ready = false
			local selectedRadius: number? = nil
			local env = setmetatable({
				task = { spawn = function(fn: () -> ()) fn() end },
				Net = {},
				workspace = { CurrentCamera = {} },
				warn = function() end,
				AUTO_ENTER_RADIUS = 1024,
				visibleGroundRadius = function()
					assert(ready, "terrain radius chosen before the final camera")
					return 500
				end,
				TerrainBuildController = { build = function(_net: any, _progress: any, beforeDraw: () -> number)
					assert(type(beforeDraw) == "function", "no initial camera gate passed to the terrain builder")
					selectedRadius = beforeDraw()
					return true
				end },
			}, { __index = getfenv() })
			local chunk = assert(loadstring(string.sub(source, first, last - 1) .. "\nreturn buildTerrain"))
			setfenv(chunk, env)
			chunk()(function() end, 0, function() return false end, nil, function() ready = true end)
			assert(ready and selectedRadius == 500, "initial view did not reach the terrain builder")
		end)
	end) 
 local function harness(source: string,mode: string): any
  local e: any={now=10,entries=0,reports=0,finishedBackground=0,errors={},warnings={},ready=false,delayed={}}
  local screen: any={
   setProgress=function()end,skipped=function()return false end,finish=function()end,
   fadeOut=function()end,destroy=function()e.destroyed=true end,
  }
  e.screen=screen
  local function event(name)
   return {Connect=function(_,fn)e[name]=fn;return {Disconnect=function()end}end}
  end
  e.Net={
   CityLoadResult={OnClientEvent=event("result")},
   CityLoadStarted={OnClientEvent=event("started")},
   RequestLoadSlot={FireServer=function()
    if mode=="overlap" then e.started({camera={}})end
    e.result({ok=true,camera={},slot={slotId=1}})
   end},
  }
  e.task={
   spawn=function(fn)fn()end,
   wait=function(duration)e.now+=duration or 0.1;if e.worker then local fn=e.worker;e.worker=nil;fn()end end,
   delay=function(_,fn)table.insert(e.delayed,fn)end,
  }
  e.os={clock=function()return e.now end}
  e.TerrainBuildController={
   build=function()error("fixture terrain failure")end,
   groundReadyAround=function()return e.ready end,
   finishInBackground=function()e.finishedBackground+=1 end,
  }
  e.workspace={CurrentCamera={CFrame=CFrame.new(0,120,80)}}
  e.visibleGroundRadius=function()return 500 end
  e.AUTO_ENTER_RADIUS=1024;e.SKIP_GROUND_RADIUS=500;e.LOAD_TIMEOUT=180
  e.WorldReveal={arm=function()end,release=function()e.released=true end}
  e.FreeCamController={setCameraState=function()end}
  e.createGameLoadingScreen=function()return screen end
  e.PlacesConfig={isLobby=function()return false end,menuIsElsewhere=function()return false end}
  e.mainMenu={Enabled=true}
  e.showErrorModal=function(message)table.insert(e.errors,message)end
  e.getMenuFadeOverlay=function()return {}end
  e.setMenuPanelVisible=function()end
  e.refreshSlotIndex=function()end
  e.enterGame=function()e.entries+=1 end
  e.enterCityNow=function()e.reports+=1 end
  e.warn=function(message)table.insert(e.warnings,message)end
  e.playerGui={FindFirstChild=function()return nil end}
  e.hasOpenedHub=false;e._loadBusy=false
  e._adminLoadActive=true;e._adminLoadToken=1;e._adminLoadingScreen=screen
  e.cancelAdminCityLoad=function(message)e._adminLoadActive=false;e.cancelledAdmin=true;table.insert(e.errors,message)end
  e.clearAdminLoadingScreen=function()end
  setmetatable(e,{__index=getfenv()})
  local function compile(first,last,result)
   local a=assert(string.find(source,first,1,true))
   local b=assert(string.find(source,last,a+1,true))
   local f=assert(loadstring(string.sub(source,a,b-1).."\nreturn "..result));setfenv(f,e)
   return f()
  end
  e.buildTerrain=compile("local function buildTerrain(","-- Forward-declared:","buildTerrain")
  e.start=compile("local function startCityLoad(","-- Menu dialogs","startCityLoad")
  e.admin=compile("local function finishAdminCityLoad(","-- ownerId is set","finishAdminCityLoad")
  return e
 end
 describe("MainMenuController terrain failure boundary",function()
  it("reports a thrown build and an explicit false result to its caller",function()
   local e=harness(script.Parent.Source,"serial")
   local ok,err=e.buildTerrain(function()end,0,function()return false end)
   assert(ok==false and type(err)=="string","terrain exception was swallowed")
   e.TerrainBuildController.build=function()return false end
   ok,err=e.buildTerrain(function()end,0,function()return false end)
   assert(ok==false and type(err)=="string","cancelled or missing city counted as a successful terrain build")
  end)
  it("routes failed overlapped terrain through the normal load-failure screen",function()
   local e=harness(script.Parent.Source,"overlap")
   e.start(1)
   assert(e.entries==0 and e.reports==0,"failed overlapping terrain entered the city")
   assert(#e.errors==1 and string.find(e.errors[1],"ground",1,true) and not e._loadBusy,"overlap failure did not restore a retryable failure UI")
  end)
  it("routes failed serial terrain through the normal load-failure screen",function()
   local e=harness(script.Parent.Source,"serial")
   e.start(1)
   assert(e.entries==0 and e.reports==0,"failed serial terrain entered the city")
   assert(#e.errors==1 and string.find(e.errors[1],"ground",1,true) and not e._loadBusy,"serial failure did not restore a retryable failure UI")
  end)
  it("cancels an admin city load before entry when terrain fails",function()
   local e=harness(script.Parent.Source,"admin")
   e.admin({camera={},slot={}})
   assert(e.cancelledAdmin and e.entries==0 and e.reports==0,"failed admin terrain entered the city")
  end)
  it("requires actual ground readiness even when the player skips",function()
   local e=harness(script.Parent.Source,"serial")
   e.TerrainBuildController.build=function()return true end
   e.task.spawn=function(fn)e.worker=fn end
   local ok=e.buildTerrain(function()end,0,function()return true end)
   assert(ok and e.finishedBackground==0,"Skip bypassed the ground-readiness gate")
  end)
 end)

 local function cityLoader(source: string): any
  local e: any={now=0,logos=0,quick=nil,viewDestroyed=0,guiDestroyed=0}
  local gui: any={Parent=true}
  gui.WaitForChild=function(_,name)assert(name=="Background");return {}end
  gui.Destroying={Connect=function(_,fn)e.onDestroy=fn end}
  gui.Destroy=function()e.guiDestroyed+=1;gui.Parent=nil;if e.onDestroy then e.onDestroy()end end
  local template={IsA=function(_,kind)return kind=="ScreenGui"end,Clone=function()return gui end}
  local view={
   setStatus=function()end,showProgress=function()end,allowSkip=function()end,
   setProgress=function()end,skipped=function()return false end,holdUntil=function()end,
   playLogo=function()e.logos+=1 end,fadeOut=function(quick)e.quick=quick end,
   destroy=function()e.viewDestroyed+=1 end,
  }
  local env=setmetatable({
   playerGui={FindFirstChild=function()return nil end},
   ReplicatedFirst={FindFirstChild=function(_,name)assert(name=="LoadingScreen");return template end},
   Theme={Layer={Fade=1}},GAME_LOADING_SCREEN_NAME="CityLoad",LoadingView={new=function()return view end},
   MIN_LOADING_SCREEN_TIME=assert(tonumber(string.match(source,"local MIN_LOADING_SCREEN_TIME = ([%d%.]+)"))),
   os={clock=function()return e.now end},
   task={spawn=function()end,wait=function()e.now+=0.05 end},
  },{__index=getfenv()})
  local a=assert(string.find(source,"local function createGameLoadingScreen(",1,true))
  local b=assert(string.find(source,"-- NO ASSET GATE",a,true))
  local f=assert(loadstring(string.sub(source,a,b-1).."\nreturn createGameLoadingScreen"));setfenv(f,env)
  e.loader=f()()
  return e
 end
 describe("MainMenuController city transition",function()
  it("uses the quick fade without waiting for another logo and cleans up the loader",function()
   local e=cityLoader(script.Parent.Source)
   e.loader.fadeOut()
   assert(e.logos==0 and e.quick==true,"ready city waited for the loading logo or full fade")
   assert(e.guiDestroyed==1 and e.viewDestroyed>=1,"quick transition leaked its loader")
  end)
  it("keeps the city loading screen floor below a quarter second",function()
   local e=cityLoader(script.Parent.Source)
   e.loader.finish()
   assert(e.now<=0.2001,"ready city waited for a decorative loading floor")
  end)
 end)

end
