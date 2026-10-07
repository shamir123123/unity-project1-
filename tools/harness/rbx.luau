--!nocheck
-- Minimal Roblox-ish runtime for running game modules under Lune (offline benchmarks and
-- correctness checks). Instances are plain Luau objects: enough of the API for the road,
-- terrain and mesh libraries to load and run, nothing more. Not the engine.
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local M = {}

-- Signals ---------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _conns = {} }, Signal)
end
function Signal:Connect(fn)
	local conn = { Connected = true, _fn = fn, _sig = self }
	function conn.Disconnect(c)
		c.Connected = false
		local i = table.find(self._conns, c)
		if i then table.remove(self._conns, i) end
	end
	conn.disconnect = conn.Disconnect
	table.insert(self._conns, conn)
	return conn
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end
function Signal:Fire(...)
	for _, c in table.clone(self._conns) do
		if c.Connected then task.spawn(c._fn, ...) end
	end
end
function Signal:Wait()
	local co = coroutine.running()
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		task.spawn(co, ...)
	end)
	return coroutine.yield()
end
M.Signal = Signal

-- Instances -------------------------------------------------------------------------------
local ISA = {
	ModuleScript = { "LuaSourceContainer" }, Script = { "BaseScript", "LuaSourceContainer" },
	LocalScript = { "Script", "BaseScript", "LuaSourceContainer" },
	Part = { "BasePart", "PVInstance" }, MeshPart = { "BasePart", "TriangleMeshPart", "PVInstance" },
	WedgePart = { "BasePart", "PVInstance" }, Model = { "PVInstance" }, Workspace = { "Model", "PVInstance" },
	StringValue = { "ValueBase" }, IntValue = { "ValueBase" }, NumberValue = { "ValueBase" }, BoolValue = { "ValueBase" },
	ObjectValue = { "ValueBase" }, Decal = { "FaceInstance" }, Texture = { "Decal", "FaceInstance" },
	RemoteEvent = { "BaseRemoteEvent" }, UnreliableRemoteEvent = { "BaseRemoteEvent" },
}

local Instance = {}
local _allTags: { [string]: { [any]: boolean } } = {}
M.tagged = _allTags

local function newRaw(className: string, name: string?)
	local self = {
		_class = className,
		_name = name or className,
		_parent = nil,
		_kids = {},
		_attrs = {},
		_props = {},
		_signals = {},
		_tags = {},
	}
	return setmetatable(self, Instance)
end

local function sig(self, key)
	local s = self._signals[key]
	if not s then
		s = Signal.new()
		self._signals[key] = s
	end
	return s
end

local methods = {}
function methods:FindFirstChild(name, recursive)
	for _, c in self._kids do
		if c._name == name then return c end
	end
	if recursive then
		for _, c in self._kids do
			local f = c:FindFirstChild(name, true)
			if f then return f end
		end
	end
	return nil
end
function methods:WaitForChild(name, _timeout)
	return self:FindFirstChild(name)
end
function methods:GetChildren()
	return table.clone(self._kids)
end
function methods:GetDescendants()
	local out = {}
	local function walk(i)
		for _, c in i._kids do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods:IsA(cls)
	if self._class == cls or cls == "Instance" then return true end
	for _, b in (ISA[self._class] or {}) do
		if b == cls then return true end
	end
	return false
end
function methods:IsDescendantOf(other)
	local p = self._parent
	while p do
		if p == other then return true end
		p = p._parent
	end
	return false
end
function methods:FindFirstChildOfClass(cls)
	for _, c in self._kids do
		if c._class == cls then return c end
	end
	return nil
end
function methods:FindFirstChildWhichIsA(cls, recursive)
	for _, c in self._kids do
		if c:IsA(cls) then return c end
	end
	if recursive then
		for _, c in self._kids do
			local f = c:FindFirstChildWhichIsA(cls, true)
			if f then return f end
		end
	end
	return nil
end
function methods:FindFirstAncestor(name)
	local p = self._parent
	while p do
		if p._name == name then return p end
		p = p._parent
	end
	return nil
end
function methods:FindFirstAncestorOfClass(cls)
	local p = self._parent
	while p do
		if p._class == cls then return p end
		p = p._parent
	end
	return nil
end
function methods:FindFirstAncestorWhichIsA(cls)
	local p = self._parent
	while p do
		if p:IsA(cls) then return p end
		p = p._parent
	end
	return nil
end
function methods:GetAttribute(k)
	return self._attrs[k]
end
function methods:SetAttribute(k, v)
	if self._attrs[k] == v then return end
	self._attrs[k] = v
	local s = self._signals["attr:" .. k]
	if s then s:Fire() end
	local s2 = self._signals.AttributeChanged
	if s2 then s2:Fire(k) end
end
function methods:GetAttributes()
	return table.clone(self._attrs)
end
function methods:GetAttributeChangedSignal(k)
	return sig(self, "attr:" .. k)
end
function methods:GetPropertyChangedSignal(k)
	return sig(self, "prop:" .. k)
end
function methods:GetFullName()
	local parts = {}
	local i = self
	while i and i._class ~= "DataModel" do
		table.insert(parts, 1, i._name)
		i = i._parent
	end
	return table.concat(parts, ".")
end
function methods:Destroy()
	self.Parent = nil
	for _, c in table.clone(self._kids) do c:Destroy() end
	self._destroyed = true
end
function methods:ClearAllChildren()
	for _, c in table.clone(self._kids) do c:Destroy() end
end
function methods:Clone()
	local c = newRaw(self._class, self._name)
	for k, v in self._props do c._props[k] = v end
	for k, v in self._attrs do c._attrs[k] = v end
	for t in self._tags do c._tags[t] = true end
	for _, k in self._kids do k:Clone().Parent = c end
	return c
end
function methods:GetPivot()
	return self._props.Pivot or self._props.CFrame or roblox.CFrame.new()
end
function methods:PivotTo(cf)
	self._props.Pivot = cf
	self._props.CFrame = cf
end
function methods:AddTag(t)
	self._tags[t] = true
	_allTags[t] = _allTags[t] or {}
	_allTags[t][self] = true
end
function methods:RemoveTag(t)
	self._tags[t] = nil
	if _allTags[t] then _allTags[t][self] = nil end
end
function methods:HasTag(t)
	return self._tags[t] == true
end
function methods:GetTags()
	local out = {}
	for t in self._tags do table.insert(out, t) end
	return out
end
-- remotes / bindables
function methods:FireServer() end
function methods:FireClient() end
function methods:FireAllClients() end
function methods:Fire(...)
	sig(self, "Event"):Fire(...)
end
function methods:InvokeServer() return nil end

local EVENTS = {
	ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
	AncestryChanged = true, Changed = true, AttributeChanged = true, Destroying = true,
	OnServerEvent = true, OnClientEvent = true, Event = true, OnInvoke = true,
}

local DEFAULTS = {
	Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true,
	Transparency = 0, LocalTransparencyModifier = 0, Value = nil,
}

Instance.__index = function(self, k)
	local m = methods[k]
	if m then return m end
	if k == "Name" then return self._name end
	if k == "ClassName" then return self._class end
	if k == "Parent" then return self._parent end
	if EVENTS[k] then return sig(self, k) end
	local p = self._props[k]
	if p ~= nil then return p end
	local c = methods.FindFirstChild(self, k)
	if c then return c end
	if k == "Position" and self._props.CFrame then return self._props.CFrame.Position end
	return DEFAULTS[k]
end

local function fireUp(i, name, inst)
	local p = i
	while p do
		local s = p._signals[name]
		if s then s:Fire(inst) end
		p = p._parent
	end
end

Instance.__newindex = function(self, k, v)
	if k == "Name" then
		self._name = v
	elseif k == "Parent" then
		local old = self._parent
		if old == v then return end
		if old then
			local i = table.find(old._kids, self)
			if i then table.remove(old._kids, i) end
			local s = old._signals.ChildRemoved
			if s then s:Fire(self) end
			fireUp(old, "DescendantRemoving", self)
		end
		self._parent = v
		if v then
			table.insert(v._kids, self)
			local s = v._signals.ChildAdded
			if s then s:Fire(self) end
			fireUp(v, "DescendantAdded", self)
		end
	else
		self._props[k] = v
		if k == "CFrame" then self._props.Pivot = v end
		local s = self._signals["prop:" .. k]
		if s then s:Fire() end
	end
end
Instance.__tostring = function(self)
	return self._name
end
Instance.__type = "Instance"

M.Instance = {
	new = function(className, parent)
		local i = newRaw(className)
		if parent then i.Parent = parent end
		return i
	end,
}
M.newRaw = newRaw
M.isInstance = function(v)
	return type(v) == "table" and getmetatable(v) == Instance
end

-- typeof that knows our instances
local rawTypeof = typeof
M.typeof = function(v)
	if type(v) == "table" and getmetatable(v) == Instance then return "Instance" end
	return rawTypeof(v)
end

return M
