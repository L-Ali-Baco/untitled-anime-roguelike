--[[
    Benchmark for require optimization in CombatService.luau

    To run this benchmark, you need a Luau runtime (e.g. `lune` or `luau`).
    Run with: `lune run tests/benchmark_require.luau` or `luau tests/benchmark_require.luau`

    Scenario:
    - Simulate the overhead of `require(script.Parent.ClassService)` inside a hot path function `validateAttack`.
    - Compare with cached module reference (upvalue).
]]

-- Simulate the environment structure
local ClassServiceModule = {
    GetPlayerClass = function(self, player)
        return "Warrior"
    end
}

-- Simulate the script hierarchy and property access overhead
local script = {
    Parent = {
        ClassService = ClassServiceModule
    }
}

-- Simulate require function overhead (lookup + validation)
local function require(module)
    -- In Roblox, require checks if the module is valid, returns the cached result, etc.
    -- We simulate a minimal overhead here.
    if type(module) == "table" then
        return module
    end
    return nil
end

local Player = {} -- Dummy player object

-- 1. Current Implementation: require inside the function
local function validateAttack_Current(player)
    -- The overhead comes from:
    -- 1. Indexing `script`
    -- 2. Indexing `Parent`
    -- 3. Indexing `ClassService`
    -- 4. Calling `require`
    local ClassService = require(script.Parent.ClassService)
    local className = ClassService:GetPlayerClass(player) or "Warrior"
    return className
end

-- 2. Optimized Implementation: require at top level (cached upvalue)
local ClassService_Optimized = require(script.Parent.ClassService)

local function validateAttack_Optimized(player)
    -- Here we only access the upvalue `ClassService_Optimized`
    local className = ClassService_Optimized:GetPlayerClass(player) or "Warrior"
    return className
end

-- Run Benchmark
local iterations = 1000000
print(string.format("Running benchmark with %d iterations...", iterations))

local start = os.clock()
for i = 1, iterations do
    validateAttack_Current(Player)
end
local durationCurrent = os.clock() - start
print(string.format("Current Implementation Time:  %.6f s", durationCurrent))

start = os.clock()
for i = 1, iterations do
    validateAttack_Optimized(Player)
end
local durationOptimized = os.clock() - start
print(string.format("Optimized Implementation Time: %.6f s", durationOptimized))

local improvement = (durationCurrent - durationOptimized) / durationCurrent * 100
print(string.format("Performance Improvement:       %.2f%%", improvement))
