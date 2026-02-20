--[[
    tests/verify_statlib.luau
    Standalone test runner for StatLib logic.

    Run with lune:
    lune run tests/verify_statlib
]]

local fs = require("@lune/fs")

-- ============================================================================
-- MOCK ENVIRONMENT
-- ============================================================================

local MockInstances = {}
local MockModules = {}

local function createMockInstance(className, name)
	local self = {
		ClassName = className,
		Name = name or className,
		Parent = nil,
		_children = {},
		_attributes = {},
	}

    local mt = {
        __index = function(t, k)
            -- Check if key exists in 'self' (methods)
            if rawget(t, k) then return rawget(t, k) end

            -- Check children
            if t._children[k] then
                return t._children[k]
            end

            return nil
        end
    }
    setmetatable(self, mt)

	function self:FindFirstChild(n)
		return self._children[n]
	end

    function self:GetChildren()
        local children = {}
        for _, child in pairs(self._children) do
            table.insert(children, child)
        end
        return children
    end

	function self:GetAttribute(n)
		return self._attributes[n]
	end

	function self:SetAttribute(n, v)
		self._attributes[n] = v
	end

	function self:GetAttributes()
		return self._attributes
	end

    function self:GetService(serviceName)
        if self._children[serviceName] then
            return self._children[serviceName]
        end
        -- Auto-create if not exists for simplicity in some cases
        local s = createMockInstance(serviceName, serviceName)
        self._children[serviceName] = s
        return s
    end

    function self:WaitForChild(n)
        if self._children[n] then
            return self._children[n]
        end
        -- Create dummy if strictly needed, or error?
        -- For now, let's create it to prevent blocks
        local s = createMockInstance("Folder", n)
        self._children[n] = s
        return s
    end

	return self
end

-- Global Mocks
local game = createMockInstance("DataModel", "Game")

local ReplicatedStorage = createMockInstance("ReplicatedStorage", "ReplicatedStorage")
game._children["ReplicatedStorage"] = ReplicatedStorage
ReplicatedStorage.Parent = game

local Players = createMockInstance("Players", "Players")
game._children["Players"] = Players

-- Setup Folder Structure for require paths
local Shared = createMockInstance("Folder", "Shared")
ReplicatedStorage._children["Shared"] = Shared

local ConfigFolder = createMockInstance("Folder", "Config")
Shared._children["Config"] = ConfigFolder

local ItemRegistryModule = createMockInstance("ModuleScript", "ItemRegistry")
ConfigFolder._children["ItemRegistry"] = ItemRegistryModule

-- Mock Color3
local Color3 = {
    fromRGB = function(r, g, b)
        return { R = r, G = g, B = b }
    end,
    new = function(r, g, b)
        return { R = r, G = g, B = b }
    end
}

-- Mock ItemRegistry Content
local MockItemRegistry = {
    Pool = {
        -- Additive Bonus Item
        TestSword = {
            Name = "Test Sword",
            Effects = {
                { Stat = "Damage", Value = 10, Type = "Additive" },
            },
        },
        -- Multiplier Bonus Item
        TestAmulet = {
            Name = "Test Amulet",
            Effects = {
                { Stat = "Damage", Value = 0.5, Type = "Multiplier" }, -- +50%
            },
        },
        -- Mixed Effects Item
        TestMixed = {
            Name = "Test Mixed",
            Effects = {
                { Stat = "Health", Value = 100, Type = "Additive" },
                { Stat = "Health", Value = 0.1, Type = "Multiplier" },
            },
        },
        -- No Effects Item
        TestEmpty = {
            Name = "Test Empty",
            Effects = {},
        },
        -- Negative Effects (Cursed)
        TestCursed = {
            Name = "Test Cursed",
            Effects = {
                { Stat = "Speed", Value = -5, Type = "Additive" },
            },
        },
    }
}
MockModules[ItemRegistryModule] = MockItemRegistry

-- GLOBALS
local _G = {
	game = game,
	Instance = { new = function(c) return createMockInstance(c) end },
	Color3 = Color3,
	math = math,
	print = print,
	table = table,
    pairs = pairs,
    ipairs = ipairs,
    string = string,
}

-- Global require interceptor
local function mockRequire(module)
	if MockModules[module] then
		return MockModules[module]
	end
    -- Fallback for string requires if any (not used in StatLib but good practice)
    if type(module) == "string" then
        return require(module)
    end
	error("Module not mocked: " .. tostring(module.Name))
end

-- ============================================================================
-- TEST RUNNER (Simple)
-- ============================================================================

local passCount = 0
local failCount = 0

local function runTest(name, func)
    local success, err = pcall(func)
    if success then
        print("✅ [PASS] " .. name)
        passCount = passCount + 1
    else
        print("❌ [FAIL] " .. name)
        print("    Error: " .. tostring(err))
        failCount = failCount + 1
    end
end

local function assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(msg or string.format("Expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

-- ============================================================================
-- LOAD StatLib
-- ============================================================================

local function loadScript(path, env)
	local content = fs.readFile(path)
	local newEnv = setmetatable({}, { __index = _G })
	for k,v in pairs(env or {}) do newEnv[k] = v end
	newEnv.require = mockRequire

	local chunk, err = (loadstring or load)(content, path)
	if not chunk then error(err) end
	setfenv(chunk, newEnv)
	return chunk
end

print("Loading StatLib...")
local StatLibChunk = loadScript("src/shared/Lib/StatLib.luau")
local StatLib = StatLibChunk()

if not StatLib then
    error("Failed to load StatLib module")
end

-- ============================================================================
-- TESTS
-- ============================================================================

print("\nStarting Tests for StatLib...")

runTest("GetStat returns base value with no inventory/attributes", function()
    local player = createMockInstance("Player")
    local result = StatLib:GetStat(player, "Damage", 100, nil)
    assertEqual(result, 100)
end)

runTest("GetStat uses optimized inventory path (Additive)", function()
    local player = createMockInstance("Player")
    local inventory = { ["TestSword"] = 1 } -- +10 Additive
    local result = StatLib:GetStat(player, "Damage", 100, inventory)
    -- Base 100 + 10 = 110. Multiplier is 1.
    assertEqual(result, 110)
end)

runTest("GetStat uses optimized inventory path (Multiplier)", function()
    local player = createMockInstance("Player")
    local inventory = { ["TestAmulet"] = 1 } -- +50% Multiplier (0.5)
    local result = StatLib:GetStat(player, "Damage", 100, inventory)
    -- Base 100 + 0 = 100. Multiplier is 1 + 0.5 = 1.5.
    -- Result = 100 * 1.5 = 150
    assertEqual(result, 150)
end)

runTest("GetStat combines Additive and Multiplier correctly", function()
    local player = createMockInstance("Player")
    local inventory = {
        ["TestSword"] = 1,  -- +10 Additive
        ["TestAmulet"] = 1  -- +0.5 Multiplier
    }
    local result = StatLib:GetStat(player, "Damage", 100, inventory)
    -- Base 100 + 10 = 110.
    -- Multiplier 1 + 0.5 = 1.5.
    -- Result = 110 * 1.5 = 165.
    assertEqual(result, 165)
end)

runTest("GetStat handles item stacking", function()
    local player = createMockInstance("Player")
    local inventory = {
        ["TestSword"] = 2,  -- +20 Additive
    }
    local result = StatLib:GetStat(player, "Damage", 100, inventory)
    assertEqual(result, 120)
end)

runTest("GetStat handles unknown items gracefully", function()
    local player = createMockInstance("Player")
    local inventory = {
        ["UnknownItem"] = 5,
    }
    local result = StatLib:GetStat(player, "Damage", 100, inventory)
    assertEqual(result, 100)
end)

runTest("GetStat fallback to attributes (Additive)", function()
    local player = createMockInstance("Player")
    player:SetAttribute("Item_TestSword", 1) -- +10 Additive

    local result = StatLib:GetStat(player, "Damage", 100, nil)
    assertEqual(result, 110)
end)

runTest("GetStat fallback to attributes (Multiplier)", function()
    local player = createMockInstance("Player")
    player:SetAttribute("Item_TestAmulet", 1) -- +0.5 Multiplier

    local result = StatLib:GetStat(player, "Damage", 100, nil)
    assertEqual(result, 150)
end)

runTest("GetStat fallback ignores non-item attributes", function()
    local player = createMockInstance("Player")
    player:SetAttribute("OtherAttribute", 100)

    local result = StatLib:GetStat(player, "Damage", 100, nil)
    assertEqual(result, 100)
end)

runTest("GetStat fallback handles multiple item attributes", function()
    local player = createMockInstance("Player")
    player:SetAttribute("Item_TestSword", 1) -- +10
    player:SetAttribute("Item_TestAmulet", 1) -- +0.5x

    local result = StatLib:GetStat(player, "Damage", 100, nil)
    assertEqual(result, 165)
end)

runTest("GetStat handles negative additive values", function()
    local player = createMockInstance("Player")
    local inventory = { ["TestCursed"] = 1 } -- -5 Speed
    local result = StatLib:GetStat(player, "Speed", 20, inventory)
    assertEqual(result, 15)
end)

-- ============================================================================
-- SUMMARY
-- ============================================================================

print("--------------------------------------------------")
print("Results: " .. passCount .. " Passed, " .. failCount .. " Failed")

if failCount > 0 then
    -- Exit with error code
    if process and process.exit then
        process.exit(1)
    else
        os.exit(1)
    end
end
