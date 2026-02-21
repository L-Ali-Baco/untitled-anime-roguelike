return function()
	local CombatService = require(script.Parent.CombatService)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	-- We need to access the mocked dependencies to configure them for tests
	-- In a real TestEZ setup, we might use dependency injection or module mocking.
	-- Here, we assume the environment has been set up such that 'require' returns our mocks.

	local MockStatLib = require(ReplicatedStorage.Shared.Lib.StatLib)
	local MockCombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

	describe("CombatService.processDamage", function()
		local attacker
		local target
		local humanoid
		local rootPart

		beforeEach(function()
			-- Reset mocks
			attacker = Instance.new("Player")
			attacker.Name = "Attacker"
			attacker.Character = Instance.new("Model")
			local attackerRoot = Instance.new("Part")
			attackerRoot.Name = "HumanoidRootPart"
			attackerRoot.Parent = attacker.Character

			target = Instance.new("Model")
			target.Name = "Target"

			humanoid = Instance.new("Humanoid")
			humanoid.MaxHealth = 100
			humanoid.Health = 100
			humanoid.Parent = target

			rootPart = Instance.new("Part")
			rootPart.Name = "HumanoidRootPart"
			rootPart.Parent = target

			-- Default Stats
			MockStatLib.Stats = {
				Damage = 10, -- Base damage multiplier/addition from stats
				CritChance = 0,
			}

			-- Default Config
			MockCombatConfig.Server = {
				DamageMultiplier = 1.0,
			}
			MockCombatConfig.Attacks = {
				[1] = { Damage = 10, Knockback = 5, Hitstop = 0.1, ScreenShake = 0.1 },
			}

			-- Reset internal state if possible (attackHitTargets)
			-- Since we can't easily access local variables, we use unique attackIds for each test
		end)

		it("should apply base damage correctly", function()
			local attackId = "attack_base_1"
			local attackIndex = 1

			-- Config: Attack 1 does 10 damage
			-- StatLib: Returns 10 (override base) or modifies it?
			-- The code: `local damage = StatLib:GetStat(attacker, "Damage", baseDamage)`
			-- Our MockStatLib.GetStat returns the stat value if present, or baseValue.
			-- Let's set StatLib to return baseValue for "Damage" by default or handle it.

			-- We'll implement MockStatLib behavior in the runner, but here we assume:
			-- If "Damage" is set in MockStatLib.Stats, it returns that.
			-- If not, it returns baseValue.

			-- Test Case 1: No stat modifiers
			MockStatLib.Stats.Damage = nil -- Use base value

			local didDamage, targetDied = CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(didDamage).to.equal(true)
			expect(targetDied).to.equal(false)
			expect(humanoid.Health).to.equal(90) -- 100 - 10
		end)

		it("should apply stat modifiers to damage", function()
			local attackId = "attack_stat_1"
			local attackIndex = 1

			-- StatLib returns 20 instead of base 10
			MockStatLib.Stats.Damage = 20

			CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(humanoid.Health).to.equal(80) -- 100 - 20
		end)

		it("should apply global damage multiplier", function()
			local attackId = "attack_global_1"
			local attackIndex = 1

			MockStatLib.Stats.Damage = nil
			MockCombatConfig.Server.DamageMultiplier = 2.0

			CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(humanoid.Health).to.equal(80) -- 100 - (10 * 2)
		end)

		it("should handle critical hits", function()
			local attackId = "attack_crit_1"
			local attackIndex = 1

			MockStatLib.Stats.Damage = nil
			MockStatLib.Stats.CritChance = 1.0 -- 100% crit chance

			CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(humanoid.Health).to.equal(80) -- 100 - (10 * 2.0)
		end)

		it("should apply damage resistance", function()
			local attackId = "attack_resist_1"
			local attackIndex = 1

			MockStatLib.Stats.Damage = nil
			target:SetAttribute("DamageResistance", 0.5) -- 50% resistance

			CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(humanoid.Health).to.equal(95) -- 100 - (10 * 0.5)
		end)

		it("should be fully blocked by shield", function()
			local attackId = "attack_shield_1"
			local attackIndex = 1

			MockStatLib.Stats.Damage = nil
			target:SetAttribute("Shield", 20) -- 20 shield > 10 damage

			CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(humanoid.Health).to.equal(100) -- No health damage
			expect(target:GetAttribute("Shield")).to.equal(10) -- 20 - 10
		end)

		it("should break shield and apply excess damage", function()
			local attackId = "attack_shield_break_1"
			local attackIndex = 1

			MockStatLib.Stats.Damage = nil
			target:SetAttribute("Shield", 5) -- 5 shield < 10 damage

			CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(humanoid.Health).to.equal(95) -- 100 - (10 - 5)
			expect(target:GetAttribute("Shield")).to.equal(0)
		end)

		it("should ignore duplicate hits with same attackId", function()
			local attackId = "attack_dup_1"
			local attackIndex = 1
			MockStatLib.Stats.Damage = nil

			-- First hit
			local didDamage1 = CombatService._processDamage(attacker, target, attackIndex, attackId)
			expect(didDamage1).to.equal(true)
			expect(humanoid.Health).to.equal(90)

			-- Second hit (same ID)
			local didDamage2 = CombatService._processDamage(attacker, target, attackIndex, attackId)
			expect(didDamage2).to.equal(false)
			expect(humanoid.Health).to.equal(90) -- No change
		end)

		it("should allow hits with different attackIds", function()
			local attackId1 = "attack_diff_1"
			local attackId2 = "attack_diff_2"
			local attackIndex = 1
			MockStatLib.Stats.Damage = nil

			-- First hit
			CombatService._processDamage(attacker, target, attackIndex, attackId1)
			expect(humanoid.Health).to.equal(90)

			-- Second hit (different ID)
			CombatService._processDamage(attacker, target, attackIndex, attackId2)
			expect(humanoid.Health).to.equal(80)
		end)

		it("should return false if target is dead", function()
			local attackId = "attack_dead_1"
			local attackIndex = 1

			humanoid.Health = 0

			local didDamage = CombatService._processDamage(attacker, target, attackIndex, attackId)
			expect(didDamage).to.equal(false)
		end)

		it("should report target death", function()
			local attackId = "attack_kill_1"
			local attackIndex = 1

			humanoid.Health = 5
			MockStatLib.Stats.Damage = 10 -- Overkill

			local didDamage, targetDied = CombatService._processDamage(attacker, target, attackIndex, attackId)

			expect(didDamage).to.equal(true)
			expect(targetDied).to.equal(true)
			expect(humanoid.Health).to.equal(0) -- Clamp to 0 usually handled by Humanoid, but mock might go negative
			-- In our mock, TakeDamage subtracts.
		end)
	end)
end
