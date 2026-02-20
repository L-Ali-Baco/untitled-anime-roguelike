return function()
	local EnemyLib = require(script.Parent.EnemyLib)

	describe("EnemyLib:TakeDamage", function()
		describe("Input Validation", function()
			it("should return 0 if model is nil", function()
				expect(EnemyLib:TakeDamage(nil, 10)).to.equal(0)
			end)

			it("should return 0 if amount is 0", function()
				local model = Instance.new("Model")
				expect(EnemyLib:TakeDamage(model, 0)).to.equal(0)
			end)

			it("should return 0 if amount is negative", function()
				local model = Instance.new("Model")
				expect(EnemyLib:TakeDamage(model, -5)).to.equal(0)
			end)
		end)

		describe("Attribute-based Enemies", function()
			local function createEnemy(health)
				local model = Instance.new("Model")
				model:SetAttribute("IsEnemy", true)
				model:SetAttribute("Health", health)
				model:SetAttribute("MaxHealth", 100)
				model:SetAttribute("IsDead", false)
				return model
			end

			it("should reduce health and return actual damage", function()
				local model = createEnemy(100)
				local damageDealt = EnemyLib:TakeDamage(model, 30)

				expect(damageDealt).to.equal(30)
				expect(model:GetAttribute("Health")).to.equal(70)
				expect(model:GetAttribute("IsDead")).to.equal(false)
			end)

			it("should cap health at 0 and set IsDead to true when lethal", function()
				local model = createEnemy(50)
				local damageDealt = EnemyLib:TakeDamage(model, 60)

				expect(damageDealt).to.equal(50)
				expect(model:GetAttribute("Health")).to.equal(0)
				expect(model:GetAttribute("IsDead")).to.equal(true)
			end)

			it("should return 0 if enemy is already dead (Health <= 0)", function()
				local model = createEnemy(0)
				model:SetAttribute("IsDead", true)

				local damageDealt = EnemyLib:TakeDamage(model, 10)

				expect(damageDealt).to.equal(0)
				expect(model:GetAttribute("Health")).to.equal(0)
				expect(model:GetAttribute("IsDead")).to.equal(true)
			end)
		end)
	end)
end
