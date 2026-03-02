--[[
    StaminaController.luau
    Manages stamina resource for abilities like dashing.
    Handles consumption, regeneration, and provides signals for UI updates.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local StaminaConfig = require(ReplicatedStorage.Shared.Config.StaminaConfig)
local StatLib = require(ReplicatedStorage.Shared.Lib.StatLib)

local StaminaController = {}
StaminaController.Name = "StaminaController"

-- Stamina state
local currentStamina = StaminaConfig.Max
local lastUsedTime = 0
local isRegenerating = true

-- Signals for UI/effects
StaminaController.OnStaminaChanged = Signal.new() -- Fires (current, max, percent)
StaminaController.OnStaminaDepleted = Signal.new() -- Fires when stamina hits 0
StaminaController.OnStaminaUsed = Signal.new() -- Fires (amount, remaining)
StaminaController.OnStaminaFailure = Signal.new() -- Fires when stamina check fails

-- Connections
local connections: { RBXScriptConnection } = {}

--[[
    Update stamina regeneration
]]
local function onHeartbeat(deltaTime: number)
	-- Check if we can regenerate
	local timeSinceUse = os.clock() - lastUsedTime

	if timeSinceUse < StaminaConfig.RegenDelay then
		isRegenerating = false
		return
	end

	-- Don't regenerate if already full
	if currentStamina >= StaminaConfig.Max then
		isRegenerating = false
		return
	end

	-- Start/continue regenerating
	isRegenerating = true
	local baseRegen = StaminaConfig.RegenRate
	local regenRate = StatLib:GetStat(game.Players.LocalPlayer, "StaminaRegen", baseRegen)

	local regenAmount = regenRate * deltaTime
	local newStamina = math.min(currentStamina + regenAmount, StaminaConfig.Max)

	if newStamina ~= currentStamina then
		currentStamina = newStamina
		StaminaController.OnStaminaChanged:Fire(currentStamina, StaminaConfig.Max, currentStamina / StaminaConfig.Max)
	end
end

-- Public API --

--[[
    Get current stamina amount
]]
function StaminaController:GetStamina(): number
	return currentStamina
end

--[[
    Get max stamina
]]
function StaminaController:GetMaxStamina(): number
	return StaminaConfig.Max
end

--[[
    Get stamina as percentage (0-1)
]]
function StaminaController:GetStaminaPercent(): number
	return currentStamina / StaminaConfig.Max
end

--[[
    Check if player has enough stamina for an action
]]
function StaminaController:HasStamina(amount: number): boolean
	return currentStamina >= amount
end

--[[
    Check if player can perform a specific action
]]
function StaminaController:CanPerformAction(actionName: string): boolean
	local cost = StaminaConfig.Costs[actionName]
	if not cost then
		warn("[StaminaController] Unknown action:", actionName)
		return false
	end
	return currentStamina >= cost
end

--[[
    Consume stamina for an action
    Returns true if successful, false if not enough stamina
]]
function StaminaController:UseStamina(amount: number): boolean
	if currentStamina < amount then
		return false
	end

	currentStamina = math.max(0, currentStamina - amount)
	lastUsedTime = os.clock()
	isRegenerating = false

	StaminaController.OnStaminaUsed:Fire(amount, currentStamina)
	StaminaController.OnStaminaChanged:Fire(currentStamina, StaminaConfig.Max, currentStamina / StaminaConfig.Max)

	if currentStamina <= 0 then
		StaminaController.OnStaminaDepleted:Fire()
	end

	return true
end

--[[
    Consume stamina for a named action
    Returns true if successful, false if not enough stamina
]]
function StaminaController:UseStaminaForAction(actionName: string): boolean
	local cost = StaminaConfig.Costs[actionName]
	if not cost then
		warn("[StaminaController] Unknown action:", actionName)
		return false
	end
	return self:UseStamina(cost)
end

--[[
    Restore stamina (for pickups, abilities, etc.)
]]
function StaminaController:RestoreStamina(amount: number)
	local newStamina = math.min(currentStamina + amount, StaminaConfig.Max)
	if newStamina ~= currentStamina then
		currentStamina = newStamina
		StaminaController.OnStaminaChanged:Fire(currentStamina, StaminaConfig.Max, currentStamina / StaminaConfig.Max)
	end
end

--[[
    Set stamina to max (for respawns, etc.)
]]
function StaminaController:ResetStamina()
	currentStamina = StaminaConfig.Max
	lastUsedTime = 0
	isRegenerating = true
	StaminaController.OnStaminaChanged:Fire(currentStamina, StaminaConfig.Max, 1)
end

--[[
    Check if stamina is currently regenerating
]]
function StaminaController:IsRegenerating(): boolean
	return isRegenerating
end

--[[
    Check if stamina is below the low threshold (for UI warning)
]]
function StaminaController:IsLowStamina(): boolean
	return (currentStamina / StaminaConfig.Max) <= StaminaConfig.LowStaminaThreshold
end

--[[
    Check if completely exhausted
]]
function StaminaController:IsExhausted(): boolean
	return currentStamina <= StaminaConfig.ExhaustedThreshold
end

--[[
    Trigger stamina failure feedback
]]
function StaminaController:TriggerStaminaFailure()
	StaminaController.OnStaminaFailure:Fire()
end

--[[
    Initialize the controller
]]
function StaminaController:Init()
	print("[StaminaController] Initialized")
end

--[[
    Start the controller
]]
function StaminaController:Start()
	-- Connect to heartbeat for regeneration
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	-- Reset stamina on spawn
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function()
			StaminaController:ResetStamina()
		end)
	)

	-- Fire initial state for UI
	task.defer(function()
		StaminaController.OnStaminaChanged:Fire(currentStamina, StaminaConfig.Max, currentStamina / StaminaConfig.Max)
	end)

	print("[StaminaController] Started")
end

--[[
    Cleanup
]]
function StaminaController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return StaminaController
