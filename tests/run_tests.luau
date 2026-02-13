local fs = require("@lune/fs")
local process = require("@lune/process")
local luau = require("@lune/luau")

-- ==========================================
-- 1. Mock Roblox Environment
-- ==========================================

local Instance = {}
-- Methods are stored in Instance table, but we use a custom __index for child lookup

function Instance.new(className)
	local self = {
		ClassName = className,
		Name = className,
		Parent = nil,
		_children = {},
		_attributes = {}
	}

	setmetatable(self, {
		__index = function(t, k)
			-- 1. Check for method/property in Instance class
			if Instance[k] then
				return Instance[k]
			end
			-- 2. Check for child
			local children = rawget(t, "_children")
			if children and children[k] then
				return children[k]
			end
			return nil
		end
	})

	return self
end

function Instance:GetAttributes()
	return self._attributes
end

function Instance:SetAttribute(name, value)
	self._attributes[name] = value
end

function Instance:GetAttribute(name)
	return self._attributes[name]
end

function Instance:FindFirstChild(name)
	return self._children[name]
end

function Instance:WaitForChild(name)
    return self._children[name]
end

function Instance:AddChild(name, child)
	child.Name = name
	child.Parent = self
	self._children[name] = child
	return child
end

local game = Instance.new("DataModel")
local ReplicatedStorage = Instance.new("ReplicatedStorage")
local Players = Instance.new("Players")

game:AddChild("ReplicatedStorage", ReplicatedStorage)
game:AddChild("Players", Players)

local function GetService(self, name)
	if name == "ReplicatedStorage" then return ReplicatedStorage end
	if name == "Players" then return Players end
	return Instance.new(name)
end

game.GetService = GetService

-- ==========================================
-- 2. TinyTest Framework
-- ==========================================

local currentDescribe = ""
local failures = 0
local passes = 0

local function describe(name, callback)
	local oldDescribe = currentDescribe
	currentDescribe = currentDescribe == "" and name or (currentDescribe .. " " .. name)
	print("\nDescribe: " .. currentDescribe)
	callback()
	currentDescribe = oldDescribe
end

local function it(name, callback)
	local fullName = currentDescribe .. " " .. name
	local status, err = pcall(callback)
	if status then
		passes = passes + 1
		print("  [PASS] " .. name)
	else
		failures = failures + 1
		print("  [FAIL] " .. name)
		print("    Error: " .. tostring(err))
	end
end

local Expectation = {}
-- Matchers defined on the class table

function Expectation.new(value)
	local self = { value = value }

	local mt = {
		__index = function(t, k)
			-- Syntactic sugar / chaining words (properties that return self)
			if k == "to" or k == "be" or k == "at" or k == "is" or k == "should" then
				return t
			end

			-- Matchers (methods bound to self)
			if Expectation[k] then
				return function(...)
					return Expectation[k](t, ...)
				end
			end

			error("Unknown matcher or property: " .. tostring(k))
		end
	}

	setmetatable(self, mt)
	return self
end

function Expectation.equal(self, other)
	if self.value ~= other then
		error(string.format("Expected %s to equal %s", tostring(self.value), tostring(other)), 2)
	end
end

function Expectation.near(self, other, tolerance)
    if math.abs(self.value - other) > tolerance then
        error(string.format("Expected %s to be near %s (tolerance %s)", tostring(self.value), tostring(other), tostring(tolerance)), 2)
    end
end

function Expectation.least(self, limit)
    if self.value < limit then error("Expected " .. tostring(self.value) .. " to be at least " .. tostring(limit)) end
end

function Expectation.ok(self)
    if not self.value then error("Expected value to be truthy") end
end

local function expect(value)
	return Expectation.new(value)
end

-- ==========================================
-- 3. Module Loader & Path Mapping
-- ==========================================

-- Map mocked instances to file paths
local modulePaths = {}

-- Setup ReplicatedStorage structure
local Shared = Instance.new("Folder")
ReplicatedStorage:AddChild("Shared", Shared)

local Config = Instance.new("Folder")
Shared:AddChild("Config", Config)

local Lib = Instance.new("Folder")
Shared:AddChild("Lib", Lib)

-- Mock Items
local ItemRegistryModule = Instance.new("ModuleScript")
Config:AddChild("ItemRegistry", ItemRegistryModule)
modulePaths[ItemRegistryModule] = "src/shared/Config/ItemRegistry.luau"

local StatLibModule = Instance.new("ModuleScript")
Lib:AddChild("StatLib", StatLibModule)
modulePaths[StatLibModule] = "src/shared/Lib/StatLib.luau"

-- Custom Require
local loadedModules = {}

-- Forward declaration
local custom_require

custom_require = function(module)
	if typeof(module) == "table" and module.ClassName == "ModuleScript" then
		if loadedModules[module] then
			return loadedModules[module]
		end

		local path = modulePaths[module]
		if not path then
			error("No source path mapped for module: " .. module.Name)
		end

		local source = fs.readFile(path)

		-- Create sandbox environment
		local env = setmetatable({}, { __index = _G })
		env.script = module
		env.require = custom_require
        env.game = game
        env.Instance = Instance
        env.expect = expect -- Just in case

		local chunk, err = luau.load(source, {
			environment = env,
			chunkname = path
		})

		if not chunk then
			error("Failed to compile " .. path .. ": " .. err)
		end

		local result = chunk()
		loadedModules[module] = result
		return result
	end

	-- Fallback to standard require for string paths (system libs)
	return require(module)
end

-- ==========================================
-- 4. Run Test Spec
-- ==========================================

-- We load the spec file manually and run it with the test framework globals
local specSource = fs.readFile("tests/StatLib.spec.luau")

local env = setmetatable({}, { __index = _G })
env.describe = describe
env.it = it
env.expect = expect
env.game = game
env.Instance = Instance
env.require = custom_require

local chunk, err = luau.load(specSource, {
	environment = env,
	chunkname = "tests/StatLib.spec.luau"
})

if not chunk then
	error("Failed to compile spec: " .. err)
end

print("Running Tests...")
local specFunc = chunk()
if type(specFunc) == "function" then
    specFunc()
end

print(string.format("\nResults: %d Passed, %d Failed", passes, failures))

if failures > 0 then
	process.exit(1)
end
