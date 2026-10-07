--!strict
-- SolarTrackerView -- turns the panels of every solar tracker row to the sun (tag SolarTracker: each
-- row of the SolarFarm template, Authoring.PowerTemplateSetup). Pure client view: the server's rows lie
-- flat. Single-axis tracking, as the real rows do it: the panels turn about the row's torque tube to
-- face the sun as nearly as that axis allows, at most 60 degrees either way; they ease back to flat as
-- the sun nears the horizon (backtracking -- low sun, long shadows, the rows would shade each other)
-- and lie flat at night. It reads the same Lighting clock PowerService rates the farm's output on, so
-- the panels point where the power comes from.
--
-- A row's Model pivot is its axis (LookVector along the tube, UpVector up); its panel parts (named
-- *_Panels*) keep their flat pose relative to it. Each step re-anchors on the farm's Root, so the Move
-- tool and the placement ghost never leave the panels behind. Cheap: a check every STEP seconds, and
-- parts are written only when the angle has moved MIN_TURN.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local TAG = "SolarTracker"
local MAX_TILT = math.rad(60)
local BACKTRACK = math.rad(15) -- below this sun elevation the rows ease back toward flat
local STEP = 0.5
local MIN_TURN = math.rad(0.25)

local SolarTrackerView = {}

type Row = { root: BasePart, offset: CFrame, parts: { BasePart }, rest: { CFrame }, angle: number }
local _rows: { [Model]: Row } = {}
local _conn: RBXScriptConnection? = nil
local _acc = 0

local function panelsOf(row: Model, axis: CFrame): ({ BasePart }, { CFrame })
	local parts, rest = {}, {}
	for _, d in row:GetDescendants() do
		if d:IsA("BasePart") and string.find(d.Name, "_Panels", 1, true) then
			table.insert(parts, d)
			table.insert(rest, axis:ToObjectSpace(d.CFrame))
		end
	end
	return parts, rest
end

local function track(inst: Instance)
	if not inst:IsA("Model") then return end
	local row = inst :: Model
	-- Replication may deliver the tag before the farm's Root: wait briefly (bounded).
	task.spawn(function()
		local deadline = os.clock() + 5
		local root: BasePart? = nil
		while os.clock() < deadline do
			local farm = row.Parent
			root = if farm and farm:IsA("Model") then farm.PrimaryPart else nil
			if root or not row.Parent then break end
			task.wait(0.1)
		end
		if not root or not row.Parent then return end
		local axis = row:GetPivot()
		local parts, rest = panelsOf(row, axis)
		_rows[row] = { root = root, offset = root.CFrame:ToObjectSpace(axis), parts = parts, rest = rest, angle = math.huge }
	end)
end

local function untrack(inst: Instance)
	if inst:IsA("Model") then _rows[inst :: Model] = nil end
end

-- The turn about the row's axis that faces the sun: its direction in the axis frame, projected across
-- the tube (rotating about local Z carries +Y to (-sin a, cos a)).
local function tiltFor(axis: CFrame, sun: Vector3): number
	if sun.Y <= 0 then return 0 end
	local l = axis:VectorToObjectSpace(sun)
	local a = math.clamp(math.atan2(-l.X, l.Y), -MAX_TILT, MAX_TILT)
	local elev = math.asin(math.clamp(sun.Y, -1, 1))
	return if elev < BACKTRACK then a * elev / BACKTRACK else a
end

local function step()
	local sun = Lighting:GetSunDirection()
	for row, r in _rows do
		if not row.Parent or not r.root.Parent then
			_rows[row] = nil
			continue
		end
		if #r.parts == 0 then
			r.parts, r.rest = panelsOf(row, r.root.CFrame * r.offset) -- streamed in after the tag
			r.angle = math.huge
		end
		local axis = r.root.CFrame * r.offset
		-- a farm switched off (attribute Off, EmergencyService.setOff) parks its rows flat
		local farm = row.Parent
		local a = if farm and farm:GetAttribute("Off") then 0 else tiltFor(axis, sun)
		if math.abs(a - r.angle) < MIN_TURN then continue end
		r.angle = a
		local turn = axis * CFrame.Angles(0, 0, a)
		for i, p in r.parts do
			if p.Parent then p.CFrame = turn * r.rest[i] end
		end
	end
end

function SolarTrackerView.Start()
	for _, inst in CollectionService:GetTagged(TAG) do
		track(inst)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_acc += dt
		if _acc < STEP then return end
		_acc = 0
		step()
	end)
end

function SolarTrackerView.Stop()
	if _conn then
		_conn:Disconnect()
		_conn = nil
	end
	table.clear(_rows)
end

return SolarTrackerView
