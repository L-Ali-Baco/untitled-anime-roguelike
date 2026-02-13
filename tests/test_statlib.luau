--[[
    tests/test_statlib.luau
    Unit tests for StatLib:GetStat
]]

local process = require("@lune/process")
local MockEnv = require("./mock_env")
local game = MockEnv.setup()

-- Ensure we use the mocked require
local require = _G.require

local StatLib = MockEnv.loadStatLib()
local ItemRegistry = require(game.ReplicatedStorage.Shared.Config.ItemRegistry)

-- Minimal Test Framework
local function expect(value)
    return {
        to = {
            equal = function(expected)
                -- Handle floating point comparison loosely
                if type(value) == "number" and type(expected) == "number" then
                    if math.abs(value - expected) > 0.0001 then
                         error(string.format("Expected %s, got %s", tostring(expected), tostring(value)), 2)
                    end
                elseif value ~= expected then
                    error(string.format("Expected %s, got %s", tostring(expected), tostring(value)), 2)
                end
            end
        }
    }
end

local function describe(desc, func)
    print("\nSuite: " .. desc)
    func()
end

local function it(desc, func)
    local success, err = pcall(func)
    if success then
        print("  [PASS] " .. desc)
    else
        print("  [FAIL] " .. desc)
        print("    Error: " .. tostring(err))
        process.exit(1)
    end
end

-- Tests
describe("StatLib:GetStat", function()
    local player = _G.Instance.new("Player")

    it("should return base value when no items present", function()
        local result = StatLib:GetStat(player, "Damage", 100)
        expect(result).to.equal(100)
    end)

    it("should apply additive bonuses correctly", function()
        -- LensMakersGlasses: CritChance +0.1 (Additive)
        player:SetAttribute("Item_LensMakersGlasses", 1)

        local result = StatLib:GetStat(player, "CritChance", 0)
        expect(result).to.equal(0.1)

        -- Reset
        player:SetAttribute("Item_LensMakersGlasses", 0)
    end)

    it("should apply multiplier bonuses correctly", function()
        -- SharpWhetstone: Damage +0.1 (Multiplier)
        player:SetAttribute("Item_SharpWhetstone", 1)

        local result = StatLib:GetStat(player, "Damage", 100)
        -- (100 + 0) * (1 + 0.1) = 110
        expect(result).to.equal(110)

        -- Stack 2 items
        player:SetAttribute("Item_SharpWhetstone", 2)
        result = StatLib:GetStat(player, "Damage", 100)
        -- (100) * (1 + 0.2) = 120
        expect(result).to.equal(120)

        player:SetAttribute("Item_SharpWhetstone", 0)
    end)

    it("should combine additive and multiplier bonuses", function()
        -- Inject a test item for deterministic testing
        ItemRegistry.Pool["TestItemAdditive"] = {
            Effects = {
                { Stat = "Damage", Value = 50, Type = "Additive" }
            }
        }

        player:SetAttribute("Item_TestItemAdditive", 1)
        player:SetAttribute("Item_SharpWhetstone", 1) -- +10% mult

        local result = StatLib:GetStat(player, "Damage", 100)
        -- (100 + 50) * (1 + 0.1) = 150 * 1.1 = 165
        expect(result).to.equal(165)

        -- Clean up
        ItemRegistry.Pool["TestItemAdditive"] = nil
        player:SetAttribute("Item_TestItemAdditive", 0)
        player:SetAttribute("Item_SharpWhetstone", 0)
    end)

    it("should ignore items not in registry", function()
        player:SetAttribute("Item_UnknownItem", 1)
        local result = StatLib:GetStat(player, "Damage", 100)
        expect(result).to.equal(100)
        player:SetAttribute("Item_UnknownItem", 0)
    end)

    it("should handle mixed stats", function()
        -- One item affects Speed, another Damage
        player:SetAttribute("Item_SwiftBoots", 1) -- WalkSpeed mult 0.15

        -- Check Damage (unaffected)
        local result = StatLib:GetStat(player, "Damage", 100)
        expect(result).to.equal(100)

        -- Check WalkSpeed (affected)
        result = StatLib:GetStat(player, "WalkSpeed", 16)
        -- 16 * 1.15 = 18.4
        expect(result).to.equal(18.4)

        player:SetAttribute("Item_SwiftBoots", 0)
    end)
end)

print("\nAll tests passed!")
