--!strict
-- SewageOutfall
-- The sewage outlet's pipe out to the water (user, 2026-10-06: "it becomes longer and shorter depending on
-- how far the water is"). From the outlet's PipeOut marker it lays SewageOutlet_Pipe sections (2.4 m) end to
-- end along the outlet's back (-Z, the water side) and caps the run with SewageOutlet_End where the next
-- stretch would stand over water -- so the open mouth is at the shore. Pieces are look only (no queries) and
-- live in the outlet model, so they go when it goes. Pure library: no state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)

local WATERLINE_Y = TerrainConstants.SEA_Y + TerrainConstants.RENDER_BULGE
local SECTION = 4.8      -- studs: one SewageOutlet_Pipe (2.4 m)
local MOUTH = 3.2        -- studs from the End's origin to its mouth (1.6 m)
local MAX_SECTIONS = 12  -- 58 studs of pipe at most; the outlet already has to stand within reach of water

local SewageOutfall = {}

local function wet(p: Vector3): boolean
	return TerrainDataService.getSurfaceY(p.X, p.Z) < WATERLINE_Y and not TerrainDataService.isDryAt(p.X, p.Z)
end

local function piece(templates: Instance, name: string, cf: CFrame, into: Instance): Model?
	local t = templates:FindFirstChild(name)
	if not (t and t:IsA("Model")) then return nil end
	local c = t:Clone()
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then d.CanQuery = false end
	end
	c:PivotTo(cf)
	c.Parent = into
	return c
end

-- Lays (or re-lays, after a move) the run on a placed outlet. Returns how many sections it used.
function SewageOutfall.lay(model: Model): number
	local old = model:FindFirstChild("Outfall")
	if old then old:Destroy() end
	local templates = ReplicatedStorage.City:FindFirstChild("ServiceTemplates")
	local mark = model:FindFirstChild("PipeOut", true)
	if not (templates and mark and mark:IsA("Attachment")) then return 0 end
	local folder = Instance.new("Folder")
	folder.Name = "Outfall"
	folder.Parent = model
	local pivot = model:GetPivot()
	local dir = pivot:VectorToWorldSpace(Vector3.new(0, 0, -1))
	local start = Vector3.new(mark.WorldPosition.X, pivot.Position.Y, mark.WorldPosition.Z)
	local frame = pivot - pivot.Position
	local n = 0
	while n < MAX_SECTIONS and not wet(start + dir * (n * SECTION + MOUTH)) do
		piece(templates, "SewageOutlet_Pipe", frame + start + dir * (n * SECTION), folder)
		n += 1
	end
	local fin = piece(templates, "SewageOutlet_End", frame + start + dir * (n * SECTION), folder)
	-- the brown plume spreads ON the water where the pour lands (WaterTemplateSetup's PlumeArea); a run that
	-- never reached water has nowhere to spread it
	local plume = fin and fin:FindFirstChild("PlumeArea", true)
	if plume and plume:IsA("BasePart") then
		local p = plume.Position
		if wet(p) then plume.Position = Vector3.new(p.X, WATERLINE_Y + 0.1, p.Z) else plume:Destroy() end
	end
	return n
end

return SewageOutfall
