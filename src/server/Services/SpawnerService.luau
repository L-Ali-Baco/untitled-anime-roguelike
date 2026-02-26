--[[
    SpawnerService.luau
    Handles periodic spawning of enemies at designated spawn points.
    
    Responsibilities:
    - Track all objects tagged with 'EnemySpawnPoint'
    - Periodically spawn enemies if players are within range
    - Manage spawn point cooldowns
    - Automatically create test spawn points if none exist
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))

local SpawnerService = {
	Name = "SpawnerService",
}

-- References to other services
local EnemyService = require(script.Parent.EnemyService)
local MapService = require(script.Parent.MapService)

-- State
local spawnPoints = {} -- { [Instance]: { LastSpawnTime: number } }
local spawningEnabled = true -- toggled by /nospawn and /spawn commands
local updateAccumulator = 0
local SPAWN_CHECK_INTERVAL = 2.0 -- Check for spawns every 2 seconds

--[[
    Sync spawn points from MapService
]]
local function refreshSpawnPoints()
	if not MapService then
		return
	end

	local mapSpawns = MapService:GetEnemySpawns()

	-- Add new points
	for _, instance in mapSpawns do
		if not spawnPoints[instance] then
			spawnPoints[instance] = { LastSpawnTime = 0 }
		end
	end

	-- Remove invalid points
	for instance in spawnPoints do
		if not instance:IsDescendantOf(workspace) then
			spawnPoints[instance] = nil
		end
	end
end

--[[
    Check if a position falls within any player's forward FOV cone.
    Spawn points inside this cone are skipped so enemies don't visibly pop in front of the camera.
]]
local function isInPlayerFOV(position: Vector3): boolean
	local fovAngle = (EnemyConfig.Spawn and EnemyConfig.Spawn.FOVExclusionAngle) or 50
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and char.PrimaryPart then
			local rootCF = char.PrimaryPart.CFrame
			local toSpawn = position - rootCF.Position
			local flatToSpawn = Vector3.new(toSpawn.X, 0, toSpawn.Z)
			if flatToSpawn.Magnitude < 1 then
				continue
			end
			local lookFlat = Vector3.new(rootCF.LookVector.X, 0, rootCF.LookVector.Z)
			if lookFlat.Magnitude < 0.1 then
				continue
			end
			local dot = lookFlat.Unit:Dot(flatToSpawn.Unit)
			local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))
			if angle <= fovAngle then
				return true
			end
		end
	end
	return false
end

--[[
    Check if any player is in valid range of a position
]]
local function isInRange(position: Vector3): boolean
	local min = EnemyConfig.Spawn.MinSpawnDistance
	local max = EnemyConfig.Spawn.MaxSpawnDistance
	local anyInRange = false

	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and char.PrimaryPart then
			local dist = (char.PrimaryPart.Position - position).Magnitude
			if dist >= min and dist <= max then
				anyInRange = true
				break
			end
		end
	end

	return anyInRange
end

--[[
    Pick a random enemy type based on simple weights
]]
local function getRandomEnemyType(): string
	local types = { "Minion", "Minion", "Minion", "Brute", "Brute", "Shooter", "MossFrog" } -- ~43% Minion, 29% Brute, 14% Shooter, 14% MossFrog
	return types[math.random(#types)]
end

--[[
    Attempt to spawn an enemy at a specific point
]]
local function attemptSpawn(point: Instance)
	local data = spawnPoints[point]
	local now = tick()

	-- Check cooldown
	if now - data.LastSpawnTime < EnemyConfig.Spawn.RespawnDelay then
		return
	end

	-- Check player proximity
	local pos = (point:IsA("BasePart") and point.Position) or (point:IsA("Model") and point:GetPivot().Position)
	if not pos then
		return
	end

	if isInRange(pos) and not isInPlayerFOV(pos) then
		-- Check enemy cap
		if EnemyService:GetEnemyCount() >= EnemyConfig.AI.MaxActiveEnemies then
			return
		end

		-- Spawn!
		local enemyType = getRandomEnemyType()
		local success = EnemyService:SpawnEnemy(enemyType, pos + Vector3.new(0, 3, 0))

		if success then
			data.LastSpawnTime = now
			-- print("[SpawnerService] Spawned", enemyType, "at", point.Name)
		end
	end
end

--[[
    Create test spawn points if none exist
]]
local function createTestSpawnPoints()
	local tag = EnemyConfig.Spawn.SpawnTag
	if #CollectionService:GetTagged(tag) > 0 then
		return
	end

	print("[SpawnerService] No spawn points found, creating test points around world spawn...")

	-- Create 4 points in a circle around 0,0,0
	local radius = 40
	for i = 1, 4 do
		local angle = (i / 4) * math.pi * 2
		local pos = Vector3.new(math.cos(angle) * radius, 0.5, math.sin(angle) * radius)

		local part = Instance.new("Part")
		part.Name = "TestSpawnPoint_" .. i
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 0.8 -- Semi-visible for testing
		part.Color = Color3.fromRGB(255, 100, 100)
		part.Size = Vector3.new(4, 1, 4)
		part.Position = pos
		part.Parent = workspace

		CollectionService:AddTag(part, tag)
	end

	refreshSpawnPoints()
end

--[[
    Initialize the service
]]
function SpawnerService:Init()
	print("[SpawnerService] Initializing...")
end

--[[
    Start the service
]]
function SpawnerService:Start()
	-- Initial setup
	refreshSpawnPoints()
	-- MapService handles map loading, we just read from it

	-- Debug commands
	local function connectPlayerChat(player: Player)
		player.Chatted:Connect(function(msg)
			local cmd = string.lower(string.split(msg, " ")[1])
			if cmd == "/nospawn" then
				spawningEnabled = false
				print("[SpawnerService] Enemy spawning DISABLED")
			elseif cmd == "/spawn" then
				spawningEnabled = true
				print("[SpawnerService] Enemy spawning ENABLED")
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		connectPlayerChat(player)
	end
	Players.PlayerAdded:Connect(connectPlayerChat)

	-- Update loop
	RunService.Heartbeat:Connect(function(dt)
		updateAccumulator += dt
		if updateAccumulator >= SPAWN_CHECK_INTERVAL then
			updateAccumulator = 0

			refreshSpawnPoints()
			if spawningEnabled then
				for point in spawnPoints do
					attemptSpawn(point)
				end
			end
		end
	end)

	print("[SpawnerService] Started successfully")
end

return SpawnerService
