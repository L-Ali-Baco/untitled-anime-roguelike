local fs = require("@lune/fs")
local luau = require("@lune/luau")
local stdio = require("@lune/stdio")
local process = require("@lune/process")

-- ==============================================================================
-- 1. Mock Roblox Environment (For .spec.luau files)
-- ==============================================================================

local Instance = {}
Instance.__index = Instance

function Instance.new(className)
	local self = setmetatable({}, {
		__index = function(t, k)
			if Instance[k] then
				return Instance[k]
			end
			return t:_GetChild(k)
		end,
		__tostring = function(t)
			return t.Name
		end,
	})
	self.ClassName = className
	self.Name = className
	self.Parent = nil
	self._children = {}
	self._attributes = {}
	self._fsPath = nil
	return self
end

function Instance:_GetChild(name)
	if self._children[name] then
		return self._children[name]
	end

	if self._fsPath and fs.isDir(self._fsPath) then
		local scriptPath = self._fsPath .. "/" .. name .. ".luau"
		if fs.isFile(scriptPath) then
			local child = Instance.new("ModuleScript")
			child.Name = name
			child.Parent = self
			child._fsPath = scriptPath
			self._children[name] = child
			return child
		end

		local dirPath = self._fsPath .. "/" .. name
		if fs.isDir(dirPath) then
			local initPath = dirPath .. "/init.luau"
			local child
			if fs.isFile(initPath) then
				child = Instance.new("ModuleScript")
				child._fsPath = initPath
			else
				child = Instance.new("Folder")
				child._fsPath = dirPath
			end
			child.Name = name
			child.Parent = self
			self._children[name] = child
			return child
		end
	end
	return nil
end

function Instance:FindFirstChild(name)
	return self[name]
end
function Instance:WaitForChild(name)
	return self[name] or error("WaitForChild timed out for " .. name)
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
function Instance:IsA(className)
	return self.ClassName == className
end
function Instance:Clone()
	local clone = Instance.new(self.ClassName)
	clone.Name = self.Name
	for k, v in pairs(self._attributes) do
		clone._attributes[k] = v
	end
	return clone
end
function Instance:Destroy()
	if self.Parent then
		self.Parent._children[self.Name] = nil
		self.Parent = nil
	end
end

local game = Instance.new("DataModel")
local ReplicatedStorage = Instance.new("ReplicatedStorage")
local ServerScriptService = Instance.new("ServerScriptService")
local Players = Instance.new("Players")
local Workspace = Instance.new("Workspace")
local CollectionService = Instance.new("CollectionService")

game._children["ReplicatedStorage"] = ReplicatedStorage
game._children["ServerScriptService"] = ServerScriptService
game._children["Players"] = Players
game._children["Workspace"] = Workspace
game._children["CollectionService"] = CollectionService

function game:GetService(name)
	return self._children[name] or Instance.new(name)
end
function CollectionService:AddTag(inst, tag) end -- Mock
function CollectionService:HasTag(inst, tag)
	return false
end

-- Map Filesystem
local Shared = Instance.new("Folder")
Shared.Name = "Shared"
Shared.Parent = ReplicatedStorage
Shared._fsPath = "src/shared"
ReplicatedStorage._children["Shared"] = Shared

local Packages = Instance.new("Folder")
Packages.Name = "Packages"
Packages.Parent = ReplicatedStorage
Packages._fsPath = "Packages"
ReplicatedStorage._children["Packages"] = Packages

local Server = Instance.new("Folder")
Server.Name = "Server"
Server.Parent = ServerScriptService
Server._fsPath = "src/server"
ServerScriptService._children["Server"] = Server

-- Custom Require
local cache = {}
local function custom_require(module)
	if type(module) == "string" then
		return require(module)
	end
	if type(module) == "table" and module.ClassName == "ModuleScript" then
		if cache[module] then
			return cache[module]
		end
		if not module._fsPath then
			error("No source file for " .. module.Name)
		end

		local source = fs.readFile(module._fsPath)
		local env = setmetatable({
			script = module,
			require = custom_require,
			game = game,
			workspace = Workspace,
			Instance = Instance,
			Enum = { Material = { Plastic = 1 }, UserInputState = { Begin = 1 } },
			task = {
				wait = function() end,
				spawn = function(f)
					f()
				end,
				delay = function(_, f)
					f()
				end,
			},
			print = print,
			pairs = pairs,
			ipairs = ipairs,
			next = next,
			type = type,
			typeof = typeof,
			tostring = tostring,
			tonumber = tonumber,
			error = error,
			assert = assert,
			pcall = pcall,
			xpcall = xpcall,
			select = select,
			unpack = unpack,
			table = table,
			string = string,
			math = math,
			_G = _G,
		}, { __index = _G })

		local chunk, err = luau.load(source, { chunkname = module._fsPath, environment = env })
		if not chunk then
			error("Compile error " .. module.Name .. ": " .. err)
		end
		local result = chunk()
		cache[module] = result
		return result
	end
	error("Invalid require: " .. tostring(module))
end

-- Test Globals
local currentDescribe = ""
local totalPass, totalFail = 0, 0
local function describe(name, callback)
	local prev = currentDescribe
	currentDescribe = currentDescribe == "" and name or (currentDescribe .. " > " .. name)
	callback()
	currentDescribe = prev
end
local function it(name, callback)
	local fullName = currentDescribe .. " > " .. name
	local success, err = pcall(callback)
	if success then
		totalPass += 1
		print(stdio.color("green") .. "  ✓ " .. fullName .. stdio.color("reset"))
	else
		totalFail += 1
		print(stdio.color("red") .. "  ✕ " .. fullName .. stdio.color("reset"))
		print(stdio.color("red") .. "    " .. tostring(err) .. stdio.color("reset"))
	end
end
local Expectation = {}
Expectation.__index = Expectation
function Expectation.new(val)
	return setmetatable({ value = val, inverted = false }, Expectation)
end
function Expectation:equal(other)
	local match = self.value == other
	if self.inverted then
		match = not match
	end
	if not match then
		error(
			string.format(
				"Expected %s to %sequal %s",
				tostring(self.value),
				self.inverted and "NOT " or "",
				tostring(other)
			),
			2
		)
	end
end
function Expectation:be(val)
	self:equal(val)
end
function Expectation:near(other, tol)
	local match = math.abs(self.value - other) <= (tol or 1e-5)
	if self.inverted then
		match = not match
	end
	if not match then
		error(string.format("Expected %s to be near %s", tostring(self.value), tostring(other)), 2)
	end
end
function Expectation:__index(k)
	if Expectation[k] then
		return Expectation[k]
	end
	if k == "to" or k == "be" then
		return self
	end
	if k == "never" then
		self.inverted = not self.inverted
		return self
	end
	error("Unknown matcher: " .. k)
end
local function expect(val)
	return Expectation.new(val)
end

-- ==============================================================================
-- 2. Runner Logic
-- ==============================================================================

local function runSpec(path)
	print(stdio.color("cyan") .. "Running Spec: " .. path .. stdio.color("reset"))
	local source = fs.readFile(path)
	-- Explicit Mock Environment
	local env = {
		game = game,
		workspace = Workspace,
		Instance = Instance,
		require = custom_require,
		describe = describe,
		it = it,
		expect = expect,
		print = print,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		type = type,
		typeof = typeof,
		tostring = tostring,
		tonumber = tonumber,
		error = error,
		assert = assert,
		pcall = pcall,
		xpcall = xpcall,
		select = select,
		unpack = unpack,
		table = table,
		string = string,
		math = math,
		task = {
			wait = function() end,
			spawn = function(f)
				f()
			end,
			delay = function(_, f)
				f()
			end,
		},
		_G = _G,
	}

	local chunk, err = luau.load(source, { chunkname = path, environment = env })
	if not chunk then
		print(stdio.color("red") .. "Failed to load " .. path .. ": " .. err .. stdio.color("reset"))
		totalFail += 1
		return
	end

	local success, result = pcall(chunk)
	if not success then
		print(stdio.color("red") .. "Error executing " .. path .. ": " .. result .. stdio.color("reset"))
		totalFail += 1
		return
	end

	if type(result) == "function" then
		local innerSuccess, innerErr = pcall(result)
		if not innerSuccess then
			print(stdio.color("red") .. "Error in spec function " .. path .. ": " .. innerErr .. stdio.color("reset"))
			totalFail += 1
		end
	end
end

local function runStandaloneScript(path, filename)
	print(stdio.color("cyan") .. "Running Script (Subprocess): " .. path .. stdio.color("reset"))
	-- Run with lune in the tests directory to resolve relative paths
	local result = process.spawn("lune", { "run", filename }, {
		cwd = "tests",
		stdio = "inherit",
	})

	if result.ok then
		print(stdio.color("green") .. "  ✓ Script passed" .. stdio.color("reset"))
		totalPass += 1
	else
		print(
			stdio.color("red") .. "  ✕ Script failed with exit code " .. tostring(result.code) .. stdio.color("reset")
		)
		totalFail += 1
	end
end

local function findAndRun(dir)
	local items = fs.readDir(dir)
	for _, item in items do
		local fullPath = dir .. "/" .. item

		if fs.isFile(fullPath) then
			if item:match("%.spec%.luau$") then
				runSpec(fullPath)
			elseif item:match("^test_.*%.luau$") then
				-- Standard "test_*" files -> run independent
				runStandaloneScript(fullPath, item:gsub("%.luau$", ""))
			end
		elseif fs.isDir(fullPath) then
			findAndRun(fullPath)
		end
	end
end

print(stdio.style("bold") .. "Test Runner Starting..." .. stdio.color("reset"))
findAndRun("tests")

print(string.rep("-", 40))
print(string.format("Summary: %d Passed, %d Failed", totalPass, totalFail))

if totalFail > 0 then
	process.exit(1)
end
