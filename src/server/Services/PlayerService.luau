--[[
    PlayerService.luau
    Manages player lifecycle and character properties.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = require(ReplicatedStorage.Shared.Framework)

local PlayerService = Framework.CreateService({
	Name = "PlayerService",
})

function PlayerService:Start()
	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	-- Handle existing players
	for _, player in Players:GetPlayers() do
		self:OnPlayerAdded(player)
	end
end

function PlayerService:OnPlayerAdded(player)
	print("[PlayerService] Player joined:", player.Name)

	player.CharacterAdded:Connect(function(character)
		self:OnCharacterAdded(player, character)
	end)

	if player.Character then
		self:OnCharacterAdded(player, player.Character)
	end
end

function PlayerService:OnCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid then
		-- Set default humanoid properties
		humanoid.WalkSpeed = 18 -- Match MovementConfig
	end

	-- Remove spawn ForceField so enemies can deal damage immediately.
	-- Roblox's SpawnLocation grants a ForceField by default; TakeDamage() is
	-- silently blocked while one exists.
	for _, child in character:GetChildren() do
		if child:IsA("ForceField") then
			child:Destroy()
		end
	end
	character.ChildAdded:Connect(function(child)
		if child:IsA("ForceField") then
			child:Destroy()
		end
	end)
end

return PlayerService
