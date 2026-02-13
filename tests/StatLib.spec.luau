return function()
	local StatLib = require(game:GetService("ReplicatedStorage").Shared.Lib.StatLib)
	local ItemRegistry = require(game:GetService("ReplicatedStorage").Shared.Config.ItemRegistry)

	describe("StatLib", function()
		describe("GetStat", function()
			it("should return the base value when the player has no items", function()
				local player = Instance.new("Player")
				-- Ensure no attributes set

				local baseValue = 100
				local result = StatLib:GetStat(player, "Damage", baseValue)

				expect(result).to.equal(baseValue)
			end)

			it("should correctly apply additive bonuses", function()
				local player = Instance.new("Player")
				-- Assume "LensMakersGlasses" adds +0.1 CritChance (Additive)
				player:SetAttribute("Item_LensMakersGlasses", 1)

				-- Mock ItemRegistry logic if necessary, or rely on the real one loaded in environment
				-- For this test, we assume the real ItemRegistry has LensMakersGlasses

				local baseValue = 0.5
				local result = StatLib:GetStat(player, "CritChance", baseValue)

				-- 0.5 + 0.1 = 0.6
				expect(result).to.be.near(0.6, 0.001)
			end)

			it("should correctly apply multiplier bonuses", function()
				local player = Instance.new("Player")
				-- Assume "SharpWhetstone" adds +0.1 Damage (Multiplier)
				player:SetAttribute("Item_SharpWhetstone", 1)

				local baseValue = 100
				local result = StatLib:GetStat(player, "Damage", baseValue)

				-- (100 + 0) * (1 + 0.1) = 110
				expect(result).to.equal(110)
			end)
		end)
	end)
end
