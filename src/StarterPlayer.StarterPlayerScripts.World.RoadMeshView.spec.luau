--!strict
return function()
	it("queues a road edit for this frame without a quiet timer",function()
		local source=script.Parent.Source
		local a=assert(source:find("local function schedule(key:",1,true))
		local b=assert(source:find("-- (Re)assign a road piece",a,true))
		local timers,queued=0,0
		local env=setmetatable({
			_cells={cell={version=0,meshes={}}},_scheduled=0,_roadScheduled={},
			isLotKey=function() return false end,
			enqueue=function() queued+=1 end,
			task={delay=function() timers+=1 end,defer=function(fn) fn() end},
		},{__index=getfenv()})
		local f=assert(loadstring(source:sub(a,b-1).."\nreturn schedule"));setfenv(f,env)
		f()("cell")
		assert(timers==0 and queued==1,"road edits wait out a render quiet timer")
	end)
end