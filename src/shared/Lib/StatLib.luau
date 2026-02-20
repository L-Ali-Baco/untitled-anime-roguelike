--[[
    StatLib.luau
    Utility for calculating player stats with item modifiers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)

local StatLib = {}

-- Cache parsed inventories to avoid O(N) allocation/parsing on every frame
-- [Player] = { [ItemKey] = count }
local inventoryCache = {}
-- [Player] = Connection
local connections = {}

--[[
    Internal helper to get or create cached inventory for a player
]]
local function _getInventory(player: Player): { [string]: number }
	-- Only cache for Players to avoid memory leaks with NPCs/Models or issues with non-Instances
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		local inventory = {}
		local attributes = player:GetAttributes()
		for k, v in pairs(attributes) do
			if string.sub(k, 1, 5) == "Item_" then
				inventory[string.sub(k, 6)] = v
			end
		end
		return inventory
	end

	if inventoryCache[player] then
		return inventoryCache[player]
	end

	local inventory = {}
	local attributes = player:GetAttributes()
	for k, v in pairs(attributes) do
		if string.sub(k, 1, 5) == "Item_" then
			inventory[string.sub(k, 6)] = v
		end
	end

	inventoryCache[player] = inventory

	-- Setup listener if not already tracking this player
	if not connections[player] then
		connections[player] = player.AttributeChanged:Connect(function(attributeName)
			if string.sub(attributeName, 1, 5) == "Item_" then
				inventoryCache[player] = nil -- Invalidate cache
			end
		end)
	end

	return inventory
end

-- Cleanup when player leaves
Players.PlayerRemoving:Connect(function(player)
	inventoryCache[player] = nil
	if connections[player] then
		connections[player]:Disconnect()
		connections[player] = nil
	end
end)

--[[
    Get the modified value of a specific stat based on player items.
]]
function StatLib:GetStat(
	player: Player,
	statName: string,
	baseValue: number,
	inventory: { [string]: number }?
): number
	local finalValue = baseValue
	local additiveBonus = 0
	local multiplierBonus = 1

	-- Use provided inventory or fetch/cache it
	-- OPTIMIZATION: Cached inventory avoids O(N) GetAttributes() allocation and loop
	local usedInventory = inventory or _getInventory(player)

	for itemKey, count in pairs(usedInventory) do
		local item = ItemRegistry.Pool[itemKey]

		if item and item.Effects then
			for _, effect in pairs(item.Effects) do
				if effect.Stat == statName then
					if effect.Type == "Additive" then
						additiveBonus += effect.Value * count
					elseif effect.Type == "Multiplier" then
						multiplierBonus += effect.Value * count
					end
				end
			end
		end
	end

	return (finalValue + additiveBonus) * multiplierBonus
end

return StatLib
