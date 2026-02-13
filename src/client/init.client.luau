--[[
    Client Bootstrapper
    Initializes and starts all client controllers via Framework.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = require(ReplicatedStorage.Shared.Framework)

local LocalPlayer = Players.LocalPlayer

-- Wait for essential services
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

print("[Client] Starting...")

--[[
    Recursively load all controllers from a folder
]]
local function loadControllersFromFolder(folder: Instance, path: string)
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") and child.Name:match("Controller$") then
			local success, result = pcall(function()
				return require(child)
			end)

			if success then
				-- Support both self-registering controllers and legacy return-table controllers
				if type(result) == "table" and result.Name then
					if not Framework.Controllers[result.Name] then
						Framework.CreateController(result)
						print("[Client] Registered legacy controller:", result.Name)
					end
				end
			else
				warn("[Client] Failed to load controller:", child.Name, result)
			end
		elseif child:IsA("Folder") then
			loadControllersFromFolder(child, path .. "/" .. child.Name)
		end
	end
end

-- Load Core controllers
local coreFolder = script:WaitForChild("Core")
loadControllersFromFolder(coreFolder, "Core")

-- Load Feature controllers
local featuresFolder = script:WaitForChild("Features")
loadControllersFromFolder(featuresFolder, "Features")

-- Load VFX controllers
local vfxFolder = script:WaitForChild("VFX")
loadControllersFromFolder(vfxFolder, "VFX")

-- Load Main controllers (including UIController)
local controllersFolder = script:FindFirstChild("Controllers")
if controllersFolder then
	loadControllersFromFolder(controllersFolder, "Controllers")
end

-- Start the Framework
Framework.Start():catch(function(err)
	warn("[Client] Framework failed to start:", err)
end)
