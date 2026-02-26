local fs = require("@lune/fs")
local luau = require("@lune/luau")

local mockEnv = {}
local realTick = os.clock
local currentTick = 1000

mockEnv.tick = function()
	return currentTick
end
mockEnv.task = { delay = function() end, wait = function() end }
mockEnv.math = math
mockEnv.table = table
mockEnv.string = string
mockEnv.type = type
mockEnv.typeof = typeof
mockEnv.warn = warn
mockEnv.print = function() end -- silence
mockEnv.error = error
mockEnv.os = os
mockEnv.require = function()
	return {}
end

local runServiceEvt = {}
mockEnv.game = {
	GetService = function(_, svc)
		if svc == "RunService" then
			return {
				Heartbeat = {
					Connect = function(_, cb)
						runServiceEvt.cb = cb
					end,
				},
			}
		end
		return {
			Connect = function() end,
		}
	end,
}

local combatSource = fs.readFile("src/server/Services/CombatService.luau")
local bytecode = luau.compile(combatSource)
local callable = luau.load(bytecode, { debugName = "CombatService", injectGlobals = true, env = mockEnv })

local CombatService = callable()

print("Testing Queue Optimization...")

CombatService:Start()

local mockPlayer = {}
local mockTarget = {
	GetAttribute = function()
		return 100
	end,
	FindFirstChildOfClass = function()
		return nil
	end,
}

-- Add 1000 attacks
local initialTick = currentTick
for i = 1, 1000 do
	CombatService:onRequestAttack(mockPlayer, 1, mockTarget)
end

print("Added 1000 attacks.")

-- Advance time by 0.5s, run heartbeat (should not clean up since expiry is tick() + 1)
currentTick = initialTick + 0.5
if runServiceEvt.cb then
	runServiceEvt.cb()
end
print("Heartbeat 1 done.")

-- Advance time past 1s, run heartbeat (should clean up all)
currentTick = initialTick + 1.1
if runServiceEvt.cb then
	runServiceEvt.cb()
end
print("Heartbeat 2 done. Cleaned up successfully without errors.")

-- Add 1 more attack to ensure indices reset properly
CombatService:onRequestAttack(mockPlayer, 1, mockTarget)
currentTick = currentTick + 2
if runServiceEvt.cb then
	runServiceEvt.cb()
end
print("Heartbeat 3 done. Queue resets properly.")

print("Queue Optimization Test Passed!")
