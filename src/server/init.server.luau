--[[
    Server Bootstrapper
    Initializes and starts all server services.
    
    Services are loaded in two phases:
    1. Init - Setup, can reference other services but not use them
    2. Start - All services ready, safe to use each other
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

print("[Server] Starting...")

-- Store all services
local services = {}

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
				local name = result.Name or child.Name
				services[name] = result
				print("[Server] Loaded service:", name)
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

-- Phase 1: Init all services
print("[Server] Initializing services...")
for name, service in services do
	if service.Init then
		local success, err = pcall(function()
			service:Init()
		end)

		if not success then
			warn("[Server] Failed to init service:", name, err)
		end
	end
end

-- Phase 2: Start all services
print("[Server] Starting services...")
for name, service in services do
	if service.Start then
		task.spawn(function()
			local success, err = pcall(function()
				service:Start()
			end)

			if not success then
				warn("[Server] Failed to start service:", name, err)
			end
		end)
	end
end

-- Handle player joining
local function onPlayerAdded(player: Player)
	print("[Server] Player joined:", player.Name)

	-- Character handling
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			-- Set default humanoid properties
			humanoid.WalkSpeed = 18 -- Match our MovementConfig
		end
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

-- Connect player events
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[Server] Bootstrap complete!")

-- Tag training dummy for combat system
local function tagTrainingDummies()
	-- Find and tag all training dummies in workspace
	for _, obj in workspace:GetChildren() do
		if obj.Name == "TrainingDummy" and obj:FindFirstChildOfClass("Humanoid") then
			CollectionService:AddTag(obj, "TrainingDummy")
			CollectionService:AddTag(obj, "Enemy") -- Also tag as enemy for targeting
			
			-- Apply collision group
			for _, part in obj:GetDescendants() do
				if part:IsA("BasePart") then
					part.CollisionGroup = "Enemies"
				end
			end
			
			print("[Server] Tagged TrainingDummy:", obj:GetFullName())

			local humanoid = obj:FindFirstChildOfClass("Humanoid")
			if humanoid then
				-- Reset health immediately when it hits 0 (instant respawn)
				humanoid.Died:Connect(function()
					task.wait(0.5) -- Brief delay so death registers
					humanoid.Health = humanoid.MaxHealth
					print("[Server] Reset TrainingDummy health")
				end)

				-- Also reset health after taking damage (if not dead)
				-- This lets you keep testing combos without waiting
				local lastDamageTime = 0
				humanoid.HealthChanged:Connect(function(newHealth)
					if newHealth < humanoid.MaxHealth and newHealth > 0 then
						lastDamageTime = tick()
						local capturedTime = lastDamageTime

						-- Reset health after 2 seconds of no damage
						task.delay(2, function()
							if lastDamageTime == capturedTime and humanoid.Health > 0 then
								humanoid.Health = humanoid.MaxHealth
								print("[Server] Reset TrainingDummy health (regen)")
							end
						end)
					end
				end)
			end
		end
	end
end

-- Run after workspace loads
task.defer(tagTrainingDummies)
