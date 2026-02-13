local stdio = require("@lune/stdio")
local process = require("@lune/process")

-- Minimal Test Framework
local function describe(name, callback)
	print(stdio.color("blue") .. "Describe: " .. name .. stdio.color("reset"))
	callback()
end

local function it(name, callback)
	local success, err = pcall(callback)
	if success then
		print(stdio.color("green") .. "  ✓ " .. name .. stdio.color("reset"))
	else
		print(stdio.color("red") .. "  ✕ " .. name .. stdio.color("reset"))
		print(stdio.color("red") .. "    Error: " .. tostring(err) .. stdio.color("reset"))
		error("Test failed: " .. name) -- Propagate error to fail the suite
	end
end

local function expect(value)
	return {
		to = {
			equal = function(expected)
				if value ~= expected then
					error(string.format("Expected %s to equal %s", tostring(value), tostring(expected)), 2)
				end
			end,
			never = {
				equal = function(expected)
					if value == expected then
						error(string.format("Expected %s to NOT equal %s", tostring(value), tostring(expected)), 2)
					end
				end
			},
			be = {
				ok = function()
					if not value then
						error(string.format("Expected %s to be truthy", tostring(value)), 2)
					end
				end,
				a = function(typeStr)
					if typeof(value) ~= typeStr then
						 error(string.format("Expected %s to be a %s", tostring(value), typeStr), 2)
					end
				end
			}
		}
	}
end

-- Expose globals
_G.describe = describe
_G.it = it
_G.expect = expect

-- Mocking Roblox Globals (Minimal implementation for CharacterLib)
local MockInstance = {}
MockInstance.__index = MockInstance

function MockInstance.new(className)
	local self = setmetatable({
		ClassName = className,
		Name = className,
		Parent = nil,
		_children = {},
		_attributes = {},
	}, MockInstance)

	-- Add specific properties based on ClassName
	if className == "Humanoid" then
		self.Health = 100
		self.MaxHealth = 100
	end

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

function MockInstance:FindFirstChildOfClass(className)
	for _, child in ipairs(self._children) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

function MockInstance:IsA(className)
	if self.ClassName == className then return true end
	if className == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart") then return true end
	if className == "Model" and self.ClassName == "Model" then return true end
	if className == "Humanoid" and self.ClassName == "Humanoid" then return true end
	return false
end

function MockInstance:GetAttribute(name)
	return self._attributes[name]
end

function MockInstance:SetAttribute(name, value)
	self._attributes[name] = value
end

function MockInstance:SetParent(parent)
    self.Parent = parent
    if parent then
        table.insert(parent._children, self)
    end
end

-- Helper to add child
function MockInstance:AddChild(child)
	table.insert(self._children, child)
	child.Parent = self
end

_G.Instance = MockInstance

-- Load the test file
-- Run
print("Running tests...")
local success, err = pcall(function()
	local spec = require("../src/shared/Lib/CharacterLib.spec")
	if type(spec) == "function" then
		spec({
			describe = describe,
			it = it,
			expect = expect,
			Instance = MockInstance
		})
	end
end)

if not success then
	print(stdio.color("red") .. "Test Suite Failed!" .. stdio.color("reset"))
	print(err)
	process.exit(1)
end

print(stdio.color("green") .. "All tests passed!" .. stdio.color("reset"))
