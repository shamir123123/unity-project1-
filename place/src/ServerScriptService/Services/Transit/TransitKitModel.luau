--!strict
-- TransitKitModel
-- The Blender transit kit at runtime: clones ServerStorage.Templates.Transit.<Key> (made by
-- Authoring.TransitSetup from blender/transit.py) and turns its TransitPlan into world poses -- the
-- bays of a layout with the drives in and out that transit_plan.py swept-path-checked. Server-only
-- library: no lifecycle; the decoded plans are memoised per template.
--
-- Yard drives are FRONT-AXLE traces: the rear axle follows one wheelbase behind along the same line
-- (that is what the plan checked), so `yardPose` rebuilds the bus pose from the two axles.

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local TransitKitModel = {}

export type Bay = {
	id: number, kind: string, stop: string?,
	cf: CFrame,             -- the parked bus pivot (whole-bus centre on the ground), facing the way it leaves
	pathIn: { Vector3 },    -- front axle: road hand-off -> parked
	pathOut: { Vector3 },   -- front axle: parked -> road hand-off
}

-- transit_plan.py BUS / ARTIC in studs: wheelbase, and front axle -> whole-bus centre.
local AXLES = table.freeze({
	city = table.freeze({ wb = 11.8, centre = 6.39 }),
	artic = table.freeze({ wb = 11.5, centre = 12.7 }),
})
local GROUND_Y = 0.06 -- the kit's asphalt top (3 cm)

local _plans: { [string]: any } = {}

local function template(key: string): Model?
	local root = ServerStorage:FindFirstChild("Templates")
	local folder = root and root:FindFirstChild("Transit")
	local t = folder and folder:FindFirstChild(key)
	return if t and t:IsA("Model") then t else nil
end

local function plan(key: string): any?
	if _plans[key] == nil then
		local t = template(key)
		local sv = t and t:FindFirstChild("TransitPlan")
		_plans[key] = if sv and sv:IsA("StringValue") then HttpService:JSONDecode(sv.Value) else false
	end
	return _plans[key] or nil
end

function TransitKitModel.has(key: string): boolean
	return template(key) ~= nil
end

function TransitKitModel.defaultLayout(key: string): number
	local p = plan(key)
	return if p then p.default else 1
end

function TransitKitModel.layoutCount(key: string): number
	local p = plan(key)
	return if p then #p.layouts else 0
end

-- Every gate in the site's street side (bus in / out, staff car, walk) as "x0,x1,Kind;..." in template
-- studs: LotDressingService paves a drive (a footpath for Walk) from each out to the road (tag
-- PavedGates, attr GateSpans).
function TransitKitModel.gateSpans(key: string): string?
	local p = plan(key)
	if not p or not p.gates then return nil end
	local out = {}
	for kind, g in p.gates do
		table.insert(out, string.format("%.2f,%.2f,%s", g[1], g[2], kind))
	end
	table.sort(out)
	return if #out > 0 then table.concat(out, ";") else nil
end

-- What the player chooses between: each layout's label, its bus count and how many are long.
function TransitKitModel.layoutInfo(key: string): { { label: string, buses: number, artic: number } }
	local p = plan(key)
	local out = {}
	for i, L in (if p then p.layouts else {}) do
		out[i] = { label = L.label, buses = #L.bays, artic = L.artic }
	end
	return out
end

-- A clone of the template at `pivot` keeping only `layout`'s bay lines (a stop has none).
function TransitKitModel.spawn(key: string, pivot: CFrame, layout: number?): Model?
	local t = template(key)
	if not t then return nil end
	local m = t:Clone()
	for _, p in m:GetChildren() do
		local l = p:GetAttribute("Layout")
		if l ~= nil and l ~= layout then p:Destroy() end
	end
	local plan_ = m:FindFirstChild("TransitPlan")
	if plan_ then plan_:Destroy() end -- server data, no need to replicate it
	m:PivotTo(pivot)
	return m
end

-- The bays of `layout` in the world, for a model pivoted at `pivot`.
function TransitKitModel.bays(key: string, pivot: CFrame, layout: number): { Bay }
	local p = plan(key)
	if not p or #p.layouts == 0 then return {} end
	local L = p.layouts[math.clamp(layout, 1, #p.layouts)]
	local function world(q: { number }): Vector3
		return pivot * Vector3.new(q[1], GROUND_Y, q[2])
	end
	local out: { Bay } = {}
	for _, b in L.bays do
		local pathIn, pathOut = {}, {}
		for i, q in b.pathIn do pathIn[i] = world(q) end
		for i, q in b.pathOut do pathOut[i] = world(q) end
		table.insert(out, {
			id = b.id, kind = b.kind, stop = b.stop, pathIn = pathIn, pathOut = pathOut,
			-- plan yaw 0 = nose to the street (+Z); vehicles face -Z
			cf = pivot * CFrame.new(b.pos[1], GROUND_Y, b.pos[2]) * CFrame.Angles(0, math.rad(b.yaw) + math.pi, 0),
		})
	end
	return out
end

function TransitKitModel.axles(articulated: boolean): { wb: number, centre: number }
	return if articulated then AXLES.artic else AXLES.city
end

-- Cumulative arc length of a polyline.
function TransitKitModel.arc(pts: { Vector3 }): { number }
	local cum = { 0 }
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		cum[i] = cum[i - 1] + Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
	end
	return cum
end

-- The point at arc length s; before the start it runs straight back along `back` (the heading the
-- bus had when the drive began), so the rear axle has somewhere to be.
local function at(pts: { Vector3 }, cum: { number }, s: number, back: Vector3): Vector3
	if s <= 0 then return pts[1] - back * (-s) end
	if s >= cum[#cum] then return pts[#pts] end
	local lo, hi = 1, #cum
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] < s then lo = mid else hi = mid end
	end
	local t = (s - cum[lo]) / math.max(1e-6, cum[hi] - cum[lo])
	return pts[lo]:Lerp(pts[hi], t)
end

-- The bus pivot with its front axle at arc s of `pts`: heading = rear axle -> front axle.
function TransitKitModel.yardPose(pts: { Vector3 }, cum: { number }, s: number, back: Vector3, articulated: boolean, lift: number): CFrame
	local ax = if articulated then AXLES.artic else AXLES.city
	local front = at(pts, cum, s, back)
	local rear = at(pts, cum, s - ax.wb, back)
	local dir = Vector3.new(front.X - rear.X, 0, front.Z - rear.Z)
	dir = if dir.Magnitude > 1e-3 then dir.Unit else back
	local c = front - dir * ax.centre
	local pos = Vector3.new(c.X, (front.Y + rear.Y) * 0.5 + lift, c.Z)
	return CFrame.lookAt(pos, pos + dir)
end

return TransitKitModel
