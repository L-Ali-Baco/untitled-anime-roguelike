--[[
    Server Bootstrapper
    Initializes and starts all server services via Framework.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = require(ReplicatedStorage.Shared.Framework)

print("[Server] Starting...")

--[[
    Recursively load all services from a folder
]]
local function loadServicesFromFolder(folder: Instance, path: string)
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") and child.Name:match("Service$") then
			local success, result = pcall(function()
				return require(child)
			end)

			if success then
				-- Support both self-registering services and legacy return-table services
				if type(result) == "table" and result.Name then
					if not Framework.Services[result.Name] then
						Framework.CreateService(result)
						print("[Server] Registered legacy service:", result.Name)
					end
				end
			else
				warn("[Server] Failed to load service:", child.Name, result)
			end
		elseif child:IsA("Folder") then
			loadServicesFromFolder(child, path .. "/" .. child.Name)
		end
	end
end

-- Load Services folder (main services location)
local servicesFolder = script:FindFirstChild("Services")
if servicesFolder then
	loadServicesFromFolder(servicesFolder, "Services")
end

-- Load Core services
local coreFolder = script:FindFirstChild("Core")
if coreFolder then
	loadServicesFromFolder(coreFolder, "Core")
end

-- Load Feature services
local featuresFolder = script:FindFirstChild("Features")
if featuresFolder then
	loadServicesFromFolder(featuresFolder, "Features")
end

-- Start the Framework
Framework.Start():catch(function(err)
	warn("[Server] Framework failed to start:", err)
end)
