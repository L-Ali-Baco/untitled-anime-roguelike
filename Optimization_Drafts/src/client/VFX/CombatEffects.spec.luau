return function()
	local CombatEffects = require(script.Parent.CombatEffects)

	describe("CombatEffects Optimized", function()
		it("should load the module", function()
			expect(CombatEffects).to.be.ok()
		end)

		it("should expose VFX methods", function()
			expect(CombatEffects.SpawnSlashTrail).to.be.a("function")
			expect(CombatEffects.SpawnHitSpark).to.be.a("function")
			expect(CombatEffects.SpawnFireHitEffect).to.be.a("function")
		end)
	end)
end
