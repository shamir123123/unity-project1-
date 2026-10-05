-- Minimal Roblox-ish runtime for running the place's modules under Lune.
-- Uses the real DOM from the place (via @lune/roblox) and a bundle of module sources.
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local process = require("@lune/process")

local Runtime = {}

-- Deterministic stand-in for Roblox's Random (not bit-identical, fine for benchmarks).
local Random = {}
Random.__index = Random
function Random.new(seed: number?)
	local s = math.floor((seed or os.clock() * 1e6)) % 2147483647
	if s <= 0 then s += 2147483646 end
	return setmetatable({ _s = s }, Random)
end
function Random:_next(): number
	self._s = (self._s * 48271) % 2147483647
	return self._s / 2147483647
end
function Random:NextNumber(a: number?, b: number?): number
	local lo, hi = a or 0, b or 1
	return lo + (hi - lo) * self:_next()
end
function Random:NextInteger(a: number, b: number): number
	return math.floor(a + (b - a + 1) * self:_next())
end
function Random:Clone()
	return setmetatable({ _s = self._s }, Random)
end
function Random:Shuffle(t)
	for i = #t, 2, -1 do
		local j = self:NextInteger(1, i)
		t[i], t[j] = t[j], t[i]
	end
end
function Random:NextUnitVector()
	local z = self:NextNumber(-1, 1)
	local a = self:NextNumber(0, math.pi * 2)
	local r = math.sqrt(1 - z * z)
	return roblox.Vector3.new(r * math.cos(a), r * math.sin(a), z)
end
Runtime.Random = Random

function Runtime.load(opts: { place: string?, bundle: string, game: any?, shared: any?, services: any?, globals: any? })
	local game = opts.game
	if not game and opts.place then
		local t0 = os.clock()
		game = roblox.deserializePlace(fs.readFile(opts.place))
		print(string.format("[runtime] place loaded in %.2fs", os.clock() - t0))
	end
	-- Lune resolves `.Terrain` as Workspace's property on every instance; route it to the child.
	pcall(roblox.implementProperty, "Instance", "Terrain", function(self)
		local c = self:FindFirstChild("Terrain")
		if c then return c end
		if self.ClassName == "Workspace" then return self:FindFirstChildOfClass("Terrain") end
		error("Terrain is not a valid member of " .. self.ClassName)
	end)
	-- Services Lune does not model come from opts.services (plain tables with the methods used).
	local mocks = opts.services or {}
	local serde = require("@lune/serde")
	mocks.EncodingService = mocks.EncodingService or {
		CompressBuffer = function(_, b, _algo, level)
			return buffer.fromstring(serde.compress("zstd", buffer.tostring(b), level))
		end,
		DecompressBuffer = function(_, b, _algo)
			return buffer.fromstring(serde.decompress("zstd", buffer.tostring(b)))
		end,
	}
	pcall(roblox.implementMethod, "DataModel", "GetService", function(self, name)
		if mocks[name] then return mocks[name] end
		local existing = self:FindFirstChildOfClass(name)
		if existing then return existing end
		local ok, inst = pcall(roblox.Instance.new, name)
		if ok then inst.Parent = self return inst end
		error("'" .. tostring(name) .. "' is not a valid service name")
	end)
	-- No engine events in Lune: every signal is a stub that accepts connections and never fires.
	local function stubSignal()
		return {
			Connect = function() return { Disconnect = function() end, Connected = true } end,
			Once = function() return { Disconnect = function() end, Connected = true } end,
			Wait = function() return task.wait() end,
		}
	end
	pcall(roblox.implementMethod, "Instance", "GetAttributeChangedSignal", function() return stubSignal() end)
	pcall(roblox.implementMethod, "Instance", "GetPropertyChangedSignal", function() return stubSignal() end)
	for _, ev in { "Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged",
		"Destroying", "AttributeChanged", "OnServerEvent", "OnClientEvent", "Event", "PlayerAdded", "PlayerRemoving",
		"Heartbeat", "Stepped", "RenderStepped", "CharacterAdded" } do
		pcall(roblox.implementProperty, "Instance", ev, function() return stubSignal() end)
	end
	-- Approximate Model/PVInstance pivots (enough for render/placement code to run and be timed).
	local CFrame, Vector3 = roblox.CFrame, roblox.Vector3
	local function modelPivot(self)
		local pp = self.PrimaryPart
		if pp then return pp.CFrame end
		local ok, wp = pcall(function() return self.WorldPivot end)
		if ok and wp then return wp end
		return CFrame.identity
	end
	pcall(roblox.implementMethod, "Model", "GetPivot", modelPivot)
	pcall(roblox.implementMethod, "BasePart", "GetPivot", function(self) return self.CFrame end)
	pcall(roblox.implementMethod, "BasePart", "PivotTo", function(self, cf) self.CFrame = cf end)
	pcall(roblox.implementMethod, "Model", "PivotTo", function(self, cf)
		local delta = cf * modelPivot(self):Inverse()
		for _, d in self:GetDescendants() do
			if d:IsA("BasePart") then d.CFrame = delta * d.CFrame end
		end
		pcall(function() self.WorldPivot = cf end)
	end)
	local function bbox(self)
		local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, d in self:GetDescendants() do
			if d:IsA("BasePart") then
				local p, h = d.CFrame.Position, d.Size * 0.5
				lo = lo:Min(p - h); hi = hi:Max(p + h)
			end
		end
		if lo.X > hi.X then return CFrame.identity, Vector3.zero end
		return CFrame.new((lo + hi) * 0.5), hi - lo
	end
	pcall(roblox.implementMethod, "Model", "GetBoundingBox", bbox)
	pcall(roblox.implementMethod, "Model", "GetExtentsSize", function(self) local _, sz = bbox(self) return sz end)
	pcall(roblox.implementMethod, "Model", "GetScale", function(self) return self:GetAttribute("__scale") or 1 end)
	pcall(roblox.implementMethod, "Model", "ScaleTo", function(self, s) self:SetAttribute("__scale", s) end)
	pcall(roblox.implementMethod, "Instance", "WaitForChild", function(self, name, _timeout)
		return self:FindFirstChild(name)
	end)
	local loaders = {}
	local cache = {}
	local loading = {}
	local function req(x: any): any
		if type(x) == "string" then
			return require(x)
		end
		local full = x:GetFullName()
		local c = cache[full]
		if c ~= nil then return c.v end
		local f = loaders[full]
		if not f then error("[runtime] no module " .. full) end
		if loading[full] then error("[runtime] cyclic require " .. full) end
		loading[full] = true
		local v = f(x)
		loading[full] = nil
		cache[full] = { v = v }
		return v
	end
	local bundleFn = require(opts.bundle)
	local function tick() return os.clock() end
	local function wait(t) return task.wait(t) end
	local function delay(t, f) return task.delay(t, f) end
	local function spawn(f) return task.spawn(f) end
	local ws = game and game:FindFirstChildOfClass("Workspace")
	-- Modules added by the fixes do not exist in the place file yet: give each one an instance.
	local function ensureModules()
		for full in loaders do
			local cur = game
			local parts = string.split(full, ".")
			for i, part in parts do
				local nxt = cur:FindFirstChild(part)
				if not nxt then
					nxt = roblox.Instance.new(if i == #parts then "ModuleScript" else "Folder")
					nxt.Name = part
					nxt.Parent = cur
				end
				cur = nxt
			end
		end
	end
	-- Lune will not let GetService be overridden, so modules see a thin proxy of the DataModel.
	local realGame = game
	local gameProxy = if realGame then setmetatable({}, {
		__index = function(_, k)
			if k == "GetService" then
				return function(_, name)
					if mocks[name] then return mocks[name] end
					local existing = realGame:FindFirstChildOfClass(name)
					if existing then return existing end
					local ok, inst = pcall(realGame.GetService, realGame, name)
					if ok then return inst end
					error("'" .. tostring(name) .. "' is not a valid service name")
				end
			end
			local v = realGame[k]
			if type(v) == "function" then
				return function(_, ...) return v(realGame, ...) end
			end
			return v
		end,
	}) else nil
	-- Enums newer than Lune's reflection database resolve to stable placeholder items.
	local fakeEnums = {}
	local EnumProxy = setmetatable({}, {
		__index = function(_, k)
			local ok, e = pcall(function() return roblox.Enum[k] end)
			if ok and e then return e end
			local fe = fakeEnums[k]
			if not fe then
				fe = setmetatable({}, { __index = function(t, item)
					local v = "Enum." .. k .. "." .. item
					rawset(t, item, v)
					return v
				end })
				fakeEnums[k] = fe
			end
			return fe
		end,
	})
	local g = opts.globals or {}
	local function pick(name, default)
		local v = g[name]
		if v ~= nil then return v end
		return default
	end
	bundleFn(loaders, req, gameProxy, pick("workspace", ws), EnumProxy, roblox.Instance, roblox.Vector3, roblox.Vector2, roblox.CFrame,
		roblox.Color3, roblox.Region3, roblox.BrickColor, roblox.UDim2, roblox.UDim, roblox.NumberSequence,
		roblox.NumberSequenceKeypoint, roblox.ColorSequence, roblox.ColorSequenceKeypoint, roblox.NumberRange,
		roblox.Ray, Random, task, pick("warn", warn or print), tick, pick("Content", roblox.Content), roblox.Font, roblox.PhysicalProperties,
		nil, nil, nil, nil, roblox.Rect, roblox.Faces, roblox.Axes, roblox.Vector3int16, roblox.Region3int16,
		opts.shared or {}, delay, spawn, wait)
	if game then ensureModules() end
	return {
		game = game,
		require = req,
		loaders = loaders,
		find = function(path: string): any
			local cur = game
			for part in string.gmatch(path, "[^%.]+") do
				cur = cur:FindFirstChild(part)
				if not cur then error("[runtime] missing " .. path) end
			end
			return cur
		end,
	}
end

return Runtime
