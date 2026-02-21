-- tests/verify_stamina_fix.luau
-- Verified the StaminaController.TriggerStaminaFailure logic using the actual source file.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

print("Starting Stamina Fix Verification...")

-- 1. Mock Dependencies

-- Signal
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

-- Config
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

-- StatLib
local StatLib = {
	GetStat = function(self, player, name, base)
		return base
	end
}

-- Roblox Services
local RunService = {
	Heartbeat = {
		Connect = function()
			return { Disconnect = function() end }
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

-- Game
local game_mock = {
	GetService = function(self, name)
		if name == "RunService" then return RunService end
		if name == "ReplicatedStorage" then return ReplicatedStorage end
		if name == "Players" then
			return {
				LocalPlayer = {
					CharacterAdded = { Connect = function() end }
				}
			}
		end
		return nil
	end
}

-- Custom Require
local function mockRequire(module)
	if module == ReplicatedStorage.Packages.Signal then return Signal end
	if module == ReplicatedStorage.Shared.Config.StaminaConfig then return StaminaConfig end
	if module == ReplicatedStorage.Shared.Lib.StatLib then return StatLib end
	error("Unknown require: " .. tostring(module))
end

-- 2. Load the actual StaminaController file
local function loadController()
	local content = fs.readFile("src/client/Core/StaminaController.luau")

	-- Create environment
	local env = {
		game = game_mock,
		require = mockRequire,
		print = function(...) end, -- Silence prints
		warn = function(...) print("WARN:", ...) end,
		table = table,
		math = math,
		os = os,
		task = { defer = function(f) f() end },
		script = { Parent = {} } -- Mock script
	}

	local chunk = luau.load(content, {
		environment = env
	})

	return chunk()
end

local StaminaController = loadController()

-- 3. Verify Logic

local testPassed = false
local signalFired = false

-- Listen for OnStaminaFailure
if not StaminaController.OnStaminaFailure then
	error("StaminaController missing OnStaminaFailure signal!")
end

StaminaController.OnStaminaFailure:Connect(function()
	print("  [PASS] OnStaminaFailure signal received.")
	signalFired = true
end)

-- Check TriggerStaminaFailure existence
if not StaminaController.TriggerStaminaFailure then
	error("StaminaController missing TriggerStaminaFailure method!")
end

print("Triggering TriggerStaminaFailure()...")
StaminaController:TriggerStaminaFailure()

if signalFired then
	print("SUCCESS: Stamina failure logic verified.")
else
	error("FAILURE: Signal did not fire.")
end
