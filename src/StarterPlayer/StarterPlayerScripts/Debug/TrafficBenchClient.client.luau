--!strict
-- LocalScript -> StarterPlayerScripts/Debug
-- While a TrafficBenchmark runs on the server (workspace attribute TrafficBenchActive), sends
-- this device's frame rate once a second: mean FPS, the 95th-percentile frame time, and whether
-- it is a touch device. Idle otherwise -- one attribute read a frame.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))

local REPORT_INTERVAL = 1

local frames: { number } = {}
local elapsed = 0

RunService.RenderStepped:Connect(function(dt: number)
	if workspace:GetAttribute("TrafficBenchActive") ~= true then
		if #frames > 0 then table.clear(frames) end
		elapsed = 0
		return
	end
	table.insert(frames, dt)
	elapsed += dt
	if elapsed < REPORT_INTERVAL then return end
	local total = 0
	for _, d in frames do total += d end
	table.sort(frames)
	local p95 = frames[math.clamp(math.ceil(#frames * 0.95), 1, #frames)]
	local mobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	Net.ReportBenchFrameStats:FireServer(#frames / total, p95 * 1000, mobile)
	table.clear(frames)
	elapsed = 0
end)
