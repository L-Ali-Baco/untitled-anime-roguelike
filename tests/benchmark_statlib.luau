--[[
    Benchmark for StatLib optimization

    To run this benchmark, you need a Luau runtime (e.g. `lune` or `luau`).
    Since the environment lacks one, this script serves as documentation of the optimization logic.

    Scenario:
    - 1000 items in registry.
    - Player has 20 items.
    - Calculate a stat 1000 times.
]]

local ItemRegistry = { Pool = {} }
-- Populate 1000 items
for i = 1, 1000 do
    local key = "Item" .. i
    ItemRegistry.Pool[key] = {
        Effects = {
            { Stat = "Damage", Value = 0.1, Type = "Multiplier" }
        }
    }
end

local Player = {
    _attributes = {},
    GetAttribute = function(self, name)
        return self._attributes[name]
    end,
    GetAttributes = function(self)
        -- Simulate returning a copy
        local copy = {}
        for k, v in pairs(self._attributes) do
            copy[k] = v
        end
        return copy
    end
}

-- Give player 20 random items
for i = 1, 20 do
    local key = "Item" .. math.random(1, 1000)
    Player._attributes["Item_" .. key] = 1
end

-- Give player 50 non-item attributes
for i = 1, 50 do
    Player._attributes["OtherAttribute_" .. i] = true
end

-- Current Implementation
local function GetStat_Current(player, statName, baseValue)
    local finalValue = baseValue
    local additiveBonus = 0
    local multiplierBonus = 1

    for itemKey, item in pairs(ItemRegistry.Pool) do
        local count = player:GetAttribute("Item_" .. itemKey) or 0
        if count > 0 and item.Effects then
            for _, effect in pairs(item.Effects) do
                if effect.Stat == statName then
                    if effect.Type == "Additive" then
                        additiveBonus = additiveBonus + effect.Value * count
                    elseif effect.Type == "Multiplier" then
                        multiplierBonus = multiplierBonus + effect.Value * count
                    end
                end
            end
        end
    end

    return (finalValue + additiveBonus) * multiplierBonus
end

-- Optimized Implementation
local function GetStat_Optimized(player, statName, baseValue)
    local finalValue = baseValue
    local additiveBonus = 0
    local multiplierBonus = 1

    local attributes = player:GetAttributes()
    for name, value in pairs(attributes) do
        if string.sub(name, 1, 5) == "Item_" then
            local itemKey = string.sub(name, 6)
            local item = ItemRegistry.Pool[itemKey]

            if item and item.Effects then
                local count = value
                for _, effect in pairs(item.Effects) do
                    if effect.Stat == statName then
                        if effect.Type == "Additive" then
                            additiveBonus = additiveBonus + effect.Value * count
                        elseif effect.Type == "Multiplier" then
                            multiplierBonus = multiplierBonus + effect.Value * count
                        end
                    end
                end
            end
        end
    end

    return (finalValue + additiveBonus) * multiplierBonus
end

-- Benchmark
local start = os.clock()
for i = 1, 1000 do
    GetStat_Current(Player, "Damage", 100)
end
print("Current Implementation Time: " .. (os.clock() - start))

start = os.clock()
for i = 1, 1000 do
    GetStat_Optimized(Player, "Damage", 100)
end
print("Optimized Implementation Time: " .. (os.clock() - start))
