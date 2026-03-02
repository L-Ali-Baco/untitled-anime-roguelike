--[[
    BeaconService.luau
    Server-side objective management.
    Handles charging beacons and triggering waves.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local WorldConfig = require(Shared:WaitForChild("Config"):WaitForChild("WorldConfig"))

local BeaconService = {
	Name = "BeaconService",
}

-- States
local State = {
	Inactive = "Inactive",
	Charging = "Charging",
	Completed = "Completed",
}

-- Active beacons data
-- { [Instance]: { Progress: number, State: string, LastSpawn: number } }
local activeBeacons = {}

-- References
local EnemyService = nil

--[[
    Check if any player is within range of a position
]]
local function getPlayersInRange(position: Vector3, radius: number): { Player }
	local inRange = {}
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and char.PrimaryPart then
			local dist = (char.PrimaryPart.Position - position).Magnitude
			if dist <= radius then
				table.insert(inRange, player)
			end
		end
	end
	return inRange
end

--[[
    Handle a beacon completing
]]
local function completeBeacon(instance: Instance)
	local data = activeBeacons[instance]
	data.State = State.Completed
	data.Progress = 100

	-- Notify clients
	local stateRemote = Remotes:GetEvent("BeaconStateChanged")
	if stateRemote then
		stateRemote:FireAllClients(instance, State.Completed)
	end

	print("[BeaconService] Beacon COMPLETED:", instance.Name)

	-- Visual feedback
	if instance:IsA("BasePart") then
		instance.Color = WorldConfig.Beacon.CompletedColor
	end

	-- Spawn Loot Chest
	local ItemService = require(script.Parent.ItemService)
	local pos = (instance:IsA("BasePart") and instance.Position)
		or (instance:IsA("Model") and instance:GetPivot().Position)
	if pos and ItemService then
		ItemService:SpawnChest(pos)
	end
end

--[[
    Initialize a beacon instance
]]
function BeaconService:RegisterBeacon(instance: Instance)
	if activeBeacons[instance] then
		return
	end

	activeBeacons[instance] = {
		Progress = 0,
		State = State.Inactive,
		LastSpawn = 0,
		LastProgressUpdate = 0, -- For network throttling
	}

	-- Setup visuals if part
	if instance:IsA("BasePart") then
		instance.Color = WorldConfig.Beacon.ActiveColor
		instance.Transparency = 0.5
		instance.CanCollide = false
		instance.Anchored = true
	end

	print("[BeaconService] Registered beacon:", instance.Name)
end

--[[
    Main update loop
]]
local function onHeartbeat(dt: number)
	local config = WorldConfig.Beacon

	for instance, data in activeBeacons do
		if data.State == State.Completed then
			continue
		end

		local pos = (instance:IsA("BasePart") and instance.Position)
			or (instance:IsA("Model") and instance:GetPivot().Position)
		if not pos then
			continue
		end

		local players = getPlayersInRange(pos, config.ChargeRadius)
		local hasPlayers = #players > 0
		local oldState = data.State

		-- Update Progress
		if hasPlayers then
			data.State = State.Charging
			local chargeDelta = (dt / config.ChargeTime) * 100
			data.Progress = math.min(100, data.Progress + chargeDelta)

			-- Handle Spawning
			local now = os.clock()
			if now - data.LastSpawn >= config.SpawnIntervalDuringCharge then
				data.LastSpawn = now
				if EnemyService then
					-- Spawn enemy near players but not exactly on them
					local player = players[math.random(#players)]
					local offset = Vector3.new(math.random(-20, 20), 0, math.random(-20, 20))
					EnemyService:SpawnEnemy("Minion", player.Character.PrimaryPart.Position + offset)
				end
			end
		else
			data.State = State.Inactive
			local drainDelta = (dt / config.ChargeTime) * 100 * config.LoseProgressRate
			data.Progress = math.max(0, data.Progress - drainDelta)
		end

		-- Broadcast updates
		if data.State ~= oldState then
			local stateRemote = Remotes:GetEvent("BeaconStateChanged")
			if stateRemote then
				stateRemote:FireAllClients(instance, data.State)
			end

			-- Update visual color
			if instance:IsA("BasePart") then
				instance.Color = (data.State == State.Charging) and config.ChargingColor or config.ActiveColor
			end
		end

		-- Update Progress Remote (Throttled to ~10Hz or on significant change)
		local now = os.clock()
		if now - data.LastProgressUpdate >= 0.1 then
			data.LastProgressUpdate = now
			local progressRemote = Remotes:GetEvent("BeaconProgressUpdated")
			if progressRemote then
				progressRemote:FireAllClients(instance, data.Progress)
			end
		end

		-- Check completion
		if data.Progress >= 100 then
			completeBeacon(instance)
		end
	end
end

--[[
    Create a test beacon
]]
local function createTestBeacon()
	local tag = WorldConfig.Beacon.Tag
	if #CollectionService:GetTagged(tag) > 0 then
		return
	end

	print("[BeaconService] Creating test beacon...")
	local part = Instance.new("Part")
	part.Name = "ObjectiveBeacon"
	part.Size = Vector3.new(WorldConfig.Beacon.ChargeRadius * 2, 1, WorldConfig.Beacon.ChargeRadius * 2)
	part.Shape = Enum.PartType.Cylinder
	part.Rotation = Vector3.new(0, 0, 90)
	part.Position = Vector3.new(0, 0.5, 0)
	part.Parent = workspace

	CollectionService:AddTag(part, tag)
end

function BeaconService:Init()
	print("[BeaconService] Initializing...")
end

function BeaconService:Start()
	EnemyService = require(script.Parent.EnemyService)

	-- Find existing
	for _, instance in CollectionService:GetTagged(WorldConfig.Beacon.Tag) do
		self:RegisterBeacon(instance)
	end

	-- Listen for new
	CollectionService:GetInstanceAddedSignal(WorldConfig.Beacon.Tag):Connect(function(ins)
		self:RegisterBeacon(ins)
	end)

	createTestBeacon()
	RunService.Heartbeat:Connect(onHeartbeat)

	print("[BeaconService] Started")
end

return BeaconService
