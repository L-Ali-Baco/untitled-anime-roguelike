--[[
    Verification Script for StatLib Caching

    This script outlines the logic to verify that StatLib correctly caches player inventories
    and invalidates them on attribute changes.

    Usage (conceptual):
    1. Mock `game`, `Players`, `ReplicatedStorage`.
    2. Require `StatLib`.
    3. Run the following test case.
]]

local function runTest(StatLib)
    print("Starting StatLib Cache Verification...")

    -- 1. Setup Mock Player
    local player = {
        _attributes = {},
        _listeners = {},
        GetAttributesCallCount = 0,

        IsA = function(self, class) return class == "Player" end,

        GetAttributes = function(self)
            self.GetAttributesCallCount = self.GetAttributesCallCount + 1
            local t = {}
            for k,v in pairs(self._attributes) do t[k] = v end
            return t
        end,

        SetAttribute = function(self, k, v)
            self._attributes[k] = v
            for _, cb in ipairs(self._listeners) do
                cb(k)
            end
        end,

        AttributeChanged = {
            Connect = function(_, callback)
                table.insert(player._listeners, callback)
                return { Disconnect = function() end }
            end
        }
    }

    -- Setup initial state
    player:SetAttribute("Item_Sword", 1)

    -- 2. First Call - Should fetch attributes
    local val1 = StatLib:GetStat(player, "Damage", 10)
    if player.GetAttributesCallCount ~= 1 then
        error("FAIL: Expected 1 GetAttributes call, got " .. player.GetAttributesCallCount)
    end
    print("PASS: First call fetched attributes.")

    -- 3. Second Call - Should use cache
    local val2 = StatLib:GetStat(player, "Damage", 10)
    if player.GetAttributesCallCount ~= 1 then
        error("FAIL: Expected 1 GetAttributes call (cached), got " .. player.GetAttributesCallCount)
    end
    print("PASS: Second call used cache.")

    -- 4. Invalidate Cache
    player:SetAttribute("Item_Shield", 1) -- "Item_" prefix triggers invalidation

    -- 5. Third Call - Should refetch
    local val3 = StatLib:GetStat(player, "Damage", 10)
    if player.GetAttributesCallCount ~= 2 then
        error("FAIL: Expected 2 GetAttributes calls (refetch), got " .. player.GetAttributesCallCount)
    end
    print("PASS: Invalidation worked, refetched attributes.")

    -- 6. Irrelevant Attribute Change
    player:SetAttribute("Health", 100) -- Should NOT invalidate
    local val4 = StatLib:GetStat(player, "Damage", 10)
    if player.GetAttributesCallCount ~= 2 then
        error("FAIL: Irrelevant attribute caused refetch! Count: " .. player.GetAttributesCallCount)
    end
    print("PASS: Irrelevant attribute did not invalidate cache.")

    print("ALL TESTS PASSED")
end

return runTest
