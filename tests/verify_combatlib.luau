--[[
    tests/verify_combatlib.luau
    Standalone verification script for CombatLib.
    This script mocks the Roblox API and verifies that OverlapParams are reused.
    Run with `lune run tests/verify_combatlib.luau`
]]

local process = { exit = function(code) end }
if _G.process then process = _G.process end

-- Mock Counters
local overlapParamsNewCount = 0

-- Mock Data Structure
local MockInstance = {}
MockInstance.__index = MockInstance

function MockInstance.new(className, name)
    local self = setmetatable({
        ClassName = className,
        Name = name or className,
        Parent = nil,
        _children = {},
        _attributes = {},
        _tags = {},
    }, MockInstance)
    return self
end

function MockInstance:FindFirstChild(name)
    for _, child in ipairs(self._children) do
        if child.Name == name then
            return child
        end
    end
    return nil
end

function MockInstance:WaitForChild(name)
    local child = self:FindFirstChild(name)
    if not child then
        child = MockInstance.new("Folder", name)
        table.insert(self._children, child)
    end
    return child
end

function MockInstance:GetChildren()
    return self._children
end

-- Mock Roblox Services
local game = MockInstance.new("DataModel", "Game")
local Workspace = MockInstance.new("Workspace", "Workspace")
local ReplicatedStorage = MockInstance.new("ReplicatedStorage", "ReplicatedStorage")
local CollectionService = MockInstance.new("CollectionService", "CollectionService")

-- Connect Services
game._children = { Workspace, ReplicatedStorage, CollectionService }

function game:GetService(serviceName)
    for _, service in ipairs(self._children) do
        if service.Name == serviceName then
            return service
        end
    end
    -- Create if missing (lazy mock)
    local service = MockInstance.new(serviceName, serviceName)
    table.insert(self._children, service)
    return service
end

-- Mock Workspace Methods
function Workspace:GetPartBoundsInRadius(position, radius, params)
    -- Verify params are passed
    if not params then error("Missing params") end
    -- Return dummy result
    return {}
end

-- Mock CollectionService Methods
function CollectionService:HasTag(instance, tag)
    return instance._tags[tag] == true
end

-- Mock OverlapParams
local OverlapParams = {}
function OverlapParams.new()
    overlapParamsNewCount += 1
    return {
        FilterDescendantsInstances = {},
        FilterType = "Exclude",
        CollisionGroup = "Default",
        MaxParts = 0,
        RespectCanCollide = false
    }
end

-- Mock Enum
local Enum = {
    RaycastFilterType = {
        Exclude = "Exclude",
        Include = "Include"
    }
}

-- Setup Mock Environment
local mockEnv = {
    game = game,
    workspace = Workspace,
    OverlapParams = OverlapParams,
    Enum = Enum,
    Vector3 = {
        new = function(x, y, z) return {X=x, Y=y, Z=z} end,
        zero = {X=0, Y=0, Z=0}
    },
    tick = os.clock,
    print = print,
    warn = function(...) print("WARN:", ...) end,
    pairs = pairs,
    ipairs = ipairs,
    table = table,
    error = error,
    typeof = typeof,
    type = type,
    tostring = tostring,
    select = select,
    math = math,
}

-- Handle require mocking
local mockModules = {}

-- Setup CombatConfig Mock
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local combatConfigModule = configFolder:WaitForChild("CombatConfig")

mockModules[combatConfigModule] = {
    Targeting = { TargetTag = "Enemy" }
}

mockEnv.require = function(module)
    if mockModules[module] then
        return mockModules[module]
    end
    -- If it's a string (e.g. built-in modules), ignore or error?
    -- In Roblox, require takes a ModuleScript.
    -- If we are running locally, require takes a string path.
    -- We need to differentiate.
    if type(module) == "string" then
        return require(module) -- Fallback to lune/luau require
    end
    error("Module not mocked: " .. tostring(module.Name))
end


-- Load CombatLib
local fs = require("@lune/fs")

local function loadScript(path, env)
    local content = fs.readFile(path)
    local chunk, err = (loadstring or load)(content, path)
    if not chunk then error(err) end
    setfenv(chunk, env)
    return chunk()
end

print("Loading CombatLib...")
local CombatLib = loadScript("src/shared/Lib/CombatLib.luau", mockEnv)

-- Run Test
print("Running Performance Verification...")

-- Baseline Test: Call multiple times and check allocation count
local iterations = 100
overlapParamsNewCount = 0 -- Reset

for i = 1, iterations do
    CombatLib.getEnemiesInRadius(mockEnv.Vector3.zero, 10, {})
end

print("Called getEnemiesInRadius " .. iterations .. " times.")
print("OverlapParams.new() calls: " .. overlapParamsNewCount)

if overlapParamsNewCount == iterations then
    print("STATUS: UNOPTIMIZED")
elseif overlapParamsNewCount == 0 then
    print("STATUS: OPTIMIZED")
else
    print("STATUS: UNEXPECTED (" .. overlapParamsNewCount .. ")")
end

-- Functional Verification (Ensure it doesn't crash)
local success, err = pcall(function()
    CombatLib.getEnemiesInRadius(mockEnv.Vector3.zero, 10, {})
end)

if success then
    print("Functional Check: PASS")
else
    print("Functional Check: FAIL - " .. tostring(err))
    process.exit(1)
end
