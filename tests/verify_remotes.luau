--[[
    tests/verify_remotes.luau
    Verification script for Remotes module.
    Tests:
    - InitServer (idempotency, duplicate folder prevention)
    - Remote creation
    - GetFolder
    - GetEvent
]]

local fs = require("@lune/fs")

-- ============================================================================
-- MOCK ENVIRONMENT
-- ============================================================================

local InstanceMethods = {}
function InstanceMethods:FindFirstChild(n)
	for _, child in ipairs(self._children) do
		if child.Name == n then return child end
	end
	return nil
end
function InstanceMethods:WaitForChild(n)
	return self:FindFirstChild(n)
end
function InstanceMethods:GetChildren()
	return self._children
end

local function createMockInstanceRefined(className, name)
	local storage = {
		ClassName = className,
		Name = name or className,
		Parent = nil,
		_children = {}, -- Array of children
	}

	local proxy = {}
	local mt = {
		__index = function(t, k)
			if InstanceMethods[k] then return InstanceMethods[k] end
			return storage[k]
		end,
		__newindex = function(t, k, v)
			if k == "Parent" then
				local oldParent = storage.Parent
				if oldParent then
					-- Remove from old parent
					for i, child in ipairs(oldParent._children) do
						if child == t then
							table.remove(oldParent._children, i)
							break
						end
					end
				end

				storage.Parent = v

				if v then
					-- Add to new parent
					table.insert(v._children, t)
				end
			elseif k == "Name" then
				storage.Name = v
			else
				storage[k] = v
			end
		end
	}

	return setmetatable(proxy, mt)
end


local game = createMockInstanceRefined("DataModel", "Game")
local ReplicatedStorage = createMockInstanceRefined("ReplicatedStorage", "ReplicatedStorage")
ReplicatedStorage.Parent = game

local RunService = {
	IsServer = function() return true end
}

local function GetService(self, name)
	if name == "ReplicatedStorage" then return ReplicatedStorage end
	if name == "RunService" then return RunService end
	return createMockInstanceRefined("Service", name)
end

game.GetService = GetService

-- Mock Instance.new
local function Instance_new(className)
	return createMockInstanceRefined(className)
end


-- GLOBALS
local _G_ENV = {
	game = game,
	Instance = { new = Instance_new },
	print = print,
	pairs = pairs,
	ipairs = ipairs,
	table = table,
}

-- Loader
local function loadScript(path)
	local content = fs.readFile(path)
	local env = setmetatable({}, { __index = _G_ENV })
	local chunk, err = (loadstring or load)(content, path)
	if not chunk then error(err) end
	setfenv(chunk, env)
	return chunk()
end

-- ============================================================================
-- TEST LOGIC
-- ============================================================================

local function assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(msg or string.format("Expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

print("Loading Remotes module...")
local Remotes = loadScript("src/shared/Remotes.luau")

print("Test 1: InitServer creates folder correctly")
local folder1 = Remotes:InitServer()

assertEqual(folder1.Name, "Remotes", "Folder name incorrect")
assertEqual(folder1.Parent, ReplicatedStorage, "Folder parent incorrect")

-- Check existence of some known remotes
local requestAttack = folder1:FindFirstChild("RequestAttack")
if not requestAttack then error("Missing RequestAttack remote") end
assertEqual(requestAttack.ClassName, "RemoteEvent", "RequestAttack should be RemoteEvent")


print("Test 2: InitServer handles existing folder (Idempotency)")
local folder2 = Remotes:InitServer()

-- Check that only ONE folder exists
local count = 0
for _, child in ipairs(ReplicatedStorage:GetChildren()) do
	if child.Name == "Remotes" then
		count = count + 1
	end
end

assertEqual(count, 1, "Duplicate Remotes folders found!")
assertEqual(folder1, folder2, "InitServer returned different folder object")


print("Test 3: GetEvent works")
local event = Remotes:GetEvent("RequestAttack")
if not event then error("GetEvent returned nil") end
assertEqual(event.Name, "RequestAttack", "GetEvent name mismatch")


print("Test 4: GetFolder works")
local gotFolder = Remotes:GetFolder()
assertEqual(gotFolder, folder1, "GetFolder returned incorrect object")


print("SUCCESS: All tests passed.")
