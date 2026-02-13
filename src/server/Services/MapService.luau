--[[
    MapService.luau
    Server-side map management.
    Handles loading maps, finding spawn points, and cleanup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("Config"):WaitForChild("MapConfig"))

local MapService = {
	Name = "MapService",
}

-- Current active map
local currentMapModel = nil
local currentMapData = nil

-- Cached points
local enemySpawns = {}
local chestSpawns = {}
local playerSpawns = {}

--[[
    Clear the current map
]]
function MapService:ClearMap()
	if currentMapModel then
		currentMapModel:Destroy()
		currentMapModel = nil
	end

	enemySpawns = {}
	chestSpawns = {}
	playerSpawns = {}

	print("[MapService] Map cleared")
end

--[[
    Load a map by name
]]
function MapService:LoadMap(mapName: string)
	-- Clear existing
	self:ClearMap()

	-- Find map model
	local mapsFolder = ReplicatedStorage:FindFirstChild(MapConfig.StorageFolder)
	if not mapsFolder then
		-- Create folder if missing (Development convenience)
		mapsFolder = Instance.new("Folder")
		mapsFolder.Name = MapConfig.StorageFolder
		mapsFolder.Parent = ReplicatedStorage
		warn("[MapService] Created missing Maps folder in ReplicatedStorage")
	end

	local mapTemplate = mapsFolder:FindFirstChild(mapName)
	if not mapTemplate then
		warn("[MapService] Map not found:", mapName, "- Using placeholder baseplate")

		-- Create a dummy map if not found
		local dummyMap = Instance.new("Model")
		dummyMap.Name = "PlaceholderMap"

		local floor = Instance.new("Part")
		floor.Name = "Floor"
		floor.Size = Vector3.new(200, 1, 200)
		floor.Position = Vector3.new(0, -1, 0)
		floor.Anchored = true
		floor.Color = Color3.fromRGB(50, 50, 50)
		floor.Parent = dummyMap

		-- Add some spawn points
		for i = 1, 4 do
			local spawn = Instance.new("Part")
			spawn.Name = "EnemySpawn"
			spawn.Size = Vector3.new(2, 2, 2)
			spawn.Position = Vector3.new(math.random(-50, 50), 2, math.random(-50, 50))
			spawn.Anchored = true
			spawn.Transparency = 0.8
			spawn.CanCollide = false
			spawn.Color = Color3.fromRGB(255, 0, 0)
			CollectionService:AddTag(spawn, MapConfig.Tags.SpawnPoint)
			spawn.Parent = dummyMap
		end

		local pSpawn = Instance.new("Part")
		pSpawn.Name = "PlayerSpawn"
		pSpawn.Position = Vector3.new(0, 5, 0)
		pSpawn.Anchored = true
		pSpawn.Transparency = 1
		CollectionService:AddTag(pSpawn, MapConfig.Tags.PlayerSpawn)
		pSpawn.Parent = dummyMap

		currentMapModel = dummyMap
		currentMapModel.Parent = Workspace
	else
		-- Clone real map
		currentMapModel = mapTemplate:Clone()
		currentMapModel.Parent = Workspace
	end

	-- Cache points using CollectionService and Tags
	-- This assumes map creator tagged them correctly, OR named them correctly
	-- We support both Tag and Name for robustness
	for _, desc in currentMapModel:GetDescendants() do
		if desc:IsA("BasePart") then
			-- Enemy Spawns
			if CollectionService:HasTag(desc, MapConfig.Tags.SpawnPoint) or desc.Name == MapConfig.Tags.SpawnPoint then
				table.insert(enemySpawns, desc)
				desc.Transparency = 1 -- Hide spawners
			end

			-- Chest Spawns
			if CollectionService:HasTag(desc, MapConfig.Tags.ChestSpawn) or desc.Name == MapConfig.Tags.ChestSpawn then
				table.insert(chestSpawns, desc)
				desc.Transparency = 1
			end

			-- Player Spawns
			if
				CollectionService:HasTag(desc, MapConfig.Tags.PlayerSpawn)
				or desc.Name == MapConfig.Tags.PlayerSpawn
			then
				table.insert(playerSpawns, desc)
				desc.Transparency = 1
			end
		end
	end

	print("[MapService] Loaded", mapName, "- Enemy Spawns:", #enemySpawns)

	return currentMapModel
end

--[[
    Get a random enemy spawn point
]]
function MapService:GetRandomEnemySpawn(): Vector3
	if #enemySpawns > 0 then
		local part = enemySpawns[math.random(#enemySpawns)]
		return part.Position + Vector3.new(0, 2, 0)
	end

	-- Fallback: Random point around center
	local angle = math.random() * math.pi * 2
	local dist = math.random(30, 60)
	return Vector3.new(math.cos(angle) * dist, 2, math.sin(angle) * dist)
end

--[[
    Get all potential chest locations
]]
function MapService:GetChestSpawns(): { BasePart }
	return chestSpawns
end

--[[
    Get all enemy spawn points (for SpawnerService)
]]
function MapService:GetEnemySpawns(): { BasePart }
	return enemySpawns
end

--[[
    Get player spawn point
]]
function MapService:GetPlayerSpawn(): Vector3
	if #playerSpawns > 0 then
		return playerSpawns[math.random(#playerSpawns)].Position
	end
	return Vector3.new(0, 10, 0)
end

function MapService:Init()
	print("[MapService] Initialized")
end

function MapService:Start()
	-- Auto-load test map on start
	self:LoadMap("TestArena")
end

return MapService
