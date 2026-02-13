--[[
    Benchmark for ProcService optimization

    Scenario:
    - 1000 items in registry.
    - Player has 20 items.
    - Calculate proc checks 1000 times.
]]

local ItemRegistry = { Pool = {} }
-- Populate 1000 items
for i = 1, 1000 do
    local key = "Item" .. i
    ItemRegistry.Pool[key] = {
        Procs = {
            { Type = "OnHit", Chance = 0.1, Id = "TestProc" }
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
local playerInventory = {}
for i = 1, 20 do
    local key = "Item" .. math.random(1, 1000)
    Player._attributes["Item_" .. key] = 1
    playerInventory[key] = 1
end

-- Give player 50 non-item attributes
for i = 1, 50 do
    Player._attributes["OtherAttribute_" .. i] = true
end

-- Mock ItemService
local ItemService = {
    GetPlayerInventory = function(self, player)
        return playerInventory
    end
}

-- Current Implementation (Iterating Registry + Attribute Lookup)
local function ProcessHit_Current(attacker, target, damage, isCrit)
    local procsTriggered = 0
    for itemKey, item in pairs(ItemRegistry.Pool) do
        local count = attacker:GetAttribute("Item_" .. itemKey) or 0
        if count > 0 and item.Procs then
            for _, proc in pairs(item.Procs) do
                -- Logic would go here
                procsTriggered += 1
            end
        end
    end
    return procsTriggered
end

-- Optimized Implementation (Iterating Inventory directly)
local function ProcessHit_Optimized(attacker, target, damage, isCrit)
    local procsTriggered = 0
    local inventory = ItemService:GetPlayerInventory(attacker)

    for itemKey, count in pairs(inventory) do
        local item = ItemRegistry.Pool[itemKey]
        if item and item.Procs then
            for _, proc in pairs(item.Procs) do
                -- Logic would go here
                procsTriggered += 1
            end
        end
    end
    return procsTriggered
end

-- Benchmark
local iterations = 1000
local start = os.clock()
for i = 1, iterations do
    ProcessHit_Current(Player, nil, 10, false)
end
local timeCurrent = os.clock() - start
print(string.format("Current Implementation Time: %.6f", timeCurrent))

start = os.clock()
for i = 1, iterations do
    ProcessHit_Optimized(Player, nil, 10, false)
end
local timeOptimized = os.clock() - start
print(string.format("Optimized Implementation Time: %.6f", timeOptimized))

local improvement = timeCurrent / timeOptimized
print(string.format("Improvement Factor: %.2fx faster", improvement))
