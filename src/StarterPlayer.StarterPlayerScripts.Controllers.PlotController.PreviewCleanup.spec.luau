--!strict
return function()
	local source=script.Parent.Source
	local function harness(count: number): (any,any)
		local first=string.find(source,"type RetiredPreview",1,true) or assert(string.find(source,"local function clearPool(",1,true))
		local last=assert(string.find(source,"local function drawSeg(",first,true))
		local pool={}
		local env: any=setmetatable({destroyed=0,folderDestroyed=0,waits=0,deferred={},clock=0,_worldRevision=0,
			_lastPreviewInputs={"cached"},PREVIEW_BUDGET=.003,breathePreview=function() end,
		},{__index=getfenv()})
		for _=1,count do table.insert(pool,{Destroy=function() env.destroyed+=1;env.clock+=.001 end}) end
		local folder={Parent={},Destroy=function() env.folderDestroyed+=1 end}
		env._preview=pool;env._folder=folder
		env.os={clock=function() return env.clock end}
		env.task={
			defer=function(fn) local co=coroutine.create(fn);table.insert(env.deferred,co);return co end,
			wait=function() env.waits+=1;coroutine.yield() end,
		}
		local fn=assert(loadstring(string.sub(source,first,last-1).."\nreturn clearPool"))
		setfenv(fn,env)
		return fn(),env
	end
	it("hides and transfers thousands of previews without synchronous destruction",function()
		local clear,env=harness(27000)
		local oldPool,oldFolder=env._preview,env._folder
		clear(oldPool)
		assert(env.destroyed==0,"input callback destroyed the entire preview synchronously")
		assert(oldFolder.Parent==nil and env._folder==nil,"retired preview stayed visible")
		assert(env._preview~=oldPool and #env._preview==0,"active drawing still owns retired instances")
		assert(env._worldRevision==1 and env._lastPreviewInputs==nil,"suspended renderer was not invalidated")
		assert(#env.deferred==1,"retirement needs exactly one worker")
	end)
	it("drains retired pools in budgeted slices and survives tool cleanup",function()
		local clear,env=harness(24)
		clear(env._preview)
		local old=env.deferred[1]
		assert(old,"cleanup was not scheduled")
		local nextPool={}
		for _=1,12 do table.insert(nextPool,{Destroy=function() env.destroyed+=1;env.clock+=.001 end}) end
		env._preview=nextPool;env._folder={Parent={},Destroy=function() env.folderDestroyed+=1 end}
		clear(nextPool)
		assert(#env.deferred==1,"a second cleanup worker was spawned")
		env._bound=false;env._enabled=false;env._previewWorker=nil
		local before=0
		while coroutine.status(old)~="dead" do
			local ok,err=coroutine.resume(old);assert(ok,err)
			assert(env.destroyed-before<=4,"cleanup exceeded its per-frame budget")
			before=env.destroyed
		end
		assert(env.destroyed==36 and env.folderDestroyed==2 and env.waits>=9,"cleanup leaked instances or skipped budget yields")
		env._preview={};env._folder={Parent={},Destroy=function() env.folderDestroyed+=1 end}
		clear(env._preview)
		assert(#env.deferred==2,"finished worker ownership was not released")
		assert(coroutine.resume(env.deferred[2]))
		assert(env.folderDestroyed==3,"empty final folder was retained")
	end)
end
