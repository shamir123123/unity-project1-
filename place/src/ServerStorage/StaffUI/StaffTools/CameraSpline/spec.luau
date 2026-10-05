--!strict
-- CameraSpline spec: constant speed along uneven keys, endpoints exact, pans and stills safe.
local CameraSpline = require(script.Parent)

local function key(p: Vector3, l: Vector3, fov: number?): CameraSpline.Key
	return { p = p, l = l, fov = fov or 50 }
end

return function()
	local straight = CameraSpline.build({
		key(Vector3.new(0, 10, 0), Vector3.new(0, 0, -100), 50),
		key(Vector3.new(100, 10, 0), Vector3.new(100, 0, -100), 30),
	})
	local mid, fov = CameraSpline.sample(straight, 0.5)
	assert(math.abs(mid.Position.X - 50) < 0.5, "a straight two-key flight is halfway at u=0.5")
	assert(math.abs(fov - 40) < 0.01, "fov eases between keys")
	assert((CameraSpline.sample(straight, 0).Position - Vector3.new(0, 10, 0)).Magnitude < 1e-3, "starts on key 1")
	assert((CameraSpline.sample(straight, 1).Position - Vector3.new(100, 10, 0)).Magnitude < 1e-3, "ends on the last key")

	-- Keys 10 then 190 studs apart: equal time steps must still cover equal distance.
	local uneven = CameraSpline.build({
		key(Vector3.new(0, 0, 0), Vector3.new(0, 0, -50)),
		key(Vector3.new(10, 0, 0), Vector3.new(10, 0, -50)),
		key(Vector3.new(200, 0, 40), Vector3.new(200, 0, -50)),
	})
	local prev = CameraSpline.sample(uneven, 0).Position
	local lo, hi = math.huge, 0
	for i = 1, 20 do
		local q = CameraSpline.sample(uneven, i / 20).Position
		local d = (q - prev).Magnitude
		lo, hi = math.min(lo, d), math.max(hi, d)
		prev = q
	end
	assert(hi / lo < 1.05, ("constant speed on uneven keys (ratio %.3f)"):format(hi / lo))

	local pan = CameraSpline.build({
		key(Vector3.new(0, 50, 0), Vector3.new(-100, 0, 0)),
		key(Vector3.new(0, 50, 0), Vector3.new(100, 0, 0)),
	})
	local panMid = CameraSpline.sample(pan, 0.5)
	assert(panMid.Position == panMid.Position and math.abs(panMid.LookVector.X) < 0.2, "a pan in place sweeps the look-at")

	local still = CameraSpline.build({ key(Vector3.new(1, 2, 3), Vector3.new(1, 2, -3), 40) })
	assert(CameraSpline.sample(still, 0.7).Position == Vector3.new(1, 2, 3), "one key holds still")
end
