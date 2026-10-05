--!nocheck
-- Headless stand-in for the Roblox engine, just enough to run the city's traffic modules
-- under lune: instances, services, signals, a simulated clock and a cooperative task
-- scheduler. Real datatypes (Vector3, CFrame, ...) come from lune's roblox library.

local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local E = {}

-- == Simulated clock ==========================================================
E.now = 0
local realClock = os.clock
E.realClock = realClock

-- == Random (deterministic) ===================================================
local Random = {}
Random.__index = Random
-- Seeds are scrambled (murmur3 finaliser) so neighbouring seeds give unrelated streams, as
-- Roblox's own Random does; a bare Lehmer step left pid*16+salt seeds almost in lockstep.
local function mul32(a, b)
	local ahi, alo = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	return (((ahi * b) % 65536) * 65536 + alo * b) % 4294967296
end
local function mix32(x)
	x = bit32.bxor(x, bit32.rshift(x, 16)); x = mul32(x, 0x85EBCA6B)
	x = bit32.bxor(x, bit32.rshift(x, 13)); x = mul32(x, 0xC2B2AE35)
	return bit32.bxor(x, bit32.rshift(x, 16))
end
function Random.new(seed)
	local raw = math.floor(tonumber(seed) or (E.now * 1000 + 12345))
	local s = mix32(bit32.band(raw % 4294967296, 0xFFFFFFFF)) % 2147483647
	if s <= 0 then s += 2147483646 end
	local r = setmetatable({ s = s }, Random)
	r:_next(); r:_next()
	return r
end
function Random:_next()
	self.s = (self.s * 48271) % 2147483647
	return self.s / 2147483647
end
function Random:NextNumber(a, b)
	local u = self:_next()
	if a then return a + (b - a) * u end
	return u
end
function Random:NextInteger(a, b)
	return math.floor(a + (b - a + 1) * self:_next())
end
E.Random = Random

-- == Signals ==================================================================
local Signal = {}
Signal.__index = Signal
function Signal.new() return setmetatable({ _h = {} }, Signal) end
function Signal:Connect(fn)
	local conn = { Connected = true }
	local list = self._h
	table.insert(list, conn)
	conn._fn = fn
	function conn.Disconnect(c)
		c.Connected = false
		local i = table.find(list, c)
		if i then table.remove(list, i) end
	end
	return conn
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...) c:Disconnect(); fn(...) end)
	return c
end
E.handlerTime = {}
function Signal:Fire(...)
	for _, c in table.clone(self._h) do
		if c.Connected then
			if E.profileHandlers then
				local src = debug.info(c._fn, "s") or "?"
				local t0 = os.clock()
				E.spawn(c._fn, ...)
				E.handlerTime[src] = (E.handlerTime[src] or 0) + (os.clock() - t0)
			else
				E.spawn(c._fn, ...)
			end
		end
	end
end
function Signal:Wait()
	local co = coroutine.running()
	local c
	c = self:Connect(function(...) c:Disconnect(); E.resume(co, ...) end)
	return coroutine.yield()
end
E.Signal = Signal

-- == Task scheduler ===========================================================
local sleeping = {} -- { co, at, args }
local deferred = {}
E.errors = {}

function E.resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		table.insert(E.errors, debug.traceback(co, tostring(err)))
		if E.onError then E.onError(err, co) end
	end
end

function E.spawn(fn, ...)
	if type(fn) == "thread" then E.resume(fn, ...); return fn end
	local co = coroutine.create(fn)
	E.resume(co, ...)
	return co
end

local task = {}
function task.spawn(fn, ...) return E.spawn(fn, ...) end
function task.defer(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	table.insert(deferred, { co = co, args = table.pack(...) })
	return co
end
function task.delay(t, fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	table.insert(sleeping, { co = co, at = E.now + (t or 0), args = table.pack(...) })
	return co
end
function task.wait(t)
	local co = coroutine.running()
	local start = E.now
	table.insert(sleeping, { co = co, at = E.now + math.max(t or 0, 1 / 60), args = { n = 0 } })
	coroutine.yield()
	return E.now - start
end
function task.cancel(co)
	for i = #sleeping, 1, -1 do
		if sleeping[i].co == co then table.remove(sleeping, i) end
	end
	for i = #deferred, 1, -1 do
		if deferred[i].co == co then table.remove(deferred, i) end
	end
end
function task.synchronize() end
function task.desynchronize() end
E.task = task

function E.runDeferred()
	local guard = 0
	while #deferred > 0 and guard < 10000 do
		guard += 1
		local item = table.remove(deferred, 1)
		if coroutine.status(item.co) == "suspended" then
			E.resume(item.co, table.unpack(item.args, 1, item.args.n))
		end
	end
end

function E.runSleepers()
	local due = {}
	for i = #sleeping, 1, -1 do
		local s = sleeping[i]
		if s.at <= E.now then
			table.remove(sleeping, i)
			table.insert(due, s)
		end
	end
	table.sort(due, function(a, b) return a.at < b.at end)
	for _, s in due do
		if coroutine.status(s.co) == "suspended" then
			E.resume(s.co, table.unpack(s.args, 1, s.args.n))
		end
	end
end

-- == Instances ================================================================
local Instance = {}
local INST = {} -- marker key
local classIsA = {
	Part = { BasePart = true, PVInstance = true },
	MeshPart = { BasePart = true, PVInstance = true },
	WedgePart = { BasePart = true, PVInstance = true },
	Model = { PVInstance = true },
	Folder = {},
	ModuleScript = { LuaSourceContainer = true },
	Script = { LuaSourceContainer = true, BaseScript = true },
	LocalScript = { LuaSourceContainer = true, BaseScript = true },
	Attachment = {},
	RemoteEvent = {},
	RemoteFunction = {},
	BindableEvent = {},
	BindableFunction = {},
	UnreliableRemoteEvent = {},
}

local tags = {}           -- inst -> { [tag]=true }
local tagged = {}         -- tag -> { [inst]=true }
local tagAdded = {}       -- tag -> Signal
local tagRemoved = {}

local methods = {}
local function rawProps(inst) return rawget(inst, "_p") end

function methods.GetAttribute(self, k) return rawget(self, "_a")[k] end
function methods.GetAttributes(self) return table.clone(rawget(self, "_a")) end
function methods.SetAttribute(self, k, v)
	local a = rawget(self, "_a")
	if a[k] == v then return end
	a[k] = v
	local sig = rawget(self, "_as")[k]
	if sig then sig:Fire() end
	local any = rawget(self, "_asAny")
	if any then any:Fire(k) end
end
function methods.GetAttributeChangedSignal(self, k)
	local s = rawget(self, "_as")[k]
	if not s then s = Signal.new(); rawget(self, "_as")[k] = s end
	return s
end
function methods.GetPropertyChangedSignal(self, k)
	local key = "prop:" .. k
	local s = rawget(self, "_as")[key]
	if not s then s = Signal.new(); rawget(self, "_as")[key] = s end
	return s
end
function methods.GetChildren(self) return table.clone(rawget(self, "_c")) end
function methods.GetDescendants(self)
	local out = {}
	local function walk(i)
		for _, c in rawget(i, "_c") do table.insert(out, c); walk(c) end
	end
	walk(self)
	return out
end
function methods.FindFirstChild(self, name, recursive)
	for _, c in rawget(self, "_c") do
		if rawProps(c).Name == name then return c end
	end
	if recursive then
		for _, c in rawget(self, "_c") do
			local f = methods.FindFirstChild(c, name, true)
			if f then return f end
		end
	end
	return nil
end
function methods.WaitForChild(self, name, _timeout)
	return methods.FindFirstChild(self, name)
end
function methods.FindFirstChildOfClass(self, cls)
	for _, c in rawget(self, "_c") do
		if rawProps(c).ClassName == cls then return c end
	end
	return nil
end
function methods.FindFirstChildWhichIsA(self, cls)
	for _, c in rawget(self, "_c") do
		if methods.IsA(c, cls) then return c end
	end
	return nil
end
function methods.FindFirstAncestorOfClass(self, cls)
	local p = rawProps(self).Parent
	while p do
		if rawProps(p).ClassName == cls then return p end
		p = rawProps(p).Parent
	end
	return nil
end
function methods.FindFirstAncestorWhichIsA(self, cls)
	local p = rawProps(self).Parent
	while p do
		if methods.IsA(p, cls) then return p end
		p = rawProps(p).Parent
	end
	return nil
end
function methods.FindFirstAncestor(self, name)
	local p = rawProps(self).Parent
	while p do
		if rawProps(p).Name == name then return p end
		p = rawProps(p).Parent
	end
	return nil
end
function methods.IsA(self, cls)
	local c = rawProps(self).ClassName
	if c == cls or cls == "Instance" then return true end
	local t = classIsA[c]
	return t ~= nil and t[cls] == true
end
function methods.IsDescendantOf(self, other)
	local p = rawProps(self).Parent
	while p do
		if p == other then return true end
		p = rawProps(p).Parent
	end
	return false
end
function methods.GetFullName(self)
	local parts = {}
	local i = self
	while i and rawProps(i).ClassName ~= "DataModel" do
		table.insert(parts, 1, rawProps(i).Name)
		i = rawProps(i).Parent
	end
	return table.concat(parts, ".")
end
function methods.ClearAllChildren(self)
	for _, c in table.clone(rawget(self, "_c")) do methods.Destroy(c) end
end
function methods.Destroy(self)
	if rawget(self, "_destroyed") then return end
	rawset(self, "_destroyed", true)
	for _, c in table.clone(rawget(self, "_c")) do methods.Destroy(c) end
	self.Parent = nil
	local t = tags[self]
	if t then
		for tag in t do
			if tagged[tag] then tagged[tag][self] = nil end
			if tagRemoved[tag] then tagRemoved[tag]:Fire(self) end
		end
		tags[self] = nil
	end
	local d = rawget(self, "_destroying")
	if d then d:Fire() end
end
function methods.Clone(self)
	local copy = Instance.new(rawProps(self).ClassName)
	for k, v in rawProps(self) do
		if k ~= "Parent" then rawProps(copy)[k] = v end
	end
	for k, v in rawget(self, "_a") do rawget(copy, "_a")[k] = v end
	if tags[self] then
		for tag in tags[self] do E.CollectionService:AddTag(copy, tag) end
	end
	local map = {}
	for _, c in rawget(self, "_c") do
		local cc = methods.Clone(c)
		map[c] = cc
		cc.Parent = copy
	end
	local pp = rawProps(self).PrimaryPart
	if pp and map[pp] then rawProps(copy).PrimaryPart = map[pp] end
	return copy
end
-- Pivot helpers. A Model's pivot is its PrimaryPart's CFrame (or its own stored pivot).
function methods.GetPivot(self)
	local p = rawProps(self)
	if p.ClassName == "Model" then
		if p.PrimaryPart then return rawProps(p.PrimaryPart).CFrame end
		return p.WorldPivot or roblox.CFrame.identity
	end
	return p.CFrame or roblox.CFrame.identity
end
function methods.PivotTo(self, cf)
	local p = rawProps(self)
	if p.ClassName == "Model" then
		local old = methods.GetPivot(self)
		local delta = cf * old:Inverse()
		for _, d in methods.GetDescendants(self) do
			local dp = rawProps(d)
			if dp.CFrame and methods.IsA(d, "BasePart") then dp.CFrame = delta * dp.CFrame end
		end
		if not p.PrimaryPart then p.WorldPivot = cf end
	else
		p.CFrame = cf
	end
end
function methods.GetExtentsSize(self)
	local p = rawProps(self)
	if p.ExtentsSize then return p.ExtentsSize end
	local pp = p.PrimaryPart
	if pp then return rawProps(pp).Size end
	return p.Size or roblox.Vector3.new(4, 3, 8)
end
function methods.GetBoundingBox(self)
	return methods.GetPivot(self), methods.GetExtentsSize(self)
end
function methods.AddTag(self, tag) E.CollectionService:AddTag(self, tag) end
function methods.RemoveTag(self, tag) E.CollectionService:RemoveTag(self, tag) end
function methods.HasTag(self, tag) return E.CollectionService:HasTag(self, tag) end
function methods.GetTags(self)
	local out = {}
	for t in tags[self] or {} do table.insert(out, t) end
	return out
end
-- Remotes
function methods.FireClient() end
function methods.FireAllClients() end
function methods.FireServer() end
function methods.InvokeClient() end
function methods.InvokeServer() end
function methods.Fire(self, ...)
	local ev = rawget(self, "_event")
	if ev then ev:Fire(...) end
end

local InstMeta = {}
function InstMeta.__index(self, k)
	local m = methods[k]
	if m then return m end
	local p = rawProps(self)
	local v = p[k]
	if v ~= nil then return v end
	if k == "Position" and p.CFrame then return p.CFrame.Position end
	if k == "WorldPosition" and p.WorldCFrame then return p.WorldCFrame.Position end
	if k == "Destroying" then
		local d = rawget(self, "_destroying")
		if not d then d = Signal.new(); rawset(self, "_destroying", d) end
		return d
	end
	if k == "ChildAdded" or k == "ChildRemoved" or k == "DescendantAdded" or k == "DescendantRemoving"
		or k == "AncestryChanged" or k == "OnServerEvent" or k == "OnClientEvent" or k == "Event" then
		local key = "_sig" .. k
		local s = rawget(self, key)
		if not s then s = Signal.new(); rawset(self, key, s) end
		if k == "Event" then rawset(self, "_event", s) end
		return s
	end
	local child = methods.FindFirstChild(self, k)
	if child then return child end
	return nil
end
function InstMeta.__newindex(self, k, v)
	local p = rawProps(self)
	if k == "Parent" then
		local old = p.Parent
		if old == v then return end
		if old then
			local list = rawget(old, "_c")
			local i = table.find(list, self)
			if i then table.remove(list, i) end
			local s = rawget(old, "_sigChildRemoved")
			if s then s:Fire(self) end
		end
		p.Parent = v
		if v then
			table.insert(rawget(v, "_c"), self)
			local s = rawget(v, "_sigChildAdded")
			if s then s:Fire(self) end
		end
		return
	end
	if k == "Position" and p.CFrame then
		p.CFrame = p.CFrame - p.CFrame.Position + v
		return
	end
	p[k] = v
	local sig = rawget(self, "_as")["prop:" .. k]
	if sig then sig:Fire() end
end
InstMeta.__tostring = function(self) return rawProps(self).Name end
InstMeta[INST] = true

function Instance.new(cls, parent)
	local inst = setmetatable({ _p = { ClassName = cls, Name = cls }, _c = {}, _a = {}, _as = {} }, InstMeta)
	if cls == "Part" or cls == "MeshPart" then
		local p = rawProps(inst)
		p.CFrame = roblox.CFrame.identity
		p.Size = roblox.Vector3.new(4, 1, 2)
		p.Anchored = false
		p.CanCollide = true
		p.CanQuery = true
		p.Transparency = 0
	elseif cls == "Attachment" then
		rawProps(inst).WorldCFrame = roblox.CFrame.identity
	end
	if parent then inst.Parent = parent end
	return inst
end
E.Instance = Instance
function E.isInstance(v)
	return type(v) == "table" and getmetatable(v) == InstMeta
end

-- == Services =================================================================
local CollectionService = Instance.new("CollectionService")
rawProps(CollectionService).Name = "CollectionService"
local function sigFor(map, tag)
	local s = map[tag]
	if not s then s = Signal.new(); map[tag] = s end
	return s
end
local CS = {}
function CS.AddTag(_, inst, tag)
	local t = tags[inst]
	if not t then t = {}; tags[inst] = t end
	if t[tag] then return end
	t[tag] = true
	local set = tagged[tag]
	if not set then set = {}; tagged[tag] = set end
	set[inst] = true
	if tagAdded[tag] then tagAdded[tag]:Fire(inst) end
end
function CS.RemoveTag(_, inst, tag)
	local t = tags[inst]
	if not t or not t[tag] then return end
	t[tag] = nil
	if tagged[tag] then tagged[tag][inst] = nil end
	if tagRemoved[tag] then tagRemoved[tag]:Fire(inst) end
end
function CS.HasTag(_, inst, tag)
	local t = tags[inst]
	return t ~= nil and t[tag] == true
end
function CS.GetTagged(_, tag)
	local out = {}
	for inst in tagged[tag] or {} do table.insert(out, inst) end
	return out
end
function CS.GetTags(_, inst) return methods.GetTags(inst) end
function CS.GetInstanceAddedSignal(_, tag) return sigFor(tagAdded, tag) end
function CS.GetInstanceRemovedSignal(_, tag) return sigFor(tagRemoved, tag) end
for k, f in CS do methods[k] = methods[k] or f end
-- methods table is shared, so expose CS functions through the CollectionService proxy only
local CSProxy = setmetatable({}, { __index = function(_, k) return CS[k] or CollectionService[k] end })
E.CollectionService = CSProxy

local RunService = { Heartbeat = Signal.new(), Stepped = Signal.new(), PostSimulation = Signal.new(),
	PreSimulation = Signal.new(), RenderStepped = Signal.new() }
function RunService:IsServer() return true end
function RunService:IsClient() return false end
function RunService:IsStudio() return true end
function RunService:IsRunning() return true end
function RunService:IsRunMode() return false end
E.RunService = RunService

local Players = { PlayerAdded = Signal.new(), PlayerRemoving = Signal.new(), _list = {} }
function Players:GetPlayers() return self._list end
function Players:GetPlayerByUserId() return nil end
E.Players = Players

local Workspace = Instance.new("Workspace")
rawProps(Workspace).Name = "Workspace"
local wsMethods = {}
function wsMethods.Raycast() return nil end
function wsMethods.GetPartBoundsInRadius() return {} end
function wsMethods.GetPartBoundsInBox() return {} end
function wsMethods.GetPartsInPart() return {} end
function wsMethods.Spherecast() return nil end
function wsMethods.Blockcast() return nil end
for k, f in wsMethods do methods[k] = methods[k] or f end
E.Workspace = Workspace

local HttpService = {}
function HttpService:JSONEncode(v) return serde.encode("json", v) end
function HttpService:JSONDecode(s) return serde.decode("json", s) end
function HttpService:GenerateGUID() return tostring(math.random(1, 1e9)) end

local ServerStorage = Instance.new("ServerStorage"); rawProps(ServerStorage).Name = "ServerStorage"
local ReplicatedStorage = Instance.new("ReplicatedStorage"); rawProps(ReplicatedStorage).Name = "ReplicatedStorage"
local ServerScriptService = Instance.new("ServerScriptService"); rawProps(ServerScriptService).Name = "ServerScriptService"
local StarterPlayer = Instance.new("StarterPlayer"); rawProps(StarterPlayer).Name = "StarterPlayer"
local ReplicatedFirst = Instance.new("ReplicatedFirst"); rawProps(ReplicatedFirst).Name = "ReplicatedFirst"
local Lighting = Instance.new("Lighting"); rawProps(Lighting).Name = "Lighting"

local game = Instance.new("DataModel")
rawProps(game).Name = "Game"
for _, s in { Workspace, ServerStorage, ReplicatedStorage, ServerScriptService, StarterPlayer, ReplicatedFirst, Lighting } do
	s.Parent = game
end
local services = {
	Workspace = Workspace, ServerStorage = ServerStorage, ReplicatedStorage = ReplicatedStorage,
	ServerScriptService = ServerScriptService, StarterPlayer = StarterPlayer, ReplicatedFirst = ReplicatedFirst,
	Lighting = Lighting, CollectionService = CSProxy, RunService = RunService, Players = Players,
	HttpService = HttpService,
}
local genericServices = {}
methods.GetService = function(_, name)
	local s = services[name]
	if s then return s end
	s = genericServices[name]
	if not s then
		s = Instance.new(name)
		rawProps(s).Name = name
		genericServices[name] = s
	end
	return s
end
rawProps(game).HttpService = HttpService -- game.HttpService, as the specs index it
E.game = game
E.services = services

-- == Module tree from the extracted sources ===================================
-- src/<Service>/<A>/<B>.luau  -> game.<Service>.A.B (ModuleScript); a directory with the
-- same name as a module holds its children.
local SRC
local function ensurePath(root, parts)
	local node = root
	for _, name in parts do
		local child = methods.FindFirstChild(node, name)
		if not child then
			child = Instance.new("Folder")
			rawProps(child).Name = name
			child.Parent = node
		end
		node = child
	end
	return node
end

function E.mountSources(srcDir)
	SRC = srcDir
	local function walk(dir, rel)
		for _, name in fs.readDir(dir) do
			local full = dir .. "/" .. name
			if fs.isDir(full) then
				walk(full, if rel == "" then name else rel .. "/" .. name)
			elseif name:sub(-5) == ".luau" and name:sub(1, 1) ~= "_" then
				local base = name:gsub("%.server%.luau$", ""):gsub("%.client%.luau$", ""):gsub("%.luau$", "")
				if base:find("%.dup%d+") then continue end
				local cls = if name:find("%.server%.luau$") then "Script"
					elseif name:find("%.client%.luau$") then "LocalScript" else "ModuleScript"
				local parts = string.split(if rel == "" then base else rel .. "/" .. base, "/")
				local svcName = table.remove(parts, 1)
				local root = services[svcName]
				if not root then continue end
				local leaf = table.remove(parts)
				local parent = ensurePath(root, parts)
				local existing = methods.FindFirstChild(parent, leaf)
				if existing and rawProps(existing).ClassName == "Folder" then
					rawProps(existing).ClassName = cls
					rawProps(existing).SourcePath = full
				elseif not existing then
					local m = Instance.new(cls)
					rawProps(m).Name = leaf
					rawProps(m).SourcePath = full
					m.Parent = parent
				end
			end
		end
	end
	walk(srcDir, "")
end

-- Override a module's source file (patched copy) by full dotted path.
function E.overrideSource(dotted, filePath)
	local parts = string.split(dotted, ".")
	local node = game
	for _, name in parts do
		node = if node == game then services[name] else methods.FindFirstChild(node, name)
		assert(node, "no module " .. dotted)
	end
	rawProps(node).SourcePath = filePath
end

-- == require ==================================================================
E.stubs = {}       -- full dotted name -> value
E.loaded = {}      -- inst -> result
local loading = {}

local baseTypeof = typeof
local function fakeTypeof(v)
	if E.isInstance(v) then return "Instance" end
	if type(v) == "table" and getmetatable(v) == Random then return "Random" end
	if type(v) == "table" and getmetatable(v) == Signal then return "RBXScriptSignal" end
	return baseTypeof(v)
end
E.typeof = fakeTypeof

local warnings = {}
E.warnings = warnings
local function fakeWarn(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	local msg = table.concat(parts, " ")
	table.insert(warnings, msg)
	if E.echoWarnings then print("[warn] " .. msg) end
end

local fakeOs = setmetatable({
	clock = function() return E.now end,
	time = function() return math.floor(1700000000 + E.now) end,
}, { __index = os })

local RaycastParams = { new = function() return { FilterDescendantsInstances = {}, FilterType = nil } end }
local OverlapParams = { new = function() return { FilterDescendantsInstances = {}, FilterType = nil, MaxParts = 0 } end }

function E.makeEnv(scriptInst)
	local env = {
		game = game, workspace = Workspace, script = scriptInst,
		Vector3 = roblox.Vector3, CFrame = roblox.CFrame, Color3 = roblox.Color3, Vector2 = roblox.Vector2,
		UDim2 = roblox.UDim2, UDim = roblox.UDim, NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence, NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence, ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		BrickColor = roblox.BrickColor, Rect = roblox.Rect, Region3 = roblox.Region3, Ray = roblox.Ray,
		Vector3int16 = roblox.Vector3int16, PhysicalProperties = roblox.PhysicalProperties, Font = roblox.Font,
		Enum = roblox.Enum, Instance = Instance, Random = Random, RaycastParams = RaycastParams,
		OverlapParams = OverlapParams, task = task, typeof = fakeTypeof, warn = fakeWarn, os = fakeOs,
		tick = function() return E.now end, time = function() return E.now end,
		wait = task.wait, delay = task.delay, spawn = task.spawn,
		DateTime = { now = function() return { UnixTimestamp = math.floor(E.now), UnixTimestampMillis = math.floor(E.now * 1000) } end },
		print = print, error = error, assert = assert, pcall = pcall, xpcall = xpcall, select = select,
		type = type, tostring = tostring, tonumber = tonumber, pairs = pairs, ipairs = ipairs, next = next,
		setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset,
		rawequal = rawequal, rawlen = rawlen, unpack = table.unpack,
		math = math, string = string, table = table, coroutine = coroutine, debug = debug, utf8 = utf8,
		buffer = buffer, bit32 = bit32, vector = vector,
	}
	env.require = function(target)
		return E.require(target)
	end
	-- Studio's loadstring / getfenv / setfenv, enough for the project's own spec runners.
	-- lune's load copies an environment table (no metatable, no later writes), so the chunk is
	-- loaded plainly and bound with the native setfenv, which keeps both.
	env.loadstring = function(src, chunkname)
		local ok, fn = pcall(luau.load, src, { debugName = chunkname or "loadstring", environment = env })
		if not ok then return nil, tostring(fn) end
		return fn
	end
	env.setfenv = function(fn, e)
		setfenv(fn, e)
		return fn
	end
	env.getfenv = function() return env end
	env._G = env
	env.shared = {}
	return env
end

-- script.Source for every mounted module (the project's specs read their own sources).
function E.preloadSources()
	for _, svc in game:GetChildren() do
		for _, d in svc:GetDescendants() do
			local p = rawProps(d)
			if p.SourcePath then p.Source = fs.readFile(p.SourcePath) end
		end
	end
end

function E.require(target)
	if type(target) == "string" then error("string require not supported: " .. target) end
	assert(E.isInstance(target), "require expects an Instance, got " .. fakeTypeof(target))
	local full = methods.GetFullName(target)
	local stub = E.stubs[full] or E.stubs[rawProps(target).Name]
	if stub ~= nil then return stub end
	local cached = E.loaded[target]
	if cached ~= nil then return cached end
	if loading[target] then error("cyclic require: " .. full) end
	local path = rawProps(target).SourcePath
	assert(path, "module has no source: " .. full)
	loading[target] = true
	local source = fs.readFile(path)
	if E.sourceFilter then source = E.sourceFilter(full, source) end
	local fn = luau.load(source, { debugName = full, environment = E.makeEnv(target) })
	local result = fn()
	loading[target] = nil
	E.loaded[target] = result
	return result
end

-- Load a module's source with extra text appended/replaced (exposes internals to tests).
function E.requireWith(target, transform)
	local full = methods.GetFullName(target)
	local source = fs.readFile(rawProps(target).SourcePath)
	source = transform(source)
	local fn = luau.load(source, { debugName = full, environment = E.makeEnv(target) })
	local result = fn()
	E.loaded[target] = result
	return result
end

function E.resolve(dotted)
	local parts = string.split(dotted, ".")
	local node = services[table.remove(parts, 1)]
	for _, name in parts do
		node = node and methods.FindFirstChild(node, name)
	end
	return node
end

-- == Frame driver =============================================================
function E.step(dt)
	E.now += dt
	E.runSleepers()
	RunService.Stepped:Fire(E.now, dt)
	RunService.Heartbeat:Fire(dt)
	E.runDeferred()
end

-- Fake player with a camera position, so LOD treats cars near it as visible.
function E.addPlayer(name, camPos)
	local p = Instance.new("Player")
	rawProps(p).Name = name
	rawProps(p).UserId = #Players._list + 1
	table.insert(Players._list, p)
	return p
end

E.roblox = roblox
return E
