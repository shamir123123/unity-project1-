--!nocheck
-- PedestrianView smoothness: walkers walking at a steady speed, sent the way the server sends
-- them (a 20 Hz walker tick on 60 Hz frames, a pose every 1/12 s of it, so gaps of 50-133 ms),
-- over a network with latency, jitter and loss, drawn at 60 or 30 fps. Reports how often a
-- walker stands still for a frame while it should be walking ("frozen"), the spread of its
-- per-frame steps, and its biggest single step, against the steady step it should take.
-- Usage (from tools/harness): lune run test_walker_stream.luau [rev]   (rev: older view code)
local H = require("./loader")
local process = require("@lune/process")
local rev = process.args[1]
if rev then
	H.patches["StarterPlayer.StarterPlayerScripts.World.PedestrianView"] = function()
		return process.exec("git", { "show", rev .. ":src/StarterPlayer.StarterPlayerScripts.World.PedestrianView.luau" }).stdout
	end
end
local signal = H.rbx.Signal.new()
local netStub = { SyncNpcPoses = { OnClientEvent = signal } }
H.boot({ server = false, overrides = { ["ReplicatedStorage.Networker"] = netStub } })
H.quietWarn = true
local I = H.rbx.Instance
local V3, CF = H.roblox.Vector3, H.roblox.CFrame
local ws = H.game:GetService("Workspace")
ws._props.BulkMoveTo = function(_, parts, cfs)
	for i, p in parts do p.CFrame = cfs[i] end
end
ws.CurrentCamera.CFrame = CF.new(0, 40, -60) * CF.Angles(0, math.pi, 0)
local View = H.require("StarterPlayer.StarterPlayerScripts.World.PedestrianView")
local rs = H.game:GetService("RunService").RenderStepped

local SPEED = 5 -- studs per second (2.5 walk speed at 2x base rate)
local seed = 12345
local function rnd()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

local function run(label, opts)
	seed = 12345
	local N = 8
	local walkers = {}
	for i = 1, N do
		local m = I.new("Model"); m.Name = "W" .. i
		local root = I.new("Part"); root.Name = "HumanoidRootPart"; root.CFrame = CF.new(i * 6 - 24, 3, 20); root.Parent = m
		m.PrimaryPart = root
		m:SetAttribute("NpcId", 1000 * opts.id + i)
		m.Parent = ws
		m:AddTag("NPCWalker")
		walkers[i] = m
	end
	View.Start()
	local fps = opts.fps or 60
	local frameDt = 1 / fps
	local serverBase = 5000 + opts.id * 100 -- server os.clock differs from the client's
	local sendEvery = opts.sendEvery or (1 / 12)
	local queue = {} -- { at = client arrival time, buf = buffer }
	local function send(serverT, clientT)
		if rnd() < (opts.loss or 0) then return end
		local buf = buffer.create(8 + 19 * N)
		buffer.writef64(buf, 0, serverBase + serverT)
		for i = 1, N do
			local off = 8 + (i - 1) * 19
			buffer.writeu32(buf, off, 1000 * opts.id + i)
			buffer.writef32(buf, off + 4, i * 6 - 24)
			buffer.writef32(buf, off + 8, 3)
			buffer.writef32(buf, off + 12, 20 + SPEED * serverT)
			buffer.writeu16(buf, off + 16, 0)
			buffer.writei8(buf, off + 18, 0)
		end
		local at = clientT + (opts.latency or 0.08) + rnd() * (opts.jitter or 0)
		table.insert(queue, { at = at, buf = buf })
	end
	-- server: 60 Hz frames, the walker tick when 1/20 s has gathered, a send each 1/12 s of it
	local serverT, accum, sendAccum = 0, 0, 0
	local clientT = 0
	local nextServerFrame = 0
	local zs = {}
	local total = opts.seconds or 14
	while clientT < total do
		clientT += frameDt
		while nextServerFrame <= clientT do
			accum += 1 / 60
			if accum >= 1 / 20 - 1e-9 then
				serverT += accum
				sendAccum += accum
				accum = 0
				if sendAccum >= sendEvery - 1e-9 then
					sendAccum %= sendEvery
					send(serverT, nextServerFrame)
				end
			end
			nextServerFrame += 1 / 60
		end
		table.sort(queue, function(a, b) return a.at < b.at end)
		while queue[1] and queue[1].at <= clientT do
			signal:Fire(table.remove(queue, 1).buf)
		end
		rs:Fire(frameDt)
		table.insert(zs, walkers[1].PrimaryPart.CFrame.Position.Z)
	end
	View.Stop()
	for _, m in walkers do m:Destroy() end
	-- after a 3 s warm-up
	local want = SPEED * frameDt
	local steps = {}
	for k = math.floor(3 * fps) + 1, #zs do table.insert(steps, zs[k] - zs[k - 1]) end
	local frozen, maxStep, sum, sq = 0, 0, 0, 0
	for _, d in steps do
		if d < want * 0.1 then frozen += 1 end
		maxStep = math.max(maxStep, d)
		sum += d
		sq += d * d
	end
	local mean = sum / #steps
	local sd = math.sqrt(math.max(0, sq / #steps - mean * mean))
	print(string.format("%-40s frozen %5.1f%% of frames | step spread %4.2f | biggest step %4.1fx | mean speed %4.2f/%4.2f",
		label, frozen / #steps * 100, sd / want, maxStep / want, mean / frameDt, SPEED))
end

run("steady network, 60 fps", { id = 1 })
run("jitter 40 ms, 60 fps", { id = 2, jitter = 0.04 })
run("jitter 60 ms + 3% loss, 60 fps", { id = 3, jitter = 0.06, loss = 0.03 })
run("jitter 40 ms, 30 fps", { id = 4, jitter = 0.04, fps = 30 })
run("4 Hz band (1000-1500 studs), jitter 40", { id = 5, jitter = 0.04, sendEvery = 0.25 })
run("2 Hz band (1500-4000 studs), jitter 40", { id = 6, jitter = 0.04, sendEvery = 0.5 })
process.exit(0)
