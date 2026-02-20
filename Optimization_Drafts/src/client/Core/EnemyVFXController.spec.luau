return function()
	local EnemyVFXController = require(script.Parent.EnemyVFXController)

	describe("EnemyVFXController Optimized", function()
		it("should load the module", function()
			expect(EnemyVFXController).to.be.ok()
		end)

		it("should expose PlayHitstun", function()
			expect(EnemyVFXController.PlayHitstun).to.be.a("function")
		end)
	end)
end
