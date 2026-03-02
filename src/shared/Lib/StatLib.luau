--[[
    StatLib.luau
    Utility for calculating player stats with item modifiers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)
local MathUtil = require(ReplicatedStorage.Shared.Lib.MathUtil)

local StatLib = {}

-- Cache parsed inventories to avoid O(N) GetAttributes() allocation on every frame.
-- [Player] = { [ItemKey] = count }  — invalidated on any Item_ attribute change.
local inventoryCache: { [Player]: { [string]: number } } = {}
local cacheConnections: { [Player]: RBXScriptConnection } = {}

local function _getInventory(player: Player): { [string]: number }
	if inventoryCache[player] then
		return inventoryCache[player]
	end
	local inventory: { [string]: number } = {}
	for k, v in pairs(player:GetAttributes()) do
		if string.sub(k, 1, 5) == "Item_" then
			inventory[string.sub(k, 6)] = v
		end
	end
	inventoryCache[player] = inventory
	if not cacheConnections[player] then
		cacheConnections[player] = player.AttributeChanged:Connect(function(attr)
			if string.sub(attr, 1, 5) == "Item_" then
				inventoryCache[player] = nil
			end
		end)
	end
	return inventory
end

Players.PlayerRemoving:Connect(function(player)
	inventoryCache[player] = nil
	if cacheConnections[player] then
		cacheConnections[player]:Disconnect()
		cacheConnections[player] = nil
	end
end)

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
		-- OPTIMIZATION: Use cached inventory (invalidated on Item_ attribute change)
		-- Avoids O(N) GetAttributes() allocation on every stat recalculation.
		for itemKey, count in pairs(_getInventory(player)) do
			local item = ItemRegistry.Pool[itemKey]
			if item and item.Effects then
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
