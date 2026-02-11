--[[
    ScreenShakeController.luau
    Handles camera shake effects for combat impact.
    Uses perlin noise for natural-feeling shake.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local ScreenShakeController = {}
ScreenShakeController.Name = "ScreenShakeController"

-- Config shorthand
local ShakeConfig = CombatConfig.ScreenShake

-- State
local currentIntensity = 0
local currentDuration = 0
local shakeStartTime = 0
local shakeOffset = CFrame.new()
local noiseSeed = math.random(0, 10000)

-- Reference to camera controller (set in Init)
local CameraController = nil

-- Connection
local updateConnection: RBXScriptConnection? = nil

--[[
    Generate perlin noise based offset
]]
local function getNoiseOffset(time: number, intensity: number): CFrame
	local frequency = ShakeConfig.Frequency
	local maxOffset = ShakeConfig.MaxOffset * intensity

	-- Use perlin noise for smooth randomness
	local noiseX = math.noise(time * frequency, noiseSeed, 0)
	local noiseY = math.noise(time * frequency, 0, noiseSeed)
	local noiseZ = math.noise(0, time * frequency, noiseSeed)

	-- Scale by intensity
	local offsetX = noiseX * maxOffset
	local offsetY = noiseY * maxOffset
	local offsetZ = noiseZ * maxOffset * 0.5 -- Less Z shake

	-- Small rotation shake
	local rotX = noiseX * math.rad(2) * intensity
	local rotY = noiseY * math.rad(2) * intensity

	return CFrame.new(offsetX, offsetY, offsetZ) * CFrame.Angles(rotX, rotY, 0)
end

--[[
    Update shake every frame
]]
local function onRenderStepped(deltaTime: number)
	if currentIntensity <= 0 then
		shakeOffset = CFrame.new()
		return
	end

	local elapsed = os.clock() - shakeStartTime

	-- Calculate decay
	local decayMultiplier = 1
	if currentDuration > 0 then
		local progress = elapsed / currentDuration
		-- Exponential decay
		decayMultiplier = math.exp(-ShakeConfig.DecayRate * progress)

		-- End shake when decayed enough
		if decayMultiplier < 0.01 or elapsed > currentDuration then
			currentIntensity = 0
			shakeOffset = CFrame.new()
			return
		end
	end

	-- Calculate final intensity with decay
	local finalIntensity = currentIntensity * decayMultiplier * ShakeConfig.BaseIntensity

	-- Get noise-based offset
	shakeOffset = getNoiseOffset(elapsed, finalIntensity)
end

-- Public API --

--[[
    Get current shake offset (called by CameraController)
]]
function ScreenShakeController:GetShakeOffset(): CFrame
	return shakeOffset
end

--[[
    Apply screen shake
    @param intensity - Shake intensity (0-1, will be multiplied by config)
    @param duration - How long the shake lasts
]]
function ScreenShakeController:Shake(intensity: number, duration: number?)
	if not ShakeConfig.Enabled then
		return
	end

	duration = duration or 0.2

	-- Stack shakes (add intensities, take longer duration)
	if currentIntensity > 0 then
		currentIntensity = math.min(currentIntensity + intensity * 0.5, 1.5)
		currentDuration = math.max(currentDuration, duration)
	else
		currentIntensity = intensity
		currentDuration = duration
		shakeStartTime = os.clock()
	end

	-- Randomize seed for variety
	noiseSeed = math.random(0, 10000)
end

--[[
    Apply combat hit shake (uses attack's ScreenShake value)
]]
function ScreenShakeController:ShakeFromHit(attackData: { ScreenShake: number })
	local intensity = attackData.ScreenShake or 0.3
	local duration = 0.1 + (intensity * 0.1) -- Longer for heavier hits
	self:Shake(intensity, duration)
end

--[[
    Apply heavy impact shake (for finishers, crits, etc.)
]]
function ScreenShakeController:HeavyShake()
	self:Shake(0.8, 0.2)
end

--[[
    Apply light shake (for regular hits)
]]
function ScreenShakeController:LightShake()
	self:Shake(0.3, 0.1)
end

--[[
    Stop all shake immediately
]]
function ScreenShakeController:StopShake()
	currentIntensity = 0
	currentDuration = 0
	shakeOffset = CFrame.new()
end

--[[
    Check if currently shaking
]]
function ScreenShakeController:IsShaking(): boolean
	return currentIntensity > 0
end

--[[
    Initialize the controller
]]
function ScreenShakeController:Init()
	-- Try to get CameraController reference
	local success, result = pcall(function()
		return require(script.Parent.Parent.Core.CameraController)
	end)
	if success then
		CameraController = result
	end

	print("[ScreenShakeController] Initialized")
end

--[[
    Start the controller
]]
function ScreenShakeController:Start()
	-- Update every render frame for smooth shake
	updateConnection = RunService.RenderStepped:Connect(onRenderStepped)

	print("[ScreenShakeController] Started")
end

--[[
    Cleanup
]]
function ScreenShakeController:Destroy()
	if updateConnection then
		updateConnection:Disconnect()
		updateConnection = nil
	end
	shakeOffset = CFrame.new()
end

return ScreenShakeController
