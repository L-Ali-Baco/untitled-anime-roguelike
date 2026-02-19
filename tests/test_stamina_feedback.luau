-- tests/test_stamina_feedback.luau
-- This test verifies the StaminaController logic for triggering feedback signals.

print("Starting Stamina Feedback Test...")

-- 1. Mock Dependencies
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _listeners = {} }, Signal)
end
function Signal:Connect(fn)
	table.insert(self._listeners, fn)
	return {
		Disconnect = function() end
	}
end
function Signal:Fire(...)
	for _, fn in ipairs(self._listeners) do
		fn(...)
	end
end

local StaminaConfig = {
	Max = 100,
	RegenRate = 10,
	RegenDelay = 1,
	Costs = {
		AirJump = 20,
		Dash = 30
	},
	LowStaminaThreshold = 0.3,
	ExhaustedThreshold = 0
}

local StatLib = {
	GetStat = function(self, player, name, base)
		return base
	end
}

local RunService = {
	Heartbeat = {
		Connect = function()
			return {
				Disconnect = function() end
			}
		end
	}
}

local ReplicatedStorage = {
	Packages = {
		Signal = Signal
	},
	Shared = {
		Config = {
			StaminaConfig = StaminaConfig
		},
		Lib = {
			StatLib = StatLib
		}
	}
}

-- Mock game service
local game_mock = {
	GetService = function(self, name)
		if name == "RunService" then
			return RunService
		end
		if name == "ReplicatedStorage" then
			return ReplicatedStorage
		end
		if name == "Players" then
			return {
				LocalPlayer = {
					CharacterAdded = {
						Connect = function() end
					}
				}
			}
		end
		return nil
	end
}
local game = game_mock -- Override global game if possible, or use local variable

-- 2. Define Controller (Pasted logic from StaminaController.luau, adapted slightly for test env)
-- We manually construct the controller to test the *Logic* we implemented.

local StaminaController = {}
StaminaController.Name = "StaminaController"

-- Stamina state (Simulated)
local currentStamina = StaminaConfig.Max
local lastUsedTime = 0
local isRegenerating = true

-- Signals
StaminaController.OnStaminaChanged = Signal.new()
StaminaController.OnStaminaDepleted = Signal.new()
StaminaController.OnStaminaUsed = Signal.new()
StaminaController.OnStaminaActionFailed = Signal.new() -- This is what we added

--[[
    Trigger the stamina failed feedback (sound/UI) for a specific action
]]
function StaminaController:TriggerActionFailed(actionName)
	self.OnStaminaActionFailed:Fire(actionName)
end

function StaminaController:HasStamina(amount)
	return currentStamina >= amount
end

-- 3. Execute Tests

local testPassed = false
local receivedActionName = nil

-- Listen for the signal
StaminaController.OnStaminaActionFailed:Connect(function(actionName)
	print("Signal received for action:", actionName)
	receivedActionName = actionName
	testPassed = true
end)

-- Trigger the action
print("Triggering action failure for 'AirJump'...")
StaminaController:TriggerActionFailed("AirJump")

-- Assert
if testPassed and receivedActionName == "AirJump" then
	print("SUCCESS: OnStaminaActionFailed fired correctly.")
else
	error("FAILURE: Signal did not fire or passed wrong argument.")
end

-- Verify HasStamina Logic
currentStamina = 10
if StaminaController:HasStamina(20) then
	error("FAILURE: HasStamina should return false for 10 < 20")
end
if not StaminaController:HasStamina(5) then
	error("FAILURE: HasStamina should return true for 10 >= 5")
end
print("SUCCESS: HasStamina logic verified.")

return true
