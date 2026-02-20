return function()
	local EnemyService = require(script.Parent.EnemyService)

	describe("EnemyService Optimized", function()
		it("should load the module", function()
			expect(EnemyService).to.be.ok()
		end)

		it("should expose management methods", function()
			expect(EnemyService.SpawnEnemy).to.be.a("function")
			expect(EnemyService.RegisterEnemy).to.be.a("function")
			expect(EnemyService.GetEnemyCount).to.be.a("function")
		end)

        it("should have internal cache structure", function()
            -- We can't access locals directly in Lua, but we can verify behavior
            expect(EnemyService.GetActiveEnemies).to.be.a("function")
            expect(type(EnemyService:GetActiveEnemies())).to.equal("table")
        end)
	end)
end
