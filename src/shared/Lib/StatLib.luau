--[[
    StatLib.luau
    Utility for calculating player stats with item modifiers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)

local StatLib = {}

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

	if inventory then
		-- OPTIMIZATION: Use provided inventory table directly (O(M) items)
		-- Avoids GetAttributes() allocation and string parsing
		for itemKey, count in pairs(inventory) do
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
	else
		-- FALLBACK: Iterate player attributes (O(N) attributes)
		-- This scales O(N) with player items instead of O(N) with total game items.
		local attributes = player:GetAttributes()
		for attributeName, value in pairs(attributes) do
			if string.sub(attributeName, 1, 5) == "Item_" then
				local itemKey = string.sub(attributeName, 6)
				local item = ItemRegistry.Pool[itemKey]

				if item and item.Effects then
					local count = value
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
		end
	end

	return (finalValue + additiveBonus) * multiplierBonus
end

return StatLib
