-- tests/verify_remote_signal.luau
local fs = require("@lune/fs")
local process = require("@lune/process")

-- ============================================================================
-- MOCK ENVIRONMENT
-- ============================================================================

-- Mock Promise
local MockPromise = {
	new = function(executor)
		local resolve = function(...) end
		local reject = function(...) end
		if executor then executor(resolve, reject) end
		return {
			andThen = function() return MockPromise.new(function() end) end,
			catch = function() return MockPromise.new(function() end) end
		}
	end,
	all = function() return MockPromise.new(function() end) end
}

-- Mock Instance
local InstanceMethods = {}
function InstanceMethods:FindFirstChild(n)
	for _, child in ipairs(self._children or {}) do
		if child.Name == n then return child end
	end
	return nil
end
function InstanceMethods:WaitForChild(n) return self:FindFirstChild(n) end
function InstanceMethods:GetChildren() return self._children or {} end
function InstanceMethods:IsA(className) return self.ClassName == className end
function InstanceMethods:Destroy() self.Parent = nil end
function InstanceMethods:FireClient(player, ...)
	-- Record call
	table.insert(self._calls, {Method="FireClient", Player=player, Args={...}})
end
function InstanceMethods:FireAllClients(...)
	table.insert(self._calls, {Method="FireAllClients", Args={...}})
end

local function createMockInstance(className, name)
	local storage = {
		ClassName = className,
		Name = name or className,
		Parent = nil,
		_children = {},
		_calls = {}, -- To record method calls
		OnServerEvent = {
			Connect = function(_, fn) return { Connected = true, Disconnect = function() end } end,
			Wait = function() end
		},
		OnClientEvent = {
			Connect = function(_, fn) return { Connected = true, Disconnect = function() end } end,
			Wait = function() end
		}
	}

	local proxy = {}
	local mt = {
		__index = function(t, k)
			if InstanceMethods[k] then return InstanceMethods[k] end
			if storage[k] ~= nil then return storage[k] end

			-- Try to find child by name
			for _, child in ipairs(storage._children) do
				if child.Name == k then return child end
			end
			return nil
		end,
		__newindex = function(t, k, v)
			if k == "Parent" then
				local oldParent = storage.Parent
				if oldParent and oldParent._children then
					for i, child in ipairs(oldParent._children) do
						if child == t then
							table.remove(oldParent._children, i)
							break
						end
					end
				end
				storage.Parent = v
				if v then
					if not v._children then v._children = {} end
					table.insert(v._children, t)
				end
			else
				storage[k] = v
			end
		end
	}
	return setmetatable(proxy, mt)
end

-- Mock Game Services
local Services = {}
Services.ReplicatedStorage = createMockInstance("Folder", "ReplicatedStorage")
Services.RunService = { IsServer = function() return true end, IsClient = function() return false end }
Services.Players = createMockInstance("Players", "Players")

local game = {
	GetService = function(_, name)
		if Services[name] then return Services[name] end
		return createMockInstance("Service", name)
	end
}

-- Setup ReplicatedStorage structure for requires
local Packages = createMockInstance("Folder", "Packages")
Packages.Parent = Services.ReplicatedStorage
local PromiseModule = createMockInstance("ModuleScript", "Promise")
PromiseModule.Parent = Packages

-- Custom Require
local loadedModules = {}
local function customRequire(module)
	if module == PromiseModule then
		return MockPromise
	end

	if type(module) == "string" then
		return require(module)
	end

	-- If it's a mock instance (ModuleScript)
	if type(module) == "table" and module.ClassName == "ModuleScript" then
		-- If we have a mapped file path for this module, load it
		if module._path then
			if loadedModules[module._path] then return loadedModules[module._path] end
			local chunk = loadScript(module._path)
			loadedModules[module._path] = chunk
			return chunk
		end
	end

	error("Cannot require module: " .. tostring(module))
end


-- Loader with environment
function loadScript(path)
	local content = fs.readFile(path)

	local env = {
		game = game,
		Instance = { new = createMockInstance },
		require = customRequire,
		script = createMockInstance("ModuleScript", "Script"), -- Mock script
		print = print,
		warn = warn,
		error = error,
		pairs = pairs,
		ipairs = ipairs,
		type = type,
		table = table,
		setmetatable = setmetatable,
		tostring = tostring,
		assert = assert,
	}

	local chunk, err = (loadstring or load)(content, "=" .. path)
	if not chunk then error(err) end
	setfenv(chunk, env)
	return chunk()
end

-- ============================================================================
-- TEST LOGIC
-- ============================================================================

local function loadNetworking()
	local content = fs.readFile("src/shared/Framework/Networking.luau")

	local networkingScript = createMockInstance("ModuleScript", "Networking")

	local env = {
		game = game,
		Instance = { new = createMockInstance },
		require = customRequire,
		script = networkingScript,
		print = print,
		warn = warn,
		error = error,
		pairs = pairs,
		ipairs = ipairs,
		type = type,
		table = table,
		setmetatable = setmetatable,
		tostring = tostring,
		assert = assert,
	}

	local chunk = (loadstring or load)(content, "src/shared/Framework/Networking.luau")
	setfenv(chunk, env)
	return chunk()
end

local function loadRemoteSignal()
	local content = fs.readFile("src/shared/Framework/RemoteSignal.luau")
	local env = {
		game = game,
		Instance = { new = createMockInstance },
		require = customRequire,
		script = createMockInstance("ModuleScript", "RemoteSignal"),
		print = print,
		warn = warn,
		error = error,
		pairs = pairs,
		ipairs = ipairs,
		type = type,
		table = table,
		setmetatable = setmetatable,
		tostring = tostring,
		assert = assert,
	}
	local chunk = (loadstring or load)(content, "src/shared/Framework/RemoteSignal.luau")
	setfenv(chunk, env)
	return chunk()
end

print("Loading modules...")
local Networking = loadNetworking()
local RemoteSignal = loadRemoteSignal()
print("Modules loaded.")

-- Test 1: Register Service with RemoteSignal
print("Test 1: Register Service with RemoteSignal")

local TestService = {
	Client = {
		MySignal = RemoteSignal.new()
	}
}

Networking.RegisterService("TestService", TestService)

-- Verify RemoteEvent created
local remoteFolder = Services.ReplicatedStorage:FindFirstChild("FrameworkRemotes")
if not remoteFolder then error("FrameworkRemotes folder not found") end

local serviceFolder = remoteFolder:FindFirstChild("TestService")
if not serviceFolder then error("TestService folder not found") end

local remoteEvent = serviceFolder:FindFirstChild("MySignal")
if not remoteEvent then error("MySignal RemoteEvent not found") end

if remoteEvent.ClassName ~= "RemoteEvent" then error("MySignal is not a RemoteEvent") end

-- Verify RemoteSignal connected
local signal = TestService.Client.MySignal
if not signal._remote then error("RemoteSignal _remote not set") end
if signal._remote ~= remoteEvent then error("RemoteSignal linked to wrong remote") end

print("Test 2: Fire Signal")
-- Fire signal
local player = createMockInstance("Player", "TestPlayer")
signal:Fire(player, "Hello", 123)

-- Check calls
if #remoteEvent._calls ~= 1 then error("Expected 1 call to RemoteEvent, got " .. #remoteEvent._calls) end
local call = remoteEvent._calls[1]
if call.Method ~= "FireClient" then error("Expected FireClient call") end
if call.Player ~= player then error("Wrong player passed") end
if call.Args[1] ~= "Hello" or call.Args[2] ~= 123 then error("Wrong args passed") end

print("Test 3: Connect Signal")
-- Test Connect (Server side)
local connected = false
signal:Connect(function() connected = true end)
-- Just verify it didn't error.

print("SUCCESS: All tests passed.")
