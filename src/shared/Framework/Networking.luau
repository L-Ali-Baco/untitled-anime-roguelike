--[[
    Networking.luau
    Handles client-server communication for the Framework.

    Server: Creates Remotes for Services.
    Client: Creates Proxies for Services.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(ReplicatedStorage.Packages.Promise)

local Networking = {}

Networking.RemoteFolder = nil
Networking.ServiceRemotes = {}

--[=[
    Server: Initializes networking for a service.
    Create RemoteFunction/RemoteEvent for each Client:Method.
]=]
function Networking.RegisterService(serviceName, serviceDef)
	if not RunService:IsServer() then return end

	local remoteFolder = Networking.GetRemoteFolder()
	local serviceFolder = Instance.new("Folder")
	serviceFolder.Name = serviceName
	serviceFolder.Parent = remoteFolder

	-- If the service has a `Client` table, expose its methods
	if serviceDef.Client then
		for methodName, method in pairs(serviceDef.Client) do
			if type(method) == "function" then
				-- By default, treat as RemoteFunction for simplicity?
				-- Or maybe define specific types? For now, let's use RemoteFunction for calls with return values
				-- and RemoteEvent for void calls.
				-- Or just expose everything as RemoteFunction for ease of use? RemoteFunctions are synchronous which can block.
				-- Better: Use a naming convention or explicit definition.
				-- Let's stick to simple: If name starts with "On", it's an Event (Server->Client or Client->Server signal).
				-- If name starts with "Get" or implies a return, it's a Function.

				-- Actually, Knit uses a specific `Client` table where functions are RemoteFunctions
				-- and signals are RemoteEvents.
				-- Let's just use RemoteFunctions for now as they are most versatile,
				-- but warn about yielding.
				-- Or better: A specific naming convention or configuration.

				-- For this implementation, let's use a "Method" approach:
				-- Client calls specific methods on the Service.

				local remoteFunc = Instance.new("RemoteFunction")
				remoteFunc.Name = methodName
				remoteFunc.Parent = serviceFolder

				remoteFunc.OnServerInvoke = function(player, ...)
					return method(serviceDef.Client, player, ...)
				end
			elseif type(method) == "table" and method.ClassName == "RemoteSignal" then
				-- TODO: Handle Signals
			end
		end
	end
end

--[=[
    Client: Returns a proxy for a service on the server.
]=]
function Networking.GetService(serviceName)
	if not RunService:IsClient() then return nil end

	local serviceFolder = Networking.GetRemoteFolder():WaitForChild(serviceName, 10)
	if not serviceFolder then
		warn("Service \"" .. serviceName .. "\" not found or timed out.")
		return nil
	end

	local serviceProxy = {}

	-- Populate proxy with methods from RemoteFunctions
	for _, child in ipairs(serviceFolder:GetChildren()) do
		if child:IsA("RemoteFunction") then
			serviceProxy[child.Name] = function(self, ...)
				return child:InvokeServer(...)
			end
			-- Add Promise version
			serviceProxy[child.Name .. "Promise"] = function(self, ...)
				local args = {...}
				return Promise.new(function(resolve, reject)
					local success, result = pcall(function()
						return child:InvokeServer(unpack(args))
					end)
					if success then
						resolve(result)
					else
						reject(result)
					end
				end)
			end
		elseif child:IsA("RemoteEvent") then
			-- Events (Signals)
			serviceProxy[child.Name] = child -- Allow direct connection
		end
	end

	return serviceProxy
end

--[=[
    Gets or creates the main Remote folder in ReplicatedStorage.
]=]
function Networking.GetRemoteFolder()
	if Networking.RemoteFolder then return Networking.RemoteFolder end

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild("FrameworkRemotes")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "FrameworkRemotes"
			folder.Parent = ReplicatedStorage
		end
		Networking.RemoteFolder = folder
	else
		Networking.RemoteFolder = ReplicatedStorage:WaitForChild("FrameworkRemotes", 10)
	end

	return Networking.RemoteFolder
end

return Networking
