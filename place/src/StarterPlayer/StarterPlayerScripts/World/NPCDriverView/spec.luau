--!strict
return function()
	local source = (script.Parent :: ModuleScript).Source
	describe("Vehicle view ownership", function()
		it("a released car adopts its authoritative handoff pose instead of the last rendered road pose",function()
			local car=Instance.new("Model");local root=Instance.new("Part");root.Parent=car;car.PrimaryPart=root
			root.CFrame=CFrame.new(100,0,0);car:SetAttribute("NPCStoppedPose",CFrame.new(5,0,0))
			local env:any=setmetatable({_byId={},_idConns={},_hidden={},_fadeApplied={},
				_streamStamp={},_heardAt={},_dropped={},_rigs={},_tracked={[car]=root},
				_active={},_stash={},_trackedCount=1,_pending={}},{__index=getfenv()})
			local first=assert(source:find("local function untrack(",1,true));local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn untrack"));setfenv(fn,env);fn()(car)
			local position=root.Position;car:Destroy();expect(position).to.equal(Vector3.new(5,0,0))
		end)

		it("releasing a vehicle discards its hidden cached road pose", function()
			local car=Instance.new("Model")
			local env:any=setmetatable({_byId={},_idConns={},_hidden={},_fadeApplied={},
				_streamStamp={},_heardAt={},_dropped={},_rigs={},_tracked={[car]=true},
				_active={},_stash={[car]=CFrame.new(100,0,0)},_trackedCount=1,_pending={}}, {__index=getfenv()})
			local first=assert(source:find("local function untrack(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4).."\nreturn untrack"));setfenv(fn,env)
			fn()(car);local stale=env._stash[car];car:Destroy()
			expect(stale).to.equal(nil)
		end)
		it("stopping the view clears stale hidden poses and stream receipt state", function()
			local env:any=setmetatable({NPCDriverView={},_conns={},_pending={},_idConns={},
				_byId={},_streamStamp={},_hidden={},_fadeApplied={},_active={},_tracked={},_rigs={},
				_stash={old=CFrame.new()},_heardAt={old=10},_dropped={old=true}}, {__index=getfenv()})
			local first=assert(source:find("function NPCDriverView.Stop(",1,true))
			local last=assert(source:find("\nend",first,true))
			local fn=assert(loadstring(source:sub(first,last+4)));setfenv(fn,env);fn()
			env.NPCDriverView.Stop()
			expect(next(env._stash)).to.equal(nil)
			expect(next(env._heardAt)).to.equal(nil)
			expect(next(env._dropped)).to.equal(nil)
		end)
	end)
end