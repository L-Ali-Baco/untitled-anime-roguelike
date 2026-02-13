--[[
    tests/mock_env.luau
    Mock Roblox environment for testing StatLib in Lune.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local MockEnv = {}

-- Basic Instance Mock
local Instance = {}
Instance.__index = Instance

function Instance.new(className)
    local self = setmetatable({}, Instance)
    self.ClassName = className
    self.Name = className
    self._attributes = {}
    self._children = {}
    return self
end

function Instance:GetAttributes()
    return self._attributes
end

function Instance:GetAttribute(name)
    return self._attributes[name]
end

function Instance:SetAttribute(name, value)
    self._attributes[name] = value
end

function Instance:GetService(serviceName)
    if serviceName == "Players" then
        return _G.game.Players
    elseif serviceName == "ReplicatedStorage" then
        return _G.game.ReplicatedStorage
    end
    error("Service not mocked: " .. serviceName)
end

function Instance:WaitForChild(name)
    return self[name] or error("Child not found: " .. name)
end

-- Module Loader
local moduleRegistry = {}

local function loadModule(path)
    if not fs.isFile(path) then
        error("File not found: " .. path)
    end
    local content = fs.readFile(path)
    -- Compile and run
    local chunk = luau.load(content, { chunkname = path, environment = _G })
    return chunk()
end

-- Mock Color3
local Color3 = {}
function Color3.fromRGB(r, g, b)
    return { r = r, g = g, b = b }
end
function Color3.new(r, g, b)
    return { r = r, g = g, b = b }
end
_G.Color3 = Color3

-- Mock Require
local original_require = require
_G.require = function(target)
    if type(target) == "string" then
        return original_require(target)
    elseif type(target) == "table" and target.ClassName == "ModuleScript" then
        if moduleRegistry[target] then
            if target._cachedResult then
                return target._cachedResult
            end
            local path = moduleRegistry[target]
            local result = loadModule(path)
            target._cachedResult = result
            return result
        else
            error("ModuleScript not registered in mock: " .. (target.Name or "Unknown"))
        end
    else
        error("Invalid require target: " .. tostring(target))
    end
end

-- Setup Game and Hierarchy
function MockEnv.setup()
    _G.game = Instance.new("DataModel")
    _G.game.Players = Instance.new("Players")

    local ReplicatedStorage = Instance.new("ReplicatedStorage")
    _G.game.ReplicatedStorage = ReplicatedStorage

    local Shared = Instance.new("Folder")
    Shared.Name = "Shared"
    ReplicatedStorage.Shared = Shared

    local Config = Instance.new("Folder")
    Config.Name = "Config"
    Shared.Config = Config

    -- Mock ItemRegistry
    local ItemRegistry = Instance.new("ModuleScript")
    ItemRegistry.Name = "ItemRegistry"
    Config.ItemRegistry = ItemRegistry

    -- Register Module Path
    moduleRegistry[ItemRegistry] = "src/shared/Config/ItemRegistry.luau"

    -- Expose classes
    _G.Instance = Instance

    return _G.game
end

-- Load the System Under Test (SUT)
function MockEnv.loadStatLib()
    return loadModule("src/shared/Lib/StatLib.luau")
end

return MockEnv
