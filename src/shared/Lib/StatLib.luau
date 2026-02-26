--[[
    StatLib.luau
    Utility for calculating player stats with item modifiers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)
local MathUtil = require(ReplicatedStorage.Shared.Lib.MathUtil)

local StatLib = {}

-- Hard caps applied after all item math resolves.
-- Prevents additive stats from exceeding physically meaningful values.
local STAT_CAPS: { [string]: { min: number?, max: number? } } = {
	CritChance = { min = 0, max = 1 }, -- probability: never above 100%
	MaxHealth = { min = 1 }, -- never zero or negative HP
	WalkSpeed = { max = 100 }, -- engine starts clipping at extreme speeds
	AttackRate = { min = 0.05 }, -- avoid divide-by-zero in attack timing
}

--[[
    Get the modified value of a specific stat based on player items.
    Formula: (baseValue + sum(additive*stacks)) * (1 + sum(multiplier*stacks))
    Multiplier bonus is floored at 0.01 so negative-multiplier items (GlassCannon)
    cannot produce negative or zero stat values even when stacked multiple times.
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
						elseif effect.Type == "Hyperbolic" then
							-- Returns the *total* bonus at this stack count (not per-stack).
							-- Cap defaults to 5× the base value if not specified in the item.
							local cap = effect.Cap or (effect.Value * 5)
							additiveBonus += MathUtil.HyperbolicScale(count, effect.Value, cap)
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
							elseif effect.Type == "Hyperbolic" then
								local cap = effect.Cap or (effect.Value * 5)
								additiveBonus += MathUtil.HyperbolicScale(count, effect.Value, cap)
							end
						end
					end
				end
			end
		end
	end

	-- Safety floor: multiplierBonus must never go negative (e.g. 2× GlassCannon = -0.8×)
	multiplierBonus = math.max(0.01, multiplierBonus)

	local result = (finalValue + additiveBonus) * multiplierBonus

	-- Apply per-stat caps
	local cap = STAT_CAPS[statName]
	if cap then
		if cap.min then
			result = math.max(cap.min, result)
		end
		if cap.max then
			result = math.min(cap.max, result)
		end
	end

	return result
end

return StatLib
