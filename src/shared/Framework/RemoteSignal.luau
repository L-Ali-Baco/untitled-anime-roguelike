--[[
    RemoteSignal.luau
    Wrapper for RemoteEvents to be used within the Framework Services.
]]

local RunService = game:GetService("RunService")

local RemoteSignal = {}
RemoteSignal.__index = RemoteSignal
RemoteSignal.ClassName = "RemoteSignal"

function RemoteSignal.new()
	local self = setmetatable({
		_remote = nil,
	}, RemoteSignal)
	return self
end

function RemoteSignal:Connect(fn)
	if not self._remote then
		error("RemoteSignal:Connect() called before remote assigned. Ensure you are calling this after Framework.Start() or in Init/Start.")
	end

	if RunService:IsServer() then
		return self._remote.OnServerEvent:Connect(fn)
	else
		return self._remote.OnClientEvent:Connect(fn)
	end
end

function RemoteSignal:Fire(player, ...)
	if not self._remote then return end
	if RunService:IsServer() then
		self._remote:FireClient(player, ...)
	else
		error("RemoteSignal:Fire() can only be called on the server")
	end
end

function RemoteSignal:FireAll(...)
	if not self._remote then return end
	if RunService:IsServer() then
		self._remote:FireAllClients(...)
	else
		error("RemoteSignal:FireAll() can only be called on the server")
	end
end

function RemoteSignal:FireServer(...)
	if not self._remote then return end
	if RunService:IsClient() then
		self._remote:FireServer(...)
	else
		error("RemoteSignal:FireServer() can only be called on the client")
	end
end

function RemoteSignal:Wait()
	if not self._remote then return end
	if RunService:IsServer() then
		return self._remote.OnServerEvent:Wait()
	else
		return self._remote.OnClientEvent:Wait()
	end
end

-- Internal use by Networking.RegisterService
function RemoteSignal:_SetRemote(remote)
	self._remote = remote
end

function RemoteSignal:Destroy()
	if self._remote then
		self._remote:Destroy()
		self._remote = nil
	end
end

return RemoteSignal
