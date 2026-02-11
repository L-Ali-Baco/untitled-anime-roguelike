--[[
    PhysicsService.luau
    Manages collision groups and physics interactions.
    
    Responsibilities:
    - Set up collision groups (Players, Enemies, DashingPlayers)
    - Configure collision rules (DashingPlayers ignore Enemies)
    - Handle group switching for dashing players
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local PhysicsManager = {
	Name = "PhysicsService",
}

-- Group Names
local GROUPS = {
	Players = "Players",
	Enemies = "Enemies",
	DashingPlayers = "DashingPlayers",
}

--[[
    Apply a collision group to an entire model
]]
function PhysicsManager:SetModelCollisionGroup(model: Model, groupName: string)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end

--[[
    Initialize collision groups and rules
]]
function PhysicsManager:Init()
	-- Register groups
	for _, name in GROUPS do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
	end

	-- Configure Rules:
	-- 1. DashingPlayers ignore Enemies
	PhysicsService:CollisionGroupSetCollidable(GROUPS.DashingPlayers, GROUPS.Enemies, false)
	
	-- 2. DashingPlayers still collide with default (environment)
	PhysicsService:CollisionGroupSetCollidable(GROUPS.DashingPlayers, "Default", true)
	
	-- 3. Players and Enemies collide normally
	PhysicsService:CollisionGroupSetCollidable(GROUPS.Players, GROUPS.Enemies, true)

	print("[PhysicsService] Collision groups initialized")
end

--[[
    Start listening for state changes
]]
function PhysicsManager:Start()
	-- Listen for I-frame changes (which happen during dash)
	local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
	if iframeRemote then
		iframeRemote.OnServerEvent:Connect(function(player: Player, isDashing: boolean)
			local character = player.Character
			if not character then return end

			if isDashing then
				self:SetModelCollisionGroup(character, GROUPS.DashingPlayers)
			else
				self:SetModelCollisionGroup(character, GROUPS.Players)
			end
		end)
	end

	-- Handle character spawning
	local function onCharacterAdded(character: Model)
		self:SetModelCollisionGroup(character, GROUPS.Players)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(onCharacterAdded)
	end)

	for _, player in Players:GetPlayers() do
		if player.Character then
			onCharacterAdded(player.Character)
		end
		player.CharacterAdded:Connect(onCharacterAdded)
	end
end

return PhysicsManager
