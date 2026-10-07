--!strict
-- PipeArt
-- How a buried main LOOKS, shared by the server (hand-drawn runs) and the client (the drag
-- preview and the mains under every road), so the two can never be drawn differently.
-- 2026-10-07 (user, after Cities: Skylines 2: "make it exactly like this"): smooth pipe, a round joint
-- where two runs meet (shapeBall), and a short upright drum where a run ends (shapeStand) -- no dark
-- metal collars any more. Water teal, sewage yellow.
-- Pure library: it only shapes Parts it is handed, so a caller can pool them.

local PipeArt = {}

PipeArt.WATER  = Color3.fromRGB(46, 170, 182)
PipeArt.SEWAGE = Color3.fromRGB(226, 182, 26)
-- The mains under a road: down the middle, water one side of the centreline and sewage the other.
PipeArt.ROAD_THICK = 1.6
PipeArt.ROAD_LAT   = 1.4
PipeArt.STAND_SCALE = 1.7 -- an end drum's diameter over its pipe's
-- Water rides this far above sewage wherever both are drawn (user 2026-10-07: "water is higher than the
-- sewage"). More than a road main's thickness, so the two cross at a junction without touching.
PipeArt.WATER_RISE = 1.8
PipeArt.COLLAR_LENGTH = 0.6
PipeArt.COLLAR_SCALE  = 1.35 -- collar diameter over pipe diameter

-- A mains colour, darkened for the metal collar on it.
function PipeArt.collarColor(c: Color3): Color3
	return c:Lerp(Color3.new(0, 0, 0), 0.35)
end

local function base(p: BasePart)
	(p :: Part).Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = false
end

-- One length of pipe from `a` to `b`, `thick` studs across, pushed `offset` studs sideways
-- (so two mains can share a trench). Overlaps its neighbours by half a diameter, so a bend
-- shows no gap. Returns false (and leaves `p` alone) for a zero-length piece.
function PipeArt.shapePipe(p: BasePart, a: Vector3, b: Vector3, color: Color3, thick: number, offset: number): boolean
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	if flat.Magnitude < 0.05 then return false end
	local perp = Vector3.new(-flat.Unit.Z, 0, flat.Unit.X) * offset
	local from, to = a + perp, b + perp
	base(p)
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = Vector3.new((to - from).Magnitude + thick * 0.5, thick, thick)
	local mid = (from + to) * 0.5
	p.CFrame = CFrame.lookAt(mid, mid + (to - from).Unit) * CFrame.Angles(0, math.rad(90), 0)
	return true
end

-- A round joint where runs meet, `d` studs across.
function PipeArt.shapeBall(p: BasePart, at: Vector3, color: Color3, d: number)
	base(p)
	local part = p :: Part
	part.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = Vector3.new(d, d, d)
	p.CFrame = CFrame.new(at)
end

-- The upright drum where a run ends (or rises to a tap): `d` across, `h` tall, centred on `at`.
function PipeArt.shapeStand(p: BasePart, at: Vector3, color: Color3, d: number, h: number)
	base(p)
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = Vector3.new(h, d, d)
	p.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
end

-- @deprecated: use PipeArt.shapeBall instead (the collars are gone from the look, 2026-10-07).
-- The collar at a joint `at`, facing along `dir`, pushed `offset` sideways like its pipe.
function PipeArt.shapeCollar(p: BasePart, at: Vector3, dir: Vector3, color: Color3, thick: number, offset: number)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local d = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.xAxis
	local pos = at + Vector3.new(-d.Z, 0, d.X) * offset
	base(p)
	p.Material = Enum.Material.Metal
	p.Color = PipeArt.collarColor(color)
	p.Size = Vector3.new(PipeArt.COLLAR_LENGTH, thick * PipeArt.COLLAR_SCALE, thick * PipeArt.COLLAR_SCALE)
	p.CFrame = CFrame.lookAt(pos, pos + d) * CFrame.Angles(0, math.rad(90), 0)
end

return PipeArt
