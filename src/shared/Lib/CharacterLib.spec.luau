local CharacterLib = require("./CharacterLib")

return function(context)
	local describe = context.describe
	local it = context.it
	local expect = context.expect

	-- Mock Instance helper if needed, or use global if it persists.
	-- Since _G.Instance might not persist, let's allow passing it or relying on global if shared.
	-- Let's check if _G.Instance is shared. If describe failed, Instance likely fails too.
	local Instance = context.Instance or _G.Instance

	describe("CharacterLib:IsAlive", function()
		it("should return true when character has a Humanoid with Health > 0", function()
			local model = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid:SetParent(model)
			humanoid.Health = 100

			expect(CharacterLib:IsAlive(model)).to.equal(true)
		end)

		it("should return false when character has a Humanoid with Health <= 0", function()
			local model = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid:SetParent(model)
			humanoid.Health = 0

			expect(CharacterLib:IsAlive(model)).to.equal(false)
		end)

		it("should return false when character has no Humanoid", function()
			local model = Instance.new("Model")
			-- No humanoid added

			expect(CharacterLib:IsAlive(model)).to.equal(false)
		end)

		it("should return false when model is nil", function()
			expect(CharacterLib:IsAlive(nil)).to.equal(false)
		end)
	end)
end
