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
function StatLib:GetStat(player: Player, statName: string, baseValue: number): number
	local finalValue = baseValue
	local additiveBonus = 0
	local multiplierBonus = 1
	
	-- Iterate through all possible items in config
	for itemKey, item in pairs(ItemRegistry.Pool) do
		local count = player:GetAttribute("Item_" .. itemKey) or 0
		if count > 0 and item.Effects then
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
