--!strict
-- TrainBuildingModel
-- Procedural builders for the rail placeables: the Train Depot (engine shed), the Train
-- Yard (sidings + maintenance shed) and the three station sizes. Server-only pure
-- builders, no state; TransitService is the sole caller. +Z faces the track. Authored at
-- full size, then ScaleTo(WORLD_SCALE), same as TransitBuildingModel.
-- ponytail: placeholder massing until the rail kit is modelled. Swap each builder for a
-- template clone then; callers only need a Model with the same pivot convention.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)

local TrainBuildingModel = {}

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local C_CONCRETE = Color3.fromRGB(150, 150, 154)
local C_DARK     = Color3.fromRGB(70, 73, 80)
local C_GLASS    = Color3.fromRGB(18, 20, 24)
local C_BALLAST  = Color3.fromRGB(104, 99, 93)
local C_RAIL     = Color3.fromRGB(150, 150, 154)
local C_EDGE     = Color3.fromRGB(214, 178, 90)
local C_LIGHT    = Color3.fromRGB(255, 240, 205)
local C_WHITE    = Color3.fromRGB(228, 228, 222)

local GAUGE_HALF = 2.8 -- rail pair half-spread, authored (matches the track renderer at full size)

local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, role: string?): Part
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.CFrame = cf
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false
	p.Color = color; p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = (role == "Wall" or role == "Roof")
	if role then p:SetAttribute("PaintRole", role) end
	p.Parent = parent
	return p
end

local function sign(board: BasePart, text: string, face: Enum.NormalId?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = face or Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.LightInfluence = 0.6
	sg.MaxDistance = 400
	sg.Parent = board
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(0.92, 0.78)
	lbl.Position = UDim2.fromScale(0.04, 0.11)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.Text = text
	lbl.TextColor3 = C_WHITE
	lbl.TextScaled = true
	lbl.Parent = sg
end

-- A pair of rails on a ballast bed from z0 to z1 (z0 < z1) at local x, or along X when
-- `alongX` (then x/z swap roles: `at` is the Z of the track).
local function track(model: Instance, name: string, at: number, a0: number, a1: number, y: number, alongX: boolean)
	local len, mid = a1 - a0, (a0 + a1) * 0.5
	if alongX then
		newPart(model, name .. "Bed", V(len, 0.3, 8), CF(mid, y + 0.15, at), C_BALLAST, M.Slate)
		for _, s in { -1, 1 } do
			newPart(model, name .. "Rail" .. s, V(len, 0.35, 0.35), CF(mid, y + 0.45, at + s * GAUGE_HALF), C_RAIL, M.Metal)
		end
	else
		newPart(model, name .. "Bed", V(8, 0.3, len), CF(at, y + 0.15, mid), C_BALLAST, M.Slate)
		for _, s in { -1, 1 } do
			newPart(model, name .. "Rail" .. s, V(0.35, 0.35, len), CF(at + s * GAUGE_HALF, y + 0.45, mid), C_RAIL, M.Metal)
		end
	end
end

local function baseRoot(model: Model): Part
	local root = newPart(model, "Root", V(2, 1, 2), CF(0, 0, 0), C_DARK, M.SmoothPlastic)
	root.Transparency = 1
	model.PrimaryPart = root
	return root
end

local function finish(model: Model): Model
	if RoadConstants.WORLD_SCALE ~= 1 then model:ScaleTo(RoadConstants.WORLD_SCALE) end
	return model
end

-- Train Depot: a long engine shed with three road doors onto the track side (+Z) and an
-- office at one end. Root is the base-centre pivot.
function TrainBuildingModel.buildDepot(spec: TransitTypes.DepotSpec, footprint: Vector3): Model
	local fx, fz, h = footprint.X, footprint.Z, spec.height
	local hx, hz = fx * 0.5, fz * 0.5
	local model = Instance.new("Model")
	model.Name = "TrainDepot"
	baseRoot(model)
	newPart(model, "Yard", V(fx - 2, 0.3, fz - 2), CF(0, 0.15, 0), C_CONCRETE, M.Concrete)

	local shedD = fz * 0.62
	local shedZ = -hz + 1 + shedD * 0.5
	local front = shedZ + shedD * 0.5
	local officeW = 30
	local shedW = fx - 2 - officeW
	local shedX = -hx + 1 + shedW * 0.5
	local officeX = hx - 1 - officeW * 0.5

	newPart(model, "ShedBody", V(shedW, h, shedD), CF(shedX, h * 0.5, shedZ), spec.wall, M.Brick, "Wall")
	newPart(model, "ShedRoof", V(shedW + 1.5, 1, shedD + 1.5), CF(shedX, h + 0.5, shedZ), spec.roof, M.Slate, "Roof")
	newPart(model, "ShedRidge", V(shedW * 0.9, 3, shedD * 0.28), CF(shedX, h + 2.5, shedZ), spec.roof, M.Slate, "Roof")
	newPart(model, "RidgeGlass", V(shedW * 0.88, 1.6, shedD * 0.3), CF(shedX, h + 2.2, shedZ), C_GLASS, M.SmoothPlastic)

	local doors = 3
	local step = shedW / doors
	for i = 1, doors do
		local x = shedX - shedW * 0.5 + step * (i - 0.5)
		newPart(model, "Door" .. i, V(step * 0.62, h - 5, 0.4), CF(x, (h - 5) * 0.5, front + 0.2), C_GLASS, M.SmoothPlastic)
		track(model, "Lead" .. i, x, front - 2, hz - 1, 0.3, false)
	end
	newPart(model, "Fascia", V(shedW, 2, 0.5), CF(shedX, h - 2, front + 0.3), spec.accent, M.SmoothPlastic, "Accent")

	local officeH = h * 0.7
	newPart(model, "Office", V(officeW, officeH, shedD * 0.8), CF(officeX, officeH * 0.5, shedZ), spec.wall, M.Brick, "Wall")
	newPart(model, "OfficeRoof", V(officeW + 1, 0.8, shedD * 0.8 + 1), CF(officeX, officeH + 0.4, shedZ), spec.roof, M.Slate, "Roof")
	newPart(model, "OfficeWindows", V(officeW - 6, 3, 0.3), CF(officeX, officeH * 0.55, shedZ + shedD * 0.4 + 0.15), C_GLASS, M.SmoothPlastic)
	local board = newPart(model, "SignBoard", V(officeW - 4, 3, 0.4), CF(officeX, officeH - 2.4, shedZ + shedD * 0.4 + 0.3), spec.accent, M.SmoothPlastic, "Accent")
	sign(board, "TRAIN DEPOT")

	for i, x in { -hx + 3, hx - 3 } do
		newPart(model, "LightPole" .. i, V(0.6, 16, 0.6), CF(x, 8, hz - 3), C_DARK, M.Metal)
		newPart(model, "LightHead" .. i, V(2.4, 0.4, 1.2), CF(x, 16.2, hz - 3), C_LIGHT, M.Neon)
	end
	return finish(model)
end

-- Train Yard: parallel sidings along the track, a two-road maintenance shed over the back
-- pair, a wash gantry and two stored coaches. Root is the base-centre pivot.
function TrainBuildingModel.buildYard(spec: TransitTypes.DepotSpec, footprint: Vector3): Model
	local fx, fz, h = footprint.X, footprint.Z, spec.height
	local hx, hz = fx * 0.5, fz * 0.5
	local model = Instance.new("Model")
	model.Name = "TrainYard"
	baseRoot(model)
	newPart(model, "Yard", V(fx - 2, 0.3, fz - 2), CF(0, 0.15, 0), C_BALLAST, M.Slate)

	local sidings = 4
	local pitch = (fz - 12) / sidings
	local zs: { number } = {}
	for i = 1, sidings do
		zs[i] = -hz + 6 + pitch * (i - 0.5)
		track(model, "Siding" .. i, zs[i], -hx + 4, hx - 4, 0.3, true)
	end

	-- Maintenance shed over the two back sidings, open at both ends.
	local shedW = fx * 0.45
	local shedX = -hx + 4 + shedW * 0.5
	local shedZ = (zs[1] + zs[2]) * 0.5
	local shedD = pitch * 2 + 6
	for _, s in { -1, 1 } do
		newPart(model, "ShedWall" .. s, V(shedW, h, 1), CF(shedX, h * 0.5, shedZ + s * shedD * 0.5), spec.wall, M.Concrete, "Wall")
	end
	newPart(model, "ShedRoof", V(shedW + 1, 1, shedD + 2), CF(shedX, h + 0.5, shedZ), spec.roof, M.Metal, "Roof")
	newPart(model, "ShedSkylight", V(shedW * 0.9, 0.4, shedD * 0.3), CF(shedX, h + 1.1, shedZ), C_GLASS, M.SmoothPlastic)
	newPart(model, "ShedStripe", V(shedW, 1.4, 0.3), CF(shedX, h - 1.4, shedZ + shedD * 0.5 + 0.6), spec.accent, M.SmoothPlastic, "Accent")

	-- Wash gantry over the third siding.
	local gx = hx - fx * 0.28
	for _, s in { -1, 1 } do
		newPart(model, "GantryLeg" .. s, V(1, h * 0.8, 1), CF(gx, h * 0.4, zs[3] + s * 7), C_DARK, M.Metal)
	end
	newPart(model, "GantryBeam", V(3, 1.4, 15), CF(gx, h * 0.8, zs[3]), spec.accent, M.Metal, "Accent")

	-- Two stored coaches on the front siding (static dressing, not trains in service).
	local coach = TransitTypes.Train
	for i = 1, 2 do
		local x = hx - 12 - (i - 1) * (coach.carLength + 3) - coach.carLength * 0.5
		newPart(model, "StoredCoach" .. i, V(coach.carLength * 0.96, coach.height * 0.62, coach.width), CF(x, 0.6 + coach.height * 0.5, zs[4]), coach.body, M.SmoothPlastic)
		newPart(model, "StoredCoachBand" .. i, V(coach.carLength * 0.97, coach.height * 0.12, coach.width + 0.1), CF(x, 0.6 + coach.height * 0.6, zs[4]), C_GLASS, M.SmoothPlastic)
	end

	local board = newPart(model, "SignBoard", V(24, 3.4, 0.4), CF(-hx + 16, 5, hz - 1.5), spec.accent, M.SmoothPlastic, "Accent")
	sign(board, "TRAIN YARD")
	newPart(model, "SignPost", V(0.6, 4, 0.6), CF(-hx + 16, 2, hz - 1.8), C_DARK, M.Metal)
	return finish(model)
end

-- Station: the platform runs along X on the track side (+Z edge at the track), canopy and
-- hall grow with the platform size. Pole is the PrimaryPart at the origin (TransitService
-- lifts the pivot by half the pole height so the base sits on the ground).
function TrainBuildingModel.buildStation(spec: TransitTypes.StopSpec): Model
	local model = Instance.new("Model")
	model.Name = "TrainStation"
	local cars = spec.platformCars or 3
	local groundY = -spec.poleHeight * 0.5
	local sh = spec.shelterSize
	local L, H, D = sh.X, sh.Y, sh.Z
	local PLAT_H = 2.4

	local pole = newPart(model, "Pole", V(0.6, spec.poleHeight, 0.6), CF(0, 0, 0), C_DARK, M.Metal)
	model.PrimaryPart = pole
	local blade = newPart(model, "SignBlade", V(6, 1.8, 0.25), CF(0, spec.poleHeight * 0.5 - 1.4, 0.3), spec.accent, M.SmoothPlastic, "Accent")
	sign(blade, "RAIL", Enum.NormalId.Back)

	local platZ = -D * 0.5 + 0.35
	local top = groundY + PLAT_H
	newPart(model, "Platform", V(L, PLAT_H, D), CF(0, groundY + PLAT_H * 0.5, platZ), C_CONCRETE, M.Concrete)
	newPart(model, "EdgeStrip", V(L, 0.12, 1), CF(0, top + 0.06, 0.35 - 0.6), C_EDGE, M.SmoothPlastic)

	-- Canopy: a short shelter on a halt, most of the platform on a main station.
	local canopyL = L * (if cars <= 3 then 0.35 elseif cars <= 5 then 0.6 else 0.9)
	local canopyZ = platZ - D * 0.1
	local posts = math.max(2, math.floor(canopyL / 28))
	for i = 1, posts do
		local x = -canopyL * 0.5 + canopyL * (i - 0.5) / posts
		newPart(model, "CanopyPost" .. i, V(0.6, H - PLAT_H, 0.6), CF(x, top + (H - PLAT_H) * 0.5, canopyZ), C_DARK, M.Metal)
	end
	newPart(model, "CanopyRoof", V(canopyL, 0.4, D * 0.75), CF(0, groundY + H, canopyZ), C_DARK, M.SmoothPlastic, "Roof")
	newPart(model, "CanopyLip", V(canopyL + 0.4, 0.3, D * 0.75 + 0.4), CF(0, groundY + H - 0.3, canopyZ), spec.accent, M.SmoothPlastic, "Accent")
	local strip = newPart(model, "CanopyLight", V(canopyL - 4, 0.15, 0.8), CF(0, groundY + H - 0.55, canopyZ), C_LIGHT, M.Neon)
	strip.Transparency = 0.15
	for _, sx in { -1, 1 } do
		newPart(model, "Bench" .. sx, V(canopyL * 0.18, 0.3, 1.2), CF(sx * canopyL * 0.22, top + 1.4, canopyZ - D * 0.2), Color3.fromRGB(120, 124, 130), M.Metal)
	end

	-- Station hall behind the platform (Medium and Large). Its glass front faces the platform.
	local backZ = platZ - D * 0.5
	local hitD = D
	if cars > 3 then
		local big = cars > 5
		local hallW, hallD, hallH = if big then 160 else 72, if big then 56 else 28, if big then 30 else 18
		local hallZ = backZ - hallD * 0.5
		newPart(model, "Hall", V(hallW, hallH, hallD), CF(0, groundY + hallH * 0.5, hallZ), Color3.fromRGB(196, 176, 150), M.Brick, "Wall")
		newPart(model, "HallRoof", V(hallW + 2, 1.2, hallD + 2), CF(0, groundY + hallH + 0.6, hallZ), Color3.fromRGB(78, 82, 88), M.Slate, "Roof")
		newPart(model, "HallGlass", V(hallW * 0.7, hallH * 0.55, 0.4), CF(0, groundY + hallH * 0.42, backZ + 0.2), C_GLASS, M.SmoothPlastic)
		local board = newPart(model, "HallSign", V(hallW * 0.5, 4, 0.5), CF(0, groundY + hallH - 3, backZ + 0.3), spec.accent, M.SmoothPlastic, "Accent")
		sign(board, "STATION")
		if big then
			local tz = hallZ - hallD * 0.5 + 8
			newPart(model, "Tower", V(16, hallH + 28, 16), CF(hallW * 0.5 - 10, groundY + (hallH + 28) * 0.5, tz), Color3.fromRGB(186, 164, 136), M.Brick, "Wall")
			newPart(model, "TowerCap", V(18, 2, 18), CF(hallW * 0.5 - 10, groundY + hallH + 29, tz), Color3.fromRGB(78, 82, 88), M.Slate, "Roof")
			newPart(model, "Clock", V(8, 8, 0.4), CF(hallW * 0.5 - 10, groundY + hallH + 20, tz + 8.2), C_WHITE, M.SmoothPlastic)
		end
		hitD = D + hallD
	end

	local hit = newPart(model, "Hitbox", V(L + 0.5, H + 1, hitD + 1), CF(0, groundY + (H + 1) * 0.5, 0.35 - hitD * 0.5), C_DARK, M.SmoothPlastic)
	hit.Transparency = 1
	hit.CanQuery = true
	return finish(model)
end

return TrainBuildingModel
