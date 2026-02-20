return function()
	local CombatController = require(script.Parent.CombatController)

	describe("CombatController Optimized", function()
		it("should load the module", function()
			expect(CombatController).to.be.ok()
			expect(CombatController.Init).to.be.a("function")
			expect(CombatController.Start).to.be.a("function")
		end)

		it("should expose public API", function()
			expect(CombatController.IsAttacking).to.be.a("function")
			expect(CombatController.GetCurrentComboHit).to.be.a("function")
			expect(CombatController.CanAttack).to.be.a("function")
		end)

        -- Note: Deeper logic testing requires full mocking of RunService, Players, etc.
	end)
end
