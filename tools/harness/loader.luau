--!nocheck
-- Loads the game's scripts from src/ (via sourcemap.json) into a virtual DataModel so pure
-- modules can be required and run under Lune. Usage:
--   local H = require("./loader")
--   local game = H.boot({ server = false, overrides = { ["ReplicatedStorage.Terrain.TerrainMeshView"] = stub } })
--   local RoadNetwork = H.require("ReplicatedStorage.Road.RoadNetwork")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local rbx = require("./rbx")

local H = {}
H.rbx = rbx
-- full path -> function(source) -> source: test-only hooks (e.g. expose a module's locals)
H.patches = {}
H.roblox = roblox

local ROOT = "../../"
local _game
local _byPath: { [string]: any } = {}
local _files: { [any]: string } = {}
local _cache: { [any]: any } = {}
local _loading: { [any]: boolean } = {}
local _overrides: { [string]: any } = {}
local _env

local function buildTree(node, parent, path)
	local inst = rbx.newRaw(node.className, node.name)
	local full = if path == "" then node.name else path .. "." .. node.name
	if parent then inst.Parent = parent end
	_byPath[full] = inst
	if node.filePaths then _files[inst] = node.filePaths[1] end
	for _, c in (node.children or {}) do buildTree(c, inst, full) end
	return inst
end

-- deterministic PRNG standing in for Roblox Random
local Random = {}
Random.__index = Random
function Random.new(seed)
	seed = math.floor(tonumber(seed) or os.clock() * 1e6) % 2147483647
	if seed <= 0 then seed += 2147483646 end
	return setmetatable({ s = seed }, Random)
end
function Random:_next()
	self.s = (self.s * 16807) % 2147483647
	return self.s / 2147483647
end
function Random:NextNumber(a, b)
	a = a or 0; b = b or 1
	return a + (b - a) * self:_next()
end
function Random:NextInteger(a, b)
	return math.floor(a + (b - a + 1) * self:_next())
end
function Random:NextUnitVector()
	local v = roblox.Vector3.new(self:_next() - 0.5, self:_next() - 0.5, self:_next() - 0.5)
	return v.Unit
end
function Random:Shuffle(t)
	for i = #t, 2, -1 do
		local j = self:NextInteger(1, i)
		t[i], t[j] = t[j], t[i]
	end
end

-- Mock EditableMesh: counts work so bakes can be measured offline.
H.emStats = { meshes = 0, verts = 0, tris = 0, calls = 0, bakes = 0, fixed = 0, fixedAlive = 0, parts = 0 }
local function newEditableMesh()
	local st = H.emStats
	st.meshes += 1
	local em = { _v = 0, _t = 0, _n = 0, _c = 0, _uv = 0 }
	function em:AddVertex(_p) st.calls += 1; st.verts += 1; self._v += 1; return self._v end
	function em:AddNormal(_n) st.calls += 1; self._n += 1; return self._n end
	function em:AddColor(_c, _a) st.calls += 1; self._c += 1; return self._c end
	function em:AddUV(_u) st.calls += 1; self._uv += 1; return self._uv end
	function em:AddTriangle(_a, _b, _c) st.calls += 1; st.tris += 1; self._t += 1; return self._t end
	function em:SetFaceColors() st.calls += 1 end
	function em:SetFaceNormals() st.calls += 1 end
	function em:SetFaceUVs() st.calls += 1 end
	function em:Destroy() end
	return em
end

local function makeServices(isServer: boolean)
	local services = {}
	local function svc(name)
		local s = services[name]
		if s then return s end
		s = _game:FindFirstChild(name) or rbx.newRaw(name, name)
		if not s.Parent and s ~= _game then s.Parent = _game end
		services[name] = s
		return s
	end
	local RunService = svc("RunService")
	RunService._props.Heartbeat = rbx.Signal.new()
	RunService._props.RenderStepped = rbx.Signal.new()
	RunService._props.Stepped = rbx.Signal.new()
	RunService._props.PreRender = rbx.Signal.new()
	RunService._props.PreSimulation = rbx.Signal.new()
	RunService._props.PostSimulation = rbx.Signal.new()
	RunService._props.IsStudio = function() return true end
	RunService._props.IsServer = function() return isServer end
	RunService._props.IsClient = function() return not isServer end
	RunService._props.IsRunning = function() return true end
	RunService._props.BindToRenderStep = function() end
	RunService._props.UnbindFromRenderStep = function() end

	local CS = svc("CollectionService")
	local added, removed = {}, {}
	CS._props.GetTagged = function(_, tag)
		local out = {}
		for i in (rbx.tagged[tag] or {}) do table.insert(out, i) end
		return out
	end
	CS._props.HasTag = function(_, i, tag) return i._tags[tag] == true end
	CS._props.AddTag = function(_, i, tag) i:AddTag(tag); if added[tag] then added[tag]:Fire(i) end end
	CS._props.RemoveTag = function(_, i, tag) i:RemoveTag(tag); if removed[tag] then removed[tag]:Fire(i) end end
	CS._props.GetTags = function(_, i) return i:GetTags() end
	CS._props.GetInstanceAddedSignal = function(_, tag)
		added[tag] = added[tag] or rbx.Signal.new()
		return added[tag]
	end
	CS._props.GetInstanceRemovedSignal = function(_, tag)
		removed[tag] = removed[tag] or rbx.Signal.new()
		return removed[tag]
	end

	local Http = svc("HttpService")
	Http._props.JSONEncode = function(_, v) return serde.encode("json", v) end
	Http._props.JSONDecode = function(_, s) return serde.decode("json", s) end
	local guid = 0
	Http._props.GenerateGUID = function() guid += 1; return string.format("{%08d-0000-0000-0000-000000000000}", guid) end

	local Asset = svc("AssetService")
	Asset._props.CreateEditableMesh = function() return newEditableMesh() end
	Asset._props.CreateDataModelContentAsync = function() H.emStats.bakes += 1; return "Success", {} end
	Asset._props.CreateEditableMeshAsync = function(_, _content, opts)
		if H.refuseFixed then error("budget") end
		H.emStats.fixed += 1
		H.emStats.fixedAlive += 1
		local em = newEditableMesh()
		local destroyed = false
		function em:Destroy()
			if destroyed then return end
			destroyed = true
			H.emStats.fixedAlive -= 1
		end
		return em
	end
	Asset._props.CreateMeshPartAsync = function()
		H.emStats.parts += 1
		local mp = rbx.Instance.new("MeshPart")
		mp._props.Size = roblox.Vector3.new(64, 2, 64)
		mp._props.CFrame = roblox.CFrame.new()
		mp._props.ApplyMesh = function() end
		return mp
	end

	local Players = svc("Players")
	Players._props.GetPlayers = function() return {} end
	Players._props.PlayerAdded = rbx.Signal.new()
	Players._props.PlayerRemoving = rbx.Signal.new()

	local ws = svc("Workspace")
	ws._props.CurrentCamera = rbx.Instance.new("Camera")
	ws._props.CurrentCamera._props.CFrame = roblox.CFrame.new(0, 300, 0)
	ws._props.CurrentCamera._props.FieldOfView = 70
	ws._props.CurrentCamera._props.ViewportSize = roblox.Vector2.new(1920, 1080)
	ws._props.Raycast = function() return nil end
	ws._props.GetPartBoundsInBox = function() return {} end
	ws._props.GetPartsInPart = function() return {} end
	if not ws:FindFirstChild("Terrain") then rbx.Instance.new("Terrain", ws) end

	_game._props.GetService = function(_, name) return svc(name) end
	_game._props.FindService = function(_, name) return services[name] end
	_game._props.PlaceId = 0
	_game._props.JobId = "harness"
	return svc
end

local function makeEnv(isServer: boolean)
	local env = {}
	for k, v in roblox do
		if k ~= "Instance" and type(k) == "string" and string.match(k, "^%u") then env[k] = v end
	end
	env.Instance = rbx.Instance
	env.Random = Random
	-- enums newer than Lune's reflection database
	local extraEnums = { CreateContentResult = { Success = "Success" } }
	env.Enum = setmetatable({}, { __index = function(_, k) return extraEnums[k] or (roblox.Enum :: any)[k] end })
	env.typeof = rbx.typeof
	env.task = task
	env.game = _game
	env.workspace = _game:GetService("Workspace")
	env.Workspace = env.workspace
	env.tick = os.clock
	env.time = os.clock
	env.wait = task.wait
	env.delay = task.delay
	env.spawn = task.spawn
	env.warn = function(...) if H.quietWarn then return end print("[warn]", ...) end
	env.settings = function() return { Rendering = { QualityLevel = 10 } } end
	env.UserSettings = function() return { GameSettings = { SavedQualityLevel = 10 } } end
	env.shared = {}
	env._G = env
	env.Content = { fromObject = function(o) return { obj = o } end, fromUri = function(u) return { uri = u } end, none = {} }
	env.DateTime = { now = function() return { UnixTimestamp = os.time(), UnixTimestampMillis = os.time() * 1000 } end }
	env.debug = setmetatable({ profilebegin = function() end, profileend = function() end, setmemorycategory = function() end, resetmemorycategory = function() end }, { __index = debug })
	env.TweenInfo = env.TweenInfo or { new = function(...) return { ... } end }
	return env
end

function H.require(target)
	if type(target) == "string" then
		local o = _overrides[target]
		if o ~= nil then return o end
		local inst = _byPath[target]
		assert(inst, "no such script: " .. target)
		target = inst
	end
	if type(target) ~= "table" then error("require of non-instance: " .. tostring(target)) end
	local full = target:GetFullName()
	local o = _overrides[full]
	if o ~= nil then return o end
	local cached = _cache[target]
	if cached ~= nil then return cached end
	assert(not _loading[target], "cyclic require: " .. full)
	local file = _files[target]
	assert(file, "not a script with a source file: " .. full)
	_loading[target] = true
	local src = fs.readFile(ROOT .. file)
	local patch = H.patches[full]
	if patch then src = patch(src) end
	local env = table.clone(_env)
	env.script = target
	env.require = H.require
	local fn = luau.load(src, { debugName = full, environment = env, injectGlobals = true })
	local okRun, result = pcall(fn)
	_loading[target] = nil
	if not okRun then error(result, 0) end
	_cache[target] = if result == nil then false else result
	return result
end

-- Run a Script/LocalScript (or any source file) by path with its own env.
function H.run(path: string)
	local inst = _byPath[path]
	assert(inst, path)
	local src = fs.readFile(ROOT .. _files[inst])
	local env = table.clone(_env)
	env.script = inst
	env.require = H.require
	return luau.load(src, { debugName = path, environment = env, injectGlobals = true })()
end

function H.path(p: string)
	return _byPath[p]
end

function H.boot(opts: { server: boolean?, overrides: { [string]: any }? }?)
	opts = opts or {}
	local map = serde.decode("json", fs.readFile(ROOT .. "sourcemap.json"))
	_game = rbx.newRaw("DataModel", "Game")
	for _, c in map.children do buildTree(c, _game, "") end
	H.game = _game
	makeServices(opts.server == true)
	_env = makeEnv(opts.server == true)
	_overrides = opts.overrides or {}
	return _game
end

H.task = task
return H
