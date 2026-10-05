-- Shared demand runner: spawn directed trips between endpoint pairs at a fixed rate and
-- report throughput, delay, stuck cars, warnings and errors.
local W = require("../rt/world")
local V3 = W.V3
local C = {}
C.W = W

-- Endpoint: { pos = Vector3 (on an inbound lane), out = Vector3 (on an outbound lane) }
-- Builds an endpoint at the tip of an arm drawn from `tip` toward `toward`.
function C.armEnd(tip, toward, inset, side)
	local dir = (toward - tip)
	dir = V3.new(dir.X, 0, dir.Z).Unit
	local right = V3.new(-dir.Z, 0, dir.X)
	inset = inset or 30
	side = side or 3
	return { pos = tip + dir * inset + right * side, out = tip + dir * inset - right * side }
end

function C.run(opts)
	local ends = opts.ends
	local rate = opts.rate or 0.1
	local secs = opts.secs or 300
	local rng = W.E.Random.new(opts.seed or 7)
	local acc = {}
	for i in ends do acc[i] = rng:NextNumber() end
	local spawned, blocked, noroute = 0, 0, 0
	local samples = {}
	local t0 = os.clock()
	local driverTime = 0
	W.run(secs, opts.fps or 30, function(i, dt)
		for k, e in ends do
			acc[k] += (e.rate or rate) * dt
			if acc[k] >= 1 then
				local dest
				if opts.pickDest then dest = opts.pickDest(k, rng) else
					repeat dest = rng:NextInteger(1, #ends) until dest ~= k
				end
				local car, why = W.spawnTrip(e.pos, ends[dest].out, { allowCrossing = opts.allowCrossing, size = opts.size })
				if car then acc[k] -= 1; spawned += 1
				elseif why == "noroute" then noroute += 1; acc[k] -= 1
				else blocked += 1; acc[k] = math.min(acc[k], 1.5) end
			end
		end
		if opts.onFrame then opts.onFrame(i, dt) end
		if i % 6 == 0 then
			W.checkCollisions()
			W.timeBy = W.timeBy or {}
			for model, st in W.Driver._lab.drivers() do
				if model.Parent then
					local r = st.stopReason or "?"
					if (st.currentSpeed or 0) < 0.5 then r = r .. "(stopped)" end
					if r == "blocked(stopped)" then
						W.blockTally = W.blockTally or {}
						local b = st.blockedBy
						local drivers = W.Driver._lab.drivers()
						local k = if not b then "nil" elseif drivers[b] then (if drivers[b].connector then "driverConn" else "driverLane") .. (if (drivers[b].currentSpeed or 0) < 0.5 then "Stopped" else "Moving") else "offgraph"
						if st.connector then k = "meOnConn:" .. k end
						W.blockTally[k] = (W.blockTally[k] or 0) + 1
					end
					W.timeBy[r] = (W.timeBy[r] or 0) + 6 * dt
					if string.find(model.Name, "Bus") then
						W.busTimeBy = W.busTimeBy or {}
						W.busTimeBy[r] = (W.busTimeBy[r] or 0) + 6 * dt
						W.busV = W.busV or { n = 0, sum = 0 }
						W.busV.n += 1; W.busV.sum += st.currentSpeed or 0
					end
				end
			end
		end
		if i % ((opts.fps or 30) * (opts.report or 60)) == 0 then
			local c = W.census()
			table.insert(samples, c)
			if not opts.quiet then
				print(string.format("t=%4ds live=%4d stopped=%4d stuck=%3d avgV=%5.1f arrived=%5d aborted=%3d",
					math.floor(W.E.now), c.n, c.stopped, c.stuck, c.avgSpeed, #W.arrivals, #W.aborts))
			end
		end
	end)
	local real = os.clock() - t0
	local c = W.census()
	local tt, maxT = 0, 0
	local late = 0
	for _, r in W.arrivals do
		local d = r.arrived - r.started
		tt += d
		maxT = math.max(maxT, d)
	end
	local res = {
		spawned = spawned, blocked = blocked, noroute = noroute, arrived = #W.arrivals, aborted = #W.aborts,
		live = c.n, stuck = c.stuck, stopped = c.stopped, meanTrip = if #W.arrivals > 0 then tt / #W.arrivals else 0,
		maxTrip = maxT, real = real, reasons = c.reasons,
		throughputPerHour = #W.arrivals / secs * 3600,
	}
	return res
end

function C.report(name, res)
	print(string.format("RESULT %s spawned=%d blocked=%d noroute=%d arrived=%d (%.0f/h) aborted=%d live=%d stuck=%d meanTrip=%.1fs maxTrip=%.0fs real=%.1fs",
		name, res.spawned, res.blocked, res.noroute, res.arrived, res.throughputPerHour, res.aborted, res.live, res.stuck,
		res.meanTrip, res.maxTrip, res.real))
	local rs = {}
	for r, n in res.reasons do table.insert(rs, r .. "=" .. n) end
	table.sort(rs)
	print("  reasons: " .. table.concat(rs, " "))
	print(string.format("  COLLISIONS %d", W.collisions.events))
	if W.timeBy then
		local tot, list = 0, {}
		for k, v in W.timeBy do tot += v; table.insert(list, { k, v }) end
		table.sort(list, function(a, b) return a[2] > b[2] end)
		local parts = {}
		for i = 1, math.min(10, #list) do table.insert(parts, string.format("%s=%.0f%%", list[i][1], list[i][2] / tot * 100)) end
		print("  TIME " .. table.concat(parts, " "))
		if W.blockTally then
			local bl = {}
			for k, v in W.blockTally do table.insert(bl, k .. "=" .. v) end
			table.sort(bl)
			print("  BLOCKERS " .. table.concat(bl, " "))
		end
		if W.busTimeBy then
			local tb, lb = 0, {}
			for k, v in W.busTimeBy do tb += v; table.insert(lb, { k, v }) end
			table.sort(lb, function(a, b) return a[2] > b[2] end)
			local pb = {}
			for _, kv in lb do table.insert(pb, string.format("%s=%.0f%%", kv[1], 100 * kv[2] / tb)) end
			print(string.format("  BUSTIME total=%.0fs meanV=%.1f ", tb, W.busV.sum / W.busV.n) .. table.concat(pb, " "))
		end
	end
	for _, c in W.collisions.samples do print("    " .. c) end
	local seen, n = {}, 0
	for _, w in W.E.warnings do
		local key = w:gsub("%d+", "#"):sub(1, 120)
		if not seen[key] then seen[key] = 0; n += 1 end
		seen[key] += 1
	end
	for k, v in seen do print(string.format("  WARN x%d %s", v, k)) end
	local shown = 0
	for _, w in W.E.warnings do
		if w:find("stalled") and shown < 6 then shown += 1; print("  STALL " .. w) end
	end
	if W.Driver._diag then
		local ks = {}
		for k, v in W.Driver._diag do table.insert(ks, k .. "=" .. v) end
		table.sort(ks)
		print("  diag: " .. table.concat(ks, " "))
	end
	local seenE = {}
	for _, e in W.E.errors do
		local key = e:sub(1, 300)
		if not seenE[key] then seenE[key] = true; print("  ERR " .. e:sub(1, 900)) end
	end
end

return C
