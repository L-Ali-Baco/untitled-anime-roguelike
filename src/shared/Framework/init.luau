--[[
    Framework
    Lightweight game framework for organizing client/server code.
    Inspired by Knit.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(ReplicatedStorage.Packages.Promise)

-- Lazy load Networking to avoid potential circular dependency issues
local Networking = require(script.Networking)

local Framework = {}

Framework.RemoteSignal = require(script.RemoteSignal)
Framework.Services = {}
Framework.Controllers = {}
Framework.IsServer = RunService:IsServer()
Framework.IsClient = RunService:IsClient()

--[=[
    Creates a new Service (Server-side singleton).
    Automatically registers client methods for networking.
]=]
function Framework.CreateService(def)
	assert(Framework.IsServer, "Services can only be created on the server")
	assert(type(def) == "table", "Service definition must be a table")
	assert(type(def.Name) == "string", "Service must have a Name")

	if Framework.Services[def.Name] then
		error("Service \"" .. def.Name .. "\" already exists")
	end

	-- Initialize default lifecycle methods if missing
	def.Init = def.Init or function() end
	def.Start = def.Start or function() end

	Framework.Services[def.Name] = def

	-- Register with Networking if Client table exists
	if def.Client then
		Networking.RegisterService(def.Name, def)
	end

	return def
end

--[=[
    Creates a new Controller (Client-side singleton).
]=]
function Framework.CreateController(def)
	assert(Framework.IsClient, "Controllers can only be created on the client")
	assert(type(def) == "table", "Controller definition must be a table")
	assert(type(def.Name) == "string", "Controller must have a Name")

	if Framework.Controllers[def.Name] then
		error("Controller \"" .. def.Name .. "\" already exists")
	end

	-- Initialize default lifecycle methods if missing
	def.Init = def.Init or function() end
	def.Start = def.Start or function() end

	Framework.Controllers[def.Name] = def

	return def
end

--[=[
    Gets a Service by name.
    On Server: Returns the Service table directly.
    On Client: Returns a proxy object via Networking.
]=]
function Framework.GetService(serviceName)
	if Framework.IsServer then
		return Framework.Services[serviceName]
	else
		return Networking.GetService(serviceName)
	end
end

--[=[
    Gets a Controller by name (Client-side only).
]=]
function Framework.GetController(controllerName)
	return Framework.Controllers[controllerName]
end

--[=[
    Starts the Framework.
    1. Runs :Init() on all Services/Controllers.
    2. Runs :Start() on all Services/Controllers.
]=]
function Framework.Start()
	local promises = {}

	-- Phase 1: Init
	local modules = Framework.IsServer and Framework.Services or Framework.Controllers

	print(Framework.IsServer and "[Framework] Initializing Server..." or "[Framework] Initializing Client...")

	for name, module in pairs(modules) do
		if type(module.Init) == "function" then
			table.insert(promises, Promise.new(function(resolve, reject)
				local success, err = pcall(function()
					module:Init()
				end)
				if success then
					resolve()
				else
					reject(err)
				end
			end):catch(function(err)
				warn("Failed to Init " .. name .. ": " .. tostring(err))
			end))
		end
	end

	-- Wait for all Inits
	return Promise.all(promises):andThen(function()
		-- Phase 2: Start
		local startPromises = {}
		print(Framework.IsServer and "[Framework] Starting Services..." or "[Framework] Starting Controllers...")

		for name, module in pairs(modules) do
			if type(module.Start) == "function" then
				table.insert(startPromises, Promise.new(function(resolve, reject)
					task.spawn(function()
						local success, err = pcall(function()
							module:Start()
						end)
						if success then
							resolve()
						else
							reject(err)
						end
					end)
				end):catch(function(err)
					warn("Failed to Start " .. name .. ": " .. tostring(err))
				end))
			end
		end

		return Promise.all(startPromises)
	end):andThen(function()
		print(Framework.IsServer and "[Framework] Started Successfully" or "[Framework] Started Successfully")
	end)
end

return Framework
