--!strict
-- PedestrianView
-- Client-side movement for server-simulated walkers, the pedestrian twin of
-- NPCDriverView. The server simulates walkers (authoritative) but no longer
-- writes walkers' instance CFrames after building them -- poses arrive batched over
-- Net.SyncNpcPoses (unreliable buffer packets, see PathFollower); this view maps
-- entries to walkers via the NpcId attribute and plays each one back on the server's
-- clock (below). Client-only, no client->server path. The figure's body parts
-- are welded to the root, so moving the root locally moves the whole person.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local PedestrianView = {}

local TAG = "NPCWalker"

-- PLAYBACK ON THE SERVER'S CLOCK (2026-10-08, user: walkers "move and freeze"). Every stream
-- packet carries the server's os.clock() at the moment its poses were taken. Each walker keeps
-- the last few poses with those stamps and is drawn at (server time now - its delay): the pose
-- between the two stamps either side of that moment. The server sends a walker every 50-133 ms
-- (its 20 Hz tick against a 1/12 s send step) and packets arrive with network jitter on top;
-- timing the lerp by ARRIVAL turned both into jump-hold-jump, several times a second. On
-- server time, uneven sends and jitter only change how far ahead the buffer runs.
--
-- Server time is estimated from the packets: (stamp - local clock at arrival) is the clock
-- offset minus that packet's travel time, so the largest one seen is the best estimate (the
-- fastest packet). It may only creep down, so a clock drifting the other way is followed
-- without one slow packet dragging every walker back.
local OFFSET_CREEP = 0.02 -- share of a lower reading taken per packet
local _offset: number? = nil

-- How far behind server time a walker plays: at least one send interval plus jitter, so the
-- pose after the playback point has normally arrived. Grows at once when a walker runs out
-- of poses (it would stand still), shrinks slowly while the buffer runs ahead, so a change
-- reads as walking a touch faster or slower, never as a jump.
local DELAY_MIN = 0.15
local DELAY_MAX = 0.75
local DELAY_MARGIN = 0.07
local DELAY_SHRINK = 0.1 -- seconds of delay given back per second
local BUFFER = 5 -- poses kept per walker
local _clock = 0
-- A pose farther than this from the last one is a teleport (spawn, re-path, pop-in), not
-- walking: the walker is put there instead of gliding across the map.
local SNAP_DIST = 12
-- View-direction cull: walkers IN FRONT stay drawn at any distance; walkers BEHIND the
-- camera are hidden and not moved (still simulated on the server). Cosines of the angle off
-- the camera look vector; hysteresis between show and hide so turning never flickers.
local FRONT_COS = 0.05
local BEHIND_COS = -0.19
local POS_EPS = 1e-3
-- Past NEAR_DIST a walker is redrawn on every FAR_EVERY-th frame, staggered, but never less
-- often than FAR_MIN_HZ: at 30 fps every frame, so far walkers do not drop to 10 Hz.
local NEAR_DIST = 300
local FAR_EVERY = 3
local FAR_MIN_HZ = 20
local _frame = 0
local _slotSeq = 0

type Tracked = {
	root: BasePart, model: Model, display: CFrame,
	poses: { CFrame }, stamps: { number }, -- oldest first, server time
	delay: number,
	farewellAt: number?, -- server stamp of the last pose before the walker left our stream
	hidden: boolean?, -- behind the camera
	gone: boolean?, -- past its farewell pose: out of our stream, so not drawn
	slot: number,
}

-- Stream packet layout (must match PathFollower): f64 timestamp header, then
-- entries of (id u32, x f32, y f32, z f32, yaw u16, pitch i8).
local STREAM_HEADER = 8
local STREAM_ENTRY = 19
local FAREWELL_PITCH = -128

-- Hide/show a whole walker model client-side via LocalTransparencyModifier (the server's
-- authoritative Transparency is untouched). Only called on a hide<->show transition.
local function setModelHidden(model: Model, hidden: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = if hidden then 1 else 0 end
	end
end

local _tracked: { [Model]: Tracked } = {}
local _pending: { [Model]: RBXScriptConnection } = {}
local _conns: { RBXScriptConnection } = {}
local _byId: { [number]: Model } = {}
local _idConns: { [Model]: RBXScriptConnection } = {}

local function track(model: Model)
	if _tracked[model] then return end
	local root = model.PrimaryPart
	if not root then
		if _pending[model] then return end
		_pending[model] = model:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
			local p = _pending[model]
			if p then p:Disconnect() end
			_pending[model] = nil
			track(model)
		end)
		return
	end
	_slotSeq += 1
	-- Until its first stream pose, a walker stands where the server built it.
	_tracked[model] = {
		root = root, model = model, display = root.CFrame,
		poses = {}, stamps = {}, delay = DELAY_MIN,
		slot = _slotSeq,
	}
	local id = model:GetAttribute("NpcId")
	if typeof(id) == "number" then
		_byId[id] = model
	end
	-- Keep listening so a re-assigned id can never orphan the map.
	_idConns[model] = model:GetAttributeChangedSignal("NpcId"):Connect(function()
		local v = model:GetAttribute("NpcId")
		if typeof(v) == "number" then _byId[v] = model end
	end)
end

local function untrack(model: Model)
	_tracked[model] = nil
	local id = model:GetAttribute("NpcId")
	if typeof(id) == "number" and _byId[id] == model then _byId[id] = nil end
	local ic = _idConns[model]
	if ic then ic:Disconnect(); _idConns[model] = nil end
	local p = _pending[model]
	if p then p:Disconnect(); _pending[model] = nil end
end

-- The pose at server time `at`, and whether the buffer had run out (at is past its newest pose).
local function poseAt(t: Tracked, at: number): (CFrame?, boolean)
	local stamps, poses = t.stamps, t.poses
	local n = #stamps
	if n == 0 then return nil, false end
	if at >= stamps[n] then return poses[n], at > stamps[n] end
	if at <= stamps[1] then return poses[1], false end
	for i = n - 1, 1, -1 do
		local s0 = stamps[i]
		if at >= s0 then
			-- Drop what playback has passed, keeping the segment it is on.
			for _ = 1, i - 1 do
				table.remove(stamps, 1)
				table.remove(poses, 1)
			end
			local s1 = stamps[2]
			return poses[1]:Lerp(poses[2], (at - s0) / (s1 - s0)), false
		end
	end
	return poses[1], false
end

-- One batched move per frame, as NPCDriverView does for cars: workspace:BulkMoveTo is the
-- engine's cheap path for moving many parts, and a CFrame write per walker paid the full
-- per-property cost for each. Reused so a frame allocates nothing.
local _moveParts: { BasePart } = {}
local _moveCFrames: { CFrame } = {}

local function step(dt: number)
	_clock += dt
	_frame += 1
	table.clear(_moveParts)
	table.clear(_moveCFrames)
	local serverNow = if _offset then _clock + _offset else nil
	local farEvery = math.clamp(math.floor(1 / (FAR_MIN_HZ * math.max(dt, 1e-3))), 1, FAR_EVERY)
	local camera = workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else nil
	local camLook = if camera then camera.CFrame.LookVector else nil

	for model, t in _tracked do
		local root = t.root
		if not root.Parent then
			_tracked[model] = nil
			continue
		end
		if not serverNow or #t.stamps == 0 then continue end

		local at = serverNow - t.delay
		local pose, starved = poseAt(t, at)
		if not pose then continue end
		if starved then
			-- Out of poses: hold playback on the newest one by playing further behind from now on,
			-- so the next pose continues from there instead of jumping. A walker standing still
			-- (a kerb wait sends nothing) also lands here; it costs only some delay.
			t.delay = math.min(DELAY_MAX, serverNow - t.stamps[#t.stamps])
		else
			local stamps = t.stamps
			local gap = if #stamps >= 2 then stamps[#stamps] - stamps[#stamps - 1] else 0
			local want = math.clamp(gap + DELAY_MARGIN, DELAY_MIN, DELAY_MAX)
			if t.delay > want then t.delay = math.max(want, t.delay - DELAY_SHRINK * dt) end
		end

		local farewell = t.farewellAt
		if farewell and at >= farewell then
			if not t.gone then t.gone = true; setModelHidden(model, true) end
			continue
		end

		if camPos and camLook then
			local off = pose.Position - camPos
			local mag = off.Magnitude
			local dot = if mag > 1e-3 then off:Dot(camLook) / mag else 1
			if dot < BEHIND_COS then
				if not t.hidden then t.hidden = true; setModelHidden(model, true) end
				continue
			elseif dot > FRONT_COS and t.hidden then
				t.hidden = false
				setModelHidden(model, false)
			end
			if t.hidden then continue end
			if mag > NEAR_DIST and (t.slot + _frame) % farEvery ~= 0 then continue end
		end

		if (pose.Position - t.display.Position).Magnitude < POS_EPS
			and pose.LookVector:Dot(t.display.LookVector) > 0.9999 then
			continue
		end
		t.display = pose
		table.insert(_moveParts, root)
		table.insert(_moveCFrames, pose)
	end
	if #_moveParts > 0 then
		workspace:BulkMoveTo(_moveParts, _moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Decode one stream packet; feed each known walker's pose into its buffer.
local function onStreamPacket(buf: buffer)
	if typeof(buf) ~= "buffer" or buffer.len(buf) < STREAM_HEADER + STREAM_ENTRY then return end
	local stamp = buffer.readf64(buf, 0)
	local reading = stamp - _clock
	local offset = _offset
	if not offset or reading > offset then
		_offset = reading
	else
		_offset = offset + (reading - offset) * OFFSET_CREEP
	end
	local n = (buffer.len(buf) - STREAM_HEADER) // STREAM_ENTRY
	for k = 0, n - 1 do
		local off = STREAM_HEADER + k * STREAM_ENTRY
		local model = _byId[buffer.readu32(buf, off)]
		if not model then continue end
		local t = _tracked[model]
		if not t then continue end
		local stamps, poses = t.stamps, t.poses
		local last = #stamps
		if last > 0 and stamp <= stamps[last] then continue end
		local pos = Vector3.new(buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8), buffer.readf32(buf, off + 12))
		local yaw = buffer.readu16(buf, off + 16) / 65535 * (2 * math.pi) - math.pi
		-- FAREWELL_PITCH marks a walker's last pose before it leaves our stream (PathFollower):
		-- it is drawn there, then hidden until the stream picks it up again.
		local pitchRaw = buffer.readi8(buf, off + 18)
		local farewell = pitchRaw == FAREWELL_PITCH
		local pitch = if farewell then 0 else math.rad(pitchRaw)
		local cosP = math.cos(pitch)
		local look = Vector3.new(-math.sin(yaw) * cosP, math.sin(pitch), -math.cos(yaw) * cosP)
		local pose = CFrame.lookAt(pos, pos + look, Vector3.yAxis)
		local ref = if last > 0 then poses[last] else t.display
		if (pose.Position - ref.Position).Magnitude > SNAP_DIST then
			-- A teleport: start the buffer over there. Drawn at once by the next frame.
			table.clear(stamps)
			table.clear(poses)
			t.display = pose
			t.root.CFrame = pose
		end
		table.insert(stamps, stamp)
		table.insert(poses, pose)
		if #stamps > BUFFER then
			table.remove(stamps, 1)
			table.remove(poses, 1)
		end
		if farewell then
			t.farewellAt = stamp
		elseif t.farewellAt then
			t.farewellAt = nil
			if t.gone then
				t.gone = false
				if not t.hidden then setModelHidden(model, false) end
			end
		end
	end
end

function PedestrianView.Start()
	local Net = require(ReplicatedStorage:WaitForChild("Networker")) :: any
	table.insert(_conns, Net.SyncNpcPoses.OnClientEvent:Connect(onStreamPacket))

	for _, m in CollectionService:GetTagged(TAG) do
		if m:IsA("Model") then track(m) end
	end
	table.insert(_conns, CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
		if inst:IsA("Model") then track(inst :: Model) end
	end))
	table.insert(_conns, CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
		untrack(inst :: Model)
	end))
	table.insert(_conns, RunService.RenderStepped:Connect(step))
end

function PedestrianView.Stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	for _, c in _pending do c:Disconnect() end
	table.clear(_pending)
	for _, c in _idConns do c:Disconnect() end
	table.clear(_idConns)
	table.clear(_byId)
	table.clear(_tracked)
end

return PedestrianView
