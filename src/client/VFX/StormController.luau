--[[
    StormController.luau
    Client-side visual effects for the Director System ("The Storm").
    
    Responsibilities:
    - Darken sky based on difficulty
    - Add fog/atmosphere effects
    - Respond to Director events (horde warnings, etc.)
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DirectorConfig = require(ReplicatedStorage.Shared.Config.DirectorConfig)

local StormController = {}
StormController.Name = "StormController"

-- State
local currentDifficulty = DirectorConfig.BaseDifficulty
local originalLighting = {}
local atmosphere = nil
local fog = nil

-- Connections
local connections = {}

--[[
    Store original lighting values
]]
local function storeOriginalLighting()
	originalLighting = {
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogColor = Lighting.FogColor,
		FogStart = Lighting.FogStart,
		FogEnd = Lighting.FogEnd,
	}
end

--[[
    Lerp between two Color3 values
]]
local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

--[[
    Get or create the Atmosphere effect
]]
local function getAtmosphere(): Atmosphere
	if atmosphere and atmosphere.Parent then
		return atmosphere
	end

	-- Find existing or create new
	atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "StormAtmosphere"
		atmosphere.Parent = Lighting
	end

	return atmosphere
end

--[[
    Calculate visual progress based on difficulty and thresholds
]]
local function getVisualProgress(difficulty: number, startDiff: number, maxDiff: number): number
	if difficulty < startDiff then
		return 0
	end

	local progress = (difficulty - startDiff) / (maxDiff - startDiff)
	return math.clamp(progress, 0, 1)
end

--[[
    Update sky darkening
]]
local function updateSkyDarkening(difficulty: number)
	local config = DirectorConfig.Visuals
	if not config.SkyDarkeningEnabled then
		return
	end

	local progress = getVisualProgress(difficulty, config.SkyStartDifficulty, config.SkyMaxDarkDifficulty)

	-- Lerp clock time from day to night
	local targetClockTime = config.DayClockTime + (config.NightClockTime - config.DayClockTime) * progress

	-- Handle wrap-around (14 -> 0 should go through 24)
	if config.DayClockTime > config.NightClockTime then
		-- Going from afternoon to midnight
		if progress > 0.5 then
			targetClockTime = config.DayClockTime + ((24 - config.DayClockTime) + config.NightClockTime) * progress
			if targetClockTime >= 24 then
				targetClockTime = targetClockTime - 24
			end
		end
	end

	-- Smooth transition
	TweenService:Create(Lighting, TweenInfo.new(1, Enum.EasingStyle.Quad), {
		ClockTime = targetClockTime,
		Brightness = 2 - progress * 1.5, -- Dimmer at high difficulty
	}):Play()
end

--[[
    Update fog effects
]]
local function updateFog(difficulty: number)
	local config = DirectorConfig.Visuals
	if not config.FogEnabled then
		return
	end

	local progress = getVisualProgress(difficulty, config.FogStartDifficulty, config.FogMaxDifficulty)

	if progress <= 0 then
		-- No fog yet
		Lighting.FogEnd = 100000
		return
	end

	-- Lerp fog color
	local fogColor = lerpColor(config.FogColorStart, config.FogColorEnd, progress)

	-- Lerp fog distance (closer = denser)
	local fogEnd = config.FogEndDistanceMin + (config.FogEndDistanceMax - config.FogEndDistanceMin) * progress

	TweenService:Create(Lighting, TweenInfo.new(1, Enum.EasingStyle.Quad), {
		FogColor = fogColor,
		FogStart = config.FogStartDistance * (1 - progress * 0.5),
		FogEnd = fogEnd,
	}):Play()
end

--[[
    Update atmosphere effects
]]
local function updateAtmosphere(difficulty: number)
	local config = DirectorConfig.Visuals
	if not config.AtmosphereEnabled then
		return
	end

	local progress = getVisualProgress(difficulty, config.FogStartDifficulty, config.FogMaxDifficulty)

	local atmo = getAtmosphere()

	-- Lerp atmosphere properties
	local density = config.AtmosphereDensityMin + (config.AtmosphereDensityMax - config.AtmosphereDensityMin) * progress
	local color = lerpColor(config.AtmosphereColorStart, config.AtmosphereColorEnd, progress)

	TweenService:Create(atmo, TweenInfo.new(1, Enum.EasingStyle.Quad), {
		Density = density,
		Color = color,
		Decay = color,
		Glare = progress * 0.5,
		Haze = progress * 3,
	}):Play()
end

--[[
    Handle difficulty update from server
]]
local function onDifficultyUpdate(data)
	currentDifficulty = data.Difficulty

	-- Update all visual effects
	updateSkyDarkening(currentDifficulty)
	updateFog(currentDifficulty)
	updateAtmosphere(currentDifficulty)
end

--[[
    Handle horde warning
]]
local function onHordeWarning(data)
	-- Flash screen red briefly
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local flash = Instance.new("ScreenGui")
	flash.Name = "HordeWarningFlash"
	flash.IgnoreGuiInset = true
	flash.DisplayOrder = 100

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	frame.BackgroundTransparency = 0.7
	frame.BorderSizePixel = 0
	frame.Parent = flash

	flash.Parent = playerGui

	-- Pulse effect
	local pulseCount = 3
	local pulseDuration = data.Delay / pulseCount

	for i = 1, pulseCount do
		TweenService:Create(frame, TweenInfo.new(pulseDuration * 0.3), {
			BackgroundTransparency = 0.5,
		}):Play()
		task.wait(pulseDuration * 0.3)
		TweenService:Create(frame, TweenInfo.new(pulseDuration * 0.7), {
			BackgroundTransparency = 0.9,
		}):Play()
		task.wait(pulseDuration * 0.7)
	end

	flash:Destroy()
end

--[[
    Handle director events
]]
local function onEventTriggered(data)
	if data.EventType == "EliteSpawn" then
		-- Could add special VFX for elite spawn
		print("[StormController] ELITE ENEMY SPAWNED!")
	elseif data.EventType == "HordeWave" then
		print("[StormController] HORDE WAVE!", data.EnemyCount, "enemies!")
	end
end

-- Public API --

--[[
    Get current difficulty
]]
function StormController:GetDifficulty(): number
	return currentDifficulty
end

--[[
    Reset visuals to original state
]]
function StormController:ResetVisuals()
	if next(originalLighting) then
		for prop, value in originalLighting do
			Lighting[prop] = value
		end
	end

	if atmosphere then
		atmosphere.Density = 0.2
	end
end

--[[
    Initialize the controller
]]
function StormController:Init()
	storeOriginalLighting()
	print("[StormController] Initialized")
end

--[[
    Start the controller
]]
function StormController:Start()
	-- Connect to remotes
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotesFolder then
		warn("[StormController] Remotes folder not found!")
		return
	end

	-- Difficulty updates
	local difficultyRemote = remotesFolder:FindFirstChild(DirectorConfig.Remotes.DifficultyUpdate)
	if difficultyRemote then
		table.insert(connections, difficultyRemote.OnClientEvent:Connect(onDifficultyUpdate))
	else
		-- Create listener for when remote is added
		remotesFolder.ChildAdded:Connect(function(child)
			if child.Name == DirectorConfig.Remotes.DifficultyUpdate then
				table.insert(connections, child.OnClientEvent:Connect(onDifficultyUpdate))
			end
		end)
	end

	-- Horde warnings
	local hordeRemote = remotesFolder:FindFirstChild(DirectorConfig.Remotes.HordeWarning)
	if hordeRemote then
		table.insert(connections, hordeRemote.OnClientEvent:Connect(onHordeWarning))
	end

	-- Events
	local eventRemote = remotesFolder:FindFirstChild(DirectorConfig.Remotes.EventTriggered)
	if eventRemote then
		table.insert(connections, eventRemote.OnClientEvent:Connect(onEventTriggered))
	end

	print("[StormController] Started")
end

--[[
    Cleanup
]]
function StormController:Destroy()
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)

	self:ResetVisuals()
end

return StormController
