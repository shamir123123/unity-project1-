--!strict
-- CameraSpline -- the path maths behind CinematicCamera, pure so it can be spec'd.
-- Eye and look-at each follow a centripetal Catmull-Rom spline through the keys; a track is
-- flown at constant speed along the eye path via an arc-length table (the look-at path when
-- the eye stands still, i.e. a pan in place).

export type Key = { p: Vector3, l: Vector3, fov: number }
export type Track = {
	keys: { Key },
	ease: string?,
	segs: number,
	eyes: { Vector3 },
	looks: { Vector3 },
	cum: { number },
	total: number,
}

local CameraSpline = {}

local ARC_SAMPLES = 48 -- arc-length samples per segment

-- Centripetal Catmull-Rom (Barry-Goldman), value between p1 and p2 at t in [0,1].
local function crPoint(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t1 = math.max((p1 - p0).Magnitude, 1e-3) ^ 0.5
	local t2 = t1 + math.max((p2 - p1).Magnitude, 1e-3) ^ 0.5
	local t3 = t2 + math.max((p3 - p2).Magnitude, 1e-3) ^ 0.5
	local u = t1 + (t2 - t1) * t
	local a1 = p0 * ((t1 - u) / t1) + p1 * (u / t1)
	local a2 = p1 * ((t2 - u) / (t2 - t1)) + p2 * ((u - t1) / (t2 - t1))
	local a3 = p2 * ((t3 - u) / (t3 - t2)) + p3 * ((u - t2) / (t3 - t2))
	local b1 = a1 * ((t2 - u) / t2) + a2 * (u / t2)
	local b2 = a2 * ((t3 - u) / (t3 - t1)) + a3 * ((u - t1) / (t3 - t1))
	return b1 * ((t2 - u) / (t2 - t1)) + b2 * ((u - t1) / (t2 - t1))
end

-- Point on the whole path: segment i (1-based, between key i and i+1) at local t. Ends are
-- extended by reflection so the first and last segments get a natural tangent.
local function pathPoint(pts: { Vector3 }, i: number, t: number): Vector3
	local n = #pts
	if n == 1 then return pts[1] end
	local p1, p2 = pts[i], pts[i + 1]
	local p0 = if i > 1 then pts[i - 1] else p1 * 2 - p2
	local p3 = if i + 2 <= n then pts[i + 2] else p2 * 2 - p1
	return crPoint(p0, p1, p2, p3, t)
end

local function eased(kind: string?, u: number): number
	if kind == "inOut" then
		return u * u * (3 - 2 * u)
	elseif kind == "in" then
		return u * u
	elseif kind == "out" then
		return 1 - (1 - u) * (1 - u)
	end
	return u
end

-- Arc-length table over the eye path (or the look-at path for a pan in place).
function CameraSpline.build(keys: { Key }, ease: string?): Track
	local segs = math.max(#keys - 1, 0)
	local eyes, looks = table.create(#keys), table.create(#keys)
	for k, key in keys do
		eyes[k] = key.p
		looks[k] = key.l
	end
	local function lengths(pts: { Vector3 }): ({ number }, number)
		local cum = { 0 }
		local total = 0
		for i = 1, segs do
			local prev = pathPoint(pts, i, 0)
			for s = 1, ARC_SAMPLES do
				local q = pathPoint(pts, i, s / ARC_SAMPLES)
				total += (q - prev).Magnitude
				prev = q
				table.insert(cum, total)
			end
		end
		return cum, total
	end
	local cum, total = lengths(eyes)
	if total < 1 then
		cum, total = lengths(looks)
	end
	return { keys = keys, ease = ease, segs = segs, eyes = eyes, looks = looks, cum = cum, total = total }
end

-- Camera pose at fraction u of the track: CFrame, field of view, distance to the look-at point.
function CameraSpline.sample(track: Track, u: number): (CFrame, number, number)
	local keys = track.keys
	if track.segs == 0 then
		local k = keys[1]
		return CFrame.lookAt(k.p, k.l), k.fov, (k.l - k.p).Magnitude
	end
	local idx: number
	if track.total < 1e-3 then
		idx = u * track.segs * ARC_SAMPLES
	else
		-- Binary search the cumulative table for the arc distance, then interpolate.
		local want = eased(track.ease, u) * track.total
		local cum = track.cum
		local lo, hi = 1, #cum
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if cum[mid] <= want then lo = mid else hi = mid end
		end
		local span = cum[hi] - cum[lo]
		idx = (lo - 1) + (if span > 0 then (want - cum[lo]) / span else 0)
	end
	idx = math.clamp(idx, 0, track.segs * ARC_SAMPLES)
	local seg = math.min(math.floor(idx / ARC_SAMPLES) + 1, track.segs)
	local t = (idx - (seg - 1) * ARC_SAMPLES) / ARC_SAMPLES
	local eye = pathPoint(track.eyes, seg, t)
	local look = pathPoint(track.looks, seg, t)
	local f0, f1 = keys[seg].fov, keys[seg + 1].fov
	local fov = f0 + (f1 - f0) * (t * t * (3 - 2 * t))
	local focus = (look - eye).Magnitude
	if focus < 1e-3 then look = eye + Vector3.new(0, 0, -1) end
	return CFrame.lookAt(eye, look), fov, focus
end

return CameraSpline
